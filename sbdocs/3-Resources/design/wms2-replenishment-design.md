---
type: design
status: active
system: wms2
last_verified: 2026-05-20
verified_by: Claude (executor)
tags: [wms2, replenishment, fix-location, stock, inventory]
---

## TL;DR
- Module-level design for the replenishment subsystem in `v2/wms2-api` — moving inventory from bulk storage into fixed pick-face locations (flow bins).
- Four service halves: **Generator** (`ReplenishGeneratorService`) creates orders at `PROCESSABLE(300)`; **Execution** (`MobileReplenishService`) drives the physical move to `FINISHED(700)`; **Maintenance** (`ReplenishmentOrderMaintenanceService`) recalculates/redirects/cancels open orders; **Job** (`ReplenishOrderJob`) runs the cron pipeline across all tenants.
- Core entities: `Replenishorder` (order + state) and `FixLocationAssignment` (FLA — SKU → fixed slot binding with `lowerbound`/`middlebound`/`upperbound` thresholds).
- State machine: `PROCESSABLE(300)` → `STARTED(500)` → `FINISHED(700)` or `CANCELED(800)`; `PICKED(600)` is unused in this flow.
- FLA `middlebound` is the refill trigger — a refill order is generated when on-hand drops below it; `upperbound` is the cancel-if-full threshold.
- Critical constraint: `refillFixedLocations()` has no outer `@Transactional`; calling it inside `finishReplenishmentOrderInternal` means an unexpected refill failure can roll back the finish transaction.
- Read this doc for: replenishment stuck-state bugs, over-replenishment, FLA assignment failures, multi-unitload replenishment path (`MobileReplenishService`), or the `ReplenishOrderJob` cron pipeline.

# WMS2 Replenishment Subsystem Design

Module-level design for the replenishment subsystem in `v2/wms2-api`.
Audience: engineers fixing replenishment stuck states, over-replenishment bugs, and location assignment failures.

---

## §0 Module Inventory

All files under `v2/wms2-api/src/main/java/net/aim_ai/wms/` unless noted.

### Production classes

| File | Lines | Role | Covered in |
|---|---|---|---|
| `service/ReplenishGeneratorService.java` | 250 | Order creation + stock reservation — the "generator" half | §2, §3, §6 |
| `service/ReplenishmentOrderMaintenanceService.java` | 575 | Periodic recalculation, source redirect, cancellation — the "maintenance" half | §2, §3, §5 |
| `service/ReplenishorderService.java` | 347 | Public CRUD API: create, update, cancel, priority, redirect | §2, §3 |
| `service/job/ReplenishOrderJobService.java` | 277 | Transactional wrappers called by the cron job | §2, §8 |
| `service/mobile/MobileReplenishService.java` | 1004 | Mobile execution: start → check source/dest → finish; multi-unitload path | §2, §7 |
| `schedulejob/ReplenishOrderJob.java` | 470 | Cron orchestrator — iterates tenants, runs pipeline phases | §8 |
| `model/Replenishorder.java` | 164 | JPA entity — `replenishorder` table | §4 |
| `model/FixLocationAssignment.java` | 108 | JPA entity — `fix_location_assignment` table | §4, §6 |
| `model/ReplenishmentMonitorView.java` | 209 | Read-only monitor view entity | §4 |
| `repo/jpa/ReplenishorderRepository.java` | 363 | JPA repository with 20+ native/JPQL queries | §10 |
| `repo/jpa/ReplenishmentMonitorViewRepository.java` | 114 | Monitor view repository | §10 |
| `repo/projection/ReplenishOrderDetailView.java` | 21 | Projection: detail view columns | §10 |
| `repo/projection/ReplenishMonitorSummaryView.java` | 31 | Projection: monitor summary columns | §10 |
| `repo/projection/UnitloadReplenishView.java` | 9 | Projection: unit load replenish fields | §10 |
| `repo/projection/StockunitReplenishInfoView.java` | 8 | Projection: stock unit info for replenishment | §10 |
| `controller/ReplenishOrderController.java` | 298 | Desktop REST endpoints (HAL) | §2 |
| `controller/mobile/ReplenishController.java` | 248 | Mobile REST endpoints | §2 |
| `json/mobile/ReplenishMobileOrderDto.java` | 325 | Mobile order DTO | §2 |
| `json/mobile/MultiReplenishRequestDto.java` | 60 | Multi-unitload request DTO | §7 |
| `json/mobile/MultiReplenishResponseDto.java` | 65 | Multi-unitload response DTO | §7 |
| `json/mobile/MultiReplenishUnitLoadDto.java` | 63 | Per-unitload entry in multi-unitload request | §7 |

### Test classes

