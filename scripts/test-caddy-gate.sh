#!/usr/bin/env bash
# =============================================================================
# test-caddy-gate.sh — prove the Caddyfile's auth gate (HOMEINFRA-195, FACT-1675)
#
# Runs the real Caddyfile in caddy:2-alpine against a stub upstream named `inngest`
# (python, answers on 8288 and 8289 with "<port> <path> auth=<present|absent>"), then
# curls a matrix: operator surfaces (/, /v0/gql, /invoke, /debug, /metrics, /mcp) must
# refuse anonymous callers; SDK/worker routes must reach the upstream untouched.
# Runs twice: with credentials set, and with them unset (must be closed, not open).
#
# Needs only docker + curl. Credentials are random per run and never printed.
#   ./scripts/test-caddy-gate.sh
# =============================================================================
set -euo pipefail
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
PY_IMAGE="${PY_IMAGE:-python:3-alpine}"
PORT="${GATE_TEST_PORT:-18080}"
UI_PORT="${GATE_TEST_UI_PORT:-18081}"
NET="caddy-gate-test-$$"
TMP="$(mktemp -d)"
umask 077

cleanup() {
  rc=$?
  docker rm -f "${NET}-caddy" "${NET}-inngest" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

for bin in docker curl openssl; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done

# Test-only credentials (random, discarded with $TMP).
export INNGEST_SIGNING_KEY; INNGEST_SIGNING_KEY="$(openssl rand -hex 32)"
export INNGEST_MCP_BEARER; INNGEST_MCP_BEARER="$(openssl rand -hex 24)"
export INNGEST_DASHBOARD_USER="operator"
DASH_PASS="$(openssl rand -hex 16)"
export INNGEST_DASHBOARD_HASH
INNGEST_DASHBOARD_HASH="$(docker run --rm "$CADDY_IMAGE" caddy hash-password --plaintext "$DASH_PASS")"
printf 'Authorization: Bearer %s\n' "$INNGEST_SIGNING_KEY" >"${TMP}/bearer.hdr"
printf 'Authorization: Bearer %s\n' "$INNGEST_MCP_BEARER" >"${TMP}/mcp-bearer.hdr"
printf 'Authorization: Bearer %s\n' "wrong-$(openssl rand -hex 8)" >"${TMP}/wrong-bearer.hdr"
# The SDK form of the same key. The gate compares the raw hex, so callers strip the prefix
# (factory inngest-runs.ts and verify-sweep, niche-fleet inngest-registration.ts).
printf 'Authorization: Bearer signkey-prod-%s\n' "$INNGEST_SIGNING_KEY" >"${TMP}/prefixed-bearer.hdr"
printf 'Authorization: Bearer %s\n' "unset-inngest-signing-key-denies-all" >"${TMP}/sentinel-bearer.hdr"
printf 'Authorization: Bearer %s\n' "unset-inngest-mcp-bearer-denies-all" >"${TMP}/sentinel-mcp-bearer.hdr"
printf 'user = "%s:%s"\n' "$INNGEST_DASHBOARD_USER" "$DASH_PASS" >"${TMP}/basic.curlrc"
printf 'user = "%s:%s"\n' "$INNGEST_DASHBOARD_USER" "wrong" >"${TMP}/wrong-basic.curlrc"
printf 'user = "%s:%s"\n' "unset-dashboard-user-denies-all" "x" >"${TMP}/sentinel-basic.curlrc"

cat >"${TMP}/stub.py" <<'PY'
import http.server, socketserver, threading
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        port = self.server.server_address[1]
        auth = "present" if self.headers.get("Authorization") else "absent"
        up = (self.headers.get("Upgrade") or "none").lower()
        jwt = "present" if self.headers.get("Cf-Access-Jwt-Assertion") else "absent"
        cookie = "present" if self.headers.get("Cookie") else "absent"
        body = f"{port} {self.path} auth={auth} upgrade={up} jwt={jwt} cookie={cookie}".encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = do_PUT = do_DELETE = _r
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
for p in (8288, 8289):
    threading.Thread(target=S(("0.0.0.0", p), H).serve_forever, daemon=True).start()
threading.Event().wait()
PY

docker network create "$NET" >/dev/null
docker run -d --name "${NET}-inngest" --network "$NET" --network-alias inngest \
  -v "${TMP}/stub.py:/stub.py:ro" "$PY_IMAGE" python /stub.py >/dev/null

PASS=0; FAIL=0
check() {  # check <want-code> <want-body-prefix|-> <label> <curl args...>
  local want="$1" wantbody="$2" label="$3"; shift 3
  local out code body
  out="$(curl -sS -o "${TMP}/body" -w '%{http_code}' --max-time 10 "$@" || echo 000)"
  code="$out"; body="$(cat "${TMP}/body" 2>/dev/null || true)"
  if [[ "$code" == "$want" && ( "$wantbody" == "-" || "$body" == "$wantbody"* ) ]]; then
    PASS=$((PASS+1)); printf '  ok   %-3s %s\n' "$code" "$label"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %-3s %s (want %s %s, got body: %.80s)\n' "$code" "$label" "$want" "$wantbody" "$body"
  fi
}

start_caddy() {  # start_caddy <env args...>
  docker rm -f "${NET}-caddy" >/dev/null 2>&1 || true
  docker run --rm --network "$NET" -v "${ROOT}/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -e INNGEST_DOMAIN="http://:8080" "$@" "$CADDY_IMAGE" \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"${TMP}/validate.log" 2>&1 \
    || { cat "${TMP}/validate.log"; echo "caddy validate FAILED"; exit 1; }
  echo "  ok   caddy validate"
  docker run -d --name "${NET}-caddy" --network "$NET" -p "127.0.0.1:${PORT}:8080" -p "127.0.0.1:${UI_PORT}:8081" \
    -v "${ROOT}/Caddyfile:/etc/caddy/Caddyfile:ro" -e INNGEST_DOMAIN="http://:8080" "$@" \
    "$CADDY_IMAGE" >/dev/null
  for _ in $(seq 1 50); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT}/health" && return 0
    sleep 0.2
  done
  docker logs "${NET}-caddy" | tail -20; echo "caddy did not start"; exit 1
}

