create table private.staff_session_exchanges (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  auth_user_id uuid not null references app.staff_profiles(auth_user_id) on delete cascade,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create table private.staff_sessions (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  auth_user_id uuid not null references app.staff_profiles(auth_user_id) on delete cascade,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create index staff_session_exchanges_retention_idx
  on private.staff_session_exchanges(coalesce(consumed_at, expires_at));
create index staff_sessions_retention_idx
  on private.staff_sessions(coalesce(revoked_at, expires_at));

create or replace function app.create_staff_session_exchange()
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := auth.uid();
  exchange_token text;
begin
  if actor is null or coalesce(auth.jwt()->>'aal', '') <> 'aal2' or not exists (
    select 1 from app.staff_profiles profile
    where profile.auth_user_id = actor and profile.active = true
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  delete from private.staff_session_exchanges exchange
  where exchange.auth_user_id = actor
    and (exchange.consumed_at is not null or exchange.expires_at <= timezone('utc', now()));

  exchange_token := encode(gen_random_bytes(32), 'hex');
  insert into private.staff_session_exchanges(token_hash, auth_user_id, expires_at)
  values (
    encode(digest(exchange_token, 'sha256'), 'hex'),
    actor,
    timezone('utc', now()) + interval '2 minutes'
  );

  return jsonb_build_object('exchangeToken', exchange_token);
end;
$$;

create or replace function app.consume_staff_session_exchange(p_exchange_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  exchange private.staff_session_exchanges%rowtype;
  profile app.staff_profiles%rowtype;
  session_token text;
  now_utc timestamptz := timezone('utc', now());
begin
  if p_exchange_token is null or p_exchange_token !~ '^[0-9a-f]{64}$' then
    raise exception 'STAFF_SESSION_EXCHANGE_INVALID' using errcode = '22023';
  end if;

  select * into exchange
  from private.staff_session_exchanges item
  where item.token_hash = encode(digest(p_exchange_token, 'sha256'), 'hex')
    and item.consumed_at is null
    and item.expires_at > now_utc
  for update;
  if exchange.auth_user_id is null then
    raise exception 'STAFF_SESSION_EXCHANGE_INVALID' using errcode = '22023';
  end if;

  select * into profile
  from app.staff_profiles item
  where item.auth_user_id = exchange.auth_user_id and item.active = true;
  if profile.auth_user_id is null then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  update private.staff_session_exchanges
  set consumed_at = now_utc
  where token_hash = exchange.token_hash;

  session_token := encode(gen_random_bytes(32), 'hex');
  insert into private.staff_sessions(token_hash, auth_user_id, expires_at)
  values (
    encode(digest(session_token, 'sha256'), 'hex'),
    profile.auth_user_id,
    now_utc + interval '8 hours'
  );

  return jsonb_build_object(
    'sessionToken', session_token,
    'context', jsonb_build_object(
      'userId', profile.auth_user_id,
      'displayName', profile.display_name,
      'role', profile.role,
      'activeSeason', (
        select jsonb_build_object('id', season.id, 'name', season.name)
        from app.app_settings settings
        join app.seasons season on season.id = settings.active_season_id
        where settings.id = true
        limit 1
      )
    )
  );
end;
$$;

create or replace function app.get_staff_app_session(p_session_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  profile app.staff_profiles%rowtype;
begin
  if p_session_token is null or p_session_token !~ '^[0-9a-f]{64}$' then
    return null;
  end if;

  select staff.* into profile
  from private.staff_sessions session
  join app.staff_profiles staff on staff.auth_user_id = session.auth_user_id
  where session.token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
    and session.revoked_at is null
    and session.expires_at > timezone('utc', now())
    and staff.active = true;
  if profile.auth_user_id is null then return null; end if;

  return jsonb_build_object(
    'userId', profile.auth_user_id,
    'displayName', profile.display_name,
    'role', profile.role,
    'activeSeason', (
      select jsonb_build_object('id', season.id, 'name', season.name)
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
      limit 1
    )
  );
end;
$$;

create or replace function app.revoke_staff_app_session(p_session_token text)
returns integer
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  affected integer;
begin
  if p_session_token is null or p_session_token !~ '^[0-9a-f]{64}$' then return 0; end if;
  update private.staff_sessions
  set revoked_at = timezone('utc', now())
  where token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
    and revoked_at is null;
  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function app.create_staff_session_exchange() from public, anon;
grant execute on function app.create_staff_session_exchange() to authenticated;
revoke all on function app.consume_staff_session_exchange(text) from public, anon, authenticated;
revoke all on function app.get_staff_app_session(text) from public, anon, authenticated;
revoke all on function app.revoke_staff_app_session(text) from public, anon, authenticated;
grant execute on function app.consume_staff_session_exchange(text) to service_role;
grant execute on function app.get_staff_app_session(text) to service_role;
grant execute on function app.revoke_staff_app_session(text) to service_role;

create or replace function app.cleanup_expired_security_data(p_now timestamptz)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  otp_count integer;
  rate_count integer;
  session_count integer;
  email_event_count integer;
begin
  if p_now is null then raise exception 'INVALID_RETENTION_TIMESTAMP' using errcode = '22023'; end if;
  delete from private.parent_otp_challenges challenge
  where challenge.used_at is not null and challenge.used_at <= p_now - interval '24 hours';
  get diagnostics otp_count = row_count;
  with deleted as (
    delete from private.parent_otp_challenges challenge
    where challenge.used_at is null and challenge.expires_at <= p_now - interval '24 hours' returning 1
  ) select otp_count + count(*)::integer into otp_count from deleted;
  delete from private.rate_limit_events event where event.occurred_at < p_now - interval '30 days';
  get diagnostics rate_count = row_count;
  delete from private.parent_sessions session
  where coalesce(session.revoked_at, session.expires_at) <= p_now - interval '30 days';
  get diagnostics session_count = row_count;
  delete from private.staff_session_exchanges exchange
  where coalesce(exchange.consumed_at, exchange.expires_at) <= p_now - interval '24 hours';
  delete from private.staff_sessions session
  where coalesce(session.revoked_at, session.expires_at) <= p_now - interval '30 days';
  delete from app.email_events event where event.occurred_at < p_now - interval '12 months';
  get diagnostics email_event_count = row_count;
  delete from private.operation_runs run
  where run.status <> 'running' and run.finished_at < p_now - interval '90 days';
  return jsonb_build_object(
    'otpChallenges', otp_count,
    'rateLimitEvents', rate_count,
    'parentSessions', session_count,
    'emailEvents', email_event_count
  );
end;
$$;
