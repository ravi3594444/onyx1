# Runbook: 22nd X AI knowledge base on Onyx v4.8.4

This runbook covers the development deployment of stock Onyx under the 22nd X AI brand.
Scope and rules: `docs/product/PRD.md`, `docs/product/ARCHITECTURE.md`, `docs/product/TRD-PLAN.md`.
Test results: the "Baseline evidence" section of `docs/product/TRD-PLAN.md`.

## 1. Baseline

| Item | Value |
| --- | --- |
| Fork `main` | Same as upstream `main` at `f1fbc7a` (3 October 2026). No owner changes. |
| Running release | Upstream tag `v4.8.4`, commit `d15d4451607965e0e349aad231f858596e85ea52` |
| Images | `onyx-backend`, `onyx-web-server`, `onyx-model-server` at `v4.8.4`, pinned by digest in `release.env`. All three carry the revision label `d15d445`. |
| Compose files | `deployment/docker_compose` and `deployment/data` from the tag `v4.8.4`. Do not use the files on fork `main`; they belong to a later, unreleased version. |
| Edition | Enterprise code loads (upstream default `LICENSE_ENFORCEMENT_ENABLED=true`). Without a license the tier is `community`. |

The fork keeps upstream source unchanged. Our additions live in `docs/product/`, `product/`
and `.github/workflows/axi-*.yml`.

## 2. Remotes

```bash
git remote -v
# origin    https://github.com/ravi3594444/onyx1 (fetch and push)
# upstream  https://github.com/onyx-dot-app/onyx  (fetch only)
git remote add upstream https://github.com/onyx-dot-app/onyx
git remote set-url --push upstream no_push_to_upstream
```

## 3. Install on the development VM

Requirements: Docker Engine with the Compose plugin, 4 vCPU, 16 GB RAM, 100 GB SSD.
Before you start OpenSearch, follow the OpenSearch host settings:
`vm.max_map_count=262144`, open files 65536, unlimited memlock.

1. Export the release files from the tag into a stable folder:

   ```bash
   git fetch --depth 1 upstream tag v4.8.4
   sudo mkdir -p /srv/onyx && sudo chown "$USER" /srv/onyx
   git archive v4.8.4 deployment/docker_compose deployment/data | tar -x -C /srv/onyx
   cp product/deploy/compose.override.yml /srv/onyx/deployment/docker_compose/
   ```

2. Create `.env` with generated secrets. Give the public URL as the second argument:

   ```bash
   product/deploy/make-env.sh /srv/onyx/deployment/docker_compose https://kb.example.com
   ```

   Store a copy of `.env` in a password manager. `ENCRYPTION_KEY_SECRET` decrypts stored
   credentials. A restore without it loses those credentials.

3. Start the stack. Docker Compose reads `compose.override.yml` automatically:

   ```bash
   cd /srv/onyx/deployment/docker_compose
   docker compose pull
   docker compose up -d
   curl -fsS http://localhost:3000/api/health
   ```

4. Open the web URL. The first account that you register becomes the admin.

5. In **Admin > Language Models**, add the model provider. Then set the default model.

Do not use `onyx-cli deploy install --no-prompt`. Without a prompt it installs Onyx Lite,
which has no OpenSearch, no connectors and no vector search. If you use `onyx-cli`
interactively, select "Standard".

## 3a. HTTPS with Let's Encrypt

The stack from section 3 serves plain HTTP on ports 80 and 3000. `enable-https.sh` adds the
overlay `product/deploy/compose.https.yml`. The overlay gives nginx the upstream production
setup: ports 80 and 443, the `../data/certbot` volumes and `app.conf.template.prod`. It
removes the publish of port 3000, and it adds the upstream `certbot` service (pinned to
`certbot/certbot:v5.8.0` by digest).

Requirements:

- A DNS `A` or `AAAA` record for the domain that points to the public IP of the VM.
- Port 80 and port 443 of the VM open to the internet. Let's Encrypt validates the domain
  over port 80 (`/.well-known/acme-challenge/`).

