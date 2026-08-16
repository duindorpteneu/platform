-- Keep the exact parent runtime contract visible through PostgREST and add a
-- narrowly scoped, immutable correction path for loose extras on package orders.

revoke all on function public.get_parent_package_workspace_v6(text)
from public, anon, authenticated;
grant execute on function public.get_parent_package_workspace_v6(text)
to service_role;

create table private.loose_order_line_removal_requests (
  request_id uuid primary key,
  staff_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete restrict,
  order_id uuid not null
    references app.member_orders(id) on delete restrict,
  order_line_id uuid not null
    references app.order_lines(id) on delete restrict,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  reason text not null check (
    reason = btrim(reason)
    and length(reason) between 3 and 500
  ),
  result_snapshot jsonb not null check (
    jsonb_typeof(result_snapshot) = 'object'
    and not result_snapshot ?| array[
      'email', 'recipient', 'name', 'member_name', 'date_of_birth',
      'token', 'token_hash', 'qr_token', 'qr_hash', 'checkout_url'
    ]
  ),
  correlation_id uuid,
  created_at timestamptz not null default timezone('utc', now())
);

alter table private.loose_order_line_removal_requests enable row level security;
revoke all on table private.loose_order_line_removal_requests
from public, anon, authenticated, service_role;

create or replace function private.protect_loose_order_line_removal_request()
returns trigger
language plpgsql
set search_path = private, pg_temp
as $$
begin
  raise exception 'LOOSE_ORDER_LINE_REMOVAL_REQUEST_IMMUTABLE'
    using errcode = '23514';
end;
$$;

create trigger loose_order_line_removal_requests_immutable
before update or delete on private.loose_order_line_removal_requests
for each row execute function private.protect_loose_order_line_removal_request();

create or replace function app.remove_loose_order_line_v1(
  p_order_line_id uuid,
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
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  computed_hash text;
  existing private.loose_order_line_removal_requests%rowtype;
  target_line app.order_lines%rowtype;
  target_order app.member_orders%rowtype;
  result jsonb;
begin
  if p_order_line_id is null
    or p_request_id is null
    or length(normalized_reason) not between 3 and 500
  then
    raise exception 'LOOSE_ORDER_LINE_REMOVAL_INVALID'
      using errcode = '22023';
  end if;

  computed_hash := encode(extensions.digest(jsonb_build_object(
    'orderLineId', p_order_line_id,
    'reason', normalized_reason
  )::text, 'sha256'), 'hex');

  perform pg_advisory_xact_lock(
    hashtextextended(
      'loose-order-line-removal-request:' || p_request_id::text,
      0
    )
  );
  select * into existing
  from private.loose_order_line_removal_requests request
  where request.request_id = p_request_id
  for update;
  if found then
    if existing.staff_user_id <> actor
      or existing.request_hash <> computed_hash
    then
      raise exception 'LOOSE_ORDER_LINE_REMOVAL_IDEMPOTENCY_CONFLICT'
        using errcode = '23505';
    end if;
    return existing.result_snapshot || jsonb_build_object('reused', true);
  end if;

  perform private.lock_inventory_mutation();

  select line.* into target_line
  from app.order_lines line
  where line.id = p_order_line_id;
  if not found then
    raise exception 'LOOSE_ORDER_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;

  select orders.* into target_order
  from app.member_orders orders
  where orders.id = target_line.order_id
  for update;
  if not found then
    raise exception 'LOOSE_ORDER_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;

  select line.* into target_line
  from app.order_lines line
  where line.id = p_order_line_id
  for update;

  if target_order.package_revision_id is null
    or target_order.package_assignment_state <> 'active'
    or target_line.package_template_item_id is not null
  then
    raise exception 'LOOSE_ORDER_LINE_NOT_REMOVABLE'
      using errcode = '23514';
  end if;
  if target_line.status <> 'backorder' then
    raise exception 'LOOSE_ORDER_LINE_LOGISTICS_BLOCKED'
      using errcode = '23514';
  end if;
  if exists(
    select 1 from app.inventory_reservations reservation
    where reservation.order_line_id = target_line.id
      and reservation.status in ('reserved', 'fulfilled')
  ) or exists(
    select 1 from app.inventory_allocations allocation
    where allocation.order_line_id = target_line.id
      and allocation.status in ('reserved', 'fulfilled')
  ) or exists(
    select 1 from app.fulfilment_lines fulfilment_line
    where fulfilment_line.order_line_id = target_line.id
      and fulfilment_line.reversed_at is null
  ) or exists(
    select 1 from app.package_size_change_requests size_request
    where size_request.order_line_id = target_line.id
      and size_request.status = 'requested'
  ) then
    raise exception 'LOOSE_ORDER_LINE_LOGISTICS_BLOCKED'
      using errcode = '23514';
  end if;

  update app.order_lines
  set status = 'cancelled',
      updated_at = timezone('utc', now())
  where id = target_line.id;
  perform app.refresh_order_status(target_order.id);

  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata, correlation_id
  ) values (
    actor,
    'order.loose_line.cancelled',
    'order_line',
    target_line.id,
    jsonb_build_object(
      'orderId', target_order.id,
      'memberSeasonId', target_order.member_season_id,
      'articleId', target_line.article_id,
      'previousStatus', target_line.status::text,
      'reason', normalized_reason
    ),
    p_correlation_id
  );

  result := jsonb_build_object(
    'requestId', p_request_id,
    'orderId', target_order.id,
    'orderLineId', target_line.id,
    'status', 'cancelled',
    'reused', false
  );
  insert into private.loose_order_line_removal_requests(
    request_id, staff_user_id, order_id, order_line_id,
    request_hash, reason, result_snapshot, correlation_id
  ) values (
    p_request_id, actor, target_order.id, target_line.id,
    computed_hash, normalized_reason, result, p_correlation_id
  );
  return result;
