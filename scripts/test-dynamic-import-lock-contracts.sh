#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1)
task_tmp="$(mktemp -d)"
reverse_one_log="${task_tmp}/reverse-one.log"
reverse_two_log="${task_tmp}/reverse-two.log"
catalog_import_log="${task_tmp}/catalog-import.log"
catalog_mutation_log="${task_tmp}/catalog-mutation.log"
member_import_log="${task_tmp}/member-import.log"
member_mutation_log="${task_tmp}/member-mutation.log"
cleanup_log="${task_tmp}/cleanup.log"
flag_before="$("${psql_cmd[@]}" -Atc "
  select enabled::text
  from app.release_feature_flags
  where key = 'dynamic_import_v2'
")"
active_season_before="$("${psql_cmd[@]}" -Atc "
  select coalesce(active_season_id::text, '')
  from app.app_settings
  where id = true
")"

cleanup_data() {
  "${psql_cmd[@]}" \
    -v flag_before="$flag_before" \
    -v active_season_before="$active_season_before" <<'SQL'
begin;
set local session_replication_role = replica;
delete from app.audit_logs
where entity_id = any(array[
  'dd100000-0000-4000-8000-000000000001'::uuid,
  'dd110000-0000-4000-8000-000000000001'::uuid,
  'dd130000-0000-4000-8000-000000000001'::uuid,
  'dd130000-0000-4000-8000-000000000002'::uuid,
  'dd130000-0000-4000-8000-000000000003'::uuid,
  'dd130000-0000-4000-8000-000000000004'::uuid,
  'dd200000-0000-4000-8000-000000000001'::uuid,
  'dd200000-0000-4000-8000-000000000002'::uuid,
  'dd200000-0000-4000-8000-000000000003'::uuid,
  'dd200000-0000-4000-8000-000000000004'::uuid
]);
delete from app.action_items
where season_id = 'dd100000-0000-4000-8000-000000000001';
delete from app.member_size_selection_history
where member_season_id in (
  select id
  from app.member_seasons
  where season_id = 'dd100000-0000-4000-8000-000000000001'
);
delete from app.member_article_sizes
where season_id = 'dd100000-0000-4000-8000-000000000001';
delete from app.member_seasons
where season_id = 'dd100000-0000-4000-8000-000000000001';
delete from app.member_external_identities
where member_id = any(array[
  'dd130000-0000-4000-8000-000000000001'::uuid,
  'dd130000-0000-4000-8000-000000000002'::uuid,
  'dd130000-0000-4000-8000-000000000003'::uuid,
  'dd130000-0000-4000-8000-000000000004'::uuid
]);
delete from private.member_sensitive_identity
where member_id = any(array[
  'dd130000-0000-4000-8000-000000000001'::uuid,
  'dd130000-0000-4000-8000-000000000002'::uuid,
  'dd130000-0000-4000-8000-000000000003'::uuid,
  'dd130000-0000-4000-8000-000000000004'::uuid
]);
delete from private.dynamic_import_run_leases
where run_id = any(array[
  'dd400000-0000-4000-8000-000000000001'::uuid,
  'dd400000-0000-4000-8000-000000000002'::uuid,
  'dd400000-0000-4000-8000-000000000003'::uuid,
  'dd400000-0000-4000-8000-000000000004'::uuid
]);
delete from private.dynamic_import_row_plans
where run_id = any(array[
  'dd400000-0000-4000-8000-000000000001'::uuid,
  'dd400000-0000-4000-8000-000000000002'::uuid,
  'dd400000-0000-4000-8000-000000000003'::uuid,
  'dd400000-0000-4000-8000-000000000004'::uuid
]);
delete from app.dynamic_import_row_results
where run_id = any(array[
  'dd400000-0000-4000-8000-000000000001'::uuid,
  'dd400000-0000-4000-8000-000000000002'::uuid,
  'dd400000-0000-4000-8000-000000000003'::uuid,
  'dd400000-0000-4000-8000-000000000004'::uuid
]);
delete from private.dynamic_import_selected_rows
where run_id = any(array[
  'dd400000-0000-4000-8000-000000000001'::uuid,
  'dd400000-0000-4000-8000-000000000002'::uuid,
  'dd400000-0000-4000-8000-000000000003'::uuid,
  'dd400000-0000-4000-8000-000000000004'::uuid
]);
delete from app.dynamic_import_runs
where id = any(array[
  'dd400000-0000-4000-8000-000000000001'::uuid,
  'dd400000-0000-4000-8000-000000000002'::uuid,
  'dd400000-0000-4000-8000-000000000003'::uuid,
  'dd400000-0000-4000-8000-000000000004'::uuid
]);
update app.import_batches
set active_mapping_revision_id = null
where id = any(array[
  'dd200000-0000-4000-8000-000000000001'::uuid,
  'dd200000-0000-4000-8000-000000000002'::uuid,
  'dd200000-0000-4000-8000-000000000003'::uuid,
  'dd200000-0000-4000-8000-000000000004'::uuid
]);
delete from app.import_mapping_revisions
where id = any(array[
  'dd300000-0000-4000-8000-000000000001'::uuid,
  'dd300000-0000-4000-8000-000000000002'::uuid,
  'dd300000-0000-4000-8000-000000000003'::uuid,
  'dd300000-0000-4000-8000-000000000004'::uuid
]);
delete from app.import_batches
where id = any(array[
  'dd200000-0000-4000-8000-000000000001'::uuid,
  'dd200000-0000-4000-8000-000000000002'::uuid,
  'dd200000-0000-4000-8000-000000000003'::uuid,
  'dd200000-0000-4000-8000-000000000004'::uuid
]);
delete from app.members
where id = any(array[
  'dd130000-0000-4000-8000-000000000001'::uuid,
  'dd130000-0000-4000-8000-000000000002'::uuid,
  'dd130000-0000-4000-8000-000000000003'::uuid,
  'dd130000-0000-4000-8000-000000000004'::uuid
]);
delete from app.article_seasons
where article_id = 'dd110000-0000-4000-8000-000000000001';
delete from app.article_variants
where article_id = 'dd110000-0000-4000-8000-000000000001';
delete from app.articles
where id = 'dd110000-0000-4000-8000-000000000001';
update app.app_settings
set active_season_id = nullif(:'active_season_before', '')::uuid
where id = true;
delete from app.seasons
where id = 'dd100000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'dd000000-0000-4000-8000-000000000001';
update app.release_feature_flags
set enabled = :'flag_before'::boolean
where key = 'dynamic_import_v2';
commit;
SQL
}

