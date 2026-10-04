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
