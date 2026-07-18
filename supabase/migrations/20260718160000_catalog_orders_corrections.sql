alter table app.articles
  add column if not exists code text,
  add column if not exists icon_type text not null default 'package';

update app.articles
set code = case lower(name)
  when 'shirt' then 'SHIRT'
  when 'broekje' then 'BROEK'
  when 'sokken' then 'SOK'
  else upper(left(regexp_replace(name, '[^a-zA-Z0-9]+', '', 'g'), 16)) || '-' || left(id::text, 4)
end
where code is null;

alter table app.articles
  alter column code set not null,
  add constraint articles_name_length_check check (length(trim(name)) between 1 and 120),
  add constraint articles_code_format_check check (code ~ '^[A-Z0-9_-]{2,24}$'),
  add constraint articles_icon_type_check check (icon_type in ('shirt', 'package', 'circle-dot')),
  add constraint articles_sort_order_check check (sort_order between 0 and 10000);

create unique index if not exists articles_name_normalized_idx on app.articles(lower(trim(name)));
create unique index if not exists articles_code_normalized_idx on app.articles(upper(trim(code)));

alter table app.article_variants
  add column if not exists sort_order integer not null default 0,
  add constraint article_variants_size_length_check check (length(trim(size)) between 1 and 80),
  add constraint article_variants_sku_length_check check (sku is null or length(trim(sku)) between 1 and 120),
  add constraint article_variants_sort_order_check check (sort_order between 0 and 10000);

alter table app.article_variants
  add constraint article_variants_id_article_unique unique (id, article_id);

create table if not exists app.article_seasons (
  article_id uuid not null references app.articles(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now()),
  primary key (article_id, season_id)
);

insert into app.article_seasons(article_id, season_id)
select article.id, settings.active_season_id
from app.articles article
cross join app.app_settings settings
where settings.id = true and settings.active_season_id is not null
on conflict do nothing;

alter table app.article_seasons enable row level security;
create policy "operations can read article seasons" on app.article_seasons
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

alter table app.order_lines
  add column if not exists article_id uuid,
  add column if not exists size_snapshot text;

update app.order_lines line
set article_id = variant.article_id, size_snapshot = variant.size
from app.article_variants variant
where variant.id = line.article_variant_id and (line.article_id is null or line.size_snapshot is null);

create or replace function app.sync_order_line_article()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
declare resolved_article_id uuid; resolved_size text;
begin
  select article_id, size into resolved_article_id, resolved_size
  from app.article_variants
  where id = new.article_variant_id;
  if resolved_article_id is null then
    raise exception 'ARTICLE_VARIANT_NOT_FOUND' using errcode = '23503';
  end if;
  if new.article_id is not null and new.article_id <> resolved_article_id then
    raise exception 'ORDER_LINE_ARTICLE_VARIANT_MISMATCH' using errcode = '23514';
  end if;
  new.article_id := resolved_article_id;
  if tg_op = 'INSERT' or new.article_variant_id is distinct from old.article_variant_id or new.size_snapshot is null then
    new.size_snapshot := resolved_size;
  end if;
  return new;
end;
$$;

drop trigger if exists order_lines_sync_article on app.order_lines;
create trigger order_lines_sync_article
before insert or update of article_variant_id, article_id on app.order_lines
for each row execute function app.sync_order_line_article();

alter table app.order_lines
  alter column article_id set not null,
  alter column size_snapshot set not null,
  add constraint order_lines_article_id_fkey foreign key (article_id) references app.articles(id) on delete restrict,
  add constraint order_lines_variant_article_fkey foreign key (article_variant_id, article_id)
    references app.article_variants(id, article_id) on delete restrict;

create unique index if not exists order_lines_one_active_article_idx
  on app.order_lines(order_id, article_id) where status <> 'cancelled';

create or replace function app.enforce_paid_payment_amount()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
declare due integer;
begin
  if new.status = 'paid' then
    select amount_due_cents into due from app.member_orders where id = new.order_id for update;
    if due is null or new.currency <> 'EUR' or new.amount_cents <> due then
      raise exception 'PAID_AMOUNT_MISMATCH' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists payments_enforce_exact_amount on app.payments;
