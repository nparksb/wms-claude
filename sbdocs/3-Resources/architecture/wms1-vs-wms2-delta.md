---
title: "WMS v1 vs v2 — Architectural Delta"
type: architecture
status: active
version: both
scope: v1-v2-delta
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-06
verified_by: code read of v1/wms-api + comparison against v2/wms2-api + architecture docs
related:
  - ../../2-Areas/wms-v1-v2-sync/README.md
  - ./wms2-transaction-osiv-boundary-map.md
  - ./wms2-state-machine-catalog.md
  - ./wms2-tenant-routing-datasource-topology.md
  - ./wms2-scheduled-jobs-catalog.md
  - ./wms2-keycloak-role-matrix.md
  - ../data-dictionary/wms2-sysprop-catalog.md
  - ../data-dictionary/wms2-landlord-vs-tenant-entity-map.md
tags:
  - architecture
  - both
  - v1-v2-delta
  - wms1
  - wms2
---

# WMS v1 vs v2 — Architectural Delta

**Scope:** Every load-bearing difference between `v1/wms-api` and `v2/wms2-api` · **Version:** both
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

This doc records **only the differences** between v1 and v2. The 11 v2 architecture and data-dictionary docs apply to v1 nearly verbatim *except* where noted here. When porting a v1 fix to v2 or vice versa, read the relevant v2 doc first, then consult the matching section below for the divergence you'll hit.

One framing fact to anchor every section: **v1 is single-tenant; v2 was retrofitted for database-per-tenant multi-tenancy.** Most substantial deltas trace back to that retrofit.

Related: the v1→v2 sync workflow at [2-Areas/wms-v1-v2-sync/README.md](../../2-Areas/wms-v1-v2-sync/README.md) — update this delta doc as part of every sync sweep.

---

## 2. Stack delta

**MOSTLY-SAME — different language / framework majors.**

| | v1 | v2 |
|---|---|---|
| Java | **8** (`pom.xml:21`) | **21** |
| Spring Boot | **2.3.7.RELEASE** (`pom.xml:17`) | **3.5.9** |
| Namespace | `javax.*` (all imports) | `jakarta.*` |
| Keycloak client | `9.0.3` (`pom.xml:318`) | newer |
| PostgreSQL JDBC | `42.2.24` (`pom.xml:78`) | similar or newer |
| Build | Maven + Docker (Maven 3.8.4 / OpenJDK 8 multi-stage) | Maven + Docker |

**Porting impact:** Every javax import in v1 changes to jakarta. Spring Boot 2.3 → 3.5 migration guides apply; in particular, `WebSecurityConfigurerAdapter` → `SecurityFilterChain`, removed `@EnableWebFluxSecurity` class, etc.

---

## 3. Transactions + OSIV delta

**DIFFERENT — v1 has no multi-tenancy in the persistence stack.**

| | v1 | v2 |
|---|---|---|
| `PlatformTransactionManager` beans | **1** (Spring Boot default, no explicit config) | **2** — `landlordTransactionManager` (`@Primary`), `tenantTransactionManager` |
| Entity Manager Factories | **1** | **2** — split by package |
| `spring.jpa.open-in-view` | defaults to **`true`** (not explicitly set) | **`false`** (`application.properties:54`) |
| `hibernate.multiTenancy` | absent | `DATABASE` |
| `TenantIdentifierResolver` | absent | custom implementation |

**Consequence for porting:** a v1 service with bare `@Transactional` works correctly against the single DS; the v2 port **must** qualify every tenant-data `@Transactional` with `value="tenantTransactionManager"` (or `@TenantTransactional`). Missed qualifiers silently fall through to landlord — the single biggest landmine documented in [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) §10 item 1.

**OSIV flip:** any v1 code that lazy-loads associations in the view/controller layer will **fail** in v2. Pre-fetch or traverse inside the service `@Transactional` boundary.

---

## 4. Multi-tenancy delta

**DIFFERENT — the biggest architectural divergence.**

