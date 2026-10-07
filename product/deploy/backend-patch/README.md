# 22nd X AI backend patch for Onyx v4.8.4

`../build-backend-image.sh` exports `backend/` from the upstream tag in
`../release.env`, copies the new files in `overlay/backend/`, applies the numbered
patches in order, then runs `docker build --target runtime`. The workflow
`.github/workflows/axi-build-backend.yml` builds, tests and pushes the image.

## What changes and why

Every company (tenant) on the multi-tenant stack gets four platform defaults when
Onyx creates its tenant:

1. The platform Fireworks model is the default chat model. The company does not need
   its own key.
2. The default assistant prompt is the built-in Onyx prompt plus the reviewed
   knowledge instructions.
3. The platform web search provider is the active search provider. The company does
   not need its own search key.
4. The Code Interpreter row exists (the tenant migration seeds it). Its state is
   reported, never changed.

The change uses Onyx's own tenant setup. `setup_tenant` in
`ee/onyx/server/tenants/provisioning.py` runs for each new company and for each
pre-provisioned pool tenant (`TARGET_AVAILABLE_TENANTS`). After `setup_onyx`, it calls
`apply_platform_defaults`. Auth, permissions, retrieval, storage and tenancy do not
change.

## New files (our code)

| Path | Why |
| --- | --- |
| `overlay/backend/onyx/axi/__init__.py` | Package marker |
| `overlay/backend/onyx/axi/tenant_defaults.py` | Env config, `KNOWLEDGE_INSTRUCTIONS`, `apply_platform_defaults(db_session)` |
| `overlay/backend/onyx/axi/backfill.py` | `python -m onyx.axi.backfill` for tenants that exist already, and `--rotate-platform-key` |

The upstream Dockerfile copies the whole `onyx/` package (`COPY ./onyx /app/onyx`), so
the new subpackage ships. The build stops when an overlay file has an upstream
counterpart: the overlay only adds files.

## Changed upstream files

| Patch | File | Why |
| --- | --- | --- |
| `0001-tenant-defaults-hook.patch` | `ee/onyx/server/tenants/provisioning.py` | One import and a call to `apply_platform_defaults` in `setup_tenant`, after `setup_onyx`, in the same tenant session. A failure is logged with `logger.exception` and does not stop the tenant creation; the backfill repairs the tenant later. The traceback holds only the `RuntimeError` of `apply_platform_defaults`: the first line of each step error, without SQL parameters or keys. |
| `0002-llm-provider-type-key-guard.patch` | `onyx/server/manage/llm/api.py` | Credential protection, see below. `_validate_llm_provider_change` also rejects a changed provider type when the request keeps the stored key (HTTP 400). The provider upsert and the provider test pass the types. |
| `0002-llm-provider-type-key-guard.patch` | `onyx/server/manage/image_generation/api.py` | The image generation config update passes the types to the same check. |
| `0003-voice-llm-key-reuse-guard.patch` | `onyx/server/manage/voice/api.py` | Credential protection. A voice provider may copy the key of an LLM provider (`llm_provider_id`) only for the same provider type and API base in multi-tenant mode (HTTP 400 otherwise). Upstream copied it to any voice provider type and target URI. |

The patches are unified diffs relative to `backend/`. Apply them from the export root
with `patch -p1 --forward --batch --fuzz=0 < <file>`.

## Environment

Set these on the api_server and on the background workers of the multi-tenant stack
(the workers run `setup_tenant` for the pool tenants).

| Variable | Default | Use |
| --- | --- | --- |
| `FIREWORKS_DEFAULT_API_KEY` | none | Platform key. Without it the model step is skipped (`skipped_no_key`). Secret: put it in the deployment `.env`, never in git. |
| `FIREWORKS_DEFAULT_MODEL` | `accounts/fireworks/models/deepseek-v4p1-flash` | Model name |
| `FIREWORKS_DEFAULT_DISPLAY_NAME` | `22nd X AI model` | Provider name in the admin page |
| `FIREWORKS_DEFAULT_PROVIDER` | `fireworks_ai` | LiteLLM provider type |
| `FIREWORKS_DEFAULT_API_BASE` | none | Optional endpoint override |
| `WEB_SEARCH_DEFAULT_PROVIDER` | none | Search provider type: `exa`, `brave`, `serper`, `tavily`, `google_pse` or `searxng`. Without it the web search step is skipped (`skipped_not_configured`). |
| `WEB_SEARCH_DEFAULT_API_KEY` | none | Search key. Required for every type except `searxng`. Secret, same rule as the platform key. The step stores it only when Enterprise Edition is active (`skipped_no_encryption` otherwise). |
| `WEB_SEARCH_DEFAULT_CONFIG` | none | JSON object of strings, the `config` of the provider row. Example: `{"searxng_base_url":"http://searxng:8080","num_results":"10"}`. Google PSE needs `search_engine_id`. |
| `WEB_SEARCH_DEFAULT_DISPLAY_NAME` | `22nd X AI web search` | Provider name in the admin page |

