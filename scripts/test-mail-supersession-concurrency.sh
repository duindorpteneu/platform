#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De mailsupersession-racetest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
mkdir -p .tmp
test_tmp_dir="$(mktemp -d .tmp/mail-supersession.XXXXXX)"
release_marker="$test_tmp_dir/release-holding"
bounce_marker="$test_tmp_dir/bounce-holding"
release_log="$test_tmp_dir/release.log"
bounce_log="$test_tmp_dir/bounce.log"
previous_flag="$("${psql_cmd[@]}" -c \
  "select enabled::text from app.release_feature_flags where key='mail_templates_v2'")"
previous_cutover="$("${psql_cmd[@]}" -c \
  "select exists(select 1 from private.release_cutovers where key='mail_templates_v2')::text")"

cleanup_data() {
  "${psql_cmd[@]}" \
    -v previous_flag="$previous_flag" \
    -v previous_cutover="$previous_cutover" >/dev/null <<'SQL'
begin;
set local session_replication_role = replica;

delete from private.mail_v2_event_suppressions
where event_id in (
  select id from private.mail_v2_domain_events
  where season_id = 'f8100000-0000-4000-8000-000000000001'
);
delete from private.mail_v2_projections
where projection_batch_id in (
  select id from private.mail_v2_projection_batches
  where season_id = 'f8100000-0000-4000-8000-000000000001'
);
delete from private.mail_v2_projection_batches
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from private.mail_v2_domain_events
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from app.email_events
where email_job_id in (
  select id from private.email_jobs
  where season_id = 'f8100000-0000-4000-8000-000000000001'
);
delete from private.email_jobs
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from app.action_items
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from app.inventory_allocation_events
where allocation_id in (
  select id from app.inventory_allocations
  where season_id = 'f8100000-0000-4000-8000-000000000001'
);
delete from app.inventory_allocations
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from app.member_article_sizes
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from private.parent_portal_grants
where member_season_id in (
  select id from app.member_seasons
  where season_id = 'f8100000-0000-4000-8000-000000000001'
);
delete from private.parent_accounts
where id = 'f8200000-0000-4000-8000-000000000001';
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id from app.order_package_snapshots
  where order_id = 'f8300000-0000-4000-8000-000000000001'
);
delete from app.order_package_snapshots
where order_id = 'f8300000-0000-4000-8000-000000000001';
delete from app.order_lines
where order_id = 'f8300000-0000-4000-8000-000000000001';
delete from app.member_orders
where id = 'f8300000-0000-4000-8000-000000000001';
delete from app.member_seasons
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from private.member_sensitive_identity
where member_id = 'f8400000-0000-4000-8000-000000000001';
delete from app.members
where id = 'f8400000-0000-4000-8000-000000000001';
delete from app.article_seasons
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from app.article_variants
where article_id in (
  'f8500000-0000-4000-8000-000000000001',
  'f8500000-0000-4000-8000-000000000002'
);
delete from app.articles
where id in (
  'f8500000-0000-4000-8000-000000000001',
  'f8500000-0000-4000-8000-000000000002'
);
delete from app.inventory_settings
where season_id = 'f8100000-0000-4000-8000-000000000001';
delete from app.seasons
where id = 'f8100000-0000-4000-8000-000000000001';
delete from app.audit_logs
where actor_user_id = 'f8000000-0000-4000-8000-000000000001'
  or entity_id in (
    'f8600000-0000-4000-8000-000000000001',
    'f8600000-0000-4000-8000-000000000002'
  );
delete from app.staff_profiles
where auth_user_id = 'f8000000-0000-4000-8000-000000000001';

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
  cleanup_data || status=1
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT

cleanup_data

"${psql_cmd[@]}" >/dev/null <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  'f8000000-0000-4000-8000-000000000001',
  'Mailsupersession race',
  'beheerder'
);
insert into app.seasons(id, name, default_amount_cents, status)
values(
  'f8100000-0000-4000-8000-000000000001',
  'Mailsupersession concurrency',
  10000,
  'open'
);
insert into app.articles(id, name, code, sort_order, active) values
  (
    'f8500000-0000-4000-8000-000000000001',
    'Release-raceshirt',
    'MAIL-RACE-RELEASE',
    851,
    true
  ),
  (
    'f8500000-0000-4000-8000-000000000002',
    'Bounce-raceshirt',
    'MAIL-RACE-BOUNCE',
    852,
    true
  );
