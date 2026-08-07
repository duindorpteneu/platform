-- A posted inventory delivery creates a durable, PII-free notification
-- proposal. Delivery-sourced allocations no longer enqueue pickup mail
-- automatically; an AAL2 operations user must explicitly confirm selected
-- proposal items. Other allocation sources retain the existing producer.

create table app.inventory_delivery_notification_proposals (
  id uuid primary key default gen_random_uuid(),
  delivery_draft_id uuid not null unique
    references app.inventory_delivery_drafts(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  receipt_id uuid not null unique
    references app.delivery_receipts(id) on delete restrict,
  status text not null default 'open' check (
    status in ('open', 'confirmed')
  ),
  created_by uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  confirmed_by uuid
    references app.staff_profiles(auth_user_id) on delete restrict,
  confirmed_at timestamptz,
  confirmation_request_id uuid unique,
  confirmation_revision text check (
    confirmation_revision is null
    or confirmation_revision ~ '^[0-9a-f]{64}$'
  ),
  selected_count integer not null default 0 check (selected_count >= 0),
  eligible_count integer not null default 0 check (eligible_count >= 0),
  skipped_count integer not null default 0 check (skipped_count >= 0),
  blocked_count integer not null default 0 check (blocked_count >= 0),
  event_count integer not null default 0 check (event_count >= 0),
  parent_group_count integer not null default 0 check (parent_group_count >= 0),
  created_at timestamptz not null default timezone('utc', now()),
  constraint inventory_delivery_notification_proposal_lifecycle_check check (
    (
      status = 'open'
      and confirmed_by is null
      and confirmed_at is null
      and confirmation_request_id is null
      and confirmation_revision is null
      and selected_count = 0
      and eligible_count = 0
      and skipped_count = 0
      and blocked_count = 0
      and event_count = 0
      and parent_group_count = 0
    )
    or (
      status = 'confirmed'
      and confirmed_by is not null
      and confirmed_at is not null
      and confirmation_request_id is not null
      and confirmation_revision is not null
      and selected_count <= eligible_count + skipped_count + blocked_count
      and event_count >= eligible_count
    )
  )
);

create index inventory_delivery_notification_proposals_workspace_idx
  on app.inventory_delivery_notification_proposals(
    season_id,
    status,
    created_at desc,
    id
  );

create table app.inventory_delivery_notification_items (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null
    references app.inventory_delivery_notification_proposals(id)
    on delete restrict,
  allocation_event_id uuid not null unique
    references app.inventory_allocation_events(id) on delete restrict,
  allocation_id uuid not null
    references app.inventory_allocations(id) on delete restrict,
  decision text not null default 'pending' check (
    decision in ('pending', 'enqueued', 'skipped', 'blocked')
  ),
  reason_code text check (
    reason_code is null
    or reason_code ~ '^[a-z][a-z0-9._-]{2,79}$'
  ),
  event_count integer not null default 0 check (event_count >= 0),
  decided_by uuid
    references app.staff_profiles(auth_user_id) on delete restrict,
  decided_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  unique(proposal_id, allocation_id),
  constraint inventory_delivery_notification_item_lifecycle_check check (
    (
      decision = 'pending'
      and reason_code is null
      and event_count = 0
      and decided_by is null
      and decided_at is null
    )
    or (
      decision = 'enqueued'
      and reason_code = 'notification.events_enqueued'
      and event_count > 0
      and decided_by is not null
      and decided_at is not null
    )
    or (
      decision in ('skipped', 'blocked')
      and reason_code is not null
      and event_count = 0
      and decided_by is not null
      and decided_at is not null
    )
  )
);

create index inventory_delivery_notification_items_proposal_idx
  on app.inventory_delivery_notification_items(
    proposal_id,
    decision,
    created_at,
    id
  );

alter table app.inventory_delivery_notification_proposals
  enable row level security;
alter table app.inventory_delivery_notification_items
  enable row level security;

create policy "operations can read delivery notification proposals"
on app.inventory_delivery_notification_proposals
for select using (
  app.staff_role() in ('beheerder', 'kledingcommissie')
  and coalesce(auth.jwt()->>'aal', '') = 'aal2'
);

create policy "operations can read delivery notification items"
on app.inventory_delivery_notification_items
for select using (
  app.staff_role() in ('beheerder', 'kledingcommissie')
  and coalesce(auth.jwt()->>'aal', '') = 'aal2'
);

revoke all on table app.inventory_delivery_notification_proposals
from public, anon, authenticated, service_role;
revoke all on table app.inventory_delivery_notification_items
from public, anon, authenticated, service_role;
grant select on table app.inventory_delivery_notification_proposals
to authenticated;
grant select on table app.inventory_delivery_notification_items
to authenticated;

create or replace function private.ensure_inventory_delivery_notification_proposal()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if new.status <> 'posted'
    or old.status = 'posted'
    or new.posted_receipt_id is null
    or new.posted_by is null
  then
    return new;
  end if;

  insert into app.inventory_delivery_notification_proposals(
    delivery_draft_id,
    season_id,
    receipt_id,
    created_by
  ) values (
    new.id,
    new.season_id,
    new.posted_receipt_id,
    new.posted_by
  )
  on conflict (delivery_draft_id) do nothing;
  return new;
end;
$$;

create trigger inventory_delivery_drafts_notification_proposal
after update of status, posted_receipt_id, posted_by
on app.inventory_delivery_drafts
for each row execute function
  private.ensure_inventory_delivery_notification_proposal();

revoke all on function
  private.ensure_inventory_delivery_notification_proposal()
from public, anon, authenticated, service_role;

create or replace function private.capture_inventory_delivery_notification_item()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_proposal_id uuid;
begin
  if new.event_type <> 'reserved'
    or new.next_status <> 'reserved'
    or new.source_type <> 'inventory_delivery'
    or new.source_id is null
  then
    return new;
  end if;

  select proposal.id into target_proposal_id
  from app.inventory_delivery_notification_proposals proposal
  join app.inventory_delivery_drafts draft
    on draft.id = proposal.delivery_draft_id
    and draft.id = new.source_id
    and draft.status = 'posted'
  join app.inventory_allocations allocation
    on allocation.id = new.allocation_id
    and allocation.season_id = proposal.season_id
  where proposal.status = 'open';

  if target_proposal_id is null then
    raise exception 'DELIVERY_NOTIFICATION_PROPOSAL_REQUIRED'
      using errcode = '23514';
  end if;

  insert into app.inventory_delivery_notification_items(
    proposal_id,
    allocation_event_id,
    allocation_id
  ) values (
    target_proposal_id,
    new.id,
    new.allocation_id
  )
  on conflict (allocation_event_id) do nothing;
  return new;
end;
$$;

create trigger inventory_allocation_events_delivery_notification_item
after insert on app.inventory_allocation_events
for each row execute function
  private.capture_inventory_delivery_notification_item();

revoke all on function
  private.capture_inventory_delivery_notification_item()
from public, anon, authenticated, service_role;

-- Applied databases may already contain posted deliveries. Backfill a proposal
-- and item ledger without re-enqueueing historical readiness events.
insert into app.inventory_delivery_notification_proposals(
  delivery_draft_id,
  season_id,
  receipt_id,
  created_by,
  created_at
)
select
  draft.id,
  draft.season_id,
  draft.posted_receipt_id,
  draft.posted_by,
  coalesce(draft.posted_at, draft.updated_at, draft.created_at)
from app.inventory_delivery_drafts draft
where draft.status = 'posted'
  and draft.posted_receipt_id is not null
  and draft.posted_by is not null
on conflict (delivery_draft_id) do nothing;

insert into app.inventory_delivery_notification_items(
  proposal_id,
  allocation_event_id,
  allocation_id,
  created_at
)
select
  proposal.id,
  allocation_event.id,
  allocation_event.allocation_id,
  allocation_event.created_at
from app.inventory_allocation_events allocation_event
join app.inventory_delivery_notification_proposals proposal
  on proposal.delivery_draft_id = allocation_event.source_id
join app.inventory_allocations allocation
  on allocation.id = allocation_event.allocation_id
  and allocation.season_id = proposal.season_id
where allocation_event.event_type = 'reserved'
  and allocation_event.next_status = 'reserved'
  and allocation_event.source_type = 'inventory_delivery'
on conflict (allocation_event_id) do nothing;

-- Suppress only the automatic delivery producer. Queue allocators, payment
-- allocations and explicit corrections retain their existing behavior.
create or replace function private.produce_pickup_ready_v2()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_allocation app.inventory_allocations%rowtype;
  target_grant record;
begin
  if new.event_type <> 'reserved'
    or new.next_status <> 'reserved'
    or new.source_type = 'inventory_delivery'
    or not private.mail_templates_v2_cutover_started()
  then
    return new;
  end if;
  select * into target_allocation
  from app.inventory_allocations allocation
  where allocation.id = new.allocation_id;
  if not found then
    return new;
  end if;
  for target_grant in
    select grant_row.parent_account_id
    from private.parent_portal_grants grant_row
    where grant_row.member_season_id = target_allocation.member_season_id
      and grant_row.status = 'active'
      and grant_row.parent_account_id is not null
  loop
    perform private.enqueue_mail_v2_member_event(
      'pickup_ready',
      target_grant.parent_account_id,
      target_allocation.member_season_id,
      'inventory_allocation_event',
      new.id,
      coalesce(
        new.source_id,
        case
          when new.source_type = 'allocation_queue' then (
            substr(md5('allocation-queue:' || txid_current()::text), 1, 8)
            || '-' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 9, 4)
            || '-4' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 14, 3)
            || '-8' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 18, 3)
            || '-' || substr(md5(
              'allocation-queue:' || txid_current()::text
            ), 21, 12)
          )::uuid
          else new.id
        end
      ),
      concat_ws(
        ':',
        'pickup-ready-v2',
        new.id,
        target_grant.parent_account_id
      ),
      target_allocation.order_line_id
    );
  end loop;
  return new;
