#!/usr/bin/env bash
# Prepares and checks the development VM. axi-bootstrap-dev.yml pipes it over SSH.
# Usage: vm-bootstrap.sh inspect
#        vm-bootstrap.sh install <full commit SHA> <web domain>
#        vm-bootstrap.sh verify <full commit SHA> [with-chat]
#        vm-bootstrap.sh restart <full commit SHA>
#        vm-bootstrap.sh https <full commit SHA> <email> [staging]
#        vm-bootstrap.sh owner <full commit SHA> <owner email> <invite email|-> <keep|on|off>
#        vm-bootstrap.sh model <full commit SHA> <litellm provider> <model id|list>
#        vm-bootstrap.sh smtp <full commit SHA>
#        vm-bootstrap.sh keygen
#        vm-bootstrap.sh mt-up <full commit SHA> | mt-check <full commit SHA> [after-restart]
#        vm-bootstrap.sh mt-restart <full commit SHA> | mt-down | mt-destroy
#        vm-bootstrap.sh inventory <full commit SHA> [owner email]
#        vm-bootstrap.sh cutover <full commit SHA> <letsencrypt email> <owner email>
#        vm-bootstrap.sh rollback <full commit SHA>
#        vm-bootstrap.sh saas-check <full commit SHA> [after-restart] | saas-restart <full commit SHA>
#        vm-bootstrap.sh saas-journey <full commit SHA> [after-restart]
#        vm-bootstrap.sh saas-defaults <full commit SHA> [dry-run]
#        vm-bootstrap.sh saas-update <full commit SHA> [release-change]
#        vm-bootstrap.sh saas-down <full commit SHA>
#        vm-bootstrap.sh ci-host-setup <full commit SHA> [main-socket]
#        vm-bootstrap.sh saas-rotate-key <full commit SHA> [dry-run]
#        vm-bootstrap.sh saas-backup <full commit SHA> | saas-restore-test <full commit SHA> [backup folder]
#        vm-bootstrap.sh saas-tools-check <full commit SHA>
#        vm-bootstrap.sh assistant-prompt <full commit SHA> <set|reset|show> | chat-check <full commit SHA>
# Layout on the VM: /srv/onyx-src (clone of the fork), /srv/onyx (release files, .env,
# evidence, secrets, the ci-executor.env marker, active-stack), /srv/backups, /srv/onyx-mt
# (multi-tenant test stack), /srv/onyx-saas (multi-tenant production stack after the cutover,
# with rollback/ snapshots and deployed.env), /srv/onyx-saas-restore (restore test copy).
# See product/deploy/RUNBOOK.md, product/deploy/mt/README.md and docs/product/MULTI-TENANT.md.
# The script never creates a second .env for the live stack, never removes the live volumes
# and never prints a secret. It needs python3 and curl; both are present on Debian and Ubuntu.
# Every action except inspect takes the lock /srv/onyx/.vm-ops.lock (vm_lock).
# The actions run as "<function> 2>&1 | tee <log> || code=$?" (with_evidence), where set -e
# has no effect: every step of an action checks its own result (|| die, || return 1).
set -euo pipefail

# VM_BOOTSTRAP_SRV_ROOT replaces /srv only in local tests of this script.
readonly SRV_ROOT="${VM_BOOTSTRAP_SRV_ROOT:-/srv}"
readonly ONYX_SRC_DIR="${SRV_ROOT}/onyx-src"
readonly ONYX_DEPLOY_DIR="${SRV_ROOT}/onyx"
readonly ONYX_RESTORE_DIR="${SRV_ROOT}/onyx-restore"
readonly BACKUP_ROOT="${SRV_ROOT}/backups"
readonly EVIDENCE_ROOT="${ONYX_DEPLOY_DIR}/evidence"
readonly USERS_FILE="${ONYX_DEPLOY_DIR}/test-users.env"
# The workflow writes model.env and smtp.env here (mode 600) from the environment secrets.
readonly SECRETS_DIR="${ONYX_DEPLOY_DIR}/secrets"
# The model that the live stack runs (model action, run 25). Default for the platform model.
readonly DEFAULT_PLATFORM_MODEL=accounts/fireworks/models/deepseek-v4p1-flash
readonly COMPOSE_DIR="${ONYX_DEPLOY_DIR}/deployment/docker_compose"
readonly RESTORE_COMPOSE_DIR="${ONYX_RESTORE_DIR}/deployment/docker_compose"
readonly FORK_URL=https://github.com/ravi3594444/onyx1
readonly UPSTREAM_URL=https://github.com/onyx-dot-app/onyx
# set_live_url reads .env: the public HTTPS URL with the HTTPS overlay, else HOST_PORT on
# localhost. PUBLIC_URL is the HTTPS URL when the overlay is active, else empty.
LIVE_URL=http://localhost:3000
PUBLIC_URL=""
readonly RESTORE_URL=http://localhost:3100
readonly RESTORE_PROJECT=onyx-restore
readonly HEALTH_TIMEOUT=900
readonly DNS_NAME=my-knowledge.duckdns.org
# The connectors that run_checks.py and prune_race.py create. verify removes them first.
readonly TEST_CONNECTOR_NAMES=("PRD test corpus" "Prune race corpus")
readonly TEST_PROJECT_NAME="HR private"

# Set by docker_setup: "docker" or "sudo -n docker".
DOCKER_CMD=()
# Step results of verify, in run order.
STEP_NAMES=()
STEP_CODES=()
# 1 while verify has the live stack stopped.
LIVE_STOPPED=0
# Cookie jar of the admin session in verify.
ADMIN_JAR=""
# 1 when saas_model_defaults replaced the platform key in the saas .env in this run.
PLATFORM_KEY_CHANGED=0

main() {
  # Bash has read the whole script here. Nothing must read the piped script by mistake.
  exec </dev/null
  local action="${1:-}"
  shift || true
  [[ "${action}" == inspect || -z "${action}" ]] || vm_lock
  case "${action}" in
    inspect) inspect ;;
    install) install_stack "$@" ;;
    verify) verify_wrapper "$@" ;;
    restart) restart_wrapper "$@" ;;
    https) enable_https "$@" ;;
    owner) owner_wrapper "$@" ;;
    model) model_wrapper "$@" ;;
    smtp) smtp_setup "$@" ;;
    keygen) inbox_keygen ;;
    mt-up) mt_up_wrapper "$@" ;;
    mt-check) mt_check_wrapper "$@" ;;
    mt-restart) mt_restart_wrapper "$@" ;;
    mt-down) mt_down_wrapper "$@" ;;
    mt-destroy) mt_destroy_wrapper "$@" ;;
    inventory) inventory_wrapper "$@" ;;
    cutover) cutover_wrapper "$@" ;;
    rollback) rollback_wrapper "$@" ;;
    saas-check) saas_check_wrapper "$@" ;;
    saas-restart) saas_restart_wrapper "$@" ;;
    saas-journey) saas_journey_wrapper "$@" ;;
    saas-defaults) saas_defaults_wrapper "$@" ;;
    saas-update) saas_update_wrapper "$@" ;;
    saas-down) saas_down_wrapper "$@" ;;
    ci-host-setup) ci_host_setup_wrapper "$@" ;;
    saas-rotate-key) saas_rotate_key_wrapper "$@" ;;
    saas-backup) saas_backup_wrapper "$@" ;;
    saas-restore-test) saas_restore_test_wrapper "$@" ;;
    saas-tools-check) saas_tools_check_wrapper "$@" ;;
    assistant-prompt) assistant_prompt_wrapper "$@" ;;
    chat-check) chat_check_wrapper "$@" ;;
    *) die "usage: vm-bootstrap.sh inspect | install <sha> <web domain> | verify <sha> [with-chat] | restart <sha> | https <sha> <email> [staging] | owner <sha> <email> <invite|-> <keep|on|off> | model <sha> <provider> <model|list> | smtp <sha> | keygen | mt-up <sha> | mt-check <sha> [after-restart] | mt-restart <sha> | mt-down | mt-destroy | inventory <sha> [owner email] | cutover <sha> <email> <owner email> | rollback <sha> | saas-check <sha> [after-restart] | saas-restart <sha> | saas-journey <sha> [after-restart] | saas-defaults <sha> [dry-run] | saas-update <sha> [release-change] | saas-down <sha> | ci-host-setup <sha> [main-socket] | saas-rotate-key <sha> [dry-run] | saas-backup <sha> | saas-restore-test <sha> [backup folder] | saas-tools-check <sha> | assistant-prompt <sha> <set|reset|show> | chat-check <sha>" ;;
  esac
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# One action at a time on this VM: flock on VM_LOCK_FILE (fd 8), 20 minutes of patience.
# VM_OPS_LOCKED=1 means a parent process holds the lock already (it is exported).
vm_lock() {
  if [[ "${VM_OPS_LOCKED:-0}" == 1 ]]; then
    echo "vm lock: held by the parent process."
    return 0
  fi
  if [[ ! -d "${ONYX_DEPLOY_DIR}" || ! -w "${ONYX_DEPLOY_DIR}" ]]; then
    echo "vm lock: ${ONYX_DEPLOY_DIR} is not writable (before the install action): no lock."
    return 0
  fi
  exec 8>>"${VM_LOCK_FILE}" || die "cannot open ${VM_LOCK_FILE}."
  flock -w 1200 8 || die "another vm-bootstrap action holds ${VM_LOCK_FILE} (waited 1200 s)."
  export VM_OPS_LOCKED=1
  echo "vm lock: ${VM_LOCK_FILE} taken."
}

section() {
  printf '\n== %s ==\n' "$*"
}

# Runs a command and prints "missing" when it fails. For inspect: nothing stops the report.
show() {
  local title="$1"
  shift
  section "${title}"
  "$@" 2>&1 || echo "missing"
}

# Prints the key names of an env file, never the values.
env_keys() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "${file}" |
      sort -u | tr '\n' ' '
    echo
  else
    echo "missing"
  fi
}

# Lists a folder without .env values.
list_dir() {
  local dir="$1"
  if [[ -d "${dir}" ]]; then
    ls -la "${dir}"
    local env_file
    while IFS= read -r env_file; do
      echo "-- keys in ${env_file}:"
      env_keys "${env_file}"
    done < <(find "${dir}" -maxdepth 3 -name '.env' -type f 2>/dev/null)
  else
    echo "missing"
  fi
}

check_sha() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || die "Give the full 40-character commit SHA."
}

have_sudo() {
  sudo -n true 2>/dev/null
}

# Chooses plain docker or sudo docker. A fresh docker group applies only to a new login.
docker_setup() {
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif have_sudo && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo -n docker)
  else
    die "Docker does not answer for this user, also not with sudo. Run the install action first."
  fi
}

dk() {
  "${DOCKER_CMD[@]}" "$@"
}

live_compose() {
  (cd "${COMPOSE_DIR}" && dk compose "$@")
}

# The restore folder has no compose.https.yml. The shell value of COMPOSE_FILE wins over
# the restored .env, so the restored stack uses only the two files that exist there.
restore_compose() {
  (cd "${RESTORE_COMPOSE_DIR}" &&
    COMPOSE_FILE=docker-compose.yml:compose.override.yml dk compose -p "${RESTORE_PROJECT}" "$@")
}

http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true
}

# Waits until <url>/api/health answers 200. On a timeout it prints what curl saw.
wait_health() {
  local base_url="$1" timeout="${2:-${HEALTH_TIMEOUT}}" deadline
  deadline=$((SECONDS + timeout))
  until [[ "$(http_code "${base_url}/api/health")" == 200 ]]; do
    ((SECONDS < deadline)) || {
      echo "ERROR: ${base_url}/api/health is not healthy after ${timeout} s." >&2
      curl_diagnostics "${base_url}/api/health"
      return 1
    }
    sleep 10
  done
  echo "${base_url}/api/health answers 200."
}

# Prints the HTTP code, the TLS result and the last lines of a verbose curl of <url>.
curl_diagnostics() {
  local url="$1"
  echo "-- curl ${url}"
  curl -sS -o /dev/null -w 'http_code=%{http_code} ssl_verify_result=%{ssl_verify_result} remote_ip=%{remote_ip} time_total=%{time_total}\n' \
    --max-time 20 -v "${url}" 2>&1 | grep -v '^[{}] \[' | tail -n 25 || true
  if [[ ${#DOCKER_CMD[@]} -gt 0 && -f "${COMPOSE_DIR}/.env" ]]; then
    live_compose ps --format '{{.Name}} {{.Status}} {{.Ports}}' 2>&1 || true
    live_compose logs --tail 20 nginx 2>&1 || true
  fi
}

# Records whether the public HTTPS URL answers, with a trusted certificate, like a user sees it.
check_public_url() {
  local deadline code
  [[ -n "${PUBLIC_URL}" ]] || { echo "No HTTPS overlay in .env: no public URL to check."; return 0; }
  deadline=$((SECONDS + 60))
  while :; do
    code="$(http_code "${PUBLIC_URL}/api/health")"
    [[ "${code}" == 200 ]] && break
    ((SECONDS < deadline)) || {
      echo "ERROR: ${PUBLIC_URL}/api/health answers ${code}, not 200." >&2
      curl_diagnostics "${PUBLIC_URL}/api/health"
      return 1
    }
    sleep 5
  done
  echo "${PUBLIC_URL}/api/health answers 200."
  echo "-- certificate"
  echo | openssl s_client -connect "${DNS_NAME}:443" -servername "${DNS_NAME}" 2>/dev/null |
    openssl x509 -noout -issuer -subject -enddate 2>&1 || true
  code="$(http_code "http://${DNS_NAME}/")"
  [[ "${code}" =~ ^30[1278]$ ]] || { echo "ERROR: http://${DNS_NAME}/ answers ${code}, not a redirect." >&2; return 1; }
  echo "http://${DNS_NAME}/ redirects (${code})."
}

# ---------------------------------------------------------------- inspect

inspect() {
  section "vm-bootstrap inspect $(date -u +%FT%TZ) on $(hostname)"
  show "os-release" cat /etc/os-release
  show "kernel" uname -a
  show "nproc" nproc
  show "memory" free -h
  show "disk / and /srv" df -h / /srv
  show "block devices" lsblk -o NAME,SIZE,MOUNTPOINT
  section "sudo -n"
  if have_sudo; then echo "ok"; else echo "denied"; fi
  show "id" id
  show "docker version" docker --version
  show "docker compose version" docker compose version
  show "systemctl is-active docker" systemctl is-active docker
  section "docker for this user"
  if docker info >/dev/null 2>&1; then
    echo "docker info works without sudo"
    show "docker ps -a" docker ps -a
    show "docker volume ls" docker volume ls
  elif have_sudo && sudo -n docker info >/dev/null 2>&1; then
    echo "docker works only with sudo. A new login applies the docker group."
    show "sudo docker ps -a" sudo -n docker ps -a
    show "sudo docker volume ls" sudo -n docker volume ls
  else
    echo "docker does not work for this user (missing or no access)"
  fi
  show "sysctl vm.max_map_count" sysctl vm.max_map_count
  section "ulimit -n"
  ulimit -n
  section "listening TCP sockets"
  ss -ltnp 2>/dev/null || ss -ltn 2>/dev/null || echo "missing"
  section "owners of port 80 and 443"
  if have_sudo; then
    sudo -n ss -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null || echo "missing"
  else
    echo "sudo denied: process names are not visible"
    ss -ltn '( sport = :80 or sport = :443 )' 2>/dev/null || echo "missing"
  fi
  show "DNS ${DNS_NAME}" getent ahosts "${DNS_NAME}"
  section "public IP"
  curl -fsS --max-time 5 https://api.ipify.org || echo "missing"
  echo
  show "${ONYX_SRC_DIR}" list_dir "${ONYX_SRC_DIR}"
  section "${ONYX_SRC_DIR} HEAD"
  git -C "${ONYX_SRC_DIR}" log -1 --format='%H %cI %s' 2>/dev/null || echo "missing"
  show "${ONYX_DEPLOY_DIR}" list_dir "${ONYX_DEPLOY_DIR}"
  show "${COMPOSE_DIR}" list_dir "${COMPOSE_DIR}"
  show "${BACKUP_ROOT}" list_dir "${BACKUP_ROOT}"
  show "${EVIDENCE_ROOT}" ls -la "${EVIDENCE_ROOT}"
  show "code interpreter host facts" ci_host_facts
  section "inspect complete"
}

# ---------------------------------------------------------------- install

install_stack() {
  local sha="${1:-}" web_domain="${2:-}"
  check_sha "${sha}"
  [[ "${web_domain}" =~ ^https?:// ]] || die "Give the web domain with http:// or https://."
  have_sudo || die "sudo -n is denied for $(id -un). The install action needs sudo without a password."

  install_docker
  configure_host
  checkout_source "${sha}"
  export_release_files "${COMPOSE_DIR}" "${sha}"
  if [[ -f "${COMPOSE_DIR}/.env" ]]; then
    echo "${COMPOSE_DIR}/.env exists. The script keeps it."
  else
    "${ONYX_SRC_DIR}/product/deploy/make-env.sh" "${COMPOSE_DIR}" "${web_domain}"
  fi

  docker_setup
  check_ports
  section "docker compose pull"
  live_compose pull --quiet
  section "docker compose up -d"
  live_compose up -d
  set_live_url
  wait_health "${LIVE_URL}"
  show "docker compose ps" live_compose ps
  show "docker compose images" live_compose images
  show "memory" free -h
  show "disk /" df -h /
  section "install complete: ${sha} with $(release_value ONYX_RELEASE_TAG) at ${web_domain}"
}

install_docker() {
  section "Docker Engine"
  if docker compose version >/dev/null 2>&1 || sudo -n docker compose version >/dev/null 2>&1; then
    echo "Docker and the Compose plugin are installed."
  else
    local id codename
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && echo "${ID}")"
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
    [[ "${id}" == debian || "${id}" == ubuntu ]] || die "Unsupported distribution ${id}. Install Docker by hand."
    export DEBIAN_FRONTEND=noninteractive
    sudo -n -E apt-get -y update
    sudo -n -E apt-get -y install ca-certificates curl git
    sudo -n install -m 0755 -d /etc/apt/keyrings
    sudo -n curl -fsSL "https://download.docker.com/linux/${id}/gpg" -o /etc/apt/keyrings/docker.asc
    sudo -n chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${id} ${codename} stable" |
      sudo -n tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo -n -E apt-get -y update
    sudo -n -E apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo -n systemctl enable --now docker
  fi
  sudo -n usermod -aG docker "$(id -un)"
  echo "$(id -un) is in the docker group. A new login applies it."
}

configure_host() {
  section "host settings"
  echo "vm.max_map_count=262144" | sudo -n tee /etc/sysctl.d/99-onyx.conf >/dev/null
  sudo -n sysctl --system >/dev/null
  sysctl vm.max_map_count
  sudo -n install -d -o "$(id -un)" -g "$(id -gn)" "${ONYX_SRC_DIR}" "${ONYX_DEPLOY_DIR}" "${BACKUP_ROOT}" \
    "${ONYX_RESTORE_DIR}"
  command -v git >/dev/null || sudo -n -E apt-get -y install git
}

# Clones the fork if needed and checks out <sha> detached.
checkout_source() {
  local sha="$1"
  section "source at ${sha}"
  if [[ ! -d "${ONYX_SRC_DIR}/.git" ]]; then
    git clone --filter=blob:none "${FORK_URL}" "${ONYX_SRC_DIR}" || return 1
  fi
  git -C "${ONYX_SRC_DIR}" fetch --quiet origin "${sha}" || return 1
  git -C "${ONYX_SRC_DIR}" checkout --quiet --detach "${sha}" || return 1
  git -C "${ONYX_SRC_DIR}" log -1 --format='%H %cI %s' || return 1
}

release_value() {
  sed -n -E "s/^${1}=//p" "${ONYX_SRC_DIR}/product/deploy/release.env" | tail -n 1
}

# Fetches the pinned tag, checks its commit and exports the deployment files into
# <compose dir>/../.. . It never touches .env.
export_release_files() {
  local compose_dir="$1" sha="$2" tag commit target
  tag="$(release_value ONYX_RELEASE_TAG)"
  commit="$(release_value ONYX_RELEASE_COMMIT)"
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ONYX_RELEASE_TAG is not a release tag: ${tag}"
  section "release files ${tag} into ${compose_dir}"
  git -C "${ONYX_SRC_DIR}" fetch --quiet --no-tags "${UPSTREAM_URL}" "refs/tags/${tag}:refs/tags/${tag}" || return 1
  [[ "$(git -C "${ONYX_SRC_DIR}" rev-parse "refs/tags/${tag}^{commit}")" == "${commit}" ]] ||
    die "Tag ${tag} is not commit ${commit}."
  mkdir -p "${compose_dir}" || return 1
  target="$(cd "${compose_dir}/../.." && pwd)" || return 1
  git -C "${ONYX_SRC_DIR}" archive "${tag}" deployment/docker_compose deployment/data | tar -x -C "${target}" || return 1
  export_overlay "${sha}" product/deploy/compose.override.yml "${compose_dir}" || return 1
  echo "Exported ${tag} (${commit}) and compose.override.yml."
}

# Copies one file from the checkout at <sha> into <dir> (compose overlays, tool configs).
# It writes a temporary file first, checks that it is not empty, then moves it into place:
# a failed git show never leaves an empty or half-written file. The files hold no secret,
# so mode 644 lets the containers read the mounted configs.
export_overlay() {
  local sha="$1" path="$2" dir="$3" name tmp
  name="$(basename "${path}")"
  mkdir -p "${dir}" || return 1
  tmp="$(mktemp "${dir}/.${name}.XXXXXX")" || return 1
  if git -C "${ONYX_SRC_DIR}" show "${sha}:${path}" >"${tmp}" 2>/dev/null && [[ -s "${tmp}" ]]; then
    chmod 644 "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${dir}/${name}" || { rm -f "${tmp}"; return 1; }
    echo "Exported ${name}."
  else
    rm -f "${tmp}"
    echo "ERROR: ${path} is missing or empty at ${sha}." >&2
    return 1
  fi
}

# Reads a key from the live .env, or prints the default.
# With compose.https.yml in COMPOSE_FILE, nginx publishes only ports 80 and 443.
set_live_url() {
  if [[ "$(live_env_value COMPOSE_FILE "")" == *compose.https.yml* ]]; then
    # Plain HTTP on the published port 80 only redirects, so the checks use the public
    # HTTPS URL, with a trusted certificate, like a user does.
    LIVE_URL="https://${DNS_NAME}"
    PUBLIC_URL="${LIVE_URL}"
  else
    LIVE_URL="http://localhost:$(live_env_value HOST_PORT 3000)"
  fi
}

live_env_value() {
  local value=""
  if [[ -f "${COMPOSE_DIR}/.env" ]]; then
    value="$(sed -n -E "s/^${1}=//p" "${COMPOSE_DIR}/.env" | tail -n 1)"
  fi
  echo "${value:-$2}"
}

# nginx publishes HOST_PORT_80 (80) and HOST_PORT (3000). A port that another process
# holds makes "up" fail. The script names the process and stops; it kills nothing.
check_ports() {
  section "published ports"
  local port owner
  for port in "$(live_env_value HOST_PORT_80 80)" "$(live_env_value HOST_PORT 3000)"; do
    owner="$(sudo -n ss -ltnpH "sport = :${port}" 2>/dev/null || ss -ltnH "sport = :${port}" 2>/dev/null || true)"
    if [[ -z "${owner}" ]]; then
      echo "port ${port}: free"
    elif grep -q 'docker-proxy\|dockerd' <<<"${owner}" && dk ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"; then
      echo "port ${port}: published by a Docker container (the stack, presumably)"
    else
      echo "${owner}"
      die "Port ${port} is in use by another process (see above). Stop it or set HOST_PORT_80/HOST_PORT in .env. The script kills nothing."
    fi
  done
}

# ---------------------------------------------------------------- verify

verify_wrapper() {
  local sha="${1:-}" mode="${2:-}" evidence
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == with-chat ]] || die "The second argument must be with-chat or empty."
  mkdir -p "${EVIDENCE_ROOT}"
  evidence="${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${evidence}"
  echo "Evidence folder: ${evidence}"
  # tee keeps a copy on the VM; stdout goes to the Actions log. pipefail gives the verify code.
  local code=0
  verify "${sha}" "${mode}" "${evidence}" 2>&1 | tee "${evidence}/verify.log" || code=$?
  return "${code}"
}

# Records the exit code of a step and continues after a failure.
run_step() {
  local name="$1" code=0
  shift
  section "step ${name}"
  "$@" || code=$?
  STEP_NAMES+=("${name}")
  STEP_CODES+=("${code}")
  echo "-- step ${name}: exit ${code}"
  return 0
}

verify() {
  local sha="$1" mode="$2" evidence="$3" with_chat=0 work_dir
  [[ "${mode}" == with-chat ]] && with_chat=1
  section "vm-bootstrap verify ${sha} $(date -u +%FT%TZ) (with_chat=${with_chat})"
  docker info >/dev/null 2>&1 ||
    die "docker does not work without sudo. backup.sh and restore.sh need it. Log in again after the install action."
  docker_setup
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. Run the install action first."
  set_live_url
  wait_health "${LIVE_URL}" 60 || die "The live stack is not healthy. Run the install action first."

  checkout_source "${sha}"
  work_dir="$(mktemp -d)"
  export TMPDIR="${work_dir}"
  trap 'on_verify_exit' EXIT

  ensure_test_users
  # shellcheck disable=SC1090
  source "${USERS_FILE}"
  export ADMIN_EMAIL ADMIN_PASSWORD USER_A_EMAIL USER_A_PASSWORD USER_B_EMAIL USER_B_PASSWORD
  admin_login "${LIVE_URL}" "${work_dir}/admin.jar"
  check_admin_capabilities

  run_step public-url check_public_url
  run_step cleanup cleanup_previous_runs

  local checks="${ONYX_SRC_DIR}/product/test-corpus/run_checks.py"
  local -a chat_flag=(--skip-chat) steps=(index search privacy update delete)
  if ((with_chat)); then
    chat_flag=()
    steps=(index search chat chat-forced privacy update delete)
  fi
  local step
  for step in "${steps[@]}"; do
    run_step "${step}" python3 "${checks}" --base-url "${LIVE_URL}" --state "${evidence}/state.json" \
      "${chat_flag[@]}" "${step}"
  done
  # prune_race.py creates its own connector "Prune race corpus".
  run_step prune-race python3 "${ONYX_SRC_DIR}/product/test-corpus/prune_race.py" --base-url "${LIVE_URL}"

  local backup_dir
  backup_dir="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  run_step backup "${ONYX_SRC_DIR}/product/deploy/backup.sh" "${COMPOSE_DIR}" "${backup_dir}" onyx

  if [[ -f "${backup_dir}/SHA256SUMS" ]]; then
    run_step restore isolated_restore "${sha}" "${backup_dir}"
    if [[ "${STEP_CODES[-1]}" == 0 ]]; then
      cp "${evidence}/state.json" "${evidence}/restore-state.json"
      run_step restore-search python3 "${checks}" --base-url "${RESTORE_URL}" \
        --state "${evidence}/restore-state.json" --skip-chat search
      run_step restore-privacy python3 "${checks}" --base-url "${RESTORE_URL}" \
        --state "${evidence}/restore-state.json" --skip-chat privacy
    fi
    run_step restore-down remove_restore_project
    run_step live-start start_live
  else
    echo "No backup folder: the restore test does not run."
  fi

  show "docker stats" docker stats --no-stream
  show "memory" free -m
  show "disk /" df -h /
  env_keys "${USERS_FILE}" >"${evidence}/test-users.keys"

  summary
}

on_verify_exit() {
  local code=$?
  if ((LIVE_STOPPED)); then
    echo "verify ended with the live stack stopped. Starting it." >&2
    start_live || true
  fi
  if ((code != 0)); then
    echo "verify stopped early with exit ${code}." >&2
  fi
}

summary() {
  local i failed=0
  section "summary"
  printf '%-16s %s\n' "step" "exit code"
  for i in "${!STEP_NAMES[@]}"; do
    printf '%-16s %s\n' "${STEP_NAMES[$i]}" "${STEP_CODES[$i]}"
    [[ "${STEP_CODES[$i]}" == 0 ]] || failed=1
  done
  if ((failed)); then
    echo "RESULT: FAIL (one or more steps did not exit with 0)"
    return 1
  fi
  echo "RESULT: PASS (all steps exited with 0)"
}

# ----- users

# Writes the users file once. The passwords stay on the VM; the log shows only the emails.
ensure_test_users() {
  section "test users"
  if [[ ! -f "${USERS_FILE}" ]]; then
    (
      umask 077
      {
        echo "ADMIN_EMAIL=admin@example.com"
        echo "ADMIN_PASSWORD=Tt1-$(openssl rand -hex 12)"
        echo "USER_A_EMAIL=user-a@example.com"
        echo "USER_A_PASSWORD=Tt1-$(openssl rand -hex 12)"
        echo "USER_B_EMAIL=user-b@example.com"
        echo "USER_B_PASSWORD=Tt1-$(openssl rand -hex 12)"
      } >"${USERS_FILE}"
    )
    echo "Created ${USERS_FILE}."
  fi
  chmod 600 "${USERS_FILE}"
  local email password role
  for role in ADMIN USER_A USER_B; do
    email="$(sed -n -E "s/^${role}_EMAIL=//p" "${USERS_FILE}")"
    password="$(sed -n -E "s/^${role}_PASSWORD=//p" "${USERS_FILE}")"
    register_user "${email}" "${password}"
  done
}

# 201: created. 400: the user exists. Anything else stops the script.
register_user() {
  local email="$1" password="$2" body code
  body="$(python3 -c 'import json,sys; print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))' "${email}" "${password}")"
  code="$(curl -s -o "${TMPDIR}/register.out" -w '%{http_code}' --max-time 30 -X POST \
    -H 'Content-Type: application/json' --data "${body}" "${LIVE_URL}/api/auth/register" || true)"
  case "${code}" in
    201) echo "registered ${email}" ;;
    400) echo "${email} exists already ($(tr -d '\n' <"${TMPDIR}/register.out" | cut -c1-120))" ;;
    403)
      # Invite-only sign-up refuses every registration, also of an existing account. The
      # logins of the checks show whether the account exists.
      grep -q "invite-only" "${TMPDIR}/register.out" ||
        die "register ${email} returned 403: $(cut -c1-300 "${TMPDIR}/register.out")"
      echo "${email}: sign-up is invite-only (403), the account must exist already."
      ;;
    *) die "register ${email} returned ${code}: $(cut -c1-300 "${TMPDIR}/register.out")" ;;
  esac
}

