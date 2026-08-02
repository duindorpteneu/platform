-- Immutable, season-bound mapping revisions and reusable mapping presets.
--
-- Only selected source columns are persisted. Mapping revisions store a digest
-- of each selected header, never ignored header labels or source values.

do $$ begin
  create type app.import_mapping_field as enum (
    'external_member_id',
    'first_name',
    'insertion',
    'last_name',
    'email',
    'team',
    'date_of_birth',
    'gender',
    'active_for_season'
  );
exception when duplicate_object then null; end $$;

create table app.import_mapping_presets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  name_key text not null,
  entries jsonb not null,
  revision integer not null default 1 check (revision > 0),
  created_by uuid not null,
  updated_by uuid not null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  archived_at timestamptz,
  constraint import_mapping_presets_name_check check (
    length(name) between 1 and 80
    and name = btrim(name)
    and name !~ '[[:cntrl:]]'
  ),
  constraint import_mapping_presets_name_key_check check (
    length(name_key) between 1 and 80
  ),
  constraint import_mapping_presets_entries_check check (
    jsonb_typeof(entries) = 'array'
    and jsonb_array_length(entries) between 1 and 64
  )
);

create unique index import_mapping_presets_active_name_idx
  on app.import_mapping_presets(name_key)
  where archived_at is null;

create table app.import_mapping_revisions (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references app.import_batches(id) on delete restrict,
  season_id uuid not null references app.seasons(id) on delete restrict,
  revision integer not null check (revision > 0),
  mapping jsonb not null,
  mapping_hash text not null check (mapping_hash ~ '^[0-9a-f]{64}$'),
  header_hash text not null check (header_hash ~ '^[0-9a-f]{64}$'),
  catalog_hash text not null check (catalog_hash ~ '^[0-9a-f]{64}$'),
  policy jsonb not null,
  preset_id uuid references app.import_mapping_presets(id) on delete restrict,
  preset_revision integer,
  created_by uuid not null,
  created_at timestamptz not null default timezone('utc', now()),
  unique (batch_id, revision),
  unique (id, batch_id, season_id),
  constraint import_mapping_revisions_mapping_check check (
    jsonb_typeof(mapping) = 'array'
    and jsonb_array_length(mapping) between 1 and 64
  ),
  constraint import_mapping_revisions_policy_check check (
    policy = jsonb_build_object(
      'fillEmptyValues', true,
      'updateImportedUnconfirmedSizes', true,
      'protectConfirmedSizes', true,
      'ignoreEmptySourceValues', true
    )
  ),
  constraint import_mapping_revisions_preset_check check (
    (preset_id is null and preset_revision is null)
    or (preset_id is not null and preset_revision is not null and preset_revision > 0)
  )
);

alter table app.import_batches
  add column active_mapping_revision_id uuid,
  add constraint import_batches_active_mapping_revision_fkey
    foreign key (active_mapping_revision_id, id, season_id)
    references app.import_mapping_revisions(id, batch_id, season_id)
    on delete restrict
    deferrable initially deferred;

create index import_mapping_revisions_batch_idx
  on app.import_mapping_revisions(batch_id, revision desc);

alter table app.import_mapping_presets enable row level security;
alter table app.import_mapping_revisions enable row level security;

create policy "administrators can read import mapping presets"
on app.import_mapping_presets
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
);

create policy "administrators can read own import mapping revisions"
on app.import_mapping_revisions
for select
using (
  coalesce(auth.jwt()->>'aal', '') = 'aal2'
  and app.staff_role() = 'beheerder'
  and created_by = auth.uid()
);

revoke all on table app.import_mapping_presets
from public, anon, authenticated, service_role;
revoke all on table app.import_mapping_revisions
from public, anon, authenticated, service_role;
grant select on table app.import_mapping_presets to authenticated;
grant select on table app.import_mapping_revisions to authenticated;