| File | Lines | Notes |
|---|---|---|
| `unit/service/ReplenishGeneratorServiceUnitTest.java` | 988 | 30+ `@Test` methods; Mockito; covers idempotency, stock fallback, template creation |
| `unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | 1168 | 30+ `@Test` methods; covers recalc, source redirect, cancel threshold |
| `unit/service/ReplenishorderServiceUnitTest.java` | 1014 | 30+ `@Test` methods; covers redirect, cancel, priority bulk update |
| `unit/service/job/ReplenishOrderJobServiceUnitTest.java` | 489 | 15+ `@Test` methods; covers FLA deletion, generate with/without FLA |
| `unit/service/mobile/MobileReplenishServiceUnitTest.java` | — | Unit tests for mobile flow |
| `unit/service/mobile/MobileReplenishServiceH2Test.java` | — | H2 in-memory integration tests |
| `integration/service/mobile/MobileReplenishServiceIntegrationTest.java` | — | Testcontainers (PostgreSQL) integration tests |
| `unit/schedulejob/ReplenishOrderJobTest.java` | — | Job-level unit tests |
| `unit/controller/ReplenishOrderControllerUnitTest.java` | — | Controller unit tests |
| `unit/controller/ReplenishOrderControllerH2Test.java` | — | H2 controller tests |
| `unit/controller/mobile/ReplenishControllerUnitTest.java` | — | Mobile controller unit tests |
| `integration/repository/ReplenishorderRepositoryIntegrationTest.java` | — | Native-query integration tests |
| `resources/scripts/mobileReplenishService_multiUnitLoads.sql` | — | Test fixture SQL for multi-unitload scenario |

---

## §1 Overview

Replenishment moves inventory from bulk storage areas into picking/flow-bin locations so pickers never find an empty slot. The subsystem splits cleanly into two halves:

**Generator half** — `ReplenishGeneratorService` decides *whether* and *what* to replenish. It selects a source stock unit, reserves the amount, and persists the `Replenishorder` at state `PROCESSABLE (300)`. It never executes physical movement.

**Execution half** — `MobileReplenishService` handles the physical movement. A warehouse operator scans the source unit load, walks to the destination, and confirms; the service transfers stock, marks the order `FINISHED (700)`, and triggers follow-up refill.

**Maintenance half** — `ReplenishmentOrderMaintenanceService` periodically recalculates open `PROCESSABLE` orders: adjusting requested amounts, redirecting to better source stock if the original becomes unusable, and cancelling orders whose destination is already sufficiently stocked.

**Job orchestrator** — `ReplenishOrderJob.doCalculation()` drives the entire pipeline on a cron schedule, iterating over all tenants.

```
ReplenishOrderJob.doCalculation()
  │
  ├─ mergePickingOrders()
  ├─ deleteEmptyFixAssignmentWithoutStockToReplenish()
  ├─ cancelUnreachableReplenishment()
  ├─ cancelReplenishmentIfFlowbinIsFull()
  ├─ generateReplenishmentForItemDataWithoutFixedAssignment()
  ├─ generateReplenishmentForItemDataWithFixedAssignmentWithOrders()
  ├─ triggerRegularReplenishment()
  ├─ updateReplenishmentOrderPriority()
  ├─ recalculateReplenishmentOrderWithoutFixedLocationAssignment()
  └─ replenishmentOrderMaintenanceService.recalculateOpenOrders/recalculateForItem()
