---
title: "runClubLine Transaction Boundary & Hardening"
ticket: ""
ticket_url: ""
type: bug
priority: urgent
status: implemented-pending-review
project: [wms1]
version: v1
requester: audit-driven
created: 2026-04-24
updated: 2026-04-24
deployed_env: dev
related:
  - 260424-oms-notification-rollback-risk-remediation
  - 260422-changeReservedAmount-stale-object-state-fix
  - 260422-mobile-picking-stale-tote-clear-loses-pickingtoteid
tags:
  - plan
  - bug
  - transactions
  - oms-notification
  - picking
  - club-run
  - concurrency
---

# runClubLine Transaction Boundary & Hardening

**Project:** v1/wms-api | **Version:** v1 | **Type:** Bug (transaction/OMS-notification correctness) + hardening
**Priority:** Urgent — production duplicate-notification and retry-amplification risk
**Status:** PLANNING (v2 — deep re-validation 2026-04-24)
**Date:** 2026-04-24
**Related:** `260424-oms-notification-rollback-risk-remediation.md` (parent program for non-runClubLine sites)

**Source audits validated against `develop` branch @ `7e1b5e6`:**
Original audits — runClubLine failure-points (full scope) and OMS notification rollback risk §3.1 (runClubLine subset).

**Revision 2 changelog (2026-04-24):** Added F6 (concurrent-run defense), F7 (stock-scan dedupe + extended `.orElse(null)` cleanup), F8 (phased "once-for-all" OMS delivery guarantee). Priority re-stratification. Test matrix expanded. Rollout order rewritten.

**Revision 3 status (2026-04-24):** F1-F7 implemented on `develop`. F4, F8 remain deferred per rollout plan. See §10 for detailed status.

---

## 1. Problem Statement

`CustomerorderBatchService.runClubLine` (`src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java:515-648`) fires **three synchronous OMS HTTP POSTs** from the middle of a transaction that still has material DB writes after them. When anything after the POSTs throws — optimistic lock, `DataAccessException`, `FacadeException`, `ProcessingException` from a downstream timeout — the WMS transaction rolls back but OMS has already committed state for "released → picking-started → picking-finished". A "Run Club" retry compounds the problem because `OptimisticLockRetryTemplate.executeWithRetry` re-invokes the full method up to 5 attempts, producing up to **15 duplicate OMS events** per run.

### 1.1 User-visible symptoms

| Observable | Cause | Resolved by |
|---|---|---|
| OMS shows batch as PICKED/PACKED, WMS shows batch still ACTIVATED/STAGING_LANE_ASSIGNED | Commit-time failure in Phase 4 after OMS POSTs succeeded. | F1 |
| 3× or up to 15× duplicate `ORDER_BATCH_PICKING_*` messages for the same batch | `OptimisticLockRetryTemplate` retries include the OMS calls. | F1 |
| Unrelated stock appears on a parcel external number from a prior, non-completed run | `unitloadService.createUnitload` silent-return on duplicate `labelid`. | F2 |
| NPE with `"No value present"` / null deref, no entity identity in the 500 message | `itemdataRepository.findById(...).orElse(null)` then dereference. | F3 + F7 |
| "Insufficient stock for position" mid-run after Phase 2 started (partial parcels created before failure) | Phase-1 optimistic stock read races with concurrent picker/transfer. | F4 |
| Two simultaneous "Run Club" clicks on the same batch both consume time; second fails with obscure `ObjectOptimisticLockingFailureException` | `CustomerorderBatch` has `@Version` but no pessimistic entry lock; both operators race until commit. | F6 |
| After F1 lands: OMS outage leaves `message.status = 'FAILED'` rows with no auto-delivery | No scheduled retry poller exists; `MessageService.resendMessage` is admin-only. | F8 (Phase 2) |

### 1.2 Scope of the plan

**Primary (urgent, required before next high-traffic Club run):** F1 (afterCommit), F2 (parcel-label collision), F6 (batch-level pessimistic lock + state re-check).

**Secondary (rolls with the primary change):** F3 (unsafe `.orElse(null)` cleanup), F7 (eliminate double stock scan), F5 (enriched error messages).

**Tertiary (post-stabilization):** F4 (pessimistic staging-lane lock — concurrency hardening), F8 (transactional outbox — durable OMS delivery guarantee).

---

## 2. Root Cause Analysis

### 2.1 Transaction skeleton (confirmed in `develop`)

```java
// CustomerorderBatchService.java
@Service
@Transactional                                                    // class-level, line 28
public class CustomerorderBatchService {
    ...
    @Transactional(rollbackFor = {BusinessException.class, FacadeException.class})  // line 515
    public void runClubLine(Long orderBatchId) throws BusinessException, FacadeException {
        // Phase 0 — entry load (515-527)  ← opens with findById, no lock (see 2.6)
        // Phase 1 — guards + stock pre-check (529-557)  ← double-scans staging lane (see 2.7)
        // Phase 2 — create parcels + transfer stock (559-617)
        manageOrderService.customerOrderReleaseForPicking(orders);    // line 620
        manageOrderService.customerOrderPickingStarted(orders);       // line 621
        manageOrderService.customerOrderPicked(orders);               // line 622 — ALSO writes DB (see 2.2)
        // Phase 4 — mark orders PACKED + save batch (624-646)
    }
}
```

The controller wrapper:

```java
// ClubLineController.java:177
OptimisticLockRetryTemplate.executeWithRetry(() -> {
    customerorderBatchService.runClubLine(currentOrderBatch.getId());
}, "runClubLine(" + orderBatchId + ")");
```

The retry template (`src/main/java/net/aim_ai/wms/service/util/OptimisticLockRetryTemplate.java:19-56`) retries **only** `ObjectOptimisticLockingFailureException` / `javax.persistence.OptimisticLockException`, up to `DEFAULT_MAX_RETRIES = 5`, exponential backoff 50→800ms. Any other exception propagates on the first attempt.

### 2.2 `customerOrderPicked` has a DB write hidden inside it (Club branch)

`ManageOrderService.customerOrderPicked` at lines 283-344 generates a fresh `UUID` per order and persists it **inside** the same transaction, before the HTTP POST:

```java
// ManageOrderService.java:296-308
customerOrderList.forEach(customerOrder -> {
    OrderDto orderDto = addOrderToOrderBatch(customerOrder, orderBatchDto);
    if (isClub) {
        String tote_label = String.valueOf(UUID.randomUUID());     // NEW UUID per call
        orderDto.setToteLabel(tote_label);
        customerOrder.setHistorytote(tote_label);                   // DB field
        customerorderRepository.save(customerOrder);                // DB write inside OMS method
    }
    ...
});
...
Map<String,String> respMap = httpRestService.post(urlPath, payload);   // line 318 — HTTP POST
```

