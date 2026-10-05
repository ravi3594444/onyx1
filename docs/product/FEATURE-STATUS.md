# Feature status: Onyx v4.8.4 on the development VM

Product name: 22nd X AI. URL: https://my-knowledge.duckdns.org. Edition: Community (CE), no Business
license, `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=false`, license enforcement on. Hosted LLM
credentials (Fireworks AI) are supplied and in configuration. No SMTP, web-search, image or voice
provider keys.

> **Update, 5 October 2026.** The public URL now runs the multi-tenant stack `onyx-saas`
> (`docs/product/MULTI-TENANT.md`, sections 6 and 7). There, `MULTI_TENANT=true` loads the EE
> tenancy code without a license (upstream behaviour for multi-tenant mode); license
> enforcement is not changed. Every new company gets the platform model and the knowledge
> instructions through native tenant setup (`product/deploy/backend-patch`). The table below
> describes the single-tenant stack `onyx`, which stays stopped with its volumes for rollback.
> Not available on `onyx-saas`: email delivery (no SMTP), invite accept/deny dialog (Onyx
> joins an invited address on sign-up instead), billing pages, team-by-domain join, and
> "Leave team" (nginx answers 409 for every request: a temporary limitation, not a complete
> implementation).

Source of truth for "what exists": the `v4.8.4` tag checkout (commit `d15d445`). Paths below are
relative to that tree. VM evidence: `docs/product/TRD-PLAN.md`, section "Development VM evidence",
and `product/test-corpus/README.md` with `product/test-corpus/evidence/`.

## How the edition switch works

- `backend/onyx/main.py:797` loads `get_application` through `fetch_versioned_implementation`.
  With the flag `false`, the CE app from `backend/onyx/main.py` runs. The EE app in
  `backend/ee/onyx/main.py` is not loaded. Its routers (user groups, analytics, query history,
  hooks, enterprise settings, SCIM, license, billing) are not registered. On the VM they answer 404.
- With the flag `true`, two middlewares apply: `backend/ee/onyx/server/middleware/license_enforcement.py`
  (gated or expired license) and `backend/ee/onyx/server/middleware/tier_gate.py` (402 per path).
  The path-to-tier map is `backend/ee/onyx/configs/license_enforcement_config.py`
  (`PATH_PREFIX_MIN_TIER`). The web mirror is `requiredTier` in `web/src/lib/admin-routes.ts`.
- "Blocked by a license" below means: the code needs the flag `true` and a Business or Enterprise
  tier. The VM has neither. The CE routes are not affected.

Status values: **Verified** = Configured and verified on the VM. **Needs credentials** = Available,
needs provider or source credentials. **License** = Blocked by a license. **Not verified** = Not
yet verified. **Not supported** = Not supported in this release.