```

---

## §2 Public API / Contract

### `ReplenishGeneratorService`

All tenant-write methods use `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class)`.

| Method | Signature | Tx boundary | Throws | Notes |
|---|---|---|---|---|
| `refillFixedLocations()` | `() → void` | None (iterates; each item calls `refillSingleFixedLocation`) | `FacadeException` (per-item, swallowed) | Walks all FLAs returned by `getRefillFixedLocations(FINISHED)`. Loop errors are logged and skipped. |
| `refillSingleFixedLocation(flaId)` | `(Long) → void` | `REQUIRES_NEW` | `FacadeException` | Single FLA refill in isolation; safe to call from job loop. |
| `calculateOrder(itemDataId, amount, destinationId)` | `(Long, BigDecimal, Long) → Replenishorder` | delegates to 4-arg overload with `PRIORITY_VERY_LOW` | `FacadeException` | Returns `null` if a pending order already exists for same item+destination (idempotency guard). |
| `calculateOrder(itemDataId, amount, destinationId, priority)` | `(Long, BigDecimal, Long, Integer) → Replenishorder` | `REQUIRES_NEW` | `FacadeException` | Core creation logic. Validates amount > 0. Prefers source stock with sufficient amount; falls back to stock with greatest available. Reserves `requestedamount` via `StockunitBusinessService.changeReservedAmount`. |
| `reserveExplicitStockForOrder(order, stock, amount)` | `(Replenishorder, Stockunit, BigDecimal) → void` | None | `FacadeException` | Used by multi-unitload path to reserve stock on an explicitly chosen source unit. Null-safe — does nothing if any param is null. |
| `createOrderFromTemplate(template, stock, amount, destinationId, sequenceIndex)` | `(Replenishorder, Stockunit, BigDecimal, Long, int) → Replenishorder` | `REQUIRES_NEW` | `FacadeException` | Clones template metadata; derives number as `template.getNumber() + "-" + (sequenceIndex+1)`; reserves stock. Used by multi-unitload fulfillment for orders 2…N. |

### `ReplenishmentOrderMaintenanceService`

No `@Transactional` annotations at method level — all DB writes are done directly via repository save calls within the calling transaction or in helper methods that acquire their own resources.

| Method | Signature | Notes |
|---|---|---|
| `recalculateOpenOrders()` | `() → void` | Calls `recalculateOpenOrders(false)` — respects cadence sysprop. |
| `recalculateOpenOrders(force)` | `(boolean) → void` | Loads all `PROCESSABLE` orders, builds bulk `RecalcContext`, iterates. Skips orders with `manuallyoverridepriority = true`. |
| `recalculateForItem(itemDataId)` | `(Long) → void` | Targeted recalc for a specific item; called by job after detecting affected items. `null` itemDataId falls back to full recalc. |
| `recalculateOrder(order)` | package-private `(Replenishorder) → void` | Test entry point — wraps with empty context. |
| `recalculateOrder(order, ctx)` | **public** `@Transactional(tenantTransactionManager, REQUIRED)` `(Replenishorder, RecalcContext) → void` | Core logic: re-fetches order with `findByIdForUpdate(@Lock PESSIMISTIC_WRITE)`, checks FLA, validates/redirects source, computes shortage, cancels or adjusts amount. Per-order short tx when called from sweep; annotation bypassed (this. call) when called from `recalculateForItem`. (260520 fix) |

### `ReplenishorderService`

All tenant-write methods use `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})`.

| Method | Signature | Tx boundary | Throws | HTTP (via controller) |
|---|---|---|---|---|
| `create(mOrder)` | `(ReplenishMobileOrderDto) → Replenishorder` | `tenantTransactionManager` | `FacadeException` | `POST /v3/replenish` |
| `update(id, stockUnitId, priority)` | `(Long, Long, Integer) → Replenishorder` | `tenantTransactionManager` | `B, F` | `PUT /v3/replenish/{id}` |
| `updateSourceStockUnit(id, stockUnitId)` | `(Long, Long) → Replenishorder` | `tenantTransactionManager` | `B, F` | `PUT /v3/replenish/{id}/sourceStockUnit` |
| `updatePriority(id, priority)` | `(Long, Integer) → Replenishorder` | `tenantTransactionManager` | — | `PUT /v3/replenish/{id}/priority` |
| `getActive(itemId, requestedLocationId)` | `(Long, Long) → List<Replenishorder>` | `readOnly` | — | `GET /v3/replenish/active` |
| `cancelReplenishmentOrder(replenishOrder)` | `(Replenishorder) → void` | `tenantTransactionManager` | `FacadeException` | `DELETE /v3/replenish/{id}` |
| `redirectSource(replenishOrder, stockUnit)` | `(Replenishorder, Stockunit) → Replenishorder` | `tenantTransactionManager` | `B, F` | Called internally by `update` |
| `updateReplenishmentOrderPriority(List, int)` | bulk variant | `tenantTransactionManager` | — | Called by picking job |
| `updateReplenishmentOrderPriority(List, int, int)` | bulk variant (old→new) | `tenantTransactionManager` | — | Called by picking job |
| `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` | `() → void` | `tenantTransactionManager` | — | Called by job |
| `existsForStockUnit(stockUnit)` | `(Stockunit) → Replenishorder` | `readOnly` | — | Used by stock movement guards |
| `getReplenishorderDetails(id)` | `(Long) → Map<String,Object>` | `readOnly` | — | `GET /v3/replenish/{id}/details` |
| `getStockunitInfoForReplenishment(id)` | `(Long) → List<Map>` | `readOnly` | — | `GET /v3/replenish/{id}/stockunitInfo` |

### `ReplenishOrderJobService`

All methods use `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`. This service exists to give each job-loop item its own isolated transaction so one failure does not abort the full job run.

| Method | Notes |
|---|---|
| `deleteEmptyFixAssignmentWithoutStockToReplenish(fixedLocationAssignmentId)` | Deletes FLA if it meets the "empty + no stock to replenish + no open orders" criteria. |
| `generateReplenishmentForItemDataWithoutFixedAssignment(itemDataId, amount)` | Calls `ReplenishGeneratorService.calculateOrder` with `destinationId = null`. |
| `generateReplenishmentForItemDataWithFixedAssignment(fixAssignmentId)` | Pre-validates FLA sanity (unitload on location, label matches, active, single SU) before calling `calculateOrder`. Triggers if `amountOnLocation < middleBound`. |
| `triggerRegularReplenishment()` | Iterates FLA IDs from `getRefillFixedLocations(FINISHED)`, calls `replenishGeneratorService.refillSingleFixedLocation(id)` per entry. |
| `updateReplenishmentOrderPriority(replenishOrderId, priority)` | Direct priority set — bypasses `manuallyoverridepriority` flag. |
| `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` | Delegates to `ReplenishorderService`. |
| `getRefillFixedLocationIds()` | Read-only query — returns FLA IDs eligible for refill. |
| `refillFixedLocationAssignment(fixLocationAssignmentId)` | `rollbackFor = FacadeException.class`; delegates to `refillSingleFixedLocation`. |
| `cancelReplenishmentOrder(replenishmentOrderId)` | Delegates to `ReplenishorderService.cancelReplenishmentOrder`. |

### `MobileReplenishService` (selected public methods)

All write methods: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.

| Method | Notes |
|---|---|
| `loadOrderByDestination(locationName)` | Loads order for a fixed-location scan. Throws if location not found or not a FLA. |
| `loadOrderById(id)` | Simple order load; no transaction. |
| `startOrder(mOrder)` | `PROCESSABLE → STARTED`. Records `operatorId`. Handles optimistic lock with re-fetch. |
| `resetOrder(mOrder)` | `STARTED → PROCESSABLE`. Clears `operatorId`. |
| `checkSource(mOrder, code)` | Validates or switches source unit load. Transfers reservation to new unit load if switched. |
| `checkDestination(mOrder, code)` | Validates destination. Creates FLA on-the-fly for new flowbin destinations. |
| `finishReplenishmentOrder(mOrder)` | `STARTED → FINISHED`. Transfers stock, creates FLA if absent, triggers refill. |
| `checkAmountPicked(mOrder, amount)` | Validation only — no persistence. |
| `fulfillMultipleUnitLoads(request)` | Multi-unitload path. See §7. |
| `getCalculatedOrders(code, clientId)` | Returns `PROCESSABLE` orders as select-item list for mobile picker. |
| `getReservedOrder()` | Returns `STARTED` order reserved by current operator. |

---

## §3 Service Dependency Tree

```
ReplenishOrderJob (cron)
├── ReplenishOrderJobService (REQUIRES_NEW wrappers)
│   ├── ReplenishGeneratorService        ← order creation + reservation
│   │   ├── StockunitBusinessService     ← changeReservedAmount
│   │   ├── ItemdataService
│   │   ├── BasicService                 ← generateReplenishNumber
│   │   ├── ReplenishorderRepository
│   │   ├── FixLocationAssignmentRepository
│   │   ├── StockunitRepository
│   │   ├── UnitloadRepository
│   │   └── LocationRepository
│   ├── ReplenishorderService            ← cancel, priority, recalc
│   │   ├── ReplenishGeneratorService
│   │   ├── StockunitBusinessService
│   │   └── [repositories]
│   └── FixLocationAssignmentService     ← delete FLA
│
├── ReplenishmentOrderMaintenanceService ← recalculate open orders
│   ├── StockunitBusinessService
│   ├── SyspropService                   ← cadence, threshold, upper-bound sysprops
│   ├── ReplenishorderRepository
│   ├── StockunitRepository
│   ├── UnitloadRepository
│   ├── LocationRepository
│   ├── LocationAreaRepository
│   └── FixLocationAssignmentRepository
│
└── [also drives] MobileReplenishService (via recalculateOpenOrders post-finish)

MobileReplenishService (mobile API)
├── ReplenishGeneratorService
├── ReplenishmentOrderMaintenanceService
├── StockunitBusinessService
├── FixLocationAssignmentService
└── [repositories]