Naively moving the three OMS calls to `afterCommit` would defer the UUID generation past commit, which changes persisted state. The F1 fix must split UUID generation (stays in TX) from the HTTP POST (defers to `afterCommit`).

### 2.3 `HttpRestService` exception surface

Confirmed: `HttpRestService.post` at `src/main/java/net/aim_ai/wms/service/HttpRestService.java:40` declares `throws IOException` only. RESTEasy is configured with 5s connect + 15s read timeout (lines 87-88), which raise `javax.ws.rs.ProcessingException` — **unchecked**, not caught by any `catch (IOException)` in `ManageOrderService`, and therefore triggers the default Spring rollback of `runClubLine`'s transaction.

### 2.4 `UnitloadService.createUnitload` silent-return (F2)

`src/main/java/net/aim_ai/wms/service/UnitloadService.java:108-133`: when `findByLabelid(name)` returns a match, the method silently returns the existing unitload rather than creating a new one. `runClubLine:561` passes `order.getParcelexternalnumber()` as the `name`. If a prior (failed, cancelled, or long-lived) unitload has the same `labelid`, the Club run merges this run's stock into that unitload — possibly at the wrong `storagelocationId` or holding different `Itemdata`. No exception is thrown.

### 2.5 Unsafe `.orElse(null)` sites in runClubLine and its helpers (F3 — reduced and extended scope)

The audit listed six `.get()` sites; most are already fixed to `.orElseThrow(...)` in prior commits (lines 504, 517, 547, 549, 602, 626). **Three remain** after deep re-validation:

| File:Line | Code | Risk |
|---|---|---|
| `CustomerorderBatchService.java:571` | `Itemdata itemData = itemdataRepository.findById(orderPosition.getItemdataId()).orElse(null);` | Immediately dereferenced at line 572 (`itemData.getId()`) and line 573 (`itemDataListMap.get(itemData)`) — NPE if absent. |
| `CustomerorderBatchService.java:588` | `Stockunit stockUnitUpdated = stockunitRepository.findById(stockUnit.getId()).orElse(null);` | Added to `emptyOrMovedStockUnits`; `removeAll` tolerates null but hides data corruption. |
| `CustomerorderBatchService.java:445` (in `isEnoughStockOnStagingLane`) | `Itemdata itemData = itemdataRepository.findById(orderPosition.getItemdataId()).orElse(null);` | Used as map key at line 446 and concatenated at line 447 — NPE on `.containsKey(null)` behavior is tolerated but the error message is meaningless. **NEW in rev 2.** |

A fourth latent site at line 464 (`Itemdata suItemData = itemdataRepository.findById(stockUnit.getItemdataId()).orElse(null);`) is tolerated because the map put at line 471 accepts null keys, but should also be cleaned up for symmetry.

### 2.6 Batch entry is lock-free (NEW — F6)

`runClubLine:517` opens with `customerorderBatchRepository.findById(orderBatchId)` — **no pessimistic lock**, because `CustomerorderBatchRepository` has no `findByIdForUpdate` method. Compare to:

- `CustomerorderRepository.java:168` — `findByIdForUpdate` ✓
- `PickingorderRepository.java:141` — `findByIdForUpdate` ✓
- `BillofladingRepository.java:83` — `findByIdForUpdate` ✓
- `StockunitRepository.java:32` — `findByIdForUpdate` ✓
- `CustomerorderBatchRepository.java` — **absent**

Consequence: two operators clicking "Run Club" on the same batch within the same few milliseconds both pass the state guard at lines 522-527 (both see stale `ORDER_BATCH_ACTIVATED` state). Without F6:

1. Both proceed through Phase 1/Phase 2.
2. Both attempt to `createUnitload(parcelExternalNumber, ...)`. F2 (if deployed) fires only for the slower operator once the faster one's unitload commits — but the faster operator's F2 guard already passed; now they've started transferring stock.
3. Faster operator commits. Slower operator's Phase 4 `customerorderBatchRepository.save(orderBatch)` fails `@Version` check → `ObjectOptimisticLockingFailureException` → retried 5 times by the retry template, all failing with the same version mismatch, eventually surfaces as an obscure error.
4. With F1 already deployed: slower operator never sends OMS POSTs (rollback aborts afterCommit). So no duplicate OMS traffic. But slower operator still wastes up to ~1.5s of CPU and DB I/O.

With F6 (pessimistic batch lock + state re-check inside the lock):
1. Fast operator acquires row-level lock on `customerorder_batch`.
2. Slow operator blocks on the lock.
3. Fast operator commits `ORDER_BATCH_CLUB_RUN_FINISHED`.
4. Slow operator's lock acquires; `findByIdForUpdate` returns the fresh state `ORDER_BATCH_CLUB_RUN_FINISHED`; state guard throws clean `BusinessException("already in CLUB_RUN_FINISHED")`.

Net: slow operator fails in ~5ms with a readable error; no partial work, no retries, no wasted stock reads.

### 2.7 Phase 1 and Phase 2 double-scan the staging lane (NEW — F7)

```java
// Line 539
if (!isEnoughStockOnStagingLane(orderBatch)) {                              // Walk A
    throw new BusinessException("Not enough stock on location.");
}

// Line 543-545
Map<Itemdata, List<Stockunit>> itemDataListMap = new HashMap<>();
List<Unitload> ulList = unitloadRepository.findByStoragelocationId(...);    // Walk B
mapStockUnitsToItemData(ulList, itemDataListMap);
```

Walk A inside `isEnoughStockOnStagingLane`:
1. `unitloadRepository.findByStoragelocationId(stagingLane.getId())` (line 457)
2. Recursive walk via `mapStockUnitsToItemData` (lines 495-513): per unitload → `findByCarrierunitloadId` + `findByUnitloadId` + per-stockunit `itemdataRepository.findById`.

Walk B inside `runClubLine`:
1. `unitloadRepository.findByStoragelocationId(...)` again (line 544)
2. Same recursive walk (line 545).

For a Club lane with N unitloads and M children each, this is ~2 × (N + N*M + stockunits-per-unitload * 2) queries. Besides inefficiency, Walk A and Walk B can observe different snapshots under concurrent stock movement; the pre-check passes, the Phase 2 transfer fails with "Insufficient stock for position ..." at line 612. Rollback is clean but the Club run is wasted.

F4 (pessimistic stagnation-lane unitload lock) closes the race if Walk B's lock is acquired at Walk A time; but the simpler structural fix is F7: make `isEnoughStockOnStagingLane` return BOTH the boolean AND the `Map<Itemdata, List<Stockunit>>` so Phase 2 reuses it. With F7, only ONE scan happens, and if F4 is applied to that single scan, the lock covers the entire run.

