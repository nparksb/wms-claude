---
title: "SBDEV-1699 — Replenish: qty requested shows sysprop default instead of FLA upperbound"
ticket: "SBDEV-1699"
ticket_url: ""
type: "bugfix"
priority: "high"
status: "draft"
project: ["wms1"]
version: "v1"
requester: ""
created: "2026-04-29"
updated: "2026-04-29"
related: []
tags:
  - plan
  - replenish
  - mobile
---

# SBDEV-1699 — Replenish: qty requested shows sysprop default instead of FLA upperbound

**Ticket:** SBDEV-1699
**Project:** wms1 | **Version:** v1 | **Type:** bugfix
**Priority:** high
**Status:** draft
**Date:** 2026-04-29

---

## 0. Affected Sites (enumeration before drafting)

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `ViewDtoService.java:643–672` | `getStockPerLocation()` — uses `findByAssignedlocationId(locationId)` (wrong key — looks up by destination location rather than SKU; may return FLA for wrong SKU when replenish order destination ≠ FLA's natural SKU location) | yes — wrong FLA lookup | yes |
| 2 | `ReplenishmentMonitorViewRepository.java:65–73` | `t5` subquery — joins FLA but omits `f.upperbound` from SELECT | yes — monitor-view SQL path bypasses Java fix | yes |
| 3 | `ViewDtoService.java:1142–1178` | `getReplenishMonitorViewSummary()` — maps `result[7]` as `qtyRequested` (customer demand); no `locationStock` field | yes — DTO missing the fill-qty field | yes |
| 4 | `replenish.vue:~148–175` | `fetchAllReplen()` — held-up items: `locationStock: item.qtyRequested` hardcodes customer demand | yes — mobile reads wrong field | yes |

---

## 1. Problem Statement

The **"Qty Requested"** value on the desktop replenishment monitor and the **held-up quantity** on the mobile replenishment screen are supposed to reflect the **fill quantity**: how many units are needed to bring the fixed-assignment pick location up to its configured `fix_location_assignment.upperbound`. Instead, both show the **system-parameter default** from `los_sysprop` (the `REPLENISH_UPPER_BOUND` key), ignoring the per-item FLA setting entirely.

Commit `f52c69e` (SBDEV-1699: Replen - Qty req not matching) attempted a fix by updating `ViewDtoService.getStockPerLocation()` to look up the FLA by destination location ID. That attempt left **two defects unresolved**:

1. **Wrong FLA lookup key** (`ViewDtoService.java`): The code queries `fix_location_assignment` by `assignedlocation_id` (the replenish destination location). While `assignedlocation_id` has a UNIQUE constraint (verified against live DB: `uk_qakwvmdhdymic54v3dgie46wa`), lookup by location is still semantically wrong: if a replenish order for SKU-A is routed to a location whose FLA belongs to SKU-B, `findByAssignedlocationId` returns the wrong FLA's `upperbound`. The correct key is `itemdata_id` (the SKU), consistent with how `ReplenishmentOrderMaintenanceService` resolves the FLA.

2. **Mobile held-up path not touched** (`replenish.vue` / `ReplenishmentMonitorViewRepository`): The mobile replenishment screen fetches "held-up" items (customer demand with no replenish order yet) from a separate endpoint `/dashboard/replenishMonitorViewSummary`. That endpoint's SQL does **not expose `f.upperbound`**, so the Java fix in `getStockPerLocation` has zero effect on this code path. The mobile maps `locationStock: item.qtyRequested`, where `qtyRequested` is customer order demand (`round(sum(cop.amount))`), not fill qty.

**Reproduction:**
1. Ensure at least one `fix_location_assignment` row has a non-zero `upperbound` that differs from the sysprop default.
2. Open the mobile replenishment screen (held-up items) or the desktop replenishment monitor.
3. Observe "Qty Requested" reflects the sysprop value, not `FLA.upperbound − currentStock`.

---

## 2. Root Cause Analysis

### Bug 1 — `getStockPerLocation` uses wrong FLA lookup key

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/ViewDtoService.java:643–672`

The SBDEV-1699 fix queries by destination location:

```java
// Broken code — ViewDtoService.java ~line 649
Long locationId = result[14] != null ? Long.valueOf(result[14].toString()) : null;
// ...
Optional<FixLocationAssignment> assignment =
    fixLocationAssignmentRepository.findByAssignedlocationId(locationId);
if (assignment.isPresent() && Boolean.TRUE.equals(assignment.get().getActive())) {
    locationUpperBound = assignment.get().getUpperbound();
}
```

`result[14]` = `r.destination_id` (replenish order destination). `result[13]` = `s.itemdata_id` (available, already mapped to DTO but not used for lookup).

Two problems:

**a) Lookup by location instead of SKU**: `fix_location_assignment` has UNIQUE constraints on both `assignedlocation_id` (`uk_qakwvmdhdymic54v3dgie46wa`) and `itemdata_id` (`uk_k2oy160252pn1o7comeeqbjt8`), confirmed against the live `wh01_om1` DB and `V1.0.01__wms_tables.sql:280`. So `IncorrectResultSizeDataAccessException` is not a risk. However, lookup by location is semantically wrong: if a replenish order for SKU-A is routed to a location whose FLA belongs to SKU-B (e.g., manually rerouted destination), `findByAssignedlocationId` returns the wrong FLA's `upperbound`. `findByItemdataId(itemdataId)` always resolves the FLA for the correct SKU regardless of destination routing.

**b) Zero-guard missing on `upperbound`**: `FixLocationAssignment.upperbound` defaults to `BigDecimal.ZERO`. If an FLA row exists but `upperbound` was never set, `locationUpperBound = ZERO` produces a negative `locationStock = 0 − currentStock`.

The canonical approach is already in `ReplenishmentOrderMaintenanceService.resolveActiveAssignment()` (line ~132): look up by `itemdata_id` via `findByItemdataId(itemdataId)`, then in `resolveUpperBound()` fall back to the sysprop when `upperbound` is null or zero.

### Bug 2 — Mobile held-up path bypasses the Java fix entirely

**Files:**
- `ReplenishmentMonitorViewRepository.java:65–73` (SQL)
- `ViewDtoService.java:1142–1178` (DTO mapper)
- `pages/replenish.vue:~148–175` (mobile)

The mobile replenishment page calls **two** endpoints:

| Path | Items fetched | Field used for qty |
|------|--------------|-------------------|
| `GET /replenishOrder/detailView` | Active replenish orders | `locationStock` (from `getStockPerLocation`) — Bug 1 applies here |
| `GET /dashboard/replenishMonitorViewSummary` | Held-up demand items (no replenish order yet) | `qtyRequested` = customer demand — **Java fix has zero effect** |

In `fetchAllReplen()`, held-up items are merged with:
```js
locationStock: item.qtyRequested  // BUG: qtyRequested = round(sum(cop.amount)) = customer demand
```

The monitor view SQL `t5` subquery (lines 65–73 of `ReplenishmentMonitorViewRepository`) joins `fix_location_assignment` but its SELECT is:
```sql
SELECT i.id AS i_id,
       l.name AS fix_assignment_location_name,
       round(su.amount) AS bottles_on_location,
       round(su.reservedamount) AS bottles_reserved_on_location
  FROM fix_location_assignment f ...
```

`f.upperbound` is joined but **never selected**. Without it in `result[25]`, the Java DTO mapper cannot compute fill qty, and `locationStock` is never populated in the monitor view response.

---

## 3. The Regression Chain

| SHA | File | Change | Effect |
|-----|------|--------|--------|
| `f52c69e` | `ViewDtoService.java` | Added `findByAssignedlocationId` lookup in `getStockPerLocation` | Partial fix: corrects desktop `/detailView` for FLA-triggered orders only; may return wrong FLA upperbound when replenish destination ≠ FLA's natural SKU location; mobile monitor-view path left untouched |

---

## 4. Architecture Overview

```
Desktop path (partially fixed by f52c69e, still has Bug 1):

  wms-web-ui openRequest.vue
    → GET /v3/replenishOrder/detailView
    → ReplenishOrderController
    → ViewDtoService.getReplenishOrderViewByKeyword()
    → getStockPerLocation(page, syspropUpperBound)    ← Bug 1: wrong lookup key
    → DTO: { locationStock }
    ← openRequest.vue: item.locationStock as "Requested Amount"

Mobile path — active replenish orders (same as desktop, same Bug 1):

  replenish.vue fetchAllReplen()
    → GET /v3/replenishOrder/detailView               ← Bug 1 affects this too

Mobile path — held-up items (UNTOUCHED by f52c69e, Bug 2):

  replenish.vue fetchAllReplen() / fetchHeldUp()
    → GET /v3/dashboard/replenishMonitorViewSummary
    → ViewDtoService.getReplenishMonitorViewSummary()
    → ReplenishmentMonitorViewRepository.getReplenishViewSummary() [native SQL]
         t5 subquery: JOIN fix_location_assignment (f.upperbound NOT selected) ← Bug 2 SQL
    → DTO: { qtyRequested = customer demand, locationStock absent }
    ← replenish.vue: locationStock: item.qtyRequested  ← Bug 2 mobile mapping
    → store.commit('replenish/setRealAmountNeeded', item?.locationStock || item?.qtyRequested)
```

**Key Files:**

| File | Lines | Role |
|------|-------|------|
| `v1/wms-api/.../service/ViewDtoService.java` | 643–672 | `getStockPerLocation()` — computes fill qty per destination location |
| `v1/wms-api/.../service/ViewDtoService.java` | 1142–1178 | `getReplenishMonitorViewSummary()` — DTO mapper for held-up item monitor view |
| `v1/wms-api/.../repo/jpa/ReplenishmentMonitorViewRepository.java` | 21–119 | Native SQL — `getReplenishViewSummary()` |
| `v1/wms-api/.../repo/jpa/FixLocationAssignmentRepository.java` | 23–30 | `findByAssignedlocationId` / `findByItemdataId` |
| `v1/wms-api/.../model/FixLocationAssignment.java` | — | Entity: `upperbound` default=ZERO, `active` default=TRUE |
| `v1/wms-mobile-ui/pages/replenish.vue` | 120–213 | `fetchAllReplen()` / `fetchHeldUp()` — mobile replenish page |

---

## 5. Fix Design

### Fix A — Switch `getStockPerLocation` to `findByItemdataId` + zero-guard

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/ViewDtoService.java` (~lines 643–672)

**Before:**
```java
Long locationId = result[14] != null ? Long.valueOf(result[14].toString()) : null;
if (locationId != null && (!stockPerLocation.containsKey(locationId) || stockPerLocation.get(locationId) == null)) {
    Long locationStock = 0L;
    BigDecimal locationUpperBound = upperBound;
    Optional<FixLocationAssignment> assignment =
        fixLocationAssignmentRepository.findByAssignedlocationId(locationId);
    if (assignment.isPresent() && Boolean.TRUE.equals(assignment.get().getActive())) {
        locationUpperBound = assignment.get().getUpperbound();
    }
```

**After:**
```java
Long locationId = result[14] != null ? Long.valueOf(result[14].toString()) : null;
if (locationId != null && (!stockPerLocation.containsKey(locationId) || stockPerLocation.get(locationId) == null)) {
    Long locationStock = 0L;
    BigDecimal locationUpperBound = upperBound;
    Long itemdataId = result[13] != null ? ((BigInteger) result[13]).longValue() : null;
    if (itemdataId != null) {
        Optional<FixLocationAssignment> assignment =
            fixLocationAssignmentRepository.findByItemdataId(itemdataId);
        if (assignment.isPresent()
                && Boolean.TRUE.equals(assignment.get().getActive())
                && assignment.get().getUpperbound() != null
                && assignment.get().getUpperbound().compareTo(BigDecimal.ZERO) > 0) {
            locationUpperBound = assignment.get().getUpperbound();
        }
    }
```

**Why this fix, not alternatives:**
- Matches the pattern in `ReplenishmentOrderMaintenanceService.resolveActiveAssignment()` — look up FLA by SKU, not location. SKU is the natural identity for a fixed-location assignment.
- `assignedlocation_id` and `itemdata_id` both have UNIQUE constraints (verified live DB), so no `IncorrectResultSizeDataAccessException` risk either way. The switch to `findByItemdataId` is about correctness: it finds the FLA for the right SKU regardless of how the replenish destination was assigned.
- Zero-guard (`compareTo(BigDecimal.ZERO) > 0`) prevents negative `locationStock` when FLA `upperbound` was never configured (default = ZERO). Falls back to sysprop value, which is the pre-SBDEV-1699 behavior and is safe.
- `result[13]` (`s.itemdata_id`) is already parsed in the caller loop (`dto.put("itemdataId", result[13])`); no query changes needed.

### Fix B — Expose `f.upperbound` through monitor view SQL → Java DTO → Mobile

#### Fix B.1 — Add `f.upperbound` to `t5` subquery

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/repo/jpa/ReplenishmentMonitorViewRepository.java:65–73`

**Before (t5 SELECT):**
```sql
LEFT JOIN ( SELECT i.id AS i_id,
       l.name AS fix_assignment_location_name,
       round(su.amount) AS bottles_on_location,
       round(su.reservedamount) AS bottles_reserved_on_location
      FROM fix_location_assignment f
        JOIN itemdata i ON f.itemdata_id = i.id
        JOIN location l ON f.assignedlocation_id = l.id
        JOIN unitload ul ON l.id = ul.storagelocation_id
        JOIN stockunit su ON su.unitload_id = ul.id) t5 ON t1.i_id = t5.i_id
```

**After (t5 SELECT):**
```sql
LEFT JOIN ( SELECT i.id AS i_id,
       l.name AS fix_assignment_location_name,
       round(su.amount) AS bottles_on_location,
       round(su.reservedamount) AS bottles_reserved_on_location,
       f.upperbound AS fix_assignment_upperbound
      FROM fix_location_assignment f
        JOIN itemdata i ON f.itemdata_id = i.id
        JOIN location l ON f.assignedlocation_id = l.id
        JOIN unitload ul ON l.id = ul.storagelocation_id
        JOIN stockunit su ON su.unitload_id = ul.id) t5 ON t1.i_id = t5.i_id
```

Add `t5.fix_assignment_upperbound` to the **main SELECT** (append after `t5.bottles_reserved_on_location`) and to the **GROUP BY** list (line 117). This appends as `result[25]` — all existing indices 0–24 are unchanged.

#### Fix B.2 — Add `locationStock` to `getReplenishMonitorViewSummary` DTO

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/ViewDtoService.java:1142–1178`

Append after `dto.put("replenishableLocationNames", result[24])` (line 1174):

```java
BigDecimal fixUpperBound = result[25] != null ? (BigDecimal) result[25] : null;
BigDecimal qtyOnLoc = result[14] != null ? new BigDecimal(result[14].toString()) : BigDecimal.ZERO;
if (fixUpperBound != null && fixUpperBound.compareTo(BigDecimal.ZERO) > 0) {
    dto.put("locationStock", fixUpperBound.subtract(qtyOnLoc).longValue());
}
```

This mirrors the `getStockPerLocation` computation and produces the same `locationStock` field that the mobile already reads via `item?.locationStock || item?.qtyRequested`.

#### Fix B.3 — Mobile: use `locationStock` from DTO for held-up items

**File:** `v1/wms-mobile-ui/pages/replenish.vue` (~lines 148–175, inside `fetchAllReplen()`)

**Before:**
```js
locationStock: item.qtyRequested
```

**After:**
```js
locationStock: item.locationStock != null ? item.locationStock : item.qtyRequested
```

Safe fallback: items without an FLA (no `locationStock` in DTO) degrade to customer demand — which is the pre-fix behavior and is acceptable for non-FLA items. The existing line 213 fallback (`item?.locationStock || item?.qtyRequested`) then works correctly for all cases.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `v1/wms-api/.../service/ViewDtoService.java` | Modify (×2) | Fix A: switch `getStockPerLocation` to `findByItemdataId` + zero-guard; Fix B.2: add `locationStock` computation to `getReplenishMonitorViewSummary` |
| `v1/wms-api/.../repo/jpa/ReplenishmentMonitorViewRepository.java` | Modify | Fix B.1: add `f.upperbound AS fix_assignment_upperbound` to t5 subquery, main SELECT, and GROUP BY |
| `v1/wms-mobile-ui/pages/replenish.vue` | Modify | Fix B.3: replace `locationStock: item.qtyRequested` with `item.locationStock` fallback for held-up items |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | N/A — no schema change; no Flyway migration needed | N/A | Pure logic + SQL query text change |
| 2 | **Feature flags / sysprops** | N/A — no new sysprop keys | N/A | Existing `REPLENISH_UPPER_BOUND` sysprop remains as fallback |
| 3 | **Config / env** | N/A | N/A | |
| 4 | **Deploy-order dependency** | wms-api must deploy before wms-mobile-ui | Dev | Fix B.2 adds `locationStock` to DTO; Fix B.3 reads it. Mobile falls back gracefully if API deploys late (old behavior). |
| 5 | **Data migration** | N/A — existing FLA rows with non-zero `upperbound` work automatically | N/A | Verify staging data: `SELECT id, itemdata_id, assignedlocation_id, upperbound FROM fix_location_assignment WHERE upperbound > 0;` |
| 6 | **External systems** | N/A | N/A | |
| 7 | **Access / permissions** | N/A | N/A | |
| 8 | **Monitoring / alerts** | N/A | N/A | |

Pre-deploy info — both `assignedlocation_id` and `itemdata_id` have UNIQUE constraints (confirmed in live DB). No duplicate-check SQL needed.

### 7.2 Implementation Checklist

- [ ] **Fix A** — `ViewDtoService.getStockPerLocation()`: extract `itemdataId` from `result[13]`; replace `findByAssignedlocationId(locationId)` with `findByItemdataId(itemdataId)` + active + zero-guard on `upperbound`
- [ ] **Fix B.1** — `ReplenishmentMonitorViewRepository.getReplenishViewSummary()`: add `f.upperbound AS fix_assignment_upperbound` to t5 subquery SELECT; append `t5.fix_assignment_upperbound` to main SELECT and GROUP BY
- [ ] **Fix B.2** — `ViewDtoService.getReplenishMonitorViewSummary()`: map `result[25]` and compute `locationStock = upperbound − qtyOnLocation`; add to DTO when `upperbound > 0`
- [ ] **Fix B.3** — `replenish.vue fetchAllReplen()`: change `locationStock: item.qtyRequested` to `locationStock: item.locationStock != null ? item.locationStock : item.qtyRequested`
- [ ] Unit tests added for `getStockPerLocation` (FLA found, FLA zero upperbound fallback, no FLA)
- [ ] Unit/integration test for `getReplenishMonitorViewSummary` verifying new `locationStock` field
- [ ] Run `mvn test -Dtest=ViewDtoServiceTest` — all pass
- [ ] Run `mvn verify` — all pass
- [ ] Code review completed
- [ ] Deploy wms-api; then deploy wms-mobile-ui

---

## 8. Testing Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| FLA with non-zero `upperbound` (desktop) | Call `/replenishOrder/detailView`; FLA has `upperbound=50`, current stock=30 | `locationStock = 20` |
| FLA with `upperbound = 0` (default) | Call `/replenishOrder/detailView`; FLA has `upperbound=0` | Falls back to sysprop value; no crash |
| No FLA for SKU | Call `/replenishOrder/detailView`; no FLA row for itemdata_id | Falls back to sysprop; no crash |
| Monitor view — FLA with `upperbound` (mobile held-up) | Call `/dashboard/replenishMonitorViewSummary`; FLA `upperbound=50`, current=30 | `locationStock = 20` in response |
| Monitor view — no FLA for SKU | Call `/dashboard/replenishMonitorViewSummary`; no FLA | `locationStock` absent from DTO; mobile falls back to `qtyRequested` |
| Duplicate FLA per SKU pre-check | DB query: `SELECT itemdata_id, count(*) ... HAVING count(*) > 1` | Zero rows (else resolve before deploy) |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `ViewDtoServiceTest` | `getStockPerLocation_usesItemdataIdLookup` | FLA found by SKU; `locationStock = upperbound − currentStock` |
| `ViewDtoServiceTest` | `getStockPerLocation_zeroUpperbound_fallsBackToSysprop` | FLA with `upperbound=0` → sysprop value used |
| `ViewDtoServiceTest` | `getStockPerLocation_noFla_usesSystemParamUpperBound` | No FLA → sysprop value used |
| `ViewDtoServiceTest` | `getReplenishMonitorViewSummary_includesLocationStockWhenFlaPresent` | DTO has `locationStock` key when t5 FLA has `upperbound > 0` |
| `ViewDtoServiceTest` | `getReplenishMonitorViewSummary_noLocationStockWhenNoFla` | DTO has no `locationStock` key when no FLA exists |
| (Integration) `ReplenishmentMonitorViewRepositoryTest` | `getReplenishViewSummary_exposesUpperbound` | `result[25]` populated from FLA `upperbound` column |

Note: Mockito 3.3.3 — no `mockStatic()`. Use `SecurityContextHolder` directly for any principal setup in tests.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Desktop replenishment monitor | staging | 1. Set FLA `upperbound=50` for a SKU with 30 units at pick location. 2. Open desktop replenishment → open requests view. 3. Check "Requested Amount" | Shows 20 (50−30), not sysprop default | |
| Mobile — active replenish order | staging | 1. Trigger a replenish order for the FLA SKU. 2. Open mobile replenish screen. 3. Check qty shown next to order | Shows 20 (fill qty), not customer demand | |
| Mobile — held-up (no order yet) | staging | 1. Ensure customer orders exist for the SKU but no replenish order. 2. Open mobile replenish screen (held-up section). 3. Check qty | Shows 20 (fill qty from FLA), not total customer demand | |
| No FLA — regression check | staging | 1. Remove FLA for a different SKU. 2. Check desktop + mobile for that SKU | Shows sysprop default; no 500 crash | |
| SQL sanity — new column | staging DB | `SELECT i_id, fix_assignment_upperbound FROM (` run `getReplenishViewSummary` SQL `) AS q WHERE fix_assignment_upperbound IS NOT NULL LIMIT 5;` | Non-empty result with correct `upperbound` values | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=ViewDtoServiceTest` | | |
| `mvn verify` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Mobile E2E Playwright test for replenish | No Playwright replenish spec exists yet; replenish is not in current test scope |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| N/A — unique constraints on both `assignedlocation_id` and `itemdata_id` confirmed in live DB | N/A | Both `findByAssignedlocationId` and `findByItemdataId` are safe from `IncorrectResultSizeDataAccessException` |
| SQL column-index shift if `fix_assignment_upperbound` inserted mid-SELECT (not appended) | All existing DTO fields at indices > insertion point are off by one | Append as last column; confirm indices 0–24 unchanged; verify with unit test |
| `result[25]` is `BigDecimal` — monitor view currently returns `null` for items without FLA | NPE in DTO mapper | Null-guard before cast: `result[25] != null ? (BigDecimal) result[25] : null` |
| Mobile fallback to `qtyRequested` for non-FLA items | Shows customer demand — but this was always the behavior | Documented acceptable degradation; Fix B.3 uses explicit fallback |
| Deploy order: mobile before API | `locationStock` absent from DTO → mobile falls back to `qtyRequested` (old behavior, no crash) | Acceptable; deploy API first |
| GROUP BY omission of new column | PostgreSQL error: non-aggregate column not in GROUP BY | Append to GROUP BY list; caught by `mvn verify` integration test |

---

## 10. Completeness Checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 1 | **All callsites enumerated** | ✓ §0 lists 5 rows; all addressed in §5 Fix Design or explicitly excluded |
| 2 | **Adjacent bugs** | ✓ `findByAssignedlocationId` appears only in `getStockPerLocation` (single callsite for this pattern) |
| 3 | **Backward compatibility** | ✓ `locationStock` is additive to monitor view DTO; desktop DTO unchanged; mobile uses explicit fallback |
| 4 | **Concurrency** | no — read-only display path; no locks, no writes |
| 5 | **Multi-tenant** | no — v1 is single-tenant per wms-api instance; datasource already bound per request |
| 6 | **Error handling** | ✓ `itemdataId` null-guarded before `findByItemdataId`; zero-guard on `upperbound`; `result[25]` null-guarded in DTO mapper; mobile has explicit fallback |
| 7 | **Observability** | no — display-only fix; no new failure modes introduced; existing LOG in `getReplenishMonitorViewSummary` covers the path |
| 8 | **Rollback / migration** | ✓ No Flyway migration; revert = `git revert` of 2 Java + 1 SQL + 1 Vue file |
| 9 | **Test coverage** | ✓ Unit + integration + manual smoke in §8 |
| 10 | **Cross-version (v1↔v2)** | no — v1 only; v2 uses a different service layer; port deferred to separate plan if needed |

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-1699-replenish-qty-requested-wrong-upperbound.sh`

Run after every implementation pass. Exit 0 = all checks pass.

### 11.2 Implementation status — v1 (2026-04-29)

**Status: IMPLEMENTED ✓**

All four fixes applied and verified on branch `release-hotfix-260429`:

| Fix | File | Change | Status |
|---|---|---|---|
| A | `ViewDtoService.java` | `getStockPerLocation`: replaced `findByAssignedlocationId` with `findByItemdataId(itemdataId)` + active/zero-guard | ✓ Done |
| B.1 | `ReplenishmentMonitorViewRepository.java` | Added `f.upperbound AS fix_assignment_upperbound` to t5 subquery SELECT, main SELECT, and GROUP BY | ✓ Done |
| B.2 | `ViewDtoService.java` | `getReplenishMonitorViewSummary`: reads result[25], computes `locationStock = fixUpperBound − qtyOnLocation` | ✓ Done |
| B.3 | `wms-mobile-ui/pages/replenish.vue` | `fetchAllReplen` held-up mapping: `locationStock: item.locationStock != null ? item.locationStock : item.qtyRequested` | ✓ Done |

**Tests added/updated in `ViewDtoServiceUnitTest.java`:**
- Updated `testGetReplenishMonitorViewSummary`: added `null` as result[25]; asserts `locationStock` absent
- Added `testGetReplenishMonitorViewSummary_withFlaUpperbound`: result[25]=80, result[14]=50 → `locationStock=30L`
- Updated `testGetReplenishOrderViewByKeyword_OpenState`: added result[16] (modifiedDate) — pre-existing gap fixed
- Updated `testGetReplenishOrderViewByKeyword_ClosedState`: added result[16] (modifiedDate) — pre-existing gap fixed
- Added `testGetReplenishOrderViewByKeyword_withFlaUpperboundUsed`: FLA upperbound=150, stockQty=80 → `locationStock=70L`
- Added `testGetReplenishOrderViewByKeyword_withZeroFlaUpperbound`: FLA upperbound=0 (zero-guard) → falls back to sysprop → `locationStock=20L`

**Verification result:** `verify-SBDEV-1699.sh` — 13 pass, 0 fail, 0 skip

**Suite result:** `mvn verify` — 1627 tests, 1 failure (`MobileMoveStockServiceUnitTest.selectDestination_destinationLabelDoesNotMatchPattern_ThrowsBusinessException`) — pre-existing, unrelated to this fix (message text mismatch in old test). All 58 `ViewDtoServiceUnitTest` tests pass.

### 11.3 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 4 changes across 2 repos; straightforward substitution + SQL addendum |
| **Pre-draft step** | none | Analysis complete; this document is the plan |
| **Plan-review step** | critic | Cross-repo + SQL column-index risk warrants critic pass before coding |
| **Implementation shape** | executor | Sequential: Fix A + Fix B.1 + Fix B.2 (API) first, then Fix B.3 (mobile) |
| **Verification step** | verify-script + verifier | Mandatory |
| **Code-review step** | code-reviewer | SQL + two Java methods + Vue change |
| **Commit step** | git-master | Two logical commits: `fix(replenish): use itemdataId for FLA lookup + add monitor-view locationStock` (API), then `fix(replenish): use locationStock from DTO for held-up items` (mobile) |
