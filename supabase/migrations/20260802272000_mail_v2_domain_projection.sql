-- Generic mail-v2 projection, immutable job snapshots and send-time
-- authorization. Fulfilment keeps its specialised event ledger; every other
-- durable mail-v2 process uses this shared default-deny projection.

alter table private.email_jobs
  drop constraint email_jobs_context_kind_check,
  drop constraint email_jobs_context_check,
  drop constraint email_jobs_durable_snapshot_check;

alter table private.email_jobs
  add constraint email_jobs_context_kind_check check (
    context_kind in ('order', 'portal_access', 'fulfilment', 'mail_v2')
  ),
  add constraint email_jobs_context_check check (
    (
      context_kind = 'order'
      and order_id is not null
      and parent_account_id is null
      and parent_access_batch_id is null
      and template_key <> 'portal_access_invite'
      and season_id is null
      and mail_template_revision_id is null
      and mail_branding_revision_id is null
      and rendered_subject_snapshot is null
      and rendered_preheader_snapshot is null
      and rendered_html_snapshot is null
      and rendered_text_snapshot is null
      and from_name_snapshot is null
      and from_email_snapshot is null
      and reply_to_email_snapshot is null
      and render_hash is null
    )
    or (
      context_kind = 'portal_access'
      and order_id is null
      and parent_account_id is not null
      and parent_access_batch_id is not null
      and template_key = 'portal_access_invite'
      and kind = 'transactional'
      and batch_id is null
      and season_id is null
      and mail_template_revision_id is null
      and mail_branding_revision_id is null
      and rendered_subject_snapshot is null
      and rendered_preheader_snapshot is null
      and rendered_html_snapshot is null
      and rendered_text_snapshot is null
      and from_name_snapshot is null
      and from_email_snapshot is null
      and reply_to_email_snapshot is null
      and render_hash is null
    )
    or (
      context_kind = 'fulfilment'
      and order_id is null
      and parent_account_id is not null
      and parent_access_batch_id is null
      and template_key in ('partial_pickup', 'package_complete')
      and kind = 'transactional'
      and batch_id is null
      and season_id is not null
      and template_id is null
      and template_version is null
      and subject_source_snapshot is null
      and body_source_snapshot is null
      and allowed_shortcodes_snapshot is null
      and mail_template_revision_id is not null
      and mail_branding_revision_id is not null
      and rendered_subject_snapshot is not null
      and rendered_preheader_snapshot is not null
      and rendered_html_snapshot is not null
      and rendered_text_snapshot is not null
      and from_name_snapshot is not null
      and from_email_snapshot is not null
      and reply_to_email_snapshot is not null
      and render_hash is not null
    )
    or (
      context_kind = 'mail_v2'
      and order_id is null
      and parent_access_batch_id is null
      and template_key not in (
        'login_otp',
        'partial_pickup',
        'package_complete'
      )
      and (
        (
          template_key = 'internal_email_failure'
          and parent_account_id is null
        )
        or (
          template_key <> 'internal_email_failure'
          and parent_account_id is not null
        )
      )
      and kind in ('transactional', 'bulk')
      and batch_id is null
      and season_id is not null
      and template_id is null
      and template_version is null
      and subject_source_snapshot is null
      and body_source_snapshot is null
      and allowed_shortcodes_snapshot is null
      and mail_template_revision_id is not null
      and mail_branding_revision_id is not null
      and rendered_subject_snapshot is not null
      and rendered_preheader_snapshot is not null
      and rendered_html_snapshot is not null
      and rendered_text_snapshot is not null
      and from_name_snapshot is not null
      and from_email_snapshot is not null
      and reply_to_email_snapshot is not null
      and render_hash is not null
    )
  ) not valid,
  add constraint email_jobs_durable_snapshot_check check (
    (
      context_kind in ('order', 'portal_access')
      and template_id is not null
      and template_version is not null
      and template_version > 0
      and subject_source_snapshot is not null
      and body_source_snapshot is not null
      and allowed_shortcodes_snapshot is not null
    )
    or (
      context_kind in ('fulfilment', 'mail_v2')
      and template_id is null
      and template_version is null
      and subject_source_snapshot is null
      and body_source_snapshot is null
      and allowed_shortcodes_snapshot is null
      and mail_template_revision_id is not null
      and mail_branding_revision_id is not null
      and render_hash is not null
    )
  ) not valid;

alter table private.email_jobs
  validate constraint email_jobs_context_check,
  validate constraint email_jobs_durable_snapshot_check;

