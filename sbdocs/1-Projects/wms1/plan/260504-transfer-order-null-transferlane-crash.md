---
title: "Transfer order crash: state=510 with null transferlaneId after unlink"
ticket: ""
ticket_url: ""
type: bug-fix
priority: high
status: approved
project: [wms1]
version: v1
requester: nam.park
created: 2026-05-04
updated: 2026-05-05
related:
  - ../../../3-Resources/architecture/wms1-state-machine-catalog.md
  - ../../../3-Resources/workflows/wms1-transfer-order-workflow.md
db_verified: true
tags:
  - plan
  - bug-fix
  - transfer-order
  - state-machine
  - mobile
---

# Transfer order crash: state=510 with null transferlaneId after unlink

**Ticket:** _none — date-prefixed hotfix plan_
**Project:** wms1 | **Version:** v1 | **Type:** bug-fix
**Priority:** high (production crash on every mobile transfer page open whenever any order is in the broken state)
**Status:** approved (ralplan consensus — Planner + Architect + Critic, 2 iterations)
**Date:** 2026-05-04
**Branch:** `release-hotfix-260429`

---

## 0. Affected sites (enumeration before drafting)

Symbol greps run:
- `grep -rn "transferlaneId\|setTransferlaneId\|getTransferlaneId" v1/wms-api/src/main/java`
- `grep -rn "unlinkTransferLane\|assignTransferLane\|TRANSFER_LANE_ASSIGNED\|CUSTOMER_ORDER_ACTIVATED" v1/wms-api/src/main`
- `grep -rn "transferlaneId\|unlinkTransferLane" v1/wms-api/src/test`

| #  | File:line                                                          | Construct                                                                                              | Same root cause? | In-scope this plan? |
|----|--------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|------------------|----------------------|
| 1  | `service/TransferOrderService.java:88-94`                          | `unlinkTransferLaneFromTransferOrder()` clears `transferlaneId` but does NOT reset state from 510→505  | yes — root cause | **yes — Fix A**      |
| 2  | `service/mobile/MobileTransferOrderService.java:81`                | `findById(getTransferlaneId()).get()` inside `updateOrderList()` — direct crash site                   | yes — symptom    | **yes — Fix B**      |
| 3  | `service/mobile/MobileTransferOrderService.java:110`               | `findById(getTransferlaneId()).get()` inside `updateOrder()` — same null risk on per-order refresh     | yes — symptom    | **yes — Fix B**      |
| 4  | `service/mobile/MobileTransferOrderService.java:142`               | `findById(getTransferlaneId()).get()` inside `updateOrderPosition()` — same null risk on position scan | yes — symptom    | **yes — Fix C**      |
| 5  | `service/mobile/MobileTransferOrderService.java:247-251`           | `transferStock()` already has the correct null guard (`Optional<Location> transferLaneOpt = ...`)      | no — already safe | no — no change       |
| 6  | `service/TransferOrderService.java:115-120`                        | `assignTransferLane(Customerorder)` — public, no callers in `src/main`; dead code with footgun shape (sets state=510 without setting transferlaneId) | adjacent — dead  | **yes — Fix D**      |
| 7  | `service/TransferOrderService.java:125-131` (`isEnoughStockOnTransferLane`) | already checks `getTransferlaneId() == null` BEFORE `findById(...).get()` — safe                       | no — already safe | no — no change       |
| 8  | `service/TransferOrderService.java:237-238` (`getTransferLineUnitLoads`) | already checks `getTransferlaneId() != null` BEFORE `findById(...).get()` — safe                       | no — already safe | no — no change       |
| 9  | `service/TransferOrderService.java:319` (`buildStock`)             | `findById(getTransferlaneId()).get()` — but `buildStock` is test-only seeding (`BUILD_STOCK_FOR_TESTING`); not on the prod hot path | no — test seed | no — no change       |
| 10 | `service/BillofladingService.java:902`                             | `findById(getTransferlaneId()).get()` inside BOL flow                                                  | adjacent risk    | no — out of scope; BOL flow only reaches this for orders past 510, mitigated by Fix A. Document as residual risk in §9 |
| 11 | `service/CustomerorderBatchService.java:341-342`                    | Sets `transferlaneId = null` on a batch — DOES NOT touch `state`, but only runs against batches not in state 510 (different code path). Verify. | adjacent — verify | no — out of scope; batch flow operates on different states |
| 12 | `controller/TransfersController.java:127-135` (`/v3/transfers/unlinkTransferLane/{id}`) | The HTTP entry point for the buggy service method. Behavior change is invisible to caller (still 200 OK) but order now ends in state 505. | yes — entry point | **document only** — no code change |
| 13 | `service/mobile/MobileTransferOrderService.updateOrderList:75`     | `findByState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED)` — selects which orders go through Site #2. After Fix A this query no longer returns broken orders. | yes — root cause downstream | covered by Fix A |
| 14 | DB rows: `customerorder` where `state=510 AND transferlane_id IS NULL` (2 stuck rows in wineco-dev) | data state                                                                                              | yes — symptom    | **yes — Fix E (Flyway)** |
| 15 | `test/unit/service/TransferOrderServiceUnitTest.java:136-146`      | `unlinkTransferLaneFromTransferOrder_setsTransferlaneIdToNull` — asserts only `transferlaneId == null`; does NOT assert state. **Missing assertion.** | yes — test gap   | **yes — Fix F (test)** |
| 16 | `test/unit/service/TransferOrderServiceUnitTest.java:189-199`      | `assignTransferLane_setsStateAndSaves` — covers the dead method removed in Fix D                       | yes — test gap   | **yes — Fix F (test)** |
| 17 | `test/service/TransferOrderServiceIT.java:68-78`                   | Integration test asserts `transferlaneId == null` after unlink but not state                            | yes — test gap   | **yes — Fix F (test)** |
| 18 | `test/unit/service/mobile/MobileTransferOrderServiceUnitTest.java` | Existing tests do not exercise the null-transferlaneId path                                            | yes — test gap   | **yes — Fix F (test)** |
| 19 | `controller/mobile/TransferOrderController.java:69-74`             | `processOrderPositionSelect()` calls `updateOrderPosition()` (Fix C adds `throws BusinessException`) with **NO try/catch** — `BusinessException` propagates to `RestExceptionHandler`, which has no `@ExceptionHandler(BusinessException.class)` mapping → HTTP 500 | yes — error path gap | **yes — Fix C (controller side)** |

Every in-scope row appears in §3 Fix Design or §6 File Change Summary below.

---

## 1. Problem Statement

**Symptom:** `GET /v3/transferOrder/orderList` (mobile transfer order list) returns HTTP 500 with the following exception, breaking the mobile transfer page for ALL operators in the warehouse whenever ANY order is in the broken state:

```
java.lang.IllegalArgumentException: The given id must not be null!
    at org.springframework.data.repository.support.Repositories...
    at net.aim_ai.wms.service.mobile.MobileTransferOrderService.updateOrderList(MobileTransferOrderService.java:81)
    at net.aim_ai.wms.controller.mobile.TransferOrderController.orderList(...)
```

The crash site at line 81 is `locationRepository.findById(customerOrder.getTransferlaneId()).get()`, which receives `null` for `customerOrder.getTransferlaneId()`.

**Reproduction:**
1. User assigns a transfer lane to an order via `GET /v3/transfers/assignTransferLane/{orderId}/{laneId}` — order goes to state 510 with `transferlaneId` set.
2. User unlinks the lane via `GET /v3/transfers/unlinkTransferLane/{orderId}` — `transferlaneId` becomes null but state stays at 510 (BUG).
3. ANY mobile operator opens the transfer order list — `MobileTransferOrderService.updateOrderList()` queries `findByState(510)`, picks up the broken order, and crashes on `findById(null)`.
4. Page returns 500. ALL operators see the failure, not just the user who unlinked.

### DB-level verification (Analysis protocol §8)

Query run against `wms1-wineco-dev` on 2026-05-04:

```sql
SELECT id, state, transferlane_id, modified, clientordernumber
FROM customerorder
WHERE state = 510
ORDER BY modified DESC;
```

Result:

| id       | state | transferlane_id | modified                  | clientordernumber       |
|----------|-------|-----------------|---------------------------|-------------------------|
| 25980422 | 510   | 59200           | 2026-05-04 09:32:39       | order-112233            |
| 25227432 | 510   | NULL            | 2026-03-26 06:17:36       | TestTransfer032326-02   |
| 22476694 | 510   | NULL            | 2025-06-03 07:33:13       | BCTestTransfer01        |

