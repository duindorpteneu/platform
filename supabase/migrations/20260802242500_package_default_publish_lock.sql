-- Publishing a non-default package must not clear another template's default.
-- Serialize publication per season so the partial unique indexes and the
-- exact-one business invariant are evaluated against one stable state.

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

  perform pg_advisory_xact_lock(
    hashtextextended('package-season:' || target.season_id::text, 0)
  );
  if not exists(
    select 1
    from app.seasons season
    where season.id = target.season_id
      and season.status = 'open'
    for update
  ) then
    raise exception 'PACKAGE_SEASON_NOT_OPEN' using errcode = '23514';
  end if;
  perform 1
  from app.package_templates template
  where template.id = target.template_id
    and template.season_id = target.season_id
  for update;
  perform 1
  from app.package_template_revisions revision
  where revision.season_id = target.season_id
  order by revision.id
  for update;

  select count(*) into item_count
  from app.package_template_items item
  where item.revision_id = target.id;
  if item_count = 0 or exists(
    select 1
    from app.package_template_items item
    left join app.articles article on article.id = item.article_id
    left join app.article_seasons link
      on link.article_id = article.id
      and link.season_id = target.season_id
    where item.revision_id = target.id
      and (
        article.id is null
        or not article.active
        or link.article_id is null
        or not exists(
          select 1
          from app.article_variants variant
          where variant.article_id = article.id
            and variant.active
        )
      )
  ) then
    raise exception 'PACKAGE_PRODUCT_NOT_AVAILABLE' using errcode = '23514';
  end if;

  update app.package_template_items item
  set product_name_snapshot = article.name,
      product_code_snapshot = article.code
  from app.articles article
  where item.revision_id = target.id
    and article.id = item.article_id;

  should_default := coalesce(p_make_default, false)
    or exists(
      select 1
      from app.package_template_revisions revision
      where revision.template_id = target.template_id
        and revision.active
        and revision.is_default
    )
    or not exists(
      select 1
      from app.package_template_revisions revision
      where revision.season_id = target.season_id
        and revision.active
        and revision.is_default
    );

  if should_default then
    update app.package_template_revisions revision
    set is_default = false
    where revision.season_id = target.season_id
      and revision.is_default;
  end if;
  update app.package_template_revisions revision
  set active = false,
      is_default = false
  where revision.template_id = target.template_id
    and revision.active;
  update app.package_template_revisions
  set status = 'published',
      active = true,
      is_default = should_default,
      published_by = actor,
      published_at = timezone('utc', now())
  where id = target.id;

  if not exists(
    select 1
    from app.package_template_revisions revision
    where revision.season_id = target.season_id
      and revision.active
      and revision.is_default
  ) then
    raise exception 'PACKAGE_DEFAULT_REQUIRED' using errcode = '23514';
  end if;

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
    'package.revision.published',
    'package_revision',
    target.id,
    jsonb_build_object(
      'templateId', target.template_id,
      'seasonId', target.season_id,
      'revisionNumber', target.revision_number,
      'priceCents', target.price_cents,
      'itemCount', item_count,
      'default', should_default
    ),
    p_correlation_id
  );
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

notify pgrst, 'reload schema';
