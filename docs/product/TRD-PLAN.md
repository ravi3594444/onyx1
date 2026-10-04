# Technical requirements and development plan

Version 1.0 — 3 October 2026.

## Authority and scope

Read PRD.md and ARCHITECTURE.md before implementation. These three files define the current prototype and supersede earlier automation/wrapper proposals.

The task is to run, test and brand the existing Onyx Enterprise application in our fork. It is not to recreate Onyx or build a new SaaS control plane.

## Phase 1: inspect and establish the baseline

- Verify origin points to the owner's fork and upstream to official Onyx.
- Read applicable AGENTS.md files and upstream setup instructions.
- Inspect the current branch/revision and existing owner changes.
- Select a stable source/image baseline and record exact versions.
- Check Standard deployment requirements and supported enterprise entitlement.
- Record required environment values without storing their secrets.
- Use only the supplied development target; if absent, establish local feasibility and report the specific infrastructure input needed.

Do not reset main, overwrite existing owner work, or upgrade unrelated dependencies.

Deliverable: reproducible setup notes and an evidence-based list of missing inputs.

## Phase 2: run the original application

Use the existing supported deployment. Verify service readiness, authentication, model connectivity and admin access before source changes.

Upload the PRD test corpus and connect one supported source. Establish two test user identities and exercise chat/search with citations.

When a capability is gated, record the required entitlement. Do not disable enforcement to make the test pass.

Deliverable: running baseline and functional test results.

## Phase 3: branding

Obtain the owner's name, logo assets, colours and domain. Apply supported appearance configuration first.

Verify the login, navigation, chat and admin screens on desktop and phone. If a setting cannot satisfy a requirement, propose and implement only the narrow source patch needed within authorized scope.

Deliverable: branded application, asset locations and a list of custom source changes.

## Phase 4: persistence and operating checks

Restart application containers and confirm durable documents/files/chat state remain usable. Validate source update/deletion behavior for the chosen connector.

Create an off-VM backup and restore it to an isolated test environment, or prove a supported reindex path from backed-up originals. Do not expose restored customer credentials or activate real outbound connections in tests.

Record observed recovery behavior and interrupted-job handling. Do not claim zero data loss from arbitrary OOM, restart or resize events.

Deliverable: persistence evidence, restore procedure and baseline resource measurements.

## Phase 5: minimal CI/CD after the baseline works

Review existing fork workflows before adding another pipeline.

Initially, CI runs relevant upstream checks and validates our changed files/configuration. Build the exact tested revision. Add a deployment workflow only once the target, secrets and pinned artifacts are configured.

Commits to our main can automatically deploy to the development target after required checks pass. Production activation is a later, licensed launch step.

Stable upstream releases create tested upgrade candidates; they do not silently deploy every upstream commit. Keep migration and configuration review in the upgrade process.

Deployments must preserve data volumes, serialize per target and verify health. Image recovery must respect database/index compatibility.

Deliverable: one understandable CI path and one development deployment path, without duplicated vendor pipelines.

## Minimum functional checks

| Test | Required evidence |
| --- | --- |
| Authentication | Correct users authenticate; unauthorized admin operations are denied |
| Search/answer | Representative questions return relevant source-backed results |
| Missing information | Behavior is documented; unsupported answers are identified |
| Citations | Cited sources correspond to the answer evidence |
| Source update/deletion | Changes propagate as documented for that source |
| Privacy | A cannot read B's private chats or restricted documents |
| Branding | Agreed identity appears in the selected screens; missing settings are explicit |
| Restart | Durably stored state remains accessible |
| Restore | Backed-up data supports representative search/chat after recovery |
| Resources | Peak memory, CPU, disk and ingestion/query timings are recorded |

Use upstream tests and focused behavior tests where required. Do not add a large suite that merely asserts that branding literals exist.

## Engineering constraints

- Preserve core modules and directory structure.
- Use small commits with one clear purpose.
- Avoid duplicate abstractions, helper layers without a current caller, and broad cleanup.
- Use supported configuration and existing dependencies.
- Maintain a concise custom-change register in the runbook.
- Keep secrets and real customer data out of source control.
- Keep existing auth, ACL and license checks effective.
- Do not introduce wrapper APIs, MCP servers, approval workflows, payment systems or new databases in this stage.
- Record real blockers and failed checks; never claim an unexecuted test passed.

## Repository workflow

You may push to main in your own fork when that is the owner's instruction and repository rules permit it. Push only to the verified fork remote.

For reviewable development, use a focused working branch and integrate tested work into our main. A pull request is optional unless the owner's instructions or repository rules require one.

