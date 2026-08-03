-- Allocation-gated QR exchange and journal-driven fulfilment.
--
-- A QR locator identifies an order but never authorizes issuance. Only a
-- currently authenticated staff application session can exchange a locator
-- for a short-lived, single-use grant. The scanner response deliberately
-- contains only the member's first name and registered gender.

-- Logistics state transitions do not alter the immutable commercial package
-- snapshot. Only a real legacy component change (including cancellation)
-- creates a new pre-settlement snapshot.
create or replace function app.refresh_legacy_package_snapshot_from_lines()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order_id uuid := case
    when tg_op = 'DELETE' then old.order_id
    else new.order_id
  end;
  target_order app.member_orders%rowtype;
  snapshot_id uuid;
begin
  if tg_op = 'UPDATE'
    and old.order_id = new.order_id
    and old.article_id = new.article_id
    and old.article_variant_id = new.article_variant_id
    and old.quantity = new.quantity
    and (old.status = 'cancelled') = (new.status = 'cancelled')
  then
    return new;
  end if;

  select * into target_order
  from app.member_orders
  where id = target_order_id
  for update;
  if not found or target_order.package_revision_id is not null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  snapshot_id := private.create_order_package_snapshot(
    target_order.id,
    target_order.member_season_id,
    target_order.season_id,
    target_order.amount_due_cents,
    null,
    'Nieuwe legacy snapshot na wijziging van bestelregels'
  );

  insert into app.order_package_snapshot_items(
    snapshot_id,
    order_line_id,
    article_id,
    article_variant_id,
    quantity,
    product_name_snapshot,
    product_code_snapshot,
    variant_label_snapshot,
    size_snapshot,
    sort_order
  )
  select
    snapshot_id,
    line.id,
    line.article_id,
    line.article_variant_id,
    line.quantity,
    line.product_name_snapshot,
    line.product_code_snapshot,
    line.size_snapshot,
    line.size_snapshot,
    article.sort_order
  from app.order_lines line
  join app.articles article on article.id = line.article_id
  where line.order_id = target_order.id
    and line.status <> 'cancelled';

  perform set_config('app.package_snapshot_internal', 'on', true);
  update app.member_orders
  set active_package_snapshot_id = snapshot_id
  where id = target_order.id;
  perform set_config('app.package_snapshot_internal', 'off', true);
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function app.refresh_legacy_package_snapshot_from_lines()
from public, anon, authenticated, service_role;

alter table app.member_seasons
  add constraint member_seasons_id_season_unique
    unique (id, season_id);

create table private.qr_order_identities (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique,
  member_season_id uuid not null,
  season_id uuid not null references app.seasons(id) on delete restrict,
  last_generation integer not null default 0 check (last_generation >= 0),
  suspended_at timestamptz,
  suspended_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  suspension_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  foreign key (order_id, member_season_id)
    references app.member_orders(id, member_season_id) on delete restrict,
  foreign key (member_season_id, season_id)
    references app.member_seasons(id, season_id) on delete restrict,
  unique (id, order_id),
  constraint qr_order_identity_suspension_check check (
    (
      suspended_at is null
      and suspended_by is null
      and suspension_reason is null
    )
    or (
      suspended_at is not null
      and suspension_reason is not null
      and length(btrim(suspension_reason)) between 4 and 500
    )
  )
);

create table private.qr_order_locators (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null
    references private.qr_order_identities(id) on delete restrict,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  generation integer not null check (generation > 0),
  key_version integer not null check (key_version between 1 and 9999),
  derivation_nonce text not null check (
    derivation_nonce ~ '^[A-Za-z0-9_-]{43}$'
  ),
  pepper_fingerprint text not null check (
    pepper_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  locator_hash text not null unique check (
    locator_hash ~ '^[0-9a-f]{64}$'
  ),
  active boolean not null default true,
  created_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now()),
  revoked_at timestamptz,
  revoked_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  revocation_reason text,
  unique (derivation_nonce),
  unique (identity_id, generation),
  unique (id, order_id),
  foreign key (identity_id, order_id)
    references private.qr_order_identities(id, order_id) on delete restrict,
  constraint qr_order_locator_lifecycle_check check (
    (
      active
      and revoked_at is null
      and revoked_by is null
      and revocation_reason is null
    )
    or (
      not active
      and revoked_at is not null
      and revocation_reason is not null
      and length(btrim(revocation_reason)) between 4 and 500
    )
  )
);

create unique index qr_order_locators_one_active_identity_idx
  on private.qr_order_locators(identity_id)
  where active;

create table private.qr_scan_grants (
  id uuid primary key default gen_random_uuid(),
  locator_id uuid not null
    references private.qr_order_locators(id) on delete restrict,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  staff_session_hash text not null check (
    staff_session_hash ~ '^[0-9a-f]{64}$'
  ),
  exchange_request_id uuid not null unique,
  exchange_request_hash text not null check (
    exchange_request_hash ~ '^[0-9a-f]{64}$'
  ),
  key_version integer not null check (key_version between 1 and 9999),
  grant_hash text not null unique check (
    grant_hash ~ '^[0-9a-f]{64}$'
  ),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_by_fulfilment_id uuid,
  revoked_at timestamptz,
  revocation_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  constraint qr_scan_grant_lifecycle_check check (
    not (
      consumed_at is not null
      and revoked_at is not null
    )
    and (
      revoked_at is null
      or (
        revocation_reason is not null
        and length(btrim(revocation_reason)) between 4 and 160
      )
    )
  ),
  constraint qr_scan_grant_expiry_check check (
    expires_at > created_at
    and expires_at <= created_at + interval '2 minutes 5 seconds'
  ),
  foreign key (locator_id, order_id)
    references private.qr_order_locators(id, order_id) on delete restrict
);

create index qr_scan_grants_active_lookup_idx
  on private.qr_scan_grants(grant_hash, expires_at)
  where consumed_at is null and revoked_at is null;
create index qr_scan_grants_session_idx
  on private.qr_scan_grants(staff_session_hash, created_at desc);

create table private.qr_identity_commands (
  request_id uuid primary key,
  command_type text not null check (
    command_type in ('provision', 'rotate', 'revoke')
  ),
  order_id uuid not null references app.member_orders(id) on delete restrict,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  locator_id uuid references private.qr_order_locators(id) on delete restrict,
  actor_user_id uuid references app.staff_profiles(auth_user_id) on delete restrict,
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
      'locator',
      'locator_hash',
      'grant',
      'grant_hash'
    ]
  ),
  created_at timestamptz not null default timezone('utc', now())
);

alter table app.fulfilments
  add column member_season_id uuid,
  add column season_id uuid,
  add column request_id uuid,
  add column scan_grant_id uuid;

create or replace function private.populate_fulfilment_scope()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  order_scope record;
begin
  select orders.member_season_id, orders.season_id
  into order_scope
  from app.member_orders orders
  where orders.id = new.order_id;
  if not found then
    raise exception 'FULFILMENT_ORDER_NOT_FOUND' using errcode = '23503';
  end if;
  new.member_season_id := coalesce(
    new.member_season_id,
    order_scope.member_season_id
  );
  new.season_id := coalesce(new.season_id, order_scope.season_id);
  if new.member_season_id is distinct from order_scope.member_season_id
    or new.season_id is distinct from order_scope.season_id
  then
    raise exception 'FULFILMENT_SCOPE_MISMATCH' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function private.populate_fulfilment_scope()
from public, anon, authenticated, service_role;

create trigger fulfilments_populate_scope
before insert or update of order_id, member_season_id, season_id
on app.fulfilments
for each row execute function private.populate_fulfilment_scope();

update app.fulfilments fulfilment
set member_season_id = orders.member_season_id,
    season_id = orders.season_id
from app.member_orders orders
where orders.id = fulfilment.order_id;

alter table app.fulfilments
  alter column member_season_id set not null,
  alter column season_id set not null,
  add constraint fulfilments_order_member_season_fkey
    foreign key (order_id, member_season_id)
    references app.member_orders(id, member_season_id) on delete restrict,
  add constraint fulfilments_member_season_season_fkey
    foreign key (member_season_id, season_id)
    references app.member_seasons(id, season_id) on delete restrict,
  add constraint fulfilments_request_id_unique unique (request_id),
  add constraint fulfilments_scan_grant_id_unique unique (scan_grant_id),
  add constraint fulfilments_scan_contract_check check (
    (request_id is null and scan_grant_id is null)
    or (request_id is not null and scan_grant_id is not null)
  ),
  add constraint fulfilments_scan_grant_fkey
    foreign key (scan_grant_id)
    references private.qr_scan_grants(id) on delete restrict;

alter table private.qr_scan_grants
  add constraint qr_scan_grants_consumed_fulfilment_fkey
    foreign key (consumed_by_fulfilment_id)
    references app.fulfilments(id) on delete restrict,
  add constraint qr_scan_grants_consumption_check check (
    (consumed_at is null and consumed_by_fulfilment_id is null)
    or (consumed_at is not null and consumed_by_fulfilment_id is not null)
  );

alter table app.fulfilment_lines
  add column inventory_allocation_id uuid;

update app.fulfilment_lines fulfilment_line
set inventory_allocation_id = allocation.id
from app.inventory_allocations allocation
where allocation.legacy_reservation_id = fulfilment_line.reservation_id;

do $$
begin
  if exists(
    select 1
    from app.fulfilment_lines fulfilment_line
    where fulfilment_line.inventory_allocation_id is null
  ) then
    raise exception 'QR_V2_FULFILMENT_ALLOCATION_BACKFILL_BLOCKED';
  end if;
end;
$$;

alter table app.fulfilment_lines
  alter column reservation_id drop not null,
  add constraint fulfilment_lines_inventory_allocation_fkey
    foreign key (inventory_allocation_id)
    references app.inventory_allocations(id) on delete restrict,
  add constraint fulfilment_lines_inventory_source_check check (
    reservation_id is not null
    or inventory_allocation_id is not null
  );

create unique index fulfilment_one_active_allocation_idx
  on app.fulfilment_lines(inventory_allocation_id)
  where reversed_at is null;
create unique index inventory_movement_one_issue_fulfilment_line_idx
  on app.inventory_movements(fulfilment_line_id)
  where movement_type = 'fulfilment_issued';

create table private.fulfilment_command_requests (
  request_id uuid primary key,
  fulfilment_id uuid not null unique
    references app.fulfilments(id) on delete restrict,
  scan_grant_id uuid not null unique
    references private.qr_scan_grants(id) on delete restrict,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  staff_session_hash text not null check (
    staff_session_hash ~ '^[0-9a-f]{64}$'
  ),
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
      'locator',
      'locator_hash',
      'grant',
      'grant_hash',
      'order_id'
    ]
  ),
  created_at timestamptz not null default timezone('utc', now())
);

create table private.fulfilment_correction_requests (
  request_id uuid primary key,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  actor_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  staff_session_hash text not null check (
    staff_session_hash ~ '^[0-9a-f]{64}$'
  ),
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
      'locator',
      'locator_hash',
      'grant',
      'grant_hash'
    ]
  ),
  created_at timestamptz not null default timezone('utc', now())
);

