# Entity Comparison Fix Plan — Post Spring Boot 3.5.9 / Hibernate 6 Upgrade

## Current Status (Updated 2026-02-08)

| Phase | Status | Commit | Details |
|-------|--------|--------|---------|
| **Quick-Win** | DONE | `9987486` | 4 critical call sites fixed with ID-based comparison |
| **Phase 1** | DONE | `5f27ee4` | 7 critical entities + Location fix |
| **Phase 2** | DONE | `fc97d79` | Remaining 54 entities (all 61 covered) |
| **Phase 3** | DONE | `51251b9` | 14 remaining call sites converted to ID-based |
| **Phase 4** | DONE | `7b0bbb0` | 15 @Transactional, stale entity fix, 9 @Modifying(clearAutomatically) |
| **Phase 5** | DONE | `bf07b55` | 554 new contract tests, 3249 total tests pass |
| **Phase 6** | DONE | `pending` | closeBOL() concurrency fix — pessimistic locking, thread-safe bolToClose, entity refresh |

**Test Results:** 3249 tests pass, 0 failures across all phases.

### Phase 6: closeBOL() Concurrency Fix

**Problem:** `ObjectOptimisticLockingFailureException` at `BillofladingService.java:427` when `closeBOL()` called concurrently.

**Root Causes:**
1. `bolToClose` used non-thread-safe `ArrayList` with race condition (check-then-act)
2. No database-level locking to prevent concurrent closeBOL on the same BOL
3. Stale entity versions after `processTransfer` recursively saves unitloads

**Fixes Applied:**
| Fix | File | Change |
|-----|------|--------|
| Thread-safe bolToClose | `BillofladingService.java` | `ArrayList` → `ConcurrentHashMap.newKeySet()`, atomic `add()`, `try-finally` cleanup |
| Pessimistic BOL lock | `BillofladingRepository.java` | Added `findByIdForUpdate()` with `@Lock(PESSIMISTIC_WRITE)` |
| Pessimistic lock in closeBOL | `BillofladingService.java` | `SELECT ... FOR UPDATE` on BOL row at start of closeBOL() |
| Entity refresh | `BillofladingService.java` | `entityManager.refresh()` on unitloads/stockunits before modifying entityLock |
| finishTransfer hardened | `BillofladingService.java` | Same pessimistic lock + entity refresh pattern applied |
| Test mocks updated | `BillofladingServiceUnitTest.java` | Added EntityManager mock + findByIdForUpdate mocks |

---

## Executive Summary

After upgrading from **Java 8 / Spring Boot 2.7.14 / Hibernate 5** to **Java 21 / Spring Boot 3.5.9 / Hibernate 6**, entity identity comparison was broken across the codebase. **60 out of 61 JPA entities** lacked custom `equals()` / `hashCode()` implementations, and the **1 entity that had them** (`Location`) used the proxy-unsafe `getClass()` pattern.

The codebase relied heavily on reference-based entity comparison via `.equals()`, `.contains()`, `.removeAll()`, and `HashMap`/`HashSet` operations — all of which silently failed under Hibernate 6's stricter proxy and persistence context behavior.

### Impact (Now Resolved)

| Category | Before | After |
|----------|--------|-------|
| Entities with proxy-safe equals/hashCode | 0 of 61 | **61 of 61** |
| Service-layer entity comparisons at risk | 25+ locations | **0** |
| Controller-layer entity comparisons at risk | 3+ locations | **0** |
| Collection operations on entities (contains/remove/removeAll) | 15+ locations | **0** |
| Entities used as Map keys | 2+ locations | **0** |

---

## Root Cause Analysis

### Why This Worked in Hibernate 5 But Breaks in Hibernate 6

1. **First-level cache identity** — In Hibernate 5, `findById()` within the same transaction often returned the **same Java object reference**, making `==` and default `Object.equals()` (reference equality) work by accident. Hibernate 6 is stricter about when it returns cached vs fresh instances.

2. **Proxy behavior changes** — Hibernate 6 creates proxies more aggressively. A `findById()` may return a proxy while a `findByXxx()` returns the real entity. `proxy.equals(entity)` fails with default `Object.equals()` because they are different Java objects.

