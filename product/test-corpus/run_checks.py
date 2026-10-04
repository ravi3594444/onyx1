"""Functional checks for the PRD test corpus against a running Onyx deployment.

Uses only the Python standard library and the public HTTP API (through nginx).
Each step compares its results with the expected evidence in README.md, prints
one PASS, FAIL or SKIP line for each check, and exits with 1 if any check failed.

Usage:
  python3 run_checks.py --base-url http://localhost:3000 --state state.json STEP
Steps: index, search, chat, chat-forced, privacy, update, delete.
Credentials come from env vars ADMIN_EMAIL/ADMIN_PASSWORD, USER_A_EMAIL/
USER_A_PASSWORD (not in HR) and USER_B_EMAIL/USER_B_PASSWORD (HR stand-in).
"""

import argparse
import http.cookiejar
import json
import os
import re
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

CORPUS_DIR = Path(__file__).parent / "documents"
GUIDE_FILE = "whatsapp-assistant-product-guide.md"
OLD_REFUND_FILE = "refund-policy-2025.md"
NEW_REFUND_FILE = "refund-policy-2026.md"
PUBLIC_FILES = [
    "expense-policy.md",
    GUIDE_FILE,
    OLD_REFUND_FILE,
    NEW_REFUND_FILE,
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
SUPPORT_HOURS = "Monday to Saturday, 09:00 to 19:00 IST"
UPDATED_SUPPORT_HOURS = "Monday to Friday, 10:00 to 18:00 IST"
WAIT_SECONDS = 900
INDEX_FAILED_STATUSES = ("failed", "canceled", "completed_with_errors")
FILE_END_STATUSES = ("COMPLETED", "SKIPPED", "FAILED", "CANCELED")
# Q4: an answer that says that the documents do not hold the information.
# Matched after normalise(), so "n't" covers "don't", "couldn't" and "wasn't".
NO_INFO_PHRASES = (
    "no information",
    "no relevant",
    "no document",
    "no mention",
    "no parental leave",
    "nothing about",
    "none of the",
    "not find",
    "n't find",
    "cannot find",
    "unable to find",
    "not able to find",
    "n't able to find",
    "not found",
    "not locate",
    "n't locate",
    "cannot locate",
    "not see any",
    "n't see any",
    "not contain",
    "n't contain",
    "not include",
    "n't include",
    "not cover",
    "n't cover",
    "not mention",
    "n't mention",
    "not have information",
    "n't have information",
    "not have any information",
    "n't have any information",
    "not in the document",
    "n't in the document",
    "not in the provided",
    "not in the available",
    "not in the knowledge base",
    "not available in",
)
# Q4: a leave length shows an invented policy. No document states one.
LEAVE_LENGTH = r"\b\d+ ?-? ?(?:weeks?|months?)\b"
# Q3: an answer that marks the 14-day rule as part of the replaced edition.
REPLACED_PHRASES = (
    "replaced",
    "replaces",
    "supersed",
    "previous",
    "prior",
    "older",
    "earlier",
    "former",
    "outdated",
    "no longer",
    "changed from",
    "extended from",
    "increased from",
)
OLD_REFUND_FACTS = ("14 day", "14-day", "fourteen day", "fourteen-day")


@dataclass(frozen=True)
class Expected:
    """What a chat answer must and must not contain (see README.md)."""

    cite: str | None = None
    facts: tuple[str, ...] = ()
    uncited: bool = False
    # The answer states one of NO_INFO_PHRASES.
    says_no_info: bool = False
    # The answer comes from a search that returned public documents.
    retrieves_public: bool = False
    # Facts of a replaced edition. The answer states them only with REPLACED_PHRASES.
    old_facts: tuple[str, ...] = ()
    forbidden_sources: tuple[str, ...] = (RESTRICTED_FILE,)
    forbidden_text: tuple[str, ...] = (RESTRICTED_MARKER,)
    # Regular expressions that the normalised answer must not match.
    forbidden_patterns: tuple[str, ...] = ()


# Expected answers for users without access to the restricted file.
ANSWERS = {
    "Q1": Expected(cite="expense-policy.md", facts=("1,500",)),
    "Q2": Expected(cite=GUIDE_FILE, facts=("monday", "saturday", "09:00 to 19:00")),
    "Q3": Expected(
        cite=NEW_REFUND_FILE, facts=("30 days",), old_facts=OLD_REFUND_FACTS
    ),
    "Q4": Expected(uncited=True, says_no_info=True, forbidden_patterns=(LEAVE_LENGTH,)),
    "Q5": Expected(
        retrieves_public=True, forbidden_text=(RESTRICTED_MARKER, "38 to 46")
    ),
}
HR_Q5_ANSWER = Expected(
    cite=RESTRICTED_FILE, facts=("38 to 46",), forbidden_sources=(), forbidden_text=()
)
UPDATED_Q2_ANSWER = Expected(
    cite=GUIDE_FILE,
    facts=("monday", "friday", "10:00 to 18:00"),
    forbidden_text=(RESTRICTED_MARKER, "19:00"),
)
DELETED_Q3_ANSWER = Expected(
    cite=NEW_REFUND_FILE,
    facts=("30 days",),
    old_facts=OLD_REFUND_FACTS,
    forbidden_sources=(RESTRICTED_FILE, OLD_REFUND_FILE),
)


class Checks:
    """Records the check results of one step."""

    def __init__(self) -> None:
        self.passed: list[str] = []
        self.failed: list[str] = []
        self.skipped: list[str] = []

    def record(self, name: str, passed: bool, detail: Any = None) -> None:
        (self.passed if passed else self.failed).append(name)
        result = "PASS" if passed else "FAIL"
        print(f"{result} {name}: {json.dumps(detail, ensure_ascii=False)}", flush=True)

    def skip(self, name: str, reason: str) -> None:
        """Records a check that did not run. A skip does not fail the step."""
        self.skipped.append(name)
        print(f"SKIP {name}: {json.dumps(reason, ensure_ascii=False)}", flush=True)

    def exit_code(self, step: str) -> int:
        """Prints the step result. Returns 1 if a check failed or none ran."""
        total = len(self.passed) + len(self.failed)
        skipped = f", {len(self.skipped)} skipped" if self.skipped else ""
        if self.failed or not total:
            failed = json.dumps(self.failed, ensure_ascii=False)
            print(
                f"FAIL step {step}: {len(self.failed)} of {total} checks failed"
                f"{skipped}: {failed}"
            )
            return 1
        print(f"PASS step {step}: {total} checks passed{skipped}")
        return 0


def expect(condition: bool, message: str) -> None:
    """Stops the step with exit code 1 when a precondition is not met."""
    if not condition:
        raise SystemExit(message)


def require_state(state: dict[str, Any], *keys: str) -> None:
    missing = [key for key in keys if not state.get(key)]
    expect(not missing, f"state file lacks {missing}; run the earlier steps first")


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
        status, data = self.request(
            "POST",
            "/api/auth/login",
            raw_body=form.encode(),
            content_type="application/x-www-form-urlencoded",
        )
        expect(status in (200, 204), f"login as {email} returned {status}: {data}")
        # A dropped session cookie gives 403 on later calls, like a denied access.
        status, data = self.request("GET", "/api/me")
        expect(
            status == 200
            and isinstance(data, dict)
            and str(data.get("email", "")).lower() == email.lower(),
            f"/api/me after login as {email} returned {status}: {data}",
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

    def stream_lines(self, path: str, json_body: Any) -> list[dict[str, Any]]:
        """Posts JSON and returns the NDJSON packets of a streamed response."""
        # __init__ allows only http and https base URLs.
        request = urllib.request.Request(  # noqa: S310
            self.base_url + path,
            data=json.dumps(json_body).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with self.opener.open(request, timeout=900) as response:
                return [json.loads(line) for line in response if line.strip()]
        except urllib.error.HTTPError as error:
            raise SystemExit(
                f"{path} returned {error.code}: {error.read().decode()}"
            ) from None

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


def login(base_url: str, role: str) -> OnyxSession:
    """Logs in with the {role}_EMAIL and {role}_PASSWORD env vars."""
    email, password = (os.environ.get(f"{role}_{key}") for key in ("EMAIL", "PASSWORD"))
    expect(bool(email and password), f"set {role}_EMAIL and {role}_PASSWORD")
    return OnyxSession(base_url, str(email), str(password))


def log(label: str, value: Any) -> None:
    print(f"{label}: {json.dumps(value, ensure_ascii=False)}", flush=True)


def normalise(text: str) -> str:
    """Lower-cases text, collapses whitespace and writes "38-46" as "38 to 46".

    It also writes a curly apostrophe as a straight one.
    """
    text = text.lower().replace("\u2019", "'").replace("\u2018", "'")
    text = " ".join(text.split())
    return re.sub(r"(?<=\d) ?[-\u2013\u2014] ?(?=\d)", " to ", text)


def poll(
    read: Callable[[], Any], done: Callable[[Any], bool]
) -> tuple[Any, float | None]:
    """Calls read() every 5 s until done() accepts its value.

    Returns the last value and the seconds waited, or None after WAIT_SECONDS.
    """
    started = time.time()
    while True:
        value = read()
        seconds = time.time() - started
        if done(value):
            return value, round(seconds, 1)
        if seconds >= WAIT_SECONDS:
            return value, None
        time.sleep(5)


def last_pruned(admin: OnyxSession, cc_pair_id: int) -> str | None:
    status, value = admin.request(
        "GET", f"/api/manage/admin/cc-pair/{cc_pair_id}/last_pruned"
    )
    expect(status == 200, f"last_pruned returned {status}: {value}")
    return value if isinstance(value, str) else None


def wait_for_prune(
    checks: Checks, admin: OnyxSession, cc_pair_id: int, before: str | None, name: str
) -> None:
    """Waits until a prune newer than `before` finished.

    Onyx v4.8.4 starts no prune for removed files while another prune of the same
    cc-pair runs, and still answers 200. A removed file then stays searchable until
    the next scheduled prune. So a later removal must wait for the earlier prune.
    """
    value, seconds = poll(
        lambda: last_pruned(admin, cc_pair_id),
        lambda found: found is not None and found != before,
    )
    checks.record(
        name,
        seconds is not None,
        {
            "seconds": seconds,
            "timeout_seconds": WAIT_SECONDS,
            "before": before,
            "last_pruned": value,
        },
    )


def latest_attempt(admin: OnyxSession, cc_pair_id: int) -> tuple[int, str | None]:
    """Returns the id and the status of the newest index attempt (0 if none)."""
    status, page = admin.request(
        "GET",
        f"/api/manage/admin/cc-pair/{cc_pair_id}/index-attempts?page_num=0&page_size=1",
    )
    expect(status == 200, f"index attempts returned {status}: {page}")
    items = page.get("items") or []
    return (int(items[0]["id"]), items[0].get("status")) if items else (0, None)


def wait_for_indexing(
    checks: Checks,
    admin: OnyxSession,
    cc_pair_id: int,
    expected_docs: int,
    after_attempt_id: int = 0,
) -> float | None:
    """Checks that an index attempt newer than after_attempt_id succeeds."""

    def read() -> dict[str, Any]:
        # Id and status come from one item. The cc-pair read comes after it.
        attempt_id, attempt_status = latest_attempt(admin, cc_pair_id)
        status, info = admin.request("GET", f"/api/manage/admin/cc-pair/{cc_pair_id}")
        expect(status == 200, f"cc-pair {cc_pair_id} returned {status}: {info}")
        return {
            "attempt_id": attempt_id,
            "status": attempt_status,
            "indexing": info.get("indexing"),
            "num_docs_indexed": info.get("num_docs_indexed"),
        }

    def ended(progress: dict[str, Any]) -> bool:
        return progress["attempt_id"] > after_attempt_id and not progress["indexing"]

    def indexed(progress: dict[str, Any]) -> bool:
        return (
            ended(progress)
            and progress["status"] == "success"
            and progress["num_docs_indexed"] == expected_docs
        )

    progress, seconds = poll(
        read,
        lambda p: indexed(p) or (ended(p) and p["status"] in INDEX_FAILED_STATUSES),
    )
    checks.record(
        f"new index attempt on cc-pair {cc_pair_id} indexes {expected_docs} documents",
        indexed(progress),
        {"seconds": seconds, "timeout_seconds": WAIT_SECONDS, **progress},
    )
    return seconds


def search_docs(session: OnyxSession, query: str) -> list[dict[str, Any]]:
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
    expect(not data.get("error"), f"search returned an error: {data.get('error')}")
    docs: list[dict[str, Any]] = data["search_docs"]
    return docs


def search_titles(session: OnyxSession, query: str) -> list[str]:
    return [doc["semantic_identifier"] for doc in search_docs(session, query)]


def search_contents(session: OnyxSession, query: str) -> str:
    return json.dumps(search_docs(session, query))


def request_chat_session(
    session: OnyxSession, description: str, project_id: int | None = None
) -> tuple[int, Any]:
    return session.request(
        "POST",
        "/api/chat/create-chat-session",
        {"persona_id": 0, "description": description, "project_id": project_id},
    )


def create_chat_session(
    session: OnyxSession, description: str, project_id: int | None = None
) -> str:
    status, created = request_chat_session(session, description, project_id)
    expect(status == 200, f"create-chat-session returned {status}: {created}")
    return str(created["chat_session_id"])


def access_denied(status: int, body: Any) -> bool:
    """True for a 403 "Access denied" or a 404 "not found" error body.

    A 403 for a missing permission (for example READ_CHAT) has another detail.
    """
    detail = str(body.get("detail", "")).lower() if isinstance(body, dict) else ""
    return (status == 403 and "access denied" in detail) or (
        status == 404 and "not found" in detail
    )


def ask(
    session: OnyxSession,
    question: str,
    project_id: int | None = None,
    forced_tool_id: int | None = None,
) -> dict[str, Any]:
    """Sends one chat message with streaming, as the web UI does.

    Streaming keeps the nginx connection alive while a slow model works.
    """
    chat_session_id = create_chat_session(session, question[:40], project_id)
    started = time.time()
    packets = session.stream_lines(
        "/api/chat/send-chat-message",
        {
            "message": question,
            "chat_session_id": chat_session_id,
            "parent_message_id": -1,
            "file_descriptors": [],
            "forced_tool_id": forced_tool_id,
            "stream": True,
            "include_citations": True,
            "origin": "api",
        },
    )
    answer_parts: list[str] = []
    cited_ids: set[str] = set()
    titles: dict[str, str] = {}
    errors: list[str] = []
    for packet in packets:
        obj = packet.get("obj") or {}
        packet_type = obj.get("type")
        # A failed tool streams {"obj": {"type": "error"}} and the model still answers.
        if "error" in packet or packet_type == "error":
            errors.append(str(packet.get("error") or obj))
        if packet_type == "message_delta":
            answer_parts.append(obj.get("content") or "")
        elif packet_type == "citation_info":
            cited_ids.add(obj["document_id"])
        for doc in obj.get("documents") or obj.get("final_documents") or []:
            titles[doc["document_id"]] = doc["semantic_identifier"]
    return {
        "chat_session_id": chat_session_id,
        "seconds": round(time.time() - started, 1),
        "answer": "".join(answer_parts).strip(),
        "cited": sorted(titles.get(doc_id, doc_id) for doc_id in cited_ids),
        "retrieved": sorted(set(titles.values())),
        "error": errors or None,
    }


def check_answer(
    checks: Checks, name: str, result: dict[str, Any], expected: Expected
) -> None:
    answer = normalise(result["answer"])
    sources = result["cited"] + result["retrieved"]
    problems = [
        f"does not state {fact!r}"
        for fact in expected.facts
        if normalise(fact) not in answer
    ]
    problems += [
        f"states {text!r}"
        for text in expected.forbidden_text
        if normalise(text) in answer
    ]
    problems += [
        f"states {match.group()!r}"
        for pattern in expected.forbidden_patterns
        if (match := re.search(pattern, answer))
    ]
    problems += [
        f"retrieves or cites {source}"
        for source in expected.forbidden_sources
        if source in sources
    ]
    if expected.cite and expected.cite not in result["cited"]:
        problems.append(f"does not cite {expected.cite}")
    if expected.uncited and result["cited"]:
        problems.append("cites documents")
    if expected.says_no_info and not any(
        normalise(phrase) in answer for phrase in NO_INFO_PHRASES
    ):
        problems.append("does not say that the documents lack the information")
    if expected.retrieves_public and not set(result["retrieved"]) & set(PUBLIC_FILES):
        problems.append("retrieves no public document")
    old_facts = [fact for fact in expected.old_facts if normalise(fact) in answer]
    if old_facts and not any(normalise(p) in answer for p in REPLACED_PHRASES):
        problems.append(f"states {old_facts[0]!r} but not that its edition is replaced")
    if result["error"] or not answer:
        problems.append("no answer")
    checks.record(name, not problems, {"problems": problems, **result})


def step_index(base_url: str, state: dict[str, Any], checks: Checks) -> None:
    admin = login(base_url, "ADMIN")
    started = time.time()
    uploaded = admin.upload(
        "/api/manage/admin/connector/file/upload",
        [CORPUS_DIR / name for name in PUBLIC_FILES],
        {},
    )
    # Save each id when it exists, so that a failed step leaves no unknown ids.
    state["file_ids"] = dict(
        zip(uploaded["file_names"], uploaded["file_paths"], strict=True)
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
    state["connector_id"] = connector["id"]
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
    state["credential_id"] = credential["id"]
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
    state["cc_pair_id"] = link["data"]
    indexing_seconds = wait_for_indexing(checks, admin, link["data"], len(PUBLIC_FILES))
    log(
        "index",
        {
            "cc_pair_id": link["data"],
            "documents": len(PUBLIC_FILES),
            "seconds_upload_to_indexed": round(time.time() - started, 1),
            "seconds_waiting_for_indexing": indexing_seconds,
        },
    )

    user_b = login(base_url, "USER_B")
    status, project = user_b.request(
        "POST", "/api/user/projects/create?name=HR%20private"
    )
    expect(status == 200, f"project create returned {status}: {project}")
    state["project_id"] = project["id"]
    upload = user_b.upload(
        "/api/user/projects/file/upload",
        [CORPUS_DIR / RESTRICTED_FILE],
        {"project_id": str(project["id"])},
    )
    file_ids = [file["id"] for file in upload["user_files"]]
    state["user_file_ids"] = file_ids
    expect(len(file_ids) == 1, f"project file upload returned {upload}")

    def read_statuses() -> list[str]:
        status, data = user_b.request(
            "POST", "/api/user/projects/file/statuses", {"file_ids": file_ids}
        )
        expect(status == 200, f"file statuses returned {status}: {data}")
        return [item["status"] for item in data]

    statuses, seconds = poll(
        read_statuses, lambda found: all(s in FILE_END_STATUSES for s in found)
    )
    checks.record(
        f"{RESTRICTED_FILE} in user B project reaches COMPLETED",
        statuses == ["COMPLETED"],
        {
            "owner": user_b.email,
            "project_id": project["id"],
            "statuses": statuses,
            "seconds": seconds,
        },
    )


def step_search(base_url: str, _state: dict[str, Any], checks: Checks) -> None:
    user_a = login(base_url, "USER_A")
    for key, question in QUESTIONS.items():
        started = time.time()
        titles = search_titles(user_a, question)
        top = ANSWERS[key].cite
        checks.record(
            f"search {key} as {user_a.email}",
            bool(titles)
            and (top is None or titles[:1] == [top])
            and RESTRICTED_FILE not in titles,
            {
                "expected_top": top,
                "seconds": round(time.time() - started, 2),
                "top_titles": titles[:4],
            },
        )
    marker_query = f"{RESTRICTED_MARKER} salary band"
    # Control: the owner finds the file, so its absence for others is evidence.
    user_b = login(base_url, "USER_B")
    docs = search_docs(user_b, marker_query)
    titles = [doc["semantic_identifier"] for doc in docs]
    marker_found = RESTRICTED_MARKER in json.dumps(docs)
    checks.record(
        f"search shows {RESTRICTED_FILE} to its owner {user_b.email}",
        RESTRICTED_FILE in titles or marker_found,
        {"marker_found": marker_found, "titles": titles},
    )
    for session in (user_a, login(base_url, "ADMIN")):
        docs = search_docs(session, marker_query)
        titles = [doc["semantic_identifier"] for doc in docs]
        # Public results show that the search ran and returned documents.
        public_found = any(title in PUBLIC_FILES for title in titles)
        checks.record(
            f"search hides {RESTRICTED_MARKER} from {session.email}",
            public_found
            and RESTRICTED_MARKER not in json.dumps(docs)
            and RESTRICTED_FILE not in titles,
            {"public_found": public_found, "titles": titles},
        )


def step_chat(base_url: str, state: dict[str, Any], checks: Checks) -> None:
    require_state(state, "project_id")
    user_a = login(base_url, "USER_A")
    user_b = login(base_url, "USER_B")
    for key, expected in ANSWERS.items():
        result = ask(user_a, QUESTIONS[key])
        state.setdefault("chat_sessions", {})[key] = result["chat_session_id"]
        check_answer(checks, f"chat {key} as {user_a.email}", result, expected)
    result = ask(user_b, QUESTIONS["Q5"], project_id=state["project_id"])
    state["user_b_chat_session"] = result["chat_session_id"]
    check_answer(
        checks, f"chat Q5 as {user_b.email} in own project", result, HR_Q5_ANSWER
    )


def step_privacy(base_url: str, state: dict[str, Any], checks: Checks) -> None:
    require_state(state, "project_id", "user_file_ids")
    user_b = login(base_url, "USER_B")
    if "user_b_chat_session" not in state:
        # Without the chat step (no model), test an empty session of user B.
        state["user_b_chat_session"] = create_chat_session(user_b, "privacy check")
    session_path = f"/api/chat/get-chat-session/{state['user_b_chat_session']}"
    file_ids = state["user_file_ids"]
    # Controls: user B can use the ids, so a denial for user A is evidence.
    status, data = user_b.request("GET", session_path)
    checks.record("user B can read own chat session", status == 200, {"status": status})
    status, data = user_b.request("GET", "/api/user/projects")
    checks.record(
        "user B project list shows own project",
        status == 200
        and isinstance(data, list)
        and state["project_id"] in [project.get("id") for project in data],
        {"status": status, "body": data},
    )
    status, data = user_b.request(
        "POST", "/api/user/projects/file/statuses", {"file_ids": file_ids}
    )
    checks.record(
        "user B file status lookup returns own files",
        status == 200
        and isinstance(data, list)
        and sorted(str(item.get("id")) for item in data)
        == sorted(str(file_id) for file_id in file_ids),
        {"status": status, "body": data},
    )

    user_a = login(base_url, "USER_A")
    # Control: user A can read chat sessions, so a denial is about the owner.
    # A failed create is a failed check, so the checks below still run.
    status, data = request_chat_session(user_a, "privacy check")
    created = status == 200 and isinstance(data, dict)
    own_session = data.get("chat_session_id") if created else None
    detail: dict[str, Any] = {"create_status": status, "body": data}
    readable = False
    if own_session:
        status, data = user_a.request(
            "GET", f"/api/chat/get-chat-session/{own_session}"
        )
        readable = status == 200
        detail = {"status": status} if readable else {"status": status, "body": data}
    checks.record("user A can read own chat session", readable, detail)
    status, data = user_a.request("GET", session_path)
    checks.record(
        "user A cannot read user B chat session",
        access_denied(status, data),
        {"status": status, "body": data},
    )
    status, data = user_a.request("GET", "/api/user/projects")
    projects = data if status == 200 and isinstance(data, list) else None
    checks.record(
        "user A project list hides user B project",
        projects is not None
        and state["project_id"] not in [project.get("id") for project in projects],
        {"status": status, "body": data},
    )
    for file_id in file_ids:
        status, data = user_a.request(
            "POST", "/api/user/projects/file/statuses", {"file_ids": [file_id]}
        )
        checks.record(
            f"user A file status lookup hides user B file {file_id}",
            access_denied(status, data) or (status == 200 and data == []),
            {"status": status, "body": data},
        )


def step_update(base_url: str, state: dict[str, Any], checks: Checks) -> None:
    require_state(state, "cc_pair_id", "connector_id", "file_ids")
    admin = login(base_url, "ADMIN")
    updated = (
        (CORPUS_DIR / GUIDE_FILE)
        .read_text()
        .replace(SUPPORT_HOURS, UPDATED_SUPPORT_HOURS)
        .replace("Guide version: 2.3.", "Guide version: 2.4.")
    )
    expect(UPDATED_SUPPORT_HOURS in updated, f"{GUIDE_FILE} lacks '{SUPPORT_HOURS}'")
    temp_file = Path(tempfile.mkdtemp()) / GUIDE_FILE
    temp_file.write_text(updated)
    previous_attempt_id, _ = latest_attempt(admin, state["cc_pair_id"])
    pruned_before = last_pruned(admin, state["cc_pair_id"])
    started = time.time()
    admin.upload(
        f"/api/manage/admin/connector/{state['connector_id']}/files/update",
        [temp_file],
        {"file_ids_to_remove": json.dumps([state["file_ids"][GUIDE_FILE]])},
    )
    wait_for_indexing(
        checks, admin, state["cc_pair_id"], len(PUBLIC_FILES), previous_attempt_id
    )
    wait_for_prune(
        checks,
        admin,
        state["cc_pair_id"],
        pruned_before,
        "prune after the update removes the old version",
    )
    log("update applied", {"seconds": round(time.time() - started, 1)})
    contents = search_contents(admin, QUESTIONS["Q2"])
    checks.record(
        "search shows the new support hours and not the old ones",
        UPDATED_SUPPORT_HOURS in contents and SUPPORT_HOURS not in contents,
        {
            "new_hours_found": UPDATED_SUPPORT_HOURS in contents,
            "old_hours_found": SUPPORT_HOURS in contents,
        },
    )
    if SKIP_CHAT:
        checks.skip("chat Q2 after update", "--skip-chat: no model answer")
        return
    check_answer(
        checks, "chat Q2 after update", ask(admin, QUESTIONS["Q2"]), UPDATED_Q2_ANSWER
    )


def step_delete(base_url: str, state: dict[str, Any], checks: Checks) -> None:
    require_state(state, "connector_id", "file_ids")
    admin = login(base_url, "ADMIN")
    query = "refund within 14 days of purchase 2025 edition"
    titles = search_titles(admin, query)
    checks.record(
        f"search finds {OLD_REFUND_FILE} before deletion",
        OLD_REFUND_FILE in titles,
        {"titles": titles},
    )
    admin.upload(
        f"/api/manage/admin/connector/{state['connector_id']}/files/update",
        [],
        {"file_ids_to_remove": json.dumps([state["file_ids"][OLD_REFUND_FILE]])},
    )

    def deleted(found: list[str]) -> bool:
        # The 2026 edition shows that the search returned the refund documents.
        return NEW_REFUND_FILE in found and OLD_REFUND_FILE not in found

    titles, seconds = poll(lambda: search_titles(admin, query), deleted)
    checks.record(
        f"deletion of {OLD_REFUND_FILE} reaches search",
        seconds is not None,
        {"seconds": seconds, "timeout_seconds": WAIT_SECONDS, "titles": titles},
    )
    titles = search_titles(admin, "refund policy 2025 edition 14 days")
    checks.record(
        f"search hides {OLD_REFUND_FILE} and shows {NEW_REFUND_FILE}",
        deleted(titles),
        {"titles": titles},
    )
    if SKIP_CHAT:
        checks.skip("chat Q3 after deletion", "--skip-chat: no model answer")
        return
    check_answer(
        checks,
        "chat Q3 after deletion",
        ask(admin, QUESTIONS["Q3"]),
        DELETED_Q3_ANSWER,
    )


def search_tool_id(session: OnyxSession) -> int:
    status, tools = session.request("GET", "/api/tool")
    expect(status == 200, f"tool list returned {status}: {tools}")
    ids = [t["id"] for t in tools if t.get("in_code_tool_id") == "SearchTool"]
    expect(bool(ids), "tool list has no SearchTool")
    return int(ids[0])


def step_chat_forced(base_url: str, _state: dict[str, Any], checks: Checks) -> None:
    """Repeats Q1-Q5 with the Search tool forced, to separate retrieval from tool choice."""
    user_a = login(base_url, "USER_A")
    tool_id = search_tool_id(user_a)
    for key, expected in ANSWERS.items():
        check_answer(
            checks,
            f"chat {key} as {user_a.email} with search forced",
            ask(user_a, QUESTIONS[key], forced_tool_id=tool_id),
            expected,
        )


SKIP_CHAT = False

STEPS: dict[str, Callable[[str, dict[str, Any], Checks], None]] = {
    "index": step_index,
    "search": step_search,
    "chat": step_chat,
    "chat-forced": step_chat_forced,
    "privacy": step_privacy,
    "update": step_update,
    "delete": step_delete,
}


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", default="http://localhost:3000")
    parser.add_argument("--state", type=Path, default=Path("checks-state.json"))
    parser.add_argument(
        "--skip-chat",
        action="store_true",
        help="skip the model answers in update and delete (no model provider); "
        "each one prints a SKIP line",
    )
    parser.add_argument("step", choices=list(STEPS))
    args = parser.parse_args()
    global SKIP_CHAT  # noqa: PLW0603
    SKIP_CHAT = args.skip_chat
    expect(
        not (SKIP_CHAT and args.step in ("chat", "chat-forced")),
        f"--skip-chat cannot run the {args.step} step",
    )
    state: dict[str, Any] = (
        json.loads(args.state.read_text()) if args.state.exists() else {}
    )
    checks = Checks()
    stopped = f"{args.step} runs to the end"
    try:
        STEPS[args.step](args.base_url, state, checks)
    except SystemExit as error:
        checks.record(stopped, False, str(error.code))
    except Exception as error:
        traceback.print_exc()
        checks.record(stopped, False, repr(error))
    finally:
        # Keep the ids from a failed step for the later steps and for cleanup.
        args.state.write_text(json.dumps(state, indent=1))
    return checks.exit_code(args.step)


if __name__ == "__main__":
    sys.exit(main())