v1 is **single-tenant**. One PostgreSQL DB, one connection pool, one datasource, no routing. The `facility_code` header is accepted in DTOs (`AbstractRestController.java:20`, `AdviceDto.java:38`) only for business-logic validation, not routing. There is no `TenantContext`, no `TenantFilter`, no `AbstractRoutingDataSource`.

| | v1 | v2 |
|---|---|---|
| DataSource count | **1** | **1 landlord + N per-tenant** (lazy via `ConcurrentHashMap`) |
| `TenantContext` | absent | `ThreadLocal<TenantProfile>` at `landlord/config/TenantContext.java:18` |
| `TenantFilter` | absent | `@Order(HIGHEST_PRECEDENCE)` servlet filter |
| `X-Tenant-ID` + `facility_code` HTTP headers | unused for routing | required, lowercased, set TenantContext |
| Pool lifecycle | fixed pool | lazy create, 15-min idle eviction (`TenantPoolEvictor`) |
| Hibernate multi-tenancy | none | `DATABASE` strategy via `TenantIdentifierResolver` |
| Landlord-side entities | absent | 4 (`Tenant`, `TenantDbConfiguration`, `TenantAuthConfiguration`, `TenantDiscovery`) |

**Consequence for porting:** any v1 code that directly accesses a service or repository is fine; the v2 equivalent must ensure the call path either runs inside `TenantFilter` (HTTP request) or manually sets `TenantContext.setCurrentTenant(profile)` and clears in `finally`. Scheduled jobs are the chief non-HTTP path — see §6 below.

For the v2 picture in full, see [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md).

---

## 5. State machine delta

**MOSTLY-SAME — v1 is missing one terminal state.**

v1 `WmsConstants.State` (lines 20–109) has the same values as v2 for:
`RAW=0`, `ASSIGNED=200`, `PROCESSABLE=300`, `RESERVED=400`, `STARTED=500`, `CUSTOMER_ORDER_ACTIVATED=505`, `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED=510`, `ORDER_BATCH_ACTIVATED=520`, `ORDER_BATCH_STAGING_LANE_ASSIGNED=525`, `ORDER_BATCH_CLUB_RUN_FINISHED=530`, `PENDING=550`, `PICKED=600`, `PACKED=650`, `PALLETIZED=670`, `FINISHED=700`, `CANCELED=800`.

| Constant | v1 | v2 |
|---|---|---|
| `LOADED_TO_TRUCK` (680) | **absent** | present |

**Consequence for porting:** any v2 logic that sets `Customerorder.state = LOADED_TO_TRUCK` (truck loading flow — see [wms2-bol-truck-loading-workflow.md](../workflows/wms2-bol-truck-loading-workflow.md) §5) has no direct v1 equivalent. v1 orders skip from `PALLETIZED` (670) to `FINISHED` (700) at BOL close; truck load is not a distinct tracked state.

**String states** (`AdviceState`, `BillOfLadingState`) match byte-for-byte, including the two-L `CANCELLED` spelling in both versions. No divergence there.

---

## 6. Scheduled jobs delta

**MOSTLY-SAME — same 5 cron jobs, but v1 has no advisory lock (jobs race across replicas).**

| | v1 | v2 |
|---|---|---|
| Business cron jobs | `OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`, `ReleaseExpiredPickingOrdersFromUserJob` | **identical 5** |
| Scheduling | `SchedulingConfigurer` + DB sysprops for cron expressions | same pattern |
| Activation gate | `app.cron` (`application.properties:94`, default `false`) + `BasicService.isCron()` | `app.cron` |
| `AdvisoryLockService` | **absent** — jobs have no cross-replica mutex | present; `JobLockId` constants `100001L–100008L` (5 shared business jobs + 3 v2-only: `StaleClubBatchCleanupJob`, `RestIdempotencyCleanupJob`, `OutboxDispatcherJob`) |
| `TenantPoolEvictor` / `TenantConfigLoader` `@Scheduled` | absent (no multi-tenancy) | present |
| Micrometer job metrics | **absent** | present (SBDEV-2238-4.5): `wms2.cron.<job>.{duration,success,failure,skipped_lock_busy,rows_processed,last_run_epoch_seconds,last_success_epoch_seconds}` on all 5 shared business jobs; `/actuator/prometheus` enabled |

