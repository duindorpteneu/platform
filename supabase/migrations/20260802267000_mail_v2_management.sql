-- Administrator-only management contract for mail-v2 templates and branding.
-- Drafts may be incomplete, but publishing always revalidates the complete
-- typed shortcode and protected-node contract inside the database.

create or replace function private.mail_document_shortcode_keys(p_document jsonb)
returns text[]
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with recursive nodes(node) as (
    select p_document
    union all
    select child.value
    from nodes parent
    cross join lateral jsonb_array_elements(
      case
        when jsonb_typeof(parent.node->'content') = 'array'
          then parent.node->'content'
        else '[]'::jsonb
      end
    ) child
  )
  select coalesce(
    array_agg(distinct node#>>'{attrs,key}' order by node#>>'{attrs,key}')
      filter (where node->>'type' = 'shortcode'),
    '{}'::text[]
  )
  from nodes;
$$;

create or replace function private.mail_document_protected_nodes(p_document jsonb)
returns text[]
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  with recursive nodes(node) as (
    select p_document
    union all
    select child.value
    from nodes parent
    cross join lateral jsonb_array_elements(
      case
        when jsonb_typeof(parent.node->'content') = 'array'
          then parent.node->'content'
        else '[]'::jsonb
      end
    ) child
  )
  select coalesce(
    array_agg(node#>>'{attrs,kind}' order by node#>>'{attrs,kind}')
      filter (where node->>'type' = 'protectedBlock'),
    '{}'::text[]
  )
  from nodes;
$$;

create or replace function private.mail_template_content_is_allowed(
  p_template_key text,
  p_subject_source text,
  p_preheader_source text,
  p_body_tiptap jsonb,
  p_sanitized_html_source text,
  p_text_fallback_source text
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  definition app.mail_templates%rowtype;
  shortcode_keys text[];
  protected_nodes text[];
begin
  select * into definition
  from app.mail_templates template
  where template.template_key = p_template_key
    and template.active;
  if not found
    or not private.mail_document_is_safe(p_body_tiptap)
    or not private.mail_source_tokens_are_safe(
      p_subject_source,
      definition.allowed_shortcode_keys
    )
    or not private.mail_source_tokens_are_safe(
      p_preheader_source,
      definition.allowed_shortcode_keys
    )
    or not private.mail_source_tokens_are_safe(
      p_text_fallback_source,
      definition.allowed_shortcode_keys
    )
    or (
      p_sanitized_html_source is not null
      and not private.mail_html_is_safe(p_sanitized_html_source)
    )
  then
    return false;
  end if;
  shortcode_keys := private.mail_document_shortcode_keys(p_body_tiptap);
  protected_nodes := private.mail_document_protected_nodes(p_body_tiptap);
  return shortcode_keys <@ definition.allowed_shortcode_keys
    and protected_nodes <@ definition.allowed_protected_nodes;
end;
$$;

create or replace function private.mail_template_revision_is_publishable(
  p_revision_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  target app.mail_template_revisions%rowtype;
  definition app.mail_templates%rowtype;
  protected_nodes text[];
  required_node text;
begin
  select * into target
  from app.mail_template_revisions revision
  where revision.id = p_revision_id;
  if not found or target.status <> 'draft' then
    return false;
  end if;
  select * into definition
  from app.mail_templates template
  where template.template_key = target.template_key
    and template.active;
  if not found
    or target.sanitized_html_source is null
    or not private.mail_template_content_is_allowed(
      target.template_key,
      target.subject_source,
      target.preheader_source,
      target.body_tiptap,
      target.sanitized_html_source,
      target.text_fallback_source
    )
  then
    return false;
  end if;

  protected_nodes := private.mail_document_protected_nodes(
    target.body_tiptap
  );
  foreach required_node in array definition.required_protected_nodes
  loop
    if (
      select count(*) <> 1
      from unnest(protected_nodes) node
      where node = required_node
    ) then
      return false;
    end if;
  end loop;
  return true;
end;
$$;

revoke all on function private.mail_document_shortcode_keys(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.mail_document_protected_nodes(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.mail_template_content_is_allowed(
  text, text, text, jsonb, text, text
) from public, anon, authenticated, service_role;
revoke all on function private.mail_template_revision_is_publishable(uuid)
from public, anon, authenticated, service_role;

create or replace function private.mail_branding_values_hash(
  p_club_name text,
  p_logo_asset_path text,
  p_from_name text,
  p_from_email text,
  p_reply_to_email text,
  p_contact_email text,
  p_club_address_line text,
  p_club_postal_code text,
  p_club_city text,
  p_pickup_name text,
  p_pickup_address_line text,
  p_pickup_postal_code text,
  p_pickup_city text,
  p_privacy_url text,
  p_primary_color text,
  p_secondary_color text,
  p_accent_color text,
  p_footer_text text,
  p_contrast_validated boolean
)
returns text
language sql
immutable
set search_path = extensions, pg_catalog, pg_temp
as $$
  select encode(
    extensions.digest(
      convert_to(
        concat_ws(
          E'\n',
          p_club_name,
          p_logo_asset_path,
          btrim(p_from_name),
          lower(btrim(p_from_email)),
          lower(btrim(p_reply_to_email)),
          lower(btrim(p_contact_email)),
          btrim(p_club_address_line),
          p_club_postal_code,
          btrim(p_club_city),
          btrim(p_pickup_name),
          btrim(p_pickup_address_line),
          p_pickup_postal_code,
          btrim(p_pickup_city),
          p_privacy_url,
          p_primary_color,
          p_secondary_color,
          p_accent_color,
          btrim(p_footer_text),
          p_contrast_validated::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

revoke all on function private.mail_branding_values_hash(
  text, text, text, text, text, text, text, text, text, text,
  text, text, text, text, text, text, text, text, boolean
) from public, anon, authenticated, service_role;

create or replace function private.guard_mail_template_revision()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MAIL_TEMPLATE_REVISION_IMMUTABLE' using errcode = '55000';
  end if;
  if new.content_hash <> private.mail_template_content_hash(
    new.template_key,
    new.internal_name,
    new.subject_source,
    new.preheader_source,
    new.body_tiptap,
    new.sanitized_html_source,
    new.text_fallback_source
  ) then
    raise exception 'MAIL_TEMPLATE_CONTENT_HASH_INVALID'
      using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id
      or new.template_key is distinct from old.template_key
      or new.revision is distinct from old.revision
      or new.created_by is distinct from old.created_by
      or new.creation_source is distinct from old.creation_source
      or new.created_at is distinct from old.created_at
    then
      raise exception 'MAIL_TEMPLATE_REVISION_IDENTITY_IMMUTABLE'
        using errcode = '55000';
    end if;
    if old.status = 'draft' and new.status = 'draft' then
      if new.published_by is not null
        or new.published_at is not null
        or new.archived_by is not null
        or new.archived_at is not null
      then
        raise exception 'MAIL_TEMPLATE_REVISION_STATE_INVALID'
          using errcode = '23514';
      end if;
      return new;
    end if;
    if old.status = 'draft' and new.status = 'published' then
      if new.internal_name is distinct from old.internal_name
        or new.subject_source is distinct from old.subject_source
        or new.preheader_source is distinct from old.preheader_source
        or new.body_tiptap is distinct from old.body_tiptap
        or new.sanitized_html_source is distinct from old.sanitized_html_source
        or new.text_fallback_source is distinct from old.text_fallback_source
        or new.schema_version is distinct from old.schema_version
        or new.content_hash is distinct from old.content_hash
      then
        raise exception 'MAIL_TEMPLATE_PUBLISH_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    if old.status = 'published' and new.status = 'archived' then
      if new.internal_name is distinct from old.internal_name
        or new.subject_source is distinct from old.subject_source
        or new.preheader_source is distinct from old.preheader_source
        or new.body_tiptap is distinct from old.body_tiptap
        or new.sanitized_html_source is distinct from old.sanitized_html_source
        or new.text_fallback_source is distinct from old.text_fallback_source
        or new.schema_version is distinct from old.schema_version
        or new.content_hash is distinct from old.content_hash
        or new.published_by is distinct from old.published_by
        or new.published_at is distinct from old.published_at
      then
        raise exception 'MAIL_TEMPLATE_ARCHIVE_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    raise exception 'MAIL_TEMPLATE_REVISION_TRANSITION_INVALID'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

create or replace function private.guard_mail_branding_revision()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MAIL_BRANDING_REVISION_IMMUTABLE' using errcode = '55000';
  end if;
  if new.content_hash <> private.mail_branding_values_hash(
    new.club_name,
    new.logo_asset_path,
    new.from_name,
    new.from_email,
    new.reply_to_email,
    new.contact_email,
    new.club_address_line,
    new.club_postal_code,
    new.club_city,
    new.pickup_name,
    new.pickup_address_line,
    new.pickup_postal_code,
    new.pickup_city,
    new.privacy_url,
    new.primary_color,
    new.secondary_color,
    new.accent_color,
    new.footer_text,
    new.contrast_validated
  ) then
    raise exception 'MAIL_BRANDING_CONTENT_HASH_INVALID'
      using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id
      or new.revision is distinct from old.revision
      or new.created_by is distinct from old.created_by
      or new.creation_source is distinct from old.creation_source
      or new.created_at is distinct from old.created_at
    then
      raise exception 'MAIL_BRANDING_REVISION_IDENTITY_IMMUTABLE'
        using errcode = '55000';
    end if;
    if old.status = 'draft' and new.status = 'draft' then
      if new.published_by is not null
        or new.published_at is not null
        or new.archived_by is not null
        or new.archived_at is not null
      then
        raise exception 'MAIL_BRANDING_REVISION_STATE_INVALID'
          using errcode = '23514';
      end if;
      return new;
    end if;
    if old.status = 'draft' and new.status = 'published' then
      if row(
        new.club_name, new.logo_asset_path, new.from_name, new.from_email,
        new.reply_to_email, new.contact_email, new.club_address_line,
        new.club_postal_code, new.club_city, new.pickup_name,
        new.pickup_address_line, new.pickup_postal_code, new.pickup_city,
        new.privacy_url, new.primary_color, new.secondary_color,
        new.accent_color, new.footer_text, new.contrast_validated,
        new.content_hash
      ) is distinct from row(
        old.club_name, old.logo_asset_path, old.from_name, old.from_email,
        old.reply_to_email, old.contact_email, old.club_address_line,
        old.club_postal_code, old.club_city, old.pickup_name,
        old.pickup_address_line, old.pickup_postal_code, old.pickup_city,
        old.privacy_url, old.primary_color, old.secondary_color,
        old.accent_color, old.footer_text, old.contrast_validated,
        old.content_hash
      ) then
        raise exception 'MAIL_BRANDING_PUBLISH_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    if old.status = 'published' and new.status = 'archived' then
      if row(
        new.club_name, new.logo_asset_path, new.from_name, new.from_email,
        new.reply_to_email, new.contact_email, new.club_address_line,
        new.club_postal_code, new.club_city, new.pickup_name,
        new.pickup_address_line, new.pickup_postal_code, new.pickup_city,
        new.privacy_url, new.primary_color, new.secondary_color,
        new.accent_color, new.footer_text, new.contrast_validated,
        new.content_hash, new.published_by, new.published_at
      ) is distinct from row(
        old.club_name, old.logo_asset_path, old.from_name, old.from_email,
        old.reply_to_email, old.contact_email, old.club_address_line,
        old.club_postal_code, old.club_city, old.pickup_name,
        old.pickup_address_line, old.pickup_postal_code, old.pickup_city,
        old.privacy_url, old.primary_color, old.secondary_color,
        old.accent_color, old.footer_text, old.contrast_validated,
        old.content_hash, old.published_by, old.published_at
      ) then
        raise exception 'MAIL_BRANDING_ARCHIVE_CONTENT_IMMUTABLE'
          using errcode = '55000';
      end if;
      return new;
    end if;
    raise exception 'MAIL_BRANDING_REVISION_TRANSITION_INVALID'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

create or replace function app.get_mail_workspace_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return jsonb_build_object(
    'featureEnabled', coalesce((
      select flag.enabled
      from app.release_feature_flags flag
      where flag.key = 'mail_templates_v2'
    ), false),
    'cutoverAt', (
      select cutover.activated_at
      from private.release_cutovers cutover
      where cutover.key = 'mail_templates_v2'
    ),
    'shortcodes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', definition.key,
        'valueType', definition.value_type,
        'description', definition.description
      ) order by definition.key)
      from app.mail_shortcode_definitions definition
    ), '[]'::jsonb),
    'protectedNodes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', definition.key,
        'description', definition.description
      ) order by definition.key)
      from app.mail_protected_node_definitions definition
    ), '[]'::jsonb),
    'templates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', template.template_key,
        'internalName', template.internal_name,
        'process', template.process,
        'audience', template.audience,
        'active', template.active,
        'allowedShortcodes', template.allowed_shortcode_keys,
        'requiredShortcodes', template.required_shortcode_keys,
        'allowedProtectedNodes', template.allowed_protected_nodes,
        'requiredProtectedNodes', template.required_protected_nodes,
        'draft', case when draft.id is null then null else jsonb_build_object(
          'id', draft.id,
          'revision', draft.revision,
          'status', draft.status,
          'internalName', draft.internal_name,
          'subjectSource', draft.subject_source,
          'preheaderSource', draft.preheader_source,
          'bodyTipTap', draft.body_tiptap,
          'sanitizedHtmlSource', draft.sanitized_html_source,
          'textFallbackSource', draft.text_fallback_source,
          'schemaVersion', draft.schema_version,
          'contentHash', draft.content_hash,
          'createdAt', draft.created_at,
          'updatedAt', draft.updated_at
        ) end,
        'published', case
          when published.id is null then null
          else jsonb_build_object(
            'id', published.id,
            'revision', published.revision,
            'status', published.status,
            'internalName', published.internal_name,
            'subjectSource', published.subject_source,
            'preheaderSource', published.preheader_source,
            'bodyTipTap', published.body_tiptap,
            'sanitizedHtmlSource', published.sanitized_html_source,
            'textFallbackSource', published.text_fallback_source,
            'schemaVersion', published.schema_version,
            'contentHash', published.content_hash,
            'publishedAt', published.published_at,
            'publishedBy', published.published_by
          )
        end
      ) order by template.process, template.internal_name)
      from app.mail_templates template
      left join app.mail_template_revisions draft
        on draft.template_key = template.template_key
        and draft.status = 'draft'
      left join app.mail_template_revisions published
        on published.template_key = template.template_key
        and published.status = 'published'
    ), '[]'::jsonb),
    'branding', jsonb_build_object(
      'draft', (
        select jsonb_build_object(
          'id', branding.id,
          'revision', branding.revision,
          'status', branding.status,
          'clubName', branding.club_name,
          'logoAssetPath', branding.logo_asset_path,
          'fromName', branding.from_name,
          'fromEmail', branding.from_email,
          'replyToEmail', branding.reply_to_email,
          'contactEmail', branding.contact_email,
          'clubAddressLine', branding.club_address_line,
          'clubPostalCode', branding.club_postal_code,
          'clubCity', branding.club_city,
          'pickupName', branding.pickup_name,
          'pickupAddressLine', branding.pickup_address_line,
          'pickupPostalCode', branding.pickup_postal_code,
          'pickupCity', branding.pickup_city,
          'privacyUrl', branding.privacy_url,
          'primaryColor', branding.primary_color,
          'secondaryColor', branding.secondary_color,
          'accentColor', branding.accent_color,
          'footerText', branding.footer_text,
          'contrastValidated', branding.contrast_validated,
          'contentHash', branding.content_hash,
          'creationSource', branding.creation_source,
          'publishedBy', branding.published_by,
          'publishedAt', branding.published_at,
          'createdAt', branding.created_at,
          'updatedAt', branding.updated_at
        )
        from app.mail_branding_revisions branding
        where branding.status = 'draft'
      ),
      'published', (
        select jsonb_build_object(
          'id', branding.id,
          'revision', branding.revision,
          'status', branding.status,
          'clubName', branding.club_name,
          'logoAssetPath', branding.logo_asset_path,
          'fromName', branding.from_name,
          'fromEmail', branding.from_email,
          'replyToEmail', branding.reply_to_email,
          'contactEmail', branding.contact_email,
          'clubAddressLine', branding.club_address_line,
          'clubPostalCode', branding.club_postal_code,
          'clubCity', branding.club_city,
          'pickupName', branding.pickup_name,
          'pickupAddressLine', branding.pickup_address_line,
          'pickupPostalCode', branding.pickup_postal_code,
          'pickupCity', branding.pickup_city,
          'privacyUrl', branding.privacy_url,
          'primaryColor', branding.primary_color,
          'secondaryColor', branding.secondary_color,
          'accentColor', branding.accent_color,
          'footerText', branding.footer_text,
          'contrastValidated', branding.contrast_validated,
          'contentHash', branding.content_hash,
          'creationSource', branding.creation_source,
          'publishedBy', branding.published_by,
          'publishedAt', branding.published_at,
          'createdAt', branding.created_at,
          'updatedAt', branding.updated_at
        )
        from app.mail_branding_revisions branding
        where branding.status = 'published'
      )
    )
  );
