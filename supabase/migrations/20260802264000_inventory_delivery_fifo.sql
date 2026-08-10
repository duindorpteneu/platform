-- Phase B inventory commands, atomic delivery posting and paid/size-valid FIFO.

create or replace function private.inventory_v2_enabled()
returns boolean
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select coalesce((
    select flag.enabled
    from app.release_feature_flags flag
    where flag.key = 'allocation_qr_v2'
  ), false);
$$;

create or replace function private.lock_inventory_mutation()
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('duindorp-inventory-v2-global', 0)
  );
end;
$$;

revoke all on function private.inventory_v2_enabled()
from public, anon, authenticated, service_role;
revoke all on function private.lock_inventory_mutation()
from public, anon, authenticated, service_role;

create or replace function private.inventory_delivery_draft_json(
  p_draft_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'id', draft.id,
    'seasonId', draft.season_id,
    'status', draft.status::text,
    'receivedOn', draft.received_on,
    'supplier', draft.supplier,
    'packingSlipReference', draft.packing_slip_reference,
    'revision', draft.revision,
    'postedReceiptId', draft.posted_receipt_id,
    'postedAt', draft.posted_at,
    'createdAt', draft.created_at,
    'updatedAt', draft.updated_at,
    'lineCount', (
      select count(*)
      from app.inventory_delivery_draft_lines line
      where line.draft_id = draft.id
    ),
    'confirmedCount', (
      select count(*)
      from app.inventory_delivery_draft_lines line
      where line.draft_id = draft.id
        and line.confirmed
    ),
    'totalQuantity', (
      select coalesce(sum(line.quantity), 0)
      from app.inventory_delivery_draft_lines line
      where line.draft_id = draft.id
        and line.confirmed
    ),
    'lines', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', line.id,
          'articleId', line.article_id,
          'variantId', line.article_variant_id,
          'productName', line.product_name_snapshot,
          'productCode', line.product_code_snapshot,
          'size', line.size_snapshot,
          'sku', line.sku_snapshot,
          'quantity', line.quantity,
          'confirmed', line.confirmed,
          'confirmedAt', line.confirmed_at
        )
        order by line.sort_order, line.product_name_snapshot,
          line.size_snapshot, line.article_variant_id
      )
      from app.inventory_delivery_draft_lines line
      where line.draft_id = draft.id
    ), '[]'::jsonb)
  )
  from app.inventory_delivery_drafts draft
  where draft.id = p_draft_id;
$$;

revoke all on function private.inventory_delivery_draft_json(uuid)
from public, anon, authenticated, service_role;

create or replace function app.create_inventory_delivery_draft(
  p_season_id uuid,
  p_received_on date,
  p_supplier text,
  p_packing_slip_reference text,
  p_article_ids uuid[],
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  normalized_supplier text;
  normalized_reference text;
  normalized_articles uuid[];
  request_hash text;
  existing app.inventory_delivery_drafts%rowtype;
  draft_id uuid;
  requested_count integer;
  inserted_count integer;
begin
  normalized_supplier := regexp_replace(
    btrim(coalesce(p_supplier, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  normalized_reference := nullif(
    regexp_replace(
      btrim(coalesce(p_packing_slip_reference, '')),
      '[[:space:]]+',
      ' ',
      'g'
    ),
    ''
  );
  select array_agg(article_id order by article_id)
  into normalized_articles
  from (
    select distinct article_id
    from unnest(coalesce(p_article_ids, array[]::uuid[])) article_id
  ) selected;
  requested_count := coalesce(array_length(p_article_ids, 1), 0);

  if p_season_id is null
    or p_received_on is null
    or p_received_on > current_date + 1
    or length(normalized_supplier) not between 1 and 160
    or (
      normalized_reference is not null
      and length(normalized_reference) not between 1 and 160
    )
    or p_request_id is null
    or requested_count not between 1 and 50
    or requested_count <> coalesce(array_length(normalized_articles, 1), 0)
  then
    raise exception 'INVENTORY_DELIVERY_DRAFT_INVALID' using errcode = '22023';
  end if;

  if not exists(
    select 1
    from app.seasons season
    where season.id = p_season_id
      and season.status = 'open'
  ) then
    raise exception 'INVENTORY_SEASON_NOT_OPEN' using errcode = '23514';
  end if;

  if (
    select count(*)
    from app.articles article
    join app.article_seasons link
      on link.article_id = article.id
      and link.season_id = p_season_id
    where article.id = any(normalized_articles)
      and article.active
  ) <> requested_count
  or exists(
    select 1
    from unnest(normalized_articles) selected(article_id)
    where not exists(
      select 1
      from app.article_variants variant
      where variant.article_id = selected.article_id
        and variant.active
    )
  ) then
    raise exception 'INVENTORY_DELIVERY_PRODUCT_INVALID' using errcode = '23514';
  end if;

  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'inventory-delivery-create-v1',
        p_season_id::text,
        p_received_on::text,
        normalized_supplier,
        coalesce(normalized_reference, ''),
        array_to_string(normalized_articles, ',')
      ),
      'sha256'
    ),
    'hex'
  );

  select * into existing
  from app.inventory_delivery_drafts draft
  where draft.create_request_id = p_request_id;
  if found then
    if existing.create_request_hash <> request_hash then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return private.inventory_delivery_draft_json(existing.id)
      || jsonb_build_object('reused', true);
  end if;

  insert into app.inventory_delivery_drafts(
    season_id,
    received_on,
    supplier,
    packing_slip_reference,
    create_request_id,
    create_request_hash,
    created_by,
    updated_by
  ) values (
    p_season_id,
    p_received_on,
    normalized_supplier,
    normalized_reference,
    p_request_id,
    request_hash,
    actor,
    actor
  )
  returning id into draft_id;

  insert into app.inventory_delivery_draft_lines(
    draft_id,
    article_id,
    article_variant_id,
    product_name_snapshot,
    product_code_snapshot,
    size_snapshot,
    sku_snapshot,
    sort_order
  )
  select
    draft_id,
    article.id,
    variant.id,
    article.name,
    article.code,
    variant.size,
    variant.sku,
    article.sort_order
  from app.articles article
  join app.article_variants variant
    on variant.article_id = article.id
    and variant.active
  where article.id = any(normalized_articles)
  order by article.sort_order, article.id, variant.sort_order, variant.id;
  get diagnostics inserted_count = row_count;

  if inserted_count = 0 then
    raise exception 'INVENTORY_DELIVERY_VARIANTS_REQUIRED' using errcode = '23514';
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    actor,
    'inventory.delivery_draft.created',
    'inventory_delivery_draft',
    draft_id,
    jsonb_build_object(
      'seasonId', p_season_id,
      'productCount', requested_count,
      'lineCount', inserted_count
    )
  );

  return private.inventory_delivery_draft_json(draft_id)
    || jsonb_build_object('reused', false);
end;
$$;

revoke all on function app.create_inventory_delivery_draft(
  uuid, date, text, text, uuid[], uuid
) from public, anon;
grant execute on function app.create_inventory_delivery_draft(
  uuid, date, text, text, uuid[], uuid
) to authenticated;

