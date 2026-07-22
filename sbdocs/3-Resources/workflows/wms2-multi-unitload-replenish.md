---
title: WMS v2 Multi-Unit Load Replenishment
type: workflow
project: wms2
status: stable
created: 2026-04-19
last_verified: 2026-07-10
tags: [wms2, workflow, replenish]
---

# Multi-Unit Load Replenishment Endpoint Plan

## Background
- The existing workflow (`docs/replenish-workflow.md`) already explains how replenish work is generated in `ReplenishOrderJob.doCalculation`, converted into `Replenishorder` entities through `ReplenishGeneratorService.calculateOrder`, and executed end-to-end in `MobileReplenishService` (loading the order, validating source/destination, and calling `finishReplenishmentOrder` to transfer stock and trigger follow-up refills).
- `docs/replenish-order-creation.md` documents that *every* order goes through `ReplenishGeneratorService.calculateOrder`, which enforces item/destination validation, picks a source stock unit, reserves quantity, and persists the order before any mobile workflow interacts with it. To keep that invariant while injecting authoritative source/destination data, this plan introduces `ReplenishGeneratorService.createOrderFromTemplate`, a companion that mirrors every validation/persistence/reservation step from `calculateOrder` but accepts the explicit `Stockunit`, location, and quantity. The template order referenced by `orderId` is reused (not recreated) for the first unit load, while every ad-hoc multi-unit-load order is instantiated through the new method.
- The new endpoint needs to respect both flows: (1) fulfill the provided `orderId` through the same validations and finishing logic the mobile workflow already uses, and (2) create additional ad-hoc orders using the documented creation logic, but allowing explicit source unit loads, locations, quantities, and order numbers derived from the template order.

## Goals
- Accept a payload `{ orderId, destinationLocationId, unitLoads: [{ id, locationId, qty }, ...] }` and fulfill the first unit load against the provided order.
- When the payload contains more unit loads than the original order can cover, create ad-hoc replenish orders (per `docs/replenish-order-creation.md`) that reuse the template order’s client, item, and priority while forcing the supplied source unit load, source location, amount, destination, and a generated order number derived from the template order’s number (for example, `RPL1234-2`, `RPL1234-3`, …).
- All orders (original + ad-hoc) must flow through logic identical to `MobileReplenishService.finishReplenishmentOrder`; we will clone that method into a new `finishReplenishmentOrderWithoutRefill` helper so the validations/stock transfer stay identical, but the `refillFixedLocations()` invocation is deferred until the entire batch completes.
- The `destinationLocationId` provided in the payload overrides whatever destination was stored in the template order and is also copied to every ad-hoc order; unit-load instructions never influence the destination.

## Endpoint Contract
- **HTTP**: `POST /v3/replenish/multi-unitloads` (name can change, but `/v3/replenish` stays consistent with `ReplenishController`).
- **Request body**:
  ```json
  {
    "orderId": 123,
    "destinationLocationId": 456,
    "unitLoads": [
      { "id": 1, "locationId": 11, "qty": 5.5 },
      { "id": 2, "locationId": 22, "qty": 2 }
    ]
  }
  ```
- **Response**: list of processed orders `[{ id, number, qty, unitLoadId, status, destinationLocationId }]` so the client knows which ad-hoc IDs were created, which amounts were transferred, and what destination was applied.

## High-Level Flow
0. **Transactional boundary**:
   - The orchestrating service method must be annotated with `@Transactional` so any failure (validation, reservation, stock transfer, ad-hoc creation) causes the entire batch to roll back—no partial replenishments should remain if the endpoint returns an error.
1. **Controller** (`ReplenishController`):
   - Add the new POST endpoint.
   - Validate the payload shape and delegate to `MobileReplenishService.fulfillMultipleUnitLoads`.
   - Map domain errors (`FacadeException`, `BusinessException`) into the same `{ errors: [...] }` structure used throughout the controller.
