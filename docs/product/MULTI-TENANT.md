# Multi-tenant migration (Onyx v4.8.4)

Scope: move the live single-tenant VM install (Compose project `onyx`) to Onyx `MULTI_TENANT` mode.
Source of truth: tag `v4.8.4`. All `path:line` citations are relative to `backend/` unless noted.
Marks: **[confirmed]** = read in code. **[unconfirmed]** = not tested on our VM yet.

## 1. What `alembic -n schema_private` creates

- `alembic.ini:116-118` defines the `schema_private` section. It runs `alembic_tenants/`.
- `alembic_tenants/env.py:30` targets `PublicBase.metadata` only. It does not set `version_table`.
  So it uses the default table `public.alembic_version`.
- Tables (all in schema `public`, `onyx/db/models.py:5669-5830`):
  `user_tenant_mapping` (5689), `user_tenant_mapping_oauth_account` (5702), `available_tenant` (5735),
  `tenant_anonymous_user_path` (5752), `tenant_sso_domain` (5762), `tenant_invite_counter` (5796),
  `tenant_shard` (5815).
- Other objects: index `uq_user_active_email_idx` (one active company per email,
  `alembic_tenants/versions/ac842f85f932_*.py:37-39`), extension `pg_trgm`, and a read-only
  Postgres role (`alembic_tenants/versions/3b9f09038764_*.py:24-28`).
- The read-only role step fails if `DB_READONLY_USER`/`DB_READONLY_PASSWORD` are empty. The
  defaults are `db_readonly_user`/`password` (`onyx/configs/app_configs.py:2034-2036`). Set a strong
  `DB_READONLY_PASSWORD` in `.env`.

Collision with the live `public` schema **[confirmed]**:
- Table names do not collide. No per-tenant `Base` table uses these names (`PublicBase` is separate
  on purpose, `onyx/db/models.py:5669-5684`).
- `alembic_version` collides. In single-tenant mode `public.alembic_version` holds the head of the
  main tree. `schema_private` reads the same table and finds an unknown revision. Alembic stops
  with "Can't locate revision". It does not overwrite data, but it does not work either.
- The main tree refuses a plain `alembic upgrade head` when `MULTI_TENANT=true`
  (`alembic/env.py:223-227`). Tenant schemas keep their own `alembic_version`
  (`alembic/env.py:252-258`).
- With `MULTI_TENANT=true`, a request for tenant `public` is refused (`onyx/db/engine/sql_engine.py:558-559`).
  The old data in `public` is invisible to the MT app.
- Result: you cannot switch the live database to MT in place.

## 2. Is there a supported conversion tool?

No **[confirmed]**. Searched `backend/scripts/`, `backend/scripts/tenant_cleanup/`, `backend/ee/`,
`alembic*/`, `deployment/`, `docs/`. The only MT tooling is tenant cleanup and shard routing. The
upstream MT overlay is marked "Development only"
(`deployment/docker_compose/docker-compose.multitenant.yml:24`).

How MT derives tenant-scoped storage:

| Store | MT behavior | Citation |
|---|---|---|
| Postgres | One schema per company, `tenant_<uuid4>`. Only names that match the pattern count as tenants. | `ee/onyx/server/tenants/provisioning.py:181`, `onyx/db/engine/tenant_utils.py:23-29,128-140` |
| OpenSearch | Index name comes from the embedding model, not the tenant: `danswer_chunk_<model>`. All tenants share it. MT adds a `tenant_id` keyword field and filters on it. Chunk IDs get a short tenant prefix. Mapping is `dynamic: strict`. | `onyx/server/manage/search_settings.py:280`, `onyx/document_index/opensearch/schema.py:61,96-102,414,581-582`, `.../search.py:323-328` |
| File store (MinIO) | Key is `{prefix}/{tenant_id}/{file}`. Single-tenant keys use `public/`. Reads use the stored `FileRecord.object_key`. | `onyx/file_store/s3_key_utils.py:142`, `onyx/file_store/file_store.py:273-281,434` |
| Redis | Keys get a `{tenant_id}:` prefix. Not durable; start empty. | `onyx/redis/tenant_redis_client.py:31-53` |

Option A, fresh MT stack plus re-sign-up and re-index (recommended):
- Owner signs up. Onyx creates `tenant_<uuid>` and makes the first user admin.
- Re-create connectors, LLM provider and settings. Re-index the test corpus.
- Lost: chats, user passwords, connector state, uploaded files. Test data only, so this is acceptable.

Option B, manual schema move (not recommended, evaluated for completeness):
1. Restore the backup into a new database. `ALTER SCHEMA public RENAME TO tenant_<uuid>`.
2. Create a new `public`. Move `pg_trgm` and `pgcrypto` back with `ALTER EXTENSION ... SET SCHEMA public`.
   Reason: the rename moves them, and new tenant migrations call `public.gin_trgm_ops`
   (`alembic/versions/495cb26ce93e_*.py:474`). Without this step new sign-ups fail. **[unconfirmed]**
