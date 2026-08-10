#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

source scripts/deploy/assert-runner-boundary.sh

: "${RELEASE_SHA:?RELEASE_SHA ontbreekt}"
: "${ARTIFACT_DIGEST:?ARTIFACT_DIGEST ontbreekt}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID ontbreekt}"

readonly action="${1:-}"
readonly runtime_directory="/srv/apps/duindorpteneu/staging"
readonly current_runtime="${runtime_directory}/.env.runtime"
readonly current_revision="${runtime_directory}/REVISION"
readonly current_manifest="${runtime_directory}/RELEASE_MANIFEST"
readonly pending_revision="${runtime_directory}/.production-rollback-${GITHUB_RUN_ID}.revision"
readonly pending_manifest="${runtime_directory}/.production-rollback-${GITHUB_RUN_ID}.manifest"
readonly pending_runtime="${runtime_directory}/.production-rollback-${GITHUB_RUN_ID}.runtime"
readonly durable_revision="${runtime_directory}/PRODUCTION_ROLLBACK_REVISION"
readonly durable_manifest="${runtime_directory}/PRODUCTION_ROLLBACK_RELEASE_MANIFEST"
readonly durable_runtime="${runtime_directory}/.env.runtime.production-rollback"

die() {
  echo "$1" >&2
  exit 1
}

[[ "${action}" == capture || "${action}" == commit || "${action}" == cleanup ]] \
  || die "Gebruik production-rollback-target.sh capture|commit|cleanup"
[[ "${RELEASE_SHA}" =~ ^[a-f0-9]{40}$ ]] \
  || die "RELEASE_SHA is ongeldig."
[[ "${ARTIFACT_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]] \
  || die "ARTIFACT_DIGEST is ongeldig."
[[ "${GITHUB_RUN_ID}" =~ ^[1-9][0-9]*$ ]] \
  || die "GITHUB_RUN_ID is ongeldig."
[[ "${EUID}" -ne 0 ]] \
  || die "Rollbackdoelsynchronisatie mag niet als root draaien."
assert_runner_boundary staging

exec 9>"${runtime_directory}/.deploy.lock"
chmod 600 "${runtime_directory}/.deploy.lock"
flock -n 9 || die "Stagingdeployment of -acceptatie is al actief."

if [[ "${action}" == cleanup ]]; then
  rm -f -- "${pending_revision}" "${pending_manifest}" "${pending_runtime}"
  exit 0
fi

validate_runtime() {
  local runtime_file="$1"
  node -e '
    const fs = require("node:fs");
    const [file, sha, digest] = process.argv.slice(1);
    const entries = Object.fromEntries(
      fs.readFileSync(file, "utf8").split(/\r?\n/u)
        .filter(Boolean).map((line) => {
          const separator = line.indexOf("=");
          if (separator < 1) process.exit(1);
          return [line.slice(0, separator), line.slice(separator + 1)];
        }),
    );
    if (
      entries.RELEASE_SHA !== sha
      || entries.RELEASE_ARTIFACT_DIGEST !== digest
    ) process.exit(1);
  ' "${runtime_file}" "${RELEASE_SHA}" "${ARTIFACT_DIGEST}" \
    || die "Stagingruntime is niet artifactgebonden."
}

validate_manifest() {
  local manifest_file="$1"
  local image_digest image_config_digest manifest_artifact
  read -r image_digest image_config_digest manifest_artifact < <(
    node scripts/deploy/release-manifest.mjs fields "${manifest_file}"
  )
  [[ "${manifest_artifact}" == "${ARTIFACT_DIGEST}" ]] \
    || die "Rollbackdoelmanifest heeft een afwijkend artifact."
  node scripts/deploy/release-manifest.mjs verify \
    "${manifest_file}" "${RELEASE_SHA}" "${image_digest}" \
    "${image_config_digest}" "${manifest_artifact}" >/dev/null
  docker image inspect "duindorpteneu-app:${RELEASE_SHA}" >/dev/null
  local loaded_digest
  loaded_digest="$(
    docker image inspect --format '{{.Id}}' \
      "duindorpteneu-app:${RELEASE_SHA}"
  )"
  [[ "${loaded_digest}" == "${image_digest}" \
    || "${loaded_digest}" == "${image_config_digest}" ]] \
    || die "Rollbackdoelimage wijkt af van het manifest."
}

if [[ "${action}" == capture ]]; then
  for required in "${current_runtime}" "${current_revision}" "${current_manifest}"; do
    [[ -f "${required}" && ! -L "${required}" ]] \
      || die "Actuele stagingrelease is onvolledig."
  done
  [[ "$(tr -d '\r\n' < "${current_revision}")" == "${RELEASE_SHA}" ]] \
    || die "Staging draait niet de promotiecandidate."
  validate_runtime "${current_runtime}"
  validate_manifest "${current_manifest}"

  revision_temp="$(mktemp "${pending_revision}.XXXXXX")"
  manifest_temp="$(mktemp "${pending_manifest}.XXXXXX")"
  runtime_temp="$(mktemp "${pending_runtime}.XXXXXX")"
  printf '%s\n' "${RELEASE_SHA}" > "${revision_temp}"
  cp -- "${current_manifest}" "${manifest_temp}"
  cp -- "${current_runtime}" "${runtime_temp}"
  chmod 600 "${revision_temp}" "${manifest_temp}" "${runtime_temp}"
  mv -f -- "${revision_temp}" "${pending_revision}"
  mv -f -- "${manifest_temp}" "${pending_manifest}"
  mv -f -- "${runtime_temp}" "${pending_runtime}"
  echo "Promotiecandidate is run-gebonden als pending rollbackdoel vastgelegd."
  exit 0
fi

for required in "${pending_revision}" "${pending_manifest}" "${pending_runtime}"; do
  [[ -f "${required}" && ! -L "${required}" ]] \
    || die "Pending rollbackdoel ontbreekt of is een symlink."
  [[ "$(stat -c '%a' "${required}")" == 600 ]] \
    || die "Pending rollbackdoel heeft onveilige bestandsrechten."
done
[[ "$(tr -d '\r\n' < "${pending_revision}")" == "${RELEASE_SHA}" ]] \
  || die "Pending rollbackdoel heeft een afwijkende release."
validate_runtime "${pending_runtime}"
validate_manifest "${pending_manifest}"

revision_temp="$(mktemp "${durable_revision}.XXXXXX")"
manifest_temp="$(mktemp "${durable_manifest}.XXXXXX")"
runtime_temp="$(mktemp "${durable_runtime}.XXXXXX")"
cp -- "${pending_revision}" "${revision_temp}"
cp -- "${pending_manifest}" "${manifest_temp}"
cp -- "${pending_runtime}" "${runtime_temp}"
chmod 600 "${revision_temp}" "${manifest_temp}" "${runtime_temp}"
mv -f -- "${manifest_temp}" "${durable_manifest}"
mv -f -- "${runtime_temp}" "${durable_runtime}"
# De revision is de commitmarker en wordt bewust als laatste geïnstalleerd.
mv -f -- "${revision_temp}" "${durable_revision}"
rm -f -- "${pending_revision}" "${pending_manifest}" "${pending_runtime}"
echo "Actuele productionrelease is duurzaam als volgend stagingrollbackdoel vastgelegd."
