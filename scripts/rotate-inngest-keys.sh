#!/usr/bin/env bash
# =============================================================================
# rotate-inngest-keys.sh
# -----------------------------------------------------------------------------
# Rotate the SHARED self-hosted Inngest event + signing keys across the Inngest
# server (the Lightsail VPS) and every worker app, in one coordinated cutover.
#
# SECURITY: this script NEVER prints secret values. New keys are generated into
# shell vars + written ONLY to (a) the gitignored .env files, (b) the VPS .env,
# and (c) the Coolify API request bodies. `set +x` is enforced; nothing echoes a
# value. If you must inspect a value, read the gitignored file directly yourself.
#
# Usage:
#   ./scripts/rotate-inngest-keys.sh            # do it
#   ./scripts/rotate-inngest-keys.sh --dry-run  # show the plan, change nothing
#   ./scripts/rotate-inngest-keys.sh --verify   # only run the post-rotation checks
#
# Requires: openssl, curl, jq, ssh/scp. Config: scripts/../rotate.conf (gitignored;
# copy rotate.conf.example). The Coolify token never leaves this machine.
# =============================================================================
set -euo pipefail
set +x                      # belt-and-suspenders: never trace (would leak values)
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"

OPS_ENV="${ROOT}/.env"
CONF="${ROOT}/rotate.conf"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
DRY=0; VERIFY_ONLY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --verify)  VERIFY_ONLY=1 ;;
  "" ) ;;
  *) echo "Unknown arg: $1 (try --dry-run | --verify)"; exit 1 ;;
esac

# Scratch dir for transient secret-bearing files; wiped on exit no matter what.
TMP="$(mktemp -d)"
# Preserve the real exit status — without capturing $? first, the rm would reset
# it to 0 and mask every failure (config error, scp fail, etc.) as success.
cleanup() { rc=$?; rm -rf "$TMP"; exit "$rc"; }
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }                       # safe: never pass secrets here
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
# rotate.conf is OPTIONAL — only for overrides. Defaults + auto-detection below
# mean the normal case is just:  ./scripts/rotate-inngest-keys.sh
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"

: "${VPS_INNGEST_DIR:=/opt/inngest}"

# COOLIFY_API and WORKERS come from rotate.conf (copy rotate.conf.example).
# WORKERS is required; COOLIFY_API only if your workers deploy via Coolify.

