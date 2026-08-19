#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-refund-concurrency.XXXXXX)"

cleanup_data() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local session_replication_role = replica;
delete from private.manual_payment_corrections
where order_id = 'fa200000-0000-4000-8000-000000000001';
delete from private.manual_payment_requests
where order_id = 'fa200000-0000-4000-8000-000000000001';
delete from private.email_jobs
where order_id = 'fa200000-0000-4000-8000-000000000001';
delete from app.audit_logs
where actor_user_id = 'fa000000-0000-4000-8000-000000000001'
  or entity_id in (
    'fa200000-0000-4000-8000-000000000001',
    'fa400000-0000-4000-8000-000000000001'
  );
delete from app.payments
where order_id = 'fa200000-0000-4000-8000-000000000001';
delete from app.member_package_size_selections
where assignment_id in (
  select id from app.member_package_assignments
  where order_id = 'fa200000-0000-4000-8000-000000000001'
);
delete from app.member_package_assignments
where order_id = 'fa200000-0000-4000-8000-000000000001';
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id from app.order_package_snapshots
  where order_id = 'fa200000-0000-4000-8000-000000000001'
);
delete from app.order_package_snapshots
where order_id = 'fa200000-0000-4000-8000-000000000001';
delete from app.member_orders
where id = 'fa200000-0000-4000-8000-000000000001';
delete from app.member_external_identities
where member_id = 'fa100000-0000-4000-8000-000000000001';
delete from private.member_sensitive_identity
where member_id = 'fa100000-0000-4000-8000-000000000001';
delete from app.member_seasons
where member_id = 'fa100000-0000-4000-8000-000000000001';
delete from app.members
where id = 'fa100000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'fa000000-0000-4000-8000-000000000001';
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

cleanup_data >/dev/null
"${psql_cmd[@]}" >"${test_tmp_dir}/fixture.log" 2>&1 <<'SQL'
begin;
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'fa000000-0000-4000-8000-000000000001',
  'Refundconcurrencybeheerder',
  'beheerder'
);
insert into app.members(
  id, relation_number, first_name, last_name, email, team, active_for_season
) values (
  'fa100000-0000-4000-8000-000000000001',
  'REF-RACE-1',
  'Refund',
  'Race',
  'refund-race@example.invalid',
  'JO16-1',
  true
);
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
select
  'fa200000-0000-4000-8000-000000000001',
  'fa100000-0000-4000-8000-000000000001',
  active_season_id,
  12500
from app.app_settings
where id = true;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"fa000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.record_manual_payment_v2(
  'fa200000-0000-4000-8000-000000000001',
  'cash',
  12500,
  'Contant ontvangen voor refundrace',
  'fa300000-0000-4000-8000-000000000001'
);
commit;
SQL

payment_id="$("${psql_cmd[@]}" -Atc "
  select id
  from app.payments
  where order_id = 'fa200000-0000-4000-8000-000000000001'
    and status = 'paid'
")"
if [[ ! "$payment_id" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "De refundracefixture heeft geen betaalde betaling." >&2
  exit 1
fi

run_refund() {
  local hold_seconds="$1"
  "${psql_cmd[@]}" <<SQL
begin;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"fa000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.record_manual_payment_refund_v1(
  'fa200000-0000-4000-8000-000000000001',
  '${payment_id}',
  12500,
  'Contante betaling aantoonbaar teruggegeven',
  'Kasbon REF-RACE-1',
  'fa500000-0000-4000-8000-000000000001'
);
select pg_sleep(${hold_seconds});
commit;
SQL
}

run_refund 2 >"${test_tmp_dir}/first.log" 2>&1 &
first_pid=$!
sleep 0.25
run_refund 0 >"${test_tmp_dir}/second.log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

if ! grep -q '"reused"[[:space:]]*:[[:space:]]*false' \
  "${test_tmp_dir}/first.log"; then
  echo "De eerste refundpoging leverde geen nieuw resultaat." >&2
  exit 1
fi
if ! grep -q '"reused"[[:space:]]*:[[:space:]]*true' \
  "${test_tmp_dir}/second.log"; then
  echo "De tweede refundpoging werd niet idempotent hergebruikt." >&2
  exit 1
fi

state="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from private.manual_payment_corrections
      where order_id='fa200000-0000-4000-8000-000000000001') || ':' ||
    (select count(*) from app.payments
      where order_id='fa200000-0000-4000-8000-000000000001'
        and status='refunded') || ':' ||
    (select count(*) from app.audit_logs
      where action='payment.manual.refund_recorded'
        and entity_id='${payment_id}')
")"
if [[ "$state" != "1:1:1" ]]; then
  echo "Onverwachte refundconcurrencystaat: $state" >&2
  exit 1
fi

echo "Handmatige refundconcurrency: geslaagd."
