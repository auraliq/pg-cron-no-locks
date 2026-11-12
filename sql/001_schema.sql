-- Fictional schema for the demo. Nothing here is from a real system.
create table if not exists contacts (
  id           bigint generated always as identity primary key,
  dial_key     text not null unique,            -- opaque key your dialer resolves to a number
  status       text not null default 'pending'
               check (status in ('pending', 'called', 'do_not_call')),
  result       text,
  last_call_at timestamptz
);
create index if not exists contacts_pending_idx on contacts (id) where status = 'pending';

create table if not exists calls (
  id               bigint generated always as identity primary key,
  contact_id       bigint not null references contacts (id),
  provider_call_id text not null unique,        -- makes webhook retries idempotent
  outcome          text,
  ended_at         timestamptz
);

-- Results the webhook could not apply right now (row busy). Retried every minute.
create table if not exists pending_results (
  id               bigint generated always as identity primary key,
  provider_call_id text not null unique,
  contact_id       bigint not null,
  payload          jsonb not null,
  attempts         int not null default 0,
  last_error       text,
  created_at       timestamptz not null default now(),
  next_try_at      timestamptz not null default now()
);

-- One row per alert kind. Something else (a poller, pg_net, a human) reads it.
create table if not exists alerts (
  kind       text primary key,
  is_open    boolean not null default true,
  detail     text,
  opened_at  timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);

-- Stand-in for "place a call and wait". Replace with your real dial step.
-- The pause is the point: a real round waits between calls, and that waiting
-- is what turns a careless UPDATE into a long-held row lock.
create or replace function dial_stub(p_dial_key text, p_pause numeric default 5)
returns void language plpgsql as $$
begin
  perform pg_sleep(p_pause);
end $$;
