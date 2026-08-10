-- Scheduler, retention and health integration for persistent import runs.

alter table private.operation_runs
  drop constraint operation_runs_operation_check;
alter table private.operation_runs
  add constraint operation_runs_operation_check check (
    operation in ('email_worker', 'retention', 'import_worker')
  );

create or replace function app.start_operation_run(p_operation text, p_run_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare started timestamptz := timezone('utc', now());
begin
  if p_run_id is null
    or p_operation not in ('email_worker', 'retention', 'import_worker')
  then
    raise exception 'INVALID_OPERATION_RUN' using errcode = '22023';
  end if;

  insert into private.operation_runs(id, operation, status, started_at)
  values(p_run_id, p_operation, 'running', started);

  return jsonb_build_object(
    'runId', p_run_id,
    'operation', p_operation,
    'startedAt', started
  );
exception when unique_violation then
  raise exception 'OPERATION_RUN_CONFLICT' using errcode = '23505';
end;
$$;

create or replace function app.cleanup_expired_security_data_v3(p_now timestamptz)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  previous_result jsonb;
  selected_count integer;
  expired_run_count integer;
  partial_failure_count integer := 0;
  plan_count integer;
  partial_run record;
  failure_dedupe_key text;
begin
  if p_now is null then
    raise exception 'INVALID_RETENTION_TIMESTAMP' using errcode = '22023';
  end if;

  previous_result := app.cleanup_expired_security_data_v2(p_now);

  for partial_run in
    select
      run.id,
      run.batch_id,
      run.season_id,
      run.created_by
    from app.dynamic_import_runs run
    where run.expires_at <= p_now
      and run.status = 'committing'
      and exists(
        select 1
        from private.dynamic_import_row_plans plan
        where plan.run_id = run.id
          and plan.committed_at is not null
      )
    order by run.id
    for update
  loop
    update app.dynamic_import_runs
    set status = 'failed',
        failure_code = 'partial_commit_expired',
        failed_at = p_now
    where id = partial_run.id;
    update app.import_batches
    set dynamic_status = 'failed',
        status = 'failed',
        failure_code = 'partial_commit_expired'
    where id = partial_run.batch_id;
    delete from private.dynamic_import_run_leases
    where run_id = partial_run.id;

    failure_dedupe_key := encode(
      extensions.digest(
        convert_to('import-failure:' || partial_run.id::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    );
    perform private.open_action_item(
      'import_failure',
      partial_run.season_id,
      'import_batch',
      partial_run.batch_id,
      'import_run',
      partial_run.id,
      failure_dedupe_key,
      'critical',
      'admin_only',
      'partial_commit_expired',
      jsonb_build_object(
        'runId', partial_run.id,
        'batchId', partial_run.batch_id,
        'blocked', true
      ),
      p_now + interval '1 hour'
    );
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata
    )
    values(
      null,
      'members.import.partial_commit.expired',
      'import_batch',
      partial_run.batch_id,
      jsonb_build_object(
        'runId', partial_run.id,
        'failureCode', 'partial_commit_expired'
      )
    );
    partial_failure_count := partial_failure_count + 1;
  end loop;

  with expired_runs as (
    update app.dynamic_import_runs run
    set status = 'expired',
        failure_code = 'selected_retention_expired',
        failed_at = p_now
    where run.expires_at <= p_now
      and run.status not in ('committed', 'failed', 'expired')
    returning run.id, run.batch_id
  ),
  expired_batches as (
    update app.import_batches batch
    set dynamic_status = 'expired',
        status = 'failed',
        failure_code = 'selected_retention_expired'
    where batch.id in (select expired_runs.batch_id from expired_runs)
      and batch.dynamic_status <> 'committed'
    returning 1
  )
  select count(*)::integer
  into expired_run_count
  from expired_runs;

  delete from private.dynamic_import_run_leases lease
  where lease.expires_at <= p_now
    or exists(
      select 1
      from app.dynamic_import_runs run
      where run.id = lease.run_id
        and run.status in ('committed', 'failed', 'expired')
    );

  with removed as (
    delete from private.dynamic_import_selected_rows selected
    where selected.expires_at <= p_now
    returning 1
  )
  select count(*)::integer into selected_count from removed;

  with removed as (
    delete from private.dynamic_import_row_plans plan
    where exists(
      select 1
      from app.dynamic_import_runs run
      where run.id = plan.run_id
        and (
          run.status = 'expired'
          or (
            run.status = 'failed'
            and run.failed_at <= p_now - interval '30 days'
          )
        )
    )
    returning 1
  )
  select count(*)::integer into plan_count from removed;

  return previous_result || jsonb_build_object(
    'importSelectedRows', selected_count,
    'importRunsExpired', expired_run_count,
    'importPartialFailures', partial_failure_count,
    'importPlansPurged', plan_count
  );
end;
$$;

create or replace function app.get_operational_health_v4()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  base jsonb := app.get_operational_health_v3();
  now_utc timestamptz := timezone('utc', now());
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
      ),
      'reconciliationRequired', (
        select count(*)
        from app.action_items item
        where item.type = 'import_failure'
          and item.severity = 'critical'
          and item.status in ('open', 'in_progress')
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

revoke all on function app.cleanup_expired_security_data_v3(timestamptz)
from public, anon, authenticated;
grant execute on function app.cleanup_expired_security_data_v3(timestamptz)
to service_role;

revoke all on function app.get_operational_health_v4()
from public, anon, authenticated;
grant execute on function app.get_operational_health_v4()
to service_role;

notify pgrst, 'reload schema';
