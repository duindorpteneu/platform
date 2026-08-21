-- v14 separated recipient failures from systemic health, but accidentally
-- replaced the v13 failed-job count without retaining its safe-terminal and
-- exact historical acknowledgement exclusions. Preserve those established
-- contracts while keeping every new or changed systemic failure fail-closed.

do $$
declare
  unresolved_count integer;
  expected_staging_count integer;
begin
  with candidates as (
    select job.*
    from private.email_jobs job
    where job.status = 'failed'
      and job.updated_at > coalesce(
        (
          select reconciliation.reconciled_at
          from private.migration_reconciliations reconciliation
          where reconciliation.migration_key =
            '20260818133600_acknowledge_recovered_email_scheduler_health'
            and reconciliation.status = 'passed'
        ),
        '-infinity'::timestamptz
      )
      and coalesce(job.last_error, '') not in (
        'access_inactive_before_send',
        'access_revoked_before_send',
        'eligibility_changed_before_send',
        'mail_v2_paused',
        'superseded_by_back_in_stock'
      )
      and not exists (
        select 1
        from private.migration_reconciliations reconciliation
        cross join lateral jsonb_array_elements(
          coalesce(
            reconciliation.metrics->'acknowledgedFailedJobs',
            '[]'::jsonb
          )
        ) acknowledged
        where reconciliation.migration_key =
          '20260820152000_acknowledge_preexisting_email_failure'
          and reconciliation.status = 'passed'
          and (acknowledged->>'jobId')::uuid = job.id
          and job.updated_at <=
            (acknowledged->>'updatedAt')::timestamptz
      )
      and not exists (
        select 1
        from private.email_provider_sync_evidence evidence
        where evidence.delivery_attempt_id = job.current_delivery_attempt_id
          and evidence.recipient_failure
      )
  )
  select
    count(*)::integer,
    count(*) filter (
      where candidate.kind = 'bulk'
        and candidate.template_key = 'portal_access_reminder'
        and candidate.context_kind = 'mail_v2'
        and candidate.last_error = 'provider_rejected'
        and candidate.attempts = 5
        and candidate.provider_message_id is null
        and candidate.current_delivery_attempt_id is not null
        and not exists (
          select 1
          from app.email_events event
          where event.email_job_id = candidate.id
        )
    )::integer
  into unresolved_count, expected_staging_count
  from candidates candidate;

  if unresolved_count > 1
    or (unresolved_count = 1 and expected_staging_count <> 1)
  then
    raise exception 'PRE_RELEASE_EMAIL_FAILURE_SET_REQUIRES_REVIEW'
      using errcode = '23514';
  end if;
end;
$$;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
)
select
  '20260821170721_preserve_email_health_v13_exclusions',
  'passed',
  jsonb_build_object(
    'strategy',
      'preserve v13 exclusions and exact pre-release failure evidence',
    'acknowledgedFailedJobCount', count(*)::integer,
    'acknowledgedFailedJobs', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'jobId', candidate.id,
          'updatedAt', candidate.updated_at
        )
        order by candidate.id
      ),
      '[]'::jsonb
    )
  )
from (
  select job.id, job.updated_at
  from private.email_jobs job
  where job.status = 'failed'
    and job.updated_at > coalesce(
      (
        select reconciliation.reconciled_at
        from private.migration_reconciliations reconciliation
        where reconciliation.migration_key =
          '20260818133600_acknowledge_recovered_email_scheduler_health'
          and reconciliation.status = 'passed'
      ),
      '-infinity'::timestamptz
    )
    and job.kind = 'bulk'
    and job.template_key = 'portal_access_reminder'
    and job.context_kind = 'mail_v2'
    and job.last_error = 'provider_rejected'
    and job.attempts = 5
    and job.provider_message_id is null
    and job.current_delivery_attempt_id is not null
    and not exists (
      select 1
      from app.email_events event
      where event.email_job_id = job.id
    )
    and not exists (
      select 1
      from private.migration_reconciliations reconciliation
      cross join lateral jsonb_array_elements(
        coalesce(
          reconciliation.metrics->'acknowledgedFailedJobs',
          '[]'::jsonb
        )
      ) acknowledged
      where reconciliation.migration_key =
        '20260820152000_acknowledge_preexisting_email_failure'
        and reconciliation.status = 'passed'
        and (acknowledged->>'jobId')::uuid = job.id
        and job.updated_at <= (acknowledged->>'updatedAt')::timestamptz
    )
    and not exists (
      select 1
      from private.email_provider_sync_evidence evidence
      where evidence.delivery_attempt_id = job.current_delivery_attempt_id
        and evidence.recipient_failure
    )
) candidate
on conflict (migration_key) do update
set status = excluded.status,
    metrics = excluded.metrics,
    reconciled_at = statement_timestamp();

