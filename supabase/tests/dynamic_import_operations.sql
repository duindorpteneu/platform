begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(
  has_function_privilege(
    'service_role',
    'app.cleanup_expired_security_data_v3(timestamptz)',
    'EXECUTE'
  ),
  'alleen de serviceworker kan importretentie uitvoeren'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.cleanup_expired_security_data_v3(timestamptz)',
    'EXECUTE'
  ),
  'authenticated kan importretentie niet uitvoeren'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.get_operational_health_v4()',
    'EXECUTE'
  ),
  'de serviceworker kan private operationele health lezen'
);
select ok(
  not has_function_privilege(
    'anon',
    'app.get_operational_health_v4()',
    'EXECUTE'
  ),
  'anon kan operationele health niet lezen'
);
select ok(
  has_function_privilege(
    'service_role',
    'app.release_dynamic_import_run_lease(uuid,uuid,integer)',
    'EXECUTE'
  ),
  'alleen de serviceworker kan een eigen importlease vrijgeven'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.release_dynamic_import_run_lease(uuid,uuid,integer)',
    'EXECUTE'
  ),
  'medewerkers kunnen geen importleases vrijgeven'
);

insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  'fa000000-0000-4000-8000-000000000001',
  'Importretentiebeheer',
  'beheerder'
);
insert into app.seasons(id, name, default_amount_cents, status)
values(
  'fa100000-0000-4000-8000-000000000001',
  '2050/2051 importretentie',
  10000,
  'open'
);
update app.release_feature_flags
set enabled = true
where key = 'dynamic_import_v2';

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
  next_source_row,
  expires_at,
  created_at
)
select
  batch_id,
  'operations.csv',
  repeat('a', 64),
  'fa000000-0000-4000-8000-000000000001',
  'preview',
  'fa100000-0000-4000-8000-000000000001',
  request_id,
  2,
  'processing',
  'UTF-8',
  ';',
  100,
  1,
  1,
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  repeat('b', 64),
  repeat('c', 64),
  2,
  expires_at,
  created_at
from (
  values
    (
      'fa200000-0000-4000-8000-000000000001'::uuid,
      'fa210000-0000-4000-8000-000000000001'::uuid,
      timezone('utc', now()) - interval '1 minute',
      timezone('utc', now()) - interval '20 minutes'
    ),
    (
      'fa200000-0000-4000-8000-000000000002'::uuid,
      'fa210000-0000-4000-8000-000000000002'::uuid,
      timezone('utc', now()) + interval '2 hours',
      timezone('utc', now()) - interval '40 minutes'
    ),
    (
      'fa200000-0000-4000-8000-000000000003'::uuid,
      'fa210000-0000-4000-8000-000000000003'::uuid,
      timezone('utc', now()) - interval '1 minute',
      timezone('utc', now()) - interval '10 minutes'
    )
) fixture(batch_id, request_id, expires_at, created_at);

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
  'fa100000-0000-4000-8000-000000000001',
  1,
  jsonb_build_array(
    jsonb_build_object(
      'columnIndex', 0,
      'sourceHeaderHash', repeat('d', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'first_name'
      )
    )
  ),
  repeat('b', 64),
  repeat('d', 64),
  repeat('c', 64),
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  'fa000000-0000-4000-8000-000000000001'
from (
  values
    (
      'fa300000-0000-4000-8000-000000000001'::uuid,
      'fa200000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'fa300000-0000-4000-8000-000000000002'::uuid,
      'fa200000-0000-4000-8000-000000000002'::uuid
    ),
    (
      'fa300000-0000-4000-8000-000000000003'::uuid,
      'fa200000-0000-4000-8000-000000000003'::uuid
    )
) fixture(mapping_id, batch_id);

