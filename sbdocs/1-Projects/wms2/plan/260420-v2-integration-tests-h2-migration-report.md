---
title: "WMS v2 Integration Tests — H2 Migration Feasibility Report"
type: plan
status: draft
version: v2
scope: wms2-api
owner: "nam.park@siteboss.net"
created: 2026-04-20
updated: 2026-04-20
last_verified: 2026-04-20
verified_by: "initial authoring — pending user review"
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

## 0. TL;DR

- **Can H2 replace Testcontainers PostgreSQL?** **Yes — for ~60% of the suite.** The other ~40% hits PL/pgSQL functions and `pg_advisory_lock` and genuinely needs PostgreSQL. Recommended target state is a **hybrid**: H2 by default for fast local + CI, opt-in PostgreSQL profile for the tests that need it.
- **Is the current suite worth keeping?** **Mixed.** 17 of 20 integration tests are currently `@Disabled` (landlord datasource env issue or legacy `AppPostgresDBSetupExtension`). Only 3 actually run today. Most of the "disabled" tests are salvageable if infrastructure is fixed; a few should be deleted outright.
- **Why "doesn't work anymore"?** The base class `AppPostgresDBContainer` enables `.withReuse(true)` which needs a live local Docker daemon; tests hang silently if Docker isn't running. Separately, the landlord datasource config is broken in the test profile, which masks every integration-test failure behind `HikariConfig: dataSource or jdbcUrl is required`.

---

## 1. Current Infrastructure — Evidence

### 1.1 Testcontainers base

| File | Key config |
|---|---|
| `src/test/java/net/aim_ai/wms/common/extension/AppPostgresDBContainer.java:10-19` | `postgres:12` image, db `wms_test`, creds `test/test`, **`.withReuse(true)`** |
| `src/test/java/net/aim_ai/wms/common/extension/AppPostgresDBSetupExtension.java:18-26` | Runs Flyway manually before suite; duplicated at `src/test/java/net/aim_ai/wms/AppPostgresDBSetupExtension.java` |
| `src/test/resources/application.properties:25` | `spring.datasource.url=jdbc:postgresql://localhost:5432/wms_test` hardcoded |
| `src/test/resources/application.properties:33` | `spring.flyway.enabled=false` — Flyway is manual via extension |
| `src/test/resources/application.properties:39` | `spring.jpa.hibernate.ddl-auto=validate` (no auto-DDL) |

### 1.2 An H2 extension already exists (partially wired)

- `src/test/java/net/aim_ai/wms/common/H2TestExtension.java:39-56` — H2 with `MODE=PostgreSQL`, Flyway disabled, `ddl-auto=create-drop`.
- `BaseRepositoryIntegrationTest.java:24` and `BaseIntegrationTest.java:23` reference `@ActiveProfiles("integration")`, but `application-integration.properties` **does not exist** — properties are injected via `H2TestExtension` at runtime.
- This is a half-finished migration. Someone started the H2 path and didn't finish it.

### 1.3 Why Testcontainers "stopped working"

Two root causes, not one:

1. **No local Docker daemon.** `.withReuse(true)` needs `/var/run/docker.sock` reachable. If Docker Desktop / Colima isn't running, tests hang or fail with cryptic timeouts. No `.testcontainers.properties` overrides this.
2. **Broken landlord datasource in the test profile.** Every `BaseRepositoryIntegrationTest` subclass fails `ApplicationContext` load with `HikariConfig: dataSource or jdbcUrl is required`. This is what motivated the `@Disabled` annotations on `ClientRepositoryIntegrationTest` (line 285), `BillofladingPositionRepositoryTest`, and the `120db54` smoke-test commit on the current branch. **This would still fail on H2** — the landlord/tenant routing bootstrap is independent of the underlying database engine.

---

## 2. PostgreSQL-Specific Surface Area — What Breaks on H2

