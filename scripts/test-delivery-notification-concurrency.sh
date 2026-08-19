#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De leveringnotificatie-racetest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
mkdir -p .tmp
test_tmp_dir="$(mktemp -d .tmp/delivery-notification.XXXXXX)"
first_log="$test_tmp_dir/confirm-first.log"
second_log="$test_tmp_dir/confirm-second.log"

staff_id="d4300000-0000-4000-8000-000000000001"
season_id="d4300000-0000-4000-8000-000000000002"
article_id="d4300000-0000-4000-8000-000000000003"
variant_id="d4300000-0000-4000-8000-000000000004"
member_id="d4300000-0000-4000-8000-000000000005"
order_id="d4300000-0000-4000-8000-000000000006"
line_id="d4300000-0000-4000-8000-000000000007"
payment_id="d4300000-0000-4000-8000-000000000008"
parent_id="d4300000-0000-4000-8000-000000000009"
grant_id="d4300000-0000-4000-8000-00000000000a"
receipt_id="d4300000-0000-4000-8000-00000000000b"
draft_id="d4300000-0000-4000-8000-00000000000c"
allocation_id="d4300000-0000-4000-8000-00000000000d"
allocation_event_id="d4300000-0000-4000-8000-00000000000e"
request_id="d4300000-0000-4000-8000-00000000000f"
fixture_template_revision_id="d4300000-0000-4000-8000-000000000011"

previous_mail_flag="$("${psql_cmd[@]}" -c \
  "select enabled::text from app.release_feature_flags where key='mail_templates_v2'")"
previous_mail_cutover="$("${psql_cmd[@]}" -c \
  "select exists(select 1 from private.release_cutovers where key='mail_templates_v2')::text")"
previous_active_season="$("${psql_cmd[@]}" -c \
  "select coalesce(active_season_id::text, '') from app.app_settings where id=true")"
proposal_id=""
proposal_item_id=""
eligibility_revision=""

