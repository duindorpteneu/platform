-- Staff password recovery gets an app-owned, neutral request path. Completing
-- recovery revokes every opaque app session and outstanding scan grant for the
-- authenticated staff identity before a fresh password + MFA login is allowed.

alter table private.rate_limit_events
  drop constraint rate_limit_events_scope_check;
alter table private.rate_limit_events
  add constraint rate_limit_events_scope_check check (
    scope in (
      'otp_request',
      'otp_verify',
      'mollie_create',
      'export',
      'search',
      'supplier_login',
      'staff_recovery'
    )
  );

create or replace function app.consume_rate_limit(
  p_scope text,
  p_key_hash text,
  p_limit integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  now_utc timestamptz := timezone('utc', now());
begin
  if p_scope is null
    or p_scope <> all(array[
      'otp_request',
      'otp_verify',
      'mollie_create',
      'export',
      'search',
      'supplier_login',
      'staff_recovery'
    ])
  then
    raise exception 'INVALID_RATE_LIMIT_SCOPE' using errcode = '22023';
  end if;
  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_RATE_LIMIT_KEY' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 1000
    or p_window_seconds is null or p_window_seconds not between 1 and 86400
  then
    raise exception 'INVALID_RATE_LIMIT_BOUNDS' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_scope || ':' || p_key_hash, 0)
  );
  if (
    select count(*)
    from private.rate_limit_events event
    where event.scope = p_scope
      and event.key_hash = p_key_hash
      and event.occurred_at
        > now_utc - make_interval(secs => p_window_seconds)
  ) >= p_limit then
    return false;
  end if;
  insert into private.rate_limit_events(scope, key_hash, occurred_at)
  values(p_scope, p_key_hash, now_utc);
  return true;
end;
$$;

revoke all on function app.consume_rate_limit(
  text, text, integer, integer
) from public, anon, authenticated;
grant execute on function app.consume_rate_limit(
  text, text, integer, integer
) to service_role;

create or replace function app.revoke_all_staff_app_sessions_for_user(
  p_auth_user_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  now_utc timestamptz := timezone('utc', now());
  sessions_revoked integer := 0;
  exchanges_consumed integer := 0;
  scan_grants_revoked integer := 0;
begin
  if p_auth_user_id is null
    or not exists (
      select 1
      from app.staff_profiles profile
      where profile.auth_user_id = p_auth_user_id
    )
  then
    return null;
  end if;

  perform set_config('app.qr_internal', 'on', true);
  update private.qr_scan_grants grant_row
  set revoked_at = now_utc,
      revocation_reason = 'Wachtwoord van medewerker is hersteld'
  where grant_row.staff_session_hash in (
      select session.token_hash
      from private.staff_sessions session
      where session.auth_user_id = p_auth_user_id
    )
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null;
  get diagnostics scan_grants_revoked = row_count;
  perform set_config('app.qr_internal', 'off', true);

  update private.staff_sessions session
  set revoked_at = now_utc
  where session.auth_user_id = p_auth_user_id
    and session.revoked_at is null;
  get diagnostics sessions_revoked = row_count;

  update private.staff_session_exchanges exchange
  set consumed_at = now_utc
  where exchange.auth_user_id = p_auth_user_id
    and exchange.consumed_at is null;
  get diagnostics exchanges_consumed = row_count;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    p_auth_user_id,
    'staff.password.recovery.completed',
    'staff_profile',
    (select profile.id from app.staff_profiles profile where profile.auth_user_id = p_auth_user_id),
    jsonb_build_object(
      'sessionsRevoked', sessions_revoked,
      'exchangesConsumed', exchanges_consumed,
      'scanGrantsRevoked', scan_grants_revoked
    )
  );

  return jsonb_build_object(
    'sessionsRevoked', sessions_revoked,
    'exchangesConsumed', exchanges_consumed,
    'scanGrantsRevoked', scan_grants_revoked
  );
end;
$$;

revoke all on function app.revoke_all_staff_app_sessions_for_user(uuid)
from public, anon, authenticated;
grant execute on function app.revoke_all_staff_app_sessions_for_user(uuid)
to service_role;

comment on function app.revoke_all_staff_app_sessions_for_user(uuid)
is 'Service-only completion of staff password recovery; revokes opaque sessions, pending exchanges and scan grants and appends a PII-free audit event.';