The settings are checked offline with `build_search_provider_from_config`, the same
check as the admin endpoint. A bad value fails the web search step for every tenant;
the error text never holds the key.

The LLM provider row has the same values as the single-tenant setup through
`PUT /api/admin/llm/provider?is_creation=true`: public, not auto mode, no groups, no
personas, `custom_config` `{}`, one visible model without image input.

The search provider row has the same values as `POST /api/admin/web-search/search-providers`
with `activate=true`. The step never writes `internet_content_provider`: without an
active content row, Onyx uses its built-in crawler to open the results. It never
changes `persona__tool` or `tool.enabled` either.

## Knowledge instructions

`KNOWLEDGE_INSTRUCTIONS` in `tenant_defaults.py` is a verbatim copy of
`ASSISTANT_ADDITION` in `product/deploy/default_assistant.py`. Change both or neither.
The tenant prompt is `DEFAULT_SYSTEM_PROMPT.rstrip() + "\n\n" + KNOWLEDGE_INSTRUCTIONS + "\n"`,
which is what `default_assistant.py set` writes through the API. The upstream
placeholders in `DEFAULT_SYSTEM_PROMPT` stay. The prompt is set with
`update_default_assistant_configuration`, the helper of `PATCH /api/admin/default-assistant`;
the tools of the assistant do not change.

## Repeatability rules

`apply_platform_defaults` never overwrites a company's choice. You can run it again.

| Step | Condition | Result |
| --- | --- | --- |
| Model | no `FIREWORKS_DEFAULT_API_KEY` | `skipped_no_key` |
| Model | the tenant has a default chat model (its own, or ours from an earlier run) | `kept` |
| Model | a provider with our name and type exists, no default | `linked`: its model becomes the default |
| Model | otherwise | `created`: provider created and made the default |
| Instructions | assistant prompt is NULL (the built-in default) | `set` |
| Instructions | any other value | `kept` |
| Web search | no `WEB_SEARCH_DEFAULT_PROVIDER` | `skipped_not_configured` (no marker) |
| Web search | `WEB_SEARCH_DEFAULT_API_KEY` is set and Enterprise Edition is not active | `skipped_no_encryption`: nothing is written, not even the marker. Only the EE build encrypts stored keys. The step runs again when EE is active. A `searxng` provider without a key does not need EE. |
| Web search | the marker row exists | `kept_marker`: nothing is read or written |
| Web search | no marker, any search provider row exists | `kept`: the marker is written with `{"decision": "kept"}` |
| Web search | no marker, no search provider row | `created`: provider row created and activated, marker `{"decision": "created"}` |
| Code Interpreter | no `code_interpreter_server` row | `seeded`: one row with `server_enabled = true` |
| Code Interpreter | row with `server_enabled = true` | `enabled` |
| Code Interpreter | row with `server_enabled = false` | `disabled_kept`: never flipped to true |

The marker is the row `axi_platform_web_search` in the tenant's `key_value_store`
table. It records that the web search decision was made once. After it exists, the
step does nothing: a company that deletes or replaces our provider keeps its state.

Caveat for the first backfill of a tenant that existed before this version: the step
cannot tell an owner's earlier deletion from "never configured". Both look like "no
search provider row", so the first run creates our provider. Run `--dry-run` first and
read the `web_search=created` lines; set a marker by hand for a tenant that must stay
without a provider.

The four steps are independent. Each runs in its own try: on an error the step rolls
back, the next step still runs, and at the end a `RuntimeError` names the failed steps
(no secrets). The model step raises when our provider exists without our model, or
when several providers have our name. An admin must then pick the default by hand.
Each call logs one INFO line with the tenant id and the four results. A failed step
logs one ERROR line with the step, the tenant id and the first line of the error. That
line has no traceback: a SQLAlchemy traceback holds the statement parameters. The keys
are never logged or printed.

## Backfill

Run it in the api_server container of the multi-tenant stack:

```bash
python -m onyx.axi.backfill --dry-run   # report only
python -m onyx.axi.backfill             # apply
```

It lists every tenant schema (`get_all_tenant_ids`), also the pool tenants that no
company owns yet, and prints one line per tenant:

```
tenant <id>: llm=<result> instructions=<result> web_search=<result> code_interpreter=<result> content=<builtin|provider type>
```

