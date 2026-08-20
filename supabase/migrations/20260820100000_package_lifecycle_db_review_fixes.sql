-- Follow-up hardening after full pgTAP review. Keep the established broad
-- confirmation predicate for reminder workflows and use a distinct strict
-- valid-variant predicate at payment boundaries.

create or replace function private.package_sizes_complete(
  p_order_id uuid, p_snapshot_id uuid
) returns boolean language sql stable security definer
set search_path = app, private, pg_temp as $$
  select p_order_id is not null and p_snapshot_id is not null
    and exists(
      select 1 from app.member_package_assignments assignment
      where assignment.id = p_snapshot_id and assignment.order_id = p_order_id
        and assignment.status = 'active'
    )
    and exists(
      select 1 from app.order_package_snapshot_items item
      where item.snapshot_id = p_snapshot_id
    )
    and not exists(
      select 1 from app.order_package_snapshot_items item
      where item.snapshot_id = p_snapshot_id
        and not exists(
          select 1 from app.member_package_size_selections selection
          where selection.assignment_id = p_snapshot_id
            and selection.snapshot_item_id = item.id
            and selection.article_id = item.article_id
        )
    );
$$;

create or replace function private.package_variant_sizes_complete(
  p_order_id uuid, p_snapshot_id uuid
) returns boolean language sql stable security definer
set search_path = app, private, pg_temp as $$
  select p_order_id is not null and p_snapshot_id is not null
    and exists(
      select 1 from app.member_package_assignments assignment
      where assignment.id = p_snapshot_id
        and assignment.order_id = p_order_id
        and assignment.status = 'active'
    )
    and exists(
      select 1 from app.order_package_snapshot_items item
      where item.snapshot_id = p_snapshot_id
    )
    and not exists(
      select 1
      from app.order_package_snapshot_items item
      join app.member_orders orders on orders.id = p_order_id
      where item.snapshot_id = p_snapshot_id
        and not exists(
          select 1
          from app.member_package_size_selections selection
          join app.article_variants variant
            on variant.id = selection.selected_variant_id
            and variant.article_id = item.article_id
            and variant.active
          join app.article_seasons article_season
            on article_season.article_id = variant.article_id
            and article_season.season_id = orders.season_id
          where selection.assignment_id = p_snapshot_id
            and selection.snapshot_item_id = item.id
            and selection.article_id = item.article_id
            and selection.selection_kind = 'variant'
        )
    );
$$;
revoke all on function private.package_variant_sizes_complete(uuid, uuid)
from public, anon, authenticated, service_role;

-- Resolve package execution by the explicit link first, then by the immutable
-- template component for pre-link historical rows. Package progress is always
-- credited with snapshot quantity; package-backed lines are never loose too.
create or replace function private.package_fulfilment_quantities(p_order_id uuid)
returns jsonb language sql stable security definer
set search_path = app, private, pg_temp as $$
  with target as (
    select orders.id order_id, orders.active_package_snapshot_id snapshot_id
    from app.member_orders orders where orders.id = p_order_id
  ), package_items as (
    select item.id, item.template_item_id, item.quantity,
      coalesce(linked.id, matched.id) order_line_id,
      coalesce(linked.status, matched.status) line_status
    from target
    join app.order_package_snapshot_items item
      on item.snapshot_id = target.snapshot_id
    left join app.order_lines linked
      on linked.id = item.order_line_id and linked.status <> 'cancelled'
    left join lateral (
      select line.id, line.status
      from app.order_lines line
      where linked.id is null
        and line.order_id = target.order_id
        and line.status <> 'cancelled'
        and line.package_template_item_id = item.template_item_id
        and line.article_id = item.article_id
        and 1 = (
          select count(*) from app.order_lines candidate
          where candidate.order_id = target.order_id
            and candidate.status <> 'cancelled'
            and candidate.package_template_item_id = item.template_item_id
            and candidate.article_id = item.article_id
        )
      order by line.created_at, line.id
      limit 1
    ) matched on true
  ), package_totals as (
    select coalesce(sum(quantity), 0)::integer expected,
      coalesce(sum(quantity) filter (where line_status = 'ready_for_pickup'), 0)::integer ready,
      coalesce(sum(quantity) filter (where line_status = 'picked_up'), 0)::integer picked,
      coalesce(sum(quantity) filter (where order_line_id is null or line_status = 'backorder'), 0)::integer backorder
    from package_items
  ), loose as (
    select coalesce(sum(line.quantity), 0)::integer expected,
      coalesce(sum(line.quantity) filter (where line.status = 'ready_for_pickup'), 0)::integer ready,
      coalesce(sum(line.quantity) filter (where line.status = 'picked_up'), 0)::integer picked,
      coalesce(sum(line.quantity) filter (where line.status = 'backorder'), 0)::integer backorder
    from app.order_lines line
    where line.order_id = p_order_id and line.status <> 'cancelled'
      and not exists(
        select 1 from package_items item
        where item.order_line_id = line.id
          or (item.template_item_id is not null
            and item.template_item_id = line.package_template_item_id)
      )
  )
  select jsonb_build_object(
    'expectedQuantity', package_totals.expected + loose.expected,
    'readyQuantity', package_totals.ready + loose.ready,
    'pickedUpQuantity', package_totals.picked + loose.picked,
    'backorderQuantity', package_totals.backorder + loose.backorder
  ) from package_totals cross join loose;
