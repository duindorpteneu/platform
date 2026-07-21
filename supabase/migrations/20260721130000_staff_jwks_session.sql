create or replace function app.create_staff_app_session_for_user(p_auth_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = app, private, extensions, pg_temp
as $$
declare
  profile app.staff_profiles%rowtype;
  session_token text;
begin
  if p_auth_user_id is null then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  select * into profile
  from app.staff_profiles item
  where item.auth_user_id = p_auth_user_id and item.active = true;
  if profile.auth_user_id is null then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  session_token := encode(gen_random_bytes(32), 'hex');
  insert into private.staff_sessions(token_hash, auth_user_id, expires_at)
  values (
    encode(digest(session_token, 'sha256'), 'hex'),
    profile.auth_user_id,
    timezone('utc', now()) + interval '8 hours'
  );

  return jsonb_build_object(
    'sessionToken', session_token,
    'context', jsonb_build_object(
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
    )
  );
end;
$$;

revoke all on function app.create_staff_session_exchange() from authenticated;
revoke all on function app.create_staff_app_session_for_user(uuid) from public, anon, authenticated;
grant execute on function app.create_staff_app_session_for_user(uuid) to service_role;

notify pgrst, 'reload schema';
