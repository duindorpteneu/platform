-- Exact, product-bound size aliases for dynamic imports.
--
-- Aliases never create stock variants. They are additional exact match keys for an
-- existing variant and remain product-scoped. Existing historical migrations and
-- catalog data are left intact.

create or replace function private.normalize_size_match(p_value text)
returns text
language sql
immutable
strict
set search_path = pg_catalog, pg_temp
as $$
  select upper(
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

revoke all on function private.normalize_size_match(text)
from public, anon, authenticated, service_role;

create or replace function private.contains_unsafe_size_format(p_value text)
returns boolean
language sql
immutable
strict
set search_path = pg_catalog, pg_temp
as $$
  select encode(convert_to(p_value, 'UTF8'), 'hex')
    ~ '(c2ad|d88[0-5]|d89c|db9d|dc8f|e0a29[01]|e0a3a2|cd8f|e1859f|e185a0|e19eb4|e19eb5|e1a08[b-f]|e2808[b-f]|e280a[a-e]|e281a[0-4]|e281a[6-f]|e385a4|efb88[0-9a-f]|efbea0|efbfb[9ab]|efbbbf|f09182bd|f091838d|f09390b[0-f]|f09bb2a[0-f]|f09d85b[3-9a]|f3a0)';
$$;

revoke all on function private.contains_unsafe_size_format(text)
from public, anon, authenticated, service_role;

create table app.article_variant_aliases (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null,
  article_variant_id uuid not null,
  alias text not null,
  alias_normalized text not null,
  created_by uuid,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  foreign key (article_variant_id, article_id)
    references app.article_variants(id, article_id)
    on delete restrict,
  unique (article_id, alias_normalized),
  unique (article_variant_id, alias_normalized),
  constraint article_variant_alias_value_check check (
    length(alias) between 1 and 80
    and alias = btrim(alias)
    and alias !~ '[[:cntrl:]]'
    and not private.contains_unsafe_size_format(alias)
    and alias_normalized = private.normalize_size_match(alias)
    and alias_normalized !~ '^ANDERS([ .…]*)$'
  )
);

create index article_variant_aliases_variant_idx
  on app.article_variant_aliases(article_variant_id, alias_normalized);

create trigger article_variant_aliases_touch_updated_at
before update on app.article_variant_aliases
for each row execute function app.touch_updated_at();

alter table app.article_variant_aliases enable row level security;

create policy "clothing staff can read variant aliases"
on app.article_variant_aliases
for select
using (app.staff_role() in ('beheerder', 'kledingcommissie'));

revoke all on table app.article_variant_aliases
from public, anon, authenticated, service_role;
grant select on table app.article_variant_aliases to authenticated;

create or replace function private.assert_variant_match_keys(
  p_article_id uuid,
  p_variant_id uuid,
  p_size text,
  p_supplier_code text,
  p_aliases text[]
)
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  size_key text;
  code_key text;
  alias_value text;
  alias_key text;
  requested_keys text[] := array[]::text[];
begin
  if p_article_id is null
    or p_size is null
    or length(btrim(p_size)) not between 1 and 80
    or p_size ~ '[[:cntrl:]]'
    or private.contains_unsafe_size_format(p_size)
    or coalesce(array_length(p_aliases, 1), 0) > 25
  then
    raise exception 'INVALID_VARIANT_MATCH_KEYS' using errcode = '22023';
  end if;

  size_key := private.normalize_size_match(p_size);
  if size_key = '' or size_key ~ '^ANDERS([ .…]*)$' then
    raise exception 'OTHER_IS_NOT_A_VARIANT' using errcode = '23514';
  end if;
  requested_keys := array_append(requested_keys, size_key);

  if nullif(btrim(p_supplier_code), '') is not null then
    if length(btrim(p_supplier_code)) > 120
      or p_supplier_code ~ '[[:cntrl:]]'
      or private.contains_unsafe_size_format(p_supplier_code)
    then
      raise exception 'INVALID_VARIANT_MATCH_KEYS' using errcode = '22023';
    end if;
    code_key := private.normalize_size_match(p_supplier_code);
    if code_key ~ '^ANDERS([ .…]*)$' then
      raise exception 'OTHER_IS_NOT_A_VARIANT' using errcode = '23514';
    end if;
    requested_keys := array_append(requested_keys, code_key);
  end if;

  foreach alias_value in array coalesce(p_aliases, array[]::text[])
  loop
    if alias_value is null
      or length(btrim(alias_value)) not between 1 and 80
      or alias_value <> btrim(alias_value)
      or alias_value ~ '[[:cntrl:]]'
      or private.contains_unsafe_size_format(alias_value)
    then
      raise exception 'INVALID_VARIANT_ALIAS' using errcode = '22023';
    end if;
    alias_key := private.normalize_size_match(alias_value);
    if alias_key = '' or alias_key ~ '^ANDERS([ .…]*)$' then
      raise exception 'OTHER_IS_NOT_A_VARIANT' using errcode = '23514';
    end if;
    if alias_key = any(requested_keys) then
      raise exception 'DUPLICATE_VARIANT_MATCH_KEY' using errcode = '23505';
    end if;
    requested_keys := array_append(requested_keys, alias_key);
  end loop;

  if exists (
    select 1
    from app.article_variants variant
    where variant.article_id = p_article_id
      and variant.id is distinct from p_variant_id
      and (
        private.normalize_size_match(variant.size) = any(requested_keys)
        or (
          nullif(btrim(variant.sku), '') is not null
          and private.normalize_size_match(variant.sku) = any(requested_keys)
        )
      )
  ) or exists (
    select 1
    from app.article_variant_aliases alias
    where alias.article_id = p_article_id
      and alias.article_variant_id is distinct from p_variant_id
      and alias.alias_normalized = any(requested_keys)
  ) then
    raise exception 'VARIANT_MATCH_KEY_EXISTS' using errcode = '23505';
  end if;
end;
$$;

revoke all on function private.assert_variant_match_keys(uuid, uuid, text, text, text[])
from public, anon, authenticated, service_role;

create or replace function app.guard_catalog_variant_match_keys()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  existing_aliases text[];
begin
  select coalesce(array_agg(alias.alias order by alias.alias_normalized), array[]::text[])
  into existing_aliases
  from app.article_variant_aliases alias
  where alias.article_variant_id = new.id;

  perform private.assert_variant_match_keys(
    new.article_id,
    new.id,
    new.size,
    new.sku,
    existing_aliases
  );
  return new;
end;
$$;

drop trigger if exists article_variants_guard_match_keys on app.article_variants;
create trigger article_variants_guard_match_keys
before insert or update of article_id, size, sku on app.article_variants
for each row execute function app.guard_catalog_variant_match_keys();

-- Keep the legacy RPC compatible during the expand window, but make it take the
-- same product lock and exact-key validation as v2. This prevents old and new
-- application artifacts from racing each other during an immutable deployment.
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
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_id uuid;
  existing app.article_variants%rowtype;
  existing_aliases text[];
begin
  if actor is null or app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if not exists(select 1 from app.articles where id = p_article_id)
    or length(btrim(p_size)) not between 1 and 80
    or (nullif(btrim(p_supplier_code), '') is not null and length(btrim(p_supplier_code)) > 120)
    or p_sort_order not between 0 and 10000
  then
    raise exception 'INVALID_VARIANT' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('catalog-variant:' || coalesce(p_article_id::text, ''), 0)
  );
  perform 1
  from app.article_variants
  where article_id = p_article_id
  order by id
  for update;
  perform 1
  from app.article_variant_aliases
  where article_id = p_article_id
  order by id
  for update;

  select coalesce(array_agg(alias.alias order by alias.alias_normalized), array[]::text[])
  into existing_aliases
  from app.article_variant_aliases alias
  where alias.article_variant_id = p_variant_id;

  perform private.assert_variant_match_keys(
    p_article_id,
    p_variant_id,
    p_size,
    p_supplier_code,
    existing_aliases
  );

  if p_variant_id is null then
    insert into app.article_variants(article_id, size, sku, active, sort_order)
    values(p_article_id, btrim(p_size), nullif(btrim(p_supplier_code), ''), p_active, p_sort_order)
    returning id into target_id;
  else
    select *
    into existing
    from app.article_variants
    where id = p_variant_id and article_id = p_article_id
    for update;
    if not found then
      raise exception 'VARIANT_NOT_FOUND' using errcode = 'P0002';
    end if;
    if exists(select 1 from app.order_lines where article_variant_id = p_variant_id)
      and existing.size is distinct from btrim(p_size)
    then
      raise exception 'USED_VARIANT_SIZE_IMMUTABLE' using errcode = '23514';
    end if;
    update app.article_variants
    set size = btrim(p_size),
        sku = nullif(btrim(p_supplier_code), ''),
        active = p_active,
        sort_order = p_sort_order
    where id = p_variant_id;
    target_id := p_variant_id;
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(
    actor,
    case when p_variant_id is null then 'catalog.variant.created' else 'catalog.variant.updated' end,
    'article_variant',
    target_id,
    jsonb_build_object('article_id', p_article_id, 'active', p_active)
  );
  return target_id;