end;
$$;

create or replace function app.save_mail_template_draft_v1(
  p_template_key text,
  p_expected_hash text,
  p_internal_name text,
  p_subject_source text,
  p_preheader_source text,
  p_body_tiptap jsonb,
  p_sanitized_html_source text,
  p_text_fallback_source text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  target app.mail_template_revisions%rowtype;
  next_revision integer;
  new_hash text;
begin
  if p_template_key is null
    or p_internal_name is null
    or length(btrim(p_internal_name)) not between 3 and 120
    or p_subject_source is null
    or length(btrim(p_subject_source)) not between 3 and 180
    or p_subject_source ~ '[[:cntrl:]<>]'
    or p_preheader_source is null
    or length(btrim(p_preheader_source)) not between 3 and 240
    or p_preheader_source ~ '[[:cntrl:]<>]'
    or p_text_fallback_source is null
    or length(btrim(p_text_fallback_source)) not between 3 and 20000
    or not private.mail_template_content_is_allowed(
      p_template_key,
      btrim(p_subject_source),
      btrim(p_preheader_source),
      p_body_tiptap,
      nullif(btrim(p_sanitized_html_source), ''),
      btrim(p_text_fallback_source)
    )
  then
    raise exception 'MAIL_TEMPLATE_DRAFT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-template-draft:' || p_template_key, 0)
  );
  select * into target
  from app.mail_template_revisions revision
  where revision.template_key = p_template_key
    and revision.status = 'draft'
  for update;

  new_hash := private.mail_template_content_hash(
    p_template_key,
    btrim(p_internal_name),
    btrim(p_subject_source),
    btrim(p_preheader_source),
    p_body_tiptap,
    nullif(btrim(p_sanitized_html_source), ''),
    btrim(p_text_fallback_source)
  );
  if found then
    if p_expected_hash is null
      or p_expected_hash !~ '^[0-9a-f]{64}$'
      or target.content_hash <> p_expected_hash
    then
      raise exception 'MAIL_TEMPLATE_DRAFT_STALE' using errcode = '40001';
    end if;
    update app.mail_template_revisions
    set internal_name = btrim(p_internal_name),
        subject_source = btrim(p_subject_source),
        preheader_source = btrim(p_preheader_source),
        body_tiptap = p_body_tiptap,
        sanitized_html_source = nullif(btrim(p_sanitized_html_source), ''),
        text_fallback_source = btrim(p_text_fallback_source),
        content_hash = new_hash,
        updated_at = timezone('utc', now())
    where id = target.id
    returning * into target;
  else
    if p_expected_hash is not null then
      raise exception 'MAIL_TEMPLATE_DRAFT_STALE' using errcode = '40001';
    end if;
    select coalesce(max(revision.revision), 0) + 1 into next_revision
    from app.mail_template_revisions revision
    where revision.template_key = p_template_key;
    insert into app.mail_template_revisions(
      template_key,
      revision,
      status,
      internal_name,
      subject_source,
      preheader_source,
      body_tiptap,
      sanitized_html_source,
      text_fallback_source,
      content_hash,
      created_by,
      creation_source
    ) values (
      p_template_key,
      next_revision,
      'draft',
      btrim(p_internal_name),
      btrim(p_subject_source),
      btrim(p_preheader_source),
      p_body_tiptap,
      nullif(btrim(p_sanitized_html_source), ''),
      btrim(p_text_fallback_source),
      new_hash,
      actor,
      'staff'
    )
    returning * into target;
  end if;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'mail_template.draft_saved',
    'mail_template_revision',
    target.id,
    jsonb_build_object(
      'templateKey', target.template_key,
      'revision', target.revision,
      'contentHash', target.content_hash
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'revisionId', target.id,
    'templateKey', target.template_key,
    'revision', target.revision,
    'status', target.status,
    'contentHash', target.content_hash,
    'updatedAt', target.updated_at
  );
