-- Audited package switch workflow after payment or inventory allocation.
-- Financial history remains bound to its original immutable package snapshot;
-- this workflow never creates a refund or transfers a payment.

create table app.package_change_requests (
  id uuid primary key,
  order_id uuid not null
    references app.member_orders(id) on delete restrict,
  member_season_id uuid not null
    references app.member_seasons(id) on delete restrict,
  season_id uuid not null
    references app.seasons(id) on delete restrict,
  from_snapshot_id uuid not null,
  from_package_revision_id uuid,
  from_package_name text not null,
  from_price_cents integer not null check (from_price_cents >= 0),
  from_currency text not null check (from_currency ~ '^[A-Z]{3}$'),
  to_package_revision_id uuid not null
    references app.package_template_revisions(id) on delete restrict,
  to_package_name text not null,
  to_price_cents integer not null check (to_price_cents >= 0),
  to_currency text not null check (to_currency ~ '^[A-Z]{3}$'),
  price_delta_cents integer not null,
  state_snapshot jsonb not null check (
    jsonb_typeof(state_snapshot) = 'object'
    and not state_snapshot ?| array[
      'email', 'recipient', 'name', 'memberName', 'dateOfBirth',
      'token', 'tokenHash', 'qrToken', 'checkoutUrl'
    ]
  ),
  state_revision text not null check (state_revision ~ '^[0-9a-f]{64}$'),
  reason text not null check (
    reason = btrim(reason) and length(reason) between 4 and 480
  ),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (
    status in ('blocked', 'ready', 'applied', 'superseded', 'dismissed')
  ),
  requested_by uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  correlation_id uuid,
  requested_at timestamptz not null default timezone('utc', now()),
  applied_at timestamptz,
  applied_by uuid references app.staff_profiles(auth_user_id) on delete restrict,
  result_snapshot jsonb,
  constraint package_change_from_snapshot_order_fkey
    foreign key(from_snapshot_id, order_id)
    references app.order_package_snapshots(id, order_id)
    on delete restrict,
  constraint package_change_lifecycle_check check (
    (
      status in ('blocked', 'ready', 'superseded', 'dismissed')
      and applied_at is null
      and applied_by is null
      and result_snapshot is null
    )
    or (
      status = 'applied'
      and applied_at is not null
      and applied_by is not null
      and jsonb_typeof(result_snapshot) = 'object'
    )
  )
);

create index package_change_requests_queue_idx
  on app.package_change_requests(season_id, status, requested_at desc);
create index package_change_requests_order_idx
  on app.package_change_requests(order_id, requested_at desc);

alter table app.package_change_requests enable row level security;
revoke all on table app.package_change_requests
from public, anon, authenticated, service_role;

create or replace function private.protect_package_change_request()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  if current_setting('app.package_change_request_internal', true)
    is distinct from 'on'
  then
    raise exception 'PACKAGE_CHANGE_REQUEST_IMMUTABLE'
      using errcode = '23514';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger package_change_requests_protect
before update or delete on app.package_change_requests
for each row execute function private.protect_package_change_request();

revoke all on function private.protect_package_change_request()
from public, anon, authenticated, service_role;

