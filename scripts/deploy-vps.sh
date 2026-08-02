#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly repository_image="duindorpteneu-app"
readonly compose_file="deploy/compose.vps.yml"

die() { echo "$1" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Vereist commando ontbreekt: $1"; }
valid_sha() { [[ "${1:-}" =~ ^[a-f0-9]{40}$ ]]; }

build_release() {
  require_command docker
  require_command gzip
  require_command sha256sum
  require_command tar
  valid_sha "${RELEASE_SHA:-}" || die "RELEASE_SHA moet een volledige Git-SHA zijn."
  [[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] || die "Checkout en RELEASE_SHA verschillen."
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "Buildcheckout bevat tracked wijzigingen."
  local image_tag="${repository_image}:${RELEASE_SHA}"
  local output_dir="${RELEASE_OUTPUT_DIRECTORY:-.release}"
  mkdir -p "$output_dir"
  docker build --label "nl.dgwebservices.duindorpteneu.sha=${RELEASE_SHA}" --tag "$image_tag" .
  local image_tar manifest_digest config_path config_digest artifact_digest actual_digest
  image_tar="$(mktemp "${output_dir}/.image.XXXXXX.tar")"
  trap 'rm -f -- "${image_tar:-}"' EXIT INT TERM HUP
  docker save --output "$image_tar" "$image_tag"
  manifest_digest="$(tar -xOf "$image_tar" index.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s);if(x.manifests?.length!==1)process.exit(1);process.stdout.write(x.manifests[0].digest)})')"
  config_path="$(tar -xOf "$image_tar" manifest.json | IMAGE_TAG="$image_tag" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s).filter(v=>v.RepoTags?.includes(process.env.IMAGE_TAG));if(x.length!==1)process.exit(1);process.stdout.write(x[0].Config)})')"
  [[ "$manifest_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Docker-archief bevat geen geldige OCI-manifestdigest."
  [[ "$config_path" =~ ^blobs/sha256/[a-f0-9]{64}$ ]] || die "Docker-archief bevat geen geldige imageconfig."
  config_digest="sha256:${config_path##*/}"
  actual_digest="sha256:$(tar -xOf "$image_tar" "blobs/sha256/${manifest_digest#sha256:}" | sha256sum | cut -d' ' -f1)"
  [[ "$actual_digest" == "$manifest_digest" ]] || die "OCI-manifestdigest komt niet overeen met het archief."
  actual_digest="sha256:$(tar -xOf "$image_tar" "$config_path" | sha256sum | cut -d' ' -f1)"
  [[ "$actual_digest" == "$config_digest" ]] || die "Imageconfigdigest komt niet overeen met het archief."
  gzip -9n -c "$image_tar" > "$output_dir/duindorpteneu-app.tar.gz"
  artifact_digest="sha256:$(sha256sum "$output_dir/duindorpteneu-app.tar.gz" | cut -d' ' -f1)"
  node scripts/deploy/release-manifest.mjs create "$output_dir/RELEASE_MANIFEST" build "$RELEASE_SHA" "$image_tag" "$manifest_digest" "$config_digest" "$artifact_digest"
  rm -f -- "$image_tar"
  trap - EXIT INT TERM HUP
  chmod 600 "$output_dir/RELEASE_MANIFEST" "$output_dir/duindorpteneu-app.tar.gz"
  echo "Immutable image voor ${RELEASE_SHA} is gebouwd."
}

deploy_environment() {
  local environment="$1"
  local runtime_directory compose_project expected_port expected_host
  case "$environment" in
    staging)
      runtime_directory="/srv/apps/duindorpteneu/staging"
      compose_project="duindorpteneu-staging"
      expected_port="14000"
      expected_host="staging-duindorp.dgwebservices.nl"
      ;;
    production)
      runtime_directory="/srv/apps/duindorpteneu/production"
      compose_project="duindorpteneu-production"
      expected_port="24000"
      expected_host="duindorp.dgwebservices.nl"
      ;;
    *) die "Environment moet staging of production zijn." ;;
  esac
  export DEPLOY_ENVIRONMENT="$environment" RUNTIME_DIRECTORY="$runtime_directory" COMPOSE_PROJECT_NAME="$compose_project"
  [[ "${APP_BIND_PORT:-}" == "$expected_port" ]] || die "APP_BIND_PORT is onjuist."
  [[ "${APP_HOST:-}" == "$expected_host" ]] || die "APP_HOST is onjuist."
  valid_sha "${GITHUB_SHA:-${RELEASE_SHA:-}}" || die "GITHUB_SHA/RELEASE_SHA is ongeldig."
  valid_sha "${RELEASE_SHA:-}" || die "RELEASE_SHA is ongeldig."
  [[ -f "${RELEASE_ARTIFACT:-}" && -f "${RELEASE_MANIFEST_SOURCE:-}" ]] || die "Release-artefact of manifest ontbreekt."

  for command in base64 docker curl flock node pnpm gzip sha256sum stat tar; do require_command "$command"; done
  [[ "$EUID" -ne 0 ]] || die "Deployment als root is niet toegestaan."
  [[ "${USER:-}" == "deploy" && "${HOME:-}" == "/home/deploy" ]] || die "Deployment moet onder de geïsoleerde deploygebruiker draaien."
  [[ " $(id -nG) " != *" docker "* ]] || die "Lidmaatschap van de rootful dockergroep is niet toegestaan."
  local deploy_uid expected_runtime_dir expected_socket
  deploy_uid="$(id -u)"
  expected_runtime_dir="/run/user/${deploy_uid}"
  expected_socket="${expected_runtime_dir}/docker.sock"
  [[ "${XDG_RUNTIME_DIR:-}" == "$expected_runtime_dir" ]] || die "XDG_RUNTIME_DIR wijst niet naar de deploygebruiker."
  [[ "${DOCKER_HOST:-}" == "unix://${expected_socket}" ]] || die "DOCKER_HOST wijst niet naar de Rootless Docker-socket."
  [[ -S "$expected_socket" && "$(stat -c '%u' "$expected_socket")" == "$deploy_uid" ]] || die "Rootless Docker-socket of eigendom is ongeldig."
  docker compose version >/dev/null
  local security_options
  security_options="$(docker info --format '{{json .SecurityOptions}}')"
  [[ "$security_options" == *rootless* ]] || die "Docker daemon is niet Rootless."

  node scripts/deploy/configure-runtime.mjs validate
  [[ ! -L "$runtime_directory" ]] || die "Runtime directory mag geen symlink zijn."
  mkdir -p "$runtime_directory"
  [[ -d "$runtime_directory" && -O "$runtime_directory" ]] || die "Runtime directory heeft een onjuiste eigenaar."
  chmod 700 "$runtime_directory"
  [[ ! -L "${runtime_directory}/.deploy.lock" ]] || die "Deploylock mag geen symlink zijn."
  exec 9>"${runtime_directory}/.deploy.lock"
  chmod 600 "${runtime_directory}/.deploy.lock"
  flock -n 9 || die "Er draait al een deployment voor ${environment}."

  local image_tag="${repository_image}:${RELEASE_SHA}" expected_digest expected_config_digest expected_artifact_digest loaded_digest loaded_label archive_digest archive_manifest_digest archive_config_path archive_config_digest
  read -r expected_digest expected_config_digest expected_artifact_digest < <(node scripts/deploy/release-manifest.mjs fields "$RELEASE_MANIFEST_SOURCE")
  node scripts/deploy/release-manifest.mjs verify "$RELEASE_MANIFEST_SOURCE" "$RELEASE_SHA" "$expected_digest" "$expected_config_digest" "$expected_artifact_digest" >/dev/null
  archive_digest="sha256:$(sha256sum "$RELEASE_ARTIFACT" | cut -d' ' -f1)"
  [[ "$archive_digest" == "$expected_artifact_digest" ]] || die "Release-artefact wijkt af van het buildmanifest."
  archive_manifest_digest="$(tar -xOzf "$RELEASE_ARTIFACT" index.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s);if(x.manifests?.length!==1)process.exit(1);process.stdout.write(x.manifests[0].digest)})')"
  archive_config_path="$(tar -xOzf "$RELEASE_ARTIFACT" manifest.json | IMAGE_TAG="$image_tag" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s).filter(v=>v.RepoTags?.includes(process.env.IMAGE_TAG));if(x.length!==1)process.exit(1);process.stdout.write(x[0].Config)})')"
  [[ "$archive_manifest_digest" == "$expected_digest" ]] || die "OCI-manifestdigest wijkt af van het buildmanifest."
  [[ "$archive_config_path" =~ ^blobs/sha256/[a-f0-9]{64}$ ]] || die "Release-artefact bevat geen geldige imageconfig."
  archive_config_digest="sha256:${archive_config_path##*/}"
  [[ "$archive_config_digest" == "$expected_config_digest" ]] || die "Imageconfigdigest wijkt af van het buildmanifest."
  [[ "sha256:$(tar -xOzf "$RELEASE_ARTIFACT" "blobs/sha256/${expected_digest#sha256:}" | sha256sum | cut -d' ' -f1)" == "$expected_digest" ]] || die "OCI-manifestblob is gewijzigd."
  [[ "sha256:$(tar -xOzf "$RELEASE_ARTIFACT" "$archive_config_path" | sha256sum | cut -d' ' -f1)" == "$expected_config_digest" ]] || die "Imageconfigblob is gewijzigd."

  if [[ "$environment" == production ]]; then
    [[ -f "${STAGING_RELEASE_MANIFEST:-}" ]] || die "Staging release manifest ontbreekt."
    node scripts/deploy/release-manifest.mjs compare "$RELEASE_MANIFEST_SOURCE" "$STAGING_RELEASE_MANIFEST"
    [[ -n "${GITHUB_TOKEN:-}" ]] || die "Job-scoped GitHub-token ontbreekt."
    local git_auth_header
    git_auth_header="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\r\n')"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${git_auth_header}" git fetch origin main --no-tags
    unset git_auth_header
    local current_main
    current_main="$(git rev-parse origin/main)"
    if [[ "${DEPLOYMENT_MODE:-current}" == current ]]; then
      [[ "$current_main" == "$RELEASE_SHA" && "${GITHUB_SHA:-}" == "$RELEASE_SHA" ]] || die "Release is verouderd ten opzichte van main."
    elif [[ "${DEPLOYMENT_MODE:-}" == redeploy ]]; then
      git merge-base --is-ancestor "$RELEASE_SHA" origin/main || die "Redeploy-SHA hoort niet bij main."
    else
      die "Ongeldige deploymentmodus."
    fi
  fi

  gzip -dc "$RELEASE_ARTIFACT" | docker load >/dev/null
  loaded_digest="$(docker image inspect --format '{{.Id}}' "$image_tag")"
  loaded_label="$(docker image inspect --format '{{index .Config.Labels "nl.dgwebservices.duindorpteneu.sha"}}' "$image_tag")"
  [[ "$loaded_digest" == "$expected_digest" || "$loaded_digest" == "$expected_config_digest" ]] || die "Geladen image-identiteit wijkt af van zowel OCI-manifest als imageconfig."
  [[ "$loaded_label" == "$RELEASE_SHA" ]] || die "Geladen image heeft niet het verwachte releaselabel."

  local runtime_env_file="${runtime_directory}/.env.runtime"
  [[ ! -L "$runtime_env_file" ]] || die "Runtimebestand mag geen symlink zijn."
  export APP_IMAGE="$image_tag" RUNTIME_ENV_FILE=/dev/null
  local rendered_compose
  rendered_compose="$(mktemp "${runtime_directory}/compose.XXXXXX")"
  trap 'rm -f -- "${rendered_compose:-}"' EXIT INT TERM HUP
  docker compose -p "$compose_project" -f "$compose_file" config > "$rendered_compose"
  ! grep -F 'host_ip: 0.0.0.0' "$rendered_compose" >/dev/null || die "Compose publiceert op 0.0.0.0."
  grep -F 'host_ip: 127.0.0.1' "$rendered_compose" >/dev/null || die "Compose-loopbackbinding ontbreekt."
  grep -F "published: \"${expected_port}\"" "$rendered_compose" >/dev/null || die "Compose publiceert de verkeerde hostpoort."
  grep -F 'target: 3000' "$rendered_compose" >/dev/null || die "Compose publiceert de verkeerde containerpoort."

  pnpm security:migrations
  echo "Controleer remote migratievolgorde en drift."
  pnpm exec supabase db push --db-url "$SUPABASE_DB_URL" --dry-run
  pnpm exec supabase db push --db-url "$SUPABASE_DB_URL" --yes
  node scripts/deploy/check-postgrest-rpcs.mjs

  local previous_revision="" previous_image="" runtime_backup="${runtime_directory}/.env.runtime.previous" runtime_existed=false
  export RUNTIME_ENV_FILE="$runtime_env_file"
  [[ -f "${runtime_directory}/REVISION" ]] && previous_revision="$(tr -d '\r\n' < "${runtime_directory}/REVISION")"
  if valid_sha "$previous_revision"; then previous_image="${repository_image}:${previous_revision}"; fi
  if [[ -f "$RUNTIME_ENV_FILE" ]]; then
    runtime_existed=true
    cp -f -- "$RUNTIME_ENV_FILE" "$runtime_backup"
    chmod 600 "$runtime_backup"
  fi
  node scripts/deploy/configure-runtime.mjs write-runtime "$RUNTIME_ENV_FILE"

  local activated=false
  rollback() {
    local status="${1:-1}"
    if [[ -f "$runtime_backup" ]]; then
      mv -f -- "$runtime_backup" "$RUNTIME_ENV_FILE"
    elif [[ "$runtime_existed" == false ]]; then
      rm -f -- "$RUNTIME_ENV_FILE"
    fi
    if [[ "$activated" == true && -n "$previous_image" ]] && docker image inspect "$previous_image" >/dev/null 2>&1; then
      echo "Applicatiehealth faalde; vorige image wordt teruggezet. Databasemigraties worden niet teruggedraaid." >&2
      APP_IMAGE="$previous_image" docker compose -p "$compose_project" -f "$compose_file" up -d --no-build --remove-orphans || true
    fi
    docker compose -p "$compose_project" -f "$compose_file" logs --no-color --tail 80 app scheduler 2>&1 | node scripts/deploy/redact-logs.mjs || true
    exit "$status"
  }
  signal_abort() {
    echo "Deployment door een signaal afgebroken; veilige applicatieherstelactie wordt geprobeerd." >&2
    rollback 130
  }
  trap 'rollback $?' ERR
  trap signal_abort INT TERM HUP
  activated=true
  docker compose -p "$compose_project" -f "$compose_file" up -d --no-build --remove-orphans

  local app_container runtime_probe_nonce expected_runtime_probe actual_runtime_probe
  app_container="$(docker compose -p "$compose_project" -f "$compose_file" ps -q app)"
  [[ -n "$app_container" ]] || die "Applicatiecontainer ontbreekt voor runtime-secretcontrole."
  runtime_probe_nonce="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))')"
  expected_runtime_probe="$(DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.PARENT_TOKEN_PEPPER).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
  actual_runtime_probe="$(docker exec -e DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" "$app_container" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.PARENT_TOKEN_PEPPER).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
  [[ "$expected_runtime_probe" == "$actual_runtime_probe" ]] || die "Actieve runtime bevat niet de verwachte PARENT_TOKEN_PEPPER."

  check_with_retries() {
    local url="$1"
    for attempt in $(seq 1 20); do
      if node scripts/deploy/check-http.mjs "$url" "$environment" "$RELEASE_SHA"; then return 0; fi
      [[ "$attempt" == 20 ]] && return 1
      sleep 3
    done
  }
  check_with_retries "http://127.0.0.1:${expected_port}"
  check_with_retries "https://${expected_host}"
  node scripts/deploy/check-edge-body-limits.mjs "$environment"
  local scheduler_container scheduler_health
  scheduler_container="$(docker compose -p "$compose_project" -f "$compose_file" ps -q scheduler)"
  [[ -n "$scheduler_container" ]] || die "Schedulercontainer ontbreekt."
  for attempt in $(seq 1 20); do
    scheduler_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$scheduler_container")"
    [[ "$scheduler_health" == healthy ]] && break
    [[ "$attempt" == 20 ]] && die "Scheduler werd niet gezond."
    sleep 3
  done

  local temp_revision temp_previous temp_manifest
  temp_revision="$(mktemp "${runtime_directory}/REVISION.XXXXXX")"
  temp_previous="$(mktemp "${runtime_directory}/PREVIOUS_REVISION.XXXXXX")"
  temp_manifest="$(mktemp "${runtime_directory}/RELEASE_MANIFEST.XXXXXX")"
  printf '%s\n' "$RELEASE_SHA" > "$temp_revision"
  printf '%s\n' "$previous_revision" > "$temp_previous"
  node scripts/deploy/release-manifest.mjs create "$temp_manifest" "$environment" "$RELEASE_SHA" "$image_tag" "$expected_digest" "$expected_config_digest" "$expected_artifact_digest"
  chmod 600 "$temp_revision" "$temp_previous" "$temp_manifest"
  mv -f -- "$temp_previous" "${runtime_directory}/PREVIOUS_REVISION"
  mv -f -- "$temp_revision" "${runtime_directory}/REVISION"
  mv -f -- "$temp_manifest" "${runtime_directory}/RELEASE_MANIFEST"
  rm -f -- "$runtime_backup" "$rendered_compose"
  activated=false
  trap - ERR EXIT INT TERM HUP

  echo "Deploy van ${RELEASE_SHA} naar ${environment} is volledig geverifieerd."
}

case "${1:-}" in
  build-release) build_release ;;
  staging|production) deploy_environment "$1" ;;
  *) die "Gebruik: scripts/deploy-vps.sh build-release|staging|production" ;;
esac