## Knowledge

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| File ingestion (upload) | `backend/onyx/connectors/file/`, `POST /manage/admin/connector/file/upload` in `backend/onyx/server/documents/connector.py` | CE | none | Verified | Run 9: 4 public documents and 1 project file indexed (`...vm-verify-run9.txt`). |
| Connector catalogue | `DocumentSource` in `backend/onyx/configs/constants.py`; `CONNECTOR_CLASS_MAP` in `backend/onyx/connectors/registry.py`; `SOURCE_METADATA_MAP` in `web/src/lib/sources.ts` | CE | source credentials per connector | Needs credentials | `DocumentSource` has 61 members. 5 are not connectors (`ingestion_api`, `not_applicable`, `mock_connector`, `user_file`, `craft_file`). The registry maps 57 sources; 56 are real connectors (plus `mock_connector`). `sources.ts` has 60 `ValidSources` entries plus the alias `federated_slack`; `zoom` has no web entry. Only the File connector was tested. No other connector was tested. |
| Indexing (Celery) | `backend/onyx/background/celery/`, `backend/onyx/server/documents/cc_pair.py` | CE | none | Verified | Run 9 "Index" PASS. |
| Scheduled sync and pruning | `DEFAULT_PRUNING_FREQ = 7 days` in `backend/onyx/configs/app_configs.py:1454`; `POST /manage/admin/cc-pair/{id}/prune` | CE | none | Verified, with one open issue | Manual prune PASS. The pruning race is reproduced and stays open; workaround in RUNBOOK section 7a. |
| Document sets | `backend/onyx/server/features/document_set/api.py` (`/manage/admin/document-set`, `/manage/document-set`) | CE | none | Not verified | Route exists in the CE app. Not part of the VM checks. |
| Document update (re-index) | `targeted_reindex_router` in `backend/onyx/main.py:568`; `POST /manage/admin/connector/{id}/files/update` | CE | none | Verified | Run 9 "Update" PASS (search part). Model answer skipped. |
| Document deletion | `POST /manage/admin/deletion-attempt` in `backend/onyx/server/manage/administrative.py`; `DELETE /onyx-api/ingestion/{document_id}` | CE | none | Verified | Run 9 "Deletion" PASS. Removed file leaves search in about 5 s. |
| Project files (per-user) | `backend/onyx/server/features/projects/api.py` (`/user/projects`) | CE | none | Verified | Run 9 "Permissions" PASS: lists hide other users' files. |
| Knowledge graph tool | `backend/onyx/tools/tool_implementations/knowledge_graph/`, `kg_admin_router` | CE | LLM | Not verified | Unconfirmed on the VM. |

## Search

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Hybrid retrieval | `HYBRID_ALPHA` (default 0.5) in `backend/onyx/configs/chat_configs.py:76`; OpenSearch index | CE | none | Verified | Run 9 "Search" PASS 8 of 8 (Q1 to Q5 return the expected top file). |
| Filters (source, document set, time, tags) | `BaseFilters` in `backend/onyx/context/search/models.py:104` | CE | none | Not verified | Fields exist. The VM checks used no filters. |
| Source results | `GET /manage/indexed-sources` in `backend/onyx/server/documents/connector.py` | CE | none | Verified | Only the `file` source is indexed on the VM. |
| Permission enforcement | `build_access_filters_for_user` in `backend/onyx/context/search/preprocessing/access_filters.py` | CE | none | Verified | Run 9: user B finds the restricted file; user A and the admin do not see the `KESTREL-7731` marker. 7 of 7 privacy checks PASS. |
| Search API | `POST /search` in `backend/onyx/server/features/search/api.py` | CE | none | Verified | Used by `run_checks.py` for the search step. |

## AI chat

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Hosted LLM provider | `llm_admin_router` in `backend/onyx/main.py:600`, `/admin/language-models` page | CE | provider key | Needs credentials | Fireworks AI key supplied; configuration in progress. Not verified. |
| Streaming answers | `POST /chat/send-chat-message` in `backend/onyx/server/query_and_chat/chat_backend.py:777`; SSE when `stream=true` | CE | LLM | Not verified | Chat did not pass yet. No model answered on the VM. |
| Retrieval in chat (Search tool) | `backend/onyx/tools/tool_implementations/search/search_tool.py` | CE | LLM | Not verified | `chat` and `chat-forced` steps pending. |
| Citations | `CitationInfo` in `backend/onyx/server/query_and_chat/streaming_models.py:141`; `CITEABLE_TOOLS_NAMES` in `backend/onyx/tools/built_in_tools.py:48` | CE | LLM | Not verified | Expected evidence in `product/test-corpus/README.md`. Not run. |
| Chat history | `GET /chat/get-user-chat-sessions`, `GET /chat/get-chat-session/{id}` in `chat_backend.py`; `maximum_chat_retention_days` in `backend/onyx/server/settings/models.py` | CE | none | Verified (access only) | Run 9: cross-user session access returns 403 "Access denied". Content of a model answer not verified. |
| Deep research mode | `deep_research: bool` in `backend/onyx/server/query_and_chat/models.py:122`; `SKIP_DEEP_RESEARCH_CLARIFICATION` in `chat_configs.py:109` | CE | LLM | Not verified | Needs a configured model. |

