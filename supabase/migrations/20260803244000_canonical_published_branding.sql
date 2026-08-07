create or replace function private.published_branding_projection_v1()
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select jsonb_build_object(
    'revisionId', branding.id,
    'revision', branding.revision,
    'contentHash', branding.content_hash,
    'clubName', branding.club_name,
    'contactEmail', branding.contact_email,
    'clubAddressLine', branding.club_address_line,
    'clubPostalCode', branding.club_postal_code,
    'clubCity', branding.club_city,
    'pickupAddressDiffers', true,
    'pickupName', branding.pickup_name,
    'pickupAddressLine', branding.pickup_address_line,
    'pickupPostalCode', branding.pickup_postal_code,
    'pickupCity', branding.pickup_city,
    'pickupLocation', concat_ws(
      ', ',
      branding.pickup_name,
      branding.pickup_address_line,
      concat_ws(' ', branding.pickup_postal_code, branding.pickup_city)
    ),
    'primaryColor', branding.primary_color,
    'secondaryColor', branding.secondary_color,
    'accentColor', branding.accent_color
  )
  from app.mail_branding_revisions branding
  where branding.status = 'published';
$$;

revoke all on function private.published_branding_projection_v1()
from public, anon, authenticated, service_role;

create or replace function private.sync_published_branding_projection_v1()
returns void
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  projection jsonb := private.published_branding_projection_v1();
begin
  if projection is null then
    raise exception 'PUBLISHED_BRANDING_REQUIRED' using errcode = '23514';
  end if;
  insert into app.app_settings(id, club_name)
  values (true, 'Duindorp SV')
  on conflict (id) do nothing;
  update app.app_settings
  set club_name = projection->>'clubName',
      contact_email = projection->>'contactEmail',
      club_address_line = projection->>'clubAddressLine',
      club_postal_code = projection->>'clubPostalCode',
      club_city = projection->>'clubCity',
      pickup_address_differs = true,
      pickup_name = projection->>'pickupName',
      pickup_address_line = projection->>'pickupAddressLine',
      pickup_postal_code = projection->>'pickupPostalCode',
      pickup_city = projection->>'pickupCity',
      pickup_location = projection->>'pickupLocation',
      updated_at = timezone('utc', now())
  where id = true;
end;
$$;

revoke all on function private.sync_published_branding_projection_v1()
from public, anon, authenticated, service_role;

select private.sync_published_branding_projection_v1();

create or replace function private.branding_projection_blocker_count_v1()
returns integer
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select case
    when projection.value is null or settings.id is null then 1
    when settings.club_name is distinct from projection.value->>'clubName'
      or settings.contact_email is distinct from projection.value->>'contactEmail'
      or settings.club_address_line is distinct from projection.value->>'clubAddressLine'
      or settings.club_postal_code is distinct from projection.value->>'clubPostalCode'
      or settings.club_city is distinct from projection.value->>'clubCity'
      or settings.pickup_address_differs is distinct from true
      or settings.pickup_name is distinct from projection.value->>'pickupName'
      or settings.pickup_address_line is distinct from projection.value->>'pickupAddressLine'
      or settings.pickup_postal_code is distinct from projection.value->>'pickupPostalCode'
      or settings.pickup_city is distinct from projection.value->>'pickupCity'
      or settings.pickup_location is distinct from projection.value->>'pickupLocation'
    then 1
    else 0
  end
  from (select private.published_branding_projection_v1() value) projection
  left join app.app_settings settings on settings.id = true;
$$;

revoke all on function private.branding_projection_blocker_count_v1()
from public, anon, authenticated, service_role;

drop policy if exists "admins can manage settings" on app.app_settings;
revoke insert, update, delete on app.app_settings from authenticated;

create or replace function app.get_settings_workspace_v3()
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, pg_temp
as $$
declare
  workspace jsonb := app.get_settings_workspace_v2();
  projection jsonb := private.published_branding_projection_v1();
begin
  if projection is null then
    raise exception 'PUBLISHED_BRANDING_REQUIRED' using errcode = '23514';
  end if;
  return jsonb_set(
    workspace,
    '{settings}',
    (workspace->'settings') || jsonb_build_object(
      'clubName', projection->>'clubName',
      'contactEmail', projection->>'contactEmail',
      'clubAddressLine', projection->>'clubAddressLine',
      'clubPostalCode', projection->>'clubPostalCode',
      'clubCity', projection->>'clubCity',
      'pickupAddressDiffers', true,
      'pickupName', projection->>'pickupName',
      'pickupAddressLine', projection->>'pickupAddressLine',
      'pickupPostalCode', projection->>'pickupPostalCode',
      'pickupCity', projection->>'pickupCity',
      'pickupLocation', projection->>'pickupLocation',
      'brandingRevisionId', projection->>'revisionId',
      'brandingRevision', (projection->>'revision')::integer,
      'brandingContentHash', projection->>'contentHash'
    ),
    true
  );
