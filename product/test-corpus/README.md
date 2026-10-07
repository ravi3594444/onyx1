# Test corpus

Synthetic documents for the functional checks in `docs/product/PRD.md`.
They contain no real customer or employee data.

Upload only the files in `documents/`. Do not upload this README.

| File | Purpose | Access |
| --- | --- | --- |
| `expense-policy.md` | Short policy | All users |
| `whatsapp-assistant-product-guide.md` | Product guide; changed during the update check | All users |
| `refund-policy-2025.md` | Older version of a conflicting pair; removed during the deletion check | All users |
| `refund-policy-2026.md` | Newer version of a conflicting pair | All users |
| `hr-salary-bands-restricted.md` | Restricted document | HR group only |

## Expected evidence

A check passes only when the answer states the expected fact and cites the expected file.
A fluent answer without the expected citation does not pass.

| ID | Question | Expected fact | Expected source |
| --- | --- | --- | --- |
| Q1 | What is the daily meal allowance for domestic business travel? | INR 1,500 per day | `expense-policy.md` |
| Q2 | What are the support hours for WhatsApp Assistant? | Monday to Saturday, 09:00 to 19:00 IST | `whatsapp-assistant-product-guide.md` |
| Q3 | How many days does a customer have to request a full refund? | 30 days (2026 edition replaces the 14-day 2025 edition) | `refund-policy-2026.md`; a mention of the 2025 edition is acceptable only if it is identified as replaced |
| Q4 | What is the parental leave policy? | No document has this information. The answer must say so and must not invent a policy. | None |
| Q5 | What is the salary band for a Senior Software Engineer at level L4? | HR user: 38 to 46 lakh. Other users: no answer, and no `KESTREL-7731` marker in any result. The answer of other users must come from a search that returned public documents. | `hr-salary-bands-restricted.md` (HR user only) |

## Update and deletion checks

| ID | Change | Expected result after the connector sync |
| --- | --- | --- |
| U1 | In `whatsapp-assistant-product-guide.md`, set the support hours to "Monday to Friday, 10:00 to 18:00 IST" and the guide version to 2.4. | Q2 returns the new hours. |
| D1 | Remove `refund-policy-2025.md` from the source. | No search result shows the 2025 edition. Q3 cites only the 2026 edition. |

## Pass and fail

`run_checks.py` compares each result with the expected evidence above.

- Each check prints one line on stdout: `PASS <check>: <detail>`, `FAIL <check>: <detail>` or `SKIP <check>: <reason>`. The detail and the reason are JSON.
- `SKIP` shows a check that did not run. With `--skip-chat`, the `update` and `delete` steps skip their model answers and print one `SKIP` line for each. A skipped check is not a pass. Read the log to see which checks did not run.
- A step runs all its checks, also after a check fails. Then it prints `PASS step <step>` or `FAIL step <step>`, with the number of skipped checks, for example `PASS step update: 2 checks passed, 1 skipped`.
- A step exits with 0 only when at least one check ran and all checks that ran pass. Otherwise it exits with 1. A skip does not fail the step.
- Some errors stop the step: a login or API call fails, a search returns an error, or the state file lacks an ID from an earlier step. The step then prints `FAIL <step> runs to the end: <reason>` and `FAIL step <step>`, and exits with 1.
- A wait that is longer than 900 seconds fails its check.
- After each login, the script reads `/api/me`. If the session is not the expected user, the step stops.
- A check that expects no result also needs a control result. An empty or failed search does not pass. Examples:
  - The search for `KESTREL-7731` must return public documents to user A and to the admin.
  - User B, the owner of `hr-salary-bands-restricted.md`, runs the same search. Thus, the `search` step also needs the user B credentials. The check `search shows hr-salary-bands-restricted.md to its owner` passes only when the results show the file or the marker. If the search API does not return project files outside a project chat, this check fails. Then the search step does not prove that the marker is hidden.
  - The deletion search must show `refund-policy-2026.md`.
  - User B must get access to the IDs that user A must not get.
  - User A must be able to create and read its own chat session. For the session of user B, user A must get 403 `Access denied` or 404 `not found`. A 403 for a missing permission, such as `READ_CHAT`, fails. The log shows the response body. If user A cannot create its session, the control check fails and the other user A checks still run.
- Q5 for user A passes only when the chat retrieved at least one public document. An answer without a search does not pass.
- A chat check fails when the stream reports an error, also when a tool fails and the model still answers.
- Title and citation checks compare file names exactly. Fact checks ignore case and extra spaces, read `38-46` as `38 to 46`, and read a curly apostrophe as a straight one.
- Q3: an answer that states `14 days`, `14-day` or `fourteen days` must also say that this edition is replaced. It must contain one of the phrases in `REPLACED_PHRASES` in `run_checks.py`, for example `replaced`, `supersed`, `previous`, `older` or `no longer`. The words `2025 edition` alone are not enough. This rule applies in the `chat`, `chat-forced` and `delete` steps. A phrase does not prove that the answer gives 30 days as the current rule. Read the answer to make sure.
- Q4 passes only with an answer that cites no document and says that the documents do not have the information. The answer must contain one of the phrases in `NO_INFO_PHRASES` in `run_checks.py`, for example `no information`, `not find`, `n't include`, `none of the` or `not mention`. A phrase with `n't` matches `don't`, `couldn't` and `wasn't`. The answer must not state a leave length, such as `12 weeks` or `6 months`. Read the answer to make sure that it does not invent a policy in other words.
- The `chat-forced` step asks Q1 to Q5 as user A with the Search tool forced. It uses the same expected evidence as the `chat` step.
- The `delete` step finds `refund-policy-2025.md` before it removes the file. Thus, run it only once after each `index` step.

