#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-package-concurrency.XXXXXX)"
confirm_first_pid=""
previous_active_season="$("${psql_cmd[@]}" -Atc "select coalesce(active_season_id::text, '') from app.app_settings where id = true")"
previous_package_flag="$("${psql_cmd[@]}" -Atc "select enabled::text from app.release_feature_flags where key = 'package_orders_v2'")"
previous_import_flag="$("${psql_cmd[@]}" -Atc "select enabled::text from app.release_feature_flags where key = 'dynamic_import_v2'")"

cleanup_data() {
  "${psql_cmd[@]}" <<'SQL'
begin;
set local session_replication_role = replica;
set constraints all deferred;

delete from private.dynamic_import_run_leases
where run_id = 'cc960000-0000-4000-8000-000000000001';
delete from private.dynamic_import_row_plans
where run_id = 'cc960000-0000-4000-8000-000000000001';
delete from app.dynamic_import_row_results
where run_id = 'cc960000-0000-4000-8000-000000000001';
delete from private.dynamic_import_selected_rows
where run_id = 'cc960000-0000-4000-8000-000000000001';
delete from app.dynamic_import_runs
where id = 'cc960000-0000-4000-8000-000000000001';
update app.import_batches
set active_mapping_revision_id = null
where id = 'cc940000-0000-4000-8000-000000000001';
delete from app.import_mapping_revisions
where id = 'cc950000-0000-4000-8000-000000000001';
delete from app.import_batches
where id = 'cc940000-0000-4000-8000-000000000001';
delete from private.staff_package_selection_requests
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003',
  'cc510000-0000-4000-8000-000000000004'
);
delete from private.loose_order_line_removal_requests
where order_id in (
  select orders.id from app.member_orders orders
  where orders.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.package_change_requests
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from private.parent_package_selection_requests
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003'
);
delete from app.package_size_confirmation_items
where confirmation_id in (
  select confirmation.id
  from app.package_size_confirmations confirmation
  where confirmation.member_season_id in (
    'cc510000-0000-4000-8000-000000000001',
    'cc510000-0000-4000-8000-000000000002',
    'cc510000-0000-4000-8000-000000000003'
  )
);
delete from app.member_package_size_selections
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003',
  'cc510000-0000-4000-8000-000000000004'
);
delete from app.package_size_confirmations
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003'
);
delete from app.member_size_selection_history
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003',
  'cc510000-0000-4000-8000-000000000004'
);
delete from app.package_size_change_requests
where member_season_id = 'cc510000-0000-4000-8000-000000000003';
delete from app.action_items
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from app.fulfilment_lines
where order_line_id in (
  select line.id
  from app.order_lines line
  join app.member_orders orders on orders.id = line.order_id
  where orders.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.fulfilments
where order_id in (
  select orders.id
  from app.member_orders orders
  where orders.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.inventory_reservations
where order_line_id in (
  select line.id
  from app.order_lines line
  join app.member_orders orders on orders.id = line.order_id
  where orders.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.inventory_allocation_events
where allocation_id in (
  select allocation.id from app.inventory_allocations allocation
  where allocation.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.inventory_allocations
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from private.inventory_allocation_queue
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from app.delivery_receipt_lines
where receipt_id = 'cc700000-0000-4000-8000-000000000001';
delete from app.delivery_receipts
where id = 'cc700000-0000-4000-8000-000000000001';
delete from private.qr_tokens
where order_id in (
  select orders.id
  from app.member_orders orders
  where orders.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.payments
where order_id in (
  select orders.id
  from app.member_orders orders
  where orders.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.member_article_sizes
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003',
  'cc510000-0000-4000-8000-000000000004'
);
delete from app.audit_logs
where actor_user_id in (
  'cc000000-0000-4000-8000-000000000001',
  'cc000000-0000-4000-8000-000000000002'
)
or metadata::text like '%cc510000-0000-4000-8000-%';
delete from app.member_package_assignments
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003',
  'cc510000-0000-4000-8000-000000000004'
);
delete from app.order_package_snapshot_items
where snapshot_id in (
  select snapshot.id from app.order_package_snapshots snapshot
  where snapshot.member_season_id in (
    'cc510000-0000-4000-8000-000000000001',
    'cc510000-0000-4000-8000-000000000002',
    'cc510000-0000-4000-8000-000000000003',
    'cc510000-0000-4000-8000-000000000004'
  )
);
delete from app.order_package_snapshots
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003',
  'cc510000-0000-4000-8000-000000000004'
);
delete from app.order_lines
where order_id in (
  select orders.id from app.member_orders orders
  where orders.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.member_orders
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from private.parent_portal_grants
where member_season_id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003'
);
delete from private.parent_sessions
where parent_account_id in (
  'cc600000-0000-4000-8000-000000000001',
  'cc600000-0000-4000-8000-000000000002',
  'cc600000-0000-4000-8000-000000000003'
);
delete from private.parent_accounts
where id in (
  'cc600000-0000-4000-8000-000000000001',
  'cc600000-0000-4000-8000-000000000002',
  'cc600000-0000-4000-8000-000000000003'
);
delete from app.member_seasons
where id in (
  'cc510000-0000-4000-8000-000000000001',
  'cc510000-0000-4000-8000-000000000002',
  'cc510000-0000-4000-8000-000000000003',
  'cc510000-0000-4000-8000-000000000004'
);
delete from private.member_sensitive_identity
where member_id in (
  'cc500000-0000-4000-8000-000000000001',
  'cc500000-0000-4000-8000-000000000002',
  'cc500000-0000-4000-8000-000000000003',
  'cc500000-0000-4000-8000-000000000004'
);
delete from app.members
where id in (
  'cc500000-0000-4000-8000-000000000001',
  'cc500000-0000-4000-8000-000000000002',
  'cc500000-0000-4000-8000-000000000003',
  'cc500000-0000-4000-8000-000000000004'
);
delete from app.package_template_items
where revision_id in (
  select revision.id
  from app.package_template_revisions revision
  where revision.season_id = 'cc100000-0000-4000-8000-000000000001'
);
delete from app.package_template_revisions
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from app.package_templates
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from app.article_seasons
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from app.article_variants
where article_id in (
  'cc200000-0000-4000-8000-000000000001',
  'cc200000-0000-4000-8000-000000000002',
  'cc200000-0000-4000-8000-000000000003'
);
delete from app.articles
where id in (
  'cc200000-0000-4000-8000-000000000001',
  'cc200000-0000-4000-8000-000000000002',
  'cc200000-0000-4000-8000-000000000003'
);
delete from app.inventory_settings
where season_id = 'cc100000-0000-4000-8000-000000000001';
delete from app.seasons
where id = 'cc100000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id in (
  'cc000000-0000-4000-8000-000000000001',
  'cc000000-0000-4000-8000-000000000002'
);
commit;
SQL
}

cleanup() {
  exec 9>&- || true
  if [[ -n "$confirm_first_pid" ]] && kill -0 "$confirm_first_pid" 2>/dev/null; then
    kill "$confirm_first_pid" 2>/dev/null || true
    wait "$confirm_first_pid" 2>/dev/null || true
  fi
  cleanup_data
  if [[ "$previous_active_season" =~ ^[0-9a-f-]{36}$ ]]; then
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id = '$previous_active_season'::uuid where id = true" >/dev/null
  else
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id = null where id = true" >/dev/null
  fi
  "${psql_cmd[@]}" -c "update app.release_feature_flags set enabled = $previous_package_flag where key = 'package_orders_v2'" >/dev/null
  "${psql_cmd[@]}" -c "update app.release_feature_flags set enabled = $previous_import_flag where key = 'dynamic_import_v2'" >/dev/null
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
}

wait_for_marker() {
  local log_file="$1"
  local marker="$2"
  local attempt
  for attempt in $(seq 1 200); do
    if grep -q "$marker" "$log_file" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  echo "Synchronisatiemarker niet bereikt: $marker"
  tail -n 40 "$log_file" 2>/dev/null || true
  return 1
}

wait_for_backend_lock() {
  local application_name="$1"
  local attempt
  for attempt in $(seq 1 200); do
    if [[ "$("${psql_cmd[@]}" -Atc "
      select count(*)
      from pg_stat_activity
      where application_name = '${application_name}'
        and wait_event_type = 'Lock'
    ")" == "1" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "Backend bereikte de verwachte lock niet: $application_name"
  "${psql_cmd[@]}" -c "
    select application_name, state, wait_event_type, wait_event
    from pg_stat_activity
    where application_name = '${application_name}'
  " || true
  return 1
}

trap cleanup EXIT
cleanup_data

"${psql_cmd[@]}" <<'SQL'
update app.app_settings set active_season_id = null where id = true;
update app.release_feature_flags set enabled = true where key = 'package_orders_v2';
update app.release_feature_flags set enabled = true where key = 'dynamic_import_v2';

insert into app.staff_profiles(auth_user_id, display_name, role, active)
values
  ('cc000000-0000-4000-8000-000000000001', 'Package race beheerder', 'beheerder', true),
  ('cc000000-0000-4000-8000-000000000002', 'Package race uitgifte', 'uitgifte', true);
insert into app.seasons(
  id, name, starts_on, ends_on, default_amount_cents, status, opened_at
)
values(
  'cc100000-0000-4000-8000-000000000001',
  'Package concurrencyseizoen',
  '2051-07-01',
  '2052-06-30',
  12500,
  'open',
  timezone('utc', now())
);
insert into app.articles(id, name, code, icon_type, sort_order)
values
  ('cc200000-0000-4000-8000-000000000001', 'Race shirt', 'CC-SHIRT', 'shirt', 10),
  ('cc200000-0000-4000-8000-000000000002', 'Race broek', 'CC-BROEK', 'circle-dot', 20),
  ('cc200000-0000-4000-8000-000000000003', 'Race keeper', 'CC-KEEPER', 'shirt', 30);
insert into app.article_variants(id, article_id, size, sku, sort_order)
values
  ('cc300000-0000-4000-8000-000000000001', 'cc200000-0000-4000-8000-000000000001', '152', 'CC-SHIRT-152', 10),
  ('cc300000-0000-4000-8000-000000000002', 'cc200000-0000-4000-8000-000000000001', '164', 'CC-SHIRT-164', 20),
  ('cc300000-0000-4000-8000-000000000003', 'cc200000-0000-4000-8000-000000000002', '152', 'CC-BROEK-152', 10),
  ('cc300000-0000-4000-8000-000000000004', 'cc200000-0000-4000-8000-000000000002', '164', 'CC-BROEK-164', 20),
  ('cc300000-0000-4000-8000-000000000005', 'cc200000-0000-4000-8000-000000000003', '152', 'CC-KEEPER-152', 10),
  ('cc300000-0000-4000-8000-000000000006', 'cc200000-0000-4000-8000-000000000003', '164', 'CC-KEEPER-164', 20);
insert into app.article_seasons(article_id, season_id)
values
  ('cc200000-0000-4000-8000-000000000001', 'cc100000-0000-4000-8000-000000000001'),
  ('cc200000-0000-4000-8000-000000000002', 'cc100000-0000-4000-8000-000000000001'),
  ('cc200000-0000-4000-8000-000000000003', 'cc100000-0000-4000-8000-000000000001');

insert into app.package_templates(id, season_id, template_key, created_by)
values
  ('cc400000-0000-4000-8000-000000000001', 'cc100000-0000-4000-8000-000000000001', 'race-shirt', 'cc000000-0000-4000-8000-000000000001'),
  ('cc400000-0000-4000-8000-000000000002', 'cc100000-0000-4000-8000-000000000001', 'race-broek', 'cc000000-0000-4000-8000-000000000001'),
  ('cc400000-0000-4000-8000-000000000003', 'cc100000-0000-4000-8000-000000000001', 'race-keeper', 'cc000000-0000-4000-8000-000000000001'),
  ('cc400000-0000-4000-8000-000000000004', 'cc100000-0000-4000-8000-000000000001', 'race-publish-a', 'cc000000-0000-4000-8000-000000000001'),
  ('cc400000-0000-4000-8000-000000000005', 'cc100000-0000-4000-8000-000000000001', 'race-publish-b', 'cc000000-0000-4000-8000-000000000001');
insert into app.package_template_revisions(
  id, template_id, season_id, revision_number, name, description,
  price_cents, status, active, is_default, created_by
)
values
  ('cc410000-0000-4000-8000-000000000001', 'cc400000-0000-4000-8000-000000000001', 'cc100000-0000-4000-8000-000000000001', 1, 'Race shirtpakket', '', 12500, 'draft', false, false, 'cc000000-0000-4000-8000-000000000001'),
  ('cc410000-0000-4000-8000-000000000002', 'cc400000-0000-4000-8000-000000000002', 'cc100000-0000-4000-8000-000000000001', 1, 'Race broekpakket', '', 12500, 'draft', false, false, 'cc000000-0000-4000-8000-000000000001'),
  ('cc410000-0000-4000-8000-000000000003', 'cc400000-0000-4000-8000-000000000003', 'cc100000-0000-4000-8000-000000000001', 1, 'Race keeperpakket', '', 12500, 'draft', false, false, 'cc000000-0000-4000-8000-000000000001'),
  ('cc410000-0000-4000-8000-000000000004', 'cc400000-0000-4000-8000-000000000004', 'cc100000-0000-4000-8000-000000000001', 1, 'Race publicatie A', '', 12500, 'draft', false, false, 'cc000000-0000-4000-8000-000000000001'),
  ('cc410000-0000-4000-8000-000000000005', 'cc400000-0000-4000-8000-000000000005', 'cc100000-0000-4000-8000-000000000001', 1, 'Race publicatie B', '', 12500, 'draft', false, false, 'cc000000-0000-4000-8000-000000000001');
insert into app.package_template_items(
  id, revision_id, article_id, quantity, product_name_snapshot,
  product_code_snapshot, sort_order, season_id
)
values
  ('cc420000-0000-4000-8000-000000000001', 'cc410000-0000-4000-8000-000000000001', 'cc200000-0000-4000-8000-000000000001', 1, 'Race shirt', 'CC-SHIRT', 10, 'cc100000-0000-4000-8000-000000000001'),
  ('cc420000-0000-4000-8000-000000000002', 'cc410000-0000-4000-8000-000000000002', 'cc200000-0000-4000-8000-000000000002', 1, 'Race broek', 'CC-BROEK', 10, 'cc100000-0000-4000-8000-000000000001'),
  ('cc420000-0000-4000-8000-000000000003', 'cc410000-0000-4000-8000-000000000003', 'cc200000-0000-4000-8000-000000000003', 1, 'Race keeper', 'CC-KEEPER', 10, 'cc100000-0000-4000-8000-000000000001'),
  ('cc420000-0000-4000-8000-000000000004', 'cc410000-0000-4000-8000-000000000004', 'cc200000-0000-4000-8000-000000000001', 1, 'Race shirt', 'CC-SHIRT', 10, 'cc100000-0000-4000-8000-000000000001'),
  ('cc420000-0000-4000-8000-000000000005', 'cc410000-0000-4000-8000-000000000005', 'cc200000-0000-4000-8000-000000000002', 1, 'Race broek', 'CC-BROEK', 10, 'cc100000-0000-4000-8000-000000000001');
update app.package_template_revisions
set status = 'published',
    active = true,
    is_default = id = 'cc410000-0000-4000-8000-000000000001',
    published_by = 'cc000000-0000-4000-8000-000000000001',
    published_at = timezone('utc', now())
where id in (
  'cc410000-0000-4000-8000-000000000001',
  'cc410000-0000-4000-8000-000000000002',
  'cc410000-0000-4000-8000-000000000003'
);

insert into app.members(
  id, relation_number, first_name, last_name, email, team, gender
)
values
  ('cc500000-0000-4000-8000-000000000001', 'CC-RACE-1', 'Race', 'Bevestiging', 'race-confirm@example.invalid', 'Race-1', 'female'),
  ('cc500000-0000-4000-8000-000000000002', 'CC-RACE-2', 'Race', 'Catalogus', 'race-catalog@example.invalid', 'Race-2', 'male'),
  ('cc500000-0000-4000-8000-000000000003', 'CC-RACE-3', 'Race', 'Uitgifte', 'race-fulfil@example.invalid', 'Race-3', 'female'),
  ('cc500000-0000-4000-8000-000000000004', 'CC-RACE-4', 'Race', 'Beheer', 'race-staff@example.invalid', 'Race-4', 'male');
insert into app.member_seasons(
  id, member_id, season_id, team_name, participation_status,
  reconciliation_status
)
values
  ('cc510000-0000-4000-8000-000000000001', 'cc500000-0000-4000-8000-000000000001', 'cc100000-0000-4000-8000-000000000001', 'Race-1', 'active', 'resolved'),
  ('cc510000-0000-4000-8000-000000000002', 'cc500000-0000-4000-8000-000000000002', 'cc100000-0000-4000-8000-000000000001', 'Race-2', 'active', 'resolved'),
  ('cc510000-0000-4000-8000-000000000003', 'cc500000-0000-4000-8000-000000000003', 'cc100000-0000-4000-8000-000000000001', 'Race-3', 'active', 'resolved'),
  ('cc510000-0000-4000-8000-000000000004', 'cc500000-0000-4000-8000-000000000004', 'cc100000-0000-4000-8000-000000000001', 'Race-4', 'active', 'resolved');
update app.app_settings
set active_season_id = 'cc100000-0000-4000-8000-000000000001'
where id = true;

insert into private.parent_accounts(id, email_normalized)
values
  ('cc600000-0000-4000-8000-000000000001', 'race-confirm@example.invalid'),
  ('cc600000-0000-4000-8000-000000000002', 'race-catalog@example.invalid'),
  ('cc600000-0000-4000-8000-000000000003', 'race-fulfil@example.invalid');
insert into private.parent_sessions(parent_account_id, token_hash, expires_at)
values
  ('cc600000-0000-4000-8000-000000000001', repeat('1', 64), timezone('utc', now()) + interval '1 hour'),
  ('cc600000-0000-4000-8000-000000000002', repeat('2', 64), timezone('utc', now()) + interval '1 hour'),
  ('cc600000-0000-4000-8000-000000000003', repeat('3', 64), timezone('utc', now()) + interval '1 hour');
insert into private.parent_portal_grants(
  member_season_id, email_normalized, parent_account_id, status, source,
  granted_by, granted_at
)
values
  ('cc510000-0000-4000-8000-000000000001', 'race-confirm@example.invalid', 'cc600000-0000-4000-8000-000000000001', 'active', 'administrator', 'cc000000-0000-4000-8000-000000000001', timezone('utc', now())),
  ('cc510000-0000-4000-8000-000000000002', 'race-catalog@example.invalid', 'cc600000-0000-4000-8000-000000000002', 'active', 'administrator', 'cc000000-0000-4000-8000-000000000001', timezone('utc', now())),
  ('cc510000-0000-4000-8000-000000000003', 'race-fulfil@example.invalid', 'cc600000-0000-4000-8000-000000000003', 'active', 'administrator', 'cc000000-0000-4000-8000-000000000001', timezone('utc', now()));

select public.select_parent_package_v3(
  repeat('1', 64),
  'cc510000-0000-4000-8000-000000000001',
  'cc410000-0000-4000-8000-000000000001',
  private.package_workspace_revision('cc510000-0000-4000-8000-000000000001'),
  'cc800000-0000-4000-8000-000000000001',
  null
);
select public.select_parent_package_v3(
  repeat('2', 64),
  'cc510000-0000-4000-8000-000000000002',
  'cc410000-0000-4000-8000-000000000002',
  private.package_workspace_revision('cc510000-0000-4000-8000-000000000002'),
  'cc800000-0000-4000-8000-000000000002',
  null
);
select public.select_parent_package_v3(
  repeat('3', 64),
  'cc510000-0000-4000-8000-000000000003',
  'cc410000-0000-4000-8000-000000000003',
  private.package_workspace_revision('cc510000-0000-4000-8000-000000000003'),
  'cc800000-0000-4000-8000-000000000003',
  null
);

insert into app.import_batches(
  id, file_name, checksum, actor_user_id, status, season_id,
  client_request_id, schema_version, dynamic_status, encoding, delimiter,
  byte_count, source_row_count, source_column_count, policy, mapping_hash,
  catalog_hash, preview_revision, next_source_row, expires_at
)
values(
  'cc940000-0000-4000-8000-000000000001',
  'package-confirm-race.csv',
  repeat('a', 64),
  'cc000000-0000-4000-8000-000000000001',
  'preview',
  'cc100000-0000-4000-8000-000000000001',
  'cc940000-0000-4000-8000-000000000001',
  2,
  'previewed',
  'UTF-8',
  ';',
  128,
  1,
  5,
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  repeat('b', 64),
  private.dynamic_import_catalog_hash(
    'cc100000-0000-4000-8000-000000000001'
  ),
  1,
  3,
  timezone('utc', now()) + interval '10 minutes'
);
insert into app.import_mapping_revisions(
  id, batch_id, season_id, revision, mapping, mapping_hash, header_hash,
  catalog_hash, policy, created_by
)
values(
  'cc950000-0000-4000-8000-000000000001',
  'cc940000-0000-4000-8000-000000000001',
  'cc100000-0000-4000-8000-000000000001',
  1,
  jsonb_build_array(
    jsonb_build_object(
      'columnIndex', 0,
      'sourceHeaderHash', repeat('0', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'external_member_id'
      )
    ),
    jsonb_build_object(
      'columnIndex', 1,
      'sourceHeaderHash', repeat('1', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'first_name'
      )
    ),
    jsonb_build_object(
      'columnIndex', 2,
      'sourceHeaderHash', repeat('2', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'last_name'
      )
    ),
    jsonb_build_object(
      'columnIndex', 3,
      'sourceHeaderHash', repeat('3', 64),
      'target', jsonb_build_object(
        'kind', 'member_field',
        'field', 'team'
      )
    ),
    jsonb_build_object(
      'columnIndex', 4,
      'sourceHeaderHash', repeat('4', 64),
      'target', jsonb_build_object(
        'kind', 'product_size',
        'articleId', 'cc200000-0000-4000-8000-000000000001'
      )
    )
  ),
  repeat('b', 64),
  repeat('c', 64),
  private.dynamic_import_catalog_hash(
    'cc100000-0000-4000-8000-000000000001'
  ),
  jsonb_build_object(
    'fillEmptyValues', true,
    'updateImportedUnconfirmedSizes', true,
    'protectConfirmedSizes', true,
    'ignoreEmptySourceValues', true
  ),
  'cc000000-0000-4000-8000-000000000001'
);
update app.import_batches
set active_mapping_revision_id =
  'cc950000-0000-4000-8000-000000000001'
where id = 'cc940000-0000-4000-8000-000000000001';
insert into app.dynamic_import_runs(
  id, batch_id, mapping_revision_id, season_id, created_by,
  client_request_id, request_hash, status, source_row_count, next_source_row,
  next_analysis_source_row, next_commit_source_row, plan_hash, expires_at,
  started_at, previewed_at
)
values(
  'cc960000-0000-4000-8000-000000000001',
  'cc940000-0000-4000-8000-000000000001',
  'cc950000-0000-4000-8000-000000000001',
  'cc100000-0000-4000-8000-000000000001',
  'cc000000-0000-4000-8000-000000000001',
  'cc970000-0000-4000-8000-000000000001',
  repeat('d', 64),
  'committing',
  1,
  3,
  3,
  2,
  repeat('e', 64),
  timezone('utc', now()) + interval '10 minutes',
  timezone('utc', now()),
  timezone('utc', now())
);
insert into private.dynamic_import_selected_rows(
  run_id, source_row, selected_values, row_hash, identity_key_hash, expires_at
)
select
  'cc960000-0000-4000-8000-000000000001',
  2,
  selected_values,
  encode(
    extensions.digest(convert_to(selected_values::text, 'UTF8'), 'sha256'
  ), 'hex'),
  private.dynamic_import_identity_key_hash(selected_values->'fields'),
  timezone('utc', now()) + interval '10 minutes'
from (
  select jsonb_build_object(
    'sourceRow', 2,
    'fields', jsonb_build_object(
      'external_member_id', 'CC-RACE-1',
      'first_name', 'Race',
      'last_name', 'Bevestiging',
      'team', 'Race-1-import'
    ),
    'sizes', jsonb_build_object(
      'cc200000-0000-4000-8000-000000000001',
      '152'
    ),
    'errors', '[]'::jsonb
  ) selected_values
) selected;
insert into app.dynamic_import_row_results(
  run_id, source_row, outcome, blocking, change_count
)
select
  'cc960000-0000-4000-8000-000000000001',
  2,
  (analysis->>'outcome')::app.dynamic_import_row_outcome,
  (analysis->>'blocking')::boolean,
  (analysis->>'changeCount')::integer
from (
  select private.dynamic_import_analyze_row(
    'cc960000-0000-4000-8000-000000000001',
    2
  ) analysis
) analyzed;
insert into private.dynamic_import_row_plans(
  run_id, source_row, matched_member_id, state_hash, analysis_hash,
  resolved_variants
)
select
  'cc960000-0000-4000-8000-000000000001',
  2,
  nullif(analysis->>'matchedMemberId', '')::uuid,
  analysis->>'stateHash',
  analysis->>'analysisHash',
  coalesce(analysis->'resolvedVariants', '{}'::jsonb)
from (
  select private.dynamic_import_analyze_row(
    'cc960000-0000-4000-8000-000000000001',
    2
  ) analysis
) analyzed;
insert into private.dynamic_import_run_leases(
  run_id, claim_token, generation, claimed_at, expires_at
)
values(
  'cc960000-0000-4000-8000-000000000001',
  'cc980000-0000-4000-8000-000000000001',
  1,
  timezone('utc', now()),
  timezone('utc', now()) + interval '55 seconds'
);
SQL

confirm_revision="$("${psql_cmd[@]}" -Atc "select private.package_workspace_revision('cc510000-0000-4000-8000-000000000001')")"
confirm_first_log="$test_tmp_dir/confirm-first.log"
confirm_second_log="$test_tmp_dir/confirm-second.log"
confirm_import_log="$test_tmp_dir/confirm-import.log"
confirm_control_fifo="$test_tmp_dir/confirm-control.fifo"

mkfifo "$confirm_control_fifo"
PGAPPNAME="duindorp-package-confirm-holder" \
  "${psql_cmd[@]}" <"$confirm_control_fifo" >"$confirm_first_log" 2>&1 &
confirm_first_pid=$!
exec 9>"$confirm_control_fifo"
{
  printf '%s\n' \
    "begin;" \
    "set local statement_timeout = '15s';" \
    "set local lock_timeout = '10s';" \
    "select public.confirm_parent_package_sizes_v5(" \
    "  repeat('1', 64)," \
    "  'cc510000-0000-4000-8000-000000000001'," \
    "  '[{\"articleId\":\"cc200000-0000-4000-8000-000000000001\",\"kind\":\"variant\",\"variantId\":\"cc300000-0000-4000-8000-000000000001\",\"note\":null}]'::jsonb," \
    "  '$confirm_revision'," \
    "  'cc810000-0000-4000-8000-000000000001'," \
    "  null" \
    ")->>'reused';" \
    "\\echo CONFIRM_FIRST_HOLDING"
} >&9
wait_for_marker "$confirm_first_log" "CONFIRM_FIRST_HOLDING"

PGAPPNAME="duindorp-package-confirm-retry" \
  "${psql_cmd[@]}" >"$confirm_second_log" 2>&1 <<SQL &
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
select public.confirm_parent_package_sizes_v5(
  repeat('1', 64),
  'cc510000-0000-4000-8000-000000000001',
  '[{"articleId":"cc200000-0000-4000-8000-000000000001","kind":"variant","variantId":"cc300000-0000-4000-8000-000000000001","note":null}]'::jsonb,
  '$confirm_revision',
  'cc810000-0000-4000-8000-000000000001',
  null
)->>'reused';
commit;
SQL
confirm_second_pid=$!

set +e
PGAPPNAME="duindorp-package-confirm-import" \
  "${psql_cmd[@]}" >"$confirm_import_log" 2>&1 <<'SQL' &
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select app.commit_dynamic_import_chunk(
  'cc960000-0000-4000-8000-000000000001',
  'cc980000-0000-4000-8000-000000000001',
  1,
  1
);
commit;
SQL
confirm_import_pid=$!
set -e

wait_for_backend_lock "duindorp-package-confirm-retry"
wait_for_backend_lock "duindorp-package-confirm-import"
printf '%s\n' "commit;" "\\q" >&9
exec 9>&-
wait "$confirm_first_pid"
confirm_first_pid=""
wait "$confirm_second_pid"
set +e
wait "$confirm_import_pid"
confirm_import_status=$?
set -e
if ! grep -qx "false" "$confirm_first_log" || ! grep -qx "true" "$confirm_second_log"; then
  tail -n 40 "$confirm_first_log"
  tail -n 40 "$confirm_second_log"
  exit 1
fi
if [[ "$confirm_import_status" -eq 0 ]] ||
  ! grep -q "DYNAMIC_IMPORT_STATE_DRIFT" "$confirm_import_log" ||
  grep -Eq "deadlock detected|40P01" "$confirm_import_log"; then
  tail -n 40 "$confirm_import_log"
  exit 1
fi
confirm_count="$("${psql_cmd[@]}" -Atc "select count(*) from app.package_size_confirmations where member_season_id = 'cc510000-0000-4000-8000-000000000001'")"
if [[ "$confirm_count" != "1" ]]; then
  echo "Onverwacht aantal confirmationrecords: $confirm_count"
  exit 1
fi
confirm_state="$("${psql_cmd[@]}" -Atc "
  select
    size_profile.selection_status::text || ':' ||
    size_profile.article_variant_id::text || ':' ||
    count(distinct line.id) || ':' ||
    count(distinct history.id)
  from app.member_article_sizes size_profile
  join app.member_orders orders
    on orders.member_season_id = size_profile.member_season_id
  join app.order_lines line
    on line.order_id = orders.id
    and line.article_id = size_profile.article_id
    and line.status <> 'cancelled'
  join app.member_size_selection_history history
    on history.member_season_id = size_profile.member_season_id
    and history.article_id = size_profile.article_id
    and history.selection_status = 'confirmed'
  where size_profile.member_season_id =
    'cc510000-0000-4000-8000-000000000001'
  group by size_profile.selection_status, size_profile.article_variant_id
")"
if [[ "$confirm_state" != \
  "confirmed:cc300000-0000-4000-8000-000000000001:1:1" ]]; then
  echo "Onverwachte confirm/import-uitkomst: $confirm_state"
  exit 1
fi

catalog_revision="$("${psql_cmd[@]}" -Atc "select private.package_workspace_revision('cc510000-0000-4000-8000-000000000002')")"
catalog_first_log="$test_tmp_dir/catalog-first.log"
catalog_second_log="$test_tmp_dir/catalog-second.log"
(
  "${psql_cmd[@]}" >"$catalog_first_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
select public.confirm_parent_package_sizes_v5(
  repeat('2', 64),
  'cc510000-0000-4000-8000-000000000002',
  '[{"articleId":"cc200000-0000-4000-8000-000000000002","kind":"variant","variantId":"cc300000-0000-4000-8000-000000000003","note":null}]'::jsonb,
  '$catalog_revision',
  'cc810000-0000-4000-8000-000000000002',
  null
);
\echo CATALOG_CONFIRM_HOLDING
select pg_sleep(1.5);
commit;
SQL
) &
catalog_first_pid=$!
wait_for_marker "$catalog_first_log" "CATALOG_CONFIRM_HOLDING"
(
  "${psql_cmd[@]}" >"$catalog_second_log" 2>&1 <<'SQL'
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.upsert_catalog_variant_v2(
  'cc200000-0000-4000-8000-000000000002',
  'cc300000-0000-4000-8000-000000000003',
  '152',
  'CC-BROEK-152',
  array[]::text[],
  false,
  10
);
commit;
SQL
) &
catalog_second_pid=$!
wait "$catalog_first_pid"
wait "$catalog_second_pid"
catalog_state="$("${psql_cmd[@]}" -Atc "
  select variant.active::text || ':' || size_profile.selection_status::text || ':' || count(line.id)
  from app.article_variants variant
  join app.member_article_sizes size_profile
    on size_profile.article_variant_id = variant.id
    and size_profile.member_season_id = 'cc510000-0000-4000-8000-000000000002'
  join app.member_orders orders
    on orders.member_season_id = size_profile.member_season_id
  left join app.order_lines line
    on line.order_id = orders.id
    and line.article_variant_id = variant.id
    and line.status <> 'cancelled'
  where variant.id = 'cc300000-0000-4000-8000-000000000003'
  group by variant.active, size_profile.selection_status
")"
if [[ "$catalog_state" != "false:confirmed:1" ]]; then
  echo "Onverwachte confirm/deactivate-uitkomst: $catalog_state"
  exit 1
fi

staff_revision="$("${psql_cmd[@]}" -Atc "select private.package_workspace_revision('cc510000-0000-4000-8000-000000000004')")"
staff_first_log="$test_tmp_dir/staff-first.log"
staff_second_log="$test_tmp_dir/staff-second.log"
(
  "${psql_cmd[@]}" >"$staff_first_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.select_member_package_v3(
  'cc510000-0000-4000-8000-000000000004',
  'cc410000-0000-4000-8000-000000000001',
  '$staff_revision',
  'Concurrencytest pakketkeuze',
  'cc820000-0000-4000-8000-000000000001',
  null
)->>'reused';
\echo STAFF_FIRST_HOLDING
select pg_sleep(1.5);
commit;
SQL
) &
staff_first_pid=$!
wait_for_marker "$staff_first_log" "STAFF_FIRST_HOLDING"
(
  "${psql_cmd[@]}" >"$staff_second_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.select_member_package_v3(
  'cc510000-0000-4000-8000-000000000004',
  'cc410000-0000-4000-8000-000000000001',
  '$staff_revision',
  'Concurrencytest pakketkeuze',
  'cc820000-0000-4000-8000-000000000001',
  null
)->>'reused';
commit;
SQL
) &
staff_second_pid=$!
wait "$staff_first_pid"
wait "$staff_second_pid"
if ! grep -qx "false" "$staff_first_log" || ! grep -qx "true" "$staff_second_log"; then
  tail -n 40 "$staff_first_log"
  tail -n 40 "$staff_second_log"
  exit 1
fi

publish_hash_a="$("${psql_cmd[@]}" -Atc "select private.package_revision_content_hash('cc410000-0000-4000-8000-000000000004')")"
publish_hash_b="$("${psql_cmd[@]}" -Atc "select private.package_revision_content_hash('cc410000-0000-4000-8000-000000000005')")"
publish_first_log="$test_tmp_dir/publish-first.log"
publish_second_log="$test_tmp_dir/publish-second.log"
(
  "${psql_cmd[@]}" >"$publish_first_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.publish_package_revision_v2(
  'cc410000-0000-4000-8000-000000000004',
  true,
  '$publish_hash_a',
  null
);
\echo PUBLISH_FIRST_HOLDING
select pg_sleep(1.5);
commit;
SQL
) &
publish_first_pid=$!
wait_for_marker "$publish_first_log" "PUBLISH_FIRST_HOLDING"
(
  "${psql_cmd[@]}" >"$publish_second_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.publish_package_revision_v2(
  'cc410000-0000-4000-8000-000000000005',
  true,
  '$publish_hash_b',
  null
);
commit;
SQL
) &
publish_second_pid=$!
wait "$publish_first_pid"
wait "$publish_second_pid"
publish_state="$("${psql_cmd[@]}" -Atc "
  select count(*) filter (where status = 'published') || ':' ||
    count(*) filter (where active and is_default)
  from app.package_template_revisions
  where id in (
    'cc410000-0000-4000-8000-000000000004',
    'cc410000-0000-4000-8000-000000000005'
  )