# Logs in the admin with curl. The cookie jar stays in the work folder (mode 600).
admin_login() {
  local base_url="$1" jar="$2" code
  ADMIN_JAR="${jar}"
  install -m 600 /dev/null "${jar}"
  code="$(curl -s -o "${TMPDIR}/login.out" -w '%{http_code}' --max-time 30 -c "${jar}" -X POST \
    --data-urlencode "username=${ADMIN_EMAIL}" --data-urlencode "password=${ADMIN_PASSWORD}" \
    "${base_url}/api/auth/login" || true)"
  [[ "${code}" == 200 || "${code}" == 204 ]] ||
    die "admin login returned ${code}: $(cut -c1-300 "${TMPDIR}/login.out")"
}

# Calls the API as the admin. Prints the status code; the body goes to <out file>.
api() {
  local method="$1" path="$2" out="$3" body="${4:-}"
  local -a data=()
  [[ -z "${body}" ]] || data=(-H 'Content-Type: application/json' --data "${body}")
  curl -s -o "${out}" -w '%{http_code}' --max-time 60 -b "${ADMIN_JAR}" -X "${method}" \
    "${data[@]}" "${LIVE_URL}${path}" || true
}

check_admin_capabilities() {
  local code
  code="$(api GET /api/me "${TMPDIR}/me.out")"
  [[ "${code}" == 200 ]] || die "/api/me returned ${code}."
  python3 -c 'import json,sys; sys.exit(0 if "admin" in json.load(open(sys.argv[1])).get("admin_capabilities", []) else 1)' \
    "${TMPDIR}/me.out" ||
    die "${ADMIN_EMAIL} is not an admin: someone else registered the first account. Give that account admin rights, or make ${ADMIN_EMAIL} an admin in Admin > Users."
  echo "${ADMIN_EMAIL} has the admin capability."
}

# ----- cleanup of earlier runs

cleanup_previous_runs() {
  remove_test_connectors || return 1
  remove_test_projects || return 1
  remove_restore_project || return 1
}

# Lists cc-pair ids and names (tab separated) of the test connectors.
list_test_cc_pairs() {
  local code
  code="$(api POST /api/manage/admin/connector/indexing-status "${TMPDIR}/status.out" '{}')"
  [[ "${code}" == 200 ]] || { echo "indexing-status returned ${code}" >&2; return 1; }
  python3 -c '
import json, sys
# prune_race.py adds a time stamp to its connector name, so a prefix also matches.
names = sys.argv[2:]
for group in json.load(open(sys.argv[1])):
    for entry in group.get("indexing_statuses", []):
        name = entry.get("name") or ""
        if "cc_pair_id" in entry and any(name == n or name.startswith(n + " ") for n in names):
            print(entry["cc_pair_id"], entry["name"], sep="\t")
' "${TMPDIR}/status.out" "${TEST_CONNECTOR_NAMES[@]}"
}

remove_test_connectors() {
  local pairs cc_pair_id name code ids deadline
  pairs="$(list_test_cc_pairs)" || return 1
  [[ -n "${pairs}" ]] || { echo "no test connectors from earlier runs"; return 0; }
  while IFS=$'\t' read -r cc_pair_id name; do
    code="$(api GET "/api/manage/admin/cc-pair/${cc_pair_id}" "${TMPDIR}/pair.out")"
    [[ "${code}" == 200 ]] || { echo "cc-pair ${cc_pair_id} returned ${code}" >&2; return 1; }
    ids="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({"connector_id": d["connector"]["id"], "credential_id": d["credential"]["id"]}))' "${TMPDIR}/pair.out")"
    code="$(api PUT "/api/manage/admin/cc-pair/${cc_pair_id}/status" "${TMPDIR}/pause.out" '{"status":"PAUSED"}')"
    [[ "${code}" == 200 ]] || { echo "pause of cc-pair ${cc_pair_id} returned ${code}: $(cut -c1-200 "${TMPDIR}/pause.out")" >&2; return 1; }
    code="$(api POST /api/manage/admin/deletion-attempt "${TMPDIR}/delete.out" "${ids}")"
    [[ "${code}" == 200 ]] || { echo "deletion-attempt for cc-pair ${cc_pair_id} returned ${code}: $(cut -c1-200 "${TMPDIR}/delete.out")" >&2; return 1; }
    echo "deleting connector '${name}' (cc-pair ${cc_pair_id}, ${ids})"
  done <<<"${pairs}"
  deadline=$((SECONDS + 600))
  while IFS=$'\t' read -r cc_pair_id name; do
    until [[ "$(api GET "/api/manage/admin/cc-pair/${cc_pair_id}" /dev/null)" == 404 ]]; do
      ((SECONDS < deadline)) || { echo "cc-pair ${cc_pair_id} ('${name}') still exists after 600 s" >&2; return 1; }
      sleep 5
    done
    echo "connector '${name}' (cc-pair ${cc_pair_id}) is deleted"
  done <<<"${pairs}"
}

# User B owns the "HR private" project that the index step creates. DELETE /api/user/projects/<id>.
remove_test_projects() {
  local jar="${TMPDIR}/user-b.jar" code ids project_id
  install -m 600 /dev/null "${jar}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -c "${jar}" -X POST \
    --data-urlencode "username=${USER_B_EMAIL}" --data-urlencode "password=${USER_B_PASSWORD}" \
    "${LIVE_URL}/api/auth/login" || true)"
  [[ "${code}" == 200 || "${code}" == 204 ]] || { echo "user B login returned ${code}" >&2; return 1; }
  code="$(curl -s -o "${TMPDIR}/projects.out" -w '%{http_code}' --max-time 30 -b "${jar}" "${LIVE_URL}/api/user/projects" || true)"
  [[ "${code}" == 200 ]] || { echo "GET /api/user/projects returned ${code}" >&2; return 1; }
  ids="$(python3 -c 'import json,sys; print("\n".join(str(p["id"]) for p in json.load(open(sys.argv[1])) if p.get("name") == sys.argv[2]))' \
    "${TMPDIR}/projects.out" "${TEST_PROJECT_NAME}")"
  [[ -n "${ids}" ]] || { echo "no '${TEST_PROJECT_NAME}' projects from earlier runs"; return 0; }
  while IFS= read -r project_id; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -b "${jar}" -X DELETE "${LIVE_URL}/api/user/projects/${project_id}" || true)"
    [[ "${code}" == 204 || "${code}" == 200 ]] || { echo "DELETE project ${project_id} returned ${code}" >&2; return 1; }
    echo "deleted project '${TEST_PROJECT_NAME}' (${project_id})"
  done <<<"${ids}"
}

# Removes containers and volumes of the restore project. It touches nothing of project onyx.
remove_restore_project() {
  local containers volumes
  containers="$(dk ps -aq --filter "label=com.docker.compose.project=${RESTORE_PROJECT}")" || return 1
  [[ -z "${containers}" ]] || xargs -r "${DOCKER_CMD[@]}" rm -f <<<"${containers}" >/dev/null || return 1
  volumes="$(dk volume ls -q --filter "label=com.docker.compose.project=${RESTORE_PROJECT}")" || return 1
  [[ -z "${volumes}" ]] || xargs -r "${DOCKER_CMD[@]}" volume rm <<<"${volumes}" >/dev/null || return 1
  dk network rm "${RESTORE_PROJECT}_default" >/dev/null 2>&1 || true
  echo "project ${RESTORE_PROJECT} has no containers and no volumes"
}

# ----- backup and restore

start_live() {
  live_compose start || return 1
  LIVE_STOPPED=0
  set_live_url
  wait_health "${LIVE_URL}"
}

# Restores the backup into a fresh folder on ports 3100 and 8100 while the live stack is stopped.
isolated_restore() {
  local sha="$1" backup_dir="$2"
  # Only root can write /srv, so the folder itself stays and only its content goes.
  if [[ ! -d "${ONYX_RESTORE_DIR}" ]]; then
    sudo -n install -d -o "$(id -un)" -g "$(id -gn)" "${ONYX_RESTORE_DIR}" || return 1
  fi
  find "${ONYX_RESTORE_DIR}" -mindepth 1 -delete || return 1
  mkdir -p "${RESTORE_COMPOSE_DIR}" || return 1
  export_release_files "${RESTORE_COMPOSE_DIR}" "${sha}" || return 1
  # export_release_files runs without errexit here. Check its result before the live stack stops.
  [[ -f "${RESTORE_COMPOSE_DIR}/docker-compose.yml" && -f "${RESTORE_COMPOSE_DIR}/compose.override.yml" ]] || {
    echo "ERROR: the release files are missing in ${RESTORE_COMPOSE_DIR}. The live stack keeps running." >&2
    return 1
  }
  echo "stopping the live stack"
  live_compose stop || return 1
  LIVE_STOPPED=1
  # restore.sh copies env.backup to .env. See restore_compose for COMPOSE_FILE.
  COMPOSE_FILE=docker-compose.yml:compose.override.yml HOST_PORT=3100 HOST_PORT_80=8100 \
    "${ONYX_SRC_DIR}/product/deploy/restore.sh" "${backup_dir}" "${RESTORE_COMPOSE_DIR}" "${RESTORE_PROJECT}"
}


# ---------------------------------------------------------------- restart

restart_wrapper() {
  local sha="${1:-}" evidence code=0
  check_sha "${sha}"
  evidence="${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-restart"
  mkdir -p "${evidence}"
  echo "Evidence folder: ${evidence}"
  restart_stack "${sha}" "${evidence}" 2>&1 | tee "${evidence}/restart.log" || code=$?
  return "${code}"
}

# Recreates all live containers (down, then up -d) and checks that the indexed data and
# the access rules are still there. "down" never gets -v, so the named volumes stay.
restart_stack() {
  local sha="$1" evidence="$2" state volumes_before volumes_after work_dir
  section "vm-bootstrap restart ${sha} $(date -u +%FT%TZ)"
  docker info >/dev/null 2>&1 || die "docker does not work without sudo. Run the install action first."
  docker_setup
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. Run the install action first."
  [[ -f "${USERS_FILE}" ]] || die "${USERS_FILE} is missing. Run the verify action first."
  state="$(find "${EVIDENCE_ROOT}" -mindepth 2 -maxdepth 2 -name state.json | sort | tail -n 1)"
  [[ -n "${state}" ]] || die "No state.json in ${EVIDENCE_ROOT}. Run the verify action first."
  echo "State of the last verify: ${state}"
  cp "${state}" "${evidence}/state.json"
  set_live_url
  wait_health "${LIVE_URL}" 60 || die "The live stack is not healthy before the restart."
  checkout_source "${sha}"
  work_dir="$(mktemp -d)"
  export TMPDIR="${work_dir}"
  # shellcheck disable=SC1090
  source "${USERS_FILE}"
  export ADMIN_EMAIL ADMIN_PASSWORD USER_A_EMAIL USER_A_PASSWORD USER_B_EMAIL USER_B_PASSWORD

  volumes_before="$(dk volume ls -q --filter label=com.docker.compose.project=onyx | sort)"
  show "containers before" live_compose ps --format '{{.Name}} {{.ID}} {{.Status}}'
  run_step down live_compose down
  run_step up live_compose up -d
  run_step health wait_health "${LIVE_URL}"
  run_step public-url check_public_url
  show "containers after" live_compose ps --format '{{.Name}} {{.ID}} {{.Status}}'
  volumes_after="$(dk volume ls -q --filter label=com.docker.compose.project=onyx | sort)"
  echo "volumes: ${volumes_after//$'\n'/ }"
  run_step volumes-kept test -n "${volumes_after}" -a "${volumes_before}" = "${volumes_after}"

  local checks="${ONYX_SRC_DIR}/product/test-corpus/run_checks.py" step
  for step in search privacy; do
    run_step "${step}" python3 "${checks}" --base-url "${LIVE_URL}" --state "${evidence}/state.json" \
      --skip-chat "${step}"
  done
  show "docker stats" dk stats --no-stream
  show "memory" free -m
  summary
}

# ---------------------------------------------------------------- https