3. Run `schema_private`. Insert one active `user_tenant_mapping` row per user.
4. OpenSearch breaks: the old index has no `tenant_id` field and no chunk-ID prefix. MT rejects
   chunks without `tenant_id` (`schema.py:309-312`). Strict mapping blocks new fields. An alias does
   not help. You must delete the index and re-index anyway.
5. MinIO mostly works: old objects stay readable through the stored key. Tenant cleanup by prefix
   misses `public/` objects.
6. `setup_onyx` never runs for this tenant (it runs on provisioning,
   `ee/onyx/server/tenants/provisioning.py:731-760`). Defaults may be missing. **[unconfirmed]**
- Verdict: B keeps chats and users, but it is unsupported, it still needs a full re-index, and each
  upgrade can expose a new gap. Use A. Keep the single-tenant backup for any later data recovery.

## 3. Runbook for our VM

Fixed inputs: live project `onyx` (volumes `onyx_*`), validation project `onyx-mt` (volumes
`onyx-mt_*`, overlay `product/deploy/mt/compose.mt.yml`, `127.0.0.1:3200`), scripts
`product/deploy/backup.sh` and `restore.sh`.

MT settings to check in `onyx-mt/.env` before start:
- `MULTI_TENANT=true`, `AUTH_TYPE=cloud`, `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true` (overlay).
- `DEV_MODE=true`. Without it, each new company posts to `CONTROL_PLANE_API_BASE_URL`
  (default `http://localhost:8082`) and sign-up returns 500
  (`ee/onyx/server/tenants/provisioning.py:157-158,237-261`; `onyx/configs/app_configs.py:1894-1895`).
  `DEV_MODE` also skips seat billing calls (`onyx/server/manage/users.py:682,759`) and sets unlimited
  usage limits (`ee/onyx/server/tenant_usage_limits.py:119`).
- Side effect: `DEV_MODE` lets an empty `USER_AUTH_SECRET` pass (`onyx/auth/users.py:235`).
  Gate: confirm `USER_AUTH_SECRET` is set.
- `DB_READONLY_PASSWORD=<strong>`. `TARGET_AVAILABLE_TENANTS=1` (default 5 pre-built schemas,
  `onyx/configs/app_configs.py:1992`). `SUPER_USERS=[]` (impersonation, `ee/onyx/server/tenants/admin_api.py:26-29`).
- Leave `HUBSPOT_TRACKING_URL` unset (`ee/onyx/configs/app_configs.py:166`).

Step 0. Backup.
- Run `product/deploy/backup.sh <compose dir> <new folder> onyx`. Copy the folder off the VM.
- Gate: `SHA256SUMS` exists and `sha256sum -c` passes. Live stack is up again.

Step 1. Isolated validation on `onyx-mt` (live stack stays live).
- Start `onyx-mt` with fresh volumes. Do not start its connector syncs with live credentials.
- Gate 1a: api_server log shows `schema_private` at head. `\dt public.*` shows the 7 tables.
- Gate 1b: MinIO bucket exists (`MINIO_DEFAULT_BUCKETS`; MT does not create it,
  `onyx/main.py:428-431`). If missing, create it with `mc mb`. **[unconfirmed]**
- Gate 1c: OpenSearch MT path works. `setup.py:371` says MT OpenSearch support is unfinished for
  setup. Index creation relies on `VERIFY_CREATE_OPENSEARCH_INDEX_ON_INIT_MT` (`app_configs.py:565-568`).
  Index one small connector and search it. **[unconfirmed]**
- Gate 1d: run the requirement tests in section 4 with two test companies. All pass.

Step 2. Cut-over (short downtime).
1. Announce a stop. Run a final `backup.sh` of `onyx`. Gate: checksums pass.
2. `docker compose -p onyx stop`. Do not run `down -v`. Volumes stay.
3. Owner signs up on `onyx-mt` with ravi80847949@gmail.com. Gate: owner is admin of a new
   `tenant_<uuid>`; one `user_tenant_mapping` row with `active=true`.
4. Owner sets LLM provider, invite-only, connectors. Re-index the test corpus.
   Gate: indexing attempts succeed; a known test query returns the expected document.
5. Owner invites test users again. Gate: invited sign-up lands in the owner's company as basic user.
6. Point the nginx/HTTPS overlay upstream to the `onyx-mt` web and api services. DNS stays.
   Gate: `https://<domain>` login works; certificate is valid; `/api/health` is 200.
7. Watch `onyx-mt` logs for 24 hours. Keep `onyx` stopped, not removed.

Data carried over: none automatically. Owner account: re-created by sign-up (new password, new
user ID). Chats, chat files, personas, users, API keys: not carried. Documents: re-ingested from
sources. Old data stays readable only in the `onyx_*` volumes and the backup.

