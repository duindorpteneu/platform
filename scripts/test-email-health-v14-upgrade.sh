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
    echo "Kon de lokale database na de e-mailhealthupgradetest niet herstellen." >&2
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
  echo "E-mailhealthupgradetest weigert onverwachte database-identiteit." >&2
  exit 1
fi

cd "$repository_root"
node scripts/run-supabase.mjs db reset --local \
  --version 20260821163000 --no-seed

"${psql_cmd[@]}" <<'SQL'
update private.migration_reconciliations
set reconciled_at = '2026-08-21 13:00:00+00'::timestamptz
where migration_key =
  '20260818133600_acknowledge_recovered_email_scheduler_health';

insert into app.seasons(id, name, default_amount_cents, status)
values (
  'b7072100-0000-4000-8000-000000000010',
  'E-mailhealthupgrade',
  100,
  'open'
);
insert into private.parent_accounts(id, email_normalized)
values (
  'b7072100-0000-4000-8000-000000000011',
  'email-health-upgrade@example.invalid'
);

alter table private.email_jobs disable trigger email_jobs_guard_snapshot;

insert into private.email_jobs(
  id,
  kind,
  recipient_email,
  template_key,
  payload,
  status,
  attempts,
  idempotency_key,
  completed_at,
  last_error,
  updated_at,
  context_kind,
  parent_account_id,
  season_id,
  mail_template_revision_id,
  mail_branding_revision_id,
  rendered_subject_snapshot,
  rendered_preheader_snapshot,
  rendered_html_snapshot,
  rendered_text_snapshot,
  from_name_snapshot,
  from_email_snapshot,
  reply_to_email_snapshot,
  render_hash,
  created_at
)
select
  'c0c0686d-e6e6-4778-96de-c38f2effb023',
  'bulk',
  'email-health-upgrade@example.invalid',
  'portal_access_reminder',
  '{}'::jsonb,
  'failed',
  5,
  'email-health-v14-upgrade',
  '2026-08-21 16:52:21.986788+00'::timestamptz,
  'provider_rejected',
  '2026-08-21 16:52:21.986788+00'::timestamptz,
  'mail_v2',
  'b7072100-0000-4000-8000-000000000011',
  'b7072100-0000-4000-8000-000000000010',
  revision.id,
  branding.id,
  'Veilige test',
  'Veilige test',
  '<p>Veilige test</p>',
  'Veilige test',
  branding.from_name,
  branding.from_email,
  branding.reply_to_email,
  repeat('a', 64),
  '2026-08-21 14:21:21.263402+00'::timestamptz
from app.mail_template_revisions revision
cross join app.mail_branding_revisions branding
where revision.status = 'published'
  and branding.status = 'published'
limit 1;

insert into private.email_delivery_attempts(
  id,
  email_job_id,
  attempt_number,
  claim_token,
  claimed_at
) values (
  'db33ef34-56fd-4922-b266-dc754f8d2906',
  'c0c0686d-e6e6-4778-96de-c38f2effb023',
  5,
  'b7072100-0000-4000-8000-000000000003',
  statement_timestamp()
);

update private.email_jobs
set current_delivery_attempt_id =
  'db33ef34-56fd-4922-b266-dc754f8d2906',
  updated_at = '2026-08-21 16:52:21.986788+00'::timestamptz
where id = 'c0c0686d-e6e6-4778-96de-c38f2effb023';

alter table private.email_jobs enable trigger email_jobs_guard_snapshot;
SQL

node scripts/run-supabase.mjs migration up --local >/dev/null

result="$("${psql_cmd[@]}" -c "
  select concat_ws(':',
    reconciliation.status,
    reconciliation.metrics->>'acknowledgedFailedJobCount',
    app.get_operational_health_v14(
      repeat('a', 64), 1, null, null
    ) #>> '{emailJobs,failed}'
  )
  from private.migration_reconciliations reconciliation
  where reconciliation.migration_key =
    '20260821170721_preserve_email_health_v13_exclusions'
")"
if [[ "$result" != "passed:1:0" ]]; then
  echo "Onverwachte e-mailhealth-v14-upgradestaat: $result" >&2
  exit 1
fi

"${psql_cmd[@]}" -c "
  update private.email_jobs
  set updated_at = updated_at + interval '1 second'
  where id = 'c0c0686d-e6e6-4778-96de-c38f2effb023';
"

changed_health="$("${psql_cmd[@]}" -c "
  select app.get_operational_health_v14(
    repeat('a', 64), 1, null, null
  ) #>> '{emailJobs,failed}'
")"
if [[ "$changed_health" != "1" ]]; then
  echo "Een gewijzigde failureversie bleef niet fail-closed: $changed_health" >&2
  exit 1
fi

restore_latest
echo "E-mailhealth-v14-upgradetest geslaagd: exacte erkenning en fail-closed wijziging bewezen."
