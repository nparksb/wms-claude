# closeBOL() Performance Optimization Plan

## Current State

The `BillofladingService.closeBOL()` method (`BillofladingService.java:250-511`) processes Bill of Lading closure — updating states, building web service DTOs, transferring unit loads to SHIPPED, and updating entity locks.

For a typical BOL with **5 pallets, 50 parcels, 200 line items**, it generates **~2,160 database queries** due to N+1 patterns across a 3-level nested loop.

## Query Breakdown

| Section | Lines | Queries | % |
|---------|-------|---------|---|
| Pallet identification scan | 319-326 | ~255 | 12% |
| Parcel loop (entity fetches) | 352-388 | ~400 | 19% |
| Position loop (entity fetches) | 389-411 | ~850 | 39% |
| `transferUnitLoadToLocation` recursive | 429 | ~330 | 15% |
| Entity lock update loop | 430-443 | ~215 | 10% |
| Orphan position re-check | 413-423 | ~75 | 3% |
| Redundant re-fetches | various | ~60 | 3% |

## Root Cause

The method was written as a direct transliteration of the business process into code — "for each pallet, for each parcel, for each position, load and update one-by-one." This results in O(N) database round-trips at every level of the hierarchy where O(1) bulk operations could be used.

Three core problems:
1. **No pre-loading**: Each entity fetched individually by ID inside nested loops
2. **Redundant re-fetches**: Entities fetched, then immediately re-fetched
3. **Individual saves**: State changes done one `save()` at a time instead of bulk UPDATEs

---

## Optimizations

### P1. Replace pallet identification scan with direct query
**~250 queries eliminated | 5 min | zero risk**

**Problem**: Lines 319-326 iterate ALL BOL positions (pallets + parcels + items) calling `findById(carrierId)` for each to identify top-level pallets.

**Solution**: Build an in-memory position tree from the already-loaded positions. Group by `carrierId` — positions with `carrierId == null` (or carrier not in the loaded set) are pallets.

**Files changed**: `BillofladingService.java`

### P2. Bulk JPQL UPDATE for entity locks
**~215 queries eliminated | 30 min | low risk**

**Problem**: Lines 430-443 loop through each pallet's children, calling `findById`, `save` on each unitload and stockunit to set `entityLock`.

**Solution**: Add bulk update repository methods:
```java
// UnitloadRepository
@Modifying
@Query(value = "UPDATE unitload SET entity_lock = :lock, version = version + 1 WHERE id IN (:ids)", nativeQuery = true)
void updateEntityLockByIds(@Param("lock") Integer lock, @Param("ids") Collection<Long> ids);

// StockunitRepository
@Modifying
@Query(value = "UPDATE stockunit SET entity_lock = :lock, version = version + 1 WHERE unitload_id IN (:unitloadIds)", nativeQuery = true)
void updateEntityLockByUnitloadIds(@Param("lock") Integer lock, @Param("unitloadIds") Collection<Long> unitloadIds);
```

Collect all unitload IDs during processing, execute 2 bulk updates. Requires `entityManager.flush()` + `clear()` afterward.

**Files changed**: `UnitloadRepository.java`, `StockunitRepository.java`, `BillofladingService.java`

### P3. Bulk JPQL UPDATE for state changes
**~500-600 queries eliminated | 1 hour | medium risk**

**Problem**: Lines 341-420 individually save each BOL position, customer order, and customer order position to set state.

**Solution**: Add bulk update repository methods:
```java
// BillofladingPositionRepository
@Modifying
@Query(value = "UPDATE billoflading_position SET state = :state, version = version + 1 WHERE billoflading_id = :bolId", nativeQuery = true)
void updateStateByBillofladingId(@Param("state") String state, @Param("bolId") Long bolId);

// CustomerorderRepository
@Modifying
@Query(value = "UPDATE customerorder SET state = :state, version = version + 1 WHERE id IN (:ids)", nativeQuery = true)
void updateStateByIds(@Param("state") Integer state, @Param("ids") Collection<Long> ids);

// CustomerorderPositionRepository
@Modifying
@Query(value = "UPDATE customerorder_position SET state = :state, version = version + 1 WHERE order_id IN (:orderIds)", nativeQuery = true)
void updateStateByOrderIds(@Param("state") Integer state, @Param("orderIds") Collection<Long> orderIds);
```

The DTO-building loop still reads entities, but all writes become 3 queries total.

**Files changed**: `BillofladingPositionRepository.java`, `CustomerorderRepository.java`, `CustomerorderPositionRepository.java`, `BillofladingService.java`

### P4. Pre-load all entities in bulk before loops
**~500 queries eliminated | 2-3 hours | medium risk**

**Problem**: Lines 352-411 fetch entities individually inside nested loops: `findById` for each customerorder, unitload, batch, client, shipperid, order position, and itemdata.

**Solution**: Before entering the pallet loop:
1. Build in-memory position tree from loaded BOL positions (group by `carrierId`)
2. Extract all FK IDs from positions (orderId, sourceId, orderpositionId, etc.)
3. Bulk fetch with `findAllById()` (~8 queries total)
4. Build `Map<Long, Entity>` lookup tables
5. Iterate tree using map lookups instead of individual `findById()`

**Files changed**: `BillofladingService.java`

### P5. Remove orphan position re-check
**~50 queries eliminated | 10 min | low risk**

**Problem**: Lines 413-423 re-fetch all `CustomerorderPosition` rows per order to find non-FINISHED ones and force them to FINISHED.

**Solution**: With P3's bulk UPDATE (`updateStateByOrderIds`), all positions for all orders in the BOL are set to FINISHED in one query. This entire block becomes unnecessary.

