#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De OTP-racetest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-parent-otp.XXXXXX)"
replay_marker="$test_tmp_dir/replay-holding"
binding_marker="$test_tmp_dir/binding-holding"
identity_marker="$test_tmp_dir/identity-holding"
challenge_marker="$test_tmp_dir/challenge-holding"
support_replay_marker="$test_tmp_dir/support-replay-holding"
support_limit_marker="$test_tmp_dir/support-limit-holding"
replay_first_log="$test_tmp_dir/replay-first.log"
replay_second_log="$test_tmp_dir/replay-second.log"
binding_first_log="$test_tmp_dir/binding-first.log"
binding_second_log="$test_tmp_dir/binding-second.log"
identity_first_log="$test_tmp_dir/identity-first.log"
identity_second_log="$test_tmp_dir/identity-second.log"
challenge_first_log="$test_tmp_dir/challenge-first.log"
challenge_second_log="$test_tmp_dir/challenge-second.log"
support_replay_first_log="$test_tmp_dir/support-replay-first.log"
support_replay_second_log="$test_tmp_dir/support-replay-second.log"
support_limit_first_log="$test_tmp_dir/support-limit-first.log"
support_limit_second_log="$test_tmp_dir/support-limit-second.log"

cleanup_data() {
  "${psql_cmd[@]}" >/dev/null <<'SQL'
begin;
set local session_replication_role = replica;
delete from private.parent_otp_provider_event_quarantine
where delivery_attempt_id in (
  'e2791000-0000-4000-8000-000000000001',
  'e2791000-0000-4000-8000-000000000002'
);
delete from private.parent_otp_provider_events
where delivery_attempt_id in (
  'e2791000-0000-4000-8000-000000000001',
  'e2791000-0000-4000-8000-000000000002'
);
delete from private.parent_otp_provider_message_bindings
where delivery_attempt_id in (
  'e2791000-0000-4000-8000-000000000001',
  'e2791000-0000-4000-8000-000000000002'
);
delete from private.parent_otp_delivery_outcomes
where delivery_attempt_id in (
  select id from private.parent_otp_delivery_attempts
  where parent_account_id in (
    'e2790000-0000-4000-8000-000000000001',
    'e2790000-0000-4000-8000-000000000003'
  )
);
delete from private.email_provider_sync_evidence
where parent_otp_delivery_attempt_id in (
  select id from private.parent_otp_delivery_attempts
  where parent_account_id in (
    'e2790000-0000-4000-8000-000000000001',
    'e2790000-0000-4000-8000-000000000003'
  )
);
delete from private.parent_otp_delivery_attempts
where parent_account_id in (
  'e2790000-0000-4000-8000-000000000001',
  'e2790000-0000-4000-8000-000000000003'
);
delete from private.parent_otp_support_events
where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
delete from private.parent_sessions
where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
delete from private.parent_otp_challenges
where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
delete from private.parent_portal_grants
where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
delete from private.email_recipient_parent_bindings
where parent_account_id in (
  'e2790000-0000-4000-8000-000000000001',
  'e2790000-0000-4000-8000-000000000003'
);
delete from app.audit_logs
where entity_id = 'e2790000-0000-4000-8000-000000000003';
delete from app.member_seasons
where member_id = 'e2793000-0000-4000-8000-000000000003';
delete from app.members
where id = 'e2793000-0000-4000-8000-000000000003';
delete from private.parent_accounts
where id in (
  'e2790000-0000-4000-8000-000000000001',
  'e2790000-0000-4000-8000-000000000003'
);
delete from app.staff_profiles
where auth_user_id = 'e2795000-0000-4000-8000-000000000003';
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
insert into private.parent_accounts(id, email_normalized)
values
  (
    'e2790000-0000-4000-8000-000000000001',
    'otp-concurrency@example.invalid'
  ),
  (
    'e2790000-0000-4000-8000-000000000003',
    'otp-challenge-race@example.invalid'
  );
insert into app.staff_profiles(auth_user_id, display_name, role)
values (
  'e2795000-0000-4000-8000-000000000003',
  'OTP support concurrency',
  'beheerder'
);
insert into app.members(
  id, relation_number, first_name, last_name, email, team
) values (
  'e2793000-0000-4000-8000-000000000003',
  'OTP-RACE-003',
  'OTP',
  'Race',
  'otp-challenge-race@example.invalid',
  'JO14-1'
);
insert into private.parent_portal_grants(
  id, member_season_id, email_normalized, parent_account_id,
  status, source, granted_by, granted_at
)
select
  'e2794000-0000-4000-8000-000000000003',
  season.id,
  'otp-challenge-race@example.invalid',
  'e2790000-0000-4000-8000-000000000003',
  'active',
  'administrator',
  'e2795000-0000-4000-8000-000000000003',
  statement_timestamp()
from app.member_seasons season
where season.member_id = 'e2793000-0000-4000-8000-000000000003';
insert into private.parent_otp_challenges(
  id, parent_account_id, code_hash, expires_at, credential_version
) values (
  'e2796000-0000-4000-8000-000000000003',
  'e2790000-0000-4000-8000-000000000003',
  repeat('c', 64),
  statement_timestamp() + interval '10 minutes',
  3
);
insert into private.parent_otp_delivery_attempts(
  id,
  parent_account_id,
  challenge_id,
  template_revision_id,
  branding_revision_id,
  expires_at
)
select
  attempt_id,
  'e2790000-0000-4000-8000-000000000001',
  challenge_id,
  template_revision.id,
  branding.id,
  statement_timestamp() + interval '10 minutes'
from app.mail_template_revisions template_revision
cross join app.mail_branding_revisions branding
cross join (
  values
    (
      'e2791000-0000-4000-8000-000000000001'::uuid,
      'e2792000-0000-4000-8000-000000000001'::uuid
    ),
    (
      'e2791000-0000-4000-8000-000000000002'::uuid,
      'e2792000-0000-4000-8000-000000000002'::uuid
    )
) fixture(attempt_id, challenge_id)
where template_revision.template_key = 'login_otp'
  and template_revision.status = 'published'
  and branding.status = 'published';

insert into private.parent_otp_delivery_outcomes(
  delivery_attempt_id,
  outcome,
  provider_http_message_id
) values
  (
    'e2791000-0000-4000-8000-000000000001',
    'accepted',
    'otp-http-message-1'
  ),
  (
    'e2791000-0000-4000-8000-000000000002',
    'accepted',
    'otp-http-message-2'
  );
SQL

event_time="$("${psql_cmd[@]}" -c \
  "select to_char(clock_timestamp(), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")"

record_event() {
  local attempt_id="$1"
  local event_id="$2"
  local message_id="$3"
  "${psql_cmd[@]}" -c "
    select app.record_parent_otp_sendgrid_events_v3(
      jsonb_build_array(
        jsonb_build_object(
          'delivery_attempt_id', '$attempt_id',
          'event_id', '$event_id',
          'provider_message_id', '$message_id',
          'event_type', 'delivered',
          'occurred_at', '$event_time'
        )
      )
    );
  "
}

replay_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select app.record_parent_otp_sendgrid_events_v3(
  jsonb_build_array(
    jsonb_build_object(
      'delivery_attempt_id', 'e2791000-0000-4000-8000-000000000001',
      'event_id', 'otp-concurrent-replay',
      'provider_message_id', 'otp-http-message-1.filter0001.42.0',
      'event_type', 'delivered',
      'occurred_at', '$event_time'
    )
  )
);
\\! touch "$replay_marker"
select pg_sleep(2);
commit;
SQL
}

replay_first >"$replay_first_log" 2>&1 &
replay_first_pid=$!
for _ in $(seq 1 100); do
  [[ -f "$replay_marker" ]] && break
  kill -0 "$replay_first_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ ! -f "$replay_marker" ]]; then
  echo "De OTP-replaybarrière werd niet bereikt." >&2
  exit 1
fi
record_event \
  "e2791000-0000-4000-8000-000000000001" \
  "otp-concurrent-replay" \
  "otp-http-message-1.filter0001.42.0" \
  >"$replay_second_log" 2>&1 &
replay_second_pid=$!
wait "$replay_first_pid"
wait "$replay_second_pid"

binding_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select app.record_parent_otp_sendgrid_events_v3(
  jsonb_build_array(
    jsonb_build_object(
      'delivery_attempt_id', 'e2791000-0000-4000-8000-000000000002',
      'event_id', 'otp-concurrent-binding-a',
      'provider_message_id', 'otp-http-message-2.filter0001.42.0',
      'event_type', 'delivered',
      'occurred_at', '$event_time'
    )
  )
);
\\! touch "$binding_marker"
select pg_sleep(2);
commit;
SQL
}

