#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prepare_sql="${repository_root}/scripts/providers/sql/mollie-fixture-prepare.sql"
state_sql="${repository_root}/scripts/providers/sql/mollie-fixture-state.sql"
cleanup_sql="${repository_root}/scripts/providers/sql/mollie-fixture-cleanup.sql"
removal_migration="${repository_root}/supabase/migrations/20260802170000_remove_product_mollie_acceptance_fixtures.sql"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1 -At)
fixture_args=(
  -v paid_member_id=a9100000-0000-4000-8000-000000000001
  -v mismatch_member_id=a9100000-0000-4000-8000-000000000002
  -v paid_order_id=a9200000-0000-4000-8000-000000000001
  -v mismatch_order_id=a9200000-0000-4000-8000-000000000002
  -v readiness_article_id=a9300000-0000-4000-8000-000000000001
  -v readiness_variant_id=a9400000-0000-4000-8000-000000000001
  -v readiness_order_line_id=a9500000-0000-4000-8000-000000000001
  -v readiness_qr_request_id=a9600000-0000-4000-8000-000000000001
  -v paid_relation=MOLLIE-12345a1-P
  -v mismatch_relation=MOLLIE-12345a1-M
  -v fixture_email=mollie-acceptance+12345a1@example.invalid
  -v state_order_id=a9200000-0000-4000-8000-000000000001
  -v state_member_id=a9100000-0000-4000-8000-000000000001
)
previous_mollie="$("${psql_cmd[@]}" -c "select mollie_enabled from app.app_settings where id = true")"
previous_active="$("${psql_cmd[@]}" -c "select coalesce(active_season_id::text, '') from app.app_settings where id = true")"

restore() {
  "${psql_cmd[@]}" "${fixture_args[@]}" < "$cleanup_sql" >/dev/null 2>&1 || true
  "${psql_cmd[@]}" -c "delete from app.members where id = 'a9100000-0000-4000-8000-000000000001'::uuid and relation_number = 'MOLLIE-COLLISION'" >/dev/null 2>&1 || true
  "${psql_cmd[@]}" -c "drop table if exists private.mollie_acceptance_fixtures" >/dev/null 2>&1 || true
  if [[ "$previous_mollie" == "t" ]]; then
    "${psql_cmd[@]}" -c "update app.app_settings set mollie_enabled = true where id = true" >/dev/null
  else
    "${psql_cmd[@]}" -c "update app.app_settings set mollie_enabled = false where id = true" >/dev/null
  fi
}
trap restore EXIT

if [[ ! "$previous_active" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "Mollie-fixture SQL-test vereist een actief lokaal seizoen." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select count(*) from app.seasons where id = '$previous_active'::uuid and status = 'open'")" != "1" ]]; then
  echo "Mollie-fixture SQL-test vereist een open lokaal seizoen." >&2
  exit 1
fi

restore

"${psql_cmd[@]}" -c "create table private.mollie_acceptance_fixtures (marker boolean not null); insert into private.mollie_acceptance_fixtures values (true)" >/dev/null
set +e
"${psql_cmd[@]}" < "$removal_migration" >/dev/null 2>&1
active_fixture_migration_status=$?
set -e
if [[ "$active_fixture_migration_status" -eq 0 ]]; then
  echo "Mollie-fixture removal migration accepteerde een actieve legacyledger." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select to_regclass('private.mollie_acceptance_fixtures') is not null")" != "t" ]]; then
  echo "Mollie-fixture removal migration verwijderde actieve herstelstaat." >&2
  exit 1
fi
"${psql_cmd[@]}" -c "drop table private.mollie_acceptance_fixtures" >/dev/null

"${psql_cmd[@]}" -c "insert into app.members (id, relation_number, first_name, last_name, email, team) values ('a9100000-0000-4000-8000-000000000001', 'MOLLIE-COLLISION', 'Collision', 'Guard', 'collision@example.invalid', 'MOLLIE-ACCEPTANCE')" >/dev/null
set +e
"${psql_cmd[@]}" "${fixture_args[@]}" < "$cleanup_sql" >/dev/null 2>&1
collision_cleanup_status=$?
set -e
if [[ "$collision_cleanup_status" -eq 0 ]]; then
  echo "Mollie-fixture cleanup accepteerde data zonder exact fixture-eigendom." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select count(*) from app.members where id = 'a9100000-0000-4000-8000-000000000001'::uuid and relation_number = 'MOLLIE-COLLISION'")" != "1" ]]; then
  echo "Mollie-fixture cleanup wijzigde collisiondata vóór de ownership-preflight." >&2
  exit 1
fi
"${psql_cmd[@]}" -c "delete from app.members where id = 'a9100000-0000-4000-8000-000000000001'::uuid and relation_number = 'MOLLIE-COLLISION'" >/dev/null

"${psql_cmd[@]}" -c "update app.app_settings set mollie_enabled = true where id = true" >/dev/null
settings_before="$("${psql_cmd[@]}" -c "select active_season_id::text || '|' || mollie_enabled::text from app.app_settings where id = true")"

if [[ "$("${psql_cmd[@]}" "${fixture_args[@]}" < "$prepare_sql")" != '{"prepared": true}' ]]; then
  echo "Mollie-fixture prepare gaf geen geldig resultaat." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select count(*) from app.members where id in ('a9100000-0000-4000-8000-000000000001','a9100000-0000-4000-8000-000000000002')")" != "2" ]]; then
  echo "Mollie-fixture bevat niet exact twee leden." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select count(*) from app.member_orders where id in ('a9200000-0000-4000-8000-000000000001','a9200000-0000-4000-8000-000000000002') and season_id = '$previous_active'::uuid and amount_due_cents = 100")" != "2" ]]; then
  echo "Mollie-fixture bevat niet exact twee begrensde orders." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" "${fixture_args[@]}" < "$prepare_sql")" != '{"prepared": true}' ]]; then
  echo "Mollie-fixture prepare is niet idempotent." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" "${fixture_args[@]}" < "$state_sql")" != "null" ]]; then
  echo "Mollie-fixture state is vóór checkout niet leeg." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select active_season_id::text || '|' || mollie_enabled::text from app.app_settings where id = true")" != "$settings_before" ]]; then
  echo "Mollie-fixture heeft globale instellingen gewijzigd." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" "${fixture_args[@]}" < "$cleanup_sql")" != '{"cleaned": true}' ]]; then
  echo "Mollie-fixture cleanup gaf geen geldig resultaat." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" "${fixture_args[@]}" < "$cleanup_sql")" != '{"cleaned": true}' ]]; then
  echo "Mollie-fixture cleanup is niet idempotent." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select count(*) from app.members where id in ('a9100000-0000-4000-8000-000000000001','a9100000-0000-4000-8000-000000000002')")" != "0" ]]; then
  echo "Mollie-fixture cleanup liet leden achter." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select count(*) from app.member_orders where id in ('a9200000-0000-4000-8000-000000000001','a9200000-0000-4000-8000-000000000002')")" != "0" ]]; then
  echo "Mollie-fixture cleanup liet orders achter." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "select to_regclass('private.mollie_acceptance_fixtures') is null")" != "t" ]]; then
  echo "Mollie-fixture heeft een duurzame fixturetabel gemaakt." >&2
  exit 1
fi

echo "Mollie-fixture SQL-integratietest geslaagd: begrensd, idempotent en zonder globale configuratiemutatie."
