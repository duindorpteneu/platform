\set ON_ERROR_STOP on

begin isolation level repeatable read;
set local statement_timeout = '5min';
set local lock_timeout = '5s';

\ir operational-cleanup-contract.sql

do $preflight$
begin
  if current_setting('server_version_num')::integer / 10000 <> 17 then
    raise exception 'staging cleanup requires PostgreSQL 17';
  end if;
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise exception 'migration ledger is missing';
  end if;
end;
$preflight$;

select jsonb_build_object(
  'schema_version', 1,
  'mode', 'dry-run',
  'latest_migration_version', (
    select max(version::text)
    from supabase_migrations.schema_migrations
  ),
  'state_digest', pg_temp.cleanup_state_digest(),
  'cleanup_table_count', cardinality(pg_temp.cleanup_tables()),
  'preserved_table_count', cardinality(pg_temp.preserved_tables()),
  'total_rows', pg_temp.cleanup_total_rows(),
  'non_empty_tables', (
    select count(*)
    from jsonb_each(pg_temp.cleanup_counts())
    where value::text::bigint > 0
  ),
  'blockers', pg_temp.cleanup_blockers(),
  'row_counts', pg_temp.cleanup_counts(),
  'preserved', jsonb_build_object(
    'staff_profiles', (select count(*) from app.staff_profiles),
    'active_admins', (
      select count(*)
      from app.staff_profiles
      where role = 'beheerder'
        and active
    ),
    'auth_users', (select count(*) from auth.users),
    'seasons', (select count(*) from app.seasons),
    'mail_templates', (select count(*) from app.mail_templates),
    'supplier_principals', (select count(*) from private.supplier_planner_principals)
  )
)::text;

rollback;