Future upstream upgrades use an upgrade branch. Fetch and compare the selected release, preserve our changes, resolve conflicts deliberately and validate migration requirements. Do not force-reset our fork.

## Copyable agent prompt

```text
Work on my Onyx fork. Read docs/product/PRD.md,
docs/product/ARCHITECTURE.md and docs/product/TRD-PLAN.md,
then applicable AGENTS.md and upstream setup instructions.

First verify the repository remotes, current revision and existing changes.
Run and test the original application before changing its source.
Use a recorded stable baseline and a supplied development target.

Our scope is the existing knowledge base with our branding:
existing chat/search, documents, one supported connector, source citations,
two-user permission checks and durable storage.

Use existing appearance settings first. Obtain missing brand inputs.
Keep auth, document ACLs and license enforcement intact.
Record any trial/development entitlement needed for gated features.

Preserve upstream directories and modules. Make only small, necessary changes.
Do not build wrapper APIs, MCP services, billing, approval queues, ERP/CRM
workflows, another admin application or speculative scalability modules.

Test document ingestion, citations, updates/deletion, privacy, restart and
isolated restoration. Measure CPU, RAM, disk and ingestion/query latency.
Use focused checks appropriate to actual changes.

Once the baseline works, review existing CI and add only the minimal
development pipeline needed. Pin tested releases and preserve data volumes.
Respect the owner's branch/push instructions; push only to the verified fork.

Complete the authorized work and report what runs, what changed, actual
test results, resource measurements and specific remaining blockers.
Do not report unexecuted tests as passed.
```

## Start inputs

Fork URL; development execution target; model credentials supplied securely; enterprise development entitlement where needed; and branding assets.

Missing branding should not prevent baseline inspection/testing. Missing a deployment target should not cause an unrelated production VM to be reused.

## Completion report format

- Selected source revision and image versions.
- Setup/start commands and safe configuration instructions.
- Changed files and the reason for each source patch.
- Executed tests and results.
- Baseline resource measurements and scaling recommendations supported by them.
- Restore/recovery procedure and its observed limitations.
- Remaining inputs or verified feature gaps.

## Baseline evidence (sandbox run, 3–4 October 2026)

This section records the first run. The procedure is in `product/deploy/RUNBOOK.md`.

### Environment

- Target: Claude Code cloud sandbox, 4 vCPU, 15.7 GB RAM, about 40 GB disk allowance.
  The owner's development VM was not supplied. These numbers show feasibility only.
- Release: upstream `v4.8.4` (`d15d445`), images pinned by digest.
- Containers had no internet access. The model server images contain the embedding model,
  so indexing worked offline.
- No model credentials were supplied. A local stand-in model (Qwen3-4B, Q4_K_M, llama.cpp,
  CPU only) served as an OpenAI-compatible provider. Its answer quality and speed do not
  represent a production provider.
- Sandbox-only adjustments, not for the VM: lower OpenSearch ulimits (host limits),
  absolute OpenSearch disk watermarks (the VM reports a 252 GB disk with a small allowance).

### Results

| Check | Result | Evidence |
| --- | --- | --- |
| Installation | Pass | `make-env.sh` and `docker compose up -d`: 10 services healthy in about 2 minutes |
| Authentication | Pass | Register 201, login 204, wrong password 400. Basic user gets 403 on admin APIs. Anonymous gets 403. |
| Search and answer | Partial | Search ranks the expected document first for Q1–Q3. Chat with the stand-in model: Q1 correct with citation; Q2 and Q3 answered without calling Search, also with Search forced. Retest with the production model. |
| Missing information | Pass with note | Q5 for a user without access: "no information", no leak. Q4: the stand-in model did not search and gave a generic reply without a company policy. |
| Citations | Pass | Q1 cites `expense-policy.md`. Bob's Q5 cites `hr-salary-bands-restricted.md`. Citations are stored with the chat. |
| Source update | Pass | File replaced through `/files/update`: re-indexed in 28 s; search shows the new hours only. |
| Source deletion | Pass | File removed: gone from search in 6 s. |
| Privacy | Pass (Community scope) | Alice gets 403 on Bob's chat. Bob's project file never appears in Alice's or the admin's search. |
| Group-restricted document | Blocked | User groups need the Business plan (HTTP 402). |
| Branding | Blocked | Enterprise settings need the Business plan (HTTP 402). Assets and script are ready. |
| Restart | Pass | Host restart: all containers returned. `down` and `up`: healthy in 98 s; documents, files, chats, citations and settings intact. Redis restart signs users out. |
| Restore | Pass | Cold backup (81 s downtime, 7.5 MB). Restore into a separate project on port 3100: healthy in 87 s. Search, old chats, privacy and new cited answers work. |
| Desktop and phone | Pass | Login, chat, admin connector pages render at 1280×800 and 390×844. |

