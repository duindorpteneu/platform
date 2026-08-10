-- Serialize every size-profile mutation with dynamic-import member locks.
-- A member-level advisory key also protects an absent size row, which ordinary
-- row locks cannot do.

create or replace function private.lock_member_size_mutation()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  member_id uuid;
begin
  for member_id in
    select distinct candidate
    from unnest(array[
      case when tg_op in ('UPDATE', 'DELETE') then old.member_id else null end,
      case when tg_op in ('INSERT', 'UPDATE') then new.member_id else null end
    ]) candidate
    where candidate is not null
    order by candidate
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('dynamic-import-member:' || member_id::text, 0)
    );
  end loop;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function private.lock_member_size_mutation()
from public, anon, authenticated, service_role;

create trigger member_article_sizes_00_lock_member
before insert or update or delete on app.member_article_sizes
for each row execute function private.lock_member_size_mutation();

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
  if p_member_id is null
    or p_season_id is null
    or p_expected_revision is null
    or p_expected_revision !~ '^[0-9a-f]{64}$'
    or p_sizes is null
    or jsonb_typeof(p_sizes) <> 'array'
    or jsonb_array_length(p_sizes) > 25
  then
    raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('dynamic-import-member:' || p_member_id::text, 0)
  );
  if not exists(
    select 1
    from app.members member
    where member.id = p_member_id
      and member.active_for_season
    for update
  ) then
    if exists(
      select 1 from app.members member where member.id = p_member_id
    ) then
      raise exception 'MEMBER_NOT_ACTIVE' using errcode = '23514';
    end if;
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists(
    select 1
    from app.app_settings settings
    join app.seasons season on season.id = settings.active_season_id
    where settings.id = true
      and season.id = p_season_id
      and season.status = 'open'
  ) then
    raise exception 'SEASON_NOT_OPEN' using errcode = '23514';
  end if;

  perform 1
  from app.member_article_sizes size_profile
  where size_profile.member_id = p_member_id
    and size_profile.season_id = p_season_id
  for update;
  perform 1
  from app.member_orders orders
  where orders.member_id = p_member_id
    and orders.season_id = p_season_id
  for update;

  if private.member_size_revision(p_member_id, p_season_id)
    <> p_expected_revision
  then
    raise exception 'MEMBER_SIZES_CONFLICT' using errcode = '40001';
  end if;
  if (
    select count(distinct entry->>'articleId')
    from jsonb_array_elements(p_sizes) entry
  ) <> jsonb_array_length(p_sizes) then
    raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023';
  end if;

  for item in select value from jsonb_array_elements(p_sizes)
  loop
    if jsonb_typeof(item) <> 'object'
      or not (item ? 'articleId' and item ? 'variantId')
      or (select count(*) from jsonb_object_keys(item)) <> 2
      or (item->>'articleId') !~ '^[0-9a-fA-F-]{36}$'
      or (
        item->'variantId' <> 'null'::jsonb
        and (item->>'variantId') !~ '^[0-9a-fA-F-]{36}$'
      )
    then
      raise exception 'MEMBER_SIZES_INVALID' using errcode = '22023';
    end if;
    target_article_id := (item->>'articleId')::uuid;
    target_variant_id := nullif(item->>'variantId', '')::uuid;

    if not exists(
      select 1
      from app.articles article
      join app.article_seasons link
        on link.article_id = article.id
        and link.season_id = p_season_id
      where article.id = target_article_id
        and article.active
    ) then
      raise exception 'MEMBER_SIZE_ARTICLE_INVALID' using errcode = '22023';
    end if;
    if target_variant_id is not null
      and not exists(
        select 1
        from app.article_variants variant
        where variant.id = target_variant_id
          and variant.article_id = target_article_id
          and variant.active
      )
    then
      raise exception 'MEMBER_SIZE_VARIANT_INVALID' using errcode = '22023';
    end if;

    select line.article_variant_id into current_order_variant_id
    from app.member_orders orders
    join app.order_lines line on line.order_id = orders.id
    where orders.member_id = p_member_id
      and orders.season_id = p_season_id
      and line.article_id = target_article_id
      and line.status <> 'cancelled'
    limit 1;
    if found
      and current_order_variant_id is distinct from target_variant_id
    then
      raise exception 'MEMBER_SIZE_ORDER_LINE_IMMUTABLE'
        using errcode = '23514';
    end if;
    if found then continue; end if;

    if target_variant_id is null then
      delete from app.member_article_sizes size_profile
      where size_profile.member_id = p_member_id
        and size_profile.season_id = p_season_id
        and size_profile.article_id = target_article_id;
    else
      insert into app.member_article_sizes(
        member_id,
        season_id,
        article_id,
        article_variant_id,
        created_by,
        updated_by
      )
      values(
        p_member_id,
        p_season_id,
        target_article_id,
        target_variant_id,
        actor,
        actor
      )
      on conflict(member_id, season_id, article_id) do update
      set article_variant_id = excluded.article_variant_id,
          updated_by = actor,
          updated_at = timezone('utc', now())
      where app.member_article_sizes.article_variant_id
        is distinct from excluded.article_variant_id;
    end if;
    if found then
      changed_article_ids := array_append(
        changed_article_ids,
        target_article_id
      );
    end if;
  end loop;

  if cardinality(changed_article_ids) > 0 then
    insert into app.audit_logs(
      actor_user_id,
      action,
      entity_type,
      entity_id,
      metadata,
      correlation_id
    )
    values(
      actor,
      'member.sizes.updated',
      'member',
      p_member_id,
      jsonb_build_object(
        'seasonId', p_season_id,
        'articleIds', to_jsonb(changed_article_ids),
        'changedCount', cardinality(changed_article_ids)
      ),
      p_correlation_id
    );
  end if;
  return private.member_size_profile_json(p_member_id);
