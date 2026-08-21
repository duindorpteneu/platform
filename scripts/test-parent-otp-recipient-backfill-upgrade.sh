#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_url="postgresql://postgres:postgres@127.0.0.1:54339/postgres"
psql_cmd=(psql "$database_url" -X -q -v ON_ERROR_STOP=1 -At)
reset_log="$(mktemp)"
restored=false

restore_latest() {
  if [[ "$restored" == true ]]; then return; fi
  if ! (cd "$repository_root" && pnpm db:reset >"$reset_log" 2>&1); then
    tail -n 80 "$reset_log" >&2
    echo "Kon de lokale database na de OTP-recipientupgradetest niet herstellen." >&2
    return 1
  fi
  restored=true
}

cleanup() {
  local status=$?
  restore_latest || status=1
  rm -f "$reset_log"
  exit "$status"
}
trap cleanup EXIT

identity="$("${psql_cmd[@]}" -c "
  select concat_ws('|', current_database(), current_user, inet_server_port()::text)
")"
if [[ "$identity" != "postgres|postgres|5432" ]]; then
  echo "OTP-recipientupgradetest weigert onverwachte database-identiteit." >&2
  exit 1
fi

cd "$repository_root"
node scripts/run-supabase.mjs db reset --local \
  --version 20260821161500 --no-seed

"${psql_cmd[@]}" <<'SQL'
insert into private.parent_accounts(id, email_normalized)
values (
  'b6150000-0000-4000-8000-000000000001',
  'otp-backfill@example.invalid'
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
  'b6150000-0000-4000-8000-000000000002',
  'b6150000-0000-4000-8000-000000000001',
  'b6150000-0000-4000-8000-000000000003',
  template_revision.id,
  branding_revision.id,
  statement_timestamp() + interval '10 minutes'
from app.mail_template_revisions template_revision
cross join app.mail_branding_revisions branding_revision
where template_revision.template_key = 'login_otp'
  and branding_revision.status = 'published'
limit 1;
SQL

"${psql_cmd[@]}" <<'SQL'
begin;
alter table private.parent_otp_delivery_attempts
  add column recipient_identity_id uuid;
update private.parent_otp_delivery_attempts
set recipient_identity_id = 'b6150000-0000-4000-8000-000000000004'
where id = 'b6150000-0000-4000-8000-000000000002';
rollback;

insert into private.migration_reconciliations(
  migration_key,
  status,
  metrics
) values (
  '20260821162000_email_recipient_health',
  'passed',
  '{}'::jsonb
);
SQL

set +e
"${psql_cmd[@]}" <<'SQL' >"$reset_log" 2>&1
begin;
alter table private.parent_otp_delivery_attempts
  add column recipient_identity_id uuid;
update private.parent_otp_delivery_attempts
set recipient_identity_id = 'b6150000-0000-4000-8000-000000000004'
where id = 'b6150000-0000-4000-8000-000000000002';
SQL
self_disabled_status=$?
set -e
if [[ "$self_disabled_status" -eq 0 ]] \
  || ! grep -q 'PARENT_OTP_DELIVERY_LEDGER_IMMUTABLE' "$reset_log"; then
  echo "De tijdelijke OTP-ledgerguard sloot niet op de backfillreconciliatie." >&2
  exit 1
fi

"${psql_cmd[@]}" -c "
  delete from private.migration_reconciliations
  where migration_key = '20260821162000_email_recipient_health';
"

node scripts/run-supabase.mjs migration up --local >/dev/null

result="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    identity.email_normalized,
    allow_reconciliation.status,
    restore_reconciliation.status,
    (attempt.recipient_identity_id is not null)::text
  )
  from private.parent_otp_delivery_attempts attempt
  join private.email_recipient_identities identity
    on identity.id = attempt.recipient_identity_id
  cross join private.migration_reconciliations allow_reconciliation
  cross join private.migration_reconciliations restore_reconciliation
  where attempt.id = 'b6150000-0000-4000-8000-000000000002'
    and allow_reconciliation.migration_key =
      '20260821161500_allow_parent_otp_recipient_backfill'
    and restore_reconciliation.migration_key =
      '20260821162500_restore_parent_otp_ledger_immutability'
")"
if [[ "$result" != "otp-backfill@example.invalid:passed:passed:true" ]]; then
  echo "Onverwachte OTP-recipientbackfillstaat: $result" >&2
  exit 1
fi

set +e
"${psql_cmd[@]}" -c "
  update private.parent_otp_delivery_attempts
  set recipient_identity_id = recipient_identity_id
  where id = 'b6150000-0000-4000-8000-000000000002';
" >"$reset_log" 2>&1
immutable_status=$?
set -e
if [[ "$immutable_status" -eq 0 ]] \
  || ! grep -q 'PARENT_OTP_DELIVERY_LEDGER_IMMUTABLE' "$reset_log"; then
  echo "De strikte OTP-ledgerguard is na de backfill niet hersteld." >&2
  exit 1
fi

restore_latest
echo "OTP-recipientupgradetest geslaagd: historie gebonden en ledgerguard opnieuw strikt."