end;
$$;

create or replace function app.get_member_detail_v5(p_member_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with detail as (
    select app.get_member_detail_v4(p_member_id) result
  ), enriched as (
    select case
      when detail.result->'order' is null
        or jsonb_typeof(detail.result->'order') = 'null'
      then detail.result
      else jsonb_set(
        detail.result,
        '{order,lines}',
        coalesce((
          select jsonb_agg(
            line.value || jsonb_build_object(
              'lineKind', case
                when stored.package_template_item_id is null then 'loose'
                else 'package'
              end,
              'canRemove', app.staff_role() = 'beheerder'
                and orders.package_revision_id is not null
                and orders.package_assignment_state = 'active'
                and stored.package_template_item_id is null
                and stored.status = 'backorder'
                and not exists(
                  select 1 from app.inventory_reservations reservation
                  where reservation.order_line_id = stored.id
                    and reservation.status in ('reserved', 'fulfilled')
                )
                and not exists(
                  select 1 from app.inventory_allocations allocation
                  where allocation.order_line_id = stored.id
                    and allocation.status in ('reserved', 'fulfilled')
                )
                and not exists(
                  select 1 from app.fulfilment_lines fulfilment_line
                  where fulfilment_line.order_line_id = stored.id
                    and fulfilment_line.reversed_at is null
                )
                and not exists(
                  select 1 from app.package_size_change_requests size_request
                  where size_request.order_line_id = stored.id
                    and size_request.status = 'requested'
                )
            ) order by line.ordinality
          )
          from jsonb_array_elements(detail.result #> '{order,lines}')
            with ordinality line(value, ordinality)
          join app.order_lines stored
            on stored.id = (line.value->>'id')::uuid
          join app.member_orders orders on orders.id = stored.order_id
        ), '[]'::jsonb),
        false
      )
    end result
    from detail
  )
  select result from enriched;
$$;

revoke all on function private.protect_loose_order_line_removal_request()
from public, anon, authenticated, service_role;
revoke all on function app.remove_loose_order_line_v1(uuid, text, uuid, uuid)
from public, anon, service_role;
revoke all on function app.get_member_detail_v5(uuid)
from public, anon, service_role;
grant execute on function app.remove_loose_order_line_v1(uuid, text, uuid, uuid)
to authenticated;
grant execute on function app.get_member_detail_v5(uuid)
to authenticated;

notify pgrst, 'reload schema';
