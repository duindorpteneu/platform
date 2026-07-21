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

do $$
declare
  entity text;
  schema_name text;
  table_name text;
  counted bigint;
begin
  foreach entity in array array[
    'app.seasons',
    'app.staff_profiles',
    'app.import_batches',
    'app.members',
    'app.articles',
    'app.article_variants',
    'app.member_orders',
    'app.order_lines',
    'app.payments',
    'app.delivery_receipts',
    'app.inventory_reservations',
    'app.fulfilments',
    'app.audit_logs',
    'private.parent_accounts',
    'private.parent_sessions',
    'private.email_jobs',
    'private.payment_events',
    'private.qr_tokens'
  ]
  loop
    schema_name := split_part(entity, '.', 1);
    table_name := split_part(entity, '.', 2);
    if to_regclass(format('%I.%I', schema_name, table_name)) is null then
      raise exception 'required entity table is missing: %', entity;
    end if;
    execute format('select count(*) from %I.%I', schema_name, table_name) into counted;
    insert into restore_entity_counts values (entity, counted);
  end loop;
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
    'entity_counts', (
      select jsonb_object_agg(entity, row_count order by entity)
      from restore_entity_counts
    )
  ) as payload
)
select payload::text from evidence;
