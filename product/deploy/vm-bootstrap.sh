#!/usr/bin/env bash
# Prepares and checks the development VM. axi-bootstrap-dev.yml pipes it over SSH.
# Usage: vm-bootstrap.sh inspect
#        vm-bootstrap.sh install <full commit SHA> <web domain>
#        vm-bootstrap.sh verify <full commit SHA> [with-chat]
#        vm-bootstrap.sh restart <full commit SHA>
#        vm-bootstrap.sh https <full commit SHA> <email> [staging]
# Layout on the VM: /srv/onyx-src (clone of the fork), /srv/onyx (release files, .env,
# evidence), /srv/backups. See product/deploy/RUNBOOK.md.
# The script never creates a second .env, never removes the live volumes and never
# prints a secret. It needs python3 and curl; both are present on Debian and Ubuntu.
set -euo pipefail

# VM_BOOTSTRAP_SRV_ROOT replaces /srv only in local tests of this script.
readonly SRV_ROOT="${VM_BOOTSTRAP_SRV_ROOT:-/srv}"
readonly ONYX_SRC_DIR="${SRV_ROOT}/onyx-src"
readonly ONYX_DEPLOY_DIR="${SRV_ROOT}/onyx"
readonly ONYX_RESTORE_DIR="${SRV_ROOT}/onyx-restore"
readonly BACKUP_ROOT="${SRV_ROOT}/backups"
readonly EVIDENCE_ROOT="${ONYX_DEPLOY_DIR}/evidence"
readonly USERS_FILE="${ONYX_DEPLOY_DIR}/test-users.env"
readonly COMPOSE_DIR="${ONYX_DEPLOY_DIR}/deployment/docker_compose"
readonly RESTORE_COMPOSE_DIR="${ONYX_RESTORE_DIR}/deployment/docker_compose"
readonly FORK_URL=https://github.com/ravi3594444/onyx1
readonly UPSTREAM_URL=https://github.com/onyx-dot-app/onyx
# set_live_url reads .env: port 80 with the HTTPS overlay, else HOST_PORT. PUBLIC_URL is
# the HTTPS URL of the stack when the overlay is active, else empty.
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
    *) die "usage: vm-bootstrap.sh inspect | install <sha> <web domain> | verify <sha> [with-chat] | restart <sha> | https <sha> <email> [staging]" ;;
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

# Reads a key from the live .env, or prints the default.
# With compose.https.yml in COMPOSE_FILE, nginx publishes only ports 80 and 443.
set_live_url() {
  if [[ "$(live_env_value COMPOSE_FILE "")" == *compose.https.yml* ]]; then
    # The checks run over loopback. check_public_url records the public HTTPS URL apart.
    LIVE_URL=http://localhost
    PUBLIC_URL="https://${DNS_NAME}"
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

main "$@"
