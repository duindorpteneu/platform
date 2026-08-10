-- Explicit, auditable and pausable mail-v2 cutover. The immutable watermark is
-- retained when the runtime is paused, so historical fulfilment events are
-- never silently swept into a later activation.

create or replace function private.guard_irreversible_release_cutover()
returns trigger
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  if old.key not in (
    'dynamic_import_v2',
    'allocation_qr_v2',
    'mail_templates_v2'
  ) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if old.key = 'dynamic_import_v2' then
    if tg_op = 'DELETE' then
      if exists(
        select 1
        from private.release_cutovers cutover
        where cutover.key = old.key
      ) then
        raise exception 'DYNAMIC_IMPORT_CUTOVER_IRREVERSIBLE'
          using errcode = '55000';
      end if;
      return old;
    end if;
    if new.key is distinct from old.key then
      raise exception 'DYNAMIC_IMPORT_CUTOVER_KEY_IMMUTABLE'
        using errcode = '55000';
    end if;
    if new.enabled then
      insert into private.release_cutovers(key)
      values(new.key)
      on conflict (key) do nothing;
    end if;
    return new;
  end if;

  if old.key = 'mail_templates_v2' then
    if tg_op = 'DELETE' then
      if exists(
        select 1
        from private.release_cutovers cutover
        where cutover.key = old.key
      ) then
        raise exception 'RELEASE_CUTOVER_IRREVERSIBLE'
          using errcode = '55000';
      end if;
      return old;
    end if;
    if new.key is distinct from old.key then
      raise exception 'RELEASE_CUTOVER_KEY_IMMUTABLE'
        using errcode = '55000';
    end if;
    if new.enabled
      and not exists(
        select 1
        from private.release_cutovers cutover
        where cutover.key = old.key
      )
    then
      raise exception 'RELEASE_CUTOVER_GATE_REQUIRED'
        using errcode = '55000';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if exists(
      select 1
      from private.release_cutovers cutover
      where cutover.key = old.key
    ) then
      raise exception 'RELEASE_CUTOVER_IRREVERSIBLE' using errcode = '55000';
    end if;
    return old;
  end if;
  if new.key is distinct from old.key then
    raise exception 'RELEASE_CUTOVER_KEY_IMMUTABLE' using errcode = '55000';
  end if;
  if old.enabled and not new.enabled then
    raise exception 'RELEASE_CUTOVER_IRREVERSIBLE' using errcode = '55000';
  end if;
  if not old.enabled
    and new.enabled
    and not exists(
      select 1
      from private.release_cutovers cutover
      where cutover.key = new.key
    )
  then
    raise exception 'RELEASE_CUTOVER_GATE_REQUIRED' using errcode = '55000';
  end if;
  if new.enabled then
    insert into private.release_cutovers(key)
    values(new.key)
    on conflict (key) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function private.guard_irreversible_release_cutover()
from public, anon, authenticated, service_role;

-- A published template is not sufficient proof that a process can produce a
-- safe v2 message. Every producer is therefore registered by a forward-only
-- migration only after its selection, suppression and idempotency paths exist.
create table private.mail_v2_process_capabilities (
  template_key text primary key
    references app.mail_templates(template_key) on delete restrict,
  producer_version integer not null check (producer_version > 0),
  enabled boolean not null default true,
  registered_at timestamptz not null default timezone('utc', now())
);

alter table private.mail_v2_process_capabilities enable row level security;
revoke all on table private.mail_v2_process_capabilities
from public, anon, authenticated, service_role;

insert into private.mail_v2_process_capabilities(
  template_key,
  producer_version
) values
  ('partial_pickup', 1),
  ('package_complete', 1);

create or replace function private.mail_v2_cutover_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  catalog_count integer;
  published_count integer;
  branding_count integer;
  producer_count integer;
  state_material text;
  state_hash text;
begin
  select count(*)::integer into catalog_count
  from app.mail_templates template
  where template.active;
  select count(*)::integer into published_count
  from app.mail_templates template
  join app.mail_template_revisions revision
    on revision.template_key = template.template_key
    and revision.status = 'published'
    and revision.sanitized_html_source is not null
  where template.active;
  select count(*)::integer into branding_count
  from app.mail_branding_revisions branding
  where branding.status = 'published'
    and branding.contrast_validated;
  select count(*)::integer into producer_count
  from private.mail_v2_process_capabilities capability
  join app.mail_templates template
    on template.template_key = capability.template_key
    and template.active
  where capability.enabled;

  select concat_ws(
    E'\n',
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          template.template_key,
          coalesce(revision.revision::text, 'missing'),
          coalesce(revision.content_hash, 'missing')
        ),
        E'\n'
        order by template.template_key
      )
      from app.mail_templates template
      left join app.mail_template_revisions revision
        on revision.template_key = template.template_key
        and revision.status = 'published'
      where template.active
    ), ''),
    coalesce((
      select concat_ws(
        ':',
        branding.revision::text,
        branding.content_hash
      )
      from app.mail_branding_revisions branding
      where branding.status = 'published'
        and branding.contrast_validated
    ), 'missing'),
    coalesce((
      select string_agg(
        concat_ws(
          ':',
          capability.template_key,
          capability.producer_version::text,
          capability.enabled::text
        ),
        E'\n'
        order by capability.template_key
      )
      from private.mail_v2_process_capabilities capability
    ), ''),
    catalog_count::text,
    published_count::text,
    branding_count::text,
    producer_count::text
  ) into state_material;
  state_hash := encode(
    extensions.digest(convert_to(state_material, 'UTF8'), 'sha256'),
    'hex'
  );

  return jsonb_build_object(
    'enabled',
    coalesce((
      select flag.enabled
      from app.release_feature_flags flag
      where flag.key = 'mail_templates_v2'
    ), false),
    'cutoverAt',
    (
      select cutover.activated_at
      from private.release_cutovers cutover
      where cutover.key = 'mail_templates_v2'
    ),
    'catalogCount',
    catalog_count,
    'publishedCount',
    published_count,
    'brandingCount',
    branding_count,
    'producerCount',
    producer_count,
    'ready',
    catalog_count = 19
      and published_count = catalog_count
      and branding_count = 1
      and producer_count = catalog_count,
    'revision',
    state_hash
  );
