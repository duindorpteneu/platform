#!/usr/bin/env bash
set -Eeuo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP ontbreekt}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID ontbreekt}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT ontbreekt}"
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL ontbreekt}"
: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF ontbreekt}"
: "${RELEASE_SHA:?RELEASE_SHA ontbreekt}"
: "${SOURCE_RELEASE_SHA:?SOURCE_RELEASE_SHA ontbreekt}"
: "${SOURCE_ARTIFACT_DIGEST:?SOURCE_ARTIFACT_DIGEST ontbreekt}"
: "${TARGET_ENVIRONMENT:?TARGET_ENVIRONMENT ontbreekt}"
[[ "${RELEASE_SHA}" =~ ^[a-f0-9]{40}$ ]]
[[ "${SOURCE_RELEASE_SHA}" =~ ^[a-f0-9]{40}$ ]]
[[ "${SOURCE_ARTIFACT_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]]

[[ "${TARGET_ENVIRONMENT}" == staging || "${TARGET_ENVIRONMENT}" == production ]]
expected_project_ref="$(
  if [[ "${TARGET_ENVIRONMENT}" == staging ]]; then
    printf '%s' dxbdjtbyghsovlrdcwcr
  else
    printf '%s' wobcbufmmputydtzemyu
  fi
)"
[[ "${SUPABASE_PROJECT_REF}" == "${expected_project_ref}" ]]

for command in cut date docker find mktemp node openssl seq sha256sum stat tr; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Vereist commando ontbreekt: ${command}" >&2
    exit 1
  }
done
if [[ "${TARGET_ENVIRONMENT}" == production ]]; then
  command -v gpg >/dev/null 2>&1 || {
    echo "Vereist commando ontbreekt: gpg" >&2
    exit 1
  }
fi

expected_postgres_image="public.ecr.aws/supabase/postgres:17.6.1.143@sha256:80d7b27c3e8d77cfa7226eee9508671796da214781ff15a35b3670d7ad5ee453"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-${expected_postgres_image}}"
[[ "${POSTGRES_IMAGE}" == "${expected_postgres_image}" ]]
source_network_args=()
if [[ -n "${SOURCE_DOCKER_NETWORK:-}" ]]; then
  [[ "${TARGET_ENVIRONMENT}" == staging ]]
  [[ "${SOURCE_DOCKER_NETWORK}" =~ ^[a-zA-Z0-9_.-]+$ ]]
  source_network_args=(--network "${SOURCE_DOCKER_NETWORK}")
fi

run_key="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
container_name="duindorp-restore-${run_key}"
dump_container_name="duindorp-dump-${run_key}"
dump_path="${RUNNER_TEMP}/duindorp-restore-${run_key}.dump"
decrypted_dump_path="${RUNNER_TEMP}/duindorp-restore-${run_key}.decrypted.dump"
encrypted_dump_path="${RUNNER_TEMP}/duindorp-restore-${run_key}.dump.gpg"
passphrase_path="${RUNNER_TEMP}/duindorp-restore-${run_key}.passphrase"
verification_path="${RUNNER_TEMP}/duindorp-restore-${run_key}-verification.json"
evidence_path="${RUNNER_TEMP}/duindorp-restore-${run_key}-evidence.json"
restore_work_dir="$(
  mktemp -d "${RUNNER_TEMP}/duindorp-restore-${run_key}.work.XXXXXX"
)"
source_inventory_path="${restore_work_dir}/source-inventory.json"
restored_inventory_path="${restore_work_dir}/restored-inventory.json"
inventory_key_path="${restore_work_dir}/inventory.key"
candidate_verification_path="${restore_work_dir}/candidate-verification.json"
label="nl.duindorpteneu.restore-run=${run_key}"
started_epoch="$(date -u +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
backup_snapshot_epoch="${started_epoch}"
backup_snapshot_at="${started_at}"

cleanup() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  docker rm --force --volumes "${container_name}" >/dev/null 2>&1 || true
  docker rm --force --volumes "${dump_container_name}" >/dev/null 2>&1 || true
  rm -f -- "${dump_path}" "${decrypted_dump_path}" \
    "${passphrase_path}" "${verification_path}"
  find "${restore_work_dir}" -mindepth 1 -maxdepth 1 -delete \
    >/dev/null 2>&1 || true
  rmdir "${restore_work_dir}" >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 129' HUP
trap 'cleanup 143' TERM

umask 077
chmod 0700 "${restore_work_dir}"
: > "${dump_path}"
chmod 0600 "${dump_path}"
: > "${source_inventory_path}"
: > "${restore_work_dir}/source.dump"
chmod 0600 "${source_inventory_path}" "${restore_work_dir}/source.dump"
openssl rand -hex 32 > "${inventory_key_path}"
chmod 0600 "${inventory_key_path}"

