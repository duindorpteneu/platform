-- LOGIN_OTP uses the published mail-v2 template and branding without ever
-- persisting the six-digit code, rendered body, recipient address or a
-- brute-forceable render digest. Delivery attempts and provider facts are
-- immutable, independently correlated and retention bounded.

create table private.parent_otp_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  challenge_id uuid not null unique,
  template_revision_id uuid not null
    references app.mail_template_revisions(id) on delete restrict,
  branding_revision_id uuid not null
    references app.mail_branding_revisions(id) on delete restrict,
  expires_at timestamptz not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint parent_otp_delivery_attempts_expiry_check check (
    expires_at > created_at
    and expires_at <= created_at + interval '11 minutes'
  )
);

comment on column private.parent_otp_delivery_attempts.challenge_id is
  'Opaque correlation only; deliberately no FK so challenge-secret retention can be shorter than delivery evidence.';

create table private.parent_otp_delivery_outcomes (
  id bigint generated always as identity primary key,
  delivery_attempt_id uuid not null unique
    references private.parent_otp_delivery_attempts(id) on delete restrict,
  outcome text not null check (
    outcome in (
      'accepted',
      'provider_rejected',
      'delivery_uncertain',
      'configuration_error',
      'disabled',
      'render_failed'
    )
  ),
  provider_http_message_id text check (
    provider_http_message_id is null
    or length(btrim(provider_http_message_id)) between 3 and 240
  ),
  error_code text check (
    error_code is null
    or error_code ~ '^[a-z0-9][a-z0-9._-]{0,99}$'
  ),
  created_at timestamptz not null default statement_timestamp(),
  constraint parent_otp_delivery_outcomes_shape_check check (
    (
      outcome = 'accepted'
      and provider_http_message_id is not null
      and error_code is null
    )
    or (
      outcome <> 'accepted'
      and provider_http_message_id is null
      and error_code is not null
    )
  )
);

create table private.parent_otp_provider_message_bindings (
  delivery_attempt_id uuid primary key
    references private.parent_otp_delivery_attempts(id) on delete restrict,
  provider_message_id text not null unique check (
    length(btrim(provider_message_id)) between 1 and 240
  ),
  bound_at timestamptz not null default statement_timestamp()
);

create table private.parent_otp_provider_events (
  id bigint generated always as identity primary key,
  delivery_attempt_id uuid not null
    references private.parent_otp_delivery_attempts(id) on delete restrict,
  provider_event_id text not null unique check (
    length(btrim(provider_event_id)) between 1 and 240
  ),
  provider_message_id text not null check (
    length(btrim(provider_message_id)) between 1 and 240
  ),
  event_type text not null check (
    event_type in (
      'delivered',
      'bounced',
      'deferred',
      'dropped',
      'failed'
    )
  ),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default statement_timestamp()
);

