"""Acceptance checks for Onyx v4.8.4 with MULTI_TENANT=true (one workspace per company).

Uses only the Python standard library and the public HTTP API (through nginx).
Prints one PASS or FAIL line for each check and exits with 0 only if all pass.

Usage:
  MT_PASSWORD_SALT=... python3 mt_checks.py --base-url URL --tag TAG [--after-restart]

The first run registers owner A, owner B and member A, uploads one document to
each workspace and writes the ids to the state file. A run with --after-restart
logs in with the same accounts and repeats only the read checks.

Passwords come from HMAC-SHA256(MT_PASSWORD_SALT, tag + role). Keep the salt
secret: anyone with the salt and the tag can log in as the test accounts.

Email addresses use "-" and not "+" before the tag: in MULTI_TENANT mode,
v4.8.4 rejects "+" in the local part of a new account unless the domain is
onyx.app (verify_email_domain in backend/onyx/auth/users.py).
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from run_checks import (
    CORPUS_DIR,
    FILE_END_STATUSES,
    NEW_REFUND_FILE,
    NO_INFO_PHRASES,
    QUESTIONS,
    Checks,
    OnyxSession,
    access_denied,
    ask,
    create_chat_session,
    expect,
    log,
    normalise,
    poll,
    search_docs,
    wait_for_indexing,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy"))
from default_assistant import ASSISTANT_ADDITION  # noqa: E402

DOC_A = "expense-policy.md"
DOC_B = NEW_REFUND_FILE
QUERY_A = QUESTIONS["Q1"]
QUERY_B = QUESTIONS["Q3"]
ADMIN_TOKEN = "admin"  # Permission.FULL_ADMIN_PANEL_ACCESS
ADMIN_ENDPOINT = "/api/manage/users/accepted?page_num=0&page_size=1000"
ROLES = ("owner-a", "owner-b", "member-a")
TAG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")


def password_for(salt: str, tag: str, role: str) -> str:
    """Derives a stable password that meets every optional v4.8.4 password rule."""
    digest = hmac.new(salt.encode(), f"{tag}:{role}".encode(), hashlib.sha256)
    body = base64.urlsafe_b64encode(digest.digest()).decode().rstrip("=")[:32]
    return f"Mt{body}7!"


class Accounts:
    """The email addresses and passwords of one test run."""

    def __init__(self, tag: str, domain: str, salt: str) -> None:
        self.tag = tag
        self.emails = {role: f"{role}-{tag}@{domain}" for role in ROLES}
        self.invitee_b = f"invitee-b-{tag}@{domain}"
        self._passwords = {role: password_for(salt, tag, role) for role in ROLES}

    def password(self, role: str) -> str:
        return self._passwords[role]


def plain_request(
    base_url: str,
    method: str,
    path: str,
    json_body: Any = None,
    bearer: str | None = None,
) -> tuple[int, Any]:
    """Sends one request without a session cookie, optionally with a Bearer token."""
    headers: dict[str, str] = {}
    body = None
    if json_body is not None:
        body = json.dumps(json_body).encode()
        headers["Content-Type"] = "application/json"
    if bearer is not None:
        headers["Authorization"] = f"Bearer {bearer}"
    # main() allows only http and https base URLs.
    request = urllib.request.Request(  # noqa: S310
        base_url.rstrip("/") + path, data=body, method=method, headers=headers
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:  # noqa: S310
            status, text = response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        status, text = error.code, error.read().decode()
    try:
        return status, json.loads(text) if text else None
    except json.JSONDecodeError:
        return status, text


def register(
    checks: Checks, base_url: str, accounts: Accounts, role: str, name: str
) -> None:
    """POST /api/auth/register (fastapi-users register router)."""
    email = accounts.emails[role]
    status, data = plain_request(
        base_url,
        "POST",
        "/api/auth/register",
        {"email": email, "password": accounts.password(role)},
    )
    checks.record(name, status == 201, {"email": email, "status": status, "body": data})


def me(session: OnyxSession) -> dict[str, Any]:
    status, data = session.request("GET", "/api/me")
    expect(status == 200 and isinstance(data, dict), f"/api/me returned {status}")
    result: dict[str, Any] = data
    return result


def me_summary(data: dict[str, Any]) -> dict[str, Any]:
    return {
        "email": data.get("email"),
        "team_name": data.get("team_name"),
        "tenant_info": data.get("tenant_info"),
        "admin_capabilities": data.get("admin_capabilities"),
    }


def is_admin(data: dict[str, Any]) -> bool:
    return ADMIN_TOKEN in (data.get("admin_capabilities") or [])


def titles_of(docs: list[dict[str, Any]]) -> list[str]:
    return [str(doc.get("semantic_identifier")) for doc in docs]


def user_emails(session: OnyxSession) -> tuple[int, list[str]]:
    status, data = session.request("GET", ADMIN_ENDPOINT)
    if status != 200 or not isinstance(data, dict):
        return status, []
    return status, [str(item.get("email")).lower() for item in data.get("items", [])]


def invited_emails(session: OnyxSession) -> tuple[int, list[str]]:
    status, data = session.request("GET", "/api/manage/users/invited")
    if status != 200 or not isinstance(data, list):
        return status, []
    return status, [str(item.get("email")).lower() for item in data]


def create_file_connector(
    checks: Checks, session: OnyxSession, file_name: str, name: str
) -> dict[str, Any]:
    """Uploads one corpus file and indexes it, as step_index of run_checks does."""
    uploaded = session.upload(
        "/api/manage/admin/connector/file/upload", [CORPUS_DIR / file_name], {}
    )
    status, connector = session.request(
        "POST",
        "/api/manage/admin/connector",
        {
            "name": name,
            "source": "file",
            "input_type": "load_state",
            "connector_specific_config": {
                "file_locations": uploaded["file_paths"],
                "file_names": uploaded["file_names"],
                "zip_metadata_file_id": None,
            },
            "refresh_freq": None,
            "prune_freq": None,
            "indexing_start": None,
            "access_type": "public",
            "groups": [],
        },
    )
    expect(status == 200, f"connector create returned {status}: {connector}")
    status, credential = session.request(
        "POST",
        "/api/manage/credential",
        {
            "credential_json": {},
            "admin_public": True,
            "source": "file",
            "name": name,
            "curator_public": False,
            "groups": [],
        },
    )
    expect(status == 200, f"credential create returned {status}: {credential}")
    status, link = session.request(
        "PUT",
        f"/api/manage/connector/{connector['id']}/credential/{credential['id']}",
        {
            "name": name,
            "access_type": "public",
            "groups": [],
            "auto_sync_options": None,
            "processing_mode": "REGULAR",
        },
    )
    expect(status == 200, f"cc-pair link returned {status}: {link}")
    info = {"name": name, "connector_id": connector["id"], "cc_pair_id": link["data"]}
    log(f"connector {name}", info)
    wait_for_indexing(checks, session, link["data"], 1)
    return info


def upload_user_file(checks: Checks, session: OnyxSession, tag: str) -> dict[str, Any]:
    status, project = session.request(
        "POST",
        "/api/user/projects/create?" + urllib.parse.urlencode({"name": f"MT A {tag}"}),
    )
    expect(status == 200, f"project create returned {status}: {project}")
    upload = session.upload(
        "/api/user/projects/file/upload",
        [CORPUS_DIR / DOC_A],
        {"project_id": str(project["id"])},
    )
    file_ids = [str(file["id"]) for file in upload["user_files"]]
    expect(len(file_ids) == 1, f"project file upload returned {upload}")

    def read_statuses() -> list[str]:
        status, data = session.request(
            "POST", "/api/user/projects/file/statuses", {"file_ids": file_ids}
        )
        expect(status == 200, f"file statuses returned {status}: {data}")
        return [item["status"] for item in data]

    statuses, seconds = poll(
        read_statuses, lambda found: all(s in FILE_END_STATUSES for s in found)
    )
    checks.record(
        "owner A user file reaches COMPLETED",
        statuses == ["COMPLETED"],
        {"statuses": statuses, "seconds": seconds},
    )
    return {"project_id": project["id"], "user_file_id": file_ids[0]}


def create_persona(session: OnyxSession, name: str) -> dict[str, Any]:
    """POST /api/persona with the required PersonaUpsertRequest fields only."""
    status, persona = session.request(
        "POST",
        "/api/persona",
        {
            "name": name,
            "description": "Multi-tenant isolation check",
            "document_set_ids": [],
            "tool_ids": [],
            "system_prompt": "You are a test agent.",
            "task_prompt": "",
            "datetime_aware": False,
        },
    )
    expect(status == 200, f"persona create returned {status}: {persona}")
    info = {"id": persona["id"], "name": name, "is_public": persona.get("is_public")}
    log("persona", info)
    return info


def persona_names(session: OnyxSession) -> tuple[int, list[str]]:
    status, data = session.request("GET", "/api/persona")
    if status != 200 or not isinstance(data, list):
        return status, []
    return status, [str(item.get("name")) for item in data]


def connector_names(session: OnyxSession) -> tuple[int, list[str]]:
    status, data = session.request("GET", "/api/manage/connector")
    if status != 200 or not isinstance(data, list):
        return status, []
    return status, [str(item.get("name")) for item in data]


# ---------------------------------------------------------------- write steps


def setup_accounts(
    checks: Checks, base_url: str, accounts: Accounts, state: dict[str, Any]
) -> dict[str, OnyxSession]:
    """Steps 1-3: registers the owners and the member and records their workspaces."""
    sessions: dict[str, OnyxSession] = {}
    for role, letter in (("owner-a", "A"), ("owner-b", "B")):
        register(
            checks, base_url, accounts, role, f"owner {letter} registers uninvited"
        )
        session = OnyxSession(base_url, accounts.emails[role], accounts.password(role))
        sessions[role] = session
        data = me(session)
        state.setdefault("tenants", {})[role] = data.get("team_name")
        checks.record(
            f"owner {letter} /api/me shows a workspace and admin capability",
            bool(data.get("team_name")) and is_admin(data),
            me_summary(data),
        )
    tenants = state["tenants"]
    checks.record(
        "owners A and B are in different workspaces",
        tenants["owner-a"] != tenants["owner-b"],
        tenants,
    )

    owner_a = sessions["owner-a"]
    member_email = accounts.emails["member-a"]
    status, data = owner_a.request(
        "PUT", "/api/manage/admin/users", {"emails": [member_email]}
    )
    state["member_invite"] = {"status": status, "body": data}
    checks.record(
        "owner A invites member A",
        status == 200,
        {"status": status, "body": data},
    )
    if isinstance(data, dict):
        log("email_invite_status", data.get("email_invite_status"))
    status, invited = invited_emails(owner_a)
    checks.record(
        "owner A invited list shows member A",
        member_email.lower() in invited,
        {"status": status, "invited": invited},
    )
    # A first workspace for an address is an active mapping: register joins it.
    register(checks, base_url, accounts, "member-a", "member A registers after invite")
    member = OnyxSession(base_url, member_email, accounts.password("member-a"))
    data = me(member)
    invitation = (data.get("tenant_info") or {}).get("invitation") or {}
    if invitation.get("tenant_id") == tenants["owner-a"]:
        # Only an address that already has another workspace gets a pending invitation.
        status, body = member.request(
            "POST",
            "/api/tenants/users/invite/accept",
            {"tenant_id": tenants["owner-a"]},
        )
        log("member A accepts invitation", {"status": status, "body": body})
        member = OnyxSession(base_url, member_email, accounts.password("member-a"))
    sessions["member-a"] = member
    return sessions


def setup_data(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    accounts: Accounts,
    state: dict[str, Any],
) -> None:
    """Step 5 writes: connectors, chat session, persona and user file."""
    owner_a, owner_b = sessions["owner-a"], sessions["owner-b"]
    tag = accounts.tag
    state["connector_a"] = create_file_connector(
        checks, owner_a, DOC_A, f"MT connector A {tag}"
    )
    state["connector_b"] = create_file_connector(
        checks, owner_b, DOC_B, f"MT connector B {tag}"
    )
    state["chat_session_a"] = create_chat_session(owner_a, f"MT chat A {tag}")
    state["persona_a"] = create_persona(owner_a, f"MT persona A {tag}")
    state["user_file_a"] = upload_user_file(checks, owner_a, tag)
    model = model_settings()
    if model is None:
        log("MODEL_API_KEY unset: the companies get no model; chat answer checks skipped")
        state["model_configured"] = False
    else:
        state["model_configured"] = all(
            configure_company_model(checks, sessions[role], label, model)
            for label, role in (("owner A", "owner-a"), ("owner B", "owner-b"))
        )


def model_settings() -> dict[str, str] | None:
    """The hosted model from the environment, or None when MODEL_API_KEY is unset."""
    key = os.environ.get("MODEL_API_KEY", "").strip()
    if not key:
        return None
    return {
        "api_key": key,
        "provider": os.environ.get("MODEL_PROVIDER", "fireworks_ai").strip(),
        "model": os.environ.get("MODEL_NAME", "").strip(),
        "api_base": os.environ.get("MODEL_API_BASE", "").strip(),
        "display_name": os.environ.get("MODEL_DISPLAY_NAME", "22nd X AI model").strip(),
    }


def configure_company_model(
    checks: Checks, owner: OnyxSession, label: str, model: dict[str, str]
) -> bool:
    """Creates the hosted model provider in one company and makes it the default.

    Every company configures its own model in Onyx v4.8.4 (Admin > LLM). This is the
    same request as the admin UI sends. The key is never printed.
    """
    body: dict[str, Any] = {
        "id": None,
        "name": model["display_name"],
        "provider": model["provider"],
        "api_key": model["api_key"],
        "api_key_changed": True,
        "api_base": model["api_base"] or None,
        "api_version": None,
        "custom_config": {},
        "custom_config_changed": True,
        "is_public": True,
        "is_auto_mode": False,
        "groups": [],
        "personas": [],
        "deployment_name": None,
        "keep_existing_models": False,
        "model_configurations": [
            {
                "name": model["model"],
                "is_visible": True,
                "max_input_tokens": None,
                "supports_image_input": False,
            }
        ],
    }
    status, saved = owner.request("PUT", "/api/admin/llm/provider?is_creation=true", body)
    ok = status == 200 and isinstance(saved, dict) and "id" in saved
    checks.record(
        f"{label} creates the model provider {model['display_name']!r}",
        ok,
        {"status": status, "provider": model["provider"], "model": model["model"]},
    )
    if not ok:
        return False
    status, _ = owner.request(
        "POST",
        "/api/admin/llm/default",
        {"provider_id": int(saved["id"]), "model_name": model["model"]},
    )
    checks.record(f"{label} sets the model as default", status == 200, {"status": status})
    status, config = owner.request("GET", "/api/admin/default-assistant/configuration")
    default_prompt = str((config or {}).get("default_system_prompt", "")) if status == 200 else ""
    prompt_ok = False
    if default_prompt:
        status, _ = owner.request(
            "PATCH",
            "/api/admin/default-assistant",
            {"system_prompt": default_prompt.rstrip() + "\n\n" + ASSISTANT_ADDITION + "\n"},
        )
        prompt_ok = status == 200
    checks.record(
        f"{label} adds the knowledge rules to the default assistant",
        prompt_ok,
        {"status": status, "default_prompt_chars": len(default_prompt)},
    )
    return True


def says_no_info(answer: str) -> bool:
    text = normalise(answer)
    return any(normalise(phrase) in text for phrase in NO_INFO_PHRASES)


def chat_summary(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "seconds": result["seconds"],
        "cited": result["cited"],
        "retrieved": result["retrieved"],
        "answer": result["answer"][:300],
        "error": result["error"],
    }


def check_model_chat(
    checks: Checks, sessions: dict[str, OnyxSession], state: dict[str, Any], suffix: str
) -> None:
    """Answers come from the own company's documents only."""
    if not state.get("model_configured"):
        log("model not configured in the companies: chat answer checks skipped")
        return
    cases = (
        ("owner A", "owner-a", QUERY_A, DOC_A, DOC_B, "1,500"),
        ("member A", "member-a", QUERY_A, DOC_A, DOC_B, "1,500"),
        ("owner B", "owner-b", QUERY_B, DOC_B, DOC_A, "30 days"),
    )
    for label, role, question, own_doc, other_doc, fact in cases:
        result = ask(sessions[role], question)
        answer = normalise(result["answer"])
        problems = []
        if own_doc not in result["cited"]:
            problems.append(f"does not cite {own_doc}")
        if other_doc in result["cited"] + result["retrieved"]:
            problems.append(f"sees {other_doc} of the other company")
        if normalise(fact) not in answer:
            problems.append(f"does not state {fact!r}")
        if result["error"] or not result["answer"]:
            problems.append("no answer")
        checks.record(
            f"{label} chat answers from the own document{suffix}",
            not problems,
            {"problems": problems, **chat_summary(result)},
        )
    # Company B has no expense policy. The answer must say so, without citations, and must
    # never show company A's document.
    result = ask(sessions["owner-b"], QUERY_A)
    problems = []
    if DOC_A in result["cited"] + result["retrieved"]:
        problems.append(f"sees {DOC_A} of company A")
    if result["cited"]:
        problems.append("cites documents")
    if not says_no_info(result["answer"]):
        problems.append("does not say that the documents lack the information")
    if result["error"] or not result["answer"]:
        problems.append("no answer")
    checks.record(
        f"owner B chat on company A's topic says the documents lack it{suffix}",
        not problems,
        {"problems": problems, **chat_summary(result)},
    )