# Runs enable-https.sh for DNS_NAME. "staging" requests an untrusted test certificate.
enable_https() {
  local sha="${1:-}" email="${2:-}" mode="${3:-}"
  check_sha "${sha}"
  [[ "${email}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Give a valid email for Let's Encrypt."
  [[ -z "${mode}" || "${mode}" == staging ]] || die "The third argument must be staging or empty."
  section "vm-bootstrap https ${DNS_NAME} ${sha} $(date -u +%FT%TZ) (mode=${mode:-production})"
  docker info >/dev/null 2>&1 || die "docker does not work without sudo. Run the install action first."
  docker_setup
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. Run the install action first."
  checkout_source "${sha}"
  if [[ "${mode}" == staging ]]; then
    STAGING=1 "${ONYX_SRC_DIR}/product/deploy/enable-https.sh" "${COMPOSE_DIR}" "${DNS_NAME}" "${email}"
  else
    "${ONYX_SRC_DIR}/product/deploy/enable-https.sh" "${COMPOSE_DIR}" "${DNS_NAME}" "${email}"
  fi
  set_live_url
  wait_health "${LIVE_URL}"
  show "docker compose ps" live_compose ps
  section "https complete: https://${DNS_NAME}"
}


# ---------------------------------------------------------------- owner, model, smtp

is_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# A plain address without quotes or spaces. The account SQL embeds the owner address.
is_plain_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Shared start of the actions that talk to the live API as the admin test user.
live_action_start() {
  local sha="$1"
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. Run the install action first."
  [[ -f "${USERS_FILE}" ]] || die "${USERS_FILE} is missing. Run the verify action first."
  set_live_url
  wait_health "${LIVE_URL}" 60 || die "The live stack is not healthy."
  checkout_source "${sha}"
  # shellcheck disable=SC1090
  source "${USERS_FILE}"
  export ADMIN_EMAIL ADMIN_PASSWORD
}

# Runs <function> with its arguments and keeps a copy of the output in the evidence folder.
# EVIDENCE_DIR names that folder for the function.
EVIDENCE_DIR=""
with_evidence() {
  local label="$1" evidence code=0
  shift
  mkdir -p "${EVIDENCE_ROOT}"
  evidence="${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-${label}"
  mkdir -p "${evidence}"
  EVIDENCE_DIR="${evidence}"
  echo "Evidence folder: ${evidence}"
  "$@" 2>&1 | tee "${evidence}/${label}.log" || code=$?
  return "${code}"
}

owner_wrapper() {
  local sha="${1:-}" owner="${2:-}" invite="${3:--}" invite_only="${4:-keep}"
  check_sha "${sha}"
  is_email "${owner}" || die "Give the owner email."
  [[ "${invite}" == - ]] || is_email "${invite}" || die "Give an invite email, or - for none."
  [[ "${invite_only}" =~ ^(keep|on|off)$ ]] || die "The invite-only argument must be keep, on or off."
  with_evidence owner owner_admin "${sha}" "${owner}" "${invite}" "${invite_only}"
}

# Grants the owner the admin access, invites a member and sets invite-only sign-up.
owner_admin() {
  local sha="$1" owner="$2" invite="$3" invite_only="$4"
  local -a args
  section "vm-bootstrap owner ${owner} ${sha} $(date -u +%FT%TZ)"
  live_action_start "${sha}"
  # No --list here: the workflow log and its artifact must not carry the member emails.
  args=(--base-url "${LIVE_URL}" --owner "${owner}")
  [[ "${invite}" == - ]] || args+=(--invite "${invite}")
  [[ "${invite_only}" == keep ]] || args+=(--invite-only "${invite_only}")
  python3 "${ONYX_SRC_DIR}/product/deploy/owner-admin.py" "${args[@]}"
}

model_wrapper() {
  local sha="${1:-}" provider="${2:-fireworks_ai}" model="${3:-list}"
  check_sha "${sha}"
  [[ "${provider}" =~ ^[a-z0-9_]+$ ]] || die "Give the LiteLLM provider name, for example fireworks_ai."
  [[ "${model}" =~ ^[A-Za-z0-9._/:-]+$ ]] || die "Give the model id, or list to show the matching models."
  with_evidence model configure_model "${sha}" "${provider}" "${model}"
}

# Configures the hosted model through the admin API. The key stays in model.env.
configure_model() {
  local sha="$1" provider="$2" model="$3"
  section "vm-bootstrap model ${provider} ${model} ${sha} $(date -u +%FT%TZ)"
  if [[ -f "${SECRETS_DIR}/model.sealed" ]]; then
    unseal_model_key
  fi
  [[ -f "${SECRETS_DIR}/model.env" ]] ||
    die "${SECRETS_DIR}/model.env is missing. The workflow writes it from the secret MODEL_API_KEY or the sealed_model_key input."
  # shellcheck disable=SC1090,SC1091
  source "${SECRETS_DIR}/model.env"
  [[ -n "${MODEL_API_KEY:-}" ]] || die "MODEL_API_KEY is empty in ${SECRETS_DIR}/model.env."
  export MODEL_API_KEY MODEL_API_BASE="${MODEL_API_BASE:-}" MODEL_PROVIDER="${provider}" MODEL_NAME="${model}"
  if [[ "${model}" == list ]]; then
    checkout_source "${sha}"
    python3 "${ONYX_SRC_DIR}/product/deploy/configure-model.py" --check-key-only
    return
  fi
  live_action_start "${sha}"
  python3 "${ONYX_SRC_DIR}/product/deploy/configure-model.py" --base-url "${LIVE_URL}"
  # saas_prepare copies these into the platform defaults of the multi-tenant stack.
  set_env_key MODEL_PROVIDER "${provider}" "${SECRETS_DIR}/model.env"
  set_env_key MODEL_NAME "${model}" "${SECRETS_DIR}/model.env"
  echo "Wrote MODEL_PROVIDER and MODEL_NAME into ${SECRETS_DIR}/model.env."
}

# Writes the SMTP values from smtp.env into .env and recreates the services that read them.
smtp_setup() {
  local sha="${1:-}" key
  check_sha "${sha}"
  section "vm-bootstrap smtp ${sha} $(date -u +%FT%TZ)"
  docker info >/dev/null 2>&1 || die "docker does not work without sudo. Run the install action first."
  docker_setup
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. Run the install action first."
  [[ -f "${SECRETS_DIR}/smtp.env" ]] ||
    die "${SECRETS_DIR}/smtp.env is missing. The workflow writes it from the SMTP_* secrets."
  checkout_source "${sha}"
  # shellcheck disable=SC1090,SC1091
  source "${SECRETS_DIR}/smtp.env"
  # Onyx sends email when SMTP_SERVER and EMAIL_FROM are set (EMAIL_CONFIGURED).
  [[ -n "${SMTP_SERVER:-}" && -n "${EMAIL_FROM:-}" ]] || die "SMTP_SERVER and EMAIL_FROM are needed."
  for key in SMTP_SERVER SMTP_PORT SMTP_USER SMTP_PASS SMTP_STARTTLS EMAIL_FROM; do
    [[ -n "${!key:-}" ]] || continue
    set_env_key "${key}" "${!key}"
  done
  set_env_key ENABLE_EMAIL_INVITES true
  echo "Set in .env (values not shown): SMTP_SERVER SMTP_PORT SMTP_USER SMTP_PASS SMTP_STARTTLS EMAIL_FROM, and ENABLE_EMAIL_INVITES=true."
  section "docker compose up -d: api_server and background read the new values"
  live_compose up -d
  set_live_url
  wait_health "${LIVE_URL}"
}

# Sets one key in .env (the live one, or <env file>): replaces the line, also a commented
# one, or appends it. The value goes through the environment, so quotes, & and | are safe.
set_env_key() {
  ENV_KEY="$1" ENV_VALUE="$2" python3 - "${3:-${COMPOSE_DIR}/.env}" <<'PY'
import os, re, sys
path, key, value = sys.argv[1], os.environ["ENV_KEY"], os.environ["ENV_VALUE"]
if any(c in value for c in " #$'\"\\"):
    value = "'" + value + "'" if "'" not in value else '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'
lines = open(path).read().splitlines()
pattern = re.compile(rf"^#? ?{re.escape(key)}=")
for i, line in enumerate(lines):
    if pattern.match(line):
        lines[i] = f"{key}={value}"
        break
else:
    lines.append(f"{key}={value}")
with open(path, "w") as handle:
    handle.write("\n".join(lines) + "\n")
PY
}


assistant_prompt_wrapper() {
  local sha="${1:-}" mode="${2:-show}"
  check_sha "${sha}"
  [[ "${mode}" =~ ^(set|reset|show)$ ]] || die "The second argument must be set, reset or show."
  with_evidence assistant-prompt assistant_prompt "${sha}" "${mode}"
}

# Sets, resets or shows the prompt of the default assistant through the admin API.
assistant_prompt() {
  local sha="$1" mode="$2"
  section "vm-bootstrap assistant-prompt ${mode} ${sha} $(date -u +%FT%TZ)"
  docker_setup
  live_action_start "${sha}"
  python3 "${ONYX_SRC_DIR}/product/deploy/default_assistant.py" --base-url "${LIVE_URL}" "${mode}"
}

chat_check_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence chat-check chat_check "${sha}"
}

# Repeats the chat steps of verify on the live stack with the state of the last verify.
# It stops nothing and touches no volume.
chat_check() {
  local sha="$1" state step
  section "vm-bootstrap chat-check ${sha} $(date -u +%FT%TZ)"
  docker_setup
  live_action_start "${sha}"
  state="$(find "${EVIDENCE_ROOT}" -mindepth 2 -maxdepth 2 -name state.json | sort | tail -n 1)"
  [[ -n "${state}" ]] || die "No state.json in ${EVIDENCE_ROOT}. Run the verify action first."
  echo "State of the last verify: ${state}"
  cp "${state}" "${EVIDENCE_DIR}/state.json"
  export USER_A_EMAIL USER_A_PASSWORD USER_B_EMAIL USER_B_PASSWORD
  for step in chat chat-forced; do
    run_step "${step}" python3 "${ONYX_SRC_DIR}/product/test-corpus/run_checks.py" \
      --base-url "${LIVE_URL}" --state "${EVIDENCE_DIR}/state.json" "${step}"
  done
  summary
}

# ---------------------------------------------------------------- sealed secrets

# Creates the inbox key once and prints its public half. A secret encrypted to it can travel
# through a public workflow input: only this VM can decrypt it.
inbox_keygen() {
  local key="${SECRETS_DIR}/inbox.pem"
  section "vm-bootstrap keygen $(date -u +%FT%TZ)"
  install -d -m 700 "${SECRETS_DIR}"
  if [[ ! -f "${key}" ]]; then
    (umask 077 && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "${key}" 2>/dev/null)
    echo "Created ${key} (mode 600)."
  fi
  echo "Public key (encrypt with RSA-OAEP, SHA-256, then base64):"
  openssl pkey -in "${key}" -pubout
}

# Decrypts model.sealed (base64 of RSA-OAEP SHA-256) into model.env, then removes it.
unseal_model_key() {
  local key="${SECRETS_DIR}/inbox.pem" plain
  [[ -f "${key}" ]] || die "${key} is missing. Run the keygen action first."
  plain="$(base64 -d "${SECRETS_DIR}/model.sealed" |
    openssl pkeyutl -decrypt -inkey "${key}" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256)" ||
    die "The sealed model key does not decrypt with ${key}."
  [[ "${plain}" =~ ^[A-Za-z0-9._-]+$ ]] || die "The decrypted model key has unexpected characters."
  (umask 077 && printf 'MODEL_API_KEY=%q\nMODEL_API_BASE=\n' "${plain}" >"${SECRETS_DIR}/model.env")
  rm -f "${SECRETS_DIR}/model.sealed"
  echo "Unsealed the model key into ${SECRETS_DIR}/model.env (value not shown)."
}


# ---------------------------------------------------------------- multi-tenant validation stack

# A second, isolated stack with MULTI_TENANT=true, for validation only. Project onyx-mt has its
# own containers, network and volumes; nginx listens only on 127.0.0.1:3200. It never reads or
# changes the live .env or the volumes of project onyx. See product/deploy/mt/README.md.
readonly MT_DIR="${SRV_ROOT}/onyx-mt"
readonly MT_COMPOSE_DIR="${MT_DIR}/deployment/docker_compose"
readonly MT_PROJECT=onyx-mt
readonly MT_URL=http://127.0.0.1:3200
readonly MT_WEB_DOMAIN=http://localhost:3200
# compose.saas.yml holds the application settings, compose.mt.yml the test-stack specifics.
readonly MT_COMPOSE_FILES=(docker-compose.yml compose.override.yml compose.saas.yml compose.mt.yml)
readonly MT_TAG_FILE="${MT_DIR}/mt-tag"
readonly MT_SALT_FILE="${MT_DIR}/mt-salt"
readonly MT_STATE_FILE="${MT_DIR}/mt_state.json"
# MemAvailable that mt-up needs before it starts the stack: 6 GiB, in kB.
readonly MT_MIN_AVAILABLE_KB=$((6 * 1024 * 1024))

# Stops the script if the project name could address the live project.
mt_project_guard() {
  [[ "${MT_PROJECT}" == onyx-mt ]] || die "The multi-tenant project name must be onyx-mt, not ${MT_PROJECT}."
}

# ----- helpers shared by the multi-tenant stacks (test: onyx-mt, production: onyx-saas)

# Runs docker compose for <project> in <dir> with the -f files of <list> (colon separated).
# The -f options are explicit, because sudo drops a COMPOSE_FILE value from the shell.
stack_compose() {
  local project="$1" dir="$2" list="$3" file
  shift 3
  local -a files=()
  while IFS= read -r -d: file; do
    files+=(-f "${file}")
  done < <(printf '%s:' "${list}")
  (cd "${dir}" && dk compose -p "${project}" "${files[@]}" "$@")
}

# Joins the arguments with colons, for stack_compose and COMPOSE_FILE.
join_colon() {
  local IFS=:
  echo "$*"
}

# True when every file of the list, and .env, exists in <dir>.
stack_files_present() {
  local dir="$1" file
  shift
  for file in "$@" .env; do
    [[ -f "${dir}/${file}" ]] || return 1
  done
}

# All containers of a project, also stopped ones.
stack_containers() {
  dk ps -aq --filter "label=com.docker.compose.project=$1"
}

# Running containers of a project.
stack_running() {
  dk ps -q --filter "label=com.docker.compose.project=$1"
}

# Sets one key in <env file> (same method as make-env.sh). Plain values only.
stack_env_pin() {
  local env_file="$1" key="$2" value="$3"
  if grep -qE "^#? ?${key}=" "${env_file}"; then
    sed -i -E "s|^#? ?${key}=.*|${key}=${value}|" "${env_file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${env_file}"
  fi
}

# Prints the last value of a key in <env file>, without outer quotes.
stack_env_value() {
  sed -n -E "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1 |
    sed -E -e 's/[[:space:]]+$//' -e "s/^[\"'](.*)[\"']$/\1/"
}

# Settings that the multi-tenant mode needs in <env file>. No value is printed.
stack_env_settings() {
  local env_file="$1"
  # DEV_MODE lets an empty USER_AUTH_SECRET pass (onyx/auth/users.py:235). Never start so.
  [[ -n "$(stack_env_value "${env_file}" USER_AUTH_SECRET)" ]] ||
    die "USER_AUTH_SECRET is empty in ${env_file}. Set it with: openssl rand -hex 32"
  # The schema_private migration creates a read-only Postgres role. The code default of the
  # password is "password" (app_configs.py:2034-2036), so write a strong one once.
  [[ -n "$(stack_env_value "${env_file}" DB_READONLY_USER)" ]] ||
    stack_env_pin "${env_file}" DB_READONLY_USER db_readonly_user
  if [[ -z "$(stack_env_value "${env_file}" DB_READONLY_PASSWORD)" ]]; then
    stack_env_pin "${env_file}" DB_READONLY_PASSWORD "$(openssl rand -hex 24)"
    echo "Wrote DB_READONLY_PASSWORD into ${env_file} (value not shown)."
  fi
  # No tracking calls from our stacks.
  [[ -z "$(stack_env_value "${env_file}" HUBSPOT_TRACKING_URL)" ]] ||
    die "HUBSPOT_TRACKING_URL is set in ${env_file}. Remove it."
  echo "USER_AUTH_SECRET, DB_READONLY_USER and DB_READONLY_PASSWORD are set (values not shown)."
}

# Pins the project name and the compose file list in <env file>. A plain "docker compose"
# in that folder then addresses the right project, never onyx.
stack_env_pin_compose() {
  local env_file="$1" project="$2"
  shift 2
  stack_env_pin "${env_file}" COMPOSE_PROJECT_NAME "${project}"
  stack_env_pin "${env_file}" COMPOSE_FILE "$(join_colon "$@")"
  echo "Set COMPOSE_PROJECT_NAME and COMPOSE_FILE in ${env_file}."
}

# Creates the check tag and the password salt once. The salt is never printed.
# Prints the tag on the last line.
stack_ensure_check_secrets() {
  local tag_file="$1" salt_file="$2" prefix="$3" tag
  if [[ ! -s "${tag_file}" ]]; then
    echo "${prefix}-$(openssl rand -hex 4)" >"${tag_file}"
    echo "Created ${tag_file}."
  fi
  if [[ ! -s "${salt_file}" ]]; then
    (umask 077 && openssl rand -hex 32 >"${salt_file}")
    echo "Created ${salt_file} (mode 600, value not shown)."
  fi
  chmod 600 "${salt_file}"
  tag="$(cat "${tag_file}")"
  [[ "${tag}" =~ ^[a-z0-9][a-z0-9-]{0,23}$ ]] || die "${tag_file} does not hold a valid tag."
  echo "Tag: ${tag}"
}

# Runs mt_checks.py against <url>. Mode: empty or after-restart.
stack_run_checks() {
  local url="$1" tag_file="$2" salt_file="$3" state_file="$4" prefix="$5" mode="${6:-}"
  local checks="${ONYX_SRC_DIR}/product/test-corpus/mt_checks.py" tag
  [[ -f "${checks}" ]] || { echo "ERROR: ${checks} is missing at this commit." >&2; return 1; }
  stack_ensure_check_secrets "${tag_file}" "${salt_file}" "${prefix}"
  tag="$(cat "${tag_file}")"
  local -a args=(--base-url "${url}" --tag "${tag}" --state "${state_file}")
  [[ "${mode}" != after-restart ]] || args+=(--after-restart)
  MT_PASSWORD_SALT="$(cat "${salt_file}")" python3 "${checks}" "${args[@]}"
}

# ----- test stack (onyx-mt)

mt_compose() {
  mt_project_guard
  stack_compose "${MT_PROJECT}" "${MT_COMPOSE_DIR}" "$(join_colon "${MT_COMPOSE_FILES[@]}")" "$@"
}

mt_compose_files_present() {
  stack_files_present "${MT_COMPOSE_DIR}" "${MT_COMPOSE_FILES[@]}"
}

mt_containers() {
  stack_containers "${MT_PROJECT}"
}

mt_env_pin() {
  stack_env_pin "${MT_COMPOSE_DIR}/.env" "$@"
}

mt_env_value() {
  stack_env_value "${MT_COMPOSE_DIR}/.env" "$1"
}

# Refuses to start when the VM has less than MT_MIN_AVAILABLE_KB free for a new stack.
mt_memory_gate() {
  local available
  section "memory before start"
  free -m
  available="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
  [[ "${available}" =~ ^[0-9]+$ ]] || die "MemAvailable is not in /proc/meminfo."
  echo "MemAvailable: $((available / 1024)) MiB. mt-up needs $((MT_MIN_AVAILABLE_KB / 1024)) MiB."
  if [[ -n "$(stack_running "${MT_PROJECT}")" ]]; then
    echo "Project ${MT_PROJECT} runs already, so its memory is in use. The check does not apply."
    return 0
  fi
  ((available >= MT_MIN_AVAILABLE_KB)) ||
    die "Only $((available / 1024)) MiB of memory is available. The multi-tenant stack needs about 6 GiB next to the live stack. Nothing was started."
}

# Creates the folder, exports the release files and the overlays, and writes .env once.
mt_prepare() {
  local sha="$1"
  section "multi-tenant folder ${MT_DIR}"
  if [[ ! -d "${MT_DIR}" ]]; then
    sudo -n install -d -o "$(id -un)" -g "$(id -gn)" "${MT_DIR}" ||
      die "sudo -n cannot create ${MT_DIR}."
  fi
  checkout_source "${sha}" || die "The checkout of ${sha} failed."
  export_release_files "${MT_COMPOSE_DIR}" "${sha}" || die "The export of the release files failed."
  export_overlay "${sha}" product/deploy/mt/compose.saas.yml "${MT_COMPOSE_DIR}" || die "The export of compose.saas.yml failed."
  export_overlay "${sha}" product/deploy/mt/compose.mt.yml "${MT_COMPOSE_DIR}" || die "The export of compose.mt.yml failed."
  if [[ -f "${MT_COMPOSE_DIR}/.env" ]]; then
    echo "${MT_COMPOSE_DIR}/.env exists. The script keeps it."
  else
    # New secrets. The live .env is never copied.
    "${ONYX_SRC_DIR}/product/deploy/make-env.sh" "${MT_COMPOSE_DIR}" "${MT_WEB_DOMAIN}"
  fi
  if [[ -f "${COMPOSE_DIR}/.env" ]] && cmp -s "${COMPOSE_DIR}/.env" "${MT_COMPOSE_DIR}/.env"; then
    die "${MT_COMPOSE_DIR}/.env is a copy of the live .env. Remove it; mt-up then writes new secrets."
  fi
  stack_env_pin_compose "${MT_COMPOSE_DIR}/.env" "${MT_PROJECT}" "${MT_COMPOSE_FILES[@]}"
  stack_env_settings "${MT_COMPOSE_DIR}/.env"
}

mt_report() {
  show "docker compose ps (${MT_PROJECT})" mt_compose ps
  show "docker stats" dk stats --no-stream
  show "memory" free -m
}

mt_up_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence mt-up mt_up "${sha}"
}

mt_up() {
  local sha="$1"
  section "vm-bootstrap mt-up ${sha} $(date -u +%FT%TZ)"
  docker_setup
  mt_memory_gate
  mt_prepare "${sha}"
  section "docker compose -p ${MT_PROJECT} pull"
  mt_compose pull --quiet
  section "docker compose -p ${MT_PROJECT} up -d"
  mt_compose up -d
  wait_health "${MT_URL}"
  show "file store bucket job" mt_compose logs --no-log-prefix mt_minio_bucket
  mt_report
  section "mt-up complete: ${sha} with $(release_value ONYX_RELEASE_TAG) at ${MT_URL}"
}

# Runs mt_checks.py against the test stack. Mode: empty or after-restart.
mt_run_checks() {
  stack_run_checks "${MT_URL}" "${MT_TAG_FILE}" "${MT_SALT_FILE}" "${MT_STATE_FILE}" mt "${1:-}"
}

mt_check_wrapper() {
  local sha="${1:-}" mode="${2:-}"
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == after-restart ]] || die "The second argument must be after-restart or empty."
  with_evidence mt-check mt_check "${sha}" "${mode}"
}

mt_check() {
  local sha="$1" mode="$2"
  section "vm-bootstrap mt-check ${sha} $(date -u +%FT%TZ) (mode=${mode:-first})"
  [[ -f "${MT_COMPOSE_DIR}/.env" ]] || die "${MT_COMPOSE_DIR}/.env is missing. Run the mt-up action first."
  wait_health "${MT_URL}" 60 || die "The multi-tenant stack is not healthy. Run the mt-up action first."
  checkout_source "${sha}"
  mt_run_checks "${mode}"
}

mt_restart_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence mt-restart mt_restart "${sha}"
}

# Recreates the multi-tenant containers and repeats the read checks. "down" never gets -v.
mt_restart() {
  local sha="$1" volumes_before volumes_after
  section "vm-bootstrap mt-restart ${sha} $(date -u +%FT%TZ)"
  docker_setup
  mt_compose_files_present || die "The files in ${MT_COMPOSE_DIR} are missing. Run the mt-up action first."
  [[ -f "${MT_STATE_FILE}" ]] || die "${MT_STATE_FILE} is missing. Run the mt-check action first."
  wait_health "${MT_URL}" 60 || die "The multi-tenant stack is not healthy before the restart."
  checkout_source "${sha}"

  volumes_before="$(dk volume ls -q --filter "label=com.docker.compose.project=${MT_PROJECT}" | sort)"
  show "containers before" mt_compose ps --format '{{.Name}} {{.ID}} {{.Status}}'
  run_step down mt_compose down
  run_step up mt_compose up -d
  run_step health wait_health "${MT_URL}"
  show "containers after" mt_compose ps --format '{{.Name}} {{.ID}} {{.Status}}'
  volumes_after="$(dk volume ls -q --filter "label=com.docker.compose.project=${MT_PROJECT}" | sort)"
  echo "volumes: ${volumes_after//$'\n'/ }"
  run_step volumes-kept test -n "${volumes_after}" -a "${volumes_before}" = "${volumes_after}"
  run_step mt-check-after-restart mt_run_checks after-restart
  mt_report
  summary
}

