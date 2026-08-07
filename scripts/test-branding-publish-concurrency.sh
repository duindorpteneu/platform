#!/usr/bin/env bash
set -Eeuo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54339/postgres}"
case "$database_url" in
  postgresql://*@127.0.0.1:*/*|postgres://*@127.0.0.1:*/*|postgresql://*@localhost:*/*|postgres://*@localhost:*/*) ;;
  *)
    echo "De branding-racetest mag uitsluitend tegen een lokale database draaien." >&2
    exit 2
    ;;
esac

psql_cmd=(psql "$database_url" -X -q -A -t -v ON_ERROR_STOP=1)
mkdir -p .tmp
test_tmp_dir="$(mktemp -d .tmp/branding-publish.XXXXXX)"
first_marker="$test_tmp_dir/first-published"
first_log="$test_tmp_dir/first.log"
second_log="$test_tmp_dir/second.log"
staff_id="e3440000-0000-4000-8000-000000000001"
fixture_id="e3440000-0000-4000-8000-000000000002"
correlation_id="e3440000-0000-4000-8000-000000000003"
original_id=""
original_updated_at=""
settings_updated_at=""
fixture_hash=""
first_pid=""

preflight="$("${psql_cmd[@]}" -F '|' <<'SQL'
select concat_ws(
  '|',
  coalesce(max(id::text) filter (where status = 'published'), ''),
  coalesce(max(updated_at::text) filter (where status = 'published'), ''),
  (select updated_at::text from app.app_settings where id = true),
  count(*) filter (where status = 'published'),
  count(*) filter (where status = 'draft')
)
from app.mail_branding_revisions;
SQL
)"
IFS='|' read -r original_id original_updated_at settings_updated_at published_count draft_count <<<"$preflight"
if [[ ! "$original_id" =~ ^[0-9a-f-]{36}$ ]] \
  || [[ "$published_count" != "1" ]] \
  || [[ "$draft_count" != "0" ]] \
  || [[ -z "$original_updated_at" ]] \
  || [[ -z "$settings_updated_at" ]]; then
  echo "De lokale brandingbasis moet exact één publicatie en geen draft bevatten; voer eerst pnpm db:reset uit." >&2
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit 1
fi

cleanup() {
  local status=$?
  if [[ -n "$first_pid" ]] && kill -0 "$first_pid" 2>/dev/null; then
    kill "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
  fi
  "${psql_cmd[@]}" \
    -v staff_id="$staff_id" \
    -v fixture_id="$fixture_id" \
    -v original_id="$original_id" \
    -v original_updated_at="$original_updated_at" \
    -v settings_updated_at="$settings_updated_at" \
    >/dev/null <<'SQL' || status=1
begin;
set local session_replication_role = replica;
delete from app.audit_logs
where entity_id = :'fixture_id'::uuid
  or actor_user_id = :'staff_id'::uuid;
delete from app.mail_branding_revisions
where id = :'fixture_id'::uuid;
update app.mail_branding_revisions
set status = 'published',
    archived_by = null,
    archived_at = null,
    updated_at = :'original_updated_at'::timestamptz
where id = :'original_id'::uuid;
delete from app.staff_profiles
where auth_user_id = :'staff_id'::uuid;
set local session_replication_role = origin;
select private.sync_published_branding_projection_v1();
update app.app_settings
set updated_at = :'settings_updated_at'::timestamptz
where id = true;
commit;
SQL
  find "$test_tmp_dir" -mindepth 1 -maxdepth 1 -delete
  rmdir "$test_tmp_dir"
  exit "$status"
}
trap cleanup EXIT

fixture_hash="$("${psql_cmd[@]}" \
  -v staff_id="$staff_id" \
  -v fixture_id="$fixture_id" <<'SQL'
begin;
insert into app.staff_profiles(auth_user_id, display_name, role)
values(
  :'staff_id'::uuid,
  'Branding publicatierace',
  'beheerder'
);
insert into app.mail_branding_revisions(
  id,
  revision,
  status,
  club_name,
  logo_asset_path,
  from_name,
  from_email,
  reply_to_email,
  contact_email,
  club_address_line,
  club_postal_code,
  club_city,
  pickup_name,
  pickup_address_line,
  pickup_postal_code,
  pickup_city,
  privacy_url,
  primary_color,
  secondary_color,
  accent_color,
  footer_text,
  contrast_validated,
  content_hash,
  created_by,
  creation_source
)
select
  :'fixture_id'::uuid,
  coalesce(max(revision), 0) + 1,
  'draft',
  'Duindorp SV',
  '/duindorp-sv-logo.png',
  'Kledingcommissie Duindorp SV',
  'kleding@duindorpsv.nl',
  'kleding@duindorpsv.nl',
  'kleding@duindorpsv.nl',
  'Houtrustlaan 1',
  '2566 ZW',
  'Den Haag',
  'Free-Kick Sport',
  'De Savornin Lohmanplein 45',
  '2566 AE',
  'Den Haag',
  'https://duindorpsv.nl/privacy',
  '#17418B',
  '#0B2E63',
  '#356FD1',
  'Kledingcommissie Duindorp SV · kleding@duindorpsv.nl · duindorpsv.nl/privacy',
  true,
  private.mail_branding_values_hash(
    'Duindorp SV',
    '/duindorp-sv-logo.png',
    'Kledingcommissie Duindorp SV',
    'kleding@duindorpsv.nl',
    'kleding@duindorpsv.nl',
    'kleding@duindorpsv.nl',
    'Houtrustlaan 1',
    '2566 ZW',
    'Den Haag',
    'Free-Kick Sport',
    'De Savornin Lohmanplein 45',
    '2566 AE',
    'Den Haag',
    'https://duindorpsv.nl/privacy',
    '#17418B',
    '#0B2E63',
    '#356FD1',
    'Kledingcommissie Duindorp SV · kleding@duindorpsv.nl · duindorpsv.nl/privacy',
    true
  ),
  :'staff_id'::uuid,
  'staff'
