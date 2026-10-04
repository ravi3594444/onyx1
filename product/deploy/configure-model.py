#!/usr/bin/env python3
"""Configures the hosted LLM provider of an Onyx deployment, then tests it.

Uses only the Python standard library and the admin HTTP API (through nginx).
Each step prints one PASS or FAIL line and the script exits with 1 if any
check failed. The API key is never printed.

Usage:
  python3 configure-model.py --base-url http://localhost:3000
  python3 configure-model.py --check-key-only [--filter deepseek]

Env vars: ADMIN_EMAIL, ADMIN_PASSWORD (login), MODEL_PROVIDER (LiteLLM provider
name, default fireworks_ai), MODEL_NAME (model id, for Fireworks AI in the form
accounts/fireworks/models/<model>), MODEL_API_KEY, optional MODEL_API_BASE and
MODEL_DISPLAY_NAME (default "22nd X AI model").

--check-key-only lists the provider's models whose id contains --filter, with
the bearer key, and prints nothing else. It helps to pick the exact model id.
"""

import argparse
import json
import os
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "test-corpus"))

from run_checks import Checks, OnyxSession, ask, expect, login  # noqa: E402

DEFAULT_PROVIDER = "fireworks_ai"
DEFAULT_DISPLAY_NAME = "22nd X AI model"
# LiteLLM's own default for fireworks_ai; used only for --check-key-only.
FIREWORKS_API_BASE = "https://api.fireworks.ai/inference/v1"
SMOKE_QUESTION = "Reply with the single word OK"
STEP = "configure-model"


