#!/usr/bin/env python3
"""Moves the owner and the other real accounts of the live stack into the multi-tenant stack.

vm-bootstrap.sh cutover calls the subcommands in this order. Password hashes travel only
through pipes and the transfer file (mode 600). Nothing secret reaches stdout, the command
line or the log. The one-time passwords live only in the memory of the register step.

  collect      stdin: live rows (tab separated: email, hash, is_active, is_verified, admin).
               Writes the transfer file, or with --dry-run only prints the plan.
  mapping-sql  prints a psql script that reads the mapping of each address in onyx-saas.
  mark         stdin: the output of that script. Stores the existing mappings.
  register     signs up the owner (new company), invites and signs up the other accounts,
               and grants admin access, through the public API.
  copy-sql     prints a psql script that copies the old hashes into the owner's tenant
               schema in one transaction, then reads them back.
  verify       stdin: the output of that script. Prints counts, exits with 1 on a mismatch.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import re
import secrets
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ADMIN_TOKEN = "admin"  # Permission.FULL_ADMIN_PANEL_ACCESS
SCHEMA_PATTERN = re.compile(r"^tenant_[0-9a-f-]+$")
EMAIL_PATTERN = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
USERS_PATH = "/api/manage/users/accepted?page_num=0&page_size=1000"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: Path) -> dict[str, Any]:
    data: dict[str, Any] = json.loads(path.read_text())
    return data


def save(path: Path, data: dict[str, Any]) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(data, handle, indent=1)
    os.chmod(path, 0o600)


def accounts_of(data: dict[str, Any]) -> list[dict[str, Any]]:
    accounts: list[dict[str, Any]] = data["accounts"]
    return accounts


def psql_literal(value: str) -> str:
    """Quotes a value for a psql \\set argument: backslash and quote are doubled."""
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def read_rows(lines: list[str]) -> list[list[str]]:
    return [line.rstrip("\n").split("\t") for line in lines if line.strip()]


# ---------------------------------------------------------------- collect


def collect(args: argparse.Namespace) -> None:
    owner = args.owner.lower()
    accounts: list[dict[str, Any]] = []
    inactive = 0
    for row in read_rows(sys.stdin.readlines()):
        if len(row) != 5:
            fail("a live account row does not have 5 fields (the row is not shown)")
        email, hashed, active, verified, admin = row
        if not hashed:
            fail("a live account row has no password hash (the row is not shown)")
        if active != "t" and email.lower() != owner:
            inactive += 1
            continue
        accounts.append(
            {
                "role": "owner" if email.lower() == owner else "member",
                "email": email.lower(),
                "hash": hashed,
                "is_active": active == "t",
                "is_verified": verified == "t",
                "was_admin": admin == "t",
            }
        )
    owners = [a for a in accounts if a["role"] == "owner"]
    members = [a for a in accounts if a["role"] == "member"]
    print(f"owner {owner}: {'found' if owners else 'MISSING'} in the live database")
    print(
        f"other real accounts to transfer: {len(members)} "
        f"({sum(a['was_admin'] for a in members)} admins); "
        f"inactive, not transferred: {inactive}"
    )
    problems: list[str] = []
    if not owners:
        problems.append("the owner row is missing in the live database")
    elif not owners[0]["is_active"]:
        problems.append("the owner account is inactive in the live database")
    else:
        print(
            f"owner admin in the live stack: {'yes' if owners[0]['was_admin'] else 'no'}"
        )
    bad = [a for a in accounts if not EMAIL_PATTERN.match(a["email"])]
    if bad:
        problems.append(f"{len(bad)} addresses are not plain addresses (not shown)")
    plus = [a for a in accounts if "+" in a["email"].split("@")[0]]
    if plus:
        # verify_email_domain in onyx/auth/users.py refuses "+" in MULTI_TENANT mode.
        problems.append(f"{len(plus)} addresses have '+' in the local part (not shown)")
    if args.signup_limit and len(accounts) > args.signup_limit:
        problems.append(
            f"{len(accounts)} sign-ups exceed the limit of {args.signup_limit} per hour. "
            "Add SIGNUP_RATE_LIMIT_ENABLED=false to /srv/onyx/secrets/saas.env"
        )
    for problem in problems:
        print(f"transfer blocked: {problem}")
    if problems:
        fail("the account transfer cannot run (see above). Nothing was changed.")
    if args.dry_run:
        print("dry run: the transfer can run; nothing written")
        return
    save(args.file, {"owner": owner, "accounts": accounts})
    print(f"Wrote {args.file} (mode 600, holds the password hashes; not shown).")


# ---------------------------------------------------------------- mapping


def mapping_sql(args: argparse.Namespace) -> None:
    lines = ["\\set ON_ERROR_STOP on"]
    for index, account in enumerate(accounts_of(load(args.file))):
        lines.append(f"\\set email {psql_literal(account['email'])}")
        # The only formatted value is the integer index.
        lines.append(
            f"SELECT {index}, coalesce((SELECT tenant_id"  # noqa: S608
            " FROM public.user_tenant_mapping"
            " WHERE email = lower(:'email') AND active LIMIT 1), '');"
        )
    print("\n".join(lines))


def mark(args: argparse.Namespace) -> None:
    data = load(args.file)
    accounts = accounts_of(data)
    seen = 0
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        index, tenant = line.split("|", 1)
        accounts[int(index)]["existing_tenant"] = tenant or None
        seen += 1
    if seen != len(accounts):
        fail(f"the mapping query returned {seen} rows for {len(accounts)} accounts")
    save(args.file, data)
    existing = sum(bool(a["existing_tenant"]) for a in accounts)
    print(f"accounts that already have a company in onyx-saas: {existing}")


# ---------------------------------------------------------------- register


class Client:
    def __init__(self, base_url: str) -> None:
        if urllib.parse.urlparse(base_url).scheme != "https":
            fail(f"--base-url must use https: {base_url}")
        self.base_url = base_url.rstrip("/")
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()),
        )

    def call(
        self,
        method: str,
        path: str,
        body: Any = None,
        form: dict[str, str] | None = None,
    ) -> tuple[int, Any]:
        data: bytes | None = None
        headers = {"Accept": "application/json"}
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        # __init__ allows only https.
        request = urllib.request.Request(  # noqa: S310
            self.base_url + path, data=data, method=method, headers=headers
        )
        try:
            with self.opener.open(request, timeout=300) as response:
                status, text = response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            status, text = error.code, error.read().decode()
        try:
            return status, json.loads(text) if text else None
        except json.JSONDecodeError:
            return status, text


def one_time_password() -> str:
    """Meets every optional v4.8.4 password rule. It is never stored or printed."""
    return f"Ot{secrets.token_urlsafe(24)}7!"


def detail(body: Any) -> str:
    """The error detail of a response, without echoing request data."""
    if isinstance(body, dict):
        return str(body.get("detail") or body.get("error_code") or "")[:200]
    return ""


def sign_up(base_url: str, email: str, label: str) -> str:
    """POST /api/auth/register like the web form. Returns the one-time password."""
    password = one_time_password()
    status, body = Client(base_url).call(
        "POST",
        "/api/auth/register",
        {"email": email, "username": email, "password": password},
    )
    if status != 201:
        fail(f"sign-up of {label} returned {status}: {detail(body)}")
    return password


def log_in(base_url: str, email: str, password: str, label: str) -> Client:
    client = Client(base_url)
    status, body = client.call(
        "POST", "/api/auth/login", form={"username": email, "password": password}
    )
    if status not in (200, 204):
        fail(f"login of {label} returned {status}: {detail(body)}")
    return client


def register(args: argparse.Namespace) -> None:
    data = load(args.file)
    accounts = accounts_of(data)
    owner = next(a for a in accounts if a["role"] == "owner")
    members = [a for a in accounts if a["role"] == "member"]
    if owner.get("existing_tenant"):
        # Trust a company only when an earlier run of this transfer created it. Anyone can
        # sign up on the public URL, so an unknown company with the owner's address may
        # belong to somebody else: stop, and copy no password hash into it.
        if owner.get("created_tenant") != owner["existing_tenant"]:
            fail(
                "the owner's address already has a company in onyx-saas that this "
                "transfer did not create; nothing was copied. Check that company first."
            )
        foreign = [
            m
            for m in members
            if m.get("existing_tenant")
            and m["existing_tenant"] != owner["created_tenant"]
        ]
        if foreign:
            fail(
                f"{len(foreign)} accounts already have another company in onyx-saas; "
                "nothing was copied. Check those companies first."
            )
        missing = [m for m in members if not m.get("existing_tenant")]
        print("owner: has a company in onyx-saas already; no sign-up")
        print(
            f"other real accounts without an onyx-saas account: {len(missing)} (invite them in Admin > Users)"
        )
        return
    password = sign_up(args.base_url, owner["email"], "the owner")
    owner_client = log_in(args.base_url, owner["email"], password, "the owner")
    del password
    status, me = owner_client.call("GET", "/api/me")
    if (
        status != 200
        or not isinstance(me, dict)
        or ADMIN_TOKEN not in (me.get("admin_capabilities") or [])
    ):
        fail(
            f"the owner is not admin of a new company after the sign-up (status {status})"
        )
    tenant = str(me.get("team_name") or "")
    if not tenant.startswith("tenant_"):
        fail("/api/me of the owner shows no company id after the sign-up")
    owner["registered"] = True
    owner["created_tenant"] = tenant
    save(args.file, data)
    print("owner: signed up through the web form request; admin of a new company")

    foreign = [m for m in members if m.get("existing_tenant")]
    if foreign:
        fail(
            f"{len(foreign)} accounts already have a company in onyx-saas that this "
            "transfer did not create; nothing was copied. Check those companies first."
        )

    new_members = [m for m in members if not m.get("existing_tenant")]
    if new_members:
        status, body = owner_client.call(
            "PUT",
            "/api/manage/admin/users",
            {"emails": [m["email"] for m in new_members]},
        )
        if status != 200:
            fail(
                f"the invitation of {len(new_members)} accounts returned {status}: {detail(body)}"
            )
    for index, member in enumerate(new_members, start=1):
        label = f"account {index} of {len(new_members)}"
        password = sign_up(args.base_url, member["email"], label)
        log_in(args.base_url, member["email"], password, label)
        del password
        member["registered"] = True
        save(args.file, data)
    status, users = owner_client.call("GET", USERS_PATH)
    listed = {
        str(item.get("email")).lower(): item
        for item in (users.get("items", []) if isinstance(users, dict) else [])
    }
    absent = [m for m in new_members if m["email"] not in listed]
    if status != 200 or absent:
        fail(
            f"the owner's user list (status {status}) lacks {len(absent)} invited accounts"
        )
    print(
        f"other real accounts: {len(new_members)} invited and signed up into the owner's company"
    )

    admins = [m for m in new_members if m["was_admin"]]
    for member in admins:
        status, body = owner_client.call(
            "PATCH",
            "/api/manage/admin/users/admin-access",
            {"user_email": member["email"], "is_admin": True},
        )
        if status != 200:
            fail(f"granting admin access returned {status}: {detail(body)}")
    print(f"admin access granted: {len(admins)}")


# ---------------------------------------------------------------- copy and verify


def copy_targets(data: dict[str, Any], schema: str) -> list[tuple[int, dict[str, Any]]]:
    """Accounts whose user row is in <schema>: new sign-ups and earlier transfers."""
    owner = next(a for a in accounts_of(data) if a["role"] == "owner")
    if owner.get("created_tenant") != schema:
        fail("the target company is not the one that this transfer created")
    return [
        (index, account)
        for index, account in enumerate(accounts_of(data))
        if account.get("registered") or account.get("existing_tenant") == schema
    ]


def set_lines(account: dict[str, Any]) -> list[str]:
    return [
        f"\\set email {psql_literal(account['email'])}",
        f"\\set hash {psql_literal(account['hash'])}",
        f"\\set verified {'true' if account['is_verified'] else 'false'}",
    ]


def copy_sql(args: argparse.Namespace) -> None:
    if not SCHEMA_PATTERN.match(args.schema):
        fail("the tenant schema name has an unexpected form")
    data = load(args.file)
    targets = copy_targets(data, args.schema)
    # :"schema" is a quoted identifier and :'email' a quoted literal (psql interpolation).
    lines = [
        "\\set ON_ERROR_STOP on",
        f"\\set schema {psql_literal(args.schema)}",
        "BEGIN;",
    ]
    for _, account in targets:
        lines += set_lines(account)
        lines.append(
            'UPDATE :"schema"."user" SET hashed_password = :\'hash\','
            " is_verified = :verified WHERE lower(email) = lower(:'email');"
        )
    lines.append("COMMIT;")
    for index, account in targets:
        lines += set_lines(account)
        # The only formatted value is the integer index.
        lines.append(
            f"SELECT {index}, count(*),"  # noqa: S608
            " coalesce(bool_or(u.effective_permissions @> '[\"admin\"]'::jsonb), false),"
            " EXISTS (SELECT 1 FROM public.user_tenant_mapping m"
            " WHERE m.email = lower(:'email') AND m.tenant_id = :'schema' AND m.active)"
            ' FROM :"schema"."user" u WHERE lower(u.email) = lower(:\'email\')'
            " AND u.hashed_password = :'hash' AND u.is_active;"
        )
    print("\n".join(lines))


def verify(args: argparse.Namespace) -> None:
    data = load(args.file)
    accounts = accounts_of(data)
    results: dict[int, tuple[bool, bool]] = {}
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        index, count, admin, mapped = line.split("|")
        results[int(index)] = (count == "1" and mapped == "t", admin == "t")
    targets = copy_targets(data, args.schema)
    problems = 0
    for index, account in targets:
        copied, admin = results.get(index, (False, False))
        if not copied:
            problems += 1
        # Only the owner and new sign-ups got their admin access from this transfer.
        if account["role"] == "owner" or account.get("registered"):
            wants_admin = account["role"] == "owner" or account["was_admin"]
            if wants_admin and not admin:
                problems += 1
        account["transferred"] = copied
    save(args.file, data)
    owner_index, owner = next(
        (i, a) for i, a in enumerate(accounts) if a["role"] == "owner"
    )
    owner_copied, owner_admin = results.get(owner_index, (False, False))
    if owner_copied:
        print(
            "owner: transferred, password unchanged, "
            + ("admin" if owner_admin else "NOT admin")
        )
    else:
        print("owner: NOT transferred")
    members = [(i, a) for i, a in targets if a["role"] == "member"]
    done = [i for i, _ in members if results.get(i, (False, False))[0]]
    admins = [i for i in done if results[i][1]]
    skipped = sum(a["role"] == "member" for a in accounts) - len(members)
    print(
        f"other real accounts: {len(done)} of {len(members)} transferred, password unchanged"
        f" ({len(admins)} admins); not in the owner's company: {skipped}"
    )
    if problems or not owner_copied:
        fail(f"{problems} transfer checks failed")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("collect")
    p.add_argument("--owner", required=True)
    p.add_argument("--file", type=Path)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--signup-limit", type=int, default=5)
    for name in ("mapping-sql", "mark"):
        sub.add_parser(name).add_argument("--file", type=Path, required=True)
    p = sub.add_parser("register")
    p.add_argument("--file", type=Path, required=True)
    p.add_argument("--base-url", required=True)
    for name in ("copy-sql", "verify"):
        p = sub.add_parser(name)
        p.add_argument("--file", type=Path, required=True)
        p.add_argument("--schema", required=True)
    args = parser.parse_args()
    if args.command == "collect":
        if not EMAIL_PATTERN.match(args.owner):
            fail("--owner is not a plain address")
        if not args.dry_run and args.file is None:
            fail("collect needs --file or --dry-run")
    handlers = {
        "collect": collect,
        "mapping-sql": mapping_sql,
        "mark": mark,
        "register": register,
        "copy-sql": copy_sql,
        "verify": verify,
    }
    handlers[args.command](args)


if __name__ == "__main__":
    main()
