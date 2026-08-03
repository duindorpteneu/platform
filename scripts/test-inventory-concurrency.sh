#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-inventory-concurrency.XXXXXX)"
previous_flag="$("${psql_cmd[@]}" -c "select enabled::text from app.release_feature_flags where key='allocation_qr_v2'")"
previous_active_season="$("${psql_cmd[@]}" -c "select active_season_id::text from app.app_settings where id=true")"

cleanup_data() {
  "${psql_cmd[@]}" <<SQL
begin;
set local session_replication_role = replica;
delete from private.inventory_allocation_queue
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.action_items
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.audit_logs
where entity_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002',
  'f2600000-0000-4000-8000-000000000001',
  'f2600000-0000-4000-8000-000000000002'
);
delete from app.inventory_allocation_events
where allocation_id in (
  select id from app.inventory_allocations
  where season_id = 'f2100000-0000-4000-8000-000000000001'
);
delete from app.inventory_movements
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.inventory_allocations
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.payments
where order_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id from app.order_package_snapshots
  where order_id in (
    'f2500000-0000-4000-8000-000000000001',
    'f2500000-0000-4000-8000-000000000002'
  )
);
delete from app.order_package_snapshots
where order_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.order_lines
where order_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.member_orders
where id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.member_article_sizes
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.member_external_identities
where member_id in (
  'f2400000-0000-4000-8000-000000000001',
  'f2400000-0000-4000-8000-000000000002'
);
delete from private.member_sensitive_identity
where member_id in (
  'f2400000-0000-4000-8000-000000000001',
  'f2400000-0000-4000-8000-000000000002'
);
delete from app.member_seasons
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.members
where id in (
  'f2400000-0000-4000-8000-000000000001',
  'f2400000-0000-4000-8000-000000000002'
);
delete from app.article_seasons
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.article_variants
where article_id = 'f2200000-0000-4000-8000-000000000001';
delete from app.articles
where id = 'f2200000-0000-4000-8000-000000000001';
delete from app.inventory_settings
where season_id = 'f2100000-0000-4000-8000-000000000001';
update app.app_settings
set active_season_id = '${previous_active_season}'
where id = true;
delete from app.seasons
where id = 'f2100000-0000-4000-8000-000000000001';
update app.release_feature_flags
set enabled = ${previous_flag}
where key = 'allocation_qr_v2';
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
insert into app.seasons(id, name, default_amount_cents, status)
values ('f2100000-0000-4000-8000-000000000001', 'Voorraadconcurrency', 12500, 'open');
update app.app_settings
set active_season_id = 'f2100000-0000-4000-8000-000000000001'
where id = true;
insert into app.articles(id, name, code, sort_order)
values ('f2200000-0000-4000-8000-000000000001', 'Concurrencyshirt', 'CON-SHIRT', 990);
insert into app.article_seasons(article_id, season_id)
values ('f2200000-0000-4000-8000-000000000001', 'f2100000-0000-4000-8000-000000000001');
insert into app.article_variants(id, article_id, size, sku)
values (
  'f2300000-0000-4000-8000-000000000001',
  'f2200000-0000-4000-8000-000000000001',
  'M',
  'CON-M'
);
insert into app.members(id, relation_number, first_name, last_name, email, team) values
  ('f2400000-0000-4000-8000-000000000001', 'CON-001', 'Eerste', 'Race', 'con-1@example.invalid', 'TEST'),
  ('f2400000-0000-4000-8000-000000000002', 'CON-002', 'Tweede', 'Race', 'con-2@example.invalid', 'TEST');
insert into app.member_orders(id, member_id, season_id, amount_due_cents) values
  ('f2500000-0000-4000-8000-000000000001', 'f2400000-0000-4000-8000-000000000001', 'f2100000-0000-4000-8000-000000000001', 12500),
  ('f2500000-0000-4000-8000-000000000002', 'f2400000-0000-4000-8000-000000000002', 'f2100000-0000-4000-8000-000000000001', 12500);
insert into app.order_lines(id, order_id, article_variant_id) values
  ('f2600000-0000-4000-8000-000000000001', 'f2500000-0000-4000-8000-000000000001', 'f2300000-0000-4000-8000-000000000001'),
  ('f2600000-0000-4000-8000-000000000002', 'f2500000-0000-4000-8000-000000000002', 'f2300000-0000-4000-8000-000000000001');
select set_config('app.package_size_internal', 'on', true);
update app.member_article_sizes
set selection_status = 'confirmed',
    selection_source = 'staff',
    confirmed_at = timezone('utc', now()) - interval '2 days',
    article_variant_id = 'f2300000-0000-4000-8000-000000000001',
    raw_value = null,
    member_note = null
where season_id = 'f2100000-0000-4000-8000-000000000001';
select set_config('app.package_size_internal', 'off', true);
insert into app.payments(
  order_id, method, status, amount_cents, idempotency_key, paid_at
) values
  ('f2500000-0000-4000-8000-000000000001', 'cash', 'paid', 12500, 'inventory-concurrency-1', timezone('utc', now()) - interval '3 days'),
  ('f2500000-0000-4000-8000-000000000002', 'cash', 'paid', 12500, 'inventory-concurrency-2', timezone('utc', now()) - interval '1 day');
insert into app.inventory_movements(
  season_id, article_id, article_variant_id, movement_type, on_hand_delta,
  source_type, reason_code, idempotency_key
) values (
  'f2100000-0000-4000-8000-000000000001',
  'f2200000-0000-4000-8000-000000000001',
  'f2300000-0000-4000-8000-000000000001',
  'opening_balance',
  1,
  'concurrency_test',
  'inventory.concurrency_opening',
  repeat('f', 64)
);
update app.release_feature_flags
set enabled = true
where key = 'allocation_qr_v2';
SQL

run_allocator() {
  "${psql_cmd[@]}" -c "
    select private.allocate_inventory_fifo_variant(
      'f2100000-0000-4000-8000-000000000001',
      'f2300000-0000-4000-8000-000000000001',
      'concurrency_test',
      null,
      null,
      null
    );
  "
}

run_allocator >"${test_tmp_dir}/allocator-1.log" 2>&1 &
first_pid=$!
run_allocator >"${test_tmp_dir}/allocator-2.log" 2>&1 &
second_pid=$!
set +e
wait "$first_pid"
first_status=$?
wait "$second_pid"
second_status=$?
set -e
if (( first_status != 0 || second_status != 0 )); then
  sed -n '1,80p' "${test_tmp_dir}/allocator-1.log" >&2
  sed -n '1,80p' "${test_tmp_dir}/allocator-2.log" >&2
  echo "Voorraadallocatorconcurrency eindigde met een databasefout." >&2
  exit 1
fi

state="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    (select count(*) from app.inventory_allocations
      where season_id='f2100000-0000-4000-8000-000000000001'
        and status='reserved'),
    (select count(*) from app.inventory_movements
      where season_id='f2100000-0000-4000-8000-000000000001'
        and movement_type='allocation_reserved'),
    (select available from private.inventory_balance(
      'f2100000-0000-4000-8000-000000000001',
      'f2300000-0000-4000-8000-000000000001'
    )),
    (select order_line_id::text from app.inventory_allocations
      where season_id='f2100000-0000-4000-8000-000000000001'
        and status='reserved')
  )
")"
expected="1:1:0:f2600000-0000-4000-8000-000000000001"
if [[ "$state" != "$expected" ]]; then
  echo "Onverwachte voorraadconcurrencystaat: $state" >&2
  exit 1
fi

echo "Voorraadconcurrency geslaagd: één stuk, één journaalevent en exact de oudste FIFO-regel."