Run the script from the fork checkout on the VM. It is idempotent: run it again after a
failure, or to check the setup. Set `STAGING=1` to test with the Let's Encrypt staging
service, which has no rate limits but gives an untrusted certificate.

```bash
product/deploy/enable-https.sh /srv/onyx/deployment/docker_compose kb.example.com admin@example.com
```

The script does these steps and prints a `PASS` or `FAIL` line for each check:

1. Checks the domain, the email and that `getent hosts <domain>` gives the public IP of the
   VM. If the DNS record is wrong, it stops before it changes a file.
2. Copies `compose.https.yml` next to `docker-compose.yml`. Changes three keys in `.env`:
   `DOMAIN=<domain>`, `WEB_DOMAIN=https://<domain>` and `COMPOSE_FILE`, which gets
   `compose.https.yml` as the last file (`docker-compose.yml:compose.override.yml:compose.https.yml`).
   It changes no other value.
3. Copies `options-ssl-nginx.conf` and `ssl-dhparams.pem` from `product/deploy/tls/` (pinned
   copies from certbot v5.8.0, checked against `SHA256SUMS`) into `../data/certbot/conf`. It
   copies `product/deploy/nginx/redirect.conf.template` with the domain filled in into
   `../data/nginx-extra/`, which the overlay mounts into nginx. The nginx command fills in the
   container address at every start: the redirect block listens on that address only. The
   upstream HTTPS block proxies every request to `localhost:80` with the same Host header, and
   those requests must reach the upstream port-80 block, not the redirect. If no certificate
   exists, it writes a 1-day dummy certificate (`CN=localhost`), so that nginx can start.
4. Runs `docker compose up -d`. This recreates nginx with the production template and starts
   `certbot`. Then it waits for `http://localhost/nginx-health`.
5. If the certificate is the dummy, it removes it and runs `certbot certonly --webroot`. Then
   it reloads nginx.
6. Checks that `https://<domain>/nginx-health` and `https://<domain>/api/health` answer 200
   (a redirect does not pass), and that `http://<domain>/` answers a 301 to HTTPS. The redirect block serves only the ACME challenge
   path and the health check on port 80 for the domain. `WEB_DOMAIN` makes the app build its
   own links with `https://`. An HSTS header needs a change to the upstream 443 server block,
   so it is not set.

Renewal: the `certbot` service runs `certbot renew` every 12 hours. `run-nginx.sh` reloads
nginx every 6 hours, so nginx uses a new certificate without a restart. Check with
`docker compose logs certbot`.

Deploys: `deploy-remote.sh` stages `compose.https.yml` from the deployed commit next to the
live `.env` copy, so `docker compose pull` in the stage folder finds every file in
`COMPOSE_FILE`. With the overlay active, the deploy health check uses port 80, because port
3000 is no longer published. Section 9 then needs `--base-url http://localhost` or the HTTPS URL.

Restore test (section 8): `restore.sh` copies `env.backup` to `.env`, and that file now
has `COMPOSE_FILE` with `compose.https.yml`. The restore folder has no such file, and the
overlay would also publish ports 80 and 443, which the live stack uses. Compose prefers the
shell environment to `.env`, and `restore.sh` allows `COMPOSE_FILE` in the shell. So run the
restore with the plain HTTP file list:

```bash
COMPOSE_FILE=docker-compose.yml:compose.override.yml HOST_PORT=3100 HOST_PORT_80=8100 \
  product/deploy/restore.sh /srv/backups/2026-10-04 /srv/onyx-restore/deployment/docker_compose onyx-restore
```

## 4. Configuration decisions

| Setting | Value | Reason |
| --- | --- | --- |
| `IMAGE_TAG` and `ONYX_*_IMAGE` | `v4.8.4` with digests | Pinned, tested release |
| `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES` | `false` (template default) | With `true` and no license, the whole UI shows "Access Restricted". An uploaded license sets the tier. |
| `LICENSE_ENFORCEMENT_ENABLED` | not set (upstream default `true`) | Keep license enforcement. Never set it to `false`. |
| `code-interpreter` service | Opt-in through `COMPOSE_PROFILES` | It mounts the host Docker socket. The PRD does not need it. |
| Secrets | Generated by `make-env.sh` | Replaces `minioadmin`, `password` and the default OpenSearch password |
| Telemetry | Upstream default | Set `DISABLE_TELEMETRY=true` if no usage data must go to Onyx |