end;
$$;

create or replace function app.update_settings_v3(
  p_active_season_id uuid,
  p_season_amounts jsonb,
  p_mollie_enabled boolean,
  p_email_enabled boolean,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := private.require_admin_aal2();
  previous_settings app.app_settings%rowtype;
  amount_entry jsonb;
  amount_season_id uuid;
  amount_cents integer;
  seen_season_ids uuid[] := array[]::uuid[];
  changed_fields text[] := array[]::text[];
begin
  if p_mollie_enabled is null or p_email_enabled is null
    or (
      p_active_season_id is not null
      and not exists (
        select 1 from app.seasons
        where id = p_active_season_id and status = 'open'
      )
    )
    or p_season_amounts is null
    or jsonb_typeof(p_season_amounts) <> 'array'
    or jsonb_array_length(p_season_amounts) > 50
  then
    raise exception 'SETTINGS_OPERATIONAL_VALUES_INVALID'
      using errcode = '22023';
  end if;
  if private.branding_projection_blocker_count_v1() <> 0 then
    raise exception 'SETTINGS_BRANDING_PROJECTION_DRIFT'
      using errcode = '23514';
  end if;

  select * into previous_settings
  from app.app_settings
  where id = true
  for update;

  for amount_entry in select value from jsonb_array_elements(p_season_amounts)
  loop
    if jsonb_typeof(amount_entry) <> 'object'
      or not (amount_entry ? 'seasonId' and amount_entry ? 'amountCents')
      or (select count(*) from jsonb_object_keys(amount_entry)) <> 2
      or (amount_entry->>'seasonId') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      or (amount_entry->>'amountCents') !~ '^[0-9]+$'
    then
      raise exception 'SETTINGS_SEASON_AMOUNTS_INVALID'
        using errcode = '22023';
    end if;
    amount_season_id := (amount_entry->>'seasonId')::uuid;
    amount_cents := (amount_entry->>'amountCents')::integer;
    if amount_season_id = any(seen_season_ids)
      or amount_cents < 0
      or amount_cents > 10000000
      or not exists (
        select 1 from app.seasons where id = amount_season_id
      )
    then
      raise exception 'SETTINGS_SEASON_AMOUNTS_INVALID'
        using errcode = '22023';
    end if;
    seen_season_ids := array_append(seen_season_ids, amount_season_id);
    update app.seasons
    set default_amount_cents = amount_cents
    where id = amount_season_id
      and default_amount_cents is distinct from amount_cents;
    if found then
      changed_fields := array_append(changed_fields, 'legacy_season_amount');
    end if;
  end loop;

  changed_fields := array_cat(changed_fields, array_remove(array[
    case when previous_settings.active_season_id is distinct from
      p_active_season_id then 'active_season' end,
    case when previous_settings.mollie_enabled is distinct from
      p_mollie_enabled then 'mollie_enabled' end,
    case when previous_settings.email_enabled is distinct from
      p_email_enabled then 'email_enabled' end
  ], null));
  update app.app_settings
  set active_season_id = p_active_season_id,
      mollie_enabled = p_mollie_enabled,
      email_enabled = p_email_enabled,
      updated_at = timezone('utc', now())
  where id = true;

  insert into app.audit_logs(
    actor_user_id, action, entity_type, metadata, correlation_id
  ) values (
    actor,
    'settings.updated',
    'app_settings',
    jsonb_build_object(
      'changedFields', to_jsonb(changed_fields),
      'seasonAmountUpdates', jsonb_array_length(p_season_amounts),
      'brandingRevision', (
        private.published_branding_projection_v1()->>'revision'
      )::integer
    ),
    p_correlation_id
  );
  return app.get_settings_workspace_v3();
end;
$$;

create or replace function app.update_settings_v2(
  p_contact_email text,
  p_club_address_line text,
  p_club_postal_code text,
  p_club_city text,
  p_pickup_address_differs boolean,
  p_pickup_name text,
  p_pickup_address_line text,
  p_pickup_postal_code text,
  p_pickup_city text,
  p_active_season_id uuid,
  p_season_amounts jsonb,
  p_mollie_enabled boolean,
  p_email_enabled boolean,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  projection jsonb := private.published_branding_projection_v1();
begin
  perform private.require_admin_aal2();
  if projection is null
    or lower(btrim(coalesce(p_contact_email, '')))
      is distinct from projection->>'contactEmail'
    or btrim(coalesce(p_club_address_line, ''))
      is distinct from projection->>'clubAddressLine'
    or upper(regexp_replace(
      btrim(coalesce(p_club_postal_code, '')), '[[:space:]]+', ' ', 'g'
    )) is distinct from projection->>'clubPostalCode'
    or btrim(coalesce(p_club_city, ''))
      is distinct from projection->>'clubCity'
    or p_pickup_address_differs is distinct from true
    or btrim(coalesce(p_pickup_name, ''))
      is distinct from projection->>'pickupName'
    or btrim(coalesce(p_pickup_address_line, ''))
      is distinct from projection->>'pickupAddressLine'
    or upper(regexp_replace(
      btrim(coalesce(p_pickup_postal_code, '')), '[[:space:]]+', ' ', 'g'
    )) is distinct from projection->>'pickupPostalCode'
    or btrim(coalesce(p_pickup_city, ''))
      is distinct from projection->>'pickupCity'
  then
    raise exception 'SETTINGS_BRANDING_MANAGED_SEPARATELY'
      using errcode = '22023';
  end if;
  return app.update_settings_v3(
    p_active_season_id,
    p_season_amounts,
    p_mollie_enabled,
    p_email_enabled,
    p_correlation_id
  );
end;
$$;

create or replace function app.create_season_v3(
  p_name text,
  p_starts_on date,
  p_ends_on date,
  p_default_amount_cents integer,
  p_make_active boolean default true,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform app.create_season(
    p_name,
    p_starts_on,
    p_ends_on,
    p_default_amount_cents,
    p_make_active,
    p_correlation_id
  );
  return app.get_settings_workspace_v3();
end;
$$;

revoke all on function app.get_settings_workspace_v3()
from public, anon;
revoke all on function app.update_settings_v3(
  uuid, jsonb, boolean, boolean, uuid
) from public, anon;
revoke all on function app.create_season_v3(
  text, date, date, integer, boolean, uuid
) from public, anon;
grant execute on function app.get_settings_workspace_v3() to authenticated;
grant execute on function app.update_settings_v3(
  uuid, jsonb, boolean, boolean, uuid
) to authenticated;
grant execute on function app.create_season_v3(
  text, date, date, integer, boolean, uuid
) to authenticated;
revoke all on function app.update_settings(
  text, text, uuid, jsonb, boolean, boolean, uuid
) from public, anon, authenticated, service_role;

create or replace function app.publish_mail_branding_revision_v2(
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
  perform pg_advisory_xact_lock(
    hashtextextended('mail-branding-publish', 0)
  );
  select * into target
  from app.mail_branding_revisions branding
  where branding.id = p_revision_id
  for update;
  if not found then
    raise exception 'MAIL_BRANDING_REVISION_NOT_FOUND' using errcode = 'P0002';
  end if;
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
  perform private.sync_published_branding_projection_v1();
  if private.branding_projection_blocker_count_v1() <> 0 then
    raise exception 'SETTINGS_BRANDING_PROJECTION_DRIFT'
      using errcode = '23514';
  end if;
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
      'contrastValidated', target.contrast_validated,
      'projectionChangedFields',
      jsonb_build_array(
        'club_identity', 'contact', 'club_address', 'pickup_address'
      )
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

create or replace function app.publish_mail_branding_revision_v1(
  p_revision_id uuid,
  p_expected_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language sql
security definer
set search_path = app, private, pg_temp
as $$
  select app.publish_mail_branding_revision_v2(
    p_revision_id,
    p_expected_hash,
    p_correlation_id
  );
$$;

revoke all on function app.publish_mail_branding_revision_v2(
  uuid, text, uuid
) from public, anon;
grant execute on function app.publish_mail_branding_revision_v2(
  uuid, text, uuid
) to authenticated;

create or replace function app.get_email_worker_preflight_v2(
  p_from_name text,
  p_from_email text,
  p_reply_to_email text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  branding_match_count integer;
  sender_drift_count integer;
  projection_blockers integer :=
    private.branding_projection_blocker_count_v1();
begin
  if length(btrim(coalesce(p_from_name, ''))) not between 3 and 120
    or p_from_name ~ E'[\\r\\n]'
    or p_from_email <> lower(btrim(p_from_email))
    or p_reply_to_email <> lower(btrim(p_reply_to_email))
    or p_from_email !~ '^[^[:space:]@]+@[^[:space:]@]+$'
    or p_reply_to_email !~ '^[^[:space:]@]+@[^[:space:]@]+$'
  then
    raise exception 'EMAIL_WORKER_PREFLIGHT_INVALID' using errcode = '22023';
  end if;
  select count(*)::integer into branding_match_count
  from app.mail_branding_revisions branding
  where branding.status = 'published'
    and branding.contrast_validated
    and branding.from_name = p_from_name
    and branding.from_email = p_from_email
    and branding.reply_to_email = p_reply_to_email;
  select count(*)::integer into sender_drift_count
  from private.email_jobs job
  where job.context_kind = 'fulfilment'
    and job.status in ('queued', 'retry')
    and (
      job.from_name_snapshot <> p_from_name
      or job.from_email_snapshot <> p_from_email
      or job.reply_to_email_snapshot <> p_reply_to_email
    );
  return jsonb_build_object(
    'ready',
    branding_match_count = 1
      and sender_drift_count = 0
      and projection_blockers = 0,
    'brandingMatchCount', branding_match_count,
    'senderDriftCount', sender_drift_count,
    'brandingProjectionBlockers', projection_blockers
  );
end;
$$;

create or replace function app.get_email_worker_preflight_v1(
  p_from_name text,
  p_from_email text,
  p_reply_to_email text
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select app.get_email_worker_preflight_v2(
    p_from_name,
    p_from_email,
    p_reply_to_email
  );
$$;

revoke all on function app.get_email_worker_preflight_v2(
  text, text, text
) from public, anon, authenticated;
grant execute on function app.get_email_worker_preflight_v2(
  text, text, text
) to service_role;

create or replace function app.get_mail_v2_cutover_snapshot_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  snapshot jsonb := app.get_mail_v2_cutover_snapshot();
  blockers integer := private.branding_projection_blocker_count_v1();
begin
  return snapshot || jsonb_build_object(
    'brandingProjectionBlockers', blockers,
    'ready', coalesce((snapshot->>'ready')::boolean, false) and blockers = 0
  );
end;
$$;

revoke all on function app.get_mail_v2_cutover_snapshot_v2()
from public, anon;
grant execute on function app.get_mail_v2_cutover_snapshot_v2()
to authenticated;

create or replace function app.get_allocation_qr_cutover_snapshot_v2(
  p_pepper_fingerprint text,
  p_key_version integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  snapshot jsonb := app.get_allocation_qr_cutover_snapshot(
    p_pepper_fingerprint,
    p_key_version
  );
  blockers integer := private.branding_projection_blocker_count_v1();
begin
  return snapshot || jsonb_build_object(
    'brandingProjectionBlockers', blockers,
    'ready', coalesce((snapshot->>'ready')::boolean, false) and blockers = 0
  );
end;
$$;

revoke all on function app.get_allocation_qr_cutover_snapshot_v2(
  text, integer
) from public, anon;
grant execute on function app.get_allocation_qr_cutover_snapshot_v2(
  text, integer
) to authenticated;

create or replace function app.get_operational_health_v12(
  p_current_pepper_fingerprint text,
  p_current_key_version integer,
  p_previous_pepper_fingerprint text default null,
  p_previous_key_version integer default null
)
returns jsonb
language sql
stable
security definer
set search_path = app, private, pg_temp
as $$
  select app.get_operational_health_v11(
    p_current_pepper_fingerprint,
    p_current_key_version,
    p_previous_pepper_fingerprint,
    p_previous_key_version
  ) || jsonb_build_object(
    'brandingProjection',
    jsonb_build_object(
      'blockers', private.branding_projection_blocker_count_v1()
    )
  );
$$;

revoke all on function app.get_operational_health_v12(
  text, integer, text, integer
) from public, anon, authenticated;
grant execute on function app.get_operational_health_v12(
  text, integer, text, integer
) to service_role;

create or replace function public.get_public_brand_tokens_v1()
returns jsonb
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select jsonb_build_object(
    'primaryColor', branding.primary_color,
    'secondaryColor', branding.secondary_color,
    'accentColor', branding.accent_color,
    'revision', branding.revision,
    'contentHash', branding.content_hash
  )
  from app.mail_branding_revisions branding
  where branding.status = 'published'
    and branding.contrast_validated;
$$;

revoke all on function public.get_public_brand_tokens_v1() from public;
grant execute on function public.get_public_brand_tokens_v1()
to anon, authenticated, service_role;

create or replace function app.get_settings_rpc_contract_version()
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $$
  select jsonb_build_object(
    'version', '20260803244000',
    'ready',
      count(*) = 3
      and bool_and(
        has_function_privilege('authenticated', procedure.oid, 'execute')
      )
  )
  from pg_proc procedure
  join pg_namespace namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'app'
    and procedure.proname = any(array[
      'get_settings_workspace_v3',
      'update_settings_v3',
      'create_season_v3'
    ]);
$$;

revoke all on function app.get_settings_rpc_contract_version()
from public, anon, authenticated;
grant execute on function app.get_settings_rpc_contract_version()
to service_role;

notify pgrst, 'reload schema';
