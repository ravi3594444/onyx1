#!/usr/bin/env bash
# Enables HTTPS with Let's Encrypt for the Onyx Compose deployment (RUNBOOK.md, section 3a).
# Usage: product/deploy/enable-https.sh <deployment/docker_compose folder> <domain> <email>
# The script is idempotent. Run it again after a failure, or to check the setup.
# It changes only three keys in .env: DOMAIN, WEB_DOMAIN and COMPOSE_FILE.
# It copies compose.https.yml next to docker-compose.yml, so that nginx publishes ports 80
# and 443 only. Certificate issuance needs port 80 reachable from the internet.
# STAGING=1 requests a Let's Encrypt staging certificate (no rate limits, not trusted).
# The script never removes containers, volumes or other .env values.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_dir="$(cd "${1:?usage: enable-https.sh <deployment/docker_compose folder> <domain> <email>}" && pwd)"
domain="${2:?domain, for example kb.example.com}"
email="${3:?email for the certificate account}"
env_file="${compose_dir}/.env"
overlay="${compose_dir}/compose.https.yml"
certbot_dir="$(dirname "${compose_dir}")/data/certbot"
health_timeout="${HTTPS_HEALTH_TIMEOUT:-300}"
rsa_key_size=4096
# Upstream init-letsencrypt.sh uses this subject for the dummy certificate.
dummy_subject="/CN=localhost"
tls_params_url="https://raw.githubusercontent.com/certbot/certbot/master"
failed=0

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*" >&2
  failed=1
}
die() {
  echo "FAIL: $*" >&2
  exit 1
}
compose() { (cd "${compose_dir}" && docker compose "$@"); }
# Runs a shell command in the certbot service, which mounts ../data/certbot/conf.
# Certbot writes /etc/letsencrypt as root, so the host user cannot read it directly.
in_certbot() { compose run --rm --no-deps --entrypoint sh certbot -c "$1"; }

# Same rule as make-env.sh: replace the line (also a commented one), or append it.
set_env_value() {
  local key="$1" value="$2"
  if grep -qE "^#? ?${key}=" "${env_file}"; then
    sed -i -E "s|^#? ?${key}=.*|${key}=${value}|" "${env_file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${env_file}"
  fi
}
env_value() { sed -n -E "s/^${1}=//p" "${env_file}" | tail -n 1; }

