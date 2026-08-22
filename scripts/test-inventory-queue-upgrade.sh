#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_url="postgresql://postgres:postgres@127.0.0.1:54339/postgres"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1 -At)
reset_log="$(mktemp)"
restored=false

restore_latest() {
  if [[ "$restored" == true ]]; then return; fi
  if ! (cd "$repository_root" && pnpm db:reset >"$reset_log" 2>&1); then
    tail -n 80 "$reset_log" >&2
    return 1
  fi
  restored=true
}

cleanup() {
  local status=$?
  restore_latest || status=1
  rm -f "$reset_log"
  exit "$status"
}
trap cleanup EXIT

identity="$("${psql_cmd[@]}" -c "select concat_ws('|',current_database(),current_user,inet_server_port())")"
if [[ "$identity" != "postgres|postgres|5432" ]]; then
  echo "Voorraadqueue-upgradetest weigert onverwachte database-identiteit." >&2
  exit 2
fi

cd "$repository_root"
node scripts/run-supabase.mjs db reset --local --version 20260820183000 --no-seed

"${psql_cmd[@]}" <<'SQL'
insert into app.seasons(id, name, default_amount_cents, status)
values ('fa410000-0000-4000-8000-000000000001','Queue upgrade',10000,'open');
update app.app_settings
set active_season_id='fa410000-0000-4000-8000-000000000001'
where id=true;
insert into app.articles(id, name, code, sort_order)
values ('fa420000-0000-4000-8000-000000000001','Queueartikel','QUEUE-UP',941);
insert into app.article_seasons(article_id, season_id)
values ('fa420000-0000-4000-8000-000000000001','fa410000-0000-4000-8000-000000000001');
insert into app.article_variants(id, article_id, size, sku, sort_order) values
  ('fa430000-0000-4000-8000-000000000001','fa420000-0000-4000-8000-000000000001','S','QUEUE-S',1),
  ('fa430000-0000-4000-8000-000000000002','fa420000-0000-4000-8000-000000000001','M','QUEUE-M',2),
  ('fa430000-0000-4000-8000-000000000003','fa420000-0000-4000-8000-000000000001','L','QUEUE-L',3);
insert into app.members(id, relation_number, first_name, last_name, email, team)
values ('fa440000-0000-4000-8000-000000000001','QUEUE-001','Queue','Upgrade','queue@example.invalid','TEST');
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
values ('fa450000-0000-4000-8000-000000000001','fa440000-0000-4000-8000-000000000001','fa410000-0000-4000-8000-000000000001',10000);
insert into app.order_lines(id, order_id, article_variant_id)
values ('fa460000-0000-4000-8000-000000000001','fa450000-0000-4000-8000-000000000001','fa430000-0000-4000-8000-000000000001');
select set_config('app.package_size_internal','on',true);
update app.member_article_sizes
set article_variant_id='fa430000-0000-4000-8000-000000000001',
    selection_status='confirmed',
    selection_source='staff',
    raw_value=null,
    member_note=null,
    confirmed_at=statement_timestamp()
where member_id='fa440000-0000-4000-8000-000000000001'
  and season_id='fa410000-0000-4000-8000-000000000001'
  and article_id='fa420000-0000-4000-8000-000000000001';
select set_config('app.package_size_internal','off',true);
insert into app.payments(order_id,method,status,amount_cents,idempotency_key,paid_at)
values ('fa450000-0000-4000-8000-000000000001','cash','paid',10000,'queue-upgrade-paid',statement_timestamp());

delete from private.inventory_allocation_queue
where season_id='fa410000-0000-4000-8000-000000000001';
insert into private.inventory_allocation_queue(
  season_id, article_variant_id, status, reason_code, attempts
) values
  ('fa410000-0000-4000-8000-000000000001','fa430000-0000-4000-8000-000000000001','queued','upgrade.active_poison',10),
  ('fa410000-0000-4000-8000-000000000001','fa430000-0000-4000-8000-000000000002','queued','upgrade.stale_poison',10),
  ('fa410000-0000-4000-8000-000000000001','fa430000-0000-4000-8000-000000000003','failed','upgrade.unknown_failure',10);
SQL

node scripts/run-supabase.mjs migration up --local >/dev/null

state="$("${psql_cmd[@]}" -c "
  select string_agg(concat_ws(':',article_variant_id,status,attempts),',' order by article_variant_id)
  from private.inventory_allocation_queue
  where season_id='fa410000-0000-4000-8000-000000000001'
")"
expected="fa430000-0000-4000-8000-000000000001:queued:0,fa430000-0000-4000-8000-000000000002:completed:10,fa430000-0000-4000-8000-000000000003:failed:10"
if [[ "$state" != "$expected" ]]; then
  echo "Onverwachte gerepareerde voorraadqueuestaat: $state" >&2
  exit 1
fi

reconciliation="$("${psql_cmd[@]}" -c "
  select concat_ws(':',status,metrics->>'reset',metrics->>'completed')
  from private.migration_reconciliations
  where migration_key='20260820190000_inventory_allocation_queue_state_machine'
")"
if [[ "$reconciliation" != "passed:1:1" ]]; then
  echo "Onverwacht voorraadqueue-reconciliatiebewijs: $reconciliation" >&2
  exit 1
fi

"${psql_cmd[@]}" -c "select private.enqueue_inventory_variant(
  'fa410000-0000-4000-8000-000000000001',
  'fa430000-0000-4000-8000-000000000003',
  'upgrade.retry_unknown'
)" >/dev/null
reenqueued="$("${psql_cmd[@]}" -c "
  select concat_ws(':',status,attempts)
  from private.inventory_allocation_queue
  where season_id='fa410000-0000-4000-8000-000000000001'
    and article_variant_id='fa430000-0000-4000-8000-000000000003'
")"
if [[ "$reenqueued" != "queued:0" ]]; then
  echo "Terminale re-enqueue startte geen verse lifecycle: $reenqueued" >&2
  exit 1
fi

restore_latest
echo "Voorraadqueue-upgradetest geslaagd: actieve poison heropend, stale poison gesloten en onbekende failure behouden."