cleanup_data() {
  "${psql_cmd[@]}" \
    -v staff_id="$staff_id" \
    -v season_id="$season_id" \
    -v article_id="$article_id" \
    -v variant_id="$variant_id" \
    -v member_id="$member_id" \
    -v order_id="$order_id" \
    -v line_id="$line_id" \
    -v payment_id="$payment_id" \
    -v parent_id="$parent_id" \
    -v receipt_id="$receipt_id" \
    -v draft_id="$draft_id" \
    -v allocation_id="$allocation_id" \
    -v request_id="$request_id" \
    -v previous_mail_flag="$previous_mail_flag" \
    -v previous_mail_cutover="$previous_mail_cutover" \
    -v previous_active_season="$previous_active_season" \
    -v fixture_template_revision_id="$fixture_template_revision_id" \
    >/dev/null <<'SQL'
begin;
set local session_replication_role = replica;

delete from private.mail_v2_episode_transitions
where episode_id in (
  select id from private.mail_v2_notification_episodes
  where parent_account_id = :'parent_id'::uuid
);
delete from private.mail_v2_episode_dispatches
where episode_id in (
  select id from private.mail_v2_notification_episodes
  where parent_account_id = :'parent_id'::uuid
);
delete from private.mail_v2_notification_episodes
where parent_account_id = :'parent_id'::uuid;
delete from private.mail_v2_event_suppressions
where event_id in (
  select id from private.mail_v2_domain_events
  where source_id = 'd4300000-0000-4000-8000-00000000000e'::uuid
);
delete from private.mail_v2_projections
where event_id in (
  select id from private.mail_v2_domain_events
  where source_id = 'd4300000-0000-4000-8000-00000000000e'::uuid
);
delete from private.mail_v2_domain_events
where source_id = 'd4300000-0000-4000-8000-00000000000e'::uuid;

delete from private.inventory_command_requests
where request_id = :'request_id'::uuid;
delete from app.audit_logs
where actor_user_id = :'staff_id'::uuid
  or entity_id in (
    :'draft_id'::uuid,
    :'allocation_id'::uuid,
    :'order_id'::uuid
  );
delete from app.inventory_delivery_notification_items
where allocation_id = :'allocation_id'::uuid;
delete from app.inventory_delivery_notification_proposals
where delivery_draft_id = :'draft_id'::uuid;
delete from app.inventory_allocation_events
where allocation_id = :'allocation_id'::uuid;
delete from app.inventory_movements
where allocation_id = :'allocation_id'::uuid
  or delivery_draft_id = :'draft_id'::uuid;
delete from app.inventory_allocations
where id = :'allocation_id'::uuid;
delete from app.inventory_delivery_draft_lines
where draft_id = :'draft_id'::uuid;
delete from app.inventory_delivery_drafts
where id = :'draft_id'::uuid;
delete from app.delivery_receipt_lines
where receipt_id = :'receipt_id'::uuid;
delete from app.delivery_receipts
where id = :'receipt_id'::uuid;

delete from private.parent_portal_grants
where parent_account_id = :'parent_id'::uuid;
delete from private.parent_accounts
where id = :'parent_id'::uuid;
delete from app.payments
where id = :'payment_id'::uuid;
delete from private.inventory_allocation_queue
where season_id = :'season_id'::uuid;
delete from app.action_items
where season_id = :'season_id'::uuid;
delete from app.member_package_size_selections
where assignment_id in (
  select id from app.member_package_assignments
  where order_id = :'order_id'::uuid
);
delete from app.member_package_assignments
where order_id = :'order_id'::uuid;
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id from app.order_package_snapshots
  where order_id = :'order_id'::uuid
);
delete from app.order_package_snapshots
where order_id = :'order_id'::uuid;
delete from app.order_lines
where id = :'line_id'::uuid;
delete from app.member_orders
where id = :'order_id'::uuid;
delete from app.member_article_sizes
where member_id = :'member_id'::uuid;
delete from app.member_external_identities
where member_id = :'member_id'::uuid;
delete from private.member_sensitive_identity
where member_id = :'member_id'::uuid;
delete from app.member_seasons
where member_id = :'member_id'::uuid;
delete from app.members
where id = :'member_id'::uuid;
delete from app.article_seasons
where article_id = :'article_id'::uuid;
delete from app.article_variants
where id = :'variant_id'::uuid;
delete from app.articles
where id = :'article_id'::uuid;
delete from app.inventory_settings
where season_id = :'season_id'::uuid;
update app.app_settings
set active_season_id = nullif(:'previous_active_season', '')::uuid
where id = true;
delete from app.seasons
where id = :'season_id'::uuid;
delete from app.staff_profiles
where auth_user_id = :'staff_id'::uuid;

delete from app.mail_template_revisions
where id = :'fixture_template_revision_id'::uuid
  and internal_name = 'Concurrency afhaalbericht'
  and creation_source = 'system';
update app.release_feature_flags
set enabled = :'previous_mail_flag'::boolean
where key = 'mail_templates_v2';
delete from private.release_cutovers
where key = 'mail_templates_v2'
  and not :'previous_mail_cutover'::boolean;

set local session_replication_role = origin;
commit;
SQL
}

cleanup() {
  local status=$?
  cleanup_data >/dev/null 2>&1 || status=1
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT

cleanup_data >/dev/null

setup="$("${psql_cmd[@]}" \
  -v staff_id="$staff_id" \
  -v season_id="$season_id" \
  -v article_id="$article_id" \
  -v variant_id="$variant_id" \
  -v member_id="$member_id" \
  -v order_id="$order_id" \
  -v line_id="$line_id" \
  -v payment_id="$payment_id" \
  -v parent_id="$parent_id" \
  -v grant_id="$grant_id" \
  -v receipt_id="$receipt_id" \
  -v draft_id="$draft_id" \
  -v allocation_id="$allocation_id" \
  -v allocation_event_id="$allocation_event_id" \
  -v fixture_template_revision_id="$fixture_template_revision_id" <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (:'staff_id'::uuid, 'Leveringnotificatie race', 'beheerder');

insert into app.seasons(id, name, default_amount_cents, status)
values (:'season_id'::uuid, 'Leveringnotificatie 2026', 12500, 'open');
update app.app_settings
set active_season_id = :'season_id'::uuid
where id = true;

insert into app.articles(id, name, code, sort_order, active)
values (
  :'article_id'::uuid,
  'Notificatieshirt',
  'NOTIFY-SHIRT',
  934,
  true
);
insert into app.article_seasons(article_id, season_id)
values (:'article_id'::uuid, :'season_id'::uuid);
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
) values (
  :'variant_id'::uuid,
  :'article_id'::uuid,
  'M',
  'NOTIFY-M',
  1,
  true
);

insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values (
  :'member_id'::uuid,
  'NOTIFY-001',
  'Fictief',
  'Concurrencylid',
  'notify-concurrency@example.invalid',
  'TEST'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
) values (
  :'order_id'::uuid,
  :'member_id'::uuid,
  :'season_id'::uuid,
  12500
);
insert into app.order_lines(
  id,
  order_id,
  article_variant_id
) values (
  :'line_id'::uuid,
  :'order_id'::uuid,
  :'variant_id'::uuid
);
update app.order_lines
set status = 'ready_for_pickup'
where id = :'line_id'::uuid;

insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key,
  paid_at
) values (
  :'payment_id'::uuid,
  :'order_id'::uuid,
  'cash',
  'paid',
  12500,
  'delivery-notification-concurrency-paid',
  timezone('utc', now()) - interval '1 day'
);

insert into private.parent_accounts(id, email_normalized)
values (
  :'parent_id'::uuid,
  'notify-concurrency@example.invalid'
);
insert into private.parent_portal_grants(
  id,
  member_season_id,
  email_normalized,
  parent_account_id,
  status,
  source,
  granted_by,
  granted_at
) select
  :'grant_id'::uuid,
  orders.member_season_id,
  'notify-concurrency@example.invalid',
  :'parent_id'::uuid,
  'active',
  'administrator',
  :'staff_id'::uuid,
  timezone('utc', now())
from app.member_orders orders
where orders.id = :'order_id'::uuid;

insert into private.release_cutovers(key)
values ('mail_templates_v2')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

with next_revision as (
  select coalesce(max(revision), 0) + 1 as revision
  from app.mail_template_revisions
  where template_key = 'pickup_ready'
), inserted as (
  insert into app.mail_template_revisions(
    id,
    template_key,
    revision,
    status,
    internal_name,
    subject_source,
    preheader_source,
    body_tiptap,
    sanitized_html_source,
    text_fallback_source,
    content_hash,
    creation_source,
    published_at
  )
  select
    :'fixture_template_revision_id'::uuid,
    'pickup_ready',
    next_revision.revision,
    'published',
    'Concurrency afhaalbericht',
    'Afhalen voor {{member_first_name}}',
    'Bekijk de afhaalklare pakketregels in het portaal.',
    '{
      "type":"doc",
      "content":[
        {
          "type":"paragraph",
          "content":[
            {"type":"text","text":"Fictieve afhaalcontrole voor "},
            {"type":"shortcode","attrs":{"key":"member_first_name"}},
            {"type":"text","text":" via "},
            {"type":"shortcode","attrs":{"key":"portal_url"}}
          ]
        },
        {"type":"protectedBlock","attrs":{"kind":"ready_items"}},
        {"type":"protectedBlock","attrs":{"kind":"pickup_location"}},
        {"type":"protectedBlock","attrs":{"kind":"pickup_qr"}}
      ]
    }'::jsonb,
    '<p>Fictieve afhaalcontrole</p><table><tbody><tr><td>Afhaalklaar</td></tr></tbody></table>',
    'Fictieve afhaalcontrole via het ledenportaal.',
    private.mail_template_content_hash(
      'pickup_ready',
      'Concurrency afhaalbericht',
      'Afhalen voor {{member_first_name}}',
      'Bekijk de afhaalklare pakketregels in het portaal.',
      '{
        "type":"doc",
        "content":[
          {
            "type":"paragraph",
            "content":[
              {"type":"text","text":"Fictieve afhaalcontrole voor "},
              {"type":"shortcode","attrs":{"key":"member_first_name"}},
              {"type":"text","text":" via "},
              {"type":"shortcode","attrs":{"key":"portal_url"}}
            ]
          },
          {"type":"protectedBlock","attrs":{"kind":"ready_items"}},
          {"type":"protectedBlock","attrs":{"kind":"pickup_location"}},
          {"type":"protectedBlock","attrs":{"kind":"pickup_qr"}}
        ]
      }'::jsonb,
      '<p>Fictieve afhaalcontrole</p><table><tbody><tr><td>Afhaalklaar</td></tr></tbody></table>',
      'Fictieve afhaalcontrole via het ledenportaal.'
    ),
    'system',
    timezone('utc', now())
  from next_revision
  where not exists(
    select 1
    from app.mail_template_revisions
    where template_key = 'pickup_ready'
      and status = 'published'
  )
  returning id
), receipt as (
  insert into app.delivery_receipts(
    id,
    received_on,
    supplier,
    actor_user_id
  ) values (
    :'receipt_id'::uuid,
    current_date,
    'Fictieve leverancier',
    :'staff_id'::uuid
  )
  returning id
), draft as (
  insert into app.inventory_delivery_drafts(
    id,
    season_id,
    status,
    received_on,
    supplier,
    revision,
    create_request_id,
    create_request_hash,
    created_by,
    updated_by
  ) values (
    :'draft_id'::uuid,
    :'season_id'::uuid,
    'ready',
    current_date,
    'Fictieve leverancier',
    1,
    'd4300000-0000-4000-8000-000000000010'::uuid,
    repeat('d', 64),
    :'staff_id'::uuid,
    :'staff_id'::uuid
  )
  returning id
)
select count(*) from inserted;

