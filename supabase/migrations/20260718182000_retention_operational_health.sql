create index parent_otp_challenges_retention_idx
  on private.parent_otp_challenges(coalesce(used_at, expires_at));
create index parent_sessions_retention_idx
  on private.parent_sessions((case when revoked_at is not null then revoked_at else expires_at end));
create index email_events_retention_idx
  on app.email_events(occurred_at);
create index payments_reconciliation_issue_idx
  on app.payments(reconciled_at desc)
  where reconciliation_issue is not null;

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
  if p_now is null then
    raise exception 'INVALID_RETENTION_TIMESTAMP' using errcode = '22023';
  end if;

  delete from private.parent_otp_challenges challenge
  where challenge.used_at is not null
    and challenge.used_at <= p_now - interval '24 hours';
  get diagnostics otp_count = row_count;

  with deleted as (
    delete from private.parent_otp_challenges challenge
    where challenge.used_at is null
      and challenge.expires_at <= p_now - interval '24 hours'
    returning 1
  )
  select otp_count + count(*)::integer into otp_count from deleted;

  delete from private.rate_limit_events event
  where event.occurred_at < p_now - interval '30 days';
  get diagnostics rate_count = row_count;

  delete from private.parent_sessions session
  where (case when session.revoked_at is not null then session.revoked_at else session.expires_at end)
    <= p_now - interval '30 days';
  get diagnostics session_count = row_count;

  delete from app.email_events event
  where event.occurred_at < p_now - interval '12 months';
  get diagnostics email_event_count = row_count;

  return jsonb_build_object(
    'otpChallenges', otp_count,
    'rateLimitEvents', rate_count,
    'parentSessions', session_count,
    'emailEvents', email_event_count
  );
end;
$$;

create or replace function app.get_operational_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  now_utc timestamptz := timezone('utc', now());
begin
  return jsonb_build_object(
    'emailJobs', jsonb_build_object(
      'queued', (select count(*) from private.email_jobs where status = 'queued'),
      'retry', (select count(*) from private.email_jobs where status = 'retry'),
      'processingStale', (select count(*) from private.email_jobs
        where status = 'processing' and claimed_at < now_utc - interval '15 minutes'),
      'failed', (select count(*) from private.email_jobs where status = 'failed')
    ),
    'reconciliationIssues', (
      select count(*) from app.payments where reconciliation_issue is not null
    ),
    'recentWebhookFailures', (
      select count(*) from private.payment_events
      where event_type = 'mismatch' and processed_at >= now_utc - interval '24 hours'
    ),
    'dbTime', to_char(now_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  );
end;
$$;

create or replace function app.revoke_parent_session(p_token_hash text)
returns integer
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  revoked_count integer;
  now_utc timestamptz := timezone('utc', now());
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_PARENT_SESSION_TOKEN' using errcode = '22023';
  end if;

  update private.parent_sessions session
  set revoked_at = now_utc
  where session.token_hash = p_token_hash
    and session.revoked_at is null
    and session.expires_at > now_utc;
  get diagnostics revoked_count = row_count;
  return revoked_count;
end;
$$;

create or replace function app.revoke_all_parent_sessions(p_parent_account_id uuid)
returns integer
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  revoked_count integer;
  now_utc timestamptz := timezone('utc', now());
begin
  if p_parent_account_id is null then
    raise exception 'INVALID_PARENT_ACCOUNT' using errcode = '22023';
  end if;

  update private.parent_sessions session
  set revoked_at = now_utc
  where session.parent_account_id = p_parent_account_id
    and session.revoked_at is null
    and session.expires_at > now_utc;
  get diagnostics revoked_count = row_count;
  return revoked_count;
end;
$$;

revoke all on function app.cleanup_expired_security_data(timestamptz)
from public, anon, authenticated;
grant execute on function app.cleanup_expired_security_data(timestamptz)
to service_role;

revoke all on function app.get_operational_health()
from public, anon, authenticated;
grant execute on function app.get_operational_health()
to service_role;

revoke all on function app.revoke_parent_session(text)
from public, anon, authenticated;
grant execute on function app.revoke_parent_session(text)
to service_role;

revoke all on function app.revoke_all_parent_sessions(uuid)
from public, anon, authenticated;
grant execute on function app.revoke_all_parent_sessions(uuid)
to service_role;