mt_down_wrapper() {
  [[ $# -eq 0 ]] || die "mt-down takes no arguments."
  with_evidence mt-down mt_down
}

# Stops and removes the containers. The volumes stay for inspection; mt-destroy removes them.
mt_down() {
  section "vm-bootstrap mt-down $(date -u +%FT%TZ)"
  docker_setup
  if mt_compose_files_present; then
    mt_compose down
  elif [[ -n "$(mt_containers)" ]]; then
    die "Project ${MT_PROJECT} has containers, but the files in ${MT_COMPOSE_DIR} are missing. Run mt-up or mt-destroy."
  else
    echo "Project ${MT_PROJECT} has no containers."
  fi
  show "volumes kept (${MT_PROJECT})" dk volume ls --filter "label=com.docker.compose.project=${MT_PROJECT}"
  show "memory" free -m
}

mt_destroy_wrapper() {
  [[ $# -eq 0 ]] || die "mt-destroy takes no arguments."
  with_evidence mt-destroy mt_destroy
}

# Removes the containers, the network and the volumes of project onyx-mt, and its check state.
# .env, the tag and the salt stay, so a new mt-up uses the same secrets.
mt_destroy() {
  local containers volumes volume
  section "vm-bootstrap mt-destroy $(date -u +%FT%TZ)"
  mt_project_guard
  docker_setup
  if mt_compose_files_present; then
    mt_compose down
  fi
  containers="$(mt_containers)"
  [[ -z "${containers}" ]] || xargs -r "${DOCKER_CMD[@]}" rm -f <<<"${containers}" >/dev/null
  volumes="$(dk volume ls -q --filter "label=com.docker.compose.project=${MT_PROJECT}")"
  # The label filter is exact. The name check is a second guard for the live volumes.
  while IFS= read -r volume; do
    [[ -z "${volume}" || "${volume}" == "${MT_PROJECT}_"* ]] ||
      die "Volume ${volume} has the label of ${MT_PROJECT} but not its name prefix. Nothing more is removed."
  done <<<"${volumes}"
  [[ -z "${volumes}" ]] || xargs -r "${DOCKER_CMD[@]}" volume rm <<<"${volumes}" >/dev/null
  dk network rm "${MT_PROJECT}_default" >/dev/null 2>&1 || true
  rm -f "${MT_STATE_FILE}"
  echo "Project ${MT_PROJECT} has no containers and no volumes. Removed ${MT_STATE_FILE}."
  show "volumes left (${MT_PROJECT})" dk volume ls --filter "label=com.docker.compose.project=${MT_PROJECT}"
}

# ---------------------------------------------------------------- multi-tenant production stack

# The production multi-tenant stack (project onyx-saas) takes the public URL over from the
# live single-tenant project onyx. cutover makes a cold backup, stops onyx (never down -v)
# and starts onyx-saas with the same certificate. rollback starts onyx again. The volumes of
# both projects stay. See docs/product/MULTI-TENANT.md, section 6.
readonly SAAS_DIR="${SRV_ROOT}/onyx-saas"
readonly SAAS_PROJECT=onyx-saas
readonly SAAS_COMPOSE_DIR="${SAAS_DIR}/deployment/docker_compose"
# compose.tools.yml adds the code interpreter behind its gateway and SearXNG.
# compose.https.yml comes last: its nginx ports, command and volumes win.
readonly SAAS_COMPOSE_FILES=(docker-compose.yml compose.override.yml compose.saas.yml compose.tools.yml compose.https.yml)
# The configs that compose.tools.yml mounts, in <compose dir>/tools/ (product/deploy/tools/).
readonly SAAS_TOOLS_FILES=(ci-gateway.conf searxng-settings.yml)
# The services of compose.tools.yml. saas-restore-test stops them for the test.
readonly SAAS_TOOL_SERVICES=(code-interpreter ci-gateway searxng)
# saas-update keeps the last 5 snapshots of .env and the compose files here.
readonly SAAS_ROLLBACK_DIR="${SAAS_DIR}/rollback"
readonly SAAS_ROLLBACK_KEEP=5
# What runs: the deployed SHA, the release and the image refs (no secrets).
readonly SAAS_DEPLOYED_FILE="${SAAS_DIR}/deployed.env"
# Which project serves the public URL: onyx-saas (cutover, saas-update) or onyx (rollback).
readonly ACTIVE_STACK_FILE="${ONYX_DEPLOY_DIR}/active-stack"
# ci-host-setup writes the executor daemon marker: DOCKER_SOCK_PATH, EXECUTOR_MODE, EXECUTOR_UID.
readonly CI_MARKER_FILE="${ONYX_DEPLOY_DIR}/ci-executor.env"
readonly CI_SANDBOX_USER=ci-sandbox
readonly CI_CLEANUP_BIN="${ONYX_DEPLOY_DIR}/bin/ci-cleanup.sh"
# The global cap of all executor containers (the user slice of ci-sandbox, or code-exec.slice).
readonly CI_CAP=(MemoryMax=3G CPUQuota=200% TasksMax=2048)
# The default of PYTHON_EXECUTOR_DOCKER_RUN_ARGS in compose.tools.yml; keep both equal.
readonly CI_EXECUTOR_RUN_ARGS_DEFAULT="--cpus=1 --ulimit nofile=256:256 --env OMP_NUM_THREADS=1 --env OPENBLAS_NUM_THREADS=1 --env MKL_NUM_THREADS=1"
readonly CI_CGROUP_PARENT_ARG="--cgroup-parent=code-exec.slice"
# sha256 (hex, one per line) of every platform key that saas_model_defaults replaced.
readonly KEY_FINGERPRINTS_FILE="${SECRETS_DIR}/platform-key-fingerprints"
readonly VM_LOCK_FILE="${ONYX_DEPLOY_DIR}/.vm-ops.lock"
# saas-backup: the newest *-saas backups that stay in BACKUP_ROOT.
readonly SAAS_BACKUP_KEEP=7
# saas-restore-test: the copy of the production stack.
readonly SAAS_RESTORE_DIR="${SRV_ROOT}/onyx-saas-restore"
readonly SAAS_RESTORE_COMPOSE_DIR="${SAAS_RESTORE_DIR}/deployment/docker_compose"
readonly SAAS_RESTORE_PROJECT=onyx-saas-restore
readonly SAAS_RESTORE_URL=http://127.0.0.1:3300
readonly SAAS_RESTORE_PORT=3300
readonly SAAS_RESTORE_FILES=(docker-compose.yml compose.override.yml compose.saas.yml compose.restore.yml)
# MemAvailable that the restore copy needs after the tool services stop: 5 GiB, in kB.
readonly SAAS_RESTORE_MIN_AVAILABLE_KB=$((5 * 1024 * 1024))
# Free disk space that saas-backup and saas-restore-test need at least: 5 GiB, in kB.
readonly SAAS_MIN_FREE_KB=$((5 * 1024 * 1024))
readonly SAAS_URL="https://${DNS_NAME}"
readonly SAAS_TAG_FILE="${SAAS_DIR}/saas-tag"
readonly SAAS_SALT_FILE="${SAAS_DIR}/saas-salt"
readonly SAAS_STATE_FILE="${SAAS_DIR}/mt_state.json"
# saas-journey: the customer-journey test (saas_journey.py).
readonly SAAS_JOURNEY_TAG_FILE="${SAAS_DIR}/journey-tag"
readonly SAAS_JOURNEY_SALT_FILE="${SAAS_DIR}/journey-salt"
readonly SAAS_JOURNEY_STATE_FILE="${SAAS_DIR}/journey_state.json"
# The live rows of the accounts that cutover moves (mode 600, holds password hashes).
readonly SAAS_TRANSFER_FILE="${SAAS_DIR}/account-transfer.json"
readonly LIVE_DATA_DIR="${ONYX_DEPLOY_DIR}/deployment/data"
readonly SAAS_DATA_DIR="${SAAS_DIR}/deployment/data"
# 1 while cutover has the live stack stopped and onyx-saas is not yet healthy.
CUTOVER_LIVE_STOPPED=0

saas_project_guard() {
  [[ "${SAAS_PROJECT}" == onyx-saas ]] || die "The production multi-tenant project name must be onyx-saas, not ${SAAS_PROJECT}."
}

saas_compose() {
  saas_project_guard
  stack_compose "${SAAS_PROJECT}" "${SAAS_COMPOSE_DIR}" "$(join_colon "${SAAS_COMPOSE_FILES[@]}")" "$@"
}

saas_compose_files_present() {
  stack_files_present "${SAAS_COMPOSE_DIR}" "${SAAS_COMPOSE_FILES[@]}"
}

# Runs mt_checks.py against the production stack. Mode: empty or after-restart. It configures
# no model here: the platform image supplies it (saas-journey checks that). mt_checks.py
# configures a model only when MODEL_API_KEY is in its environment, as on the mt stack.
saas_run_checks() {
  stack_run_checks "${SAAS_URL}" "${SAAS_TAG_FILE}" "${SAAS_SALT_FILE}" "${SAAS_STATE_FILE}" saas "${1:-}"
}

# Runs one psql script from stdin in the onyx-saas database. Values reach psql only through
# the script (\set lines), never through the command line.
saas_psql() {
  local env_file="${SAAS_COMPOSE_DIR}/.env" user db
  user="$(stack_env_value "${env_file}" POSTGRES_USER)"
  db="$(stack_env_value "${env_file}" POSTGRES_DB)"
  saas_compose exec -T relational_db psql -U "${user:-postgres}" -d "${db:-postgres}" \
    -v ON_ERROR_STOP=1 -qAt -f -
}

# Prints the result of one SQL statement in the onyx-saas database.
saas_sql_value() {
  saas_psql <<<"$1"
}

# Deletes the per-IP sign-up counters (SIGNUP_RATE_LIMIT_ENABLED, 5 sign-ups per hour) before
# the sign-ups of this script. The counters live in Redis only.
saas_reset_signup_limit() {
  if saas_compose exec -T cache sh -c \
    "redis-cli --scan --pattern 'signup_rate:*' | xargs -r redis-cli del >/dev/null"; then
    echo "Reset the per-IP sign-up counters (signup_rate:*)."
  else
    echo "WARNING: could not reset the sign-up counters. Sign-ups can get 429." >&2
  fi
}

# Applies the platform defaults (model, knowledge rules) to every tenant that lacks them.
# onyx.axi.backfill comes with ONYX_BACKEND_IMAGE_CLOUD. It never overwrites a company setting.
saas_backfill() {
  local -a args=()
  [[ "${1:-}" != dry-run ]] || args=(--dry-run)
  section "platform defaults for every tenant (onyx.axi.backfill ${args[*]})"
  saas_key_presence
  saas_compose exec -T api_server python -m onyx.axi.backfill "${args[@]}"
}

# Says where the platform key is present: the saas .env, the resolved compose config and
# the running containers. Prints present or missing only, never a value.
saas_key_presence() {
  local env_file="${SAAS_COMPOSE_DIR}/.env" service state
  if grep -qE '^FIREWORKS_DEFAULT_API_KEY=.+' "${env_file}"; then state=present; else state=missing; fi
  echo "platform key in ${env_file}: ${state}"
  for service in api_server background; do
    state="$(saas_compose config --format json 2>/dev/null | python3 -c '
import json, sys
env = json.load(sys.stdin)["services"][sys.argv[1]].get("environment") or {}
print("present" if env.get("FIREWORKS_DEFAULT_API_KEY") else "missing")
' "${service}" || echo unknown)"
    echo "platform key in the compose config of ${service}: ${state}"
    # shellcheck disable=SC2016
    state="$(saas_compose exec -T "${service}" sh -c '[ -n "${FIREWORKS_DEFAULT_API_KEY:-}" ] && echo present || echo missing' 2>/dev/null || echo unknown)"
    echo "platform key in the running ${service} container: ${state}"
  done
}

# The volumes of both projects. The live volumes (onyx_*) must always be in the list.
list_stack_volumes() {
  dk volume ls --filter label=com.docker.compose.project=onyx
  dk volume ls --filter "label=com.docker.compose.project=${SAAS_PROJECT}" --format '{{.Name}}'
}

saas_report() {
  show "docker compose ps (${SAAS_PROJECT})" saas_compose ps
  show "docker compose images (${SAAS_PROJECT})" saas_compose images
  show "volumes of onyx and ${SAAS_PROJECT}" list_stack_volumes
  show "memory" free -m
}

# ----- inventory

inventory_wrapper() {
  local sha="${1:-}" owner="${2:-}"
  check_sha "${sha}"
  [[ -z "${owner}" ]] || is_plain_email "${owner}" || die "The owner email is not a plain address."
  with_evidence inventory inventory_live "${sha}" "${owner}"
}

# Runs one SQL statement in the live Postgres and prints the rows. Errors are silent.
live_sql() {
  live_compose exec -T relational_db psql -U "$(live_env_value POSTGRES_USER postgres)" \
    -d "$(live_env_value POSTGRES_DB postgres)" -v ON_ERROR_STOP=1 -At -c "$1" 2>/dev/null
}

# Like live_sql, with tab-separated fields and visible errors. For rows that go to a pipe.
live_sql_tsv() {
  live_compose exec -T relational_db psql -U "$(live_env_value POSTGRES_USER postgres)" \
    -d "$(live_env_value POSTGRES_DB postgres)" -v ON_ERROR_STOP=1 -qAt -F $'\t' -c "$1"
}

# Prints "<label>: <value>" or "<label>: query failed". One failed query stops nothing.
live_count() {
  local label="$1" sql="$2" value
  value="$(live_sql "${sql}")" || { echo "${label}: query failed"; return 0; }
  echo "${label}: ${value}"
}

# Prints the value of <key> in a JSON file, the length when it is a list, or "?".
# Key "-" means the whole document.
json_value() {
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    if sys.argv[2] != "-":
        data = data[sys.argv[2]]
    print(len(data) if isinstance(data, list) else data)
except Exception:
    print("?")
' "$1" "$2"
}

# SQL expression: the category of a "user" row. <owner> must pass is_plain_email (or be empty).
# v4.8.4 keeps API keys and bots as rows with account_type other than STANDARD; API key rows
# also have an address that ends in onyxapikey.ai (onyx/db/api_key.py).
account_category_sql() {
  local owner="$1"
  echo "CASE WHEN lower(email) = lower('${owner}') THEN 'owner'" \
    "WHEN lower(email) LIKE '%@example.com' THEN 'synthetic'" \
    "WHEN account_type <> 'STANDARD' OR lower(email) LIKE '%onyxapikey.ai'" \
    "OR lower(email) IN ('anonymous@onyx.app', 'no-auth-placeholder@onyx.app') THEN 'service'" \
    "ELSE 'other' END"
}

# Admin in v4.8.4 is the permission "admin" in effective_permissions (membership of the Admin
# group, onyx/db/users.py user_is_admin). The column "role" is a tombstone.
readonly ADMIN_SQL="effective_permissions @> '[\"admin\"]'::jsonb"

# Per category: users, active users, admins, chat sessions, user files. Prints "query failed"
# lines on error. Without effective_permissions the admin count is "unknown".
inventory_accounts() {
  local owner="$1" category sql rows admin="${ADMIN_SQL}"
  category="$(account_category_sql "${owner}")"
  sql="WITH u AS (SELECT id, ${category} AS c, is_active, @ADMIN@ AS adm FROM \"user\"),
s AS (SELECT user_id, count(*) AS n FROM chat_session GROUP BY user_id),
f AS (SELECT user_id, count(*) AS n FROM user_file GROUP BY user_id)
SELECT u.c, count(*), count(*) FILTER (WHERE u.is_active),
  count(*) FILTER (WHERE u.adm),
  coalesce(sum(s.n), 0), coalesce(sum(f.n), 0)
FROM u LEFT JOIN s ON s.user_id = u.id LEFT JOIN f ON f.user_id = u.id GROUP BY u.c ORDER BY u.c"
  rows="$(live_sql "${sql//@ADMIN@/${admin}}")" || {
    admin="NULL::boolean"
    rows="$(live_sql "${sql//@ADMIN@/${admin}}")" || { echo "accounts by category: query failed"; return 0; }
  }
  [[ "${admin}" == "${ADMIN_SQL}" ]] || echo "(no effective_permissions column: admin unknown)"
  printf '%-10s %6s %6s %7s %13s %10s\n' category users active admins chat_sessions user_files
  local c users active admins chats files
  while IFS='|' read -r c users active admins chats files; do
    [[ -n "${c}" ]] || continue
    # A NULL admin flag counts as 0 in FILTER; show "unknown" when the column is missing.
    [[ "${admin}" == "${ADMIN_SQL}" ]] || admins=unknown
    printf '%-10s %6s %6s %7s %13s %10s\n' "${c}" "${users}" "${active}" "${admins}" "${chats}" "${files}"
  done <<<"${rows}"
  if [[ -z "${owner}" ]]; then
    echo "owner: no owner email given"
  elif grep -q '^owner|' <<<"${rows}"; then
    if [[ "${admin}" != "${ADMIN_SQL}" ]]; then
      echo "owner ${owner}: present, admin unknown"
    elif grep -q '^owner|[0-9]*|[0-9]*|1|' <<<"${rows}"; then
      echo "owner ${owner}: present, admin yes"
    else
      echo "owner ${owner}: present, admin no"
    fi
  else
    echo "owner ${owner}: not present"
  fi
  echo "Categories: owner = the owner email; synthetic = @example.com test accounts;"
  echo "service = API keys, bots and placeholders; other = other real accounts (count only)."
}

# Read-only inventory of the live single-tenant stack before the cutover. The log shows
# counts only. The emails and connector names go to inventory.txt (mode 600) in the evidence folder.
inventory_live() {
  local sha="$1" owner="$2" report="${EVIDENCE_DIR}/inventory.txt" users_total
  section "vm-bootstrap inventory ${sha} $(date -u +%FT%TZ)"
  docker_setup
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. Run the install action first."
  set_live_url
  wait_health "${LIVE_URL}" 60 || die "The live stack is not healthy."
  checkout_source "${sha}"

  section "database counts (project onyx)"
  users_total="$(live_sql 'SELECT count(*) FROM "user"' || echo '?')"
  echo "users: ${users_total}"
  live_count "active users" 'SELECT count(*) FROM "user" WHERE is_active'
  live_count "admins (permission admin)" "SELECT count(*) FROM \"user\" WHERE ${ADMIN_SQL}"
  echo "connectors by source:"
  live_sql "SELECT '  ' || source || ': ' || count(*) FROM connector GROUP BY source ORDER BY source" ||
    echo "  query failed"
  live_count "connector_credential_pair" 'SELECT count(*) FROM connector_credential_pair'
  live_count "document" 'SELECT count(*) FROM document'
  live_count "chat_session" 'SELECT count(*) FROM chat_session'
  live_count "chat_message" 'SELECT count(*) FROM chat_message'
  live_count "user_file" 'SELECT count(*) FROM user_file'
  live_count "persona (not builtin_persona)" 'SELECT count(*) FROM persona WHERE NOT builtin_persona'
  live_count "persona (not is_default_persona)" 'SELECT count(*) FROM persona WHERE NOT is_default_persona'
  live_count "llm_provider" 'SELECT count(*) FROM llm_provider'
  live_count "document_set" 'SELECT count(*) FROM document_set'
  live_count "user_group (EE table)" 'SELECT count(*) FROM user_group'

  section "accounts by category"
  inventory_accounts "${owner}"

  section "account transfer plan (dry run, nothing is written)"
  if [[ -z "${owner}" ]]; then
    echo "No owner email given: no transfer plan."
  else
    transfer_collect "${owner}" dry-run || echo "transfer plan: blocked (see above)"
  fi

  section "detailed report"
  install -m 600 /dev/null "${report}"
  {
    echo "# inventory of the live stack, ${sha}, $(date -u +%FT%TZ)"
    echo "## users (email, category, account_type, is_active, admin)"
    live_sql "SELECT email, $(account_category_sql "${owner}"), account_type, is_active, ${ADMIN_SQL} FROM \"user\" ORDER BY email" ||
      live_sql 'SELECT email, is_active FROM "user" ORDER BY email' || echo "query failed"
    echo "## connectors (id, name, source)"
    live_sql 'SELECT id, name, source FROM connector ORDER BY id' || echo "query failed"
  } >>"${report}"
  echo "Written: ${report} (mode 600, holds the emails and connector names)."

  section "API counts"
  inventory_api || echo "API counts skipped (see above)."

  section "What the cutover does with the data"
  echo "- Accounts: the owner and the active other real accounts move with their password"
  echo "  hashes (see the plan above). The owner gets a new company with the platform model."
  echo "  Synthetic @example.com accounts and service accounts do not move."
  echo "- Connectors, documents, chats, assistants and files stay in the old volumes (project onyx)."
  echo "  They are not migrated. rollback makes them reachable again."
}

# Counts through the public API as the admin test user. Returns 1 when the login fails.
inventory_api() {
  local work_dir code
  [[ -f "${USERS_FILE}" ]] || { echo "${USERS_FILE} is missing: no API counts."; return 1; }
  work_dir="$(mktemp -d)"
  export TMPDIR="${work_dir}"
  # shellcheck disable=SC1090
  source "${USERS_FILE}"
  export ADMIN_EMAIL ADMIN_PASSWORD
  (admin_login "${LIVE_URL}" "${work_dir}/admin.jar") || { echo "admin login failed: no API counts."; return 1; }
  ADMIN_JAR="${work_dir}/admin.jar"
  # v4.8.4 has no GET /api/admin/settings. GET /api/settings carries the same fields.
  code="$(api GET /api/admin/settings "${work_dir}/settings.out")"
  [[ "${code}" == 200 ]] || code="$(api GET /api/settings "${work_dir}/settings.out")"
  if [[ "${code}" == 200 ]]; then
    echo "invite_only_enabled: $(json_value "${work_dir}/settings.out" invite_only_enabled)"
  else
    echo "settings: GET returned ${code}"
  fi
  code="$(api GET '/api/manage/users/accepted?page_num=0&page_size=1000' "${work_dir}/accepted.out")"
  if [[ "${code}" == 200 ]]; then
    echo "accepted users (API): $(json_value "${work_dir}/accepted.out" items)"
  else
    echo "accepted users: GET returned ${code}"
  fi
  code="$(api GET /api/manage/users/invited "${work_dir}/invited.out")"
  if [[ "${code}" == 200 ]]; then
    echo "invited users (API): $(json_value "${work_dir}/invited.out" -)"
  else
    echo "invited users: GET returned ${code}"
  fi
}

# ----- account transfer

# SQL: the live rows that cutover moves (owner and other real accounts), tab separated:
# email, hashed_password, is_active, is_verified, admin.
transfer_rows_sql() {
  echo "SELECT email, hashed_password, is_active, is_verified, ${ADMIN_SQL} FROM \"user\"" \
    "WHERE ($(account_category_sql "$1")) IN ('owner', 'other') ORDER BY email"
}

# Reads the transfer rows of the live database. Mode dry-run prints the plan only; mode write
# also writes SAAS_TRANSFER_FILE (mode 600). The hashes go only through the pipe and the file.
# Fails when the owner row is missing or the transfer cannot run.
transfer_collect() {
  local owner="$1" mode="$2" limit=5 env_file="${SAAS_COMPOSE_DIR}/.env"
  local tool="${ONYX_SRC_DIR}/product/deploy/transfer_accounts.py"
  local -a out=(--dry-run)
  [[ "${mode}" != write ]] || out=(--file "${SAAS_TRANSFER_FILE}")
  # saas_merge_secrets copies secrets/saas.env into the saas .env, so both can switch it off.
  local file
  for file in "${env_file}" "${SECRETS_DIR}/saas.env"; do
    if [[ -f "${file}" && "$(stack_env_value "${file}" SIGNUP_RATE_LIMIT_ENABLED)" == false ]]; then
      limit=0
    fi
  done
  live_sql_tsv "$(transfer_rows_sql "${owner}")" |
    python3 "${tool}" collect --owner "${owner}" --signup-limit "${limit}" "${out[@]}"
}

# Moves the accounts of SAAS_TRANSFER_FILE into onyx-saas, which must serve SAAS_URL:
# 1. Signs up the owner with a random one-time password (the native sign-up: new company,
#    owner admin, platform defaults), invites and signs up each other account with its own
#    one-time password, and grants admin access to the former admins (transfer_accounts.py).
# 2. Copies each old password hash into the owner's tenant schema in one transaction and
#    reads it back. The one-time passwords exist only inside step 1 and are discarded.
# An account that already has a company in onyx-saas (an earlier cutover) is not signed up
# again. Any failure stops the script; on_cutover_exit then starts the live stack again.
transfer_accounts() {
  local owner="$1" file="${SAAS_TRANSFER_FILE}" schema
  local tool="${ONYX_SRC_DIR}/product/deploy/transfer_accounts.py"
  section "account transfer into ${SAAS_PROJECT}"
  [[ -f "${file}" ]] || die "${file} is missing. The account transfer did not run."
  saas_reset_signup_limit
  python3 "${tool}" mapping-sql --file "${file}" | saas_psql | python3 "${tool}" mark --file "${file}" ||
    die "The account transfer could not read the onyx-saas mappings."
  python3 "${tool}" register --file "${file}" --base-url "${SAAS_URL}" ||
    die "The sign-up step of the account transfer failed."
  schema="$(saas_sql_value "SELECT tenant_id FROM public.user_tenant_mapping WHERE email = lower('${owner}') AND active")" ||
    die "The owner's company lookup failed."
  [[ "${schema}" =~ ^tenant_[0-9a-f-]+$ ]] || die "The owner has no active company in ${SAAS_PROJECT}."
  python3 "${tool}" copy-sql --file "${file}" --schema "${schema}" | saas_psql |
    python3 "${tool}" verify --file "${file}" --schema "${schema}" ||
    die "The password hash copy of the account transfer failed."
  echo "The one-time passwords are discarded. Each account logs in with its old password."
}

# ----- cutover

cutover_wrapper() {
  local sha="${1:-}" email="${2:-}" owner="${3:-}"
  check_sha "${sha}"
  is_email "${email}" || die "Give the Let's Encrypt account email (the one of the https action)."
  is_plain_email "${owner}" || die "Give the owner email (a plain address) as the third argument."
  with_evidence cutover cutover "${sha}" "${email}" "${owner}"
}

# Moves the public URL from project onyx to project onyx-saas. Order: checks, transfer plan,
# cold backup, saas folder and .env, certificate copy, pull, read the accounts, stop onyx,
# start onyx-saas, health checks, account transfer, platform defaults for every tenant.
# A failure after the stop stops onyx-saas and starts onyx again. onyx never gets "down";
# its volumes stay. $2 is the Let's Encrypt email. The wrapper validates it; the account
# itself travels inside certbot/conf. The log never shows it. $3 is the owner email.
cutover() {
  local sha="$1" owner="$3" backup_dir
  section "vm-bootstrap cutover ${sha} $(date -u +%FT%TZ)"
  docker info >/dev/null 2>&1 ||
    die "docker does not work without sudo. backup.sh needs it. Log in again after the install action."
  docker_setup
  saas_project_guard
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. Run the install action first."
  [[ -z "$(stack_running "${SAAS_PROJECT}")" ]] ||
    die "Project ${SAAS_PROJECT} has running containers. Run rollback or saas-down first, or use the saas-* actions."
  set_live_url
  [[ -n "${PUBLIC_URL}" ]] || die "The live .env has no compose.https.yml in COMPOSE_FILE. Run the https action first."
  wait_health "${LIVE_URL}" 60 || die "The live stack is not healthy. Nothing was changed."
  # certbot writes its files as root with mode 700, so the check needs sudo.
  sudo -n test -f "${LIVE_DATA_DIR}/certbot/conf/live/${DNS_NAME}/fullchain.pem" ||
    die "No certificate for ${DNS_NAME} in ${LIVE_DATA_DIR}/certbot/conf. Run the https action first."
  checkout_source "${sha}"
  saas_cloud_backend_image >/dev/null
  [[ -f "${SECRETS_DIR}/model.env" || -f "${SECRETS_DIR}/model.sealed" ]] ||
    die "${SECRETS_DIR}/model.env is missing. Run the model action first. Nothing was changed."
  section "account transfer plan"
  transfer_collect "${owner}" dry-run || die "The account transfer cannot run. Nothing was changed."

  backup_dir="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-pre-cutover"
  section "cold backup of the live stack into ${backup_dir}"
  "${ONYX_SRC_DIR}/product/deploy/backup.sh" "${COMPOSE_DIR}" "${backup_dir}" onyx
  verify_backup "${backup_dir}"
  wait_health "${LIVE_URL}" ||
    die "The live stack did not come back after the backup. Start it: cd ${COMPOSE_DIR} && docker compose start"

  saas_prepare "${sha}"
  saas_copy_https_files "${sha}"
  section "docker compose -p ${SAAS_PROJECT} pull"
  saas_compose pull --quiet

  section "account transfer: read the live accounts"
  transfer_collect "${owner}" write || die "The live accounts could not be read. Nothing was changed."

  section "stopping the live stack (project onyx, volumes stay)"
  trap 'on_cutover_exit' EXIT
  CUTOVER_LIVE_STOPPED=1
  live_compose stop
  section "docker compose -p ${SAAS_PROJECT} up -d"
  saas_compose up -d
  wait_health "${SAAS_URL}" || die "${SAAS_PROJECT} is not healthy at ${SAAS_URL}."
  PUBLIC_URL="${SAAS_URL}"
  check_public_url || die "The public URL checks failed on ${SAAS_PROJECT}."
  transfer_accounts "${owner}"
  saas_backfill || die "The platform defaults could not be applied to every tenant."
  CUTOVER_LIVE_STOPPED=0
  saas_write_deployed "${sha}" || echo "WARNING: ${SAAS_DEPLOYED_FILE} could not be written." >&2
  saas_write_active_stack "${SAAS_PROJECT}" || echo "WARNING: ${ACTIVE_STACK_FILE} could not be written." >&2
  show "file store bucket job" saas_compose logs --no-log-prefix mt_minio_bucket
  saas_report
  section "cutover complete: ${SAAS_PROJECT} serves ${SAAS_URL}"
  echo "Backup of the live stack: ${backup_dir}"
  echo "Rollback: workflow action rollback, or on the VM: vm-bootstrap.sh rollback ${sha}"
}

# After a failed start: stops onyx-saas and starts onyx again, so the old service is back.
on_cutover_exit() {
  local code=$?
  if ((CUTOVER_LIVE_STOPPED)); then
    echo "cutover failed (exit ${code}) while the live stack was stopped. Stopping ${SAAS_PROJECT} and starting onyx again." >&2
    echo "Accounts that the transfer created stay in the ${SAAS_PROJECT} volumes; the next cutover reuses them." >&2
    saas_compose stop || true
    live_compose start || true
    set_live_url
    if wait_health "${LIVE_URL}"; then
      echo "The live stack (project onyx) serves ${LIVE_URL} again. The cutover did not happen." >&2
    else
      echo "ERROR: the live stack is not healthy. Run the rollback action." >&2
    fi
  fi
}

# Checks the backup folder: SHA256SUMS exists and every checksum passes.
verify_backup() {
  local backup_dir="$1"
  [[ -f "${backup_dir}/SHA256SUMS" ]] || die "No SHA256SUMS in ${backup_dir}. Nothing more was changed."
  (cd "${backup_dir}" && sha256sum -c --quiet SHA256SUMS) ||
    die "The checksums in ${backup_dir} do not pass. Nothing more was changed."
  echo "Backup ${backup_dir}: SHA256SUMS passes."
  ls -la "${backup_dir}"
}

# Prints ONYX_BACKEND_IMAGE_CLOUD of release.env, or stops when it is empty.
saas_cloud_backend_image() {
  local image
  image="$(release_value ONYX_BACKEND_IMAGE_CLOUD)"
  [[ -n "${image}" ]] ||
    die "ONYX_BACKEND_IMAGE_CLOUD is empty in release.env. Run axi-build-backend.yml and pin its digest first: without that image new companies get no platform model, so the customer journey fails. Nothing was changed."
  echo "${image}"
}

# Copies the platform model from secrets/model.env into <env file> as FIREWORKS_DEFAULT_*.
# The cloud backend image reads them when it sets up a company. Key names only in the log.
saas_model_defaults() {
  local env_file="$1" file="${SECRETS_DIR}/model.env" key model provider base old_key
  if [[ -f "${SECRETS_DIR}/model.sealed" ]]; then
    unseal_model_key
  fi
  [[ -f "${file}" ]] ||
    die "${file} is missing. Run the model action first: every new company gets the platform model from it."
  # Read in this shell, not in a subshell: actions run inside "... || code=$?", where a
  # failing subshell does not stop the script.
  key="$(model_env_value "${file}" MODEL_API_KEY)"
  model="$(model_env_value "${file}" MODEL_NAME)"
  provider="$(model_env_value "${file}" MODEL_PROVIDER)"
  base="$(model_env_value "${file}" MODEL_API_BASE)"
  [[ -n "${key}" ]] || die "MODEL_API_KEY is empty in ${file}."
  if [[ -z "${model}" ]]; then
    # model.env of the model action before MODEL_NAME existed. The live stack runs this model.
    model="${DEFAULT_PLATFORM_MODEL}"
    echo "MODEL_NAME is not in ${file}; using ${model}."
  fi
  # A new key: keep the fingerprint (sha256) of the old one, so that saas-rotate-key finds
  # the company providers that still hold it. The log never shows a key.
  old_key="$(model_env_value "${env_file}" FIREWORKS_DEFAULT_API_KEY)"
  if [[ -n "${old_key}" && "${old_key}" != "${key}" ]]; then
    record_key_fingerprint "${old_key}" ||
      die "The fingerprint of the previous platform key could not be recorded in ${KEY_FINGERPRINTS_FILE}."
    PLATFORM_KEY_CHANGED=1
    echo "platform key changed: fingerprint of the previous key recorded"
  fi
  set_env_key FIREWORKS_DEFAULT_API_KEY "${key}" "${env_file}" || die "Could not write ${env_file}."
  set_env_key FIREWORKS_DEFAULT_MODEL "${model}" "${env_file}" || die "Could not write ${env_file}."
  set_env_key FIREWORKS_DEFAULT_PROVIDER "${provider:-fireworks_ai}" "${env_file}" || die "Could not write ${env_file}."
  set_env_key FIREWORKS_DEFAULT_API_BASE "${base}" "${env_file}" || die "Could not write ${env_file}."
  grep -qE '^FIREWORKS_DEFAULT_API_KEY=.+' "${env_file}" ||
    die "FIREWORKS_DEFAULT_API_KEY did not reach ${env_file}."
  echo "Set from ${file} (values not shown): FIREWORKS_DEFAULT_API_KEY FIREWORKS_DEFAULT_MODEL FIREWORKS_DEFAULT_PROVIDER FIREWORKS_DEFAULT_API_BASE"
}

# Prints one value of a KEY=value file (the format that the model action writes, %q quoting
# allowed) without sourcing the file into this shell.
model_env_value() {
  python3 - "$1" "$2" <<'PY'
import shlex, sys
path, wanted = sys.argv[1], sys.argv[2]
value = ""
for line in open(path):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, raw = line.split("=", 1)
    if key.strip() == wanted:
        parts = shlex.split(raw)
        value = parts[0] if parts else ""
print(value)
PY
}

# Creates the saas folder, exports the release files, the overlays and the tool configs, and
# writes .env once. Every run pins the domain, the release, the images, the compose files and
# profiles, the executor socket, the web search default and the platform model.
# secrets/saas.env comes last, so its keys win. It needs the marker of ci-host-setup.
saas_prepare() {
  local sha="$1" env_file="${SAAS_COMPOSE_DIR}/.env" cloud_image backend_image key sock mode
  section "production multi-tenant folder ${SAAS_DIR}"
  if [[ ! -d "${SAAS_DIR}" ]]; then
    sudo -n install -d -o "$(id -un)" -g "$(id -gn)" "${SAAS_DIR}" || die "sudo -n cannot create ${SAAS_DIR}."
  fi
  saas_require_marker
  sock="$(ci_marker_value DOCKER_SOCK_PATH)"
  mode="$(ci_marker_value EXECUTOR_MODE)"
  export_release_files "${SAAS_COMPOSE_DIR}" "${sha}" || die "The export of the release files failed."
  export_overlay "${sha}" product/deploy/mt/compose.saas.yml "${SAAS_COMPOSE_DIR}" || die "The export of compose.saas.yml failed."
  export_overlay "${sha}" product/deploy/mt/compose.tools.yml "${SAAS_COMPOSE_DIR}" || die "The export of compose.tools.yml failed."
  export_overlay "${sha}" product/deploy/compose.https.yml "${SAAS_COMPOSE_DIR}" || die "The export of compose.https.yml failed."
  for key in "${SAAS_TOOLS_FILES[@]}"; do
    export_overlay "${sha}" "product/deploy/tools/${key}" "${SAAS_COMPOSE_DIR}/tools" || die "The export of tools/${key} failed."
  done
  cloud_image="$(release_value ONYX_WEB_SERVER_IMAGE_CLOUD)"
  [[ -n "${cloud_image}" ]] || die "ONYX_WEB_SERVER_IMAGE_CLOUD is missing in release.env."
  backend_image="$(saas_cloud_backend_image)" || die "ONYX_BACKEND_IMAGE_CLOUD is missing in release.env."
  for key in ONYX_MODEL_SERVER_IMAGE CODE_INTERPRETER_IMAGE PYTHON_EXECUTOR_IMAGE CI_GATEWAY_IMAGE SEARXNG_IMAGE; do
    [[ -n "$(release_value "${key}")" ]] || die "${key} is empty in release.env."
  done
  if [[ -f "${env_file}" ]]; then
    echo "${env_file} exists. The script keeps its secrets."
  else
    # New secrets. The live .env is never copied.
    "${ONYX_SRC_DIR}/product/deploy/make-env.sh" "${SAAS_COMPOSE_DIR}" "${SAAS_URL}" || die "make-env.sh failed."
  fi
  if cmp -s "${COMPOSE_DIR}/.env" "${env_file}"; then
    die "${env_file} is a copy of the live .env. Remove it; cutover then writes new secrets."
  fi
  chmod 600 "${env_file}" || die "chmod 600 ${env_file} failed."
  pin_or_die "${env_file}" DOMAIN "${DNS_NAME}"
  pin_or_die "${env_file}" WEB_DOMAIN "${SAAS_URL}"
  # The release, the web build with NEXT_PUBLIC_CLOUD_ENABLED=true, the backend build that
  # gives every new company the platform defaults, the model server and the tool images.
  pin_or_die "${env_file}" IMAGE_TAG "$(release_value ONYX_RELEASE_TAG)"
  pin_or_die "${env_file}" ONYX_WEB_SERVER_IMAGE "${cloud_image}"
  pin_or_die "${env_file}" ONYX_BACKEND_IMAGE "${backend_image}"
  for key in ONYX_MODEL_SERVER_IMAGE CODE_INTERPRETER_IMAGE PYTHON_EXECUTOR_IMAGE CI_GATEWAY_IMAGE SEARXNG_IMAGE; do
    pin_or_die "${env_file}" "${key}" "$(release_value "${key}")"
  done
  echo "Set DOMAIN, WEB_DOMAIN, IMAGE_TAG, ONYX_WEB_SERVER_IMAGE, ONYX_BACKEND_IMAGE (cloud builds), ONYX_MODEL_SERVER_IMAGE, CODE_INTERPRETER_IMAGE, PYTHON_EXECUTOR_IMAGE, CI_GATEWAY_IMAGE and SEARXNG_IMAGE in ${env_file}."
  # The tool services (profile code-interpreter), the gateway address and the executor socket.
  pin_or_die "${env_file}" COMPOSE_PROFILES "s3-filestore,code-interpreter"
  pin_or_die "${env_file}" CODE_INTERPRETER_BASE_URL "http://ci-gateway:8000"
  pin_or_die "${env_file}" DOCKER_SOCK_PATH "${sock}"
  if [[ "${mode}" == main-socket ]]; then
    ci_env_add_cgroup_parent "${env_file}" || die "Could not set CI_EXECUTOR_RUN_ARGS in ${env_file}."
  else
    ci_env_drop_cgroup_parent "${env_file}" || die "Could not set CI_EXECUTOR_RUN_ARGS in ${env_file}."
  fi
  echo "Set COMPOSE_PROFILES=s3-filestore,code-interpreter, CODE_INTERPRETER_BASE_URL=http://ci-gateway:8000 and DOCKER_SOCK_PATH=${sock} (${mode}) in ${env_file}."
  if [[ -z "$(stack_env_value "${env_file}" SEARXNG_SECRET)" ]]; then
    key="$(openssl rand -hex 32)" || die "openssl rand failed."
    pin_or_die "${env_file}" SEARXNG_SECRET "${key}"
    echo "Wrote SEARXNG_SECRET into ${env_file} (value not shown)."
  fi
  # The web search default of every new company. An owner-supplied provider in
  # secrets/saas.env wins: saas_merge_secrets runs last.
  if ! grep -qE '^WEB_SEARCH_DEFAULT_PROVIDER=' "${env_file}"; then
    set_env_key WEB_SEARCH_DEFAULT_PROVIDER searxng "${env_file}" || die "Could not write ${env_file}."
    set_env_key WEB_SEARCH_DEFAULT_CONFIG '{"searxng_base_url":"http://searxng:8080","num_results":"10"}' "${env_file}" ||
      die "Could not write ${env_file}."
    set_env_key WEB_SEARCH_DEFAULT_DISPLAY_NAME "22nd X AI web search" "${env_file}" || die "Could not write ${env_file}."
    echo "Set WEB_SEARCH_DEFAULT_PROVIDER=searxng, WEB_SEARCH_DEFAULT_CONFIG and WEB_SEARCH_DEFAULT_DISPLAY_NAME in ${env_file}."
  else
    echo "${env_file} has WEB_SEARCH_DEFAULT_PROVIDER already: the web search default stays."
  fi
  stack_env_pin_compose "${env_file}" "${SAAS_PROJECT}" "${SAAS_COMPOSE_FILES[@]}" ||
    die "Could not set COMPOSE_PROJECT_NAME and COMPOSE_FILE in ${env_file}."
  stack_env_settings "${env_file}"
  saas_model_defaults "${env_file}"
  saas_merge_secrets "${env_file}"
}

# stack_env_pin, or stop: the actions run without errexit.
pin_or_die() {
  stack_env_pin "$@" || die "Could not set $2 in $1."
}

# Writes the KEY=value lines of secrets/saas.env into the saas .env. The log shows key names only.
saas_merge_secrets() {
  local env_file="$1" file="${SECRETS_DIR}/saas.env" line key value keys=""
  [[ -f "${file}" ]] || { echo "No ${file}: no extra keys for the saas .env."; return 0; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "${file} has a line that is not KEY=value (the line is not shown)."
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    # One layer of matching quotes goes. set_env_key quotes again when needed.
    if [[ "${value}" =~ ^\"(.*)\"$ || "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    set_env_key "${key}" "${value}" "${env_file}" || die "Could not write ${key} into ${env_file}."
    keys+=" ${key}"
  done <"${file}"
  echo "Set from ${file} (values not shown):${keys}"
}

# Copies the Let's Encrypt files and the nginx redirect files of the live stack. The copies
# keep their owner (certbot writes as root). An existing certbot/conf copy stays as it is.
saas_copy_https_files() {
  local sha="$1"
  section "certificate and nginx files"
  mkdir -p "${SAAS_DATA_DIR}/certbot" "${SAAS_DATA_DIR}/nginx-extra" || die "Could not create ${SAAS_DATA_DIR}."
  if sudo -n test -d "${SAAS_DATA_DIR}/certbot/conf"; then
    echo "${SAAS_DATA_DIR}/certbot/conf exists. The script keeps it."
  else
    sudo -n cp -a "${LIVE_DATA_DIR}/certbot/." "${SAAS_DATA_DIR}/certbot/" ||
      die "sudo -n cannot copy ${LIVE_DATA_DIR}/certbot."
    echo "Copied certbot/ (account, certificate and ACME web root)."
  fi
  # redirect.conf.template already carries the domain. render-redirect.sh fills in the rest.
  sudo -n cp -a "${LIVE_DATA_DIR}/nginx-extra/." "${SAAS_DATA_DIR}/nginx-extra/" ||
    die "sudo -n cannot copy ${LIVE_DATA_DIR}/nginx-extra."
  # The live copy of render-redirect.sh may predate the leave-team guard. Use the checkout.
  sudo -n install -m 644 "${ONYX_SRC_DIR}/product/deploy/nginx/render-redirect.sh" \
    "${SAAS_DATA_DIR}/nginx-extra/render-redirect.sh" ||
    die "sudo -n cannot write ${SAAS_DATA_DIR}/nginx-extra/render-redirect.sh."
  echo "Copied nginx-extra/ and installed render-redirect.sh from ${sha}."
  ls -la "${SAAS_DATA_DIR}/nginx-extra" || true
}

# ----- rollback

rollback_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence rollback rollback "${sha}"
}

# Stops onyx-saas (its volumes stay) and starts onyx again on the public URL.
rollback() {
  local sha="$1"
  section "vm-bootstrap rollback ${sha} $(date -u +%FT%TZ)"
  docker_setup
  [[ -f "${COMPOSE_DIR}/.env" ]] || die "${COMPOSE_DIR}/.env is missing. The live stack cannot start."
  section "stopping ${SAAS_PROJECT} (volumes stay)"
  saas_stop
  section "starting the live stack (project onyx)"
  live_compose start
  set_live_url
  wait_health "${LIVE_URL}"
  check_public_url
  saas_write_active_stack onyx || echo "WARNING: ${ACTIVE_STACK_FILE} could not be written." >&2
  show "docker compose ps (onyx)" live_compose ps
  show "volumes of onyx and ${SAAS_PROJECT}" list_stack_volumes
  section "rollback complete: project onyx serves ${LIVE_URL}"
}

# Stops the containers of onyx-saas. Never "down", never -v.
saas_stop() {
  local containers
  if saas_compose_files_present; then
    saas_compose stop
  else
    containers="$(stack_running "${SAAS_PROJECT}")"
    [[ -z "${containers}" ]] || xargs -r "${DOCKER_CMD[@]}" stop <<<"${containers}" >/dev/null
  fi
  echo "Project ${SAAS_PROJECT} has no running containers."
}

# ----- saas-check, saas-restart, saas-down

# Stops the script unless onyx-saas, and not onyx, serves the public URL. The checks create
# accounts, so they must never run against the single-tenant stack.
saas_must_serve() {
  [[ -f "${SAAS_COMPOSE_DIR}/.env" ]] || die "${SAAS_COMPOSE_DIR}/.env is missing. Run the cutover action first."
  [[ -n "$(stack_running "${SAAS_PROJECT}")" ]] || die "Project ${SAAS_PROJECT} has no running containers. Run the cutover action first."
  [[ -z "$(live_compose ps -q --status running 2>/dev/null)" ]] ||
    die "The live project onyx has running containers. The checks would run against it. Stop one stack first."
  wait_health "${SAAS_URL}" 60 || die "${SAAS_PROJECT} is not healthy at ${SAAS_URL}."
}

saas_check_wrapper() {
  local sha="${1:-}" mode="${2:-}"
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == after-restart ]] || die "The second argument must be after-restart or empty."
  with_evidence saas-check saas_check "${sha}" "${mode}"
}

saas_check() {
  local sha="$1" mode="$2"
  section "vm-bootstrap saas-check ${sha} $(date -u +%FT%TZ) (mode=${mode:-first})"
  docker_setup
  saas_must_serve
  checkout_source "${sha}"
  saas_run_checks "${mode}"
}

saas_restart_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence saas-restart saas_restart "${sha}"
}

# Recreates the onyx-saas containers and repeats the customer journey read checks.
# "down" never gets -v.
saas_restart() {
  local sha="$1" volumes_before volumes_after
  section "vm-bootstrap saas-restart ${sha} $(date -u +%FT%TZ)"
  docker_setup
  saas_compose_files_present || die "The files in ${SAAS_COMPOSE_DIR} are missing. Run the cutover action first."
  [[ -f "${SAAS_JOURNEY_STATE_FILE}" ]] ||
    die "${SAAS_JOURNEY_STATE_FILE} is missing. Run the saas-journey action first."
  saas_must_serve
  checkout_source "${sha}"

  volumes_before="$(dk volume ls -q --filter "label=com.docker.compose.project=${SAAS_PROJECT}" | sort)"
  show "containers before" saas_compose ps --format '{{.Name}} {{.ID}} {{.Status}}'
  run_step down saas_compose down
  run_step up saas_compose up -d
  run_step health wait_health "${SAAS_URL}"
  PUBLIC_URL="${SAAS_URL}"
  run_step public-url check_public_url
  show "containers after" saas_compose ps --format '{{.Name}} {{.ID}} {{.Status}}'
  volumes_after="$(dk volume ls -q --filter "label=com.docker.compose.project=${SAAS_PROJECT}" | sort)"
  echo "volumes: ${volumes_after//$'\n'/ }"
  run_step volumes-kept test -n "${volumes_after}" -a "${volumes_before}" = "${volumes_after}"
  run_step saas-journey-after-restart saas_run_journey after-restart
  saas_report
  summary
}

# ----- saas-journey, saas-defaults, saas-update

# Runs saas_journey.py against the public URL. Mode: empty or after-restart. A first run gets
# a new tag (two new test companies); after-restart reuses the tag of the last first run.
# MODEL_API_KEY goes into the environment of the test only so that it can check that no
# response body holds the key. The test never sends it.
saas_run_journey() {
  local mode="${1:-}" tag key=""
  local journey="${ONYX_SRC_DIR}/product/test-corpus/saas_journey.py"
  [[ -f "${journey}" ]] || { echo "ERROR: ${journey} is missing at this commit." >&2; return 1; }
  if [[ "${mode}" != after-restart ]]; then
    rm -f "${SAAS_JOURNEY_TAG_FILE}"
    saas_reset_signup_limit
  fi
  stack_ensure_check_secrets "${SAAS_JOURNEY_TAG_FILE}" "${SAAS_JOURNEY_SALT_FILE}" journey
  tag="$(cat "${SAAS_JOURNEY_TAG_FILE}")"
  local -a args=(--base-url "${SAAS_URL}" --tag "${tag}" --state "${SAAS_JOURNEY_STATE_FILE}")
  [[ "${mode}" != after-restart ]] || args+=(--after-restart)
  if [[ -f "${SECRETS_DIR}/model.env" ]]; then
    key="$(
      # shellcheck disable=SC1090,SC1091
      source "${SECRETS_DIR}/model.env"
      printf '%s' "${MODEL_API_KEY:-}"
    )"
    echo "model.env found: the journey checks that no response holds the platform key."
  else
    echo "No ${SECRETS_DIR}/model.env: the journey checks the masked key field only."
  fi
  MODEL_API_KEY="${key}" MT_PASSWORD_SALT="$(cat "${SAAS_JOURNEY_SALT_FILE}")" \
    python3 "${journey}" "${args[@]}"
}

saas_journey_wrapper() {
  local sha="${1:-}" mode="${2:-}"
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == after-restart ]] || die "The second argument must be after-restart or empty."
  with_evidence saas-journey saas_journey "${sha}" "${mode}"
}

saas_journey() {
  local sha="$1" mode="$2"
  section "vm-bootstrap saas-journey ${sha} $(date -u +%FT%TZ) (mode=${mode:-first})"
  docker_setup
  saas_must_serve
  checkout_source "${sha}"
  saas_run_journey "${mode}"
}

saas_defaults_wrapper() {
  local sha="${1:-}" mode="${2:-}"
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == dry-run ]] || die "The second argument must be dry-run or empty."
  with_evidence saas-defaults saas_defaults "${sha}" "${mode}"
}