update app.inventory_delivery_drafts
set status = 'posted',
    posted_receipt_id = :'receipt_id'::uuid,
    posted_at = timezone('utc', now()),
    posted_by = :'staff_id'::uuid,
    updated_by = :'staff_id'::uuid,
    updated_at = timezone('utc', now())
where id = :'draft_id'::uuid;

insert into app.inventory_allocations(
  id,
  season_id,
  member_id,
  member_season_id,
  order_id,
  order_line_id,
  article_id,
  article_variant_id,
  quantity,
  status,
  reconciliation_status,
  allocation_mode,
  paid_at,
  size_valid_at,
  priority_at,
  product_name_snapshot,
  size_snapshot,
  allocated_at,
  allocated_by
) select
  :'allocation_id'::uuid,
  :'season_id'::uuid,
  :'member_id'::uuid,
  orders.member_season_id,
  :'order_id'::uuid,
  :'line_id'::uuid,
  :'article_id'::uuid,
  :'variant_id'::uuid,
  1,
  'reserved',
  'resolved',
  'fifo',
  payment.paid_at,
  timezone('utc', now()) - interval '2 days',
  greatest(
    payment.paid_at,
    timezone('utc', now()) - interval '2 days'
  ),
  'Notificatieshirt',
  'M',
  timezone('utc', now()),
  :'staff_id'::uuid
from app.member_orders orders
join app.payments payment on payment.order_id = orders.id
where orders.id = :'order_id'::uuid
  and payment.id = :'payment_id'::uuid;

insert into app.inventory_allocation_events(
  id,
  allocation_id,
  event_type,
  next_status,
  reason_code,
  source_type,
  source_id,
  idempotency_key,
  actor_user_id,
  safe_context
) values (
  :'allocation_event_id'::uuid,
  :'allocation_id'::uuid,
  'reserved',
  'reserved',
  'inventory.fifo_reserved',
  'inventory_delivery',
  :'draft_id'::uuid,
  repeat('e', 64),
  :'staff_id'::uuid,
  jsonb_build_object(
    'allocationId', :'allocation_id'::uuid,
    'orderItemId', :'line_id'::uuid,
    'variantId', :'variant_id'::uuid,
    'quantity', 1
  )
);

select concat_ws(
  '|',
  (
    select proposal.id
    from app.inventory_delivery_notification_proposals proposal
    where proposal.delivery_draft_id = :'draft_id'::uuid
  ),
  (
    select item.id
    from app.inventory_delivery_notification_items item
    where item.allocation_event_id = :'allocation_event_id'::uuid
  ),
  (
    select private.inventory_delivery_notification_revision(proposal.id)
    from app.inventory_delivery_notification_proposals proposal
    where proposal.delivery_draft_id = :'draft_id'::uuid
  )
);
SQL
)"

IFS='|' read -r proposal_id proposal_item_id eligibility_revision \
  <<<"$(printf '%s\n' "$setup" | sed -n '2p')"