end;
$$;

revoke all on function private.mail_v2_cutover_snapshot()
from public, anon, authenticated, service_role;

create or replace function app.get_mail_v2_cutover_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();
  return private.mail_v2_cutover_snapshot();
end;
$$;

create or replace function app.activate_mail_templates_v2(
  p_expected_revision text,
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  snapshot jsonb;
  normalized_reason text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if p_expected_revision !~ '^[0-9a-f]{64}$'
    or length(normalized_reason) not between 4 and 500
  then
    raise exception 'MAIL_V2_CUTOVER_INPUT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );
  lock table app.release_feature_flags in share row exclusive mode;
  lock table app.mail_template_revisions in share mode;
  lock table app.mail_branding_revisions in share mode;
  lock table private.mail_v2_process_capabilities in share mode;
  snapshot := private.mail_v2_cutover_snapshot();
  if (snapshot->>'enabled')::boolean
    and snapshot->>'cutoverAt' is not null
  then
    return snapshot || jsonb_build_object('reused', true);
  end if;
  if snapshot->>'revision' <> p_expected_revision then
    raise exception 'MAIL_V2_CUTOVER_STALE' using errcode = '40001';
  end if;
  if not (snapshot->>'ready')::boolean then
    raise exception 'MAIL_V2_CUTOVER_RECONCILIATION_REQUIRED'
      using errcode = '23514';
  end if;

  insert into private.release_cutovers(key)
  values('mail_templates_v2')
  on conflict (key) do nothing;
  update app.release_feature_flags
  set enabled = true,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where key = 'mail_templates_v2';
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    metadata,
    correlation_id
  ) values (
    actor,
    'release.mail_templates_v2.activated',
    'release_feature_flag',
    jsonb_build_object(
      'revision',
      p_expected_revision,
      'catalogCount',
      (snapshot->>'catalogCount')::integer,
      'publishedCount',
      (snapshot->>'publishedCount')::integer,
      'brandingCount',
      (snapshot->>'brandingCount')::integer,
      'producerCount',
      (snapshot->>'producerCount')::integer,
      'reasonDigest',
      encode(
        extensions.digest(convert_to(normalized_reason, 'UTF8'), 'sha256'),
        'hex'
      ),
      'reasonLength',
      length(normalized_reason)
    ),
    p_correlation_id
  );
  return private.mail_v2_cutover_snapshot()
    || jsonb_build_object('reused', false);
end;
$$;

create or replace function app.pause_mail_templates_v2(
  p_reason text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  normalized_reason text;
  current_enabled boolean;
  reason_digest text;
begin
  normalized_reason := regexp_replace(
    btrim(coalesce(p_reason, '')),
    '[[:space:]]+',
    ' ',
    'g'
  );
  if length(normalized_reason) not between 4 and 500 then
    raise exception 'MAIL_V2_PAUSE_INPUT_INVALID' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('mail-templates-v2-cutover', 0)
  );
  if not exists(
    select 1
    from private.release_cutovers cutover
    where cutover.key = 'mail_templates_v2'
  ) then
    raise exception 'MAIL_V2_CUTOVER_NOT_ACTIVATED'
      using errcode = '55000';
  end if;
  select flag.enabled into current_enabled
  from app.release_feature_flags flag
  where flag.key = 'mail_templates_v2'
  for update;
  if not coalesce(current_enabled, false) then
    return private.mail_v2_cutover_snapshot()
      || jsonb_build_object('reused', true);
  end if;
  reason_digest := encode(
    extensions.digest(convert_to(normalized_reason, 'UTF8'), 'sha256'),
    'hex'
  );
  update app.release_feature_flags
  set enabled = false,
      updated_by = actor,
      updated_at = timezone('utc', now())
  where key = 'mail_templates_v2';
  insert into app.audit_logs(
    actor_user_id,
    action,
    entity_type,
    metadata,
    correlation_id
  ) values (
    actor,
    'release.mail_templates_v2.paused',
    'release_feature_flag',
    jsonb_build_object(
      'reasonDigest',
      reason_digest,
      'reasonLength',
      length(normalized_reason)
    ),
    p_correlation_id
  );
  return private.mail_v2_cutover_snapshot()
    || jsonb_build_object('reused', false);
end;
$$;

revoke all on function app.get_mail_v2_cutover_snapshot()
from public, anon, authenticated, service_role;
revoke all on function app.activate_mail_templates_v2(text, text, uuid)
from public, anon, authenticated, service_role;
revoke all on function app.pause_mail_templates_v2(text, uuid)
from public, anon, authenticated, service_role;
grant execute on function app.get_mail_v2_cutover_snapshot()
to authenticated;
grant execute on function app.activate_mail_templates_v2(text, text, uuid)
to authenticated;
grant execute on function app.pause_mail_templates_v2(text, uuid)
to authenticated;

comment on function app.activate_mail_templates_v2(text, text, uuid)
is 'AAL2 administrator cutover after all 19 templates, producers and one branding revision are ready.';
comment on function app.pause_mail_templates_v2(text, uuid)
is 'Pauses projection while preserving the immutable mail-v2 cutover watermark.';