2. **Service orchestration** (`MobileReplenishService.fulfillMultipleUnitLoads`):
   - Load the template `Replenishorder` once and eagerly fetch related entities (`Client`, `Itemdata`, `Location`) to avoid N+1 queries within the loop.
  - Resolve the authoritative destination via `locationRepository.findById(destinationLocationId)` and invoke a destination-assignment helper that reuses the `checkDestination` validations (fixed-assignment enforcement, flow-bin verification, empty-location checks) but operates on the provided `destinationLocationId` rather than a scanned label. The helper runs immediately after the template order is loaded; once the checks pass it writes the authoritative destination onto the template order so every subsequent DTO or ad-hoc order automatically sees the override.
  - For each unit load entry:
    1. Validate existence of the `Unitload`, ensure `unitLoad.getStoragelocationId()` equals `locationId`, and fetch the matching `Stockunit` for the template item by calling `stockunitRepository.findByUnitloadId` and filtering for the stock with the order’s `itemdataId`, verifying it contains at least `qty`.
    2. Collect the validated `Stockunit`, `Unitload`, and requested quantity into an instruction list so later steps can reuse the resolved entities. No stock splitting is required because the transfer amount is controlled through `ReplenishMobileOrderDto.amountPicked`.
3. **Prepare the template order (index 0)**:
   - If the order currently reserves stock, call `stockunitBusinessService.changeReservedAmount` to release it before reusing the order.
   - Set the order’s `destinationId`, `stockunitId`, `requestedlocationId`, `requestedamount`, and `sourcelocationname` so they match the first instruction’s source data while forcing the destination to `destinationLocationId`, persisting the override so the authoritative destination is visible on future loads.
   - Reserve the intended `qty` on the explicit stock by calling the `reserveExplicitStockForOrder` helper described below.
   - Build a `ReplenishMobileOrderDto` via the dedicated `buildMobileDto` helper so all fields (source/destination IDs, labels, and `amountPicked`) reflect the authoritative instruction data before calling `finishReplenishmentOrderWithoutRefill`. Setting `amountPicked` inside the helper is essential: `ReplenishController.checkDestination` reloads the order before finishing it, which clears `amountPicked` and causes the current workflow to move the entire stock unit. This orchestrator must therefore populate `amountPicked` immediately before finishing so only the requested quantity is transferred without splitting inventory.
4. **Create and finish ad-hoc orders (index ≥ 1)**:
   - Implement `ReplenishGeneratorService.createOrderFromTemplate(Replenishorder template, Stockunit sourceStock, BigDecimal qty, Long destinationId, int sequenceIndex)` as the exclusive instantiation/persistence path for the additional orders. The method literally copies the validation/persistence/reservation logic in `calculateOrder` (ID generation, requested-amount bounds, metadata population, state/priority defaults, and reservation bookkeeping) while injecting authoritative fields (explicit source stock, requested location, destination, quantity, and derived order number). Inside the method, build the order number by taking `template.getNumber()` and appending `"-" + (sequenceIndex + 1)` so numbering stays consistent even if callers do not supply strings.
   - Reserve exactly `qty` against the explicit stock id using the same reservation mechanism described for the template order (either directly via `stockunitBusinessService.changeReservedAmount` or via `reserveExplicitStockForOrder`).
   - After persistence, reuse the same DTO/`finishReplenishmentOrderWithoutRefill` helper so each order is validated and stock is transferred without re-triggering the refill job.
5. **Response building**:
   - Collect each finished order’s `id`, `number`, processed quantity, `unitLoadId`, `status`, and `destinationLocationId` (matching the endpoint contract) and return them in order.
6. **Final refill trigger**:
   - After the loop completes successfully, call `replenishGeneratorService.refillFixedLocations()` exactly once so the downstream workflow is aligned with the current single-order behavior but avoids redundant recalculations after each unit load.

## Detailed Implementation Tasks
1. **DTOs & validation**:
   - Introduce `MultiReplenishRequestDto` and `MultiReplenishUnitLoadDto` in `src/main/java/net/aim_ai/wms/json/mobile/`.
   - Annotate with validation constraints (non-null `orderId`, non-empty `unitLoads`, `qty > 0`).
