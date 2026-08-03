-- Close three false-green package-size cases:
-- 1. a missing size row is never a complete package;
-- 2. UUID spelling cannot duplicate one selection while omitting another;
-- 3. approving a reserved size change preserves the historical old order line.

alter table app.package_size_change_requests
  add column replacement_order_line_id uuid
    references app.order_lines(id) on delete restrict;

alter table app.package_size_change_requests
  drop constraint package_size_change_lifecycle_check;

alter table app.package_size_change_requests
  add constraint package_size_change_lifecycle_check check (
    (
      status = 'requested'
      and resolved_at is null
      and resolved_by is null
      and resolution_reason is null
      and approved_variant_id is null
      and released_reservation_id is null
      and replacement_order_line_id is null
    )
    or (
      status = 'approved'
      and resolved_at is not null
      and resolved_by is not null
      and length(btrim(coalesce(resolution_reason, '')))
        between 3 and 500
      and approved_variant_id is not null
      and released_reservation_id is not null
      and replacement_order_line_id is not null
    )
    or (
      status = 'rejected'
      and resolved_at is not null
      and resolved_by is not null
      and length(btrim(coalesce(resolution_reason, '')))
        between 3 and 500
      and approved_variant_id is null
      and released_reservation_id is null
      and replacement_order_line_id is null
    )
    or (
      status = 'superseded'
      and resolved_at is not null
      and resolved_by is null
      and length(btrim(coalesce(resolution_reason, '')))
        between 3 and 500
      and approved_variant_id is null
      and released_reservation_id is null
      and replacement_order_line_id is null
    )
  ) not valid;

alter table app.package_size_change_requests
  validate constraint package_size_change_lifecycle_check;

create or replace function private.package_sizes_complete(
  p_order_id uuid,
  p_snapshot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select p_order_id is not null
    and p_snapshot_id is not null
    and exists(
      select 1
      from app.order_package_snapshot_items package_item
      where package_item.snapshot_id = p_snapshot_id
    )
    and not exists(
      select 1
      from app.order_package_snapshot_items snapshot_item
      left join app.member_orders orders on orders.id = p_order_id
      left join app.member_article_sizes size_profile
        on size_profile.member_season_id = orders.member_season_id
        and size_profile.article_id = snapshot_item.article_id
      where snapshot_item.snapshot_id = p_snapshot_id
        and not coalesce(
          size_profile.selection_status in (
            'confirmed',
            'locked',
            'change_requested'
          )
          or (
            size_profile.selection_status = 'conflict'
            and size_profile.selection_source = 'parent'
            and size_profile.confirmed_at is not null
            and length(btrim(coalesce(size_profile.member_note, '')))
              between 1 and 500
          ),
          false
        )
    );
$$;

revoke all on function private.package_sizes_complete(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function public.confirm_parent_package_sizes_v3(
  p_token_hash text,
  p_member_season_id uuid,
  p_selections jsonb,
  p_expected_revision text,
  p_request_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  account_id uuid;
  target_member_id uuid;
  target_order_id uuid;
  existing_confirmation_id uuid;
begin
  if p_member_season_id is null
    or p_request_id is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_selections is null
    or jsonb_typeof(p_selections) <> 'array'
    or jsonb_array_length(p_selections) not between 1 and 25
    or exists(
      select 1
      from jsonb_array_elements(p_selections) selection
      where jsonb_typeof(selection.value) <> 'object'
        or coalesce(selection.value->>'articleId', '') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    )
  then
    raise exception 'PACKAGE_SIZE_SELECTION_INVALID' using errcode = '22023';
  end if;
  account_id := private.parent_account_for_member_season(
    p_token_hash,
    p_member_season_id
  );
  if account_id is null then
    raise exception 'PARENT_MEMBER_SEASON_ACCESS_DENIED' using errcode = '42501';
  end if;
  select member_season.member_id
  into target_member_id
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;
  if target_member_id is null then
    raise exception 'MEMBER_SEASON_NOT_ELIGIBLE' using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || p_member_season_id::text,
      0
    )
  );
  perform 1
  from app.member_seasons member_season
  where member_season.id = p_member_season_id
  for update;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'package-size-request:' || p_request_id::text,
      0
    )
  );
  select orders.id
  into target_order_id
  from app.member_orders orders
  where orders.member_season_id = p_member_season_id
  for update;
  if target_order_id is null then
    raise exception 'PACKAGE_ORDER_REQUIRED' using errcode = '23514';
  end if;
  select confirmation.id
  into existing_confirmation_id
  from app.package_size_confirmations confirmation
  where confirmation.order_id = target_order_id
    and confirmation.request_id = p_request_id;
  if existing_confirmation_id is null and exists(
    select 1
    from app.member_article_sizes size_profile
    where size_profile.member_season_id = p_member_season_id
      and size_profile.selection_status = 'locked'
  ) then
    raise exception 'PACKAGE_SIZE_ISSUED_LOCKED' using errcode = '23514';
  end if;
  if (
    select count(distinct (selection.value->>'articleId')::uuid)
    from jsonb_array_elements(p_selections) selection
  ) <> jsonb_array_length(p_selections)
  then
    raise exception 'PACKAGE_SIZE_SELECTION_INVALID' using errcode = '22023';
  end if;
  return public.confirm_parent_package_sizes_v2(
    p_token_hash,
    p_member_season_id,
    p_selections,
    p_expected_revision,
    p_request_id,
    p_correlation_id
  );