echo "Een consistente bronsnapshot wordt met de PostgreSQL 17-client gemaakt."
docker run --rm \
  --name "${dump_container_name}" \
  --label "${label}" \
  "${source_network_args[@]}" \
  --read-only \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
  --env SOURCE_INVENTORY_MODE="${TARGET_ENVIRONMENT}" \
  --volume "${PWD}:/harness:ro" \
  --volume "${restore_work_dir}:/work" \
  --volume "${inventory_key_path}:/run/restore-inventory-key:ro" \
  --entrypoint sh \
  "${POSTGRES_IMAGE}" \
  /harness/scripts/staging/create-source-snapshot-backup.sh

mv -f -- "${restore_work_dir}/source.dump" "${dump_path}"
source_major="$(node -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const publicSchema = value.schemas?.find((schema) =>
    schema.name === "public");
  const publicUsage = publicSchema?.acl?.some((grant) =>
    grant.grantor === "pg_database_owner"
      && grant.grantee === "PUBLIC"
      && grant.privilege === "USAGE"
      && grant.grantable === false);
  if (!publicUsage) {
    throw new Error("De public-schema-ACL wijkt af van het Supabase-contract");
  }
  process.stdout.write(String(value.postgresMajor));
' "${source_inventory_path}")"
if [[ "${TARGET_ENVIRONMENT}" == staging ]]; then
  [[ "${source_major}" == "17" ]] || {
    echo "Stagingbron moet PostgreSQL 17 zijn; aangetroffen major: ${source_major}." >&2
    exit 1
  }
else
  [[ "${source_major}" =~ ^(15|16|17)$ ]] || {
    echo "Productiebronmajor wordt niet ondersteund: ${source_major}." >&2
    exit 1
  }
fi
echo "Bronmajor ${source_major}; geïsoleerd hersteldoel major 17."

[[ -s "${dump_path}" ]]
[[ -s "${source_inventory_path}" ]]
[[ "$(stat -c '%a' "${dump_path}")" == "600" ]]
[[ "$(stat -c '%a' "${source_inventory_path}")" == "600" ]]
include_supabase_functions_admin="$(
  node scripts/staging/validate-source-restore-inventory.mjs \
    --print-functions-admin-presence "${source_inventory_path}"
)"
[[ "${include_supabase_functions_admin}" == true \
    || "${include_supabase_functions_admin}" == false ]]
include_postgres_realtime_admin_membership="$(
  node scripts/staging/validate-source-restore-inventory.mjs \
    --print-postgres-realtime-admin-membership "${source_inventory_path}"
)"
[[ "${include_postgres_realtime_admin_membership}" == true \
    || "${include_postgres_realtime_admin_membership}" == false ]]

