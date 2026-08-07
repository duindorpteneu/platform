#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De supplier-racetest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-supplier-concurrency.XXXXXX)"
previous_active_season="$("${psql_cmd[@]}" -c "select coalesce(active_season_id::text, '') from app.app_settings where id=true")"
previous_active_season_sql="null"
if [[ -n "$previous_active_season" ]]; then
  previous_active_season_sql="'$previous_active_season'"
fi

cleanup_data() {
  "${psql_cmd[@]}" >/dev/null <<SQL
begin;
set local session_replication_role = replica;
delete from app.audit_logs
where entity_id in (
  select id from private.supplier_planner_principals
  where display_name = 'Supplier concurrency'
);
delete from private.supplier_planner_events
where principal_id in (
  select id from private.supplier_planner_principals
  where display_name = 'Supplier concurrency'
);
delete from private.supplier_planner_admin_requests
where principal_id in (
  select id from private.supplier_planner_principals
  where display_name = 'Supplier concurrency'
);
delete from private.supplier_planner_sessions
where principal_id in (
  select id from private.supplier_planner_principals
  where display_name = 'Supplier concurrency'
);
delete from private.supplier_planner_season_grants
where principal_id in (
  select id from private.supplier_planner_principals
  where display_name = 'Supplier concurrency'
);
delete from private.supplier_planner_principals
where display_name = 'Supplier concurrency';
delete from private.staff_sessions
where auth_user_id = 'fb000000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'fb000000-0000-4000-8000-000000000001';
update app.app_settings
set active_season_id = ${previous_active_season_sql}
where id = true;
delete from app.inventory_settings
where season_id = 'fb100000-0000-4000-8000-000000000001';
delete from app.seasons
where id = 'fb100000-0000-4000-8000-000000000001';
set local session_replication_role = origin;
commit;
SQL
}

cleanup() {
  local status=$?
  cleanup_data || status=1
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT
cleanup_data

"${psql_cmd[@]}" >/dev/null <<'SQL'
insert into app.staff_profiles(
  auth_user_id,
  display_name,
  role,
  active
) values (
  'fb000000-0000-4000-8000-000000000001',
  'Supplier concurrency beheerder',
  'beheerder',
  true
);
insert into app.seasons(id, name, default_amount_cents, status)
values (
  'fb100000-0000-4000-8000-000000000001',
  'Supplier concurrency',
  0,
  'open'
);
update app.app_settings
set active_season_id = 'fb100000-0000-4000-8000-000000000001'
where id = true;
select app.create_staff_app_session_for_user(
  'fb000000-0000-4000-8000-000000000001'
);
SQL

staff_session_hash="$("${psql_cmd[@]}" -c "
  select token_hash
  from private.staff_sessions
  where auth_user_id = 'fb000000-0000-4000-8000-000000000001'
    and revoked_at is null
  order by created_at desc
  limit 1;
")"

create_principal() {
  "${psql_cmd[@]}" -c "
    select app.manage_supplier_planner_v1(
      'create',
      'fb000000-0000-4000-8000-000000000001',
      '$staff_session_hash',
      'fb800000-0000-4000-8000-000000000001',
      null,
      'Supplier concurrency',
      repeat('a', 64),
      null,
      array['fb100000-0000-4000-8000-000000000001'::uuid]
    );
  "
}

create_principal >"$test_tmp_dir/create-1.log" 2>&1 &
first_pid=$!
create_principal >"$test_tmp_dir/create-2.log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

create_output="$test_tmp_dir/create-output.log"
cp "$test_tmp_dir/create-1.log" "$create_output"
sed -n '1,$p' "$test_tmp_dir/create-2.log" >>"$create_output"
if [[ "$(grep -c '"alreadyProcessed": false' "$create_output")" -ne 1 ]] \
  || [[ "$(grep -c '"alreadyProcessed": true' "$create_output")" -ne 1 ]]; then
  echo "Parallelle supplier-create was niet exact één mutatie plus één replay." >&2
  exit 1
fi

principal_id="$("${psql_cmd[@]}" -c "
  select id from private.supplier_planner_principals
  where display_name = 'Supplier concurrency';
")"
"${psql_cmd[@]}" >/dev/null -c "
  select app.create_supplier_planner_session_v1(
    repeat('a', 64),
    repeat('b', 64),
    repeat('c', 64)
  );
"

read_planning() {
  "${psql_cmd[@]}" -c "
    do \$race\$
    begin
      perform app.get_supplier_planning_v1(
        repeat('b', 64),
        'fb100000-0000-4000-8000-000000000001',
        null
      );
    exception when insufficient_privilege then
      null;
    end
    \$race\$;
  "
}

for read_index in 1 2 3 4 5 6 7 8; do
  read_planning >"$test_tmp_dir/read-$read_index.log" 2>&1 &
done
"${psql_cmd[@]}" -c "
  select app.manage_supplier_planner_v1(
    'rotate',
    'fb000000-0000-4000-8000-000000000001',
    '$staff_session_hash',
    'fb800000-0000-4000-8000-000000000002',
    '$principal_id',
    null,
    repeat('d', 64),
    'Concurrency sleutelrotatie',
    null
  );
" >"$test_tmp_dir/rotate.log" 2>&1
wait

state="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    (select count(*) from private.supplier_planner_principals
      where display_name = 'Supplier concurrency'),
    (select count(*) from private.supplier_planner_admin_requests
      where principal_id = '$principal_id'),
    (select count(*) from private.supplier_planner_events
      where principal_id = '$principal_id'
        and event_type = 'principal_created'),
    (select count(*) from private.supplier_planner_sessions
      where principal_id = '$principal_id'
        and revoked_at is null),
    (app.get_supplier_planner_context_v1(repeat('b', 64)) is null)::integer,
    (app.get_operational_health_v10(
      repeat('1', 64), 1, null, null
    ) #>> '{supplierPlanning,unauthorizedActiveSessions}')
  );
")"
if [[ "$state" != "1:2:1:0:1:0" ]]; then
  echo "Onverwachte supplier-concurrencystaat: $state" >&2
  exit 1
fi

echo "Supplier concurrency geslaagd: één create, exacte replay en geen sessiezombie na rotatie."