### Resources

| Measure | Value |
| --- | --- |
| Onyx RAM, all services, no LLM | Peak 8.9 GiB, median 6.3 GiB |
| Largest services | OpenSearch 2.7 GiB (2 GB heap), background workers 2.4 GiB, model servers 1.3 + 1.1 GiB |
| Onyx CPU | Median 10 % of one vCPU; 4 vCPU saturated during indexing and model warm-up |
| Local stand-in LLM | Up to 5.2 GiB RAM and all 4 vCPU |
| Disk | Images about 19.5 GB; model caches 1.1 GB; data for this corpus under 70 MB |
| Ingestion | 4 files: 107 s on the first run (includes warm-up); 1 changed file: 28 s |
| Search latency | 0.35–0.53 s warm; 49 s for the first query after a restart |
| Chat latency | 11–280 s with the CPU stand-in model; not representative |

Recommendations from these numbers: 16 GB RAM is enough for this corpus with a hosted model
provider. Do not run a local LLM on the same 4 vCPU VM. Keep at least 30 GB free for images
and growth. Measure again with the real corpus before changing the VM size.

### Remaining inputs

1. A Business license (trial or development) for branding and user groups.
2. Model provider credentials.
3. The development VM, and the domain for the app.
4. Decision on brand colours: these need our own web image (see `product/branding/README.md`).

### Re-run with exit codes (4 October 2026)

`run_checks.py`, `backup.sh` and `restore.sh` fail the command when a check fails. The runs
below used them against the live sandbox stack. The untrimmed output is in
`product/test-corpus/evidence/*.txt`. Each log names its commit and records every exit code.

Full run with the stand-in model (`2026-10-04-sandbox-run.txt`, commit `856785a`):

| Step | Exit code | Checks |
| --- | --- | --- |
| index | 0 | 2 of 2 pass |
| search | 0 | 8 of 8 pass, including the owner control: user B finds the restricted file, user A and the admin do not |
| chat | 1 | 3 of 6 pass (Q1, Q5 for user A, Q5 for user B). Q2, Q3 and Q4 fail: the stand-in model does not search, or answers in general terms. |
| chat-forced | 1 | 2 of 5 pass (Q1, Q5). Same Q2, Q3 and Q4 failures. |
| privacy | 0 | 7 of 7 pass |
| update | 1 | Re-index and search pass. The model answer for Q2 fails. |
| delete | 1 | Deletion reaches search. The model answer for Q3 fails. |

Model-free run, the same steps as CI (`2026-10-04-sandbox-run-skip-chat.txt`, commit `b0d7ba6`):
index, search, privacy, update and delete all exit 0. 23 checks pass and 2 model answers are
`SKIP`. The update step waits for its prune (see below).

Backup and restore (`2026-10-04-sandbox-backup-restore.txt`, commit `0525118`; these scripts did
not change after it):

| Test | Exit code | Result |
| --- | --- | --- |
| T1 backup with a forced copy failure | 1 | Stack started again (11 containers, health 200). No backup folder, no partial folder. |
| T2 backup | 0 | 86 s downtime. All files mode 600. |
| T3 restore into the live project | 1 | Refused: the project has containers. Live volume unchanged. |
| T4 restore with a different `.env` | 1 | Refused. No volumes created. |
| T5 MinIO root password differs from `S3_AWS_SECRET_ACCESS_KEY` | 1 | Refused before `.env` was written. No volumes. |
| T6 secret exported in the shell | 1 | Refused. No volumes. |
| T7 isolated restore on port 3100 | 0 | Healthy in 51 s. `background` not started. `search` (8 of 8) and `privacy` (7 of 7) exit 0 on the copy. |

Whole-connector deletion (`2026-10-04-sandbox-connector-delete.txt`): pause plus
`deletion-attempt` removed each test connector. The cc-pair returned 404 after 3 to 20 s, and
search then returned no documents.

### CI on GitHub

The owner enabled Actions on 4 October 2026. Results of `axi-product-ci.yml` on this branch:

- Static checks and compose config passed on every push run after the first one.
- Run #6 failed the `ruff-format` check on a checkpoint commit. The next commit fixed it.
- Run #3 (manual e2e) was cancelled by a push. The workflow now groups manual runs apart.
- Run #8 (manual e2e) failed in `delete`: the removed file stayed in search for 900 s. Cause,
  from the Onyx logs: the update step's prune still ran, and Onyx v4.8.4 then starts no prune
  for removed files ("Failed to trigger pruning", HTTP 200). The update step now waits for its
  prune. RUNBOOK section 7a tells operators how to handle this.