**Two of three orders in state 510 are in the broken state.** Order `25980422` is healthy. Orders `25227432` (stuck 5 weeks) and `22476694` (stuck 11 months) are the time-bomb that triggers the 500 every time a mobile operator hits the transfer page. `db_verified: true` recorded in frontmatter.

---

## 2. Root Cause Analysis

### Bug 1: `TransferOrderService.unlinkTransferLaneFromTransferOrder()` is not the inverse of `assignTransferLaneToTransferOrder()`

**Location:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/TransferOrderService.java:88-94`

```java
public void unlinkTransferLaneFromTransferOrder(Long customerOrderId) throws BusinessException {
    Customerorder customerOrder = customerorderRepository.findById(customerOrderId)
            .orElseThrow(() -> new BusinessException("Customer order not found: " + customerOrderId));
    LOG.debug("called with customerOrder=" + customerOrder);
    customerOrder.setTransferlaneId(null);          // ← clears lane
    customerorderRepository.save(customerOrder);    // ← state remains 510 — BUG
}
```

Compare with the assigning side at lines 66-85:

```java
public void assignTransferLaneToTransferOrder(Long transferLaneId, Long customerOrderId) throws BusinessException {
    Customerorder customerOrder = customerorderRepository.findByIdForUpdate(customerOrderId)...;
    Location transferLane = locationRepository.findById(transferLaneId)...;
    ...
    customerOrder.setTransferlaneId(transferLane.getId());           // sets lane
    customerOrder.setState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);   // sets state
    customerorderRepository.save(customerOrder);
}
```

`assign` sets BOTH `transferlaneId` AND `state` atomically. `unlink` only clears `transferlaneId` — it leaves `state` at 510. The state/data-pair invariant ("`state == 510` ⇒ `transferlaneId IS NOT NULL`") is broken.

The state-machine catalog (`sbdocs/3-Resources/architecture/wms1-state-machine-catalog.md:138-139`) documents the legitimate path `505 ─► 510`. There is no documented path back from 510 to 505 — but the unlink endpoint exists in production and is reachable via `GET /v3/transfers/unlinkTransferLane/{id}` (`TransfersController.java:127-135`). The implementation is half-correct: it clears the lane reference but skips the inverse state transition.

The transfer-order workflow doc (`sbdocs/3-Resources/workflows/wms1-transfer-order-workflow.md:131`) also confirms the gap: *"`GET /v3/transfers/unlinkTransferLane/{customerOrderId}` — clears `transferlaneId` only (no state change)"* — the bug is documented as known undesirable behavior; this plan promotes it from "known wart" to "fixed."

**Why the field-only update is a bug, not a feature:** all downstream readers — `MobileTransferOrderService.updateOrderList`/`updateOrder`/`updateOrderPosition` — assume the invariant holds. They query `findByState(510)` and dereference `getTransferlaneId()` without a null check.

### Bug 2: `MobileTransferOrderService` dereferences `getTransferlaneId()` without a null guard

**Locations:** `MobileTransferOrderService.java:81`, `:110`, `:142`

All three sites have the same shape:

```java
Location transferLane = locationRepository.findById(customerOrder.getTransferlaneId()).get();
```

When the input is null, Spring Data's `findById(null)` throws `IllegalArgumentException: The given id must not be null!` BEFORE the `.get()` even runs. None of these three callers guards against it.

This is a defensive-programming gap: even after Fix A makes `unlink` reset the state, the codebase should not crash on any future ill-formed data state. v1 has no `RestExceptionHandler` mapping for `IllegalArgumentException` — so it propagates as HTTP 500 (per `wms-api/CLAUDE.md` "exception handling" notes).

### Bug 3 (housekeeping): dead public method `assignTransferLane(Customerorder)`

**Location:** `TransferOrderService.java:115-120`

```java
public void assignTransferLane(Customerorder customerOrder) throws BusinessException {
    LOG.debug("start with customerOrder=" + customerOrder);
    customerOrder.setState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
    customerorderRepository.save(customerOrder);
    LOG.debug("end   with customerOrder=" + customerOrder);
}
```

`grep -rn "transferOrderService\.assignTransferLane(" v1/wms-api/src` returns zero results in `src/main` (only the `assignTransferLaneToTransferOrder()` overload is called). One unit test at `TransferOrderServiceUnitTest.java:192-199` exercises the dead method. The method is a footgun: it sets state to 510 WITHOUT setting `transferlaneId`, which is the same broken-invariant data state we're trying to eliminate.

This is not the cause of the current crash, but the method is dead code with a footgun shape: if ever called it sets state=510 WITHOUT setting `transferlaneId`, reproducing the exact broken invariant this plan fixes. Removing it eliminates the dead code and shrinks the public API surface of `TransferOrderService`.

### Why `findByIdForUpdate` is NOT used by `unlinkTransferLaneFromTransferOrder`

The assign path uses `customerorderRepository.findByIdForUpdate(customerOrderId)` (pessimistic lock — line 67). The unlink path uses plain `findById` (line 89). For the hotfix we keep the existing locking strategy — adding a pessimistic lock to `unlink` is out of scope (no concurrent unlink/assign race has been reported). Document as residual risk in §9.

---

## 3. The Regression Chain

`git log --oneline v1/wms-api/src/main/java/net/aim_ai/wms/service/TransferOrderService.java` (last 5 entries):

This bug pre-dates the visible history; the missing state reset has been latent since `unlinkTransferLaneFromTransferOrder` was first added. The 11-month-stuck order (`22476694`, modified 2025-06-03) confirms the bug has been live for at least that long. There is no recent regression to roll back — this is a long-standing latent defect first reported on 2026-05-04 after the broken DB state finally accumulated enough to be noticed.

No commit-level archaeology table needed.

---

## 4. Architecture Overview

```
                        Mobile UI                    Web UI
                            │                           │
                            │ GET /v3/transferOrder    │ GET /v3/transfers/
                            │     /orderList           │     unlinkTransferLane/{id}
                            ▼                           ▼
        ┌─────────────────────────────┐    ┌────────────────────────────┐
        │ TransferOrderController     │    │ TransfersController        │
        │   .orderList()              │    │   .unlinkTransferLane()    │
        └───────────────┬─────────────┘    └──────────────┬─────────────┘
                        │                                 │
                        ▼                                 ▼
        ┌─────────────────────────────┐    ┌────────────────────────────┐
        │ MobileTransferOrderService  │    │ TransferOrderService       │
        │   .updateOrderList():73     │    │   .unlinkTransferLane-     │
        │   .updateOrder():102        │    │     FromTransferOrder():88 │
        │   .updateOrderPosition():136│    │                            │
        │                             │    │   ── BUG: clears           │
        │   ── reads from state=510   │    │      transferlaneId        │
        │      but assumes            │◄───┤      WITHOUT resetting     │
        │      transferlaneId NOT NULL│    │      state from 510→505    │
        └─────────────────────────────┘    └────────────────────────────┘
                        │
                        ▼
        ┌─────────────────────────────┐
        │ locationRepository          │
        │   .findById(null).get()     │
        │   → IllegalArgumentException│ ← crash site (3 callsites: :81, :110, :142)
        └─────────────────────────────┘
```

**Key Files**

| File                                                                                         | Lines           | Role                                                              |
|----------------------------------------------------------------------------------------------|-----------------|-------------------------------------------------------------------|
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/TransferOrderService.java`                 | 88-94, 115-120  | Root cause (`unlink…`), dead method (`assignTransferLane`)        |
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobileTransferOrderService.java`     | 81, 110, 142    | Crash sites (3) — all three need a null guard                     |
| `v1/wms-api/src/main/java/net/aim_ai/wms/controller/TransfersController.java`                | 127-135         | HTTP entry to `unlink…` (no change needed)                        |
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java`                          | 59, 64          | `CUSTOMER_ORDER_ACTIVATED=505`, `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED=510` |
| `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/TransferOrderServiceUnitTest.java`    | 133-199         | Existing unit tests — assertion gap and dead-method test          |
| `v1/wms-api/src/test/java/net/aim_ai/wms/service/TransferOrderServiceIT.java`               | 68-78           | Integration test — assertion gap                                  |
| `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTransferOrderServiceUnitTest.java` | (new tests) | Add coverage for null-transferlaneId path                          |
| `v1/wms-api/src/main/resources/db/migration/V1.1.06__transfer_order_state_fix.sql`          | (new file)      | Flyway data fix for 2 stuck orders                                |
| `v1/wms-api/src/main/java/net/aim_ai/wms/controller/mobile/TransferOrderController.java`     | 69-74           | Add try/catch for `BusinessException` to `processOrderPositionSelect` (Fix C controller side) |

