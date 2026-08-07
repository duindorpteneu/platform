#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De mailcampagne-concurrencytest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
mkdir -p .tmp
test_tmp_dir="$(mktemp -d -p .tmp duindorp-mail-campaign.XXXXXX)"
first_log="$test_tmp_dir/confirm-1.log"
second_log="$test_tmp_dir/confirm-2.log"
second_retry_log="$test_tmp_dir/confirm-2-retry.log"
first_marker="$test_tmp_dir/confirm-1-holding"
dynamic_writer_log="$test_tmp_dir/dynamic-writer.log"
dynamic_campaign_log="$test_tmp_dir/dynamic-campaign.log"
dynamic_marker="$test_tmp_dir/dynamic-writer-holding"
allocator_writer_log="$test_tmp_dir/allocator-writer.log"
allocator_campaign_log="$test_tmp_dir/allocator-campaign.log"
allocator_marker="$test_tmp_dir/allocator-writer-holding"
payment_writer_log="$test_tmp_dir/payment-writer.log"
payment_campaign_log="$test_tmp_dir/payment-campaign.log"
payment_marker="$test_tmp_dir/payment-writer-holding"
reminder_first_log="$test_tmp_dir/reminder-first.log"
reminder_second_log="$test_tmp_dir/reminder-second.log"
previous_flag="$("${psql_cmd[@]}" -c \
  "select enabled::text from app.release_feature_flags where key='mail_templates_v2'")"
previous_cutover="$("${psql_cmd[@]}" -c \
  "select exists(select 1 from private.release_cutovers where key='mail_templates_v2')::text")"
created_template_revision="false"
created_reminder_template_revision="false"

cleanup_data() {
  "${psql_cmd[@]}" \
    -v previous_flag="$previous_flag" \
    -v previous_cutover="$previous_cutover" \
    -v created_template_revision="$created_template_revision" \
    -v created_reminder_template_revision="$created_reminder_template_revision" <<'SQL'
begin;
set local session_replication_role = replica;

create temporary table cleanup_mail_jobs as
select batch.email_job_id id
from private.mail_v2_projection_batches batch
where batch.cohort_id in (
  select cohort_id
  from private.mail_v2_campaign_runs
  where actor_user_id = 'ca000000-0000-4000-8000-000000000001'
)
  and batch.email_job_id is not null;
create temporary table cleanup_projection_batches as
select batch.id
from private.mail_v2_projection_batches batch
where batch.cohort_id in (
  select cohort_id
  from private.mail_v2_campaign_runs
  where actor_user_id = 'ca000000-0000-4000-8000-000000000001'
);

delete from private.mail_reminder_runs
where rule_id = 'ca850000-0000-4000-8000-000000000001';
delete from private.mail_reminder_rule_revisions
where rule_id = 'ca850000-0000-4000-8000-000000000001';
delete from app.mail_reminder_rules
where id = 'ca850000-0000-4000-8000-000000000001';
delete from private.mail_v2_episode_transitions
where episode_id in (
  select id
  from private.mail_v2_notification_episodes
  where parent_account_id = 'ca600000-0000-4000-8000-000000000001'
);
delete from private.mail_v2_episode_dispatches
where episode_id in (
  select id
  from private.mail_v2_notification_episodes
  where parent_account_id = 'ca600000-0000-4000-8000-000000000001'
);
delete from private.mail_v2_notification_episodes
where parent_account_id = 'ca600000-0000-4000-8000-000000000001';
delete from private.mail_v2_projections
where projection_batch_id in (
  select id
  from private.mail_v2_projection_batches
  where cohort_id in (
    select cohort_id
    from private.mail_v2_campaign_runs
    where actor_user_id = 'ca000000-0000-4000-8000-000000000001'
  )
);
delete from private.mail_v2_projection_batches
where cohort_id in (
  select cohort_id
  from private.mail_v2_campaign_runs
  where actor_user_id = 'ca000000-0000-4000-8000-000000000001'
);
delete from app.audit_logs
where action = 'mail_v2.domain.queued'
  and (metadata->>'projectionBatchId')::uuid in (
    select id from cleanup_projection_batches
  );
delete from private.mail_v2_domain_events
where source_type in ('mail_campaign', 'mail_reminder_rule')
  and member_season_id in (
    select id
    from app.member_seasons
    where member_id = 'ca300000-0000-4000-8000-000000000001'
  );
delete from private.mail_v2_campaign_runs
where actor_user_id = 'ca000000-0000-4000-8000-000000000001';
delete from private.email_jobs
where id in (select id from cleanup_mail_jobs);
delete from private.mail_v2_campaign_preflight_items
where preflight_id in (
  select id
  from private.mail_v2_campaign_preflights
  where actor_user_id = 'ca000000-0000-4000-8000-000000000001'
);
delete from private.mail_v2_campaign_preflights
where actor_user_id = 'ca000000-0000-4000-8000-000000000001';
delete from private.parent_portal_grants
where member_season_id in (
  select id
  from app.member_seasons
  where member_id = 'ca300000-0000-4000-8000-000000000001'
);
delete from private.parent_accounts
where id = 'ca600000-0000-4000-8000-000000000001';
delete from app.payments
where id = 'ca900000-0000-4000-8000-000000000001';
delete from app.order_lines
where order_id = 'ca400000-0000-4000-8000-000000000001';
delete from private.inventory_allocation_queue
where article_variant_id = 'ca200000-0000-4000-8000-000000000001';
delete from app.member_orders
where id = 'ca400000-0000-4000-8000-000000000001';
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id
  from app.order_package_snapshots
  where order_id = 'ca400000-0000-4000-8000-000000000001'
);
delete from app.order_package_snapshots
where order_id = 'ca400000-0000-4000-8000-000000000001';
delete from app.member_seasons
where member_id = 'ca300000-0000-4000-8000-000000000001';
delete from private.member_sensitive_identity
where member_id = 'ca300000-0000-4000-8000-000000000001';
delete from app.members
where id = 'ca300000-0000-4000-8000-000000000001';
delete from app.article_variants
where id = 'ca200000-0000-4000-8000-000000000001';
delete from app.article_seasons
where article_id = 'ca100000-0000-4000-8000-000000000001';
delete from app.articles
where id = 'ca100000-0000-4000-8000-000000000001';
delete from app.audit_logs
where actor_user_id = 'ca000000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'ca000000-0000-4000-8000-000000000001';
delete from app.mail_template_revisions
where id = 'ca700000-0000-4000-8000-000000000001'
  and :'created_template_revision'::boolean;
