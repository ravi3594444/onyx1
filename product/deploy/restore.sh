#!/usr/bin/env bash
# Restores a backup.sh backup into a new Compose project for an isolated test.
# Usage: product/deploy/restore.sh <backup folder> <deployment/docker_compose folder> <project>
# The compose folder must hold the same release files. The script copies env.backup to .env.
# An existing .env must be identical to env.backup.
# The project must be new: the script stops if its volumes or containers exist.
# Set HOST_PORT and HOST_PORT_80 to keep the restored nginx off the live ports.
# The script starts only nginx and the services that it needs. It does not start the background
# service: it runs the connector syncs and the Slack and Discord bots with the live credentials.
# RESTORE_HEALTH_TIMEOUT (seconds, default 900) limits the start and the health check together.
set -euo pipefail

backup_dir="$(cd "${1:?backup folder}" && pwd)"
compose_dir="$(cd "${2:?compose folder}" && pwd)"
project="${3:?project name, for example onyx-restore}"
volumes=(db_volume opensearch-data minio_data file-system)
tool_image="${BACKUP_TOOL_IMAGE:-postgres:15.2-alpine}"
health_timeout="${RESTORE_HEALTH_TIMEOUT:-900}"
env_file="${compose_dir}/.env"
secrets=(USER_AUTH_SECRET ENCRYPTION_KEY_SECRET POSTGRES_PASSWORD OPENSEARCH_ADMIN_PASSWORD
  S3_AWS_ACCESS_KEY_ID S3_AWS_SECRET_ACCESS_KEY)

die() {
  echo "ERROR: $*" >&2
  exit 1
}
compose() { (cd "${compose_dir}" && docker compose -p "${project}" "$@"); }
# Prints the last value of a key in .env, without surrounding quotes.
env_value() {
  sed -n -E "s/^${1}=//p" "${env_file}" | tail -n 1 | sed -E "s/^\"(.*)\"$|^'(.*)'$/\1\2/"
}

# Compose normalizes other names, and the volume names below must match.
[[ "${project}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Use only a-z, 0-9, _ and - in the project name."
[[ "${health_timeout}" =~ ^[1-9][0-9]*$ ]] || die "RESTORE_HEALTH_TIMEOUT must be a number of seconds."
logs_hint="Inspect: cd ${compose_dir} && docker compose -p ${project} logs api_server"

# backup.sh writes SHA256SUMS last, so a complete backup lists every file.
(cd "${backup_dir}" && sha256sum -c --strict SHA256SUMS)
for file in "${volumes[@]/%/.tar.gz}" env.backup; do
  awk -v f="${file}" '$2 == f || $2 == "./" f { found = 1 } END { exit !found }' \
    "${backup_dir}/SHA256SUMS" || die "SHA256SUMS does not list ${file}. The backup is not complete."
done

# Never delete or overwrite existing data: the target project must be new.
containers="$(compose ps -a -q)"
[[ -z "${containers}" ]] || die "Project ${project} has containers. Use a new project name."
for volume in "${volumes[@]}"; do
  if docker volume inspect "${project}_${volume}" >/dev/null 2>&1; then
    die "Volume ${project}_${volume} exists. Use a new project name."
  fi
done

# The restored secrets must be the backed-up secrets.
if [[ -e "${env_file}" ]]; then
  cmp -s "${backup_dir}/env.backup" "${env_file}" ||
    die "${env_file} differs from env.backup. Use a compose folder without .env."
else
  install -m 600 "${backup_dir}/env.backup" "${env_file}"
fi
for key in "${secrets[@]}"; do
  [[ -n "$(env_value "${key}")" ]] || die "${key} is missing or empty in ${env_file}."
done

# create makes the project's volumes and containers without starting them.
compose create
for volume in "${volumes[@]}"; do
  docker run --rm -v "${project}_${volume}:/volume" -v "${backup_dir}:/backup:ro" \
    "${tool_image}" tar -xzf "/backup/${volume}.tar.gz" -C /volume
done

# A healthy API proves that the restored database and OpenSearch passwords work.
# nginx waits for a healthy api_server, so up can wait a long time. timeout limits it.
deadline=$((SECONDS + health_timeout))
(cd "${compose_dir}" && timeout "${health_timeout}" docker compose -p "${project}" up -d nginx) ||
  die "docker compose up failed or took more than ${health_timeout} s. ${logs_hint}"
port="${HOST_PORT:-$(env_value HOST_PORT)}"
url="http://localhost:${port:-3000}/api/health"
until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}" || true)" == 200 ]]; do
  ((SECONDS < deadline)) ||
    die "${url} is not healthy after ${health_timeout} s. ${logs_hint}"
  sleep 5
done
echo "Restored into project ${project}. ${url} answers 200."
echo "The background service is not started. Disable the connectors and the bots before you start it."