# --- 1. Checks before any change --------------------------------------------------------------
[[ "${domain}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
  die "${domain} is not a lower-case DNS name with at least two labels."
[[ "${email}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "${email} is not an email address."
[[ -f "${compose_dir}/docker-compose.yml" ]] || die "${compose_dir} has no docker-compose.yml."
[[ -f "${env_file}" ]] || die "${env_file} is missing. Run product/deploy/make-env.sh first."
[[ -f "${script_dir}/compose.https.yml" ]] || die "${script_dir}/compose.https.yml is missing."

# The domain must point to this host. Let's Encrypt connects to it on port 80.
resolved="$(getent hosts "${domain}" | awk '{ print $1 }')" || true
[[ -n "${resolved}" ]] || die "${domain} does not resolve. Create the DNS record first."
public_ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null ||
  curl -fsS --max-time 10 https://ifconfig.me/ip 2>/dev/null || true)"
if [[ -z "${public_ip}" ]]; then
  echo "WARNING: cannot read the public IP of this host. The DNS check is skipped." >&2
elif grep -Fxq "${public_ip}" <<<"${resolved}"; then
  pass "${domain} resolves to this host (${public_ip})."
else
  die "${domain} resolves to $(tr '\n' ' ' <<<"${resolved}")but this host is ${public_ip}. No file changed."
fi

# --- 2. Overlay and .env -----------------------------------------------------------------------
if ! cmp -s "${script_dir}/compose.https.yml" "${overlay}"; then
  install -m 644 "${script_dir}/compose.https.yml" "${overlay}"
fi
set_env_value DOMAIN "${domain}"
set_env_value WEB_DOMAIN "https://${domain}"
compose_file="$(env_value COMPOSE_FILE)"
if [[ -z "${compose_file}" ]]; then
  compose_file="docker-compose.yml:compose.override.yml:compose.https.yml"
elif [[ ":${compose_file}:" != *":compose.https.yml:"* ]]; then
  compose_file="${compose_file}:compose.https.yml"
fi
set_env_value COMPOSE_FILE "${compose_file}"
pass ".env sets DOMAIN=${domain}, WEB_DOMAIN=https://${domain}, COMPOSE_FILE=${compose_file}."

# --- 3. TLS parameters and certificate ---------------------------------------------------------
# The host user owns these folders, because it creates them before certbot runs.
mkdir -p "${certbot_dir}/conf" "${certbot_dir}/www"
for file in certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
  certbot/certbot/ssl-dhparams.pem; do
  name="$(basename "${file}")"
  if [[ ! -s "${certbot_dir}/conf/${name}" ]]; then
    curl -fsS --max-time 60 -o "${certbot_dir}/conf/${name}.tmp" "${tls_params_url}/${file}" ||
      die "cannot download ${name}."
    mv "${certbot_dir}/conf/${name}.tmp" "${certbot_dir}/conf/${name}"
  fi
done
pass "options-ssl-nginx.conf and ssl-dhparams.pem are in ${certbot_dir}/conf."

live="/etc/letsencrypt/live/${domain}"
if in_certbot "test -s '${live}/fullchain.pem'" >/dev/null 2>&1; then
  echo "A certificate exists at ${live}/fullchain.pem."
else
  # nginx needs a certificate file to start. The dummy lives one day; certbot replaces it below.
  echo "No certificate yet. Creating a dummy certificate so that nginx can start."
  in_certbot "mkdir -p '${live}' && openssl req -x509 -nodes -newkey rsa:${rsa_key_size} -days 1 \
    -keyout '${live}/privkey.pem' -out '${live}/fullchain.pem' -subj '${dummy_subject}'" >/dev/null
fi

# --- 4. Start nginx with the production template ------------------------------------------------
compose up -d
deadline=$((SECONDS + health_timeout))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost/nginx-health || true)" == 200 ]]; do
  ((SECONDS < deadline)) ||
    die "http://localhost/nginx-health is not 200 after ${health_timeout} s. Inspect: cd ${compose_dir} && docker compose logs nginx"
  sleep 5
done
pass "nginx answers on port 80."

# --- 5. Issue the real certificate if the dummy is in place --------------------------------------
issuer="$(in_certbot "openssl x509 -in '${live}/fullchain.pem' -noout -issuer" 2>/dev/null || true)"
if [[ "${issuer}" == *"CN=localhost"* || "${issuer}" == *"CN = localhost"* ]]; then
  echo "The certificate is the dummy. Requesting a Let's Encrypt certificate for ${domain}."
  in_certbot "rm -rf '${live}' '/etc/letsencrypt/archive/${domain}' '/etc/letsencrypt/renewal/${domain}.conf'"
  staging_args=()
  [[ "${STAGING:-0}" == 1 ]] && staging_args=(--staging)
  compose run --rm --no-deps --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
    -d "${domain}" --email "${email}" --agree-tos --no-eff-email --rsa-key-size "${rsa_key_size}" \
    --non-interactive "${staging_args[@]}" ||
    die "certbot did not issue a certificate. Check that port 80 of ${domain} is reachable from the internet."
  compose exec nginx nginx -s reload
  pass "Let's Encrypt certificate issued. nginx reloaded."
else
  pass "The certificate is not the dummy (${issuer:-issuer unknown}). No issuance needed."
fi

# --- 6. Verify ---------------------------------------------------------------------------------
curl_tls=(curl -fsS --max-time 20 -o /dev/null)
[[ "${STAGING:-0}" == 1 ]] && curl_tls+=(--insecure)
for path in /nginx-health /api/health; do
  if "${curl_tls[@]}" "https://${domain}${path}"; then
    pass "https://${domain}${path} answers 200."
  else
    fail "https://${domain}${path} does not answer 200."
  fi
done
# The upstream production template serves the app on port 80 too. It has no redirect.
http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://${domain}/" || true)"
case "${http_code}" in
30[1278]) pass "http://${domain}/ redirects (${http_code})." ;;
200) echo "INFO: http://${domain}/ answers 200 without a redirect (upstream app.conf.template.prod). Use the https URL." ;;
*) fail "http://${domain}/ answers ${http_code}." ;;
esac

((failed == 0)) || die "HTTPS setup is not complete."
echo "HTTPS is enabled for https://${domain}. The certbot service renews the certificate every 12 h."
