#!/usr/bin/env bash
# Configuration and mode guards for the deployment scripts (FACT-545).
# These tests use command stubs, so they never need Fly, Redis, Supabase, DNS, or SSH credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}
assert_not_called() {
  local command="$1"
  [[ ! -f "$TMP/${command}.called" ]] || fail "$command must not be called"
}

# Run a script with harmless stubs for external commands. A stub records calls and
# returns success, letting these tests prove which path was selected without deploying.
cat >"$TMP/flyctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALLS/flyctl.calls"
: >"$TEST_CALLS/flyctl.called"
EOF
cat >"$TMP/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALLS/ssh.calls"
: >"$TEST_CALLS/ssh.called"
exit 99
EOF
cat >"$TMP/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALLS/rsync.calls"
: >"$TEST_CALLS/rsync.called"
EOF
cat >"$TMP/terraform" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALLS/terraform.calls"
printf '203.0.113.10\n'
EOF
cat >"$TMP/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALLS/curl.calls"
printf '204\n'
EOF
chmod +x "$TMP"/*
export TEST_CALLS="$TMP"
export PATH="$TMP:$PATH"

# Work in a disposable copy because sync-apps.sh writes the generated config.
WORK="$TMP/repo"
cp -R "$ROOT" "$WORK"
mkdir -p "$WORK/.setup.local.d"
printf 'demo|https://worker.example/inngest\n' >"$WORK/sync-apps.conf"
printf '[fly]\n' >"$WORK/fly.toml"

run_sync() (
  cd "$WORK"
  FLY_APP_NAME=inngest-oss INNGEST_POSTGRES_URI='postgresql://db/inngest?sslmode=require&options=-c%20search_path%3Dinngest' \
    INNGEST_TARGET="$1" ./scripts/sync-apps.sh
)

fly_output="$(run_sync fly 2>&1)"
assert_contains "$fly_output" "deploy generated inngest.yaml to Fly app inngest-oss"
assert_not_called ssh
assert_not_called rsync
[[ -f "$TMP/flyctl.called" ]] || fail "Fly mode must invoke flyctl"

# An ambient Fly app must not redirect the default Lightsail mode. The SSH stub
# intentionally fails: reaching it proves the default chose Lightsail before any
# deployment command could be hidden behind a successful stub.
rm -f "$TMP/flyctl.called"
if (cd "$WORK" && INNGEST_TARGET=lightsail FLY_APP_NAME=ambient ./scripts/sync-apps.sh) >"$TMP/lightsail.out" 2>&1; then
  fail "Lightsail test unexpectedly succeeded"
fi
assert_contains "$(cat "$TMP/lightsail.out")" "→ rsync config"
assert_not_called flyctl

run_invalid_uri() (
  cd "$WORK"
  FLY_APP_NAME=inngest-oss INNGEST_POSTGRES_URI="$1" FLY_REDIS_URL=redis://redis.internal:6379 \
    INNGEST_EVENT_KEY=event INNGEST_SIGNING_KEY=signing ./scripts/up-fly.sh
)

rm -f "$TMP/flyctl.called"
if run_invalid_uri 'postgresql://db/inngest?sslmode=require&options=-c%20search_path%3Dapp' >"$TMP/schema.out" 2>&1; then
  schema_status=0
else
  schema_status=$?
fi
(( schema_status != 0 )) || fail "tenant schema app must fail before flyctl"
assert_contains "$(cat "$TMP/schema.out")" "must not target the tenant schema app"
assert_not_called flyctl

rm -f "$TMP/flyctl.called"
if run_invalid_uri 'postgresql://db/inngest?options=-c%20search_path%3Dinngest' >"$TMP/ssl.out" 2>&1; then
  ssl_status=0
else
  ssl_status=$?
fi
assert_not_called flyctl
(( ssl_status != 0 )) || fail "missing sslmode=require must fail before flyctl"
assert_contains "$(cat "$TMP/ssl.out")" "must include sslmode=require"

echo "deploy config tests passed"
