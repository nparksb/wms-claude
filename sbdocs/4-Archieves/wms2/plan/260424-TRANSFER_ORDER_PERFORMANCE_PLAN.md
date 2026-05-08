# Transfer Order Processing Performance Improvement Plan

## Executive Summary

The transfer order processing workflow spans two services (`TransferOrderService` and `MobileTransferOrderService`) serving both the web UI and mobile handheld devices. Analysis reveals **severe N+1 query patterns** across all major operations, with the worst offender — `updateOrderPositionPickSources()` — executing **~12N database queries** for N stock units due to triple-nested `findById()` calls inside stream filters.

A typical transfer order with 10 unit loads, 30 stock units, and 6 SKU positions currently generates an estimated **350-500+ queries** across the mobile workflow (order list → position select → transfer). This plan targets a **70-85% query reduction** organized into 6 phases by priority and dependency.

### Implementation Progress

| Phase | Description | Status | Commit |
|-------|-------------|--------|--------|
| 1 | Replace `calculateStockOnStagingLane()` with single native query | **DONE** | `4281dd7` |
| 2 | Batch pre-fetch in `updateOrderPositionPickSources()` | **DONE** | `9af9a61` |
| 3 | Batch pre-fetch in `updateOrderList()` + `updateOrder()` | **DONE** | `af66214` |
| 4 | Optimize `getTransferLineUnitLoads()` + `calc()` | **DONE** | `a849bfa` |
| 5 | Pre-fetch FLA in `BillofladingService.transferOrder()` | **DONE** | `595e764` |
| 6 | Batch pre-fetch in `getSKUOverview()` | **DONE** | `46585aa` |

### Bug Fixes Discovered During Analysis

| Fix | Description | Status | Commit |
|-----|-------------|--------|--------|
| B1 | `itemdata.equals(sku)` in `calculateStockOnStagingLane()` uses broken entity equality — should compare by ID | **DONE** | `4281dd7` |
| B2 | Carrier traversal in `getTransferLineUnitLoads()` calls `findById()` twice on same ID per iteration | **DONE** | `a849bfa` |
| B3 | `updateOrderPositionPickSources()` adds duplicate stock units across 3 filter passes (deep storage, non-flowbin, flowbin) — a stock unit matching multiple filters appears multiple times | **DONE** | `9af9a61` |
| B4 | `AdviceService.close()` / `acceptTransferAdvice()` — bulk JPQL UPDATE with `clearAutomatically=true` evicts un-flushed `Advice` state change; advice stays OPEN instead of FINISHED. Fix: `save()` → `saveAndFlush()` | **DONE** | `5794cd6` |

---

## Table of Contents