### 2.8 Post-F1 OMS outage recovery gap (NEW — F8)

After F1 lands, a true OMS outage during the afterCommit callback leaves:
- `message.status = 'FAILED'` rows with `answer = null`, `code = '503'`.
- No scheduled poller to retry them (verified — `grep @Scheduled src/main/java/.../schedulejob` finds no message-retry job).
- `MessageService.resendMessage:132` exists but requires an admin to click a button per message.

This is **acceptable** for a well-monitored OMS but not a "once-for-all" solution. A crash between DB commit and afterCommit invocation leaves an even worse gap: WMS is committed, no `Message` row at all, no signal to operators that OMS missed the notification.

The durable-delivery fix is the **transactional outbox pattern** — scoped as F8 (optional Phase 2 follow-up).

---

### Affected Locations

| # | File | Line(s) | Description | Fix |
|---|------|---------|-------------|-----|
| 1 | `service/CustomerorderBatchService.java` | 620-622 | Three synchronous OMS POSTs inside TX | F1 |
| 2 | `service/CustomerorderBatchService.java` | 547-557 | Insert parcel-label collision guard before Phase 2 | F2 |
| 3 | `service/CustomerorderBatchService.java` | 445, 464, 571, 588 | Unsafe `.orElse(null)` patterns | F3 |
| 4 | `service/CustomerorderBatchService.java` | 544 | Promote Phase 1 staging-lane scan to pessimistic lock | F4 |
| 5 | `service/CustomerorderBatchService.java` | 540, 612 | Enrich guard / insufficient-stock messages | F5 |
| 6 | `service/ManageOrderService.java` | 283-344 | Split Club-branch UUID write from HTTP POST | F1 prerequisite |
| 7 | `service/CustomerorderBatchService.java` | 517-527 | Batch lookup + state guard under pessimistic lock | F6 |
| 8 | `repo/jpa/CustomerorderBatchRepository.java` | (new method) | Add `findByIdForUpdate` | F6 |
| 9 | `service/CustomerorderBatchService.java` | 422-493, 539-545 | Refactor `isEnoughStockOnStagingLane` to return `(boolean, Map)`; remove Phase 2 rescan | F7 |
| 10 | `repo/jpa/UnitloadRepository.java` | (new method) | Add `findByStoragelocationIdForUpdate` | F4 |
| 11 | (follow-up) `model/Message.java`, poller, schema migration | | Outbox pattern | F8 (Phase 2, separate PR) |

---

## 3. Design / Proposed Fix

Eight discrete fixes. Urgency tiers in §5 below.

### 3.1 F1 — Move OMS POSTs to `afterCommit`, split UUID write from HTTP (P0)

**Problem:** OMS is notified before the WMS transaction commits; a post-POST rollback or retry duplicates OMS traffic.

**Prerequisite — Split `ManageOrderService.customerOrderPicked`:**

The Club-only UUID-write side-effect (`ManageOrderService.java:299-302`) must stay in the transaction so the `historytote` UUID is durable. The HTTP POST must move out.

```java
// ManageOrderService.java — NEW method (transactional caller responsible)
/** Assigns historytote UUIDs for CLUB orders and persists them. Safe to call
    inside a transaction. Does NOT contact OMS. Idempotent. */
public void assignClubHistoryTotes(List<Customerorder> customerOrderList) throws BusinessException {
    if (customerOrderList.isEmpty()) return;

    Customerorder representative = customerOrderList.get(0);
    CustomerorderBatch orderBatch = customerorderBatchRepository.findById(representative.getOrderbatchId())
        .orElseThrow(() -> new BusinessException("Order batch not found: " + representative.getOrderbatchId()));

    if (!WmsConstants.OrderBatchType.CLUB.equals(orderBatch.getType())) return;

    for (Customerorder customerOrder : customerOrderList) {
        if (Integer.valueOf(WmsConstants.State.CANCELED).equals(customerOrder.getState())) continue;
        if (customerOrder.getHistorytote() == null) {               // idempotent under retry
            customerOrder.setHistorytote(String.valueOf(UUID.randomUUID()));
            customerorderRepository.save(customerOrder);
        }
    }
}

// ManageOrderService.java — MODIFIED: remove the UUID write, read the persisted value
public void customerOrderPicked(List<Customerorder> customerOrderList) throws BusinessException {
    // ... existing header (removeIf CANCELED, empty check, representative, isClub flag) ...
    customerOrderList.forEach(customerOrder -> {
        OrderDto orderDto = addOrderToOrderBatch(customerOrder, orderBatchDto);
        if (isClub) {
            orderDto.setToteLabel(customerOrder.getHistorytote());   // read persisted UUID
        } else if (customerOrder.getPickingtoteId() != null) {
            // ... unchanged pick-pack branch ...
        }
    });
    // ... existing try/catch around httpRestService.post(...) ...
}
```

**`runClubLine` change** — replace lines 619-622:

```java
LOG.debug("assigning club history totes (transactional)");
manageOrderService.assignClubHistoryTotes(orders);

final List<Customerorder> omsOrders = new ArrayList<>(orders);
final String batchIdForLog = orderBatch.getBatchid();
if (TransactionSynchronizationManager.isSynchronizationActive()) {
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() {
        @Override public void afterCommit() {
            try { manageOrderService.customerOrderReleaseForPicking(omsOrders); }
            catch (Exception e) { LOG.error("OMS releaseForPicking callback failed for batch " + batchIdForLog, e); }
            try { manageOrderService.customerOrderPickingStarted(omsOrders); }
            catch (Exception e) { LOG.error("OMS pickingStarted callback failed for batch " + batchIdForLog, e); }
            try { manageOrderService.customerOrderPicked(omsOrders); }
            catch (Exception e) { LOG.error("OMS picked callback failed for batch " + batchIdForLog, e); }
        }
    });
} else {
    LOG.warn("runClubLine: no transaction synchronization active — falling back to synchronous OMS calls");
    manageOrderService.customerOrderReleaseForPicking(omsOrders);
    manageOrderService.customerOrderPickingStarted(omsOrders);
    manageOrderService.customerOrderPicked(omsOrders);
}
```

**Pattern source:** `PickingorderBusinessService.finishPickingOrder:150-169` (already in production).

**Consequences after F1:**

| Pre-fix failure | Post-fix behavior |
|---|---|
| `ProcessingException` from OMS timeout mid-TX → rollback after POST | `afterCommit` catches it; TX already committed; only logs |
| `OptimisticLockException` on Phase 4 `customerorderRepository.save` | Retry template re-runs `runClubLine`; OMS not yet contacted; no duplication |
| `DataAccessException` during Phase 4 flush | TX rolls back; `afterCommit` never runs; OMS not notified |
| Caller retries the UI action | OMS sees one set of notifications per committed run; not 5× |

