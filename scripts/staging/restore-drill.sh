#!/usr/bin/env bash
set -Eeuo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP ontbreekt}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID ontbreekt}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT ontbreekt}"
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL ontbreekt}"
: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF ontbreekt}"
: "${RELEASE_SHA:?RELEASE_SHA ontbreekt}"

expected_postgres_image="public.ecr.aws/supabase/postgres:17.6.1.143@sha256:80d7b27c3e8d77cfa7226eee9508671796da214781ff15a35b3670d7ad5ee453"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-${expected_postgres_image}}"
[[ "${POSTGRES_IMAGE}" == "${expected_postgres_image}" ]]

run_key="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
container_name="duindorp-restore-${run_key}"
dump_container_name="duindorp-dump-${run_key}"
dump_path="${RUNNER_TEMP}/duindorp-restore-${run_key}.dump"
verification_path="${RUNNER_TEMP}/duindorp-restore-${run_key}-verification.json"
evidence_path="${RUNNER_TEMP}/duindorp-restore-${run_key}-evidence.json"
label="nl.duindorpteneu.restore-run=${run_key}"
started_epoch="$(date -u +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
backup_snapshot_epoch="${started_epoch}"
backup_snapshot_at="${started_at}"

cleanup() {
  docker rm --force --volumes "${container_name}" >/dev/null 2>&1 || true
  docker rm --force --volumes "${dump_container_name}" >/dev/null 2>&1 || true
  rm -f -- "${dump_path}" "${verification_path}"
}
trap cleanup EXIT INT TERM

umask 077
: > "${dump_path}"
chmod 0600 "${dump_path}"

echo "PostgreSQL 17 logische stagingback-up wordt gemaakt."
source_major="$(docker run --rm \
  --name "${dump_container_name}" \
  --label "${label}" \
  --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
  --entrypoint sh \
  "${POSTGRES_IMAGE}" \
  -ceu 'psql "$SOURCE_DB_URL" --no-psqlrc --tuples-only --no-align --command="select current_setting('"'"'server_version_num'"'"')::integer / 10000"')"
[[ "${source_major}" == "17" ]]

docker run --rm \
  --name "${dump_container_name}" \
  --label "${label}" \
  --env SOURCE_DB_URL="${SUPABASE_DB_URL}" \
  --entrypoint sh \
  "${POSTGRES_IMAGE}" \
  -ceu 'pg_dump --format=custom --compress=6 --no-owner --no-acl --strict-names \
    --schema=app --schema=private --schema=public --schema=auth --schema=supabase_migrations \
    --dbname="$SOURCE_DB_URL"' \
  > "${dump_path}"

[[ -s "${dump_path}" ]]
[[ "$(stat -c '%a' "${dump_path}")" == "600" ]]

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
  if docker logs "${container_name}" 2>&1 | grep -Fq "${init_complete_marker}" \
    && docker exec "${container_name}" pg_isready --quiet --username postgres --dbname postgres; then
    break
  fi
  sleep 2
done
docker logs "${container_name}" 2>&1 | grep -Fq "${init_complete_marker}"
docker exec "${container_name}" pg_isready --quiet --username postgres --dbname postgres
docker exec "${container_name}" createdb --username postgres --template template0 restore_drill

echo "Back-up wordt in een netwerkloze, run-unieke PostgreSQL 17-container hersteld."
docker exec --interactive "${container_name}" \
  pg_restore --exit-on-error --no-owner --no-acl --username postgres --dbname restore_drill \
  < "${dump_path}"

docker exec --interactive "${container_name}" \
  psql --no-psqlrc --quiet --tuples-only --no-align --username postgres --dbname restore_drill \
  < scripts/staging/restore-verify.sql \
  > "${verification_path}"
chmod 0600 "${verification_path}"

completed_epoch="$(date -u +%s)"
completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export STARTED_AT="${started_at}"
export BACKUP_SNAPSHOT_AT="${backup_snapshot_at}"
export COMPLETED_AT="${completed_at}"
export RPO_SECONDS="$((completed_epoch - backup_snapshot_epoch))"
export RTO_SECONDS="$((completed_epoch - started_epoch))"
export RESTORE_VERIFICATION_PATH="${verification_path}"
export RESTORE_EVIDENCE_PATH="${evidence_path}"

node scripts/staging/write-restore-evidence.mjs
echo "Restore-oefening is binnen RPO/RTO afgerond; alleen geredigeerd bewijs blijft beschikbaar."
