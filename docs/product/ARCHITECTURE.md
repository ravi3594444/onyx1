# Architecture: preserve Onyx, isolate our changes

Version 1.0 — 3 October 2026.

## Current design

Use the stock Onyx Standard application in our fork. Retain its existing frontend, backend, background processing and supported storage configuration.

Use the reviewed v4.8.4 release as a candidate baseline, not an instruction to reset the fork. Inspect the fork's actual revision, any existing changes, release notes and image availability before selecting the development baseline.

| Area | Responsibility | Our initial changes |
| --- | --- | --- |
| Existing frontend | Chat, search and owner/admin interface | Supported branding settings; narrowly scoped fixes only if needed |
| Existing backend | Authentication, retrieval and application APIs | Supported configuration; no planned custom core module |
| Existing workers/model services | Source sync, indexing and model tasks | Tune supported settings after measurement |
| Postgres | Application metadata and durable relational state | Preserve upstream schema and migrations |
| OpenSearch | Search/index storage in the reviewed Standard baseline | Supported configuration and persistent storage |
| Configured file store | Original uploaded files and application file objects | Durable location and recovery procedure |
| Deployment | Images, networking, secrets and service configuration | Small, versioned configuration overlay |
| Product documentation/assets | Requirements, architecture, plan, brand assets | Our isolated additions |

Redis is ephemeral in the reviewed default Compose configuration; verify session/job recovery behavior rather than treating it as a durable store.

## Codebase layout in the fork

Keep existing backend, web and deployment directories in place. Do not reorganize vendor code merely to make the repository look smaller.

Add only files that have a current purpose:

| Proposed path | Contents |
| --- | --- |
| docs/product/PRD.md | Product scope and acceptance |
| docs/product/ARCHITECTURE.md | Architecture and modification boundaries |
| docs/product/TRD-PLAN.md | Engineering plan, test evidence and agent instructions |
| product/branding/ | Actual approved assets, once supplied |
| product/deploy/ | Small overrides/runbook or release manifest, once required |

Do not create empty frameworks, speculative services or another database for this prototype. Do not duplicate upstream documentation; link it and record only our differences.

## Clean and compact rules

1. Prefer supported configuration over source changes.
2. Prefer one existing implementation over a duplicate custom implementation.
3. Keep each patch tied to a demonstrated issue or requirement.
4. Avoid mass formatting, dependency upgrades and unrelated refactors.
5. Keep business/branding settings out of search, ingestion and permission logic.
6. Preserve upstream authentication, document ACL checks and license enforcement.
7. Record every custom source patch with purpose, affected paths and validation.
8. Use existing libraries and conventions before adding dependencies.
9. Keep credentials and real customer data out of the public fork.
10. Remove unused product code, not upstream capabilities that have not been evaluated.

Directory separation alone does not guarantee conflict-free upgrades. Changes to existing files can conflict, and separate integrations can break when interfaces change.

## Branding boundary

Apply appearance settings through the existing interface/API under the selected entitlement. Store versioned brand assets separately and record how settings are applied.

If a required brand detail cannot be configured, identify its exact frontend location first. Make a small targeted patch; do not replace the interface or scatter repeated literals throughout the codebase.

Do not directly edit application database records or override enterprise loading merely to force a setting.

## Fork and upstream boundaries

origin is our fork. upstream is the official Onyx repository. Verify both before any push.

Our main branch holds our tested application state. Use focused working branches while developing, then integrate completed changes into our main according to the owner's instructions. Pushing to our main is supported, subject to repository rules; it does not push to the upstream repository.

Choose stable releases for upgrade evaluation. Test an upgrade on a branch before integrating it. Never force-reset our main to upstream or assume that a sync preserves custom changes automatically.

## Data and deployment boundary

Use stable Compose project names and persistent storage locations. Keep release image references pinned and record their source revisions. Container replacement must not delete volumes.

A supported VM resize can retain persistent storage, but interrupted/uncommitted work may fail. Restore capability, original file availability and job reconciliation are part of the architecture.

Application image rollback is safe only when storage schemas remain compatible. A migrated database/search index requires a coordinated recovery strategy.

## Future extensibility

If testing later establishes a need for our own API, MCP exposure or application connection panel, introduce it as an independently owned module/service through supported Onyx interfaces.

That is a future architecture decision, not scaffolding to build now. Do not assume that a new source can be added without connector or permission work.

## Scaling strategy

| Measured pressure | First response | Later response if warranted |
| --- | --- | --- |
| Memory/OOM during ingestion | Reduce supported ingestion concurrency; investigate process/container limits; add RAM | Isolate indexing/model workloads |
| CPU saturation and slow queries | Profile indexing versus query work; adjust concurrency; add CPU | Separate supported workloads |
| Disk growth | Expand storage safely; manage log/image retention without deleting data | Dedicated search/file storage |
| Slow source refresh | Inspect connector errors, limits and worker queues | Additional supported indexing capacity |
| Availability requirements | Test off-VM backup and restoration | Separate durable services and supported HA deployment |

Start with the owner's 4 vCPU/16 GB RAM/about 100 GB persistent SSD development budget for a small corpus. It is not a capacity guarantee. Onyx's published Standard minimum is 4 vCPU/10 GB RAM; preferred guidance is higher.

Collect peak RAM, per-service CPU, corpus size, queue age, ingestion duration, disk growth and query latency. Suggested initial investigation thresholds are sustained 80% memory pressure and 75% disk usage, adjusted after measurement.

Scale vertically first. Move to managed/distributed components or Kubernetes only when measured load or availability requirements justify the operational cost. Do not promise a fixed number of companies/users per VM.

## References

- [Resource guidance](https://docs.onyx.app/deployment/getting_started/resourcing)
- [Reviewed Compose source](https://github.com/onyx-dot-app/onyx/blob/v4.8.4/deployment/docker_compose/docker-compose.yml)
- [Fork behavior](https://docs.github.com/en/pull-requests/reference/forks)
