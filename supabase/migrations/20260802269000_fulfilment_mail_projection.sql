-- Mail-v2 fulfilment projection.
--
-- The scanner commits a PII-free immutable domain event. A service worker then
-- leases groups per parent account, season and event type, renders the exact
-- published template outside PostgreSQL and atomically finalizes one immutable
-- e-mail job for all events in the group. Legacy workers keep using v2 claim
-- contracts and will never see these jobs.

alter table private.fulfilment_notification_events
  add column package_snapshot_id uuid;

alter table private.fulfilment_notification_events
  disable trigger fulfilment_notification_events_immutable;
update private.fulfilment_notification_events event
set package_snapshot_id = orders.active_package_snapshot_id
from app.member_orders orders
where orders.id = event.order_id
  and event.package_snapshot_id is null;
alter table private.fulfilment_notification_events
  enable trigger fulfilment_notification_events_immutable;

do $$
begin
  if exists(
    select 1
    from private.fulfilment_notification_events event
    where event.package_snapshot_id is null
  ) then
    raise exception 'FULFILMENT_MAIL_PACKAGE_SNAPSHOT_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;
end;
$$;

alter table private.fulfilment_notification_events
  alter column package_snapshot_id set not null,
  add constraint fulfilment_notification_events_package_snapshot_fkey
    foreign key (package_snapshot_id, order_id)
    references app.order_package_snapshots(id, order_id)
    on delete restrict;

create or replace function private.bind_fulfilment_mail_package_snapshot()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  active_snapshot_id uuid;
begin
  select orders.active_package_snapshot_id into active_snapshot_id
  from app.member_orders orders
  where orders.id = new.order_id
  for key share;
  if active_snapshot_id is null then
    raise exception 'FULFILMENT_MAIL_PACKAGE_SNAPSHOT_REQUIRED'
      using errcode = '23514';
  end if;
  if new.package_snapshot_id is not null
    and new.package_snapshot_id <> active_snapshot_id
  then
    raise exception 'FULFILMENT_MAIL_PACKAGE_SNAPSHOT_STALE'
      using errcode = '40001';
  end if;
  new.package_snapshot_id := active_snapshot_id;
  return new;
end;
$$;

create trigger fulfilment_notification_events_bind_package_snapshot
before insert on private.fulfilment_notification_events
for each row execute function
  private.bind_fulfilment_mail_package_snapshot();

revoke all on function private.bind_fulfilment_mail_package_snapshot()
from public, anon, authenticated, service_role;

alter table private.email_jobs
  add column season_id uuid references app.seasons(id) on delete restrict,
  add column mail_template_revision_id uuid
    references app.mail_template_revisions(id) on delete restrict,
  add column mail_branding_revision_id uuid
    references app.mail_branding_revisions(id) on delete restrict,
  add column rendered_subject_snapshot text,
  add column rendered_preheader_snapshot text,
  add column rendered_html_snapshot text,
  add column rendered_text_snapshot text,
  add column from_name_snapshot text,
  add column from_email_snapshot text,
  add column reply_to_email_snapshot text,
  add column render_hash text;

alter table private.email_jobs
  drop constraint email_jobs_context_kind_check,
  drop constraint email_jobs_context_check,
  drop constraint email_jobs_durable_snapshot_check;

alter table private.email_jobs
  add constraint email_jobs_context_kind_check check (
    context_kind in ('order', 'portal_access', 'fulfilment')
  ),
  add constraint email_jobs_render_hash_check check (
    render_hash is null or render_hash ~ '^[0-9a-f]{64}$'
  ),
  add constraint email_jobs_v2_render_limits_check check (
    rendered_subject_snapshot is null or (
      length(rendered_subject_snapshot) between 1 and 200
      and rendered_subject_snapshot !~ E'[\\r\\n]'
    )
  ) not valid,
  add constraint email_jobs_v2_preheader_limits_check check (
    rendered_preheader_snapshot is null or (
      length(rendered_preheader_snapshot) between 1 and 240
      and rendered_preheader_snapshot !~ E'[\\r\\n]'
    )
  ) not valid,
  add constraint email_jobs_v2_body_limits_check check (
    (
      rendered_html_snapshot is null
      and rendered_text_snapshot is null
    )
    or (
      rendered_html_snapshot is not null
      and rendered_text_snapshot is not null
      and octet_length(rendered_html_snapshot) between 1 and 50000
      and octet_length(rendered_text_snapshot) between 1 and 20000
    )
  ) not valid,
  add constraint email_jobs_v2_sender_check check (
    (
      from_name_snapshot is null
      and from_email_snapshot is null
      and reply_to_email_snapshot is null
    )
    or (
      length(from_name_snapshot) between 3 and 120
      and from_name_snapshot !~ E'[\\r\\n]'
      and from_email_snapshot = lower(btrim(from_email_snapshot))
      and reply_to_email_snapshot = lower(btrim(reply_to_email_snapshot))
      and from_email_snapshot ~ '^[^[:space:]@]+@[^[:space:]@]+$'
      and reply_to_email_snapshot ~ '^[^[:space:]@]+@[^[:space:]@]+$'
    )
  ) not valid,
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
      context_kind = 'fulfilment'
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
  validate constraint email_jobs_v2_render_limits_check,
  validate constraint email_jobs_v2_preheader_limits_check,
  validate constraint email_jobs_v2_body_limits_check,
  validate constraint email_jobs_v2_sender_check,
  validate constraint email_jobs_context_check,
  validate constraint email_jobs_durable_snapshot_check;