3. **Native query cache bypass** — The codebase has **41+ repositories with native queries** (`nativeQuery=true`). Native queries bypass the first-level cache entirely, so the same row returns a different Java object.

4. **Entity model uses Long FK IDs** — All relationships are modeled as `Long foreignKeyId` fields rather than `@ManyToOne` associations. This forces manual re-fetching of related entities, increasing the chance of getting different object instances for the same database row.

---

## Detailed Findings — All At-Risk Locations

### CRITICAL — Collection Operations on Entities

| # | File | Line | Code | Entity | Risk |
|---|------|------|------|--------|------|
| 1 | `CustomerorderBatchService.java` | 465 | `stockUnits.removeAll(emptyOrMovedStockUnits)` | Stockunit | `removeAll` depends on equals — re-fetched entities won't match, items remain in list, causing **duplicate processing / data corruption** |
| 2 | `CustomerorderBatchService.java` | 388 | `stockUnits.contains(stockUnit)` | Stockunit | Deduplication fails — same stock unit added multiple times |
| 3 | `CustomerorderBatchService.java` | 137 | `itemDataList.contains(itemData)` | Itemdata | SKU deduplication fails — replenishment triggered for same item multiple times |
| 4 | `CustomerorderBatchService.java` | 155 | `batchOrders.contains(order)` | Customerorder | Priority logic skips valid orders or processes duplicates |
| 5 | `GoodsReceiptPositionService.java` | 120 | `stockUnitList.contains(posStockUnit)` | Stockunit | Validation incorrectly throws "StockUnit not on UnitLoad" |
| 6 | `PickingorderBusinessService.java` | 132 | `customerOrderSet.contains(customerOrder)` | Customerorder | Set deduplication fails — same order processed multiple times |
| 7 | `TransferOrderService.java` | 243 | `ulWithoutCarrier.contains(unitLoad)` | Unitload | Deduplication fails — duplicate unit loads in transfer list |
| 8 | `CustomerorderBatchService.java` | 504 | `availableStagingLanes.contains(stagingLane)` | Location | Staging lane validation incorrectly rejects valid lanes |
| 9 | `MobilePutAwayService.java` | 271 | `locationList.contains(location)` | Location | Location deduplication fails — duplicate put-away suggestions |

### HIGH — Entity-to-Entity `.equals()` Comparisons

| # | File | Line | Code | Entity | Risk |
|---|------|------|------|--------|------|
| 10 | `OrderRestController.java` | 815 | `cob.equals(customerOrderBatch)` | CustomerorderBatch | REST API rejects valid orders with "CHILD_NOT_PART_OF_PARENT" — **external integration breakage** |
| 11 | `BillofladingService.java` | 550 | `unitLoad.equals(pallet) \|\| unitLoad.equals(parcel)` | Unitload | Stock combination logic broken — skips valid or processes invalid unit loads |
| 12 | `ReceivingService.java` | 549 | `pallet.equals(newPallet)` | Unitload | Pallet update logic broken — unnecessary unassign/reassign operations |
| 13 | `StockunitBusinessService.java` | 160 | `destFirstItemdata.equals(sourceStockunitItemdata)` | Itemdata | Mixed stock validation broken — allows mixed stock or rejects valid transfers |
| 14 | `TransferOrderService.java` | 294 | `suItemData.equals(itemData)` | Itemdata | Stock calculation wrong — misses matching items, returns incorrect amounts |
| 15 | `ReplenishOrderJobService.java` | 126 | `assignedUnitLoadStorageLocation.equals(assignedLocation)` | Location | Replenishment incorrectly flags unit loads as "on wrong location" |
| 16 | `CustomerorderBatchService.java` | 871 | `itemData.equals(itemDataMap.get(...))` | Itemdata | Stock sum calculation wrong — misses matching stock units |

### MEDIUM — Entities Used as Map Keys

| # | File | Line | Code | Entity | Risk |
|---|------|------|------|--------|------|
| 17 | `TransferOrderService.java` | 248 | `Map<Unitload, Integer> unitLoadIntegerMap` | Unitload | Map lookups fail — same unit load stored under multiple keys |
| 18 | `CustomerorderBatchService.java` | 387 | `itemDataListMap.computeIfAbsent(itemData, ...)` | Itemdata | Map fragmentation — same SKU gets multiple entries |