Run the steps in this order. The command stops at the first failed step and exits with its code:

```bash
(
  set -e
  for step in index search chat chat-forced privacy update delete; do
    python3 product/test-corpus/run_checks.py --base-url http://localhost:3000 "$step"
  done
)
```

To keep a log, add `2>&1 | tee checks.log` after the closing parenthesis, and run `set -o pipefail` first.

If a step fails, the loop does not run the later steps. For example, if the owner check fails, the loop stops at `search`. To get the evidence of the later steps, run each one separately with the same command.

## Customer-journey test (multi-tenant stack)

`saas_journey.py` tests the multi-tenant production stack (project `onyx-saas`) like customers
use it. It imports the helpers and the expected answers of `run_checks.py` and `mt_checks.py`.
It never configures an LLM provider, a default model or the default assistant: the platform
backend image must supply them to each new company. It writes no `/api/admin/llm/*` setting
and never calls `PATCH /api/admin/default-assistant`.

```bash
MT_PASSWORD_SALT=... python3 product/test-corpus/saas_journey.py \
  --base-url https://my-knowledge.duckdns.org --tag journey-1a2b3c4d \
  --state journey_state.json [--email-domain example.com] [--after-restart]
```

`vm-bootstrap.sh saas-journey <sha> [after-restart]` runs it on the VM (workflow actions
`saas-journey` and `saas-journey-after-restart`). The output and the exit code follow the rules of
"Pass and fail" above. The first run does these steps:

1. Owner A and owner B sign up with `POST /api/auth/register` and the body of the web form
   (`email`, `username`, `password`). Each one is admin of a different workspace (`/api/me`
   `team_name`).
2. Without setup, `GET /api/llm/provider` (the listing of the chat UI) shows the default model
   "22nd X AI model" to each owner. `GET /api/admin/default-assistant/configuration` (read only)
   holds `ASSISTANT_ADDITION` of `product/deploy/default_assistant.py`. Owner A gets an answer to
   "Reply with the single word OK" before any document exists.
3. As owner A, the admin provider listing masks `api_key`. A `PUT /api/admin/llm/provider` with
   `api_key_changed: false` and a foreign API base must get 4xx with the guard message, and the
   provider must stay unchanged. `POST /api/admin/llm/test` with the stored key and a foreign API
   base must also get the guard message. The foreign base is `https://api.example.invalid/v1`: a
   reserved name, so no request leaves the server also when the guard fails.
4. Owner A indexes the four public files in `documents/` (the unchanged files, never the updated
   copies of the update check) and puts `hr-salary-bands-restricted.md` into a private project.
   Owner B indexes only `refund-policy-2026.md`.
5. Owner A invites member A. Member A signs up, lands in workspace A without admin access and gets
   403 on the user list and on the admin LLM endpoints. Owner A's user list shows member A; owner
   B's does not.
6. Member A asks Q1 to Q5 with the expected answers of the table above (as user A of
   `run_checks.py`). Owner A asks Q5 in the private project (as user B of `run_checks.py`).
7. Separation: owner B's chat answer to Q1 cites nothing, retrieves no company A document and says
   that the documents lack the information. Owner B's search for Q1 returns no company A document.
   Owner A's search returns no document id of company B (both companies have a file with the name
   `refund-policy-2026.md`, so the check compares document ids). Owner B and member A cannot read
   owner A's chat session; owner B cannot read owner A's user file. Connector and assistant lists
   do not cross.

`--after-restart` logs in with the stored accounts and repeats: identities and roles, the platform
model, the masked key, the 403 of member A, the chat session separation, a new "OK" chat, member
A's Q1 answer with its citation, the search separation and owner B's Q1 answer.

`--no-chat` (only with `--after-restart`) skips the three chat answers and prints one `SKIP` line
for each. The restore test (`saas-restore-test`) uses it: the restored copy has no platform key,
so no model answers there. The read checks still run.

`MODEL_API_KEY` (optional) is the platform key. The script never sends it and refuses a request
body that holds it. It checks that no response body of the whole run holds the key. Without it,
the run prints `SKIP the platform key appears in no response` and relies on the masked
`api_key` field. The log never shows an `api_key` value: the v4.8.4 mask keeps 8 characters.

The state file keeps the tag, the emails, the workspaces and the ids for `--after-restart`.

## Code Interpreter and Web Search test (multi-tenant stack)