create table private.fulfilment_notification_events (
  id uuid primary key default gen_random_uuid(),
  fulfilment_id uuid not null unique
    references app.fulfilments(id) on delete restrict,
  order_id uuid not null references app.member_orders(id) on delete restrict,
  member_season_id uuid not null,
  season_id uuid not null references app.seasons(id) on delete restrict,
  event_type text not null check (
    event_type in ('partial_pickup', 'package_complete')
  ),
  idempotency_key text not null unique check (
    idempotency_key ~ '^[0-9a-f]{64}$'
  ),
  payload_snapshot jsonb not null check (
    jsonb_typeof(payload_snapshot) = 'object'
    and octet_length(payload_snapshot::text) <= 32000
    and not payload_snapshot ?| array[
      'email',
      'recipient',
      'name',
      'member_name',
      'first_name',
      'last_name',
      'date_of_birth',
      'relation_number',
      'team',
      'token',
      'token_hash',
      'locator',
      'locator_hash',
      'grant',
      'grant_hash'
    ]
  ),
  created_at timestamptz not null default timezone('utc', now()),
  foreign key (order_id, member_season_id)
    references app.member_orders(id, member_season_id) on delete restrict,
  foreign key (member_season_id, season_id)
    references app.member_seasons(id, season_id) on delete restrict
);

alter table private.qr_order_identities enable row level security;
alter table private.qr_order_locators enable row level security;
alter table private.qr_scan_grants enable row level security;
alter table private.qr_identity_commands enable row level security;
alter table private.fulfilment_command_requests enable row level security;
alter table private.fulfilment_correction_requests enable row level security;
alter table private.fulfilment_notification_events enable row level security;

revoke all on table
  private.qr_order_identities,
  private.qr_order_locators,
  private.qr_scan_grants,
  private.qr_identity_commands,
  private.fulfilment_command_requests,
  private.fulfilment_correction_requests,
  private.fulfilment_notification_events
from public, anon, authenticated, service_role;

create or replace function private.reject_qr_event_mutation()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  raise exception 'QR_EVENT_IMMUTABLE' using errcode = '23514';
end;
$$;

create trigger qr_identity_commands_immutable
before update or delete on private.qr_identity_commands
for each row execute function private.reject_qr_event_mutation();
create trigger fulfilment_command_requests_immutable
before update or delete on private.fulfilment_command_requests
for each row execute function private.reject_qr_event_mutation();
create trigger fulfilment_correction_requests_immutable
before update or delete on private.fulfilment_correction_requests
for each row execute function private.reject_qr_event_mutation();
create trigger fulfilment_notification_events_immutable
before update or delete on private.fulfilment_notification_events
for each row execute function private.reject_qr_event_mutation();

create or replace function private.guard_qr_identity_projection()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if current_setting('app.qr_internal', true) <> 'on' then
    raise exception 'QR_PROJECTION_MUTATION_DENIED' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'QR_PROJECTION_DELETE_DENIED' using errcode = '23514';
  end if;
  if old.order_id is distinct from new.order_id
    or old.member_season_id is distinct from new.member_season_id
    or old.season_id is distinct from new.season_id
    or old.created_at is distinct from new.created_at
  then
    raise exception 'QR_IDENTITY_BINDING_IMMUTABLE' using errcode = '23514';
  end if;
  if new.last_generation < old.last_generation then
    raise exception 'QR_GENERATION_MONOTONIC' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger qr_order_identities_guard
before update or delete on private.qr_order_identities
for each row execute function private.guard_qr_identity_projection();

create or replace function private.guard_qr_locator_projection()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if current_setting('app.qr_internal', true) <> 'on' then
    raise exception 'QR_PROJECTION_MUTATION_DENIED' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'QR_PROJECTION_DELETE_DENIED' using errcode = '23514';
  end if;
  if old.identity_id is distinct from new.identity_id
    or old.order_id is distinct from new.order_id
    or old.generation is distinct from new.generation
    or old.key_version is distinct from new.key_version
    or old.derivation_nonce is distinct from new.derivation_nonce
    or old.pepper_fingerprint is distinct from new.pepper_fingerprint
    or old.locator_hash is distinct from new.locator_hash
    or old.created_by is distinct from new.created_by
    or old.created_at is distinct from new.created_at
    or (not old.active and new.active)
    or (
      old.revoked_at is not null
      and (
        new.revoked_at is distinct from old.revoked_at
        or new.revoked_by is distinct from old.revoked_by
        or new.revocation_reason is distinct from old.revocation_reason
      )
    )
  then
    raise exception 'QR_LOCATOR_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger qr_order_locators_guard
before update or delete on private.qr_order_locators
for each row execute function private.guard_qr_locator_projection();

create or replace function private.guard_qr_scan_grant_projection()
returns trigger
language plpgsql
set search_path = app, private, pg_temp
as $$
begin
  if current_setting('app.qr_internal', true) <> 'on' then
    raise exception 'QR_PROJECTION_MUTATION_DENIED' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    raise exception 'QR_PROJECTION_DELETE_DENIED' using errcode = '23514';
  end if;
  if old.locator_id is distinct from new.locator_id
    or old.order_id is distinct from new.order_id
    or old.actor_user_id is distinct from new.actor_user_id
    or old.staff_session_hash is distinct from new.staff_session_hash
    or old.exchange_request_id is distinct from new.exchange_request_id
    or old.exchange_request_hash is distinct from new.exchange_request_hash
    or old.key_version is distinct from new.key_version
    or old.grant_hash is distinct from new.grant_hash
    or old.expires_at is distinct from new.expires_at
    or old.created_at is distinct from new.created_at
    or (old.consumed_at is not null and new.consumed_at is distinct from old.consumed_at)
    or (
      old.consumed_at is not null
      and new.consumed_by_fulfilment_id
        is distinct from old.consumed_by_fulfilment_id
    )
    or (
      old.revoked_at is not null
      and (
        new.revoked_at is distinct from old.revoked_at
        or new.revocation_reason is distinct from old.revocation_reason
      )
    )
  then
    raise exception 'QR_SCAN_GRANT_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger qr_scan_grants_guard
before update or delete on private.qr_scan_grants
for each row execute function private.guard_qr_scan_grant_projection();

revoke all on function private.reject_qr_event_mutation()
from public, anon, authenticated, service_role;
revoke all on function private.guard_qr_identity_projection()
from public, anon, authenticated, service_role;
revoke all on function private.guard_qr_locator_projection()
from public, anon, authenticated, service_role;
revoke all on function private.guard_qr_scan_grant_projection()
from public, anon, authenticated, service_role;

