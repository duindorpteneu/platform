#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1)
same_first_log="/tmp/duindorp-parent-access-same-first.log"
same_second_log="/tmp/duindorp-parent-access-same-second.log"
different_first_log="/tmp/duindorp-parent-access-different-first.log"
different_second_log="/tmp/duindorp-parent-access-different-second.log"
cross_activate_log="/tmp/duindorp-parent-access-cross-activate.log"
cross_revoke_log="/tmp/duindorp-parent-access-cross-revoke.log"
email_activate_log="/tmp/duindorp-parent-access-email-activate.log"
email_update_log="/tmp/duindorp-parent-access-email-update.log"
template_activate_log="/tmp/duindorp-parent-access-template-activate.log"
template_update_log="/tmp/duindorp-parent-access-template-update.log"
previous_active_season="$("${psql_cmd[@]}" -Atc "select coalesce(active_season_id::text, '') from app.app_settings where id = true")"

cleanup() {
  "${psql_cmd[@]}" <<'SQL'
delete from private.email_jobs
where parent_access_batch_id in (
  select id from private.parent_access_batches
  where actor_user_id = 'b0000000-0000-4000-8000-000000000001'
);
delete from private.parent_access_batch_items
where batch_id in (
  select id from private.parent_access_batches
  where actor_user_id = 'b0000000-0000-4000-8000-000000000001'
);
delete from private.parent_access_batches
where actor_user_id = 'b0000000-0000-4000-8000-000000000001';
delete from private.parent_portal_grants
where member_season_id in (
  'b3000000-0000-4000-8000-000000000001',
  'b3000000-0000-4000-8000-000000000002',
  'b3000000-0000-4000-8000-000000000003',
  'b3000000-0000-4000-8000-000000000004',
  'b3000000-0000-4000-8000-000000000005',
  'b3000000-0000-4000-8000-000000000006'
);
delete from private.parent_otp_challenges
where parent_account_id in (
  select id from private.parent_accounts
  where email_normalized in (
    'access-race-one@example.invalid',
    'access-race-two@example.invalid',
    'access-race-cross@example.invalid',
    'access-race-email@example.invalid',
    'access-race-template@example.invalid'
  )
);
delete from private.parent_sessions
where parent_account_id in (
  select id from private.parent_accounts
  where email_normalized in (
    'access-race-one@example.invalid',
    'access-race-two@example.invalid',
    'access-race-cross@example.invalid',
    'access-race-email@example.invalid',
    'access-race-template@example.invalid'
  )
);
delete from private.parent_member_links
where member_id in (
  'b2000000-0000-4000-8000-000000000001',
  'b2000000-0000-4000-8000-000000000002',
  'b2000000-0000-4000-8000-000000000003',
  'b2000000-0000-4000-8000-000000000004',
  'b2000000-0000-4000-8000-000000000005'
);
delete from private.parent_accounts
where email_normalized in (
  'access-race-one@example.invalid',
  'access-race-two@example.invalid',
  'access-race-cross@example.invalid',
  'access-race-email@example.invalid',
  'access-race-template@example.invalid'
);
delete from app.audit_logs
where actor_user_id = 'b0000000-0000-4000-8000-000000000001'
  or metadata->>'seasonId' = 'b1000000-0000-4000-8000-000000000001';
delete from app.member_seasons
where id in (
  'b3000000-0000-4000-8000-000000000001',
  'b3000000-0000-4000-8000-000000000002',
  'b3000000-0000-4000-8000-000000000003',
  'b3000000-0000-4000-8000-000000000004',
  'b3000000-0000-4000-8000-000000000005',
  'b3000000-0000-4000-8000-000000000006'
);
delete from app.members
where id in (
  'b2000000-0000-4000-8000-000000000001',
  'b2000000-0000-4000-8000-000000000002',
  'b2000000-0000-4000-8000-000000000003',
  'b2000000-0000-4000-8000-000000000004',
  'b2000000-0000-4000-8000-000000000005'
);
delete from app.seasons
where id in (
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000002'
);
update app.email_templates
set subject_source = regexp_replace(
  subject_source,
  ' \[access-concurrency\]$',
  ''
)
where template_key = 'portal_access_invite'
  and subject_source like '% [access-concurrency]';
delete from app.staff_profiles
where auth_user_id = 'b0000000-0000-4000-8000-000000000001';
SQL
  if [[ "$previous_active_season" =~ ^[0-9a-f-]{36}$ ]]; then
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id = '$previous_active_season'::uuid where id = true" >/dev/null
  else
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id = null where id = true" >/dev/null
  fi
}