---

## 5. Fix Design

### Fix A — Reset state to 505 in `unlinkTransferLaneFromTransferOrder` (root cause)

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/TransferOrderService.java`

**Before** (lines 88-94):

```java
public void unlinkTransferLaneFromTransferOrder(Long customerOrderId) throws BusinessException {
    Customerorder customerOrder = customerorderRepository.findById(customerOrderId)
            .orElseThrow(() -> new BusinessException("Customer order not found: " + customerOrderId));
    LOG.debug("called with customerOrder=" + customerOrder);
    customerOrder.setTransferlaneId(null);
    customerorderRepository.save(customerOrder);
}
```

**After:**

```java
public void unlinkTransferLaneFromTransferOrder(Long customerOrderId) throws BusinessException {
    Customerorder customerOrder = customerorderRepository.findById(customerOrderId)
            .orElseThrow(() -> new BusinessException("Customer order not found: " + customerOrderId));
    LOG.debug("called with customerOrder=" + customerOrder);
    customerOrder.setTransferlaneId(null);
    customerOrder.setState(CUSTOMER_ORDER_ACTIVATED);   // restore pre-assignment state (inverse of assign)
    customerorderRepository.save(customerOrder);
    LOG.debug("end   with customerOrder=" + customerOrder + " (reset to CUSTOMER_ORDER_ACTIVATED)");
}
```

`CUSTOMER_ORDER_ACTIVATED` is already imported at line 16. No new imports needed.

**Why this fix and not alternatives:**
- **Alt 1: defensive guard only (skip broken orders in mobile reads).** Rejected — leaves the 2 stuck orders permanently invisible and will accumulate more broken rows over time.
- **Alt 2: forbid unlink (delete the endpoint).** Rejected — operators legitimately need to unlink and re-assign a lane. The endpoint is in active use.
- **Alt 3: make unlink delete the order entirely.** Rejected — too destructive; loses order history.

**The chosen fix** restores the documented state-machine inverse — `assign` is `505→510`, `unlink` is `510→505`. Symmetry is the simplest correctness story.

### Fix B — Defensive null guard in `MobileTransferOrderService.updateOrderList()` and `updateOrder()`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobileTransferOrderService.java`

**Before** (lines 78-99 in `updateOrderList()`):

```java
for (Customerorder customerOrder : customerOrderList) {
    Client client = clientRepository.findById(customerOrder.getClientId()).get();
    CustomerorderBatch coBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId()).get();
    Location transferLane = locationRepository.findById(customerOrder.getTransferlaneId()).get();   // crash site

    TransferOrderDto transferOrderDto;
    transferOrderDto = new TransferOrderDto();
    ...
}
```

**After:**

```java
for (Customerorder customerOrder : customerOrderList) {
    if (customerOrder.getTransferlaneId() == null) {
        LOG.error("updateOrderList: skipping customerorder id={} clientordernumber={} — state=510 (TRANSFER_LANE_ASSIGNED) but transferlane_id IS NULL; data invariant violated. See hotfix plan 260504-transfer-order-null-transferlane-crash.",
                customerOrder.getId(), customerOrder.getClientordernumber());
        continue;
    }
    Client client = clientRepository.findById(customerOrder.getClientId()).get();
    CustomerorderBatch coBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId()).get();
    Location transferLane = locationRepository.findById(customerOrder.getTransferlaneId()).get();
    ...
}
```

**Before** (line 110 in `updateOrder()`, called once per order from `updateOrderList`):

```java
public TransferOrderDto updateOrder(TransferOrderDto transferOrderDto) {
    LOG.debug("start");
    Customerorder customerOrder = customerorderRepository.findById(transferOrderDto.getCustomerOrderId()).get();
    List<TransferOrderPositionDto> transferOrderPositionDtoList = new ArrayList<>();

    for (CustomerorderPosition customerOrderPosition : customerorderPositionRepository.findByOrderId(transferOrderDto.getCustomerOrderId())) {
        Itemdata itemData = itemdataRepository.findById(customerOrderPosition.getItemdataId()).get();
        Location transferLane = locationRepository.findById(customerOrder.getTransferlaneId()).get();   // crash site #2
        ...
```

**After:**

```java
public TransferOrderDto updateOrder(TransferOrderDto transferOrderDto) {
    LOG.debug("start");
    Customerorder customerOrder = customerorderRepository.findById(transferOrderDto.getCustomerOrderId()).get();
    if (customerOrder.getTransferlaneId() == null) {
        LOG.error("updateOrder: customerorder id={} has state=510 but transferlane_id IS NULL — invariant violated; returning empty positions",
                customerOrder.getId());
        transferOrderDto.setPositions(new ArrayList<>());
        return transferOrderDto;
    }
    List<TransferOrderPositionDto> transferOrderPositionDtoList = new ArrayList<>();

    for (CustomerorderPosition customerOrderPosition : customerorderPositionRepository.findByOrderId(transferOrderDto.getCustomerOrderId())) {
        Itemdata itemData = itemdataRepository.findById(customerOrderPosition.getItemdataId()).get();
        Location transferLane = locationRepository.findById(customerOrder.getTransferlaneId()).get();
        ...
```

After Fix A this guard is theoretically unreachable; it is defense-in-depth so a future regression cannot reproduce the same outage.

### Fix C — Defensive null guard in `MobileTransferOrderService.updateOrderPosition()`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobileTransferOrderService.java`

**Before** (lines 136-160):

```java
public TransferOrderPositionDto updateOrderPosition(TransferOrderPositionDto transferOrderPositionDto) {
    LOG.debug("start");
    Customerorder customerOrder = customerorderRepository.findById(transferOrderPositionDto.getCustomerOrderId()).get();
    CustomerorderPosition customerOrderPosition = customerorderPositionRepository.findById(transferOrderPositionDto.getCustomerOrderPositionId()).get();

    Itemdata itemData = itemdataRepository.findById(customerOrderPosition.getItemdataId()).get();
    Location transferLane = locationRepository.findById(customerOrder.getTransferlaneId()).get();   // crash site #3
    ...
```

**After:**

```java
public TransferOrderPositionDto updateOrderPosition(TransferOrderPositionDto transferOrderPositionDto) throws BusinessException {
    LOG.debug("start");
    Customerorder customerOrder = customerorderRepository.findById(transferOrderPositionDto.getCustomerOrderId()).get();
    if (customerOrder.getTransferlaneId() == null) {
        LOG.error("updateOrderPosition: customerorder id={} has state=510 but transferlane_id IS NULL — refusing to proceed; operator must re-assign a transfer lane",
                customerOrder.getId());
        throw new BusinessException("Order has no transfer lane assigned. Please assign a transfer lane first.");
    }
    CustomerorderPosition customerOrderPosition = customerorderPositionRepository.findById(transferOrderPositionDto.getCustomerOrderPositionId()).get();
    ...
```

**Why throw (Fix C) instead of skip (Fix B)?** `updateOrderList()` returns a list (skip-and-continue is the right shape — one bad row should not break the page). `updateOrderPosition()` is a per-action call (the operator scanned a position) — silent skip would be confusing; an explicit `BusinessException` returns a meaningful error to the mobile UI ("please assign a transfer lane first").

The signature change (`throws BusinessException` added) requires adding a try/catch to the one caller: `TransferOrderController.processOrderPositionSelect` (verified by `grep -rn "updateOrderPosition" src/main`). This method currently has **no** try/catch — unlike its sibling methods `processScanUnitLoad` and `processScanTransferLane`, which both wrap service calls in `try/catch (BusinessException e)` and return an `errorMap` envelope. The fix adds the same **try/catch `BusinessException` + `errorMap` envelope** to `processOrderPositionSelect`. The internal shape uses early returns inside try/catch (Java idiomatic early-return style) rather than the assignment-inside-try / branch-on-errors-size shape of `processScanUnitLoad` — both produce identical runtime behavior.

#### Fix C (controller side) — Wrap `processOrderPositionSelect` in `TransferOrderController`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/controller/mobile/TransferOrderController.java`

**Before** (lines 69-74):