create or replace function private.staff_app_session_authorized(
  p_actor_id uuid,
  p_staff_session_hash text,
  p_allowed_roles app.staff_role[]
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select
    p_actor_id is not null
    and p_staff_session_hash ~ '^[0-9a-f]{64}$'
    and coalesce(array_length(p_allowed_roles, 1), 0) > 0
    and exists(
      select 1
      from private.staff_sessions session
      join app.staff_profiles profile
        on profile.auth_user_id = session.auth_user_id
        and profile.active
        and profile.role = any(p_allowed_roles)
      where session.token_hash = p_staff_session_hash
        and session.auth_user_id = p_actor_id
        and session.revoked_at is null
        and session.expires_at > timezone('utc', now())
    );
$$;

revoke all on function private.staff_app_session_authorized(
  uuid, text, app.staff_role[]
) from public, anon, authenticated, service_role;

create or replace function private.order_qr_business_eligible(
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
    from app.member_orders orders
    join app.member_seasons member_season
      on member_season.id = orders.member_season_id
      and member_season.member_id = orders.member_id
      and member_season.season_id = orders.season_id
      and member_season.participation_status = 'active'
      and member_season.reconciliation_status = 'resolved'
    join app.seasons season
      on season.id = orders.season_id
      and season.status = 'open'
    join app.app_settings settings
      on settings.id = true
      and settings.active_season_id = orders.season_id
      and length(btrim(coalesce(settings.pickup_location, ''))) between 4 and 240
    join lateral (
      select
        count(*) filter (
          where payment.status = 'paid'
            and payment.reconciliation_issue is null
            and payment.amount_cents = orders.amount_due_cents
            and payment.currency = 'EUR'
            and payment.member_season_id = orders.member_season_id
            and payment.package_snapshot_id = orders.active_package_snapshot_id
        ) paid_count,
        count(*) filter (
          where payment.status = 'duplicate_paid'
            or payment.reconciliation_issue is not null
        ) conflict_count
      from app.payments payment
      where payment.order_id = orders.id
    ) settlement on settlement.paid_count = 1
      and settlement.conflict_count = 0
    where orders.id = p_order_id
      and exists(
        select 1
        from app.inventory_allocations allocation
        join app.order_lines line
          on line.id = allocation.order_line_id
          and line.order_id = allocation.order_id
          and line.article_variant_id = allocation.article_variant_id
          and line.status = 'ready_for_pickup'
          and line.quantity = allocation.quantity
        where allocation.order_id = orders.id
          and allocation.status = 'reserved'
          and allocation.reconciliation_status = 'resolved'
          and allocation.paid_at is not null
          and allocation.size_valid_at is not null
      )
  );
$$;

create or replace function private.order_qr_usable(
  p_order_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select
    private.inventory_v2_enabled()
    and coalesce((
      select flag.enabled
      from app.release_feature_flags flag
      where flag.key = 'scanner_pwa_v2'
    ), false)
    and private.order_qr_business_eligible(p_order_id)
    and exists(
      select 1
      from private.qr_order_identities identity
      join private.qr_order_locators locator
        on locator.identity_id = identity.id
        and locator.active
      where identity.order_id = p_order_id
        and identity.suspended_at is null
    );
$$;

revoke all on function private.order_qr_business_eligible(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.order_qr_usable(uuid)
from public, anon, authenticated, service_role;

create or replace function private.current_qr_locator_generation(
  p_order_id uuid
)
returns integer
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select locator.generation
  from private.qr_order_identities identity
  join private.qr_order_locators locator
    on locator.identity_id = identity.id
    and locator.active
  where identity.order_id = p_order_id
    and identity.suspended_at is null
  limit 1;
$$;

revoke all on function private.current_qr_locator_generation(uuid)
from public, anon, authenticated, service_role;

create or replace function app.list_order_qr_identity_candidates(
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  if p_limit not between 1 and 250 then
    raise exception 'QR_CANDIDATE_LIMIT_INVALID' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'candidates',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'orderId', candidate.order_id,
          'generation', candidate.next_generation,
          'hasActiveLegacy', candidate.has_active_legacy
        )
        order by candidate.order_id
      )
      from (
        select
          orders.id order_id,
          greatest(
            coalesce(identity.last_generation, 0),
            coalesce(legacy.maximum_generation, 0)
          ) + 1 next_generation,
          coalesce(legacy.has_active, false) has_active_legacy
        from app.member_orders orders
        left join private.qr_order_identities identity
          on identity.order_id = orders.id
        left join lateral (
          select
            coalesce(max(token.version), 0) maximum_generation,
            bool_or(token.active) has_active
          from private.qr_tokens token
          where token.order_id = orders.id
        ) legacy on true
        where coalesce(identity.suspended_at is null, true)
          and not exists(
            select 1
            from private.qr_order_locators locator
            where locator.identity_id = identity.id
              and locator.active
          )
          and (
            coalesce(legacy.has_active, false)
            or private.order_qr_business_eligible(orders.id)
          )
        order by orders.id
        limit p_limit
      ) candidate
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.list_order_qr_identity_candidates(integer)
from public, anon, authenticated, service_role;
grant execute on function app.list_order_qr_identity_candidates(integer)
to service_role;

create or replace function app.register_order_qr_locator(
  p_order_id uuid,
  p_generation integer,
  p_key_version integer,
  p_derivation_nonce text,
  p_pepper_fingerprint text,
  p_locator_hash text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
  identity private.qr_order_identities%rowtype;
  locator_id uuid;
  expected_generation integer;
  request_hash text;
  prior private.qr_identity_commands%rowtype;
  result jsonb;
begin
  if p_order_id is null
    or p_generation is null
    or p_generation < 1
    or p_key_version not between 1 and 9999
    or p_derivation_nonce !~ '^[A-Za-z0-9_-]{43}$'
    or p_pepper_fingerprint !~ '^[0-9a-f]{64}$'
    or p_locator_hash !~ '^[0-9a-f]{64}$'
    or p_request_id is null
  then
    raise exception 'QR_PROVISION_INPUT_INVALID' using errcode = '22023';
  end if;
  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'qr-provision-v2',
        p_order_id::text,
        p_generation::text,
        p_key_version::text,
        p_derivation_nonce,
        p_pepper_fingerprint,
        p_locator_hash
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended('qr-command:' || p_request_id::text, 0)
  );
  select * into prior
  from private.qr_identity_commands command
  where command.request_id = p_request_id;
  if found then
    if prior.command_type <> 'provision'
      or prior.order_id <> p_order_id
      or prior.request_hash <> request_hash
    then
      raise exception 'QR_COMMAND_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('qr-order:' || p_order_id::text, 0)
  );
  select * into target_order
  from app.member_orders orders
  where orders.id = p_order_id
  for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into identity
  from private.qr_order_identities current_identity
  where current_identity.order_id = target_order.id
  for update;
  if not found then
    insert into private.qr_order_identities(
      order_id,
      member_season_id,
      season_id
    ) values (
      target_order.id,
      target_order.member_season_id,
      target_order.season_id
    )
    returning * into identity;
  end if;
  if identity.suspended_at is not null then
    raise exception 'QR_IDENTITY_SUSPENDED' using errcode = '55000';
  end if;

  if exists(
    select 1
    from private.qr_order_locators locator
    where locator.identity_id = identity.id
      and locator.active
  ) then
    raise exception 'QR_LOCATOR_ALREADY_ACTIVE' using errcode = '23505';
  end if;

  select greatest(
    identity.last_generation,
    coalesce((
      select max(token.version)
      from private.qr_tokens token
      where token.order_id = target_order.id
    ), 0)
  ) + 1
  into expected_generation;
  if p_generation <> expected_generation then
    raise exception 'QR_GENERATION_STALE' using errcode = '40001';
  end if;

  insert into private.qr_order_locators(
    identity_id,
    order_id,
    generation,
    key_version,
    derivation_nonce,
    pepper_fingerprint,
    locator_hash
  ) values (
    identity.id,
    target_order.id,
    p_generation,
    p_key_version,
    p_derivation_nonce,
    p_pepper_fingerprint,
    p_locator_hash
  )
  returning id into locator_id;

  perform set_config('app.qr_internal', 'on', true);
  update private.qr_order_identities
  set last_generation = p_generation,
      updated_at = timezone('utc', now())
  where id = identity.id;
  update private.qr_tokens
  set active = false,
      revoked_at = coalesce(revoked_at, timezone('utc', now())),
      revocation_reason = coalesce(
        revocation_reason,
        'Gecontroleerd vervangen door QR-locator v2'
      )
  where order_id = target_order.id
    and active;
  perform set_config('app.qr_internal', 'off', true);

  result := jsonb_build_object(
    'orderId', target_order.id,
    'generation', p_generation,
    'keyVersion', p_key_version,
    'status', 'active',
    'reused', false
  );
  insert into private.qr_identity_commands(
    request_id,
    command_type,
    order_id,
    request_hash,
    locator_id,
    result_snapshot
  ) values (
    p_request_id,
    'provision',
    target_order.id,
    request_hash,
    locator_id,
    result
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    null,
    'qr.locator.provisioned',
    'member_order',
    target_order.id,
    jsonb_build_object(
      'generation', p_generation,
      'keyVersion', p_key_version,
      'legacyRevoked', true
    )
  );
  return result;
end;
$$;

revoke all on function app.register_order_qr_locator(
  uuid, integer, integer, text, text, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.register_order_qr_locator(
  uuid, integer, integer, text, text, text, uuid
) to service_role;

create or replace function app.get_order_qr_management_context_v2(
  p_actor_id uuid,
  p_staff_session_hash text,
  p_order_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  identity private.qr_order_identities%rowtype;
  maximum_legacy integer;
begin
  if not private.staff_app_session_authorized(
    p_actor_id,
    p_staff_session_hash,
    array['beheerder', 'kledingcommissie']::app.staff_role[]
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if not exists(
    select 1 from app.member_orders orders where orders.id = p_order_id
  ) then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into identity
  from private.qr_order_identities current_identity
  where current_identity.order_id = p_order_id;
  select coalesce(max(token.version), 0) into maximum_legacy
  from private.qr_tokens token
  where token.order_id = p_order_id;
  return jsonb_build_object(
    'orderId', p_order_id,
    'currentGeneration', private.current_qr_locator_generation(p_order_id),
    'nextGeneration', greatest(
      coalesce(identity.last_generation, 0),
      maximum_legacy
    ) + 1,
    'suspended', identity.suspended_at is not null,
    'businessEligible', private.order_qr_business_eligible(p_order_id)
  );
end;
$$;

revoke all on function app.get_order_qr_management_context_v2(
  uuid, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.get_order_qr_management_context_v2(
  uuid, text, uuid
) to service_role;

create or replace function app.manage_order_qr_locator_v2(
  p_actor_id uuid,
  p_staff_session_hash text,
  p_order_id uuid,
  p_action text,
  p_expected_generation integer,
  p_key_version integer,
  p_derivation_nonce text,
  p_pepper_fingerprint text,
  p_locator_hash text,
  p_reason text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_order app.member_orders%rowtype;
  identity private.qr_order_identities%rowtype;
  current_locator private.qr_order_locators%rowtype;
  locator_id uuid;
  normalized_reason text;
  request_hash text;
  prior private.qr_identity_commands%rowtype;
  maximum_legacy integer;
  result jsonb;
begin
  if not private.staff_app_session_authorized(
    p_actor_id,
    p_staff_session_hash,
    array['beheerder', 'kledingcommissie']::app.staff_role[]
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_order_id is null
    or p_action not in ('rotate', 'revoke')
    or p_expected_generation is null
    or p_expected_generation < 0
    or p_request_id is null
    or length(normalized_reason) not between 4 and 500
    or (
      p_action = 'rotate'
      and (
        p_key_version not between 1 and 9999
        or p_derivation_nonce !~ '^[A-Za-z0-9_-]{43}$'
        or p_pepper_fingerprint !~ '^[0-9a-f]{64}$'
        or p_locator_hash !~ '^[0-9a-f]{64}$'
      )
    )
    or (
      p_action = 'revoke'
      and (
        p_locator_hash is not null
        or p_derivation_nonce is not null
        or p_pepper_fingerprint is not null
        or p_key_version is not null
      )
    )
  then
    raise exception 'QR_MANAGEMENT_INPUT_INVALID' using errcode = '22023';
  end if;
  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'qr-management-v2',
        p_order_id::text,
        p_action,
        normalized_reason
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended('qr-command:' || p_request_id::text, 0)
  );
  select * into prior
  from private.qr_identity_commands command
  where command.request_id = p_request_id;
  if found then
    if prior.command_type <> p_action
      or prior.order_id <> p_order_id
      or prior.actor_user_id <> p_actor_id
      or prior.request_hash <> request_hash
    then
      raise exception 'QR_COMMAND_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('qr-order:' || p_order_id::text, 0)
  );
  select * into target_order
  from app.member_orders orders
  where orders.id = p_order_id
  for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into identity
  from private.qr_order_identities current_identity
  where current_identity.order_id = target_order.id
  for update;
  if not found then
    if p_action = 'revoke' then
      raise exception 'QR_IDENTITY_NOT_FOUND' using errcode = 'P0002';
    end if;
    select coalesce(max(token.version), 0)
    into maximum_legacy
    from private.qr_tokens token
    where token.order_id = target_order.id;
    insert into private.qr_order_identities(
      order_id,
      member_season_id,
      season_id,
      last_generation
    ) values (
      target_order.id,
      target_order.member_season_id,
      target_order.season_id,
      maximum_legacy
    )
    returning * into identity;
  end if;
  select * into current_locator
  from private.qr_order_locators locator
  where locator.identity_id = identity.id
    and locator.active
  for update;
  if coalesce(current_locator.generation, identity.last_generation, 0)
    <> p_expected_generation
  then
    raise exception 'QR_GENERATION_STALE' using errcode = '40001';
  end if;

  perform set_config('app.qr_internal', 'on', true);
  if current_locator.id is not null then
    update private.qr_order_locators
    set active = false,
        revoked_at = timezone('utc', now()),
        revoked_by = p_actor_id,
        revocation_reason = normalized_reason
    where id = current_locator.id;
  end if;
  update private.qr_scan_grants grant_row
  set revoked_at = timezone('utc', now()),
      revocation_reason = 'QR-identiteit gewijzigd'
  where grant_row.order_id = target_order.id
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null;

  if p_action = 'rotate' then
    insert into private.qr_order_locators(
      identity_id,
      order_id,
      generation,
      key_version,
      derivation_nonce,
      pepper_fingerprint,
      locator_hash,
      created_by
    ) values (
      identity.id,
      target_order.id,
      p_expected_generation + 1,
      p_key_version,
      p_derivation_nonce,
      p_pepper_fingerprint,
      p_locator_hash,
      p_actor_id
    )
    returning id into locator_id;
    update private.qr_order_identities
    set last_generation = p_expected_generation + 1,
        suspended_at = null,
        suspended_by = null,
        suspension_reason = null,
        updated_at = timezone('utc', now())
    where id = identity.id;
    update private.qr_tokens
    set active = false,
        revoked_at = coalesce(revoked_at, timezone('utc', now())),
        revoked_by = coalesce(revoked_by, p_actor_id),
        revocation_reason = coalesce(revocation_reason, normalized_reason)
    where order_id = target_order.id
      and active;
    result := jsonb_build_object(
      'orderId', target_order.id,
      'generation', p_expected_generation + 1,
      'status', 'active',
      'reused', false
    );
  else
    update private.qr_order_identities
    set suspended_at = timezone('utc', now()),
        suspended_by = p_actor_id,
        suspension_reason = normalized_reason,
        updated_at = timezone('utc', now())
    where id = identity.id;
    update private.qr_tokens
    set active = false,
        revoked_at = coalesce(revoked_at, timezone('utc', now())),
        revoked_by = coalesce(revoked_by, p_actor_id),
        revocation_reason = coalesce(revocation_reason, normalized_reason)
    where order_id = target_order.id
      and active;
    result := jsonb_build_object(
      'orderId', target_order.id,
      'generation', p_expected_generation,
      'status', 'revoked',
      'reused', false
    );
  end if;
  perform set_config('app.qr_internal', 'off', true);

  insert into private.qr_identity_commands(
    request_id,
    command_type,
    order_id,
    request_hash,
    locator_id,
    actor_user_id,
    result_snapshot
  ) values (
    p_request_id,
    p_action,
    target_order.id,
    request_hash,
    locator_id,
    p_actor_id,
    result
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    p_actor_id,
    case
      when p_action = 'rotate' then 'qr.locator.rotated'
      else 'qr.locator.revoked'
    end,
    'member_order',
    target_order.id,
    jsonb_build_object(
      'generation', case
        when p_action = 'rotate' then p_expected_generation + 1
        else p_expected_generation
      end,
      'reason', normalized_reason
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke all on function app.manage_order_qr_locator_v2(
  uuid, text, uuid, text, integer, integer, text, text, text, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.manage_order_qr_locator_v2(
  uuid, text, uuid, text, integer, integer, text, text, text, text, uuid, uuid
) to service_role;

create or replace function private.fulfilment_scan_workspace(
  p_order_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'status', 'found',
    'member', jsonb_build_object(
      'firstName', member.first_name,
      'gender', member.gender::text
    ),
    'lines', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', line.id,
          'article', line.product_name_snapshot,
          'size', line.size_snapshot,
          'quantity', line.quantity,
          'status', line.status::text
        )
        order by article.sort_order, line.id
      )
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = orders.id
        and line.status <> 'cancelled'
    ), '[]'::jsonb)
  )
  from app.member_orders orders
  join app.members member on member.id = orders.member_id
  where orders.id = p_order_id;
$$;

revoke all on function private.fulfilment_scan_workspace(uuid)
from public, anon, authenticated, service_role;

create or replace function app.exchange_order_qr_locator_v2(
  p_actor_id uuid,
  p_staff_session_hash text,
  p_locator_hash text,
  p_grant_hash text,
  p_grant_key_version integer,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  locator private.qr_order_locators%rowtype;
  identity private.qr_order_identities%rowtype;
  prior private.qr_scan_grants%rowtype;
  request_hash text;
  expires timestamptz;
  workspace jsonb;
begin
  if not private.staff_app_session_authorized(
    p_actor_id,
    p_staff_session_hash,
    array['beheerder', 'uitgifte']::app.staff_role[]
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_locator_hash !~ '^[0-9a-f]{64}$'
    or p_grant_hash !~ '^[0-9a-f]{64}$'
    or p_grant_key_version not between 1 and 9999
    or p_request_id is null
  then
    return jsonb_build_object('status', 'invalid');
  end if;
  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'qr-exchange-v2',
        p_actor_id::text,
        p_staff_session_hash,
        p_locator_hash,
        p_grant_hash,
        p_grant_key_version::text
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended('qr-exchange:' || p_request_id::text, 0)
  );
  select * into prior
  from private.qr_scan_grants grant_row
  where grant_row.exchange_request_id = p_request_id;
  if found then
    if prior.actor_user_id <> p_actor_id
      or prior.staff_session_hash <> p_staff_session_hash
      or prior.exchange_request_hash <> request_hash
      or prior.key_version <> p_grant_key_version
      or prior.grant_hash <> p_grant_hash
    then
      raise exception 'QR_EXCHANGE_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    if prior.consumed_at is not null
      or prior.revoked_at is not null
      or prior.expires_at <= timezone('utc', now())
      or not private.order_qr_usable(prior.order_id)
    then
      return jsonb_build_object('status', 'invalid');
    end if;
    return private.fulfilment_scan_workspace(prior.order_id)
      || jsonb_build_object('grantExpiresAt', prior.expires_at);
  end if;

  if (
    select count(*)
    from app.audit_logs audit
    where audit.actor_user_id = p_actor_id
      and audit.action in ('qr.exchange.accepted', 'qr.exchange.rejected')
      and audit.created_at >= timezone('utc', now()) - interval '1 minute'
  ) >= 60 then
    raise exception 'QR_EXCHANGE_RATE_LIMITED' using errcode = 'P0001';
  end if;

  select current_locator.* into locator
  from private.qr_order_locators current_locator
  where current_locator.locator_hash = p_locator_hash
    and current_locator.active
  for update;
  if not found then
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      metadata
    ) values (
      p_actor_id,
      'qr.exchange.rejected',
      'member_order',
      jsonb_build_object('reason', 'invalid_or_inactive')
    );
    return jsonb_build_object('status', 'invalid');
  end if;
  select * into identity
  from private.qr_order_identities current_identity
  where current_identity.id = locator.identity_id
  for update;
  if not found
    or identity.suspended_at is not null
    or not private.order_qr_usable(identity.order_id)
  then
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      metadata
    ) values (
      p_actor_id,
      'qr.exchange.rejected',
      'member_order',
      jsonb_build_object('reason', 'not_usable')
    );
    return jsonb_build_object('status', 'invalid');
  end if;

  expires := timezone('utc', now()) + interval '2 minutes';
  perform set_config('app.qr_internal', 'on', true);
  update private.qr_scan_grants grant_row
  set revoked_at = timezone('utc', now()),
      revocation_reason = 'Vervangen door een nieuwe scan'
  where grant_row.order_id = identity.order_id
    and grant_row.staff_session_hash = p_staff_session_hash
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null;
  perform set_config('app.qr_internal', 'off', true);

  insert into private.qr_scan_grants(
    locator_id,
    order_id,
    actor_user_id,
    staff_session_hash,
    exchange_request_id,
    exchange_request_hash,
    key_version,
    grant_hash,
    expires_at
  ) values (
    locator.id,
    identity.order_id,
    p_actor_id,
    p_staff_session_hash,
    p_request_id,
    request_hash,
    p_grant_key_version,
    p_grant_hash,
    expires
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    p_actor_id,
    'qr.exchange.accepted',
    'member_order',
    identity.order_id,
    jsonb_build_object(
      'generation', locator.generation,
      'expiresInSeconds', 120
    )
  );
  workspace := private.fulfilment_scan_workspace(identity.order_id);
  return workspace || jsonb_build_object('grantExpiresAt', expires);
end;
$$;

revoke all on function app.exchange_order_qr_locator_v2(
  uuid, text, text, text, integer, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.exchange_order_qr_locator_v2(
  uuid, text, text, text, integer, uuid
) to service_role;

create or replace function app.commit_fulfilment_v3(
  p_actor_id uuid,
  p_staff_session_hash text,
  p_grant_hash text,
  p_order_line_ids uuid[],
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  prior private.fulfilment_command_requests%rowtype;
  grant_hint private.qr_scan_grants%rowtype;
  locked_grant private.qr_scan_grants%rowtype;
  target_order app.member_orders%rowtype;
  identity private.qr_order_identities%rowtype;
  locator private.qr_order_locators%rowtype;
  normalized_line_ids uuid[];
  selected_count integer;
  valid_count integer;
  selected record;
  variant_id uuid;
  created_fulfilment_id uuid;
  fulfilment_line_id uuid;
  pickup_location text;
  completed_at timestamptz;
  outcome text;
  notification_payload jsonb;
  request_hash text;
  result jsonb;
begin
  if not private.staff_app_session_authorized(
    p_actor_id,
    p_staff_session_hash,
    array['beheerder', 'uitgifte']::app.staff_role[]
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_grant_hash !~ '^[0-9a-f]{64}$'
    or p_request_id is null
    or coalesce(array_length(p_order_line_ids, 1), 0) not between 1 and 25
  then
    raise exception 'FULFILMENT_COMMAND_INVALID' using errcode = '22023';
  end if;
  select
    array_agg(candidate.line_id order by candidate.line_id),
    count(*)::integer
  into normalized_line_ids, selected_count
  from (
    select distinct line_id
    from unnest(p_order_line_ids) selected_line(line_id)
  ) candidate;
  if selected_count <> array_length(p_order_line_ids, 1) then
    raise exception 'FULFILMENT_COMMAND_DUPLICATE_LINE'
      using errcode = '22023';
  end if;

  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'fulfilment-commit-v3',
        p_actor_id::text,
        p_staff_session_hash,
        p_grant_hash,
        array_to_string(normalized_line_ids, ',')
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended('fulfilment-request:' || p_request_id::text, 0)
  );
  select * into prior
  from private.fulfilment_command_requests command
  where command.request_id = p_request_id;
  if found then
    if prior.actor_user_id <> p_actor_id
      or prior.staff_session_hash <> p_staff_session_hash
      or prior.request_hash <> request_hash
    then
      raise exception 'FULFILMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  select * into grant_hint
  from private.qr_scan_grants grant_row
  where grant_row.grant_hash = p_grant_hash;
  if not found
    or grant_hint.actor_user_id <> p_actor_id
    or grant_hint.staff_session_hash <> p_staff_session_hash
  then
    return jsonb_build_object('status', 'stale');
  end if;
  select * into target_order
  from app.member_orders orders
  where orders.id = grant_hint.order_id;
  if not found then
    return jsonb_build_object('status', 'stale');
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_order.member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:'
        || target_order.member_season_id::text,
      0
    )
  );
  select * into target_order
  from app.member_orders orders
  where orders.id = grant_hint.order_id
  for update;
  if not found then
    return jsonb_build_object('status', 'stale');
  end if;
  perform private.lock_inventory_mutation();

  select * into locked_grant
  from private.qr_scan_grants grant_row
  where grant_row.id = grant_hint.id
  for update;
  select * into locator
  from private.qr_order_locators current_locator
  where current_locator.id = locked_grant.locator_id
  for update;
  select * into identity
  from private.qr_order_identities current_identity
  where current_identity.id = locator.identity_id
  for update;

  if not private.staff_app_session_authorized(
      p_actor_id,
      p_staff_session_hash,
      array['beheerder', 'uitgifte']::app.staff_role[]
    )
    or locked_grant.id is null
    or locked_grant.order_id <> target_order.id
    or locked_grant.actor_user_id <> p_actor_id
    or locked_grant.staff_session_hash <> p_staff_session_hash
    or locked_grant.consumed_at is not null
    or locked_grant.revoked_at is not null
    or locked_grant.expires_at <= timezone('utc', now())
    or locator.id is null
    or not locator.active
    or identity.id is null
    or identity.order_id <> target_order.id
    or identity.suspended_at is not null
    or not private.order_qr_usable(target_order.id)
  then
    if locked_grant.id is not null
      and locked_grant.consumed_at is null
      and locked_grant.revoked_at is null
    then
      perform set_config('app.qr_internal', 'on', true);
      update private.qr_scan_grants
      set revoked_at = timezone('utc', now()),
          revocation_reason = 'Scanstatus is niet meer actueel'
      where id = locked_grant.id;
      perform set_config('app.qr_internal', 'off', true);
    end if;
    return jsonb_build_object('status', 'stale');
  end if;

  for selected in
    select line.id
    from app.order_lines line
    join app.inventory_allocations allocation
      on allocation.order_line_id = line.id
      and allocation.order_id = line.order_id
    where line.id = any(normalized_line_ids)
    order by allocation.article_variant_id, allocation.id
    for update of line, allocation
  loop
    null;
  end loop;

  select count(*)::integer into valid_count
  from app.order_lines line
  join app.inventory_allocations allocation
    on allocation.order_line_id = line.id
    and allocation.order_id = line.order_id
    and allocation.article_variant_id = line.article_variant_id
    and allocation.quantity = line.quantity
  where line.id = any(normalized_line_ids)
    and line.order_id = target_order.id
    and line.status = 'ready_for_pickup'
    and allocation.status = 'reserved'
    and allocation.reconciliation_status = 'resolved'
    and allocation.paid_at is not null
    and allocation.size_valid_at is not null
    and not exists(
      select 1
      from app.fulfilment_lines active_line
      where active_line.order_line_id = line.id
        and active_line.reversed_at is null
    )
    and (
      select coalesce(sum(movement.reserved_delta), 0)
      from app.inventory_movements movement
      where movement.allocation_id = allocation.id
    ) = allocation.quantity
    and (
      select coalesce(sum(movement.issued_delta), 0)
      from app.inventory_movements movement
      where movement.allocation_id = allocation.id
    ) = 0;
  if valid_count <> selected_count then
    perform set_config('app.qr_internal', 'on', true);
    update private.qr_scan_grants
    set revoked_at = timezone('utc', now()),
        revocation_reason = 'Uitgifteselectie is niet meer actueel'
    where id = locked_grant.id;
    perform set_config('app.qr_internal', 'off', true);
    return jsonb_build_object('status', 'stale');
  end if;

  for variant_id in
    select distinct allocation.article_variant_id
    from app.inventory_allocations allocation
    where allocation.order_line_id = any(normalized_line_ids)
      and allocation.status = 'reserved'
    order by allocation.article_variant_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'inventory-balance:'
          || target_order.season_id::text
          || ':'
          || variant_id::text,
        0
      )
    );
  end loop;

  select settings.pickup_location into pickup_location
  from app.app_settings settings
  where settings.id = true
    and settings.active_season_id = target_order.season_id;
  if length(btrim(coalesce(pickup_location, ''))) not between 4 and 240 then
    perform set_config('app.qr_internal', 'on', true);
    update private.qr_scan_grants
    set revoked_at = timezone('utc', now()),
        revocation_reason = 'Afhaallocatie ontbreekt'
    where id = locked_grant.id;
    perform set_config('app.qr_internal', 'off', true);
    return jsonb_build_object('status', 'blocked');
  end if;

  completed_at := timezone('utc', now());
  perform set_config('app.inventory_internal', 'on', true);
  insert into app.fulfilments(
    order_id,
    actor_user_id,
    location,
    member_season_id,
    season_id,
    request_id,
    scan_grant_id,
    created_at
  ) values (
    target_order.id,
    p_actor_id,
    btrim(pickup_location),
    target_order.member_season_id,
    target_order.season_id,
    p_request_id,
    locked_grant.id,
    completed_at
  )
  returning id into created_fulfilment_id;

  for selected in
    select
      line.id order_line_id,
      line.quantity line_quantity,
      line.product_name_snapshot line_product_name_snapshot,
      line.size_snapshot line_size_snapshot,
      allocation.id allocation_id,
      allocation.season_id allocation_season_id,
      allocation.article_id allocation_article_id,
      allocation.article_variant_id allocation_variant_id,
      allocation.quantity allocation_quantity,
      allocation.legacy_reservation_id
    from app.order_lines line
    join app.inventory_allocations allocation
      on allocation.order_line_id = line.id
      and allocation.order_id = line.order_id
      and allocation.status = 'reserved'
    where line.id = any(normalized_line_ids)
    order by allocation.article_variant_id, allocation.id
  loop
    insert into app.fulfilment_lines(
      fulfilment_id,
      order_line_id,
      reservation_id,
      inventory_allocation_id,
      quantity,
      product_name_snapshot,
      article_variant_id_snapshot,
      size_snapshot,
      created_at
    ) values (
      created_fulfilment_id,
      selected.order_line_id,
      selected.legacy_reservation_id,
      selected.allocation_id,
      selected.allocation_quantity,
      selected.line_product_name_snapshot,
      selected.allocation_variant_id,
      selected.line_size_snapshot,
      completed_at
    )
    returning id into fulfilment_line_id;

    insert into app.inventory_movements(
      season_id,
      article_id,
      article_variant_id,
      movement_type,
      on_hand_delta,
      reserved_delta,
      issued_delta,
      allocation_id,
      fulfilment_line_id,
      source_type,
      source_id,
      reason_code,
      idempotency_key,
      actor_user_id,
      correlation_id,
      safe_context,
      occurred_at
    ) values (
      selected.allocation_season_id,
      selected.allocation_article_id,
      selected.allocation_variant_id,
      'fulfilment_issued',
      -selected.allocation_quantity,
      -selected.allocation_quantity,
      selected.allocation_quantity,
      selected.allocation_id,
      fulfilment_line_id,
      'fulfilment',
      created_fulfilment_id,
      'fulfilment.issued',
      encode(
        extensions.digest(
          concat_ws(
            ':',
            'fulfilment-issue-v3',
            created_fulfilment_id::text,
            selected.allocation_id::text
          ),
          'sha256'
        ),
        'hex'
      ),
      p_actor_id,
      p_correlation_id,
      jsonb_build_object(
        'fulfilmentId', created_fulfilment_id,
        'allocationId', selected.allocation_id,
        'orderItemId', selected.order_line_id,
        'variantId', selected.allocation_variant_id,
        'quantity', selected.allocation_quantity
      ),
      completed_at
    );

    update app.inventory_allocations
    set status = 'fulfilled',
        fulfilled_at = completed_at,
        fulfilled_by = p_actor_id,
        updated_at = completed_at
    where id = selected.allocation_id;
    if selected.legacy_reservation_id is not null then
      update app.inventory_reservations
      set status = 'fulfilled',
          updated_at = completed_at
      where id = selected.legacy_reservation_id
        and status = 'reserved';
      if not found then
        raise exception 'LEGACY_RESERVATION_STATE_MISMATCH'
          using errcode = '23514';
      end if;
    end if;
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
    ) values (
      selected.allocation_id,
      'fulfilled',
      'reserved',
      'fulfilled',
      'fulfilment.issued',
      'fulfilment',
      created_fulfilment_id,
      encode(
        extensions.digest(
          concat_ws(
            ':',
            'fulfilment-allocation-event-v3',
            created_fulfilment_id::text,
            selected.allocation_id::text
          ),
          'sha256'
        ),
        'hex'
      ),
      p_actor_id,
      jsonb_build_object(
        'fulfilmentId', created_fulfilment_id,
        'allocationId', selected.allocation_id,
        'orderItemId', selected.order_line_id,
        'variantId', selected.allocation_variant_id,
        'quantity', selected.allocation_quantity
      ),
      completed_at
    );
    update app.order_lines
    set status = 'picked_up',
        updated_at = completed_at
    where id = selected.order_line_id
      and status = 'ready_for_pickup';
    if not found then
      raise exception 'ORDER_LINE_STATE_MISMATCH' using errcode = '23514';
    end if;
  end loop;
  perform set_config('app.inventory_internal', 'off', true);

  perform app.refresh_order_status(target_order.id);
  outcome := case
    when exists(
      select 1
      from app.order_lines line
      where line.order_id = target_order.id
        and line.status in ('backorder', 'ready_for_pickup')
    )
    then 'partial_pickup'
    else 'package_complete'
  end;
  notification_payload := jsonb_build_object(
    'fulfilmentId', created_fulfilment_id,
    'issued', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'product', line.product_name_snapshot,
          'size', line.size_snapshot,
          'quantity', line.quantity
        )
        order by line.id
      )
      from app.fulfilment_lines line
      where line.fulfilment_id = created_fulfilment_id
    ), '[]'::jsonb),
    'remaining', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'product', line.product_name_snapshot,
          'size', line.size_snapshot,
          'quantity', line.quantity,
          'status', line.status::text
        )
        order by article.sort_order, line.id
      )
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = target_order.id
        and line.status in ('backorder', 'ready_for_pickup')
    ), '[]'::jsonb),
    'package', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'product', line.product_name_snapshot,
          'size', line.size_snapshot,
          'quantity', line.quantity,
          'status', line.status::text
        )
        order by article.sort_order, line.id
      )
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = target_order.id
        and line.status <> 'cancelled'
    ), '[]'::jsonb)
  );
  insert into private.fulfilment_notification_events(
    fulfilment_id,
    order_id,
    member_season_id,
    season_id,
    event_type,
    idempotency_key,
    payload_snapshot,
    created_at
  ) values (
    created_fulfilment_id,
    target_order.id,
    target_order.member_season_id,
    target_order.season_id,
    outcome,
    encode(
      extensions.digest(
        'fulfilment-notification-v3:' || created_fulfilment_id::text,
        'sha256'
      ),
      'hex'
    ),
    notification_payload,
    completed_at
  );

  perform set_config('app.qr_internal', 'on', true);
  update private.qr_scan_grants
  set consumed_at = completed_at,
      consumed_by_fulfilment_id = created_fulfilment_id
  where id = locked_grant.id;
  perform set_config('app.qr_internal', 'off', true);

  result := jsonb_build_object(
    'status', 'completed',
    'issuedLines', selected_count,
    'completedAt', completed_at,
    'outcome', outcome,
    'reused', false
  );
  insert into private.fulfilment_command_requests(
    request_id,
    fulfilment_id,
    scan_grant_id,
    actor_user_id,
    staff_session_hash,
    request_hash,
    result_snapshot,
    created_at
  ) values (
    p_request_id,
    created_fulfilment_id,
    locked_grant.id,
    p_actor_id,
    p_staff_session_hash,
    request_hash,
    result,
    completed_at
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id,
    created_at
  ) values (
    p_actor_id,
    'fulfilment.completed_v3',
    'fulfilment',
    created_fulfilment_id,
    jsonb_build_object(
      'orderId', target_order.id,
      'memberSeasonId', target_order.member_season_id,
      'seasonId', target_order.season_id,
      'lineCount', selected_count,
      'outcome', outcome
    ),
    p_correlation_id,
    completed_at
  );
  return result;
