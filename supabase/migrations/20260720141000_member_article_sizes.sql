create table app.member_article_sizes (
  member_id uuid not null references app.members(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  article_id uuid not null,
  article_variant_id uuid not null,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  primary key (member_id, season_id, article_id),
  foreign key (article_id, season_id) references app.article_seasons(article_id, season_id) on delete restrict,
  foreign key (article_variant_id, article_id) references app.article_variants(id, article_id) on delete restrict
);

create index member_article_sizes_season_member_idx on app.member_article_sizes(season_id, member_id);
create index member_article_sizes_variant_idx on app.member_article_sizes(article_variant_id);

alter table app.member_article_sizes enable row level security;
create policy "clothing staff can read member sizes" on app.member_article_sizes
for select using (app.staff_role() in ('beheerder', 'kledingcommissie'));

revoke all on table app.member_article_sizes from public, anon, authenticated;
grant select on table app.member_article_sizes to authenticated;

insert into app.member_article_sizes(member_id, season_id, article_id, article_variant_id)
select orders.member_id, orders.season_id, line.article_id, line.article_variant_id
from app.member_orders orders
join app.order_lines line on line.order_id = orders.id and line.status <> 'cancelled'
join app.article_seasons link on link.article_id = line.article_id and link.season_id = orders.season_id
on conflict(member_id, season_id, article_id) do update
set article_variant_id = excluded.article_variant_id,
    updated_at = timezone('utc', now());

create or replace function private.require_clothing_aal2()
returns uuid
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare actor uuid := auth.uid();
begin
  if actor is null or coalesce(auth.jwt()->>'aal', '') <> 'aal2' or not exists (
    select 1 from app.staff_profiles
    where auth_user_id = actor and active = true and role in ('beheerder', 'kledingcommissie')
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return actor;
end;
$$;

create or replace function private.member_size_revision(p_member_id uuid, p_season_id uuid)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest(concat_ws('|',
    'member-sizes-v1', p_member_id::text, p_season_id::text,
    coalesce((select member.active_for_season::text from app.members member where member.id = p_member_id), ''),
    coalesce((select season.status::text from app.seasons season where season.id = p_season_id), ''),
    coalesce((
      select string_agg(link.article_id::text || ':' || article.active::text, ',' order by link.article_id)
      from app.article_seasons link
      join app.articles article on article.id = link.article_id
      where link.season_id = p_season_id
    ), ''),
    coalesce((
      select string_agg(variant.id::text || ':' || variant.article_id::text || ':' || variant.active::text,
        ',' order by variant.id)
      from app.article_variants variant
      where exists(select 1 from app.article_seasons link where link.season_id = p_season_id and link.article_id = variant.article_id)
    ), ''),
    coalesce((
      select string_agg(size.article_id::text || ':' || size.article_variant_id::text, ',' order by size.article_id)
      from app.member_article_sizes size
      where size.member_id = p_member_id and size.season_id = p_season_id
    ), ''),
    coalesce((
      select string_agg(line.article_id::text || ':' || line.article_variant_id::text || ':' || line.status::text,
        ',' order by line.article_id, line.id)
      from app.member_orders orders
      join app.order_lines line on line.order_id = orders.id and line.status <> 'cancelled'
      where orders.member_id = p_member_id and orders.season_id = p_season_id
    ), '')
  ), 'sha256'), 'hex');
$$;

create or replace function private.member_size_profile_json(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_season_id uuid;
  target_season_name text;
  target_season_status app.season_status;
  member_active boolean;
begin
  select member.active_for_season into member_active from app.members member where member.id = p_member_id;
  if not found then raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002'; end if;

  select season.id, season.name, season.status
  into target_season_id, target_season_name, target_season_status
  from app.app_settings settings
  join app.seasons season on season.id = settings.active_season_id
  where settings.id = true;

  if target_season_id is null then return null; end if;

  return jsonb_build_object(
    'seasonId', target_season_id,
    'seasonName', target_season_name,
    'editable', member_active and target_season_status = 'open',
    'revision', private.member_size_revision(p_member_id, target_season_id),
    'articles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', article.id,
        'name', article.name,
        'code', article.code,
        'active', article.active,
        'selectedVariantId', coalesce(order_line.article_variant_id, size.article_variant_id),
        'ordered', order_line.id is not null,
        'orderLineStatus', order_line.status,
        'variants', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', variant.id,
            'size', variant.size,
            'active', variant.active
          ) order by variant.sort_order, lower(variant.size), variant.id)
          from app.article_variants variant
          where variant.article_id = article.id
            and (variant.active or variant.id = coalesce(order_line.article_variant_id, size.article_variant_id))
        ), '[]'::jsonb)
      ) order by article.sort_order, lower(article.name), article.id)
      from app.article_seasons link
      join app.articles article on article.id = link.article_id
      left join app.member_article_sizes size
        on size.member_id = p_member_id and size.season_id = target_season_id and size.article_id = article.id
      left join lateral (
        select line.id, line.article_variant_id, line.status
        from app.member_orders orders
        join app.order_lines line on line.order_id = orders.id
        where orders.member_id = p_member_id and orders.season_id = target_season_id
          and line.article_id = article.id and line.status <> 'cancelled'
        order by line.created_at desc, line.id desc limit 1
      ) order_line on true
      where link.season_id = target_season_id
        and (article.active or size.article_id is not null or order_line.id is not null)
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.get_member_detail_v2(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare result jsonb;
begin
  perform private.require_clothing_aal2();
  result := app.get_member_detail(p_member_id);
  return result || jsonb_build_object('sizeProfile', private.member_size_profile_json(p_member_id));
end;
$$;

create or replace function app.set_member_article_sizes(
  p_member_id uuid,
  p_season_id uuid,
  p_sizes jsonb,
  p_expected_revision text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  item jsonb;
  target_article_id uuid;
  target_variant_id uuid;
  current_order_variant_id uuid;
  changed_article_ids uuid[] := array[]::uuid[];
begin
  actor := private.require_clothing_aal2();
  if p_member_id is null or p_season_id is null or p_expected_revision !~ '^[0-9a-f]{64}$'
    or jsonb_typeof(p_sizes) <> 'array' or jsonb_array_length(p_sizes) > 25
  then raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023'; end if;
  if not exists(select 1 from app.members where id = p_member_id and active_for_season = true for update) then
    if exists(select 1 from app.members where id = p_member_id) then
      raise exception 'MEMBER_NOT_ACTIVE' using errcode = '23514';
    end if;
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists(
    select 1 from app.app_settings settings
    join app.seasons season on season.id = settings.active_season_id
    where settings.id = true and season.id = p_season_id and season.status = 'open'
  ) then raise exception 'SEASON_NOT_OPEN' using errcode = '23514'; end if;

  perform 1 from app.member_article_sizes
  where member_id = p_member_id and season_id = p_season_id for update;
  perform 1 from app.member_orders orders
  where orders.member_id = p_member_id and orders.season_id = p_season_id for update;

  if private.member_size_revision(p_member_id, p_season_id) <> p_expected_revision then
    raise exception 'MEMBER_SIZES_CONFLICT' using errcode = '40001';
  end if;
  if (select count(distinct entry->>'articleId') from jsonb_array_elements(p_sizes) entry) <> jsonb_array_length(p_sizes) then
    raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023';
  end if;

  for item in select value from jsonb_array_elements(p_sizes)
  loop
    if jsonb_typeof(item) <> 'object' or not (item ? 'articleId' and item ? 'variantId')
      or (select count(*) from jsonb_object_keys(item)) <> 2
      or (item->>'articleId') !~ '^[0-9a-fA-F-]{36}$'
      or (item->'variantId' <> 'null'::jsonb and (item->>'variantId') !~ '^[0-9a-fA-F-]{36}$')
    then raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023'; end if;
    target_article_id := (item->>'articleId')::uuid;
    target_variant_id := nullif(item->>'variantId', '')::uuid;

    if not exists(
      select 1 from app.articles article
      join app.article_seasons link on link.article_id = article.id and link.season_id = p_season_id
      where article.id = target_article_id and article.active
    ) then raise exception 'MEMBER_SIZE_ARTICLE_INVALID' using errcode = '22023'; end if;
    if target_variant_id is not null and not exists(
      select 1 from app.article_variants variant
      where variant.id = target_variant_id and variant.article_id = target_article_id and variant.active
    ) then raise exception 'MEMBER_SIZE_VARIANT_INVALID' using errcode = '22023'; end if;

    select line.article_variant_id into current_order_variant_id
    from app.member_orders orders
    join app.order_lines line on line.order_id = orders.id
    where orders.member_id = p_member_id and orders.season_id = p_season_id
      and line.article_id = target_article_id and line.status <> 'cancelled'
    limit 1;
    if found and current_order_variant_id is distinct from target_variant_id then
      raise exception 'MEMBER_SIZE_ORDER_LINE_IMMUTABLE' using errcode = '23514';
    end if;
    if found then continue; end if;

    if target_variant_id is null then
      delete from app.member_article_sizes
      where member_id = p_member_id and season_id = p_season_id and article_id = target_article_id;
    else
      insert into app.member_article_sizes(member_id, season_id, article_id, article_variant_id, created_by, updated_by)
      values(p_member_id, p_season_id, target_article_id, target_variant_id, actor, actor)
      on conflict(member_id, season_id, article_id) do update
      set article_variant_id = excluded.article_variant_id,
          updated_by = actor,
          updated_at = timezone('utc', now())
      where app.member_article_sizes.article_variant_id is distinct from excluded.article_variant_id;
    end if;
    if found then changed_article_ids := array_append(changed_article_ids, target_article_id); end if;
  end loop;

  if cardinality(changed_article_ids) > 0 then
    insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
    values(actor, 'member.sizes.updated', 'member', p_member_id, jsonb_build_object(
      'seasonId', p_season_id, 'articleIds', to_jsonb(changed_article_ids), 'changedCount', cardinality(changed_article_ids)
    ), p_correlation_id);
  end if;
  return private.member_size_profile_json(p_member_id);
end;
$$;

create or replace function app.sync_member_size_from_order_line()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare target_member_id uuid; target_season_id uuid;
begin
  if new.status = 'cancelled' then return new; end if;
  select orders.member_id, orders.season_id into target_member_id, target_season_id
  from app.member_orders orders where orders.id = new.order_id;
  if not exists(
    select 1 from app.article_seasons link
    where link.article_id = new.article_id and link.season_id = target_season_id
  ) then return new; end if;
  insert into app.member_article_sizes(member_id, season_id, article_id, article_variant_id, created_by, updated_by)
  values(target_member_id, target_season_id, new.article_id, new.article_variant_id, auth.uid(), auth.uid())
  on conflict(member_id, season_id, article_id) do update
  set article_variant_id = excluded.article_variant_id,
      updated_by = auth.uid(),
      updated_at = timezone('utc', now());
  return new;
end;
$$;

create trigger order_lines_sync_member_size
after insert or update of article_variant_id, status on app.order_lines
for each row execute function app.sync_member_size_from_order_line();

create or replace function app.protect_profile_variant_identity()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  if (new.size is distinct from old.size or new.article_id is distinct from old.article_id)
    and exists(select 1 from app.member_article_sizes size where size.article_variant_id = old.id)
  then raise exception 'PROFILE_VARIANT_IDENTITY_IMMUTABLE' using errcode = '23514'; end if;
  return new;
end;
$$;

create trigger article_variants_protect_profile_identity
before update of size, article_id on app.article_variants
for each row execute function app.protect_profile_variant_identity();

revoke all on function private.require_clothing_aal2() from public, anon, authenticated;
revoke all on function private.member_size_revision(uuid,uuid) from public, anon, authenticated;
revoke all on function private.member_size_profile_json(uuid) from public, anon, authenticated;
revoke all on function app.get_member_detail_v2(uuid) from public, anon;
revoke all on function app.set_member_article_sizes(uuid,uuid,jsonb,text,uuid) from public, anon;
revoke all on function app.sync_member_size_from_order_line() from public, anon, authenticated;
revoke all on function app.protect_profile_variant_identity() from public, anon, authenticated;
grant execute on function app.get_member_detail_v2(uuid) to authenticated;
grant execute on function app.set_member_article_sizes(uuid,uuid,jsonb,text,uuid) to authenticated;
