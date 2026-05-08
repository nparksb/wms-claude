---
type: workflow
status: active
system: wms1
last_verified: 2026-04-27
---

# Multi-Unit Load Replenishment (v1)

Companion to [[wms1-replenish-workflow]] for the case where a single replenishment order requires stock drawn from more than one unit load. The standard single-UL path is described in that doc; this one documents only what is different.

Related design plan: [[wms2-multi-unitload-replenish]] (the v2 plan that this feature was implemented against).

---

## When Multi-UL Replenishment Triggers

A replenishment task normally draws all stock from one unit load. Multi-UL replenishment is used when:

- The required quantity is spread across several source unit loads (no single UL holds enough).
- An operator explicitly knows which unit loads to pull from and wants to control the split (e.g. consuming older stock first, or clearing a bulk location).
- The caller is a system integration (not an interactive mobile scan flow) that supplies an explicit list of `{ unitloadId, locationId, qty }` tuples as part of a single request.

The trigger is the `POST /v3/replenish/multi-unitloads` endpoint. The mobile scan-per-UL interactive flow described in the standard workflow is **not** used here — the entire batch is submitted in one API call.

---

## Endpoint Contract

**`POST /v3/replenish/multi-unitloads`**  
Controller: `ReplenishController.multiUnitLoads` (line 231)

### Request

```json
{
  "orderId": 123,
  "destinationLocationId": 456,
  "destinationLocationName": "FLOW-A01",
  "unitLoads": [
    { "id": 1001, "locationId": 11, "qty": 5.5 },
    { "id": 1002, "locationId": 22, "qty": 2.0 }
  ]
}
```

- `orderId` (`@NotNull`): the existing PROCESSABLE replenish order that acts as the template.
- `destinationLocationId` / `destinationLocationName`: either can be used; name takes precedence when both are supplied. Must resolve to a valid flowbin fixed-assignment location.
- `unitLoads` (`@NotEmpty`): ordered list of unit loads to process. Duplicate IDs within the list are rejected. Each entry requires `locationId` and `qty > 0`. `id` can be omitted if `labelId` (label string) is provided instead — the service resolves it via `unitloadRepository.findByLabelid` (with case-insensitive fallback).

DTOs: `MultiReplenishRequestDto`, `MultiReplenishUnitLoadDto` (`net.aim_ai.wms.json.mobile`).

### Response

On success: `HTTP 200` with a JSON array of processed orders:

```json
[
  { "id": 123,  "number": "RPL1000",   "qty": 5.5, "unitLoadId": 1001, "status": 700, "destinationLocationId": 456 },
  { "id": 9201, "number": "RPL1000-2", "qty": 2.0, "unitLoadId": 1002, "status": 700, "destinationLocationId": 456 }
]
```

On error: `HTTP 200` with `{ "errors": [{ "title": "Runtime Error", "message": "..." }] }` (standard controller error envelope).

---

## Generator: Order Creation Spanning Multiple ULs

### Standard path (single UL)

`ReplenishGeneratorService.calculateOrder` picks one source stock automatically, reserves the quantity, and creates one `Replenishorder` at state `PROCESSABLE`.

### Multi-UL path

No new orders are generated upfront. Instead:

1. The **first unit load** reuses the existing template order. Its source stock, source location, requested amount, and destination are overwritten by `applyExplicitSourceToOrder` (line 895).
2. Each **subsequent unit load** gets a brand-new order created via `ReplenishGeneratorService.createOrderFromTemplate` (line 171).

`createOrderFromTemplate` mirrors every field and validation from `calculateOrder`:

| Field | Source |
|---|---|
| `id` | `replenishorderRepository.getNextId()` |
| `number` | `template.getNumber() + "-" + (sequenceIndex + 1)` |
| `clientId` | copied from template |
| `itemdataId` | copied from template |
| `prio` / `manuallyoverridepriority` | copied from template |
| `state` | `PROCESSABLE` (300) |
| `destinationId` | `destinationId` parameter (the overridden destination) |
| `stockunitId` | explicit stock from the instruction |
| `requestedlocationId` | `unitload.getStoragelocationId()` |
| `requestedamount` | `min(qty, stock.getAmount())` |
| `sourcelocationname` | resolved from `requestedlocationId` |

After persistence, `reserveExplicitStockForOrder` immediately reserves `requestedAmount` on the stock via `stockUnitBusinessService.changeReservedAmount(..., CODE_REPLENISHMENT_CREATED, ...)`.

Order numbering example: template `RPL1000` → ad-hoc orders `RPL1000-2`, `RPL1000-3`, …