create or replace function app.update_inventory_delivery_draft(
  p_draft_id uuid,
  p_expected_revision integer,
  p_lines jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  target app.inventory_delivery_drafts%rowtype;
  item jsonb;
  normalized_lines jsonb := '[]'::jsonb;
  normalized_item jsonb;
  request_hash text;
  prior private.inventory_command_requests%rowtype;
  result jsonb;
  input_count integer;
  draft_count integer;
  all_confirmed boolean;
begin
  input_count := case
    when jsonb_typeof(p_lines) = 'array' then jsonb_array_length(p_lines)
    else 0
  end;
  if p_draft_id is null
    or p_expected_revision is null
    or p_expected_revision < 1
    or p_request_id is null
    or jsonb_typeof(p_lines) <> 'array'
    or input_count not between 1 and 500
  then
    raise exception 'INVENTORY_DELIVERY_UPDATE_INVALID' using errcode = '22023';
  end if;

  for item in select value from jsonb_array_elements(p_lines)
  loop
    if jsonb_typeof(item) <> 'object'
      or not (
        item ? 'variantId'
        and item ? 'quantity'
        and item ? 'confirmed'
      )
      or (select count(*) from jsonb_object_keys(item)) <> 3
      or (item->>'variantId') !~
        '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or (
        item->'quantity' <> 'null'::jsonb
        and (
          jsonb_typeof(item->'quantity') <> 'number'
          or (item->>'quantity') !~ '^(0|[1-9][0-9]{0,4})$'
          or (item->>'quantity')::integer > 10000
        )
      )
      or jsonb_typeof(item->'confirmed') <> 'boolean'
      or (
        (item->>'confirmed')::boolean
        and item->'quantity' = 'null'::jsonb
      )
    then
      raise exception 'INVENTORY_DELIVERY_LINE_INVALID' using errcode = '22023';
    end if;

    normalized_item := jsonb_build_object(
      'variant_id', lower(item->>'variantId'),
      'quantity', case
        when item->'quantity' = 'null'::jsonb then null
        else (item->>'quantity')::integer
      end,
      'confirmed', (item->>'confirmed')::boolean
    );
    normalized_lines := normalized_lines || jsonb_build_array(normalized_item);
  end loop;

  select jsonb_agg(value order by value->>'variant_id')
  into normalized_lines
  from jsonb_array_elements(normalized_lines);

  if (
    select count(distinct value->>'variant_id')
    from jsonb_array_elements(normalized_lines)
  ) <> input_count then
    raise exception 'INVENTORY_DELIVERY_LINE_DUPLICATE' using errcode = '22023';
  end if;

  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'inventory-delivery-update-v1',
        p_draft_id::text,
        p_expected_revision::text,
        normalized_lines::text
      ),
      'sha256'
    ),
    'hex'
  );

  select * into prior
  from private.inventory_command_requests request
  where request.request_id = p_request_id;
  if found then
    if prior.command_type <> 'inventory.delivery.update'
      or prior.target_id <> p_draft_id
      or prior.request_hash <> request_hash
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  select * into target
  from app.inventory_delivery_drafts draft
  where draft.id = p_draft_id
  for update;
  if not found then
    raise exception 'INVENTORY_DELIVERY_DRAFT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.status not in ('draft', 'ready') then
    raise exception 'INVENTORY_DELIVERY_DRAFT_IMMUTABLE' using errcode = '23514';
  end if;
  if target.revision <> p_expected_revision then
    raise exception 'INVENTORY_DELIVERY_REVISION_CONFLICT' using errcode = '40001';
  end if;

  select count(*) into draft_count
  from app.inventory_delivery_draft_lines line
  where line.draft_id = p_draft_id;
  if draft_count <> input_count
    or exists(
      select 1
      from jsonb_array_elements(normalized_lines) entry
      where not exists(
        select 1
        from app.inventory_delivery_draft_lines line
        where line.draft_id = p_draft_id
          and line.article_variant_id = (entry->>'variant_id')::uuid
      )
    )
  then
    raise exception 'INVENTORY_DELIVERY_FULL_MATRIX_REQUIRED'
      using errcode = '23514';
  end if;

  update app.inventory_delivery_draft_lines line
  set quantity = input.quantity,
      confirmed = input.confirmed,
      confirmed_at = case
        when input.confirmed then coalesce(line.confirmed_at, timezone('utc', now()))
        else null
      end,
      confirmed_by = case when input.confirmed then actor else null end,
      updated_at = timezone('utc', now())
  from jsonb_to_recordset(normalized_lines)
    as input(variant_id uuid, quantity integer, confirmed boolean)
  where line.draft_id = p_draft_id
    and line.article_variant_id = input.variant_id;

  select bool_and(line.confirmed and line.quantity is not null)
  into all_confirmed
  from app.inventory_delivery_draft_lines line
  where line.draft_id = p_draft_id;

  update app.inventory_delivery_drafts
  set status = case
        when all_confirmed then 'ready'::app.inventory_delivery_status
        else 'draft'::app.inventory_delivery_status
      end,
      revision = revision + 1,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where id = p_draft_id;

  result := private.inventory_delivery_draft_json(p_draft_id)
    || jsonb_build_object('reused', false);
  insert into private.inventory_command_requests(
    request_id,
    command_type,
    target_id,
    request_hash,
    result_snapshot,
    actor_user_id
  ) values (
    p_request_id,
    'inventory.delivery.update',
    p_draft_id,
    request_hash,
    result,
    actor
  );

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    actor,
    'inventory.delivery_draft.updated',
    'inventory_delivery_draft',
    p_draft_id,
    jsonb_build_object(
      'lineCount', input_count,
      'ready', all_confirmed,
      'revision', p_expected_revision + 1
    )
  );
  return result;
end;
$$;

revoke all on function app.update_inventory_delivery_draft(
  uuid, integer, jsonb, uuid
) from public, anon;
grant execute on function app.update_inventory_delivery_draft(
  uuid, integer, jsonb, uuid
) to authenticated;

create or replace function private.inventory_action_key(
  p_scope text,
  p_season_id uuid,
  p_object_id uuid
)
returns text
language sql
immutable
set search_path = extensions, pg_temp
as $$
  select encode(
    extensions.digest(
      concat_ws('|', p_scope, p_season_id::text, p_object_id::text),
      'sha256'
    ),
    'hex'
  );
$$;

revoke all on function private.inventory_action_key(text, uuid, uuid)
from public, anon, authenticated, service_role;

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
      p_source_type,
      p_source_id,
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
      p_source_type,
      p_source_id,
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

create or replace function private.refresh_paid_waiting_actions(
  p_season_id uuid,
  p_variant_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
  action_key text;
  current_available bigint;
begin
  select balance.available into current_available
  from private.inventory_balance(p_season_id, p_variant_id) balance;

  for target in
    select
      line.id order_line_id,
      line.quantity,
      row_number() over (
        order by greatest(payment.paid_at, size_profile.confirmed_at),
          line.created_at, line.id
      ) queue_position
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
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      )
  loop
    action_key := private.inventory_action_key(
      'paid-waiting-stock-v1',
      p_season_id,
      target.order_line_id
    );
    perform private.open_action_item(
      'paid_waiting_stock',
      p_season_id,
      'order_line',
      target.order_line_id,
      'article_variant',
      p_variant_id,
      action_key,
      (
        case when current_available = 0 then 'critical' else 'warning' end
      )::app.action_item_severity,
      'operations'::app.action_item_visibility,
      case
        when current_available = 0 then 'inventory.paid_waiting_zero'
        else 'inventory.paid_waiting_insufficient'
      end,
      jsonb_build_object(
        'orderItemId', target.order_line_id,
        'variantId', p_variant_id,
        'quantity', target.quantity,
        'available', current_available,
        'queueDepth', target.queue_position
      ),
      null
    );
  end loop;

  for target in
    select item.object_id order_line_id, item.dedupe_key
    from app.action_items item
    where item.type = 'paid_waiting_stock'
      and item.season_id = p_season_id
      and item.status in ('open', 'in_progress')
      and item.safe_context->>'variantId' = p_variant_id::text
      and not exists(
        select 1
        from app.order_lines line
        join app.member_orders orders on orders.id = line.order_id
        join app.payments payment
          on payment.order_id = orders.id
          and payment.status = 'paid'
          and payment.reconciliation_issue is null
        join app.member_article_sizes size_profile
          on size_profile.member_season_id = orders.member_season_id
          and size_profile.article_id = line.article_id
          and size_profile.article_variant_id = line.article_variant_id
          and size_profile.selection_status in ('confirmed', 'locked')
          and size_profile.confirmed_at is not null
        where line.id = item.object_id
          and line.status = 'backorder'
          and not exists(
            select 1
            from app.inventory_allocations allocation
            where allocation.order_line_id = line.id
              and allocation.status in ('reserved', 'fulfilled')
          )
      )
  loop
    perform private.auto_resolve_action_item(
      'paid_waiting_stock',
      p_season_id,
      target.dedupe_key,
      'system: deze orderregel wacht niet meer betaald op voorraad'
    );
  end loop;
end;
$$;

revoke all on function private.refresh_paid_waiting_actions(uuid, uuid)
from public, anon, authenticated, service_role;

