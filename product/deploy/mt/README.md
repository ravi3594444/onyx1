# Multi-tenant validation stack

This folder holds the overlay for a second Onyx v4.8.4 stack with `MULTI_TENANT=true`. Use it
for validation only. It runs on the development VM next to the live single-tenant stack and
shares nothing with it.

## Isolation

| Item | Live stack | Multi-tenant stack |
| --- | --- | --- |
| Folder | `/srv/onyx/deployment/docker_compose` | `/srv/onyx-mt/deployment/docker_compose` |
| Compose project | `onyx` | `onyx-mt` (containers, network and volumes `onyx-mt_*`) |
| Compose files | `docker-compose.yml`, `compose.override.yml`, `compose.https.yml` | `docker-compose.yml`, `compose.override.yml`, `compose.mt.yml` |
| Published port | 80 and 443 | `127.0.0.1:3200` only |
| `.env` | live secrets | new secrets from `make-env.sh`, `WEB_DOMAIN=http://localhost:3200` |

`vm-bootstrap.sh` gives `-p onyx-mt` and the three `-f` files on each call. It also writes
`COMPOSE_PROJECT_NAME=onyx-mt` and `COMPOSE_FILE` into the multi-tenant `.env`, and
`compose.mt.yml` sets `name: onyx-mt`. A plain `docker compose` in the multi-tenant folder then
also addresses `onyx-mt`, never `onyx`. The script never copies the live `.env`. It stops if the
two files are equal.

## Actions

Run them with the workflow `axi-bootstrap-dev.yml` (input `action`), or on the VM with
`product/deploy/vm-bootstrap.sh`. Each action keeps a log in `/srv/onyx/evidence/<time>-mt-*/`.

| Workflow action | Script call | What it does |
| --- | --- | --- |
| `mt-up` | `mt-up <sha>` | Checks memory, exports the release files and `compose.mt.yml`, writes `.env` once and checks it, pulls, starts, waits for `http://127.0.0.1:3200/api/health`, shows `ps`, `docker stats` and `free -m`. |
| `mt-check` | `mt-check <sha>` | Runs `product/test-corpus/mt_checks.py` against `http://127.0.0.1:3200`. |
| `mt-check-after-restart` | `mt-check <sha> after-restart` | The same, with `--after-restart` (read checks only). |
| `mt-restart` | `mt-restart <sha>` | `down` (without `-v`), `up -d`, health wait, volume comparison, then the after-restart checks. |
| `mt-down` | `mt-down` | `down` without `-v`. The volumes stay for inspection. |
| `mt-destroy` | `mt-destroy` | Removes the containers, the network and the volumes of `onyx-mt`, and `mt_state.json`. |

Order for a full test: `mt-up`, `mt-check`, `mt-restart`, then `mt-down` or `mt-destroy`.

Files in `/srv/onyx-mt`, created once:

- `mt-tag`: the tag of the test accounts (`mt-` and 8 hex characters). The log shows it.
- `mt-salt`: the password salt (mode 600). The script gives it to `mt_checks.py` in
  `MT_PASSWORD_SALT` and never prints it.
- `mt_state.json`: the state of `mt_checks.py`. `mt-destroy` removes it, because the accounts
  and documents go with the volumes. `.env`, `mt-tag` and `mt-salt` stay.

## Settings in compose.mt.yml

The base comes from the upstream overlay
`deployment/docker_compose/docker-compose.multitenant.yml` at tag v4.8.4:

- `api_server` and `background`: `MULTI_TENANT=true`, `AUTH_TYPE=cloud`,
  `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true`, `REQUIRE_EMAIL_VERIFICATION=false`.
- `api_server`: the command `alembic -n schema_private upgrade head` before `uvicorn`. The base
  `alembic upgrade head` refuses to run with `MULTI_TENANT=true`.
- `web_server`: `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true`.

The `environment` values win over the `.env` value `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=false`.

Additions from the migration research (line numbers refer to `backend/` at v4.8.4):

| Setting | Where | Reason |
| --- | --- | --- |
| `DEV_MODE=true` | `api_server` and `background` (upstream: `api_server` only) | Without it, a new company sign-up posts to `CONTROL_PLANE_API_BASE_URL` and returns 500 (`ee/onyx/server/tenants/provisioning.py:157`), and invites call billing (`onyx/server/manage/users.py:682-731`). This stack has no control plane, and no stub control plane is used. |
| `TARGET_AVAILABLE_TENANTS=1` | `api_server`, `background` | The default 5 pre-builds 5 tenant schemas (`onyx/configs/app_configs.py:1992`). |
| `SUPER_USERS=[]` | `api_server`, `background` | No cross-tenant impersonation (`ee/onyx/configs/app_configs.py:151`). |
| `VERIFY_CREATE_OPENSEARCH_INDEX_ON_INIT_MT=true` | `api_server`, `background` | The code default, set explicitly: a tenant's OpenSearch index is created when it is first used (`onyx/configs/app_configs.py:565`). Vespa setup is skipped by the default `ONYX_DISABLE_VESPA=true` (`onyx/setup.py:366`). |
| `mt_minio_bucket` (one-shot service) | new | With `MULTI_TENANT=true` the API server does not create the file store bucket (`onyx/main.py:428-431`). The `MINIO_DEFAULT_BUCKETS` setting of the upstream `minio` service is not reliable (see its comment). The job runs `mc mb --ignore-existing` for `S3_FILE_STORE_BUCKET_NAME` (default `onyx-file-store-bucket`), and `api_server` waits until it completes. `mt-up` shows its log. |
| `HUBSPOT_TRACKING_URL` | not set | No tracking calls (`ee/onyx/configs/app_configs.py:166`). `mt-up` stops if `.env` sets it. |

