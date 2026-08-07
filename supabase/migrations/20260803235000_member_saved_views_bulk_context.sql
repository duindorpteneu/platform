-- Owner-bound member saved views and safe bulk-action context.
--
-- Saved views deliberately exclude free-text search, pagination and a selected
-- member. Applying a view always revalidates every stored filter; stale views
-- fail closed instead of silently broadening the member result set.

create or replace function private.member_saved_view_filter_shape_valid(
  p_filters jsonb
)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select
    jsonb_typeof(p_filters) = 'object'
    and not exists(
      select 1
      from jsonb_object_keys(
        case
          when jsonb_typeof(p_filters) = 'object' then p_filters
          else '{}'::jsonb
        end
      ) filter_key
      where filter_key not in (
        'team',
        'payment',
        'orderStatus',
        'articleId',
        'size',
        'lineStatus'
      )
    )
    and (
      not (p_filters ? 'team')
      or (
        jsonb_typeof(p_filters->'team') = 'string'
        and p_filters->>'team' = btrim(p_filters->>'team')
        and length(p_filters->>'team') between 1 and 120
      )
    )
    and (
      not (p_filters ? 'payment')
      or (
        jsonb_typeof(p_filters->'payment') = 'string'
        and p_filters->>'payment' in ('paid', 'unpaid', 'no_order')
      )
    )
    and (
      not (p_filters ? 'orderStatus')
      or (
        jsonb_typeof(p_filters->'orderStatus') = 'string'
        and p_filters->>'orderStatus' in (
          'Nog niet betaald',
          'Nalevering',
          'Gedeeltelijk af te halen',
          'Volledig af te halen',
          'Gedeeltelijk afgehaald',
          'Afgerond'
        )
      )
    )
    and (
      not (p_filters ? 'articleId')
      or (
        jsonb_typeof(p_filters->'articleId') = 'string'
        and p_filters->>'articleId' ~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      )
    )
    and (
      not (p_filters ? 'size')
      or (
        jsonb_typeof(p_filters->'size') = 'string'
        and p_filters->>'size' = btrim(p_filters->>'size')
        and length(p_filters->>'size') between 1 and 80
      )
    )
    and (
      not (p_filters ? 'lineStatus')
      or (
        jsonb_typeof(p_filters->'lineStatus') = 'string'
        and p_filters->>'lineStatus' in (
          'backorder',
          'ready_for_pickup',
          'picked_up',
          'cancelled'
        )
      )
    );
$$;