**Retry amplification cap:** 3 POSTs × 1 commit = 3 OMS events maximum per successful run.

**Residual risk addressed by F8:** a crash or OMS outage in the afterCommit window leaves WMS committed with OMS un-notified. `FAILED` Message rows provide a manual re-send queue via the admin UI, but not automatic recovery.

**Files changed:** `service/CustomerorderBatchService.java`, `service/ManageOrderService.java`

---

### 3.2 F2 — Parcel-label collision pre-flight (P0)

**Problem:** `unitloadService.createUnitload` silently returns a pre-existing unitload on matching `labelid`, merging Club run stock into a stale/wrong-location parcel.

**Solution:** guard at the top of Phase 2, after line 557, before the loop at line 559:

```java
for (Customerorder order : orders) {
    String label = order.getParcelexternalnumber();
    if (label == null || label.isEmpty()) {
        throw new BusinessException("Order " + order.getNumber()
                + " has no parcel external number — cannot run club line");
    }
    Optional<Unitload> existing = unitloadRepository.findByLabelid(label);
    if (existing.isPresent()) {
        Unitload ul = existing.get();
        throw new BusinessException("Parcel label collision for order " + order.getNumber()
                + ": unitload id=" + ul.getId()
                + " already exists with labelid=" + label
                + " at storagelocationId=" + ul.getStoragelocationId()
                + ". Manual reconciliation required before rerunning Club.");
    }
}
```

**Files changed:** `service/CustomerorderBatchService.java`

---

### 3.3 F3 — Replace remaining unsafe `.orElse(null)` with `.orElseThrow(BusinessException)` (P1)

**Extended scope (rev 2):** also fix line 445 and line 464 in `isEnoughStockOnStagingLane` (will be refactored under F7; apply the fixes there to avoid merge churn).

**Line 571-574** (in `runClubLine` per-position loop):

```java
Itemdata itemData = itemdataRepository.findById(orderPosition.getItemdataId())
        .orElseThrow(() -> new BusinessException(
                "Itemdata " + orderPosition.getItemdataId()
                + " referenced by orderPosition id=" + orderPosition.getId()
                + " (order " + order.getNumber() + ") not found"));
```

**Line 588** (stale re-read):

```java
Stockunit stockUnitUpdated = stockunitRepository.findById(stockUnit.getId())
        .orElseThrow(() -> new BusinessException(
                "Stock unit " + stockUnit.getId()
                + " disappeared after transferStockToUnitLoad for order "
                + order.getNumber() + " position " + orderPosition.getId()));
```

**Lines 445, 464** (in `isEnoughStockOnStagingLane`, if F7 is deferred): same `orElseThrow(BusinessException)` pattern with the `Itemdata` id.

**Files changed:** `service/CustomerorderBatchService.java`

---

### 3.4 F4 — Pessimistic lock on staging-lane unitloads at Phase 1 (P2)

**Problem:** Phase 1 stock read races with concurrent stock consumers; Phase 2 can abort with "Insufficient stock for position" after partial work.

**New repository method:**

```java
// UnitloadRepository.java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT u FROM Unitload u WHERE u.storagelocationId = :locationId")
List<Unitload> findByStoragelocationIdForUpdate(@Param("locationId") Long locationId);
```

**Usage:** replace the single scan that F7 leaves behind (see §3.7) with the `ForUpdate` variant — Club run is the sole writer on this staging lane, so the lock is safe.

**Do not** relocate the check into a read-only code path. Keep read-only UI callers (`isEnoughStockOnStagingLane` invoked from dashboards) lock-free.

**Trade-off:** Club run holds PESSIMISTIC_WRITE on all lane unitloads for the full duration (typically sub-second). Concurrent mobile pickers on the same lane block, which is the intended semantics.

**Files changed:** `repo/jpa/UnitloadRepository.java`, `service/CustomerorderBatchService.java`

---

### 3.5 F5 — Actionable guard messages (P2)

**Row "Not enough stock on location."** — enrich with per-SKU shortfall. Because F7 promotes `isEnoughStockOnStagingLane` to return structured data, use the same data to format the error:

```java
// After F7, runClubLine has a StockCheckResult { boolean enough; Map<Itemdata, BigDecimal> shortfallBySku; Map<Itemdata, List<Stockunit>> byItem; }
StockCheckResult stockCheck = checkStagingLaneStock(orderBatch);
if (!stockCheck.enough()) {
    String top = stockCheck.shortfallBySku().entrySet().stream().limit(3)
        .map(e -> e.getKey().getItemNr() + " short by " + e.getValue())
        .collect(Collectors.joining("; "));
    throw new BusinessException("Not enough stock on staging lane for batch "
            + orderBatch.getBatchid() + ". Shortfalls: " + top
            + (stockCheck.shortfallBySku().size() > 3
                    ? " and " + (stockCheck.shortfallBySku().size()-3) + " more" : ""));
}
```

**"Mixed stock not allowed on unitLoad=..."** (in `StockunitBusinessService.transferStockToUnitLoad:149`): include existing `Itemdata` on the target and the incoming `Itemdata`.

**Files changed:** `service/CustomerorderBatchService.java`, `service/StockunitBusinessService.java`

---

### 3.6 F6 — Pessimistic batch lock + state re-check under lock (NEW — P0)

**Problem:** concurrent "Run Club" clicks on the same batch race past the state guard; second operator burns ~1.5s of retries before surfacing an `ObjectOptimisticLockingFailureException`.

**New repository method:**

```java
// CustomerorderBatchRepository.java — NEW method, mirrors the pattern used by
// CustomerorderRepository.findByIdForUpdate (line 168).
@org.springframework.data.jpa.repository.Lock(javax.persistence.LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT b FROM CustomerorderBatch b WHERE b.id = :id")
Optional<CustomerorderBatch> findByIdForUpdate(@Param("id") Long id);
```

**`runClubLine` change** — replace the first three lines of the method (517-519):

```java
// BEFORE
CustomerorderBatch orderBatch = customerorderBatchRepository.findById(orderBatchId)
        .orElseThrow(() -> new BusinessException("Order batch not found: " + orderBatchId));
LOG.debug("start runClubLine with orderBatch=" + orderBatch);

// AFTER — acquire row-level lock, THEN re-check state inside the lock
CustomerorderBatch orderBatch = customerorderBatchRepository.findByIdForUpdate(orderBatchId)
        .orElseThrow(() -> new BusinessException("Order batch not found: " + orderBatchId));
LOG.debug("start runClubLine with orderBatch=" + orderBatch + " (row-locked)");

// State guard is evaluated AGAINST the fresh locked row. This is the same guard
// that existed at lines 522-527, now moved down one level so it runs post-lock.
if (orderBatch.getState() != WmsConstants.State.ORDER_BATCH_ACTIVATED
    && orderBatch.getState() != WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED) {
    throw new BusinessException("Cannot run club line on batch in state: " + orderBatch.getState()
            + ". Expected state: ACTIVATED (" + WmsConstants.State.ORDER_BATCH_ACTIVATED
            + ") or STAGING_LANE_ASSIGNED (" + WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED + ")");
}
```

