#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/aws.sh"

for cmd in aws terraform rsync; do
  case "$cmd" in
    aws) command -v aws >/dev/null || brew install awscli ;;
    terraform) command -v terraform >/dev/null || brew install terraform ;;
    rsync) command -v rsync >/dev/null || brew install rsync ;;
  esac
done

if aws_require_session; then
  aws_show_identity
  echo "Ready: ./scripts/init.sh  then  ./scripts/up.sh"
  exit 0
fi

echo "Run: ./scripts/init.sh"
echo "Then: aws login && ./scripts/up.sh"
exit 1
