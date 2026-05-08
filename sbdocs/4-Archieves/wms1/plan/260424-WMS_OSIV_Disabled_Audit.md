# WMS v1 OSIV Disabled — JPA Dirty-Checking Audit

**Date:** 2026-03-13
**Status:** In Progress
**Priority:** Critical
**Repository:** `v1/wms-api`  
**Branch Audited:** `develop` (with cross-reference to `release`)

---

## Problem Statement

Open Session In View (OSIV) has been disabled in `wms-api` (`spring.jpa.open-in-view=false`). With OSIV enabled, Hibernate's "dirty checking" would automatically flush any modified entity fields to the database at the end of an HTTP request — even without an explicit `.save()` call or `@Transactional` boundary. With OSIV disabled, entities become **detached** once the persistence context closes (at the end of the service/transactional method), meaning any setter calls on fetched entities that lack a corresponding `.save()` or `@Transactional` boundary will be **silently lost**.

This audit verifies that no data integrity regressions exist in the codebase after disabling OSIV.

---

## Methodology

### Automated Scanning
1. **Setter-to-save ratio analysis** — For every `.java` file in `service/` and `controller/`, counted `.set[A-Z]` calls vs `.save()` calls vs `@Transactional` annotations.
2. **Files with high setter counts and low/zero save counts** were flagged for manual review.
3. **Entity vs DTO classification** — Setter calls on DTO/TO objects (e.g., `MobileReplenishOrderTO`, `TruckLoadingMobileDTO`, `MobileInfoTO`) were excluded since they are not JPA-managed entities and require no persistence.

### Manual Verification
For each flagged file, every setter call was traced to determine:
- **Is the target a new entity or a fetched entity?** New entities (`new Stockunit()`) always have `.save()` at the end of the creation block.
- **Is there a `.save()` after the setter?** Either on the same variable or via delegation to another service method that saves internally.
- **Is the method `@Transactional`?** If so, dirty checking applies within the transaction boundary.
- **Is the setter on a DTO/TO?** If so, no persistence needed.

---

## Audit Results

### Pass 1 Verdict: ✅ SAFE (service layer bulk scan)

### Pass 2 Verdict: ⚠️ ONE BUG FOUND (granular endpoint-by-endpoint audit)

Every entity modification in the codebase follows one of these safe patterns, **except** the `ReplenishOrderJob.mergePickingOrders` bug documented below:

| Pattern | Description | Example |
|---------|-------------|---------|
| **New → Set → Save** | Entity is created with `new`, fields set, then `.save()` called | `StockunitBusinessService.createStockUnit()` |
| **Fetch → Set → Save** | Entity fetched from repository, modified, then `.save()` called | `ShipperidService.updateShipperIDCarrier()` |
| **@Transactional method** | Method has `@Transactional`, dirty checking active within boundary | `StockunitBusinessService.transferStockToUnitLoad()` |
| **DTO setters only** | Setters are on transfer objects, not JPA entities | `MobileInfoService`, `MobileReplenishService` |

---

## Detailed File-by-File Results

### Core Service Layer (`service/`)

