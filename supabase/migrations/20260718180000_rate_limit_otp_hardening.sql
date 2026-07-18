create table private.rate_limit_events (
  id bigint generated always as identity primary key,
  scope text not null check (scope in ('otp_request', 'otp_verify', 'mollie_create', 'export', 'search')),
  key_hash text not null check (key_hash ~ '^[0-9a-f]{64}$'),
  occurred_at timestamptz not null default timezone('utc', now())
);

create index rate_limit_events_lookup_idx
  on private.rate_limit_events(scope, key_hash, occurred_at desc);
create index rate_limit_events_retention_idx
  on private.rate_limit_events(occurred_at);

alter table private.rate_limit_events enable row level security;
revoke all on private.rate_limit_events from public, anon, authenticated, service_role;
revoke all on sequence private.rate_limit_events_id_seq from public, anon, authenticated, service_role;

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
    or p_scope <> all(array['otp_request', 'otp_verify', 'mollie_create', 'export', 'search'])
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

  perform pg_advisory_xact_lock(hashtextextended(p_scope || ':' || p_key_hash, 0));

  if (
    select count(*)
    from private.rate_limit_events event
    where event.scope = p_scope
      and event.key_hash = p_key_hash
      and event.occurred_at > now_utc - make_interval(secs => p_window_seconds)
  ) >= p_limit then
    return false;
  end if;

  insert into private.rate_limit_events(scope, key_hash, occurred_at)
  values(p_scope, p_key_hash, now_utc);
  return true;
end;
$$;

create or replace function public.create_parent_otp(
  p_email text,
  p_code_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
volatile
security definer
set search_path = private, app, pg_temp
as $$
declare
  account_id uuid;
  normalized_email text := lower(trim(p_email));
  email_key_hash text;
  now_utc timestamptz := timezone('utc', now());
begin
  if normalized_email is null
    or length(normalized_email) not between 3 and 254
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+$'
    or p_code_hash is null
    or p_code_hash !~ '^[0-9a-f]{64}$'
    or p_expires_at is null
  then
    return null;
  end if;

  email_key_hash := encode(extensions.digest(normalized_email, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('otp_request:' || email_key_hash, 0));

  if exists (
    select 1
    from private.rate_limit_events event
    where event.scope = 'otp_request'
      and event.key_hash = email_key_hash
      and event.occurred_at > now_utc - interval '60 seconds'
  ) then
    return null;
  end if;

  if (
    select count(*)
    from private.rate_limit_events event
    where event.scope = 'otp_request'
      and event.key_hash = email_key_hash
      and event.occurred_at > now_utc - interval '1 hour'
  ) >= 5 then
    return null;
  end if;

  insert into private.rate_limit_events(scope, key_hash, occurred_at)
  values('otp_request', email_key_hash, now_utc);

  if not exists (
    select 1
    from app.members member
    where lower(trim(member.email)) = normalized_email
      and member.active_for_season = true
  ) then
    return null;
  end if;

  insert into private.parent_accounts(email_normalized)
  values(normalized_email)
  on conflict (email_normalized) do update
    set email_normalized = excluded.email_normalized
  returning id into account_id;

  update private.parent_otp_challenges
  set used_at = now_utc
  where parent_account_id = account_id
    and used_at is null
    and expires_at > now_utc;

  insert into private.parent_otp_challenges(parent_account_id, code_hash, expires_at)
  values(account_id, p_code_hash, now_utc + interval '10 minutes');

  return account_id;
end;
$$;

revoke all on function app.consume_rate_limit(text, text, integer, integer)
from public, anon, authenticated;
grant execute on function app.consume_rate_limit(text, text, integer, integer)
to service_role;

revoke all on function public.create_parent_otp(text, text, timestamptz)
from public, anon, authenticated;
grant execute on function public.create_parent_otp(text, text, timestamptz)
to service_role;
