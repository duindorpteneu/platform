-- Runtime configuration and immutable delivery incidents are separate health
-- axes. A historical `configuration_error` or `disabled` OTP attempt remains
-- in the append-only ledger, while current runtime/database/provider binding
-- is already verified by the application health route. Only provider rejection
-- and render failures remain recent unresolved send blockers here.

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
  from private.parent_otp_delivery_outcomes outcome
  where outcome.outcome in ('provider_rejected', 'render_failed')
    and outcome.created_at
      >= statement_timestamp() - interval '24 hours';

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