2. **Controller**:
   - Add the endpoint method (`multiUnitLoads`) using the DTOs and existing error-handling pattern.
3. **Service helpers**:
   - `MobileReplenishService.fulfillMultipleUnitLoads(MultiReplenishRequestDto request)` orchestrates the flow described above.
   - Add private helpers for:
     - `validateUnitLoadEntry(Replenishorder template, MultiReplenishUnitLoadDto dto, Location authoritativeDestination)` returning the resolved `Stockunit` and `Unitload`.
     - `applyExplicitSourceToOrder(Replenishorder order, Stockunit sourceStock, BigDecimal qty, Location destination)` which updates the entity and reserves the quantity by calling a new method in `ReplenishGeneratorService` (or directly inside the service if better scoped).
     - `buildMobileDto(Replenishorder order, Stockunit stock, Location destination, BigDecimal qty)` so we can pass a fully-populated DTO with `amountPicked = qty` into the “finish without refill” helper, avoiding stock splits for partial transfers.
     - `finishReplenishmentOrderWithoutRefill(ReplenishMobileOrderDto dto)` which encapsulates the current `finishReplenishmentOrder` logic except for the final `refillFixedLocations()` call, letting the batch orchestrator explicitly trigger the refill job once at the end.
     - `assignDestinationForMultiUnitLoads(Replenishorder template, Long destinationId)` that mirrors `checkDestination` step-by-step but resolves the destination internally from the supplied ID instead of a scanned label. It runs immediately after loading the template order, persists the authoritative destination on that entity, and returns the resolved `Location` so any subsequent ad-hoc orders already inherit the override.
4. **Generator extension**:
   - Add `Replenishorder createOrderFromTemplate(Replenishorder template, Stockunit stock, BigDecimal amount, Long destinationId, int sequenceIndex)`:
     - Validate amount > 0 (same as `calculateOrder`).
     - Load the `Unitload` for the provided `Stockunit` to set `requestedlocationId` and `sourcelocationname`.
     - Populate the new entity copying the template’s `clientId`, `itemdataId`, `prio`, `manuallyoverridepriority`, and state fields exactly like `calculateOrder`, including ID generation.
     - Derive the order number inside the method as `template.getNumber() + "-" + (sequenceIndex + 1)` so numbering remains deterministic without external strings.
     - Persist and reserve via `stockunitBusinessService.changeReservedAmount`, mirroring the `CODE_REPLENISHMENT_CREATED` reservation from `calculateOrder`.
   - Expose a smaller helper (`reserveExplicitStockForOrder`) if we want to reuse the reservation logic for both the original order and ad-hoc orders.
5. **Destination handling**:
   - Introduce a dedicated helper (e.g., `assignDestinationForMultiUnitLoads`) that copies the logic from `MobileReplenishService.checkDestination` line-for-line (same validations, logging, and fixed-assignment creation) but accepts the authoritative `destinationLocationId` directly and runs immediately after the template order is loaded. Once the helper validates the destination it writes the override to the template order and returns the resolved `Location`, guaranteeing that both the reused template order and every ad-hoc order created afterward already contain the updated destination. This is the same helper described in the Service helpers section above.
6. **Order numbering**:
   - Use the template order’s `number` as the prefix.
   - Let `createOrderFromTemplate` append `"-<index>"`, adding 1 to the internal loop index when formatting so the first ad-hoc order (instruction index 1) yields suffix `-2`, instead of calling `basicService.generateReplenishNumber()`.
   - Consider storing a back-reference to the template order id/number via a custom field if traceability is useful.
7. **Transactional boundaries**:
   - Wrap `fulfillMultipleUnitLoads` in a single transaction so either all orders finish or none do. This matches the expectation that the request is strictly all-or-nothing: it either completes every unit load or rolls back all work if any error occurs.
