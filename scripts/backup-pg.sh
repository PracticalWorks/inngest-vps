#!/usr/bin/env bash
# Nightly Postgres backup. Install on VPS via cron:
#   0 3 * * * /opt/inngest/scripts/backup-pg.sh >> /var/log/inngest-pg-backup.log 2>&1

set -euo pipefail

cd /opt/inngest
mkdir -p backups
STAMP="$(date +%Y%m%d-%H%M%S)"
FILE="backups/inngest-${STAMP}.sql.gz"

docker compose exec -T postgres pg_dump -U inngest inngest | gzip > "$FILE"
find backups -name 'inngest-*.sql.gz' -mtime +14 -delete

echo "Wrote ${FILE} ($(du -h "$FILE" | cut -f1))"
