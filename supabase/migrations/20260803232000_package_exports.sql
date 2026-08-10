-- First-class package exports.
--
-- Package reports are based on the active immutable commercial snapshot.
-- Issued product names and sizes come from fulfilment snapshots, never from
-- the mutable live catalogue.

alter function private.build_export_rows(text, uuid, text)
  rename to build_export_rows_legacy_20260718;

create or replace function private.export_effective_payment_status(p_order_id uuid)
returns text
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select coalesce((
    select payment.status::text
    from app.member_orders orders
    join app.payments payment
      on payment.order_id = orders.id
      and payment.package_snapshot_id = orders.active_package_snapshot_id
    where orders.id = p_order_id
    order by case payment.status
      when 'paid' then 1
      when 'refunded' then 2
      when 'duplicate_paid' then 3
      when 'pending' then 4
      when 'open' then 5
      else 6
    end, payment.created_at desc, payment.id desc
    limit 1
  ), 'open');
$$;

create or replace function private.build_export_rows(
  p_type text,
  p_season_id uuid,
  p_filter text
)
returns table(row_data jsonb)
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  if p_type = 'package_orders' then
    return query
    select jsonb_build_object(
      'relationNumber', member.relation_number,
      'member', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'team', member_season.team_name,
      'season', season.name,
      'order', orders.id::text,
      'packageName', snapshot.package_name,
      'packageRevision', snapshot.revision_label,
      'packagePriceCents', snapshot.package_price_cents,
      'currency', snapshot.currency,
      'snapshotOrigin', snapshot.snapshot_origin,
      'paymentStatus', effective.status,
      'orderStatus', orders.order_status,
      'componentCount', coalesce(components.component_count, 0),
      'sizeMissingCount', coalesce(components.size_missing_count, 0),
      'backorderQuantity', coalesce(lines.backorder_quantity, 0),
      'readyForPickupQuantity', coalesce(lines.ready_quantity, 0),
      'pickedUpQuantity', coalesce(lines.picked_up_quantity, 0)
    )
    from app.member_orders orders
    join app.members member on member.id = orders.member_id
    join app.member_seasons member_season
      on member_season.id = orders.member_season_id
      and member_season.season_id = orders.season_id
    join app.seasons season on season.id = orders.season_id
    join app.order_package_snapshots snapshot
      on snapshot.id = orders.active_package_snapshot_id
      and snapshot.order_id = orders.id
    cross join lateral (
      select private.export_effective_payment_status(orders.id) status
    ) effective
    left join lateral (
      select
        count(*)::integer component_count,
        count(*) filter (
          where not exists(
            select 1
            from app.order_lines item_line
            where item_line.order_id = orders.id
              and item_line.status <> 'cancelled'
              and (
                item_line.id = snapshot_item.order_line_id
                or (
                  snapshot_item.order_line_id is null
                  and snapshot_item.template_item_id is not null
                  and item_line.package_template_item_id = snapshot_item.template_item_id
                )
              )
          )
        )::integer size_missing_count
      from app.order_package_snapshot_items snapshot_item
      where snapshot_item.snapshot_id = snapshot.id
    ) components on true
    left join lateral (
      select
        coalesce(sum(line.quantity) filter (
          where line.status = 'backorder'
        ), 0)::integer backorder_quantity,
        coalesce(sum(line.quantity) filter (
          where line.status = 'ready_for_pickup'
        ), 0)::integer ready_quantity,
        coalesce(sum(line.quantity) filter (
          where line.status = 'picked_up'
        ), 0)::integer picked_up_quantity
      from app.order_lines line
      where line.order_id = orders.id
    ) lines on true
    where (p_season_id is null or orders.season_id = p_season_id)
      and (
        p_filter = 'all'
        or (p_filter = 'unpaid' and effective.status <> 'paid')
        or (p_filter = 'paid' and effective.status = 'paid')
        or (p_filter = 'size_missing' and coalesce(components.size_missing_count, 0) > 0)
        or (p_filter = 'backorder' and coalesce(lines.backorder_quantity, 0) > 0)
        or (p_filter = 'ready_for_pickup' and coalesce(lines.ready_quantity, 0) > 0)
        or (p_filter = 'picked_up' and coalesce(lines.picked_up_quantity, 0) > 0)
        or p_filter = snapshot.snapshot_origin
      )
    order by season.name, member.relation_number, orders.id;

  elsif p_type = 'package_items' then
    return query
    select jsonb_build_object(
      'relationNumber', member.relation_number,
      'member', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'team', member_season.team_name,
      'season', season.name,
      'order', orders.id::text,
      'packageName', snapshot.package_name,
      'packageRevision', snapshot.revision_label,
      'productName', snapshot_item.product_name_snapshot,
      'productCode', snapshot_item.product_code_snapshot,
      'quantity', snapshot_item.quantity,
      'selectedSize', case
        when selected_line.status = 'cancelled' then null
        else coalesce(selected_line.size_snapshot, snapshot_item.size_snapshot)
      end,
      'lineStatus', coalesce(selected_line.status::text, 'size_missing'),
      'issuedQuantity', coalesce(issued.issued_quantity, 0),
      'issuedSizes', issued.issued_sizes,
      'paymentStatus', effective.status
    )
    from app.member_orders orders
    join app.members member on member.id = orders.member_id
    join app.member_seasons member_season
      on member_season.id = orders.member_season_id
      and member_season.season_id = orders.season_id
    join app.seasons season on season.id = orders.season_id
    join app.order_package_snapshots snapshot
      on snapshot.id = orders.active_package_snapshot_id
      and snapshot.order_id = orders.id
    join app.order_package_snapshot_items snapshot_item
      on snapshot_item.snapshot_id = snapshot.id
    cross join lateral (
      select private.export_effective_payment_status(orders.id) status
    ) effective
    left join lateral (
      select line.*
      from app.order_lines line
      where line.order_id = orders.id
        and (
          line.id = snapshot_item.order_line_id
          or (
            snapshot_item.order_line_id is null
            and snapshot_item.template_item_id is not null
            and line.package_template_item_id = snapshot_item.template_item_id
          )
        )
      order by
        (line.status <> 'cancelled') desc,
        line.created_at desc,
        line.id desc
      limit 1
    ) selected_line on true
    left join lateral (
      select
        coalesce(sum(fulfilment_line.quantity), 0)::integer issued_quantity,
        string_agg(
          distinct fulfilment_line.size_snapshot,
          ', ' order by fulfilment_line.size_snapshot
        ) issued_sizes
      from app.fulfilment_lines fulfilment_line
      join app.fulfilments fulfilment
        on fulfilment.id = fulfilment_line.fulfilment_id
      where fulfilment_line.order_line_id = selected_line.id
        and fulfilment_line.reversed_at is null
        and fulfilment.reversed_at is null
    ) issued on true
    where (p_season_id is null or orders.season_id = p_season_id)
      and (
        p_filter = 'all'
        or (
          p_filter = 'size_missing'
          and (
            selected_line.id is null
            or selected_line.status = 'cancelled'
          )
        )
        or p_filter = selected_line.status::text
        or (p_filter = 'issued' and coalesce(issued.issued_quantity, 0) > 0)
      )
    order by
      season.name,
      member.relation_number,
      snapshot_item.sort_order,
      lower(snapshot_item.product_name_snapshot),
      snapshot_item.id;

  elsif p_type = 'fulfilments' then
    return query
    select jsonb_build_object(
      'member', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'line', fulfilment_line.order_line_id::text,
      'article', fulfilment_line.product_name_snapshot,
      'size', fulfilment_line.size_snapshot,
      'date', to_char(
        fulfilment_line.created_at at time zone 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'actorRole', staff.role::text,
      'actor', staff.display_name,
      'correctionStatus', case
        when fulfilment_line.reversed_at is not null
          or fulfilment.reversed_at is not null
          then 'reversed'
        when fulfilment.corrected_at is not null then 'corrected'
        else 'active'
      end
    )
    from app.fulfilment_lines fulfilment_line
    join app.fulfilments fulfilment
      on fulfilment.id = fulfilment_line.fulfilment_id
    join app.member_orders orders on orders.id = fulfilment.order_id
    join app.members member on member.id = orders.member_id
    left join app.staff_profiles staff
      on staff.auth_user_id = fulfilment.actor_user_id
    where (p_season_id is null or orders.season_id = p_season_id)
      and (
        p_filter = 'all'
        or (
          p_filter = 'active'
          and fulfilment_line.reversed_at is null
          and fulfilment.reversed_at is null
          and fulfilment.corrected_at is null
        )
        or (
          p_filter = 'corrected'
          and fulfilment.corrected_at is not null
          and fulfilment_line.reversed_at is null
          and fulfilment.reversed_at is null
        )
        or (
          p_filter = 'reversed'
          and (
            fulfilment_line.reversed_at is not null
            or fulfilment.reversed_at is not null
          )
        )
      )
    order by fulfilment_line.created_at, fulfilment_line.id;

  else
    return query
    select legacy.row_data
    from private.build_export_rows_legacy_20260718(
      p_type,
      p_season_id,
      p_filter
    ) legacy;
  end if;
end;
$$;

create or replace function app.get_export_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'types', array[
      'members',
      'orders',
      'package_orders',
      'package_items',
      'payments',
      'deliveries',
      'fulfilments',
      'outstanding'
    ],
    'seasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', season.id,
        'name', season.name,
        'active', settings.active_season_id = season.id
      ) order by
        (settings.active_season_id = season.id) desc,
        season.starts_on desc nulls last,
        season.name
      )
      from app.seasons season
      cross join app.app_settings settings
      where settings.id = true
    ), '[]'::jsonb),
    'filters', jsonb_build_object(
      'members', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alle leden'),
        jsonb_build_object('value', 'active', 'label', 'Actieve leden'),
        jsonb_build_object('value', 'inactive', 'label', 'Inactieve leden'),
        jsonb_build_object('value', 'linked', 'label', 'Met gekoppelde ouder'),
        jsonb_build_object('value', 'unlinked', 'label', 'Zonder gekoppelde ouder')),
      'orders', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alle bestellingen'),
        jsonb_build_object('value', 'unpaid', 'label', 'Niet betaald'),
        jsonb_build_object('value', 'paid', 'label', 'Betaald'),
        jsonb_build_object('value', 'backorder', 'label', 'Met nalevering'),
        jsonb_build_object('value', 'ready_for_pickup', 'label', 'Af te halen'),
        jsonb_build_object('value', 'picked_up', 'label', 'Deels of geheel afgehaald')),
      'package_orders', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alle pakketorders'),
        jsonb_build_object('value', 'unpaid', 'label', 'Niet betaald'),
        jsonb_build_object('value', 'paid', 'label', 'Betaald'),
        jsonb_build_object('value', 'size_missing', 'label', 'Met ontbrekende maat'),
        jsonb_build_object('value', 'backorder', 'label', 'Met nalevering'),
        jsonb_build_object('value', 'ready_for_pickup', 'label', 'Af te halen'),
        jsonb_build_object('value', 'picked_up', 'label', 'Deels of geheel afgehaald'),
        jsonb_build_object('value', 'legacy', 'label', 'Legacy pakketten'),
        jsonb_build_object('value', 'template', 'label', 'Pakketten uit template'),
        jsonb_build_object('value', 'admin_change', 'label', 'Beheerwijzigingen')),
      'package_items', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alle pakketonderdelen'),
        jsonb_build_object('value', 'size_missing', 'label', 'Maat ontbreekt of conflicteert'),
        jsonb_build_object('value', 'backorder', 'label', 'Nalevering'),
        jsonb_build_object('value', 'ready_for_pickup', 'label', 'Af te halen'),
        jsonb_build_object('value', 'picked_up', 'label', 'Afgehaald'),
        jsonb_build_object('value', 'issued', 'label', 'Met uitgifte')),
      'payments', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alle betalingen'),
        jsonb_build_object('value', 'open', 'label', 'Open'),
        jsonb_build_object('value', 'pending', 'label', 'In behandeling'),
        jsonb_build_object('value', 'paid', 'label', 'Betaald'),
        jsonb_build_object('value', 'failed', 'label', 'Mislukt'),
        jsonb_build_object('value', 'canceled', 'label', 'Geannuleerd'),
        jsonb_build_object('value', 'expired', 'label', 'Verlopen'),
        jsonb_build_object('value', 'refunded', 'label', 'Terugbetaald'),
        jsonb_build_object('value', 'duplicate_paid', 'label', 'Dubbel betaald'),
        jsonb_build_object('value', 'mollie', 'label', 'Mollie'),
        jsonb_build_object('value', 'cash', 'label', 'Kas'),
        jsonb_build_object('value', 'card', 'label', 'Pin')),
      'deliveries', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alle leveringen'),
        jsonb_build_object('value', 'available', 'label', 'Met beschikbare voorraad'),
        jsonb_build_object('value', 'fully_allocated', 'label', 'Volledig gereserveerd')),
      'fulfilments', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alle uitgiftes'),
        jsonb_build_object('value', 'active', 'label', 'Actief'),
        jsonb_build_object('value', 'corrected', 'label', 'Gecorrigeerd'),
        jsonb_build_object('value', 'reversed', 'label', 'Teruggedraaid')),
      'outstanding', jsonb_build_array(
        jsonb_build_object('value', 'all', 'label', 'Alles openstaand'),
        jsonb_build_object('value', 'unpaid', 'label', 'Niet betaald'),
        jsonb_build_object('value', 'backorder', 'label', 'Naleveringen'),
        jsonb_build_object('value', 'ready_for_pickup', 'label', 'Nog af te halen'))
    )
  );