binding_first >"$binding_first_log" 2>&1 &
binding_first_pid=$!
for _ in $(seq 1 100); do
  [[ -f "$binding_marker" ]] && break
  kill -0 "$binding_first_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ ! -f "$binding_marker" ]]; then
  echo "De OTP-providerbindingsbarrière werd niet bereikt." >&2
  exit 1
fi
record_event \
  "e2791000-0000-4000-8000-000000000002" \
  "otp-concurrent-binding-b" \
  "otp-http-message-2.filter0002.43.0" \
  >"$binding_second_log" 2>&1 &
binding_second_pid=$!
wait "$binding_first_pid"
wait "$binding_second_pid"

replay_output="$test_tmp_dir/replay-output.log"
binding_output="$test_tmp_dir/binding-output.log"
cp "$replay_first_log" "$replay_output"
sed -n '1,$p' "$replay_second_log" >>"$replay_output"
cp "$binding_first_log" "$binding_output"
sed -n '1,$p' "$binding_second_log" >>"$binding_output"

if [[ "$(grep -c '"recorded": 1' "$replay_output")" -ne 1 ]] \
  || [[ "$(grep -c '"ignored": 1' "$replay_output")" -ne 1 ]]; then
  echo "Exacte parallelle OTP-replay was niet één insert plus één no-op." >&2
  exit 1
