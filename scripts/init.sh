#!/usr/bin/env bash
# First-time local setup (safe to re-run).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"

chmod +x "${ROOT}/scripts/"*.sh "${ROOT}/scripts/lib/"*.sh 2>/dev/null || true

if [[ ! -f "${ROOT}/.env" ]]; then
  cp "${ROOT}/.env.example" "${ROOT}/.env"
  echo "Created .env — set INNGEST_DOMAIN to your hostname (e.g. inngest.example.com)"
else
  echo ".env exists"
fi

ensure_sync_apps_conf

cat <<EOF

Ready.

  1. Edit .env → INNGEST_DOMAIN
  2. Edit sync-apps.conf → your worker serve URLs
  3. aws login
  4. ./scripts/up.sh

EOF