- [Current Architecture](#current-architecture)
- [Processing Flow & Query Analysis](#processing-flow--query-analysis)
- [Performance Bottleneck Analysis](#performance-bottleneck-analysis)
- [Phase 1: Replace calculateStockOnStagingLane() with Native Query](#phase-1-replace-calculatestockonstaginglane-with-native-query)
- [Phase 2: Batch Pre-fetch in updateOrderPositionPickSources()](#phase-2-batch-pre-fetch-in-updateorderpositionpicksources)
- [Phase 3: Batch Pre-fetch in updateOrderList() + updateOrder()](#phase-3-batch-pre-fetch-in-updateorderlist--updateorder)
- [Phase 4: Optimize getTransferLineUnitLoads() + calc()](#phase-4-optimize-gettransferlineunitloads--calc)
- [Phase 5: Pre-fetch FLA in BillofladingService.transferOrder()](#phase-5-pre-fetch-fla-in-billofladingservicetransferorder)
- [Phase 6: Batch Pre-fetch in getSKUOverview()](#phase-6-batch-pre-fetch-in-getskuoverview)
- [Multi-Threading Considerations](#multi-threading-considerations)
- [Estimated Impact Summary](#estimated-impact-summary)
- [Testing Strategy](#testing-strategy)
- [File Reference Index](#file-reference-index)

---

## Current Architecture

### Workflow Steps

The transfer order process has two parallel tracks — **Web UI** (warehouse manager) and **Mobile** (handheld device operator):

**Web UI Track (TransfersController — `/v3/transfers/`)**

| Step | Endpoint | Service Method | Typical Queries | Frequency |
|------|----------|----------------|-----------------|-----------|
| 1. View open/active transfers | `GET /v3/transfers/{open,active,closed}Transfer` | `ViewDtoService.get*Transfer()` | 1 (efficient view query) | Per page load |
| 2. Get available lanes | `POST /v3/transfers/availableTransferLanes` | `TransferOrderService.getAvailableTransferLanes()` | 1 | Once per assignment |
| 3. Assign transfer lane | `GET /v3/transfers/assignTransferLane/{orderId}/{locId}` | `TransferOrderService.assignTransferLaneToTransferOrder()` | ~3 | Once per order |
| 4. Activate transfer order | `GET /v3/transfers/activateTransferOrder/{orderId}/{locId}` | `TransferOrderService.activateTransferOrder()` | ~5 | Once per order |
| 5. Get SKU overview | `GET /v3/transfers/skus?orderBatchId=` | `TransferOrderService.getSKUOverview()` | ~2N+2 | Per page load |
| 6. Get unit loads | `POST /v3/transfers/unitLoads` | `TransferOrderService.getTransferLineUnitLoads()` | **~50-200+** | Per page load |
| 7. Run transfer (ship) | `GET /v3/transfers/runTransfer/{orderId}` | `BillofladingService.transferOrder()` | **~50-150** | Once per order |

**Mobile Track (TransferOrderController — `/v3/transferOrder/`)**

| Step | Endpoint | Service Method | Typical Queries | Frequency |
|------|----------|----------------|-----------------|-----------|
| A. Load order list | `GET /v3/transferOrder/orderList` | `MobileTransferOrderService.updateOrderList()` | **~50-300+** | Per screen open |
| B. Select position | `POST /v3/transferOrder/processOrderPositionSelect` | `MobileTransferOrderService.updateOrderPosition()` | **~40-200+** | Per SKU selection |
| C. Scan unit load | `POST /v3/transferOrder/processScanUnitLoad` | `MobileTransferOrderService.validateUnitByUnitLoadInput()` | ~2 | Per scan |
| D. Scan transfer lane | `POST /v3/transferOrder/processScanTransferLane` | `MobileTransferOrderService.transferStock()` | **~30-80** | Per transfer |

### Key Files

| File | Role |
|------|------|
| `controller/TransfersController.java` | Web UI REST endpoints for transfer management |
| `controller/mobile/TransferOrderController.java` | Mobile handheld REST endpoints |
| `service/TransferOrderService.java` | Transfer lane assignment, SKU overview, unit load views |
| `service/mobile/MobileTransferOrderService.java` | Mobile order list, position selection, stock transfer |
| `service/BillofladingService.java` | `transferOrder()` — final stock consolidation and shipping |
| `service/StockunitBusinessService.java` | `transferStockToUnitLoad()` — stock movement (already optimized) |
| `service/UnitloadBusinessService.java` | `transferUnitLoadToLocation()` — unit load movement |
| `repo/jpa/StockunitRepository.java` | Stock unit queries (42 methods, 16 native) |
| `repo/jpa/UnitloadRepository.java` | Unit load queries (18 methods, 8 native) |
| `repo/jpa/LocationRepository.java` | Location queries |
| `repo/jpa/FixLocationAssignmentRepository.java` | Fixed location assignment queries |

---

## Processing Flow & Query Analysis

### Mobile Transfer Flow (Critical Path)

The mobile handheld flow is the most performance-sensitive because warehouse operators use it repeatedly throughout the day. A single transfer cycle involves:

```
orderList  →  processOrderPositionSelect  →  processScanUnitLoad  →  processScanTransferLane
   (A)               (B)                         (C)                       (D)
   │                 │                           │                         │
   ▼                 ▼                           ▼                         ▼
updateOrderList   updateOrderPosition     validateUnitByUnitLoad    transferStock
   │                 │                           │                    │       │
   ▼                 ▼                           │              [transfer]  updateOrderPosition
 per order:     calculateStockOnStagingLane      │                         │
  ├ findById    updateOrderPositionPickSources    │                  calculateStockOnStagingLane
  │  (client)      │                             │                  updateOrderPositionPickSources
  ├ findById       ▼                             │
  │  (batch)    getStockUnitItemIdAndNotLocked    │
  ├ findById    per stock unit (×3 filter passes):│
  │  (location)  ├ findById(unitload)             │
  └ updateOrder  ├ findById(location)             │
     │           ├ findById(area or type)          │
     ▼           per stock unit (DTO build):       │
   per position:  ├ findById(unitload)             │
    ├ findById    ├ findById(location)             │
    │ (itemdata)  └ findById(locationType)         │
    ├ findById
    │ (location)     ~~12N queries~~
    └ calculateStockOnStagingLane
        │
        ▼
      per unitload:
       └ per stockunit:
          └ findById(itemdata)

          ~~1+N+NM queries~~
```

### Query Count Estimates (Typical Transfer: 5 orders, 6 positions each, 10 ULs on lane, 30 SUs)

| Method | Formula | Estimated Queries |
|--------|---------|-------------------|
| `updateOrderList()` | O × (3 + P × (2 + 1 + N + N×M)) | **~300-500** |
| `updateOrderPosition()` | 4 + (1 + N + N×M) + 12×S | **~40-200** |
| `transferStock()` | 5 + (1 + N + N×M) + 10-15 | **~30-80** |
| `getTransferLineUnitLoads()` | P × (1 + 2×U + U×(C+S) + U×2) | **~50-200** |
| `BillofladingService.transferOrder()` | (1 + N + N×M) + U×(2 + 10-15) | **~50-150** |
| `getSKUOverview()` | 2 + 2×P + P | **~20** |

Where: O=orders, P=positions, N=unitloads, M=stockunits/UL, S=source stock units, U=unit loads, C=carrier depth

---

## Performance Bottleneck Analysis

### Bottleneck 1: `calculateStockOnStagingLane()` — Nested N+1 Loop (CRITICAL)

**File:** `MobileTransferOrderService.java:317-330`

```java
// CURRENT: 1 + N + N*M queries
for (Unitload unitLoad : unitloadRepository.findByStoragelocationId(transferLane.getId())) {       // 1 query → N results
    for (Stockunit stockUnit : stockunitRepository.findByUnitloadId(unitLoad.getId())) {            // N queries → M results each
        Itemdata itemdata = itemdataRepository.findById(stockUnit.getItemdataId()).orElseThrow(...); // N*M queries
        if (itemdata.equals(sku)) {  // BUG B1: entity equality, not ID comparison
            amountOnLocation = amountOnLocation + stockUnit.getAmount().intValue();
        }
    }
}
```

**Impact:** Called from **3 locations** — `updateOrder():128`, `updateOrderPosition():160`, `transferStock():277`. In `updateOrderList()`, this is called O×P times (orders × positions), producing O×P×(1+N+N×M) queries.

**Root cause:** The method reimplements what the existing native query `StockunitRepository.getAmountAvailable(locationId, itemdataId)` already does in a **single SQL query**.

**Bug B1:** `itemdata.equals(sku)` uses entity reference equality (or broken field equality). Should compare by `itemdata.getId().equals(sku.getId())`. This bug is masked because the method still produces correct results when itemdata entities happen to be the same persistence context instance, but fails after `entityManager.clear()` or across transaction boundaries.

---

### Bottleneck 2: `updateOrderPositionPickSources()` — Triple-Nested findById in Stream Filters (CRITICAL)

**File:** `MobileTransferOrderService.java:188-223`

```java
// CURRENT: 3 filter passes × 3 findById()s per stock unit = 9N queries in filters
// + 3 more findById()s per stock unit in DTO loop = 3N queries
// Total: ~12N queries for N stock units

// Filter 1: deep storage locations (3 queries per SU)
stockUnitList.addAll(resultList.stream().filter(su ->
    locationAreaRepository.findById(                              // query 3
        locationRepository.findById(                              // query 2
            unitloadRepository.findById(su.getUnitloadId())       // query 1
                .orElseThrow(...).getStoragelocationId()
        ).get().getAreaId()
    ).get().getUsefordeepstorage()).collect(Collectors.toList()));

// Filter 2: non-flowbin locations (3 queries per SU)
stockUnitList.addAll(resultList.stream().filter(su -> !
    locationTypeRepository.findById(                              // query 3
        locationRepository.findById(                              // query 2
            unitloadRepository.findById(su.getUnitloadId())       // query 1
                .orElseThrow(...).getStoragelocationId()
        ).get().getTypeId()
    ).get().getSltname().equals(STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN))
    .collect(Collectors.toList()));

// Filter 3: flowbin locations (3 queries per SU)
stockUnitList.addAll(resultList.stream().filter(su ->
    locationTypeRepository.findById(...)                          // same pattern
    .get().getSltname().equals(STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN))
    .collect(Collectors.toList()));

// DTO building loop (3 queries per SU)
for (Stockunit stockUnit : stockUnitList) {
    Unitload unitLoad = unitloadRepository.findById(...);         // query 1
    Location location = locationRepository.findById(...);         // query 2
    LocationType locationType = locationTypeRepository.findById(...); // query 3
    // build DTO
}
```

**Impact:** For 20 available stock units, this generates **~240 queries**. Called every time a warehouse operator selects a position on the mobile device.

**Bug B3:** The 3 filter passes add stock units to `stockUnitList` independently. A stock unit in a deep storage location that is NOT a flowbin gets added by both Filter 1 (deep storage=true) and Filter 2 (not flowbin). This produces duplicates in the pick source list shown on the mobile device.

---

### Bottleneck 3: `updateOrderList()` + `updateOrder()` — Per-Order/Per-Position N+1

**File:** `MobileTransferOrderService.java:90-149`

```java
// updateOrderList() — 3 findById()s per order
for (Customerorder customerOrder : customerOrderList) {
    Client client = clientRepository.findById(customerOrder.getClientId())...;              // per order
    CustomerorderBatch coBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId())...; // per order
    Location transferLane = locationRepository.findById(customerOrder.getTransferlaneId())...; // per order
    transferOrderDto = updateOrder(transferOrderDto);
}

// updateOrder() — 2 findById()s + calculateStockOnStagingLane() per position
for (CustomerorderPosition position : positions) {
    Itemdata itemData = itemdataRepository.findById(...)...;      // per position
    Location transferLane = locationRepository.findById(...)...;   // per position (SAME location every time!)
    int amountOnTransferLane = calculateStockOnStagingLane(itemData, transferLane); // expensive!
}
```

**Impact:** For 5 orders × 6 positions: 5×3 = 15 lookups + 5×6×2 = 60 lookups + 5×6×(1+N+N×M) per-position staging lane calculation. The `locationRepository.findById(customerOrder.getTransferlaneId())` is called once per position but returns the same `Location` every time within the same order.

---

### Bottleneck 4: `getTransferLineUnitLoads()` + `calc()` — Complex N+1 with Carrier Recursion

**File:** `TransferOrderService.java:226-320`

```java
// Per position: itemdata lookup + carrier traversal + recursive calc
positions.forEach(position -> {
    Itemdata itemData = itemdataRepository.findById(position.getItemdataId())...;  // N+1

    for (Unitload unitLoad : resultList) {
        // BUG B2: double findById on same carrier ID per while-loop iteration
        while (unitLoad.getCarrierunitloadId() != null &&
               unitloadRepository.findById(unitLoad.getCarrierunitloadId()).isPresent()) {   // query 1
            unitLoad = unitloadRepository.findById(carrierUlId).orElseThrow(...);             // query 2 (DUPLICATE!)
        }
    }

    for (Unitload unitLoad : ulWithoutCarrier) {
        Itemdata ulItemData = itemdataRepository.findById(position.getItemdataId())...;  // SAME itemdata re-fetched!
        int amount = calc(unitLoad, ulItemData, unitLoadIntegerMap);  // recursive
    }

    unitLoadIntegerMap.forEach((unitLoad, amount) -> {
        Location ulStorageLocation = locationRepository.findById(unitLoad.getStoragelocationId())...;  // N+1
        itemunitRepository.findById(itemData.getHandlingunitId())...;  // N+1 (same itemunit per position!)
    });
});
```

**`calc()` recursive method (lines 302-320):**
```java
private int calc(Unitload unitLoad, Itemdata itemData, Map<Unitload, Integer> unitLoadIntegerMap) {
    List<Unitload> childrenUnitLoads = unitloadRepository.findByCarrierunitloadId(unitLoad.getId());  // query per node
    for (Unitload ul : childrenUnitLoads) {
        calc(ul, itemData, unitLoadIntegerMap);  // recursive
    }
    List<Stockunit> suList = stockunitRepository.findByUnitloadId(unitLoad.getId());  // query per node
    for (Stockunit stockUnit : suList) {
        Itemdata suItemData = itemdataRepository.findById(stockUnit.getItemdataId())...;  // N+1 per stock unit
    }
}
```

**Impact:** For 6 positions × 10 unit loads × 2 carrier depth: ~6×(1 + 10×2×2 + 10×(1+3×1) + 10×2) = ~400+ queries.

**Bug B2:** The while loop at line 255 calls `unitloadRepository.findById(carrierUlId)` twice per iteration — once in the condition (`.isPresent()`) and again in the body (`.orElseThrow()`). The JPA first-level cache may absorb this for non-native queries, but it's still wasteful.

---

### Bottleneck 5: `BillofladingService.transferOrder()` — combineStock() without Pre-fetched FLA

**File:** `BillofladingService.java:711-786`

```java
// transferOrder() calls combineStock() per unit load, which calls transferStockToUnitLoad()
// transferStockToUnitLoad() internally fetches FixLocationAssignment per call
for (Unitload unitLoad : unitLoads) {
    combineStock(customerOrder, emptyUnitLoadList, pallet, parcel, unitLoad);
    // → for each stock unit: transferStockToUnitLoad(stockUnit, parcel, ...)
    //   → internally: fixLocationAssignmentRepository.findByAssignedlocationId(sourceLocation.getId())
    //   → internally: fixLocationAssignmentRepository.findByAssignedlocationId(destinationLocation.getId())
}
```

**Impact:** The `transferStockToUnitLoad()` 9-arg overload with pre-fetched FLA (added in commit `589b0ef`) is not used here. Each call still fetches the FLA for the destination (transfer lane) location — which is the **same location** for every call. For 30 stock units, that's ~30 redundant FLA lookups.

---

### Bottleneck 6: `getSKUOverview()` — Minor Per-Position N+1

**File:** `TransferOrderService.java:192-224`

```java
positions.forEach(position -> {
    Itemdata itemData = itemdataRepository.findById(position.getItemdataId())...;    // N+1
    String unitName = itemunitRepository.findById(itemData.getHandlingunitId())...;  // N+1
    Integer amount = stockunitRepository.getAmountAvailable(...);                     // N+1 (native, efficient)
});
```

**Impact:** ~3N queries for N positions. Moderate — typically 6-10 positions. Low priority but easy to batch.

---

## Phase 1: Replace `calculateStockOnStagingLane()` with Native Query

**Priority:** CRITICAL — Highest impact, lowest effort
**Files:** `MobileTransferOrderService.java`
**Estimated reduction:** ~300-400 queries eliminated per `updateOrderList()` call

### Problem

`calculateStockOnStagingLane()` (lines 317-330) uses a triple-nested loop to compute what the existing native query `StockunitRepository.getAmountAvailable(locationId, itemdataId)` already computes in **one SQL statement**.

### Current Code (lines 317-330)

```java
private int calculateStockOnStagingLane(Itemdata sku, Location transferLane) {
    int amountOnLocation = 0;
    for (Unitload unitLoad : unitloadRepository.findByStoragelocationId(transferLane.getId())) {
        for (Stockunit stockUnit : stockunitRepository.findByUnitloadId(unitLoad.getId())) {
            Itemdata itemdata = itemdataRepository.findById(stockUnit.getItemdataId()).orElseThrow(...);
            if (itemdata.equals(sku)) {
                amountOnLocation = amountOnLocation + stockUnit.getAmount().intValue();
            }
        }
    }
    return amountOnLocation;
}
```

### Optimized Code

```java
private int calculateStockOnStagingLane(Itemdata sku, Location transferLane) {
    Integer amount = stockunitRepository.getAmountAvailable(transferLane.getId(), sku.getId());
    return amount != null ? amount : 0;
}
```

### Existing Native Query (`StockunitRepository.java:41-48`)

```sql
SELECT sum(stockUnit.amount) FROM stockunit
INNER JOIN unitload ON stockunit.unitload_id = unitload.id
INNER JOIN itemdata ON stockunit.itemdata_id = itemdata.id
INNER JOIN location ON unitload.storagelocation_id = location.id
WHERE location.id = :locationId
AND itemdata.id = :itemdataId
```

This query does the exact same join path (location → unitload → stockunit → itemdata) and sum, but in a single round-trip.

### Bug Fix B1

The `itemdata.equals(sku)` comparison is replaced by ID-based matching in the SQL WHERE clause (`itemdata.id = :itemdataId`), which is correct and efficient.

### Impact

| Call Site | Before | After | Reduction |
|-----------|--------|-------|-----------|
| `updateOrder():128` (×P per order) | 1+N+N×M per position | **1** per position | ~95% |
| `updateOrderPosition():160` | 1+N+N×M | **1** | ~95% |
| `transferStock():277` | 1+N+N×M | **1** | ~95% |
| `updateOrderList()` (5 orders × 6 positions) | ~300-400 | **~30** | ~90% |

### Testing

- Run existing `MobileTransferOrderServiceUnitTest` — all `calculateStockOnStagingLane` dependent tests
- Verify: `updateOrderList`, `updateOrder`, `updateOrderPosition`, `transferStock` return same results
- Edge case: empty transfer lane (no stock) should return 0
- Edge case: stock unit with amount=0 should not contribute

---

## Phase 2: Batch Pre-fetch in `updateOrderPositionPickSources()`

**Priority:** CRITICAL — Eliminates ~12N queries for N stock units
**Files:** `MobileTransferOrderService.java`
**Estimated reduction:** ~200+ queries eliminated per position selection

### Problem

Three stream filter passes and the DTO building loop each independently call `findById()` on unitload, location, area, and type repositories — per stock unit.

### Current Code (lines 179-228)

The 3 filter passes determine pick source priority:
1. Deep storage locations (should be picked first)
2. Non-flowbin locations (standard pick locations)
3. Flowbin locations (last priority)

Each filter traverses: `stockunit → unitload → location → area/type` via 3 nested `findById()` calls.

### Optimized Approach

Pre-fetch all related entities in bulk before filtering:

```java
public TransferOrderPositionDto updateOrderPositionPickSources(TransferOrderPositionDto transferOrderPositionDto) {
    LOG.debug("start with {}", transferOrderPositionDto);
    transferOrderPositionDto.setInputUnitLoad(null);
    transferOrderPositionDto.setCurrentPickSource(null);
    transferOrderPositionDto.setTransferOrderPositionPickSourceDtoList(new ArrayList<>());

    List<Stockunit> resultList = stockunitRepository.getStockUnitItemIdAndNotLocked(
        WmsConstants.BusinessObjectLockState.NOT_LOCKED, transferOrderPositionDto.getSkuId());

    if (resultList.isEmpty()) {
        return transferOrderPositionDto;
    }

    // --- BATCH PRE-FETCH (3 queries instead of 9N) ---
    Set<Long> unitloadIds = resultList.stream()
        .map(Stockunit::getUnitloadId).collect(Collectors.toSet());
    Map<Long, Unitload> unitloadMap = unitloadRepository.findAllById(unitloadIds).stream()
        .collect(Collectors.toMap(Unitload::getId, u -> u));

    Set<Long> locationIds = unitloadMap.values().stream()
        .map(Unitload::getStoragelocationId).collect(Collectors.toSet());
    Map<Long, Location> locationMap = locationRepository.findAllById(locationIds).stream()
        .collect(Collectors.toMap(Location::getId, l -> l));

    Set<Long> areaIds = locationMap.values().stream()
        .map(Location::getAreaId).collect(Collectors.toSet());
    Map<Long, LocationArea> areaMap = locationAreaRepository.findAllById(areaIds).stream()
        .collect(Collectors.toMap(LocationArea::getId, a -> a));

    Set<Long> typeIds = locationMap.values().stream()
        .map(Location::getTypeId).collect(Collectors.toSet());
    Map<Long, LocationType> typeMap = locationTypeRepository.findAllById(typeIds).stream()
        .collect(Collectors.toMap(LocationType::getId, t -> t));

    // --- IN-MEMORY FILTERING (0 queries) ---
    // Priority ordering: deep storage first, then non-flowbin, then flowbin
    List<Stockunit> deepStorageStockUnits = new ArrayList<>();
    List<Stockunit> nonFlowbinStockUnits = new ArrayList<>();
    List<Stockunit> flowbinStockUnits = new ArrayList<>();

    for (Stockunit su : resultList) {
        Unitload ul = unitloadMap.get(su.getUnitloadId());
        if (ul == null) continue;
        Location loc = locationMap.get(ul.getStoragelocationId());
        if (loc == null) continue;
        LocationArea area = areaMap.get(loc.getAreaId());
        LocationType type = typeMap.get(loc.getTypeId());

        boolean isDeepStorage = area != null && Boolean.TRUE.equals(area.getUsefordeepstorage());
        boolean isFlowbin = type != null &&
            WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(type.getSltname());

        if (isDeepStorage) {
            deepStorageStockUnits.add(su);
        } else if (!isFlowbin) {
            nonFlowbinStockUnits.add(su);
        } else {
            flowbinStockUnits.add(su);
        }
    }

    List<Stockunit> stockUnitList = new ArrayList<>();
    stockUnitList.addAll(deepStorageStockUnits);
    stockUnitList.addAll(nonFlowbinStockUnits);
    stockUnitList.addAll(flowbinStockUnits);

    // --- DTO BUILDING (0 queries — reuse pre-fetched maps) ---
    List<TransferOrderPositionPickSourceDto> pickSourceList = new ArrayList<>();
    for (Stockunit stockUnit : stockUnitList) {
        Unitload unitLoad = unitloadMap.get(stockUnit.getUnitloadId());
        Location location = locationMap.get(unitLoad.getStoragelocationId());
        LocationType locationType = typeMap.get(location.getTypeId());

        TransferOrderPositionPickSourceDto dto = new TransferOrderPositionPickSourceDto();
        dto.setStockUnitId(stockUnit.getId());
        dto.setAmountOnPosition(stockUnit.getAvailableamount().intValue());
        dto.setLocationName(location.getName());
        dto.setLocationType(locationType.getSltname());
        dto.setUnitLoadLabel(unitLoad.getLabelid());
        pickSourceList.add(dto);
    }

    transferOrderPositionDto.setTransferOrderPositionPickSourceDtoList(pickSourceList);
    LOG.debug("end   with {}", transferOrderPositionDto);
    return transferOrderPositionDto;
}
```

### Bug Fix B3

The current code adds a stock unit to `stockUnitList` via three independent `addAll()` calls. A stock unit in a deep storage location that is NOT a flowbin matches both Filter 1 (deep storage) and Filter 2 (not flowbin), so it appears twice. The optimized code uses exclusive if/else-if/else logic to place each stock unit in exactly one category.

### Impact

| Scenario | Before (queries) | After (queries) | Reduction |
|----------|-------------------|-----------------|-----------|
| 20 stock units | 1 + 9×20 + 3×20 = **241** | 1 + 4 = **5** | **98%** |
| 50 stock units | 1 + 9×50 + 3×50 = **601** | 1 + 4 = **5** | **99%** |

### Testing

- Run existing `MobileTransferOrderServiceUnitTest` — `updateOrderPositionPickSources` tests
- Verify pick source ordering is preserved: deep storage → non-flowbin → flowbin
- Verify no duplicates in pick source list (Bug B3 fix)
- Edge case: stock unit whose unitload/location has been deleted between query and lookup

---

## Phase 3: Batch Pre-fetch in `updateOrderList()` + `updateOrder()`

**Priority:** HIGH — Eliminates per-order and per-position lookups
**Files:** `MobileTransferOrderService.java`
**Estimated reduction:** ~50-80 queries eliminated per order list load

### Problem 3a: `updateOrderList()` — Per-order lookups (lines 90-117)

Three `findById()` calls per order for client, batch, and location.

### Optimized `updateOrderList()`

```java
public List<TransferOrderDto> updateOrderList() {
    LOG.debug("start");
    List<Customerorder> customerOrderList = customerorderRepository.findByState(
        WmsConstants.State.CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);

    if (customerOrderList.isEmpty()) {
        return new ArrayList<>();
    }

    // --- BATCH PRE-FETCH (3 queries instead of 3×O) ---
    Set<Long> clientIds = customerOrderList.stream()
        .map(Customerorder::getClientId).collect(Collectors.toSet());
    Map<Long, Client> clientMap = clientRepository.findAllById(clientIds).stream()
        .collect(Collectors.toMap(Client::getId, c -> c));

    Set<Long> batchIds = customerOrderList.stream()
        .map(Customerorder::getOrderbatchId).collect(Collectors.toSet());
    Map<Long, CustomerorderBatch> batchMap = customerorderBatchRepository.findAllById(batchIds).stream()
        .collect(Collectors.toMap(CustomerorderBatch::getId, b -> b));

    Set<Long> locationIds = customerOrderList.stream()
        .map(Customerorder::getTransferlaneId).filter(Objects::nonNull).collect(Collectors.toSet());
    Map<Long, Location> locationMap = locationRepository.findAllById(locationIds).stream()
        .collect(Collectors.toMap(Location::getId, l -> l));

    List<TransferOrderDto> transferOrderDtoList = new ArrayList<>();
    for (Customerorder customerOrder : customerOrderList) {
        Client client = clientMap.get(customerOrder.getClientId());
        CustomerorderBatch coBatch = batchMap.get(customerOrder.getOrderbatchId());
        Location transferLane = locationMap.get(customerOrder.getTransferlaneId());

        if (client == null || coBatch == null || transferLane == null) continue;

        TransferOrderDto transferOrderDto = new TransferOrderDto();
        transferOrderDto.setClientName(client.getName());
        transferOrderDto.setClientNumber(client.getClNr());
        transferOrderDto.setCustomerOrderId(customerOrder.getId());
        transferOrderDto.setClientOrderNumber(customerOrder.getClientordernumber());
        transferOrderDto.setTransferid(coBatch.getTransferid());
        transferOrderDto.setTransferlane(transferLane.getName());

        transferOrderDto = updateOrder(transferOrderDto);
        if (transferOrderDto.getPositions().size() > 0) {
            transferOrderDtoList.add(transferOrderDto);
        }
    }
    LOG.debug("end   with transferOrders.size={}", transferOrderDtoList.size());
    return transferOrderDtoList;
}
```

### Problem 3b: `updateOrder()` — Redundant location fetch per position (lines 119-149)

`locationRepository.findById(customerOrder.getTransferlaneId())` is called inside the loop for every position, but the transfer lane is the same for all positions of the same order. Combined with Phase 1, this method becomes efficient.

### Optimized `updateOrder()`

```java
public TransferOrderDto updateOrder(TransferOrderDto transferOrderDto) {
    LOG.debug("start");
    Customerorder customerOrder = customerorderRepository.findById(
        transferOrderDto.getCustomerOrderId()).orElseThrow(() ->
            new EntityNotFoundException("CustomerOrder", transferOrderDto.getCustomerOrderId()));

    Location transferLane = locationRepository.findById(
        customerOrder.getTransferlaneId()).orElseThrow(() ->
            new EntityNotFoundException("Location", customerOrder.getTransferlaneId()));

    List<CustomerorderPosition> positions = customerorderPositionRepository.findByOrderId(
        transferOrderDto.getCustomerOrderId());

    // --- BATCH PRE-FETCH itemdata for all positions (1 query instead of P) ---
    Set<Long> itemdataIds = positions.stream()
        .map(CustomerorderPosition::getItemdataId).collect(Collectors.toSet());
    Map<Long, Itemdata> itemdataMap = itemdataRepository.findAllById(itemdataIds).stream()
        .collect(Collectors.toMap(Itemdata::getId, i -> i));

    List<TransferOrderPositionDto> transferOrderPositionDtoList = new ArrayList<>();
    for (CustomerorderPosition customerOrderPosition : positions) {
        Itemdata itemData = itemdataMap.get(customerOrderPosition.getItemdataId());
        if (itemData == null) continue;

        // Phase 1 optimization: single native query instead of nested loops
        int amountOnTransferLane = calculateStockOnStagingLane(itemData, transferLane);
        int amountNeeded = customerOrderPosition.getAmount().intValue();

        if (amountNeeded <= amountOnTransferLane) {
            continue;
        }

        int amountLeft = amountNeeded - amountOnTransferLane;

        TransferOrderPositionDto dto = new TransferOrderPositionDto();
        dto.setCustomerOrderId(transferOrderDto.getCustomerOrderId());
        dto.setAmountNeeded(amountLeft);
        dto.setCustomerOrderPositionId(customerOrderPosition.getId());
        dto.setSkuId(itemData.getId());
        dto.setSkuNumber(itemData.getItemNr());
        dto.setSkuName(itemData.getName());
        transferOrderPositionDtoList.add(dto);
    }
    LOG.debug("end   with transferOrderPositionss.size={}", transferOrderPositionDtoList.size());
    transferOrderDto.setPositions(transferOrderPositionDtoList);
    return transferOrderDto;
}
```

### Impact

| Scenario (5 orders, 6 positions) | Before (queries) | After (queries) | Reduction |
|-----------------------------------|-------------------|-----------------|-----------|
| `updateOrderList()` header lookups | 3×5 = 15 | 3 | 80% |
| `updateOrder()` per-position lookups | (2+1)×6×5 = 90 | (3+1)×5 = 20 | 78% |
| Combined with Phase 1 | ~300-500 total | ~40-50 total | **85-90%** |

### Testing

- Run existing `MobileTransferOrderServiceUnitTest` — `updateOrderList`, `updateOrder` tests
- Verify order list still filters out fully-fulfilled orders
- Verify position amounts correctly reflect remaining needs

---

## Phase 4: Optimize `getTransferLineUnitLoads()` + `calc()`

**Priority:** HIGH — Complex refactor, significant query reduction on web UI
**Files:** `TransferOrderService.java`
**Estimated reduction:** ~150-300 queries eliminated per unit load view

### Problem 4a: Per-position itemdata re-fetch (line 236, 270)

`itemdataRepository.findById(position.getItemdataId())` is called twice per position — once at the top of the loop (line 236) and again inside the inner loop (line 270) for the same ID.

### Problem 4b: Carrier traversal double-findById (lines 255-258)

```java
while (unitLoad.getCarrierunitloadId() != null &&
       unitloadRepository.findById(unitLoad.getCarrierunitloadId()).isPresent()) {  // query 1
    final Long carrierUlId = unitLoad.getCarrierunitloadId();
    unitLoad = unitloadRepository.findById(carrierUlId).orElseThrow(...);           // query 2 (same ID!)
}
```

### Problem 4c: `calc()` recursive N+1 (lines 302-320)

Each recursive call makes 2 queries (children + stock units) plus N itemdata lookups per stock unit.

### Problem 4d: Per-unit-load location and itemunit lookups (lines 275-284)

`locationRepository.findById()` and `itemunitRepository.findById()` called per unit load in the DTO building loop. The itemunit is the same for all unit loads of the same position.

### Optimized Approach

```java
public List<ClubLineUnitLoadDto> getTransferLineUnitLoads(
        Customerorder customerOrder, boolean onlyTransferLocation, String skuFilter) {

    List<ClubLineUnitLoadDto> skuList = new ArrayList<>();
    final int[] i = {0};

    List<CustomerorderPosition> positions = customerorderPositionRepository.findByOrderId(customerOrder.getId());

    // --- BATCH PRE-FETCH: itemdata + itemunits for all positions (2 queries) ---
    Set<Long> itemdataIds = positions.stream()
        .map(CustomerorderPosition::getItemdataId).collect(Collectors.toSet());
    Map<Long, Itemdata> itemdataMap = itemdataRepository.findAllById(itemdataIds).stream()
        .collect(Collectors.toMap(Itemdata::getId, id -> id));

    Set<Long> itemunitIds = itemdataMap.values().stream()
        .map(Itemdata::getHandlingunitId).collect(Collectors.toSet());
    Map<Long, Itemunit> itemunitMap = itemunitRepository.findAllById(itemunitIds).stream()
        .collect(Collectors.toMap(Itemunit::getId, iu -> iu));

    // Pre-fetch transfer lane once if needed
    Location transferLane = null;
    if (onlyTransferLocation && customerOrder.getTransferlaneId() != null) {
        transferLane = locationRepository.findById(customerOrder.getTransferlaneId()).orElse(null);
    }

    for (CustomerorderPosition position : positions) {
        Itemdata itemData = itemdataMap.get(position.getItemdataId());
        if (itemData == null) continue;
        if (skuFilter != null && !skuFilter.equals(itemData.getName())) continue;

        List<Unitload> resultList;
        if (onlyTransferLocation) {
            resultList = (transferLane != null)
                ? unitloadRepository.getBatchLocationsByItemIdAndLaneName(itemData.getId(), transferLane.getName())
                : new ArrayList<>();
        } else {
            resultList = unitloadRepository.getBatchLocationsByItemIdAndNamedLocations(
                itemData.getId(), locationService.getClearing().getId(),
                Arrays.asList(AREA_INBOUND_NAME, AREA_STORAGE_PICKING_NAME,
                    AREA_STORAGE_PICKING_REPLENISH_NAME, AREA_STORAGE_REPLENISH_NAME,
                    AREA_DEEP_STORAGE_NAME, AREA_USERS_NAME));
        }

        // --- FIX B2: Single findById per carrier traversal step ---
        List<Unitload> ulWithoutCarrier = new ArrayList<>();
        for (Unitload unitLoad : resultList) {
            while (unitLoad.getCarrierunitloadId() != null) {
                Optional<Unitload> carrierOpt = unitloadRepository.findById(unitLoad.getCarrierunitloadId());
                if (carrierOpt.isPresent()) {
                    unitLoad = carrierOpt.get();
                } else {
                    break;
                }
            }
            final Unitload currentUnitLoad = unitLoad;
            if (ulWithoutCarrier.stream().noneMatch(ul -> ul.getId().equals(currentUnitLoad.getId()))
                    && customerOrder.getClientId().equals(currentUnitLoad.getClientId())) {
                ulWithoutCarrier.add(unitLoad);
            }
        }

        // --- BATCH PRE-FETCH: all stock units for all unit loads in one query ---
        Set<Long> ulIds = ulWithoutCarrier.stream().map(Unitload::getId).collect(Collectors.toSet());
        // Also collect child UL IDs for calc() — flatten carrier tree
        Set<Long> allUlIds = new HashSet<>(ulIds);
        // Fetch children iteratively (breadth-first)
        Set<Long> currentLevel = new HashSet<>(ulIds);
        while (!currentLevel.isEmpty()) {
            List<Unitload> children = new ArrayList<>();
            for (Long ulId : currentLevel) {
                children.addAll(unitloadRepository.findByCarrierunitloadId(ulId));
            }
            currentLevel = children.stream().map(Unitload::getId).collect(Collectors.toSet());
            allUlIds.addAll(currentLevel);
        }

        Map<Long, List<Stockunit>> stockByUnitload = Collections.emptyMap();
        if (!allUlIds.isEmpty()) {
            stockByUnitload = stockunitRepository.findByUnitloadIdIn(allUlIds).stream()
                .collect(Collectors.groupingBy(Stockunit::getUnitloadId));
        }

        // --- calc() with pre-fetched data (0 additional queries) ---
        Map<Unitload, Integer> unitLoadIntegerMap = new HashMap<>();
        for (Unitload unitLoad : ulWithoutCarrier) {
            int amount = calcOptimized(unitLoad, itemData, unitLoadIntegerMap, stockByUnitload);
            unitLoadIntegerMap.put(unitLoad, amount);
        }

        // --- DTO building with pre-fetched location + itemunit (batch fetch locations) ---
        Set<Long> locationIdsForDto = ulWithoutCarrier.stream()
            .map(Unitload::getStoragelocationId).collect(Collectors.toSet());
        Map<Long, Location> locationMapForDto = locationRepository.findAllById(locationIdsForDto).stream()
            .collect(Collectors.toMap(Location::getId, l -> l));

        Itemunit itemunit = itemunitMap.get(itemData.getHandlingunitId());
        String unitName = itemunit != null ? itemunit.getUnitname() : "";

        unitLoadIntegerMap.forEach((unitLoad, amount) -> {
            Location ulStorageLocation = locationMapForDto.get(unitLoad.getStoragelocationId());
            ClubLineUnitLoadDto dto = new ClubLineUnitLoadDto();
            dto.setAmount(amount);
            dto.setUnitLoadName(unitLoad.getLabelid());
            dto.setUnitLoadId(unitLoad.getId());
            dto.setItemDataName(itemData.getName());
            dto.setItemId(itemData.getItemNr());
            dto.setItemType(itemData.getWinetype());
            dto.setItemUnit(unitName);
            dto.setLocationName(ulStorageLocation != null ? ulStorageLocation.getName() : "");
            dto.setId(i[0]++);
            dto.setCarrierName(null);
            if (unitLoad.getCarrierunitloadId() != null) {
                unitloadRepository.findById(unitLoad.getCarrierunitloadId())
                    .ifPresent(carrier -> dto.setCarrierName(carrier.getLabelid()));
            }
            skuList.add(dto);
        });
    }

    return skuList;
}

// Optimized calc() using pre-fetched stock map
private int calcOptimized(Unitload unitLoad, Itemdata itemData,
        Map<Unitload, Integer> unitLoadIntegerMap,
        Map<Long, List<Stockunit>> stockByUnitload) {
    int total = 0;

    List<Unitload> childrenUnitLoads = unitloadRepository.findByCarrierunitloadId(unitLoad.getId());
    for (Unitload ul : childrenUnitLoads) {
        total += calcOptimized(ul, itemData, unitLoadIntegerMap, stockByUnitload);
    }

    List<Stockunit> suList = stockByUnitload.getOrDefault(unitLoad.getId(), Collections.emptyList());
    for (Stockunit stockUnit : suList) {
        if (stockUnit.getItemdataId().equals(itemData.getId())) {
            total += stockUnit.getAmount().intValue();
        }
    }

    unitLoadIntegerMap.put(unitLoad, total);
    return total;
}
```

### Impact

| Scenario (6 positions, 10 ULs, depth 2) | Before (queries) | After (queries) | Reduction |
|------------------------------------------|-------------------|-----------------|-----------|
| Itemdata lookups | 6 + 6×10 = 66 | 1 | 98% |
| Carrier traversal | 6×10×2×2 = 240 | 6×10×1 = 60 | 75% |
| calc() recursive | 6×10×(2+3) = 300 | 6×(10+1) = 66 | 78% |
| Location/Itemunit DTO | 6×(10+10) = 120 | 6×1 = 6 | 95% |
| **Total** | **~400-700** | **~60-130** | **~75-85%** |

### Testing

- Run existing `TransferOrderServiceUnitTest` — `getTransferLineUnitLoads` tests
- Verify amounts match current behavior
- Verify carrier name resolution
- Verify client ID filtering still works
- Verify SKU filter still works

---

## Phase 5: Pre-fetch FLA in `BillofladingService.transferOrder()`

**Priority:** MEDIUM — Applies proven pattern from commit `589b0ef`
**Files:** `BillofladingService.java`
**Estimated reduction:** ~30-60 redundant FLA queries per transfer order

### Problem

`combineStock()` calls `transferStockToUnitLoad()` per stock unit using the 8-arg overload (which internally fetches FLA). The destination is always the same transfer lane, so the destination FLA is fetched identically on every call.

### Optimized Code

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void transferOrder(Long customerOrderId) throws BusinessException, FacadeException {
    // ... existing setup code ...

    List<Unitload> unitLoads = unitloadRepository.findByStoragelocationId(transferLane.getId());

    // --- PRE-FETCH FLA for transfer lane (1 query instead of ~30) ---
    FixLocationAssignment transferLaneFla = fixLocationAssignmentRepository
        .findByAssignedlocationId(transferLane.getId()).orElse(null);

    List<Unitload> emptyUnitLoadList = new ArrayList<>();
    for (Unitload unitLoad : unitLoads) {
        combineStock(customerOrder, emptyUnitLoadList, pallet, parcel, unitLoad, transferLaneFla);
    }

    // ... rest unchanged ...
}

private void combineStock(Customerorder customerOrder, List<Unitload> emptyUnitLoadList,
        Unitload pallet, Unitload parcel, Unitload unitLoad,
        FixLocationAssignment transferLaneFla) throws FacadeException, BusinessException {
    if (unitLoad.getId().equals(pallet.getId()) || unitLoad.getId().equals(parcel.getId())) {
        return;
    }
    List<Unitload> ulChildren = unitloadRepository.findByCarrierunitloadId(unitLoad.getId());
    if (ulChildren.isEmpty()) {
        List<Stockunit> ulStockUnits = stockunitRepository.findByUnitloadId(unitLoad.getId());
        if (ulStockUnits.isEmpty()) {
            emptyUnitLoadList.add(unitLoad);
            return;
        }
        for (Stockunit stockUnit : new ArrayList<>(ulStockUnits)) {
            // Use 9-arg overload with pre-fetched FLA
            stockunitBusinessService.transferStockToUnitLoad(stockUnit, parcel, stockUnit.getAmount(),
                WmsConstants.CODE_TRANSFER_BUILD_TRUCK, customerOrder.getNumber(), null,
                false, true, transferLaneFla);
        }
        return;
    }
    for (Unitload child : ulChildren) {
        combineStock(customerOrder, emptyUnitLoadList, pallet, parcel, child, transferLaneFla);
    }
    emptyUnitLoadList.add(unitLoad);
}
```

### Impact

| Scenario (10 ULs, 30 SUs) | Before | After | Reduction |
|----------------------------|--------|-------|-----------|
| FLA lookups (destination) | ~30 | 1 | 97% |

### Testing

- Run existing `BillofladingServiceUnitTest` — `transferOrder` tests
- Verify stock is correctly consolidated onto pallet/parcel
- Verify empty unit loads are cleaned up

---

## Phase 6: Batch Pre-fetch in `getSKUOverview()`

**Priority:** LOW — Minor optimization, easy to implement
**Files:** `TransferOrderService.java`
**Estimated reduction:** ~10-15 queries per SKU overview page load

### Problem

Per-position `itemdataRepository.findById()` and `itemunitRepository.findById()` inside `forEach`.

### Optimized Code

```java
public List<ClubLineSkuDto> getSKUOverview(Long orderBatchId) {
    List<Customerorder> customerOrders = customerorderRepository.findByOrderbatchId(orderBatchId);
    List<CustomerorderPosition> positions = customerorderPositionRepository.findByOrderId(
        customerOrders.get(0).getId());

    // --- BATCH PRE-FETCH (2 queries instead of 2×P) ---
    Set<Long> itemdataIds = positions.stream()
        .map(CustomerorderPosition::getItemdataId).collect(Collectors.toSet());
    Map<Long, Itemdata> itemdataMap = itemdataRepository.findAllById(itemdataIds).stream()
        .collect(Collectors.toMap(Itemdata::getId, id -> id));

    Set<Long> itemunitIds = itemdataMap.values().stream()
        .map(Itemdata::getHandlingunitId).collect(Collectors.toSet());
    Map<Long, Itemunit> itemunitMap = itemunitRepository.findAllById(itemunitIds).stream()
        .collect(Collectors.toMap(Itemunit::getId, iu -> iu));

    Long transferLaneId = customerOrders.get(0).getTransferlaneId();

    List<ClubLineSkuDto> skuList = new ArrayList<>();
    for (CustomerorderPosition position : positions) {
        Itemdata itemData = itemdataMap.get(position.getItemdataId());
        if (itemData == null) continue;

        Itemunit itemunit = itemunitMap.get(itemData.getHandlingunitId());

        ClubLineSkuDto dto = new ClubLineSkuDto();
        dto.setEntity(itemData);
        dto.setName(itemData.getName());
        dto.setNumber(itemData.getItemNr());
        dto.setUnit(itemunit != null ? itemunit.getUnitname() : "");
        dto.setAmountRequired(position.getAmount().intValue());
        dto.setId(itemData.getId());

        if (transferLaneId == null) {
            dto.setAmountAvailable(0);
        } else {
            Integer amount = stockunitRepository.getAmountAvailable(transferLaneId, itemData.getId());
            dto.setAmountAvailable(amount != null ? amount : 0);
        }
        skuList.add(dto);
    }
    return skuList;
}
```

### Impact

| Scenario (6 positions) | Before | After | Reduction |
|-------------------------|--------|-------|-----------|
| Itemdata lookups | 6 | 1 | 83% |
| Itemunit lookups | 6 | 1 | 83% |
| **Total** | 2 + 12 + 6 = 20 | 2 + 2 + 6 = 10 | 50% |

Note: The `getAmountAvailable()` native query per position (6 queries) is efficient and doesn't benefit from batching without a custom aggregate query.

### Testing

- Run existing `TransferOrderServiceUnitTest` — `getSKUOverview` tests
- Verify amounts and SKU details match current behavior

---

## Multi-Threading Considerations

### TenantContext Thread-Local Safety

**CRITICAL:** All optimizations in this plan use **sequential processing only**. No `parallelStream()`, `CompletableFuture`, or `@Async` is introduced.

The `TenantContext` uses `ThreadLocal` storage for database routing. As demonstrated by Bug B2 in the Club Processing plan (commit `74f3c22`), parallel operations lose tenant context in ForkJoinPool threads, causing queries to route to the wrong database.

**Rule:** Never use `parallelStream()` or `CompletableFuture` in any service method that accesses tenant-scoped repositories.

### Concurrent Mobile Device Access

Multiple handheld devices may simultaneously:
1. Load the same order list (`updateOrderList()`) — safe, read-only
2. Select the same position (`updateOrderPosition()`) — safe, read-only
3. Transfer stock to the same lane (`transferStock()`) — protected by pessimistic locks in `transferStockToUnitLoad()`

The batch pre-fetch optimizations do not change concurrency behavior. All existing locking mechanisms in `StockunitBusinessService.transferStockToUnitLoad()` and `UnitloadBusinessService.transferUnitLoadToLocation()` remain unchanged.

### JPA First-Level Cache Interaction

The batch `findAllById()` calls load entities into the JPA persistence context (L1 cache). Subsequent `findById()` calls for the same IDs within the same transaction will hit the L1 cache rather than the database. This provides a secondary optimization benefit — any `findById()` calls we missed in the optimization still benefit from the batch pre-fetch warming the cache.

**Exception:** Native queries (e.g., `getAmountAvailable()`, `getStockUnitItemIdAndNotLocked()`) bypass the L1 cache entirely. These cannot benefit from pre-fetching.

---

## Estimated Impact Summary

### Per-Endpoint Query Reduction

| Endpoint | Method | Before | After | Reduction |
|----------|--------|--------|-------|-----------|
| `GET /v3/transferOrder/orderList` | `updateOrderList()` | ~300-500 | ~40-50 | **85-90%** |
| `POST /v3/transferOrder/processOrderPositionSelect` | `updateOrderPosition()` | ~40-200 | ~8-12 | **80-95%** |
| `POST /v3/transferOrder/processScanTransferLane` | `transferStock()` | ~30-80 | ~15-20 | **50-75%** |
| `POST /v3/transfers/unitLoads` | `getTransferLineUnitLoads()` | ~400-700 | ~60-130 | **75-85%** |
| `GET /v3/transfers/runTransfer/{id}` | `transferOrder()` | ~50-150 | ~30-100 | **30-40%** |
| `GET /v3/transfers/skus` | `getSKUOverview()` | ~20 | ~10 | **50%** |

### Phase-by-Phase Cumulative Impact

| Phase | Queries Eliminated | Effort | Dependencies |
|-------|-------------------|--------|--------------|
| Phase 1 | ~300-400 | Very Low (5-line change) | None |
| Phase 2 | ~200+ | Medium (rewrite method) | None |
| Phase 3 | ~50-80 | Medium (batch pre-fetch) | Phase 1 |
| Phase 4 | ~150-300 | High (complex refactor) | None |
| Phase 5 | ~30-60 | Low (proven pattern) | None |
| Phase 6 | ~10-15 | Low (batch pre-fetch) | None |

### Recommended Implementation Order

1. **Phase 1** first — highest impact, trivial change, unblocks Phase 3
2. **Phase 2** next — second highest impact on mobile critical path
3. **Phase 5** in parallel — independent, low risk, proven pattern
4. **Phase 3** after Phase 1 — builds on Phase 1
5. **Phase 6** — easy, independent
6. **Phase 4** last — most complex, web UI only (lower priority than mobile)

---

## Testing Strategy

### Unit Tests

All phases should be validated against existing unit tests:

| Test File | Covers |
|-----------|--------|
| `TransferOrderServiceUnitTest.java` | Phases 4, 6: `getTransferLineUnitLoads`, `getSKUOverview`, `isEnoughStockOnTransferLane` |
| `MobileTransferOrderServiceUnitTest.java` | Phases 1, 2, 3: `updateOrderList`, `updateOrder`, `updateOrderPosition`, `transferStock` |
| `TransferOrderControllerUnitTest.java` | Controller-level tests for all endpoints |
| `BillofladingServiceUnitTest.java` | Phase 5: `transferOrder` |

### Integration Tests

| Test File | Covers |
|-----------|--------|
| `MobileTransferOrderServiceIntegrationTest.java` | End-to-end mobile transfer flow with real database |

### Manual Verification

For each phase, verify on a test tenant with representative data:
1. Transfer order list loads correctly with all position data
2. Position selection shows correct pick sources in priority order
3. Stock transfer moves correct amounts
4. Run Transfer consolidates stock correctly
5. Unit load view shows correct amounts and locations

### Regression Checklist

- [ ] No `parallelStream()` introduced
- [ ] All `@Transactional` annotations specify `tenantTransactionManager`
- [ ] No new `findById()` calls inside loops (use pre-fetched maps)
- [ ] Edge case: empty collections passed to `findAllById()` / `findByUnitloadIdIn()`
- [ ] Edge case: null FK IDs filtered before batch fetch (e.g., `transferlaneId` can be null)

---

## File Reference Index

### Files Modified Per Phase

| Phase | Files |
|-------|-------|
| 1 | `MobileTransferOrderService.java` |
| 2 | `MobileTransferOrderService.java` |
| 3 | `MobileTransferOrderService.java` |
| 4 | `TransferOrderService.java` |
| 5 | `BillofladingService.java` |
| 6 | `TransferOrderService.java` |

### Repository Methods Used

| Method | Type | Used In Phase |
|--------|------|---------------|
| `StockunitRepository.getAmountAvailable()` | Native (existing) | 1 |
| `StockunitRepository.getStockUnitItemIdAndNotLocked()` | Native (existing) | 2 |
| `StockunitRepository.findByUnitloadIdIn()` | JPQL (existing) | 4 |
| `UnitloadRepository.getBatchLocationsByItemIdAndLaneName()` | Native (existing) | 4 |
| `FixLocationAssignmentRepository.findByAssignedlocationId()` | JPQL (existing) | 5 |
| `*Repository.findAllById()` | Spring Data (built-in) | 2, 3, 4, 6 |

No new repository methods need to be created. All optimizations use existing queries and Spring Data built-in `findAllById()`.
