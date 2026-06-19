---
title: "WMS v2 Integration Tests — H2 Migration Feasibility Report"
type: plan
status: draft
version: v2
scope: wms2-api
owner: "nam.park@siteboss.net"
created: 2026-04-20
updated: 2026-06-17
last_verified: 2026-06-17
verified_by: "re-grounded against HEAD — pending user review"
related:
  - ../../../2-Areas/runbooks/wms1-cancel-packed-parcel.md
  - ../../../2-Areas/wms-v1-v2-sync/README.md
tags:
  - plan
  - draft
  - wms2
  - testing
  - h2
  - testcontainers
  - integration-tests
---

# WMS v2 Integration Tests — H2 Migration Feasibility Report

**Status: DRAFT — awaiting review.** If approved, this document becomes the execution plan.

> **Re-grounding note (2026-06-17).** Re-verified against HEAD on 2026-06-17. The test infrastructure described as "to build" in the 2026-04-20 draft **already exists** — the H2 `integration` profile (`application-integration.properties`), the `BaseIntegrationTest` / `BasePostgresIntegrationTest` pair, `TestDataFactory`, and the `TestDatabaseConfig` landlord/tenant H2 wiring all shipped between the draft and today. The draft's central diagnosis (a "broken landlord datasource" gating ~9 tests) is **inverted**: the landlord datasource is wired and integration tests boot on H2 right now. The sections below reflect the live tree, not the April plan-of-record. The strategic direction (hybrid H2-default + opt-in PG profile) is retained; the work has shifted from *building plumbing* to *migrating the remaining legacy tests onto the plumbing that already exists*.

## 0. TL;DR

- **Can H2 replace Testcontainers PostgreSQL?** **Yes — for the bulk of the suite, and it already does.** The H2 `integration` profile is live; most integration tests boot and run on H2 today. A minority genuinely needs PostgreSQL — PL/pgSQL functions, `pg_advisory_lock`, and a handful of PG-only native SQL queries. Target state is the **hybrid** that is already half-built: H2 by default for fast local + CI, opt-in PostgreSQL (Testcontainers) profile for the enumerated PG-only tests.
- **Is the infrastructure the April draft proposed to build still missing?** **No — it is built.** `application-integration.properties`, the `BaseIntegrationTest`/`BasePostgresIntegrationTest` pair, `TestDataFactory`, and `TestDatabaseConfig` (which forwards the tenant routing datasource to the landlord H2 instance) all exist at HEAD. See §1.
- **Is the current suite worth keeping?** **Mixed.** The integration tree is now ~42 classes; **18 `@Disabled` markers across 15 classes** remain, in **categorized** buckets (see §3) — *not* a single landlord root cause. 8 legacy multi-tenant tests should be rebuilt on the existing H2 base; 7 PG-only markers are legitimately kept on the PG profile; 1 complex-fixture test; 1 perf test is intentionally on-demand; 1 report smoke test waits on the PL/pgSQL→Java port (P2 Phase A).
- **Why did the April draft say it "doesn't work anymore"?** That was true in April. It is not true now. The landlord-datasource fix shipped (`TestDatabaseConfig` mocks `tenantDynamicRoutingDataSource` to forward `getConnection()` to `landlordDataSource`, so one H2 instance backs both landlord- and tenant-package entities). The residual disabled tests are disabled for the specific, narrower reasons enumerated in §3.

---

## 1. Current Infrastructure — Evidence (re-grounded against HEAD)

The April draft's §1 described this infrastructure as missing or half-built. As of 2026-06-17 it is **built and live**. The H2 lane boots and runs.

### 1.1 The H2 `integration` profile exists and fully wires both datasources

`src/test/resources/application-integration.properties` **exists** (the April draft said "does not exist — create it"). It wires H2 for both the landlord and the tenant datasources:

| Property | Value |
|---|---|
| `landlord.datasource.jdbc-url` | `jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE` |
| `spring.datasource.url` (tenant fallback) | same H2 URL — one in-memory instance backs both packages |
| `spring.flyway.enabled` | `false` (Hibernate `ddl-auto=create-drop` builds the schema) |
| `spring.jpa.hibernate.ddl-auto` | `create-drop` |
| `spring.jpa.database-platform` | `org.hibernate.dialect.H2Dialect` |
| `rest.security.enabled`, `app.cron`, `management.tracing.enabled` | all `false` (context boots without Keycloak / cron / Zipkin) |
| `spring.autoconfigure.exclude` | OAuth2 resource-server + Spring Security servlet auto-configs excluded so the tenant context boots without `HttpSecurity` |

