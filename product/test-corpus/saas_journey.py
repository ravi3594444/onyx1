"""Customer-journey acceptance test for the multi-tenant stack (Onyx v4.8.4, onyx-saas).

Uses only the Python standard library and the public HTTP API (through nginx).
Prints one PASS or FAIL line for each check and exits with 0 only if all pass.

Usage:
  MT_PASSWORD_SALT=... python3 saas_journey.py --base-url URL --tag TAG \\
      --state journey_state.json [--email-domain example.com] [--after-restart] [--no-chat]

The test acts like customers do. It never configures an LLM provider, a default
model or the default assistant: the platform image must supply them to every new
company. The first run:
  1. signs up owner A and owner B with the web form request (two companies);
  2. checks the platform model "22nd X AI model" and the knowledge rules without
     any setup, and asks one chat question before any document exists;
  3. checks that a company admin cannot read or redirect the platform key;
  4. uploads the corpus to company A and one refund policy to company B;
  5. invites member A into company A;
  6. asks Q1 to Q5 as member A and Q5 in owner A's private project;
  7. checks the separation of the two companies.
A run with --after-restart logs in with the same accounts and repeats the read checks.
With --no-chat (after-restart mode only) it skips the two chat answers: the restore test
runs it on a copy of the stack without the platform key, so no model answers there.

MODEL_API_KEY (optional) is the platform key. The test never sends it. It only checks
that no response body contains it. Without it, the test checks that the api_key field
of the admin provider listing is masked or empty.

Passwords come from HMAC-SHA256(MT_PASSWORD_SALT, tag + role), as in mt_checks.py.
"""

import argparse
import json
import os
import re
import sys
import traceback
import urllib.parse
from pathlib import Path
from typing import Any

