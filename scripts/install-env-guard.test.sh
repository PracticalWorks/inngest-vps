#!/usr/bin/env bash
# install.sh must not push a local .env that would delete or change a value the live VPS
# holds, and must not mint fresh keys over a box that already has them (HOMEINFRA-229).
# ssh and rsync are stubs: the "VPS" is a fixture file, so this needs no host or key.
#   ./scripts/install-env-guard.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# The guard runs env-manifest.sh on the VPS as `bash -s -- <remote .env>`; answer it
# from the fixture. Every other ssh call (mkdir, bootstrap) just succeeds.
for a in "$@"; do
  if [[ "$a" == "bash -s -- "* ]]; then exec bash -s -- "$FAKE_REMOTE_ENV"; fi
done
printf '%s\n' "$*" >>"$TEST_CALLS/ssh.calls"
EOF
cat >"$TMP/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_CALLS/rsync.calls"
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" TEST_CALLS="$TMP"

LIVE='INNGEST_DOMAIN=inngest.example.test
INNGEST_EVENT_KEY=ev-live-value-0001
INNGEST_SIGNING_KEY=sk-live-value-0002
PG_PASSWORD=pg-live-value-0003
INNGEST_MCP_BEARER=mcp-live-value-0004'

# run <label> <local .env content | __none__> <remote .env content | __none__> [env...]
run() {
  local label="$1" local_env="$2" remote_env="$3"; shift 3
  rm -rf "$TMP/repo" "$TMP"/*.calls
  cp -R "$ROOT" "$TMP/repo"
  rm -f "$TMP/repo/.env" "$TMP/repo/.setup.local"
  [[ "$local_env" == __none__ ]] || printf '%s\n' "$local_env" >"$TMP/repo/.env"
  export FAKE_REMOTE_ENV="$TMP/remote.env"
  rm -f "$FAKE_REMOTE_ENV"
  [[ "$remote_env" == __none__ ]] || printf '%s\n' "$remote_env" >"$FAKE_REMOTE_ENV"
  set +e
  OUT="$(cd "$TMP/repo" && env QUIET=1 "$@" bash scripts/install.sh 203.0.113.10 2>&1)"
  RC=$?
  set -e
  # No case may print a value, whatever its outcome.
  [[ "$OUT" != *"-value-"* ]] || fail "$label: output contains a secret value"
  echo "  ran  $label (rc=$RC)"
}
pushed_env() { grep -q '/.env' "$TMP/rsync.calls" 2>/dev/null; }
assert_refused() {  # <label> <name that must be named>
  [[ "$RC" != 0 ]] || fail "$1: expected a refusal, got rc=0"
  [[ "$OUT" == *"$2"* ]] || fail "$1: refusal does not name $2: $OUT"
  ! pushed_env || fail "$1: .env was pushed despite the refusal"
  [[ ! -f "$TMP/rsync.calls" ]] || fail "$1: rsync ran before the guard decided"
}
assert_pushed() {
  [[ "$RC" == 0 ]] || fail "$1: expected success, got rc=$RC: $OUT"
  pushed_env || fail "$1: .env was not pushed"
}

run "first install: no .env on the VPS" "$LIVE" __none__
assert_pushed "first install"

run "local .env matches the VPS" "$LIVE" "$LIVE"
assert_pushed "matching .env"

run "local .env lacks a name the VPS has" "$(grep -v MCP_BEARER <<<"$LIVE")" "$LIVE"
assert_refused "missing name" "INNGEST_MCP_BEARER: set on the VPS, missing locally"

run "local .env holds a different Postgres password" "$(sed 's/pg-live-value-0003/pg-stale-value-0009/' <<<"$LIVE")" "$LIVE"
assert_refused "changed value" "PG_PASSWORD: differs from the VPS"

run "no local .env, but the VPS has one" __none__ "$LIVE"
assert_refused "no local .env" "already has one"
[[ ! -f "$TMP/repo/.env" ]] || fail "no local .env: ensure_env minted new keys"

run "deliberate overwrite" "$(sed 's/pg-live-value-0003/pg-new-value-0010/' <<<"$LIVE")" "$LIVE" INSTALL_ENV_OVERWRITE=1
assert_pushed "INSTALL_ENV_OVERWRITE=1"

run "local .env adds the dashboard login" "$LIVE
INNGEST_DASHBOARD_USER=operator
INNGEST_DASHBOARD_HASH='\$2a\$14\$hash-value-0005'" "$LIVE"
assert_pushed "adding names"
[[ "$OUT" == *"adds: INNGEST_DASHBOARD_HASH INNGEST_DASHBOARD_USER"* ]] || fail "adds not reported: $OUT"

echo "install env guard tests passed"