cleanup() {
  status=$?
  if ! cleanup_data >"$cleanup_log" 2>&1; then
    tail -n 40 "$cleanup_log" >&2
    status=1
  fi
  rm -f \
    "$reverse_one_log" \
    "$reverse_two_log" \
    "$catalog_import_log" \
    "$catalog_mutation_log" \
    "$member_import_log" \
    "$member_mutation_log" \
    "$cleanup_log"
  rmdir "$task_tmp"
  exit "$status"
}
trap cleanup EXIT

cleanup_data
"${psql_cmd[@]}" <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  'dd000000-0000-4000-8000-000000000001',
  'Import lockbeheer',
  'beheerder'
);
insert into app.seasons(id, name, default_amount_cents, status)
values(
  'dd100000-0000-4000-8000-000000000001',
  '2051/2052 importlocks',
  10000,
  'open'
);
update app.app_settings
set active_season_id = 'dd100000-0000-4000-8000-000000000001'
where id = true;
update app.release_feature_flags
set enabled = true
where key = 'dynamic_import_v2';

insert into app.articles(id, name, code, icon_type, active, sort_order)
values(
  'dd110000-0000-4000-8000-000000000001',
  'Importlockshirt',
  'LOCK-SHIRT',
  'shirt',
  true,
  1
);
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  active,
  sort_order
)
values(
  'dd120000-0000-4000-8000-000000000001',
  'dd110000-0000-4000-8000-000000000001',
  '152',
  'LOCK-152',
  true,
  1
);
insert into app.article_seasons(article_id, season_id)
values(
  'dd110000-0000-4000-8000-000000000001',
  'dd100000-0000-4000-8000-000000000001'
);
insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team,
  active_for_season,
  gender
)
values
  (
    'dd130000-0000-4000-8000-000000000001',
    'LOCK-A',
    'Lock',
    'Alpha',
    'lock-alpha@example.invalid',
    'LOCK-A0',
    true,
    'female'
  ),
  (
    'dd130000-0000-4000-8000-000000000002',
    'LOCK-B',
    'Lock',
    'Bravo',
    'lock-bravo@example.invalid',
    'LOCK-B0',
    true,
    'male'
  ),
  (
    'dd130000-0000-4000-8000-000000000003',
    'LOCK-C',
    'Lock',
    'Catalogus',
    'lock-catalogus@example.invalid',
    'LOCK-C0',
    true,
    'other'
  ),
  (
    'dd130000-0000-4000-8000-000000000004',
    'LOCK-D',
    'Lock',
    'Maat',
    'lock-maat@example.invalid',
    'LOCK-D0',
    true,
    'unknown'
  );

