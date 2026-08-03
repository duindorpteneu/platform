#!/usr/bin/env bash
set -Eeuo pipefail

db_url="${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
auth_user_id="f8000000-0000-4000-8000-000000000001"
member_id="f8000000-0000-4000-8000-000000000002"
article_id="f8000000-0000-4000-8000-000000000003"
rollback_run_id="f8000000-0000-4000-8000-000000000004"
commit_run_id="f8000000-0000-4000-8000-000000000005"
second_commit_run_id="f8000000-0000-4000-8000-000000000006"
release_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
backup_checksum="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

cleanup() {
  set +e
  psql "${db_url}" --no-psqlrc --quiet --set=ON_ERROR_STOP=1 <<SQL
delete from app.audit_logs
where correlation_id in ('${rollback_run_id}'::uuid, '${commit_run_id}'::uuid);
delete from app.audit_logs where correlation_id = '${second_commit_run_id}'::uuid;
delete from app.members where id = '${member_id}'::uuid;
delete from app.articles where id = '${article_id}'::uuid;
delete from app.staff_profiles where auth_user_id = '${auth_user_id}'::uuid;
delete from auth.users where id = '${auth_user_id}'::uuid;
SQL
}
trap cleanup EXIT INT TERM

psql "${db_url}" --no-psqlrc --quiet --set=ON_ERROR_STOP=1 <<SQL
delete from app.audit_logs
where correlation_id in ('${rollback_run_id}'::uuid, '${commit_run_id}'::uuid);
delete from app.audit_logs where correlation_id = '${second_commit_run_id}'::uuid;
delete from app.members where id = '${member_id}'::uuid;
delete from app.articles where id = '${article_id}'::uuid;
delete from app.staff_profiles where auth_user_id = '${auth_user_id}'::uuid;
delete from auth.users where id = '${auth_user_id}'::uuid;

insert into auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
values (
  '${auth_user_id}'::uuid,
  'authenticated',
  'authenticated',
  'cleanup-admin@example.invalid',
  'not-a-login-secret',
  timezone('utc', now()),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  timezone('utc', now()),
  timezone('utc', now())
);

insert into app.staff_profiles (auth_user_id, display_name, role, active)
values ('${auth_user_id}'::uuid, 'Cleanup contractbeheerder', 'beheerder', true);

insert into app.members (id, relation_number, first_name, last_name, email, team, gender)
values (
  '${member_id}'::uuid,
  'CLEANUP-CONTRACT-1',
  'Contract',
  'Testlid',
  'cleanup-parent@example.invalid',
  'Testteam',
  'unknown'
);

insert into app.articles (id, name, code, icon_type)
values ('${article_id}'::uuid, 'Cleanup testartikel', 'CLNTEST', 'package');
SQL

preflight_json="$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --file=scripts/staging/sql/operational-cleanup-preflight.sql
)"
state_digest="$(
  PREFLIGHT_JSON="${preflight_json}" node -e '
    const value = JSON.parse(process.env.PREFLIGHT_JSON);
    if (value.row_counts["app.members"] < 1 || value.row_counts["app.articles"] < 1) process.exit(1);
    if (value.preserved.active_admins < 1 || Object.values(value.blockers).some((count) => count !== 0)) process.exit(1);
    process.stdout.write(value.state_digest);
  '
)"

if psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
  --set=expected_state_digest="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
  --set=release_sha="${release_sha}" \
  --set=cleanup_run_id="${rollback_run_id}" \
  --set=backup_checksum="${backup_checksum}" \
  --set=cleanup_commit=true \
  --file=scripts/staging/sql/operational-cleanup-apply.sql >/dev/null 2>&1; then
  echo "Cleanup accepteerde ten onrechte een verouderde statedigest." >&2
  exit 1
fi

[[ "$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --command="select exists(select 1 from app.members where id = '${member_id}'::uuid)::text"
)" == true ]]

rollback_result="$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --set=expected_state_digest="${state_digest}" \
    --set=release_sha="${release_sha}" \
    --set=cleanup_run_id="${rollback_run_id}" \
    --set=backup_checksum="${backup_checksum}" \
    --set=cleanup_commit=false \
    --file=scripts/staging/sql/operational-cleanup-apply.sql
)"
ROLLBACK_RESULT="${rollback_result}" node -e '
  const value = JSON.parse(process.env.ROLLBACK_RESULT);
  if (value.result !== "rolled_back_test" || value.remaining_operational_rows !== 0) process.exit(1);
'

preserved_after_rollback="$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --command="select (
      exists(select 1 from app.members where id = '${member_id}'::uuid)
      and exists(select 1 from app.articles where id = '${article_id}'::uuid)
      and exists(select 1 from app.staff_profiles where auth_user_id = '${auth_user_id}'::uuid)
      and exists(select 1 from auth.users where id = '${auth_user_id}'::uuid)
      and not exists(select 1 from app.audit_logs where correlation_id = '${rollback_run_id}'::uuid)
    )::text"
)"
[[ "${preserved_after_rollback}" == true ]]

commit_result="$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --set=expected_state_digest="${state_digest}" \
    --set=release_sha="${release_sha}" \
    --set=cleanup_run_id="${commit_run_id}" \
    --set=backup_checksum="${backup_checksum}" \
    --set=cleanup_commit=true \
    --file=scripts/staging/sql/operational-cleanup-apply.sql
)"
COMMIT_RESULT="${commit_result}" node -e '
  const value = JSON.parse(process.env.COMMIT_RESULT);
  if (value.result !== "committed"
    || value.remaining_operational_rows !== 0
    || value.cleanup_audit_rows !== 1
    || value.preserved.active_admins < 1) process.exit(1);
'

postcondition="$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --command="select (
      not exists(select 1 from app.members)
      and not exists(select 1 from app.articles)
      and exists(select 1 from app.staff_profiles where auth_user_id = '${auth_user_id}'::uuid)
      and exists(select 1 from auth.users where id = '${auth_user_id}'::uuid)
      and exists(select 1 from app.audit_logs where correlation_id = '${commit_run_id}'::uuid)
      and exists(select 1 from app.app_settings)
      and exists(select 1 from app.seasons)
      and exists(select 1 from app.mail_templates)
    )::text"
)"
[[ "${postcondition}" == true ]]

empty_preflight_json="$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --file=scripts/staging/sql/operational-cleanup-preflight.sql
)"
empty_state_digest="$(
  PREFLIGHT_JSON="${empty_preflight_json}" node -e '
    const value = JSON.parse(process.env.PREFLIGHT_JSON);
    if (value.total_rows !== 0) process.exit(1);
    process.stdout.write(value.state_digest);
  '
)"
second_result="$(
  psql "${db_url}" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --set=expected_state_digest="${empty_state_digest}" \
    --set=release_sha="${release_sha}" \
    --set=cleanup_run_id="${second_commit_run_id}" \
    --set=backup_checksum="${backup_checksum}" \
    --set=cleanup_commit=true \
    --file=scripts/staging/sql/operational-cleanup-apply.sql
)"
SECOND_RESULT="${second_result}" node -e '
  const value = JSON.parse(process.env.SECOND_RESULT);
  if (value.result !== "committed" || value.removed_rows !== 0 || value.remaining_operational_rows !== 0) process.exit(1);
'

echo "Staging-cleanupcontract geslaagd: rollback behield data; commit wiste 90 tabellen en behield staff/Auth/config."
