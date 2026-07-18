create or replace function app.get_member_list(
  p_search text default null,
  p_team text default null,
  p_payment_filter text default null,
  p_order_status text default null,
  p_article_id uuid default null,
  p_size text default null,
  p_line_status app.order_line_status default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare
  active_season_id uuid;
  active_season_name text;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_limit < 1 or p_limit > 100 or p_offset < 0 or p_offset > 100000 then
    raise exception 'INVALID_MEMBER_LIST_PAGE' using errcode = '22023';
  end if;
  if length(coalesce(p_search, '')) > 120 or length(coalesce(p_team, '')) > 120 or length(coalesce(p_size, '')) > 80 then
    raise exception 'INVALID_MEMBER_LIST_FILTER' using errcode = '22023';
  end if;
  if p_payment_filter is not null and p_payment_filter not in ('paid', 'unpaid', 'no_order') then
    raise exception 'INVALID_PAYMENT_FILTER' using errcode = '22023';
  end if;
  if p_order_status is not null and p_order_status not in (
    'Nog niet betaald', 'Nalevering', 'Gedeeltelijk af te halen',
    'Volledig af te halen', 'Gedeeltelijk afgehaald', 'Afgerond'
  ) then
    raise exception 'INVALID_ORDER_STATUS_FILTER' using errcode = '22023';
  end if;

  select s.id, s.name into active_season_id, active_season_name
  from app.app_settings settings
  join app.seasons s on s.id = settings.active_season_id
  where settings.id = true
  limit 1;

  return (
    with base as (
      select
        m.id,
        m.relation_number,
        m.first_name,
        m.insertion,
        m.last_name,
        m.team,
        m.active_for_season,
        m.updated_at as member_updated_at,
        mo.id as order_id,
        mo.amount_due_cents,
        mo.order_status,
        mo.updated_at as order_updated_at,
        exists (
          select 1 from app.payments p
          where p.order_id = mo.id and p.status = 'paid'
        ) as paid,
        coalesce(sum(ol.quantity) filter (where ol.status in ('ready_for_pickup', 'picked_up')), 0)::integer as progress_quantity,
        coalesce(sum(ol.quantity) filter (where ol.status <> 'cancelled'), 0)::integer as total_quantity
      from app.members m
      left join app.member_orders mo on mo.member_id = m.id and mo.season_id = active_season_id
      left join app.order_lines ol on ol.order_id = mo.id
      where (
        nullif(trim(p_search), '') is null
        or concat_ws(' ', m.first_name, m.insertion, m.last_name) ilike '%' || trim(p_search) || '%'
        or m.team ilike '%' || trim(p_search) || '%'
        or m.relation_number ilike '%' || trim(p_search) || '%'
      )
      and (nullif(trim(p_team), '') is null or m.team = trim(p_team))
      and (
        p_payment_filter is null
        or (p_payment_filter = 'paid' and mo.id is not null and exists (
          select 1 from app.payments p where p.order_id = mo.id and p.status = 'paid'
        ))
        or (p_payment_filter = 'unpaid' and mo.id is not null and not exists (
          select 1 from app.payments p where p.order_id = mo.id and p.status = 'paid'
        ))
        or (p_payment_filter = 'no_order' and mo.id is null)
      )
      and (p_order_status is null or mo.order_status = p_order_status)
      and (
        p_article_id is null
        or exists (
          select 1
          from app.order_lines filter_line
          join app.article_variants filter_variant on filter_variant.id = filter_line.article_variant_id
          where filter_line.order_id = mo.id and filter_variant.article_id = p_article_id
        )
      )
      and (
        nullif(trim(p_size), '') is null
        or exists (
          select 1
          from app.order_lines filter_line
          join app.article_variants filter_variant on filter_variant.id = filter_line.article_variant_id
          where filter_line.order_id = mo.id and filter_variant.size = trim(p_size)
        )
      )
      and (
        p_line_status is null
        or exists (
          select 1 from app.order_lines filter_line
          where filter_line.order_id = mo.id and filter_line.status = p_line_status
        )
      )
      group by m.id, mo.id
    ),
    page as (
      select *
      from base
      order by active_for_season desc, greatest(member_updated_at, coalesce(order_updated_at, member_updated_at)) desc,
        lower(last_name), lower(first_name), relation_number
      limit p_limit offset p_offset
    )
    select jsonb_build_object(
      'activeSeason', case when active_season_id is null then null else jsonb_build_object('id', active_season_id, 'name', active_season_name) end,
      'totalCount', (select count(*)::integer from app.members),
      'activeCount', (select count(*)::integer from app.members where active_for_season = true),
      'filteredCount', (select count(*)::integer from base),
      'filterOptions', jsonb_build_object(
        'teams', coalesce((
          select jsonb_agg(team order by lower(team))
          from (select distinct team from app.members where trim(team) <> '') teams
        ), '[]'::jsonb),
        'articles', coalesce((
          select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, lower(name))
          from app.articles where active = true
        ), '[]'::jsonb),
        'sizes', coalesce((
          select jsonb_agg(size order by lower(size))
          from (select distinct size from app.article_variants where active = true and trim(size) <> '') sizes
        ), '[]'::jsonb)
      ),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', id,
          'memberName', concat_ws(' ', first_name, insertion, last_name),
          'relationNumber', relation_number,
          'team', team,
          'activeForSeason', active_for_season,
          'updatedAt', greatest(member_updated_at, coalesce(order_updated_at, member_updated_at)),
          'order', case when order_id is null then null else jsonb_build_object(
            'id', order_id,
            'amountDueCents', amount_due_cents,
            'paymentStatus', case when paid then 'Betaald' else 'Nog te betalen' end,
            'orderStatus', order_status,
            'progressQuantity', progress_quantity,
            'totalQuantity', total_quantity
          ) end
        ) order by active_for_season desc, greatest(member_updated_at, coalesce(order_updated_at, member_updated_at)) desc,
          lower(last_name), lower(first_name), relation_number)
        from page
      ), '[]'::jsonb)
    )
  );