**Files changed**: `BillofladingService.java`

### P6. Eliminate redundant re-fetches
**~60 queries eliminated | 30 min | low risk**

**Problem**: Several locations re-fetch entities that were just loaded:
- Line 354: re-fetches BOL position just returned by `findByCarrierId`
- Line 430: re-fetches pallet just transferred
- Line 434: re-queries children already queried inside `processTransfer`
- Line 500: re-fetches batch entities already loaded at line 362

**Solution**: Use pre-loaded entity maps (from P4) and avoid re-fetching after transfer.

**Files changed**: `BillofladingService.java`

### P7. Optimize `transferUnitLoadToLocation` (bulk transfer)
**~300 queries eliminated | 4-6 hours | high risk**

**Problem**: `processTransfer()` (UnitloadBusinessService:209-228) is recursive — 6 queries per tree node (findById, save, getNextId, findTypeById, saveRecord, findChildren). For 5 pallets with 10 parcels each: 55 nodes × 6 = 330 queries.

**Solution**: Add a `transferPalletTreesToLocation()` method to `UnitloadBusinessService`:
1. Validate destination location constraints (once)
2. BFS traversal to flatten all pallet trees (1-2 bulk queries for children)
3. Bulk UPDATE `storagelocation_id` for all unitloads (1 query)
4. Get sequence IDs in bulk (1 query)
5. Pre-load UnitloadTypes (1 query)
6. Build all UnitloadRecord objects in memory
7. `saveAll()` records (1 batch insert)

Converts ~330 queries to ~6 queries.

```java
// UnitloadRepository
@Modifying
@Query(value = "UPDATE unitload SET storagelocation_id = :locationId, version = version + 1 WHERE id IN (:ids)", nativeQuery = true)
void updateStoragelocationByIds(@Param("locationId") Long locationId, @Param("ids") Collection<Long> ids);

// UnitloadRecordRepository
@Query(value = "SELECT nextval('seqentities') FROM generate_series(1, :count)", nativeQuery = true)
List<Long> getNextIds(@Param("count") int count);
```

The existing `transferUnitLoadToLocation()` remains unchanged (shared code used elsewhere).

**Files changed**: `UnitloadBusinessService.java`, `UnitloadRepository.java`, `UnitloadRecordRepository.java`

### P8. Enable JDBC batch_size
**Global improvement | 5 min | zero code risk**

**Problem**: No Hibernate JDBC batching configured. Individual `save()` and `saveAll()` calls generate individual SQL statements.

**Solution**: Add to `application.properties`:
```properties
spring.jpa.properties.hibernate.jdbc.batch_size=50
spring.jpa.properties.hibernate.order_inserts=true
spring.jpa.properties.hibernate.order_updates=true
```

**Files changed**: `application.properties`

---

## Implementation Approach

### New closeBOL() structure:
```
1. Validate BOL state/type (unchanged)
2. Load all BOL positions (1 query)
3. Build in-memory position tree (zero queries)
4. Delete garbage positions (1 bulk DELETE)
5. Bulk pre-load all referenced entities (~8 queries)
6. Iterate tree to build DTOs (zero queries - map lookups)
7. Bulk transfer pallet trees to SHIPPED (~6 queries)
8. Bulk UPDATE: BOL position states (1 query)
9. Bulk UPDATE: customer order states (1 query)
10. Bulk UPDATE: customer order position states (1 query)
11. Bulk UPDATE: unitload entity locks (1 query)
12. Bulk UPDATE: stockunit entity locks (1 query)
13. Save billOfLading state (1 query)
14. entityManager.flush() + clear()
15. Web service call (uses DTOs, no DB)
16. Batch state finalization (~5 queries)
```

### EntityManager for flush/clear:
```java
@PersistenceContext
private EntityManager entityManager;
```
Required after bulk JPQL UPDATEs to avoid stale persistence context.

---

## Expected Results

| Scenario | Queries | Reduction |
|----------|---------|-----------|
| **Current** | ~2,160 | — |
| After P1-P3, P5-P6 (quick wins) | ~600 | 72% |
| After P1-P6 (without transfer rewrite) | ~350 | 84% |
| After ALL (P1-P8) | ~30-50 | **97-98%** |

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Bulk UPDATEs bypass optimistic locking | Use `version = version + 1` in all bulk UPDATEs |
| Stale persistence context | `entityManager.flush()` + `clear()` after bulk UPDATEs |
| Bulk transfer skips per-node validation | Validation moved to per-pallet level (location constraints checked per pallet type) |
| Entity loading failure from maps | `.get()` with proper null checks and BusinessException on missing entities |
| Memory pressure from bulk pre-loading | Acceptable for BOL sizes (typically <1000 positions) |

## Files Modified

| File | Changes |
|------|---------|
| `BillofladingPositionRepository.java` | Add `updateStateByBillofladingId`, `deleteGarbageByBillofladingId` |
| `CustomerorderRepository.java` | Add `updateStateByIds` |
| `CustomerorderPositionRepository.java` | Add `updateStateByOrderIds` |
| `UnitloadRepository.java` | Add `updateEntityLockByIds`, `updateStoragelocationByIds`, `findAllByCarrierunitloadIdIn` |
| `StockunitRepository.java` | Add `updateEntityLockByUnitloadIds` |
| `UnitloadRecordRepository.java` | Add `getNextIds` |
| `UnitloadBusinessService.java` | Add `transferPalletTreesToLocation` |
| `BillofladingService.java` | Rewrite `closeBOL()` |
| `application.properties` | Add `hibernate.jdbc.batch_size` |