create temporary table lock_mappings(kind text, mapping jsonb);
insert into lock_mappings(kind, mapping)
values(
  'fields',
  jsonb_build_array(
    jsonb_build_object(
      'columnIndex', 0,
      'sourceHeaderHash', repeat('0', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'external_member_id'
      )
    ),
    jsonb_build_object(
      'columnIndex', 1,
      'sourceHeaderHash', repeat('1', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'first_name'
      )
    ),
    jsonb_build_object(
      'columnIndex', 2,
      'sourceHeaderHash', repeat('2', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'last_name'
      )
    ),
    jsonb_build_object(
      'columnIndex', 3,
      'sourceHeaderHash', repeat('3', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'team'
      )
    )
  )
);
insert into lock_mappings(kind, mapping)
select
  'catalog',
  mapping || jsonb_build_array(
    jsonb_build_object(
      'columnIndex', 4,
      'sourceHeaderHash', repeat('4', 64),
      'target', jsonb_build_object(
        'kind', 'product_size',
        'articleId', 'dd110000-0000-4000-8000-000000000001'
      )
    )
  )
from lock_mappings
where kind = 'fields';

insert into app.import_batches(
  id,
  file_name,
  checksum,
  actor_user_id,
  status,
  season_id,
  client_request_id,
  schema_version,
  dynamic_status,
  encoding,
  delimiter,
  byte_count,
  source_row_count,
  source_column_count,
  policy,
  mapping_hash,
  catalog_hash,
  preview_revision,
  next_source_row,
  expires_at
)
select
  batch_id,
  'import-locks.csv',
  repeat('a', 64),
  'dd000000-0000-4000-8000-000000000001',
  'preview',
  'dd100000-0000-4000-8000-000000000001',
  batch_id,
  2,
  'previewed',
  'UTF-8',
  ';',
  256,
  source_count,
  5,
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  repeat('b', 64),
  private.dynamic_import_catalog_hash(
    'dd100000-0000-4000-8000-000000000001'
  ),
  1,
  source_count + 2,
  timezone('utc', now()) + interval '10 minutes'
from (
  values
    ('dd200000-0000-4000-8000-000000000001'::uuid, 2),
    ('dd200000-0000-4000-8000-000000000002'::uuid, 2),
    ('dd200000-0000-4000-8000-000000000003'::uuid, 1),
    ('dd200000-0000-4000-8000-000000000004'::uuid, 1)
) fixture(batch_id, source_count);