The existing guard at lines 522-527 is now unreachable (same check above) — **delete it**.

**Consequences:**
- Slow operator blocks on the lock; when the fast operator commits, slow operator's `findByIdForUpdate` returns the fresh state (`ORDER_BATCH_CLUB_RUN_FINISHED`) and the state guard throws immediately.
- No wasted Phase 1/2 work.
- No optimistic-lock retry churn.
- Lock held for full `runClubLine` duration; acceptable because Club runs are user-initiated, low-concurrency operations.

**Trade-off:** if the fast operator's TX is long-running (DB unresponsive, replication lag), the slow operator blocks. The lock-wait timeout is inherited from PostgreSQL default (30s); if tuned lower via `statement_timeout`, the slow operator surfaces a `PessimisticLockingFailureException`. Acceptable for an operation expected to complete in sub-second.

**Lock-order audit:** combined with F4 (pessimistic lock on staging-lane unitloads), the acquisition order in `runClubLine` becomes: `CustomerorderBatch` (F6, at line 517) → `Unitload` rows in staging lane (F4, at line 544). Confirm no other code path acquires these in reverse order — grep:

```
grep -rn "findByIdForUpdate\|findByStoragelocationIdForUpdate" src/main/java/
```

Known callers to audit: `CustomerorderService.cancelOrder` (locks Customerorder/Pickingorder but not batch), `MobilePickingService.processPick` (locks Customerorder/Stockunit). Neither acquires `CustomerorderBatch` for update, so deadlock risk is low.

**Files changed:** `repo/jpa/CustomerorderBatchRepository.java`, `service/CustomerorderBatchService.java`

---

### 3.7 F7 — Refactor `isEnoughStockOnStagingLane` to return `(boolean, Map)`; remove Phase 2 re-scan (NEW — P1)

**Problem:** Phase 1 scans the staging lane; Phase 2 scans it again. Double I/O, race window, two separate places for `.orElse(null)` cleanup.

**Solution:** introduce a small value type and one method that returns both the sufficiency flag and the pre-computed item-data map. Keep `isEnoughStockOnStagingLane(CustomerorderBatch)` as a thin read-only adapter for existing UI callers.

```java
// CustomerorderBatchService.java — NEW private class
private static final class StockCheckResult {
    final boolean enough;
    final Map<Itemdata, List<Stockunit>> byItem;
    final Map<Itemdata, BigDecimal> shortfallBySku;  // used by F5
    StockCheckResult(boolean enough, Map<Itemdata, List<Stockunit>> byItem,
                     Map<Itemdata, BigDecimal> shortfallBySku) {
        this.enough = enough; this.byItem = byItem; this.shortfallBySku = shortfallBySku;
    }
}

// NEW internal method — used by runClubLine. All .orElse(null) patterns in the
// current `isEnoughStockOnStagingLane` are converted to .orElseThrow(BusinessException)
// here (F3 extension — covers the old line 445 / 464 sites).
private StockCheckResult checkStagingLaneStock(CustomerorderBatch orderBatch) throws BusinessException {
    // ... port existing body of isEnoughStockOnStagingLane, but:
    //   - every itemdataRepository.findById(...).orElse(null) → .orElseThrow(BusinessException)
    //   - at end, return StockCheckResult(enough, itemDataListMap, shortfallBySku)
    //   - DO NOT call the pessimistic-lock method here; that stays in runClubLine (see below)
}

// EXISTING public method — becomes a thin wrapper so UI callers (read-only dashboards)
// are unaffected.
public boolean isEnoughStockOnStagingLane(CustomerorderBatch orderBatch) throws BusinessException {
    return checkStagingLaneStock(orderBatch).enough;
}
```

**`runClubLine` change** — replace lines 539-545:

```java
// BEFORE
if (!isEnoughStockOnStagingLane(orderBatch)) {
    throw new BusinessException("Not enough stock on location.");
}

Map<Itemdata, List<Stockunit>> itemDataListMap = new HashMap<>();
List<Unitload> ulList = unitloadRepository.findByStoragelocationId(orderBatch.getStaginglaneId());
mapStockUnitsToItemData(ulList, itemDataListMap);

// AFTER
StockCheckResult stockCheck = checkStagingLaneStock(orderBatch);
if (!stockCheck.enough) {
    // F5 — rich message with shortfall detail (see §3.5)
    throw new BusinessException(/* formatted message */);
}
Map<Itemdata, List<Stockunit>> itemDataListMap = stockCheck.byItem;
```

F4's pessimistic lock slots in here by changing the one surviving call to `unitloadRepository.findByStoragelocationId` (inside `checkStagingLaneStock`) to `findByStoragelocationIdForUpdate`. One scan, one lock.

**Files changed:** `service/CustomerorderBatchService.java`

---

### 3.8 F8 — Durable OMS delivery: phased path to "once-for-all" (NEW — P2/P3)

This fix closes the two residual windows F1 cannot:
- **R1:** OMS outage during the afterCommit POST → `FAILED` Message row, no auto-retry.
- **R2:** JVM crash between DB commit and afterCommit execution → no Message row at all, silent loss.

Propose a **two-phase** approach. Phase 2a can land immediately after F1. Phase 2b is a larger structural change scoped as a separate plan.

#### 3.8.a Phase 2a — scheduled re-sender for `FAILED` message rows (medium effort)

Closes R1 (the common case).

Add a `@Scheduled` job that periodically (e.g., every 60s) scans `message WHERE status = 'FAILED' AND (retries IS NULL OR retries < max_retries) AND created >= now() - interval '24 hours'` and invokes `MessageService.resendMessage(msg)` for each. On success, the existing `resendMessage` writes a new SENT row referencing the original via `redeliverId` (already implemented at `MessageService.java:152-153`). On failure, increment `retries` and try again next tick.

Schema prerequisites:
- Add `message.retries INTEGER` column (nullable; default 0).
- Add composite index `message(status, created)` for the polling query.

Flyway migration sketch:

```sql
-- V1.1.06__message_retries.sql
ALTER TABLE message ADD COLUMN retries INTEGER DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_message_status_created ON message(status, created);
```

Backoff: simple linear cap at 5 retries, then flip `status` to a new terminal value (`DLQ` — dead-letter queue) so ops gets a clean list of un-delivered messages via the existing Message admin UI.

