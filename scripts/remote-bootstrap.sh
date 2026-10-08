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

# Nightly jobs, installed idempotently (re-running replaces each job's line, never duplicates it).
chmod +x scripts/backup-pg.sh scripts/pg-retention.sh
# Root's crontab: the jobs run `docker compose`, and the login user is not in the docker
# group (and cannot write /var/log), so in its crontab both failed every night, silently
# (found 2026-10-08, FACT-1675: no backup log had ever been written).
ensure_cron() { # <script path> <cron line>: replaces any existing line for that script
  crontab -l 2>/dev/null | grep -vF "$1" | crontab - 2>/dev/null || true
  ( sudo crontab -l 2>/dev/null | grep -vF "$1" ; echo "$2" ) | sudo crontab -
}
ensure_cron /opt/inngest/scripts/backup-pg.sh "0 3 * * * /opt/inngest/scripts/backup-pg.sh >> /var/log/inngest-pg-backup.log 2>&1"
ensure_cron /opt/inngest/scripts/pg-retention.sh "30 3 * * * /opt/inngest/scripts/pg-retention.sh >> /var/log/inngest-pg-retention.log 2>&1"

echo "Stack is up on this host."