end;
$$;

revoke all on function app.commit_fulfilment_v3(
  uuid, text, text, uuid[], uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.commit_fulfilment_v3(
  uuid, text, text, uuid[], uuid, uuid
) to service_role;

create or replace function app.correct_fulfilment_v3(
  p_actor_id uuid,
  p_staff_session_hash text,
  p_order_line_ids uuid[],
  p_target_status text,
  p_reason text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  normalized_line_ids uuid[];
  selected_count integer;
  normalized_reason text;
  request_hash text;
  prior private.fulfilment_correction_requests%rowtype;
  target_order app.member_orders%rowtype;
  order_count integer;
  valid_count integer;
  selected record;
  variant_id uuid;
  movement_type app.inventory_movement_type;
  event_type text;
  correction_time timestamptz;
  result jsonb;
begin
  if not private.staff_app_session_authorized(
    p_actor_id,
    p_staff_session_hash,
    array['beheerder', 'kledingcommissie']::app.staff_role[]
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_target_status not in ('ready_for_pickup', 'backorder')
    or p_request_id is null
    or coalesce(array_length(p_order_line_ids, 1), 0) not between 1 and 25
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'FULFILMENT_CORRECTION_INVALID' using errcode = '22023';
  end if;
  select
    array_agg(candidate.line_id order by candidate.line_id),
    count(*)::integer
  into normalized_line_ids, selected_count
  from (
    select distinct line_id
    from unnest(p_order_line_ids) selected_line(line_id)
  ) candidate;
  if selected_count <> array_length(p_order_line_ids, 1) then
    raise exception 'FULFILMENT_CORRECTION_DUPLICATE_LINE'
      using errcode = '22023';
  end if;

  select count(distinct line.order_id)::integer into order_count
  from app.order_lines line
  where line.id = any(normalized_line_ids);
  if order_count <> 1 then
    raise exception 'FULFILMENT_CORRECTION_SINGLE_ORDER_REQUIRED'
      using errcode = '23514';
  end if;
  select orders.* into target_order
  from app.member_orders orders
  where orders.id = (
    select line.order_id
    from app.order_lines line
    where line.id = any(normalized_line_ids)
    limit 1
  );
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;

  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'fulfilment-correction-v3',
        p_actor_id::text,
        p_staff_session_hash,
        target_order.id::text,
        array_to_string(normalized_line_ids, ','),
        p_target_status,
        normalized_reason
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'fulfilment-correction-request:' || p_request_id::text,
      0
    )
  );
  select * into prior
  from private.fulfilment_correction_requests command
  where command.request_id = p_request_id;
  if found then
    if prior.order_id <> target_order.id
      or prior.actor_user_id <> p_actor_id
      or prior.staff_session_hash <> p_staff_session_hash
      or prior.request_hash <> request_hash
    then
      raise exception 'FULFILMENT_IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_order.member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:'
        || target_order.member_season_id::text,
      0
    )
  );
  select * into target_order
  from app.member_orders orders
  where orders.id = target_order.id
  for update;
  perform private.lock_inventory_mutation();

  for selected in
    select line.id
    from app.order_lines line
    join app.fulfilment_lines fulfilment_line
      on fulfilment_line.order_line_id = line.id
      and fulfilment_line.reversed_at is null
    join app.inventory_allocations allocation
      on allocation.id = fulfilment_line.inventory_allocation_id
    where line.id = any(normalized_line_ids)
    order by allocation.article_variant_id, allocation.id
    for update of line, fulfilment_line, allocation
  loop
    null;
  end loop;

  select count(*)::integer into valid_count
  from app.order_lines line
  join app.fulfilment_lines fulfilment_line
    on fulfilment_line.order_line_id = line.id
    and fulfilment_line.reversed_at is null
  join app.inventory_allocations allocation
    on allocation.id = fulfilment_line.inventory_allocation_id
    and allocation.order_line_id = line.id
    and allocation.order_id = line.order_id
    and allocation.article_variant_id = line.article_variant_id
    and allocation.quantity = line.quantity
  where line.id = any(normalized_line_ids)
    and line.order_id = target_order.id
    and line.status = 'picked_up'
    and allocation.status = 'fulfilled'
    and allocation.reconciliation_status = 'resolved'
    and (
      select coalesce(sum(movement.reserved_delta), 0)
      from app.inventory_movements movement
      where movement.allocation_id = allocation.id
    ) = 0
    and (
      select coalesce(sum(movement.issued_delta), 0)
      from app.inventory_movements movement
      where movement.allocation_id = allocation.id
    ) = allocation.quantity;
  if valid_count <> selected_count then
    raise exception 'FULFILMENT_CORRECTION_STATE_INVALID'
      using errcode = '23514';
  end if;

  for variant_id in
    select distinct allocation.article_variant_id
    from app.inventory_allocations allocation
    where allocation.order_line_id = any(normalized_line_ids)
      and allocation.status = 'fulfilled'
    order by allocation.article_variant_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'inventory-balance:'
          || target_order.season_id::text
          || ':'
          || variant_id::text,
        0
      )
    );
  end loop;

  correction_time := timezone('utc', now());
  movement_type := case
    when p_target_status = 'ready_for_pickup'
      then 'fulfilment_reversed_ready'::app.inventory_movement_type
    else 'fulfilment_reversed_backorder'::app.inventory_movement_type
  end;
  event_type := case
    when p_target_status = 'ready_for_pickup' then 'reversed_ready'
    else 'reversed_backorder'
  end;

  perform set_config('app.inventory_internal', 'on', true);
  for selected in
    select
      line.id order_line_id,
      line.quantity line_quantity,
      fulfilment_line.id fulfilment_line_id,
      fulfilment_line.fulfilment_id,
      allocation.id allocation_id,
      allocation.season_id allocation_season_id,
      allocation.article_id allocation_article_id,
      allocation.article_variant_id allocation_variant_id,
      allocation.quantity allocation_quantity,
      allocation.legacy_reservation_id
    from app.order_lines line
    join app.fulfilment_lines fulfilment_line
      on fulfilment_line.order_line_id = line.id
      and fulfilment_line.reversed_at is null
    join app.inventory_allocations allocation
      on allocation.id = fulfilment_line.inventory_allocation_id
    where line.id = any(normalized_line_ids)
    order by allocation.article_variant_id, allocation.id
  loop
    insert into app.inventory_movements(
      season_id,
      article_id,
      article_variant_id,
      movement_type,
      on_hand_delta,
      reserved_delta,
      issued_delta,
      allocation_id,
      fulfilment_line_id,
      source_type,
      source_id,
      reason_code,
      idempotency_key,
      actor_user_id,
      correlation_id,
      safe_context,
      occurred_at
    ) values (
      selected.allocation_season_id,
      selected.allocation_article_id,
      selected.allocation_variant_id,
      movement_type,
      selected.allocation_quantity,
      case
        when p_target_status = 'ready_for_pickup'
          then selected.allocation_quantity
        else 0
      end,
      -selected.allocation_quantity,
      selected.allocation_id,
      selected.fulfilment_line_id,
      'fulfilment_correction',
      p_request_id,
      case
        when p_target_status = 'ready_for_pickup'
          then 'fulfilment.reversed_ready'
        else 'fulfilment.reversed_backorder'
      end,
      encode(
        extensions.digest(
          concat_ws(
            ':',
            'fulfilment-correction-movement-v3',
            p_request_id::text,
            selected.allocation_id::text
          ),
          'sha256'
        ),
        'hex'
      ),
      p_actor_id,
      p_correlation_id,
      jsonb_build_object(
        'fulfilmentId', selected.fulfilment_id,
        'allocationId', selected.allocation_id,
        'orderItemId', selected.order_line_id,
        'variantId', selected.allocation_variant_id,
        'quantity', selected.allocation_quantity
      ),
      correction_time
    );
    update app.inventory_allocations
    set status = case
          when p_target_status = 'ready_for_pickup'
            then 'reserved'::app.inventory_allocation_status
          else 'released'::app.inventory_allocation_status
        end,
        fulfilled_at = case
          when p_target_status = 'ready_for_pickup' then null
          else fulfilled_at
        end,
        fulfilled_by = case
          when p_target_status = 'ready_for_pickup' then null
          else fulfilled_by
        end,
        released_at = case
          when p_target_status = 'backorder' then correction_time
          else null
        end,
        released_by = case
          when p_target_status = 'backorder' then p_actor_id
          else null
        end,
        release_reason = case
          when p_target_status = 'backorder' then normalized_reason
          else null
        end,
        updated_at = correction_time
    where id = selected.allocation_id;
    if selected.legacy_reservation_id is not null then
      update app.inventory_reservations
      set status = case
            when p_target_status = 'ready_for_pickup'
              then 'reserved'::app.reservation_status
            else 'released'::app.reservation_status
          end,
          updated_at = correction_time
      where id = selected.legacy_reservation_id
        and status = 'fulfilled';
      if not found then
        raise exception 'LEGACY_RESERVATION_STATE_MISMATCH'
          using errcode = '23514';
      end if;
    end if;
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
    ) values (
      selected.allocation_id,
      event_type,
      'fulfilled',
      case
        when p_target_status = 'ready_for_pickup'
          then 'reserved'::app.inventory_allocation_status
        else 'released'::app.inventory_allocation_status
      end,
      case
        when p_target_status = 'ready_for_pickup'
          then 'fulfilment.reversed_ready'
        else 'fulfilment.reversed_backorder'
      end,
      'fulfilment_correction',
      p_request_id,
      encode(
        extensions.digest(
          concat_ws(
            ':',
            'fulfilment-correction-event-v3',
            p_request_id::text,
            selected.allocation_id::text
          ),
          'sha256'
        ),
        'hex'
      ),
      p_actor_id,
      jsonb_build_object(
        'fulfilmentId', selected.fulfilment_id,
        'allocationId', selected.allocation_id,
        'orderItemId', selected.order_line_id,
        'variantId', selected.allocation_variant_id,
        'quantity', selected.allocation_quantity
      ),
      correction_time
    );
    update app.fulfilment_lines
    set reversed_at = correction_time,
        reversed_by = p_actor_id,
        reversal_reason = normalized_reason
    where id = selected.fulfilment_line_id;
    update app.fulfilments
    set corrected_at = correction_time,
        correction_reason = normalized_reason
    where id = selected.fulfilment_id;
    update app.order_lines
    set status = p_target_status::app.order_line_status,
        updated_at = correction_time
    where id = selected.order_line_id;
  end loop;
  perform set_config('app.inventory_internal', 'off', true);

  if p_target_status = 'backorder' then
    for variant_id in
      select distinct allocation.article_variant_id
      from app.inventory_allocations allocation
      where allocation.order_line_id = any(normalized_line_ids)
      order by allocation.article_variant_id
    loop
      perform private.enqueue_inventory_variant(
        target_order.season_id,
        variant_id,
        'fulfilment_correction'
      );
    end loop;
  end if;
  perform app.refresh_order_status(target_order.id);

  perform set_config('app.qr_internal', 'on', true);
  update private.qr_scan_grants grant_row
  set revoked_at = correction_time,
      revocation_reason = 'Uitgifte is gecorrigeerd'
  where grant_row.order_id = target_order.id
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null;
  perform set_config('app.qr_internal', 'off', true);

  result := jsonb_build_object(
    'status', 'corrected',
    'correctedLines', selected_count,
    'targetStatus', p_target_status,
    'correctedAt', correction_time,
    'reused', false
  );
  insert into private.fulfilment_correction_requests(
    request_id,
    order_id,
    actor_user_id,
    staff_session_hash,
    request_hash,
    result_snapshot,
    created_at
  ) values (
    p_request_id,
    target_order.id,
    p_actor_id,
    p_staff_session_hash,
    request_hash,
    result,
    correction_time
  );
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id,
    created_at
  ) values (
    p_actor_id,
    'fulfilment.corrected_v3',
    'member_order',
    target_order.id,
    jsonb_build_object(
      'memberSeasonId', target_order.member_season_id,
      'seasonId', target_order.season_id,
      'lineCount', selected_count,
      'targetStatus', p_target_status,
      'reason', normalized_reason
    ),
    p_correlation_id,
    correction_time
  );
  return result;