exception
  when unique_violation then
    raise exception 'VARIANT_MATCH_KEY_EXISTS' using errcode = '23505';
end;
$$;

create or replace function app.upsert_catalog_variant_v2(
  p_article_id uuid,
  p_variant_id uuid,
  p_size text,
  p_supplier_code text,
  p_aliases text[],
  p_active boolean,
  p_sort_order integer
)
returns uuid
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_id uuid;
  alias_value text;
begin
  if actor is null
    or app.staff_role() not in ('beheerder', 'kledingcommissie')
    or coalesce(auth.jwt()->>'aal', '') <> 'aal2'
  then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('catalog-variant:' || coalesce(p_article_id::text, ''), 0)
  );
  perform 1 from app.articles where id = p_article_id for share;
  if not found then
    raise exception 'ARTICLE_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform 1
  from app.article_variants
  where article_id = p_article_id
  order by id
  for update;
  perform 1
  from app.article_variant_aliases
  where article_id = p_article_id
  order by id
  for update;

  perform private.assert_variant_match_keys(
    p_article_id,
    p_variant_id,
    p_size,
    p_supplier_code,
    coalesce(p_aliases, array[]::text[])
  );

  -- Remove this variant's previous aliases inside the same transaction before the
  -- legacy-compatible core update. This permits moving an old alias to the label
  -- or code without weakening cross-variant collision checks.
  if p_variant_id is not null then
    delete from app.article_variant_aliases
    where article_variant_id = p_variant_id;
  end if;

  target_id := app.upsert_catalog_variant(
    p_article_id,
    p_variant_id,
    p_size,
    p_supplier_code,
    p_active,
    p_sort_order
  );

  foreach alias_value in array coalesce(p_aliases, array[]::text[])
  loop
    insert into app.article_variant_aliases(
      article_id,
      article_variant_id,
      alias,
      alias_normalized,
      created_by
    )
    values(
      p_article_id,
      target_id,
      btrim(alias_value),
      private.normalize_size_match(alias_value),
      actor
    );
  end loop;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(
    actor,
    'catalog.variant.match_keys.updated',
    'article_variant',
    target_id,
    jsonb_build_object(
      'article_id', p_article_id,
      'alias_count', coalesce(array_length(p_aliases, 1), 0)
    )
  );

  return target_id;
