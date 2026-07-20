create or replace function app.preview_team_member_status(
  p_team text,
  p_active boolean
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare
  target_season_id uuid;
  normalized_team text := trim(p_team);
  total_members integer;
  changed_members integer;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_active is null or length(normalized_team) not between 1 and 120 then
    raise exception 'TEAM_STATUS_INPUT_INVALID' using errcode = '22023';
  end if;

  select season.id into target_season_id
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true;
  if target_season_id is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;

  select count(*)::integer,
    count(*) filter (where active_for_season is distinct from p_active)::integer
  into total_members, changed_members
  from app.members
  where team = normalized_team;
  if total_members = 0 then
    raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'seasonId', target_season_id,
    'team', normalized_team,
    'totalMembers', total_members,
    'changedMembers', changed_members,
    'unchangedMembers', total_members - changed_members,
    'activeForSeason', p_active,
    'committed', false
  );
end;
$$;

create or replace function app.bulk_set_team_member_status(
  p_team text,
  p_active boolean,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_season_id uuid;
  normalized_team text := trim(p_team);
  normalized_reason text := trim(p_reason);
  total_members integer;
  changed_members integer;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_active is null or length(normalized_team) not between 1 and 120
    or length(normalized_reason) not between 3 and 240
  then
    raise exception 'TEAM_STATUS_INPUT_INVALID' using errcode = '22023';
  end if;

  select season.id into target_season_id
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true
  for update of settings, season;
  if target_season_id is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;

  perform id from app.members where team = normalized_team order by id for update;
  get diagnostics total_members = row_count;
  if total_members = 0 then
    raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002';
  end if;

  with changed as (
    update app.members
    set active_for_season = p_active
    where team = normalized_team and active_for_season is distinct from p_active
    returning id
  ), audited as (
    insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
    select actor,
      case when p_active then 'member.activated' else 'member.deactivated' end,
      'member', changed.id,
      jsonb_build_object(
        'seasonId', target_season_id,
        'activeBefore', not p_active,
        'activeAfter', p_active,
        'reason', normalized_reason,
        'team', normalized_team,
        'bulk', true
      ), p_correlation_id
    from changed
    returning 1
  )
  select count(*)::integer into changed_members from audited;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor,
    case when p_active then 'member.team_bulk_activated' else 'member.team_bulk_deactivated' end,
    'season', target_season_id,
    jsonb_build_object(
      'team', normalized_team,
      'totalMembers', total_members,
      'changedMembers', changed_members,
      'unchangedMembers', total_members - changed_members,
      'reason', normalized_reason
    ), p_correlation_id);

  return jsonb_build_object(
    'seasonId', target_season_id,
    'team', normalized_team,
    'totalMembers', total_members,
    'changedMembers', changed_members,
    'unchangedMembers', total_members - changed_members,
    'activeForSeason', p_active,
    'committed', true
  );
end;
$$;