### LOW — Existing `Location.equals()` is Proxy-Unsafe

| # | File | Line | Code | Issue |
|---|------|------|------|-------|
| 19 | `Location.java` | 221 | `getClass() != o.getClass()` | Uses `getClass()` which fails when comparing a Hibernate proxy with the real entity. Must use `instanceof`. |
| 20 | `Location.java` | 223 | `xpos.equals(location.xpos)` | Accesses fields directly instead of via getters. Proxy fields are uninitialized — **must use getters**. |
| 21 | `Location.java` | 228 | `Objects.hash(id, ...)` | Uses `id` in hashCode — this changes after persist, breaking HashSet/HashMap contracts. |

---

## Phased Fix Plan

### Phase 0: Preparation (Estimated: 1 day)

**Goal:** Establish the base entity `equals()`/`hashCode()` pattern and test infrastructure.

#### 0.1 — Define the Standard Pattern

Create a reusable base class or documented pattern for all entities:

```java
// Recommended pattern: ID-based equals with instanceof (proxy-safe)
@Override
public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof Itemdata other)) return false;  // instanceof, NOT getClass()
    return getId() != null && getId().equals(other.getId());  // use GETTERS, not fields
}

@Override
public int hashCode() {
    // FIXED value — never use id in hashCode (changes on persist)
    return getClass().hashCode();
}
```

**Why this pattern:**
- `instanceof` works with Hibernate proxies (a proxy `instanceof Itemdata` is true)
- Getters trigger proxy initialization (direct field access returns null on proxies)
- Fixed `hashCode()` ensures entity can be used in HashSet/HashMap before and after persist
- `getId() != null` guard prevents two transient (unsaved) entities from being falsely equal

#### 0.2 — Create a Utility Class

```java
public class EntityUtils {
    /**
     * Safely compare two entities by ID, handling proxies and null.
     */
    public static boolean isSameEntity(BasicEntity a, BasicEntity b) {
        if (a == b) return true;
        if (a == null || b == null) return false;
        if (a.getId() == null || b.getId() == null) return false;
        return a.getId().equals(b.getId());
    }
}
```

#### 0.3 — Add Test Infrastructure

Create a reusable test that validates `equals()`/`hashCode()` contracts for all entities:
- Reflexive: `a.equals(a)` is true
- Symmetric: `a.equals(b)` ↔ `b.equals(a)`
- Consistent hashCode: equal objects have equal hash codes
- Null-safe: `a.equals(null)` is false
- Works with new (transient) entities

---

### Phase 1: Fix Critical Entities (Estimated: 2-3 days)

**Goal:** Add `equals()`/`hashCode()` to the 8 entities involved in the most dangerous comparisons.

**Priority order** (by number of at-risk locations and severity):

| Priority | Entity | At-Risk Locations | Impact |
|----------|--------|-------------------|--------|
| P0 | `Itemdata` | 5 locations | Stock calculations, mixed-stock validation, SKU dedup |
| P0 | `Stockunit` | 3 locations | removeAll failure, contains checks, data corruption |
| P0 | `Unitload` | 4 locations | Map keys, contains checks, equals comparisons |
| P0 | `Customerorder` | 3 locations | Set dedup, batch contains, order processing |
| P1 | `CustomerorderBatch` | 1 location | REST API integration breakage |
| P1 | `Pickingorder` | 1 location | HashSet deduplication |
| P1 | `Location` (FIX existing) | 3 locations | Staging lane validation, put-away, replenishment |

#### 1.1 — Implement `equals()`/`hashCode()` for P0 Entities

For each of `Itemdata`, `Stockunit`, `Unitload`, `Customerorder`:

```java
// Example: Itemdata.java
@Override
public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof Itemdata other)) return false;
    return getId() != null && getId().equals(other.getId());
}

@Override
public int hashCode() {
    return getClass().hashCode();
}
```

#### 1.2 — Fix `Location.java` equals/hashCode