end;
$$;

revoke all on function app.correct_fulfilment_v3(
  uuid, text, uuid[], text, text, uuid, uuid
) from public, anon, authenticated, service_role;
grant execute on function app.correct_fulfilment_v3(
  uuid, text, uuid[], text, text, uuid, uuid
) to service_role;

create or replace function private.revoke_order_qr_v2(
  p_order_id uuid,
  p_actor_id uuid,
  p_reason text,
  p_suspend boolean default true
)
returns integer
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  normalized_reason text;
  identity_id uuid;
  affected integer := 0;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_order_id is null
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'QR_REVOCATION_INPUT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('qr-order:' || p_order_id::text, 0)
  );
  select identity.id into identity_id
  from private.qr_order_identities identity
  where identity.order_id = p_order_id
  for update;
  if identity_id is null then
    return 0;
  end if;
  perform set_config('app.qr_internal', 'on', true);
  update private.qr_order_locators locator
  set active = false,
      revoked_at = timezone('utc', now()),
      revoked_by = p_actor_id,
      revocation_reason = normalized_reason
  where locator.identity_id = identity_id
    and locator.active;
  get diagnostics affected = row_count;
  update private.qr_scan_grants grant_row
  set revoked_at = timezone('utc', now()),
      revocation_reason = left(normalized_reason, 160)
  where grant_row.order_id = p_order_id
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null;
  if p_suspend then
    update private.qr_order_identities
    set suspended_at = timezone('utc', now()),
        suspended_by = p_actor_id,
        suspension_reason = normalized_reason,
        updated_at = timezone('utc', now())
    where id = identity_id;
  end if;
  perform set_config('app.qr_internal', 'off', true);
  return affected;
