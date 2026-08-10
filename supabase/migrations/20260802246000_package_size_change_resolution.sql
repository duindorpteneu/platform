-- Durable package-size change requests and administrator-only resolution.
--
-- A reserved size is never overwritten in place. The parent request is kept as
-- a separate historical record. Approval releases the exact reservation and
-- changes the logistical line atomically; rejection leaves stock untouched.

create table app.package_size_change_requests (
  id uuid primary key default gen_random_uuid(),
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  order_id uuid not null
    references app.member_orders(id) on delete restrict,
  order_line_id uuid not null
    references app.order_lines(id) on delete restrict,
  article_id uuid not null
    references app.articles(id) on delete restrict,
  current_variant_id uuid not null,
  requested_variant_id uuid,
  requested_raw_value text,
  requested_member_note text,
  parent_account_id uuid not null
    references private.parent_accounts(id) on delete restrict,
  status text not null default 'requested' check (
    status in ('requested', 'approved', 'rejected', 'superseded')
  ),
  requested_at timestamptz not null,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_reason text,
  approved_variant_id uuid,
  released_reservation_id uuid
    references app.inventory_reservations(id) on delete restrict,
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now()),
  constraint package_size_change_current_variant_fkey
    foreign key (current_variant_id, article_id)
    references app.article_variants(id, article_id)
    on delete restrict,
  constraint package_size_change_requested_variant_fkey
    foreign key (requested_variant_id, article_id)
    references app.article_variants(id, article_id)
    on delete restrict,
  constraint package_size_change_approved_variant_fkey
    foreign key (approved_variant_id, article_id)
    references app.article_variants(id, article_id)
    on delete restrict,
  constraint package_size_change_payload_check check (
    (
      requested_variant_id is not null
      and requested_raw_value is null
      and requested_member_note is null
    )
    or (
      requested_variant_id is null
      and requested_raw_value = 'Anders…'
      and length(btrim(coalesce(requested_member_note, '')))
        between 1 and 500
    )
  ),
  constraint package_size_change_lifecycle_check check (
    (
      status = 'requested'
      and resolved_at is null
      and resolved_by is null
      and resolution_reason is null
      and approved_variant_id is null
      and released_reservation_id is null
    )
    or (
      status = 'approved'
      and resolved_at is not null
      and resolved_by is not null
      and length(btrim(coalesce(resolution_reason, '')))
        between 3 and 500
      and approved_variant_id is not null
      and released_reservation_id is not null
    )
    or (
      status = 'rejected'
      and resolved_at is not null
      and resolved_by is not null
      and length(btrim(coalesce(resolution_reason, '')))
        between 3 and 500
      and approved_variant_id is null
      and released_reservation_id is null
    )
    or (
      status = 'superseded'
      and resolved_at is not null
      and resolved_by is null
      and length(btrim(coalesce(resolution_reason, '')))
        between 3 and 500
      and approved_variant_id is null
      and released_reservation_id is null
    )
  )
);

create unique index package_size_change_one_open_line_idx
  on app.package_size_change_requests(order_line_id)
  where status = 'requested';
create index package_size_change_queue_idx
  on app.package_size_change_requests(
    status,
    member_season_id,
    requested_at,
    id
  );

alter table app.package_size_change_requests enable row level security;
create policy "clothing staff can read package size change requests"
on app.package_size_change_requests
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);
revoke all on table app.package_size_change_requests
from public, anon, authenticated, service_role;
grant select on table app.package_size_change_requests to authenticated;

create or replace function app.protect_package_size_change_request()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'PACKAGE_SIZE_CHANGE_IMMUTABLE' using errcode = '23514';
  end if;
  if old.member_season_id is distinct from new.member_season_id
    or old.order_id is distinct from new.order_id
    or old.order_line_id is distinct from new.order_line_id
    or old.article_id is distinct from new.article_id
    or old.current_variant_id is distinct from new.current_variant_id
    or old.requested_variant_id is distinct from new.requested_variant_id
    or old.requested_raw_value is distinct from new.requested_raw_value
    or old.requested_member_note is distinct from new.requested_member_note
    or old.parent_account_id is distinct from new.parent_account_id
    or old.requested_at is distinct from new.requested_at
    or old.correlation_id is distinct from new.correlation_id
    or old.created_at is distinct from new.created_at
    or old.status <> 'requested'
    or new.status not in ('approved', 'rejected', 'superseded')
  then
    raise exception 'PACKAGE_SIZE_CHANGE_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger package_size_change_requests_protect
