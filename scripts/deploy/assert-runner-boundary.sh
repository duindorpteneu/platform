#!/usr/bin/env bash

assert_runner_boundary() {
  local environment="${1:-}"
  local expected_runner expected_user expected_home expected_runtime
  local peer_user peer_home peer_runtime peer_project
  case "${environment}" in
    staging)
      expected_runner="duindorp-staging-01"
      expected_user="duindorp-staging"
      expected_home="/home/duindorp-staging"
      expected_runtime="/srv/apps/duindorpteneu/staging"
      peer_user="duindorp-production"
      peer_home="/home/duindorp-production"
      peer_runtime="/srv/apps/duindorpteneu/production"
      peer_project="duindorpteneu-production"
      ;;
    production)
      expected_runner="duindorp-production-01"
      expected_user="duindorp-production"
      expected_home="/home/duindorp-production"
      expected_runtime="/srv/apps/duindorpteneu/production"
      peer_user="duindorp-staging"
      peer_home="/home/duindorp-staging"
      peer_runtime="/srv/apps/duindorpteneu/staging"
      peer_project="duindorpteneu-staging"
      ;;
    *)
      echo "Runnerboundary vereist staging of production." >&2
      return 1
      ;;
  esac

  local command
  for command in docker getent id realpath stat; do
    command -v "${command}" >/dev/null 2>&1 || {
      echo "Runnerboundary mist vereist commando: ${command}" >&2
      return 1
    }
  done

  [[ "${GITHUB_REPOSITORY:-}" == "duindorpteneu/platform" ]] || {
    echo "Runner hoort niet bij de canonieke repository." >&2
    return 1
  }
  [[ "${RUNNER_NAME:-}" == "${expected_runner}" ]] || {
    echo "Onjuiste self-hosted runner voor ${environment}." >&2
    return 1
  }
  [[ "$(id -un)" == "${expected_user}" ]] || {
    echo "Onjuiste Unix-principal voor ${environment}." >&2
    return 1
  }
  [[ "${USER:-}" == "${expected_user}" && "${HOME:-}" == "${expected_home}" ]] || {
    echo "Runnerenvironment wijkt af van de Unix-principal." >&2
    return 1
  }

  local passwd_home own_uid own_gid peer_uid peer_gid
  passwd_home="$(getent passwd "${expected_user}" | cut -d: -f6)"
  own_uid="$(id -u "${expected_user}")"
  own_gid="$(id -g "${expected_user}")"
  peer_uid="$(id -u "${peer_user}")"
  peer_gid="$(id -g "${peer_user}")"
  [[ "${passwd_home}" == "${expected_home}"
    && "${own_uid}" != 0
    && "${own_uid}" != "${peer_uid}"
    && "${own_gid}" != "${peer_gid}" ]] || {
    echo "Unix-principals zijn niet aantoonbaar gescheiden." >&2
    return 1
  }
  [[ " $(id -G "${expected_user}") " != *" ${peer_gid} "* ]] || {
    echo "Eigen runnerprincipal is lid van de peer-hoofdgroep." >&2
    return 1
  }
  [[ " $(id -G "${peer_user}") " != *" ${own_gid} "* ]] || {
    echo "Peer-runnerprincipal is lid van de eigen hoofdgroep." >&2
    return 1
  }

  [[ -d "${expected_home}" && ! -L "${expected_home}"
    && "$(stat -c '%u:%a' "${expected_home}")" == "${own_uid}:700" ]] || {
    echo "Runnerhome is niet privé of heeft een onjuiste eigenaar." >&2
    return 1
  }
  [[ -d "${peer_home}" && ! -r "${peer_home}" && ! -w "${peer_home}"
    && ! -x "${peer_home}" ]] || {
    echo "Peer-runnerhome is toegankelijk voor deze principal." >&2
    return 1
  }

  local workspace_root workspace_path temp_path
  workspace_root="${expected_home}/actions-runner/_work"
  workspace_path="$(realpath "${GITHUB_WORKSPACE:-/niet-aanwezig}" 2>/dev/null || true)"
  temp_path="$(realpath "${RUNNER_TEMP:-/niet-aanwezig}" 2>/dev/null || true)"
  [[ "${workspace_path}" == "${workspace_root}/"* ]] || {
    echo "GITHUB_WORKSPACE valt buiten de private runnerhome." >&2
    return 1
  }
  [[ "${temp_path}" == "${workspace_root}/_temp"
    || "${temp_path}" == "${workspace_root}/_temp/"* ]] || {
    echo "RUNNER_TEMP valt buiten de private runnerhome." >&2
    return 1
  }

  local base_directory="/srv/apps/duindorpteneu"
  local base_mode
  base_mode="$(stat -c '%a' "${base_directory}" 2>/dev/null || true)"
  [[ -d "${base_directory}" && ! -L "${base_directory}"
    && "$(stat -c '%u' "${base_directory}")" == 0
    && ! -w "${base_directory}"
    && "${base_mode}" =~ ^[0-7]{3,4}$
    && $((8#${base_mode} & 0022)) -eq 0 ]] || {
    echo "Gedeelde runtimebasis is niet root-owned en schrijfgesloten." >&2
    return 1
  }
  [[ -d "${expected_runtime}" && ! -L "${expected_runtime}"
    && "$(stat -c '%u:%a' "${expected_runtime}")" == "${own_uid}:700" ]] || {
    echo "Eigen runtimeboom is niet vooraf veilig ingericht." >&2
    return 1
  }
  [[ -d "${peer_runtime}" && ! -r "${peer_runtime}"
    && ! -w "${peer_runtime}" && ! -x "${peer_runtime}"
    && "$(stat -c '%u:%a' "${peer_runtime}")" == "${peer_uid}:700" ]] || {
    echo "Peer-runtimeboom is niet aantoonbaar ontoegankelijk." >&2
    return 1
  }

  local expected_runtime_dir expected_socket socket_mode
  expected_runtime_dir="/run/user/${own_uid}"
  expected_socket="${expected_runtime_dir}/docker.sock"
  [[ "${XDG_RUNTIME_DIR:-}" == "${expected_runtime_dir}"
    && "${DOCKER_HOST:-}" == "unix://${expected_socket}"
    && -S "${expected_socket}" && ! -L "${expected_socket}"
    && "$(stat -c '%u:%g' "${expected_socket}")" == "${own_uid}:${own_gid}" ]] || {
    echo "Rootless Docker-socket is niet aan de eigen principal gebonden." >&2
    return 1
  }
  socket_mode="$(stat -c '%a' "${expected_socket}")"
  [[ "${socket_mode}" == 600 ]] || {
    echo "Rootless Docker-socket heeft te ruime rechten." >&2
    return 1
  }
  [[ "$(docker info --format '{{json .SecurityOptions}}')" == *rootless* ]] || {
    echo "Dockerdaemon is niet Rootless." >&2
    return 1
  }
  local docker_root
  docker_root="$(
    realpath "$(docker info --format '{{.DockerRootDir}}')" 2>/dev/null || true
  )"
  [[ "${docker_root}" == "${expected_home}/.local/share/docker" ]] || {
    echo "Docker data-root is niet environment-eigen." >&2
    return 1
  }
  [[ -z "$(docker ps -aq \
    --filter "label=com.docker.compose.project=${peer_project}")" ]] || {
    echo "Eigen Dockerdaemon kan het peer-Composeproject zien." >&2
    return 1
  }

  local marker="/etc/duindorpteneu-runners/${environment}.conf"
  local expected_marker actual_marker
  expected_marker="$(
    printf 'runner=%s\nuser=%s\nhome=%s\nruntime=%s' \
      "${expected_runner}" "${expected_user}" "${expected_home}" \
      "${expected_runtime}"
  )"
  actual_marker="$(tr -d '\r' < "${marker}" 2>/dev/null || true)"
  [[ -f "${marker}" && ! -L "${marker}"
    && "$(stat -c '%u:%a' "${marker}")" == "0:444"
    && "${actual_marker}" == "${expected_marker}" ]] || {
    echo "Root-owned runnerprovisioningmarker ontbreekt of wijkt af." >&2
    return 1
  }

  echo "Self-hosted runnerboundary voor ${environment} is fail-closed bewezen."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  assert_runner_boundary "${1:-}"
fi
