\set ON_ERROR_STOP on

\if :{?include_supabase_functions_admin}
\else
  do $$
  begin
    raise exception 'include_supabase_functions_admin ontbreekt';
  end;
  $$;
\endif

\if :{?include_postgres_realtime_admin_membership}
\else
  do $$
  begin
    raise exception 'include_postgres_realtime_admin_membership ontbreekt';
  end;
  $$;
\endif

do $$
declare
  role_name text;
begin
  foreach role_name in array array[
    'anon',
    'authenticated',
    'service_role',
    'authenticator',
    'supabase_admin',
    'supabase_auth_admin',
    'supabase_privileged_role',
    'supabase_read_only_user',
    'supabase_realtime_admin',
    'supabase_replication_admin',
    'supabase_storage_admin',
    'dashboard_user'
  ]
  loop
    if not exists (
      select 1
      from pg_roles
      where rolname = role_name
    ) then
      execute format('create role %I nologin', role_name);
    end if;
  end loop;
end;
$$;

\if :include_supabase_functions_admin
do $$
begin
  if not exists (
    select 1
    from pg_roles
    where rolname = 'supabase_functions_admin'
  ) then
    create role supabase_functions_admin nologin;
  end if;
end;
$$;
\endif

alter role anon
  nosuperuser inherit nocreaterole nocreatedb nologin
  noreplication nobypassrls connection limit -1;
alter role authenticated
  nosuperuser inherit nocreaterole nocreatedb nologin
  noreplication nobypassrls connection limit -1;
alter role authenticator
  nosuperuser noinherit nocreaterole nocreatedb login
  noreplication nobypassrls connection limit -1;
alter role dashboard_user
  nosuperuser inherit createrole createdb nologin
  replication nobypassrls connection limit -1;
alter role postgres
  nosuperuser inherit createrole createdb login
  replication bypassrls connection limit -1;
alter role service_role
  nosuperuser inherit nocreaterole nocreatedb nologin
  noreplication bypassrls connection limit -1;
alter role supabase_admin
  superuser inherit createrole createdb login
  replication bypassrls connection limit -1;
alter role supabase_auth_admin
  nosuperuser noinherit createrole nocreatedb login
  noreplication nobypassrls connection limit -1;
\if :include_supabase_functions_admin
  alter role supabase_functions_admin
    nosuperuser noinherit createrole nocreatedb login
    noreplication nobypassrls connection limit -1;
\endif
alter role supabase_read_only_user
  nosuperuser inherit nocreaterole nocreatedb login
  noreplication bypassrls connection limit -1;
alter role supabase_replication_admin
  nosuperuser inherit nocreaterole nocreatedb login
  replication nobypassrls connection limit -1;
alter role supabase_storage_admin
  nosuperuser noinherit createrole nocreatedb login
  noreplication nobypassrls connection limit -1;

grant anon, authenticated, service_role to authenticator;
grant
  anon,
  authenticated,
  authenticator,
  pg_create_subscription,
  pg_monitor,
  pg_read_all_data,
  pg_signal_backend,
  service_role,
  supabase_privileged_role
to postgres;
\if :include_postgres_realtime_admin_membership
  grant supabase_realtime_admin to postgres;
\endif
\if :include_supabase_functions_admin
  grant supabase_functions_admin to postgres;
\endif
grant pg_monitor, pg_read_all_data to supabase_read_only_user;
grant authenticator to supabase_storage_admin;

create schema if not exists extensions authorization supabase_admin;
create extension if not exists pgcrypto with schema extensions;