end;
$$;

create or replace function app.get_member_detail(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  active_season_id uuid;
  active_season_name text;
  target_member app.members%rowtype;
  target_order app.member_orders%rowtype;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_member_id is null then
    raise exception 'INVALID_MEMBER_ID' using errcode = '22023';
  end if;

  select * into target_member from app.members where id = p_member_id;
  if not found then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select s.id, s.name into active_season_id, active_season_name
  from app.app_settings settings
  join app.seasons s on s.id = settings.active_season_id
  where settings.id = true
  limit 1;

  select * into target_order
  from app.member_orders
  where member_id = p_member_id and season_id = active_season_id
  limit 1;

  return jsonb_build_object(
    'id', target_member.id,
    'memberName', concat_ws(' ', target_member.first_name, target_member.insertion, target_member.last_name),
    'firstName', target_member.first_name,
    'insertion', target_member.insertion,
    'lastName', target_member.last_name,
    'relationNumber', target_member.relation_number,
    'email', target_member.email,
    'team', target_member.team,
    'activeForSeason', target_member.active_for_season,
    'updatedAt', target_member.updated_at,
    'activeSeason', case when active_season_id is null then null else jsonb_build_object('id', active_season_id, 'name', active_season_name) end,
    'parentLinks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', link.id,
        'email', account.email_normalized,
        'linkedAt', link.linked_at
      ) order by lower(account.email_normalized))
      from private.parent_member_links link
      join private.parent_accounts account on account.id = link.parent_account_id
      where link.member_id = p_member_id and link.unlinked_at is null
    ), '[]'::jsonb),
    'order', case when target_order.id is null then null else jsonb_build_object(
      'id', target_order.id,
      'amountDueCents', target_order.amount_due_cents,
      'orderStatus', target_order.order_status,
      'paymentStatus', case when exists (
        select 1 from app.payments p where p.order_id = target_order.id and p.status = 'paid'
      ) then 'Betaald' else 'Nog te betalen' end,
      'paidAt', (
        select p.paid_at from app.payments p
        where p.order_id = target_order.id and p.status = 'paid'
        order by p.paid_at desc nulls last limit 1
      ),
      'qrStatus', case
        when exists (select 1 from private.qr_tokens qr where qr.order_id = target_order.id and qr.active = true) then 'Actief'
        when exists (select 1 from private.qr_tokens qr where qr.order_id = target_order.id) then 'Ingetrokken'
        else 'Niet aangemaakt'
      end,
      'lines', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ol.id,
          'article', article.name,
          'size', variant.size,
          'quantity', ol.quantity,
          'status', ol.status::text
        ) order by article.sort_order, lower(article.name), lower(variant.size))
        from app.order_lines ol
        join app.article_variants variant on variant.id = ol.article_variant_id
        join app.articles article on article.id = variant.article_id
        where ol.order_id = target_order.id
      ), '[]'::jsonb)
    ) end,
    'activities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', activity.id,
        'action', activity.action,
        'entityType', activity.entity_type,
        'createdAt', activity.created_at
      ) order by activity.created_at desc, activity.id desc)
      from (
        select id, action, entity_type, created_at
        from app.audit_logs
        where action <> 'qr.lookup'
          and (entity_id = p_member_id or (target_order.id is not null and entity_id = target_order.id))
        order by created_at desc, id desc
        limit 10
      ) activity
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function app.get_member_list(text, text, text, text, uuid, text, app.order_line_status, integer, integer) from public, anon;
revoke all on function app.get_member_detail(uuid) from public, anon;
grant execute on function app.get_member_list(text, text, text, text, uuid, text, app.order_line_status, integer, integer) to authenticated;
grant execute on function app.get_member_detail(uuid) to authenticated;