")"
if [[ "$publish_state" != "2:1" ]]; then
  echo "Onverwachte defaultpublicatie-uitkomst: $publish_state"
  exit 1
fi

"${psql_cmd[@]}" <<'SQL'
select public.confirm_parent_package_sizes_v5(
  repeat('3', 64),
  'cc510000-0000-4000-8000-000000000003',
  '[{"articleId":"cc200000-0000-4000-8000-000000000003","kind":"variant","variantId":"cc300000-0000-4000-8000-000000000005","note":null}]'::jsonb,
  private.package_workspace_revision('cc510000-0000-4000-8000-000000000003'),
  'cc810000-0000-4000-8000-000000000003',
  null
);
insert into app.payments(
  order_id, method, status, amount_cents, idempotency_key, paid_at
)
select orders.id, 'cash', 'paid', orders.amount_due_cents,
  'cc-package-race-paid', timezone('utc', now())
from app.member_orders orders
where orders.member_season_id = 'cc510000-0000-4000-8000-000000000003';
insert into app.delivery_receipts(
  id, received_on, supplier, actor_user_id
)
values(
  'cc700000-0000-4000-8000-000000000001',
  current_date,
  'Package race leverancier',
  'cc000000-0000-4000-8000-000000000001'
);
insert into app.delivery_receipt_lines(
  id, receipt_id, article_variant_id, received_quantity
)
values(
  'cc710000-0000-4000-8000-000000000001',
  'cc700000-0000-4000-8000-000000000001',
  'cc300000-0000-4000-8000-000000000005',
  1
);
insert into app.inventory_reservations(
  id, receipt_line_id, order_line_id, quantity, actor_user_id
)
select
  'cc720000-0000-4000-8000-000000000001',
  'cc710000-0000-4000-8000-000000000001',
  line.id,
  1,
  'cc000000-0000-4000-8000-000000000001'
