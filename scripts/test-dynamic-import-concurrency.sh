#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1)
task_tmp="$(mktemp -d)"
claim_one_log="${task_tmp}/claim-one.log"
claim_two_log="${task_tmp}/claim-two.log"
commit_one_log="${task_tmp}/commit-one.log"
commit_two_log="${task_tmp}/commit-two.log"
stale_log="${task_tmp}/stale.log"
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
where entity_id in (
  'dc200000-0000-4000-8000-000000000001',
  'dc200000-0000-4000-8000-000000000002',
  'dc200000-0000-4000-8000-000000000003'
);
delete from app.action_items
where season_id = 'dc100000-0000-4000-8000-000000000001';
delete from app.member_size_selection_history
where member_season_id in (
  select id
  from app.member_seasons
  where season_id = 'dc100000-0000-4000-8000-000000000001'
);
delete from app.member_article_sizes
where season_id = 'dc100000-0000-4000-8000-000000000001';
delete from app.member_seasons
where season_id = 'dc100000-0000-4000-8000-000000000001';
delete from app.member_external_identities
where member_id in (
  select id
  from app.members
  where first_name = 'Race'
    and last_name = 'Import'
    and team = 'JO9-1'
);
delete from private.member_sensitive_identity
where member_id in (
  select id
  from app.members
  where first_name = 'Race'
    and last_name = 'Import'
    and team = 'JO9-1'
);
delete from app.members
where first_name = 'Race'
  and last_name = 'Import'
  and team = 'JO9-1';
delete from private.dynamic_import_run_leases
where run_id in (
  'dc400000-0000-4000-8000-000000000001',
  'dc400000-0000-4000-8000-000000000002',
  'dc400000-0000-4000-8000-000000000003'
);
delete from private.dynamic_import_row_plans
where run_id in (
  'dc400000-0000-4000-8000-000000000001',
  'dc400000-0000-4000-8000-000000000002',
  'dc400000-0000-4000-8000-000000000003'
);
delete from app.dynamic_import_row_results
where run_id in (
  'dc400000-0000-4000-8000-000000000001',
  'dc400000-0000-4000-8000-000000000002',
  'dc400000-0000-4000-8000-000000000003'
);
delete from private.dynamic_import_selected_rows
where run_id in (
  'dc400000-0000-4000-8000-000000000001',
  'dc400000-0000-4000-8000-000000000002',
  'dc400000-0000-4000-8000-000000000003'
);
delete from app.dynamic_import_runs
where id in (
  'dc400000-0000-4000-8000-000000000001',
  'dc400000-0000-4000-8000-000000000002',
  'dc400000-0000-4000-8000-000000000003'
);
update app.import_batches
set active_mapping_revision_id = null
where id in (
  'dc200000-0000-4000-8000-000000000001',
  'dc200000-0000-4000-8000-000000000002',
  'dc200000-0000-4000-8000-000000000003'
);
delete from app.import_mapping_revisions
where id in (
  'dc300000-0000-4000-8000-000000000001',
  'dc300000-0000-4000-8000-000000000002',
  'dc300000-0000-4000-8000-000000000003'
);
delete from app.import_batches
where id in (
  'dc200000-0000-4000-8000-000000000001',
  'dc200000-0000-4000-8000-000000000002',
  'dc200000-0000-4000-8000-000000000003'
);
update app.app_settings
set active_season_id = nullif(:'active_season_before', '')::uuid
where id = true;
delete from app.inventory_settings
where season_id = 'dc100000-0000-4000-8000-000000000001';
delete from app.seasons
where id = 'dc100000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'dc000000-0000-4000-8000-000000000001';
update app.release_feature_flags
set enabled = :'flag_before'::boolean
where key = 'dynamic_import_v2';
commit;
SQL
}

cleanup() {
  status=$?
  cleanup_data >/dev/null 2>&1 || status=1
  rm -f \
    "$claim_one_log" \
    "$claim_two_log" \
    "$commit_one_log" \
    "$commit_two_log" \
    "$stale_log"
  rmdir "$task_tmp"
  exit "$status"
}
trap cleanup EXIT

cleanup_data
"${psql_cmd[@]}" <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'dc000000-0000-4000-8000-000000000001',
  'Import concurrencybeheer',
  'beheerder'
);
insert into app.seasons(id, name, default_amount_cents, status)
values (
  'dc100000-0000-4000-8000-000000000001',
  '2049/2050 importconcurrency',
  10000,
  'open'
);
update app.app_settings
set active_season_id = 'dc100000-0000-4000-8000-000000000001'
where id = true;
update app.release_feature_flags
set enabled = true
where key = 'dynamic_import_v2';