delete from app.mail_template_revisions
where id = 'ca700000-0000-4000-8000-000000000002'
  and :'created_reminder_template_revision'::boolean;

update app.release_feature_flags
set enabled = :'previous_flag'::boolean
where key = 'mail_templates_v2';
delete from private.release_cutovers
where key = 'mail_templates_v2'
  and not :'previous_cutover'::boolean;

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

if [[ "$("${psql_cmd[@]}" -c \
  "select count(*) from app.mail_template_revisions where template_key='payment_request' and status='published'")" == "0" ]]; then
  created_template_revision="true"
fi
if [[ "$("${psql_cmd[@]}" -c \
  "select count(*) from app.mail_template_revisions where template_key='payment_reminder' and status='published'")" == "0" ]]; then
  created_reminder_template_revision="true"
fi

"${psql_cmd[@]}" \
  -v create_revision="$created_template_revision" \
  -v create_reminder_revision="$created_reminder_template_revision" \
  >/dev/null <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'ca000000-0000-4000-8000-000000000001',
  'Mailcampagne race',
  'beheerder'
);
insert into app.articles(id, name, code, sort_order, active)
values (
  'ca100000-0000-4000-8000-000000000001',
  'Mailcampagneshirt',
  'MAIL-CAMPAIGN',
  741,
  true
);
insert into app.article_seasons(article_id, season_id)
select
  'ca100000-0000-4000-8000-000000000001',
  settings.active_season_id