## 5. Entitlement

| Need | Required plan | Status |
| --- | --- | --- |
| App name, logo, greeting, login subtitle, disclaimer (`/api/admin/enterprise-settings`) | Business | Blocked: HTTP 402 without a license |
| User groups and group-restricted connectors | Business | Blocked: HTTP 402 without a license |
| Hide "Powered by Onyx", custom help link | Enterprise | Blocked |
| Chat, search, connectors, per-user projects, private chats | Community | Works |

To activate a license: **Admin > Billing > Activate License Key**, or
`POST /api/license/upload` with the multipart field `license_file`.
To get one: ask Onyx (founders@onyx.app) for a development or trial license, or start the
Business plan checkout on the billing page. The checkout needs outbound access to
`cloud.onyx.app`.

## 6. Apply the brand

After a Business license is active:

```bash
ADMIN_EMAIL=... ADMIN_PASSWORD=... product/branding/apply-branding.sh https://kb.example.com
```

The script uploads `product/branding/logo.png` and replaces all enterprise settings with
`product/branding/enterprise-settings.json`. No restart is necessary. See
`product/branding/README.md` for the asset sources and the gaps that settings cannot close.

## 7. Restart behaviour

- `docker compose down` and `up -d` replace containers and keep the named volumes.
- Redis has no volume. A Redis restart signs out all users. They sign in again; no data is lost.
- Any change to `.env` recreates every service that reads it, which includes Redis.

## 7a. Known Onyx behaviour: removed files and pruning

When you remove files from a File connector, Onyx starts a prune for that connector. In
v4.8.4, if a prune of the same connector still runs, Onyx starts no new prune. It only logs
"Failed to trigger pruning" and the API still answers 200. The removed file then stays
searchable until the next scheduled prune (default every 7 days).

After you remove or replace files:

1. Wait until **Last pruned** of the connector changes
   (`GET /api/manage/admin/cc-pair/<id>/last_pruned`).
2. If you removed more files during a running prune, start a prune again
   (`POST /api/manage/admin/cc-pair/<id>/prune`), or wait for the schedule.

`run_checks.py` waits for the prune after the update step. CI found this race on a fast runner.

## 8. Backup and restore

The backup is cold: the stack stops for the copy.

```bash
product/deploy/backup.sh /srv/onyx/deployment/docker_compose /srv/backups/$(date +%F)
# Then copy the backup folder off the VM, for example to object storage.
```

It saves the volumes `db_volume` (Postgres), `opensearch-data`, `minio_data` (original files)
and `file-system`, plus `.env` and a `SHA256SUMS` file. Model caches, logs and Redis are not
durable state.

Safety rules in `backup.sh`:

- The backup folder must be new. All files are readable only by the owner.
- If a step fails or a signal stops the script, the script starts the stack again and removes
  the partial copy. Only a complete copy gets the final folder name.
- If something starts the stack during the copy, the backup fails.
- The exit code is 0 only when the copy is complete and the stack is running again.

Isolated restore test, on a second VM or with the live stack stopped:

```bash
git archive v4.8.4 deployment/docker_compose deployment/data | tar -x -C /srv/onyx-restore
cp product/deploy/compose.override.yml /srv/onyx-restore/deployment/docker_compose/
HOST_PORT=3100 HOST_PORT_80=8100 product/deploy/restore.sh \
  /srv/backups/2026-10-04 /srv/onyx-restore/deployment/docker_compose onyx-restore
```

Safety rules in `restore.sh`:

- It checks `SHA256SUMS` and requires every archive and `env.backup`.
- It stops before any change if the target project has containers or volumes. It never
  deletes data.
- It checks `env.backup` before it writes `.env`. The eight required secrets must be set, and
  `MINIO_ROOT_*` must equal `S3_AWS_*`. An existing `.env` must be identical to `env.backup`.