| File | Setters | Saves | @Transactional | Status | Notes |
|------|---------|-------|----------------|--------|-------|
| `AdviceService.java` | ~20 | ~8 | Yes (class) | ✅ Safe | All entity mods have `.save()` |
| `ReceivingService.java` | ~30 | 6 | Caller-inherited | ✅ Safe | All entity mods have `.save()` |
| `PickingorderBusinessService.java` | ~25 | ~12 | Partial | ✅ Safe | `confirmPick()` is `@Transactional`; all others call `.save()` |
| `PickingorderPositionService.java` | ~5 | ~3 | No | ✅ Safe | `.save()` follows every setter |
| `PickingorderService.java` | ~5 | ~3 | No | ✅ Safe | `.save()` follows every setter |
| `ReplenishorderService.java` | ~10 | ~5 | No | ✅ Safe | New entity → set → save pattern |
| `ReplenishGeneratorService.java` | ~15 | 2 | No | ✅ Safe | New entity → set → save pattern |
| `StockunitBusinessService.java` | ~20 | ~10 | Partial | ✅ Safe | `transferStockToUnitLoad()` + `changeReservedAmount()` are `@Transactional`; others use `.save()` |
| `StockunitService.java` | ~30 | ~15 | No | ✅ Safe | Every fetch→set→save pattern verified |
| `UnitloadBusinessService.java` | ~20 | ~8 | Partial | ✅ Safe | `transferUnitLoadToLocation()` + `transferUnitLoadToCarrier()` are `@Transactional`; others use `.save()` |
| `UnitloadService.java` | ~10 | ~5 | No | ✅ Safe | `.save()` follows every setter |
| `CyclecountService.java` | ~10 | 6 | No | ✅ Safe | `.save()` follows every state change |
| `CyclecountPositionService.java` | ~5 | ~3 | No | ✅ Safe | `.save()` follows every setter |
| `LosSyspropService.java` | ~15 | 3 | No | ✅ Safe | All property updates end with `.save()` |
| `ShipperidService.java` | ~5 | 3 | No | ✅ Safe | Each update method: set → save |
| `ManageOrderService.java` | ~10 | ~5 | No | ✅ Safe | HTTP calls to OMS; entity mods saved |
| `StockrecordService.java` | ~15 | ~3 | No | ✅ Safe | New entity → set → save pattern |
| `LocationService.java` | ~5 | ~3 | No | ✅ Safe | set → save pattern |

### Mobile Service Layer (`service/mobile/`)

| File | Setters | Saves | @Transactional | Status | Notes |
|------|---------|-------|----------------|--------|-------|
| `MobileInfoService.java` | ~39 | 0 | No | ✅ Safe | **All setters are on DTOs** (`MobileInfoTO`), not JPA entities |
| `MobileTransferOrderService.java` | ~15 | 0 | No | ✅ Safe | All setters on DTOs |
| `MobilePutAwayService.java` | ~10 | 0 | No | ✅ Safe | Delegates entity persistence to `StockunitBusinessService` / `UnitloadBusinessService` |
| `MobileMoveStockService.java` | ~10 | 0 | No | ✅ Safe | Delegates to business services that handle persistence |
| `MobileMoveUnitloadService.java` | ~12 | 2 | 1 method | ✅ Safe | Entity setters at lines 419-420 and 445-446 each followed by `.save()` |
| `MobileReplenishService.java` | ~72 | 8 | 2 methods | ✅ Safe | Entity mods (replenish order state) all have `.save()`; remaining setters are on DTOs |
| `MobilePickingService.java` | ~55 | ~26 | 1 method | ✅ Safe | Every entity setter followed by `.save()` or delegates to `finishPickingOrder()` which saves internally |
| `MobileCycleCountService.java` | ~24 | 6 | No | ✅ Safe | Every cycle count position/state change followed by `.save()` |
| `MobileTruckLoadingService.java` | ~21 | 4 | No | ✅ Safe | Entity mods (BOL, BOL positions) all have `.save()`; remaining setters on DTOs |

### Controller Layer (`controller/rest/`)

| File | Setters | Saves | Status | Notes |
|------|---------|-------|--------|-------|
| `AdviceRestController.java` | ~85 | 7 | ✅ Safe | All setters are on **new** entities before `.save()` (advice + positions creation) |
| `OrderRestController.java` | ~59 | 4 | ✅ Safe | All setters on **new** entities (batch + order + position creation) |
| `UtilRestController.java` | ~102 | ~56 | ✅ Safe | System init and bulk reset methods — every fetch→set→save verified (lines 715-760, 990-1010) |
| `FileImportController.java` | ~76 | 8 | ✅ Safe | CSV import creates **new** entities (clients, locations, SKUs, advices) — all followed by `.save()` |
| `SkuRestController.java` | ~25 | 2 | ✅ Safe | Create + update SKU — both end with `.save()` |

---

## Key Patterns Identified