**Files added:** `schedulejob/MessageRetryJob.java`, `service/job/MessageRetryJobService.java`, `src/main/resources/db/migration/V1.1.06__message_retries.sql`.

#### 3.8.b Phase 2b — transactional outbox (full structural fix)

Closes R2. Scope as a separate plan (`oms-notification-transactional-outbox.md`); below is the sketch for reference.

Design:
1. **Pre-commit**: inside the TX, replace `httpRestService.post` + `createMessage` with a single `createOutboxRow(PENDING, payload, process, url)`. The OMS call never happens inside a TX at all.
2. **Post-commit**: an `afterCommit` callback wakes the outbox poller (optimistic delivery). A scheduled poller (10s cadence) picks up any `PENDING` row older than 5s and delivers it, moving through `PENDING → IN_FLIGHT → SENT` or `PENDING → FAILED` with retries tracked.
3. **Idempotency**: add `message.idempotency_key` (string, derived from process + entity id + state transition). OMS-side dedupe is the second line of defense; WMS-side dedupe (don't re-POST an `IN_FLIGHT` row until a timeout) is the first.

Benefits over afterCommit:
- Crash between commit and delivery: outbox row is already committed; poller picks it up on restart.
- OMS outage: poller keeps retrying with configurable backoff.
- Observable: queue depth, oldest-pending-age, per-process error rate — all queryable from `message`.

Risks:
- Schema change requires coordination with the admin-UI Message page (row semantics change: `PENDING` and `IN_FLIGHT` are new states).
- Outbox at-least-once delivery requires OMS-side idempotency support — coordinate with the OMS team before committing to this phase.

**Files changed:** new `service/OmsOutboxService.java`, extensions to `model/Message.java`, `repo/jpa/MessageRepository.java`, schema migration, per-site updates replacing `createMessage` + `httpRestService.post` with `omsOutboxService.enqueue(...)`.

---

## 4. V1/V2 Applicability

V1-only plan. A parallel v2 analysis should run after F1/F6 land — v2's `CustomerorderBatchService` has diverged. Use the `wms-v2-migrate` skill when ready to port.

---

## 5. Priority stratification & Rollout Order

Rev-2 re-stratification:

| Tier | Fix | Rationale |
|------|-----|-----------|
| **P0 (before next high-traffic Club run)** | F1 | OMS desync + duplicate-event amplification |
| **P0** | F2 | Only inventory-corruption path |
| **P0** | F6 | Concurrent-run defense; simple repo addition, big UX win |
| **P1 (land in same release cycle)** | F3 | Trivial risk reduction; enables F7 |
| **P1** | F7 | Structural cleanup; enables F4 and F5 |
| **P1** | F5 | QoL on the hot error paths |
| **P2 (next release)** | F4 | Concurrency hardening after F7 isolates the scan |
| **P2** | F8 Phase 2a | Scheduled FAILED re-sender; closes OMS-outage gap |
| **P3 (separate plan)** | F8 Phase 2b | Transactional outbox; closes crash-window gap |

### Rollout order

1. **F3 alone** — pure risk-reduction, zero semantic change, single PR. De-risks merging the structural changes.
2. **F6 + repository addition** — small, well-bounded change. Single PR. Includes new `CustomerorderBatchRepository.findByIdForUpdate`. Run lock-order audit before merging.
3. **F1 + F2 together** — the structural fix and its prerequisite guard. Single PR with the `ManageOrderService.customerOrderPicked` split and `assignClubHistoryTotes`. Deploy behind a reversible release tag. This is the PR that benefits most from a code-reviewer second opinion (not self-review).
4. **F7 + F5** — refactor + cosmetic. One PR.
5. **F4** — after F7 makes the stock scan a single site. Coordinate with teams touching the staging lane (mobile picking, transfer order).
6. **F8 Phase 2a** — separate PR after F1 is stable ≥ 1 release cycle.
7. **F8 Phase 2b** — separate plan + separate PR series. Not in scope of this document.

---

## 6. Testing

### 6.1 Unit tests — `CustomerorderBatchServiceUnitTest`

Existing suite covers happy paths (`runClubLine_validBatch_createsPackagesAndUpdatesState`, `runClubLine_multipleOrders_createsMultiplePackages`, `runClubLine_skipsCancelledOrders_onlyActiveOrdersPacked`, etc.). Add:

- `runClubLine_parcelLabelCollision_throwsBusinessException_beforeAnyWrite` (F2) — mock `unitloadRepository.findByLabelid` to return a pre-existing unitload; assert **zero** `customerorderRepository.save` / `stockunitRepository.save` calls.
- `runClubLine_omsCallsDeferredUntilAfterCommit` (F1) — using Spring's `@Transactional` test support, verify `manageOrderService.customerOrder*` mocks are invoked **after** `customerorderBatchRepository.save(orderBatch)` and **not** invoked when the test rolls back.
- `runClubLine_omsFailurePostCommit_doesNotRollback` (F1) — stub `customerOrderPicked` to throw `RuntimeException`; assert DB state reaches `ORDER_BATCH_CLUB_RUN_FINISHED` and the exception is swallowed + logged.
- `runClubLine_missingItemdata_throwsBusinessExceptionWithId` (F3) — assert message contains both `itemdataId` and owning `orderPosition.id`.
- `runClubLine_historytotePersistedBeforeCommit` (F1) — assert `assignClubHistoryTotes` writes the UUID **before** the TX commits, not inside the deferred callback.
- `runClubLine_historytote_idempotent_onRetry` (F1) — simulate first attempt throwing `OptimisticLockException` after `assignClubHistoryTotes` but before Phase 4; verify second attempt does **not** generate a new UUID.
- `runClubLine_acquiresBatchLockAtEntry` (F6) — verify `customerorderBatchRepository.findByIdForUpdate` is the first call, not `findById`.
- `runClubLine_stateMutatedByConcurrentWriter_throwsAfterLock` (F6) — simulate concurrent writer flipping state to `CLUB_RUN_FINISHED` during the lock wait; assert clean `BusinessException` and zero downstream work.
- `runClubLine_stagingLaneScannedOnce` (F7) — use a spy on `unitloadRepository.findByStoragelocationId*`; assert at most one call.

### 6.2 Integration test — new class `CustomerorderBatchServiceClubRunIT`

Using Testcontainers + a seeded Club batch:

- `clubRun_happyPath_persistsBatchAndFiresThreeOmsPosts`
- `clubRun_phase4RollsBack_omsNotNotified` — inject `@BeforeCommit` hook that throws; assert zero HTTP traffic and zero `Message` rows.
- `clubRun_parcelLabelCollision_zeroStockWrites`
- `clubRun_concurrentInvocationSerializedByLock` (F6) — fork two threads, each calling `runClubLine` on the same batch; assert one succeeds and the other gets `BusinessException("already in CLUB_RUN_FINISHED")`. No duplicate OMS traffic recorded by mock HTTP server.

### 6.3 Existing suites to re-run

- `OptimisticLockRetryTemplateTest`
- `ManageOrderServiceUnitTest` — extend with cases for the split `customerOrderPicked` and the new `assignClubHistoryTotes`.
- `CustomerorderBatchServiceUnitTest` — full existing suite (7 runClubLine tests already present).

### 6.4 Manual QA checklist

- Pre-F1: reproduce in dev by stopping OMS container mid-run (10s after "Run Club" click) — confirm WMS rolls back, OMS has `SENT` records (the bug).
- Post-F1: same repro — confirm WMS rolls back, OMS has **no** records for this batch (fix).
- Post-F1: OMS returns 500 on POST — confirm `FAILED` Message row, WMS committed, batch in `CLUB_RUN_FINISHED` (expected).
- Post-F6: two browser tabs, both click "Run Club" within 1 second — confirm one succeeds, one gets clean error, no duplicate unitload rows.

---

## 7. Production-incident checklist

When a Club run fails in production:

```sql
-- 1. Did any of the three OMS processes go SENT while the batch is still pre-CLUB_RUN_FINISHED?
SELECT m.id, m.process, m.status, m.statuscodeanswer, m.created
FROM   message m
WHERE  m.message LIKE '%<BATCH_ID>%'
  AND  m.process IN ('ORDER_BATCH_PICKING_RELEASED',
                     'ORDER_BATCH_PICKING_STARTED',
                     'ORDER_BATCH_PICKING_FINISHED')
ORDER  BY m.created DESC
LIMIT  20;

-- 2. Is the batch still in a pre-Club-finished state?
SELECT id, batchid, state, version, modified
FROM   customerorder_batch
WHERE  batchid = '<BATCH_ID>';

-- 3. (Post-F6) Did a concurrent run attempt also arrive?
SELECT id, process, status, statuscodeanswer, answer, created
FROM   message
WHERE  message LIKE '%<BATCH_ID>%'
  AND  status = 'FAILED'
  AND  answer LIKE '%already in%CLUB_RUN_FINISHED%'
ORDER  BY created DESC;
```

A `status = 'SENT'` row for any of the three processes with a batch state < `ORDER_BATCH_CLUB_RUN_FINISHED` is direct evidence of the pre-F1 bug. After F1 lands, this combination should be impossible for a non-crash failure. Crash-window recovery is covered by F8.

---

## 8. Open questions

- **`assignClubHistoryTotes` idempotency vs. "fresh UUID on re-run"**: the design no-ops when `historytote` is non-null. Confirm with ops: if a Club batch is legitimately re-run (e.g., after a manual revert), should a fresh UUID be generated? If yes, gate the no-op on `orderBatch.state != CLUB_RUN_FINISHED` rather than UUID presence.
- **Retry cap review post-F1**: with F6 + F1, `OptimisticLockRetryTemplate.DEFAULT_MAX_RETRIES = 5` is almost never useful (the pessimistic batch lock eliminates most optimistic conflicts). Consider lowering to 2 for `runClubLine` specifically — needs a per-call override.
- **F4 deadlock audit**: confirm no other code path acquires `unitload` rows at the Club staging-lane + `customerorder_batch` rows in reverse order. Specifically check `MobilePickingService.processPick`, `TransferOrderService`, `PickingorderBusinessService.confirmPick`. None of these acquire `customerorder_batch` for update today; F6 does not change that.
- **F8 Phase 2a backfill**: any existing long-standing `FAILED` Message rows should be manually reviewed before enabling the retry job — they may correspond to batches that have since been reconciled via other means, in which case re-delivery would cause new desync.
- **F8 Phase 2b OMS-side idempotency**: transactional outbox requires at-least-once delivery. Does OMS dedupe by `idempotency_key` today? If not, coordinate with the OMS team before F8 Phase 2b.
- **Test-suite performance**: the new concurrent-run IT forks threads and needs a genuine DB (Testcontainers). Budget ~20s added to CI.

---

## 9. References

- Reference implementations of the afterCommit pattern (in production today):
  - `PickingorderBusinessService.finishPickingOrder:150-169`
  - `PickingorderBusinessService.confirmPick:344-350`
  - `MobilePickingService.processPick:438-450`
- `OptimisticLockRetryTemplate.java:19-56` — retry template validated (DEFAULT_MAX_RETRIES = 5)
- `CustomerorderBatch.java:51` — `@Version` confirmed (enables optimistic locking but not pessimistic entry)
- Existing `findByIdForUpdate` patterns to mirror for F6:
  - `CustomerorderRepository.java:168`
  - `PickingorderRepository.java:141`
  - `BillofladingRepository.java:83`
  - `StockunitRepository.java:32`
- `MessageService.resendMessage:132` — existing admin-only re-send (basis for F8 Phase 2a)
- `CustomerorderBatchServiceUnitTest` — existing tests preserved; new tests listed in §6.1
- Companion plan: `260424-oms-notification-rollback-risk-remediation.md` — covers all other sites from Audit 1 (§3.2-4.4)
- Follow-up plan (future): `oms-notification-transactional-outbox.md` — F8 Phase 2b structural fix (not yet created)

---

## 10. Implementation status (2026-04-24)

P0 and P1 tiers (F1, F2, F3, F5, F6, F7) implemented on `develop`. F4 and F8 deferred per rollout plan §5.

### Code changes landed

| Fix | Status | Files touched |
|-----|--------|---------------|
| F1 — afterCommit + UUID split | ✅ Implemented | `service/ManageOrderService.java` (added `assignClubHistoryTotes`, read historytote from entity in `customerOrderPicked`), `service/CustomerorderBatchService.java` (afterCommit registration block + sync fallback) |
| F2 — Parcel-label collision guard | ✅ Implemented | `service/CustomerorderBatchService.java` (guard loop after active-orders filter) |
| F3 — `.orElseThrow` cleanup | ✅ Implemented | `service/CustomerorderBatchService.java` (lines covering the former 445, 571, 588 + the redundant line 464 removed via F7) |
| F5 — Actionable error messages | ✅ Implemented | `service/CustomerorderBatchService.java` (shortfall detail in "Not enough stock"), `service/StockunitBusinessService.java` (colliding SKUs in "Mixed stock not allowed") |
| F6 — Pessimistic batch lock | ✅ Implemented | `repo/jpa/CustomerorderBatchRepository.java` (`findByIdForUpdate`), `service/CustomerorderBatchService.java` (entry uses `findByIdForUpdate`, state guard under lock) |
| F7 — Single staging-lane scan | ✅ Implemented | `service/CustomerorderBatchService.java` (`StockCheckResult` private class, `checkStagingLaneStock` method, `isEnoughStockOnStagingLane` as thin wrapper, Phase 2 reuses `byItem` map) |
| F4 — Staging-lane pessimistic lock | ⏸️ Deferred | Per §5 rollout — "after F7 stabilizes, coordinate with teams touching the lane" |
| F8 Phase 2a — FAILED re-sender | ⏸️ Deferred | Per §5 rollout — separate PR after F1 stable ≥ 1 release |
| F8 Phase 2b — Transactional outbox | ⏸️ Deferred | Separate plan `oms-notification-transactional-outbox.md` (not yet created) |

### Test coverage added

New tests in `CustomerorderBatchServiceUnitTest` (8 new, all pass):

- `runClubLine_parcelLabelCollision_throwsBusinessException_beforeAnyWrite` — F2
- `runClubLine_missingItemdata_throwsBusinessExceptionWithPositionId` — F3
- `runClubLine_acquiresBatchLockAtEntry` — F6 (verifies `findByIdForUpdate` invoked, `findById` never)
- `runClubLine_stagingLaneScannedOnce` — F7 (verifies `findByStoragelocationId` called exactly once)
- `runClubLine_notEnoughStock_throwsWithShortfallDetail` — F5
- `runClubLine_omsCallsDeferredUntilAfterCommit` — F1 (uses `TransactionSynchronizationManager.initSynchronization()` to simulate a TX; verifies POSTs are deferred, then fires afterCommit and asserts ordered invocation)
- `runClubLine_omsFailureInAfterCommitCallback_doesNotPreventSubsequentPosts` — F1 robustness (first POST throws, subsequent two still attempt)
- `runClubLine_assignClubHistoryTotesInvokedBeforeOmsPosts` — F1 UUID-before-POST ordering

New tests in `ManageOrderServiceUnitTest` (6 new, all pass; 1 obsolete test removed):

- `assignClubHistoryTotes_emptyList_noop`
- `assignClubHistoryTotes_nullList_noop`
- `assignClubHistoryTotes_freshOrder_writesUuid` (with UUID format assertion)
- `assignClubHistoryTotes_existingHistorytote_isIdempotent` (retry-safety)
- `assignClubHistoryTotes_cancelledOrder_skipped`
- `assignClubHistoryTotes_mixedList_onlyWritesFreshActive`
- `customerOrderPicked_clubBranch_readsHistorytoteFromEntity_doesNotGenerateFresh` — verifies F1 split
- **REMOVED:** `customerOrderPicked_clubBatch_generatesUuidTote` — tested pre-F1 behavior that moved to `assignClubHistoryTotes`; replaced by the above tests

Existing tests updated (stub changes only, no behavior changes):

- 10 runClubLine tests: `customerorderBatchRepository.findById(1L)` → `findByIdForUpdate(1L)` (line-targeted perl substitution)
- 7 successful-path runClubLine tests: added `unitloadRepository.findByLabelid(anyString())` → `Optional.empty()` to pass the new F2 guard

### Test run results

```
CustomerorderBatchServiceUnitTest — Tests run: 62, Failures: 0, Errors: 0 (was 54 pre-impl)
ManageOrderServiceUnitTest       — Tests run: 17, Failures: 0, Errors: 0 (was 12 pre-impl; 1 removed, 6 added)
StockunitServiceUnitTest         — Tests run: 51, Failures: 0, Errors: 0
StockunitBusinessServiceUnitTest — Tests run: 27, Failures: 0, Errors: 0
----------------------------------------------------------------------
Total across relevant suites    — 157 tests, all pass.
```

Full `mvn test` run: **1638 tests, 1635 pass, 3 fail**. The 3 failures (`MobileMoveStockServiceUnitTest.selectDestination_destinationLabelDoesNotMatchPattern_ThrowsBusinessException`, `ViewDtoServiceUnitTest.testGetReplenishOrderViewByKeyword_{Open,Closed}State`) were **verified pre-existing on clean `develop` via `git stash` isolation** — they are unrelated to this plan's scope and will be addressed separately.

### Integration tests (NOT implemented in this pass)

The plan §6.2 calls for `CustomerorderBatchServiceClubRunIT` using Testcontainers to exercise:

- `clubRun_happyPath_persistsBatchAndFiresThreeOmsPosts`
- `clubRun_phase4RollsBack_omsNotNotified`
- `clubRun_parcelLabelCollision_zeroStockWrites`
- `clubRun_concurrentInvocationSerializedByLock` (F6 — requires two JVM threads against Testcontainers PG)

These require a real `@Transactional` boundary + real DB transactions to validate the afterCommit behavior end-to-end. **Status: deferred** — the unit tests above cover the logic via `TransactionSynchronizationManager.initSynchronization()` simulation, which exercises the registration-and-fire path. A separate follow-up ticket should add the full IT suite, particularly the concurrent-invocation test which cannot be simulated at the unit-test level.

### Manual QA

Not yet performed. The plan's §6.4 checklist (stop OMS container mid-run, two-browser-tab concurrent click) requires a staging environment with OMS and WMS both running. **Status: pending QA pass before tagging for release.**

### Risks observed during implementation

1. **Retry-cap nuance (§8 open question — still open):** `OptimisticLockRetryTemplate.DEFAULT_MAX_RETRIES = 5` is now almost never useful for `runClubLine` because F6 serializes at the batch row. Consider lowering to 1-2 in a follow-up to reduce wall-clock under genuine contention. Not in scope for this PR.
2. **`assignClubHistoryTotes` idempotency-by-UUID-presence** was chosen per plan §8; confirm with ops before release. If a legitimate re-run requires fresh UUIDs, the check must be gated on batch state instead.
3. **No F8 means OMS outage still leaves orphan FAILED rows** (no auto-redelivery). This is existing behavior — the change here does not worsen it. F8 Phase 2a is the scheduled follow-up.
4. **Test-file line-number shifts** from the perl-targeted edits: resolved cleanly; all 27 pre-existing `findById(1L)` stubs were individually classified and only the 10 runClubLine-related ones renamed.

### What remains before calling this plan fully done

- [ ] Add the Testcontainers IT (§6.2) — separate ticket
- [ ] Manual QA pass (§6.4)
- [ ] Implement F4 (P2 — after F1/F6 stable ≥ 1 release)
- [ ] Implement F8 Phase 2a (P2 — after F1 stable ≥ 1 release; Flyway migration + scheduled job)
- [ ] Scope F8 Phase 2b into its own plan (`oms-notification-transactional-outbox.md`)
- [ ] Resolve the open `assignClubHistoryTotes` idempotency question with ops
- [ ] Revisit retry cap for runClubLine specifically