**Porting impact — serious:** v1 runs a single instance; jobs firing concurrently is only theoretical (if an admin bounces the service during a run). v2 runs horizontally replicated; **without the advisory lock, `OrderReleaseJob` would execute on every replica simultaneously**, multiplying optimistic-lock storms. Any new v2 cron job MUST acquire an advisory lock via `AdvisoryLockService.tryLock(...)`. See [wms2-scheduled-jobs-catalog.md](./wms2-scheduled-jobs-catalog.md) §2 + §4.

**Additional v1-only quirks (discovered 2026-04-27):**
- **Broken `ReplenishOrderJob` gate** (`ReplenishOrderJob.java:200`): the delete-when-empty branch evaluates the constant *name* `WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY_KEY` rather than reading the DB value — always `false`. The branch is dead code in v1.
- **Startup-time schedule snapshot**: v1 reads cron expressions from `LosSysprop` once at startup (`SchedulingConfigurer`). Changing a sysprop at runtime has no effect until restart. v2 re-evaluates cron expressions dynamically via `TaskScheduler` rescheduling.

---

## 7. Sysprop delta

**MOSTLY-SAME — ~190 shared, with v2-only extensions.**

| | v1 | v2 |
|---|---|---|
| Total `SYSTEM_PROPERTY_*_KEY` constants | **~201** (single file) | **~75 documented + others** |
| OMS `WEBSERVICE_*` URL keys | 9 (CLOSE_ADVICE, ACCEPT_TRANSFER, ACCEPT_HUB_AND_SPOKE, STOCK_COUNT, STOCK_UPDATE, ORDER_BATCH_RELEASED_FOR_PICKING, ORDER_BATCH_PICKING_TOTE_ASSIGNED, ORDER_BATCH_PICKING, ORDER_BATCH_LOADED_TO_TRUCK) | 18 — includes v1's 9 **plus** 9 more (`FINISHED_PICKING`, `HELD`, `SHIPPED`, `PALLETIZED`, `CANCELLED`, `TEST_CRM_CONNECTIVITY`, `FACILITY_LIST_LOOKUP`, `BEHAVIOUR`) |

**v2-only keys** (not in v1):

- `NEW_CRON_JOB_ACTIVATED`, `OLD_CRON_JOB_ACTIVATED` (cron master gates)
- `CUPS_SERVER_ADDRESS_*` (CUPS printing server — v2 added structured config)
- `PRINTING_ZPL_*` (extended label template set)
- `KEYCLOAK_*` (all 8 Keycloak sysprops — v1 used hardcoded config)
- `STRING_PATTERN_*` (barcode regex patterns — v2-centralized)
- `STOCK_SUMMARY_EXPORT_TIMER_SPLIT_*` (batched export)
- `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_*_BOUND` (replenishment tuning constants)
- `INBOUND_UPDATE_STOCK_IMMEDIATELY`, `REQUIRE_RECEIVING_TO_CONTAINER`
- `CYCLE_COUNT_*`, `SHIPPING_METHOD_ACTIVATED`, `SHOW_MANIFEST_LOCATION`
- `PICK_PATH_DIRECTION` (SBDEV-2096 — configurable pick/putaway/cycle-count/move-stock sort direction; v1 is hardcoded column-first)

**v1-only keys:** v1 has more total constants but most are tenant-config bits that collapsed into `TenantDbConfiguration` / `TenantAuthConfiguration` rows in v2. Audit these one-by-one when porting a v1 fix that reads an unusual sysprop.

For the v2 catalog see [wms2-sysprop-catalog.md](../data-dictionary/wms2-sysprop-catalog.md).

---

## 8. Entity delta

**DIFFERENT — flat package in v1 vs landlord/tenant split in v2.**

| | v1 | v2 |
|---|---|---|
| Package structure | single `net.aim_ai.wms.model/` | split: `landlord/model/` (4 entities) + `model/` (62 tenant entities + 11 views) |
| Total entity count | **~67** | ~76 total |
| `Tenant`, `TenantDbConfiguration`, `TenantAuthConfiguration`, `TenantDiscovery` | absent | landlord-side (4 tables) |
| `InventoryRecord` | present | present |
| Monitor-view entities (`OrderMonitorView`, `FlowbinMonitorView`, etc.) | not enumerated | 11 view entities in v2 |