exception
  when unique_violation then
    raise exception 'VARIANT_MATCH_KEY_EXISTS' using errcode = '23505';
end;
$$;

revoke all on function app.upsert_catalog_variant_v2(
  uuid, uuid, text, text, text[], boolean, integer
) from public, anon;
grant execute on function app.upsert_catalog_variant_v2(
  uuid, uuid, text, text, text[], boolean, integer
) to authenticated;

create or replace function private.variant_match_conflicts(p_article_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with match_keys as (
    select variant.id variant_id,
      private.normalize_size_match(variant.size) match_key
    from app.article_variants variant
    where variant.article_id = p_article_id
    union all
    select variant.id,
      private.normalize_size_match(variant.sku)
    from app.article_variants variant
    where variant.article_id = p_article_id
      and nullif(btrim(variant.sku), '') is not null
    union all
    select alias.article_variant_id, alias.alias_normalized
    from app.article_variant_aliases alias
    where alias.article_id = p_article_id
  ),
  conflicts as (
    select match_key,
      array_agg(distinct variant_id order by variant_id) variant_ids,
      'ambiguous'::text reason
    from match_keys
    group by match_key
    having count(distinct variant_id) > 1

    union all

    select private.normalize_size_match(candidate.value),
      array_agg(distinct candidate.variant_id order by candidate.variant_id),
      'invalid_other'::text
    from (
      select variant.id variant_id, variant.size value
      from app.article_variants variant
      where variant.article_id = p_article_id
      union all
      select variant.id, variant.sku
      from app.article_variants variant
      where variant.article_id = p_article_id
        and nullif(btrim(variant.sku), '') is not null
    ) candidate
    where private.normalize_size_match(candidate.value) ~ '^ANDERS([ .…]*)$'
    group by private.normalize_size_match(candidate.value)

    union all

    select '[onveilige opmaak]'::text,
      array_agg(distinct candidate.variant_id order by candidate.variant_id),
      'unsafe_format'::text
    from (
      select variant.id variant_id, variant.size value
      from app.article_variants variant
      where variant.article_id = p_article_id
      union all
      select variant.id, variant.sku
      from app.article_variants variant
      where variant.article_id = p_article_id
        and nullif(btrim(variant.sku), '') is not null
    ) candidate
    where candidate.value ~ '[[:cntrl:]]'
      or private.contains_unsafe_size_format(candidate.value)
    having count(distinct candidate.variant_id) > 0
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'key', conflict.match_key,
        'variantIds', conflict.variant_ids,
        'reason', conflict.reason
      )
      order by conflict.reason, conflict.match_key
    ),
    '[]'::jsonb
  )
  from conflicts conflict;