from app.mail_branding_revisions
returning content_hash;
commit;
SQL
)"
if [[ ! "$fixture_hash" =~ ^[0-9a-f]{64}$ ]]; then
  echo "De brandingfixture kon niet veilig worden voorbereid." >&2
  exit 1
fi

publish_first() {
  "${psql_cmd[@]}" \
    -v staff_id="$staff_id" \
    -v fixture_id="$fixture_id" \
    -v fixture_hash="$fixture_hash" \
    -v correlation_id="$correlation_id" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'staff_id', 'aal', 'aal2')::text,
  true
);
set local role authenticated;
select app.publish_mail_branding_revision_v2(
  :'fixture_id'::uuid,
  :'fixture_hash',
  :'correlation_id'::uuid
)->>'status';
\\! touch "$first_marker"
select pg_sleep(2);
commit;
SQL
}

wait_for_marker() {
  for _ in $(seq 1 100); do
    if [[ -f "$first_marker" ]]; then
      return
    fi
    if ! kill -0 "$first_pid" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done
  wait "$first_pid" || true
  first_pid=""
  sed -n '1,100p' "$first_log" >&2
  echo "De brandingconcurrencybarrière werd niet bereikt." >&2
  exit 1
}

publish_first >"$first_log" 2>&1 &
first_pid=$!
wait_for_marker

set +e
"${psql_cmd[@]}" \
  -v staff_id="$staff_id" \
  -v fixture_id="$fixture_id" \
  -v fixture_hash="$fixture_hash" \
  -v correlation_id="$correlation_id" >"$second_log" 2>&1 <<'SQL'
\set VERBOSITY verbose
begin;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'staff_id', 'aal', 'aal2')::text,
  true
);
set local role authenticated;
select app.publish_mail_branding_revision_v2(
  :'fixture_id'::uuid,
  :'fixture_hash',
  :'correlation_id'::uuid
);
commit;
SQL
second_status=$?
set -e
if ! wait "$first_pid"; then
  sed -n '1,100p' "$first_log" >&2
  echo "De eerste brandingpublicatie faalde." >&2
  exit 1
fi
first_pid=""
if [[ "$second_status" -eq 0 ]] \
  || ! grep -q '40001' "$second_log" \
  || ! grep -q 'MAIL_BRANDING_PUBLISH_STALE' "$second_log"; then
  sed -n '1,100p' "$second_log" >&2
  echo "De verliezende brandingpublicatie was niet exact stale." >&2
  exit 1
fi

race_state="$("${psql_cmd[@]}" \
  -v fixture_id="$fixture_id" \
  -v original_id="$original_id" <<'SQL'
select concat_ws(
  '|',
  count(*) filter (where branding.status = 'published'),
  max(branding.status) filter (where branding.id = :'fixture_id'::uuid),
  max(branding.status) filter (where branding.id = :'original_id'::uuid),
  (
    select count(*)
    from app.audit_logs audit
    where audit.action = 'mail_branding.published'
      and audit.entity_id = :'fixture_id'::uuid
  ),
  private.branding_projection_blocker_count_v1(),
  (
    select count(*)
    from app.audit_logs audit
    where audit.action = 'mail_branding.published'
      and audit.entity_id = :'fixture_id'::uuid
      and audit.metadata::text !~* '@|houtrust|lohman|privacy'
  ),
  (
    select (public.get_public_brand_tokens_v1()->>'accentColor') =
      '#356FD1'
  )
)
from app.mail_branding_revisions branding;
SQL
)"
if [[ "$race_state" != "1|published|archived|1|0|1|t" ]]; then
  echo "De brandingpublicatierace liet geen exact en privacyveilig resultaat achter." >&2
  exit 1
fi

echo "Brandingpublicatie is atomair: exact één winnaar, één stale verliezer en een consistente publieke projectie."
