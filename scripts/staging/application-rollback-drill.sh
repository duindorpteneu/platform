#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source scripts/deploy/assert-runner-boundary.sh

: "${RELEASE_SHA:?RELEASE_SHA ontbreekt}"
: "${ARTIFACT_DIGEST:?ARTIFACT_DIGEST ontbreekt}"
: "${STAGING_APP_URL:?STAGING_APP_URL ontbreekt}"
: "${CONFIRMATION:?CONFIRMATION ontbreekt}"
: "${ROLLBACK_EVIDENCE_PATH:?ROLLBACK_EVIDENCE_PATH ontbreekt}"

readonly runtime_directory="/srv/apps/duindorpteneu/staging"
readonly compose_file="deploy/compose.vps.yml"
readonly compose_project="duindorpteneu-staging"
readonly runtime_env_file="${runtime_directory}/.env.runtime"
readonly previous_runtime_file="${runtime_directory}/.env.runtime.production-rollback"
readonly current_manifest="${runtime_directory}/RELEASE_MANIFEST"
readonly previous_manifest="${runtime_directory}/PRODUCTION_ROLLBACK_RELEASE_MANIFEST"
readonly previous_revision_file="${runtime_directory}/PRODUCTION_ROLLBACK_REVISION"
readonly current_image="duindorpteneu-app:${RELEASE_SHA}"
readonly legacy_sha="a79c8d843d75e90810ccceb228538c6368d2198b"
readonly legacy_capture_evidence="${runtime_directory}/LEGACY_ADOPTION_EVIDENCE"
readonly legacy_adoption_result="${runtime_directory}/LEGACY_ADOPTION_RESULT"

die() {
  echo "$1" >&2
  exit 1
}

[[ "${CONFIRMATION}" == "STAGING-ROLLBACK" ]] \
  || die "Bevestiging is ongeldig."
[[ "${STAGING_APP_URL}" == "https://staging-duindorp.dgwebservices.nl" ]] \
  || die "Alleen de vaste staginghost is toegestaan."
[[ "${RELEASE_SHA}" =~ ^[a-f0-9]{40}$ ]] \
  || die "RELEASE_SHA is ongeldig."
[[ "${ARTIFACT_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]] \
  || die "ARTIFACT_DIGEST is ongeldig."
[[ "$(git rev-parse HEAD)" == "${RELEASE_SHA}" ]] \
  || die "Checkout en release verschillen."
[[ "${EUID}" -ne 0 ]] \
  || die "Rollbackdrill mag niet als root draaien."
for command in docker flock node; do
  command -v "${command}" >/dev/null 2>&1 \
    || die "Vereist commando ontbreekt: ${command}"
done
assert_runner_boundary staging
for required_file in \
  "${runtime_env_file}" \
  "${previous_runtime_file}" \
  "${current_manifest}" \
  "${previous_manifest}" \
  "${runtime_directory}/REVISION" \
  "${previous_revision_file}"
do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] \
    || die "Rollbackbron ontbreekt of is een symlink."
done

exec 9>"${runtime_directory}/.deploy.lock"
chmod 600 "${runtime_directory}/.deploy.lock"
flock -n 9 || die "Stagingdeployment of -acceptatie is al actief."

current_revision="$(tr -d '\r\n' < "${runtime_directory}/REVISION")"
previous_revision="$(tr -d '\r\n' < "${previous_revision_file}")"
[[ "${current_revision}" == "${RELEASE_SHA}" ]] \
  || die "Stagingrevision wijkt af."
[[ "${previous_revision}" =~ ^[a-f0-9]{40}$ ]] \
  || die "Duurzame productionrollbackrevision is ongeldig."
[[ "${previous_revision}" != "${current_revision}" ]] \
  || die "Rollbackdrill vereist een nieuwe candidate naast production."

read -r current_digest current_config_digest current_artifact < <(
  node scripts/deploy/release-manifest.mjs fields "${current_manifest}"
)
read -r previous_digest previous_config_digest previous_artifact < <(
  node scripts/deploy/release-manifest.mjs fields "${previous_manifest}"
)
[[ "${current_artifact}" == "${ARTIFACT_DIGEST}" ]] \
  || die "Huidig stagingmanifest wijkt af van de preflight."
node scripts/deploy/release-manifest.mjs verify \
  "${previous_manifest}" "${previous_revision}" "${previous_digest}" \
  "${previous_config_digest}" "${previous_artifact}" >/dev/null
previous_image="duindorpteneu-app:${previous_revision}"
docker image inspect "${current_image}" "${previous_image}" >/dev/null
current_loaded_digest="$(
  docker image inspect --format '{{.Id}}' "${current_image}"
)"
previous_loaded_digest="$(
  docker image inspect --format '{{.Id}}' "${previous_image}"
)"
[[ "${current_loaded_digest}" == "${current_digest}" \
  || "${current_loaded_digest}" == "${current_config_digest}" ]] \
  || die "Huidige stagingimage wijkt af van het herstelmanifest."