end;
$$;

revoke all on function private.produce_pickup_ready_v2()
from public, anon, authenticated, service_role;

create or replace function private.inventory_delivery_notification_item_state(
  p_item_id uuid
)
returns table(
  classification text,
  reason_code text,
  active_parent_groups integer
)
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
  grant_count integer := 0;
begin
  select
    item.id,
    item.decision,
    item.reason_code stored_reason,
    item.event_count,
    proposal.status proposal_status,
    proposal.id proposal_id,
    proposal.season_id proposal_season_id,
    proposal.delivery_draft_id,
    allocation_event.id allocation_event_id,
    allocation_event.event_type,
    allocation_event.next_status,
    allocation_event.source_type,
    allocation_event.source_id,
    allocation.id allocation_id,
    allocation.status allocation_status,
    allocation.reconciliation_status,
    allocation.season_id allocation_season_id,
    allocation.member_season_id,
    allocation.order_id,
    allocation.order_line_id,
    member_season.season_id member_season_season_id,
    member_season.participation_status,
    orders.season_id order_season_id,
    line.status line_status
  into target
  from app.inventory_delivery_notification_items item
  join app.inventory_delivery_notification_proposals proposal
    on proposal.id = item.proposal_id
  join app.inventory_allocation_events allocation_event
    on allocation_event.id = item.allocation_event_id
  join app.inventory_allocations allocation
    on allocation.id = item.allocation_id
    and allocation.id = allocation_event.allocation_id
  join app.member_seasons member_season
    on member_season.id = allocation.member_season_id
  join app.member_orders orders
    on orders.id = allocation.order_id
    and orders.member_season_id = member_season.id
  join app.order_lines line
    on line.id = allocation.order_line_id
    and line.order_id = orders.id
    and line.article_variant_id = allocation.article_variant_id
  where item.id = p_item_id;

  if not found then
    return query select 'blocked', 'notification.item_missing', 0;
    return;
  end if;

  if target.proposal_status = 'confirmed' then
    return query select
      case
        when target.decision = 'enqueued' then 'eligible'
        else target.decision
      end,
      coalesce(target.stored_reason, 'notification.already_confirmed'),
      target.event_count;
    return;
  end if;

  if target.event_type <> 'reserved'
    or target.next_status <> 'reserved'
    or target.source_type <> 'inventory_delivery'
    or target.source_id <> target.delivery_draft_id
    or target.allocation_season_id <> target.proposal_season_id
    or target.member_season_season_id <> target.proposal_season_id
    or target.order_season_id <> target.proposal_season_id
  then
    return query select 'blocked', 'notification.source_mismatch', 0;
    return;
  end if;

  if exists(
    select 1
    from private.mail_v2_domain_events event
    join private.mail_v2_event_suppressions suppression
      on suppression.event_id = event.id
    where event.source_type = 'inventory_allocation_event'
      and event.source_id = target.allocation_event_id
  ) then
    return query select 'skipped', 'notification.readiness_suppressed', 0;
    return;
  end if;

  if exists(
    select 1
    from private.mail_v2_domain_events event
    where event.source_type = 'inventory_allocation_event'
      and event.source_id = target.allocation_event_id
  ) then
    return query select 'skipped', 'notification.readiness_event_exists', 0;
    return;
  end if;

  if not private.mail_templates_v2_cutover_started() then
    return query select 'blocked', 'notification.mail_v2_inactive', 0;
    return;
  end if;

  if not exists(
    select 1
    from app.mail_templates template
    join app.mail_template_revisions revision
      on revision.template_key = template.template_key
      and revision.status = 'published'
    where template.template_key = 'pickup_ready'
      and template.active
  ) or not exists(
    select 1
    from app.mail_branding_revisions branding
    where branding.status = 'published'
      and branding.contrast_validated
  ) then
    return query select 'blocked', 'notification.template_unavailable', 0;
    return;
  end if;

  if target.participation_status <> 'active'
    or target.allocation_status <> 'reserved'
    or target.reconciliation_status <> 'resolved'
    or target.line_status <> 'ready_for_pickup'
  then
    return query select 'blocked', 'notification.allocation_not_ready', 0;
    return;
  end if;

  if not exists(
    select 1
    from app.payments payment
    where payment.order_id = target.order_id
      and payment.status = 'paid'
      and payment.reconciliation_issue is null
  ) then
    return query select 'blocked', 'notification.payment_not_valid', 0;
    return;
  end if;

  select count(distinct grant_row.parent_account_id)::integer
  into grant_count
  from private.parent_portal_grants grant_row
  where grant_row.member_season_id = target.member_season_id
    and grant_row.status = 'active'
    and grant_row.parent_account_id is not null;

  if grant_count = 0 then
    return query select 'skipped', 'notification.no_active_parent_grant', 0;
    return;
  end if;

  return query select 'eligible', 'notification.ready', grant_count;