insert into app.import_mapping_revisions(
  id,
  batch_id,
  season_id,
  revision,
  mapping,
  mapping_hash,
  header_hash,
  catalog_hash,
  policy,
  created_by
)
select
  fixture.mapping_id,
  fixture.batch_id,
  'dd100000-0000-4000-8000-000000000001',
  1,
  mapping.mapping,
  repeat('b', 64),
  repeat('c', 64),
  private.dynamic_import_catalog_hash(
    'dd100000-0000-4000-8000-000000000001'
  ),
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  'dd000000-0000-4000-8000-000000000001'
from (
  values
    (
      'dd300000-0000-4000-8000-000000000001'::uuid,
      'dd200000-0000-4000-8000-000000000001'::uuid,
      'fields'
    ),
    (
      'dd300000-0000-4000-8000-000000000002'::uuid,
      'dd200000-0000-4000-8000-000000000002'::uuid,
      'fields'
    ),
    (
      'dd300000-0000-4000-8000-000000000003'::uuid,
      'dd200000-0000-4000-8000-000000000003'::uuid,
      'catalog'
    ),
    (
      'dd300000-0000-4000-8000-000000000004'::uuid,
      'dd200000-0000-4000-8000-000000000004'::uuid,
      'fields'
    )
) fixture(mapping_id, batch_id, mapping_kind)
join lock_mappings mapping on mapping.kind = fixture.mapping_kind;
update app.import_batches batch
set active_mapping_revision_id = fixture.mapping_id
from (
  values
    (
      'dd200000-0000-4000-8000-000000000001'::uuid,
      'dd300000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'dd200000-0000-4000-8000-000000000002'::uuid,
      'dd300000-0000-4000-8000-000000000002'::uuid
    ),
    (
      'dd200000-0000-4000-8000-000000000003'::uuid,
      'dd300000-0000-4000-8000-000000000003'::uuid
    ),
    (
      'dd200000-0000-4000-8000-000000000004'::uuid,
      'dd300000-0000-4000-8000-000000000004'::uuid
    )
) fixture(batch_id, mapping_id)
where batch.id = fixture.batch_id;

insert into app.dynamic_import_runs(
  id,
  batch_id,
  mapping_revision_id,
  season_id,
  created_by,
  client_request_id,
  request_hash,
  status,
  source_row_count,
  next_source_row,
  next_analysis_source_row,
  next_commit_source_row,
  plan_hash,
  expires_at,
  started_at,
  previewed_at
)
select
  fixture.run_id,
  fixture.batch_id,
  fixture.mapping_id,
  'dd100000-0000-4000-8000-000000000001',
  'dd000000-0000-4000-8000-000000000001',
  fixture.request_id,
  repeat(fixture.hash_character, 64),
  'committing',
  fixture.source_count,
  fixture.source_count + 2,
  fixture.source_count + 2,
  2,
  repeat(fixture.plan_character, 64),
  timezone('utc', now()) + interval '10 minutes',
  timezone('utc', now()),
  timezone('utc', now())
from (
  values
    (
      'dd400000-0000-4000-8000-000000000001'::uuid,
      'dd200000-0000-4000-8000-000000000001'::uuid,
      'dd300000-0000-4000-8000-000000000001'::uuid,
      'dd410000-0000-4000-8000-000000000001'::uuid,
      2,
      '1',
      '5'
    ),
    (
      'dd400000-0000-4000-8000-000000000002'::uuid,
      'dd200000-0000-4000-8000-000000000002'::uuid,
      'dd300000-0000-4000-8000-000000000002'::uuid,
      'dd410000-0000-4000-8000-000000000002'::uuid,
      2,
      '2',
      '6'
    ),
    (
      'dd400000-0000-4000-8000-000000000003'::uuid,
      'dd200000-0000-4000-8000-000000000003'::uuid,
      'dd300000-0000-4000-8000-000000000003'::uuid,
      'dd410000-0000-4000-8000-000000000003'::uuid,
      1,
      '3',
      '7'
    ),
    (
      'dd400000-0000-4000-8000-000000000004'::uuid,
      'dd200000-0000-4000-8000-000000000004'::uuid,
      'dd300000-0000-4000-8000-000000000004'::uuid,
      'dd410000-0000-4000-8000-000000000004'::uuid,
      1,
      '4',
      '8'
    )
) fixture(
  run_id,
  batch_id,
  mapping_id,
  request_id,
  source_count,
  hash_character,
  plan_character
);

