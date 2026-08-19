#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De e-mailattempt-racetest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-email-attempt.XXXXXX)"
replay_marker="$test_tmp_dir/replay-holding"
binding_marker="$test_tmp_dir/binding-holding"
replay_first_log="$test_tmp_dir/replay-first.log"
replay_second_log="$test_tmp_dir/replay-second.log"
binding_first_log="$test_tmp_dir/binding-first.log"
binding_second_log="$test_tmp_dir/binding-second.log"
identity_marker="$test_tmp_dir/identity-holding"
identity_first_log="$test_tmp_dir/identity-first.log"
identity_second_log="$test_tmp_dir/identity-second.log"

cleanup_data() {
  "${psql_cmd[@]}" >/dev/null <<'SQL'
begin;
set local session_replication_role = replica;

delete from private.email_provider_event_quarantine
where email_job_id in (
  'e2773000-0000-4000-8000-000000000001',
  'e2773000-0000-4000-8000-000000000002'
);
delete from app.email_events
where email_job_id in (
  'e2773000-0000-4000-8000-000000000001',
  'e2773000-0000-4000-8000-000000000002'
);
delete from private.email_delivery_attempt_provider_messages
where delivery_attempt_id in (
  select id
  from private.email_delivery_attempts
  where email_job_id in (
    'e2773000-0000-4000-8000-000000000001',
    'e2773000-0000-4000-8000-000000000002'
  )
);
delete from private.email_delivery_attempt_outcomes
where delivery_attempt_id in (
  select id
  from private.email_delivery_attempts
  where email_job_id in (
    'e2773000-0000-4000-8000-000000000001',
    'e2773000-0000-4000-8000-000000000002'
  )
);
update private.email_jobs
set current_delivery_attempt_id = null
where id in (
  'e2773000-0000-4000-8000-000000000001',
  'e2773000-0000-4000-8000-000000000002'
);
delete from private.email_delivery_attempts
where email_job_id in (
  'e2773000-0000-4000-8000-000000000001',
  'e2773000-0000-4000-8000-000000000002'
);
delete from private.email_jobs
where id in (
  'e2773000-0000-4000-8000-000000000001',
  'e2773000-0000-4000-8000-000000000002'
);
delete from app.member_package_size_selections
where assignment_id in (
  select id
  from app.member_package_assignments
  where order_id = 'e2772000-0000-4000-8000-000000000001'
);
delete from app.member_package_assignments
where order_id = 'e2772000-0000-4000-8000-000000000001';
delete from app.order_package_snapshot_items
where snapshot_id in (
  select id
  from app.order_package_snapshots
  where order_id = 'e2772000-0000-4000-8000-000000000001'
);
delete from app.order_package_snapshots
where order_id = 'e2772000-0000-4000-8000-000000000001';
delete from app.member_orders
where id = 'e2772000-0000-4000-8000-000000000001';
delete from app.member_seasons
where member_id = 'e2771000-0000-4000-8000-000000000001';
delete from private.member_sensitive_identity
where member_id = 'e2771000-0000-4000-8000-000000000001';
delete from app.members
where id = 'e2771000-0000-4000-8000-000000000001';

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
insert into app.members(
  id,
  relation_number,
  first_name,
  last_name,
  email,
  team
) values (
  'e2771000-0000-4000-8000-000000000001',
  'ATTEMPT-RACE',
  'Race',
  'Attempt',
  'attempt-race@example.invalid',
  'TEST'
);
insert into app.member_orders(
  id,
  member_id,
  season_id,
  amount_due_cents
)
select
  'e2772000-0000-4000-8000-000000000001',
  'e2771000-0000-4000-8000-000000000001',
  settings.active_season_id,
  100
from app.app_settings settings
where settings.id = true;
insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  template_id,
  order_id,
  idempotency_key,
  payload,
  created_at
)
select
  job_id,
  'transactional',
  'attempt-race@example.invalid',
  'payment_received',
  template.id,
  'e2772000-0000-4000-8000-000000000001',
  'delivery-attempt-concurrency-' || slot,
  '{}'::jsonb,
  statement_timestamp() + (slot || ' milliseconds')::interval