create table private.mail_v2_projection_batches (
  id uuid primary key default gen_random_uuid(),
  parent_account_id uuid
    references private.parent_accounts(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  template_key text not null
    references app.mail_templates(template_key) on delete restrict,
  cohort_id uuid,
  template_revision_id uuid not null
    references app.mail_template_revisions(id) on delete restrict,
  branding_revision_id uuid not null
    references app.mail_branding_revisions(id) on delete restrict,
  status text not null default 'leased' check (
    status in ('leased', 'queued', 'suppressed')
  ),
  lease_token uuid,
  lease_expires_at timestamptz,
  email_job_id uuid unique
    references private.email_jobs(id) on delete restrict,
  suppression_reason text check (
    suppression_reason is null or suppression_reason in (
      'eligibility_inactive',
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid',
      'retry_exhausted'
    )
  ),
  retry_count integer not null default 0 check (retry_count between 0 and 10),
  event_count integer not null check (event_count between 0 and 100),
  eligible_event_count integer check (
    eligible_event_count is null
    or eligible_event_count between 1 and event_count
  ),
  eligibility_revision text check (
    eligibility_revision is null
    or eligibility_revision ~ '^[0-9a-f]{64}$'
  ),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint mail_v2_projection_batches_recipient_check check (
    (
      template_key = 'internal_email_failure'
      and parent_account_id is null
    )
    or (
      template_key <> 'internal_email_failure'
      and parent_account_id is not null
    )
  ),
  constraint mail_v2_projection_batches_state_check check (
    (
      status = 'leased'
      and lease_token is not null
      and lease_expires_at is not null
      and email_job_id is null
      and suppression_reason is null
      and eligible_event_count is null
      and eligibility_revision is null
    )
    or (
      status = 'queued'
      and lease_token is null
      and lease_expires_at is null
      and email_job_id is not null
      and suppression_reason is null
      and eligible_event_count is not null
      and eligibility_revision is not null
    )
    or (
      status = 'suppressed'
      and lease_token is null
      and lease_expires_at is null
      and email_job_id is null
      and suppression_reason is not null
      and eligible_event_count is null
      and eligibility_revision is null
    )
  )
);

create table private.mail_v2_projections (
  event_id uuid primary key
    references private.mail_v2_domain_events(id) on delete restrict,
  projection_batch_id uuid not null
    references private.mail_v2_projection_batches(id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now())
);

create table private.mail_v2_event_suppressions (
  event_id uuid primary key
    references private.mail_v2_domain_events(id) on delete restrict,
  reason text not null check (
    reason in (
      'eligibility_inactive',
      'superseded_by_back_in_stock',
      'retry_exhausted'
    )
  ),
  superseding_event_id uuid
    references private.mail_v2_domain_events(id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now()),
  constraint mail_v2_event_suppressions_binding_check check (
    (
      reason = 'superseded_by_back_in_stock'
      and superseding_event_id is not null
      and superseding_event_id <> event_id
    )
    or (
      reason <> 'superseded_by_back_in_stock'
      and superseding_event_id is null
    )
  )
);

create index mail_v2_projection_batches_lease_idx
  on private.mail_v2_projection_batches(lease_expires_at, created_at)
  where status = 'leased';
create index mail_v2_projection_batches_parent_idx
  on private.mail_v2_projection_batches(
    parent_account_id,
    season_id,
    created_at desc
  );
create index mail_v2_projections_batch_idx
  on private.mail_v2_projections(projection_batch_id, created_at);
create index mail_v2_event_suppressions_created_idx
  on private.mail_v2_event_suppressions(created_at, event_id);

alter table private.mail_v2_projection_batches enable row level security;
alter table private.mail_v2_projections enable row level security;
alter table private.mail_v2_event_suppressions enable row level security;
revoke all on
  private.mail_v2_projection_batches,
  private.mail_v2_projections,
  private.mail_v2_event_suppressions
from public, anon, authenticated, service_role;

create or replace function private.guard_mail_v2_projection_batch()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if current_setting('app.mail_v2_projection_internal', true) <> 'on' then
    raise exception 'MAIL_V2_PROJECTION_MUTATION_DENIED'
      using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    if old.event_count <> 0 then
      raise exception 'MAIL_V2_PROJECTION_DELETE_DENIED'
        using errcode = '55000';
    end if;
    return old;
  end if;
  if old.id is distinct from new.id
    or old.parent_account_id is distinct from new.parent_account_id
    or old.season_id is distinct from new.season_id
    or old.template_key is distinct from new.template_key
    or old.cohort_id is distinct from new.cohort_id
    or old.template_revision_id is distinct from new.template_revision_id
    or old.branding_revision_id is distinct from new.branding_revision_id
    or old.created_at is distinct from new.created_at
  then
    raise exception 'MAIL_V2_PROJECTION_BINDING_IMMUTABLE'
      using errcode = '55000';
  end if;
  if old.event_count is distinct from new.event_count
    and not (
      old.status = 'leased'
      and new.status = 'leased'
      and old.event_count = 0
      and new.event_count between 1 and 100
      and new.lease_token is not distinct from old.lease_token
    )
  then
    raise exception 'MAIL_V2_PROJECTION_EVENT_COUNT_IMMUTABLE'
      using errcode = '55000';
  end if;
  if old.retry_count is distinct from new.retry_count
    and not (
      old.status = 'queued'
      and new.status = 'leased'
      and new.retry_count = old.retry_count + 1
    )
  then
    raise exception 'MAIL_V2_PROJECTION_RETRY_INVALID'
      using errcode = '55000';
  end if;
  if (
    old.eligible_event_count is distinct from new.eligible_event_count
    or old.eligibility_revision is distinct from new.eligibility_revision
  ) and not (
    (
      old.status = 'leased'
      and new.status = 'queued'
      and new.eligible_event_count between 1 and new.event_count
      and new.eligibility_revision ~ '^[0-9a-f]{64}$'
    )
    or (
      old.status = 'queued'
      and new.status in ('leased', 'suppressed')
      and new.eligible_event_count is null
      and new.eligibility_revision is null
    )
  ) then
    raise exception 'MAIL_V2_PROJECTION_ELIGIBILITY_INVALID'
      using errcode = '55000';
  end if;
  if old.status = 'leased' and new.status = 'leased' then
    if old.lease_expires_at > timezone('utc', now())
      and new.lease_token is distinct from old.lease_token
    then
      raise exception 'MAIL_V2_PROJECTION_LEASE_ACTIVE'
        using errcode = '40001';
    end if;
    return new;
  end if;
  if old.status = 'leased' and new.status in ('queued', 'suppressed') then
    return new;
  end if;
  if old.status = 'queued'
    and new.status in ('leased', 'suppressed')
    and old.email_job_id is not null
    and new.email_job_id is null
  then
    return new;
  end if;
  raise exception 'MAIL_V2_PROJECTION_TRANSITION_INVALID'
    using errcode = '55000';
end;
$$;

create trigger mail_v2_projection_batches_guard
before update or delete on private.mail_v2_projection_batches
for each row execute function private.guard_mail_v2_projection_batch();

create or replace function private.reject_mail_v2_projection_mutation()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'MAIL_V2_PROJECTION_IMMUTABLE' using errcode = '55000';
end;
$$;

create trigger mail_v2_projections_immutable
before update or delete on private.mail_v2_projections
for each row execute function private.reject_mail_v2_projection_mutation();
create trigger mail_v2_event_suppressions_immutable
before update or delete on private.mail_v2_event_suppressions
for each row execute function private.reject_mail_v2_projection_mutation();

revoke all on function private.guard_mail_v2_projection_batch()
from public, anon, authenticated, service_role;
revoke all on function private.reject_mail_v2_projection_mutation()
from public, anon, authenticated, service_role;

create or replace function private.guard_email_job_snapshot()
returns trigger
language plpgsql
security definer
set search_path = private, app, pg_temp
as $$
declare
  target_template app.email_templates%rowtype;
  target_v2_template app.mail_template_revisions%rowtype;
  target_branding app.mail_branding_revisions%rowtype;
  expected_recipient text;
begin
  if tg_op = 'INSERT'
    and new.context_kind in ('fulfilment', 'mail_v2')
  then
    if current_setting('app.mail_projection_internal', true) <> 'on'
      and current_setting('app.mail_v2_projection_internal', true) <> 'on'
    then
      raise exception 'MAIL_V2_JOB_CONTEXT_REQUIRED' using errcode = '23514';
    end if;
    if new.template_id is not null
      or new.template_version is not null
      or new.mail_template_revision_id is null
      or new.mail_branding_revision_id is null
      or new.render_hash is null
    then
      raise exception 'MAIL_V2_JOB_CONTEXT_REQUIRED' using errcode = '23514';
    end if;
    select * into target_v2_template
    from app.mail_template_revisions revision
    where revision.id = new.mail_template_revision_id
      and revision.status in ('published', 'archived');
    select * into target_branding
    from app.mail_branding_revisions branding
    where branding.id = new.mail_branding_revision_id
      and branding.status in ('published', 'archived')
      and branding.contrast_validated;
    if target_v2_template.id is null
      or target_branding.id is null
      or target_v2_template.template_key <> new.template_key
      or new.from_name_snapshot <> target_branding.from_name
      or new.from_email_snapshot <> target_branding.from_email
      or new.reply_to_email_snapshot <> target_branding.reply_to_email
    then
      raise exception 'MAIL_V2_JOB_SNAPSHOT_INVALID' using errcode = '23514';
    end if;
    if new.context_kind = 'fulfilment' then
      select account.email_normalized into expected_recipient
      from private.parent_accounts account
      where account.id = new.parent_account_id;
    elsif new.template_key = 'internal_email_failure' then
      expected_recipient := target_branding.contact_email;
    else
      select account.email_normalized into expected_recipient
      from private.parent_accounts account
      where account.id = new.parent_account_id;
    end if;
    if expected_recipient is null
      or new.recipient_email <> expected_recipient
    then
      raise exception 'MAIL_V2_JOB_RECIPIENT_INVALID' using errcode = '23514';
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.template_id is null
      or new.template_key = 'verification_code'
    then
      raise exception 'DURABLE_EMAIL_CONTEXT_REQUIRED' using errcode = '23514';
    end if;
    select * into target_template
    from app.email_templates template
    where template.id = new.template_id and template.active;
    if not found or target_template.template_key <> new.template_key then
      raise exception 'EMAIL_TEMPLATE_NOT_ACTIVE' using errcode = '23514';
    end if;
    if (
      new.context_kind = 'order'
      and (
        new.order_id is null
        or new.parent_account_id is not null
        or new.parent_access_batch_id is not null
        or new.template_key = 'portal_access_invite'
      )
    ) or (
      new.context_kind = 'portal_access'
      and (
        new.order_id is not null
        or new.parent_account_id is null
        or new.parent_access_batch_id is null
        or new.template_key <> 'portal_access_invite'
        or new.kind <> 'transactional'
        or new.batch_id is not null
        or new.recipient_email <> (
          select account.email_normalized
          from private.parent_accounts account
          where account.id = new.parent_account_id
        )
      )
    ) then
      raise exception 'EMAIL_TEMPLATE_CONTEXT_INVALID' using errcode = '23514';
    end if;
    new.template_version := target_template.version;
    new.subject_source_snapshot := target_template.subject_source;
    new.body_source_snapshot := target_template.body_source;
    new.allowed_shortcodes_snapshot := target_template.allowed_shortcodes;
    return new;
  end if;

  if new.context_kind is distinct from old.context_kind
    or new.kind is distinct from old.kind
    or new.order_id is distinct from old.order_id
    or new.parent_account_id is distinct from old.parent_account_id
    or new.parent_access_batch_id is distinct from old.parent_access_batch_id
    or new.batch_id is distinct from old.batch_id
    or new.template_id is distinct from old.template_id
    or new.template_key is distinct from old.template_key
    or new.recipient_email is distinct from old.recipient_email
    or new.payload is distinct from old.payload
    or new.idempotency_key is distinct from old.idempotency_key
    or new.template_version is distinct from old.template_version
    or new.subject_source_snapshot is distinct from old.subject_source_snapshot
    or new.body_source_snapshot is distinct from old.body_source_snapshot
    or new.allowed_shortcodes_snapshot is distinct from old.allowed_shortcodes_snapshot
    or new.season_id is distinct from old.season_id
    or new.mail_template_revision_id is distinct from old.mail_template_revision_id
    or new.mail_branding_revision_id is distinct from old.mail_branding_revision_id
    or new.rendered_subject_snapshot is distinct from old.rendered_subject_snapshot
    or new.rendered_preheader_snapshot is distinct from old.rendered_preheader_snapshot
    or new.rendered_html_snapshot is distinct from old.rendered_html_snapshot
    or new.rendered_text_snapshot is distinct from old.rendered_text_snapshot
    or new.from_name_snapshot is distinct from old.from_name_snapshot
    or new.from_email_snapshot is distinct from old.from_email_snapshot
    or new.reply_to_email_snapshot is distinct from old.reply_to_email_snapshot
    or new.render_hash is distinct from old.render_hash
  then
    raise exception 'EMAIL_JOB_SNAPSHOT_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_email_job_snapshot()
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_out_of_stock_sent(
  p_parent_account_id uuid,
  p_order_line_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from private.mail_v2_domain_events event
    join private.mail_v2_projections projection
      on projection.event_id = event.id
    join private.mail_v2_projection_batches batch
      on batch.id = projection.projection_batch_id
      and batch.status = 'queued'
    join private.email_jobs job
      on job.id = batch.email_job_id
      and job.status = 'sent'
      and coalesce(job.delivery_status, 'accepted')
        not in ('bounced', 'dropped', 'failed')
    where event.template_key = 'out_of_stock'
      and event.parent_account_id = p_parent_account_id
      and event.order_line_id = p_order_line_id
  );
$$;

create or replace function private.mail_v2_out_of_stock_in_flight(
  p_parent_account_id uuid,
  p_order_line_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from private.mail_v2_domain_events event
    join private.mail_v2_projections projection
      on projection.event_id = event.id
    join private.mail_v2_projection_batches batch
      on batch.id = projection.projection_batch_id
    left join private.email_jobs job
      on job.id = batch.email_job_id
    where event.template_key = 'out_of_stock'
      and event.parent_account_id = p_parent_account_id
      and event.order_line_id = p_order_line_id
      and (
        batch.status = 'leased'
        or (
          batch.status = 'queued'
          and job.status in ('queued', 'retry', 'processing')
        )
      )
  );
$$;

create or replace function private.mail_v2_pickup_ready_sent(
  p_parent_account_id uuid,
  p_order_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select exists(
    select 1
    from private.mail_v2_domain_events event
    join private.mail_v2_projections projection
      on projection.event_id = event.id
    join private.mail_v2_projection_batches batch
      on batch.id = projection.projection_batch_id
      and batch.status = 'queued'
    join private.email_jobs job
      on job.id = batch.email_job_id
      and job.status = 'sent'
      and coalesce(job.delivery_status, 'accepted')
        not in ('bounced', 'dropped', 'failed')
    where event.template_key in ('pickup_ready', 'back_in_stock')
      and event.parent_account_id = p_parent_account_id
      and event.order_id = p_order_id
  );
$$;

revoke all on function private.mail_v2_out_of_stock_sent(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_out_of_stock_in_flight(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function private.mail_v2_pickup_ready_sent(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_current_event_payload(
  p_event_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  current_payload jsonb;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if not found then
    return null;
  end if;
  if target.template_key = 'internal_email_failure' then
    return target.payload_snapshot;
  end if;
  current_payload := private.mail_v2_member_payload(
    target.template_key,
    target.parent_account_id,
    target.member_season_id,
    target.source_id,
    target.order_line_id
  );
  if not private.mail_v2_payload_keys_are_safe(current_payload) then
    raise exception 'MAIL_V2_CURRENT_PAYLOAD_INVALID' using errcode = '23514';
  end if;
  return current_payload;
end;
$$;

revoke all on function private.mail_v2_current_event_payload(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_event_state(
  p_event_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  paid boolean;
  has_reserved boolean;
  has_open_line boolean;
  queue_pending boolean;
  size_segment text;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if not found then
    return 'terminal';
  end if;

  if target.template_key = 'internal_email_failure' then
    if exists(
      select 1
      from private.email_jobs source_job
      where source_job.id = target.source_id
        and source_job.template_key <> 'internal_email_failure'
        and (
          source_job.status = 'failed'
          or source_job.delivery_status in ('bounced', 'dropped', 'failed')
        )
    ) then
      return 'eligible';
    end if;
    return 'terminal';
  end if;

  if not exists(
    select 1
    from app.member_seasons member_season
    join private.parent_portal_grants grant_row
      on grant_row.member_season_id = member_season.id
      and grant_row.parent_account_id = target.parent_account_id
      and grant_row.status = 'active'
    where member_season.id = target.member_season_id
      and member_season.season_id = target.season_id
      and member_season.participation_status = 'active'
  ) then
    return 'terminal';
  end if;

  if target.template_key = 'portal_access_invite' then
    if exists(
      select 1
      from private.parent_access_batch_items batch_item
      join private.parent_portal_grants grant_row
        on grant_row.id = batch_item.grant_id
        and grant_row.parent_account_id = target.parent_account_id
        and grant_row.status = 'active'
      where batch_item.batch_id = target.source_id
        and batch_item.member_season_id = target.member_season_id
        and batch_item.outcome = 'activated'
    ) then
      return 'eligible';
    end if;
    return 'terminal';
  end if;

  if target.template_key = 'portal_access_reminder' then
    if exists(
      select 1
      from private.parent_accounts account
      where account.id = target.parent_account_id
        and account.last_login_at is null
    ) then
      return 'eligible';
    end if;
    return 'terminal';
  end if;

  if target.order_id is null or not exists(
    select 1
    from app.member_orders orders
    where orders.id = target.order_id
      and orders.member_season_id = target.member_season_id
      and orders.season_id = target.season_id
      and orders.active_package_snapshot_id is not null
      and exists(
        select 1
        from app.order_lines line
        where line.order_id = orders.id
          and line.status <> 'cancelled'
      )
  ) then
    return 'terminal';
  end if;

  if target.template_key in (
    'size_fill_request',
    'size_fill_reminder',
    'size_review_request',
    'size_review_reminder'
  ) then
    size_segment := private.mail_v2_size_segment(target.order_id);
    if target.template_key in ('size_fill_request', 'size_fill_reminder') then
      return case when size_segment = 'fill' then 'eligible' else 'terminal' end;
    end if;
    return case when size_segment = 'review' then 'eligible' else 'terminal' end;
  end if;

  if target.template_key = 'size_confirmed' then
    if exists(
      select 1
      from app.package_size_confirmations confirmation
      join app.member_orders orders on orders.id = confirmation.order_id
      where confirmation.id = target.source_id
        and confirmation.member_season_id = target.member_season_id
        and confirmation.package_snapshot_id is not null
        and confirmation.package_snapshot_id =
          orders.active_package_snapshot_id
        and not exists(
          select 1
          from app.package_size_confirmation_items confirmation_item
          join app.order_package_snapshot_items snapshot_item
            on snapshot_item.id = confirmation_item.snapshot_item_id
          where confirmation_item.confirmation_id = confirmation.id
            and snapshot_item.snapshot_id <>
              confirmation.package_snapshot_id
        )
        and private.package_sizes_complete(
          orders.id,
          confirmation.package_snapshot_id
        )
    ) then
      return 'eligible';
    end if;
    return 'terminal';
  end if;

  select exists(
    select 1
    from app.payments payment
    where payment.order_id = target.order_id
      and payment.status = 'paid'
      and payment.reconciliation_issue is null
  ) into paid;

  if target.template_key in ('payment_request', 'payment_reminder') then
    return case when paid then 'terminal' else 'eligible' end;
  end if;

  select exists(
    select 1
    from app.inventory_allocations allocation
    where allocation.order_id = target.order_id
      and allocation.status = 'reserved'
      and (
        target.order_line_id is null
        or allocation.order_line_id = target.order_line_id
      )
  ) into has_reserved;
  select exists(
    select 1
    from app.order_lines line
    where line.order_id = target.order_id
      and line.status = 'backorder'
      and (
        target.order_line_id is null
        or line.id = target.order_line_id
      )
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      )
  ) into has_open_line;

  if target.template_key = 'payment_received_waiting_stock' then
    if not paid or has_reserved or not has_open_line then
      return 'terminal';
    end if;
    select exists(
      select 1
      from app.order_lines line
      join private.inventory_allocation_queue queue
        on queue.season_id = target.season_id
        and queue.article_variant_id = line.article_variant_id
        and queue.status in ('queued', 'processing')
      where line.order_id = target.order_id
        and line.status = 'backorder'
    ) into queue_pending;
    return case when queue_pending then 'pending' else 'eligible' end;
  end if;

  if target.template_key = 'available_payment_required' then
    if paid then
      return 'terminal';
    end if;
    if exists(
      select 1
      from app.order_lines line
      join lateral private.inventory_balance(
        target.season_id,
        line.article_variant_id
      ) balance on true
      where line.order_id = target.order_id
        and line.status = 'backorder'
        and line.article_variant_id is not null
        and balance.available > 0
        and not exists(
          select 1
          from app.inventory_allocations allocation
          where allocation.order_line_id = line.id
            and allocation.status in ('reserved', 'fulfilled')
        )
    ) then
      return 'eligible';
    end if;
    return 'terminal';
  end if;

  if target.template_key = 'out_of_stock' then
    if not paid or not has_open_line or target.order_line_id is null then
      return 'terminal';
    end if;
    if exists(
      select 1
      from app.order_lines line
      join lateral private.inventory_balance(
        target.season_id,
        line.article_variant_id
      ) balance on true
      where line.id = target.order_line_id
        and balance.available = 0
    ) then
      return 'eligible';
    end if;
    return 'terminal';
  end if;

  if target.template_key in (
    'pickup_ready',
    'pickup_reminder',
    'back_in_stock'
  ) then
    if not paid or not has_reserved then
      return 'terminal';
    end if;
    if target.template_key = 'pickup_ready'
      and target.order_line_id is not null
      and (
        private.mail_v2_out_of_stock_sent(
          target.parent_account_id,
          target.order_line_id
        )
        or private.mail_v2_out_of_stock_in_flight(
          target.parent_account_id,
          target.order_line_id
        )
      )
    then
      return 'pending';
    end if;
    if target.template_key = 'back_in_stock'
      and (
        target.order_line_id is null
        or not private.mail_v2_out_of_stock_sent(
          target.parent_account_id,
          target.order_line_id
        )
      )
    then
      return 'terminal';
    end if;
    if target.template_key = 'pickup_reminder'
      and not private.mail_v2_pickup_ready_sent(
        target.parent_account_id,
        target.order_id
      )
    then
      return 'terminal';
    end if;
    if private.order_qr_usable(target.order_id) then
      return 'eligible';
    end if;
    return 'pending';
  end if;

  return 'terminal';
end;
$$;

revoke all on function private.mail_v2_event_state(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_event_eligibility(
  p_event_id uuid
)
returns table(state text, revision_hash text)
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target private.mail_v2_domain_events%rowtype;
  state_value text;
  material text;
begin
  select * into target
  from private.mail_v2_domain_events event
  where event.id = p_event_id;
  if not found then
    return query select 'terminal'::text, encode(
      extensions.digest(convert_to('missing:' || p_event_id, 'UTF8'), 'sha256'),
      'hex'
    );
    return;
  end if;
  state_value := private.mail_v2_event_state(target.id);
  material := concat_ws(
    E'\n',
    target.id::text,
    state_value,
    coalesce(private.mail_v2_current_event_payload(target.id)::text, ''),
    coalesce((
      select concat_ws(
        ':',
        member_season.participation_status::text,
        member_season.updated_at::text
      )
      from app.member_seasons member_season
      where member_season.id = target.member_season_id
    ), ''),
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          grant_row.id::text,
          grant_row.status::text,
          grant_row.updated_at::text
        ),
        ',' order by grant_row.id
      )
      from private.parent_portal_grants grant_row
      where grant_row.member_season_id = target.member_season_id
        and grant_row.parent_account_id = target.parent_account_id
    ), ''),
    coalesce((
      select account.last_login_at::text
      from private.parent_accounts account
      where account.id = target.parent_account_id
    ), ''),
    coalesce((
      select concat_ws(
        ':',
        orders.order_status,
        orders.amount_due_cents::text,
        orders.active_package_snapshot_id::text,
        orders.updated_at::text
      )
      from app.member_orders orders
      where orders.id = target.order_id
    ), ''),
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          payment.id::text,
          payment.status::text,
          payment.reconciliation_issue,
          payment.updated_at::text
        ),
        ',' order by payment.id
      )
      from app.payments payment
      where payment.order_id = target.order_id
    ), ''),
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          line.id::text,
          line.status::text,
          line.updated_at::text
        ),
        ',' order by line.id
      )
      from app.order_lines line
      where line.order_id = target.order_id
    ), ''),
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          allocation.id::text,
          allocation.status::text,
          allocation.updated_at::text
        ),
        ',' order by allocation.id
      )
      from app.inventory_allocations allocation
      where allocation.order_id = target.order_id
    ), ''),
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          size_profile.article_id::text,
          size_profile.selection_status::text,
          size_profile.updated_at::text
        ),
        ',' order by size_profile.article_id
      )
      from app.member_article_sizes size_profile
      where size_profile.member_season_id = target.member_season_id
    ), ''),
    coalesce((
      select concat_ws(
        ':',
        identity.last_generation::text,
        identity.suspended_at::text,
        identity.updated_at::text
      )
      from private.qr_order_identities identity
      where identity.order_id = target.order_id
    ), '')
  );
  return query select state_value, encode(
    extensions.digest(convert_to(material, 'UTF8'), 'sha256'),
    'hex'
  );
