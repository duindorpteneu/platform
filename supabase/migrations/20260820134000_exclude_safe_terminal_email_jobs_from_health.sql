-- A failed queue status can also be the deliberate terminal result of a
-- pre-send eligibility check. Those jobs were never offered to a provider and
-- already do not produce an internal e-mail failure action item. Keep their
-- immutable history, but align release health with that existing distinction.

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260820134000_exclude_safe_terminal_email_jobs_from_health',
  'passed',
  jsonb_build_object(
    'strategy',
      'exclude deliberate pre-send terminal outcomes from operational failures',
    'safeTerminalJobs',
      (
        select count(*)
        from private.email_jobs job
        where job.status = 'failed'
          and job.last_error in (
            'access_inactive_before_send',
            'eligibility_changed_before_send',
            'mail_v2_paused',
            'superseded_by_back_in_stock'
          )
      )
  )
);

create or replace function app.get_operational_health_v13(
  p_current_pepper_fingerprint text,
  p_current_key_version integer,
  p_previous_pepper_fingerprint text default null,
  p_previous_key_version integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  snapshot jsonb := app.get_operational_health_v12(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
  rejection_recovery_boundary timestamptz := coalesce(
    (
      select reconciliation.reconciled_at
      from private.migration_reconciliations reconciliation
      where reconciliation.migration_key =
        '20260818123100_acknowledge_pre_fix_parent_otp_rejections'
        and reconciliation.status = 'passed'
    ),
    '-infinity'::timestamptz
  );
  email_recovery_boundary timestamptz := coalesce(
    (
      select reconciliation.reconciled_at
      from private.migration_reconciliations reconciliation
      where reconciliation.migration_key =
        '20260818133600_acknowledge_recovered_email_scheduler_health'
        and reconciliation.status = 'passed'
    ),
    '-infinity'::timestamptz
  );
  unresolved_otp_send_failures integer;
  unresolved_failed_jobs integer;
  unresolved_uncertain_jobs integer;
  unresolved_provider_failures integer;
  unrecovered_stale_email_run boolean;
begin
  select count(*)::integer
  into unresolved_otp_send_failures
  from private.parent_otp_delivery_outcomes failure
  where failure.outcome in ('provider_rejected', 'render_failed')
    and failure.created_at
      >= statement_timestamp() - interval '24 hours'
    and (
      failure.outcome = 'render_failed'
      or (
        failure.created_at > rejection_recovery_boundary
        and not exists (
          select 1
          from private.parent_otp_delivery_outcomes recovery
          where recovery.outcome = 'accepted'
            and recovery.created_at > failure.created_at
        )
      )
    );

  select count(*)::integer
  into unresolved_failed_jobs
  from private.email_jobs job
  where job.status = 'failed'
    and job.updated_at > email_recovery_boundary
    and coalesce(job.last_error, '') not in (
      'access_inactive_before_send',
      'eligibility_changed_before_send',
      'mail_v2_paused',
      'superseded_by_back_in_stock'
    );

  select count(*)::integer
  into unresolved_uncertain_jobs
  from private.email_jobs job
  where job.status = 'delivery_uncertain'
    and job.updated_at > email_recovery_boundary;

  select count(*)::integer
  into unresolved_provider_failures
  from app.email_events event
  where event.event_type in ('bounced', 'dropped', 'failed')
    and event.occurred_at
      >= statement_timestamp() - interval '24 hours'
    and event.recorded_at > email_recovery_boundary;

  select exists (
    select 1
    from private.operation_runs stale_run
    where stale_run.operation = 'email_worker'
      and stale_run.status = 'running'
      and stale_run.started_at
        < statement_timestamp() - interval '2 minutes'
      and not exists (
        select 1
        from private.operation_runs recovery_run
        where recovery_run.operation = stale_run.operation
          and recovery_run.status = 'succeeded'
          and recovery_run.finished_at > stale_run.started_at
      )
  ) into unrecovered_stale_email_run;

  snapshot := jsonb_set(
    snapshot,
    '{parentOtpDelivery,sendFailuresRecent}',
    to_jsonb(unresolved_otp_send_failures),
    false
  );
  snapshot := jsonb_set(
    snapshot,
    '{emailJobs,failed}',
    to_jsonb(unresolved_failed_jobs),
    false
  );
  snapshot := jsonb_set(
    snapshot,
    '{emailJobs,deliveryUncertain}',
    to_jsonb(unresolved_uncertain_jobs),
    false
  );
  snapshot := jsonb_set(
    snapshot,
    '{recentDeliveryFailures}',
    to_jsonb(unresolved_provider_failures),
    false
  );
  return jsonb_set(
    snapshot,
    '{operations,emailWorker,runningStale}',
    to_jsonb(unrecovered_stale_email_run),
    false
  );
end;
$$;

revoke all on function app.get_operational_health_v13(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v13(
  text, integer, text, integer
) to service_role;

notify pgrst, 'reload schema';
