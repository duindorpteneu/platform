create or replace function private.require_admin_aal2()
returns uuid
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null or coalesce(auth.jwt()->>'aal', '') <> 'aal2' or not exists (
    select 1 from app.staff_profiles
    where auth_user_id = actor and active = true and role = 'beheerder'
  ) then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  return actor;
end;
$$;

create or replace function app.audit_category(p_action text)
returns text
language sql
immutable
set search_path = app, pg_temp
as $$
  select case
    when p_action ~ '^(member|import)\.' then 'members'
    when p_action ~ '^order\.' then 'orders'
    when p_action ~ '^payment\.' then 'payments'
    when p_action ~ '^(stock|inventory|delivery|reservation)\.' then 'inventory'
    when p_action ~ '^(qr|fulfilment)\.' then 'fulfilment'
    when p_action ~ '^(email|export)\.' then 'communications'
    when p_action ~ '^(settings|staff)\.' then 'settings'
    when p_action ~ '^(auth|parent|security)\.' then 'security'
    else 'security'
  end;
$$;

drop policy if exists "operations can read audit" on app.audit_logs;
drop policy if exists "settings audit access" on app.audit_logs;
create policy "settings audit access" on app.audit_logs
for select using (
  app.staff_role() = 'beheerder'
  or (
    app.staff_role() = 'kledingcommissie'
    and app.audit_category(action) in (
      'members', 'orders', 'payments', 'inventory', 'fulfilment', 'communications'
    )
  )
);

create index if not exists audit_logs_category_created_idx
  on app.audit_logs (app.audit_category(action), created_at desc);

create or replace function app.get_settings_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
begin
  perform private.require_admin_aal2();

  return jsonb_build_object(
    'settings', coalesce((
      select jsonb_build_object(
        'clubName', settings.club_name,
        'contactEmail', settings.contact_email,
        'pickupLocation', settings.pickup_location,
        'activeSeasonId', settings.active_season_id,
        'mollieEnabled', settings.mollie_enabled,
        'emailEnabled', settings.email_enabled
      )
      from app.app_settings settings
      where settings.id = true
    ), jsonb_build_object(
      'clubName', 'Duindorp SV', 'contactEmail', null, 'pickupLocation', null,
      'activeSeasonId', null, 'mollieEnabled', false, 'emailEnabled', false
    )),
    'seasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', season.id,
        'name', season.name,
        'status', season.status,
        'startsOn', season.starts_on,
        'endsOn', season.ends_on,
        'defaultAmountCents', season.default_amount_cents,
        'active', season.id = settings.active_season_id
      ) order by (season.id = settings.active_season_id) desc, season.starts_on desc nulls last, season.name)
      from app.seasons season
      cross join app.app_settings settings
      where settings.id = true
    ), '[]'::jsonb),
    'staff', coalesce((
      select jsonb_agg(jsonb_build_object(
        'authUserId', profile.auth_user_id,
        'displayName', profile.display_name,
        'role', profile.role,
        'active', profile.active,
        'lastLoginAt', profile.last_login_at,
        'createdAt', profile.created_at,
        'isCurrentUser', profile.auth_user_id = auth.uid()
      ) order by profile.active desc, profile.display_name)
      from app.staff_profiles profile
    ), '[]'::jsonb),
    'roles', jsonb_build_array('beheerder', 'kledingcommissie', 'uitgifte')
  );
end;
$$;