from app.app_settings settings
where settings.id = true;
insert into app.article_variants(
  id,
  article_id,
  size,
  sku,
  sort_order,
  active
) values (
  'ca200000-0000-4000-8000-000000000001',
  'ca100000-0000-4000-8000-000000000001',
  'M',
  'MAIL-CAMPAIGN-M',
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
  'ca300000-0000-4000-8000-000000000001',
  'MAIL-CAMPAIGN-001',
  'Test',
  'Campagne',
  'mail-campaign-race@example.invalid',
  'TEST-1'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  'ca400000-0000-4000-8000-000000000001',
  'ca300000-0000-4000-8000-000000000001',
  settings.active_season_id,
  12500
from app.app_settings settings
where settings.id = true;
insert into app.order_lines(id, order_id, article_variant_id)
values (
  'ca500000-0000-4000-8000-000000000001',
  'ca400000-0000-4000-8000-000000000001',
  'ca200000-0000-4000-8000-000000000001'
);
insert into app.payments(
  id,
  order_id,
  method,
  status,
  amount_cents,
  idempotency_key
) values (
  'ca900000-0000-4000-8000-000000000001',
  'ca400000-0000-4000-8000-000000000001',
  'mollie',
  'open',
  12500,
  'mail-campaign-lock-order'
);
insert into private.parent_accounts(id, email_normalized)
values (
  'ca600000-0000-4000-8000-000000000001',
  'mail-campaign-race@example.invalid'
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
)
select
  'ca610000-0000-4000-8000-000000000001',
  orders.member_season_id,
  'mail-campaign-race@example.invalid',
  'ca600000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  'ca000000-0000-4000-8000-000000000001',
  timezone('utc', now())
from app.member_orders orders
where orders.id = 'ca400000-0000-4000-8000-000000000001';

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
  schema_version,
  content_hash,
  creation_source,
  published_at
)
select
  'ca700000-0000-4000-8000-000000000001',
  draft.template_key,
  999,
  'published',
  draft.internal_name,
  draft.subject_source,
  draft.preheader_source,
  draft.body_tiptap,
  '<p>Veilige campagneconcurrencytemplate</p>',
  draft.text_fallback_source,
  draft.schema_version,
  repeat('a', 64),
  'system',
  timezone('utc', now())
from app.mail_template_revisions draft
where draft.template_key = 'payment_request'
  and draft.status = 'draft'
  and :'create_revision'::boolean;

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
  schema_version,
  content_hash,
  creation_source,
  published_at
)
select
  'ca700000-0000-4000-8000-000000000002',
  draft.template_key,
  999,
  'published',
  draft.internal_name,
  draft.subject_source,
  draft.preheader_source,
  draft.body_tiptap,
  '<p>Veilige reminderconcurrencytemplate</p>',
  draft.text_fallback_source,
  draft.schema_version,
  repeat('b', 64),
  'system',
  timezone('utc', now())
from app.mail_template_revisions draft
where draft.template_key = 'payment_reminder'
  and draft.status = 'draft'
  and :'create_reminder_revision'::boolean;

insert into private.release_cutovers(key, activated_at)
values ('mail_templates_v2', timezone('utc', now()) - interval '1 minute')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

select set_config('app.mail_reminder_rule_internal', 'on', true);
insert into app.mail_reminder_rules(
  id,
  season_id,
  template_key,
  internal_name,
  first_delay_hours,
  frequency_hours,
  maximum_dispatches,
  cooldown_hours,
  end_at,
  quiet_start,
  quiet_end,
  active,
  created_by,
  updated_by
)
select
  'ca850000-0000-4000-8000-000000000001',
  settings.active_season_id,
  'payment_reminder',
  'Reminder concurrency',
  1,
  24,
  3,
  1,
  timestamptz '2099-08-31 22:00:00+00',
  time '23:00',
  time '06:00',
  true,
  'ca000000-0000-4000-8000-000000000001',
  'ca000000-0000-4000-8000-000000000001'
from app.app_settings settings
where settings.id = true;
select set_config('app.mail_reminder_rule_internal', 'off', true);

begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"ca000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array['ca400000-0000-4000-8000-000000000001'::uuid],
  'ca800000-0000-4000-8000-000000000001'
);
select app.preview_mail_v2_campaign_v1(
  'payment_request',
  array['ca400000-0000-4000-8000-000000000001'::uuid],
  'ca800000-0000-4000-8000-000000000004'
);
reset role;
commit;
SQL

preflight_id="$("${psql_cmd[@]}" -c \
  "select id from private.mail_v2_campaign_preflights where request_id='ca800000-0000-4000-8000-000000000001'")"
eligibility_revision="$("${psql_cmd[@]}" -c \
  "select eligibility_revision from private.mail_v2_campaign_preflights where id='$preflight_id'")"
second_preflight_id="$("${psql_cmd[@]}" -c \
  "select id from private.mail_v2_campaign_preflights where request_id='ca800000-0000-4000-8000-000000000004'")"