## Agents and personas

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Create and edit agents | `backend/onyx/server/features/persona/api.py` (`/persona`, `/admin/persona`, agents router) | CE | none | Not verified | Routes exist in the CE app. |
| Instructions (system prompt) | `POST /persona`, `PATCH /persona/{id}` in the same file | CE | none | Not verified | |
| Document sets on an agent | persona create and update models in `backend/onyx/server/features/persona/` | CE | none | Not verified | |
| Tools on an agent | `backend/onyx/tools/built_in_tools.py` (9 built-in tools) and custom tools | CE | varies per tool | Not verified | Built-in: Search, ImageGeneration, WebSearch, KnowledgeGraph, OpenURL, Python, FileReader, Memory, CodingAgent. |
| Sharing and ownership | `PATCH /persona/{id}/share`, `POST /persona/{id}/transfer-ownership`, `PATCH /admin/persona/{id}/public` | CE | none | Not verified | |
| Skills | `backend/onyx/server/features/skill/api.py` (`/skills`) | CE | none | Not verified | Unconfirmed on the VM. |

## Integrations

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Native actions (built-in tools) | `backend/onyx/tools/built_in_tools.py` | CE | LLM; some need provider keys | Needs credentials | Search tool works without extra keys. Others see Research, Execution and Media below. |
| MCP client (connect to external MCP servers) | `backend/onyx/server/features/mcp/api.py` (`/mcp`, `/admin/mcp`); `backend/onyx/tools/tool_implementations/mcp/`; page `/admin/mcp-actions` | CE | the external server and its auth | Not verified | Supports API key, per-user credentials and OAuth (`/mcp/oauth/connect`). |
| OpenAPI custom tools | `backend/onyx/server/features/tool/api.py` (`/admin/tool/custom`, `/tool/custom/validate`); page `/admin/openapi-actions` | CE | the target API | Not verified | |
| Tool auth (OAuth configs, per-user tokens) | `oauth_config_router`, `user_oauth_token_router` in `backend/onyx/main.py:591-593` | CE | provider OAuth app | Not verified | |
| Onyx MCP server (Onyx as a server) | `backend/onyx/mcp_server/`, `backend/onyx/mcp_server_main.py`; compose service `mcp_server` | CE | `MCP_SERVER_ENABLED=true`, a PAT or API key | Not verified (off) | The service is commented out in `deployment/docker_compose/docker-compose.yml:241` and `docker-compose.prod.yml:200`. `MCP_SERVER_ENABLED` defaults to false (`app_configs.py:1926`). It exposes one tool: document search (`backend/onyx/mcp_server/tools/search.py`), HTTP on port 8090, bearer auth. Not enabled on the VM. |
| Slack and Discord bots | `backend/onyx/onyxbot/`, `discord_bot_router` | CE | bot tokens | Needs credentials | Not verified. |

## Research

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Web search providers | `WebSearchProviderType` in `backend/shared_configs/enums.py:24`: `google_pse`, `serper`, `exa`, `searxng`, `brave`, `tavily`; admin page `/admin/web-search` | CE | API key for all except SearXNG (`provider_requires_api_key` in `backend/onyx/tools/tool_implementations/web_search/providers.py:62`) | Configured on `onyx-saas` (verify run pending) | Every company gets the platform provider "22nd X AI web search" (SearXNG on the VM, no key). A keyed provider replaces it through `secrets/saas.env`. Acceptance test: `product/test-corpus/tools_check.py` (`saas-tools-check`). See `MULTI-TENANT.md`, section 8. The single-tenant stack has no provider. |
| Web content fetch (Open URL) | `WebContentProviderType`: `onyx_web_crawler`, `firecrawl`, `exa`; `backend/onyx/tools/tool_implementations/open_url/` | CE | none for the Onyx crawler; keys for the others | Configured on `onyx-saas` (verify run pending) | Built-in crawler, no content provider active. `tools_check.py` fetches the cited links. See `MULTI-TENANT.md`, section 8. |
| Web search API | `POST /web-search/search` in `backend/onyx/server/features/web_search/api.py` | CE | web search provider | Needs credentials | |
| Deep research | see AI chat | CE | LLM; web search for web sources | Not verified | |