create trigger payments_enforce_exact_amount
before insert or update of status, amount_cents, currency, order_id on app.payments
for each row execute function app.enforce_paid_payment_amount();

create or replace function app.guard_paid_order_line_identity()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
declare target_order_id uuid;
begin
  target_order_id := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
  if exists(select 1 from app.payments where order_id = target_order_id and status = 'paid') then
    if tg_op in ('INSERT', 'DELETE') or new.order_id is distinct from old.order_id
      or new.article_variant_id is distinct from old.article_variant_id
      or new.article_id is distinct from old.article_id
      or new.quantity is distinct from old.quantity
      or new.size_snapshot is distinct from old.size_snapshot
    then raise exception 'PAID_ORDER_IMMUTABLE' using errcode = '23514'; end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists order_lines_guard_paid_identity on app.order_lines;
create trigger order_lines_guard_paid_identity
before insert or update or delete on app.order_lines
for each row execute function app.guard_paid_order_line_identity();

create or replace function app.guard_paid_order_amount()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  if new.amount_due_cents is distinct from old.amount_due_cents
    and exists(select 1 from app.payments where order_id = old.id and status = 'paid')
  then raise exception 'PAID_ORDER_IMMUTABLE' using errcode = '23514'; end if;
  return new;
end;
$$;

drop trigger if exists member_orders_guard_paid_amount on app.member_orders;
create trigger member_orders_guard_paid_amount
before update of amount_due_cents on app.member_orders
for each row execute function app.guard_paid_order_amount();

alter table app.fulfilment_lines
  add column if not exists reversed_by uuid,
  add column if not exists reversal_reason text;

alter table app.fulfilments
  add column if not exists corrected_at timestamptz,
  add column if not exists correction_reason text;

create or replace function app.get_catalog_order_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare active_season_id uuid; active_season_name text; default_amount integer;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  select season.id, season.name, season.default_amount_cents
  into active_season_id, active_season_name, default_amount
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id
  where settings.id = true and season.status = 'open'
  limit 1;

  return jsonb_build_object(
    'activeSeason', case when active_season_id is null then null else jsonb_build_object(
      'id', active_season_id, 'name', active_season_name, 'defaultAmountCents', default_amount
    ) end,
    'articles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', article.id,
        'name', article.name,
        'code', article.code,
        'iconType', article.icon_type,
        'active', article.active,
        'sortOrder', article.sort_order,
        'seasonIds', coalesce((
          select jsonb_agg(link.season_id order by link.season_id)
          from app.article_seasons link where link.article_id = article.id
        ), '[]'::jsonb),
        'variants', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', variant.id,
            'size', variant.size,
            'supplierCode', variant.sku,
            'active', variant.active,
            'sortOrder', variant.sort_order,
            'used', exists(select 1 from app.order_lines line where line.article_variant_id = variant.id),
            'receivedQuantity', coalesce((
              select sum(receipt_line.received_quantity)
              from app.delivery_receipt_lines receipt_line
              where receipt_line.article_variant_id = variant.id
            ), 0),
            'availableQuantity', coalesce((
              select sum(receipt_line.received_quantity)
              from app.delivery_receipt_lines receipt_line
              where receipt_line.article_variant_id = variant.id
            ), 0) - coalesce((
              select sum(reservation.quantity)
              from app.inventory_reservations reservation
              join app.order_lines reserved_line on reserved_line.id = reservation.order_line_id
              where reserved_line.article_variant_id = variant.id
                and reservation.status in ('reserved', 'fulfilled')
            ), 0)
          ) order by variant.sort_order, lower(variant.size), variant.id)
          from app.article_variants variant where variant.article_id = article.id
        ), '[]'::jsonb)
      ) order by article.sort_order, lower(article.name), article.id)
      from app.articles article
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', member.id,
        'name', concat_ws(' ', member.first_name, member.insertion, member.last_name),
        'relationNumber', member.relation_number,
        'team', member.team,
        'order', case when orders.id is null then null else jsonb_build_object(
          'id', orders.id,
          'amountDueCents', orders.amount_due_cents,
          'paid', exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid'),
          'lines', coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', line.id,
              'articleId', line.article_id,
              'variantId', line.article_variant_id,
              'quantity', line.quantity,
              'status', line.status::text
            ) order by article.sort_order, line.id)
            from app.order_lines line
            join app.articles article on article.id = line.article_id
            where line.order_id = orders.id and line.status <> 'cancelled'
          ), '[]'::jsonb)
        ) end
      ) order by lower(member.last_name), lower(member.first_name), member.id)
      from app.members member
      left join app.member_orders orders
        on orders.member_id = member.id and orders.season_id = active_season_id
      where member.active_for_season = true
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.get_fulfilment_corrections_workspace()
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
  return jsonb_build_object('fulfilments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', fulfilment.id,
      'orderId', fulfilment.order_id,
      'memberName', concat_ws(' ', member.first_name, member.insertion, member.last_name),
      'relationNumber', member.relation_number,
      'team', member.team,
      'location', fulfilment.location,
      'fulfilledAt', fulfilment.created_at,
      'correctedAt', fulfilment.corrected_at,
      'lines', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', fulfilment_line.id,
          'orderLineId', order_line.id,
          'article', article.name,
          'size', order_line.size_snapshot,
          'quantity', fulfilment_line.quantity,
          'status', order_line.status::text,
          'reversedAt', fulfilment_line.reversed_at,
          'reversalReason', fulfilment_line.reversal_reason
        ) order by article.sort_order, fulfilment_line.id)
        from app.fulfilment_lines fulfilment_line
        join app.order_lines order_line on order_line.id = fulfilment_line.order_line_id
        join app.articles article on article.id = order_line.article_id
        where fulfilment_line.fulfilment_id = fulfilment.id
      ), '[]'::jsonb)
    ) order by fulfilment.created_at desc, fulfilment.id desc)
    from (
      select * from app.fulfilments order by created_at desc, id desc limit 100
    ) fulfilment
    join app.member_orders orders on orders.id = fulfilment.order_id
    join app.members member on member.id = orders.member_id
  ), '[]'::jsonb));
