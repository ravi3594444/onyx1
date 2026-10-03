# Product requirements: branded company knowledge base

Version 1.0 — 3 October 2026.

## Goal

Run and validate our fork of Onyx Enterprise, then present it under our brand. Give a company a working place to add knowledge, search it, and ask questions with source citations.

This first version uses the existing application and owner/admin interface. It establishes what already works before choosing additional features.

## Initial users and workload

One test organization with one administrator and one or two authenticated users. Begin with a small synthetic document set and one supported connector. Corpus growth is measured, not assumed.

## In scope

| Requirement | Acceptance |
| --- | --- |
| Reproducible installation | A recorded release/commit and supported configuration start successfully on the development target. |
| Original interface | Existing chat, search and admin screens operate without a replacement frontend. |
| Knowledge ingestion | Sample files index; one supported connector completes a sync; failures are visible. |
| Grounded answers | Representative questions return relevant answers and inspectable citations. Missing information is handled without claiming unsupported certainty. |
| Data updates | A modified or removed source is reflected according to the connector's documented sync/deletion behavior. |
| Access controls | Different test users can access only their permitted documents and private chat state. |
| Branding | Agreed name, logo, colours and domain are applied through supported settings wherever available. |
| Persistence | Restarting application containers preserves documents, files and chat state that the system durably stores. |
| Usable interface | Key workflows are checked on desktop and phone; no broad redesign is required. |

Brand name, logo assets, domain and final colour choices remain owner inputs. Until supplied, retain existing settings rather than inventing a permanent identity.

## Development entitlement

The enterprise license permits development/testing without a subscription. Some features still require a valid entitlement to activate; use an appropriate trial/development license where needed. Keep enforcement intact.

Before real customer production use, obtain the commercial rights and seat coverage appropriate to our hosting/branding/distribution model. Do not equate an unpaid operational pilot with unrestricted development use.

## Deferred scope

A separate admin application, wrapper API, MCP server, embeddable widget, billing, workflow engine, approval queue, ERP/CRM automation, new connectors and shared multi-company tenancy.

These can be assessed after testing the base product. Their possible future value does not make them first-version requirements.

## Test corpus

Include a short policy, a product guide, conflicting versions of a sample document, a question with no answer in the corpus, and a document intended for a restricted test user.

Evaluate normal questions, missing information, citations, updates, deletion and unauthorized requests. Record expected source evidence; do not assume every plausible generated answer is correct.

## Definition of done

- Selected source revision, commands, configuration requirements and entitlement status are recorded.
- Existing application runs and its critical workflows pass the functional checks.
- Branding is applied or an exact supported-feature/input blocker is documented.
- A restart and isolated restore/reindex test demonstrate the persistence/recovery path.
- Baseline CPU, RAM, disk, ingestion time and query latency are recorded.
- Necessary custom changes are small, documented and reviewable.
- Real missing features are listed separately with evidence from testing.

A prototype can be functionally ready without being commercially launch-ready. Production licensing, operating procedures and customer isolation are launch prerequisites.

## References

- [Onyx](https://github.com/onyx-dot-app/onyx)
- [Enterprise license at reviewed baseline](https://github.com/onyx-dot-app/onyx/blob/v4.8.4/backend/ee/LICENSE)
- [White labeling](https://docs.onyx.app/admins/advanced_configs/white_labeling)
