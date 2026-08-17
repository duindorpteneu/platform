#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${RUNNER_TEMP:?RUNNER_TEMP ontbreekt}"
: "${GITHUB_PATH:?GITHUB_PATH ontbreekt}"

readonly version="2.97.0"
readonly archive_sha256="a2c9b8497e1f85b1ad0dfcb78b5a622e098801b8e461e459e88e1ee12f018112"
readonly archive_name="gh_${version}_linux_amd64.tar.gz"
readonly archive_url="https://github.com/cli/cli/releases/download/v${version}/${archive_name}"
readonly install_directory="${RUNNER_TEMP}/duindorp-github-cli-${version}"
readonly archive_path="${install_directory}/${archive_name}"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64) ;;
  *)
    echo "Alleen de gepinde Linux x64 GitHub CLI is toegestaan." >&2
    exit 1
    ;;
esac
for command in curl head sha256sum tar; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Vereist commando ontbreekt: ${command}" >&2
    exit 1
  }
done
[[ ! -e "${install_directory}" ]] || {
  echo "De tijdelijke GitHub CLI-map bestaat al." >&2
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
  --directory "${install_directory}" --strip-components=2 \
  "gh_${version}_linux_amd64/bin/gh"
rm -f -- "${archive_path}"
[[ -f "${install_directory}/gh" && ! -L "${install_directory}/gh" ]] || {
  echo "De verwachte GitHub CLI-binary ontbreekt." >&2
  exit 1
}
chmod 0755 "${install_directory}/gh"
[[ "$("${install_directory}/gh" --version | head -n 1)" == \
  "gh version ${version} "* ]] || {
  echo "De GitHub CLI-versie wijkt af." >&2
  exit 1
}
printf '%s\n' "${install_directory}" >> "${GITHUB_PATH}"
echo "Gepinde GitHub CLI ${version} is checksum-geverifieerd."