if [[ ! "$proposal_id" =~ ^[0-9a-f-]{36}$ ]] \
  || [[ ! "$proposal_item_id" =~ ^[0-9a-f-]{36}$ ]] \
  || [[ ! "$eligibility_revision" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Het PII-vrije leveringnotificatievoorstel kon niet worden voorbereid." >&2
  exit 1
fi

automatic_events="$("${psql_cmd[@]}" \
  -v allocation_event_id="$allocation_event_id" <<'SQL'
select count(*)
  from private.mail_v2_domain_events
  where source_type = 'inventory_allocation_event'
    and source_id = :'allocation_event_id'::uuid;
SQL
)"
if [[ "$automatic_events" != "0" ]]; then
  echo "Het boeken van de levering maakte ten onrechte automatisch een afhaalevent." >&2
  exit 1
fi

run_confirm() {
  local hold_seconds="$1"
  "${psql_cmd[@]}" \
    -v staff_id="$staff_id" \
    -v proposal_id="$proposal_id" \
    -v proposal_item_id="$proposal_item_id" \
    -v eligibility_revision="$eligibility_revision" \
    -v request_id="$request_id" \
    -v hold_seconds="$hold_seconds" <<'SQL'
begin;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'staff_id', 'aal', 'aal2')::text,
  true
);
set local role authenticated;
select app.confirm_inventory_delivery_notification_proposal_v1(
  :'proposal_id'::uuid,
  :'eligibility_revision',
  array[]::uuid[],
  :'request_id'::uuid,
  null
)->>'reused';
select pg_sleep(:'hold_seconds'::numeric);
commit;
SQL
}

run_confirm 1 >"$first_log" 2>&1 &
first_pid=$!
for _ in {1..100}; do
  grep -qx 'false' "$first_log" 2>/dev/null && break
  sleep 0.02
done
run_confirm 0 >"$second_log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

result_total="$(awk '/^(false|true)$/{count++} END{print count+0}' \
  "$first_log" "$second_log")"
result_false="$(awk '/^false$/{count++} END{print count+0}' \
  "$first_log" "$second_log")"
result_true="$(awk '/^true$/{count++} END{print count+0}' \
  "$first_log" "$second_log")"
if [[ "$result_total" -ne 2 ]] \
  || [[ "$result_false" -ne 1 ]] \
  || [[ "$result_true" -ne 1 ]]; then
  echo "De bevestigingsrace leverde niet exact één mutatie en één idempotente retry op." >&2
  exit 1
fi

final_state="$("${psql_cmd[@]}" \
  -v proposal_id="$proposal_id" \
  -v allocation_event_id="$allocation_event_id" \
  -v request_id="$request_id" \
  -v staff_id="$staff_id" <<'SQL'
select concat_ws(
    '|',
    (
      select count(*)
      from app.inventory_delivery_notification_proposals proposal
      where proposal.id = :'proposal_id'::uuid
        and proposal.status = 'confirmed'
        and proposal.selected_count = 1
        and proposal.eligible_count = 1
        and proposal.skipped_count = 0
        and proposal.blocked_count = 0
        and proposal.event_count = 1
        and proposal.parent_group_count = 1
    ),
    (
      select count(*)
      from app.inventory_delivery_notification_items item
      where item.proposal_id = :'proposal_id'::uuid
        and item.decision = 'enqueued'
        and item.event_count = 1
    ),
    (
      select count(*)
      from private.inventory_command_requests request
      where request.request_id = :'request_id'::uuid
        and request.command_type =
          'inventory.delivery.notification.confirm'
    ),
    (
      select count(*)
      from private.mail_v2_domain_events event
      where event.source_type = 'inventory_allocation_event'
        and event.source_id = :'allocation_event_id'::uuid
        and event.cohort_id = :'proposal_id'::uuid
    ),
    (
      select count(*)
      from app.audit_logs audit
      where audit.actor_user_id = :'staff_id'::uuid
        and audit.action =
          'inventory.delivery_notification.confirmed'
        and audit.entity_id = :'proposal_id'::uuid
    )
  );
SQL
)"
if [[ "$final_state" != "1|1|1|1|1" ]]; then
  echo "De leveringnotificatie-ledger is na de race niet exact-once: $final_state" >&2
  exit 1
fi

echo "Leveringnotificatieconcurrency groen: geen auto-event, één bevestiging, één eventset en één idempotente retry."
