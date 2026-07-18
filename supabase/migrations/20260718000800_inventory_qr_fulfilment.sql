do $$ begin
  create type app.reservation_status as enum ('reserved', 'fulfilled', 'released');
exception when duplicate_object then null; end $$;

create table if not exists app.delivery_receipts (
  id uuid primary key default gen_random_uuid(),
  received_on date not null,
  supplier text not null,
  packing_slip_reference text,
  actor_user_id uuid not null,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists app.delivery_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references app.delivery_receipts(id) on delete restrict,
  article_variant_id uuid not null references app.article_variants(id) on delete restrict,
  received_quantity integer not null check (received_quantity > 0),
  created_at timestamptz not null default timezone('utc', now()),
  unique (receipt_id, article_variant_id)
);

create table if not exists app.inventory_reservations (
  id uuid primary key default gen_random_uuid(),
  receipt_line_id uuid not null references app.delivery_receipt_lines(id) on delete restrict,
  order_line_id uuid not null references app.order_lines(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  status app.reservation_status not null default 'reserved',
  actor_user_id uuid not null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create unique index if not exists inventory_one_active_reservation_idx
  on app.inventory_reservations(order_line_id) where status in ('reserved', 'fulfilled');

create table if not exists private.qr_tokens (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references app.member_orders(id) on delete restrict,
  token_hash text not null unique,
  version integer not null check (version > 0),
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  revoked_at timestamptz,
  revoked_by uuid,
  revocation_reason text,
  unique (order_id, version)
);

create unique index if not exists qr_one_active_order_idx on private.qr_tokens(order_id) where active = true;

create table if not exists app.fulfilments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references app.member_orders(id) on delete restrict,
  actor_user_id uuid not null,
  location text not null,
  created_at timestamptz not null default timezone('utc', now()),
  reversed_at timestamptz,
  reversed_by uuid,
  reversal_reason text
);

create table if not exists app.fulfilment_lines (
  id uuid primary key default gen_random_uuid(),
  fulfilment_id uuid not null references app.fulfilments(id) on delete restrict,
  order_line_id uuid not null references app.order_lines(id) on delete restrict,
  reservation_id uuid not null references app.inventory_reservations(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  reversed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create unique index if not exists fulfilment_one_active_order_line_idx
  on app.fulfilment_lines(order_line_id) where reversed_at is null;

create index if not exists audit_logs_actor_action_created_idx
  on app.audit_logs(actor_user_id, action, created_at desc);

create trigger inventory_reservations_touch_updated_at before update on app.inventory_reservations
for each row execute function app.touch_updated_at();

alter table app.delivery_receipts enable row level security;
alter table app.delivery_receipt_lines enable row level security;
alter table app.inventory_reservations enable row level security;
alter table app.fulfilments enable row level security;
alter table app.fulfilment_lines enable row level security;
alter table private.qr_tokens enable row level security;

create policy "operations can read receipts" on app.delivery_receipts for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "operations can read receipt lines" on app.delivery_receipt_lines for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "operations can read reservations" on app.inventory_reservations for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));
create policy "staff can read fulfilments" on app.fulfilments for select using (app.is_staff_member());
create policy "staff can read fulfilment lines" on app.fulfilment_lines for select using (app.is_staff_member());

create or replace function app.refresh_order_status(p_order_id uuid)
returns text
language plpgsql
set search_path = app, pg_temp
as $$
declare
  next_status text;
  active_count integer;
  backorder_count integer;
  ready_count integer;
  picked_up_count integer;
begin
  if not exists (select 1 from app.member_orders where id = p_order_id) then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not exists (select 1 from app.payments where order_id = p_order_id and status = 'paid') then
    next_status := 'Nog niet betaald';
  else
    select
      count(*) filter (where status <> 'cancelled'),
      count(*) filter (where status = 'backorder'),
      count(*) filter (where status = 'ready_for_pickup'),
      count(*) filter (where status = 'picked_up')
    into active_count, backorder_count, ready_count, picked_up_count
    from app.order_lines
    where order_id = p_order_id;

    next_status := case
      when active_count = 0 or picked_up_count = active_count then 'Afgerond'
      when picked_up_count > 0 then 'Gedeeltelijk afgehaald'
      when ready_count > 0 and backorder_count > 0 then 'Gedeeltelijk af te halen'
      when ready_count = active_count then 'Volledig af te halen'
      else 'Nalevering'
    end;
  end if;

  update app.member_orders
  set order_status = next_status, updated_at = timezone('utc', now())
  where id = p_order_id;
  return next_status;
end;
$$;

create or replace function app.register_delivery_receipt(
  p_received_on date,
  p_supplier text,
  p_packing_slip_reference text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare actor uuid := auth.uid(); receipt_id uuid; line_count integer;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  if p_received_on is null or length(trim(p_supplier)) = 0 or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'INVALID_RECEIPT' using errcode = '22023'; end if;
  insert into app.delivery_receipts (received_on, supplier, packing_slip_reference, actor_user_id)
  values (p_received_on, left(trim(p_supplier), 160), nullif(left(trim(p_packing_slip_reference), 160), ''), actor)
  returning id into receipt_id;
  insert into app.delivery_receipt_lines (receipt_id, article_variant_id, received_quantity)
  select receipt_id, rows.variant_id, rows.quantity
  from jsonb_to_recordset(p_lines) as rows(variant_id uuid, quantity integer)
  where rows.variant_id is not null and rows.quantity > 0;
  get diagnostics line_count = row_count;
  if line_count <> jsonb_array_length(p_lines) then raise exception 'INVALID_RECEIPT_LINE' using errcode = '22023'; end if;
  insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, metadata)
  values (actor, 'stock.receipt.created', 'delivery_receipt', receipt_id, jsonb_build_object('line_count', line_count, 'received_on', p_received_on));
  return jsonb_build_object('receiptId', receipt_id, 'lineCount', line_count);
end;
$$;

create or replace function app.reserve_order_lines(p_receipt_line_id uuid, p_order_line_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare actor uuid := auth.uid(); receipt_line app.delivery_receipt_lines%rowtype; requested integer; consumed integer; selected_quantity integer; line_id uuid; line_record app.order_lines%rowtype; affected_order_ids uuid[] := '{}';
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  requested := coalesce(array_length(p_order_line_ids, 1), 0);
  if requested = 0 or requested <> (select count(distinct value) from unnest(p_order_line_ids) as value) then raise exception 'INVALID_RESERVATION_SELECTION' using errcode = '22023'; end if;
  select * into receipt_line from app.delivery_receipt_lines where id = p_receipt_line_id for update;
  if not found then raise exception 'RECEIPT_LINE_NOT_FOUND' using errcode = 'P0002'; end if;
  select coalesce(sum(quantity), 0) into consumed from app.inventory_reservations where receipt_line_id = p_receipt_line_id and status in ('reserved', 'fulfilled');
  select coalesce(sum(quantity), 0) into selected_quantity from app.order_lines where id = any(p_order_line_ids);
  if receipt_line.received_quantity - consumed < selected_quantity then raise exception 'INSUFFICIENT_STOCK' using errcode = '23514'; end if;
  foreach line_id in array p_order_line_ids loop
    select * into line_record from app.order_lines where id = line_id for update;
    if not found or line_record.article_variant_id <> receipt_line.article_variant_id or line_record.status <> 'backorder' then raise exception 'ORDER_LINE_NOT_RESERVABLE' using errcode = '23514'; end if;
    insert into app.inventory_reservations (receipt_line_id, order_line_id, quantity, actor_user_id)
    values (p_receipt_line_id, line_record.id, line_record.quantity, actor);
    update app.order_lines set status = 'ready_for_pickup', updated_at = timezone('utc', now()) where id = line_record.id;
    if not line_record.order_id = any(affected_order_ids) then affected_order_ids := array_append(affected_order_ids, line_record.order_id); end if;
  end loop;
  foreach line_id in array affected_order_ids loop perform app.refresh_order_status(line_id); end loop;
  insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, metadata)
  values (actor, 'stock.lines.reserved', 'delivery_receipt_line', p_receipt_line_id, jsonb_build_object('order_line_ids', p_order_line_ids));
  return jsonb_build_object('reservedLines', requested);
end;
$$;

create or replace function app.store_order_qr(p_order_id uuid, p_token_hash text, p_version integer)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare actor uuid := auth.uid(); qr_id uuid;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  if not exists (select 1 from app.payments where order_id = p_order_id and status = 'paid') then raise exception 'ORDER_NOT_PAID' using errcode = '23514'; end if;
  if p_token_hash !~ '^[0-9a-f]{64}$' or p_version < 1 then raise exception 'INVALID_QR_TOKEN' using errcode = '22023'; end if;
  insert into private.qr_tokens (order_id, token_hash, version, created_by)
  values (p_order_id, p_token_hash, p_version, actor) returning id into qr_id;
  insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, metadata)
  values (actor, 'qr.created', 'member_order', p_order_id, jsonb_build_object('version', p_version));
  return qr_id;
