#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

source scripts/deploy/assert-runner-boundary.sh

: "${RELEASE_SHA:?RELEASE_SHA ontbreekt}"
: "${ARTIFACT_DIGEST:?ARTIFACT_DIGEST ontbreekt}"
: "${STAGING_APP_URL:?STAGING_APP_URL ontbreekt}"
: "${LEGACY_CAPTURE_DIRECTORY:?LEGACY_CAPTURE_DIRECTORY ontbreekt}"
: "${LEGACY_ADOPTION_RESULT_PATH:?LEGACY_ADOPTION_RESULT_PATH ontbreekt}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID ontbreekt}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT ontbreekt}"

readonly legacy_sha="a79c8d843d75e90810ccceb228538c6368d2198b"
readonly runtime_directory="/srv/apps/duindorpteneu/staging"
readonly compose_file="deploy/compose.vps.yml"
readonly compose_project="duindorpteneu-staging"
readonly runtime_env_file="${runtime_directory}/.env.runtime"
readonly current_manifest="${runtime_directory}/RELEASE_MANIFEST"
readonly current_revision_file="${runtime_directory}/REVISION"
readonly legacy_manifest="${LEGACY_CAPTURE_DIRECTORY}/LEGACY_RELEASE_MANIFEST"
readonly legacy_archive="${LEGACY_CAPTURE_DIRECTORY}/legacy-production-image.tar.gz"
readonly capture_evidence="${LEGACY_CAPTURE_DIRECTORY}/legacy-capture-evidence.json"
readonly capture_checksums="${LEGACY_CAPTURE_DIRECTORY}/SHA256SUMS"
readonly legacy_image="duindorpteneu-app:${legacy_sha}"
readonly current_image="duindorpteneu-app:${RELEASE_SHA}"

die() {
  echo "$1" >&2
  exit 1
}

[[ "${STAGING_APP_URL}" == "https://duindorpsv.dgwebservices.nl" ]] \
  || die "Legacy adoptie is uitsluitend voor de vaste staginghost."
[[ "${RELEASE_SHA}" =~ ^[a-f0-9]{40}$ \
  && "${RELEASE_SHA}" != "${legacy_sha}" \
  && "${ARTIFACT_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]] \
  || die "Releasecandidate-identiteit is ongeldig."
[[ "${LEGACY_ADOPTION_RESULT_PATH}" == \
  "${RUNNER_TEMP}/legacy-adoption-result-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.json" ]] \
  || die "Adoptiresultaatpad is niet run-uniek."
for command in docker flock gzip node sha256sum stat; do
  command -v "${command}" >/dev/null 2>&1 \
    || die "Vereist commando ontbreekt: ${command}"
done
assert_runner_boundary staging

for required in \
  "${legacy_manifest}" \
  "${legacy_archive}" \
  "${capture_evidence}" \
  "${capture_checksums}" \
  "${runtime_env_file}" \
  "${current_manifest}" \
  "${current_revision_file}"
do
  [[ -f "${required}" && ! -L "${required}" ]] \
    || die "Legacy- of candidatebestand ontbreekt of is een symlink."
done
(
  cd "${LEGACY_CAPTURE_DIRECTORY}"
  sha256sum --check SHA256SUMS
)
capture_evidence_hash="$(
  node scripts/deploy/legacy-adoption-evidence.mjs verify-capture \
    "${capture_evidence}" "${legacy_manifest}" "${legacy_archive}"
)"
[[ "${capture_evidence_hash}" =~ ^sha256:[a-f0-9]{64}$ ]] \
  || die "Legacy capturebewijs heeft geen geldige hash."

[[ "$(tr -d '\r\n' < "${current_revision_file}")" == "${RELEASE_SHA}" ]] \
  || die "Staging draait niet de gevraagde releasecandidate."
read -r current_oci current_config current_artifact < <(
  node scripts/deploy/release-manifest.mjs fields "${current_manifest}"
)
[[ "${current_artifact}" == "${ARTIFACT_DIGEST}" ]] \
  || die "Candidateartifact wijkt af van de stagingpreflight."
node scripts/deploy/release-manifest.mjs verify \
  "${current_manifest}" "${RELEASE_SHA}" "${current_oci}" \
  "${current_config}" "${current_artifact}" >/dev/null
read -r legacy_oci legacy_config legacy_artifact < <(
  node scripts/deploy/release-manifest.mjs fields "${legacy_manifest}"
)
node scripts/deploy/release-manifest.mjs verify \
  "${legacy_manifest}" "${legacy_sha}" "${legacy_oci}" \
  "${legacy_config}" "${legacy_artifact}" >/dev/null

exec 9>"${runtime_directory}/.deploy.lock"
chmod 600 "${runtime_directory}/.deploy.lock"
flock -n 9 || die "Stagingdeployment of -acceptatie is actief."

node scripts/deploy/check-http.mjs \
  "${STAGING_APP_URL}" staging "${RELEASE_SHA}" "${ARTIFACT_DIGEST}"
gzip -dc "${legacy_archive}" | docker load >/dev/null
legacy_loaded_digest="$(
  docker image inspect --format '{{.Id}}' "${legacy_image}"
)"
[[ "${legacy_loaded_digest}" == "${legacy_oci}"
  || "${legacy_loaded_digest}" == "${legacy_config}" ]] \
  || die "Geladen legacy-image wijkt af van het productionmanifest."
