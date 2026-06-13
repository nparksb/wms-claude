---
title: "Port PL/pgSQL report functions to Java — v2/wms2-api"
ticket: ""
ticket_url: ""
type: refactor
priority: medium
status: draft
project: [wms2-api]
version: v2
requester: "nam.park@siteboss.net"
created: 2026-04-20
updated: 2026-04-20
related:
  - ./260420-v2-integration-tests-h2-migration-report.md
  - ../../../2-Areas/runbooks/wms1-cancel-packed-parcel.md
tags:
  - plan
  - draft
  - wms2
  - refactor
  - testing
  - plpgsql
  - h2
---

# Port PL/pgSQL report functions to Java — v2/wms2-api

**Ticket:** — (to be filed) — owner: nam.park@siteboss.net
**Project:** wms2-api | **Version:** v2 | **Type:** refactor
**Priority:** medium
**Status:** DRAFT — pending review
**Date:** 2026-04-20

---

## 1. Problem Statement

`v2/wms2-api` ships three PL/pgSQL functions that make the entire integration-test suite PostgreSQL-dependent:

| Function | Defined | Signature | Last revision |
|---|---|---|---|
| `stock_history(timestamp)` | `V1.0.03__wms_functions.sql:13-71` | `(timestamp) → 8-col TABLE` | V1.0.03 |
| `transaction_detail(varchar, varchar, timestamp, timestamp)` | `V1.0.03` → `V1.1.04` → `V2.1.07` | `(…) → 24-col TABLE` | V2.1.07 |
| `transaction_summary(varchar, timestamp, timestamp)` | `V1.0.03` → `V1.1.04` | `(…) → 18-col TABLE` | V1.1.04 |

Consequences today:

- **H2 cannot run integration tests that touch reports.** H2 has no PL/pgSQL; Flyway migrations fail at H2 boot. This blocks Phase 2+ of the separate H2 migration plan ([260420-v2-integration-tests-h2-migration-report.md](./260420-v2-integration-tests-h2-migration-report.md)).
- **Testcontainers is the only way to verify report logic,** and Testcontainers needs a running Docker daemon. When Docker isn't up, `ClientRepositoryIntegrationTest.getTransactionDetail` is silently skipped.
- **The smoke test we just added (`120db54`) is `@Disabled`** because of an unrelated landlord-datasource env issue — but even when that's fixed, the test still requires the PL/pgSQL function to exist.
- **Logic is hard to read, debug, and unit-test.** 350+ lines of dynamic SQL with 6-way UNIONs live inside the DB; the business rules they encode (zero-amount filter, canceled-order accounting, picking vs club split) can't be asserted without a round-trip.

Goal: Move the report SQL out of PL/pgSQL into Java, keep behavior byte-identical, enable H2 testability, and leave a clean rollback path.

---

## 2. Current Architecture

### 2.1 Call chain (production)

```
POST /rest/report/getTransactionReport
  └─ TransactionReportRestController.getTransactionReport()           :75-175
     └─ ClientRepository.getTransactionSummary(code, startStr, endStr) :49-56
        └─ native query → transaction_summary(:code, to_timestamp(:startStr), to_timestamp(:endStr))

POST /rest/report/getTransactionDetailedReport
  └─ TransactionReportRestController.getTransactionDetailedReport()   :177-322
     └─ ClientRepository.getTransactionDetail(code, sku, startStr, endStr) :58-66
        └─ native query → transaction_detail(:code, :sku, to_timestamp(:startStr), to_timestamp(:endStr))

(internal — unused by REST today, but publicly exposed)
StockViewRepository.stockHistoryAfterAsOfDate(Date asOfDate)            :18-20
  └─ native query → stock_history(:asOfDate)
```

### 2.2 Shape of each function (semantics to preserve)

| Function | What it does (semantically) | Sub-queries |
|---|---|---|
| `stock_history(as_of)` | For each SKU with activity, compute total stock today + received / returned / shipped / adjusted since `as_of`, return the back-computed historical stock | 1 outer SELECT from `stock_view` LEFT JOIN 4 correlated subqueries (RECEIVING, RETURN, SHIPPED, MANAGE_INVENTORY) |
| `transaction_detail(client, sku, start, end)` | Timeline view: one row per movement (shipped / received / returned / putaway / replenished / adjusted / damaged / picked / QA / canceled / club-run) + BEGINNING + ENDING inventory rows | 6 UNION ALL branches against `billoflading_position`, `stockrecord`, `customerorder_position`, `stock_history()`, with `transaction_name` CASE labels |
| `transaction_summary(client, start, end)` | Per-SKU rollup across the date range: beginning / received / returned / putaway / adjustments / damaged / depleted-picked / depleted-club / shipped / ending / net-change | Outer GROUP BY over UNION of stockrecord aggregates + billoflading totals + canceled-order adjustments; begin/end come from `stock_history(start)` / `stock_history(end)` |

