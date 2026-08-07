#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_url="postgresql://postgres:postgres@127.0.0.1:54339/postgres"
fixture_sql="${repository_root}/scripts/migrations/phase-b-legacy-fixture.sql"
fingerprint_sql="${repository_root}/scripts/migrations/legacy-domain-fingerprint.sql"
assert_sql="${repository_root}/scripts/migrations/assert-phase-b-expand.sql"
reset_log="$(mktemp)"
restored=false

restore_latest() {
  if [[ "$restored" == "true" ]]; then
    return
  fi
  if ! (cd "$repository_root" && pnpm db:reset >"$reset_log" 2>&1); then
    tail -n 80 "$reset_log" >&2
    echo "Kon de lokale Duindorp-database na de upgradetest niet herstellen." >&2
    return 1
  fi
  restored=true
}

cleanup() {
  status=$?
  restore_latest || status=1
  rm -f "$reset_log"
  exit "$status"
}
trap cleanup EXIT

psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1 -At)

identity="$("${psql_cmd[@]}" -c "
  select concat_ws('|',
    current_database(),
    current_user,
    inet_server_port()::text
  )
")"
if [[ "$identity" != "postgres|postgres|5432" ]]; then
  echo "Phase-B-upgradetest weigert onverwachte database-identiteit." >&2
  exit 1
fi

cd "$repository_root"
node scripts/run-supabase.mjs db reset --local \
  --version 20260802170000 --no-seed

if [[ "$("${psql_cmd[@]}" -c "
  select count(*) from supabase_migrations.schema_migrations
  where version = '20260802170000'
")" != "1" ]]; then
  echo "Legacy upgradebaseline 20260802170000 ontbreekt." >&2
  exit 1
fi
if [[ "$("${psql_cmd[@]}" -c "
  select count(*) from supabase_migrations.schema_migrations
  where version = '20260802180000'
")" != "0" ]]; then
  echo "Expand-migratie staat al op de legacybaseline." >&2
  exit 1
fi

"${psql_cmd[@]}" < "$fixture_sql" >/dev/null
before_fingerprint="$("${psql_cmd[@]}" < "$fingerprint_sql")"
if [[ ! "$before_fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Legacyfingerprint is ongeldig." >&2
  exit 1
fi

node scripts/run-supabase.mjs migration up --local

after_fingerprint="$("${psql_cmd[@]}" < "$fingerprint_sql")"
if [[ "$before_fingerprint" != "$after_fingerprint" ]]; then
  echo "Legacy geld-, voorraad-, uitgifte- of toegangskolommen wijzigden tijdens de expand-upgrade." >&2
  exit 1
fi

assertion_result="$("${psql_cmd[@]}" < "$assert_sql")"
if [[ "$assertion_result" != "phase-b-expand-upgrade-assertions-passed" ]]; then
  echo "Phase-B-upgradeasserties gaven geen geldig eindresultaat." >&2
  exit 1
fi

restore_latest
echo "Phase-B-upgradetest geslaagd: legacyhashes gelijk en alle reconciliatieasserties groen."
