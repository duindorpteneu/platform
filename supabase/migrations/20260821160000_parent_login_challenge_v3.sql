-- Stable parent login challenge v3.
-- A resend creates a new immutable delivery attempt for the same challenge.
-- The application derives both credentials from the challenge UUID with
-- domain-separated HMAC and stores only the existing OTP verification hash.

alter table private.parent_otp_challenges
  add column credential_version smallint not null default 1,
  add column closed_at timestamptz,
  add column close_reason text;

alter table private.parent_otp_challenges
  add constraint parent_otp_challenges_credential_version_check
    check (credential_version in (1, 3)),
  add constraint parent_otp_challenges_close_reason_check
    check (
      (closed_at is null and close_reason is null)
      or (
        closed_at is not null
        and close_reason in (
          'consumed',
          'expired',
          'attempts_exhausted',
          'support_reset',
          'access_revoked',
          'legacy_superseded'
        )
      )
    );

update private.parent_otp_challenges challenge
set closed_at = coalesce(challenge.used_at, least(challenge.expires_at, statement_timestamp())),
    close_reason = case
      when challenge.used_at is not null then 'consumed'
      when challenge.attempts >= challenge.max_attempts then 'attempts_exhausted'
      else 'expired'
    end
where challenge.closed_at is null
  and (
    challenge.used_at is not null
    or challenge.expires_at <= statement_timestamp()
    or challenge.attempts >= challenge.max_attempts
  );

-- Any still-open legacy challenge cannot be reproduced. It is replaced once
-- on the first v3 request rather than pretending its random OTP is stable.
update private.parent_otp_challenges challenge
set closed_at = statement_timestamp(),
    close_reason = 'legacy_superseded',
    used_at = coalesce(challenge.used_at, statement_timestamp())
where challenge.closed_at is null
  and challenge.credential_version <> 3;

create unique index parent_otp_one_open_challenge_idx
  on private.parent_otp_challenges(parent_account_id)
  where closed_at is null and used_at is null;

alter table private.parent_otp_delivery_attempts
  drop constraint parent_otp_delivery_attempts_challenge_id_key;

create index parent_otp_delivery_attempts_challenge_idx
  on private.parent_otp_delivery_attempts(challenge_id, created_at desc);