| Feature | Location | Impact |
|---|---|---|
| **PL/pgSQL functions** — `stock_history()`, `transaction_detail()` | `V1.0.03__wms_functions.sql:13-71`, `V1.1.04__wms_functions.sql:4`, `V1.1.12__update_transaction_detail_pick_amount_filter.sql` | H2 has no PL/pgSQL. Flyway migration will fail at H2 boot. 6 `CREATE OR REPLACE FUNCTION` sites total. |
| **`pg_advisory_lock`** | `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java:37,54` | PostgreSQL-only. Used by scheduled jobs: `ORDER_RELEASE`, `REPLENISH_ORDER`, `CLEAN_UP_MESSAGES`, `STOCK_SUMMARY_EXPORT`, `RELEASE_EXPIRED_PICKING`. Any test that drives a scheduled job or calls `AdvisoryLockService` will fail on H2 at runtime. |
| **Native queries** (172 `nativeQuery = true` annotations) | repos throughout | Most are portable. Landmines: `::text` casts, `FOR UPDATE OF <table>`, PG date arithmetic, PG `BOOLEAN` literal comparisons. The `MessageRepository` archive/delete-with-LIMIT queries are PG-only. |
| **`to_timestamp()` in ClientRepository.getTransactionDetail** | query definition for `transaction_detail()` invocation | Directly blocks the `V1.1.12` port we landed on `phase4`. |

**Bottom line:** H2 can run repo tests that stick to JPQL + JPA features. It cannot run tests that exercise PL/pgSQL functions, advisory locks, PG-only native SQL, or the scheduled-job mutex.

---

## 3. Test-by-Test Verdict

20 integration test classes. **17 are currently `@Disabled`** (either class-level or every meaningful inner class).

| Test class | Path | Status today | H2-portable? | Recommendation |
|---|---|---|---|---|
| **ClientRepositoryIntegrationTest** | `repository/` | inner `GetTransactionDetailSmokeTest` disabled | No — PL/pgSQL | **Keep on PostgreSQL profile.** Unblocks once landlord DS is wired. |
| **CyclecountRepositoryIntegrationTest** | `repository/` | inner `NativeSqlWithJoins` disabled | Yes (JPQL portion) | **Migrate to H2.** Disable the native-JOIN inner class or add fixtures. |
| **LocationRepositoryIntegrationTest** | `repository/` | inner class disabled (fixture complexity) | Yes | **Migrate to H2.** |
| **MessageRepositoryIntegrationTest** | `repository/` | 4 inner classes disabled | No — PG date math, DELETE...LIMIT | **Keep on PostgreSQL profile.** |
| **PickingorderRepositoryIntegrationTest** | `repository/` | running | Yes | **Migrate to H2.** |
| **PrinterRepositoryIntegrationTest** | `repository/` | 2 inner classes disabled (PG BOOLEAN cast) | Partial | **Migrate baseline to H2; keep BOOLEAN inner class on PG profile.** |
| **ReplenishorderRepositoryIntegrationTest** | `repository/` | class-level disabled (fixture complexity) | Yes if fixtures provided | **Migrate to H2 with `TestDataFactory`; unblock.** |
| **SyspropRepositoryIntegrationTest** | `repository/` | running | Yes | **Migrate to H2.** |
| **UserRepositoryIntegrationTest** | `repository/` | running | Yes | **Migrate to H2.** |
| **AdviceServiceIntegrationTest** | `service/` | running, mocks externals | Yes | **Migrate to H2.** |
| **ClientServiceIntegrationTest** | `service/` | class-level disabled | Legacy | **Delete or rewrite from scratch on new H2 base.** |
| **ClientControllerIntegrationTest** | `controller/` | stub (32 LOC, no asserts) | — | **Delete.** No coverage. |
| **ClientControllerLegacyIntegrationTest** | `controller/` | class-level disabled | — | **Delete.** |
| **CustomerOrderControllerIntegrationTest** | `controller/` | (not examined in detail) | TBD | Verify before deciding. |
| **OrderRestControllerIntegrationTest** | `controller/rest/` | class-level disabled, `@Sql`-based | Legacy | **Delete and rebuild on H2 base with `TestDataFactory`** (no `@Sql` scripts). |
| **SkuRestControllerIntegrationTest** | `controller/rest/` | class-level disabled, `@Sql`-based | Legacy | **Same — rebuild.** |
| **MobilePickingServiceIntegrationTest** | `service/mobile/` | class-level disabled, `@Sql`-based | Legacy | **Rebuild on H2 base.** Mobile flows are where v2 has the most bugs — most valuable test surface. |
| **MobileTransferOrderServiceIntegrationTest** | `service/mobile/` | same | Legacy | **Rebuild.** |
| **MobilePutawayServiceIntegrationTest** | `service/mobile/` | same | Legacy | **Rebuild.** |
| **MobileReplenishServiceIntegrationTest** | `service/mobile/` | same | Legacy | **Rebuild.** |

