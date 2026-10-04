"""Administers the owner account, invitations and sign-up policy of an Onyx workspace.

Runs as the admin test user (env ADMIN_EMAIL/ADMIN_PASSWORD) against the public URL.
It uses only the Python standard library and the Onyx v4.8.4 admin API through nginx.
Each action prints one PASS, FAIL or SKIP line and the script exits with 1 if any
requested action failed.

Usage:
  python3 owner-admin.py --base-url https://onyx.example.com --owner OWNER@EXAMPLE.COM
      [--invite EMAIL ...] [--invite-only on|off] [--list]

Actions:
  --owner EMAIL        Report the owner account. Grant admin access when it lacks it.
                       The owner must sign up first; the script never creates accounts
                       and never changes passwords.
  --invite EMAIL       Record an invitation and report the email delivery status that
                       the API returns. Repeatable.
  --invite-only on|off Set the workspace "invite only" sign-up restriction. Refused when
                       the owner is not an admin, so the owner is never locked out.
  --list               Print users (email, admin, active) and pending invitations.

Onyx v4.8.4 has no admin API for the SMTP configuration. Email delivery depends on the
env vars listed in SMTP_ENV_VARS in the api_server container.
"""

import argparse
import sys
import traceback
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "test-corpus"))

from run_checks import Checks, OnyxSession, expect, log, login  # noqa: E402

# backend/onyx/configs/app_configs.py (v4.8.4): EMAIL_CONFIGURED needs
# SMTP_SERVER and EMAIL_FROM (or SMTP_USER), or SENDGRID_API_KEY.
# backend/onyx/server/manage/users.py: ENABLE_EMAIL_INVITES gates the send.
SMTP_ENV_VARS = (
    "ENABLE_EMAIL_INVITES",
    "SMTP_SERVER",
    "SMTP_PORT",
    "SMTP_USER",
    "SMTP_PASS",
    "SMTP_STARTTLS",
    "EMAIL_FROM",
    "SENDGRID_API_KEY",
)
# backend/onyx/server/manage/models.py: EmailInviteStatus.
EMAIL_STATUS_MEANING = {
    "SENT": "the invite email was sent",
    "DISABLED": "ENABLE_EMAIL_INVITES is not 'true'; tell the person yourself",
    "NOT_CONFIGURED": "no SMTP_SERVER/EMAIL_FROM or SENDGRID_API_KEY; tell the person yourself",
    "SEND_FAILED": "the SMTP or SendGrid call failed; see the api_server log",
}
PAGE_SIZE = 1000


def ok(status: int, data: Any, path: str) -> None:
    expect(status == 200, f"{path} returned {status}: {data}")


def list_users(admin: OnyxSession) -> list[dict[str, Any]]:
    """Reads every accepted user with GET /api/manage/users/accepted (paginated)."""
    users: list[dict[str, Any]] = []
    page = 0
    while True:
        path = f"/api/manage/users/accepted?page_num={page}&page_size={PAGE_SIZE}"
        status, data = admin.request("GET", path)
        ok(status, data, path)
        expect(
            isinstance(data, dict) and isinstance(data.get("items"), list),
            f"{path} returned an unexpected body: {data}",
        )
        items: list[dict[str, Any]] = data["items"]
        users.extend(items)
        total = int(data.get("total_items", len(users)))
        if not items or len(users) >= total:
            return users
        page += 1


def list_invited(admin: OnyxSession) -> list[str]:
    """Reads pending invitations with GET /api/manage/users/invited."""
    path = "/api/manage/users/invited"
    status, data = admin.request("GET", path)
    ok(status, data, path)
    expect(isinstance(data, list), f"{path} returned an unexpected body: {data}")
    return [str(item.get("email", "")) for item in data if isinstance(item, dict)]


def find_user(admin: OnyxSession, email: str) -> dict[str, Any] | None:
    """Finds one accepted user by email, case-insensitively."""
    path = f"/api/manage/users/accepted?q={email}&page_num=0&page_size={PAGE_SIZE}"
    status, data = admin.request("GET", path)
    ok(status, data, path)
    expect(
        isinstance(data, dict) and isinstance(data.get("items"), list),
        f"{path} returned an unexpected body: {data}",
    )
    for user in data["items"]:
        if str(user.get("email", "")).lower() == email.lower():
            return user
    return None


def summary(user: dict[str, Any]) -> dict[str, Any]:
    """Keeps the fields that matter for the report. No ids, no tokens."""
    return {
        "email": user.get("email"),
        "is_admin": bool(user.get("is_admin")),
        "is_active": bool(user.get("is_active")),
        "account_type": user.get("account_type"),
        "password_configured": user.get("password_configured"),
    }


def ensure_owner_admin(admin: OnyxSession, owner: str, checks: Checks) -> bool:
    """Reports the owner account and grants admin access when needed.

    Returns True when the owner exists and is an admin at the end.
    """
    user = find_user(admin, owner)
    if user is None:
        invited = owner.lower() in (email.lower() for email in list_invited(admin))
        checks.record(
            f"owner {owner} has an account",
            False,
            f"no account for {owner}{' (invitation pending)' if invited else ''}: "
            f"the owner must sign up first at {admin.base_url}/auth/signup; "
            "this script never creates accounts",
        )
        return False
    checks.record(f"owner {owner} has an account", True, summary(user))
    if not user.get("is_active", False):
        checks.record(f"owner {owner} is active", False, summary(user))
    if user.get("is_admin"):
        checks.record(f"owner {owner} is admin", True, "already admin")
        return True
    # backend/onyx/server/manage/users.py: PATCH /manage/admin/users/admin-access
    # with UserAdminAccessUpdateRequest. Admin is group membership, not a role.
    path = "/api/manage/admin/users/admin-access"
    status, data = admin.request(
        "PATCH", path, json_body={"user_email": user["email"], "is_admin": True}
    )
    ok(status, data, path)
    after = find_user(admin, owner)
    granted = after is not None and bool(after.get("is_admin"))
    checks.record(
        f"owner {owner} is admin",
        granted,
        {"before": summary(user), "after": summary(after) if after else None},
    )
    return granted


