#!/usr/bin/env bash
# Runs ON the Lightsail VPS (called by install.sh over SSH).
set -euo pipefail

cd /opt/inngest

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

mkdir -p backups scripts

dc() {
  if docker info >/dev/null 2>&1; then
    docker compose "$@"
  else
    sudo docker compose "$@"
  fi
}

dc pull
dc up -d
dc exec -T inngest inngest alpha doctor healthcheck

echo "Stack is up on this host."