from mt_checks import (
    TAG_PATTERN,
    Accounts,
    check_admin_limits,
    check_chat,
    check_connectors,
    check_identities,
    check_personas,
    check_user_files,
    create_files_connector,
    create_persona,
    invited_emails,
    is_admin,
    me,
    me_summary,
    plain_request,
    upload_user_file,
)
from run_checks import (
    ANSWERS,
    HR_Q5_ANSWER,
    NEW_REFUND_FILE,
    PUBLIC_FILES,
    QUESTIONS,
    RESTRICTED_FILE,
    RESTRICTED_MARKER,
    Checks,
    Expected,
    OnyxSession,
    ask,
    check_answer,
    expect,
    log,
    normalise,
    search_docs,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy"))
from default_assistant import ASSISTANT_ADDITION  # noqa: E402

PLATFORM_MODEL_NAME = "22nd X AI model"
OK_PROMPT = "Reply with the single word OK"
# Reserved top-level domain (RFC 2606): no request to it ever leaves the server, also
# when the guard under test fails.
FOREIGN_API_BASE = "https://api.example.invalid/v1"
# Message of _validate_llm_provider_change in onyx/server/manage/llm/api.py (v4.8.4).
GUARD_MESSAGE = "without changing the api key"
DOC_A = "expense-policy.md"
# Company B has only this file. Company A has a copy with the same name, so the
# separation checks compare document ids, not titles.
DOC_B = NEW_REFUND_FILE
A_ONLY_TITLES = tuple(name for name in PUBLIC_FILES if name != DOC_B) + (
    RESTRICTED_FILE,
)
# Owner B asks Q1: company B has no expense policy.
OWNER_B_Q1_ANSWER = Expected(
    uncited=True,
    says_no_info=True,
    forbidden_sources=A_ONLY_TITLES,
    forbidden_text=("1,500", RESTRICTED_MARKER),
)


class KeyWatch:
    """Looks for the platform key in every response body and in every request body."""

    def __init__(self, key: str) -> None:
        self.key = key
        self.responses = 0
        self.leaks: list[str] = []

    def scan(self, path: str, data: Any) -> None:
        self.responses += 1
        if not self.key:
            return
        text = data if isinstance(data, str) else json.dumps(data)
        if self.key in text:
            self.leaks.append(path)

    def guard_request(self, path: str, body: bytes | None) -> None:
        if self.key and body is not None and self.key.encode() in body:
            raise SystemExit(f"refused to send the platform key to {path}")


KEY_WATCH = KeyWatch("")


class WatchedSession(OnyxSession):
    """OnyxSession that passes each request and response through KEY_WATCH."""

    def request(
        self,
        method: str,
        path: str,
        json_body: Any = None,
        raw_body: bytes | None = None,
        content_type: str = "application/json",
        timeout: float = 900,
    ) -> tuple[int, Any]:
        body = raw_body
        if body is None and json_body is not None:
            body = json.dumps(json_body).encode()
        KEY_WATCH.guard_request(path, body)
        status, data = super().request(
            method, path, json_body, raw_body, content_type, timeout
        )
        KEY_WATCH.scan(path, data)
        return status, data

    def stream_lines(self, path: str, json_body: Any) -> list[dict[str, Any]]:
        KEY_WATCH.guard_request(path, json.dumps(json_body).encode())
        packets = super().stream_lines(path, json_body)
        KEY_WATCH.scan(path, packets)
        return packets


def watched_plain_request(
    base_url: str, method: str, path: str, json_body: Any = None
) -> tuple[int, Any]:
    if json_body is not None:
        KEY_WATCH.guard_request(path, json.dumps(json_body).encode())
    status, data = plain_request(base_url, method, path, json_body)
    KEY_WATCH.scan(path, data)
    return status, data


def login(base_url: str, accounts: Accounts, role: str) -> WatchedSession:
    return WatchedSession(base_url, accounts.emails[role], accounts.password(role))


def sign_up(
    checks: Checks, base_url: str, accounts: Accounts, role: str, name: str
) -> None:
    """POST /api/auth/register with the body of basicSignup in web/src/lib/users/svc.ts."""
    email = accounts.emails[role]
    status, data = watched_plain_request(
        base_url,
        "POST",
        "/api/auth/register",
        {"email": email, "username": email, "password": accounts.password(role)},
    )
    checks.record(name, status == 201, {"email": email, "status": status, "body": data})


def chat_summary(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "chat_session_id": result["chat_session_id"],
        "seconds": result["seconds"],
        "answer": result["answer"][:300],
        "cited": result["cited"],
        "error": result["error"],
    }


def redact(data: Any) -> Any:
    """Hides every api_key value. The mask of v4.8.4 still shows 8 characters of the key."""
    if isinstance(data, dict):
        return {
            key: "<hidden>" if key == "api_key" and value else redact(value)
            for key, value in data.items()
        }
    if isinstance(data, list):
        return [redact(item) for item in data]
    return data


def doc_ids(docs: list[dict[str, Any]]) -> list[str]:
    return [str(doc.get("document_id")) for doc in docs]


def titles(docs: list[dict[str, Any]]) -> list[str]:
    return [str(doc.get("semantic_identifier")) for doc in docs]


# ---------------------------------------------------------------- platform defaults


def default_provider(listing: Any) -> tuple[dict[str, Any] | None, str | None]:
    """The default text provider and model name of a provider listing."""
    if not isinstance(listing, dict):
        return None, None
    default = listing.get("default_text") or {}
    provider = next(
        (
            item
            for item in listing.get("providers") or []
            if item.get("id") == default.get("provider_id")
        ),
        None,
    )
    return provider, default.get("model_name")


def provider_names(provider: dict[str, Any], model_name: str | None) -> list[str]:
    """The provider name and the display names of the default model."""
    names = [str(provider.get("name"))]
    for model in provider.get("model_configurations") or []:
        if model.get("name") == model_name:
            names += [
                str(model[key])
                for key in ("display_name", "custom_display_name")
                if model.get(key)
            ]
    return names


def check_platform_model(
    checks: Checks, session: OnyxSession, label: str, suffix: str
) -> None:
    """GET /api/llm/provider is the listing that the chat UI reads (useLLMProviders)."""
    status, listing = session.request("GET", "/api/llm/provider")
    provider, model_name = default_provider(listing)
    names = provider_names(provider, model_name) if provider else []
    checks.record(
        f"{label} sees {PLATFORM_MODEL_NAME!r} as the default model without setup{suffix}",
        status == 200 and PLATFORM_MODEL_NAME in names,
        {
            "status": status,
            "names": names,
            "provider": provider.get("provider") if provider else None,
            "model": model_name,
        },
    )


def check_assistant_rules(checks: Checks, session: OnyxSession, suffix: str) -> None:
    """Read-only: the default assistant prompt holds ASSISTANT_ADDITION."""
    status, config = session.request(
        "GET", "/api/admin/default-assistant/configuration"
    )
    config = config if isinstance(config, dict) else {}
    marker = " ".join(ASSISTANT_ADDITION.split())
    found = {
        field: marker in " ".join(str(config.get(field) or "").split())
        for field in ("system_prompt", "default_system_prompt")
    }
    checks.record(
        f"owner A default assistant holds the knowledge rules{suffix}",
        status == 200 and any(found.values()),
        {"status": status, "found_in": found},
    )


def check_immediate_chat(checks: Checks, session: OnyxSession, suffix: str) -> str:
    """Asks OK_PROMPT and returns the id of the new chat session."""
    result = ask(session, OK_PROMPT)
    answered = bool(re.search(r"\bok\b", normalise(result["answer"])))
    checks.record(
        f"owner A chat answers {OK_PROMPT!r} with the platform model{suffix}",
        answered and not result["error"],
        chat_summary(result),
    )
    return str(result["chat_session_id"])


# ---------------------------------------------------------------- credential protection


def admin_provider(session: OnyxSession) -> tuple[int, dict[str, Any] | None, Any]:
    """The default provider of GET /api/admin/llm/provider, and the whole body."""
    status, listing = session.request("GET", "/api/admin/llm/provider")
    provider, _ = default_provider(listing)
    return status, provider, listing


def key_masked(provider: dict[str, Any] | None) -> bool:
    """True when api_key is empty or holds the mask of _mask_string."""
    if provider is None:
        return False
    value = provider.get("api_key")
    return value is None or value == "" or "****" in str(value)


def provider_fingerprint(provider: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": provider.get("id"),
        "name": provider.get("name"),
        "provider": provider.get("provider"),
        "api_base": provider.get("api_base"),
        "api_key_masked": key_masked(provider),
        "models": sorted(
            str(model.get("name"))
            for model in provider.get("model_configurations") or []
        ),
    }


def check_key_masked(checks: Checks, session: OnyxSession, suffix: str) -> None:
    status, provider, _ = admin_provider(session)
    checks.record(
        f"owner A admin provider listing masks the platform key{suffix}",
        status == 200 and key_masked(provider),
        {
            "status": status,
            "api_key_masked": key_masked(provider),
            "key_known_to_test": bool(KEY_WATCH.key),
        },
    )


def guard_refused(status: int, body: Any) -> bool:
    return 400 <= status < 500 and GUARD_MESSAGE in json.dumps(body).lower()


def check_credential_guard(
    checks: Checks, owner_a: OnyxSession, state: dict[str, Any]
) -> None:
    """A company admin cannot send the stored key to another API base."""
    check_key_masked(checks, owner_a, "")
    status, provider, _ = admin_provider(owner_a)
    if provider is None:
        raise SystemExit(f"admin provider list returned {status} without a default")
    before = provider_fingerprint(provider)
    state["provider_a"] = {k: before[k] for k in ("id", "provider", "api_base")}
    models = [
        {
            "name": model["name"],
            "is_visible": model.get("is_visible", True),
            "max_input_tokens": model.get("max_input_tokens"),
            "supports_image_input": model.get("supports_image_input", False),
        }
        for model in provider.get("model_configurations") or []
    ]
    # The request of the admin UI after an edit of the API base only.
    body = {
        "id": provider["id"],
        "name": provider.get("name"),
        "provider": provider["provider"],
        "api_key": provider.get("api_key"),
        "api_key_changed": False,
        "api_base": FOREIGN_API_BASE,
        "api_version": provider.get("api_version"),
        "custom_config": provider.get("custom_config"),
        "custom_config_changed": False,
        "is_public": provider.get("is_public", True),
        "is_auto_mode": provider.get("is_auto_mode", False),
        "groups": provider.get("groups") or [],
        "personas": provider.get("personas") or [],
        "deployment_name": provider.get("deployment_name"),
        "keep_existing_models": True,
        "model_configurations": models,
    }
    status, data = owner_a.request("PUT", "/api/admin/llm/provider", body)
    checks.record(
        "owner A cannot move the platform provider to a foreign API base",
        guard_refused(status, data),
        {"status": status, "body": redact(data), "api_base": FOREIGN_API_BASE},
    )
    _, after_provider, _ = admin_provider(owner_a)
    after = provider_fingerprint(after_provider) if after_provider else None
    checks.record(
        "the platform provider is unchanged after the refused update",
        after == before,
        {"before": before, "after": after},
    )
    _, model_name = default_provider(owner_a.request("GET", "/api/llm/provider")[1])
    status, data = owner_a.request(
        "POST",
        "/api/admin/llm/test",
        {
            "id": provider["id"],
            "provider": provider["provider"],
            "model": model_name or (models[0]["name"] if models else ""),
            "api_key": None,
            "api_base": FOREIGN_API_BASE,
            "api_version": None,
            "custom_config": None,
            "deployment_name": None,
            "api_key_changed": False,
            "custom_config_changed": False,
        },
    )
    checks.record(
        "owner A cannot test the stored key against a foreign API base",
        status != 200 and guard_refused(status, data),
        {"status": status, "body": redact(data), "api_base": FOREIGN_API_BASE},
    )


def check_member_llm_admin(
    checks: Checks, member: OnyxSession, state: dict[str, Any], suffix: str
) -> None:
    provider_id = state["provider_a"]["id"]
    for path in ("/api/admin/llm/provider", f"/api/admin/llm/provider/{provider_id}"):
        status, data = member.request("GET", path)
        checks.record(
            f"member A gets 403 on {path}{suffix}",
            status == 403,
            {"status": status, "body": redact(data)},
        )


# ---------------------------------------------------------------- accounts


def sign_up_owners(
    checks: Checks, base_url: str, accounts: Accounts, state: dict[str, Any]
) -> dict[str, OnyxSession]:
    sessions: dict[str, OnyxSession] = {}
    for role, letter in (("owner-a", "A"), ("owner-b", "B")):
        sign_up(checks, base_url, accounts, role, f"owner {letter} signs up")
        session = login(base_url, accounts, role)
        sessions[role] = session
        data = me(session)
        state.setdefault("tenants", {})[role] = data.get("team_name")
        checks.record(
            f"owner {letter} is admin of a new workspace",
            bool(data.get("team_name")) and is_admin(data),
            me_summary(data),
        )
    tenants = state["tenants"]
    checks.record(
        "owners A and B are in different workspaces",
        tenants["owner-a"] != tenants["owner-b"],
        tenants,
    )
    return sessions


def invite_member(
    checks: Checks,
    base_url: str,
    accounts: Accounts,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
) -> None:
    owner_a = sessions["owner-a"]
    email = accounts.emails["member-a"]
    status, data = owner_a.request(
        "PUT", "/api/manage/admin/users", {"emails": [email]}
    )
    checks.record(
        "owner A invites member A", status == 200, {"status": status, "body": data}
    )
    status, invited = invited_emails(owner_a)
    checks.record(
        "owner A invited list shows member A",
        email.lower() in invited,
        {"status": status, "invited": invited},
    )
    sign_up(
        checks, base_url, accounts, "member-a", "member A signs up after the invite"
    )
    member = login(base_url, accounts, "member-a")
    invitation = (me(member).get("tenant_info") or {}).get("invitation") or {}
    if invitation.get("tenant_id") == state["tenants"]["owner-a"]:
        # Only an address that already has another workspace gets a pending invitation.
        status, body = member.request(
            "POST",
            "/api/tenants/users/invite/accept",
            {"tenant_id": state["tenants"]["owner-a"]},
        )
        log("member A accepts invitation", {"status": status, "body": body})
        member = login(base_url, accounts, "member-a")
    sessions["member-a"] = member
    data = me(member)
    checks.record(
        "member A lands in workspace A without admin capability",
        data.get("team_name") == state["tenants"]["owner-a"] and not is_admin(data),
        me_summary(data),
    )


# ---------------------------------------------------------------- knowledge


def upload_knowledge(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    accounts: Accounts,
    state: dict[str, Any],
) -> None:
    tag = accounts.tag
    state["connector_a"] = create_files_connector(
        checks, sessions["owner-a"], list(PUBLIC_FILES), f"Journey corpus A {tag}"
    )
    state["user_file_a"] = upload_user_file(
        checks,
        sessions["owner-a"],
        tag,
        file_name=RESTRICTED_FILE,
        label=f"{RESTRICTED_FILE} in owner A private project",
    )
    state["connector_b"] = create_files_connector(
        checks, sessions["owner-b"], [DOC_B], f"Journey corpus B {tag}"
    )


def grounded_answers(
    checks: Checks, sessions: dict[str, OnyxSession], state: dict[str, Any]
) -> None:
    member = sessions["member-a"]
    for key, expected in ANSWERS.items():
        result = ask(member, QUESTIONS[key])
        check_answer(checks, f"chat {key} as member A", result, expected)
    result = ask(
        sessions["owner-a"],
        QUESTIONS["Q5"],
        project_id=state["user_file_a"]["project_id"],
    )
    check_answer(
        checks, "chat Q5 as owner A in the private project", result, HR_Q5_ANSWER
    )


# ---------------------------------------------------------------- separation


def check_search_separation(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
    suffix: str,
) -> None:
    owner_a, owner_b = sessions["owner-a"], sessions["owner-b"]
    docs_a = search_docs(owner_a, QUESTIONS["Q1"]) + search_docs(
        owner_a, QUESTIONS["Q3"]
    )
    docs_b = search_docs(owner_b, QUESTIONS["Q3"])
    ids_a, ids_b = set(doc_ids(docs_a)), set(doc_ids(docs_b))
    state.setdefault("doc_ids_a", [])
    state.setdefault("doc_ids_b", [])
    state["doc_ids_a"] = sorted(ids_a | set(state["doc_ids_a"]))
    state["doc_ids_b"] = sorted(ids_b | set(state["doc_ids_b"]))
    known_a, known_b = set(state["doc_ids_a"]), set(state["doc_ids_b"])
    # Controls: each company finds its own documents.
    checks.record(
        f"owner B search for Q3 finds its own {DOC_B}{suffix}",
        DOC_B in titles(docs_b),
        {"titles": titles(docs_b)},
    )
    found_a = titles(docs_a)
    checks.record(
        f"owner A search finds {DOC_A} and {DOC_B} of company A{suffix}",
        DOC_A in found_a and DOC_B in found_a,
        {"titles": found_a},
    )
    checks.record(
        f"owner A search returns no document id of company B{suffix}",
        not ids_a & known_b,
        {"shared_ids": sorted(ids_a & known_b), "ids_a": sorted(ids_a)},
    )
    docs = search_docs(owner_b, QUESTIONS["Q1"])
    leaked_titles = [title for title in titles(docs) if title in A_ONLY_TITLES]
    leaked_ids = sorted(set(doc_ids(docs)) & known_a)
    checks.record(
        f"owner B search for Q1 returns no document of company A{suffix}",
        not leaked_titles and not leaked_ids and "1,500" not in json.dumps(docs),
        {"titles": titles(docs), "leaked_ids": leaked_ids},
    )


def check_owner_b_chat(checks: Checks, owner_b: OnyxSession, suffix: str) -> None:
    result = ask(owner_b, QUESTIONS["Q1"])
    check_answer(
        checks,
        f"owner B chat Q1 says that its documents lack the information{suffix}",
        result,
        OWNER_B_Q1_ANSWER,
    )


def check_key_never_returned(checks: Checks) -> None:
    if not KEY_WATCH.key:
        checks.skip(
            "the platform key appears in no response",
            "MODEL_API_KEY unset: the masked api_key field is checked instead",
        )
        return
    checks.record(
        "the platform key appears in no response",
        not KEY_WATCH.leaks,
        {"responses_scanned": KEY_WATCH.responses, "paths_with_key": KEY_WATCH.leaks},
    )


# ---------------------------------------------------------------- runs


def first_run(
    checks: Checks, base_url: str, accounts: Accounts, state: dict[str, Any]
) -> None:
    state.clear()
    state["tag"] = accounts.tag
    state["emails"] = accounts.emails
    sessions = sign_up_owners(checks, base_url, accounts, state)
    owner_a, owner_b = sessions["owner-a"], sessions["owner-b"]

    check_platform_model(checks, owner_a, "owner A", "")
    check_platform_model(checks, owner_b, "owner B", "")
    check_assistant_rules(checks, owner_a, "")
    state["chat_session_a"] = check_immediate_chat(checks, owner_a, "")

    check_credential_guard(checks, owner_a, state)

    upload_knowledge(checks, sessions, accounts, state)
    state["persona_a"] = create_persona(owner_a, f"Journey persona A {accounts.tag}")

    invite_member(checks, base_url, accounts, sessions, state)
    check_admin_limits(checks, sessions, accounts, "")
    check_member_llm_admin(checks, sessions["member-a"], state, "")

    grounded_answers(checks, sessions, state)

    check_owner_b_chat(checks, owner_b, "")
    check_search_separation(checks, sessions, state, "")
    check_chat(checks, sessions, state, "")
    check_user_files(checks, sessions, state, "")
    check_connectors(checks, sessions, state, "")
    check_personas(checks, sessions, state, "")


def after_restart_run(
    checks: Checks,
    base_url: str,
    accounts: Accounts,
    state: dict[str, Any],
    no_chat: bool = False,
) -> None:
    expect(
        state.get("tag") == accounts.tag,
        f"state file is for tag {state.get('tag')!r}, not {accounts.tag!r}",
    )
    for key in (
        "tenants",
        "chat_session_a",
        "provider_a",
        "doc_ids_a",
        "doc_ids_b",
        "connector_a",
    ):
        expect(
            bool(state.get(key)),
            f"state file lacks {key}; run without --after-restart first",
        )
    suffix = " after restart"
    sessions: dict[str, OnyxSession] = {
        role: login(base_url, accounts, role)
        for role in ("owner-a", "owner-b", "member-a")
    }
    check_identities(checks, sessions, state, suffix)
    check_platform_model(checks, sessions["owner-a"], "owner A", suffix)
    check_platform_model(checks, sessions["owner-b"], "owner B", suffix)
    check_key_masked(checks, sessions["owner-a"], suffix)
    check_member_llm_admin(checks, sessions["member-a"], state, suffix)
    check_chat(checks, sessions, state, suffix)
    check_search_separation(checks, sessions, state, suffix)
    if no_chat:
        # A restored copy has no platform key, so no model answers there.
        for name in (
            f"owner A chat answers {OK_PROMPT!r} with the platform model{suffix}",
            f"chat Q1 as member A{suffix}",
            f"owner B chat Q1 says that its documents lack the information{suffix}",
        ):
            checks.skip(name, "--no-chat: no model answer")
        return
    check_immediate_chat(checks, sessions["owner-a"], suffix)
    result = ask(sessions["member-a"], QUESTIONS["Q1"])
    check_answer(checks, f"chat Q1 as member A{suffix}", result, ANSWERS["Q1"])
    check_owner_b_chat(checks, sessions["owner-b"], suffix)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--tag", required=True, help="short id: a-z, 0-9 and '-'")
    parser.add_argument("--state", type=Path, default=Path("journey_state.json"))
    parser.add_argument("--email-domain", default="example.com")
    parser.add_argument(
        "--after-restart",
        action="store_true",
        help="log in with the accounts of the state file and repeat the read checks",
    )
    parser.add_argument(
        "--no-chat",
        action="store_true",
        help="with --after-restart: skip the chat answers (a copy without the platform key)",
    )
    args = parser.parse_args()
    if args.no_chat and not args.after_restart:
        parser.error("--no-chat needs --after-restart")
    if urllib.parse.urlparse(args.base_url).scheme not in ("http", "https"):
        parser.error(f"--base-url must use http or https: {args.base_url}")
    if not TAG_PATTERN.match(args.tag):
        parser.error("--tag must match " + TAG_PATTERN.pattern)
    salt = os.environ.get("MT_PASSWORD_SALT", "")
    if len(salt) < 8:
        parser.error("set MT_PASSWORD_SALT (8 characters or more)")
    KEY_WATCH.key = os.environ.get("MODEL_API_KEY", "").strip()
    accounts = Accounts(args.tag, args.email_domain, salt)
    state: dict[str, Any] = {}
    if args.after_restart:
        if not args.state.exists():
            parser.error(f"--after-restart needs the state file {args.state}")
        state = json.loads(args.state.read_text())
    step = "journey-after-restart" if args.after_restart else "journey"
    checks = Checks()
    stopped = f"{step} runs to the end"
    try:
        if args.after_restart:
            after_restart_run(checks, args.base_url, accounts, state, args.no_chat)
        else:
            first_run(checks, args.base_url, accounts, state)
    except SystemExit as error:
        checks.record(stopped, False, str(error.code))
    except Exception as error:
        traceback.print_exc()
        checks.record(stopped, False, repr(error))
    finally:
        check_key_never_returned(checks)
        if not args.after_restart:
            # Keep the ids from a failed run for --after-restart.
            args.state.write_text(json.dumps(state, indent=1))
    return checks.exit_code(step)


if __name__ == "__main__":
    sys.exit(main())