## Execution

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Code execution (Python tool) | `backend/onyx/tools/tool_implementations/python/`; `CODE_INTERPRETER_BASE_URL` in `app_configs.py:1661`; compose service `code-interpreter` (`onyxdotapp/code-interpreter:0.4.7`, `docker-compose.prod.yml:494`) | CE | the `code-interpreter` container and a Docker daemon for the executors | Configured on `onyx-saas` (verify run pending) | On `onyx-saas`, `product/deploy/mt/compose.tools.yml` runs the sandbox API behind `ci-gateway`, with a rootless executor daemon from `ci-host-setup` (main-socket fallback). Acceptance test: `product/test-corpus/tools_check.py` (`saas-tools-check`). See `MULTI-TENANT.md`, section 8. The single-tenant stack keeps it off (`compose.override.yml`). |
| Bash tool | `backend/onyx/tools/tool_implementations/bash/` | CE | same sandbox | Not verified (off) | Not in `BUILT_IN_TOOL_MAP`; used inside the coding agent. Unconfirmed. |
| Craft / Build (app and file generation with a coding agent) | `backend/onyx/server/features/build/`, `ENABLE_CRAFT` (default false) in `build/configs.py:72`; `deployment/docker_compose/docker-compose.craft.yml`; pages `/admin/craft/*` | CE | `ENABLE_CRAFT=true`, a sandbox backend (Docker socket or Kubernetes), an LLM | Not verified (off) | Not enabled on the VM. |
| File reader and memory tools | `backend/onyx/tools/tool_implementations/file_reader/`, `.../memory/` | CE | LLM | Not verified | |

## Media

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Voice STT and TTS | `backend/onyx/voice/providers/` (`openai`, `azure`, `elevenlabs`, `zoom`); `backend/onyx/server/manage/voice/`; page `/admin/voice` | CE | a voice provider key | Needs credentials | No key supplied. Default STT and TTS are set per provider (`is_default_stt`, `is_default_tts`). |
| Image generation | `ImageGenerationProviderName` in `backend/onyx/image_gen/factory.py:12` (`azure`, `openai`, `vertex_ai`); `POST /image-generation/generate`; page `/admin/image-generation` | CE | an image provider key | Needs credentials | No key supplied. Fireworks AI is not an image provider in this release. |

## Team

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Accounts (email and password) | `backend/onyx/auth/users.py`; `/auth/register`, `/auth/login` | CE | none | Verified | Admin, user A and user B log in during the checks. `AUTH_TYPE` single-provider mode is removed in this release (`users.py:195-206`). |
| Admin role and user management | `backend/onyx/server/manage/users.py` (`/manage/users`, `/manage/admin/*`) | CE | none | Verified (basic) | First registered user is admin. Deactivate and delete not verified. |
| Invitations | `bulk_invite_users` in `users.py:559`, `PUT /manage/admin/users`; email through `send_user_email_invite` only when `EMAIL_CONFIGURED` | CE | SMTP for the email; none for the list | Needs credentials | Invite list works without SMTP (unconfirmed on the VM). No invite email is sent. |
| Invite-only signup | `invite_only_enabled` (default false) in `backend/onyx/server/settings/models.py:50`; `verify_email_is_invited` in `users.py:311` | CE | none | Not verified | Open signup is the default. `VALID_EMAIL_DOMAINS` (`app_configs.py:181-196`) can limit domains. |
| Email verification and password reset | `REQUIRE_EMAIL_VERIFICATION` (`app_configs.py:392`), `password_router` | CE | SMTP (`SMTP_SERVER`, `SMTP_USER`, `SMTP_PASS`, `EMAIL_FROM` at `app_configs.py:395-412`) or SendGrid | Needs credentials | No SMTP on the VM. |
| Collaboration: shared chats, shared agents, projects | `ChatSessionSharedStatus` (`public`, `private`) in `backend/onyx/db/enums.py:248`; persona share routes; `/user/projects` | CE | none | Not verified | Project privacy verified; sharing not. |
| Single SSO provider (OIDC or SAML) | `backend/onyx/server/manage/sso/api.py`, `saml_multi.py`, `oidc_multi.py`, `sso_discovery.py`; page `/admin/sso-providers` | CE | an identity provider | Needs credentials | One enabled provider works at every tier (`sso/api.py:114-120`). A second enabled provider needs Business. |
| Google OAuth login | `OAUTH_ENABLED` block in `backend/onyx/main.py` | CE | Google OAuth client | Needs credentials | |

