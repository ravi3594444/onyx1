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
#        vm-bootstrap.sh inventory <full commit SHA>
#        vm-bootstrap.sh cutover <full commit SHA> <letsencrypt email> | rollback <full commit SHA>
#        vm-bootstrap.sh saas-check <full commit SHA> [after-restart] | saas-restart <full commit SHA>
#        vm-bootstrap.sh saas-down <full commit SHA>
#        vm-bootstrap.sh assistant-prompt <full commit SHA> <set|reset|show> | chat-check <full commit SHA>
# Layout on the VM: /srv/onyx-src (clone of the fork), /srv/onyx (release files, .env,
# evidence), /srv/backups, /srv/onyx-mt (multi-tenant test stack), /srv/onyx-saas (multi-tenant
# production stack after the cutover). See product/deploy/RUNBOOK.md and docs/product/MULTI-TENANT.md.
# The script never creates a second .env for the live stack, never removes the live volumes
# and never prints a secret. It needs python3 and curl; both are present on Debian and Ubuntu.
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

main() {
  # Bash has read the whole script here. Nothing must read the piped script by mistake.
  exec </dev/null
  local action="${1:-}"
  shift || true
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
    saas-down) saas_down_wrapper "$@" ;;
    assistant-prompt) assistant_prompt_wrapper "$@" ;;
    chat-check) chat_check_wrapper "$@" ;;
    *) die "usage: vm-bootstrap.sh inspect | install <sha> <web domain> | verify <sha> [with-chat] | restart <sha> | https <sha> <email> [staging] | owner <sha> <email> <invite|-> <keep|on|off> | model <sha> <provider> <model|list> | smtp <sha> | keygen | mt-up <sha> | mt-check <sha> [after-restart] | mt-restart <sha> | mt-down | mt-destroy | inventory <sha> | cutover <sha> <email> | rollback <sha> | saas-check <sha> [after-restart] | saas-restart <sha> | saas-down <sha> | assistant-prompt <sha> <set|reset|show> | chat-check <sha>" ;;
  esac
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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
    git clone --filter=blob:none "${FORK_URL}" "${ONYX_SRC_DIR}"
  fi
  git -C "${ONYX_SRC_DIR}" fetch --quiet origin "${sha}"
  git -C "${ONYX_SRC_DIR}" checkout --quiet --detach "${sha}"
  git -C "${ONYX_SRC_DIR}" log -1 --format='%H %cI %s'
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
  git -C "${ONYX_SRC_DIR}" fetch --quiet --no-tags "${UPSTREAM_URL}" "refs/tags/${tag}:refs/tags/${tag}"
  [[ "$(git -C "${ONYX_SRC_DIR}" rev-parse "refs/tags/${tag}^{commit}")" == "${commit}" ]] ||
    die "Tag ${tag} is not commit ${commit}."
  mkdir -p "${compose_dir}"
  target="$(cd "${compose_dir}/../.." && pwd)"
  git -C "${ONYX_SRC_DIR}" archive "${tag}" deployment/docker_compose deployment/data | tar -x -C "${target}"
  git -C "${ONYX_SRC_DIR}" show "${sha}:product/deploy/compose.override.yml" >"${compose_dir}/compose.override.yml"
  echo "Exported ${tag} (${commit}) and compose.override.yml."
}