before update or delete on app.package_size_change_requests
for each row execute function app.protect_package_size_change_request();

create or replace function private.capture_package_size_change_request()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_order_id uuid;
  target_line_id uuid;
  target_current_variant_id uuid;
  target_reservation_id uuid;
begin
  if new.selection_status <> 'change_requested' then
    return new;
  end if;
  if tg_op = 'UPDATE'
    and old.selection_status = 'change_requested'
    and old.article_variant_id is not distinct from new.article_variant_id
    and old.requested_article_variant_id
      is not distinct from new.requested_article_variant_id
    and old.requested_raw_value is not distinct from new.requested_raw_value
    and old.requested_member_note is not distinct from new.requested_member_note
    and old.requested_by_parent_account_id
      is not distinct from new.requested_by_parent_account_id
    and old.requested_at is not distinct from new.requested_at
  then
    return new;
  end if;

  select orders.id, line.id, line.article_variant_id, reservation.id
  into
    target_order_id,
    target_line_id,
    target_current_variant_id,
    target_reservation_id
  from app.member_orders orders
  join app.order_lines line
    on line.order_id = orders.id
    and line.article_id = new.article_id
    and line.status <> 'cancelled'
  join app.inventory_reservations reservation
    on reservation.order_line_id = line.id
    and reservation.status = 'reserved'
  where orders.member_season_id = new.member_season_id
  order by line.created_at desc, line.id desc
  limit 1;

  if target_line_id is null
    or target_current_variant_id is distinct from new.article_variant_id
    or new.requested_by_parent_account_id is null
    or new.requested_at is null
  then
    raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
      using errcode = '23514';
  end if;

  update app.package_size_change_requests request
  set status = 'superseded',
      resolved_at = timezone('utc', now()),
      resolution_reason = 'Vervangen door een nieuwer ouderverzoek'
  where request.order_line_id = target_line_id
    and request.status = 'requested';

  insert into app.package_size_change_requests(
    member_season_id,
    order_id,
    order_line_id,
    article_id,
    current_variant_id,
    requested_variant_id,
    requested_raw_value,
    requested_member_note,
    parent_account_id,
    requested_at
  )
  values(
    new.member_season_id,
    target_order_id,
    target_line_id,
    new.article_id,
    new.article_variant_id,
    new.requested_article_variant_id,
    new.requested_raw_value,
    new.requested_member_note,
    new.requested_by_parent_account_id,
    new.requested_at
  );
  return new;
end;
$$;

create trigger member_article_sizes_capture_package_change
after insert or update of
  selection_status,
  article_variant_id,
  requested_article_variant_id,
  requested_raw_value,
  requested_member_note,
  requested_by_parent_account_id,
  requested_at
on app.member_article_sizes
for each row execute function private.capture_package_size_change_request();

insert into app.package_size_change_requests(
  member_season_id,
  order_id,
  order_line_id,
  article_id,
  current_variant_id,
  requested_variant_id,
  requested_raw_value,
  requested_member_note,
  parent_account_id,
  requested_at
)
select
  size_profile.member_season_id,
  orders.id,
  line.id,
  size_profile.article_id,
  size_profile.article_variant_id,
  size_profile.requested_article_variant_id,
  size_profile.requested_raw_value,
  size_profile.requested_member_note,
  size_profile.requested_by_parent_account_id,
  size_profile.requested_at
from app.member_article_sizes size_profile
join app.member_orders orders
  on orders.member_season_id = size_profile.member_season_id
join app.order_lines line
  on line.order_id = orders.id
  and line.article_id = size_profile.article_id
  and line.status <> 'cancelled'
join app.inventory_reservations reservation
  on reservation.order_line_id = line.id
  and reservation.status = 'reserved'
where size_profile.selection_status = 'change_requested'
on conflict do nothing;

do $$
begin
  if exists(
    select 1
    from app.member_article_sizes size_profile
    where size_profile.selection_status = 'change_requested'
      and not exists(
        select 1
        from app.package_size_change_requests request
        where request.member_season_id = size_profile.member_season_id
          and request.article_id = size_profile.article_id
          and request.status = 'requested'
      )
  ) then
    raise exception 'PACKAGE_SIZE_CHANGE_BACKFILL_RECONCILIATION_FAILED';
  end if;