end;
$$;

create or replace function app.upsert_catalog_article(
  p_article_id uuid,
  p_name text,
  p_code text,
  p_icon_type text,
  p_active boolean,
  p_sort_order integer,
  p_season_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare actor uuid := auth.uid(); target_id uuid; season_id uuid;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if length(trim(p_name)) not between 1 and 120
    or upper(trim(p_code)) !~ '^[A-Z0-9_-]{2,24}$'
    or p_icon_type not in ('shirt', 'package', 'circle-dot')
    or p_sort_order not between 0 and 10000
    or coalesce(array_length(p_season_ids, 1), 0) = 0
    or coalesce(array_length(p_season_ids, 1), 0) <> (select count(distinct value) from unnest(p_season_ids) value)
  then raise exception 'INVALID_ARTICLE' using errcode = '22023';
  end if;
  foreach season_id in array p_season_ids loop
    if not exists(select 1 from app.seasons season where season.id = season_id) then
      raise exception 'SEASON_NOT_FOUND' using errcode = 'P0002';
    end if;
  end loop;

  if p_article_id is null then
    insert into app.articles(name, code, icon_type, active, sort_order)
    values(trim(p_name), upper(trim(p_code)), p_icon_type, p_active, p_sort_order)
    returning id into target_id;
  else
    perform 1 from app.articles where id = p_article_id for update;
    if not found then raise exception 'ARTICLE_NOT_FOUND' using errcode = 'P0002'; end if;
    update app.articles set
      name = trim(p_name), code = upper(trim(p_code)), icon_type = p_icon_type,
      active = p_active, sort_order = p_sort_order
    where id = p_article_id;
    target_id := p_article_id;
    delete from app.article_seasons where article_id = target_id and season_id <> all(p_season_ids);
  end if;

  insert into app.article_seasons(article_id, season_id)
  select target_id, value from unnest(p_season_ids) value on conflict do nothing;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(actor, case when p_article_id is null then 'catalog.article.created' else 'catalog.article.updated' end,
    'article', target_id, jsonb_build_object('active', p_active, 'season_count', array_length(p_season_ids, 1)));
  return target_id;
exception when unique_violation then
  raise exception 'ARTICLE_NAME_OR_CODE_EXISTS' using errcode = '23505';
end;
$$;

create or replace function app.upsert_catalog_variant(
  p_article_id uuid,
  p_variant_id uuid,
  p_size text,
  p_supplier_code text,
  p_active boolean,
  p_sort_order integer
)
returns uuid
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare actor uuid := auth.uid(); target_id uuid; existing app.article_variants%rowtype;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if not exists(select 1 from app.articles where id = p_article_id)
    or length(trim(p_size)) not between 1 and 80
    or (nullif(trim(p_supplier_code), '') is not null and length(trim(p_supplier_code)) > 120)
    or p_sort_order not between 0 and 10000
  then raise exception 'INVALID_VARIANT' using errcode = '22023'; end if;

  if p_variant_id is null then
    insert into app.article_variants(article_id, size, sku, active, sort_order)
    values(p_article_id, trim(p_size), nullif(trim(p_supplier_code), ''), p_active, p_sort_order)
    returning id into target_id;
  else
    select * into existing from app.article_variants where id = p_variant_id and article_id = p_article_id for update;
    if not found then raise exception 'VARIANT_NOT_FOUND' using errcode = 'P0002'; end if;
    if exists(select 1 from app.order_lines where article_variant_id = p_variant_id)
      and existing.size is distinct from trim(p_size)
    then raise exception 'USED_VARIANT_SIZE_IMMUTABLE' using errcode = '23514'; end if;
    update app.article_variants set size = trim(p_size), sku = nullif(trim(p_supplier_code), ''),
      active = p_active, sort_order = p_sort_order
    where id = p_variant_id;
    target_id := p_variant_id;
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(actor, case when p_variant_id is null then 'catalog.variant.created' else 'catalog.variant.updated' end,
    'article_variant', target_id, jsonb_build_object('article_id', p_article_id, 'active', p_active));
  return target_id;
exception when unique_violation then
  raise exception 'VARIANT_SIZE_EXISTS' using errcode = '23505';
end;
$$;

create or replace function app.save_member_order(
  p_member_id uuid,
  p_season_id uuid,
  p_amount_due_cents integer,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_order app.member_orders%rowtype;
  previous_amount integer;
  requested_count integer;
  item record;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_amount_due_cents is null or p_amount_due_cents < 0
    or jsonb_typeof(p_lines) <> 'array'
    or jsonb_array_length(p_lines) < 1
    or jsonb_array_length(p_lines) > 25
  then raise exception 'INVALID_ORDER' using errcode = '22023'; end if;
  if not exists(select 1 from app.members where id = p_member_id and active_for_season = true for update) then
    raise exception 'MEMBER_NOT_ACTIVE' using errcode = '23514';
  end if;
  if not exists(
    select 1 from app.app_settings settings join app.seasons season on season.id = settings.active_season_id
    where settings.id = true and season.id = p_season_id and season.status = 'open'
  ) then raise exception 'SEASON_NOT_OPEN' using errcode = '23514'; end if;

  with incoming as (
    select row_data.variant_id, row_data.quantity, variant.article_id
    from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)
    left join app.article_variants variant on variant.id = row_data.variant_id
  )
  select count(*) into requested_count from incoming
  where variant_id is not null and quantity between 1 and 25 and article_id is not null;
  if requested_count <> jsonb_array_length(p_lines)
    or (select count(distinct row_data.variant_id) from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)) <> requested_count
    or (select count(distinct variant.article_id)
        from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)
        join app.article_variants variant on variant.id = row_data.variant_id) <> requested_count
    or exists(
      select 1
      from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)
      join app.article_variants variant on variant.id = row_data.variant_id
      join app.articles article on article.id = variant.article_id
      where not variant.active or not article.active
        or not exists(select 1 from app.article_seasons link where link.article_id = article.id and link.season_id = p_season_id)
    )
  then raise exception 'INVALID_ORDER_LINES' using errcode = '22023'; end if;

  select * into target_order from app.member_orders
  where member_id = p_member_id and season_id = p_season_id for update;
  if found and exists(select 1 from app.payments where order_id = target_order.id and status = 'paid') then
    raise exception 'PAID_ORDER_IMMUTABLE' using errcode = '23514';
  end if;

  if not found then
    insert into app.member_orders(member_id, season_id, amount_due_cents)
    values(p_member_id, p_season_id, p_amount_due_cents) returning * into target_order;
  else
    previous_amount := target_order.amount_due_cents;
    if exists(select 1 from app.order_lines where order_id = target_order.id and status <> 'backorder' and status <> 'cancelled')
      and (
        exists(
          select line.article_variant_id, line.quantity from app.order_lines line
          where line.order_id = target_order.id and line.status <> 'cancelled'
          except
          select row_data.variant_id, row_data.quantity
          from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)
        )
        or exists(
          select row_data.variant_id, row_data.quantity
          from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)
          except
          select line.article_variant_id, line.quantity from app.order_lines line
          where line.order_id = target_order.id and line.status <> 'cancelled'
        )
      )
    then raise exception 'RESERVED_ORDER_LINES_IMMUTABLE' using errcode = '23514'; end if;
    update app.member_orders set amount_due_cents = p_amount_due_cents where id = target_order.id;
  end if;

  update app.order_lines line set status = 'cancelled', updated_at = timezone('utc', now())
  where line.order_id = target_order.id and line.status = 'backorder'
    and not exists(
      select 1 from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)
      join app.article_variants variant on variant.id = row_data.variant_id
      where variant.article_id = line.article_id
    );

  for item in
    select row_data.variant_id, row_data.quantity, variant.article_id
    from jsonb_to_recordset(p_lines) row_data(variant_id uuid, quantity integer)
    join app.article_variants variant on variant.id = row_data.variant_id
  loop
    update app.order_lines set article_variant_id = item.variant_id, quantity = item.quantity,
      updated_at = timezone('utc', now())
    where order_id = target_order.id and article_id = item.article_id and status = 'backorder';
    if not found and not exists(
      select 1 from app.order_lines where order_id = target_order.id and article_id = item.article_id and status <> 'cancelled'
    ) then
      insert into app.order_lines(order_id, article_variant_id, quantity)
      values(target_order.id, item.variant_id, item.quantity);
    end if;
  end loop;

  perform app.refresh_order_status(target_order.id);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(actor, case when previous_amount is null then 'order.created' else 'order.updated' end, 'member_order',
    target_order.id, jsonb_build_object('amount_before_cents', previous_amount, 'amount_after_cents', p_amount_due_cents, 'line_count', requested_count));
  return jsonb_build_object('orderId', target_order.id, 'amountDueCents', p_amount_due_cents, 'lineCount', requested_count);
