-- Administrator-only mail-v2 test delivery.
--
-- Test messages never create member domain events, reminder runs or email jobs.
-- The application supplies the fixed environment recipient only to SendGrid; it
-- is deliberately absent from this append-only ledger and from the audit log.

create table private.mail_test_deliveries (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  template_key text not null
    references app.mail_templates(template_key) on delete restrict,
  template_revision_id uuid not null
    references app.mail_template_revisions(id) on delete restrict,
  template_content_hash text not null check (
    template_content_hash ~ '^[0-9a-f]{64}$'
  ),
  branding_revision_id uuid not null
    references app.mail_branding_revisions(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp()
);

create table private.mail_test_delivery_outcomes (
  delivery_id uuid primary key
    references private.mail_test_deliveries(id) on delete restrict,
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
  finalized_by uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  created_at timestamptz not null default statement_timestamp()
);

alter table private.mail_test_deliveries enable row level security;
alter table private.mail_test_delivery_outcomes enable row level security;

revoke all on
  private.mail_test_deliveries,
  private.mail_test_delivery_outcomes
from public, anon, authenticated, service_role;

create or replace function private.reject_mail_test_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  raise exception 'MAIL_TEST_DELIVERY_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger mail_test_deliveries_immutable
before update or delete on private.mail_test_deliveries
for each row execute function private.reject_mail_test_ledger_mutation();

create trigger mail_test_delivery_outcomes_immutable
before update or delete on private.mail_test_delivery_outcomes
for each row execute function private.reject_mail_test_ledger_mutation();

revoke all on function private.reject_mail_test_ledger_mutation()
from public, anon, authenticated, service_role;

create or replace function app.prepare_mail_test_delivery_v1(
  p_request_id uuid,
  p_template_key text,
  p_expected_content_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target private.mail_test_deliveries%rowtype;
  target_outcome text;
  template app.mail_template_revisions%rowtype;
  branding app.mail_branding_revisions%rowtype;
begin
  if p_request_id is null
    or p_template_key is null
    or p_expected_content_hash !~ '^[0-9a-f]{64}$'
  then
    raise exception 'MAIL_TEST_DELIVERY_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('mail-test-delivery:' || p_request_id::text, 0)
  );

  select delivery.* into target
  from private.mail_test_deliveries delivery
  where delivery.request_id = p_request_id;

  if found then
    select outcome.outcome into target_outcome
    from private.mail_test_delivery_outcomes outcome
    where outcome.delivery_id = target.id;
    if target.template_key <> p_template_key
      or target.template_content_hash <> p_expected_content_hash
    then
      raise exception 'MAIL_TEST_REQUEST_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'deliveryId', target.id,
      'status', coalesce(target_outcome, 'prepared'),
      'reused', true
    );
  end if;

  select revision.* into template
  from app.mail_template_revisions revision
  where revision.template_key = p_template_key
    and revision.status = 'published';
  if not found then
    raise exception 'MAIL_TEST_TEMPLATE_NOT_PUBLISHED' using errcode = '23514';
  end if;
  if template.content_hash <> p_expected_content_hash then
    raise exception 'MAIL_TEST_TEMPLATE_STALE' using errcode = '40001';
  end if;

  select revision.* into branding
  from app.mail_branding_revisions revision
  where revision.status = 'published';
  if not found or not branding.contrast_validated then
    raise exception 'MAIL_TEST_BRANDING_UNAVAILABLE' using errcode = '23514';
  end if;

  insert into private.mail_test_deliveries(
    request_id,
    actor_user_id,
    template_key,
    template_revision_id,
    template_content_hash,
    branding_revision_id
  ) values (
    p_request_id,
    actor,
    template.template_key,
    template.id,
    template.content_hash,
    branding.id
  )
  returning * into target;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'email.test_delivery.prepared',
    'mail_test_delivery',
    target.id,
    jsonb_build_object(
      'templateKey', template.template_key,
      'templateRevision', template.revision,
      'brandingRevision', branding.revision
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'deliveryId', target.id,
    'status', 'prepared',
    'reused', false,
    'template', jsonb_build_object(
      'id', template.id,
      'contentHash', template.content_hash,
      'source', jsonb_build_object(
        'templateKey', template.template_key,
        'subjectSource', template.subject_source,
        'preheaderSource', template.preheader_source,
        'bodyTipTap', template.body_tiptap,
        'allowedShortcodes', (
          select catalog.allowed_shortcode_keys
          from app.mail_templates catalog
          where catalog.template_key = template.template_key
        ),
        'allowedProtectedNodes', (
          select catalog.allowed_protected_nodes
          from app.mail_templates catalog
          where catalog.template_key = template.template_key
        ),
        'requiredProtectedNodes', (
          select catalog.required_protected_nodes
          from app.mail_templates catalog
          where catalog.template_key = template.template_key
        )
      )
    ),
    'branding', jsonb_build_object(
      'id', branding.id,
      'contentHash', branding.content_hash,
      'values', jsonb_build_object(
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
        'contrastValidated', branding.contrast_validated
      )
    )
  );
