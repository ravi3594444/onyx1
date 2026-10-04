"""Reproduces the Onyx v4.8.4 pruning race and tests the supported remedy.

The race: a file removal while a prune of the same connector runs starts no new prune.
The API still answers 200, and the removed file stays searchable until the next
scheduled prune. The remedy under test is the supported manual prune
(POST /api/manage/admin/cc-pair/<id>/prune).

Usage: python3 prune_race.py --base-url http://localhost:3000
Needs ADMIN_EMAIL and ADMIN_PASSWORD. Exit code 0 only when the remedy removes the file.
"""

import argparse
import json
import sys
import time

from run_checks import (
    CORPUS_DIR,
    GUIDE_FILE,
    OLD_REFUND_FILE,
    PUBLIC_FILES,
    Checks,
    OnyxSession,
    expect,
    last_pruned,
    log,
    login,
    poll,
    search_docs,
    wait_for_indexing,
)

QUERY = "refund policy support hours meal allowance"
SETTLE_SECONDS = 60


def create_connector(
    admin: OnyxSession, checks: Checks
) -> tuple[int, int, dict[str, str]]:
    """Indexes the public corpus in a new File connector. Returns ids and file ids."""
    # Connector names must be unique, so each run gets its own name.
    name = f"Prune race corpus {time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    uploaded = admin.upload(
        "/api/manage/admin/connector/file/upload",
        [CORPUS_DIR / name for name in PUBLIC_FILES],
        {},
    )
    file_ids = dict(zip(uploaded["file_names"], uploaded["file_paths"], strict=True))
    status, connector = admin.request(
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
    status, credential = admin.request(
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
    status, link = admin.request(
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
    wait_for_indexing(checks, admin, link["data"], len(PUBLIC_FILES))
    return connector["id"], link["data"], file_ids


def remove_file(admin: OnyxSession, connector_id: int, file_id: str) -> None:
    admin.upload(
        f"/api/manage/admin/connector/{connector_id}/files/update",
        [],
        {"file_ids_to_remove": json.dumps([file_id])},
    )


def wait_for_new_prune(
    admin: OnyxSession, cc_pair_id: int, before: str | None
) -> str | None:
    value, seconds = poll(
        lambda: last_pruned(admin, cc_pair_id),
        lambda found: found is not None and found != before,
    )
    return value if seconds is not None else None


def manual_prune(admin: OnyxSession, cc_pair_id: int) -> tuple[int, object]:
    """Starts a prune. Retries while Onyx answers 409 (a prune still runs)."""
    deadline = time.time() + 300
    while True:
        status, body = admin.request(
            "POST", f"/api/manage/admin/cc-pair/{cc_pair_id}/prune"
        )
        if status != 409 or time.time() > deadline:
            return status, body
        time.sleep(5)


def document_ids(admin: OnyxSession, cc_pair_id: int) -> set[str]:
    """Document ids of this connector in search results (FILE_CONNECTOR__<file id>)."""
    return {
        doc["document_id"]
        for doc in search_docs(admin, QUERY)
        if doc["document_id"] in KNOWN_IDS[cc_pair_id]
    }


KNOWN_IDS: dict[int, set[str]] = {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://localhost:3000")
    args = parser.parse_args()
    checks = Checks()
    admin = login(args.base_url, "ADMIN")
    connector_id, cc_pair_id, file_ids = create_connector(admin, checks)
    doc_id = {name: f"FILE_CONNECTOR__{file_id}" for name, file_id in file_ids.items()}
    KNOWN_IDS[cc_pair_id] = set(doc_id.values())
    checks.record(
        "all documents of the new connector are in search",
        document_ids(admin, cc_pair_id) == KNOWN_IDS[cc_pair_id],
        {"found": sorted(document_ids(admin, cc_pair_id))},
    )

    # Reproduction: start a prune, then remove a file while that prune runs. Onyx v4.8.4
    # starts no second prune in that window, so the removed file stays indexed.
    removed: str | None = None
    for candidate in (GUIDE_FILE, OLD_REFUND_FILE):
        before = last_pruned(admin, cc_pair_id)
        status, body = manual_prune(admin, cc_pair_id)
        expect(status == 200, f"manual prune returned {status}: {body}")
        remove_file(admin, connector_id, file_ids[candidate])
        first_prune = wait_for_new_prune(admin, cc_pair_id, before)
        expect(
            first_prune is not None,
            "the prune that ran during the removal never finished",
        )
        time.sleep(SETTLE_SECONDS)
        second_prune = last_pruned(admin, cc_pair_id)
        still_indexed = doc_id[candidate] in document_ids(admin, cc_pair_id)
        log(
            f"removal of {candidate} during a prune",
            {
                "second_prune_started": second_prune != first_prune,
                "still_in_search_after_settle": still_indexed,
                "settle_seconds": SETTLE_SECONDS,
            },
        )
        if still_indexed:
            removed = candidate
            break
    checks.record(
        "race reproduced: a file removed during a prune stays in search",
        removed is not None,
        {"file": removed, "note": "FAIL means the race did not occur in this run"},
    )
    if removed is None:
        return checks.exit_code("prune-race")

    # Supported remedy: a manual prune after the first prune ended.
    before_manual = last_pruned(admin, cc_pair_id)
    status, body = manual_prune(admin, cc_pair_id)
    checks.record(
        "manual prune accepted", status == 200, {"status": status, "body": body}
    )
    manual_pruned = wait_for_new_prune(admin, cc_pair_id, before_manual)
    checks.record(
        "manual prune finished",
        manual_pruned is not None,
        {"last_pruned": manual_pruned},
    )
    # The prune deletes the documents through background tasks, so search lags a little.
    found, seconds = poll(
        lambda: document_ids(admin, cc_pair_id),
        lambda ids: doc_id[removed] not in ids and len(ids) > 0,
    )
    checks.record(
        f"manual prune removes {removed} from search",
        seconds is not None,
        {"seconds": seconds, "remaining": sorted(found)},
    )
    return checks.exit_code("prune-race")


if __name__ == "__main__":
    sys.exit(main())
