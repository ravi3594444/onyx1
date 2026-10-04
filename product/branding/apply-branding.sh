#!/usr/bin/env bash
# Applies the 22nd X AI appearance settings through the supported Onyx API.
# Needs a Business (or higher) license; without one the API returns HTTP 402.
# Usage: ADMIN_EMAIL=... ADMIN_PASSWORD=... product/branding/apply-branding.sh [base URL]
set -euo pipefail

branding_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_url="${1:-http://localhost:3000}"
cookie_jar="$(mktemp)"
trap 'rm -f "${cookie_jar}"' EXIT

curl -fsS -c "${cookie_jar}" -o /dev/null -X POST "${base_url}/api/auth/login" \
  --data-urlencode "username=${ADMIN_EMAIL:?set ADMIN_EMAIL}" \
  --data-urlencode "password=${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"

# Upload the logo first. The settings payload then turns on use_custom_logo.
curl -fsS -b "${cookie_jar}" -o /dev/null -X PUT \
  "${base_url}/api/admin/enterprise-settings/logo?is_logotype=false" \
  -F "file=@${branding_dir}/logo.png;type=image/png"

# This PUT replaces every field, so the JSON file lists all of them.
curl -fsS -b "${cookie_jar}" -o /dev/null -X PUT "${base_url}/api/admin/enterprise-settings" \
  -H "Content-Type: application/json" --data-binary "@${branding_dir}/enterprise-settings.json"

echo "Applied branding to ${base_url}."