Step 3. Rollback.
1. Point the nginx/HTTPS overlay back to the `onyx` project. Stop `onyx-mt`.
2. `docker compose -p onyx start`. Gate: owner login, a test search, and an old chat work.
3. Only if `onyx_*` volumes are damaged: run `restore.sh <pre-cut-over backup> <compose dir> <new project>`.
   It restores into a new project only. Then point nginx to that project.
4. Changes made on `onyx-mt` after cut-over are lost on rollback. Tell users before cut-over.

Step 4. Cleanup (after 14 days without rollback). Remove `onyx_*` volumes only after a final backup.

## 4. Requirements mapping

| Owner rule | Status | Evidence |
|---|---|---|
| Uninvited first sign-up creates a new company and makes the user admin | Native | No mapping, so a tenant is provisioned (`ee/onyx/server/tenants/provisioning.py:115-151,181`). First user is admin (`onyx/auth/users.py:798-801`). Invite check skipped when the tenant is empty (`onyx/auth/users.py:782-788`). |
| Invited sign-up joins the inviter's company as member | Native | Invite writes a mapping (`ee/onyx/db/user_tenant_mapping.py:503-507`). Sign-up resolves it and activates a single pending row (`ee/onyx/db/user_tenant_mapping.py:51-85`). `user_count>0`, so role is basic and the invite list is checked (`onyx/auth/users.py:782-801`). Unknown until tested in our UI. |
| Existing logins go to their own company | Native for MT-created accounts | Login resolves the active mapping (`ee/onyx/db/user_tenant_mapping.py:100-124`). Old single-tenant logins do not carry over (section 3). One active company per email (`ac842f85f932:37-39`). |
| Owners administer only their company | Native | Sessions bind to the tenant schema; admin routes need `FULL_ADMIN_PANEL_ACCESS` inside it. Cross-tenant impersonation needs `SUPER_USERS` (`ee/onyx/auth/users.py:37`). Configuration: keep `SUPER_USERS=[]`. |
| Public company creation is open | Native + configuration | Any new email gets a company. Captcha and sign-up rate limit are optional (`onyx/auth/users.py:727-758`). Consider abuse limits. |
| Membership of existing companies only by invitation | Native | No path adds an uninvited user to an existing tenant. Domain "join" needs the control plane (`ee/onyx/server/tenants/user_invitations_api.py:50-61`) and admin approval (`:89-92`); without control plane it returns 404. Per-tenant `invite_only_enabled` defaults to false (`onyx/server/settings/models.py:50`) but is not needed for this rule. Unknown until tested. |
| Invitation codes separate from marketing referral codes | Needs code | Invitations are by email only; there is no invitation code. `referral_source` is a cookie sent to HubSpot and the control plane (`ee/onyx/server/tenants/provisioning.py:112-113`; `onyx/auth/users.py:761-764`). Separation holds today because invitation codes do not exist. A code-based invite needs new code. |

Open risks: MT mode is upstream "development only" on Compose. `DEV_MODE` has side effects
listed above. Re-test this document after each Onyx upgrade.

## 5. Results on the VM (4 October 2026, isolated stack)

The `mt-up` and `mt-check` actions of `axi-bootstrap-dev.yml` run the stack of section 3 on the
development VM next to the live single-tenant install. Evidence:
`product/test-corpus/evidence/2026-10-04-vm-mt-up-run31.txt` and `...-vm-mt-check-run32.txt`.

| Acceptance item | Result |
|---|---|
| Register Company A and Company B without an invitation | PASS. Each sign-up returns 201, `/api/me` shows a distinct `tenant_<uuid>` team and the `admin` capability. |
| Invite a member into A | PASS. `PUT /api/manage/admin/users` records the invitation (`email_invite_status: DISABLED`, no SMTP). The member registers, lands in A, has basic capabilities only and gets 403 on the user list. |
| B's invitations stay in B | PASS. The invited address appears in B's list and not in A's. |
| Documents and search | PASS. A's connector document is found by A's owner and member and not by B; B's document is found by B only. |
| Chats | PASS. B gets 404 on A's chat session; A's member gets 403 on the owner's session. |
| Connectors, agents, files, projects | PASS. Each owner lists only their own connector and persona; B gets 404 on A's persona and user file; project lists do not cross. The member sees A's persona only when it is public. |
| APIs | PASS. A personal API key of A's owner resolves to A and searches only A's documents. |
| Repeat after restart | PASS. `mt-restart` (run 33) recreated every container and repeated 29 checks: same workspaces, same roles, same separation (`...-vm-mt-restart-run33.txt`). |

Not covered by these runs: email delivery (no SMTP), the invite accept and deny modal of the
cloud web build (the stack ran the single-tenant branded image), billing pages, and the
control-plane calls listed in `MULTI-TENANT-DEPENDENCIES.md`.

## 6. Cutover of the public URL to the multi-tenant stack

