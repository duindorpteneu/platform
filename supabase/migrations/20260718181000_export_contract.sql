create or replace function private.export_effective_payment_status(p_order_id uuid)
returns text
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select coalesce((
    select payment.status::text
    from app.payments payment
    where payment.order_id = p_order_id
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
  if p_type = 'members' then
    return query
    select jsonb_build_object(
      'relationNumber', member.relation_number,
      'name', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'team', member.team,
      'email', member.email,
      'active', member.active_for_season,
      'parentLinked', exists(
        select 1 from private.parent_member_links link
        where link.member_id = member.id and link.unlinked_at is null
      )
    )
    from app.members member
    where (p_season_id is null or exists(
      select 1 from app.member_orders orders
      where orders.member_id = member.id and orders.season_id = p_season_id
    ))
      and (p_filter = 'all'
        or (p_filter = 'active' and member.active_for_season)
        or (p_filter = 'inactive' and not member.active_for_season)
        or (p_filter = 'linked' and exists(
          select 1 from private.parent_member_links link
          where link.member_id = member.id and link.unlinked_at is null
        ))
        or (p_filter = 'unlinked' and not exists(
          select 1 from private.parent_member_links link
          where link.member_id = member.id and link.unlinked_at is null
        )))
    order by member.relation_number, member.id;

  elsif p_type = 'orders' then
    return query
    select jsonb_build_object(
      'member', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'season', season.name,
      'amountCents', orders.amount_due_cents,
      'paymentStatus', effective.status,
      'orderStatus', orders.order_status,
      'backorderQuantity', coalesce(lines.backorder_quantity, 0),
      'readyForPickupQuantity', coalesce(lines.ready_quantity, 0),
      'pickedUpQuantity', coalesce(lines.picked_up_quantity, 0),
      'cancelledQuantity', coalesce(lines.cancelled_quantity, 0)
    )
    from app.member_orders orders
    join app.members member on member.id = orders.member_id
    join app.seasons season on season.id = orders.season_id
    cross join lateral (
      select private.export_effective_payment_status(orders.id) status
    ) effective
    left join lateral (
      select
        coalesce(sum(line.quantity) filter (where line.status = 'backorder'), 0)::integer backorder_quantity,
        coalesce(sum(line.quantity) filter (where line.status = 'ready_for_pickup'), 0)::integer ready_quantity,
        coalesce(sum(line.quantity) filter (where line.status = 'picked_up'), 0)::integer picked_up_quantity,
        coalesce(sum(line.quantity) filter (where line.status = 'cancelled'), 0)::integer cancelled_quantity
      from app.order_lines line where line.order_id = orders.id
    ) lines on true
    where (p_season_id is null or orders.season_id = p_season_id)
      and (p_filter = 'all'
        or (p_filter = 'unpaid' and effective.status <> 'paid')
        or (p_filter = 'paid' and effective.status = 'paid')
        or (p_filter = 'backorder' and coalesce(lines.backorder_quantity, 0) > 0)
        or (p_filter = 'ready_for_pickup' and coalesce(lines.ready_quantity, 0) > 0)
        or (p_filter = 'picked_up' and coalesce(lines.picked_up_quantity, 0) > 0))
    order by season.name, member.relation_number, orders.id;

  elsif p_type = 'payments' then
    return query
    select jsonb_build_object(
      'order', payment.order_id::text,
      'member', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'amountCents', payment.amount_cents,
      'method', payment.method::text,
      'status', payment.status::text,
      'reference', coalesce(payment.provider_payment_id, payment.id::text),
      'date', to_char(coalesce(payment.paid_at, payment.created_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'actor', coalesce(actor.display_name, case when payment.method = 'mollie' then 'Mollie' else null end)
    )
    from app.payments payment
    join app.member_orders orders on orders.id = payment.order_id
    join app.members member on member.id = orders.member_id
    left join lateral (
      select staff.display_name
      from app.audit_logs audit
      left join app.staff_profiles staff on staff.auth_user_id = audit.actor_user_id
      where audit.action = 'payment.manual.recorded'
        and audit.metadata->>'payment_id' = payment.id::text
      order by audit.created_at desc, audit.id desc
      limit 1
    ) actor on true
    where (p_season_id is null or orders.season_id = p_season_id)
      and (p_filter = 'all'
        or p_filter = payment.status::text
        or p_filter = payment.method::text)
    order by coalesce(payment.paid_at, payment.created_at), payment.id;

  elsif p_type = 'deliveries' then
    return query
    select jsonb_build_object(
      'delivery', coalesce(receipt.packing_slip_reference, receipt.id::text),
      'date', receipt.received_on::text,
      'variant', article.name || ' — ' || variant.size,
      'received', receipt_line.received_quantity,
      'reserved', coalesce(stock.reserved_quantity, 0),
      'available', receipt_line.received_quantity - coalesce(stock.reserved_quantity, 0)
    )
    from app.delivery_receipt_lines receipt_line
    join app.delivery_receipts receipt on receipt.id = receipt_line.receipt_id
    join app.article_variants variant on variant.id = receipt_line.article_variant_id
    join app.articles article on article.id = variant.article_id
    left join lateral (
      select coalesce(sum(reservation.quantity) filter (
        where reservation.status in ('reserved', 'fulfilled')
      ), 0)::integer reserved_quantity
      from app.inventory_reservations reservation
      where reservation.receipt_line_id = receipt_line.id
    ) stock on true
    where (p_season_id is null or exists(
      select 1
      from app.inventory_reservations reservation
      join app.order_lines line on line.id = reservation.order_line_id
      join app.member_orders orders on orders.id = line.order_id
      where reservation.receipt_line_id = receipt_line.id
        and orders.season_id = p_season_id
    ))
      and (p_filter = 'all'
        or (p_filter = 'available' and receipt_line.received_quantity - coalesce(stock.reserved_quantity, 0) > 0)
        or (p_filter = 'fully_allocated' and receipt_line.received_quantity - coalesce(stock.reserved_quantity, 0) <= 0))
    order by receipt.received_on, receipt.id, article.sort_order, variant.sort_order, variant.id;

  elsif p_type = 'fulfilments' then
    return query
    select jsonb_build_object(
      'member', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'line', fulfilment_line.order_line_id::text,
      'article', article.name,
      'size', order_line.size_snapshot,
      'date', to_char(fulfilment_line.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'actorRole', staff.role::text,
      'actor', staff.display_name,
      'correctionStatus', case
        when fulfilment_line.reversed_at is not null or fulfilment.reversed_at is not null then 'reversed'
        when fulfilment.corrected_at is not null then 'corrected'
        else 'active'
      end
    )
    from app.fulfilment_lines fulfilment_line
    join app.fulfilments fulfilment on fulfilment.id = fulfilment_line.fulfilment_id
    join app.member_orders orders on orders.id = fulfilment.order_id
    join app.members member on member.id = orders.member_id
    join app.order_lines order_line on order_line.id = fulfilment_line.order_line_id
    join app.articles article on article.id = order_line.article_id
    left join app.staff_profiles staff on staff.auth_user_id = fulfilment.actor_user_id
    where (p_season_id is null or orders.season_id = p_season_id)
      and (p_filter = 'all'
        or (p_filter = 'active' and fulfilment_line.reversed_at is null and fulfilment.reversed_at is null and fulfilment.corrected_at is null)
        or (p_filter = 'corrected' and fulfilment.corrected_at is not null
          and fulfilment_line.reversed_at is null and fulfilment.reversed_at is null)
        or (p_filter = 'reversed' and (fulfilment_line.reversed_at is not null or fulfilment.reversed_at is not null)))
    order by fulfilment_line.created_at, fulfilment_line.id;

  elsif p_type = 'outstanding' then
    return query
    with effective_orders as (
      select orders.*, member.relation_number,
        concat_ws(' ', member.first_name, member.insertion, member.last_name) member_name,
        season.name season_name,
        private.export_effective_payment_status(orders.id) payment_status
      from app.member_orders orders
      join app.members member on member.id = orders.member_id
      join app.seasons season on season.id = orders.season_id
      where p_season_id is null or orders.season_id = p_season_id
    ), outstanding_rows as (
      select orders.member_name, orders.relation_number, orders.season_name,
        orders.id order_id, 'unpaid'::text category, null::text article,
        null::text size, null::integer quantity, orders.payment_status,
        null::text line_status, orders.created_at sort_at
      from effective_orders orders
      where orders.payment_status <> 'paid' and p_filter in ('all', 'unpaid')
      union all
      select orders.member_name, orders.relation_number, orders.season_name,
        orders.id, 'backorder', article.name, line.size_snapshot, line.quantity,
        orders.payment_status, line.status::text, line.created_at
      from effective_orders orders
      join app.order_lines line on line.order_id = orders.id and line.status = 'backorder'
      join app.articles article on article.id = line.article_id
      where p_filter in ('all', 'backorder')
      union all
      select orders.member_name, orders.relation_number, orders.season_name,
        orders.id, 'ready_for_pickup', article.name, line.size_snapshot, line.quantity,
        orders.payment_status, line.status::text, line.created_at
      from effective_orders orders
      join app.order_lines line on line.order_id = orders.id and line.status = 'ready_for_pickup'
      join app.articles article on article.id = line.article_id
      where p_filter in ('all', 'ready_for_pickup')
    )
    select jsonb_build_object(
      'member', row.member_name,
      'relationNumber', row.relation_number,
      'season', row.season_name,
      'order', row.order_id::text,
      'category', row.category,
      'article', row.article,
      'size', row.size,
      'quantity', row.quantity,
      'paymentStatus', row.payment_status,
      'lineStatus', row.line_status
    )
    from outstanding_rows row
    order by row.season_name, row.relation_number, row.sort_at, row.category;
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
    'types', array['members', 'orders', 'payments', 'deliveries', 'fulfilments', 'outstanding'],
    'seasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', season.id,
        'name', season.name,
        'active', settings.active_season_id = season.id
      ) order by (settings.active_season_id = season.id) desc, season.starts_on desc nulls last, season.name)
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
    'members', 'orders', 'payments', 'deliveries', 'fulfilments', 'outstanding'
  ]) then
    raise exception 'INVALID_EXPORT_TYPE' using errcode = '22023';
  end if;

  allowed_filters := case p_type
    when 'members' then array['all', 'active', 'inactive', 'linked', 'unlinked']
    when 'orders' then array['all', 'unpaid', 'paid', 'backorder', 'ready_for_pickup', 'picked_up']
    when 'payments' then array['all', 'open', 'pending', 'paid', 'failed', 'canceled', 'expired', 'refunded', 'duplicate_paid', 'mollie', 'cash', 'card']
    when 'deliveries' then array['all', 'available', 'fully_allocated']
    when 'fulfilments' then array['all', 'active', 'corrected', 'reversed']
    when 'outstanding' then array['all', 'unpaid', 'backorder', 'ready_for_pickup']
  end;
  if not (safe_filter = any(allowed_filters)) then
    raise exception 'INVALID_EXPORT_FILTER' using errcode = '22023';
  end if;

  if p_season_id is not null then
    select season.name into season_name from app.seasons season where season.id = p_season_id;
    if season_name is null then
      raise exception 'EXPORT_SEASON_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;

  rate_key := encode(extensions.digest(actor::text || ':' || p_type, 'sha256'), 'hex');
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
    from private.build_export_rows(p_type, p_season_id, safe_filter) generated
    limit 10001
  ) source;

  if row_count > 10000 then
    raise exception 'EXPORT_CAPACITY_EXCEEDED' using errcode = '54000';
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, metadata)
  values(actor, 'export.created', 'export', jsonb_build_object(
    'type', p_type,
    'season', p_season_id,
    'filter', safe_filter,
    'row_count', row_count
  ));

  return jsonb_build_object(
    'type', p_type,
    'seasonName', season_name,
    'generatedAt', to_char(now_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'columns', columns,
    'rows', rows
  );
end;
$$;

revoke all on function private.export_effective_payment_status(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.build_export_rows(text, uuid, text)
from public, anon, authenticated, service_role;

revoke all on function app.get_export_workspace() from public, anon;
revoke all on function app.create_export(text, uuid, text) from public, anon;
grant execute on function app.get_export_workspace() to authenticated;
grant execute on function app.create_export(text, uuid, text) to authenticated;