`content` is read only: the active content provider type, or `builtin` for the Onyx
crawler. A failed tenant prints `ERROR` and the summary counts it; the exit status is
then 1. `--tenant-id ID` runs one tenant.

## Platform key rotation

The platform key is in the platform model row of every tenant's `llm_provider`
table. `--rotate-platform-key` replaces it in every tenant schema:

```bash
# NEW key: FIREWORKS_DEFAULT_API_KEY of the container.
# OLD keys: SHA-256 fingerprints, one per line, '#' comments allowed.
python -m onyx.axi.backfill --rotate-platform-key --dry-run \
  --fingerprints-file /srv/onyx/secrets/platform-key-fingerprints
python -m onyx.axi.backfill --rotate-platform-key \
  --fingerprints-file /srv/onyx/secrets/platform-key-fingerprints
# An old key that is not in the file: one line on stdin, never on the command line.
printf '%s\n' "$OLD_KEY" | python -m onyx.axi.backfill --rotate-platform-key --old-key-stdin
```

Rules:

- The new key is `FIREWORKS_DEFAULT_API_KEY`; the command refuses an empty value.
- It refuses to run when Enterprise Edition is not active (`global_version.is_ee_version()`),
  because only the EE build encrypts the stored keys. It warns when `ENCRYPTION_KEY_SECRET`
  is empty.
- A row holds an old key when its decrypted key equals the stdin key, or when the
  SHA-256 of the key is in the fingerprints file. A key in use now
  (`FIREWORKS_DEFAULT_API_KEY`, `WEB_SEARCH_DEFAULT_API_KEY`) is never an old key.
- Only a platform model row gets the new key. A platform model row has `provider` equal
  to `FIREWORKS_DEFAULT_PROVIDER`, `api_base` equal to `FIREWORKS_DEFAULT_API_BASE` (two
  empty values are equal) and an empty `custom_config`. The name does not count.
- Every other row that holds an old key is `matched_foreign`. The command never writes
  it. The output gives its table, id, provider type and reason: `provider_type`,
  `api_base`, `custom_config`, `voice_provider` (every voice row: a voice provider sends
  the key to another vendor or URL), `content_provider` (every content row), `config`
  or `no_platform_search` (web search rows).
- A row that holds a retired key but points elsewhere keeps the old key and stops
  working when the key is revoked. That is intended: the platform key goes to the
  platform endpoint only.
- By default the command writes no web search row. A platform web search row has the
  `provider_type` and `config` of the `WEB_SEARCH_DEFAULT_*` settings. When it holds an
  old key, it counts as `search_skipped`. With `--include-web-search`, it gets
  `WEB_SEARCH_DEFAULT_API_KEY`: the search key, never the model key. The option refuses
  to run without a search key, with settings that are not valid, or when the search key
  equals the model key.
- The write goes through the ORM, as in `upsert_llm_provider`, so `EncryptedString`
  encrypts the new value. After the commit (one per tenant) each written row is read
  back and the decrypted value is compared.
- Output per tenant, then one summary line:

  ```
  tenant <id>: llm_rows=<n> voice_rows=<n> search_rows=<n> matched=<n> matched_foreign=<n> rotated=<n> already_new=<n> search_skipped=<n>
  tenant <id>: matched_foreign <table> id=<id> type=<provider type> reason=<reason>
  rotation: tenants X, matched Y, matched_foreign F, rotated Z, failed W
  ```

  `search_rows` counts the web search and content rows. `already_new` counts the rows
  that the command would write and that hold the new key already. The exit status is 1
  when a tenant failed and 2 for a bad option or environment. `--dry-run` writes
  nothing. No key and no matching value is printed. The SHA-256 of the new key (and of
  the new search key) is printed, so that the operator can store it.
- Change the key and the endpoint (`FIREWORKS_DEFAULT_PROVIDER`,
  `FIREWORKS_DEFAULT_API_BASE`) in two separate steps. After an endpoint change, the
  existing rows do not match the platform identity and count as `matched_foreign`.

Procedure (the VM script writes the fingerprint of each retired platform key to
`/srv/onyx/secrets/platform-key-fingerprints`):

1. Put the new key in the deployment `.env` and recreate the containers (api_server
   and background workers). New tenants now get the new key.
2. Run the rotation with `--dry-run`. Read `matched` and the `matched_foreign` lines.
   Then run it without `--dry-run`.
3. Run `--dry-run` again: `matched 0`. The `matched_foreign` count does not change:
   these rows keep the old key.
4. Revoke the old key at Fireworks.
5. After a restore of an older backup, run the rotation again: the restored rows hold
   the old key. Keep the old fingerprints in the file for this reason.

