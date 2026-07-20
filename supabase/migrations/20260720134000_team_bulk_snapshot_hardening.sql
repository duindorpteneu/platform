create or replace function private.team_member_status_revision(
  p_team text,
  p_active boolean,
  p_season_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(concat_ws('|',
    'member-status-v1', p_season_id::text, p_team, p_active::text,
    coalesce((
      select string_agg(member.id::text || ':' || member.active_for_season::text, ',' order by member.id)
      from app.members member where member.team = p_team
    ), '')
  ), 'sha256'), 'hex');
$$;

create or replace function private.team_order_articles_revision(
  p_team text,
  p_variant_ids uuid[],
  p_season_id uuid
)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(concat_ws('|',
    'team-order-articles-v1', p_season_id::text, p_team,
    coalesce((select string_agg(value::text, ',' order by value) from unnest(p_variant_ids) value), ''),
    coalesce((
      select string_agg(member.id::text || ':' || member.active_for_season::text, ',' order by member.id)
      from app.members member where member.team = p_team
    ), ''),
    coalesce((
      select string_agg(orders.id::text || ':' || orders.member_id::text || ':' ||
        (exists(select 1 from app.payments payment where payment.order_id = orders.id and payment.status = 'paid'))::text,
        ',' order by orders.member_id)
      from app.member_orders orders
      join app.members member on member.id = orders.member_id
      where member.team = p_team and orders.season_id = p_season_id
    ), ''),
    coalesce((
      select string_agg(line.order_id::text || ':' || line.article_id::text || ':' || line.status::text,
        ',' order by line.order_id, line.article_id, line.id)
      from app.order_lines line
      join app.member_orders orders on orders.id = line.order_id and orders.season_id = p_season_id
      join app.members member on member.id = orders.member_id and member.team = p_team
      where line.article_id in (
        select variant.article_id from app.article_variants variant where variant.id = any(p_variant_ids)
      )
    ), ''),
    coalesce((
      select string_agg(variant.id::text || ':' || variant.article_id::text || ':' || variant.active::text || ':' ||
        article.active::text || ':' || (exists(
          select 1 from app.article_seasons link where link.article_id = article.id and link.season_id = p_season_id
        ))::text, ',' order by variant.id)
      from app.article_variants variant
      join app.articles article on article.id = variant.article_id
      where variant.id = any(p_variant_ids)
    ), '')
  ), 'sha256'), 'hex');
$$;

revoke all on function private.team_member_status_revision(text, boolean, uuid) from public, anon, authenticated;
revoke all on function private.team_order_articles_revision(text, uuid[], uuid) from public, anon, authenticated;