second_eligibility_revision="$("${psql_cmd[@]}" -c \
  "select eligibility_revision from private.mail_v2_campaign_preflights where id='$second_preflight_id'")"

"${psql_cmd[@]}" >"$dynamic_writer_log" 2>&1 <<SQL &
begin;
select pg_advisory_xact_lock(
  hashtextextended(
    'dynamic-import-member:ca300000-0000-4000-8000-000000000001',
    0
  )
);
select pg_advisory_xact_lock(
  hashtextextended(
    'dynamic-import-member-season:' || orders.member_season_id::text,
    0
  )
)
from app.member_orders orders
where orders.id = 'ca400000-0000-4000-8000-000000000001';
\! touch "$dynamic_marker"
select pg_sleep(0.5);
select private.lock_inventory_mutation();
commit;
SQL
dynamic_writer_pid=$!

for _attempt in {1..100}; do
  if [[ -f "$dynamic_marker" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -f "$dynamic_marker" ]]; then
  echo "De gesimuleerde uitgiftewriter verkreeg de lidlocks niet tijdig." >&2
  exit 1
fi

"${psql_cmd[@]}" >"$dynamic_campaign_log" 2>&1 <<'SQL' &
begin;
select private.lock_mail_v2_campaign_state(
  'payment_request',
  array['ca400000-0000-4000-8000-000000000001'::uuid],
  false
);
commit;
SQL
dynamic_campaign_pid=$!

dynamic_writer_status=0
dynamic_campaign_status=0
wait "$dynamic_writer_pid" || dynamic_writer_status=$?
wait "$dynamic_campaign_pid" || dynamic_campaign_status=$?
if [[ "$dynamic_writer_status" -ne 0 || "$dynamic_campaign_status" -eq 0 ]]; then
  echo "De campagne gaf niet veilig voorrang aan de uitgiftewriter." >&2
  sed -n '1,120p' "$dynamic_writer_log" >&2
  sed -n '1,120p' "$dynamic_campaign_log" >&2
  exit 1
fi
if ! grep -q 'MAIL_V2_CAMPAIGN_STATE_BUSY' "$dynamic_campaign_log" \
  || grep -Eqi 'deadlock detected|40P01' "$dynamic_campaign_log"; then
  echo "De uitgifte-lockrace eindigde niet als veilige serialisatieretry." >&2
  sed -n '1,120p' "$dynamic_campaign_log" >&2
  exit 1
fi

"${psql_cmd[@]}" >"$allocator_writer_log" 2>&1 <<SQL &
begin;
select private.lock_inventory_mutation();
select id
from app.order_lines
where id = 'ca500000-0000-4000-8000-000000000001'
for update;
\! touch "$allocator_marker"
select pg_sleep(0.5);
select pg_advisory_xact_lock(
  hashtextextended(
    'dynamic-import-member:ca300000-0000-4000-8000-000000000001',
    0
  )
);
select pg_advisory_xact_lock(
  hashtextextended(
    'dynamic-import-member-season:' || orders.member_season_id::text,
    0
  )
)
from app.member_orders orders
where orders.id = 'ca400000-0000-4000-8000-000000000001';
commit;
SQL
allocator_writer_pid=$!

for _attempt in {1..100}; do
  if [[ -f "$allocator_marker" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -f "$allocator_marker" ]]; then
  echo "De gesimuleerde allocator verkreeg voorraad- en regel-locks niet tijdig." >&2
  exit 1
fi

"${psql_cmd[@]}" >"$allocator_campaign_log" 2>&1 <<'SQL' &
begin;
select private.lock_mail_v2_campaign_state(
  'payment_request',
  array['ca400000-0000-4000-8000-000000000001'::uuid],
  false
);
commit;
SQL
allocator_campaign_pid=$!

allocator_writer_status=0
allocator_campaign_status=0
wait "$allocator_writer_pid" || allocator_writer_status=$?
wait "$allocator_campaign_pid" || allocator_campaign_status=$?
if [[ "$allocator_writer_status" -ne 0 || "$allocator_campaign_status" -eq 0 ]]; then
  echo "De campagne gaf niet veilig voorrang aan de allocator." >&2
  sed -n '1,120p' "$allocator_writer_log" >&2
  sed -n '1,120p' "$allocator_campaign_log" >&2
  exit 1