create or replace function private.reserve_inventory_order_line(
  p_order_line_id uuid,
  p_mode app.inventory_allocation_mode,
  p_actor uuid,
  p_override_reason text default null,
  p_source_type text default 'allocator',
  p_source_id uuid default null,
  p_correlation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  candidate record;
  allocation_id uuid;
  movement_id uuid;
  current_available bigint;
  action_key text;
begin
  if p_order_line_id is null
    or p_mode not in ('fifo', 'admin_override')
    or (
      p_mode = 'admin_override'
      and length(btrim(coalesce(p_override_reason, ''))) not between 4 and 500
    )
  then
    raise exception 'INVENTORY_ALLOCATION_INPUT_INVALID' using errcode = '22023';
  end if;
  perform private.lock_inventory_mutation();

  begin
    perform 1
    from app.member_orders orders
    join app.order_lines line on line.order_id = orders.id
    where line.id = p_order_line_id
    for update of orders, line nowait;
  exception when lock_not_available then
    return null;
  end;

  select
    orders.id order_id,
    orders.member_id,
    orders.member_season_id,
    orders.season_id,
    line.id order_line_id,
    line.article_id,
    line.article_variant_id,
    line.quantity,
    line.product_name_snapshot,
    line.size_snapshot,
    payment.paid_at,
    size_profile.confirmed_at size_valid_at
  into candidate
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
  where line.id = p_order_line_id
    and line.status = 'backorder'
    and not exists(
      select 1
      from app.inventory_allocations allocation
      where allocation.order_line_id = line.id
        and allocation.status in ('reserved', 'fulfilled')
    );
  if not found then
    return null;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'inventory-balance:'
        || candidate.season_id::text
        || ':'
        || candidate.article_variant_id::text,
      0
    )
  );
  select balance.available into current_available
  from private.inventory_balance(
    candidate.season_id,
    candidate.article_variant_id
  ) balance;
  if current_available < candidate.quantity then
    return null;
  end if;

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
    allocated_at,
    allocated_by,
    override_reason
  ) values (
    candidate.season_id,
    candidate.member_id,
    candidate.member_season_id,
    candidate.order_id,
    candidate.order_line_id,
    candidate.article_id,
    candidate.article_variant_id,
    candidate.quantity,
    'reserved',
    'resolved',
    p_mode,
    candidate.paid_at,
    candidate.size_valid_at,
    greatest(candidate.paid_at, candidate.size_valid_at),
    candidate.product_name_snapshot,
    candidate.size_snapshot,
    timezone('utc', now()),
    p_actor,
    case when p_mode = 'admin_override' then btrim(p_override_reason) else null end
  )
  returning id into allocation_id;

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
    safe_context
  ) values (
    allocation_id,
    'reserved',
    null,
    'reserved',
    case
      when p_mode = 'fifo' then 'inventory.fifo_reserved'
      else 'inventory.admin_override_reserved'
    end,
    p_source_type,
    p_source_id,
    encode(
      extensions.digest(
        'inventory-allocation-reserved:' || allocation_id::text,
        'sha256'
      ),
      'hex'
    ),
    p_actor,
    jsonb_build_object(
      'allocationId', allocation_id,
      'orderItemId', candidate.order_line_id,
      'variantId', candidate.article_variant_id,
      'quantity', candidate.quantity
    )
  );

  insert into app.inventory_movements(
    season_id,
    article_id,
    article_variant_id,
    movement_type,
    reserved_delta,
    allocation_id,
    source_type,
    source_id,
    reason_code,
    idempotency_key,
    actor_user_id,
    correlation_id,
    safe_context
  ) values (
    candidate.season_id,
    candidate.article_id,
    candidate.article_variant_id,
    'allocation_reserved',
    candidate.quantity,
    allocation_id,
    p_source_type,
    p_source_id,
    'inventory.allocation_reserved',
    encode(
      extensions.digest(
        'inventory-allocation-movement:' || allocation_id::text,
        'sha256'
      ),
      'hex'
    ),
    p_actor,
    p_correlation_id,
    jsonb_build_object(
      'allocationId', allocation_id,
      'orderItemId', candidate.order_line_id,
      'variantId', candidate.article_variant_id,
      'quantity', candidate.quantity
    )
  )
  returning id into movement_id;

  update app.order_lines
  set status = 'ready_for_pickup',
      updated_at = timezone('utc', now())
  where id = candidate.order_line_id;
  perform app.refresh_order_status(candidate.order_id);

  action_key := private.inventory_action_key(
    'paid-waiting-stock-v1',
    candidate.season_id,
    candidate.order_line_id
  );
  perform private.auto_resolve_action_item(
    'paid_waiting_stock',
    candidate.season_id,
    action_key,
    'system: voorraad is hard toegewezen'
  );

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    p_actor,
    case
      when p_mode = 'fifo' then 'inventory.allocation.fifo'
      else 'inventory.allocation.override'
    end,
    'inventory_allocation',
    allocation_id,
    jsonb_build_object(
      'seasonId', candidate.season_id,
      'orderId', candidate.order_id,
      'orderLineId', candidate.order_line_id,
      'variantId', candidate.article_variant_id,
      'quantity', candidate.quantity,
      'movementId', movement_id,
      'overrideReason', case
        when p_mode = 'admin_override' then btrim(p_override_reason)
        else null
      end
    ),
    p_correlation_id
  );
  return allocation_id;
end;
$$;

revoke all on function private.reserve_inventory_order_line(
  uuid, app.inventory_allocation_mode, uuid, text, text, uuid, uuid
) from public, anon, authenticated, service_role;

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
  allocated_lines integer := 0;
  allocated_quantity integer := 0;
  blocked_by_lock boolean := false;
begin
  if p_season_id is null
    or p_variant_id is null
    or p_source_type !~ '^[a-z][a-z0-9_]{1,63}$'
  then
    raise exception 'INVENTORY_ALLOCATOR_INPUT_INVALID' using errcode = '22023';
  end if;
  perform private.lock_inventory_mutation();

  loop
    select
      line.id order_line_id,
      line.quantity,
      greatest(payment.paid_at, size_profile.confirmed_at) priority_at
    into candidate
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
      and not exists(
        select 1
        from app.inventory_allocations allocation
        where allocation.order_line_id = line.id
          and allocation.status in ('reserved', 'fulfilled')
      )
    order by greatest(payment.paid_at, size_profile.confirmed_at),
      line.created_at, line.id
    limit 1;
    exit when not found;

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
      blocked_by_lock := true;
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
    'blockedByConcurrentMutation', blocked_by_lock
  );
end;
$$;

revoke all on function private.allocate_inventory_fifo_variant(
  uuid, uuid, text, uuid, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function app.allocate_inventory_override(
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
  normalized_reason text;
  request_hash text;
  prior private.inventory_command_requests%rowtype;
  allocation_id uuid;
  result jsonb;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_order_line_id is null
    or p_request_id is null
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'INVENTORY_OVERRIDE_INVALID' using errcode = '22023';
  end if;
  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'inventory-override-v1',
        p_order_line_id::text,
        normalized_reason
      ),
      'sha256'
    ),
    'hex'
  );
  select * into prior
  from private.inventory_command_requests request
  where request.request_id = p_request_id;
  if found then
    if prior.command_type <> 'inventory.allocation.override'
      or prior.target_id <> p_order_line_id
      or prior.request_hash <> request_hash
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  if not private.inventory_v2_enabled() then
    raise exception 'INVENTORY_V2_NOT_ENABLED' using errcode = '55000';
  end if;
  allocation_id := private.reserve_inventory_order_line(
    p_order_line_id,
    'admin_override',
    actor,
    normalized_reason,
    'admin_override',
    p_request_id,
    p_correlation_id
  );
  if allocation_id is null then
    raise exception 'INVENTORY_OVERRIDE_NOT_ELIGIBLE' using errcode = '23514';
  end if;

  result := jsonb_build_object(
    'allocationId', allocation_id,
    'orderLineId', p_order_line_id,
    'status', 'reserved',
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
    'inventory.allocation.override',
    p_order_line_id,
    request_hash,
    result,
    actor
  );
  return result;
end;
$$;

revoke all on function app.allocate_inventory_override(
  uuid, text, uuid, uuid
) from public, anon;
grant execute on function app.allocate_inventory_override(
  uuid, text, uuid, uuid
) to authenticated;