### 1.2 The base-class pair the draft proposed already exists

`src/test/java/net/aim_ai/wms/common/base/` contains the full set today:

| Base class | Profile / DB | Role |
|---|---|---|
| `BaseIntegrationTest.java:22-27` | `@ActiveProfiles("integration")` + `@Import(TestDatabaseConfig)`, H2 | Default H2 integration base. `@Transactional`, mocks `TenantHealthService` / `EndpointHealthCheck`. |
| `BaseRepositoryIntegrationTest.java:23-28` | `@ActiveProfiles("integration")` + `@Import(TestDatabaseConfig)`, H2 | Repository-layer H2 base (the most-used base — 9 subclasses). |
| `BaseRollbackIntegrationTest.java:29-52` | `@ActiveProfiles("integration")` + `@Import(TestDatabaseConfig)`, H2 | Rollback/transaction-boundary H2 base (6 subclasses). |
| `BaseControllerIntegrationTest.java:21` | extends `BaseIntegrationTest`, H2 | MockMvc controller H2 base. |
| `BasePostgresIntegrationTest.java:34-37` | `@ExtendWith(AppPostgresDBSetupExtension)`, Testcontainers PG | The PG opt-in base. **Note its own TODO (SBDEV-2217):** it does not yet set `@ActiveProfiles("integration")`, so it cannot supply `landlord.datasource.jdbc-url` on its own — it boots only via the Postgres extension's system properties and currently fails the landlord wiring. This is the *remaining* PG-lane gap (see §4.2 #1), not a landlord gap in the H2 lane. |

Also present (unit/perf bases, out of scope for this report): `BaseServiceUnitTest`, `BaseUnitTest`, `BaseControllerUnitTest`, `BasePerformanceTest`.

### 1.3 `TestDatabaseConfig` already collapses landlord + tenant onto one H2 instance

`src/test/java/net/aim_ai/wms/common/config/TestDatabaseConfig.java:25-45` defines an `@Primary` `tenantDynamicRoutingDataSource` bean that is a Mockito mock whose `getConnection()` **forwards to the real `landlordDataSource`** — so a single H2 instance hosts both landlord-package and tenant-package entities. It also creates the `seqentities` sequence (`CREATE SEQUENCE IF NOT EXISTS seqentities`). This is exactly the fix the April draft proposed as "the single biggest lever" — **it has shipped.**

### 1.4 `TestDataFactory` already exists

`src/test/java/net/aim_ai/wms/common/fixtures/TestDataFactory.java` **exists** (the April draft proposed "provide a `TestDataFactory`"). A second copy lives at `unit/fixtures/TestDataFactory.java` for the unit lane. Rebuilt legacy tests can use the existing common fixture rather than `@Sql` scripts.

### 1.5 What did NOT get cleaned up (still real debt)

- `src/test/java/net/aim_ai/wms/common/H2TestExtension.java` still exists alongside the profile — the runtime property-injection extension was never deleted after the profile took over.
- The duplicate `AppPostgresDBSetupExtension` is still present in **two** places: `net/aim_ai/wms/AppPostgresDBSetupExtension.java` (root package) and `net/aim_ai/wms/common/extension/AppPostgresDBSetupExtension.java`.
- `BaseRepositoryIntegrationTest` and `BaseRollbackIntegrationTest` are *not* collapsed into `BaseIntegrationTest`; they are separate (functioning) H2 bases. Collapsing them is optional tidy-up, not a blocker.

### 1.6 Why the April draft's "Testcontainers stopped working" diagnosis is now stale

The April draft attributed everything to (1) a missing Docker daemon and (2) a "broken landlord datasource in the test profile" that "would still fail on H2." Both are obsolete:

1. The **H2 lane has no Docker dependency** and is the default — there is no `.withReuse(true)` hang on the default path.
2. The **landlord datasource is wired** in the H2 profile (§1.1, §1.3); the H2 integration tests boot. Of the 18 remaining `@Disabled` markers in the integration tree, exactly **one** still cites the old Hikari error in its comment: `ClientRepositoryIntegrationTest:285`. Even there the comment is stale — the rest of that class runs green on H2; the test's *real* residual blocker is that it exercises the `transaction_detail()` PL/pgSQL function, so it depends on **P2 Phase A** (the PL/pgSQL→Java port), not on any landlord fix.

