-- Status-gated run history retention, from Inngest's self-hosting runbook
-- (inngest/inngest docs/POSTGRES_RETENTION.md, #4357). Self-hosted Inngest never
-- truncates run history, so these tables grow without bound and the runs list slows.
-- A run's data is deleted only once the run reached a terminal status AND finished more
-- than :days ago: in-flight runs (debounce, waitForEvent, retries) are never touched.
-- Children before their anchor. Each statement deletes at most :batch rows; the wrapper
-- (pg-retention.sh) repeats each until it deletes 0.
-- psql variables: days, batch, step.

\if :{?step}
\else
  \echo 'pg-retention.sql: set -v step=<name>'
  \quit
\endif

SELECT :'step' = 'spans' AS do_spans, :'step' = 'traces' AS do_traces, :'step' = 'event_batches' AS do_event_batches,
       :'step' = 'trace_runs' AS do_trace_runs, :'step' = 'history' AS do_history, :'step' = 'function_runs' AS do_function_runs,
       :'step' = 'function_finishes' AS do_function_finishes, :'step' = 'events' AS do_events \gset

\if :do_spans
DELETE FROM spans WHERE ctid IN (
  SELECT s.ctid FROM spans s WHERE s.run_id IN (
    SELECT run_id FROM trace_runs WHERE status IN (50,300,400,500,600)
      AND ended_at < (extract(epoch FROM now()) * 1000 - :days * 86400000)::bigint)
  LIMIT :batch);
\elif :do_traces
DELETE FROM traces WHERE ctid IN (
  SELECT t.ctid FROM traces t WHERE t.run_id IN (
    SELECT run_id FROM trace_runs WHERE status IN (50,300,400,500,600)
      AND ended_at < (extract(epoch FROM now()) * 1000 - :days * 86400000)::bigint)
  LIMIT :batch);
\elif :do_event_batches
DELETE FROM event_batches WHERE ctid IN (
  SELECT eb.ctid FROM event_batches eb WHERE eb.run_id IN (
    SELECT run_id FROM trace_runs WHERE status IN (50,300,400,500,600)
      AND ended_at < (extract(epoch FROM now()) * 1000 - :days * 86400000)::bigint)
  LIMIT :batch);
\elif :do_trace_runs
DELETE FROM trace_runs WHERE ctid IN (
  SELECT ctid FROM trace_runs WHERE status IN (50,300,400,500,600)
    AND ended_at < (extract(epoch FROM now()) * 1000 - :days * 86400000)::bigint
  LIMIT :batch);
\elif :do_history
DELETE FROM history WHERE ctid IN (
  SELECT h.ctid FROM history h WHERE h.run_id IN (
    SELECT run_id FROM function_finishes WHERE created_at < now() - make_interval(days => :days))
  LIMIT :batch);
\elif :do_function_runs
DELETE FROM function_runs WHERE ctid IN (
  SELECT fr.ctid FROM function_runs fr WHERE fr.run_id IN (
    SELECT run_id FROM function_finishes WHERE created_at < now() - make_interval(days => :days))
  LIMIT :batch);
\elif :do_function_finishes
DELETE FROM function_finishes WHERE ctid IN (
  SELECT ctid FROM function_finishes WHERE created_at < now() - make_interval(days => :days)
  LIMIT :batch);
\elif :do_events
DELETE FROM events WHERE ctid IN (
  SELECT e.ctid FROM events e
  WHERE e.received_at < now() - make_interval(days => :days)
    AND NOT EXISTS (
      SELECT 1 FROM function_runs fr
      LEFT JOIN function_finishes ff ON ff.run_id = fr.run_id
      WHERE fr.event_id = e.internal_id AND ff.run_id IS NULL)
  LIMIT :batch);
\else
  \echo 'pg-retention.sql: unknown step ' :'step'
  \quit
\endif