B="http://127.0.0.1:${PORT}"
U="http://127.0.0.1:${UI_PORT}"
JWT=(-H 'Cf-Access-Jwt-Assertion: test.jwt.value')
GQL=(-X POST -H 'Content-Type: application/json' --data '{"query":"{ apps { name } }"}')

sdk_matrix() {
  check 200 "8288 /e/" "event ingest   POST /e/key"            -X POST "$B/e/somekey"
  check 200 "8288 /fn/register" "app sync  POST /fn/register" -X POST "$B/fn/register"
  check 200 "8288 /api/v2/apps" "api v2   GET /api/v2/apps"    "$B/api/v2/apps"
  check 200 "8288 /v2/apps" "api v2 alias GET /v2/apps"        "$B/v2/apps"
  check 200 "8288 /v1/events" "api v1   GET /v1/events"        "$B/v1/events"
  check 200 "8288 /v1/checkpoint/r/steps" "checkpoint POST /v1/checkpoint/r/steps" -X POST "$B/v1/checkpoint/r/steps"
  check 200 "8288 /v0/runs/r/batch" "large payload GET /v0/runs/r/batch" "$B/v0/runs/r/batch"
  check 200 "8288 /v0/runs/r/actions" "large payload GET /v0/runs/r/actions" "$B/v0/runs/r/actions"
  check 200 "8288 /v0/telemetry" "sdk telemetry POST /v0/telemetry" -X POST "$B/v0/telemetry"
  check 200 "8288 /v0/connect/start" "connect start POST /v0/connect/start" -X POST "$B/v0/connect/start"
  check 200 "8289 /v0/connect" "connect gateway GET /v0/connect (-> 8289)" "$B/v0/connect"
  # What a Connect worker actually sends (HOMEINFRA-229): the upgrade must reach the gateway.
  check 200 "8289 /v0/connect auth=absent upgrade=websocket" "connect WebSocket upgrade reaches 8289" \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$B/v0/connect"
  check 200 "8288 /v0/connect/flush" "connect flush POST /v0/connect/flush" -X POST "$B/v0/connect/flush"
  check 200 "8288 /fn/remove" "app remove POST /fn/remove"   -X POST "$B/fn/remove"
  check 200 "8288 /v0/runs/r" "run cancel DELETE /v0/runs/r" -X DELETE "$B/v0/runs/r"
  check 200 "8288 /health" "health   GET /health"            "$B/health"
  check 200 "8288 /dev" "dev info  GET /dev"                    "$B/dev"
  check 200 "8288 /dev/traces" "otlp     POST /dev/traces"      -X POST "$B/dev/traces"
  check 200 "8288 /fn/register auth=present" "sdk Authorization reaches upstream" \
    -X POST -H "Authorization: Bearer signkey-test" "$B/fn/register"
}