**Same hard conventions** (preserved from v1, enforced in v2):

- **No JPA associations** — all FK relationships are `Long foreignKeyId` fields. Never add `@ManyToOne` / `@OneToMany` (documented in both CLAUDE.md files).
- **Entity comparison by ID, not `.equals()`** — only `Location` has `equals`/`hashCode` and it's broken; everything else uses object reference equality.

**Porting impact:** moving a v1 entity to v2 requires choosing the right package (`landlord/model` for config-like tables, `model/` for tenant data). When in doubt — tenant side.

For the v2 split see [wms2-landlord-vs-tenant-entity-map.md](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md).

---

## 9. OMS callback delta

**SAME — all 9 v1 callback URL sysprops exist verbatim in v2.**

v1 fires: `WEBSERVICE_CLOSE_ADVICE`, `WEBSERVICE_ACCEPT_TRANSFER`, `WEBSERVICE_ACCEPT_HUB_AND_SPOKE`, `WEBSERVICE_STOCK_COUNT`, `WEBSERVICE_STOCK_UPDATE`, `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING`, `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED`, `WEBSERVICE_ORDER_BATCH_PICKING`, `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK`.

v2 fires: all of the above **plus** `FINISHED_PICKING`, `HELD`, `SHIPPED`, `PALLETIZED`, `CANCELLED`, `TEST_CRM_CONNECTIVITY`, `FACILITY_LIST_LOOKUP`, `BEHAVIOUR`.

**Porting impact:** v2 sends more notifications than v1. If you port a v1 fix that *adds* a callback, the v2 equivalent may already exist — grep v2 first. The `WEBSERVICE_BEHAVIOUR` sysprop (`send | discard | keep`, default `keep`) is the v2-only emergency switch for all callbacks.

**v1 silent gap (discovered 2026-04-27):** `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` is defined as a sysprop key in `WmsConstants.java` but is **never fired** by v1's `closeBOL` flow. v1 `closeBOL` transitions orders `PALLETIZED → FINISHED` directly with no loaded-to-truck callback. OMS will never receive this notification from v1 regardless of whether the sysprop URL is configured.

---

## 10. Authorization / Keycloak delta

**MOSTLY-SAME — same OAuth2 + role patterns, different admin-role name and a larger function set in v1.**

| | v1 | v2 |
|---|---|---|
| Super-admin role constant | `AIM_ADMIN_ROLE = "aim_admin"` (`Authority.java:15-44`) | `SB_ADMIN_ROLE = "sb_admin"` |
| Super-admin expression | `Authority.IS_AIM_ADMIN` = `"isAimAdmin()"` | `Authority.IS_SB_ADMIN` |
| `FunctionEnum` constant count | **86** (`WmsConstants.java:323-407`) | 51 |
| Composite roles (e.g. `role_inventory_manager`, `role_outbound_manager`) | same personas | same personas |
| Group paths (`APP_GROUP`, `APP_ADMIN_GROUP`) | same | same |

**Porting impact:** v1 → v2 porting of admin endpoints requires changing `@PreAuthorize(Authority.IS_AIM_ADMIN)` to `@PreAuthorize(Authority.IS_SB_ADMIN)` and renaming the `aim_admin` Keycloak role to `sb_admin` in the destination realm. v1's larger `FunctionEnum` list — track which additions are v1-specific (many are legacy and unused in v2) when porting features that reference them.

For the v2 matrix see [wms2-keycloak-role-matrix.md](./wms2-keycloak-role-matrix.md).

---

## 11. Endpoints delta

**MOSTLY-SAME — both mount `/v3` + `/rest/`.**

| | v1 | v2 |
|---|---|---|
| Main API prefix | `/v3` (HAL / Spring Data REST auto-exposed) | `/v3` |
| Admin/integration prefix | `/rest/*` (manually written controllers) | `/rest/*` |
| Public endpoints | none (no tenant context concept) | `/api/public/*` (bypasses `TenantFilter`) — `authConfig` lookup lives here |
| `/v3/clubLine/*` | **not found in v1** | present (`ClubLineController`) |
| `/v3/tenant/health` | absent | present (validates per-tenant DB) |

