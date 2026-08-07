\set ON_ERROR_STOP on

do $$
begin
  if current_setting('server_version_num')::integer / 10000 <> 17 then
    raise exception 'restore target must run PostgreSQL 17';
  end if;
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise exception 'migration ledger is missing';
  end if;
  if exists (
    select 1
    from pg_constraint
    where connamespace in ('app'::regnamespace, 'private'::regnamespace)
      and not convalidated
  ) then
    raise exception 'one or more application constraints are not validated';
  end if;
end;
$$;

create temporary table restore_entity_counts (
  entity text primary key,
  row_count bigint not null check (row_count >= 0)
);

create temporary table restore_security_checks (
  underlying_member_rows bigint not null check (underlying_member_rows > 0),
  unauthorized_member_rows bigint not null,
  unauthorized_access_denied boolean not null
);

begin;
insert into app.members(first_name, last_name, team)
values ('Restore', 'RLS sentinel', 'RESTORE-SENTINEL');
do $$
declare
  underlying_rows bigint;
  unauthorized_rows bigint := 0;
  access_denied boolean := false;
begin
  select count(*)::bigint
  into underlying_rows
  from app.members;
  execute 'set local role authenticated';
  begin
    execute 'select count(*)::bigint from app.members'
    into unauthorized_rows;
  exception when others then
    unauthorized_rows := 0;
    access_denied := true;
  end;
  execute 'reset role';
  insert into restore_security_checks(
    underlying_member_rows,
    unauthorized_member_rows,
    unauthorized_access_denied
  ) values (
    underlying_rows,
    unauthorized_rows,
    access_denied
  );
end;
$$;
select
  underlying_member_rows as restore_underlying_member_rows,
  unauthorized_member_rows as restore_unauthorized_member_rows,
  unauthorized_access_denied as restore_unauthorized_access_denied
from restore_security_checks
\gset
rollback;

insert into restore_security_checks(
  underlying_member_rows,
  unauthorized_member_rows,
  unauthorized_access_denied
) values (
  :'restore_underlying_member_rows'::bigint,
  :'restore_unauthorized_member_rows'::bigint,
  :'restore_unauthorized_access_denied'::boolean
);

do $$
declare
  schema_name text;
  table_name text;
  counted bigint;
begin
  for schema_name, table_name in
    select namespace.nspname, relation.relname
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in ('app', 'private')
      and relation.relkind in ('r', 'p')
    order by namespace.nspname, relation.relname
  loop
    execute format(
      'select count(*) from %I.%I',
      schema_name,
      table_name
    ) into counted;
    insert into restore_entity_counts
    values (schema_name || '.' || table_name, counted);
  end loop;
end;
$$;

do $$
begin
  if not has_schema_privilege('authenticated', 'app', 'USAGE')
    or not has_function_privilege(
      'authenticated',
      'app.get_settings_workspace_v3()',
      'EXECUTE'
    )
    or has_function_privilege(
      'service_role',
      'app.get_settings_workspace_v3()',
      'EXECUTE'
    )
    or not has_function_privilege(
      'service_role',
      'app.get_staff_app_session(text)',
      'EXECUTE'
    )
    or (
      select underlying_member_rows
      from restore_security_checks
    ) < 1
    or (
      select unauthorized_member_rows
      from restore_security_checks
    ) <> 0
    or not (
      select unauthorized_access_denied
      from restore_security_checks
    )
  then
    raise exception 'restored role, ACL or negative RLS contract is invalid';
  end if;
end;
$$;

with constraint_counts as (
  select case contype
    when 'c' then 'check'
    when 'f' then 'foreign_key'
    when 'p' then 'primary_key'
    when 'u' then 'unique'
    when 'x' then 'exclusion'
    else 'other'
  end as kind,
  count(*)::integer as total
  from pg_constraint
  where connamespace in ('app'::regnamespace, 'private'::regnamespace)
  group by 1
), evidence as (
  select jsonb_build_object(
    'postgres_major', current_setting('server_version_num')::integer / 10000,
    'migration_versions', (
      select coalesce(jsonb_agg(version::text order by version::text), '[]'::jsonb)
      from supabase_migrations.schema_migrations
    ),
    'constraints', (
      select coalesce(jsonb_object_agg(kind, total order by kind), '{}'::jsonb)
      from constraint_counts
    ),
    'invalid_constraints', 0,
    'rls_enabled_tables', (
      select count(*)::integer
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('app', 'private')
        and c.relkind in ('r', 'p')
        and c.relrowsecurity
    ),
    'security_contract', jsonb_build_object(
      'authenticated_app_usage',
        has_schema_privilege('authenticated', 'app', 'USAGE'),
      'authenticated_staff_rpc_execute',
        has_function_privilege(
          'authenticated',
          'app.get_settings_workspace_v3()',
          'EXECUTE'
        ),
      'service_role_staff_rpc_denied',
        not has_function_privilege(
          'service_role',
          'app.get_settings_workspace_v3()',
          'EXECUTE'
        ),
      'service_role_session_rpc_execute',
        has_function_privilege(
          'service_role',
          'app.get_staff_app_session(text)',
          'EXECUTE'
        ),
      'unauthorized_member_rows',
        (select unauthorized_member_rows from restore_security_checks),
      'unauthorized_access_denied',
        (select unauthorized_access_denied from restore_security_checks),
      'underlying_member_rows',
        (select underlying_member_rows from restore_security_checks)
    ),
    'entity_counts', (
      select jsonb_object_agg(entity, row_count order by entity)
      from restore_entity_counts
    )
  ) as payload
)
select payload::text from evidence;
