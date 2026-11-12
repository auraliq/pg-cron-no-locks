-- Fix, part 2: the webhook never waits long, and never loses a result.
--
-- _apply_result does the real work and may raise lock_not_available (55P03)
-- when it cannot get the row lock within lock_timeout.
-- apply_call_result is what the webhook calls: on a busy row it parks the
-- payload in pending_results and answers 'queued' instead of failing.
--
-- FOR NO KEY UPDATE (not FOR UPDATE): inserting into calls takes a KEY SHARE
-- lock on the parent contact row because of the foreign key, and FOR UPDATE
-- conflicts with KEY SHARE while FOR NO KEY UPDATE does not.
create or replace function _apply_result(p_payload jsonb)
returns void language plpgsql as $$
declare
  v_contact bigint := (p_payload->>'contact_id')::bigint;
  v_outcome text   := p_payload->>'outcome';
begin
  perform 1 from contacts where id = v_contact for no key update;
  if not found then
    raise exception 'unknown contact %', v_contact;
  end if;

  insert into calls (contact_id, provider_call_id, outcome, ended_at)
  values (v_contact, p_payload->>'provider_call_id', v_outcome, now())
  on conflict (provider_call_id) do nothing;

  update contacts
     set status = case when v_outcome = 'do_not_call' then 'do_not_call' else 'called' end,
         result = v_outcome,
         last_call_at = coalesce(last_call_at, now())
   where id = v_contact;
end $$;

create or replace function apply_call_result(p_payload jsonb, p_lock_timeout text default '2s')
returns text language plpgsql as $$
begin
  -- Local to this transaction. Keep it well below the role's statement_timeout.
  perform set_config('lock_timeout', p_lock_timeout, true);
  begin
    perform _apply_result(p_payload);
    return 'applied';
  exception when lock_not_available then
    insert into pending_results (provider_call_id, contact_id, payload)
    values (p_payload->>'provider_call_id', (p_payload->>'contact_id')::bigint, p_payload)
    on conflict (provider_call_id) do nothing;
    return 'queued';
  end;
end $$;
