-- Fix, part 1: the dialer holds no row locks while it works.
--
--  * It reads candidates without locking them.
--  * It does the slow part (dialing, pausing) with nothing locked.
--  * It writes ONCE at the end, one set-based UPDATE, and only to rows that are
--    still 'pending' (a webhook that arrived mid-round may already have moved
--    them on; we must not overwrite that).
--  * A transaction-level advisory lock stops two rounds from overlapping. It
--    does not block any row access.
create or replace function dialer_round(p_batch int default 15, p_pause numeric default 5)
returns int language plpgsql as $$
declare
  r record;
  v_ids bigint[] := '{}';
  v_n   int;
begin
  if not pg_try_advisory_xact_lock(hashtext('dialer_round')) then
    return 0;                       -- previous round still running
  end if;

  for r in select id, dial_key from contacts where status = 'pending' order by id limit p_batch loop
    perform dial_stub(r.dial_key, p_pause);
    v_ids := v_ids || r.id;
  end loop;

  update contacts
     set status = 'called', last_call_at = now()
   where id = any (v_ids)
     and status = 'pending';          -- only rows still pending
  get diagnostics v_n = row_count;
  return v_n;
end $$;