end;
$$;

create or replace function app.get_order_qr_rotation_context(p_actor_id uuid, p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare current_version integer; is_active boolean;
begin
  if p_actor_id is null or not exists(
    select 1 from app.staff_profiles where auth_user_id = p_actor_id and active = true
      and role in ('beheerder', 'kledingcommissie')
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if not exists(select 1 from app.member_orders where id = p_order_id) then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;
  select version, active into current_version, is_active from private.qr_tokens
  where order_id = p_order_id order by version desc limit 1;
  return jsonb_build_object('orderId', p_order_id, 'currentVersion', current_version, 'active', coalesce(is_active, false));
end;
$$;

create or replace function app.rotate_order_qr(
  p_actor_id uuid,
  p_order_id uuid,
  p_expected_version integer,
  p_token_hash text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare current_token private.qr_tokens%rowtype; next_version integer;
begin
  if p_actor_id is null or not exists(
    select 1 from app.staff_profiles where auth_user_id = p_actor_id and active = true
      and role in ('beheerder', 'kledingcommissie')
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_token_hash !~ '^[0-9a-f]{64}$' or length(trim(p_reason)) not between 4 and 500 then
    raise exception 'INVALID_QR_ROTATION' using errcode = '22023';
  end if;
  perform 1 from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  if not exists(select 1 from app.payments where order_id = p_order_id and status = 'paid') then
    raise exception 'ORDER_NOT_PAID' using errcode = '23514';
  end if;
  select * into current_token from private.qr_tokens
  where order_id = p_order_id order by version desc limit 1 for update;
  if not found or current_token.version <> p_expected_version then
    raise exception 'QR_ROTATION_CONFLICT' using errcode = '40001';
  end if;
  next_version := current_token.version + 1;
  if current_token.active then
    update private.qr_tokens set active = false, revoked_at = timezone('utc', now()),
      revoked_by = p_actor_id, revocation_reason = trim(p_reason)
    where id = current_token.id;
  end if;
  insert into private.qr_tokens(order_id, token_hash, version, created_by)
  values(p_order_id, p_token_hash, next_version, p_actor_id);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(p_actor_id, 'qr.rotated', 'member_order', p_order_id,
    jsonb_build_object('previous_version', current_token.version, 'new_version', next_version, 'reason', trim(p_reason)));
  return jsonb_build_object('orderId', p_order_id, 'qrStatus', 'active', 'version', next_version);
end;
$$;

create or replace function app.revoke_order_qr(p_actor_id uuid, p_order_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare current_token private.qr_tokens%rowtype;
begin
  if p_actor_id is null or not exists(
    select 1 from app.staff_profiles where auth_user_id = p_actor_id and active = true
      and role in ('beheerder', 'kledingcommissie')
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if length(trim(p_reason)) not between 4 and 500 then raise exception 'INVALID_QR_REVOCATION' using errcode = '22023'; end if;
  select * into current_token from private.qr_tokens
  where order_id = p_order_id and active = true for update;
  if not found then raise exception 'ACTIVE_QR_NOT_FOUND' using errcode = 'P0002'; end if;
  update private.qr_tokens set active = false, revoked_at = timezone('utc', now()),
    revoked_by = p_actor_id, revocation_reason = trim(p_reason)
  where id = current_token.id;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(p_actor_id, 'qr.revoked', 'member_order', p_order_id,
    jsonb_build_object('version', current_token.version, 'reason', trim(p_reason)));
  return jsonb_build_object('orderId', p_order_id, 'qrStatus', 'revoked');
end;
$$;

create or replace function app.correct_fulfilment(
  p_order_line_ids uuid[],
  p_target_status app.order_line_status,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  line_id uuid;
  line_record app.order_lines%rowtype;
  active_fulfilment_line app.fulfilment_lines%rowtype;
  affected_orders uuid[] := '{}';
  corrected_count integer := 0;
  ordered_line_ids uuid[];
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_target_status not in ('ready_for_pickup', 'backorder')
    or length(trim(p_reason)) not between 4 and 500
    or coalesce(array_length(p_order_line_ids, 1), 0) = 0
    or array_length(p_order_line_ids, 1) > 25
    or array_length(p_order_line_ids, 1) <> (select count(distinct value) from unnest(p_order_line_ids) value)
  then raise exception 'INVALID_FULFILMENT_CORRECTION' using errcode = '22023'; end if;

  select array_agg(value order by value) into ordered_line_ids from unnest(p_order_line_ids) value;
  foreach line_id in array ordered_line_ids loop
    select * into line_record from app.order_lines where id = line_id for update;
    if not found or line_record.status <> 'picked_up' then
      raise exception 'ORDER_LINE_NOT_PICKED_UP' using errcode = '23514';
    end if;
    select fulfilment_line.* into active_fulfilment_line
    from app.fulfilment_lines fulfilment_line
    where fulfilment_line.order_line_id = line_id and fulfilment_line.reversed_at is null
    for update;
    if not found then raise exception 'ACTIVE_FULFILMENT_NOT_FOUND' using errcode = '23514'; end if;

    update app.fulfilment_lines set reversed_at = timezone('utc', now()), reversed_by = actor,
      reversal_reason = trim(p_reason) where id = active_fulfilment_line.id;
    update app.fulfilments set corrected_at = timezone('utc', now()), correction_reason = trim(p_reason)
    where id = active_fulfilment_line.fulfilment_id;
    update app.inventory_reservations set
      status = case when p_target_status = 'ready_for_pickup' then 'reserved'::app.reservation_status else 'released'::app.reservation_status end,
      updated_at = timezone('utc', now())
    where id = active_fulfilment_line.reservation_id and status = 'fulfilled';
    if not found then raise exception 'FULFILLED_RESERVATION_NOT_FOUND' using errcode = '23514'; end if;
    update app.order_lines set status = p_target_status, updated_at = timezone('utc', now()) where id = line_id;
    if not line_record.order_id = any(affected_orders) then affected_orders := array_append(affected_orders, line_record.order_id); end if;
    corrected_count := corrected_count + 1;
  end loop;

  foreach line_id in array affected_orders loop
    perform app.refresh_order_status(line_id);
    insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
    values(actor, 'fulfilment.corrected', 'member_order', line_id,
      jsonb_build_object('order_line_ids', p_order_line_ids, 'target_status', p_target_status::text, 'reason', trim(p_reason)));
  end loop;
  return jsonb_build_object('correctedLines', corrected_count, 'targetStatus', p_target_status::text);
end;
$$;

revoke all on function app.get_catalog_order_workspace() from public, anon;
revoke all on function app.get_fulfilment_corrections_workspace() from public, anon;
revoke all on function app.upsert_catalog_article(uuid, text, text, text, boolean, integer, uuid[]) from public, anon;
revoke all on function app.upsert_catalog_variant(uuid, uuid, text, text, boolean, integer) from public, anon;
revoke all on function app.save_member_order(uuid, uuid, integer, jsonb) from public, anon;
revoke all on function app.get_order_qr_rotation_context(uuid, uuid) from public, anon, authenticated;
revoke all on function app.rotate_order_qr(uuid, uuid, integer, text, text) from public, anon, authenticated;
revoke all on function app.revoke_order_qr(uuid, uuid, text) from public, anon, authenticated;
revoke all on function app.correct_fulfilment(uuid[], app.order_line_status, text) from public, anon;

grant execute on function app.get_catalog_order_workspace() to authenticated;
grant execute on function app.get_fulfilment_corrections_workspace() to authenticated;
grant execute on function app.upsert_catalog_article(uuid, text, text, text, boolean, integer, uuid[]) to authenticated;
grant execute on function app.upsert_catalog_variant(uuid, uuid, text, text, boolean, integer) to authenticated;
grant execute on function app.save_member_order(uuid, uuid, integer, jsonb) to authenticated;
grant execute on function app.get_order_qr_rotation_context(uuid, uuid) to service_role;
grant execute on function app.rotate_order_qr(uuid, uuid, integer, text, text) to service_role;
grant execute on function app.revoke_order_qr(uuid, uuid, text) to service_role;
grant execute on function app.correct_fulfilment(uuid[], app.order_line_status, text) to authenticated;

grant usage on schema app to service_role;
grant select on app.article_seasons to authenticated;
revoke insert, update, delete on app.article_seasons from authenticated;

revoke execute on function app.store_order_qr(uuid, text, integer) from authenticated;
revoke execute on function app.record_manual_payment_with_qr(uuid, app.payment_method, text, text) from authenticated;

create or replace function app.record_manual_payment_with_qr_trusted(
  p_actor_id uuid,
  p_order_id uuid,
  p_method app.payment_method,
  p_idempotency_key text,
  p_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare target_order app.member_orders%rowtype; payment_id uuid; qr_version integer;
begin
  if p_actor_id is null or not exists(
    select 1 from app.staff_profiles where auth_user_id = p_actor_id and active = true
      and role in ('beheerder', 'kledingcommissie')
  ) then raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501'; end if;
  if p_method not in ('cash', 'card') or length(trim(p_idempotency_key)) not between 8 and 160
    or p_token_hash !~ '^[0-9a-f]{64}$'
  then raise exception 'INVALID_MANUAL_PAYMENT' using errcode = '22023'; end if;
  select * into target_order from app.member_orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  if exists(select 1 from app.payments where order_id = p_order_id and status = 'paid') then
    raise exception 'ORDER_ALREADY_PAID' using errcode = '23505';
  end if;
  insert into app.payments(order_id, method, status, amount_cents, idempotency_key, paid_at)
  values(p_order_id, p_method, 'paid', target_order.amount_due_cents, trim(p_idempotency_key), timezone('utc', now()))
  returning id into payment_id;
  select coalesce(max(version), 0) + 1 into qr_version from private.qr_tokens where order_id = p_order_id;
  insert into private.qr_tokens(order_id, token_hash, version, created_by)
  values(p_order_id, p_token_hash, qr_version, p_actor_id);
  perform app.refresh_order_status(p_order_id);
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(p_actor_id, 'payment.manual.recorded', 'member_order', p_order_id,
    jsonb_build_object('payment_id', payment_id, 'method', p_method::text, 'amount_cents', target_order.amount_due_cents));
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(p_actor_id, 'qr.created', 'member_order', p_order_id, jsonb_build_object('version', qr_version));
  return jsonb_build_object('paymentId', payment_id, 'status', 'paid', 'amountCents', target_order.amount_due_cents,
    'method', p_method::text, 'qrStatus', 'active', 'qrVersion', qr_version);
end;
$$;

revoke all on function app.record_manual_payment_with_qr_trusted(uuid, uuid, app.payment_method, text, text)
from public, anon, authenticated;
grant execute on function app.record_manual_payment_with_qr_trusted(uuid, uuid, app.payment_method, text, text)
to service_role;

create or replace function public.get_parent_members(p_token_hash text)
returns table (
  member_id uuid,
  relation_number text,
  first_name text,
  insertion text,
  last_name text,
  team text,
  order_id uuid,
  amount_due_cents integer,
  payment_status text,
  order_status text,
  article_lines jsonb,
  qr_version integer
)
language sql
security definer
set search_path = private, app, pg_temp
as $$
  select member.id, member.relation_number, member.first_name, member.insertion, member.last_name, member.team,
    orders.id, orders.amount_due_cents,
    coalesce((select payment.status::text from app.payments payment where payment.order_id = orders.id order by payment.created_at desc limit 1), 'open'),
    orders.order_status,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', line.id, 'article', article.name, 'size', line.size_snapshot,
        'quantity', line.quantity, 'status', line.status::text
      ) order by article.sort_order, line.size_snapshot)
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = orders.id and line.status <> 'cancelled'
    ), '[]'::jsonb),
    (select token.version from private.qr_tokens token where token.order_id = orders.id and token.active = true limit 1)
  from private.parent_sessions session
  join private.parent_member_links link on link.parent_account_id = session.parent_account_id and link.unlinked_at is null
  join app.members member on member.id = link.member_id and member.active_for_season = true
  left join app.member_orders orders on orders.member_id = member.id
  where session.token_hash = p_token_hash and session.revoked_at is null and session.expires_at > timezone('utc', now());
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
    insert into app.audit_logs(actor_user_id, action, entity_type, metadata)
    values(actor, 'qr.lookup', 'member_order', jsonb_build_object('result', 'invalid'));
    return jsonb_build_object('status', 'invalid');
  end if;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(actor, 'qr.lookup', 'member_order', target_order, jsonb_build_object('result', 'found'));
  return jsonb_build_object(
    'status', 'found',
    'orderId', target_order,
    'paid', exists(select 1 from app.payments where order_id = target_order and status = 'paid'),
    'member', (
      select jsonb_build_object('name', concat_ws(' ', member.first_name, member.insertion, member.last_name),
        'team', member.team, 'relationNumberSuffix', right(member.relation_number, 4))
      from app.member_orders orders join app.members member on member.id = orders.member_id
      where orders.id = target_order
    ),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', line.id, 'article', article.name, 'size', line.size_snapshot, 'status', line.status::text
      ) order by article.sort_order)
      from app.order_lines line
      join app.articles article on article.id = line.article_id
      where line.order_id = target_order and line.status <> 'cancelled'
    ), '[]'::jsonb)
  );
end;
$$;

alter function app.get_member_detail(uuid) rename to get_member_detail_before_catalog;
revoke all on function app.get_member_detail_before_catalog(uuid) from public, anon, authenticated;

create function app.get_member_detail(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare result jsonb; visible_lines jsonb;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  result := app.get_member_detail_before_catalog(p_member_id);
  if result->'order' is null or jsonb_typeof(result->'order') = 'null' then return result; end if;
  select coalesce(jsonb_agg(line), '[]'::jsonb) into visible_lines
  from jsonb_array_elements(result #> '{order,lines}') line
  where line->>'status' <> 'cancelled';
  return jsonb_set(result, '{order,lines}', visible_lines, false);
end;
$$;

revoke all on function app.get_member_detail(uuid) from public, anon;
grant execute on function app.get_member_detail(uuid) to authenticated;