trap cleanup EXIT
cleanup

"${psql_cmd[@]}" <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'b0000000-0000-4000-8000-000000000001',
  'Toegang concurrencybeheerder',
  'beheerder'
);
insert into app.seasons(
  id, name, starts_on, ends_on, default_amount_cents, status, opened_at
) values
  (
    'b1000000-0000-4000-8000-000000000001',
    'Toegang concurrencyseizoen',
    '2047-07-01',
    '2048-06-30',
    12500,
    'open',
    timezone('utc', now())
  ),
  (
    'b1000000-0000-4000-8000-000000000002',
    'Toegang concurrencyseizoen twee',
    '2048-07-01',
    '2049-06-30',
    13000,
    'open',
    timezone('utc', now())
  );
insert into app.members(
  id, relation_number, first_name, last_name, email, team, active_for_season
) values
  (
    'b2000000-0000-4000-8000-000000000001',
    'ACCESS-RACE-1',
    'Race',
    'Een',
    'access-race-one@example.invalid',
    'Race-1',
    true
  ),
  (
    'b2000000-0000-4000-8000-000000000002',
    'ACCESS-RACE-2',
    'Race',
    'Twee',
    'access-race-two@example.invalid',
    'Race-2',
    true
  ),
  (
    'b2000000-0000-4000-8000-000000000003',
    'ACCESS-RACE-3',
    'Race',
    'Seizoen',
    'access-race-cross@example.invalid',
    'Race-3',
    true
  ),
  (
    'b2000000-0000-4000-8000-000000000004',
    'ACCESS-RACE-4',
    'Race',
    'E-mail',
    'access-race-email@example.invalid',
    'Race-4',
    true
  ),
  (
    'b2000000-0000-4000-8000-000000000005',
    'ACCESS-RACE-5',
    'Race',
    'Template',
    'access-race-template@example.invalid',
    'Race-5',
    true
  );
insert into app.member_seasons(
  id,
  member_id,
  season_id,
  team_name,
  participation_status,
  reconciliation_status
) values
  (
    'b3000000-0000-4000-8000-000000000001',
    'b2000000-0000-4000-8000-000000000001',
    'b1000000-0000-4000-8000-000000000001',
    'Race-1',
    'active',
    'resolved'
  ),
  (
    'b3000000-0000-4000-8000-000000000002',
    'b2000000-0000-4000-8000-000000000002',
    'b1000000-0000-4000-8000-000000000001',
    'Race-2',
    'active',
    'resolved'
  ),
  (
    'b3000000-0000-4000-8000-000000000003',
    'b2000000-0000-4000-8000-000000000003',
    'b1000000-0000-4000-8000-000000000001',
    'Race-3',
    'active',
    'resolved'
  ),
  (
    'b3000000-0000-4000-8000-000000000004',
    'b2000000-0000-4000-8000-000000000003',
    'b1000000-0000-4000-8000-000000000002',
    'Race-3B',
    'active',
    'resolved'
  ),
  (
    'b3000000-0000-4000-8000-000000000005',
    'b2000000-0000-4000-8000-000000000004',
    'b1000000-0000-4000-8000-000000000001',
    'Race-4',
    'active',
    'resolved'
  ),
  (
    'b3000000-0000-4000-8000-000000000006',
    'b2000000-0000-4000-8000-000000000005',
    'b1000000-0000-4000-8000-000000000001',
    'Race-5',
    'active',
    'resolved'
  );