# The Access-protected dashboard listener (HOMEINFRA-233): cloudflared -> caddy:8081. Access
# signs what it lets through; no assertion means the hostname was published unprotected.
ui_matrix() {
  check 403 - "ui: no Access JWT GET /"                          "$U/"
  check 403 - "ui: no Access JWT POST /v0/gql"                   "${GQL[@]}" "$U/v0/gql"
  check 403 - "ui: basic auth is not a way in (no JWT)"          -K "${TMP}/basic.curlrc" "$U/"
  check 403 - "ui: signing-key bearer is not a way in (no JWT)"  -H @"${TMP}/bearer.hdr" "$U/"
  check 200 "8288 / auth=absent" "ui: JWT GET / (dashboard)"     "${JWT[@]}" "$U/"
  check 200 "8288 / auth=absent upgrade=none jwt=absent cookie=absent" \
    "ui: Access JWT, CF_Authorization cookie and Authorization never reach inngest" \
    "${JWT[@]}" -H 'Cookie: CF_Authorization=test.jwt.value' -H @"${TMP}/bearer.hdr" "$U/"
  check 200 "8288 /runs" "ui: JWT GET /runs (SPA route)"         "${JWT[@]}" "$U/runs"
  check 200 "8288 /assets/x.js" "ui: JWT GET /assets/x.js"       "${JWT[@]}" "$U/assets/x.js"
  check 200 "8288 /v0/gql auth=absent" "ui: JWT POST /v0/gql (same origin)" "${GQL[@]}" "${JWT[@]}" "$U/v0/gql"
  check 200 "8288 /v0/gql auth=absent" "ui: JWT + Authorization POST /v0/gql (stripped)" \
    "${GQL[@]}" "${JWT[@]}" -H @"${TMP}/bearer.hdr" "$U/v0/gql"
  check 200 "8288 /v0 " "ui: JWT GET /v0 (playground)"           "${JWT[@]}" "$U/v0"
  check 200 "8288 /mcp/setup" "ui: JWT GET /mcp/setup (SPA page)" "${JWT[@]}" "$U/mcp/setup"
  check 200 "8288 /api/v2/operations" "ui: JWT GET /api/v2/operations" "${JWT[@]}" "$U/api/v2/operations"
  check 200 "8288 /v0/telemetry" "ui: JWT POST /v0/telemetry"   -X POST "${JWT[@]}" "$U/v0/telemetry"
  check 200 "8288 /dev " "ui: JWT GET /dev"                      "${JWT[@]}" "$U/dev"
  check 404 - "ui: JWT POST /mcp (MCP server stays on the API host)" -X POST "${JWT[@]}" "$U/mcp"
  check 404 - "ui: JWT GET /debug/pprof/"                        "${JWT[@]}" "$U/debug/pprof/"
  check 404 - "ui: JWT GET /metrics"                             "${JWT[@]}" "$U/metrics"
  check 404 - "ui: JWT POST /e/key (events stay on the API host)" -X POST "${JWT[@]}" "$U/e/somekey"
  check 404 - "ui: JWT POST /fn/register"                        -X POST "${JWT[@]}" "$U/fn/register"
  check 404 - "ui: JWT GET /v0/connect (no WebSocket here)"     "${JWT[@]}" "$U/v0/connect"
  check 404 - "ui: JWT GET /v0/runs/r/batch"                     "${JWT[@]}" "$U/v0/runs/r/batch"
  check 404 - "ui: JWT GET /v1/events"                           "${JWT[@]}" "$U/v1/events"
  check 404 - "ui: JWT POST /dev/traces"                         -X POST "${JWT[@]}" "$U/dev/traces"
}

