-- ANTI-PATTERN, kept only to reproduce the incident. Do not schedule this.
--
-- A pg_cron job runs its whole command as ONE transaction. Every UPDATE below
-- takes a row lock that is held until the function returns, i.e. through every
-- later pause in the loop. Anything else that touches those rows waits.
create or replace function dialer_round_bad(p_batch int default 15, p_pause numeric default 5)
returns int language plpgsql as $$
declare r record; n int := 0;
begin
  for r in select id, dial_key from contacts where status = 'pending' order by id limit p_batch loop
    perform dial_stub(r.dial_key, p_pause);
    update contacts set status = 'called', last_call_at = now() where id = r.id;  -- lock held from here to the end
    n := n + 1;
  end loop;
  return n;
end $$;

-- The matching naive webhook: no lock_timeout, waits as long as it takes
-- (until the role's statement_timeout kills it and the result is lost).
create or replace function apply_call_result_naive(p_payload jsonb)
returns void language plpgsql as $$
begin
  update contacts
     set status = case when p_payload->>'outcome' = 'do_not_call' then 'do_not_call' else 'called' end,
         result = p_payload->>'outcome'
   where id = (p_payload->>'contact_id')::bigint;
end $$;