end;
$$;

revoke all on function private.mail_v2_event_eligibility(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_projection_eligibility(
  p_projection_batch_id uuid
)
returns table(
  eligible_count integer,
  pending_count integer,
  terminal_count integer,
  revision_hash text
)
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  with states as (
    select event.id, eligibility.state, eligibility.revision_hash
    from private.mail_v2_projections projection
    join private.mail_v2_domain_events event
      on event.id = projection.event_id
    join lateral private.mail_v2_event_eligibility(event.id)
      eligibility on true
    where projection.projection_batch_id = p_projection_batch_id
  )
  select
    count(*) filter (where state = 'eligible')::integer,
    count(*) filter (where state = 'pending')::integer,
    count(*) filter (where state = 'terminal')::integer,
    encode(
      extensions.digest(
        convert_to(
          coalesce(string_agg(
            id::text || ':' || state || ':' || revision_hash,
            E'\n' order by id
          ), ''),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    )
  from states;
$$;

revoke all on function private.mail_v2_projection_eligibility(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_projection_group_json(
  p_projection_batch_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'groupId', batch.id,
    'templateKey', batch.template_key,
    'eligibilityRevision', (
      select eligibility.revision_hash
      from private.mail_v2_projection_eligibility(batch.id) eligibility
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
    ),
    'events', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'eventId', event.id,
          'payload', private.mail_v2_current_event_payload(event.id)
        )
        order by event.created_at, event.id
      )
      from private.mail_v2_projections projection
      join private.mail_v2_domain_events event
        on event.id = projection.event_id
      join lateral private.mail_v2_event_eligibility(event.id)
        eligibility on eligibility.state = 'eligible'
      where projection.projection_batch_id = batch.id
    ), '[]'::jsonb)
  )
  from private.mail_v2_projection_batches batch
  join app.mail_template_revisions template_revision
    on template_revision.id = batch.template_revision_id
  join app.mail_templates template
    on template.template_key = template_revision.template_key
  join app.mail_branding_revisions branding
    on branding.id = batch.branding_revision_id
  where batch.id = p_projection_batch_id;