end;
$$;

create or replace function app.lookup_fulfilment(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare actor uuid := auth.uid(); target_order uuid;
begin
  if actor is null or not app.is_staff_member() then raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  if p_token_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('status', 'invalid'); end if;
  if (select count(*) from app.audit_logs where actor_user_id = actor and action = 'qr.lookup' and created_at >= timezone('utc', now()) - interval '1 minute') >= 60 then raise exception 'QR_LOOKUP_RATE_LIMITED' using errcode = 'P0001'; end if;
  select order_id into target_order from private.qr_tokens where token_hash = p_token_hash and active = true limit 1;
  if target_order is null then
    insert into app.audit_logs (actor_user_id, action, entity_type, metadata) values (actor, 'qr.lookup', 'member_order', jsonb_build_object('result', 'invalid'));
    return jsonb_build_object('status', 'invalid');
  end if;
  insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, metadata) values (actor, 'qr.lookup', 'member_order', target_order, jsonb_build_object('result', 'found'));
  return jsonb_build_object(
    'status', 'found',
    'orderId', target_order,
    'paid', exists(select 1 from app.payments where order_id = target_order and status = 'paid'),
    'member', (select jsonb_build_object('name', concat_ws(' ', m.first_name, m.insertion, m.last_name), 'team', m.team, 'relationNumberSuffix', right(m.relation_number, 4)) from app.member_orders mo join app.members m on m.id = mo.member_id where mo.id = target_order),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', ol.id, 'article', a.name, 'size', av.size, 'status', ol.status::text) order by a.sort_order) from app.order_lines ol join app.article_variants av on av.id = ol.article_variant_id join app.articles a on a.id = av.article_id where ol.order_id = target_order), '[]'::jsonb)
  );