fi
if [[ "$(grep -c '"recorded": 1' "$binding_output")" -ne 1 ]] \
  || [[ "$(grep -c '"quarantined": 1' "$binding_output")" -ne 1 ]]; then
  echo "Tegenstrijdige parallelle providerbinding was niet één winnaar plus quarantaine." >&2
  exit 1
fi

second_bound_message="$("${psql_cmd[@]}" -c "
  select provider_message_id
  from private.parent_otp_provider_message_bindings
  where delivery_attempt_id =
    'e2791000-0000-4000-8000-000000000002';
")"
if [[ -z "$second_bound_message" ]]; then
  echo "De tweede OTP-attempt mist een immutable providerbinding." >&2
  exit 1
fi

identity_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select app.record_parent_otp_sendgrid_events_v3(
  jsonb_build_array(
    jsonb_build_object(
      'delivery_attempt_id', 'e2791000-0000-4000-8000-000000000001',
      'event_id', 'otp-global-event-collision',
      'provider_message_id', 'otp-http-message-1.filter0001.42.0',
      'event_type', 'delivered',
      'occurred_at', '$event_time'
    )
  )
);
\\! touch "$identity_marker"
select pg_sleep(2);
commit;
SQL
}

identity_first >"$identity_first_log" 2>&1 &
identity_first_pid=$!
for _ in $(seq 1 100); do
  [[ -f "$identity_marker" ]] && break
  kill -0 "$identity_first_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ ! -f "$identity_marker" ]]; then
  echo "De globale OTP-event-ID-barrière werd niet bereikt." >&2
  exit 1
fi
record_event \
  "e2791000-0000-4000-8000-000000000002" \
  "otp-global-event-collision" \
  "$second_bound_message" \
  >"$identity_second_log" 2>&1 &
identity_second_pid=$!
wait "$identity_first_pid"
wait "$identity_second_pid"
if ! grep -q '"recorded": 1' "$identity_first_log" \
  || ! grep -q '"quarantined": 1' "$identity_second_log"; then
  echo "Globale OTP-event-ID-collision werd niet atomisch gequarantaineerd." >&2
  exit 1
fi

event_count="$("${psql_cmd[@]}" -c "
  select count(*)
  from private.parent_otp_provider_events
  where delivery_attempt_id in (
    'e2791000-0000-4000-8000-000000000001',
    'e2791000-0000-4000-8000-000000000002'
  );
