#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

source scripts/deploy/assert-runner-boundary.sh

: "${RUNNER_TEMP:?RUNNER_TEMP ontbreekt}"
: "${LEGACY_CAPTURE_DIRECTORY:?LEGACY_CAPTURE_DIRECTORY ontbreekt}"
: "${PRODUCTION_BASE_URL:?PRODUCTION_BASE_URL ontbreekt}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID ontbreekt}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT ontbreekt}"

readonly legacy_sha="a79c8d843d75e90810ccceb228538c6368d2198b"
readonly runtime_directory="/srv/apps/duindorpteneu/production"
readonly manifest_path="${runtime_directory}/RELEASE_MANIFEST"
readonly revision_path="${runtime_directory}/REVISION"
readonly image_tag="duindorpteneu-app:${legacy_sha}"
readonly compose_file="deploy/compose.vps.yml"
readonly compose_project="duindorpteneu-production"
readonly archive_path="${LEGACY_CAPTURE_DIRECTORY}/legacy-production-image.tar.gz"
readonly captured_manifest="${LEGACY_CAPTURE_DIRECTORY}/LEGACY_RELEASE_MANIFEST"
readonly evidence_path="${LEGACY_CAPTURE_DIRECTORY}/legacy-capture-evidence.json"

die() {
  echo "$1" >&2
  exit 1
}

[[ "${LEGACY_CAPTURE_DIRECTORY}" == \
  "${RUNNER_TEMP}/legacy-production-capture-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" ]] \
  || die "Capturedirectory moet run-uniek onder RUNNER_TEMP staan."
[[ "${PRODUCTION_BASE_URL}" == "https://duindorp.dgwebservices.nl" ]] \
  || die "Legacy capture is uitsluitend voor de vaste productiehost."
for command in docker flock gzip node sha256sum stat tar; do
  command -v "${command}" >/dev/null 2>&1 \
    || die "Vereist commando ontbreekt: ${command}"
done
assert_runner_boundary production

[[ -f "${manifest_path}" && ! -L "${manifest_path}"
  && -f "${revision_path}" && ! -L "${revision_path}"
  && "$(tr -d '\r\n' < "${revision_path}")" == "${legacy_sha}" ]] \
  || die "Productie draait niet exact de eenmalig toegestane legacyrelease."
read -r image_digest config_digest artifact_digest < <(
  node scripts/deploy/release-manifest.mjs fields "${manifest_path}"
)
node scripts/deploy/release-manifest.mjs verify \
  "${manifest_path}" "${legacy_sha}" "${image_digest}" \
  "${config_digest}" "${artifact_digest}" >/dev/null

[[ -f "${runtime_directory}/.deploy.lock"
  && ! -L "${runtime_directory}/.deploy.lock" ]] \
  || die "Production deploylock ontbreekt."
exec 9<>"${runtime_directory}/.deploy.lock"
flock -n 9 || die "Productiondeployment is actief."

app_container="$(
  APP_IMAGE="${image_tag}" \
    RUNTIME_ENV_FILE="${runtime_directory}/.env.runtime" \
    APP_BIND_PORT=24000 \
    docker compose -p "${compose_project}" -f "${compose_file}" ps -q app
)"
[[ -n "${app_container}" ]] || die "Productionappcontainer ontbreekt."
[[ "$(docker inspect --format \
  '{{index .Config.Labels "com.docker.compose.project"}}' \
  "${app_container}")" == "${compose_project}" ]] \
  || die "Productionappcontainer hoort niet bij het productionproject."
[[ "$(docker inspect --format \
  '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' \
  "${app_container}")" == "${legacy_sha}" ]] \
  || die "Productionappcontainer heeft een afwijkend releaselabel."
loaded_digest="$(docker image inspect --format '{{.Id}}' "${image_tag}")"
container_image_id="$(
  docker inspect --format '{{.Image}}' "${app_container}"
)"
[[ "${loaded_digest}" == "${config_digest}"
  && "${container_image_id}" == "${loaded_digest}" ]] \
  || die "Draaiende legacy-image wijkt af van het productionmanifest."