insert into app.article_seasons(article_id, season_id) values
  (
    'f8500000-0000-4000-8000-000000000001',
    'f8100000-0000-4000-8000-000000000001'
  ),
  (
    'f8500000-0000-4000-8000-000000000002',
    'f8100000-0000-4000-8000-000000000001'
  );
insert into app.article_variants(
  id, article_id, size, sku, sort_order, active
) values
  (
    'f8510000-0000-4000-8000-000000000001',
    'f8500000-0000-4000-8000-000000000001',
    'M',
    'MAIL-RACE-RELEASE-M',
    1,
    true
  ),
  (
    'f8510000-0000-4000-8000-000000000002',
    'f8500000-0000-4000-8000-000000000002',
    'M',
    'MAIL-RACE-BOUNCE-M',
    1,
    true
  );
insert into app.members(
  id, relation_number, first_name, last_name, email, team
) values (
  'f8400000-0000-4000-8000-000000000001',
  'MAIL-SUPER-RACE',
  'Race',
  'Voorwaarde',
  'mail-supersession-race@example.invalid',
  'TEST-1'
);
insert into app.member_orders(id, member_id, season_id, amount_due_cents)
values(
  'f8300000-0000-4000-8000-000000000001',
  'f8400000-0000-4000-8000-000000000001',
  'f8100000-0000-4000-8000-000000000001',
  10000
);
insert into app.order_lines(id, order_id, article_variant_id) values
  (
    'f8310000-0000-4000-8000-000000000001',
    'f8300000-0000-4000-8000-000000000001',
    'f8510000-0000-4000-8000-000000000001'
  ),
  (
    'f8310000-0000-4000-8000-000000000002',
    'f8300000-0000-4000-8000-000000000001',
    'f8510000-0000-4000-8000-000000000002'
  );
update app.order_lines
set status = 'ready_for_pickup'
where id = 'f8310000-0000-4000-8000-000000000001';
insert into private.parent_accounts(id, email_normalized)
values(
  'f8200000-0000-4000-8000-000000000001',
  'mail-supersession-race@example.invalid'
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
  'f8210000-0000-4000-8000-000000000001',
  orders.member_season_id,
  'mail-supersession-race@example.invalid',
  'f8200000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  'f8000000-0000-4000-8000-000000000001',
  statement_timestamp()
from app.member_orders orders
where orders.id = 'f8300000-0000-4000-8000-000000000001';

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
  allocated_at
)
select
  fixture.allocation_id,
  orders.season_id,
  orders.member_id,
  orders.member_season_id,
  orders.id,
  fixture.order_line_id,
  fixture.article_id,
  fixture.variant_id,
  1,
  'reserved',
  'resolved',
  'fifo',
  statement_timestamp() - interval '2 hours',
  statement_timestamp() - interval '1 hour',
  statement_timestamp() - interval '1 hour',
  fixture.product_name,
  'M',
  statement_timestamp() - interval '30 minutes'
from (
  values
    (
      'f8520000-0000-4000-8000-000000000001'::uuid,
      'f8310000-0000-4000-8000-000000000001'::uuid,
      'f8500000-0000-4000-8000-000000000001'::uuid,
      'f8510000-0000-4000-8000-000000000001'::uuid,
      'Release-raceshirt'::text
    ),
    (
      'f8520000-0000-4000-8000-000000000002'::uuid,
      'f8310000-0000-4000-8000-000000000002'::uuid,
      'f8500000-0000-4000-8000-000000000002'::uuid,
      'f8510000-0000-4000-8000-000000000002'::uuid,
      'Bounce-raceshirt'::text
    )
) fixture(
  allocation_id,
  order_line_id,
  article_id,
  variant_id,
  product_name
)
cross join app.member_orders orders
where orders.id = 'f8300000-0000-4000-8000-000000000001';