The production multi-tenant stack is Compose project `onyx-saas` in `/srv/onyx-saas`. It uses
`compose.saas.yml` (application settings) and `compose.https.yml` (ports 80 and 443, the
Let's Encrypt files). The live single-tenant project `onyx` keeps its folder `/srv/onyx` and
its volumes `onyx_*`. Nothing deletes them. Run the steps with the workflow
`axi-bootstrap-dev.yml` (input `action`). Each step keeps a log in `/srv/onyx/evidence/`.

Preconditions of `cutover`:

- `release.env` has a value in `ONYX_BACKEND_IMAGE_CLOUD`: the digest of the image that
  `axi-build-backend.yml` builds (v4.8.4 with `product/deploy/backend-patch`). While the value
  is empty, `cutover` and `saas-update` stop before they change anything.
- `/srv/onyx/secrets/model.env` holds `MODEL_API_KEY` and `MODEL_NAME` (the `model` action
  writes both). `MODEL_PROVIDER` defaults to `fireworks_ai`. `MODEL_API_BASE` is optional.
- The owner account (input `owner_email`) exists and is active in the live stack.

| Order | Action | What it does |
| --- | --- | --- |
| 1 | `inventory` (uses `owner_email`) | Read-only. Counts users, connectors, documents, chats, files, assistants, LLM providers and groups of the live stack. Shows the accounts by category (see below) with their chat sessions and user files, whether the owner is present and admin, and the account transfer plan (a dry run). The log shows counts only. The emails and connector names go to `inventory.txt` (mode 600) in the evidence folder. |
| 2 | `cutover` (needs `letsencrypt_email` and `owner_email`) | See "Cutover steps" below. |
| 3 | `saas-journey` | The customer-journey test of section 7 against the public URL. |
| 4 | `saas-restart` | `down` without `-v`, `up -d`, health, redirect, volume comparison, then `saas-journey-after-restart`. |
| - | `saas-check` | Runs `mt_checks.py` (two test companies, separation checks). It configures no model. |
| - | `saas-defaults`, `saas-defaults-dry-run` | Runs `python -m onyx.axi.backfill [--dry-run]` in `api_server`. It gives every tenant, also the pre-built pool tenants, the platform defaults that it lacks, and prints one outcome for each tenant. It never overwrites a company setting. |
| - | `saas-update` | Deploys a commit on `onyx-saas`: release files and overlays, pinned images, platform model from `model.env`. `.env` keeps its secrets. Then `pull`, `up -d`, health, redirect check and the backfill. |
| - | `rollback` | Stops `onyx-saas` (volumes stay) and starts `onyx` again. The old service is back in about 2 minutes. Refuses nothing except a missing live `.env`. |
| - | `saas-down` | Stops `onyx-saas`. The public URL answers nothing until `cutover` or `rollback`. There is no destroy action for this stack. |

Account categories of `inventory` (from the live `user` table):

- owner: the address of `owner_email`. Admin comes from the permission `admin` in
  `effective_permissions` (membership of the Admin group). The column `role` is a tombstone
  in v4.8.4. Without `effective_permissions` the inventory shows `unknown`.
- synthetic: addresses that end in `@example.com` (test accounts).
- service: API keys, bots and placeholders: `account_type` is not `STANDARD`, or the address
  ends in `onyxapikey.ai` (`onyx/db/api_key.py`), or it is `anonymous@onyx.app` or
  `no-auth-placeholder@onyx.app`.
- other: all other accounts (other real accounts). The log shows their count only.

### Cutover steps

1. Checks: `onyx-saas` does not run, the live stack is healthy, the certificate exists,
   `ONYX_BACKEND_IMAGE_CLOUD` is set, `model.env` exists, and the transfer plan can run.
   Nothing is changed when a check fails.
2. Cold backup of the live stack into `/srv/backups/<time>-pre-cutover`, with checksum check.
3. Prepares `/srv/onyx-saas`: a new `.env` (never a copy of the live one), the cloud web and
   backend images, and `FIREWORKS_DEFAULT_API_KEY`, `FIREWORKS_DEFAULT_MODEL`,
   `FIREWORKS_DEFAULT_PROVIDER` and `FIREWORKS_DEFAULT_API_BASE` from `model.env`. The log shows
   the key names only. Copies the certificate and the nginx files, pulls the images.
4. Reads the rows of the owner and of each active other real account (email, password hash,
   `is_verified`, admin) from the live database into `/srv/onyx-saas/account-transfer.json`
   (mode 600). The hashes go through a pipe only; the log never shows them.
5. Stops `onyx` (volumes stay), starts `onyx-saas`, waits for
   `https://my-knowledge.duckdns.org/api/health` and checks the redirect.
6. Account transfer (`transfer_accounts` in `vm-bootstrap.sh`, `product/deploy/transfer_accounts.py`):
   - Signs up the owner with `POST /api/auth/register` and a random one-time password. This is
     the native sign-up: a new company, the owner is its admin, the platform defaults apply.
   - Logs in as the owner, invites each other real account (`PUT /api/manage/admin/users`) and
     signs up each one with its own random one-time password. They join the owner's company
     as members. Former admins get admin access (`PATCH /api/manage/admin/users/admin-access`).
   - Reads the tenant schema of the owner from `public.user_tenant_mapping`. Copies each old
     password hash into `"<schema>"."user"` in one transaction:
     `transfer_accounts.py copy-sql | docker compose exec -T relational_db psql -f - | transfer_accounts.py verify`.
     The values reach psql as `\set` lines of the script on stdin, never on a command line.
   - Reads the hashes back and prints only `owner: transferred, password unchanged, admin` and
     counts. The one-time passwords are discarded. Each account logs in with its old password.
   - Passwords are never reset. `@example.com` and service accounts are not transferred.
     Inactive accounts are not transferred.
7. `python -m onyx.axi.backfill` gives every tenant, also the pool tenants, the platform defaults.

When a step after the stop fails, the cutover fails. The EXIT trap stops `onyx-saas` and starts
`onyx` again, and the log says so. Accounts that the transfer created stay in the `onyx-saas_*`
volumes. The next `cutover` does not sign them up again, but copies the hashes again. If the
owner already has a company in `onyx-saas`, the transfer cannot invite new accounts (the owner
password is unknown to the script); the log shows their count, and the owner invites them.

Limits of the transfer:

- The sign-up limit of the stack is 5 sign-ups per hour from one address. The transfer resets
  the counter and needs 1 + N sign-ups. For more than 4 other real accounts, the plan stops the
  cutover. Then add `SIGNUP_RATE_LIMIT_ENABLED=false` to `/srv/onyx/secrets/saas.env`.
- In `MULTI_TENANT` mode, v4.8.4 refuses `+` in the local part of a new address. The plan stops
  the cutover when an account has such an address.

The backup folder holds `db_volume.tar.gz`, `opensearch-data.tar.gz`, `minio_data.tar.gz`,
`file-system.tar.gz`, `env.backup` (the live `.env`, with secrets) and `SHA256SUMS`. Copy it off
the VM. `product/deploy/restore.sh` restores it into a fresh folder.

### What is not migrated

Only accounts move. Chats, documents, connectors, uploaded files, projects, assistants and
settings of the old workspace stay in the `onyx_*` volumes and in the backup. They are not
migrated. `rollback` makes them reachable again. After the cutover, the owner sees an empty
company with the platform model "22nd X AI model" and the knowledge rules of the default
assistant, and adds documents again.

### Deploys after the cutover

`axi-deploy-dev.yml` runs `deploy-remote.sh` on every push to `main`. When the active stack is
`onyx-saas`, the script runs `saas-update` of that commit and never starts project `onyx`:
ports 80 and 443 belong to `onyx-saas`. See section 9. A manual `saas-update` run
(`axi-bootstrap-dev.yml`) does the same.

### Rollback

`rollback` returns the previous service with all its data. Companies created on `onyx-saas`
after the cutover stay in the `onyx-saas_*` volumes and come back with the next `cutover`.
Remove the `onyx_*` volumes only after a final backup and a decision to stay.

### Known limits

- Leave team: nginx answers every `POST /api/tenants/leave-team` with 409
  (`LEAVE_TEAM_GUARD`, `product/deploy/nginx/render-redirect.sh`). In v4.8.4 the last admin who
  leaves asks the control plane to delete the team, and this deployment has none. The guard is
  a temporary limitation, not a complete implementation: no user can leave a team. An admin
  removes the account instead.
- Email: invitations, verification and password reset need SMTP (the `smtp` action). Without
  SMTP, the invite list records the address (`email_invite_status: DISABLED`), and the invited
  person signs up with that address.

## 7. Customer-journey test (`saas-journey`)

`product/test-corpus/saas_journey.py` acts like customers do. It never configures an LLM
provider, a default model or the default assistant. Details: `product/test-corpus/README.md`.

| Step | Checks |
| --- | --- |
| Sign-up | Owner A and owner B sign up with the request of the web form. Each one is admin of a different company. |
| Platform model | Without setup, `GET /api/llm/provider` (the listing of the chat UI) shows the default "22nd X AI model" to each owner. The default assistant holds the knowledge rules. Owner A gets an answer to "Reply with the single word OK" before any document exists. |
| Platform key | The admin provider listing masks the key. A change of the API base with the stored key is refused (4xx with the guard message), and the provider stays unchanged. A test call with the stored key and a foreign API base is refused. Member A gets 403 on the admin LLM endpoints. With `MODEL_API_KEY` set, no response body of the whole run holds the key. |
| Knowledge | Owner A indexes the four public corpus files and puts the restricted file into a private project. Company B indexes only `refund-policy-2026.md`. |
| Invitation | Owner A invites member A. Member A lands in company A without admin access and gets 403 on the user list. Owner A's user list shows member A; owner B's does not. |
| Answers | Member A gets Q1 to Q5 with the assertions of `run_checks.py`. Owner A gets Q5 in the private project. |
| Separation | Owner B's chat on Q1 says that its documents lack the information, without citations. Search results, chat sessions, user files, connectors and assistants do not cross. |

The test accounts are `owner-a-<tag>`, `owner-b-<tag>` and `member-a-<tag>` at `example.com`. Each
first run makes a new tag (`journey-` plus 8 hex characters, in `/srv/onyx-saas/journey-tag`), so
it creates two new test companies on the production stack. The passwords derive from the salt
in `/srv/onyx-saas/journey-salt` (mode 600, never printed). `saas-journey-after-restart` and
`saas-restart` reuse the tag of the last first run. `--no-chat` (after-restart mode) skips the
chat answers; the restore test of section 11 uses it on a copy without the platform key.

## 8. Code Interpreter and Web Search

Status: configured; the first `saas-tools-check` run on the VM is pending. Line numbers refer
to `backend/` at v4.8.4.

### What runs

The overlay `product/deploy/mt/compose.tools.yml` adds three services to `onyx-saas`. They are
in the Compose profile `code-interpreter` (`COMPOSE_PROFILES=s3-filestore,code-interpreter` in
the saas `.env`). `release.env` pins each service image as `tag@sha256:...` and the executor
image by digest. The `compose-config` job of `axi-product-ci.yml` renders this file set and
fails when an image of `release.env` is not pinned or does not reach the render.

| Service | Role |
| --- | --- |
| `code-interpreter` | The sandbox API of the upstream Python tool (`CODE_INTERPRETER_IMAGE`). `api_server` and `background` reach it as `CODE_INTERPRETER_BASE_URL=http://ci-gateway:8000` (`compose.saas.yml`). It starts one executor container per run (`PYTHON_EXECUTOR_IMAGE`) through the Docker socket of `ci-host-setup`. Its `env_file` is reset: the secrets of `.env` do not reach it. It is only on the internal network `ci_internal`: no route to the host, the internet or the other services. Staged files live in a 1 GiB tmpfs (mode 0700); `tools/ci-cleanup.sh` removes files older than 30 minutes. |
| `ci-gateway` | nginx between `api_server` and the sandbox API (`CI_GATEWAY_IMAGE`, `product/deploy/tools/ci-gateway.conf`). The sandbox API has no authentication and one file store for every company, so the gateway passes only the calls of the Onyx client (`code_interpreter_client.py`): `GET /health`, `POST /v1/execute`, `POST /v1/execute/stream`, `POST /v1/files` (upload) and `GET`/`DELETE /v1/files/<uuid>`. Everything else gets 403: the file listing `GET /v1/files`, `/v1/sessions/*` (long-lived executors with bash) and the API description. |
| `searxng` | Keyless metasearch for the Web Search tool (`SEARXNG_IMAGE`; `product/deploy/tools/searxng-settings.yml` enables the JSON format that the client needs, `searxng_client.py:26-28`). Only the application containers reach it. |

### Executor restrictions and limits

- Each run is one container of the executor image, started by the sandbox API with
  `--network none`, 1 CPU, 256 open files, 512 MB of memory and a CPU time limit of 60 s
  (`compose.tools.yml`). It runs as uid 65532, has no Docker socket, no network and none of
  the stack secrets in its environment. `tools_check.py` step f verifies these four points
  from inside a run.
- A run stops after 60 s: Onyx sends `CODE_INTERPRETER_DEFAULT_TIMEOUT_MS` (upstream default
  60 000 ms, `onyx/configs/app_configs.py:1665`) and the sandbox API caps it at the same value
  (`MAX_EXEC_TIMEOUT_MS`). The test requires the stop of an endless loop within 90 s. Output
  is cut at 50 000 characters (`CODE_INTERPRETER_MAX_OUTPUT_LENGTH`). At most 25 chat files
  and 100 MiB are staged into a run (`CODE_INTERPRETER_MAX_STAGED_FILES` and `_BYTES`,
  `app_configs.py:1678-1684`).
- Memory budget next to the stack: sandbox API 3 GiB, all executors together 3 GiB (a
  systemd slice of the executor daemon), SearXNG 512 MiB, gateway 128 MiB.
- Generated files are saved in the file store of the company with the origin
  `CHAT_IMAGE_GEN` (`python_tool.py:484-497`) and served by `GET /api/chat/file/{id}`.
  Another company gets 404: the file record is in the schema of the company
  (`user_can_access_chat_file`, `onyx/access/access.py:221-286`). In v4.8.4 every user of the
  same company who knows the file id can read a `CHAT_IMAGE_GEN` file (upstream TODO at
  `access.py:269-284`). The test records that status as INFO.

### Rootless daemon or main-socket fallback

`ci-host-setup <sha> [main-socket]` (workflow actions `ci-host-setup` and
`ci-host-setup-main-socket`) prepares the host:

- `rootless` (default): a rootless Docker daemon of the unprivileged host user `ci-sandbox`
  runs the executor containers. The sandbox API gets that daemon's socket (`DOCKER_SOCK_PATH`
  in the saas `.env`, from the marker `/srv/onyx/ci-executor.env`). An escape from an
  executor lands in that user, not in root; it cannot reach the main daemon, the stack
  containers or the volumes.
