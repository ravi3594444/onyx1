"""Acceptance test for Code Interpreter and Web Search on the multi-tenant stack (onyx-saas).

Uses only the Python standard library and the public HTTP API (through nginx).
Prints one PASS, FAIL, SKIP or INFO line for each step and exits with 0 only if all
checks pass. INFO lines are evidence, not checks.

Usage:
  MT_PASSWORD_SALT=... python3 tools_check.py --base-url URL \\
      --state journey_state.json --tag TAG [--email-domain example.com] \\
      [--record tools_state.json]

--state is the state file of saas_journey.py: it names owner A, member A and owner B.
--tag is a new tag: the test signs up owner C (owner-c-<tag>@<domain>) as a new company.
The test configures no provider and no prompt. It only switches company C's Code
Interpreter and web search provider off and on again (step g) and records both states.

Steps:
  a. Owner C signs up. Owners A, B and C see the Code Interpreter enabled and connected,
     the tools PythonTool, WebSearchTool and OpenURLTool, one active web search provider
     "22nd X AI web search" without a visible key, and no active content provider.
  b. Member A attaches a generated CSV and gets its total and mean from the Python tool.
  c. Member A gets chart.png and result.csv. Member A downloads them; owner B cannot.
  d. Owner B and owner C get a cited web answer. The test fetches the cited links.
  e. Company B sees no trace of the CSV. Company A cannot download a file of company C.
  f. Sandbox probes in company C: uid, Docker socket, secret names, network, a timeout.
  g. Company C switches both tools off, the test records the state, then restores them.

Passwords come from HMAC-SHA256(MT_PASSWORD_SALT, tag + role), as in mt_checks.py.
"""

import argparse
import datetime
import json
import os
import re
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from decimal import ROUND_HALF_EVEN, ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import Any

from mt_checks import (
    TAG_PATTERN,
    is_admin,
    me,
    me_summary,
    password_for,
    plain_request,
)
from run_checks import (
    FILE_END_STATUSES,
    Checks,
    OnyxSession,
    access_denied,
    create_chat_session,
    expect,
    poll,
    search_docs,
)

PROVIDER_NAME = "22nd X AI web search"
REQUIRED_TOOLS = ("PythonTool", "WebSearchTool", "OpenURLTool")
# The executor user of the Code Interpreter sandbox (see MULTI-TENANT.md, section 8).
EXPECTED_UID = 65532
TIMEOUT_WALL_SECONDS = 90
LINK_TIMEOUT_SECONDS = 15
USER_AGENT = "Mozilla/5.0 (compatible; 22nd-X-AI-tools-check/1.0)"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
PROBE_MARKER = "AXI_PROBE="
# 12 amounts: total 4321.50, mean 360.125. build_csv computes both.
CSV_AMOUNTS = (
    "120.50",
    "340.00",
    "275.25",
    "410.75",
    "99.00",
    "500.00",
    "310.10",
    "450.40",
    "215.00",
    "380.50",
    "600.00",
    "620.00",
)
CSV_REGIONS = ("North", "South", "East", "West")
# Packets of one Python tool run. The run ends with the first other packet.
PYTHON_PACKETS = {
    "python_tool_start",
    "python_tool_delta",
    "tool_call_argument_delta",
    "chat_heartbeat",
}

CSV_QUESTION = (
    "Using the attached CSV, compute the total and the mean of the amount column "
    "with Python. Reply with both numbers."
)
CHART_QUESTION = (
    "Create a bar chart of amount per region from the attached CSV, save it as "
    "chart.png, and also write result.csv with the per-region totals; then describe "
    "the chart."
)
WEB_QUESTION = (
    "What is the current population of Iceland according to Wikipedia? "
    "Cite your sources."
)
TINY_FILE_QUESTION = (
    "Use Python to write a file named hello.txt that contains the single line "
    "'hello from company C', and tell me its name."
)
PROBE_CODE = """import json, os, socket
info = {
    "uid": os.getuid(),
    "docker_sock": os.path.exists("/var/run/docker.sock"),
    "secret_env_names": sorted(
        k for k in os.environ
        if any(p in k for p in ("POSTGRES", "S3_", "FIREWORKS", "SMTP"))
    ),
}
try:
    socket.create_connection(("1.1.1.1", 80), 3).close()
    info["network"] = "open"
except Exception as error:
    info["network"] = "blocked: " + type(error).__name__
print("AXI_PROBE=" + json.dumps(info))
"""
PROBE_QUESTION = (
    "Run exactly this Python code with the Python tool, without any change, and then "
    "report its output:\n\n```python\n" + PROBE_CODE + "```"
)
LOOP_QUESTION = (
    "Run exactly this Python code with the Python tool, without any change, and report "
    "what happened:\n\n```python\nwhile True:\n    pass\n```"
)


def info(name: str, detail: Any = None) -> None:
    """Prints evidence that is not a check."""
    print(
        f"INFO {name}: {json.dumps(detail, ensure_ascii=False, default=str)}",
        flush=True,
    )