end;
$$;

revoke execute on function public.confirm_parent_package_sizes_v2(
  text, uuid, jsonb, text, uuid, uuid
) from service_role;
revoke all on function public.confirm_parent_package_sizes_v3(
  text, uuid, jsonb, text, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.confirm_parent_package_sizes_v3(
  text, uuid, jsonb, text, uuid, uuid
) to service_role;

create or replace function app.resolve_package_size_change_v2(
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
  old_line app.order_lines%rowtype;
  new_line app.order_lines%rowtype;
  reservation app.inventory_reservations%rowtype;
  receipt_line_id uuid;
  action_key text;
  action_id uuid;
  target_member_season_id uuid;
begin
  if p_decision = 'reject' then
    return app.resolve_package_size_change(
      p_request_id,
      p_decision,
      p_approved_variant_id,
      p_reason,
      p_expected_revision,
      p_correlation_id
    );
  end if;
  if p_request_id is null
    or p_decision <> 'approve'
    or p_approved_variant_id is null
    or length(btrim(coalesce(p_reason, ''))) not between 3 and 500
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
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
    if target.status = 'approved'
      and target.approved_variant_id = p_approved_variant_id
      and target.resolution_reason = btrim(p_reason)
    then
      return jsonb_build_object(
        'requestId', target.id,
        'memberSeasonId', target.member_season_id,
        'orderLineId', target.replacement_order_line_id,
        'replacedOrderLineId', target.order_line_id,
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
  if not found then
    raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
      using errcode = '23514';
  end if;

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
  into old_line
  from app.order_lines order_line
  where order_line.id = target.order_line_id
  for update;
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
  if old_line.id is null
    or old_line.order_id <> target.order_id
    or old_line.article_id <> target.article_id
    or old_line.article_variant_id <> target.current_variant_id
    or old_line.status = 'picked_up'
    or reservation.id is null
    or reservation.status <> 'reserved'
    or size_profile.selection_status <> 'change_requested'
    or size_profile.article_variant_id <> target.current_variant_id
    or size_profile.requested_article_variant_id
      is distinct from target.requested_variant_id
    or size_profile.requested_raw_value
      is distinct from target.requested_raw_value
    or size_profile.requested_member_note
      is distinct from target.requested_member_note
    or exists(
      select 1
      from app.fulfilment_lines fulfilment_line
      where fulfilment_line.order_line_id = old_line.id
        and fulfilment_line.reversed_at is null
    )
  then
    raise exception 'PACKAGE_SIZE_CHANGE_STATE_INVALID'
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
  set status = 'cancelled',
      updated_at = timezone('utc', now())
  where id = old_line.id;
  insert into app.order_lines(
    order_id,
    article_variant_id,
    quantity,
    package_template_item_id
  )
  values(
    old_line.order_id,
    p_approved_variant_id,
    old_line.quantity,
    old_line.package_template_item_id
  )
  returning * into new_line;
  perform set_config('app.package_size_internal', 'off', true);

  update app.package_size_change_requests
  set status = 'approved',
      resolved_at = timezone('utc', now()),
      resolved_by = actor,
      resolution_reason = btrim(p_reason),
      approved_variant_id = p_approved_variant_id,
      released_reservation_id = reservation.id,
      replacement_order_line_id = new_line.id
  where id = target.id;
  if action_id is not null then
    perform app.resolve_action_item(
      action_id,
      'resolved',
      btrim(p_reason),
      p_correlation_id
    );
  end if;
  perform app.refresh_order_status(target.order_id);

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
    'order.package_size_change.approved',
    'package_size_change_request',
    target.id,
    jsonb_build_object(
      'memberSeasonId', target.member_season_id,
      'orderId', target.order_id,
      'replacedOrderLineId', old_line.id,
      'replacementOrderLineId', new_line.id,
      'articleId', target.article_id,
      'releasedReservationId', reservation.id
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'requestId', target.id,
    'memberSeasonId', target.member_season_id,
    'orderLineId', new_line.id,
    'replacedOrderLineId', old_line.id,
    'status', 'approved',
    'releasedReservationId', reservation.id,
    'revision', private.package_workspace_revision(target.member_season_id),
    'reused', false
  );
end;
$$;

revoke execute on function app.resolve_package_size_change(
  uuid, text, uuid, text, text, uuid
) from authenticated;
revoke all on function app.resolve_package_size_change_v2(
  uuid, text, uuid, text, text, uuid
) from public, anon;
grant execute on function app.resolve_package_size_change_v2(
  uuid, text, uuid, text, text, uuid
) to authenticated;

create or replace function public.select_parent_package_v2(
  p_token_hash text,
  p_member_season_id uuid,
  p_package_revision_id uuid,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  account_id uuid;
  target_member_id uuid;
begin
  account_id := private.parent_account_for_member_season(
    p_token_hash,
    p_member_season_id
  );
  if account_id is null then
    raise exception 'PARENT_MEMBER_SEASON_ACCESS_DENIED' using errcode = '42501';
  end if;
  select member_season.member_id
  into target_member_id
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;
  if target_member_id is null then
    raise exception 'MEMBER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  return public.select_parent_package(
    p_token_hash,
    p_member_season_id,
    p_package_revision_id,
    p_expected_revision,
    p_correlation_id
  );
end;
$$;

create or replace function app.select_member_package_v2(
  p_member_season_id uuid,
  p_package_revision_id uuid,
  p_expected_revision text,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_id uuid;
begin
  perform private.require_admin_aal2();
  select member_season.member_id
  into target_member_id
  from app.member_seasons member_season
  where member_season.id = p_member_season_id;
  if target_member_id is null then
    raise exception 'MEMBER_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  return app.select_member_package(
    p_member_season_id,
    p_package_revision_id,
    p_expected_revision,
    p_reason,
    p_correlation_id
  );
end;
$$;

revoke execute on function public.select_parent_package(
  text, uuid, uuid, text, uuid
) from service_role;
revoke all on function public.select_parent_package_v2(
  text, uuid, uuid, text, uuid
) from public, anon, authenticated;
grant execute on function public.select_parent_package_v2(
  text, uuid, uuid, text, uuid
) to service_role;
revoke execute on function app.select_member_package(
  uuid, uuid, text, text, uuid
) from authenticated;
revoke all on function app.select_member_package_v2(
  uuid, uuid, text, text, uuid
) from public, anon;
grant execute on function app.select_member_package_v2(
  uuid, uuid, text, text, uuid
) to authenticated;

create or replace function app.publish_package_revision_v2(
  p_revision_id uuid,
  p_make_default boolean,
  p_expected_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_season_id uuid;
begin
  perform private.require_admin_aal2();
  select revision.season_id
  into target_season_id
  from app.package_template_revisions revision
  where revision.id = p_revision_id;
  if target_season_id is null then
    raise exception 'PACKAGE_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('package-season:' || target_season_id::text, 0)
  );
  return app.publish_package_revision(
    p_revision_id,
    p_make_default,
    p_expected_hash,
    p_correlation_id
  );
end;
$$;

revoke execute on function app.publish_package_revision(
  uuid, boolean, text, uuid
) from authenticated;
revoke all on function app.publish_package_revision_v2(
  uuid, boolean, text, uuid
) from public, anon;
grant execute on function app.publish_package_revision_v2(
  uuid, boolean, text, uuid
) to authenticated;

create or replace function app.reserve_order_lines_v2(
  p_receipt_line_id uuid,
  p_order_line_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_id uuid;
begin
  if actor is null
    or app.staff_role() not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  for target_id in
    select distinct orders.member_id
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    where line.id = any(p_order_line_ids)
    order by orders.member_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('dynamic-import-member:' || target_id::text, 0)
    );
  end loop;
  for target_id in
    select distinct orders.member_season_id
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    where line.id = any(p_order_line_ids)
    order by orders.member_season_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'dynamic-import-member-season:' || target_id::text,
        0
      )
    );
  end loop;
  return app.reserve_order_lines(p_receipt_line_id, p_order_line_ids);
end;
$$;

revoke execute on function app.reserve_order_lines(uuid, uuid[])
from authenticated;
revoke all on function app.reserve_order_lines_v2(uuid, uuid[])
from public, anon;
grant execute on function app.reserve_order_lines_v2(uuid, uuid[])
to authenticated;

create or replace function app.commit_fulfilment_v2(
  p_order_id uuid,
  p_order_line_ids uuid[],
  p_location text,
  p_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_member_id uuid;
  target_member_season_id uuid;
begin
  if actor is null or not app.is_staff_member() then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  select orders.member_id, orders.member_season_id
  into target_member_id, target_member_season_id
  from app.member_orders orders
  where orders.id = p_order_id;
  if target_member_id is null then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member-season:' || target_member_season_id::text,
      0
    )
  );
  return app.commit_fulfilment(
    p_order_id,
    p_order_line_ids,
    p_location,
    p_token_hash
  );