alter table app.inventory_allocation_events
  disable trigger inventory_allocation_events_mail_v2;
insert into app.inventory_allocation_events(
  id,
  allocation_id,
  event_type,
  next_status,
  reason_code,
  source_type,
  source_id,
  idempotency_key,
  safe_context
) values
  (
    'f8530000-0000-4000-8000-000000000001',
    'f8520000-0000-4000-8000-000000000001',
    'reserved',
    'reserved',
    'mail_supersession.reserved',
    'mail_supersession_test',
    'f8000000-0000-4000-8000-000000000001',
    repeat('8', 64),
    '{}'::jsonb
  ),
  (
    'f8530000-0000-4000-8000-000000000002',
    'f8520000-0000-4000-8000-000000000002',
    'reserved',
    'reserved',
    'mail_supersession.reserved',
    'mail_supersession_test',
    'f8000000-0000-4000-8000-000000000001',
    repeat('9', 64),
    '{}'::jsonb
  );
alter table app.inventory_allocation_events
  enable trigger inventory_allocation_events_mail_v2;

insert into private.mail_v2_domain_events(
  id,
  template_key,
  parent_account_id,
  season_id,
  member_season_id,
  order_id,
  order_line_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key,
  payload_snapshot
)
select
  fixture.event_id,
  fixture.template_key,
  'f8200000-0000-4000-8000-000000000001',
  orders.season_id,
  orders.member_season_id,
  orders.id,
  fixture.order_line_id,
  fixture.source_type,
  fixture.source_id,
  fixture.cohort_id,
  fixture.idempotency_key,
  '{}'::jsonb
from (
  values
    (
      'f8540000-0000-4000-8000-000000000001'::uuid,
      'pickup_ready'::text,
      'f8310000-0000-4000-8000-000000000001'::uuid,
      'inventory_allocation_event'::text,
      'f8530000-0000-4000-8000-000000000001'::uuid,
      'f8550000-0000-4000-8000-000000000001'::uuid,
      'mail-supersession:pickup:release'::text
    ),
    (
      'f8540000-0000-4000-8000-000000000002'::uuid,
      'out_of_stock'::text,
      'f8310000-0000-4000-8000-000000000001'::uuid,
      'mail_campaign'::text,
      'f8560000-0000-4000-8000-000000000001'::uuid,
      'f8550000-0000-4000-8000-000000000001'::uuid,
      'mail-supersession:oos:release'::text
    ),
    (
      'f8540000-0000-4000-8000-000000000003'::uuid,
      'pickup_ready'::text,
      'f8310000-0000-4000-8000-000000000002'::uuid,
      'inventory_allocation_event'::text,
      'f8530000-0000-4000-8000-000000000002'::uuid,
      'f8550000-0000-4000-8000-000000000002'::uuid,
      'mail-supersession:pickup:bounce'::text
    ),
    (
      'f8540000-0000-4000-8000-000000000004'::uuid,
      'out_of_stock'::text,
      'f8310000-0000-4000-8000-000000000002'::uuid,
      'mail_campaign'::text,
      'f8560000-0000-4000-8000-000000000002'::uuid,
      'f8550000-0000-4000-8000-000000000002'::uuid,
      'mail-supersession:oos:bounce'::text
    )
) fixture(
  event_id,
  template_key,
  order_line_id,
  source_type,
  source_id,
  cohort_id,
  idempotency_key
)
cross join app.member_orders orders
where orders.id = 'f8300000-0000-4000-8000-000000000001';