**Porting impact:** new v2 endpoints with `/api/public/` prefix bypass tenant resolution. v1 equivalents (if any) don't need this distinction. The `clubLine` endpoint set is a v2 feature — if porting a v1 club-order fix, you'll likely land it in `CustomerorderBatchService` methods rather than the `ClubLineController` path.

---

## 12. Testing + infrastructure delta

**SAME — both use Testcontainers + H2 profiles.**

Same test pattern in both:

- Testcontainers `PostgreSQL` singleton via `AppPostgresDBContainer` + `AppPostgresDBSetupExtension` (JUnit 5)
- Flyway migrations in `src/main/resources/db/migration/V*.sql`
- H2 profile for fast repo tests (`application-h2test.properties`)
- Jasypt `ENC(...)` support for encrypted sysprops; `-Djasypt.encryptor.password` runtime flag

**v1-specific constraint** (confirmed from v1 CLAUDE.md):

- **Mockito 3.3.3** — inherited from Spring Boot 2.3.7 BOM. **No `mockStatic()`** — any static-method mocking must use an alternative (PowerMock or refactor). v2 uses a newer Mockito (from Spring Boot 3.5's BOM) where `mockStatic()` is available.
- **`OptimisticLockRetryTemplate.executeWithRetry()`** — same utility as v2's `OptimisticLockRetry.executeWithRetry()`, named slightly differently. The retry policy (3 attempts, 100ms * attempt exponential backoff) is identical.

**Porting impact:** a v1 test that works around a lack of `mockStatic` may become simpler in v2. A v2 test written assuming `mockStatic` cannot be ported backwards to v1 without refactor.

---

## 13. Porting Guidance

When porting a **fix** from v1 to v2, walk this checklist:

| Question | Source |
|---|---|
| Does the v1 code use bare `@Transactional`? | §3 — qualify with `tenantTransactionManager` |
| Does the v1 code rely on OSIV lazy loading? | §3 — pre-fetch in service layer |
| Does it touch `Customerorder.state`? | §5 — check if `LOADED_TO_TRUCK` (680) now applies |
| Is it in a scheduled job? | §6 — add `AdvisoryLockService.tryLock(...)` + per-tenant iteration |
| Does it read a sysprop? | §7 — v2-only keys may exist; verify caching (`@Cacheable`) implications |
| Does it reference an entity? | §8 — confirm which DB (landlord vs tenant) |
| Does it fire an OMS callback? | §9 — v2 may already have an equivalent; grep before adding |
| Does it gate on a role? | §10 — rename `aim_admin` → `sb_admin`, check `FunctionEnum` |
| Is it an HTTP endpoint? | §11 — route does not change; but confirm if it should be `/api/public/*` |

The canonical porting tool is the `wms-v2-migrate` skill, which runs this checklist automatically against a v1 plan file. See [2-Areas/wms-v1-v2-sync/README.md](../../2-Areas/wms-v1-v2-sync/README.md).

---

## 14. Known Landmines

1. **Bare `@Transactional` in ported code.** v1's default routes to the one DS it has. v2's default routes to landlord — always wrong for tenant data. Most common port mistake.
2. **OSIV-dependent lazy loading.** v1 code that works "accidentally" because OSIV is on breaks silently in v2 (empty collections, `LazyInitializationException` on access).
3. **Missing `LOADED_TO_TRUCK` in v1.** A v1 fix that observes "order goes from `PALLETIZED` to `FINISHED`" is correct in v1 but misses a step in v2. Don't copy the state-machine guard verbatim.
4. **Cron concurrency.** A v1 fix that assumes "job only runs on one instance" is factually true in v1 but dangerously false in v2 without an advisory lock. Every ported cron fix must add `AdvisoryLockService.tryLock(JobLockId.X)`.
5. **Admin-role rename.** `aim_admin` in v1 becomes `sb_admin` in v2 at both the constant level and the Keycloak realm level. Porting an `@PreAuthorize` expression without renaming produces an always-deny.
6. **`WEBSERVICE_BEHAVIOUR` sysprop is v2-only.** A v2 tenant with `WEBSERVICE_BEHAVIOUR=discard` will silently drop all OMS callbacks — the sysprop doesn't exist in v1, so v1 can't "match this behavior" out of the box.
7. **`mockStatic` is v2-only.** A v2 test with `Mockito.mockStatic(...)` cannot be ported to v1 without restructuring.
8. **`/api/public/` path has no v1 analog.** v1 doesn't need it (no tenant context to skip). If a v1 fix lands a new endpoint, the v2 port must decide whether it's `/v3/...` (tenant-scoped) or `/api/public/...` (tenant-free).
9. **String literal `"TRANSFER_INTRACOMPANY"` at `BillofladingService.java:315`.** v1 uses a hardcoded string; v2 uses a constant reference. If the constant value ever changes, v1 silently stops routing transfer BOLs to the intracompany close path.
10. **`SID`-prefix bug on fast-path cycle count positions.** `CyclecountService.countSingleUnitLoad` generates position numbers with `SID` prefix instead of `CCP`. Some queries that filter by prefix will misclassify these as stockunit references.
11. **`ReceivingService` has no `@Transactional`.** Goods receipt creation, stock unit writes, and `FixLocationAssignment` inserts run in separate auto-commit transactions. A failure mid-receive leaves partial stock with no rollback path — the position must be manually adjusted or deleted.
12. **`WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` sysprop exists in v1 but is never fired.** See §9. Configuring this URL in a v1 tenant has no effect.
13. **Broken `ReplenishOrderJob` delete-when-empty gate.** See §6. The branch is permanently dead — `FixLocationAssignment` records are never cleaned up by the job regardless of the sysprop value.
14. **`PICK_PATH_DIRECTION` sysprop is v2-only (SBDEV-2096).** Sort direction for picking, putaway, cycle-count, and move-stock is configurable in v2 (`VERTICAL` = column-first, `HORIZONTAL` = row-first); v1 is hardcoded column-first. No v1 porting needed, but v1 fixes that touch sorting logic should note this gap.

---

## 15. How to use this doc

| Scenario | Jump to |
|---|---|
| Porting a specific v1 fix | §13 checklist + the section covering the subsystem the fix touches |
| Onboarding a new engineer | §1 overview → §2 stack → §4 multi-tenancy (the biggest single delta) |
| Answering "does v1 have X?" | scan §2–§12 by category; each row is a row in a comparison table |
| Updating after v1→v2 sync sweep | §15 verification log + cross-check each section against sweep findings |

---

## 16. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | v1 pom.xml, application.properties, WmsConstants.java, Authority.java, SchedulingConfiguration, package structure, entity count, 9 WEBSERVICE_* keys, FunctionEnum constant count, TransactionManager bean count, OSIV setting | Differences matched the 16 points above; v1 single-tenant + missing `LOADED_TO_TRUCK` + no AdvisoryLockService are the load-bearing deltas | Explore agent sweep of v1/wms-api + comparison against v2 arch docs |
| 2026-04-27 | Full v1 codebase deep-dive producing 12 reference docs (state machine catalog, transaction boundary map, entity enumeration, scheduled jobs catalog, package analysis, tenant topology, BOL/picking/receiving/cycle-count/transfer/stockunit docs). New findings added to §6, §9, §14: broken ReplenishOrderJob gate, startup-time cron snapshot, LOADED_TO_TRUCK sysprop never fired, string-literal TRANSFER_INTRACOMPANY, SID-prefix cycle-count bug, ReceivingService no-transaction risk. | 5 new landmines (§14 items 9–13), 2 new §6 quirks, 1 new §9 gap | 6 parallel executor agents sweeping v1/wms-api source |

**Re-verify every sync sweep.** The v1→v2 sync workflow already diffs both codebases weekly; that's the natural cadence. **Next expected re-verify:** next weekly sync sweep (anchor dates live in [2-Areas/wms-v1-v2-sync/sync-log.md](../../2-Areas/wms-v1-v2-sync/sync-log.md)).
