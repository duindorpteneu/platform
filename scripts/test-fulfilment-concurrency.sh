#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1)
first_log="/tmp/duindorp-fulfilment-race-first.log"
second_log="/tmp/duindorp-fulfilment-race-second.log"

cleanup() {
  "${psql_cmd[@]}" <<'SQL'
delete from app.audit_logs
where entity_id in ('45000000-0000-4000-8000-000000000001', '46000000-0000-4000-8000-000000000001')
   or metadata->>'order_id' = '45000000-0000-4000-8000-000000000001';
delete from app.fulfilment_lines where order_line_id = '46000000-0000-4000-8000-000000000001';
delete from app.fulfilments where order_id = '45000000-0000-4000-8000-000000000001';
delete from app.inventory_reservations where order_line_id = '46000000-0000-4000-8000-000000000001';
delete from app.delivery_receipt_lines where id = '48000000-0000-4000-8000-000000000001';
delete from app.delivery_receipts where id = '47000000-0000-4000-8000-000000000001';
delete from private.qr_tokens where order_id = '45000000-0000-4000-8000-000000000001';
delete from app.payments where order_id = '45000000-0000-4000-8000-000000000001';
delete from app.order_lines where id = '46000000-0000-4000-8000-000000000001';
delete from app.member_orders where id = '45000000-0000-4000-8000-000000000001';
delete from app.members where id = '44000000-0000-4000-8000-000000000001';
delete from app.article_variants where id = '43000000-0000-4000-8000-000000000001';
delete from app.articles where id = '42000000-0000-4000-8000-000000000001';
delete from app.seasons where id = '41000000-0000-4000-8000-000000000001';
delete from app.staff_profiles where auth_user_id in ('40000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000002');
SQL
}

trap cleanup EXIT
cleanup

"${psql_cmd[@]}" <<'SQL'
insert into app.staff_profiles (auth_user_id, display_name, role)
values
  ('40000000-0000-4000-8000-000000000001', 'Race balie één', 'uitgifte'),
  ('40000000-0000-4000-8000-000000000002', 'Race balie twee', 'uitgifte');
insert into app.seasons (id, name, default_amount_cents, status)
values ('41000000-0000-4000-8000-000000000001', 'Race-testseizoen', 12500, 'open');
insert into app.articles (id, name, sort_order)
values ('42000000-0000-4000-8000-000000000001', 'Race-testartikel', 100);
insert into app.article_variants (id, article_id, size, sku)
values ('43000000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-000000000001', 'RACE', 'RACE-001');
insert into app.members (id, relation_number, first_name, last_name, email, team)
values ('44000000-0000-4000-8000-000000000001', 'RACE-001', 'Race', 'Testlid', 'race@example.invalid', 'Testteam');
insert into app.member_orders (id, member_id, season_id, amount_due_cents, order_status)
values ('45000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000001', 12500, 'Volledig af te halen');
insert into app.order_lines (id, order_id, article_variant_id, status)
values ('46000000-0000-4000-8000-000000000001', '45000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 'ready_for_pickup');
insert into app.delivery_receipts (id, received_on, supplier, actor_user_id)
values ('47000000-0000-4000-8000-000000000001', current_date, 'Race-testleverancier', '40000000-0000-4000-8000-000000000001');
insert into app.delivery_receipt_lines (id, receipt_id, article_variant_id, received_quantity)
values ('48000000-0000-4000-8000-000000000001', '47000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 1);
insert into app.inventory_reservations (id, receipt_line_id, order_line_id, quantity, actor_user_id)
values ('49000000-0000-4000-8000-000000000001', '48000000-0000-4000-8000-000000000001', '46000000-0000-4000-8000-000000000001', 1, '40000000-0000-4000-8000-000000000001');
insert into app.payments (order_id, method, status, amount_cents, idempotency_key, paid_at)
values ('45000000-0000-4000-8000-000000000001', 'card', 'paid', 12500, 'race-payment-00000001', timezone('utc', now()));
insert into private.qr_tokens (order_id, token_hash, version)
values ('45000000-0000-4000-8000-000000000001', repeat('c', 64), 1);
SQL

run_first() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"40000000-0000-4000-8000-000000000001","aal":"aal2"}', true);
select app.commit_fulfilment(
  '45000000-0000-4000-8000-000000000001',
  array['46000000-0000-4000-8000-000000000001'::uuid],
  'Race-balie één',
  repeat('c', 64)
);
select pg_sleep(2);
commit;
SQL
}

run_second() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"40000000-0000-4000-8000-000000000002","aal":"aal2"}', true);
select app.commit_fulfilment(
  '45000000-0000-4000-8000-000000000001',
  array['46000000-0000-4000-8000-000000000001'::uuid],
  'Race-balie twee',
  repeat('c', 64)
);
commit;
SQL
}

set +e
run_first >"$first_log" 2>&1 &
first_pid=$!
sleep 0.25
run_second >"$second_log" 2>&1 &
second_pid=$!
wait "$first_pid"
first_status=$?
wait "$second_pid"
second_status=$?
set -e

if [[ "$first_status" -ne 0 ]]; then
  tail -n 40 "$first_log"
  exit 1
fi

if [[ "$second_status" -eq 0 ]] || ! rg -q "ORDER_LINE_NOT_READY" "$second_log"; then
  tail -n 40 "$second_log"
  exit 1
fi

result=$("${psql_cmd[@]}" -Atc "select count(*) || ':' || min(ol.status::text) from app.fulfilment_lines fl join app.order_lines ol on ol.id = fl.order_line_id where fl.order_line_id = '46000000-0000-4000-8000-000000000001' and fl.reversed_at is null")
if [[ "$result" != "1:picked_up" ]]; then
  echo "Onverwacht race-resultaat: $result"
  exit 1
fi

echo "Concurrencytest geslaagd: één fulfilment, tweede balie geblokkeerd."