end;
$$;

revoke all on function private.revoke_order_qr_v2(
  uuid, uuid, text, boolean
) from public, anon, authenticated, service_role;

create or replace function private.revoke_qr_after_payment_transition()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if (
    new.status in ('refunded', 'duplicate_paid')
    or new.reconciliation_issue is not null
  ) and (
    tg_op = 'INSERT'
    or old.status is distinct from new.status
    or old.reconciliation_issue is distinct from new.reconciliation_issue
  ) then
    perform private.revoke_order_qr_v2(
      new.order_id,
      new.recorded_by,
      case
        when new.status = 'refunded' then 'Betaling is terugbetaald'
        when new.status = 'duplicate_paid' then 'Dubbele betaling vereist controle'
        else 'Betaalreconciliatie vereist controle'
      end,
      true
    );
  end if;
  return new;
end;
$$;

create trigger payments_revoke_qr_v2
after insert or update of status, reconciliation_issue on app.payments
for each row execute function private.revoke_qr_after_payment_transition();

revoke all on function private.revoke_qr_after_payment_transition()
from public, anon, authenticated, service_role;

create or replace function app.revoke_staff_app_session(p_session_token text)
returns integer
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  session_hash text;
  affected integer;
begin
  if p_session_token is null or p_session_token !~ '^[0-9a-f]{64}$' then
    return 0;
  end if;
  session_hash := encode(digest(p_session_token, 'sha256'), 'hex');
  perform set_config('app.qr_internal', 'on', true);
  update private.qr_scan_grants grant_row
  set revoked_at = timezone('utc', now()),
      revocation_reason = 'Medewerkerssessie is beëindigd'
  where grant_row.staff_session_hash = session_hash
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null;
  perform set_config('app.qr_internal', 'off', true);
  update private.staff_sessions
  set revoked_at = timezone('utc', now())
  where token_hash = session_hash
    and revoked_at is null;
  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function app.revoke_staff_app_session(text)
