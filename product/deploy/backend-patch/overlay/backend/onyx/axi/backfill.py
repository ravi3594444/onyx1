"""Apply the platform defaults to every existing tenant, or rotate the platform key.

Usage (inside the api_server container):
    python -m onyx.axi.backfill [--dry-run] [--tenant-id TENANT_ID]
    python -m onyx.axi.backfill --rotate-platform-key [--dry-run] [--tenant-id TENANT_ID]
        [--old-key-stdin] [--fingerprints-file PATH] [--include-web-search]

Default mode: lists every tenant schema, also the pre-provisioned tenants that no
company owns yet, and calls apply_platform_defaults for each one. The rules are the
same as at tenant creation: a company's own choice is never changed.

Rotation mode: FIREWORKS_DEFAULT_API_KEY holds the NEW key. The OLD keys come from
stdin (--old-key-stdin, one line) and/or from a file of SHA-256 fingerprints
(--fingerprints-file, hex, one per line, '#' comments). Only a platform model row
gets the new key: provider type FIREWORKS_DEFAULT_PROVIDER, API base
FIREWORKS_DEFAULT_API_BASE and no custom config. Any other row that holds an old key
points to another vendor or endpoint: it is reported as matched_foreign and keeps
its key. That covers every voice and content provider row. With
--include-web-search, a platform web search row (same type and config as the
WEB_SEARCH_DEFAULT_* settings) gets WEB_SEARCH_DEFAULT_API_KEY, never the model key.

Exit status 1 when a tenant failed. Prints no secrets.
"""

import argparse
import hashlib
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from onyx.axi.tenant_defaults import (
    FIREWORKS_DEFAULT_API_BASE,
    FIREWORKS_DEFAULT_API_KEY,
    FIREWORKS_DEFAULT_PROVIDER,
    WEB_SEARCH_DEFAULT_API_KEY,
    WebSearchSettings,
    _web_search_settings,
    apply_platform_defaults,
    safe_error_text,
)
from onyx.configs.app_configs import ENCRYPTION_KEY_SECRET
from onyx.db.engine.sql_engine import SqlEngine, get_session_with_tenant
from onyx.db.engine.tenant_utils import get_all_tenant_ids
from onyx.db.models import (
    InternetContentProvider,
    InternetSearchProvider,
    LLMProvider,
    VoiceProvider,
)
from onyx.db.web_search import fetch_active_web_content_provider
from onyx.utils.variable_functionality import (
    global_version,
    set_is_ee_based_on_env_variable,
)
from shared_configs.contextvars import CURRENT_TENANT_ID_CONTEXTVAR

KeyRow = LLMProvider | VoiceProvider | InternetSearchProvider | InternetContentProvider

_FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
_UNSAFE_LABEL_RE = re.compile(r"[^A-Za-z0-9_.:-]")


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _label(value: str) -> str:
    """A provider type for the output: admins can type it, so keep one safe token."""
    return _UNSAFE_LABEL_RE.sub("?", value)[:40] or "?"


# Default mode


def _content_provider_label(db_session: Session) -> str:
    provider = fetch_active_web_content_provider(db_session)
    return provider.provider_type if provider is not None else "builtin"


def _run_tenant(tenant_id: str, dry_run: bool) -> str:
    token = CURRENT_TENANT_ID_CONTEXTVAR.set(tenant_id)
    try:
        with get_session_with_tenant(tenant_id=tenant_id) as db_session:
            result = apply_platform_defaults(db_session, dry_run=dry_run)
            content = _content_provider_label(db_session)
        return (
            f"llm={result.llm} instructions={result.instructions} "
            f"web_search={result.web_search} code_interpreter={result.code_interpreter} "
            f"content={_label(content)}"
        )
    finally:
        CURRENT_TENANT_ID_CONTEXTVAR.reset(token)


def _defaults_main(tenant_ids: Sequence[str], dry_run: bool) -> int:
    if dry_run:
        print("DRY RUN: no changes are written")

    failed = 0
    for tenant_id in tenant_ids:
        try:
            print(f"tenant {tenant_id}: {_run_tenant(tenant_id, dry_run)}")
        except Exception as e:
            failed += 1
            print(f"tenant {tenant_id}: ERROR {safe_error_text(e)}")

    print(
        f"summary: {len(tenant_ids)} tenants, {len(tenant_ids) - failed} ok, "
        f"{failed} failed{' (dry run)' if dry_run else ''}"
    )
    return 1 if failed else 0


