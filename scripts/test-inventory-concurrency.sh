#!/usr/bin/env bash
set -Eeuo pipefail

database_url="postgresql://postgres:postgres@127.0.0.1:54339/postgres"
psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-inventory-concurrency.XXXXXX)"
identity="$("${psql_cmd[@]}" -c "select concat_ws('|',current_database(),current_user,inet_server_port())")"
if [[ "$identity" != "postgres|postgres|5432" ]]; then
  echo "Voorraadconcurrencytest weigert onverwachte lokale database-identiteit." >&2
  exit 2
fi
previous_flag="$("${psql_cmd[@]}" -c "select enabled::text from app.release_feature_flags where key='allocation_qr_v2'")"
previous_cutover="$("${psql_cmd[@]}" -c "select count(*)::text from private.release_cutovers where key='allocation_qr_v2'")"
previous_mail_flag="$("${psql_cmd[@]}" -c "select enabled::text from app.release_feature_flags where key='mail_templates_v2'")"
previous_mail_cutover="$("${psql_cmd[@]}" -c "select count(*)::text from private.release_cutovers where key='mail_templates_v2'")"
previous_active_season="$("${psql_cmd[@]}" -c "select active_season_id::text from app.app_settings where id=true")"

cleanup_data() {
  "${psql_cmd[@]}" <<SQL
begin;
set local session_replication_role = replica;
delete from private.inventory_allocation_queue
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from private.mail_v2_episode_dispatches
where event_id in (
  select id from private.mail_v2_domain_events
  where parent_account_id = 'f2700000-0000-4000-8000-000000000001'
);
delete from private.mail_v2_episode_transitions
where episode_id in (
  select id from private.mail_v2_notification_episodes
  where parent_account_id = 'f2700000-0000-4000-8000-000000000001'
);
delete from private.mail_v2_notification_episodes
where parent_account_id = 'f2700000-0000-4000-8000-000000000001';
delete from private.mail_v2_domain_events
where parent_account_id = 'f2700000-0000-4000-8000-000000000001';
delete from private.parent_portal_grants
where parent_account_id = 'f2700000-0000-4000-8000-000000000001';
delete from private.parent_accounts
where id = 'f2700000-0000-4000-8000-000000000001';
delete from app.action_items
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.audit_logs
where entity_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002',
  'f2600000-0000-4000-8000-000000000001',
  'f2600000-0000-4000-8000-000000000002'
);
delete from app.inventory_allocation_events
where allocation_id in (
  select id from app.inventory_allocations
  where season_id = 'f2100000-0000-4000-8000-000000000001'
);
delete from app.inventory_movements
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.inventory_allocations
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.payments
where order_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.member_package_size_selections
where assignment_id in (
  select id from app.member_package_assignments
  where order_id in (
    'f2500000-0000-4000-8000-000000000001',
    'f2500000-0000-4000-8000-000000000002'
  )
);
delete from app.member_package_assignments
where order_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id from app.order_package_snapshots
  where order_id in (
    'f2500000-0000-4000-8000-000000000001',
    'f2500000-0000-4000-8000-000000000002'
  )
);
delete from app.order_package_snapshots
where order_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.order_lines
where order_id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.member_orders
where id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
delete from app.member_article_sizes
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.member_external_identities
where member_id in (
  'f2400000-0000-4000-8000-000000000001',
  'f2400000-0000-4000-8000-000000000002'
);
delete from private.member_sensitive_identity
where member_id in (
  'f2400000-0000-4000-8000-000000000001',
  'f2400000-0000-4000-8000-000000000002'
);
delete from app.member_seasons
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.members
where id in (
  'f2400000-0000-4000-8000-000000000001',
  'f2400000-0000-4000-8000-000000000002'
);
delete from app.article_seasons
where season_id = 'f2100000-0000-4000-8000-000000000001';
delete from app.article_variants
where article_id = 'f2200000-0000-4000-8000-000000000001';
delete from app.articles
where id = 'f2200000-0000-4000-8000-000000000001';
delete from app.inventory_settings
where season_id = 'f2100000-0000-4000-8000-000000000001';
update app.app_settings
set active_season_id = '${previous_active_season}'
where id = true;
delete from app.seasons
where id = 'f2100000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'f2000000-0000-4000-8000-000000000001';
update app.release_feature_flags
set enabled = ${previous_flag}
where key = 'allocation_qr_v2';
delete from private.release_cutovers
where key = 'allocation_qr_v2'
  and ${previous_cutover} = 0;
