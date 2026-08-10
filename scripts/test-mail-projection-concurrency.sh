#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De mailprojectie-concurrencytest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-mail-projection.XXXXXX)"
first_log="$test_tmp_dir/worker-1.log"
second_log="$test_tmp_dir/worker-2.log"
first_marker="$test_tmp_dir/worker-1-holding"
previous_flag="$("${psql_cmd[@]}" -c \
  "select enabled::text from app.release_feature_flags where key='mail_templates_v2'")"
previous_cutover="$("${psql_cmd[@]}" -c \
  "select exists(select 1 from private.release_cutovers where key='mail_templates_v2')::text")"
created_template_revision="false"

cleanup_data() {
  "${psql_cmd[@]}" \
    -v previous_flag="$previous_flag" \
    -v previous_cutover="$previous_cutover" \
    -v created_template_revision="$created_template_revision" <<'SQL'
begin;
set local session_replication_role = replica;

delete from private.fulfilment_mail_projections
where projection_batch_id in (
  select id
  from private.fulfilment_mail_projection_batches
  where season_id = 'f7100000-0000-4000-8000-000000000001'
);
delete from private.fulfilment_mail_projection_batches
where season_id = 'f7100000-0000-4000-8000-000000000001';
delete from private.fulfilment_notification_events
where season_id = 'f7100000-0000-4000-8000-000000000001';
delete from private.parent_portal_grants
where member_season_id in (
  select id
  from app.member_seasons
  where season_id = 'f7100000-0000-4000-8000-000000000001'
);
delete from private.parent_accounts
where id = 'f7400000-0000-4000-8000-000000000001';
delete from app.fulfilments
where season_id = 'f7100000-0000-4000-8000-000000000001';
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id
  from app.order_package_snapshots
  where order_id in (
    'f7500000-0000-4000-8000-000000000001',
    'f7500000-0000-4000-8000-000000000002'
  )
);
delete from app.order_package_snapshots
where order_id in (
  'f7500000-0000-4000-8000-000000000001',
  'f7500000-0000-4000-8000-000000000002'
);
delete from app.member_orders
where id in (
  'f7500000-0000-4000-8000-000000000001',
  'f7500000-0000-4000-8000-000000000002'
);
delete from app.member_seasons
where season_id = 'f7100000-0000-4000-8000-000000000001';
delete from private.member_sensitive_identity
where member_id in (
  'f7200000-0000-4000-8000-000000000001',
  'f7200000-0000-4000-8000-000000000002'
);
delete from app.members
where id in (
  'f7200000-0000-4000-8000-000000000001',
  'f7200000-0000-4000-8000-000000000002'
);
delete from app.inventory_settings
where season_id = 'f7100000-0000-4000-8000-000000000001';
delete from app.seasons
where id = 'f7100000-0000-4000-8000-000000000001';
delete from app.audit_logs
where actor_user_id = 'f7000000-0000-4000-8000-000000000001';
delete from app.staff_profiles
where auth_user_id = 'f7000000-0000-4000-8000-000000000001';
delete from app.mail_template_revisions
where id = 'f7600000-0000-4000-8000-000000000001'
  and :'created_template_revision'::boolean;

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
  "select count(*) from app.mail_template_revisions where template_key='partial_pickup' and status='published'")" == "0" ]]; then
  created_template_revision="true"
fi

"${psql_cmd[@]}" -v create_revision="$created_template_revision" >/dev/null <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'f7000000-0000-4000-8000-000000000001',
  'Mailprojectie race',
  'beheerder'
);
insert into app.seasons(id, name, default_amount_cents, status)
values (
  'f7100000-0000-4000-8000-000000000001',
  'Mailprojectie concurrency',
  12500,
  'open'
);
insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values
  (
    'f7200000-0000-4000-8000-000000000001',
    'MAIL-RACE-001',
    'Eerste',
    'Race',
    'mail-race@example.invalid',
    'TEST-1'
  ),
  (
    'f7200000-0000-4000-8000-000000000002',
    'MAIL-RACE-002',
    'Tweede',
    'Race',
    'mail-race@example.invalid',
    'TEST-2'
  );
insert into app.member_orders(id, member_id, season_id, amount_due_cents) values
  (
    'f7500000-0000-4000-8000-000000000001',
    'f7200000-0000-4000-8000-000000000001',
    'f7100000-0000-4000-8000-000000000001',
    12500
  ),
  (
    'f7500000-0000-4000-8000-000000000002',
    'f7200000-0000-4000-8000-000000000002',
    'f7100000-0000-4000-8000-000000000001',
    12500
  );
