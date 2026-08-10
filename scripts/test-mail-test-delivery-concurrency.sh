#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De testmail-racetest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
mkdir -p .tmp
test_tmp_dir="$(mktemp -d .tmp/mail-test-delivery.XXXXXX)"
prepare_first_log="$test_tmp_dir/prepare-first.log"
prepare_second_log="$test_tmp_dir/prepare-second.log"
finalize_first_log="$test_tmp_dir/finalize-first.log"
finalize_second_log="$test_tmp_dir/finalize-second.log"
event_first_log="$test_tmp_dir/event-first.log"
event_second_log="$test_tmp_dir/event-second.log"
collision_first_log="$test_tmp_dir/collision-first.log"
collision_second_log="$test_tmp_dir/collision-second.log"
staff_id="e3330000-0000-4000-8000-000000000001"
request_id="e3330000-0000-4000-8000-000000000002"
fixture_revision_id=""
published_hash=""
delivery_id=""

cleanup() {
  local status=$?
  "${psql_cmd[@]}" \
    -v staff_id="$staff_id" \
    -v request_id="$request_id" \
    -v fixture_revision_id="${fixture_revision_id:-00000000-0000-0000-0000-000000000000}" \
    >/dev/null <<'SQL' || status=1
begin;
set local session_replication_role = replica;
delete from app.audit_logs
where entity_id in (
  select id from private.mail_test_deliveries
  where request_id = :'request_id'::uuid
);
delete from private.mail_test_delivery_provider_quarantine
where delivery_id in (
  select id from private.mail_test_deliveries
  where request_id = :'request_id'::uuid
);
delete from private.mail_test_delivery_provider_events
where delivery_id in (
  select id from private.mail_test_deliveries
  where request_id = :'request_id'::uuid
);
delete from private.mail_test_delivery_provider_acceptances
where delivery_id in (
  select id from private.mail_test_deliveries
  where request_id = :'request_id'::uuid
);
delete from private.mail_test_delivery_outcomes
where delivery_id in (
  select id from private.mail_test_deliveries
  where request_id = :'request_id'::uuid
);
delete from private.mail_test_deliveries
where request_id = :'request_id'::uuid;
delete from app.mail_template_revisions
where id = :'fixture_revision_id'::uuid
  and creation_source = 'system';
delete from app.staff_profiles
where auth_user_id = :'staff_id'::uuid;
set local session_replication_role = origin;
commit;
SQL
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT

setup="$("${psql_cmd[@]}" \
  -v staff_id="$staff_id" \
  -v request_id="$request_id" <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values(:'staff_id'::uuid, 'Testmail concurrency', 'beheerder')
on conflict (auth_user_id) do update
set display_name = excluded.display_name,
    role = excluded.role,
    active = true;

with next_revision as (
  select coalesce(max(revision), 0) + 1 as revision
  from app.mail_template_revisions
  where template_key = 'package_complete'
), inserted as (
  insert into app.mail_template_revisions(
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
    'package_complete',
    next_revision.revision,
    'published',
    'Concurrency testmail',
    'Voorbeeldpakket compleet voor {{member_first_name}}',
    'Fictieve concurrencycontrole voor {{season_name}}.',
    '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Fictieve testinhoud"}]},{"type":"protectedBlock","attrs":{"kind":"full_package"}}]}'::jsonb,
    '<p>Fictieve testinhoud</p><table><tbody><tr><td>Voorbeeldproduct</td></tr></tbody></table>',
    'Fictieve testinhoud met het volledige voorbeeldpakket.',
    private.mail_template_content_hash(
      'package_complete',
      'Concurrency testmail',
      'Voorbeeldpakket compleet voor {{member_first_name}}',
      'Fictieve concurrencycontrole voor {{season_name}}.',
      '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Fictieve testinhoud"}]},{"type":"protectedBlock","attrs":{"kind":"full_package"}}]}'::jsonb,
      '<p>Fictieve testinhoud</p><table><tbody><tr><td>Voorbeeldproduct</td></tr></tbody></table>',
      'Fictieve testinhoud met het volledige voorbeeldpakket.'
    ),
    'system',
    statement_timestamp()
  from next_revision
  where not exists (
    select 1 from app.mail_template_revisions
    where template_key = 'package_complete'
      and status = 'published'
  )
  returning id, content_hash
)
select concat_ws(
  '|',
  coalesce((select id::text from inserted), ''),
  coalesce(
    (select content_hash from inserted),
    (
    select content_hash
    from app.mail_template_revisions
    where template_key = 'package_complete'
      and status = 'published'
    )
  )
);
SQL
)"
IFS='|' read -r fixture_revision_id published_hash <<<"$setup"
if [[ ! "$published_hash" =~ ^[0-9a-f]{64}$ ]]; then
  echo "De gepubliceerde testtemplate kon niet veilig worden voorbereid." >&2
  exit 1
fi

run_prepare() {
  local hold_seconds="$1"
  "${psql_cmd[@]}" \
    -v staff_id="$staff_id" \
    -v request_id="$request_id" \
    -v published_hash="$published_hash" \
    -v hold_seconds="$hold_seconds" <<'SQL'
begin;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'staff_id', 'aal', 'aal2')::text,
  true
);
set local role authenticated;
select app.prepare_mail_test_delivery_v1(
  :'request_id'::uuid,
  'package_complete',
  :'published_hash',
  null
)->>'reused';
select pg_sleep(:'hold_seconds'::numeric);
commit;
SQL
}