# Auto-derive the VPS ssh target from .setup.local unless explicitly provided.
if [[ -z "${VPS_HOST:-}" && -f "${ROOT}/.setup.local" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "${ROOT}/.setup.local"
  [[ -n "${INNGEST_LIGHTSAIL_IP:-}" ]] && VPS_HOST="ubuntu@${INNGEST_LIGHTSAIL_IP}"
fi

for bin in openssl curl jq ssh scp; do command -v "$bin" >/dev/null || die "missing dependency: $bin"; done

# Mode-aware requirements (use explicit die, NOT ${VAR:?} — see EXIT-trap note).
[[ -n "${WORKERS:-}" ]] || die "No WORKERS configured."
if [[ "$VERIFY_ONLY" != 1 ]]; then        # verify is read-only; needs neither host nor token
  [[ -n "${VPS_HOST:-}" ]] || die "VPS_HOST not set and INNGEST_LIGHTSAIL_IP missing from ${ROOT}/.setup.local. Set VPS_HOST in rotate.conf."
fi
# Real run needs the Coolify token — prompt for it (hidden) if not already in env/conf.
if [[ "$VERIFY_ONLY" != 1 && "$DRY" != 1 && -z "${COOLIFY_TOKEN:-}" ]]; then
  if [[ -t 0 ]]; then
    printf 'Coolify API token (read+write+deploy) — input hidden, paste + Enter: ' >&2
    read -rs COOLIFY_TOKEN || true; printf '\n' >&2
  fi
  [[ -n "${COOLIFY_TOKEN:-}" ]] || die "No COOLIFY_TOKEN. Re-run and paste at the prompt, or: export COOLIFY_TOKEN=... before running."
  [[ -n "${COOLIFY_API:-}" ]] || die "COOLIFY_API not set. Set it in rotate.conf (see rotate.conf.example)."
fi

# -----------------------------------------------------------------------------
# Coolify helpers (token via header; values via @file bodies — never in argv)
# -----------------------------------------------------------------------------
cf() {  # cf METHOD PATH [bodyfile]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "${COOLIFY_API}${path}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
      -H "Content-Type: application/json" --data @"$body"
  else
    curl -fsS -X "$method" "${COOLIFY_API}${path}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}"
  fi
}

resolve_uuid_by_domain() {  # echoes "<type>:<uuid>" for a serve URL's host
  local host="$1" apps
  apps="$(cf GET /api/v1/applications)" || die "Coolify API: cannot list applications (check token scope)"
  local uuid
  uuid="$(jq -r --arg h "$host" '.[] | select((.fqdn // "") | contains($h)) | .uuid' <<<"$apps" | head -1)"
  [[ -n "$uuid" && "$uuid" != "null" ]] && { echo "applications:$uuid"; return 0; }
  # fall back to services (compose resources sometimes surface here)
  local svcs; svcs="$(cf GET /api/v1/services 2>/dev/null || echo '[]')"
  uuid="$(jq -r --arg h "$host" '.[] | select((.fqdn // "")|contains($h)) | .uuid' <<<"$svcs" | head -1)"
  [[ -n "$uuid" && "$uuid" != "null" ]] && { echo "services:$uuid"; return 0; }
  return 1
}

cf_set_env() {  # cf_set_env <type> <uuid> <KEY> <valuefile>
  local type="$1" uuid="$2" key="$3" vf="$4" body="${TMP}/body.json"
  jq -n --arg k "$key" --rawfile v "$vf" '{key:$k, value:($v|rtrimstr("\n")), is_preview:false}' >"$body"
  # PATCH updates if present; if it 404s on "not found", POST to create.
  cf PATCH "/api/v1/${type}/${uuid}/envs" "$body" >/dev/null 2>&1 \
    || cf POST "/api/v1/${type}/${uuid}/envs" "$body" >/dev/null
}

cf_redeploy() { cf GET "/api/v1/deploy?uuid=$2&force=false" >/dev/null && say "  redeploy triggered ($1)"; }

# -----------------------------------------------------------------------------
# 0. VERIFY-ONLY short circuit
# -----------------------------------------------------------------------------
# Rotation success = each worker re-registers and shows connected=true with the
# new keys. The url scheme (http vs https) is a SEPARATE concern (the serveHost /
# Cloudflare-redirect issue) — only relevant on domains that 301 http->https — so
# we report it as info, not a rotation failure.
verify_all() {
  local base rc=0; base="$(inngest_base_url)"
  say "== verify (rotation = reachable + connected=true) =="
  local apps
  apps="$(curl -fsS --max-time 12 -X POST "${base}/v0/gql" -H 'Content-Type: application/json' \
    --data '{"query":"query { apps { externalID url connected } }"}' 2>/dev/null || echo '{}')"
  while read -r url; do [[ -z "$url" ]] && continue
    local host intro mode row regurl conn
    host="$(printf '%s' "$url" | sed -E 's#https?://([^/]+).*#\1#')"
    intro="$(curl -fsS --max-time 10 "$url" 2>/dev/null || echo '{}')"
    mode="$(jq -r '.mode // "unreachable"' <<<"$intro")"
    row="$(jq -c --arg h "$host" '.data.apps[]? | select(.url|contains($h))' <<<"$apps" 2>/dev/null | head -1)"
    if [[ -z "$row" ]]; then
      say "  ${host}: introspection mode=${mode} | server: NOT REGISTERED"; rc=1; continue
    fi
    regurl="$(jq -r '.url' <<<"$row")"; conn="$(jq -r '.connected' <<<"$row")"
    say "  ${host}: introspection mode=${mode} | registered=${regurl} connected=${conn}"
    if [[ "$conn" == "true" && "$mode" != "unreachable" ]]; then
      say "    OK (key rotation healthy)"
      [[ "$regurl" == http://* ]] && say "    note: registered over http:// — fine UNLESS this domain 301s http->https (then it needs the serveHost fix; separate from key rotation)"
    else
      say "    !! not connected/reachable — rotation likely incomplete here"; rc=1
    fi
  done <<<"$WORKERS"
  return "$rc"
}
if [[ "$VERIFY_ONLY" == 1 ]]; then verify_all; exit $?; fi

# -----------------------------------------------------------------------------
# 1. Generate the new pair (lengths match the current keys)
# -----------------------------------------------------------------------------
NEW_EVENT_KEY="$(openssl rand -hex 16)"      # 32 hex chars
NEW_SIGNING_KEY="$(openssl rand -hex 32)"    # 64 hex chars
printf '%s' "$NEW_EVENT_KEY"   >"${TMP}/event.key"
printf '%s' "$NEW_SIGNING_KEY" >"${TMP}/signing.key"
say "Generated a new event key + signing key (values not shown)."

if [[ "$DRY" == 1 ]]; then
  say "DRY-RUN plan:"
  say "  1. rewrite ${OPS_ENV} (INNGEST_EVENT_KEY, INNGEST_SIGNING_KEY)"
  say "  2. scp .env -> ${VPS_HOST}:${VPS_INNGEST_DIR}/.env ; recreate 'inngest' container"
  say "  3. for each worker URL, set both keys via Coolify API + redeploy:"
  while read -r u; do [[ -n "$u" ]] && say "       - $u"; done <<<"$WORKERS"
  say "  4. PUT each /inngest to re-register ; 5. verify reachable + connected=true"
  exit 0
fi

# -----------------------------------------------------------------------------
# 2. Update local ops .env (canonical record) — backup first
# -----------------------------------------------------------------------------
[[ -f "$OPS_ENV" ]] || die "Missing ${OPS_ENV}"
cp -p "$OPS_ENV" "${OPS_ENV}.bak.$(date +%s 2>/dev/null || echo bak)"
# Replace in place without printing values (sed reads the value from the temp files via shell var).
tmp_env="${TMP}/ops.env"
awk -v ek="$NEW_EVENT_KEY" -v sk="$NEW_SIGNING_KEY" '
  /^INNGEST_EVENT_KEY=/   {print "INNGEST_EVENT_KEY="ek; next}
  /^INNGEST_SIGNING_KEY=/ {print "INNGEST_SIGNING_KEY="sk; next}
  {print}
' "$OPS_ENV" >"$tmp_env"
grep -q '^INNGEST_EVENT_KEY='   "$tmp_env" || die "INNGEST_EVENT_KEY not found in ${OPS_ENV}"
grep -q '^INNGEST_SIGNING_KEY=' "$tmp_env" || die "INNGEST_SIGNING_KEY not found in ${OPS_ENV}"
cp "$tmp_env" "$OPS_ENV"
say "Updated ${OPS_ENV} (backup saved)."

# -----------------------------------------------------------------------------
# 3. Push to the VPS + recreate the inngest container
# -----------------------------------------------------------------------------
say "Pushing new keys to the Inngest server (${VPS_HOST}) and recreating the container..."
scp "${SSH_OPTS[@]}" "$OPS_ENV" "${VPS_HOST}:${VPS_INNGEST_DIR}/.env" \
  || die "scp .env to VPS failed (check VPS_HOST / SSH access)"
ssh "${SSH_OPTS[@]}" "$VPS_HOST" \
  "cd ${VPS_INNGEST_DIR} && (docker compose up -d --force-recreate inngest || sudo docker compose up -d --force-recreate inngest)" \
  || die "Failed to recreate inngest container on the VPS"
say "Inngest server recreated with the new keys."

# -----------------------------------------------------------------------------
# 4. Update each worker in Coolify (env + redeploy)
# -----------------------------------------------------------------------------
say "Updating workers in Coolify..."
declare -a WORKER_URLS=()
while read -r url; do [[ -n "$url" ]] && WORKER_URLS+=("$url"); done <<<"$WORKERS"
FAILED_WORKERS=()
for url in "${WORKER_URLS[@]}"; do
  host="$(printf '%s' "$url" | sed -E 's#https?://([^/]+).*#\1#')"
  say "  ${host}:"
  # Best-effort per worker: the server is already rotated, so never abort the
  # whole run on one worker — record the failure and keep going.
  if res="$(resolve_uuid_by_domain "$host" 2>/dev/null)"; then
    type="${res%%:*}"; uuid="${res##*:}"
    if cf_set_env "$type" "$uuid" INNGEST_EVENT_KEY "${TMP}/event.key" \
       && cf_set_env "$type" "$uuid" INNGEST_SIGNING_KEY "${TMP}/signing.key"; then
      say "    env updated (${type}/${uuid})"
      cf_redeploy "$host" "$uuid" || say "    !! redeploy call failed — redeploy ${host} manually"
    else
      say "    !! Coolify env update failed for ${host} — set both keys manually + redeploy"
      FAILED_WORKERS+=("$host")
    fi
  else
    say "    !! could not resolve a Coolify resource for ${host}."
    say "       Set both keys manually in Coolify -> ${host} -> Environment Variables, then redeploy."
    FAILED_WORKERS+=("$host")
  fi
done

# -----------------------------------------------------------------------------
# 5. Wait for workers to come back, then re-register each with the server
# -----------------------------------------------------------------------------
say "Waiting ~90s for redeploys, then re-registering..."
sleep 90
for url in "${WORKER_URLS[@]}"; do
  if curl -fsS --max-time 25 -X PUT "$url" >/dev/null 2>&1; then
    say "  re-registered: $url"
  else
    say "  !! PUT $url failed — redeploy may still be in flight; re-run with --verify shortly"
  fi
done

# -----------------------------------------------------------------------------
# 6. Verify
# -----------------------------------------------------------------------------
verify_all
say ""
if (( ${#FAILED_WORKERS[@]} > 0 )); then
  say "!! These workers need a MANUAL Coolify key update + redeploy:"
  for h in "${FAILED_WORKERS[@]}"; do say "     - $h"; done
  say "   (open the gitignored ${OPS_ENV} to copy the new values into Coolify)."
  say ""
fi
say "Rotation done. If any worker shows '!! not https+connected', wait for its"
say "redeploy to finish and re-run:  ./scripts/rotate-inngest-keys.sh --verify"
