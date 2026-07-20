alter table app.app_settings
  add column if not exists club_address_line text,
  add column if not exists club_postal_code text,
  add column if not exists club_city text,
  add column if not exists pickup_address_differs boolean not null default false,
  add column if not exists pickup_name text,
  add column if not exists pickup_address_line text,
  add column if not exists pickup_postal_code text,
  add column if not exists pickup_city text;

insert into app.app_settings(id, club_name)
values(true, 'Duindorp SV')
on conflict(id) do nothing;

alter table app.app_settings
  add constraint app_settings_club_address_complete check (
    (club_address_line is null and club_postal_code is null and club_city is null)
    or (club_address_line is not null and club_postal_code is not null and club_city is not null)
  ),
  add constraint app_settings_pickup_address_complete check (
    (not pickup_address_differs and pickup_name is null and pickup_address_line is null and pickup_postal_code is null and pickup_city is null)
    or (pickup_address_differs and pickup_name is not null and pickup_address_line is not null and pickup_postal_code is not null and pickup_city is not null)
  ),
  add constraint app_settings_club_address_lengths check (
    length(club_address_line) <= 160 and length(club_city) <= 120
    and club_postal_code ~ '^[0-9]{4} [A-Z]{2}$'
  ),
  add constraint app_settings_pickup_address_lengths check (
    length(pickup_name) <= 120 and length(pickup_address_line) <= 160 and length(pickup_city) <= 120
    and pickup_postal_code ~ '^[0-9]{4} [A-Z]{2}$'
  );