create or replace function app.preview_team_order_articles(
  p_team text,
  p_variant_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare
  target_season_id uuid;
  normalized_team text := trim(p_team);
  selected_count integer := coalesce(array_length(p_variant_ids, 1), 0);
  total_members integer;
  active_members integer;
  inactive_skipped integer;
  paid_skipped integer;
  orders_to_create integer;
  orders_to_extend integer;
  unchanged_members integer;
  lines_to_add integer;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if length(normalized_team) not between 1 and 120 or selected_count not between 1 and 25
    or selected_count <> (select count(distinct variant_id) from unnest(p_variant_ids) variant_id)
  then
    raise exception 'TEAM_ARTICLE_INPUT_INVALID' using errcode = '22023';
  end if;

  select season.id into target_season_id
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true;
  if target_season_id is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;

  if (select count(*) from app.article_variants variant
      join app.articles article on article.id = variant.article_id
      join app.article_seasons link on link.article_id = article.id and link.season_id = target_season_id
      where variant.id = any(p_variant_ids) and variant.active and article.active) <> selected_count
    or (select count(distinct variant.article_id) from app.article_variants variant where variant.id = any(p_variant_ids)) <> selected_count
  then
    raise exception 'TEAM_ARTICLE_SELECTION_INVALID' using errcode = '22023';
  end if;

  with team_members as (
    select member.id, member.active_for_season, orders.id as order_id,
      exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid') as paid
    from app.members member
    left join app.member_orders orders on orders.member_id = member.id and orders.season_id = target_season_id
    where member.team = normalized_team
  ), eligible as (
    select team_member.*,
      (select count(*)::integer
       from app.article_variants selected_variant
       where selected_variant.id = any(p_variant_ids)
         and not exists(
           select 1 from app.order_lines line
           where line.order_id = team_member.order_id
             and line.article_id = selected_variant.article_id
             and line.status <> 'cancelled'
         )) as missing_lines
    from team_members team_member
    where team_member.active_for_season and not team_member.paid
  )
  select
    (select count(*)::integer from team_members),
    (select count(*)::integer from team_members where active_for_season),
    (select count(*)::integer from team_members where not active_for_season),
    (select count(*)::integer from team_members where active_for_season and paid),
    (select count(*)::integer from eligible where order_id is null and missing_lines > 0),
    (select count(*)::integer from eligible where order_id is not null and missing_lines > 0),
    (select count(*)::integer from eligible where missing_lines = 0),
    coalesce((select sum(missing_lines)::integer from eligible), 0)
  into total_members, active_members, inactive_skipped, paid_skipped,
    orders_to_create, orders_to_extend, unchanged_members, lines_to_add;

  if total_members = 0 then
    raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'seasonId', target_season_id,
    'team', normalized_team,
    'selectedVariantCount', selected_count,
    'totalMembers', total_members,
    'activeMembers', active_members,
    'inactiveMembersSkipped', inactive_skipped,
    'paidOrdersSkipped', paid_skipped,
    'ordersCreated', orders_to_create,
    'ordersExtended', orders_to_extend,
    'unchangedMembers', unchanged_members,
    'linesAdded', lines_to_add,
    'committed', false
  );
end;
$$;

