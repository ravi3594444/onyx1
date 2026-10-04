"""Functional checks for the PRD test corpus against a running Onyx deployment.

Uses only the Python standard library and the public HTTP API (through nginx).
Each step prints evidence; read it against the expected evidence in README.md.

Usage:
  python3 run_checks.py --base-url http://localhost:3000 --state state.json STEP
Steps: index, search, chat, privacy, update, delete.
Credentials come from env vars ADMIN_EMAIL/ADMIN_PASSWORD, USER_A_EMAIL/
USER_A_PASSWORD (not in HR) and USER_B_EMAIL/USER_B_PASSWORD (HR stand-in).
"""

import argparse
import http.cookiejar
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

CORPUS_DIR = Path(__file__).parent / "documents"
PUBLIC_FILES = [
    "expense-policy.md",
    "whatsapp-assistant-product-guide.md",
    "refund-policy-2025.md",
    "refund-policy-2026.md",
]
RESTRICTED_FILE = "hr-salary-bands-restricted.md"
RESTRICTED_MARKER = "KESTREL-7731"
QUESTIONS = {
    "Q1": "What is the daily meal allowance for domestic business travel?",
    "Q2": "What are the support hours for WhatsApp Assistant?",
    "Q3": "How many days does a customer have to request a full refund?",
    "Q4": "What is the parental leave policy?",
    "Q5": "What is the salary band for a Senior Software Engineer at level L4?",
}
UPDATED_SUPPORT_HOURS = "Monday to Friday, 10:00 to 18:00 IST"


class OnyxSession:
    """One logged-in user, talking to the API through nginx."""

    def __init__(self, base_url: str, email: str, password: str) -> None:
        if urllib.parse.urlparse(base_url).scheme not in ("http", "https"):
            raise SystemExit(f"base URL must use http or https: {base_url}")
        self.base_url = base_url.rstrip("/")
        self.email = email
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        form = urllib.parse.urlencode({"username": email, "password": password})
        self.request(
            "POST",
            "/api/auth/login",
            raw_body=form.encode(),
            content_type="application/x-www-form-urlencoded",
        )

    def request(
        self,
        method: str,
        path: str,
        json_body: Any = None,
        raw_body: bytes | None = None,
        content_type: str = "application/json",
        timeout: float = 900,
    ) -> tuple[int, Any]:
        body = (
            raw_body
            if raw_body is not None
            else (json.dumps(json_body).encode() if json_body is not None else None)
        )
        # __init__ allows only http and https base URLs.
        request = urllib.request.Request(  # noqa: S310
            self.base_url + path,
            data=body,
            method=method,
            headers={"Content-Type": content_type} if body is not None else {},
        )
        try:
            with self.opener.open(request, timeout=timeout) as response:
                status, text = response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            status, text = error.code, error.read().decode()
        try:
            return status, json.loads(text) if text else None
        except json.JSONDecodeError:
            return status, text

    def upload(self, path: str, files: list[Path], fields: dict[str, str]) -> Any:
        boundary = uuid.uuid4().hex
        parts: list[bytes] = []
        parts.extend(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"'
            f"\r\n\r\n{value}\r\n".encode()
            for name, value in fields.items()
        )
        parts.extend(
            f'--{boundary}\r\nContent-Disposition: form-data; name="files"; '
            f'filename="{file.name}"\r\nContent-Type: text/markdown\r\n\r\n'.encode()
            + file.read_bytes()
            + b"\r\n"
            for file in files
        )
        parts.append(f"--{boundary}--\r\n".encode())
        status, data = self.request(
            "POST",
            path,
            raw_body=b"".join(parts),
            content_type=f"multipart/form-data; boundary={boundary}",
        )
        expect(status == 200, f"upload to {path} returned {status}: {data}")
        return data


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAILED: {message}")


def log(label: str, value: Any) -> None:
    print(f"{label}: {json.dumps(value, ensure_ascii=False)}", flush=True)


def wait_for_indexing(admin: OnyxSession, cc_pair_id: int, expected_docs: int) -> float:
    started = time.time()
    while time.time() - started < 900:
        _, info = admin.request("GET", f"/api/manage/admin/cc-pair/{cc_pair_id}")
        if (
            info.get("num_docs_indexed") == expected_docs
            and info.get("last_index_attempt_status") == "success"
            and not info.get("indexing")
        ):
            return time.time() - started
        time.sleep(5)
    raise SystemExit(f"FAILED: cc-pair {cc_pair_id} did not finish indexing: {info}")


def search_titles(session: OnyxSession, query: str) -> list[str]:
    status, data = session.request(
        "POST",
        "/api/search/send-search-message",
        {
            "search_query": query,
            "filters": None,
            "num_hits": 10,
            "run_query_expansion": False,
            "include_content": True,
            "stream": False,
        },
    )
    expect(status == 200, f"search returned {status}: {data}")
    return [doc["semantic_identifier"] for doc in data["search_docs"]]


