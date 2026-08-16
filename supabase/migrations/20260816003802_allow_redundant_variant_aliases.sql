-- A size label and supplier code already are exact import match keys. Operators
-- reasonably repeat either value in the optional alias field; treating that
-- redundancy as a collision made every such first variant fail before INSERT.
-- Keep aliases unique among themselves and across other variants, but discard
-- aliases that add no match key beyond their own variant's label or code.

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
  alias_keys text[] := array[]::text[];
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
    if not code_key = any(requested_keys) then
      requested_keys := array_append(requested_keys, code_key);
    end if;
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
    if alias_key = any(alias_keys) then
      raise exception 'DUPLICATE_VARIANT_MATCH_KEY' using errcode = '23505';
    end if;
    alias_keys := array_append(alias_keys, alias_key);

    if alias_key = size_key or (code_key is not null and alias_key = code_key) then
      continue;
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

revoke all on function private.assert_variant_match_keys(
  uuid, uuid, text, text, text[]
) from public, anon, authenticated, service_role;

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
  size_key text;
  code_key text;
  alias_value text;
  alias_key text;
  effective_aliases text[] := array[]::text[];
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

  size_key := private.normalize_size_match(p_size);
  if nullif(btrim(p_supplier_code), '') is not null then
    code_key := private.normalize_size_match(p_supplier_code);
  end if;
  foreach alias_value in array coalesce(p_aliases, array[]::text[])
  loop
    alias_key := private.normalize_size_match(alias_value);
    if alias_key <> size_key
      and (code_key is null or alias_key <> code_key)
    then
      effective_aliases := array_append(effective_aliases, btrim(alias_value));
    end if;
  end loop;

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

  foreach alias_value in array effective_aliases
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
      alias_value,
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
      'alias_count', coalesce(array_length(effective_aliases, 1), 0)
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