fi
if ! grep -q 'MAIL_V2_CAMPAIGN_STATE_BUSY' "$allocator_campaign_log" \
  || grep -Eqi 'deadlock detected|40P01' "$allocator_campaign_log"; then
  echo "De allocator-lockrace eindigde niet als veilige serialisatieretry." >&2
  sed -n '1,120p' "$allocator_campaign_log" >&2
  exit 1
fi

"${psql_cmd[@]}" >"$payment_writer_log" 2>&1 <<SQL &
begin;
select id
from app.payments
where id = 'ca900000-0000-4000-8000-000000000001'
for update;
\! touch "$payment_marker"
select pg_sleep(0.5);
select private.lock_inventory_mutation();
select id
from app.order_lines
where id = 'ca500000-0000-4000-8000-000000000001'
for update;
commit;
SQL
payment_writer_pid=$!

for _attempt in {1..100}; do
  if [[ -f "$payment_marker" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -f "$payment_marker" ]]; then
  echo "De gesimuleerde betaalwriter verkreeg de betaalrij niet tijdig." >&2
  exit 1
fi

"${psql_cmd[@]}" >"$payment_campaign_log" 2>&1 <<'SQL' &
begin;
select private.lock_mail_v2_campaign_state(
  'payment_request',
  array['ca400000-0000-4000-8000-000000000001'::uuid],
  false
);
commit;
SQL
payment_campaign_pid=$!

payment_writer_status=0
payment_campaign_status=0
wait "$payment_writer_pid" || payment_writer_status=$?
wait "$payment_campaign_pid" || payment_campaign_status=$?
if [[ "$payment_writer_status" -ne 0 || "$payment_campaign_status" -eq 0 ]]; then
  echo "De campagne gaf niet veilig voorrang aan de betaalwriter." >&2
  sed -n '1,120p' "$payment_writer_log" >&2
  sed -n '1,120p' "$payment_campaign_log" >&2
  exit 1
fi
if ! grep -q 'MAIL_V2_CAMPAIGN_STATE_BUSY' "$payment_campaign_log" \
  || grep -Eqi 'deadlock detected|40P01' "$payment_campaign_log"; then
  echo "De betaal-lockrace eindigde niet als veilige serialisatieretry." >&2
  sed -n '1,120p' "$payment_campaign_log" >&2
  exit 1
fi

"${psql_cmd[@]}" \
  -v preflight_id="$preflight_id" \
  -v eligibility_revision="$eligibility_revision" \
  >"$first_log" 2>&1 <<SQL &
begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"ca000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select app.confirm_mail_v2_campaign_v1(
  :'preflight_id'::uuid,
  :'eligibility_revision',
  'ca800000-0000-4000-8000-000000000002',
  null
);
\! touch "$first_marker"
select pg_sleep(2);
commit;
SQL
first_pid=$!

for _attempt in {1..100}; do
  if [[ -f "$first_marker" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -f "$first_marker" ]]; then
  echo "De eerste campagneconfirm verkreeg de preflightlock niet tijdig." >&2
  exit 1
fi

"${psql_cmd[@]}" \
  -v preflight_id="$second_preflight_id" \
  -v eligibility_revision="$second_eligibility_revision" \
  >"$second_log" 2>&1 <<'SQL' &
begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"ca000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select app.confirm_mail_v2_campaign_v1(
  :'preflight_id'::uuid,
  :'eligibility_revision',
  'ca800000-0000-4000-8000-000000000003',
  null
);
commit;
SQL
second_pid=$!

first_status=0
second_status=0
wait "$first_pid" || first_status=$?
wait "$second_pid" || second_status=$?
if [[ "$first_status" -ne 0 || "$second_status" -eq 0 ]]; then
  echo "De episode-race had niet exact één succesvolle confirm." >&2
  sed -n '1,120p' "$first_log" >&2
  sed -n '1,120p' "$second_log" >&2
  exit 1
fi

if ! grep -q '"reused": false' "$first_log"; then
  echo "De eerste confirm leverde geen nieuwe run op." >&2
  exit 1
fi
if ! grep -q 'MAIL_V2_CAMPAIGN_STATE_BUSY' "$second_log" \
  || grep -Eqi 'deadlock detected|40P01' "$second_log"; then
  echo "De gelijktijdige tweede preflight leverde geen veilige retry op." >&2
  exit 1