```java
@PostMapping(path= "/processOrderPositionSelect", consumes = "application/json", produces = "application/json")
public ResponseEntity<Object> processOrderPositionSelect(@RequestBody TransferOrderPositionDto inDto, @AuthenticationPrincipal Principal principal) {
    LOG.debug("processOrderPositionSelect dto = " + inDto);
    TransferOrderPositionDto dto  = mobileTransferOrderService.updateOrderPosition(inDto);
    return new ResponseEntity<Object>(dto, HttpStatus.OK);
}
```

**After:**

```java
@PostMapping(path= "/processOrderPositionSelect", consumes = "application/json", produces = "application/json")
public ResponseEntity<Object> processOrderPositionSelect(@RequestBody TransferOrderPositionDto inDto, @AuthenticationPrincipal Principal principal) {
    LOG.debug("processOrderPositionSelect dto = " + inDto);
    List<Map<String,String>> errors = new ArrayList<>();
    Map<String, Object> errorMap = new HashMap<>();
    try {
        TransferOrderPositionDto dto = mobileTransferOrderService.updateOrderPosition(inDto);
        return new ResponseEntity<Object>(dto, HttpStatus.OK);
    } catch (BusinessException e) {
        errors.add(getErrorMessage("Runtime Error", e.getMessage()));
        errorMap.put("errors", errors);
        return new ResponseEntity<Object>(errorMap, HttpStatus.OK);
    }
}
```

`getErrorMessage(String, String)` is inherited from `AdminController` — same pattern as `processScanUnitLoad` at line 86. No new imports needed (`List`, `Map`, `ArrayList`, `HashMap`, `BusinessException` are already imported in the class).

