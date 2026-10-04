#!/usr/bin/env bash
# Deploys one commit of the fork on the development VM. axi-deploy-dev.yml pipes it over SSH.
# Usage: deploy-remote.sh <full commit SHA>
# Assumes: /srv/onyx-src is a clone of the fork with remote "origin", and /srv/onyx holds
# the release files and the .env from make-env.sh (RUNBOOK.md, section 3).
# The HEAD of /srv/onyx-src is the commit whose files are in /srv/onyx.
# ALLOW_ROLLBACK=1 permits an older commit. ALLOW_RELEASE_CHANGE=1 permits a new Onyx release.
# The script never creates .env and never removes containers or volumes.
set -euo pipefail

# Bash reads the whole function before it runs it, so no command reads the piped script.
main() {
  local sha="${1:?usage: deploy-remote.sh <full commit SHA>}"
  local src_dir="${ONYX_SRC_DIR:-/srv/onyx-src}"
  local deploy_dir="${ONYX_DEPLOY_DIR:-/srv/onyx}"
  local health_timeout="${DEPLOY_HEALTH_TIMEOUT:-900}"
  local compose_dir="${deploy_dir}/deployment/docker_compose"
  local env_file="${compose_dir}/.env"
  local log="${deploy_dir}/deploy.log"

  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "Give the full 40-character commit SHA."
  [[ -f "${env_file}" ]] ||
    die "${env_file} is missing. Run product/deploy/make-env.sh once (RUNBOOK.md, section 3)."

  git -C "${src_dir}" fetch --quiet origin "${sha}"
  if [[ "${ALLOW_ROLLBACK:-0}" != 1 ]]; then
    git -C "${src_dir}" merge-base --is-ancestor HEAD "${sha}" ||
      die "${sha} does not include the deployed commit $(git -C "${src_dir}" rev-parse HEAD)." \
        "To deploy an older commit, set ALLOW_ROLLBACK=1."
  fi

  stage="$(mktemp -d)"
  trap 'rm -rf "${stage}"' EXIT
  # release.env comes from the commit that this script deploys.
  git -C "${src_dir}" show "${sha}:product/deploy/release.env" >"${stage}/release.env"
  # shellcheck disable=SC1091
  source "${stage}/release.env"
  local tag="${ONYX_RELEASE_TAG}" current_tag
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ONYX_RELEASE_TAG is not a release tag: ${tag}"
  current_tag="$(sed -n -E 's/^IMAGE_TAG=//p' "${env_file}" | tail -n 1)"
  if [[ "${current_tag}" != "${tag}" && "${ALLOW_RELEASE_CHANGE:-0}" != 1 ]]; then
    die "The Onyx release changes from ${current_tag:-none} to ${tag}. The new release migrates" \
      "the database. Run product/deploy/backup.sh first, then deploy with ALLOW_RELEASE_CHANGE=1."
  fi

  git -C "${src_dir}" fetch --quiet --no-tags https://github.com/onyx-dot-app/onyx \
    "refs/tags/${tag}:refs/tags/${tag}"
  [[ "$(git -C "${src_dir}" rev-parse "refs/tags/${tag}^{commit}")" == "${ONYX_RELEASE_COMMIT}" ]] ||
    die "Tag ${tag} is not commit ${ONYX_RELEASE_COMMIT}."

  # Prepare the new files in the stage folder and pull the images from there.
  # If the pull fails, no live file changes.
  local stage_compose="${stage}/deployment/docker_compose"
  git -C "${src_dir}" archive "${tag}" deployment/docker_compose deployment/data |
    tar -x -C "${stage}"
  git -C "${src_dir}" show "${sha}:product/deploy/compose.override.yml" \
    >"${stage_compose}/compose.override.yml"
  # The HTTPS overlay (RUNBOOK.md, section 3a). COMPOSE_FILE in .env can name it, so the stage
  # pull needs it too. A commit without the file leaves no empty file behind.
  git -C "${src_dir}" show "${sha}:product/deploy/compose.https.yml" \
    >"${stage_compose}/compose.https.yml" 2>/dev/null || rm -f "${stage_compose}/compose.https.yml"
  cp -p "${env_file}" "${stage_compose}/.env"
  set_env_value "${stage_compose}/.env" IMAGE_TAG "${tag}"
  set_env_value "${stage_compose}/.env" ONYX_BACKEND_IMAGE "${ONYX_BACKEND_IMAGE}"
  set_env_value "${stage_compose}/.env" ONYX_WEB_SERVER_IMAGE "${ONYX_WEB_SERVER_IMAGE}"
  set_env_value "${stage_compose}/.env" ONYX_MODEL_SERVER_IMAGE "${ONYX_MODEL_SERVER_IMAGE}"
  echo "$(date -u +%FT%TZ) Deploy ${sha} with Onyx ${tag}." >>"${log}"
  (cd "${stage_compose}" && docker compose pull --quiet) >>"${log}" 2>&1 ||
    die "docker compose pull failed. No live file changed. See ${log}."

  git -C "${src_dir}" checkout --quiet --detach "${sha}"
  cp -a "${stage}/deployment" "${deploy_dir}/"
  # up -d replaces changed containers and keeps the named volumes.
  # Compose writes only to the log, so a closed SSH session does not interrupt it.
  (cd "${compose_dir}" && docker compose up -d) >>"${log}" 2>&1 ||
    die "docker compose up failed. See ${log}."

  local port url deadline
  port="$(sed -n -E 's/^HOST_PORT=//p' "${env_file}" | tail -n 1)"
  # With the HTTPS overlay, nginx publishes only ports 80 and 443.
  if [[ "$(sed -n -E 's/^COMPOSE_FILE=//p' "${env_file}" | tail -n 1)" == *compose.https.yml* ]]; then
    port=80
  fi
  url="http://localhost:${port:-3000}/api/health"
  deadline=$((SECONDS + health_timeout))
  until curl -fsS -o /dev/null --max-time 10 "${url}"; do
    ((SECONDS < deadline)) ||
      die "${url} is not healthy after ${health_timeout} s. Inspect: cd ${compose_dir} && docker compose logs api_server"
    sleep 10
  done
  echo "Deployed ${sha} with Onyx ${tag}. ${url} answers 200." | tee -a "${log}"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Same rule as make-env.sh: replace the line (also a commented one), or append it.
set_env_value() {
  local env_file="$1" key="$2" value="$3"
  if grep -qE "^#? ?${key}=" "${env_file}"; then
    sed -i -E "s|^#? ?${key}=.*|${key}=${value}|" "${env_file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${env_file}"
  fi
}

main "$@"