run_prepare 1 >"$prepare_first_log" 2>&1 &
first_pid=$!
for _ in {1..100}; do
  grep -qx 'false' "$prepare_first_log" 2>/dev/null && break
  sleep 0.02
done
run_prepare 0 >"$prepare_second_log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

prepare_total="$(awk '/^(false|true)$/{count++} END{print count+0}' "$prepare_first_log" "$prepare_second_log")"
prepare_false="$(awk '/^false$/{count++} END{print count+0}' "$prepare_first_log" "$prepare_second_log")"
prepare_true="$(awk '/^true$/{count++} END{print count+0}' "$prepare_first_log" "$prepare_second_log")"
if [[ "$prepare_total" -ne 2 ]] \
  || [[ "$prepare_false" -ne 1 ]] \
  || [[ "$prepare_true" -ne 1 ]]; then
  echo "De request-ID-race leverde niet exact één verzendbare voorbereiding op." >&2
  exit 1
fi

delivery_id="$("${psql_cmd[@]}" -v request_id="$request_id" <<'SQL'
select id
from private.mail_test_deliveries
where request_id = :'request_id'::uuid;
SQL
)"
if [[ ! "$delivery_id" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "De testdelivery-identiteit ontbreekt na de voorbereiding." >&2
  exit 1
fi

run_finalize() {
  local hold_seconds="$1"
  "${psql_cmd[@]}" \
    -v staff_id="$staff_id" \
    -v delivery_id="$delivery_id" \
    -v hold_seconds="$hold_seconds" <<'SQL'
begin;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'staff_id', 'aal', 'aal2')::text,
  true
);
set local role authenticated;
select app.finalize_mail_test_delivery_v2(
  :'delivery_id'::uuid,
  'accepted',
  'concurrency-http-message',
  null
)->>'reused';
select pg_sleep(:'hold_seconds'::numeric);
commit;
SQL
}

run_finalize 1 >"$finalize_first_log" 2>&1 &
first_pid=$!
for _ in {1..100}; do
  grep -qx 'false' "$finalize_first_log" 2>/dev/null && break
  sleep 0.02
done
run_finalize 0 >"$finalize_second_log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

finalize_total="$(awk '/^(false|true)$/{count++} END{print count+0}' "$finalize_first_log" "$finalize_second_log")"
finalize_false="$(awk '/^false$/{count++} END{print count+0}' "$finalize_first_log" "$finalize_second_log")"
finalize_true="$(awk '/^true$/{count++} END{print count+0}' "$finalize_first_log" "$finalize_second_log")"
if [[ "$finalize_total" -ne 2 ]] \
  || [[ "$finalize_false" -ne 1 ]] \
  || [[ "$finalize_true" -ne 1 ]]; then
  echo "De outcome-race leverde niet exact één immutable uitkomst op." >&2
  exit 1
fi

ledger_counts="$("${psql_cmd[@]}" -v request_id="$request_id" <<'SQL'
select concat_ws(
    '|',
    (
      select count(*)
      from private.mail_test_deliveries delivery
      where delivery.request_id = :'request_id'::uuid
    ),
    (
      select count(*)
      from private.mail_test_delivery_outcomes outcome
      join private.mail_test_deliveries delivery
        on delivery.id = outcome.delivery_id
      where delivery.request_id = :'request_id'::uuid
    )
  );