fi

second_retry_status=0
"${psql_cmd[@]}" \
  -v preflight_id="$second_preflight_id" \
  -v eligibility_revision="$second_eligibility_revision" \
  >"$second_retry_log" 2>&1 <<'SQL' || second_retry_status=$?
begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"ca000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select app.confirm_mail_v2_campaign_v1(
  :'preflight_id'::uuid,
  :'eligibility_revision',
  'ca800000-0000-4000-8000-000000000006',
  null
);
commit;
SQL
if [[ "$second_retry_status" -eq 0 ]] \
  || ! grep -q 'MAIL_V2_CAMPAIGN_ELIGIBILITY_CHANGED' "$second_retry_log"; then
  echo "De retry van de tweede preflight zag de gewijzigde episode niet." >&2
  sed -n '1,120p' "$second_retry_log" >&2
  exit 1
fi

reused_result="$("${psql_cmd[@]}" \
  -v preflight_id="$preflight_id" \
  -v eligibility_revision="$eligibility_revision" <<'SQL'
begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"ca000000-0000-4000-8000-000000000001","aal":"aal2"}',
  true
);
set local role authenticated;
select app.confirm_mail_v2_campaign_v1(
  :'preflight_id'::uuid,
  :'eligibility_revision',
  'ca800000-0000-4000-8000-000000000003',
  null
);
commit;
SQL
)"
if ! grep -q '"reused": true' <<<"$reused_result"; then
  echo "Een tweede confirm van dezelfde preflight hergebruikte de run niet." >&2
  exit 1
fi

read -r run_count event_count batch_count episode_count dispatch_count \
  <<<"$("${psql_cmd[@]}" -F ' ' -c "
select
  (select count(*) from private.mail_v2_campaign_runs
    where preflight_id='$preflight_id'),
  (select count(*) from private.mail_v2_domain_events
    where source_type='mail_campaign'
      and member_season_id in (
        select id from app.member_seasons
        where member_id='ca300000-0000-4000-8000-000000000001'
      )),
  (select count(*) from private.mail_v2_projection_batches
    where cohort_id in (
      select cohort_id from private.mail_v2_campaign_runs
      where preflight_id='$preflight_id'
    )),
  (select count(*) from private.mail_v2_notification_episodes
    where process_key='payment'
      and parent_account_id='ca600000-0000-4000-8000-000000000001'
      and scope_id='ca400000-0000-4000-8000-000000000001'
      and status='open'),
  (select count(*) from private.mail_v2_episode_dispatches dispatch
    join private.mail_v2_notification_episodes episode
      on episode.id=dispatch.episode_id
    where episode.process_key='payment'
      and episode.parent_account_id='ca600000-0000-4000-8000-000000000001'
      and episode.scope_id='ca400000-0000-4000-8000-000000000001');
")"
if [[ "$run_count" != "1" || "$event_count" != "1" \
  || "$batch_count" != "1" || "$episode_count" != "1" \
  || "$dispatch_count" != "1" ]]; then
  echo "De confirmrace schreef niet exact één run, event, episodebinding en projectiebatch." >&2
  exit 1
fi