- It stops if the shell exports any of these secrets, because Compose would use the shell
  values instead of the restored ones. Unset them first.
- It locks the compose folder, so two restores cannot use the same folder. Use one compose
  folder for each restore project.
- It starts only nginx and the services nginx needs. It does not start `background`, so the
  copy does not sync connectors or run bots with live credentials.
- It waits for `/api/health` (`RESTORE_HEALTH_TIMEOUT`, default 900 s). A healthy API shows
  that the restored database and OpenSearch passwords work.

Restore only into the same release. A newer image migrates the database and the index;
after that, rollback needs a backup from before the upgrade.
Do not activate real outbound connectors in a restored test copy.

## 9. Functional checks

```bash
export ADMIN_EMAIL=... ADMIN_PASSWORD=... USER_A_EMAIL=... USER_A_PASSWORD=... \
       USER_B_EMAIL=... USER_B_PASSWORD=...
set -o pipefail
(
  set -e
  for step in index search chat chat-forced privacy update delete; do
    python3 product/test-corpus/run_checks.py --base-url http://localhost:3000 "$step"
  done
) 2>&1 | tee checks.log
```

Each step prints `PASS`, `FAIL` and `SKIP` lines and exits with 1 when a check fails. A `SKIP`
does not fail the step; the step summary counts the skips. The loop stops
at the first failed step. Without a model provider, add `--skip-chat` and leave out the
`chat` and `chat-forced` steps. See `product/test-corpus/README.md`.

## 10. Custom-change register

| Change | Paths | Purpose | Validation |
| --- | --- | --- | --- |
| Product documents | `docs/product/` | Scope, architecture, plan and evidence | Review |
| Compose override | `product/deploy/compose.override.yml` | Makes `code-interpreter` opt-in | `docker compose config --services` |
| Release pin and env script | `product/deploy/release.env`, `make-env.sh` | Pinned images, generated secrets | Stack started from the generated `.env` |
| Backup and restore | `product/deploy/backup.sh`, `restore.sh` | Recovery path | Isolated restore test |
| Brand assets and apply script | `product/branding/` | Supported white-label settings | Returns 402 until licensed |
| Test corpus and checks | `product/test-corpus/` | PRD functional checks | Sandbox run |
| CI/CD workflows and deploy script | `.github/workflows/axi-*.yml`, `product/deploy/deploy-remote.sh` | CI checks and dev deploy | `actionlint`, `zizmor`, `shellcheck`; GitHub Actions run |

There are no changes to upstream source files.

## 11. CI and deployment pipeline

We added four workflows (with `axi-check-dev-ssh.yml`). The 50 upstream workflows stay unchanged.

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `axi-product-ci.yml` ("22nd X AI product checks") | Pull requests, and pushes to `main` and `claude/**`, that change `product/`, `docs/product/` or `axi-*.yml`; manual run | `static`: pre-commit hooks on our files (large files, YAML, `ripsecrets`, `shellcheck`, `ruff`, `ruff-format`, `actionlint`, `zizmor`), `py_compile`, `bash -n`. `compose-config`: exports the tag from `release.env`, checks its commit, runs `make-env.sh`, checks the services and the image digests. `e2e` (push to `main` or manual run): starts the stack, registers 3 users, runs `index`, `search`, `privacy`, `update` and `delete` with `--skip-chat`, backs up, restores into `onyx-restore` on port 3100, and runs `search` there. |
| `axi-bootstrap-dev.yml` ("Bootstrap dev VM") | Manual run from `main` only | Runs `product/deploy/vm-bootstrap.sh` on the VM over SSH. Actions: `inspect` (read-only), `install` (Docker, host settings, release files, `make-env.sh` only if `.env` is missing, `up -d`), `verify` and `verify-with-chat` (cleanup, checks, `prune_race.py`, backup, isolated restore on port 3100), `restart` (`down` without `-v`, `up -d`, then `search` and `privacy` with the state of the last `verify`), `https` and `https-staging` (`enable-https.sh` for `my-knowledge.duckdns.org`; needs the `letsencrypt_email` input). Evidence goes to `/srv/onyx/evidence/<time>/` and to the run artifact. |
| `axi-deploy-dev.yml` ("Deploy 22nd X AI dev") | The product checks pass on a push to `main`; manual run from `main` | A manual run first checks that the product checks passed on `main` for that commit. Then it runs `product/deploy/deploy-remote.sh` on the VM over SSH. One deploy at a time. |

