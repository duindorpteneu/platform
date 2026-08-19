#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-payment-concurrency.XXXXXX)"

cleanup_data() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local session_replication_role = replica;
delete from private.manual_payment_requests
where order_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);
delete from private.payment_events
where payment_id in (
  select id from app.payments
  where order_id in (
    'e2000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    'e2000000-0000-4000-8000-000000000003'
  )
);
delete from private.email_jobs
where order_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);
delete from private.qr_tokens
where order_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);
delete from app.audit_logs
where actor_user_id = 'e0000000-0000-4000-8000-000000000001'
  or entity_id in (
    'e2000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    'e2000000-0000-4000-8000-000000000003'
  );
delete from app.payments
where order_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);
delete from app.member_package_size_selections
where assignment_id in (
  select id from app.member_package_assignments
  where order_id in (
    'e2000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    'e2000000-0000-4000-8000-000000000003'
  )
);
delete from app.member_package_assignments
where order_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id from app.order_package_snapshots
  where order_id in (
    'e2000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    'e2000000-0000-4000-8000-000000000003'
  )
);
delete from app.order_package_snapshots
where order_id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);
delete from app.member_orders
where id in (
  'e2000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003'
);
delete from app.member_external_identities
where member_id in (
  'e1000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000002',
  'e1000000-0000-4000-8000-000000000003'
);
delete from private.member_sensitive_identity
where member_id in (
  'e1000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000002',
  'e1000000-0000-4000-8000-000000000003'
);
delete from app.member_seasons
where member_id in (
  'e1000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000002',
  'e1000000-0000-4000-8000-000000000003'
);
delete from app.members
where id in (
  'e1000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000002',
  'e1000000-0000-4000-8000-000000000003'
);
delete from app.staff_profiles
where auth_user_id = 'e0000000-0000-4000-8000-000000000001';
commit;
SQL
}

cleanup() {
  local status=$?
  cleanup_data >/dev/null 2>&1 || status=1
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT

cleanup_data
"${psql_cmd[@]}" <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'e0000000-0000-4000-8000-000000000001',
  'Betaalconcurrencybeheerder',
  'beheerder'
);
insert into app.members(id, relation_number, first_name, last_name, email, team) values
  ('e1000000-0000-4000-8000-000000000001', 'PAY-RACE-1', 'Kas', 'Race', 'kas-race@example.invalid', 'JO11-1'),
  ('e1000000-0000-4000-8000-000000000002', 'PAY-RACE-2', 'Webhook', 'Replay', 'webhook-replay@example.invalid', 'JO12-1'),
  ('e1000000-0000-4000-8000-000000000003', 'PAY-RACE-3', 'Kas', 'Webhook', 'kas-webhook@example.invalid', 'JO13-1');
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select 'e2000000-0000-4000-8000-000000000001'::uuid,
  'e1000000-0000-4000-8000-000000000001'::uuid, active_season_id, 12500
from app.app_settings where id = true
union all
select 'e2000000-0000-4000-8000-000000000002'::uuid,
  'e1000000-0000-4000-8000-000000000002'::uuid, active_season_id, 7500
from app.app_settings where id = true
union all
select 'e2000000-0000-4000-8000-000000000003'::uuid,
  'e1000000-0000-4000-8000-000000000003'::uuid, active_season_id, 8500
from app.app_settings where id = true;
insert into app.payments(
  id, order_id, method, status, amount_cents, idempotency_key,
  provider_payment_id, metadata_schema_version
) values
  ('e4000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002',
   'mollie', 'pending', 7500, 'payment-race-webhook-replay', 'tr_payment_race_replay', 2),
  ('e4000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000003',
   'mollie', 'pending', 8500, 'payment-race-cash-webhook', 'tr_payment_race_cross', 2);
SQL

run_cash() {
  local hold_seconds="$1"
  "${psql_cmd[@]}" <<SQL
begin;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.record_manual_payment_v2(
  'e2000000-0000-4000-8000-000000000001',
  'cash',
  12500,
  'Gelijktijdig contant ontvangen',
  'e3000000-0000-4000-8000-000000000001'
);
select pg_sleep(${hold_seconds});
commit;
SQL
}

run_cash 2 >"${test_tmp_dir}/cash-first.log" 2>&1 &
first_pid=$!
sleep 0.25
run_cash 0 >"${test_tmp_dir}/cash-second.log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

first_payment="$(
  grep -Eo '"paymentId"[[:space:]]*:[[:space:]]*"[0-9a-f-]{36}"' \
    "${test_tmp_dir}/cash-first.log" | head -n 1 | grep -Eo '[0-9a-f-]{36}'
)"
second_payment="$(
  grep -Eo '"paymentId"[[:space:]]*:[[:space:]]*"[0-9a-f-]{36}"' \
    "${test_tmp_dir}/cash-second.log" | head -n 1 | grep -Eo '[0-9a-f-]{36}'
)"
if [[ -z "$first_payment" || "$first_payment" != "$second_payment" ]]; then
  echo "Gelijktijdige kasretry retourneerde niet dezelfde betaling." >&2
  exit 1
