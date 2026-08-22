-- Avoid rebuilding the complete adjustment/refund balance for the common
-- pre-payment path. Orders with any payment history, any financial adjustment,
-- or a zero-valued active package still use the canonical balance unchanged.
create or replace function private.order_has_effective_paid_payment(
  p_order_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  definitely_unpaid boolean;
  effective_paid boolean;
begin
  select
    coalesce(snapshot.package_price_cents, orders.amount_due_cents) > 0
    and not exists(
      select 1
      from app.payments payment
      where payment.order_id = orders.id
    )
    and not exists(
      select 1
      from app.package_financial_adjustments adjustment
      where adjustment.order_id = orders.id
    )
  into definitely_unpaid
  from app.member_orders orders
  left join app.order_package_snapshots snapshot
    on snapshot.id = orders.active_package_snapshot_id
    and snapshot.order_id = orders.id
  where orders.id = p_order_id;

  if definitely_unpaid then
    return false;
  end if;

  select balance.effective_status = 'paid'
  into effective_paid
  from private.order_financial_balance(p_order_id) balance;

  return effective_paid;
end;
$$;

revoke all on function private.order_has_effective_paid_payment(uuid)
from public, anon, authenticated, service_role;

-- Evaluate the ordered eligibility set once. Re-running a LIMIT 1 candidate
-- query after every reservation made the effective-payment predicate
-- quadratic in the number of waiting lines.
create or replace function private.allocate_inventory_fifo_variant(
  p_season_id uuid,
  p_variant_id uuid,
  p_source_type text default 'allocator',
  p_source_id uuid default null,
  p_actor uuid default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  candidate record;
  allocation_id uuid;
  current_available bigint;
  allocated_lines integer := 0;
  allocated_quantity integer := 0;
  outcome text := 'completed';
begin
  if p_season_id is null
    or p_variant_id is null
    or p_source_type !~ '^[a-z][a-z0-9_]{1,63}$'
  then
    raise exception 'INVENTORY_ALLOCATOR_INPUT_INVALID' using errcode = '22023';
  end if;

  perform private.lock_inventory_mutation();

  for candidate in
    select
      line.id order_line_id,
      line.quantity,
      greatest(payment.paid_at, size_profile.confirmed_at) priority_at
    from app.order_lines line
    join app.member_orders orders on orders.id = line.order_id
    join lateral (
      select payment.paid_at
      from app.payments payment
      where payment.order_id = orders.id
        and payment.status = 'paid'
        and payment.reconciliation_issue is null
      order by payment.paid_at, payment.created_at, payment.id
      limit 1
    ) payment on true
    join app.member_article_sizes size_profile
      on size_profile.member_season_id = orders.member_season_id
      and size_profile.article_id = line.article_id
      and size_profile.article_variant_id = line.article_variant_id
      and size_profile.selection_status in ('confirmed', 'locked')
      and size_profile.confirmed_at is not null
    where orders.season_id = p_season_id
      and line.article_variant_id = p_variant_id
      and line.status = 'backorder'
      and private.order_has_effective_paid_payment(orders.id)
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      )
    order by greatest(payment.paid_at, size_profile.confirmed_at),
      line.created_at, line.id
  loop
    select balance.available
    into current_available
    from private.inventory_balance(p_season_id, p_variant_id) balance;

    if current_available < candidate.quantity then
      outcome := 'insufficient_stock';
      exit;
    end if;

    allocation_id := private.reserve_inventory_order_line(
      candidate.order_line_id,
      'fifo',
      p_actor,
      null,
      p_source_type,
      p_source_id,
      p_correlation_id
    );

    if allocation_id is null then
      outcome := 'concurrent_mutation';
      exit;
    end if;

    allocated_lines := allocated_lines + 1;
    allocated_quantity := allocated_quantity + candidate.quantity;
  end loop;

  perform private.refresh_inventory_variant_actions(
    p_season_id,
    p_variant_id,
    p_source_type,
    p_source_id
  );
  perform private.refresh_paid_waiting_actions(p_season_id, p_variant_id);

  return jsonb_build_object(
    'seasonId', p_season_id,
    'variantId', p_variant_id,
    'allocatedLines', allocated_lines,
    'allocatedQuantity', allocated_quantity,
    'outcome', outcome,
    'blockedByConcurrentMutation', outcome = 'concurrent_mutation'
  );
end;
$$;

revoke all on function private.allocate_inventory_fifo_variant(
  uuid, uuid, text, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