Exposure that remains (no patch):

- A company admin sees the first and last 4 characters of the platform keys in the
  masked admin views.
- A company admin can change the `provider_type` of the platform web search row and keep
  the stored key. The search key then goes to another search vendor. This is an upstream
  gap (see the review below); we do not patch it. The rotation counts such a row as
  `matched_foreign` and does not write it.

## Credential protection review (v4.8.4)

Line numbers are for the unpatched v4.8.4 `backend/`.

- Admin GET endpoints mask the key. `GET /api/admin/llm/provider` and
  `GET /api/admin/llm/provider/{id}` call `_mask_provider_credentials`
  (`onyx/server/manage/llm/api.py:545`, `:585`; function at `:250`), and so does
  `GET /api/admin/llm/vision-providers` (`:882`). `PUT` returns the masked view too
  (`:711`). The mask shows the first 4 and the last 4 characters (`_mask_string`,
  `:147`).
- The upsert keeps the stored key only when `api_key_changed` is false (`:656-661`).
  In multi-tenant mode it rejects a changed `api_base` or `custom_config` with that
  stored key (`_validate_llm_provider_change`, `:304-347`, called at `:627`). It did
  not check the provider type: patch 0002 adds that check.
- `POST /api/admin/llm/test` with an existing id and `api_key_changed` false runs the
  same check before it uses the stored key (`:463-476`), so a new `api_base` gets
  HTTP 400. Patch 0002 adds the provider type there too.
- Model list endpoints use the stored key only when the request `api_base` is the
  stored one (`_resolve_api_key`, `:154-188`).
- Image generation: the clone and test paths copy a stored key only after the same
  check, and they keep the source provider type
  (`onyx/server/manage/image_generation/api.py:89`, `:236`). The config update keeps
  the old key after the same check (`:447`) but takes the provider type from the
  request; patch 0002 adds the type check there.
- Voice providers: `POST /api/admin/voice/providers` with `llm_provider_id` copied the
  stored LLM key to any voice provider type and any target URI
  (`onyx/server/manage/voice/api.py:217-231`). A company admin could so send the platform
  key to another endpoint. Patch 0003 allows the copy only for the same provider type and
  API base.
- Web search providers: `GET /api/admin/web-search/search-providers` returns
  `masked_api_key` (first 4 and last 4 characters). `POST .../search-providers` with
  an `id` and `api_key_changed` false keeps the stored key
  (`onyx/db/web_search.py`, `_apply_search_provider_updates`) and takes the provider
  type from the request. A company admin can so switch the row from `exa` to another
  type and send the platform search key to that endpoint. This is an upstream gap;
  we do not patch it. The search key pays for searches only: set a spend limit on
  the search account, or use `searxng` (no key).
- Remaining exposure, accepted for the development stack: a company admin sees the first
  and last 4 characters of the platform keys, and can add other models of the same
  provider to the platform provider (the key then pays for them). Set a spend limit on
  the Fireworks account; give each company its own key when that is not acceptable.
- Non-admin endpoints (`GET /api/llm/provider`, `GET /api/llm/persona/{id}/providers`,
  `:907`, `:1052`) return `LLMProviderDescriptor` (`onyx/server/manage/llm/models.py:90-131`):
  id, name, provider type and models. No key, `api_base` or `custom_config`.

## Check a new upstream tag

```bash
product/deploy/backend-patch/check-upstream.sh v4.9.0
```

It exports the tag, dry-runs each patch with no fuzz, checks that the overlay adds
files only, checks that the upstream names the overlay uses still exist, then
compiles the patched files. Every item prints PASS or FAIL. Change
`ONYX_RELEASE_TAG` only after a full PASS, then run the build workflow.

## Rollback

The official backend digest stays in `product/deploy/release.env` as
`ONYX_BACKEND_IMAGE`; our image is `ONYX_BACKEND_IMAGE_CLOUD`. To roll back, point
the stack at the official digest again and restart. Tenants keep their provider,
marker and prompt rows; they are normal Onyx data that admins can change.

## Licence notes

- The overlay (`onyx/axi/`) is our code. It uses Onyx's MIT-licensed Community
  Edition helpers only.
- `ee/onyx/server/tenants/provisioning.py` stays under the Onyx Enterprise License
  (`backend/ee/LICENSE`, which covers the whole `ee/` directory); patch 0001 adds one
  import and one call. The terms for the use of `ee/` code are the same as for the
  official image. Patches 0002 and 0003 change MIT files only. No Enterprise code moves into
  Community paths.
- License enforcement is not changed. The image keeps all upstream `ee/` code
  as upstream ships it, apart from the hunk above.