"${psql_cmd[@]}" >/dev/null <<'SQL'
begin;
set local role service_role;
create temporary table reminder_initial_claim as
select app.claim_mail_v2_domain_projections_v1(
  'ca860000-0000-4000-8000-000000000001',
  10
) result;
reset role;
create temporary table reminder_initial_hash as
select private.mail_v2_render_hash(
  (
    select (result #>> '{groups,0,groupId}')::uuid
    from reminder_initial_claim
  ),
  (
    select result #>> '{groups,0,eligibilityRevision}'
    from reminder_initial_claim
  ),
  (
    select (result #>> '{groups,0,template,id}')::uuid
    from reminder_initial_claim
  ),
  (
    select (result #>> '{groups,0,branding,id}')::uuid
    from reminder_initial_claim
  ),
  'Betaalverzoek',
  'Betaal het vaste pakketbedrag.',
  '<p>Betaal het vaste pakketbedrag.</p>',
  'Betaal het vaste pakketbedrag.'
) render_hash;
grant select on reminder_initial_claim, reminder_initial_hash to service_role;
set local role service_role;
create temporary table reminder_initial_finalize as
select app.finalize_mail_v2_domain_projection_v1(
  (
    select (result #>> '{groups,0,groupId}')::uuid
    from reminder_initial_claim
  ),
  (
    select (result->>'leaseToken')::uuid
    from reminder_initial_claim
  ),
  (
    select result #>> '{groups,0,eligibilityRevision}'
    from reminder_initial_claim
  ),
  'Betaalverzoek',
  'Betaal het vaste pakketbedrag.',
  '<p>Betaal het vaste pakketbedrag.</p>',
  'Betaal het vaste pakketbedrag.',
  (select render_hash from reminder_initial_hash)
) result;
reset role;
update private.email_jobs
set status = 'sent',
    sent_at = (
      date_trunc(
        'day',
        statement_timestamp() at time zone 'Europe/Amsterdam'
      ) + interval '10 hours'
    ) at time zone 'Europe/Amsterdam',
    completed_at = (
      date_trunc(
        'day',
        statement_timestamp() at time zone 'Europe/Amsterdam'
      ) + interval '10 hours'
    ) at time zone 'Europe/Amsterdam',
    updated_at = statement_timestamp()
where id = (
  select (result->>'jobId')::uuid
  from reminder_initial_finalize
);
commit;
SQL

"${psql_cmd[@]}" >"$reminder_first_log" 2>&1 <<'SQL' &
begin;
select pg_advisory_xact_lock(
  hashtextextended(
    'mail-reminder-rule:ca850000-0000-4000-8000-000000000001',
    0
  )
);
set local role service_role;
select app.run_due_mail_reminders_v1(
  (
    date_trunc(
      'day',
      statement_timestamp() at time zone 'Europe/Amsterdam'
    ) + interval '12 hours'
  ) at time zone 'Europe/Amsterdam',
  100
);
reset role;
select pg_sleep(1);
commit;
SQL
reminder_first_pid=$!
sleep 0.2
"${psql_cmd[@]}" >"$reminder_second_log" 2>&1 <<'SQL' &
begin;
set local role service_role;
select app.run_due_mail_reminders_v1(
  (
    date_trunc(
      'day',
      statement_timestamp() at time zone 'Europe/Amsterdam'
    ) + interval '12 hours'
  ) at time zone 'Europe/Amsterdam',
  100
);
commit;
SQL
reminder_second_pid=$!

reminder_first_status=0
reminder_second_status=0
wait "$reminder_first_pid" || reminder_first_status=$?
wait "$reminder_second_pid" || reminder_second_status=$?
if [[ "$reminder_first_status" -ne 0 || "$reminder_second_status" -ne 0 ]]; then
  echo "De herinneringsplannerrace kon niet veilig worden voltooid." >&2
  sed -n '1,120p' "$reminder_first_log" >&2
  sed -n '1,120p' "$reminder_second_log" >&2
  exit 1
fi

read -r reminder_event_count reminder_dispatch_count reminder_run_count \
  reminder_failure_count <<<"$("${psql_cmd[@]}" -F ' ' -c "
select
  (select count(*) from private.mail_v2_domain_events
    where source_type='mail_reminder_rule'
      and source_id='ca850000-0000-4000-8000-000000000001'),
  (select coalesce(sum(dispatched_count), 0)
    from private.mail_reminder_runs
    where rule_id='ca850000-0000-4000-8000-000000000001'),
  (select count(*) from private.mail_reminder_runs
    where rule_id='ca850000-0000-4000-8000-000000000001'),
  (select count(*) from private.mail_reminder_runs
    where rule_id='ca850000-0000-4000-8000-000000000001'
      and status='failed');
")"
if [[ "$reminder_event_count" != "1" \
  || "$reminder_dispatch_count" != "1" \
  || "$reminder_run_count" != "2" \
  || "$reminder_failure_count" != "0" ]]; then
  echo "Twee gelijktijdige planners produceerden niet exact één herinnering: events=$reminder_event_count dispatches=$reminder_dispatch_count runs=$reminder_run_count failures=$reminder_failure_count." >&2
  sed -n '1,120p' "$reminder_first_log" >&2
  sed -n '1,120p' "$reminder_second_log" >&2
  exit 1
fi

echo "Mailcampagne- en reminderconcurrency geslaagd: lockordes geven veilige retries en twee planners produceren exact één verschuldigd reminder-event."