---

## 2. PostgreSQL-Specific Surface Area — What Breaks on H2

| Feature | Location | Impact |
|---|---|---|
| **PL/pgSQL functions** — `stock_history()`, `transaction_detail()` | `V1.0.03__wms_functions.sql:13-71`, `V1.1.04__wms_functions.sql:4`, `V2.1.07__update_transaction_detail_pick_amount_filter.sql` | H2 has no PL/pgSQL. Flyway migration will fail at H2 boot. 6 `CREATE OR REPLACE FUNCTION` sites total. |
| **`pg_advisory_lock`** | `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java:56,88` | PostgreSQL-only. Used by **8** scheduled jobs (`ORDER_RELEASE`, `REPLENISH_ORDER`, `CLEAN_UP_MESSAGES`, `STOCK_SUMMARY_EXPORT`, `RELEASE_EXPIRED_PICKING`, `STALE_CLUB_BATCH_CLEANUP`, `CLEANUP_REST_IDEMPOTENCY`, `OUTBOX_DISPATCHER`). Any test that drives a scheduled job or calls `AdvisoryLockService` will fail on H2 at runtime. See [P3 advisory-lock plan](./260421-v2-replace-pg-advisory-lock.md) for the authoritative job/lock inventory. |
| **Native queries** (186 `nativeQuery = true` annotations at HEAD) | repos throughout | Most are portable. Landmines: `::text` casts, `FOR UPDATE OF <table>`, PG date arithmetic, PG `BOOLEAN` literal comparisons. The `MessageRepository` archive/delete-with-LIMIT and INSERT-INTO-SELECT queries are PG-only. |
| **`SELECT FOR UPDATE` lock semantics** | `PickingorderBusinessServiceConcurrencyIT`, `StockunitBusinessServiceConcurrencyIT`, `UnitloadBusinessServiceConcurrencyIT` (all `@Disabled`, SBDEV-2217) | H2 cannot reproduce PostgreSQL row-lock contention; these concurrency ITs require the real PG engine. |
| **`to_timestamp()` in ClientRepository.getTransactionDetail** | query definition for `transaction_detail()` invocation | Directly blocks the `V2.1.07` filter test; this is the residual blocker behind `ClientRepositoryIntegrationTest:285`. |

**Bottom line:** H2 can run repo tests that stick to JPQL + JPA features. It cannot run tests that exercise PL/pgSQL functions, advisory locks, PG-only native SQL, or the scheduled-job mutex.

---

## 3. Test-by-Test Verdict (re-audited at HEAD)

The integration tree under `src/test/java/net/aim_ai/wms/integration/` now holds **~42 classes** (the April draft saw 20), plus the 3 root-package `service/*BusinessServiceConcurrencyIT` classes. Many suites postdate the April draft: the entire `integration/outbox/*` suite (`OutboxClaimExplainIT`, `OutboxClaimOrderingIT`, `OutboxConcurrentEnqueueIT`, `OutboxMigrationV1124IT`, `OutboxStuckAggregateIntegrationTest`, `OutboxTerminalHoldIT`), the outbox/cancel integration tests (`AdviceOutboxIntegrationTest`, `CustomerorderOutboxIntegrationTest`, `CustomerorderBatchOutboxIntegrationTest`, `CancelOrderRollbackIntegrationTest`), several concurrency `*IT` classes (`ParcelMonitorViewServiceConcurrencyIT`, `SequenceTransactionServiceConcurrencyIT`, `CustomerorderBatchServiceParallelStreamRegressionIT`), `AdviceServiceRollbackIntegrationTest`, `IdempotencyFilterIT`, `MessageCleanupBatchServiceIT`, `WarehouseStockReportServiceStreamIT`, `BillofladingServiceFinishTransferIT`, and `SkuRestControllerAtomicityIntegrationTest`. The large majority of these **run green on the H2 lane today** (they extend `BaseIntegrationTest` / `BaseRepositoryIntegrationTest` / `BaseRollbackIntegrationTest`).

### 3.1 The 18 remaining `@Disabled` markers (across 15 classes), by category

These are the real `@Disabled` annotations in the integration tree (doc-comment mentions in `BillofladingServiceFinishTransferIT:40` and `OutboxClaimOrderingIT:29`, and the commented-out `//@Disabled` at `ClientControllerLegacyIntegrationTest:104,111`, are **not** counted — they are not active markers).

