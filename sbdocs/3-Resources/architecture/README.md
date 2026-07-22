---
title: "Architecture Docs — MOC"
type: index
status: active
version: both
scope: architecture
updated: 2026-04-26
tags: [moc, index, architecture]
---

# Architecture Docs — MOC

Long-lived structural references for the SiteBoss OWL / WMS platform. Every doc here is **code-grounded** — claims tied to file paths + line numbers — and has a 60-day `last_verified` cadence.

See also: [vault index](../../INDEX.md) · [architecture template](../../9-System/templates/wms-architecture-template.md) · [symptom index](../../_symptom-index.md) · [v2 function-to-docs map](./wms2-function-to-docs-map.md) · [v1 function-to-docs map](./wms1-function-to-docs-map.md)

---

## 1. How to read this folder

Docs cluster into three groups:

- **Subsystem** — one specific cross-cutting concern of `wms2-api` (transactions, state, multi-tenancy, scheduled jobs). Written in response to recurring bug classes in the archive.
- **Cross-cutting** — span multiple projects (frontend + backend + 3rd-party systems).
- **Meta / catalog** — cross-reference indexes and compare-across-versions.

Start in the group that matches your task; each doc has its own "How to use" table near the end.

---

## 2. Subsystem docs

| Doc | Scope | Read when… |
|---|---|---|
| [wms1-transaction-boundary-map.md](./wms1-transaction-boundary-map.md) | v1 TX strategy (class vs method), OSIV-on consequences, `REQUIRES_NEW` inventory, cross-service call map, locking, post-commit hooks | v1 `@Transactional` edits; silent-rollback / pool-exhaustion / OMS-notification-drop debugging; porting v1 code to v2 |
| [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) | TX managers, `@Primary` landmine, OSIV, `@Version` / `@Lock` inventory, retries | `@Transactional` edits; optimistic-lock / pool-exhaustion / "wrong-DB-wrote" debugging |
| [wms1-tenant-routing-datasource-topology.md](./wms1-tenant-routing-datasource-topology.md) | v1 deployment-per-tenant model, single static HikariDS, `facility_code` body validation, v1-vs-v2 differences | v1 "wrong facility_code" OMS errors; connection-pool exhaustion; v1→v2 migration planning |
| [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md) | `TenantContext`, `TenantFilter`, per-tenant Hikari, multi-DB routing, pool eviction | `@Async` additions; PgBouncer rollout planning; "data from wrong tenant" bugs |
| [wms1-state-machine-catalog.md](./wms1-state-machine-catalog.md) | v1 entity state machines — state constants, transition sites, cascade chains | `setState(...)` edits on v1 entities; stuck-state / wrong-cascade bugs; porting v1 state logic to v2 |
| [wms2-state-machine-catalog.md](./wms2-state-machine-catalog.md) | 9 entities × 160 state-write sites, cascades, `CANCELED`/`CANCELLED` spelling | `setState(...)` edits; stuck-state / wrong-cascade bugs; PR review on `CustomerorderService` / `PickingorderBusinessService` |
| [wms1-scheduled-jobs-catalog.md](./wms1-scheduled-jobs-catalog.md) | v1 cron jobs — triggers, advisory locks, gates | Adding or modifying v1 scheduled tasks; cross-replica mutex debugging |
| [wms2-scheduled-jobs-catalog.md](./wms2-scheduled-jobs-catalog.md) | 5 business cron jobs + 2 infra `@Scheduled` methods, advisory-lock IDs, gates | New cron job; `app.cron` enablement; cross-replica mutex debugging |
| [wms2-caching-strategy.md](./wms2-caching-strategy.md) | Caffeine cache inventory (4 caches), TTLs, multi-tenant key isolation, all `@Cacheable`/`@CacheEvict` sites, known invalidation gaps, safe modification patterns | Any edit to a service that reads or writes `sysprops`, `clients`, `locations`, or `itemdata`; cache-staleness bug investigation; adding a new cached read or eviction |
| [wms-database-migration-guide.md](./wms-database-migration-guide.md) | Flyway versioning conventions, safe DDL patterns, lock risks, native-query sweep, multi-tenant apply, rollback strategy — covers both v1 and v2 | Writing any migration that touches a live table; schema change review; onboarding a new dev to migration practices |
| [wms2-greenfield-db-provisioning.md](./wms2-greenfield-db-provisioning.md) | Standing up a brand-new client DB directly on v2 — why replaying the 23 historical scripts yields the wrong (pre-UTC) state, the consolidated `V2.0.00` baseline approach, client-config seed, sequencing vs the UTC work | Onboarding a greenfield client; deciding new-DB vs migration path; designing the squashed baseline |
| [wms2-database-setup-guide.md](./wms2-database-setup-guide.md) | **Entry point** for provisioning a v2 tenant DB — the two paths (fresh-start Flyway base dump in `db/migration/` vs the v1→v2 onboarding toolkit in `db/v1-to-v2-onboarding/`), when to use each, the `V2.1.16` watermark convergence, and links to the per-client runbooks | "How do I set up a v2 database?"; choosing fresh-start vs migration; understanding the post-#71 `db/` layout |
| [wms-exception-taxonomy.md](./wms-exception-taxonomy.md) | Full exception hierarchy for v1 + v2 — class diagram, HTTP status mapping, rollback matrix, i18n / message keys, OMS `/rest/` contract, decision guide, v1 vs v2 delta | Adding a new error condition; choosing the right exception type; checking whether rollbackFor is needed; adding a localized message key |

---