[[ "${previous_loaded_digest}" == "${previous_digest}" \
  || "${previous_loaded_digest}" == "${previous_config_digest}" ]] \
  || die "Vorige stagingimage wijkt af van het herstelmanifest."

previous_health_contract="artifact-v2"
previous_scheduler_expected=true
legacy_adoption_evidence_sha256=""
legacy_adoption_run_id=""
if [[ "${previous_revision}" == "${legacy_sha}" ]]; then
  [[ -f "${legacy_capture_evidence}" && ! -L "${legacy_capture_evidence}"
    && -f "${legacy_adoption_result}" && ! -L "${legacy_adoption_result}" ]] \
    || die "Legacy rollbacktarget mist gecommitteerd adoptiebewijs."
  legacy_adoption_run_id="$(
    node -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (!Number.isSafeInteger(value.adoption_workflow_run_id)
        || value.adoption_workflow_run_id < 1) process.exit(1);
      process.stdout.write(String(value.adoption_workflow_run_id));
    ' "${legacy_adoption_result}"
  )"
  legacy_adoption_evidence_sha256="$(
    node scripts/deploy/legacy-adoption-evidence.mjs verify-provenance \
      "${legacy_adoption_result}" "${legacy_capture_evidence}" \
      "${legacy_adoption_run_id}"
  )"
  [[ "${legacy_adoption_evidence_sha256}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "Legacy adoptiebewijs heeft een ongeldige hash."
  previous_health_contract="legacy-v1-exact-four-fields"
  previous_scheduler_expected=false
fi

node -e '
  const fs = require("node:fs");
  const [file, sha, digest] = process.argv.slice(1);
  const entries = Object.fromEntries(
    fs.readFileSync(file, "utf8").split(/\r?\n/)
      .filter(Boolean).map((line) => {
        const split = line.indexOf("=");
        return [line.slice(0, split), line.slice(split + 1)];
      }),
  );
  if (entries.RELEASE_SHA !== sha
    || entries.RELEASE_ARTIFACT_DIGEST !== digest) process.exit(1);
' "${previous_runtime_file}" "${previous_revision}" "${previous_artifact}" \
  || die "Vorige runtime-identiteit is niet artifactgebonden."

runtime_backup="$(mktemp "${runtime_directory}/.rollback-current.XXXXXX")"
previous_drill_runtime="$(
  mktemp "${runtime_directory}/.rollback-previous-no-send.XXXXXX"
)"
cp -f -- "${runtime_env_file}" "${runtime_backup}"
node scripts/deploy/normalize-legacy-runtime.mjs \
  "${previous_runtime_file}" "${previous_drill_runtime}" staging \
  "${previous_revision}" "${previous_artifact}"
chmod 600 "${runtime_backup}" "${previous_drill_runtime}"
restored_current=false

compose() {
  APP_BIND_PORT=14000 \
    RUNTIME_ENV_FILE="${runtime_env_file}" \
    APP_IMAGE="$1" \
    docker compose -p "${compose_project}" -f "${compose_file}" "${@:2}"
}

check_release() {
  local revision="$1"
  local artifact="$2"
  local health_contract="$3"
  local url
  for url in "http://127.0.0.1:14000" "${STAGING_APP_URL}"; do
    local passed=false
    for _ in $(seq 1 20); do
      if [[ "${health_contract}" == "legacy-v1-exact-four-fields" ]] \
        && node scripts/deploy/check-legacy-http.mjs \
          "${url}" staging "${revision}"
      then
        passed=true
        break
      elif [[ "${health_contract}" == "artifact-v2" ]] \
        && node scripts/deploy/check-http.mjs \
          "${url}" staging "${revision}" "${artifact}"
      then
        passed=true
        break
      fi
      sleep 3
    done
    [[ "${passed}" == true ]] || return 1
  done
}

check_scheduler() {
  local image="$1"
  local container health
  container="$(compose "${image}" ps -q scheduler)" || return 1
  [[ -n "${container}" ]] || return 1
  for _ in $(seq 1 20); do
    health="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
        "${container}"
    )" || return 1
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

check_stack() {
  check_release "$2" "$3" "$4"
  if [[ "$5" == true ]]; then
    check_scheduler "$1"
  else
    stop_and_check_scheduler "$1"
  fi
}

restore_current() {
  cp -f -- "${runtime_backup}" "${runtime_env_file}"
  chmod 600 "${runtime_env_file}"
  compose "${current_image}" up -d --no-build --remove-orphans
  check_stack "${current_image}" "${current_revision}" "${current_artifact}" \
    "artifact-v2" true
  restored_current=true
}

cleanup() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  if [[ "${restored_current}" != true ]]; then
    if ! restore_current; then
      echo "KRITIEK: staging kon na de rollbackdrill niet worden hersteld." >&2
      status=70
    fi
  fi
  rm -f -- "${runtime_backup}" "${previous_drill_runtime}"
  exit "${status}"
}
trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 129' HUP
trap 'cleanup 143' TERM