- `main-socket`: the sandbox API gets `/var/run/docker.sock` of the main daemon, as the
  upstream file does (`docker-compose.yml:576-580`), and every executor runs in the cgroup
  `code-exec.slice` (`CI_EXECUTOR_RUN_ARGS`). The sandbox API then has root-equivalent
  access to the host. Use it only when the host cannot run rootless Docker (no user
  namespaces, no `newuidmap`), and plan the move back. The action log shows the mode in use.

### SearXNG keyless search and its limits

SearXNG sends each query to public engines without an API key (`provider_requires_api_key`,
`web_search/providers.py:62-67`). Limits: the engines rate-limit or captcha the VM address,
so a query can return nothing (the test retries once); result quality and freshness vary;
the client keeps the first `num_results` (default 10) results (`searxng_client.py:41-43`);
one instance serves every company. There is no per-query cost.

### A keyed provider replaces it

The platform defaults (`product/deploy/backend-patch`, `onyx/axi`) give every company one
search provider named "22nd X AI web search" from `WEB_SEARCH_DEFAULT_PROVIDER`,
`WEB_SEARCH_DEFAULT_API_KEY`, `WEB_SEARCH_DEFAULT_CONFIG` and `WEB_SEARCH_DEFAULT_DISPLAY_NAME`
(`compose.saas.yml`, `api_server` and `background`). `saas_prepare` writes the SearXNG values
into the saas `.env` when it has no `WEB_SEARCH_DEFAULT_PROVIDER` yet: type `searxng` with the
internal SearXNG URL. To use a keyed provider, set in `/srv/onyx/secrets/saas.env`:
`WEB_SEARCH_DEFAULT_PROVIDER` (`serper`, `exa`, `brave`, `tavily` or `google_pse`),
`WEB_SEARCH_DEFAULT_API_KEY`, and `WEB_SEARCH_DEFAULT_CONFIG` (JSON) when the type needs
settings, for example `{"search_engine_id": "..."}` for Google PSE (`providers.py:120-128`).
Then run `saas-update` (or `saas-defaults`): the values of `saas.env` win over the SearXNG
defaults, and the backfill updates the platform provider of every company and leaves a
company's own providers alone. The key is stored encrypted for each company; the admin
listing shows a mask only (`manage/web_search/api.py:82-86`).