alter table private.email_jobs disable trigger email_jobs_guard_snapshot;
insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  payload,
  status,
  attempts,
  available_at,
  sent_at,
  idempotency_key,
  completed_at,
  context_kind,
  parent_account_id,
  season_id,
  mail_template_revision_id,
  mail_branding_revision_id,
  rendered_subject_snapshot,
  rendered_preheader_snapshot,
  rendered_html_snapshot,
  rendered_text_snapshot,
  from_name_snapshot,
  from_email_snapshot,
  reply_to_email_snapshot,
  render_hash
)
select
  fixture.job_id,
  'bulk',
  'mail-supersession-race@example.invalid',
  'out_of_stock',
  '{"schemaVersion":1,"eventCount":1}'::jsonb,
  'sent',
  1,
  statement_timestamp() - interval '1 hour',
  statement_timestamp() - interval '30 minutes',
  fixture.idempotency_key,
  statement_timestamp() - interval '30 minutes',
  'mail_v2',
  'f8200000-0000-4000-8000-000000000001',
  'f8100000-0000-4000-8000-000000000001',
  revision.id,
  branding.id,
  'Tijdelijk niet leverbaar',
  'Voorraadbericht',
  '<p>Tijdelijk niet leverbaar.</p>',
  'Tijdelijk niet leverbaar.',
  branding.from_name,
  branding.from_email,
  branding.reply_to_email,
  fixture.render_hash
from (
  values
    (
      'f8600000-0000-4000-8000-000000000001'::uuid,
      'mail-supersession:oos-job:release'::text,
      repeat('6', 64)
    ),
    (
      'f8600000-0000-4000-8000-000000000002'::uuid,
      'mail-supersession:oos-job:bounce'::text,
      repeat('7', 64)
    )
) fixture(job_id, idempotency_key, render_hash)
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'out_of_stock'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id, from_name, from_email, reply_to_email
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding;
alter table private.email_jobs enable trigger email_jobs_guard_snapshot;

insert into private.mail_v2_projection_batches(
  id,
  parent_account_id,
  season_id,
  template_key,
  cohort_id,
  template_revision_id,
  branding_revision_id,
  status,
  email_job_id,
  event_count,
  eligible_event_count,
  eligibility_revision
)
select
  fixture.batch_id,
  'f8200000-0000-4000-8000-000000000001',
  'f8100000-0000-4000-8000-000000000001',
  'out_of_stock',
  fixture.cohort_id,
  revision.id,
  branding.id,
  'queued',
  fixture.job_id,
  1,
  1,
  fixture.eligibility_revision
from (
  values
    (
      'f8610000-0000-4000-8000-000000000001'::uuid,
      'f8550000-0000-4000-8000-000000000001'::uuid,
      'f8600000-0000-4000-8000-000000000001'::uuid,
      repeat('6', 64)
    ),
    (
      'f8610000-0000-4000-8000-000000000002'::uuid,
      'f8550000-0000-4000-8000-000000000002'::uuid,
      'f8600000-0000-4000-8000-000000000002'::uuid,
      repeat('7', 64)
    )
) fixture(batch_id, cohort_id, job_id, eligibility_revision)
cross join lateral (
  select id
  from app.mail_template_revisions
  where template_key = 'out_of_stock'
  order by revision desc
  limit 1
) revision
cross join lateral (
  select id
  from app.mail_branding_revisions
  where status = 'published'
  order by revision desc
  limit 1
) branding;
insert into private.mail_v2_projections(event_id, projection_batch_id)
values
  (
    'f8540000-0000-4000-8000-000000000002',
    'f8610000-0000-4000-8000-000000000001'
  ),
  (
    'f8540000-0000-4000-8000-000000000004',
    'f8610000-0000-4000-8000-000000000002'
  );

insert into private.release_cutovers(key, activated_at)
values('mail_templates_v2', statement_timestamp() - interval '1 hour')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';
SQL

wait_for_marker() {
  local marker="$1"
  local pid="$2"
  local log_file="$3"
  for _ in $(seq 1 100); do
    if [[ -f "$marker" ]]; then
      return
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done
  wait "$pid" || true
  sed -n '1,100p' "$log_file" >&2
  echo "De concurrencybarrière werd niet bereikt." >&2
  exit 1
}