def invite_from_b(
    checks: Checks, sessions: dict[str, OnyxSession], accounts: Accounts
) -> None:
    """Step 4 write: the invite body names no workspace, so B can only invite into B."""
    owner_a, owner_b = sessions["owner-a"], sessions["owner-b"]
    status, data = owner_b.request(
        "PUT", "/api/manage/admin/users", {"emails": [accounts.invitee_b]}
    )
    checks.record(
        "owner B invite request succeeds",
        status == 200,
        {"status": status, "body": data},
    )
    status_b, invited_b = invited_emails(owner_b)
    status_a, invited_a = invited_emails(owner_a)
    checks.record(
        "owner B invite lands in workspace B and not in A",
        accounts.invitee_b in invited_b and accounts.invitee_b not in invited_a,
        {
            "status_b": status_b,
            "status_a": status_a,
            "in_b": accounts.invitee_b in invited_b,
            "in_a": accounts.invitee_b in invited_a,
        },
    )


# ----------------------------------------------------------------- read steps


def check_identities(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
    suffix: str,
) -> None:
    tenants = state["tenants"]
    for role, letter in (("owner-a", "A"), ("owner-b", "B")):
        data = me(sessions[role])
        checks.record(
            f"owner {letter} keeps workspace and admin capability{suffix}",
            data.get("team_name") == tenants[role] and is_admin(data),
            me_summary(data),
        )
    data = me(sessions["member-a"])
    checks.record(
        f"member A is in workspace A without admin capability{suffix}",
        data.get("team_name") == tenants["owner-a"] and not is_admin(data),
        me_summary(data),
    )


