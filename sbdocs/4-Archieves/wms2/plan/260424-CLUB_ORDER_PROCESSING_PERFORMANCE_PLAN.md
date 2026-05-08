# Club Order Processing Performance Improvement Plan

## Executive Summary

The club order processing workflow (`runClubLine()`) generates an estimated **5,000+ database queries** for a typical batch of 50 orders x 6 SKUs. The root cause is cascading N+1 query patterns across nested loops, duplicated stock scans, per-call entity re-fetching in shared service methods, and a correctness bug where three entities used as HashMap keys lack `hashCode()`.

This plan targets a **70-80% query reduction** (down to ~1,000-1,500 queries) across all club processing steps, with fixes organized into 5 phases by priority and dependency.

### Implementation Progress

| Phase | Description | Status | Commit |
|-------|-------------|--------|--------|
| 1 | Entity `hashCode()` — Itemdata, Unitload, CustomerorderBatch | **DONE** | `82adb26` |
| 2 | Eliminate duplicate stock scan in `runClubLine()` | **DONE** | `82adb26` |
| 3 | Batch pre-fetching in `runClubLine()` order loop | **DONE** | `a419a14` |
| 4 | Optimize `transferStockToUnitLoad()` repeated lookups | **DONE** | `589b0ef` |
| 5 | Optimize view endpoints & batch OMS operations | **DONE** | `46392fe` |

### Bug Fixes Discovered During Testing

| Fix | Description | Status | Commit |
|-----|-------------|--------|--------|
| B1 | `StaleObjectStateException` in `activateOrderBatch()` — stale `@Version` after `assignStagingLaneToOrderBatch()` saves the entity in a separate transaction; re-fetch by ID before saving | **DONE** | `073083c` |
| B2 | `parallelStream()` in `calculateUnitLoadAmounts()` breaks multi-tenant routing — `TenantContext` (ThreadLocal) does not propagate to ForkJoinPool worker threads; removed parallel path | **DONE** | `74f3c22` |

---

## Table of Contents

