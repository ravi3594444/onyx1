"""Platform defaults for every 22nd X AI tenant.

Gives a tenant the platform Fireworks model as its default chat model, adds the
reviewed knowledge instructions to its default assistant, gives it the platform web
search provider and reports its Code Interpreter state. setup_tenant calls this
after setup_onyx (patch 0001); onyx.axi.backfill calls it for existing tenants.

The function is repeatable and never overwrites a choice that the company made.
"""

import json
import os
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal, TypeVar

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from onyx.db.llm import (
    fetch_default_llm_model,
    fetch_existing_llm_provider_by_name_and_type,
    update_default_provider,
    upsert_llm_provider,
)
from onyx.db.models import CodeInterpreterServer, KVStore
from onyx.db.models import LLMProvider as LLMProviderModel
from onyx.db.persona import (
    get_default_assistant,
    update_default_assistant_configuration,
)
from onyx.db.web_search import fetch_web_search_providers, upsert_web_search_provider
from onyx.prompts.chat_prompts import DEFAULT_SYSTEM_PROMPT
from onyx.server.manage.llm.models import (
    LLMProviderUpsertRequest,
    ModelConfigurationUpsertRequest,
)
from onyx.server.manage.llm.provider_cache import invalidate_provider_listing_cache
from onyx.tools.tool_implementations.web_search.providers import (
    build_search_provider_from_config,
)
from onyx.utils.logger import setup_logger
from shared_configs.contextvars import CURRENT_TENANT_ID_CONTEXTVAR
from shared_configs.enums import WebSearchProviderType

logger = setup_logger()

# The key is a secret: never log it.
FIREWORKS_DEFAULT_API_KEY: str | None = (
    os.environ.get("FIREWORKS_DEFAULT_API_KEY") or None
)
FIREWORKS_DEFAULT_MODEL: str = (
    os.environ.get("FIREWORKS_DEFAULT_MODEL")
    or "accounts/fireworks/models/deepseek-v4p1-flash"
)
FIREWORKS_DEFAULT_DISPLAY_NAME: str = (
    os.environ.get("FIREWORKS_DEFAULT_DISPLAY_NAME") or "22nd X AI model"
)
FIREWORKS_DEFAULT_PROVIDER: str = (
    os.environ.get("FIREWORKS_DEFAULT_PROVIDER") or "fireworks_ai"
)
FIREWORKS_DEFAULT_API_BASE: str | None = (
    os.environ.get("FIREWORKS_DEFAULT_API_BASE") or None
)

# Platform web search. The provider type is a WebSearchProviderType value
# (exa, brave, serper, tavily, google_pse, searxng). Unset: the step is skipped.
WEB_SEARCH_DEFAULT_PROVIDER: str | None = (
    os.environ.get("WEB_SEARCH_DEFAULT_PROVIDER") or None
)
# The key is a secret: never log it.
WEB_SEARCH_DEFAULT_API_KEY: str | None = (
    os.environ.get("WEB_SEARCH_DEFAULT_API_KEY") or None
)
# JSON object of strings, for example {"searxng_base_url": "http://searxng:8080"}.
WEB_SEARCH_DEFAULT_CONFIG: str | None = (
    os.environ.get("WEB_SEARCH_DEFAULT_CONFIG") or None
)
WEB_SEARCH_DEFAULT_DISPLAY_NAME: str = (
    os.environ.get("WEB_SEARCH_DEFAULT_DISPLAY_NAME") or "22nd X AI web search"
)
# key_value_store row that records the web search decision for a tenant.
WEB_SEARCH_MARKER_KEY = "axi_platform_web_search"

# Reviewed text. Twin: ASSISTANT_ADDITION in product/deploy/default_assistant.py.
# Keep the two identical.
KNOWLEDGE_INSTRUCTIONS = """
# Knowledge rules
The search tool returns only documents that the current user is allowed to read. Access control \
runs before you see a document. Answer from a returned document even when its text says that it \
is restricted, classified or meant for one group: the user who asks already has access to it. \
Do not refuse on that basis and do not tell the user to ask another team for it.

When the returned documents do not contain the information that the question needs, answer in one \
or two sentences that the documents do not cover it. Such an answer has no citation at all: no \
[1]-style markers, and no list or description of the documents that the search returned. Cite a \
document only for a statement that this document supports.
""".strip()

LlmOutcome = Literal["created", "linked", "kept", "skipped_no_key"]
InstructionsOutcome = Literal["set", "kept"]
WebSearchOutcome = Literal["created", "kept", "kept_marker", "skipped_not_configured"]
CodeInterpreterOutcome = Literal["enabled", "disabled_kept", "seeded"]

T = TypeVar("T")


@dataclass(frozen=True)
class PlatformDefaultsResult:
    llm: LlmOutcome
    instructions: InstructionsOutcome
    web_search: WebSearchOutcome
    code_interpreter: CodeInterpreterOutcome


@dataclass(frozen=True)
class WebSearchSettings:
    provider_type: WebSearchProviderType
    api_key: str | None
    config: dict[str, str]


