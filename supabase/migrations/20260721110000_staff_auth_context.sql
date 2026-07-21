create or replace function app.get_staff_auth_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare
  profile app.staff_profiles%rowtype;
begin
  if auth.uid() is null or coalesce(auth.jwt()->>'aal', '') <> 'aal2' then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  select * into profile
  from app.staff_profiles
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if profile.auth_user_id is null then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'userId', profile.auth_user_id,
    'displayName', profile.display_name,
    'role', profile.role,
    'activeSeason', (
      select jsonb_build_object('id', season.id, 'name', season.name)
      from app.app_settings settings
      join app.seasons season on season.id = settings.active_season_id
      where settings.id = true
      limit 1
    )
  );
end;
$$;

revoke all on function app.get_staff_auth_context() from public, anon;
grant execute on function app.get_staff_auth_context() to authenticated;