create or replace function app.prepare_parent_otp_delivery_v3(
  p_email text,
  p_challenge_id uuid,
  p_code_hash text,
  p_force_new boolean default false,
  p_actor_user_id uuid default null,
  p_expected_challenge_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  now_utc timestamptz := statement_timestamp();
  normalized_email text := lower(nullif(btrim(normalize(p_email, NFKC)), ''));
  email_key_hash text;
  account private.parent_accounts%rowtype;
  challenge private.parent_otp_challenges%rowtype;
  template app.mail_templates%rowtype;
  template_revision app.mail_template_revisions%rowtype;
  branding app.mail_branding_revisions%rowtype;
  last_send_at timestamptz;
  cooldown_until timestamptz;
  attempt_id uuid;
  reused boolean := false;
begin
  if normalized_email is null
    or length(normalized_email) not between 3 and 254
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or p_challenge_id is null
    or p_code_hash is null
    or p_code_hash !~ '^[0-9a-f]{64}$'
    or p_force_new is null
    or p_actor_user_id is not null
    or (p_force_new and p_expected_challenge_id is null)
    or (not p_force_new and p_expected_challenge_id is not null)
  then
    raise exception 'PARENT_OTP_V3_INPUT_INVALID' using errcode = '22023';
  end if;
  if not private.mail_templates_v2_cutover_started() then
    return jsonb_build_object('status', 'unavailable');
  end if;
  if not private.mail_templates_v2_enabled() then
    return jsonb_build_object('status', 'blocked');
  end if;

  -- Resolve immutable render dependencies before changing challenge state.
  -- A missing template/branding revision must never invalidate a usable code.
  select * into template
  from app.mail_templates target
  where target.template_key = 'login_otp'
    and target.active;
  select * into template_revision
  from app.mail_template_revisions revision
  where revision.template_key = 'login_otp'
    and revision.status = 'published'
  order by revision.revision desc
  limit 1;
  select * into branding
  from app.mail_branding_revisions revision
  where revision.status = 'published'
  order by revision.revision desc
  limit 1;
  if template.template_key is null
    or template_revision.id is null
    or branding.id is null
  then
    return jsonb_build_object('status', 'blocked');
  end if;

  select target.* into account
  from private.parent_accounts target
  where target.email_normalized = normalized_email;
  if account.id is null then
    return jsonb_build_object('status', 'ineligible');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'parent-auth-account:' || account.id::text, 0
  ));
  select target.* into account
  from private.parent_accounts target
  where target.id = account.id
  for update;
  if not private.parent_account_has_portal_access(account.id) then
    return jsonb_build_object('status', 'ineligible');
  end if;

  update private.parent_otp_challenges target
  set closed_at = now_utc,
      close_reason = case
        when target.attempts >= target.max_attempts then 'attempts_exhausted'
        else 'expired'
      end
  where target.parent_account_id = account.id
    and target.closed_at is null
    and (
      target.expires_at <= now_utc
      or target.attempts >= target.max_attempts
    );

  select target.* into challenge
  from private.parent_otp_challenges target
  where target.parent_account_id = account.id
    and target.closed_at is null
  for update;

  -- A public force-new request is a compare-and-rotate operation. Possession
  -- of an older sealed context must never close a challenge created later by
  -- support or another browser tab, nor reveal that newer challenge context.
  if p_force_new and (
    challenge.id is null
    or challenge.credential_version <> 3
    or challenge.id <> p_expected_challenge_id
  ) then
    return jsonb_build_object('status', 'ineligible');
  end if;

  -- Decide whether another send is allowed before replacing any credential.
  -- This preserves the current challenge when a force-new click is cooled down
  -- or rate limited, instead of closing it without sending its replacement.
  email_key_hash := encode(extensions.digest(normalized_email, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(
    'otp_request:' || email_key_hash, 0
  ));
  select max(event.occurred_at) into last_send_at
  from private.rate_limit_events event
  where event.scope = 'otp_request'
    and event.key_hash = email_key_hash;
  cooldown_until := coalesce(last_send_at + interval '90 seconds', now_utc);
  if cooldown_until > now_utc then
    if challenge.id is not null and challenge.credential_version = 3 then
      return jsonb_build_object(
        'status', 'cooldown',
        'challengeId', challenge.id,
        'expiresAt', challenge.expires_at,
        'cooldownUntil', cooldown_until
      );
    end if;
    return jsonb_build_object('status', 'ineligible');
  end if;
  if (
    select count(*)
    from private.rate_limit_events event
    where event.scope = 'otp_request'
      and event.key_hash = email_key_hash
      and event.occurred_at > now_utc - interval '1 hour'
  ) >= 5 then
    if challenge.id is not null and challenge.credential_version = 3 then
      return jsonb_build_object(
        'status', 'rate_limited',
        'challengeId', challenge.id,
        'expiresAt', challenge.expires_at,
        'cooldownUntil', now_utc + interval '90 seconds'
      );
    end if;
    return jsonb_build_object('status', 'ineligible');
  end if;

  if p_force_new and challenge.id is not null then
    update private.parent_otp_challenges target
    set closed_at = now_utc,
        close_reason = 'support_reset',
        used_at = coalesce(target.used_at, now_utc)
    where target.id = challenge.id
      and target.id = p_expected_challenge_id;
    if not found then
      return jsonb_build_object('status', 'ineligible');
    end if;
    challenge := null;
  end if;

  if challenge.id is not null and challenge.credential_version <> 3 then
    update private.parent_otp_challenges target
    set closed_at = now_utc,
        close_reason = 'legacy_superseded',
        used_at = coalesce(target.used_at, now_utc)
    where target.id = challenge.id;
    challenge := null;
  end if;

  if challenge.id is null then
    insert into private.parent_otp_challenges(
      id,
      parent_account_id,
      code_hash,
      expires_at,
      credential_version
    ) values (
      p_challenge_id,
      account.id,
      p_code_hash,
      now_utc + interval '10 minutes',
      3
    )
    returning * into challenge;
  else
    reused := true;
  end if;

  insert into private.rate_limit_events(scope, key_hash, occurred_at)
  values('otp_request', email_key_hash, now_utc);
  cooldown_until := now_utc + interval '90 seconds';

  insert into private.parent_otp_delivery_attempts(
    parent_account_id,
    challenge_id,
    template_revision_id,
    branding_revision_id,
    expires_at
  ) values (
    account.id,
    challenge.id,
    template_revision.id,
    branding.id,
    challenge.expires_at
  ) returning id into attempt_id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    case when reused
      then 'parent.otp.delivery.resent'
      else 'parent.otp.delivery.prepared'
    end,
    'parent_account',
    account.id,
    jsonb_build_object(
      'deliveryAttemptId', attempt_id,
      'challengeId', challenge.id,
      'credentialVersion', 3,
      'reused', reused,
      'templateRevisionId', template_revision.id,
      'brandingRevisionId', branding.id
    )
  );

  return jsonb_build_object(
    'status', 'prepared',
    'challengeId', challenge.id,
    'expiresAt', challenge.expires_at,
    'cooldownUntil', cooldown_until,
    'reused', reused,
    'deliveryAttemptId', attempt_id,
    'expiresInMinutes', greatest(
      1,
      ceil(extract(epoch from (challenge.expires_at - now_utc)) / 60)::integer
    ),
    'template', jsonb_build_object(
      'id', template_revision.id,
      'templateKey', template_revision.template_key,
      'subjectSource', template_revision.subject_source,
      'preheaderSource', template_revision.preheader_source,
      'bodyTipTap', template_revision.body_tiptap,
      'contentHash', template_revision.content_hash,
      'allowedShortcodes', template.allowed_shortcode_keys,
      'allowedProtectedNodes', template.allowed_protected_nodes,
      'requiredProtectedNodes', template.required_protected_nodes
    ),
    'branding', jsonb_build_object(
      'id', branding.id,
      'clubName', branding.club_name,
      'logoAssetPath', branding.logo_asset_path,
      'fromName', branding.from_name,
      'fromEmail', branding.from_email,
      'replyToEmail', branding.reply_to_email,
      'contactEmail', branding.contact_email,
      'clubAddressLine', branding.club_address_line,
      'clubPostalCode', branding.club_postal_code,
      'clubCity', branding.club_city,
      'pickupName', branding.pickup_name,
      'pickupAddressLine', branding.pickup_address_line,
      'pickupPostalCode', branding.pickup_postal_code,
      'pickupCity', branding.pickup_city,
      'privacyUrl', branding.privacy_url,
      'primaryColor', branding.primary_color,
      'secondaryColor', branding.secondary_color,
      'accentColor', branding.accent_color,
      'footerText', branding.footer_text,
      'contrastValidated', branding.contrast_validated,
      'contentHash', branding.content_hash
    )
  );