end;
$$;

create or replace function app.create_export(
  p_type text,
  p_season_id uuid,
  p_filter text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  season_name text;
  columns jsonb;
  rows jsonb;
  row_count integer;
  now_utc timestamptz := timezone('utc', now());
  allowed_filters text[];
  rate_key text;
  safe_filter text := coalesce(nullif(trim(p_filter), ''), 'all');
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  if p_type is null or p_type <> all(array[
    'members',
    'orders',
    'package_orders',
    'package_items',
    'payments',
    'deliveries',
    'fulfilments',
    'outstanding'
  ]) then
    raise exception 'INVALID_EXPORT_TYPE' using errcode = '22023';
  end if;

  allowed_filters := case p_type
    when 'members' then
      array['all', 'active', 'inactive', 'linked', 'unlinked']
    when 'orders' then
      array['all', 'unpaid', 'paid', 'backorder', 'ready_for_pickup', 'picked_up']
    when 'package_orders' then
      array[
        'all',
        'unpaid',
        'paid',
        'size_missing',
        'backorder',
        'ready_for_pickup',
        'picked_up',
        'legacy',
        'template',
        'admin_change'
      ]
    when 'package_items' then
      array[
        'all',
        'size_missing',
        'backorder',
        'ready_for_pickup',
        'picked_up',
        'issued'
      ]
    when 'payments' then
      array[
        'all',
        'open',
        'pending',
        'paid',
        'failed',
        'canceled',
        'expired',
        'refunded',
        'duplicate_paid',
        'mollie',
        'cash',
        'card'
      ]
    when 'deliveries' then
      array['all', 'available', 'fully_allocated']
    when 'fulfilments' then
      array['all', 'active', 'corrected', 'reversed']
    when 'outstanding' then
      array['all', 'unpaid', 'backorder', 'ready_for_pickup']
  end;
  if not (safe_filter = any(allowed_filters)) then
    raise exception 'INVALID_EXPORT_FILTER' using errcode = '22023';
  end if;
  if p_season_id is null then
    raise exception 'EXPORT_SEASON_REQUIRED' using errcode = '22023';
  end if;

  select season.name into season_name
  from app.seasons season
  where season.id = p_season_id;
  if season_name is null then
    raise exception 'EXPORT_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  rate_key := encode(
    extensions.digest(actor::text || ':' || p_type, 'sha256'),
    'hex'
  );
  if not app.consume_rate_limit('export', rate_key, 20, 60) then
    raise exception 'EXPORT_RATE_LIMITED' using errcode = 'P0001';
  end if;

  columns := case p_type
    when 'members' then jsonb_build_array(
      jsonb_build_object('key', 'relationNumber', 'label', 'Relatienummer'),
      jsonb_build_object('key', 'name', 'label', 'Naam'),
      jsonb_build_object('key', 'team', 'label', 'Team'),
      jsonb_build_object('key', 'email', 'label', 'E-mail'),
      jsonb_build_object('key', 'active', 'label', 'Actief'),
      jsonb_build_object('key', 'parentLinked', 'label', 'Gekoppelde ouderstatus'))
    when 'orders' then jsonb_build_array(
      jsonb_build_object('key', 'member', 'label', 'Lid'),
      jsonb_build_object('key', 'season', 'label', 'Seizoen'),
      jsonb_build_object('key', 'amountCents', 'label', 'Bedrag (centen)'),
      jsonb_build_object('key', 'paymentStatus', 'label', 'Betaalstatus'),
      jsonb_build_object('key', 'orderStatus', 'label', 'Orderstatus'),
      jsonb_build_object('key', 'backorderQuantity', 'label', 'Aantal nalevering'),
      jsonb_build_object('key', 'readyForPickupQuantity', 'label', 'Aantal af te halen'),
      jsonb_build_object('key', 'pickedUpQuantity', 'label', 'Aantal afgehaald'),
      jsonb_build_object('key', 'cancelledQuantity', 'label', 'Aantal geannuleerd'))
    when 'package_orders' then jsonb_build_array(
      jsonb_build_object('key', 'relationNumber', 'label', 'Relatienummer'),
      jsonb_build_object('key', 'member', 'label', 'Lid'),
      jsonb_build_object('key', 'team', 'label', 'Team'),
      jsonb_build_object('key', 'season', 'label', 'Seizoen'),
      jsonb_build_object('key', 'order', 'label', 'Order'),
      jsonb_build_object('key', 'packageName', 'label', 'Pakket'),
      jsonb_build_object('key', 'packageRevision', 'label', 'Pakketrevisie'),
      jsonb_build_object('key', 'packagePriceCents', 'label', 'Pakketprijs (centen)'),
      jsonb_build_object('key', 'currency', 'label', 'Valuta'),
      jsonb_build_object('key', 'snapshotOrigin', 'label', 'Snapshotbron'),
      jsonb_build_object('key', 'paymentStatus', 'label', 'Betaalstatus'),
      jsonb_build_object('key', 'orderStatus', 'label', 'Orderstatus'),
      jsonb_build_object('key', 'componentCount', 'label', 'Pakketonderdelen'),
      jsonb_build_object('key', 'sizeMissingCount', 'label', 'Ontbrekende maten'),
      jsonb_build_object('key', 'backorderQuantity', 'label', 'Aantal nalevering'),
      jsonb_build_object('key', 'readyForPickupQuantity', 'label', 'Aantal af te halen'),
      jsonb_build_object('key', 'pickedUpQuantity', 'label', 'Aantal afgehaald'))
    when 'package_items' then jsonb_build_array(
      jsonb_build_object('key', 'relationNumber', 'label', 'Relatienummer'),
      jsonb_build_object('key', 'member', 'label', 'Lid'),
      jsonb_build_object('key', 'team', 'label', 'Team'),
      jsonb_build_object('key', 'season', 'label', 'Seizoen'),
      jsonb_build_object('key', 'order', 'label', 'Order'),
      jsonb_build_object('key', 'packageName', 'label', 'Pakket'),
      jsonb_build_object('key', 'packageRevision', 'label', 'Pakketrevisie'),
      jsonb_build_object('key', 'productName', 'label', 'Product'),
      jsonb_build_object('key', 'productCode', 'label', 'Productcode'),
      jsonb_build_object('key', 'quantity', 'label', 'Pakketaantal'),
      jsonb_build_object('key', 'selectedSize', 'label', 'Gekozen maat'),
      jsonb_build_object('key', 'lineStatus', 'label', 'Regelstatus'),
      jsonb_build_object('key', 'issuedQuantity', 'label', 'Uitgegeven aantal'),
      jsonb_build_object('key', 'issuedSizes', 'label', 'Uitgegeven maten'),
      jsonb_build_object('key', 'paymentStatus', 'label', 'Betaalstatus'))
    when 'payments' then jsonb_build_array(
      jsonb_build_object('key', 'order', 'label', 'Order'),
      jsonb_build_object('key', 'member', 'label', 'Lid'),
      jsonb_build_object('key', 'amountCents', 'label', 'Bedrag (centen)'),
      jsonb_build_object('key', 'method', 'label', 'Methode'),
      jsonb_build_object('key', 'status', 'label', 'Status'),
      jsonb_build_object('key', 'reference', 'label', 'Referentie'),
      jsonb_build_object('key', 'date', 'label', 'Datum'),
      jsonb_build_object('key', 'actor', 'label', 'Actor'))
    when 'deliveries' then jsonb_build_array(
      jsonb_build_object('key', 'delivery', 'label', 'Levering'),
      jsonb_build_object('key', 'date', 'label', 'Datum'),
      jsonb_build_object('key', 'variant', 'label', 'Variant'),
      jsonb_build_object('key', 'received', 'label', 'Ontvangen'),
      jsonb_build_object('key', 'reserved', 'label', 'Gereserveerd'),
      jsonb_build_object('key', 'available', 'label', 'Beschikbaar'))
    when 'fulfilments' then jsonb_build_array(
      jsonb_build_object('key', 'member', 'label', 'Lid'),
      jsonb_build_object('key', 'line', 'label', 'Regel'),
      jsonb_build_object('key', 'article', 'label', 'Artikel'),
      jsonb_build_object('key', 'size', 'label', 'Maat'),
      jsonb_build_object('key', 'date', 'label', 'Datum'),
      jsonb_build_object('key', 'actorRole', 'label', 'Uitgifterol'),
      jsonb_build_object('key', 'actor', 'label', 'Account'),
      jsonb_build_object('key', 'correctionStatus', 'label', 'Correctiestatus'))
    when 'outstanding' then jsonb_build_array(
      jsonb_build_object('key', 'member', 'label', 'Lid'),
      jsonb_build_object('key', 'relationNumber', 'label', 'Relatienummer'),
      jsonb_build_object('key', 'season', 'label', 'Seizoen'),
      jsonb_build_object('key', 'order', 'label', 'Order'),
      jsonb_build_object('key', 'category', 'label', 'Openstaand type'),
      jsonb_build_object('key', 'article', 'label', 'Artikel'),
      jsonb_build_object('key', 'size', 'label', 'Maat'),
      jsonb_build_object('key', 'quantity', 'label', 'Aantal'),
      jsonb_build_object('key', 'paymentStatus', 'label', 'Betaalstatus'),
      jsonb_build_object('key', 'lineStatus', 'label', 'Regelstatus'))
  end;

  select count(*), coalesce(jsonb_agg(source.row_data), '[]'::jsonb)
  into row_count, rows
  from (
    select generated.row_data
    from private.build_export_rows(
      p_type,
      p_season_id,
      safe_filter
    ) generated
    limit 10001
  ) source;

  if row_count > 10000 then
    raise exception 'EXPORT_CAPACITY_EXCEEDED' using errcode = '54000';
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    metadata
  )
  values(
    actor,
    'export.created',
    'export',
    jsonb_build_object(
      'type', p_type,
      'season', p_season_id,
      'filter', safe_filter,
      'row_count', row_count
    )
  );

  return jsonb_build_object(
    'type', p_type,
    'seasonName', season_name,
    'generatedAt', to_char(
      now_utc at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
    ),
    'columns', columns,
    'rows', rows
  );
end;
$$;

revoke all on function private.build_export_rows_legacy_20260718(text, uuid, text)
from public, anon, authenticated, service_role;
revoke all on function private.export_effective_payment_status(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.build_export_rows(text, uuid, text)
from public, anon, authenticated, service_role;

revoke all on function app.get_export_workspace() from public, anon;
revoke all on function app.create_export(text, uuid, text) from public, anon;
grant execute on function app.get_export_workspace() to authenticated;
grant execute on function app.create_export(text, uuid, text) to authenticated;
