#!/usr/bin/env bash
# AWS auth for solo operator: `aws login` or default `aws configure` profile.
set -euo pipefail

inngest_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

load_aws_env() {
  AWS_REGION="${AWS_REGION:-us-east-1}"
}

aws_clear_env_creds() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
}

# Terraform cannot read `aws login` cache — export resolved session to env vars.
aws_export_for_terraform() {
  local exports

  unset AWS_PROFILE
  exports="$(aws configure export-credentials --format env)" || return 1

  # shellcheck disable=SC1090
  eval "$exports"
  export AWS_REGION="${AWS_REGION:-us-east-1}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
}

aws_require_session() {
  load_aws_env
  aws_clear_env_creds

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    return 1
  fi

  aws_export_for_terraform
}

aws_show_identity() {
  echo "AWS:"
  aws sts get-caller-identity
}
