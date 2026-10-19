#!/usr/bin/env bash
# Deploy stack to an existing Lightsail IP (provision.sh calls this automatically).
#
#   ./scripts/install.sh 1.2.3.4
#   ./scripts/install.sh --print-env
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"

ENV_FILE="${ROOT}/.env"
REMOTE_DIR="/opt/inngest"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

normalize_host() {
  local h="$1"
  [[ "$h" == *@* ]] || h="ubuntu@${h}"
  printf '%s' "$h"
}

rand_hex() { openssl rand -hex "$1"; }

ensure_env() {
  if [[ -f "$ENV_FILE" ]]; then
    return
  fi
  local domain
  domain="$(inngest_domain)"
  cat >"$ENV_FILE" <<EOF
INNGEST_DOMAIN=${domain}
INNGEST_EVENT_KEY=$(rand_hex 16)
INNGEST_SIGNING_KEY=$(rand_hex 32)
PG_PASSWORD=$(rand_hex 16)
INNGEST_QUEUE_WORKERS=200
INNGEST_POLL_INTERVAL=60
INNGEST_LOG_LEVEL=info
EOF
  chmod 600 "$ENV_FILE"
  [[ -z "${QUIET:-}" ]] && echo "Created ${ENV_FILE}"
}

print_env() {
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  cat <<EOF

INNGEST_EVENT_KEY=${INNGEST_EVENT_KEY}
INNGEST_SIGNING_KEY=${INNGEST_SIGNING_KEY}
INNGEST_BASE_URL=https://${INNGEST_DOMAIN}
INNGEST_DEV=0

EOF
}

if [[ "${1:-}" == "--print-env" ]]; then
  ensure_env
  print_env
  exit 0
fi

HOST_RAW="${1:?Usage: ./scripts/provision.sh   or   ./scripts/install.sh IP}"
HOST="$(normalize_host "$HOST_RAW")"
IP="${HOST#*@}"

# This script pushes the LOCAL .env over the VPS's, and ensure_env mints fresh keys when
# the local file is missing. On a live box either one strands every app (signing and event
# keys), drops a gate credential, or locks inngest out of its own Postgres (PG_PASSWORD)
# (HOMEINFRA-229). So compare first, by hash, printing names only. New local names are
# fine; a name the push would delete or change stops it. INSTALL_ENV_OVERWRITE=1 is the
# deliberate override.
guard_remote_env() {
  if [[ "${INSTALL_ENV_OVERWRITE:-}" == 1 ]]; then
    echo "INSTALL_ENV_OVERWRITE=1: the local .env replaces the VPS's without a comparison."
    return 0
  fi
  local remote locl lh name hash problems=() adds=()
  remote="$(ssh "${SSH_OPTS[@]}" "$HOST" "bash -s -- ${REMOTE_DIR}/.env" <"${ROOT}/scripts/env-manifest.sh")" \
    || { echo "Could not read ${REMOTE_DIR}/.env on ${HOST} to compare it; refusing to overwrite it." >&2; exit 1; }
  case "$remote" in
    ABSENT) return 0 ;;
    UNREADABLE) echo "${HOST}:${REMOTE_DIR}/.env exists but is unreadable; refusing to overwrite it." >&2; exit 1 ;;
  esac
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "No local ${ENV_FILE}, but ${HOST} already has one. A deploy would mint new keys and" >&2
    echo "replace the live ones. Run this from the checkout that holds the box's .env." >&2
    exit 1
  fi
  locl="$(bash "${ROOT}/scripts/env-manifest.sh" "$ENV_FILE")"
  # Last assignment wins, as in compose's .env.
  remote="$(awk '{m[$1]=$2} END {for (k in m) print k, m[k]}' <<<"$remote" | sort)"
  locl="$(awk '{m[$1]=$2} END {for (k in m) print k, m[k]}' <<<"$locl" | sort)"
  while read -r name hash; do
    [[ -n "$name" ]] || continue
    lh="$(awk -v n="$name" '$1 == n {print $2}' <<<"$locl")"
    if [[ -z "$lh" ]]; then problems+=("${name}: set on the VPS, missing locally (the push would delete it)")
    elif [[ "$lh" != "$hash" ]]; then problems+=("${name}: differs from the VPS (the push would change it)")
    fi
  done <<<"$remote"
  while read -r name hash; do
    [[ -n "$name" ]] || continue
    awk -v n="$name" '$1 == n {f=1} END {exit !f}' <<<"$remote" || adds+=("$name")
  done <<<"$locl"
  if (( ${#problems[@]} > 0 )); then
    echo "Refusing to push the local .env over ${HOST}:${REMOTE_DIR}/.env:" >&2
    printf '  %s\n' "${problems[@]}" >&2
    echo "Make the local .env match the VPS, or rerun with INSTALL_ENV_OVERWRITE=1 if the change is deliberate." >&2
    exit 1
  fi
  if (( ${#adds[@]} > 0 )); then echo "The local .env adds: ${adds[*]}"; fi
  echo "Local .env matches the VPS's on every name it already holds."
}
guard_remote_env

ensure_env
chmod +x "${ROOT}/scripts/"*.sh "${ROOT}/scripts/lib/"*.sh 2>/dev/null || true

if [[ -z "${QUIET:-}" ]]; then
  echo "→ ${HOST}:${REMOTE_DIR}"
fi

ssh "${SSH_OPTS[@]}" "$HOST" "sudo mkdir -p ${REMOTE_DIR} && sudo chown -R \$(whoami):\$(whoami) ${REMOTE_DIR} 2>/dev/null || true"

rsync -avz --delete \
  --exclude '.env' \
  --exclude 'sync-apps.conf' \
  --exclude 'inngest.yaml' \
  --exclude 'certs/' \
  --exclude 'backups/' \
  --exclude '.git/' \
  --exclude '.setup.local' \
  --exclude 'terraform/' \
  "${ROOT}/" "${HOST}:${REMOTE_DIR}/"

rsync -avz "${ENV_FILE}" "${HOST}:${REMOTE_DIR}/.env"

ssh "${SSH_OPTS[@]}" "$HOST" "bash ${REMOTE_DIR}/scripts/remote-bootstrap.sh"

echo "INNGEST_LIGHTSAIL_IP=${IP}" >"${ROOT}/.setup.local"

if [[ -z "${QUIET:-}" ]]; then
  cat <<EOF

Deployed to ${IP}
  ./scripts/install.sh --print-env
  ./scripts/sync-apps.sh

EOF
fi