create index email_jobs_mail_v2_revision_idx
  on private.email_jobs(mail_template_revision_id, created_at desc)
  where mail_template_revision_id is not null;
create index email_jobs_fulfilment_parent_idx
  on private.email_jobs(parent_account_id, season_id, created_at desc)
  where context_kind = 'fulfilment';

create table private.fulfilment_mail_projection_batches (
  id uuid primary key default gen_random_uuid(),
  parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  event_type text not null check (
    event_type in ('partial_pickup', 'package_complete')
  ),
  template_revision_id uuid not null
    references app.mail_template_revisions(id) on delete restrict,
  branding_revision_id uuid not null
    references app.mail_branding_revisions(id) on delete restrict,
  status text not null default 'leased' check (
    status in ('leased', 'queued', 'suppressed')
  ),
  lease_token uuid,
  lease_expires_at timestamptz,
  email_job_id uuid unique references private.email_jobs(id) on delete restrict,
  suppression_reason text check (
    suppression_reason is null or suppression_reason in (
      'grant_inactive_before_enqueue',
      'grant_inactive_before_send',
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid'
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
  constraint fulfilment_mail_projection_batch_state_check check (
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

create table private.fulfilment_mail_projections (
  event_id uuid primary key
    references private.fulfilment_notification_events(id) on delete restrict,
  projection_batch_id uuid not null
    references private.fulfilment_mail_projection_batches(id)
    on delete restrict,
  created_at timestamptz not null default timezone('utc', now())
);

create table private.fulfilment_mail_supersessions (
  event_id uuid primary key
    references private.fulfilment_notification_events(id) on delete restrict,
  superseding_event_id uuid not null
    references private.fulfilment_notification_events(id) on delete restrict,
  projection_batch_id uuid not null
    references private.fulfilment_mail_projection_batches(id)
    on delete restrict,
  created_at timestamptz not null default timezone('utc', now()),
  constraint fulfilment_mail_supersessions_distinct_check check (
    event_id <> superseding_event_id
  )
);

create index fulfilment_mail_projection_batches_lease_idx
  on private.fulfilment_mail_projection_batches(
    lease_expires_at,
    created_at
  )
  where status = 'leased';
create index fulfilment_mail_projection_batches_parent_idx
  on private.fulfilment_mail_projection_batches(
    parent_account_id,
    season_id,
    created_at desc
  );
create index fulfilment_mail_projections_batch_idx
  on private.fulfilment_mail_projections(projection_batch_id, created_at);
create index fulfilment_mail_supersessions_batch_idx
  on private.fulfilment_mail_supersessions(
    projection_batch_id,
    created_at
  );
create index fulfilment_mail_supersessions_completion_idx
  on private.fulfilment_mail_supersessions(
    superseding_event_id,
    created_at
  );

alter table private.fulfilment_mail_projection_batches enable row level security;
alter table private.fulfilment_mail_projections enable row level security;
alter table private.fulfilment_mail_supersessions enable row level security;
revoke all on
  private.fulfilment_mail_projection_batches,
  private.fulfilment_mail_projections,
  private.fulfilment_mail_supersessions
from public, anon, authenticated, service_role;

create or replace function private.mail_v2_render_hash(
  p_projection_batch_id uuid,
  p_eligibility_revision text,
  p_template_revision_id uuid,
  p_branding_revision_id uuid,
  p_subject text,
  p_preheader text,
  p_html text,
  p_text text
)
returns text
language sql
immutable
set search_path = extensions, pg_catalog, pg_temp
as $$
  select encode(
    extensions.digest(
      convert_to(
        concat_ws(
          E'\n',
          p_projection_batch_id::text,
          p_eligibility_revision,
          p_template_revision_id::text,
          p_branding_revision_id::text,
          p_subject,
          p_preheader,
          p_html,
          p_text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

revoke all on function private.mail_v2_render_hash(
  uuid, text, uuid, uuid, text, text, text, text
) from public, anon, authenticated, service_role;

create or replace function private.mail_v2_render_html_is_safe(p_html text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_html is not null
    and octet_length(p_html) between 1 and 50000
    and p_html !~* '<[[:space:]]*(script|iframe|form|object|embed|style|link|meta|base|svg|math)([[:space:]>])'
    and p_html !~* '[[:space:]]on[a-z]+[[:space:]]*='
    and p_html !~* '(href|src)[[:space:]]*=[[:space:]]*[''"][[:space:]]*(javascript|vbscript|data)[[:space:]]*:';
$$;

revoke all on function private.mail_v2_render_html_is_safe(text)
from public, anon, authenticated, service_role;

create or replace function private.guard_fulfilment_mail_projection_batch()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if current_setting('app.mail_projection_internal', true) <> 'on' then
    raise exception 'MAIL_PROJECTION_MUTATION_DENIED' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    if old.event_count <> 0 then
      raise exception 'MAIL_PROJECTION_DELETE_DENIED' using errcode = '55000';
    end if;
    return old;
  end if;
  if old.id is distinct from new.id
    or old.parent_account_id is distinct from new.parent_account_id
    or old.season_id is distinct from new.season_id
    or old.event_type is distinct from new.event_type
    or old.template_revision_id is distinct from new.template_revision_id
    or old.branding_revision_id is distinct from new.branding_revision_id
    or old.created_at is distinct from new.created_at
  then
    raise exception 'MAIL_PROJECTION_BINDING_IMMUTABLE' using errcode = '55000';
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
    raise exception 'MAIL_PROJECTION_EVENT_COUNT_IMMUTABLE'
      using errcode = '55000';
  end if;
  if old.retry_count is distinct from new.retry_count
    and not (
      old.status in ('queued', 'suppressed')
      and new.status = 'leased'
      and new.retry_count = old.retry_count + 1
    )
  then
    raise exception 'MAIL_PROJECTION_RETRY_COUNT_INVALID'
      using errcode = '55000';
  end if;
  if (
    old.eligible_event_count is distinct from new.eligible_event_count
    or old.eligibility_revision is distinct from new.eligibility_revision
  ) and not (
    (
      old.status = 'leased'
      and new.status = 'queued'
      and old.eligible_event_count is null
      and old.eligibility_revision is null
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
    raise exception 'MAIL_PROJECTION_ELIGIBILITY_INVALID'
      using errcode = '55000';
  end if;
  if old.status = 'leased' and new.status = 'leased' then
    if old.lease_expires_at > timezone('utc', now())
      and new.lease_token is distinct from old.lease_token
    then
      raise exception 'MAIL_PROJECTION_LEASE_ACTIVE' using errcode = '40001';
    end if;
    return new;
  end if;
  if old.status = 'leased' and new.status in ('queued', 'suppressed') then
    return new;
  end if;
  if old.status = 'queued'
    and new.status = 'suppressed'
    and old.email_job_id is not null
    and new.email_job_id is null
  then
    return new;
  end if;
  if old.status = 'queued'
    and new.status = 'leased'
    and old.email_job_id is not null
    and new.email_job_id is null
    and new.suppression_reason is null
    and new.lease_token is not null
    and new.lease_expires_at is not null
    and new.retry_count = old.retry_count + 1
  then
    return new;
  end if;
  if old.status = 'suppressed'
    and new.status = 'leased'
    and old.email_job_id is null
    and new.email_job_id is null
    and new.suppression_reason is null
    and new.lease_token is not null
    and new.lease_expires_at is not null
  then
    return new;
  end if;
  raise exception 'MAIL_PROJECTION_TRANSITION_INVALID' using errcode = '55000';
end;
$$;

create trigger fulfilment_mail_projection_batches_guard
before update or delete on private.fulfilment_mail_projection_batches
for each row execute function private.guard_fulfilment_mail_projection_batch();

create or replace function private.reject_fulfilment_mail_projection_mutation()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  raise exception 'MAIL_PROJECTION_EVENT_IMMUTABLE' using errcode = '55000';
end;
$$;

create trigger fulfilment_mail_projections_immutable
before update or delete on private.fulfilment_mail_projections
for each row execute function
  private.reject_fulfilment_mail_projection_mutation();

create or replace function private.guard_fulfilment_mail_supersession()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'MAIL_SUPERSESSION_IMMUTABLE' using errcode = '55000';
  end if;
  if not exists(
    select 1
    from private.fulfilment_notification_events partial_event
    join private.fulfilment_notification_events complete_event
      on complete_event.id = new.superseding_event_id
      and complete_event.event_type = 'package_complete'
      and complete_event.order_id = partial_event.order_id
      and complete_event.season_id = partial_event.season_id
      and complete_event.created_at >= partial_event.created_at
    join private.fulfilment_mail_projections completion_projection
      on completion_projection.event_id = complete_event.id
      and completion_projection.projection_batch_id =
        new.projection_batch_id
    join private.fulfilment_mail_projection_batches batch
      on batch.id = completion_projection.projection_batch_id
      and batch.event_type = 'package_complete'
    where partial_event.id = new.event_id
      and partial_event.event_type = 'partial_pickup'
  ) then
    raise exception 'MAIL_SUPERSESSION_BINDING_INVALID'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger fulfilment_mail_supersessions_guard
before insert or update or delete on private.fulfilment_mail_supersessions
for each row execute function
  private.guard_fulfilment_mail_supersession();

revoke all on function private.guard_fulfilment_mail_projection_batch()
from public, anon, authenticated, service_role;
revoke all on function private.reject_fulfilment_mail_projection_mutation()
from public, anon, authenticated, service_role;
revoke all on function private.guard_fulfilment_mail_supersession()
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
begin
  if tg_op = 'INSERT' and new.context_kind = 'fulfilment' then
    if current_setting('app.mail_projection_internal', true) <> 'on'
      or new.template_id is not null
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
    if not found
      or target_v2_template.id is null
      or target_v2_template.template_key <> new.template_key
      or target_v2_template.template_key not in (
        'partial_pickup',
        'package_complete'
      )
      or new.from_name_snapshot <> target_branding.from_name
      or new.from_email_snapshot <> target_branding.from_email
      or new.reply_to_email_snapshot <> target_branding.reply_to_email
    then
      raise exception 'MAIL_V2_JOB_SNAPSHOT_INVALID' using errcode = '23514';
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

create or replace function private.fulfilment_mail_current_eligibility(
  p_projection_batch_id uuid
)
returns table(eligible_count integer, revision_hash text)
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  with eligible as (
    select event.id
    from private.fulfilment_mail_projection_batches batch
    join private.fulfilment_mail_projections projection
      on projection.projection_batch_id = batch.id
    join private.fulfilment_notification_events event
      on event.id = projection.event_id
      and event.season_id = batch.season_id
      and event.event_type = batch.event_type
    join app.member_seasons member_season
      on member_season.id = event.member_season_id
      and member_season.participation_status = 'active'
    join private.parent_portal_grants grant_row
      on grant_row.member_season_id = event.member_season_id
      and grant_row.parent_account_id = batch.parent_account_id
      and grant_row.status = 'active'
    where batch.id = p_projection_batch_id
  )
  select
    count(*)::integer,
    encode(
      extensions.digest(
        convert_to(
          coalesce(string_agg(id::text, E'\n' order by id), ''),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    )
  from eligible;
$$;

revoke all on function private.fulfilment_mail_current_eligibility(uuid)
from public, anon, authenticated, service_role;

create or replace function private.fulfilment_mail_projection_group_json(
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
    'eventType', batch.event_type,
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
    'eligibilityRevision',
    (
      select eligibility.revision_hash
      from private.fulfilment_mail_current_eligibility(batch.id) eligibility
    ),
    'events', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'eventId', latest.event_id,
          'memberFirstName', latest.member_first_name,
          'memberFullName', concat_ws(
            ' ',
            latest.member_first_name,
            latest.member_insertion,
            latest.member_last_name
          ),
          'teamName', coalesce(latest.team_name, 'Niet opgegeven'),
          'seasonName', latest.season_name,
          'packageName', latest.package_name,
          'issued',
          case
            when batch.event_type = 'partial_pickup' then coalesce((
              select jsonb_agg(
                issued_line.value
                order by prior_event.created_at,
                  prior_event.id,
                  issued_line.ordinality
              )
              from private.fulfilment_mail_projections prior_projection
              join private.fulfilment_notification_events prior_event
                on prior_event.id = prior_projection.event_id
                and prior_event.order_id = latest.order_id
                and prior_event.event_type = 'partial_pickup'
              cross join lateral jsonb_array_elements(
                prior_event.payload_snapshot->'issued'
              ) with ordinality issued_line(value, ordinality)
              where prior_projection.projection_batch_id = batch.id
            ), '[]'::jsonb)
            else latest.payload_snapshot->'issued'
          end,
          'remaining', latest.payload_snapshot->'remaining',
          'package', latest.payload_snapshot->'package'
        )
        order by latest.member_first_name, latest.member_id, latest.event_id
      )
      from (
        select distinct on (event.order_id)
          event.id event_id,
          event.order_id,
          event.payload_snapshot,
          member.id member_id,
          member.first_name member_first_name,
          member.insertion member_insertion,
          member.last_name member_last_name,
          member_season.team_name,
          season.name season_name,
          package_snapshot.package_name
        from private.fulfilment_mail_projections projection
        join private.fulfilment_notification_events event
          on event.id = projection.event_id
          and event.event_type = batch.event_type
        join app.member_seasons member_season
          on member_season.id = event.member_season_id
          and member_season.participation_status = 'active'
        join private.parent_portal_grants grant_row
          on grant_row.member_season_id = event.member_season_id
          and grant_row.parent_account_id = batch.parent_account_id
          and grant_row.status = 'active'
        join app.members member on member.id = member_season.member_id
        join app.seasons season on season.id = event.season_id
        join app.order_package_snapshots package_snapshot
          on package_snapshot.id = event.package_snapshot_id
          and package_snapshot.order_id = event.order_id
        where projection.projection_batch_id = batch.id
        order by event.order_id, event.created_at desc, event.id desc
      ) latest
    ), '[]'::jsonb)
  )
  from private.fulfilment_mail_projection_batches batch
  join app.mail_template_revisions template_revision
    on template_revision.id = batch.template_revision_id
  join app.mail_templates template
    on template.template_key = template_revision.template_key
  join app.mail_branding_revisions branding
    on branding.id = batch.branding_revision_id
  where batch.id = p_projection_batch_id;
$$;

revoke all on function private.fulfilment_mail_projection_group_json(uuid)
from public, anon, authenticated, service_role;

create or replace function app.claim_fulfilment_mail_projections_v1(
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
  cutover_at timestamptz;
  candidate record;
  new_batch_id uuid;
  selected_template_revision_id uuid;
  selected_branding_revision_id uuid;
  result jsonb;
begin
  if p_lease_token is null or p_limit is null or p_limit < 1 then
    raise exception 'MAIL_PROJECTION_CLAIM_INVALID' using errcode = '22023';
  end if;
  safe_limit := least(p_limit, 10);
  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );

  if not exists(
    select 1
    from app.release_feature_flags flag
    where flag.key = 'mail_templates_v2'
      and flag.enabled
  ) then
    return jsonb_build_object(
      'leaseToken',
      p_lease_token,
      'groups',
      '[]'::jsonb
    );
  end if;
  select cutover.activated_at into cutover_at
  from private.release_cutovers cutover
  where cutover.key = 'mail_templates_v2';
  if cutover_at is null then
    raise exception 'MAIL_V2_CUTOVER_REQUIRED' using errcode = '55000';
  end if;

  perform set_config('app.mail_projection_internal', 'on', true);
  with expired as (
    select batch.id
    from private.fulfilment_mail_projection_batches batch
    where batch.status = 'leased'
      and batch.lease_expires_at <= timezone('utc', now())
    order by batch.created_at, batch.id
    for update skip locked
    limit safe_limit
  )
  update private.fulfilment_mail_projection_batches batch
  set lease_token = p_lease_token,
      lease_expires_at = timezone('utc', now()) + interval '5 minutes',
      updated_at = timezone('utc', now())
  from expired
  where batch.id = expired.id;
  get diagnostics claimed_count = row_count;

  for candidate in
    select
      grant_row.parent_account_id,
      event.season_id,
      event.event_type,
      min(event.created_at) first_created_at
    from private.fulfilment_notification_events event
    join app.member_seasons member_season
      on member_season.id = event.member_season_id
      and member_season.participation_status = 'active'
    join private.parent_portal_grants grant_row
      on grant_row.member_season_id = event.member_season_id
      and grant_row.status = 'active'
      and grant_row.parent_account_id is not null
    where event.created_at >= cutover_at
      and not exists(
        select 1
        from private.fulfilment_mail_projections projection
        where projection.event_id = event.id
      )
      and not exists(
        select 1
        from private.fulfilment_mail_supersessions supersession
        where supersession.event_id = event.id
      )
      and (
        event.event_type <> 'partial_pickup'
        or not exists(
          select 1
          from private.fulfilment_notification_events complete_event
          where complete_event.order_id = event.order_id
            and complete_event.season_id = event.season_id
            and complete_event.event_type = 'package_complete'
            and complete_event.created_at >= event.created_at
        )
      )
      and exists(
        select 1
        from app.mail_template_revisions revision
        where revision.template_key = event.event_type
          and revision.status = 'published'
      )
      and exists(
        select 1
        from app.mail_branding_revisions branding
        where branding.status = 'published'
          and branding.contrast_validated
      )
    group by
      grant_row.parent_account_id,
      event.season_id,
      event.event_type
    order by first_created_at, grant_row.parent_account_id
    limit greatest(safe_limit - claimed_count, 0)
  loop
    select revision.id into selected_template_revision_id
    from app.mail_template_revisions revision
    where revision.template_key = candidate.event_type
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
    insert into private.fulfilment_mail_projection_batches(
      id,
      parent_account_id,
      season_id,
      event_type,
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
      candidate.event_type,
      selected_template_revision_id,
      selected_branding_revision_id,
      'leased',
      p_lease_token,
      timezone('utc', now()) + interval '5 minutes',
      0
    );

    with primary_events as (
      select event.id
      from private.fulfilment_notification_events event
      join app.member_seasons member_season
        on member_season.id = event.member_season_id
        and member_season.participation_status = 'active'
      join private.parent_portal_grants grant_row
        on grant_row.member_season_id = event.member_season_id
        and grant_row.status = 'active'
        and grant_row.parent_account_id = candidate.parent_account_id
      where event.season_id = candidate.season_id
        and event.event_type = candidate.event_type
        and event.created_at >= cutover_at
        and not exists(
          select 1
          from private.fulfilment_mail_projections projection
          where projection.event_id = event.id
        )
        and not exists(
          select 1
          from private.fulfilment_mail_supersessions supersession
          where supersession.event_id = event.id
        )
        and (
          event.event_type <> 'partial_pickup'
          or not exists(
            select 1
            from private.fulfilment_notification_events complete_event
            where complete_event.order_id = event.order_id
              and complete_event.season_id = event.season_id
              and complete_event.event_type = 'package_complete'
              and complete_event.created_at >= event.created_at
          )
        )
      order by event.created_at, event.id
      for update of event skip locked
      limit 10
    )
    insert into private.fulfilment_mail_projections(
      event_id,
      projection_batch_id
    )
    select primary_event.id, new_batch_id
    from primary_events primary_event
    on conflict (event_id) do nothing;
    get diagnostics inserted_count = row_count;

    if inserted_count = 0 then
      delete from private.fulfilment_mail_projection_batches batch
      where batch.id = new_batch_id;
    else
      insert into private.fulfilment_mail_supersessions(
        event_id,
        superseding_event_id,
        projection_batch_id
      )
      select
        partial_event.id,
        complete_event.id,
        new_batch_id
      from private.fulfilment_mail_projections completion_projection
      join private.fulfilment_notification_events complete_event
        on complete_event.id = completion_projection.event_id
        and complete_event.event_type = 'package_complete'
      join private.fulfilment_notification_events partial_event
        on partial_event.order_id = complete_event.order_id
        and partial_event.season_id = complete_event.season_id
        and partial_event.event_type = 'partial_pickup'
        and partial_event.created_at <= complete_event.created_at
      where completion_projection.projection_batch_id = new_batch_id
        and not exists(
          select 1
          from private.fulfilment_mail_projections projection
          where projection.event_id = partial_event.id
        )
        and not exists(
          select 1
          from private.fulfilment_mail_supersessions supersession
          where supersession.event_id = partial_event.id
        )
      on conflict (event_id) do nothing;

      update private.fulfilment_mail_projection_batches
      set event_count = inserted_count
      where id = new_batch_id;
      claimed_count := claimed_count + 1;
    end if;
  end loop;
  perform set_config('app.mail_projection_internal', 'off', true);

  select jsonb_build_object(
    'leaseToken',
    p_lease_token,
    'groups',
    coalesce(jsonb_agg(
      private.fulfilment_mail_projection_group_json(batch.id)
      order by batch.created_at, batch.id
    ), '[]'::jsonb)
  ) into result
  from private.fulfilment_mail_projection_batches batch
  where batch.status = 'leased'
    and batch.lease_token = p_lease_token;
  return result;
exception when others then
  perform set_config('app.mail_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.claim_fulfilment_mail_projections_v1(uuid, integer)
from public, anon, authenticated;
grant execute on function app.claim_fulfilment_mail_projections_v1(
  uuid, integer
) to service_role;

create or replace function private.open_mail_projection_action(
  p_batch private.fulfilment_mail_projection_batches,
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
    'mail_projection_batch',
    p_batch.id,
    'fulfilment_mail_projection',
    p_batch.id,
    encode(
      extensions.digest(
        'mail-projection:' || p_batch.id::text,
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
      'count',
      p_batch.event_count
    ),
    timezone('utc', now()) + interval '1 day'
  );
end;
$$;

revoke all on function private.open_mail_projection_action(
  private.fulfilment_mail_projection_batches,
  text
) from public, anon, authenticated, service_role;

create or replace function app.finalize_fulfilment_mail_projection_v1(
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
  target_batch private.fulfilment_mail_projection_batches%rowtype;
  target_template app.mail_template_revisions%rowtype;
  target_branding app.mail_branding_revisions%rowtype;
  target_account private.parent_accounts%rowtype;
  projection_count integer;
  authorized_count integer;
  current_eligibility_revision text;
  expected_hash text;
  created_job_id uuid;
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
    raise exception 'MAIL_PROJECTION_FINALIZE_INVALID'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );
  select * into target_batch
  from private.fulfilment_mail_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_PROJECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target_batch.status = 'queued' then
    if not exists(
      select 1
      from private.email_jobs job
      where job.id = target_batch.email_job_id
        and job.render_hash = p_render_hash
    ) then
      raise exception 'MAIL_PROJECTION_FINALIZE_CONFLICT'
        using errcode = '40001';
    end if;
    return jsonb_build_object(
      'groupId',
      target_batch.id,
      'jobId',
      target_batch.email_job_id,
      'status',
      'queued',
      'eventCount',
      target_batch.eligible_event_count,
      'reused',
      true
    );
  end if;
  if target_batch.status = 'suppressed' then
    return jsonb_build_object(
      'groupId',
      target_batch.id,
      'jobId',
      null,
      'status',
      'suppressed',
      'eventCount',
      target_batch.event_count,
      'reused',
      true
    );
  end if;
  if not exists(
    select 1
    from app.release_feature_flags flag
    join private.release_cutovers cutover
      on cutover.key = flag.key
    where flag.key = 'mail_templates_v2'
      and flag.enabled
  ) then
    raise exception 'MAIL_V2_PROJECTION_PAUSED' using errcode = '55000';
  end if;
  if target_batch.lease_token is distinct from p_lease_token
    or target_batch.lease_expires_at <= timezone('utc', now())
  then
    raise exception 'MAIL_PROJECTION_LEASE_CONFLICT' using errcode = '40001';
  end if;

  select count(*)::integer into projection_count
  from private.fulfilment_mail_projections projection
  where projection.projection_batch_id = target_batch.id;
  select eligibility.eligible_count, eligibility.revision_hash
  into authorized_count, current_eligibility_revision
  from private.fulfilment_mail_current_eligibility(target_batch.id) eligibility;
  if projection_count = 0
    or projection_count <> target_batch.event_count
    or authorized_count = 0
  then
    perform set_config('app.mail_projection_internal', 'on', true);
    update private.fulfilment_mail_projection_batches
    set status = 'suppressed',
        lease_token = null,
        lease_expires_at = null,
        suppression_reason = 'grant_inactive_before_enqueue',
        eligible_event_count = null,
        eligibility_revision = null,
        updated_at = timezone('utc', now())
    where id = target_batch.id;
    perform set_config('app.mail_projection_internal', 'off', true);
    perform private.open_mail_projection_action(
      target_batch,
      'grant_inactive_before_enqueue'
    );
    return jsonb_build_object(
      'groupId',
      target_batch.id,
      'jobId',
      null,
      'status',
      'suppressed',
      'eventCount',
      target_batch.event_count,
      'reused',
      false
    );
  end if;
  if current_eligibility_revision <> p_eligibility_revision then
    perform set_config('app.mail_projection_internal', 'on', true);
    update private.fulfilment_mail_projection_batches
    set lease_expires_at = timezone('utc', now()) - interval '1 second',
        updated_at = timezone('utc', now())
    where id = target_batch.id;
    perform set_config('app.mail_projection_internal', 'off', true);
    return jsonb_build_object(
      'groupId',
      target_batch.id,
      'jobId',
      null,
      'status',
      'stale',
      'eventCount',
      authorized_count,
      'reused',
      false
    );
  end if;

  select * into target_template
  from app.mail_template_revisions revision
  where revision.id = target_batch.template_revision_id
    and revision.status in ('published', 'archived');
  if not found or target_template.template_key <> target_batch.event_type then
    raise exception 'MAIL_PROJECTION_TEMPLATE_INVALID' using errcode = '23514';
  end if;
  select * into target_branding
  from app.mail_branding_revisions branding
  where branding.id = target_batch.branding_revision_id
    and branding.status in ('published', 'archived')
    and branding.contrast_validated;
  if not found then
    raise exception 'MAIL_PROJECTION_BRANDING_INVALID' using errcode = '23514';
  end if;
  select * into target_account
  from private.parent_accounts account
  where account.id = target_batch.parent_account_id;
  if not found
    or target_account.email_normalized !~ '^[^[:space:]@]+@[^[:space:]@]+$'
  then
    raise exception 'MAIL_PROJECTION_RECIPIENT_INVALID' using errcode = '23514';
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
    raise exception 'MAIL_PROJECTION_RENDER_HASH_MISMATCH'
      using errcode = '23514';
  end if;

  perform set_config('app.mail_projection_internal', 'on', true);
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
    'fulfilment',
    'transactional',
    target_account.email_normalized,
    target_batch.event_type,
    jsonb_build_object(
      'schemaVersion',
      1,
      'projectionBatchId',
      target_batch.id,
      'eventCount',
      authorized_count
    ),
    'queued',
    timezone('utc', now()),
    target_batch.parent_account_id,
    target_batch.season_id,
    concat_ws(
      ':',
      'mail-v2',
      'fulfilment',
      target_batch.id::text,
      target_batch.retry_count::text
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

  update private.fulfilment_mail_projection_batches
  set status = 'queued',
      lease_token = null,
      lease_expires_at = null,
      email_job_id = created_job_id,
      eligible_event_count = authorized_count,
      eligibility_revision = p_eligibility_revision,
      updated_at = timezone('utc', now())
  where id = target_batch.id;
  perform set_config('app.mail_projection_internal', 'off', true);

  insert into app.audit_logs(
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    'mail_v2.fulfilment.queued',
    'email_job',
    created_job_id,
    jsonb_build_object(
      'templateKey',
      target_batch.event_type,
      'templateRevisionId',
      target_batch.template_revision_id,
      'brandingRevisionId',
      target_batch.branding_revision_id,
      'projectionBatchId',
      target_batch.id,
      'eventCount',
      authorized_count,
      'renderHash',
      p_render_hash
    )
  );
  return jsonb_build_object(
    'groupId',
    target_batch.id,
    'jobId',
    created_job_id,
    'status',
    'queued',
    'eventCount',
    authorized_count,
    'reused',
    false
  );
exception when others then
  perform set_config('app.mail_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.finalize_fulfilment_mail_projection_v1(
  uuid, uuid, text, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function app.finalize_fulfilment_mail_projection_v1(
  uuid, uuid, text, text, text, text, text, text
) to service_role;

create or replace function app.fail_fulfilment_mail_projection_v1(
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
  target_batch private.fulfilment_mail_projection_batches%rowtype;
begin
  if p_projection_batch_id is null
    or p_lease_token is null
    or p_reason not in (
      'render_invalid',
      'projection_response_invalid',
      'projection_finalize_invalid'
    )
  then
    raise exception 'MAIL_PROJECTION_FAILURE_INVALID' using errcode = '22023';
  end if;
  select * into target_batch
  from private.fulfilment_mail_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_PROJECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target_batch.status = 'suppressed' then
    return jsonb_build_object(
      'groupId', target_batch.id, 'status', 'suppressed', 'reused', true
    );
  end if;
  if target_batch.status <> 'leased'
    or target_batch.lease_token is distinct from p_lease_token
  then
    raise exception 'MAIL_PROJECTION_LEASE_CONFLICT' using errcode = '40001';
  end if;
  perform set_config('app.mail_projection_internal', 'on', true);
  update private.fulfilment_mail_projection_batches
  set status = 'suppressed',
      lease_token = null,
      lease_expires_at = null,
      suppression_reason = p_reason,
      updated_at = timezone('utc', now())
  where id = target_batch.id;
  perform set_config('app.mail_projection_internal', 'off', true);
  perform private.open_mail_projection_action(target_batch, p_reason);
  return jsonb_build_object(
    'groupId', target_batch.id, 'status', 'suppressed', 'reused', false
  );
exception when others then
  perform set_config('app.mail_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.fail_fulfilment_mail_projection_v1(
  uuid, uuid, text
) from public, anon, authenticated;
grant execute on function app.fail_fulfilment_mail_projection_v1(
  uuid, uuid, text
) to service_role;

create or replace function app.retry_fulfilment_mail_projection_v1(
  p_projection_batch_id uuid,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target_batch private.fulfilment_mail_projection_batches%rowtype;
  projection_count integer;
  authorized_count integer;
  normalized_reason text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_projection_batch_id is null
    or length(normalized_reason) not between 4 and 500
    or normalized_reason ~ '[[:cntrl:]]'
  then
    raise exception 'MAIL_PROJECTION_RETRY_INVALID' using errcode = '22023';
  end if;
  select * into target_batch
  from private.fulfilment_mail_projection_batches batch
  where batch.id = p_projection_batch_id
  for update;
  if not found then
    raise exception 'MAIL_PROJECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target_batch.status = 'leased' and target_batch.retry_count > 0 then
    return jsonb_build_object(
      'batchId', target_batch.id,
      'status', target_batch.status,
      'retryCount', target_batch.retry_count,
      'reused', true
    );
  end if;
  if target_batch.status <> 'suppressed' then
    raise exception 'MAIL_PROJECTION_RETRY_STATE_CONFLICT'
      using errcode = '40001';
  end if;

  select count(*)::integer into projection_count
  from private.fulfilment_mail_projections projection
  where projection.projection_batch_id = target_batch.id;
  select count(*)::integer into authorized_count
  from private.fulfilment_mail_projections projection
  join private.fulfilment_notification_events event
    on event.id = projection.event_id
    and event.season_id = target_batch.season_id
    and event.event_type = target_batch.event_type
  join app.member_seasons member_season
    on member_season.id = event.member_season_id
    and member_season.participation_status = 'active'
  join private.parent_portal_grants grant_row
    on grant_row.member_season_id = event.member_season_id
    and grant_row.parent_account_id = target_batch.parent_account_id
    and grant_row.status = 'active'
  where projection.projection_batch_id = target_batch.id;
  if projection_count = 0
    or projection_count <> target_batch.event_count
    or authorized_count = 0
  then
    raise exception 'MAIL_PROJECTION_RETRY_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;

  perform set_config('app.mail_projection_internal', 'on', true);
  update private.fulfilment_mail_projection_batches
  set status = 'leased',
      lease_token = gen_random_uuid(),
      lease_expires_at = timezone('utc', now()) - interval '1 second',
      suppression_reason = null,
      retry_count = retry_count + 1,
      updated_at = timezone('utc', now())
  where id = target_batch.id
  returning * into target_batch;
  perform set_config('app.mail_projection_internal', 'off', true);

  update app.action_items
  set status = 'resolved',
      resolved_at = timezone('utc', now()),
      resolved_by = actor,
      resolution_reason = normalized_reason
  where type = 'mail_projection_failed'
    and object_type = 'mail_projection_batch'
    and object_id = target_batch.id
    and status in ('open', 'in_progress');

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'mail_v2.fulfilment.retry_requested',
    'mail_projection_batch',
    target_batch.id,
    jsonb_build_object(
      'retryCount',
      target_batch.retry_count,
      'reasonDigest',
      encode(
        extensions.digest(convert_to(normalized_reason, 'UTF8'), 'sha256'),
        'hex'
      ),
      'reasonLength',
      length(normalized_reason)
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'batchId', target_batch.id,
    'status', target_batch.status,
    'retryCount', target_batch.retry_count,
    'reused', false
  );
exception when others then
  perform set_config('app.mail_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.retry_fulfilment_mail_projection_v1(
  uuid, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.retry_fulfilment_mail_projection_v1(
  uuid, text, uuid
) to authenticated;

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
  where job.context_kind = 'fulfilment'
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
          and job.template_version is null
          and job.render_hash is not null
          and exists(
            select 1
            from private.fulfilment_mail_projection_batches batch
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
        when claimed.context_kind = 'fulfilment' then jsonb_build_object(
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

create or replace function app.authorize_claimed_email_job_v2(
  p_job_id uuid,
  p_claim_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_job private.email_jobs%rowtype;
  target_batch private.fulfilment_mail_projection_batches%rowtype;
  access_valid boolean;
  projection_count integer;
  authorized_count integer;
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
  if target_job.context_kind = 'order' then
    return true;
  end if;
  if target_job.context_kind = 'portal_access' then
    select exists(
      select 1
      from private.parent_access_batch_items batch_item
      join private.parent_portal_grants grant_row
        on grant_row.id = batch_item.grant_id
        and grant_row.parent_account_id = target_job.parent_account_id
        and grant_row.status = 'active'
      join app.member_seasons member_season
        on member_season.id = grant_row.member_season_id
        and member_season.participation_status = 'active'
      where batch_item.batch_id = target_job.parent_access_batch_id
        and batch_item.outcome = 'activated'
    ) into access_valid;
    if access_valid then
      return true;
    end if;
  elsif target_job.context_kind = 'fulfilment' then
    select * into target_batch
    from private.fulfilment_mail_projection_batches batch
    where batch.email_job_id = target_job.id
      and batch.status = 'queued'
    for update;
    if found then
      select count(*)::integer into projection_count
      from private.fulfilment_mail_projections projection
      where projection.projection_batch_id = target_batch.id;
      select eligibility.eligible_count, eligibility.revision_hash
      into authorized_count, current_eligibility_revision
      from private.fulfilment_mail_current_eligibility(target_batch.id)
        eligibility;
      if projection_count = target_batch.event_count
        and authorized_count = target_batch.eligible_event_count
        and current_eligibility_revision = target_batch.eligibility_revision
        and projection_count > 0
      then
        return true;
      end if;
    end if;
  end if;

  update private.email_jobs
  set status = 'failed',
      completed_at = timezone('utc', now()),
      last_error = 'access_inactive_before_send',
      updated_at = timezone('utc', now())
  where id = target_job.id;
  if target_job.context_kind = 'fulfilment' and target_batch.id is not null then
    perform set_config('app.mail_projection_internal', 'on', true);
    if projection_count = target_batch.event_count
      and authorized_count > 0
      and target_batch.retry_count < 10
    then
      update private.fulfilment_mail_projection_batches
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
      update private.fulfilment_mail_projection_batches
      set status = 'suppressed',
          email_job_id = null,
          suppression_reason = 'grant_inactive_before_send',
          eligible_event_count = null,
          eligibility_revision = null,
          updated_at = timezone('utc', now())
      where id = target_batch.id;
    end if;
    perform set_config('app.mail_projection_internal', 'off', true);
    if not (
      projection_count = target_batch.event_count
      and authorized_count > 0
      and target_batch.retry_count < 10
    ) then
      perform private.open_mail_projection_action(
        target_batch,
        'grant_inactive_before_send'
      );
    end if;
  end if;
  return false;
exception when others then
  perform set_config('app.mail_projection_internal', 'off', true);
  raise;
end;
$$;

revoke all on function app.authorize_claimed_email_job_v2(uuid, uuid)
from public, anon, authenticated;
grant execute on function app.authorize_claimed_email_job_v2(uuid, uuid)
to service_role;

comment on function app.claim_fulfilment_mail_projections_v1(uuid, integer)
is 'Leases consolidated post-cutover fulfilment groups without logging recipient data.';
comment on function app.finalize_fulfilment_mail_projection_v1(
  uuid, uuid, text, text, text, text, text, text
) is 'Revalidates every grant and atomically enqueues one immutable rendered job.';
comment on function app.retry_fulfilment_mail_projection_v1(uuid, text, uuid)
is 'AAL2 administrator recovery after the suppressing condition has been reconciled.';
comment on function app.claim_email_jobs_v3(uuid, integer)
is 'Rollback-safe union claim for legacy source jobs and immutable mail-v2 snapshots.';