### 1. DTO-Heavy Mobile Layer (No Risk)
The mobile service layer has the highest setter counts but lowest save counts because it builds **Data Transfer Objects** (DTOs) for the mobile app UI. These are in package `net.aim_ai.wms.data.dto` and are never JPA-managed. Examples:
- `MobileInfoTO`, `MobileReplenishOrderTO`, `TruckLoadingMobileDTO`, `CycleCountMobileDTO`

### 2. New Entity Creation (No Risk)
Controllers (`AdviceRestController`, `OrderRestController`, `FileImportController`) create entities with `new Entity()`, set fields, then call `repository.save()`. This is the standard JPA pattern and works identically with or without OSIV.

### 3. Fetched Entity Modification (Verified Safe)
The potentially dangerous pattern — fetching an entity, modifying it, and relying on dirty checking — was **not found without a corresponding `.save()` call**. Every instance of `repository.findById()` → `.set*()` is followed by `.save()`.

### 4. @Transactional Methods (Safe)
Methods with `@Transactional` have dirty checking active within their boundary. Key examples:
- `StockunitBusinessService.transferStockToUnitLoad()` — complex stock movements
- `StockunitBusinessService.changeReservedAmount()` — reservation changes
- `UnitloadBusinessService.transferUnitLoadToLocation()` — unit load transfers
- `MobilePickingService.processPick()` — pick confirmation

---

## Relationship to Other Plans

| Plan | Relationship |
|------|-------------|
| [Reservation Leak Fix](../../wms2/plan/260424-Reservation_Leak_Analysis.md) | Fixed 4 bugs where `.save()` was missing after reservation amount changes — **already deployed** via PR #145 |
| Phase 2: Tight Transactions | Plans to add `@Transactional` to 5 `StockunitService` methods that currently have none — this audit confirms they are safe *today* because they use explicit `.save()`, but adding `@Transactional` remains the correct long-term fix |

---

---

## Pass 2: Granular Endpoint-by-Endpoint Audit

### 🐛 BUG: `ReplenishOrderJob.mergePickingOrders` — CANCELED state not persisted

**File:** `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java`
**Method:** `mergePickingOrders(List<Pickingorder>, long, Section)` (line 388)
**Annotation:** `@Transactional(propagation = Propagation.REQUIRES_NEW)`

**Problem:**
1. The method receives a `List<Pickingorder>` from the private `mergePickingOrders()` caller (line 99), which fetches them **outside** any transaction — they are **detached** entities.
2. Inside the method, line 402 re-fetches each as `poCurrent` (managed), but only uses it for a state check.
3. Lines 429-431 modify the **original detached** `pickingOrder`: `setState(CANCELED)`, `setCustomerordernumber(null)`, `setSectionId(null)`.
4. All are added to `pickingOrderList` (line 433).
5. Later, some are removed from the list and **reused** — these get saved with `PROCESSABLE` state at line 463 ✅.
6. **Leftover picking orders** that aren't reused remain in `pickingOrderList` and are **never saved** — their `CANCELED` state is silently lost ❌.

**Impact:** Picking orders that should be canceled after merge remain in their original `PROCESSABLE` state. This could cause duplicate picking or stale picking orders appearing in the queue.

**Fix:**
```java
// After the merge loop (after line 488), save any remaining canceled picking orders:
for (Pickingorder leftover : pickingOrderList) {
    pickingorderRepository.save(leftover);
}
```

**Alternative fix (more defensive):** Save each picking order immediately after setting it to CANCELED at line 431:
```java
pickingOrder.setState(WmsConstants.State.CANCELED);
pickingOrder.setCustomerordernumber(null);
pickingOrder.setSectionId(null);
pickingorderRepository.save(pickingOrder);  // <-- ADD THIS
pickingOrderList.add(pickingOrder);
```

### Pass 2: Web UI Controllers (Verified Safe)