")"
quarantine_count="$("${psql_cmd[@]}" -c "
  select count(*)
  from private.parent_otp_provider_event_quarantine
  where delivery_attempt_id =
    'e2791000-0000-4000-8000-000000000002';
")"
quarantine_reasons="$("${psql_cmd[@]}" -F ':' -c "
  select
    count(*) filter (where reason = 'event_message_mismatch'),
    count(*) filter (where reason = 'event_identity_collision')
  from private.parent_otp_provider_event_quarantine
  where delivery_attempt_id =
    'e2791000-0000-4000-8000-000000000002';
")"
if [[ "$event_count" != "3" \
    || "$quarantine_count" != "2" \
    || "$quarantine_reasons" != "1:1" ]]; then
  echo "De OTP-providerledger bevat na de race geen exact resultaat." >&2
  exit 1
fi

challenge_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select app.consume_parent_login_challenge_v3(
  'e2796000-0000-4000-8000-000000000003',
  'code',
  repeat('c', 64),
  repeat('d', 64),
  statement_timestamp() + interval '7 days'
);
\\! touch "$challenge_marker"
select pg_sleep(2);
commit;
SQL
}

challenge_first >"$challenge_first_log" 2>&1 &
challenge_first_pid=$!
for _ in $(seq 1 100); do
  [[ -f "$challenge_marker" ]] && break
  kill -0 "$challenge_first_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ ! -f "$challenge_marker" ]]; then
  echo "De gedeelde challengeconsumptiebarrière werd niet bereikt." >&2
  exit 1
fi
"${psql_cmd[@]}" -c "
  select app.consume_parent_login_challenge_v3(
    'e2796000-0000-4000-8000-000000000003',
    'direct',
    null,
    repeat('e', 64),
    statement_timestamp() + interval '7 days'
  );
" >"$challenge_second_log" 2>&1 &
challenge_second_pid=$!
wait "$challenge_first_pid"
wait "$challenge_second_pid"
challenge_output="$test_tmp_dir/challenge-output.log"
cp "$challenge_first_log" "$challenge_output"
sed -n '1,$p' "$challenge_second_log" >>"$challenge_output"
challenge_session_count="$("${psql_cmd[@]}" -c "
  select count(*) from private.parent_sessions
  where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
")"
if [[ "$(grep -c '"status": "verified"' "$challenge_output")" -ne 1 ]] \
  || [[ "$(grep -c '"status": "invalid"' "$challenge_output")" -ne 1 ]] \
  || [[ "$challenge_session_count" != "1" ]]; then
  echo "Code en directe link konden dezelfde challenge niet atomair verbruiken." >&2
  exit 1
fi

support_request() {
  local challenge_id="$1"
  local code_hash="$2"
  local request_id="$3"
  "${psql_cmd[@]}" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"e2795000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select app.prepare_parent_otp_support_delivery_v1(
  'e2790000-0000-4000-8000-000000000003',
  'reset',
  '$challenge_id',
  '$code_hash',
  '$request_id'
);
commit;
SQL
}

support_replay_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"e2795000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select app.prepare_parent_otp_support_delivery_v1(
  'e2790000-0000-4000-8000-000000000003',
  'reset',
  'e2797000-0000-4000-8000-000000000001',
  repeat('1', 64),
  'e2798000-0000-4000-8000-000000000001'
);
\! touch "$support_replay_marker"
select pg_sleep(2);
commit;
SQL
}

support_replay_first >"$support_replay_first_log" 2>&1 &
support_replay_first_pid=$!
for _ in $(seq 1 100); do
  [[ -f "$support_replay_marker" ]] && break
  kill -0 "$support_replay_first_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ ! -f "$support_replay_marker" ]]; then
  echo "De support-idempotentiebarrière werd niet bereikt." >&2
  exit 1
fi
support_request \
  'e2797000-0000-4000-8000-000000000002' \
  "$(printf '2%.0s' {1..64})" \
  'e2798000-0000-4000-8000-000000000001' \
  >"$support_replay_second_log" 2>&1 &
support_replay_second_pid=$!
wait "$support_replay_first_pid"
wait "$support_replay_second_pid"

