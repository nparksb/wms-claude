---
title: WMS v2 Replenish Workflow
type: workflow
project: wms2
status: stable
created: 2026-04-19
last_verified: 2026-05-08
tags: [wms2, workflow, replenish]
---

# Replenish Workflow

### Flow Overview

- Replenish work is continuously prepared by ```ReplenishOrderJob.doCalculation```, which (once enabled) executes a pipeline of housekeeping tasks—merge tote-on-cart picks, delete empty fixed assignments, cancel unreachable or flow-bin-full orders, generate new replenishments for both fixed/non-fixed items, update priorities, and recalc open orders—so the system always has up-to-date PROCESSABLE replenish orders ready for execution [(src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java (lines 57-88))](/src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java#L57-L88).

- When a shortage is detected (either proactively via the job, reactively after an order is completed, or on-demand via the `/v3/replenish/requestAmount` endpoint), ```ReplenishGeneratorService``` picks up the request: ```refillFixedLocations``` walks the fixed assignments and computes each assignment’s missing quantity, while ```requestReplenish``` simply passes the operator-entered amount straight into ```calculateOrder```. Both paths select a source stock/unit load, populate client/item/destination metadata, set the state to PROCESSABLE, and reserve the requested amount so the goods are locked for that task [(src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java (lines 48-145); src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 508-525))](/src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java#L48-L145).

### Execution Steps

- Mobile clients materialize these orders via ```ReplenishMobileService```. Operators usually scan the destination location, which validates that it is a fixed assignment and, if there is an active order, loads its details (item, client, destination) into a ```ReplenishMobileOrderDto``` so the handheld shows what to pick and where to deliver [(src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 99-129))](/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java#L99-L129).

- To begin working, the user calls ```startOrder```, which ensures the order is not already finished, prevents other operators from hijacking it, and moves it from PROCESSABLE to STARTED while recording the current operator ID [(src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 177-193))](/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java#L177-L193). Orders can also be reset back to PROCESSABLE, but only if they were already released (state ≥ PROCESSABLE) and are not yet finished [(src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 195-208))](/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java#L195-L208).

- At the source, ```checkSource``` enforces that the scanned unit load/location matches the reserved unit load. If “pick any” is allowed and a different unit load is scanned, the service verifies it holds a single, unreserved stock unit of the right item, switches the order to that stock, and transfers the reservation to the new unit load/location [(src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 210-286))](/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java#L210-L286).

- At the destination, ```checkDestination``` first allows the operator to scan the already-assigned destination or the original source unit-load label and simply returns if either matches; only when a new location is scanned does it enforce that the item currently lacks another fixed assignment, that the scanned location exists, its label corresponds to an existing unit load, the location is a flow-bin, empty, and unassigned. When those checks pass it creates the fixed assignment for that location/item pair and writes the destination info back onto the order DTO [(src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 300-356))](/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java#L300-L356).

- ```checkAmountPicked``` is purely a validation call: it ensures the entered quantity is positive and not greater than the remaining stock, but the controller does not persist that value anywhere, so the handheld must keep track of the operator’s entry itself [(src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 428-442); src/main/java/net/aim_ai/wms/controller/mobile/ReplenishController.java (lines 155-176))](/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java#L428-L442).

- ```finishReplenishmentOrder``` closes the loop: it reloads the order, revalidates source stock and destination, clears any reserved quantities, ensures the destination has an assigned unit load (creating one if missing), and transfers **all** stock that remains on the reserved unit load (because ```amountPicked``` is still null when the controller reloads the DTO) onto that unit load before marking the order FINISHED and triggering another ```refillFixedLocations()``` run. The mobile controller calls this immediately after a successful ```checkDestination```, so users do not invoke a separate “finish” step [(src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java (lines 359-425); src/main/java/net/aim_ai/wms/controller/mobile/ReplenishController.java (lines 180-200))](/src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java#L359-L425).


---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |
| 2026-05-08 | SBDEV-1699 (commit `c4fcfc1`) — verified the new `ViewDtoService.getStockPerLocation` batched lookup via `findByItemdataIdIn`, `ReplenishMonitorSummaryView.getFix_assignment_upperbound()` projection, `f.upperbound AS fix_assignment_upperbound` in `ReplenishmentMonitorViewRepository`, and the new `locationStock` DTO emission. None of these surface in this workflow doc body (which describes the operator-visible flow only), so no body edits required. | All claims still accurate; only frontmatter bumped. | Code read |

**Re-verify every 60 days.** Next due: **2026-07-07**.