end;
$$;

revoke all on function
  private.inventory_delivery_notification_item_state(uuid)
from public, anon, authenticated, service_role;

create or replace function
  private.inventory_delivery_notification_revision(uuid)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(
    extensions.digest(
      convert_to(
        concat_ws(
          E'\n',
          proposal.id::text,
          proposal.status,
          proposal.season_id::text,
          coalesce(string_agg(
            concat_ws(
              ':',
              item.id::text,
              item.allocation_event_id::text,
              state.classification,
              state.reason_code,
              state.active_parent_groups::text
            ),
            E'\n' order by item.id
          ), ''),
          coalesce((
            select string_agg(
              revision.id::text || ':' || revision.content_hash,
              ':' order by revision.id
            )
            from app.mail_template_revisions revision
            where revision.template_key = 'pickup_ready'
              and revision.status = 'published'
          ), ''),
          coalesce((
            select string_agg(
              branding.id::text || ':' || branding.content_hash,
              ':' order by branding.id
            )
            from app.mail_branding_revisions branding
            where branding.status = 'published'
              and branding.contrast_validated
          ), '')
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  from app.inventory_delivery_notification_proposals proposal
  left join app.inventory_delivery_notification_items item
    on item.proposal_id = proposal.id
  left join lateral
    private.inventory_delivery_notification_item_state(item.id) state
    on item.id is not null
  where proposal.id = $1
  group by proposal.id, proposal.status, proposal.season_id;
$$;

revoke all on function
  private.inventory_delivery_notification_revision(uuid)
from public, anon, authenticated, service_role;

create or replace function app.get_inventory_delivery_notification_proposal_v1(
  p_delivery_draft_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  proposal app.inventory_delivery_notification_proposals%rowtype;
  revision_hash text;
begin
  perform private.require_clothing_aal2();
  select * into proposal
  from app.inventory_delivery_notification_proposals candidate
  where candidate.delivery_draft_id = p_delivery_draft_id;
  if not found then
    raise exception 'DELIVERY_NOTIFICATION_PROPOSAL_NOT_FOUND'
      using errcode = 'P0002';
  end if;

  revision_hash := case
    when proposal.status = 'confirmed' then proposal.confirmation_revision
    else private.inventory_delivery_notification_revision(proposal.id)
  end;

  return jsonb_build_object(
    'id', proposal.id,
    'deliveryDraftId', proposal.delivery_draft_id,
    'seasonId', proposal.season_id,
    'receiptId', proposal.receipt_id,
    'status', proposal.status,
    'eligibilityRevision', revision_hash,
    'selectedCount', proposal.selected_count,
    'eligibleCount', case
      when proposal.status = 'confirmed' then proposal.eligible_count
      else (
        select count(*)
        from app.inventory_delivery_notification_items item
        join lateral
          private.inventory_delivery_notification_item_state(item.id) state
          on true
        where item.proposal_id = proposal.id
          and state.classification = 'eligible'
      )
    end,
    'skippedCount', case
      when proposal.status = 'confirmed' then proposal.skipped_count
      else (
        select count(*)
        from app.inventory_delivery_notification_items item
        join lateral
          private.inventory_delivery_notification_item_state(item.id) state
          on true
        where item.proposal_id = proposal.id
          and state.classification = 'skipped'
      )
    end,
    'blockedCount', case
      when proposal.status = 'confirmed' then proposal.blocked_count
      else (
        select count(*)
        from app.inventory_delivery_notification_items item
        join lateral
          private.inventory_delivery_notification_item_state(item.id) state
          on true
        where item.proposal_id = proposal.id
          and state.classification = 'blocked'
      )
    end,
    'eventCount', proposal.event_count,
    'parentGroupCount', case
      when proposal.status = 'confirmed' then proposal.parent_group_count
      else (
        select count(distinct grant_row.parent_account_id)
        from app.inventory_delivery_notification_items item
        join lateral
          private.inventory_delivery_notification_item_state(item.id) state
          on state.classification = 'eligible'
        join app.inventory_allocations allocation
          on allocation.id = item.allocation_id
        join private.parent_portal_grants grant_row
          on grant_row.member_season_id = allocation.member_season_id
          and grant_row.status = 'active'
          and grant_row.parent_account_id is not null
        where item.proposal_id = proposal.id
      )
    end,
    'createdAt', proposal.created_at,
    'confirmedAt', proposal.confirmed_at,
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', item.id,
          'allocationEventId', item.allocation_event_id,
          'allocationId', item.allocation_id,
          'productName', allocation.product_name_snapshot,
          'size', allocation.size_snapshot,
          'quantity', allocation.quantity,
          'classification', case
            when proposal.status = 'confirmed'
              and item.decision = 'enqueued'
            then 'eligible'
            when proposal.status = 'confirmed'
            then item.decision
            else state.classification
          end,
          'reasonCode', case
            when proposal.status = 'confirmed' then item.reason_code
            else state.reason_code
          end,
          'eventCount', item.event_count,
          'selectedByDefault',
            proposal.status = 'open'
            and state.classification = 'eligible'
        )
        order by allocation.product_name_snapshot,
          allocation.size_snapshot,
          item.id
      )
      from app.inventory_delivery_notification_items item
      join app.inventory_allocations allocation
        on allocation.id = item.allocation_id
      join lateral
        private.inventory_delivery_notification_item_state(item.id) state
        on true
      where item.proposal_id = proposal.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function
  app.get_inventory_delivery_notification_proposal_v1(uuid)
from public, anon;
grant execute on function
  app.get_inventory_delivery_notification_proposal_v1(uuid)
to authenticated;

create or replace function app.confirm_inventory_delivery_notification_proposal_v1(
  p_proposal_id uuid,
  p_expected_revision text,
  p_excluded_item_ids uuid[],
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  proposal app.inventory_delivery_notification_proposals%rowtype;
  item_record record;
  grant_record record;
  prior private.inventory_command_requests%rowtype;
  excluded_ids uuid[];
  excluded_count integer;
  requested_selection_count integer := 0;
  confirmed_eligible_count integer := 0;
  confirmed_skipped_count integer := 0;
  confirmed_blocked_count integer := 0;
  confirmed_event_count integer := 0;
  confirmed_parent_group_count integer := 0;
  item_event_count integer;
  request_hash text;
  current_revision text;
  result jsonb;
begin
  select array_agg(item_id order by item_id)
  into excluded_ids
  from (
    select distinct item_id
    from unnest(coalesce(p_excluded_item_ids, array[]::uuid[])) item_id
  ) excluded;
  excluded_ids := coalesce(excluded_ids, array[]::uuid[]);
  excluded_count := coalesce(array_length(p_excluded_item_ids, 1), 0);

  if p_proposal_id is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_request_id is null
    or excluded_count > 500
    or excluded_count <> coalesce(array_length(excluded_ids, 1), 0)
  then
    raise exception 'DELIVERY_NOTIFICATION_CONFIRM_INVALID'
      using errcode = '22023';
  end if;

  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'inventory-delivery-notification-confirm-v1',
        p_proposal_id::text,
        p_expected_revision,
        'all-eligible-except',
        array_to_string(excluded_ids, ',')
      ),
      'sha256'
    ),
    'hex'
  );

  select * into prior
  from private.inventory_command_requests request
  where request.request_id = p_request_id;
  if found then
    if prior.command_type <> 'inventory.delivery.notification.confirm'
      or prior.target_id <> p_proposal_id
      or prior.request_hash <> request_hash
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  select * into proposal
  from app.inventory_delivery_notification_proposals candidate
  where candidate.id = p_proposal_id
  for update;
  if not found then
    raise exception 'DELIVERY_NOTIFICATION_PROPOSAL_NOT_FOUND'
      using errcode = 'P0002';
  end if;

  select * into prior
  from private.inventory_command_requests request
  where request.request_id = p_request_id;
  if found then
    if prior.command_type <> 'inventory.delivery.notification.confirm'
      or prior.target_id <> p_proposal_id
      or prior.request_hash <> request_hash
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  if proposal.status <> 'open' then
    raise exception 'DELIVERY_NOTIFICATION_ALREADY_CONFIRMED'
      using errcode = '55000';
  end if;
  if exists(
    select 1
    from unnest(excluded_ids) excluded(item_id)
    where not exists(
      select 1
      from app.inventory_delivery_notification_items item
      where item.proposal_id = proposal.id
        and item.id = excluded.item_id
    )
  ) then
    raise exception 'DELIVERY_NOTIFICATION_ITEM_INVALID'
      using errcode = '23514';
  end if;

  current_revision :=
    private.inventory_delivery_notification_revision(proposal.id);
  if current_revision <> p_expected_revision then
    raise exception 'DELIVERY_NOTIFICATION_ELIGIBILITY_CHANGED'
      using errcode = '40001';
  end if;

  for item_record in
    select
      item.id,
      item.allocation_event_id,
      allocation.member_season_id,
      allocation.order_line_id,
      state.classification,
      state.reason_code
    from app.inventory_delivery_notification_items item
    join app.inventory_allocations allocation
      on allocation.id = item.allocation_id
    join lateral
      private.inventory_delivery_notification_item_state(item.id) state
      on true
    where item.proposal_id = proposal.id
    order by item.id
    for update of item
  loop
    item_event_count := 0;
    if item_record.classification = 'eligible' then
      if item_record.id = any(excluded_ids) then
        update app.inventory_delivery_notification_items
        set decision = 'skipped',
            reason_code = 'notification.staff_not_selected',
            decided_by = actor,
            decided_at = timezone('utc', now())
        where id = item_record.id;
        confirmed_skipped_count := confirmed_skipped_count + 1;
      else
        requested_selection_count := requested_selection_count + 1;
        for grant_record in
          select distinct grant_row.parent_account_id
          from private.parent_portal_grants grant_row
          where grant_row.member_season_id = item_record.member_season_id
            and grant_row.status = 'active'
            and grant_row.parent_account_id is not null
          order by grant_row.parent_account_id
        loop
          perform private.enqueue_mail_v2_member_event(
            'pickup_ready',
            grant_record.parent_account_id,
            item_record.member_season_id,
            'inventory_allocation_event',
            item_record.allocation_event_id,
            proposal.id,
            concat_ws(
              ':',
              'delivery-notification-v1',
              proposal.id,
              item_record.allocation_event_id,
              grant_record.parent_account_id
            ),
            item_record.order_line_id
          );
          item_event_count := item_event_count + 1;
        end loop;
        if item_event_count = 0 then
          update app.inventory_delivery_notification_items
          set decision = 'skipped',
              reason_code = 'notification.no_active_parent_grant',
              decided_by = actor,
              decided_at = timezone('utc', now())
          where id = item_record.id;
          confirmed_skipped_count := confirmed_skipped_count + 1;
        else
          update app.inventory_delivery_notification_items
          set decision = 'enqueued',
              reason_code = 'notification.events_enqueued',
              event_count = item_event_count,
              decided_by = actor,
              decided_at = timezone('utc', now())
          where id = item_record.id;
          confirmed_eligible_count := confirmed_eligible_count + 1;
          confirmed_event_count :=
            confirmed_event_count + item_event_count;
        end if;
      end if;
    elsif item_record.classification = 'skipped' then
      update app.inventory_delivery_notification_items
      set decision = 'skipped',
          reason_code = item_record.reason_code,
          decided_by = actor,
          decided_at = timezone('utc', now())
      where id = item_record.id;
      confirmed_skipped_count := confirmed_skipped_count + 1;
    else
      update app.inventory_delivery_notification_items
      set decision = 'blocked',
          reason_code = item_record.reason_code,
          decided_by = actor,
          decided_at = timezone('utc', now())
      where id = item_record.id;
      confirmed_blocked_count := confirmed_blocked_count + 1;
    end if;
  end loop;

  select count(distinct event.parent_account_id)::integer
  into confirmed_parent_group_count
  from private.mail_v2_domain_events event
  where event.cohort_id = proposal.id
    and event.template_key = 'pickup_ready';

  update app.inventory_delivery_notification_proposals
  set status = 'confirmed',
      confirmed_by = actor,
      confirmed_at = timezone('utc', now()),
      confirmation_request_id = p_request_id,
      confirmation_revision = current_revision,
      selected_count = requested_selection_count,
      eligible_count = confirmed_eligible_count,
      skipped_count = confirmed_skipped_count,
      blocked_count = confirmed_blocked_count,
      event_count = confirmed_event_count,
      parent_group_count = confirmed_parent_group_count
  where id = proposal.id;

  result := jsonb_build_object(
    'proposalId', proposal.id,
    'status', 'confirmed',
    'selectedCount', requested_selection_count,
    'eligibleCount', confirmed_eligible_count,
    'skippedCount', confirmed_skipped_count,
    'blockedCount', confirmed_blocked_count,
    'eventCount', confirmed_event_count,
    'parentGroupCount', confirmed_parent_group_count,
    'reused', false
  );

  insert into private.inventory_command_requests(
    request_id,
    command_type,
    target_id,
    request_hash,
    result_snapshot,
    actor_user_id
  ) values (
    p_request_id,
    'inventory.delivery.notification.confirm',
    proposal.id,
    request_hash,
    result,
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
    'inventory.delivery_notification.confirmed',
    'inventory_delivery_notification_proposal',
    proposal.id,
    jsonb_build_object(
      'deliveryDraftId', proposal.delivery_draft_id,
      'seasonId', proposal.season_id,
      'eligibleCount', confirmed_eligible_count,
      'skippedCount', confirmed_skipped_count,
      'blockedCount', confirmed_blocked_count,
      'eventCount', confirmed_event_count,
      'parentGroupCount', confirmed_parent_group_count
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke all on function
  app.confirm_inventory_delivery_notification_proposal_v1(
    uuid, text, uuid[], uuid, uuid
  )
from public, anon;
grant execute on function
  app.confirm_inventory_delivery_notification_proposal_v1(
    uuid, text, uuid[], uuid, uuid
  )
to authenticated;

comment on table app.inventory_delivery_notification_proposals is
  'PII-vrije, expliciet te bevestigen mailvoorstellen per geboekte levering.';
comment on table app.inventory_delivery_notification_items is
  'PII-vrije selectie- en uitkomstregels gekoppeld aan harde allocatie-events.';

notify pgrst, 'reload schema';