# Rotation mode


@dataclass(frozen=True)
class OldKeys:
    # repr=False: a printed object must not show a key or its fingerprint.
    plain: str | None = field(repr=False)
    fingerprints: frozenset[str] = field(repr=False)

    def matches(self, value: str) -> bool:
        if self.plain is not None and value == self.plain:
            return True
        return _sha256(value) in self.fingerprints


@dataclass(frozen=True)
class RotationPlan:
    llm_key: str = field(repr=False)
    old_keys: OldKeys = field(repr=False)
    # Identity of the platform web search row; None when it is not configured.
    search: WebSearchSettings | None = None
    # The new key of the platform web search rows. Set only with --include-web-search.
    search_key: str | None = field(default=None, repr=False)

    def is_current_key(self, value: str) -> bool:
        # A key in use now is never an old key, even when a fingerprint lists it.
        return value in (self.llm_key, WEB_SEARCH_DEFAULT_API_KEY, self.search_key)


@dataclass(frozen=True)
class RowRule:
    # The new key for the row. None: the row is never written.
    target: str | None
    # Why the row is not a platform row. None for a platform row.
    foreign_reason: str | None


@dataclass
class RotationCounts:
    llm_rows: int = 0
    voice_rows: int = 0
    search_rows: int = 0
    matched: int = 0
    matched_foreign: int = 0
    rotated: int = 0
    already_new: int = 0
    search_skipped: int = 0
    foreign: list[str] = field(default_factory=list)

    def line(self) -> str:
        return (
            f"llm_rows={self.llm_rows} voice_rows={self.voice_rows} "
            f"search_rows={self.search_rows} matched={self.matched} "
            f"matched_foreign={self.matched_foreign} rotated={self.rotated} "
            f"already_new={self.already_new} search_skipped={self.search_skipped}"
        )


def _read_fingerprints(path: str) -> frozenset[str]:
    fingerprints: set[str] = set()
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, start=1):
            text = line.split("#", 1)[0].strip().lower()
            if not text:
                continue
            if not _FINGERPRINT_RE.match(text):
                raise ValueError(f"{path}:{number}: not a SHA-256 hex digest")
            fingerprints.add(text)
    return frozenset(fingerprints)


def _key_value(row: KeyRow) -> str | None:
    return row.api_key.get_value(apply_mask=False) if row.api_key else None


def _llm_foreign_reason(row: LLMProvider) -> str | None:
    """None for a platform model row; otherwise the field that points elsewhere."""
    if row.provider != FIREWORKS_DEFAULT_PROVIDER:
        return "provider_type"
    if (row.api_base or None) != (FIREWORKS_DEFAULT_API_BASE or None):
        return "api_base"
    if row.custom_config:
        return "custom_config"
    return None


def _search_foreign_reason(
    row: InternetSearchProvider, platform: WebSearchSettings | None
) -> str | None:
    """None for a platform web search row; otherwise why it is another one."""
    if platform is None:
        return "no_platform_search"
    if row.provider_type != platform.provider_type.value:
        return "provider_type"
    if (row.config or {}) != platform.config:
        return "config"
    return None


def _llm_rule(row: LLMProvider, plan: RotationPlan) -> RowRule:
    reason = _llm_foreign_reason(row)
    return RowRule(
        target=plan.llm_key if reason is None else None, foreign_reason=reason
    )


def _search_rule(row: InternetSearchProvider, plan: RotationPlan) -> RowRule:
    reason = _search_foreign_reason(row, plan.search)
    return RowRule(
        target=plan.search_key if reason is None else None, foreign_reason=reason
    )


def _visit(
    counts: RotationCounts,
    writes: list[tuple[KeyRow, str]],
    plan: RotationPlan,
    table: str,
    row: KeyRow,
    provider_type: str,
    rule: RowRule,
) -> None:
    value = _key_value(row)
    if value is None:
        return
    if rule.target is not None and value == rule.target:
        counts.already_new += 1
        return
    if plan.is_current_key(value) or not plan.old_keys.matches(value):
        return
    if rule.target is not None:
        counts.matched += 1
        writes.append((row, rule.target))
    elif rule.foreign_reason is None:
        # A platform web search row, and the run has no --include-web-search.
        counts.search_skipped += 1
    else:
        counts.matched_foreign += 1
        counts.foreign.append(
            f"{table} id={row.id} type={_label(provider_type)} "
            f"reason={rule.foreign_reason}"
        )