# Applies the platform defaults to every tenant (also the pre-built pool tenants).
saas_defaults() {
  local sha="$1" mode="$2"
  section "vm-bootstrap saas-defaults ${sha} $(date -u +%FT%TZ) (mode=${mode:-apply})"
  docker_setup
  saas_must_serve
  saas_backfill "${mode}"
}

saas_update_wrapper() {
  local sha="${1:-}" mode="${2:-}"
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == release-change ]] || die "The second argument must be release-change or empty."
  with_evidence saas-update saas_update "${sha}" "${mode}"
}

# State of saas_update for on_saas_update_exit.
SAAS_UPDATE_SNAPSHOT=""
SAAS_UPDATE_STARTED=0
SAAS_UPDATE_DONE=0

# Deploys <sha> on the running onyx-saas stack: new release files, overlays and tool configs,
# the nginx files, the pinned images and the platform model from model.env. The certificate
# stays, .env keeps its secrets, the volumes stay. Order: checks, snapshot of the files,
# saas_prepare, executor image, pull, up -d, health, smoke checks, image check, platform
# defaults, key rotation when the platform key changed, deployed.env and active-stack.
# A failure after up -d puts the snapshot files back and runs up -d again. A changed Onyx
# release needs the mode release-change, which makes a backup first. The last line of the
# output is RESULT=deployed, RESULT=unchanged, RESULT=rolled-back or RESULT=failed.
# axi-deploy-dev.yml never touches onyx-saas.
saas_update() {
  local sha="$1" mode="$2" new_tag current_tag unchanged=0 executor_image
  trap 'on_saas_update_exit' EXIT
  section "vm-bootstrap saas-update ${sha} $(date -u +%FT%TZ) (mode=${mode:-same-release})"
  docker_setup
  saas_must_serve
  checkout_source "${sha}" || die "The checkout of ${sha} failed. Nothing was changed."
  saas_require_marker
  new_tag="$(release_value ONYX_RELEASE_TAG)"
  current_tag="$(stack_env_value "${SAAS_COMPOSE_DIR}/.env" IMAGE_TAG)"
  if [[ -n "${current_tag}" && "${current_tag}" != "${new_tag}" ]]; then
    [[ "${mode}" == release-change ]] ||
      die "The Onyx release changes from ${current_tag} to ${new_tag}: the new release migrates the database. Run saas-update with release-change; it makes a backup first. Nothing was changed."
    section "release change ${current_tag} -> ${new_tag}: backup first"
    saas_backup "${sha}" || die "The backup before the release change failed. Nothing was changed."
  elif [[ "${mode}" == release-change ]]; then
    echo "The release stays ${new_tag}: no backup for a release change."
  fi
  saas_update_snapshot || die "The rollback snapshot could not be written. Nothing was changed."
  PLATFORM_KEY_CHANGED=0
  saas_prepare "${sha}"
  saas_copy_https_files "${sha}"
  if saas_update_unchanged; then
    unchanged=1
    echo "The .env, the compose files and the tool configs are equal to the snapshot."
  fi
  executor_image="$(stack_env_value "${SAAS_COMPOSE_DIR}/.env" PYTHON_EXECUTOR_IMAGE)"
  [[ -n "${executor_image}" ]] || die "PYTHON_EXECUTOR_IMAGE is empty in ${SAAS_COMPOSE_DIR}/.env."
  section "executor image on the executor daemon ($(ci_marker_value EXECUTOR_MODE))"
  executor_docker pull --quiet "${executor_image}" || die "The executor image could not be pulled into the executor daemon."
  section "docker compose -p ${SAAS_PROJECT} pull"
  saas_compose pull --quiet || die "docker compose pull failed."
  SAAS_UPDATE_STARTED=1
  section "docker compose -p ${SAAS_PROJECT} up -d"
  saas_compose up -d || die "docker compose up -d failed."
  wait_health "${SAAS_URL}" || die "${SAAS_PROJECT} is not healthy at ${SAAS_URL} after the update."
  PUBLIC_URL="${SAAS_URL}"
  check_public_url || die "The public URL checks failed after the update."
  saas_smoke_checks || die "The smoke checks failed after the update."
  saas_images_match_pins || die "The running images are not the pinned images."
  saas_backfill || die "The platform defaults could not be applied to every tenant."
  if ((PLATFORM_KEY_CHANGED)); then
    saas_rotate_key || die "The platform key rotation failed."
  fi
  saas_write_deployed "${sha}" || die "${SAAS_DEPLOYED_FILE} could not be written."
  saas_write_active_stack "${SAAS_PROJECT}" || die "${ACTIVE_STACK_FILE} could not be written."
  SAAS_UPDATE_DONE=1
  saas_report
  section "saas-update complete: ${sha} on ${SAAS_URL}"
  if ((unchanged)); then
    echo "RESULT=unchanged"
  else
    echo "RESULT=deployed"
  fi
}