Both `transaction_*` internally call `stock_history()` (inline in their dynamic SQL).

### 2.3 What's "dynamic" about the dynamic SQL

The bodies use `EXECUTE query USING $1, $2, …` but **do not build the query shape conditionally** — they're just string-interpolating parameters so the `TABLE` return-type declaration works with composite types. Every branch executes on every call. In Java terms: plain parameterized native SQL, no `if/else` branching, no reflection needed.

### 2.4 Duplicated repository methods

`transaction_detail` and `transaction_summary` are each declared in **two** repositories with overlapping queries:

| Method | Repository A | Repository B |
|---|---|---|
| `transaction_detail` | `ClientRepository.getTransactionDetail` (takes String dates, calls `to_timestamp`) | `StockrecordRepository.transactionDetailByClientNumberAndSkuBetweenDates` (takes `Date`) |
| `transaction_summary` | `ClientRepository.getTransactionSummary` (takes String dates) | `StockrecordRepository.transactionSummaryByClientNumberBetweenDates` (takes `Date`) |

Only the `ClientRepository` flavor is wired to the REST endpoints today. The `StockrecordRepository` variants look dead. Consolidate during the port.

### 2.5 Tests

| Test | Covers | Status |
|---|---|---|
| `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest` (lines 284-312) | `transaction_detail()` callability | **@Disabled** — landlord DS env issue |
| *(none)* | `transaction_summary()` | — |
| *(none)* | `stock_history()` | — |