create or replace function private.normalize_import_header(p_value text)
returns text
language sql
immutable
strict
set search_path = pg_catalog, pg_temp
as $$
  select lower(
    btrim(
      regexp_replace(
        normalize(p_value, NFKC),
        '[[:space:]]+',
        ' ',
        'g'
      )
    )
  );
$$;

revoke all on function private.normalize_import_header(text)
from public, anon, authenticated, service_role;

create or replace function private.dynamic_import_catalog_hash(p_season_id uuid)
returns text
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with catalog as (
    select
      article.id article_id,
      article.code,
      article.name,
      article.sort_order article_sort_order,
      variant.id variant_id,
      variant.size,
      variant.sku,
      variant.sort_order variant_sort_order,
      coalesce((
        select jsonb_agg(
          jsonb_build_array(alias.alias_normalized, alias.article_variant_id)
          order by alias.alias_normalized, alias.article_variant_id
        )
        from app.article_variant_aliases alias
        where alias.article_variant_id = variant.id
      ), '[]'::jsonb) aliases
    from app.article_seasons link
    join app.articles article on article.id = link.article_id and article.active
    join app.article_variants variant on variant.article_id = article.id and variant.active
    where link.season_id = p_season_id
  )
  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          jsonb_agg(
            jsonb_build_array(
              catalog.article_id,
              catalog.code,
              catalog.name,
              catalog.variant_id,
              private.normalize_size_match(catalog.size),
              case
                when nullif(btrim(catalog.sku), '') is null then null
                else private.normalize_size_match(catalog.sku)
              end,
              catalog.aliases
            )
            order by
              catalog.article_sort_order,
              catalog.article_id,
              catalog.variant_sort_order,
              catalog.variant_id
          )::text,
          '[]'
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  from catalog;
$$;

revoke all on function private.dynamic_import_catalog_hash(uuid)
from public, anon, authenticated, service_role;