ReplenishorderService (desktop API)
└── ReplenishGeneratorService (via create → calculateOrder)
```

---

## §4 Data Model

### 4.1 Entities

#### `Replenishorder` — table `replenishorder`

Extends `AbstractBaseEntity` (provides `id`, `version`, `created`, `modified`).

| Column | Java field | Type | Nullable | Notes |
|---|---|---|---|---|
| `id` (PK) | `id` | `Long` | N | From `AbstractBaseEntity` |
| `version` | `version` | `Integer` | N | Optimistic lock via `@Version` (inherited) |
| `number` | `number` | `String` | N | Unique order number; format `REPL-<seq>` for standard; `REPL-<seq>-<n>` for multi-unitload sub-orders |
| `state` | `state` | `Integer` | N | See §5 state machine; default `RAW (0)` |
| `prio` | `prio` | `Integer` | N | Priority; default `PRIORITY_VERY_LOW (0)` |
| `requestedamount` | `requestedamount` | `NUMERIC(17,4)` | Y | Amount to move; capped at source stock amount |
| `sourcelocationname` | `sourcelocationname` | `String` | Y | Denormalized source location name (snapshot at creation) |
| `entity_lock` | `entityLock` | `Integer` | Y | Always set to `0` at creation |
| `additionalcontent` | `additionalcontent` | `String` | Y | Free-text field; not used by current logic |
| `manuallyoverridepriority` | `manuallyoverridepriority` | `Boolean` | Y | When `true`, maintenance service skips priority recalculation |
| `client_id` (FK→client) | `clientId` | `Long` | N | Client owning the stock |
| `itemdata_id` (FK→itemdata) | `itemdataId` | `Long` | N | SKU being replenished |
| `stockunit_id` (FK→stockunit) | `stockunitId` | `Long` | Y | Source stock unit; reservation is held here |
| `requestedlocation_id` (FK→location) | `requestedlocationId` | `Long` | Y | Source location snapshot |
| `requestedrack_id` (FK→location_rack) | `requestedrackId` | `Long` | Y | Source rack snapshot |
| `destination_id` (FK→location) | `destinationId` | `Long` | Y | Target fixed location; may be `null` for items without FLA |
| `operator_id` (FK→mywms_user) | `operatorId` | `Long` | Y | Operator who claimed the order (`startOrder`) |

#### `FixLocationAssignment` — table `fix_location_assignment`

| Column | Java field | Type | Nullable | Notes |
|---|---|---|---|---|
| `id` (PK) | `id` | `Long` | N | From `AbstractBaseEntity` |
| `active` | `active` | `Boolean` | Y | When `false`, maintenance service ignores FLA |
| `lowerbound` | `lowerbound` | `NUMERIC(17,4)` | N | Minimum desired stock; default `0` |
| `middlebound` | `middlebound` | `NUMERIC(17,4)` | N | Trigger threshold — refill triggered when `amount < middlebound`; default `0` |
| `upperbound` | `upperbound` | `NUMERIC(17,4)` | N | Target fill level; default `0` |
| `assignedlocation_id` (FK→location) | `assignedlocationId` | `Long` | N | The fixed picking location (flowbin slot) |
| `assignedunitload_id` (FK→unitload) | `assignedunitloadId` | `Long` | N | The unit load sitting on the assigned location; stock is transferred here at finish |
| `itemdata_id` (FK→itemdata) | `itemdataId` | `Long` | N | SKU assigned to this slot |
| `entity_lock` | `entityLock` | `Integer` | Y | Lock state |

#### `ReplenishmentMonitorView` — table `replenishment_monitor_view` (DB view)

Read-only aggregate view of replenishment monitor data. Not modified by any service in this module.

### 4.2 Entity Relationships

```
Itemdata 1 ─── N Replenishorder (via itemdata_id)
Location  1 ─── N Replenishorder (via requestedlocation_id — source)
Location  1 ─── N Replenishorder (via destination_id — destination, nullable)
Stockunit 1 ─── 1 Replenishorder (via stockunit_id; reservation held here)
Client    1 ─── N Replenishorder (via client_id)