- Run #11 (manual e2e, commit `b0d7ba6`): **passed**, 8 minutes in total
  (https://github.com/ravi3594444/onyx1/actions/runs/37195235054). Stack start 2 min 42 s;
  index, search, privacy, update and delete with `--skip-chat` 1 min 13 s; backup and isolated
  restore 2 min 23 s; search on the restored copy 15 s.

## Development VM evidence (4 October 2026)

The first installation on the development VM ran through the workflow `axi-bootstrap-dev.yml`
(RUNBOOK section 11). The job logs are in `product/test-corpus/evidence/2026-10-04-vm-*.txt`.
The VM also keeps a copy of each run in `/srv/onyx/evidence/<time>/`.

### Environment

- VM `instance-20261004-101329`, Ubuntu 22.04.5, 6 vCPU, 15 GiB RAM, 97 GB disk, no swap.
- Onyx v4.8.4 (tag commit `d15d445`), image digests from `release.env`. Docker Engine from the
  official apt repository. `vm.max_map_count=262144` through `/etc/sysctl.d/99-onyx.conf`.
- URL: https://my-knowledge.duckdns.org (Let's Encrypt, production CA, renewed by the `certbot`
  service every 12 h). Plain HTTP answers a 301 to HTTPS. Deployed commit at the end of the
  day: see the last table.
- License enforcement stays on. No Business license, no model provider and no branding yet.

### Runs