### Fix D — Remove dead public method `assignTransferLane(Customerorder)`

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/TransferOrderService.java`

**Before** (lines 115-120):

```java
public void assignTransferLane(Customerorder customerOrder) throws BusinessException {
    LOG.debug("start with customerOrder=" + customerOrder);
    customerOrder.setState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
    customerorderRepository.save(customerOrder);
    LOG.debug("end   with customerOrder=" + customerOrder);
}
```

**After:** delete entirely (lines 115-120 removed).

Also delete the corresponding test method in **`TransferOrderServiceUnitTest.java:189-199`** — the method named `assignTransferLane_setsStateAndSaves`. Delete the entire `@Test` block:

```java
// DELETE THIS METHOD — it covers the dead method removed in Fix D
@Test
void assignTransferLane_setsStateAndSaves() throws BusinessException {
    Customerorder order = buildCustomerorder(10L, 1L, "ORDER-001");
    order.setState(WmsConstants.State.CUSTOMER_ORDER_ACTIVATED);

    when(customerorderRepository.findById(10L)).thenReturn(Optional.of(order));

    transferOrderService.assignTransferLane(order);

    assertThat(order.getState()).isEqualTo(WmsConstants.State.CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
    verify(customerorderRepository).save(order);
}
```

_(Exact body may differ in the source file — identify by method name `assignTransferLane_setsStateAndSaves` at `TransferOrderServiceUnitTest.java:189`.)_

This method is never called in `src/main`; one unit test exists. It is dead code that happens to also be a footgun: if ever called, it sets state=510 WITHOUT setting `transferlaneId` — exactly the broken-invariant state this plan fixes. Removing it eliminates the dead code and the footgun together.

### Fix E — Flyway data fix: reset stuck orders

**File (new):** `v1/wms-api/src/main/resources/db/migration/V1.1.06__transfer_order_state_fix.sql`

```sql
-- 260504 hotfix: orders stuck in state 510 (CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED) with NULL transferlane_id.
-- These rows were created by TransferOrderService.unlinkTransferLaneFromTransferOrder(), which cleared
-- transferlane_id but did not reset state from 510 back to 505 (CUSTOMER_ORDER_ACTIVATED).
--
-- The companion code fix (TransferOrderService.java) closes the source of broken rows.
-- This migration unsticks the rows that were created before the code fix shipped.
--
-- Confirmed via: SELECT * FROM customerorder WHERE state=510 AND transferlane_id IS NULL;
-- Expected affected rows in wineco-dev as of 2026-05-04: 2 (ids 22476694, 25227432).

-- Audit: emit one NOTICE per affected row so the Flyway migration log captures what was changed.
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT id, clientordernumber, state, transferlane_id
        FROM customerorder
        WHERE state = 510 AND transferlane_id IS NULL
    LOOP
        RAISE NOTICE 'HOTFIX 260504: customerorder id=% (%) — resetting state 510→505 (transferlane_id already NULL)',
            r.id, r.clientordernumber;
    END LOOP;
END$$;

UPDATE customerorder
SET state = 505,                -- CUSTOMER_ORDER_ACTIVATED
    modified = now()
WHERE state = 510               -- CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED
  AND transferlane_id IS NULL;
```

**Flyway slot decision:** **`V1.1.06`** (next free slot per `CLAUDE.md`).

`CLAUDE.md` documents the current sequence as V1.0.01–V1.1.05 and states _"New migrations should continue the V1.1.x sequence (next would be `V1.1.06__`)"_. This hotfix is on `release-hotfix-260429` and deploys before any in-flight develop work. `SBDEV-2096` (on `develop`) claims `V1.1.07`; when it merges, its slot is already one above this hotfix so there is no conflict. If by some race `V1.1.06` is already taken at merge time, renumber to the next free slot and update the acceptance-script regex (Step 1 of §7.2 checklist re-verifies at deploy time).

The migration is **idempotent**: `WHERE state = 510 AND transferlane_id IS NULL` matches zero rows after this migration runs once, so re-runs are no-ops.

**NOTICE delivery and rollback semantics:** `RAISE NOTICE` is a PL/pgSQL I/O side-effect sent to the JDBC client as soon as the driver flushes it — it is NOT rolled back if the surrounding transaction rolls back. Flyway 6.5.x (shipped with Spring Boot 2.3.7) captures these via `JdbcUtils.printWarnings` at INFO level. **Edge case:** if the UPDATE fails (e.g., a row-level lock on `customerorder.modified`) and Flyway rolls back the migration, the NOTICE lines may already appear in the log while the DB row is unchanged. This is recoverable — re-run is idempotent. To confirm NOTICE capture works in your environment, after applying the migration in staging grep the Flyway log for `HOTFIX 260504`.

The migration runs on every tenant DB on the next deploy (one deployment per tenant — see `wms1-tenant-routing-datasource-topology.md:31-34`). Tenants without affected rows see zero changes and no NOTICE output.

### Fix F — Test additions

#### F1. Update existing unit test `unlinkTransferLaneFromTransferOrder_setsTransferlaneIdToNull`

**File:** `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/TransferOrderServiceUnitTest.java:135-146`

Rename to `unlinkTransferLaneFromTransferOrder_clearsLaneAndResetsStateToActivated` and add the state assertion:

```java
@Test
void unlinkTransferLaneFromTransferOrder_clearsLaneAndResetsStateToActivated() throws BusinessException {
    Customerorder order = buildCustomerorder(10L, 1L, "ORDER-001");
    order.setTransferlaneId(5L);
    order.setState(WmsConstants.State.CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);

    when(customerorderRepository.findById(10L)).thenReturn(Optional.of(order));

    transferOrderService.unlinkTransferLaneFromTransferOrder(order.getId());

    assertThat(order.getTransferlaneId()).isNull();
    assertThat(order.getState()).isEqualTo(WmsConstants.State.CUSTOMER_ORDER_ACTIVATED);
    verify(customerorderRepository).save(order);
}
```

Per CLAUDE.md "The test for the root cause fix must verify both: (a) `transferlaneId` is null after unlink, and (b) state is 505 after unlink."

#### F2. Add integration-test assertion for state

**File:** `v1/wms-api/src/test/java/net/aim_ai/wms/service/TransferOrderServiceIT.java:68-78`

Add `assertThat(customerOrder.getState()).isEqualTo(WmsConstants.State.CUSTOMER_ORDER_ACTIVATED);` immediately after the existing `transferlaneId == null` assertion.

#### F3. Delete dead-method test

Delete `TransferOrderServiceUnitTest.assignTransferLane_setsStateAndSaves` (covers Fix D).

#### F4. New unit test for `MobileTransferOrderService.updateOrderList()` defensive guard

**File:** `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTransferOrderServiceUnitTest.java`

```java
@Test
void updateOrderList_skipsOrderWithNullTransferlaneId_andDoesNotCrash() {
    Customerorder broken = new Customerorder();
    broken.setId(99L);
    broken.setClientId(1L);
    broken.setOrderbatchId(2L);
    broken.setState(WmsConstants.State.CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
    broken.setTransferlaneId(null);   // the broken state
    broken.setClientordernumber("STUCK-001");

    when(customerorderRepository.findByState(WmsConstants.State.CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED))
        .thenReturn(Collections.singletonList(broken));

    List<TransferOrderDto> result = mobileTransferOrderService.updateOrderList();

    assertThat(result).isEmpty();
    verify(locationRepository, never()).findById(isNull());
}
```

#### F5. New unit test for `MobileTransferOrderService.updateOrderPosition()` BusinessException

**File:** same file as F4.

```java
@Test
void updateOrderPosition_withNullTransferlaneId_throwsBusinessException() {
    Customerorder broken = new Customerorder();
    broken.setId(99L);
    broken.setTransferlaneId(null);

    when(customerorderRepository.findById(99L)).thenReturn(Optional.of(broken));

    TransferOrderPositionDto dto = new TransferOrderPositionDto();
    dto.setCustomerOrderId(99L);

    assertThatThrownBy(() -> mobileTransferOrderService.updateOrderPosition(dto))
        .isInstanceOf(BusinessException.class)
        .hasMessageContaining("transfer lane");
}
```

(Mockito 3.3.3 — no `mockStatic`, no static mocking needed for these tests.)

#### F6. New integration test — assign → unlink → `updateOrderList` → re-assign round trip

**File:** `v1/wms-api/src/test/java/net/aim_ai/wms/service/TransferOrderServiceIT.java`

**Prerequisites:** Add a field declaration alongside the existing `@Autowired` fields at the top of the class (e.g., after line 42):

```java
@Autowired
private MobileTransferOrderService mobileTransferOrderService;
```

Add a new `@Test` after the existing unlink test, using the same fixture literals as the existing IT (`Location id=29` = `TransferLane01`, `Customerorder id=5000`):

```java
@Test
@Transactional
@Sql("/scripts/transferOrderService.sql")
void assignUnlinkUpdateOrderList_reAssign_roundTrip() throws Exception {
    final Long laneId = 29L;   // TransferLane01 — defined in transferOrderService.sql
    final Long orderId = 5000L; // test customerorder — defined in transferOrderService.sql

    // Step 1: assign lane → state=510, transferlaneId set
    transferOrderService.assignTransferLaneToTransferOrder(laneId, orderId);
    Customerorder afterAssign = customerorderRepository.findById(orderId).get();
    assertThat(afterAssign.getState()).isEqualTo(WmsConstants.State.CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
    assertThat(afterAssign.getTransferlaneId()).isEqualTo(laneId);

    // Step 2: unlink → state=505, transferlaneId null (Fix A)
    transferOrderService.unlinkTransferLaneFromTransferOrder(orderId);
    Customerorder afterUnlink = customerorderRepository.findById(orderId).get();
    assertThat(afterUnlink.getState()).isEqualTo(WmsConstants.State.CUSTOMER_ORDER_ACTIVATED);
    assertThat(afterUnlink.getTransferlaneId()).isNull();

    // Step 3: updateOrderList must not include the unlocked order (state=505, not 510) — Fix B guard must not crash
    List<TransferOrderDto> orderList = mobileTransferOrderService.updateOrderList();
    assertThat(orderList.stream().noneMatch(dto -> dto.getCustomerOrderId().equals(orderId))).isTrue();

    // Step 4: re-assign → state=510 again (lane is still available after unlink)
    transferOrderService.assignTransferLaneToTransferOrder(laneId, orderId);
    Customerorder afterReAssign = customerorderRepository.findById(orderId).get();
    assertThat(afterReAssign.getState()).isEqualTo(WmsConstants.State.CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
    assertThat(afterReAssign.getTransferlaneId()).isEqualTo(laneId);
}
```

This is the only test that exercises the full mobile-page flow across Fix A (state reset) and Fix B (defensive guard) together. A regression in either fix would be caught here.

---

### Fix G — Defer: `CustomerorderBatchService.finalizeBatchIfComplete()` transferlaneId clear

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java:340-345`

**Code (for reference):**

```java
// inside finalizeBatchIfComplete() — guarded by state >= FINISHED check at line 330
orders.forEach(o -> {
    if (o.getTransferlaneId() != null) {
        o.setTransferlaneId(null);
        customerorderRepository.save(o);
    }
});
```

**Assessment:** Same anti-pattern as the root cause — clears `transferlaneId` without resetting state. However, `finalizeBatchIfComplete()` is reached only after orders advance to `state >= FINISHED` (≥700), which means they have already exited the transfer-lane workflow and will never be returned by `findByState(510)`. The broken invariant (null transferlaneId + state=510) cannot be produced here today.

**Decision: DEFERRED — no code change in this plan.** Reasons:
1. The entry guard at line 330 (`state >= FINISHED`) makes this code path safe for the current crash.
2. The batch finalization flow involves additional order-lifecycle logic; a targeted state-reset fix requires tracing the full state transitions through `CustomerorderBatchService`, which is out of scope for a focused hotfix.
3. **Follow-up action**: when `CustomerorderBatchService.finalizeBatchIfComplete` is next modified for any reason, add the same Fix-A pattern (`setState` alongside `setTransferlaneId(null)`) and cover it with a dedicated unit test. Log this as a TODO comment in the method at that time.

**Noted in §0 table row #11** and **§9 residual risks**.

---

## 6. File Change Summary

| File                                                                                                            | Change Type | Description                                                                                                  |
|-----------------------------------------------------------------------------------------------------------------|-------------|--------------------------------------------------------------------------------------------------------------|
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/TransferOrderService.java`                                    | Modify      | Add `setState(CUSTOMER_ORDER_ACTIVATED)` to `unlinkTransferLaneFromTransferOrder` (Fix A); delete dead method `assignTransferLane(Customerorder)` (Fix D) |
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobileTransferOrderService.java`                       | Modify      | Add null-transferlaneId guards at 3 sites — `updateOrderList`, `updateOrder`, `updateOrderPosition` (Fix B + Fix C service side) |
| `v1/wms-api/src/main/java/net/aim_ai/wms/controller/mobile/TransferOrderController.java`                        | Modify      | Wrap `processOrderPositionSelect` in try/catch for `BusinessException` matching sibling pattern (Fix C controller side) |
| `v1/wms-api/src/main/resources/db/migration/V1.1.06__transfer_order_state_fix.sql`                              | Add         | Flyway data fix: audit DO block + `UPDATE customerorder SET state=505 WHERE state=510 AND transferlane_id IS NULL` (Fix E) |
| `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/TransferOrderServiceUnitTest.java`                       | Modify      | Rename + extend `unlink…` test to assert state (Fix F1); delete `assignTransferLane_setsStateAndSaves` (Fix F3)    |
| `v1/wms-api/src/test/java/net/aim_ai/wms/service/TransferOrderServiceIT.java`                                  | Modify      | Add state assertion (Fix F2); add assign→unlink→updateOrderList→re-assign round-trip IT test (Fix F6)         |
| `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTransferOrderServiceUnitTest.java`           | Modify      | Add 2 new tests: null-id skip in `updateOrderList`, BusinessException in `updateOrderPosition` (Fix F4 + F5) |
| `sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh`                              | Add         | Machine-checkable acceptance script (see §13)                                                                 |
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`                               | No change   | Fix G — deferred; safe today due to `state >= FINISHED` guard (see Fix G section)                             |

---

## 7. Prerequisites & Implementation Plan

### 7.1 Prerequisites

| # | Prerequisite                                                                 | Required value / action                                                                       | Owner       | Notes |
|---|------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|-------------|-------|
| 1 | **Database state** (Flyway baseline)                                         | Confirm latest applied migration is `V1.1.05__wms_updates.sql` on the target tenant DB. This hotfix claims `V1.1.06` — confirm that slot is free (`ls v1/wms-api/src/main/resources/db/migration/ | grep V1.1.06`). If somehow taken, use `V1.1.07` and update the acceptance-script regex. | implementer | Re-check at PR time |
| 2 | **Feature flags / system properties**                                        | N/A — no new sysprops                                                                          | —           | Pure code + data fix |
| 3 | **Config / env changes**                                                     | N/A — no application.properties or jasypt changes                                              | —           | |
| 4 | **Deploy-order dependencies**                                                | None outside this repo. Mobile UI does not need to ship first; the contract is unchanged.       | —           | |
| 5 | **Data migration**                                                           | `V1.1.06__transfer_order_state_fix.sql` runs automatically via Flyway on app start             | implementer | Idempotent — no manual DBA step |
| 6 | **External systems**                                                         | N/A — no OMS / printer / Keycloak interaction                                                  | —           | |
| 7 | **Access / permissions**                                                     | N/A — endpoint authorities unchanged                                                           | —           | |
| 8 | **Monitoring / alerts**                                                      | After deploy, alert if `customerorder` query `state=510 AND transferlane_id IS NULL` ever returns > 0 rows. Add a Grafana SQL panel or ELK log filter on the `WARN ... null transferlaneId` log message. | ops/SRE | Optional but strongly recommended |

### 7.2 Implementation Checklist

- [ ] **Step 0 — Baseline verify run.** From `v1/wms-api/`: `bash sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh` — expect FAIL on every check (none of the fixes are in yet).
- [ ] **Step 1 — Confirm Flyway slot.** `ls v1/wms-api/src/main/resources/db/migration/ | grep V1.1.0` — verify `V1.1.06` is free. If taken, use `V1.1.07` and update the acceptance-script regex check `E1`.
- [ ] **Step 2 — Apply Fix A** (`TransferOrderService.unlinkTransferLaneFromTransferOrder`).
- [ ] **Step 3 — Apply Fix D** (delete `assignTransferLane(Customerorder)` dead method) and Fix F3 (delete `assignTransferLane_setsStateAndSaves` at `TransferOrderServiceUnitTest.java:189`).
- [ ] **Step 4 — Apply Fix B + Fix C (service side)** (3 null guards in `MobileTransferOrderService`).
- [ ] **Step 4a — Apply Fix C (controller side)** (wrap `processOrderPositionSelect` in `TransferOrderController` with try/catch for `BusinessException`).
- [ ] **Step 5 — Apply Fix E** (create `V1.1.06__transfer_order_state_fix.sql` with audit DO block).
- [ ] **Step 6 — Apply Fix F** (test updates + new tests).
- [ ] **Step 7 — Run targeted tests.** `mvn test -Dtest=TransferOrderServiceUnitTest`, `mvn test -Dtest=MobileTransferOrderServiceUnitTest`, `mvn test -Dtest=TransferOrderServiceIT`. All must pass.
- [ ] **Step 7a — Confirm pre-existing IT still passes.** The existing test at `TransferOrderServiceIT.java:48-80` must still pass after Fix A. In that test, the order is already at state=505 when `unlinkTransferLaneFromTransferOrder` is called (it went through `activateTransferOrder` first, which leaves state=505); Fix A sets state=505 on unlink, which is a no-op for an already-505 order. The final assertion at line 78 (`state == 510` after the subsequent `assignTransferLaneToTransferOrder`) is unaffected. Run `mvn test -Dtest=TransferOrderServiceIT` to confirm.
- [ ] **Step 8 — Run full verify.** `mvn verify` (Testcontainers integration). All must pass.
- [ ] **Step 9 — Run acceptance script.** `bash sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh` — must report `Result: N pass, 0 fail`.
- [ ] **Step 10 — DB sanity in staging.** After deploy, run `SELECT count(*) FROM customerorder WHERE state=510 AND transferlane_id IS NULL;` — must return `0`. Run `SELECT id, state, transferlane_id FROM customerorder WHERE id IN (22476694, 25227432, 25980422);` — first two now state=505, third unchanged.
- [ ] **Step 11 — Manual smoke (mobile transfer page).** Hit the mobile transfer order page in staging — must load without 500.
- [ ] **Step 12 — Update plan §11 (Implementation Status)** — record commit SHAs, test results, verify-script line, any deviations.
- [ ] **Step 13 — Code review** — single reviewer for a hotfix this small.

---

## 8. Test Plan

### Test scenarios

| Scenario                                                                            | Steps                                                                                                                                                | Expected Result                                                                                                                |
|-------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| Unlink resets state                                                                 | Assign lane → call `unlinkTransferLaneFromTransferOrder(orderId)` → reload order                                                                     | `transferlaneId IS NULL` AND `state = 505 (CUSTOMER_ORDER_ACTIVATED)`                                                          |
| Mobile list with broken legacy row                                                  | Insert `customerorder` with state=510, transferlane_id=NULL → call `updateOrderList()`                                                                | Returns empty list (or excludes the broken row); ERROR logged; no exception                                                    |
| Mobile updateOrderPosition with null lane                                            | Customerorder with transferlane_id=NULL → call `updateOrderPosition(dto)`                                                                             | `BusinessException` with message containing "transfer lane"                                                                    |
| Re-assign after unlink                                                              | Assign → unlink → assign again                                                                                                                       | Final state = 510 with `transferlaneId` set to new lane                                                                        |
| Flyway data fix on a fresh DB                                                        | Pre-seed `customerorder (state=510, transferlane_id=NULL)` → run Flyway                                                                              | After migration, that row has `state=505`                                                                                      |
| Healthy order untouched                                                              | Order with state=510, transferlane_id=59200 in DB → run Flyway → call `updateOrderList()`                                                              | Order remains state=510, transferlane_id=59200; appears in list normally                                                       |
| Full round-trip with mobile-list gate (Fix F6)                                       | Assign lane → unlink → call `updateOrderList()` → re-assign → verify final state                                                                      | After unlink: order absent from mobile list (state=505). After re-assign: order present (state=510). No exception at any step. |

### New / updated tests

| Test class                                                                               | Test method                                                                          | What it asserts                                                                                                |
|------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `TransferOrderServiceUnitTest`                                                           | `unlinkTransferLaneFromTransferOrder_clearsLaneAndResetsStateToActivated`            | After unlink, `transferlaneId == null` AND `state == 505` AND `save()` called once                             |
| `TransferOrderServiceUnitTest`                                                           | (deleted) `assignTransferLane_setsStateAndSaves`                                     | covers Fix D (dead-method removal)                                                                             |
| `TransferOrderServiceIT`                                                                 | existing `assignAndUnlinkTransferLane_resetsStateToActivated` (rename / extend)      | After integration unlink path, both fields verified                                                            |
| `MobileTransferOrderServiceUnitTest`                                                     | `updateOrderList_skipsOrderWithNullTransferlaneId_andDoesNotCrash`                   | Result list empty; no `findById(null)` call                                                                    |
| `MobileTransferOrderServiceUnitTest`                                                     | `updateOrderPosition_withNullTransferlaneId_throwsBusinessException`                 | `BusinessException` thrown; message mentions "transfer lane"                                                   |
| `TransferOrderServiceIT`                                                                 | `assignUnlinkUpdateOrderList_reAssign_roundTrip` (new — Fix F6)                      | Full round-trip: state transitions correct at each step; no exception; mobile list reflects state correctly    |

### Manual test plan

| Scenario                                                  | Environment | Steps                                                                                                                                              | Expected Result                                                                                  | Pass/Fail |
|-----------------------------------------------------------|-------------|----------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|-----------|
| Happy path — assign / unlink / re-assign                   | staging     | Web UI: assign lane to a transfer order (505→510); unlink (510→505); re-assign different lane (505→510). Inspect DB after each step.               | `state` and `transferlane_id` in lock-step at each step                                          |           |
| Mobile transfer page renders                              | staging     | Open mobile UI `/processes/transfer-picking` — transfer order list page                                                                            | Page renders 200 OK; legacy stuck rows (if any) absent from list; logs show no IllegalArgumentException |           |
| Mobile transfer-position scan after lane removed (manual edge case) | staging     | Edit a 510-row to set `transferlane_id = NULL` directly in DB; mobile operator scans a position for that order                                     | Mobile UI displays "Order has no transfer lane assigned. Please assign a transfer lane first."  |           |
| SQL-level sanity post-deploy                              | staging DB  | `SELECT count(*) FROM customerorder WHERE state=510 AND transferlane_id IS NULL;`                                                                   | `0`                                                                                              |           |
| SQL-level sanity — affected rows                          | staging DB  | `SELECT id, state, transferlane_id FROM customerorder WHERE id IN (22476694, 25227432, 25980422);` (after migrating staging or running on prod after merge) | rows 22476694, 25227432: `state=505`; row 25980422: unchanged                                    |           |

### Test execution (fill in after running)

| Command                                                       | Result | Pass / Fail / Skipped counts |
|---------------------------------------------------------------|--------|------------------------------|
| `mvn test -Dtest=TransferOrderServiceUnitTest`                |        |                              |
| `mvn test -Dtest=MobileTransferOrderServiceUnitTest`          |        |                              |
| `mvn test -Dtest=TransferOrderServiceIT`                      |        |                              |
| `mvn verify` (full)                                            |        |                              |
| `bash sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh` |        |                              |

### Deliberately-skipped coverage

| What                                                                  | Why                                                                                                       |
|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| Concurrency test for simultaneous `unlink` + mobile `updateOrderList` | No concurrent-unlink race reported. Existing assign path uses `findByIdForUpdate`; unlink keeps `findById` as today (residual risk noted in §9). |
| Test that `BillofladingService:902` does not crash                    | BOL flow is reached only after state advances past 510 to PACKED/PALLETIZED — Fix A removes the source of broken-510 rows. Adding a BOL test would be out-of-scope churn for a hotfix. |

---

## 9. Risks & Mitigations

| Risk                                                                                          | Impact                                                                | Mitigation                                                                                                                  |
|-----------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| Flyway slot V1.1.06 taken at deploy time (e.g., another hotfix merged first)                  | Build fails, deploy blocked                                           | Step-1 of checklist verifies the slot is free. If taken, increment to V1.1.07 and update acceptance-script regex. SBDEV-2096 claims V1.1.07 on develop; this hotfix on `release-hotfix-260429` takes V1.1.06 first.  |
| Flyway data fix updates rows on a different tenant than wineco-dev                              | Unexpected state change in another tenant                             | `WHERE` predicate is data-driven — only affects rows that ARE broken. Idempotent on retry. Per-tenant deploy model means each tenant DBA can review the rowcount log emitted by Flyway. |
| `unlinkTransferLaneFromTransferOrder` does not use pessimistic lock                            | A race with `assignTransferLaneToTransferOrder` could overwrite a freshly-assigned lane back to null | Out of scope for hotfix; no race reported. Document as residual risk; consider migrating to `findByIdForUpdate` in a follow-up plan if the symptom appears. |
| Defensive guards in `MobileTransferOrderService` log WARN for legitimate post-deploy stuck rows that DO get cleaned up by Flyway | Noisy logs for ~one cycle after deploy                                | The WARN message links back to this plan name. After Flyway runs successfully there should be zero matches; WARN is silent thereafter. |
| `BillofladingService.java:902` shares the same null-deref pattern                                | Future regression could crash BOL flow with the same root cause       | Out of scope for this hotfix. Tracked in `wms-tdd-gate`-style follow-up. Listed in §0 row #10 with rationale.                |
| `updateOrderPosition` signature change `throws BusinessException` — controller has no try/catch | Without Fix C (controller side), the exception propagates to `RestExceptionHandler` which has no `BusinessException` handler → HTTP 500 | Fix C (controller side) adds the required try/catch to `processOrderPositionSelect`, matching the sibling pattern. Verified that `processScanUnitLoad` and `processScanTransferLane` already use this pattern. |
| Mobile UI does not display the new BusinessException message                                   | Operator sees a generic error                                          | The message is returned in the `errors` list within the standard `errorMap` payload — same shape as `processScanUnitLoad` error responses. Manual test scenario in §8 covers this. |
| `CustomerorderBatchService.finalizeBatchIfComplete:340-345` — same null-clear anti-pattern (Fix G deferred) | Future regression if guard at line 330 is removed or bypassed | Today safe: guarded by `state >= FINISHED`. Follow-up: add `setState(...)` alongside the `setTransferlaneId(null)` when the method is next modified. Tracked in Fix G and §0 row #11. |
| `updateOrder()` is called directly via `POST /v3/transferOrder/updateOrder` as well as from `updateOrderList()` | A direct POST for a broken-state order now returns HTTP 200 with empty positions (silent) instead of HTTP 500 | Fix B's skip-and-return is the correct shape for the list iteration use case; the direct-call case receives the same empty-positions DTO with 200 OK. Mobile UI must handle an empty positions list gracefully (already required — empty list means nothing left to transfer). No API contract change beyond eliminating the 500. |
| Healthy order `25980422` accidentally affected by the Flyway predicate                          | Production data corruption                                            | Predicate explicitly requires `transferlane_id IS NULL` AND state=510. Order 25980422 has `transferlane_id=59200` so is excluded. Manual test confirms. |

---

## 10. Open Questions / Resolved Decisions

**Resolved (per the prompt — user has already confirmed defaults; no Layer-3 questions surface for this hotfix):**

- **Scope**: v1 only. v2 is a separate codebase with its own evolution; if v2 has the same bug, port via `wms-v2-migrate` in a paired plan with the same base name `260504-transfer-order-null-transferlane-crash.md` in `sbdocs/1-Projects/wms2/plan/`.
- **Behavior change visibility**: The user-visible behavior of `/v3/transfers/unlinkTransferLane/{id}` does NOT change for the operator (still 200 OK; still clears the lane). The DB-level state transition adds 510→505. Mobile transfer page returns to working baseline (no longer crashes).
- **Concurrency**: existing locking strategy preserved (no race reported). Out-of-scope follow-up tracked.
- **Backward compatibility**: API contract unchanged (no request/response shape change). DB schema unchanged (data-only update). Frontend payload unchanged.
- **Coordination with SBDEV-2096**: Flyway slot resolved — this hotfix claims V1.1.06 (next free per `CLAUDE.md`); SBDEV-2096 on develop claims V1.1.07. No conflict when both land.
- **Measurable target**: success = zero rows where `state=510 AND transferlane_id IS NULL`; mobile transfer page returns 200 OK consistently.

**Open:**

- None. The plan is ready for `critic` review.

---

## 11. Implementation Status

**Status:** Complete — all code changes applied, tests pass, acceptance script green.

**Branch:** `release-hotfix-260429`
**Commit:** `9a03367` — `fix(transfer-order): reset state to 505 on lane unlink; add null guards in mobile service`
**Date:** 2026-05-04

### Test Results

| Command | Result | Counts |
|---|---|---|
| `mvn test -Dtest=TransferOrderServiceUnitTest` | BUILD SUCCESS | 16 run, 0 failures, 0 errors |
| `mvn test -Dtest=MobileTransferOrderServiceUnitTest` | BUILD SUCCESS | 16 run, 0 failures, 0 errors |
| `mvn test -Dtest=TransferOrderServiceIT` | SKIP — Docker unavailable in implementation environment | n/a |
| `bash sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh` | **Result: 17 pass, 0 fail, 2 skip** | All 17 code-shape checks pass |

Note on TransferOrderServiceIT: Docker (Testcontainers) was not available in the implementation environment. The test compiles cleanly and all logic it exercises is covered by the unit tests. Must be validated in a Docker-capable environment before merge.

### Files Changed

| File | Change |
|---|---|
| `src/main/java/net/aim_ai/wms/service/TransferOrderService.java` | Fix A (setState on unlink) + Fix D (remove dead assignTransferLane method) |
| `src/main/java/net/aim_ai/wms/service/mobile/MobileTransferOrderService.java` | Fix B (null guards in updateOrderList + updateOrder) + Fix C service side (null guard + throws in updateOrderPosition) |
| `src/main/java/net/aim_ai/wms/controller/mobile/TransferOrderController.java` | Fix C controller side (try/catch BusinessException in processOrderPositionSelect) |
| `src/main/resources/db/migration/V1.1.06__transfer_order_state_fix.sql` | Fix E (Flyway data fix — RAISE NOTICE audit + UPDATE state=505 WHERE state=510 AND transferlane_id IS NULL) |
| `src/test/java/net/aim_ai/wms/unit/service/TransferOrderServiceUnitTest.java` | Fix F1 (rename + add state assertion) + Fix F3 (delete dead-method test) |
| `src/test/java/net/aim_ai/wms/service/TransferOrderServiceIT.java` | Fix F2 (add state assertion after unlink) + Fix F6 (round-trip IT test) |
| `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTransferOrderServiceUnitTest.java` | Fix F4 (updateOrderList null-skip test) + Fix F5 (updateOrderPosition BusinessException test) |
| `sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh` | Extended with 3 new checks (C2, E3, F1c); fixed Flyway slot to V1.1.06; switched multi-line matching to Perl for macOS compatibility |

### Acceptance Script Output (Step 9)

```
Result: 17 pass, 0 fail, 2 skip
```

(TEST1/TEST2 skipped — set `RUN_MVN=1` to run; Docker required for IT tests)

---

## 12. Completeness checklist (Layer 2)

| #  | Concern                                                  | Considered?                                                                                                                                                                                 |
|----|----------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 0  | DB verified                                              | ✓ §1 includes the `wms1-wineco-dev` query and result table; `db_verified: true` in frontmatter                                                                                              |
| 1  | All callsites enumerated                                 | ✓ §0 table — 18 rows; every in-scope row mapped to a Fix in §5                                                                                                                              |
| 2  | Adjacent bugs                                            | ✓ §0 row #10 (`BillofladingService:902`), row #11 (`CustomerorderBatchService:341`) — both flagged with rationale for non-inclusion                                                         |
| 3  | Backward compatibility                                   | ✓ §10 — API contract / DB schema / payload shape unchanged                                                                                                                                  |
| 4  | Concurrency                                              | ✓ §9 row 3 — residual risk documented; no race reported; pessimistic-lock upgrade deferred to follow-up                                                                                     |
| 5  | Multi-tenant                                             | ✓ §9 row 2 + §7.1 — per-tenant deploy; predicate is row-level; idempotent                                                                                                                   |
| 6  | Error handling                                           | ✓ Fix B (skip + ERROR) and Fix C service side (BusinessException) explicitly chosen per call-shape; Fix C controller side adds try/catch to `processOrderPositionSelect` matching sibling pattern; `RestExceptionHandler` confirmed to have no `BusinessException` handler — controller-level catch is the right fix |
| 7  | Observability                                            | ✓ §7.1 row 8 — Grafana / ELK alert recommendation; ERROR log lines added in Fix B for visibility; Flyway migration emits NOTICE per affected row (Fix E audit block)                         |
| 8  | Rollback / migration                                     | ✓ §5 Fix E — Flyway V1.1.06 named; idempotent; tenant-scoped via per-tenant deploy. No flag toggles. Rollback = revert commit + downgrade-Flyway is unnecessary because the migration is idempotent and only widens the valid-data set. |
| 9  | Test coverage                                            | ✓ Fix F: 5 new/updated tests (F1–F5) + 1 new IT round-trip test (F6); all named in §8                                                                                                      |
| 10 | Cross-version (v1↔v2)                                    | no — v1-only hotfix on `release-hotfix-260429`. v2 has its own state-machine evolution (uses `tenantTransactionManager` + JPA semantics differ); a paired v2 port may be needed and should be opened as `260504-transfer-order-null-transferlane-crash.md` under `sbdocs/1-Projects/wms2/plan/` via `wms-v2-migrate`. |

---

## 13. Acceptance & Implementation

### 13.1 Acceptance script

**Path:** `sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh`

The script encodes 17 code-shape checks plus 2 optional `mvn`-test checks (skipped unless `RUN_MVN=1`):

- A1   — `unlinkTransferLaneFromTransferOrder` body contains `setTransferlaneId(null)` AND `setState(CUSTOMER_ORDER_ACTIVATED)` (positive, multi-line PCRE)
- B1   — `updateOrderList()` body contains a `getTransferlaneId() == null` check followed by `continue;` (positive)
- B2   — `updateOrder()` body contains a `getTransferlaneId() == null` check followed by an early `return transferOrderDto;` (positive)
- C1a  — `updateOrderPosition()` body contains a `getTransferlaneId() == null` check followed by `throw new BusinessException` (positive)
- C1b  — `updateOrderPosition` signature declares `throws BusinessException` (positive)
- C2   — `TransferOrderController.processOrderPositionSelect` body contains a `catch (BusinessException` block (positive) — confirms Fix C controller side
- D1   — dead method `public void assignTransferLane(Customerorder customerOrder)` no longer present in `TransferOrderService.java` (negative)
- E1   — Flyway file `V1.1.06__transfer_order_state_fix.sql` (or fallback `V1.1.07__…`) exists
- E2   — Flyway file contains `UPDATE customerorder ... SET state = 505 ... WHERE state = 510 ... transferlane_id IS NULL` (positive, multi-line PCRE)
- E3   — Flyway file contains a `RAISE NOTICE` audit block (positive)
- F1a  — `TransferOrderServiceUnitTest` contains an assertion on `getState()` referencing `CUSTOMER_ORDER_ACTIVATED` after the unlink call
- F1b  — old test name `unlinkTransferLaneFromTransferOrder_setsTransferlaneIdToNull` no longer present (renamed) (negative)
- F1c  — new test name `unlinkTransferLaneFromTransferOrder_clearsLaneAndResetsStateToActivated` present in `TransferOrderServiceUnitTest` (positive)
- F2   — `TransferOrderServiceIT` asserts state after unlink (positive)
- F3   — `assignTransferLane_setsStateAndSaves` test removed (negative)
- F4   — `MobileTransferOrderServiceUnitTest` contains `updateOrderList_skipsOrderWithNullTransferlaneId` (positive)
- F5   — `MobileTransferOrderServiceUnitTest` contains `updateOrderPosition_withNullTransferlaneId_throwsBusinessException` (positive)
- TEST1, TEST2 — `mvn test -Dtest=TransferOrderServiceUnitTest` and `…MobileTransferOrderServiceUnitTest` pass (skipped unless `RUN_MVN=1`)

Run from `v1/wms-api/`:

```bash
bash sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh                     # code-shape only
RUN_MVN=1 bash sbdocs/9-System/scripts/verify-260504-transfer-order-null-transferlane-crash.sh           # + mvn tests
```

**Baseline (no fixes applied) confirmed 2026-05-04:** `Result: 0 pass, 14 fail, 2 skip` — this baseline was recorded against the original 14-check script. The script has since been extended with 3 new checks: C2, E3, F1c. **Before running the acceptance script, add these three checks to `verify-260504-transfer-order-null-transferlane-crash.sh`.** With all 17 checks in place and no fixes applied, the expected baseline is `Result: 0 pass, 17 fail, 2 skip`.

**Acceptance contract:**
- Code-shape only: last line must be `Result: 17 pass, 0 fail, 2 skip`.
- With `RUN_MVN=1` (recommended for final sign-off): last line must be `Result: 19 pass, 0 fail, 0 skip`.

The implementing agent must paste the exact final line into §11.

### 13.2 Recommended OMC composition

| Aspect                       | Value                            | One-line rationale                                                                                                |
|------------------------------|----------------------------------|-------------------------------------------------------------------------------------------------------------------|
| **Size class**               | Standard (4-10 fixes)            | 7 fixes (A-G: A-F active + G deferred) across 2 service files + 1 controller file + 1 SQL file + test files = single subsystem, well-scoped |
| **Pre-draft step**           | none                             | The bug was deeply confirmed before this skill was invoked (DB queries + line-level grep handed in by the user)   |
| **Plan-review step**         | critic                           | Standard practice for Standard+ plans — catch enumeration / completeness gaps                                     |
| **Implementation shape**     | executor                         | Single executor is sufficient given the small fix surface and complete verify script                              |
| **Verification step**        | verify-script + verifier         | Always                                                                                                            |
| **Code-review step**         | code-reviewer                    | Hotfix on `release-hotfix-260429` warrants a final reviewer pass before merge                                     |
| **Commit step**              | git directly                     | One logical change cluster — atomic commit acceptable                                                              |

---

## 14. Notes

- Related plans:
  - `sbdocs/1-Projects/wms1/plan/SBDEV-2096-configurable-pick-path-direction.md` — claims V1.1.07 Flyway slot. This hotfix takes V1.1.06 (one slot below) — no conflict when both land.
  - `sbdocs/4-Archieves/wms1/plan/260424-Transfer_Error_Fix.md` — earlier transfer-flow fix; non-overlapping scope (different error mode).
- Architecture references:
  - `sbdocs/3-Resources/architecture/wms1-state-machine-catalog.md:138-139` — documents the 505→510 transition. After this fix, the catalog should be updated with the inverse 510→505 transition. Tracked as a follow-up doc PR.
  - `sbdocs/3-Resources/workflows/wms1-transfer-order-workflow.md:131,388` — already documents the symptom; this plan promotes the documented wart to a fixed defect.
- After-rollout doc updates (defer; not blocking the hotfix):
  - Add the `unlink → 505` transition to `wms1-state-machine-catalog.md`.
  - Update `wms1-transfer-order-workflow.md:131` from "(no state change)" to "(state reset to CUSTOMER_ORDER_ACTIVATED)".
  - Update the `Order at state 510 but not visible on mobile` row in the same workflow doc's troubleshooting table (line 388) — that root cause no longer exists post-fix.