8. **Testing**:
   - Add unit tests around the new service logic (mocking repositories) to verify:
     - Destination override works when the template order already had a different destination.
     - Reservations are released from the original stock and applied to the explicit unit loads.
     - Ad-hoc orders get the expected numbers (`RPL1234-2`, `RPL1234-3`, …) and inherit priority/client/item.
     - Partial failures throw and no new orders remain because of the transactional wrapper.
     - The “finish without refill” helper does not trigger `refillFixedLocations()` and the orchestrator calls it exactly once after the batch succeeds.
     - Setting `amountPicked` before calling the helper causes only the requested quantity to move, confirming the orchestration does not require stock splitting for partial transfers.

## Behavior Guarantees
- **All-or-nothing semantics**: `MobileReplenishService.fulfillMultipleUnitLoads` runs in a single transaction. If any validation or finishing step fails, the request is treated as failed and no new replenish orders remain finished from this call (no partial success).
- **Destination override**: The provided `destinationLocationId` is validated once and persisted as the authoritative destination on the template order. The same destination is applied to every ad-hoc order; unit-load entries never influence the destination.
- **Explicit stock and quantity**: Each unit-load instruction validates the `Unitload` and matching `Stockunit`, then reserves exactly the requested `qty` on that stock via `stockunitBusinessService.changeReservedAmount`. `ReplenishMobileOrderDto.amountPicked` is set to `qty` so only the requested quantity is moved for each order.
- **Availability (not gross-stock) entry guard (260709, v1 port `1ff0d85`)**: `validateUnitLoadEntry` gates on **availability** (`amount − reservedamount`), not gross `amount`. A selected UL whose stock is already reserved by another open replen (available < qty) is rejected up front with `FacadeException("MsgUnitLoadStockAlreadyReserved", <available>)` — so the operator picks a different UL instead of the request exploding downstream in `changeReservedAmount` with `CANNOT_RESERVE_MORE_THAN_AVAILABLE (0.0000)`. A **self-source add-back** credits the template order's own recoverable share (`requestedamount` capped at `reserved`, only when `reserved > 0`) so re-selecting the template's own current source UL is not wrongly rejected. The reserved read is null-safe (the `reservedamount` column is nullable). Because all ULs are validated before any reservation, this single gate covers both the first-UL (`applyExplicitSourceToOrder`) and ad-hoc (`createOrderFromTemplate`) reserve paths. **v1/v2 divergence:** the v2 credit is `min(requestedamount, reserved)` under `reserved > 0` (null-guard + `reserved==0` over-credit fix); v1 credits plain `requestedamount`. Behaviorally identical where `reserved ≥ requested` (all known-reachable states); the cap only diverges in the atypical `0 < reserved < requested` leak. Do NOT "correct" the v2 form back to v1 arithmetic.
- **Single refill pass**: `finishReplenishmentOrderWithoutRefill` never calls `replenishGeneratorService.refillFixedLocations()`. The orchestrator calls `refillFixedLocations()` exactly once after the entire batch loop completes successfully.
- **Deterministic numbering**: Ad-hoc orders created from the template derive their numbers as `<templateNumber>-<index+1>` (e.g., `RPL1234-2`, `RPL1234-3`, …), while inheriting priority, client, and item from the template order.


## Error Handling
- Reject the request if any unit load fails validation (missing unit load/location, mismatched item, insufficient stock, duplicate unit load ids, etc.) with `FacadeException` or `BusinessException`.
- If finishing any order throws, abort the whole transaction so we do not leave some orders finished and others pending.
- Surface validation errors via the controller’s current `{ "errors": [ { title, message } ] }` structure.



---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |
| 2026-07-10 | 260709 (v1 port `1ff0d85`): documented the `validateUnitLoadEntry` availability-not-gross entry guard + self-source add-back (`MsgUnitLoadStockAlreadyReserved`) in Behavior Guarantees; noted the v1/v2 credit-arithmetic divergence. | Code read of `MobileReplenishService.validateUnitLoadEntry` on branch `port/260709-multiul-replen-availability` | 260709 v2 port |

**Re-verify every 60 days.** Next due: **2026-09-08**.