## APIs

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| Personal access tokens | `backend/onyx/server/pat/api.py` (`GET/POST /user/pats`, `GET /user/pats/scopes`) | CE | none | Not verified | Scopes such as `read:search`, `read:chat`, `write:chat` (`backend/onyx/mcp_server/README.md`). |
| Service-account API keys | `backend/onyx/server/api_key/api.py` (`/admin/api-key`); page `/admin/service-accounts` | CE route; Business tier when EE is on | none on CE | Not verified | Registered in the CE app (`main.py:623`). With EE on, `PATH_PREFIX_MIN_TIER` gates `/admin/api-key` at Business, and the web page carries `requiredTier: BUSINESS`. |
| Search endpoint | `POST /search` | CE | PAT or session | Verified | Used by the checks. |
| Chat endpoints | `/chat/create-chat-session`, `/chat/send-chat-message`, `/chat/get-user-chat-sessions`, `/chat/chat-session/{id}/resume-stream` | CE | LLM for answers | Partly verified | Session create and access checks PASS. Answers not verified. |
| Ingestion API | `backend/onyx/server/onyx_api/ingestion.py`: `GET/POST /onyx-api/ingestion`, `DELETE /onyx-api/ingestion/{document_id}`, `GET /onyx-api/connector-docs/{cc_pair_id}` | CE | PAT or API key | Not verified | |
| Management endpoints | `/manage/admin/connector*`, `/manage/admin/cc-pair/*`, `/manage/admin/document-set`, `/manage/users`, `/admin/persona`, `/admin/tool`, `/admin/mcp` | CE | admin session or key | Verified (connector and cc-pair) | `run_checks.py` uses connector upload, prune and deletion routes. |
| Web search and image endpoints | `POST /web-search/search`, `POST /image-generation/generate` | CE | provider keys | Needs credentials | |
| OpenAPI docs | `ENABLE_PUBLIC_DOCS` (`main.py:524`) | CE | none | Not verified | Opt-in. Unconfirmed on the VM. |

## Enterprise