def check_admin_limits(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    accounts: Accounts,
    suffix: str,
) -> None:
    owner_a, owner_b, member = (sessions[role] for role in ROLES)
    status, data = member.request("GET", ADMIN_ENDPOINT)
    checks.record(
        f"member A gets 403 on {ADMIN_ENDPOINT}{suffix}",
        status == 403,
        {"status": status, "body": data},
    )
    status, emails_a = user_emails(owner_a)
    checks.record(
        f"owner A user list shows owner A and member A and not owner B{suffix}",
        status == 200
        and accounts.emails["owner-a"] in emails_a
        and accounts.emails["member-a"] in emails_a
        and accounts.emails["owner-b"] not in emails_a,
        {"status": status, "emails": emails_a},
    )
    status, emails_b = user_emails(owner_b)
    checks.record(
        f"owner B user list shows owner B and not owner A or member A{suffix}",
        status == 200
        and accounts.emails["owner-b"] in emails_b
        and accounts.emails["owner-a"] not in emails_b
        and accounts.emails["member-a"] not in emails_b,
        {"status": status, "emails": emails_b},
    )


def check_search(checks: Checks, sessions: dict[str, OnyxSession], suffix: str) -> None:
    owner_a, owner_b, member = (sessions[role] for role in ROLES)
    for label, session in (("owner A", owner_a), ("member A", member)):
        titles = titles_of(search_docs(session, QUERY_A))
        checks.record(
            f"{label} search finds {DOC_A}{suffix}", DOC_A in titles, {"titles": titles}
        )
        titles = titles_of(search_docs(session, QUERY_B))
        checks.record(
            f"{label} search does not find {DOC_B}{suffix}",
            DOC_B not in titles,
            {"titles": titles},
        )
    titles = titles_of(search_docs(owner_b, QUERY_B))
    checks.record(
        f"owner B search finds {DOC_B}{suffix}", DOC_B in titles, {"titles": titles}
    )
    docs = search_docs(owner_b, QUERY_A)
    titles = titles_of(docs)
    checks.record(
        f"owner B search does not find {DOC_A}{suffix}",
        DOC_A not in titles and "1,500" not in json.dumps(docs),
        {"titles": titles},
    )