`.env` checks in `mt-up` (no value is printed):

- `USER_AUTH_SECRET` must not be empty. `DEV_MODE` lets an empty value pass with only a warning
  (`onyx/auth/users.py:235`). `make-env.sh` writes a random value.
- `DB_READONLY_USER` (`db_readonly_user`) and `DB_READONLY_PASSWORD` (48 random hex characters)
  are written once. The `schema_private` migration creates this read-only Postgres role, and the
  code default of the password is `password` (`onyx/configs/app_configs.py:2034-2036`).

The upstream development overlay `docker-compose.dev.yml` is not used. It publishes the
internal ports (5432, 6379, 8080, 9000, 9004, 9005, 9200), which the live stack or the host can
hold.

### LICENSE_ENFORCEMENT_ENABLED

The overlay does not set it, so it keeps the code default `true`. The upstream overlay does
not change it either, and the validation must show the shipped behavior. With
`MULTI_TENANT=true`, v4.8.4 behaves as follows:

- `check_ee_features_enabled` and `apply_license_status_to_settings` give the EE features
  without a license (`ee/onyx/server/settings/api.py`).
- The license middleware finds no license for a tenant and lets the request through.
- `get_tier` asks the control plane (`CONTROL_PLANE_API_BASE_URL`, default
  `http://localhost:8082`). The call fails and the tier falls back to `BUSINESS`
  (`ee/onyx/utils/tier.py`). The fallback is not cached, so each tier lookup tries again. Expect
  warnings about the control plane in the `api_server` log.

## Memory plan

The VM has 6 vCPU and 15.6 GiB of RAM. The live stack uses about 7 GiB.

- `mt-up` reads `MemAvailable` from `/proc/meminfo` and stops before any change when it is less
  than 6 GiB. It skips the check when `onyx-mt` runs already.
- OpenSearch heap: 1 GiB (`OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g`; upstream fixes 2g in
  `docker-compose.yml`, and Compose merges `environment` by key).
- Indexing threads: `CELERY_WORKER_DOCPROCESSING_CONCURRENCY=2` (upstream 6).
- The code interpreter does not start (`compose.override.yml`).
- Memory limits per container. A limit is a maximum, not a reservation. A container that
  goes above it stops, not a live container. Change a limit with the variable in the
  multi-tenant `.env`:

| Service | Limit | Variable |
| --- | --- | --- |
| `background` | 4g | `MT_BACKGROUND_MEM_LIMIT` |
| `inference_model_server`, `indexing_model_server` | 3g each | `MT_MODEL_SERVER_MEM_LIMIT` |
| `api_server` | 2g | `MT_API_SERVER_MEM_LIMIT` |
| `opensearch` | 2g | `MT_OPENSEARCH_MEM_LIMIT` |
| `relational_db` | 2g (includes the 1g `/dev/shm`) | `MT_RELATIONAL_DB_MEM_LIMIT` |
| `web_server` | 1g | `MT_WEB_SERVER_MEM_LIMIT` |

Expected use: about 6 to 7.5 GiB. Together with the live stack, this is close to the RAM of
the VM. Stop the stack with `mt-down` when the validation ends.

## Web image and NEXT_PUBLIC_CLOUD_ENABLED

The stack uses `ONYX_WEB_SERVER_IMAGE` from `product/deploy/release.env` (our GHCR build).

In v4.8.4, `web/src/lib/constants.ts` reads `NEXT_PUBLIC_CLOUD_ENABLED` for
`NEXT_PUBLIC_CLOUD_ENABLED` and `SERVER_SIDE_ONLY__CLOUD_ENABLED`. `web/Dockerfile` takes it as
a build argument. Next.js puts `NEXT_PUBLIC_*` values into the bundle at build time, so a
runtime value in `.env` has no effect. About 27 files in `web/src` use it (for example the
cloud sign-up pages and billing). Our image is built without it, so the web UI uses the
self-hosted pages against a multi-tenant backend. The upstream overlay does not set it either.
The API checks in `mt_checks.py` do not depend on it. A test of the cloud web pages needs a web
build with `NEXT_PUBLIC_CLOUD_ENABLED=true`.