# Copies one compose overlay from the checkout at <sha> into <compose dir>.
export_overlay() {
  local sha="$1" path="$2" compose_dir="$3"
  git -C "${ONYX_SRC_DIR}" show "${sha}:${path}" >"${compose_dir}/$(basename "${path}")"
  echo "Exported $(basename "${path}")."
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
  checkout_source "${sha}"
  export_release_files "${MT_COMPOSE_DIR}" "${sha}"
  export_overlay "${sha}" product/deploy/mt/compose.saas.yml "${MT_COMPOSE_DIR}"
  export_overlay "${sha}" product/deploy/mt/compose.mt.yml "${MT_COMPOSE_DIR}"
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
# compose.https.yml comes last: its nginx ports, command and volumes win.
readonly SAAS_COMPOSE_FILES=(docker-compose.yml compose.override.yml compose.saas.yml compose.https.yml)
readonly SAAS_URL="https://${DNS_NAME}"
readonly SAAS_TAG_FILE="${SAAS_DIR}/saas-tag"
readonly SAAS_SALT_FILE="${SAAS_DIR}/saas-salt"
readonly SAAS_STATE_FILE="${SAAS_DIR}/mt_state.json"
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

# Runs mt_checks.py against the production stack. Mode: empty or after-restart. With
# secrets/model.env, the company checks also configure the model; the values stay in the env.
saas_run_checks() {
  (
    if [[ -f "${SECRETS_DIR}/model.env" ]]; then
      # shellcheck disable=SC1090,SC1091
      source "${SECRETS_DIR}/model.env"
      export MODEL_API_KEY="${MODEL_API_KEY:-}" MODEL_PROVIDER="${MODEL_PROVIDER:-}" \
        MODEL_NAME="${MODEL_NAME:-}" MODEL_API_BASE="${MODEL_API_BASE:-}"
      echo "model.env found: the company checks configure the model"
    else
      echo "No ${SECRETS_DIR}/model.env: the chat checks are skipped."
    fi
    stack_run_checks "${SAAS_URL}" "${SAAS_TAG_FILE}" "${SAAS_SALT_FILE}" "${SAAS_STATE_FILE}" saas "${1:-}"
  )
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
  local sha="${1:-}"
  check_sha "${sha}"
  with_evidence inventory inventory_live "${sha}"
}

# Runs one SQL statement in the live Postgres and prints the rows. Errors are silent.
live_sql() {
  live_compose exec -T relational_db psql -U "$(live_env_value POSTGRES_USER postgres)" \
    -d "$(live_env_value POSTGRES_DB postgres)" -v ON_ERROR_STOP=1 -At -c "$1" 2>/dev/null
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

# Read-only inventory of the live single-tenant stack before the cutover. The log shows
# counts only. The emails and connector names go to inventory.txt (mode 600) in the evidence folder.
inventory_live() {
  local sha="$1" report="${EVIDENCE_DIR}/inventory.txt" users_total
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
  live_count "admins (role = ADMIN)" "SELECT count(*) FROM \"user\" WHERE role = 'ADMIN'"
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

  section "detailed report"
  install -m 600 /dev/null "${report}"
  {
    echo "# inventory of the live stack, ${sha}, $(date -u +%FT%TZ)"
    echo "## users (email, role, is_active)"
    live_sql 'SELECT email, role, is_active FROM "user" ORDER BY email' ||
      live_sql 'SELECT email, is_active FROM "user" ORDER BY email' || echo "query failed"
    echo "## connectors (id, name, source)"
    live_sql 'SELECT id, name, source FROM connector ORDER BY id' || echo "query failed"
  } >>"${report}"
  echo "Written: ${report} (mode 600, holds the emails and connector names)."

  section "API counts"
  inventory_api || echo "API counts skipped (see above)."

  section "Needs recreation or manual transfer after cutover:"
  echo "- Accounts: ${users_total} in the live stack. Every account must sign up again on the new stack."
  echo "  The first sign-up of an email creates its company and makes it admin. Passwords are not copied."
  echo "- Connectors, documents, chats and files stay in the old volumes (project onyx). They are not migrated."
  echo "- The LLM provider and the settings must be configured again in each company."
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

# ----- cutover

cutover_wrapper() {
  local sha="${1:-}" email="${2:-}"
  check_sha "${sha}"
  is_email "${email}" || die "Give the Let's Encrypt account email (the one of the https action)."
  with_evidence cutover cutover "${sha}" "${email}"
}

# Moves the public URL from project onyx to project onyx-saas. Order: checks, cold backup,
# saas folder and .env, certificate copy, pull, stop onyx, start onyx-saas, health checks.
# A failed start stops onyx-saas and starts onyx again. onyx never gets "down"; its volumes stay.
# $2 is the Let's Encrypt email. The wrapper validates it; the account itself travels inside
# certbot/conf. The log never shows it.
cutover() {
  local sha="$1" backup_dir
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

  section "stopping the live stack (project onyx, volumes stay)"
  trap 'on_cutover_exit' EXIT
  CUTOVER_LIVE_STOPPED=1
  live_compose stop
  section "docker compose -p ${SAAS_PROJECT} up -d"
  saas_compose up -d
  wait_health "${SAAS_URL}" || die "${SAAS_PROJECT} is not healthy at ${SAAS_URL}."
  PUBLIC_URL="${SAAS_URL}"
  check_public_url || die "The public URL checks failed on ${SAAS_PROJECT}."
  CUTOVER_LIVE_STOPPED=0
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
    saas_compose stop || true
    live_compose start || true
    set_live_url
    wait_health "${LIVE_URL}" || echo "ERROR: the live stack is not healthy. Run the rollback action." >&2
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

# Creates the saas folder, exports the release files and the overlays, and writes .env once.
# Every run pins the domain, the compose files and the cloud web image.
saas_prepare() {
  local sha="$1" env_file="${SAAS_COMPOSE_DIR}/.env" cloud_image
  section "production multi-tenant folder ${SAAS_DIR}"
  if [[ ! -d "${SAAS_DIR}" ]]; then
    sudo -n install -d -o "$(id -un)" -g "$(id -gn)" "${SAAS_DIR}" || die "sudo -n cannot create ${SAAS_DIR}."
  fi
  export_release_files "${SAAS_COMPOSE_DIR}" "${sha}"
  export_overlay "${sha}" product/deploy/mt/compose.saas.yml "${SAAS_COMPOSE_DIR}"
  export_overlay "${sha}" product/deploy/compose.https.yml "${SAAS_COMPOSE_DIR}"
  cloud_image="$(release_value ONYX_WEB_SERVER_IMAGE_CLOUD)"
  [[ -n "${cloud_image}" ]] || die "ONYX_WEB_SERVER_IMAGE_CLOUD is missing in release.env."
  if [[ -f "${env_file}" ]]; then
    echo "${env_file} exists. The script keeps its secrets."
  else
    # New secrets. The live .env is never copied.
    "${ONYX_SRC_DIR}/product/deploy/make-env.sh" "${SAAS_COMPOSE_DIR}" "${SAAS_URL}"
  fi
  if cmp -s "${COMPOSE_DIR}/.env" "${env_file}"; then
    die "${env_file} is a copy of the live .env. Remove it; cutover then writes new secrets."
  fi
  chmod 600 "${env_file}"
  stack_env_pin "${env_file}" DOMAIN "${DNS_NAME}"
  stack_env_pin "${env_file}" WEB_DOMAIN "${SAAS_URL}"
  # The multi-tenant stack needs the web build with NEXT_PUBLIC_CLOUD_ENABLED=true.
  stack_env_pin "${env_file}" ONYX_WEB_SERVER_IMAGE "${cloud_image}"
  echo "Set DOMAIN, WEB_DOMAIN and ONYX_WEB_SERVER_IMAGE (cloud build) in ${env_file}."
  stack_env_pin_compose "${env_file}" "${SAAS_PROJECT}" "${SAAS_COMPOSE_FILES[@]}"
  stack_env_settings "${env_file}"
  saas_merge_secrets "${env_file}"
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
    set_env_key "${key}" "${value}" "${env_file}"
    keys+=" ${key}"
  done <"${file}"
  echo "Set from ${file} (values not shown):${keys}"
}

# Copies the Let's Encrypt files and the nginx redirect files of the live stack. The copies
# keep their owner (certbot writes as root). An existing certbot/conf copy stays as it is.
saas_copy_https_files() {
  local sha="$1"
  section "certificate and nginx files"
  mkdir -p "${SAAS_DATA_DIR}/certbot" "${SAAS_DATA_DIR}/nginx-extra"
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
  ls -la "${SAAS_DATA_DIR}/nginx-extra"
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

# Recreates the onyx-saas containers and repeats the read checks. "down" never gets -v.
saas_restart() {
  local sha="$1" volumes_before volumes_after
  section "vm-bootstrap saas-restart ${sha} $(date -u +%FT%TZ)"
  docker_setup
  saas_compose_files_present || die "The files in ${SAAS_COMPOSE_DIR} are missing. Run the cutover action first."
  [[ -f "${SAAS_STATE_FILE}" ]] || die "${SAAS_STATE_FILE} is missing. Run the saas-check action first."
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
  run_step saas-check-after-restart saas_run_checks after-restart
  saas_report
  summary
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

main "$@"
