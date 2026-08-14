#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_url="postgresql://postgres:postgres@127.0.0.1:54339/postgres"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1 -At)
reset_log="$(mktemp)"
restored=false

restore_latest() {
  if [[ "$restored" == true ]]; then
    return
  fi
  if ! (cd "$repository_root" && pnpm db:reset >"$reset_log" 2>&1); then
    tail -n 80 "$reset_log" >&2
    echo "Kon de lokale Duindorp-database na de voorraadupgradetest niet herstellen." >&2
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

identity="$("${psql_cmd[@]}" -c "
  select concat_ws('|',
    current_database(),
    current_user,
    inet_server_port()::text
  )
")"
if [[ "$identity" != "postgres|postgres|5432" ]]; then
  echo "Voorraadupgradetest weigert onverwachte database-identiteit." >&2
  exit 1
fi

cd "$repository_root"
node scripts/run-supabase.mjs db reset --local \
  --version 20260813130000 --no-seed

"${psql_cmd[@]}" <<'SQL'
insert into app.seasons(id, name, default_amount_cents, status)
values (
  'fa100000-0000-4000-8000-000000000001',
  'Voorraadactie upgrade',
  10000,
  'open'
);

insert into app.action_items(
  type,
  season_id,
  object_type,
  object_id,
  source_type,
  source_id,
  dedupe_key,
  severity,
  visibility,
  reason_code,
  safe_context
) values (
  'out_of_stock',
  'fa100000-0000-4000-8000-000000000001',
  'article_variant',
  'fa200000-0000-4000-8000-000000000001',
  'mollie_acceptance',
  'fa300000-0000-4000-8000-000000000001',
  encode(
    extensions.digest('inventory-action-source-upgrade', 'sha256'),
    'hex'
  ),
  'warning',
  'operations',
  'inventory.zero_available',
  jsonb_build_object(
    'variantId', 'fa200000-0000-4000-8000-000000000001'::uuid,
    'available', 0,
    'shortage', 1,
    'waiterCount', 1
  )
);
SQL

node scripts/run-supabase.mjs migration up --local >/dev/null

result="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    item.source_type,
    item.source_id::text,
    constraint_state.convalidated::text,
    reconciliation.status,
    reconciliation.metrics ->> 'normalized_active_items'
  )
  from app.action_items item
  cross join pg_constraint constraint_state
  cross join private.migration_reconciliations reconciliation
  where item.season_id = 'fa100000-0000-4000-8000-000000000001'
    and item.type = 'out_of_stock'
    and item.status = 'open'
    and constraint_state.conrelid = 'app.action_items'::regclass
    and constraint_state.conname = 'action_items_active_inventory_source_check'
    and reconciliation.migration_key =
      '20260814120000_inventory_action_source_stability'
")"
expected="article_variant:fa200000-0000-4000-8000-000000000001:true:passed:1"
if [[ "$result" != "$expected" ]]; then
  echo "Onverwachte voorraadactie-upgradestaat: $result" >&2
  exit 1
fi

set +e
"${psql_cmd[@]}" -c "
  insert into app.action_items(
    type, season_id, object_type, object_id, source_type, source_id,
    dedupe_key, severity, visibility, reason_code, safe_context
  ) values (
    'low_stock',
    'fa100000-0000-4000-8000-000000000001',
    'article_variant',
    'fa200000-0000-4000-8000-000000000002',
    'inventory_delivery',
    'fa300000-0000-4000-8000-000000000002',
    encode(
      extensions.digest('inventory-action-source-invalid', 'sha256'),
      'hex'
    ),
    'warning',
    'operations',
    'inventory.below_threshold',
    jsonb_build_object(
      'variantId', 'fa200000-0000-4000-8000-000000000002'::uuid,
      'available', 1,
      'shortage', 1,
      'waiterCount', 1
    )
  );
" >/dev/null 2>&1
invalid_insert_status=$?
set -e
if [[ "$invalid_insert_status" -eq 0 ]]; then
  echo "Gevalideerde constraint accepteerde een instabiele actieve voorraadactie." >&2
  exit 1
fi

restore_latest
echo "Voorraadactie-upgradetest geslaagd: legacyepisode genormaliseerd en nieuwe drift databasebreed geblokkeerd."
