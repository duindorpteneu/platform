#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1)
first_log="/tmp/duindorp-variant-alias-first.log"
second_log="/tmp/duindorp-variant-alias-second.log"

cleanup() {
  "${psql_cmd[@]}" <<'SQL'
delete from app.audit_logs
where actor_user_id = 'ac000000-0000-4000-8000-000000000001'
   or entity_id in (
     'ac200000-0000-4000-8000-000000000001',
     'ac300000-0000-4000-8000-000000000001',
     'ac300000-0000-4000-8000-000000000002'
   );
delete from app.article_variant_aliases
where article_id = 'ac200000-0000-4000-8000-000000000001';
delete from app.article_variants
where article_id = 'ac200000-0000-4000-8000-000000000001';
delete from app.articles
where id = 'ac200000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'ac000000-0000-4000-8000-000000000001';
SQL
}

trap cleanup EXIT
cleanup

"${psql_cmd[@]}" <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'ac000000-0000-4000-8000-000000000001',
  'Alias concurrencycommissie',
  'kledingcommissie'
);
insert into app.articles(id, name, code, icon_type, sort_order)
values (
  'ac200000-0000-4000-8000-000000000001',
  'Alias concurrencyproduct',
  'ALIAS-RACE',
  'shirt',
  10
);
SQL

run_first() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.upsert_catalog_variant_v2(
  'ac200000-0000-4000-8000-000000000001',
  null,
  'M',
  null,
  array['Medium'],
  true,
  10
);
select pg_sleep(2);
commit;
SQL
}

run_second() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"ac000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.upsert_catalog_variant(
  'ac200000-0000-4000-8000-000000000001',
  null,
  'ｍ',
  null,
  true,
  20
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
if [[ "$second_status" -eq 0 ]] || ! grep -q "VARIANT_MATCH_KEY_EXISTS" "$second_log"; then
  tail -n 40 "$second_log"
  exit 1
fi

result=$("${psql_cmd[@]}" -Atc "
  select count(*) || ':' || min(private.normalize_size_match(size))
  from app.article_variants
  where article_id = 'ac200000-0000-4000-8000-000000000001'
")
if [[ "$result" != "1:M" ]]; then
  echo "Onverwacht aliasrace-resultaat: $result"
  exit 1
fi

echo "Maatalias-concurrencytest geslaagd: v2 en legacy serialiseren op dezelfde productsleutel."