create or replace function private.enqueue_inventory_variant(
  p_season_id uuid,
  p_variant_id uuid,
  p_reason_code text
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if p_season_id is null
    or p_variant_id is null
    or p_reason_code !~ '^[a-z][a-z0-9._-]{2,79}$'
  then
    raise exception 'INVENTORY_QUEUE_INPUT_INVALID' using errcode = '22023';
  end if;
  insert into private.inventory_allocation_queue(
    season_id,
    article_variant_id,
    status,
    reason_code,
    attempts,
    queued_at,
    started_at,
    completed_at,
    last_error_code,
    updated_at
  ) values (
    p_season_id,
    p_variant_id,
    'queued',
    p_reason_code,
    0,
    timezone('utc', now()),
    null,
    null,
    null,
    timezone('utc', now())
  )
  on conflict (season_id, article_variant_id) do update
  set status = 'queued',
      reason_code = excluded.reason_code,
      queued_at = timezone('utc', now()),
      started_at = null,
      completed_at = null,
      last_error_code = null,
      updated_at = timezone('utc', now());
end;
$$;

revoke all on function private.enqueue_inventory_variant(
  uuid, uuid, text
) from public, anon, authenticated, service_role;

create or replace function app.process_inventory_allocation_queue(
  p_limit integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  job record;
  processed integer := 0;
  failed integer := 0;
  allocation_result jsonb;
begin
  if p_limit not between 1 and 100 then
    raise exception 'INVENTORY_QUEUE_LIMIT_INVALID' using errcode = '22023';
  end if;
  if not private.inventory_v2_enabled() then
    return jsonb_build_object(
      'processed', 0,
      'failed', 0,
      'disabled', true
    );
  end if;

  for job in
    select queue.season_id, queue.article_variant_id, queue.reason_code
    from private.inventory_allocation_queue queue
    where queue.status in ('queued', 'failed')
      and queue.attempts < 10
    order by queue.queued_at, queue.season_id, queue.article_variant_id
    for update skip locked
    limit p_limit
  loop
    update private.inventory_allocation_queue
    set status = 'processing',
        attempts = attempts + 1,
        started_at = timezone('utc', now()),
        completed_at = null,
        last_error_code = null,
        updated_at = timezone('utc', now())
    where season_id = job.season_id
      and article_variant_id = job.article_variant_id;
    begin
      allocation_result := private.allocate_inventory_fifo_variant(
        job.season_id,
        job.article_variant_id,
        'allocation_queue',
        null,
        null,
        null
      );
      update private.inventory_allocation_queue
      set status = case
            when (allocation_result->>'blockedByConcurrentMutation')::boolean
            then 'queued'::app.inventory_queue_status
            else 'completed'::app.inventory_queue_status
          end,
          completed_at = case
            when (allocation_result->>'blockedByConcurrentMutation')::boolean
            then null
            else timezone('utc', now())
          end,
          updated_at = timezone('utc', now())
      where season_id = job.season_id
        and article_variant_id = job.article_variant_id;
      processed := processed + 1;
    exception when others then
      update private.inventory_allocation_queue
      set status = 'failed',
          last_error_code = sqlstate,
          completed_at = timezone('utc', now()),
          updated_at = timezone('utc', now())
      where season_id = job.season_id
        and article_variant_id = job.article_variant_id;
      failed := failed + 1;
    end;
  end loop;
  return jsonb_build_object(
    'processed', processed,
    'failed', failed,
    'disabled', false
  );
end;
$$;

revoke all on function app.process_inventory_allocation_queue(integer)
from public, anon, authenticated, service_role;
grant execute on function app.process_inventory_allocation_queue(integer)
to service_role;

create or replace function app.post_inventory_delivery_draft(
  p_draft_id uuid,
  p_expected_revision integer,
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
  target app.inventory_delivery_drafts%rowtype;
  prior private.inventory_command_requests%rowtype;
  request_hash text;
  receipt_id uuid;
  receipt_line_id uuid;
  movement_id uuid;
  line_record app.inventory_delivery_draft_lines%rowtype;
  allocation_result jsonb;
  allocated_lines integer := 0;
  allocated_quantity integer := 0;
  positive_lines integer := 0;
  result jsonb;
begin
  if p_draft_id is null
    or p_expected_revision is null
    or p_expected_revision < 1
    or p_request_id is null
  then
    raise exception 'INVENTORY_DELIVERY_POST_INVALID' using errcode = '22023';
  end if;
  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'inventory-delivery-post-v1',
        p_draft_id::text,
        p_expected_revision::text
      ),
      'sha256'
    ),
    'hex'
  );
  select * into prior
  from private.inventory_command_requests request
  where request.request_id = p_request_id;
  if found then
    if prior.command_type <> 'inventory.delivery.post'
      or prior.target_id <> p_draft_id
      or prior.request_hash <> request_hash
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  if not private.inventory_v2_enabled() then
    raise exception 'INVENTORY_V2_NOT_ENABLED' using errcode = '55000';
  end if;
  perform private.lock_inventory_mutation();
  select * into target
  from app.inventory_delivery_drafts draft
  where draft.id = p_draft_id
  for update;
  if not found then
    raise exception 'INVENTORY_DELIVERY_DRAFT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.status <> 'ready'
    or target.revision <> p_expected_revision
    or exists(
      select 1
      from app.inventory_delivery_draft_lines line
      where line.draft_id = target.id
        and (not line.confirmed or line.quantity is null)
    )
  then
    raise exception 'INVENTORY_DELIVERY_NOT_READY' using errcode = '23514';
  end if;

  perform set_config('app.inventory_internal', 'on', true);
  insert into app.delivery_receipts(
    received_on,
    supplier,
    packing_slip_reference,
    actor_user_id
  ) values (
    target.received_on,
    target.supplier,
    target.packing_slip_reference,
    actor
  )
  returning id into receipt_id;

  for line_record in
    select line.*
    from app.inventory_delivery_draft_lines line
    where line.draft_id = target.id
      and line.quantity > 0
    order by line.article_variant_id
  loop
    insert into app.delivery_receipt_lines(
      receipt_id,
      article_variant_id,
      received_quantity
    ) values (
      receipt_id,
      line_record.article_variant_id,
      line_record.quantity
    )
    returning id into receipt_line_id;

    insert into app.inventory_movements(
      season_id,
      article_id,
      article_variant_id,
      movement_type,
      on_hand_delta,
      delivery_draft_id,
      receipt_line_id,
      source_type,
      source_id,
      reason_code,
      idempotency_key,
      actor_user_id,
      correlation_id,
      safe_context,
      occurred_at
    ) values (
      target.season_id,
      line_record.article_id,
      line_record.article_variant_id,
      'receipt',
      line_record.quantity,
      target.id,
      receipt_line_id,
      'inventory_delivery',
      target.id,
      'inventory.delivery_posted',
      encode(
        extensions.digest(
          concat_ws(
            ':',
            'inventory-delivery-receipt',
            target.id::text,
            line_record.article_variant_id::text
          ),
          'sha256'
        ),
        'hex'
      ),
      actor,
      p_correlation_id,
      jsonb_build_object(
        'deliveryDraftId', target.id,
        'receiptId', receipt_id,
        'receiptLineId', receipt_line_id,
        'variantId', line_record.article_variant_id,
        'quantity', line_record.quantity
      ),
      target.received_on::timestamp at time zone 'Europe/Amsterdam'
    )
    returning id into movement_id;
    positive_lines := positive_lines + 1;
  end loop;

  update app.inventory_delivery_drafts
  set status = 'posted',
      posted_receipt_id = receipt_id,
      posted_at = timezone('utc', now()),
      posted_by = actor,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where id = target.id;

  for line_record in
    select distinct on (line.article_variant_id) line.*
    from app.inventory_delivery_draft_lines line
    where line.draft_id = target.id
      and line.quantity > 0
    order by line.article_variant_id
  loop
    allocation_result := private.allocate_inventory_fifo_variant(
      target.season_id,
      line_record.article_variant_id,
      'inventory_delivery',
      target.id,
      actor,
      p_correlation_id
    );
    allocated_lines := allocated_lines
      + coalesce((allocation_result->>'allocatedLines')::integer, 0);
    allocated_quantity := allocated_quantity
      + coalesce((allocation_result->>'allocatedQuantity')::integer, 0);
  end loop;
  perform set_config('app.inventory_internal', 'off', true);

  result := jsonb_build_object(
    'draftId', target.id,
    'receiptId', receipt_id,
    'status', 'posted',
    'positiveLines', positive_lines,
    'allocatedLines', allocated_lines,
    'allocatedQuantity', allocated_quantity,
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
    'inventory.delivery.post',
    target.id,
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
    'inventory.delivery.posted',
    'inventory_delivery_draft',
    target.id,
    jsonb_build_object(
      'seasonId', target.season_id,
      'receiptId', receipt_id,
      'positiveLines', positive_lines,
      'allocatedLines', allocated_lines,
      'allocatedQuantity', allocated_quantity
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke all on function app.post_inventory_delivery_draft(
  uuid, integer, uuid, uuid
) from public, anon;
grant execute on function app.post_inventory_delivery_draft(
  uuid, integer, uuid, uuid
) to authenticated;

create or replace function app.cancel_inventory_delivery_draft(
  p_draft_id uuid,
  p_expected_revision integer,
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
  actor uuid := private.require_clothing_aal2();
  normalized_reason text;
  request_hash text;
  prior private.inventory_command_requests%rowtype;
  target app.inventory_delivery_drafts%rowtype;
  result jsonb;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_draft_id is null
    or p_expected_revision is null
    or p_expected_revision < 1
    or p_request_id is null
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'INVENTORY_DELIVERY_CANCEL_INVALID' using errcode = '22023';
  end if;
  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'inventory-delivery-cancel-v1',
        p_draft_id::text,
        p_expected_revision::text,
        normalized_reason
      ),
      'sha256'
    ),
    'hex'
  );
  select * into prior
  from private.inventory_command_requests request
  where request.request_id = p_request_id;
  if found then
    if prior.command_type <> 'inventory.delivery.cancel'
      or prior.target_id <> p_draft_id
      or prior.request_hash <> request_hash
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  select * into target
  from app.inventory_delivery_drafts draft
  where draft.id = p_draft_id
  for update;
  if not found then
    raise exception 'INVENTORY_DELIVERY_DRAFT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.status not in ('draft', 'ready')
    or target.revision <> p_expected_revision
  then
    raise exception 'INVENTORY_DELIVERY_CANCEL_CONFLICT' using errcode = '40001';
  end if;
  update app.inventory_delivery_drafts
  set status = 'cancelled',
      cancelled_at = timezone('utc', now()),
      cancellation_reason = normalized_reason,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where id = target.id;

  result := jsonb_build_object(
    'draftId', target.id,
    'status', 'cancelled',
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
    'inventory.delivery.cancel',
    target.id,
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
    'inventory.delivery.cancelled',
    'inventory_delivery_draft',
    target.id,
    jsonb_build_object(
      'seasonId', target.season_id,
      'reason', normalized_reason
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke all on function app.cancel_inventory_delivery_draft(
  uuid, integer, text, uuid, uuid
) from public, anon;
grant execute on function app.cancel_inventory_delivery_draft(
  uuid, integer, text, uuid, uuid
) to authenticated;

create or replace function private.release_order_inventory_allocations(
  p_order_id uuid,
  p_reason text,
  p_actor uuid,
  p_source_type text,
  p_source_id uuid,
  p_correlation_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  allocation app.inventory_allocations%rowtype;
  released_count integer := 0;
  affected_variants uuid[] := array[]::uuid[];
  target_variant uuid;
  order_season_id uuid;
  conflict_key text;
begin
  if p_order_id is null
    or length(btrim(coalesce(p_reason, ''))) not between 4 and 500
    or p_source_type !~ '^[a-z][a-z0-9_]{1,63}$'
  then
    raise exception 'INVENTORY_RELEASE_INPUT_INVALID' using errcode = '22023';
  end if;
  perform private.lock_inventory_mutation();
  select orders.season_id into order_season_id
  from app.member_orders orders
  where orders.id = p_order_id;
  if order_season_id is null then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;

  for allocation in
    select current_allocation.*
    from app.inventory_allocations current_allocation
    where current_allocation.order_id = p_order_id
      and current_allocation.status = 'reserved'
    order by current_allocation.article_variant_id, current_allocation.id
    for update
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        'inventory-balance:'
          || allocation.season_id::text
          || ':'
          || allocation.article_variant_id::text,
        0
      )
    );
    insert into app.inventory_movements(
      season_id,
      article_id,
      article_variant_id,
      movement_type,
      reserved_delta,
      allocation_id,
      source_type,
      source_id,
      reason_code,
      idempotency_key,
      actor_user_id,
      correlation_id,
      safe_context
    ) values (
      allocation.season_id,
      allocation.article_id,
      allocation.article_variant_id,
      'allocation_released',
      -allocation.quantity,
      allocation.id,
      p_source_type,
      p_source_id,
      'inventory.allocation_released',
      encode(
        extensions.digest(
          concat_ws(
            ':',
            'inventory-allocation-release',
            allocation.id::text,
            p_source_type,
            coalesce(p_source_id::text, 'none')
          ),
          'sha256'
        ),
        'hex'
      ),
      p_actor,
      p_correlation_id,
      jsonb_build_object(
        'allocationId', allocation.id,
        'orderItemId', allocation.order_line_id,
        'variantId', allocation.article_variant_id,
        'quantity', allocation.quantity
      )
    );

    perform set_config('app.inventory_internal', 'on', true);
    update app.inventory_allocations
    set status = 'released',
        released_at = timezone('utc', now()),
        released_by = p_actor,
        release_reason = btrim(p_reason),
        updated_at = timezone('utc', now())
    where id = allocation.id;
    if allocation.legacy_reservation_id is not null then
      update app.inventory_reservations
      set status = 'released',
          updated_at = timezone('utc', now())
      where id = allocation.legacy_reservation_id
        and status = 'reserved';
    end if;
    perform set_config('app.inventory_internal', 'off', true);

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
      safe_context
    ) values (
      allocation.id,
      'released',
      'reserved',
      'released',
      'inventory.allocation_released',
      p_source_type,
      p_source_id,
      encode(
        extensions.digest(
          concat_ws(
            ':',
            'inventory-allocation-release-event',
            allocation.id::text,
            p_source_type,
            coalesce(p_source_id::text, 'none')
          ),
          'sha256'
        ),
        'hex'
      ),
      p_actor,
      jsonb_build_object(
        'allocationId', allocation.id,
        'orderItemId', allocation.order_line_id,
        'variantId', allocation.article_variant_id,
        'quantity', allocation.quantity
      )
    );
    update app.order_lines
    set status = 'backorder',
        updated_at = timezone('utc', now())
    where id = allocation.order_line_id
      and status = 'ready_for_pickup';
    if not allocation.article_variant_id = any(affected_variants) then
      affected_variants := array_append(
        affected_variants,
        allocation.article_variant_id
      );
    end if;
    released_count := released_count + 1;
  end loop;

  update private.qr_tokens
  set active = false,
      revoked_at = coalesce(revoked_at, timezone('utc', now())),
      revoked_by = coalesce(revoked_by, p_actor),
      revocation_reason = coalesce(
        revocation_reason,
        left(btrim(p_reason), 500)
      )
  where order_id = p_order_id
    and active;
  perform app.refresh_order_status(p_order_id);

  if exists(
    select 1
    from app.inventory_allocations fulfilled_allocation
    where fulfilled_allocation.order_id = p_order_id
      and fulfilled_allocation.status = 'fulfilled'
  ) then
    conflict_key := private.inventory_action_key(
      'payment-fulfilled-conflict-v1',
      order_season_id,
      p_order_id
    );
    perform private.open_action_item(
      'payment_conflict',
      order_season_id,
      'member_order',
      p_order_id,
      p_source_type,
      p_source_id,
      conflict_key,
      'critical'::app.action_item_severity,
      'admin_only'::app.action_item_visibility,
      'payment.refunded_after_fulfilment',
      jsonb_build_object(
        'packageOrderId', p_order_id,
        'count', (
          select count(*)
          from app.inventory_allocations fulfilled_allocation
          where fulfilled_allocation.order_id = p_order_id
            and fulfilled_allocation.status = 'fulfilled'
        ),
        'blocked', true
      ),
      null
    );
  end if;

  foreach target_variant in array affected_variants
  loop
    perform private.refresh_inventory_variant_actions(
      order_season_id,
      target_variant,
      p_source_type,
      p_source_id
    );
    perform private.refresh_paid_waiting_actions(
      order_season_id,
      target_variant
    );
  end loop;

  if released_count > 0 then
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata,
      correlation_id
    ) values (
      p_actor,
      'inventory.order_allocations.released',
      'member_order',
      p_order_id,
      jsonb_build_object(
        'releasedCount', released_count,
        'reason', btrim(p_reason),
        'sourceType', p_source_type
      ),
      p_correlation_id
    );
  end if;
  return released_count;
