#!/usr/bin/env bash
# Deploy the additive Fly.io target. Fly terminates TLS; Redis is a Fly app.
# Supabase supplies the dedicated Inngest Postgres database/schema.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"

load_local_env
: "${FLY_APP_NAME:=inngest-oss}"
: "${FLY_REGION:=iad}"
export FLY_APP_NAME FLY_REGION
: "${FLY_REDIS_URL:?Set FLY_REDIS_URL to the Fly Redis private URL}"
: "${INNGEST_POSTGRES_URI:?Set INNGEST_POSTGRES_URI to the Supabase session pooler URI with sslmode=require}"
: "${INNGEST_EVENT_KEY:?Set INNGEST_EVENT_KEY}"
: "${INNGEST_SIGNING_KEY:?Set INNGEST_SIGNING_KEY}"

[[ "${INNGEST_POSTGRES_URI}" == *"sslmode=require"* ]] || {
  echo "INNGEST_POSTGRES_URI must include sslmode=require" >&2
  exit 1
}
normalized_postgres_uri="${INNGEST_POSTGRES_URI//%3D/=}"
normalized_postgres_uri="${normalized_postgres_uri//%3d/=}"
case "$normalized_postgres_uri" in
  *search_path=app[^a-zA-Z0-9_]*|*search_path=app|*schema=app[^a-zA-Z0-9_]*|*schema=app)
    echo "INNGEST_POSTGRES_URI must not target the tenant schema app" >&2
    exit 1
    ;;
esac

flyctl apps create "$FLY_APP_NAME" 2>/dev/null || true
if [[ ! -f "${ROOT}/fly.toml" ]]; then
  sed "s/app = \"inngest-oss\"/app = \"${FLY_APP_NAME}\"/; s/primary_region = \"iad\"/primary_region = \"${FLY_REGION}\"/" \
    "${ROOT}/fly.toml.example" >"${ROOT}/fly.toml"
fi
flyctl secrets set \
  INNGEST_EVENT_KEY="$INNGEST_EVENT_KEY" \
  INNGEST_SIGNING_KEY="$INNGEST_SIGNING_KEY" \
  INNGEST_POSTGRES_URI="$INNGEST_POSTGRES_URI" \
  INNGEST_REDIS_URI="$FLY_REDIS_URL" \
  --app "$FLY_APP_NAME"

"${ROOT}/scripts/sync-apps.sh" --write-yaml
flyctl deploy --config "${ROOT}/fly.toml" --app "$FLY_APP_NAME" --remote-only
