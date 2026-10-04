#!/usr/bin/env python3
"""Sets or resets the default assistant instructions of one Onyx workspace.

Onyx v4.8.4 keeps the default assistant prompt per workspace (tenant). An admin changes it
with PATCH /api/admin/default-assistant. This script appends the deployment instructions in
ASSISTANT_ADDITION to the built-in default prompt, or resets the prompt to the built-in one.

Usage: default_assistant.py --base-url URL (set|reset|show)
Env: ADMIN_EMAIL, ADMIN_PASSWORD (an admin of the workspace). Nothing secret is printed.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

# The same text that the multi-tenant backend gets from DEFAULT_SYSTEM_PROMPT_ADDITION
# (product/deploy/backend-patch). Keep the two in sync.
ASSISTANT_ADDITION = """
# Knowledge rules
The search tool returns only documents that the current user is allowed to read. Access control \
runs before you see a document. Answer from a returned document even when its text says that it \
is restricted, classified or meant for one group: the user who asks already has access to it. \
Do not refuse on that basis and do not tell the user to ask another team for it.

When the returned documents do not contain the information that the question needs, say so in one \
or two sentences and do not add citations. Only cite a document for a statement that the document \
supports. Do not list or cite unrelated documents to show what you searched.
""".strip()


class Session:
    def __init__(self, base_url: str) -> None:
        if urllib.parse.urlparse(base_url).scheme not in ("http", "https"):
            sys.exit(f"--base-url must use http or https: {base_url}")
        self.base_url = base_url.rstrip("/")
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()),
        )

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
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
        req = urllib.request.Request(  # noqa: S310
            self.base_url + path, data=data, method=method, headers=headers
        )
        try:
            with self.opener.open(req, timeout=60) as resp:
                raw = resp.read()
                status = resp.status
        except urllib.error.HTTPError as err:
            raw = err.read()
            status = err.code
        try:
            return status, json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return status, raw.decode(errors="replace")


def login(session: Session, email: str, password: str) -> None:
    status, body = session.request(
        "POST", "/api/auth/login", form={"username": email, "password": password}
    )
    if status not in (200, 204):
        sys.exit(f"login failed with HTTP {status}: {body}")
    status, me = session.request("GET", "/api/me")
    if status != 200 or "admin" not in (me or {}).get("admin_capabilities", []):
        sys.exit(f"the account is not an admin of this workspace (HTTP {status}).")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("mode", choices=("set", "reset", "show"))
    args = parser.parse_args()
    email = os.environ.get("ADMIN_EMAIL", "")
    password = os.environ.get("ADMIN_PASSWORD", "")
    if not email or not password:
        sys.exit("ADMIN_EMAIL and ADMIN_PASSWORD must be set.")

    session = Session(args.base_url)
    login(session, email, password)
    status, config = session.request(
        "GET", "/api/admin/default-assistant/configuration"
    )
    if status != 200 or not isinstance(config, dict):
        sys.exit(
            f"GET default-assistant configuration failed with HTTP {status}: {config}"
        )
    current = config.get("system_prompt")
    default_prompt = str(config.get("default_system_prompt", ""))
    print(
        f"current prompt: {'built-in default' if current is None else f'custom, {len(current)} chars'}; "
        f"built-in default has {len(default_prompt)} chars"
    )
    if args.mode == "show":
        return 0

    if args.mode == "set":
        if not default_prompt:
            sys.exit(
                "the API returned an empty built-in default prompt; nothing changed."
            )
        new_prompt = default_prompt.rstrip() + "\n\n" + ASSISTANT_ADDITION + "\n"
        payload: dict[str, Any] = {"system_prompt": new_prompt}
    else:
        payload = {"system_prompt": None}
    status, body = session.request(
        "PATCH", "/api/admin/default-assistant", body=payload
    )
    if status != 200:
        sys.exit(f"PATCH default-assistant failed with HTTP {status}: {body}")

    status, config = session.request(
        "GET", "/api/admin/default-assistant/configuration"
    )
    after = (config or {}).get("system_prompt") if isinstance(config, dict) else None
    if args.mode == "set":
        ok = isinstance(after, str) and ASSISTANT_ADDITION in after
    else:
        ok = after is None
    print(
        f"{'PASS' if ok else 'FAIL'} default assistant prompt {args.mode}: "
        f"{'built-in default' if after is None else f'custom, {len(after)} chars'}"
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
