#!/usr/bin/env bash
# env-manifest.sh <env-file>: print one "NAME <sha256 of the line>" per assignment, or
# "ABSENT" when the file does not exist. Values never leave this script; only their hashes
# do, so install.sh can compare a laptop's .env with the VPS's without either being shown
# (HOMEINFRA-229). Runs locally and, piped over ssh (`bash -s -- <file>`), on the VPS.
set -euo pipefail
set +x

f="${1:?usage: env-manifest.sh <env-file>}"
if [[ ! -e "$f" ]]; then echo ABSENT; exit 0; fi
[[ -r "$f" ]] || { echo "UNREADABLE"; exit 0; }

if command -v sha256sum >/dev/null 2>&1; then h() { sha256sum | cut -c1-64; }
elif command -v shasum >/dev/null 2>&1; then h() { shasum -a 256 | cut -c1-64; }
else h() { openssl dgst -sha256 -r | cut -c1-64; }
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
  printf '%s %s\n' "${line%%=*}" "$(printf '%s' "${line#*=}" | h)"
done <"$f"
