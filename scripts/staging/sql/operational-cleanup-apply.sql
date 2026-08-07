\set ON_ERROR_STOP on
\if :{?cleanup_commit}
\else
\set cleanup_commit false
\endif

begin isolation level serializable;
set local statement_timeout = '10min';
set local lock_timeout = '30s';

\ir operational-cleanup-contract.sql

\o /dev/null
select set_config('duindorp.cleanup.expected_state_digest', :'expected_state_digest', true);
select set_config('duindorp.cleanup.release_sha', :'release_sha', true);
select set_config('duindorp.cleanup.run_id', :'cleanup_run_id', true);
select set_config('duindorp.cleanup.backup_checksum', :'backup_checksum', true);
select set_config('duindorp.cleanup.backup_artifact_id', :'backup_artifact_id', true);
select set_config('duindorp.cleanup.commit', :'cleanup_commit', true);
\o

do $input_contract$
begin
  if current_setting('duindorp.cleanup.expected_state_digest') !~ '^[a-f0-9]{64}$' then
    raise exception 'expected state digest is invalid';
  end if;
  if current_setting('duindorp.cleanup.release_sha') !~ '^[a-f0-9]{40}$' then
    raise exception 'release SHA is invalid';
  end if;
  if current_setting('duindorp.cleanup.run_id') !~ '^[a-f0-9-]{36}$'
    or current_setting('duindorp.cleanup.run_id')::uuid::text
      <> current_setting('duindorp.cleanup.run_id')
  then
    raise exception 'cleanup run ID is invalid';
  end if;
  if current_setting('duindorp.cleanup.backup_checksum') !~ '^[a-f0-9]{64}$' then
    raise exception 'backup checksum is invalid';
  end if;
  if current_setting('duindorp.cleanup.backup_artifact_id') !~ '^[1-9][0-9]*$' then
    raise exception 'backup artifact ID is invalid';
  end if;
  if current_setting('duindorp.cleanup.commit') not in ('true', 'false') then
    raise exception 'cleanup commit contract is invalid';
  end if;
end;
$input_contract$;

do $lock_tables$
declare
  lock_statement text;
begin
  select 'lock table '
    || string_agg(qualified_table, ', ' order by qualified_table)
    || ' in access exclusive mode'
  into lock_statement
  from unnest(pg_temp.cleanup_tables()) as listed(qualified_table);
  execute lock_statement;
end;
$lock_tables$;

do $preconditions$
begin
  if pg_temp.cleanup_state_digest()
    <> current_setting('duindorp.cleanup.expected_state_digest')
  then
    raise exception 'operational state changed after the verified backup';
  end if;
  if not exists (
    select 1
    from app.staff_profiles as profile
    join auth.users as auth_user on auth_user.id = profile.auth_user_id
    where profile.role = 'beheerder'
      and profile.active
  ) then
    raise exception 'no active administrator Auth account is present';
  end if;
  if exists (
    select 1
    from jsonb_each(pg_temp.cleanup_blockers())
    where value::text::bigint <> 0
  ) then
    raise exception 'one or more cleanup safety blockers are active';
  end if;
end;
$preconditions$;

create temporary table cleanup_preservation_proof (
  key text primary key,
  value text not null
) on commit drop;

insert into cleanup_preservation_proof (key, value)
values
  ('preserved_state', pg_temp.preserved_state_digest()),
  ('audit_state', (
    select encode(
      digest(
        coalesce(
          string_agg(
            encode(digest(to_jsonb(audit_row)::text, 'sha256'), 'hex'),
            ''
            order by encode(digest(to_jsonb(audit_row)::text, 'sha256'), 'hex')
          ),
          ''
        ),
        'sha256'
      ),
      'hex'
    )
    from app.audit_logs as audit_row
  )),
  ('audit_count', (select count(*)::text from app.audit_logs)),
  ('staff_profiles', pg_temp.staff_profile_digest()),
  ('auth_users', pg_temp.auth_user_id_digest()),
  ('migration_ledger', pg_temp.migration_ledger_digest()),
  ('constraints', pg_temp.constraint_digest()),
  ('staff_count', (select count(*)::text from app.staff_profiles)),
  ('active_admin_count', (
    select count(*)::text
    from app.staff_profiles
    where role = 'beheerder'
      and active
  )),
  ('auth_user_count', (select count(*)::text from auth.users)),
  ('removed_rows', pg_temp.cleanup_total_rows()::text);