$$;

revoke all on function private.mail_v2_projection_group_json(uuid)
from public, anon, authenticated, service_role;

create or replace function private.reconcile_mail_v2_event_supersessions()
returns integer
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
  back_event_id uuid;
  reconciled integer := 0;
begin
  for target in
    select event.*
    from private.mail_v2_domain_events event
    where event.template_key = 'pickup_ready'
      and event.order_line_id is not null
      and not exists(
        select 1
        from private.mail_v2_event_suppressions suppression
        where suppression.event_id = event.id
      )
      and private.mail_v2_out_of_stock_sent(
        event.parent_account_id,
        event.order_line_id
      )
    order by event.created_at, event.id
    limit 100
    for update skip locked
  loop
    back_event_id := private.enqueue_mail_v2_member_event(
      'back_in_stock',
      target.parent_account_id,
      target.member_season_id,
      'inventory_allocation_event',
      target.source_id,
      target.cohort_id,
      concat_ws(
        ':',
        'back-in-stock-v2',
        target.source_id,
        target.parent_account_id
      ),
      target.order_line_id
    );
    insert into private.mail_v2_event_suppressions(
      event_id,
      reason,
      superseding_event_id
    ) values (
      target.id,
      'superseded_by_back_in_stock',
      back_event_id
    ) on conflict (event_id) do nothing;
    reconciled := reconciled + 1;
  end loop;
  return reconciled;