from app.email_templates template
cross join (
  values
    (1, 'e2773000-0000-4000-8000-000000000001'::uuid),
    (2, 'e2773000-0000-4000-8000-000000000002'::uuid)
) jobs(slot, job_id)
where template.template_key = 'payment_received';
SQL

first_attempt="$("${psql_cmd[@]}" -c "
  select app.claim_email_jobs_v4(
    'e2774000-0000-4000-8000-000000000001',
    1
  ) #>> '{jobs,0,deliveryAttemptId}'
")"
second_attempt="$("${psql_cmd[@]}" -c "
  select app.claim_email_jobs_v4(
    'e2774000-0000-4000-8000-000000000002',
    1
  ) #>> '{jobs,0,deliveryAttemptId}'
")"
if [[ -z "$first_attempt" || -z "$second_attempt" ]]; then
  echo "De attempt-racefixture kon niet worden geclaimd." >&2
  exit 1
fi
first_claim_token="$("${psql_cmd[@]}" -c "
  select claim_token
  from private.email_jobs
  where id = 'e2773000-0000-4000-8000-000000000001'
")"
second_claim_token="$("${psql_cmd[@]}" -c "
  select claim_token
  from private.email_jobs
  where id = 'e2773000-0000-4000-8000-000000000002'
")"
if [[ -z "$first_claim_token" || -z "$second_claim_token" ]]; then
  echo "De attempt-racefixture mist een claimtoken." >&2
  exit 1