do $truncate_allowlist$
declare
  truncate_statement text;
begin
  select 'truncate table '
    || string_agg(qualified_table, ', ' order by qualified_table)
    || ' restart identity'
  into truncate_statement
  from unnest(pg_temp.cleanup_tables()) as listed(qualified_table);
  execute truncate_statement;
end;
$truncate_allowlist$;

insert into app.audit_logs (
  actor_user_id,
  action,
  entity_type,
  entity_id,
  metadata,
  correlation_id
)
values (
  null,
  'staging.domain_cleanup.completed',
  'staging_environment',
  :'cleanup_run_id'::uuid,
  jsonb_build_object(
    'release_sha', :'release_sha',
    'cleanup_run_id', :'cleanup_run_id',
    'cleanup_table_count', cardinality(pg_temp.cleanup_tables()),
    'removed_rows', (select value::bigint from cleanup_preservation_proof where key = 'removed_rows'),
    'backup_checksum', :'backup_checksum',
    'backup_artifact_id', :'backup_artifact_id'
  ),
  :'cleanup_run_id'::uuid
);

do $postconditions$
declare
  qualified_table text;
  state record;
begin
  foreach qualified_table in array pg_temp.cleanup_tables()
  loop
    select * into state from pg_temp.table_state(qualified_table);
    if state.row_count <> 0 then
      raise exception 'cleanup table is not empty: %', qualified_table;
    end if;
  end loop;

  if (
    select count(*)
    from app.audit_logs
  ) <> (
    select value::bigint + 1
    from cleanup_preservation_proof
    where key = 'audit_count'
  )
    or (
      select count(*)
      from app.audit_logs
      where action = 'staging.domain_cleanup.completed'
        and correlation_id = current_setting('duindorp.cleanup.run_id')::uuid
    ) <> 1
    or (
      select encode(
        digest(
          coalesce(
            string_agg(
              encode(digest(to_jsonb(audit_row)::text, 'sha256'), 'hex'),
              ''
              order by encode(digest(to_jsonb(audit_row)::text, 'sha256'), 'hex')
            ),
            ''
          ),
          'sha256'
        ),
        'hex'
      )
      from app.audit_logs as audit_row
      where correlation_id is distinct from current_setting('duindorp.cleanup.run_id')::uuid
    ) <> (select value from cleanup_preservation_proof where key = 'audit_state')
    or pg_temp.preserved_state_digest()
      <> (select value from cleanup_preservation_proof where key = 'preserved_state')
    or pg_temp.staff_profile_digest()
      <> (select value from cleanup_preservation_proof where key = 'staff_profiles')
    or pg_temp.auth_user_id_digest()
      <> (select value from cleanup_preservation_proof where key = 'auth_users')
    or (select count(*)::text from app.staff_profiles)
      <> (select value from cleanup_preservation_proof where key = 'staff_count')
    or (
      select count(*)::text
      from app.staff_profiles
      where role = 'beheerder'
        and active
    ) <> (select value from cleanup_preservation_proof where key = 'active_admin_count')
    or (select count(*)::text from auth.users)
      <> (select value from cleanup_preservation_proof where key = 'auth_user_count')
    or pg_temp.migration_ledger_digest()
      <> (select value from cleanup_preservation_proof where key = 'migration_ledger')
    or pg_temp.constraint_digest()
      <> (select value from cleanup_preservation_proof where key = 'constraints')
    or exists (
      select 1
      from app.staff_profiles as profile
      left join auth.users as auth_user on auth_user.id = profile.auth_user_id
      where auth_user.id is null
    )
  then
    raise exception 'a preserved staff, Auth or configuration invariant changed';
  end if;
end;
$postconditions$;

select jsonb_build_object(
  'schema_version', 1,
  'result', case when :'cleanup_commit'::boolean then 'committed' else 'rolled_back_test' end,
  'cleanup_run_id', :'cleanup_run_id',
  'cleanup_table_count', cardinality(pg_temp.cleanup_tables()),
  'removed_rows', (select value::bigint from cleanup_preservation_proof where key = 'removed_rows'),
  'remaining_operational_rows', 0,
    'cleanup_audit_rows', (
      select count(*)
      from app.audit_logs
      where action = 'staging.domain_cleanup.completed'
        and correlation_id = :'cleanup_run_id'::uuid
    ),
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

\if :cleanup_commit
commit;
\else
rollback;
\endif