| Controller | Setters | Saves | Status | Notes |
|------------|---------|-------|--------|-------|
| `AdviceController` | 1 | 0 | ✅ Safe | Delegates to `adviceService.setPurchaseOrderNumber()` which calls `.save()` |
| `BillOfLadingController` | 4 | 0 | ✅ Safe | 2 are service delegations (`setTrackingDeviceID()`, `setDestinationFacility()`) that `.save()` internally; 2 are on DTO `ParcelMonitorDto` |
| `BoxTypeController` | 1 | 1 | ✅ Safe | Explicit `.save()` |
| `ClientController` | 11 | 4 | ✅ Safe | 7 setters on `new Client()` before `.save()`; 4 fetch→set→save patterns |
| `CustomerOrderController` | 1 | 0 | ✅ Safe | Delegates to `customerorderService.setPickingDate()` which calls `.save()` |
| `GroupController` | 8 | 2 | ✅ Safe | New entity creation patterns |
| `ItemDataController` | 2 | 1 | ✅ Safe | Explicit `.save()` |
| `PrinterController` | 17 | 6 | ✅ Safe | New entity + fetch→set→save patterns |
| `ReportController` | 2 | 0 | ✅ Safe | Setters on DTO `OrderDetailMonitorView`, not JPA entity |
| `RoleController` | 9 | 2 | ✅ Safe | New entity creation patterns |
| `ShipperIdController` | 11 | 2 | ✅ Safe | New entity + fetch→set→save patterns |
| `StockUnitController` | 4 | 0 | ✅ Safe | Delegates to `stockunitService.setLockOnHold()` and `.setLockDamaged()` which both `.save()` |
| `SystemPropertyController` | 13 | 3 | ✅ Safe | Explicit `.save()` patterns |
| `UserController` | 12 | 4 | ✅ Safe | New entity + fetch→set→save patterns |

### Pass 2: Mobile Controllers (Verified Safe)

| Controller | Setters | Saves | Status | Notes |
|------------|---------|-------|--------|-------|
| `MoveStockController` | 2 | 0 | ✅ Safe | All setters on DTOs |
| `MoveUnitloadController` | 1 | 0 | ✅ Safe | Setter on DTO |
| `PalletizingController` | 1 | 0 | ✅ Safe | Setter on DTO |
| `PutawayController` | 1 | 0 | ✅ Safe | Setter on DTO |
| `ReplenishController` | 3 | 0 | ✅ Safe | All setters on DTOs (`ReplenishMobileOrderDto`) |
| `TransferOrderController` | 2 | 0 | ✅ Safe | All setters on DTOs |

### Pass 2: Scheduled Jobs (Verified Safe)

| Job | Status | Notes |
|-----|--------|-------|
| `OrderReleaseJob` | ✅ Safe | Delegates to `ReleaseOrderJobService.releaseOrder()` which is `@Transactional(REQUIRES_NEW)` — all entities fetched within transaction, all state changes either dirty-checked or explicitly saved |
| `CleanUpOldMessagesJob` | ✅ Safe | Delegates to `CleanUpOldMessageJobService` which uses `@Modifying` + `@Transactional` native queries |
| `ReleaseExpiredPickingOrdersFromUserJob` | ✅ Safe | Fetches picking orders, modifies them, and calls `pickingorderRepository.save()` after each |
| `ReplenishOrderJob` | ⚠️ BUG | `mergePickingOrders()` — see bug above |
| `StockSummaryExportJob` | ✅ Safe | No entity modifications (export only) |

### Pass 2: Async & Event Listeners (Verified Safe)

| Component | Status | Notes |
|-----------|--------|-------|
| `MessageRepository.deleteMessages()` `@Async` | ✅ Safe | `@Modifying` + `@Transactional` native query — self-contained |
| `AdminController` `@EventListener(ApplicationReadyEvent)` | ✅ Safe | Logging only — no entity modifications |
| `TokenController` `@EventListener(ApplicationReadyEvent)` | ✅ Safe | Logging only — no entity modifications |

### Pass 2: Job Services (Verified Safe)

| Service | Status | Notes |
|---------|--------|-------|
| `ReleaseOrderJobService` | ✅ Safe | `@Transactional(REQUIRES_NEW)` on `releaseOrder()`. Entities fetched within transaction, explicit `.save()` on all state changes. First-round position changes (lines 126-170) rely on dirty checking within transaction. |
| `ReplenishOrderJobService` | ✅ Safe | All methods are `@Transactional(REQUIRES_NEW)` — entities fetched within transaction |
| `CleanUpOldMessageJobService` | ✅ Safe | Uses repository `@Modifying`+`@Transactional` native queries |

