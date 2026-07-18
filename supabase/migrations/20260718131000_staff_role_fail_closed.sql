create or replace function app.staff_role()
returns app.staff_role
language plpgsql
stable
security definer
set search_path = app, pg_temp
as $$
declare
  resolved_role app.staff_role;
begin
  if auth.uid() is null or coalesce(auth.jwt()->>'aal', '') <> 'aal2' then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  select role into resolved_role
  from app.staff_profiles
  where auth_user_id = auth.uid() and active = true
  limit 1;

  if resolved_role is null then
    raise exception 'STAFF_AUTHORIZATION_REQUIRED' using errcode = '42501';
  end if;

  return resolved_role;
end;
$$;
