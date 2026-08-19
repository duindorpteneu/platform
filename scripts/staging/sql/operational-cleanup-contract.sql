\set ON_ERROR_STOP on

create or replace function pg_temp.cleanup_tables()
returns text[]
language sql
immutable
as $$
  select array[
    'app.action_items',
    'app.article_seasons',
    'app.article_variant_aliases',
    'app.article_variants',
    'app.articles',
    'app.delivery_receipt_lines',
    'app.delivery_receipts',
    'app.dynamic_import_row_results',
    'app.dynamic_import_runs',
    'app.email_batches',
    'app.email_events',
    'app.fulfilment_lines',
    'app.fulfilments',
    'app.import_batches',
    'app.import_mapping_presets',
    'app.import_mapping_revisions',
    'app.inventory_allocation_events',
    'app.inventory_allocations',
    'app.inventory_delivery_draft_lines',
    'app.inventory_delivery_drafts',
    'app.inventory_delivery_notification_items',
    'app.inventory_delivery_notification_proposals',
    'app.inventory_movements',
    'app.inventory_reservations',
    'app.member_article_sizes',
    'app.member_external_identities',
    'app.member_package_assignments',
    'app.member_package_size_selections',
    'app.member_orders',
    'app.member_seasons',
    'app.member_size_selection_history',
    'app.members',
    'app.order_lines',
    'app.order_package_snapshot_items',
    'app.order_package_snapshots',
    'app.package_change_requests',
    'app.package_size_change_requests',
    'app.package_size_confirmation_items',
    'app.package_size_confirmations',
    'app.package_template_items',
    'app.package_template_revisions',
    'app.package_templates',
    'app.payments',
    'private.dynamic_import_mapping_preferences',
    'private.dynamic_import_row_plans',
    'private.dynamic_import_run_leases',
    'private.dynamic_import_selected_identity_keys',
    'private.dynamic_import_selected_rows',
    'private.email_delivery_attempt_outcomes',
    'private.email_delivery_attempt_provider_messages',
    'private.email_delivery_attempts',
    'private.email_jobs',
    'private.email_provider_event_quarantine',
    'private.fulfilment_command_requests',
    'private.fulfilment_correction_requests',
    'private.fulfilment_mail_projection_batches',
    'private.fulfilment_mail_projections',
    'private.fulfilment_mail_supersessions',
    'private.fulfilment_notification_events',
    'private.import_staging_payloads',
    'private.inventory_allocation_queue',
    'private.inventory_command_requests',
    'private.inventory_legacy_assignments',
    'private.inventory_legacy_reconciliation',
    'private.loose_order_line_removal_requests',
    'private.mail_v2_campaign_preflight_items',
    'private.mail_v2_campaign_preflights',
    'private.mail_v2_campaign_runs',
    'private.mail_v2_domain_events',
    'private.mail_v2_episode_dispatches',
    'private.mail_v2_episode_transitions',
    'private.mail_v2_event_suppressions',
    'private.mail_v2_notification_episodes',
    'private.mail_v2_projection_batches',
    'private.mail_v2_projections',
    'private.mail_test_deliveries',
    'private.mail_test_delivery_outcomes',
    'private.mail_test_delivery_provider_acceptances',
    'private.mail_test_delivery_provider_events',
    'private.mail_test_delivery_provider_quarantine',
    'private.manual_payment_corrections',
    'private.manual_payment_requests',
    'private.member_package_bulk_requests',
    'private.member_profile_edit_requests',
    'private.member_sensitive_identity',
    'private.member_size_edit_requests',
    'private.parent_access_batch_items',
    'private.parent_access_batches',
    'private.parent_accounts',
    'private.parent_member_links',
    'private.parent_otp_challenges',
    'private.parent_otp_delivery_attempts',
    'private.parent_otp_delivery_outcomes',
    'private.parent_otp_provider_event_quarantine',
    'private.parent_otp_provider_events',
    'private.parent_otp_provider_message_bindings',
    'private.parent_package_selection_requests',
    'private.parent_portal_grants',
    'private.parent_sessions',
    'private.payment_events',
    'private.payment_reconciliation_resolutions',
    'private.qr_identity_commands',
    'private.qr_order_identities',
    'private.qr_order_locators',
    'private.qr_scan_grants',
    'private.qr_tokens',
    'private.staff_package_selection_requests'
  ]::text[];
