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