def utc_now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- numbers and files


def build_csv(tag: str) -> tuple[str, str, Decimal, Decimal, dict[str, Decimal]]:
    """Returns the CSV text, its unique marker, the total, the mean and the region totals."""
    marker = f"AXI-CSV-MARKER-{tag.upper()}"
    lines = ["order_id,region,amount,note"]
    by_region: dict[str, Decimal] = {}
    for index, amount in enumerate(CSV_AMOUNTS, start=1):
        region = CSV_REGIONS[(index - 1) % len(CSV_REGIONS)]
        note = f"ref {marker}" if index == 1 else "ok"
        lines.append(f"{index},{region},{amount},{note}")
        by_region[region] = by_region.get(region, Decimal(0)) + Decimal(amount)
    total = sum((Decimal(amount) for amount in CSV_AMOUNTS), Decimal(0))
    mean = total / Decimal(len(CSV_AMOUNTS))
    return "\n".join(lines) + "\n", marker, total, mean, by_region


def number_variants(value: Decimal) -> set[str]:
    """The exact value and its 2- and 3-decimal roundings (half up and half even)."""
    variants = {format(value.normalize(), "f")}
    for places in (2, 3):
        for rounding in (ROUND_HALF_UP, ROUND_HALF_EVEN):
            quantum = Decimal(1).scaleb(-places)
            variants.add(format(value.quantize(quantum, rounding=rounding), "f"))
    return variants


def contains_number(text: str, value: Decimal) -> bool:
    """True when the text states the number, with or without thousands separators."""
    plain = text.replace(",", "")
    return any(
        re.search(r"(?<![\d.])" + re.escape(variant) + r"(?!\d)", plain)
        for variant in number_variants(value)
    )


def looks_like_csv(content: bytes, content_type: str) -> bool:
    if "csv" in content_type.lower():
        return True
    if b"\0" in content or content.startswith(PNG_MAGIC):
        return False
    try:
        first_line = content.decode().splitlines()[0]
    except (UnicodeDecodeError, IndexError):
        return False
    return "," in first_line


def key_hidden(value: Any) -> bool:
    """True when the listing shows no key or only a mask.

    v4.8.4 masks as "abcd...wxyz", or as bullets for a short key (mask_string in
    backend/onyx/utils/encryption.py).
    """
    if value is None or value == "":
        return True
    text = str(value)
    if set(text) <= {"•", "*"}:
        return True
    return "..." in text and len(text) <= 24


def provider_summary(provider: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": provider.get("id"),
        "name": provider.get("name"),
        "provider_type": provider.get("provider_type"),
        "is_active": provider.get("is_active"),
        "key_hidden": key_hidden(provider.get("masked_api_key")),
    }


def titles(docs: list[dict[str, Any]]) -> list[str]:
    return [str(doc.get("semantic_identifier")) for doc in docs]


# ---------------------------------------------------------------- HTTP helpers


def upload_bytes(
    session: OnyxSession,
    path: str,
    file_name: str,
    content_type: str,
    data: bytes,
    fields: dict[str, str],
) -> Any:
    """Posts one in-memory file as multipart form data (field name "files")."""
    boundary = uuid.uuid4().hex
    parts: list[bytes] = [
        f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"'
        f"\r\n\r\n{value}\r\n".encode()
        for name, value in fields.items()
    ]
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="files"; '
        f'filename="{file_name}"\r\nContent-Type: {content_type}\r\n\r\n'.encode()
        + data
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    status, body = session.request(
        "POST",
        path,
        raw_body=b"".join(parts),
        content_type=f"multipart/form-data; boundary={boundary}",
    )
    expect(status == 200, f"upload to {path} returned {status}: {body}")
    return body


def download(session: OnyxSession, path: str) -> tuple[int, bytes, str]:
    """GET as the session user. Returns the status, the bytes and the content type."""
    # OnyxSession allows only http and https base URLs.
    request = urllib.request.Request(session.base_url + path, method="GET")  # noqa: S310
    try:
        with session.opener.open(request, timeout=120) as response:
            return (
                int(response.status),
                response.read(),
                str(response.headers.get("Content-Type") or ""),
            )
    except urllib.error.HTTPError as error:
        return (
            int(error.code),
            error.read(),
            str(error.headers.get("Content-Type") or ""),
        )


def fetch_status(url: str) -> int | None:
    """HTTP status of a public link (redirects followed), or None when unreachable."""
    if urllib.parse.urlparse(url).scheme not in ("http", "https"):
        return None
    request = urllib.request.Request(  # noqa: S310
        url, headers={"User-Agent": USER_AGENT}, method="GET"
    )
    try:
        with urllib.request.urlopen(  # noqa: S310
            request, timeout=LINK_TIMEOUT_SECONDS
        ) as response:
            return int(response.status)
    except urllib.error.HTTPError as error:
        return int(error.code)
    except (urllib.error.URLError, OSError, ValueError):
        return None


