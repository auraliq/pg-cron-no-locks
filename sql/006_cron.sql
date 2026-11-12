-- Schedules. Skipped silently if pg_cron is not available (e.g. a plain local
-- Postgres). On Supabase, enable pg_cron under Database > Extensions first.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('dialer-round',          '* * * * *', 'select dialer_round(15, 5)');
    perform cron.schedule('retry-pending-results', '* * * * *', 'select retry_pending_results()');
  else
    raise notice 'pg_cron not available: jobs not scheduled';
  end if;
end $$;

-- Note: pg_cron runs at most one instance of a given job at a time; a run that
-- would overlap is queued until the previous one finishes. The advisory lock in
-- dialer_round() is a second line of defense, not the only one.