from public, anon, authenticated;
grant execute on function app.revoke_staff_app_session(text)
to service_role;

create or replace function public.get_parent_package_workspace_v4(
  p_token_hash text
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, public, pg_temp
as $$
  select jsonb_set(
    workspace.result,
    '{members}',
    coalesce((
      select jsonb_agg(
        case
          when member.value->'order' is null
            or jsonb_typeof(member.value->'order') = 'null'
          then member.value
          else jsonb_set(
            member.value,
            '{order}',
            (member.value->'order')
              || case
                when private.order_qr_usable(
                  (member.value #>> '{order,id}')::uuid
                )
                then coalesce((
                  select jsonb_build_object(
                    'qrVersion', locator.generation,
                    'qrKeyVersion', locator.key_version,
                    'qrNonce', locator.derivation_nonce
                  )
                  from private.qr_order_identities identity
                  join private.qr_order_locators locator
                    on locator.identity_id = identity.id
                    and locator.order_id = identity.order_id
                    and locator.active
                  where identity.order_id =
                    (member.value #>> '{order,id}')::uuid
                    and identity.suspended_at is null
                  limit 1
                ), jsonb_build_object(
                  'qrVersion', null,
                  'qrKeyVersion', null,
                  'qrNonce', null
                ))
                else jsonb_build_object(
                  'qrVersion', null,
                  'qrKeyVersion', null,
                  'qrNonce', null
                )
              end,
            true
          )
        end
        order by member.ordinality
      )
      from jsonb_array_elements(workspace.result->'members')
        with ordinality as member(value, ordinality)
    ), '[]'::jsonb),
    true
  )
  from (
    select public.get_parent_package_workspace_v3(p_token_hash) result
  ) workspace;
$$;

revoke execute on function public.get_parent_package_workspace_v3(text)
from service_role;
revoke all on function public.get_parent_package_workspace_v4(text)
from public, anon, authenticated;
grant execute on function public.get_parent_package_workspace_v4(text)
to service_role;

insert into private.release_cutovers(key)
select 'allocation_qr_v2'
where exists(
  select 1
  from app.release_feature_flags flag
  where flag.key = 'allocation_qr_v2'
    and flag.enabled
)
on conflict (key) do nothing;

create or replace function private.guard_irreversible_release_cutover()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if old.key not in ('dynamic_import_v2', 'allocation_qr_v2') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if old.key = 'dynamic_import_v2' then
    if tg_op = 'DELETE' then
      if exists(
        select 1 from private.release_cutovers cutover
        where cutover.key = old.key
      ) then
        raise exception 'DYNAMIC_IMPORT_CUTOVER_IRREVERSIBLE'
          using errcode = '55000';
      end if;
      return old;
    end if;
    if new.key is distinct from old.key then
      raise exception 'DYNAMIC_IMPORT_CUTOVER_KEY_IMMUTABLE'
        using errcode = '55000';
    end if;
    if new.enabled then
      insert into private.release_cutovers(key)
      values(new.key)
      on conflict (key) do nothing;
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if exists(
      select 1 from private.release_cutovers cutover
      where cutover.key = old.key
    ) then
      raise exception 'RELEASE_CUTOVER_IRREVERSIBLE' using errcode = '55000';
    end if;
    return old;
  end if;
  if new.key is distinct from old.key then
    raise exception 'RELEASE_CUTOVER_KEY_IMMUTABLE' using errcode = '55000';
  end if;
  if old.enabled and not new.enabled then
    raise exception 'RELEASE_CUTOVER_IRREVERSIBLE' using errcode = '55000';
  end if;
  if not old.enabled
    and new.enabled
    and not exists(
      select 1 from private.release_cutovers cutover
      where cutover.key = new.key
    )
  then
    raise exception 'RELEASE_CUTOVER_GATE_REQUIRED' using errcode = '55000';
  end if;
  if new.enabled then
    insert into private.release_cutovers(key)
    values(new.key)
    on conflict (key) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function private.guard_irreversible_release_cutover()
from public, anon, authenticated, service_role;

create or replace function private.allocation_qr_cutover_snapshot(
  p_pepper_fingerprint text,
  p_key_version integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  inventory_report jsonb;
  queue_blockers integer;
  balance_blockers integer;
  ready_line_blockers integer;
  allocation_blockers integer;
  fulfilment_link_blockers integer;
  locator_blockers integer;
  legacy_blockers integer;
  key_blockers integer;
  pickup_blockers integer;
  enabled boolean;
  ready boolean;
  revision text;
begin
  if p_pepper_fingerprint !~ '^[0-9a-f]{64}$'
    or p_key_version not between 1 and 9999
  then
    raise exception 'QR_CUTOVER_KEY_INVALID' using errcode = '22023';
  end if;
  inventory_report := private.inventory_reconciliation_report();
  select count(*)::integer into queue_blockers
  from private.inventory_allocation_queue queue
  where queue.status in ('queued', 'processing', 'failed');
  select count(*)::integer into balance_blockers
  from (
    select
      movement.season_id,
      movement.article_variant_id
    from app.inventory_movements movement
    group by movement.season_id, movement.article_variant_id
    having sum(movement.on_hand_delta) < 0
      or sum(movement.reserved_delta) < 0
      or sum(movement.issued_delta) < 0
      or sum(movement.reserved_delta) > sum(movement.on_hand_delta)
  ) invalid_balance;
  select count(*)::integer into ready_line_blockers
  from (
    select line.id
    from app.order_lines line
    left join app.inventory_allocations allocation
      on allocation.order_line_id = line.id
      and allocation.status = 'reserved'
      and allocation.reconciliation_status = 'resolved'
    where line.status = 'ready_for_pickup'
    group by line.id
    having count(allocation.id) <> 1
  ) blocked_line;
  select count(*)::integer into allocation_blockers
  from app.inventory_allocations allocation
  join app.order_lines line on line.id = allocation.order_line_id
  join app.member_orders orders on orders.id = allocation.order_id
  where allocation.status = 'reserved'
    and (
      allocation.reconciliation_status <> 'resolved'
      or line.status <> 'ready_for_pickup'
      or line.quantity <> allocation.quantity
      or line.article_variant_id <> allocation.article_variant_id
      or not exists(
        select 1
        from app.payments payment
        where payment.order_id = orders.id
          and payment.status = 'paid'
          and payment.reconciliation_issue is null
          and payment.amount_cents = orders.amount_due_cents
          and payment.currency = 'EUR'
          and payment.member_season_id = orders.member_season_id
          and payment.package_snapshot_id = orders.active_package_snapshot_id
      )
      or not exists(
        select 1
        from app.member_article_sizes size_profile
        where size_profile.member_season_id = orders.member_season_id
          and size_profile.article_id = line.article_id
          and size_profile.article_variant_id = line.article_variant_id
          and size_profile.selection_status in ('confirmed', 'locked')
          and size_profile.confirmed_at is not null
      )
    );
  select count(*)::integer into fulfilment_link_blockers
  from app.fulfilment_lines fulfilment_line
  where fulfilment_line.inventory_allocation_id is null;
  select count(*)::integer into locator_blockers
  from app.member_orders orders
  where private.order_qr_business_eligible(orders.id)
    and not exists(
      select 1
      from private.qr_order_identities identity
      join private.qr_order_locators locator
        on locator.identity_id = identity.id
        and locator.active
        and locator.pepper_fingerprint = p_pepper_fingerprint
        and locator.key_version = p_key_version
      where identity.order_id = orders.id
        and identity.suspended_at is null
    );
  select count(*)::integer into legacy_blockers
  from private.qr_tokens token
  where token.active;
  select count(*)::integer into key_blockers
  from private.qr_order_locators locator
  where locator.active
    and (
      locator.pepper_fingerprint <> p_pepper_fingerprint
      or locator.key_version <> p_key_version
    );
  select count(*)::integer into pickup_blockers
  from app.app_settings settings
  where settings.id = true
    and length(btrim(coalesce(settings.pickup_location, '')))
      not between 4 and 240;
  select flag.enabled into enabled
  from app.release_feature_flags flag
  where flag.key = 'allocation_qr_v2';
  ready := (inventory_report->>'ready')::boolean
    and queue_blockers = 0
    and balance_blockers = 0
    and ready_line_blockers = 0
    and allocation_blockers = 0
    and fulfilment_link_blockers = 0
    and locator_blockers = 0
    and legacy_blockers = 0
    and key_blockers = 0
    and pickup_blockers = 0;
  revision := encode(
    extensions.digest(
      concat_ws(
        '|',
        'allocation-qr-cutover-v2',
        inventory_report->>'hash',
        queue_blockers,
        balance_blockers,
        ready_line_blockers,
        allocation_blockers,
        fulfilment_link_blockers,
        locator_blockers,
        legacy_blockers,
        key_blockers,
        pickup_blockers,
        p_pepper_fingerprint,
        p_key_version,
        coalesce(enabled, false),
        ready
      ),
      'sha256'
    ),
    'hex'
  );
  return jsonb_build_object(
    'enabled', coalesce(enabled, false),
    'ready', ready,
    'revision', revision,
    'inventory', inventory_report,
    'queueBlockers', queue_blockers,
    'balanceBlockers', balance_blockers,
    'readyLineBlockers', ready_line_blockers,
    'allocationBlockers', allocation_blockers,
    'fulfilmentLinkBlockers', fulfilment_link_blockers,
    'locatorBlockers', locator_blockers,
    'activeLegacyQr', legacy_blockers,
    'keyBlockers', key_blockers,
    'pickupConfigurationBlockers', pickup_blockers,
    'keyVersion', p_key_version,
    'pepperFingerprint', p_pepper_fingerprint
  );
end;
$$;

revoke all on function private.allocation_qr_cutover_snapshot(text, integer)
from public, anon, authenticated, service_role;

create or replace function app.get_allocation_qr_cutover_snapshot(
  p_pepper_fingerprint text,
  p_key_version integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return private.allocation_qr_cutover_snapshot(
    p_pepper_fingerprint,
    p_key_version
  );
end;
$$;

create or replace function app.activate_allocation_qr_v2(
  p_expected_revision text,
  p_pepper_fingerprint text,
  p_key_version integer,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  snapshot jsonb;
  normalized_reason text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_pepper_fingerprint !~ '^[0-9a-f]{64}$'
    or p_key_version not between 1 and 9999
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'QR_CUTOVER_INPUT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('allocation-qr-cutover-v2', 0)
  );
  perform private.lock_inventory_mutation();
  lock table app.release_feature_flags in share row exclusive mode;
  lock table private.qr_order_identities in share row exclusive mode;
  lock table private.qr_order_locators in share row exclusive mode;
  lock table private.qr_tokens in share row exclusive mode;
  snapshot := private.allocation_qr_cutover_snapshot(
    p_pepper_fingerprint,
    p_key_version
  );
  if (snapshot->>'enabled')::boolean then
    return snapshot || jsonb_build_object('reused', true);
  end if;
  if snapshot->>'revision' <> p_expected_revision then
    raise exception 'QR_CUTOVER_STALE' using errcode = '40001';
  end if;
  if not (snapshot->>'ready')::boolean then
    raise exception 'QR_CUTOVER_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;

  insert into private.release_cutovers(key)
  values('allocation_qr_v2')
  on conflict (key) do nothing;
  update app.release_feature_flags
  set enabled = true,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where key in ('allocation_qr_v2', 'scanner_pwa_v2');
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    metadata,
    correlation_id
  ) values (
    actor,
    'release.allocation_qr_v2.activated',
    'release_feature_flag',
    jsonb_build_object(
      'inventoryHash', snapshot #>> '{inventory,hash}',
      'revision', p_expected_revision,
      'keyVersion', p_key_version,
      'pepperFingerprint', p_pepper_fingerprint,
      'reason', normalized_reason
    ),
    p_correlation_id
  );
  return private.allocation_qr_cutover_snapshot(
    p_pepper_fingerprint,
    p_key_version
  ) || jsonb_build_object('reused', false);
end;
$$;

revoke all on function app.get_allocation_qr_cutover_snapshot(text, integer)
from public, anon;
grant execute on function app.get_allocation_qr_cutover_snapshot(text, integer)
to authenticated;
revoke all on function app.activate_allocation_qr_v2(
  text, text, integer, text, uuid
) from public, anon;
grant execute on function app.activate_allocation_qr_v2(
  text, text, integer, text, uuid
) to authenticated;

-- The replacement artifact never accepts a legacy bearer. Historical
-- functions remain for forward-only schema compatibility but are unreachable.
revoke execute on function app.lookup_fulfilment(text)
from authenticated, service_role;
revoke execute on function app.commit_fulfilment_v2(
  uuid, uuid[], text, text
) from authenticated, service_role;
revoke execute on function app.correct_fulfilment_v2(
  uuid[], app.order_line_status, text
) from authenticated, service_role;
revoke execute on function app.get_order_qr_rotation_context(uuid, uuid)
from service_role;
revoke execute on function app.rotate_order_qr(
  uuid, uuid, integer, text, text
) from service_role;
revoke execute on function app.revoke_order_qr(uuid, uuid, text)
from service_role;

create or replace function app.expire_qr_scan_grants(
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  expired_count integer;
begin
  if p_limit not between 1 and 2000 then
    raise exception 'QR_GRANT_EXPIRY_LIMIT_INVALID' using errcode = '22023';
  end if;
  perform set_config('app.qr_internal', 'on', true);
  with expired as (
    select grant_row.id
    from private.qr_scan_grants grant_row
    where grant_row.consumed_at is null
      and grant_row.revoked_at is null
      and grant_row.expires_at <= timezone('utc', now())
    order by grant_row.expires_at, grant_row.id
    for update skip locked
    limit p_limit
  )
  update private.qr_scan_grants grant_row
  set revoked_at = timezone('utc', now()),
      revocation_reason = 'Scanbevoegdheid is verlopen'
  from expired
  where grant_row.id = expired.id;
  get diagnostics expired_count = row_count;
  perform set_config('app.qr_internal', 'off', true);
  return jsonb_build_object('expired', expired_count);
end;
$$;

revoke all on function app.expire_qr_scan_grants(integer)
from public, anon, authenticated, service_role;
grant execute on function app.expire_qr_scan_grants(integer)
to service_role;

create or replace function app.get_operational_health_v5()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  base jsonb := app.get_operational_health_v4();
  now_utc timestamptz := timezone('utc', now());
  latest private.operation_runs%rowtype;
  last_healthy timestamptz;
  inventory_operation jsonb;
begin
  select * into latest
  from private.operation_runs
  where operation = 'inventory_allocator'
  order by started_at desc
  limit 1;
  select max(finished_at) into last_healthy
  from private.operation_runs
  where operation = 'inventory_allocator'
    and status in ('succeeded', 'paused');
  inventory_operation := jsonb_build_object(
    'required', true,
    'lastStatus', latest.status,
    'lastStartedAt', latest.started_at,
    'lastSucceededAt', last_healthy,
    'stale',
      last_healthy is null
      or last_healthy < now_utc - interval '2 minutes',
    'runningStale', exists(
      select 1
      from private.operation_runs operation_run
      where operation_run.operation = 'inventory_allocator'
        and operation_run.status = 'running'
        and operation_run.started_at < now_utc - interval '2 minutes'
    )
  );
  return jsonb_set(
    base,
    '{operations}',
    (base->'operations')
      || jsonb_build_object('inventoryAllocator', inventory_operation)
  ) || jsonb_build_object(
    'qrControl',
    jsonb_build_object(
      'cutoverActive', private.inventory_v2_enabled(),
      'scannerActive', coalesce((
        select flag.enabled
        from app.release_feature_flags flag
        where flag.key = 'scanner_pwa_v2'
      ), false),
      'candidateOrders', (
        select count(*)
        from app.member_orders orders
        left join private.qr_order_identities identity
          on identity.order_id = orders.id
        where coalesce(identity.suspended_at is null, true)
          and not exists(
            select 1
            from private.qr_order_locators locator
            where locator.identity_id = identity.id
              and locator.active
          )
          and (
            exists(
              select 1
              from private.qr_tokens token
              where token.order_id = orders.id
                and token.active
            )
            or private.order_qr_business_eligible(orders.id)
          )
      ),
      'activeLegacyQr', (
        select count(*) from private.qr_tokens token where token.active
      ),
      'openGrants', (
        select count(*)
        from private.qr_scan_grants grant_row
        where grant_row.consumed_at is null
          and grant_row.revoked_at is null
          and grant_row.expires_at > now_utc
      ),
      'expiredOpenGrants', (
        select count(*)
        from private.qr_scan_grants grant_row
        where grant_row.consumed_at is null
          and grant_row.revoked_at is null
          and grant_row.expires_at <= now_utc
      )
    )
  );
end;
$$;

revoke all on function app.get_operational_health_v5()
from public, anon, authenticated;
grant execute on function app.get_operational_health_v5()
to service_role;

create or replace function app.get_operational_health_v6(
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
  base jsonb;
  key_mismatches integer;
  grant_key_mismatches integer;
  previous_key_locators integer;
  previous_key_grants integer;
begin
  if p_current_pepper_fingerprint !~ '^[0-9a-f]{64}$'
    or p_current_key_version not between 1 and 9999
    or (
      (p_previous_pepper_fingerprint is null)
        <> (p_previous_key_version is null)
    )
    or (
      p_previous_pepper_fingerprint is not null
      and (
        p_previous_pepper_fingerprint !~ '^[0-9a-f]{64}$'
        or p_previous_key_version not between 1 and 9999
        or p_previous_key_version = p_current_key_version
      )
    )
  then
    raise exception 'QR_HEALTH_KEY_INVALID' using errcode = '22023';
  end if;
  base := app.get_operational_health_v5();
  select count(*)::integer into key_mismatches
  from private.qr_order_locators locator
  where locator.active
    and (
      locator.pepper_fingerprint <> p_current_pepper_fingerprint
      or locator.key_version <> p_current_key_version
    )
    and (
      p_previous_pepper_fingerprint is null
      or locator.pepper_fingerprint <> p_previous_pepper_fingerprint
      or locator.key_version <> p_previous_key_version
    );
  select count(*)::integer into grant_key_mismatches
  from private.qr_scan_grants grant_row
  where grant_row.consumed_at is null
    and grant_row.revoked_at is null
    and grant_row.expires_at > timezone('utc', now())
    and grant_row.key_version <> p_current_key_version
    and (
      p_previous_key_version is null
      or grant_row.key_version <> p_previous_key_version
    );
  select count(*)::integer into previous_key_locators
  from private.qr_order_locators locator
  where locator.active
    and p_previous_key_version is not null
    and locator.key_version = p_previous_key_version
    and locator.pepper_fingerprint = p_previous_pepper_fingerprint;
  select count(*)::integer into previous_key_grants
  from private.qr_scan_grants grant_row
  where grant_row.consumed_at is null
    and grant_row.revoked_at is null
    and grant_row.expires_at > timezone('utc', now())
    and p_previous_key_version is not null
    and grant_row.key_version = p_previous_key_version;
  return jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          base,
          '{qrControl,keyMismatchActiveLocators}',
          to_jsonb(key_mismatches),
          true
        ),
        '{qrControl,keyMismatchOpenGrants}',
        to_jsonb(grant_key_mismatches),
        true
      ),
      '{qrControl,previousKeyActiveLocators}',
      to_jsonb(previous_key_locators),
      true
    ),
    '{qrControl,previousKeyOpenGrants}',
    to_jsonb(previous_key_grants),
    true
  );
end;
$$;

revoke all on function app.get_operational_health_v6(
  text, integer, text, integer
)
from public, anon, authenticated, service_role;
grant execute on function app.get_operational_health_v6(
  text, integer, text, integer
)
to service_role;

-- Keep the existing member-detail contract, but make QR management reflect
-- the v2 locator lifecycle after the one-way bearer cutover. "Actief" here
-- denotes an active credential; every scanner exchange still rechecks payment,
-- allocation, season and feature-cutover eligibility server-side.
create or replace function app.get_member_detail_v3(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  target_role app.staff_role;
  target_order_id uuid;
  qr_status text;
begin
  result := app.get_member_detail_v2(p_member_id);
  target_role := app.staff_role();
  target_order_id := nullif(result #>> '{order,id}', '')::uuid;
  if target_order_id is not null then
    qr_status := case
      when exists(
        select 1
        from private.qr_order_identities identity
        join private.qr_order_locators locator
          on locator.identity_id = identity.id
          and locator.active
        where identity.order_id = target_order_id
          and identity.suspended_at is null
      ) then 'Actief'
      when exists(
        select 1
        from private.qr_tokens token
        where token.order_id = target_order_id
          and token.active
      ) then 'Actief'
      when exists(
        select 1
        from private.qr_order_identities identity
        where identity.order_id = target_order_id
      ) or exists(
        select 1
        from private.qr_tokens token
        where token.order_id = target_order_id
      ) then 'Ingetrokken'
      else 'Niet aangemaakt'
    end;
    result := jsonb_set(
      result,
      '{order,qrStatus}',
      to_jsonb(qr_status),
      false
    );
  end if;
  return result || jsonb_build_object(
    'gender', (
      select member.gender::text
      from app.members member
      where member.id = p_member_id
    ),
    'dateOfBirth', case when target_role = 'beheerder' then (
      select identity.date_of_birth
      from private.member_sensitive_identity identity
      where identity.member_id = p_member_id
    ) else null end,
    'memberSeasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', member_season.id,
        'seasonId', member_season.season_id,
        'seasonName', season.name,
        'team', member_season.team_name,
        'participationStatus', member_season.participation_status::text,
        'reconciliationStatus', member_season.reconciliation_status::text
      ) order by season.starts_on desc nulls last, season.name desc)
      from app.member_seasons member_season
      join app.seasons season on season.id = member_season.season_id
      where member_season.member_id = p_member_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_member_detail_v3(uuid)
from public, anon;
grant execute on function app.get_member_detail_v3(uuid)
to authenticated;

notify pgrst, 'reload schema';
