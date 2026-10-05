#!/usr/bin/env bash
# Cleans up after the code interpreter (0.4.7) of the production multi-tenant stack:
#   1. removes executor containers (code-exec-*) that are older than CI_EXEC_MAX_AGE_SEC
#      on the executor Docker daemon. When the API dies in the middle of a run, the
#      executor container keeps sleeping for about 694 days.
#   2. deletes staged files older than CI_FILE_MAX_AGE_MIN in the running
#      code-interpreter container. The API never deletes them.
# vm-bootstrap.sh ci-host-setup installs this script as /srv/onyx/bin/ci-cleanup.sh and a
# systemd timer (ci-cleanup.timer) runs it as root every 5 minutes. The marker
# /srv/onyx/ci-executor.env names the socket of the executor daemon.
# The script prints names and ages only. It never prints a secret.
set -euo pipefail

marker="${CI_EXECUTOR_MARKER:-/srv/onyx/ci-executor.env}"
max_age_sec="${CI_EXEC_MAX_AGE_SEC:-300}"
file_max_age_min="${CI_FILE_MAX_AGE_MIN:-30}"
project="${CI_COMPOSE_PROJECT:-onyx-saas}"
service="${CI_COMPOSE_SERVICE:-code-interpreter}"
files_dir="${CI_FILES_DIR:-/tmp/code-interpreter-files}"

if [[ ! -f "${marker}" ]]; then
  echo "no marker ${marker}: nothing to do"
  exit 0
fi
sock="$(sed -n -E 's/^DOCKER_SOCK_PATH=//p' "${marker}" | tail -n 1)"
[[ -n "${sock}" ]] || { echo "ERROR: DOCKER_SOCK_PATH is empty in ${marker}" >&2; exit 1; }
if [[ ! -S "${sock}" ]]; then
  echo "ERROR: ${sock} is not a socket (the executor daemon is down?)" >&2
  exit 1
fi

# Docker commands on the executor daemon (DOCKER_HOST) and on the main daemon.
executor() {
  DOCKER_HOST="unix://${sock}" docker "$@"
}
main_docker() {
  docker "$@"
}

now="$(date +%s)"
removed=0
kept=0
ids="$(executor ps -q --filter name=code-exec- | tr '\n' ' ')"
if [[ -n "${ids// /}" ]]; then
  # Word splitting is intended: ids is a list of container ids.
  # shellcheck disable=SC2086
  while read -r id name started; do
    [[ -n "${id}" ]] || continue
    name="${name#/}"
    [[ "${name}" == code-exec-* ]] || continue
    started_s="$(date -d "${started}" +%s 2>/dev/null || echo "${now}")"
    age=$((now - started_s))
    if ((age > max_age_sec)); then
      if executor rm -f "${id}" >/dev/null; then
        echo "removed ${name} (age ${age} s)"
        removed=$((removed + 1))
      else
        echo "ERROR: could not remove ${name}" >&2
      fi
    else
      kept=$((kept + 1))
    fi
  done < <(executor inspect --format '{{.Id}} {{.Name}} {{.State.StartedAt}}' ${ids})
fi
echo "executor containers: removed ${removed}, running ${kept}"

container="$(main_docker ps -q --filter "label=com.docker.compose.project=${project}" \
  --filter "label=com.docker.compose.service=${service}" --filter status=running | head -n 1)"
if [[ -n "${container}" ]]; then
  deleted="$(main_docker exec "${container}" find "${files_dir}" -type f -mmin "+${file_max_age_min}" -print -delete | wc -l)"
  echo "staged files older than ${file_max_age_min} min deleted in ${service}: ${deleted}"
else
  echo "${service} of project ${project} is not running: no staged files to delete"
fi
