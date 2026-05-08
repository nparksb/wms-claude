---
title: WMS v1 Replenish Order Creation
type: workflow
project: wms1
status: stable
created: 2026-04-26
last_verified: 2026-05-01
tags: [wms1, workflow, replenish]
---

# Replenish Order Creation

This document traces every code path that results in the creation of a `Replenishorder` entity. All statements reference actual implementations—no assumptions were added.

## Triggers That Request a New Order

- **Scheduled pipeline** – `ReplenishOrderJob.doCalculation` runs either on demand or via cron. When `isCronJob` is `true`, it first checks the `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` and `SYSTEM_PROPERTY_REPLENISHMENT_TIMER_ACTIVATED_KEY` system properties and aborts if either is disabled (`src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:23-43`). Once enabled, it executes a fixed sequence (`mergePickingOrders`, `deleteEmptyFixAssignmentWithoutStockToReplenish`, `cancelUnreachableReplenishment`, `cancelReplenishmentIfFlowbinIsFull`, `generateReplenishmentForItemDataWithoutFixedAssignment`, `generateReplenishmentForItemDataWithFixedAssignmentWithOrders`, `triggerRegularReplenishment`, `updateReplenishmentOrderPriority`, `recalculateReplenishmentOrderWithoutFixedLocationAssignment`) before returning (`src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:57-110`). The steps that actually create orders are described below.

- **Manual/mobile request** – `/v3/replenish/requestAmount` accepts a `ReplenishMobileOrderDto` payload and forwards it to `MobileReplenishService.requestReplenish` (`src/main/java/net/aim_ai/wms/controller/mobile/ReplenishController.java:33-78`). The service loads the client (`clientNumber`), item (`itemNumber` scoped to the client), destination location (`destinationLocationName`), and requested quantity (`amountRequested`) and then calls `ReplenishGeneratorService.calculateOrder`. Any failure (missing item, missing location, `calculateOrder` throwing a `FacadeException`) is surfaced back to the caller (`src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java:503-525`).

- **Service-level creation** – `ReplenishorderService.create` is used by administrative flows. It mirrors the mobile path: resolve client/item/destination from `ReplenishMobileOrderDto`, then call `calculateOrder` while also passing the DTO’s priority (`src/main/java/net/aim_ai/wms/service/ReplenishorderService.java:59-73`).

- **Auto-refill after finishing** – `/v3/replenish/checkDestination` invokes `MobileReplenishService.finishReplenishmentOrder`, which finalizes the current order and then immediately calls `replenishGeneratorService.refillFixedLocations()` (`src/main/java/net/aim_ai/wms/controller/mobile/ReplenishController.java:155-199`, `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java:359-425`). That refill run can create new `Replenishorder` entities as soon as an operator puts stock away.

In every case above, the actual order calculation work happens inside `ReplenishGeneratorService`.

## How Shortages Are Detected Before Creation

- **Fixed locations needing refill** – `FixLocationAssignmentRepository.getRefillFixedLocations` returns assignments where (1) the unit load linked to the assignment holds less stock than the assignment’s lower bound, (2) the assignment is active, (3) no open `Replenishorder` already references the same destination or item, and (4) there exists at least one unlocked (entity-lock = 0) stock unit for the item in an area that allows replenishment (`src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java:34-74`). `ReplenishGeneratorService.refillFixedLocations` consumes that list, loads the assigned unit load, calculates the missing amount as `upperBound - currentAmount`, and immediately calls `calculateOrder` with the assignment’s item and destination (`src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java:48-69`).

- **Items that lack a fixed assignment** – `ReplenishOrderJob.generateReplenishmentForItemDataWithoutFixedAssignment` gathers item IDs that simultaneously (a) have customer-order demand in state `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` before their assigned orders are released, (b) lack any fixed location assignment, (c) do not already have an open `Replenishorder`, (d) have no stock in a picking-enabled area, and (e) do have stock in a replenishment-enabled area (`src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:200-238`, `src/main/java/net/aim_ai/wms/repo/jpa/ItemdataRepository.java:66-104`). The service simply forwards the item ID, calculated upper bound, and a `null` destination to `calculateOrder` (`src/main/java/net/aim_ai/wms/service/job/ReplenishOrderJobService.java:59-88`).

