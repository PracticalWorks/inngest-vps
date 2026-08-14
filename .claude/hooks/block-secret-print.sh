#!/usr/bin/env bash
# PreToolUse(Bash) guard — block commands that PRINT secret values into the
# terminal and therefore into the transcript.
#
# The distinction that makes this usable: READING, copying and editing secret
# files is allowed. Only dumping their VALUES to stdout is blocked. A guard that
# forbade touching them at all would be turned off within a day.
#
# Protocol: the tool call arrives as JSON on stdin. Exit 2 = BLOCK (stderr is
# shown to the agent). Exit 0 = allow. Any internal error allows — fail-open, so
# a bug here can never brick the shell.
#
# Shipped as a TEMPLATE. Copy it to .claude/hooks/ alongside the settings file
# and commit both. Tune SECRET_FILE below to whatever your repo actually holds.
set -uo pipefail

input="$(cat 2>/dev/null)" || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -z "${cmd:-}" ] && exit 0

low="$(printf '%s' "$cmd" | tr 'A-Z' 'a-z')"
block() { printf 'BLOCKED by secret-print guard: %s\n' "$1" >&2; exit 2; }

# Files whose CONTENTS are sensitive (matched case-insensitively).
SECRET_FILE='(\.env([./][a-z0-9._-]+)?|\.setup\.local|[a-z0-9._/-]*\.tfvars|[a-z0-9._/-]*\.pem|[a-z0-9._/-]*(secret|credential|passwd|password)[a-z0-9._/-]*|[a-z0-9._/-]*service[-_]?account[a-z0-9._/-]*\.json|id_(rsa|ed25519|ecdsa)([^.a-z]|$))'

# Reads that DON'T expose values, which make an otherwise-risky command safe.
is_redirected() { printf '%s' "$cmd" | grep -Eq '>>?[[:space:]]*[^&[:space:]]'; }
is_redacted()   { printf '%s' "$low" | grep -Eq '<(hidden|redacted)>|s/=[.][*]|s#=[.][*]|-f1|\$\{#'; }

# *.example/.sample/.template/.dist/.md are templates, not secrets.
touches_secret_file() {
  local scrubbed
  scrubbed="$(printf '%s' "$low" | sed -E 's/[a-z0-9._/-]*\.(example|sample|template|dist|md)([[:space:]]|$)/ /g')"
  printf '%s' "$scrubbed" | grep -Eq "$SECRET_FILE"
}

# 1) Whole-environment dumps.
if printf '%s' "$low" | grep -Eq '(^|[;&|(][[:space:]]*)(env|printenv)([[:space:]]*$|[[:space:]]*[;&|)])'; then
  block "'env'/'printenv' can dump every env value. Reference vars by NAME, or check one: [ -n \"\$VAR\" ] && echo set (len \${#VAR})."
fi

# 2) echo/printf expanding a SECRET-looking variable straight to stdout.
if printf '%s' "$low" | grep -Eq '\b(echo|printf)\b[^>]*\$\{?[a-z_]*(secret|token|passwd|password|signing|api[_-]?key|[_-]key|cred)'; then
  is_redacted || block "this prints a secret-looking variable's value. Print only length: echo \"len=\${#VAR}\"."
fi

# 3) Pagers/dumpers on a secret file (allowed when redirected to a file).
if printf '%s' "$low" | grep -Eq '\b(cat|bat|less|more|head|tail|xxd|od|hexdump|strings|nl|tac|rev)\b' && touches_secret_file; then
  is_redirected || block "this prints secret-file contents to the terminal. Reads are fine — redirect to a file (> out), check length (wc -c), or redact (sed 's/=.*/=<hidden>/')."
fi

# 4) grep/sed/awk over a secret file that would print matching lines or values.
if printf '%s' "$low" | grep -Eq '\b(grep|egrep|fgrep|rg|ag|ack|sed|awk|perl|cut)\b' && touches_secret_file; then
  if printf '%s' "$low" | grep -Eq '\bgrep\b[^|;]*[[:space:]]-[a-z]*[cqlL]'; then :   # grep -c/-q/-l: counts/names only
  elif is_redacted; then :
  elif is_redirected; then :
  else block "grep/sed/awk over a secret file prints values. Use grep -c/-q/-l, redact (sed 's/=.*/=<hidden>/'), or redirect to a file."
  fi
fi

exit 0
