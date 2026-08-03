-- Serialize catalog and season-link mutations with dynamic-import catalog
-- snapshots. All participants acquire season locks first and article locks
-- second, with UUIDs sorted inside each class.

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
declare
  actor uuid := auth.uid();
  target_id uuid;
  season_id uuid;
begin
  if actor is null
    or app.staff_role() not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if length(trim(p_name)) not between 1 and 120
    or upper(trim(p_code)) !~ '^[A-Z0-9_-]{2,24}$'
    or p_icon_type not in ('shirt', 'package', 'circle-dot')
    or p_sort_order not between 0 and 10000
    or coalesce(array_length(p_season_ids, 1), 0) = 0
    or coalesce(array_length(p_season_ids, 1), 0) <> (
      select count(distinct value)
      from unnest(p_season_ids) value
    )
  then
    raise exception 'INVALID_ARTICLE' using errcode = '22023';
  end if;
  foreach season_id in array p_season_ids
  loop
    if not exists(
      select 1 from app.seasons season where season.id = season_id
    ) then
      raise exception 'SEASON_NOT_FOUND' using errcode = 'P0002';
    end if;
  end loop;

  for season_id in
    select distinct value
    from unnest(p_season_ids) value
    order by value
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('catalog-season:' || season_id::text, 0)
    );
  end loop;
  if p_article_id is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('catalog-variant:' || p_article_id::text, 0)
    );
  end if;

  if p_article_id is null then
    insert into app.articles(name, code, icon_type, active, sort_order)
    values(
      trim(p_name),
      upper(trim(p_code)),
      p_icon_type,
      p_active,
      p_sort_order
    )
    returning id into target_id;
  else
    perform 1
    from app.articles
    where id = p_article_id
    for update;
    if not found then
      raise exception 'ARTICLE_NOT_FOUND' using errcode = 'P0002';
    end if;
    update app.articles
    set name = trim(p_name),
        code = upper(trim(p_code)),
        icon_type = p_icon_type,
        active = p_active,
        sort_order = p_sort_order
    where id = p_article_id;
    target_id := p_article_id;
    delete from app.article_seasons link
    where link.article_id = target_id
      and link.season_id <> all(p_season_ids);
  end if;

  insert into app.article_seasons(article_id, season_id)
  select target_id, value
  from unnest(p_season_ids) value
  on conflict do nothing;
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    actor,
    case
      when p_article_id is null then 'catalog.article.created'
      else 'catalog.article.updated'
    end,
    'article',
    target_id,
    jsonb_build_object(
      'active', p_active,
      'season_count', array_length(p_season_ids, 1)
    )
  );
  return target_id;
exception
  when unique_violation then
    raise exception 'ARTICLE_NAME_OR_CODE_EXISTS' using errcode = '23505';
end;
$$;

create or replace function app.bulk_set_article_season(
  p_season_id uuid,
  p_article_ids uuid[],
  p_linked boolean,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  actor uuid := auth.uid();
  requested_count integer := coalesce(array_length(p_article_ids, 1), 0);
  changed_count integer := 0;
  article_id uuid;
begin
  if actor is null
    or app.staff_role() not in ('beheerder', 'kledingcommissie')
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_season_id is null
    or p_linked is null
    or requested_count not between 1 and 500
    or requested_count <> (
      select count(distinct selected_article_id)
      from unnest(p_article_ids) selected_article_id
    )
  then
    raise exception 'ARTICLE_SEASON_SELECTION_INVALID' using errcode = '22023';
  end if;
  if not exists(
    select 1
    from app.seasons
    where id = p_season_id
      and status = 'open'
  ) then
    raise exception 'SEASON_NOT_OPEN' using errcode = '23514';
  end if;
  if (
    select count(*) from app.articles where id = any(p_article_ids)
  ) <> requested_count then
    raise exception 'ARTICLE_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('catalog-season:' || p_season_id::text, 0)
  );
  for article_id in
    select distinct selected_article_id
    from unnest(p_article_ids) selected_article_id
    order by selected_article_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('catalog-variant:' || article_id::text, 0)
    );
  end loop;

  if p_linked then
    insert into app.article_seasons(article_id, season_id)
    select selected_article_id, p_season_id
    from unnest(p_article_ids) selected_article_id
    on conflict(article_id, season_id) do nothing;
  else
    delete from app.article_seasons link
    where link.season_id = p_season_id
      and link.article_id = any(p_article_ids);
  end if;
  get diagnostics changed_count = row_count;

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
    case
      when p_linked then 'catalog.article_seasons.bulk_linked'
      else 'catalog.article_seasons.bulk_unlinked'
    end,
    'season',
    p_season_id,
    jsonb_build_object(
      'articleIds', to_jsonb(p_article_ids),
      'requestedCount', requested_count,
      'changedCount', changed_count
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'seasonId', p_season_id,
    'linked', p_linked,
    'requestedCount', requested_count,
    'changedCount', changed_count
  );
end;
$$;

notify pgrst, 'reload schema';