$$;

create or replace function private.ensure_package_size_lifecycle(p_order_id uuid)
returns jsonb language plpgsql security definer
set search_path = app, private, extensions, pg_temp as $$
declare
  target_order app.member_orders%rowtype;
  component record;
  target_line app.order_lines%rowtype;
  matching_line_count integer;
  materialized integer := 0;
  linked integer := 0;
begin
  select * into target_order from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  if target_order.package_revision_id is null then
    return jsonb_build_object('orderLinesMaterialized', 0, 'snapshotItemsLinked', 0);
  end if;
  if target_order.package_assignment_state <> 'active'
    or target_order.active_package_snapshot_id is null
  then raise exception 'PACKAGE_SIZES_REQUIRED' using errcode = '23514'; end if;

  perform pg_advisory_xact_lock(hashtextextended('package-lifecycle:' || target_order.id::text, 0));
  if not private.package_variant_sizes_complete(
    target_order.id, target_order.active_package_snapshot_id
  ) then
    raise exception 'PACKAGE_SIZES_REQUIRED' using errcode = '23514';
  end if;

  for component in
    select snapshot_item.*, selection.selected_variant_id
    from app.order_package_snapshot_items snapshot_item
    join app.member_package_size_selections selection
      on selection.assignment_id = snapshot_item.snapshot_id
      and selection.snapshot_item_id = snapshot_item.id
      and selection.selection_kind = 'variant'
    where snapshot_item.snapshot_id = target_order.active_package_snapshot_id
    order by snapshot_item.sort_order, snapshot_item.id
  loop
    target_line := null;
    select * into target_line from app.order_lines line
    where line.id = component.order_line_id and line.status <> 'cancelled' for update;
    if component.order_line_id is not null and target_line.id is null then
      raise exception 'PACKAGE_LINE_STATE_REQUIRES_CORRECTION' using errcode = '23514';
    end if;
    if target_line.id is null then
      select count(*), (array_agg(line.id order by line.created_at, line.id))[1]
      into matching_line_count, target_line.id
      from app.order_lines line
      where line.order_id = target_order.id and line.status <> 'cancelled'
        and line.package_template_item_id = component.template_item_id
        and line.article_id = component.article_id;
      if matching_line_count > 1 then
        raise exception 'PACKAGE_ACTIVE_LINE_DUPLICATE' using errcode = '23514';
      elsif matching_line_count = 1 then
        select * into target_line from app.order_lines line
        where line.id = target_line.id for update;
      end if;
    end if;

    if target_line.id is null then
      insert into app.order_lines(order_id, article_variant_id, quantity, package_template_item_id)
      values(target_order.id, component.selected_variant_id, component.quantity, component.template_item_id)
      returning * into target_line;
      materialized := materialized + 1;
    elsif target_line.order_id is distinct from target_order.id
      or target_line.article_variant_id is distinct from component.selected_variant_id
      or target_line.quantity is distinct from component.quantity
      or target_line.package_template_item_id is distinct from component.template_item_id
    then
      raise exception 'PACKAGE_LINE_STATE_REQUIRES_CORRECTION' using errcode = '23514';
    end if;
    update app.order_package_snapshot_items
    set order_line_id = target_line.id,
        article_variant_id = component.selected_variant_id,
        variant_label_snapshot = target_line.size_snapshot,
        size_snapshot = target_line.size_snapshot
    where id = component.id and order_line_id is null;
    if found then linked := linked + 1; end if;
    perform private.enqueue_inventory_variant(
      target_order.season_id, component.selected_variant_id, 'package_size_materialized'
    );
  end loop;
  return jsonb_build_object('orderLinesMaterialized', materialized,
    'snapshotItemsLinked', linked);