def invite(admin: OnyxSession, email: str, checks: Checks) -> None:
    """Invites one email with PUT /api/manage/admin/users and reports the result."""
    path = "/api/manage/admin/users"
    status, data = admin.request("PUT", path, json_body={"emails": [email]})
    if status != 200:
        checks.record(f"invite {email} recorded", False, f"{status}: {data}")
        return
    expect(isinstance(data, dict), f"{path} returned an unexpected body: {data}")
    # BulkInviteResponse: invited_count, email_invite_status.
    email_status = str(data.get("email_invite_status", "UNKNOWN"))
    existing = find_user(admin, email)
    pending = email.lower() in (item.lower() for item in list_invited(admin))
    checks.record(
        f"invite {email} recorded",
        pending or existing is not None,
        {
            "invited_count": data.get("invited_count"),
            "email_invite_status": email_status,
            "pending_invitation": pending,
            "already_has_account": existing is not None,
        },
    )
    meaning = EMAIL_STATUS_MEANING.get(email_status, "status not known to this script")
    name = f"invite email to {email} delivered"
    if existing is not None:
        checks.skip(name, "the email already has an account; no invite email is sent")
    elif email_status == "SENT":
        checks.record(name, True, meaning)
    elif email_status == "SEND_FAILED":
        checks.record(name, False, f"{email_status}: {meaning}")
    else:
        checks.skip(name, f"{email_status}: {meaning}")


def read_settings(admin: OnyxSession) -> dict[str, Any]:
    path = "/api/settings"
    status, data = admin.request("GET", path)
    ok(status, data, path)
    expect(isinstance(data, dict), f"{path} returned an unexpected body: {data}")
    return data


def set_invite_only(
    admin: OnyxSession, enabled: bool, owner_is_admin: bool, checks: Checks
) -> None:
    """Sets Settings.invite_only_enabled with PATCH /api/admin/settings.

    backend/onyx/auth/users.py (v4.8.4): verify_email_is_invited blocks sign-up of
    emails that are not on the invited list when this setting is on. It does not
    block existing accounts, so the owner must have an account before it goes on.
    """
    name = f"invite-only {'on' if enabled else 'off'}"
    before = read_settings(admin).get("invite_only_enabled")
    if enabled and not owner_is_admin:
        checks.record(
            name,
            False,
            f"not applied: the owner is not an admin yet (current value: {before})",
        )
        return
    if before == enabled:
        checks.record(name, True, f"already {enabled}")
        return
    path = "/api/admin/settings"
    status, data = admin.request(
        "PATCH", path, json_body={"invite_only_enabled": enabled}
    )
    ok(status, data, path)
    after = read_settings(admin).get("invite_only_enabled")
    checks.record(name, after == enabled, {"before": before, "after": after})


def print_listing(admin: OnyxSession, checks: Checks) -> None:
    users = list_users(admin)
    invited = list_invited(admin)
    for user in sorted(users, key=lambda item: str(item.get("email", ""))):
        log("user", summary(user))
    for email in sorted(invited):
        log("invited", {"email": email})
    checks.record(
        "list users and invitations",
        True,
        {
            "users": len(users),
            "admins": sum(1 for user in users if user.get("is_admin")),
            "pending_invitations": len(invited),
        },
    )


def run(args: argparse.Namespace, checks: Checks) -> None:
    admin = login(args.base_url, "ADMIN")
    settings = read_settings(admin)
    log(
        "workspace",
        {
            "version": settings.get("version"),
            "invite_only_enabled": settings.get("invite_only_enabled"),
            "anonymous_user_enabled": settings.get("anonymous_user_enabled"),
            "smtp_status_api": "none in v4.8.4; env-only",
            "smtp_env_vars": list(SMTP_ENV_VARS),
        },
    )
    owner_is_admin = ensure_owner_admin(admin, args.owner, checks)
    for email in args.invite:
        invite(admin, email, checks)
    if args.invite_only is not None:
        set_invite_only(admin, args.invite_only == "on", owner_is_admin, checks)
    if args.list:
        print_listing(admin, checks)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", default="http://localhost:3000")
    parser.add_argument("--owner", required=True, help="email of the workspace owner")
    parser.add_argument(
        "--invite", action="append", default=[], metavar="EMAIL", help="invite an email"
    )
    parser.add_argument("--invite-only", choices=("on", "off"), default=None)
    parser.add_argument("--list", action="store_true")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    checks = Checks()
    stopped = "owner-admin runs to the end"
    try:
        run(args, checks)
    except SystemExit as error:
        checks.record(stopped, False, str(error.code))
    except Exception as error:
        traceback.print_exc()
        checks.record(stopped, False, repr(error))
    return checks.exit_code("owner-admin")


if __name__ == "__main__":
    sys.exit(main())