create or replace function private.package_change_state(
  p_order_id uuid,
  p_target_revision_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'orderId', orders.id,
    'memberSeasonId', orders.member_season_id,
    'seasonId', orders.season_id,
    'fromSnapshotId', current_snapshot.id,
    'fromPackageRevisionId', orders.package_revision_id,
    'fromPackageName', current_snapshot.package_name,
    'fromPriceCents', current_snapshot.package_price_cents,
    'fromCurrency', current_snapshot.currency,
    'toPackageRevisionId', target.id,
    'toPackageName', target.name,
    'toPriceCents', target.price_cents,
    'toCurrency', target.currency,
    'priceDeltaCents',
      target.price_cents - current_snapshot.package_price_cents,
    'paymentStatus', private.order_effective_payment_status(orders.id),
    'unresolvedPaymentCount', (
      select count(*)::integer
      from app.payments payment
      where payment.order_id = orders.id
        and payment.status in ('open', 'pending', 'paid', 'duplicate_paid')
    ),
    'paidHistoryCount', (
      select count(*)::integer
      from app.payments payment
      where payment.order_id = orders.id
        and payment.status in ('paid', 'refunded', 'duplicate_paid')
    ),
    'refundedPaymentCount', (
      select count(*)::integer
      from app.payments payment
      where payment.order_id = orders.id
        and payment.status = 'refunded'
    ),
    'reservedAllocationCount', (
      select count(*)::integer
      from app.inventory_allocations allocation
      where allocation.order_id = orders.id
        and allocation.status = 'reserved'
    ),
    'fulfilledAllocationCount', (
      select count(*)::integer
      from app.inventory_allocations allocation
      where allocation.order_id = orders.id
        and allocation.status = 'fulfilled'
    ),
    'unreconciledLegacyReservationCount', (
      select count(*)::integer
      from app.inventory_reservations reservation
      join app.order_lines line on line.id = reservation.order_line_id
      where line.order_id = orders.id
        and reservation.status in ('reserved', 'fulfilled')
        and not exists(
          select 1
          from app.inventory_allocations allocation
          where allocation.legacy_reservation_id = reservation.id
        )
    ),
    'unreversedFulfilmentCount', (
      select count(*)::integer
      from app.fulfilment_lines fulfilment_line
      join app.fulfilments fulfilment
        on fulfilment.id = fulfilment_line.fulfilment_id
      where fulfilment.order_id = orders.id
        and fulfilment.reversed_at is null
        and fulfilment_line.reversed_at is null
    )
  )
  into result
  from app.member_orders orders
  join app.order_package_snapshots current_snapshot
    on current_snapshot.id = orders.active_package_snapshot_id
  join app.package_template_revisions target
    on target.id = p_target_revision_id
    and target.season_id = orders.season_id
    and target.status = 'published'
    and target.active
  where orders.id = p_order_id;
  if result is null then
    raise exception 'PACKAGE_CHANGE_TARGET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if result->>'fromPackageRevisionId'
    = result->>'toPackageRevisionId'
  then
    raise exception 'PACKAGE_CHANGE_TARGET_UNCHANGED' using errcode = '22023';
  end if;
  return result || jsonb_build_object(
    'requiresPaymentResolution',
      (result->>'unresolvedPaymentCount')::integer > 0,
    'requiresExternalRefund',
      (result->>'unresolvedPaymentCount')::integer > 0
      and (result->>'paymentStatus') in ('paid', 'duplicate_paid'),
    'requiresAllocationRelease',
      (result->>'reservedAllocationCount')::integer > 0,
    'blockedByFulfilment',
      (result->>'fulfilledAllocationCount')::integer > 0
      or (result->>'unreversedFulfilmentCount')::integer > 0,
    'blockedByReconciliation',
      (result->>'unreconciledLegacyReservationCount')::integer > 0,
    'canApply',
      (result->>'unresolvedPaymentCount')::integer = 0
      and (result->>'fulfilledAllocationCount')::integer = 0
      and (result->>'unreversedFulfilmentCount')::integer = 0
      and (result->>'unreconciledLegacyReservationCount')::integer = 0
  );
end;
$$;

