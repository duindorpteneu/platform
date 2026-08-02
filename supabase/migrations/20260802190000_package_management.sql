-- Administrator-managed package templates and immutable published revisions.
-- No package, product or size business fixtures are created by this migration.

alter table app.package_template_items
  add column season_id uuid;

update app.package_template_items item
set season_id = revision.season_id
from app.package_template_revisions revision
where revision.id = item.revision_id;

alter table app.package_template_items
  alter column season_id set not null,
  add constraint package_template_items_revision_season_fkey
    foreign key (revision_id, season_id)
    references app.package_template_revisions(id, season_id)
    on delete restrict
    not valid,
  add constraint package_template_items_article_season_fkey
    foreign key (article_id, season_id)
    references app.article_seasons(article_id, season_id)
    on delete restrict
    not valid;

alter table app.package_template_items
  validate constraint package_template_items_revision_season_fkey;
alter table app.package_template_items
  validate constraint package_template_items_article_season_fkey;

create unique index package_template_revisions_one_draft_idx
  on app.package_template_revisions(template_id)
  where status = 'draft';

create or replace function app.audit_category(p_action text)
returns text
language sql
immutable
set search_path = app, pg_temp
as $$
  select case
    when p_action ~ '^(member|import)\.' then 'members'
    when p_action ~ '^(order|package)\.' then 'orders'
    when p_action ~ '^payment\.' then 'payments'
    when p_action ~ '^(stock|inventory|delivery|reservation|catalog)\.' then 'inventory'
    when p_action ~ '^(qr|fulfilment)\.' then 'fulfilment'
    when p_action ~ '^(email|export)\.' then 'communications'
    when p_action ~ '^(settings|staff|season)\.' then 'settings'
    when p_action ~ '^(auth|parent|security)\.' then 'security'
    else 'security'
  end;
$$;

create or replace function private.package_revision_content_hash(p_revision_id uuid)
returns text
language sql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
  select encode(extensions.digest((
    select jsonb_build_object(
      'revisionId', revision.id,
      'templateId', revision.template_id,
      'seasonId', revision.season_id,
      'key', template.template_key,
      'revisionNumber', revision.revision_number,
      'name', revision.name,
      'description', revision.description,
      'priceCents', revision.price_cents,
      'currency', revision.currency,
      'status', revision.status,
      'active', revision.active,
      'default', revision.is_default,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', item.id,
          'articleId', item.article_id,
          'quantity', item.quantity,
          'productName', item.product_name_snapshot,
          'productCode', item.product_code_snapshot,
          'sortOrder', item.sort_order
        ) order by item.sort_order, item.article_id, item.id)
        from app.package_template_items item
        where item.revision_id = revision.id
      ), '[]'::jsonb)
    )::text
    from app.package_template_revisions revision
    join app.package_templates template on template.id = revision.template_id
    where revision.id = p_revision_id
  ), 'sha256'), 'hex');
$$;

revoke all on function private.package_revision_content_hash(uuid)
  from public, anon, authenticated, service_role;

create or replace function app.guard_package_article_availability()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  if old.active and not new.active and exists(
    select 1
    from app.package_template_items item
    join app.package_template_revisions revision on revision.id = item.revision_id
    where item.article_id = old.id
      and (revision.status = 'draft' or revision.active)
  ) then
    raise exception 'PACKAGE_PRODUCT_STILL_IN_USE' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger articles_guard_package_availability
before update of active on app.articles
for each row execute function app.guard_package_article_availability();

create or replace function app.guard_package_last_active_variant()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
declare
  target_article_id uuid := case when tg_op = 'DELETE' then old.article_id else new.article_id end;
  removes_active boolean := old.active and (tg_op = 'DELETE' or not new.active);
begin
  if removes_active
    and not exists(
      select 1 from app.article_variants variant
      where variant.article_id = target_article_id
        and variant.id <> old.id
        and variant.active
    )
    and exists(
      select 1
      from app.package_template_items item
      join app.package_template_revisions revision on revision.id = item.revision_id
      where item.article_id = target_article_id
        and (revision.status = 'draft' or revision.active)
    )
  then
    raise exception 'PACKAGE_LAST_ACTIVE_VARIANT_REQUIRED' using errcode = '23514';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger article_variants_guard_package_availability