update app.app_settings
set active_season_id = 'b1000000-0000-4000-8000-000000000001'
where id = true;
SQL

preview_revision() {
  local member_season_id="$1"
  local season_id="${2:-b1000000-0000-4000-8000-000000000001}"
  "${psql_cmd[@]}" -At <<SQL
begin;
set local role authenticated;
set local "request.jwt.claims" =
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}';
select app.preview_parent_portal_activation(
  '${season_id}',
  array['${member_season_id}'::uuid]
)->>'revision';
commit;
SQL
}

run_activation() {
  local member_season_id="$1"
  local revision="$2"
  local batch_key="$3"
  local hold_seconds="$4"
  local season_id="${5:-b1000000-0000-4000-8000-000000000001}"
  "${psql_cmd[@]}" <<SQL
begin;
set local role authenticated;
set local "request.jwt.claims" =
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}';
select app.activate_parent_portal_access(
  '${season_id}',
  array['${member_season_id}'::uuid],
  '${revision}',
  '${batch_key}'::uuid,
  null
);
select pg_sleep(${hold_seconds});
commit;
SQL
}

preview_revocation() {
  local grant_id="$1"
  local season_id="$2"
  "${psql_cmd[@]}" -At <<SQL
begin;
set local role authenticated;
set local "request.jwt.claims" =
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}';
select app.preview_parent_portal_revocation(
  '${season_id}',
  array['${grant_id}'::uuid]
)->>'revision';
commit;
SQL
}

run_revocation() {
  local grant_id="$1"
  local revision="$2"
  local batch_key="$3"
  local hold_seconds="$4"
  local season_id="$5"
  "${psql_cmd[@]}" <<SQL
begin;
set local role authenticated;
set local "request.jwt.claims" =
  '{"sub":"b0000000-0000-4000-8000-000000000001","aal":"aal2"}';
select app.revoke_parent_portal_access(
  '${season_id}',
  array['${grant_id}'::uuid],
  'Concurrencycontrole over seizoenen',
  '${revision}',
  '${batch_key}'::uuid,
  null
);
select pg_sleep(${hold_seconds});
commit;
SQL
}

same_revision="$(preview_revision 'b3000000-0000-4000-8000-000000000001')"
set +e
run_activation \
  'b3000000-0000-4000-8000-000000000001' \
  "$same_revision" \
  'b4000000-0000-4000-8000-000000000001' \
  1 >"$same_first_log" 2>&1 &
same_first_pid=$!
sleep 0.2
run_activation \
  'b3000000-0000-4000-8000-000000000001' \
  "$same_revision" \
  'b4000000-0000-4000-8000-000000000001' \
  0 >"$same_second_log" 2>&1 &
same_second_pid=$!
wait "$same_first_pid"
same_first_status=$?
wait "$same_second_pid"
same_second_status=$?
set -e

if [[ "$same_first_status" -ne 0 || "$same_second_status" -ne 0 ]]; then
  tail -n 40 "$same_first_log"
  tail -n 40 "$same_second_log"
  exit 1
fi
if ! grep -q '"reused": false' "$same_first_log" \
  || ! grep -q '"reused": true' "$same_second_log"; then
  tail -n 40 "$same_first_log"
  tail -n 40 "$same_second_log"
  exit 1
fi

same_counts="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from private.parent_portal_grants
      where member_season_id = 'b3000000-0000-4000-8000-000000000001'
        and status = 'active')
    || ':' ||
    (select count(*) from private.email_jobs
      where context_kind = 'portal_access'
        and parent_access_batch_id = (
          select id from private.parent_access_batches
          where batch_key = 'b4000000-0000-4000-8000-000000000001'
        ));
")"
if [[ "$same_counts" != "1:1" ]]; then
  echo "Onverwacht idempotent toegangsrace-resultaat: $same_counts"
  exit 1