restore_input_path="${dump_path}"
encrypted_checksum=""
if [[ "${TARGET_ENVIRONMENT}" == production ]]; then
  : "${PRODUCTION_BACKUP_PASSPHRASE:?PRODUCTION_BACKUP_PASSPHRASE ontbreekt}"
  : "${RELEASE_ARTIFACT_DIGEST:?RELEASE_ARTIFACT_DIGEST ontbreekt}"
  [[ "${#PRODUCTION_BACKUP_PASSPHRASE}" -ge 32 ]]
  [[ "${RELEASE_ARTIFACT_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]]
  printf '%s' "${PRODUCTION_BACKUP_PASSPHRASE}" > "${passphrase_path}"
  chmod 0600 "${passphrase_path}"
  gpg --batch --yes --pinentry-mode loopback \
    --passphrase-file "${passphrase_path}" \
    --symmetric --cipher-algo AES256 \
    --output "${encrypted_dump_path}" "${dump_path}"
  chmod 0600 "${encrypted_dump_path}"
  gpg --batch --yes --pinentry-mode loopback \
    --passphrase-file "${passphrase_path}" \
    --decrypt --output "${decrypted_dump_path}" "${encrypted_dump_path}"
  chmod 0600 "${decrypted_dump_path}"
  [[ "$(sha256sum "${dump_path}" | cut -d' ' -f1)" == \
    "$(sha256sum "${decrypted_dump_path}" | cut -d' ' -f1)" ]]
  encrypted_checksum="$(sha256sum "${encrypted_dump_path}" | cut -d' ' -f1)"
  restore_input_path="${decrypted_dump_path}"
fi

restore_password="$(openssl rand -hex 32)"
docker run --detach \
  --name "${container_name}" \
  --label "${label}" \
  --network none \
  --security-opt no-new-privileges:true \
  --env POSTGRES_PASSWORD="${restore_password}" \
  --env POSTGRES_DB=postgres \
  "${POSTGRES_IMAGE}" >/dev/null
unset restore_password

init_complete_marker='PostgreSQL init process complete; ready for start up.'
for _ in $(seq 1 120); do
  container_logs="$(docker logs "${container_name}" 2>&1)"
  if [[ "${container_logs}" == *"${init_complete_marker}"* ]] \
    && docker exec "${container_name}" pg_isready --quiet --username postgres --dbname postgres; then
    break
  fi
  sleep 2
done
container_logs="$(docker logs "${container_name}" 2>&1)"
[[ "${container_logs}" == *"${init_complete_marker}"* ]]
unset container_logs
docker exec "${container_name}" pg_isready --quiet --username postgres --dbname postgres
docker exec "${container_name}" createdb \
  --username supabase_admin --template template0 restore_drill
docker exec "${container_name}" \
  psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username supabase_admin --dbname restore_drill \
  --command='drop schema if exists public cascade;'
docker exec --interactive "${container_name}" \
  psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --set=include_supabase_functions_admin="${include_supabase_functions_admin}" \
  --set=include_postgres_realtime_admin_membership="${include_postgres_realtime_admin_membership}" \
  --username supabase_admin \
  --dbname restore_drill \
  < scripts/staging/prepare-restore-roles.sql

echo "Back-up wordt in een netwerkloze, run-unieke PostgreSQL 17-container hersteld."
docker exec --interactive "${container_name}" \
  pg_restore --exit-on-error --disable-triggers \
  --username supabase_admin \
  --dbname restore_drill \
  < "${restore_input_path}"
docker exec "${container_name}" \
  psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username supabase_admin --dbname restore_drill \
  --command='set role pg_database_owner; grant usage on schema public to public; reset role;'

docker cp "${inventory_key_path}" \
  "${container_name}:/tmp/restore-inventory-key"
docker cp scripts/staging/source-restore-inventory.sql \
  "${container_name}:/tmp/source-restore-inventory.sql"
docker exec "${container_name}" chmod 0600 /tmp/restore-inventory-key
docker exec "${container_name}" sh -ceu '
  inventory_hmac_key="$(tr -d "\r\n" < /tmp/restore-inventory-key)"
  psql --no-psqlrc --quiet --tuples-only --no-align \
    --set=ON_ERROR_STOP=1 \
    --set=snapshot_mode=0 \
    --set=inventory_hmac_key="${inventory_hmac_key}" \
    --username supabase_admin \
    --dbname restore_drill \
    --file /tmp/source-restore-inventory.sql
  rm -f -- /tmp/restore-inventory-key /tmp/source-restore-inventory.sql
' > "${restored_inventory_path}"
chmod 0600 "${restored_inventory_path}"

restore_contract_mode=source
if [[ "${TARGET_ENVIRONMENT}" == staging ]]; then
  restore_contract_mode=current
  docker exec --interactive "${container_name}" \
    psql --no-psqlrc --quiet --tuples-only --no-align \
    --username supabase_admin --dbname restore_drill \
    < scripts/staging/restore-verify.sql \
    > "${candidate_verification_path}"
  chmod 0600 "${candidate_verification_path}"
  node scripts/staging/validate-restore-verification.mjs \
    "${candidate_verification_path}"
fi

node scripts/staging/validate-source-restore-inventory.mjs \
  "${source_inventory_path}" \
  "${restored_inventory_path}" \
  "${restore_contract_mode}" \
  "${verification_path}"
chmod 0600 "${verification_path}"

completed_epoch="$(date -u +%s)"
completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export STARTED_AT="${started_at}"
export BACKUP_SNAPSHOT_AT="${backup_snapshot_at}"
export COMPLETED_AT="${completed_at}"
export BACKUP_SNAPSHOT_AGE_SECONDS="$((completed_epoch - backup_snapshot_epoch))"
export RESTORE_DURATION_SECONDS="$((completed_epoch - started_epoch))"
export RESTORE_VERIFICATION_PATH="${verification_path}"
export RESTORE_EVIDENCE_PATH="${evidence_path}"
export RESTORE_TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT}"
export RESTORE_ENCRYPTED_SHA256="${encrypted_checksum}"
export RESTORE_SOURCE_RELEASE_SHA="${SOURCE_RELEASE_SHA}"
export RESTORE_SOURCE_ARTIFACT_DIGEST="${SOURCE_ARTIFACT_DIGEST}"
export RESTORE_CONTRACT_MODE="${restore_contract_mode}"

node scripts/staging/write-restore-evidence.mjs
echo "Verse back-up en geïsoleerde restore zijn binnen de technische drilldoelen afgerond; alleen geredigeerd bewijs blijft beschikbaar."