def check_chat(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
    suffix: str,
) -> None:
    path = f"/api/chat/get-chat-session/{state['chat_session_a']}"
    status, data = sessions["owner-a"].request("GET", path)
    checks.record(
        f"owner A reads own chat session{suffix}", status == 200, {"status": status}
    )
    for label, role in (("owner B", "owner-b"), ("member A", "member-a")):
        status, data = sessions[role].request("GET", path)
        checks.record(
            f"{label} cannot read owner A chat session{suffix}",
            access_denied(status, data),
            {"status": status, "body": data},
        )


def check_connectors(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
    suffix: str,
) -> None:
    # Ids come from per-workspace sequences, so the names identify connectors.
    name_a, name_b = state["connector_a"]["name"], state["connector_b"]["name"]
    status, names = connector_names(sessions["owner-a"])
    checks.record(
        f"owner A connector list shows own connector and not B's{suffix}",
        status == 200 and name_a in names and name_b not in names,
        {"status": status, "names": names},
    )
    status, names = connector_names(sessions["owner-b"])
    checks.record(
        f"owner B connector list shows own connector and not A's{suffix}",
        status == 200 and name_b in names and name_a not in names,
        {"status": status, "names": names},
    )


def check_personas(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
    suffix: str,
) -> None:
    persona = state["persona_a"]
    status, names = persona_names(sessions["owner-a"])
    checks.record(
        f"owner A persona list shows own persona{suffix}",
        status == 200 and persona["name"] in names,
        {"status": status, "names": names},
    )
    status, names = persona_names(sessions["owner-b"])
    checks.record(
        f"owner B persona list lacks owner A persona{suffix}",
        status == 200 and persona["name"] not in names,
        {"status": status, "names": names},
    )
    status, data = sessions["owner-b"].request("GET", f"/api/persona/{persona['id']}")
    leaked = (
        status == 200 and isinstance(data, dict) and data.get("name") == persona["name"]
    )
    checks.record(
        f"owner B cannot read owner A persona by id{suffix}",
        not leaked,
        {
            "status": status,
            "name": data.get("name") if isinstance(data, dict) else data,
        },
    )
    # v4.8.4 creates a persona with is_public=True when the request omits it.
    status, names = persona_names(sessions["member-a"])
    visible = persona["name"] in names
    checks.record(
        f"member A sees owner A persona only when it is public{suffix}",
        status == 200 and visible == bool(persona["is_public"]),
        {"status": status, "is_public": persona["is_public"], "visible": visible},
    )


