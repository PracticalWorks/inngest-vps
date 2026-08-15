#!/usr/bin/env bash
# Self-hosted Inngest (OSS) worker sync.
#
# OSS has no Cloud REST sync API. The Inngest server polls serve URLs from
# inngest.yaml (mounted in Docker). This script probes workers, regenerates
# inngest.yaml from sync-apps.conf, and recreates the Inngest container.
#
# Usage:
#   ./scripts/sync-apps.sh              # probe + reload Lightsail server
#   ./scripts/sync-apps.sh --fly        # probe + deploy Fly server
#   ./scripts/sync-apps.sh --check      # probe serve URLs only
#   ./scripts/sync-apps.sh --write-yaml # regenerate inngest.yaml locally
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"

TARGET="${INNGEST_TARGET:-lightsail}"
for arg in "$@"; do
  case "$arg" in
    --fly) TARGET="fly" ;;
  esac
done

CONF="$(inngest_repo_root)/sync-apps.conf"
YAML="$(inngest_repo_root)/inngest.yaml"
BASE="$(inngest_base_url)"
REMOTE_DIR="/opt/inngest"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

get_ip() {
  local root
  root="$(inngest_repo_root)"
  if [[ -f "${root}/.setup.local" ]]; then
    # shellcheck disable=SC1090
    source "${root}/.setup.local"
    if [[ -n "${INNGEST_LIGHTSAIL_IP:-}" ]]; then
      echo "${INNGEST_LIGHTSAIL_IP}"
      return 0
    fi
  fi
  if command -v terraform >/dev/null 2>&1; then
    terraform -chdir="${root}/terraform/aws" output -raw static_ip 2>/dev/null && return 0
  fi
  return 1
}

write_inngest_yaml() {
  [[ -f "$CONF" ]] || {
    echo "Missing ${CONF} — run ./scripts/init.sh"
    exit 1
  }

  {
    echo "# Generated from sync-apps.conf — do not edit by hand."
    echo "urls:"
    while IFS='|' read -r app_id url _rest || [[ -n "${app_id:-}${url:-}" ]]; do
      [[ "${app_id:-}" =~ ^[[:space:]]*# ]] && continue
      url="${url#"${url%%[![:space:]]*}"}"
      url="${url%"${url##*[![:space:]]}"}"
      [[ -z "${url:-}" ]] && continue
      echo "  - ${url}"
    done <"$CONF"
    echo "poll-interval: 60"
  } >"$YAML"
}

probe_url() {
  local app_id="$1" url="$2"
  local code

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo "000")"
  echo "  ${app_id}"
  echo "    ${url} → HTTP ${code}"

  case "$code" in
    200|201|204|405) return 0 ;;
    401) echo "    auth blocking serve path — exempt /inngest (or your path) from app auth" ;;
    404) echo "    route missing — Mastra uses /inngest, not /api/inngest" ;;
    500) echo "    handler error — check worker logs" ;;
    000) echo "    unreachable — DNS or app down" ;;
  esac
  return 1
}

reload_inngest_server() {
  local ip host root fly_app
  root="$(inngest_repo_root)"

  write_inngest_yaml

  # Fly deploys the generated poll config with the image. It never needs the
  # Lightsail IP or SSH, and it does not use Inngest Cloud's REST sync API.
  if [[ "$TARGET" == "fly" ]]; then
    load_local_env
    fly_app="${FLY_APP_NAME:?Set FLY_APP_NAME for --fly sync}"
    [[ -f "${root}/fly.toml" ]] || {
      echo "Missing ${root}/fly.toml — run ./scripts/up-fly.sh first"
      exit 1
    }
    echo "→ deploy generated inngest.yaml to Fly app ${fly_app}"
    flyctl deploy --config "${root}/fly.toml" --app "$fly_app" --remote-only
  else
    ip="$(get_ip)" || {
      echo "No VPS IP — run ./scripts/up.sh first"
      exit 1
    }
    host="ubuntu@${ip}"
    echo "→ rsync config to ${host}:${REMOTE_DIR}/"
    rsync -avz "$YAML" "${root}/docker-compose.yml" "${host}:${REMOTE_DIR}/"
    echo "→ recreate Inngest container (applies inngest.yaml mount)"
    ssh "${SSH_OPTS[@]}" "$host" "cd ${REMOTE_DIR} && if docker info >/dev/null 2>&1; then docker compose up -d inngest; else sudo docker compose up -d inngest; fi"
  fi

  echo
  echo "Server reloading. Poll interval: 60s."
  echo "Dashboard: ${BASE} → Apps"
}

main() {
  ensure_sync_apps_conf

  case "${1:-}" in
    --write-yaml)
      write_inngest_yaml
      echo "Wrote ${YAML}"
      exit 0
      ;;
    --fly)
      shift
      main "$@"
      exit $?
      ;;
    --check)
      echo "Probing worker serve URLs:"
      echo
      failed=0
      while IFS='|' read -r app_id url _rest; do
        [[ -z "${app_id:-}" || "$app_id" =~ ^# ]] && continue
        [[ -z "${url:-}" ]] && continue
        probe_url "$app_id" "$url" || failed=$((failed + 1))
        echo
      done <"$CONF"
      exit "$(( failed > 0 ? 1 : 0 ))"
      ;;
    --help | -h)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    "" | --reload-server)
      echo "Inngest server: ${BASE}"
      echo "OSS sync: server polls inngest.yaml (no Cloud REST API)."
      echo
      echo "Worker serve URLs:"
      failed=0
      while IFS='|' read -r app_id url _rest; do
        [[ -z "${app_id:-}" || "$app_id" =~ ^# ]] && continue
        [[ -z "${url:-}" ]] && continue
        probe_url "$app_id" "$url" || failed=$((failed + 1))
        echo
      done <"$CONF"

      if (( failed > 0 )); then
        echo "Some workers look unhealthy — sync may still partially work."
        echo
      fi

      reload_inngest_server
      ;;
    *)
      echo "Unknown: $1 (try --help)"
      exit 1
      ;;
  esac
}

main "$@"