end;
$$;

revoke all on function app.prepare_parent_otp_delivery_v3(
  text, uuid, text, boolean, uuid, uuid
) from public, anon, authenticated;
grant execute on function app.prepare_parent_otp_delivery_v3(
  text, uuid, text, boolean, uuid, uuid
) to service_role;

create or replace function app.consume_parent_login_challenge_v3(
  p_challenge_id uuid,
  p_credential_kind text,
  p_code_hash text,
  p_session_token_hash text,
  p_session_expires_at timestamptz
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
    expires_at
  ) values (
    account.id,
    p_session_token_hash,
    p_session_expires_at
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

revoke all on function app.consume_parent_login_challenge_v3(
  uuid, text, text, text, timestamptz
) from public, anon, authenticated;
grant execute on function app.consume_parent_login_challenge_v3(
  uuid, text, text, text, timestamptz
) to service_role;

comment on function app.prepare_parent_otp_delivery_v3(
  text, uuid, text, boolean, uuid, uuid
) is
  'Prepares one immutable send attempt while reusing one stable v3 challenge; public force-new is compare-and-rotate bound to the expected active challenge and never returns either login credential.';
comment on function app.consume_parent_login_challenge_v3(
  uuid, text, text, text, timestamptz
) is
  'Atomically consumes a v3 code or server-verified direct-login proof and creates the parent session.';

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260821160000_parent_login_challenge_v3',
  'passed',
  jsonb_build_object(
    'openChallenges', (
      select count(*)
      from private.parent_otp_challenges
      where closed_at is null
    ),
    'v3Challenges', (
      select count(*)
      from private.parent_otp_challenges
      where credential_version = 3
    )
  )
)
on conflict (migration_key) do update
set status = excluded.status,
    metrics = excluded.metrics,
    reconciled_at = statement_timestamp();

select pg_notify('pgrst', 'reload schema');