revoke all on function private.package_change_state(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.package_change_response(
  p_request app.package_change_requests,
  p_reused boolean
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'requestId', p_request.id,
    'orderId', p_request.order_id,
    'memberSeasonId', p_request.member_season_id,
    'fromSnapshotId', p_request.from_snapshot_id,
    'fromPackageRevisionId', p_request.from_package_revision_id,
    'fromPackageName', p_request.from_package_name,
    'fromPriceCents', p_request.from_price_cents,
    'fromCurrency', p_request.from_currency,
    'toPackageRevisionId', p_request.to_package_revision_id,
    'toPackageName', p_request.to_package_name,
    'toPriceCents', p_request.to_price_cents,
    'toCurrency', p_request.to_currency,
    'priceDeltaCents', p_request.price_delta_cents,
    'paymentStatus', p_request.state_snapshot->>'paymentStatus',
    'unresolvedPaymentCount',
      (p_request.state_snapshot->>'unresolvedPaymentCount')::integer,
    'paidHistoryCount',
      (p_request.state_snapshot->>'paidHistoryCount')::integer,
    'refundedPaymentCount',
      (p_request.state_snapshot->>'refundedPaymentCount')::integer,
    'reservedAllocationCount',
      (p_request.state_snapshot->>'reservedAllocationCount')::integer,
    'fulfilledAllocationCount',
      (p_request.state_snapshot->>'fulfilledAllocationCount')::integer,
    'requiresPaymentResolution',
      (p_request.state_snapshot->>'requiresPaymentResolution')::boolean,
    'requiresExternalRefund',
      (p_request.state_snapshot->>'requiresExternalRefund')::boolean,
    'requiresAllocationRelease',
      (p_request.state_snapshot->>'requiresAllocationRelease')::boolean,
    'blockedByFulfilment',
      (p_request.state_snapshot->>'blockedByFulfilment')::boolean,
    'blockedByReconciliation',
      (p_request.state_snapshot->>'blockedByReconciliation')::boolean,
    'canApply', (p_request.state_snapshot->>'canApply')::boolean,
    'status', p_request.status,
    'revision', p_request.state_revision,
    'reused', p_reused,
    'result', p_request.result_snapshot
  );
$$;

revoke all on function private.package_change_response(
  app.package_change_requests, boolean
) from public, anon, authenticated, service_role;

create or replace function app.preflight_package_change_v1(
  p_order_id uuid,
  p_target_revision_id uuid,
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
  actor uuid := private.require_admin_aal2();
  normalized_reason text := regexp_replace(
    btrim(coalesce(p_reason, '')), '[[:space:]]+', ' ', 'g'
  );
  current_state jsonb;
  current_revision text;
  computed_hash text;
  existing app.package_change_requests%rowtype;
  inserted app.package_change_requests%rowtype;
  action_key text;
begin
  if p_order_id is null
    or p_target_revision_id is null
    or p_request_id is null
    or length(normalized_reason) not between 4 and 480
  then
    raise exception 'PACKAGE_CHANGE_INPUT_INVALID' using errcode = '22023';
  end if;
  computed_hash := encode(extensions.digest(
    jsonb_build_object(
      'orderId', p_order_id,
      'targetRevisionId', p_target_revision_id,
      'reason', normalized_reason
    )::text,
    'sha256'
  ), 'hex');
  perform pg_advisory_xact_lock(
    hashtextextended('package-change-request:' || p_request_id::text, 0)
  );
  select * into existing
  from app.package_change_requests request
  where request.id = p_request_id
  for update;
  if found then
    if existing.requested_by <> actor
      or existing.request_hash <> computed_hash
    then
      raise exception 'PACKAGE_CHANGE_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    return private.package_change_response(existing, true);
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('package-change-order:' || p_order_id::text, 0)
  );
  perform 1 from app.member_orders where id = p_order_id for update;
  if not found then
    raise exception 'PACKAGE_CHANGE_ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;
  current_state := private.package_change_state(
    p_order_id, p_target_revision_id
  );
  current_revision := encode(
    extensions.digest(current_state::text, 'sha256'),
    'hex'
  );

  perform set_config('app.package_change_request_internal', 'on', true);
  update app.package_change_requests request
  set status = 'superseded'
  where request.order_id = p_order_id
    and request.status in ('ready', 'blocked');
  perform set_config('app.package_change_request_internal', 'off', true);

  insert into app.package_change_requests(
    id,
    order_id,
    member_season_id,
    season_id,
    from_snapshot_id,
    from_package_revision_id,
    from_package_name,
    from_price_cents,
    from_currency,
    to_package_revision_id,
    to_package_name,
    to_price_cents,
    to_currency,
    price_delta_cents,
    state_snapshot,
    state_revision,
    reason,
    request_hash,
    status,
    requested_by,
    correlation_id
  ) values (
    p_request_id,
    p_order_id,
    (current_state->>'memberSeasonId')::uuid,
    (current_state->>'seasonId')::uuid,
    (current_state->>'fromSnapshotId')::uuid,
    nullif(current_state->>'fromPackageRevisionId', '')::uuid,
    current_state->>'fromPackageName',
    (current_state->>'fromPriceCents')::integer,
    current_state->>'fromCurrency',
    (current_state->>'toPackageRevisionId')::uuid,
    current_state->>'toPackageName',
    (current_state->>'toPriceCents')::integer,
    current_state->>'toCurrency',
    (current_state->>'priceDeltaCents')::integer,
    current_state,
    current_revision,
    normalized_reason,
    computed_hash,
    case when (current_state->>'canApply')::boolean
      then 'ready' else 'blocked' end,
    actor,
    p_correlation_id
  )
  returning * into inserted;

  action_key := encode(extensions.digest(
    concat_ws(':', 'package-change-v1', p_order_id::text),
    'sha256'
  ), 'hex');
  perform private.open_action_item(
    'package_change_after_payment',
    inserted.season_id,
    'member_order',
    inserted.order_id,
    'package_change_request',
    inserted.id,
    action_key,
    case when (current_state->>'blockedByFulfilment')::boolean
      then 'critical'::app.action_item_severity
      else 'warning'::app.action_item_severity end,
    'admin_only'::app.action_item_visibility,
    case
      when (current_state->>'blockedByFulfilment')::boolean
        then 'package_change.fulfilment_block'
      when (current_state->>'requiresPaymentResolution')::boolean
        then 'package_change.payment_resolution_required'
      when (current_state->>'requiresAllocationRelease')::boolean
        then 'package_change.allocation_release_required'
      else 'package_change.ready'
    end,
    jsonb_build_object(
      'packageOrderId', inserted.order_id,
      'count',
        (current_state->>'reservedAllocationCount')::integer
        + (current_state->>'fulfilledAllocationCount')::integer,
      'blocked', not (current_state->>'canApply')::boolean,
      'eligible', (current_state->>'canApply')::boolean
    ),
    null
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
    'package_change.preflighted',
    'package_change_request',
    inserted.id,
    jsonb_build_object(
      'orderId', inserted.order_id,
      'fromSnapshotId', inserted.from_snapshot_id,
      'toPackageRevisionId', inserted.to_package_revision_id,
      'priceDeltaCents', inserted.price_delta_cents,
      'status', inserted.status,
      'reason', normalized_reason
    ),
    p_correlation_id
  );
  return private.package_change_response(inserted, false);
end;
$$;

revoke all on function app.preflight_package_change_v1(
  uuid, uuid, text, uuid, uuid
) from public, anon, service_role;
grant execute on function app.preflight_package_change_v1(
  uuid, uuid, text, uuid, uuid
) to authenticated;

create or replace function app.prepare_order_package_snapshot()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  snapshot_id uuid;
begin
  if tg_op = 'INSERT' then
    snapshot_id := private.create_order_package_snapshot(
      new.id,
      new.member_season_id,
      new.season_id,
      new.amount_due_cents,
      new.package_revision_id,
      case when new.package_revision_id is null
        then 'Compatibilitysnapshot bij legacy orderaanmaak'
        else 'Pakketsnapshot bij orderaanmaak'
      end
    );
    new.active_package_snapshot_id := snapshot_id;
    return new;
  end if;

  if new.package_revision_id is distinct from old.package_revision_id
    or new.amount_due_cents is distinct from old.amount_due_cents
  then
    if current_setting('app.package_change_internal', true)
      is distinct from 'on'
      and (
        exists (
          select 1 from app.payments
          where order_id = old.id
            and status in ('paid', 'refunded', 'duplicate_paid')
        )
        or exists (
          select 1 from app.inventory_reservations reservation
          join app.order_lines line on line.id = reservation.order_line_id
          where line.order_id = old.id
            and reservation.status in ('reserved', 'fulfilled')
        )
      )
    then
      raise exception 'PACKAGE_ORDER_CHANGE_REQUIRES_ADMIN_WORKFLOW'
        using errcode = '23514';
    end if;

    snapshot_id := private.create_order_package_snapshot(
      new.id,
      new.member_season_id,
      new.season_id,
      new.amount_due_cents,
      new.package_revision_id,
      case
        when current_setting('app.package_change_internal', true) = 'on'
          then 'Nieuwe commerciële snapshot via geaudite pakketwijziging'
        else 'Nieuwe commerciële snapshot na wijziging vóór betaling/reservering'
      end
    );

    if new.package_revision_id is null then
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
      select snapshot_id, line.id, line.article_id,
        line.article_variant_id, line.quantity,
        line.product_name_snapshot, line.product_code_snapshot,
        line.size_snapshot, line.size_snapshot, article.sort_order
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = new.id and line.status <> 'cancelled';
    end if;
    new.active_package_snapshot_id := snapshot_id;
  elsif new.active_package_snapshot_id is distinct from old.active_package_snapshot_id
    and current_setting('app.package_snapshot_internal', true)
      is distinct from 'on'
  then
    raise exception 'ACTIVE_PACKAGE_SNAPSHOT_IMMUTABLE'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.prepare_order_package_snapshot()
from public, anon, authenticated, service_role;

create or replace function app.apply_package_change_v1(
  p_request_id uuid,
  p_expected_revision text,
  p_confirmation text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target app.package_change_requests%rowtype;
  current_state jsonb;
  current_revision text;
  released_count integer := 0;
  next_snapshot uuid;
  result jsonb;
  action_key text;
begin
  if p_request_id is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_confirmation is null
    or p_confirmation not in (
      'SWITCH_PACKAGE',
      'RELEASE_ALLOCATIONS_AND_SWITCH'
    )
  then
    raise exception 'PACKAGE_CHANGE_APPLY_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('package-change-order-request:' || p_request_id::text, 0)
  );
  select * into target
  from app.package_change_requests request
  where request.id = p_request_id
  for update;
  if not found then
    raise exception 'PACKAGE_CHANGE_REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.status = 'applied' then
    if target.state_revision <> p_expected_revision then
      raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001';
    end if;
    return private.package_change_response(target, true);
  end if;
  if target.status not in ('ready', 'blocked')
    or target.state_revision <> p_expected_revision
  then
    raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('package-change-order:' || target.order_id::text, 0)
  );
  perform 1 from app.member_orders
  where id = target.order_id for update;
  perform 1
  from app.package_template_revisions revision
  where revision.id = target.to_package_revision_id
    and revision.season_id = target.season_id
    and revision.status = 'published'
    and revision.active
  for update;
  if not found then
    raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001';
  end if;
  current_state := private.package_change_state(
    target.order_id, target.to_package_revision_id
  );
  current_revision := encode(
    extensions.digest(current_state::text, 'sha256'),
    'hex'
  );
  if current_revision <> target.state_revision then
    raise exception 'PACKAGE_CHANGE_STALE' using errcode = '40001';
  end if;
  if not (current_state->>'canApply')::boolean then
    raise exception 'PACKAGE_CHANGE_BLOCKED' using errcode = '23514';
  end if;
  if (current_state->>'requiresAllocationRelease')::boolean
    <> (p_confirmation = 'RELEASE_ALLOCATIONS_AND_SWITCH')
  then
    raise exception 'PACKAGE_CHANGE_CONFIRMATION_REQUIRED'
      using errcode = '22023';
  end if;

  if (current_state->>'requiresAllocationRelease')::boolean then
    released_count := private.release_order_inventory_allocations(
      target.order_id,
      'Pakketwijziging: ' || target.reason,
      actor,
      'package_change_request',
      target.id,
      p_correlation_id
    );
  end if;

  perform set_config('app.package_change_internal', 'on', true);
  update app.member_orders
  set package_revision_id = target.to_package_revision_id,
      amount_due_cents = target.to_price_cents
  where id = target.order_id
  returning active_package_snapshot_id into next_snapshot;
  perform set_config('app.package_change_internal', 'off', true);

  update app.order_lines
  set status = 'cancelled',
      updated_at = timezone('utc', now())
  where order_id = target.order_id
    and status = 'backorder';
  perform app.refresh_order_status(target.order_id);

  result := jsonb_build_object(
    'requestId', target.id,
    'orderId', target.order_id,
    'memberSeasonId', target.member_season_id,
    'fromSnapshotId', target.from_snapshot_id,
    'toSnapshotId', next_snapshot,
    'toPackageRevisionId', target.to_package_revision_id,
    'priceDeltaCents', target.price_delta_cents,
    'releasedAllocationCount', released_count,
    'paymentTransferred', false,
    'refundCreated', false,
    'status', 'applied'
  );
  perform set_config('app.package_change_request_internal', 'on', true);
  update app.package_change_requests
  set status = 'applied',
      applied_at = timezone('utc', now()),
      applied_by = actor,
      result_snapshot = result
  where id = target.id
  returning * into target;
  perform set_config('app.package_change_request_internal', 'off', true);

  action_key := encode(extensions.digest(
    concat_ws(':', 'package-change-v1', target.order_id::text),
    'sha256'
  ), 'hex');
  perform private.auto_resolve_action_item(
    'package_change_after_payment',
    target.season_id,
    action_key,
    'Pakketwijziging gecontroleerd uitgevoerd'
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
    'package_change.applied',
    'package_change_request',
    target.id,
    jsonb_build_object(
      'orderId', target.order_id,
      'fromSnapshotId', target.from_snapshot_id,
      'toSnapshotId', next_snapshot,
      'toPackageRevisionId', target.to_package_revision_id,
      'priceDeltaCents', target.price_delta_cents,
      'releasedAllocationCount', released_count,
      'paymentTransferred', false,
      'refundCreated', false,
      'reason', target.reason
    ),
    p_correlation_id
  );
  return private.package_change_response(target, false);
end;
$$;

revoke all on function app.apply_package_change_v1(
  uuid, text, text, uuid
) from public, anon, service_role;
grant execute on function app.apply_package_change_v1(
  uuid, text, text, uuid
) to authenticated;

notify pgrst, 'reload schema';