### Per-company availability

- Code Interpreter: each company has its own switch (`code_interpreter_server.server_enabled`,
  default true, `onyx/db/models.py:7086`; `GET`/`PUT /api/admin/code-interpreter`,
  `manage/code_interpreter/api.py:38-56`). The Python tool is listed only when the switch is
  on and the sandbox API answers `/health` (`python_tool.py:259-267`; `GET /api/tool` hides
  unavailable tools, `features/tool/api.py:394-398`).
- Web Search: the tool is listed only when the company has an active search provider
  (`web_search_tool.py:141-145`). A company admin can deactivate the platform provider or add
  own ones (`/api/admin/web-search/search-providers`). Open URL is always listed and uses the
  built-in crawler; no content provider is active by default.
- The backfill keeps a company's choice: a switched-off interpreter stays off, an inactive
  platform provider stays inactive. `tools_check.py` step g records both states for a check
  after the next backfill.

### No per-company caps

The sandbox API, the executor daemon and SearXNG are shared by all companies. There is no
per-company quota: the only limits are per run (time, output, staged files) and the host
resources of the executor daemon. One company can occupy the executors for all others; a run
waits or fails when the host is full. A rate limit from a public engine affects every company.
Watch `docker stats` and the sandbox API log. A per-company cap needs new code.