Itemdata  1 ─── 1 FixLocationAssignment (unique per SKU)
Location  1 ─── 1 FixLocationAssignment (via assignedlocation_id)
Unitload  1 ─── 1 FixLocationAssignment (via assignedunitload_id)
```

---

## §5 State Machine

The `Replenishorder.state` field uses `WmsConstants.State` integer constants.

| From | Event | To | Guard | Code path |
|---|---|---|---|---|
| — | `calculateOrder` creates order | `PROCESSABLE (300)` | `amount > 0`, source stock available, no duplicate pending order | `ReplenishGeneratorService.calculateOrder:187` |
| `PROCESSABLE` | Operator calls `startOrder` | `STARTED (500)` | Order not already finished; no other operator claimed it | `MobileReplenishService.startOrder:233` |
| `STARTED` | Operator calls `resetOrder` | `PROCESSABLE (300)` | State must be ≥ `PROCESSABLE` and < `FINISHED` | `MobileReplenishService.resetOrder:263` |
| `PROCESSABLE` or `STARTED` | `finishReplenishmentOrder` completes | `FINISHED (700)` | Source stock present, destination present, state < `FINISHED` | `MobileReplenishService.finishReplenishmentOrderInternal:498` |
| `PROCESSABLE` | Maintenance detects source gone / destination full | `CANCELED (800)` | Shortage ≤ cancel threshold, or no usable source found | `ReplenishmentOrderMaintenanceService.cancelOrder:375` |
| `PROCESSABLE` or `STARTED` | `cancelReplenishmentOrder` | `CANCELED (800)` | State < `FINISHED (700)` | `ReplenishorderService.cancelReplenishmentOrder:219` |

Note: `PICKED (600)` exists in `WmsConstants.State` but is not used by the replenishment state machine. The state skips from `STARTED (500)` directly to `FINISHED (700)`.

### Priority values (`WmsConstants.Priority`)

| Constant | Value | Meaning |
|---|---|---|
| `PRIORITY_VERY_LOW` | 0 | Default; assigned to all auto-generated orders |
| `PRIORITY_LOW` | 100 | — |
| `PRIORITY_MEDIUM` | 1000 | — |
| `PRIORITY_HIGH` | 10000 | — |
| `PRIORITY_URGENT` | 100000 | — |

Priority is inherited from the customer order driving the replenishment, via the job's `updateReplenishmentOrderPriority` phase. Orders with `manuallyoverridepriority = true` are excluded from all automatic priority updates.

---

## §6 `FixLocationAssignment` Relationship

A `FixLocationAssignment` (FLA) represents a permanent SKU-to-location binding: "item X always lives at flowbin slot Y."

### How FLAs gate replenishment

1. **Order creation** — `ReplenishGeneratorService.calculateOrder` accepts a `destinationId`. When called from the job's `generateReplenishmentForItemDataWithFixedAssignment` path, `destinationId = fla.assignedlocationId`. Orders for items without a FLA get `destinationId = null`.

2. **Trigger threshold** — `ReplenishOrderJobService.generateReplenishmentForItemDataWithFixedAssignment` checks `stockUnitList.get(0).getAmount() < fla.middlebound`. Only if below the middle bound does it call `calculateOrder` with `required = fla.upperbound - amountOnLocation`.

3. **Maintenance alignment** — `ReplenishmentOrderMaintenanceService.recalculateOrder` calls `resolveActiveAssignment` to fetch the FLA, then `alignDestination` to set `destinationId` on orphaned orders (orders with `destinationId = null` that now have an active FLA). It also uses `fla.upperbound` as the target fill level for shortage calculation.

4. **Cancellation trigger** — `getIdsToCancelReplenishOrders` query cancels orders where `stockUnit.amount >= fla.upperbound` (flowbin full) — `ReplenishOrderJob:269`.

5. **FLA creation at finish** — `MobileReplenishService.finishReplenishmentOrderInternal` creates a FLA on-the-fly if none exists for the destination location, calling `FixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, itemData)`. This means destinations scan-confirmed by the operator implicitly become permanent fixed locations.

6. **FLA deletion** — `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` removes FLAs where the assigned unit load has zero stock AND there is no replenishable source stock AND no open advice positions AND no open replenish orders. Controlled by sysprop `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` (default `false`).

### FLA lifecycle during replenishment

```
                  ┌─────────────────────────────────────────────────┐
                  │  FixLocationAssignment                          │
                  │  assignedlocationId → Location (flowbin slot)  │
                  │  assignedunitloadId → Unitload (container)      │
                  │  itemdataId         → Itemdata (SKU)            │
                  │  upperbound / middlebound / lowerbound          │
                  │  active = true/false                            │
                  └─────────────────────────────────────────────────┘
                               │
       Job reads middlebound    │   finishReplenishmentOrder
       amountOnLocation <       │   transfers stock to
       middlebound → generate   │   assignedunitload
                               ▼
                  ┌─────────────────────────────────────────────────┐
                  │  Replenishorder.destinationId = fla.assignedlocationId │
                  └─────────────────────────────────────────────────┘
```

---

## §7 Multi-Unitload Replenishment Path

Endpoint: `POST /v3/replenish/multi-unitloads` → `MobileReplenishService.fulfillMultipleUnitLoads`.

Request: `{ orderId, destinationLocationId, destinationLocationName, unitLoads: [{ id, labelId, locationId, qty }] }`.

Response: `[{ id, number, qty, unitLoadId, status, destinationLocationId }]` — one entry per order processed.

### Transaction boundary

The entire method runs in a single `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. All-or-nothing: any failure rolls back all stock transfers and order state changes.

### Flow

```
fulfillMultipleUnitLoads(request)
  │
  ├─ 1. Load template order (orderId)
  ├─ 2. assignDestinationForMultiUnitLoads()
  │      validates destination is flowbin, creates FLA if absent,
  │      persists destination on template order
  │
  ├─ 3. For each unitLoad entry:
  │      validateUnitLoadEntry()
  │        ├─ load Unitload (by id or labelId)
  │        ├─ verify unitload.storagelocationId == dto.locationId
  │        └─ find Stockunit with matching itemdataId; check qty
  │
  ├─ 4. First instruction (index 0) — reuses template order:
  │      applyExplicitSourceToOrder()
  │        ├─ release any existing reservation on old stockunit
  │        ├─ set order.stockunitId, requestedlocationId, requestedamount, destinationId
  │        └─ reserveExplicitStockForOrder()
  │      finishReplenishmentOrderWithoutRefill(buildMobileDto())
  │        └─ transfers stock, sets order FINISHED (no refill triggered)
  │
  ├─ 5. Remaining instructions (index 1..N) — new orders per unit load:
  │      ReplenishGeneratorService.createOrderFromTemplate()
  │        ├─ number = template.number + "-" + (i+1)
  │        ├─ copies client, itemdata, prio, manuallyoverridepriority
  │        └─ reserves stock on explicit Stockunit
  │      entityManager.refresh(inst.stock)   ← re-sync after REQUIRES_NEW inner tx
  │      finishReplenishmentOrderWithoutRefill(buildMobileDto())
  │
  └─ 6. Post-batch:
         replenishGeneratorService.refillFixedLocations()   ← single refill pass
         replenishmentOrderMaintenanceService.recalculateOpenOrders(true)
```

### Key subtlety: `entityManager.refresh` after `createOrderFromTemplate`

`createOrderFromTemplate` runs in `Propagation.REQUIRES_NEW`, which commits the inner transaction before returning. The outer persistence context still holds a stale version of `inst.stock` (the `Stockunit`). When the immediately following `finishReplenishmentOrderWithoutRefill` calls `changeReservedAmount → findByIdForUpdate`, Hibernate detects the version mismatch and throws `ObjectOptimisticLockingFailureException`. The `entityManager.refresh(inst.stock)` call at line 797 of `MobileReplenishService` re-syncs the entity with the database before that call — this is load-bearing, not ceremonial.