**Category A — "Legacy test infrastructure incompatible with multi-tenant architecture" (8 class-level disables).** These predate the H2 base/`TestDataFactory` and still extend the old `AppPostgresDBSetupExtension` path. *Rebuild on `BaseIntegrationTest` + `TestDataFactory`, or delete.*

| Test class | Location | Marker |
|---|---|---|
| `ClientServiceIntegrationTest` | `integration/service/` | `:23` class-level |
| `MobilePickingServiceIntegrationTest` | `integration/service/mobile/` | `:31` class-level |
| `MobilePutawayServiceIntegrationTest` | `integration/service/mobile/` | `:24` class-level |
| `MobileReplenishServiceIntegrationTest` | `integration/service/mobile/` | `:35` class-level |
| `MobileTransferOrderServiceIntegrationTest` | `integration/service/mobile/` | `:32` class-level |
| `SkuRestControllerIntegrationTest` | `integration/controller/rest/` | `:41` class-level |
| `OrderRestControllerIntegrationTest` | `integration/controller/rest/` | `:38` class-level |
| `ClientControllerLegacyIntegrationTest` | `integration/controller/` | `:42` class-level (delete candidate) |

**Category B — PG-only native SQL, explicitly "incompatible with H2" (7 method/inner-class disables across 4 classes).** *Legitimately kept on `BasePostgresIntegrationTest`.*

| Test | Location | Reason in comment |
|---|---|---|
| `LocationRepositoryIntegrationTest` | `:291` | "Native SQL queries use PostgreSQL-specific syntax — incompatible with H2" (JOINs) |
| `PrinterRepositoryIntegrationTest` | `:128`, `:158` (2 inner classes) | "Native SQL compares BOOLEAN to VARCHAR 'true' — incompatible with H2" |
| `MessageRepositoryIntegrationTest` | `:197`, `:232`, `:303` (3 inner classes) | PG date arithmetic; native `INSERT INTO SELECT` |
| `CyclecountRepositoryIntegrationTest` | `:340` | "Native SQL queries with JOINs require related entities — incompatible with H2 test setup" |

(The 3 root-package `PickingorderBusinessServiceConcurrencyIT:21`, `StockunitBusinessServiceConcurrencyIT:22`, `UnitloadBusinessServiceConcurrencyIT:24` are **also** PG-only — "H2 cannot reproduce SELECT FOR UPDATE lock semantics (SBDEV-2217)" — and belong to the PG lane. They live outside the `integration/` package, so they are not part of the integration-tree marker count, but they are part of the enumerated PG-only set in §4.3.)

**Category C — complex fixtures (1 class-level disable).** *Rebuild on H2 with `TestDataFactory`, or keep on PG if fixtures stay native.*

| Test | Location | Reason |
|---|---|---|
| `ReplenishorderRepositoryIntegrationTest` | `:31` | "Requires complex entity setup with Itemdata and Location — use TestContainers for full tests" |

**Category D — on-demand perf (1 class-level disable, leave as-is).**

| Test | Location | Reason |
|---|---|---|
| `BillofladingServiceFinishTransferPerformanceIT` | `:78` | "on-demand only — long-running load test for SBDEV-2216 AC2" — intentional, do not enable in CI |

**Category E — PL/pgSQL report smoke (1 method disable, waits on P2 Phase A).**

| Test | Location | Reason (comment is stale) |
|---|---|---|
| `ClientRepositoryIntegrationTest` | `:285` | Comment still cites the old landlord Hikari error, but the rest of the class runs green on H2; the real blocker is the `transaction_detail()` PL/pgSQL call. Unblocks when P2 Phase A ports the function to Java. |

### 3.2 Headcount reconciliation

Verified at HEAD on 2026-06-17:

- **18 raw `@Disabled` markers** in the `integration/` tree = 8 (Category A, all class-level) + 7 (Category B: Location ×1, Printer ×2, Message ×3, Cyclecount ×1) + 1 (Category C) + 1 (Category D) + 1 (Category E). Several Category-B classes carry multiple inner-class markers, so these 18 markers live across **15 distinct test classes**.
- **Actionable migration set:** the **8 Category-A classes** (rebuild on H2 or delete) + the **1 Category-C class** (fixtures) = the work this plan adds. Categories B (PG-only) and D (on-demand perf) are intentional; Category E is blocked on P2 Phase A.
- **Not counted as disabled:** doc-comment mentions in `BillofladingServiceFinishTransferIT:40` and `OutboxClaimOrderingIT:29`, and the commented-out `//@Disabled` at `ClientControllerLegacyIntegrationTest:104,111`.
- **Separately,** the 3 root-package `service/*BusinessServiceConcurrencyIT` classes are class-level `@Disabled` for `SELECT FOR UPDATE` (SBDEV-2217) — PG-only, part of the §4.3 enumerated set but outside the `integration/` package.
- **Already green on H2:** the remaining ~27 integration classes, including the whole outbox suite, the rollback tests, and the controller/idempotency/report-stream ITs.