[[ "$(docker image inspect --format \
  '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' \
  "${legacy_image}")" == "${legacy_sha}" ]] \
  || die "Geladen legacy-image heeft een afwijkend releaselabel."
docker image inspect "${current_image}" >/dev/null

runtime_backup="$(mktemp "${runtime_directory}/.legacy-current-runtime.XXXXXX")"
legacy_runtime="$(mktemp "${runtime_directory}/.legacy-adopt-runtime.XXXXXX")"
cp -- "${runtime_env_file}" "${runtime_backup}"
node scripts/deploy/normalize-legacy-runtime.mjs \
  "${runtime_backup}" "${legacy_runtime}" staging \
  "${legacy_sha}" "${legacy_artifact}"
chmod 600 "${runtime_backup}" "${legacy_runtime}"

restored_candidate=false
compose() {
  APP_BIND_PORT=14000 \
    RUNTIME_ENV_FILE="${runtime_env_file}" \
    APP_IMAGE="$1" \
    docker compose -p "${compose_project}" -f "${compose_file}" "${@:2}"
}
check_scheduler() {
  local image="$1"
  local container health
  container="$(compose "${image}" ps -q scheduler)" || return 1
  [[ -n "${container}" ]] || return 1
  for _ in $(seq 1 20); do
    health="$(docker inspect --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      "${container}")" || return 1
    [[ "${health}" == healthy ]] && return 0
    sleep 3
  done
  return 1
}
stop_and_check_scheduler() {
  local image="$1"
  if ! compose "${image}" stop scheduler; then
    [[ -z "$(compose "${image}" ps -aq scheduler)" ]] || return 1
  fi
  [[ -z "$(compose "${image}" ps --status running -q scheduler)" ]]
}
check_candidate_http() {
  for _ in $(seq 1 20); do
    if node scripts/deploy/check-http.mjs \
      "${STAGING_APP_URL}" staging "${RELEASE_SHA}" "${ARTIFACT_DIGEST}"
    then
      return 0
    fi
    sleep 3
  done
  return 1
}
check_legacy_http() {
  local base_url="$1"
  for _ in $(seq 1 20); do
    if node scripts/deploy/check-legacy-http.mjs \
      "${base_url}" staging "${legacy_sha}"
    then
      return 0
    fi
    sleep 3
  done
  return 1
}
restore_candidate() {
  cp -- "${runtime_backup}" "${runtime_env_file}"
  chmod 600 "${runtime_env_file}"
  compose "${current_image}" up -d --no-build --remove-orphans
  check_candidate_http
  check_scheduler "${current_image}"
  restored_candidate=true
}
cleanup() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  if [[ "${restored_candidate}" != true ]] && ! restore_candidate; then
    echo "KRITIEK: releasecandidate kon na legacy-adoptie niet worden hersteld." >&2
    status=70
  fi
  rm -f -- "${runtime_backup}" "${legacy_runtime}"
  exit "${status}"
}
trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 129' HUP
trap 'cleanup 143' TERM