before update of active or delete on app.article_variants
for each row execute function app.guard_package_last_active_variant();

create or replace function app.get_package_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return jsonb_build_object(
    'activeSeason', (
      select jsonb_build_object('id', season.id, 'name', season.name)
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
    ),
    'seasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', season.id,
        'name', season.name,
        'status', season.status::text,
        'active', season.id = settings.active_season_id
      ) order by season.starts_on desc nulls last, season.name desc)
      from app.seasons season
      cross join app.app_settings settings
      where settings.id = true
    ), '[]'::jsonb),
    'articles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', article.id,
        'name', article.name,
        'code', article.code,
        'active', article.active,
        'seasonIds', coalesce((
          select jsonb_agg(link.season_id order by link.season_id)
          from app.article_seasons link
          where link.article_id = article.id
        ), '[]'::jsonb),
        'sizes', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', variant.id,
            'label', variant.size,
            'active', variant.active
          ) order by variant.sort_order, lower(variant.size), variant.id)
          from app.article_variants variant
          where variant.article_id = article.id
        ), '[]'::jsonb)
      ) order by article.sort_order, lower(article.name), article.id)
      from app.articles article
    ), '[]'::jsonb),
    'templates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', template.id,
        'seasonId', template.season_id,
        'seasonName', season.name,
        'key', template.template_key,
        'revisions', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', revision.id,
            'revisionNumber', revision.revision_number,
            'name', revision.name,
            'description', revision.description,
            'priceCents', revision.price_cents,
            'currency', revision.currency,
            'status', revision.status::text,
            'active', revision.active,
            'default', revision.is_default,
            'publishedAt', revision.published_at,
            'contentHash', private.package_revision_content_hash(revision.id),
            'items', coalesce((
              select jsonb_agg(jsonb_build_object(
                'id', item.id,
                'articleId', item.article_id,
                'quantity', item.quantity,
                'productName', item.product_name_snapshot,
                'productCode', item.product_code_snapshot,
                'sortOrder', item.sort_order
              ) order by item.sort_order, lower(item.product_name_snapshot), item.id)
              from app.package_template_items item
              where item.revision_id = revision.id
            ), '[]'::jsonb)
          ) order by revision.revision_number desc)
          from app.package_template_revisions revision
          where revision.template_id = template.id
        ), '[]'::jsonb)
      ) order by season.starts_on desc nulls last, season.name desc, template.template_key)
      from app.package_templates template
      join app.seasons season on season.id = template.season_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app.upsert_package_draft(
  p_template_id uuid,
  p_revision_id uuid,
  p_season_id uuid,
  p_template_key text,
  p_name text,
  p_description text,
  p_price_cents integer,
  p_items jsonb,
  p_expected_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target_template_id uuid := p_template_id;
  target_revision_id uuid := p_revision_id;
  next_revision integer;
  item_count integer;
  created boolean := false;
  current_hash text;
begin
  if p_season_id is null
    or trim(coalesce(p_template_key, '')) !~ '^[a-z0-9][a-z0-9_-]{1,63}$'
    or length(trim(coalesce(p_name, ''))) not between 1 and 120
    or length(coalesce(p_description, '')) > 2000
    or p_price_cents is null or p_price_cents < 0 or p_price_cents > 10000000
    or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) not between 1 and 25
  then
    raise exception 'PACKAGE_DRAFT_INVALID' using errcode = '22023';
  end if;
  if not exists(
    select 1 from app.seasons
    where id = p_season_id and status = 'open'
    for share
  ) then
    raise exception 'PACKAGE_SEASON_NOT_OPEN' using errcode = '23514';
  end if;
  if exists(
    select 1
    from jsonb_array_elements(p_items) entry
    where jsonb_typeof(entry) <> 'object'
      or (select count(*) from jsonb_object_keys(entry)) <> 3
      or not (entry ? 'articleId' and entry ? 'quantity' and entry ? 'sortOrder')
      or (entry->>'articleId') !~ '^[0-9a-fA-F-]{36}$'
      or jsonb_typeof(entry->'quantity') <> 'number'
      or jsonb_typeof(entry->'sortOrder') <> 'number'
      or (entry->>'quantity')::numeric <> trunc((entry->>'quantity')::numeric)
      or (entry->>'sortOrder')::numeric <> trunc((entry->>'sortOrder')::numeric)
      or (entry->>'quantity')::integer not between 1 and 25
      or (entry->>'sortOrder')::integer not between 0 and 10000
  ) or (
    select count(distinct entry->>'articleId')
    from jsonb_array_elements(p_items) entry
  ) <> jsonb_array_length(p_items) then
    raise exception 'PACKAGE_ITEMS_INVALID' using errcode = '22023';
  end if;
  if exists(
    select 1
    from jsonb_array_elements(p_items) entry
    left join app.articles article on article.id = (entry->>'articleId')::uuid
    left join app.article_seasons link
      on link.article_id = article.id and link.season_id = p_season_id
    where article.id is null
      or not article.active
      or link.article_id is null
      or not exists(
        select 1 from app.article_variants variant
        where variant.article_id = article.id and variant.active
      )
  ) then
    raise exception 'PACKAGE_PRODUCT_NOT_AVAILABLE' using errcode = '23514';
  end if;

  if target_template_id is null and (target_revision_id is not null or p_expected_hash is not null) then
    raise exception 'PACKAGE_DRAFT_INVALID' using errcode = '22023';
  end if;
  if target_template_id is null then
    insert into app.package_templates(season_id, template_key, created_by)
    values(p_season_id, trim(p_template_key), actor)
    returning id into target_template_id;
    next_revision := 1;
    insert into app.package_template_revisions(
      template_id,
      season_id,
      revision_number,
      name,
      description,
      price_cents,
      created_by
    )
    values(
      target_template_id,
      p_season_id,
      next_revision,
      trim(p_name),
      trim(coalesce(p_description, '')),
      p_price_cents,
      actor
    )
    returning id into target_revision_id;
    created := true;
  else
    perform 1
    from app.package_templates template
    where template.id = target_template_id and template.season_id = p_season_id
    for update;
    if not found then
      raise exception 'PACKAGE_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
    end if;
    if target_revision_id is null then
      raise exception 'PACKAGE_REVISION_REQUIRED' using errcode = '22023';
    end if;
    if coalesce(p_expected_hash, '') !~ '^[0-9a-f]{64}$' then
      raise exception 'PACKAGE_EXPECTED_HASH_REQUIRED' using errcode = '22023';
    end if;
    perform 1
    from app.package_template_revisions revision
    where revision.id = target_revision_id
      and revision.template_id = target_template_id
      and revision.season_id = p_season_id
      and revision.status = 'draft'
    for update;
    if not found then
      raise exception 'PACKAGE_DRAFT_NOT_EDITABLE' using errcode = '23514';
    end if;
    current_hash := private.package_revision_content_hash(target_revision_id);
    if current_hash is distinct from p_expected_hash then
      raise exception 'PACKAGE_DRAFT_STALE' using errcode = '40001';
    end if;
    update app.package_templates
    set template_key = trim(p_template_key)
    where id = target_template_id;
    update app.package_template_revisions
    set name = trim(p_name),
        description = trim(coalesce(p_description, '')),
        price_cents = p_price_cents
    where id = target_revision_id;
    delete from app.package_template_items where revision_id = target_revision_id;
  end if;

  insert into app.package_template_items(
    revision_id,
    season_id,
    article_id,
    quantity,
    product_name_snapshot,
    product_code_snapshot,
    sort_order
  )
  select target_revision_id, p_season_id, article.id, (entry->>'quantity')::integer,
    article.name, article.code, (entry->>'sortOrder')::integer
  from jsonb_array_elements(p_items) entry
  join app.articles article on article.id = (entry->>'articleId')::uuid;
  get diagnostics item_count = row_count;
  if item_count <> jsonb_array_length(p_items) then
    raise exception 'PACKAGE_ITEMS_INVALID' using errcode = '22023';
  end if;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(
    actor,
    case when created then 'package.draft.created' else 'package.draft.updated' end,
    'package_revision',
    target_revision_id,
    jsonb_build_object(
      'templateId', target_template_id,
      'seasonId', p_season_id,
      'priceCents', p_price_cents,
      'itemCount', item_count
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'templateId', target_template_id,
    'revisionId', target_revision_id,
    'created', created,
    'itemCount', item_count,
    'contentHash', private.package_revision_content_hash(target_revision_id)
  );
end;
$$;

create or replace function app.clone_package_revision(
  p_template_id uuid,
  p_source_revision_id uuid,
  p_expected_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  source_revision app.package_template_revisions%rowtype;
  target_revision_id uuid;
  item_count integer;
begin
  perform 1 from app.package_templates where id = p_template_id for update;
  if not found then
    raise exception 'PACKAGE_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists(
    select 1 from app.package_template_revisions
    where template_id = p_template_id and status = 'draft'
  ) then
    raise exception 'PACKAGE_DRAFT_ALREADY_EXISTS' using errcode = '23505';
  end if;
  select * into source_revision
  from app.package_template_revisions
  where id = p_source_revision_id
    and template_id = p_template_id
  for share;
  if not found then
    raise exception 'PACKAGE_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if source_revision.status not in ('published', 'archived')
    or coalesce(p_expected_hash, '') !~ '^[0-9a-f]{64}$'
    or private.package_revision_content_hash(source_revision.id) is distinct from p_expected_hash
    or exists(
      select 1
      from app.package_template_revisions newer
      where newer.template_id = source_revision.template_id
        and newer.revision_number > source_revision.revision_number
    )
  then
    raise exception 'PACKAGE_REVISION_STALE' using errcode = '40001';
  end if;

  insert into app.package_template_revisions(
    template_id,
    season_id,
    revision_number,
    name,
    description,
    price_cents,
    currency,
    created_by
  )
  values(
    source_revision.template_id,
    source_revision.season_id,
    source_revision.revision_number + 1,
    source_revision.name,
    source_revision.description,
    source_revision.price_cents,
    source_revision.currency,
    actor
  )
  returning id into target_revision_id;

  insert into app.package_template_items(
    revision_id,
    season_id,
    article_id,
    quantity,
    product_name_snapshot,
    product_code_snapshot,
    sort_order
  )
  select target_revision_id, source_revision.season_id, article_id, quantity,
    product_name_snapshot, product_code_snapshot, sort_order
  from app.package_template_items
  where revision_id = source_revision.id;
  get diagnostics item_count = row_count;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'package.revision.cloned', 'package_revision', target_revision_id,
    jsonb_build_object(
      'templateId', p_template_id,
      'sourceRevisionId', source_revision.id,
      'revisionNumber', source_revision.revision_number + 1,
      'itemCount', item_count
    ), p_correlation_id);
  return jsonb_build_object(
    'templateId', p_template_id,
    'revisionId', target_revision_id,
    'revisionNumber', source_revision.revision_number + 1,
    'itemCount', item_count,
    'contentHash', private.package_revision_content_hash(target_revision_id)
  );