---

## 4. Recommended Target State — Hybrid

### 4.1 Two test modes, one source tree (the H2 mode already exists)

| Mode | Annotation / profile | DB | Invocation | Status |
|---|---|---|---|---|
| **Default (H2)** | `@ActiveProfiles("integration")` via `application-integration.properties` + `TestDatabaseConfig` | H2 in-memory, `MODE=PostgreSQL`, `ddl-auto=create-drop` | `mvn verify` | **Live.** Backs `BaseIntegrationTest` / `BaseRepositoryIntegrationTest` / `BaseRollbackIntegrationTest`; most of the integration tree runs here today. |
| **Opt-in PostgreSQL** | `BasePostgresIntegrationTest` + `AppPostgresDBSetupExtension` (Testcontainers) | `postgres:12` via Testcontainers, real Flyway migrations | (separate Failsafe profile — see §5.5, not yet split) | **Partly built.** The base class exists but does not yet activate `@ActiveProfiles("integration")`, so it cannot supply `landlord.datasource.jdbc-url` — this is the one real remaining wiring gap (its own TODO SBDEV-2217). |

### 4.2 Remaining work (most of the April "fixes" already shipped)

Each item is annotated with its current state.

1. **PG-lane landlord wiring (DONE for H2, OPEN for PG).** The H2 lane's landlord datasource is wired and forwarding (§1.3) — the April "single biggest lever" is **already pulled**. The residual gap is the *Postgres* base: `BasePostgresIntegrationTest` needs either `@ActiveProfiles("integration")` (to inherit `landlord.datasource.jdbc-url`) or a dedicated landlord-datasource config for the Testcontainers context (per its SBDEV-2217 TODO). This blocks the 3 SELECT-FOR-UPDATE concurrency ITs and any future PG-lane test.
2. **`application-integration.properties` — DONE.** It exists and is self-sufficient (§1.1). No action.
3. **`TestDataFactory` — DONE.** Exists at `common/fixtures/TestDataFactory.java` (§1.4). Rebuilt Category-A tests **use the existing factory**; do not author a new one.
4. **Base-class tidy-up — OPTIONAL.** The `BaseIntegrationTest` + `BasePostgresIntegrationTest` pair already exists. `BaseRepositoryIntegrationTest` / `BaseRollbackIntegrationTest` are functioning H2 bases, not blockers; collapsing them is cosmetic. Real removable debt: delete the duplicate `AppPostgresDBSetupExtension` (root-package copy), retire the now-redundant `H2TestExtension`, and delete `ClientControllerLegacyIntegrationTest`.
5. **PL/pgSQL handling — DEFERRED to P2.** Porting `stock_history()` / `transaction_detail()` to Java (so the H2 lane can assert against Java logic) is the subject of the separate P2 plan (Phase A). Until then, the PL/pgSQL-dependent report tests stay on the PG lane / disabled (Category E).

### 4.3 The tests that must stay on PostgreSQL (enumerated, not estimated)

The PG opt-in lane is bounded to exactly this set:

1. `ClientRepositoryIntegrationTest:285` — `transaction_detail()` PL/pgSQL (Category E; moves to H2 after P2 Phase A).
2. `MessageRepositoryIntegrationTest:197,232,303` — PG date math, native `INSERT INTO SELECT` (Category B).
3. `PrinterRepositoryIntegrationTest:128,158` — PG `BOOLEAN`-to-`VARCHAR` cast in native SQL (Category B).
4. `LocationRepositoryIntegrationTest:291` — native JOINs (Category B).
5. `CyclecountRepositoryIntegrationTest:340` — native JOINs requiring related entities (Category B).
6. `PickingorderBusinessServiceConcurrencyIT`, `StockunitBusinessServiceConcurrencyIT`, `UnitloadBusinessServiceConcurrencyIT` — `SELECT FOR UPDATE` lock semantics (SBDEV-2217).
7. Any future test that drives a scheduled job through `AdvisoryLockService` (`pg_try_advisory_lock`) or deliberately verifies PL/pgSQL function correctness.

