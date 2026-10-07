#!/bin/sh
# Renders the HTTPS redirect block with one listen line per container address.
# compose.https.yml runs it inside the nginx container at every start. Without an address
# the script fails, so nginx does not start and port 80 never falls back to the app.
set -eu
template=/etc/nginx/conf.d/zz-redirect.conf.template
target=/etc/nginx/conf.d/zz-redirect.conf
addresses="$(hostname -i)"
lines=""
for addr in $addresses; do
  case "$addr" in
    *:*) lines="${lines}    listen [${addr}]:80;
" ;;
    *) lines="${lines}    listen ${addr}:80;
" ;;
  esac
done
[ -n "$lines" ] || { echo "render-redirect.sh: hostname -i gave no address" >&2; exit 1; }
# shellcheck disable=SC2016
LISTEN_LINES="$lines" envsubst '$LISTEN_LINES' <"$template" >"$target"
echo "render-redirect.sh: the redirect block listens on port 80 of: $addresses"

# Multi-tenant stack only (LEAVE_TEAM_GUARD=true in compose.saas.yml). Onyx v4.8.4 lets the
# last admin of a team call POST /api/tenants/leave-team, which then asks the control plane
# to delete the team and fails with 500 without one. This deployment has no control plane,
# so nginx answers the route with a clear 409 before it reaches the app. Nothing is deleted.
# The exact-match location wins over the regex location of the upstream template.
if [ "${LEAVE_TEAM_GUARD:-}" = "true" ]; then
  app=/etc/nginx/conf.d/app.conf.template.prod
  marker='    location ~ ^/(api|openapi.json)(/.*)?$ {'
  guard=/tmp/leave-team-guard.conf
  cat >"$guard" <<'EOF_GUARD'
    location = /api/tenants/leave-team {
        default_type application/json;
        return 409 '{"detail": "Leaving a team is not available on this deployment. Ask another admin of your team to remove your account, or contact the 22nd X AI team."}';
    }
EOF_GUARD
  grep -qxF "$marker" "$app" || { echo "render-redirect.sh: api location not found in $app" >&2; exit 1; }
  awk -v marker="$marker" -v guard="$guard" '
    $0 == marker { while ((getline line < guard) > 0) print line; close(guard) }
    { print }' "$app" >"$app.tmp" && mv "$app.tmp" "$app"
  grep -qF 'location = /api/tenants/leave-team' "$app" || { echo "render-redirect.sh: guard not inserted" >&2; exit 1; }
  echo "render-redirect.sh: POST /api/tenants/leave-team answers 409 (leave-team guard)"
fi

# Multi-tenant stack only (LANDING_PAGE=true in compose.saas.yml). The exact route / serves the
# landing page from /usr/share/nginx/landing (built from product/landing by axi-deploy-dev.yml)
# and /_landing/ serves its assets. A request with the auth cookie goes to /app, as the Onyx
# root page does. Without index.html the block is left out and / stays with Onyx.
landing=/usr/share/nginx/landing
if [ "${LANDING_PAGE:-}" = "true" ]; then
  if [ -f "$landing/index.html" ]; then
    app=/etc/nginx/conf.d/app.conf.template.prod
    marker='    location ~ ^/(api|openapi.json)(/.*)?$ {'
    block=/tmp/landing.conf
    cat >"$block" <<'EOF_LANDING'
    location = / {
        absolute_redirect off;
        if ($cookie_fastapiusersauth) {
            return 302 /app;
        }
        root /usr/share/nginx/landing;
        try_files /index.html =404;
        add_header Cache-Control "no-cache" always;
    }
    location ^~ /_landing/ {
        alias /usr/share/nginx/landing/;
        add_header Cache-Control "public, max-age=3600" always;
    }
EOF_LANDING
    grep -qxF "$marker" "$app" || { echo "render-redirect.sh: api location not found in $app" >&2; exit 1; }
    awk -v marker="$marker" -v block="$block" '
      $0 == marker { while ((getline line < block) > 0) print line; close(block) }
      { print }' "$app" >"$app.tmp" && mv "$app.tmp" "$app"
    grep -qF 'location ^~ /_landing/' "$app" || { echo "render-redirect.sh: landing block not inserted" >&2; exit 1; }
    echo "render-redirect.sh: / serves the landing page; /_landing/ serves its assets"
  else
    echo "render-redirect.sh: no $landing/index.html; / stays with Onyx"
  fi
fi
