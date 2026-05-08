# Receiving Process Performance Improvement Plan

**Date:** 2026-02-22
**Branch:** `v2-tmp/np51-receiving-formance`
**Status:** All phases complete (1–4)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current Architecture](#2-current-architecture)
3. [Bottleneck Analysis](#3-bottleneck-analysis)
4. [Improvement Plan](#4-improvement-plan)
5. [Implementation Phases](#5-implementation-phases)
6. [Risk Assessment](#6-risk-assessment)

---

## 1. Executive Summary

The receiving process (`ReceivingService.receiveGoods()`) is the most query-intensive hot path in the WMS. For a single HTTP request receiving **N cases**, the current implementation executes approximately **15–20 database queries per case**, resulting in **750–1,000 queries for a 50-case receive** — all within a single `@Transactional` boundary that also includes network calls to a CUPS printer.

Additionally, several critical receiving methods (`AdviceService.close()`, `acceptTransferAdvice()`, `acceptHubAndSpokeAdvice()`) lack `@Transactional` annotations entirely, risking partial data corruption under failure conditions.

In a multi-threaded environment, the over-delivery check in `receiveGoods()` has a TOCTOU (time-of-check-time-of-use) race condition — two concurrent receives for the same advice position can both pass validation and cause over-delivery.

### Estimated Impact

| Optimization | Query Reduction | Effort |
|---|---|---|
| Pre-fetch immutable lookups before loop | ~30% (eliminate ~5 repeated queries/iteration) | Low |
| Replace count-by-full-list with counter variable | ~15% (eliminate growing SELECT per iteration) | Low |
| Batch entity saves (`saveAll()`) | ~20% (reduce individual INSERTs) | Medium |
| Move printer calls outside transaction | N/A (reduces DB connection hold time) | Medium |
| Fix missing `@Transactional` | N/A (data integrity fix) | Low |
| Add pessimistic lock for over-delivery | N/A (concurrency fix) | Medium |

**Combined estimate: 60–70% query reduction** on the `receiveGoods()` hot path (similar to the `closeBOL()` optimization already applied).

---

## 2. Current Architecture

### 2.1 Receiving Workflows

There are four distinct receiving paths:

| Path | Entry Point | Trigger | Auto-Receives? |
|---|---|---|---|
| **Regular** | `ReceivingController.receive()` | User scans at workstation | No (manual) |
| **Return** | `AdviceRestController.create()` | OMS sends return advice | Yes (auto per position) |
| **Transfer** | `AdviceRestController.createTransfer()` | Inter-warehouse transfer | No (manual via Path A) |
| **Hub-and-Spoke** | `AdviceRestController.createHubAndSpoke()` | Hub warehouse routing | No (accept creates orders) |

All four paths eventually call `ReceivingService.receiveGoods()` for the actual goods receipt.

### 2.2 Key Files

| File | Role |
|---|---|
| `ReceivingService.java` | Core: `receiveGoods()` (line 289–548), `createAdviceWithPositions()`, pallet mgmt |
| `AdviceService.java` | Close advice, accept transfer/hub-and-spoke BOLs |
| `UnitloadService.java` | `createUnitload()` — creates unitload + audit record |
| `StockunitBusinessService.java` | `createStockUnit()` — creates stock unit + stock record |
| `UnitloadBusinessService.java` | `transferUnitLoadToLocation/Carrier()` — moves unitloads |
| `BasicService.java` | Sequence number generation (`generateNumber`, `generateNumberWithGoodsReceipt`) |

### 2.3 The `receiveGoods()` Flow (Critical Path)

```
receiveGoods(advicePositionId, carrierUnitLoadId, storeOnCarrier,
             amountBottles, amountBottlesPerCase, amountCases, boxtypeId, printer)

  ┌─ VALIDATION PHASE (one-time lookups) ──────────────────────────────┐
  │  printService.isPrintAvailable()          ← NETWORK CALL          │
  │  syspropRepository.findSysvalue...()      ← config lookup         │
  │  advicepositionRepository.findById()                               │
  │  boxtypeRepository.findById()                                      │
  │  itemdataRepository.findById()                                     │
  │  userRepository.findByName()                                       │
  │  adviceRepository.findById()                                       │
  │  clientRepository.findById()                                       │
  │  goodsreceiptpositionRepo.findByAdvicepositionId()  ← over-delivery│
  │  locationRepository.findByName("InboundWorkstation") ← FETCHED 2x │
  │  unitloadTypeRepository.findById()                                 │
  │  goodsreceiptRepository.findByAdviceId()                           │
  │  goodsreceiptRepository.save()  ← create if first                 │
  │  locationRepository.findByName("InboundWorkstation") ← DUPLICATE  │
  │  syspropRepository (warehouse name)                                │
  └────────────────────────────────────────────────────────────────────┘

  ┌─ PER-CASE LOOP (N iterations) ─────────────────────────────────────┐
  │  while (amountBottles > 0) {                                       │
  │    unitloadService.createUnitload()                                │
  │      ├─ basicService.generateNumber()  → sequence table query      │
  │      ├─ unitloadRepository.findByLabelid()  ← existence check     │
  │      ├─ unitloadRepository.save()  ← INSERT                       │
  │      ├─ locationRepository.findByName("Spawn")  ← SAME EVERY TIME │
  │      └─ unitloadRecordService.record...()  ← INSERT               │
  │    unitloadRepository.save()  ← SET boxtype                        │
  │    stockunitBusinessService.createStockUnit()                      │
  │      ├─ stockunitRepository.save()  ← INSERT                      │
  │      ├─ locationRepository.findById()  ← unitload location         │
  │      ├─ unitloadTypeRepository.findNameById()  ← type name lookup  │
  │      └─ stockrecordRepository.save()  ← INSERT                    │
  │    basicService.generateNumberWithGoodsReceipt()                   │
  │      └─ goodsreceiptpositionRepo.findByGoodsreceiptId()            │
  │         ← LOADS ALL GRPs JUST TO COUNT (grows each iteration!)     │
  │    goodsreceiptpositionRepository.save()  ← INSERT                 │
  │    transferUnitLoadToLocation/Carrier()                            │
  │      ├─ unitloadRepository.save()  ← UPDATE location              │
  │      ├─ unitloadRecordService.record...()  ← INSERT               │
  │      └─ unitloadRepository.findByCarrierunitloadId()  ← children  │
  │    sharedService.createCaseLabel()  ← label bytes                  │
  │  }                                                                 │
  └────────────────────────────────────────────────────────────────────┘

  ┌─ POST-LOOP ────────────────────────────────────────────────────────┐
  │  messageService.sendStockChangeMessage()                           │
  │  printService.cupsPrint()  ← NETWORK CALL inside @Transactional   │
  └────────────────────────────────────────────────────────────────────┘
```

**Per-case query count: ~15–20 queries. For 50 cases: ~750–1,000 queries.**

---

## 3. Bottleneck Analysis

### 3.1 N+1 Query in `generateNumberWithGoodsReceipt()` — CRITICAL

**File:** `BasicService.java:76–82`

```java
public String generateNumberWithGoodsReceipt(Goodsreceipt goodsReceipt) {
    List<Goodsreceiptposition> grPositions =
        goodsreceiptpositionRepository.findByGoodsreceiptId(goodsReceipt.getId());
    String number = String.format(prefix + getFormat(), grPositions.size());
    ...
}
```

Called once per case in the loop. Loads the **full list of `Goodsreceiptposition` entities** just to get a count. On iteration 1 it loads 1 entity, on iteration 2 it loads 2, ..., on iteration N it loads N. This is **O(N²) entity loading** — the worst single bottleneck.

**Fix:** Replace with a simple counter variable initialized before the loop.

### 3.2 Repeated Immutable Lookups Inside Loop — HIGH

Each loop iteration re-fetches values that never change during the transaction:

| Lookup | Called From | Times/Receive |
|---|---|---|
| `locationRepository.findByName("Spawn")` | `UnitloadService.createUnitload()` | N |
| `locationRepository.findById(itemdata.getPutawaylocationId())` | `receiveGoods()` line 500 | N (when no carrier) |
| `unitloadTypeRepository.findNameById()` | `StockunitBusinessService.createStockUnit()` | N |
| `unitloadRepository.findByCarrierunitloadId()` | `processTransfer()` (child check) | N |

All of these return the same result every iteration and should be fetched once before the loop.

### 3.3 Duplicate Location Fetch — MEDIUM

**File:** `ReceivingService.java:400` and `:440`

```java
// Line 400
Optional<Location> storageLocationOptional =
    locationRepository.findByName(WmsConstants.STORAGE_LOCATION_INBOUND_NAME);
// Line 440
Optional<Location> inboundWorkStationOptional =
    locationRepository.findByName(WmsConstants.STORAGE_LOCATION_INBOUND_NAME);
```

Same location fetched twice with different variable names. One should be removed.

### 3.4 Individual Saves vs. Batch — MEDIUM

Each loop iteration performs individual `save()` calls:
- `unitloadRepository.save()` — 2x per iteration (create + set boxtype)
- `stockunitRepository.save()` — 1x per iteration
- `goodsreceiptpositionRepository.save()` — 1x per iteration
- `stockrecordRepository.save()` — 1x per iteration
- `unitloadRecordService.record...()` — 2x per iteration

That's **~7 individual INSERT/UPDATE** statements per case. With `saveAll()` batching, these could be reduced to bulk operations at the end.

### 3.5 Network Calls Inside `@Transactional` — HIGH (Multi-Thread Impact)

**File:** `ReceivingService.java:302` and `:543`

```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public void receiveGoods(...) {
    // Line 302 — NETWORK CALL at start
    if(!printService.isPrintAvailable(printer.getAddress())) { ... }

    // ... all DB work ...

    // Line 543 — NETWORK CALL at end
    printService.cupsPrint(printer.getAddress(), outputStream.toByteArray());
}
```

The entire `receiveGoods()` method is one `@Transactional` boundary. The CUPS printer calls hold a database connection open during network I/O. If the printer is slow or unreachable (timeout), the DB connection is held for the full timeout period. In a multi-threaded environment with limited DB connections, this can exhaust the connection pool and block all other warehouse operations.

### 3.6 Over-Delivery Race Condition (TOCTOU) — CRITICAL for Concurrency

**File:** `ReceivingService.java:388–396`

```java
if (!advice.getAllowoverdelivery()) {
    List<Goodsreceiptposition> goodsreceiptPositionList =
        goodsreceiptpositionRepository.findByAdvicepositionId(adviceposition.getId());
    int amountReceived = goodsreceiptPositionList.stream()...;
    if (amountReceived + amountBottles > notifiedAmount) {
        throw new BusinessException("Not allowed to receive more than notified!");
    }
}
```

Two concurrent `receiveGoods()` calls for the same advice position can **both read the same `amountReceived` value**, both pass the check, and both proceed — resulting in over-delivery. There is no pessimistic lock, and the advice position entity is never saved/versioned in this method, so optimistic locking doesn't protect against this.

### 3.7 Missing `@Transactional` Annotations — CRITICAL for Data Integrity

| Method | File:Line | Risk |
|---|---|---|
| `createAdviceWithPositions()` | `ReceivingService.java:146` | Advice saved, position save fails → orphan advice |
| `updateAdviceWithPositions()` | `ReceivingService.java:239` | Same orphan risk |
| `close()` | `AdviceService.java:273` | Advice set FINISHED, position updates fail mid-loop → partial close |
| `acceptTransferAdvice()` | `AdviceService.java:379` | Same as close() |
| `acceptHubAndSpokeAdvice()` | `AdviceService.java:133` | Creates pallets, parcels, orders — any failure leaves partial data |

### 3.8 `initialized` Flag Never Set to `true` — LOW (Repeated Init)

**Files:** `StockunitBusinessService.java:73,93–97` and `UnitloadBusinessService.java:78,100–104`

```java
private boolean initialized = false;

private void ensureInitialized() {
    if (!initialized && TenantContext.getCurrentTenant() != null) {
        init();  // init() never sets initialized = true!
    }
}
```

The `initialized` field is declared `false` and never updated. `init()` runs on **every request**, performing unnecessary `findByName("Nirvana")` and `findByLabelid("Nirvana")` lookups.

### 3.9 N+1 in `AdviceService.close()` — MEDIUM

**File:** `AdviceService.java:301–305, 315, 332–341`

Three separate issues in `close()`:
1. **Individual position saves** (line 302–305) instead of using the existing bulk JPQL `updateAdvicepositionToStateByAdviceId()`
2. **Duplicate position list fetch** (line 301 and 315) — same query run twice
3. **N+1 in DTO building** (line 332–341) — `itemdataRepository.findById()` and `goodsreceiptpositionRepository.findByAdvicepositionId()` per position

### 3.10 `resolvePalletByLabelId()` Crash Bug — HIGH

**File:** `ReceivingService.java:561–562`

```java
if(!unitLoadOptional.isPresent()){
    throw new BusinessException("noUnitLoadValuePresent", unitLoadOptional.get().getTypeId(),...);
}
```

When the Optional is empty, `.get()` throws `NoSuchElementException` before the `BusinessException` is constructed. This is a guaranteed crash that masks the real error.

---

## 4. Improvement Plan

### Phase 1: Quick Wins — Data Integrity & Bug Fixes (Low Effort, High Impact)

**Estimated effort: 1–2 days**

#### 1.1 Add Missing `@Transactional` Annotations

Add `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` to:

- `ReceivingService.createAdviceWithPositions()` (line 146)
- `ReceivingService.updateAdviceWithPositions()` (line 239)
- `AdviceService.close()` (line 273)
- `AdviceService.acceptTransferAdvice()` (line 379)
- `AdviceService.acceptHubAndSpokeAdvice()` (line 133)
- `AdviceService.fixHubAndSpokePalletIssues()` (line 114)

**Note:** Verify that none of these methods are called from within the same class (Spring proxy self-invocation issue). If they are, extract to a separate service or use `TransactionTemplate`.

#### 1.2 Fix `resolvePalletByLabelId()` Crash

Replace `unitLoadOptional.get().getTypeId()` with the `number` parameter in the BusinessException constructor to avoid `NoSuchElementException`.

#### 1.3 Fix `initialized` Flag Bug

Add `this.initialized = true;` at the end of `init()` in both:
- `StockunitBusinessService.java`
- `UnitloadBusinessService.java`

Also add a null-check after `init()` to handle the case where the Nirvana entity was not found (currently swallows the error and leaves `nirvanaUnitload = null`).

#### 1.4 Remove Duplicate Location Fetch

Remove `locationRepository.findByName(STORAGE_LOCATION_INBOUND_NAME)` at line 440 and reuse `storageLocation` from line 400.

### Phase 2: `receiveGoods()` Loop Optimization (Medium Effort, High Impact)

**Estimated effort: 3–5 days**

#### 2.1 Replace `generateNumberWithGoodsReceipt()` with Counter

**Before (O(N²) entity loading):**
```java
while (amountBottles > 0) {
    ...
    String grpNumber = basicService.generateNumberWithGoodsReceipt(goodsreceipt);
    ...
}
```

**After:**
```java
// Before loop: get initial count once
int grpCount = goodsreceiptpositionRepository.countByGoodsreceiptId(goodsreceipt.getId());

while (amountBottles > 0) {
    ...
    grpCount++;
    String grpNumber = goodsreceipt.getNumber() + "-" + String.format("%06d", grpCount);
    ...
}
```

**Requires:** Add `countByGoodsreceiptId(Long id)` to `GoodsreceiptpositionRepository` (Spring Data derives it automatically from method name — no custom query needed).

#### 2.2 Pre-Fetch Immutable Lookups Before Loop

Move these lookups before the `while` loop:

```java
// Pre-fetch once (these never change during the transaction)
Location spawnLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_SPAWN)
    .orElseThrow(...);
Location putAwayLocation = (carrier == null)
    ? locationRepository.findById(itemdata.getPutawaylocationId()).orElseThrow(...)
    : null;
String unitloadTypeName = unitloadTypeRepository.findNameById(adviceposition.getUnitloadtypeId());
```

Then pass these as parameters to `createUnitload()` and `createStockUnit()`, or use overloaded methods that accept pre-fetched entities.

**Changes required:**

| Method | Change |
|---|---|
| `UnitloadService.createUnitload()` | Add overload accepting `Location spawnLocation` parameter |
| `StockunitBusinessService.createStockUnit()` | Add overload accepting `Location location`, `String unitloadTypeName` |
| `receiveGoods()` loop | Use pre-fetched values, pass to overloaded methods |

#### 2.3 Batch Entity Creation with `saveAll()`

Collect entities in lists during the loop and persist in bulk after:

```java
List<Unitload> unitloadsToSave = new ArrayList<>(amountCases);
List<Stockunit> stockunitsToSave = new ArrayList<>(amountCases);
List<Goodsreceiptposition> grpsToSave = new ArrayList<>(amountCases);
List<Stockrecord> stockrecordsToSave = new ArrayList<>(amountCases);

while (amountBottles > 0) {
    // Build entities in memory (no save())
    ...
}

// Bulk persist
unitloadRepository.saveAll(unitloadsToSave);
stockunitRepository.saveAll(stockunitsToSave);
goodsreceiptpositionRepository.saveAll(grpsToSave);
stockrecordRepository.saveAll(stockrecordsToSave);
```

**Caveat:** The current loop uses `unitload.getId()` and `stockUnit.getId()` immediately after `save()` for cross-entity FK references. Batching requires either:
- (a) Using `saveAll()` in stages (save unitloads first, then use their IDs for stockunits), or
- (b) Using JPA-generated `@GeneratedValue` IDs that are populated after `saveAll()`, or
- (c) Pre-generating IDs (less practical with auto-increment).

**Recommended approach:** Option (a) — staged batching:
```
1. saveAll(unitloads)       → IDs populated
2. Build stockunits using unitload IDs
3. saveAll(stockunits)      → IDs populated
4. Build GRPs using both IDs
5. saveAll(grps)
```

#### 2.4 Consolidate Duplicate `unitloadRepository.save()` Per Iteration

Currently each iteration does:
```java
Unitload unitload = unitloadService.createUnitload(...);  // save #1
unitload.setBoxtypeId(boxType.getId());
unitloadRepository.save(unitload);                        // save #2
```

The boxtype can be set before the first save by adding a `boxtypeId` parameter to `createUnitload()`, eliminating the second save.

### Phase 3: Transaction Boundary Restructuring (Medium Effort, High Impact)

**Estimated effort: 2–3 days**

#### 3.1 Move Printer Calls Outside `@Transactional`

Split `receiveGoods()` into:
1. **Pre-transaction:** Printer availability check
2. **Transactional core:** All DB work (extracted to a package-private method)
3. **Post-transaction:** Label printing

```java
// Public entry point — NOT @Transactional
public void receiveGoods(...) throws BusinessException, FacadeException {
    // 1. Pre-transaction: printer check
    if (!printService.isPrintAvailable(printer.getAddress())) {
        throw new BusinessException("Printer not available...");
    }

    // 2. Transactional core
    byte[] labelBytes = receiveGoodsTransactional(
        advicePositionId, carrierUnitLoadId, storeOnCarrier,
        amountBottles, amountBottlesPerCase, amountCases, boxtypeId);

    // 3. Post-transaction: print (only after successful commit)
    if (Boolean.parseBoolean(syspropRepository.findSysvalueBySyskey(PRINT_CASE_LABEL_KEY))) {
        printService.cupsPrint(printer.getAddress(), labelBytes);
    }
}

@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
/*package*/ byte[] receiveGoodsTransactional(...) {
    // All DB operations here
    // Returns label bytes for post-commit printing
}
```

**Impact:** Eliminates DB connection hold during network I/O. In multi-threaded environments with 10+ concurrent receives, this prevents connection pool exhaustion when printers are slow.

#### 3.2 Add Pessimistic Lock for Over-Delivery Check

Add a `SELECT ... FOR UPDATE` method to `AdvicepositionRepository`:

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT ap FROM Adviceposition ap WHERE ap.id = :id")
Optional<Adviceposition> findByIdForUpdate(@Param("id") Long id);
```

Use this at `ReceivingService.java:330` instead of the plain `findById()`:

```java
// Before
Optional<Adviceposition> advicepositionOptional = advicepositionRepository.findById(advicePositionId);

// After
Optional<Adviceposition> advicepositionOptional = advicepositionRepository.findByIdForUpdate(advicePositionId);
```

This ensures only one thread can receive against the same advice position at a time, preventing the TOCTOU race on over-delivery checks.

**Trade-off:** This serializes concurrent receives for the **same** advice position. Different advice positions are unaffected. In practice, this is acceptable because receiving the same SKU line from two workstations simultaneously is an unusual workflow.

### Phase 4: `AdviceService` Optimization (Low Effort, Medium Impact)

**Estimated effort: 1–2 days**

#### 4.1 Use Bulk JPQL Update in `close()` and `acceptTransferAdvice()`

**Before (`AdviceService.java:301–305`):**
```java
List<Adviceposition> positionList = advicepositionRepository.findByAdviceId(advice.getId());
positionList.forEach((position) -> {
    position.setState(WmsConstants.AdviceState.FINISHED);
    advicepositionRepository.save(position);
});
```

**After:**
```java
advicepositionRepository.updateAdvicepositionToStateByAdviceId(
    advice.getId(), WmsConstants.AdviceState.FINISHED);
entityManager.flush();
entityManager.clear();  // Evict stale entities from persistence context
```

The bulk JPQL method `updateAdvicepositionToStateByAdviceId()` already exists in `AdvicepositionRepository.java:21–25` but is not used in `close()` or `acceptTransferAdvice()`.

**Apply the same pattern** to `acceptTransferAdvice()` (line 422–425 equivalent).

#### 4.2 Remove Duplicate Position List Fetch in `close()`

Remove the second `advicepositionRepository.findByAdviceId()` at line 315. Reuse the `positionList` from line 301.

**Important:** If 4.1 is applied (bulk JPQL update + `clear()`), the list must be re-fetched after the clear. In that case, remove the **first** fetch (line 301) and keep only the second (line 315) after the bulk update.

#### 4.3 Batch DTO Building in `close()`

**Before (`AdviceService.java:332–341`) — N+1:**
```java
for (Adviceposition advicePosition : positionList) {
    Itemdata itemData = itemdataRepository.findById(advicePosition.getItemdataId())...;
    List<Goodsreceiptposition> grpList =
        goodsreceiptpositionRepository.findByAdvicepositionId(advicePosition.getId());
    ...
}
```

**After — bulk pre-fetch:**
```java
// Collect all IDs
Set<Long> itemdataIds = positionList.stream()
    .map(Adviceposition::getItemdataId).collect(Collectors.toSet());
Set<Long> positionIds = positionList.stream()
    .map(Adviceposition::getId).collect(Collectors.toSet());

// Bulk fetch
Map<Long, Itemdata> itemdataMap = itemdataRepository.findAllById(itemdataIds)
    .stream().collect(Collectors.toMap(Itemdata::getId, Function.identity()));
Map<Long, List<Goodsreceiptposition>> grpMap =
    goodsreceiptpositionRepository.findByAdvicepositionIdIn(positionIds)
    .stream().collect(Collectors.groupingBy(Goodsreceiptposition::getAdvicepositionId));

// Build DTOs with pre-fetched data
for (Adviceposition ap : positionList) {
    Itemdata itemData = itemdataMap.get(ap.getItemdataId());
    List<Goodsreceiptposition> grps = grpMap.getOrDefault(ap.getId(), List.of());
    ...
}
```

**Requires:** Add `findByAdvicepositionIdIn(Collection<Long> ids)` to `GoodsreceiptpositionRepository`.

---

## 5. Implementation Phases

### Phase 1: Quick Wins (Days 1–2) — COMPLETED

| # | Task | Files | Status |
|---|---|---|---|
| 1.1 | Add `@Transactional` to 6 methods | `ReceivingService.java`, `AdviceService.java` | Done |
| 1.2 | Fix `resolvePalletByLabelId()` crash | `ReceivingService.java:563` | Done |
| 1.3 | Fix `initialized` flag bug | `StockunitBusinessService.java`, `UnitloadBusinessService.java` | Done |
| 1.4 | Remove duplicate location fetch | `ReceivingService.java:439` | Done |

### Phase 2: Loop Optimization (Days 3–7) — COMPLETED

| # | Task | Files | Status |
|---|---|---|---|
| 2.1 | Add `countByGoodsreceiptId()` + use counter | `GoodsreceiptpositionRepository.java`, `BasicService.java`, `ReceivingService.java` | Done |
| 2.2 | Pre-fetch immutable lookups (spawn, putaway, typeName) | `ReceivingService.java`, `UnitloadService.java`, `StockunitBusinessService.java` | Done |
| 2.3 | Batch saves with `saveAll()` | — | Deferred — FK dependency chain prevents safe batching without major refactoring |
| 2.4 | Consolidate unitload save (add boxtypeId param) | `UnitloadService.java`, `ReceivingService.java` | Done |

### Phase 3: Transaction Restructuring (Days 8–10) — COMPLETED

| # | Task | Files | Status |
|---|---|---|---|
| 3.1 | Defer printing to after commit via `TransactionSynchronization` | `ReceivingService.java` | Done |
| 3.2 | Add pessimistic lock for over-delivery (`findByIdForUpdate`) | `AdvicepositionRepository.java`, `ReceivingService.java` | Done |

### Phase 4: AdviceService Optimization (Days 11–12) — COMPLETED

| # | Task | Files | Status |
|---|---|---|---|
| 4.1 | Bulk JPQL in `close()` + `acceptTransferAdvice()` | `AdviceService.java` | Done |
| 4.2 | Remove duplicate position fetch | `AdviceService.java` | Done |
| 4.3 | Batch DTO building | `AdviceService.java`, `GoodsreceiptpositionRepository.java` | Done |

### Testing Strategy

Each phase should include:
1. **Unit tests** — mock repository calls, verify batch methods are called
2. **Integration tests** — TestContainers PostgreSQL, verify correct data after receiving
3. **Concurrency tests** — for Phase 3.2, use `CountDownLatch` to simulate concurrent receives on same advice position, verify over-delivery is prevented
4. **Query count logging** — enable Hibernate `show_sql` or p6spy to measure actual query reduction before/after

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Self-invocation bypasses `@Transactional` proxy | Medium | High | Audit call chains; extract to separate bean if needed |
| Pessimistic lock causes deadlocks | Low | Medium | Lock ordering: always lock advice position before unitload; set lock timeout |
| Batch `saveAll()` breaks FK ordering | Medium | Medium | Use staged batching (unitloads → stockunits → GRPs); test with real DB |
| Printer call after commit fails silently | Low | Low | Log print failures; add retry queue for failed prints |
| Bulk JPQL `clear()` causes `LazyInitializationException` | Medium | Medium | Re-fetch needed entities after `clear()`; pattern already proven in `closeBOL()` |
| `acceptHubAndSpokeAdvice()` regression | Medium | High | This method creates customer orders — test all hub-and-spoke flows end-to-end |

### Rollback Plan

Each phase is independent and can be deployed separately. If issues arise:
- Phase 1: Revert `@Transactional` additions (worst case: back to current behavior)
- Phase 2: Revert loop changes (fall back to per-iteration queries)
- Phase 3: Revert transaction split (printer calls go back inside transaction)
- Phase 4: Revert to individual saves in `close()`

---

## Appendix: Query Count Estimate

| Scenario: 50-Case Receive | Current | After Phase 2 | After All Phases |
|---|---|---|---|
| Pre-loop lookups | ~15 | ~12 | ~12 |
| Per-case queries | ~15–20 × 50 = 750–1000 | ~6–8 × 50 = 300–400 | ~2–3 batch ops |
| Post-loop | ~3 | ~3 | ~3 |
| **Total** | **~770–1020** | **~315–415** | **~100–150** |
| **Reduction** | baseline | **~55–60%** | **~85%** |

*Note: "After All Phases" assumes full batching (Phase 2.3). Without batching, Phase 2.1 + 2.2 + 2.4 alone achieve ~55–60% reduction.*