$$;

create or replace function pg_temp.preserved_tables()
returns text[]
language sql
immutable
as $$
  select array[
    'app.app_settings',
    'app.audit_logs',
    'app.email_templates',
    'app.inventory_settings',
    'app.mail_branding_revisions',
    'app.mail_protected_node_definitions',
    'app.mail_reminder_rules',
    'app.mail_shortcode_definitions',
    'app.mail_template_revisions',
    'app.mail_templates',
    'app.release_feature_flags',
    'app.seasons',
    'app.staff_profiles',
    'app.staff_saved_views',
    'private.mail_reminder_rule_revisions',
    'private.mail_reminder_runs',
    'private.mail_v2_process_capabilities',
    'private.migration_reconciliations',
    'private.operation_runs',
    'private.rate_limit_events',
    'private.release_cutovers',
    'private.staff_session_exchanges',
    'private.staff_sessions',
    'private.supplier_planner_admin_requests',
    'private.supplier_planner_events',
    'private.supplier_planner_principals',
    'private.supplier_planner_season_grants',
    'private.supplier_planner_sessions'
  ]::text[];
$$;

create or replace function pg_temp.table_state(qualified_table text)
returns table(row_count bigint, row_digest text)
language plpgsql
as $$
declare
  schema_name text := split_part(qualified_table, '.', 1);
  table_name text := split_part(qualified_table, '.', 2);
begin
  if qualified_table !~ '^(app|private)\.[a-z][a-z0-9_]*$' then
    raise exception 'unsafe table identifier in cleanup contract';
  end if;

  return query execute format(
    $query$
      select
        count(*)::bigint,
        encode(
          digest(
            coalesce(string_agg(row_hash, '' order by row_hash), ''),
            'sha256'
          ),
          'hex'
        )
      from (
        select encode(digest(to_jsonb(source_row)::text, 'sha256'), 'hex') as row_hash
        from %I.%I as source_row
      ) as hashed_rows
    $query$,
    schema_name,
    table_name
  );
end;
$$;

create or replace function pg_temp.cleanup_state_digest()
returns text
language plpgsql
as $$
declare
  qualified_table text;
  state record;
  accumulator text := '';
begin
  foreach qualified_table in array pg_temp.cleanup_tables()
  loop
    select * into state from pg_temp.table_state(qualified_table);
    accumulator := accumulator
      || qualified_table || ':' || state.row_count::text || ':' || state.row_digest || E'\n';
  end loop;
  return encode(digest(accumulator, 'sha256'), 'hex');
end;
$$;

create or replace function pg_temp.preserved_state_digest()
returns text
language plpgsql
as $$
declare
  qualified_table text;
  state record;
  accumulator text := '';
begin
  foreach qualified_table in array pg_temp.preserved_tables()
  loop
    if qualified_table = 'app.audit_logs' then
      continue;
    end if;
    select * into state from pg_temp.table_state(qualified_table);
    accumulator := accumulator
      || qualified_table || ':' || state.row_count::text || ':' || state.row_digest || E'\n';
  end loop;
  return encode(digest(accumulator, 'sha256'), 'hex');
end;
$$;

create or replace function pg_temp.cleanup_counts()
returns jsonb
language plpgsql
as $$
declare
  qualified_table text;
  state record;
  result jsonb := '{}'::jsonb;
begin
  foreach qualified_table in array pg_temp.cleanup_tables()
  loop
    select * into state from pg_temp.table_state(qualified_table);
    result := result || jsonb_build_object(qualified_table, state.row_count);
  end loop;
  return result;
end;
$$;

create or replace function pg_temp.cleanup_total_rows()
returns bigint
language sql
as $$
  select coalesce(sum(value::text::bigint), 0)
  from jsonb_each(pg_temp.cleanup_counts());
$$;

create or replace function pg_temp.staff_profile_digest()
returns text
language sql
as $$
  select encode(
    digest(
      coalesce(
        string_agg(
          id::text || ':' || auth_user_id::text || ':' || role::text || ':' || active::text,
          E'\n'
          order by auth_user_id
        ),
        ''
      ),
      'sha256'
    ),
    'hex'
  )
  from app.staff_profiles;
$$;