**Totals:** 8 migrate to H2 • 3 keep on PostgreSQL profile • 4 rebuild on new H2 base • 3 delete • 2 verify first.

---

## 4. Recommended Target State — Hybrid

### 4.1 Two test modes, one source tree

| Mode | Annotation / profile | DB | Invocation | Use for |
|---|---|---|---|---|
| **Default (H2)** | `@ActiveProfiles("integration")` via `H2TestExtension` | H2 in-memory, `MODE=PostgreSQL`, `ddl-auto=create-drop` | `mvn verify` | Fast local + CI run. ~8 migrated tests + 4 rebuilt mobile tests + 2 service tests. |
| **Opt-in PostgreSQL** | `@ActiveProfiles("integration-pg")` + Testcontainers extension | `postgres:12` via Testcontainers, Flyway runs real migrations | `mvn verify -Pintegration-pg` | ~5 tests that exercise PL/pgSQL functions, advisory locks, or PG-only native SQL. |

### 4.2 Fixes that unblock H2 adoption

1. **Wire landlord datasource for the test profile.** This is the single biggest lever — it unblocks ~9 `@Disabled` tests regardless of DB engine. Likely fix: point `landlordDataSource` bean at the same H2 instance (or a second H2 schema) in `TestDatabaseConfig`.
2. **Create `application-integration.properties`.** Today it's referenced by `@ActiveProfiles("integration")` but doesn't exist — config flows only through `H2TestExtension`. Make the profile self-sufficient.
3. **Unify the base classes.** There are currently 4 base classes and 2 duplicated extensions. Collapse to one pair: `BaseIntegrationTest` (H2) + `BasePostgresIntegrationTest` (Testcontainers). Delete `BaseRepositoryIntegrationTest`, the root-package `AppPostgresDBSetupExtension` duplicate, and `ClientControllerLegacyIntegrationTest`.
4. **Provide a `TestDataFactory`** (e.g. `test/java/.../common/fixture/TestDataFactory.java`) so rebuilt mobile tests don't need `@Sql` scripts. Pattern: `TestDataFactory.clientWithItems("ACME", 5)` returns persisted entity graph.
5. **Split PL/pgSQL migrations.** Move `stock_history()` and `transaction_detail()` into a `db/migration/postgres/` subtree and exclude it from the H2 Flyway (if Flyway is later re-enabled on H2). Or: port the functions to Java services and let tests assert against Java logic.

### 4.3 The tests that must stay on PostgreSQL

Only **5 realistic scenarios** justify a `postgres-integration` profile:

1. `ClientRepositoryIntegrationTest.getTransactionDetail` — calls `transaction_detail()` PL/pgSQL.
2. `MessageRepositoryIntegrationTest` — 4 inner classes using PG date math, `INSERT INTO SELECT` archive, `DELETE … LIMIT`.
3. `PrinterRepositoryIntegrationTest.findByTypeAndProcessdefaultTrue` — PG boolean cast in native SQL.
4. Any test that drives a scheduled job (directly or indirectly via `AdvisoryLockService`).
5. Any new test that deliberately verifies PL/pgSQL function correctness (e.g. behavioral test of the V1.1.12 filter fix).

Everything else either doesn't need real SQL (pure Java logic — use unit tests) or can run on H2 PG-compat mode.

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

- `ReleaseOrderJobService`, `ReplenishOrderJob`, `CleanupMessagesJob` — expose test-only triggers on the `postgres-integration` profile so scenario tests don't wait for cron.
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

### 5.5 CI pipeline shape

- **Default stage (fast):** `mvn verify` with H2 integration profile. Target: <2 min. Runs on every PR.
- **Extended stage (slow, on-demand or nightly):** `mvn verify -Pintegration-pg` with Testcontainers. Runs pre-merge-to-main or nightly. No local Docker assumption for dev, but CI runners have it.
- No more silent hangs when Docker isn't running — H2 has no daemon dependency.

---

## 6. Phased Execution (if approved)

### Phase 1 — Unblock (1–2 days)