end;
$$;

create or replace function app.commit_fulfilment(p_order_id uuid, p_order_line_ids uuid[], p_location text, p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare actor uuid := auth.uid(); fulfilment_id uuid; line_id uuid; reservation app.inventory_reservations%rowtype; selected_count integer;
begin
  if actor is null or not app.is_staff_member() then raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  selected_count := coalesce(array_length(p_order_line_ids, 1), 0);
  if selected_count = 0 or selected_count <> (select count(distinct value) from unnest(p_order_line_ids) as value) or length(trim(p_location)) = 0 or p_token_hash !~ '^[0-9a-f]{64}$' then raise exception 'INVALID_FULFILMENT_SELECTION' using errcode = '22023'; end if;
  perform 1 from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  if not exists (select 1 from private.qr_tokens where order_id = p_order_id and token_hash = p_token_hash and active = true) then raise exception 'QR_TOKEN_INVALID' using errcode = '23514'; end if;
  if not exists (select 1 from app.payments where order_id = p_order_id and status = 'paid') then raise exception 'ORDER_NOT_PAID' using errcode = '23514'; end if;
  insert into app.fulfilments (order_id, actor_user_id, location) values (p_order_id, actor, left(trim(p_location), 160)) returning id into fulfilment_id;
  foreach line_id in array p_order_line_ids loop
    perform 1 from app.order_lines where id = line_id and order_id = p_order_id and status = 'ready_for_pickup' for update;
    if not found then raise exception 'ORDER_LINE_NOT_READY' using errcode = '23514'; end if;
    select * into reservation from app.inventory_reservations where order_line_id = line_id and status = 'reserved' for update;
    if not found then raise exception 'RESERVATION_NOT_FOUND' using errcode = '23514'; end if;
    insert into app.fulfilment_lines (fulfilment_id, order_line_id, reservation_id, quantity) values (fulfilment_id, line_id, reservation.id, reservation.quantity);
    update app.inventory_reservations set status = 'fulfilled', updated_at = timezone('utc', now()) where id = reservation.id;
    update app.order_lines set status = 'picked_up', updated_at = timezone('utc', now()) where id = line_id;
  end loop;
  perform app.refresh_order_status(p_order_id);
  insert into app.audit_logs (actor_user_id, action, entity_type, entity_id, metadata)
  values (actor, 'fulfilment.completed', 'fulfilment', fulfilment_id, jsonb_build_object('order_id', p_order_id, 'line_count', selected_count, 'location', left(trim(p_location), 160)));
  return jsonb_build_object('fulfilmentId', fulfilment_id, 'issuedLines', selected_count, 'completedAt', timezone('utc', now()));
end;
$$;

revoke all on function app.register_delivery_receipt(date, text, text, jsonb) from public, anon;
revoke all on function app.reserve_order_lines(uuid, uuid[]) from public, anon;
revoke all on function app.store_order_qr(uuid, text, integer) from public, anon;
revoke all on function app.lookup_fulfilment(text) from public, anon;
revoke all on function app.commit_fulfilment(uuid, uuid[], text, text) from public, anon;
revoke all on function app.refresh_order_status(uuid) from public, anon, authenticated;
grant execute on function app.register_delivery_receipt(date, text, text, jsonb) to authenticated;
grant execute on function app.reserve_order_lines(uuid, uuid[]) to authenticated;
grant execute on function app.store_order_qr(uuid, text, integer) to authenticated;
grant execute on function app.lookup_fulfilment(text) to authenticated;
grant execute on function app.commit_fulfilment(uuid, uuid[], text, text) to authenticated;
