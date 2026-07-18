#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

case "${DEPLOY_ENVIRONMENT:-}" in
  staging)
    DEPLOY_ROOT="/srv/duindorp-tenueportaal/staging"
    SYSTEMD_SERVICE="duindorp-tenueportaal-staging.service"
    ;;
  production)
    DEPLOY_ROOT="/srv/duindorp-tenueportaal/production"
    SYSTEMD_SERVICE="duindorp-tenueportaal-production.service"
    ;;
  *)
    echo "DEPLOY_ENVIRONMENT moet staging of production zijn." >&2
    exit 1
    ;;
esac

export DEPLOY_ROOT SYSTEMD_SERVICE
node scripts/deploy/configure-runtime.mjs validate

run_id="${GITHUB_RUN_ID:-0}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
if [[ ! "$run_id" =~ ^[0-9]+$ || ! "$run_attempt" =~ ^[0-9]+$ ]]; then
  echo "Ongeldige GitHub-runidentiteit." >&2
  exit 1
fi

release_id="${DEPLOY_SHA}-${run_id}-${run_attempt}"
release_dir="${DEPLOY_ROOT}/releases/${release_id}"
temporary_release="${release_dir}.tmp"
current_link="${DEPLOY_ROOT}/current"
previous_target=""
activated="false"

cleanup() {
  rm -rf -- "$temporary_release"
}

rollback() {
  local exit_code=$?
  cleanup
  if [[ "$activated" == "true" && -n "$previous_target" && -d "$previous_target" ]]; then
    echo "Healthcheck mislukt; vorige applicatierelease wordt teruggezet." >&2
    ln -s "$previous_target" "${current_link}.rollback"
    mv -Tf "${current_link}.rollback" "$current_link"
    sudo -n systemctl restart "$SYSTEMD_SERVICE" || true
  fi
  exit "$exit_code"
}
trap rollback ERR
trap cleanup EXIT

echo "Bouw standalone Next.js-release voor ${DEPLOY_ENVIRONMENT}."
pnpm build
test -f .next/standalone/server.js

rm -rf -- "$temporary_release"
mkdir -p "$temporary_release/.next"
cp -a .next/standalone/. "$temporary_release/"
cp -a .next/static "$temporary_release/.next/static"
cp -a public "$temporary_release/public"
printf '%s\n' "$DEPLOY_SHA" > "$temporary_release/RELEASE_SHA"

echo "Controleer en pas forward-only Supabase-migraties toe."
pnpm exec supabase link --project-ref "$SUPABASE_PROJECT_ID"
pnpm exec supabase db push --linked --include-all --dry-run
pnpm exec supabase db push --linked --include-all --yes

mkdir -p "${DEPLOY_ROOT}/releases" "${DEPLOY_ROOT}/shared"
node scripts/deploy/configure-runtime.mjs write-runtime "${DEPLOY_ROOT}/shared/app.env"
mv "$temporary_release" "$release_dir"

if [[ -L "$current_link" ]]; then
  previous_target="$(readlink -f "$current_link")"
fi
ln -s "$release_dir" "${current_link}.next"
mv -Tf "${current_link}.next" "$current_link"
activated="true"

sudo -n systemctl restart "$SYSTEMD_SERVICE"

echo "Controleer lokale app en publieke Caddy-route."
for attempt in {1..30}; do
  if curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null; then
    break
  fi
  if [[ "$attempt" == "30" ]]; then
    echo "Lokale healthcheck bleef rood." >&2
    false
  fi
  sleep 2
done
curl --fail --silent --show-error --max-time 10 "${APP_BASE_URL}/api/health" >/dev/null

activated="false"
trap - ERR

mapfile -t old_releases < <(find "${DEPLOY_ROOT}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | tail -n +6 | cut -d' ' -f2-)
for old_release in "${old_releases[@]}"; do
  if [[ "$old_release" != "$(readlink -f "$current_link")" ]]; then
    rm -rf -- "$old_release"
  fi
done

echo "Deploy ${DEPLOY_SHA} naar ${DEPLOY_ENVIRONMENT} is geslaagd."