- [ ] Fix landlord datasource wiring in `TestDatabaseConfig` so `@ActiveProfiles("integration")` boots without the Hikari error. **Highest-leverage single change.**
- [ ] Create `application-integration.properties`. Delete runtime property injection that `H2TestExtension` does.
- [ ] Delete duplicate `AppPostgresDBSetupExtension` at the root of `src/test/java/net/aim_ai/wms/`.
- [ ] Remove `@Disabled` from tests that only fail due to landlord wiring (`BillofladingPositionRepositoryTest`, `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest`, the smoke test from commit `120db54`). Re-run; confirm they now pass.

### Phase 2 — H2 migration (2–3 days)

- [ ] Migrate 7 H2-portable repo tests to `BaseIntegrationTest` (User, Sysprop, Pickingorder, Cyclecount, Location, Replenishorder, AdviceService). Delete their Testcontainers dependencies.
- [ ] Introduce `TestDataFactory` with the 4–5 entity graphs the mobile tests need.
- [ ] Collapse base classes to `BaseIntegrationTest` / `BasePostgresIntegrationTest`. Delete `BaseRepositoryIntegrationTest`.
- [ ] Confirm `mvn verify` (default) runs without Docker.

### Phase 3 — Rebuild mobile + REST tests (3–5 days)

- [ ] Rewrite the 4 mobile-service tests against `BaseIntegrationTest` + `TestDataFactory`. Drop all `@Sql` scripts.
- [ ] Rewrite (or delete, case by case) the 2 REST controller tests.
- [ ] Delete the 3 tests marked **Delete** in §3.

### Phase 4 — Scenario test scaffold (3–5 days, optional Phase)

- [ ] Add `test/java/.../scenario/` package.
- [ ] Build `PickPackScenarioTest` — the full Scenario 1 from the smoke checklist end-to-end (`postgres-integration` profile; drives `ReleaseOrderJobService` directly; WireMock OMS).
- [ ] Add cross-cutting assertion helpers (§5.3).
- [ ] Replicate pattern for 2–3 more scenarios (Club, Transfer Offsite, Receiving) once the shape is proven.

### Phase 5 — CI split (0.5 day)

- [ ] Failsafe profile `integration-pg` that activates `@ActiveProfiles("integration-pg")` tests only.
- [ ] CI pipeline: fast stage runs default; extended stage runs `-Pintegration-pg` nightly or pre-merge.

**Total:** 10–16 engineering days depending on scenario-test ambition.

---

## 7. Risks & Open Questions

| Risk / Question | Notes |
|---|---|
| **H2 PostgreSQL compat mode ≠ PostgreSQL** | Sequence caching, timezone semantics, optimistic-lock retry patterns can diverge. Mitigation: keep the `postgres-integration` profile as a safety net for anything behavior-sensitive. |
| **Is anyone running `mvn verify` today?** | If the answer is "no one," this work may be lower priority than building the missing scenario layer directly on PostgreSQL. |
| **Should the 3-4 PL/pgSQL functions be ported to Java?** | Out of scope for this report — but worth a separate design decision. If yes, the "keep on PostgreSQL" list shrinks further. |
| **Landlord datasource fix may be harder than expected.** | If multi-tenancy bootstrap is fundamentally broken in test config, Phase 1 expands significantly. Worth a 2-hour spike before committing to the timeline. |

---

## 8. Decisions Needed From You

Before Phase 1 starts, please confirm:

1. **Hybrid model OK?** H2 for fast path, PostgreSQL-profile for ~5 tests. Or do you want one engine everywhere (which means either keeping Testcontainers and fixing the Docker dependency, or rewriting the PL/pgSQL functions in Java)?
2. **Delete vs preserve `@Disabled` legacy tests?** I recommend deleting the 3 explicitly called out in §3. Confirm.
3. **Scenario test layer — in or out of scope now?** Phase 4 is optional but is where the real testing gap lives (per the smoke-test checklist analysis). Your call.
4. **Who owns the PostgreSQL-profile tests?** If nobody runs them nightly, they'll rot. Need an owner or a CI cadence.
5. **Landlord datasource spike first?** Recommended — 2 hours to verify Phase 1 is actually achievable before committing the rest.

---

## 9. Next Steps

- If approved: I'll update frontmatter `status: active`, flip this file to an execution plan, and start Phase 1.
- If changes wanted: mark them inline, I'll revise.
- If rejected: archive this to `4-Archieves/wms2/plan/` with a note on why.
