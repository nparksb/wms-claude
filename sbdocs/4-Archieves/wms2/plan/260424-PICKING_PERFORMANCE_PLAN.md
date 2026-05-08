# Picking Process Performance Optimization Plan

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current Architecture Overview](#2-current-architecture-overview)
3. [Bottleneck Analysis by Picking Step](#3-bottleneck-analysis-by-picking-step)
4. [Optimization Plan](#4-optimization-plan)
5. [Implementation Phases](#5-implementation-phases)
6. [Risk Assessment](#6-risk-assessment)
7. [Appendix: Query Monitoring Setup](#7-appendix-query-monitoring-setup)

---

## 1. Executive Summary

The picking process (Started → Picked → Packed → Palletized) suffers from severe N+1 query problems, redundant database fetches, individual saves in loops, and a catastrophic sorting comparator that fires DB queries inside `Comparator.compare()`. In a multi-threaded warehouse environment with 10-30 concurrent pickers, these issues compound into database connection pool exhaustion, long transaction hold times, and optimistic locking failures.

### Key Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Order list screen (10 orders, 5 pos each) | ~121 queries | ~1 query |
| Position sort + info (10 positions) | ~380 queries | ~10 queries |
| Single pick confirmation | ~30 queries | ~18 queries |
| Order finish (5 positions, 3 orders) | ~100+ queries | ~15 queries |
| **Estimated overall query reduction** | | **60-80%** |

### Picking Flow Under Concurrency

```
10-30 concurrent pickers, each executing this flow:

  ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
  │  Order Selection │───▶│  Position List +  │───▶│  Confirm Pick   │──┐
  │  (~121 queries)  │    │  Sort (~380 q.)   │    │  (~30 q. each)  │  │
  └─────────────────┘    └──────────────────┘    └─────────────────┘  │
                                                        │ per position │
                                                        ◀─────────────┘
                                                        │ last position
                                                        ▼
                                               ┌─────────────────┐
                                               │  Finish Order   │
                                               │  (~100+ queries)│
                                               └─────────────────┘
```

Each picker holds DB connections during the entire operation. Without `@Transactional` on read methods, every single repository call borrows and returns a connection independently — 20 pickers × 121 queries on the order list screen = 2,420 connection checkouts in seconds.

---

## 2. Current Architecture Overview

### Picking Flow States

```
PROCESSABLE (300) → RESERVED (400) → STARTED (500) → PICKED (600) → PACKED (650) → PALLETIZED → FINISHED (700)
```

### Key Files

| File | Role | Lines |
|------|------|-------|
| `MobilePickingService.java` | Mobile picking workflows, order listing, sorting | 1137 |
| `PickingorderBusinessService.java` | Core business logic: confirmPick, finishPickingOrder | 466 |
| `PickingOrderMergeService.java` | Merges picking orders for cart optimization | 150 |
| `MobilePalletizingService.java` | Palletizing scanned parcels onto pallets | 365 |
| `PickingController.java` | REST endpoints for mobile picking | 326 |
| `PalletizingController.java` | REST endpoints for palletizing | 139 |
| `DefaultStrategy.java` | Location sorting comparator | 95 |

### Dual Transaction Manager Configuration (CRITICAL)

The application has **two transaction managers**:

| Transaction Manager | `@Primary` | DataSource | Used For |
|---------------------|-----------|------------|----------|
| `landlordTransactionManager` | **Yes** | `landlordDataSource` (master DB) | Tenant config lookups only |
| `tenantTransactionManager` | No | `tenantDynamicRoutingDataSource` (routed per tenant) | All warehouse operations |

**CRITICAL:** Because `landlordTransactionManager` is `@Primary`, any `@Transactional` annotation **without** `value = "tenantTransactionManager"` will default to the landlord (master) database — silently using the wrong transaction manager. **Every `@Transactional` on tenant service methods MUST explicitly specify:**
```java
@Transactional(value = "tenantTransactionManager", ...)
```

**Pattern reference:** See `ReceivingService.java` and `BillofladingService.java` for correct usage.

### Repositories (Native Query Heavy)

| Repository | Native Queries | Impact |
|------------|---------------|--------|
| `PickingorderRepository` | 9 native queries | Bypass L1 cache |
| `PickingorderPositionRepository` | 5 native queries | Bypass L1 cache |
| `PickingorderUnitloadRepository` | 1 native query | Bypass L1 cache |

### User-Facing Endpoints (Regular Picking)

| Endpoint | Controller Method | Service Method | Step |
|----------|-------------------|----------------|------|
| `GET /v3/picking/pickingOrders/{section}` | `requpickingOrdersestLocation` | `getPickingOrders()` | Order Selection |
| `GET /v3/picking/pickingOrderPositionsInfo/{id}` | `pickingOrderPositionsInfo` | `getPickingOrderPositionsInfo()` | Position List |
| `GET /v3/picking/processLocation/{id}/{input}` | `processLocation` | `processLocation()` | Location Scan |
| `POST /v3/picking/processPick` | `processPick` | `processPick()` → `confirmPick()` | Pick Confirm |
| `GET /v3/picking/releasePickingOrder/{id}` | `releasePickingOrder` | `releaseRegularPickingOrder()` | Release/Finish |

### User-Facing Endpoints (Rapid Picking)

| Endpoint | Service Method | Step |
|----------|----------------|------|
| `GET /v3/picking/processRapidPickScanPackage/{section}/{input}` | `rapidPickingScanPackage()` | Scan Package |
| `POST /v3/picking/processRapidPickScanSource` | `rapidPickingScanSource()` | Scan Source |
| `POST /v3/picking/processRapidPickScanPackageToVerify` | `rapidPickScanPackageToVerify()` | Verify |
| `POST /v3/picking/resetPickingOrder` | `resetPickingOrder()` | Reset |

---

## 3. Bottleneck Analysis by Picking Step

### 3.1 STARTED Step — Order Selection & Position Loading

#### B1: `getPickingOrders()` — N+1 on order list display
**File:** `MobilePickingService.java:536-545`
**Severity:** HIGH
**Concurrency Impact:** Every picker hitting this endpoint simultaneously

```java
// Current: 1 native query + N × readOrderMap()
List<Pickingorder> pickingOrders = pickingorderRepository.getPickingOrders(...);
pickingOrders.forEach(item -> mapList.add(readOrderMap(item.getId())));
```

`readOrderMap()` → `readOrder()` (line 497-523) does per-order:
- 1 query: `pickingorderRepository.findById()` (redundant — already have the entity)
- 1 query: `findByPickingorderId()` to get positions
- N × 2 queries: for each position, fetches `CustomerorderPosition` + `Customerorder`

**Query count: 1 + N_orders × (2 + N_positions × 2)**
For 10 orders with 5 positions each: **1 + 10 × (2 + 10) = 121 queries**

#### B2: `getPickingOrderPositionsInfo()` — Catastrophic sorting comparator
**File:** `MobilePickingService.java:621-639`
**Severity:** CRITICAL
**Concurrency Impact:** Holds DB connections during O(n log n) sort

```java
poPositions.sort((o1, o2) -> ds.compare(
    locationRepository.findById(
        unitloadRepository.findById(
            stockunitRepository.findById(o1.getPickfromstockunitId())...
        ).get().getStoragelocationId()
    ).get(),
    ...
));
```

The `Comparator.compare()` fires **3 chained DB queries per element per comparison**:
1. `stockunitRepository.findById()`
2. `unitloadRepository.findById()`
3. `locationRepository.findById()`

Then `DefaultStrategy.compare()` (line 38-92) fires **2 more queries per element**:
4. `locationRackRepository.findById()`
5. `locationRackRowRepository.findById()`

**Query count for sorting N positions: O(N log N) × 10 queries**
For 10 positions: ~330 queries just for sorting.

Then the info-building loop (line 642-676) fires per position:
- `itemdataRepository.findById()` — 1 query
- `itemunitRepository.findById()` — 1 query
- `pickingorderUnitloadRepository.findById()` — 1 query
- `unitloadRepository.findById()` — 1 query
- `clientRepository.findById()` — 1 query

**Total for 10 positions: ~330 (sort) + 50 (info) = ~380 queries**

#### B3: `getPickingOrderPositionsInfo()` triggers `startPickingOrder()` as self-call
**File:** `MobilePickingService.java:617-618`
**Severity:** MEDIUM
**Concurrency Impact:** Self-call bypasses Spring `@Transactional` proxy

```java
if (pickingOrder.getState() < WmsConstants.State.STARTED)
    startPickingOrder(pickingOrder);  // self-call — @Transactional on line 267 is IGNORED
```

The self-call to `startPickingOrder()` (line 267) bypasses Spring's AOP proxy. The `@Transactional` annotation on `startPickingOrder()` is not applied. Within `startPickingOrder()`:
- Line 271: `findByPickingorderId()` — runs in auto-commit (redundant, positions fetched again at line 621)
- Line 274: `pickingorderBusinessService.startPickingOrder()` — IS transactional (cross-bean call)
- Line 301: `pickingorderRepository.save()` — runs in auto-commit

This also means `getPickingOrderPositionsInfo()` cannot be marked `@Transactional(readOnly = true)` because it triggers writes.

#### B3b: Triple position fetch within single user flow
**File:** `MobilePickingService.java` lines 335, 271, 621
**Severity:** MEDIUM

When a user selects an order and loads positions, `findByPickingorderId()` is called 3 times:
1. `processPickingOrderForStart()` line 335 — checks if all finished
2. `startPickingOrder()` line 271 — fetches again but result unused for this purpose
3. `getPickingOrderPositionsInfo()` line 621 — fetches for sorting and display

### 3.2 PICKED Step — Confirming Individual Picks

#### B4: `confirmPick()` — Heavy single-pick operation
**File:** `PickingorderBusinessService.java:290-463`
**Severity:** HIGH
**Concurrency Impact:** Multiple pickers confirming picks simultaneously

Per pick confirmation:
- Line 294: `pickingorderPositionRepository.findById()` — refresh
- Line 318: `pickingorderRepository.findById()` — fetch order
- Line 332: `stockunitRepository.findById()` — fetch source stock
- Line 336: `userRepository.findByName()` — fetch user (every single pick!)
- Line 339: `unitloadRepository.findById()` — fetch stock unit's unitload
- Line 341: `unitloadRepository.findById()` — fetch carrier (if pallet)
- Line 344: `unitloadRepository.findById()` — fetch tote unitload
- Line 345: `transferStockToUnitLoad()` — complex operation (~10+ queries internally)
- Line 349: `unitloadRepository.findByCarrierunitloadId()` — check empty carrier
- Line 368-377: Optimistic lock retry loop — re-fetches + saves
- Line 380: `customerorderPositionRepository.findById()` — fetch CO position
- Line 395: `findByCustomerorderpositionId()` — all picking positions for CO pos
- Line 406: `customerorderRepository.findById()` — fetch customer order
- Line 419: `customerorderPositionRepository.findByOrderId()` — all CO positions
- Line 432: `customerorderRepository.findById()` — **re-fetch same customer order!**
- Line 455: `findByPickingorderId()` — all PO positions to check completion

**Query count per single pick: ~25-35 queries**

#### B5: `processPick()` — Tote assignment N+1
**File:** `MobilePickingService.java:367-482`
**Severity:** HIGH (first pick only, but blocks other pickers)

When creating a new tote (first pick, line 446-451):

```java
for (CustomerorderPosition orderPosition : customerorderPositionRepository.findByOrderId(customerOrder.getId())) {
    for (PickingorderPosition pickPos : pickingorderPositionRepository.findByCustomerorderpositionId(orderPosition.getId())) {
        pickPos.setPicktounitloadId(pickingUnitLoad.getId());
        pickingorderPositionRepository.save(pickPos);  // individual save!
    }
}
```

**Query count: 1 + N_coPositions × (1 + N_poPositions × 1 save) = potentially 20+ queries**

#### B6: `finishPickingOrder()` — Triple-nested N+1
**File:** `PickingorderBusinessService.java:129-236`
**Severity:** CRITICAL
**Concurrency Impact:** Called when last pick completes; holds transaction lock

```
For each picking position (line 144):
  → fetch CustomerorderPosition (line 153)        // N+1
  → fetch Customerorder (line 154)                 // N+1
  → check set membership via stream (line 155)     // O(N) per check
  For each unique customer order:
    → fetch all CO positions (line 169)            // N+1
    → fetch picking tote unitload (line 206)
    For each CO position (line 208-225):
      → fetch all PO positions for CO pos (line 210)   // N+1
      For each PO position:
        → fetch PickingorderUnitload (line 214)        // N+1
        → fetch Unitload (line 219)                    // N+1
        → transferUnitLoadToLocation (~290 queries!)   // CRITICAL
        → save PickingorderUnitload (line 222)
```

**Query count: Deeply nested, for 5 positions across 3 orders: 50-100+ queries**
Plus `transferUnitLoadToLocation` which itself generates ~290 queries (shared code).

#### B7: `cleanUpCancelledOrder()` — Individual saves in loop
**File:** `PickingorderBusinessService.java:238-278`
**Severity:** MEDIUM

```java
for (Stockunit stockUnit : stockUnits) {
    stockUnit.setEntityLock(...);
    stockunitRepository.save(stockUnit);  // individual save!
}
coPositions.forEach(position -> {
    position.setState(WmsConstants.State.CANCELED);
    customerorderPositionRepository.save(position);  // individual save!
});
```

### 3.3 PACKED Step — Club Line Packing

#### B8: `CustomerorderBatchService.runClubLine()` — Individual saves
**File:** `CustomerorderBatchService.java:502-514`
**Severity:** MEDIUM

```java
for (Customerorder staleOrder : orders) {
    Customerorder order = customerorderRepository.findById(staleOrder.getId())...;
    order.setState(WmsConstants.State.PACKED);
    customerorderRepository.save(order);                    // individual save
    for (CustomerorderPosition orderPosition : positions) {
        orderPosition.setState(WmsConstants.State.PACKED);
        customerorderPositionRepository.save(orderPosition); // individual save
    }
}
```

### 3.4 PALLETIZED Step

#### B9: `MobilePalletizingService.scanPallet()` — Duplicate BOL queries
**File:** `MobilePalletizingService.java:120-222`
**Severity:** LOW-MEDIUM

- Line 175: `billofladingPositionRepository.getBySourceUnitLoadLabelId(parcel.getLabelid())` — for parcel
- Line 198: `billofladingPositionRepository.getBySourceUnitLoadLabelId(palletLabel)` — for pallet (when pallet exists)
- `syspropRepository.findSysvalueBySyskey()` called multiple times for same keys (lines 153, 181, 182)

### 3.5 Cross-Cutting Concurrency Issues

#### B10: Repeated `userRepository.findByName(SecurityContextUtils.getUserName())` calls
**Files:** Almost every method in MobilePickingService and PickingorderBusinessService
**Severity:** MEDIUM
**Impact:** Same user fetched 3-5 times within a single HTTP request

Locations within the picking flow (within `MobilePickingService`):
- `resumePickingOrderIfExists()` line 160
- `processPickingOrderForStart()` line 309
- `processPick()` line 372
- `getPickingOrders()` line 538
- `verifyPickingOrders()` line 550
- `getPickingOrderPositionsInfo()` line 611
- `rapidPickingScanPackage()` line 764
- `rapidPickingScanPackageAndType()` line 871
- `rapidPickingScanSource()` line 907
- `releasePickingOrder(PickingorderPosition)` line 1047

Within `PickingorderBusinessService`:
- `startPickingOrder()` line 111
- `confirmPick()` line 336

A typical pick flow (select → load positions → confirm pick) fetches the same user **4-5 times**:
1. `processPickingOrderForStart()` → user at line 309
2. `getPickingOrderPositionsInfo()` → user at line 611
3. `startPickingOrder()` → user at line 111 (via PickingorderBusinessService)
4. `processPick()` → user at line 372
5. `confirmPick()` → user at line 336

#### B11: `customerOrderSet` uses `HashSet` but entities have no `equals`/`hashCode`
**File:** `PickingorderBusinessService.java:142, 155`
**Severity:** HIGH
**Impact:** The `.stream().anyMatch(co -> co.getId().equals(...))` on line 155 is O(N) per check, and due to missing `equals`/`hashCode`, duplicate customer orders may be processed.

```java
Set<Customerorder> customerOrderSet = new HashSet<>();
// ...
if (customerOrderSet.stream().anyMatch(co -> co.getId().equals(customerOrder.getId()))) {
    continue;
}
customerOrderSet.add(customerOrder);
```

Should use `Map<Long, Customerorder>` keyed by ID instead.

#### B12: No `@Transactional` on several read-heavy methods
**File:** `MobilePickingService.java`
**Severity:** MEDIUM
**Impact:** Methods like `getPickingOrders()` (line 536), `readOrder()` (line 497), `readOrderMap()` (line 484), `getPickingOrderPositionsInfo()` (line 607) are not marked `@Transactional`, causing each repository call to open/close its own transaction and database connection.

Under 20 concurrent pickers, this creates thousands of short-lived connection checkouts per second, exhausting the connection pool even though actual DB time is low.

#### B13: `PickingOrderMergeService.mergePickingOrders()` — N+1 in batch
**File:** `PickingOrderMergeService.java:56-90`
**Severity:** MEDIUM

```java
for (Pickingorder pickingOrder : pickingOrders) {
    Pickingorder poCurrent = pickingorderRepository.findById(pickingOrder.getId())...; // redundant re-fetch
    List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(...);
    for (PickingorderPosition pickingPosition : poPositions) {
        CustomerorderPosition coPosition = customerorderPositionRepository.findById(...)...; // N+1
        Customerorder customerOrder = customerorderRepository.findById(...)...;              // N+1
    }
}
```

#### B14: `processLocation()` fires 3 chained queries
**File:** `MobilePickingService.java:681-693`
**Severity:** LOW-MEDIUM

```java
Stockunit pickFromStockUnit = stockunitRepository.findById(pickingPosition.getPickfromstockunitId())...;
Unitload unitLoad = unitloadRepository.findById(pickFromStockUnit.getUnitloadId())...;
Location location = locationRepository.findById(unitLoad.getStoragelocationId())...;
```

Could be replaced with a single join query.

#### B15: `releasePickingOrder(Pickingorder)` — Individual saves in loop
**File:** `MobilePickingService.java:224-246`
**Severity:** MEDIUM

```java
for (PickingorderPosition pick : poPositions) {
    // ...
    pick.setState(WmsConstants.State.PROCESSABLE);
    pickingorderPositionRepository.save(pick);  // individual save per position
}
```

#### B16: `rapidPickingScanSource()` — Duplicate stockunit fetch
**File:** `MobilePickingService.java:946, 970`
**Severity:** LOW

```java
List<Stockunit> stockunitList = stockunitRepository.findByUnitloadId(unitLoad.getId());  // line 946
// ... validation ...
Stockunit stockUnit_scanned = stockunitRepository.findByUnitloadId(unitLoad.getId()).get(0);  // line 970 — SAME CALL
```

#### B17: Multiple `finishPickingOrder()` entry points — race condition risk
**File:** `PickingorderBusinessService.java:129`
**Severity:** HIGH (concurrency)

`finishPickingOrder()` is called from **7 different paths**:
1. `MobilePickingService.processPick()` line 469
2. `MobilePickingService.startPickingOrder()` line 291
3. `MobilePickingService.processPickingOrderForStart()` line 343
4. `MobilePickingService.releasePickingOrder(Pickingorder)` line 214
5. `MobilePickingService.releaseRegularPickingOrder()` line 587
6. `MobilePickingService.rapidPickingScanSource()` line 1003
7. `MobilePickingService.rapidPickScanPackageToVerify()` line 1083

Two concurrent pickers finishing their last picks simultaneously could both call `finishPickingOrder()` on the same order. The guard at line 132 (`state >= FINISHED → throw`) helps but there is a TOCTOU window. The `transferUnitLoadToLocation` call (~290 queries) makes this window significant.

---

## 4. Optimization Plan

### OPT-1: Eliminate sorting comparator DB queries (B2) — CRITICAL

**Target:** `MobilePickingService.getPickingOrderPositionsInfo()` lines 621-639

**Problem:** `DefaultStrategy.compare()` fires 5 DB queries per comparison inside `Comparator.compare()`. For N positions, this is O(N log N × 10) queries.

**Solution:** Pre-fetch all location data into in-memory maps before sorting.

```java
// 1. Collect all pickfromstockunit IDs for unpicked positions
List<Long> stockunitIds = poPositions.stream()
    .filter(p -> p.getState() < WmsConstants.State.PICKED && p.getPickfromstockunitId() != null)
    .map(PickingorderPosition::getPickfromstockunitId)
    .toList();

// 2. Bulk fetch chain: stockunits → unitloads → locations → racks → rack rows (5 queries total)
Map<Long, Stockunit> stockunitMap = toMap(stockunitRepository.findAllById(stockunitIds));
Set<Long> unitloadIds = stockunitMap.values().stream().map(Stockunit::getUnitloadId).collect(toSet());
Map<Long, Unitload> unitloadMap = toMap(unitloadRepository.findAllById(unitloadIds));
Set<Long> locationIds = unitloadMap.values().stream().map(Unitload::getStoragelocationId).collect(toSet());
Map<Long, Location> locationMap = toMap(locationRepository.findAllById(locationIds));
Set<Long> rackIds = locationMap.values().stream().map(Location::getRackId).filter(Objects::nonNull).collect(toSet());
Map<Long, LocationRack> rackMap = toMap(locationRackRepository.findAllById(rackIds));
Set<Long> rackRowIds = rackMap.values().stream().map(LocationRack::getRackrowId).filter(Objects::nonNull).collect(toSet());
Map<Long, LocationRackRow> rackRowMap = toMap(locationRackRowRepository.findAllById(rackRowIds));

// 3. Build a pre-resolved location map: positionId → Location
Map<Long, Location> positionLocationMap = new HashMap<>();
for (PickingorderPosition pos : poPositions) {
    if (pos.getState() >= WmsConstants.State.PICKED || pos.getPickfromstockunitId() == null) continue;
    Stockunit su = stockunitMap.get(pos.getPickfromstockunitId());
    if (su == null) continue;
    Unitload ul = unitloadMap.get(su.getUnitloadId());
    if (ul == null) continue;
    positionLocationMap.put(pos.getId(), locationMap.get(ul.getStoragelocationId()));
}

// 4. Sort using in-memory data only
poPositions.sort((o1, o2) -> {
    Location loc1 = positionLocationMap.get(o1.getId());
    Location loc2 = positionLocationMap.get(o2.getId());
    return inMemoryCompare(loc1, loc2, rackMap, rackRowMap);
});
```

**Changes:**
- Create `InMemoryLocationComparator` that accepts pre-loaded rack/rackRow maps
- Bulk pre-fetch in `getPickingOrderPositionsInfo()` before sort

**Query reduction:** ~330 queries → 5 queries (for 10 positions)

### OPT-2: Bulk pre-fetch in `getPickingOrderPositionsInfo()` info loop (B2)

**Target:** `MobilePickingService.java:642-676`

**Problem:** Per-position fetches of itemdata, itemunit, pickingorderUnitload, unitload, client.

**Solution:** Collect all IDs from positions, `findAllById()` in bulk, build maps.

```java
// Collect IDs
Set<Long> itemdataIds = poPositions.stream().map(PickingorderPosition::getItemdataId).collect(toSet());
Set<Long> clientIds = poPositions.stream().map(PickingorderPosition::getClientId).collect(toSet());
Set<Long> picktoUnitloadIds = poPositions.stream()
    .map(PickingorderPosition::getPicktounitloadId).filter(Objects::nonNull).collect(toSet());

// Bulk fetch (3-5 queries instead of N × 5)
Map<Long, Itemdata> itemdataMap = toMap(itemdataRepository.findAllById(itemdataIds));
Map<Long, Client> clientMap = toMap(clientRepository.findAllById(clientIds));
Map<Long, PickingorderUnitload> pulMap = toMap(pickingorderUnitloadRepository.findAllById(picktoUnitloadIds));
// ... derive unitload IDs from pulMap, fetch in bulk too
```

**Query reduction:** 50 queries → 5 queries (for 10 positions)

### OPT-3: Optimize `getPickingOrders()` / `readOrder()` (B1)

**Target:** `MobilePickingService.java:536-545`

**Problem:** For each picking order, `readOrder()` individually fetches positions, then per-position fetches CO position and CO to count distinct customer orders.

**Solution:** Replace with a single native query that returns summary data.

```sql
-- New repository method: getPickingOrderSummaries()
SELECT po.id, po.number, po.created, po.prio,
       COUNT(DISTINCT pop.id) as position_count,
       COUNT(DISTINCT co.id) as parcel_count,
       SUM(CASE WHEN pop.amountpicked = pop.amount THEN 1 ELSE 0 END) as picked_count
FROM pickingorder po
JOIN pickingorder_position pop ON pop.pickingorder_id = po.id
JOIN customerorder_position cop ON pop.customerorderposition_id = cop.id
JOIN customerorder co ON cop.order_id = co.id
LEFT JOIN section s ON po.section_id = s.id
WHERE po.state >= :processable AND po.state < :finished
  AND s.name = :sectionName
  AND ( (po.state = :processable)
     OR (po.state = :started AND po.operator_id = :userId)
     OR (EXISTS(SELECT 1 FROM mywms_user u WHERE u.id = po.operator_id AND u.id = :userId)) )
  AND EXISTS(SELECT 1 FROM pickingorder_position pp WHERE pp.pickingorder_id = po.id)
GROUP BY po.id, po.number, po.created, po.prio
ORDER BY po.state DESC, po.prio DESC, po.created ASC
```

Return a projection interface (`PickingOrderSummaryView`) instead of entity + N queries.

**Query reduction:** 121 queries → 1 query (for 10 orders with 5 positions)

### OPT-4: Optimize `confirmPick()` (B4)

**Target:** `PickingorderBusinessService.java:290-463`

**Optimizations:**

1. **Accept user as parameter** — Remove `userRepository.findByName()` at line 336. Caller (`processPick`) already fetched the user at line 372. Pass it through. Saves 1 query per pick.

2. **Remove redundant customer order re-fetch** — Line 432 re-fetches the same customer order just fetched on line 406:
   ```java
   // Line 406: already fetched
   Customerorder customerOrder = customerorderRepository.findById(coPositionOrderId)...;
   // Line 432: redundant re-fetch of same entity
   Customerorder freshOrder = customerorderRepository.findById(customerOrder.getId())...;
   ```
   Use `entityManager.refresh(customerOrder)` if freshness is needed, or just use the same reference.

3. **Replace completion check with count query** — Lines 455-460 fetch all PO positions to check if all are PICKED. Instead, use a count query:
   ```java
   // Replace findByPickingorderId + stream check with:
   long unpickedCount = pickingorderPositionRepository.countByPickingorderIdAndStateLessThan(
       pickingOrder.getId(), WmsConstants.State.PICKED);
   if (unpickedCount == 0 && pickingOrder.getState() < WmsConstants.State.PICKED) { ... }
   ```
   **Important:** Add `entityManager.flush()` before the count query to ensure the just-saved PICKED state (from the optimistic lock retry at lines 368-377) is visible to the count query.

**Query reduction per pick: ~30 queries → ~18 queries**

### OPT-5: Optimize `finishPickingOrder()` (B6)

**Target:** `PickingorderBusinessService.java:129-236`

**Problem:** Triple-nested N+1 with per-entity fetches and `transferUnitLoadToLocation` calls.

**Solution:**

1. **Bulk pre-fetch all related data upfront:**
   ```java
   List<PickingorderPosition> pickingPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());

   // Collect all CO position IDs and bulk fetch
   Set<Long> coPositionIds = pickingPositions.stream()
       .map(PickingorderPosition::getCustomerorderpositionId).collect(toSet());
   Map<Long, CustomerorderPosition> coPositionMap = toMap(customerorderPositionRepository.findAllById(coPositionIds));

   // Collect all CO IDs and bulk fetch
   Set<Long> coIds = coPositionMap.values().stream()
       .map(CustomerorderPosition::getOrderId).collect(toSet());
   Map<Long, Customerorder> customerOrderMap = toMap(customerorderRepository.findAllById(coIds));
   ```

2. **Replace `HashSet<Customerorder>` with `Map<Long, Customerorder>`** (B11):
   ```java
   Map<Long, Customerorder> processedOrders = new HashMap<>();
   // ...
   if (processedOrders.containsKey(customerOrder.getId())) continue;
   processedOrders.put(customerOrder.getId(), customerOrder);
   ```

3. **Bulk pre-fetch tote data for the finish loop** (lines 208-225):
   ```java
   // Pre-fetch all picking unitloads and their actual unitloads
   Set<Long> picktoUlIds = pickingPositions.stream()
       .map(PickingorderPosition::getPicktounitloadId).filter(Objects::nonNull).collect(toSet());
   Map<Long, PickingorderUnitload> pulMap = toMap(pickingorderUnitloadRepository.findAllById(picktoUlIds));
   Set<Long> ulIds = pulMap.values().stream()
       .map(PickingorderUnitload::getUnitloadId).filter(Objects::nonNull).collect(toSet());
   Map<Long, Unitload> ulMap = toMap(unitloadRepository.findAllById(ulIds));
   ```

4. **Deduplicate tote transfers** — The inner loop (208-225) may call `transferUnitLoadToLocation` multiple times for the same tote. Track already-transferred totes:
   ```java
   Set<Long> transferredToteIds = new HashSet<>();
   // Inside loop:
   if (!transferredToteIds.add(pickingUnitLoad.getUnitloadId())) continue;
   ```

5. **Batch save `PickingorderUnitload` state updates** after the loop using `saveAll()`.

**Query reduction:** ~100+ queries → ~15 queries (excluding transferUnitLoadToLocation)

### OPT-6: Optimize `processPick()` tote assignment (B5)

**Target:** `MobilePickingService.java:446-451`

**Problem:** Double-nested loop with individual saves when assigning tote to all positions of a customer order.

**Solution:** Use bulk JPQL UPDATE:

```java
// Replace the double loop with a single JPQL update
@Modifying
@Query("UPDATE PickingorderPosition p SET p.picktounitloadId = :unitloadId " +
       "WHERE p.customerorderpositionId IN " +
       "(SELECT cop.id FROM CustomerorderPosition cop WHERE cop.orderId = :orderId)")
void assignToteToAllPositions(@Param("unitloadId") Long unitloadId, @Param("orderId") Long orderId);
```

**Important:** Add `entityManager.flush()` + `clear()` after the bulk JPQL UPDATE to avoid stale persistence context.

**Query reduction:** ~20 queries → 1 query

### OPT-7: Cache repeated lookups within request scope (B10)

**Target:** All services in the picking flow

**Problem:** `userRepository.findByName(SecurityContextUtils.getUserName())` is called 3-5 times per HTTP request across services.

**Solution:** Pass the `User` object through the call chain instead of re-fetching:
- `processPick()` fetches user → passes to `confirmPick()`
- `confirmPick()` uses passed user instead of re-fetching
- `startPickingOrder()` accepts optional User parameter

Similarly for frequently re-fetched entities:
- `locationRepository.findByName(STORAGE_LOCATION_FINISHED_PICKING)` — fetch once, pass through
- `locationRepository.findByName(STORAGE_LOCATION_EMPTY_TOTES)` — fetch once, pass through

**Query reduction:** 4-8 queries per request

### OPT-8: Add `@Transactional` to service methods with `tenantTransactionManager` (B12)

**Target:** `MobilePickingService` methods — both read-only and read-write

**Problem:** `getPickingOrders()`, `readOrder()`, `readOrderMap()` lack `@Transactional`, so each repository call gets its own short-lived transaction/connection. Additionally, any `@Transactional` without explicit `value = "tenantTransactionManager"` defaults to `landlordTransactionManager` (which is `@Primary`), silently using the wrong database.

**Solution — read methods:**
```java
@Transactional(value = "tenantTransactionManager", readOnly = true)
public List<Map<String,String>> getPickingOrders(String section) { ... }
```

**Solution — write methods:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public List<Map<String,Object>> getPickingOrderPositionsInfo(long pickingOrderID) { ... }
```

**CAUTION:** `getPickingOrderPositionsInfo()` MUST use writable `@Transactional` (not readOnly) because it calls `startPickingOrder()` which does writes.

**CRITICAL:** ALL `@Transactional` annotations in ALL phases of this plan MUST specify `value = "tenantTransactionManager"`. Omitting this silently routes to the landlord (master) database. See "Dual Transaction Manager Configuration" in Section 2.

**Impact:** Shares a single DB connection across all repository calls within the method; enables Hibernate L1 cache to work properly within the method.

### OPT-9: Optimize `mergePickingOrders()` (B13)

**Target:** `PickingOrderMergeService.java:56-90`

**Solution:**

1. **Remove redundant re-fetch** (line 58): `pickingorderRepository.findById(pickingOrder.getId())` when the entity is already in the list.

2. **Bulk pre-fetch all positions and CO data:**
   ```java
   // Fetch all positions for all picking orders at once
   List<Long> allPoIds = pickingOrders.stream().map(Pickingorder::getId).toList();
   // Add new repo method: findByPickingorderIdIn(List<Long> ids)
   Map<Long, List<PickingorderPosition>> positionsByOrder = ...;

   // Bulk fetch all CO positions and COs
   Set<Long> coPositionIds = allPositions.stream()
       .map(PickingorderPosition::getCustomerorderpositionId).collect(toSet());
   Map<Long, CustomerorderPosition> coPosMap = toMap(customerorderPositionRepository.findAllById(coPositionIds));
   ```

3. **Batch save** position reassignments using `saveAll()` instead of individual saves (line 129).

**Query reduction:** N × (2 + M × 2) → 4 bulk queries

### OPT-10: Optimize Packed step — `runClubLine()` (B8)

**Target:** `CustomerorderBatchService.java:502-514`

**Solution:** Replace individual saves with bulk JPQL UPDATE:

```java
// Instead of loop-save:
@Modifying
@Query("UPDATE Customerorder co SET co.state = :state WHERE co.orderbatchId = :batchId")
void updateStateByBatchId(@Param("state") int state, @Param("batchId") Long batchId);

@Modifying
@Query("UPDATE CustomerorderPosition cop SET cop.state = :state " +
       "WHERE cop.orderId IN (SELECT co.id FROM Customerorder co WHERE co.orderbatchId = :batchId)")
void updatePositionStateByBatchId(@Param("state") int state, @Param("batchId") Long batchId);
```

**Important:** Add `entityManager.flush()` + `clear()` after bulk UPDATEs.

**Query reduction:** N orders × (1 + M positions) → 2 queries

### OPT-11: Add repository helper methods

Add the following methods to support bulk operations:

```java
// PickingorderPositionRepository
List<PickingorderPosition> findByPickingorderIdIn(List<Long> pickingorderIds);
long countByPickingorderIdAndStateLessThan(Long pickingorderId, int state);

// CustomerorderPositionRepository (if not exists)
List<CustomerorderPosition> findByOrderIdIn(Collection<Long> orderIds);
```

### OPT-12: Batch saves in release and cleanup (B7, B15)

**Target:** `PickingorderBusinessService.cleanUpCancelledOrder()` lines 245-258, `MobilePickingService.releasePickingOrder(Pickingorder)` lines 224-246

**Solution:** Replace individual `save()` calls inside loops with `saveAll()`:

```java
// cleanUpCancelledOrder: batch save stockunits
stockUnits.forEach(su -> su.setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED));
stockunitRepository.saveAll(stockUnits);

// cleanUpCancelledOrder: batch save CO positions
coPositions.forEach(position -> position.setState(WmsConstants.State.CANCELED));
customerorderPositionRepository.saveAll(coPositions);

// releasePickingOrder: collect modified positions, batch save
List<PickingorderPosition> modifiedPositions = new ArrayList<>();
for (PickingorderPosition pick : poPositions) {
    // ... state checks ...
    pick.setState(WmsConstants.State.PROCESSABLE);
    modifiedPositions.add(pick);
}
if (!modifiedPositions.isEmpty()) pickingorderPositionRepository.saveAll(modifiedPositions);
```

---

## 5. Implementation Phases

Each phase is designed so that at the end:
1. The application can be deployed locally
2. The specific picking flow covered by that phase can be exercised end-to-end
3. All existing functionality is preserved (performance-only changes)
4. Hibernate statistics can be used to verify query reduction (see [Appendix](#7-appendix-query-monitoring-setup))

### Pre-Implementation: Enable Query Monitoring

Before starting any phase, enable Hibernate statistics to measure before/after query counts.

| Task | File | Details |
|------|------|---------|
| Add Hibernate statistics properties | `application_dev.properties` | See [Appendix](#7-appendix-query-monitoring-setup) |
| Run baseline measurements | — | Record query counts for each endpoint before optimization |

---

### Phase 1: Order List Screen Performance
**Scope:** Read-only operations — the order selection screen
**Risk:** Very Low — purely read operations, no write path changes
**Endpoints tested:** `GET /v3/picking/pickingOrders/{section}`

#### What Changes

| # | Task | File | Lines | OPT |
|---|------|------|-------|-----|
| 1.1 | Create `PickingOrderSummaryView` projection interface | New: `repo/projection/PickingOrderSummaryView.java` | — | OPT-3 |
| 1.2 | Add `getPickingOrderSummaries()` native query | `PickingorderRepository.java` | New method | OPT-3 |
| 1.3 | Replace `getPickingOrders()` + `readOrderMap()` loop with summary query | `MobilePickingService.java` | 536-545 | OPT-3 |
| 1.4 | Add `@Transactional(value = "tenantTransactionManager", readOnly = true)` to `getPickingOrders()` | `MobilePickingService.java` | 536 | OPT-8 |
| 1.5 | Add `@Transactional(value = "tenantTransactionManager", readOnly = true)` to `readOrder()` and `readOrderMap()` | `MobilePickingService.java` | 484, 497 | OPT-8 |
| 1.6 | Fix all existing bare `@Transactional` in `MobilePickingService` to specify `tenantTransactionManager` | `MobilePickingService.java` | all | OPT-8 |

#### What Does NOT Change
- `readOrder()` and `readOrderMap()` remain as-is for any other callers (if any)
- The response format returned to the frontend must be identical: `{ created, parcels, positions, priority, id, group, picked }`
- `verifyPickingOrders()` is already a single query — no change needed

#### Local Testing Checklist

```
1. Deploy locally with Hibernate statistics enabled
2. Open mobile picking UI
3. Navigate to picking section → order list screen
4. Verify:
   [ ] Order list loads and displays correctly
   [ ] Each order shows: created date, parcel count, position count, priority, ID, number, picked count
   [ ] Orders are sorted by state DESC, priority DESC, created ASC
   [ ] Only orders assigned to current user or in PROCESSABLE state appear
   [ ] Hibernate stats show 1-2 queries instead of 100+
5. Test edge cases:
   [ ] Empty order list (no orders in section)
   [ ] Section with orders assigned to different users
   [ ] Orders in various states (PROCESSABLE, STARTED, RESERVED)
```

**Expected query reduction:** ~121 queries → 1-2 queries per order list load

---

### Phase 2: Position List & Sorting Performance
**Scope:** Position loading, location-optimized sorting, position info display
**Risk:** Low-Medium — the `startPickingOrder()` self-call means adding `@Transactional` changes the transactional boundary
**Endpoints tested:** `GET /v3/picking/pickingOrderPositionsInfo/{id}`
**Depends on:** Phase 1 (to test the full select → load flow)

#### What Changes

| # | Task | File | Lines | OPT |
|---|------|------|-------|-----|
| 2.1 | Create `InMemoryLocationComparator` utility class | New: `util/InMemoryLocationComparator.java` | — | OPT-1 |
| 2.2 | Bulk pre-fetch location chain (stockunit → unitload → location → rack → rackrow) | `MobilePickingService.java` | Before line 623 | OPT-1 |
| 2.3 | Replace `DefaultStrategy` sort with `InMemoryLocationComparator` | `MobilePickingService.java` | 623-639 | OPT-1 |
| 2.4 | Bulk pre-fetch info data (itemdata, itemunit, client, pickingUnitload, unitload) | `MobilePickingService.java` | Before line 642 | OPT-2 |
| 2.5 | Replace per-position info fetches with map lookups | `MobilePickingService.java` | 642-676 | OPT-2 |
| 2.6 | Add `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` to `getPickingOrderPositionsInfo()` | `MobilePickingService.java` | 607 | OPT-8 |

#### What Does NOT Change
- `DefaultStrategy.java` remains unchanged (may be used by other callers)
- `startPickingOrder()` method signature and behavior unchanged
- The response format for each position remains identical: `{ id, pickFromLocation, pickFromUnitLoad, pickAmount, pickStatus, skuName, skuNumber, pickUnit, pickToUnitLoad, clientName, clientNumber }`
- Sorting order (rack row → rack → column → level) remains identical

#### Implementation Note: `@Transactional` on `getPickingOrderPositionsInfo()`
This method calls `startPickingOrder()` at line 618, which is a self-call (bypassing Spring proxy). By adding `@Transactional` to `getPickingOrderPositionsInfo()`, all operations — including the writes inside `startPickingOrder()` — will now run within a single transaction. This is actually **better** than the current behavior where writes happen in auto-commit mode without transactional guarantees. The `@Transactional` MUST NOT be `readOnly = true` because of these writes.

#### Local Testing Checklist

```
1. Deploy locally with Hibernate statistics enabled
2. Open mobile picking UI → select a picking order from Phase 1's order list
3. Verify position list screen:
   [ ] All positions display with correct info (SKU, location, amount, status, tote)
   [ ] Positions are sorted by location (rack row → rack → column → level)
   [ ] Already-picked positions sort to the bottom (appear as "Picked")
   [ ] Positions with null pickfromstockunitId sort correctly (no crash)
   [ ] "Scan empty tote" appears for positions without assigned tote
   [ ] Hibernate stats show ~10 queries instead of ~380
4. Test edge cases:
   [ ] Order with only 1 position (no sorting needed)
   [ ] Order with all positions already picked (should redirect/finish)
   [ ] Order in RESERVED state (should auto-start to STARTED)
   [ ] Order with positions across multiple rack rows
   [ ] Order with positions where rack/rackRow is null
```

**Expected query reduction:** ~380 queries → ~10 queries per position list load

---

### Phase 3: Pick Confirmation Performance
**Scope:** The core pick operation — tote scan, pick confirmation, tote assignment
**Risk:** Medium — modifies transactional write path, touches optimistic lock retry
**Endpoints tested:** `POST /v3/picking/processPick`
**Depends on:** Phase 2 (to test select → load → pick flow)

#### What Changes

| # | Task | File | Lines | OPT |
|---|------|------|-------|-----|
| 3.1 | Add `User` parameter to `confirmPick()` signature | `PickingorderBusinessService.java` | 290 | OPT-7 |
| 3.2 | Remove `userRepository.findByName()` in `confirmPick()`, use passed user | `PickingorderBusinessService.java` | 336 | OPT-7 |
| 3.3 | Update `processPick()` to pass user to `confirmPick()` | `MobilePickingService.java` | 466 | OPT-7 |
| 3.4 | Update `rapidPickingScanSource()` to pass user to `confirmPick()` | `MobilePickingService.java` | 989 | OPT-7 |
| 3.5 | Remove redundant customer order re-fetch at line 432 | `PickingorderBusinessService.java` | 432 | OPT-4 |
| 3.6 | Add `countByPickingorderIdAndStateLessThan()` to PickingorderPositionRepository | `PickingorderPositionRepository.java` | New method | OPT-11 |
| 3.7 | Replace completion check (lines 455-460) with count query | `PickingorderBusinessService.java` | 455-460 | OPT-4 |
| 3.8 | Add `entityManager.flush()` before count query | `PickingorderBusinessService.java` | Before 455 | OPT-4 |
| 3.9 | Add `User` parameter to `startPickingOrder()` | `PickingorderBusinessService.java` | 103 | OPT-7 |
| 3.10 | Remove `userRepository.findByName()` in `startPickingOrder()`, use passed user | `PickingorderBusinessService.java` | 111 | OPT-7 |
| 3.11 | Create `assignToteToAllPositions()` JPQL update in PickingorderPositionRepository | `PickingorderPositionRepository.java` | New method | OPT-6 |
| 3.12 | Replace double loop in `processPick()` (lines 446-451) with JPQL update | `MobilePickingService.java` | 446-451 | OPT-6 |
| 3.13 | Add `entityManager.flush()` + `clear()` after JPQL update in `processPick()` | `MobilePickingService.java` | After 451 | OPT-6 |

#### What Does NOT Change
- The external behavior of `confirmPick()` is identical — same state transitions, same entity updates
- The optimistic lock retry mechanism at lines 368-377 remains unchanged
- Customer order state promotion logic (STARTED → PICKED) unchanged
- OMS notifications (`customerOrderPickingStarted`) unchanged
- The `processPick()` endpoint response format unchanged

#### Signature Change Impact
`confirmPick()` gains a `User` parameter. All callers must be updated:
- `MobilePickingService.processPick()` line 466 — already has user at line 372
- `MobilePickingService.rapidPickingScanSource()` line 989 — already has user at line 907
- Check for any other callers via grep

`startPickingOrder()` gains a `User` parameter. All callers must be updated:
- `MobilePickingService.startPickingOrder()` line 274 — caller has user available
- `MobilePickingService.getPickingOrderPositionsInfo()` line 618 — has user at line 611
- Internal calls: `confirmPick()` line 447 — has user parameter

#### Local Testing Checklist

```
1. Deploy locally with Hibernate statistics enabled
2. Open mobile picking UI → select order → view positions → perform picks
3. Test FIRST pick (tote creation):
   [ ] Scan new tote → tote created and assigned correctly
   [ ] All positions for the same customer order get the tote assigned
   [ ] Customer order gets pickingtoteId and historytote set
   [ ] OMS tote assignment notification sent (if production mode)
   [ ] Hibernate stats show reduced queries for tote assignment
4. Test SUBSEQUENT picks:
   [ ] Scan existing tote → pick confirmed correctly
   [ ] Pick amount recorded correctly
   [ ] Customer order position amountpicked updated
   [ ] Customer order position state transitions (STARTED → PICKED)
   [ ] Picking position state set to PICKED
   [ ] Source stock unit correctly split/transferred
   [ ] Hibernate stats show ~18 queries instead of ~30
5. Test LAST pick (order completion trigger):
   [ ] After last pick, picking order state → PICKED
   [ ] finishPickingOrder() is called (verified in next phase)
6. Test edge cases:
   [ ] Pick with wrong tote name → error message
   [ ] Pick on already-picked position → error message
   [ ] Concurrent picks on same order (two browser tabs) → no crash, optimistic lock retry works
   [ ] Tote already belongs to different order → error message
   [ ] Empty carrier pallet sent to nirvana after last pick from it
```

**Expected query reduction per pick:** ~30 queries → ~18 queries

---

### Phase 4: Order Completion & Cleanup Performance
**Scope:** Order finish flow, cancelled order cleanup, order release
**Risk:** Medium-High — complex state transitions, OMS notifications, tote transfers
**Endpoints tested:** `GET /v3/picking/releasePickingOrder/{id}` (also triggered internally after last pick)
**Depends on:** Phase 3 (order completion is triggered by last pick)

#### What Changes

| # | Task | File | Lines | OPT |
|---|------|------|-------|-----|
| 4.1 | Bulk pre-fetch CO positions and orders in `finishPickingOrder()` | `PickingorderBusinessService.java` | 142-160 | OPT-5 |
| 4.2 | Replace `HashSet<Customerorder>` with `Map<Long, Customerorder>` | `PickingorderBusinessService.java` | 142, 155 | OPT-5 |
| 4.3 | Bulk pre-fetch tote data (PickingorderUnitload + Unitload) | `PickingorderBusinessService.java` | 208-225 | OPT-5 |
| 4.4 | Deduplicate tote transfers (track already-transferred totes) | `PickingorderBusinessService.java` | 220 | OPT-5 |
| 4.5 | Batch `saveAll()` for PickingorderUnitload state updates | `PickingorderBusinessService.java` | 222 | OPT-5 |
| 4.6 | Batch `saveAll()` for stockunits in `cleanUpCancelledOrder()` | `PickingorderBusinessService.java` | 245-248 | OPT-12 |
| 4.7 | Batch `saveAll()` for CO positions in `cleanUpCancelledOrder()` | `PickingorderBusinessService.java` | 254-258 | OPT-12 |
| 4.8 | Batch `saveAll()` for positions in `releasePickingOrder(Pickingorder)` | `MobilePickingService.java` | 224-246 | OPT-12 |

#### What Does NOT Change
- Order state transitions (PICKED → FINISHED, or CANCELED)
- OMS notification logic (`customerOrderPicked`) — triggered at same conditions
- `transferUnitLoadToLocation` behavior — still called per unique tote (shared code, not optimized here)
- Cancelled order cleanup flow — same steps, just batched saves
- Release order flow — same state checks, just batched saves

#### Local Testing Checklist

```
1. Deploy locally with Hibernate statistics enabled
2. Complete full pick cycle → verify order finishes:
   [ ] Picking order state → FINISHED after all positions picked
   [ ] Customer order state → PICKED (or PENDING if partial)
   [ ] OMS picking confirmation sent (check logs for "Sending picking confirmation")
   [ ] Totes transferred to FINISHED_PICKING location
   [ ] PickingorderUnitload state → PICKED
   [ ] Hibernate stats show ~15 queries instead of ~100+ for finishPickingOrder
3. Test multi-customer-order scenario:
   [ ] Picking order with positions for CO-A and CO-B
   [ ] CO-A finishes before CO-B → CO-A gets PICKED notification
   [ ] CO-B finishes → CO-B gets PICKED notification
   [ ] No duplicate tote transfers (each tote transferred only once)
4. Test order release:
   [ ] Release partially picked order → error "Finish already started picking order!"
   [ ] Release unpicked order → reset to PROCESSABLE state, operator cleared
   [ ] Release fully picked order → finishes the order
5. Test cancelled order:
   [ ] Order marked for cancellation → cleanup runs
   [ ] Tote sent to clearing
   [ ] Stock units unlocked
   [ ] CO and CO positions set to CANCELED
   [ ] Batch state updated if all orders in batch finished
6. Test edge cases:
   [ ] Concurrent finish (two pickers finish last pick simultaneously) → no duplicate processing
   [ ] Order with all positions CANCELED → state = CANCELED
```

**Expected query reduction:** ~100+ queries → ~15 queries per order finish (excluding transferUnitLoadToLocation)

---

### Phase 5: Merge & Batch Operations Performance
**Scope:** Background merge job and club line batch packing
**Risk:** Low-Medium — batch operations are independently triggered
**Endpoints tested:** Admin batch endpoints, merge triggered via scheduled job
**Depends on:** Phase 4 (merged orders should still complete correctly)

#### What Changes

| # | Task | File | Lines | OPT |
|---|------|------|-------|-----|
| 5.1 | Remove redundant re-fetch in `mergePickingOrders()` | `PickingOrderMergeService.java` | 58 | OPT-9 |
| 5.2 | Add `findByPickingorderIdIn()` to PickingorderPositionRepository | `PickingorderPositionRepository.java` | New method | OPT-11 |
| 5.3 | Bulk pre-fetch all positions for all picking orders | `PickingOrderMergeService.java` | 56-84 | OPT-9 |
| 5.4 | Bulk pre-fetch CO positions and customer orders | `PickingOrderMergeService.java` | 69-71 | OPT-9 |
| 5.5 | Batch `saveAll()` for position reassignment | `PickingOrderMergeService.java` | 126-130 | OPT-9 |
| 5.6 | Replace individual saves in `runClubLine()` status update with bulk JPQL UPDATE | `CustomerorderBatchService.java` | 502-514 | OPT-10 |
| 5.7 | Add `entityManager.flush()` + `clear()` after bulk updates in `runClubLine()` | `CustomerorderBatchService.java` | After 514 | OPT-10 |
| 5.8 | Add bulk update repository methods for Customerorder and CustomerorderPosition | `CustomerorderRepository.java`, `CustomerorderPositionRepository.java` | New methods | OPT-10 |

#### What Does NOT Change
- Merge logic: priority handling, cart capacity, order grouping — all unchanged
- Club line flow: stock transfer, OMS notifications, order state progression — all unchanged
- Only the data access pattern changes (bulk instead of individual)

#### Local Testing Checklist

```
1. Deploy locally with Hibernate statistics enabled
2. Test merge operation:
   [ ] Create multiple small picking orders in the same section
   [ ] Trigger merge (via scheduled job or manual trigger)
   [ ] Verify orders are correctly merged up to boxesPerCart limit
   [ ] Verify positions reassigned to merged orders
   [ ] Verify old orders set to CANCELED, merged orders set to PROCESSABLE
   [ ] Pick a merged order through full cycle → completes correctly
3. Test club line batch:
   [ ] Create a club line order batch
   [ ] Assign staging lane with sufficient stock
   [ ] Run club line operation
   [ ] Verify all orders reach PACKED state
   [ ] Verify all order positions reach PACKED state
   [ ] Verify OMS notifications sent (releaseForPicking, pickingStarted, picked)
   [ ] Verify batch state → ORDER_BATCH_CLUB_RUN_FINISHED
4. Test edge cases:
   [ ] Merge with orders in RESERVED state → skipped correctly
   [ ] Club line with insufficient stock → error thrown, no state changes
```

**Expected query reduction:**
- Merge: N × (2 + M × 2) → 4 bulk queries
- Club line status update: N × (1 + M) → 2 queries

---

### Phase 6: Rapid Picking & Minor Optimizations
**Scope:** Rapid picking flow, processLocation optimization, sysprop caching
**Risk:** Low — similar patterns to phases 1-4, separate user flow
**Endpoints tested:** Rapid picking endpoints (`processRapidPickScanPackage`, `processRapidPickScanSource`, etc.)
**Depends on:** Phase 3 (rapid picking calls `confirmPick()` which was modified)

#### What Changes

| # | Task | File | Lines | OPT |
|---|------|------|-------|-----|
| 6.1 | Remove duplicate `stockunitRepository.findByUnitloadId()` in `rapidPickingScanSource()` | `MobilePickingService.java` | 946, 970 | B16 |
| 6.2 | Add `@Transactional(value = "tenantTransactionManager", readOnly = true)` to `processLocation()` | `MobilePickingService.java` | 681 | OPT-8 |
| 6.3 | Replace 3-query chain in `processLocation()` with single join query or pre-fetched data | `MobilePickingService.java` | 682-688 | B14 |
| 6.4 | Add `@Transactional(value = "tenantTransactionManager", readOnly = true)` to `verifyPickingOrders()` | `MobilePickingService.java` | 547 | OPT-8 |
| 6.5 | Add `@Transactional(value = "tenantTransactionManager", readOnly = true)` to `ProcessRapidPickingScanPackage()` and other read wrappers | `MobilePickingService.java` | 695, etc. | OPT-8 |

#### What Does NOT Change
- Rapid picking flow behavior — same state transitions, same validations
- Error handling and business exceptions — unchanged
- Response formats — unchanged

#### Local Testing Checklist

```
1. Deploy locally with Hibernate statistics enabled
2. Test rapid picking flow:
   [ ] Scan package → position info returned correctly
   [ ] Scan source → pick confirmed, next position returned
   [ ] Verify package → order finishes
   [ ] Scan pass → order released
3. Test location scan:
   [ ] Scan correct location → success
   [ ] Scan wrong location → error "Location not valid"
4. Test edge cases:
   [ ] Package already picked → error message
   [ ] Package belongs to different section → error message
   [ ] Package locked to different operator → error message
```

**Expected query reduction:** 5-10 queries per rapid pick operation

---

### Phase Summary

| Phase | Scope | Risk | Query Reduction | Files Modified | Status | Commit |
|-------|-------|------|----------------|----------------|--------|--------|
| 1 | Order List Screen | Very Low | 121 → 1-2 | 2 files + 1 new | COMPLETE | `19db91b` |
| 2 | Position List & Sort | Low-Medium | 380 → 10 | 2 files + 1 new | COMPLETE | `5468dfc` |
| 3 | Pick Confirmation | Medium | 30 → 18 per pick | 3 files | COMPLETE | `865d36a` |
| 4 | Order Completion | Medium-High | 100+ → 15 per finish | 2 files | COMPLETE | `72f833b` |
| 5 | Merge & Batch | Low-Medium | N×M → 4-6 | 4 files | COMPLETE | `f256f73` |
| 6 | Rapid Picking & Minor | Low | 5-10 per operation | 1-2 files | COMPLETE | `e0c45eb` |

---

## 6. Risk Assessment

### Multi-Threading Concerns

| Risk | Severity | Mitigation |
|------|----------|------------|
| JPQL bulk UPDATE causes stale persistence context | HIGH | Always `entityManager.flush()` + `clear()` after bulk UPDATEs, then re-fetch entities that are used later |
| `saveAll()` may fail partially on optimistic lock conflicts | MEDIUM | Wrap in `OptimisticLockRetry` where needed; existing retry mechanism already handles this pattern |
| Reducing transaction scope may break consistency | MEDIUM | Keep `@Transactional` boundaries identical or expand them (never shrink); only change what happens inside |
| Pre-fetching data that changes during transaction | MEDIUM | Only pre-fetch at the start of a transaction boundary; re-fetch if mutation is expected |
| Native query changes may break existing behavior | LOW | Test with existing integration tests; new native queries should be verified with EXPLAIN ANALYZE |
| Adding `@Transactional` to previously non-transactional methods | MEDIUM | Changes from per-query auto-commit to single transaction. If an error occurs mid-method, all changes now roll back (previously, earlier changes would have committed). This is actually safer but different behavior. |
| Concurrent `finishPickingOrder()` calls on same order | HIGH | The guard at line 132 (`state >= FINISHED → throw`) prevents double-finish, but there is a TOCTOU window. The existing optimistic locking on the Pickingorder entity version column provides the safety net. |
| Connection pool exhaustion during read-heavy polling | HIGH | Phase 1 and 2's `@Transactional` additions will share connections within methods, dramatically reducing checkout pressure. The summary query (OPT-3) reduces from 121 queries to 1, eliminating the connection storm. |

### Per-Phase Risk Summary

| Phase | Risk Level | Key Risk | Rollback Strategy |
|-------|-----------|----------|-------------------|
| 1 | Very Low | Summary query returns wrong data | Revert to original `readOrder()` loop |
| 2 | Low-Medium | `InMemoryLocationComparator` sorts differently than `DefaultStrategy` | Compare sort results side-by-side before removing old code |
| 3 | Medium | `confirmPick()` signature change breaks callers | Overload: keep old signature as wrapper that fetches user internally |
| 4 | Medium-High | `finishPickingOrder()` bulk changes miss edge case | Each bulk pre-fetch can be individually reverted to per-entity fetch |
| 5 | Low-Medium | Merge batch save misassigns positions | Run merge on small test data first, verify position→order mapping |
| 6 | Low | Minor optimizations | Individual reverts |

### Rollback Plan

Each optimization is independently deployable. If issues arise:
1. Each bulk pre-fetch can be reverted to individual fetches
2. JPQL bulk UPDATEs can be reverted to loop-save patterns
3. New repository methods are additive and don't affect existing code
4. `@Transactional` annotations can be removed to restore previous behavior
5. `InMemoryLocationComparator` can be swapped back to `DefaultStrategy`

---

## 7. Appendix: Query Monitoring Setup

### Enable Hibernate Statistics

Add to `application_dev.properties` (or active profile properties):

```properties
# Hibernate query statistics
spring.jpa.properties.hibernate.generate_statistics=true
logging.level.org.hibernate.stat=DEBUG

# Optional: log all SQL queries (verbose, use for debugging)
# logging.level.org.hibernate.SQL=DEBUG
# spring.jpa.properties.hibernate.format_sql=true

# Optional: log query parameters
# logging.level.org.hibernate.orm.jdbc.bind=TRACE
```

### Reading Statistics Per Request

Add a servlet filter or use an existing interceptor to log per-request statistics:

```java
import org.hibernate.SessionFactory;
import org.hibernate.stat.Statistics;

// At the start of request:
Statistics stats = sessionFactory.getStatistics();
stats.clear();

// At the end of request:
LOG.info("Queries executed: {}, time: {}ms",
    stats.getQueryExecutionCount(),
    stats.getQueryExecutionMaxTime());
```

### Baseline Measurements

Before each phase, record the current query count for the affected endpoints:

| Endpoint | Scenario | Queries (Before) | Queries (After) |
|----------|----------|----------------:|----------------:|
| `GET /pickingOrders/{section}` | 10 orders, 5 positions each | _measure_ | _measure_ |
| `GET /pickingOrderPositionsInfo/{id}` | 10 positions | _measure_ | _measure_ |
| `POST /processPick` | First pick (tote creation) | _measure_ | _measure_ |
| `POST /processPick` | Subsequent pick | _measure_ | _measure_ |
| `POST /processPick` | Last pick (triggers finish) | _measure_ | _measure_ |
| `GET /releasePickingOrder/{id}` | Release unpicked order | _measure_ | _measure_ |

---

## Summary Table

| ID | Bottleneck | Phase | Impact | Queries Before | Queries After |
|----|-----------|-------|--------|----------------|---------------|
| OPT-1 | Sorting comparator DB queries | 2 | CRITICAL | ~330 | 5 |
| OPT-2 | Position info loop | 2 | HIGH | ~50 | 5 |
| OPT-3 | Order list N+1 | 1 | HIGH | ~121 | 1 |
| OPT-4 | confirmPick redundancies | 3 | HIGH | ~30 | ~18 |
| OPT-5 | finishPickingOrder N+1 | 4 | CRITICAL | ~100+ | ~15 |
| OPT-6 | Tote assignment loop | 3 | HIGH | ~20 | 1 |
| OPT-7 | Repeated user lookups | 3 | MEDIUM | 4-8/req | 1/req |
| OPT-8 | Missing @Transactional | 1,2,6 | MEDIUM | — | — |
| OPT-9 | Merge service N+1 | 5 | MEDIUM | N×(2+M×2) | 4 |
| OPT-10 | Packing individual saves | 5 | MEDIUM | N×(1+M) | 2 |
| OPT-11 | New repository methods | 3,5 | — | — | — |
| OPT-12 | Cleanup/release batch saves | 4 | MEDIUM | N saves | 1 saveAll |