| Run | Action | Commit | Result |
| --- | --- | --- | --- |
| 2 | install | `f03e162` | PASS. 11 containers healthy, `/api/health` 200 (`...vm-install-run2.txt`). |
| 3 | verify | `f03e162` | 10 of 11 steps PASS. `restore` FAIL: the deploy user could not create `/srv/onyx-restore`. Fixed in `3d5843a` (`...vm-verify-run3.txt`). |
| 4 | https-staging | `bc1e398` | PASS with a staging certificate (`...vm-https-run4-staging.txt`). |
| 5 | https | `d840c58` | FAIL: the TLS check ran before nginx had reloaded. Fixed in `be37356` (`...vm-https-run5-failed.txt`). |
| 6 | https | `67c5e58` | PASS: production certificate (`...vm-https-run6.txt`). The 200 that this run and run 4 reported for `/api/health` was a redirect loop; see run 9. |
| 7 | verify | `67c5e58` | `restore` PASS. All checks FAIL with 403 after login: with `WEB_DOMAIN=https://...` the session cookie is `Secure`, and Python did not send it over `http://localhost`. Fixed in `43859e1`. |
| 8 | verify | `43859e1` | FAIL before the first check: `https://<domain>/api/health` answered no 200 from the VM (the redirect loop). |
| 9 | verify | `6fdf922` | All 14 functional steps PASS, including backup and the isolated restore. The new `public-url` step FAIL with the diagnosis: the upstream HTTPS block proxies to `localhost:80` with the domain as Host, and the redirect block answered 301. Fixed in `988982d` (`...vm-verify-run9.txt`). |
| 10 | restart | `6fdf922` | `down`, `up -d`, health, the same 10 volumes, `search` 8 of 8 and `privacy` 7 of 7 PASS after the full recreate of all containers. `public-url` FAIL with the same redirect loop (`...vm-restart-run10.txt`). |
| 11, 12 | https | `988982d`, `2d21a28` | Cancelled by us: with the redirect block on the container address, the loopback health check saw only redirects and waited 15 minutes. Fixed in `090d600`: the checks use the public HTTPS URL. |
| 13 | https | `090d600` | FAIL: Docker had created an empty directory where the new `render-redirect.sh` bind mount pointed. Fixed in `d5a6f09`. |
| 16 | owner | `d2561f1` | PASS: `ravi80847949@gmail.com` had an account with basic permissions; the supported admin API granted admin access, read back as `is_admin: true`. 4 accounts, 2 admins, 0 pending invitations (`...vm-owner-run16.txt`). |
| 17 | https | `d5a6f09` | HTTPS 200 with the real check, but `http://` answered 200: nginx still ran with its old command. Fixed in `49f3973` (force-recreate nginx). |
| 18 | owner | `d5a6f09` | PASS: invite-only sign-up on (`invite_only_enabled` false to true), owner already admin (`...vm-owner-run18.txt`). |
| 19 | https | `49f3973` | PASS: redirect block on `172.18.0.12:80` only; `https://<domain>/api/health` and `/nginx-health` 200 (Let's Encrypt production, `CN=YE1`); `http://<domain>/` 301 (`...vm-https-run19.txt`). |

### Results on the VM (run 9, commit `6fdf922`)

| Check | Result |
| --- | --- |
| Startup | PASS. `install` and every `live-start` reached `/api/health` 200 within 2 minutes. |
| Index | PASS. 4 public documents and 1 private project file indexed. |
| Search | PASS, 8 of 8. Q1 to Q5 return the expected top file. User B finds the restricted file; user A and the admin do not see the marker and get public documents. |
| Permissions | PASS, 7 of 7. Cross-user chat session 403 "Access denied"; project and file lists hide the other user's data. |
| Update | PASS. Re-index, prune and search show the new support hours only. Model answer skipped (no model). |
| Deletion | PASS. The removed 2025 refund policy leaves search in about 5 s. Model answer skipped. |
| Pruning race | Reproduced: a file removed during a running prune stays in search after 60 s and no second prune starts. The supported manual prune (`POST .../cc-pair/<id>/prune`) removes it in about 20 s. 6 of 6 checks PASS. The race itself is Onyx behaviour and stays open; the workaround is in RUNBOOK section 7a. |
| Backup | PASS. 87 s downtime, SHA256SUMS verified by the restore. |
| Isolated restore | PASS. Port 3100 healthy in about 50 s; `search` 8 of 8 and `privacy` 7 of 7 on the copy; live stack started again afterwards. |
| Restart | PASS (run 10). `docker compose down` then `up -d`: all containers recreated in about 2 minutes, the 10 named volumes unchanged, indexed documents and access rules intact (`search` 8 of 8, `privacy` 7 of 7). Sessions live in Redis and end with a restart. |
| Public HTTPS URL | PASS (run 19). Trusted certificate, 200 over HTTPS, 301 from plain HTTP. The certbot service renews every 12 h; nginx reloads every 6 h. |
| Chat and citations | BLOCKED: no model provider credentials. |
| Branding | BLOCKED: no Business license. License enforcement stays on. |

### Resources (run 9, after the checks, idle)

`docker stats`: OpenSearch 2.5 GiB, background 1.8 GiB, api_server 0.6 GiB, two model servers
0.3 GiB each, MinIO 0.2 GiB, Postgres 0.1 GiB, nginx, Redis and certbot under 10 MiB each.
Host: 6.5 GiB used of 15.6 GiB, 23 GB disk used of 97 GB. CPU idle below 10 % per container.

### Owner and team (4 October 2026, afternoon)

- Owner `ravi80847949@gmail.com`: admin access granted through `PATCH /api/manage/admin/users/admin-access`
  (run 16). Password unchanged. The synthetic admin `admin@example.com` of the checks stays as the
  recoverable administrative account.
- Invite-only sign-up: on (run 18). It is the Community workspace setting `invite_only_enabled`
  (`PATCH /api/admin/settings`); existing accounts keep logging in, new sign-ups need an invitation.
- Invitations: `PUT /api/manage/admin/users` records the invitation and reports
  `email_invite_status`. With no SMTP settings the status is `NOT_CONFIGURED` or `DISABLED`: no
  email goes out. The `smtp` action of the workflow writes `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USER`,
  `SMTP_PASS`, `SMTP_STARTTLS`, `EMAIL_FROM` and `ENABLE_EMAIL_INVITES=true` into `.env` from the
  `ci-protected` secrets. BLOCKED until the secrets exist.
- Enterprise evaluation mode: v4.8.4 treats `LICENSE_ENFORCEMENT_ENABLED=false` with
  `ENABLE_PAID_ENTERPRISE_EDITION_FEATURES=true` as tier ENTERPRISE without a license
  (`backend/ee/onyx/utils/tier.py:71-100`; upstream uses it in `docker-compose.search-testing.yml`
  and its CI). The code comments call it a legacy development mode that will go away. It works by
  switching license enforcement off, which this project keeps on. Not applied. See
  `docs/product/FEATURE-STATUS.md` for the per-feature status.

### Remaining inputs

1. `MODEL_API_KEY` as a `ci-protected` secret: unblocks the `model` action, `chat`, `chat-forced`
   and the model answers of `update` and `delete` (`verify-with-chat`).
2. `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `EMAIL_FROM` as `ci-protected` secrets, and
   one authorized recipient: unblocks invitation emails and their delivery evidence.
3. A Business license: unblocks native branding, user groups, permission sync, query history and
   service-account API keys. Not requested in this pass; the web image carries the branding.