def search_contents(session: OnyxSession, query: str) -> str:
    _, data = session.request(
        "POST",
        "/api/search/send-search-message",
        {
            "search_query": query,
            "filters": None,
            "num_hits": 10,
            "run_query_expansion": False,
            "include_content": True,
            "stream": False,
        },
    )
    return json.dumps(data["search_docs"])


def ask(
    session: OnyxSession, question: str, project_id: int | None = None
) -> dict[str, Any]:
    _, created = session.request(
        "POST",
        "/api/chat/create-chat-session",
        {
            "persona_id": 0,
            "description": question[:40],
            "project_id": project_id,
        },
    )
    started = time.time()
    status, data = session.request(
        "POST",
        "/api/chat/send-chat-message",
        {
            "message": question,
            "chat_session_id": created["chat_session_id"],
            "parent_message_id": -1,
            "file_descriptors": [],
            "stream": False,
            "include_citations": True,
            "origin": "api",
        },
    )
    expect(status == 200, f"chat returned {status}: {data}")
    cited_ids = {c["document_id"] for c in data.get("citation_info") or []}
    titles = {
        d["document_id"]: d["semantic_identifier"]
        for d in data.get("top_documents") or []
    }
    return {
        "chat_session_id": created["chat_session_id"],
        "seconds": round(time.time() - started, 1),
        "answer": (data.get("answer_citationless") or data.get("answer") or "").strip(),
        "cited": sorted(titles.get(doc_id, doc_id) for doc_id in cited_ids),
        "retrieved": sorted(set(titles.values())),
        "error": data.get("error_msg"),
    }


