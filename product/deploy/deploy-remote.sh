#!/usr/bin/env bash
# Deploys one commit of the fork on the development VM. axi-deploy-dev.yml pipes it over SSH.
# Usage: deploy-remote.sh <full commit SHA>
# Assumes: /srv/onyx-src is a clone of the fork with remote "origin", and /srv/onyx holds
# the release files and the .env from make-env.sh (RUNBOOK.md, section 3).
#
# Policy: an automatic deploy deploys only what product/deploy/release.env pins at that commit
# (image digests, overlays, settings). A change of the Onyx release (ONYX_RELEASE_TAG) migrates
# the database, so it needs a manual run with allow_release_change (ALLOW_RELEASE_CHANGE=1).
# ALLOW_ROLLBACK=1 permits an older commit. The script never creates .env and never removes
# containers or volumes.
#
# The active stack comes from /srv/onyx/active-stack ("onyx" or "onyx-saas"). Without the
# marker, a running project onyx-saas selects onyx-saas. The script stops when both projects
# run or the state is ambiguous, and it never starts project onyx while onyx-saas is active.
#   onyx:      the single-tenant path below (stage, pull, up -d, health).
#   onyx-saas: takes the VM lock /srv/onyx/.vm-ops.lock, stages vm-bootstrap.sh from the commit
#              and runs "saas-update <sha> [release-change]" detached, with its output in a log.
#              The last line is RESULT=deployed|unchanged|rolled-back|failed. The exit code is
#              non-zero for failed and rolled-back. /srv/onyx/deploy.log keeps one line per run.
set -euo pipefail

# Bash reads the whole function before it runs it, so no command reads the piped script.
main() {
  local sha="${1:?usage: deploy-remote.sh <full commit SHA>}"
  local src_dir="${ONYX_SRC_DIR:-/srv/onyx-src}"
  local deploy_dir="${ONYX_DEPLOY_DIR:-/srv/onyx}"
  local saas_dir="${ONYX_SAAS_DIR:-/srv/onyx-saas}"
  local health_timeout="${DEPLOY_HEALTH_TIMEOUT:-900}"
  local compose_dir="${deploy_dir}/deployment/docker_compose"
  local env_file="${compose_dir}/.env"
  local log="${deploy_dir}/deploy.log"

  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "Give the full 40-character commit SHA."
  [[ "${ALLOW_RELEASE_CHANGE:-0}" =~ ^[01]$ ]] || die "ALLOW_RELEASE_CHANGE must be 0 or 1."
  [[ "${ALLOW_ROLLBACK:-0}" =~ ^[01]$ ]] || die "ALLOW_ROLLBACK must be 0 or 1."

  local active
  active="$(active_stack "${deploy_dir}")"
  echo "Active stack: ${active}."
  if [[ "${active}" == onyx-saas ]]; then
    # set -e: a non-zero return ends the script with the exit code of the update.
    deploy_saas "${sha}" "${src_dir}" "${deploy_dir}" "${saas_dir}" "${log}"
    return
  fi
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

  # Last guard: the pull took time, and onyx-saas owns ports 80 and 443 when it runs.
  local saas_now
  saas_now="$(running_containers onyx-saas)" || die "docker ps failed. Project onyx was not started."
  [[ -z "${saas_now}" ]] ||
    die "Project onyx-saas started during the deploy. Project onyx was not started."
  git -C "${src_dir}" checkout --quiet --detach "${sha}"
  cp -a "${stage}/deployment" "${deploy_dir}/"
  # up -d replaces changed containers and keeps the named volumes.
  # Compose writes only to the log, so a closed SSH session does not interrupt it.
  (cd "${compose_dir}" && docker compose up -d) >>"${log}" 2>&1 ||
    die "docker compose up failed. See ${log}."

  local port domain url deadline
  port="$(sed -n -E 's/^HOST_PORT=//p' "${env_file}" | tail -n 1)"
  url="http://localhost:${port:-3000}/api/health"
  # With the HTTPS overlay, port 80 only redirects, so the check uses the public HTTPS URL.
  if [[ "$(sed -n -E 's/^COMPOSE_FILE=//p' "${env_file}" | tail -n 1)" == *compose.https.yml* ]]; then
    domain="$(sed -n -E 's/^DOMAIN=//p' "${env_file}" | tail -n 1)"
    [[ -n "${domain}" ]] || die "COMPOSE_FILE names compose.https.yml but .env has no DOMAIN."
    url="https://${domain}/api/health"
  fi
  deadline=$((SECONDS + health_timeout))
  # Only HTTP 200 passes: curl -f accepts a redirect.
  until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}" || true)" == 200 ]]; do
    ((SECONDS < deadline)) ||
      die "${url} is not healthy after ${health_timeout} s. Inspect: cd ${compose_dir} && docker compose logs api_server"
    sleep 10
  done
  echo "Deployed ${sha} with Onyx ${tag}. ${url} answers 200." | tee -a "${log}"
  echo "RESULT=deployed"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Running containers of one Compose project (exact project name). Fails when docker fails.
