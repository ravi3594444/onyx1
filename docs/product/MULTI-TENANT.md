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

