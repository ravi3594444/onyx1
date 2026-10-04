#!/usr/bin/env bash
# Creates the .env for the pinned Onyx release in an exported deployment folder.
# Usage: product/deploy/make-env.sh <deployment/docker_compose folder> [web domain]
# The script does not overwrite an existing .env, because .env holds the secrets.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_dir="${1:?usage: make-env.sh <deployment/docker_compose folder> [web domain]}"
web_domain="${2:-http://localhost:3000}"
env_file="${compose_dir}/.env"

if [[ -e "${env_file}" ]]; then
  echo "${env_file} exists. Stop: the script does not replace generated secrets." >&2
  exit 1
fi

# shellcheck source=release.env disable=SC1091
source "${script_dir}/release.env"

set_env_value() {
  local key="$1" value="$2"
  if grep -qE "^#? ?${key}=" "${env_file}"; then
    sed -i -E "s|^#? ?${key}=.*|${key}=${value}|" "${env_file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${env_file}"
  fi
}

umask 077
cp "${compose_dir}/env.template" "${env_file}"

set_env_value IMAGE_TAG "${ONYX_RELEASE_TAG}"
set_env_value ONYX_BACKEND_IMAGE "${ONYX_BACKEND_IMAGE}"
set_env_value ONYX_WEB_SERVER_IMAGE "${ONYX_WEB_SERVER_IMAGE}"
set_env_value ONYX_MODEL_SERVER_IMAGE "${ONYX_MODEL_SERVER_IMAGE}"
set_env_value WEB_DOMAIN "${web_domain}"
# Keep ENABLE_PAID_ENTERPRISE_EDITION_FEATURES at the template default (false).
# Without a license, true locks the whole UI. An uploaded license sets the tier.

set_env_value USER_AUTH_SECRET "$(openssl rand -hex 32)"
# The application trims this key to 32 bytes. Back it up with the database.
set_env_value ENCRYPTION_KEY_SECRET "$(openssl rand -hex 16)"
set_env_value POSTGRES_PASSWORD "$(openssl rand -hex 24)"
# OpenSearch needs upper case, lower case, a digit and a special character.
set_env_value OPENSEARCH_ADMIN_PASSWORD "Os1-$(openssl rand -hex 16)"

# The application uses the MinIO root credentials, so both pairs must match.
minio_user="onyx-$(openssl rand -hex 6)"
minio_password="$(openssl rand -hex 24)"
set_env_value MINIO_ROOT_USER "${minio_user}"
set_env_value MINIO_ROOT_PASSWORD "${minio_password}"
set_env_value S3_AWS_ACCESS_KEY_ID "${minio_user}"
set_env_value S3_AWS_SECRET_ACCESS_KEY "${minio_password}"

echo "Created ${env_file} for Onyx ${ONYX_RELEASE_TAG}. Keep a secure copy of it."