echo "== credentials SET =="
start_caddy -e INNGEST_SIGNING_KEY -e INNGEST_MCP_BEARER -e INNGEST_DASHBOARD_USER -e INNGEST_DASHBOARD_HASH
check 401 - "anonymous  POST /v0/gql query"                 "${GQL[@]}" "$B/v0/gql"
check 401 - "anonymous  GET  /v0/gql/"                      "$B/v0/gql/"
check 401 - "anonymous  GET  /v0/gql query"                --get --data-urlencode 'query={ apps { name } }' "$B/v0/gql"
check 401 - "anonymous  GET  /v0/gql bare"                 "$B/v0/gql"
check 401 - "wrong bearer POST /v0/gql"                     "${GQL[@]}" -H @"${TMP}/wrong-bearer.hdr" "$B/v0/gql"
check 401 - "public sentinel bearer POST /v0/gql"           "${GQL[@]}" -H @"${TMP}/sentinel-bearer.hdr" "$B/v0/gql"
check 401 - "wrong basic POST /v0/gql"                      "${GQL[@]}" -K "${TMP}/wrong-basic.curlrc" "$B/v0/gql"
check 401 - "MCP bearer POST /v0/gql (signing key only)"     "${GQL[@]}" -H @"${TMP}/mcp-bearer.hdr" "$B/v0/gql"
check 401 - "signkey-prod- prefixed bearer POST /v0/gql (raw hex only)" "${GQL[@]}" -H @"${TMP}/prefixed-bearer.hdr" "$B/v0/gql"
check 200 "8288 /v0/gql auth=absent" "signing-key bearer POST /v0/gql (credential stripped)" "${GQL[@]}" -H @"${TMP}/bearer.hdr" "$B/v0/gql"
check 200 "8288 /v0/gql auth=absent" "basic  POST /v0/gql (credential stripped)" "${GQL[@]}" -K "${TMP}/basic.curlrc" "$B/v0/gql"
check 401 - "anonymous  GET  / (dashboard)"                 "$B/"
check 200 "8288 / auth=absent" "basic GET / (dashboard)"   -K "${TMP}/basic.curlrc" "$B/"
check 200 "8288 /assets/x.js" "basic GET /assets/x.js"      -K "${TMP}/basic.curlrc" "$B/assets/x.js"
check 401 - "anonymous  GET  /runs (SPA route)"             "$B/runs"
check 401 - "anonymous  GET  /v0 (gql playground)"          "$B/v0"
check 401 - "anonymous  POST /invoke/fn (unauth invoke)"    -X POST "$B/invoke/fn"
check 401 - "anonymous  GET  /debug/pprof/"                 "$B/debug/pprof/"
check 401 - "anonymous  GET  /metrics"                      "$B/metrics"
check 200 "8288 /metrics auth=absent" "signing-key bearer GET /metrics" -H @"${TMP}/bearer.hdr" "$B/metrics"
check 401 - "anonymous  GET  /invoke/fn"                    "$B/invoke/fn"
check 401 - "anonymous  GET  /debug/pprof/profile"          "$B/debug/pprof/profile?seconds=1"
check 401 - "anonymous  GET  /v0/connectx (not a prefix)"   "$B/v0/connectx"
check 401 - "anonymous  GET  /healthz (only /health)"       "$B/healthz"
check 401 - "anonymous  GET  /e (no key)"                   "$B/e"
check 401 - "anonymous  GET  /api/v1/x (SPA fallback)"      "$B/api/v1/x"
check 401 - "anonymous  POST /mcp"                          -X POST "$B/mcp"
check 401 - "public sentinel bearer POST /mcp"              -X POST -H @"${TMP}/sentinel-mcp-bearer.hdr" "$B/mcp"
check 401 - "signing-key bearer POST /mcp (MCP bearer only)" -X POST -H @"${TMP}/bearer.hdr" "$B/mcp"
check 401 - "basic auth POST /mcp (bearer only)"            -X POST -K "${TMP}/basic.curlrc" "$B/mcp"
check 200 "8288 /mcp auth=present" "MCP bearer POST /mcp"   -X POST -H @"${TMP}/mcp-bearer.hdr" "$B/mcp"
sdk_matrix
ui_matrix

