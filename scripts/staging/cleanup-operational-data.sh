#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source scripts/deploy/assert-runner-boundary.sh

: "${TARGET_ENVIRONMENT:?TARGET_ENVIRONMENT ontbreekt}"
: "${TARGET_OPERATION:?TARGET_OPERATION ontbreekt}"
: "${CLEANUP_MODE:?CLEANUP_MODE ontbreekt}"
: "${STAGING_APP_URL:?STAGING_APP_URL ontbreekt}"
: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF ontbreekt}"
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL ontbreekt}"
: "${RELEASE_SHA:?RELEASE_SHA ontbreekt}"
: "${ARTIFACT_DIGEST:?ARTIFACT_DIGEST ontbreekt}"
: "${CONFIRM_TARGET:?CONFIRM_TARGET ontbreekt}"
: "${RUNNER_TEMP:?RUNNER_TEMP ontbreekt}"
: "${CLEANUP_EVIDENCE_PATH:?CLEANUP_EVIDENCE_PATH ontbreekt}"

readonly expected_postgres_image="public.ecr.aws/supabase/postgres:17.6.1.143@sha256:80d7b27c3e8d77cfa7226eee9508671796da214781ff15a35b3670d7ad5ee453"
readonly postgres_image="${POSTGRES_IMAGE:-${expected_postgres_image}}"
readonly compose_file="deploy/compose.vps.yml"
readonly compose_project="duindorpteneu-staging"
readonly runtime_directory="/srv/apps/duindorpteneu/staging"
readonly runtime_env_file="${runtime_directory}/.env.runtime"
readonly image_tag="duindorpteneu-app:${RELEASE_SHA}"
readonly run_key="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
readonly restore_container="duindorp-cleanup-restore-${run_key}"
readonly dump_container="duindorp-cleanup-dump-${run_key}"
readonly preflight_path="${RUNNER_TEMP}/duindorp-cleanup-${run_key}-preflight.json"
readonly second_preflight_path="${RUNNER_TEMP}/duindorp-cleanup-${run_key}-preflight-after-backup.json"
readonly postcondition_path="${RUNNER_TEMP}/duindorp-cleanup-${run_key}-postcondition.json"
readonly raw_dump_path="${RUNNER_TEMP}/duindorp-cleanup-${run_key}.dump"
readonly restored_dump_path="${RUNNER_TEMP}/duindorp-cleanup-${run_key}-restore.dump"
readonly restore_verification_path="${RUNNER_TEMP}/duindorp-cleanup-${run_key}-restore.json"
readonly passphrase_path="${RUNNER_TEMP}/duindorp-cleanup-${run_key}.passphrase"
restore_work_dir=""
source_inventory_path=""
restored_inventory_path=""
inventory_key_path=""
inventory_verification_path=""

app_stopped=false

die() {
  echo "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Vereist commando ontbreekt: $1"
}

compose() {
  APP_IMAGE="${image_tag}" \
    RUNTIME_ENV_FILE="${runtime_env_file}" \
    APP_BIND_PORT=14000 \
    docker compose -p "${compose_project}" -f "${compose_file}" "$@"
}

restart_staging() {
  if [[ "${app_stopped}" == true ]]; then
    compose up -d --no-build --remove-orphans >/dev/null
    app_stopped=false
  fi
}