create or replace function app.bulk_add_team_order_articles(
  p_team text,
  p_variant_ids uuid[],
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_season_id uuid;
  default_amount integer;
  normalized_team text := trim(p_team);
  selected_count integer := coalesce(array_length(p_variant_ids, 1), 0);
  total_members integer;
  active_members integer := 0;
  inactive_skipped integer := 0;
  paid_skipped integer := 0;
  orders_created integer := 0;
  orders_extended integer := 0;
  unchanged_members integer := 0;
  lines_added integer := 0;
  member_record record;
  variant_record record;
  target_order_id uuid;
  existing_order boolean;
  member_lines_added integer;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if length(normalized_team) not between 1 and 120 or selected_count not between 1 and 25
    or selected_count <> (select count(distinct variant_id) from unnest(p_variant_ids) variant_id)
  then
    raise exception 'TEAM_ARTICLE_INPUT_INVALID' using errcode = '22023';
  end if;

  select season.id, season.default_amount_cents into target_season_id, default_amount
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true
  for update of settings, season;
  if target_season_id is null then
    raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514';
  end if;

  perform variant.id
  from app.article_variants variant
  join app.articles article on article.id = variant.article_id
  join app.article_seasons link on link.article_id = article.id and link.season_id = target_season_id
  where variant.id = any(p_variant_ids) and variant.active and article.active
  order by variant.id
  for share of variant, article;
  if not found
    or (select count(*) from app.article_variants variant
        join app.articles article on article.id = variant.article_id
        join app.article_seasons link on link.article_id = article.id and link.season_id = target_season_id
        where variant.id = any(p_variant_ids) and variant.active and article.active) <> selected_count
    or (select count(distinct variant.article_id) from app.article_variants variant where variant.id = any(p_variant_ids)) <> selected_count
  then
    raise exception 'TEAM_ARTICLE_SELECTION_INVALID' using errcode = '22023';
  end if;

  perform id from app.members where team = normalized_team order by id for update;
  get diagnostics total_members = row_count;
  if total_members = 0 then
    raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002';
  end if;

  for member_record in
    select member.id, member.active_for_season
    from app.members member
    where member.team = normalized_team
    order by member.id
  loop
    if not member_record.active_for_season then
      inactive_skipped := inactive_skipped + 1;
      continue;
    end if;
    active_members := active_members + 1;

    select orders.id into target_order_id
    from app.member_orders orders
    where orders.member_id = member_record.id and orders.season_id = target_season_id
    for update;
    existing_order := found;

    if existing_order and exists(
      select 1 from app.payments payment where payment.order_id = target_order_id and payment.status = 'paid'
    ) then
      paid_skipped := paid_skipped + 1;
      continue;
    end if;

    member_lines_added := 0;
    if not existing_order then
      insert into app.member_orders(member_id, season_id, amount_due_cents)
      values(member_record.id, target_season_id, default_amount)
      returning id into target_order_id;
    end if;

    for variant_record in
      select variant.id, variant.article_id
      from app.article_variants variant
      where variant.id = any(p_variant_ids)
      order by variant.article_id
    loop
      if not exists(
        select 1 from app.order_lines line
        where line.order_id = target_order_id
          and line.article_id = variant_record.article_id
          and line.status <> 'cancelled'
      ) then
        insert into app.order_lines(order_id, article_variant_id, quantity)
        values(target_order_id, variant_record.id, 1);
        member_lines_added := member_lines_added + 1;
      end if;
    end loop;

    if member_lines_added = 0 then
      unchanged_members := unchanged_members + 1;
      if not existing_order then
        raise exception 'TEAM_ARTICLE_EMPTY_NEW_ORDER' using errcode = '23514';
      end if;
    else
      lines_added := lines_added + member_lines_added;
      if existing_order then orders_extended := orders_extended + 1;
      else orders_created := orders_created + 1;
      end if;
      perform app.refresh_order_status(target_order_id);
      insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
      values(actor, 'order.team_bulk_articles_added', 'member_order', target_order_id,
        jsonb_build_object(
          'seasonId', target_season_id,
          'team', normalized_team,
          'variantIds', to_jsonb(p_variant_ids),
          'linesAdded', member_lines_added,
          'orderCreated', not existing_order
        ), p_correlation_id);
    end if;
  end loop;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'order.team_bulk_articles_completed', 'season', target_season_id,
    jsonb_build_object(
      'team', normalized_team,
      'variantIds', to_jsonb(p_variant_ids),
      'totalMembers', total_members,
      'activeMembers', active_members,
      'inactiveMembersSkipped', inactive_skipped,
      'paidOrdersSkipped', paid_skipped,
      'ordersCreated', orders_created,
      'ordersExtended', orders_extended,
      'unchangedMembers', unchanged_members,
      'linesAdded', lines_added
    ), p_correlation_id);

  return jsonb_build_object(
    'seasonId', target_season_id,
    'team', normalized_team,
    'selectedVariantCount', selected_count,
    'totalMembers', total_members,
    'activeMembers', active_members,
    'inactiveMembersSkipped', inactive_skipped,
    'paidOrdersSkipped', paid_skipped,
    'ordersCreated', orders_created,
    'ordersExtended', orders_extended,
    'unchangedMembers', unchanged_members,
    'linesAdded', lines_added,
    'committed', true
  );
end;
$$;

revoke all on function app.preview_team_member_status(text, boolean) from public, anon;
revoke all on function app.bulk_set_team_member_status(text, boolean, text, uuid) from public, anon;
revoke all on function app.preview_team_order_articles(text, uuid[]) from public, anon;
revoke all on function app.bulk_add_team_order_articles(text, uuid[], uuid) from public, anon;
grant execute on function app.preview_team_member_status(text, boolean) to authenticated;
grant execute on function app.bulk_set_team_member_status(text, boolean, text, uuid) to authenticated;
grant execute on function app.preview_team_order_articles(text, uuid[]) to authenticated;
grant execute on function app.bulk_add_team_order_articles(text, uuid[], uuid) to authenticated;

create or replace function app.get_member_team_options()
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
  return coalesce((
    select jsonb_agg(team order by lower(team))
    from (select distinct team from app.members where trim(team) <> '') options
  ), '[]'::jsonb);
end;
$$;

revoke all on function app.get_member_team_options() from public, anon;
grant execute on function app.get_member_team_options() to authenticated;
