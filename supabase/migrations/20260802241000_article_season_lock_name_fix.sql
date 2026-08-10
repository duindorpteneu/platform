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
  selected_id uuid;
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
  for selected_id in
    select distinct selected_article_id
    from unnest(p_article_ids) selected_article_id
    order by selected_article_id
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('catalog-variant:' || selected_id::text, 0)
    );
  end loop;

  if p_linked then
    insert into app.article_seasons(article_id, season_id)
    select selected_article_id, p_season_id
    from unnest(p_article_ids) selected_article_id
    on conflict on constraint article_seasons_pkey do nothing;
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