create or replace function app.preview_team_member_status_v2(
  p_team text,
  p_active boolean
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare result jsonb;
begin
  select preview.value || jsonb_build_object(
    'revision', private.team_member_status_revision(
      preview.value->>'team', p_active, (preview.value->>'seasonId')::uuid
    )
  ) into result
  from (select app.preview_team_member_status(p_team, p_active) as value) preview;
  return result;
end;
$$;

create or replace function app.preview_team_order_articles_v2(
  p_team text,
  p_variant_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare result jsonb;
begin
  select preview.value || jsonb_build_object(
    'revision', private.team_order_articles_revision(
      preview.value->>'team', p_variant_ids, (preview.value->>'seasonId')::uuid
    )
  ) into result
  from (select app.preview_team_order_articles(p_team, p_variant_ids) as value) preview;
  return result;
end;
$$;

create or replace function app.bulk_set_team_member_status_v2(
  p_team text,
  p_active boolean,
  p_reason text,
  p_expected_season_id uuid,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_season_id uuid;
  normalized_team text := trim(coalesce(p_team, ''));
  normalized_reason text := trim(coalesce(p_reason, ''));
  total_members integer;
  changed_members integer;
  current_revision text;
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_active is null or length(normalized_team) not between 1 and 120
    or length(normalized_reason) not between 3 and 240
    or p_expected_season_id is null
    or coalesce(p_expected_revision, '') !~ '^[a-f0-9]{64}$'
  then raise exception 'TEAM_STATUS_INPUT_INVALID' using errcode = '22023'; end if;

  lock table app.members in share row exclusive mode;
  select season.id into target_season_id
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true
  for update of settings, season;
  if target_season_id is null then raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514'; end if;
  if target_season_id <> p_expected_season_id then
    raise exception 'TEAM_BULK_SNAPSHOT_CHANGED' using errcode = '40001';
  end if;

  select count(*)::integer into total_members from app.members where team = normalized_team;
  if total_members = 0 then raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002'; end if;
  current_revision := private.team_member_status_revision(normalized_team, p_active, target_season_id);
  if current_revision <> p_expected_revision then
    raise exception 'TEAM_BULK_SNAPSHOT_CHANGED' using errcode = '40001';
  end if;

  with changed as (
    update app.members set active_for_season = p_active
    where team = normalized_team and active_for_season is distinct from p_active
    returning id
  ), audited as (
    insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
    select actor, case when p_active then 'member.activated' else 'member.deactivated' end,
      'member', changed.id, jsonb_build_object(
        'seasonId', target_season_id, 'activeBefore', not p_active, 'activeAfter', p_active,
        'reason', normalized_reason, 'team', normalized_team, 'bulk', true
      ), p_correlation_id
    from changed returning 1
  ) select count(*)::integer into changed_members from audited;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, case when p_active then 'member.team_bulk_activated' else 'member.team_bulk_deactivated' end,
    'season', target_season_id, jsonb_build_object(
      'team', normalized_team, 'totalMembers', total_members, 'changedMembers', changed_members,
      'unchangedMembers', total_members - changed_members, 'reason', normalized_reason,
      'previewRevision', p_expected_revision
    ), p_correlation_id);

  return jsonb_build_object(
    'seasonId', target_season_id, 'team', normalized_team, 'totalMembers', total_members,
    'changedMembers', changed_members, 'unchangedMembers', total_members - changed_members,
    'activeForSeason', p_active, 'committed', true
  );
end;
$$;

create or replace function app.bulk_add_team_order_articles_v2(
  p_team text,
  p_variant_ids uuid[],
  p_expected_season_id uuid,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_season_id uuid;
  default_amount integer;
  normalized_team text := trim(coalesce(p_team, ''));
  selected_count integer := coalesce(array_length(p_variant_ids, 1), 0);
  total_members integer;
  active_members integer := 0;
  inactive_skipped integer := 0;
  paid_skipped integer := 0;
  orders_created integer := 0;
  orders_extended integer := 0;
  unchanged_members integer := 0;
  lines_added integer := 0;
  current_revision text;
  member_record record;
  variant_record record;
  target_order_id uuid;
  existing_order boolean;
  member_lines_added integer;
  added_variant_ids uuid[];
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if length(normalized_team) not between 1 and 120 or selected_count not between 1 and 25
    or selected_count <> (select count(distinct variant_id) from unnest(p_variant_ids) variant_id)
    or p_expected_season_id is null or coalesce(p_expected_revision, '') !~ '^[a-f0-9]{64}$'
  then raise exception 'TEAM_ARTICLE_INPUT_INVALID' using errcode = '22023'; end if;

  lock table app.members, app.member_orders, app.payments, app.order_lines,
    app.articles, app.article_variants, app.article_seasons in share row exclusive mode;

  select season.id, season.default_amount_cents into target_season_id, default_amount
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id and season.status = 'open'
  where settings.id = true
  for update of settings, season;
  if target_season_id is null then raise exception 'ACTIVE_SEASON_REQUIRED' using errcode = '23514'; end if;
  if target_season_id <> p_expected_season_id then
    raise exception 'TEAM_BULK_SNAPSHOT_CHANGED' using errcode = '40001';
  end if;

  if (select count(*) from app.article_variants variant
      join app.articles article on article.id = variant.article_id
      join app.article_seasons link on link.article_id = article.id and link.season_id = target_season_id
      where variant.id = any(p_variant_ids) and variant.active and article.active) <> selected_count
    or (select count(distinct variant.article_id) from app.article_variants variant where variant.id = any(p_variant_ids)) <> selected_count
  then raise exception 'TEAM_ARTICLE_SELECTION_INVALID' using errcode = '22023'; end if;

  select count(*)::integer into total_members from app.members where team = normalized_team;
  if total_members = 0 then raise exception 'TEAM_NOT_FOUND' using errcode = 'P0002'; end if;
  current_revision := private.team_order_articles_revision(normalized_team, p_variant_ids, target_season_id);
  if current_revision <> p_expected_revision then
    raise exception 'TEAM_BULK_SNAPSHOT_CHANGED' using errcode = '40001';
  end if;

  for member_record in
    select member.id, member.active_for_season from app.members member
    where member.team = normalized_team order by member.id
  loop
    if not member_record.active_for_season then inactive_skipped := inactive_skipped + 1; continue; end if;
    active_members := active_members + 1;
    target_order_id := null;
    select orders.id into target_order_id from app.member_orders orders
    where orders.member_id = member_record.id and orders.season_id = target_season_id;
    existing_order := found;
    if existing_order and exists(select 1 from app.payments payment where payment.order_id = target_order_id and payment.status = 'paid') then
      paid_skipped := paid_skipped + 1; continue;
    end if;

    member_lines_added := 0;
    added_variant_ids := '{}'::uuid[];
    if not existing_order then
      insert into app.member_orders(member_id, season_id, amount_due_cents)
      values(member_record.id, target_season_id, default_amount) returning id into target_order_id;
    end if;

    for variant_record in
      select variant.id, variant.article_id from app.article_variants variant
      where variant.id = any(p_variant_ids) order by variant.article_id
    loop
      if not exists(select 1 from app.order_lines line where line.order_id = target_order_id
        and line.article_id = variant_record.article_id and line.status <> 'cancelled')
      then
        insert into app.order_lines(order_id, article_variant_id, quantity)
        values(target_order_id, variant_record.id, 1);
        member_lines_added := member_lines_added + 1;
        added_variant_ids := array_append(added_variant_ids, variant_record.id);
      end if;
    end loop;

    if member_lines_added = 0 then
      unchanged_members := unchanged_members + 1;
      if not existing_order then raise exception 'TEAM_ARTICLE_EMPTY_NEW_ORDER' using errcode = '23514'; end if;
    else
      lines_added := lines_added + member_lines_added;
      if existing_order then orders_extended := orders_extended + 1; else orders_created := orders_created + 1; end if;
      perform app.refresh_order_status(target_order_id);
      insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
      values(actor, 'order.team_bulk_articles_added', 'member_order', target_order_id,
        jsonb_build_object(
          'seasonId', target_season_id, 'team', normalized_team,
          'addedVariantIds', to_jsonb(added_variant_ids), 'linesAdded', member_lines_added,
          'orderCreated', not existing_order, 'previewRevision', p_expected_revision
        ), p_correlation_id);
    end if;
  end loop;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'order.team_bulk_articles_completed', 'season', target_season_id,
    jsonb_build_object(
      'team', normalized_team, 'requestedVariantIds', to_jsonb(p_variant_ids),
      'totalMembers', total_members, 'activeMembers', active_members,
      'inactiveMembersSkipped', inactive_skipped, 'paidOrdersSkipped', paid_skipped,
      'ordersCreated', orders_created, 'ordersExtended', orders_extended,
      'unchangedMembers', unchanged_members, 'linesAdded', lines_added,
      'previewRevision', p_expected_revision
    ), p_correlation_id);

  return jsonb_build_object(
    'seasonId', target_season_id, 'team', normalized_team, 'selectedVariantCount', selected_count,
    'totalMembers', total_members, 'activeMembers', active_members,
    'inactiveMembersSkipped', inactive_skipped, 'paidOrdersSkipped', paid_skipped,
    'ordersCreated', orders_created, 'ordersExtended', orders_extended,
    'unchangedMembers', unchanged_members, 'linesAdded', lines_added, 'committed', true
  );
end;
$$;

revoke execute on function app.bulk_set_team_member_status(text, boolean, text, uuid) from authenticated;
revoke execute on function app.bulk_add_team_order_articles(text, uuid[], uuid) from authenticated;
revoke all on function app.preview_team_member_status_v2(text, boolean) from public, anon;
revoke all on function app.preview_team_order_articles_v2(text, uuid[]) from public, anon;
revoke all on function app.bulk_set_team_member_status_v2(text, boolean, text, uuid, text, uuid) from public, anon;
revoke all on function app.bulk_add_team_order_articles_v2(text, uuid[], uuid, text, uuid) from public, anon;
grant execute on function app.preview_team_member_status_v2(text, boolean) to authenticated;
grant execute on function app.preview_team_order_articles_v2(text, uuid[]) to authenticated;
grant execute on function app.bulk_set_team_member_status_v2(text, boolean, text, uuid, text, uuid) to authenticated;
grant execute on function app.bulk_add_team_order_articles_v2(text, uuid[], uuid, text, uuid) to authenticated;