create or replace function private.assert_dynamic_import_mapping(
  p_mapping jsonb,
  p_season_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  entry jsonb;
  target jsonb;
  source_index integer;
  target_kind text;
  target_field text;
  target_article uuid;
  seen_indexes integer[] := array[]::integer[];
  seen_fields text[] := array[]::text[];
  seen_articles uuid[] := array[]::uuid[];
begin
  if jsonb_typeof(p_mapping) <> 'array'
    or jsonb_array_length(p_mapping) not between 1 and 64
  then
    raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
  end if;

  for entry in select value from jsonb_array_elements(p_mapping)
  loop
    if jsonb_typeof(entry) <> 'object'
      or not (entry ?& array['columnIndex', 'sourceHeaderHash', 'target'])
      or (select count(*) from jsonb_object_keys(entry)) <> 3
      or coalesce(entry->>'sourceHeaderHash', '') !~ '^[0-9a-f]{64}$'
    then
      raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
    end if;
    begin
      source_index := (entry->>'columnIndex')::integer;
    exception when others then
      raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
    end;
    if source_index not between 0 and 63
      or to_jsonb(source_index) is distinct from entry->'columnIndex'
      or source_index = any(seen_indexes)
    then
      raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
    end if;
    seen_indexes := array_append(seen_indexes, source_index);

    target := entry->'target';
    if jsonb_typeof(target) <> 'object' then
      raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
    end if;
    target_kind := target->>'kind';
    if target_kind = 'member_field' then
      if not (target ?& array['kind', 'field'])
        or (select count(*) from jsonb_object_keys(target)) <> 2
      then
        raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
      end if;
      target_field := target->>'field';
      if target_field is null
        or target_field not in (
          'external_member_id', 'first_name', 'insertion', 'last_name',
          'email', 'team', 'date_of_birth', 'gender', 'active_for_season'
        )
        or target_field = any(seen_fields)
      then
        raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
      end if;
      seen_fields := array_append(seen_fields, target_field);
    elsif target_kind = 'product_size' then
      if not (target ?& array['kind', 'articleId'])
        or (select count(*) from jsonb_object_keys(target)) <> 2
      then
        raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
      end if;
      begin
        target_article := (target->>'articleId')::uuid;
      exception when others then
        raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
      end;
      if target_article = any(seen_articles)
        or not exists(
          select 1
          from app.article_seasons link
          join app.articles article on article.id = link.article_id and article.active
          where link.season_id = p_season_id
            and link.article_id = target_article
            and exists(
              select 1 from app.article_variants variant
              where variant.article_id = article.id and variant.active
            )
            and private.variant_match_conflicts(article.id) = '[]'::jsonb
        )
      then
        raise exception 'DYNAMIC_IMPORT_PRODUCT_NOT_IMPORTABLE' using errcode = '23514';
      end if;
      seen_articles := array_append(seen_articles, target_article);
    else
      raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
    end if;
  end loop;
end;
$$;

revoke all on function private.assert_dynamic_import_mapping(jsonb, uuid)
from public, anon, authenticated, service_role;

create or replace function private.assert_dynamic_import_preset_entries(p_entries jsonb)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  entry jsonb;
  target jsonb;
  source_key text;
  target_kind text;
  target_field text;
  target_article uuid;
  seen_headers text[] := array[]::text[];
  seen_fields text[] := array[]::text[];
  seen_articles uuid[] := array[]::uuid[];
begin
  if jsonb_typeof(p_entries) <> 'array'
    or jsonb_array_length(p_entries) not between 1 and 64
  then
    raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
  end if;

  for entry in select value from jsonb_array_elements(p_entries)
  loop
    if jsonb_typeof(entry) <> 'object'
      or not (entry ?& array['sourceHeaderKey', 'target'])
      or (select count(*) from jsonb_object_keys(entry)) <> 2
    then
      raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
    end if;
    source_key := entry->>'sourceHeaderKey';
    if source_key is null
      or length(source_key) not between 1 and 120
      or source_key <> private.normalize_import_header(source_key)
      or source_key = any(seen_headers)
    then
      raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
    end if;
    seen_headers := array_append(seen_headers, source_key);

    target := entry->'target';
    target_kind := target->>'kind';
    if target_kind = 'member_field' then
      target_field := target->>'field';
      if (select count(*) from jsonb_object_keys(target)) <> 2
        or target_field is null
        or target_field not in (
          'external_member_id', 'first_name', 'insertion', 'last_name',
          'email', 'team', 'date_of_birth', 'gender', 'active_for_season'
        )
        or target_field = any(seen_fields)
      then
        raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
      end if;
      seen_fields := array_append(seen_fields, target_field);
    elsif target_kind = 'product_size' then
      if (select count(*) from jsonb_object_keys(target)) <> 2 then
        raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
      end if;
      begin
        target_article := (target->>'articleId')::uuid;
      exception when others then
        raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
      end;
      if target_article = any(seen_articles)
        or not exists(select 1 from app.articles where id = target_article)
      then
        raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
      end if;
      seen_articles := array_append(seen_articles, target_article);
    else
      raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
    end if;
  end loop;
end;
$$;

revoke all on function private.assert_dynamic_import_preset_entries(jsonb)
from public, anon, authenticated, service_role;

create or replace function app.get_dynamic_import_mapping_workspace(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  target_batch app.import_batches%rowtype;
  current_catalog_hash text;
begin
  actor := private.require_dynamic_import_admin();
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;

  select * into target_batch
  from app.import_batches batch
  where batch.id = p_batch_id
    and batch.actor_user_id = actor
    and batch.schema_version = 2
    and batch.dynamic_status in ('uploaded', 'previewed')
    and batch.expires_at > timezone('utc', now());
  if not found then
    raise exception 'DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE' using errcode = 'P0002';
  end if;
  if not exists(
    select 1
    from app.app_settings settings
    join app.seasons season on season.id = settings.active_season_id
    where settings.id = true
      and season.id = target_batch.season_id
      and season.status = 'open'
  ) then
    raise exception 'DYNAMIC_IMPORT_SEASON_CHANGED' using errcode = '55000';
  end if;

  current_catalog_hash := private.dynamic_import_catalog_hash(target_batch.season_id);
  return jsonb_build_object(
    'batchId', target_batch.id,
    'seasonId', target_batch.season_id,
    'revision', target_batch.preview_revision,
    'catalogHash', current_catalog_hash,
    'articles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', article.id,
        'code', article.code,
        'name', article.name,
        'importable',
          jsonb_array_length(private.variant_match_conflicts(article.id)) = 0
          and exists(
            select 1 from app.article_variants variant
            where variant.article_id = article.id and variant.active
          ),
        'matchConflicts', private.variant_match_conflicts(article.id),
        'variants', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', variant.id,
            'label', variant.size,
            'code', variant.sku,
            'aliases', coalesce((
              select jsonb_agg(alias.alias order by alias.alias_normalized)
              from app.article_variant_aliases alias
              where alias.article_variant_id = variant.id
            ), '[]'::jsonb)
          ) order by variant.sort_order, variant.size, variant.id)
          from app.article_variants variant
          where variant.article_id = article.id and variant.active
        ), '[]'::jsonb)
      ) order by article.sort_order, article.name, article.id)
      from app.article_seasons link
      join app.articles article on article.id = link.article_id and article.active
      where link.season_id = target_batch.season_id
    ), '[]'::jsonb),
    'presets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', preset.id,
        'name', preset.name,
        'revision', preset.revision,
        'entries', preset.entries
      ) order by preset.name_key, preset.id)
      from app.import_mapping_presets preset
      where preset.archived_at is null
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.save_dynamic_import_mapping(
  p_batch_id uuid,
  p_expected_revision integer,
  p_expected_catalog_hash text,
  p_header_hash text,
  p_mapping jsonb,
  p_policy jsonb,
  p_preset_id uuid default null,
  p_preset_revision integer default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  target_batch app.import_batches%rowtype;
  current_catalog_hash text;
  current_mapping_hash text;
  next_revision integer;
  revision_id uuid;
  current_revision app.import_mapping_revisions%rowtype;
begin
  actor := private.require_dynamic_import_admin();
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_expected_revision is null
    or p_expected_revision < 0
    or p_expected_catalog_hash !~ '^[0-9a-f]{64}$'
    or p_header_hash !~ '^[0-9a-f]{64}$'
    or p_policy is distinct from jsonb_build_object(
      'fillEmptyValues', true,
      'updateImportedUnconfirmedSizes', true,
      'protectConfirmedSizes', true,
      'ignoreEmptySourceValues', true
    )
    or ((p_preset_id is null) <> (p_preset_revision is null))
  then
    raise exception 'DYNAMIC_IMPORT_MAPPING_INVALID' using errcode = '22023';
  end if;

  select * into target_batch
  from app.import_batches batch
  where batch.id = p_batch_id
    and batch.actor_user_id = actor
    and batch.schema_version = 2
  for update;
  if not found
    or target_batch.dynamic_status not in ('uploaded', 'previewed')
    or target_batch.expires_at <= timezone('utc', now())
    or not exists(
      select 1
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
        and season.id = target_batch.season_id
        and season.status = 'open'
    )
    or not exists(
      select 1 from private.import_staging_payloads payload
      where payload.batch_id = target_batch.id
        and payload.expires_at > timezone('utc', now())
    )
  then
    raise exception 'DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE' using errcode = 'P0002';
  end if;

  current_catalog_hash := private.dynamic_import_catalog_hash(target_batch.season_id);
  if current_catalog_hash is distinct from p_expected_catalog_hash then
    raise exception 'DYNAMIC_IMPORT_CATALOG_CHANGED' using errcode = '40001';
  end if;
  perform private.assert_dynamic_import_mapping(p_mapping, target_batch.season_id);

  if p_preset_id is not null and not exists(
    select 1 from app.import_mapping_presets preset
    where preset.id = p_preset_id
      and preset.revision = p_preset_revision
      and preset.archived_at is null
  ) then
    raise exception 'DYNAMIC_IMPORT_PRESET_CHANGED' using errcode = '40001';
  end if;

  current_mapping_hash := encode(
    extensions.digest(convert_to(p_mapping::text, 'UTF8'), 'sha256'),
    'hex'
  );

  if target_batch.preview_revision <> p_expected_revision then
    select * into current_revision
    from app.import_mapping_revisions revision
    where revision.id = target_batch.active_mapping_revision_id;
    if found
      and current_revision.mapping_hash = current_mapping_hash
      and current_revision.header_hash = p_header_hash
      and current_revision.catalog_hash = current_catalog_hash
      and current_revision.policy = p_policy
      and current_revision.preset_id is not distinct from p_preset_id
      and current_revision.preset_revision is not distinct from p_preset_revision
    then
      return jsonb_build_object(
        'batchId', target_batch.id,
        'revision', current_revision.revision,
        'mappingHash', current_revision.mapping_hash,
        'catalogHash', current_revision.catalog_hash,
        'reused', true
      );
    end if;
    raise exception 'DYNAMIC_IMPORT_REVISION_CHANGED' using errcode = '40001';
  end if;

  next_revision := target_batch.preview_revision + 1;
  insert into app.import_mapping_revisions(
    batch_id,
    season_id,
    revision,
    mapping,
    mapping_hash,
    header_hash,
    catalog_hash,
    policy,
    preset_id,
    preset_revision,
    created_by
  )
  values(
    target_batch.id,
    target_batch.season_id,
    next_revision,
    p_mapping,
    current_mapping_hash,
    p_header_hash,
    current_catalog_hash,
    p_policy,
    p_preset_id,
    p_preset_revision,
    actor
  )
  returning id into revision_id;

  update app.import_batches
  set active_mapping_revision_id = revision_id,
      mapping = p_mapping,
      mapping_hash = current_mapping_hash,
      catalog_hash = current_catalog_hash,
      preview_revision = next_revision,
      dynamic_status = 'uploaded',
      failure_code = null
  where id = target_batch.id;

  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata, correlation_id
  )
  values(
    actor,
    'members.import.mapping.saved',
    'import_batch',
    target_batch.id,
    jsonb_build_object(
      'revision', next_revision,
      'selectedColumnCount', jsonb_array_length(p_mapping),
      'productColumnCount', (
        select count(*) from jsonb_array_elements(p_mapping) entry
        where entry #>> '{target,kind}' = 'product_size'
      ),
      'usedPreset', p_preset_id is not null
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'batchId', target_batch.id,
    'revision', next_revision,
    'mappingHash', current_mapping_hash,
    'catalogHash', current_catalog_hash,
    'reused', false
  );
end;
$$;

create or replace function app.save_dynamic_import_mapping_preset(
  p_preset_id uuid,
  p_expected_revision integer,
  p_name text,
  p_entries jsonb,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  target_id uuid;
  normalized_name text;
  normalized_key text;
  next_revision integer;
  existing app.import_mapping_presets%rowtype;
begin
  actor := private.require_dynamic_import_admin();
  if not private.dynamic_import_enabled() then
    raise exception 'DYNAMIC_IMPORT_DISABLED' using errcode = '55000';
  end if;
  if p_name is null then
    raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
  end if;
  normalized_name := btrim(normalize(p_name, NFKC));
  normalized_key := private.normalize_import_header(normalized_name);
  if length(normalized_name) not between 1 and 80
    or normalized_name ~ '[[:cntrl:]]'
  then
    raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
  end if;
  perform private.assert_dynamic_import_preset_entries(p_entries);

  if p_preset_id is null then
    if p_expected_revision is not null then
      raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
    end if;
    insert into app.import_mapping_presets(
      name, name_key, entries, created_by, updated_by
    )
    values(normalized_name, normalized_key, p_entries, actor, actor)
    returning id, revision into target_id, next_revision;
  else
    select * into existing
    from app.import_mapping_presets preset
    where preset.id = p_preset_id
    for update;
    if not found or existing.archived_at is not null then
      raise exception 'DYNAMIC_IMPORT_PRESET_NOT_FOUND' using errcode = 'P0002';
    end if;
    if p_expected_revision is null or existing.revision <> p_expected_revision then
      raise exception 'DYNAMIC_IMPORT_PRESET_CHANGED' using errcode = '40001';
    end if;
    next_revision := existing.revision + 1;
    update app.import_mapping_presets
    set name = normalized_name,
        name_key = normalized_key,
        entries = p_entries,
        revision = next_revision,
        updated_by = actor,
        updated_at = timezone('utc', now())
    where id = existing.id;
    target_id := existing.id;
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(
    actor,
    'members.import.mapping_preset.saved',
    'import_mapping_preset',
    target_id,
    jsonb_build_object(
      'revision', next_revision,
      'entryCount', jsonb_array_length(p_entries)
    ),
    p_correlation_id
  );

  return jsonb_build_object(
    'id', target_id,
    'name', normalized_name,
    'revision', next_revision,
    'entries', p_entries
  );
exception when unique_violation then
  raise exception 'DYNAMIC_IMPORT_PRESET_NAME_EXISTS' using errcode = '23505';
end;
$$;

create or replace function app.archive_dynamic_import_mapping_preset(
  p_preset_id uuid,
  p_expected_revision integer,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  changed app.import_mapping_presets%rowtype;
begin
  actor := private.require_dynamic_import_admin();
  if p_preset_id is null or p_expected_revision is null or p_expected_revision < 1 then
    raise exception 'DYNAMIC_IMPORT_PRESET_INVALID' using errcode = '22023';
  end if;
  update app.import_mapping_presets preset
  set archived_at = timezone('utc', now()),
      revision = revision + 1,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where preset.id = p_preset_id
    and preset.revision = p_expected_revision
    and preset.archived_at is null
  returning * into changed;
  if not found then
    raise exception 'DYNAMIC_IMPORT_PRESET_CHANGED' using errcode = '40001';
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(
    actor,
    'members.import.mapping_preset.archived',
    'import_mapping_preset',
    changed.id,
    jsonb_build_object('revision', changed.revision),
    p_correlation_id
  );
  return jsonb_build_object('id', changed.id, 'revision', changed.revision, 'archived', true);
end;
$$;

revoke all on function app.get_dynamic_import_mapping_workspace(uuid)
from public, anon;
grant execute on function app.get_dynamic_import_mapping_workspace(uuid)
to authenticated;

revoke all on function app.save_dynamic_import_mapping(
  uuid, integer, text, text, jsonb, jsonb, uuid, integer, uuid
) from public, anon;
grant execute on function app.save_dynamic_import_mapping(
  uuid, integer, text, text, jsonb, jsonb, uuid, integer, uuid
) to authenticated;

revoke all on function app.save_dynamic_import_mapping_preset(
  uuid, integer, text, jsonb, uuid
) from public, anon;
grant execute on function app.save_dynamic_import_mapping_preset(
  uuid, integer, text, jsonb, uuid
) to authenticated;

revoke all on function app.archive_dynamic_import_mapping_preset(uuid, integer, uuid)
from public, anon;
grant execute on function app.archive_dynamic_import_mapping_preset(uuid, integer, uuid)
to authenticated;

notify pgrst, 'reload schema';
