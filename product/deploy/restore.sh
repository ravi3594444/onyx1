#!/usr/bin/env bash
# Restores a backup.sh backup into a separate Compose project for an isolated test.
# Usage: product/deploy/restore.sh <backup folder> <deployment/docker_compose folder> <project>
# The compose folder must hold the same release files. The script copies env.backup to .env.
# Set HOST_PORT and HOST_PORT_80 to keep the restored nginx off the live ports.
set -euo pipefail

backup_dir="$(cd "${1:?backup folder}" && pwd)"
compose_dir="$(cd "${2:?compose folder}" && pwd)"
project="${3:?project name, for example onyx-restore}"
volumes=(db_volume opensearch-data minio_data file-system)
tool_image="postgres:15.2-alpine"

(cd "${backup_dir}" && sha256sum -c SHA256SUMS)
if [[ ! -e "${compose_dir}/.env" ]]; then
  cp "${backup_dir}/env.backup" "${compose_dir}/.env"
  chmod 600 "${compose_dir}/.env"
fi
compose() { (cd "${compose_dir}" && docker compose -p "${project}" "$@"); }

# create makes the project's volumes and containers without starting them.
compose create
for volume in "${volumes[@]}"; do
  docker run --rm -v "${project}_${volume}:/volume" -v "${backup_dir}:/backup:ro" \
    "${tool_image}" sh -c "rm -rf /volume/* /volume/.[!.]* 2>/dev/null; tar -xzf /backup/${volume}.tar.gz -C /volume"
done
compose up -d
echo "Restored into project ${project}."
