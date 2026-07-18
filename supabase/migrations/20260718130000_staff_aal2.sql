create or replace function app.is_staff_member()
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select coalesce(auth.jwt()->>'aal', '') = 'aal2'
    and exists (
      select 1 from app.staff_profiles
      where auth_user_id = auth.uid() and active = true
    );
$$;

create or replace function app.staff_role()
returns app.staff_role
language sql
stable
security definer
set search_path = app, pg_temp
as $$
  select role from app.staff_profiles
  where auth_user_id = auth.uid()
    and active = true
    and coalesce(auth.jwt()->>'aal', '') = 'aal2'
  limit 1;
$$;