end;
$$;

revoke all on function private.reconcile_mail_v2_event_supersessions()
from public, anon, authenticated, service_role;

create or replace function app.claim_mail_v2_domain_projections_v1(
  p_lease_token uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  safe_limit integer;
  claimed_count integer := 0;
  inserted_count integer;
  candidate record;
  new_batch_id uuid;
  selected_template_revision_id uuid;
  selected_branding_revision_id uuid;
  result jsonb;
begin
  if p_lease_token is null or p_limit is null or p_limit < 1 then
    raise exception 'MAIL_V2_DOMAIN_CLAIM_INVALID' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 10);
  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );
  if not private.mail_templates_v2_enabled() then
    return jsonb_build_object(
      'leaseToken', p_lease_token, 'groups', '[]'::jsonb
    );
  end if;

  perform private.reconcile_mail_v2_event_supersessions();

  insert into private.mail_v2_event_suppressions(event_id, reason)
  select event.id, 'eligibility_inactive'
  from private.mail_v2_domain_events event
  join lateral private.mail_v2_event_eligibility(event.id)
    eligibility on eligibility.state = 'terminal'
  where not exists(
      select 1
      from private.mail_v2_projections projection
      where projection.event_id = event.id
    )
    and not exists(
      select 1
      from private.mail_v2_event_suppressions suppression
      where suppression.event_id = event.id
    )
  order by event.created_at, event.id
  limit 250
  on conflict (event_id) do nothing;

  perform set_config('app.mail_v2_projection_internal', 'on', true);
  for candidate in
    select batch.id
    from private.mail_v2_projection_batches batch
    join lateral private.mail_v2_projection_eligibility(batch.id)
      eligibility on true
    where batch.status = 'leased'
      and batch.lease_expires_at <= timezone('utc', now())
      and eligibility.pending_count = 0
      and eligibility.eligible_count = 0
      and eligibility.terminal_count = batch.event_count
    order by batch.created_at, batch.id
    for update of batch skip locked
    limit 250
  loop
    insert into private.mail_v2_event_suppressions(event_id, reason)
    select projection.event_id, 'eligibility_inactive'
    from private.mail_v2_projections projection
    where projection.projection_batch_id = candidate.id
    on conflict (event_id) do nothing;
    update private.mail_v2_projection_batches
    set status = 'suppressed',
        lease_token = null,
        lease_expires_at = null,
        suppression_reason = 'eligibility_inactive',
        updated_at = timezone('utc', now())
    where id = candidate.id;
  end loop;

  with expired as (
    select batch.id
    from private.mail_v2_projection_batches batch
    join lateral private.mail_v2_projection_eligibility(batch.id)
      eligibility on true
    where batch.status = 'leased'
      and batch.lease_expires_at <= timezone('utc', now())
      and eligibility.pending_count = 0
      and eligibility.eligible_count > 0
    order by batch.created_at, batch.id
    for update skip locked
    limit safe_limit
  )
  update private.mail_v2_projection_batches batch
  set lease_token = p_lease_token,
      lease_expires_at = timezone('utc', now()) + interval '5 minutes',
      updated_at = timezone('utc', now())
  from expired
  where batch.id = expired.id;
  get diagnostics claimed_count = row_count;

  for candidate in
    select
      event.parent_account_id,
      event.season_id,
      event.template_key,
      event.cohort_id,
      min(event.created_at) first_created_at
    from private.mail_v2_domain_events event
    join lateral private.mail_v2_event_eligibility(event.id)
      eligibility on eligibility.state = 'eligible'
    where not exists(
        select 1
        from private.mail_v2_projections projection
        where projection.event_id = event.id
      )
      and not exists(
        select 1
        from private.mail_v2_event_suppressions suppression
        where suppression.event_id = event.id
      )
      and exists(
        select 1
        from app.mail_template_revisions revision
        where revision.template_key = event.template_key
          and revision.status = 'published'
      )
      and exists(
        select 1
        from app.mail_branding_revisions branding
        where branding.status = 'published'
          and branding.contrast_validated
      )
    group by
      event.parent_account_id,
      event.season_id,
      event.template_key,
      event.cohort_id
    order by first_created_at, event.parent_account_id
    limit greatest(safe_limit - claimed_count, 0)
  loop
    select revision.id into selected_template_revision_id
    from app.mail_template_revisions revision
    where revision.template_key = candidate.template_key
      and revision.status = 'published';
    select branding.id into selected_branding_revision_id
    from app.mail_branding_revisions branding
    where branding.status = 'published'
      and branding.contrast_validated;
    if selected_template_revision_id is null
      or selected_branding_revision_id is null
    then
      continue;
    end if;

    new_batch_id := gen_random_uuid();
    insert into private.mail_v2_projection_batches(
      id,
      parent_account_id,
      season_id,
      template_key,
      cohort_id,
      template_revision_id,
      branding_revision_id,
      status,
      lease_token,
      lease_expires_at,
      event_count
    ) values (
      new_batch_id,
      candidate.parent_account_id,
      candidate.season_id,
      candidate.template_key,
      candidate.cohort_id,
      selected_template_revision_id,
      selected_branding_revision_id,
      'leased',
      p_lease_token,
      timezone('utc', now()) + interval '5 minutes',
      0
    );

    with selected_events as (
      select event.id
      from private.mail_v2_domain_events event
      join lateral private.mail_v2_event_eligibility(event.id)
        eligibility on eligibility.state = 'eligible'
      where event.parent_account_id is not distinct from
          candidate.parent_account_id
        and event.season_id = candidate.season_id
        and event.template_key = candidate.template_key
        and event.cohort_id is not distinct from candidate.cohort_id
        and not exists(
          select 1
          from private.mail_v2_projections projection
          where projection.event_id = event.id
        )
        and not exists(
          select 1
          from private.mail_v2_event_suppressions suppression
          where suppression.event_id = event.id
        )
      order by event.created_at, event.id
      for update of event skip locked
      limit 100
    )
    insert into private.mail_v2_projections(
      event_id,
      projection_batch_id
    )
    select selected_event.id, new_batch_id
    from selected_events selected_event
    on conflict (event_id) do nothing;
    get diagnostics inserted_count = row_count;

    if inserted_count = 0 then
      delete from private.mail_v2_projection_batches batch
      where batch.id = new_batch_id;
    else
      update private.mail_v2_projection_batches
      set event_count = inserted_count
      where id = new_batch_id;
      claimed_count := claimed_count + 1;
    end if;
  end loop;

  for candidate in
    select batch.id
    from private.mail_v2_projection_batches batch
    join lateral private.mail_v2_projection_eligibility(batch.id)
      eligibility on true
    where batch.status = 'leased'
      and batch.lease_token = p_lease_token
      and eligibility.pending_count > 0
    order by batch.created_at, batch.id
    for update of batch
  loop
    update private.mail_v2_projection_batches
    set lease_expires_at = timezone('utc', now()) - interval '1 second',
        updated_at = timezone('utc', now())
    where id = candidate.id;
  end loop;

  for candidate in
    select batch.id
    from private.mail_v2_projection_batches batch
    join lateral private.mail_v2_projection_eligibility(batch.id)
      eligibility on true
    where batch.status = 'leased'
      and batch.lease_token = p_lease_token
      and eligibility.pending_count = 0
      and eligibility.eligible_count = 0
      and eligibility.terminal_count = batch.event_count
    order by batch.created_at, batch.id
    for update of batch
  loop
    insert into private.mail_v2_event_suppressions(event_id, reason)
    select projection.event_id, 'eligibility_inactive'
    from private.mail_v2_projections projection
    where projection.projection_batch_id = candidate.id
    on conflict (event_id) do nothing;
    update private.mail_v2_projection_batches
    set status = 'suppressed',
        lease_token = null,
        lease_expires_at = null,
        suppression_reason = 'eligibility_inactive',
        updated_at = timezone('utc', now())
    where id = candidate.id;
  end loop;
  perform set_config('app.mail_v2_projection_internal', 'off', true);

  select jsonb_build_object(
    'leaseToken',
    p_lease_token,
    'groups',
    coalesce(jsonb_agg(
      private.mail_v2_projection_group_json(batch.id)
      order by batch.created_at, batch.id
    ), '[]'::jsonb)
  ) into result
  from private.mail_v2_projection_batches batch
  join lateral private.mail_v2_projection_eligibility(batch.id)
    eligibility on eligibility.pending_count = 0
      and eligibility.eligible_count > 0
  where batch.status = 'leased'
    and batch.lease_token = p_lease_token;
  return result;