---

## §8 `ReplenishOrderJob` Integration

`ReplenishOrderJob` is the cron orchestrator. It is not a `@Scheduled` bean itself — it is triggered externally (by a scheduler that reads the `REPLENISHMENT_TIMER_MINUTE` and `REPLENISHMENT_TIMER_HOUR` sysprops). The `doCalculation(Boolean isCronJob)` method runs the full pipeline.

### Concurrency guards

Two-layer guard:
1. **Distributed lock** — `AdvisoryLockService.tryLock(REPLENISH_ORDER)` acquires a PostgreSQL advisory lock. Prevents duplicate execution across replicas in a multi-pod deployment.
2. **JVM-local guard** — `AtomicBoolean RUNNING` prevents overlapping executions within the same JVM.

### Tenant iteration

The job fetches all `TenantDbConfiguration` records from the landlord database, sets `TenantContext.setCurrentTenant(profile)` per tenant, and clears it in the `finally` block. Each tenant runs the full pipeline independently.

### Activation guard

```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(SYSTEM_PROPERTY_REPLENISHMENT_TIMER_ACTIVATED_KEY))) {
    continue;  // skip this tenant
}
```

Both `NEW_CRON_JOB_ACTIVATED` and `REPLENISHMENT_TIMER_ACTIVATED` must be `true`.

### Job pipeline phases

| Phase | Method | What it does |
|---|---|---|
| 1 | `mergePickingOrders()` | Merges tote-on-cart picking orders for TOTES_ON_CART sections. Gated by `MERGE_PICKING_ORDERS` sysprop. |
| 2 | `deleteEmptyFixAssignmentWithoutStockToReplenish()` | Deletes orphaned FLAs. Gated by `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` (default `false`). |
| 3 | `cancelUnreachableReplenishment()` | Cancels orders whose source stock is in a non-replenishable area (`la.useforreplenish = false`). Returns affected IDs. |
| 4 | `cancelReplenishmentIfFlowbinIsFull()` | Cancels orders where `stockUnit.amount >= fla.upperbound`. Returns affected IDs. |
| 5 | `generateReplenishmentForItemDataWithoutFixedAssignment()` | Generates orders for items with open customer orders but no FLA. Uses `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` as the amount. |
| 6 | `generateReplenishmentForItemDataWithFixedAssignmentWithOrders()` | Generates orders for FLA items where demand exceeds stock. Uses native query to find eligible FLA IDs. |
| 7 | `triggerRegularReplenishment()` | Periodic refill of FLAs below their upper bound (the `getRefillFixedLocations` query). |
| 8 | `updateReplenishmentOrderPriority()` | Syncs replenish order priority with customer order priority. Two passes: (a) reset to `PRIORITY_VERY_LOW` orders with no matching customer orders; (b) elevate to match `max(customerOrder.prio)` for orders that have active customer demand. |
| 9 | `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` | Back-fills `destinationId` on orders that gained a FLA since creation. |
| 10 | `recalculateForItem` / `recalculateOpenOrders` | Calls `ReplenishmentOrderMaintenanceService` — targeted for affected items, or cadence-gated full recalc if nothing changed. |

### Affected item tracking

Phases 3–7 return lists of affected IDs. The job unions these into `Set<Long> affectedItemIds` and calls `replenishmentOrderMaintenanceService.recalculateForItem(itemId)` per item. If `affectedItemIds` is empty (quiet cycle), it falls back to `recalculateOpenOrders(false)` which respects the cadence sysprop.

---

## §9 Cross-Service Interactions

### With `StockunitBusinessService`

`changeReservedAmount(stock, delta, isDelta, activityCode, orderNumber, comment)` is the central reservation primitive. Activity codes used by replenishment:

| Code constant | Value | When written |
|---|---|---|
| `CODE_REPLENISHMENT_CREATED` | `"REPLENISHMENT_CREATED"` | Order created; reservation added |
| `CODE_REPLENISHMENT` | `"REPLENISHMENT"` | Reservation adjustment during recalc |
| `CODE_REPLENISHMENT_FINISHED` | `"REPLENISHMENT_FINISHED"` | Reservation released at order finish |
| `CODE_REPLENISHMENT_CANCELLED` | `"REPLENISHMENT_CANCELLED"` | Reservation released at cancel |
| `CODE_REPLENISHMENT_SWITCHED` | `"REPLENISHMENT_SWITCHED"` | Reservation transferred when source unit load is switched |
| `CODE_REDIRECT_REPLENISHMENT_SOURCE` | `"REDIRECT_REPLENISHMENT_SOURCE"` | Reservation transferred during manual source redirect |

`transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked, ...)` is called at `finishReplenishmentOrderInternal` to physically move stock to the FLA's assigned unit load.

### With Picking

The replenish job's phase 8 reads `customerorder.prio` to derive replenishment priority. If a customer order's priority changes, the replenishment order tracking that item will be updated on the next job cycle. The job also reads `customerorder_position` to find items with insufficient stock for upcoming orders (phases 5–6).

### With `FixLocationAssignmentService`

`createFixedLocationAssignment(location, itemdata)` is called in two scenarios:
- `MobileReplenishService.checkDestination` — when an operator scans a new flowbin with no existing FLA.
- `MobileReplenishService.finishReplenishmentOrderInternal` — when no FLA exists at the destination at finish time.

This means replenishment execution can create FLAs as a side effect.

---

## §10 Repository Native Queries

### `ReplenishorderRepository` — key queries

