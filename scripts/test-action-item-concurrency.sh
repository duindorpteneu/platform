#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1)
task_tmp="$(mktemp -d)"
first_log="${task_tmp}/first.log"
second_log="${task_tmp}/second.log"

cleanup_data() {
  "${psql_cmd[@]}" <<'SQL'
delete from app.action_items
where season_id = 'ad100000-0000-4000-8000-000000000001';
delete from app.seasons
where id = 'ad100000-0000-4000-8000-000000000001';
SQL
}

cleanup() {
  status=$?
  cleanup_data >/dev/null 2>&1 || status=1
  rm -f "$first_log" "$second_log"
  rmdir "$task_tmp"
  exit "$status"
}
trap cleanup EXIT

cleanup_data
"${psql_cmd[@]}" <<'SQL'
insert into app.seasons(id, name, default_amount_cents, status)
values (
  'ad100000-0000-4000-8000-000000000001',
  'Action-item concurrency',
  10000,
  'open'
);
SQL

open_action() {
  local hold_seconds="$1"
  "${psql_cmd[@]}" -At <<SQL
begin;
select private.open_action_item(
  'allocation_conflict',
  'ad100000-0000-4000-8000-000000000001',
  'order_item',
  'ad200000-0000-4000-8000-000000000001',
  'allocation',
  null,
  encode(extensions.digest('action-item-concurrency-condition', 'sha256'), 'hex'),
  'warning',
  'operations',
  'allocation_state_conflict',
  '{"sourceRow":1}'::jsonb,
  null
);
select pg_sleep(${hold_seconds});
commit;
SQL
}

set +e
open_action 2 >"$first_log" 2>&1 &
first_pid=$!
sleep 0.2
open_action 0 >"$second_log" 2>&1 &
second_pid=$!
wait "$first_pid"
first_status=$?
wait "$second_pid"
second_status=$?
set -e

if [[ "$first_status" -ne 0 ]]; then
  tail -n 40 "$first_log"
  exit 1
fi
if [[ "$second_status" -ne 0 ]]; then
  tail -n 40 "$second_log"
  exit 1
fi

first_id="$(grep -Eo '[0-9a-f]{8}-[0-9a-f-]{27}' "$first_log" | head -n 1)"
second_id="$(grep -Eo '[0-9a-f]{8}-[0-9a-f-]{27}' "$second_log" | head -n 1)"
if [[ -z "$first_id" || "$first_id" != "$second_id" ]]; then
  echo "Gelijktijdige action-itemcalls retourneerden niet hetzelfde item." >&2
  exit 1
fi

result="$("${psql_cmd[@]}" -Atc "
  select count(*) || ':' || min(episode)::text
  from app.action_items
  where season_id = 'ad100000-0000-4000-8000-000000000001'
    and status in ('open', 'in_progress')
")"
if [[ "$result" != "1:1" ]]; then
  echo "Onverwacht action-itemconcurrencyresultaat: $result" >&2
  exit 1
fi

echo "Action-itemconcurrencytest geslaagd: gelijktijdige signalen leveren één actieve episode."