Everything else either doesn't need real SQL (pure Java logic — use unit tests) or already runs on H2 PG-compat mode. **The PG opt-in lane must not grow beyond this enumerated set without a documented reason** (see falsifiable goal, §5.5).

---

## 5. Broader Recommendations — Beyond Plumbing

These address the gap the smoke-test checklist exposed (§Scenario 1–10). Integration tests today are single-repo / single-service; the real value is **contract tests at the system boundary**.

### 5.1 Introduce "scenario tests" as a new layer

- Named `*ScenarioTest.java`, wired to Failsafe separately.
- Each scenario from `sbdocs/0-Inbox/wms-testing-smoke-test-checklist.md` gets one test: receiving → putaway → pick → pack → BOL → ship.
- Drive via REST (MockMvc at first; real HTTP when a dedicated E2E profile exists) with a WireMock-backed fake OMS.
- Assert both Java state AND DB state (state machine transitions + `message` table `SENT`).
- This is where the **most value per test** lives today — the repo tests largely duplicate unit-test coverage; the scenario layer is missing.

### 5.2 Drive scheduled jobs directly in tests

- `ReleaseOrderJobService`, `ReplenishOrderJob`, `CleanupMessagesJob` — expose test-only triggers on the PG (Testcontainers) lane so scenario tests don't wait for cron. These jobs take `pg_advisory_lock` via `AdvisoryLockService`, so they belong on the PG lane, not H2.
- Complements the picks-up-past-PACKED gap in the smoke-test checklist.

### 5.3 Promote a small set of cross-cutting assertion helpers

Shared between all integration and scenario tests:

- `assertMessageSent(type, correlationId)` — checks `message.process`, `message.status='SENT'`.
- `assertStockReservationReleased(stockunitId, amountDelta)` — diffs `reservedamount`.
- `assertEntityLock(stockunitId, lockValue)` — `NOT_LOCKED` / `SHIPPED` / `TRANSFER`.
- `assertStateTransition(entityId, fromState, toState)` — tables are always PG state-ints.

### 5.4 Delete what doesn't earn its keep

- Thin controller integration tests (ClientController stub, `ClientControllerLegacyIntegrationTest`) — controller logic is trivial, MockMvc unit tests are equivalent and ~100× faster.
- Any `*IntegrationTest` whose assertions would pass with an unmocked no-op repository — that's a signal the test isn't actually integrating anything.

### 5.5 CI pipeline shape, falsifiable goal, and PG-lane ownership

**Default stage (fast, H2):** `mvn verify` on the `integration` profile. Runs on every PR. No Docker daemon dependency — H2 has no `.withReuse(true)` hang.

**Extended stage (PG, Testcontainers):** the enumerated PG-only set from §4.3. **This lane is load-bearing, not optional.** See the fidelity risk below.

#### Falsifiable goal

The April draft's "the bulk of the suite" is made numeric here:

- **Target:** ≥ 90% of integration-tree test *classes* run on the H2 default lane. Concretely: of ~42 integration classes, no more than the enumerated PG-only set (§4.3 — currently 5 repository classes with PG-only markers + the 3 root concurrency ITs) may require the PG lane; everything else runs on H2.
- **PG-opt-in lane ≤ the enumerated PG-only set.** Any growth requires a documented justification appended to §4.3.
- **Acceptance test (must pass before this plan is declared done):** with the Docker daemon **stopped**, run `mvn verify`; the default (H2) lane must be **green**. This proves the default path has no Docker dependency and that the H2-migrated tests actually run, not silently skip.
- **Secondary acceptance:** the count of active `@Disabled` markers in `integration/` drops from 18 to ≤ the intentional set (Category B PG-only + Category D perf + Category E pending-P2) after the 8 Category-A + 1 Category-C rebuilds land.

#### PG-lane ownership (precondition, not an open question)

The H2 default lane verifies **Java/JPA wiring and business logic only — not SQL-engine fidelity** (see §7). PG-specific regressions in code that the H2 lane covers are **structurally invisible** to the H2 lane. Therefore the PG (Testcontainers) lane is the *only* defense for engine-level fidelity and is load-bearing.

**Precondition for this plan:** before the PG lane is split out, it must have (a) a **named owner** accountable for keeping it green, and (b) an **enforced, blocking CI cadence** — the PG stage runs as a required check pre-merge-to-`main` (or at minimum a required nightly that blocks the next merge on failure). A "nightly if someone remembers" cadence is explicitly rejected; an unowned, unenforced PG lane will rot and silently void the fidelity guarantee that justifies the whole hybrid model.