create table private.parent_otp_provider_event_quarantine (
  id bigint generated always as identity primary key,
  event_fingerprint text not null check (
    event_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  reason text not null check (
    reason in (
      'attempt_identity_missing',
      'event_identity_collision',
      'event_message_mismatch',
      'occurred_at_out_of_bounds'
    )
  ),
  delivery_attempt_id uuid,
  occurred_at timestamptz,
  recorded_at timestamptz not null default statement_timestamp(),
  unique (event_fingerprint, reason)
);

create index parent_otp_delivery_attempts_account_idx
  on private.parent_otp_delivery_attempts(
    parent_account_id,
    created_at desc
  );
create index parent_otp_delivery_attempts_retention_idx
  on private.parent_otp_delivery_attempts(created_at, id);
create index parent_otp_provider_events_attempt_idx
  on private.parent_otp_provider_events(
    delivery_attempt_id,
    occurred_at desc,
    id desc
  );
create index parent_otp_provider_quarantine_recorded_idx
  on private.parent_otp_provider_event_quarantine(recorded_at, id);

alter table private.parent_otp_delivery_attempts enable row level security;
alter table private.parent_otp_delivery_outcomes enable row level security;
alter table private.parent_otp_provider_message_bindings
  enable row level security;
alter table private.parent_otp_provider_events enable row level security;
alter table private.parent_otp_provider_event_quarantine
  enable row level security;

revoke all on
  private.parent_otp_delivery_attempts,
  private.parent_otp_delivery_outcomes,
  private.parent_otp_provider_message_bindings,
  private.parent_otp_provider_events,
  private.parent_otp_provider_event_quarantine
from public, anon, authenticated, service_role;

create or replace function private.guard_parent_otp_delivery_ledger()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  if tg_op = 'DELETE'
    and coalesce(
      current_setting('app.parent_otp_delivery_retention', true),
      'off'
    ) = 'on'
  then
    return old;
  end if;
  raise exception 'PARENT_OTP_DELIVERY_LEDGER_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger parent_otp_delivery_attempts_immutable
before update or delete on private.parent_otp_delivery_attempts
for each row execute function private.guard_parent_otp_delivery_ledger();
create trigger parent_otp_delivery_outcomes_immutable
before update or delete on private.parent_otp_delivery_outcomes
for each row execute function private.guard_parent_otp_delivery_ledger();
create trigger parent_otp_provider_message_bindings_immutable
before update or delete on private.parent_otp_provider_message_bindings
for each row execute function private.guard_parent_otp_delivery_ledger();
create trigger parent_otp_provider_events_immutable
before update or delete on private.parent_otp_provider_events
for each row execute function private.guard_parent_otp_delivery_ledger();
create trigger parent_otp_provider_event_quarantine_immutable
before update or delete on private.parent_otp_provider_event_quarantine
for each row execute function private.guard_parent_otp_delivery_ledger();

revoke all on function private.guard_parent_otp_delivery_ledger()
from public, anon, authenticated, service_role;

create or replace function app.prepare_parent_otp_delivery_v1(
  p_email text,
  p_code_hash text,
  p_expires_at timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  now_utc timestamptz := statement_timestamp();
  account_id uuid;
  challenge private.parent_otp_challenges%rowtype;
  template app.mail_templates%rowtype;
  template_revision app.mail_template_revisions%rowtype;
  branding app.mail_branding_revisions%rowtype;
  attempt_id uuid;
begin
  if p_code_hash is null
    or p_code_hash !~ '^[0-9a-f]{64}$'
    or p_expires_at is null
    or p_expires_at < now_utc + interval '9 minutes'
    or p_expires_at > now_utc + interval '11 minutes'
  then
    raise exception 'PARENT_OTP_DELIVERY_INPUT_INVALID'
      using errcode = '22023';
  end if;

  if not private.mail_templates_v2_cutover_started() then
    return jsonb_build_object('status', 'unavailable');
  end if;
  if not private.mail_templates_v2_enabled() then
    return jsonb_build_object('status', 'blocked');
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

  account_id := public.create_parent_otp(
    p_email,
    p_code_hash,
    p_expires_at
  );
  if account_id is null then
    return jsonb_build_object('status', 'ineligible');
  end if;

  select * into challenge
  from private.parent_otp_challenges target
  where target.parent_account_id = account_id
    and target.code_hash = p_code_hash
    and target.used_at is null
    and target.expires_at > now_utc
  order by target.created_at desc, target.id desc
  limit 1
  for update;
  if challenge.id is null then
    raise exception 'PARENT_OTP_CHALLENGE_MISSING'
      using errcode = '23514';
  end if;

  insert into private.parent_otp_delivery_attempts(
    parent_account_id,
    challenge_id,
    template_revision_id,
    branding_revision_id,
    expires_at
  ) values (
    account_id,
    challenge.id,
    template_revision.id,
    branding.id,
    challenge.expires_at
  )
  returning id into attempt_id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    'parent.otp.delivery.prepared',
    'parent_account',
    account_id,
    jsonb_build_object(
      'deliveryAttemptId', attempt_id,
      'templateRevisionId', template_revision.id,
      'brandingRevisionId', branding.id
    )
  );

  return jsonb_build_object(
    'status', 'prepared',
    'deliveryAttemptId', attempt_id,
    'expiresInMinutes', 10,
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

revoke all on function app.prepare_parent_otp_delivery_v1(
  text, text, timestamptz
) from public, anon, authenticated;
grant execute on function app.prepare_parent_otp_delivery_v1(
  text, text, timestamptz
) to service_role;

create or replace function app.authorize_parent_otp_delivery_v1(
  p_delivery_attempt_id uuid
)
returns boolean
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  attempt private.parent_otp_delivery_attempts%rowtype;
  authorized boolean;
begin
  if p_delivery_attempt_id is null then
    return false;
  end if;
  select * into attempt
  from private.parent_otp_delivery_attempts target
  where target.id = p_delivery_attempt_id
  for update;
  if attempt.id is null
    or exists(
      select 1
      from private.parent_otp_delivery_outcomes outcome
      where outcome.delivery_attempt_id = attempt.id
    )
  then
    return false;
  end if;
  select
    private.mail_templates_v2_enabled()
    and coalesce(public.is_operational_feature_enabled('email_enabled'), false)
    and private.parent_account_has_portal_access(
      attempt.parent_account_id
    )
    and attempt.expires_at > statement_timestamp()
    and exists(
      select 1
      from private.parent_otp_challenges challenge
      where challenge.id = attempt.challenge_id
        and challenge.parent_account_id = attempt.parent_account_id
        and challenge.used_at is null
        and challenge.expires_at > statement_timestamp()
        and challenge.attempts < challenge.max_attempts
    )
  into authorized;
  return coalesce(authorized, false);
end;
$$;

revoke all on function app.authorize_parent_otp_delivery_v1(uuid)
from public, anon, authenticated;
grant execute on function app.authorize_parent_otp_delivery_v1(uuid)
to service_role;

create or replace function app.complete_parent_otp_delivery_v1(
  p_delivery_attempt_id uuid,
  p_outcome text,
  p_provider_http_message_id text default null,
  p_error_code text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  attempt private.parent_otp_delivery_attempts%rowtype;
  existing private.parent_otp_delivery_outcomes%rowtype;
  normalized_message_id text :=
    nullif(btrim(p_provider_http_message_id), '');
  normalized_error text := nullif(btrim(p_error_code), '');
begin
  if p_delivery_attempt_id is null
    or p_outcome not in (
      'accepted',
      'provider_rejected',
      'delivery_uncertain',
      'configuration_error',
      'disabled',
      'render_failed'
    )
    or (
      p_outcome = 'accepted'
      and (
        normalized_message_id is null
        or length(normalized_message_id) not between 3 and 240
        or normalized_error is not null
      )
    )
    or (
      p_outcome <> 'accepted'
      and (
        normalized_message_id is not null
        or normalized_error is null
        or normalized_error
          !~ '^[a-z0-9][a-z0-9._-]{0,99}$'
      )
    )
  then
    raise exception 'PARENT_OTP_DELIVERY_OUTCOME_INVALID'
      using errcode = '22023';
  end if;

  select * into attempt
  from private.parent_otp_delivery_attempts target
  where target.id = p_delivery_attempt_id
  for update;
  if attempt.id is null then
    raise exception 'PARENT_OTP_DELIVERY_ATTEMPT_NOT_FOUND'
      using errcode = 'P0002';
  end if;

  select * into existing
  from private.parent_otp_delivery_outcomes target
  where target.delivery_attempt_id = attempt.id;
  if existing.id is not null then
    if existing.outcome = p_outcome
      and existing.provider_http_message_id
        is not distinct from normalized_message_id
      and existing.error_code is not distinct from normalized_error
    then
      return jsonb_build_object(
        'status', 'completed',
        'outcome', existing.outcome,
        'reused', true
      );
    end if;
    raise exception 'PARENT_OTP_DELIVERY_OUTCOME_CONFLICT'
      using errcode = '23505';
  end if;

  insert into private.parent_otp_delivery_outcomes(
    delivery_attempt_id,
    outcome,
    provider_http_message_id,
    error_code
  ) values (
    attempt.id,
    p_outcome,
    normalized_message_id,
    normalized_error
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    'parent.otp.delivery.completed',
    'parent_account',
    attempt.parent_account_id,
    jsonb_build_object(
      'deliveryAttemptId', attempt.id,
      'outcome', p_outcome
    )
  );
  return jsonb_build_object(
    'status', 'completed',
    'outcome', p_outcome,
    'reused', false
  );
end;
$$;

revoke all on function app.complete_parent_otp_delivery_v1(
  uuid, text, text, text
) from public, anon, authenticated;
grant execute on function app.complete_parent_otp_delivery_v1(
  uuid, text, text, text
) to service_role;

create or replace function private.quarantine_parent_otp_provider_event(
  p_reason text,
  p_delivery_attempt_id uuid,
  p_event_id text,
  p_provider_message_id text,
  p_event_type text,
  p_occurred_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = private, extensions, pg_temp
as $$
declare
  fingerprint text;
begin
  if p_reason not in (
    'attempt_identity_missing',
    'event_identity_collision',
    'event_message_mismatch',
    'occurred_at_out_of_bounds'
  ) then
    raise exception 'PARENT_OTP_PROVIDER_QUARANTINE_REASON_INVALID'
      using errcode = '22023';
  end if;
  fingerprint := encode(
    extensions.digest(
      convert_to(
        concat_ws(
          ':',
          coalesce(p_delivery_attempt_id::text, ''),
          coalesce(p_event_id, ''),
          coalesce(p_provider_message_id, ''),
          coalesce(p_event_type, ''),
          coalesce(p_occurred_at::text, '')
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  insert into private.parent_otp_provider_event_quarantine(
    event_fingerprint,
    reason,
    delivery_attempt_id,
    occurred_at
  ) values (
    fingerprint,
    p_reason,
    p_delivery_attempt_id,
    p_occurred_at
  )
  on conflict (event_fingerprint, reason) do nothing;
end;
$$;

revoke all on function private.quarantine_parent_otp_provider_event(
  text, uuid, text, text, text, timestamptz
) from public, anon, authenticated, service_role;

create or replace function app.record_parent_otp_sendgrid_events_v1(
  p_events jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  item record;
  attempt private.parent_otp_delivery_attempts%rowtype;
  existing private.parent_otp_provider_events%rowtype;
  normalized_event_id text;
  normalized_message_id text;
  bound_message_id text;
  inserted_count integer := 0;
  ignored_count integer := 0;
  quarantined_count integer := 0;
  affected integer;
begin
  if jsonb_typeof(p_events) <> 'array'
    or jsonb_array_length(p_events) > 500
  then
    raise exception 'PARENT_OTP_PROVIDER_EVENTS_INVALID'
      using errcode = '22023';
  end if;
  for item in
    select *
    from jsonb_to_recordset(p_events) as event_data(
      delivery_attempt_id uuid,
      event_id text,
      provider_message_id text,
      event_type text,
      occurred_at timestamptz
    )
  loop
    normalized_event_id := nullif(btrim(item.event_id), '');
    normalized_message_id :=
      nullif(btrim(item.provider_message_id), '');
    if item.delivery_attempt_id is null
      or normalized_event_id is null
      or length(normalized_event_id) > 240
      or normalized_message_id is null
      or length(normalized_message_id) > 240
      or item.occurred_at is null
      or item.event_type not in (
        'delivered',
        'bounced',
        'deferred',
        'dropped',
        'failed'
      )
    then
      perform private.quarantine_parent_otp_provider_event(
        'attempt_identity_missing',
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    select * into attempt
    from private.parent_otp_delivery_attempts target
    where target.id = item.delivery_attempt_id;
    if attempt.id is null then
      perform private.quarantine_parent_otp_provider_event(
        'attempt_identity_missing',
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;
    if item.occurred_at < attempt.created_at - interval '5 minutes'
      or item.occurred_at > statement_timestamp() + interval '5 minutes'
    then
      perform private.quarantine_parent_otp_provider_event(
        'occurred_at_out_of_bounds',
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    existing := null;
    select * into existing
    from private.parent_otp_provider_events provider_event
    where provider_event.provider_event_id = normalized_event_id;
    if existing.id is not null then
      if existing.delivery_attempt_id = item.delivery_attempt_id
        and existing.provider_message_id = normalized_message_id
        and existing.event_type = item.event_type
        and existing.occurred_at = item.occurred_at
      then
        ignored_count := ignored_count + 1;
      else
        perform private.quarantine_parent_otp_provider_event(
          'event_identity_collision',
          item.delivery_attempt_id,
          normalized_event_id,
          normalized_message_id,
          item.event_type,
          item.occurred_at
        );
        quarantined_count := quarantined_count + 1;
      end if;
      continue;
    end if;

    insert into private.parent_otp_provider_message_bindings(
      delivery_attempt_id,
      provider_message_id
    ) values (
      item.delivery_attempt_id,
      normalized_message_id
    )
    on conflict do nothing;
    select binding.provider_message_id into bound_message_id
    from private.parent_otp_provider_message_bindings binding
    where binding.delivery_attempt_id = item.delivery_attempt_id;
    if bound_message_id is distinct from normalized_message_id then
      perform private.quarantine_parent_otp_provider_event(
        'event_message_mismatch',
        item.delivery_attempt_id,
        normalized_event_id,
        normalized_message_id,
        item.event_type,
        item.occurred_at
      );
      quarantined_count := quarantined_count + 1;
      continue;
    end if;

    insert into private.parent_otp_provider_events(
      delivery_attempt_id,
      provider_event_id,
      provider_message_id,
      event_type,
      occurred_at
    ) values (
      item.delivery_attempt_id,
      normalized_event_id,
      normalized_message_id,
      item.event_type,
      item.occurred_at
    )
    on conflict (provider_event_id) do nothing;
    get diagnostics affected = row_count;
    if affected = 0 then
      ignored_count := ignored_count + 1;
    else
      inserted_count := inserted_count + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'recorded', inserted_count,
    'ignored', ignored_count,
    'quarantined', quarantined_count
  );
end;
$$;

revoke all on function app.record_parent_otp_sendgrid_events_v1(jsonb)
from public, anon, authenticated;
grant execute on function app.record_parent_otp_sendgrid_events_v1(jsonb)
to service_role;

create or replace function app.purge_parent_otp_delivery_history_v1(
  p_now timestamptz,
  p_retention_days integer default 90,
  p_limit integer default 500
)
returns integer
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  attempt_ids uuid[];
  deleted_count integer := 0;
  affected integer;
begin
  if p_now is null
    or p_retention_days not between 30 and 365
    or p_limit not between 1 and 5000
  then
    raise exception 'PARENT_OTP_DELIVERY_RETENTION_INVALID'
      using errcode = '22023';
  end if;
  select coalesce(array_agg(candidate.id), '{}'::uuid[])
  into attempt_ids
  from (
    select attempt.id
    from private.parent_otp_delivery_attempts attempt
    where attempt.created_at
      <= p_now - make_interval(days => p_retention_days)
    order by attempt.created_at, attempt.id
    for update skip locked
    limit p_limit
  ) candidate;

  perform set_config(
    'app.parent_otp_delivery_retention',
    'on',
    true
  );
  delete from private.parent_otp_provider_events
  where delivery_attempt_id = any(attempt_ids);
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;
  delete from private.parent_otp_provider_message_bindings
  where delivery_attempt_id = any(attempt_ids);
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;
  delete from private.parent_otp_delivery_outcomes
  where delivery_attempt_id = any(attempt_ids);
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;
  delete from private.parent_otp_delivery_attempts
  where id = any(attempt_ids);
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;
  with expired_quarantine as (
    select quarantine.id
    from private.parent_otp_provider_event_quarantine quarantine
    where quarantine.recorded_at
      <= p_now - make_interval(days => p_retention_days)
    order by quarantine.recorded_at, quarantine.id
    for update skip locked
    limit p_limit
  )
  delete from private.parent_otp_provider_event_quarantine quarantine
  where quarantine.id in (
    select expired_quarantine.id from expired_quarantine
  );
  get diagnostics affected = row_count;
  deleted_count := deleted_count + affected;
  perform set_config(
    'app.parent_otp_delivery_retention',
    'off',
    true
  );
  return deleted_count;
end;
$$;

revoke all on function app.purge_parent_otp_delivery_history_v1(
  timestamptz, integer, integer
) from public, anon, authenticated;
grant execute on function app.purge_parent_otp_delivery_history_v1(
  timestamptz, integer, integer
) to service_role;

create or replace function app.get_operational_health_v9(
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
  base jsonb := app.get_operational_health_v8(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  );
begin
  return base || jsonb_build_object(
    'parentOtpDelivery',
    jsonb_build_object(
      'stalePrepared',
      (
        select count(*)
        from private.parent_otp_delivery_attempts attempt
        where attempt.created_at
            < statement_timestamp() - interval '2 minutes'
          and not exists(
            select 1
            from private.parent_otp_delivery_outcomes outcome
            where outcome.delivery_attempt_id = attempt.id
          )
      ),
      'deliveryUncertainRecent',
      (
        select count(*)
        from private.parent_otp_delivery_outcomes outcome
        where outcome.outcome = 'delivery_uncertain'
          and outcome.created_at
            >= statement_timestamp() - interval '24 hours'
      ),
      'sendFailuresRecent',
      (
        select count(*)
        from private.parent_otp_delivery_outcomes outcome
        where outcome.outcome in (
            'provider_rejected',
            'configuration_error',
            'disabled',
            'render_failed'
          )
          and outcome.created_at
            >= statement_timestamp() - interval '24 hours'
      ),
      'quarantinedEvents',
      (
        select count(*)
        from private.parent_otp_provider_event_quarantine
      ),
      'providerFailuresRecent',
      (
        select count(*)
        from (
          select distinct on (event.delivery_attempt_id)
            event.delivery_attempt_id,
            event.event_type,
            event.occurred_at
          from private.parent_otp_provider_events event
          order by
            event.delivery_attempt_id,
            event.occurred_at desc,
            event.id desc
        ) latest
        where latest.event_type in ('bounced', 'dropped', 'failed')
          and latest.occurred_at
            >= statement_timestamp() - interval '24 hours'
      )
    )
  );
end;
$$;

revoke all on function app.get_operational_health_v9(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v9(
  text, integer, text, integer
) to service_role;

insert into private.mail_v2_process_capabilities(
  template_key,
  producer_version
) values ('login_otp', 1)
on conflict (template_key) do update
set producer_version = excluded.producer_version,
    enabled = true,
    registered_at = statement_timestamp();

do $$
declare
  direct_access bigint;
  producer_count integer;
begin
  select count(*) into direct_access
  from information_schema.role_table_grants grant_row
  where grant_row.table_schema = 'private'
    and grant_row.table_name in (
      'parent_otp_delivery_attempts',
      'parent_otp_delivery_outcomes',
      'parent_otp_provider_message_bindings',
      'parent_otp_provider_events',
      'parent_otp_provider_event_quarantine'
    )
    and grant_row.grantee in (
      'anon',
      'authenticated',
      'service_role'
    );
  select count(*)::integer into producer_count
  from private.mail_v2_process_capabilities capability
  where capability.enabled;
  if direct_access <> 0 or producer_count <> 19 then
    raise exception 'PARENT_OTP_MAIL_V2_RECONCILIATION_FAILED'
      using errcode = '23514';
  end if;
  insert into private.migration_reconciliations(
    migration_key,
    status,
    metrics
  ) values (
    '20260802279000_parent_otp_mail_v2',
    'passed',
    jsonb_build_object(
      'deliveryAttempts',
      (select count(*) from private.parent_otp_delivery_attempts),
      'enabledProducers',
      producer_count,
      'directApiTableGrants',
      direct_access
    )
  )
  on conflict (migration_key) do update
  set status = excluded.status,
      metrics = excluded.metrics,
      reconciled_at = statement_timestamp();
end;
$$;

comment on function app.prepare_parent_otp_delivery_v1(
  text, text, timestamptz
) is
  'Creates an OTP only when immutable published mail-v2 template and branding snapshots are available.';
comment on function app.complete_parent_otp_delivery_v1(
  uuid, text, text, text
) is
  'Records one immutable, idempotent and non-PII delivery outcome.';
comment on function app.authorize_parent_otp_delivery_v1(uuid) is
  'Revalidates cutover, mail gate, access and live challenge immediately before provider delivery.';
comment on function app.record_parent_otp_sendgrid_events_v1(jsonb)
is
  'Records signed provider events against explicit OTP attempt identities.';

notify pgrst, 'reload schema';