def safe_error_text(e: BaseException, *extra_secrets: str | None) -> str:
    """One line for an error, with the platform keys masked."""
    # First line only: SQLAlchemy appends the SQL and its bound values after it.
    message = str(e).split("\n", 1)[0]
    for secret in (
        FIREWORKS_DEFAULT_API_KEY,
        WEB_SEARCH_DEFAULT_API_KEY,
        *extra_secrets,
    ):
        if secret:
            message = message.replace(secret, "****")
    return f"{type(e).__name__}: {message}"


def build_workspace_prompt() -> str:
    """The prompt that default_assistant.py `set` writes through the API."""
    return DEFAULT_SYSTEM_PROMPT.rstrip() + "\n\n" + KNOWLEDGE_INSTRUCTIONS + "\n"


def _provider_request() -> LLMProviderUpsertRequest:
    # Same values as PUT /api/admin/llm/provider?is_creation=true in single-tenant mode.
    return LLMProviderUpsertRequest(
        name=FIREWORKS_DEFAULT_DISPLAY_NAME,
        provider=FIREWORKS_DEFAULT_PROVIDER,
        api_key=FIREWORKS_DEFAULT_API_KEY,
        api_key_changed=True,
        api_base=FIREWORKS_DEFAULT_API_BASE,
        custom_config={},
        custom_config_changed=True,
        is_public=True,
        is_auto_mode=False,
        groups=[],
        personas=[],
        model_configurations=[
            ModelConfigurationUpsertRequest(
                name=FIREWORKS_DEFAULT_MODEL,
                is_visible=True,
                max_input_tokens=None,
                supports_image_input=False,
            )
        ],
    )


def _apply_llm(db_session: Session, dry_run: bool) -> LlmOutcome:
    if not FIREWORKS_DEFAULT_API_KEY:
        return "skipped_no_key"
    # A default chat model means the company chose one, or an earlier run set ours.
    if fetch_default_llm_model(db_session) is not None:
        return "kept"

    existing = fetch_existing_llm_provider_by_name_and_type(
        name=FIREWORKS_DEFAULT_DISPLAY_NAME,
        provider_type=FIREWORKS_DEFAULT_PROVIDER,
        db_session=db_session,
    )
    if existing is not None:
        if FIREWORKS_DEFAULT_MODEL not in {
            mc.name for mc in existing.model_configurations
        }:
            # The company edited the provider; do not change it.
            raise ValueError(
                f"Provider '{FIREWORKS_DEFAULT_DISPLAY_NAME}' (id={existing.id}) "
                f"has no model '{FIREWORKS_DEFAULT_MODEL}'; set a default model by hand."
            )
        if not dry_run:
            update_default_provider(existing.id, FIREWORKS_DEFAULT_MODEL, db_session)
            invalidate_provider_listing_cache()
        return "linked"

    # The helper returns None for several matches too. Do not add one more.
    same_name_count = db_session.scalar(
        select(func.count())
        .select_from(LLMProviderModel)
        .where(
            LLMProviderModel.name == FIREWORKS_DEFAULT_DISPLAY_NAME,
            LLMProviderModel.provider == FIREWORKS_DEFAULT_PROVIDER,
        )
    )
    if same_name_count:
        raise ValueError(
            f"{same_name_count} providers are named '{FIREWORKS_DEFAULT_DISPLAY_NAME}'; "
            "set a default model by hand."
        )

    if not dry_run:
        try:
            provider = upsert_llm_provider(_provider_request(), db_session)
            update_default_provider(provider.id, FIREWORKS_DEFAULT_MODEL, db_session)
        finally:
            invalidate_provider_listing_cache()
    return "created"


def _apply_instructions(db_session: Session, dry_run: bool) -> InstructionsOutcome:
    persona = get_default_assistant(db_session)
    if persona is None:
        raise ValueError("Default assistant not found")
    # Any stored value is the company's choice (or an earlier run).
    if persona.system_prompt is not None:
        return "kept"
    if not dry_run:
        update_default_assistant_configuration(
            db_session,
            system_prompt=build_workspace_prompt(),
            update_system_prompt=True,
        )
    return "set"


def _parse_web_search_config(raw: str | None) -> dict[str, str]:
    if raw is None:
        return {}
    # The error texts never echo the value: it may hold a private URL.
    try:
        parsed = json.loads(raw)
    except ValueError:
        raise ValueError("WEB_SEARCH_DEFAULT_CONFIG is not valid JSON") from None
    if not isinstance(parsed, dict) or not all(
        isinstance(k, str) and isinstance(v, str) for k, v in parsed.items()
    ):
        raise ValueError("WEB_SEARCH_DEFAULT_CONFIG must be a JSON object of strings")
    return {str(k): str(v) for k, v in parsed.items()}