end;
$$;

revoke all on function private.release_order_inventory_allocations(
  uuid, text, uuid, text, uuid, uuid
) from public, anon, authenticated, service_role;

create or replace function private.handle_payment_inventory_transition()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target record;
begin
  if (
    new.status = 'paid'
    and (tg_op = 'INSERT' or old.status <> 'paid')
  ) then
    for target in
      select distinct orders.season_id, line.article_variant_id
      from app.member_orders orders
      join app.order_lines line on line.order_id = orders.id
      where orders.id = new.order_id
        and line.status = 'backorder'
    loop
      perform private.enqueue_inventory_variant(
        target.season_id,
        target.article_variant_id,
        'payment.became_paid'
      );
    end loop;
  elsif tg_op = 'UPDATE'
    and old.status = 'paid'
    and new.status <> 'paid'
  then
    perform private.release_order_inventory_allocations(
      new.order_id,
      'Betaling is niet langer definitief voldaan',
      null,
      'payment',
      new.id,
      null
    );
  end if;
  return new;
end;
$$;

create trigger payments_inventory_transition
after insert or update of status on app.payments
for each row execute function private.handle_payment_inventory_transition();

revoke all on function private.handle_payment_inventory_transition()
from public, anon, authenticated, service_role;

create or replace function private.handle_size_inventory_transition()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if new.article_variant_id is not null
    and new.selection_status in ('confirmed', 'locked')
    and new.confirmed_at is not null
    and (
      tg_op = 'INSERT'
      or old.article_variant_id is distinct from new.article_variant_id
      or old.selection_status is distinct from new.selection_status
      or old.confirmed_at is distinct from new.confirmed_at
    )
  then
    perform private.enqueue_inventory_variant(
      new.season_id,
      new.article_variant_id,
      'size.became_valid'
    );
  end if;
  return new;
end;
$$;

create trigger member_article_sizes_inventory_transition
after insert or update of
  article_variant_id,
  selection_status,
  confirmed_at
on app.member_article_sizes
for each row execute function private.handle_size_inventory_transition();

revoke all on function private.handle_size_inventory_transition()
from public, anon, authenticated, service_role;