create temporary table selected_lock_rows(
  run_id uuid,
  source_row integer,
  external_id text,
  first_name text,
  last_name text,
  team text
);
insert into selected_lock_rows
values
  (
    'dd400000-0000-4000-8000-000000000001',
    2,
    'LOCK-A',
    'Lock',
    'Alpha',
    'LOCK-A1'
  ),
  (
    'dd400000-0000-4000-8000-000000000001',
    3,
    'LOCK-B',
    'Lock',
    'Bravo',
    'LOCK-B1'
  ),
  (
    'dd400000-0000-4000-8000-000000000002',
    2,
    'LOCK-B',
    'Lock',
    'Bravo',
    'LOCK-B2'
  ),
  (
    'dd400000-0000-4000-8000-000000000002',
    3,
    'LOCK-A',
    'Lock',
    'Alpha',
    'LOCK-A2'
  ),
  (
    'dd400000-0000-4000-8000-000000000003',
    2,
    'LOCK-C',
    'Lock',
    'Catalogus',
    'LOCK-C1'
  ),
  (
    'dd400000-0000-4000-8000-000000000004',
    2,
    'LOCK-D',
    'Lock',
    'Maat',
    'LOCK-D1'
  );
insert into private.dynamic_import_selected_rows(
  run_id,
  source_row,
  selected_values,
  row_hash,
  identity_key_hash,
  expires_at
)
select
  row.run_id,
  row.source_row,
  value.selected_values,
  encode(
    extensions.digest(convert_to(value.selected_values::text, 'UTF8'), 'sha256'
  ), 'hex'),
  private.dynamic_import_identity_key_hash(
    value.selected_values->'fields'
  ),
  timezone('utc', now()) + interval '10 minutes'
from selected_lock_rows row
cross join lateral (
  select jsonb_build_object(
    'sourceRow', row.source_row,
    'fields', jsonb_build_object(
      'external_member_id', row.external_id,
      'first_name', row.first_name,
      'last_name', row.last_name,
      'team', row.team
    ),
    'sizes', '{}'::jsonb,
    'errors', '[]'::jsonb
  ) selected_values
) value;
insert into app.dynamic_import_row_results(
  run_id,
  source_row,
  outcome,
  blocking,
  change_count
)
select run_id, source_row, 'update', false, 1
from selected_lock_rows;
insert into private.dynamic_import_row_plans(
  run_id,
  source_row,
  matched_member_id,
  state_hash,
  analysis_hash,
  resolved_variants
)
select
  analyzed.run_id,
  analyzed.source_row,
  nullif(analyzed.analysis->>'matchedMemberId', '')::uuid,
  analyzed.analysis->>'stateHash',
  analyzed.analysis->>'analysisHash',
  coalesce(analyzed.analysis->'resolvedVariants', '{}'::jsonb)
from (
  select
    row.run_id,
    row.source_row,
    private.dynamic_import_analyze_row(row.run_id, row.source_row) analysis
  from selected_lock_rows row
) analyzed;
insert into private.dynamic_import_run_leases(
  run_id,
  claim_token,
  generation,
  claimed_at,
  expires_at
)
select
  run_id,
  claim_token,
  1,
  timezone('utc', now()),
  timezone('utc', now()) + interval '55 seconds'
