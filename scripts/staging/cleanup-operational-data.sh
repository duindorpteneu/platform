#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${TARGET_ENVIRONMENT:?TARGET_ENVIRONMENT ontbreekt}"
: "${TARGET_OPERATION:?TARGET_OPERATION ontbreekt}"
: "${CLEANUP_MODE:?CLEANUP_MODE ontbreekt}"
: "${STAGING_APP_URL:?STAGING_APP_URL ontbreekt}"
: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF ontbreekt}"
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL ontbreekt}"
: "${RELEASE_SHA:?RELEASE_SHA ontbreekt}"
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
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

[[ "${postgres_image}" == "${expected_postgres_image}" ]] || die "PostgreSQL-image wijkt af van de gepinde digest."
[[ "${TARGET_OPERATION}" == cleanup ]] || die "Alleen de cleanupoperatie is toegestaan."
[[ "${CLEANUP_MODE}" == dry-run || "${CLEANUP_MODE}" == apply ]] || die "CLEANUP_MODE is ongeldig."
[[ "$(git rev-parse HEAD)" == "${RELEASE_SHA}" ]] || die "Checkout en RELEASE_SHA verschillen."

for command in docker node sha256sum; do require_command "${command}"; done
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
    if (value.schema_version !== 1 || value.cleanup_table_count !== 90 || value.preserved_table_count !== 27) process.exit(1);
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

: "${STAGING_CLEANUP_BACKUP_PASSPHRASE:?STAGING_CLEANUP_BACKUP_PASSPHRASE ontbreekt}"
: "${BACKUP_ARTIFACT_PATH:?BACKUP_ARTIFACT_PATH ontbreekt}"
: "${BACKUP_ARTIFACT_NAME:?BACKUP_ARTIFACT_NAME ontbreekt}"
: "${CLEANUP_RUN_ID:?CLEANUP_RUN_ID ontbreekt}"
: "${MOLLIE_ENABLED:?MOLLIE_ENABLED ontbreekt}"
: "${EMAIL_ENABLED:?EMAIL_ENABLED ontbreekt}"
: "${DYNAMIC_IMPORT_ENABLED:?DYNAMIC_IMPORT_ENABLED ontbreekt}"

[[ "${#STAGING_CLEANUP_BACKUP_PASSPHRASE}" -ge 32 ]] || die "De cleanup-backuppassphrase is te kort."
[[ "${MOLLIE_ENABLED}" == false && "${EMAIL_ENABLED}" == false && "${DYNAMIC_IMPORT_ENABLED}" == false ]] \
  || die "Runtimeproviders en dynamische import moeten vóór cleanup uitstaan."
[[ "${BACKUP_ARTIFACT_PATH}" == "${RUNNER_TEMP}/"*".gpg" ]] || die "Backupartifact moet een run-uniek versleuteld tijdelijk bestand zijn."
[[ "${BACKUP_ARTIFACT_NAME}" =~ ^staging-domain-backup-[a-f0-9-]+$ ]] || die "Backupartifactnaam is ongeldig."
[[ "${CLEANUP_RUN_ID}" =~ ^[a-f0-9-]{36}$ ]] || die "Cleanup-run-ID is ongeldig."

for command in flock gpg openssl stat; do require_command "${command}"; done
[[ "${EUID}" -ne 0 ]] || die "Cleanup als root is niet toegestaan."
[[ "${USER:-}" == deploy && "${HOME:-}" == /home/deploy ]] || die "Cleanup moet onder de geïsoleerde deploygebruiker draaien."
deploy_uid="$(id -u)"
expected_socket="/run/user/${deploy_uid}/docker.sock"
[[ "${DOCKER_HOST:-}" == "unix://${expected_socket}" && -S "${expected_socket}" ]] \
  || die "De Rootless Docker-socket klopt niet."
[[ "$(stat -c '%u' "${expected_socket}")" == "${deploy_uid}" ]] || die "De Rootless Docker-socket heeft een verkeerde eigenaar."
[[ "$(docker info --format '{{json .SecurityOptions}}')" == *rootless* ]] || die "De Dockerdaemon is niet Rootless."
[[ ! -L "${runtime_directory}" && -d "${runtime_directory}" && -O "${runtime_directory}" ]] \
  || die "Het stagingruntimepad is ongeldig."
[[ -f "${runtime_directory}/REVISION" && "$(tr -d '\r\n' < "${runtime_directory}/REVISION")" == "${RELEASE_SHA}" ]] \
  || die "Het stagingruntimepad draait niet de gevraagde release."
[[ -f "${runtime_env_file}" && ! -L "${runtime_env_file}" ]] || die "Het stagingruntimebestand ontbreekt of is een symlink."
docker image inspect "${image_tag}" >/dev/null
[[ "$(docker image inspect --format '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' "${image_tag}")" == "${RELEASE_SHA}" ]] \
  || die "De stagingimage heeft een afwijkend releaselabel."

