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
(--fingerprints-file, hex, one per line, '#' comments). Every LLM provider and voice
provider row whose key is an old key gets the new key. Web search and content
provider rows that hold an old key are reported only, unless --include-web-search.

Exit status 1 when a tenant failed. Prints no secrets.
"""

import argparse
import hashlib
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.orm import Session

from onyx.axi.tenant_defaults import (
    FIREWORKS_DEFAULT_API_KEY,
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


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


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
            f"content={content}"
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
    plain: str | None
    fingerprints: frozenset[str]

    def matches(self, value: str) -> bool:
        if self.plain is not None and value == self.plain:
            return True
        return _sha256(value) in self.fingerprints


@dataclass
class RotationCounts:
    llm_rows: int = 0
    voice_rows: int = 0
    search_rows: int = 0
    matched: int = 0
    rotated: int = 0
    already_new: int = 0
    search_matched: int = 0

    def line(self) -> str:
        return (
            f"llm_rows={self.llm_rows} voice_rows={self.voice_rows} "
            f"search_rows={self.search_rows} matched={self.matched} "
            f"rotated={self.rotated} already_new={self.already_new} "
            f"search_matched={self.search_matched}"
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


def _rotate_tenant(
    tenant_id: str,
    new_key: str,
    old_keys: OldKeys,
    include_web_search: bool,
    dry_run: bool,
) -> RotationCounts:
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
            search_rows: list[KeyRow] = [
                *db_session.scalars(
                    select(InternetSearchProvider).order_by(InternetSearchProvider.id)
                ),
                *db_session.scalars(
                    select(InternetContentProvider).order_by(InternetContentProvider.id)
                ),
            ]
            counts.llm_rows = len(llm_rows)
            counts.voice_rows = len(voice_rows)
            counts.search_rows = len(search_rows)

            to_rotate: list[KeyRow] = []
            platform_rows: list[KeyRow] = [*llm_rows, *voice_rows]
            for row in platform_rows:
                value = _key_value(row)
                if value is None:
                    continue
                if value == new_key:
                    counts.already_new += 1
                elif old_keys.matches(value):
                    counts.matched += 1
                    to_rotate.append(row)
            # The search key is another secret: report only, unless asked.
            for row in search_rows:
                value = _key_value(row)
                if value is None or value == new_key or not old_keys.matches(value):
                    continue
                counts.search_matched += 1
                if include_web_search:
                    counts.matched += 1
                    to_rotate.append(row)

            if dry_run or not to_rotate:
                return counts
            for row in to_rotate:
                # EncryptedString re-encrypts on assignment, as upsert_llm_provider does.
                row.api_key = new_key  # type: ignore[assignment]
            db_session.commit()
            for row in to_rotate:
                db_session.refresh(row, attribute_names=["api_key"])
                if _key_value(row) != new_key:
                    raise RuntimeError(
                        f"{type(row).__name__} id={row.id}: the key read back "
                        "is not the new key"
                    )
                counts.rotated += 1
            return counts
    finally:
        CURRENT_TENANT_ID_CONTEXTVAR.reset(token)


def _rotate_main(
    parser: argparse.ArgumentParser,
    args: argparse.Namespace,
    tenant_ids: Sequence[str],
) -> int:
    new_key = FIREWORKS_DEFAULT_API_KEY
    if not new_key:
        parser.error("FIREWORKS_DEFAULT_API_KEY is empty; it must hold the new key")
    if not global_version.is_ee_version():
        parser.error(
            "Enterprise Edition is not active; the stored keys would not be encrypted"
        )
    if not ENCRYPTION_KEY_SECRET:
        print("WARNING: ENCRYPTION_KEY_SECRET is empty; keys are stored in clear")

    plain: str | None = None
    if args.old_key_stdin:
        plain = sys.stdin.readline().rstrip("\r\n")
        if not plain:
            parser.error("--old-key-stdin: no key on stdin")
        if plain == new_key:
            parser.error("the old key on stdin equals FIREWORKS_DEFAULT_API_KEY")
    fingerprints: frozenset[str] = frozenset()
    if args.fingerprints_file:
        fingerprints = _read_fingerprints(args.fingerprints_file)
    if plain is None and not fingerprints:
        parser.error("no old key: give --old-key-stdin and/or --fingerprints-file")
    old_keys = OldKeys(plain=plain, fingerprints=fingerprints)

    if args.dry_run:
        print("DRY RUN: no changes are written")
    print(f"new key sha256: {_sha256(new_key)}")
    print(
        f"old keys: {1 if plain is not None else 0} from stdin, "
        f"{len(fingerprints)} fingerprints"
    )

    failed = 0
    matched = 0
    rotated = 0
    search_left = 0
    for tenant_id in tenant_ids:
        try:
            counts = _rotate_tenant(
                tenant_id,
                new_key,
                old_keys,
                include_web_search=args.include_web_search,
                dry_run=args.dry_run,
            )
            matched += counts.matched
            rotated += counts.rotated
            if not args.include_web_search:
                search_left += counts.search_matched
            print(f"tenant {tenant_id}: {counts.line()}")
        except Exception as e:
            failed += 1
            print(f"tenant {tenant_id}: ERROR {safe_error_text(e, plain)}")

    if search_left:
        print(
            f"note: {search_left} web search/content rows hold an old key; "
            "they stay unchanged without --include-web-search"
        )
    print(
        f"rotation: tenants {len(tenant_ids)}, matched {matched}, rotated {rotated}, "
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
            "Replace the old platform key with FIREWORKS_DEFAULT_API_KEY "
            "in every LLM and voice provider row that holds it."
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
        help="Also rotate web search and content provider rows that hold an old key.",
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