def check_user_files(
    checks: Checks,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
    suffix: str,
) -> None:
    file_id = state["user_file_a"]["user_file_id"]
    project_id = state["user_file_a"]["project_id"]
    status, data = sessions["owner-a"].request(
        "GET", f"/api/user/projects/file/{file_id}"
    )
    checks.record(
        f"owner A reads own user file{suffix}", status == 200, {"status": status}
    )
    for label, role in (("owner B", "owner-b"), ("member A", "member-a")):
        session = sessions[role]
        status, data = session.request("GET", f"/api/user/projects/file/{file_id}")
        checks.record(
            f"{label} cannot read owner A user file{suffix}",
            status in (403, 404),
            {"status": status, "body": data},
        )
        status, data = session.request(
            "POST", "/api/user/projects/file/statuses", {"file_ids": [file_id]}
        )
        checks.record(
            f"{label} file status lookup hides owner A user file{suffix}",
            access_denied(status, data) or (status == 200 and data == []),
            {"status": status, "body": data},
        )
    status, data = sessions["owner-b"].request("GET", "/api/user/projects")
    names = [str(p.get("name")) for p in data] if isinstance(data, list) else []
    checks.record(
        f"owner B project list lacks owner A project{suffix}",
        status == 200 and f"MT A {state['tag']}" not in names,
        {"status": status, "names": names, "project_id_a": project_id},
    )