end;
$$;

create or replace function app.publish_package_revision(
  p_revision_id uuid,
  p_make_default boolean,
  p_expected_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target app.package_template_revisions%rowtype;
  should_default boolean;
  item_count integer;
begin
  select * into target
  from app.package_template_revisions
  where id = p_revision_id
  for update;
  if not found then
    raise exception 'PACKAGE_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.status <> 'draft' then
    raise exception 'PACKAGE_REVISION_NOT_DRAFT' using errcode = '23514';
  end if;
  if coalesce(p_expected_hash, '') !~ '^[0-9a-f]{64}$'
    or private.package_revision_content_hash(target.id) is distinct from p_expected_hash
  then
    raise exception 'PACKAGE_REVISION_STALE' using errcode = '40001';
  end if;
  if not exists(
    select 1 from app.seasons
    where id = target.season_id and status = 'open'
    for update
  ) then
    raise exception 'PACKAGE_SEASON_NOT_OPEN' using errcode = '23514';
  end if;
  perform 1
  from app.package_templates
  where id = target.template_id and season_id = target.season_id
  for update;

  select count(*) into item_count
  from app.package_template_items item
  where item.revision_id = target.id;
  if item_count = 0 or exists(
    select 1
    from app.package_template_items item
    left join app.articles article on article.id = item.article_id
    left join app.article_seasons link
      on link.article_id = article.id and link.season_id = target.season_id
    where item.revision_id = target.id
      and (
        article.id is null
        or not article.active
        or link.article_id is null
        or not exists(
          select 1 from app.article_variants variant
          where variant.article_id = article.id and variant.active
        )
      )
  ) then
    raise exception 'PACKAGE_PRODUCT_NOT_AVAILABLE' using errcode = '23514';
  end if;

  update app.package_template_items item
  set product_name_snapshot = article.name,
      product_code_snapshot = article.code
  from app.articles article
  where item.revision_id = target.id and article.id = item.article_id;

  should_default := coalesce(p_make_default, false)
    or exists(
      select 1 from app.package_template_revisions revision
      where revision.template_id = target.template_id
        and revision.active and revision.is_default
    )
    or not exists(
      select 1 from app.package_template_revisions revision
      where revision.season_id = target.season_id
        and revision.active and revision.is_default
    );

  update app.package_template_revisions
  set is_default = false
  where season_id = target.season_id and is_default;
  update app.package_template_revisions
  set active = false, is_default = false
  where template_id = target.template_id and active;
  update app.package_template_revisions
  set status = 'published',
      active = true,
      is_default = should_default,
      published_by = actor,
      published_at = timezone('utc', now())
  where id = target.id;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'package.revision.published', 'package_revision', target.id,
    jsonb_build_object(
      'templateId', target.template_id,
      'seasonId', target.season_id,
      'revisionNumber', target.revision_number,
      'priceCents', target.price_cents,
      'itemCount', item_count,
      'default', should_default
    ), p_correlation_id);
  return jsonb_build_object(
    'templateId', target.template_id,
    'revisionId', target.id,
    'revisionNumber', target.revision_number,
    'active', true,
    'default', should_default,
    'contentHash', private.package_revision_content_hash(target.id)
  );