### 2.6 Affected locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `src/main/resources/db/migration/V1.0.03__wms_functions.sql` | 13-553 | All three functions created here |
| 2 | `src/main/resources/db/migration/V1.1.04__wms_functions.sql` | 3-501 | `transaction_detail` + `transaction_summary` replaced |
| 3 | `src/main/resources/db/migration/V2.1.07__update_transaction_detail_pick_amount_filter.sql` | 9-368 | `transaction_detail` zero-amount filter (most recent) |
| 4 | `src/main/java/net/aim_ai/wms/repo/jpa/ClientRepository.java` | 49-66 | `getTransactionSummary`, `getTransactionDetail` native queries |
| 5 | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordRepository.java` | 20-38 | Duplicate `transactionDetailByClientNumberAndSkuBetweenDates`, `transactionSummaryByClientNumberBetweenDates` |
| 6 | `src/main/java/net/aim_ai/wms/repo/jpa/StockViewRepository.java` | 18-20 | `stockHistoryAfterAsOfDate` native query |
| 7 | `src/main/java/net/aim_ai/wms/controller/rest/TransactionReportRestController.java` | 75-322 | Two REST endpoints calling the report methods |
| 8 | `src/test/java/net/aim_ai/wms/integration/repository/ClientRepositoryIntegrationTest.java` | 284-312 | `@Disabled` smoke test for `transaction_detail` |

---

## 3. Design / Proposed Fix

### 3.1 Strategy: "SQL moves, semantics don't"

Move each function body into a Java `@Service` that issues **parameterized native SQL** via Spring's `NamedParameterJdbcTemplate`. The SQL string is the existing function body, verbatim, with `$1/$2/…` → `:namedParam`, wrapped in `SELECT … FROM (…inner select…) AS t`. The result is mapped to the existing projection interfaces (`StockHistoryView`, `TransactionDetailView`, `TransactionSummaryView`) via `RowMapper<…>`.

**Why this and not a "rewrite in Java streams" approach:**

- The UNION queries are battle-tested production logic. Rewriting as Java loops/streams reintroduces dozens of subtle decision points (null handling, BigDecimal scale, date truncation) that the SQL already has right.
- 350 lines of SQL becomes ~350 lines of Java, with much worse readability and performance.
- The SQL uses no PostgreSQL-exclusive constructs once you strip the `LANGUAGE plpgsql` wrapper and the `EXECUTE … USING` indirection. It works on H2 in PostgreSQL-compat mode and on real PostgreSQL.

**What we DO rewrite in Java:** only the `stock_history()` + `transaction_*` composition (today, the DB function calls `stock_history()` inline). In Java, the services will either (a) inline the same sub-SELECT into the transaction_* queries, or (b) call `stockHistoryService.forDate()` and join results in-memory. Option (a) is recommended — single round-trip, same cost as today.

### 3.2 Per-function design

#### 3.2.1 `StockHistoryReportService`

- Input: `LocalDateTime asOfDate`
- Output: `List<StockHistoryView>` (projection unchanged)
- Internals: `NamedParameterJdbcTemplate.query(SQL_STOCK_HISTORY, Map.of("asOfDate", asOfDate), STOCK_HISTORY_ROW_MAPPER)`
- SQL constant `SQL_STOCK_HISTORY` = the body of `stock_history()` function from `V1.0.03:18-71`, with `$1` → `:asOfDate` and no `RETURN QUERY EXECUTE` wrapper.

#### 3.2.2 `TransactionDetailReportService`

- Input: `String clientCode`, `String sku`, `LocalDateTime startDate`, `LocalDateTime endDate`
- Output: `List<TransactionDetailView>`
- SQL constant = body of `transaction_detail()` from `V2.1.07:9-368` (the most recent version; it has the zero-amount filter that v1 shipped in `4a0a26e`). Substitute:
  - `$1` → `:clientCode`
  - `$2` → `:sku`
  - `$3` → `:startDate`
  - `$4` → `:endDate`
  - Inline calls to `stock_history($3)` / `stock_history($4)` become the body of stock_history with the param substituted — OR call `StockHistoryReportService.forDate()` and merge. Keep SQL-inline for zero-regression.
- The existing `to_timestamp(:startDate, 'YYYY-MM-DD hh24:mi:ss')` parsing at the REST layer becomes Java `LocalDateTime.parse(…)` in the controller (`TransactionReportRestController`). Parameters reach the service as `LocalDateTime`, not `String`. **This simplifies the SQL and makes it H2-compatible** (H2 supports `to_timestamp` in PG mode but the string-parsing coupling at the DB boundary is fragile).

#### 3.2.3 `TransactionSummaryReportService`

- Input: `String clientCode`, `LocalDateTime startDate`, `LocalDateTime endDate`
- Output: `List<TransactionSummaryView>`
- SQL constant = body of `transaction_summary()` from `V1.1.04:371-499`.

### 3.3 Controller changes

`TransactionReportRestController` switches from calling `ClientRepository.getTransactionSummary(String, String, String)` to calling `TransactionSummaryReportService.run(String, LocalDateTime, LocalDateTime)`. Date-string parsing (`'YYYY-MM-DD hh24:mi:ss'` — was done in the DB via `to_timestamp`) moves to the controller layer using `DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")`.

No change to request/response DTOs, no change to OpenAPI schema.

### 3.4 Repository cleanup

- **Delete** `StockrecordRepository.transactionDetailByClientNumberAndSkuBetweenDates` and `transactionSummaryByClientNumberBetweenDates` (unused; confirmed in audit).
- **Delete** `ClientRepository.getTransactionDetail` and `ClientRepository.getTransactionSummary` (replaced by the new services).
- **Delete** `StockViewRepository.stockHistoryAfterAsOfDate` (replaced).
- If any of these are referenced from Spring Data REST or other callers, replace with service calls.

### 3.5 Migration strategy — parallel rollout with feature flag

**Don't drop the PL/pgSQL functions in the same release that introduces the Java path.** Stage in four phases:

1. **Phase A (add Java path):** Introduce the three services. REST endpoints still call the old repository methods. Tests compare Java-path output to DB-function output against the same seeded data.
2. **Phase B (flag flip):** Add `app.report.engine=java|plpgsql` system property (read via `LosSyspropRepository`, default `plpgsql`). Controller branches on the flag. Ship with `plpgsql` default in prod; flip to `java` in staging and bake for 2 weeks.
3. **Phase C (default flip):** Default switches to `java`. PL/pgSQL path remains as fallback.
4. **Phase D (cleanup):** Once Phase C has 1 release in prod with no reports issues, add migration `V2.1.08__drop_report_functions.sql` that `DROP FUNCTION IF EXISTS stock_history(timestamp), transaction_detail(…), transaction_summary(…)`. Remove the `app.report.engine` flag and the DB-function branch of the controller.