hold_release() {
  "${psql_cmd[@]}" <<SQL
begin;
select id
from app.inventory_allocations
where id = 'f8520000-0000-4000-8000-000000000001'
for update;
\\! touch "$release_marker"
select pg_sleep(2);
select set_config('app.inventory_internal', 'on', true);
update app.inventory_allocations
set status = 'released',
    released_at = statement_timestamp(),
    release_reason = 'Concurrencytest vrijgave',
    updated_at = statement_timestamp()
where id = 'f8520000-0000-4000-8000-000000000001';
update app.order_lines
set status = 'backorder',
    updated_at = statement_timestamp()
where id = 'f8310000-0000-4000-8000-000000000001';
select set_config('app.inventory_internal', 'off', true);
commit;
SQL
}

hold_release >"$release_log" 2>&1 &
release_pid=$!
wait_for_marker "$release_marker" "$release_pid" "$release_log"
release_result="$(timeout 1s "${psql_cmd[@]}" -c \
  "select private.reconcile_mail_v2_event_supersessions()")"
if [[ "$release_result" != "0" ]]; then
  echo "Reconciliatie schreef tijdens een allocation-release: $release_result" >&2
  exit 1
fi
if ! wait "$release_pid"; then
  sed -n '1,120p' "$release_log" >&2
  echo "De allocation-releaseworker faalde." >&2
  exit 1
fi

release_state="$("${psql_cmd[@]}" -c "
  select concat_ws(
    ':',
    (
      select status
      from app.inventory_allocations
      where id = 'f8520000-0000-4000-8000-000000000001'
    ),
    (
      select count(*)
      from private.mail_v2_event_suppressions
      where event_id in (
        'f8540000-0000-4000-8000-000000000001',
        'f8540000-0000-4000-8000-000000000002'
      )
    ),
    (
      select count(*)
      from private.mail_v2_domain_events
      where template_key = 'back_in_stock'
        and order_line_id = 'f8310000-0000-4000-8000-000000000001'
    )
  )
")"
if [[ "$release_state" != "released:0:0" ]]; then
  echo "Onveilige allocation-release/race-uitkomst: $release_state" >&2
  exit 1
fi

"${psql_cmd[@]}" -c "
  update app.order_lines
  set status = 'ready_for_pickup',
      updated_at = statement_timestamp()
  where id = 'f8310000-0000-4000-8000-000000000002'
" >/dev/null

hold_bounce() {
  "${psql_cmd[@]}" <<SQL
begin;
select id
from private.email_jobs
where id = 'f8600000-0000-4000-8000-000000000002'
for update;
\\! touch "$bounce_marker"
select pg_sleep(2);
update private.email_jobs
set delivery_status = 'bounced',
    updated_at = statement_timestamp()
where id = 'f8600000-0000-4000-8000-000000000002';
commit;
SQL
}

hold_bounce >"$bounce_log" 2>&1 &
bounce_pid=$!
wait_for_marker "$bounce_marker" "$bounce_pid" "$bounce_log"
bounce_result="$(timeout 1s "${psql_cmd[@]}" -c \
  "select private.reconcile_mail_v2_event_supersessions()")"
if [[ "$bounce_result" != "0" ]]; then
  echo "Reconciliatie schreef tijdens een provider-bounce: $bounce_result" >&2
  exit 1
fi
if ! wait "$bounce_pid"; then
  sed -n '1,120p' "$bounce_log" >&2
  echo "De provider-bounceworker faalde." >&2
  exit 1
fi

bounce_state="$("${psql_cmd[@]}" -c "
  select concat_ws(
    ':',
    (
      select delivery_status
      from private.email_jobs
      where id = 'f8600000-0000-4000-8000-000000000002'
    ),
    (
      select count(*)
      from private.mail_v2_event_suppressions
      where event_id in (
        'f8540000-0000-4000-8000-000000000003',
        'f8540000-0000-4000-8000-000000000004'
      )
    ),
    (
      select count(*)
      from private.mail_v2_domain_events
      where template_key = 'back_in_stock'
        and order_line_id = 'f8310000-0000-4000-8000-000000000002'
    )
  )
")"
if [[ "$bounce_state" != "bounced:0:0" ]]; then
  echo "Onveilige provider-bounce/race-uitkomst: $bounce_state" >&2
  exit 1
fi

echo "Mailsupersession-concurrency geslaagd: release en provider-bounce winnen veilig zonder dubbele communicatie."
