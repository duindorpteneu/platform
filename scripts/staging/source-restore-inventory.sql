\set ON_ERROR_STOP on

create temporary table restore_relation_counts (
  relation_identity text primary key,
  row_count bigint not null check (row_count >= 0),
  row_hmac text not null check (row_hmac ~ '^[a-f0-9]{64}$')
);
create temporary table restore_sequence_state (
  sequence_identity text primary key,
  last_value bigint not null,
  is_called boolean not null
);
create temporary table restore_security_contract (
  underlying_member_rows bigint not null check (
    underlying_member_rows >= 0
  ),
  unauthorized_member_rows bigint not null check (
    unauthorized_member_rows >= 0
  ),
  unauthorized_access_denied boolean not null
);

begin isolation level repeatable read read only;
\if :snapshot_mode
set transaction snapshot :'snapshot_id';
\endif
set local search_path = pg_catalog;
\o /dev/null
select set_config(
  'duindorp.restore_inventory_hmac_key',
  :'inventory_hmac_key',
  true
);
\o

do $$
declare
  target record;
  counted bigint;
  content_hmac text;
begin
  for target in
    select namespace.nspname schema_name, relation.relname relation_name
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in (
      'app',
      'auth',
      'private',
      'public',
      'supabase_migrations'
    )
      and relation.relkind in ('r', 'p')
    order by namespace.nspname, relation.relname
  loop
    execute format($query$
      select
        count(*)::bigint,
        encode(
          extensions.hmac(
            convert_to(
              coalesce(string_agg(row_hash, '' order by row_hash), ''),
              'UTF8'
            ),
            convert_to(%L, 'UTF8'),
            'sha256'
          ),
          'hex'
        )
      from (
        select encode(
          extensions.digest(
            convert_to(to_jsonb(source_row)::text, 'UTF8'),
            'sha256'
          ),
          'hex'
        ) row_hash
        from %I.%I source_row
      ) hashed_rows
    $query$,
      current_setting('duindorp.restore_inventory_hmac_key'),
      target.schema_name,
      target.relation_name
    ) into counted, content_hmac;
    insert into restore_relation_counts(
      relation_identity,
      row_count,
      row_hmac
    )
    values (
      target.schema_name || '.' || target.relation_name,
      counted,
      content_hmac
    );
  end loop;
end;
$$;

do $$
declare
  target record;
  current_last_value bigint;
  current_is_called boolean;
begin
  for target in
    select namespace.nspname schema_name, relation.relname sequence_name
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in (
      'app',
      'auth',
      'private',
      'public',
      'supabase_migrations'
    )
      and relation.relkind = 'S'
    order by namespace.nspname, relation.relname
  loop
    execute format(
      'select last_value::bigint, is_called from %I.%I',
      target.schema_name,
      target.sequence_name
    ) into current_last_value, current_is_called;
    insert into restore_sequence_state(
      sequence_identity,
      last_value,
      is_called
    ) values (
      target.schema_name || '.' || target.sequence_name,
      current_last_value,
      current_is_called
    );
  end loop;
end;
$$;

do $$
declare
  underlying_rows bigint := 0;
  unauthorized_rows bigint := 0;
  access_denied boolean := false;