update app.release_feature_flags
set enabled = ${previous_mail_flag}
where key = 'mail_templates_v2';
delete from private.release_cutovers
where key = 'mail_templates_v2'
  and ${previous_mail_cutover} = 0;
commit;
SQL
}

cleanup() {
  local status=$?
  if (( status != 0 )); then
    echo "Voorraadconcurrencytest faalde; diagnostische subprocesslogs volgen." >&2
    for log_file in "${test_tmp_dir}"/*.log; do
      [[ -f "$log_file" ]] || continue
      echo "--- $(basename "$log_file") ---" >&2
      sed -n '1,120p' "$log_file" >&2
    done
  fi
  cleanup_data >/dev/null 2>&1 || status=1
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT

cleanup_data >/dev/null
"${psql_cmd[@]}" >/dev/null <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values ('f2000000-0000-4000-8000-000000000001','Queue concurrency','beheerder');
insert into private.release_cutovers(key)
values ('mail_templates_v2')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';
insert into app.seasons(id, name, default_amount_cents, status)
values ('f2100000-0000-4000-8000-000000000001', 'Voorraadconcurrency', 12500, 'open');
update app.app_settings
set active_season_id = 'f2100000-0000-4000-8000-000000000001'
where id = true;
insert into app.articles(id, name, code, sort_order)
values ('f2200000-0000-4000-8000-000000000001', 'Concurrencyshirt', 'CON-SHIRT', 990);
insert into app.article_seasons(article_id, season_id)
values ('f2200000-0000-4000-8000-000000000001', 'f2100000-0000-4000-8000-000000000001');
insert into app.article_variants(id, article_id, size, sku)
values (
  'f2300000-0000-4000-8000-000000000001',
  'f2200000-0000-4000-8000-000000000001',
  'M',
  'CON-M'
);
insert into app.members(id, relation_number, first_name, last_name, email, team) values
  ('f2400000-0000-4000-8000-000000000001', 'CON-001', 'Eerste', 'Race', 'con-1@example.invalid', 'TEST'),
  ('f2400000-0000-4000-8000-000000000002', 'CON-002', 'Tweede', 'Race', 'con-2@example.invalid', 'TEST');
insert into app.member_orders(id, member_id, season_id, amount_due_cents) values
  ('f2500000-0000-4000-8000-000000000001', 'f2400000-0000-4000-8000-000000000001', 'f2100000-0000-4000-8000-000000000001', 12500),
  ('f2500000-0000-4000-8000-000000000002', 'f2400000-0000-4000-8000-000000000002', 'f2100000-0000-4000-8000-000000000001', 12500);
insert into app.order_lines(id, order_id, article_variant_id) values
  ('f2600000-0000-4000-8000-000000000001', 'f2500000-0000-4000-8000-000000000001', 'f2300000-0000-4000-8000-000000000001'),
  ('f2600000-0000-4000-8000-000000000002', 'f2500000-0000-4000-8000-000000000002', 'f2300000-0000-4000-8000-000000000001');
select set_config('app.package_size_internal', 'on', true);
update app.member_article_sizes
set selection_status = 'confirmed',
    selection_source = 'staff',
    confirmed_at = timezone('utc', now()) - interval '2 days',
    article_variant_id = 'f2300000-0000-4000-8000-000000000001',
    raw_value = null,
    member_note = null
where season_id = 'f2100000-0000-4000-8000-000000000001';
select set_config('app.package_size_internal', 'off', true);
insert into private.parent_accounts(id, email_normalized)
values ('f2700000-0000-4000-8000-000000000001','queue-parent@example.invalid');
insert into private.parent_portal_grants(
  id, member_season_id, email_normalized, parent_account_id, status,
  source, granted_by, granted_at
)
select
  case orders.id
    when 'f2500000-0000-4000-8000-000000000001'::uuid
      then 'f2800000-0000-4000-8000-000000000001'::uuid
    else 'f2800000-0000-4000-8000-000000000002'::uuid
  end,
  orders.member_season_id,
  'queue-parent@example.invalid',
  'f2700000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  'f2000000-0000-4000-8000-000000000001',
  clock_timestamp()
from app.member_orders orders
where orders.id in (
  'f2500000-0000-4000-8000-000000000001',
  'f2500000-0000-4000-8000-000000000002'
);
insert into app.payments(
  order_id, method, status, amount_cents, idempotency_key, paid_at
) values
  ('f2500000-0000-4000-8000-000000000001', 'cash', 'paid', 12500, 'inventory-concurrency-1', timezone('utc', now()) - interval '3 days'),
  ('f2500000-0000-4000-8000-000000000002', 'cash', 'paid', 12500, 'inventory-concurrency-2', timezone('utc', now()) - interval '1 day');
insert into app.inventory_movements(
  season_id, article_id, article_variant_id, movement_type, on_hand_delta,
  source_type, reason_code, idempotency_key
) values (
  'f2100000-0000-4000-8000-000000000001',
  'f2200000-0000-4000-8000-000000000001',
  'f2300000-0000-4000-8000-000000000001',
  'opening_balance',
  1,
  'concurrency_test',
  'inventory.concurrency_opening',
  repeat('f', 64)
);
insert into private.release_cutovers(key)
values ('allocation_qr_v2')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key = 'allocation_qr_v2';
SQL

run_allocator() {
  "${psql_cmd[@]}" -c "
    select private.allocate_inventory_fifo_variant(
      'f2100000-0000-4000-8000-000000000001',
      'f2300000-0000-4000-8000-000000000001',
      'concurrency_test',
      null,
      null,
      null
    );
  "
}

run_allocator >"${test_tmp_dir}/allocator-1.log" 2>&1 &
first_pid=$!
run_allocator >"${test_tmp_dir}/allocator-2.log" 2>&1 &
second_pid=$!
set +e
wait "$first_pid"
first_status=$?
wait "$second_pid"
second_status=$?
set -e
if (( first_status != 0 || second_status != 0 )); then
  sed -n '1,80p' "${test_tmp_dir}/allocator-1.log" >&2
  sed -n '1,80p' "${test_tmp_dir}/allocator-2.log" >&2
  echo "Voorraadallocatorconcurrency eindigde met een databasefout." >&2
  exit 1
fi

state="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    (select count(*) from app.inventory_allocations
      where season_id='f2100000-0000-4000-8000-000000000001'
        and status='reserved'),
    (select count(*) from app.inventory_movements
      where season_id='f2100000-0000-4000-8000-000000000001'
        and movement_type='allocation_reserved'),
    (select available from private.inventory_balance(
      'f2100000-0000-4000-8000-000000000001',
      'f2300000-0000-4000-8000-000000000001'
    )),
    (select order_line_id::text from app.inventory_allocations
      where season_id='f2100000-0000-4000-8000-000000000001'
        and status='reserved')
  )
")"
expected="1:1:0:f2600000-0000-4000-8000-000000000001"
if [[ "$state" != "$expected" ]]; then
  echo "Onverwachte voorraadconcurrencystaat: $state" >&2
  exit 1
fi

run_refresh() {
  local source_type="$1"
  local source_id="$2"
  "${psql_cmd[@]}" -c "
    select private.refresh_inventory_variant_actions(
      'f2100000-0000-4000-8000-000000000001',
      'f2300000-0000-4000-8000-000000000001',
      '${source_type}',
      '${source_id}'
    );
  "
}

run_refresh \
  inventory_delivery \
  f2500000-0000-4000-8000-000000000001 \
  >"${test_tmp_dir}/refresh-1.log" 2>&1 &
first_refresh_pid=$!
run_refresh \
  mollie_acceptance \
  f2500000-0000-4000-8000-000000000002 \
  >"${test_tmp_dir}/refresh-2.log" 2>&1 &
second_refresh_pid=$!
set +e
wait "$first_refresh_pid"
first_refresh_status=$?
wait "$second_refresh_pid"
second_refresh_status=$?
set -e
if (( first_refresh_status != 0 || second_refresh_status != 0 )); then
  sed -n '1,80p' "${test_tmp_dir}/refresh-1.log" >&2
  sed -n '1,80p' "${test_tmp_dir}/refresh-2.log" >&2
  echo "Gelijktijdige voorraadactieverversing met verschillende bronnen faalde." >&2
  exit 1
fi

action_state="$("${psql_cmd[@]}" -c "
  select concat_ws(':', count(*), min(source_type), min(source_id::text))
  from app.action_items
  where season_id = 'f2100000-0000-4000-8000-000000000001'
    and object_type = 'article_variant'
    and object_id = 'f2300000-0000-4000-8000-000000000001'
    and type = 'out_of_stock'
    and status in ('open', 'in_progress')
")"
expected_action_state="1:article_variant:f2300000-0000-4000-8000-000000000001"
if [[ "$action_state" != "$expected_action_state" ]]; then
  echo "Onstabiele voorraadactie-identiteit: $action_state" >&2
  exit 1
fi

# Payment validity and size validity can become true at the same time. Both
# triggers must coalesce onto one queue row without losing either generation.
"${psql_cmd[@]}" >/dev/null <<'SQL'
update app.payments
set reconciliation_issue = 'queue concurrency setup'
where order_id = 'f2500000-0000-4000-8000-000000000002';
select set_config('app.package_size_internal', 'on', true);
update app.member_article_sizes
set selection_status = 'imported_unconfirmed',
    selection_source = 'import',
    confirmed_at = null
where member_id = 'f2400000-0000-4000-8000-000000000002'
  and season_id = 'f2100000-0000-4000-8000-000000000001';
select set_config('app.package_size_internal', 'off', true);
-- The fixture's initial paid payment can already have produced this event.
-- Remove that setup artifact so the concurrent payment transition creates the
-- event under test instead of comparing its mutable size snapshot with an old
-- idempotency snapshot.
begin;
set local session_replication_role = replica;
delete from private.mail_v2_episode_dispatches
where event_id in (
  select id from private.mail_v2_domain_events
  where template_key = 'payment_received_waiting_stock'
    and order_id = 'f2500000-0000-4000-8000-000000000002'
);
delete from private.mail_v2_episode_transitions
where episode_id in (
  select id from private.mail_v2_notification_episodes
  where parent_account_id = 'f2700000-0000-4000-8000-000000000001'
    and scope_id = 'f2500000-0000-4000-8000-000000000002'
);
delete from private.mail_v2_notification_episodes
where parent_account_id = 'f2700000-0000-4000-8000-000000000001'
  and scope_id = 'f2500000-0000-4000-8000-000000000002';
delete from private.mail_v2_domain_events
where template_key = 'payment_received_waiting_stock'
  and order_id = 'f2500000-0000-4000-8000-000000000002';
commit;
delete from private.inventory_allocation_queue
where season_id = 'f2100000-0000-4000-8000-000000000001'
  and article_variant_id = 'f2300000-0000-4000-8000-000000000001';
SQL

"${psql_cmd[@]}" -c "update app.payments set reconciliation_issue=null where order_id='f2500000-0000-4000-8000-000000000002'" \
  >"${test_tmp_dir}/payment-enqueue.log" 2>&1 &
payment_enqueue_pid=$!
"${psql_cmd[@]}" -c "select set_config('app.package_size_internal','on',false); update app.member_article_sizes set selection_status='confirmed',selection_source='staff',confirmed_at=clock_timestamp() where member_id='f2400000-0000-4000-8000-000000000002' and season_id='f2100000-0000-4000-8000-000000000001'" \
  >"${test_tmp_dir}/size-enqueue.log" 2>&1 &
size_enqueue_pid=$!
wait "$payment_enqueue_pid"
wait "$size_enqueue_pid"

trigger_state="$("${psql_cmd[@]}" -c "
  select concat_ws(':',count(*),min(status::text),min(attempts),min(requested_generation))
  from private.inventory_allocation_queue
  where season_id='f2100000-0000-4000-8000-000000000001'
    and article_variant_id='f2300000-0000-4000-8000-000000000001'
")"
if [[ "$trigger_state" != "1:queued:0:2" ]]; then
  echo "Gelijktijdige betaal-/maatenqueue verloor werk: $trigger_state" >&2
  exit 1
fi

# Projection eligibility and inventory completion may race. Every observed
# state must remain valid, and the naturally produced payment event must end
# eligible after shortage reconciliation without a synthetic event/job.
payment_event_id="$("${psql_cmd[@]}" -c "
  select id::text
  from private.mail_v2_domain_events
  where template_key='payment_received_waiting_stock'
    and order_id='f2500000-0000-4000-8000-000000000002'
  order by created_at desc limit 1
")"
if [[ -z "$payment_event_id" ]]; then
  echo "De betaaltrigger produceerde geen waiting-stock-event." >&2
  exit 1
fi
(
  for _ in $(seq 1 30); do
    "${psql_cmd[@]}" -c "select private.mail_v2_event_state('${payment_event_id}')"
  done
) >"${test_tmp_dir}/mail-state-race.log" 2>&1 &
mail_state_pid=$!
"${psql_cmd[@]}" -c "set role service_role; select app.process_inventory_allocation_queue(10)" \
  >"${test_tmp_dir}/mail-completion-race.log" 2>&1
wait "$mail_state_pid"
if grep -Evq '^(pending|eligible)$' "${test_tmp_dir}/mail-state-race.log"; then
  sed -n '1,80p' "${test_tmp_dir}/mail-state-race.log" >&2
  echo "Mailstate kreeg tijdens inventory completion een ongeldige overgang." >&2
  exit 1
fi
final_mail_state="$("${psql_cmd[@]}" -c "select private.mail_v2_event_state('${payment_event_id}')")"
if [[ "$final_mail_state" != "eligible" ]]; then
  echo "Waiting-stock-event bleef na completion geblokkeerd: $final_mail_state" >&2
  exit 1
fi

"${psql_cmd[@]}" >/dev/null <<'SQL'
insert into app.inventory_movements(
  season_id, article_id, article_variant_id, movement_type, on_hand_delta,
  source_type, reason_code, idempotency_key
) values (
  'f2100000-0000-4000-8000-000000000001',
  'f2200000-0000-4000-8000-000000000001',
  'f2300000-0000-4000-8000-000000000001',
  'adjustment_in', 1, 'concurrency_test',
  'inventory.queue_contention_stock', repeat('e',64)
);
update private.inventory_allocation_queue
set status='failed', attempts=9, processing_generation=null,
    last_error_code='concurrent_mutation_retry'
where season_id='f2100000-0000-4000-8000-000000000001'
  and article_variant_id='f2300000-0000-4000-8000-000000000001';
SQL

lock_marker="${test_tmp_dir}/order-lock-held"
"${psql_cmd[@]}" >"${test_tmp_dir}/order-lock.log" 2>&1 <<SQL &
begin;
select 1 from app.order_lines
where id='f2600000-0000-4000-8000-000000000002'
for update;
\o ${lock_marker}
select 'held';
\o
select pg_sleep(5);
commit;
SQL
lock_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$lock_marker" ]] && break
  sleep 0.05
done
if [[ ! -s "$lock_marker" ]]; then
  echo "Kon de deterministische orderlock niet vaststellen." >&2
  exit 1
fi

"${psql_cmd[@]}" -c "set role service_role; select app.process_inventory_allocation_queue(10)" \
  >"${test_tmp_dir}/final-attempt.log" 2>&1
wait "$lock_pid"
exhausted_state="$("${psql_cmd[@]}" -c "
  select concat_ws(':',status,attempts,last_error_code,
    (select count(*) from app.action_items item
      where item.type='inventory_allocation_exhausted'
        and item.season_id=queue.season_id
        and item.object_id=queue.article_variant_id
        and item.status='open'))
  from private.inventory_allocation_queue queue
  where season_id='f2100000-0000-4000-8000-000000000001'
    and article_variant_id='f2300000-0000-4000-8000-000000000001'
")"
if [[ "$exhausted_state" != "failed:10:concurrent_mutation_exhausted:1" ]]; then
  echo "Laatste lockpoging werd niet veilig geterminaliseerd: $exhausted_state" >&2
  exit 1
fi

# An enqueue that overlaps a processing row waits for its row lock and then
# opens a fresh runnable lifecycle; it can never be overwritten by completion.
processing_marker="${test_tmp_dir}/processing-row-held"
"${psql_cmd[@]}" >"${test_tmp_dir}/processing-row.log" 2>&1 <<SQL &
begin;
update private.inventory_allocation_queue
set status='processing', processing_generation=requested_generation,
    attempts=1, started_at=clock_timestamp(), completed_at=null
where season_id='f2100000-0000-4000-8000-000000000001'
  and article_variant_id='f2300000-0000-4000-8000-000000000001';
\o ${processing_marker}
select 'held';
\o
select pg_sleep(3);
update private.inventory_allocation_queue
set status='completed', processing_generation=null,
    completed_at=clock_timestamp()
where season_id='f2100000-0000-4000-8000-000000000001'
  and article_variant_id='f2300000-0000-4000-8000-000000000001';
commit;
SQL
processing_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$processing_marker" ]] && break
  sleep 0.05
done
"${psql_cmd[@]}" -c "select private.enqueue_inventory_variant(
  'f2100000-0000-4000-8000-000000000001',
  'f2300000-0000-4000-8000-000000000001',
  'concurrency.processing_followup'
)" >"${test_tmp_dir}/processing-enqueue.log" 2>&1 &
followup_pid=$!
wait "$processing_pid"
wait "$followup_pid"
followup_state="$("${psql_cmd[@]}" -c "
  select concat_ws(':',status,attempts,processing_generation is null,reason_code)
  from private.inventory_allocation_queue
  where season_id='f2100000-0000-4000-8000-000000000001'
    and article_variant_id='f2300000-0000-4000-8000-000000000001'
")"
if [[ "$followup_state" != "queued:0:t:concurrency.processing_followup" ]]; then
  echo "Enqueue tijdens processing ging verloren: $followup_state" >&2
  exit 1
fi

echo "Voorraadconcurrency geslaagd: FIFO, dubbele triggers, terminale lockretry en processing-follow-up zijn lineair veilig."