class ModelConfig:
    """The provider settings from the env vars."""

    def __init__(self) -> None:
        self.provider = (
            os.environ.get("MODEL_PROVIDER", DEFAULT_PROVIDER).strip().lower()
        )
        self.model = os.environ.get("MODEL_NAME", "").strip()
        self.api_key = os.environ.get("MODEL_API_KEY", "").strip()
        self.api_base = os.environ.get("MODEL_API_BASE", "").strip() or None
        self.display_name = (
            os.environ.get("MODEL_DISPLAY_NAME", "").strip() or DEFAULT_DISPLAY_NAME
        )

    def scrub(self, value: Any) -> Any:
        """Replaces the API key in any printed value."""
        if not self.api_key:
            return value
        if isinstance(value, str):
            return value.replace(self.api_key, "[REDACTED]")
        if isinstance(value, dict):
            return {key: self.scrub(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.scrub(item) for item in value]
        return value


def provider_summary(provider: Any) -> dict[str, Any]:
    """The fields of a provider view that are safe to print."""
    if not isinstance(provider, dict):
        return {"body": provider}
    return {
        "id": provider.get("id"),
        "name": provider.get("name"),
        "provider": provider.get("provider"),
        "api_base": provider.get("api_base"),
        "is_public": provider.get("is_public"),
        "models": [
            {"name": m.get("name"), "is_visible": m.get("is_visible")}
            for m in provider.get("model_configurations") or []
        ],
    }


def list_providers(admin: OnyxSession) -> dict[str, Any]:
    status, data = admin.request("GET", "/api/admin/llm/provider")
    expect(
        status == 200 and isinstance(data, dict),
        f"provider list returned {status}: {data}",
    )
    listing: dict[str, Any] = data
    return listing


def find_provider(providers: list[dict[str, Any]], name: str) -> dict[str, Any] | None:
    matches = [p for p in providers if p.get("name") == name]
    return matches[0] if matches else None


def upsert_body(
    config: ModelConfig, provider_id: int | None, keep_existing_models: bool
) -> dict[str, Any]:
    """The LLMProviderUpsertRequest body with one model configuration."""
    return {
        "id": provider_id,
        "name": config.display_name,
        "provider": config.provider,
        "api_key": config.api_key,
        "api_key_changed": True,
        "api_base": config.api_base,
        "api_version": None,
        # An empty dict marks a custom (LiteLLM) provider, as the web UI does.
        "custom_config": {},
        "custom_config_changed": True,
        "is_public": True,
        "is_auto_mode": False,
        "groups": [],
        "personas": [],
        "deployment_name": None,
        "keep_existing_models": keep_existing_models,
        "model_configurations": [
            {
                "name": config.model,
                "is_visible": True,
                "max_input_tokens": None,
                "supports_image_input": False,
            }
        ],
    }


def upsert_provider(
    admin: OnyxSession,
    config: ModelConfig,
    provider_id: int | None,
    keep_existing_models: bool,
) -> tuple[int, Any]:
    path = "/api/admin/llm/provider"
    if provider_id is None:
        path += "?is_creation=true"
    return admin.request(
        "PUT", path, upsert_body(config, provider_id, keep_existing_models)
    )


def step_configure(base_url: str, config: ModelConfig, checks: Checks) -> None:
    expect(bool(config.model), "set MODEL_NAME")
    expect(bool(config.api_key), "set MODEL_API_KEY")
    # 1. Login. OnyxSession checks /api/me and the email.
    admin = login(base_url, "ADMIN")
    status, me = admin.request("GET", "/api/me")
    # v4.8.4 has no user role: admin access shows in admin_capabilities.
    capabilities = me.get("admin_capabilities", []) if isinstance(me, dict) else []
    checks.record(
        f"login as {admin.email} and /api/me",
        status == 200 and "admin" in capabilities,
        {"status": status, "admin_capabilities": capabilities},
    )

    # 2. List the providers and find ours by display name.
    listing = list_providers(admin)
    providers = listing.get("providers") or []
    existing = find_provider(providers, config.display_name)
    checks.record(
        f"list providers, look for {config.display_name!r}",
        True,
        {
            "count": len(providers),
            "existing": provider_summary(existing) if existing else None,
            "default_text": listing.get("default_text"),
        },
    )

    # 3. Create or update the provider. An update keeps the stored models at
    # first, so the current default model is not removed before step 4.
    existing_id = int(existing["id"]) if existing else None
    status, saved = upsert_provider(
        admin, config, existing_id, keep_existing_models=existing is not None
    )
    saved_ok = status == 200 and isinstance(saved, dict) and "id" in saved
    checks.record(
        ("update" if existing else "create") + f" provider {config.display_name!r}",
        saved_ok,
        {
            "status": status,
            "provider": config.provider,
            "model": config.model,
            "api_base": config.api_base,
            "result": provider_summary(saved) if saved_ok else config.scrub(saved),
        },
    )
    expect(saved_ok, "provider save failed; the later steps need its id")
    provider_id = int(saved["id"])

    # 4. Make it the default chat provider and model.
    status, body = admin.request(
        "POST",
        "/api/admin/llm/default",
        {"provider_id": provider_id, "model_name": config.model},
    )
    checks.record(
        f"set provider {provider_id} model {config.model!r} as default",
        status == 200,
        {"status": status, "body": config.scrub(body)},
    )
    if existing and [
        m
        for m in existing.get("model_configurations") or []
        if m.get("name") != config.model
    ]:
        # Now that our model holds the chat default, drop the other models.
        status, pruned = upsert_provider(
            admin, config, provider_id, keep_existing_models=False
        )
        pruned_ok = status == 200 and isinstance(pruned, dict)
        checks.record(
            "remove the other models of the provider",
            pruned_ok,
            {
                "status": status,
                "result": provider_summary(pruned)
                if pruned_ok
                else config.scrub(pruned),
            },
        )
    listing = list_providers(admin)
    default_text = listing.get("default_text") or {}
    final = find_provider(listing.get("providers") or [], config.display_name)
    models = [m.get("name") for m in (final or {}).get("model_configurations") or []]
    checks.record(
        "provider list shows our model as the only model and as the default",
        models == [config.model]
        and default_text.get("provider_id") == provider_id
        and default_text.get("model_name") == config.model,
        {"models": models, "default_text": default_text},
    )

    # 5. Provider test. The server uses the stored key (api_key_changed false).
    status, body = admin.request(
        "POST",
        "/api/admin/llm/test",
        {
            "id": provider_id,
            "provider": config.provider,
            "model": config.model,
            "api_key": None,
            "api_base": config.api_base,
            "api_version": None,
            "custom_config": {},
            "deployment_name": None,
            "api_key_changed": False,
            "custom_config_changed": False,
        },
    )
    checks.record(
        "/api/admin/llm/test accepts the provider",
        status == 200,
        {"status": status, "body": config.scrub(body)},
    )
    status, body = admin.request("POST", "/api/admin/llm/test/default")
    checks.record(
        "/api/admin/llm/test/default answers with the default provider",
        status == 200,
        {"status": status, "body": config.scrub(body)},
    )

    # 6. Chat smoke check through a new chat session (run_checks.ask).
    result = ask(admin, SMOKE_QUESTION)
    checks.record(
        f"chat answers {SMOKE_QUESTION!r}",
        bool(result["answer"]) and not result["error"],
        config.scrub(
            {
                "answer": result["answer"][:200],
                "seconds": result["seconds"],
                "error": result["error"],
                "chat_session_id": result["chat_session_id"],
            }
        ),
    )


def list_remote_models(api_base: str, api_key: str) -> list[str]:
    """Returns the model ids of an OpenAI-compatible GET {api_base}/models."""
    url = api_base.rstrip("/") + "/models"
    expect(
        urllib.parse.urlparse(url).scheme in ("http", "https"),
        f"MODEL_API_BASE must use http or https: {api_base}",
    )
    # The scheme is checked above.
    request = urllib.request.Request(  # noqa: S310
        url, headers={"Authorization": f"Bearer {api_key}"}
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310
            data = json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{url} returned {error.code}") from None
    items = data.get("data") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise SystemExit(f"{url} returned no model list")
    return [
        str(item["id"]) for item in items if isinstance(item, dict) and "id" in item
    ]


def check_key_only(config: ModelConfig, model_filter: str) -> int:
    expect(bool(config.api_key), "set MODEL_API_KEY")
    api_base = config.api_base or (
        FIREWORKS_API_BASE if config.provider == DEFAULT_PROVIDER else None
    )
    expect(api_base is not None, f"set MODEL_API_BASE for provider {config.provider}")
    for model_id in list_remote_models(str(api_base), config.api_key):
        if model_filter.lower() in model_id.lower():
            print(model_id)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", default="http://localhost:3000")
    parser.add_argument(
        "--check-key-only",
        action="store_true",
        help="only list the provider's models that match --filter, then exit",
    )
    parser.add_argument("--filter", default="deepseek", help="model id substring")
    args = parser.parse_args()
    config = ModelConfig()
    if args.check_key_only:
        return check_key_only(config, args.filter)
    checks = Checks()
    stopped = f"{STEP} runs to the end"
    try:
        step_configure(args.base_url, config, checks)
    except SystemExit as error:
        checks.record(stopped, False, config.scrub(str(error.code)))
    except Exception as error:
        print(config.scrub(traceback.format_exc()), file=sys.stderr, flush=True)
        checks.record(stopped, False, config.scrub(repr(error)))
    return checks.exit_code(STEP)


if __name__ == "__main__":
    sys.exit(main())