# After a failure: the snapshot files go back; after up -d the stack starts again from them.
# The last line is the RESULT.
on_saas_update_exit() {
  local code=$?
  trap - EXIT
  ((SAAS_UPDATE_DONE == 0)) || return 0
  ((code != 0)) || code=1
  if ((SAAS_UPDATE_STARTED)); then
    echo "saas-update failed (exit ${code}) after up -d: back to the snapshot ${SAAS_UPDATE_SNAPSHOT}." >&2
    if saas_update_rollback; then
      echo "RESULT=rolled-back"
    else
      echo "ERROR: the rollback failed. Check ${SAAS_COMPOSE_DIR} and ${SAAS_UPDATE_SNAPSHOT} by hand." >&2
      echo "RESULT=rollback-failed"
    fi
  elif [[ -n "${SAAS_UPDATE_SNAPSHOT}" ]]; then
    echo "saas-update failed (exit ${code}) before up -d: the snapshot files go back. The containers were not changed." >&2
    saas_update_restore_files || echo "ERROR: the snapshot files could not be put back. See ${SAAS_UPDATE_SNAPSHOT}." >&2
    echo "RESULT=failed"
  else
    echo "RESULT=failed"
  fi
  exit "${code}"
}

# Copies .env (mode 600), the compose files and the tool configs into rollback/<time>/.
# The newest SAAS_ROLLBACK_KEEP snapshots stay.
saas_update_snapshot() {
  local dir file
  dir="${SAAS_ROLLBACK_DIR}/$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 700 "${SAAS_ROLLBACK_DIR}" "${dir}" "${dir}/tools" || return 1
  install -m 600 "${SAAS_COMPOSE_DIR}/.env" "${dir}/.env" || return 1
  for file in "${SAAS_COMPOSE_FILES[@]}"; do
    [[ -f "${SAAS_COMPOSE_DIR}/${file}" ]] || continue
    install -m 644 "${SAAS_COMPOSE_DIR}/${file}" "${dir}/${file}" || return 1
  done
  for file in "${SAAS_TOOLS_FILES[@]}"; do
    [[ -f "${SAAS_COMPOSE_DIR}/tools/${file}" ]] || continue
    install -m 644 "${SAAS_COMPOSE_DIR}/tools/${file}" "${dir}/tools/${file}" || return 1
  done
  SAAS_UPDATE_SNAPSHOT="${dir}"
  echo "Rollback snapshot: ${dir}"
  find "${SAAS_ROLLBACK_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | head -n "-${SAAS_ROLLBACK_KEEP}" |
    while IFS= read -r file; do
      rm -rf "${file}" && echo "Removed the old snapshot ${file}."
    done
}

# Puts the snapshot files back into the compose folder.
saas_update_restore_files() {
  local dir="${SAAS_UPDATE_SNAPSHOT}" file
  [[ -n "${dir}" && -f "${dir}/.env" ]] || return 1
  install -m 600 "${dir}/.env" "${SAAS_COMPOSE_DIR}/.env" || return 1
  for file in "${SAAS_COMPOSE_FILES[@]}"; do
    [[ -f "${dir}/${file}" ]] || continue
    install -m 644 "${dir}/${file}" "${SAAS_COMPOSE_DIR}/${file}" || return 1
  done
  for file in "${SAAS_TOOLS_FILES[@]}"; do
    [[ -f "${dir}/tools/${file}" ]] || continue
    install -m 644 "${dir}/tools/${file}" "${SAAS_COMPOSE_DIR}/tools/${file}" || return 1
  done
  echo "Put the files of ${dir} back into ${SAAS_COMPOSE_DIR}."
}

# True when .env, the compose files and the tool configs are equal to the snapshot.
saas_update_unchanged() {
  local dir="${SAAS_UPDATE_SNAPSHOT}" file
  [[ -n "${dir}" ]] || return 1
  cmp -s "${dir}/.env" "${SAAS_COMPOSE_DIR}/.env" || return 1
  for file in "${SAAS_COMPOSE_FILES[@]}"; do
    cmp -s "${dir}/${file}" "${SAAS_COMPOSE_DIR}/${file}" || return 1
  done
  for file in "${SAAS_TOOLS_FILES[@]}"; do
    cmp -s "${dir}/tools/${file}" "${SAAS_COMPOSE_DIR}/tools/${file}" || return 1
  done
}

# Starts the stack again from the snapshot files, with the compose file list of the
# snapshot .env. Containers of services that the snapshot does not know go.
saas_update_rollback() {
  local files service ids
  saas_update_restore_files || return 1
  files="$(stack_env_value "${SAAS_COMPOSE_DIR}/.env" COMPOSE_FILE)"
  [[ -n "${files}" ]] || files="$(join_colon "${SAAS_COMPOSE_FILES[@]}")"
  if [[ "${files}" != *compose.tools.yml* ]]; then
    for service in "${SAAS_TOOL_SERVICES[@]}"; do
      ids="$(dk ps -aq --filter "label=com.docker.compose.project=${SAAS_PROJECT}" \
        --filter "label=com.docker.compose.service=${service}")" || return 1
      [[ -z "${ids}" ]] || xargs -r "${DOCKER_CMD[@]}" rm -f <<<"${ids}" >/dev/null || return 1
    done
  fi
  section "docker compose -p ${SAAS_PROJECT} up -d (snapshot files)"
  stack_compose "${SAAS_PROJECT}" "${SAAS_COMPOSE_DIR}" "${files}" up -d || return 1
  wait_health "${SAAS_URL}" || return 1
  PUBLIC_URL="${SAAS_URL}"
  check_public_url || return 1
}

# Checks that create nothing: the health and auth endpoints, the leave-team guard, the tool
# services from inside api_server.
saas_smoke_checks() {
  local code
  section "smoke checks (nothing is created)"
  code="$(http_code "${SAAS_URL}/api/health/ready")"
  if [[ "${code}" == 200 ]]; then
    echo "/api/health/ready answers 200."
  else
    echo "/api/health/ready answers ${code}; checking /api/health."
    code="$(http_code "${SAAS_URL}/api/health")"
    [[ "${code}" == 200 ]] || { echo "ERROR: /api/health answers ${code}, not 200." >&2; return 1; }
    echo "/api/health answers 200."
  fi
  curl -s --max-time 20 "${SAAS_URL}/api/auth/type" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("auth_type:", data.get("auth_type"), "multi_tenant:", data.get("multi_tenant"))
sys.exit(0 if data.get("multi_tenant") is True else 1)
' || { echo "ERROR: /api/auth/type does not report multi_tenant true." >&2; return 1; }
  code="$(http_code -X POST "${SAAS_URL}/api/tenants/leave-team")"
  [[ "${code}" == 409 ]] || { echo "ERROR: POST /api/tenants/leave-team answers ${code}, not 409." >&2; return 1; }
  echo "POST /api/tenants/leave-team answers 409 (leave-team guard)."
  saas_tool_probes basic
}

# Probes the tool services from inside api_server with urllib. Mode basic: gateway health,
# the file listing is forbidden, code-interpreter does not resolve, searxng health.
# Mode isolation adds /v1/sessions, /docs, /openapi.json and an execute call with a path as
# file_id, which must be rejected or show no secret name. Response bodies are not printed.
saas_tool_probes() {
  local mode="${1:-basic}"
  section "tool service probes from api_server (${mode})"
  saas_compose exec -T api_server python - "${mode}" <<'PY'
import json
import socket
import sys
import urllib.error
import urllib.request

mode = sys.argv[1]
failed = []


def get(url, timeout=20):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (": " + detail if detail else ""))
    if not ok:
        failed.append(name)


status, body = get("http://ci-gateway:8000/health")
try:
    data = json.loads(body)
except ValueError:
    data = {}
check("gateway /health status ok", status == 200 and data.get("status") == "ok",
      f"{status} {data.get('status')} {data.get('message', '')}".strip())
status, _ = get("http://ci-gateway:8000/v1/files")
check("gateway GET /v1/files is 403", status == 403, str(status))
try:
    socket.getaddrinfo("code-interpreter", 8000)
    resolves = True
except socket.gaierror:
    resolves = False
check("code-interpreter does not resolve from api_server", not resolves)
status, _ = get("http://searxng:8080/healthz")
check("searxng /healthz is 200", status == 200, str(status))

if mode == "isolation":
    for path in ("/v1/sessions", "/docs", "/openapi.json"):
        status, _ = get("http://ci-gateway:8000" + path)
        check(f"gateway GET {path} is 403", status == 403, str(status))
    payload = {
        "code": "print(open('env.txt', 'rb').read()[:4000])",
        "timeout_ms": 30000,
        "files": [{"path": "env.txt", "file_id": "/proc/1/environ"}],
    }
    request = urllib.request.Request(
        "http://ci-gateway:8000/v1/execute",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read()
    except OSError as error:
        status, body = 0, repr(error).encode()
    text = body.decode("utf-8", "replace")
    names = [
        "FIREWORKS_DEFAULT_API_KEY", "POSTGRES_PASSWORD", "USER_AUTH_SECRET",
        "ENCRYPTION_KEY_SECRET", "SEARXNG_SECRET", "S3_AWS_SECRET_ACCESS_KEY",
        "MINIO_ROOT_PASSWORD", "OPENSEARCH_ADMIN_PASSWORD", "SMTP_PASS", "WEB_SEARCH_DEFAULT_API_KEY",
    ]
    leaked = [name for name in names if name in text]
    check("execute with file_id /proc/1/environ is rejected or shows no secret name",
          status != 200 or not leaked, f"status {status}, secret names in the output: {leaked}")

if failed:
    print("probes failed:", ", ".join(failed))
    sys.exit(1)
print("all probes passed")
PY
}

# The running containers must run the images that .env pins. The check compares image IDs
# (the container's image against "docker image inspect <pin>"), so the spelling of the
# reference does not matter. It also prints the Image field of "compose ps --format json".
saas_images_match_pins() {
  local env_file="${SAAS_COMPOSE_DIR}/.env" service key pin cid running_id pin_id state bad=0
  section "running images against the pins"
  saas_compose ps --format json 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    rows = json.loads(raw) if raw.startswith("[") else [json.loads(l) for l in raw.splitlines() if l.strip()]
except ValueError:
    rows = []
for row in rows:
    print("  %s: %s (%s)" % (row.get("Service"), row.get("Image"), row.get("State")))
' || true
  for service in api_server:ONYX_BACKEND_IMAGE background:ONYX_BACKEND_IMAGE \
    web_server:ONYX_WEB_SERVER_IMAGE inference_model_server:ONYX_MODEL_SERVER_IMAGE \
    indexing_model_server:ONYX_MODEL_SERVER_IMAGE code-interpreter:CODE_INTERPRETER_IMAGE \
    ci-gateway:CI_GATEWAY_IMAGE searxng:SEARXNG_IMAGE; do
    key="${service#*:}"
    service="${service%%:*}"
    pin="$(stack_env_value "${env_file}" "${key}")"
    cid="$(saas_compose ps -q "${service}" 2>/dev/null | head -n 1)"
    state="$([[ -z "${cid}" ]] || dk inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null)"
    running_id="$([[ -z "${cid}" ]] || dk inspect --format '{{.Image}}' "${cid}" 2>/dev/null)"
    pin_id="$([[ -z "${pin}" ]] || dk image inspect --format '{{.Id}}' "${pin}" 2>/dev/null)"
    if [[ -n "${pin}" && "${state}" == running && -n "${pin_id}" && "${running_id}" == "${pin_id}" ]]; then
      echo "ok   ${service}: ${pin}"
    else
      echo "FAIL ${service}: pin ${key}=${pin:-missing}, state ${state:-missing}, image ${running_id:-?} (pin ${pin_id:-not local})"
      bad=1
    fi
  done
  ((bad == 0))
}

# Writes deployed.env: the SHA, the time, the release and the image refs. No secrets.
saas_write_deployed() {
  local sha="$1" env_file="${SAAS_COMPOSE_DIR}/.env" key
  {
    echo "DEPLOYED_SHA=${sha}"
    echo "DEPLOYED_AT=$(date -u +%FT%TZ)"
    echo "ONYX_RELEASE_TAG=$(release_value ONYX_RELEASE_TAG)"
    for key in ONYX_BACKEND_IMAGE ONYX_WEB_SERVER_IMAGE ONYX_MODEL_SERVER_IMAGE \
      CODE_INTERPRETER_IMAGE PYTHON_EXECUTOR_IMAGE CI_GATEWAY_IMAGE SEARXNG_IMAGE; do
      echo "${key}=$(stack_env_value "${env_file}" "${key}")"
    done
    echo "EXECUTOR_MODE=$(ci_marker_value EXECUTOR_MODE)"
  } >"${SAAS_DEPLOYED_FILE}.tmp" || return 1
  mv -f "${SAAS_DEPLOYED_FILE}.tmp" "${SAAS_DEPLOYED_FILE}" || return 1
  echo "Wrote ${SAAS_DEPLOYED_FILE}."
}

# Records which project serves the public URL.
saas_write_active_stack() {
  echo "$1" >"${ACTIVE_STACK_FILE}" || return 1
  echo "Wrote ${ACTIVE_STACK_FILE}: $1"
}

saas_down_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence saas-down saas_down "${sha}"
}

# Stops the onyx-saas containers. The volumes stay. There is no destroy action for this stack.
# The public URL answers nothing until cutover or rollback runs.
saas_down() {
  local sha="$1"
  section "vm-bootstrap saas-down ${sha} $(date -u +%FT%TZ)"
  docker_setup
  saas_stop
  show "volumes kept (${SAAS_PROJECT})" dk volume ls --filter "label=com.docker.compose.project=${SAAS_PROJECT}"
  echo "Start the old service again with the rollback action, or the new one with cutover."
}

# ---------------------------------------------------------------- code interpreter executor host

# Prints one value of the ci-host-setup marker, or nothing.
ci_marker_value() {
  [[ -f "${CI_MARKER_FILE}" ]] || return 0
  sed -n -E "s/^${1}=//p" "${CI_MARKER_FILE}" | tail -n 1
}