end;
$$;

create or replace function app.sync_member_size_from_order_line()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_member_id uuid;
  target_season_id uuid;
  target_member_season_id uuid;
  existing_size app.member_article_sizes%rowtype;
begin
  if new.status = 'cancelled' then return new; end if;

  select orders.member_id, orders.season_id, orders.member_season_id
  into target_member_id, target_season_id, target_member_season_id
  from app.member_orders orders
  where orders.id = new.order_id;

  if not exists(
    select 1
    from app.article_seasons link
    where link.article_id = new.article_id
      and link.season_id = target_season_id
  ) then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'dynamic-import-member:' || target_member_id::text,
      0
    )
  );
  select * into existing_size
  from app.member_article_sizes size_profile
  where size_profile.member_id = target_member_id
    and size_profile.season_id = target_season_id
    and size_profile.article_id = new.article_id
  for update;

  if found
    and existing_size.article_variant_id is distinct from new.article_variant_id
    and existing_size.selection_status in (
      'confirmed',
      'change_requested',
      'locked'
    )
  then
    raise exception 'CONFIRMED_SIZE_CHANGE_REQUIRES_WORKFLOW'
      using errcode = '23514';
  end if;
  if found and existing_size.selection_status = 'conflict' then
    raise exception 'SIZE_CONFLICT_MUST_BE_RESOLVED' using errcode = '23514';
  end if;

  insert into app.member_article_sizes(
    member_id,
    season_id,
    member_season_id,
    article_id,
    article_variant_id,
    selection_status,
    selection_source,
    confirmed_at,
    created_by,
    updated_by
  )
  values(
    target_member_id,
    target_season_id,
    target_member_season_id,
    new.article_id,
    new.article_variant_id,
    'confirmed',
    'order',
    timezone('utc', now()),
    auth.uid(),
    auth.uid()
  )
  on conflict(member_id, season_id, article_id) do update
  set article_variant_id = excluded.article_variant_id,
      selection_status = 'confirmed',
      selection_source = 'order',
      raw_value = null,
      member_note = null,
      confirmed_at = excluded.confirmed_at,
      confirmed_by = auth.uid(),
      updated_by = auth.uid(),
      updated_at = timezone('utc', now())
  where app.member_article_sizes.selection_status = 'imported_unconfirmed'
    or app.member_article_sizes.article_variant_id = excluded.article_variant_id;
  return new;
end;
$$;

notify pgrst, 'reload schema';