from app.member_orders orders
join app.order_lines line
  on line.order_id = orders.id
  and line.status <> 'cancelled'
where orders.member_season_id = 'cc510000-0000-4000-8000-000000000003';
update app.order_lines line
set status = 'ready_for_pickup'
from app.inventory_reservations reservation
where reservation.id = 'cc720000-0000-4000-8000-000000000001'
  and line.id = reservation.order_line_id;
select public.confirm_parent_package_sizes_v5(
  repeat('3', 64),
  'cc510000-0000-4000-8000-000000000003',
  '[{"articleId":"cc200000-0000-4000-8000-000000000003","kind":"variant","variantId":"cc300000-0000-4000-8000-000000000006","note":null}]'::jsonb,
  private.package_workspace_revision('cc510000-0000-4000-8000-000000000003'),
  'cc810000-0000-4000-8000-000000000004',
  null
);
SQL

resolve_request_id="$("${psql_cmd[@]}" -Atc "select id from app.package_size_change_requests where member_season_id = 'cc510000-0000-4000-8000-000000000003' and status = 'requested'")"
resolve_revision="$("${psql_cmd[@]}" -Atc "select private.package_workspace_revision('cc510000-0000-4000-8000-000000000003')")"
resolve_first_log="$test_tmp_dir/resolve-first.log"
resolve_second_log="$test_tmp_dir/resolve-second.log"
(
  "${psql_cmd[@]}" >"$resolve_first_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.resolve_package_size_change_v3(
  '$resolve_request_id',
  'approve',
  'cc300000-0000-4000-8000-000000000006',
  'Concurrencytest beheergoedkeuring',
  '$resolve_revision',
  null
);
\echo RESOLVE_FIRST_HOLDING
select pg_sleep(1.5);
commit;
SQL
) &
resolve_first_pid=$!
wait_for_marker "$resolve_first_log" "RESOLVE_FIRST_HOLDING"
set +e
(
  "${psql_cmd[@]}" >"$resolve_second_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.resolve_package_size_change_v3(
  '$resolve_request_id',
  'reject',
  null,
  'Gelijktijdige afwijzing door tweede beheeractie',
  '$resolve_revision',
  null
);
commit;
SQL
) &
resolve_second_pid=$!
wait "$resolve_first_pid"
resolve_first_status=$?
wait "$resolve_second_pid"
resolve_second_status=$?
set -e
if [[ "$resolve_first_status" -ne 0 ]]; then
  tail -n 40 "$resolve_first_log"
  exit 1