---

## Fulfillment Flow: `fulfillMultipleUnitLoads`

Service: `MobileReplenishService.fulfillMultipleUnitLoads` (line 733)  
Annotated `@Transactional` — all-or-nothing; any failure rolls back every order.

### Step-by-step

```
1. Load template order (orderId) — FacadeException if missing
2. Validate unitLoads list is non-empty
3. assignDestinationForMultiUnitLoads(template, destinationLocationId, destinationLocationName)
   → resolves Location by name or id
   → checks fixed-assignment consistency (item must match if assignment exists)
   → if no assignment yet: validates flowbin type + location is empty
   → persists destination override on template: template.setDestinationId(...) + save
   → returns resolved Location
4. For each unitLoad DTO:
   → resolveUnitloadId(dto): resolve id from label if id is null
   → dedup check: reject duplicate unitload ids
   → validateUnitLoadEntry(template, dto):
       · load Unitload by id
       · assert unitload.getStoragelocationId() == dto.getLocationId()
       · find Stockunit on that unitload matching template.getItemdataId()
       · assert stock.getAmount() >= dto.getQty()
       · returns MultiUnitLoadInstruction(dto, stock, unitload)
5. Process instruction[0] against template order:
   → applyExplicitSourceToOrder(template, stock, unitload, qty, destination):
       · release existing reservation if template already has a stockunitId
       · set template fields: destinationId, stockunitId, requestedlocationId, requestedamount, sourcelocationname
       · save template
       · reserveExplicitStockForOrder(template, stock, qty)  [CODE_REPLENISHMENT_CREATED]
   → buildMobileDto(template, stock, qty): populate ReplenishMobileOrderDto with amountPicked=qty
   → finishReplenishmentOrderWithoutRefill(dto)  [see Finish step below]
   → collect response DTO
6. For each instruction[i] where i >= 1:
   → createOrderFromTemplate(template, stock, qty, destination.getId(), i)
   → buildMobileDto(order, stock, qty)
   → finishReplenishmentOrderWithoutRefill(dto)
   → collect response DTO
7. After all instructions succeed:
   → replenishGeneratorService.refillFixedLocations()   [once, not per order]
   → replenishmentOrderMaintenanceService.recalculateOpenOrders(true)
   → failures here are caught and logged as WARN (do not roll back)
8. Return List<MultiReplenishResponseDto>
```

---

## Amount Tracking Across Unit Loads

Unlike the standard mobile flow (where `amountPicked` is null and the entire stock unit moves), the multi-UL path **always sets `amountPicked` explicitly** before calling finish:

```
buildMobileDto(order, stock, qty)
  → dto.setAmountPicked(qty)   ← explicit, not null
```

Inside `finishReplenishmentOrderInternal` (line 397):

```java
BigDecimal amountPicked = mobileOrder.getAmountPicked();
if (amountPicked == null) {
    amountPicked = sourceStock.getAmount();   // ← standard single-UL: moves everything
}
// → only qty is transferred, not the whole stock unit
stockunitBusinessService.transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked, ...)
```

This means only the requested quantity moves for each UL — the source stock unit is not consumed if it has more than `qty`. No stock splitting occurs; the transfer is partial by design.

The reservation sequence per order:

1. `reserveExplicitStockForOrder` → `changeReservedAmount(stock, +qty, false, CODE_REPLENISHMENT_CREATED, ...)`
2. At finish → `changeReservedAmount(sourceStock, -reservedAmount, true, CODE_REPLENISHMENT_FINISHED, ...)`
3. `transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked, CODE_REPLENISHMENT, ...)`

---

## State Transitions

```
Template order:
  [PROCESSABLE] → applyExplicitSourceToOrder (fields rewritten + reservation transferred)
               → finishReplenishmentOrderWithoutRefill
               → [FINISHED / state=700]

Ad-hoc orders (i ≥ 1):
  [created at PROCESSABLE] → createOrderFromTemplate (state=300, reservation set)
                           → finishReplenishmentOrderWithoutRefill
                           → [FINISHED / state=700]
```

Key service method references:

| Step | Method | File:line |
|---|---|---|
| Destination validate + persist | `assignDestinationForMultiUnitLoads` | `MobileReplenishService.java:820` |
| UL + stock validation | `validateUnitLoadEntry` | `MobileReplenishService.java:869` |
| UL id resolution from label | `resolveUnitloadId` | `MobileReplenishService.java:796` |
| Release old reservation + rewrite template fields | `applyExplicitSourceToOrder` | `MobileReplenishService.java:895` |
| Reserve explicit stock | `reserveExplicitStockForOrder` | `ReplenishGeneratorService.java:163` |
| Create ad-hoc order | `createOrderFromTemplate` | `ReplenishGeneratorService.java:171` |
| Build DTO with explicit qty | `buildMobileDto` | `MobileReplenishService.java:926` |
| Finish without refill | `finishReplenishmentOrderWithoutRefill` | `MobileReplenishService.java:393` |
| Finish internal (stock transfer) | `finishReplenishmentOrderInternal` | `MobileReplenishService.java:397` |
| Batch orchestrator | `fulfillMultipleUnitLoads` | `MobileReplenishService.java:733` |
| Controller endpoint | `ReplenishController.multiUnitLoads` | `ReplenishController.java:231` |

---

## Comparison with Single-UL Path

| Aspect | Single-UL (standard) | Multi-UL |
|---|---|---|
| Source selection | Auto-picked by `calculateOrder` (highest-stock UL) | Caller-supplied per entry |
| Mobile scan interaction | `checkSource` → `checkDestination` → `finishReplenishmentOrder` | None — entire batch in one API call |
| Destination validation | `checkDestination` validates scanned label | `assignDestinationForMultiUnitLoads` validates by id or name |
| `amountPicked` | `null` at finish → entire stock unit moves | Explicitly set to `qty` → only requested qty moves |
| Orders created | 1 | 1 (template) + N-1 ad-hoc orders |
| Order numbers | `RPL1000` | `RPL1000` (template), `RPL1000-2`, `RPL1000-3`, … |
| `refillFixedLocations` call | Per order, at end of `finishReplenishmentOrder` | Once, after all orders finish |
| Transaction boundary | Per `finishReplenishmentOrder` call | Single `@Transactional` wrapping entire batch |
| Priority / client / item | Set by generator from item shortage data | Inherited from template order |

---

## Common Failure Modes

### Validation failures (roll back entire batch)

| Condition | Exception | Method |
|---|---|---|
| Template order not found | `FacadeException("MsgCannotReadOrder")` | `fulfillMultipleUnitLoads:738` |
| Empty `unitLoads` list | `BusinessException("No unit loads provided")` | `fulfillMultipleUnitLoads:745` |
| Destination resolves to non-flowbin location | `BusinessException("Destination is not a flowbin!")` | `assignDestinationForMultiUnitLoads:851` |
| Destination already assigned to a different item | `BusinessException("... has different fixed assignment")` | `assignDestinationForMultiUnitLoads:861` |
| Item's fixed assignment points elsewhere | `BusinessException("... is wrong location!")` | `assignDestinationForMultiUnitLoads:843` |
| Flowbin destination already has a unit load | `BusinessException("Destination has already a unit load!")` | `assignDestinationForMultiUnitLoads:855` |
| Duplicate unit load id in request | `BusinessException("Duplicate unit load id ...")` | `fulfillMultipleUnitLoads:759` |
| Unit load not at stated location | `BusinessException("Unit load is not on expected location")` | `validateUnitLoadEntry:873` |
| Unit load holds no stock for the order's item | `FacadeException("MsgSourceStockNotFound")` | `validateUnitLoadEntry:887` |
| Unit load stock insufficient for requested qty | `FacadeException("MsgTooMuchRequested")` | `validateUnitLoadEntry:889` |
| Unit load label not found | `FacadeException("MsgUnitLoadNotFound")` | `resolveUnitloadId:811` |
| No destination supplied (both id and name null) | `FacadeException("REPLENISH_MISSING_DESTINATION")` | `assignDestinationForMultiUnitLoads:831` |

### Post-batch non-fatal failures

`refillFixedLocations()` and `recalculateOpenOrders()` run after the transaction commits. Exceptions from these calls are caught and logged at WARN level — they do not roll back the finished orders.

### Partial completion impossible

Because `fulfillMultipleUnitLoads` is `@Transactional`, any failure during processing (validation, reservation, stock transfer, ad-hoc creation) causes the entire request to roll back. No intermediate state where some orders are FINISHED and others are not is possible from this endpoint.

### Wrong unit load scanned / wrong location

If `dto.locationId` does not match `unitload.getStoragelocationId()`, `validateUnitLoadEntry` throws immediately before any mutations. All validations run before any `applyExplicitSourceToOrder` or `createOrderFromTemplate` calls, so a mismatch on UL entry #3 will reject the entire request without touching entries #1 or #2.