# ---------------------------------------------------------------- chat


@dataclass
class ChatRun:
    """One streamed chat answer with the packets that the tool checks need."""

    chat_session_id: str
    seconds: float = 0.0
    answer: str = ""
    types: list[str] = field(default_factory=list)
    # Seconds since the request start, one value for each packet in `types`.
    times: list[float] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    python_code: list[str] = field(default_factory=list)
    stdout: str = ""
    stderr: str = ""
    file_ids: list[str] = field(default_factory=list)
    search_starts: list[dict[str, Any]] = field(default_factory=list)
    documents: list[dict[str, Any]] = field(default_factory=list)
    # citation_number -> document_id
    citations: dict[int, str] = field(default_factory=dict)


def stream_timed(
    session: OnyxSession, path: str, body: Any
) -> list[tuple[float, dict[str, Any]]]:
    """Posts JSON and returns each NDJSON packet with its arrival time in seconds."""
    # OnyxSession allows only http and https base URLs.
    request = urllib.request.Request(  # noqa: S310
        session.base_url + path,
        data=json.dumps(body).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    started = time.monotonic()
    try:
        with session.opener.open(request, timeout=900) as response:
            return [
                (time.monotonic() - started, json.loads(line))
                for line in response
                if line.strip()
            ]
    except urllib.error.HTTPError as error:
        raise SystemExit(
            f"{path} returned {error.code}: {error.read().decode()}"
        ) from None


def run_chat(
    session: OnyxSession,
    question: str,
    forced_tool_id: int,
    file_descriptors: list[dict[str, Any]] | None = None,
) -> ChatRun:
    """Sends one message with a forced tool, as the web UI does, and reads the stream."""
    chat_session_id = create_chat_session(session, question[:40])
    started = time.monotonic()
    packets = stream_timed(
        session,
        "/api/chat/send-chat-message",
        {
            "message": question,
            "chat_session_id": chat_session_id,
            "parent_message_id": -1,
            "file_descriptors": file_descriptors or [],
            "forced_tool_id": forced_tool_id,
            "stream": True,
            "include_citations": True,
            "origin": "api",
        },
    )
    run = ChatRun(chat_session_id=chat_session_id)
    answer_parts: list[str] = []
    for seconds, packet in packets:
        obj = packet.get("obj") or {}
        kind = str(obj.get("type") or "")
        run.types.append(kind)
        run.times.append(round(seconds, 2))
        if "error" in packet or kind == "error":
            run.errors.append(str(packet.get("error") or obj))
        if kind == "message_delta":
            answer_parts.append(obj.get("content") or "")
        elif kind == "citation_info":
            run.citations[int(obj["citation_number"])] = str(obj["document_id"])
        elif kind == "python_tool_start":
            run.python_code.append(str(obj.get("code") or ""))
        elif kind == "python_tool_delta":
            run.stdout += obj.get("stdout") or ""
            run.stderr += obj.get("stderr") or ""
            run.file_ids.extend(str(file_id) for file_id in obj.get("file_ids") or [])
        elif kind == "search_tool_start":
            run.search_starts.append(obj)
        elif kind == "search_tool_documents_delta":
            run.documents.extend(obj.get("documents") or [])
    run.seconds = round(time.monotonic() - started, 1)
    run.answer = "".join(answer_parts).strip()
    return run


def chat_summary(run: ChatRun) -> dict[str, Any]:
    return {
        "chat_session_id": run.chat_session_id,
        "seconds": run.seconds,
        "answer": run.answer[:300],
        "errors": run.errors or None,
        "python_runs": len(run.python_code),
        "stdout_tail": run.stdout[-300:],
        "stderr_tail": run.stderr[-300:],
        "file_ids": run.file_ids,
        "web_documents": len(run.documents),
    }


def python_window(run: ChatRun) -> float | None:
    """Seconds from the first python_tool_start to the first packet of another kind."""
    if "python_tool_start" not in run.types:
        return None
    start = run.types.index("python_tool_start")
    for index in range(start + 1, len(run.types)):
        if run.types[index] not in PYTHON_PACKETS:
            return round(run.times[index] - run.times[start], 1)
    return round(run.times[-1] - run.times[start], 1)


def web_documents(run: ChatRun) -> list[dict[str, Any]]:
    """The streamed web documents with an http(s) link, one for each document id."""
    docs: dict[str, dict[str, Any]] = {}
    for doc in run.documents:
        link = str(doc.get("link") or "")
        if link.startswith(("http://", "https://")):
            docs.setdefault(str(doc.get("document_id")), doc)
    return list(docs.values())


def parse_probe(stdout: str) -> dict[str, Any] | None:
    for line in stdout.splitlines():
        if PROBE_MARKER in line:
            try:
                data = json.loads(line.split(PROBE_MARKER, 1)[1])
            except json.JSONDecodeError:
                return None
            return data if isinstance(data, dict) else None
    return None


# ---------------------------------------------------------------- the test


class ToolsCheck:
    """The sessions, ids and results that the steps share."""

    def __init__(
        self,
        checks: Checks,
        base_url: str,
        salt: str,
        tag: str,
        domain: str,
        state: dict[str, Any],
        record: dict[str, Any],
    ) -> None:
        self.checks = checks
        self.base_url = base_url
        self.salt = salt
        self.tag = tag
        self.domain = domain
        self.state = state
        self.record = record
        self.sessions: dict[str, OnyxSession] = {}
        # role -> in_code_tool_id -> tool id (ids differ for each company)
        self.tool_ids: dict[str, dict[str, int]] = {}
        self.provider_c: dict[str, Any] = {}
        self.csv_name = f"sales-{tag}.csv"
        self.csv_text, self.csv_marker, self.total, self.mean, self.by_region = (
            build_csv(tag)
        )
        self.csv_descriptor: dict[str, Any] | None = None
        self.csv_session_id: str | None = None
        self.file_ids_a: list[str] = []
        self.file_ids_c: list[str] = []

    # -- helpers

    def session(self, role: str) -> OnyxSession:
        expect(role in self.sessions, f"no session for {role}; step a did not run")
        return self.sessions[role]

    def tool_id(self, role: str, in_code_tool_id: str) -> int:
        tools = self.tool_ids.get(role) or {}
        expect(
            in_code_tool_id in tools,
            f"{role} has no {in_code_tool_id} in its tool list; step a did not pass",
        )
        return tools[in_code_tool_id]

    def tool_map(self, session: OnyxSession) -> dict[str, int]:
        status, tools = session.request("GET", "/api/tool")
        expect(
            status == 200 and isinstance(tools, list), f"/api/tool returned {status}"
        )
        return {
            str(tool["in_code_tool_id"]): int(tool["id"])
            for tool in tools
            if tool.get("in_code_tool_id")
        }

    def active_providers(self, session: OnyxSession) -> list[dict[str, Any]]:
        status, providers = session.request(
            "GET", "/api/admin/web-search/search-providers"
        )
        expect(
            status == 200 and isinstance(providers, list),
            f"search-providers returned {status}",
        )
        return [provider_summary(p) for p in providers if p.get("is_active")]

    def login_state_accounts(self) -> None:
        state_tag = str(self.state.get("tag") or "")
        expect(bool(TAG_PATTERN.match(state_tag)), "the state file has no valid tag")
        emails = self.state.get("emails") or {}
        for role in ("owner-a", "owner-b", "member-a"):
            email = emails.get(role)
            expect(bool(email), f"the state file lacks the email of {role}")
            self.sessions[role] = OnyxSession(
                self.base_url, str(email), password_for(self.salt, state_tag, role)
            )

    def attach_csv(self, session: OnyxSession) -> dict[str, Any]:
        """Uploads the CSV as a chat file (no project) and waits until it is processed."""
        upload = upload_bytes(
            session,
            "/api/user/projects/file/upload",
            self.csv_name,
            "text/csv",
            self.csv_text.encode(),
            {},
        )
        user_files = upload.get("user_files") if isinstance(upload, dict) else None
        if not isinstance(user_files, list) or len(user_files) != 1:
            raise SystemExit(f"CSV upload returned {upload}")
        user_file: dict[str, Any] = user_files[0]
        file_ids = [str(user_file["id"])]

        def read_statuses() -> list[str]:
            status, data = session.request(
                "POST", "/api/user/projects/file/statuses", {"file_ids": file_ids}
            )
            expect(status == 200, f"file statuses returned {status}: {data}")
            return [str(item["status"]) for item in data]

        statuses, seconds = poll(
            read_statuses, lambda found: all(s in FILE_END_STATUSES for s in found)
        )
        # SKIPPED: stored without indexing (a large table); the chat can still use it.
        self.checks.record(
            f"{self.csv_name} attached by member A reaches COMPLETED or SKIPPED",
            statuses in (["COMPLETED"], ["SKIPPED"]),
            {
                "statuses": statuses,
                "seconds": seconds,
                "chat_file_type": user_file.get("chat_file_type"),
            },
        )
        # The descriptor of the web UI (projectsFileToFileDescriptor).
        return {
            "id": str(user_file["file_id"]),
            "type": user_file.get("chat_file_type") or "tabular",
            "name": user_file.get("name") or self.csv_name,
            "user_file_id": str(user_file["id"]),
        }

    def download_statuses(self, role: str, file_ids: list[str]) -> dict[str, int]:
        session = self.session(role)
        return {
            file_id: download(session, f"/api/chat/file/{file_id}")[0]
            for file_id in file_ids
        }

    # -- steps

    def step_setup(self) -> None:
        self.login_state_accounts()
        email = f"owner-c-{self.tag}@{self.domain}"
        password = password_for(self.salt, self.tag, "owner-c")
        status, data = plain_request(
            self.base_url,
            "POST",
            "/api/auth/register",
            {"email": email, "username": email, "password": password},
        )
        self.checks.record(
            "owner C signs up as a new company",
            status == 201,
            {"email": email, "status": status, "body": data},
        )
        owner_c = OnyxSession(self.base_url, email, password)
        self.sessions["owner-c"] = owner_c
        data = me(owner_c)
        tenants = self.state.get("tenants") or {}
        tenant_c = data.get("team_name")
        self.checks.record(
            "owner C is admin of a company that is not A or B",
            bool(tenant_c) and is_admin(data) and tenant_c not in tenants.values(),
            {**me_summary(data), "tenants_ab": tenants},
        )
        self.record["owner_c"] = {"email": email, "tenant": tenant_c}
        for role, label in (
            ("owner-a", "owner A"),
            ("owner-b", "owner B"),
            ("owner-c", "owner C"),
        ):
            self.check_company_tools(role, label)
        self.tool_ids["member-a"] = self.tool_map(self.session("member-a"))
        self.checks.record(
            "member A tool list has PythonTool and WebSearchTool",
            all(
                t in self.tool_ids["member-a"] for t in ("PythonTool", "WebSearchTool")
            ),
            {"tools": sorted(self.tool_ids["member-a"])},
        )
        status, config = owner_c.request(
            "GET", "/api/admin/default-assistant/configuration"
        )
        info(
            "owner C default assistant tool ids (read only)",
            {
                "status": status,
                "tool_ids": config.get("tool_ids")
                if isinstance(config, dict)
                else config,
                "tools": self.tool_ids.get("owner-c"),
            },
        )
        self.record["tool_ids"] = self.tool_ids

    def check_company_tools(self, role: str, label: str) -> None:
        session = self.session(role)
        status, data = session.request("GET", "/api/admin/code-interpreter")
        self.checks.record(
            f"{label} Code Interpreter is enabled",
            status == 200 and isinstance(data, dict) and data.get("enabled") is True,
            {"status": status, "body": data},
        )
        status, data = session.request("GET", "/api/admin/code-interpreter/health")
        self.checks.record(
            f"{label} Code Interpreter health is connected",
            status == 200 and isinstance(data, dict) and data.get("connected") is True,
            {"status": status, "body": data},
        )
        tools = self.tool_map(session)
        self.tool_ids[role] = tools
        self.checks.record(
            f"{label} tool list has {', '.join(REQUIRED_TOOLS)}",
            all(tool in tools for tool in REQUIRED_TOOLS),
            {"tools": sorted(tools)},
        )
        status, providers = session.request(
            "GET", "/api/admin/web-search/search-providers"
        )
        providers = providers if isinstance(providers, list) else []
        active = [p for p in providers if p.get("is_active")]
        self.checks.record(
            f"{label} has one active web search provider {PROVIDER_NAME!r} with the key hidden",
            status == 200
            and len(active) == 1
            and active[0].get("name") == PROVIDER_NAME
            and key_hidden(active[0].get("masked_api_key")),
            {"status": status, "providers": [provider_summary(p) for p in providers]},
        )
        if role == "owner-c" and active:
            self.provider_c = provider_summary(active[0])
            self.record["provider_c"] = self.provider_c
        status, content = session.request(
            "GET", "/api/admin/web-search/content-providers"
        )
        content = content if isinstance(content, list) else []
        self.checks.record(
            f"{label} has no active web content provider (built-in crawler)",
            status == 200 and not any(p.get("is_active") for p in content),
            {
                "status": status,
                "content_providers": [provider_summary(p) for p in content],
            },
        )

    def step_csv(self) -> None:
        member = self.session("member-a")
        self.csv_descriptor = self.attach_csv(member)
        run = run_chat(
            member,
            CSV_QUESTION,
            self.tool_id("member-a", "PythonTool"),
            [self.csv_descriptor],
        )
        self.csv_session_id = run.chat_session_id
        self.record["csv"] = {
            "name": self.csv_name,
            "marker": self.csv_marker,
            "chat_session_id": run.chat_session_id,
            "user_file_id": self.csv_descriptor["user_file_id"],
        }
        self.checks.record(
            "member A CSV question runs the Python tool without error",
            bool(run.python_code) and not run.errors,
            chat_summary(run),
        )
        found = {
            "total": contains_number(run.answer, self.total),
            "mean": contains_number(run.answer, self.mean),
        }
        self.checks.record(
            "member A answer states the total and the mean of the CSV",
            all(found.values()),
            {
                "expected": {"total": str(self.total), "mean": str(self.mean)},
                "found": found,
                "answer": run.answer[:400],
            },
        )

    def step_generated_files(self) -> None:
        member = self.session("member-a")
        if self.csv_descriptor is None:
            raise SystemExit("step b did not attach the CSV")
        run = run_chat(
            member,
            CHART_QUESTION,
            self.tool_id("member-a", "PythonTool"),
            [self.csv_descriptor],
        )
        self.file_ids_a = list(dict.fromkeys(run.file_ids))
        self.record["generated_files_a"] = {
            "chat_session_id": run.chat_session_id,
            "file_ids": self.file_ids_a,
        }
        self.checks.record(
            "member A chart request returns generated file ids",
            bool(self.file_ids_a) and not run.errors,
            chat_summary(run),
        )
        files: dict[str, dict[str, Any]] = {}
        for file_id in self.file_ids_a:
            status, content, content_type = download(
                member, f"/api/chat/file/{file_id}"
            )
            is_csv = looks_like_csv(content, content_type)
            text = content.decode(errors="replace") if is_csv else ""
            files[file_id] = {
                "status": status,
                "content_type": content_type,
                "bytes": len(content),
                "png": content.startswith(PNG_MAGIC),
                "csv": is_csv,
                "regions_in_csv": sorted(r for r in self.by_region if r in text),
                "csv_head": text[:200],
            }
        self.checks.record(
            "member A downloads every generated file (200)",
            bool(files) and all(f["status"] == 200 for f in files.values()),
            {file_id: f["status"] for file_id, f in files.items()},
        )
        self.checks.record(
            "member A downloads a PNG chart among the generated files",
            any(f["status"] == 200 and f["png"] for f in files.values()),
            files,
        )
        self.checks.record(
            "member A downloads a CSV with the regions among the generated files",
            any(
                f["status"] == 200 and f["csv"] and f["regions_in_csv"]
                for f in files.values()
            ),
            {"expected_by_region": {k: str(v) for k, v in self.by_region.items()}},
        )
        denied = self.download_statuses("owner-b", self.file_ids_a)
        self.checks.record(
            "owner B cannot download member A's generated files",
            bool(denied) and all(status in (403, 404) for status in denied.values()),
            denied,
        )
        # Upstream decides this for the same company: recorded, not asserted.
        info(
            "owner A (same company, not the chat owner) download status of member A's files",
            self.download_statuses("owner-a", self.file_ids_a),
        )

    def step_web_search(self) -> None:
        for role, label in (("owner-b", "owner B"), ("owner-c", "owner C")):
            self.web_search_for(role, label)

    def web_search_for(self, role: str, label: str) -> None:
        session = self.session(role)
        tool_id = self.tool_id(role, "WebSearchTool")
        run = run_chat(session, WEB_QUESTION, tool_id)
        docs = web_documents(run)
        if not docs:
            # Public engines answer with captchas at times: one more attempt.
            info(
                f"{label} web search returned no documents, one retry",
                chat_summary(run),
            )
            run = run_chat(session, WEB_QUESTION, tool_id)
            docs = web_documents(run)
        internet = any(start.get("is_internet_search") for start in run.search_starts)
        self.checks.record(
            f"{label} web search streams internet documents with http(s) links",
            internet and bool(docs) and not run.errors,
            {**chat_summary(run), "links": [doc.get("link") for doc in docs][:10]},
        )
        numbers = sorted({int(n) for n in re.findall(r"\[(\d+)\]", run.answer)})
        links = {str(doc.get("document_id")): str(doc.get("link")) for doc in docs}
        cited: dict[int, str] = {}
        unmapped: list[int] = []
        for number in numbers:
            document_id = run.citations.get(number)
            if document_id is None or document_id not in links:
                unmapped.append(number)
            else:
                cited[number] = links[document_id]
        # citation_info packets without a [n] in the text still name web documents.
        for number, document_id in run.citations.items():
            if document_id in links:
                cited.setdefault(number, links[document_id])
        self.checks.record(
            f"{label} every [n] citation maps to a web document",
            bool(cited) and not unmapped,
            {"numbers_in_answer": numbers, "unmapped": unmapped, "cited": cited},
        )
        statuses = {link: fetch_status(link) for link in dict.fromkeys(cited.values())}
        self.checks.record(
            f"{label} at least one cited link answers with a status below 400",
            any(status is not None and status < 400 for status in statuses.values()),
            statuses,
        )
        self.record.setdefault("web_search", {})[role] = {
            "chat_session_id": run.chat_session_id,
            "cited": cited,
            "statuses": statuses,
        }

    def step_isolation(self) -> None:
        owner_b, member = self.session("owner-b"), self.session("member-a")
        status, files = owner_b.request("GET", "/api/user/files/recent")
        names_b = (
            [str(f.get("name")) for f in files] if isinstance(files, list) else None
        )
        self.checks.record(
            "owner B recent files hold no trace of company A's CSV",
            status == 200
            and names_b is not None
            and self.csv_name not in names_b
            and self.csv_marker not in json.dumps(files),
            {"status": status, "names": names_b},
        )
        status, files = member.request("GET", "/api/user/files/recent")
        names_a = (
            [str(f.get("name")) for f in files] if isinstance(files, list) else None
        )
        self.checks.record(
            "control: member A recent files list the CSV",
            status == 200 and self.csv_name in (names_a or []),
            {"status": status, "names": names_a},
        )
        docs = search_docs(owner_b, self.csv_marker)
        self.checks.record(
            "owner B search for the CSV marker returns nothing of company A",
            self.csv_marker not in json.dumps(docs)
            and self.csv_name not in titles(docs),
            {"titles": titles(docs)},
        )
        status, listing = owner_b.request("GET", "/api/chat/get-user-chat-sessions")
        sessions_b = listing.get("sessions") if isinstance(listing, dict) else None
        ids_a: set[str] = set()
        for key in ("csv", "generated_files_a"):
            item = self.record.get(key)
            if isinstance(item, dict) and item.get("chat_session_id"):
                ids_a.add(str(item["chat_session_id"]))
        text_b = json.dumps(sessions_b)
        self.checks.record(
            "owner B chat sessions hold no trace of company A's CSV chats",
            status == 200
            and isinstance(sessions_b, list)
            and not any(session_id in text_b for session_id in ids_a)
            and self.csv_marker not in text_b
            and self.csv_name not in text_b,
            {
                "status": status,
                "sessions": len(sessions_b or []),
                "ids_a": sorted(ids_a),
            },
        )
        if self.csv_session_id:
            status, data = owner_b.request(
                "GET", f"/api/chat/get-chat-session/{self.csv_session_id}"
            )
            self.checks.record(
                "owner B cannot read member A's CSV chat session",
                access_denied(status, data),
                {"status": status, "body": data},
            )
        owner_c = self.session("owner-c")
        run = run_chat(
            owner_c, TINY_FILE_QUESTION, self.tool_id("owner-c", "PythonTool")
        )
        self.file_ids_c = list(dict.fromkeys(run.file_ids))
        self.record["generated_files_c"] = {
            "chat_session_id": run.chat_session_id,
            "file_ids": self.file_ids_c,
        }
        self.checks.record(
            "owner C generates a small file with the Python tool",
            bool(self.file_ids_c) and not run.errors,
            chat_summary(run),
        )
        own = self.download_statuses("owner-c", self.file_ids_c)
        self.checks.record(
            "control: owner C downloads its own generated file",
            bool(own) and all(status == 200 for status in own.values()),
            own,
        )
        for role, label in (("owner-a", "owner A"), ("member-a", "member A")):
            denied = self.download_statuses(role, self.file_ids_c)
            self.checks.record(
                f"{label} cannot download company C's generated file",
                bool(denied)
                and all(status in (403, 404) for status in denied.values()),
                denied,
            )

    def step_sandbox(self) -> None:
        owner_c = self.session("owner-c")
        tool_id = self.tool_id("owner-c", "PythonTool")
        run = run_chat(owner_c, PROBE_QUESTION, tool_id)
        probe = parse_probe(run.stdout)
        info(
            "sandbox probe in company C",
            {
                "probe": probe,
                "code": run.python_code[:1],
                "stderr": run.stderr[:300],
                "answer": run.answer[:300],
                "seconds": run.seconds,
            },
        )
        self.record["sandbox_probe"] = probe
        if probe is None:
            self.checks.record(
                "sandbox probe prints its AXI_PROBE line", False, chat_summary(run)
            )
        else:
            self.checks.record(
                f"sandbox runs as uid {EXPECTED_UID}",
                probe.get("uid") == EXPECTED_UID,
                {"uid": probe.get("uid")},
            )
            self.checks.record(
                "sandbox has no /var/run/docker.sock",
                probe.get("docker_sock") is False,
                {"docker_sock": probe.get("docker_sock")},
            )
            self.checks.record(
                "sandbox environment has no POSTGRES, S3_, FIREWORKS or SMTP names",
                probe.get("secret_env_names") == [],
                {"secret_env_names": probe.get("secret_env_names")},
            )
            self.checks.record(
                "sandbox cannot open a TCP connection to 1.1.1.1:80",
                str(probe.get("network") or "").startswith("blocked"),
                {"network": probe.get("network")},
            )
        run = run_chat(owner_c, LOOP_QUESTION, tool_id)
        window = python_window(run)
        self.checks.record(
            f"a never-ending Python run ends within {TIMEOUT_WALL_SECONDS} s",
            window is not None and window < TIMEOUT_WALL_SECONDS,
            {
                "python_seconds": window,
                "total_seconds": run.seconds,
                "code": run.python_code[:1],
                "stderr": run.stderr[:300],
                "answer": run.answer[:300],
            },
        )
        self.record["timeout_probe"] = {"python_seconds": window, "total": run.seconds}

    def step_customization(self) -> None:
        owner_c = self.session("owner-c")
        provider_id = self.provider_c.get("id")
        expect(provider_id is not None, "step a found no active provider in company C")
        status, _ = owner_c.request(
            "PUT", "/api/admin/code-interpreter", {"enabled": False}
        )
        status_read, data = owner_c.request("GET", "/api/admin/code-interpreter")
        self.checks.record(
            "owner C switches the Code Interpreter off",
            status == 200
            and status_read == 200
            and isinstance(data, dict)
            and data.get("enabled") is False,
            {"put_status": status, "get_status": status_read, "body": data},
        )
        status, body = owner_c.request(
            "POST", f"/api/admin/web-search/search-providers/{provider_id}/deactivate"
        )
        active = self.active_providers(owner_c)
        self.checks.record(
            "owner C deactivates the platform web search provider",
            status == 200 and not active,
            {"status": status, "body": body, "active": active},
        )
        tools = self.tool_map(owner_c)
        self.checks.record(
            "owner C tool list hides PythonTool and WebSearchTool while they are off",
            "PythonTool" not in tools and "WebSearchTool" not in tools,
            {"tools": sorted(tools)},
        )
        disabled = {
            "recorded_at": utc_now(),
            "code_interpreter_enabled": False,
            "active_search_providers": active,
            "provider": self.provider_c,
        }
        self.record["customization"] = {"disabled": disabled}
        info(
            "operator: a platform defaults run (saas-defaults) must keep company C's choices: "
            "Code Interpreter off and the provider inactive. Compare with the record file.",
            {"owner_c": self.record.get("owner_c"), "disabled": disabled},
        )
        status, _ = owner_c.request(
            "PUT", "/api/admin/code-interpreter", {"enabled": True}
        )
        status_read, data = owner_c.request("GET", "/api/admin/code-interpreter")
        self.checks.record(
            "owner C switches the Code Interpreter on again",
            status == 200
            and status_read == 200
            and isinstance(data, dict)
            and data.get("enabled") is True,
            {"put_status": status, "get_status": status_read, "body": data},
        )
        status, body = owner_c.request(
            "POST", f"/api/admin/web-search/search-providers/{provider_id}/activate"
        )
        active = self.active_providers(owner_c)
        self.checks.record(
            "owner C activates the platform web search provider again",
            status == 200
            and len(active) == 1
            and active[0].get("name") == PROVIDER_NAME,
            {"status": status, "active": active},
        )
        tools = self.tool_map(owner_c)
        self.checks.record(
            "owner C tool list shows PythonTool and WebSearchTool again",
            "PythonTool" in tools and "WebSearchTool" in tools,
            {"tools": sorted(tools)},
        )
        self.record["customization"]["restored"] = {
            "recorded_at": utc_now(),
            "code_interpreter_enabled": True,
            "active_search_providers": active,
        }


def run_step(checks: Checks, name: str, step: Callable[[], None]) -> None:
    """Runs one step. A stop inside the step is one failed check; the next step runs."""
    try:
        step()
    except SystemExit as error:
        checks.record(f"step {name} runs to the end", False, str(error.code))
    except Exception as error:
        traceback.print_exc()
        checks.record(f"step {name} runs to the end", False, repr(error))


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", required=True)
    parser.add_argument(
        "--state",
        type=Path,
        required=True,
        help="journey_state.json of saas_journey.py",
    )
    parser.add_argument(
        "--tag", required=True, help="new tag for owner C: a-z, 0-9 and '-'"
    )
    parser.add_argument("--email-domain", default="example.com")
    parser.add_argument(
        "--record",
        type=Path,
        default=Path("tools_state.json"),
        help="where the test writes the ids and the recorded states",
    )
    args = parser.parse_args()
    if urllib.parse.urlparse(args.base_url).scheme not in ("http", "https"):
        parser.error(f"--base-url must use http or https: {args.base_url}")
    if not TAG_PATTERN.match(args.tag):
        parser.error("--tag must match " + TAG_PATTERN.pattern)
    salt = os.environ.get("MT_PASSWORD_SALT", "")
    if len(salt) < 8:
        parser.error("set MT_PASSWORD_SALT (8 characters or more)")
    if not args.state.exists():
        parser.error(
            f"--state file {args.state} does not exist; run saas_journey.py first"
        )
    state = json.loads(args.state.read_text())
    if not isinstance(state, dict):
        parser.error(f"--state file {args.state} is not a JSON object")
    checks = Checks()
    record: dict[str, Any] = {
        "tag": args.tag,
        "state_tag": state.get("tag"),
        "base_url": args.base_url,
        "started": utc_now(),
    }
    tools = ToolsCheck(
        checks, args.base_url, salt, args.tag, args.email_domain, state, record
    )
    steps: list[tuple[str, Callable[[], None]]] = [
        ("a-setup", tools.step_setup),
        ("b-csv", tools.step_csv),
        ("c-generated-files", tools.step_generated_files),
        ("d-web-search", tools.step_web_search),
        ("e-isolation", tools.step_isolation),
        ("f-sandbox", tools.step_sandbox),
        ("g-customization", tools.step_customization),
    ]
    try:
        for name, step in steps:
            run_step(checks, name, step)
    finally:
        record["finished"] = utc_now()
        args.record.write_text(json.dumps(record, indent=1, default=str))
        info("record written", str(args.record))
    return checks.exit_code("tools")


if __name__ == "__main__":
    sys.exit(main())