create or replace function app.get_settings_workspace_v2()
returns jsonb
language plpgsql
volatile
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
        'clubAddressLine', settings.club_address_line,
        'clubPostalCode', settings.club_postal_code,
        'clubCity', settings.club_city,
        'pickupAddressDiffers', settings.pickup_address_differs,
        'pickupName', settings.pickup_name,
        'pickupAddressLine', settings.pickup_address_line,
        'pickupPostalCode', settings.pickup_postal_code,
        'pickupCity', settings.pickup_city,
        'pickupLocation', settings.pickup_location,
        'activeSeasonId', settings.active_season_id,
        'mollieEnabled', settings.mollie_enabled,
        'emailEnabled', settings.email_enabled
      )
      from app.app_settings settings
      where settings.id = true
    ), jsonb_build_object(
      'clubName', 'Duindorp SV', 'contactEmail', null,
      'clubAddressLine', null, 'clubPostalCode', null, 'clubCity', null,
      'pickupAddressDiffers', false, 'pickupName', null, 'pickupAddressLine', null,
      'pickupPostalCode', null, 'pickupCity', null, 'pickupLocation', null,
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
  actor uuid;
  previous_settings app.app_settings%rowtype;
  normalized_email text := nullif(lower(trim(p_contact_email)), '');
  normalized_club_address text := nullif(trim(p_club_address_line), '');
  normalized_club_postal text := nullif(upper(regexp_replace(trim(p_club_postal_code), '[[:space:]]+', ' ', 'g')), '');
  normalized_club_city text := nullif(trim(p_club_city), '');
  normalized_pickup_name text := nullif(trim(p_pickup_name), '');
  normalized_pickup_address text := nullif(trim(p_pickup_address_line), '');
  normalized_pickup_postal text := nullif(upper(regexp_replace(trim(p_pickup_postal_code), '[[:space:]]+', ' ', 'g')), '');
  normalized_pickup_city text := nullif(trim(p_pickup_city), '');
  derived_pickup_location text;
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
  if (normalized_club_address is null) <> (normalized_club_postal is null)
    or (normalized_club_address is null) <> (normalized_club_city is null)
    or length(normalized_club_address) > 160 or length(normalized_club_city) > 120
    or (normalized_club_postal is not null and normalized_club_postal !~ '^[0-9]{4} [A-Z]{2}$')
  then
    raise exception 'SETTINGS_CLUB_ADDRESS_INVALID' using errcode = '22023';
  end if;
  if p_pickup_address_differs is null then
    raise exception 'SETTINGS_PICKUP_ADDRESS_INVALID' using errcode = '22023';
  end if;
  if p_pickup_address_differs and (
    normalized_pickup_name is null or normalized_pickup_address is null
    or normalized_pickup_postal is null or normalized_pickup_city is null
    or length(normalized_pickup_name) > 120 or length(normalized_pickup_address) > 160
    or length(normalized_pickup_city) > 120 or normalized_pickup_postal !~ '^[0-9]{4} [A-Z]{2}$'
  ) then
    raise exception 'SETTINGS_PICKUP_ADDRESS_INVALID' using errcode = '22023';
  end if;
  if p_active_season_id is not null and not exists (
    select 1 from app.seasons where id = p_active_season_id and status = 'open'
  ) then
    raise exception 'SETTINGS_ACTIVE_SEASON_INVALID' using errcode = '22023';
  end if;
  if jsonb_typeof(p_season_amounts) <> 'array' or jsonb_array_length(p_season_amounts) > 50 then
    raise exception 'SETTINGS_SEASON_AMOUNTS_INVALID' using errcode = '22023';
  end if;

  select * into previous_settings from app.app_settings where id = true for update;

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

  if p_pickup_address_differs then
    derived_pickup_location := concat_ws(', ', normalized_pickup_name, normalized_pickup_address, concat_ws(' ', normalized_pickup_postal, normalized_pickup_city));
  elsif normalized_club_address is not null then
    derived_pickup_location := concat_ws(', ', 'Duindorp SV', normalized_club_address, concat_ws(' ', normalized_club_postal, normalized_club_city));
  else
    derived_pickup_location := null;
  end if;
  if length(derived_pickup_location) > 240 then
    raise exception 'SETTINGS_PICKUP_ADDRESS_INVALID' using errcode = '22023';
  end if;

  changed_fields := array_cat(changed_fields, array_remove(array[
    case when previous_settings.contact_email is distinct from normalized_email then 'contact_email' end,
    case when previous_settings.club_address_line is distinct from normalized_club_address
      or previous_settings.club_postal_code is distinct from normalized_club_postal
      or previous_settings.club_city is distinct from normalized_club_city then 'club_address' end,
    case when previous_settings.pickup_address_differs is distinct from p_pickup_address_differs
      or previous_settings.pickup_name is distinct from (case when p_pickup_address_differs then normalized_pickup_name end)
      or previous_settings.pickup_address_line is distinct from (case when p_pickup_address_differs then normalized_pickup_address end)
      or previous_settings.pickup_postal_code is distinct from (case when p_pickup_address_differs then normalized_pickup_postal end)
      or previous_settings.pickup_city is distinct from (case when p_pickup_address_differs then normalized_pickup_city end) then 'pickup_address' end,
    case when previous_settings.active_season_id is distinct from p_active_season_id then 'active_season' end,
    case when previous_settings.mollie_enabled is distinct from p_mollie_enabled then 'mollie_enabled' end,
    case when previous_settings.email_enabled is distinct from p_email_enabled then 'email_enabled' end
  ], null));

  update app.app_settings
  set club_name = 'Duindorp SV',
      contact_email = normalized_email,
      club_address_line = normalized_club_address,
      club_postal_code = normalized_club_postal,
      club_city = normalized_club_city,
      pickup_address_differs = p_pickup_address_differs,
      pickup_name = case when p_pickup_address_differs then normalized_pickup_name end,
      pickup_address_line = case when p_pickup_address_differs then normalized_pickup_address end,
      pickup_postal_code = case when p_pickup_address_differs then normalized_pickup_postal end,
      pickup_city = case when p_pickup_address_differs then normalized_pickup_city end,
      pickup_location = derived_pickup_location,
      active_season_id = p_active_season_id,
      mollie_enabled = p_mollie_enabled,
      email_enabled = p_email_enabled,
      updated_at = timezone('utc', now())
  where id = true;

  insert into app.audit_logs(actor_user_id, action, entity_type, metadata, correlation_id)
  values(actor, 'settings.updated', 'app_settings', jsonb_build_object(
    'changedFields', to_jsonb(changed_fields),
    'seasonAmountUpdates', jsonb_array_length(p_season_amounts)
  ), p_correlation_id);

  return app.get_settings_workspace_v2();
end;
$$;

create or replace function app.create_season_v2(
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
    p_name, p_starts_on, p_ends_on, p_default_amount_cents, p_make_active, p_correlation_id
  );
  return app.get_settings_workspace_v2();
end;
$$;

alter function app.get_settings_workspace() volatile;

revoke all on function app.get_settings_workspace_v2() from public, anon;
revoke all on function app.update_settings_v2(text,text,text,text,boolean,text,text,text,text,uuid,jsonb,boolean,boolean,uuid) from public, anon;
revoke all on function app.create_season_v2(text,date,date,integer,boolean,uuid) from public, anon;
grant execute on function app.get_settings_workspace_v2() to authenticated;
grant execute on function app.update_settings_v2(text,text,text,text,boolean,text,text,text,text,uuid,jsonb,boolean,boolean,uuid) to authenticated;
grant execute on function app.create_season_v2(text,date,date,integer,boolean,uuid) to authenticated;