---

## 6. Phased Execution (if approved)

> The April draft's Phase 1 ("fix landlord DS + create `application-integration.properties` + delete duplicate extension") is **superseded** — that infra shipped. Phase 1 is now an *audit + categorize*, and the build work is the Category-A/C rebuilds.

### Phase 1 — Audit the 18 `@Disabled` markers (0.5–1 day)

- [ ] Confirm the §3.1 categorization against HEAD (it was re-grounded 2026-06-17): A = 8 legacy multi-tenant, B = 7 PG-only-native (across 4 classes), C = 1 complex-fixture, D = 1 on-demand perf, E = 1 PL/pgSQL report smoke.
- [ ] Confirm the H2 default lane boots green **without Docker** for the non-disabled integration classes — run the §5.5 acceptance test (`mvn verify` with daemon stopped). This is the gate that proves the existing infra works.
- [ ] No infra build in this phase — the profile, bases, `TestDatabaseConfig`, and `TestDataFactory` already exist.

### Phase 2 — Rebuild Category-A legacy tests on the existing H2 base (3–5 days)

- [ ] Rewrite the 4 mobile-service tests (`MobilePicking/Putaway/Replenish/TransferOrder`) onto `BaseIntegrationTest` + the **existing** `common/fixtures/TestDataFactory`. Drop `@Sql` scripts and the `AppPostgresDBSetupExtension` dependency. Mobile flows carry the most v2 bugs — highest-value surface.
- [ ] Rewrite `ClientServiceIntegrationTest`, `SkuRestControllerIntegrationTest`, `OrderRestControllerIntegrationTest` onto `BaseIntegrationTest` (controller variants on `BaseControllerIntegrationTest`) + `TestDataFactory`.
- [ ] Delete `ClientControllerLegacyIntegrationTest` (Category A, no coverage worth rebuilding).
- [ ] Each rebuilt test: remove its `@Disabled`, run on H2, confirm green.

### Phase 3 — Category-C fixtures + cleanup (1–2 days)

- [ ] `ReplenishorderRepositoryIntegrationTest` — provide the Itemdata + Location graph via `TestDataFactory` and move onto `BaseRepositoryIntegrationTest` (H2); or, if the fixtures stay native, keep it on `BasePostgresIntegrationTest`.
- [ ] Delete the duplicate root-package `AppPostgresDBSetupExtension`; retire `H2TestExtension` if nothing still references it. (Optional) collapse `BaseRepositoryIntegrationTest` / `BaseRollbackIntegrationTest` into `BaseIntegrationTest` — cosmetic, low priority.

### Phase 4 — Make the PG lane real (1–2 days) — **gated on §5.5 ownership precondition**

- [ ] Fix `BasePostgresIntegrationTest` landlord wiring (add `@ActiveProfiles("integration")` or a dedicated landlord config; resolves its SBDEV-2217 TODO) so the Category-B repo tests and the 3 SELECT-FOR-UPDATE concurrency ITs can boot.
- [ ] Add the Failsafe profile that activates **only** the enumerated PG-only set (§4.3); keep it bounded.
- [ ] Wire the PG stage as a **required, blocking** CI check (pre-merge or blocking nightly) with the named owner from §5.5.

### Phase 5 — Scenario test scaffold (3–5 days, optional)

- [ ] Add `test/java/.../scenario/` package; build `PickPackScenarioTest` (Scenario 1 end-to-end; drives `ReleaseOrderJobService` directly; WireMock OMS). Use the PG lane where advisory locks / PL/pgSQL are exercised.
- [ ] Add cross-cutting assertion helpers (§5.3); replicate for Club / Transfer Offsite / Receiving once the shape is proven.

**Total:** ~6–11 engineering days for Phases 1–4 (the real migration), +3–5 if the optional scenario layer is in scope. The April estimate (10–16 days) was inflated by the now-deleted infra-build work.

---

## 7. Risks & Open Questions

### 7.1 The fidelity risk is structural — state it plainly

**H2 in PostgreSQL-compat mode is not PostgreSQL.** The H2 default lane verifies **Java/JPA wiring and business logic** — entity mappings, repository method bindings, transaction boundaries, service orchestration. It does **not** verify SQL-engine fidelity: PG date arithmetic, `BOOLEAN`/`VARCHAR` cast semantics, native JOIN behaviour, sequence-caching, timezone handling, `SELECT FOR UPDATE` contention, advisory locks, and PL/pgSQL all behave differently or not at all under H2.