| Feature | Where in v4.8.4 | Edition | Needs | Status on the VM | Evidence or note |
| --- | --- | --- | --- | --- | --- |
| User groups and RBAC (curators) | `backend/ee/onyx/server/user_group/api.py` (`/manage/admin/user-group`); page `/admin/groups` | EE | flag true + Business | License | Router only in `ee/onyx/main.py:133`. Tier map: Business. |
| Permission sync (external ACLs) | `backend/ee/onyx/external_permissions/`; Celery tasks `backend/ee/onyx/background/celery/tasks/doc_permission_syncing/`, `external_group_syncing/`; `AccessType.SYNC` check in `backend/onyx/db/connector_credential_pair.py:764` | EE | flag true + Business + a supported source | License | `require_business_tier_for_sync_access` runs through `fetch_ee_implementation_or_noop`. The sync tasks exist only in the EE package. |
| SAML / OIDC (single provider) | see Team | CE | identity provider | Needs credentials | Free in this release. |
| Multiple SSO providers | `sso/api.py:114` | EE tier check | flag true + Business | License | |
| SCIM 2.0 | `backend/ee/onyx/server/scim/api.py` (`/scim/v2/*`); page `/admin/scim` | EE | flag true + Enterprise | License | Tier map: `/scim` Enterprise. |
| Query history and admin chat sessions | `backend/ee/onyx/server/query_history/api.py` (`/admin/query-history`, `/admin/chat-sessions`) | EE | flag true + Business | License | |
| Analytics and usage reports | `backend/ee/onyx/server/analytics/api.py` (`/analytics/admin`), `usage_export_router` (`/admin/usage-report`) | EE | flag true + Business (Enterprise for non-admin `/analytics`) | License | |
| Hooks / outbound webhooks | `backend/ee/onyx/server/features/hooks/api.py` (`/admin/hooks`), executor `backend/ee/onyx/hooks/`; page `/admin/hooks` | EE | flag true + Enterprise | License | The CE package `backend/onyx/server/features/hooks/` holds only `__init__.py`. |
| White labeling (theme, logo, custom analytics script) | `enterprise_settings_router` in `ee/onyx/main.py:149-156` (`/admin/enterprise-settings`); page `/admin/theme` | EE | flag true + Business (Enterprise for `custom-analytics-script`) | License | TRD run 9: "Branding BLOCKED: no Business license". Public `GET /enterprise-settings` stays open. |
| Standard answers, token rate limits, log export, evals, LLM gateway | `/manage/admin/standard-answer`, `/admin/token-rate-limits`, `/admin/log-export`, `/evals`, gateway prefix | EE | flag true + Enterprise (gateway: `LLM_GATEWAY_MIN_TIER`) | License | |
| License upload and billing | `backend/ee/onyx/server/license/api.py`, `billing_router`; page `/admin/billing` | EE | flag true | Not available (flag false) | To use a license later, set the flag `true` and upload the license on `/admin/billing`. |

## MULTI_TENANT

- `MULTI_TENANT` is read in `backend/shared_configs/configs.py:194`, default false.
- `deployment/docker_compose/docker-compose.multitenant.yml` says: tenant provisioning is EE code, so
  multi-tenant mode pins `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true` and `AUTH_TYPE=cloud`, and
  it runs the `schema_private` Alembic migrations. The file is marked "Development only".
- The EE app adds tenant middleware and `tenants_router` only when `MULTI_TENANT` is true
  (`ee/onyx/main.py:97-101, 167-170`). Cloud gating uses a control plane, not a license.
- `DISABLE_VECTOR_DB` cannot be combined with `MULTI_TENANT` (`main.py:318-326`).
- Conclusion: MULTI_TENANT is not a supported mode for this CE deployment. It needs EE code, the
  cloud auth type, Onyx control-plane services and a separate migration path. Not verified.

## Summary of open items

1. Chat, citations and the model answers in the update and delete steps: wait for the Fireworks AI
   configuration, then run `chat`, `chat-forced` and `verify-with-chat`. Chat has not passed yet.
2. Email: supply SMTP (or SendGrid) to send invites, verification and reset mails.
3. Web search: configured on `onyx-saas` with SearXNG (`MULTI-TENANT.md`, section 8); the
   `saas-tools-check` run is pending. Image and voice: supply a provider key.
4. Code interpreter: configured on `onyx-saas` behind `ci-gateway` with a rootless executor
   daemon; the `saas-tools-check` run is pending. Craft: still off (`ENABLE_CRAFT`); it needs
   a Docker socket, decide this before enabling.
5. Enterprise rows: a Business or Enterprise license plus `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true`.
6. Connectors other than File, document sets, agents, MCP client and OpenAPI tools: present in the
   code, not yet verified on the VM.