check_stack "${current_image}" "${current_revision}" "${current_artifact}" \
  "artifact-v2" true
cp -f -- "${previous_drill_runtime}" "${runtime_env_file}"
chmod 600 "${runtime_env_file}"
if [[ "${previous_scheduler_expected}" == true ]]; then
  compose "${previous_image}" up -d --no-build --remove-orphans
else
  stop_and_check_scheduler "${previous_image}"
  compose "${previous_image}" up -d --no-build app
fi
check_stack "${previous_image}" "${previous_revision}" "${previous_artifact}" \
  "${previous_health_contract}" "${previous_scheduler_expected}"
restore_current

node -e '
  const fs = require("node:fs");
  const [
    target,
    currentSha,
    currentOci,
    currentConfig,
    currentArtifact,
    previousSha,
    previousOci,
    previousConfig,
    previousArtifact,
    previousHealthContract,
    previousSchedulerExpected,
    legacyEvidenceSha256,
    legacyAdoptionRunId,
  ] = process.argv.slice(1);
  fs.writeFileSync(target, `${JSON.stringify({
    schema_version: 2,
    result: "passed",
    environment: "staging",
    current_release_sha: currentSha,
    current_oci_digest: currentOci,
    current_config_digest: currentConfig,
    current_artifact_digest: currentArtifact,
    previous_release_sha: previousSha,
    previous_oci_digest: previousOci,
    previous_config_digest: previousConfig,
    previous_artifact_digest: previousArtifact,
    previous_health_contract: previousHealthContract,
    previous_scheduler_expected: previousSchedulerExpected === "true",
    legacy_adoption_evidence_sha256:
      legacyEvidenceSha256 || null,
    legacy_adoption_run_id:
      legacyAdoptionRunId ? Number(legacyAdoptionRunId) : null,
    restored_current_release: true,
    app_health_proven: true,
    scheduler_health_proven: true,
    rollback_provider_send_disabled: true,
    database_rollback_attempted: false,
    created_at: new Date().toISOString(),
  }, null, 2)}\n`, { mode: 0o600 });
' "${ROLLBACK_EVIDENCE_PATH}" \
  "${current_revision}" "${current_digest}" "${current_config_digest}" \
  "${current_artifact}" "${previous_revision}" "${previous_digest}" \
  "${previous_config_digest}" "${previous_artifact}" \
  "${previous_health_contract}" "${previous_scheduler_expected}" \
  "${legacy_adoption_evidence_sha256}" \
  "${legacy_adoption_run_id}"
echo "Staging applicatierollback en terugkeer naar de releasecandidate zijn artifactgebonden bewezen."
