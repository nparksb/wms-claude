---
title: "WMS: Prevent Reassigning Finished Club Batches to a Staging Lane"
ticket: "SBDEV-2163"
ticket_url: "https://app.clickup.com/t/868jev5g5"
type: "feature"
priority: ""
status: "ready"
project:
  - v1/wms-api
  - v1/wms-web-ui
  - v1/wms-mobile-ui
version: ""
requester: "Joseph Gero II"
created: "2026-04-30"
updated: "2026-04-30"
related:
  - "../../../3-Resources/workflows/wms1-club-order-processing.md"
tags:
  - plan
  - club
  - wms1
---

# WMS: Prevent Reassigning Finished Club Batches to a Staging Lane

**Ticket:** [SBDEV-2163](https://app.clickup.com/t/868jev5g5)
**Project:** v1/wms-api, v1/wms-web-ui, v1/wms-mobile-ui | **Version:** unscheduled | **Type:** Feature / Protective Guard
**Status:** draft
**Date:** 2026-04-30

---

## 0. Affected Sites (Enumeration Before Drafting)

| # | File:line | Construct | In-scope this plan? | Phase |
|---|-----------|-----------|---------------------|-------|
| 1 | `service/CustomerorderBatchService.java:646` | `assignStagingLaneToOrderBatch(Long, Long)` — single write chokepoint for lane assignment | **Yes — primary change site** | Phase 1 |
| 2 | `controller/ClubLineController.java:83–110` | `GET /v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}` — calls #1 directly | Yes — covered by guard at #1, no code change needed | — |
| 3 | `controller/ClubLineController.java:139–167` | `GET /v3/clubLine/activateBatch/{orderBatchId}/{locationId}` — calls #1 then `activateOrderBatch` | Yes — covered by guard at #1, no code change needed | — |
| 4 | `repo/jpa/CustomerorderRepository.java:40–41` | `findByOrderbatchId(Long)` — existing method reused for guard query | Yes — no change, reuse as-is | — |
| 5 | `service/CustomerorderBatchService.java:409` | `assignStagingLane(CustomerorderBatch)` — state-only setter, no lane fetch; not called from any controller club flow | No — no production controller calls this for lane reassignment | — |
| 6 | `test/unit/service/CustomerorderBatchServiceUnitTest.java:194` | `// --- assignStagingLaneToOrderBatch ---` test block | **Yes — update 2 existing tests + add 4 new cases** | Phase 1 |
| 7 | `test/unit/controller/ClubLineControllerUnitTest.java` | Controller unit test class | **No — file does not exist; controller coverage via service tests + manual M2/M3** | — |

All in-scope rows are covered by §3 Design. No DB migration, no UI code change, no new repository method.

---

## 1. Problem Statement

Club batches can remain in an open state (< 700) even after all their child orders have been shipped and finished. This happens because the `CustomerorderBatch.state` field is only set to `FINISHED (700)` when `closeBOL()` processes the batch — and only if all orders finish in the same BOL close. If a batch's status becomes stale (e.g., stuck at `ORDER_BATCH_CLUB_RUN_FINISHED = 530` or `ORDER_BATCH_ACTIVATED = 520`), warehouse users can still interact with it through the club workflow.

Specifically, two UI-accessible endpoints allow re-assigning a staging lane to the batch:

- `GET /v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}` — sets batch state back to `525`
- `GET /v3/clubLine/activateBatch/{orderBatchId}/{locationId}` — sets batch state to `525` then `520`

This causes several operational problems (from ticket):
- Finished batches appear in **Open Clubs** instead of Completed Clubs
- Completed batches are **put back into Lane Assigned** state
- Physical staging lanes stay **blocked by already-shipped work**
- Club screens become misleading because batch status no longer matches child orders

The system should use child order state as the authoritative source of truth, not only the batch header state.

---

## 2. Current Architecture

### State Machine (Club Batch)

```
RAW (0)
  → ORDER_BATCH_STAGING_LANE_ASSIGNED (525)   [assignStagingLaneToOrderBatch]
    → ORDER_BATCH_ACTIVATED (520)              [activateOrderBatch]
      → ORDER_BATCH_CLUB_RUN_FINISHED (530)    [runClubLine]
        → FINISHED (700)                        [closeBOL — only if all orders finish]
```

### State Machine (Customerorder within Club Batch)

```
RAW (0)
  → PACKED (650)    [runClubLine — stock transferred to parcel]
    → FINISHED (700) [closeBOL — shipped]
     or CANCELED (800) [cancelled before/after run]
```

### Lane Assignment Flow

Both endpoints funnel through a single service method:

**`ClubLineController.java:84–95`** — `/assignStagingLane`:
```java
customerorderBatchService.assignStagingLaneToOrderBatch(locationId, orderBatchId);
```

**`ClubLineController.java:148–151`** — `/activateBatch`:
```java
customerorderBatchService.assignStagingLaneToOrderBatch(locationId, batchId);
customerorderBatchService.activateOrderBatch(batchId);
```

**`CustomerorderBatchService.java:646–663`** — single chokepoint (no `@Transactional`):
```java
public void assignStagingLaneToOrderBatch(Long stagingLaneId, Long orderBatchId)
        throws BusinessException {
    CustomerorderBatch orderBatch = customerorderBatchRepository.findById(orderBatchId)
            .orElseThrow(() -> new BusinessException("Order batch not found: " + orderBatchId));
    Location stagingLane = locationRepository.findById(stagingLaneId)
            .orElseThrow(() -> new BusinessException("Location not found: " + stagingLaneId));

    List<Location> availableStagingLanes = getAvailableStagingLanes(orderBatch.getId());
    if (!availableStagingLanes.contains(stagingLane)) {
        throw new BusinessException("staging lane is not available anymore. refresh and try again.");
    }

    orderBatch.setStaginglaneId(stagingLane.getId());
    orderBatch.setState(WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED);
    customerorderBatchRepository.save(orderBatch);
}
```

**Problem:** No check is made against child order states before mutating the batch.

### Existing Repository Method (reusable)

`CustomerorderRepository.java:40–41`:
```java
@RestResource(path = "findByOrderbatchId", rel = "findByOrderbatchId")
List<Customerorder> findByOrderbatchId(@Param("orderbatchId") Long orderbatchId);
```

### Terminal Order State Constants

`WmsConstants.java`:
```java
public static final int FINISHED = 700;  // line 104
public static final int CANCELED = 800;  // line 109
```

---

## 3. Design

### 3.1 Guard in `assignStagingLaneToOrderBatch`

**Problem:** The method has no check against child order completeness before it sets the batch state backward to `525`.

**Solution:** Add a guard at the top of `assignStagingLaneToOrderBatch` that fetches all child orders for the batch and throws `BusinessException` if all of them are in a terminal state (`FINISHED=700` or `CANCELED=800`).

The guard uses the existing `customerorderRepository.findByOrderbatchId()` — no new query needed. The in-memory `allMatch` check is acceptable: club batches typically have tens to low hundreds of orders, not thousands.

**Code change** in `CustomerorderBatchService.java` at line 646:

```java
public void assignStagingLaneToOrderBatch(Long stagingLaneId, Long orderBatchId)
        throws BusinessException {

    // Guard: prevent lane assignment if all child orders are already complete or cancelled.
    // Use order state as source of truth — the batch header state can become stale.
    List<Customerorder> batchOrders = customerorderRepository.findByOrderbatchId(orderBatchId);
    boolean allTerminal = batchOrders.isEmpty() || batchOrders.stream().allMatch(o -> {
            Integer state = o.getState();
            return Integer.valueOf(WmsConstants.State.FINISHED).equals(state)
                || Integer.valueOf(WmsConstants.State.CANCELED).equals(state);
    });
    if (allTerminal) {
        LOG.warn("assignStagingLaneToOrderBatch: blocked — batch {} has no active orders (all finished or cancelled)", orderBatchId);
        throw new BusinessException(
                "Club batch is finished or cancelled — cannot assign a staging lane.");
    }

    // Existing logic unchanged below
    CustomerorderBatch orderBatch = customerorderBatchRepository.findById(orderBatchId)
            .orElseThrow(() -> new BusinessException("Order batch not found: " + orderBatchId));
    Location stagingLane = locationRepository.findById(stagingLaneId)
            .orElseThrow(() -> new BusinessException("Location not found: " + stagingLaneId));

    List<Location> availableStagingLanes = getAvailableStagingLanes(orderBatch.getId());
    if (!availableStagingLanes.contains(stagingLane)) {
        throw new BusinessException("staging lane is not available anymore. refresh and try again.");
    }

    orderBatch.setStaginglaneId(stagingLane.getId());
    orderBatch.setState(WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED);
    customerorderBatchRepository.save(orderBatch);
}
```

**Why `Integer.valueOf(...).equals(state)` not `==`:** `getState()` returns `Integer` (boxed). Using `==` on an `Integer` and an `int` is safe via autoboxing, but can throw `NullPointerException` if `state` is null. This codebase consistently uses the `.equals()` pattern for null safety — see `CustomerorderBatchService.java:125, 192, 360, 378, 394, 426`. The explicit `Integer state = o.getState()` extraction also makes the null case readable.

**Why explicit `batchOrders.isEmpty()` branch:** A zero-order batch has nothing to process and must not be assigned a lane. Separating this from `allMatch` avoids relying on `allMatch`'s vacuous-true semantics (which are correct but non-obvious). This is a deliberate tightening, not borrowed from another method's behavior.

**Why at the top of this method (not in the controller):** Both affected endpoints call this method. Placing the guard here makes it impossible to bypass via any future caller without explicitly opting out.

**`@Modifying` query audit:** There are two other places that write `staginglane_id`: `CustomerorderBatchRepository.java:147` (a `@Modifying` UPDATE that sets `staginglane_id = NULL`) and `CustomerorderBatchService.unlinkStagingLaneFromOrderBatch` (also sets to null). Neither _assigns_ a lane; both only clear it. The single-chokepoint claim holds.

**Race condition:** `CustomerorderBatch` has `@Version` (optimistic locking, `CustomerorderBatch.java:51`). Both controller endpoints wrap their service calls in `OptimisticLockRetryTemplate.executeWithRetry` (`ClubLineController.java:93, 148`). If a concurrent request races to finalize orders between the guard read and the downstream save, the `@Version` check on the batch save will detect the conflict and retry, re-running the guard with fresh data.

**Error propagation:** `BusinessException` is caught by both controller endpoints (lines 96–99 and 152–155) and returned as HTTP 200 with body:
```json
{ "errors": [{ "type": "Runtime Error", "message": "Club batch is finished or cancelled — cannot assign a staging lane." }] }
```
**Note on HTTP 200:** Both endpoints return `HttpStatus.OK` even on error (existing behavior, not introduced by this ticket). Before sign-off, verify manually that the v1 wms-web-ui and wms-mobile-ui club screens parse and display the `errors[]` payload rather than treating all 200 responses as success (see M6 in §7 manual tests).

**Files changed:**
- `v1/wms-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java` — add guard (Modify)

---

## 4. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java` | Modify | Add terminal-order guard at top of `assignStagingLaneToOrderBatch` |
| `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/CustomerorderBatchServiceUnitTest.java` | Modify | Update 2 existing tests + add 3 new test cases in the `assignStagingLaneToOrderBatch` block |
| `sbdocs/9-System/scripts/verify-SBDEV-2163.sh` | Add | Smoke-test script (curl-based, run against dev after deploy) |

No Flyway migration. No UI code change. No new constants or repository methods.

> **Note on controller test:** No `ClubLineControllerUnitTest.java` exists in the project. Controller-level coverage for the blocked path is achieved through the service unit tests (the guard throws before any controller-owned logic) and manual tests M2/M3 in §7. Creating a net-new controller test class is out of scope for this ticket.

---

## 5. Phased Implementation Plan

### 5.1 Prerequisites

| Prerequisite | Status | Notes |
|---|---|---|
| DB schema change | N/A | No schema change |
| Flyway migration | N/A | No migration needed |
| System property / feature flag | N/A | Guard is always-on; no toggle required |
| Deploy-order dependency | N/A | Single-service change |
| Data backfill | N/A | Guard reads live order state; no historical data needs updating |
| External system coordination | N/A | OMS is not affected; BOL close flow is unchanged |
| Monitoring / alerting | N/A | No new metrics |

### 5.2 Phase 1 — Add guard + tests (single PR)

**Goal:** Insert the terminal-order guard into the single lane-assignment chokepoint and test it.

**Branch:** `task/SBDEV-2163`
**Merge target:** `main`
**Estimated effort:** 1–2 hours

**Changes:**
1. Edit `CustomerorderBatchService.assignStagingLaneToOrderBatch` — insert guard at top (see §3.1).
2. Update 2 existing tests in `CustomerorderBatchServiceUnitTest` (stub `findByOrderbatchId` with an active order so they pass through the guard).
3. Add 4 new unit tests to `CustomerorderBatchServiceUnitTest` (all-finished / all-cancelled / mixed-active / no-orders cases).

**Testing:** See §7.

**Risk:** Low. The guard is a pure read + early-exit. No write path is altered. Existing passing batches are unaffected.

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|--------|--------|-------|--------|
| API response — active batch | `ASSIGNED STAGING LANE` success | Same | None |
| API response — finished batch | `ASSIGNED STAGING LANE` success (wrong) | `errors` array with clear message | User-facing change — intended |
| `customerorder_batch.state` — active batch | Updated to 525 | Same | None |
| `customerorder_batch.state` — finished batch | Updated to 525 (wrong) | Unchanged — guard blocks write | Corrective |
| `CustomerorderRepository.findByOrderbatchId` | Existing method | Reused, not modified | None |
| UI rendering | Error toast on service error | Same mechanism; new message text | None |

**What does NOT change:**
- `runClubLine` flow
- `activateOrderBatch` standalone behavior
- `unlinkStagingLane` flow
- `getAvailableStagingLanes` query
- `closeBOL` batch-finalization logic
- Any order state transitions
- OMS notification flows

---

## 7. Testing Strategy

### Unit Tests — `CustomerorderBatchServiceUnitTest`

Block location: `// --- assignStagingLaneToOrderBatch ---` at **line 194**. Style: plain `@Test void` methods, no `@DisplayName`, no `@Nested` — match the file's existing convention.

**⚠️ Existing tests that must be updated** (guard calls `customerorderRepository.findByOrderbatchId` first; without stubbing, Mockito returns an empty list → guard throws → test breaks):

| Existing test | Required update |
|---|---|
| `assignStagingLaneToOrderBatch_availableLane_assignsLaneAndSaves` (line 196) | Add `when(customerorderRepository.findByOrderbatchId(1L)).thenReturn(Collections.singletonList(activeOrder))` before the service call, where `activeOrder` has `state = PACKED (650)` |
| `assignStagingLaneToOrderBatch_unavailableLane_throwsBusinessException` (line 214) | Same stub — needs at least one active order so the guard passes through to the lane-availability check |

**New tests** (insert after line 231, before the `// --- cancelBatch ---` comment):

| Test method | Scenario | Expected |
|-------------|----------|----------|
| `assignStagingLaneToOrderBatch_allOrdersFinished_throwsBusinessException` | `findByOrderbatchId` returns one order with `state = FINISHED (700)` | `BusinessException` thrown; message contains `"finished or cancelled"`; `save()` never called |
| `assignStagingLaneToOrderBatch_allOrdersCanceled_throwsBusinessException` | `findByOrderbatchId` returns one order with `state = CANCELED (800)` | Same |
| `assignStagingLaneToOrderBatch_mixedStates_oneActive_allowsAssignment` | `findByOrderbatchId` returns two orders: one `PACKED (650)`, one `FINISHED (700)` | No exception; `save()` called once on the batch |
| `assignStagingLaneToOrderBatch_noOrders_throwsBusinessException` | `findByOrderbatchId` returns empty list | `BusinessException` thrown (empty batch blocked) |

### Manual Test Plan

| # | Scenario | Environment | Steps | Expected Result |
|---|----------|-------------|-------|-----------------|
| M1 | Assign lane to active batch | dev | 1. Open a club batch with at least one order in state < 700. 2. Call `GET /v3/clubLine/assignStagingLane/{id}/{laneId}` | Returns success `ASSIGNED STAGING LANE` |
| M2 | Assign lane to finished batch | dev | 1. Find a club batch whose all child orders are state 700. 2. Call `GET /v3/clubLine/assignStagingLane/{id}/{laneId}` | Returns `{ "errors": [{ "type": "Runtime Error", "message": "...cannot be assigned to a staging lane..." }] }` |
| M3 | Activate finished batch | dev | 1. Same finished batch as M2. 2. Call `GET /v3/clubLine/activateBatch/{id}/{laneId}` | Returns same error; batch state unchanged |
| M4 | Assign lane to all-cancelled batch | dev | 1. Find or simulate a batch where all child orders are state 800. 2. Call `/assignStagingLane` | Returns error; batch state unchanged |
| M5 | Verify state not mutated | dev | After M2/M3: query `customerorder_batch` for the batch id | `state` column unchanged from its pre-test value |
| M6 | Web UI — error toast | dev | Perform M2 via web UI club screen | Error toast/message shown to user with the "finished or cancelled" message |
| M7 | Confirm HTTP 200 body parsed by UI | dev | Open browser devtools network tab during M6. Confirm the HTTP response is 200 but the UI still shows the error — i.e., the frontend is reading `errors[]` from the payload, not relying on HTTP status code alone | Error displayed in UI despite HTTP 200 status |

**SQL helper for M2/M4 setup (wms1-wineco-dev):**
```sql
-- Find a batch with all finished orders
SELECT cb.id, cb.state, COUNT(co.id) AS order_count
FROM customerorder_batch cb
JOIN customerorder co ON co.orderbatch_id = cb.id
WHERE cb.type = 'CLUB' AND cb.state < 700
GROUP BY cb.id, cb.state
HAVING COUNT(co.id) = COUNT(CASE WHEN co.state IN (700, 800) THEN 1 END)
LIMIT 10;
```

---

## 8. Rollout Plan

| Step | Action |
|------|--------|
| 1 | Create branch `task/SBDEV-2163` off `main` |
| 2 | Apply code change (§3.1) |
| 3 | Update the 2 existing `assignStagingLaneToOrderBatch` tests; add 4 new test cases (see §7) |
| 4 | Run `mvn test -Dtest=CustomerorderBatchServiceUnitTest` — all tests must pass |
| 5 | Run `mvn verify` (full suite) |
| 6 | Deploy to dev; run manual tests M1–M7 |
| 7 | Run `bash sbdocs/9-System/scripts/verify-SBDEV-2163.sh` — must report `Result: N pass, 0 fail` |
| 8 | PR to `main`; peer review |
| 9 | Merge and deploy |

---

## 9. Alternatives Considered

| Option | Description | Why Rejected |
|--------|-------------|--------------|
| **Guard on batch header state** | Check if `batch.state >= 700` and block | Rejected: the root cause is that `batch.state` lags behind order state — a batch stuck at 530 with all orders at FINISHED (700) would still pass a batch-state-only check. Order state is the authoritative source of truth for whether work is actually done. |
| **Auto-fix batch state on lane assignment** | Instead of blocking, auto-advance the batch to FINISHED if all orders are terminal | Rejected: silent state mutation without a BOL-close is incorrect operationally and bypasses the `closeBOL` finalization logic (OMS notification, pallet transfer, etc.). This would mask the stale-batch problem rather than surface it. |
| **Add guard in both controllers** | Duplicate the check in `assignStagingLane` and `activateBatch` | Rejected: violates DRY, and any future caller of `assignStagingLaneToOrderBatch` would bypass the guard. Single chokepoint at the service is more robust. |
| **Nightly job to auto-close stale batches** | A scheduled job finds batches with all-finished orders and advances them to state 700 | Valid complementary fix but out of scope for this ticket. Does not prevent users from triggering a lane reassignment in the window before the job runs. The guard is still needed. |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|----------|------------|
| 1 | Should a batch with **zero orders** also be blocked? | **Resolved — Yes.** The guard uses an explicit `batchOrders.isEmpty()` check before `allMatch`, blocking zero-order batches with a clear code path. A zero-order club batch has nothing to process and must not be assigned a lane. |
| 2 | Should a batch with **some cancelled + some active** orders be blocked? | **Resolved — No.** `allMatch` requires every order to be terminal. If at least one order is still active (e.g., PACKED=650), the guard passes. This is correct: partially shipped batches can still have work remaining. |
| 3 | Is a UI change needed to disable the button? | **Resolved — No for this ticket.** The error response already surfaces through the existing error toast in both UIs. A proactive UI disable (based on batch state or order state) would be a separate UX improvement and is out of scope. |
| 4 | Does `runClubLine` need a similar guard? | **Resolved — No.** `runClubLine` already checks `isEnoughStockOnStagingLane` which throws if there are no active orders. If all orders are FINISHED, there will be no stock on the staging lane and the run will fail on the stock check. However, if this becomes a concern a follow-up ticket can address it. |
| 5 | Does v2/wms2-api need the same fix? | **Out of scope for this plan.** v2 has the same club line flow (`CustomerorderBatchService.assignStagingLaneToOrderBatch` at v2:696). A v2 port should be tracked as a follow-on ticket or via `wms-v2-migrate`. |
| 6 | Is there a race between the guard read and a concurrent order finalization? | **Resolved — Mitigated.** `CustomerorderBatch` has `@Version` optimistic locking (`CustomerorderBatch.java:51`). Both controller endpoints wrap service calls in `OptimisticLockRetryTemplate.executeWithRetry` (`ClubLineController.java:93, 148`), which retries on `ObjectOptimisticLockingFailureException`. On retry, the guard re-reads live order state, so a concurrent finalization will be detected on the next attempt. |
| 7 | Are there other code paths that write `staginglane_id` (assign, not clear)? | **Resolved — No.** Audited all writes to `staginglane_id`: `CustomerorderBatchRepository.java:147` (`@Modifying` UPDATE) sets it to `NULL` only; `CustomerorderBatchService.unlinkStagingLaneFromOrderBatch` also sets to `null`. Only `assignStagingLaneToOrderBatch` writes a non-null value. Single chokepoint is confirmed. |
| 8 | Should there be a kill-switch to disable the guard in an emergency? | **Resolved — No, guard is always-on.** The guard is a pure read + early-exit with no schema dependency. If an emergency workaround is needed (e.g., ops must force-assign a lane to correct data corruption), it requires a code change or direct SQL. This is acceptable given the narrow, well-understood scope of the guard. |

---

## Implementation Status

- [x] Code change applied — guard added at top of `assignStagingLaneToOrderBatch` in `CustomerorderBatchService.java`
- [x] Unit tests added and passing — 2 existing tests updated + 4 new cases; `CustomerorderBatchServiceUnitTest`: 66 tests, 0 failures
- [ ] `mvn verify` passing — full suite has 5 pre-existing failures in `BillofladingServiceUnitTest` (4 NPEs in `closeBOL`) and `MobileMoveStockServiceUnitTest` (1 message-text mismatch in `selectDestination`); neither is related to this change
- [ ] Verify script result: `Result: _ pass, 0 fail`
- [ ] PR merged
- [ ] Branch: develop
- [ ] Commit SHA: 1715962