`tools_check.py` is the acceptance test for the Python tool and the Web Search tool on `onyx-saas`
(`docs/product/MULTI-TENANT.md`, section 8). It reuses the accounts of the last `saas_journey.py`
run (owner A, member A, owner B from `--state`) and signs up one new company C with a new tag. It
configures no provider and no prompt. It only switches company C's Code Interpreter and web search
provider off and on again, and records both states.

```bash
MT_PASSWORD_SALT=... python3 product/test-corpus/tools_check.py \
  --base-url https://my-knowledge.duckdns.org --state journey_state.json \
  --tag tools-1a2b3c4d [--email-domain example.com] [--record tools_state.json]
```

`vm-bootstrap.sh saas-tools-check <sha>` runs it on the VM (workflow action `saas-tools-check`).
The output follows "Pass and fail" above, plus `INFO <name>: <json>` lines for evidence that is not
a check. Steps:

| Step | Checks |
| --- | --- |
| a | Owner C signs up (`owner-c-<tag>@example.com`) and is admin of a new company. Owners A, B and C: `GET /api/admin/code-interpreter` shows `enabled: true`, `GET /api/admin/code-interpreter/health` shows `connected: true`, `GET /api/tool` lists `PythonTool`, `WebSearchTool` and `OpenURLTool`, `GET /api/admin/web-search/search-providers` shows exactly one active provider "22nd X AI web search" with no visible key, and no content provider is active. |
| b | Member A uploads a generated CSV (12 rows, total 4,321.50, mean 360.125; computed in the test) with `POST /api/user/projects/file/upload`. The file must reach `COMPLETED` (or `SKIPPED`, stored without indexing). Member A asks for the total and the mean with `forced_tool_id` = `PythonTool` and the file in `file_descriptors`. The stream must hold `python_tool_start`, no error, and the answer both numbers (2 or 3 decimals, with or without a thousands separator). |
| c | Member A asks for `chart.png` and `result.csv`. `python_tool_delta.file_ids` must be non-empty. Member A downloads each file through `GET /api/chat/file/{id}` with status 200: one PNG (magic bytes) and one CSV with the region names. Owner B gets 403 or 404. Owner A's status (same company) is printed as `INFO`. |
| d | Owner B and owner C ask for the population of Iceland with `forced_tool_id` = `WebSearchTool`. The stream must hold `search_tool_start` with `is_internet_search: true` and `search_tool_documents_delta` documents with http(s) links. Every `[n]` in the answer must map to a `citation_info` packet and a document. The test fetches each cited link (15 s, browser user agent, redirects followed); at least one must answer below 400. One retry when no document comes back. |
| e | Owner B's recent files, owner B's chat session list and a search for the CSV marker show nothing of company A; owner B cannot read member A's chat session. Owner C generates a small file; owner A and member A get 403 or 404 for it. |
| f | Sandbox probes in company C, printed as `INFO` and checked: uid 65532, no `/var/run/docker.sock`, no environment name with `POSTGRES`, `S3_`, `FIREWORKS` or `SMTP`, no TCP connection to `1.1.1.1:80`. Then `while True: pass` must end within 90 s (time from `python_tool_start` to the next packet of another kind). |
| g | Owner C switches the Code Interpreter off (`PUT /api/admin/code-interpreter`) and deactivates the provider (`POST .../search-providers/{id}/deactivate`); the tool list hides both tools. The test prints an `INFO` line for the operator: the next platform defaults run must keep both choices. Then it switches both on again and verifies. |

`--record` (default `tools_state.json`) gets the ids, the chat sessions, the recorded states of
step g and the probe results. The test accounts are synthetic; the run prints their emails.

## UI evidence

`ui_evidence.mjs` takes browser screenshots of a deployed instance. It runs in
GitHub Actions through `.github/workflows/axi-ui-evidence.yml` (manual start,
inputs `base_url`, `mode`, `tag`, `login_email`). The run uploads the folder as
the artifact `ui-evidence-<mode>-<run number>` and lists the PASS and FAIL
lines in the step summary. The runner must reach `base_url`.

The script needs Node 22 and the `playwright` npm package with Chromium. Env:
`BASE_URL`, `OUT_DIR`, `TAG`, `PASSWORD` (never printed), `MODE`
(`single` or `saas`), `LOGIN_EMAIL` (single mode), `EMAIL_DOMAIN`
(default `example.com`).

- Public pages: `01-login.png`, `01b-login-phone.png` (390x844), `02-signup.png`.
  The script records `document.title` and checks that "22nd X AI" and the tagline
  "More growth. Less busywork." are visible.
- `MODE=saas`: signs up `owner-a-<tag>`, invites `member-a-<tag>`, visits the
  LLM settings, sends one chat message (`08-company-a-chat.png`, check
  `chat answered`), signs up `owner-b-<tag>` in a new context and checks that
  company B does not list company A, signs up `member-a-<tag>` and checks that
  the admin pages are blocked, then logs in as owner A again and checks that
  member A is listed (`14-company-a-users-after.png`).
- `MODE=single`: public pages, then login with `LOGIN_EMAIL` and screenshots
  `03` to `05`.

Each failed step saves `error-<step>.png`, prints `FAIL <step>: <reason>` and the
next step runs. The script exits with 1 when any step fails. The test accounts
are synthetic; the run prints their emails at the end.