state_before="$(
  printf '%s|%s|%s|%s|%s' \
    "$(tr -d '\r\n' < "${revision_path}")" \
    "$(sha256sum "${manifest_path}" | cut -d' ' -f1)" \
    "${app_container}" "${container_image_id}" "${loaded_digest}"
)"
node scripts/deploy/check-legacy-http.mjs \
  "${PRODUCTION_BASE_URL}" production "${legacy_sha}"

rm -rf -- "${LEGACY_CAPTURE_DIRECTORY}"
mkdir -p "${LEGACY_CAPTURE_DIRECTORY}"
chmod 700 "${LEGACY_CAPTURE_DIRECTORY}"
image_tar="$(mktemp "${RUNNER_TEMP}/legacy-production-image.XXXXXX.tar")"
trap 'rm -f -- "${image_tar:-}"' EXIT INT TERM HUP
docker save --output "${image_tar}" "${image_tag}"
archive_manifest_digest="$(
  tar -xOf "${image_tar}" index.json \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s);if(x.manifests?.length!==1)process.exit(1);process.stdout.write(x.manifests[0].digest)})'
)"
archive_config_path="$(
  tar -xOf "${image_tar}" manifest.json \
    | IMAGE_TAG="${image_tag}" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s).filter(v=>v.RepoTags?.includes(process.env.IMAGE_TAG));if(x.length!==1)process.exit(1);process.stdout.write(x[0].Config)})'
)"
[[ "${archive_manifest_digest}" == "${image_digest}" ]] \
  || die "Recovered archive bevat een andere OCI-manifestdigest."
[[ "${archive_config_path}" == "blobs/sha256/${config_digest#sha256:}" ]] \
  || die "Recovered archive bevat een andere imageconfig."
[[ "sha256:$(tar -xOf "${image_tar}" \
  "blobs/sha256/${image_digest#sha256:}" | sha256sum | cut -d' ' -f1)" \
  == "${image_digest}" ]] \
  || die "Recovered OCI-manifestblob is gewijzigd."
[[ "sha256:$(tar -xOf "${image_tar}" "${archive_config_path}" \
  | sha256sum | cut -d' ' -f1)" == "${config_digest}" ]] \
  || die "Recovered imageconfigblob is gewijzigd."
[[ "$(docker inspect --format '{{.Image}}' "${app_container}")" \
  == "${container_image_id}"
  && "$(docker image inspect --format '{{.Id}}' "${image_tag}")" \
  == "${loaded_digest}" ]] \
  || die "Draaiende image of lokale tag wijzigde tijdens de capture."

gzip -9n -c "${image_tar}" > "${archive_path}"
cp -- "${manifest_path}" "${captured_manifest}"
chmod 600 "${archive_path}" "${captured_manifest}"
node scripts/deploy/legacy-adoption-evidence.mjs create-capture \
  "${captured_manifest}" "${archive_path}" "${evidence_path}"
chmod 600 "${evidence_path}"

node scripts/deploy/check-legacy-http.mjs \
  "${PRODUCTION_BASE_URL}" production "${legacy_sha}"
state_after="$(
  printf '%s|%s|%s|%s|%s' \
    "$(tr -d '\r\n' < "${revision_path}")" \
    "$(sha256sum "${manifest_path}" | cut -d' ' -f1)" \
    "$(
      APP_IMAGE="${image_tag}" \
        RUNTIME_ENV_FILE="${runtime_directory}/.env.runtime" \
        APP_BIND_PORT=24000 \
        docker compose -p "${compose_project}" -f "${compose_file}" ps -q app
    )" \
    "$(docker inspect --format '{{.Image}}' "${app_container}")" \
    "$(docker image inspect --format '{{.Id}}' "${image_tag}")"
)"
[[ "${state_after}" == "${state_before}" ]] \
  || die "Productionruntime wijzigde tijdens de read-only capture."

rm -f -- "${image_tar}"
trap - EXIT INT TERM HUP
echo "Draaiende legacy-productieimage is read-only en manifestgebonden vastgelegd."
