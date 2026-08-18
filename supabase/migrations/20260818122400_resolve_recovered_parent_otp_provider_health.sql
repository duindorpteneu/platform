-- Parent OTP delivery history is append-only, but release readiness must
-- represent the provider's current state. A later accepted OTP proves that a
-- preceding HTTP-level provider rejection was not a continuing system-wide
-- outage. Render failures remain unresolved because a provider acceptance
-- cannot prove that the failed render path recovered.

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
      or not exists (
        select 1
        from private.parent_otp_delivery_outcomes recovery
        where recovery.outcome = 'accepted'
          and recovery.created_at > failure.created_at
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
