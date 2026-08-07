#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${RUNNER_TEMP:?RUNNER_TEMP ontbreekt}"
: "${GITHUB_PATH:?GITHUB_PATH ontbreekt}"
: "${GITHUB_ENV:?GITHUB_ENV ontbreekt}"

readonly version="2.109.1"
readonly archive_sha256="36d87b7fe6b4bcfe89ac47a4354e526cff22480224de426d7b370f6934556976"
readonly archive_url="https://github.com/supabase/cli/releases/download/v${version}/supabase_${version}_linux_amd64.tar.gz"
readonly install_directory="${RUNNER_TEMP}/duindorp-supabase-cli-${version}"
readonly archive_path="${install_directory}/supabase.tar.gz"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64) ;;
  *)
    echo "Alleen de gepinde Linux x64 Supabase CLI is toegestaan." >&2
    exit 1
    ;;
esac
for command in curl sha256sum tar; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Vereist commando ontbreekt: ${command}" >&2
    exit 1
  }
done
[[ ! -e "${install_directory}" ]] || {
  echo "De tijdelijke Supabase CLI-map bestaat al." >&2
  exit 1
}
mkdir -m 0700 "${install_directory}"
trap 'rm -f -- "${archive_path}"' EXIT INT TERM HUP
curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 \
  --output "${archive_path}" "${archive_url}"
printf '%s  %s\n' "${archive_sha256}" "${archive_path}" \
  | sha256sum --check --status
tar --extract --gzip --file "${archive_path}" \
  --directory "${install_directory}" supabase
rm -f -- "${archive_path}"
chmod 0755 "${install_directory}/supabase"
[[ "$("${install_directory}/supabase" --version)" == "${version}" ]] || {
  echo "De Supabase CLI-versie wijkt af." >&2
  exit 1
}
printf '%s\n' "${install_directory}" >> "${GITHUB_PATH}"
printf 'SUPABASE_CLI_BINARY_OVERRIDE=%s\n' \
  "${install_directory}/supabase" >> "${GITHUB_ENV}"
echo "Gepinde Supabase CLI ${version} is checksum-geverifieerd."