create temporary table import_concurrency_mapping(mapping jsonb);
insert into import_concurrency_mapping(mapping)
values(jsonb_build_array(
  jsonb_build_object(
    'columnIndex', 0,
    'sourceHeaderHash', repeat('0', 64),
    'target', jsonb_build_object(
      'kind', 'member_field', 'field', 'external_member_id'
    )
  ),
  jsonb_build_object(
    'columnIndex', 1,
    'sourceHeaderHash', repeat('1', 64),
    'target', jsonb_build_object(
      'kind', 'member_field', 'field', 'first_name'
    )
  ),
  jsonb_build_object(
    'columnIndex', 2,
    'sourceHeaderHash', repeat('2', 64),
    'target', jsonb_build_object(
      'kind', 'member_field', 'field', 'last_name'
    )
  ),
  jsonb_build_object(
    'columnIndex', 3,
    'sourceHeaderHash', repeat('3', 64),
    'target', jsonb_build_object(
      'kind', 'member_field', 'field', 'team'
    )
  ),
  jsonb_build_object(
    'columnIndex', 4,
    'sourceHeaderHash', repeat('4', 64),
    'target', jsonb_build_object(
      'kind', 'member_field', 'field', 'date_of_birth'
    )
  )
));

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
  'import-concurrency.csv',
  repeat('a', 64),
  'dc000000-0000-4000-8000-000000000001',
  'preview',
  'dc100000-0000-4000-8000-000000000001',
  batch_id,
  2,
  case
    when batch_id = 'dc200000-0000-4000-8000-000000000001'::uuid
      then 'processing'::app.dynamic_import_status
    else 'previewed'::app.dynamic_import_status
  end,
  'UTF-8',
  ';',
  100,
  1,
  5,
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  repeat('b', 64),
  private.dynamic_import_catalog_hash(
    'dc100000-0000-4000-8000-000000000001'
  ),
  1,
  case
    when batch_id = 'dc200000-0000-4000-8000-000000000001'::uuid then 2
    else 3
  end,
  timezone('utc', now()) + interval '1 hour'
