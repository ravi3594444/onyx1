"""Platform defaults for every 22nd X AI tenant.

Gives a tenant the platform Fireworks model as its default chat model and adds the
reviewed knowledge instructions to its default assistant. setup_tenant calls this
after setup_onyx (patch 0001); onyx.axi.backfill calls it for existing tenants.

The function is repeatable and never overwrites a choice that the company made.
"""

import os
from dataclasses import dataclass
from typing import Literal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from onyx.db.llm import (
    fetch_default_llm_model,
    fetch_existing_llm_provider_by_name_and_type,
    update_default_provider,
    upsert_llm_provider,
)
from onyx.db.models import LLMProvider as LLMProviderModel
from onyx.db.persona import (
    get_default_assistant,
    update_default_assistant_configuration,
)
from onyx.prompts.chat_prompts import DEFAULT_SYSTEM_PROMPT
from onyx.server.manage.llm.models import (
    LLMProviderUpsertRequest,
    ModelConfigurationUpsertRequest,
)
from onyx.server.manage.llm.provider_cache import invalidate_provider_listing_cache
from onyx.utils.logger import setup_logger
from shared_configs.contextvars import CURRENT_TENANT_ID_CONTEXTVAR

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


@dataclass(frozen=True)
class PlatformDefaultsResult:
    llm: LlmOutcome
    instructions: InstructionsOutcome


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


def apply_platform_defaults(
    db_session: Session, *, dry_run: bool = False
) -> PlatformDefaultsResult:
    """Apply the platform LLM and the knowledge instructions to the current tenant.

    With dry_run=True, report what would change and write nothing.
    """
    result = PlatformDefaultsResult(
        llm=_apply_llm(db_session, dry_run),
        instructions=_apply_instructions(db_session, dry_run),
    )
    logger.info(
        "Platform defaults for tenant %s%s: llm=%s instructions=%s",
        CURRENT_TENANT_ID_CONTEXTVAR.get(),
        " (dry run)" if dry_run else "",
        result.llm,
        result.instructions,
    )
    return result