def check_pat(
    checks: Checks,
    base_url: str,
    sessions: dict[str, OnyxSession],
    state: dict[str, Any],
    suffix: str,
) -> None:
    """Creates a PAT for owner A, uses it, and deletes it. The token is not stored."""
    owner_a = sessions["owner-a"]
    status, created = owner_a.request(
        "POST",
        "/api/user/pats",
        {"name": f"MT PAT {state['tag']}", "expiration_days": 1},
    )
    if status == 404:
        checks.record(f"/api/user/pats exists{suffix}", False, {"status": status})
        return
    expect(status == 200, f"PAT create returned {status}: {created}")
    token = str(created["token"])
    try:
        status, data = plain_request(base_url, "GET", "/api/me", bearer=token)
        checks.record(
            f"owner A PAT gives owner A /api/me and workspace{suffix}",
            status == 200
            and isinstance(data, dict)
            and data.get("email") == owner_a.email
            and data.get("team_name") == state["tenants"]["owner-a"],
            {"status": status, **(me_summary(data) if isinstance(data, dict) else {})},
        )
        body = {
            "filters": None,
            "num_hits": 10,
            "run_query_expansion": False,
            "include_content": True,
            "stream": False,
        }
        status, own = plain_request(
            base_url,
            "POST",
            "/api/search/send-search-message",
            {**body, "search_query": QUERY_A},
            bearer=token,
        )
        own_titles = (
            titles_of(own.get("search_docs") or []) if isinstance(own, dict) else []
        )
        status_b, other = plain_request(
            base_url,
            "POST",
            "/api/search/send-search-message",
            {**body, "search_query": QUERY_B},
            bearer=token,
        )
        other_titles = (
            titles_of(other.get("search_docs") or []) if isinstance(other, dict) else []
        )
        checks.record(
            f"owner A PAT search finds {DOC_A} and not {DOC_B}{suffix}",
            status == 200
            and status_b == 200
            and DOC_A in own_titles
            and DOC_B not in other_titles,
            {
                "status": status,
                "status_b": status_b,
                "own_titles": own_titles,
                "other_titles": other_titles,
            },
        )
    finally:
        status, data = owner_a.request("DELETE", f"/api/user/pats/{created['id']}")
        log("PAT deleted", {"status": status})