update app.import_batches batch
set active_mapping_revision_id = fixture.mapping_id
from (
  values
    (
      'fa200000-0000-4000-8000-000000000001'::uuid,
      'fa300000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'fa200000-0000-4000-8000-000000000002'::uuid,
      'fa300000-0000-4000-8000-000000000002'::uuid
    ),
    (
      'fa200000-0000-4000-8000-000000000003'::uuid,
      'fa300000-0000-4000-8000-000000000003'::uuid
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
  created_at,
  started_at,
  previewed_at,
  commit_requested_at
)
values
  (
    'fa400000-0000-4000-8000-000000000001',
    'fa200000-0000-4000-8000-000000000001',
    'fa300000-0000-4000-8000-000000000001',
    'fa100000-0000-4000-8000-000000000001',
    'fa000000-0000-4000-8000-000000000001',
    'fa410000-0000-4000-8000-000000000001',
    repeat('e', 64),
    'committing',
    1,
    3,
    3,
    3,
    repeat('f', 64),
    timezone('utc', now()) - interval '1 minute',
    timezone('utc', now()) - interval '20 minutes',
    timezone('utc', now()) - interval '19 minutes',
    timezone('utc', now()) - interval '18 minutes',
    timezone('utc', now()) - interval '10 minutes'
  ),
  (
    'fa400000-0000-4000-8000-000000000002',
    'fa200000-0000-4000-8000-000000000002',
    'fa300000-0000-4000-8000-000000000002',
    'fa100000-0000-4000-8000-000000000001',
    'fa000000-0000-4000-8000-000000000001',
    'fa410000-0000-4000-8000-000000000002',
    repeat('1', 64),
    'queued_preview',
    1,
    2,
    2,
    2,
    null,
    timezone('utc', now()) + interval '2 hours',
    timezone('utc', now()) - interval '40 minutes',
    null,
    null,
    null
  ),
  (
    'fa400000-0000-4000-8000-000000000003',
    'fa200000-0000-4000-8000-000000000003',
    'fa300000-0000-4000-8000-000000000003',
    'fa100000-0000-4000-8000-000000000001',
    'fa000000-0000-4000-8000-000000000001',
    'fa410000-0000-4000-8000-000000000003',
    repeat('2', 64),
    'staging',
    1,
    2,
    2,
    2,
    null,
    timezone('utc', now()) - interval '1 minute',
    timezone('utc', now()) - interval '10 minutes',
    timezone('utc', now()) - interval '9 minutes',
    null,
    null
  );

insert into app.dynamic_import_row_results(
  run_id,
  source_row,
  outcome,
  blocking,
  change_count
)
values(
  'fa400000-0000-4000-8000-000000000001',
  2,
  'create',
  false,
  1
);
insert into private.dynamic_import_selected_rows(
  run_id,
  source_row,
  selected_values,
  row_hash,
  expires_at
)
values(
  'fa400000-0000-4000-8000-000000000001',
  2,
  jsonb_build_object(
    'sourceRow', 2,
    'fields', jsonb_build_object('first_name', 'Retentiecontrole'),
    'sizes', '{}'::jsonb,
    'errors', '[]'::jsonb
  ),
  repeat('3', 64),
  timezone('utc', now()) - interval '1 minute'
);
insert into private.dynamic_import_row_plans(
  run_id,
  source_row,
  state_hash,
  analysis_hash,
  resolved_variants,
  processed_at,
  committed_at,
  commit_disposition
)
values(
  'fa400000-0000-4000-8000-000000000001',
  2,
  repeat('4', 64),
  repeat('5', 64),
  '{}'::jsonb,
  timezone('utc', now()) - interval '5 minutes',
  timezone('utc', now()) - interval '5 minutes',
  'applied'
);
insert into private.dynamic_import_run_leases(
  run_id,
  claim_token,
  generation,
  claimed_at,
  expires_at
)
values(
  'fa400000-0000-4000-8000-000000000001',
  'fa500000-0000-4000-8000-000000000001',
  1,
  timezone('utc', now()) - interval '2 minutes',
  timezone('utc', now()) - interval '1 minute'
);
insert into private.operation_runs(
  id,
  operation,
  status,
  started_at,
  finished_at,
  processed_count
)
values(
  'fa600000-0000-4000-8000-000000000001',
  'import_worker',
  'succeeded',
  timezone('utc', now()) - interval '11 minutes',
  timezone('utc', now()) - interval '10 minutes',
  1
);
insert into private.operation_runs(
  id,
  operation,
  status,
  started_at
)
values(
  'fa600000-0000-4000-8000-000000000002',
  'import_worker',
  'running',
  timezone('utc', now()) - interval '5 minutes'
);

insert into private.dynamic_import_run_leases(
  run_id,
  claim_token,
  generation,
  claimed_at,
  expires_at
)
values(
  'fa400000-0000-4000-8000-000000000002',
  'fa500000-0000-4000-8000-000000000002',
  1,
  clock_timestamp(),
  clock_timestamp() + interval '55 seconds'
);

update private.dynamic_import_run_leases
set expires_at = clock_timestamp() + interval '1 second'
where run_id = 'fa400000-0000-4000-8000-000000000002';

select ok(
  (
    select expires_at >= clock_timestamp() + interval '54 seconds'
    from private.dynamic_import_run_leases
    where run_id = 'fa400000-0000-4000-8000-000000000002'
  ),
  'een same-owner leaseverlenging gebruikt de actuele wandklok'
);

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select ok(
  not app.release_dynamic_import_run_lease(
    'fa400000-0000-4000-8000-000000000002',
    'fa500000-0000-4000-8000-000000000099',
    1
  ),
  'een vreemde claimtoken kan een actieve importlease niet vrijgeven'
);
select ok(
  app.release_dynamic_import_run_lease(
    'fa400000-0000-4000-8000-000000000002',
    'fa500000-0000-4000-8000-000000000002',
    1
  ),
  'de actuele worker kan zijn eigen begrensde chunklease vrijgeven'
);
reset role;
select is(
  (
    select count(*)
    from private.dynamic_import_run_leases
    where run_id = 'fa400000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'de vrijgegeven chunklease is verwijderd'
);

create temporary table first_cleanup(result jsonb);
grant select, insert on first_cleanup to service_role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into first_cleanup(result)
select app.cleanup_expired_security_data_v3(timezone('utc', now()));
reset role;

select is(
  (select (result->>'importPartialFailures')::integer from first_cleanup),
  1,
  'een verlopen gedeeltelijke commit wordt als reconciliatieblokkade gemarkeerd'
);
select is(
  (select (result->>'importRunsExpired')::integer from first_cleanup),
  1,
  'een gewone verlopen stagingrun wordt zonder gedeeltelijke-commitincident gesloten'
);
select is(
  (select (result->>'importSelectedRows')::integer from first_cleanup),
  1,
  'verlopen geselecteerde bronwaarden worden verwijderd'
);
select is(
  (select (result->>'importPlansPurged')::integer from first_cleanup),
  0,
  'het plan van een recente gedeeltelijke commit blijft voor reconciliatie behouden'
);
select is(
  (
    select status::text || ':' || failure_code
    from app.dynamic_import_runs
    where id = 'fa400000-0000-4000-8000-000000000001'
  ),
  'failed:partial_commit_expired',
  'de gedeeltelijke importrun krijgt een expliciete foutstatus'
);
select is(
  (
    select status::text || ':' || dynamic_status::text || ':' || failure_code
    from app.import_batches
    where id = 'fa200000-0000-4000-8000-000000000001'
  ),
  'failed:failed:partial_commit_expired',
  'de importbatch krijgt dezelfde expliciete foutstatus'
);
select is(
  (
    select count(*)
    from private.dynamic_import_run_leases
    where run_id = 'fa400000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'de verlopen lease is verwijderd'
);
select is(
  (
    select count(*)
    from private.dynamic_import_row_plans
    where run_id = 'fa400000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'reconciliatiebewijs blijft dertig dagen beschikbaar'
);
select is(
  (
    select count(*)
    from app.action_items
    where type = 'import_failure'
      and object_id = 'fa200000-0000-4000-8000-000000000001'
      and severity = 'critical'
      and status = 'open'
  ),
  1::bigint,
  'exact één critical adminactie blokkeert verdere promotie'
);
select ok(
  not exists(
    select 1
    from app.action_items item
    where item.type = 'import_failure'
      and item.object_id = 'fa200000-0000-4000-8000-000000000001'
      and item.safe_context::text ~* 'Retentiecontrole'
  ),
  'het incidentactiepunt bevat geen geselecteerde bronwaarde'
);
select is(
  (
    select count(*)
    from app.audit_logs
    where action = 'members.import.partial_commit.expired'
      and entity_id = 'fa200000-0000-4000-8000-000000000001'
      and actor_user_id is null
  ),
  1::bigint,
  'de scheduler schrijft één eerlijk systeem-auditevent zonder beheerderimpersonatie'
);
select is(
  (
    select count(*)
    from app.action_items
    where type = 'import_failure'
      and object_id = 'fa200000-0000-4000-8000-000000000003'
  ),
  0::bigint,
  'een gewone verlopen stagingrun veroorzaakt geen vals partial-commitincident'
);

create temporary table health_after_cleanup as
select app.get_operational_health_v4() result;
select is(
  (select result #>> '{importControl,processingEnabled}' from health_after_cleanup),
  'true',
  'health rapporteert de databasefeaturepoort'
);
select is(
  (select result #>> '{importControl,cutoverActive}' from health_after_cleanup),
  'true',
  'health rapporteert de duurzame v2-cutover'
);
select is(
  (select result #>> '{importRuns,reconciliationRequired}' from health_after_cleanup),
  '1',
  'health blokkeert op het open critical reconciliatieactiepunt'
);
select is(
  (select result #>> '{importRuns,backlogStale}' from health_after_cleanup),
  'true',
  'een previewbacklog ouder dan dertig minuten is zichtbaar'
);
select is(
  (
    select (
      result #>> '{importRuns,oldestPendingAt}'
    )::timestamptz = (
      select created_at
      from app.dynamic_import_runs
      where id = 'fa400000-0000-4000-8000-000000000002'
    )
    from health_after_cleanup
  ),
  true,
  'oldestPendingAt wijst naar de werkelijk oudste wachtende run'
);
select is(
  (select result #>> '{operations,importWorker,lastStatus}' from health_after_cleanup),
  'running',
  'health toont de laatste importworkerstatus'
);
select is(
  (select result #>> '{operations,importWorker,stale}' from health_after_cleanup),
  'true',
  'een te oude succesvolle importworkerheartbeat is stale'
);
select is(
  (select result #>> '{operations,importWorker,runningStale}' from health_after_cleanup),
  'true',
  'een te lang draaiende worker wordt afzonderlijk gemarkeerd'
);

create temporary table second_cleanup(result jsonb);
grant select, insert on second_cleanup to service_role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into second_cleanup(result)
select app.cleanup_expired_security_data_v3(timezone('utc', now()));
reset role;
select is(
  (
    select
      (result->>'importPartialFailures')::integer +
      (result->>'importRunsExpired')::integer +
      (result->>'importSelectedRows')::integer +
      (result->>'importPlansPurged')::integer
    from second_cleanup
  ),
  0,
  'dezelfde cleanup is volledig idempotent'
);
select is(
  (
    select count(*)
    from app.audit_logs
    where action = 'members.import.partial_commit.expired'
      and entity_id = 'fa200000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'een retry maakt geen dubbel incident-auditevent'
);

update app.action_items
set status = 'resolved',
    resolved_at = timezone('utc', now()),
    resolved_by = 'fa000000-0000-4000-8000-000000000001',
    resolution_reason = 'Voorraad en ledenmutaties aantoonbaar gereconcilieerd'
where type = 'import_failure'
  and object_id = 'fa200000-0000-4000-8000-000000000001';
select is(
  app.get_operational_health_v4() #>> '{importRuns,reconciliationRequired}',
  '0',
  'health herstelt zodra het incident aantoonbaar is opgelost'
);

create temporary table aged_cleanup(result jsonb);
grant select, insert on aged_cleanup to service_role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into aged_cleanup(result)
select app.cleanup_expired_security_data_v3(
  timezone('utc', now()) + interval '31 days'
);
reset role;
select is(
  (select (result->>'importPlansPurged')::integer from aged_cleanup),
  1,
  'reconciliatieplannen worden pas na dertig dagen verwijderd'
);
select is(
  (
    select count(*)
    from private.dynamic_import_row_plans
    where run_id = 'fa400000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'het oude gedeeltelijke-commitplan is na de bewaartermijn verwijderd'
);

select * from finish();
rollback;
