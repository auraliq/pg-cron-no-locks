#!/usr/bin/env bash
# Integration test. Needs psql and a SCRATCH database (it truncates tables):
#   createdb nolocks_test && DATABASE_URL=postgresql:///nolocks_test ./test/run.sh
# Takes about 30 seconds. Uses several psql sessions to create real lock contention.
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL to a scratch database}"
cd "$(dirname "$0")/.."

Q() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq "$@"; }
pass=0
ok()   { pass=$((pass+1)); echo "ok - $1"; }
fail() { echo "FAIL - $1"; exit 1; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

for f in 001_schema 002_dialer_bad 003_dialer 004_webhook 005_retry_alert; do
  Q -f "sql/$f.sql" >/dev/null
done

reset() {
  Q -c "truncate calls, pending_results, alerts, contacts restart identity cascade;" >/dev/null
  Q -c "insert into contacts (dial_key) select 'KEY-' || g from generate_series(1,5) g;" >/dev/null
}
payload() { echo "{\"contact_id\":$1,\"provider_call_id\":\"$2\",\"outcome\":\"$3\"}"; }

# 1. The anti-pattern really blocks: naive webhook hits its statement timeout.
reset
Q -c "select dialer_round_bad(3, 2)" >/dev/null &
sleep 3                      # contact 1 was updated at ~2s and stays locked until ~6s
out=$(Q -c "set statement_timeout='1s'; select apply_call_result_naive('$(payload 1 t1 answered)'::jsonb)" 2>&1 || true)
wait
echo "$out" | grep -qi "statement timeout" && ok "bad dialer: naive webhook times out" || fail "expected a statement timeout, got: $out"

# 2. The fixed dialer does not block the webhook, and does not overwrite it.
reset
Q -c "select dialer_round(3, 2)" >/dev/null &
sleep 3
t0=$(now_ms)
res=$(Q -c "select apply_call_result('$(payload 1 t2 do_not_call)'::jsonb)")
t1=$(now_ms)
wait
[ "$res" = "applied" ] && ok "good dialer: webhook applied mid-round" || fail "expected applied, got $res"
[ $((t1 - t0)) -lt 1000 ] && ok "good dialer: webhook took $((t1 - t0)) ms (no lock wait)" || fail "webhook was slow: $((t1 - t0)) ms"
st=$(Q -c "select status from contacts where id = 1")
[ "$st" = "do_not_call" ] && ok "good dialer: end-of-round update did not overwrite the webhook" || fail "status overwritten: $st"
n=$(Q -c "select count(*) from contacts where status = 'called'")
[ "$n" = "2" ] && ok "good dialer: the other two contacts were marked called" || fail "expected 2 called, got $n"

# 3. Busy row: webhook queues instead of failing; the retry job drains it.
reset
Q >/dev/null <<'SQL' &
begin;
select 1 from contacts where id = 2 for update;
select pg_sleep(5);
commit;
SQL
sleep 1
t0=$(now_ms)
res=$(Q -c "select apply_call_result('$(payload 2 t3 answered)'::jsonb, '1s')")
t1=$(now_ms)
[ "$res" = "queued" ] && ok "busy row: webhook answered 'queued'" || fail "expected queued, got $res"
[ $((t1 - t0)) -lt 3000 ] && ok "busy row: gave up after lock_timeout ($((t1 - t0)) ms)" || fail "waited too long: $((t1 - t0)) ms"
[ "$(Q -c 'select count(*) from pending_results')" = "1" ] && ok "busy row: payload parked" || fail "payload not parked"
Q -c "select apply_call_result('$(payload 2 t3 answered)'::jsonb, '1s')" >/dev/null   # duplicate delivery
[ "$(Q -c 'select count(*) from pending_results')" = "1" ] || fail "duplicate delivery was queued twice"
ok "busy row: duplicate delivery is idempotent"
wait
Q -c "update pending_results set next_try_at = now()" >/dev/null
done_n=$(Q -c "select retry_pending_results()")
[ "$done_n" = "1" ] && ok "retry job applied the parked result" || fail "retry applied $done_n"
[ "$(Q -c 'select count(*) from pending_results')" = "0" ] || fail "queue not empty"
[ "$(Q -c 'select result from contacts where id = 2')" = "answered" ] && ok "contact updated after retry" || fail "contact not updated"

# 4. Alert opens when the queue does not drain, and closes when it does.
reset
Q >/dev/null <<'SQL' &
begin;
select 1 from contacts where id = 3 for update;
select pg_sleep(4);
commit;
SQL
sleep 1
for i in 1 2 3; do
  Q -c "insert into pending_results (provider_call_id, contact_id, payload, created_at)
        values ('old-$i', 3, '{\"contact_id\":3,\"provider_call_id\":\"old-$i\",\"outcome\":\"answered\"}', now() - interval '1 hour')" >/dev/null
done
Q -c "select retry_pending_results(10, interval '30 minutes')" >/dev/null
[ "$(Q -c "select count(*) from alerts where is_open and kind = 'pending_results_backlog'")" = "1" ] && ok "alert opened for an old queue" || fail "alert did not open"
wait
Q -c "update pending_results set next_try_at = now()" >/dev/null
Q -c "select retry_pending_results(10, interval '30 minutes')" >/dev/null
[ "$(Q -c "select count(*) from alerts where is_open")" = "0" ] && ok "alert closed after the queue drained" || fail "alert still open"

echo; echo "$pass checks passed"