create or replace function pg_temp.auth_user_id_digest()
returns text
language sql
as $$
  select encode(
    digest(coalesce(string_agg(id::text, E'\n' order by id), ''), 'sha256'),
    'hex'
  )
  from auth.users;
$$;

create or replace function pg_temp.cleanup_blockers()
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'database_mollie_enabled', (
      select count(*)
      from app.app_settings
      where mollie_enabled
    ),
    'database_email_enabled', (
      select count(*)
      from app.app_settings
      where email_enabled
    ),
    'active_import_leases', (
      select count(*)
      from private.dynamic_import_run_leases
      where expires_at > timezone('utc', now())
    ),
    'inflight_email_jobs', (
      select count(*)
      from private.email_jobs
      where status in ('processing', 'delivery_uncertain')
    ),
    'open_provider_payments', (
      select count(*)
      from app.payments
      where method = 'mollie'
        and status = 'open'
        and provider_payment_id is not null
    ),
    'active_scan_grants', (
      select count(*)
      from private.qr_scan_grants
      where consumed_at is null
        and revoked_at is null
        and expires_at > timezone('utc', now())
    )
  );
$$;

create or replace function pg_temp.migration_ledger_digest()
returns text
language sql
as $$
  select encode(
    digest(coalesce(string_agg(version::text, E'\n' order by version::text), ''), 'sha256'),
    'hex'
  )
  from supabase_migrations.schema_migrations;
$$;

create or replace function pg_temp.constraint_digest()
returns text
language sql
as $$
  select encode(
    digest(
      coalesce(
        string_agg(
          namespace_row.nspname || ':' || class_row.relname || ':'
            || constraint_row.conname || ':' || constraint_row.contype::text || ':'
            || constraint_row.convalidated::text || ':'
            || pg_get_constraintdef(constraint_row.oid, true),
          E'\n'
          order by namespace_row.nspname, class_row.relname, constraint_row.conname
        ),
        ''
      ),
      'sha256'
    ),
    'hex'
  )
  from pg_constraint as constraint_row
  join pg_class as class_row on class_row.oid = constraint_row.conrelid
  join pg_namespace as namespace_row on namespace_row.oid = class_row.relnamespace
  where namespace_row.nspname in ('app', 'private');
$$;

do $contract$
declare
  actual_tables text[];
  contracted_tables text[];
  unsafe_foreign_key text;
begin
  select array_agg(table_name order by table_name)
  into actual_tables
  from (
    select format('%I.%I', schemaname, tablename) as table_name
    from pg_tables
    where schemaname in ('app', 'private')
  ) as inventory;

  select array_agg(table_name order by table_name)
  into contracted_tables
  from unnest(pg_temp.cleanup_tables() || pg_temp.preserved_tables()) as listed(table_name);

  if cardinality(pg_temp.cleanup_tables()) <> 107
    or cardinality(pg_temp.preserved_tables()) <> 28
    or actual_tables is distinct from contracted_tables
  then
    raise exception 'cleanup table inventory drifted; update the explicit contract before proceeding';
  end if;

  if 'app.staff_profiles' = any(pg_temp.cleanup_tables())
    or exists (
      select 1
      from unnest(pg_temp.cleanup_tables()) as cleanup_table(table_name)
      where cleanup_table.table_name like 'auth.%'
    )
  then
    raise exception 'staff or auth table entered the cleanup allowlist';
  end if;

  select format(
    '%I.%I -> %I.%I (%I)',
    child_ns.nspname,
    child.relname,
    parent_ns.nspname,
    parent.relname,
    constraint_row.conname
  )
  into unsafe_foreign_key
  from pg_constraint as constraint_row
  join pg_class as child on child.oid = constraint_row.conrelid
  join pg_namespace as child_ns on child_ns.oid = child.relnamespace
  join pg_class as parent on parent.oid = constraint_row.confrelid
  join pg_namespace as parent_ns on parent_ns.oid = parent.relnamespace
  where constraint_row.contype = 'f'
    and format('%I.%I', child_ns.nspname, child.relname) = any(pg_temp.preserved_tables())
    and format('%I.%I', parent_ns.nspname, parent.relname) = any(pg_temp.cleanup_tables())
  limit 1;

  if unsafe_foreign_key is not null then
    raise exception 'preserved table depends on cleanup table: %', unsafe_foreign_key;
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
$contract$;
