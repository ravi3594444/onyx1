"""Apply the platform defaults to every existing tenant.

Usage (inside the api_server container):
    python -m onyx.axi.backfill [--dry-run] [--tenant-id TENANT_ID]

Lists every tenant schema, also the pre-provisioned tenants that no company owns yet,
and calls apply_platform_defaults for each one. The rules are the same as at tenant
creation: a company's own default model or assistant prompt is never changed.
Exit status 1 when a tenant failed. Prints no secrets.
"""

import argparse
import sys

from onyx.axi.tenant_defaults import FIREWORKS_DEFAULT_API_KEY, apply_platform_defaults
from onyx.db.engine.sql_engine import SqlEngine, get_session_with_tenant
from onyx.db.engine.tenant_utils import get_all_tenant_ids
from onyx.utils.variable_functionality import set_is_ee_based_on_env_variable
from shared_configs.contextvars import CURRENT_TENANT_ID_CONTEXTVAR


def _run_tenant(tenant_id: str, dry_run: bool) -> str:
    token = CURRENT_TENANT_ID_CONTEXTVAR.set(tenant_id)
    try:
        with get_session_with_tenant(tenant_id=tenant_id) as db_session:
            result = apply_platform_defaults(db_session, dry_run=dry_run)
        return f"llm={result.llm} instructions={result.instructions}"
    finally:
        CURRENT_TENANT_ID_CONTEXTVAR.reset(token)


def _safe_error(e: Exception) -> str:
    # First line only: SQLAlchemy appends the SQL and its bound values after it.
    message = str(e).split("\n", 1)[0]
    if FIREWORKS_DEFAULT_API_KEY:
        message = message.replace(FIREWORKS_DEFAULT_API_KEY, "****")
    return f"{type(e).__name__}: {message}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Apply the 22nd X AI platform defaults to every tenant."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change; write nothing.",
    )
    parser.add_argument("--tenant-id", help="Run for this tenant only.")
    args = parser.parse_args()

    set_is_ee_based_on_env_variable()
    SqlEngine.init_engine(pool_size=5, max_overflow=2)

    tenant_ids = [args.tenant_id] if args.tenant_id else get_all_tenant_ids()
    if args.dry_run:
        print("DRY RUN: no changes are written")

    failed = 0
    for tenant_id in tenant_ids:
        try:
            print(f"tenant {tenant_id}: {_run_tenant(tenant_id, args.dry_run)}")
        except Exception as e:
            failed += 1
            print(f"tenant {tenant_id}: ERROR {_safe_error(e)}")

    print(
        f"summary: {len(tenant_ids)} tenants, {len(tenant_ids) - failed} ok, "
        f"{failed} failed{' (dry run)' if args.dry_run else ''}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