$$;

revoke all on function private.variant_match_conflicts(uuid)
from public, anon, authenticated, service_role;

create or replace function app.get_catalog_order_workspace_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb;
begin
  if app.staff_role() not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  workspace := app.get_catalog_order_workspace();
  return jsonb_set(
    workspace,
    '{articles}',
    coalesce((
      select jsonb_agg(
        jsonb_set(
          article.value,
          '{variants}',
          coalesce((
            select jsonb_agg(
              variant.value || jsonb_build_object(
                'aliases',
                coalesce((
                  select jsonb_agg(alias.alias order by alias.alias_normalized)
                  from app.article_variant_aliases alias
                  where alias.article_variant_id = (variant.value->>'id')::uuid
                ), '[]'::jsonb)
              )
              order by variant.ordinality
            )
            from jsonb_array_elements(article.value->'variants')
              with ordinality as variant(value, ordinality)
          ), '[]'::jsonb),
          true
        ) || jsonb_build_object(
          'matchConflicts',
          private.variant_match_conflicts((article.value->>'id')::uuid)
        )
        order by article.ordinality
      )
      from jsonb_array_elements(workspace->'articles')
        with ordinality as article(value, ordinality)
    ), '[]'::jsonb),
    true
  );
end;
$$;

revoke all on function app.get_catalog_order_workspace_v2()
from public, anon;
grant execute on function app.get_catalog_order_workspace_v2()
to authenticated;