# Stops unless ci-host-setup wrote a complete marker. saas_prepare pins DOCKER_SOCK_PATH from it.
saas_require_marker() {
  [[ -f "${CI_MARKER_FILE}" ]] || die "${CI_MARKER_FILE} is missing: run ci-host-setup first. Nothing was changed."
  [[ "$(ci_marker_value DOCKER_SOCK_PATH)" == /* ]] ||
    die "DOCKER_SOCK_PATH is missing in ${CI_MARKER_FILE}: run ci-host-setup first. Nothing was changed."
  [[ "$(ci_marker_value EXECUTOR_MODE)" =~ ^(rootless|main-socket)$ ]] ||
    die "EXECUTOR_MODE in ${CI_MARKER_FILE} is not rootless or main-socket: run ci-host-setup first. Nothing was changed."
}

# Docker on the executor daemon of the marker, as root: the rootless socket belongs to the
# user ci-sandbox, and the code interpreter container (root) reaches it the same way.
executor_docker() {
  local sock
  sock="$(ci_marker_value DOCKER_SOCK_PATH)"
  [[ -n "${sock}" ]] || { echo "ERROR: no DOCKER_SOCK_PATH in ${CI_MARKER_FILE}." >&2; return 1; }
  sudo -n env DOCKER_HOST="unix://${sock}" docker "$@"
}

# The systemd unit that caps all executors together.
ci_cap_unit() {
  if [[ "$(ci_marker_value EXECUTOR_MODE)" == rootless ]]; then
    echo "user-$(ci_marker_value EXECUTOR_UID).slice"
  else
    echo "code-exec.slice"
  fi
}

# main-socket: the executors go into code-exec.slice. Appends the flag to CI_EXECUTOR_RUN_ARGS.
ci_env_add_cgroup_parent() {
  local env_file="$1" args
  args="$(stack_env_value "${env_file}" CI_EXECUTOR_RUN_ARGS)"
  [[ -n "${args}" ]] || args="${CI_EXECUTOR_RUN_ARGS_DEFAULT}"
  [[ " ${args} " == *" ${CI_CGROUP_PARENT_ARG} "* ]] || args+=" ${CI_CGROUP_PARENT_ARG}"
  set_env_key CI_EXECUTOR_RUN_ARGS "${args}" "${env_file}"
}

# rootless: the user slice of ci-sandbox holds the cap. Removes the flag again.
ci_env_drop_cgroup_parent() {
  local env_file="$1" args
  args="$(stack_env_value "${env_file}" CI_EXECUTOR_RUN_ARGS)"
  [[ " ${args} " == *" ${CI_CGROUP_PARENT_ARG} "* ]] || return 0
  args=" ${args} "
  args="${args// ${CI_CGROUP_PARENT_ARG} / }"
  args="${args# }"
  args="${args% }"
  set_env_key CI_EXECUTOR_RUN_ARGS "${args}" "${env_file}"
}

# Appends the sha256 of <key> to KEY_FINGERPRINTS_FILE (mode 600, one hex digest per line,
# no duplicates). The key reaches sha256sum through a pipe only; nothing prints it.
record_key_fingerprint() {
  local fingerprint
  fingerprint="$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)" || return 1
  [[ "${fingerprint}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ -d "${SECRETS_DIR}" ]] || install -d -m 700 "${SECRETS_DIR}" || return 1
  if [[ ! -f "${KEY_FINGERPRINTS_FILE}" ]]; then
    (umask 077 && : >"${KEY_FINGERPRINTS_FILE}") || return 1
  fi
  chmod 600 "${KEY_FINGERPRINTS_FILE}" || return 1
  grep -qxF "${fingerprint}" "${KEY_FINGERPRINTS_FILE}" && return 0
  echo "${fingerprint}" >>"${KEY_FINGERPRINTS_FILE}"
}

# True when the Debian package is installed.
package_installed() {
  # shellcheck disable=SC2016
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Host facts for the code interpreter executors (inspect). No secrets: the marker holds paths.
ci_host_facts() {
  local uid pkg
  echo "kernel: $(uname -r)"
  echo "cgroup file system: $(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
  echo "cgroup controllers: $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo unknown)"
  echo "kernel.unprivileged_userns_clone: $(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo n/a)"
  echo "kernel.apparmor_restrict_unprivileged_userns: $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo n/a)"
  echo "user.max_user_namespaces: $(sysctl -n user.max_user_namespaces 2>/dev/null || echo n/a)"
  for pkg in uidmap slirp4netns dbus-user-session docker-ce-rootless-extras; do
    if package_installed "${pkg}"; then echo "package ${pkg}: installed"; else echo "package ${pkg}: missing"; fi
  done
  echo "dockerd-rootless-setuptool.sh: $(command -v dockerd-rootless-setuptool.sh || echo missing)"
  echo "-- /etc/docker/daemon.json"
  cat /etc/docker/daemon.json 2>/dev/null || echo "missing"
  echo
  echo "main daemon: $({ docker info --format '{{.ServerVersion}}, cgroup driver {{.CgroupDriver}}, cgroup v{{.CgroupVersion}}, root {{.DockerRootDir}}' 2>/dev/null ||
    sudo -n docker info --format '{{.ServerVersion}}, cgroup driver {{.CgroupDriver}}, cgroup v{{.CgroupVersion}}, root {{.DockerRootDir}}' 2>/dev/null; } || echo unknown)"
  echo "-- ${CI_MARKER_FILE}"
  grep -E '^(DOCKER_SOCK_PATH|EXECUTOR_MODE|EXECUTOR_UID|EXECUTOR_CAP)=' "${CI_MARKER_FILE}" 2>/dev/null || echo "missing"
  if uid="$(id -u "${CI_SANDBOX_USER}" 2>/dev/null)"; then
    echo "user ${CI_SANDBOX_USER}: uid ${uid}, linger $(loginctl show-user "${CI_SANDBOX_USER}" -p Linger --value 2>/dev/null || echo unknown)"
    echo "subuid ranges: $(grep -c "^${CI_SANDBOX_USER}:" /etc/subuid 2>/dev/null || true), subgid ranges: $(grep -c "^${CI_SANDBOX_USER}:" /etc/subgid 2>/dev/null || true)"
    echo "delegated controllers: $(cat "/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/cgroup.controllers" 2>/dev/null || echo unknown)"
    echo "user-${uid}.slice: $(systemctl show "user-${uid}.slice" -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax 2>/dev/null | tr '\n' ' ')"
    echo "rootless socket /run/user/${uid}/docker.sock: $(sudo -n test -S "/run/user/${uid}/docker.sock" 2>/dev/null && echo present || echo missing)"
  else
    echo "user ${CI_SANDBOX_USER}: missing"
  fi
  echo "code-exec.slice: $(systemctl show code-exec.slice -p LoadState -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax 2>/dev/null | tr '\n' ' ')"
  echo "ci-cleanup.timer: $(systemctl is-active ci-cleanup.timer 2>/dev/null || true), $(systemctl is-enabled ci-cleanup.timer 2>/dev/null || true)"
  echo "memory: $(awk '/^(MemTotal|MemAvailable|SwapTotal):/ { printf "%s %d MiB  ", $1, $2 / 1024 }' /proc/meminfo)"
  echo "disk: $(df -Ph "${SRV_ROOT}" 2>/dev/null | awk 'NR == 2 { print $4 " free of " $2 }')"
}

ci_host_setup_wrapper() {
  local sha="${1:-}" mode="${2:-}"
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == main-socket ]] || die "The second argument must be main-socket or empty."
  with_evidence ci-host-setup ci_host_setup "${sha}" "${mode}"
}

# Creates the Docker daemon of the code interpreter executors. Idempotent.
# Default: a rootless daemon of the user ci-sandbox; its user slice caps all executors
# together. With main-socket, or when a rootless step fails: the main daemon, with the
# executors in code-exec.slice (the same cap). Both modes pre-pull the executor image, test
# one executor run, install the cleanup timer and write the marker ci-executor.env.
# saas-update applies the marker to the stack (DOCKER_SOCK_PATH, CI_EXECUTOR_RUN_ARGS).
ci_host_setup() {
  local sha="$1" mode="$2" image ci_image
  section "vm-bootstrap ci-host-setup ${sha} $(date -u +%FT%TZ) (mode=${mode:-rootless})"
  have_sudo || die "sudo -n is denied for $(id -un). ci-host-setup needs sudo without a password."
  docker_setup
  checkout_source "${sha}" || die "The checkout of ${sha} failed."
  image="$(release_value PYTHON_EXECUTOR_IMAGE)"
  ci_image="$(release_value CODE_INTERPRETER_IMAGE)"
  [[ "${image}" =~ @sha256:[0-9a-f]{64}$ ]] || die "PYTHON_EXECUTOR_IMAGE in release.env is not a digest reference."
  [[ "${ci_image}" =~ @sha256:[0-9a-f]{64}$ ]] || die "CODE_INTERPRETER_IMAGE in release.env is not a digest reference."
  if [[ "${mode}" == main-socket ]]; then
    echo "main-socket was requested: no rootless daemon."
  elif ci_rootless_setup "${image}" "${ci_image}"; then
    mode=rootless
  else
    echo "WARNING: the rootless executor daemon could not be set up (see the ERROR above). ci-host-setup falls back to the main Docker socket." >&2
    mode=main-socket
  fi
  if [[ "${mode}" == main-socket ]]; then
    ci_main_socket_setup "${image}" "${ci_image}" ||
      die "The executor setup on the main Docker daemon failed. ${CI_MARKER_FILE} was not changed."
  fi
  ci_cleanup_install || die "The cleanup timer could not be installed."
  section "ci-host-setup complete"
  echo "mode: $(ci_marker_value EXECUTOR_MODE)"
  echo "socket: $(ci_marker_value DOCKER_SOCK_PATH)"
  echo "cap of all executors together: ${CI_CAP[*]} ($(ci_cap_unit))"
  echo "cap of one run: ${CI_EXECUTOR_RUN_ARGS_DEFAULT}, memory 512m, pids 64, CPU time 60 s, wall time 60 s, no network"
  [[ "$(ci_marker_value EXECUTOR_MODE)" != main-socket ]] || ci_main_socket_warning
  echo "saas-update applies the marker to ${SAAS_PROJECT} (DOCKER_SOCK_PATH, CI_EXECUTOR_RUN_ARGS)."
}

ci_main_socket_warning() {
  echo "WARNING: EXECUTOR_MODE=main-socket. The code interpreter API container holds the host Docker socket, which is root-equivalent: a flaw in the API (no authentication; only ci-gateway reaches it) or in Docker gives root on the VM and the data of every company. Run ci-host-setup without main-socket when the host supports the rootless daemon." >&2
}

# Runs a command as ci-sandbox in its systemd user session. Its shell is nologin, so no
# login shell (sudo -i) is used.
ci_sandbox_run() {
  local uid="$1" home="$2"
  shift 2
  (cd / && sudo -n -u "${CI_SANDBOX_USER}" env HOME="${home}" XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin "$@")
}

# Waits up to <seconds> until <path> is a socket. sudo: /run/user/<uid> is mode 700.
wait_socket() {
  local path="$1" deadline=$((SECONDS + $2))
  until sudo -n test -S "${path}"; do
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

# Writes <content> into the root-owned <file> when it differs. Returns 0 when the file
# changed, 1 when it was already equal, 2 on an error.
write_root_file() {
  local file="$1" content="$2"
  [[ "$(sudo -n cat "${file}" 2>/dev/null)" != "${content}" ]] || return 1
  sudo -n install -d -m 755 "$(dirname "${file}")" || return 2
  printf '%s\n' "${content}" | sudo -n tee "${file}" >/dev/null || return 2
  echo "wrote ${file}"
}

# The rootless daemon of ci-sandbox. Every failed step prints an ERROR and returns 1.
ci_rootless_setup() {
  local image="$1" ci_image="$2" uid home sock controllers controller pkg info code=0
  local -a missing=()
  section "rootless executor daemon of the user ${CI_SANDBOX_USER}"
  [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == cgroup2fs ]] ||
    { echo "ERROR: cgroup v2 is not mounted at /sys/fs/cgroup. The rootless limits need it." >&2; return 1; }
  if [[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" == 1 ]]; then
    echo "ERROR: kernel.apparmor_restrict_unprivileged_userns=1. rootlesskit then needs an AppArmor profile, which this script does not install." >&2
    return 1
  fi
  for pkg in uidmap slirp4netns dbus-user-session docker-ce-rootless-extras; do
    package_installed "${pkg}" || missing+=("${pkg}")
  done
  if ((${#missing[@]})); then
    echo "installing ${missing[*]}"
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -y -q update >/dev/null ||
      { echo "ERROR: apt-get update failed." >&2; return 1; }
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -y -q install "${missing[@]}" ||
      { echo "ERROR: apt-get install ${missing[*]} failed." >&2; return 1; }
  else
    echo "packages uidmap, slirp4netns, dbus-user-session, docker-ce-rootless-extras: installed"
  fi
  command -v dockerd-rootless-setuptool.sh >/dev/null ||
    { echo "ERROR: dockerd-rootless-setuptool.sh is missing (docker-ce-rootless-extras)." >&2; return 1; }

  if ! id -u "${CI_SANDBOX_USER}" >/dev/null 2>&1; then
    sudo -n useradd --create-home --shell /usr/sbin/nologin --comment "Code Interpreter executors" \
      "${CI_SANDBOX_USER}" || { echo "ERROR: useradd ${CI_SANDBOX_USER} failed." >&2; return 1; }
    echo "created the user ${CI_SANDBOX_USER}"
  fi
  uid="$(id -u "${CI_SANDBOX_USER}")" || return 1
  home="$(getent passwd "${CI_SANDBOX_USER}" | cut -d: -f6)"
  [[ -n "${home}" ]] || { echo "ERROR: ${CI_SANDBOX_USER} has no home folder." >&2; return 1; }
  echo "user ${CI_SANDBOX_USER}: uid ${uid}, home ${home}"
  ci_ensure_subids || { echo "ERROR: the subordinate uid or gid range of ${CI_SANDBOX_USER} could not be added." >&2; return 1; }

  # Without cpu, memory and pids delegation, the rootless daemon discards --cpus, --memory and
  # --pids-limit. A changed delegation applies after a restart of the user manager.
  write_root_file /etc/systemd/system/user@.service.d/delegate.conf \
    "$(printf '%s\n' '[Service]' 'Delegate=cpu cpuset io memory pids')" || code=$?
  ((code != 2)) || { echo "ERROR: delegate.conf could not be written." >&2; return 1; }
  if ((code == 0)); then
    sudo -n systemctl daemon-reload || return 1
  fi
  sudo -n loginctl enable-linger "${CI_SANDBOX_USER}" || { echo "ERROR: loginctl enable-linger failed." >&2; return 1; }
  if ((code == 0)) && systemctl is-active --quiet "user@${uid}.service"; then
    sudo -n systemctl restart "user@${uid}.service" || { echo "ERROR: the restart of user@${uid}.service failed." >&2; return 1; }
  fi
  sudo -n systemctl start "user@${uid}.service" || { echo "ERROR: user@${uid}.service does not start." >&2; return 1; }
  wait_socket "/run/user/${uid}/bus" 60 ||
    { echo "ERROR: the user bus /run/user/${uid}/bus did not appear (dbus-user-session)." >&2; return 1; }
  controllers="$(cat "/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/cgroup.controllers" 2>/dev/null || true)"
  for controller in cpu memory pids; do
    [[ " ${controllers} " == *" ${controller} "* ]] ||
      { echo "ERROR: the cgroup controller ${controller} is not delegated to user@${uid}.service (${controllers:-none})." >&2; return 1; }
  done
  echo "delegated controllers of user@${uid}.service: ${controllers}"

  sock="/run/user/${uid}/docker.sock"
  if ci_sandbox_run "${uid}" "${home}" systemctl --user is-active --quiet docker.service; then
    echo "the rootless daemon runs (docker.service of the user manager of ${CI_SANDBOX_USER})"
  else
    echo "dockerd-rootless-setuptool.sh install"
    ci_sandbox_run "${uid}" "${home}" dockerd-rootless-setuptool.sh install ||
      { echo "ERROR: dockerd-rootless-setuptool.sh install failed (see above)." >&2; return 1; }
  fi
  ci_sandbox_run "${uid}" "${home}" systemctl --user enable docker.service >/dev/null 2>&1 ||
    { echo "ERROR: systemctl --user enable docker.service failed." >&2; return 1; }
  wait_socket "${sock}" 90 || { echo "ERROR: ${sock} did not appear within 90 s." >&2; return 1; }
  info="$(sudo -n env DOCKER_HOST="unix://${sock}" docker info --format \
    '{{.ServerVersion}} cgroup driver {{.CgroupDriver}}, cgroup v{{.CgroupVersion}}, {{json .SecurityOptions}}' 2>&1)" ||
    { echo "ERROR: the rootless daemon does not answer: ${info}" >&2; return 1; }
  echo "rootless daemon: ${info}"
  [[ "${info}" == *name=rootless* ]] || { echo "ERROR: ${sock} is not a rootless daemon." >&2; return 1; }

  # The global cap: every executor of every company together, plus the daemon itself.
  sudo -n systemctl set-property "user-${uid}.slice" "${CI_CAP[@]}" ||
    { echo "ERROR: systemctl set-property user-${uid}.slice failed." >&2; return 1; }
  echo "cap of user-${uid}.slice: $(systemctl show "user-${uid}.slice" -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax | tr '\n' ' ')"

  sudo -n env DOCKER_HOST="unix://${sock}" docker pull --quiet "${image}" ||
    { echo "ERROR: the executor image could not be pulled into the rootless daemon." >&2; return 1; }
  ci_executor_selftest "unix://${sock}" "${image}" "${CI_EXECUTOR_RUN_ARGS_DEFAULT}" || return 1
  ci_socket_check "${sock}" "${ci_image}" || return 1
  ci_write_marker "${sock}" rootless "${uid}" || { echo "ERROR: ${CI_MARKER_FILE} could not be written." >&2; return 1; }
}

# Gives ci-sandbox 65536 subordinate uids and gids once (its user namespace).
ci_ensure_subids() {
  local file start option
  for file in /etc/subuid /etc/subgid; do
    if grep -q "^${CI_SANDBOX_USER}:" "${file}" 2>/dev/null; then
      echo "${file}: ${CI_SANDBOX_USER} has a range"
      continue
    fi
    # The first id after all existing ranges, at least 100000 (as useradd does).
    start="$(awk -F: 'BEGIN { m = 100000 } NF >= 3 { e = $2 + $3; if (e > m) m = e } END { print m }' "${file}" 2>/dev/null || echo 100000)"
    option=--add-subuids
    [[ "${file}" == /etc/subuid ]] || option=--add-subgids
    sudo -n usermod "${option}" "${start}-$((start + 65535))" "${CI_SANDBOX_USER}" || return 1
    echo "${file}: added ${start}-$((start + 65535)) for ${CI_SANDBOX_USER}"
  done
}

# The fallback: executors on the main daemon, in code-exec.slice with the global cap.
ci_main_socket_setup() {
  local image="$1" ci_image="$2" driver code=0
  section "executors on the main Docker daemon (main-socket)"
  ci_main_socket_warning
  driver="$(dk info --format '{{.CgroupDriver}}' 2>/dev/null || true)"
  [[ "${driver}" == systemd ]] ||
    { echo "ERROR: the main daemon uses the cgroup driver '${driver}'. --cgroup-parent=code-exec.slice needs the systemd driver." >&2; return 1; }
  write_root_file /etc/systemd/system/code-exec.slice "$(printf '%s\n' '[Unit]' \
    'Description=Code Interpreter executor containers (22nd X AI)' 'Before=slices.target' '' '[Slice]' "${CI_CAP[@]}")" || code=$?
  ((code != 2)) || { echo "ERROR: code-exec.slice could not be written." >&2; return 1; }
  if ((code == 0)); then
    sudo -n systemctl daemon-reload || return 1
  fi
  sudo -n systemctl start code-exec.slice || { echo "ERROR: code-exec.slice does not start." >&2; return 1; }
  echo "cap of code-exec.slice: $(systemctl show code-exec.slice -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax | tr '\n' ' ')"
  dk pull --quiet "${image}" >/dev/null || { echo "ERROR: the executor image could not be pulled." >&2; return 1; }
  ci_executor_selftest unix:///var/run/docker.sock "${image}" \
    "${CI_EXECUTOR_RUN_ARGS_DEFAULT} ${CI_CGROUP_PARENT_ARG}" || return 1
  ci_socket_check /var/run/docker.sock "${ci_image}" || return 1
  ci_write_marker /var/run/docker.sock main-socket "" || { echo "ERROR: ${CI_MARKER_FILE} could not be written." >&2; return 1; }
}

# The python code of the executor test run: uid, network, and the limits in its cgroup.
readonly CI_SELFTEST_CODE='import os, socket
path = open("/proc/self/cgroup").read().strip().split("::", 1)[-1]
limits = []
for name in ("memory.max", "cpu.max", "pids.max"):
    try:
        limits.append(name + "=" + open("/sys/fs/cgroup" + path + "/" + name).read().strip().replace(" ", "/"))
    except OSError:
        limits.append(name + "=unreadable")
try:
    socket.create_connection(("1.1.1.1", 80), 3).close()
    network = "open"
except OSError:
    network = "blocked"
print("uid=%d network=%s %s" % (os.getuid(), network, " ".join(limits)))'

# One executor run with the docker run flags of the code interpreter (0.4.7) and <run args>
# on <docker host>. Fails on a Docker warning (a discarded limit), a wrong uid, an open
# network, or a limit in the cgroup that differs from the flags.
ci_executor_selftest() {
  local host="$1" image="$2" run_args="$3" out err_file errors="" expected
  local -a extra=()
  read -r -a extra <<<"${run_args}"
  section "executor test run on ${host}"
  err_file="$(mktemp)" || return 1
  out="$(sudo -n env DOCKER_HOST="${host}" docker run --rm --pull never --network none --cgroupns host \
    --pids-limit 64 --security-opt no-new-privileges --cap-drop ALL --cap-add CHOWN \
    --user 65532:65532 --tmpfs /tmp:rw,size=64m --ulimit cpu=60:60 --memory 512m --memory-swap 512m \
    "${extra[@]}" "${image}" python -c "${CI_SELFTEST_CODE}" 2>"${err_file}")" ||
    errors="docker run failed: $(tail -n 5 "${err_file}")"
  if [[ -z "${errors}" ]] && grep -qi 'warning' "${err_file}"; then
    errors="Docker warned (a limit may be discarded): $(grep -i 'warning' "${err_file}" | head -n 3)"
  fi
  rm -f "${err_file}"
  echo "executor: ${out:-no output}"
  if [[ -z "${errors}" ]]; then
    [[ "${out}" == *"uid=65532 "* ]] || errors="the executor does not run as uid 65532"
    [[ "${out}" == *"network=blocked"* ]] || errors+="${errors:+; }the executor has network access"
    for expected in memory.max=536870912 cpu.max=100000/100000 pids.max=64; do
      if [[ "${out}" == *"${expected%%=*}=unreadable"* ]]; then
        echo "note: ${expected%%=*} is not visible inside the executor; the check relies on the Docker warnings."
      elif [[ "${out}" != *"${expected}"* ]]; then
        errors+="${errors:+; }${expected%%=*} is not ${expected#*=}"
      fi
    done
  fi
  if [[ -n "${errors}" ]]; then
    echo "ERROR: executor test run on ${host}: ${errors}" >&2
    return 1
  fi
  echo "The executor test run passed: uid 65532, no network, memory 512m, 1 CPU, 64 pids."
}

# A container on the main daemon reaches <socket> as root through a bind mount, as the code
# interpreter container does. The mount never creates the path.
ci_socket_check() {
  local sock="$1" ci_image="$2" out
  section "executor socket from a container on the main daemon"
  dk pull --quiet "${ci_image}" >/dev/null || { echo "ERROR: ${ci_image} could not be pulled." >&2; return 1; }
  out="$(dk run --rm --network none --user root --entrypoint docker \
    --mount "type=bind,source=${sock},target=/var/run/docker.sock" "${ci_image}" \
    version --format '{{.Server.Version}} {{.Server.Os}}' 2>&1)" ||
    { echo "ERROR: the code interpreter image cannot reach ${sock}: ${out}" >&2; return 1; }
  echo "The code interpreter image reaches the executor daemon through ${sock} (Docker ${out})."
}

# Writes the marker atomically. No secrets: paths, the mode and the cap.
ci_write_marker() {
  local sock="$1" mode="$2" uid="$3" tmp
  tmp="$(mktemp "${ONYX_DEPLOY_DIR}/.ci-executor.env.XXXXXX")" || return 1
  {
    echo "# Written by vm-bootstrap.sh ci-host-setup on $(date -u +%FT%TZ). Read by saas_prepare and ci-cleanup.sh."
    echo "DOCKER_SOCK_PATH=${sock}"
    echo "EXECUTOR_MODE=${mode}"
    echo "EXECUTOR_UID=${uid}"
    echo "EXECUTOR_CAP=\"${CI_CAP[*]}\""
  } >"${tmp}" || { rm -f "${tmp}"; return 1; }
  chmod 644 "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${CI_MARKER_FILE}" || { rm -f "${tmp}"; return 1; }
  echo "Wrote ${CI_MARKER_FILE}: DOCKER_SOCK_PATH=${sock} EXECUTOR_MODE=${mode}"
}

# Installs ci-cleanup.sh (root-owned) and its systemd service and timer (every 5 minutes),
# and runs it once.
ci_cleanup_install() {
  local src="${ONYX_SRC_DIR}/product/deploy/tools/ci-cleanup.sh" reload=0 code
  section "cleanup timer (ci-cleanup.timer, every 5 minutes)"
  [[ -s "${src}" ]] || { echo "ERROR: ${src} is missing at this commit." >&2; return 1; }
  bash -n "${src}" || return 1
  sudo -n install -d -o root -g root -m 755 "$(dirname "${CI_CLEANUP_BIN}")" || return 1
  sudo -n install -o root -g root -m 755 "${src}" "${CI_CLEANUP_BIN}" || return 1
  code=0
  write_root_file /etc/systemd/system/ci-cleanup.service "$(printf '%s\n' '[Unit]' \
    'Description=Clean up after the Code Interpreter (22nd X AI)' 'After=docker.service' '' \
    '[Service]' 'Type=oneshot' "Environment=CI_EXECUTOR_MARKER=${CI_MARKER_FILE}" \
    "Environment=CI_VM_LOCK=${VM_LOCK_FILE}" "ExecStart=${CI_CLEANUP_BIN}" 'Nice=10')" || code=$?
  ((code != 2)) || return 1
  ((code != 0)) || reload=1
  code=0
  write_root_file /etc/systemd/system/ci-cleanup.timer "$(printf '%s\n' '[Unit]' \
    'Description=Run ci-cleanup.service every 5 minutes' '' '[Timer]' 'OnBootSec=5min' \
    'OnUnitActiveSec=5min' 'AccuracySec=30s' '' '[Install]' 'WantedBy=timers.target')" || code=$?
  ((code != 2)) || return 1
  ((code != 0)) || reload=1
  if ((reload)); then
    sudo -n systemctl daemon-reload || return 1
  fi
  sudo -n systemctl enable --now ci-cleanup.timer || return 1
  echo "first run of ci-cleanup.service:"
  if ! sudo -n systemctl start ci-cleanup.service; then
    sudo -n journalctl -u ci-cleanup.service -n 20 --no-pager -o cat >&2 || true
    return 1
  fi
  sudo -n journalctl -u ci-cleanup.service -n 6 --no-pager -o cat || true
}

# ---------------------------------------------------------------- saas-rotate-key

saas_rotate_key_wrapper() {
  local sha="${1:-}" mode="${2:-}"
  check_sha "${sha}"
  [[ -z "${mode}" || "${mode}" == dry-run ]] || die "The second argument must be dry-run or empty."
  with_evidence saas-rotate-key saas_rotate_key_action "${sha}" "${mode}"
}

saas_rotate_key_action() {
  local sha="$1" mode="$2"
  section "vm-bootstrap saas-rotate-key ${sha} $(date -u +%FT%TZ) (mode=${mode:-apply})"
  docker_setup
  saas_must_serve
  saas_rotate_key "${mode}" || die "The platform key rotation failed."
}

# Replaces every old platform key (the fingerprints in KEY_FINGERPRINTS_FILE) with the
# FIREWORKS_DEFAULT_API_KEY of the running api_server, in the provider rows of every
# tenant. The fingerprints file is on the host: it reaches the container through stdin
# (--fingerprints-file /dev/stdin). No key appears in the log; the output has counts.
saas_rotate_key() {
  local -a args=(--rotate-platform-key --fingerprints-file /dev/stdin)
  [[ "${1:-}" != dry-run ]] || args+=(--dry-run)
  section "platform key rotation (onyx.axi.backfill ${args[*]})"
  if [[ ! -s "${KEY_FINGERPRINTS_FILE}" ]]; then
    echo "ERROR: ${KEY_FINGERPRINTS_FILE} is missing or empty: no old key is known." >&2
    return 1
  fi
  echo "old key fingerprints in ${KEY_FINGERPRINTS_FILE}: $(grep -cE '^[0-9a-f]{64}$' "${KEY_FINGERPRINTS_FILE}" || true)"
  saas_key_presence
  saas_compose exec -T api_server python -m onyx.axi.backfill "${args[@]}" <"${KEY_FINGERPRINTS_FILE}"
}

# ---------------------------------------------------------------- saas-backup

# The newest backup folder of saas-backup, set by saas_backup.
SAAS_LAST_BACKUP=""

saas_backup_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence saas-backup saas_backup_action "${sha}"
}

saas_backup_action() {
  local sha="$1"
  section "vm-bootstrap saas-backup ${sha} $(date -u +%FT%TZ)"
  docker_setup
  saas_must_serve
  checkout_source "${sha}" || die "The checkout of ${sha} failed. Nothing was changed."
  saas_backup "${sha}" || die "The backup of ${SAAS_PROJECT} failed."
  section "saas-backup complete: ${SAAS_LAST_BACKUP}"
}

# Prints the free space of the file system of <path> in kB.
disk_free_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Cold backup of onyx-saas into BACKUP_ROOT/<time>-saas (backup.sh) with extra/: the
# per-tenant manifest, the compose files, the tool configs, images.txt, source-sha,
# deployed.env, the journey state and the key fingerprints (never account-transfer.json).
# The application services stop first, so that the manifest matches the copied volumes.
# Downtime: about 2 minutes. The newest SAAS_BACKUP_KEEP *-saas backups stay.
saas_backup() {
  local sha="$1" backup_dir extra free_kb
  docker info >/dev/null 2>&1 ||
    { echo "ERROR: docker does not work without sudo. backup.sh needs it. Log in again after the install action." >&2; return 1; }
  saas_compose_files_present || { echo "ERROR: the files in ${SAAS_COMPOSE_DIR} are missing." >&2; return 1; }
  backup_dir="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-saas"
  section "cold backup of ${SAAS_PROJECT} into ${backup_dir}"
  echo "Expected downtime: about 2 minutes. nginx, api_server, background and web_server stop for the manifest; backup.sh stops the rest, copies the volumes and starts the stack again."
  free_kb="$(disk_free_kb "${BACKUP_ROOT}")"
  [[ "${free_kb}" =~ ^[0-9]+$ ]] || { echo "ERROR: the free space of ${BACKUP_ROOT} is unknown." >&2; return 1; }
  echo "free space in ${BACKUP_ROOT}: $((free_kb / 1024)) MiB (backup.sh checks the exact need before the stop)"
  ((free_kb >= SAAS_MIN_FREE_KB)) ||
    { echo "ERROR: less than $((SAAS_MIN_FREE_KB / 1024)) MiB free in ${BACKUP_ROOT}. Nothing was stopped." >&2; return 1; }
  extra="$(mktemp -d "${BACKUP_ROOT}/.saas-extra.XXXXXX")" || return 1
  if ! saas_backup_extra "${sha}" "${extra}"; then
    rm -rf "${extra}"
    echo "ERROR: the extra files or the manifest failed. Starting the stopped services again." >&2
    saas_compose start || true
    return 1
  fi
  if ! BACKUP_EXTRA_DIR="${extra}" "${ONYX_SRC_DIR}/product/deploy/backup.sh" "${SAAS_COMPOSE_DIR}" "${backup_dir}" "${SAAS_PROJECT}"; then
    rm -rf "${extra}"
    echo "ERROR: backup.sh failed. Starting the stopped services again." >&2
    saas_compose start || true
    return 1
  fi
  rm -rf "${extra}"
  verify_backup "${backup_dir}"
  wait_health "${SAAS_URL}" || return 1
  saas_prune_backups
  SAAS_LAST_BACKUP="${backup_dir}"
  echo "Backup: ${backup_dir} (holds .env with secrets; copy it off the VM)."
}

# Fills <extra> and writes the manifest after the application services stop.
saas_backup_extra() {
  local sha="$1" extra="$2" file
  for file in "${SAAS_COMPOSE_FILES[@]}"; do
    cp "${SAAS_COMPOSE_DIR}/${file}" "${extra}/" || return 1
  done
  mkdir -p "${extra}/tools" || return 1
  for file in "${SAAS_TOOLS_FILES[@]}"; do
    cp "${SAAS_COMPOSE_DIR}/tools/${file}" "${extra}/tools/" || return 1
  done
  saas_compose images >"${extra}/images.txt" || return 1
  echo "${sha}" >"${extra}/source-sha" || return 1
  [[ ! -f "${SAAS_DEPLOYED_FILE}" ]] || cp "${SAAS_DEPLOYED_FILE}" "${extra}/" || return 1
  [[ ! -f "${SAAS_JOURNEY_STATE_FILE}" ]] || cp "${SAAS_JOURNEY_STATE_FILE}" "${extra}/" || return 1
  [[ ! -f "${KEY_FINGERPRINTS_FILE}" ]] || install -m 600 "${KEY_FINGERPRINTS_FILE}" "${extra}/" || return 1
  section "stopping the application services (manifest of the data that the backup copies)"
  saas_compose stop nginx api_server background web_server || return 1
  saas_manifest saas_psql >"${extra}/manifest.tsv" || return 1
  [[ -s "${extra}/manifest.tsv" ]] || return 1
  echo "manifest: $(grep -c . "${extra}/manifest.tsv") rows, $(cut -f1 "${extra}/manifest.tsv" | sort -u | grep -c '^tenant_' || true) tenant schemas"
}

# Prints the manifest through <psql function>: one row per tenant schema and item
# (schema TAB item TAB value). The items are row counts, and the server_enabled values of
# code_interpreter_server. A missing table gives "missing".
saas_manifest() {
  "$1" <<'SQL'
\pset fieldsep '\t'
SELECT q FROM (
  SELECT 0 AS o, '' AS s, '' AS l,
    'SELECT ''public'', ''user_tenant_mapping'', count(*)::text FROM public.user_tenant_mapping' AS q
  UNION ALL
  SELECT 1, n.nspname, m.label,
    CASE WHEN to_regclass(format('%I.%I', n.nspname, m.tbl)) IS NULL
      THEN format('SELECT %L, %L, %L', n.nspname, m.label, 'missing')
      ELSE format('SELECT %L, %L, (%s)::text FROM %I.%I', n.nspname, m.label, m.expr, n.nspname, m.tbl)
    END
  FROM pg_namespace AS n
  CROSS JOIN (VALUES
    ('user', 'users', 'count(*)'),
    ('chat_session', 'chat_session', 'count(*)'),
    ('chat_message', 'chat_message', 'count(*)'),
    ('document', 'document', 'count(*)'),
    ('user_file', 'user_file', 'count(*)'),
    ('llm_provider', 'llm_provider', 'count(*)'),
    ('internet_search_provider', 'internet_search_provider', 'count(*)'),
    ('code_interpreter_server', 'code_interpreter_server_enabled',
      'coalesce(string_agg(server_enabled::text, '','' ORDER BY id), ''none'')'),
    ('key_value_store', 'key_value_store', 'count(*)')
  ) AS m (tbl, label, expr)
  WHERE n.nspname LIKE 'tenant\_%'
) AS g ORDER BY o, s, l
\gexec
SQL
}

# Removes the oldest *-saas backups; the newest SAAS_BACKUP_KEEP stay.
saas_prune_backups() {
  local dir
  find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}T[0-9]{6}Z-saas' | sort | head -n "-${SAAS_BACKUP_KEEP}" |
    while IFS= read -r dir; do
      if rm -rf "${dir}"; then
        echo "Removed the old backup ${dir}."
      else
        echo "WARNING: could not remove the old backup ${dir}." >&2
      fi
    done
}

# ---------------------------------------------------------------- saas-restore-test

# State of saas_restore_test for on_saas_restore_test_exit.
SAAS_RESTORE_TOOLS_STOPPED=0
SAAS_RESTORE_IDS_BEFORE=""
SAAS_RESTORE_PASSED=0

saas_restore_guard() {
  [[ "${SAAS_RESTORE_PROJECT}" == onyx-saas-restore && "${SAAS_RESTORE_DIR}" == */onyx-saas-restore ]] ||
    die "The restore copy must be project onyx-saas-restore in a folder onyx-saas-restore."
}

