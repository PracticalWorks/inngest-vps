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
