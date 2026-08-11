#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly repository_image="duindorpteneu-app"
readonly compose_file="deploy/compose.vps.yml"
readonly incompatible_staging_rollback_revision="a846c059bce3d7e794504acca57a4771dfdb536d"

source scripts/deploy/failure-guard.sh
source scripts/deploy/assert-runner-boundary.sh
die() { deployment_die "$1"; }
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

  local supabase_cli="${SUPABASE_CLI_BINARY_OVERRIDE:-supabase}"
  for command in base64 docker curl flock node pnpm gzip sha256sum stat tar; do require_command "$command"; done
  require_command "$supabase_cli"
  [[ "$("$supabase_cli" --version)" == "2.109.1" ]] \
    || die "Supabase CLI moet exact versie 2.109.1 zijn."
  [[ "$EUID" -ne 0 ]] || die "Deployment als root is niet toegestaan."
  [[ " $(id -nG) " != *" docker "* ]] || die "Lidmaatschap van de rootful dockergroep is niet toegestaan."
  assert_runner_boundary "$environment"
  docker compose version >/dev/null

  local image_tag="${repository_image}:${RELEASE_SHA}" expected_digest expected_config_digest expected_artifact_digest loaded_digest loaded_label archive_digest archive_manifest_digest archive_config_path archive_config_digest
  read -r expected_digest expected_config_digest expected_artifact_digest < <(
    node scripts/deploy/release-manifest.mjs fields "$RELEASE_MANIFEST_SOURCE"
  )
  node scripts/deploy/release-manifest.mjs verify \
    "$RELEASE_MANIFEST_SOURCE" "$RELEASE_SHA" "$expected_digest" \
    "$expected_config_digest" "$expected_artifact_digest" >/dev/null
  export RELEASE_ARTIFACT_DIGEST="$expected_artifact_digest"
  node scripts/deploy/configure-runtime.mjs validate
  [[ -d "$runtime_directory" && -O "$runtime_directory" ]] || die "Runtime directory heeft een onjuiste eigenaar."
  chmod 700 "$runtime_directory"
  [[ ! -L "${runtime_directory}/.deploy.lock" ]] || die "Deploylock mag geen symlink zijn."
  exec 9>"${runtime_directory}/.deploy.lock"
  chmod 600 "${runtime_directory}/.deploy.lock"
  flock -n 9 || die "Er draait al een deployment voor ${environment}."

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
  fi
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "Job-scoped GitHub-token ontbreekt."
  local git_auth_header
  git_auth_header="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\r\n')"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${git_auth_header}" git fetch origin main --no-tags
  unset git_auth_header
  local current_main
  current_main="$(git rev-parse origin/main)"
  [[ "${DEPLOYMENT_MODE:-current}" == current ]] || die "Alleen de actuele main-release mag worden gedeployed."
  [[ "$current_main" == "$RELEASE_SHA" && "${GITHUB_SHA:-}" == "$RELEASE_SHA" ]] \
    || die "Release is verouderd ten opzichte van main."

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

  local previous_revision="" previous_image="" previous_digest="" previous_config_digest="" previous_artifact_digest="" previous_health_contract="artifact-v2" previous_app_compatible=true runtime_backup="${runtime_directory}/.env.runtime.previous" legacy_runtime_backup="" runtime_existed=false
  export RUNTIME_ENV_FILE="$runtime_env_file"
  [[ -f "${runtime_directory}/REVISION" ]] && previous_revision="$(tr -d '\r\n' < "${runtime_directory}/REVISION")"
  if valid_sha "$previous_revision"; then
    previous_image="${repository_image}:${previous_revision}"
    [[ -f "$RUNTIME_ENV_FILE" ]] \
      || die "Vorige release heeft geen herstelbaar runtimebestand."
    [[ -f "${runtime_directory}/RELEASE_MANIFEST" ]] \
      || die "Vorige release heeft geen herstelmanifest."
    read -r previous_digest previous_config_digest previous_artifact_digest < <(
      node scripts/deploy/release-manifest.mjs fields \
        "${runtime_directory}/RELEASE_MANIFEST"
    )
    node scripts/deploy/release-manifest.mjs verify \
      "${runtime_directory}/RELEASE_MANIFEST" "$previous_revision" \
      "$previous_digest" "$previous_config_digest" \
      "$previous_artifact_digest" >/dev/null
    docker image inspect "$previous_image" >/dev/null 2>&1 \
      || die "Vorige release-image ontbreekt; activatie en migratie zijn geblokkeerd."
    local previous_loaded_digest
    previous_loaded_digest="$(
      docker image inspect --format '{{.Id}}' "$previous_image"
    )"
    [[ "$previous_loaded_digest" == "$previous_digest" || "$previous_loaded_digest" == "$previous_config_digest" ]] \
      || die "Vorige release-image wijkt af van het herstelmanifest."
    if [[ "$environment" == staging \
      && "$previous_revision" == "$incompatible_staging_rollback_revision" ]]
    then
      previous_app_compatible=false
      [[ -z "$(
        APP_IMAGE="$previous_image" docker compose -p "$compose_project" \
          -f "$compose_file" ps --status running -q app scheduler
      )" ]] || die "De schema-incompatibele oude stagingapp draait nog; migratie en activatie zijn geblokkeerd."
    fi
    if [[ "$previous_revision" == \
      "a79c8d843d75e90810ccceb228538c6368d2198b" ]]
    then
      local legacy_capture_path legacy_result_path legacy_run_id
      legacy_capture_path="${LEGACY_CAPTURE_EVIDENCE_PATH:-${runtime_directory}/LEGACY_ADOPTION_EVIDENCE}"
      legacy_result_path="${LEGACY_ADOPTION_RESULT_PATH:-${runtime_directory}/LEGACY_ADOPTION_RESULT}"
      legacy_run_id="${LEGACY_ADOPTION_RUN_ID:-}"
      [[ -f "$legacy_capture_path" && ! -L "$legacy_capture_path"
        && -f "$legacy_result_path" && ! -L "$legacy_result_path"
        && "$legacy_run_id" =~ ^[1-9][0-9]*$ ]] \
        || die "Legacy rollbacktarget mist geverifieerd adoptiebewijs."
      node scripts/deploy/legacy-adoption-evidence.mjs verify-result \
        "$legacy_result_path" "$legacy_capture_path" \
        "$RELEASE_MANIFEST_SOURCE" "$legacy_run_id" >/dev/null
      previous_health_contract="legacy-v1-exact-four-fields"
    fi
  else
    [[ "${ALLOW_FIRST_DEPLOY:-false}" == true ]] \
      || die "Geen verifieerbare vorige release; expliciete ALLOW_FIRST_DEPLOY=true is vereist."
    [[ -z "$(docker compose -p "$compose_project" -f "$compose_file" ps -q app)" ]] \
      || die "First-deploymodus is niet toegestaan terwijl een applicatiecontainer bestaat."
  fi
  if [[ -f "$RUNTIME_ENV_FILE" ]]; then
    runtime_existed=true
    cp -f -- "$RUNTIME_ENV_FILE" "$runtime_backup"
    chmod 600 "$runtime_backup"
    if [[ "$previous_health_contract" == \
      "legacy-v1-exact-four-fields" ]]
    then
      legacy_runtime_backup="$(
        mktemp "${runtime_directory}/.env.runtime.previous-legacy.XXXXXX"
      )"
      node scripts/deploy/normalize-legacy-runtime.mjs \
        "$runtime_backup" "$legacy_runtime_backup" "$environment" \
        "$previous_revision" "$previous_artifact_digest"
    fi
  fi

  pnpm security:migrations
  echo "Controleer remote migratievolgorde en drift."
  "$supabase_cli" db push --db-url "$SUPABASE_DB_URL" --dry-run
  "$supabase_cli" db push --db-url "$SUPABASE_DB_URL" --yes
  node scripts/deploy/check-postgrest-rpcs.mjs
  node scripts/deploy/check-import-staging-key.mjs

  node scripts/deploy/configure-runtime.mjs write-runtime "$RUNTIME_ENV_FILE"

  local activated=false
  check_with_retries() {
    local url="$1"
    local expected_revision="${2:-$RELEASE_SHA}"
    local expected_artifact="${3:-$expected_artifact_digest}"
    for attempt in $(seq 1 20); do
      if node scripts/deploy/check-http.mjs \
        "$url" "$environment" "$expected_revision" "$expected_artifact"; then
        return 0
      fi
      [[ "$attempt" == 20 ]] && return 1
      sleep 3
    done
  }
  check_scheduler_with_retries() {
    local image="$1"
    local scheduler_container scheduler_health
    scheduler_container="$(
      APP_IMAGE="$image" docker compose -p "$compose_project" \
        -f "$compose_file" ps -q scheduler
    )" || return 1
    [[ -n "$scheduler_container" ]] || return 1
    for attempt in $(seq 1 20); do
      scheduler_health="$(
        docker inspect \
          --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
          "$scheduler_container"
      )" || return 1
      [[ "$scheduler_health" == healthy ]] && return 0
      [[ "$attempt" == 20 ]] && return 1
      sleep 3
    done
  }
  stop_scheduler_for_legacy() {
    local image="$1"
    if ! APP_IMAGE="$image" docker compose -p "$compose_project" \
      -f "$compose_file" stop scheduler
    then
      [[ -z "$(
        APP_IMAGE="$image" docker compose -p "$compose_project" \
          -f "$compose_file" ps -aq scheduler
      )" ]] || return 1
    fi
    [[ -z "$(
      APP_IMAGE="$image" docker compose -p "$compose_project" \
        -f "$compose_file" ps --status running -q scheduler
    )" ]]
  }
  check_previous_with_retries() {
    local url="$1"
    if [[ "$previous_health_contract" == \
      "legacy-v1-exact-four-fields" ]]
    then
      for attempt in $(seq 1 20); do
        if node scripts/deploy/check-legacy-http.mjs \
          "$url" "$environment" "$previous_revision"
        then
          return 0
        fi
        [[ "$attempt" == 20 ]] && return 1
        sleep 3
      done
    else
      check_with_retries "$url" "$previous_revision" \
        "$previous_artifact_digest"
    fi
  }
  rollback() {
    local status="${1:-1}"
    trap - ERR INT TERM HUP
    local rollback_failed=false
    local rollback_runtime="$runtime_backup"
    if [[ "$previous_health_contract" == \
      "legacy-v1-exact-four-fields" ]]
    then
      rollback_runtime="$legacy_runtime_backup"
    fi
    if [[ -f "$rollback_runtime" ]]; then
      cp -f -- "$rollback_runtime" "$RUNTIME_ENV_FILE" \
        || rollback_failed=true
    elif [[ "$runtime_existed" == false ]]; then
      rm -f -- "$RUNTIME_ENV_FILE" || rollback_failed=true
    fi
    if [[ "$activated" == true ]]; then
      if [[ "$previous_app_compatible" == false ]]; then
        echo "Applicatiehealth faalde; de schema-incompatibele oude stagingapp wordt niet gestart. De kandidaat wordt fail-closed gestopt en databasemigraties worden niet teruggedraaid." >&2
        APP_IMAGE="$image_tag" docker compose -p "$compose_project" \
          -f "$compose_file" stop app scheduler \
          || rollback_failed=true
        [[ -z "$(
          APP_IMAGE="$image_tag" docker compose -p "$compose_project" \
            -f "$compose_file" ps --status running -q app scheduler
        )" ]] || rollback_failed=true
      else
        [[ -n "$previous_image" ]] || rollback_failed=true
        echo "Applicatiehealth faalde; vorige image wordt teruggezet. Databasemigraties worden niet teruggedraaid." >&2
      fi
      if [[ "$rollback_failed" == false \
        && "$previous_app_compatible" == true ]]
      then
        if [[ "$previous_health_contract" == \
          "legacy-v1-exact-four-fields" ]]
        then
          stop_scheduler_for_legacy "$previous_image" \
            || rollback_failed=true
          if [[ "$rollback_failed" == false ]]; then
            APP_IMAGE="$previous_image" docker compose -p "$compose_project" \
              -f "$compose_file" up -d --no-build app \
              || rollback_failed=true
          fi
        else
          APP_IMAGE="$previous_image" docker compose -p "$compose_project" \
            -f "$compose_file" up -d --no-build --remove-orphans \
            || rollback_failed=true
        fi
      fi
      if [[ "$rollback_failed" == false \
        && "$previous_app_compatible" == true ]]
      then
        check_previous_with_retries \
          "http://127.0.0.1:${expected_port}" \
          || rollback_failed=true
        check_previous_with_retries "https://${expected_host}" \
          || rollback_failed=true
        if [[ "$previous_health_contract" == \
          "legacy-v1-exact-four-fields" ]]
        then
          stop_scheduler_for_legacy "$previous_image" \
            || rollback_failed=true
        else
          check_scheduler_with_retries "$previous_image" \
            || rollback_failed=true
        fi
      fi
    fi
    docker compose -p "$compose_project" -f "$compose_file" logs --no-color --tail 80 app scheduler 2>&1 | node scripts/deploy/redact-logs.mjs || true
    if [[ "$rollback_failed" == true ]]; then
      echo "KRITIEK: automatische applicatierollback kon niet worden bewezen." >&2
      rm -f -- "$runtime_backup" "$rendered_compose"
      [[ -z "$legacy_runtime_backup" ]] \
        || rm -f -- "$legacy_runtime_backup"
      exit 70
    fi
    rm -f -- "$runtime_backup" "$rendered_compose"
    [[ -z "$legacy_runtime_backup" ]] \
      || rm -f -- "$legacy_runtime_backup"
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
  expected_runtime_probe="$(DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.QR_TOKEN_PEPPER).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
  actual_runtime_probe="$(docker exec -e DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" "$app_container" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.QR_TOKEN_PEPPER).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
  [[ "$expected_runtime_probe" == "$actual_runtime_probe" ]] || die "Actieve runtime bevat niet de verwachte QR_TOKEN_PEPPER."
  docker exec "$app_container" node -e \
    'process.exit(process.env.QR_TOKEN_PEPPER_VERSION === process.argv[1] ? 0 : 1)' \
    "$QR_TOKEN_PEPPER_VERSION" \
    || die "Actieve runtime bevat niet de verwachte QR_TOKEN_PEPPER_VERSION."
  if [[ -n "${QR_TOKEN_PREVIOUS_PEPPER:-}" ]]; then
    expected_runtime_probe="$(DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.QR_TOKEN_PREVIOUS_PEPPER).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
    actual_runtime_probe="$(docker exec -e DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" "$app_container" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.QR_TOKEN_PREVIOUS_PEPPER).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
    [[ "$expected_runtime_probe" == "$actual_runtime_probe" ]] || die "Actieve runtime bevat niet de verwachte QR_TOKEN_PREVIOUS_PEPPER."
    docker exec "$app_container" node -e \
      'process.exit(process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION === process.argv[1] ? 0 : 1)' \
      "$QR_TOKEN_PREVIOUS_PEPPER_VERSION" \
      || die "Actieve runtime bevat niet de verwachte QR_TOKEN_PREVIOUS_PEPPER_VERSION."
  else
    docker exec "$app_container" node -e \
      'process.exit(!process.env.QR_TOKEN_PREVIOUS_PEPPER && !process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION ? 0 : 1)' \
      || die "Actieve runtime bevat onverwacht een vorige QR-sleutel."
  fi
  if [[ "${DYNAMIC_IMPORT_ENABLED}" == true ]]; then
    expected_runtime_probe="$(DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.IMPORT_STAGING_ENCRYPTION_KEY).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
    actual_runtime_probe="$(docker exec -e DUINDORP_RUNTIME_PROBE_NONCE="$runtime_probe_nonce" "$app_container" node -e 'const {createHmac}=require("node:crypto");process.stdout.write(createHmac("sha256",process.env.IMPORT_STAGING_ENCRYPTION_KEY).update(process.env.DUINDORP_RUNTIME_PROBE_NONCE).digest("hex"))')"
    [[ "$expected_runtime_probe" == "$actual_runtime_probe" ]] || die "Actieve runtime bevat niet de verwachte importstaging-sleutel."
  fi

  check_with_retries "http://127.0.0.1:${expected_port}"
  check_with_retries "https://${expected_host}"
  node scripts/deploy/check-edge-body-limits.mjs "$environment"
  check_scheduler_with_retries "$image_tag" \
    || die "Scheduler werd niet gezond."

  local temp_revision temp_previous temp_manifest temp_previous_manifest temp_previous_runtime
  temp_revision="$(mktemp "${runtime_directory}/REVISION.XXXXXX")"
  temp_previous="$(mktemp "${runtime_directory}/PREVIOUS_REVISION.XXXXXX")"
  temp_manifest="$(mktemp "${runtime_directory}/RELEASE_MANIFEST.XXXXXX")"
  temp_previous_manifest="$(mktemp "${runtime_directory}/PREVIOUS_RELEASE_MANIFEST.XXXXXX")"
  temp_previous_runtime="$(mktemp "${runtime_directory}/.env.runtime.previous-release.XXXXXX")"
  printf '%s\n' "$RELEASE_SHA" > "$temp_revision"
  printf '%s\n' "$previous_revision" > "$temp_previous"
  node scripts/deploy/release-manifest.mjs create "$temp_manifest" "$environment" "$RELEASE_SHA" "$image_tag" "$expected_digest" "$expected_config_digest" "$expected_artifact_digest"
  if valid_sha "$previous_revision"; then
    cp -f -- "${runtime_directory}/RELEASE_MANIFEST" \
      "$temp_previous_manifest"
    if [[ "$previous_health_contract" == \
      "legacy-v1-exact-four-fields" ]]
    then
      cp -f -- "$legacy_runtime_backup" "$temp_previous_runtime"
    else
      cp -f -- "$runtime_backup" "$temp_previous_runtime"
    fi
  else
    : > "$temp_previous_manifest"
    : > "$temp_previous_runtime"
  fi
  chmod 600 "$temp_revision" "$temp_previous" "$temp_manifest" \
    "$temp_previous_manifest" "$temp_previous_runtime"
  mv -f -- "$temp_previous_manifest" \
    "${runtime_directory}/PREVIOUS_RELEASE_MANIFEST"
  mv -f -- "$temp_previous_runtime" \
    "${runtime_directory}/.env.runtime.previous-release"
  mv -f -- "$temp_previous" "${runtime_directory}/PREVIOUS_REVISION"
  mv -f -- "$temp_revision" "${runtime_directory}/REVISION"
  mv -f -- "$temp_manifest" "${runtime_directory}/RELEASE_MANIFEST"
  rm -f -- "$runtime_backup" "$rendered_compose"
  [[ -z "$legacy_runtime_backup" ]] \
    || rm -f -- "$legacy_runtime_backup"
  activated=false
  trap - ERR EXIT INT TERM HUP

  echo "Deploy van ${RELEASE_SHA} naar ${environment} is volledig geverifieerd."
}

case "${1:-}" in
  build-release) build_release ;;
  staging|production) deploy_environment "$1" ;;
  *) die "Gebruik: scripts/deploy-vps.sh build-release|staging|production" ;;
esac