-- Once the feature flag is enabled, no legacy RPC can write around the
-- journal merely because it still exists for rollback compatibility.
create or replace function private.guard_legacy_inventory_mutation()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if private.inventory_v2_enabled()
    and current_setting('app.inventory_internal', true) <> 'on'
  then
    raise exception 'LEGACY_INVENTORY_MUTATION_DISABLED' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger delivery_receipts_v2_guard
before insert or update or delete on app.delivery_receipts
for each row execute function private.guard_legacy_inventory_mutation();
create trigger delivery_receipt_lines_v2_guard
before insert or update or delete on app.delivery_receipt_lines
for each row execute function private.guard_legacy_inventory_mutation();
create trigger inventory_reservations_v2_guard
before insert or update or delete on app.inventory_reservations
for each row execute function private.guard_legacy_inventory_mutation();
create trigger fulfilments_v2_guard
before insert or update or delete on app.fulfilments
for each row execute function private.guard_legacy_inventory_mutation();
create trigger fulfilment_lines_v2_guard
before insert or update or delete on app.fulfilment_lines
for each row execute function private.guard_legacy_inventory_mutation();

revoke all on function private.guard_legacy_inventory_mutation()
from public, anon, authenticated, service_role;

create or replace function app.assign_legacy_inventory_balance(
  p_reconciliation_id uuid,
  p_season_id uuid,
  p_quantity integer,
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
  normalized_reason text;
  candidate private.inventory_legacy_reconciliation%rowtype;
  prior private.inventory_legacy_assignments%rowtype;
  already_assigned integer;
  remaining integer;
  movement_id uuid;
  assignment_id uuid;
  action_key text;
  result jsonb;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_reconciliation_id is null
    or p_season_id is null
    or p_quantity is null
    or p_quantity <= 0
    or p_request_id is null
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'INVENTORY_RECONCILIATION_ASSIGNMENT_INVALID'
      using errcode = '22023';
  end if;

  select * into prior
  from private.inventory_legacy_assignments assignment
  where assignment.request_id = p_request_id;
  if found then
    if prior.reconciliation_id <> p_reconciliation_id
      or prior.season_id <> p_season_id
      or prior.quantity <> p_quantity
      or prior.reason <> normalized_reason
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    select
      candidate.unassigned_quantity
        - coalesce(sum(assignment.quantity), 0)
    into remaining
    from private.inventory_legacy_reconciliation candidate
    left join private.inventory_legacy_assignments assignment
      on assignment.reconciliation_id = candidate.id
    where candidate.id = p_reconciliation_id
    group by candidate.unassigned_quantity;
    return jsonb_build_object(
      'assignmentId', prior.id,
      'reconciliationId', p_reconciliation_id,
      'movementId', prior.movement_id,
      'remainingQuantity', remaining,
      'reused', true
    );
  end if;

  perform private.lock_inventory_mutation();
  select * into candidate
  from private.inventory_legacy_reconciliation reconciliation
  where reconciliation.id = p_reconciliation_id
  for update;
  if not found then
    raise exception 'INVENTORY_RECONCILIATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if candidate.status not in ('pending', 'assigned')
    or candidate.discrepancy_quantity <> 0
  then
    raise exception 'INVENTORY_RECONCILIATION_NOT_ASSIGNABLE'
      using errcode = '23514';
  end if;
  if not exists(
    select 1 from app.seasons season where season.id = p_season_id
  ) then
    raise exception 'INVENTORY_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(sum(assignment.quantity), 0)
  into already_assigned
  from private.inventory_legacy_assignments assignment
  where assignment.reconciliation_id = candidate.id;
  remaining := candidate.unassigned_quantity - already_assigned;
  if p_quantity > remaining then
    raise exception 'INVENTORY_RECONCILIATION_QUANTITY_EXCEEDED'
      using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'inventory-balance:'
        || p_season_id::text
        || ':'
        || candidate.article_variant_id::text,
      0
    )
  );
  insert into app.inventory_movements(
    season_id,
    article_id,
    article_variant_id,
    movement_type,
    on_hand_delta,
    receipt_line_id,
    source_type,
    source_id,
    reason_code,
    idempotency_key,
    actor_user_id,
    correlation_id,
    safe_context
  ) values (
    p_season_id,
    candidate.article_id,
    candidate.article_variant_id,
    'opening_balance',
    p_quantity,
    candidate.receipt_line_id,
    'inventory_reconciliation',
    candidate.id,
    'legacy.inventory_assigned',
    encode(
      extensions.digest(
        'legacy-inventory-assignment:' || p_request_id::text,
        'sha256'
      ),
      'hex'
    ),
    actor,
    p_correlation_id,
    jsonb_build_object(
      'reconciliationCandidateId', candidate.id,
      'receiptLineId', candidate.receipt_line_id,
      'variantId', candidate.article_variant_id,
      'quantity', p_quantity
    )
  )
  returning id into movement_id;

  insert into private.inventory_legacy_assignments(
    reconciliation_id,
    season_id,
    quantity,
    request_id,
    reason,
    actor_user_id,
    movement_id
  ) values (
    candidate.id,
    p_season_id,
    p_quantity,
    p_request_id,
    normalized_reason,
    actor,
    movement_id
  )
  returning id into assignment_id;

  remaining := remaining - p_quantity;
  if remaining = 0 then
    update private.inventory_legacy_reconciliation
    set status = 'assigned',
        reconciled_by = actor,
        reconciled_at = timezone('utc', now())
    where id = candidate.id;
    action_key := encode(
      extensions.digest(
        'legacy-inventory-unassigned:' || candidate.id::text,
        'sha256'
      ),
      'hex'
    );
    perform private.auto_resolve_action_item(
      'legacy_inventory_unassigned',
      candidate.review_season_id,
      action_key,
      'system: volledige openingsvoorraad is aan seizoen(en) toegewezen'
    );
  end if;

  perform private.enqueue_inventory_variant(
    p_season_id,
    candidate.article_variant_id,
    'inventory.opening_assigned'
  );
  perform private.refresh_inventory_variant_actions(
    p_season_id,
    candidate.article_variant_id,
    'inventory_reconciliation',
    candidate.id
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
    'inventory.legacy_balance.assigned',
    'inventory_reconciliation',
    candidate.id,
    jsonb_build_object(
      'seasonId', p_season_id,
      'variantId', candidate.article_variant_id,
      'quantity', p_quantity,
      'remainingQuantity', remaining,
      'movementId', movement_id,
      'reason', normalized_reason
    ),
    p_correlation_id
  );
  result := jsonb_build_object(
    'assignmentId', assignment_id,
    'reconciliationId', candidate.id,
    'movementId', movement_id,
    'remainingQuantity', remaining,
    'reused', false
  );
  return result;
end;
$$;

revoke all on function app.assign_legacy_inventory_balance(
  uuid, uuid, integer, text, uuid, uuid
) from public, anon;
grant execute on function app.assign_legacy_inventory_balance(
  uuid, uuid, integer, text, uuid, uuid
) to authenticated;