Consequence: **a PG-specific regression in code that the H2 lane covers is invisible to the H2 lane.** A query can be green on H2 and broken on PostgreSQL. The H2 lane gives no signal there. This is the price of the speed, and it is acceptable **only** because the PG (Testcontainers) lane backstops it. The PG lane is therefore load-bearing, and its ownership/cadence (§5.5) is a precondition of the hybrid model, not a nicety. If the PG lane is unowned or non-blocking, the hybrid model silently degrades to "fast but blind."

### 7.2 Remaining risks / questions

| Risk / Question | Notes |
|---|---|
| **PG lane left unowned** | Resolved into a **precondition** (§5.5, §8): named owner + blocking CI cadence before the lane is split. If the org can't commit to this, reconsider whether the hybrid model is worth it versus all-PostgreSQL. |
| **Is anyone running `mvn verify` today?** | Worth confirming — but note the H2 lane already exists and runs, so this is now about CI enforcement, not feasibility. |
| **PL/pgSQL → Java port (P2 Phase A)** | Tracked in the separate P2 plan. Until it lands, `ClientRepositoryIntegrationTest:285` (Category E) stays on the PG lane / disabled. |
| **`BasePostgresIntegrationTest` landlord wiring (SBDEV-2217)** | The one real remaining wiring gap. Scoped to Phase 4. Smaller than the April draft's feared "multi-tenancy bootstrap is broken" — the H2 path proves the bootstrap works; only the Testcontainers context needs the profile/landlord config. |

---

## 8. Decisions Needed From You

Before Phase 2 (the first build phase) starts, please confirm:

1. **Hybrid model OK?** H2 for the fast path (already live), PostgreSQL Testcontainers lane for the enumerated PG-only set (§4.3). Or one engine everywhere (all-PostgreSQL means fixing the Docker dependency and accepting the speed hit; all-H2 means porting the PL/pgSQL functions and losing engine fidelity)?

   **Steelman of the "just fix Docker DX, keep Testcontainers everywhere" alternative (and why this plan still chooses hybrid):** The strongest case against this whole initiative is that the real pain is *local* Docker friction, not CI — CI runners already have Docker (§5.5). A `~/.testcontainers.properties` reuse config, a Colima/dev-container bootstrap, and a `testcontainers.reuse.enable=true` default would remove the silent-hang failure mode and the "Docker not running" foot-gun at a fraction of this multi-plan cost, while keeping **full PG fidelity and zero H2-divergence blindness**. That is a legitimate alternative and a reasonable org could pick it. This plan still recommends hybrid for three concrete reasons: (a) **wall-clock** — the H2 default lane targets a sub-2-minute PR feedback loop (§5.5); a Testcontainers-PG boot per module is minutes slower even with reuse, and that cost is paid on every PR by every engineer; (b) **the infra is already built and partly working** — the H2 lane runs today, so "hybrid" is the lower-marginal-cost path, not a greenfield bet; (c) the fidelity gap is **bounded and disclosed** — the enumerated PG-only set (§4.3) stays on the real engine, and §7.1 makes the PG lane load-bearing for everything SQL-sensitive. If the team weights fidelity and simplicity over PR wall-clock, "fix the DX, keep Testcontainers" is the right call and this plan should be shelved rather than half-adopted. Decide explicitly — do not drift into hybrid by inertia.
2. **Category-A legacy tests — rebuild vs delete?** Recommend rebuilding the 7 substantive ones on the existing H2 base + `TestDataFactory`, deleting only `ClientControllerLegacyIntegrationTest`. Confirm.
3. **Scenario test layer — in or out of scope now?** Phase 5 is optional but is where the real testing gap lives. Your call.
4. **PG-lane owner — name one now (precondition, not an open question).** Per §5.5/§7.1 the PG Testcontainers lane is load-bearing for SQL-engine fidelity. This plan will **not** split the PG lane until there is a named owner **and** a blocking CI cadence (required pre-merge check, or blocking nightly). Please name the owner.

---

## 9. Next Steps

- If approved: I'll update frontmatter `status: active`, flip this file to an execution plan, and start Phase 1.
- If changes wanted: mark them inline, I'll revise.
- If rejected: archive this to `4-Archieves/wms2/plan/` with a note on why.