end;
$$;

create or replace function app.finalize_mail_test_delivery_v1(
  p_delivery_id uuid,
  p_outcome text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target private.mail_test_deliveries%rowtype;
  existing_outcome text;
begin
  if p_delivery_id is null
    or p_outcome not in (
      'accepted',
      'provider_rejected',
      'delivery_uncertain',
      'configuration_error',
      'disabled',
      'render_failed'
    )
  then
    raise exception 'MAIL_TEST_OUTCOME_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('mail-test-finalize:' || p_delivery_id::text, 0)
  );
  select * into target
  from private.mail_test_deliveries delivery
  where delivery.id = p_delivery_id;
  if not found then
    raise exception 'MAIL_TEST_DELIVERY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.actor_user_id <> actor then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  select outcome.outcome into existing_outcome
  from private.mail_test_delivery_outcomes outcome
  where outcome.delivery_id = target.id;
  if found then
    if existing_outcome <> p_outcome then
      raise exception 'MAIL_TEST_OUTCOME_CONFLICT' using errcode = '40001';
    end if;
    return jsonb_build_object(
      'deliveryId', target.id,
      'status', existing_outcome,
      'reused', true
    );
  end if;

  insert into private.mail_test_delivery_outcomes(
    delivery_id,
    outcome,
    finalized_by
  ) values (
    target.id,
    p_outcome,
    actor
  );

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'email.test_delivery.finalized',
    'mail_test_delivery',
    target.id,
    jsonb_build_object(
      'templateKey', target.template_key,
      'outcome', p_outcome
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'deliveryId', target.id,
    'status', p_outcome,
    'reused', false
  );
end;
$$;

revoke all on function app.prepare_mail_test_delivery_v1(
  uuid, text, text, uuid
) from public, anon;
revoke all on function app.finalize_mail_test_delivery_v1(
  uuid, text, uuid
) from public, anon;
grant execute on function app.prepare_mail_test_delivery_v1(
  uuid, text, text, uuid
) to authenticated;
grant execute on function app.finalize_mail_test_delivery_v1(
  uuid, text, uuid
) to authenticated;

comment on table private.mail_test_deliveries is
'Append-only testmail intent without recipient, rendered body or provider metadata.';
comment on table private.mail_test_delivery_outcomes is
'Single terminal testmail outcome; delivery_uncertain is never automatically retried.';
comment on function app.prepare_mail_test_delivery_v1(
  uuid, text, text, uuid
) is
'Creates one administrator/AAL2 testmail intent and returns immutable published snapshots once.';
comment on function app.finalize_mail_test_delivery_v1(
  uuid, text, uuid
) is
'Finalizes one testmail intent idempotently without creating a member mail job.';

notify pgrst, 'reload schema';
