#!/usr/bin/env bash
# Nightly run-history retention (Inngest's self-hosting runbook, see pg-retention.sql).
# Installed on the VPS by remote-bootstrap.sh:
#   30 3 * * * /opt/inngest/scripts/pg-retention.sh >> /var/log/inngest-pg-retention.log 2>&1
# Runs after the 03:00 backup, so the last backup still holds what this deletes.

set -euo pipefail

cd /opt/inngest

# Keep 14 days of finished runs. The runbook's default is 30; this is a 2 GB box, and
# deletion is status-gated, so nothing in flight is ever removed at any window.
DAYS=14
BATCH=5000

psql_inngest() { docker compose exec -T postgres psql -U inngest -d inngest -v ON_ERROR_STOP=1 "$@"; }

# The runbook's indexes on the gating columns (once; CONCURRENTLY, so writes are not
# blocked; each must run outside a transaction).
for ddl in \
  "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_trace_runs_status_ended_at ON trace_runs (status, ended_at)" \
  "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_function_finishes_created_at ON function_finishes (created_at)" \
  "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_traces_run_id ON traces (run_id)"; do
  psql_inngest -q -c "$ddl"
done

# Children before their anchor, in the runbook's order. Each statement repeats until it
# deletes 0 rows, with a short pause so the batches never hold locks for long.
for step in spans traces event_batches trace_runs history function_runs function_finishes events; do
  total=0
  while :; do
    # Not -q: quiet mode suppresses the "DELETE n" tag the loop counts.
    out=$(psql_inngest -v days="$DAYS" -v batch="$BATCH" -v step="$step" -f - < scripts/pg-retention.sql)
    n=$(printf '%s\n' "$out" | sed -n 's/^DELETE \([0-9][0-9]*\)$/\1/p' | tail -1)
    n=${n:-0}
    total=$((total + n))
    [ "$n" -eq 0 ] && break
    sleep 1
  done
  echo "$(date -u +%FT%TZ) ${step}: deleted ${total}"
done

psql_inngest -q -c "VACUUM (ANALYZE)"
echo "$(date -u +%FT%TZ) retention done (finished runs older than ${DAYS} days)"
