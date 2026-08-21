-- Atomically bind an explicitly gated staging verification request to the
-- parent session it creates. Normal parent sessions keep this column null.

alter table private.parent_sessions
  add column if not exists acceptance_correlation_hash text;

alter table private.parent_sessions
  drop constraint if exists parent_sessions_acceptance_correlation_hash_check;
alter table private.parent_sessions
  add constraint parent_sessions_acceptance_correlation_hash_check
  check (
    acceptance_correlation_hash is null
    or acceptance_correlation_hash ~ '^[0-9a-f]{64}$'
  );

create unique index if not exists parent_sessions_acceptance_correlation_unique
  on private.parent_sessions(acceptance_correlation_hash)
  where acceptance_correlation_hash is not null;

create or replace function app.consume_parent_login_challenge_v4(
  p_challenge_id uuid,
  p_credential_kind text,
  p_code_hash text,
  p_session_token_hash text,
  p_session_expires_at timestamptz,
  p_acceptance_correlation_hash text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  now_utc timestamptz := statement_timestamp();
  challenge private.parent_otp_challenges%rowtype;
  account private.parent_accounts%rowtype;
  session_id uuid;
  remaining integer;
begin
  if p_challenge_id is null
    or p_credential_kind not in ('code', 'direct')
    or (
      p_credential_kind = 'code'
      and (p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$')
    )
    or (p_credential_kind = 'direct' and p_code_hash is not null)
    or p_session_token_hash is null
    or p_session_token_hash !~ '^[0-9a-f]{64}$'
    or (
      p_acceptance_correlation_hash is not null
      and p_acceptance_correlation_hash !~ '^[0-9a-f]{64}$'
    )
    or p_session_expires_at is null
    or p_session_expires_at <= now_utc
    or p_session_expires_at > now_utc + interval '30 days'
  then
    return jsonb_build_object('status', 'invalid');
  end if;

  select target.* into challenge
  from private.parent_otp_challenges target
  where target.id = p_challenge_id;
  if challenge.id is null then
    return jsonb_build_object('status', 'invalid');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'parent-auth-account:' || challenge.parent_account_id::text, 0
  ));
  select target.* into account
  from private.parent_accounts target
  where target.id = challenge.parent_account_id
  for update;
  select target.* into challenge
  from private.parent_otp_challenges target
  where target.id = p_challenge_id
    and target.parent_account_id = account.id
  for update;

  if account.id is null
    or challenge.id is null
    or challenge.credential_version <> 3
    or challenge.closed_at is not null
    or challenge.used_at is not null
    or challenge.expires_at <= now_utc
    or challenge.attempts >= challenge.max_attempts
    or not private.parent_account_has_portal_access(account.id)
  then
    if challenge.id is not null and challenge.closed_at is null then
      if challenge.expires_at <= now_utc then
        update private.parent_otp_challenges target
        set closed_at = now_utc,
            close_reason = 'expired'
        where target.id = challenge.id;
      elsif challenge.attempts >= challenge.max_attempts then
        update private.parent_otp_challenges target
        set closed_at = now_utc,
            close_reason = 'attempts_exhausted'
        where target.id = challenge.id;
      elsif account.id is not null
        and not private.parent_account_has_portal_access(account.id)
      then
        update private.parent_otp_challenges target
        set closed_at = now_utc,
            close_reason = 'access_revoked',
            used_at = coalesce(target.used_at, now_utc)
        where target.id = challenge.id;
      end if;
    end if;
    return jsonb_build_object('status', 'invalid');
  end if;

  if p_credential_kind = 'code'
    and challenge.code_hash <> p_code_hash
  then
    remaining := greatest(challenge.max_attempts - challenge.attempts - 1, 0);
    update private.parent_otp_challenges target
    set attempts = target.attempts + 1,
        closed_at = case when remaining = 0 then now_utc else null end,
        close_reason = case
          when remaining = 0 then 'attempts_exhausted'
          else null
        end
    where target.id = challenge.id;
    return jsonb_build_object(
      'status', 'invalid',
      'attemptsRemaining', remaining
    );
  end if;

  insert into private.parent_sessions(
    parent_account_id,
    token_hash,
    expires_at,
    acceptance_correlation_hash
  ) values (
    account.id,
    p_session_token_hash,
    p_session_expires_at,
    p_acceptance_correlation_hash
  ) returning id into session_id;
  update private.parent_otp_challenges target
  set used_at = now_utc,
      closed_at = now_utc,
      close_reason = 'consumed'
  where target.id = challenge.id;
  update private.parent_accounts target
  set last_login_at = now_utc
  where target.id = account.id;
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    'parent.login.challenge.consumed',
    'parent_account',
    account.id,
    jsonb_build_object(
      'challengeId', challenge.id,
      'credentialVersion', 3,
      'credentialKind', p_credential_kind,
      'sessionId', session_id
    )
  );
  return jsonb_build_object(
    'status', 'verified',
    'parentAccountId', account.id
  );
end;
$$;

revoke all on function app.consume_parent_login_challenge_v4(
  uuid, text, text, text, timestamptz, text
) from public, anon, authenticated;
grant execute on function app.consume_parent_login_challenge_v4(
  uuid, text, text, text, timestamptz, text
) to service_role;

comment on column private.parent_sessions.acceptance_correlation_hash is
  'Nullable HMAC correlation for explicitly gated staging acceptance verification; never a session credential.';
comment on function app.consume_parent_login_challenge_v4(
  uuid, text, text, text, timestamptz, text
) is
  'Backward-compatible successor that atomically stores an optional staging acceptance correlation with the parent session.';
