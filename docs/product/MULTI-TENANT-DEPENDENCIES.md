# Onyx v4.8.4 self-hosted multi-tenant (MT) without a control plane

Source: v4.8.4 checkout. All paths are relative to `scratchpad/v484/`. "UNCONFIRMED" means I read the
code but did not run it.

## 1. Sign-up, login, invitations

**Password registration works in MT.** `POST /api/auth/register` is always mounted (`backend/onyx/main.py:640-644`).
The password-disabled guard skips MT: `if safe and not MULTI_TENANT and not password_auth_enabled`
(`backend/onyx/auth/users.py:700`). Google OAuth is optional. It is mounted only when
`OAUTH_CLIENT_ID`/`OAUTH_CLIENT_SECRET` are set (`main.py:666-704`).

**Register path** (`UserManager.create`, `users.py:690-897`):
1. Disposable-domain check, signup rate limit, captcha (captcha only when `CAPTCHA_ENABLED` and the reCAPTCHA keys are set, `onyx/auth/captcha.py:101-107`), password check.
2. `referral_source` = **cookie** `referral_source` (`users.py:761-765`). The JSON body field is not read here.
3. `get_or_provision_tenant(email, referral_source, request)` (`users.py:767-775` → `ee/onyx/server/tenants/provisioning.py:93`):
   - `submit_to_hubspot` (`:112-113`). This call is outside the try block.
   - `resolve_tenant_id(email)` (`:115`, `ee/onyx/db/user_tenant_mapping.py:141`). It returns the tenant of an ACTIVE `user_tenant_mapping` row. If no active row exists and exactly one inactive row exists, it activates that row (`user_tenant_mapping.py:51-97`). Two or more inactive rows → 409 CONFLICT.
   - No mapping → `get_available_tenant()` (pool, `:693`) → else `create_tenant` (`:172`) → `provision_tenant` (`:200`). This step refuses 409 when `user_owns_a_tenant(email)` (any mapping row, `user_tenant_mapping.py:211`). It then records the shard, runs `CREATE SCHEMA`, runs `setup_tenant`, and runs `add_users_to_tenant([email])`.
   - `notify_control_plane` is skipped when `DEV_MODE` (`:157-158`).
4. Inside the tenant schema: if `user_count > 0`, it calls `verify_email_is_invited` (`users.py:782-788`). The first user needs no invite. The check does nothing unless the tenant setting `invite_only_enabled` is on, and that setting defaults to False (`users.py:299-311`, `onyx/server/settings/models.py:50`). In MT the real gate is the `user_tenant_mapping` row, which only an invite creates.
5. `enforce_seat_limit_locked` (`users.py:813-816`) → MT → `enforce_cloud_seat_limit` (`ee/onyx/server/tenants/billing.py:245`). This returns at once when the tenant "is on trial" (see §5).
6. **First user = admin:** `on_after_register` (`users.py:1302-1345`) computes `is_admin = user_count == 1 or email in default-admin list` and calls `assign_user_to_default_groups__no_commit(..., is_admin)`. That puts the user in the Admin default group. `create` computes `is_admin = user_count == 0` (`:799-802`) only for the "upgrade an existing non-web user" path.

