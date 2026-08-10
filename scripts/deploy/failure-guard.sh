#!/usr/bin/env bash

deployment_die() {
  echo "$1" >&2
  if [[ "${activated:-false}" == true ]] \
    && declare -F rollback >/dev/null 2>&1
  then
    rollback 1
  fi
  exit 1
}