### Acceptance test

`saas-tools-check <sha>` runs `product/test-corpus/tools_check.py` against the public URL
with the accounts of the last `saas-journey` run and one new company C. Steps a to g are in
`product/test-corpus/README.md`.

## 9. Automatic deployment

- `axi-deploy-dev.yml` runs on every push to `main` that passed the product checks, and by
  hand from `main`. On the VM, `product/deploy/deploy-remote.sh` reads `/srv/onyx/active-stack`.
  With `onyx-saas` it takes the VM lock `/srv/onyx/.vm-ops.lock`, stages `vm-bootstrap.sh` of
  the deployed commit and runs `saas-update <sha>` detached, with the log streamed to the
  workflow. With `onyx` the single-tenant path of RUNBOOK.md, section 11, runs. The script
  stops when both projects run or the marker and the containers disagree, and it never starts
  project `onyx` while `onyx-saas` is active.
- Policy: an automatic deploy deploys only what `release.env` and the overlays pin at that
  commit (image digests, compose overlays, nginx and SearXNG files, settings). It never changes
  the Onyx release. A new `ONYX_RELEASE_TAG` migrates the database, so it needs a manual run:
  `axi-deploy-dev.yml` with `allow_release_change`, or `axi-bootstrap-dev.yml` with the
  action `saas-update-release-change`. `saas-update ... release-change` takes a backup
  (section 11) before the migration.
