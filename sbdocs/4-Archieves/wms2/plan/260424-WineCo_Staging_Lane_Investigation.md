# WineCo Staging Lane Investigation Report

**Date:** 2026-03-15
**Status:** Investigation Complete — Fixes Pending
**Priority:** Critical
**Client:** WineCo
**Related Tickets:** Convos 841, 842, 843, 844
**Reported By:** Michelle @ WineCo
**Investigated By:** Development Team

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Investigation Methodology](#3-investigation-methodology)
4. [Findings — Current Blockers](#4-findings--current-blockers)
5. [Findings — Historical Data Impact](#5-findings--historical-data-impact)
6. [Root Cause Analysis](#6-root-cause-analysis)
7. [Bug Details — WMS `cancelBatch()` Never Updates State](#7-bug-details--wms-cancelbatch-never-updates-state)
8. [Bug Details — WMS `closeBOL()` Never Clears Staging Lane](#8-bug-details--wms-closebol-never-clears-staging-lane)
9. [Bug Details — OMS Cancellation Never Propagates to WMS for Club Batches](#9-bug-details--oms-cancellation-never-propagates-to-wms-for-club-batches)
10. [Bug Details — OMS Never Updates `batch_criteria.batch_status`](#10-bug-details--oms-never-updates-batch_criteriabatch_status)
11. [Recommended Fixes](#11-recommended-fixes)
12. [Data Cleanup Plan](#12-data-cleanup-plan)
13. [Testing Checklist](#13-testing-checklist)
14. [Appendix A — WMS State Reference](#appendix-a--wms-state-reference)
15. [Appendix B — OMS Status Reference](#appendix-b--oms-status-reference)
16. [Appendix C — Staging Lane Availability Query](#appendix-c--staging-lane-availability-query)

---

## 1. Executive Summary

WineCo has **20 physical staging lanes** (StagingLane01–20) used for Club Run batch processing. **15 of 20 lanes are currently blocked** by batches stuck in active WMS states (520 PICKING / 525 PICKED) that will never progress because their orders have been cancelled in the OMS.

This is caused by **four independent bugs** working together:

1. **WMS `cancelBatch()` never updates batch state or clears staging lane** — it only notifies the OMS
2. **WMS `closeBOL()` never clears `staginglane_id` on batch completion** — completed batches retain lane references forever
3. **OMS cancellation never propagates to WMS for Club batches** — order-level cancellations in OMS don't trigger WMS batch cancellation
4. **OMS never updates `batch_criteria.batch_status`** — the batch header status remains NULL even when all orders are cancelled

These bugs have existed since the system's inception. The staging lane leak (Bug #2) has been silently accumulating **11,352 stale lane references** since **February 13, 2020** (over 6 years) but went unnoticed because the WMS availability query correctly excludes completed batches. The crisis became visible only when enough active batches (Bugs #1 and #3) accumulated to exhaust all 20 lanes.

### Systems & Versions Reference

> **⚠️ Important context for this report:** Two versions of the WMS and OMS codebases exist. WineCo runs on the **v1** stack. The **v2** stack is the next-generation multi-tenant rewrite. **All four bugs exist in both versions**, but the implementations differ in some areas.

| System | v1 (WineCo Production) | v2 (Next-Gen Multi-Tenant) |
|--------|----------------------|--------------------------|
| **WMS API** | Spring Boot 2.3.7, Java 8 | Spring Boot 3.5.9, Java 21 |
| **WMS Path** | `v1/wms-api/` | `v2/wms-api/` |
| **OMS** | Zend Framework 2, PHP 5.6 | Laravel 12, PHP 8.4 |
| **OMS Path** | `v1/oms-v1/` | `v2/oms-laravel-api/` |
| **Database** | PostgreSQL (WMS), MySQL (OMS) | PostgreSQL (WMS), MySQL (OMS) |

---

## 2. Problem Statement

Michelle @ WineCo reported across support conversations 841–844 that:

- Several Club Run batches are **cancelled in the OMS** but remain **active in the WMS**
- These stuck batches are **occupying staging lanes** that cannot be freed
- The warehouse has effectively **run out of staging lanes** for new Club Runs
- WMS shows these batches in PICKING/PICKED state with no way to cancel them

The immediate business impact is that **WineCo cannot process new Club Runs** because only 5 of 20 staging lanes are available, and some of those may not be physically usable.

---

## 3. Investigation Methodology

- Restored production database snapshots (2026-03-03) into local Docker containers:
  - **OMS**: MySQL 8.0 container (`oms-analysis`, port 3307) — `om1_wineco` database
  - **WMS**: PostgreSQL 16 container (`sb-postgres`, port 5432) — `wineco_wms` database
- Cross-referenced batch data between OMS (`batch_criteria`, `order`, `parcel` tables) and WMS (`customerorder_batch`, `location` tables)
- Audited WMS Java source code (both v1 and v2) for `cancelBatch()`, `closeBOL()`, and staging lane management
- Audited OMS PHP source code (both Zend v1 and Laravel v2) for batch cancellation logic
- Analyzed 6+ years of historical batch data for pattern identification

---

## 4. Findings — Current Blockers

### 4.1 Currently Blocked Staging Lanes (15 of 20)

| Lane | WMS Batch | WMS State | WMS State Name | OMS Order Status | Orders | Batch Group | Created |
|------|-----------|-----------|----------------|------------------|--------|-------------|---------|
| StagingLane02 | 48479-6 | 520 | PICKING | 3 (Processing) | 33 | 48479 | 2026-03-11 |
| StagingLane03 | 48374-1 | 520 | PICKING | **28 (Cancel)** | 65 | 48374 | 2026-03-09 |
| StagingLane04 | 48452-1 | 520 | PICKING | **28 (Cancel)** | 573 | 48452 | 2026-03-13 |
| StagingLane05 | 48374-11 | 525 | PICKED | 3 (Processing) | 41 | 48374 | 2026-03-11 |
| StagingLane06 | 48479-4 | 520 | PICKING | 3 (Processing) | 30 | 48479 | 2026-03-11 |
| StagingLane08 | 48479-3 | 520 | PICKING | 3 (Processing) | 29 | 48479 | 2026-03-11 |
| StagingLane11 | 48479-2 | 520 | PICKING | 3 (Processing) | 30 | 48479 | 2026-03-11 |
| StagingLane13 | 48479-1 | 520 | PICKING | 3 (Processing) | 18 | 48479 | 2026-03-11 |
| StagingLane14 | 48479-5 | 525 | PICKED | 3 (Processing) | 41 | 48479 | 2026-03-11 |
| StagingLane15 | 48374-7 | 520 | PICKING | **28 (Cancel)** | 84 | 48374 | 2026-03-10 |
| StagingLane16 | 48374-2 | 525 | PICKED | **28 (Cancel)** | 58 | 48374 | 2026-03-09 |
| StagingLane17 | 48374-6 | 520 | PICKING | **28 (Cancel)** | 87 | 48374 | 2026-03-09 |
| StagingLane18 | 48374-5 | 520 | PICKING | **28 (Cancel)** | 71 | 48374 | 2026-03-09 |
| StagingLane19 | 48374-4 | 520 | PICKING | **28 (Cancel)** | 49 | 48374 | 2026-03-09 |
| StagingLane20 | 48374-3 | 520 | PICKING | **28 (Cancel)** | 103 | 48374 | 2026-03-09 |

### 4.2 Available Staging Lanes (5 of 20)

| Lane | Status | Notes |
|------|--------|-------|
| StagingLane01 | Available* | *Has canceled batch 16138-2 (state 800) — doesn't block because 800 ≥ 530 threshold |
| StagingLane07 | Available | Clean |
| StagingLane09 | Available | Clean |
| StagingLane10 | Available | Clean |
| StagingLane12 | Available | Clean |



### 4.3 Additional Stuck Batches (No Staging Lane Assigned)

These batches were reported in convos 842 and 844. They exist in the WMS at state 0 (RAW) with no staging lane, but their orders are cancelled in the OMS:

| WMS Batch | WMS State | WMS Lane | OMS Order Status | Orders | Notes |
|-----------|-----------|----------|------------------|--------|-------|
| 46958-45 | 0 (RAW) | *(none)* | **28 (Cancel)** | 1 | Convo 842 — Club batch, never progressed |
| 46958-46 | *(not in WMS)* | — | **28 (Cancel)** | 1 | Convo 842 — May not have been pushed to WMS |
| 46974-124 | 0 (RAW) | *(none)* | **28 (Cancel)** | 1 | Convo 844 — Club batch, never progressed |

### 4.4 Batch Groups Summary

| Batch Group (file_id) | Total Sub-Batches | OMS-Cancelled | OMS-Processing | Lanes Blocked | Total Orders |
|------------------------|-------------------|---------------|----------------|---------------|--------------|
| **48374** | 15 | 7 (Club) | 1 (Club: 48374-11) | 8 | 558 cancelled + 41 processing |
| **48479** | 8 | 0 | 6 (Club) | 6 | 181 processing |
| **48452** | 1 | 1 (Club) | 0 | 1 | 573 cancelled |
| **46958** | 48 | 2 (Club: 45, 46) | 0 | 0 | 2 cancelled |
| **46974** | 124 | 1 (Club: 124) | 0 | 0 | 1 cancelled |
| **Totals** | — | **11** | **7** | **15** | **1,356** |

> **Note:** The 48479 sub-batches (1–6) and 48374-11 have OMS order status **3 (Processing)**, NOT 28 (Cancel). Michelle may not have cancelled these yet, or they may represent a separate issue where the OMS v2 blocks Club order cancellation (see Bug #3).

---

## 5. Findings — Historical Data Impact

### 5.1 Scale of Stale Data

| Metric | Count |
|--------|-------|
| Total batches ever created in WMS | **58,715** |
| Batches still holding a staging lane reference | **11,368** (19.4%) |
| Completed (state 700) with stale lane reference | **11,352** |
| Canceled (state 800) with stale lane reference | **1** (batch 16138-2 on StagingLane01) |
| Active (state < 700) blocking lanes | **15** |

### 5.2 Timeline

- **First stale assignment:** Batch `32-1`, created **2020-02-13**, completed **2020-02-14**, still assigned to StagingLane06
- **Duration of the leak:** **6 years, 1 month** (Feb 2020 – Mar 2026)
- **Average stale batches per month:** ~153

### 5.3 Why It Went Unnoticed for 6 Years

The `getAvailableStagingLanes` query in the WMS uses a **state threshold of 530** (`ORDER_BATCH_CLUB_RUN_FINISHED`) to determine lane occupancy:

```sql
-- File: v1/wms-api/src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java (lines 44-52)
SELECT * FROM location
WHERE location.staginglane = true
  AND NOT EXISTS (
    SELECT 1 FROM customerorder_batch orderBatch
    WHERE location.id = orderbatch.staginglane_id
      AND orderBatch.id != :batchId
      AND orderBatch.state < 530   -- ← threshold: ORDER_BATCH_CLUB_RUN_FINISHED
  )
ORDER BY location.name
```

Since completed batches have state **700** (≥ 530), they pass through the threshold and **never block new lane assignments**. The stale references are functionally harmless orphaned data. The problem only became critical when **active** batches (states 520/525, which are < 530) accumulated and exhausted all 20 lanes.

### 5.4 Peak Monthly Accumulation (Stale Completed Batches Retaining Lane References)

| Month | Stale Batches |
|-------|---------------|
| Oct 2020 | 330 |
| Dec 2021 | 330 |
| Mar 2021 | 315 |
| Oct 2021 | 283 |
| Oct 2024 | 262 |
| May 2023 | 256 |
| Nov 2022 | 253 |
| Nov 2021 | 249 |
| Nov 2023 | 245 |
| Dec 2022 | 245 |

---

## 6. Root Cause Analysis

Four independent bugs chain together to create this issue:

```
  OMS (PHP / Laravel)                          WMS (Java / Spring Boot)
  ════════════════════                         ═══════════════════════════

  User cancels orders                          cancelBatch() is called
  in a Club batch                              (from WMS UI or API)
         │                                              │
         ▼                                              ▼
  ┌─────────────────────┐                     ┌─────────────────────────┐
  │ Bug #3: OMS cancels │                     │ Bug #1: cancelBatch()   │
  │ individual orders   │                     │ builds DTO, POSTs to    │
  │ (status → 28) but   │──── no signal ────▶ │ OMS... and then STOPS.  │
  │ NEVER triggers WMS  │                     │ Never sets state → 800  │
  │ batch cancellation  │                     │ Never clears lane ref   │
  └─────────────────────┘                     └─────────────────────────┘
         │                                              │
         ▼                                              ▼
  ┌─────────────────────┐                     ┌─────────────────────────┐
  │ Bug #4: OMS never   │                     │ Bug #2: closeBOL() sets │
  │ updates batch_      │                     │ state → 700 (FINISHED)  │
  │ criteria.batch_     │                     │ but NEVER clears        │
  │ status — always     │                     │ staginglane_id          │
  │ remains NULL        │                     │ → silent lane leak      │
  └─────────────────────┘                     └─────────────────────────┘
```

---

## 7. Bug Details — WMS `cancelBatch()` Never Updates State

**Severity:** Critical
**Production System (WineCo):** v1 WMS (Spring Boot 2.3.7, Java 8)
**Also affects:** v2 WMS (Spring Boot 3.5.9, Java 21) — same bug, nearly identical code

| | v1 (Production) | v2 (Next-Gen) |
|---|---|---|
| **File** | `v1/wms-api/.../service/CustomerorderBatchService.java` | `v2/wms-api/.../service/CustomerorderBatchService.java` |
| **Lines** | 175–255 | 199–272 |
| **Visibility** | `private` | `public` |
| **Logic** | Identical | Identical |
| **Same bug?** | ✅ Yes | ✅ Yes |
| **Differences** | Uses `.get()` for Optional, `losSyspropRepository`, string concat logging | Uses `.orElseThrow()`, `syspropRepository`, `{}` placeholder logging |

### What the method does:

1. Validates the batch isn't already FINISHED (state ≥ 700)
2. Validates no orders are beyond PACKED state
3. Builds a DTO with all order positions
4. POSTs the DTO to the OMS cancel URL
5. Creates a Message record for audit trail
6. **Returns — without updating anything in the WMS database**

### What's missing (the 3 critical lines):

```java
// These lines should be at the END of cancelBatch(), BEFORE the final LOG.debug:
orderBatch.setState(WmsConstants.State.CANCELED);       // Set state to 800
orderBatch.setStaginglaneId(null);                       // Release the staging lane
customerorderBatchRepository.save(orderBatch);           // Persist changes
```

### Evidence from the code:

The method ends with only a log statement after the try/catch for the HTTP POST:

```java
// v1 line 254 / v2 line 271 — the method just ends:
LOG.debug("end   for batch=" + orderBatch);
}
```

Compare this to `unlinkStagingLaneFromOrderBatch()` (v1 line 531) which correctly calls `setStaginglaneId(null)` and `save()` — proving the pattern exists in the same class but was simply omitted from `cancelBatch()`.

---

## 8. Bug Details — WMS `closeBOL()` Never Clears Staging Lane

**Severity:** High (silent data leak, not blocking until combined with Bug #1)
**Production System (WineCo):** v1 WMS (Spring Boot 2.3.7, Java 8)
**Also affects:** v2 WMS (Spring Boot 3.5.9, Java 21) — same bug, **different implementation**

Two code paths set the batch to a completed state but neither clears `staginglane_id`:

### Path 1: Regular batch completion (`closeBOL`)

| | v1 (Production) | v2 (Next-Gen) |
|---|---|---|
| **File** | `v1/wms-api/.../service/BillofladingService.java` | `v2/wms-api/.../service/BillofladingService.java` |
| **Lines** | 601–612 | 673–703 |
| **Implementation** | Loop: `findById()` + `save()` per batch | Bulk JPQL: `UPDATE ... SET state = :finished WHERE id IN :batchIds` |
| **Same bug?** | ✅ Yes — never clears `staginglane_id` | ✅ Yes — JPQL update also omits `staginglane_id` |

**v1 code (loop-based):**
```java
// PHASE 9: Batch finalization (v1, lines 601-612)
for (CustomerorderBatch staleBatch : orderBatchHashMap.values()) {
    CustomerorderBatch orderBatch = customerorderBatchRepository.findById(staleBatch.getId())...;
    List<Customerorder> batchOrders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
    if (batchOrders.stream().anyMatch(o -> o.getState() < WmsConstants.State.FINISHED)) {
        LOG.debug("orderBatch still contains order in not final state");
    } else {
        orderBatch.setState(WmsConstants.State.FINISHED);    // ← Sets state to 700
        // orderBatch.setStaginglaneId(null);                 // ← MISSING
        customerorderBatchRepository.save(orderBatch);
    }
}
```

**v2 code (bulk JPQL):**
```java
// OPTIMIZATION: Bulk batch finalization (v2, lines 673-703)
List<Long> completedBatchIds = entityManager.createQuery(
    "SELECT cb.id FROM CustomerorderBatch cb WHERE cb.id IN :batchIds " +
    "AND NOT EXISTS (SELECT 1 FROM Customerorder co WHERE co.orderbatchId = cb.id AND co.state < :finished)",
    Long.class)...getResultList();

int updated = entityManager.createQuery(
    "UPDATE CustomerorderBatch cb SET cb.state = :finished, cb.version = cb.version + 1 " +
    "WHERE cb.id IN :batchIds")                              // ← MISSING: no staginglaneId = null
    .setParameter("finished", WmsConstants.State.FINISHED)
    .setParameter("batchIds", completedBatchIds)
    .executeUpdate();
```

### Path 2: Club Run completion (`closeBOL`)

| | v1 (Production) | v2 (Next-Gen) |
|---|---|---|
| **File** | Same as above | Same as above |
| **Lines** | 947–949 | 753–755 |
| **Implementation** | Identical logic | Identical logic (only `.get()` vs `.orElseThrow()` differs) |
| **Same bug?** | ✅ Yes | ✅ Yes |

**Both versions (identical logic):**
```java
CustomerorderBatch coOrderBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId()).get();  // v1
coOrderBatch.setState(WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED);  // ← Sets state to 530
// coOrderBatch.setStaginglaneId(null);                                    // ← MISSING in both v1 and v2
customerorderBatchRepository.save(coOrderBatch);
```

### What should be added:

```java
orderBatch.setStaginglaneId(null);  // Release staging lane on completion
```

This single missing line is responsible for **11,352 stale lane references** accumulated over 6 years.

---

## 9. Bug Details — OMS Cancellation Never Propagates to WMS for Club Batches

**Severity:** Critical
**Affected System:** OMS — the cancellation gap exists across both versions
**OMS v1 (Zend Framework 2, PHP 5.6):** WineCo's current production OMS — no evidence of a batch-level cancel-to-WMS flow
**OMS v2 (Laravel 12, PHP 8.4):** Next-gen OMS — explicitly blocks Club cancellation AND lacks batch-level WMS notification
**File (v2):** `v2/oms-laravel-api/app/Services/Legacy/LegacyOrderCancelService.php` (lines 223–236)

### The Block (OMS v2 only)

The OMS v2 `validateOrderForCancellation()` method **explicitly prevents cancellation of Club-batched orders**. This guard does NOT exist in v1 OMS:

```php
// Lines 223-236 — LegacyOrderCancelService.php
$clubBatched = $this->db()->table('parcel as p')
    ->join('batch_criteria as bc', 'bc.batch_criteria_id', '=', 'p.batch_criteria_id')
    ->where('p.order_id', $orderId)
    ->where('p.isactive', 1)
    ->where('bc.packing_line', 'Club')
    ->exists();

if ($clubBatched) {
    return [
        'valid' => false,
        'reason' => 'Order has been batched to WMS as a Club order and cannot be cancelled'
    ];
}
```

### The Paradox

If OMS v2 blocks Club order cancellation, how did these orders get cancelled (status 28)?

Possible explanations:
1. **Legacy v1 OMS** — The Zend Framework v1 OMS may not have this guard, and the cancellations were performed before the v2 migration
2. **Direct database manipulation** — Someone manually updated `order.order_status = 28` in the database
3. **Stored procedure bypass** — An older stored procedure cancellation path that didn't check for Club batching

Regardless of how the orders were cancelled, the WMS was **never notified** because:
- The OMS v2 cancel flow calls `notifyWmsOfCancellation()` which sends individual **order position** cancellations — NOT **batch** cancellations
- Even if the notification reached WMS, it would cancel individual `customerorder` records, not the parent `customerorder_batch`
- The batch would remain in its current state (520/525) with its staging lane reference intact

### The Flow Gap

```
What should happen:          What actually happens:
─────────────────            ────────────────────
OMS cancels all orders       OMS cancels all orders (status → 28)
       ↓                            ↓
OMS detects all orders       OMS does nothing with batch_criteria
cancelled in batch                  ↓
       ↓                     WMS is NOT notified
OMS calls WMS                      ↓
cancelBatch API              WMS batch stays at 520/525
       ↓                            ↓
WMS sets batch → 800         Staging lane stays occupied
WMS clears staginglane_id           ↓
       ↓                     ❌ Lane permanently blocked
✅ Lane freed
```

---

## 10. Bug Details — OMS Never Updates `batch_criteria.batch_status`

**Severity:** Medium (informational inconsistency, no direct operational impact)
**Affected System:** Both OMS v1 (Zend, PHP) and OMS v2 (Laravel, PHP) — neither version ever populates this column

### Evidence

Every single batch referenced in this investigation has `batch_criteria.batch_status = NULL` in the OMS database, regardless of whether orders are cancelled, processing, or shipped:

| file_id | batch_label | OMS order_status | batch_criteria.batch_status |
|---------|-------------|------------------|-----------------------------|
| 48374 | 48374-1 | 28 (Cancel) | NULL |
| 48374 | 48374-11 | 3 (Processing) | NULL |
| 48452 | 48452-1 | 28 (Cancel) | NULL |
| 48479 | 48479-1 | 3 (Processing) | NULL |
| 46958 | 46958-45 | 28 (Cancel) | NULL |
| 46974 | 46974-124 | 28 (Cancel) | NULL |

The `batch_criteria.batch_status` column is never updated by any code path. The OMS tracks order status at the `order` level but has no mechanism to roll up that status to the batch header.

This makes it impossible to query "which batches are cancelled" without aggregating individual order statuses.

---

## 11. Recommended Fixes

### Fix 1: WMS `cancelBatch()` — Set State and Clear Lane

**Same fix needed in both v1 and v2 — the code to add is identical.**

| | v1 (Production — deploy first) | v2 (Next-Gen) |
|---|---|---|
| **File** | `v1/wms-api/.../service/CustomerorderBatchService.java` | `v2/wms-api/.../service/CustomerorderBatchService.java` |
| **Insert before** | Line 254 (`LOG.debug("end   for batch="...`) | Line 271 (`LOG.debug("end   for batch={}"...`) |

**Code to add (identical in both versions):**

```java
// Cancel all customer orders in the batch
for (Customerorder customerOrder : batchOrders) {
    customerOrder.setState(WmsConstants.State.CANCELED);
    customerorderRepository.save(customerOrder);
}

// Update batch state and release staging lane
orderBatch.setState(WmsConstants.State.CANCELED);
orderBatch.setStaginglaneId(null);
customerorderBatchRepository.save(orderBatch);
```

### Fix 2: WMS `closeBOL()` — Clear Lane on Batch Completion

**⚠️ v1 and v2 have DIFFERENT implementations — the fix differs between versions.**

#### Fix 2a: Regular batch completion path

| | v1 (Production — deploy first) | v2 (Next-Gen) |
|---|---|---|
| **File** | `v1/wms-api/.../service/BillofladingService.java` | `v2/wms-api/.../service/BillofladingService.java` |
| **Lines** | 609 | 690–695 |
| **Current code** | `orderBatch.setState(FINISHED); save();` | Bulk JPQL: `UPDATE ... SET state = :finished` |
| **Fix** | Add `orderBatch.setStaginglaneId(null);` before `save()` | Add `, cb.staginglaneId = null` to the JPQL UPDATE |

**v1 fix (add one line):**
```java
orderBatch.setState(WmsConstants.State.FINISHED);
orderBatch.setStaginglaneId(null);                // ← ADD THIS LINE
customerorderBatchRepository.save(orderBatch);
```

**v2 fix (modify the JPQL query):**
```java
int updated = entityManager.createQuery(
    "UPDATE CustomerorderBatch cb SET cb.state = :finished, cb.staginglaneId = null, cb.version = cb.version + 1 " +
    //                                                      ^^^^^^^^^^^^^^^^^^^^^^^^ ADD THIS
    "WHERE cb.id IN :batchIds")
    .setParameter("finished", WmsConstants.State.FINISHED)
    .setParameter("batchIds", completedBatchIds)
    .executeUpdate();
```

#### Fix 2b: Club Run completion path

**Same fix in both v1 and v2 — add one line:**

| | v1 (Production) | v2 (Next-Gen) |
|---|---|---|
| **File** | Same as above | Same as above |
| **Line** | After line 948 | After line 754 |

```java
coOrderBatch.setState(WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED);
coOrderBatch.setStaginglaneId(null);              // ← ADD THIS LINE (both v1 and v2)
customerorderBatchRepository.save(coOrderBatch);
```

### Fix 3: OMS — Propagate Batch Cancellation to WMS (Future Enhancement)

**Affects:** Both OMS v1 (Zend/PHP) and OMS v2 (Laravel/PHP). Neither version has batch-level WMS cancellation logic.

When all orders in a batch are cancelled, the OMS should:
1. Update `batch_criteria.batch_status` to reflect cancellation
2. Call the WMS batch cancellation API to cancel the entire batch

> **Note:** This is a more complex fix requiring OMS-side changes. Fixes 1 and 2 should be deployed first as they address the immediate WMS-side issue. Since WineCo currently runs on OMS v1 (Zend), this fix needs to be evaluated for both OMS versions independently.

---

## 12. Data Cleanup Plan

### Phase 1: Immediate — Unblock the 15 Active Lanes (Production WMS Database)

**⚠️ CRITICAL: These SQL statements must be reviewed and approved before execution on production.**
**⚠️ Execute during a maintenance window when no Club Runs are being processed.**

```sql
-- =============================================================================
-- PHASE 1A: Cancel the 15 actively blocking batches and release their lanes
-- These are the batches in states 520/525 whose OMS orders are cancelled or stuck
-- =============================================================================

BEGIN;

-- Cancel all customer orders in the blocking batches
UPDATE customerorder co
SET co.state = 800  -- CANCELED
WHERE co.orderbatch_id IN (
    SELECT cb.id FROM customerorder_batch cb
    WHERE cb.batchid IN (
        '48374-1', '48374-2', '48374-3', '48374-4', '48374-5',
        '48374-6', '48374-7', '48374-11',
        '48452-1',
        '48479-1', '48479-2', '48479-3', '48479-4', '48479-5', '48479-6'
    )
)
AND co.state < 800;

-- Cancel the batches and release their staging lanes
UPDATE customerorder_batch
SET state = 800,           -- CANCELED
    staginglane_id = NULL  -- Release the staging lane
WHERE batchid IN (
    '48374-1', '48374-2', '48374-3', '48374-4', '48374-5',
    '48374-6', '48374-7', '48374-11',
    '48452-1',
    '48479-1', '48479-2', '48479-3', '48479-4', '48479-5', '48479-6'
);

-- Also cancel the RAW batches that never progressed
UPDATE customerorder_batch
SET state = 800
WHERE batchid IN ('46958-45', '46974-124')
AND state = 0;

-- Verify: Should show 0 rows with state < 700 and staginglane_id NOT NULL
SELECT cb.batchid, cb.state, l.name AS lane
FROM customerorder_batch cb
JOIN location l ON cb.staginglane_id = l.id
WHERE cb.state < 700;

COMMIT;
```

### Phase 2: Cleanup — Clear 11,352 Stale Lane References

```sql
-- =============================================================================
-- PHASE 2: Clear staginglane_id from all completed/cancelled batches
-- These are functionally harmless but should be cleaned up
-- =============================================================================

BEGIN;

-- Clear stale staging lane references from completed batches
UPDATE customerorder_batch
SET staginglane_id = NULL
WHERE staginglane_id IS NOT NULL
AND state >= 700;  -- FINISHED (700) or CANCELED (800)

-- Verify: Should return count matching affected rows
SELECT COUNT(*) AS remaining_stale
FROM customerorder_batch
WHERE staginglane_id IS NOT NULL
AND state >= 700;

COMMIT;
```

### Phase 3: Verification

```sql
-- After both phases, verify the full picture:
SELECT
    CASE
        WHEN cb.state < 530 THEN 'BLOCKING (< 530)'
        WHEN cb.state >= 530 AND cb.state < 700 THEN 'ACTIVE (530-699)'
        WHEN cb.state = 700 THEN 'COMPLETED (700)'
        WHEN cb.state = 800 THEN 'CANCELED (800)'
    END AS category,
    COUNT(*) AS batch_count,
    COUNT(cb.staginglane_id) AS with_lane_ref
FROM customerorder_batch cb
GROUP BY category
ORDER BY category;
```

---

## 13. Testing Checklist

### Pre-Deployment Verification

- [ ] Phase 1 SQL reviewed and approved by team lead
- [ ] Phase 2 SQL reviewed and approved by team lead
- [ ] Database backup taken before execution
- [ ] Maintenance window scheduled with WineCo

### Phase 1 Execution

- [ ] All 15 blocking batches set to state 800
- [ ] All 15 staging lanes released (staginglane_id = NULL)
- [ ] RAW batches 46958-45 and 46974-124 set to state 800
- [ ] `getAvailableStagingLanes` query returns all 20 lanes
- [ ] WineCo confirms they can create new Club Runs

### Phase 2 Execution

- [ ] 11,352 completed batches have staginglane_id cleared
- [ ] No remaining stale lane references for state ≥ 700 batches
- [ ] Existing active batches unaffected

### Code Fix Deployment (When Ready)

- [ ] Fix 1 (`cancelBatch`) applied to v1 WMS — tested with batch cancellation
- [ ] Fix 1 (`cancelBatch`) applied to v2 WMS — tested with batch cancellation
- [ ] Fix 2 (`closeBOL`) applied to v1 WMS — tested with BOL close
- [ ] Fix 2 (`closeBOL`) applied to v2 WMS — tested with BOL close
- [ ] After code deployment, create a test Club Run, complete it, verify lane is released
- [ ] After code deployment, create a test Club Run, cancel it, verify lane is released and state is 800

---

## Appendix A — WMS State Reference

| Constant | Value | Description |
|----------|-------|-------------|
| `RAW` | 0 | Initial state — batch created |
| `RAW_ON_HOLD` | 50 | Batch on hold |
| `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` | 55 | Hold: insufficient stock |
| `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` | 56 | Hold: no location assigned |
| `RAW_ON_HOLD_PROBLEM_WITH_FIXED_ASSIGNED_LOCATION` | 57 | Hold: location problem |
| `RAW_ON_HOLD_FIX_ASSIGNMENT_IS_INACTIVE` | 58 | Hold: inactive assignment |
| `FUTURE_PICKING_DATE` | 80 | Scheduled for future picking |
| `STARTED` | 500 | Batch started |
| `ORDER_BATCH_ACTIVATED` | 520 | Batch activated / picking initiated |
| `ORDER_BATCH_STAGING_LANE_ASSIGNED` | 525 | Staging lane assigned |
| **`ORDER_BATCH_CLUB_RUN_FINISHED`** | **530** | **Club Run finished — availability threshold** |
| `PICKED` | 600 | All items picked |
| `PACKED` | 650 | All items packed |
| `FINISHED` | 700 | Batch completed |
| `CANCELED` | 800 | Batch cancelled |

**Source:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java` (lines 18–109)

### Lane Availability Threshold

The `getAvailableStagingLanes` query considers a lane **occupied** if any batch with `state < 530` is assigned to it. This means:
- States 0–525: **Block** lane availability
- States 530+: **Do not block** lane availability (but stale references remain in the database)

---

## Appendix B — OMS Status Reference

| Status ID | Status String | Description |
|-----------|---------------|-------------|
| 1 | New | New order |
| 2 | New-Carrier-Assigned | Carrier assigned |
| 3 | Processing | Being processed |
| 4 | Shipped | Shipped |
| 5 | Complete | Completed |
| 6 | Exception | Exception/error |
| 28 | Cancel | Cancelled |
| 29 | Removed | Removed |

**Key Column:** `order.order_status` — the individual order status
**Unused Column:** `batch_criteria.batch_status` — always NULL (Bug #4)

---

## Appendix C — Staging Lane Availability Query

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java`
**Lines:** 44–52

```java
@RestResource(path = "getAvailableStagingLanes", rel = "getAvailableStagingLanes")
@Query(value = "SELECT * FROM location" +
    " WHERE location.staginglane = true" +
    " AND NOT EXISTS ( SELECT 1 FROM customerorder_batch orderBatch " +
    " WHERE location.id = orderbatch.staginglane_id " +
    " AND orderBatch.id != :batchId " +
    " AND orderBatch.state < :state ) " +
    "ORDER BY location.name", nativeQuery = true)
List<Location> getAvailableStagingLanes(@Param("batchId") Long batchId, @Param("state") int state);
```

The `:state` parameter is passed as `WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED` (530) from the calling code.

---

## Appendix D — Files Referenced in This Report

| File | System | Purpose |
|------|--------|---------|
| `v1/wms-api/.../service/CustomerorderBatchService.java` | WMS v1 | Contains `cancelBatch()` (Bug #1) and `unlinkStagingLaneFromOrderBatch()` |
| `v2/wms-api/.../service/CustomerorderBatchService.java` | WMS v2 | Contains `cancelBatch()` (Bug #1, identical to v1) |
| `v1/wms-api/.../service/BillofladingService.java` | WMS v1 | Contains `closeBOL()` (Bug #2) |
| `v2/wms-api/.../service/BillofladingService.java` | WMS v2 | Contains `closeBOL()` (Bug #2, identical to v1) |
| `v1/wms-api/.../repo/jpa/LocationRepository.java` | WMS v1 | Contains `getAvailableStagingLanes` query |
| `v1/wms-api/.../service/WmsConstants.java` | WMS v1 | State constants |
| `v2/oms-laravel-api/.../Legacy/LegacyOrderCancelService.php` | OMS v2 | Contains Club cancellation block (Bug #3) |

---

*Report generated 2026-03-15. Data sourced from production database snapshots dated 2026-03-03.*