exception when others then
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.claim_mail_v2_domain_projections_v1(uuid, integer)
from public, anon, authenticated;
grant execute on function app.claim_mail_v2_domain_projections_v1(
  uuid, integer
) to service_role;

create or replace function private.open_mail_v2_projection_action(
  p_batch private.mail_v2_projection_batches,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
begin
  return private.open_action_item(
    'mail_projection_failed',
    p_batch.season_id,
    'mail_v2_projection_batch',
    p_batch.id,
    'mail_v2_projection',
    p_batch.id,
    encode(
      extensions.digest(
        convert_to('mail-v2-projection:' || p_batch.id::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    'warning',
    'admin_only',
    p_reason,
    jsonb_build_object(
      'batchId',
      p_batch.id,
      'templateKey',
      p_batch.template_key,
      'count',
      p_batch.event_count
    ),
    timezone('utc', now()) + interval '1 day'
  );
end;
$$;

revoke all on function private.open_mail_v2_projection_action(
  private.mail_v2_projection_batches,
  text
) from public, anon, authenticated, service_role;

create or replace function app.finalize_mail_v2_domain_projection_v1(
  p_projection_batch_id uuid,
  p_lease_token uuid,
  p_eligibility_revision text,
  p_subject text,
  p_preheader text,
  p_html text,
  p_text text,
  p_render_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_batch private.mail_v2_projection_batches%rowtype;
  target_template app.mail_template_revisions%rowtype;
  target_branding app.mail_branding_revisions%rowtype;
  projection_count integer;
  authorized_count integer;
  pending_count integer;
  terminal_count integer;
  current_eligibility_revision text;
  expected_hash text;
  recipient_email text;
  created_job_id uuid;
  job_kind text;
begin
  if p_projection_batch_id is null
    or p_lease_token is null
    or p_eligibility_revision !~ '^[0-9a-f]{64}$'
    or p_render_hash !~ '^[0-9a-f]{64}$'
    or length(p_subject) not between 1 and 200
    or p_subject ~ E'[\\r\\n]'
    or length(p_preheader) not between 1 and 240
    or p_preheader ~ E'[\\r\\n]'
    or not private.mail_v2_render_html_is_safe(p_html)
    or octet_length(p_text) not between 1 and 20000
  then
    raise exception 'MAIL_V2_DOMAIN_FINALIZE_INVALID'
      using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );
  select * into target_batch
  from private.mail_v2_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_V2_DOMAIN_PROJECTION_NOT_FOUND'
      using errcode = 'P0002';
  end if;
  if target_batch.status = 'queued' then
    if not exists(
      select 1
      from private.email_jobs job
      where job.id = target_batch.email_job_id
        and job.render_hash = p_render_hash
    ) then
      raise exception 'MAIL_V2_DOMAIN_FINALIZE_CONFLICT'
        using errcode = '40001';
    end if;
    return jsonb_build_object(
      'groupId', target_batch.id,
      'jobId', target_batch.email_job_id,
      'status', 'queued',
      'eventCount', target_batch.eligible_event_count,
      'reused', true
    );
  end if;
  if target_batch.status = 'suppressed' then
    return jsonb_build_object(
      'groupId', target_batch.id,
      'jobId', null,
      'status', 'suppressed',
      'eventCount', target_batch.event_count,
      'reused', true
    );
  end if;
  if not private.mail_templates_v2_enabled() then
    raise exception 'MAIL_V2_PROJECTION_PAUSED' using errcode = '55000';
  end if;
  if target_batch.lease_token is distinct from p_lease_token
    or target_batch.lease_expires_at <= timezone('utc', now())
  then
    raise exception 'MAIL_V2_DOMAIN_LEASE_CONFLICT' using errcode = '40001';
  end if;

  select count(*)::integer into projection_count
  from private.mail_v2_projections projection
  where projection.projection_batch_id = target_batch.id;
  select
    eligibility.eligible_count,
    eligibility.pending_count,
    eligibility.terminal_count,
    eligibility.revision_hash
  into
    authorized_count,
    pending_count,
    terminal_count,
    current_eligibility_revision
  from private.mail_v2_projection_eligibility(target_batch.id) eligibility;
  if projection_count = 0
    or projection_count <> target_batch.event_count
  then
    perform set_config('app.mail_v2_projection_internal', 'on', true);
    update private.mail_v2_projection_batches
    set status = 'suppressed',
        lease_token = null,
        lease_expires_at = null,
        suppression_reason = 'eligibility_inactive',
        eligible_event_count = null,
        eligibility_revision = null,
        updated_at = timezone('utc', now())
    where id = target_batch.id;
    insert into private.mail_v2_event_suppressions(event_id, reason)
    select projection.event_id, 'eligibility_inactive'
    from private.mail_v2_projections projection
    where projection.projection_batch_id = target_batch.id
    on conflict (event_id) do nothing;
    perform set_config('app.mail_v2_projection_internal', 'off', true);
    return jsonb_build_object(
      'groupId', target_batch.id,
      'jobId', null,
      'status', 'suppressed',
      'eventCount', target_batch.event_count,
      'reused', false
    );
  end if;
  if pending_count > 0 then
    perform set_config('app.mail_v2_projection_internal', 'on', true);
    update private.mail_v2_projection_batches
    set lease_expires_at = timezone('utc', now()) - interval '1 second',
        updated_at = timezone('utc', now())
    where id = target_batch.id;
    perform set_config('app.mail_v2_projection_internal', 'off', true);
    return jsonb_build_object(
      'groupId', target_batch.id,
      'jobId', null,
      'status', 'stale',
      'eventCount', authorized_count,
      'reused', false
    );
  end if;
  if authorized_count = 0 and terminal_count = target_batch.event_count then
    perform set_config('app.mail_v2_projection_internal', 'on', true);
    update private.mail_v2_projection_batches
    set status = 'suppressed',
        lease_token = null,
        lease_expires_at = null,
        suppression_reason = 'eligibility_inactive',
        eligible_event_count = null,
        eligibility_revision = null,
        updated_at = timezone('utc', now())
    where id = target_batch.id;
    insert into private.mail_v2_event_suppressions(event_id, reason)
    select projection.event_id, 'eligibility_inactive'
    from private.mail_v2_projections projection
    where projection.projection_batch_id = target_batch.id
    on conflict (event_id) do nothing;
    perform set_config('app.mail_v2_projection_internal', 'off', true);
    return jsonb_build_object(
      'groupId', target_batch.id,
      'jobId', null,
      'status', 'suppressed',
      'eventCount', target_batch.event_count,
      'reused', false
    );
  end if;
  if current_eligibility_revision <> p_eligibility_revision then
    perform set_config('app.mail_v2_projection_internal', 'on', true);
    update private.mail_v2_projection_batches
    set lease_expires_at = timezone('utc', now()) - interval '1 second',
        updated_at = timezone('utc', now())
    where id = target_batch.id;
    perform set_config('app.mail_v2_projection_internal', 'off', true);
    return jsonb_build_object(
      'groupId', target_batch.id,
      'jobId', null,
      'status', 'stale',
      'eventCount', authorized_count,
      'reused', false
    );
  end if;

  select * into target_template
  from app.mail_template_revisions revision
  where revision.id = target_batch.template_revision_id
    and revision.status in ('published', 'archived');
  if not found or target_template.template_key <> target_batch.template_key then
    raise exception 'MAIL_V2_DOMAIN_TEMPLATE_INVALID'
      using errcode = '23514';
  end if;
  select * into target_branding
  from app.mail_branding_revisions branding
  where branding.id = target_batch.branding_revision_id
    and branding.status in ('published', 'archived')
    and branding.contrast_validated;
  if not found then
    raise exception 'MAIL_V2_DOMAIN_BRANDING_INVALID'
      using errcode = '23514';
  end if;
  if target_batch.template_key = 'internal_email_failure' then
    recipient_email := target_branding.contact_email;
  else
    select account.email_normalized into recipient_email
    from private.parent_accounts account
    where account.id = target_batch.parent_account_id;
  end if;
  if recipient_email is null
    or recipient_email !~ '^[^[:space:]@]+@[^[:space:]@]+$'
  then
    raise exception 'MAIL_V2_DOMAIN_RECIPIENT_INVALID'
      using errcode = '23514';
  end if;

  expected_hash := private.mail_v2_render_hash(
    target_batch.id,
    p_eligibility_revision,
    target_batch.template_revision_id,
    target_batch.branding_revision_id,
    p_subject,
    p_preheader,
    p_html,
    p_text
  );
  if expected_hash <> p_render_hash then
    raise exception 'MAIL_V2_DOMAIN_RENDER_HASH_MISMATCH'
      using errcode = '23514';
  end if;
  select case when exists(
    select 1
    from private.mail_v2_projections projection
    join private.mail_v2_domain_events event
      on event.id = projection.event_id
    where projection.projection_batch_id = target_batch.id
      and event.source_type in ('mail_campaign', 'mail_reminder_rule')
  ) then 'bulk' else 'transactional' end into job_kind;

  perform set_config('app.mail_v2_projection_internal', 'on', true);
  insert into private.email_jobs(
    context_kind,
    kind,
    recipient_email,
    template_key,
    payload,
    status,
    available_at,
    parent_account_id,
    season_id,
    idempotency_key,
    mail_template_revision_id,
    mail_branding_revision_id,
    rendered_subject_snapshot,
    rendered_preheader_snapshot,
    rendered_html_snapshot,
    rendered_text_snapshot,
    from_name_snapshot,
    from_email_snapshot,
    reply_to_email_snapshot,
    render_hash
  ) values (
    'mail_v2',
    job_kind,
    recipient_email,
    target_batch.template_key,
    jsonb_build_object(
      'schemaVersion', 1,
      'projectionBatchId', target_batch.id,
      'eventCount', authorized_count
    ),
    'queued',
    timezone('utc', now()),
    target_batch.parent_account_id,
    target_batch.season_id,
    concat_ws(
      ':',
      'mail-v2',
      'domain',
      target_batch.id,
      target_batch.retry_count
    ),
    target_batch.template_revision_id,
    target_batch.branding_revision_id,
    p_subject,
    p_preheader,
    p_html,
    p_text,
    target_branding.from_name,
    target_branding.from_email,
    target_branding.reply_to_email,
    p_render_hash
  )
  returning id into created_job_id;

  update private.mail_v2_projection_batches
  set status = 'queued',
      lease_token = null,
      lease_expires_at = null,
      email_job_id = created_job_id,
      eligible_event_count = authorized_count,
      eligibility_revision = p_eligibility_revision,
      updated_at = timezone('utc', now())
  where id = target_batch.id;
  perform set_config('app.mail_v2_projection_internal', 'off', true);

  insert into app.audit_logs(action, entity_type, entity_id, metadata)
  values (
    'mail_v2.domain.queued',
    'email_job',
    created_job_id,
    jsonb_build_object(
      'templateKey', target_batch.template_key,
      'templateRevisionId', target_batch.template_revision_id,
      'brandingRevisionId', target_batch.branding_revision_id,
      'projectionBatchId', target_batch.id,
      'eventCount', authorized_count,
      'renderHash', p_render_hash
    )
  );
  return jsonb_build_object(
    'groupId', target_batch.id,
    'jobId', created_job_id,
    'status', 'queued',
    'eventCount', authorized_count,
    'reused', false
  );
exception when others then
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.finalize_mail_v2_domain_projection_v1(
  uuid, uuid, text, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function app.finalize_mail_v2_domain_projection_v1(
  uuid, uuid, text, text, text, text, text, text
) to service_role;

create or replace function app.fail_mail_v2_domain_projection_v1(
  p_projection_batch_id uuid,
  p_lease_token uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_batch private.mail_v2_projection_batches%rowtype;
begin
  if p_projection_batch_id is null
    or p_lease_token is null
    or p_reason not in (
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid'
    )
  then
    raise exception 'MAIL_V2_DOMAIN_FAILURE_INVALID' using errcode = '22023';
  end if;
  select * into target_batch
  from private.mail_v2_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_V2_DOMAIN_PROJECTION_NOT_FOUND'
      using errcode = 'P0002';
  end if;
  if target_batch.status = 'suppressed' then
    return jsonb_build_object(
      'groupId', target_batch.id, 'status', 'suppressed', 'reused', true
    );
  end if;
  if target_batch.status <> 'leased'
    or target_batch.lease_token is distinct from p_lease_token
  then
    raise exception 'MAIL_V2_DOMAIN_LEASE_CONFLICT' using errcode = '40001';
  end if;
  perform set_config('app.mail_v2_projection_internal', 'on', true);
  update private.mail_v2_projection_batches
  set status = 'suppressed',
      lease_token = null,
      lease_expires_at = null,
      suppression_reason = p_reason,
      updated_at = timezone('utc', now())
  where id = target_batch.id;
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  perform private.open_mail_v2_projection_action(target_batch, p_reason);
  return jsonb_build_object(
    'groupId', target_batch.id, 'status', 'suppressed', 'reused', false
  );
exception when others then
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.fail_mail_v2_domain_projection_v1(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function app.fail_mail_v2_domain_projection_v1(
  uuid, uuid, text
) to service_role;

create or replace function app.authorize_claimed_email_job_v3(
  p_job_id uuid,
  p_claim_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_job private.email_jobs%rowtype;
  target_batch private.mail_v2_projection_batches%rowtype;
  projection_count integer;
  authorized_count integer;
  pending_count integer;
  terminal_count integer;
  current_eligibility_revision text;
begin
  if p_job_id is null or p_claim_token is null then
    return false;
  end if;
  select * into target_job
  from private.email_jobs job
  where job.id = p_job_id
    and job.status = 'processing'
    and job.claim_token = p_claim_token
  for update;
  if not found then
    return false;
  end if;
  if target_job.context_kind not in ('fulfilment', 'mail_v2') then
    return app.authorize_claimed_email_job_v2(p_job_id, p_claim_token);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );
  if not private.mail_templates_v2_enabled() then
    update private.email_jobs
    set status = 'queued',
        attempts = greatest(attempts - 1, 0),
        claim_token = null,
        claimed_at = null,
        last_error = 'mail_v2_paused',
        updated_at = timezone('utc', now())
    where id = target_job.id;
    return false;
  end if;
  if target_job.context_kind = 'fulfilment' then
    return app.authorize_claimed_email_job_v2(p_job_id, p_claim_token);
  end if;

  select * into target_batch
  from private.mail_v2_projection_batches batch
  where batch.email_job_id = target_job.id
    and batch.status = 'queued'
  for update;
  if not found then
    update private.email_jobs
    set status = 'failed',
        completed_at = timezone('utc', now()),
        last_error = 'eligibility_changed_before_send',
        updated_at = timezone('utc', now())
    where id = target_job.id;
    return false;
  end if;
  select count(*)::integer into projection_count
  from private.mail_v2_projections projection
  where projection.projection_batch_id = target_batch.id;
  select
    eligibility.eligible_count,
    eligibility.pending_count,
    eligibility.terminal_count,
    eligibility.revision_hash
  into
    authorized_count,
    pending_count,
    terminal_count,
    current_eligibility_revision
  from private.mail_v2_projection_eligibility(target_batch.id) eligibility;
  if projection_count = target_batch.event_count
    and pending_count = 0
    and authorized_count = target_batch.eligible_event_count
    and current_eligibility_revision = target_batch.eligibility_revision
    and authorized_count > 0
  then
    return true;
  end if;

  update private.email_jobs
  set status = 'failed',
      completed_at = timezone('utc', now()),
      last_error = 'eligibility_changed_before_send',
      updated_at = timezone('utc', now())
  where id = target_job.id;
  perform set_config('app.mail_v2_projection_internal', 'on', true);
  if projection_count = target_batch.event_count
    and (authorized_count > 0 or pending_count > 0)
    and target_batch.retry_count < 10
  then
    update private.mail_v2_projection_batches
    set status = 'leased',
        lease_token = gen_random_uuid(),
        lease_expires_at = timezone('utc', now()) - interval '1 second',
        email_job_id = null,
        suppression_reason = null,
        eligible_event_count = null,
        eligibility_revision = null,
        retry_count = retry_count + 1,
        updated_at = timezone('utc', now())
    where id = target_batch.id;
  else
    update private.mail_v2_projection_batches
    set status = 'suppressed',
        email_job_id = null,
        suppression_reason = case
          when target_batch.retry_count >= 10 then 'retry_exhausted'
          else 'eligibility_inactive'
        end,
        eligible_event_count = null,
        eligibility_revision = null,
        updated_at = timezone('utc', now())
    where id = target_batch.id;
    insert into private.mail_v2_event_suppressions(event_id, reason)
    select
      projection.event_id,
      case
        when target_batch.retry_count >= 10 then 'retry_exhausted'
        else 'eligibility_inactive'
      end
    from private.mail_v2_projections projection
    where projection.projection_batch_id = target_batch.id
    on conflict (event_id) do nothing;
  end if;
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  if target_batch.retry_count >= 10 then
    perform private.open_mail_v2_projection_action(
      target_batch,
      'retry_exhausted'
    );
  end if;
  return false;
exception when others then
  perform set_config('app.mail_v2_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.authorize_claimed_email_job_v3(uuid, uuid)
from public, anon, authenticated;
grant execute on function app.authorize_claimed_email_job_v3(uuid, uuid)
to service_role;

create or replace function app.get_email_worker_preflight_v1(
  p_from_name text,
  p_from_email text,
  p_reply_to_email text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  branding_match_count integer;
  sender_drift_count integer;
begin
  if length(btrim(coalesce(p_from_name, ''))) not between 3 and 120
    or p_from_name ~ E'[\\r\\n]'
    or p_from_email <> lower(btrim(p_from_email))
    or p_reply_to_email <> lower(btrim(p_reply_to_email))
    or p_from_email !~ '^[^[:space:]@]+@[^[:space:]@]+$'
    or p_reply_to_email !~ '^[^[:space:]@]+@[^[:space:]@]+$'
  then
    raise exception 'EMAIL_WORKER_PREFLIGHT_INVALID' using errcode = '22023';
  end if;
  select count(*)::integer into branding_match_count
  from app.mail_branding_revisions branding
  where branding.status = 'published'
    and branding.contrast_validated
    and branding.from_name = p_from_name
    and branding.from_email = p_from_email
    and branding.reply_to_email = p_reply_to_email;
  select count(*)::integer into sender_drift_count
  from private.email_jobs job
  where job.context_kind in ('fulfilment', 'mail_v2')
    and job.status in ('queued', 'retry')
    and (
      job.from_name_snapshot <> p_from_name
      or job.from_email_snapshot <> p_from_email
      or job.reply_to_email_snapshot <> p_reply_to_email
    );
  return jsonb_build_object(
    'ready',
    branding_match_count = 1 and sender_drift_count = 0,
    'brandingMatchCount',
    branding_match_count,
    'senderDriftCount',
    sender_drift_count
  );
end;
$$;

revoke all on function app.get_email_worker_preflight_v1(text, text, text)
from public, anon, authenticated;
grant execute on function app.get_email_worker_preflight_v1(text, text, text)
to service_role;

create or replace function app.claim_email_jobs_v3(
  p_claim_token uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  safe_limit integer;
begin
  if p_claim_token is null or p_limit is null or p_limit < 1 then
    raise exception 'INVALID_EMAIL_JOB_CLAIM' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 25);

  update private.email_jobs invite_job
  set status = 'failed',
      completed_at = timezone('utc', now()),
      last_error = 'access_inactive_before_send',
      updated_at = timezone('utc', now())
  where invite_job.context_kind = 'portal_access'
    and invite_job.status in ('queued', 'retry')
    and not exists(
      select 1
      from private.parent_access_batch_items batch_item
      join private.parent_portal_grants grant_row
        on grant_row.id = batch_item.grant_id
        and grant_row.parent_account_id = invite_job.parent_account_id
        and grant_row.status = 'active'
      join app.member_seasons member_season
        on member_season.id = grant_row.member_season_id
        and member_season.participation_status = 'active'
      where batch_item.batch_id = invite_job.parent_access_batch_id
        and batch_item.outcome = 'activated'
    );

  with candidates as (
    select job.id
    from private.email_jobs job
    where job.status in ('queued', 'retry')
      and job.attempts < 5
      and job.available_at <= timezone('utc', now())
      and (
        (
          job.context_kind = 'order'
          and job.template_version is not null
        )
        or (
          job.context_kind = 'portal_access'
          and job.template_version is not null
          and exists(
            select 1
            from private.parent_access_batch_items batch_item
            join private.parent_portal_grants grant_row
              on grant_row.id = batch_item.grant_id
              and grant_row.parent_account_id = job.parent_account_id
              and grant_row.status = 'active'
            join app.member_seasons member_season
              on member_season.id = grant_row.member_season_id
              and member_season.participation_status = 'active'
            where batch_item.batch_id = job.parent_access_batch_id
              and batch_item.outcome = 'activated'
          )
        )
        or (
          job.context_kind = 'fulfilment'
          and private.mail_templates_v2_enabled()
          and job.template_version is null
          and job.render_hash is not null
          and exists(
            select 1
            from private.fulfilment_mail_projection_batches batch
            where batch.email_job_id = job.id
              and batch.status = 'queued'
          )
        )
        or (
          job.context_kind = 'mail_v2'
          and private.mail_templates_v2_enabled()
          and job.template_version is null
          and job.render_hash is not null
          and exists(
            select 1
            from private.mail_v2_projection_batches batch
            where batch.email_job_id = job.id
              and batch.status = 'queued'
          )
        )
      )
    order by job.available_at, job.created_at
    for update skip locked
    limit safe_limit
  ),
  claimed as (
    update private.email_jobs job
    set status = 'processing',
        attempts = attempts + 1,
        claim_token = p_claim_token,
        claimed_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    from candidates
    where job.id = candidates.id
    returning job.*
  )
  select jsonb_build_object(
    'claimToken',
    p_claim_token,
    'jobs',
    coalesce(jsonb_agg(
      case
        when claimed.context_kind in ('fulfilment', 'mail_v2')
          then jsonb_build_object(
            'id', claimed.id,
            'kind', claimed.kind,
            'contextKind', claimed.context_kind,
            'recipientEmail', claimed.recipient_email,
            'templateKey', claimed.template_key,
            'templateRevisionId', claimed.mail_template_revision_id,
            'brandingRevisionId', claimed.mail_branding_revision_id,
            'subject', claimed.rendered_subject_snapshot,
            'preheader', claimed.rendered_preheader_snapshot,
            'html', claimed.rendered_html_snapshot,
            'text', claimed.rendered_text_snapshot,
            'fromName', claimed.from_name_snapshot,
            'fromEmail', claimed.from_email_snapshot,
            'replyToEmail', claimed.reply_to_email_snapshot,
            'renderHash', claimed.render_hash,
            'parentAccountId', claimed.parent_account_id,
            'seasonId', claimed.season_id,
            'eventCount', (claimed.payload->>'eventCount')::integer,
            'attempt', claimed.attempts
          )
        else jsonb_build_object(
          'id', claimed.id,
          'kind', claimed.kind,
          'contextKind', claimed.context_kind,
          'recipientEmail', claimed.recipient_email,
          'templateKey', claimed.template_key,
          'templateVersion', claimed.template_version,
          'subjectSource', claimed.subject_source_snapshot,
          'bodySource', claimed.body_source_snapshot,
          'allowedShortcodes', claimed.allowed_shortcodes_snapshot,
          'orderId', claimed.order_id,
          'parentAccountId', claimed.parent_account_id,
          'payload', claimed.payload,
          'attempt', claimed.attempts
        )
      end
      order by claimed.created_at
    ), '[]'::jsonb)
  ) into result
  from claimed;
  return result;
end;
$$;

revoke all on function app.claim_email_jobs_v3(uuid, integer)
from public, anon, authenticated;
grant execute on function app.claim_email_jobs_v3(uuid, integer)
to service_role;

comment on function app.claim_mail_v2_domain_projections_v1(uuid, integer)
is 'Leases current eligible parent- or internal-domain events in groups of ten.';
comment on function app.finalize_mail_v2_domain_projection_v1(
  uuid, uuid, text, text, text, text, text, text
) is 'Revalidates generic mail-v2 eligibility and stores one immutable rendered job.';
comment on function app.authorize_claimed_email_job_v3(uuid, uuid)
is 'Send-time authorization for legacy, fulfilment and generic mail-v2 jobs with pause barrier.';

notify pgrst, 'reload schema';