fi
"${psql_cmd[@]}" >/dev/null <<SQL
select app.complete_email_job_v2(
  'e2773000-0000-4000-8000-000000000001',
  '$first_claim_token',
  '$first_attempt',
  'sent',
  'attempt-http-message-1',
  null
);
select app.complete_email_job_v2(
  'e2773000-0000-4000-8000-000000000002',
  '$second_claim_token',
  '$second_attempt',
  'sent',
  'attempt-http-message-2',
  null
);
SQL
event_time="$("${psql_cmd[@]}" -c \
  "select to_char(clock_timestamp(), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")"

record_event() {
  local attempt_id="$1"
  local job_id="$2"
  local event_id="$3"
  local message_id="$4"
  "${psql_cmd[@]}" -c "
    select app.record_sendgrid_events_v4(jsonb_build_array(
      jsonb_build_object(
        'email_job_id', '$job_id',
        'delivery_attempt_id', '$attempt_id',
        'event_id', '$event_id',
        'provider_message_id', '$message_id',
        'event_type', 'delivered',
        'occurred_at', '$event_time'
      )
    ));
  "
}

replay_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select app.record_sendgrid_events_v4(jsonb_build_array(
  jsonb_build_object(
    'email_job_id', 'e2773000-0000-4000-8000-000000000001',
    'delivery_attempt_id', '$first_attempt',
    'event_id', 'attempt-concurrent-replay',
    'provider_message_id', 'attempt-http-message-1.filter0001.42.0',
    'event_type', 'delivered',
    'occurred_at', '$event_time'
  )
));
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
  echo "De replaybarrière werd niet bereikt." >&2
  exit 1
fi
record_event \
  "$first_attempt" \
  "e2773000-0000-4000-8000-000000000001" \
  "attempt-concurrent-replay" \
  "attempt-http-message-1.filter0001.42.0" \
  >"$replay_second_log" 2>&1 &
replay_second_pid=$!
wait "$replay_first_pid"
wait "$replay_second_pid"

binding_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select app.record_sendgrid_events_v4(jsonb_build_array(
  jsonb_build_object(
    'email_job_id', 'e2773000-0000-4000-8000-000000000002',
    'delivery_attempt_id', '$second_attempt',
    'event_id', 'attempt-concurrent-binding-1',
    'provider_message_id', 'attempt-http-message-2.filter0001.42.0',
    'event_type', 'delivered',
    'occurred_at', '$event_time'
  )
));
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
  echo "De berichtbindingsbarrière werd niet bereikt." >&2
  exit 1
fi
record_event \
  "$second_attempt" \
  "e2773000-0000-4000-8000-000000000002" \
  "attempt-concurrent-binding-2" \
  "attempt-http-message-2.filter0002.43.0" \
  >"$binding_second_log" 2>&1 &
binding_second_pid=$!
wait "$binding_first_pid"
wait "$binding_second_pid"

if ! grep -q '"recorded": 1' "$replay_first_log" \
  || ! grep -q '"ignored": 1' "$replay_second_log"; then
  echo "Gelijktijdige exacte replay was niet één insert plus één idempotente replay." >&2
  exit 1
fi
if ! grep -q '"recorded": 1' "$binding_first_log" \
  || ! grep -q '"quarantined": 1' "$binding_second_log"; then
  echo "Gelijktijdige providerberichtcollisie werd niet fail-closed verwerkt." >&2
  exit 1
fi

second_bound_message="$("${psql_cmd[@]}" -c "
  select provider_message_id
  from private.email_delivery_attempt_provider_messages
  where delivery_attempt_id = '$second_attempt';
")"
if [[ -z "$second_bound_message" ]]; then
  echo "De tweede attempt mist een immutable providerbinding." >&2
  exit 1
fi

identity_first() {
  "${psql_cmd[@]}" <<SQL
begin;
select app.record_sendgrid_events_v4(jsonb_build_array(
  jsonb_build_object(
    'email_job_id', 'e2773000-0000-4000-8000-000000000001',
    'delivery_attempt_id', '$first_attempt',
    'event_id', 'attempt-global-event-collision',
    'provider_message_id', 'attempt-http-message-1.filter0001.42.0',
    'event_type', 'delivered',
    'occurred_at', '$event_time'
  )
));
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
  echo "De globale event-ID-barrière werd niet bereikt." >&2
  exit 1
fi
record_event \
  "$second_attempt" \
  "e2773000-0000-4000-8000-000000000002" \
  "attempt-global-event-collision" \
  "$second_bound_message" \
  >"$identity_second_log" 2>&1 &
identity_second_pid=$!
wait "$identity_first_pid"
wait "$identity_second_pid"
if ! grep -q '"recorded": 1' "$identity_first_log" \
  || ! grep -q '"quarantined": 1' "$identity_second_log"; then
  echo "Globale provider-event-ID-collision werd niet atomisch gequarantaineerd." >&2
  exit 1
fi

final_state="$("${psql_cmd[@]}" -F ':' -c "
select
  (select count(*) from app.email_events
    where email_job_id='e2773000-0000-4000-8000-000000000001'),
  (select count(*) from app.email_events
    where email_job_id='e2773000-0000-4000-8000-000000000002'),
  (select count(*) from private.email_provider_event_quarantine
    where email_job_id='e2773000-0000-4000-8000-000000000002'),
  (select count(*) from private.email_delivery_attempt_provider_messages
    where delivery_attempt_id='$second_attempt'),
  (select count(*) from private.email_provider_event_quarantine
    where email_job_id='e2773000-0000-4000-8000-000000000002'
      and reason='event_message_mismatch'),
  (select count(*) from private.email_provider_event_quarantine
    where email_job_id='e2773000-0000-4000-8000-000000000002'
      and reason='event_identity_collision');
")"
if [[ "$final_state" != "2:1:2:1:1:1" ]]; then
  echo "Onveilige finale attempt-racestatus: $final_state" >&2
  exit 1
fi

echo "E-mailattempt-concurrencytest geslaagd: replay, providerbinding en globale event-ID zijn atomair verwerkt."
