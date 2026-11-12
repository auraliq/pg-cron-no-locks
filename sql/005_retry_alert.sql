-- Fix, part 3: drain the queue every minute, and shout if it does not drain.
--
-- Each row is retried in its own sub-block, so one busy or bad row never blocks
-- the others. Rows are claimed with FOR UPDATE SKIP LOCKED so two overlapping
-- runs would not process the same row.
create or replace function retry_pending_results(
  p_max_queue int      default 10,
  p_max_age   interval default interval '15 minutes'
) returns int language plpgsql as $$
declare
  r       record;
  v_done  int := 0;
  v_n     int;
  v_age   interval;
begin
  perform set_config('lock_timeout', '200ms', true);

  for r in
    select id, payload from pending_results
     where next_try_at <= now()
     order by id
     limit 50
     for update skip locked
  loop
    begin
      perform _apply_result(r.payload);
      delete from pending_results where id = r.id;
      v_done := v_done + 1;
    exception
      when lock_not_available then
        update pending_results
           set attempts = attempts + 1, last_error = 'row busy',
               next_try_at = now() + interval '30 seconds'
         where id = r.id;
      when others then
        update pending_results
           set attempts = attempts + 1, last_error = sqlerrm,
               next_try_at = now() + interval '5 minutes'
         where id = r.id;
    end;
  end loop;

  select count(*), coalesce(max(now() - created_at), interval '0')
    into v_n, v_age from pending_results;

  if v_n > p_max_queue or v_age > p_max_age then
    insert into alerts (kind, detail)
    values ('pending_results_backlog', format('%s pending, oldest %s', v_n, v_age))
    on conflict (kind) do update
      set is_open = true,
          detail = excluded.detail,
          last_seen = now(),
          opened_at = case when alerts.is_open then alerts.opened_at else now() end;
  else
    update alerts set is_open = false, last_seen = now()
     where kind = 'pending_results_backlog' and is_open;
  end if;

  return v_done;
end $$;
