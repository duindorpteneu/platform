#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De fulfilment-concurrencytest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-fulfilment-v3.XXXXXX)"
first_log="$test_tmp_dir/first.log"
second_log="$test_tmp_dir/second.log"
previous_active_season="$("${psql_cmd[@]}" -Atc "select coalesce(active_season_id::text, '') from app.app_settings where id = true")"
previous_pickup_location="$("${psql_cmd[@]}" -Atc "select coalesce(pickup_location, '') from app.app_settings where id = true")"
previous_allocation_flag="$("${psql_cmd[@]}" -Atc "select enabled::text from app.release_feature_flags where key = 'allocation_qr_v2'")"
previous_scanner_flag="$("${psql_cmd[@]}" -Atc "select enabled::text from app.release_feature_flags where key = 'scanner_pwa_v2'")"
previous_cutover="$("${psql_cmd[@]}" -Atc "select exists(select 1 from private.release_cutovers where key = 'allocation_qr_v2')")"

cleanup() {
  "${psql_cmd[@]}" \
    -v previous_active="$previous_active_season" \
    -v previous_pickup="$previous_pickup_location" \
    -v previous_allocation="$previous_allocation_flag" \
    -v previous_scanner="$previous_scanner_flag" \
    -v previous_cutover="$previous_cutover" <<'SQL'
begin;
set local session_replication_role = replica;

delete from private.fulfilment_notification_events
where order_id = '45000000-0000-4000-8000-000000000001';
delete from private.fulfilment_command_requests
where fulfilment_id in (
  select id from app.fulfilments
  where order_id = '45000000-0000-4000-8000-000000000001'
);
delete from app.inventory_movements
where season_id = '41000000-0000-4000-8000-000000000001';
delete from app.inventory_allocation_events
where allocation_id in (
  select id from app.inventory_allocations
  where order_id = '45000000-0000-4000-8000-000000000001'
);
delete from app.fulfilment_lines
where order_line_id = '46000000-0000-4000-8000-000000000001';
delete from app.fulfilments
where order_id = '45000000-0000-4000-8000-000000000001';
delete from private.qr_scan_grants
where order_id = '45000000-0000-4000-8000-000000000001';
delete from private.qr_identity_commands
where order_id = '45000000-0000-4000-8000-000000000001';
delete from private.qr_order_locators
where order_id = '45000000-0000-4000-8000-000000000001';
delete from private.qr_order_identities
where order_id = '45000000-0000-4000-8000-000000000001';
delete from private.inventory_allocation_queue
where season_id = '41000000-0000-4000-8000-000000000001';
delete from app.inventory_allocations
where order_id = '45000000-0000-4000-8000-000000000001';
delete from app.inventory_reservations
where order_line_id = '46000000-0000-4000-8000-000000000001';
delete from app.payments
where order_id = '45000000-0000-4000-8000-000000000001';
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id from app.order_package_snapshots
  where order_id = '45000000-0000-4000-8000-000000000001'
);
delete from app.order_lines
where id = '46000000-0000-4000-8000-000000000001';
delete from app.member_orders
where id = '45000000-0000-4000-8000-000000000001';
delete from app.order_package_snapshots
where order_id = '45000000-0000-4000-8000-000000000001';
delete from app.member_article_sizes
where member_id = '44000000-0000-4000-8000-000000000001'
  and season_id = '41000000-0000-4000-8000-000000000001';
delete from app.action_items
where season_id = '41000000-0000-4000-8000-000000000001';
delete from app.member_seasons
where member_id = '44000000-0000-4000-8000-000000000001'
  and season_id = '41000000-0000-4000-8000-000000000001';
delete from private.member_sensitive_identity
where member_id = '44000000-0000-4000-8000-000000000001';
delete from app.members
where id = '44000000-0000-4000-8000-000000000001';
delete from app.article_seasons
where article_id = '42000000-0000-4000-8000-000000000001'
  and season_id = '41000000-0000-4000-8000-000000000001';
delete from app.article_variants
where id = '43000000-0000-4000-8000-000000000001';
delete from app.articles
where id = '42000000-0000-4000-8000-000000000001';
delete from app.inventory_settings
where season_id = '41000000-0000-4000-8000-000000000001';
delete from app.audit_logs
where actor_user_id = '40000000-0000-4000-8000-000000000001'
   or entity_id in (
     '45000000-0000-4000-8000-000000000001',
     '46000000-0000-4000-8000-000000000001'
   );