exec 9>"${runtime_directory}/.deploy.lock"
chmod 0600 "${runtime_directory}/.deploy.lock"
flock -n 9 || die "Er draait al een stagingdeployment of cleanup."

for service in app scheduler; do
  container_id="$(compose ps -q "${service}")"
  [[ -n "${container_id}" ]] || die "De staging-${service}container ontbreekt."
  [[ "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "${container_id}")" == "${compose_project}" ]] \
    || die "De ${service}container hoort niet bij het stagingproject."
  [[ "$(docker inspect --format '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' "${container_id}")" == "${RELEASE_SHA}" ]] \
    || die "De ${service}container draait niet de gevraagde release."
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

: > "${raw_dump_path}"
chmod 0600 "${raw_dump_path}"
echo "Vers logische stagingherstelpunt wordt gemaakt."
source_major="$(docker run --rm \
  --name "${dump_container}" \
  --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
  --entrypoint sh \
  "${postgres_image}" \
  -ceu 'psql "$SOURCE_DB_URL" --no-psqlrc --tuples-only --no-align \
    --command="select current_setting('"'"'server_version_num'"'"')::integer / 10000"')"
[[ "${source_major}" == 17 ]] || die "De brondatabase draait niet op PostgreSQL 17."

docker run --rm \
  --name "${dump_container}" \
  --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
  --entrypoint sh \
  "${postgres_image}" \
  -ceu 'pg_dump --format=custom --compress=6 --no-owner --no-acl --strict-names \
    --schema=app --schema=private --schema=public --schema=auth --schema=supabase_migrations \
    --dbname="$SOURCE_DB_URL"' \
  > "${raw_dump_path}"
[[ -s "${raw_dump_path}" && "$(stat -c '%a' "${raw_dump_path}")" == 600 ]] || die "De logische back-up is ongeldig."

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
docker exec "${restore_container}" createdb --username postgres --template template0 restore_cleanup
docker exec "${restore_container}" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username postgres --dbname restore_cleanup --command='drop schema if exists public cascade;'
docker exec --interactive "${restore_container}" pg_restore --exit-on-error --no-owner --no-acl \
  --username postgres --dbname restore_cleanup < "${restored_dump_path}"
docker exec --interactive "${restore_container}" psql --no-psqlrc --quiet --tuples-only --no-align \
  --username postgres --dbname restore_cleanup < scripts/staging/restore-verify.sql \
  > "${restore_verification_path}"
node -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.postgres_major !== 17 || value.invalid_constraints !== 0) process.exit(1);
' "${restore_verification_path}"
rm -f -- "${restored_dump_path}" "${passphrase_path}"
docker rm --force --volumes "${restore_container}" >/dev/null

docker run --rm \
  --name "${dump_container}" \
  --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
  --env EXPECTED_STATE_DIGEST="${state_digest_after}" \
  --env RELEASE_SHA="${RELEASE_SHA}" \
  --env CLEANUP_RUN_ID="${CLEANUP_RUN_ID}" \
  --env BACKUP_CHECKSUM="${backup_checksum}" \
  --volume "${PWD}:/workspace:ro" \
  --entrypoint sh \
  "${postgres_image}" \
  -ceu 'psql "$SOURCE_DB_URL" --no-psqlrc --set=ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
    --set=expected_state_digest="$EXPECTED_STATE_DIGEST" \
    --set=release_sha="$RELEASE_SHA" \
    --set=cleanup_run_id="$CLEANUP_RUN_ID" \
    --set=backup_checksum="$BACKUP_CHECKSUM" \
    --set=cleanup_commit=true \
    --file=/workspace/scripts/staging/sql/operational-cleanup-apply.sql' \
  > "${postcondition_path}"
chmod 0600 "${postcondition_path}"

restart_staging
for _ in $(seq 1 20); do
  if node scripts/deploy/check-http.mjs "${STAGING_APP_URL}" staging "${RELEASE_SHA}"; then
    break
  fi
  sleep 3
done
node scripts/deploy/check-http.mjs "${STAGING_APP_URL}" staging "${RELEASE_SHA}"
scheduler_container="$(compose ps -q scheduler)"
[[ -n "${scheduler_container}" ]] || die "De staging-scheduler is niet herstart."
for _ in $(seq 1 20); do
  scheduler_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "${scheduler_container}")"
  [[ "${scheduler_health}" == healthy ]] && break
  sleep 5
done
[[ "${scheduler_health:-missing}" == healthy ]] || die "De staging-scheduler werd niet gezond."

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export STARTED_AT="${started_at}"
export COMPLETED_AT="${completed_at}"
export CLEANUP_PREFLIGHT_PATH="${preflight_path}"
export CLEANUP_POSTCONDITION_PATH="${postcondition_path}"
export BACKUP_CHECKSUM="${backup_checksum}"
node scripts/staging/write-cleanup-evidence.mjs
echo "Stagingdomeindata is atomair opgeschoond; staff/Auth/config bleven behouden en de encrypted back-up is herstelbaar bewezen."
