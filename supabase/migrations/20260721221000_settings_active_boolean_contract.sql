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
        'active', coalesce(season.id = settings.active_season_id, false)
      ) order by coalesce(season.id = settings.active_season_id, false) desc, season.starts_on desc nulls last, season.name)
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

revoke all on function app.get_settings_workspace_v2() from public, anon;
grant execute on function app.get_settings_workspace_v2() to authenticated;

select pg_notify('pgrst', 'reload schema');