fi
if [[ "$resolve_second_status" -eq 0 ]] || ! grep -Eq "PACKAGE_SIZE_CHANGE_ALREADY_RESOLVED|PACKAGE_SIZE_CHANGE_CONFLICT" "$resolve_second_log"; then
  tail -n 40 "$resolve_second_log"
  exit 1
fi
resolve_state="$("${psql_cmd[@]}" -Atc "
  select request.status || ':' || reservation.status::text || ':' ||
    (select count(*) from app.fulfilment_lines fulfilment_line
      where fulfilment_line.order_line_id = request.order_line_id
        and fulfilment_line.reversed_at is null)
  from app.package_size_change_requests request
  join app.inventory_reservations reservation
    on reservation.id = request.released_reservation_id
  where request.id = '$resolve_request_id'
")"
if [[ "$resolve_state" != "approved:released:0" ]]; then
  echo "Onverwachte resolve/fulfil-uitkomst: $resolve_state"
  exit 1
fi

change_order_id="$("${psql_cmd[@]}" -Atc "
  select id
  from app.member_orders
  where member_season_id = 'cc510000-0000-4000-8000-000000000004'
")"
change_revision="$("${psql_cmd[@]}" -At <<SQL
begin;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
)
\gset
select app.preflight_package_change_v1(
  '$change_order_id',
  'cc410000-0000-4000-8000-000000000002',
  'Concurrencytest revisie-archivering',
  'cc830000-0000-4000-8000-000000000001',
  null
)->>'revision';
commit;
SQL
)"
archive_hash="$("${psql_cmd[@]}" -Atc "
  select private.package_revision_content_hash(
    'cc410000-0000-4000-8000-000000000002'
  )
