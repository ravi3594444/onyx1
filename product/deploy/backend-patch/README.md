# 22nd X AI backend patch for Onyx v4.8.4

`../build-backend-image.sh` exports `backend/` from the upstream tag in
`../release.env`, copies the new files in `overlay/backend/`, applies the numbered
patches in order, then runs `docker build --target runtime`. The workflow
`.github/workflows/axi-build-backend.yml` builds, tests and pushes the image.

## What changes and why

Every company (tenant) on the multi-tenant stack gets two platform defaults when
Onyx creates its tenant:

1. The platform Fireworks model is the default chat model. The company does not need
   its own key.
2. The default assistant prompt is the built-in Onyx prompt plus the reviewed
   knowledge instructions.

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
| `overlay/backend/onyx/axi/backfill.py` | `python -m onyx.axi.backfill [--dry-run] [--tenant-id ID]` for tenants that exist already |

The upstream Dockerfile copies the whole `onyx/` package (`COPY ./onyx /app/onyx`), so
the new subpackage ships. The build stops when an overlay file has an upstream
counterpart: the overlay only adds files.

## Changed upstream files

| Patch | File | Why |
| --- | --- | --- |
| `0001-tenant-defaults-hook.patch` | `ee/onyx/server/tenants/provisioning.py` | One import and a call to `apply_platform_defaults` in `setup_tenant`, after `setup_onyx`, in the same tenant session. A failure is logged with `logger.exception` and does not stop the tenant creation; the backfill repairs the tenant later. |
| `0002-llm-provider-type-key-guard.patch` | `onyx/server/manage/llm/api.py` | Credential protection, see below. `_validate_llm_provider_change` also rejects a changed provider type when the request keeps the stored key (HTTP 400). The provider upsert and the provider test pass the types. |
| `0002-llm-provider-type-key-guard.patch` | `onyx/server/manage/image_generation/api.py` | The image generation config update passes the types to the same check. |

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

The provider row has the same values as the single-tenant setup through
`PUT /api/admin/llm/provider?is_creation=true`: public, not auto mode, no groups, no
personas, `custom_config` `{}`, one visible model without image input.

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

The model step raises (and writes nothing) when our provider exists without our
model, or when several providers have our name. An admin must then pick the
default by hand. Each call logs one INFO line with the tenant id and both results. The
key is never logged or printed.

## Backfill

Run it in the api_server container of the multi-tenant stack:

```bash
python -m onyx.axi.backfill --dry-run   # report only
python -m onyx.axi.backfill             # apply
```

It lists every tenant schema (`get_all_tenant_ids`), also the pool tenants that no
company owns yet, and prints `tenant <id>: llm=<result> instructions=<result>` and a
summary. The exit status is 1 when a tenant failed.

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
`ONYX_BACKEND_IMAGE`. To roll back, point the stack at that digest again and restart.
Tenants keep their provider and prompt rows; they are normal Onyx data that admins
can change.

## Licence notes

- The overlay (`onyx/axi/`) is our code. It uses Onyx's MIT-licensed Community
  Edition helpers only.
- `ee/onyx/server/tenants/provisioning.py` stays under the Onyx Enterprise License
  (`backend/ee/LICENSE`, which covers the whole `ee/` directory); patch 0001 adds one
  import and one call. The terms for the use of `ee/` code are the same as for the
  official image. Patch 0002 changes MIT files only. No Enterprise code moves into
  Community paths.
- License enforcement is not changed. The image keeps all upstream `ee/` code
  as upstream ships it, apart from the hunk above.