| Method | Type | Purpose |
|---|---|---|
| `findByIdForUpdate(id)` | JPQL + `PESSIMISTIC_WRITE` | Pessimistic lock for concurrency-sensitive updates |
| `getIdsForUnreachableReplenishOrders(state)` | Native | Finds orders where source stock's location area has `useforreplenish = false` |
| `getIdsToCancelReplenishOrders(state)` | Native | Finds orders where `stockUnit.amount >= fla.upperbound` (flowbin full) |
| `getIdsToDeleteEmptyFixAssignmentWithoutStockToReplenish(...)` | Native | Complex: FLAs with zero stock, no replenishable source, no open advice or replenish orders |
| `getIdsForItemDataWithFixedAssignmentWithOrders(...)` | Native | FLA IDs where demand (sum of open cop.amount + reservedAmount) > stockUnit.amount |
| `getIdsToUpdateReplenishmentOrderPriority(...)` | Native | Replenish orders with no active customer demand (priority should reset to VERY_LOW) |
| `getIdsToUpdateReplenishmentOrderPriority2(...)` | Native | Replenish orders whose priority doesn't match max customer order priority |
| `sumRequestedAmountForOpenOrders(state, itemDataId, destinationId, excludedId)` | JPQL | Sum of inbound replenishment already en route to a location (used by recalc to avoid over-ordering) |
| `findDetailMapById(id)` | Native | Full detail join (client, itemdata, user, locations, rack, stock) for desktop detail view |
| `bulkUpdatePriorityForItems(priority, itemdataIds, state, currentPrio)` | `@Modifying` JPQL | Bulk priority update — used by picking order priority sync |

### `StockunitRepository` — replenishment-specific queries

| Method | Purpose |
|---|---|
| `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage(notLocked, itemDataId, useForDeepStorage)` | Source stock selection in `calculateOrder`. Two passes: non-deep-storage first, then deep-storage fallback. |
| `getAvailableReplenishmentSources(itemDataId)` | Used by `redirectSource` in maintenance service to find best alternative source (prefers same area). Returns `[stockUnitId, amount, reserved, unitloadId, locationId, locationName, areaId]`. |
| `getStockAndReservedForLocation(itemDataId, locationId)` | Returns `[amount, reservedAmount]` at a specific destination location for shortage calculation. |
| `getStockAndReservedForPickingAreas(itemDataId)` | Returns `[amount, reservedAmount]` across all picking areas when no specific destination is set. |
| `getStockUnitInfoForReplenishment(itemDataId)` | Returns available unit loads with amount and location name for the desktop "change source" UI. |

### `FixLocationAssignmentRepository` — key queries

| Method | Purpose |
|---|---|
| `getRefillFixedLocations(replenishOrderStatus)` | FLAs eligible for refill: `stockUnit.amount < fla.upperbound` AND no open replenish order at that state. |
| `getRefillFixedLocationIds(replenishOrderStatus)` | ID-only variant of above (lighter query for the job loop). |
| `findByItemdataIdIn(ids)` | Bulk FLA fetch by itemdata IDs — used by maintenance service `RecalcContext` builder. |

---

## §11 Known Limitations and Landmines

### 1. `refillFixedLocations()` has no transaction boundary — landmine

`ReplenishGeneratorService.refillFixedLocations()` is `public void` with no `@Transactional`. Each item in its loop calls `refillSingleFixedLocation(ass.getId())` which runs in `REQUIRES_NEW`. A failure in one item is swallowed and logged, but the loop itself has no outer transaction — meaning partial completion is the intended behavior here, but the method is also called mid-transaction from `MobileReplenishService.finishReplenishmentOrderInternal` (line 503) when `triggerRefill = true`. That call runs inside the finish transaction; if refill throws unexpectedly, the finish transaction rolls back. The `try/catch` at line 505 is a mitigation, but callers should audit this path.

**Downstream plan needed:** Add a verify script to confirm `refillFixedLocations` is always invoked from within a safe context. See `wms-bugfix-plan` convention.

### 2. `calculateOrder` returns `null` for duplicate — callers must handle

When a `PROCESSABLE` order already exists for the same item + destination, `calculateOrder` returns `null` (not an exception). Several callers silently discard this: `ReplenishorderService.create` returns `null` to the controller which returns HTTP 200 with empty body. Callers should be aware that `null` means "order already exists, nothing to do" — not an error.

### 3. FLA auto-creation at `checkDestination` and `finishReplenishmentOrder` — surprise side effect

Both `checkDestination` and `finishReplenishmentOrderInternal` can create `FixLocationAssignment` records as a side effect of an operator's scan. This is by design for the flowbin assignment flow, but can create unexpected FLAs if an operator scans the wrong destination. There is no undo mechanism — FLA deletion requires the job's cleanup phase (which is off by default) or manual DB intervention.

### 4. Transaction boundaries on the recalculate methods

**Current state (after 260520 fix):**

| Method | `@Transactional`? | Notes |
|---|---|---|
| `recalculateOpenOrders(boolean)` | **No** | Intentional — 260331 decision. The sweep calls `self.recalculateOrder` per order so each order opens its own short REQUIRED tx. |
| `recalculateForItem(Long)` | **Yes** — `tenantTransactionManager` | The HTTP-callable entry point. Inner loop calls `this.recalculateOrder` (bypasses proxy — see §5.4 warning below). |
| `recalculateOrder(Replenishorder, RecalcContext)` | **Yes** — `tenantTransactionManager, REQUIRED` | Added 260520. Provides the tx that `findByIdForUpdate(@Lock PESSIMISTIC_WRITE)` requires. Per-order short tx from the sweep; annotation bypassed from `recalculateForItem` (this. call). |

**SBDEV-2234 (2026-05-18):** `recalculateForItem(Long)` gained `@Transactional(tenantTransactionManager)`. `recalculateOpenOrders(boolean)` intentionally remained NON-transactional (260331 decision). `findByIdForUpdate(@Lock PESSIMISTIC_WRITE)` was added expecting the sweep to provide a tx — but no per-order tx was opened, causing `InvalidDataAccessApiUsageException` in production.

**260520 fix:** `recalculateOrder(Replenishorder, RecalcContext)` is now `public @Transactional(tenantTransactionManager, REQUIRED)`. `recalculateOpenOrders(boolean)` calls it via `self.recalculateOrder(order, ctx)` (self-injection through CGLIB proxy) so each order gets its own short REQUIRED tx. The per-order auto-commit design from 260331 is preserved.