from (
  values
    (
      'dd400000-0000-4000-8000-000000000001'::uuid,
      'dd500000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'dd400000-0000-4000-8000-000000000002'::uuid,
      'dd500000-0000-4000-8000-000000000002'::uuid
    ),
    (
      'dd400000-0000-4000-8000-000000000003'::uuid,
      'dd500000-0000-4000-8000-000000000003'::uuid
    ),
    (
      'dd400000-0000-4000-8000-000000000004'::uuid,
      'dd500000-0000-4000-8000-000000000004'::uuid
    )
) fixture(run_id, claim_token);
SQL

commit_run() {
  local run_id="$1"
  local claim_token="$2"
  local row_limit="$3"
  "${psql_cmd[@]}" -At <<SQL
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select app.commit_dynamic_import_chunk(
  '${run_id}',
  '${claim_token}',
  1,
  ${row_limit}
);
SQL
}

set +e
commit_run \
  'dd400000-0000-4000-8000-000000000001' \
  'dd500000-0000-4000-8000-000000000001' \
  2 >"$reverse_one_log" 2>&1 &
reverse_one_pid=$!
commit_run \
  'dd400000-0000-4000-8000-000000000002' \
  'dd500000-0000-4000-8000-000000000002' \
  2 >"$reverse_two_log" 2>&1 &
reverse_two_pid=$!
wait "$reverse_one_pid"
reverse_one_status=$?
wait "$reverse_two_pid"
reverse_two_status=$?
set -e

if rg -q "deadlock detected|40P01" "$reverse_one_log" "$reverse_two_log"; then
  tail -n 30 "$reverse_one_log"
  tail -n 30 "$reverse_two_log"
  echo "Omgekeerde importvolgorde veroorzaakte een deadlock." >&2
  exit 1
fi
if [[ "$reverse_one_status" -eq "$reverse_two_status" ]]; then
  tail -n 30 "$reverse_one_log"
  tail -n 30 "$reverse_two_log"
  echo "Omgekeerde imports leverden geen exact-één veilige winnaar op." >&2
  exit 1
fi
if [[ "$reverse_one_status" -ne 0 ]]; then
  reverse_failure_log="$reverse_one_log"
else
  reverse_failure_log="$reverse_two_log"
fi
if ! rg -q "DYNAMIC_IMPORT_STATE_DRIFT" "$reverse_failure_log"; then
  tail -n 30 "$reverse_failure_log"
  echo "De verliezende omgekeerde import meldde geen state drift." >&2
  exit 1
fi

wait_for_sleeping_backend() {
  local application_name="$1"
  local attempt
  for attempt in $(seq 1 100); do
    if [[ "$("${psql_cmd[@]}" -Atc "
      select count(*)
      from pg_stat_activity
      where application_name = '${application_name}'
        and wait_event = 'PgSleep'
    ")" == "1" ]]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

PGAPPNAME="duindorp-import-catalog-lock" "${psql_cmd[@]}" >"$catalog_import_log" 2>&1 <<'SQL' &
begin;
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select app.commit_dynamic_import_chunk(
  'dd400000-0000-4000-8000-000000000003',
  'dd500000-0000-4000-8000-000000000003',
  1,
  1
);
select pg_sleep(2);
commit;
SQL
catalog_import_pid=$!
if ! wait_for_sleeping_backend "duindorp-import-catalog-lock"; then
  tail -n 40 "$catalog_import_log"
  echo "De catalogusimport bereikte de transactionele locktest niet." >&2
  exit 1
fi

"${psql_cmd[@]}" >"$catalog_mutation_log" 2>&1 <<'SQL' &
set role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"dd000000-0000-4000-8000-000000000001","aal":"aal2"}',
  false
);
select app.bulk_set_article_season(
  'dd100000-0000-4000-8000-000000000001',
  array['dd110000-0000-4000-8000-000000000001'::uuid],
  false,
  null
);
SQL
catalog_mutation_pid=$!
sleep 0.25
if ! kill -0 "$catalog_mutation_pid" 2>/dev/null; then
  wait "$catalog_mutation_pid" || true
  tail -n 40 "$catalog_mutation_log"
  echo "Catalogusontkoppeling passeerde de actieve importlock." >&2
  exit 1