update app.member_seasons
set participation_status = 'active'
where season_id = 'f7100000-0000-4000-8000-000000000001';
insert into private.parent_accounts(id, email_normalized)
values (
  'f7400000-0000-4000-8000-000000000001',
  'mail-race@example.invalid'
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
  case orders.id
    when 'f7500000-0000-4000-8000-000000000001'::uuid
      then 'f7300000-0000-4000-8000-000000000001'::uuid
    else 'f7300000-0000-4000-8000-000000000002'::uuid
  end,
  orders.member_season_id,
  'mail-race@example.invalid',
  'f7400000-0000-4000-8000-000000000001',
  'active',
  'administrator',
  'f7000000-0000-4000-8000-000000000001',
  timezone('utc', now())
from app.member_orders orders
where orders.id in (
  'f7500000-0000-4000-8000-000000000001',
  'f7500000-0000-4000-8000-000000000002'
);
insert into app.fulfilments(
  id,
  order_id,
  actor_user_id,
  location,
  member_season_id,
  season_id
)
select
  case orders.id
    when 'f7500000-0000-4000-8000-000000000001'::uuid
      then 'f7700000-0000-4000-8000-000000000001'::uuid
    else 'f7700000-0000-4000-8000-000000000002'::uuid
  end,
  orders.id,
  'f7000000-0000-4000-8000-000000000001',
  'Free-Kick Sport',
  orders.member_season_id,
  orders.season_id
from app.member_orders orders
where orders.id in (
  'f7500000-0000-4000-8000-000000000001',
  'f7500000-0000-4000-8000-000000000002'
);

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
  'f7600000-0000-4000-8000-000000000001',
  draft.template_key,
  999,
  'published',
  draft.internal_name,
  draft.subject_source,
  draft.preheader_source,
  draft.body_tiptap,
  '<p>Veilige concurrencytemplate</p>',
  draft.text_fallback_source,
  draft.schema_version,
  repeat('f', 64),
  'system',
  timezone('utc', now())
from app.mail_template_revisions draft
where draft.template_key = 'partial_pickup'
  and draft.status = 'draft'
  and :'create_revision'::boolean;

insert into private.release_cutovers(key, activated_at)
values ('mail_templates_v2', timezone('utc', now()) - interval '1 minute')
on conflict (key) do nothing;
update app.release_feature_flags
set enabled = true
where key = 'mail_templates_v2';

insert into private.fulfilment_notification_events(
  id,
  fulfilment_id,
  order_id,
  member_season_id,
  season_id,
  event_type,
  idempotency_key,
  payload_snapshot
)
select
  case orders.id
    when 'f7500000-0000-4000-8000-000000000001'::uuid
      then 'f7800000-0000-4000-8000-000000000001'::uuid
    else 'f7800000-0000-4000-8000-000000000002'::uuid
  end,
  case orders.id
    when 'f7500000-0000-4000-8000-000000000001'::uuid
      then 'f7700000-0000-4000-8000-000000000001'::uuid
    else 'f7700000-0000-4000-8000-000000000002'::uuid
  end,
  orders.id,
  orders.member_season_id,
  orders.season_id,
  'partial_pickup',
  case orders.id
    when 'f7500000-0000-4000-8000-000000000001'::uuid
      then repeat('1', 64)
    else repeat('2', 64)
  end,
  jsonb_build_object(
    'issued',
    jsonb_build_array(jsonb_build_object(
      'product', 'Testshirt',
      'size', 'M',
      'quantity', 1
    )),
    'remaining',
    jsonb_build_array(jsonb_build_object(
      'product', 'Testbroek',
      'size', 'M',
      'quantity', 1,
      'status', 'backorder'
    )),
    'package',
    jsonb_build_array()
  )
from app.member_orders orders
where orders.id in (
  'f7500000-0000-4000-8000-000000000001',
  'f7500000-0000-4000-8000-000000000002'
);
SQL

fixture_state="$("${psql_cmd[@]}" -c "
  select concat_ws(
    ':',
    (
      select count(*)
      from private.fulfilment_notification_events
      where season_id = 'f7100000-0000-4000-8000-000000000001'
    ),
    (
      select count(*)
      from private.parent_portal_grants grant_row
      join app.member_seasons member_season
        on member_season.id = grant_row.member_season_id
      where member_season.season_id =
        'f7100000-0000-4000-8000-000000000001'
        and grant_row.status = 'active'
    ),
    (
      select count(*)
      from app.mail_template_revisions
      where template_key = 'partial_pickup'
        and status = 'published'
    ),
    (
      select count(*)
      from app.mail_branding_revisions
      where status = 'published'
        and contrast_validated
    ),
    (
      select count(*)
      from app.release_feature_flags
      where key = 'mail_templates_v2'
        and enabled
    ),
    (
      select count(*)
      from private.fulfilment_notification_events event
      cross join private.release_cutovers cutover
      where event.season_id =
        'f7100000-0000-4000-8000-000000000001'
        and cutover.key = 'mail_templates_v2'
        and event.created_at >= cutover.activated_at
    ),
    (
      select count(*)
      from private.fulfilment_notification_events event
      join app.member_seasons member_season
        on member_season.id = event.member_season_id
        and member_season.participation_status = 'active'
      join private.parent_portal_grants grant_row
        on grant_row.member_season_id = event.member_season_id
        and grant_row.status = 'active'
        and grant_row.parent_account_id is not null
      cross join private.release_cutovers cutover
      where event.season_id =
        'f7100000-0000-4000-8000-000000000001'
        and cutover.key = 'mail_templates_v2'
        and event.created_at >= cutover.activated_at
    )
  )
")"
if [[ "$fixture_state" != "2:2:1:1:1:2:2" ]]; then
  echo "Onvolledige mailprojectie-concurrencyfixture: $fixture_state" >&2
  exit 1
fi

claim_projection() {
  local lease_token="$1"
  "${psql_cmd[@]}" <<SQL
    begin;
    set local role service_role;
    select app.claim_fulfilment_mail_projections_v1(
      '${lease_token}'::uuid,
      10
    );
    commit;
SQL
}

first_claim() {
  "${psql_cmd[@]}" <<SQL
    begin;
    set local role service_role;
    select app.claim_fulfilment_mail_projections_v1(
      'f7900000-0000-4000-8000-000000000001'::uuid,
      10
    );
    \\! touch "$first_marker"
    select pg_sleep(2);
    commit;
SQL
}

first_claim >"$first_log" 2>&1 &
first_pid=$!

for _ in $(seq 1 100); do
  if [[ -f "$first_marker" ]]; then
    break
  fi
  if ! kill -0 "$first_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ ! -f "$first_marker" ]]; then
  wait "$first_pid" || true
  sed -n '1,80p' "$first_log" >&2
  echo "De eerste mailprojectieworker bereikte de overlapbarrière niet." >&2
  exit 1
fi

claim_projection "f7900000-0000-4000-8000-000000000002" \
  >"$second_log" 2>&1 &
second_pid=$!

set +e
wait "$first_pid"
first_status=$?
wait "$second_pid"
second_status=$?
set -e

if (( first_status != 0 || second_status != 0 )); then
  sed -n '1,80p' "$first_log" >&2
  sed -n '1,80p' "$second_log" >&2
  echo "Een gelijktijdige mailprojectieworker eindigde met een databasefout." >&2
  exit 1
fi

state="$("${psql_cmd[@]}" -c "
  select concat_ws(
    ':',
    (
      select count(*)
      from private.fulfilment_mail_projection_batches
      where season_id = 'f7100000-0000-4000-8000-000000000001'
    ),
    (
      select count(*)
      from private.fulfilment_mail_projections projection
      join private.fulfilment_mail_projection_batches batch
        on batch.id = projection.projection_batch_id
      where batch.season_id = 'f7100000-0000-4000-8000-000000000001'
    ),
    (
      select count(distinct lease_token)
      from private.fulfilment_mail_projection_batches
      where season_id = 'f7100000-0000-4000-8000-000000000001'
    ),
    (
      select sum(event_count)
      from private.fulfilment_mail_projection_batches
      where season_id = 'f7100000-0000-4000-8000-000000000001'
    )
  )
")"

if [[ "$state" != "1:2:1:2" ]]; then
  sed -n '1,80p' "$first_log" >&2
  sed -n '1,80p' "$second_log" >&2
  echo "Onverwachte mailprojectie-concurrencystaat: $state" >&2
  exit 1
fi

render_contract="$("${psql_cmd[@]}" -c "
  with target as (
    select
      batch.id group_id,
      batch.lease_token,
      eligibility.revision_hash eligibility_revision,
      batch.template_revision_id,
      batch.branding_revision_id
    from private.fulfilment_mail_projection_batches batch
    cross join lateral private.fulfilment_mail_current_eligibility(batch.id)
      eligibility
    where batch.season_id = 'f7100000-0000-4000-8000-000000000001'
  )
  select concat_ws(
    ':',
    target.group_id,
    target.lease_token,
    target.eligibility_revision,
    target.template_revision_id,
    target.branding_revision_id,
    private.mail_v2_render_hash(
      target.group_id,
      target.eligibility_revision,
      target.template_revision_id,
      target.branding_revision_id,
      'Concurrency onderwerp',
      'Concurrency preheader',
      '<p>Veilige concurrencyrender</p>',
      'Veilige concurrencyrender'
    )
  )
  from target
")"
IFS=: read -r group_id lease_token eligibility_revision template_revision_id \
  branding_revision_id render_hash <<<"$render_contract"
if [[ -z "$group_id" || -z "$render_hash" ]]; then
  echo "De mailprojectierenderbarrière kon niet worden voorbereid." >&2
  exit 1
fi

pause_marker="$test_tmp_dir/pause-holding"
pause_log="$test_tmp_dir/pause.log"
finalize_log="$test_tmp_dir/finalize-after-pause.log"

pause_projection() {
  "${psql_cmd[@]}" <<SQL
    begin;
    select set_config(
      'request.jwt.claims',
      '{"sub":"f7000000-0000-4000-8000-000000000001","aal":"aal2"}',
      true
    );
    set local role authenticated;
    select app.pause_mail_templates_v2(
      'Geforceerde overlaptest',
      null
    );
    \\! touch "$pause_marker"
    select pg_sleep(2);
    commit;
SQL
}

finalize_after_pause() {
  "${psql_cmd[@]}" <<SQL
    begin;
    set local role service_role;
    select app.finalize_fulfilment_mail_projection_v1(
      '$group_id'::uuid,
      '$lease_token'::uuid,
      '$eligibility_revision',
      'Concurrency onderwerp',
      'Concurrency preheader',
      '<p>Veilige concurrencyrender</p>',
      'Veilige concurrencyrender',
      '$render_hash'
    );
    commit;
SQL
}

pause_projection >"$pause_log" 2>&1 &
pause_pid=$!
for _ in $(seq 1 100); do
  if [[ -f "$pause_marker" ]]; then
    break
  fi
  if ! kill -0 "$pause_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ ! -f "$pause_marker" ]]; then
  wait "$pause_pid" || true
  sed -n '1,80p' "$pause_log" >&2
  echo "De mailpauze bereikte de overlapbarrière niet." >&2
  exit 1
fi

set +e
finalize_after_pause >"$finalize_log" 2>&1 &
finalize_pid=$!
wait "$pause_pid"
pause_status=$?
wait "$finalize_pid"
finalize_status=$?
set -e

if (( pause_status != 0 || finalize_status == 0 )); then
  sed -n '1,80p' "$pause_log" >&2
  sed -n '1,80p' "$finalize_log" >&2
  echo "De pause-versus-finalizebarrière faalde." >&2
  exit 1
fi
if ! grep -q "MAIL_V2_PROJECTION_PAUSED" "$finalize_log"; then
  sed -n '1,80p' "$finalize_log" >&2
  echo "Finalize faalde niet met het verwachte pauzecontract." >&2
  exit 1
fi

post_pause_state="$("${psql_cmd[@]}" -c "
  select concat_ws(
    ':',
    (
      select enabled::text
      from app.release_feature_flags
      where key = 'mail_templates_v2'
    ),
    (
      select count(*)
      from private.email_jobs
      where context_kind = 'fulfilment'
    ),
    (
      select status
      from private.fulfilment_mail_projection_batches
      where id = '$group_id'::uuid
    )
  )
")"
if [[ "$post_pause_state" != "false:0:leased" ]]; then
  echo "Onverwachte toestand na mailpauzebarrière: $post_pause_state" >&2
  exit 1
fi

echo "Mailprojectieconcurrency geslaagd: één gezinslease en pause blokkeert een overlappende finalize."
