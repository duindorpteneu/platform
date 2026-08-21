-- Privileged, credential-blind support operations for parent login.

create table private.parent_otp_support_events (
  id bigint generated always as identity primary key,
  request_id uuid not null unique,
  parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  actor_user_id uuid not null,
  action text not null check (action in ('resend', 'reset')),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
    and not result_snapshot ?| array[
      'code', 'codeHash', 'credential', 'directCredential', 'proof'
    ]
  ),
  occurred_at timestamptz not null default statement_timestamp()
);

create index parent_otp_support_events_limit_idx
  on private.parent_otp_support_events(parent_account_id, occurred_at desc);

alter table private.parent_otp_support_events enable row level security;
revoke all on private.parent_otp_support_events
from public, anon, authenticated, service_role;
revoke all on sequence private.parent_otp_support_events_id_seq
from public, anon, authenticated, service_role;

create or replace function private.prepare_parent_otp_attempt_payload_v1(
  p_parent_account_id uuid,
  p_challenge_id uuid,
  p_reused boolean,
  p_actor_user_id uuid,
  p_action text
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
  template app.mail_templates%rowtype;
  template_revision app.mail_template_revisions%rowtype;
  branding app.mail_branding_revisions%rowtype;
  attempt_id uuid;
begin
  select target.* into challenge
  from private.parent_otp_challenges target
  where target.id = p_challenge_id
    and target.parent_account_id = p_parent_account_id
    and target.credential_version = 3
    and target.closed_at is null
    and target.used_at is null
    and target.expires_at > now_utc
    and target.attempts < target.max_attempts
  for update;
  if challenge.id is null then
    raise exception 'PARENT_OTP_SUPPORT_CHALLENGE_UNAVAILABLE'
      using errcode = '23514';
  end if;
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
  insert into private.parent_otp_delivery_attempts(
    parent_account_id,
    challenge_id,
    template_revision_id,
    branding_revision_id,
    expires_at
  ) values (
    p_parent_account_id,
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
    p_actor_user_id,
    case when p_action = 'reset'
      then 'parent.otp.support.reset'
      else 'parent.otp.support.resent'
    end,
    'parent_account',
    p_parent_account_id,
    jsonb_build_object(
      'deliveryAttemptId', attempt_id,
      'challengeId', challenge.id,
      'credentialVersion', 3,
      'reused', p_reused
    )
  );
  return jsonb_build_object(
    'status', 'prepared',
    'challengeId', challenge.id,
    'expiresAt', challenge.expires_at,
    'cooldownUntil', now_utc,
    'reused', p_reused,
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

revoke all on function private.prepare_parent_otp_attempt_payload_v1(
  uuid, uuid, boolean, uuid, text
) from public, anon, authenticated, service_role;

create or replace function app.prepare_parent_otp_support_delivery_v1(
  p_parent_account_id uuid,
  p_mode text,
  p_challenge_id uuid,
  p_code_hash text,
  p_request_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  now_utc timestamptz := statement_timestamp();
  account private.parent_accounts%rowtype;
  challenge private.parent_otp_challenges%rowtype;
  previous private.parent_otp_support_events%rowtype;
  reused boolean := false;
  request_hash text;
  result jsonb;
begin
  if p_parent_account_id is null
    or p_mode not in ('resend', 'reset')
    or p_challenge_id is null
    or p_code_hash is null
    or p_code_hash !~ '^[0-9a-f]{64}$'
    or p_request_id is null
  then
    raise exception 'PARENT_OTP_SUPPORT_INPUT_INVALID' using errcode = '22023';
  end if;

  request_hash := encode(extensions.digest(convert_to(
    jsonb_build_object(
      'parentAccountId', p_parent_account_id,
      'mode', p_mode
    )::text,
    'UTF8'
  ), 'sha256'), 'hex');

  -- Serialize every decision for one account before inspecting the bounded
  -- ledger. This makes the fifth accepted action visible to a concurrent
  -- sixth action and keeps concurrent resets from invalidating each other.
  perform pg_advisory_xact_lock(hashtextextended(
    'parent-auth-account:' || p_parent_account_id::text, 0
  ));

  select target.* into account
  from private.parent_accounts target
  where target.id = p_parent_account_id
  for update;
  if account.id is null
    or not private.parent_account_has_portal_access(account.id)
  then
    raise exception 'PARENT_OTP_SUPPORT_ACCOUNT_UNAVAILABLE'
      using errcode = 'P0002';
  end if;

  select event.* into previous
  from private.parent_otp_support_events event
  where event.request_id = p_request_id;
  if previous.id is not null then
    if previous.parent_account_id <> account.id
      or previous.actor_user_id <> actor
      or previous.action <> p_mode
      or previous.request_hash <> request_hash
    then
      raise exception 'PARENT_OTP_SUPPORT_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    return previous.result_snapshot
      || jsonb_build_object('supportRequestReused', true);
  end if;

  if (
    select count(*)
    from private.parent_otp_support_events event
    where event.parent_account_id = p_parent_account_id
      and event.occurred_at > now_utc - interval '15 minutes'
  ) >= 5 then
    raise exception 'PARENT_OTP_SUPPORT_RATE_LIMITED' using errcode = 'P0001';
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
  if challenge.id is not null
    and (p_mode = 'reset' or challenge.credential_version <> 3)
  then
    update private.parent_otp_challenges target
    set closed_at = now_utc,
        close_reason = case
          when p_mode = 'reset' then 'support_reset'
          else 'legacy_superseded'
        end,
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
    ) returning * into challenge;
  else
    reused := true;
  end if;
  result := private.prepare_parent_otp_attempt_payload_v1(
    account.id,
    challenge.id,
    reused,
    actor,
    p_mode
  ) || jsonb_build_object('supportRequestReused', false);

  insert into private.parent_otp_support_events(
    request_id,
    parent_account_id,
    actor_user_id,
    action,
    request_hash,
    result_snapshot
  ) values (
    p_request_id,
    account.id,
    actor,
    p_mode,
    request_hash,
    result
  );
  return result;
end;
$$;

revoke all on function app.prepare_parent_otp_support_delivery_v1(
  uuid, text, uuid, text, uuid
) from public, anon;
grant execute on function app.prepare_parent_otp_support_delivery_v1(
  uuid, text, uuid, text, uuid
) to authenticated;

create or replace function app.get_parent_otp_support_request_outcome_v1(
  p_request_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select case outcome.outcome
    when 'accepted' then 'provider_accepted'
    when 'provider_rejected' then 'provider_rejected'
    when 'delivery_uncertain' then 'delivery_uncertain'
    when 'configuration_error' then 'configuration_error'
    when 'disabled' then 'disabled'
    when 'render_failed' then 'render_failed'
    else 'delivery_uncertain'
  end
  from private.parent_otp_support_events event
  left join private.parent_otp_delivery_outcomes outcome
    on outcome.delivery_attempt_id = nullif(
      event.result_snapshot->>'deliveryAttemptId', ''
    )::uuid
  where event.request_id = p_request_id;
$$;

revoke all on function app.get_parent_otp_support_request_outcome_v1(uuid)
from public, anon, authenticated;
grant execute on function app.get_parent_otp_support_request_outcome_v1(uuid)
to service_role;

create or replace function app.get_parent_otp_support_v1(
  p_parent_account_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  account private.parent_accounts%rowtype;
  challenge private.parent_otp_challenges%rowtype;
  attempt private.parent_otp_delivery_attempts%rowtype;
  outcome private.parent_otp_delivery_outcomes%rowtype;
  local_part text;
  domain_part text;
begin
  select target.* into account
  from private.parent_accounts target
  where target.id = p_parent_account_id;
  if account.id is null
    or not private.parent_account_has_portal_access(account.id)
  then
    raise exception 'PARENT_OTP_SUPPORT_ACCOUNT_UNAVAILABLE'
      using errcode = 'P0002';
  end if;
  select target.* into challenge
  from private.parent_otp_challenges target
  where target.parent_account_id = account.id
  order by target.created_at desc, target.id desc
  limit 1;
  select target.* into attempt
  from private.parent_otp_delivery_attempts target
  where target.parent_account_id = account.id
  order by target.created_at desc, target.id desc
  limit 1;
  if attempt.id is not null then
    select target.* into outcome
    from private.parent_otp_delivery_outcomes target
    where target.delivery_attempt_id = attempt.id;
  end if;
  local_part := split_part(account.email_normalized, '@', 1);
  domain_part := split_part(account.email_normalized, '@', 2);
  return jsonb_build_object(
    'parentAccountId', account.id,
    'status', 'active',
    'loginEmailMasked', left(local_part, 1)
      || repeat('*', greatest(3, length(local_part) - 1))
      || '@' || domain_part,
    'lastCodeRequestedAt', challenge.created_at,
    'lastDeliveryAttemptAt', attempt.created_at,
    'lastDeliveryStatus', case
      when outcome.outcome = 'accepted' then 'provider_accepted'
      when outcome.outcome is not null then outcome.outcome
      else null
    end,
    'codeExpiresAt', case
      when challenge.closed_at is null
        and challenge.expires_at > statement_timestamp()
        and challenge.attempts < challenge.max_attempts
      then challenge.expires_at
      else null
    end,
    'lastSuccessfulLoginAt', account.last_login_at,
    'linkedChildren', coalesce((
      select jsonb_agg(jsonb_build_object(
        'memberId', family.member_id,
        'memberSeasonId', family.member_season_id,
        'memberName', concat_ws(' ', member.first_name,
          member.insertion, member.last_name),
        'team', coalesce(member_season.team_name, 'Onbekend team')
      ) order by member.last_name, member.first_name, family.member_season_id)
      from private.current_parent_family_member_seasons(account.id) family
      join app.members member on member.id = family.member_id
      join app.member_seasons member_season
        on member_season.id = family.member_season_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_parent_otp_support_v1(uuid)
from public, anon;
grant execute on function app.get_parent_otp_support_v1(uuid)
to authenticated;

comment on function app.prepare_parent_otp_support_delivery_v1(
  uuid, text, uuid, text, uuid
) is
  'Request-idempotent AAL2 administrator-only resend/reset preparation; returns delivery metadata but never either challenge credential.';

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260821161000_parent_otp_support',
  'passed',
  jsonb_build_object('supportEvents', 0)
)
on conflict (migration_key) do update
set status = excluded.status,
    metrics = excluded.metrics,
    reconciled_at = statement_timestamp();

select pg_notify('pgrst', 'reload schema');