**Invite flow (email based; Onyx has no invite codes):** `PUT /api/manage/admin/users` (`onyx/server/manage/users.py:558`, needs `FULL_ADMIN_PANEL_ACCESS` in the caller's own tenant):
- Trial invite cap. On a "trial" tenant it reserves invites against `NUM_FREE_TRIAL_USER_INVITES` (default 10, `onyx/configs/app_configs.py:1883`) and applies `enforce_invite_rate_limit` (`users.py:607-628`).
- `add_users_to_tenant(emails, tenant_id)` (`users.py:630-640` → `user_tenant_mapping.py:503`). It creates an **ACTIVE** mapping when the email has no active mapping anywhere. When the email is active in another tenant, it creates an **INACTIVE** mapping (an invitation) (`:569-575`).
- It writes the email to the tenant's KV invited list (`users.py:642-645`). It sends an invite email only if SMTP is configured. `register_tenant_users` (Stripe through the control plane) is skipped when `DEV_MODE` (`:682`).
- **New invitee:** at sign-up, `resolve_tenant_id` finds the active mapping and returns the inviter's tenant. `user_count > 0`, so the invited-list check passes. The invitee gets the **Basic** group (not admin). No accept step is needed.
- **Already-registered user invited elsewhere:** the invitation is an inactive mapping. `/me` returns `tenant_info.invitation` (`users.py:1115-1117`, `get_tenant_invitation` `user_tenant_mapping.py:911`). The user must call `POST /api/tenants/users/invite/accept {tenant_id}` (`ee/onyx/server/tenants/user_invitations_api.py:107`). The other option is `/invite/deny`. Accept activates the new row and deactivates or deletes the old rows (`user_tenant_mapping.py:680-820`). The UI then logs out and sends the user to `/auth/join` to sign up again in the new tenant (`web/src/sections/modals/NewTenantModal.tsx:41-70`). The old User row stays in the old schema, and the user can no longer log in there. **One active company per email address.** There is no tenant switcher. The accept/invite modals render only when `NEXT_PUBLIC_CLOUD_ENABLED` (`web/src/components/context/ModalContext.tsx:57`).
- **Uninvited user cannot join an existing company:** with no mapping, the user always gets a new tenant. Joining by "request to join" (`/tenants/users/invite/request`) requires `get_tenant_by_domain_from_control_plane` to match (`user_invitations_api.py:48-60`). Without a control plane that returns None, so the request is always refused. A second sign-up of an existing email does not create a tenant: `resolve_tenant_id` returns the existing tenant, and the duplicate is refused (UserAlreadyExists, or "invite-only" when that setting is on).
- Side effect: an invite reserves the email at once (active mapping). That person can no longer create their own company (409, `provisioning.py:204-207`).

**Login:** `authenticate` → `get_tenant_id_for_email` (catalog `public.user_tenant_mapping`) → it loads the user from that schema (`users.py:1537-1600`). `RedisStrategy.write_token` stores `{sub, tenant_id}` under an opaque token (`users.py:1695-1714`).

## 2. HubSpot and referral
- `submit_to_hubspot` returns at once when `HUBSPOT_TRACKING_URL` is unset (`provisioning.py:596-598`, env at `ee/onyx/configs/app_configs.py:166`). It is safe without a key. When the URL is set, a network exception is not caught and becomes a 500 on sign-up (`:620-621` runs before the try at `:117`).
- Referral source: the cookie `referral_source` is set by `web/src/app/auth/signup/ReferralSourceSelector.tsx:54`. It is only shown on the MT sign-up page. The body field `referral_source` (`web/src/lib/users/svc.ts:81`) is ignored by `create`. **Onyx never stores the referral locally.** `create_tenant` and `assign_tenant_to_user` do not use it (`# noqa: ARG001`). Only HubSpot and the control plane receive it. A local referral store is a missing piece.

## 3. setup_tenant (`provisioning.py:731-768`), step by step
1. `run_alembic_migrations(tenant_id)` (`schema_management.py`): the full main alembic chain into schema `tenant_<uuid>`. It takes about 80 s per tenant (`ee/onyx/background/celery/tasks/tenant_provisioning/tasks.py:28`). It runs synchronously in the sign-up request when the pool is empty.
2. `configure_default_api_keys` (`:375`): it creates LLM providers only if these env vars are set: `OPENAI_DEFAULT_API_KEY`, `ANTHROPIC_DEFAULT_API_KEY`, `OPENROUTER_DEFAULT_API_KEY` (each also needs `AUTO_PROVISION_DEFAULT_LLM_PROVIDERS`), `VERTEXAI_DEFAULT_CREDENTIALS` (+`VERTEXAI_DEFAULT_LOCATION`), and `COHERE_DEFAULT_API_KEY` (this one switches the FUTURE search settings to Cohere embed). With none set it logs and skips. **Every tenant admin must then configure an LLM.** The `*_DEFAULT_API_KEY` keys are shared by all tenants and count as "Onyx-managed" for LLM cost limits (`onyx/server/usage_limits.py:37-50`).
3. `setup_onyx(db, tenant_id)` (`onyx/setup.py:87-183`): index swap check, `setup_postgres` (default connector, credential and providers). Then **OpenSearch** `verify_and_create_index_if_necessary`. The index is **shared**: its name comes from search settings (e.g. the default model's index), and each chunk carries a `tenant_id` field. The chunk ID has a tenant prefix (`onyx/document_index/opensearch/schema.py:97-102`). Cluster settings and pipelines are set only at API startup (`setup_multitenant_onyx`, `setup.py:353-367`). Then `warm_up_bi_encoder`, a call to the local **model server** (indexing model server, `MODEL_SERVER_HOST`).
4. Redis: no setup step. Keys are prefixed per tenant through `get_redis_client(tenant_id=...)`.
5. File store: one shared bucket with key `{prefix}/{tenant_id}/{file}` (`onyx/file_store/file_store.py:273-288`). In MT the bucket is NOT created at startup (`main.py:427-429`, "done via IaC"). The bucket must exist.
6. External services: none in setup_tenant itself. Steps that fail: Postgres, OpenSearch, or model server down → the provisioning fails and rolls back (`provisioning.py:186-195`).

## 4. Celery in MT
- Beat `DynamicTenantScheduler` (`onyx/background/celery/apps/beat.py:26,87-110`) schedules only the `cloud_*` tasks. Each per-tenant template becomes a `cloud_beat_task_generator` (`beat_schedule.py:359-384`, `ee/onyx/background/celery/tasks/cloud/tasks.py:77`). The generator sends the task once per tenant from `get_all_tenant_ids()`, which lists all `tenant_` schemas on all shards (`onyx/db/engine/tenant_utils.py:171`). Gated tenants come from the Redis set `gated_tenants`, which is empty without a control plane. **The `public` schema is never scheduled in MT.**
- Queues: the generator runs on the default `celery` queue (primary worker). Pool provisioning runs on `monitoring`. All are already in the single `background` container's supervisord (`backend/supervisord.conf:30-127`). **One `background` container is enough.** It needs the same MT env as `api_server` (also `DEV_MODE` if you want parity).
- Pool: beat runs `cloud_check-available-tenants` every 2 min (`beat_schedule.py:409-417`). It pre-creates tenants up to `TARGET_AVAILABLE_TENANTS` (default **5**, `app_configs.py:1992`). Each pre-created tenant gets a full `setup_tenant`, and later migrations run on pool tenants too (`tasks.py:46-123,170`). Set it to 1–2 on a 15 GiB VM. Pool tenants are also in every per-tenant fan-out.
- Likely problem (UNCONFIRMED at runtime): `celery-beat-heartbeat` is scheduled only when not MT (`beat_schedule.py:432-466`). The supervisord watchdog restarts `celery_beat` when key `onyx:celery:beat:heartbeat` is missing for 15 min (`onyx/utils/supervisord_watchdog.py`, `supervisord.conf:137-145`). Expect a beat restart about every 15 min.
- Upgrades: the base `alembic upgrade head` refuses in MT (`backend/alembic/env.py:223-227`). Use `alembic -x upgrade_all_tenants=true upgrade head` plus `alembic -n schema_private upgrade head`.

## 5. Tier, license, limits, billing without a control plane
- `get_tier()` MT (`ee/onyx/utils/tier.py:133-165`) reads the Redis key `customer_tier` (tenant-prefixed, TTL 24 h, `tier_management.py:16-17,49-66`). On a miss it calls `fetch_billing_information`. On `RequestException` or `ValueError` (a missing `DATA_PLANE_SECRET` raises ValueError, `ee/onyx/server/tenants/access.py:12-14`) it returns **BUSINESS** and does not cache. The CP call is retried on every miss (30 s timeout if the host is unreachable but not refused). A Redis error also gives BUSINESS.
- `license_enforcement` middleware: **not registered in MT** (`ee/onyx/main.py:97-103`). The `/api/license` write endpoints refuse in MT.
- `tier_gate` runs in both modes (`ee/onyx/main.py:95`, `ee/onyx/configs/license_enforcement_config.py:73-93`). With the BUSINESS fallback, BUSINESS paths pass. **ENTERPRISE paths return 402**: `/admin/enterprise-settings/custom-analytics-script`, `/admin/enterprise-settings/scim`, `/manage/admin/standard-answer`, `/admin/token-rate-limits`, `/admin/hooks`, `/admin/log-export`, `/analytics` (non-admin), `/evals`, `/scim`. The `LICENSE_ENFORCEMENT_ENABLED` setting has no effect on `get_tier` in MT.
- Subscription gating: `tenant_tracking` middleware blocks a tenant only if it is in the Redis set `gated_tenants`, and it fails open (`ee/onyx/server/middleware/tenant_tracking.py:65-101`). With no control plane the set is empty, so no tenant is blocked.
- Trial: `is_tenant_on_trial` → `cached_is_tenant_on_trial` → CP. On any error it returns **True** (`ee/onyx/server/usage_limits.py:22-28`). Errors are not cached (`billing_cache.py`). Results:
  - The seat check is skipped (`billing.py:259-261`). Good: no Stripe.
  - The invite cap is `NUM_FREE_TRIAL_USER_INVITES` (default 10 new invites per tenant, lifetime counter `tenant_invite_counter`) (`manage/users.py:607-618`).
- `USAGE_LIMITS_ENABLED` defaults to `MULTI_TENANT` (`shared_configs/configs.py:241-246`). The checks are LLM cost (only for the `*_DEFAULT_API_KEY` keys), chunks indexed (docprocessing `tasks.py:1519`), API-key/PAT calls (trial default 0 = blocked), and non-streaming calls (trial 0). The limit comes from `get_tenant_usage_limit_overrides`, which returns **unlimited** when `DEV_MODE` or when the CP fetch `/usage-limit-overrides` fails (`ee/onyx/server/tenant_usage_limits.py:119-136`). The `background` container has no DEV_MODE, so it calls the CP and then falls back to unlimited. Each check still calls the CP for the trial flag. **Set `USAGE_LIMITS_ENABLED=false`.**
- Billing UI: with the official web build, the admin sidebar calls `/api/admin/billing/billing-information` and `/api/license` (`web/src/hooks/useBillingInformation.ts:19-21`, `useLicense.ts:14`). In MT the backend sends billing to `CONTROL_PLANE_API_BASE_URL/billing-information` (`ee/onyx/server/billing/service.py:63-67`). It fails with an OnyxError (502/503), so admins see an error or "no subscription" on the billing page. Chat is not blocked (fail-open). A cloud web build calls `/api/tenants/billing-information` → unhandled exception → 500. `useCloudSubscription` treats null as "subscribed" (`web/src/hooks/useCloudSubscription.ts:20-22`).
- **Every runtime outbound CP call** (`CONTROL_PLANE_API_BASE_URL`, default `http://localhost:8082`, `app_configs.py:1894`):
  | Call | Trigger | Safe without CP? |
  |---|---|---|
  | `POST /tenants/create` | new tenant | skipped by DEV_MODE (api_server) |
  | `GET /billing-information` | `get_tier` (each `/api/settings` and tier-gated request on a cache miss), trial checks (invite, seat, usage), admin billing page | yes (fallback), but slow if the host times out |
  | `GET /usage-limit-overrides` | usage checks | yes (unlimited); DEV_MODE skips it |
  | `GET /tenant-stripe-information` + Stripe | `register_tenant_users` (DEV_MODE skips), seat billing (trial skips) | yes |
  | `GET /tenant-by-domain` | `/tenants/existing-team-by-domain`, `/tenants/users/invite/request` | returns None (no join-by-domain) |
  | `DELETE /tenants/delete` | `/tenants/leave-team` by the last admin (`team_membership_api.py:45-60`) | **NO → 500**, DEV_MODE does not skip it |
  | checkout / portal sessions | upgrade buttons | error |
  `cloud.onyx.app` (`CLOUD_DATA_PLANE_URL`) is used only in self-hosted (non-MT) billing and license paths. It is not reachable in MT except `/api/license/claim`, which refuses in MT. PostHog is a no-op without a key.
- **Stub control plane:** not required for sign-up or chat. It is useful to (a) get ENTERPRISE tier, (b) keep the trial flag stable, and (c) avoid uncached retries. Minimum endpoints (bearer JWT signed with `DATA_PLANE_SECRET`; a stub can ignore it):
  - `GET /billing-information?tenant_id=` → `{"subscribed": false, "customer_tier": "ENTERPRISE"}`. This is parsed as `SubscriptionStatusResponse`: tier ENTERPRISE, trial=True, so seat billing stays off (`tenants/models.py:39-56`, `tier.py:100-131`).
  - `GET /usage-limit-overrides` → `[]`, or tenant overrides with `-1` for "unlimited".
  - `DELETE /tenants/delete` → 200.
  - `GET /tenant-by-domain` → `{}` (or omit it).
  - Optional: `POST /tenants/create` → 200 (lets you drop DEV_MODE).
  Alternative without a stub: write the Redis key `customer_tier` per tenant through `POST /api/tenants/tier-update` (needs header `X-API-KEY=EXPECTED_API_KEY` and a JWT with scope `tenant:create`, `access.py:27-50`). The key expires after 24 h, and the trial flag still calls the CP.

## 6. Frontend
- `NEXT_PUBLIC_CLOUD_ENABLED` is a **build arg** (`web/Dockerfile:68-69,157-158`). Next inlines `NEXT_PUBLIC_*` at build time, so setting it at runtime has no effect (UNCONFIRMED that the official image is built with it unset; very likely).
- What works with the official image: MT is detected at runtime from `/api/auth/type` `multi_tenant` (`web/src/lib/auth/svc.ts:35`, `svcSS.ts:42-44`). The sign-up page shows the referral selector and a Google button (`web/src/app/auth/signup/page.tsx:61-105`). The Google button points to `/api/auth/oauth/authorize`, which returns 404 unless OAuth is configured. `/auth/join` works.
- What needs a cloud build (`NEXT_PUBLIC_CLOUD_ENABLED=true`): the invite accept/deny modal and the "join team" modal (`ModalContext.tsx:57`), the pending-users list, cloud billing hooks, and `upgrade-insecure-requests` CSP (`proxy.ts:55`). The cloud build also points billing at `/api/tenants/*` and hides license and forgot-password.
- No tenant/team switcher and no "create new team" page exist. `/auth/create-account` links to `REGISTRATION_URL` (`INTERNAL_URL`||`127.0.0.1:3001`, `web/src/lib/constants.ts:63-64`), an external site. Billing pages are under `web/src/app/admin/billing/*`.
- web_server runtime env: `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true` (overlay). Nothing else MT-specific is read at runtime.

## 7. Session and cookie
The cookie `fastapiusersauth` holds an opaque token. Redis key `REDIS_AUTH_KEY_PREFIX+token` stores `{sub, tenant_id, ...}` (`users.py:1695-1714`). Every request resolves the tenant from the API-key/PAT header, then the Redis session, then the bearer token, then the anonymous cookie (`tenant_tracking.py:115-200`). An unauthenticated request goes to `public`. JWT backend is refused in MT (`users.py:1897-1901`). There is no subdomain routing. `WEB_DOMAIN` (`app_configs.py:134`) is used only for redirects, OAuth callbacks and email links. Compose Redis has no persistence (`docker-compose.yml:508`), so a restart logs everyone out and drops tier caches.

## 8. Migrating from single tenant
- No supported script exists. `backend/scripts` has only `tenant_cleanup/*`. **MT starts empty.**
- **Do not point MT at the existing database.** `alembic_tenants/env.py` uses the default version table `public.alembic_version` (no `version_table` arg, `alembic_tenants/env.py:50-66`). The single-tenant DB already has `public.alembic_version` with a main-chain revision, so `alembic -n schema_private upgrade head` should fail with "Can't locate revision" (high confidence, UNCONFIRMED by run). It also creates its tables in `public` (`alembic_tenants/versions/*`, `schema="public"`).
- Shared OpenSearch is a **data-leak risk**. MT uses the same index name for the same embedding model and adds `tenant_id` to the mapping. Single-tenant queries do not filter on tenant, so a single-tenant stack would see MT chunks. Use a separate OpenSearch, or retire the single-tenant stack. Also use a separate Redis DB/instance and a separate MinIO bucket.
- Manual import (UNCONFIRMED, not supported): create a tenant (sign up), then copy the `public` tables into `tenant_<id>` with matching alembic revision, add `user_tenant_mapping` rows for each user, and re-index all connectors (old chunks lack `tenant_id` and the tenant ID prefix). File rows keep their old object keys.
- Rollback: run MT as a separate compose project with its own volumes and `POSTGRES_DB`. Stop it and restart the single-tenant stack. Take a `pg_dump` and an OpenSearch snapshot before you start.

## 9. Checklist for self-hosted MT on Docker Compose (no control plane)
Configuration:
1. Use a separate compose project and volumes, or a new DB: `POSTGRES_DB=onyx_mt` (run `CREATE DATABASE` first; Onyx does not create it — UNCONFIRMED), plus a separate Redis, OpenSearch and MinIO bucket. The 15 GiB VM with 7 GiB in use cannot hold two full stacks comfortably. Plan to replace the single-tenant stack.
2. `api_server` and `background`: `MULTI_TENANT=true`, `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true`, `REQUIRE_EMAIL_VERIFICATION=false` (or configure SMTP), `DEV_MODE=true` on both. Note that DEV_MODE also switches OAuth connectors to dev redirect URIs (`ee/onyx/server/oauth/*.py`) and makes the api_server self-URL `127.0.0.1`. `AUTH_TYPE=cloud` is inert (`users.py:195-213`).
3. `api_server` command: `alembic -n schema_private upgrade head && uvicorn ...` (overlay). On upgrades, also run `alembic -x upgrade_all_tenants=true upgrade head`.
4. Set `USER_AUTH_SECRET` (startup refuses it empty unless DEV_MODE, `users.py:215-240`), `ENCRYPTION_KEY_SECRET`, `WEB_DOMAIN`, and `DATA_PLANE_SECRET`/`EXPECTED_API_KEY` (only if you use a stub or the tier-update endpoint).
5. `USAGE_LIMITS_ENABLED=false`, `TARGET_AVAILABLE_TENANTS=1` (or 2), and `NUM_FREE_TRIAL_USER_INVITES=<large>` (the trial fallback otherwise caps each company at 10 invites).
6. `CONTROL_PLANE_API_BASE_URL=http://<stub>` or leave the default (connection refused is fast). Leave `HUBSPOT_TRACKING_URL` and `POSTHOG_API_KEY` unset. Leave captcha off unless you set the reCAPTCHA keys.
7. Optional shared LLM keys (`OPENAI_DEFAULT_API_KEY` etc. + `AUTO_PROVISION_DEFAULT_LLM_PROVIDERS=true`). Otherwise each company admin adds their own LLM provider.
8. The MinIO bucket must exist (MT skips `file_store.initialize()`).
9. web_server: `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true`. For the invite accept modal, build a custom web image with `--build-arg NEXT_PUBLIC_CLOUD_ENABLED=true`.

Missing pieces (code or stub):
10. A stub control plane (§5) for ENTERPRISE tier, a stable trial flag, and leave-team. Without it: BUSINESS tier (ENTERPRISE paths return 402), "trial" invite caps, a broken billing page, and a 500 when the last admin leaves a company.
11. Referral codes: Onyx keeps only a free-text cookie and sends it to HubSpot or the control plane. Local storage and validation of referral codes needs new code, for example in a stub `/tenants/create` receiver (needs DEV_MODE off) or a small backend hook.
12. Invitation codes: Onyx invites are email-address mappings with no codes. If codes are required, that is new code. If email invites are acceptable, no code is needed (SMTP is optional; the invitee signs up with the invited address).
13. Existing users invited to another company need the cloud web build (modal) or a direct `POST /api/tenants/users/invite/accept`. No multi-company membership or switcher exists.
14. The beat heartbeat watchdog (likely beat restarts every ~15 min in MT). Optionally override the supervisord config or accept the restarts.
15. Single-tenant data import: no tool exists (§8).
16. Sign-up latency: with an empty pool, sign-up runs about 80 s of migrations in the request. Keep pool ≥1 and check proxy/nginx timeouts (UNCONFIRMED: actual duration on this VM).