def read_checks(
    checks: Checks,
    base_url: str,
    sessions: dict[str, OnyxSession],
    accounts: Accounts,
    state: dict[str, Any],
    suffix: str,
) -> None:
    check_identities(checks, sessions, state, suffix)
    check_admin_limits(checks, sessions, accounts, suffix)
    check_search(checks, sessions, suffix)
    check_chat(checks, sessions, state, suffix)
    check_connectors(checks, sessions, state, suffix)
    check_personas(checks, sessions, state, suffix)
    check_user_files(checks, sessions, state, suffix)
    check_pat(checks, base_url, sessions, state, suffix)
    check_model_chat(checks, sessions, state, suffix)


def run(
    checks: Checks,
    base_url: str,
    accounts: Accounts,
    state: dict[str, Any],
    after_restart: bool,
) -> None:
    if after_restart:
        expect(
            state.get("tag") == accounts.tag,
            f"state file is for tag {state.get('tag')!r}, not {accounts.tag!r}",
        )
        for key in (
            "tenants",
            "connector_a",
            "connector_b",
            "chat_session_a",
            "persona_a",
            "user_file_a",
        ):
            expect(
                bool(state.get(key)),
                f"state file lacks {key}; run without --after-restart first",
            )
        sessions = {
            role: OnyxSession(base_url, accounts.emails[role], accounts.password(role))
            for role in ROLES
        }
        read_checks(checks, base_url, sessions, accounts, state, " after restart")
        return
    state.clear()
    state["tag"] = accounts.tag
    state["emails"] = accounts.emails
    sessions = setup_accounts(checks, base_url, accounts, state)
    invite_from_b(checks, sessions, accounts)
    setup_data(checks, sessions, accounts, state)
    read_checks(checks, base_url, sessions, accounts, state, "")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--tag", required=True, help="short id: a-z, 0-9 and '-'")
    parser.add_argument("--state", type=Path, default=Path("mt_state.json"))
    parser.add_argument("--email-domain", default="example.com")
    parser.add_argument(
        "--after-restart",
        action="store_true",
        help="log in with the accounts of the state file and repeat the read checks",
    )
    args = parser.parse_args()
    if urllib.parse.urlparse(args.base_url).scheme not in ("http", "https"):
        parser.error(f"--base-url must use http or https: {args.base_url}")
    if not TAG_PATTERN.match(args.tag):
        parser.error("--tag must match " + TAG_PATTERN.pattern)
    salt = os.environ.get("MT_PASSWORD_SALT", "")
    if len(salt) < 8:
        parser.error("set MT_PASSWORD_SALT (8 characters or more)")
    accounts = Accounts(args.tag, args.email_domain, salt)
    state: dict[str, Any] = {}
    if args.after_restart:
        if not args.state.exists():
            parser.error(f"--after-restart needs the state file {args.state}")
        state = json.loads(args.state.read_text())
    step = "mt-after-restart" if args.after_restart else "mt"
    checks = Checks()
    stopped = f"{step} runs to the end"
    try:
        run(checks, args.base_url, accounts, state, args.after_restart)
    except SystemExit as error:
        checks.record(stopped, False, str(error.code))
    except Exception as error:
        traceback.print_exc()
        checks.record(stopped, False, repr(error))
    finally:
        if not args.after_restart:
            # Keep the ids from a failed run for --after-restart and for cleanup.
            args.state.write_text(json.dumps(state, indent=1))
    return checks.exit_code(step)


if __name__ == "__main__":
    sys.exit(main())