**§5.4 WARNING — do NOT change `recalculateForItem`'s inner loop to `self.recalculateOrder`:** `recalculateForItem` has an outer REQUIRED tx. Routing the inner loop through the proxy would cause `@Transactional + rollbackFor` to mark the shared outer tx rollback-only on any unchecked exception, which the try/catch swallows — but `UnexpectedRollbackException` fires on commit, poisoning all sibling orders. Most acute when called from `StockunitService.transferStock`.

**Risk:** `recalculateOpenOrders(true)` called from `MobileReplenishService.fulfillMultipleUnitLoads` (line 806) runs inside the outer `@Transactional` method — the self.recalculateOrder call opens a REQUIRED tx that joins the outer tx, so saves are still part of the outer transaction. Correct behavior but may be surprising.

### 5. Amount cap at source stock size — silent reduction

`calculateOrder` caps `requestedamount` at `sourceStock.getAmount()`:
```java
replenishOrder.setRequestedamount(amount.compareTo(sourceStock.getAmount()) > 0 ? sourceStock.getAmount() : amount);
```
If a pallet holds less than the FLA's full `required` amount, the order silently delivers less than `upperbound - current`. No partial-fill flag or follow-up order is created. The destination may remain below `upperbound` until the next job cycle.

### 6. Multi-unitload `entityManager.refresh` dependency — fragile ordering

The `entityManager.refresh(inst.stock)` call in `fulfillMultipleUnitLoads` (line 797) is load-bearing (see §7). Removing it, moving it, or calling `createOrderFromTemplate` inside the outer transaction instead of `REQUIRES_NEW` will cause `ObjectOptimisticLockingFailureException` on the second unit load. Any refactoring of the multi-unitload path must preserve this refresh.

### 7. Source stock selector prefers "enough stock" but falls back silently

`calculateOrder` iterates `stockList` in order (returned by `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage`) and picks the first stock unit with `amount >= requestedAmount`. If none exists, it falls back to `stockList.get(0)` (the first available unit). The `requestedamount` is then capped to that stock's actual amount, producing a partial-fill order with no warning.

### 8. `manuallyoverridepriority` bypass is total

Once `manuallyoverridepriority = true`, all automatic priority updates are skipped by both `ReplenishmentOrderMaintenanceService.recalculateOrder` and `ReplenishOrderJob.updateReplenishmentOrderPriority`. There is no TTL or expiry mechanism — the manual override sticks until the operator explicitly changes the priority again via the desktop UI (which sets `manuallyoverridepriority = true` again) or through direct DB correction.

### 9. No cross-tenant replenishment

Each job iteration calls `TenantContext.setCurrentTenant(profile)` before any query. All repositories route to the current tenant's database. There is no mechanism for cross-tenant stock movement.

---

## §12 Related Docs

| Document | Location |
|---|---|
| WMS2 Replenish Workflow | `sbdocs/3-Resources/workflows/wms2-replenish-workflow.md` |
| WMS2 Multi-Unitload Replenish Workflow | `sbdocs/3-Resources/workflows/wms2-multi-unitload-replenish.md` |
| WMS2 Replenish Order Creation Workflow | `sbdocs/3-Resources/workflows/wms2-replenish-order-creation.md` |
| WMS1 Replenish Workflow | `sbdocs/3-Resources/workflows/wms1-replenish-workflow.md` |
| WMS1 StockUnit Design | `sbdocs/3-Resources/design/wms1-stockunit-design.md` |

---

## §13 Verification Log

| Date | Verified by | Notes |
|---|---|---|
| 2026-04-27 | Claude (executor) | Initial doc — all service methods read from source; all state constants verified against `WmsConstants.java`; entity fields verified against `Replenishorder.java` and `FixLocationAssignment.java`; repository queries verified against `ReplenishorderRepository.java` |
| 2026-05-08 | Claude (executor) | SBDEV-1699 (commit `c4fcfc1`) verified live: `ViewDtoService.getStockPerLocation` (line 672 onwards) uses batched `fixLocationAssignmentRepository.findByItemdataIdIn(itemdataIds)` (line 684); `ReplenishmentMonitorViewRepository` SQL exposes `f.upperbound AS fix_assignment_upperbound` (line 64) with re-projected aggregate column at line 31; `ReplenishMonitorSummaryView.getFix_assignment_upperbound()` getter present (line 32); `ViewDtoService.getReplenishMonitorViewSummary` (line 1194) emits DTO `locationStock` (line 1232 — `dto.put("locationStock", fixUpperBound.subtract(qtyOnLoc).longValue())`); `ViewDtoService.getReplenishMonitorViewSummary` and the detail-view method at line 601 both annotated `@Transactional(value = "tenantTransactionManager", readOnly = true)`. No drift to module body required. |
| 2026-05-19 | Claude (executor) | SBDEV-2234 (merged 2026-05-18): `recalculateForItem(Long)` now `@Transactional(tenantTransactionManager)` — §4 limitation #4 updated to reflect this; `recalculateOpenOrders(boolean)` intentionally remains non-transactional (260331 decision, confirmed in tx-osiv-boundary-map 2026-05-15 entry). `ReplenishorderRepository.findByIdForUpdate` now actively called by `recalculateOrder` (already documented in §key files table). `SyspropService.setSysvalue` added (documented in wms2-sysprop-catalog 2026-05-15). `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` sysprop replaces JVM-local `lastRun` field. |
| 2026-05-20 | Claude (executor) | 260520 fix: `recalculateOrder(Replenishorder, RecalcContext)` now `public @Transactional(tenantTransactionManager, REQUIRED)` (Fix A — plan `260520-replenishment-open-orders-missing-tx`). `@Lazy @Autowired self` field added to service; `recalculateOpenOrders(boolean)` sweep loop changed to call `self.recalculateOrder(order, ctx)` (per-order short REQUIRED tx). §4 method table updated (visibility + annotation), §4 limitation #4 rewritten to reflect new 3-method tx boundary table. §5.4 WARNING documented. |
