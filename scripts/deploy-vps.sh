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
  valid_sha "${RELEASE_SHA:-}" || die "RELEASE_SHA moet een volledige Git-SHA zijn."
  [[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] || die "Checkout en RELEASE_SHA verschillen."
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "Buildcheckout bevat tracked wijzigingen."
  local image_tag="${repository_image}:${RELEASE_SHA}"
  local output_dir="${RELEASE_OUTPUT_DIRECTORY:-.release}"
  mkdir -p "$output_dir"
  docker build --label "nl.dgwebservices.duindorpteneu.sha=${RELEASE_SHA}" --tag "$image_tag" .
  local digest
  digest="$(docker image inspect --format '{{.Id}}' "$image_tag")"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Docker gaf geen geldige image-digest."
  node scripts/deploy/release-manifest.mjs create "$output_dir/RELEASE_MANIFEST" build "$RELEASE_SHA" "$image_tag" "$digest"
  docker save "$image_tag" | gzip -9 > "$output_dir/duindorpteneu-app.tar.gz"
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

  for command in docker curl flock node pnpm gzip; do require_command "$command"; done
  docker compose version >/dev/null
  local security_options
  security_options="$(docker info --format '{{json .SecurityOptions}}')"
  [[ "$security_options" == *rootless* ]] || die "Docker daemon is niet Rootless."
  [[ "${DOCKER_HOST:-}" != "unix:///var/run/docker.sock" ]] || die "Rootful Docker-socket is niet toegestaan."

  node scripts/deploy/configure-runtime.mjs validate
  mkdir -p "$runtime_directory"
  chmod 700 "$runtime_directory"
  exec 9>"${runtime_directory}/.deploy.lock"
  flock -n 9 || die "Er draait al een deployment voor ${environment}."

  local image_tag="${repository_image}:${RELEASE_SHA}" expected_digest loaded_digest
  expected_digest="$(node -e 'const fs=require("fs");const x=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(x.imageDigest)' "$RELEASE_MANIFEST_SOURCE")"
  node scripts/deploy/release-manifest.mjs verify "$RELEASE_MANIFEST_SOURCE" "$RELEASE_SHA" "$expected_digest" >/dev/null
  gzip -dc "$RELEASE_ARTIFACT" | docker load >/dev/null
  loaded_digest="$(docker image inspect --format '{{.Id}}' "$image_tag")"
  [[ "$loaded_digest" == "$expected_digest" ]] || die "Geladen image-digest wijkt af van het buildmanifest."

  if [[ "$environment" == production ]]; then
    [[ -f "${STAGING_RELEASE_MANIFEST:-}" ]] || die "Staging release manifest ontbreekt."
    node scripts/deploy/release-manifest.mjs compare "$RELEASE_MANIFEST_SOURCE" "$STAGING_RELEASE_MANIFEST"
    git fetch origin main --no-tags
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

  local runtime_env_file="${runtime_directory}/.env.runtime"
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

  local previous_revision="" previous_image="" runtime_backup="${runtime_directory}/.env.runtime.previous"
  export RUNTIME_ENV_FILE="$runtime_env_file"
  [[ -f "${runtime_directory}/REVISION" ]] && previous_revision="$(tr -d '\r\n' < "${runtime_directory}/REVISION")"
  if valid_sha "$previous_revision"; then previous_image="${repository_image}:${previous_revision}"; fi
  if [[ -f "$RUNTIME_ENV_FILE" ]]; then cp -f -- "$RUNTIME_ENV_FILE" "$runtime_backup"; chmod 600 "$runtime_backup"; fi
  node scripts/deploy/configure-runtime.mjs write-runtime "$RUNTIME_ENV_FILE"

  local activated=false
  rollback() {
    local status="${1:-1}"
    if [[ "$activated" == true && -n "$previous_image" ]] && docker image inspect "$previous_image" >/dev/null 2>&1; then
      echo "Applicatiehealth faalde; vorige image wordt teruggezet. Databasemigraties worden niet teruggedraaid." >&2
      [[ -f "$runtime_backup" ]] && mv -f -- "$runtime_backup" "$RUNTIME_ENV_FILE"
      APP_IMAGE="$previous_image" docker compose -p "$compose_project" -f "$compose_file" up -d --no-build --remove-orphans || true
    fi
    docker compose -p "$compose_project" -f "$compose_file" logs --no-color --tail 80 app 2>&1 | node scripts/deploy/redact-logs.mjs || true
    exit "$status"
  }
  signal_abort() {
    echo "Deployment door een signaal afgebroken; veilige applicatieherstelactie wordt geprobeerd." >&2
    rollback 130
  }
  trap 'rollback $?' ERR
  trap signal_abort INT TERM HUP
  docker compose -p "$compose_project" -f "$compose_file" up -d --no-build --remove-orphans
  activated=true

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

  local temp_revision temp_previous temp_manifest
  temp_revision="$(mktemp "${runtime_directory}/REVISION.XXXXXX")"
  temp_previous="$(mktemp "${runtime_directory}/PREVIOUS_REVISION.XXXXXX")"
  temp_manifest="$(mktemp "${runtime_directory}/RELEASE_MANIFEST.XXXXXX")"
  printf '%s\n' "$RELEASE_SHA" > "$temp_revision"
  printf '%s\n' "$previous_revision" > "$temp_previous"
  node scripts/deploy/release-manifest.mjs create "$temp_manifest" "$environment" "$RELEASE_SHA" "$image_tag" "$loaded_digest"
  chmod 600 "$temp_revision" "$temp_previous" "$temp_manifest"
  mv -f -- "$temp_previous" "${runtime_directory}/PREVIOUS_REVISION"
  mv -f -- "$temp_revision" "${runtime_directory}/REVISION"
  mv -f -- "$temp_manifest" "${runtime_directory}/RELEASE_MANIFEST"
  rm -f -- "$runtime_backup" "$rendered_compose"
  activated=false
  trap - ERR EXIT INT TERM HUP

  mapfile -t old_images < <(docker image ls "$repository_image" --format '{{.Tag}} {{.CreatedAt}}' | sort -rk2,3 | awk 'NR>5 {print $1}')
  for tag in "${old_images[@]:-}"; do
    [[ -z "$tag" || "$tag" == "$RELEASE_SHA" || "$tag" == "$previous_revision" ]] && continue
    docker image rm "${repository_image}:${tag}" >/dev/null 2>&1 || true
  done
  echo "Deploy van ${RELEASE_SHA} naar ${environment} is volledig geverifieerd."
}

case "${1:-}" in
  build-release) build_release ;;
  staging|production) deploy_environment "$1" ;;
  *) die "Gebruik: scripts/deploy-vps.sh build-release|staging|production" ;;
esac