If Phase D looks risky (these reports are client-facing), phases C and D can stretch over a quarter. The H2 migration (separate plan) can proceed as soon as Phase C lands — once `app.report.engine=java` is default and tested, H2 compatibility no longer depends on dropping the functions, only on not *requiring* them.

### 3.6 Where the port might leak H2 incompatibility

Reviewer should watch for these patterns in the copied SQL:

- **`::type` casts** — rewrite as `CAST(x AS type)` for strict portability.
- **`to_timestamp(…)` inside the SQL body** — replaced by Java `LocalDateTime` parameter binding (see §3.2.2).
- **String concatenation with `||`** — works on both engines in PG compat mode.
- **`COALESCE`, `CASE WHEN`, `UNION ALL`, `GROUP BY`, `LEFT JOIN`** — all standard SQL-92, portable.
- **`ORDER BY column_alias`** — works on both.
- **PostgreSQL-specific functions** (e.g. `date_trunc`, `age`) — **do a grep on each function body during port** and flag anything outside SQL-92.

Any incompatibility discovered becomes a scope expansion, documented in §8 with a decision (port the call site, or keep that one query on PG-only).

---

## 4. V1/V2 Applicability

This plan is **v2-only**. The v1 codebase (`v1/wms-api`) also has these functions; whether to port them is a separate decision.

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `stock_history` PL/pgSQL | Present | Present | V1 unchanged; v2 ports to Java |
| `transaction_detail` | Present (v1 commit `4a0a26e` added zero-amount filter — we just ported this as `V2.1.07`) | Present (same body after `V2.1.07`) | V1 unchanged; v2 ports to Java |
| `transaction_summary` | Present | Present | V1 unchanged; v2 ports to Java |
| Tests | v1 has no integration tests for these | v2 has 1 `@Disabled` | Port unblocks v2 tests; v1 unaffected |

### What does NOT need porting

- V1 stays on PL/pgSQL. V1 uses Testcontainers without complaint today, and the v1 → v2 sync workflow only flows in one direction (v1 → v2). We're not porting v2 Java code back to v1.

---

## 5. Implementation Checklist

### Phase A — Add Java path alongside existing (3–4 days)

- [ ] Create `service/report/StockHistoryReportService.java` with SQL constant + `RowMapper<StockHistoryView>`.
- [ ] Create `service/report/TransactionDetailReportService.java` with SQL constant + `RowMapper<TransactionDetailView>`.
- [ ] Create `service/report/TransactionSummaryReportService.java` with SQL constant + `RowMapper<TransactionSummaryView>`.
- [ ] Unit tests per service using `NamedParameterJdbcTemplate` mock + seeded rows (no DB).
- [ ] Integration tests per service using Testcontainers PostgreSQL, asserting output **matches the existing DB-function output row-for-row** against the same seeded dataset. This is the critical correctness gate.
- [ ] Wire services into `TransactionReportRestController` behind a flag (`app.report.engine=java|plpgsql`, default `plpgsql`).
- [ ] Smoke-test both endpoints with flag on/off in a local run.

### Phase B — Flag flip in staging (time: parallel to Phase A sign-off)

- [ ] Set `app.report.engine=java` in staging `LosSysprop` seed migration (env-specific, not in main Flyway).
- [ ] Run both reports in staging with real client data (pick 2-3 known clients with active activity). Compare output to prod snapshot.
- [ ] Staging bake time: 2 weeks minimum.

### Phase C — Default flip in prod (1 release cycle after Phase B passes)

- [ ] Change `app.report.engine` default to `java` in application code (not just sysprop).
- [ ] Deploy; monitor report-endpoint error rate + p99 latency for 1 full release cycle.

### Phase D — Cleanup (1 release cycle after Phase C)

- [ ] Add `V2.1.08__drop_report_functions.sql`: `DROP FUNCTION IF EXISTS public.stock_history(timestamp);`, same for `transaction_detail(…)` and `transaction_summary(…)`.
- [ ] Remove the PL/pgSQL branch of the controller + the `app.report.engine` flag.
- [ ] Delete the three repository native-query methods (§3.4).
- [ ] Update `V1.0.03`, `V1.1.04`, `V2.1.07` to **not** be dropped from migration history (Flyway is forward-only) — the new `V2.1.08` is the authoritative "they're gone" marker.
- [ ] Enable `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest` — it now works on H2 (no function needed).

### Cross-phase

- [ ] Code review after Phase A.
- [ ] Verifier agent run before Phase C deploy (compare Java vs DB-function output on a fresh seed).
- [ ] Update `sbdocs/3-Resources/architecture/` if a new doc is warranted (optional — probably not; services are self-documenting).