fi
cash_state="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from app.payments where order_id='e2000000-0000-4000-8000-000000000001') || ':' ||
    (select count(*) from private.manual_payment_requests where order_id='e2000000-0000-4000-8000-000000000001') || ':' ||
    (select count(*) from private.qr_tokens where order_id='e2000000-0000-4000-8000-000000000001')
")"
if [[ "$cash_state" != "1:1:0" ]]; then
  echo "Onverwachte kasconcurrencystaat: $cash_state" >&2
  exit 1
fi

run_webhook_replay() {
  local hold_seconds="$1"
  "${psql_cmd[@]}" <<SQL
begin;
select app.reconcile_mollie_payment_v2(
  'payment-race-same-event',
  'tr_payment_race_replay',
  'e4000000-0000-4000-8000-000000000001',
  'e4000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000002',
  'e1000000-0000-4000-8000-000000000002',
  (select member_season_id from app.member_orders where id='e2000000-0000-4000-8000-000000000002'),
  (select season_id from app.member_orders where id='e2000000-0000-4000-8000-000000000002'),
  7500,
  'EUR',
  'paid',
  timezone('utc', now()) - interval '1 minute',
  timezone('utc', now()),
  null,
  timezone('utc', now()),
  null,
  null,
  '{"schema_version":2}'::jsonb
);
select pg_sleep(${hold_seconds});
commit;
SQL
}

run_webhook_replay 2 >"${test_tmp_dir}/webhook-first.log" 2>&1 &
first_pid=$!
sleep 0.25
run_webhook_replay 0 >"${test_tmp_dir}/webhook-second.log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

if ! grep -q '"effect"[[:space:]]*:[[:space:]]*"event_replay"' "${test_tmp_dir}/webhook-second.log"; then
  tail -n 40 "${test_tmp_dir}/webhook-second.log"
  echo "Gelijktijdige webhook werd niet als replay verwerkt." >&2
  exit 1
fi
webhook_state="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from private.payment_events where idempotency_key='payment-race-same-event') || ':' ||
    (select count(*) from private.email_jobs where order_id='e2000000-0000-4000-8000-000000000002' and template_key='payment_received') || ':' ||
    (select count(*) from private.qr_tokens where order_id='e2000000-0000-4000-8000-000000000002')
")"
if [[ "$webhook_state" != "1:1:0" ]]; then
  echo "Onverwachte webhookconcurrencystaat: $webhook_state" >&2
  exit 1
fi

run_cross_webhook() {
  "${psql_cmd[@]}" <<'SQL'
begin;
select app.reconcile_mollie_payment_v2(
  'payment-race-cross-event',
  'tr_payment_race_cross',
  'e4000000-0000-4000-8000-000000000002',
  'e4000000-0000-4000-8000-000000000002',
  'e2000000-0000-4000-8000-000000000003',
  'e1000000-0000-4000-8000-000000000003',
  (select member_season_id from app.member_orders where id='e2000000-0000-4000-8000-000000000003'),
  (select season_id from app.member_orders where id='e2000000-0000-4000-8000-000000000003'),
  8500,
  'EUR',
  'paid',
  timezone('utc', now()) - interval '1 minute',
  timezone('utc', now()),
  null,
  timezone('utc', now()),
  null,
  null,
  '{"schema_version":2}'::jsonb
);
select pg_sleep(2);
commit;
SQL
}

run_cross_cash() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"e0000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.record_manual_payment_v2(
  'e2000000-0000-4000-8000-000000000003',
  'cash',
  8500,
  'Contant tijdens webhook',
  'e3000000-0000-4000-8000-000000000003'
);
commit;
SQL
}

run_cross_webhook >"${test_tmp_dir}/cross-webhook.log" 2>&1 &
webhook_pid=$!
sleep 0.25
set +e
run_cross_cash >"${test_tmp_dir}/cross-cash.log" 2>&1
cash_status=$?
set -e
wait "$webhook_pid"
if [[ "$cash_status" -eq 0 ]] || ! grep -q "ORDER_ALREADY_PAID" "${test_tmp_dir}/cross-cash.log"; then
  tail -n 40 "${test_tmp_dir}/cross-cash.log"
  echo "Kas/webhookrace faalde niet gesloten op de orderlock." >&2
  exit 1
fi
cross_state="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from app.payments where order_id='e2000000-0000-4000-8000-000000000003' and status='paid') || ':' ||
    (select count(*) from private.manual_payment_requests where order_id='e2000000-0000-4000-8000-000000000003') || ':' ||
    (select count(*) from private.qr_tokens where order_id='e2000000-0000-4000-8000-000000000003')
")"
if [[ "$cross_state" != "1:0:0" ]]; then
  echo "Onverwachte kas/webhookconcurrencystaat: $cross_state" >&2
  exit 1
fi

echo "Paymentconcurrency groen: kasretry, webhookreplay en kas/webhook zijn geserialiseerd zonder QR."