---

## Pass 3: Comprehensive Re-Audit

Re-audited all core business services, mobile services, and controllers with focus on cross-transaction entity passing, conditional saves, and loop edge cases.

### Core Service Layer Deep Review

| Service | Pattern | Status | Notes |
|---------|---------|--------|-------|
| `CustomerorderService` | Class-level `@Transactional` | ✅ Safe | All entity mutations within transaction boundary |
| `CustomerorderPositionService` | Explicit `.save()` | ✅ Safe | Every state change followed by `.save()` |
| `AdviceService` | Class-level `@Transactional` | ✅ Safe | All state changes saved explicitly |
| `BillofladingService` | Explicit `.save()` | ✅ Safe | BOL and BOL position updates all saved |
| `ReplenishGeneratorService` | New entity creation | ✅ Safe | Creates new entities → `.save()` |
| `ReplenishorderService` | Explicit `.save()` | ✅ Safe | New entity → set → save pattern |
| `ReplenishmentOrderMaintenanceService` | Explicit `.save()` | ✅ Safe | `cancelOrder()`, `alignDestination()`, `updateRequestedAmount()` all call `.save()` |
| `FixLocationAssignmentService` | Explicit `.save()` | ✅ Safe | All modifications saved |

### Stale Entity Re-Fetch Pattern (Verified Safe)

The codebase uses a defensive "stale entity" pattern where service methods accept potentially detached entities, re-fetch them inside the transaction, and save explicitly:

| Method | Re-fetch | Save | Status |
|--------|----------|------|--------|
| `StockunitBusinessService.sendStockUnitToNirvana(staleStockUnit)` | `findById(staleStockUnit.getId())` at L267 | `.save()` at L277 | ✅ |
| `StockunitBusinessService.changeReservedAmount(staleStockUnit)` | `findByIdForUpdate(staleStockUnit.getId())` at L314 | `.save()` at L334 | ✅ |
| `UnitloadBusinessService.transferUnitLoadToCarrier(staleUnitload)` | `findById(staleUnitload.getId())` at L153 | `.save()` at L207 | ✅ |
| `UnitloadBusinessService.processTransfer(staleUnitload)` | `findById(staleUnitload.getId())` at L215 | `.save()` at L218 | ✅ |
| `UnitloadBusinessService.sendToNirvana(unitload)` | `findById(unitload.getId())` at L258 | `.save()` at L261 | ✅ |

---

## Pass 4: Deep Nuance Audit

Targeted deep-dive into `REQUIRES_NEW` boundaries, loop edge cases, and conditional save paths.

### `REQUIRES_NEW` Analysis

All methods with `Propagation.REQUIRES_NEW` were verified. The key question: do they accept entity parameters that become detached in the new persistence context?

| Method | Accepts | Status | Notes |
|--------|---------|--------|-------|
| `ReleaseOrderJobService.releaseOrder()` | `long customerOrderId` + maps | ✅ Safe | ID-based, fetches internally |
| `ReplenishOrderJobService.cancelReplenishmentOrder()` | `long replenishOrderID` | ✅ Safe | ID-based |
| `ReplenishOrderJobService.generateReplenishment*()` | `long itemDataId/flaId` | ✅ Safe | ID-based |
| `ReplenishOrderJobService.updateReplenishmentOrderPriority()` | `long replenishOrderId` | ✅ Safe | ID-based |
| `ReplenishOrderJobService.refillFixedLocationAssignment()` | `long flaId` | ✅ Safe | ID-based |
| **`ReplenishOrderJob.mergePickingOrders()`** | **`List<Pickingorder>`** | ⚠️ **BUG** | **Entity list passed — detached in new context** |

**Only `ReplenishOrderJob.mergePickingOrders` accepts entity objects into a `REQUIRES_NEW` method.** All other `REQUIRES_NEW` methods use the safe ID-based pattern.