cleanup() {
  local status=$?
  set +e
  restart_staging
  docker rm --force --volumes "${restore_container}" "${dump_container}" >/dev/null 2>&1
  rm -f -- \
    "${preflight_path}" \
    "${second_preflight_path}" \
    "${postcondition_path}" \
    "${raw_dump_path}" \
    "${restored_dump_path}" \
    "${restore_verification_path}" \
    "${passphrase_path}"
  if [[ -n "${restore_work_dir}" && -d "${restore_work_dir}" ]]; then
    find "${restore_work_dir}" -mindepth 1 -maxdepth 1 -delete \
      >/dev/null 2>&1
    rmdir "${restore_work_dir}" >/dev/null 2>&1
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

[[ "${postgres_image}" == "${expected_postgres_image}" ]] || die "PostgreSQL-image wijkt af van de gepinde digest."
[[ "${TARGET_OPERATION}" == cleanup ]] || die "Alleen de cleanupoperatie is toegestaan."
[[ "${CLEANUP_MODE}" == dry-run || "${CLEANUP_MODE}" == apply ]] || die "CLEANUP_MODE is ongeldig."
[[ "$(git rev-parse HEAD)" == "${RELEASE_SHA}" ]] || die "Checkout en RELEASE_SHA verschillen."
[[ "${ARTIFACT_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]] \
  || die "ARTIFACT_DIGEST is ongeldig."

for command in docker node sha256sum; do require_command "${command}"; done
assert_runner_boundary staging
node scripts/staging/validate-target.mjs
docker image inspect "${postgres_image}" >/dev/null 2>&1 || docker pull "${postgres_image}" >/dev/null

run_preflight() {
  local output_path="$1"
  docker run --rm \
    --name "${dump_container}" \
    --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
    --volume "${PWD}:/workspace:ro" \
    --entrypoint sh \
    "${postgres_image}" \
    -ceu 'psql "$SOURCE_DB_URL" --no-psqlrc --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
      --file=/workspace/scripts/staging/sql/operational-cleanup-preflight.sql' \
    > "${output_path}"
  chmod 0600 "${output_path}"
  node -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (value.schema_version !== 1 || value.cleanup_table_count !== 100 || value.preserved_table_count !== 28) process.exit(1);
    const latest = require("node:fs").readdirSync("supabase/migrations")
      .filter((name) => /^\d{14}_.+\.sql$/.test(name)).sort().at(-1).slice(0, 14);
    if (value.latest_migration_version !== latest) throw new Error("staging migration ledger is not current");
  ' "${output_path}"
}

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_preflight "${preflight_path}"

if [[ "${CLEANUP_MODE}" == dry-run ]]; then
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export STARTED_AT="${started_at}"
  export COMPLETED_AT="${completed_at}"
  export CLEANUP_PREFLIGHT_PATH="${preflight_path}"
  unset CLEANUP_POSTCONDITION_PATH BACKUP_CHECKSUM BACKUP_ARTIFACT_NAME CLEANUP_RUN_ID || true
  node scripts/staging/write-cleanup-evidence.mjs
  echo "Staging-cleanup dry-run is PII-vrij vastgelegd; de database is niet gewijzigd."
  exit 0
fi

: "${CLEANUP_PHASE:?CLEANUP_PHASE ontbreekt}"
: "${BACKUP_ARTIFACT_PATH:?BACKUP_ARTIFACT_PATH ontbreekt}"
: "${BACKUP_ARTIFACT_NAME:?BACKUP_ARTIFACT_NAME ontbreekt}"
: "${CLEANUP_PREPARED_STATE_PATH:?CLEANUP_PREPARED_STATE_PATH ontbreekt}"
: "${CLEANUP_RUN_ID:?CLEANUP_RUN_ID ontbreekt}"
: "${MOLLIE_ENABLED:?MOLLIE_ENABLED ontbreekt}"
: "${EMAIL_ENABLED:?EMAIL_ENABLED ontbreekt}"
: "${DYNAMIC_IMPORT_ENABLED:?DYNAMIC_IMPORT_ENABLED ontbreekt}"

[[ "${CLEANUP_PHASE}" == prepare || "${CLEANUP_PHASE}" == apply ]] || die "CLEANUP_PHASE is ongeldig."
[[ "${MOLLIE_ENABLED}" == false && "${EMAIL_ENABLED}" == false && "${DYNAMIC_IMPORT_ENABLED}" == false ]] \
  || die "Runtimeproviders en dynamische import moeten vóór cleanup uitstaan."
[[ "${BACKUP_ARTIFACT_PATH}" == "${RUNNER_TEMP}/"*".gpg" ]] || die "Backupartifact moet een run-uniek versleuteld tijdelijk bestand zijn."
[[ "${BACKUP_ARTIFACT_NAME}" =~ ^staging-domain-backup-[a-f0-9-]+$ ]] || die "Backupartifactnaam is ongeldig."
[[ "${CLEANUP_PREPARED_STATE_PATH}" == "${RUNNER_TEMP}/"*".json" ]] || die "Prepared-statebestand moet run-uniek en tijdelijk zijn."
[[ "${CLEANUP_RUN_ID}" =~ ^[a-f0-9-]{36}$ ]] || die "Cleanup-run-ID is ongeldig."

for command in flock stat; do require_command "${command}"; done
if [[ "${CLEANUP_PHASE}" == prepare ]]; then
  : "${STAGING_CLEANUP_BACKUP_PASSPHRASE:?STAGING_CLEANUP_BACKUP_PASSPHRASE ontbreekt}"
  [[ "${#STAGING_CLEANUP_BACKUP_PASSPHRASE}" -ge 32 ]] || die "De cleanup-backuppassphrase is te kort."
  for command in gpg openssl; do require_command "${command}"; done
else
  : "${BACKUP_ARTIFACT_ID:?BACKUP_ARTIFACT_ID ontbreekt}"
  [[ "${BACKUP_ARTIFACT_ID}" =~ ^[1-9][0-9]*$ ]] || die "Backupartifact-ID is ongeldig."
fi
[[ "${EUID}" -ne 0 ]] || die "Cleanup als root is niet toegestaan."
[[ ! -L "${runtime_directory}" && -d "${runtime_directory}" && -O "${runtime_directory}" ]] \
  || die "Het stagingruntimepad is ongeldig."
[[ -f "${runtime_directory}/REVISION" && "$(tr -d '\r\n' < "${runtime_directory}/REVISION")" == "${RELEASE_SHA}" ]] \
  || die "Het stagingruntimepad draait niet de gevraagde release."
docker image inspect "${image_tag}" >/dev/null
[[ "$(docker image inspect --format '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' "${image_tag}")" == "${RELEASE_SHA}" ]] \
  || die "De stagingimage heeft een afwijkend releaselabel."

exec 9>"${runtime_directory}/.deploy.lock"
chmod 0600 "${runtime_directory}/.deploy.lock"
flock -n 9 || die "Er draait al een stagingdeployment of cleanup."
[[ -f "${runtime_env_file}" && ! -L "${runtime_env_file}" \
    && -O "${runtime_env_file}" \
    && "$(stat -c '%a' "${runtime_env_file}")" == 600 ]] \
  || die "Het stagingruntimebestand heeft een onveilige identiteit of modus."
node scripts/staging/assert-runtime-providers-disabled.mjs \
  "${runtime_env_file}"

for service in app scheduler; do
  container_id="$(compose ps -q "${service}")"
  [[ -n "${container_id}" ]] || die "De staging-${service}container ontbreekt."
  [[ "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "${container_id}")" == "${compose_project}" ]] \
    || die "De ${service}container hoort niet bij het stagingproject."
  [[ "$(docker inspect --format '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' "${container_id}")" == "${RELEASE_SHA}" ]] \
    || die "De ${service}container draait niet de gevraagde release."
  docker exec "${container_id}" node -e '
    const names = [
      "DYNAMIC_IMPORT_ENABLED",
      "EMAIL_ENABLED",
      "MOLLIE_ENABLED",
    ];
    process.exit(names.every((name) =>
      process.env[name] === "false") ? 0 : 1);
  ' || die "De actieve ${service}container heeft nog een provider of import aan."
done

compose stop --timeout 30 scheduler app >/dev/null
app_stopped=true

# Recompute after stopping the only staging writers. This is the snapshot that
# must remain equal through backup and the transaction's ACCESS EXCLUSIVE locks.
run_preflight "${preflight_path}"
node -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.preserved.active_admins < 1) throw new Error("geen actieve beheerder");
  if (Object.values(value.blockers).some((count) => count !== 0)) throw new Error("actieve cleanupblocker");
' "${preflight_path}"

if [[ "${CLEANUP_PHASE}" == prepare ]]; then
  restore_work_dir="$(
    mktemp -d "${RUNNER_TEMP}/duindorp-cleanup-${run_key}.work.XXXXXX"
  )"
  chmod 0700 "${restore_work_dir}"
  source_inventory_path="${restore_work_dir}/source-inventory.json"
  restored_inventory_path="${restore_work_dir}/restored-inventory.json"
  inventory_key_path="${restore_work_dir}/inventory.key"
  inventory_verification_path="${restore_work_dir}/inventory-verification.json"
  openssl rand -hex 32 > "${inventory_key_path}"
  chmod 0600 "${inventory_key_path}"
  echo "Vers logisch stagingherstelpunt wordt gemaakt."
  docker run --rm \
    --name "${dump_container}" \
    --read-only \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
    --env SOURCE_INVENTORY_MODE=staging \
    --volume "${PWD}:/harness:ro" \
    --volume "${restore_work_dir}:/work" \
    --volume "${inventory_key_path}:/run/restore-inventory-key:ro" \
    "${postgres_image}" \
    /harness/scripts/staging/create-source-snapshot-backup.sh
  mv -f -- "${restore_work_dir}/source.dump" "${raw_dump_path}"
  [[ -s "${raw_dump_path}" && -s "${source_inventory_path}" ]] \
    || die "De logische back-up of exacte broninventaris ontbreekt."
  [[ "$(stat -c '%a' "${raw_dump_path}")" == 600 \
      && "$(stat -c '%a' "${source_inventory_path}")" == 600 ]] \
    || die "De logische back-upinventaris heeft onveilige rechten."
  source_major="$(node -e '
    const value = require(process.argv[1]);
    process.stdout.write(String(value.postgresMajor));
  ' "${source_inventory_path}")"
  [[ "${source_major}" == 17 ]] \
    || die "De brondatabase draait niet op PostgreSQL 17."
  include_supabase_functions_admin="$(
    node scripts/staging/validate-source-restore-inventory.mjs \
      --print-functions-admin-presence "${source_inventory_path}"
  )"
  [[ "${include_supabase_functions_admin}" == true \
      || "${include_supabase_functions_admin}" == false ]] \
    || die "De optionele herstelrolstatus is ongeldig."

  run_preflight "${second_preflight_path}"
  state_digest_before="$(node -e 'const v=require(process.argv[1]);process.stdout.write(v.state_digest)' "${preflight_path}")"
  state_digest_after="$(node -e 'const v=require(process.argv[1]);process.stdout.write(v.state_digest)' "${second_preflight_path}")"
  [[ "${state_digest_before}" == "${state_digest_after}" ]] || die "Stagingdata wijzigde tijdens de logische back-up."

  printf '%s' "${STAGING_CLEANUP_BACKUP_PASSPHRASE}" > "${passphrase_path}"
  chmod 0600 "${passphrase_path}"
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "${passphrase_path}" \
    --symmetric --cipher-algo AES256 --output "${BACKUP_ARTIFACT_PATH}" "${raw_dump_path}"
  chmod 0600 "${BACKUP_ARTIFACT_PATH}"
  rm -f -- "${raw_dump_path}"
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "${passphrase_path}" \
    --decrypt --output "${restored_dump_path}" "${BACKUP_ARTIFACT_PATH}"
  chmod 0600 "${restored_dump_path}"
  backup_checksum="$(sha256sum "${BACKUP_ARTIFACT_PATH}" | cut -d' ' -f1)"
  [[ "${backup_checksum}" =~ ^[a-f0-9]{64}$ ]] || die "De encrypted-backupchecksum is ongeldig."

  restore_password="$(openssl rand -hex 32)"
  docker run --detach \
    --name "${restore_container}" \
    --network none \
    --security-opt no-new-privileges:true \
    --env POSTGRES_PASSWORD="${restore_password}" \
    --env POSTGRES_DB=postgres \
    "${postgres_image}" >/dev/null
  unset restore_password

  for _ in $(seq 1 120); do
    if docker logs "${restore_container}" 2>&1 | grep -Fq 'PostgreSQL init process complete; ready for start up.' \
      && docker exec "${restore_container}" pg_isready --quiet --username postgres --dbname postgres; then
      break
    fi
    sleep 2
  done
  docker exec "${restore_container}" pg_isready --quiet --username postgres --dbname postgres
  docker exec "${restore_container}" createdb \
    --username supabase_admin --template template0 restore_cleanup
  docker exec "${restore_container}" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --username supabase_admin --dbname restore_cleanup \
    --command='drop schema if exists public cascade;'
  docker exec --interactive "${restore_container}" psql --no-psqlrc \
    --set=ON_ERROR_STOP=1 \
    --set=include_supabase_functions_admin="${include_supabase_functions_admin}" \
    --username supabase_admin --dbname restore_cleanup \
    < scripts/staging/prepare-restore-roles.sql
  docker exec --interactive "${restore_container}" pg_restore \
    --exit-on-error --disable-triggers \
    --username supabase_admin --dbname restore_cleanup \
    < "${restored_dump_path}"
  docker exec "${restore_container}" psql --no-psqlrc \
    --set=ON_ERROR_STOP=1 --username supabase_admin \
    --dbname restore_cleanup \
    --command='set role pg_database_owner; grant usage on schema public to public; reset role;'
  docker exec --interactive "${restore_container}" psql --no-psqlrc --quiet --tuples-only --no-align \
    --username supabase_admin --dbname restore_cleanup \
    < scripts/staging/restore-verify.sql \
    > "${restore_verification_path}"
  node scripts/staging/validate-restore-verification.mjs \
    "${restore_verification_path}"
  docker cp "${inventory_key_path}" \
    "${restore_container}:/tmp/restore-inventory-key"
  docker cp scripts/staging/source-restore-inventory.sql \
    "${restore_container}:/tmp/source-restore-inventory.sql"
  docker exec "${restore_container}" chmod 0600 \
    /tmp/restore-inventory-key
  docker exec "${restore_container}" sh -ceu '
    inventory_hmac_key="$(tr -d "\r\n" < /tmp/restore-inventory-key)"
    psql --no-psqlrc --quiet --tuples-only --no-align \
      --set=ON_ERROR_STOP=1 \
      --set=snapshot_mode=0 \
      --set=inventory_hmac_key="${inventory_hmac_key}" \
      --username supabase_admin \
      --dbname restore_cleanup \
      --file /tmp/source-restore-inventory.sql
    rm -f -- \
      /tmp/restore-inventory-key \
      /tmp/source-restore-inventory.sql
  ' > "${restored_inventory_path}"
  chmod 0600 "${restored_inventory_path}"
  node scripts/staging/validate-source-restore-inventory.mjs \
    "${source_inventory_path}" \
    "${restored_inventory_path}" \
    current \
    "${inventory_verification_path}"
  inventory_digest="$(node -e '
    const value = require(process.argv[1]);
    process.stdout.write(value.inventory_sha256);
  ' "${inventory_verification_path}")"
  [[ "${inventory_digest}" =~ ^[a-f0-9]{64}$ ]] \
    || die "De exacte restore-inventarisdigest is ongeldig."
  rm -f -- "${restored_dump_path}" "${passphrase_path}"
  docker rm --force --volumes "${restore_container}" >/dev/null

  node -e '
    const fs = require("node:fs");
    const [target, releaseSha, runId, artifactName, checksum, stateDigest, inventoryVerificationPath] = process.argv.slice(1);
    const verification = JSON.parse(
      fs.readFileSync(inventoryVerificationPath, "utf8"),
    );
    for (const key of [
      "owner_acl_rls_exact",
      "schema_definition_exact",
      "data_hmac_exact",
      "role_contract_exact",
      "identity_hmac_exact",
    ]) {
      if (verification[key] !== true) {
        throw new Error("exact restore verification ontbreekt");
      }
    }
    const value = {
      schema_version: 2,
      release_sha: releaseSha,
      cleanup_run_id: runId,
      artifact_name: artifactName,
      encrypted_sha256: checksum,
      state_digest: stateDigest,
      inventory_sha256: verification.inventory_sha256,
      owner_acl_rls_exact: verification.owner_acl_rls_exact,
      schema_definition_exact: verification.schema_definition_exact,
      data_hmac_exact: verification.data_hmac_exact,
      role_contract_exact: verification.role_contract_exact,
      identity_hmac_exact: verification.identity_hmac_exact,
      restore_verified: true,
    };
    fs.writeFileSync(target, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  ' "${CLEANUP_PREPARED_STATE_PATH}" "${RELEASE_SHA}" "${CLEANUP_RUN_ID}" \
    "${BACKUP_ARTIFACT_NAME}" "${backup_checksum}" "${state_digest_after}" \
    "${inventory_verification_path}"
  restart_staging
  for _ in $(seq 1 20); do
    if node scripts/deploy/check-http.mjs \
      "${STAGING_APP_URL}" staging "${RELEASE_SHA}" "${ARTIFACT_DIGEST}"; then
      break
    fi
    sleep 3
  done
  node scripts/deploy/check-http.mjs \
    "${STAGING_APP_URL}" staging "${RELEASE_SHA}" "${ARTIFACT_DIGEST}"
  echo "Versleutelde stagingback-up is netwerkloos herstelgetest en gereed voor duurzame upload."
  exit 0
fi

mapfile -t prepared_fields < <(node -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const exact = ["artifact_name", "cleanup_run_id", "data_hmac_exact", "encrypted_sha256", "identity_hmac_exact", "inventory_sha256", "owner_acl_rls_exact", "release_sha", "restore_verified", "role_contract_exact", "schema_definition_exact", "schema_version", "state_digest"];
  const keys = Object.keys(value).sort();
  if (keys.length !== exact.length || keys.some((key, index) => key !== exact[index])) process.exit(1);
  if (
    value.schema_version !== 2
    || value.restore_verified !== true
    || value.owner_acl_rls_exact !== true
    || value.schema_definition_exact !== true
    || value.data_hmac_exact !== true
    || value.role_contract_exact !== true
    || value.identity_hmac_exact !== true
  ) process.exit(1);
  for (const key of ["release_sha", "cleanup_run_id", "artifact_name", "encrypted_sha256", "state_digest", "inventory_sha256"]) {
    process.stdout.write(`${value[key]}\n`);
  }
' "${CLEANUP_PREPARED_STATE_PATH}")
[[ "${#prepared_fields[@]}" == 6 ]] || die "Prepared backupbewijs is ongeldig."
[[ "${prepared_fields[0]}" == "${RELEASE_SHA}" ]] || die "Prepared backup hoort bij een andere release."
[[ "${prepared_fields[1]}" == "${CLEANUP_RUN_ID}" ]] || die "Prepared backup hoort bij een andere cleanup-run."
[[ "${prepared_fields[2]}" == "${BACKUP_ARTIFACT_NAME}" ]] || die "Prepared backupartifactnaam wijkt af."
backup_checksum="${prepared_fields[3]}"
state_digest_after="${prepared_fields[4]}"
inventory_digest="${prepared_fields[5]}"
[[ "${backup_checksum}" =~ ^[a-f0-9]{64}$ \
    && "${state_digest_after}" =~ ^[a-f0-9]{64}$ \
    && "${inventory_digest}" =~ ^[a-f0-9]{64}$ ]] \
  || die "Prepared backupdigests zijn ongeldig."
[[ -s "${BACKUP_ARTIFACT_PATH}" ]] || die "De duurzaam geüploade back-up ontbreekt lokaal."
[[ "$(sha256sum "${BACKUP_ARTIFACT_PATH}" | cut -d' ' -f1)" == "${backup_checksum}" ]] \
  || die "De geüploade back-upchecksum wijkt af."
current_state_digest="$(node -e 'const v=require(process.argv[1]);process.stdout.write(v.state_digest)' "${preflight_path}")"
[[ "${current_state_digest}" == "${state_digest_after}" ]] \
  || die "Stagingdata wijzigde na de duurzaam geüploade back-up; maak een nieuwe back-up."

docker run --rm \
  --name "${dump_container}" \
  --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
  --env EXPECTED_STATE_DIGEST="${state_digest_after}" \
  --env RELEASE_SHA="${RELEASE_SHA}" \
  --env CLEANUP_RUN_ID="${CLEANUP_RUN_ID}" \
  --env BACKUP_CHECKSUM="${backup_checksum}" \
  --env BACKUP_ARTIFACT_ID="${BACKUP_ARTIFACT_ID}" \
  --volume "${PWD}:/workspace:ro" \
  --entrypoint sh \
  "${postgres_image}" \
  -ceu 'psql "$SOURCE_DB_URL" --no-psqlrc --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
    --set=expected_state_digest="$EXPECTED_STATE_DIGEST" \
    --set=release_sha="$RELEASE_SHA" \
    --set=cleanup_run_id="$CLEANUP_RUN_ID" \
    --set=backup_checksum="$BACKUP_CHECKSUM" \
    --set=backup_artifact_id="$BACKUP_ARTIFACT_ID" \
    --set=cleanup_commit=true \
    --file=/workspace/scripts/staging/sql/operational-cleanup-apply.sql' \
  > "${postcondition_path}"
chmod 0600 "${postcondition_path}"

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export STARTED_AT="${started_at}"
export COMPLETED_AT="${completed_at}"
export CLEANUP_PREFLIGHT_PATH="${preflight_path}"
export CLEANUP_POSTCONDITION_PATH="${postcondition_path}"
export BACKUP_CHECKSUM="${backup_checksum}"
export EXACT_RESTORE_PROVEN=true
export RUNTIME_RECOVERY_PROVEN=false
node scripts/staging/write-cleanup-evidence.mjs

restart_staging
for _ in $(seq 1 20); do
  if node scripts/deploy/check-http.mjs \
    "${STAGING_APP_URL}" staging "${RELEASE_SHA}" "${ARTIFACT_DIGEST}"; then
    break
  fi
  sleep 3
done
node scripts/deploy/check-http.mjs \
  "${STAGING_APP_URL}" staging "${RELEASE_SHA}" "${ARTIFACT_DIGEST}"
scheduler_container="$(compose ps -q scheduler)"
[[ -n "${scheduler_container}" ]] || die "De staging-scheduler is niet herstart."
for _ in $(seq 1 20); do
  scheduler_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "${scheduler_container}")"
  [[ "${scheduler_health}" == healthy ]] && break
  sleep 5
done
[[ "${scheduler_health:-missing}" == healthy ]] || die "De staging-scheduler werd niet gezond."

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export COMPLETED_AT="${completed_at}"
export RUNTIME_RECOVERY_PROVEN=true
node scripts/staging/write-cleanup-evidence.mjs
echo "Stagingdomeindata is atomair opgeschoond; staff/Auth/config bleven behouden en de encrypted back-up is herstelbaar bewezen."