delete from app.seasons
where id = '41000000-0000-4000-8000-000000000001';
delete from private.staff_sessions
where auth_user_id = '40000000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = '40000000-0000-4000-8000-000000000001';

update app.release_feature_flags
set enabled = :'previous_allocation'::boolean
where key = 'allocation_qr_v2';
update app.release_feature_flags
set enabled = :'previous_scanner'::boolean
where key = 'scanner_pwa_v2';
delete from private.release_cutovers
where key = 'allocation_qr_v2'
  and not :'previous_cutover'::boolean;
update app.app_settings
set active_season_id = nullif(:'previous_active', '')::uuid,
    pickup_location = nullif(:'previous_pickup', '')
where id = true;

set local session_replication_role = origin;
commit;
SQL
  rm -rf -- "$test_tmp_dir"
}

trap cleanup EXIT
cleanup
mkdir -p "$test_tmp_dir"

"${psql_cmd[@]}" >/dev/null <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  '40000000-0000-4000-8000-000000000001',
  'V3 race-uitgifte',
  'uitgifte'
);
insert into private.staff_sessions(
  token_hash,
  auth_user_id,
  expires_at
) values (
  repeat('a', 64),
  '40000000-0000-4000-8000-000000000001',
  timezone('utc', now()) + interval '8 hours'
);
insert into app.seasons(id, name, default_amount_cents, status)
values (
  '41000000-0000-4000-8000-000000000001',
  'V3 fulfilment-race',
  12500,
  'open'
);
update app.app_settings
set active_season_id = '41000000-0000-4000-8000-000000000001',
    pickup_location = 'Free-Kick Sport, De Savornin Lohmanplein 45, 2566 AE Den Haag'
where id = true;
insert into app.articles(id, name, code, sort_order, active)
values (
  '42000000-0000-4000-8000-000000000001',
  'V3 race-shirt',
  'V3-RACE',
  990,
  true
);
insert into app.article_seasons(article_id, season_id)
values (
  '42000000-0000-4000-8000-000000000001',
  '41000000-0000-4000-8000-000000000001'
);
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  active
) values (
  '43000000-0000-4000-8000-000000000001',
  '42000000-0000-4000-8000-000000000001',
  '152',
  'V3-RACE-152',
  true
);
insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  gender
) values (
  '44000000-0000-4000-8000-000000000001',
  'V3-RACE-001',
  'Noa',
  'Race',
  'v3-race@example.invalid',
  'JO13-1',
  'female'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
) values (
  '45000000-0000-4000-8000-000000000001',
  '44000000-0000-4000-8000-000000000001',
  '41000000-0000-4000-8000-000000000001',
  12500
);
insert into app.order_lines(
  id,
  order_id,
  article_variant_id
) values (
  '46000000-0000-4000-8000-000000000001',
  '45000000-0000-4000-8000-000000000001',
  '43000000-0000-4000-8000-000000000001'
);
select set_config('app.package_size_internal', 'on', true);
insert into app.member_article_sizes(
  member_id,
  season_id,
  article_id,
  article_variant_id,
  member_season_id,
  selection_status,
  selection_source,
  confirmed_at
)
select
  '44000000-0000-4000-8000-000000000001',
  '41000000-0000-4000-8000-000000000001',
  '42000000-0000-4000-8000-000000000001',
  '43000000-0000-4000-8000-000000000001',
  member_season.id,
  'confirmed',
  'staff',
  timezone('utc', now()) - interval '1 hour'
from app.member_seasons member_season
where member_season.member_id = '44000000-0000-4000-8000-000000000001'
  and member_season.season_id = '41000000-0000-4000-8000-000000000001'
on conflict (member_id, season_id, article_id) do update
set article_variant_id = excluded.article_variant_id,
    member_season_id = excluded.member_season_id,
    selection_status = excluded.selection_status,
    selection_source = excluded.selection_source,
    raw_value = null,
    member_note = null,
    confirmed_at = excluded.confirmed_at,
    updated_at = timezone('utc', now());