begin
  if to_regclass('app.members') is not null then
    execute 'select count(*)::bigint from app.members'
      into underlying_rows;
    execute 'set local role authenticated';
    begin
      execute 'select count(*)::bigint from app.members'
        into unauthorized_rows;
    exception when others then
      unauthorized_rows := 0;
      access_denied := true;
    end;
    execute 'reset role';
  end if;
  insert into restore_security_contract(
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

with schema_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', namespace.nspname,
    'owner', owner_role.rolname,
    'acl', coalesce((
      select jsonb_agg(jsonb_build_object(
        'grantor', grantor_role.rolname,
        'grantee', case
          when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname
        end,
        'privilege', acl.privilege_type,
        'grantable', acl.is_grantable
      ) order by
        grantor_role.rolname,
        case when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname end,
        acl.privilege_type,
        acl.is_grantable)
      from aclexplode(coalesce(
        namespace.nspacl,
        acldefault('n', namespace.nspowner)
      )) acl
      join pg_roles grantor_role on grantor_role.oid = acl.grantor
      left join pg_roles grantee_role on grantee_role.oid = acl.grantee
    ), '[]'::jsonb)
  ) order by namespace.nspname), '[]'::jsonb) value
  from pg_namespace namespace
  join pg_roles owner_role on owner_role.oid = namespace.nspowner
  where namespace.nspname in (
    'app',
    'auth',
    'private',
    'public',
    'supabase_migrations'
  )
), relation_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || relation.relname,
    'kind', relation.relkind::text,
    'owner', owner_role.rolname,
    'rowCount', counts.row_count,
    'rowHmac', counts.row_hmac,
    'rls', relation.relrowsecurity,
    'forceRls', relation.relforcerowsecurity,
    'acl', coalesce((
      select jsonb_agg(jsonb_build_object(
        'grantor', grantor_role.rolname,
        'grantee', case
          when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname
        end,
        'privilege', acl.privilege_type,
        'grantable', acl.is_grantable
      ) order by
        grantor_role.rolname,
        case when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname end,
        acl.privilege_type,
        acl.is_grantable)
      from aclexplode(coalesce(
        relation.relacl,
        acldefault(
          (
            case when relation.relkind = 'S' then 's' else 'r' end
          )::"char",
          relation.relowner
        )
      )) acl
      join pg_roles grantor_role on grantor_role.oid = acl.grantor
      left join pg_roles grantee_role on grantee_role.oid = acl.grantee
    ), '[]'::jsonb)
  ) order by namespace.nspname, relation.relname), '[]'::jsonb) value
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  join pg_roles owner_role on owner_role.oid = relation.relowner
  left join restore_relation_counts counts
    on counts.relation_identity
      = namespace.nspname || '.' || relation.relname
  where namespace.nspname in (
    'app',
    'auth',
    'private',
    'public',
    'supabase_migrations'
  )
    and relation.relkind in ('r', 'p', 'v', 'm', 'S')
), column_rows as (
  select
    namespace.nspname schema_name,
    relation.relname relation_name,
    attribute.attnum attribute_number,
    attribute.attname attribute_name,
    row_number() over (
      partition by attribute.attrelid
      order by attribute.attnum
    ) position,
    format_type(attribute.atttypid, attribute.atttypmod) type_name,
    attribute.attnotnull not_null,
    attribute.attidentity::text identity_kind,
    attribute.attgenerated::text generated_kind,
    coalesce(
      pg_get_expr(default_row.adbin, default_row.adrelid, true),
      ''
    ) default_expression,
    case
      when attribute.attcollation = 0 then ''
      else attribute.attcollation::regcollation::text
    end collation_name,
    attribute.attstorage::text storage_kind,
    attribute.attcompression::text compression_kind
  from pg_attribute attribute
  join pg_class relation on relation.oid = attribute.attrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  left join pg_attrdef default_row
    on default_row.adrelid = attribute.attrelid
    and default_row.adnum = attribute.attnum
  where namespace.nspname in (
    'app',
    'auth',
    'private',
    'public',
    'supabase_migrations'
  )
    and relation.relkind in ('r', 'p', 'v', 'm', 'S')
    and attribute.attnum > 0
    and not attribute.attisdropped
), column_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', column_row.schema_name || '.'
      || column_row.relation_name || '.' || column_row.attribute_name,
    'position', column_row.position,
    'type', column_row.type_name,
    'notNull', column_row.not_null,
    'identityKind', column_row.identity_kind,
    'generated', column_row.generated_kind,
    'default', column_row.default_expression,
    'collation', column_row.collation_name,
    'storage', column_row.storage_kind,
    'compression', column_row.compression_kind
  ) order by
    column_row.schema_name,
    column_row.relation_name,
    column_row.attribute_number), '[]'::jsonb) value
  from column_rows column_row
), type_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || type_row.typname,
    'kind', type_row.typtype::text,
    'category', type_row.typcategory::text,
    'owner', owner_role.rolname,
    'notNull', type_row.typnotnull,
    'collation', case
      when type_row.typcollation = 0 then ''
      else type_row.typcollation::regcollation::text
    end,
    'baseType', case
      when type_row.typbasetype = 0 then ''
      else format_type(type_row.typbasetype, type_row.typtypmod)
    end,
    'enumLabels', coalesce((
      select jsonb_agg(enum_row.enumlabel order by enum_row.enumsortorder)
      from pg_enum enum_row
      where enum_row.enumtypid = type_row.oid
    ), '[]'::jsonb)
  ) order by namespace.nspname, type_row.typname), '[]'::jsonb) value
  from pg_type type_row
  join pg_namespace namespace on namespace.oid = type_row.typnamespace
  join pg_roles owner_role on owner_role.oid = type_row.typowner
  where namespace.nspname in (
    'app',
    'auth',
    'private',
    'public',
    'supabase_migrations'
  )
    and type_row.typtype in ('b', 'c', 'd', 'e', 'm', 'r')
    and (
      type_row.typrelid = 0
      or exists (
        select 1
        from pg_class relation
        where relation.oid = type_row.typrelid
          and relation.relkind in ('r', 'p', 'v', 'm')
      )
    )
), view_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || relation.relname,
    'kind', relation.relkind::text,
    'definitionSha256', encode(extensions.digest(
      convert_to(pg_get_viewdef(relation.oid, true), 'UTF8'),
      'sha256'
    ), 'hex')
  ) order by namespace.nspname, relation.relname), '[]'::jsonb) value
  from pg_class relation
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname in (
    'app',
    'auth',
    'private',
    'public',
    'supabase_migrations'
  )
    and relation.relkind in ('v', 'm')
), sequence_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', sequence_row.sequence_identity,
    'lastValue', sequence_row.last_value,
    'isCalled', sequence_row.is_called
  ) order by sequence_row.sequence_identity), '[]'::jsonb) value
  from restore_sequence_state sequence_row
), constraint_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || relation.relname
      || '.' || constraint_row.conname,
    'type', constraint_row.contype::text,
    'validated', constraint_row.convalidated,
    'definition', pg_get_constraintdef(constraint_row.oid, true)
  ) order by
    namespace.nspname,
    relation.relname,
    constraint_row.conname), '[]'::jsonb) value
  from pg_constraint constraint_row
  join pg_class relation on relation.oid = constraint_row.conrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname in ('app', 'auth', 'private', 'public')
), index_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || index_relation.relname,
    'table', namespace.nspname || '.' || table_relation.relname,
    'owner', owner_role.rolname,
    'definition', pg_get_indexdef(index_relation.oid)
  ) order by namespace.nspname, index_relation.relname), '[]'::jsonb) value
  from pg_index index_row
  join pg_class index_relation on index_relation.oid = index_row.indexrelid
  join pg_class table_relation on table_relation.oid = index_row.indrelid
  join pg_namespace namespace on namespace.oid = index_relation.relnamespace
  join pg_roles owner_role on owner_role.oid = index_relation.relowner
  where namespace.nspname in ('app', 'auth', 'private', 'public')
), policy_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || relation.relname
      || '.' || policy.polname,
    'command', policy.polcmd::text,
    'permissive', policy.polpermissive,
    'roles', coalesce((
      select jsonb_agg(role_row.rolname order by role_row.rolname)
      from unnest(policy.polroles) role_oid
      join pg_roles role_row on role_row.oid = role_oid
    ), '[]'::jsonb),
    'using', coalesce(pg_get_expr(policy.polqual, policy.polrelid), ''),
    'check', coalesce(pg_get_expr(policy.polwithcheck, policy.polrelid), '')
  ) order by
    namespace.nspname,
    relation.relname,
    policy.polname), '[]'::jsonb) value
  from pg_policy policy
  join pg_class relation on relation.oid = policy.polrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname in ('app', 'auth', 'private', 'public')
), function_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || procedure.proname || '('
      || pg_get_function_identity_arguments(procedure.oid) || ')',
    'owner', owner_role.rolname,
    'language', language.lanname,
    'kind', procedure.prokind::text,
    'returns', format_type(procedure.prorettype, null),
    'securityDefiner', procedure.prosecdef,
    'leakproof', procedure.proleakproof,
    'volatility', procedure.provolatile::text,
    'parallel', procedure.proparallel::text,
    'config', to_jsonb(coalesce(procedure.proconfig, array[]::text[])),
    'definitionSha256', encode(extensions.digest(
      convert_to(pg_get_functiondef(procedure.oid), 'UTF8'),
      'sha256'
    ), 'hex'),
    'acl', coalesce((
      select jsonb_agg(jsonb_build_object(
        'grantor', grantor_role.rolname,
        'grantee', case
          when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname
        end,
        'privilege', acl.privilege_type,
        'grantable', acl.is_grantable
      ) order by
        grantor_role.rolname,
        case when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname end,
        acl.privilege_type,
        acl.is_grantable)
      from aclexplode(coalesce(
        procedure.proacl,
        acldefault('f', procedure.proowner)
      )) acl
      join pg_roles grantor_role on grantor_role.oid = acl.grantor
      left join pg_roles grantee_role on grantee_role.oid = acl.grantee
    ), '[]'::jsonb)
  ) order by
    namespace.nspname,
    procedure.proname,
    pg_get_function_identity_arguments(procedure.oid)), '[]'::jsonb) value
  from pg_proc procedure
  join pg_namespace namespace on namespace.oid = procedure.pronamespace
  join pg_roles owner_role on owner_role.oid = procedure.proowner
  join pg_language language on language.oid = procedure.prolang
  where namespace.nspname in ('app', 'auth', 'private', 'public')
), trigger_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'identity', namespace.nspname || '.' || relation.relname
      || '.' || trigger_row.tgname,
    'enabled', trigger_row.tgenabled::text,
    'definition', pg_get_triggerdef(trigger_row.oid, true)
  ) order by
    namespace.nspname,
    relation.relname,
    trigger_row.tgname), '[]'::jsonb) value
  from pg_trigger trigger_row
  join pg_class relation on relation.oid = trigger_row.tgrelid
  join pg_namespace namespace on namespace.oid = relation.relnamespace
  where namespace.nspname in ('app', 'auth', 'private', 'public')
    and not trigger_row.tgisinternal
), default_acl_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'role', owner_role.rolname,
    'schema', coalesce(namespace.nspname, ''),
    'objectType', default_acl.defaclobjtype::text,
    'acl', coalesce((
      select jsonb_agg(jsonb_build_object(
        'grantor', grantor_role.rolname,
        'grantee', case
          when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname
        end,
        'privilege', acl.privilege_type,
        'grantable', acl.is_grantable
      ) order by
        grantor_role.rolname,
        case when acl.grantee = 0 then 'PUBLIC'
          else grantee_role.rolname end,
        acl.privilege_type,
        acl.is_grantable)
      from aclexplode(default_acl.defaclacl) acl
      join pg_roles grantor_role on grantor_role.oid = acl.grantor
      left join pg_roles grantee_role on grantee_role.oid = acl.grantee
    ), '[]'::jsonb)
  ) order by
    owner_role.rolname,
    coalesce(namespace.nspname, ''),
    default_acl.defaclobjtype), '[]'::jsonb) value
  from pg_default_acl default_acl
  join pg_roles owner_role on owner_role.oid = default_acl.defaclrole
  left join pg_namespace namespace on namespace.oid = default_acl.defaclnamespace
  where namespace.nspname is null
    or namespace.nspname in ('app', 'auth', 'private', 'public')
), role_inventory as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', role_row.rolname,
    'superuser', role_row.rolsuper,
    'inherit', role_row.rolinherit,
    'createRole', role_row.rolcreaterole,
    'createDatabase', role_row.rolcreatedb,
    'login', role_row.rolcanlogin,
    'replication', role_row.rolreplication,
    'bypassRls', role_row.rolbypassrls,
    'connectionLimit', role_row.rolconnlimit,
    'memberships', coalesce((
      select jsonb_agg(granted_role.rolname order by granted_role.rolname)
      from pg_auth_members membership
      join pg_roles granted_role
        on granted_role.oid = membership.roleid
      where membership.member = role_row.oid
    ), '[]'::jsonb)
  ) order by role_row.rolname), '[]'::jsonb) value
  from pg_roles role_row
  where role_row.rolname in (
    'anon',
    'authenticated',
    'authenticator',
    'dashboard_user',
    'postgres',
    'service_role',
    'supabase_admin',
    'supabase_auth_admin',
    'supabase_functions_admin',
    'supabase_read_only_user',
    'supabase_replication_admin',
    'supabase_storage_admin'
  )
), identity_inventory as (
  select jsonb_build_object(
    'authUserCount', (select count(*)::integer from auth.users),
    'authUserIdHmac', encode(extensions.hmac(
      convert_to(coalesce((
        select string_agg(user_row.id::text, ',' order by user_row.id)
        from auth.users user_row
      ), ''), 'UTF8'),
      convert_to(:'inventory_hmac_key', 'UTF8'),
      'sha256'
    ), 'hex'),
    'staffCount', (select count(*)::integer from app.staff_profiles),
    'adminCount', (
      select count(*)::integer
      from app.staff_profiles
      where role = 'beheerder'
    ),
    'staffIdHmac', encode(extensions.hmac(
      convert_to(coalesce((
        select string_agg(
          staff.auth_user_id::text,
          ',' order by staff.auth_user_id
        )
        from app.staff_profiles staff
      ), ''), 'UTF8'),
      convert_to(:'inventory_hmac_key', 'UTF8'),
      'sha256'
    ), 'hex')
  ) value
), migration_inventory as (
  select coalesce(
    jsonb_agg(version::text order by version::text),
    '[]'::jsonb
  ) value
  from supabase_migrations.schema_migrations
)
select jsonb_build_object(
  'contractVersion', 2,
  'postgresMajor',
    current_setting('server_version_num')::integer / 10000,
  'migrations', migration_inventory.value,
  'schemas', schema_inventory.value,
  'relations', relation_inventory.value,
  'columns', column_inventory.value,
  'types', type_inventory.value,
  'views', view_inventory.value,
  'sequences', sequence_inventory.value,
  'constraints', constraint_inventory.value,
  'indexes', index_inventory.value,
  'policies', policy_inventory.value,
  'functions', function_inventory.value,
  'triggers', trigger_inventory.value,
  'defaultAcls', default_acl_inventory.value,
  'roles', role_inventory.value,
  'identities', identity_inventory.value,
  'security', jsonb_build_object(
    'underlyingMemberRows', security.underlying_member_rows,
    'unauthorizedMemberRows', security.unauthorized_member_rows,
    'unauthorizedAccessDenied', security.unauthorized_access_denied
  )
)::text
from schema_inventory
cross join relation_inventory
cross join column_inventory
cross join type_inventory
cross join view_inventory
cross join sequence_inventory
cross join constraint_inventory
cross join index_inventory
cross join policy_inventory
cross join function_inventory
cross join trigger_inventory
cross join default_acl_inventory
cross join role_inventory
cross join identity_inventory
cross join migration_inventory
cross join restore_security_contract security;

rollback;
