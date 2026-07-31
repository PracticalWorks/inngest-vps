#!/usr/bin/env bash
# Shared helpers for inngest-vps scripts.
set -euo pipefail

inngest_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

load_local_env() {
  local root
  root="$(inngest_repo_root)"
  if [[ -f "${root}/.env" ]]; then
    # shellcheck disable=SC1090
    source "${root}/.env"
  fi
}

inngest_domain() {
  load_local_env
  printf '%s' "${INNGEST_DOMAIN:-inngest.example.com}"
}

inngest_base_url() {
  printf 'https://%s' "$(inngest_domain)"
}

ensure_sync_apps_conf() {
  local root conf example
  root="$(inngest_repo_root)"
  conf="${root}/sync-apps.conf"
  example="${root}/sync-apps.conf.example"
  if [[ -f "$conf" ]]; then
    return 0
  fi
  if [[ -f "$example" ]]; then
    cp "$example" "$conf"
    echo "Created ${conf} from sync-apps.conf.example — edit with your worker URLs."
    return 0
  fi
  echo "Missing ${conf}. Copy sync-apps.conf.example and add your apps."
  return 1
}