fi

different_revision="$(preview_revision 'b3000000-0000-4000-8000-000000000002')"
set +e
run_activation \
  'b3000000-0000-4000-8000-000000000002' \
  "$different_revision" \
  'b4000000-0000-4000-8000-000000000002' \
  1 >"$different_first_log" 2>&1 &
different_first_pid=$!
sleep 0.2
run_activation \
  'b3000000-0000-4000-8000-000000000002' \
  "$different_revision" \
  'b4000000-0000-4000-8000-000000000003' \
  0 >"$different_second_log" 2>&1 &
different_second_pid=$!
wait "$different_first_pid"
different_first_status=$?
wait "$different_second_pid"
different_second_status=$?
set -e

if [[ "$different_first_status" -ne 0 ]]; then
  tail -n 40 "$different_first_log"
  exit 1
fi
if [[ "$different_second_status" -eq 0 ]] \
  || ! grep -q 'PARENT_ACCESS_PREVIEW_STALE' "$different_second_log"; then
  tail -n 40 "$different_second_log"
  exit 1
fi

different_counts="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from private.parent_portal_grants
      where member_season_id = 'b3000000-0000-4000-8000-000000000002'
        and status = 'active')
    || ':' ||
    (select count(*) from private.parent_access_batches
      where season_id = 'b1000000-0000-4000-8000-000000000001'
        and batch_key in (
          'b4000000-0000-4000-8000-000000000002',
          'b4000000-0000-4000-8000-000000000003'
        ));
")"
if [[ "$different_counts" != "1:1" ]]; then
  echo "Onverwacht verschillende-batch toegangsrace-resultaat: $different_counts"
  exit 1
fi

cross_current_revision="$(preview_revision 'b3000000-0000-4000-8000-000000000003')"
run_activation \
  'b3000000-0000-4000-8000-000000000003' \
  "$cross_current_revision" \
  'b4000000-0000-4000-8000-000000000004' \
  0 >/dev/null
cross_grant_id="$("${psql_cmd[@]}" -Atc "
  select id
  from private.parent_portal_grants
  where member_season_id = 'b3000000-0000-4000-8000-000000000003'
    and status = 'active';
")"
"${psql_cmd[@]}" -c "
  insert into private.parent_sessions(
    parent_account_id,
    token_hash,
    expires_at
  )
  select parent_account_id, repeat('c', 64), timezone('utc', now()) + interval '1 day'
  from private.parent_portal_grants
  where id = '${cross_grant_id}'::uuid;
" >/dev/null
cross_next_revision="$(preview_revision \
  'b3000000-0000-4000-8000-000000000004' \
  'b1000000-0000-4000-8000-000000000002')"
cross_revoke_revision="$(preview_revocation \
  "$cross_grant_id" \
  'b1000000-0000-4000-8000-000000000001')"
set +e
run_activation \
  'b3000000-0000-4000-8000-000000000004' \
  "$cross_next_revision" \
  'b4000000-0000-4000-8000-000000000005' \
  1 \
  'b1000000-0000-4000-8000-000000000002' \
  >"$cross_activate_log" 2>&1 &
cross_activate_pid=$!
sleep 0.2
run_revocation \
  "$cross_grant_id" \
  "$cross_revoke_revision" \
  'b4000000-0000-4000-8000-000000000006' \
  0 \
  'b1000000-0000-4000-8000-000000000001' \
  >"$cross_revoke_log" 2>&1 &
cross_revoke_pid=$!
wait "$cross_activate_pid"
cross_activate_status=$?
wait "$cross_revoke_pid"
cross_revoke_status=$?
set -e
if [[ "$cross_activate_status" -ne 0 || "$cross_revoke_status" -ne 0 ]]; then
  tail -n 40 "$cross_activate_log"
  tail -n 40 "$cross_revoke_log"
  exit 1