- **Fixed assignments referenced by open orders** – `ReplenishOrderJob.generateReplenishmentForItemDataWithFixedAssignmentWithOrders` walks every fixed assignment that already has picking demand and delegates to `ReplenishOrderJobService.generateReplenishmentForItemDataWithFixedAssignment` (`src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:240-308`). That service validates the fixed assignment (exactly one stock unit on the assigned unit load, unit load located at the fixed location, labels matching, assignment active, etc.), computes `required = upperBound - amountOnLocation`, and, if the amount on location is below the assignment’s middle bound, again invokes `calculateOrder` with the fixed location ID (`src/main/java/net/aim_ai/wms/service/job/ReplenishOrderJobService.java:90-184`).

- **Regular top-off** – After the specialized generators above, the job also calls `ReplenishOrderJobService.triggerRegularReplenishment`, which is a thin wrapper around `refillFixedLocations()` and therefore reuses the logic described in the first bullet (`src/main/java/net/aim_ai/wms/service/job/ReplenishOrderJobService.java:186-199`).

## Order Calculation and Persistence

`ReplenishGeneratorService.calculateOrder` is the single place where a `Replenishorder` object is instantiated and persisted, regardless of which trigger called it (`src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java:74-151`). The method performs the following deterministic steps:

1. **Validation** – load the `Itemdata` row for `itemDataId` and reject non-positive `amount` values with a `FacadeException`.
2. **Source stock search** – query `stockunitRepository.getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` twice: first against non-deep-storage areas, then (if nothing is found) against deep-storage areas. Each row returns a stock unit ID and its available amount in a location that allows replenishment and is completely unlocked (`src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java:61-93`).
3. **Stock selection** – pick the first candidate whose amount is >= the requested `amount`; if none qualify, fall back to the first candidate in the list. Fetch the `Stockunit` and its `Unitload` for later use.
4. **`Replenishorder` population** – set the following fields before persisting via `replenishorderRepository.save`:
   - `id`/`number`: generated via `replenishorderRepository.getNextId()` and `BasicService.generateReplenishNumber()` (`src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java:119-127`, `src/main/java/net/aim_ai/wms/service/BasicService.java:90-105`).
   - `clientId` and `itemdataId`: copied from the selected `Itemdata`.
   - `requestedlocationId`: the storage location of the source unit load.
   - `destinationId`: whatever was supplied by the caller (can be `null`).
   - `requestedamount`: the smaller of the caller’s `amount` and the amount currently on the chosen stock unit.
   - `stockunitId`: the chosen source stock unit.
   - `state`: initialized to `WmsConstants.State.PROCESSABLE`.
   - `prio`: caller-provided priority or `WmsConstants.Priority.PRIORITY_VERY_LOW` when the overload without an explicit priority is used.
   - Administrative fields such as `manuallyoverridepriority=false`, `entityLock=0`, and `sourcelocationname` populated from the source location.
5. **Reservation** – immediately reserve the requested amount on the chosen stock unit by calling `stockUnitBusinessService.changeReservedAmount` with the `CODE_REPLENISHMENT_CREATED` reason and the order number. This locks the inventory for the newly created order.
6. **Return** – hand the fully populated `Replenishorder` entity back to the caller; callers then transform it into DTOs or continue with their own workflows.

If no suitable stock unit exists, the method throws a `FacadeException` detailing the missing stock and destination instead of creating an order.

## What Each Caller Does With the Result

- **Mobile request** – After `calculateOrder` succeeds, `MobileReplenishService.requestReplenish` materializes a fresh `ReplenishMobileOrderDto` using `setOrderToReplenishMobileOrder` and returns it to the device. This DTO includes the source location/unitload, requested quantity, state, and optional destination so the operator can begin scanning immediately (`src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java:505-525` and `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java:527-575`).

- **Scheduled job** – The job has no further action after `calculateOrder` returns; orders sit in the PROCESSABLE state until devices pick them up. The job’s final step (`recalculateReplenishmentOrderWithoutFixedLocationAssignment`) recalculates metadata for any PROCESSABLE orders without fixed locations, but it does not change the creation logic (`src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:100-109` and `src/main/java/net/aim_ai/wms/service/job/ReplenishOrderJobService.java:201-223`).

- **Administrative service** – `ReplenishorderService.create` simply relays the `Replenishorder` returned from the generator back to its own caller. No additional mutations occur (`src/main/java/net/aim_ai/wms/service/ReplenishorderService.java:59-73`).

With these components combined, every path that creates a new replenish order is fully documented and traceable to concrete code locations.


---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |

**Re-verify every 60 days.** Next due: **2026-06-30**.