create or replace function app.update_settings(
  p_contact_email text,
  p_pickup_location text,
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
  actor uuid;
  normalized_email text := nullif(lower(trim(p_contact_email)), '');
  normalized_location text := nullif(trim(p_pickup_location), '');
  amount_entry jsonb;
  amount_season_id uuid;
  amount_cents integer;
  changed_fields text[] := array[]::text[];
begin
  actor := private.require_admin_aal2();

  if normalized_email is not null and (
    length(normalized_email) > 254 or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ) then
    raise exception 'SETTINGS_CONTACT_EMAIL_INVALID' using errcode = '22023';
  end if;
  if normalized_location is not null and length(normalized_location) > 240 then
    raise exception 'SETTINGS_PICKUP_LOCATION_INVALID' using errcode = '22023';
  end if;
  if p_active_season_id is null or not exists (
    select 1 from app.seasons where id = p_active_season_id and status = 'open'
  ) then
    raise exception 'SETTINGS_ACTIVE_SEASON_INVALID' using errcode = '22023';
  end if;
  if jsonb_typeof(p_season_amounts) <> 'array' or jsonb_array_length(p_season_amounts) > 50 then
    raise exception 'SETTINGS_SEASON_AMOUNTS_INVALID' using errcode = '22023';
  end if;

  for amount_entry in select value from jsonb_array_elements(p_season_amounts)
  loop
    if jsonb_typeof(amount_entry) <> 'object'
      or not (amount_entry ? 'seasonId' and amount_entry ? 'amountCents')
      or (select count(*) from jsonb_object_keys(amount_entry)) <> 2
      or (amount_entry->>'seasonId') !~ '^[0-9a-fA-F-]{36}$'
      or (amount_entry->>'amountCents') !~ '^[0-9]+$'
    then
      raise exception 'SETTINGS_SEASON_AMOUNTS_INVALID' using errcode = '22023';
    end if;
    amount_season_id := (amount_entry->>'seasonId')::uuid;
    amount_cents := (amount_entry->>'amountCents')::integer;
    if amount_cents < 0 or amount_cents > 10000000
      or not exists (select 1 from app.seasons where id = amount_season_id)
    then
      raise exception 'SETTINGS_SEASON_AMOUNTS_INVALID' using errcode = '22023';
    end if;
    update app.seasons
      set default_amount_cents = amount_cents
      where id = amount_season_id and default_amount_cents is distinct from amount_cents;
    if found then changed_fields := array_append(changed_fields, 'season_amount'); end if;
  end loop;

  update app.app_settings settings
  set club_name = 'Duindorp SV',
      contact_email = normalized_email,
      pickup_location = normalized_location,
      active_season_id = p_active_season_id,
      mollie_enabled = p_mollie_enabled,
      email_enabled = p_email_enabled,
      updated_at = timezone('utc', now())
  where settings.id = true
  returning array_cat(changed_fields, array_remove(array[
    case when settings.contact_email is distinct from normalized_email then 'contact_email' end,
    case when settings.pickup_location is distinct from normalized_location then 'pickup_location' end,
    case when settings.active_season_id is distinct from p_active_season_id then 'active_season' end,
    case when settings.mollie_enabled is distinct from p_mollie_enabled then 'mollie_enabled' end,
    case when settings.email_enabled is distinct from p_email_enabled then 'email_enabled' end
  ], null)) into changed_fields;

  insert into app.audit_logs(actor_user_id, action, entity_type, metadata, correlation_id)
  values(actor, 'settings.updated', 'app_settings', jsonb_build_object(
    'changedFields', to_jsonb(changed_fields),
    'seasonAmountUpdates', jsonb_array_length(p_season_amounts)
  ), p_correlation_id);

  return app.get_settings_workspace();
end;
$$;

create or replace function app.update_staff_profile(
  p_auth_user_id uuid,
  p_display_name text,
  p_role app.staff_role,
  p_active boolean,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  target app.staff_profiles%rowtype;
  normalized_name text := trim(p_display_name);
begin
  actor := private.require_admin_aal2();
  select * into target from app.staff_profiles where auth_user_id = p_auth_user_id for update;
  if target.id is null then raise exception 'STAFF_PROFILE_NOT_FOUND' using errcode = 'P0002'; end if;
  if length(normalized_name) not between 2 and 100 then
    raise exception 'STAFF_DISPLAY_NAME_INVALID' using errcode = '22023';
  end if;
  if p_auth_user_id = actor and (not p_active or p_role <> 'beheerder') then
    raise exception 'STAFF_SELF_LOCKOUT_BLOCKED' using errcode = '23514';
  end if;
  if target.role = 'beheerder' and target.active and (not p_active or p_role <> 'beheerder')
    and (select count(*) from app.staff_profiles where role = 'beheerder' and active = true) <= 1
  then
    raise exception 'STAFF_LAST_ADMIN_BLOCKED' using errcode = '23514';
  end if;

  update app.staff_profiles
  set display_name = normalized_name, role = p_role, active = p_active
  where auth_user_id = p_auth_user_id;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'staff.updated', 'staff_profile', target.id, jsonb_build_object(
    'roleBefore', target.role, 'roleAfter', p_role,
    'activeBefore', target.active, 'activeAfter', p_active,
    'displayNameChanged', target.display_name is distinct from normalized_name
  ), p_correlation_id);

  return jsonb_build_object(
    'authUserId', p_auth_user_id, 'displayName', normalized_name,
    'role', p_role, 'active', p_active
  );
end;
$$;

create or replace function app.register_invited_staff(
  p_auth_user_id uuid,
  p_display_name text,
  p_role app.staff_role,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, private, pg_temp
as $$
declare
  actor uuid;
  profile_id uuid;
  normalized_name text := trim(p_display_name);
begin
  actor := private.require_admin_aal2();
  if length(normalized_name) not between 2 and 100 then
    raise exception 'STAFF_DISPLAY_NAME_INVALID' using errcode = '22023';
  end if;
  if exists (select 1 from app.staff_profiles where auth_user_id = p_auth_user_id) then
    raise exception 'STAFF_PROFILE_EXISTS' using errcode = '23505';
  end if;

  insert into app.staff_profiles(auth_user_id, display_name, role, active)
  values(p_auth_user_id, normalized_name, p_role, true)
  returning id into profile_id;

  insert into app.audit_logs(actor_user_id, action, entity_type, entity_id, metadata, correlation_id)
  values(actor, 'staff.invited', 'staff_profile', profile_id, jsonb_build_object('role', p_role), p_correlation_id);

  return jsonb_build_object(
    'authUserId', p_auth_user_id, 'displayName', normalized_name,
    'role', p_role, 'active', true
  );
end;
$$;

create or replace function app.get_audit_workspace(
  p_category text default null,
  p_action text default null,
  p_actor_user_id uuid default null,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, private, pg_temp
as $$
declare
  viewer_role app.staff_role := app.staff_role();
  safe_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if viewer_role not in ('beheerder', 'kledingcommissie') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;
  if p_category is not null and p_category not in (
    'members', 'orders', 'payments', 'inventory', 'fulfilment',
    'communications', 'settings', 'security'
  ) then
    raise exception 'AUDIT_FILTER_INVALID' using errcode = '22023';
  end if;
  if p_action is not null and (length(p_action) > 100 or p_action !~ '^[a-z][a-z0-9_.-]+$') then
    raise exception 'AUDIT_FILTER_INVALID' using errcode = '22023';
  end if;
  if viewer_role = 'kledingcommissie' and p_category in ('settings', 'security') then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'viewerRole', viewer_role,
    'categories', case when viewer_role = 'beheerder'
      then jsonb_build_array('members','orders','payments','inventory','fulfilment','communications','settings','security')
      else jsonb_build_array('members','orders','payments','inventory','fulfilment','communications') end,
    'actors', coalesce((
      select jsonb_agg(jsonb_build_object('id', profile.auth_user_id, 'displayName', profile.display_name)
        order by profile.display_name)
      from app.staff_profiles profile
    ), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(row_to_json(entry)::jsonb order by entry."createdAt" desc, entry.id desc)
      from (
        select audit.id::text as id,
          audit.action,
          app.audit_category(audit.action) as category,
          audit.entity_type as "entityType",
          audit.entity_id as "entityId",
          audit.metadata,
          audit.correlation_id as "correlationId",
          audit.created_at as "createdAt",
          audit.actor_user_id as "actorUserId",
          coalesce(profile.display_name, 'Systeem') as "actorName"
        from app.audit_logs audit
        left join app.staff_profiles profile on profile.auth_user_id = audit.actor_user_id
        where (viewer_role = 'beheerder' or app.audit_category(audit.action) in (
          'members', 'orders', 'payments', 'inventory', 'fulfilment', 'communications'
        ))
          and (p_category is null or app.audit_category(audit.action) = p_category)
          and (p_action is null or audit.action = p_action)
          and (p_actor_user_id is null or audit.actor_user_id = p_actor_user_id)
          and (p_before is null or audit.created_at < p_before)
        order by audit.created_at desc, audit.id desc
        limit safe_limit
      ) entry
    ), '[]'::jsonb),
    'limit', safe_limit
  );
end;
$$;

revoke all on function private.require_admin_aal2() from public, anon, authenticated;
revoke all on function app.get_settings_workspace() from public, anon;
revoke all on function app.update_settings(text,text,uuid,jsonb,boolean,boolean,uuid) from public, anon;
revoke all on function app.update_staff_profile(uuid,text,app.staff_role,boolean,uuid) from public, anon;
revoke all on function app.register_invited_staff(uuid,text,app.staff_role,uuid) from public, anon;
revoke all on function app.get_audit_workspace(text,text,uuid,timestamptz,integer) from public, anon;
grant execute on function app.get_settings_workspace() to authenticated;
grant execute on function app.update_settings(text,text,uuid,jsonb,boolean,boolean,uuid) to authenticated;
grant execute on function app.update_staff_profile(uuid,text,app.staff_role,boolean,uuid) to authenticated;
grant execute on function app.register_invited_staff(uuid,text,app.staff_role,uuid) to authenticated;
grant execute on function app.get_audit_workspace(text,text,uuid,timestamptz,integer) to authenticated;
