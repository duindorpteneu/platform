-- Portal-access revocation can deliberately terminate an invitation before it
-- reaches a provider. Preserve that immutable queue fact, but classify it in
-- the same way as the newer access-inactive pre-send guard.

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260820141000_classify_revoked_access_mail_as_safe_terminal',
  'passed',
  jsonb_build_object(
    'strategy',
      'classify explicit access revocation before provider send as safe terminal',
    'revokedBeforeSendJobs',
      (
        select count(*)
        from private.email_jobs job
        where job.status = 'failed'
          and job.last_error = 'access_revoked_before_send'
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
      'access_revoked_before_send',
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

create or replace function private.produce_internal_email_failure_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_season_id uuid;
  reason text;
  attempt_scope_id uuid := coalesce(
    new.current_delivery_attempt_id,
    new.id
  );
  action_key text;
  event_key text;
begin
  if not private.mail_templates_v2_cutover_started()
    or new.template_key = 'internal_email_failure'
    or not (
      (
        new.status = 'failed'
        and old.status is distinct from new.status
        and coalesce(new.last_error, '') not in (
          'access_inactive_before_send',
          'access_revoked_before_send',
          'eligibility_changed_before_send',
          'mail_v2_paused',
          'superseded_by_back_in_stock'
        )
      )
      or (
        new.delivery_status in ('bounced', 'dropped', 'failed')
        and (
          old.delivery_status is distinct from new.delivery_status
          or old.delivery_event_occurred_at is distinct from
            new.delivery_event_occurred_at
        )
      )
    )
  then
    return new;
  end if;
  target_season_id := coalesce(
    new.season_id,
    (
      select orders.season_id
      from app.member_orders orders
      where orders.id = new.order_id
    ),
    (
      select batch.season_id
      from private.parent_access_batches batch
      where batch.id = new.parent_access_batch_id
    )
  );
  if target_season_id is null then
    return new;
  end if;
  reason := case
    when new.delivery_status in ('bounced', 'dropped', 'failed')
      then 'provider_' || new.delivery_status
    else coalesce(new.last_error, 'terminal_failure')
  end;
  if reason !~ '^[a-z0-9][a-z0-9._-]{1,63}$' then
    reason := 'terminal_failure';
  end if;
  action_key := encode(
    extensions.digest(
      convert_to(
        'email-failure-v3:' || attempt_scope_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  event_key := encode(
    extensions.digest(
      convert_to(
        concat_ws(
          ':',
          'internal-email-failure-v3',
          attempt_scope_id,
          reason,
          coalesce(
            new.delivery_event_occurred_at::text,
            new.updated_at::text
          )
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  perform private.open_action_item(
    'email_failure',
    target_season_id,
    'email_job',
    new.id,
    'email_delivery_attempt',
    attempt_scope_id,
    action_key,
    'critical',
    'admin_only',
    'email.' || reason,
    jsonb_build_object('jobId', new.id),
    statement_timestamp() + interval '4 hours'
  );
  insert into private.mail_v2_domain_events(
    template_key,
    parent_account_id,
    season_id,
    member_season_id,
    order_id,
    order_line_id,
    source_type,
    source_id,
    cohort_id,
    idempotency_key,
    payload_snapshot
  ) values (
    'internal_email_failure',
    null,
    target_season_id,
    null,
    null,
    null,
    'email_job',
    new.id,
    attempt_scope_id,
    'internal-email-failure-v3:' || event_key,
    jsonb_build_object(
      'jobId', new.id,
      'deliveryAttemptId', attempt_scope_id,
      'reason',
      reason
    )
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

revoke all on function private.produce_internal_email_failure_v2()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