def _rotate_tenant(tenant_id: str, plan: RotationPlan, dry_run: bool) -> RotationCounts:
    counts = RotationCounts()
    token = CURRENT_TENANT_ID_CONTEXTVAR.set(tenant_id)
    try:
        with get_session_with_tenant(tenant_id=tenant_id) as db_session:
            llm_rows = list(
                db_session.scalars(select(LLMProvider).order_by(LLMProvider.id))
            )
            voice_rows = list(
                db_session.scalars(select(VoiceProvider).order_by(VoiceProvider.id))
            )
            search_rows = list(
                db_session.scalars(
                    select(InternetSearchProvider).order_by(InternetSearchProvider.id)
                )
            )
            content_rows = list(
                db_session.scalars(
                    select(InternetContentProvider).order_by(InternetContentProvider.id)
                )
            )
            counts.llm_rows = len(llm_rows)
            counts.voice_rows = len(voice_rows)
            counts.search_rows = len(search_rows) + len(content_rows)

            writes: list[tuple[KeyRow, str]] = []

            def visit(
                table: str, row: KeyRow, provider_type: str, rule: RowRule
            ) -> None:
                _visit(counts, writes, plan, table, row, provider_type, rule)

            for llm in llm_rows:
                visit("llm_provider", llm, llm.provider, _llm_rule(llm, plan))
            # A voice provider sends the key to another vendor or URL.
            voice_rule = RowRule(target=None, foreign_reason="voice_provider")
            for voice in voice_rows:
                visit("voice_provider", voice, voice.provider_type, voice_rule)
            for search in search_rows:
                visit(
                    "internet_search_provider",
                    search,
                    search.provider_type,
                    _search_rule(search, plan),
                )
            # The platform never creates a content provider row.
            content_rule = RowRule(target=None, foreign_reason="content_provider")
            for content in content_rows:
                visit(
                    "internet_content_provider",
                    content,
                    content.provider_type,
                    content_rule,
                )

            if dry_run or not writes:
                return counts
            for row, target in writes:
                if target == plan.llm_key and not isinstance(row, LLMProvider):
                    raise RuntimeError(
                        f"{type(row).__name__} id={row.id}: the model key goes "
                        "into LLM provider rows only"
                    )
                # EncryptedString re-encrypts on assignment, as upsert_llm_provider does.
                row.api_key = target  # type: ignore[assignment]
            db_session.commit()
            for row, target in writes:
                db_session.refresh(row, attribute_names=["api_key"])
                if _key_value(row) != target:
                    raise RuntimeError(
                        f"{type(row).__name__} id={row.id}: the key read back "
                        "is not the new key"
                    )
                counts.rotated += 1
            return counts
    finally:
        CURRENT_TENANT_ID_CONTEXTVAR.reset(token)


def _rotation_plan(
    parser: argparse.ArgumentParser, args: argparse.Namespace
) -> RotationPlan:
    """Check the environment and the options. parser.error exits with status 2."""
    new_key = FIREWORKS_DEFAULT_API_KEY
    if not new_key:
        parser.error("FIREWORKS_DEFAULT_API_KEY is empty; it must hold the new key")
    if not global_version.is_ee_version():
        parser.error(
            "Enterprise Edition is not active; the stored keys would not be encrypted"
        )
    if not ENCRYPTION_KEY_SECRET:
        print("WARNING: ENCRYPTION_KEY_SECRET is empty; keys are stored in clear")

    search: WebSearchSettings | None
    try:
        search = _web_search_settings()
    except ValueError as e:
        if args.include_web_search:
            parser.error(f"--include-web-search: {e}")
        print(
            "note: the platform web search settings are not valid; "
            "web search rows count as matched_foreign"
        )
        search = None
    search_key: str | None = None
    if args.include_web_search:
        if search is None or search.api_key is None:
            parser.error(
                "--include-web-search needs WEB_SEARCH_DEFAULT_PROVIDER and "
                "WEB_SEARCH_DEFAULT_API_KEY (the new search key)"
            )
        if search.api_key == new_key:
            parser.error(
                "WEB_SEARCH_DEFAULT_API_KEY equals FIREWORKS_DEFAULT_API_KEY; "
                "the model key never goes into a web search row"
            )
        search_key = search.api_key

    plain: str | None = None
    if args.old_key_stdin:
        plain = sys.stdin.readline().rstrip("\r\n")
        if not plain:
            parser.error("--old-key-stdin: no key on stdin")
        if plain in (new_key, WEB_SEARCH_DEFAULT_API_KEY):
            parser.error("the old key on stdin is a key in use now")
    fingerprints: frozenset[str] = frozenset()
    if args.fingerprints_file:
        try:
            fingerprints = _read_fingerprints(args.fingerprints_file)
        except (OSError, ValueError) as e:
            parser.error(f"--fingerprints-file: {e}")
    if plain is None and not fingerprints:
        parser.error("no old key: give --old-key-stdin and/or --fingerprints-file")
    return RotationPlan(
        llm_key=new_key,
        old_keys=OldKeys(plain=plain, fingerprints=fingerprints),
        search=search,
        search_key=search_key,
    )