Replace the existing broken implementation:

**Before (BROKEN):**
```java
if (o == null || getClass() != o.getClass()) return false;  // fails with proxy
Location location = (Location) o;
return xpos.equals(location.xpos) && ...;  // direct field access fails with proxy
```

**After (FIXED):**
```java
if (!(o instanceof Location other)) return false;  // proxy-safe
return getId() != null && getId().equals(other.getId());  // ID-based, getter access
```

Also fix `hashCode()` to use fixed value instead of `Objects.hash(id, ...)`.

#### 1.3 — Implement P1 Entities

Add `equals()`/`hashCode()` to `CustomerorderBatch` and `Pickingorder` using the same pattern.

#### 1.4 — Write Unit Tests for Phase 1 Entities

For each entity, test:
- Two instances with same ID are equal
- Two instances with different IDs are not equal
- Transient instance (null ID) is not equal to anything
- Works correctly in `HashSet` and `HashMap`
- `contains()` / `remove()` / `removeAll()` work on `ArrayList`

---

### Phase 2: Fix Remaining Entities (Estimated: 2-3 days)

**Goal:** Add `equals()`/`hashCode()` to all remaining 53 entities to prevent future issues.

#### 2.1 — Batch Implementation by Category

| Category | Entities | Count |
|----------|----------|-------|
| Transactional | Billoflading, Advice, AdvicePosition, ReplenishOrder, etc. | ~14 |
| Inventory | InventoryRecord, FixedLocationAssignment, etc. | ~5 |
| Master Data | Client, Section, LocationArea, LocationRack, etc. | ~12 |
| System | Message, User, Printer, SystemProperty, etc. | ~11 |
| View/Monitor | OrderMonitorView, StockView, etc. | ~10 |

#### 2.2 — Prioritize by Usage

1. **First:** Entities used in service-layer collections or comparisons
2. **Second:** Entities used in controller/REST layer
3. **Third:** Read-only view entities (lowest risk but still fix for consistency)

#### 2.3 — Unit Tests

Add batch parameterized tests that validate all entities follow the contract.

---

### Phase 3: Fix Comparison Call Sites (Estimated: 2-3 days)

**Goal:** For the most critical call sites, convert from entity `.equals()` to explicit **ID-based comparison** as a defense-in-depth measure. This makes the code self-documenting and immune to future equals/hashCode changes.

#### 3.1 — Convert Critical `.equals()` to ID Comparison

| File | Line | Before | After |
|------|------|--------|-------|
| `OrderRestController.java` | 815 | `cob.equals(customerOrderBatch)` | `cob.getId().equals(customerOrderBatch.getId())` |
| `BillofladingService.java` | 550 | `unitLoad.equals(pallet)` | `unitLoad.getId().equals(pallet.getId())` |
| `ReceivingService.java` | 549 | `pallet.equals(newPallet)` | `pallet.getId().equals(newPallet.getId())` |
| `StockunitBusinessService.java` | 160 | `destFirstItemdata.equals(sourceStockunitItemdata)` | `destFirstItemdata.getId().equals(sourceStockunitItemdata.getId())` |
| `TransferOrderService.java` | 294 | `suItemData.equals(itemData)` | `suItemData.getId().equals(itemData.getId())` |
| `ReplenishOrderJobService.java` | 126 | `assignedUnitLoadStorageLocation.equals(assignedLocation)` | `assignedUnitLoadStorageLocation.getId().equals(assignedLocation.getId())` |
| `CustomerorderBatchService.java` | 871 | `itemData.equals(itemDataMap.get(...))` | `itemData.getId().equals(itemDataMap.get(...).getId())` |

#### 3.2 — Convert `.contains()` on Entity Lists to ID-Based Checks

| File | Line | Before | After |
|------|------|--------|-------|
| `CustomerorderBatchService.java` | 137 | `itemDataList.contains(itemData)` | `itemDataList.stream().anyMatch(i -> i.getId().equals(itemData.getId()))` |
| `CustomerorderBatchService.java` | 155 | `batchOrders.contains(order)` | `batchOrders.stream().anyMatch(o -> o.getId().equals(order.getId()))` |
| `GoodsReceiptPositionService.java` | 120 | `stockUnitList.contains(posStockUnit)` | `stockUnitList.stream().anyMatch(su -> su.getId().equals(posStockUnit.getId()))` |
| `PickingorderBusinessService.java` | 132 | `customerOrderSet.contains(customerOrder)` | Use `Set<Long>` of IDs instead |