- RESULT line: the last line of the `saas-update` log is `RESULT=deployed|unchanged|rolled-back|failed`.
  `deployed`: the new containers run and the public URL is healthy. `unchanged`: the commit
  pins what already runs. `rolled-back`: the new state failed its health check and the
  previous pins run again. `failed`: the update stopped; read the log. Two more values can
  occur: `rollback-failed` (the update and its rollback failed; repair by hand) and `missing`
  (`deploy-remote.sh` found no RESULT line: the script died). The workflow summary shows the
  line and the log is an artifact. The job fails for every value except `deployed` and
  `unchanged`, and for a non-zero exit code of `saas-update`.
  `/srv/onyx/deploy.log` keeps one line per run; `/srv/onyx-saas/deployed.env` holds
  `DEPLOYED_SHA`.
- Rollback of pins: commit the previous digest in `release.env` and push to `main`; the
  automatic deploy applies it. The script refuses a commit that does not include
  `DEPLOYED_SHA` (a re-run of an old workflow run); to deploy an older commit on purpose, run
  `ALLOW_ROLLBACK=1 bash -s -- <sha> </srv/onyx-src/product/deploy/deploy-remote.sh` on the VM.
- One operation at a time: the GitHub concurrency group `bootstrap-dev` serialises both
  workflows, and the VM lock serialises the scripts. `VM_OPS_LOCKED=1` tells `vm-bootstrap.sh`
  that the caller holds the lock.

## 10. Platform key rotation

Every company uses the platform model with the platform key (`FIREWORKS_DEFAULT_API_KEY` in
the saas `.env`, and the provider row "22nd X AI model" of each company). To rotate it:

1. Create the new key at the provider. Keep the old key valid until step 6.
2. Store it on the VM: action `model` with the secret `MODEL_API_KEY` (or `sealed_model_key`)
   writes `/srv/onyx/secrets/model.env` (mode 600). The log shows key names only.
3. Action `saas-rotate-key-dry-run` (`saas-rotate-key <sha> dry-run`): the log shows what
   changes (the `.env` key, the containers that restart, the companies whose platform
   provider gets the new key). Nothing changes yet.
4. Action `saas-rotate-key`: writes the new key into the saas `.env`,
   recreates `api_server` and `background`, and updates the platform provider of every
   company that uses the platform key. A company with its own key is not changed. The API
   answers nothing for a short time while the containers restart.
5. Verify: `saas-journey-after-restart` (one chat answer per company) and the api_server log.
6. Revoke the old key at the provider.

## 11. Backup and restore test

- `saas-backup <sha>`: cold backup of `onyx-saas` into `/srv/backups/<time>-saas`. The
  action stops the containers (volumes stay), archives the Postgres, OpenSearch, MinIO and
  file-system volumes, copies the saas `.env` (secrets, mode 600), writes `SHA256SUMS`, then
  starts the stack again and waits for health. The public URL answers nothing while the
  archive runs (minutes; it grows with the data). `saas-update ... release-change` takes the
  same backup before a migration.
- Retention: the action keeps the newest 7 `*-saas` backups in `/srv/backups` and removes
  older ones; the log names the kept folders. Not saved: Redis (not durable), the images
  (pulled again from the digests) and the host setup of `ci-host-setup`. `saas-update` keeps
  the last 5 snapshots of the saas `.env` and the compose files in `/srv/onyx-saas/rollback/`
  for its own rollback; they are not a data backup.
- `saas-restore-test <sha> [backup path]`: restores the newest backup, or the given
  `/srv/backups/<name>` (workflow input `backup_path`), into the isolated Compose project
  `onyx-saas-restore` (`/srv/onyx-saas-restore`, `compose.restore.yml`, `127.0.0.1:3300`),
  without the platform key. It waits for health, runs
  `saas_journey.py --after-restart --no-chat` with the journey accounts of the backup
  (identities, workspaces, the masked key, the search separation; no chat answers), then
  removes the copy and its volumes. Production is not touched. The copy needs 5 GiB of free
  disk and memory for a second stack; the action stops when the VM lacks them.
- An off-VM copy is still needed: the backups live on the VM disk. Copy each folder off the
  VM (`scp` or `rsync` to another machine or object storage) and check
  `sha256sum -c SHA256SUMS` there. The folder holds the `.env` with the secrets: store it
  encrypted.