SQL
)"
if [[ "$ledger_counts" != "1|1" ]]; then
  echo "De testmail-ledger bevat niet exact één intent en één outcome." >&2
  exit 1
fi

event_occurred_at="$("${psql_cmd[@]}" -v delivery_id="$delivery_id" <<'SQL'
select created_at + interval '1 second'
from private.mail_test_deliveries
where id = :'delivery_id'::uuid;
SQL
)"

run_provider_event() {
  local event_id="$1"
  local message_id="$2"
  local hold_seconds="$3"
  "${psql_cmd[@]}" \
    -v delivery_id="$delivery_id" \
    -v event_id="$event_id" \
    -v message_id="$message_id" \
    -v occurred_at="$event_occurred_at" \
    -v hold_seconds="$hold_seconds" <<'SQL'
begin;
select concat_ws(
  '|',
  recorded.payload->>'recorded',
  recorded.payload->>'ignored',
  recorded.payload->>'quarantined'
)
from (
  select app.record_mail_test_sendgrid_events_v4(
    jsonb_build_array(
      jsonb_build_object(
        'delivery_id', :'delivery_id',
        'event_id', :'event_id',
        'provider_message_id', :'message_id',
        'event_type', 'delivered',
        'occurred_at', :'occurred_at'
      )
    )
  ) as payload
) recorded;
select pg_sleep(:'hold_seconds'::numeric);
commit;
SQL
}

run_provider_event \
  "concurrency-identical-event" \
  "concurrency-http-message.filter0001.42.0" \
  1 >"$event_first_log" 2>&1 &
first_pid=$!
for _ in {1..100}; do
  grep -qx '1|0|0' "$event_first_log" 2>/dev/null && break
  sleep 0.02
done
run_provider_event \
  "concurrency-identical-event" \
  "concurrency-http-message.filter0001.42.0" \
  0 >"$event_second_log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
identical_total="$(awk '/^(1\|0\|0|0\|1\|0)$/{count++} END{print count+0}' \
  "$event_first_log" "$event_second_log")"
identical_recorded="$(awk '/^1\|0\|0$/{count++} END{print count+0}' \
  "$event_first_log" "$event_second_log")"
identical_ignored="$(awk '/^0\|1\|0$/{count++} END{print count+0}' \
  "$event_first_log" "$event_second_log")"
if [[ "$identical_total" -ne 2 ]] \
  || [[ "$identical_recorded" -ne 1 ]] \
  || [[ "$identical_ignored" -ne 1 ]]; then
  echo "Identieke provider-eventreplay is niet deterministisch verwerkt." >&2
  exit 1
fi

run_provider_event \
  "concurrency-collision-event" \
  "concurrency-http-message.filter0001.43.0" \
  1 >"$collision_first_log" 2>&1 &
first_pid=$!
for _ in {1..100}; do
  grep -qx '1|0|0' "$collision_first_log" 2>/dev/null && break
  sleep 0.02
done
run_provider_event \
  "concurrency-collision-event" \
  "concurrency-http-message.filter0002.44.0" \
  0 >"$collision_second_log" 2>&1 &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
collision_recorded="$(awk '/^1\|0\|0$/{count++} END{print count+0}' \
  "$collision_first_log" "$collision_second_log")"
collision_quarantined="$(awk '/^0\|0\|1$/{count++} END{print count+0}' \
  "$collision_first_log" "$collision_second_log")"
if [[ "$collision_recorded" -ne 1 ]] \
  || [[ "$collision_quarantined" -ne 1 ]]; then
  echo "Provider-event-ID-collision is niet atomisch gequarantaineerd." >&2
  exit 1
fi

provider_ledger_counts="$("${psql_cmd[@]}" \
  -v delivery_id="$delivery_id" <<'SQL'
select concat_ws(
  '|',
  (
    select count(*)
    from private.mail_test_delivery_provider_events
    where delivery_id = :'delivery_id'::uuid
  ),
  (
    select count(*)
    from private.mail_test_delivery_provider_quarantine
    where delivery_id = :'delivery_id'::uuid
      and reason = 'event_identity_collision'
  )
);
SQL
)"
if [[ "$provider_ledger_counts" != "2|1" ]]; then
  echo "Provider-eventledger mist event- of quarantainerecords." >&2
  exit 1
fi

echo "Testmailconcurrency groen: één voorbereiding/outcome, deterministische replay en duurzame event-ID-collision."