end;
$$;

create or replace function app.publish_mail_template_revision_v1(
  p_revision_id uuid,
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
  target app.mail_template_revisions%rowtype;
  publish_time timestamptz := timezone('utc', now());
begin
  if p_revision_id is null
    or p_expected_hash !~ '^[0-9a-f]{64}$'
  then
    raise exception 'MAIL_TEMPLATE_PUBLISH_INVALID' using errcode = '22023';
  end if;
  select * into target
  from app.mail_template_revisions revision
  where revision.id = p_revision_id
  for update;
  if not found then
    raise exception 'MAIL_TEMPLATE_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-template-publish:' || target.template_key, 0)
  );
  if target.status <> 'draft'
    or target.content_hash <> p_expected_hash
  then
    raise exception 'MAIL_TEMPLATE_PUBLISH_STALE' using errcode = '40001';
  end if;
  if not private.mail_template_revision_is_publishable(target.id) then
    raise exception 'MAIL_TEMPLATE_NOT_PUBLISHABLE' using errcode = '23514';
  end if;

  update app.mail_template_revisions
  set status = 'archived',
      archived_by = actor,
      archived_at = publish_time,
      updated_at = publish_time
  where template_key = target.template_key
    and status = 'published';

  update app.mail_template_revisions
  set status = 'published',
      published_by = actor,
      published_at = publish_time,
      updated_at = publish_time
  where id = target.id
  returning * into target;

  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    entity_id,
    metadata,
    correlation_id
  ) values (
    actor,
    'mail_template.published',
    'mail_template_revision',
    target.id,
    jsonb_build_object(
      'templateKey', target.template_key,
      'revision', target.revision,
      'contentHash', target.content_hash
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'revisionId', target.id,
    'templateKey', target.template_key,
    'revision', target.revision,
    'status', target.status,
    'contentHash', target.content_hash,
    'publishedAt', target.published_at
  );
end;
$$;

create or replace function app.save_mail_branding_draft_v1(
  p_expected_hash text,
  p_branding jsonb,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
#variable_conflict use_variable
declare
  actor uuid := private.require_admin_aal2();
  target app.mail_branding_revisions%rowtype;
  next_revision integer;
  new_hash text;
  club_name text;
  logo_asset_path text;
  from_name text;
  from_email text;
  reply_to_email text;
  contact_email text;
  club_address_line text;
  club_postal_code text;
  club_city text;
  pickup_name text;
  pickup_address_line text;
  pickup_postal_code text;
  pickup_city text;
  privacy_url text;
  primary_color text;
  secondary_color text;
  accent_color text;
  footer_text text;
  contrast_validated boolean;
begin
  if jsonb_typeof(p_branding) <> 'object'
    or (
      select count(*) <> 19
      from jsonb_object_keys(p_branding)
    )
    or not p_branding ?& array[
      'clubName', 'logoAssetPath', 'fromName', 'fromEmail',
      'replyToEmail', 'contactEmail', 'clubAddressLine',
      'clubPostalCode', 'clubCity', 'pickupName', 'pickupAddressLine',
      'pickupPostalCode', 'pickupCity', 'privacyUrl', 'primaryColor',
      'secondaryColor', 'accentColor', 'footerText', 'contrastValidated'
    ]
  then
    raise exception 'MAIL_BRANDING_DRAFT_INVALID' using errcode = '22023';
  end if;
  club_name := p_branding->>'clubName';
  logo_asset_path := p_branding->>'logoAssetPath';
  from_name := btrim(p_branding->>'fromName');
  from_email := lower(btrim(p_branding->>'fromEmail'));
  reply_to_email := lower(btrim(p_branding->>'replyToEmail'));
  contact_email := lower(btrim(p_branding->>'contactEmail'));
  club_address_line := btrim(p_branding->>'clubAddressLine');
  club_postal_code := upper(btrim(p_branding->>'clubPostalCode'));
  club_city := btrim(p_branding->>'clubCity');
  pickup_name := btrim(p_branding->>'pickupName');
  pickup_address_line := btrim(p_branding->>'pickupAddressLine');
  pickup_postal_code := upper(btrim(p_branding->>'pickupPostalCode'));
  pickup_city := btrim(p_branding->>'pickupCity');
  privacy_url := p_branding->>'privacyUrl';
  primary_color := upper(p_branding->>'primaryColor');
  secondary_color := upper(p_branding->>'secondaryColor');
  accent_color := upper(p_branding->>'accentColor');
  footer_text := btrim(p_branding->>'footerText');
  if jsonb_typeof(p_branding->'contrastValidated') <> 'boolean' then
    raise exception 'MAIL_BRANDING_DRAFT_INVALID' using errcode = '22023';
  end if;
  contrast_validated := (p_branding->>'contrastValidated')::boolean;

  if club_name <> 'Duindorp SV'
    or logo_asset_path <> '/duindorp-sv-logo.png'
    or privacy_url <> 'https://duindorpsv.nl/privacy'
    or length(from_name) not between 3 and 120
    or from_name ~ '[[:cntrl:]]'
    or from_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or reply_to_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or contact_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or length(club_address_line) not between 3 and 160
    or club_postal_code !~ '^[0-9]{4} [A-Z]{2}$'
    or length(club_city) not between 2 and 120
    or length(pickup_name) not between 3 and 120
    or length(pickup_address_line) not between 3 and 160
    or pickup_postal_code !~ '^[0-9]{4} [A-Z]{2}$'
    or length(pickup_city) not between 2 and 120
    or primary_color !~ '^#[0-9A-F]{6}$'
    or secondary_color !~ '^#[0-9A-F]{6}$'
    or accent_color !~ '^#[0-9A-F]{6}$'
    or length(footer_text) not between 3 and 1000
    or footer_text ~ '[<>]'
  then
    raise exception 'MAIL_BRANDING_DRAFT_INVALID' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('mail-branding-draft', 0)
  );
  select * into target
  from app.mail_branding_revisions branding
  where branding.status = 'draft'
  for update;
  new_hash := private.mail_branding_values_hash(
    club_name, logo_asset_path, from_name, from_email, reply_to_email,
    contact_email, club_address_line, club_postal_code, club_city,
    pickup_name, pickup_address_line, pickup_postal_code, pickup_city,
    privacy_url, primary_color, secondary_color, accent_color,
    footer_text, contrast_validated
  );
  if found then
    if p_expected_hash is null
      or p_expected_hash !~ '^[0-9a-f]{64}$'
      or target.content_hash <> p_expected_hash
    then
      raise exception 'MAIL_BRANDING_DRAFT_STALE' using errcode = '40001';
    end if;
    update app.mail_branding_revisions
    set club_name = club_name,
        logo_asset_path = logo_asset_path,
        from_name = from_name,
        from_email = from_email,
        reply_to_email = reply_to_email,
        contact_email = contact_email,
        club_address_line = club_address_line,
        club_postal_code = club_postal_code,
        club_city = club_city,
        pickup_name = pickup_name,
        pickup_address_line = pickup_address_line,
        pickup_postal_code = pickup_postal_code,
        pickup_city = pickup_city,
        privacy_url = privacy_url,
        primary_color = primary_color,
        secondary_color = secondary_color,
        accent_color = accent_color,
        footer_text = footer_text,
        contrast_validated = contrast_validated,
        content_hash = new_hash,
        updated_at = timezone('utc', now())
    where id = target.id
    returning * into target;
  else
    if p_expected_hash is not null then
      raise exception 'MAIL_BRANDING_DRAFT_STALE' using errcode = '40001';
    end if;
    select coalesce(max(branding.revision), 0) + 1 into next_revision
    from app.mail_branding_revisions branding;
    insert into app.mail_branding_revisions(
      revision, status, club_name, logo_asset_path, from_name, from_email,
      reply_to_email, contact_email, club_address_line, club_postal_code,
      club_city, pickup_name, pickup_address_line, pickup_postal_code,
      pickup_city, privacy_url, primary_color, secondary_color,
      accent_color, footer_text, contrast_validated, content_hash,
      created_by, creation_source
    ) values (
      next_revision, 'draft', club_name, logo_asset_path, from_name,
      from_email, reply_to_email, contact_email, club_address_line,
      club_postal_code, club_city, pickup_name, pickup_address_line,
      pickup_postal_code, pickup_city, privacy_url, primary_color,
      secondary_color, accent_color, footer_text, contrast_validated,
      new_hash, actor, 'staff'
    )
    returning * into target;
  end if;
  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata, correlation_id
  ) values (
    actor,
    'mail_branding.draft_saved',
    'mail_branding_revision',
    target.id,
    jsonb_build_object(
      'revision', target.revision,
      'contentHash', target.content_hash,
      'contrastValidated', target.contrast_validated
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'revisionId', target.id,
    'revision', target.revision,
    'status', target.status,
    'contentHash', target.content_hash,
    'updatedAt', target.updated_at
  );
end;
$$;

create or replace function app.publish_mail_branding_revision_v1(
  p_revision_id uuid,
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
  target app.mail_branding_revisions%rowtype;
  publish_time timestamptz := timezone('utc', now());
begin
  if p_revision_id is null
    or p_expected_hash !~ '^[0-9a-f]{64}$'
  then
    raise exception 'MAIL_BRANDING_PUBLISH_INVALID' using errcode = '22023';
  end if;
  select * into target
  from app.mail_branding_revisions branding
  where branding.id = p_revision_id
  for update;
  if not found then
    raise exception 'MAIL_BRANDING_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-branding-publish', 0)
  );
  if target.status <> 'draft'
    or target.content_hash <> p_expected_hash
  then
    raise exception 'MAIL_BRANDING_PUBLISH_STALE' using errcode = '40001';
  end if;
  if not target.contrast_validated then
    raise exception 'MAIL_BRANDING_CONTRAST_REQUIRED' using errcode = '23514';
  end if;
  update app.mail_branding_revisions
  set status = 'archived',
      archived_by = actor,
      archived_at = publish_time,
      updated_at = publish_time
  where status = 'published';
  update app.mail_branding_revisions
  set status = 'published',
      published_by = actor,
      published_at = publish_time,
      updated_at = publish_time
  where id = target.id
  returning * into target;
  insert into app.audit_logs(
    actor_user_id, action, entity_type, entity_id, metadata, correlation_id
  ) values (
    actor,
    'mail_branding.published',
    'mail_branding_revision',
    target.id,
    jsonb_build_object(
      'revision', target.revision,
      'contentHash', target.content_hash,
      'contrastValidated', target.contrast_validated
    ),
    p_correlation_id
  );
  return jsonb_build_object(
    'revisionId', target.id,
    'revision', target.revision,
    'status', target.status,
    'contentHash', target.content_hash,
    'publishedAt', target.published_at
  );
end;
$$;

revoke all on function app.get_mail_workspace_v1()
from public, anon, authenticated;
grant execute on function app.get_mail_workspace_v1()
to authenticated;
revoke all on function app.save_mail_template_draft_v1(
  text, text, text, text, text, jsonb, text, text, uuid
) from public, anon, authenticated;
grant execute on function app.save_mail_template_draft_v1(
  text, text, text, text, text, jsonb, text, text, uuid
) to authenticated;
revoke all on function app.publish_mail_template_revision_v1(
  uuid, text, uuid
) from public, anon, authenticated;
grant execute on function app.publish_mail_template_revision_v1(
  uuid, text, uuid
) to authenticated;
revoke all on function app.save_mail_branding_draft_v1(
  text, jsonb, uuid
) from public, anon, authenticated;
grant execute on function app.save_mail_branding_draft_v1(
  text, jsonb, uuid
) to authenticated;
revoke all on function app.publish_mail_branding_revision_v1(
  uuid, text, uuid
) from public, anon, authenticated;
grant execute on function app.publish_mail_branding_revision_v1(
  uuid, text, uuid
) to authenticated;
