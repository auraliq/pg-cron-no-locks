# pg-cron-no-locks

A small Postgres/Supabase pattern, with SQL migrations and an integration test, for one specific failure: a `pg_cron` job that dials in a loop holds row locks for its whole run, and the webhook that reports each call's result times out waiting for them.

Español: patrón mínimo de Postgres/Supabase. Un job de `pg_cron` que marca llamadas no debe mantener candados de fila durante toda la ronda (escribe una sola vez al final, solo filas aún pendientes), y el webhook toma el candado con un `lock_timeout` corto; si está ocupado, encola el resultado en una tabla que otro cron reintenta cada minuto, con alerta si la cola crece. El esquema es ficticio.

> **Status: `test/run.sh` passes (13 checks, real lock contention across concurrent `psql` sessions) on PostgreSQL 17.11, tested 2026-11-11.** `006_cron.sql` (the `pg_cron` schedule) needs the `pg_cron` extension and was not part of that run.

## Case study

### Symptom
An outbound auto-dialer ran as a per-minute `pg_cron` job. Call results arrive at a webhook, which writes them to the database. Over two weeks, hundreds of webhook calls failed, every one with the same error: `canceling statement due to statement timeout`. The sender does not retry, so each failure was a lost result: no call record and no status update on the contact.

### Evidence
1. The failures were not random. They clustered in the minutes when the dialer was running, and they happened only when the person hung up *during* a round, so the result arrived while the round was still in progress.
2. The scheduled job's run history (`cron.job_run_details`, query 1 in `sql/diagnostics.sql`) showed a round lasting between one and four minutes: a batch of calls with a pause between each.
3. The webhook's database role had a `statement_timeout` of 8 seconds (`pg_roles.rolconfig`, query 3). A round holding a lock for minutes guarantees any waiter dies at 8 s.
4. `pg_stat_activity` with `pg_blocking_pids()` (query 2) is how to confirm it live: during a round, blocked webhook sessions point at the dialer's backend.

### Root cause
A `pg_cron` command runs as one transaction. The dialer function updated each contact's status right after dialing it, one row at a time. A row lock lasts until the transaction ends, so the first contact updated stayed locked for the rest of the round, including every pause after it. `002_dialer_bad.sql` reproduces exactly this. A webhook that touched one of those rows (`apply_call_result_naive`) waited until the role's timeout killed it.

### Fix
Three small changes, each in its own migration:
1. `003_dialer.sql`: the dialer does the slow part with nothing locked, then performs **one** set-based `UPDATE` at the end, restricted to rows that are **still pending** (so it never overwrites a result a webhook already wrote). An advisory transaction lock prevents overlapping rounds without blocking any row.
2. `004_webhook.sql`: the webhook function sets a short, transaction-local `lock_timeout` (2 s), takes `FOR NO KEY UPDATE` on the contact row, and on `lock_not_available` stores the payload in `pending_results` and answers `queued` instead of failing. Duplicate deliveries are harmless: unique `provider_call_id`.
3. `005_retry_alert.sql` + `006_cron.sql`: a per-minute job retries parked payloads, each in its own sub-block with `SKIP LOCKED`, and opens an alert (a row in `alerts`) when the queue is larger than a threshold or its oldest item is older than a limit; it closes the alert when the queue drains.

A detail worth knowing: inserting a row that references `contacts` through a foreign key takes a `KEY SHARE` lock on the parent row. `FOR UPDATE` conflicts with it; `FOR NO KEY UPDATE` does not. That is why the webhook uses the weaker lock.

### Verification
After deploying, the first rounds were watched in the database log (`log_lock_waits = on`): the same number of calls per round as before, **zero lock waits**, no `queued` results from the dialer's own activity, and the pending queue stayed empty. Results that arrived mid-round were applied immediately. The queue and alert stayed as a safety net for any other long writer.

## Files

```
sql/001_schema.sql        fictional tables: contacts, calls, pending_results, alerts + dial_stub()
sql/002_dialer_bad.sql    the anti-pattern and the naive webhook, to reproduce the failure
sql/003_dialer.sql        dialer_round(): no locks while working, one final UPDATE of pending rows
sql/004_webhook.sql       apply_call_result(): short lock_timeout, enqueue if busy
sql/005_retry_alert.sql   retry_pending_results(): drain the queue, open/close the alert
sql/006_cron.sql          pg_cron schedules (skipped if pg_cron is not installed)
sql/diagnostics.sql       the investigation queries
test/run.sh               integration test with real lock contention (needs psql)
```

## Test

```bash
createdb nolocks_test
DATABASE_URL=postgresql:///nolocks_test ./test/run.sh
```

It never touches `006_cron.sql`, so plain Postgres is enough. It truncates the demo tables, so use a scratch database. It checks, with several concurrent `psql` sessions:
1. the bad dialer makes the naive webhook hit its statement timeout;
2. the fixed dialer lets the webhook apply in under a second mid-round, and the end-of-round update does not overwrite what the webhook wrote;
3. a busy row makes the webhook answer `queued` after the lock timeout, duplicates are not queued twice, and the retry job applies it once the row is free;
4. the alert opens for an old, stuck queue and closes after it drains.

### Manual test plan (if you cannot run the script)
Open two SQL sessions on a scratch database with `001` to `005` applied and a few rows in `contacts`.
1. Session A: `select dialer_round_bad(3, 2);` (about 6 s). Session B after 3 s: `set statement_timeout='1s'; select apply_call_result_naive('{"contact_id":1,"provider_call_id":"a","outcome":"answered"}');` Expect a statement-timeout error.
2. Reset the rows to `pending`. Session A: `select dialer_round(3, 2);`. Session B after 3 s: `select apply_call_result('{"contact_id":1,"provider_call_id":"b","outcome":"do_not_call"}');` Expect `applied` immediately; after A finishes, contact 1 is still `do_not_call`.
3. Session A: `begin; select 1 from contacts where id = 2 for update; select pg_sleep(5);`. Session B: `select apply_call_result('{"contact_id":2,"provider_call_id":"c","outcome":"answered"}', '1s');` Expect `queued` after about 1 s and one row in `pending_results`. In A: `commit;`. In B: `select retry_pending_results();` Expect `1` and an empty queue.
4. Repeat 3 with three old rows (`created_at = now() - interval '1 hour'`) and `select retry_pending_results(10, interval '30 minutes');` while A still holds the lock. Expect a row in `alerts` with `is_open`; after commit and another retry it closes.

## Using it in your own system

- Replace `dial_stub()` with your real dial step. The rule is the point: nothing slow may run while you hold a row lock, and per-row writes belong in one statement at the end.
- Point your webhook (an Edge Function, a PostgREST RPC) at `apply_call_result(payload)`. Keep the role's `statement_timeout` comfortably above the `lock_timeout`.
- Deliver alerts however you like: poll `select * from alerts where is_open`, or call an HTTP endpoint from a trigger or job.

## Limits

- Fictional, minimal schema; no auth, no row-level security, no payload validation beyond casting.
- The retry loop gives up on nothing by itself; it keeps retrying and alerts. Add a dead-letter policy if you need one.
- `pg_cron` queues a run that would overlap the previous one; if you use another scheduler, keep the advisory lock.
- Tested logic is limited to what `test/run.sh` covers, and as noted above it has not been run by the author yet.

## License

MIT, see `LICENSE`. Author: Ricardo Delgado ([auraliq.io/ricardo](https://www.auraliq.io/ricardo), [LinkedIn](https://www.linkedin.com/in/ricardo-delgado-0626642a7)).