select set_config('app.package_size_internal', 'off', true);
insert into app.payments(
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values (
  '45000000-0000-4000-8000-000000000001',
  'cash',
  'paid',
  12500,
  'v3-race-payment-0001',
  timezone('utc', now()) - interval '30 minutes'
);
insert into app.inventory_movements(
  season_id,
  article_id,
  article_variant_id,
  movement_type,
  on_hand_delta,
  source_type,
  reason_code,
  idempotency_key
) values (
  '41000000-0000-4000-8000-000000000001',
  '42000000-0000-4000-8000-000000000001',
  '43000000-0000-4000-8000-000000000001',
  'opening_balance',
  1,
  'v3_race',
  'v3_race.opening',
  repeat('1', 64)
);
insert into private.release_cutovers(key)
values ('allocation_qr_v2')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key in ('allocation_qr_v2', 'scanner_pwa_v2');
select private.allocate_inventory_fifo_variant(
  '41000000-0000-4000-8000-000000000001',
  '43000000-0000-4000-8000-000000000001',
  'v3_race'
);
select app.register_order_qr_locator(
  '45000000-0000-4000-8000-000000000001',
  1,
  1,
  repeat('n', 43),
  repeat('9', 64),
  repeat('d', 64),
  '47000000-0000-4000-8000-000000000001'
);
select app.exchange_order_qr_locator_v2(
  '40000000-0000-4000-8000-000000000001',
  repeat('a', 64),
  repeat('d', 64),
  repeat('e', 64),
  1,
  '47000000-0000-4000-8000-000000000002'
);
SQL

ready="$("${psql_cmd[@]}" -Atc "
  select line.status::text || ':' || allocation.status::text
  from app.order_lines line
  join app.inventory_allocations allocation on allocation.order_line_id = line.id
  where line.id = '46000000-0000-4000-8000-000000000001'
")"
if [[ "$ready" != "ready_for_pickup:reserved" ]]; then
  echo "V3-racefixture werd niet afhaalklaar: $ready" >&2
  exit 1
fi

run_first() {
  "${psql_cmd[@]}" >"$first_log" 2>&1 <<'SQL'
begin;
set local statement_timeout = '15s';
select app.commit_fulfilment_v3(
  '40000000-0000-4000-8000-000000000001',
  repeat('a', 64),
  repeat('e', 64),
  array['46000000-0000-4000-8000-000000000001'::uuid],
  '48000000-0000-4000-8000-000000000001',
  null
);
\echo FIRST_COMMIT_HOLDING
select pg_sleep(1.5);
commit;
SQL
}

run_second() {
  "${psql_cmd[@]}" >"$second_log" 2>&1 <<'SQL'
begin;
set local statement_timeout = '15s';
select app.commit_fulfilment_v3(
  '40000000-0000-4000-8000-000000000001',
  repeat('a', 64),
  repeat('e', 64),
  array['46000000-0000-4000-8000-000000000001'::uuid],
  '48000000-0000-4000-8000-000000000002',
  null
);
commit;
SQL
}

run_first &
first_pid=$!
for _attempt in $(seq 1 100); do
  grep -q "FIRST_COMMIT_HOLDING" "$first_log" 2>/dev/null && break
  kill -0 "$first_pid" 2>/dev/null || break
  sleep 0.05
done
if ! grep -q "FIRST_COMMIT_HOLDING" "$first_log"; then
  tail -n 60 "$first_log"
  exit 1
fi
run_second &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

if ! grep -q '"status": "completed"' "$first_log"; then
  tail -n 60 "$first_log"
  exit 1
fi
if ! grep -q '"status": "stale"' "$second_log"; then
  tail -n 60 "$second_log"
  exit 1
fi

result="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from app.fulfilments where order_id = '45000000-0000-4000-8000-000000000001')
    || ':' ||
    (select status::text from app.inventory_allocations where order_line_id = '46000000-0000-4000-8000-000000000001')
    || ':' ||
    (select status::text from app.order_lines where id = '46000000-0000-4000-8000-000000000001')
    || ':' ||
    (select count(*) from private.fulfilment_notification_events where order_id = '45000000-0000-4000-8000-000000000001')
")"
if [[ "$result" != "1:fulfilled:picked_up:1" ]]; then
  echo "Onverwacht V3-concurrencyresultaat: $result" >&2
  exit 1
fi

echo "V3 fulfilment-concurrencytest geslaagd: één immutable uitgifte, gelijktijdige tweede commit stale."