end;
$$;

create or replace function app.resolve_package_size_change(
  p_request_id uuid,
  p_decision text,
  p_approved_variant_id uuid,
  p_reason text,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target app.package_size_change_requests%rowtype;
  member_season app.member_seasons%rowtype;
  size_profile app.member_article_sizes%rowtype;
  line app.order_lines%rowtype;
  reservation app.inventory_reservations%rowtype;
  receipt_line_id uuid;
  action_key text;
  action_id uuid;
  issued boolean;
  next_status text;
  target_member_season_id uuid;
begin
  if p_request_id is null
    or p_decision not in ('approve', 'reject')
    or length(btrim(coalesce(p_reason, ''))) not between 3 and 500
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or (p_decision = 'approve' and p_approved_variant_id is null)
    or (p_decision = 'reject' and p_approved_variant_id is not null)
  then
    raise exception 'PACKAGE_SIZE_CHANGE_RESOLUTION_INVALID'
      using errcode = '22023';
  end if;

  select request.member_season_id
  into target_member_season_id
  from app.package_size_change_requests request
  where request.id = p_request_id;
  if not found then
    raise exception 'PACKAGE_SIZE_CHANGE_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || target_member_season_id::text,
      0
    )
  );
  select *
  into target
  from app.package_size_change_requests request
  where request.id = p_request_id
  for update;

  if target.status <> 'requested' then
    if (
      p_decision = 'approve'
      and target.status = 'approved'
      and target.approved_variant_id = p_approved_variant_id
      and target.resolution_reason = btrim(p_reason)
    ) or (
      p_decision = 'reject'
      and target.status = 'rejected'
      and target.resolution_reason = btrim(p_reason)
    ) then
      return jsonb_build_object(
        'requestId', target.id,
        'memberSeasonId', target.member_season_id,
        'orderLineId', target.order_line_id,
        'status', target.status,
        'releasedReservationId', target.released_reservation_id,
        'revision',
          private.package_workspace_revision(target.member_season_id),
        'reused', true
      );
    end if;
    raise exception 'PACKAGE_SIZE_CHANGE_ALREADY_RESOLVED'
      using errcode = '40001';
  end if;

  select *
  into member_season
  from app.member_seasons current_season
  where current_season.id = target.member_season_id
  for update;

  select active_reservation.receipt_line_id
  into receipt_line_id
  from app.inventory_reservations active_reservation
  where active_reservation.order_line_id = target.order_line_id
    and active_reservation.status in ('reserved', 'fulfilled')
  order by active_reservation.created_at desc, active_reservation.id desc
  limit 1;
  if receipt_line_id is not null then
    perform 1
    from app.delivery_receipt_lines receipt_line
    where receipt_line.id = receipt_line_id
    for update;
  end if;

  select *
  into line
  from app.order_lines order_line
  where order_line.id = target.order_line_id
  for update;
  if not found then
    raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
      using errcode = '23514';
  end if;

  select *
  into reservation
  from app.inventory_reservations active_reservation
  where active_reservation.order_line_id = target.order_line_id
    and active_reservation.status in ('reserved', 'fulfilled')
  order by active_reservation.created_at desc, active_reservation.id desc
  limit 1
  for update;

  select *
  into size_profile
  from app.member_article_sizes current_size
  where current_size.member_season_id = target.member_season_id
    and current_size.article_id = target.article_id
  for update;

  if private.package_workspace_revision(target.member_season_id)
    <> p_expected_revision
  then
    raise exception 'PACKAGE_SIZE_CHANGE_CONFLICT' using errcode = '40001';
  end if;
  if member_season.id is null
    or line.order_id <> target.order_id
    or line.article_id <> target.article_id
    or line.article_variant_id <> target.current_variant_id
    or size_profile.selection_status <> 'change_requested'
    or size_profile.article_variant_id <> target.current_variant_id
    or size_profile.requested_article_variant_id
      is distinct from target.requested_variant_id
    or size_profile.requested_raw_value
      is distinct from target.requested_raw_value
    or size_profile.requested_member_note
      is distinct from target.requested_member_note
  then
    raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
      using errcode = '23514';
  end if;

  issued := line.status = 'picked_up' or exists(
    select 1
    from app.fulfilment_lines fulfilment_line
    where fulfilment_line.order_line_id = line.id
      and fulfilment_line.reversed_at is null
  );
  if issued and p_decision = 'approve' then
    raise exception 'PACKAGE_SIZE_CHANGE_ISSUED_LOCKED'
      using errcode = '23514';
  end if;

  action_key := encode(extensions.digest(
    'size-change-reserved:' || target.member_season_id::text || ':' ||
      target.article_id::text,
    'sha256'
  ), 'hex');
  select item.id
  into action_id
  from app.action_items item
  where item.type = 'size_change_after_reservation'
    and item.season_id = member_season.season_id
    and item.dedupe_key = action_key
    and item.status in ('open', 'in_progress')
  for update;

  if p_decision = 'approve' then
    if reservation.id is null or reservation.status <> 'reserved' then
      raise exception 'PACKAGE_SIZE_CHANGE_RESERVATION_REQUIRED'
        using errcode = '23514';
    end if;
    if not exists(
      select 1
      from app.article_variants variant
      join app.article_seasons article_season
        on article_season.article_id = variant.article_id
        and article_season.season_id = member_season.season_id
      where variant.id = p_approved_variant_id
        and variant.article_id = target.article_id
        and variant.active
    ) then
      raise exception 'PACKAGE_SIZE_CHANGE_VARIANT_INVALID'
        using errcode = '22023';
    end if;

    update app.inventory_reservations
    set status = 'released',
        updated_at = timezone('utc', now())
    where id = reservation.id;

    perform set_config('app.package_size_internal', 'on', true);
    update app.member_article_sizes
    set article_variant_id = p_approved_variant_id,
        selection_status = 'confirmed',
        selection_source = 'parent',
        raw_value = null,
        member_note = null,
        confirmed_at = timezone('utc', now()),
        confirmed_by = actor,
        confirmed_by_parent_account_id = target.parent_account_id,
        requested_article_variant_id = null,
        requested_raw_value = null,
        requested_member_note = null,
        requested_at = null,
        requested_by_parent_account_id = null,
        updated_by = actor,
        updated_at = timezone('utc', now())
    where member_season_id = target.member_season_id
      and article_id = target.article_id;
    update app.order_lines
    set article_variant_id = p_approved_variant_id,
        status = 'backorder',
        updated_at = timezone('utc', now())
    where id = line.id;
    perform set_config('app.package_size_internal', 'off', true);

    update app.package_size_change_requests
    set status = 'approved',
        resolved_at = timezone('utc', now()),
        resolved_by = actor,
        resolution_reason = btrim(p_reason),
        approved_variant_id = p_approved_variant_id,
        released_reservation_id = reservation.id
    where id = target.id;
    next_status := 'approved';
    if action_id is not null then
      perform app.resolve_action_item(
        action_id,
        'resolved',
        btrim(p_reason),
        p_correlation_id
      );
    end if;
    perform app.refresh_order_status(target.order_id);
  else
    update app.member_article_sizes
    set selection_status = case
          when issued then 'locked'::app.size_selection_status
          else 'confirmed'::app.size_selection_status
        end,
        requested_article_variant_id = null,
        requested_raw_value = null,
        requested_member_note = null,
        requested_at = null,
        requested_by_parent_account_id = null,
        updated_by = actor,
        updated_at = timezone('utc', now())
    where member_season_id = target.member_season_id
      and article_id = target.article_id;

    update app.package_size_change_requests
    set status = 'rejected',
        resolved_at = timezone('utc', now()),
        resolved_by = actor,
        resolution_reason = btrim(p_reason)
    where id = target.id;
    next_status := 'rejected';
    if action_id is not null then
      perform app.resolve_action_item(
        action_id,
        'dismissed',
        btrim(p_reason),
        p_correlation_id
      );
    end if;
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  )
  values(
    actor,
    'order.package_size_change.' || next_status,
    'package_size_change_request',
    target.id,
    jsonb_build_object(
      'memberSeasonId', target.member_season_id,
      'orderId', target.order_id,
      'orderLineId', target.order_line_id,
      'articleId', target.article_id,
      'releasedReservationId', case
        when next_status = 'approved' then reservation.id
        else null
      end
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'requestId', target.id,
    'memberSeasonId', target.member_season_id,
    'orderLineId', target.order_line_id,
    'status', next_status,
    'releasedReservationId', case
      when next_status = 'approved' then reservation.id
      else null
    end,
    'revision', private.package_workspace_revision(target.member_season_id),
    'reused', false
  );
end;
$$;

create or replace function app.sync_member_size_from_order_line()
returns trigger
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  target_member_id uuid;
  target_season_id uuid;
  target_member_season_id uuid;
  existing_size app.member_article_sizes%rowtype;
  change_key text;
begin
  if new.status = 'cancelled' then
    return new;
  end if;

  select orders.member_id, orders.season_id, orders.member_season_id
  into target_member_id, target_season_id, target_member_season_id
  from app.member_orders orders
  where orders.id = new.order_id;

  if not exists(
    select 1
    from app.article_seasons link
    where link.article_id = new.article_id
      and link.season_id = target_season_id
  ) then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  select *
  into existing_size
  from app.member_article_sizes size_profile
  where size_profile.member_id = target_member_id
    and size_profile.season_id = target_season_id
    and size_profile.article_id = new.article_id
  for update;

  if found
    and existing_size.article_variant_id is distinct from new.article_variant_id
    and existing_size.selection_status in (
      'confirmed',
      'change_requested',
      'locked'
    )
  then
    raise exception 'CONFIRMED_SIZE_CHANGE_REQUIRES_WORKFLOW'
      using errcode = '23514';
  end if;
  if found and existing_size.selection_status = 'conflict' then
    raise exception 'SIZE_CONFLICT_MUST_BE_RESOLVED'
      using errcode = '23514';
  end if;

  if found
    and new.status = 'picked_up'
    and existing_size.article_variant_id = new.article_variant_id
  then
    if existing_size.selection_status = 'change_requested' then
      update app.package_size_change_requests request
      set status = 'superseded',
          resolved_at = timezone('utc', now()),
          resolution_reason = 'Vervallen doordat de werkelijke maat is uitgegeven'
      where request.order_line_id = new.id
        and request.status = 'requested';
      change_key := encode(extensions.digest(
        'size-change-reserved:' || target_member_season_id::text || ':' ||
          new.article_id::text,
        'sha256'
      ), 'hex');
      perform private.auto_resolve_action_item(
        'size_change_after_reservation',
        target_season_id,
        change_key,
        'Automatisch gesloten doordat de werkelijke maat is uitgegeven'
      );
    end if;
    update app.member_article_sizes
    set selection_status = 'locked',
        requested_article_variant_id = null,
        requested_raw_value = null,
        requested_member_note = null,
        requested_at = null,
        requested_by_parent_account_id = null,
        updated_at = timezone('utc', now())
    where member_id = target_member_id
      and season_id = target_season_id
      and article_id = new.article_id;
    return new;
  end if;

  if found
    and existing_size.selection_status in (
      'confirmed',
      'change_requested',
      'locked'
    )
    and existing_size.article_variant_id = new.article_variant_id
  then
    return new;
  end if;

  insert into app.member_article_sizes(
    member_id,
    season_id,
    member_season_id,
    article_id,
    article_variant_id,
    selection_status,
    selection_source,
    confirmed_at,
    created_by,
    updated_by
  )
  values(
    target_member_id,
    target_season_id,
    target_member_season_id,
    new.article_id,
    new.article_variant_id,
    'confirmed',
    'order',
    timezone('utc', now()),
    auth.uid(),
    auth.uid()
  )
  on conflict(member_id, season_id, article_id) do update
  set article_variant_id = excluded.article_variant_id,
      selection_status = 'confirmed',
      selection_source = 'order',
      raw_value = null,
      member_note = null,
      confirmed_at = excluded.confirmed_at,
      confirmed_by = auth.uid(),
      confirmed_by_parent_account_id = null,
      requested_article_variant_id = null,
      requested_raw_value = null,
      requested_member_note = null,
      requested_at = null,
      requested_by_parent_account_id = null,
      updated_by = auth.uid(),
      updated_at = timezone('utc', now())
  where app.member_article_sizes.selection_status = 'imported_unconfirmed';

  return new;
end;
$$;

revoke all on function app.protect_package_size_change_request()
from public, anon, authenticated, service_role;
revoke all on function private.capture_package_size_change_request()
from public, anon, authenticated, service_role;
revoke all on function app.resolve_package_size_change(
  uuid, text, uuid, text, text, uuid
) from public, anon;
grant execute on function app.resolve_package_size_change(
  uuid, text, uuid, text, text, uuid
) to authenticated;
revoke all on function app.sync_member_size_from_order_line()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
