#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/aws.sh"

if aws_require_session; then
  aws_show_identity
  exit 0
fi

cat <<EOF
No AWS credentials yet.

  aws login

Then:

  ./scripts/up.sh

EOF
exit 1