end;
$$;

revoke execute on function app.commit_fulfilment(
  uuid, uuid[], text, text
) from authenticated;
revoke all on function app.commit_fulfilment_v2(
  uuid, uuid[], text, text
) from public, anon;
grant execute on function app.commit_fulfilment_v2(
  uuid, uuid[], text, text
) to authenticated;

create or replace function app.correct_fulfilment_v2(
  p_order_line_ids uuid[],
  p_target_status app.order_line_status,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_id uuid;
begin
  if actor is null
    or app.staff_role() not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  for target_id in
    select distinct orders.member_id
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    where line.id = any(p_order_line_ids)
    order by orders.member_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('dynamic-import-member:' || target_id::text, 0)
    );
  end loop;
  for target_id in
    select distinct orders.member_season_id
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    where line.id = any(p_order_line_ids)
    order by orders.member_season_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'dynamic-import-member-season:' || target_id::text,
        0
      )
    );
  end loop;
  return app.correct_fulfilment(
    p_order_line_ids,
    p_target_status,
    p_reason
  );
end;
$$;

revoke execute on function app.correct_fulfilment(
  uuid[], app.order_line_status, text
) from authenticated;
revoke all on function app.correct_fulfilment_v2(
  uuid[], app.order_line_status, text
) from public, anon;
grant execute on function app.correct_fulfilment_v2(
  uuid[], app.order_line_status, text
) to authenticated;

create or replace function app.block_pending_package_size_issuance()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_id uuid;
  target_member_season_id uuid;
begin
  if new.status <> 'picked_up'
    or (tg_op = 'UPDATE' and old.status = 'picked_up')
  then
    return new;
  end if;
  select orders.member_id, orders.member_season_id
  into target_member_id, target_member_season_id
  from app.member_orders orders
  where orders.id = new.order_id;
  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  if exists(
    select 1
    from app.member_article_sizes size_profile
    where size_profile.member_season_id = target_member_season_id
      and size_profile.article_id = new.article_id
      and size_profile.selection_status = 'change_requested'
  ) then
    raise exception 'PACKAGE_SIZE_CHANGE_PENDING'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger order_lines_block_pending_size_change
after insert or update of status on app.order_lines
for each row execute function app.block_pending_package_size_issuance();

revoke all on function app.block_pending_package_size_issuance()
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