create or replace function app.resolve_legacy_inventory_allocation(
  p_allocation_id uuid,
  p_decision text,
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
  normalized_reason text;
  request_hash text;
  prior private.inventory_command_requests%rowtype;
  target app.inventory_allocations%rowtype;
  action_key text;
  result jsonb;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_allocation_id is null
    or p_decision not in ('release_requeue', 'accept_historical')
    or p_request_id is null
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'INVENTORY_ALLOCATION_RECONCILIATION_INVALID'
      using errcode = '22023';
  end if;
  request_hash := encode(
    extensions.digest(
      concat_ws(
        '|',
        'inventory-allocation-reconcile-v1',
        p_allocation_id::text,
        p_decision,
        normalized_reason
      ),
      'sha256'
    ),
    'hex'
  );
  select * into prior
  from private.inventory_command_requests request
  where request.request_id = p_request_id;
  if found then
    if prior.command_type <> 'inventory.allocation.reconcile'
      or prior.target_id <> p_allocation_id
      or prior.request_hash <> request_hash
    then
      raise exception 'INVENTORY_REQUEST_ID_CONFLICT' using errcode = '23505';
    end if;
    return prior.result_snapshot || jsonb_build_object('reused', true);
  end if;

  perform private.lock_inventory_mutation();
  select * into target
  from app.inventory_allocations allocation
  where allocation.id = p_allocation_id
  for update;
  if not found then
    raise exception 'INVENTORY_ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.allocation_mode <> 'legacy_preserved'
    or target.reconciliation_status <> 'review_required'
  then
    raise exception 'INVENTORY_ALLOCATION_NOT_RECONCILABLE'
      using errcode = '23514';
  end if;

  if p_decision = 'release_requeue' then
    if target.status <> 'reserved' then
      raise exception 'INVENTORY_ALLOCATION_RELEASE_DECISION_INVALID'
        using errcode = '23514';
    end if;
    perform private.release_order_inventory_allocations(
      target.order_id,
      normalized_reason,
      actor,
      'inventory_reconciliation',
      target.id,
      p_correlation_id
    );
    perform private.enqueue_inventory_variant(
      target.season_id,
      target.article_variant_id,
      'inventory.reconciliation_requeue'
    );
  else
    if target.status not in ('fulfilled', 'released') then
      raise exception 'INVENTORY_HISTORICAL_ACCEPTANCE_INVALID'
        using errcode = '23514';
    end if;
    perform set_config('app.inventory_internal', 'on', true);
    update app.inventory_allocations
    set reconciliation_status = 'resolved',
        updated_at = timezone('utc', now())
    where id = target.id;
    perform set_config('app.inventory_internal', 'off', true);
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
      safe_context
    ) values (
      target.id,
      'reconciliation_resolved',
      target.status,
      target.status,
      'legacy.allocation_accepted',
      'inventory_reconciliation',
      target.id,
      encode(
        extensions.digest(
          'legacy-allocation-accepted:' || p_request_id::text,
          'sha256'
        ),
        'hex'
      ),
      actor,
      jsonb_build_object(
        'allocationId', target.id,
        'orderItemId', target.order_line_id,
        'variantId', target.article_variant_id,
        'quantity', target.quantity
      )
    );
  end if;

  action_key := encode(
    extensions.digest(
      'legacy-allocation-review:' || target.id::text,
      'sha256'
    ),
    'hex'
  );
  perform private.auto_resolve_action_item(
    'allocation_conflict',
    target.season_id,
    action_key,
    'system: legacyallocatie is door beheer gereconcilieerd'
  );

  result := jsonb_build_object(
    'allocationId', target.id,
    'decision', p_decision,
    'status', case
      when p_decision = 'release_requeue' then 'released'
      else target.status::text
    end,
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
    'inventory.allocation.reconcile',
    target.id,
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
    'inventory.legacy_allocation.reconciled',
    'inventory_allocation',
    target.id,
    jsonb_build_object(
      'decision', p_decision,
      'reason', normalized_reason,
      'orderId', target.order_id,
      'orderLineId', target.order_line_id
    ),
    p_correlation_id
  );
  return result;
end;
$$;

revoke all on function app.resolve_legacy_inventory_allocation(
  uuid, text, text, uuid, uuid
) from public, anon;
grant execute on function app.resolve_legacy_inventory_allocation(
  uuid, text, text, uuid, uuid
) to authenticated;

create or replace function private.inventory_reconciliation_report()
returns jsonb
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  with source_receipts as (
    select
      coalesce(sum(line.received_quantity), 0)::bigint legacy_received
    from app.delivery_receipt_lines line
  ),
  source_reservations as (
    select
      coalesce(sum(reservation.quantity) filter (
        where reservation.status = 'reserved'
      ), 0)::bigint legacy_reserved,
      coalesce(sum(reservation.quantity) filter (
        where reservation.status = 'fulfilled'
      ), 0)::bigint legacy_issued,
      count(*)::integer legacy_reservation_count
    from app.inventory_reservations reservation
  ),
  source as (
    select source_receipts.*, source_reservations.*
    from source_receipts, source_reservations
  ),
  target as (
    select
      coalesce(sum(movement.on_hand_delta), 0)::bigint journal_on_hand,
      coalesce(sum(movement.reserved_delta), 0)::bigint journal_reserved,
      coalesce(sum(movement.issued_delta), 0)::bigint journal_issued
    from app.inventory_movements movement
    where movement.source_type in (
      'inventory_reservation',
      'inventory_reconciliation'
    )
  ),
  blockers as (
    select
      count(*) filter (
        where reconciliation.status = 'pending'
      )::integer pending_candidates,
      count(*) filter (
        where reconciliation.status = 'discrepancy'
      )::integer discrepancy_candidates,
      coalesce(sum(
        reconciliation.unassigned_quantity
        - coalesce(assigned.quantity, 0)
      ) filter (
        where reconciliation.status = 'pending'
      ), 0)::bigint pending_quantity
    from private.inventory_legacy_reconciliation reconciliation
    left join lateral (
      select sum(assignment.quantity)::bigint quantity
      from private.inventory_legacy_assignments assignment
      where assignment.reconciliation_id = reconciliation.id
    ) assigned on true
  ),
  allocation_blockers as (
    select
      count(*) filter (
        where allocation.reconciliation_status = 'review_required'
          and allocation.status in ('reserved', 'fulfilled')
      )::integer review_allocations,
      count(*)::integer mapped_reservations
    from app.inventory_allocations allocation
    where allocation.legacy_reservation_id is not null
  ),
  report as (
    select
      source.*,
      target.*,
      blockers.*,
      allocation_blockers.*,
      (
        blockers.pending_candidates = 0
        and blockers.discrepancy_candidates = 0
        and allocation_blockers.review_allocations = 0
        and allocation_blockers.mapped_reservations
          = source.legacy_reservation_count
        and target.journal_on_hand + target.journal_issued
          = source.legacy_received
        and target.journal_reserved = source.legacy_reserved
        and target.journal_issued = source.legacy_issued
      ) ready
    from source, target, blockers, allocation_blockers
  )
  select jsonb_build_object(
    'legacyReceived', report.legacy_received,
    'legacyReserved', report.legacy_reserved,
    'legacyIssued', report.legacy_issued,
    'legacyReservationCount', report.legacy_reservation_count,
    'journalOnHand', report.journal_on_hand,
    'journalReserved', report.journal_reserved,
    'journalIssued', report.journal_issued,
    'pendingCandidates', report.pending_candidates,
    'pendingQuantity', report.pending_quantity,
    'discrepancyCandidates', report.discrepancy_candidates,
    'reviewAllocations', report.review_allocations,
    'mappedReservations', report.mapped_reservations,
    'ready', report.ready,
    'hash', encode(
      extensions.digest(
        concat_ws(
          '|',
          'inventory-reconciliation-v1',
          report.legacy_received,
          report.legacy_reserved,
          report.legacy_issued,
          report.legacy_reservation_count,
          report.journal_on_hand,
          report.journal_reserved,
          report.journal_issued,
          report.pending_candidates,
          report.pending_quantity,
          report.discrepancy_candidates,
          report.review_allocations,
          report.mapped_reservations,
          report.ready
        ),
        'sha256'
      ),
      'hex'
    )
  )
  from report;
$$;

revoke all on function private.inventory_reconciliation_report()
from public, anon, authenticated, service_role;

create or replace function app.get_inventory_reconciliation_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return jsonb_build_object(
    'report', private.inventory_reconciliation_report(),
    'candidates', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', candidate.id,
          'receiptLineId', candidate.receipt_line_id,
          'variantId', candidate.article_variant_id,
          'productName', article.name,
          'size', variant.size,
          'reviewSeasonId', candidate.review_season_id,
          'legacyReceived', candidate.legacy_received,
          'legacyReserved', candidate.legacy_reserved,
          'legacyIssued', candidate.legacy_issued,
          'unassignedQuantity', candidate.unassigned_quantity,
          'assignedQuantity', coalesce(assigned.quantity, 0),
          'remainingQuantity',
            candidate.unassigned_quantity - coalesce(assigned.quantity, 0),
          'status', candidate.status::text,
          'sourceHash', candidate.source_hash
        )
        order by candidate.created_at, candidate.id
      )
      from private.inventory_legacy_reconciliation candidate
      join app.article_variants variant
        on variant.id = candidate.article_variant_id
      join app.articles article on article.id = variant.article_id
      left join lateral (
        select sum(assignment.quantity)::integer quantity
        from private.inventory_legacy_assignments assignment
        where assignment.reconciliation_id = candidate.id
      ) assigned on true
      where candidate.status in ('pending', 'discrepancy')
    ), '[]'::jsonb),
    'reviewAllocations', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', allocation.id,
          'seasonId', allocation.season_id,
          'orderId', allocation.order_id,
          'orderLineId', allocation.order_line_id,
          'variantId', allocation.article_variant_id,
          'productName', allocation.product_name_snapshot,
          'size', allocation.size_snapshot,
          'quantity', allocation.quantity,
          'status', allocation.status::text,
          'paidAt', allocation.paid_at,
          'sizeValidAt', allocation.size_valid_at,
          'allocatedAt', allocation.allocated_at
        )
        order by allocation.created_at, allocation.id
      )
      from app.inventory_allocations allocation
      where allocation.reconciliation_status = 'review_required'
        and allocation.status in ('reserved', 'fulfilled')
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_inventory_reconciliation_workspace()
from public, anon;
grant execute on function app.get_inventory_reconciliation_workspace()
to authenticated;

