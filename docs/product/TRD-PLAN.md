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