def step_index(base_url: str, state: dict[str, Any]) -> None:
    admin = OnyxSession(
        base_url, os.environ["ADMIN_EMAIL"], os.environ["ADMIN_PASSWORD"]
    )
    started = time.time()
    uploaded = admin.upload(
        "/api/manage/admin/connector/file/upload",
        [CORPUS_DIR / name for name in PUBLIC_FILES],
        {},
    )
    status, connector = admin.request(
        "POST",
        "/api/manage/admin/connector",
        {
            "name": "PRD test corpus",
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
    status, credential = admin.request(
        "POST",
        "/api/manage/credential",
        {
            "credential_json": {},
            "admin_public": True,
            "source": "file",
            "name": "PRD test corpus",
            "curator_public": False,
            "groups": [],
        },
    )
    expect(status == 200, f"credential create returned {status}: {credential}")
    status, link = admin.request(
        "PUT",
        f"/api/manage/connector/{connector['id']}/credential/{credential['id']}",
        {
            "name": "PRD test corpus",
            "access_type": "public",
            "groups": [],
            "auto_sync_options": None,
            "processing_mode": "REGULAR",
        },
    )
    expect(status == 200, f"cc-pair link returned {status}: {link}")
    state.update(
        connector_id=connector["id"],
        credential_id=credential["id"],
        cc_pair_id=link["data"],
        file_ids=dict(zip(uploaded["file_names"], uploaded["file_paths"], strict=True)),
    )
    indexing_seconds = wait_for_indexing(admin, link["data"], len(PUBLIC_FILES))
    log(
        "index",
        {
            "cc_pair_id": link["data"],
            "documents": len(PUBLIC_FILES),
            "seconds_upload_to_indexed": round(time.time() - started, 1),
            "seconds_waiting_for_indexing": round(indexing_seconds, 1),
        },
    )

    user_b = OnyxSession(
        base_url, os.environ["USER_B_EMAIL"], os.environ["USER_B_PASSWORD"]
    )
    status, project = user_b.request(
        "POST", "/api/user/projects/create?name=HR%20private"
    )
    expect(status == 200, f"project create returned {status}: {project}")
    upload = user_b.upload(
        "/api/user/projects/file/upload",
        [CORPUS_DIR / RESTRICTED_FILE],
        {"project_id": str(project["id"])},
    )
    file_ids = [file["id"] for file in upload["user_files"]]
    for _ in range(120):
        _, statuses = user_b.request(
            "POST", "/api/user/projects/file/statuses", {"file_ids": file_ids}
        )
        if all(item["status"] == "COMPLETED" for item in statuses):
            break
        time.sleep(5)
    state.update(project_id=project["id"], user_file_ids=file_ids)
    log(
        "restricted_upload",
        {
            "owner": user_b.email,
            "project_id": project["id"],
            "statuses": [item["status"] for item in statuses],
        },
    )


def step_search(base_url: str, _state: dict[str, Any]) -> None:
    user_a = OnyxSession(
        base_url, os.environ["USER_A_EMAIL"], os.environ["USER_A_PASSWORD"]
    )
    for key, question in QUESTIONS.items():
        started = time.time()
        titles = search_titles(user_a, question)
        log(
            f"search {key} as {user_a.email}",
            {"seconds": round(time.time() - started, 2), "top_titles": titles[:4]},
        )
    for session in (
        user_a,
        OnyxSession(base_url, os.environ["ADMIN_EMAIL"], os.environ["ADMIN_PASSWORD"]),
    ):
        leaked = RESTRICTED_MARKER in search_contents(
            session, f"{RESTRICTED_MARKER} salary band"
        )
        log(f"restricted marker visible to {session.email} via search", leaked)


def step_chat(base_url: str, state: dict[str, Any]) -> None:
    user_a = OnyxSession(
        base_url, os.environ["USER_A_EMAIL"], os.environ["USER_A_PASSWORD"]
    )
    user_b = OnyxSession(
        base_url, os.environ["USER_B_EMAIL"], os.environ["USER_B_PASSWORD"]
    )
    for key in ("Q1", "Q2", "Q3", "Q4", "Q5"):
        result = ask(user_a, QUESTIONS[key])
        result["marker_leaked"] = RESTRICTED_MARKER in result["answer"]
        log(f"chat {key} as {user_a.email}", result)
        state.setdefault("chat_sessions", {})[key] = result["chat_session_id"]
    result = ask(user_b, QUESTIONS["Q5"], project_id=state["project_id"])
    log(f"chat Q5 as {user_b.email} in own project", result)
    state["user_b_chat_session"] = result["chat_session_id"]


def step_privacy(base_url: str, state: dict[str, Any]) -> None:
    user_a = OnyxSession(
        base_url, os.environ["USER_A_EMAIL"], os.environ["USER_A_PASSWORD"]
    )
    status, data = user_a.request(
        "GET", f"/api/chat/get-chat-session/{state['user_b_chat_session']}"
    )
    log("user A reads user B chat session", {"status": status, "body": data})
    status, data = user_a.request("GET", "/api/user/projects")
    names = (
        [project.get("name") for project in data] if isinstance(data, list) else data
    )
    log("user A project list", {"status": status, "projects": names})
    for file_id in state["user_file_ids"]:
        status, data = user_a.request(
            "POST", "/api/user/projects/file/statuses", {"file_ids": [file_id]}
        )
        log("user A reads user B file status", {"status": status, "body": data})


def step_update(base_url: str, state: dict[str, Any]) -> None:
    admin = OnyxSession(
        base_url, os.environ["ADMIN_EMAIL"], os.environ["ADMIN_PASSWORD"]
    )
    guide_name = "whatsapp-assistant-product-guide.md"
    updated = (
        (CORPUS_DIR / guide_name)
        .read_text()
        .replace("Monday to Saturday, 09:00 to 19:00 IST", UPDATED_SUPPORT_HOURS)
        .replace("Guide version: 2.3.", "Guide version: 2.4.")
    )
    temp_file = Path(tempfile.mkdtemp()) / guide_name
    temp_file.write_text(updated)
    started = time.time()
    admin.upload(
        f"/api/manage/admin/connector/{state['connector_id']}/files/update",
        [temp_file],
        {"file_ids_to_remove": json.dumps([state["file_ids"][guide_name]])},
    )
    wait_for_indexing(admin, state["cc_pair_id"], len(PUBLIC_FILES))
    log("update applied", {"seconds": round(time.time() - started, 1)})
    log(
        "search after update",
        search_contents(admin, QUESTIONS["Q2"]).count(UPDATED_SUPPORT_HOURS) > 0,
    )
    log("chat Q2 after update", ask(admin, QUESTIONS["Q2"]))


def step_delete(base_url: str, state: dict[str, Any]) -> None:
    admin = OnyxSession(
        base_url, os.environ["ADMIN_EMAIL"], os.environ["ADMIN_PASSWORD"]
    )
    started = time.time()
    old_name = "refund-policy-2025.md"
    admin.upload(
        f"/api/manage/admin/connector/{state['connector_id']}/files/update",
        [],
        {"file_ids_to_remove": json.dumps([state["file_ids"][old_name]])},
    )
    while time.time() - started < 900:
        if old_name not in search_titles(
            admin, "refund within 14 days of purchase 2025 edition"
        ):
            break
        time.sleep(5)
    log(
        "deletion propagated",
        {
            "seconds": round(time.time() - started, 1),
            "titles": search_titles(admin, "refund policy 2025 edition 14 days"),
        },
    )
    log("chat Q3 after deletion", ask(admin, QUESTIONS["Q3"]))


STEPS = {
    "index": step_index,
    "search": step_search,
    "chat": step_chat,
    "privacy": step_privacy,
    "update": step_update,
    "delete": step_delete,
}


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", default="http://localhost:3000")
    parser.add_argument("--state", type=Path, default=Path("checks-state.json"))
    parser.add_argument("step", choices=list(STEPS))
    args = parser.parse_args()
    state: dict[str, Any] = (
        json.loads(args.state.read_text()) if args.state.exists() else {}
    )
    STEPS[args.step](args.base_url, state)
    args.state.write_text(json.dumps(state, indent=1))


if __name__ == "__main__":
    sys.exit(main())
