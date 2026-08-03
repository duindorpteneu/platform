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
SQL

event_time="$("${psql_cmd[@]}" -c \
  "select to_char(clock_timestamp(), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")"

record_event() {
  local attempt_id="$1"
  local event_id="$2"
  local message_id="$3"
  "${psql_cmd[@]}" -c "
    select app.record_parent_otp_sendgrid_events_v1(
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

record_event \
  "e2791000-0000-4000-8000-000000000001" \
  "otp-concurrent-replay" \
  "otp-concurrent-message-1" \
  >"$test_tmp_dir/replay-first.log" 2>&1 &
replay_first_pid=$!
record_event \
  "e2791000-0000-4000-8000-000000000001" \
  "otp-concurrent-replay" \
  "otp-concurrent-message-1" \
  >"$test_tmp_dir/replay-second.log" 2>&1 &
replay_second_pid=$!
wait "$replay_first_pid"
wait "$replay_second_pid"

record_event \
  "e2791000-0000-4000-8000-000000000002" \
  "otp-concurrent-binding-a" \
  "otp-concurrent-message-a" \
  >"$test_tmp_dir/binding-first.log" 2>&1 &
binding_first_pid=$!
record_event \
  "e2791000-0000-4000-8000-000000000002" \
  "otp-concurrent-binding-b" \
  "otp-concurrent-message-b" \
  >"$test_tmp_dir/binding-second.log" 2>&1 &
binding_second_pid=$!
wait "$binding_first_pid"
wait "$binding_second_pid"

replay_output="$test_tmp_dir/replay-output.log"
binding_output="$test_tmp_dir/binding-output.log"
cp "$test_tmp_dir/replay-first.log" "$replay_output"
sed -n '1,$p' "$test_tmp_dir/replay-second.log" >>"$replay_output"
cp "$test_tmp_dir/binding-first.log" "$binding_output"
sed -n '1,$p' "$test_tmp_dir/binding-second.log" >>"$binding_output"

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
if [[ "$event_count" != "2" || "$quarantine_count" != "1" ]]; then
  echo "De OTP-providerledger bevat na de race geen exact resultaat." >&2
  exit 1
fi

echo "Parent-OTP concurrency test passed."
