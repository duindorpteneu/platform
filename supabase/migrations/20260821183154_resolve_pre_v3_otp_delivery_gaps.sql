-- Parent OTP delivery callbacks before the v3 runtime could terminate after
-- preparing the immutable attempt without appending an outcome. Preserve the
-- exact cutover evidence, append the only honest terminal fact only after an
-- attempt has expired, and keep every active or post-migration gap fail-closed.

begin;

-- These locks make the cutover snapshot exact. Runtime inserts take a
-- row-exclusive lock and therefore wait until the reconciliation commits.
lock table private.parent_otp_delivery_attempts in share row exclusive mode;
lock table private.parent_otp_delivery_outcomes in share row exclusive mode;

insert into private.parent_otp_delivery_outcomes(
  delivery_attempt_id,
  outcome,
  error_code
)
select
  attempt.id,
  'delivery_uncertain',
  'pre_v3_uncompleted_attempt'
from private.parent_otp_delivery_attempts attempt
where attempt.expires_at <= transaction_timestamp()
  and not exists (
    select 1
    from private.parent_otp_delivery_outcomes outcome
    where outcome.delivery_attempt_id = attempt.id
  );

insert into app.audit_logs(
  actor_user_id,
  action,
  entity_type,
  entity_id,
  metadata
)
select
  null,
  'parent.otp.delivery.reconciled.uncertain',
  'parent_account',
  attempt.parent_account_id,
  jsonb_build_object(
    'deliveryAttemptId', attempt.id,
    'attemptCreatedAt', attempt.created_at,
    'attemptExpiresAt', attempt.expires_at,
    'outcomeId', outcome.id,
    'outcomeCreatedAt', outcome.created_at
  )
from private.parent_otp_delivery_attempts attempt
join private.parent_otp_delivery_outcomes outcome
  on outcome.delivery_attempt_id = attempt.id
where outcome.outcome = 'delivery_uncertain'
  and outcome.error_code = 'pre_v3_uncompleted_attempt';

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
)
select
  '20260821183154_resolve_pre_v3_otp_delivery_gaps',
  'passed',
  jsonb_build_object(
    'strategy',
      'append uncertain outcomes for exact expired pre-v3 delivery gaps',
    'reconciledAttemptCount', (
      select count(*)::integer
      from private.parent_otp_delivery_outcomes outcome
      where outcome.outcome = 'delivery_uncertain'
        and outcome.error_code = 'pre_v3_uncompleted_attempt'
    ),
    'auditEntryCount', (
      select count(*)::integer
      from app.audit_logs audit
      where audit.action = 'parent.otp.delivery.reconciled.uncertain'
    ),
    'reconciledAttempts', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'attemptId', attempt.id,
          'attemptCreatedAt', attempt.created_at,
          'attemptExpiresAt', attempt.expires_at,
          'outcomeId', outcome.id,
          'outcomeCreatedAt', outcome.created_at
        ) order by attempt.created_at, attempt.id
      )
      from private.parent_otp_delivery_attempts attempt
      join private.parent_otp_delivery_outcomes outcome
        on outcome.delivery_attempt_id = attempt.id
      where outcome.outcome = 'delivery_uncertain'
        and outcome.error_code = 'pre_v3_uncompleted_attempt'
    ), '[]'::jsonb)
  )
on conflict (migration_key) do update
set status = excluded.status,
    metrics = excluded.metrics,
    reconciled_at = transaction_timestamp();

-- Preserve the previous implementation under a private RPC name so the new
-- v14 remains rollback-compatible for the prior app revision.
alter function app.get_operational_health_v14(text, integer, text, integer)
  rename to get_operational_health_v14_before_otp_gap_recovery;

revoke all on function app.get_operational_health_v14_before_otp_gap_recovery(
  text, integer, text, integer
) from public, anon, authenticated, service_role;

create function app.get_operational_health_v14(
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
  snapshot jsonb := app.get_operational_health_v14_before_otp_gap_recovery(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
  systemic_delivery_uncertain integer;
begin
  select count(*)::integer into systemic_delivery_uncertain
  from private.parent_otp_delivery_outcomes outcome
  join private.parent_otp_delivery_attempts attempt
    on attempt.id = outcome.delivery_attempt_id
  where outcome.outcome = 'delivery_uncertain'
    and outcome.created_at >= statement_timestamp() - interval '24 hours'
    and not exists (
      select 1
      from private.migration_reconciliations reconciliation
      cross join lateral jsonb_array_elements(
        coalesce(
          reconciliation.metrics->'reconciledAttempts',
          '[]'::jsonb
        )
      ) reconciled
      where reconciliation.migration_key =
        '20260821183154_resolve_pre_v3_otp_delivery_gaps'
        and reconciliation.status = 'passed'
        and (reconciled->>'attemptId')::uuid = attempt.id
        and (reconciled->>'attemptCreatedAt')::timestamptz =
          attempt.created_at
        and (reconciled->>'attemptExpiresAt')::timestamptz =
          attempt.expires_at
        and (reconciled->>'outcomeId')::bigint = outcome.id
        and (reconciled->>'outcomeCreatedAt')::timestamptz =
          outcome.created_at
        and outcome.error_code = 'pre_v3_uncompleted_attempt'
    );

  snapshot := jsonb_set(
    snapshot,
    '{parentOtpDelivery,deliveryUncertainRecent}',
    to_jsonb(systemic_delivery_uncertain),
    false
  );
  return snapshot;
end;
$$;

revoke all on function app.get_operational_health_v14(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v14(
  text, integer, text, integer
) to service_role;

create function app.get_operational_health_v15(
  p_current_pepper_fingerprint text,
  p_current_key_version integer,
  p_previous_pepper_fingerprint text default null,
  p_previous_key_version integer default null
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select app.get_operational_health_v14(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  )
$$;

revoke all on function app.get_operational_health_v15(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v15(
  text, integer, text, integer
) to service_role;

select pg_notify('pgrst', 'reload schema');

commit;