#### 3.3 — Convert `removeAll()` to ID-Based Removal

| File | Line | Before | After |
|------|------|--------|-------|
| `CustomerorderBatchService.java` | 465 | `stockUnits.removeAll(emptyOrMovedStockUnits)` | `Set<Long> idsToRemove = emptyOrMovedStockUnits.stream().map(Stockunit::getId).collect(Collectors.toSet()); stockUnits.removeIf(su -> idsToRemove.contains(su.getId()));` |

#### 3.4 — Convert Entity Map Keys to ID Keys

| File | Line | Before | After |
|------|------|--------|-------|
| `TransferOrderService.java` | 248 | `Map<Unitload, Integer>` | `Map<Long, Integer>` (keyed by unitload ID) |
| `CustomerorderBatchService.java` | 387 | `Map<Itemdata, List<Stockunit>>` | `Map<Long, List<Stockunit>>` (keyed by itemdata ID) |

---

### Phase 4: Transaction & Persistence Context Hardening (Estimated: 1-2 days)

**Goal:** Ensure transaction boundaries are correct and reduce stale entity issues.

#### 4.1 — Add Missing `@Transactional` Annotations

Review and add `@Transactional(rollbackFor = Exception.class)` to service methods that:
- Call multiple repository methods
- Perform read-then-write operations
- Currently lack any `@Transactional` annotation

Key targets:
- `ReceivingService` methods
- `CustomerorderBatchService.runClubLine()`

#### 4.2 — Fix Stale Entity Usage

| File | Line | Issue | Fix |
|------|------|-------|-----|
| `StockunitBusinessService.java` | ~245 | Uses `sourceStockunit.getAmount()` instead of `freshSourceStockunit.getAmount()` | Use the re-fetched entity's value |

#### 4.3 — Add `clearAutomatically = true` to `@Modifying` Queries

For native `@Modifying` queries that UPDATE/DELETE rows, add `clearAutomatically = true` to ensure the persistence context doesn't hold stale data:

```java
@Modifying(clearAutomatically = true)
@Query(value = "UPDATE ...", nativeQuery = true)
void updateSomething(...);
```

---

### Phase 5: Validation & Regression Testing (Estimated: 2-3 days)

**Goal:** Ensure all fixes work correctly and no regressions are introduced.

#### 5.1 — Entity Contract Tests

- Parameterized test covering all 61 entities
- Validates equals/hashCode contract (reflexive, symmetric, transitive, consistent)
- Tests with `HashSet`, `HashMap`, `ArrayList.contains()`

#### 5.2 — Integration Tests for Critical Paths

- **Stock allocation** — verify `removeAll` correctly removes processed stock units
- **Order batch processing** — verify `contains` correctly deduplicates
- **REST API** — verify `cob.equals(customerOrderBatch)` works across persistence contexts
- **Bill of lading** — verify `combineStock` correctly skips pallet/parcel
- **Receiving** — verify `updatePallet` correctly detects same vs different pallet
- **Transfer orders** — verify stock calculation matches expected amounts

#### 5.3 — Existing Test Suite

- Run full `mvn clean package` to ensure no regressions
- Verify all existing tests pass

---

## Summary Timeline

| Phase | Scope | Effort | Status |
|-------|-------|--------|--------|
| **Quick-Win** | 4 critical call sites | done | DONE `9987486` |
| **Phase 1** | 7 critical entities | done | DONE `5f27ee4` |
| **Phase 2** | Remaining 54 entities | done | DONE `fc97d79` |
| **Phase 3** | 18 comparison call sites | done | DONE `51251b9` |
| **Phase 4** | Transaction hardening | done | DONE `7b0bbb0` |
| **Phase 5** | Validation & testing | done | DONE `bf07b55` |
| **Phase 6** | closeBOL() concurrency fix | done | DONE |
