-- Inventory shortage episodes belong to the article variant, regardless of the
-- operation that happened to refresh the projection. Keep the caller source on
-- the immutable inventory/allocation records, but use a stable action-item
-- identity so payment, delivery and acceptance flows can refresh one episode.

alter table app.action_items
  add constraint action_items_active_inventory_source_check
  check (
    type not in ('low_stock', 'out_of_stock')
    or object_type <> 'article_variant'
    or status not in ('open', 'in_progress')
    or (
      source_type = 'article_variant'
      and source_id is not distinct from object_id
    )
  ) not valid;

create or replace function private.refresh_inventory_variant_actions(
  p_season_id uuid,
  p_variant_id uuid,
  p_source_type text default 'inventory_movement',
  p_source_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  current_on_hand bigint;
  current_available bigint;
  threshold integer;
  open_demand bigint;
  shortage bigint;
  waiter_count integer;
  low_key text;
  out_key text;
begin
  select balance.on_hand, balance.available
  into current_on_hand, current_available
  from private.inventory_balance(p_season_id, p_variant_id) balance;
  select settings.low_stock_threshold into threshold
  from app.inventory_settings settings
  where settings.season_id = p_season_id;
  threshold := coalesce(threshold, 10);

  select
    coalesce(sum(line.quantity), 0),
    count(*) filter (where line.status = 'backorder')
  into open_demand, waiter_count
  from app.order_lines line
  join app.member_orders orders on orders.id = line.order_id
  where orders.season_id = p_season_id
    and line.article_variant_id = p_variant_id
    and line.status in ('backorder', 'ready_for_pickup');

  shortage := greatest(open_demand - current_on_hand, 0);
  low_key := private.inventory_action_key(
    'inventory-low-stock-v1',
    p_season_id,
    p_variant_id
  );
  out_key := private.inventory_action_key(
    'inventory-out-of-stock-v1',
    p_season_id,
    p_variant_id
  );

  if current_available = 0 then
    perform private.open_action_item(
      'out_of_stock',
      p_season_id,
      'article_variant',
      p_variant_id,
      'article_variant',
      p_variant_id,
      out_key,
      (
        case when waiter_count > 0 then 'critical' else 'warning' end
      )::app.action_item_severity,
      'operations'::app.action_item_visibility,
      'inventory.zero_available',
      jsonb_build_object(
        'variantId', p_variant_id,
        'available', 0,
        'shortage', shortage,
        'waiterCount', waiter_count
      ),
      null
    );
    perform private.auto_resolve_action_item(
      'low_stock',
      p_season_id,
      low_key,
      'system: voorraadstatus is gewijzigd naar nul'
    );
  elsif current_available <= threshold then
    perform private.open_action_item(
      'low_stock',
      p_season_id,
      'article_variant',
      p_variant_id,
      'article_variant',
      p_variant_id,
      low_key,
      'warning'::app.action_item_severity,
      'operations'::app.action_item_visibility,
      'inventory.below_threshold',
      jsonb_build_object(
        'variantId', p_variant_id,
        'available', current_available,
        'shortage', shortage,
        'waiterCount', waiter_count
      ),
      null
    );
    perform private.auto_resolve_action_item(
      'out_of_stock',
      p_season_id,
      out_key,
      'system: er is weer vrije voorraad'
    );
  else
    perform private.auto_resolve_action_item(
      'low_stock',
      p_season_id,
      low_key,
      'system: voorraad is boven de ingestelde drempel'
    );
    perform private.auto_resolve_action_item(
      'out_of_stock',
      p_season_id,
      out_key,
      'system: er is weer vrije voorraad'
    );
  end if;
end;
$$;

revoke all on function private.refresh_inventory_variant_actions(
  uuid, uuid, text, uuid
) from public, anon, authenticated, service_role;

do $$
declare
  normalized_active_items bigint;
begin
  update app.action_items
  set source_type = 'article_variant',
      source_id = object_id
  where type in ('low_stock', 'out_of_stock')
    and object_type = 'article_variant'
    and status in ('open', 'in_progress')
    and (
      source_type <> 'article_variant'
      or source_id is distinct from object_id
    );
  get diagnostics normalized_active_items = row_count;

  if exists (
    select 1
    from app.action_items item
    where item.type in ('low_stock', 'out_of_stock')
      and item.object_type = 'article_variant'
      and item.status in ('open', 'in_progress')
      and (
        item.source_type <> 'article_variant'
        or item.source_id is distinct from item.object_id
      )
  ) then
    raise exception 'INVENTORY_ACTION_SOURCE_RECONCILIATION_FAILED'
      using errcode = '23514';
  end if;

  insert into private.migration_reconciliations(
    migration_key,
    status,
    metrics
  ) values (
    '20260814120000_inventory_action_source_stability',
    'passed',
    jsonb_build_object(
      'strategy', 'bind active shortage episodes to their article variant',
      'normalized_active_items', normalized_active_items
    )
  );
end;
$$;

alter table app.action_items
  validate constraint action_items_active_inventory_source_check;
