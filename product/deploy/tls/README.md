# TLS parameters for nginx

Copies of two files from the certbot repository, tag `v5.8.0`
(commit `d050f5ced828d90faf4304a752c9a6848416216a`):

- `options-ssl-nginx.conf` from `certbot/src/certbot/_internal/plugins/nginx/tls_configs/`
- `ssl-dhparams.pem` from `certbot/src/certbot/`

The upstream Onyx template `app.conf.template.prod` includes both files from
`/etc/letsencrypt`. `enable-https.sh` copies them from here and checks `SHA256SUMS`, so the
VM downloads nothing at setup time.