def _web_search_settings() -> WebSearchSettings | None:
    """The platform web search provider from the environment, checked offline.

    None when WEB_SEARCH_DEFAULT_PROVIDER is unset. Raises ValueError for a bad
    value; the message never holds the key.
    """
    if WEB_SEARCH_DEFAULT_PROVIDER is None:
        return None
    try:
        provider_type = WebSearchProviderType(WEB_SEARCH_DEFAULT_PROVIDER)
    except ValueError:
        allowed = ", ".join(t.value for t in WebSearchProviderType)
        raise ValueError(
            f"WEB_SEARCH_DEFAULT_PROVIDER '{WEB_SEARCH_DEFAULT_PROVIDER}' "
            f"is not one of: {allowed}"
        ) from None
    config = _parse_web_search_config(WEB_SEARCH_DEFAULT_CONFIG)
    # Same checks as the admin endpoint, without a network call.
    try:
        build_search_provider_from_config(
            provider_type, WEB_SEARCH_DEFAULT_API_KEY, config
        )
    except Exception as e:
        raise ValueError(
            f"Platform web search settings are not valid: {safe_error_text(e)}"
        ) from None
    return WebSearchSettings(
        provider_type=provider_type,
        api_key=WEB_SEARCH_DEFAULT_API_KEY,
        config=config,
    )


def _write_web_search_marker(db_session: Session, decision: str) -> None:
    # Through the session, so the row commits with the provider. get_kv_store()
    # would commit in a session of its own.
    db_session.add(KVStore(key=WEB_SEARCH_MARKER_KEY, value={"decision": decision}))


def _apply_web_search(db_session: Session, dry_run: bool) -> WebSearchOutcome:
    """Give the tenant the platform web search provider once.

    The marker row remembers the decision. Without the marker, any search provider
    row means that the company set up its own: it is kept and the marker is written.
    The content provider (built-in crawler by default) and the assistant tools do
    not change.
    """
    settings = _web_search_settings()
    if settings is None:
        return "skipped_not_configured"
    if db_session.get(KVStore, WEB_SEARCH_MARKER_KEY) is not None:
        return "kept_marker"
    if fetch_web_search_providers(db_session):
        if not dry_run:
            _write_web_search_marker(db_session, "kept")
            db_session.commit()
        return "kept"
    if not dry_run:
        upsert_web_search_provider(
            provider_id=None,
            name=WEB_SEARCH_DEFAULT_DISPLAY_NAME,
            provider_type=settings.provider_type,
            api_key=settings.api_key,
            api_key_changed=settings.api_key is not None,
            config=settings.config,
            activate=True,
            db_session=db_session,
        )
        _write_web_search_marker(db_session, "created")
        db_session.commit()
    return "created"


def _apply_code_interpreter(
    db_session: Session, dry_run: bool
) -> CodeInterpreterOutcome:
    """Report the Code Interpreter state; seed the row when the migration left none.

    A disabled server is the company's choice and stays disabled.
    """
    server = db_session.scalars(
        select(CodeInterpreterServer).order_by(CodeInterpreterServer.id.asc())
    ).first()
    if server is None:
        if not dry_run:
            db_session.add(CodeInterpreterServer(server_enabled=True))
            db_session.commit()
        return "seeded"
    return "enabled" if server.server_enabled else "disabled_kept"


def _run_step(
    step: str,
    apply: Callable[[], T],
    db_session: Session,
    failures: list[str],
) -> T | None:
    """Run one step. On error, roll back, record the step and return None."""
    try:
        return apply()
    except Exception as e:
        db_session.rollback()
        failures.append(f"{step} ({safe_error_text(e)})")
        logger.exception(
            "Platform defaults step %s failed for tenant %s",
            step,
            CURRENT_TENANT_ID_CONTEXTVAR.get(),
        )
        return None


def apply_platform_defaults(
    db_session: Session, *, dry_run: bool = False
) -> PlatformDefaultsResult:
    """Apply the platform defaults to the current tenant.

    The steps are independent: a failed step does not stop the next one. After
    all steps, a RuntimeError names the failed steps (without secrets).
    With dry_run=True, report what would change and write nothing.
    """
    tenant_id = CURRENT_TENANT_ID_CONTEXTVAR.get()
    failures: list[str] = []
    llm = _run_step(
        "llm", lambda: _apply_llm(db_session, dry_run), db_session, failures
    )
    instructions = _run_step(
        "instructions",
        lambda: _apply_instructions(db_session, dry_run),
        db_session,
        failures,
    )
    web_search = _run_step(
        "web_search",
        lambda: _apply_web_search(db_session, dry_run),
        db_session,
        failures,
    )
    code_interpreter = _run_step(
        "code_interpreter",
        lambda: _apply_code_interpreter(db_session, dry_run),
        db_session,
        failures,
    )
    if (
        failures
        or llm is None
        or instructions is None
        or web_search is None
        or code_interpreter is None
    ):
        raise RuntimeError(
            f"Platform defaults failed for tenant {tenant_id}: {'; '.join(failures)}"
        )
    result = PlatformDefaultsResult(
        llm=llm,
        instructions=instructions,
        web_search=web_search,
        code_interpreter=code_interpreter,
    )
    logger.info(
        "Platform defaults for tenant %s%s: llm=%s instructions=%s web_search=%s "
        "code_interpreter=%s",
        tenant_id,
        " (dry run)" if dry_run else "",
        result.llm,
        result.instructions,
        result.web_search,
        result.code_interpreter,
    )
    return result