saas_restore_compose() {
  saas_restore_guard
  stack_compose "${SAAS_RESTORE_PROJECT}" "${SAAS_RESTORE_COMPOSE_DIR}" "$(join_colon "${SAAS_RESTORE_FILES[@]}")" "$@"
}

# Like saas_psql, in the database of the copy.
saas_restore_psql() {
  local env_file="${SAAS_RESTORE_COMPOSE_DIR}/.env" user db
  user="$(stack_env_value "${env_file}" POSTGRES_USER)"
  db="$(stack_env_value "${env_file}" POSTGRES_DB)"
  saas_restore_compose exec -T relational_db psql -U "${user:-postgres}" -d "${db:-postgres}" \
    -v ON_ERROR_STOP=1 -qAt -f -
}

saas_newest_backup() {
  find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{8}T[0-9]{6}Z-saas' 2>/dev/null | sort | tail -n 1
}

saas_restore_test_wrapper() {
  local sha="${1:-}" backup="${2:-}"
  check_sha "${sha}"
  [[ -z "${backup}" || "${backup}" =~ ^${BACKUP_ROOT}/[A-Za-z0-9_.-]+$ ]] ||
    die "The backup folder must be one folder name under ${BACKUP_ROOT}."
  with_evidence saas-restore-test saas_restore_test "${sha}" "${backup}"
}

# Restores a *-saas backup (the newest, or <backup folder>) into the copy onyx-saas-restore
# on 127.0.0.1:3300 and checks it: the manifest of the copy equals the manifest of the
# backup, and the journey read checks pass on the copy (--after-restart --no-chat). The tool
# services of onyx-saas stop for the test (memory); the exit handler removes the copy,
# starts them again and checks that the production containers and the public URL are as
# before. The last line is RESULT=restore-test-passed or RESULT=restore-test-failed.
saas_restore_test() {
  local sha="$1" backup="$2" state tag journey="${ONYX_SRC_DIR}/product/test-corpus/saas_journey.py"
  trap 'on_saas_restore_test_exit' EXIT
  section "vm-bootstrap saas-restore-test ${sha} $(date -u +%FT%TZ)"
  saas_restore_guard
  docker info >/dev/null 2>&1 || die "docker does not work without sudo. restore.sh needs it."
  docker_setup
  saas_must_serve
  checkout_source "${sha}" || die "The checkout of ${sha} failed. Nothing was changed."
  [[ -f "${journey}" ]] || die "${journey} is missing at this commit. Nothing was changed."
  [[ -n "${backup}" ]] || backup="$(saas_newest_backup)"
  [[ -n "${backup}" && -d "${backup}" ]] || die "No *-saas backup in ${BACKUP_ROOT}. Run saas-backup first."
  echo "Backup: ${backup}"
  saas_restore_gates "${backup}"
  SAAS_RESTORE_IDS_BEFORE="$(dk ps -aq --no-trunc --filter "label=com.docker.compose.project=${SAAS_PROJECT}" | sort)"
  saas_restore_remove_copy || die "The leftovers of an earlier copy could not be removed."

  section "stopping the tool services of ${SAAS_PROJECT} (${SAAS_TOOL_SERVICES[*]})"
  echo "Chats that use the Code Interpreter or web search fail until this test ends (about 10 to 20 minutes)."
  SAAS_RESTORE_TOOLS_STOPPED=1
  saas_compose stop "${SAAS_TOOL_SERVICES[@]}" || die "The tool services could not be stopped."
  saas_restore_memory_gate
  saas_restore_prepare "${sha}" || die "The folder ${SAAS_RESTORE_DIR} could not be prepared."

  section "restore.sh into project ${SAAS_RESTORE_PROJECT} (${SAAS_RESTORE_URL})"
  COMPOSE_FILE="$(join_colon "${SAAS_RESTORE_FILES[@]}")" COMPOSE_PROFILES=s3-filestore \
    HOST_PORT="${SAAS_RESTORE_PORT}" RESTORE_EXTRA_SECRETS=DB_READONLY_PASSWORD \
    "${ONYX_SRC_DIR}/product/deploy/restore.sh" "${backup}" "${SAAS_RESTORE_COMPOSE_DIR}" "${SAAS_RESTORE_PROJECT}" ||
    die "restore.sh failed."
  wait_health "${SAAS_RESTORE_URL}" || die "The copy is not healthy at ${SAAS_RESTORE_URL}."
  show "docker compose ps (${SAAS_RESTORE_PROJECT})" saas_restore_compose ps --format '{{.Name}} {{.Status}}'

  section "manifest of the copy against the manifest of the backup"
  cp "${backup}/extra/manifest.tsv" "${EVIDENCE_DIR}/backup-manifest.tsv" || die "The manifest of the backup could not be copied."
  saas_manifest saas_restore_psql >"${EVIDENCE_DIR}/restore-manifest.tsv" || die "The manifest of the copy could not be read."
  if ! diff -u "${EVIDENCE_DIR}/backup-manifest.tsv" "${EVIDENCE_DIR}/restore-manifest.tsv"; then
    die "The manifest of the copy differs from the manifest of the backup (see the diff above)."
  fi
  echo "The manifests are identical ($(grep -c . "${EVIDENCE_DIR}/restore-manifest.tsv") rows)."

  section "customer journey read checks on the copy (saas_journey.py --after-restart --no-chat)"
  state="${EVIDENCE_DIR}/restore-journey-state.json"
  install -m 600 "${backup}/extra/journey_state.json" "${state}" || die "The journey state of the backup could not be copied."
  tag="$(json_value "${state}" tag)"
  [[ "${tag}" =~ ^[a-z0-9][a-z0-9-]{0,23}$ ]] || die "The journey state of the backup has no valid tag."
  echo "Tag of the backup's journey: ${tag}"
  MT_PASSWORD_SALT="$(cat "${SAAS_JOURNEY_SALT_FILE}")" python3 "${journey}" --base-url "${SAAS_RESTORE_URL}" \
    --tag "${tag}" --state "${state}" --after-restart --no-chat ||
    die "The journey read checks failed on the copy."
  SAAS_RESTORE_PASSED=1
}

# Checks that change nothing: files, checksums, release, salt, port and disk.
saas_restore_gates() {
  local backup="$1" file tag release root free_kb used_kb needed_kb
  section "gates (nothing is changed before they pass)"
  for file in SHA256SUMS env.backup db_volume.tar.gz opensearch-data.tar.gz minio_data.tar.gz \
    file-system.tar.gz extra/manifest.tsv extra/journey_state.json; do
    [[ -f "${backup}/${file}" ]] || die "${backup}/${file} is missing. Nothing was changed."
  done
  (cd "${backup}" && sha256sum -c --quiet --strict SHA256SUMS) || die "The checksums of ${backup} do not pass. Nothing was changed."
  echo "files: present; SHA256SUMS passes"
  tag="$(stack_env_value "${backup}/env.backup" IMAGE_TAG)"
  release="$(release_value ONYX_RELEASE_TAG)"
  [[ -n "${tag}" && "${tag}" == "${release}" ]] ||
    die "The backup is of release ${tag:-unknown}; this commit pins ${release}. Nothing was changed."
  echo "release: ${tag}"
  [[ -s "${SAAS_JOURNEY_SALT_FILE}" ]] || die "${SAAS_JOURNEY_SALT_FILE} is missing. Nothing was changed."
  [[ -z "$(ss -ltnH "sport = :${SAAS_RESTORE_PORT}" 2>/dev/null)" ]] ||
    die "Port ${SAAS_RESTORE_PORT} is in use. Nothing was changed."
  echo "port ${SAAS_RESTORE_PORT}: free"
  root="$(dk info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  free_kb="$(disk_free_kb "${root:-/var/lib/docker}")"
  [[ "${free_kb}" =~ ^[0-9]+$ ]] || free_kb="$(disk_free_kb /)"
  used_kb="$(du -sk "${backup}" | cut -f1)"
  needed_kb=$((used_kb * 3 + SAAS_MIN_FREE_KB))
  [[ "${free_kb}" =~ ^[0-9]+$ ]] || die "The free disk space is unknown. Nothing was changed."
  echo "disk: $((free_kb / 1024)) MiB free for Docker; the copy needs about $((needed_kb / 1024)) MiB (3 x backup + 5 GiB)"
  ((free_kb >= needed_kb)) || die "Not enough disk space for the copy. Nothing was changed."
}

# MemAvailable after the tool services stopped. The handler starts them again.
saas_restore_memory_gate() {
  local available
  section "memory before the copy starts"
  free -m
  available="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
  [[ "${available}" =~ ^[0-9]+$ ]] || die "MemAvailable is not in /proc/meminfo."
  echo "MemAvailable: $((available / 1024)) MiB. The copy needs $((SAAS_RESTORE_MIN_AVAILABLE_KB / 1024)) MiB."
  ((available >= SAAS_RESTORE_MIN_AVAILABLE_KB)) ||
    die "Only $((available / 1024)) MiB of memory is available. The copy was not started. Run the test when the executors are idle."
}

# An empty restore folder with the release files, compose.saas.yml and compose.restore.yml.
saas_restore_prepare() {
  local sha="$1"
  if [[ ! -d "${SAAS_RESTORE_DIR}" ]]; then
    sudo -n install -d -o "$(id -un)" -g "$(id -gn)" "${SAAS_RESTORE_DIR}" || return 1
  fi
  saas_restore_clear_folder || return 1
  mkdir -p "${SAAS_RESTORE_COMPOSE_DIR}" || return 1
  export_release_files "${SAAS_RESTORE_COMPOSE_DIR}" "${sha}" || return 1
  export_overlay "${sha}" product/deploy/mt/compose.saas.yml "${SAAS_RESTORE_COMPOSE_DIR}" || return 1
  export_overlay "${sha}" product/deploy/mt/compose.restore.yml "${SAAS_RESTORE_COMPOSE_DIR}" || return 1
  [[ ! -e "${SAAS_RESTORE_COMPOSE_DIR}/.env" ]] || return 1
}

# Empties the restore folder: the restored .env holds the production secrets.
saas_restore_clear_folder() {
  saas_restore_guard
  [[ -d "${SAAS_RESTORE_DIR}" ]] || return 0
  find "${SAAS_RESTORE_DIR}" -mindepth 1 -delete 2>/dev/null ||
    sudo -n find "${SAAS_RESTORE_DIR}" -mindepth 1 -delete
}

# Removes the containers (with their anonymous volumes), the volumes and the networks of
# project onyx-saas-restore, found by the Compose label; every volume must also carry the
# name prefix. It touches nothing of onyx-saas or onyx.
saas_restore_remove_copy() {
  local containers volumes volume networks
  saas_restore_guard
  ((${#DOCKER_CMD[@]})) || return 0
  containers="$(stack_containers "${SAAS_RESTORE_PROJECT}")" || return 1
  [[ -z "${containers}" ]] || xargs -r "${DOCKER_CMD[@]}" rm -f -v <<<"${containers}" >/dev/null || return 1
  volumes="$(dk volume ls -q --filter "label=com.docker.compose.project=${SAAS_RESTORE_PROJECT}")" || return 1
  while IFS= read -r volume; do
    [[ -z "${volume}" || "${volume}" == "${SAAS_RESTORE_PROJECT}_"* ]] || {
      echo "ERROR: volume ${volume} has the label of ${SAAS_RESTORE_PROJECT} but not its name prefix. Nothing more is removed." >&2
      return 1
    }
  done <<<"${volumes}"
  [[ -z "${volumes}" ]] || xargs -r "${DOCKER_CMD[@]}" volume rm <<<"${volumes}" >/dev/null || return 1
  networks="$(dk network ls -q --filter "label=com.docker.compose.project=${SAAS_RESTORE_PROJECT}")" || return 1
  [[ -z "${networks}" ]] || xargs -r "${DOCKER_CMD[@]}" network rm <<<"${networks}" >/dev/null || return 1
  echo "Project ${SAAS_RESTORE_PROJECT} has no containers, volumes or networks."
}

# Waits until ci-gateway is healthy (its health check reaches the code interpreter through
# the proxy), then runs the basic probes from api_server.
saas_wait_tools() {
  local cid health="" deadline=$((SECONDS + 300))
  cid="$(saas_compose ps -q ci-gateway 2>/dev/null | head -n 1)"
  [[ -n "${cid}" ]] || { echo "ERROR: ci-gateway has no running container." >&2; return 1; }
  until [[ "${health}" == healthy ]]; do
    ((SECONDS < deadline)) || { echo "ERROR: ci-gateway is not healthy after 300 s (${health:-unknown})." >&2; return 1; }
    sleep 10
    health="$(dk inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${cid}" 2>/dev/null || true)"
  done
  echo "ci-gateway is healthy."
  saas_tool_probes basic
}

on_saas_restore_test_exit() {
  local code=$? ok=1 ids_after url_code
  trap - EXIT
  ((code == 0 && SAAS_RESTORE_PASSED)) || ok=0
  section "cleanup: the copy ${SAAS_RESTORE_PROJECT}"
  if ((${#DOCKER_CMD[@]})); then
    saas_restore_remove_copy || { echo "ERROR: the copy could not be removed completely." >&2; ok=0; }
  fi
  saas_restore_clear_folder || { echo "ERROR: ${SAAS_RESTORE_DIR} could not be emptied (it holds a .env with secrets)." >&2; ok=0; }
  if ((SAAS_RESTORE_TOOLS_STOPPED)); then
    section "starting the tool services of ${SAAS_PROJECT} again"
    saas_compose start "${SAAS_TOOL_SERVICES[@]}" || { echo "ERROR: the tool services did not start." >&2; ok=0; }
    saas_wait_tools || ok=0
  fi
  if [[ -n "${SAAS_RESTORE_IDS_BEFORE}" ]]; then
    section "production checks"
    ids_after="$(dk ps -aq --no-trunc --filter "label=com.docker.compose.project=${SAAS_PROJECT}" | sort)"
    if [[ "${ids_after}" == "${SAAS_RESTORE_IDS_BEFORE}" ]]; then
      echo "The container IDs of ${SAAS_PROJECT} are unchanged ($(grep -c . <<<"${ids_after}") containers)."
    else
      echo "ERROR: the container IDs of ${SAAS_PROJECT} changed during the test." >&2
      ok=0
    fi
    url_code="$(http_code "${SAAS_URL}/api/health")"
    if [[ "${url_code}" == 200 ]]; then
      echo "${SAAS_URL}/api/health answers 200."
    else
      echo "ERROR: ${SAAS_URL}/api/health answers ${url_code}." >&2
      ok=0
    fi
  fi
  if ((ok)); then
    echo "RESULT=restore-test-passed"
    exit 0
  fi
  echo "RESULT=restore-test-failed"
  exit 1
}

# ---------------------------------------------------------------- saas-tools-check

saas_tools_check_wrapper() {
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence saas-tools-check saas_tools_check "${sha}"
}

# The service isolation probes from api_server, then tools_check.py: it signs up a new
# company C (tag tools-<hex>) and tests the Code Interpreter and web search of the companies
# of the last saas-journey run.
saas_tools_check() {
  local sha="$1" tag tools="${ONYX_SRC_DIR}/product/test-corpus/tools_check.py"
  section "vm-bootstrap saas-tools-check ${sha} $(date -u +%FT%TZ)"
  docker_setup
  saas_must_serve
  checkout_source "${sha}" || die "The checkout of ${sha} failed."
  [[ -f "${tools}" ]] || die "${tools} is missing at this commit."
  [[ -f "${SAAS_JOURNEY_STATE_FILE}" ]] || die "${SAAS_JOURNEY_STATE_FILE} is missing. Run the saas-journey action first."
  [[ -s "${SAAS_JOURNEY_SALT_FILE}" ]] || die "${SAAS_JOURNEY_SALT_FILE} is missing. Run the saas-journey action first."
  saas_tool_probes isolation || die "The service isolation probes failed."
  tag="tools-$(openssl rand -hex 4)" || die "openssl rand failed."
  echo "Tag of company C: ${tag}"
  saas_reset_signup_limit
  section "tools_check.py (Code Interpreter and web search)"
  MT_PASSWORD_SALT="$(cat "${SAAS_JOURNEY_SALT_FILE}")" python3 "${tools}" --base-url "${SAAS_URL}" \
    --state "${SAAS_JOURNEY_STATE_FILE}" --tag "${tag}" --record "${EVIDENCE_DIR}/tools_state.json" ||
    die "tools_check.py failed."
  section "saas-tools-check complete"
}

main "$@"
