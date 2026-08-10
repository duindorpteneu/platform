-- Phase B inventory expand and lossless legacy reconciliation.
--
-- The journal is the canonical stock balance for the new flow. Legacy receipt,
-- reservation and fulfilment rows remain unchanged as historical source facts.
-- Free legacy stock has no provable season, so it is deliberately kept outside
-- the journal until an AAL2 administrator assigns it.

do $$ begin
  create type app.inventory_movement_type as enum (
    'opening_balance',
    'receipt',
    'allocation_reserved',
    'allocation_released',
    'fulfilment_issued',
    'fulfilment_reversed_ready',
    'fulfilment_reversed_backorder',
    'adjustment_in',
    'adjustment_out'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.inventory_allocation_status as enum (
    'reserved',
    'fulfilled',
    'released'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.inventory_allocation_reconciliation as enum (
    'resolved',
    'review_required'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.inventory_allocation_mode as enum (
    'fifo',
    'admin_override',
    'legacy_preserved'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.inventory_reconciliation_status as enum (
    'pending',
    'assigned',
    'zero',
    'discrepancy'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.inventory_delivery_status as enum (
    'draft',
    'ready',
    'posted',
    'cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.inventory_queue_status as enum (
    'queued',
    'processing',
    'completed',
    'failed'
  );
exception when duplicate_object then null; end $$;

-- Action-item contexts stay deliberately small and PII-free.
create or replace function private.action_context_is_safe(p_context jsonb)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    p_context is not null
    and jsonb_typeof(p_context) = 'object'
    and octet_length(p_context::text) <= 4000
    and not exists(
      select 1
      from jsonb_each(p_context) entry
      where not (
        (
          entry.key in (
            'articleId',
            'variantId',
            'orderItemId',
            'receiptId',
            'receiptLineId',
            'deliveryDraftId',
            'allocationId',
            'movementId',
            'reconciliationCandidateId',
            'fulfilmentId',
            'runId',
            'batchId',
            'memberSeasonId',
            'packageOrderId',
            'paymentId',
            'templateId',
            'jobId'
          )
          and jsonb_typeof(entry.value) = 'string'
          and entry.value #>> '{}' ~
            '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        )
        or (
          entry.key in (
            'sourceRow',
            'quantity',
            'count',
            'attempt',
            'episode',
            'shortage',
            'available',
            'reserved',
            'requested',
            'waiterCount',
            'queueDepth',
            'templateRevision'
          )
          and jsonb_typeof(entry.value) = 'number'
          and entry.value::text ~ '^(0|[1-9][0-9]{0,9})$'
        )
        or (
          entry.key in ('blocked', 'eligible')
          and jsonb_typeof(entry.value) = 'boolean'
        )
      )
    );
$$;

revoke all on function private.action_context_is_safe(jsonb)
from public, anon, authenticated, service_role;

-- System resolution is explicit; normal staff resolution continues through the
-- existing public RPC and is classified by this trigger.
alter table app.action_items
  add column resolution_source text;

update app.action_items
set resolution_source = 'staff'
where status in ('resolved', 'dismissed');

alter table app.action_items
  drop constraint action_items_resolution_check,
  add constraint action_items_resolution_check check (
    (
      status in ('open', 'in_progress')
      and resolved_at is null
      and resolved_by is null
      and resolution_reason is null
      and resolution_source is null
    )
    or (
      status in ('resolved', 'dismissed')
      and resolved_at is not null
      and length(btrim(resolution_reason)) between 3 and 500
      and (
        (resolution_source = 'staff' and resolved_by is not null)
        or (
          resolution_source = 'system'
          and resolved_by is null
          and status = 'resolved'
        )
      )
    )
  );

create or replace function private.classify_action_item_resolution()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if new.status in ('open', 'in_progress') then
    new.resolution_source := null;
  elsif new.resolution_source is null then
    new.resolution_source := case
      when new.resolved_by is null then 'system'
      else 'staff'
    end;
  end if;
  return new;
end;
$$;

create trigger action_items_classify_resolution
before insert or update of status, resolved_by, resolution_source
on app.action_items
for each row execute function private.classify_action_item_resolution();

revoke all on function private.classify_action_item_resolution()
from public, anon, authenticated, service_role;

create or replace function private.auto_resolve_action_item(
  p_type text,
  p_season_id uuid,
  p_dedupe_key text,
  p_reason text
)
returns boolean
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_id uuid;
begin
  if p_type is null
    or p_type !~ '^[a-z][a-z0-9_]{2,63}$'
    or p_season_id is null
    or p_dedupe_key !~ '^[0-9a-f]{64}$'
    or p_reason is null
    or length(btrim(p_reason)) not between 3 and 500
  then
    raise exception 'ACTION_ITEM_AUTO_RESOLUTION_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'action-item:' || p_type || ':' || p_season_id::text || ':' || p_dedupe_key,
      0
    )
  );

  select item.id into target_id
  from app.action_items item
  where item.type = p_type
    and item.season_id = p_season_id
    and item.dedupe_key = p_dedupe_key
    and item.status in ('open', 'in_progress')
  for update;

  if target_id is null then
    return false;
  end if;

  update app.action_items
  set status = 'resolved',
      resolved_at = timezone('utc', now()),
      resolved_by = null,
      resolution_reason = btrim(p_reason),
      resolution_source = 'system'
  where id = target_id;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    'action_item.auto_resolved',
    'action_item',
    target_id,
    jsonb_build_object('type', p_type, 'seasonId', p_season_id)
  );
  return true;
end;
$$;

revoke all on function private.auto_resolve_action_item(
  text, uuid, text, text
) from public, anon, authenticated, service_role;

alter table app.order_lines
  add constraint order_lines_id_order_variant_unique
    unique (id, order_id, article_variant_id);

create table app.inventory_settings (
  season_id uuid primary key references app.seasons(id) on delete restrict,
  low_stock_threshold integer not null default 10
    check (low_stock_threshold between 0 and 100000),
  updated_by uuid,
  updated_at timestamptz not null default timezone('utc', now())
);

insert into app.inventory_settings(season_id)
select season.id from app.seasons season
on conflict (season_id) do nothing;

create or replace function private.ensure_inventory_settings()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  insert into app.inventory_settings(season_id)
  values(new.id)
  on conflict (season_id) do nothing;
  return new;
end;
$$;

create trigger seasons_ensure_inventory_settings
after insert on app.seasons
for each row execute function private.ensure_inventory_settings();

revoke all on function private.ensure_inventory_settings()
from public, anon, authenticated, service_role;

create table app.inventory_delivery_drafts (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references app.seasons(id) on delete restrict,
  status app.inventory_delivery_status not null default 'draft',
  received_on date not null,
  supplier text not null check (
    supplier = btrim(supplier)
    and length(supplier) between 1 and 160
  ),
  packing_slip_reference text check (
    packing_slip_reference is null
    or (
      packing_slip_reference = btrim(packing_slip_reference)
      and length(packing_slip_reference) between 1 and 160
    )
  ),
  revision integer not null default 1 check (revision > 0),
  create_request_id uuid not null unique,
  create_request_hash text not null check (
    create_request_hash ~ '^[0-9a-f]{64}$'
  ),
  created_by uuid not null references app.staff_profiles(auth_user_id) on delete restrict,
  updated_by uuid not null references app.staff_profiles(auth_user_id) on delete restrict,
  posted_receipt_id uuid unique references app.delivery_receipts(id) on delete restrict,
  posted_at timestamptz,
  posted_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint inventory_delivery_draft_state_check check (
    (
      status in ('draft', 'ready')
      and posted_receipt_id is null
      and posted_at is null
      and posted_by is null
      and cancelled_at is null
      and cancellation_reason is null
    )
    or (
      status = 'posted'
      and posted_receipt_id is not null
      and posted_at is not null
      and posted_by is not null
      and cancelled_at is null
      and cancellation_reason is null
    )
    or (
      status = 'cancelled'
      and posted_receipt_id is null
      and posted_at is null
      and posted_by is null
      and cancelled_at is not null
      and length(btrim(cancellation_reason)) between 4 and 500
    )
  )
);

create index inventory_delivery_drafts_workspace_idx
  on app.inventory_delivery_drafts(season_id, status, updated_at desc);

create table app.inventory_delivery_draft_lines (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references app.inventory_delivery_drafts(id) on delete restrict,
  article_id uuid not null references app.articles(id) on delete restrict,
  article_variant_id uuid not null,
  product_name_snapshot text not null check (
    length(btrim(product_name_snapshot)) between 1 and 120
  ),
  product_code_snapshot text not null check (
    length(btrim(product_code_snapshot)) between 1 and 24
  ),
  size_snapshot text not null check (
    length(btrim(size_snapshot)) between 1 and 80
  ),
  sku_snapshot text,
  sort_order integer not null check (sort_order between 0 and 10000),
  quantity integer check (quantity between 0 and 10000),
  confirmed boolean not null default false,
  confirmed_at timestamptz,
  confirmed_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  foreign key (article_variant_id, article_id)
    references app.article_variants(id, article_id) on delete restrict,
  unique (draft_id, article_variant_id),
  constraint inventory_delivery_line_confirmation_check check (
    (
      not confirmed
      and confirmed_at is null
      and confirmed_by is null
    )
    or (
      confirmed
      and quantity is not null
      and confirmed_at is not null
      and confirmed_by is not null
    )
  ),
  constraint inventory_delivery_line_sku_check check (
    sku_snapshot is null or length(btrim(sku_snapshot)) between 1 and 120
  )
);

create index inventory_delivery_draft_lines_draft_idx
  on app.inventory_delivery_draft_lines(draft_id, sort_order, article_variant_id);

create table private.inventory_command_requests (
  request_id uuid primary key,
  command_type text not null check (
    command_type ~ '^[a-z][a-z0-9._-]{2,79}$'
  ),
  target_id uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
    and not result_snapshot ?| array[
      'email',
      'recipient',
      'name',
      'member_name',
      'date_of_birth',
      'token',
      'token_hash',
      'qr_token',
      'qr_hash',
      'checkout_url'
    ]
  ),
  actor_user_id uuid references app.staff_profiles(auth_user_id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now())
);

create table app.inventory_allocations (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references app.seasons(id) on delete restrict,
  member_id uuid not null references app.members(id) on delete restrict,
  member_season_id uuid not null,
  order_id uuid not null,
  order_line_id uuid not null,
  article_id uuid not null references app.articles(id) on delete restrict,
  article_variant_id uuid not null,
  quantity integer not null check (quantity between 1 and 25),
  status app.inventory_allocation_status not null,
  reconciliation_status app.inventory_allocation_reconciliation not null,
  allocation_mode app.inventory_allocation_mode not null,
  paid_at timestamptz,
  size_valid_at timestamptz,
  priority_at timestamptz,
  product_name_snapshot text not null check (
    length(btrim(product_name_snapshot)) between 1 and 120
  ),
  size_snapshot text not null check (
    length(btrim(size_snapshot)) between 1 and 80
  ),
  legacy_reservation_id uuid unique
    references app.inventory_reservations(id) on delete restrict,
  allocated_at timestamptz,
  fulfilled_at timestamptz,
  released_at timestamptz,
  allocated_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  fulfilled_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  released_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  override_reason text,
  release_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  foreign key (member_season_id, member_id, season_id)
    references app.member_seasons(id, member_id, season_id) on delete restrict,
  foreign key (order_id, member_season_id)
    references app.member_orders(id, member_season_id) on delete restrict,
  foreign key (order_line_id, order_id, article_variant_id)
    references app.order_lines(id, order_id, article_variant_id) on delete restrict,
  foreign key (article_variant_id, article_id)
    references app.article_variants(id, article_id) on delete restrict,
  constraint inventory_allocation_timestamps_check check (
    (
      status = 'reserved'
      and allocated_at is not null
      and fulfilled_at is null
      and released_at is null
    )
    or (
      status = 'fulfilled'
      and allocated_at is not null
      and fulfilled_at is not null
      and released_at is null
    )
    or (
      status = 'released'
      and released_at is not null
    )
  ),
  constraint inventory_allocation_resolved_fact_check check (
    reconciliation_status = 'review_required'
    or status = 'released'
    or (
      paid_at is not null
      and size_valid_at is not null
      and priority_at = greatest(paid_at, size_valid_at)
    )
  ),
  constraint inventory_allocation_override_check check (
    allocation_mode <> 'admin_override'
    or (
      override_reason is not null
      and length(btrim(override_reason)) between 4 and 500
      and allocated_by is not null
    )
  ),
  constraint inventory_allocation_release_reason_check check (
    status <> 'released'
    or (
      release_reason is not null
      and length(btrim(release_reason)) between 4 and 500
    )
  )
);

create unique index inventory_allocations_one_active_line_idx
  on app.inventory_allocations(order_line_id)
  where status in ('reserved', 'fulfilled');
create index inventory_allocations_variant_queue_idx
  on app.inventory_allocations(season_id, article_variant_id, status, priority_at);
create index inventory_allocations_order_idx
  on app.inventory_allocations(order_id, status);

create table app.inventory_allocation_events (
  id uuid primary key default gen_random_uuid(),
  allocation_id uuid not null references app.inventory_allocations(id) on delete restrict,
  event_type text not null check (
    event_type in (
      'legacy_preserved',
      'reserved',
      'released',
      'fulfilled',
      'reversed_ready',
      'reversed_backorder',
      'reconciliation_resolved'
    )
  ),
  previous_status app.inventory_allocation_status,
  next_status app.inventory_allocation_status not null,
  reason_code text not null check (
    reason_code ~ '^[a-z][a-z0-9._-]{2,79}$'
  ),
  source_type text not null check (
    source_type ~ '^[a-z][a-z0-9_]{1,63}$'
  ),
  source_id uuid,
  idempotency_key text not null unique check (
    idempotency_key ~ '^[0-9a-f]{64}$'
  ),
  actor_user_id uuid references app.staff_profiles(auth_user_id) on delete restrict,
  safe_context jsonb not null default '{}'::jsonb
    check (private.action_context_is_safe(safe_context)),
  created_at timestamptz not null default timezone('utc', now())
);

create index inventory_allocation_events_allocation_idx
  on app.inventory_allocation_events(allocation_id, created_at, id);

create table app.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references app.seasons(id) on delete restrict,
  article_id uuid not null references app.articles(id) on delete restrict,
  article_variant_id uuid not null,
  movement_type app.inventory_movement_type not null,
  on_hand_delta integer not null default 0,
  reserved_delta integer not null default 0,
  issued_delta integer not null default 0,
  allocation_id uuid references app.inventory_allocations(id) on delete restrict,
  delivery_draft_id uuid references app.inventory_delivery_drafts(id) on delete restrict,
  receipt_line_id uuid references app.delivery_receipt_lines(id) on delete restrict,
  fulfilment_line_id uuid references app.fulfilment_lines(id) on delete restrict,
  source_type text not null check (
    source_type ~ '^[a-z][a-z0-9_]{1,63}$'
  ),
  source_id uuid,
  reason_code text not null check (
    reason_code ~ '^[a-z][a-z0-9._-]{2,79}$'
  ),
  idempotency_key text not null unique check (
    idempotency_key ~ '^[0-9a-f]{64}$'
  ),
  actor_user_id uuid references app.staff_profiles(auth_user_id) on delete restrict,
  correlation_id uuid,
  safe_context jsonb not null default '{}'::jsonb
    check (private.action_context_is_safe(safe_context)),
  occurred_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  foreign key (article_variant_id, article_id)
    references app.article_variants(id, article_id) on delete restrict,
  constraint inventory_movement_vector_check check (
    case movement_type
      when 'opening_balance' then
        on_hand_delta >= 0
        and reserved_delta >= 0
        and issued_delta >= 0
        and reserved_delta <= on_hand_delta
        and on_hand_delta + issued_delta > 0
      when 'receipt' then
        on_hand_delta > 0 and reserved_delta = 0 and issued_delta = 0
      when 'allocation_reserved' then
        on_hand_delta = 0 and reserved_delta > 0 and issued_delta = 0
      when 'allocation_released' then
        on_hand_delta = 0 and reserved_delta < 0 and issued_delta = 0
      when 'fulfilment_issued' then
        on_hand_delta < 0
        and reserved_delta = on_hand_delta
        and issued_delta = -on_hand_delta
      when 'fulfilment_reversed_ready' then
        on_hand_delta > 0
        and reserved_delta = on_hand_delta
        and issued_delta = -on_hand_delta
      when 'fulfilment_reversed_backorder' then
        on_hand_delta > 0
        and reserved_delta = 0
        and issued_delta = -on_hand_delta
      when 'adjustment_in' then
        on_hand_delta > 0 and reserved_delta = 0 and issued_delta = 0
      when 'adjustment_out' then
        on_hand_delta < 0 and reserved_delta = 0 and issued_delta = 0
      else false
    end
  )
);

create index inventory_movements_balance_idx
  on app.inventory_movements(season_id, article_variant_id, occurred_at, id);
create index inventory_movements_source_idx
  on app.inventory_movements(source_type, source_id);

create table private.inventory_legacy_reconciliation (
  id uuid primary key default gen_random_uuid(),
  receipt_line_id uuid not null unique
    references app.delivery_receipt_lines(id) on delete restrict,
  article_id uuid not null references app.articles(id) on delete restrict,
  article_variant_id uuid not null,
  review_season_id uuid references app.seasons(id) on delete restrict,
  legacy_received integer not null check (legacy_received > 0),
  legacy_reserved integer not null check (legacy_reserved >= 0),
  legacy_issued integer not null check (legacy_issued >= 0),
  unassigned_quantity integer not null check (unassigned_quantity >= 0),
  discrepancy_quantity integer not null,
  source_hash text not null check (source_hash ~ '^[0-9a-f]{64}$'),
  status app.inventory_reconciliation_status not null,
  reconciled_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  reconciled_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  foreign key (article_variant_id, article_id)
    references app.article_variants(id, article_id) on delete restrict,
  constraint inventory_legacy_reconciliation_state_check check (
    (
      status = 'pending'
      and unassigned_quantity > 0
      and discrepancy_quantity = 0
      and reconciled_by is null
      and reconciled_at is null
    )
    or (
      status = 'assigned'
      and unassigned_quantity > 0
      and discrepancy_quantity = 0
      and reconciled_by is not null
      and reconciled_at is not null
    )
    or (
      status = 'zero'
      and unassigned_quantity = 0
      and discrepancy_quantity = 0
      and reconciled_by is null
      and reconciled_at is null
    )
    or (
      status = 'discrepancy'
      and discrepancy_quantity <> 0
      and reconciled_by is null
      and reconciled_at is null
    )
  )
);

create index inventory_legacy_reconciliation_queue_idx
  on private.inventory_legacy_reconciliation(status, review_season_id, created_at);

create table private.inventory_legacy_assignments (
  id uuid primary key default gen_random_uuid(),
  reconciliation_id uuid not null
    references private.inventory_legacy_reconciliation(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  request_id uuid not null unique,
  reason text not null check (
    reason = btrim(reason)
    and length(reason) between 4 and 500
  ),
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  movement_id uuid not null unique
    references app.inventory_movements(id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now())
);

create index inventory_legacy_assignments_candidate_idx
  on private.inventory_legacy_assignments(reconciliation_id, created_at, id);

create table private.inventory_allocation_queue (
  season_id uuid not null references app.seasons(id) on delete restrict,
  article_variant_id uuid not null references app.article_variants(id) on delete restrict,
  status app.inventory_queue_status not null default 'queued',
  reason_code text not null check (
    reason_code ~ '^[a-z][a-z0-9._-]{2,79}$'
  ),
  attempts integer not null default 0 check (attempts between 0 and 1000),
  last_error_code text,
  queued_at timestamptz not null default timezone('utc', now()),
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default timezone('utc', now()),
  primary key (season_id, article_variant_id)
);

-- Journal and event stores are append-only. Projection mutation is restricted
-- to private adapters through a transaction-local guard.
create or replace function private.reject_inventory_event_mutation()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  raise exception 'INVENTORY_EVENT_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger inventory_movements_immutable
before update or delete on app.inventory_movements
for each row execute function private.reject_inventory_event_mutation();
create trigger inventory_allocation_events_immutable
before update or delete on app.inventory_allocation_events
for each row execute function private.reject_inventory_event_mutation();
create trigger inventory_command_requests_immutable
before update or delete on private.inventory_command_requests
for each row execute function private.reject_inventory_event_mutation();
create trigger inventory_legacy_assignments_immutable
before update or delete on private.inventory_legacy_assignments
for each row execute function private.reject_inventory_event_mutation();

create or replace function private.guard_inventory_allocation_projection()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if current_setting('app.inventory_internal', true) <> 'on' then
    raise exception 'INVENTORY_PROJECTION_MUTATION_DENIED' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'INVENTORY_PROJECTION_DELETE_DENIED' using errcode = '23514';
  end if;
  if old.season_id is distinct from new.season_id
    or old.member_id is distinct from new.member_id
    or old.member_season_id is distinct from new.member_season_id
    or old.order_id is distinct from new.order_id
    or old.order_line_id is distinct from new.order_line_id
    or old.article_id is distinct from new.article_id
    or old.article_variant_id is distinct from new.article_variant_id
    or old.quantity is distinct from new.quantity
    or old.legacy_reservation_id is distinct from new.legacy_reservation_id
    or old.created_at is distinct from new.created_at
  then
    raise exception 'INVENTORY_ALLOCATION_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger inventory_allocations_guard_projection
before update or delete on app.inventory_allocations
for each row execute function private.guard_inventory_allocation_projection();

create or replace function private.enforce_inventory_nonnegative()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  balance_on_hand bigint;
  balance_reserved bigint;
  balance_issued bigint;
begin
  select
    coalesce(sum(movement.on_hand_delta), 0),
    coalesce(sum(movement.reserved_delta), 0),
    coalesce(sum(movement.issued_delta), 0)
  into balance_on_hand, balance_reserved, balance_issued
  from app.inventory_movements movement
  where movement.season_id = new.season_id
    and movement.article_variant_id = new.article_variant_id;

  if balance_on_hand < 0
    or balance_reserved < 0
    or balance_issued < 0
    or balance_on_hand - balance_reserved < 0
  then
    raise exception 'INVENTORY_BALANCE_NEGATIVE' using errcode = '23514';
  end if;
  return null;
end;
$$;

create constraint trigger inventory_movements_nonnegative
after insert on app.inventory_movements
deferrable initially immediate
for each row execute function private.enforce_inventory_nonnegative();

revoke all on function private.reject_inventory_event_mutation()
from public, anon, authenticated, service_role;
revoke all on function private.guard_inventory_allocation_projection()
from public, anon, authenticated, service_role;
revoke all on function private.enforce_inventory_nonnegative()
from public, anon, authenticated, service_role;

create or replace function private.inventory_balance(
  p_season_id uuid,
  p_variant_id uuid
)
returns table (
  on_hand bigint,
  reserved bigint,
  issued bigint,
  available bigint
)
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select
    coalesce(sum(movement.on_hand_delta), 0)::bigint,
    coalesce(sum(movement.reserved_delta), 0)::bigint,
    coalesce(sum(movement.issued_delta), 0)::bigint,
    (
      coalesce(sum(movement.on_hand_delta), 0)
      - coalesce(sum(movement.reserved_delta), 0)
    )::bigint
  from app.inventory_movements movement
  where movement.season_id = p_season_id
    and movement.article_variant_id = p_variant_id;
$$;

revoke all on function private.inventory_balance(uuid, uuid)
from public, anon, authenticated, service_role;

-- Abort on structural corruption. Business-rule conflicts remain losslessly
-- represented as review-required allocations.
do $$
begin
  if exists(
    select 1
    from app.inventory_reservations reservation
    join app.delivery_receipt_lines receipt_line
      on receipt_line.id = reservation.receipt_line_id
    join app.order_lines order_line on order_line.id = reservation.order_line_id
    where receipt_line.article_variant_id <> order_line.article_variant_id
      or reservation.quantity <> order_line.quantity
  ) then
    raise exception 'LEGACY_INVENTORY_RESERVATION_STRUCTURE_MISMATCH';
  end if;

  if exists(
    select 1
    from app.delivery_receipt_lines receipt_line
    left join lateral (
      select coalesce(sum(reservation.quantity), 0) quantity
      from app.inventory_reservations reservation
      where reservation.receipt_line_id = receipt_line.id
        and reservation.status in ('reserved', 'fulfilled')
    ) used on true
    where used.quantity > receipt_line.received_quantity
  ) then
    raise exception 'LEGACY_INVENTORY_OVERCONSUMED';
  end if;

  if exists(
    select 1
    from app.inventory_reservations reservation
    left join app.fulfilment_lines fulfilment_line
      on fulfilment_line.reservation_id = reservation.id
      and fulfilment_line.reversed_at is null
    where (
      reservation.status = 'fulfilled'
      and (
        fulfilment_line.id is null
        or fulfilment_line.order_line_id <> reservation.order_line_id
        or fulfilment_line.quantity <> reservation.quantity
      )
    )
    or (
      reservation.status <> 'fulfilled'
      and fulfilment_line.id is not null
    )
  ) then
    raise exception 'LEGACY_INVENTORY_FULFILMENT_STRUCTURE_MISMATCH';
  end if;

  if exists(
    select reservation.id
    from app.inventory_reservations reservation
    join app.fulfilment_lines fulfilment_line
      on fulfilment_line.reservation_id = reservation.id
      and fulfilment_line.reversed_at is null
    group by reservation.id
    having count(*) <> 1
  ) then
    raise exception 'LEGACY_INVENTORY_MULTIPLE_ACTIVE_FULFILMENTS';
  end if;
end;
$$;

-- Every legacy reservation receives a lossless projection, including released
-- history. Only proven paid and size-valid active facts are marked resolved.
insert into app.inventory_allocations(
  season_id,
  member_id,
  member_season_id,
  order_id,
  order_line_id,
  article_id,
  article_variant_id,
  quantity,
  status,
  reconciliation_status,
  allocation_mode,
  paid_at,
  size_valid_at,
  priority_at,
  product_name_snapshot,
  size_snapshot,
  legacy_reservation_id,
  allocated_at,
  fulfilled_at,
  released_at,
  allocated_by,
  fulfilled_by,
  released_by,
  release_reason
)
select
  orders.season_id,
  orders.member_id,
  orders.member_season_id,
  orders.id,
  order_line.id,
  order_line.article_id,
  order_line.article_variant_id,
  reservation.quantity,
  reservation.status::text::app.inventory_allocation_status,
  case
    when reservation.status = 'released' then
      'resolved'::app.inventory_allocation_reconciliation
    when member_season.reconciliation_status = 'resolved'
      and paid.paid_at is not null
      and paid.reconciliation_issue is null
      and size_profile.article_variant_id = order_line.article_variant_id
      and size_profile.selection_status in ('confirmed', 'locked')
      and size_profile.confirmed_at is not null
      and paid.paid_at <= coalesce(reservation.created_at, timezone('utc', now()))
      and (
        (
          reservation.status = 'reserved'
          and order_line.status = 'ready_for_pickup'
          and fulfilment_line.id is null
        )
        or (
          reservation.status = 'fulfilled'
          and order_line.status = 'picked_up'
          and fulfilment_line.id is not null
        )
      )
    then 'resolved'::app.inventory_allocation_reconciliation
    else 'review_required'::app.inventory_allocation_reconciliation
  end,
  'legacy_preserved',
  paid.paid_at,
  size_profile.confirmed_at,
  case
    when paid.paid_at is not null and size_profile.confirmed_at is not null
    then greatest(paid.paid_at, size_profile.confirmed_at)
    else null
  end,
  order_line.product_name_snapshot,
  order_line.size_snapshot,
  reservation.id,
  reservation.created_at,
  case
    when reservation.status = 'fulfilled'
    then coalesce(fulfilment_line.created_at, reservation.updated_at)
    else null
  end,
  case
    when reservation.status = 'released'
    then reservation.updated_at
    else null
  end,
  reservation_staff.auth_user_id,
  case
    when reservation.status = 'fulfilled'
    then fulfilment_staff.auth_user_id
    else null
  end,
  case
    when reservation.status = 'released'
    then reservation_staff.auth_user_id
    else null
  end,
  case
    when reservation.status = 'released'
    then 'Legacy vrijgave vóór journaaltransitie'
    else null
  end
from app.inventory_reservations reservation
join app.order_lines order_line on order_line.id = reservation.order_line_id
join app.member_orders orders on orders.id = order_line.order_id
join app.member_seasons member_season
  on member_season.id = orders.member_season_id
left join lateral (
  select payment.paid_at, payment.reconciliation_issue
  from app.payments payment
  where payment.order_id = orders.id
    and payment.status = 'paid'
  order by payment.paid_at, payment.created_at, payment.id
  limit 1
) paid on true
left join app.member_article_sizes size_profile
  on size_profile.member_season_id = orders.member_season_id
  and size_profile.article_id = order_line.article_id
left join app.fulfilment_lines fulfilment_line
  on fulfilment_line.reservation_id = reservation.id
  and fulfilment_line.reversed_at is null
left join app.fulfilments fulfilment
  on fulfilment.id = fulfilment_line.fulfilment_id
left join app.staff_profiles reservation_staff
  on reservation_staff.auth_user_id = reservation.actor_user_id
left join app.staff_profiles fulfilment_staff
  on fulfilment_staff.auth_user_id = fulfilment.actor_user_id;

insert into app.inventory_allocation_events(
  allocation_id,
  event_type,
  previous_status,
  next_status,
  reason_code,
  source_type,
  source_id,
  idempotency_key,
  actor_user_id,
  safe_context,
  created_at
)
select
  allocation.id,
  'legacy_preserved',
  null,
  allocation.status,
  case
    when allocation.reconciliation_status = 'resolved'
    then 'legacy.inventory_preserved'
    else 'legacy.inventory_review_required'
  end,
  'inventory_reservation',
  allocation.legacy_reservation_id,
  encode(
    extensions.digest(
      'legacy-allocation-event:' || allocation.legacy_reservation_id::text,
      'sha256'
    ),
    'hex'
  ),
  allocation.allocated_by,
  jsonb_build_object(
    'allocationId', allocation.id,
    'orderItemId', allocation.order_line_id,
    'quantity', allocation.quantity
  ),
  allocation.created_at
from app.inventory_allocations allocation
where allocation.legacy_reservation_id is not null;

-- Reserved legacy stock is still on hand; fulfilled stock was issued before
-- the journal epoch. Both facts are recorded without touching legacy rows.
insert into app.inventory_movements(
  season_id,
  article_id,
  article_variant_id,
  movement_type,
  on_hand_delta,
  reserved_delta,
  issued_delta,
  allocation_id,
  source_type,
  source_id,
  reason_code,
  idempotency_key,
  actor_user_id,
  safe_context,
  occurred_at
)
select
  allocation.season_id,
  allocation.article_id,
  allocation.article_variant_id,
  'opening_balance',
  case when allocation.status = 'reserved' then allocation.quantity else 0 end,
  case when allocation.status = 'reserved' then allocation.quantity else 0 end,
  case when allocation.status = 'fulfilled' then allocation.quantity else 0 end,
  allocation.id,
  'inventory_reservation',
  allocation.legacy_reservation_id,
  'legacy.inventory_opening',
  encode(
    extensions.digest(
      'legacy-inventory-opening:' || allocation.legacy_reservation_id::text,
      'sha256'
    ),
    'hex'
  ),
  allocation.allocated_by,
  jsonb_build_object(
    'allocationId', allocation.id,
    'orderItemId', allocation.order_line_id,
    'quantity', allocation.quantity
  ),
  coalesce(allocation.allocated_at, allocation.created_at)
from app.inventory_allocations allocation
where allocation.legacy_reservation_id is not null
  and allocation.status in ('reserved', 'fulfilled');

insert into private.inventory_legacy_reconciliation(
  receipt_line_id,
  article_id,
  article_variant_id,
  review_season_id,
  legacy_received,
  legacy_reserved,
  legacy_issued,
  unassigned_quantity,
  discrepancy_quantity,
  source_hash,
  status
)
select
  receipt_line.id,
  variant.article_id,
  receipt_line.article_variant_id,
  case
    when receipt_line.received_quantity - used.reserved - used.issued > 0
    then settings.active_season_id
    else null
  end,
  receipt_line.received_quantity,
  used.reserved,
  used.issued,
  greatest(
    receipt_line.received_quantity - used.reserved - used.issued,
    0
  ),
  least(
    receipt_line.received_quantity - used.reserved - used.issued,
    0
  ),
  encode(
    extensions.digest(
      concat_ws(
        '|',
        'legacy-receipt-line-v1',
        receipt_line.id::text,
        receipt_line.article_variant_id::text,
        receipt_line.received_quantity::text,
        used.reserved::text,
        used.issued::text
      ),
      'sha256'
    ),
    'hex'
  ),
  case
    when receipt_line.received_quantity - used.reserved - used.issued < 0
      then 'discrepancy'::app.inventory_reconciliation_status
    when receipt_line.received_quantity - used.reserved - used.issued = 0
      then 'zero'::app.inventory_reconciliation_status
    else 'pending'::app.inventory_reconciliation_status
  end
from app.delivery_receipt_lines receipt_line
join app.article_variants variant on variant.id = receipt_line.article_variant_id
cross join app.app_settings settings
left join lateral (
  select
    coalesce(sum(reservation.quantity) filter (
      where reservation.status = 'reserved'
    ), 0)::integer reserved,
    coalesce(sum(reservation.quantity) filter (
      where reservation.status = 'fulfilled'
    ), 0)::integer issued
  from app.inventory_reservations reservation
  where reservation.receipt_line_id = receipt_line.id
) used on true
where settings.id = true;

do $$
begin
  if exists(
    select 1
    from private.inventory_legacy_reconciliation candidate
    where candidate.status = 'pending'
      and candidate.review_season_id is null
  ) then
    raise exception 'LEGACY_INVENTORY_REVIEW_SEASON_REQUIRED';
  end if;
end;
$$;

-- Reconciliation conflicts are action items, never guessed repairs.
select private.open_action_item(
  'legacy_inventory_unassigned',
  candidate.review_season_id,
  'inventory_reconciliation',
  candidate.id,
  'delivery_receipt_line',
  candidate.receipt_line_id,
  encode(
    extensions.digest(
      'legacy-inventory-unassigned:' || candidate.id::text,
      'sha256'
    ),
    'hex'
  ),
  'critical',
  'admin_only',
  'legacy.inventory_unassigned',
  jsonb_build_object(
    'reconciliationCandidateId', candidate.id,
    'receiptLineId', candidate.receipt_line_id,
    'variantId', candidate.article_variant_id,
    'quantity', candidate.unassigned_quantity,
    'blocked', true
  ),
  null
)
from private.inventory_legacy_reconciliation candidate
where candidate.status = 'pending';

select private.open_action_item(
  'allocation_conflict',
  allocation.season_id,
  'inventory_allocation',
  allocation.id,
  'inventory_reservation',
  allocation.legacy_reservation_id,
  encode(
    extensions.digest(
      'legacy-allocation-review:' || allocation.id::text,
      'sha256'
    ),
    'hex'
  ),
  'critical',
  'admin_only',
  'legacy.allocation_review_required',
  jsonb_build_object(
    'allocationId', allocation.id,
    'orderItemId', allocation.order_line_id,
    'variantId', allocation.article_variant_id,
    'quantity', allocation.quantity,
    'blocked', true
  ),
  null
)
from app.inventory_allocations allocation
where allocation.reconciliation_status = 'review_required';

-- RLS is closed by default. Application mutations only use reviewed RPCs.
alter table app.inventory_settings enable row level security;
alter table app.inventory_delivery_drafts enable row level security;
alter table app.inventory_delivery_draft_lines enable row level security;
alter table app.inventory_allocations enable row level security;
alter table app.inventory_allocation_events enable row level security;
alter table app.inventory_movements enable row level security;
alter table private.inventory_command_requests enable row level security;
alter table private.inventory_legacy_reconciliation enable row level security;
alter table private.inventory_legacy_assignments enable row level security;
alter table private.inventory_allocation_queue enable row level security;

create policy "operations can read inventory settings"
on app.inventory_settings
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "operations can read delivery drafts"
on app.inventory_delivery_drafts
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "operations can read delivery draft lines"
on app.inventory_delivery_draft_lines
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "operations can read inventory allocations"
on app.inventory_allocations
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "operations can read inventory allocation events"
on app.inventory_allocation_events
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

create policy "operations can read inventory movements"
on app.inventory_movements
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

revoke all on table app.inventory_settings
from public, anon, authenticated, service_role;
revoke all on table app.inventory_delivery_drafts
from public, anon, authenticated, service_role;
revoke all on table app.inventory_delivery_draft_lines
from public, anon, authenticated, service_role;
revoke all on table app.inventory_allocations
from public, anon, authenticated, service_role;
revoke all on table app.inventory_allocation_events
from public, anon, authenticated, service_role;
revoke all on table app.inventory_movements
from public, anon, authenticated, service_role;
revoke all on table private.inventory_command_requests
from public, anon, authenticated, service_role;
revoke all on table private.inventory_legacy_reconciliation
from public, anon, authenticated, service_role;
revoke all on table private.inventory_legacy_assignments
from public, anon, authenticated, service_role;
revoke all on table private.inventory_allocation_queue
from public, anon, authenticated, service_role;

grant select on table app.inventory_settings to authenticated;
grant select on table app.inventory_delivery_drafts to authenticated;
grant select on table app.inventory_delivery_draft_lines to authenticated;
grant select on table app.inventory_allocations to authenticated;
grant select on table app.inventory_allocation_events to authenticated;
grant select on table app.inventory_movements to authenticated;