support_replay_output="$test_tmp_dir/support-replay-output.log"
cp "$support_replay_first_log" "$support_replay_output"
sed -n '1,$p' "$support_replay_second_log" >>"$support_replay_output"
support_replay_event_count="$("${psql_cmd[@]}" -c "
  select count(*) from private.parent_otp_support_events
  where request_id = 'e2798000-0000-4000-8000-000000000001';
")"
support_replay_attempt_count="$("${psql_cmd[@]}" -c "
  select count(*) from private.parent_otp_delivery_attempts
  where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
")"
if [[ "$(grep -c '"supportRequestReused": false' "$support_replay_output")" -ne 1 ]] \
  || [[ "$(grep -c '"supportRequestReused": true' "$support_replay_output")" -ne 1 ]] \
  || [[ "$support_replay_event_count" != "1" ]] \
  || [[ "$support_replay_attempt_count" != "1" ]]; then
  echo "Parallelle supportreplay maakte niet exact één event en afleverpoging." >&2
  exit 1
fi

"${psql_cmd[@]}" >/dev/null <<'SQL'
insert into private.parent_otp_support_events(
  request_id,
  parent_account_id,
  actor_user_id,
  action,
  request_hash,
  result_snapshot
) values
  (
    'e2798000-0000-4000-8000-000000000002',
    'e2790000-0000-4000-8000-000000000003',
    'e2795000-0000-4000-8000-000000000003',
    'resend', repeat('a', 64), '{}'::jsonb
  ),
  (
    'e2798000-0000-4000-8000-000000000003',
    'e2790000-0000-4000-8000-000000000003',
    'e2795000-0000-4000-8000-000000000003',
    'resend', repeat('b', 64), '{}'::jsonb
  ),
  (
    'e2798000-0000-4000-8000-000000000004',
    'e2790000-0000-4000-8000-000000000003',
    'e2795000-0000-4000-8000-000000000003',
    'resend', repeat('c', 64), '{}'::jsonb
  );
SQL

support_limit_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  '{"sub":"e2795000-0000-4000-8000-000000000003","aal":"aal2"}',
  true
);
set local role authenticated;
select app.prepare_parent_otp_support_delivery_v1(
  'e2790000-0000-4000-8000-000000000003',
  'reset',
  'e2797000-0000-4000-8000-000000000003',
  repeat('3', 64),
  'e2798000-0000-4000-8000-000000000005'
);
\! touch "$support_limit_marker"
select pg_sleep(2);
commit;
SQL
}

support_limit_first >"$support_limit_first_log" 2>&1 &
support_limit_first_pid=$!
for _ in $(seq 1 100); do
  [[ -f "$support_limit_marker" ]] && break
  kill -0 "$support_limit_first_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ ! -f "$support_limit_marker" ]]; then
  echo "De support-ratelimitbarrière werd niet bereikt." >&2
  exit 1
fi
support_request \
  'e2797000-0000-4000-8000-000000000004' \
  "$(printf '4%.0s' {1..64})" \
  'e2798000-0000-4000-8000-000000000006' \
  >"$support_limit_second_log" 2>&1 &
support_limit_second_pid=$!
support_limit_first_status=0
support_limit_second_status=0
wait "$support_limit_first_pid" || support_limit_first_status=$?
wait "$support_limit_second_pid" || support_limit_second_status=$?
support_limit_event_count="$("${psql_cmd[@]}" -c "
  select count(*) from private.parent_otp_support_events
  where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
")"
support_limit_attempt_count="$("${psql_cmd[@]}" -c "
  select count(*) from private.parent_otp_delivery_attempts
  where parent_account_id = 'e2790000-0000-4000-8000-000000000003';
")"
if [[ "$support_limit_first_status" -ne 0 ]] \
  || [[ "$support_limit_second_status" -eq 0 ]] \
  || ! grep -q 'PARENT_OTP_SUPPORT_RATE_LIMITED' "$support_limit_second_log" \
  || [[ "$support_limit_event_count" != "5" ]] \
  || [[ "$support_limit_attempt_count" != "2" ]]; then
  echo "De accountlock serializeerde de begrensde supportacties niet correct." >&2
  exit 1
fi

echo "Parent-OTP-concurrency groen: challenge, replay, providerbinding, globale event-ID, support-idempotentie en support-ratelimit zijn atomair verwerkt."
