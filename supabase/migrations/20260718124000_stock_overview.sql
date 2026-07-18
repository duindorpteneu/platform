create or replace function app.get_stock_overview(p_variant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
begin
  if auth.uid() is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'variants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', av.id,
        'article', a.name,
        'size', av.size,
        'sku', av.sku,
        'received', coalesce(stock.received, 0),
        'reserved', coalesce(stock.reserved, 0),
        'issued', coalesce(stock.issued, 0),
        'available', coalesce(stock.received, 0) - coalesce(stock.reserved, 0) - coalesce(stock.issued, 0),
        'backorderCount', coalesce(waiting.backorder_count, 0)
      ) order by a.sort_order, av.size)
      from app.article_variants av
      join app.articles a on a.id = av.article_id
      left join lateral (
        select
          coalesce(sum(drl.received_quantity), 0)::integer as received,
          coalesce(sum((select coalesce(sum(ir.quantity), 0) from app.inventory_reservations ir where ir.receipt_line_id = drl.id and ir.status = 'reserved')), 0)::integer as reserved,
          coalesce(sum((select coalesce(sum(ir.quantity), 0) from app.inventory_reservations ir where ir.receipt_line_id = drl.id and ir.status = 'fulfilled')), 0)::integer as issued
        from app.delivery_receipt_lines drl
        where drl.article_variant_id = av.id
      ) stock on true
      left join lateral (
        select count(*)::integer as backorder_count
        from app.order_lines ol
        where ol.article_variant_id = av.id and ol.status = 'backorder'
      ) waiting on true
      where a.active = true and av.active = true
    ), '[]'::jsonb),
    'receiptLines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', drl.id,
        'receiptId', dr.id,
        'receivedOn', dr.received_on,
        'supplier', dr.supplier,
        'packingSlipReference', dr.packing_slip_reference,
        'variantId', av.id,
        'article', a.name,
        'size', av.size,
        'received', drl.received_quantity,
        'reserved', coalesce(stock.reserved, 0),
        'issued', coalesce(stock.issued, 0),
        'available', drl.received_quantity - coalesce(stock.reserved, 0) - coalesce(stock.issued, 0)
      ) order by dr.received_on desc, dr.created_at desc, a.sort_order, av.size)
      from app.delivery_receipt_lines drl
      join app.delivery_receipts dr on dr.id = drl.receipt_id
      join app.article_variants av on av.id = drl.article_variant_id
      join app.articles a on a.id = av.article_id
      left join lateral (
        select
          coalesce(sum(ir.quantity) filter (where ir.status = 'reserved'), 0)::integer as reserved,
          coalesce(sum(ir.quantity) filter (where ir.status = 'fulfilled'), 0)::integer as issued
        from app.inventory_reservations ir
        where ir.receipt_line_id = drl.id
      ) stock on true
    ), '[]'::jsonb),
    'waitlist', case when p_variant_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'orderLineId', ol.id,
        'orderId', mo.id,
        'memberName', concat_ws(' ', m.first_name, m.insertion, m.last_name),
        'relationNumber', m.relation_number,
        'team', m.team,
        'quantity', ol.quantity,
        'paid', exists(select 1 from app.payments p where p.order_id = mo.id and p.status = 'paid'),
        'createdAt', ol.created_at
      ) order by ol.created_at, m.last_name, m.first_name)
      from app.order_lines ol
      join app.member_orders mo on mo.id = ol.order_id
      join app.members m on m.id = mo.member_id
      where ol.article_variant_id = p_variant_id and ol.status = 'backorder'
    ), '[]'::jsonb) end
  );
end;
$$;

revoke all on function app.get_stock_overview(uuid) from public, anon;
grant execute on function app.get_stock_overview(uuid) to authenticated;
