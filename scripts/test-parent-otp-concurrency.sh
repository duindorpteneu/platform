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
replay_first_log="$test_tmp_dir/replay-first.log"
replay_second_log="$test_tmp_dir/replay-second.log"
binding_first_log="$test_tmp_dir/binding-first.log"
binding_second_log="$test_tmp_dir/binding-second.log"
identity_first_log="$test_tmp_dir/identity-first.log"
identity_second_log="$test_tmp_dir/identity-second.log"

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
  'e2791000-0000-4000-8000-000000000001',
  'e2791000-0000-4000-8000-000000000002'
);
delete from private.parent_otp_delivery_attempts
where id in (
  'e2791000-0000-4000-8000-000000000001',
  'e2791000-0000-4000-8000-000000000002'
);
delete from private.parent_accounts
where id = 'e2790000-0000-4000-8000-000000000001';
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
values(
  'e2790000-0000-4000-8000-000000000001',
  'otp-concurrency@example.invalid'
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
  and template_revision.status = 'draft'
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

if [[ "$(rg -c '"recorded": 1' "$replay_output")" -ne 1 ]] \
  || [[ "$(rg -c '"ignored": 1' "$replay_output")" -ne 1 ]]; then
  echo "Exacte parallelle OTP-replay was niet één insert plus één no-op." >&2
  exit 1
fi
if [[ "$(rg -c '"recorded": 1' "$binding_output")" -ne 1 ]] \
  || [[ "$(rg -c '"quarantined": 1' "$binding_output")" -ne 1 ]]; then
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
if ! rg -q '"recorded": 1' "$identity_first_log" \
  || ! rg -q '"quarantined": 1' "$identity_second_log"; then
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

echo "Parent-OTP-concurrency groen: replay, providerbinding en globale event-ID zijn atomair verwerkt."