end;
$$;
revoke all on function private.ensure_package_size_lifecycle(uuid)
from public, anon, authenticated, service_role;

-- Preserve established validation and retry errors. Package preflight runs only
-- for a genuinely new payment on an explicitly confirmed active-package order.
alter function public.prepare_mollie_payment(text, uuid, text)
rename to prepare_mollie_payment_before_db_review;
revoke all on function public.prepare_mollie_payment_before_db_review(text, uuid, text)
from public, anon, authenticated, service_role;
create function public.prepare_mollie_payment(
  p_token_hash text, p_order_id uuid, p_idempotency_key text
) returns jsonb language plpgsql security definer
set search_path = app, private, public, pg_temp as $$
declare target_order app.member_orders%rowtype; account_id uuid;
begin
  account_id := private.parent_account_for_member_season(
    p_token_hash, (select member_season_id from app.member_orders where id = p_order_id)
  );
  if account_id is null then
    return public.prepare_mollie_payment_before_package_sizes(p_token_hash, p_order_id, p_idempotency_key);
  end if;
  select * into target_order from app.member_orders where id = p_order_id for update;
  if target_order.package_assignment_state = 'active'
    and target_order.package_revision_id is not null
    and target_order.active_package_snapshot_id is not null
    and not exists(select 1 from app.payments where idempotency_key = btrim(p_idempotency_key) and order_id <> p_order_id)
    and not exists(select 1 from app.payments where order_id = p_order_id and status in ('paid', 'duplicate_paid'))
    and (
      not exists(select 1 from app.payments where order_id = p_order_id and method = 'mollie' and status in ('open', 'pending'))
      or exists(
        select 1 from app.payments payment
        where payment.order_id = p_order_id and payment.method = 'mollie'
          and payment.status in ('open', 'pending')
          and payment.provider_payment_id is null
          and payment.metadata_schema_version = 2
          and payment.created_at + interval '1 hour' > timezone('utc', now())
      )
    )
  then perform private.ensure_package_size_lifecycle(p_order_id); end if;
  return public.prepare_mollie_payment_before_package_sizes(p_token_hash, p_order_id, p_idempotency_key);
end;
$$;
revoke all on function public.prepare_mollie_payment(text, uuid, text)
from public, anon, authenticated, service_role;
grant execute on function public.prepare_mollie_payment(text, uuid, text) to service_role;

