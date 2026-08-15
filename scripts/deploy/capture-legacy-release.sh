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
for command in docker flock gzip id node sha256sum stat tar; do
  command -v "${command}" >/dev/null 2>&1 \
    || die "Vereist commando ontbreekt: ${command}"
done
assert_runner_boundary production

[[ -f "${runtime_directory}/.deploy.lock"
  && ! -L "${runtime_directory}/.deploy.lock" ]] \
  || die "Production deploylock ontbreekt."
exec 9<>"${runtime_directory}/.deploy.lock"
flock -n 9 || die "Productiondeployment is actief."

[[ -f "${manifest_path}" && ! -L "${manifest_path}"
  && -f "${revision_path}" && ! -L "${revision_path}"
  && "$(stat -c '%u:%a' "${manifest_path}")" == "$(id -u):600"
  && "$(stat -c '%u:%a' "${revision_path}")" == "$(id -u):600"
  && "$(tr -d '\r\n' < "${revision_path}")" == "${legacy_sha}" ]] \
  || die "Productierevision of -manifest is niet exact de toegestane legacyrelease."
read -r image_digest config_digest artifact_digest < <(
  node scripts/deploy/release-manifest.mjs fields "${manifest_path}"
)
node scripts/deploy/release-manifest.mjs verify \
  "${manifest_path}" "${legacy_sha}" "${image_digest}" \
  "${config_digest}" "${artifact_digest}" >/dev/null

app_container_output="$(
  APP_IMAGE="${image_tag}" \
    RUNTIME_ENV_FILE="${runtime_directory}/.env.runtime" \
    APP_BIND_PORT=24000 \
    docker compose -p "${compose_project}" -f "${compose_file}" ps -q app
)" || die "Productionappcontainerinventaris kon niet worden gelezen."
app_containers=()
while IFS= read -r candidate_container; do
  [[ -z "${candidate_container}" ]] \
    || app_containers+=("${candidate_container}")
done <<< "${app_container_output}"
((${#app_containers[@]} <= 1)) \
  || die "Meer dan één productionappcontainer gevonden."
app_container="${app_containers[0]:-}"
docker image inspect "${image_tag}" >/dev/null 2>&1 \
  || die "Exacte legacy-imagetag ontbreekt lokaal; capture zonder rebuild is onmogelijk."
loaded_digest="$(docker image inspect --format '{{.Id}}' "${image_tag}")"
image_release_label="$(docker image inspect --format \
  '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' \
  "${image_tag}")"
[[ ("${loaded_digest}" == "${config_digest}"
    || "${loaded_digest}" == "${image_digest}")
  && "${image_release_label}" == "${legacy_sha}" ]] \
  || die "Lokale legacy-image wijkt af van het productionmanifest."
docker_context_identity="$(docker context show)" \
  || die "Dockercontext kon niet worden gelezen."
docker_daemon_details="$(
  docker info --format '{{.DockerRootDir}}|{{.Name}}|{{.ID}}'
)" || die "Dockerdaemonidentiteit kon niet worden gelezen."
docker_daemon_identity="$(
  printf '%s\n%s' "${docker_context_identity}" "${docker_daemon_details}" \
    | sha256sum | cut -d' ' -f1
)"

if [[ -n "${app_container}" ]]; then
  capture_source="running_container"
  [[ "$(docker inspect --format \
    '{{index .Config.Labels "com.docker.compose.project"}}' \
    "${app_container}")" == "${compose_project}" ]] \
    || die "Productionappcontainer hoort niet bij het productionproject."
  [[ "$(docker inspect --format \
    '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' \
    "${app_container}")" == "${legacy_sha}" ]] \
    || die "Productionappcontainer heeft een afwijkend releaselabel."
  container_image_id="$(
    docker inspect --format '{{.Image}}' "${app_container}"
  )"
  [[ "${container_image_id}" == "${loaded_digest}" ]] \
    || die "Draaiende legacy-image wijkt af van het productionmanifest."
else
  capture_source="local_manifest_image"
  container_image_id="none"
fi

state_before="$(
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$(tr -d '\r\n' < "${revision_path}")" \
    "$(sha256sum "${manifest_path}" | cut -d' ' -f1)" \
    "$(stat -c '%u:%g:%a:%s:%i:%Y' "${manifest_path}")" \
    "${docker_daemon_identity}" "${#app_containers[@]}" \
    "${capture_source}" "${app_container:-none}" \
    "${container_image_id}" "${loaded_digest}" \
    "${image_digest}:${config_digest}:${image_release_label}"
)"
state_before_sha256="sha256:$(printf '%s' "${state_before}" \
  | sha256sum | cut -d' ' -f1)"
node scripts/deploy/check-legacy-http.mjs \
  "${PRODUCTION_BASE_URL}" production "${legacy_sha}"