def _rotate_main(
    parser: argparse.ArgumentParser,
    args: argparse.Namespace,
    tenant_ids: Sequence[str],
) -> int:
    plan = _rotation_plan(parser, args)
    if args.dry_run:
        print("DRY RUN: no changes are written")
    # A fingerprint is not secret: the operator stores it for the next rotation.
    print(f"new key sha256: {_sha256(plan.llm_key)}")
    if plan.search_key is not None:
        print(f"new search key sha256: {_sha256(plan.search_key)}")
    print(
        f"old keys: {1 if plan.old_keys.plain is not None else 0} from stdin, "
        f"{len(plan.old_keys.fingerprints)} fingerprints"
    )

    failed = 0
    matched = 0
    matched_foreign = 0
    rotated = 0
    search_skipped = 0
    for tenant_id in tenant_ids:
        try:
            counts = _rotate_tenant(tenant_id, plan, dry_run=args.dry_run)
        except Exception as e:
            failed += 1
            print(
                f"tenant {tenant_id}: ERROR {safe_error_text(e, plan.old_keys.plain)}"
            )
            continue
        matched += counts.matched
        matched_foreign += counts.matched_foreign
        rotated += counts.rotated
        search_skipped += counts.search_skipped
        print(f"tenant {tenant_id}: {counts.line()}")
        for foreign in counts.foreign:
            print(f"tenant {tenant_id}: matched_foreign {foreign}")

    if search_skipped:
        print(
            f"note: {search_skipped} platform web search rows hold an old key; "
            "they stay unchanged without --include-web-search"
        )
    if matched_foreign:
        print(
            f"note: {matched_foreign} rows hold an old key but point to another "
            "provider or endpoint; they keep it and stop working when it is revoked"
        )
    print(
        f"rotation: tenants {len(tenant_ids)}, matched {matched}, "
        f"matched_foreign {matched_foreign}, rotated {rotated}, "
        f"failed {failed}{' (dry run)' if args.dry_run else ''}"
    )
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Apply the 22nd X AI platform defaults to every tenant, "
            "or rotate the platform key."
        )
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change; write nothing.",
    )
    parser.add_argument("--tenant-id", help="Run for this tenant only.")
    rotate = parser.add_argument_group("key rotation")
    rotate.add_argument(
        "--rotate-platform-key",
        action="store_true",
        help=(
            "Replace an old platform key with FIREWORKS_DEFAULT_API_KEY in the "
            "platform model rows. Other rows with an old key are reported only."
        ),
    )
    rotate.add_argument(
        "--old-key-stdin",
        action="store_true",
        help="Read one old key from the first line of stdin.",
    )
    rotate.add_argument(
        "--fingerprints-file",
        metavar="PATH",
        help="File of SHA-256 hex digests of old keys, one per line.",
    )
    rotate.add_argument(
        "--include-web-search",
        action="store_true",
        help=(
            "Also give WEB_SEARCH_DEFAULT_API_KEY to the platform web search rows "
            "that hold an old key."
        ),
    )
    args = parser.parse_args()
    if not args.rotate_platform_key and (
        args.old_key_stdin or args.fingerprints_file or args.include_web_search
    ):
        parser.error("the key rotation options need --rotate-platform-key")

    set_is_ee_based_on_env_variable()
    SqlEngine.init_engine(pool_size=5, max_overflow=2)
    tenant_ids = [args.tenant_id] if args.tenant_id else get_all_tenant_ids()

    if args.rotate_platform_key:
        return _rotate_main(parser, args, tenant_ids)
    return _defaults_main(tenant_ids, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
