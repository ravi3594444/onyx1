#!/usr/bin/env bash
# Cleans up after the code interpreter (0.4.7) of the production multi-tenant stack:
#   1. removes executor containers (code-exec-*) that are older than CI_EXEC_MAX_AGE_SEC
#      on the executor Docker daemon. When the API dies in the middle of a run, the
#      executor container keeps sleeping for about 694 days.
#   2. deletes staged files older than CI_FILE_MAX_AGE_MIN in the running
#      code-interpreter container. The API never deletes them.
#   3. repairs the code-interpreter container while no vm-bootstrap action runs (the VM
#      lock is free) and the stack runs (api_server runs): it starts the container when
#      its start failed (the executor socket did not exist yet at boot), and restarts it
#      when it is unhealthy (for example after a restart of the executor daemon, which
#      makes a new socket file).
# vm-bootstrap.sh ci-host-setup installs this script as /srv/onyx/bin/ci-cleanup.sh and a
# systemd timer (ci-cleanup.timer) runs it as root every 5 minutes. The marker
# /srv/onyx/ci-executor.env names the socket of the executor daemon.
# The script prints names, ages and states only. It never prints a secret.
set -euo pipefail

marker="${CI_EXECUTOR_MARKER:-/srv/onyx/ci-executor.env}"
lock_file="${CI_VM_LOCK:-/srv/onyx/.vm-ops.lock}"
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
  env -u DOCKER_HOST docker "$@"
}

# 1. Executor containers.
now="$(date +%s)"
removed=0
kept=0
ids="$(executor ps -q --filter name=code-exec-)"
if [[ -n "${ids}" ]]; then
  # Word splitting is intended: ids is a list of container ids. A container that ends
  # between ps and inspect is gone, so inspect errors go to /dev/null.
  # shellcheck disable=SC2086
  while read -r id name started; do
    [[ -n "${id}" ]] || continue
    name="${name#/}"
    [[ "${name}" == code-exec-* ]] || continue
    started_s="$(date -d "${started}" +%s 2>/dev/null || echo "${now}")"
    age=$((now - started_s))
    if ((age > max_age_sec)); then
      if executor rm -f "${id}" >/dev/null 2>&1; then
        echo "removed ${name} (age ${age} s)"
        removed=$((removed + 1))
      else
        echo "ERROR: could not remove ${name}" >&2
      fi
    else
      kept=$((kept + 1))
    fi
  done < <(executor inspect --format '{{.Id}} {{.Name}} {{.State.StartedAt}}' ${ids} 2>/dev/null || true)
fi
echo "executor containers: removed ${removed}, running ${kept}"

# The newest container of a compose service of the project (also a stopped one).
service_container() {
  main_docker ps -aq --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}

# 2. Staged files.
container="$(service_container "${service}")"
state=""
health=""
start_error=""
if [[ -n "${container}" ]]; then
  state="$(main_docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null || true)"
  health="$(main_docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container}" 2>/dev/null || true)"
  # Docker sets State.Error when a start fails (a missing bind source, for example). A
  # container that someone stopped has no error, and the script leaves it stopped.
  start_error="$(main_docker inspect --format '{{.State.Error}}' "${container}" 2>/dev/null || true)"
fi
if [[ "${state}" == running ]]; then
  deleted="$(main_docker exec "${container}" find "${files_dir}" -type f -mmin "+${file_max_age_min}" -print -delete | wc -l)"
  echo "staged files older than ${file_max_age_min} min deleted in ${service}: ${deleted}"
else
  echo "${service} of project ${project} is not running (${state:-no container}): no staged files to delete"
fi

# 3. Repairs. Only while no vm-bootstrap action holds the VM lock: saas-restore-test stops
# the tool services on purpose, and saas-update recreates them.
[[ -n "${container}" ]] || exit 0
api_state="$(main_docker inspect --format '{{.State.Status}}' "$(service_container api_server)" 2>/dev/null || true)"
if [[ "${api_state}" != running ]]; then
  echo "api_server of project ${project} is not running: no repair"
  exit 0
fi
if [[ "${state}" == running && "${health}" != unhealthy ]]; then
  exit 0
fi
if [[ "${state}" != running && -z "${start_error}" ]]; then
  echo "${service} is ${state} without a start error (stopped on purpose): no repair"
  exit 0
fi
exec 9>>"${lock_file}"
if ! flock -n 9; then
  echo "a vm-bootstrap action holds ${lock_file}: no repair of ${service} (${state}, ${health:-no health})"
  exit 0
fi
if [[ "${state}" == running ]]; then
  echo "${service} is unhealthy: restarting it"
  main_docker restart "${container}" >/dev/null
elif [[ "${state}" == exited || "${state}" == created ]]; then
  echo "${service} is ${state} after a failed start while api_server runs: starting it"
  main_docker start "${container}" >/dev/null
else
  echo "${service} is ${state}: no repair"
fi