node scripts/deploy/check-legacy-http.mjs \
  "http://127.0.0.1:24000" production "${legacy_sha}"

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
archive_references_output="$(
  tar -xOf "${image_tar}" "blobs/sha256/${image_digest#sha256:}" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s);const d=[x.config?.digest,...(x.layers??[]).map(v=>v.digest)];if(d.length<2||d.some(v=>!/^sha256:[a-f0-9]{64}$/.test(v)))process.exit(1);process.stdout.write(d.join("\n"))})'
)" || die "Recovered OCI-manifestreferenties zijn ongeldig."
mapfile -t archive_references <<< "${archive_references_output}"
[[ "${archive_references[0]}" == "${config_digest}" ]] \
  || die "Recovered OCI-manifest verwijst naar een andere imageconfig."
for archive_reference in "${archive_references[@]}"; do
  [[ "sha256:$(tar -xOf "${image_tar}" \
    "blobs/sha256/${archive_reference#sha256:}" \
    | sha256sum | cut -d' ' -f1)" == "${archive_reference}" ]] \
    || die "Recovered OCI-reference ontbreekt of is gewijzigd."
done
[[ "sha256:$(tar -xOf "${image_tar}" "${archive_config_path}" \
  | sha256sum | cut -d' ' -f1)" == "${config_digest}" ]] \
  || die "Recovered imageconfigblob is gewijzigd."
[[ "$(tar -xOf "${image_tar}" "${archive_config_path}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).config?.Labels?.["nl.dgwebservices.duindorpteneu.sha"]??""))')" \
  == "${legacy_sha}" ]] \
  || die "Recovered imageconfig heeft een afwijkend releaselabel."
[[ "$(docker image inspect --format '{{.Id}}' "${image_tag}")" \
  == "${loaded_digest}"
  && "$(docker image inspect --format \
    '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' \
    "${image_tag}")" == "${image_release_label}" ]] \
  || die "Lokale legacy-image wijzigde tijdens de capture."
if [[ "${capture_source}" == "running_container" ]]; then
  [[ "$(docker inspect --format '{{.Image}}' "${app_container}")" \
    == "${container_image_id}" ]] \
    || die "Draaiende legacy-image wijzigde tijdens de capture."
fi

gzip -9n -c "${image_tar}" > "${archive_path}"
cp -- "${manifest_path}" "${captured_manifest}"
chmod 600 "${archive_path}" "${captured_manifest}"

node scripts/deploy/check-legacy-http.mjs \
  "${PRODUCTION_BASE_URL}" production "${legacy_sha}"
node scripts/deploy/check-legacy-http.mjs \
  "http://127.0.0.1:24000" production "${legacy_sha}"
state_after="$(
  current_app_container_output="$(
    APP_IMAGE="${image_tag}" \
      RUNTIME_ENV_FILE="${runtime_directory}/.env.runtime" \
      APP_BIND_PORT=24000 \
      docker compose -p "${compose_project}" -f "${compose_file}" ps -q app
  )" || exit 1
  current_app_containers=()
  while IFS= read -r candidate_container; do
    [[ -z "${candidate_container}" ]] \
      || current_app_containers+=("${candidate_container}")
  done <<< "${current_app_container_output}"
  ((${#current_app_containers[@]} <= 1)) || exit 1
  current_app_container="${current_app_containers[0]:-}"
  current_container_image_id="none"
  if [[ -n "${current_app_container}" ]]; then
    current_container_image_id="$(
      docker inspect --format '{{.Image}}' "${current_app_container}"
    )"
  fi
  current_docker_context_identity="$(docker context show)" || exit 1
  current_docker_daemon_details="$(
    docker info --format '{{.DockerRootDir}}|{{.Name}}|{{.ID}}'
  )" || exit 1
  current_docker_daemon_identity="$(
    printf '%s\n%s' "${current_docker_context_identity}" \
      "${current_docker_daemon_details}" \
      | sha256sum | cut -d' ' -f1
  )"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$(tr -d '\r\n' < "${revision_path}")" \
    "$(sha256sum "${manifest_path}" | cut -d' ' -f1)" \
    "$(stat -c '%u:%g:%a:%s:%i:%Y' "${manifest_path}")" \
    "${current_docker_daemon_identity}" \
    "${#current_app_containers[@]}" "${capture_source}" \
    "${current_app_container:-none}" \
    "${current_container_image_id}" \
    "$(docker image inspect --format '{{.Id}}' "${image_tag}")" \
    "${image_digest}:${config_digest}:$(docker image inspect --format \
      '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' \
      "${image_tag}")"
)"
[[ "${state_after}" == "${state_before}" ]] \
  || die "Productionruntime wijzigde tijdens de read-only capture."
state_after_sha256="sha256:$(printf '%s' "${state_after}" \
  | sha256sum | cut -d' ' -f1)"
LEGACY_CAPTURE_SOURCE="${capture_source}" \
LEGACY_CAPTURE_STATE_BEFORE_SHA256="${state_before_sha256}" \
LEGACY_CAPTURE_STATE_AFTER_SHA256="${state_after_sha256}" \
  node scripts/deploy/legacy-adoption-evidence.mjs create-capture \
  "${captured_manifest}" "${archive_path}" "${evidence_path}"
chmod 600 "${evidence_path}"

rm -f -- "${image_tar}"
trap - EXIT INT TERM HUP
echo "Legacy-productieimage is via ${capture_source} read-only en manifestgebonden vastgelegd."