- [Current Architecture](#current-architecture)
- [Performance Bottleneck Analysis](#performance-bottleneck-analysis)
- [Phase 1: Correctness Fix — Entity hashCode()](#phase-1-correctness-fix--entity-hashcode)
- [Phase 2: Eliminate Duplicate Stock Scan in runClubLine()](#phase-2-eliminate-duplicate-stock-scan-in-runclubline)
- [Phase 3: Batch Pre-fetching in runClubLine() Order Loop](#phase-3-batch-pre-fetching-in-runclubline-order-loop)
- [Phase 4: Optimize transferStockToUnitLoad() Repeated Lookups](#phase-4-optimize-transferstockttounitload-repeated-lookups)
- [Phase 5: Optimize View Endpoints](#phase-5-optimize-view-endpoints)
- [Estimated Impact Summary](#estimated-impact-summary)
- [Multi-Threading Considerations](#multi-threading-considerations)
- [Testing Strategy](#testing-strategy)
- [File Reference Index](#file-reference-index)

---

## Current Architecture

### Workflow Steps

| Step | Endpoint | Controller Method | Service Method | Typical Queries |
|------|----------|-------------------|----------------|-----------------|
| View open/active/closed runs | `GET /v3/clubLine/{open,active,closed}ClubRun` | `ClubLineController` | `ViewDtoService.get*ClubRun()` | 1 (efficient) |
| Assign staging lane | `GET /v3/clubLine/assignStagingLane/{batchId}/{locId}` | `ClubLineController:83-107` | `CustomerorderBatchService.assignStagingLaneToOrderBatch()` | ~4 |
| Activate batch | `GET /v3/clubLine/activateBatch/{batchId}/{locId}` | `ClubLineController:133-158` | `CustomerorderBatchService.activateOrderBatch()` | ~7 |
| Get SKU overview | `POST /v3/clubLine/skus` | `ClubLineController:185-195` | `CustomerorderBatchService.getClubLineSKUOverview()` | ~21 (6 SKUs) |
| Get unit loads | `POST /v3/clubLine/unitLoads` | `ClubLineController:197-210` | `CustomerorderBatchService.getClubLineUnitLoads()` | ~371 (6 SKUs, 20 ULs each) |
| **Run club line** | `GET /v3/clubLine/runClubLine/{batchId}` | `ClubLineController:160-183` | **`CustomerorderBatchService.runClubLine()`** | **~5,000+** |
| Finish (OMS notifications) | (inside runClubLine) | — | `ManageOrderService.customerOrder*()` | ~65+ |

### Key Files

| File | Role |
|------|------|
| `controller/ClubLineController.java` | REST endpoints for all club operations |
| `service/CustomerorderBatchService.java` | Primary club business logic (all major methods) |
| `service/StockunitBusinessService.java` | `transferStockToUnitLoad()` — stock movement |
| `service/UnitloadService.java` | `createUnitload()` — package creation |
| `service/ManageOrderService.java` | OMS webhook notifications |
| `service/ViewDtoService.java` | Club run list views |
| `repo/jpa/CustomerorderPositionRepository.java` | Position queries |
| `repo/jpa/StockunitRepository.java` | Stock unit queries |
| `repo/jpa/UnitloadRepository.java` | Unit load queries |
| `model/Itemdata.java` | Entity — missing `hashCode()` |
| `model/Unitload.java` | Entity — missing `hashCode()` |
| `model/CustomerorderBatch.java` | Entity — missing `hashCode()` |

---

## Performance Bottleneck Analysis

### Bottleneck 1: Duplicate Stock Scan (Phase A + B of `runClubLine()`)

**Location:** `CustomerorderBatchService.java:422-442`

**Problem:** `isEnoughStockOnStagingLane()` (line 436) builds an `itemDataListMap` mapping stock units to item data, validates stock sufficiency, then **discards the result**. Lines 440-442 immediately rebuild the exact same map by calling `mapStockUnitsToItemData()` again.

**Impact:** ~80-120 duplicate queries

### Bottleneck 2: N+1 in `mapStockUnitsToItemData()` Recursive Method

**Location:** `CustomerorderBatchService.java:403-420`

**Problem:** For each unit load on the staging lane, individually fetches child unit loads (`findByCarrierunitloadId`), then for each child fetches stock units (`findByUnitloadId`), then for each stock unit fetches item data (`findById`). This is a 3-level nested N+1 pattern.

**Impact:** ~60-100 queries per invocation (called twice — see Bottleneck 1)

### Bottleneck 3: Per-Order Entity Creation in Main Loop

**Location:** `CustomerorderBatchService.java:448-495`

**Problem:** The main order processing loop calls:
- `unitloadService.createUnitload()` per order — which fetches `locationRepository.findByName("Spawn")` every time (line 136 of `UnitloadService.java`), even though it returns the same location
- `customerorderPositionRepository.findByOrderId()` per order — N+1 for positions
- `itemdataRepository.findById()` per position — N+1 within N+1

**Impact:** ~300-500 queries (50 orders x 6 positions x ~1.5 queries per fetch)

### Bottleneck 4: `transferStockToUnitLoad()` Repeated Lookups

**Location:** `StockunitBusinessService.java:163-296`

**Problem:** Called once per order-position combination (50 orders x 6 SKUs = 300 calls). Each call independently fetches:
- `unitloadTypeRepository.findById()` — same type every time for club packages
- `stockunitRepository.findByUnitloadId()` — destination stock, re-fetched every call for the same destination
- `locationRepository.findById()` — source and destination locations, re-fetched each call
- `fixLocationAssignmentRepository.findByAssignedlocationId()` — same location each call
- Multiple `stockunitRepository.findById()` re-fetches of source/destination after save

**Impact:** ~2,000-3,000 queries (the dominant cost — ~10-15 queries per call x 300 calls)

### Bottleneck 5: OMS Notification Redundant Fetches

**Location:** `ManageOrderService.java:277-346`

**Problem:**
- `customerOrderPicked()` (line 287-298) calls `customerorderRepository.save()` inside a `forEach` loop to set `historytote` on each order
- `createOrderBatch()` (line 339-340) re-fetches `customerorderBatchRepository.findById()` and `syspropRepository.findSysvalueBySyskey()` on every webhook call (called 3 times from `runClubLine`)
- The batch entity is already available in the caller

**Impact:** ~65 queries (49 individual saves + 6 redundant re-fetches x 3 calls)

### Bottleneck 6: `calc()` Recursive N+1 in Unit Load View

**Location:** `CustomerorderBatchService.java:799-836`

**Problem:** `calculateUnitLoadAmounts()` calls `calc()` for each unit load, which issues 3 queries per unit load (children, stock units, itemdata batch). For a view with ~120 unit loads across 6 SKUs, this generates ~360 queries.

**Impact:** ~360 queries on the unit load view endpoint

### Bottleneck 7: `getClubLineSKUOverview()` N+1

**Location:** `CustomerorderBatchService.java:838-875`

**Problem:** Loops over positions and calls `itemdataRepository.findById()` + `itemunitRepository.findById()` + optionally `stockunitRepository.getAmountAvailable()` per position.

**Impact:** ~21 queries for 6 SKUs

### Bottleneck 8: Entity `hashCode()` Contract Violation (Correctness)

**Location:** `Itemdata.java:222-226`, `Unitload.java:102-106`, `CustomerorderBatch.java:130-134`

**Problem:** All three entities override `equals()` (based on `getId()`) but do NOT override `hashCode()`. `hashCode()` defaults to `Object.hashCode()` (memory identity). When these entities are used as `HashMap` keys in `isEnoughStockOnStagingLane()` and `mapStockUnitsToItemData()`, two different instances with the same ID hash to different buckets, causing `HashMap.get()` to return `null` even when `.equals()` would return `true`.

**Impact:** Silent stock allocation corruption. If the persistence context evicts and re-loads an entity (which happens with `clear()`, detached entities, or across transaction boundaries), the stock sufficiency check can silently pass with insufficient stock or produce incorrect allocation maps.

---

## Phase 1: Correctness Fix — Entity hashCode()

**Priority:** CRITICAL | **Effort:** Low | **Risk:** Low

### Problem

`Itemdata`, `Unitload`, and `CustomerorderBatch` override `equals()` but not `hashCode()`, violating the Java contract. These entities are used as `HashMap` keys in club processing methods.

### Changes

#### 1.1 Add `hashCode()` to `Itemdata.java`

**File:** `src/main/java/net/aim_ai/wms/model/Itemdata.java` (after line ~226)

```java
@Override
public int hashCode() {
    return getClass().hashCode();
}
```

> **Why `getClass().hashCode()`?** This is the Hibernate-recommended approach for JPA entities. It provides a stable hash code that works correctly with Hibernate proxies, new (unsaved) entities, and entities across different persistence contexts. Using `getId().hashCode()` would break for transient entities (where `id` is `null`) and cause `NullPointerException`.

#### 1.2 Add `hashCode()` to `Unitload.java`

**File:** `src/main/java/net/aim_ai/wms/model/Unitload.java` (after line ~106)

```java
@Override
public int hashCode() {
    return getClass().hashCode();
}
```

#### 1.3 Add `hashCode()` to `CustomerorderBatch.java`

**File:** `src/main/java/net/aim_ai/wms/model/CustomerorderBatch.java` (after line ~134)

```java
@Override
public int hashCode() {
    return getClass().hashCode();
}
```

### Notes

- Using `getClass().hashCode()` means all instances of the same entity class hash to the same bucket. This degrades HashMap to O(n) lookup within that bucket, but for the small collections used in club processing (typically <100 entries), this is negligible
- This is consistent with Vlad Mihalcea's and the Hibernate team's recommendation for JPA entities
- See also: `docs/260424-ENTITY_COMPARISON_FIX_PLAN.md` for the broader entity comparison fix plan

---

## Phase 2: Eliminate Duplicate Stock Scan in runClubLine()

**Priority:** HIGH | **Effort:** Medium | **Risk:** Low | **Estimated Savings:** ~80-120 queries

### Problem

`runClubLine()` calls `isEnoughStockOnStagingLane()` at line 436, which internally builds the full `itemDataListMap` via `mapStockUnitsToItemData()`. This map is used only for validation and then discarded. Lines 440-442 immediately rebuild the same map.

### Changes

#### 2.1 Refactor `isEnoughStockOnStagingLane()` to return both validation result and stock map

**File:** `CustomerorderBatchService.java`

Create a new inner class or record to hold the validation result:

```java
// New: result object to carry both validation and pre-built stock map
private record StockValidationResult(
    boolean sufficient,
    Map<Itemdata, List<Stockunit>> availableStockMap
) {}
```

Refactor `isEnoughStockOnStagingLane()` (lines 332-401) to return `StockValidationResult` instead of `boolean`:

```java
// BEFORE (line 332):
private boolean isEnoughStockOnStagingLane(CustomerorderBatch batch) {

// AFTER:
private StockValidationResult validateStockOnStagingLane(CustomerorderBatch batch) {
    // ... existing validation logic ...
    // At the end, instead of just returning true/false:
    return new StockValidationResult(isEnough, availableItemDataIntegerMap_as_stock_map);
}
```

#### 2.2 Update `runClubLine()` to use the combined result

**File:** `CustomerorderBatchService.java` (lines 436-442)

```java
// BEFORE:
if (!isEnoughStockOnStagingLane(batch)) {
    throw new BusinessException("Not enough stock on staging lane");
}
List<Unitload> unitloadsOnLane = unitloadRepository.findByStoragelocationId(batch.getStagingLaneId());
Map<Itemdata, List<Stockunit>> stockMap = mapStockUnitsToItemData(unitloadsOnLane);

// AFTER:
StockValidationResult stockValidation = validateStockOnStagingLane(batch);
if (!stockValidation.sufficient()) {
    throw new BusinessException("Not enough stock on staging lane");
}
Map<Itemdata, List<Stockunit>> stockMap = stockValidation.availableStockMap();
```

---

## Phase 3: Batch Pre-fetching in runClubLine() Order Loop

**Priority:** HIGH | **Effort:** Medium | **Risk:** Medium | **Estimated Savings:** ~350-550 queries

### Problem

The main loop at lines 448-495 fetches positions per order, itemdata per position, and creates a unit load per order — each with redundant lookups.

### Changes

#### 3.1 Pre-fetch all positions for all orders in one query

**File:** `CustomerorderPositionRepository.java`

Add a new repository method (if `findByOrderBatchId` only returns first order's positions):

```java
@Query(value = "SELECT cp.* FROM customerorder_position cp " +
    "JOIN customerorder co ON cp.order_id = co.id " +
    "WHERE co.orderbatch_id = :batchId", nativeQuery = true)
List<CustomerorderPosition> findAllPositionsByOrderBatchId(@Param("batchId") Long batchId);
```

#### 3.2 Pre-fetch all unique Itemdata in one query

**File:** `CustomerorderBatchService.java` — before the order loop

```java
// Pre-fetch all positions for the batch
List<CustomerorderPosition> allPositions = customerorderPositionRepository.findAllPositionsByOrderBatchId(batch.getId());

// Group positions by order ID
Map<Long, List<CustomerorderPosition>> positionsByOrderId = allPositions.stream()
    .collect(Collectors.groupingBy(CustomerorderPosition::getOrderId));

// Pre-fetch all unique itemdata
Set<Long> itemdataIds = allPositions.stream()
    .map(CustomerorderPosition::getItemdataId)
    .collect(Collectors.toSet());
Map<Long, Itemdata> itemdataMap = itemdataRepository.findAllById(itemdataIds).stream()
    .collect(Collectors.toMap(Itemdata::getId, Function.identity()));
```

#### 3.3 Pre-fetch Spawn location once before the loop

**File:** `CustomerorderBatchService.java` — before the order loop

```java
// Pre-fetch spawn location once (currently fetched 50 times inside createUnitload)
Location spawnLocation = locationRepository.findByName("Spawn");
```

Then use the overloaded `createUnitload(label, type, spawnLocation)` at `UnitloadService.java:149` instead of the version at line 123 that re-fetches Spawn every call.

#### 3.4 Update the order loop to use pre-fetched data

**File:** `CustomerorderBatchService.java` (lines 448-495)

```java
for (Customerorder order : orders) {
    // Use pre-fetched spawn location
    Unitload packageUl = unitloadService.createUnitload(order.getOrderNumber(), packageType, spawnLocation);

    order.setUnitloadId(packageUl.getId());
    customerorderRepository.save(order);

    // Use pre-fetched positions instead of per-order query
    List<CustomerorderPosition> positions = positionsByOrderId.getOrDefault(order.getId(), Collections.emptyList());

    for (CustomerorderPosition pos : positions) {
        // Use pre-fetched itemdata instead of per-position query
        Itemdata itemdata = itemdataMap.get(pos.getItemdataId());

        // ... rest of stock transfer logic
    }
}
```

#### 3.5 Pre-fetch UnitloadType once

**File:** `CustomerorderBatchService.java` — before the order loop

The `unitloadTypeRepository.findByName("Package")` at line 445 is already outside the loop, but `transferStockToUnitLoad()` re-fetches `unitloadTypeRepository.findById()` (line 172 of `StockunitBusinessService.java`) inside each call. Address this in Phase 4.

---

## Phase 4: Optimize transferStockToUnitLoad() Repeated Lookups

**Priority:** HIGH | **Effort:** High | **Risk:** Medium-High | **Estimated Savings:** ~2,000-3,000 queries

### Problem

`transferStockToUnitLoad()` is called ~300 times (50 orders x 6 SKUs). Each call independently fetches:
- Unit load type (same every time)
- Destination stock units (same destination for all positions of one order)
- Source/destination locations (same staging lane each time)
- Fix location assignments (same location each time)

### Approach: Create a Batch-Aware Transfer Context

Rather than modifying the signature of `transferStockToUnitLoad()` (which is used elsewhere), create a new method optimized for batch club processing.

#### 4.1 Create a `ClubTransferContext` helper class

**File:** `CustomerorderBatchService.java` (new inner class)

```java
/**
 * Pre-fetched context for batch stock transfers during club line processing.
 * Eliminates repeated lookups of entities that don't change between transfers.
 */
private static class ClubTransferContext {
    final Location stagingLane;
    final Location packagingLocation;
    final UnitloadType packageType;
    final Map<Long, Itemdata> itemdataMap;
    final Map<Long, List<Stockunit>> stockByItemdataId; // available stock grouped by itemdata

    // Constructor pre-computes all lookups
}
```

#### 4.2 Create `transferStockForClubBatch()` in StockunitBusinessService

**File:** `StockunitBusinessService.java`

```java
/**
 * Batch-optimized stock transfer for club line processing.
 * Accepts pre-fetched entities to avoid repeated lookups.
 *
 * @param sourceStockunit  The stock unit to transfer from
 * @param destinationUl    The destination unit load (package)
 * @param amount           Amount to transfer
 * @param unitloadType     Pre-fetched unit load type
 * @param sourceLocation   Pre-fetched source location
 */
@Transactional(value = "tenantTransactionManager",
    rollbackFor = {BusinessException.class, FacadeException.class})
public Stockunit transferStockForClubBatch(
    Stockunit sourceStockunit,
    Unitload destinationUl,
    BigDecimal amount,
    UnitloadType unitloadType,
    Location sourceLocation
) {
    // Same logic as transferStockToUnitLoad() but uses passed-in entities
    // instead of re-fetching unitloadType, location, etc.
}
```

#### 4.3 Batch pre-fetch stock units on staging lane

**File:** `CustomerorderBatchService.java` — inside `runClubLine()`, after Phase 2's stock map

```java
// Pre-fetch all stock units on all unit loads at the staging lane
// (already available from Phase 2's stockMap)
// Build a mutable queue per itemdata for allocation
Map<Long, Queue<Stockunit>> stockQueueByItemId = new HashMap<>();
for (Map.Entry<Itemdata, List<Stockunit>> entry : stockMap.entrySet()) {
    stockQueueByItemId.put(
        entry.getKey().getId(),
        new LinkedList<>(entry.getValue())
    );
}
```

#### 4.4 Update the inner position loop to use batch transfer

```java
for (CustomerorderPosition pos : positions) {
    Itemdata itemdata = itemdataMap.get(pos.getItemdataId());
    Queue<Stockunit> availableStock = stockQueueByItemId.get(itemdata.getId());

    BigDecimal remaining = pos.getAmount();
    while (remaining.compareTo(BigDecimal.ZERO) > 0 && !availableStock.isEmpty()) {
        Stockunit source = availableStock.peek();
        BigDecimal transferAmt = source.getAmount().min(remaining);

        stockunitBusinessService.transferStockForClubBatch(
            source, packageUl, transferAmt, packageType, stagingLane
        );

        remaining = remaining.subtract(transferAmt);
        if (source.getAmount().compareTo(transferAmt) <= 0) {
            availableStock.poll(); // exhausted, remove from queue
        }
    }
}
```

### Risk Mitigation

- The new `transferStockForClubBatch()` must maintain exact parity with `transferStockToUnitLoad()` for:
  - Stock record creation (`stockrecordService.recordRemoval/recordCreation`)
  - Entity lock checks (`fixLocationAssignmentRepository`)
  - Nirvana cleanup for exhausted stock units
- Unit tests should verify identical outcomes for both methods
- Keep the original `transferStockToUnitLoad()` unchanged for non-club callers

---

## Phase 5: Optimize View Endpoints

**Priority:** MEDIUM | **Effort:** Medium | **Risk:** Low | **Estimated Savings:** ~350-400 queries

### 5.1 Optimize `getClubLineSKUOverview()` N+1

**Location:** `CustomerorderBatchService.java:838-875`

**Current:** Loops over positions, calls `itemdataRepository.findById()` + `itemunitRepository.findById()` + `stockunitRepository.getAmountAvailable()` per position.

**Fix:** Batch-fetch all itemdata and itemunits before the loop.

```java
// Pre-fetch all itemdata and itemunits
Set<Long> itemIds = positions.stream().map(CustomerorderPosition::getItemdataId).collect(Collectors.toSet());
Set<Long> unitIds = positions.stream().map(CustomerorderPosition::getItemunitId).collect(Collectors.toSet());

Map<Long, Itemdata> itemMap = itemdataRepository.findAllById(itemIds).stream()
    .collect(Collectors.toMap(Itemdata::getId, Function.identity()));
Map<Long, Itemunit> unitMap = itemunitRepository.findAllById(unitIds).stream()
    .collect(Collectors.toMap(Itemunit::getId, Function.identity()));

// For available stock, use a single query with IN clause
// New repo method needed:
Map<Long, BigDecimal> availableStockMap = stockunitRepository.getAmountAvailableByItemIds(itemIds, locationName);
```

**New repository method:**

```java
@Query("SELECT su.itemdataId, SUM(su.amount) FROM Stockunit su " +
    "JOIN Unitload ul ON su.unitloadId = ul.id " +
    "JOIN Location loc ON ul.storagelocationId = loc.id " +
    "WHERE su.itemdataId IN :itemIds AND loc.name = :locationName " +
    "GROUP BY su.itemdataId")
List<Object[]> getAmountAvailableByItemIds(@Param("itemIds") Set<Long> itemIds, @Param("locationName") String locationName);
```

**Savings:** 21 queries → 3 queries (for 6 SKUs)

### 5.2 Optimize `calc()` Recursive N+1 in `getClubLineUnitLoads()`

**Location:** `CustomerorderBatchService.java:799-836`

**Current:** `calc()` issues 3 queries per unit load (children, stock units, itemdata).

**Fix:** Batch-fetch before calling `calculateUnitLoadAmounts()`:

```java
// Collect all unit load IDs
Set<Long> allUnitLoadIds = unitLoads.stream().map(Unitload::getId).collect(Collectors.toSet());

// Batch fetch all children
Map<Long, List<Unitload>> childrenByCarrierId = unitloadRepository.findByCarrierunitloadIdIn(allUnitLoadIds)
    .stream().collect(Collectors.groupingBy(Unitload::getCarrierunitloadId));

// Collect child IDs too
Set<Long> allIds = new HashSet<>(allUnitLoadIds);
childrenByCarrierId.values().forEach(children ->
    children.forEach(c -> allIds.add(c.getId())));

// Batch fetch all stock units
Map<Long, List<Stockunit>> stockByUnitloadId = stockunitRepository.findByUnitloadIdIn(allIds)
    .stream().collect(Collectors.groupingBy(Stockunit::getUnitloadId));

// Batch fetch all itemdata
Set<Long> itemIds = stockByUnitloadId.values().stream()
    .flatMap(List::stream)
    .map(Stockunit::getItemdataId)
    .collect(Collectors.toSet());
Map<Long, Itemdata> itemMap = itemdataRepository.findAllById(itemIds).stream()
    .collect(Collectors.toMap(Itemdata::getId, Function.identity()));
```

Then pass these maps to a refactored `calc()` that looks up from maps instead of querying:

```java
private BigDecimal calc(Unitload ul,
    Map<Long, List<Unitload>> childrenByCarrierId,
    Map<Long, List<Stockunit>> stockByUnitloadId,
    Map<Long, Itemdata> itemMap) {
    // Use maps instead of repository calls
}
```

**Savings:** ~360 queries → ~3-5 queries

### 5.3 Optimize `fetchUnitLoads()` Per-Position N+1

**Location:** `CustomerorderBatchService.java:666-698`

**Current:** Loops over positions and issues one unit load query per position.

**Fix:** Collect all unique `itemDataId` values and issue a single query:

```java
// New repo method
@Query(value = "SELECT DISTINCT ul.* FROM unitload ul " +
    "JOIN stockunit su ON su.unitload_id = ul.id " +
    "WHERE su.itemdata_id IN :itemIds " +
    "AND ul.storagelocation_id = :locationId", nativeQuery = true)
List<Unitload> findByItemDataIdsAndLocationId(
    @Param("itemIds") Set<Long> itemIds,
    @Param("locationId") Long locationId);
```

**Savings:** ~6 queries → 1 query (for 6 SKUs)

### 5.4 Batch `customerorderRepository.save()` in `customerOrderPicked()`

**Location:** `ManageOrderService.java:287-298`

**Current:** Calls `save()` per order inside a `forEach` to set `historytote`.

**Fix:**
```java
// BEFORE:
orders.forEach(order -> {
    order.setHistorytote(toteLabel);
    customerorderRepository.save(order);
});

// AFTER:
orders.forEach(order -> order.setHistorytote(toteLabel));
customerorderRepository.saveAll(orders);
```

**Savings:** 49 queries for 50 orders

### 5.5 Pass batch entity to `createOrderBatch()` instead of re-fetching

**Location:** `ManageOrderService.java:336-346`

**Current:** `createOrderBatch()` re-fetches `customerorderBatchRepository.findById()` and `syspropRepository.findSysvalueBySyskey()` on each of its 3 calls from `runClubLine()`.

**Fix:** Refactor to accept pre-fetched parameters:

```java
// BEFORE:
private Object createOrderBatch(List<Customerorder> orders) {
    String warehouseId = syspropRepository.findSysvalueBySyskey("warehouseid");
    CustomerorderBatch batch = customerorderBatchRepository.findById(orders.get(0).getOrderbatchId()).orElseThrow();
    // ...
}

// AFTER:
private Object createOrderBatch(List<Customerorder> orders, CustomerorderBatch batch, String warehouseId) {
    // Use passed-in parameters directly
}
```

**Savings:** ~6 queries (2 per call x 3 calls)

---

## Estimated Impact Summary

| Phase | Description | Before (Queries) | After (Queries) | Savings |
|-------|-------------|-------------------|------------------|---------|
| 1 | Entity `hashCode()` | N/A (correctness) | N/A | Prevents silent data corruption |
| 2 | Eliminate duplicate stock scan | ~160-240 | ~80-120 | **80-120 fewer** |
| 3 | Batch pre-fetch in order loop | ~300-500 | ~5-10 | **~300-500 fewer** |
| 4 | Optimize `transferStockToUnitLoad()` | ~3,000-4,500 | ~600-900 | **~2,000-3,000 fewer** |
| 5.1 | SKU overview N+1 | ~21 | ~3 | **~18 fewer** |
| 5.2 | `calc()` recursive N+1 | ~360 | ~5 | **~355 fewer** |
| 5.3 | `fetchUnitLoads()` per-position | ~6 | ~1 | **~5 fewer** |
| 5.4 | Batch save in `customerOrderPicked()` | ~50 | ~1 | **~49 fewer** |
| 5.5 | Pass batch to `createOrderBatch()` | ~6 | ~0 | **~6 fewer** |
| **TOTAL** | **`runClubLine()` (50 orders x 6 SKUs)** | **~5,000+** | **~1,000-1,500** | **~70-75% reduction** |

---

## Multi-Threading Considerations

### Current Threading Issues

1. **Long-running transaction:** `runClubLine()` runs as a single `@Transactional` method. For 50 orders x 6 SKUs, this holds a database connection and transaction open for the entire duration (~5,000 queries). This blocks other threads trying to access the same tenant database connection pool.

2. **TenantContext thread-local:** The multi-tenant routing uses `TenantContext` (thread-local). Any async or parallel processing must propagate tenant context to child threads. **Bug B2 confirmed this:** `calculateUnitLoadAmounts()` used `parallelStream()` which ran repository calls on ForkJoinPool threads without tenant context, routing to the landlord DB. **Rule: NEVER use `parallelStream()` for code paths that call repositories or depend on TenantContext.**

3. **Stock contention:** Multiple concurrent club runs targeting the same staging lane would race on stock allocation. The current single-threaded sequential approach is actually correct for avoiding double-allocation, but the long transaction increases contention window.

4. **Persistence context bloat:** The single transaction accumulates all managed entities (50 unit loads, 300 stock units, 300 positions, etc.) in the L1 cache, increasing memory pressure and slowing dirty-checking at flush time.

### Recommendations for Multi-Threading

1. **Reduce transaction duration (primary goal):** The optimizations in Phases 2-4 will reduce the total query count by 70-75%, which proportionally reduces the transaction hold time. This is the single most impactful improvement for multi-threaded environments.

2. **Consider periodic flush/clear:** After processing each order (or every N orders), call `entityManager.flush()` + `entityManager.clear()` to limit persistence context size. Note: this invalidates any managed entity references held in local variables — use IDs to re-fetch if needed after clear.

3. **Do NOT parallelize the inner order loop:** Stock allocation must remain sequential to prevent double-allocation of the same stock unit to multiple orders. The correctness guarantee outweighs the parallelism benefit.

4. **Move OMS notifications outside the transaction:** The three `manageOrderService.customerOrder*()` webhook calls (lines 498-500) involve HTTP calls that should not hold the database transaction open. Consider:
   - Using Spring's `@TransactionalEventListener` to fire notifications after commit
   - Or splitting `runClubLine()` into a transactional stock allocation phase and a non-transactional notification phase

5. **Connection pool sizing:** Ensure the tenant connection pool is sized to handle concurrent club runs, picking, and receiving operations. With the query reduction, each club run will hold a connection for significantly less time.

---

## Testing Strategy

### Unit Tests

For each phase, create or update unit tests:

| Phase | Test Class | What to Test |
|-------|------------|--------------|
| 1 | `ItemdataTest`, `UnitloadTest`, `CustomerorderBatchTest` | `hashCode()`/`equals()` contract, HashMap key behavior |
| 2 | `CustomerorderBatchServiceTest` | `validateStockOnStagingLane()` returns both validation + map |
| 3 | `CustomerorderBatchServiceTest` | Pre-fetched data produces same results as per-query |
| 4 | `StockunitBusinessServiceTest` | `transferStockForClubBatch()` matches `transferStockToUnitLoad()` output |
| 5 | `CustomerorderBatchServiceTest` | View methods return identical DTOs with batch-fetched data |

### Integration Tests

- Run full `runClubLine()` end-to-end with TestContainers PostgreSQL
- Enable Hibernate SQL logging (`spring.jpa.show-sql=true`) to count actual queries
- Compare before/after query counts
- Verify stock allocation correctness: total stock in = total stock out

### Regression Safety

- All existing tests must continue to pass after each phase
- Do NOT modify existing `transferStockToUnitLoad()` — create a new method
- Keep original `isEnoughStockOnStagingLane()` as a thin wrapper calling the new method

---

## File Reference Index

| File | Lines | What | Phase |
|------|-------|------|-------|
| `model/Itemdata.java` | 222-226 | `equals()` without `hashCode()` | 1 |
| `model/Unitload.java` | 102-106 | `equals()` without `hashCode()` | 1 |
| `model/CustomerorderBatch.java` | 130-134 | `equals()` without `hashCode()` | 1 |
| `service/CustomerorderBatchService.java` | 332-401 | `isEnoughStockOnStagingLane()` | 2 |
| `service/CustomerorderBatchService.java` | 403-420 | `mapStockUnitsToItemData()` | 2 |
| `service/CustomerorderBatchService.java` | 422-509 | `runClubLine()` main method | 2, 3, 4 |
| `service/CustomerorderBatchService.java` | 436 | Duplicate stock validation call | 2 |
| `service/CustomerorderBatchService.java` | 440-442 | Duplicate stock map rebuild | 2 |
| `service/CustomerorderBatchService.java` | 448-495 | Order processing loop | 3, 4 |
| `service/CustomerorderBatchService.java` | 541-641 | `getClubLineUnitLoads()` | 5.2, 5.3 |
| `service/CustomerorderBatchService.java` | 666-698 | `fetchUnitLoads()` per-position | 5.3 |
| `service/CustomerorderBatchService.java` | 765 | `calculateUnitLoadAmounts()` | 5.2 |
| `service/CustomerorderBatchService.java` | 799-836 | `calc()` recursive N+1 | 5.2 |
| `service/CustomerorderBatchService.java` | 838-875 | `getClubLineSKUOverview()` | 5.1 |
| `service/StockunitBusinessService.java` | 163-296 | `transferStockToUnitLoad()` | 4 |
| `service/UnitloadService.java` | 123-143 | `createUnitload()` Spawn re-fetch | 3.3 |
| `service/UnitloadService.java` | 149 | Overloaded `createUnitload()` with spawnLocation | 3.3 |
| `service/ManageOrderService.java` | 277-334 | `customerOrderPicked()` per-order save | 5.4 |
| `service/ManageOrderService.java` | 336-346 | `createOrderBatch()` redundant re-fetch | 5.5 |
| `repo/jpa/CustomerorderPositionRepository.java` | 69-74 | `findByOrderBatchId` (first order only) | 3.1 |
| `repo/jpa/UnitloadRepository.java` | 120-121 | `findByCarrierunitloadIdIn()` | 5.2 |
| `repo/jpa/StockunitRepository.java` | 190-192 | `findByUnitloadIdIn()` | 5.2 |
| `controller/ClubLineController.java` | 160-183 | `runClubLine` endpoint | all |

---

## Implementation Order

```
Phase 1 (hashCode)  ─── no dependencies, do first
     │
Phase 2 (duplicate scan) ─── foundation for Phase 3/4
     │
Phase 3 (batch pre-fetch) ─── depends on Phase 2's stock map
     │
Phase 4 (transfer optimization) ─── depends on Phase 3's pre-fetched data
     │
Phase 5 (view endpoints) ─── independent, can be done in parallel with 2-4
```

Each phase is independently deployable and testable. Phase 1 should be deployed immediately as it is a correctness fix. Phases 2-4 form a dependency chain for the critical `runClubLine()` path. Phase 5 can be done in parallel with phases 2-4 as it targets different methods.