alter function app.record_manual_payment_v2(uuid, app.payment_method, integer, text, uuid, uuid)
rename to record_manual_payment_v2_before_db_review;
revoke all on function app.record_manual_payment_v2_before_db_review(uuid, app.payment_method, integer, text, uuid, uuid)
from public, anon, authenticated, service_role;
create function app.record_manual_payment_v2(
  p_order_id uuid, p_method app.payment_method, p_amount_cents integer,
  p_reason text, p_request_id uuid, p_correlation_id uuid default null
) returns jsonb language plpgsql security definer
set search_path = app, private, pg_temp as $$
declare target_order app.member_orders%rowtype; card_enabled boolean;
begin
  perform private.require_admin_aal2();
  select * into target_order from app.member_orders where id = p_order_id for update;
  select enabled into card_enabled from app.release_feature_flags where key = 'legacy_card_payment';
  if target_order.package_assignment_state = 'active'
    and target_order.package_revision_id is not null
    and target_order.active_package_snapshot_id is not null
    and p_method in ('cash', 'card')
    and (p_method <> 'card' or coalesce(card_enabled, false))
    and p_amount_cents = target_order.amount_due_cents
    and not exists(select 1 from private.manual_payment_requests where request_id = p_request_id)
    and not exists(select 1 from app.payments where order_id = p_order_id and status in ('paid', 'duplicate_paid'))
    and not exists(select 1 from app.payments where order_id = p_order_id and reconciliation_issue is not null)
    and not exists(select 1 from app.payments where order_id = p_order_id and method = 'mollie' and status in ('open', 'pending'))
  then perform private.ensure_package_size_lifecycle(p_order_id); end if;
  return app.record_manual_payment_v2_before_package_sizes(
    p_order_id, p_method, p_amount_cents, p_reason, p_request_id, p_correlation_id
  );
