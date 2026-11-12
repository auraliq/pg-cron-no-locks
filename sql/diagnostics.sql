-- Queries used during the investigation. Run them in a SQL console.

-- 1. Which scheduled jobs are long? A job that lasts minutes and writes rows is a suspect.
select j.jobname,
       count(*)                                   as runs,
       round(avg(extract(epoch from d.end_time - d.start_time))) as avg_s,
       round(max(extract(epoch from d.end_time - d.start_time))) as max_s
  from cron.job_run_details d join cron.job j using (jobid)
 where d.start_time > now() - interval '7 days'
 group by 1 order by max_s desc;

-- 2. Who is blocking whom right now?
select a.pid, a.usename, a.wait_event_type, a.state,
       pg_blocking_pids(a.pid) as blocked_by,
       now() - a.xact_start    as xact_age,
       left(a.query, 80)       as query
  from pg_stat_activity a
 where cardinality(pg_blocking_pids(a.pid)) > 0;

-- 3. Which roles have timeouts configured? (the webhook's role timed out at its statement_timeout)
select rolname, rolconfig from pg_roles where rolconfig is not null;

-- 4. Long transactions holding locks (candidates for the culprit while a round runs).
select pid, now() - xact_start as xact_age, state, left(query, 80) as query
  from pg_stat_activity
 where xact_start is not null and now() - xact_start > interval '30 seconds'
 order by xact_age desc;

-- 5. Is the queue healthy?
select count(*) as pending, max(now() - created_at) as oldest from pending_results;
select * from alerts where is_open;

-- To count lock waits in the Postgres log, enable once:
--   alter system set log_lock_waits = on;  select pg_reload_conf();
-- and search the log for "still waiting for" / "acquired ... after".
