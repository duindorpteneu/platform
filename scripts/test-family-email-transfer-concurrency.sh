#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *) echo "De gezins-e-mailracetest mag uitsluitend lokaal draaien." >&2; exit 2 ;;
esac

psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1)
test_tmp_dir="$(mktemp -d -t duindorp-family-email.XXXXXX)"
first_log="$test_tmp_dir/first.log"
second_log="$test_tmp_dir/second.log"
first_holding="$test_tmp_dir/first-holding"
previous_active_season="$("${psql_cmd[@]}" -Atc "select coalesce(active_season_id::text, '') from app.app_settings where id = true")"

cleanup_data() {
  "${psql_cmd[@]}" >/dev/null <<'SQL'
set session_replication_role = replica;
delete from private.member_profile_edit_requests where request_id in (
  'ea600000-0000-4000-8000-000000000001','ea600000-0000-4000-8000-000000000002'
);
delete from app.audit_logs where actor_user_id = 'ea000000-0000-4000-8000-000000000001';
delete from private.parent_portal_grants where member_season_id in (
  'ea300000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000002'
);
delete from private.parent_member_links where member_id in (
  'ea200000-0000-4000-8000-000000000001','ea200000-0000-4000-8000-000000000002'
);
delete from private.parent_otp_challenges where parent_account_id = 'ea400000-0000-4000-8000-000000000001';
delete from private.parent_sessions where parent_account_id = 'ea400000-0000-4000-8000-000000000001';
delete from private.parent_accounts where id = 'ea400000-0000-4000-8000-000000000001';
delete from private.member_sensitive_identity where member_id in (
  'ea200000-0000-4000-8000-000000000001','ea200000-0000-4000-8000-000000000002'
);
delete from app.member_seasons where id in (
  'ea300000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000002'
);
delete from app.members where id in (
  'ea200000-0000-4000-8000-000000000001','ea200000-0000-4000-8000-000000000002'
);
delete from app.inventory_settings where season_id = 'ea100000-0000-4000-8000-000000000001';
delete from app.seasons where id = 'ea100000-0000-4000-8000-000000000001';
delete from app.staff_profiles where auth_user_id = 'ea000000-0000-4000-8000-000000000001';
set session_replication_role = origin;
SQL
}