")"
archive_log="$test_tmp_dir/package-change-archive.log"
apply_log="$test_tmp_dir/package-change-apply.log"
(
  "${psql_cmd[@]}" >"$archive_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.archive_package_revision(
  'cc410000-0000-4000-8000-000000000002',
  'Concurrencytest doelrevisie archiveren',
  '$archive_hash',
  null
);
\echo PACKAGE_CHANGE_ARCHIVE_HOLDING
select pg_sleep(1.5);
commit;
SQL
) &
archive_pid=$!
wait_for_marker "$archive_log" "PACKAGE_CHANGE_ARCHIVE_HOLDING"
set +e
(
  "${psql_cmd[@]}" >"$apply_log" 2>&1 <<SQL
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.apply_package_change_v1(
  'cc830000-0000-4000-8000-000000000001',
  '$change_revision',
  'SWITCH_PACKAGE',
  null
);
commit;
SQL
) &
apply_pid=$!
wait "$archive_pid"
archive_status=$?
wait "$apply_pid"
apply_status=$?
set -e
if [[ "$archive_status" -ne 0 ]]; then
  tail -n 40 "$archive_log"
  exit 1
fi
if [[ "$apply_status" -eq 0 ]] || ! grep -q "PACKAGE_CHANGE_STALE" "$apply_log"; then
  tail -n 40 "$apply_log"
  exit 1