end;
$$;
revoke all on function app.record_manual_payment_v2(uuid, app.payment_method, integer, text, uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function app.record_manual_payment_v2(uuid, app.payment_method, integer, text, uuid, uuid) to authenticated;

alter function public.confirm_parent_package_sizes_v5(text, uuid, jsonb, text, uuid, uuid)
rename to confirm_parent_package_sizes_v5_before_db_review;
revoke all on function public.confirm_parent_package_sizes_v5_before_db_review(text, uuid, jsonb, text, uuid, uuid)
from public, anon, authenticated, service_role;
create function public.confirm_parent_package_sizes_v5(
  p_token_hash text, p_member_season_id uuid, p_selections jsonb,
  p_expected_revision text, p_request_id uuid, p_correlation_id uuid default null
) returns jsonb language plpgsql security definer
set search_path = app, private, public, pg_temp as $$
declare target_order_id uuid; result jsonb;
begin
  if private.parent_account_for_member_season(p_token_hash, p_member_season_id) is null then
    return public.confirm_parent_package_sizes_v5_before_paid_lock(
      p_token_hash, p_member_season_id, p_selections, p_expected_revision, p_request_id, p_correlation_id
    );
  end if;
  select id into target_order_id from app.member_orders
  where member_season_id = p_member_season_id for update;
  if p_selections is null or jsonb_typeof(p_selections) <> 'array'
    or exists(
      select 1 from jsonb_array_elements(
        case when jsonb_typeof(p_selections) = 'array' then p_selections else '[]'::jsonb end
      ) submitted
      where jsonb_typeof(submitted.value) <> 'object'
        or coalesce(submitted.value->>'articleId', '') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        or coalesce(submitted.value->>'kind', '') not in ('variant', 'other')
        or (submitted.value->>'kind' = 'variant' and coalesce(submitted.value->>'variantId', '') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
    )
  then
    return public.confirm_parent_package_sizes_v5_before_paid_lock(
      p_token_hash, p_member_season_id, p_selections, p_expected_revision, p_request_id, p_correlation_id
    );
  end if;
  result := public.confirm_parent_package_sizes_v5_before_paid_lock(
    p_token_hash, p_member_season_id, p_selections, p_expected_revision, p_request_id, p_correlation_id
  );
  if exists(select 1 from app.payments where order_id = target_order_id and status = 'paid')
    and exists(select 1 from app.member_orders orders
      where orders.id = target_order_id and orders.package_revision_id is not null)
    and private.package_variant_sizes_complete(
      target_order_id, (select active_package_snapshot_id from app.member_orders where id = target_order_id)
    )
  then
    perform private.ensure_package_size_lifecycle(target_order_id);
    perform app.refresh_order_status(target_order_id);
  end if;
  return result;
end;
$$;
revoke all on function public.confirm_parent_package_sizes_v5(text, uuid, jsonb, text, uuid, uuid)
from public, anon, authenticated;
grant execute on function public.confirm_parent_package_sizes_v5(text, uuid, jsonb, text, uuid, uuid) to service_role;

drop trigger if exists payments_lock_package_sizes on app.payments;
create or replace function private.lock_paid_package_sizes()
returns trigger language plpgsql security definer
set search_path = app, private, pg_temp as $$
begin
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid') then
    begin
      if exists(
        select 1 from app.member_orders orders where orders.id = new.order_id
          and orders.package_revision_id is not null
          and orders.package_assignment_state = 'active'
          and orders.active_package_snapshot_id is not null
      ) then
        perform private.ensure_package_size_lifecycle(new.order_id);
      end if;
    exception when others then
      insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
      values(null, 'package_lifecycle.paid_followup_required', 'member_order', new.order_id,
        jsonb_build_object('errorCode', sqlstate));
    end;
    perform app.refresh_order_status(new.order_id);
  end if;
  return new;
end;
$$;
create trigger payments_lock_package_sizes
after insert or update of status on app.payments
for each row execute function private.lock_paid_package_sizes();

-- The parent workspace uses strict variant readiness for payment/paid recovery;
-- the broader predicate remains available to reminder segmentation only.
create or replace function public.get_parent_package_workspace_v7(p_token_hash text)
returns jsonb language plpgsql stable security definer
set search_path = app, private, public, pg_temp as $$
declare workspace jsonb; members jsonb;
begin
  workspace := public.get_parent_package_workspace_v6(p_token_hash);
  select coalesce(jsonb_agg(
    case when member.value->'order' is null then member.value else
      jsonb_set(
        member.value,
        '{order,sizesConfirmed}',
        to_jsonb(private.package_variant_sizes_complete(
          (member.value #>> '{order,id}')::uuid,
          (select orders.active_package_snapshot_id from app.member_orders orders
            where orders.id = (member.value #>> '{order,id}')::uuid)
        )),
        true
      )
    end order by member.ordinality
  ), '[]'::jsonb) into members
  from jsonb_array_elements(workspace->'members')
    with ordinality member(value, ordinality);
  return jsonb_set(workspace, '{members}', members, true);
end;
$$;
revoke all on function public.get_parent_package_workspace_v7(text)
from public, anon, authenticated;
grant execute on function public.get_parent_package_workspace_v7(text) to service_role;

-- Reconcile paid orders only when explicit confirmation and execution state are
-- unambiguous. Historical duplicates and mismatches remain untouched for review.
do $$
declare
  target_order record;
  detected_count integer := 0;
  review_count integer := 0;
begin
  for target_order in
    select orders.id
    from app.member_orders orders
    where orders.package_assignment_state = 'active'
      and orders.package_revision_id is not null
      and orders.active_package_snapshot_id is not null
      and exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid')
      and exists(
        select 1 from app.order_package_snapshot_items snapshot_item
        left join app.order_lines line
          on line.id = snapshot_item.order_line_id and line.status <> 'cancelled'
        where snapshot_item.snapshot_id = orders.active_package_snapshot_id
          and line.id is null
      )
    order by orders.id
  loop
    detected_count := detected_count + 1;
    review_count := review_count + 1;
    insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
    values(null, 'package_lifecycle.review_required', 'member_order', target_order.id,
      jsonb_build_object('errorCode', 'LEGACY_PACKAGE_EXECUTION_REQUIRES_REVIEW'));
  end loop;

  insert into private.migration_reconciliations(migration_key, status, metrics)
  values(
    '20260820100000_package_lifecycle_db_review_fixes',
    case when review_count = 0 then 'passed' else 'failed' end,
    jsonb_build_object(
      'paidOrdersDetected', detected_count,
      'paidOrdersReconciled', 0,
      'paidOrdersReviewRequired', review_count,
      'orderLinesMaterialized', 0,
      'snapshotItemsLinked', 0
    )
  ) on conflict(migration_key) do update set status = excluded.status,
    metrics = excluded.metrics, reconciled_at = timezone('utc', now());
end;
$$;

notify pgrst, 'reload schema';