CI has no model provider. Thus `e2e` does not run `chat` and `chat-forced`, and it skips the
model answers in `update` and `delete` (the log shows them as `SKIP`). Run the chat checks on the
VM as section 9 shows.
To run the static checks locally, the same files as CI:

```bash
env -u GH_TOKEN -u GITHUB_TOKEN uvx pre-commit run \
  --files $(git ls-files docs/product product '.github/workflows/axi-*.yml')
```

Without a token, zizmor skips its online audits. In CI it gets the job token.

Deploy secrets. The SSH key gives `docker` access, which is equal to root on the VM.
Thus keep the secrets only in the environment `ci-protected`, never in the repository:

1. Create the environment `ci-protected` (**Settings > Environments**) before you add secrets.
2. Set **Deployment branches and tags** to **Selected branches** with the rule `main`.
   Then a workflow on another branch cannot read the secrets. A required reviewer is optional.
3. Add the 4 secrets to this environment:

| Secret | Value |
| --- | --- |
| `DEV_SSH_HOST` | VM host name or IP address |
| `DEV_SSH_USER` | Deploy user. It must be able to run `docker`. |
| `DEV_SSH_KEY` | Private SSH key of the deploy user, without a passphrase |
| `DEV_SSH_KNOWN_HOSTS` | `known_hosts` line of the VM. Compare `ssh-keyscan <host>` with the fingerprint on the VM. |

If a secret is missing, the deploy job writes a notice and stops without an error.

`deploy-remote.sh` assumes this layout on the VM:

- `/srv/onyx-src`: a clone of the fork. Its `origin` remote must fetch without a prompt.
- `/srv/onyx`: the release files and the `.env` from section 3.

The script fetches the deployed commit. It prepares the tag files, `compose.override.yml`
and a copy of `.env` with `IMAGE_TAG` and `ONYX_*_IMAGE` from `release.env` in a temporary
folder, and runs `docker compose pull` there. Only after a good pull does it check out the
commit, copy the files to `/srv/onyx` and run `docker compose up -d`. Then it waits up to
15 minutes for `/api/health`. Compose output goes to `/srv/onyx/deploy.log`. The script never
creates `.env` and never removes volumes. If `.env` is missing, it stops: run `make-env.sh` once.

The script stops in two more cases:

- The commit does not include the deployed commit (the `HEAD` of `/srv/onyx-src`), for example
  a re-run of an old run. To deploy an older commit on purpose, run on the VM:
  `ALLOW_ROLLBACK=1 bash -s -- <sha> </srv/onyx-src/product/deploy/deploy-remote.sh`.
- `release.env` names a different Onyx release than `.env`. The new release migrates the
  database, and only a backup from before the upgrade can undo that. Run `backup.sh` on the VM,
  then start a manual deploy with **allow_release_change** selected.

Status on 4 October 2026: the owner enabled Actions on the fork. The product checks ran on
this branch (runs #1 to #3). Enabling Actions also enabled the upstream workflows. On the next
push to `main`, "Storybook Deploy" failed because it needs Onyx's Vercel token, and other
upstream workflows started.

Next steps:

1. Disable the upstream workflows now, before the next push to `main`. GitHub lists a workflow
   only after it ran once, so repeat the loop later, or use **Actions > workflow > Disable**:

   ```bash
   for file in $(git ls-files '.github/workflows/*.yml' | grep -v '/axi-'); do
     gh workflow disable "$(basename "${file}")" --repo ravi3594444/onyx1 || true
   done
   gh workflow list --all --repo ravi3594444/onyx1
   ```

2. Merge the workflows to `main`. GitHub starts the deploy trigger only for workflow files on
   the default branch.
3. When the VM exists, create the environment `ci-protected` and add the deploy secrets as
   shown above.