fi
wait "$catalog_import_pid"
wait "$catalog_mutation_pid"
if [[ "$("${psql_cmd[@]}" -Atc "
  select count(*)
  from app.article_seasons
  where article_id = 'dd110000-0000-4000-8000-000000000001'
    and season_id = 'dd100000-0000-4000-8000-000000000001'
")" != "0" ]]; then
  echo "De geserialiseerde catalogusontkoppeling is niet toegepast." >&2
  exit 1
fi
"${psql_cmd[@]}" <<'SQL'
insert into app.article_seasons(article_id, season_id)
values(
  'dd110000-0000-4000-8000-000000000001',
  'dd100000-0000-4000-8000-000000000001'
);
SQL

member_revision="$("${psql_cmd[@]}" -Atc "
  select private.member_size_revision(
    'dd130000-0000-4000-8000-000000000004',
    'dd100000-0000-4000-8000-000000000001'
  )
")"
PGAPPNAME="duindorp-import-member-lock" "${psql_cmd[@]}" >"$member_import_log" 2>&1 <<'SQL' &
begin;
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select app.commit_dynamic_import_chunk(
  'dd400000-0000-4000-8000-000000000004',
  'dd500000-0000-4000-8000-000000000004',
  1,
  1
);
select pg_sleep(2);
commit;
SQL
member_import_pid=$!
if ! wait_for_sleeping_backend "duindorp-import-member-lock"; then
  tail -n 40 "$member_import_log"
  echo "De ledenimport bereikte de transactionele locktest niet." >&2
  exit 1
fi

"${psql_cmd[@]}" -v member_revision="$member_revision" >"$member_mutation_log" 2>&1 <<'SQL' &
set role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"dd000000-0000-4000-8000-000000000001","aal":"aal2"}',
  false
);
select app.set_member_article_sizes(
  'dd130000-0000-4000-8000-000000000004',
  'dd100000-0000-4000-8000-000000000001',
  jsonb_build_array(jsonb_build_object(
    'articleId', 'dd110000-0000-4000-8000-000000000001',
    'variantId', 'dd120000-0000-4000-8000-000000000001'
  )),
  :'member_revision',
  null
);
SQL
member_mutation_pid=$!
sleep 0.25
if ! kill -0 "$member_mutation_pid" 2>/dev/null; then
  wait "$member_mutation_pid" || true
  tail -n 40 "$member_mutation_log"
  echo "Maatmutatie passeerde de actieve importlock." >&2
  exit 1
fi
wait "$member_import_pid"
wait "$member_mutation_pid"

member_lock_result="$("${psql_cmd[@]}" -Atc "
  select
    member.team || ':' ||
    coalesce(size.article_variant_id::text, '')
  from app.members member
  left join app.member_article_sizes size
    on size.member_id = member.id
    and size.season_id = 'dd100000-0000-4000-8000-000000000001'
    and size.article_id = 'dd110000-0000-4000-8000-000000000001'
  where member.id = 'dd130000-0000-4000-8000-000000000004'
")"
if [[ "$member_lock_result" != \
  "LOCK-D1:dd120000-0000-4000-8000-000000000001" ]]; then
  tail -n 40 "$member_import_log"
  tail -n 40 "$member_mutation_log"
  echo "Onverwacht geserialiseerd leden-/maatresultaat: $member_lock_result" >&2
  exit 1
fi

echo "Dynamic-importlockcontracten geslaagd: reverse-order, catalogus en maatmutatie."