echo "== credentials UNSET (must be closed) =="
start_caddy -e INNGEST_SIGNING_KEY= -e INNGEST_MCP_BEARER= -e INNGEST_DASHBOARD_USER= -e INNGEST_DASHBOARD_HASH=
check 401 - "anonymous  POST /v0/gql query"                 "${GQL[@]}" "$B/v0/gql"
check 401 - "anonymous  GET  /v0/gql query"                --get --data-urlencode 'query={ apps { name } }' "$B/v0/gql"
check 401 - "anonymous  GET  /v0/gql bare"                 "$B/v0/gql"
check 401 - "public sentinel bearer POST /v0/gql"           "${GQL[@]}" -H @"${TMP}/sentinel-bearer.hdr" "$B/v0/gql"
check 401 - "'Bearer ' (empty) POST /v0/gql"                "${GQL[@]}" -H 'Authorization: Bearer ' "$B/v0/gql"
check 401 - "sentinel basic user GET /"                     -K "${TMP}/sentinel-basic.curlrc" "$B/"
check 401 - "public sentinel bearer POST /mcp"              -X POST -H @"${TMP}/sentinel-mcp-bearer.hdr" "$B/mcp"
check 401 - "'Bearer ' (empty) POST /mcp"                   -X POST -H 'Authorization: Bearer ' "$B/mcp"
sdk_matrix
ui_matrix

echo "== docker compose passes a single-quoted bcrypt hash through literally =="
# `compose config` prints a literal $ re-escaped as $$, so undo that before comparing.
mkdir -p "${TMP}/compose"
cp "${ROOT}/docker-compose.yml" "${TMP}/compose/"
printf "INNGEST_DASHBOARD_HASH='%s'\n" "$INNGEST_DASHBOARD_HASH" >"${TMP}/compose/.env"
got="$(cd "${TMP}/compose" && docker compose config --format json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["caddy"]["environment"]["INNGEST_DASHBOARD_HASH"].replace("$$", "$"))')"
if [[ "$got" == "$INNGEST_DASHBOARD_HASH" ]]; then PASS=$((PASS+1)); echo "  ok   compose hash intact"
else FAIL=$((FAIL+1)); echo "  FAIL compose mangled the hash (\$ interpolation?)"; fi

echo "== compose: the dashboard listener is reachable only through the tunnel (HOMEINFRA-233) =="
printf 'CLOUDFLARE_TUNNEL_TOKEN=test-token-not-real\n' >"${TMP}/compose/.env"
cfg="$(cd "${TMP}/compose" && docker compose --profile dashboard-access config --format json 2>/dev/null)"
plain="$(cd "${TMP}/compose" && docker compose config --format json 2>/dev/null)"
if python3 -c '
import json, sys
c = json.loads(sys.argv[1]); p = json.loads(sys.argv[2])
caddy_ports = {int(x["target"]) for x in c["services"]["caddy"].get("ports", [])}
cf = c["services"]["cloudflared"]
assert caddy_ports == {80, 443}, f"caddy publishes {sorted(caddy_ports)}; 8081 must stay internal"
assert not cf.get("ports"), "cloudflared must publish nothing"
assert cf["environment"]["TUNNEL_TOKEN"] == "test-token-not-real", "token not passed through"
assert "cloudflared" not in p["services"], "cloudflared must be profile-gated"
' "$cfg" "$plain"; then PASS=$((PASS+1)); echo "  ok   8081 unpublished, cloudflared profile-gated, token passed"
else FAIL=$((FAIL+1)); echo "  FAIL compose exposure check"; fi

echo "== ${PASS} passed, ${FAIL} failed =="
[[ "$FAIL" == 0 ]]