fi
cross_counts="$("${psql_cmd[@]}" -Atc "
  select
    (select count(*) from private.parent_portal_grants
      where member_season_id = 'b3000000-0000-4000-8000-000000000003'
        and status = 'revoked')
    || ':' ||
    (select count(*) from private.parent_portal_grants
      where member_season_id = 'b3000000-0000-4000-8000-000000000004'
        and status = 'active')
    || ':' ||
    (select count(*) from private.parent_member_links
      where member_id = 'b2000000-0000-4000-8000-000000000003'
        and unlinked_at is null)
    || ':' ||
    (select count(*) from private.parent_sessions
      where token_hash = repeat('c', 64)
        and revoked_at is not null);
")"
if [[ "$cross_counts" != "1:1:0:1" ]]; then
  echo "Onverwacht seizoensoverschrijdend toegangsrace-resultaat: $cross_counts"
  exit 1
fi

email_revision="$(preview_revision 'b3000000-0000-4000-8000-000000000005')"
set +e
run_activation \
  'b3000000-0000-4000-8000-000000000005' \
  "$email_revision" \
  'b4000000-0000-4000-8000-000000000007' \
  1 >"$email_activate_log" 2>&1 &
email_activate_pid=$!
sleep 0.2
"${psql_cmd[@]}" -c "
  update app.members
  set email = 'access-race-email-new@example.invalid'
  where id = 'b2000000-0000-4000-8000-000000000004';
" >"$email_update_log" 2>&1 &
email_update_pid=$!
wait "$email_activate_pid"
email_activate_status=$?
wait "$email_update_pid"
email_update_status=$?
set -e
if [[ "$email_activate_status" -ne 0 || "$email_update_status" -ne 0 ]]; then
  tail -n 40 "$email_activate_log"
  tail -n 40 "$email_update_log"
  exit 1
fi
email_state="$("${psql_cmd[@]}" -Atc "
  select
    (select email_normalized
      from private.parent_portal_grants
      where member_season_id = 'b3000000-0000-4000-8000-000000000005'
        and status = 'active')
    || ':' ||
    (select email from app.members
      where id = 'b2000000-0000-4000-8000-000000000004');
")"
if [[ "$email_state" != "access-race-email@example.invalid:access-race-email-new@example.invalid" ]]; then
  echo "Onverwachte e-mailrace-uitkomst."
  exit 1
fi

template_revision="$(preview_revision 'b3000000-0000-4000-8000-000000000006')"
set +e
run_activation \
  'b3000000-0000-4000-8000-000000000006' \
  "$template_revision" \
  'b4000000-0000-4000-8000-000000000008' \
  1 >"$template_activate_log" 2>&1 &
template_activate_pid=$!
sleep 0.2
"${psql_cmd[@]}" -c "
  update app.email_templates
  set subject_source = subject_source || ' [access-concurrency]'
  where template_key = 'portal_access_invite';
" >"$template_update_log" 2>&1 &
template_update_pid=$!
wait "$template_activate_pid"
template_activate_status=$?
wait "$template_update_pid"
template_update_status=$?
set -e
if [[ "$template_activate_status" -ne 0 || "$template_update_status" -ne 0 ]]; then
  tail -n 40 "$template_activate_log"
  tail -n 40 "$template_update_log"
  exit 1
fi
template_state="$("${psql_cmd[@]}" -Atc "
  select
    (select subject_source_snapshot like '% [access-concurrency]'
      from private.email_jobs
      where parent_access_batch_id = (
        select id from private.parent_access_batches
        where batch_key = 'b4000000-0000-4000-8000-000000000008'
      ))
    || ':' ||
    (select subject_source like '% [access-concurrency]'
      from app.email_templates
      where template_key = 'portal_access_invite');
")"
if [[ "$template_state" != "false:true" ]]; then
  echo "Onverwachte mailtemplaterace-uitkomst: $template_state"
  exit 1
fi

echo "Toegangsconcurrencytest geslaagd: retries, stale previews, cross-season intrekking, e-mailidentiteit en templatesnapshot zijn raceveilig."