cleanup() {
  local status=$?
  cleanup_data || status=1
  if [[ "$previous_active_season" =~ ^[0-9a-f-]{36}$ ]]; then
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id = '$previous_active_season'::uuid where id = true" >/dev/null || status=1
  else
    "${psql_cmd[@]}" -c "update app.app_settings set active_season_id = null where id = true" >/dev/null || status=1
  fi
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT INT TERM
cleanup_data

"${psql_cmd[@]}" >/dev/null <<'SQL'
insert into app.staff_profiles(auth_user_id, display_name, role)
values('ea000000-0000-4000-8000-000000000001', 'Gezinsracebeheerder', 'beheerder');
insert into app.seasons(id, name, default_amount_cents, status)
values('ea100000-0000-4000-8000-000000000001', 'Gezinsraceseizoen', 10000, 'open');
update app.app_settings set active_season_id = 'ea100000-0000-4000-8000-000000000001' where id = true;
insert into app.members(id, relation_number, first_name, last_name, email, team, active_for_season) values
  ('ea200000-0000-4000-8000-000000000001','FAM-RACE-1','Alice','Race','afwijkend@example.invalid','MO11-1',true),
  ('ea200000-0000-4000-8000-000000000002','FAM-RACE-2','Bo','Race','afwijkend@example.invalid','JO13-1',true);
update app.member_seasons set id = 'ea300000-0000-4000-8000-000000000001'
where member_id = 'ea200000-0000-4000-8000-000000000001' and season_id = 'ea100000-0000-4000-8000-000000000001';
update app.member_seasons set id = 'ea300000-0000-4000-8000-000000000002'
where member_id = 'ea200000-0000-4000-8000-000000000002' and season_id = 'ea100000-0000-4000-8000-000000000001';
insert into private.parent_accounts(id, email_normalized)
values('ea400000-0000-4000-8000-000000000001','canoniek@example.invalid');
insert into private.parent_portal_grants(
  id,member_season_id,email_normalized,parent_account_id,status,source,granted_by,granted_at
) values
  ('ea500000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000001','canoniek@example.invalid','ea400000-0000-4000-8000-000000000001','active','administrator','ea000000-0000-4000-8000-000000000001',timezone('utc',now())),
  ('ea500000-0000-4000-8000-000000000002','ea300000-0000-4000-8000-000000000002','canoniek@example.invalid','ea400000-0000-4000-8000-000000000001','active','administrator','ea000000-0000-4000-8000-000000000001',timezone('utc',now()));
SQL

read_preview() {
  local member_id="$1" member_season_id="$2"
  "${psql_cmd[@]}" -At <<SQL
begin;
set local role authenticated;
select concat_ws('|',detail->>'profileRevision',preview->>'familyRevision')
from (select set_config('request.jwt.claims','{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',true)) auth_context
cross join lateral (select app.get_member_detail_v6('$member_id'::uuid) detail) current_detail
cross join lateral (
  select app.preview_member_family_email_transfer_v1(
    '$member_id'::uuid,'$member_season_id'::uuid,'canoniek@example.invalid',
    current_detail.detail->>'profileRevision'
  ) preview
) family_preview;
rollback;
SQL
}

first_revisions="$(read_preview 'ea200000-0000-4000-8000-000000000001' 'ea300000-0000-4000-8000-000000000001')"
second_revisions="$(read_preview 'ea200000-0000-4000-8000-000000000002' 'ea300000-0000-4000-8000-000000000002')"
IFS='|' read -r first_profile_revision first_family_revision <<<"$first_revisions"
IFS='|' read -r second_profile_revision second_family_revision <<<"$second_revisions"

run_update() {
  local member_id="$1" member_season_id="$2" first_name="$3" team="$4"
  local profile_revision="$5" family_revision="$6" request_id="$7" hold_marker="${8:-}"
  "${psql_cmd[@]}" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"ea000000-0000-4000-8000-000000000001","aal":"aal2"}',true);
select app.update_member_profile_v2(
  '$member_id'::uuid,'$member_season_id'::uuid,'$first_name',null,'Race',
  'canoniek@example.invalid',null,'unknown','$team','$profile_revision','$family_revision',
  'Gelijktijdige gezinscorrectie','$request_id'::uuid,null
);
$(if [[ -n "$hold_marker" ]]; then printf '\\! touch "%s"\nselect pg_sleep(2);' "$hold_marker"; fi)
commit;
SQL
}

run_update 'ea200000-0000-4000-8000-000000000001' 'ea300000-0000-4000-8000-000000000001' \
  'Alice' 'MO11-1' "$first_profile_revision" "$first_family_revision" \
  'ea600000-0000-4000-8000-000000000001' "$first_holding" >"$first_log" 2>&1 &
first_pid=$!
for _ in $(seq 1 100); do
  [[ -f "$first_holding" ]] && break
  kill -0 "$first_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ ! -f "$first_holding" ]]; then
  sed -n '1,160p' "$first_log" >&2
  echo "De eerste gezinstransactie bereikte de lockbarrière niet." >&2
  exit 1
fi

set +e
run_update 'ea200000-0000-4000-8000-000000000002' 'ea300000-0000-4000-8000-000000000002' \
  'Bo' 'JO13-1' "$second_profile_revision" "$second_family_revision" \
  'ea600000-0000-4000-8000-000000000002' >"$second_log" 2>&1
second_status=$?
set -e
wait "$first_pid"
if [[ "$second_status" -eq 0 ]] || ! grep -Eq 'MEMBER_PROFILE_STALE|MEMBER_FAMILY_EMAIL_STALE' "$second_log"; then
  echo "De tweede siblingtransfer faalde niet gecontroleerd op stale state." >&2
  exit 1
fi

final_state="$("${psql_cmd[@]}" -Atc "
select concat_ws('|',
  count(*) filter(where email='canoniek@example.invalid'),
  (select count(*) from private.member_profile_edit_requests where request_id in ('ea600000-0000-4000-8000-000000000001','ea600000-0000-4000-8000-000000000002')),
  (select count(*) from private.parent_portal_grants where member_season_id in ('ea300000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000002') and status='active')
) from app.members where id in ('ea200000-0000-4000-8000-000000000001','ea200000-0000-4000-8000-000000000002');")"
if [[ "$final_state" != "2|1|2" ]]; then
  echo "De siblingrace eindigde niet canoniek: $final_state" >&2
  exit 1
fi
echo "Gezins-e-mailconcurrency geslaagd: één commit, één stale loser en één consistente familie."
