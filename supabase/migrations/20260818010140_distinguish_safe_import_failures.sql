-- Keep a safely rejected import separate from an operational or reconciliation
-- incident. A run only requires release-blocking reconciliation when at least
-- one row was actually committed before the failure.

create or replace function app.fail_dynamic_import_run(
  p_run_id uuid,
  p_claim_token uuid,
  p_generation integer,
  p_failure_code text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target app.dynamic_import_runs%rowtype;
  lease private.dynamic_import_run_leases%rowtype;
  failed timestamptz := clock_timestamp();
  failure_dedupe_key text;
  has_applied_rows boolean;
  failure_severity app.action_item_severity;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;
  if p_run_id is null
    or p_claim_token is null
    or p_generation is null
    or p_generation < 1
    or p_failure_code is null
    or p_failure_code !~ '^[a-z0-9][a-z0-9._-]{0,63}$'
  then
    raise exception 'DYNAMIC_IMPORT_FAILURE_INVALID' using errcode = '22023';
  end if;

  select * into target
  from app.dynamic_import_runs run
  where run.id = p_run_id
  for update;
  select * into lease
  from private.dynamic_import_run_leases run_lease
  where run_lease.run_id = p_run_id
  for update;
  if target.id is null
    or lease.run_id is null
    or lease.claim_token <> p_claim_token
    or lease.generation <> p_generation
    or lease.expires_at <= failed
    or target.expires_at <= failed
    or target.status not in ('staging', 'committing')
  then
    raise exception 'DYNAMIC_IMPORT_LEASE_CONFLICT' using errcode = '40001';
  end if;

  select exists(
    select 1
    from private.dynamic_import_row_plans plan
    where plan.run_id = target.id
      and plan.committed_at is not null
  ) into has_applied_rows;
  failure_severity := case
    when has_applied_rows then 'critical'::app.action_item_severity
    else 'warning'::app.action_item_severity
  end;

  update app.dynamic_import_runs
  set status = 'failed',
      failure_code = p_failure_code,
      failed_at = failed
  where id = target.id;
  update app.import_batches
  set dynamic_status = 'failed',
      status = 'failed',
      failure_code = p_failure_code
  where id = target.batch_id;
  delete from private.dynamic_import_run_leases where run_id = target.id;

  failure_dedupe_key := encode(
    extensions.digest(
      convert_to('import-failure:' || target.id::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  perform private.open_action_item(
    'import_failure',
    target.season_id,
    'import_batch',
    target.batch_id,
    'import_run',
    target.id,
    failure_dedupe_key,
    failure_severity,
    'admin_only',
    p_failure_code,
    jsonb_build_object(
      'runId', target.id,
      'batchId', target.batch_id,
      'blocked', true
    ),
    failed + interval '1 hour'
  );

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    target.created_by,
    'members.import.processing.failed',
    'import_batch',
    target.batch_id,
    jsonb_build_object(
      'runId', target.id,
      'failureCode', p_failure_code,
      'reconciliationRequired', has_applied_rows
    )
  );
  return jsonb_build_object(
    'runId', target.id,
    'status', 'failed',
    'failureCode', p_failure_code,
    'reconciliationRequired', has_applied_rows
  );
end;
$$;

revoke all on function app.fail_dynamic_import_run(uuid, uuid, integer, text)
from public, anon, authenticated;
grant execute on function app.fail_dynamic_import_run(uuid, uuid, integer, text)
to service_role;

create or replace function app.get_operational_health_v4()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  base jsonb := app.get_operational_health_v3();
  now_utc timestamptz := statement_timestamp();
  import_required boolean := private.dynamic_import_enabled();
  import_latest private.operation_runs%rowtype;
  import_last_success timestamptz;
  import_operation jsonb;
begin
  select * into import_latest
  from private.operation_runs
  where operation = 'import_worker'
  order by started_at desc
  limit 1;

  select max(finished_at) into import_last_success
  from private.operation_runs
  where operation = 'import_worker'
    and status = 'succeeded';

  import_operation := jsonb_build_object(
    'required', import_required,
    'lastStatus', import_latest.status,
    'lastStartedAt', import_latest.started_at,
    'lastSucceededAt', import_last_success,
    'stale',
      import_required
      and (
        import_last_success is null
        or import_last_success < now_utc - interval '2 minutes'
      ),
    'runningStale', exists(
      select 1
      from private.operation_runs operation_run
      where operation_run.operation = 'import_worker'
        and operation_run.status = 'running'
        and operation_run.started_at < now_utc - interval '2 minutes'
        and (
          import_last_success is null
          or operation_run.started_at > import_last_success
        )
    )
  );

  return jsonb_set(
    base,
    '{operations}',
    (base->'operations') || jsonb_build_object('importWorker', import_operation)
  ) || jsonb_build_object(
    'importControl',
    jsonb_build_object(
      'processingEnabled', import_required,
      'cutoverActive', exists(
        select 1
        from private.release_cutovers cutover
        where cutover.key = 'dynamic_import_v2'
      )
    ),
    'importRuns',
    jsonb_build_object(
      'queued', (
        select count(*)
        from app.dynamic_import_runs run
        where run.status in ('queued_preview', 'commit_queued')
      ),
      'processing', (
        select count(*)
        from app.dynamic_import_runs run
        where run.status in ('staging', 'committing')
      ),
      'processingStale', (
        select count(*)
        from app.dynamic_import_runs run
        left join private.dynamic_import_run_leases lease on lease.run_id = run.id
        where run.status in ('staging', 'committing')
          and (lease.run_id is null or lease.expires_at <= now_utc)
      ),
      'failed', (
        select count(*)
        from app.dynamic_import_runs run
        where run.status = 'failed'
          and run.failed_at >= now_utc - interval '24 hours'
          and exists(
            select 1
            from private.dynamic_import_row_plans plan
            where plan.run_id = run.id
              and plan.committed_at is not null
          )
      ),
      'reconciliationRequired', (
        select count(*)
        from app.action_items item
        join app.dynamic_import_runs run
          on item.source_type = 'import_run'
          and item.source_id = run.id
        where item.type = 'import_failure'
          and item.severity = 'critical'
          and item.status in ('open', 'in_progress')
          and exists(
            select 1
            from private.dynamic_import_row_plans plan
            where plan.run_id = run.id
              and plan.committed_at is not null
          )
      ),
      'expiredSelectedRows', (
        select count(*)
        from private.dynamic_import_selected_rows selected
        where selected.expires_at <= now_utc
      ),
      'backlogStale', exists(
        select 1
        from app.dynamic_import_runs run
        where run.status in (
          'queued_preview',
          'staging',
          'commit_queued',
          'committing'
        )
          and (
            case
              when run.status in ('commit_queued', 'committing')
                then coalesce(run.commit_requested_at, run.created_at)
              else run.created_at
            end
          ) < now_utc - interval '30 minutes'
      ),
      'oldestPendingAt', (
        select min(
          case
            when run.status in ('commit_queued', 'committing')
              then coalesce(run.commit_requested_at, run.created_at)
            else run.created_at
          end
        )
        from app.dynamic_import_runs run
        where run.status in (
          'queued_preview',
          'staging',
          'commit_queued',
          'committing'
        )
      )
    )
  );
end;
$$;

revoke all on function app.get_operational_health_v4()
from public, anon, authenticated;
grant execute on function app.get_operational_health_v4()
to service_role;

-- Reclassify only still-open, zero-write failures created before this fix.
-- The immutable failed run and original audit record remain unchanged.
with reclassified as (
  update app.action_items item
  set severity = 'warning'::app.action_item_severity
  where item.type = 'import_failure'
    and item.severity = 'critical'
    and item.status in ('open', 'in_progress')
    and item.source_type = 'import_run'
    and item.source_id is not null
    and exists(
      select 1
      from app.dynamic_import_runs run
      where run.id = item.source_id
        and run.status = 'failed'
    )
    and not exists(
      select 1
      from private.dynamic_import_row_plans plan
      where plan.run_id = item.source_id
        and plan.committed_at is not null
    )
  returning item.id, item.source_id
)
insert into app.audit_logs(
  actor_user_id,
  action,
  entity_type,
  entity_id,
  metadata
)
select
  null,
  'action_item.import_failure.reclassified',
  'action_item',
  reclassified.id,
  jsonb_build_object(
    'runId', reclassified.source_id,
    'severity', 'warning',
    'reconciliationRequired', false
  )
from reclassified;

notify pgrst, 'reload schema';
