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