create or replace function app.get_operational_health_v14(
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
  snapshot jsonb := app.get_operational_health_v13(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
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
  systemic_failed integer;
  systemic_otp_failed integer;
  systemic_email_provider_failures integer;
  systemic_otp_provider_failures integer;
begin
  select count(*)::integer into systemic_failed
  from private.email_jobs job
  where job.status = 'failed'
    and job.updated_at > email_recovery_boundary
    and coalesce(job.last_error, '') not in (
      'access_inactive_before_send',
      'access_revoked_before_send',
      'eligibility_changed_before_send',
      'mail_v2_paused',
      'superseded_by_back_in_stock'
    )
    and not exists (
      select 1
      from private.migration_reconciliations reconciliation
      cross join lateral jsonb_array_elements(
        coalesce(
          reconciliation.metrics->'acknowledgedFailedJobs',
          '[]'::jsonb
        )
      ) acknowledged
      where reconciliation.migration_key in (
          '20260820152000_acknowledge_preexisting_email_failure',
          '20260821170721_preserve_email_health_v13_exclusions'
        )
        and reconciliation.status = 'passed'
        and (acknowledged->>'jobId')::uuid = job.id
        and job.updated_at <= (acknowledged->>'updatedAt')::timestamptz
    )
    and not exists (
      select 1
      from private.email_provider_sync_evidence evidence
      where evidence.delivery_attempt_id = job.current_delivery_attempt_id
        and evidence.recipient_failure
    );

  select count(*)::integer into systemic_otp_failed
  from private.parent_otp_delivery_outcomes failure
  where failure.outcome in ('provider_rejected', 'render_failed')
    and failure.created_at >= statement_timestamp() - interval '24 hours'
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
    )
    and not exists (
      select 1
      from private.email_provider_sync_evidence evidence
      where evidence.parent_otp_delivery_attempt_id = failure.delivery_attempt_id
        and evidence.recipient_failure
    );

  select count(*)::integer into systemic_email_provider_failures
  from app.email_events event
  join private.email_jobs job on job.id = event.email_job_id
  where event.event_type in ('bounced', 'dropped', 'failed')
    and event.occurred_at >= statement_timestamp() - interval '24 hours'
    and event.recorded_at > email_recovery_boundary
    and not (
      event.event_type = 'bounced'
      and exists (
        select 1
        from private.email_recipient_identities identity_row
        join private.email_recipient_suppressions suppression
          on suppression.recipient_identity_id = identity_row.id
          and suppression.lifted_at is null
        where identity_row.email_normalized = lower(btrim(job.recipient_email))
      )
    );

  select count(*)::integer into systemic_otp_provider_failures
  from (
    select distinct on (event.delivery_attempt_id)
      event.delivery_attempt_id,
      event.event_type,
      event.occurred_at
    from private.parent_otp_provider_events event
    order by event.delivery_attempt_id, event.occurred_at desc, event.id desc
  ) latest
  join private.parent_otp_delivery_attempts attempt
    on attempt.id = latest.delivery_attempt_id
  where latest.event_type in ('bounced', 'dropped', 'failed')
    and latest.occurred_at >= statement_timestamp() - interval '24 hours'
    and not (
      latest.event_type = 'bounced'
      and exists (
        select 1
        from private.email_recipient_suppressions suppression
        where suppression.recipient_identity_id = attempt.recipient_identity_id
          and suppression.lifted_at is null
      )
    );

  snapshot := jsonb_set(snapshot, '{emailJobs,failed}',
    to_jsonb(systemic_failed), false);
  snapshot := jsonb_set(snapshot, '{parentOtpDelivery,sendFailuresRecent}',
    to_jsonb(systemic_otp_failed), false);
  snapshot := jsonb_set(snapshot,
    '{parentOtpDelivery,providerFailuresRecent}',
    to_jsonb(systemic_otp_provider_failures), false);
  snapshot := jsonb_set(snapshot, '{recentDeliveryFailures}',
    to_jsonb(systemic_email_provider_failures), false);
  return snapshot;
end;
$$;

revoke all on function app.get_operational_health_v14(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v14(
  text, integer, text, integer
) to service_role;

select pg_notify('pgrst', 'reload schema');