end;
$$;

create or replace function app.archive_package_revision(
  p_revision_id uuid,
  p_reason text,
  p_expected_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target app.package_template_revisions%rowtype;
begin
  if length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'PACKAGE_ARCHIVE_REASON_REQUIRED' using errcode = '22023';
  end if;
  select * into target
  from app.package_template_revisions
  where id = p_revision_id
  for update;
  if not found then
    raise exception 'PACKAGE_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if target.status <> 'published' then
    raise exception 'PACKAGE_REVISION_NOT_PUBLISHED' using errcode = '23514';
  end if;
  if coalesce(p_expected_hash, '') !~ '^[0-9a-f]{64}$'
    or private.package_revision_content_hash(target.id) is distinct from p_expected_hash
  then
    raise exception 'PACKAGE_REVISION_STALE' using errcode = '40001';
  end if;
  if target.is_default then
    raise exception 'PACKAGE_DEFAULT_REPLACEMENT_REQUIRED' using errcode = '23514';
  end if;
  update app.package_template_revisions
  set status = 'archived', active = false, is_default = false
  where id = target.id;
  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'package.revision.archived', 'package_revision', target.id,
    jsonb_build_object(
      'templateId', target.template_id,
      'seasonId', target.season_id,
      'revisionNumber', target.revision_number,
      'reason', trim(p_reason)
    ), p_correlation_id);
  return jsonb_build_object(
    'templateId', target.template_id,
    'revisionId', target.id,
    'archived', true,
    'contentHash', private.package_revision_content_hash(target.id)
  );
end;
$$;

revoke all on function app.get_package_workspace() from public, anon;
revoke all on function app.upsert_package_draft(uuid,uuid,uuid,text,text,text,integer,jsonb,text,uuid)
  from public, anon;
revoke all on function app.clone_package_revision(uuid,uuid,text,uuid) from public, anon;
revoke all on function app.publish_package_revision(uuid,boolean,text,uuid) from public, anon;
revoke all on function app.archive_package_revision(uuid,text,text,uuid) from public, anon;
grant execute on function app.get_package_workspace() to authenticated;
grant execute on function app.upsert_package_draft(uuid,uuid,uuid,text,text,text,integer,jsonb,text,uuid)
  to authenticated;
grant execute on function app.clone_package_revision(uuid,uuid,text,uuid) to authenticated;
grant execute on function app.publish_package_revision(uuid,boolean,text,uuid) to authenticated;
grant execute on function app.archive_package_revision(uuid,text,text,uuid) to authenticated;

select pg_notify('pgrst', 'reload schema');
