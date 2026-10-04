#!/usr/bin/env bash
# Cold backup of the durable Onyx volumes. The stack stops during the copy.
# Usage: product/deploy/backup.sh <deployment/docker_compose folder> <backup folder> [project]
# Copy the backup folder off the VM. It holds .env, which contains secrets.
set -euo pipefail

compose_dir="$(cd "${1:?compose folder}" && pwd)"
backup_dir="${2:?backup folder}"
project="${3:-onyx}"
# Postgres, OpenSearch, MinIO file store, and the shared file-system volume.
# Model caches, logs and Redis are not durable state.
volumes=(db_volume opensearch-data minio_data file-system)
tool_image="postgres:15.2-alpine"

mkdir -p "${backup_dir}"
backup_dir="$(cd "${backup_dir}" && pwd)"
compose() { (cd "${compose_dir}" && docker compose -p "${project}" "$@"); }

started=$(date +%s)
compose stop
for volume in "${volumes[@]}"; do
  docker run --rm -v "${project}_${volume}:/volume:ro" -v "${backup_dir}:/backup" \
    "${tool_image}" tar -czf "/backup/${volume}.tar.gz" -C /volume .
done
compose start
cp "${compose_dir}/.env" "${backup_dir}/env.backup"
chmod 600 "${backup_dir}/env.backup"
(cd "${backup_dir}" && sha256sum ./*.tar.gz env.backup > SHA256SUMS)
echo "Backup in ${backup_dir}. Downtime: $(( $(date +%s) - started )) s."