from unnest(array[
  'dc200000-0000-4000-8000-000000000001'::uuid,
  'dc200000-0000-4000-8000-000000000002'::uuid,
  'dc200000-0000-4000-8000-000000000003'::uuid
]) batch_id;

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
  mapping_id,
  batch_id,
  'dc100000-0000-4000-8000-000000000001',
  1,
  (select mapping from import_concurrency_mapping),
  repeat('b', 64),
  repeat('c', 64),
  private.dynamic_import_catalog_hash(
    'dc100000-0000-4000-8000-000000000001'
  ),
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  'dc000000-0000-4000-8000-000000000001'
from (
  values
    (
      'dc300000-0000-4000-8000-000000000001'::uuid,
      'dc200000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'dc300000-0000-4000-8000-000000000002'::uuid,
      'dc200000-0000-4000-8000-000000000002'::uuid
    ),
    (
      'dc300000-0000-4000-8000-000000000003'::uuid,
      'dc200000-0000-4000-8000-000000000003'::uuid
    )
) fixture(mapping_id, batch_id);
update app.import_batches batch
set active_mapping_revision_id = fixture.mapping_id
from (
  values
    (
      'dc200000-0000-4000-8000-000000000001'::uuid,
      'dc300000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'dc200000-0000-4000-8000-000000000002'::uuid,
      'dc300000-0000-4000-8000-000000000002'::uuid
    ),
    (
      'dc200000-0000-4000-8000-000000000003'::uuid,
      'dc300000-0000-4000-8000-000000000003'::uuid
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
  next_commit_source_row,
  plan_hash,
  expires_at,
  started_at,
  previewed_at
) values
  (
    'dc400000-0000-4000-8000-000000000001',
    'dc200000-0000-4000-8000-000000000001',
    'dc300000-0000-4000-8000-000000000001',
    'dc100000-0000-4000-8000-000000000001',
    'dc000000-0000-4000-8000-000000000001',
    'dc500000-0000-4000-8000-000000000001',
    repeat('d', 64),
    'queued_preview',
    1,
    2,
    2,
    null,
    timezone('utc', now()) + interval '1 hour',
    null,
    null
  ),
  (
    'dc400000-0000-4000-8000-000000000002',
    'dc200000-0000-4000-8000-000000000002',
    'dc300000-0000-4000-8000-000000000002',
    'dc100000-0000-4000-8000-000000000001',
    'dc000000-0000-4000-8000-000000000001',
    'dc500000-0000-4000-8000-000000000002',
    repeat('e', 64),
    'committing',
    1,
    3,
    2,
    repeat('f', 64),
    timezone('utc', now()) + interval '1 hour',
    timezone('utc', now()),
    timezone('utc', now())
  ),
  (
    'dc400000-0000-4000-8000-000000000003',
    'dc200000-0000-4000-8000-000000000003',
    'dc300000-0000-4000-8000-000000000003',
    'dc100000-0000-4000-8000-000000000001',
    'dc000000-0000-4000-8000-000000000001',
    'dc500000-0000-4000-8000-000000000003',
    repeat('1', 64),
    'committing',
    1,
    3,
    2,
    repeat('2', 64),
    timezone('utc', now()) + interval '1 hour',
    timezone('utc', now()),
    timezone('utc', now())
  );

with selected_values as (
  select
    run_id,
    jsonb_build_object(
      'sourceRow', 2,
      'fields', fields,
      'sizes', '{}'::jsonb,
      'errors', '[]'::jsonb
    ) value
  from (
    values
      (
        'dc400000-0000-4000-8000-000000000002'::uuid,
        jsonb_build_object(
          'external_member_id', 'IMPORT-RACE-1',
          'first_name', 'Race',
          'last_name', 'Import',
          'team', 'JO9-1',
          'date_of_birth', '2018-05-05'
        )
      ),
      (
        'dc400000-0000-4000-8000-000000000003'::uuid,
        jsonb_build_object(
          'first_name', 'Race',
          'last_name', 'Import',
          'team', 'JO9-1',
          'date_of_birth', '2018-05-05'
        )
      )
  ) fixture(run_id, fields)
)
insert into private.dynamic_import_selected_rows(
  run_id,
  source_row,
  selected_values,
  row_hash,
  identity_key_hash,
  expires_at
)
select
  run_id,
  2,
  value,
  encode(extensions.digest(convert_to(value::text, 'UTF8'), 'sha256'), 'hex'),
  private.dynamic_import_identity_key_hash(value->'fields'),
  timezone('utc', now()) + interval '1 hour'
from selected_values;

insert into app.dynamic_import_row_results(
  run_id,
  source_row,
  outcome,
  blocking,
  change_count
)
select run_id, 2, 'create', false, 1
from unnest(array[
  'dc400000-0000-4000-8000-000000000002'::uuid,
  'dc400000-0000-4000-8000-000000000003'::uuid
]) run_id;
insert into private.dynamic_import_row_plans(
  run_id,
  source_row,
  matched_member_id,
  state_hash,
  analysis_hash
)
select
  run_id,
  2,
  nullif(analysis->>'matchedMemberId', '')::uuid,
  analysis->>'stateHash',
  analysis->>'analysisHash'
from (
  select
    run_id,
    private.dynamic_import_analyze_row(run_id, 2) analysis
  from unnest(array[
    'dc400000-0000-4000-8000-000000000002'::uuid,
    'dc400000-0000-4000-8000-000000000003'::uuid
  ]) run_id
) analyzed;
insert into private.dynamic_import_run_leases(
  run_id,
  claim_token,
  generation,
  claimed_at,
  expires_at
) values
  (
    'dc400000-0000-4000-8000-000000000002',
    'dc700000-0000-4000-8000-000000000002',
    1,
    timezone('utc', now()),
    timezone('utc', now()) + interval '55 seconds'
  ),
  (
    'dc400000-0000-4000-8000-000000000003',
    'dc700000-0000-4000-8000-000000000003',
    1,
    timezone('utc', now()),
    timezone('utc', now()) + interval '55 seconds'
  );
SQL

claim_import() {
  local claim_token="$1"
  "${psql_cmd[@]}" -At <<SQL
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select app.claim_dynamic_import_run(
  '${claim_token}',
  15
);
SQL
}

claim_import 'dc700000-0000-4000-8000-000000000011' >"$claim_one_log" 2>&1 &
claim_one_pid=$!
claim_import 'dc700000-0000-4000-8000-000000000012' >"$claim_two_log" 2>&1 &
claim_two_pid=$!
wait "$claim_one_pid"
wait "$claim_two_pid"

claimed_jobs="$(
  {
    rg -c '"runId"' "$claim_one_log" || true
    rg -c '"runId"' "$claim_two_log" || true
  } | awk '{total += $1} END {print total + 0}'
)"
if [[ "$claimed_jobs" != "1" ]]; then
  tail -n 20 "$claim_one_log"
  tail -n 20 "$claim_two_log"
  echo "Gelijktijdige workers claimden niet exact één importrun." >&2
  exit 1
fi

claim_state="$("${psql_cmd[@]}" -Atc "
  select run.attempt_count::text || ':' || lease.generation::text
  from app.dynamic_import_runs run
  join private.dynamic_import_run_leases lease on lease.run_id = run.id
  where run.id = 'dc400000-0000-4000-8000-000000000001'
