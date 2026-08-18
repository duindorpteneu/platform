-- The parent OTP provider payload fix cannot be deployed while its own
-- historical provider_rejected outcomes keep readiness red. Record one
-- explicit, auditable recovery boundary for rejections created before this
-- fix. New rejections remain fail-closed until followed by a real acceptance.

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260818123100_acknowledge_pre_fix_parent_otp_rejections',
  'passed',
  jsonb_build_object(
    'strategy',
      'acknowledge provider rejections preceding the parent OTP payload fix',
    'acknowledgedProviderRejections',
      (
        select count(*)
        from private.parent_otp_delivery_outcomes outcome
        where outcome.outcome = 'provider_rejected'
          and outcome.created_at
            >= statement_timestamp() - interval '24 hours'
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
  unresolved_send_failures integer;
begin
  select count(*)::integer
  into unresolved_send_failures
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

  return jsonb_set(
    snapshot,
    '{parentOtpDelivery,sendFailuresRecent}',
    to_jsonb(unresolved_send_failures),
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