fi
change_state="$("${psql_cmd[@]}" -Atc "
  select orders.package_revision_id::text || ':' || revision.status
  from app.member_orders orders
  join app.package_template_revisions revision
    on revision.id = 'cc410000-0000-4000-8000-000000000002'
  where orders.id = '$change_order_id'
")"
if [[ "$change_state" != "cc410000-0000-4000-8000-000000000001:archived" ]]; then
  echo "Pakketwissel gebruikte een gelijktijdig gearchiveerde revisie: $change_state"
  exit 1
fi

"${psql_cmd[@]}" <<'SQL'
insert into app.order_lines(
  id, order_id, article_variant_id, quantity, package_template_item_id
)
select
  'cc840000-0000-4000-8000-000000000001', orders.id,
  'cc300000-0000-4000-8000-000000000005', 1, null
from app.member_orders orders
where orders.member_season_id = 'cc510000-0000-4000-8000-000000000004';
SQL

loose_first_log="$test_tmp_dir/loose-remove-first.log"
loose_second_log="$test_tmp_dir/loose-remove-second.log"
(
  "${psql_cmd[@]}" >"$loose_first_log" 2>&1 <<'SQL'
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.remove_loose_order_line_v1(
  'cc840000-0000-4000-8000-000000000001',
  'Concurrencytest losse extra verwijderen',
  'cc850000-0000-4000-8000-000000000001',
  'cc860000-0000-4000-8000-000000000001'
);
\echo LOOSE_REMOVE_FIRST_HOLDING
select pg_sleep(1.5);
commit;
SQL
) &
loose_first_pid=$!
wait_for_marker "$loose_first_log" "LOOSE_REMOVE_FIRST_HOLDING"
(
  "${psql_cmd[@]}" >"$loose_second_log" 2>&1 <<'SQL'
begin;
set local statement_timeout = '15s';
set local lock_timeout = '10s';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"cc000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
select app.remove_loose_order_line_v1(
  'cc840000-0000-4000-8000-000000000001',
  'Concurrencytest losse extra verwijderen',
  'cc850000-0000-4000-8000-000000000001',
  'cc860000-0000-4000-8000-000000000001'
);
commit;
SQL
) &
loose_second_pid=$!
wait "$loose_first_pid"
wait "$loose_second_pid"
if ! grep -q '"reused"[[:space:]]*:[[:space:]]*false' "$loose_first_log"; then
  tail -n 40 "$loose_first_log"
  exit 1
fi
if ! grep -q '"reused"[[:space:]]*:[[:space:]]*true' "$loose_second_log"; then
  tail -n 40 "$loose_second_log"
  exit 1
fi
loose_state="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from private.loose_order_line_removal_requests
      where request_id = 'cc850000-0000-4000-8000-000000000001') || ':' ||
    (select status::text from app.order_lines
      where id = 'cc840000-0000-4000-8000-000000000001') || ':' ||
    (select count(*) from app.audit_logs
      where action = 'order.loose_line.cancelled'
        and entity_id = 'cc840000-0000-4000-8000-000000000001')
")"
if [[ "$loose_state" != "1:cancelled:1" ]]; then
  echo "Onverwachte losse-regelconcurrencystaat: $loose_state"
  exit 1
fi

echo "Package-concurrencytests geslaagd: idempotency, losse-regelcorrectie, catalogus, default, pakketwissel en conflicterende maatresoluties serialiseren zonder partial writes."