")"
if [[ "$claim_state" != "1:1" ]]; then
  echo "Onverwachte importclaimstatus: $claim_state" >&2
  exit 1
fi

old_claim_token="$("${psql_cmd[@]}" -Atc "
  select claim_token::text
  from private.dynamic_import_run_leases
  where run_id = 'dc400000-0000-4000-8000-000000000001'
")"
"${psql_cmd[@]}" <<'SQL'
update private.dynamic_import_run_leases
set claimed_at = timezone('utc', now()) - interval '2 minutes',
    expires_at = timezone('utc', now()) - interval '1 minute'
where run_id = 'dc400000-0000-4000-8000-000000000001';
SQL
claim_import 'dc700000-0000-4000-8000-000000000013' >/dev/null

set +e
"${psql_cmd[@]}" -v old_claim_token="$old_claim_token" >"$stale_log" 2>&1 <<'SQL'
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select app.stage_dynamic_import_rows(
  'dc400000-0000-4000-8000-000000000001',
  :'old_claim_token',
  1,
  2,
  jsonb_build_array(jsonb_build_object(
    'sourceRow', 2,
    'fields', jsonb_build_object(
      'external_member_id', 'STALE-IMPORT',
      'first_name', 'Stale',
      'last_name', 'Worker',
      'team', 'JO9-1'
    ),
    'sizes', '{}'::jsonb,
    'errors', '[]'::jsonb
  ))
);
SQL
stale_status=$?
set -e
if [[ "$stale_status" -eq 0 ]] || ! rg -q "DYNAMIC_IMPORT_LEASE_CONFLICT" "$stale_log"; then
  tail -n 30 "$stale_log"
  echo "Een verouderde importlease kon nog schrijven." >&2
  exit 1
fi

set +e
"${psql_cmd[@]}" -v old_claim_token="$old_claim_token" >"$stale_log" 2>&1 <<'SQL'
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select app.fail_dynamic_import_run(
  'dc400000-0000-4000-8000-000000000001',
  :'old_claim_token',
  1,
  'stale_worker_failure'
);
SQL
stale_status=$?
set -e
if [[ "$stale_status" -eq 0 ]] || ! rg -q "DYNAMIC_IMPORT_LEASE_CONFLICT" "$stale_log"; then
  tail -n 30 "$stale_log"
  echo "Een verouderde worker kon de importrun nog als mislukt afsluiten." >&2
  exit 1
fi

commit_import() {
  local run_id="$1"
  local claim_token="$2"
  "${psql_cmd[@]}" -At <<SQL
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select app.commit_dynamic_import_chunk(
  '${run_id}',
  '${claim_token}',
  1,
  1
);
SQL
}

set +e
commit_import \
  'dc400000-0000-4000-8000-000000000002' \
  'dc700000-0000-4000-8000-000000000002' >"$commit_one_log" 2>&1 &
commit_one_pid=$!
commit_import \
  'dc400000-0000-4000-8000-000000000003' \
  'dc700000-0000-4000-8000-000000000003' >"$commit_two_log" 2>&1 &
commit_two_pid=$!
wait "$commit_one_pid"
commit_one_status=$?
wait "$commit_two_pid"
commit_two_status=$?
set -e

if [[ "$commit_one_status" -eq "$commit_two_status" ]]; then
  tail -n 30 "$commit_one_log"
  tail -n 30 "$commit_two_log"
  echo "Dezelfde importidentiteit werd niet exact eenmaal gecommit." >&2
  exit 1
fi
if [[ "$commit_one_status" -ne 0 ]]; then
  failed_commit_log="$commit_one_log"
else
  failed_commit_log="$commit_two_log"
fi
if ! rg -q "DYNAMIC_IMPORT_STATE_DRIFT" "$failed_commit_log"; then
  tail -n 30 "$failed_commit_log"
  echo "De verliezende importcommit meldde geen veilige state drift." >&2
  exit 1
fi

race_result="$("${psql_cmd[@]}" -Atc "
  select
    (
      select count(*)
      from app.members
      where first_name = 'Race'
        and last_name = 'Import'
        and team = 'JO9-1'
    )
    || ':' ||
    (
      select count(*)
      from private.dynamic_import_row_plans
      where run_id in (
        'dc400000-0000-4000-8000-000000000002',
        'dc400000-0000-4000-8000-000000000003'
      )
        and committed_at is not null
    )
")"
if [[ "$race_result" != "1:1" ]]; then
  echo "Onverwacht importidentiteitsresultaat: $race_result" >&2
  exit 1
fi

bash "$(dirname "$0")/test-dynamic-import-lock-contracts.sh"

echo "Dynamic-importconcurrencytest geslaagd: claim, fencing, identiteit en lockcontracten."