cp -- "${legacy_runtime}" "${runtime_env_file}"
chmod 600 "${runtime_env_file}"
stop_and_check_scheduler "${legacy_image}"
compose "${legacy_image}" up -d --no-build app
check_legacy_http "http://127.0.0.1:14000"
check_legacy_http "${STAGING_APP_URL}"
stop_and_check_scheduler "${legacy_image}"
restore_candidate

node scripts/deploy/legacy-adoption-evidence.mjs create-result \
  "${capture_evidence}" "${current_manifest}" \
  "${LEGACY_ADOPTION_RESULT_PATH}"
[[ -s "${LEGACY_ADOPTION_RESULT_PATH}" ]] \
  || die "Legacy adoptiresultaat ontbreekt."

temp_previous_revision="$(
  mktemp "${runtime_directory}/PREVIOUS_REVISION.XXXXXX"
)"
temp_previous_manifest="$(
  mktemp "${runtime_directory}/PREVIOUS_RELEASE_MANIFEST.XXXXXX"
)"
temp_previous_runtime="$(
  mktemp "${runtime_directory}/.env.runtime.previous-release.XXXXXX"
)"
temp_production_revision="$(
  mktemp "${runtime_directory}/PRODUCTION_ROLLBACK_REVISION.XXXXXX"
)"
temp_production_manifest="$(
  mktemp "${runtime_directory}/PRODUCTION_ROLLBACK_RELEASE_MANIFEST.XXXXXX"
)"
temp_production_runtime="$(
  mktemp "${runtime_directory}/.env.runtime.production-rollback.XXXXXX"
)"
temp_capture_evidence="$(
  mktemp "${runtime_directory}/LEGACY_ADOPTION_EVIDENCE.XXXXXX"
)"
temp_adoption_result="$(
  mktemp "${runtime_directory}/LEGACY_ADOPTION_RESULT.XXXXXX"
)"
printf '%s\n' "${legacy_sha}" > "${temp_previous_revision}"
cp -- "${legacy_manifest}" "${temp_previous_manifest}"
cp -- "${legacy_runtime}" "${temp_previous_runtime}"
printf '%s\n' "${legacy_sha}" > "${temp_production_revision}"
cp -- "${legacy_manifest}" "${temp_production_manifest}"
cp -- "${legacy_runtime}" "${temp_production_runtime}"
cp -- "${capture_evidence}" "${temp_capture_evidence}"
cp -- "${LEGACY_ADOPTION_RESULT_PATH}" "${temp_adoption_result}"
chmod 600 \
  "${temp_previous_revision}" \
  "${temp_previous_manifest}" \
  "${temp_previous_runtime}" \
  "${temp_production_revision}" \
  "${temp_production_manifest}" \
  "${temp_production_runtime}" \
  "${temp_capture_evidence}" \
  "${temp_adoption_result}"
mv -f -- "${temp_previous_revision}" \
  "${runtime_directory}/PREVIOUS_REVISION"
mv -f -- "${temp_previous_manifest}" \
  "${runtime_directory}/PREVIOUS_RELEASE_MANIFEST"
mv -f -- "${temp_previous_runtime}" \
  "${runtime_directory}/.env.runtime.previous-release"
mv -f -- "${temp_production_manifest}" \
  "${runtime_directory}/PRODUCTION_ROLLBACK_RELEASE_MANIFEST"
mv -f -- "${temp_production_runtime}" \
  "${runtime_directory}/.env.runtime.production-rollback"
mv -f -- "${temp_production_revision}" \
  "${runtime_directory}/PRODUCTION_ROLLBACK_REVISION"
mv -f -- "${temp_capture_evidence}" \
  "${runtime_directory}/LEGACY_ADOPTION_EVIDENCE"
# The result is the commit marker and is deliberately installed last.
mv -f -- "${temp_adoption_result}" \
  "${runtime_directory}/LEGACY_ADOPTION_RESULT"

rm -f -- "${runtime_backup}" "${legacy_runtime}"
trap - EXIT INT TERM HUP
echo "Legacy productionrelease is als eenmalig, bewezen stagingrollbacktarget geadopteerd."