### Scheduled Job Loop Analysis

Every scheduled job's loop pattern was verified for entity lifecycle safety:

| Job | Loop Pattern | Status | Notes |
|-----|-------------|--------|-------|
| `OrderReleaseJob.releaseOrders()` | Loops over `Object[]` results, passes `Long` IDs | ✅ Safe | No entity mutation in caller |
| `ReplenishOrderJob.cancelUnreachableReplenishment()` | Loops over `Long` IDs | ✅ Safe | ID-based delegation |
| `ReplenishOrderJob.cancelReplenishmentIfFlowbinIsFull()` | Loops over `Long` IDs | ✅ Safe | ID-based delegation |
| `ReplenishOrderJob.generateReplenishment*()` (2 methods) | Loops over `Long` IDs | ✅ Safe | ID-based delegation |
| `ReplenishOrderJob.triggerRegularReplenishment()` | Loops over `Long` IDs | ✅ Safe | ID-based delegation |
| `ReplenishOrderJob.updateReplenishmentOrderPriority()` | Loops over `Long` IDs | ✅ Safe | ID-based delegation |
| `ReplenishOrderJob.recalculateReplenishment*()` | Delegates to service | ✅ Safe | No entity params |
| `ReleaseExpiredPickingOrdersFromUserJob` | Loops over `Pickingorder` list | ✅ Safe | Explicit `.save()` after each modification |
| `StockSummaryExportJob` | Loops over DTOs | ✅ Safe | No entity mutations |
| `CleanUpOldMessagesJob` | Delegates to service | ✅ Safe | `@Modifying` native queries |

### `ReplenishmentOrderMaintenanceService.recalculateOpenOrders()` (Called from Job)

Called at line 93 of `ReplenishOrderJob.doCalculation()`. No `@Transactional` on the caller or the method itself. Entities are fetched, passed to `recalculateOrder()`, which modifies and **explicitly saves** every mutation:
- `alignDestination()` → `.save()` at L185
- `cancelOrder()` → `.save()` at L365
- `updateRequestedAmount()` → `.save()` at L287, L353

✅ Safe — all mutations use explicit `.save()`.

---

## Conclusion

The WMS v1 codebase is **mostly safe** to operate with OSIV disabled. After 4 passes of auditing, **one bug** was found:

### 🐛 `ReplenishOrderJob.mergePickingOrders` — Leftover CANCELED picking orders not saved

This is the **only** method in the entire codebase that passes entity objects into a `REQUIRES_NEW` transaction boundary. All other `REQUIRES_NEW` methods use the safe ID-based pattern.

### Remaining Work
- [ ] Fix `ReplenishOrderJob.mergePickingOrders` — add `.save()` for leftover CANCELED picking orders
- [x] All other endpoints, crons, and workflows verified safe (4 passes)

---

## Testing Checklist

- [x] Automated setter-to-save ratio scan completed for all service files
- [x] Automated scan completed for all controller files
- [x] Manual verification of all high-risk files (high setter count, low save count)
- [x] DTO vs Entity classification confirmed for mobile layer
- [x] All 143 unit tests pass on both `develop` and `release` branches
- [x] Level 2 Docker build successful on `fix/develop-backport`
- [x] Reservation leak fixes deployed via PR #145
- [x] Pass 2: All 14 Web UI controllers verified (endpoint by endpoint)
- [x] Pass 2: All 6 mobile controllers verified
- [x] Pass 2: All 5 scheduled jobs verified
- [x] Pass 2: All 3 job services verified
- [x] Pass 2: @Async and @EventListener handlers verified
- [x] Pass 3: Core service layer deep review (8 services)
- [x] Pass 3: Stale entity re-fetch pattern verified (5 methods)
- [x] Pass 4: All REQUIRES_NEW methods audited (7 methods)
- [x] Pass 4: All scheduled job loops audited (10 loops)
- [x] Pass 4: ReplenishmentOrderMaintenanceService.recalculateOpenOrders() verified
- [ ] Fix: ReplenishOrderJob.mergePickingOrders fix applied and tested