create or replace function app.set_inventory_threshold(
  p_season_id uuid,
  p_threshold integer,
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
  normalized_reason text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_season_id is null
    or p_threshold not between 0 and 100000
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'INVENTORY_THRESHOLD_INVALID' using errcode = '22023';
  end if;
  insert into app.inventory_settings(
    season_id,
    low_stock_threshold,
    updated_by,
    updated_at
  ) values (
    p_season_id,
    p_threshold,
    actor,
    timezone('utc', now())
  )
  on conflict (season_id) do update
  set low_stock_threshold = excluded.low_stock_threshold,
      updated_by = excluded.updated_by,
      updated_at = excluded.updated_at;
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'inventory.threshold.updated',
    'season',
    p_season_id,
    jsonb_build_object(
      'threshold', p_threshold,
      'reason', normalized_reason
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'seasonId', p_season_id,
    'lowStockThreshold', p_threshold
  );
end;
$$;

revoke all on function app.set_inventory_threshold(
  uuid, integer, text, uuid
) from public, anon;
grant execute on function app.set_inventory_threshold(
  uuid, integer, text, uuid
) to authenticated;

create or replace function app.get_inventory_workspace(
  p_season_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_season_id uuid;
begin
  perform private.require_clothing_aal2();
  target_season_id := p_season_id;
  if target_season_id is null then
    select settings.active_season_id into target_season_id
    from app.app_settings settings
    where settings.id = true;
  end if;
  if target_season_id is null
    or not exists(
      select 1 from app.seasons season where season.id = target_season_id
    )
  then
    raise exception 'INVENTORY_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'seasonId', target_season_id,
    'enabled', private.inventory_v2_enabled(),
    'role', app.staff_role()::text,
    'lowStockThreshold', coalesce((
      select settings.low_stock_threshold
      from app.inventory_settings settings
      where settings.season_id = target_season_id
    ), 10),
    'seasons', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', season.id,
          'name', season.name,
          'status', season.status::text
        )
        order by season.starts_on desc, season.id
      )
      from app.seasons season
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', article.id,
          'name', article.name,
          'code', article.code,
          'variantCount', (
            select count(*)
            from app.article_variants variant
            where variant.article_id = article.id
              and variant.active
          )
        )
        order by article.sort_order, article.name, article.id
      )
      from app.article_seasons link
      join app.articles article on article.id = link.article_id
      where link.season_id = target_season_id
        and article.active
        and exists(
          select 1
          from app.article_variants variant
          where variant.article_id = article.id
            and variant.active
        )
    ), '[]'::jsonb),
    'variants', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', variant.id,
          'articleId', article.id,
          'article', article.name,
          'size', variant.size,
          'sku', variant.sku,
          'onHand', balance.on_hand,
          'reserved', balance.reserved,
          'issued', balance.issued,
          'available', balance.available,
          'totalOpenDemand', demand.total_open,
          'paidWaiting', demand.paid_waiting,
          'unpaidDemand', demand.unpaid,
          'unconfirmedDemand', demand.unconfirmed,
          'pickedUp', demand.picked_up,
          'shortage', greatest(demand.total_open - balance.on_hand, 0)
        )
        order by article.sort_order, article.name,
          variant.sort_order, variant.size, variant.id
      )
      from app.article_seasons link
      join app.articles article on article.id = link.article_id
      join app.article_variants variant
        on variant.article_id = article.id
        and variant.active
      join lateral private.inventory_balance(
        target_season_id,
        variant.id
      ) balance on true
      left join lateral (
        select
          coalesce(sum(line.quantity) filter (
            where line.status in ('backorder', 'ready_for_pickup')
          ), 0)::bigint total_open,
          coalesce(sum(line.quantity) filter (
            where line.status = 'backorder'
              and paid.is_paid
              and size_state.is_valid
          ), 0)::bigint paid_waiting,
          coalesce(sum(line.quantity) filter (
            where line.status = 'backorder'
              and not paid.is_paid
          ), 0)::bigint unpaid,
          coalesce(sum(line.quantity) filter (
            where line.status = 'backorder'
              and not size_state.is_valid
          ), 0)::bigint unconfirmed,
          coalesce(sum(line.quantity) filter (
            where line.status = 'picked_up'
          ), 0)::bigint picked_up
        from app.order_lines line
        join app.member_orders orders on orders.id = line.order_id
        left join lateral (
          select exists(
            select 1
            from app.payments payment
            where payment.order_id = orders.id
              and payment.status = 'paid'
              and payment.reconciliation_issue is null
          ) is_paid
        ) paid on true
        left join lateral (
          select exists(
            select 1
            from app.member_article_sizes size_profile
            where size_profile.member_season_id = orders.member_season_id
              and size_profile.article_id = line.article_id
              and size_profile.article_variant_id = line.article_variant_id
              and size_profile.selection_status in ('confirmed', 'locked')
              and size_profile.confirmed_at is not null
          ) is_valid
        ) size_state on true
        where orders.season_id = target_season_id
          and line.article_variant_id = variant.id
      ) demand on true
      where link.season_id = target_season_id
        and article.active
    ), '[]'::jsonb),
    'drafts', coalesce((
      select jsonb_agg(
        private.inventory_delivery_draft_json(draft.id)
        order by draft.updated_at desc, draft.id
      )
      from app.inventory_delivery_drafts draft
      where draft.season_id = target_season_id
        and draft.status <> 'cancelled'
    ), '[]'::jsonb),
    'waitlist', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'orderLineId', line.id,
          'orderId', orders.id,
          'memberName', concat_ws(
            ' ',
            member.first_name,
            member.insertion,
            member.last_name
          ),
          'relationNumber', member.relation_number,
          'team', member_season.team_name,
          'variantId', line.article_variant_id,
          'quantity', line.quantity,
          'paid', paid.paid_at is not null,
          'sizeValid', size_profile.confirmed_at is not null,
          'fifoAt', case
            when paid.paid_at is not null
              and size_profile.confirmed_at is not null
            then greatest(paid.paid_at, size_profile.confirmed_at)
            else null
          end,
          'eligible',
            paid.paid_at is not null
            and size_profile.confirmed_at is not null,
          'createdAt', line.created_at
        )
        order by
          case
            when paid.paid_at is not null
              and size_profile.confirmed_at is not null
            then 0
            else 1
          end,
          greatest(paid.paid_at, size_profile.confirmed_at),
          line.created_at,
          line.id
      )
      from app.order_lines line
      join app.member_orders orders on orders.id = line.order_id
      join app.member_seasons member_season
        on member_season.id = orders.member_season_id
      join app.members member on member.id = orders.member_id
      left join lateral (
        select payment.paid_at
        from app.payments payment
        where payment.order_id = orders.id
          and payment.status = 'paid'
          and payment.reconciliation_issue is null
        order by payment.paid_at, payment.created_at, payment.id
        limit 1
      ) paid on true
      left join lateral (
        select size.confirmed_at
        from app.member_article_sizes size
        where size.member_season_id = orders.member_season_id
          and size.article_id = line.article_id
          and size.article_variant_id = line.article_variant_id
          and size.selection_status in ('confirmed', 'locked')
          and size.confirmed_at is not null
        limit 1
      ) size_profile on true
      where orders.season_id = target_season_id
        and line.status = 'backorder'
    ), '[]'::jsonb),
    'reconciliation', jsonb_build_object(
      'pendingCandidates', (
        select count(*)
        from private.inventory_legacy_reconciliation candidate
        where candidate.status = 'pending'
      ),
      'reviewAllocations', (
        select count(*)
        from app.inventory_allocations allocation
        where allocation.reconciliation_status = 'review_required'
          and allocation.status in ('reserved', 'fulfilled')
      )
    )
  );
end;
$$;

revoke all on function app.get_inventory_workspace(uuid)
from public, anon;
grant execute on function app.get_inventory_workspace(uuid)
to authenticated;

alter table private.operation_runs
  drop constraint operation_runs_operation_check;
alter table private.operation_runs
  add constraint operation_runs_operation_check check (
    operation in (
      'email_worker',
      'retention',
      'import_worker',
      'inventory_allocator'
    )
  );

create or replace function app.start_operation_run(
  p_operation text,
  p_run_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  started timestamptz := timezone('utc', now());
begin
  if p_run_id is null
    or p_operation not in (
      'email_worker',
      'retention',
      'import_worker',
      'inventory_allocator'
    )
  then
    raise exception 'INVALID_OPERATION_RUN' using errcode = '22023';
  end if;

  insert into private.operation_runs(id, operation, status, started_at)
  values(p_run_id, p_operation, 'running', started);

  return jsonb_build_object(
    'runId', p_run_id,
    'operation', p_operation,
    'startedAt', started
  );
exception when unique_violation then
  raise exception 'OPERATION_RUN_CONFLICT' using errcode = '23505';
end;
$$;
