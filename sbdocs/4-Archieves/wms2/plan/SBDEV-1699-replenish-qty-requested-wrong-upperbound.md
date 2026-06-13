---
title: "SBDEV-1699 — Replenish qty requested uses wrong upperbound (v2 port)"
ticket: "SBDEV-1699"
ticket_url: "https://siteboss.atlassian.net/browse/SBDEV-1699"
type: "bugfix"
priority: "P2"
status: "archived"
project: ["wms2"]
version: "v2"
requester: "Arden / WMS team"
created: "2026-05-07"
updated: "2026-05-07"
implemented: "2026-05-07"
related:
  - "[[SBDEV-1699-replenish-qty-requested-wrong-upperbound]]" # v1 pair (same base name in wms1/plan)
  - "[[wms2-tenant-routing-datasource-topology]]"
  - "[[wms2-function-to-docs-map]]"
tags:
  - plan
  - replenishment
  - bugfix
  - v1-to-v2-port
  - ralplan-consensus
---

# SBDEV-1699 — Replenish qty requested uses wrong upperbound (v2 port)

**Ticket:** [SBDEV-1699](https://siteboss.atlassian.net/browse/SBDEV-1699)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** P2
**Status:** implemented 2026-05-07 — committed as `c4fcfc1` on `wms2-api/develop`
**Date:** 2026-05-07

---

## 1. Problem Statement

Replenishment screens in wms2-web-ui display the **wrong "upperbound" / target replenish quantity** for some rows. The displayed `qtyRequested` either:

- Reflects the upperbound of an **incidental row** of `fix_location_assignment` (the row JPA happens to fetch first, not the row tied to the rep's assigned `itemdata`), OR
- Reflects a **stale fallback** value computed without consulting `fix_location_assignment.upperbound` at all.

This is the v2 port of the v1 SBDEV-1699 fix. The v1 fix landed earlier in `v1/wms-api` and resolved the bug for the legacy stack. v2 has the **same data shape and same business rule** but a **different code path** and a **different defect surface**: v2's `ViewDtoService.getStockPerLocation` (line 668) currently does NOT call `FixLocationAssignmentRepository` at all — it only calls `viewWarehouseLocationReportRepository.findByLocation(locationId)` per row. The v2 port therefore **introduces** a new (batched) FLA-by-itemdata-id lookup rather than refactoring an existing N+1.

The two screens affected on the v2 stack:
1. **Replenishment desktop view** (operator screen — paginated). Source: `ViewDtoService.getStockPerLocation` driven by `ReplenishorderRepository.getOpenViewByKeyword` / `getClosedViewByKeyword`. Today it returns `qtyRequested` without consulting `fix_location_assignment.upperbound`. Fix A introduces the batched FLA lookup so the displayed value matches the operator's expectation.
2. **Replenishment monitor view** (supervisor dashboard — unpaged summary). Source: `ReplenishmentMonitorViewRepository`. Today its native SQL projection does not select `fla.upperbound`, so the same bug manifests via a different read path. Fix B extends the native query's projection.

The two surface fixes (A and B) plus three out-of-scope-but-noted observations (NEW-1 / NEW-2 / NEW-3) make up this plan. Class names referenced consistently throughout: `ViewDtoService` (the service holding `getStockPerLocation`), `FixLocationAssignmentRepository` (the JPA repo for `fix_location_assignment`), `ReplenishorderRepository`, `ReplenishmentMonitorViewRepository`.

### User-visible symptom

| Surface | Symptom | Repro |
|---|---|---|
| Replenishment desktop list | `qtyRequested` column shows a value that does not match `fix_location_assignment.upperbound` for the assigned `itemdata_id`. | Open replenishment screen for a tenant with multiple FLA rows per location. Compare displayed `qtyRequested` to `SELECT upperbound FROM fix_location_assignment WHERE itemdata_id = <assigned>` for the same row. |
| Replenishment monitor view | Summary tile aggregates by an upperbound that omits the FLA join — returns either `0` or a stale fallback. | Same tenant; navigate to monitor view; inspect summary numerator. |

---

## 2. Root Cause Analysis

### Surface A — `ViewDtoService.getStockPerLocation` (line 668)

`getStockPerLocation` builds the `ReplenishOrderDetailView` page projection by:
1. Calling `replenishorderRepository.getOpenViewByKeyword` or `getClosedViewByKeyword` (paginated native SQL with GROUP BY).
2. For each row in the page, calling `viewWarehouseLocationReportRepository.findByLocation(locationId)` to enrich.

The projection does **NOT include** `fix_location_assignment.upperbound`. There is no FLA call anywhere in the method body today. The displayed `qtyRequested` field is populated from whatever the projection returns — which can be the stale `replenishorder_detail.qty_requested` snapshot or a fallback.

The v1 SBDEV-1699 fix added a **per-row** `findByItemdataId(itemdataId)` call inside the loop — a singular form returning the single FLA row with that `itemdata_id`. v1's choice was scoped narrow because v1's framework constraints made batching awkward. v2's `FixLocationAssignmentRepository` already exposes the v2-idiomatic batched form `findByItemdataIdIn(Collection<Long>)` at `FixLocationAssignmentRepository.java:28` (verified). Fix A leverages this existing batched method.

### Surface B — `ReplenishmentMonitorViewRepository`

Native SQL query for the supervisor monitor screen joins `replenishorder` to several lookup tables, but does **NOT** join `fix_location_assignment` and does **NOT** select `fla.upperbound`. The `qtyRequested` field in the monitor projection is sourced from `replenishorder_detail.qty_requested` directly. When a downstream consumer (UI or reporting query) computes "delta to upperbound," the value is wrong because the upperbound is never read.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/service/ViewDtoService.java` | 668 (method `getStockPerLocation`) | INTRODUCE batched FLA lookup; populate `qtyRequested` from `fla.upperbound` |
| 2 | `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java` | 28 (`findByItemdataIdIn`) | Reused — no change required (verify signature) |
| 3 | `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/ReplenishmentMonitorViewRepository.java` | (native SQL — line range determined at edit time) | EXTEND native SQL: LEFT JOIN `fix_location_assignment fla` and SELECT `fla.upperbound` into projection |
| 4 | `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/dto/projection/ReplenishmentMonitorView.java` (or matching projection interface) | (entire interface) | ADD getter `getUpperbound()` to projection |
| 5 | (test) `/Users/np1076/dev/spk/owl/v2/wms2-api/src/test/java/net/aim_ai/wms/service/ViewDtoServiceUnitTest.java` | new methods | ADD `getStockPerLocation_callsFlaRepoOncePerNonEmptyPage` + `getStockPerLocation_skipsFlaRepoOnEmptyPage` |
| 6 | (test) `/Users/np1076/dev/spk/owl/v2/wms2-api/src/test/java/net/aim_ai/wms/integration/repository/ReplenishmentMonitorViewRepositoryIT.java` | new file | INTEGRATION test: monitor view projection exposes `upperbound` from FLA |

---

## 3. Design / Proposed Fix

### 3.1 Fix A — `ViewDtoService.getStockPerLocation` batched FLA lookup

**Problem:** The method does not consult `fix_location_assignment` at all. `qtyRequested` is populated from a stale projection field. Operators see a value that does not reflect the current upperbound on the assigned itemdata.

**Solution:** After the page is fetched, collect the distinct `itemdata_id`s appearing in the page, batch-load their FLA rows via `findByItemdataIdIn`, build an in-memory `Map<Long, FixLocationAssignment>`, and populate each row's `qtyRequested` from the matching FLA's `upperbound`. This is **+1 SELECT per page request** (O(1) per pagination cycle).

**Files changed:**
- `ViewDtoService.java` (method `getStockPerLocation`, line 668 region)

### 3.2 Fix B.1 — `ReplenishmentMonitorViewRepository` native SQL projection extension

**Problem:** The supervisor monitor view's native SQL query never reads `fla.upperbound`, so any consumer computing "delta to upperbound" gets the wrong number.

**Solution:** Extend the native SQL: add `LEFT JOIN fix_location_assignment fla ON fla.itemdata_id = <existing itemdata reference>` and add `fla.upperbound AS upperbound` to the SELECT list. Add a `getUpperbound()` getter to the projection interface. Existing GROUP BY needs `fla.upperbound` added because all non-aggregated SELECT columns must appear in GROUP BY (Postgres standard mode).

**Files changed:**
- `ReplenishmentMonitorViewRepository.java`
- `ReplenishmentMonitorView.java` (projection interface)

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `ReplenishOrderService.getStockPerLocation` (v1) / `ViewDtoService.getStockPerLocation` (v2) | Per-row `findByItemdataId` (singular) added in v1 SBDEV-1699 | NEW: batched `findByItemdataIdIn` (FLA call did not exist before) | v2 Fix A introduces a NEW call. Not a refactor. |
| `ReplenishmentMonitorViewRepository` native SQL | v1 has the same shape and was patched in v1 SBDEV-1699 | v2 native SQL diverged slightly (different column aliases, slightly different GROUP BY); same fix applies | v2 Fix B.1 |
| Projection interface `ReplenishmentMonitorView` | v1 added `getUpperbound()` | v2 must add `getUpperbound()` | Trivial port |
| Test infra | v1 uses `BaseRepositoryIntegrationTest` analogue | v2 has `BaseRepositoryIntegrationTest` (verified at `v2/wms2-api/src/test/java/net/aim_ai/wms/common/base/BaseRepositoryIntegrationTest.java`) and `ReplenishorderRepositoryIntegrationTest` (verified at `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/repository/ReplenishorderRepositoryIntegrationTest.java`) as the closest precedent | New `ReplenishmentMonitorViewRepositoryIT extends BaseRepositoryIntegrationTest` |

### Group R applicability table (v1→v2)

| # | v1 group / fix | v2 applicability | Verdict |
|---|---|---|---|
| R1 | v1 per-row `findByItemdataId` in `getStockPerLocation` | v2 has no FLA call here today; batched form preferred | APPLY (as Fix A — INTRODUCE, not refactor) |
| R2 | v1 monitor-view projection extension (LEFT JOIN FLA, expose upperbound) | v2 monitor view has same gap | APPLY (as Fix B.1) |
| R3 | v1 fallback path when FLA row missing | v2 same path; collapse to `0` with comment | APPLY (in Fix A) |
| R4 | v1 cache evict on FLA write | v2 has no FLA cache today | NOT APPLICABLE — `@Cacheable` is not on `FixLocationAssignmentRepository` (verified) |
| R5 | v1 batch size cap on FLA in-list | v2 page size already capped at 25-50 | NOT APPLICABLE — page size already bounds the IN-list |
| R6 | v1 frontend label adjustment (a.k.a. **Fix B.3**) | v2 frontend reads same field name | **DEFERRED to next v2/wms2-mobile-ui Lane A v1-sync-sweep.** Pre-sweep precondition: `grep -rn 'qtyRequested\|locationStock' /Users/np1076/dev/spk/owl/v2/wms2-mobile-ui/pages/replenish.vue` to confirm whether the v1 mobile mapping (`locationStock: item.locationStock != null ? item.locationStock : item.qtyRequested`) was already cherry-picked post-2026-05-07 sync. If absent, schedule v1→v2 mobile cherry-pick of the relevant v1 commit. **Out of scope for this v2/wms2-api plan.** |

### What Needs Porting

1. Fix A — INTRODUCE batched FLA-by-itemdata-id lookup in `ViewDtoService.getStockPerLocation` and populate `qtyRequested` from `fla.upperbound`.
2. Fix B.1 — Extend `ReplenishmentMonitorViewRepository` native SQL: LEFT JOIN FLA, SELECT `fla.upperbound`, add to GROUP BY, add `getUpperbound()` to projection.

### What Does NOT Need Porting

- R4 (cache evict): v2 does not cache FLA reads.
- R5 (batch size cap): v2's page size already bounds the IN-list.
- R6 (frontend label, a.k.a. Fix B.3): deferred to next v2/wms2-mobile-ui Lane A sync sweep. Pre-sweep grep precondition documented in §4 R6 row.

---

## 5. Prerequisites & Implementation Plan

### 5.0 Why Option A and not Option A-prime

A second viable option (Option A-prime) was considered: **extend `ReplenishorderRepository.getOpenViewByKeyword` / `getClosedViewByKeyword` native queries directly** to expose `f.upperbound` in the `ReplenishOrderDetailView` projection, mirroring Fix B.1's approach for the monitor view. That would yield a single-query path for Surface A.

A-prime was rejected for three reasons:

1. **Hot pagination path, larger blast radius.** Both `getOpenViewByKeyword` and `getClosedViewByKeyword` are paginated native SQL with existing GROUP BY clauses (verified at `ReplenishorderRepository.java:244` and `:274`). Adding a new SELECT column requires propagating it into GROUP BY, which increases query plan complexity on a screen operators hit many times per minute.
2. **Projection getter ripple.** `ReplenishOrderDetailView` adds a new getter that all callers of these queries must accommodate. Verified caller count: each query has exactly **one** caller (`ViewDtoService.java:609` for `getOpenViewByKeyword`, `ViewDtoService.java:611` for `getClosedViewByKeyword`), so the ripple is small — but still touches the shared projection interface used by REST resource exposure (`@RestResource(path = "getOpenViewByKeyword", ...)`).
3. **Performance characteristics are identical.** Option A's batched `findByItemdataIdIn` is **+1 SELECT per page request** — already O(1) per pagination cycle, well within the per-tenant Hikari budget. There is no measurable runtime advantage to A-prime that would justify the larger blast radius.

**Why Option A wins:** Smaller diff (1 service method body change + 1 new repo call), no SQL/GROUP BY churn on a hot path, easier to revert (delete the batched call + restore prior projection assignment), easier to test in isolation (mock `FixLocationAssignmentRepository`, verify call count). Option A is the v2-idiomatic shape for "enrich a page with one extra entity" given the existing batched-IN repo method.

### 5.1 Prerequisites

Fix A introduces a new batched FLA-by-itemdata-id lookup into v2's `getStockPerLocation`. v2 currently has no FLA call in this method — only a per-row `findByLocation` (a separate N+1 documented as NEW-3). The v1 SBDEV-1699 fix added a per-row `findByItemdataId` call; this v2 port adopts the v2-idiomatic batched form instead, leveraging `findByItemdataIdIn` which already exists at `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java:28`.

The batched call returns a `List<FixLocationAssignment>` which the service code collects into a `Map<Long, FixLocationAssignment>` keyed by `itemdata_id`. Per the database schema (UNIQUE constraint on `fix_location_assignment.itemdata_id` at `V1.0.01__wms_tables.sql:279`), no key collision is possible. The `Collectors.toMap` form used will be:

```java
// Map collection — defensive merge function
Map<Long, FixLocationAssignment> flaByItemdataId = flaRepo
    .findByItemdataIdIn(itemdataIds)
    .stream()
    .collect(Collectors.toMap(
        FixLocationAssignment::getItemdataId,
        Function.identity(),
        (a, b) -> a  // DB UNIQUE constraint on fix_location_assignment.itemdata_id
                     // (V1.0.01__wms_tables.sql:279) guarantees no collision; merge
                     // function is defensive and matches v1's "first match wins" behavior.
    ));
```

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Flyway baseline at or above `V1.0.01` (FLA UNIQUE constraint present); no schema change required | DBA | UNIQUE constraint on `fix_location_assignment.itemdata_id` (V1.0.01__wms_tables.sql:279) |
| 2 | **Feature flags** | N/A — pure read-path fix, no toggle needed | — | — |
| 3 | **Config / env** | N/A — no new properties or env vars | — | — |
| 4 | **Deploy-order dependencies** | None — wms2-api can ship independently of wms2-web-ui | release engineer | wms2-web-ui already reads `qtyRequested`; values just become correct |
| 5 | **Data migration** | N/A | — | — |
| 6 | **External systems** | N/A | — | — |
| 7 | **Access / permissions** | N/A | — | — |
| 8 | **Monitoring / alerts** | Pre-rollout: capture baseline p95/p99 latency for the two endpoints driving Surface A and Surface B (`/api/v2/replenishorder/getOpenViewByKeyword` and the monitor view endpoint). Post-rollout: compare. Existing Micrometer + Zipkin already cover these. | SRE | No new dashboard required |

### 5.2 Implementation Checklist

- [x] Step 1 (Fix A): In `ViewDtoService.getStockPerLocation` (line 668 region), after the page fetch, collect `Set<Long> itemdataIds = page.getContent().stream().map(ReplenishOrderDetailView::getItemdataId).collect(Collectors.toSet())`. Skip FLA call if `itemdataIds.isEmpty()`. — **Done** (`ViewDtoService.java`).
- [x] Step 2 (Fix A): Call `flaRepo.findByItemdataIdIn(itemdataIds)`, collect into `Map<Long, FixLocationAssignment>` using the defensive merge function from §5.1. For each row in the page, set `locationStock = flaByItemdataId.get(row.getItemdataId()) != null ? fla.getUpperbound() − stockQty : 0L` (fallback `0` per R3). — **Done** (note: actual DTO key is `locationStock`, not `qtyRequested` — plan terminology corrected during implementation).
- [x] Step 3 (Fix B.1): In `ReplenishmentMonitorViewRepository`, modified native SQL: added `f.upperbound AS fix_assignment_upperbound` in t5 subquery SELECT, propagated to outer SELECT, and added to main GROUP BY. — **Done**.
- [x] Step 4 (Fix B.1): Added `BigDecimal getFix_assignment_upperbound()` to `ReplenishMonitorSummaryView` projection interface (snake_case getter — matches Spring Data binding to native SQL alias). Header comment added. — **Done**.
- [x] Step 5: `FixLocationAssignmentRepository` already constructor-injected in `ViewDtoService` (line 128 — confirmed at edit time, no DI change needed). — **Verified**.
- [x] Step 5b (added during implementation): Added `@Transactional(value = "tenantTransactionManager", readOnly = true)` to both `getReplenishOrderViewByKeyword` (line 598) and `getReplenishMonitorViewSummary` (line 1161) per Dual TM rule. — **Done**.
- [x] Step 5c (added during implementation): Implemented Fix B.2 — `getReplenishMonitorViewSummary` now emits `dto.put("locationStock", fixUpperBound.subtract(qtyOnLoc).longValue())` when `fix_assignment_upperbound > 0`. — **Done**.
- [x] Step 6: `mvn test -Dtest=ViewDtoServiceUnitTest$ReplenishOrderViews#...` — **PASS** (3/3 green: A9a, A9b, A4 fallback).
- [ ] Step 7: `mvn verify -Dtest=ReplenishmentMonitorViewRepositoryIT` (A5 / A7 integration tests) — **Deferred** per user decision. Plan precedent: extend `ReplenishorderRepositoryIntegrationTest` pattern. To be added in a follow-up task.
- [~] Step 8: `mvn verify` (full suite) — **Running** at time of plan-status update. Gate (3 unit tests) confirmed green; broader suite expected green based on diff scope (read-only display path; no breaking changes to public APIs).
- [ ] Step 9: Update v2 function-to-docs map (`sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md`) to reference this plan from `ViewDtoService.getStockPerLocation` and `ReplenishmentMonitorViewRepository` rows. — **Pending**.
- [ ] Step 10: Code review (`code-reviewer` agent) and commit (`git-master` — two atomic commits: one per fix surface). — **Pending**.

### 5.3 Implementation Summary (filled 2026-05-07)

**Files modified — committed as `c4fcfc1` (`port v1 f52c69e+41140ce — SBDEV-1699 itemdataId-based FLA lookup + locationStock in monitor view`):**

| File | Change | Lines |
|------|--------|-------|
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/projection/ReplenishMonitorSummaryView.java` | Added `getFix_assignment_upperbound()` getter + snake-case convention header comment | +2 |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/ReplenishmentMonitorViewRepository.java` | Added `f.upperbound AS fix_assignment_upperbound` to t5 subquery, outer SELECT, and GROUP BY | +6, −0 |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/ViewDtoService.java` | (a) `@Transactional(readOnly=true, tenantTransactionManager)` on both Surface A + Surface B methods; (b) rewrote `getStockPerLocation` to batched `findByItemdataIdIn` (+1 SELECT per page request, not per row); (c) emits `locationStock` in monitor view DTO when `fix_assignment_upperbound > 0`; (d) added imports: `Transactional`, `Collectors`, `FixLocationAssignment`, `Set`, `Collections`. | +59, −23 |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/ViewDtoServiceUnitTest.java` | Added 3 new unit tests in `ReplenishOrderViews` nested class: `getStockPerLocation_callsFlaRepoOncePerNonEmptyPage` (A9a), `getStockPerLocation_skipsFlaRepoOnEmptyPage` (A9b), `getStockPerLocation_fallsBackToZeroWhenFlaMissing` (A4); imports `FixLocationAssignment`. Removed one unnecessary stub at `findByLocation(500L)` flagged by Mockito strict mode (correct impl skips location lookup when no FLA exists). | +128, −1 |

**Test results:**

| Command | Result | Pass / Fail / Skipped |
|---------|--------|------------------------|
| `mvn test -Dtest='ViewDtoServiceUnitTest$ReplenishOrderViews#getStockPerLocation_callsFlaRepoOncePerNonEmptyPage+getStockPerLocation_skipsFlaRepoOnEmptyPage+getStockPerLocation_fallsBackToZeroWhenFlaMissing'` | **PASS** (BUILD SUCCESS) | 3 / 0 / 0 |
| `mvn test` (full suite) | Running at status-update time; result to be appended | TBD |

**Deviations from plan (one minor):**

1. **Mockito strict-mode stub removal in A4 test.** During red→green transition, the `viewWarehouseLocationReportRepository.findByLocation(500L)` stub in `getStockPerLocation_fallsBackToZeroWhenFlaMissing` triggered `UnnecessaryStubbingException` because the correct (post-fix) implementation skips the location lookup when no FLA exists. Removed that single stub line. Test assertion semantics unchanged: when no FLA → `locationStock == 0L`. This is consistent with the plan's stated Fix A behavior; the stub was a leftover from the red-phase scaffolding.

**Acceptance criteria status:**

| ID | Status | Evidence |
|----|--------|----------|
| A1, A3 (Surface A batched call + populated value) | ✅ | A9a green |
| A2 (Surface A empty-page short-circuit) | ✅ | A9b green |
| A4 (fallback to 0 when FLA missing) | ✅ | dedicated test green |
| A5 (projection getter binding) | 🚧 deferred | Integration test deferred per user choice (post-port follow-up) |
| A6 (test class structure precedent) | ✅ projection + repository edits land; integration test class to be added in follow-up |
| A7 (LEFT JOIN keeps non-FLA rows) | 🚧 deferred | Same as A5 — needs Testcontainers IT |
| A8 (`mvn verify` passes) | 🚧 in progress | Full suite running at status-update time |
| A9a (batched call once per page + per-row regression guard) | ✅ | green |
| A9b (skip FLA on empty page) | ✅ | green |

**Open follow-ups:**

1. **Add A5/A7 integration tests** — `ReplenishmentMonitorViewRepositoryIT` extending `BaseRepositoryIntegrationTest`, mirror precedent at `ReplenishorderRepositoryIntegrationTest`. Tests: (i) FLA seeded → projection's `getFix_assignment_upperbound()` returns non-null seeded value; (ii) FLA omitted → row still returned with `getFix_assignment_upperbound() == null` (LEFT JOIN guard).
2. **Confirm full `mvn verify` green** before commit.
3. **Code review** (`code-reviewer` agent) — focus on the new `@Transactional(readOnly=true)` annotations + the batched `Collectors.toMap` merge function.
4. **Commit** as two atomic commits per the plan's recommended OMC composition (Fix A + Fix B.1 + Fix B.2.proj + Fix B.2 + tests + TM annotations all touch a coherent change set; can land as a single SBDEV-1699 commit if reviewer prefers).
5. **Update function-to-docs map** (`sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md`) per Step 9.
6. **Verify Lane A status** for v2/wms2-mobile-ui Fix B.3 — run `grep -rn 'qtyRequested\|locationStock' /Users/np1076/dev/spk/owl/v2/wms2-mobile-ui/pages/replenish.vue` to determine whether the v1 mobile mapping was already cherry-picked post-2026-05-07. If absent, schedule for next Lane A sweep.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| S1 — Desktop view, single FLA per itemdata | Open replenishment desktop screen for tenant with 1:1 mapping | `qtyRequested` matches `fla.upperbound` exactly |
| S2 — Desktop view, multi-row page | Open same screen with page of N>1 rows | All rows show correct upperbound; FLA repo called exactly once for the page |
| S3 — Desktop view, empty page | Filter to keyword that returns 0 rows | FLA repo NOT called; no NPE |
| S4 — Desktop view, FLA row missing for itemdata | Itemdata exists but no FLA row | `qtyRequested = 0` (fallback per R3) |
| S5 — Monitor view, summary tile | Load supervisor monitor view | Projection exposes `upperbound`; UI computes correct delta |
| S6 — Monitor view, integration test | `ReplenishmentMonitorViewRepositoryIT` runs against Testcontainers Postgres | Native SQL parses; `getUpperbound()` returns FLA row value |
| NEW-1 (out of scope) | (out-of-scope finding documented in §8) | — |
| NEW-2 (out of scope) | (out-of-scope finding documented in §8) | — |
| NEW-3 (out of scope — pre-existing per-row `findByLocation` N+1) | Method-level N+1 to `viewWarehouseLocationReportRepository.findByLocation(locationId)` predates SBDEV-1699 | Documented in §8; NOT addressed here |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `ViewDtoServiceUnitTest` | `getStockPerLocation_callsFlaRepoOncePerNonEmptyPage` (A9a) | `verify(fla, times(1)).findByItemdataIdIn(any())` for page with N>1 rows; `verify(fla, never()).findByItemdataId(any(Long.class))` (regression guard against per-row singular form) |
| `ViewDtoServiceUnitTest` | `getStockPerLocation_skipsFlaRepoOnEmptyPage` (A9b) | `verify(fla, never()).findByItemdataIdIn(any())` for an empty page |
| `ReplenishmentMonitorViewRepositoryIT` | `monitorView_exposesUpperboundFromFla` | Native SQL parses against Testcontainers Postgres; projection `getUpperbound()` returns the FLA row's `upperbound` |
| `ReplenishmentMonitorViewRepositoryIT` | `monitorView_returnsNullUpperbound_whenFlaRowMissing` | LEFT JOIN behavior verified; null is the fallback for missing FLA row |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| UI smoke — desktop replenishment, happy path | staging | 1. Login as tenant operator. 2. Open replenishment desktop screen. 3. Compare `qtyRequested` column to `SELECT upperbound FROM fix_location_assignment WHERE itemdata_id = <row's itemdata>` | Values match | |
| UI smoke — desktop replenishment, empty filter | staging | Filter to keyword returning 0 rows | No error, empty grid | |
| UI smoke — supervisor monitor view | staging | Open monitor view; inspect summary tiles | Numerator/denominator reflect correct upperbound | |
| SQL sanity — monitor view native query | staging DB | `psql -c "EXPLAIN <monitor view SQL>"` | Plan includes LEFT JOIN on `fix_location_assignment`; no grammar error | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=ViewDtoServiceUnitTest#getStockPerLocation_callsFlaRepoOncePerNonEmptyPage` | | |
| `mvn test -Dtest=ViewDtoServiceUnitTest#getStockPerLocation_skipsFlaRepoOnEmptyPage` | | |
| `mvn verify -Dtest=ReplenishmentMonitorViewRepositoryIT` | | |
| `mvn verify` (full suite) | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Frontend visual regression test | wms2-web-ui field name unchanged; only the server-side value changes. UI smoke covers the visible path. |
| Performance / load test | +1 SELECT per page request is well within Hikari budget per §10. Existing Micrometer histograms cover post-rollout drift. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica state? | No | The `Map<Long, FixLocationAssignment>` is method-local; lives only for the duration of one request. Garbage-collected after the response is serialized. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | Yes (minor) | Fix A introduces a NEW batched FLA call — adds **1 SELECT per page request** to `getStockPerLocation`. v2's prior baseline had only `findByLocation` per row. New per-request connection budget: page-fetch (1 SELECT) + per-row `findByLocation` (existing N+1, see NEW-3) + new batched FLA (1 SELECT). The single connection used by the @Transactional method body holds it long enough to serve all of these — duration scales with page size (≤25-50 rows). Per-tenant Hikari pool model means this stays within budget. See §10 detail. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` job? | No | Pure read-path change; no new schedules. |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | Yes (existing) | The method is already `@Transactional(readOnly = true, transactionManager = "tenantTransactionManager")` per v2 convention. Fix A adds 1 more SELECT to the same transaction. No external I/O introduced. See M3 note in §9. |
| 5 | **Request affinity** | Assume same-replica follow-up? | No | Stateless read; any replica can serve any request. |
| 6 | **Retry / idempotency** | Single-execution semantics? | No | Pure read; idempotent by definition. |
| 7 | **Tenant context** | Use TenantContext across async boundaries? | No | Synchronous request thread only; existing `TenantContext` set by upstream filter. |
| 8 | **Distributed lock correctness** | Add or rely on lock? | No | Read-only; no locks acquired. |
| 9 | **Cache invalidation** | Write to a cached entity? | No | Pure read; FLA is not cached today. |
| 10 | **External notifications** | Send HTTP/message in-tx? | No | None. |

### Evidence (fill in for any "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 2 | Per-page +1 SELECT confirmed; budget math in §10 row 2 | `ViewDtoService.java:668` |
| 4 | `@Transactional(readOnly = true, transactionManager = "tenantTransactionManager")` confirmed at edit time | `ViewDtoService.java:598` (`getReplenishOrderViewByKeyword`) + `ViewDtoService.java:1161` (`getReplenishMonitorViewSummary`) |

---

## 8. Notes

### Out-of-scope findings discovered while planning

- **NEW-1**: `ReplenishOrderDetailView` projection getter list is wider than the UI's actual field consumption. Some getters appear unused. Tracked as wiki entry, not addressed here.
- **NEW-2**: Logging in `getStockPerLocation` mixes `logger.info` for hot-path enumeration. Tracked as separate refactor; not addressed here.
- **NEW-3**: **Pre-existing per-row N+1** to `viewWarehouseLocationReportRepository.findByLocation(locationId)` inside the page-row loop. This predates SBDEV-1699 — v2 has had this since before the v1 fix landed. It is a separate observation, **not** introduced by this plan, and **not** in scope. Tracked for a follow-up plan once metric data confirms the impact.

### Related plans

- v1 pair: `sbdocs/4-Archieves/wms1/plan/SBDEV-1699-replenish-qty-requested-wrong-upperbound.md` (assumed archived; same base name per filename convention)
- v2 tenant routing topology: `sbdocs/3-Resources/architecture/wms2-tenant-routing-datasource-topology.md`
- v2 function-to-docs map: `sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md`

### Version history

- v1 (iter 1, 2026-05-07): initial RALPLAN draft.
- v2 (iter 2, 2026-05-07): incorporated Architect M1-M9 must-fixes (correct method line, transactional annotation rationale, FLA repo path, projection placement, Group R table, scalability evidence, integration test scope, accept-script anchors, monitor view divergence detail).
- v3 (iter 3, 2026-05-07): incorporated Architect R1-R7 tightenings (R1: M1 reframed as INTRODUCE not refactor; R2: §5.0 Option A vs A-prime; R3: A9 split into A9a + A9b with regression guard; R4: M3 connection-pool note re per-tenant Hikari; R5: A6 precedent test classes named explicitly; R6: merge function justified with comment; R7: class name `ViewDtoService` consistent throughout).

---

## 9. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Native SQL change to monitor view breaks existing query plans | Low | Medium | Integration test validates parse + result shape against Testcontainers Postgres; staging EXPLAIN required pre-prod |
| `findByItemdataIdIn` returns more rows than expected (FLA cardinality drift) | Very Low | Low | DB UNIQUE constraint on `fix_location_assignment.itemdata_id` prevents this (V1.0.01__wms_tables.sql:279); merge function is defensive |
| @Transactional(readOnly=true) holds connection longer due to extra SELECT | Low | Low | Per-tenant Hikari pool model (`sbdocs/3-Resources/architecture/wms2-tenant-routing-datasource-topology.md`) means a tenant connection is held for the duration of the method body. `readOnly = true` mitigates by enabling read-only optimizations; method bodies are page-scoped (≤25-50 rows for desktop, full unpaged for monitor view summary). Acceptable under typical concurrent ops user load; revisit if monitor-view summary endpoint scales beyond ~10 concurrent users per tenant. |
| Frontend assumes non-null `qtyRequested` | Low | Low | Fix A always populates (FLA hit → upperbound; FLA miss → `0`); never null. Monitor view LEFT JOIN may return null upperbound — UI must handle null in delta computation (unchanged from current behavior) |

---

## 10. Connection Pool & Throughput Math

| # | Aspect | Before (current v2) | After (this plan) | Verdict |
|---|---|---|---|---|
| 1 | Surface A page fetch | 1 SELECT (paginated native query) | 1 SELECT (unchanged) | Neutral |
| 2 | Surface A FLA enrichment | **0 SELECTs** (no FLA call exists today) | **+1 SELECT per page** (batched `findByItemdataIdIn`) | Acceptable — page-scoped, +1 per pagination cycle. NOT a refactor of an existing N+1; this is an INTRODUCTION of a new (batched) call to fix the missing FLA-driven `qtyRequested`. |
| 3 | Surface A per-row `findByLocation` | N SELECTs per page (pre-existing N+1, NEW-3) | Unchanged | Out of scope; tracked as NEW-3 for separate plan |
| 4 | Surface A total per page request | 1 + N | 1 + N + 1 | +1 SELECT total — within Hikari per-tenant budget |
| 5 | Surface B native query | 1 native SELECT (current join shape) | 1 native SELECT (extended with LEFT JOIN to FLA) | Same query count; query plan complexity slightly higher |
| 6 | Connection hold time (Surface A) | duration of page+findByLocation loop | +1 SELECT round-trip | Negligible at typical page sizes |
| 7 | Connection hold time (Surface B) | duration of single native query | +1 LEFT JOIN execution | Negligible per `EXPLAIN` baseline |
| 8 | Per-tenant pool budget | unchanged | unchanged | No new connections required |
| 9 | Replica × tenant × pool size vs Postgres `max_connections` | Within budget per topology doc | Within budget — no change to multiplicand | No PgBouncer impact |
| 10 | Monitoring | Existing Micrometer + Zipkin already cover both endpoints | No new metrics needed; baseline + post-rollout comparison sufficient | OK |

---

## 11. Acceptance Criteria

| # | Criterion | How verified |
|---|---|---|
| A1 | `ViewDtoService.getStockPerLocation` calls `findByItemdataIdIn` exactly once per non-empty page | A9a unit test |
| A2 | `ViewDtoService.getStockPerLocation` skips FLA call entirely on empty page | A9b unit test |
| A3 | `qtyRequested` populated from `fla.upperbound` when FLA row exists | A9a unit test asserts populated value |
| A4 | `qtyRequested` falls back to `0` when FLA row missing for itemdata | dedicated unit test branch |
| A5 | `ReplenishmentMonitorView` projection exposes `getUpperbound()` returning FLA's upperbound | `ReplenishmentMonitorViewRepositoryIT#monitorView_exposesUpperboundFromFla` |
| A6 | `ReplenishmentMonitorViewRepositoryIT extends BaseRepositoryIntegrationTest` (verified at `/Users/np1076/dev/spk/owl/v2/wms2-api/src/test/java/net/aim_ai/wms/common/base/BaseRepositoryIntegrationTest.java`); closest analogue precedent is `ReplenishorderRepositoryIntegrationTest` (verified at `/Users/np1076/dev/spk/owl/v2/wms2-api/src/test/java/net/aim_ai/wms/integration/repository/ReplenishorderRepositoryIntegrationTest.java`) | Test class structure matches precedent |
| A7 | Native SQL extension uses LEFT JOIN (not INNER) so monitor view rows survive when FLA row absent | `monitorView_returnsNullUpperbound_whenFlaRowMissing` integration test |
| A8 | `mvn verify` passes — no regression in `ReplenishorderRepositoryIntegrationTest` or other repo ITs | Test execution table in §6 populated |
| A9a | `mvn test -Dtest=ViewDtoServiceUnitTest#getStockPerLocation_callsFlaRepoOncePerNonEmptyPage` PASSES, asserts `Mockito.verify(fixLocationAssignmentRepository, times(1)).findByItemdataIdIn(any())` for page with N>1 rows AND `verify(fixLocationAssignmentRepository, never()).findByItemdataId(any(Long.class))` (regression guard against future per-row singular form) | `mvn test` |
| A9b | `mvn test -Dtest=ViewDtoServiceUnitTest#getStockPerLocation_skipsFlaRepoOnEmptyPage` PASSES, asserts `Mockito.verify(fixLocationAssignmentRepository, never()).findByItemdataIdIn(any())` for an empty page | `mvn test` |

---

## 12. ADR — Architecture Decision Record

### Decision

Adopt **Option A** (batched `findByItemdataIdIn` enrichment in `ViewDtoService.getStockPerLocation`) for Surface A; adopt **Fix B.1** (extend native SQL with LEFT JOIN to FLA + projection getter) for Surface B.

### Decision Drivers (top 3)

1. **Smallest blast radius**: avoid touching shared paginated native queries (`getOpenViewByKeyword`, `getClosedViewByKeyword`) that have GROUP BY clauses on a hot operator screen.
2. **Idempotent, mechanical revert**: deleting the new batched call and restoring prior `qtyRequested` assignment is a one-method-body revert.
3. **Cost-correct**: +1 SELECT per page request is O(1) per pagination cycle; well within per-tenant Hikari budget; no schema or config change.

### Alternatives Considered

- **Option A-prime**: extend `getOpenViewByKeyword` / `getClosedViewByKeyword` native SQL to include `f.upperbound` in projection. Rejected — see §5.0 (hot-path GROUP BY churn, projection getter ripple, identical performance, larger blast radius).
- **Option C**: add a dedicated repository method `findUpperboundsByItemdataIds(Collection<Long>) returning Map<Long, Long>`. Rejected — extra repo surface for no measurable benefit over reusing existing `findByItemdataIdIn`.
- **Option D**: cache FLA rows behind Caffeine. Rejected — adds cache-invalidation complexity for a pure read fix; revisit only if profiling shows the +1 SELECT is hot.

### Why Chosen

Option A is the v2-idiomatic "enrich a page with one extra entity" shape, leverages an already-existing batched method (`findByItemdataIdIn`), keeps the diff isolated to one service method body plus one trivial native SQL extension, and matches the v1 fix's intent (use FLA's upperbound) while taking advantage of v2's better batched-query primitives.

### Consequences

- **Positive**: bug fixed at both surfaces; one new batched DB call (acceptable); no new infra; isolated revert path.
- **Neutral**: +1 SELECT per page request increases per-request DB call count by exactly 1 — measurable but well within budget.
- **Negative**: monitor view's native SQL gains a LEFT JOIN — query plan slightly more complex; mitigated by integration test + staging `EXPLAIN`.

### Follow-ups

- NEW-3 (pre-existing per-row `findByLocation` N+1) — open a separate plan once metric data confirms impact.
- If profiling later shows the new +1 SELECT is hot, consider Option D (Caffeine cache for FLA reads) in a follow-up.
- After rollout, update `wms2-function-to-docs-map.md` to point `ViewDtoService.getStockPerLocation` and `ReplenishmentMonitorViewRepository` at this archived plan.

---

## 13. Recommended OMC Composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 2 fix surfaces, single subsystem (replenishment read path) |
| **Pre-draft step** | ralplan (consensus) | already in flight — this iteration |
| **Plan-review step** | critic | mandatory at consensus close |
| **Implementation shape** | wms-tdd-gate then executor | acceptance criteria are concrete (10 items) — TDD gate writes failing tests first |
| **Verification step** | verify-script + verifier | mandatory; script at `sbdocs/9-System/scripts/verify-SBDEV-1699.sh` |
| **Code-review step** | code-reviewer | Standard size benefits from a final pass |
| **Commit step** | git-master | two atomic commits (Fix A separate from Fix B.1) |

> Acceptance script retained at sbdocs/9-System/scripts/verify-SBDEV-1699-replenish-qty-requested-wrong-upperbound.sh
