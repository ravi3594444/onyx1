#!/usr/bin/env bash
# Cold backup of the durable Onyx volumes. The stack stops during the copy.
# Usage: product/deploy/backup.sh <deployment/docker_compose folder> <backup folder> [project]
# The backup folder must not exist. The script writes into a temporary sibling folder and
# renames it only after SHA256SUMS is complete. A failed copy leaves no backup folder.
# Copy the backup folder off the VM. It holds .env, which contains secrets.
set -euo pipefail
# The backup holds secrets and customer data: only the owner may read it.
umask 077

compose_dir="$(cd "${1:?compose folder}" && pwd)"
backup_dir="${2:?backup folder}"
project="${3:-onyx}"
# Postgres, OpenSearch, MinIO file store, and the shared file-system volume.
# Model caches, logs and Redis are not durable state.
volumes=(db_volume opensearch-data minio_data file-system)
tool_image="${BACKUP_TOOL_IMAGE:-postgres:15.2-alpine}"

if [[ -e "${backup_dir}" ]]; then
  echo "${backup_dir} exists. Stop: give a new backup folder." >&2
  exit 1
fi
mkdir -p "$(dirname "${backup_dir}")"
backup_dir="$(cd "$(dirname "${backup_dir}")" && pwd)/$(basename "${backup_dir}")"
compose() { (cd "${compose_dir}" && docker compose -p "${project}" "$@"); }
start_hint="Run: cd ${compose_dir} && docker compose -p ${project} start"
# docker run creates a missing volume, which would give an empty backup.
for volume in "${volumes[@]}"; do
  if ! docker volume inspect "${project}_${volume}" >/dev/null; then
    echo "Volume ${project}_${volume} does not exist. Stop: check the project name." >&2
    exit 1
  fi
done

stopped=0
work_dir=""
# Signals cannot stop the start. A failed start prints the manual command.
start_stack() {
  trap '' HUP INT TERM
  local status=0
  compose start || status=1
  stopped=0
  ((status == 0)) || echo "ERROR: the stack did not start. ${start_hint}" >&2
  return "${status}"
}
# Starts the stack again if this script stopped it, and removes a partial backup.
# Errors and signals in here must not skip the start.
finish() {
  local status=$?
  set +e
  trap '' HUP INT TERM PIPE
  if ((stopped)); then
    # If stderr is gone (a closed terminal), send the output to /dev/null so that it cannot stop the start.
    echo "Backup failed. Starting the stack again." >&2 || exec >/dev/null 2>&1
    start_stack || status=1
  fi
  if ((status != 0)) && [[ -n "${work_dir}" ]]; then
    rm -rf "${work_dir}" || echo "Remove the partial backup ${work_dir}." >&2
    echo "ERROR: backup failed. ${backup_dir} was not written." >&2
  fi
  exit "${status}"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM

work_dir="$(mktemp -d "${backup_dir}.incomplete.XXXXXX")"
install -m 600 "${compose_dir}/.env" "${work_dir}/env.backup"

started=$(date +%s)
stopped=1
compose stop
for volume in "${volumes[@]}"; do
  # This shell writes the archive, so the user of this script owns it, also with rootless Docker.
  docker run --rm -v "${project}_${volume}:/volume:ro" "${tool_image}" tar -czf - -C /volume . \
    >"${work_dir}/${volume}.tar.gz"
done
# A deploy or a second backup can start the stack during the copy. Then the copy is not consistent.
running="$(compose ps -q)"
if [[ -n "${running}" ]]; then
  echo "ERROR: the stack ran during the copy. Make sure nothing starts it, then try again." >&2
  exit 1
fi
start_failed=0
start_stack || start_failed=1
trap 'exit 1' HUP INT TERM
downtime=$(($(date +%s) - started))

# The copy is complete also if the start failed, because the stack was stopped.
(cd "${work_dir}" && sha256sum ./*.tar.gz env.backup >SHA256SUMS)
mv -T "${work_dir}" "${backup_dir}"
work_dir=""
echo "Backup in ${backup_dir}. Downtime: ${downtime} s."
if ((start_failed)); then
  echo "ERROR: the backup is complete, but the stack is stopped. ${start_hint}" >&2
  exit 1
fi