running_containers() {
  docker ps -q --filter "label=com.docker.compose.project=$1"
}

# Prints "onyx" or "onyx-saas". Stops when the marker and the containers disagree.
active_stack() {
  local deploy_dir="$1" marker="" saas live
  if [[ -f "${deploy_dir}/active-stack" ]]; then
    marker="$(tr -d '[:space:]' <"${deploy_dir}/active-stack")"
    [[ "${marker}" == onyx || "${marker}" == onyx-saas ]] ||
      die "${deploy_dir}/active-stack holds an unknown value: ${marker}"
  fi
  saas="$(running_containers onyx-saas)" || die "docker ps failed. Nothing was deployed."
  live="$(running_containers onyx)" || die "docker ps failed. Nothing was deployed."
  [[ -z "${saas}" || -z "${live}" ]] ||
    die "Both projects onyx and onyx-saas have running containers. Stop one first (rollback or cutover)."
  case "${marker}" in
    onyx-saas) echo onyx-saas ;;
    onyx)
      [[ -z "${saas}" ]] ||
        die "${deploy_dir}/active-stack says onyx, but project onyx-saas runs. Fix the marker first."
      echo onyx
      ;;
    *)
      if [[ -n "${saas}" ]]; then echo onyx-saas; else echo onyx; fi
      ;;
  esac
}

# Deploys <sha> on project onyx-saas through "vm-bootstrap.sh saas-update" of that commit.
deploy_saas() {
  local sha="$1" src_dir="$2" deploy_dir="$3" saas_dir="$4" log="$5"
  local mode="" deployed stage run_log pid code=0 result
  [[ "${ALLOW_RELEASE_CHANGE:-0}" != 1 ]] || mode=release-change

  # One VM operation at a time (shared with vm-bootstrap.sh). The detached run below inherits
  # fd 8, so the lock lasts until saas-update ends, also when the SSH session drops.
  exec 8>"${deploy_dir}/.vm-ops.lock"
  flock -w 1200 8 || die "Another VM operation holds ${deploy_dir}/.vm-ops.lock. Nothing was deployed."
  export VM_OPS_LOCKED=1

  git -C "${src_dir}" fetch --quiet origin "${sha}"
  deployed="$(sed -n -E 's/^DEPLOYED_SHA=//p' "${saas_dir}/deployed.env" 2>/dev/null | tail -n 1 || true)"
  if [[ "${ALLOW_ROLLBACK:-0}" != 1 && "${deployed}" =~ ^[0-9a-f]{40}$ && "${deployed}" != "${sha}" ]]; then
    git -C "${src_dir}" merge-base --is-ancestor "${deployed}" "${sha}" ||
      die "${sha} does not include the deployed commit ${deployed}." \
        "To deploy an older commit, set ALLOW_ROLLBACK=1 on the VM."
  fi

  # The stage lives under ${deploy_dir}: a dropped SSH session must not remove the running
  # script. The lock serialises the runs, so fixed names are safe.
  stage="${deploy_dir}/saas-update-stage"
  mkdir -p "${stage}"
  run_log="${stage}/saas-update.log"
  git -C "${src_dir}" show "${sha}:product/deploy/vm-bootstrap.sh" >"${stage}/vm-bootstrap.sh"
  [[ -s "${stage}/vm-bootstrap.sh" ]] || die "${sha} has no product/deploy/vm-bootstrap.sh."
  bash -n "${stage}/vm-bootstrap.sh" || die "vm-bootstrap.sh of ${sha} does not parse."

  echo "$(date -u +%FT%TZ) saas-update ${sha} start (mode=${mode:-pins-only})." >>"${log}"
  : >"${run_log}"
  # Detached in its own session: a closed SSH session does not stop the update. Its output
  # goes to the log, and tail streams the log until the process ends.
  # shellcheck disable=SC2086
  setsid bash "${stage}/vm-bootstrap.sh" saas-update "${sha}" ${mode} \
    >"${run_log}" 2>&1 </dev/null &
  pid=$!
  echo "saas-update runs as PID ${pid}. Log: ${run_log}"
  tail -n +1 -f --pid="${pid}" "${run_log}" || true
  wait "${pid}" || code=$?

  result="$(sed -n -E 's/^RESULT=//p' "${run_log}" | tail -n 1)"
  result="${result:-missing}"
  # Only deployed and unchanged pass. A missing line means the script died.
  if ((code == 0)) && [[ "${result}" != deployed && "${result}" != unchanged ]]; then
    code=1
  fi
  echo "$(date -u +%FT%TZ) saas-update ${sha} RESULT=${result} exit=${code} (mode=${mode:-pins-only})." >>"${log}"
  echo "RESULT=${result}"
  return "${code}"
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
