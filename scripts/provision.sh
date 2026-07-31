#!/usr/bin/env bash
# AWS Lightsail + Inngest deploy.
#
#   ./scripts/provision.sh              # terraform apply + install stack
#   ./scripts/provision.sh --destroy    # tear down AWS resources
#   ./scripts/provision.sh --install    # skip terraform, re-run install only
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${ROOT}/terraform/aws"
TFVARS="${TF_DIR}/terraform.tfvars"

# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/aws.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"

aws_require_session >/dev/null

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing: $1 — run: ./scripts/prereqs.sh"
    exit 1
  }
}

ensure_tfvars() {
  if [[ -f "$TFVARS" ]]; then
    return
  fi

  local pub="${HOME}/.ssh/id_ed25519.pub"
  [[ -f "$pub" ]] || pub="$(ls "${HOME}/.ssh/"*.pub 2>/dev/null | head -1)"

  if [[ -z "${pub:-}" || ! -f "$pub" ]]; then
    echo "No SSH public key. Run: ssh-keygen -t ed25519"
    exit 1
  fi

  local my_ip domain
  my_ip="0.0.0.0/0"
  if command -v curl >/dev/null 2>&1; then
    my_ip="$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)/32" || my_ip="0.0.0.0/0"
  fi
  domain="$(inngest_domain)"

  cat >"$TFVARS" <<EOF
aws_region          = "us-east-1"
availability_zone   = "us-east-1a"
instance_name       = "inngest"
bundle_id           = "small_2_0"
ssh_public_key_path = "${pub}"
admin_cidr          = ["${my_ip}"]
inngest_domain      = "${domain}"
EOF
  echo "Wrote ${TFVARS}"
}

wait_for_ssh() {
  local host="$1"
  echo "Waiting for SSH on ${host}..."
  for i in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" "$host" "echo ok" >/dev/null 2>&1; then
      echo "SSH ready."
      return 0
    fi
    if (( i % 6 == 0 )); then
      echo "  still waiting (${i}/60)..."
    fi
    sleep 10
  done
  echo "SSH timeout — check admin_cidr in terraform/aws/terraform.tfvars matches your IP."
  echo "Retry: ./scripts/provision.sh --install"
  exit 1
}

terraform_apply() {
  need terraform
  need aws
  aws_require_session || {
    echo "AWS session expired. Run: aws login"
    exit 1
  }

  ensure_tfvars
  cd "$TF_DIR"
  terraform init -input=false
  terraform apply -auto-approve -input=false
}

terraform_destroy() {
  need terraform
  need aws
  aws_require_session || {
    echo "AWS session expired. Run: aws login"
    exit 1
  }
  [[ -f "$TFVARS" ]] || {
    echo "No ${TFVARS} — nothing to destroy"
    exit 1
  }
  cd "$TF_DIR"
  terraform init -input=false
  terraform destroy -auto-approve -input=false
  rm -f "${ROOT}/.setup.local"
  echo "Destroyed."
}

get_ip() {
  cd "$TF_DIR"
  terraform output -raw static_ip
}

print_done() {
  local ip="$1"
  local domain base
  domain="$(inngest_domain)"
  base="$(inngest_base_url)"

  cat <<EOF

Done.

  IP:     ${ip}
  DNS:    ${domain}  A  ${ip}  (grey-cloud recommended for auto TLS)
  Health: curl -fsS ${base}/health

  Worker env for your apps:
    ./scripts/install.sh --print-env

  Register workers:
    ./scripts/sync-apps.sh

EOF
}

case "${1:-}" in
  --destroy)
    terraform_destroy
    exit 0
    ;;
  --install)
    IP=""
    if [[ -f "${ROOT}/.setup.local" ]]; then
      # shellcheck disable=SC1090
      source "${ROOT}/.setup.local"
      IP="${INNGEST_LIGHTSAIL_IP:-}"
    fi
    IP="${IP:-$(get_ip 2>/dev/null || true)}"
    [[ -n "$IP" ]] || {
      echo "No IP — run ./scripts/provision.sh first"
      exit 1
    }
    QUIET=1 "${ROOT}/scripts/install.sh" "$IP"
    print_done "$IP"
    exit 0
    ;;
  -h | --help)
    sed -n '2,10p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown: $1 (try --help)"
    exit 1
    ;;
esac

terraform_apply
IP="$(get_ip)"
HOST="ubuntu@${IP}"

wait_for_ssh "$HOST"
QUIET=1 "${ROOT}/scripts/install.sh" "$IP"
print_done "$IP"