---

## 6. Test Plan

This is a refactor with zero intended behavior change, so **test coverage is the entire value proposition of the plan.** Coverage goals:

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Stock history empty dataset | Seed no activity; call service with `asOfDate=now` | Empty list |
| Stock history single SKU, single receive | Seed 1 item, 1 RECEIVING stockrecord | 1 row with `received=amount`, `historical_stock=total-received` |
| Stock history matches DB function (regression) | Seed 20 mixed activities; run Java service AND `SELECT * FROM stock_history(:d)`; compare row-by-row | Identical output (same columns, same values, same order after ORDER BY) |
| Transaction detail zero-amount PICKING filter | Seed a PICKING stockrecord with amount=0 and one with amount=5 | Output contains only the amount=5 row |
| Transaction detail canceled-order row | Seed a customerorder_position with state=800 (CANCELED) and amountpicked>0 | Output contains a row with `transaction_name='Canceled'` and `depleted_picked` negative |
| Transaction detail BEGINNING/ENDING rows | Seed activity in a date window | Output includes exactly one BEGINNING row and one ENDING row per SKU |
| Transaction detail Java vs DB function | Same seed; Java service output == DB function output | Identical — this is the "are we done?" gate |
| Transaction summary Java vs DB function | Same seed; Java service output == DB function output | Identical |
| Transaction summary canceled-order accounting | Seed normal PICKING + canceled customerorder_position | `depleted_picked` reflects only uncanceled picks |
| Controller flag flip | Call endpoint with `app.report.engine=plpgsql`, then `=java`; same payload | Identical JSON response |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `StockHistoryReportServiceTest` (unit) | `emptyDataset_returnsEmptyList`, `singleReceive_computesHistoricalStock`, … | RowMapper + SQL shape in isolation |
| `StockHistoryReportServiceIT` (Testcontainers) | `matchesDbFunction_overSeededDataset` | Java output bytewise matches `SELECT * FROM stock_history(:d)` |
| `TransactionDetailReportServiceTest` (unit) | one per UNION branch (shipped, received, picked, canceled, BEGINNING, ENDING, club-run) | Each branch in isolation |
| `TransactionDetailReportServiceIT` (Testcontainers) | `matchesDbFunction_overSeededDataset`, `zeroAmountPickingFiltered`, `canceledOrderRowPresent` | Java vs DB function equivalence |
| `TransactionSummaryReportServiceTest` (unit) | per aggregation branch | Each aggregation in isolation |
| `TransactionSummaryReportServiceIT` (Testcontainers) | `matchesDbFunction_overSeededDataset` | Java vs DB function equivalence |
| `TransactionReportRestControllerTest` (existing — update) | `flag_java_matches_plpgsql` | End-to-end parity through the controller |
| `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest` | existing | Re-enable after Phase D (no longer needs function) |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=*ReportService*` | | |
| `mvn verify -Dtest=*ReportServiceIT` | | |
| `mvn verify` (full suite) | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Full behavioral test of the zero-amount filter in isolation from other PICKING logic | The cross-engine parity test (`matchesDbFunction_overSeededDataset`) covers it as a side-effect; a dedicated test is optional |
| Performance test Java vs DB function | Native SQL executes identically regardless of whether it lives in a function or a jdbcTemplate; perf parity is a given. If a reviewer disagrees, add a JMH test in Phase A. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | No | Services are stateless; SQL constants are `static final` strings; RowMappers are stateless |
| 2 | **Connection pool math** | Change per-request DB connection usage? | No | One DB call per endpoint invocation — identical to today (today is one JDBC call into the function; tomorrow is one JDBC call of the inlined query) |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | No | Reports are user-initiated REST calls |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls? | No | Single statement, read-only, auto-commit on completion |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica? | No | Stateless |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | No | Read-only queries are trivially idempotent |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | No | Runs on the caller thread; existing tenant datasource routing already handles this for repositories and the same bean wiring applies to `NamedParameterJdbcTemplate` |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock? | No | Read-only |
| 9 | **Cache invalidation** | Write to an entity that is cached? | No | Read-only |
| 10 | **External notifications** | Send HTTP / message inside a transaction? | No | Pure read path |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 7 | Verified `NamedParameterJdbcTemplate` bean is wired through `TenantDynamicRoutingDataSource`. | (to fill during implementation) |

---

## 8. Notes

### Rollback

The flagged rollout makes rollback trivial at every phase:

- **Phase A:** the flag is `plpgsql` by default — nothing to roll back.
- **Phase B/C:** set `app.report.engine=plpgsql` via `LosSysprop` to revert without redeploy.
- **Phase D (post-function-drop):** rollback requires reapplying `V1.0.03` / `V1.1.04` / `V2.1.07` bodies to re-create the functions (Flyway migration, `V2.1.09__restore_report_functions.sql` in the worst case). This is why Phase D should only happen after Phase C is stable for a full release.

### Parallel work streams

- This plan's **Phase A** unblocks the separate H2 migration plan's **Phase 2** immediately — once the Java path exists, repo/service tests that touch reports can run on H2 even while Phase B/C/D stretch over weeks/months.
- The landlord-datasource spike from the H2 plan is an independent prerequisite. Do it first either way.

### Out of scope

- Rewriting report queries in Java streams / Criteria API. We're moving SQL, not reinventing the reports.
- Adding new report columns or filters. Any such change is a separate plan.
- Changing request/response DTOs. Contracts are frozen for this refactor.
- v1 port. See §4.

### Estimated size

- Phase A: 3–4 days engineering + 1 day code review.
- Phase B: 2 weeks staging bake (calendar time, not effort).
- Phase C: 1 release cycle (calendar).
- Phase D: 0.5 day engineering + 1 release cycle (calendar).
- **Critical-path engineering: ~5 days**; total calendar including bake/soak: ~6 weeks.

### Open questions for reviewer

1. **Should `stock_history()` stay as a Java service if no REST endpoint uses it today?** `StockViewRepository.stockHistoryAfterAsOfDate` is the only caller and appears unused. If truly unused, we can delete it along with the function. Quick grep across the monorepo recommended before starting Phase A.
2. **Date parsing: controller-layer vs service-layer?** I've proposed controller-layer. Either works; controller-layer keeps services strictly-typed.
3. **Single `ReportSqlConstants` class vs per-service constants?** Per-service is cleaner but duplicates the `stock_history` sub-query into `transaction_detail` and `transaction_summary`. A shared constant is better. Decide during Phase A design.
4. **Is the Phase A integration test's "Java output == DB function output" assertion the right gate?** I think yes — it directly answers "did we break anything?" — but it requires Testcontainers for Phase A. That's fine (Phase A is where we still have Testcontainers running); Phase B onwards can H2-ify.

### Decisions needed before kickoff

- Approve phased rollout (A→B→C→D with flag).
- Confirm no report DTO/contract changes.
- Confirm Phase A is scheduled after the H2 plan's Phase 1 (landlord datasource fix), so integration tests unblock simultaneously.

---

## 9. Related Work — Scope Boundary for Full PostgreSQL Independence

This plan covers the **3 PL/pgSQL functions** in v2/wms2-api. Three other PostgreSQL-specific surfaces remain after this plan completes; each is tracked separately:

| Surface | Why it's not here | Tracked by |
|---|---|---|
| **`pg_try_advisory_lock` / `pg_advisory_unlock`** in `AdvisoryLockService.java` — used by 5 scheduled jobs for distributed mutex | Not a PL/pgSQL function — it's a PG built-in invoked via `createNativeQuery`. Different replacement strategy (interface + per-engine impl, or ShedLock). | [260421-v2-replace-pg-advisory-lock.md](./260421-v2-replace-pg-advisory-lock.md) |
| **172 `nativeQuery = true` repository methods with PG-specific syntax** — `::text` casts, `FOR UPDATE OF <table>`, PG date math in `MessageRepository`, PG boolean cast in `PrinterRepository` | Too diffuse for a single plan. Addressed per-test (keep on `postgres-integration` profile) and per-query (migrate opportunistically). | [260420-v2-integration-tests-h2-migration-report.md §3 + §4.3](./260420-v2-integration-tests-h2-migration-report.md) |
| **Landlord datasource wiring in test profile** (the actual cause of most `@Disabled` markers today) | Test infrastructure, not a feature migration. | [260420-v2-integration-tests-h2-migration-report.md §6 Phase 1](./260420-v2-integration-tests-h2-migration-report.md) |

Completing this plan + the advisory-lock sibling plan + the H2 migration plan's Phase 1 together gets `mvn verify` to run on H2 without Docker for the bulk of the suite. A small set of tests (~5, the PG-only list in the H2 migration plan) remain opt-in Testcontainers.