create table app.staff_saved_views (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null
    references app.staff_profiles(auth_user_id) on delete cascade,
  scope text not null check (scope = 'members'),
  season_id uuid not null references app.seasons(id) on delete restrict,
  name text not null check (
    name = btrim(name)
    and length(name) between 1 and 80
  ),
  schema_version smallint not null check (schema_version = 1),
  filters jsonb not null check (
    private.member_saved_view_filter_shape_valid(filters)
  ),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create unique index staff_saved_views_owner_name_unique_idx
  on app.staff_saved_views(
    owner_user_id,
    scope,
    season_id,
    lower(name)
  );
create index staff_saved_views_owner_scope_season_idx
  on app.staff_saved_views(owner_user_id, scope, season_id, updated_at desc);

create trigger staff_saved_views_touch_updated_at
before update on app.staff_saved_views
for each row execute function app.touch_updated_at();

alter table app.staff_saved_views enable row level security;

create policy "saved view owner can read"
on app.staff_saved_views
for select
using (
  owner_user_id = auth.uid()
  and scope = 'members'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);

create policy "saved view owner can insert"
on app.staff_saved_views
for insert
with check (
  owner_user_id = auth.uid()
  and scope = 'members'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);

create policy "saved view owner can update"
on app.staff_saved_views
for update
using (
  owner_user_id = auth.uid()
  and scope = 'members'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
)
with check (
  owner_user_id = auth.uid()
  and scope = 'members'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);

create policy "saved view owner can delete"
on app.staff_saved_views
for delete
using (
  owner_user_id = auth.uid()
  and scope = 'members'
  and app.staff_role() in ('beheerder', 'kledingcommissie')
);

revoke all on table app.staff_saved_views
from public, anon, authenticated, service_role;
grant select on table app.staff_saved_views to authenticated;

create or replace function private.member_saved_view_filters_valid_for_season(
  p_season_id uuid,
  p_filters jsonb
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target_article_id uuid;
begin
  if p_season_id is null
    or not private.member_saved_view_filter_shape_valid(p_filters)
    or not exists(
      select 1
      from app.seasons season
      where season.id = p_season_id
    )
  then
    return false;
  end if;

  if p_filters ? 'team'
    and not exists(
      select 1
      from app.member_seasons member_season
      where member_season.season_id = p_season_id
        and member_season.team_name = p_filters->>'team'
    )
  then
    return false;
  end if;

  if p_filters ? 'articleId' then
    target_article_id := (p_filters->>'articleId')::uuid;
    if not exists(
      select 1
      from app.article_seasons season_article
      join app.articles article
        on article.id = season_article.article_id
        and article.active
      where season_article.season_id = p_season_id
        and season_article.article_id = target_article_id
    ) then
      return false;
    end if;
  end if;

  if p_filters ? 'size'
    and not exists(
      select 1
      from app.article_variants variant
      join app.article_seasons season_article
        on season_article.article_id = variant.article_id
        and season_article.season_id = p_season_id
      join app.articles article
        on article.id = variant.article_id
        and article.active
      where variant.active
        and variant.size = p_filters->>'size'
        and (
          target_article_id is null
          or variant.article_id = target_article_id
        )
    )
  then
    return false;
  end if;

  return true;
end;
$$;

create or replace function private.member_saved_view_json(
  p_view app.staff_saved_views
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'id', p_view.id,
    'scope', p_view.scope,
    'seasonId', p_view.season_id,
    'name', p_view.name,
    'schemaVersion', p_view.schema_version,
    'filters', p_view.filters,
    'valid',
      p_view.schema_version = 1
      and private.member_saved_view_filters_valid_for_season(
        p_view.season_id,
        p_view.filters
      ),
    'invalidReason', case
      when p_view.schema_version <> 1 then 'schema_version_unsupported'
      when not private.member_saved_view_filters_valid_for_season(
        p_view.season_id,
        p_view.filters
      ) then 'filters_stale'
      else null
    end,
    'updatedAt', p_view.updated_at
  );
$$;

create or replace function app.get_member_saved_views(
  p_season_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
begin
  if p_season_id is null
    or not exists(
      select 1
      from app.seasons season
      where season.id = p_season_id
    )
  then
    raise exception 'SAVED_VIEW_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'scope', 'members',
    'seasonId', p_season_id,
    'views', coalesce((
      select jsonb_agg(
        private.member_saved_view_json(saved_view)
        order by lower(saved_view.name), saved_view.id
      )
      from app.staff_saved_views saved_view
      where saved_view.owner_user_id = actor
        and saved_view.scope = 'members'
        and saved_view.season_id = p_season_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.save_member_saved_view(
  p_view_id uuid,
  p_season_id uuid,
  p_name text,
  p_schema_version smallint,
  p_filters jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  normalized_name text := btrim(coalesce(p_name, ''));
  saved_view app.staff_saved_views%rowtype;
  audit_action text;
begin
  if p_season_id is null
    or not exists(
      select 1
      from app.seasons season
      where season.id = p_season_id
    )
  then
    raise exception 'SAVED_VIEW_SEASON_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_schema_version is distinct from 1
    or length(normalized_name) not between 1 and 80
    or not private.member_saved_view_filter_shape_valid(p_filters)
  then
    raise exception 'SAVED_VIEW_INVALID' using errcode = '22023';
  end if;
  if not private.member_saved_view_filters_valid_for_season(
    p_season_id,
    p_filters
  ) then
    raise exception 'SAVED_VIEW_FILTERS_STALE' using errcode = '23514';
  end if;

  if p_view_id is null then
    insert into app.staff_saved_views(
      owner_user_id,
      scope,
      season_id,
      name,
      schema_version,
      filters
    )
    values(
      actor,
      'members',
      p_season_id,
      normalized_name,
      p_schema_version,
      p_filters
    )
    returning * into saved_view;
    audit_action := 'member_saved_view.created';
  else
    update app.staff_saved_views target
    set name = normalized_name,
        schema_version = p_schema_version,
        filters = p_filters
    where target.id = p_view_id
      and target.owner_user_id = actor
      and target.scope = 'members'
      and target.season_id = p_season_id
    returning * into saved_view;
    if not found then
      raise exception 'SAVED_VIEW_NOT_FOUND' using errcode = 'P0002';
    end if;
    audit_action := 'member_saved_view.updated';
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    actor,
    audit_action,
    'staff_saved_view',
    saved_view.id,
    jsonb_build_object(
      'scope', 'members',
      'season_id', p_season_id,
      'schema_version', p_schema_version
    )
  );

  return private.member_saved_view_json(saved_view);
end;
$$;

create or replace function app.delete_member_saved_view(
  p_view_id uuid,
  p_season_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  deleted_id uuid;
begin
  delete from app.staff_saved_views saved_view
  where saved_view.id = p_view_id
    and saved_view.owner_user_id = actor
    and saved_view.scope = 'members'
    and saved_view.season_id = p_season_id
  returning saved_view.id into deleted_id;
  if deleted_id is null then
    raise exception 'SAVED_VIEW_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values(
    actor,
    'member_saved_view.deleted',
    'staff_saved_view',
    deleted_id,
    jsonb_build_object(
      'scope', 'members',
      'season_id', p_season_id
    )
  );

  return jsonb_build_object(
    'id', deleted_id,
    'seasonId', p_season_id,
    'deleted', true
  );
end;
$$;

create or replace function app.apply_member_saved_view(
  p_view_id uuid,
  p_season_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_clothing_aal2();
  saved_view app.staff_saved_views%rowtype;
begin
  select * into saved_view
  from app.staff_saved_views target
  where target.id = p_view_id
    and target.owner_user_id = actor
    and target.scope = 'members'
    and target.season_id = p_season_id;
  if not found then
    raise exception 'SAVED_VIEW_NOT_FOUND' using errcode = 'P0002';
  end if;
  if saved_view.schema_version <> 1
    or not private.member_saved_view_filters_valid_for_season(
      saved_view.season_id,
      saved_view.filters
    )
  then
    raise exception 'SAVED_VIEW_STALE' using errcode = '23514';
  end if;

  return jsonb_build_object(
    'id', saved_view.id,
    'seasonId', saved_view.season_id,
    'schemaVersion', saved_view.schema_version,
    'filters', saved_view.filters
  );
end;
$$;

alter function app.get_member_list(
  text,
  text,
  text,
  text,
  uuid,
  text,
  app.order_line_status,
  integer,
  integer
) rename to get_member_list_legacy_20260718;

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
set search_path = app, private, pg_temp
as $$
declare
  result jsonb;
  active_season uuid;
  enriched_members jsonb;
begin
  result := app.get_member_list_legacy_20260718(
    p_search,
    p_team,
    p_payment_filter,
    p_order_status,
    p_article_id,
    p_size,
    p_line_status,
    p_limit,
    p_offset
  );
  active_season := nullif(result #>> '{activeSeason,id}', '')::uuid;

  select coalesce(jsonb_agg(
    member_row.value || jsonb_build_object(
      'memberSeasonId', member_season.id,
      'bulkEligibility', jsonb_build_object(
        'portalAccessPreflight', member_season.id is not null,
        'mailPreflight', member_season.id is not null,
        'teamStatusPreflight',
          member_season.id is not null
          and member_season.team_name is not null
      )
    )
    order by member_row.ordinality
  ), '[]'::jsonb)
  into enriched_members
  from jsonb_array_elements(result->'members')
    with ordinality member_row(value, ordinality)
  left join app.member_seasons member_season
    on active_season is not null
    and member_season.season_id = active_season
    and member_season.member_id = (member_row.value->>'id')::uuid;

  return jsonb_set(result, '{members}', enriched_members, false);
end;
$$;

revoke all on function private.member_saved_view_filter_shape_valid(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.member_saved_view_filters_valid_for_season(uuid, jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.member_saved_view_json(app.staff_saved_views)
from public, anon, authenticated, service_role;

revoke all on function app.get_member_saved_views(uuid) from public, anon;
revoke all on function app.save_member_saved_view(uuid, uuid, text, smallint, jsonb)
from public, anon;
revoke all on function app.delete_member_saved_view(uuid, uuid)
from public, anon;
revoke all on function app.apply_member_saved_view(uuid, uuid)
from public, anon;
grant execute on function app.get_member_saved_views(uuid) to authenticated;
grant execute on function app.save_member_saved_view(uuid, uuid, text, smallint, jsonb)
to authenticated;
grant execute on function app.delete_member_saved_view(uuid, uuid)
to authenticated;
grant execute on function app.apply_member_saved_view(uuid, uuid)
to authenticated;

revoke all on function app.get_member_list_legacy_20260718(
  text,
  text,
  text,
  text,
  uuid,
  text,
  app.order_line_status,
  integer,
  integer
) from public, anon, authenticated, service_role;
revoke all on function app.get_member_list(
  text,
  text,
  text,
  text,
  uuid,
  text,
  app.order_line_status,
  integer,
  integer
) from public, anon;
grant execute on function app.get_member_list(
  text,
  text,
  text,
  text,
  uuid,
  text,
  app.order_line_status,
  integer,
  integer
) to authenticated;

notify pgrst, 'reload schema';
