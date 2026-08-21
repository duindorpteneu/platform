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
    echo "Kon de lokale database na de OTP-gapupgradetest niet herstellen." >&2
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
  echo "OTP-gapupgradetest weigert onverwachte database-identiteit." >&2
  exit 1
fi

cd "$repository_root"
node scripts/run-supabase.mjs db reset --local \
  --version 20260821170721 --no-seed

"${psql_cmd[@]}" <<'SQL'
insert into private.parent_accounts(id, email_normalized)
values (
  'b8315400-0000-4000-8000-000000000001',
  'otp-gap-upgrade@example.invalid'
);

insert into private.parent_otp_challenges(
  id,
  parent_account_id,
  code_hash,
  expires_at,
  created_at,
  credential_version,
  closed_at,
  close_reason
) values (
  'b8315400-0000-4000-8000-000000000002',
  'b8315400-0000-4000-8000-000000000001',
  repeat('a', 64),
  statement_timestamp() - interval '20 minutes',
  statement_timestamp() - interval '30 minutes',
  3,
  statement_timestamp() - interval '20 minutes',
  'expired'
);

insert into private.parent_otp_delivery_attempts(
  id,
  parent_account_id,
  challenge_id,
  template_revision_id,
  branding_revision_id,
  expires_at,
  created_at
)
select
  'b8315400-0000-4000-8000-000000000003',
  'b8315400-0000-4000-8000-000000000001',
  'b8315400-0000-4000-8000-000000000002',
  template.id,
  branding.id,
  statement_timestamp() - interval '20 minutes',
  statement_timestamp() - interval '30 minutes'
from app.mail_template_revisions template
cross join app.mail_branding_revisions branding
where template.template_key = 'login_otp'
  and template.status = 'published'
  and branding.status = 'published'
limit 1;

insert into private.parent_accounts(id, email_normalized)
values (
  'b8315400-0000-4000-8000-000000000011',
  'otp-gap-open-upgrade@example.invalid'
);

insert into private.parent_otp_challenges(
  id,
  parent_account_id,
  code_hash,
  expires_at,
  created_at,
  credential_version
) values (
  'b8315400-0000-4000-8000-000000000012',
  'b8315400-0000-4000-8000-000000000011',
  repeat('b', 64),
  statement_timestamp() + interval '7 minutes',
  statement_timestamp() - interval '3 minutes',
  3
);

insert into private.parent_otp_delivery_attempts(
  id,
  parent_account_id,
  challenge_id,
  template_revision_id,
  branding_revision_id,
  expires_at,
  created_at
)
select
  'b8315400-0000-4000-8000-000000000013',
  'b8315400-0000-4000-8000-000000000011',
  'b8315400-0000-4000-8000-000000000012',
  template.id,
  branding.id,
  statement_timestamp() + interval '7 minutes',
  statement_timestamp() - interval '3 minutes'
from app.mail_template_revisions template
cross join app.mail_branding_revisions branding
where template.template_key = 'login_otp'
  and template.status = 'published'
  and branding.status = 'published'
limit 1;
SQL

node scripts/run-supabase.mjs migration up --local >/dev/null

reconciled="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    reconciliation.status,
    reconciliation.metrics->>'reconciledAttemptCount',
    reconciliation.metrics->>'auditEntryCount',
    outcome.outcome,
    outcome.error_code,
    (
      select open_outcome.outcome
      from private.parent_otp_delivery_outcomes open_outcome
      where open_outcome.delivery_attempt_id =
        'b8315400-0000-4000-8000-000000000013'
    ),
    (
      select open_outcome.error_code
      from private.parent_otp_delivery_outcomes open_outcome
      where open_outcome.delivery_attempt_id =
        'b8315400-0000-4000-8000-000000000013'
    ),
    app.get_operational_health_v14(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,stalePrepared}',
    app.get_operational_health_v14(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,deliveryUncertainRecent}',
    app.get_operational_health_v15(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,stalePrepared}',
    app.get_operational_health_v15(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,deliveryUncertainRecent}'
  )
  from private.migration_reconciliations reconciliation
  join private.parent_otp_delivery_outcomes outcome
    on outcome.delivery_attempt_id =
      'b8315400-0000-4000-8000-000000000003'
  where reconciliation.migration_key =
    '20260821183154_resolve_pre_v3_otp_delivery_gaps'
")"
if [[ "$reconciled" != "passed:2:2:delivery_uncertain:pre_v3_uncompleted_attempt:delivery_uncertain:pre_v3_uncompleted_attempt:0:0:0:0" ]]; then
  echo "Onverwachte OTP-gapurgradestaat: $reconciled" >&2
  exit 1
fi

"${psql_cmd[@]}" <<'SQL'
insert into private.parent_accounts(id, email_normalized)
values (
  'b8315400-0000-4000-8000-000000000021',
  'otp-gap-new@example.invalid'
);
insert into private.parent_otp_challenges(
  id, parent_account_id, code_hash, expires_at, created_at,
  credential_version
) values (
  'b8315400-0000-4000-8000-000000000022',
  'b8315400-0000-4000-8000-000000000021',
  repeat('c', 64),
  statement_timestamp() + interval '7 minutes',
  statement_timestamp() - interval '3 minutes',
  3
);
insert into private.parent_otp_delivery_attempts(
  id, parent_account_id, challenge_id, template_revision_id,
  branding_revision_id, expires_at, created_at
)
select
  'b8315400-0000-4000-8000-000000000023',
  'b8315400-0000-4000-8000-000000000021',
  'b8315400-0000-4000-8000-000000000022',
  template.id,
  branding.id,
  statement_timestamp() + interval '7 minutes',
  statement_timestamp() - interval '3 minutes'
from app.mail_template_revisions template
cross join app.mail_branding_revisions branding
where template.template_key = 'login_otp'
  and template.status = 'published'
  and branding.status = 'published'
limit 1;
SQL

new_gap="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    app.get_operational_health_v14(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,stalePrepared}',
    app.get_operational_health_v15(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,stalePrepared}'
  )
")"
if [[ "$new_gap" != "1:1" ]]; then
  echo "Nieuwe OTP-gap bleef niet fail-closed: $new_gap" >&2
  exit 1
fi

"${psql_cmd[@]}" -c "
  select app.complete_parent_otp_delivery_v1(
    'b8315400-0000-4000-8000-000000000023',
    'delivery_uncertain',
    null,
    'delivery_completion_uncertain'
  );
" >/dev/null

new_uncertain="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    app.get_operational_health_v14(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,stalePrepared}',
    app.get_operational_health_v14(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,deliveryUncertainRecent}',
    app.get_operational_health_v15(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,stalePrepared}',
    app.get_operational_health_v15(
      repeat('a', 64), 1, null, null
    ) #>> '{parentOtpDelivery,deliveryUncertainRecent}'
  )
")"
if [[ "$new_uncertain" != "0:1:0:1" ]]; then
  echo "Nieuwe OTP-onzekerheid bleef niet fail-closed: $new_uncertain" >&2
  exit 1
fi

restore_latest
echo "OTP-gapupgradetest geslaagd: historische reconciliatie en nieuwe fail-closed uitkomsten bewezen."