## 3. Cross-cutting docs

| Doc | Scope | Read when… |
|---|---|---|
| [wms1-oms-integration-map.md](./wms1-oms-integration-map.md) | Every `/rest/**` endpoint OMS calls into v1/wms-api (5 controllers, 12 endpoints) + every WMS→OMS HTTP callback (12 outbound calls), payload shapes, deferred vs synchronous, failure modes | OMS→WMS call fails; a WMS callback is missing from OMS; adding a new integration point; diagnosing `Message` table FAILED rows |
| [wms2-oms-integration-map.md](./wms2-oms-integration-map.md) | All inbound REST endpoints OMS calls into v2/wms2-api (5 controllers, 15 endpoints) + all outbound callbacks WMS2 fires to OMS (16 calls), sysprop keys, default URLs, triggering methods, `WEBSERVICE_BEHAVIOUR` switch, v1 vs v2 delta, failure modes | OMS→WMS2 call fails; expected WMS2 callback not received by OMS; adding a new integration point; diagnosing `Message` table FAILED rows in v2 |
| [wms1-end-to-end-request-journey.md](./wms1-end-to-end-request-journey.md) | 10-step walk of a request through v1/wms-api — mobile UI → Nginx → Spring Security → tenant routing → service → response | Auth / 403/422/500 debugging in v1; onboarding; porting v1 request path to v2 |
| [wms2-end-to-end-request-journey.md](./wms2-end-to-end-request-journey.md) | 10-step walk browser → Nuxt plugins → Keycloak → axios → `TenantFilter` → routing DS → response → token refresh | Auth / tenant-mismatch / "why is the wrong data showing" bugs; onboarding a full-stack engineer |
| [wms2-keycloak-role-matrix.md](./wms2-keycloak-role-matrix.md) | 51 realm-role constants + composite roles + group paths, per-page gates | Security audits; role provisioning; new admin page |
| [wms1-function-permission-map.md](./wms1-function-permission-map.md) | All 76 v1 FunctionEnum constants — DB model, runtime check pattern, default role-to-function seed matrix, admin bypass, v1 vs v2 delta | Debugging access-denied errors in v1; adding a new v1 endpoint with a permission check; auditing which role grants a function |

---

## 4. Meta / catalog docs

| Doc | Scope | Read when… |
|---|---|---|
| [wms2-function-to-docs-map.md](./wms2-function-to-docs-map.md) | Every ~45 user-facing function → UI + role + endpoint + canonical doc | Support triage entry; coverage audit; "does X have a doc?" |
| [wms1-function-to-docs-map.md](./wms1-function-to-docs-map.md) | Every v1 user-facing function → UI page + role + endpoint + canonical doc | v1 support triage; coverage audit; pre-work doc lookup for v1 bug fixes |
| [wms1-vs-wms2-delta.md](./wms1-vs-wms2-delta.md) | 16-section diff of v1 vs v2 architecture, data, jobs, roles; porting checklist | Porting a v1 fix; weekly sync sweep; onboarding to the versioning story |
| [wms1-entity-enumeration-report.md](./wms1-entity-enumeration-report.md) | All 55 v1 entities — table names, FK Long fields, state fields, domain groups, state constants | v1 schema questions; tracing a FK chain; understanding v1 vs v2 entity differences |
| [wms1-java-package-analysis.md](./wms1-java-package-analysis.md) | Package topology across `v1/wms-api` | Understanding v1 code layout; finding a class; v1→v2 porting |
| [wms2-entity-enumeration-report.md](./wms2-entity-enumeration-report.md) | Every entity + field catalog (imported report) | Field-level questions; schema planning |
| [wms2-java-package-analysis.md](./wms2-java-package-analysis.md) | Package topology across `v2/wms2-api` (imported report) | Understanding code layout; finding a class |

---

## 5. Dataview — stale architecture docs

```dataview
TABLE scope AS "Scope", version AS "Version", last_verified AS "Last verified", updated AS "Updated"
FROM "3-Resources/architecture"
WHERE type = "architecture" AND last_verified AND (date(today) - date(last_verified)) > dur(60 days)
SORT last_verified ASC
```

```dataview
TABLE scope AS "Scope", version AS "Version", last_verified AS "Last verified"
FROM "3-Resources/architecture"
WHERE type = "architecture"
SORT last_verified DESC
```

---

## 6. Conventions

- **`type: architecture`** — mandatory on any new doc here.
- **`scope:`** — one of the canonical values in [_tags.md §2](../../_tags.md). Don't invent new scope values unless you've exhausted the existing ones.
- **`last_verified:`** — every architecture doc carries a `last_verified` date and a `**Re-verify every N days.**` note at the end. Default to **60 days** for structural concerns, **90 days** for catalogs / reports that change slowly.
- **Code-grounded claims only.** Every assertion about the code should cite a file path + line number. If you can't cite it, don't assert it.
- **Cross-link** via `related:` frontmatter to any other architecture / workflow / data-dictionary doc the subject touches.

---

## 7. Adding a new architecture doc

1. Start from the [wms-architecture-template.md](../../9-System/templates/wms-architecture-template.md) template.
2. Pick `scope:` from [_tags.md §2.1](../../_tags.md).
3. Fill frontmatter, especially `last_verified` + `verified_by`.
4. Include: Overview → Topology diagram → Configuration facts → Deep dive → Known Landmines → How to use → Verification Log.
5. Add a row in §2, §3, or §4 above.
6. If the new doc implicates new code paths, update [_symptom-index.md](../../_symptom-index.md).
