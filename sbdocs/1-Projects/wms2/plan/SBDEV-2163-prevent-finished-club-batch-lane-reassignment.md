---
title: "v2 — Prevent Reassigning Finished Club Batches to a Staging Lane"
ticket: "SBDEV-2163"
ticket_url: "https://app.clickup.com/t/868jev5g5"
type: feature
priority: high
status: implemented
project: [wms2]
version: v2
requester: Joseph Gero II
created: 2026-05-03
updated: 2026-05-03
last_verified: 2026-05-03
related:
  - "[[../../../1-Projects/wms1/plan/SBDEV-2163-prevent-finished-club-batch-lane-reassignment]]"
  - "[[../../../3-Resources/architecture/wms2-state-machine-catalog]]"
  - "[[../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - club
  - wms2
  - port
db_verified: true
---

# v2 — Prevent Reassigning Finished Club Batches to a Staging Lane

**Ticket:** [SBDEV-2163](https://app.clickup.com/t/868jev5g5)
**V1 source plan:** `sbdocs/1-Projects/wms1/plan/SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md`
**V2 target:** `v2/wms2-api`
**Status:** ready
**Date:** 2026-05-03

---

## 0. Affected Sites

| # | File:line | Construct | In-scope? | Phase |
|---|-----------|-----------|-----------|-------|
| 1 | `service/CustomerorderBatchService.java:769` | `assignStagingLaneToOrderBatch(Location, CustomerorderBatch)` — single write chokepoint | **Yes — primary change** | Phase 1 |
| 2 | `service/CustomerorderBatchService.java:~785` | New private helper `batchHasNoActiveOrders(Long)` | **Yes — extracted helper** | Phase 1 |
| 3 | `controller/ClubLineController.java:83–107` | `GET /v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}` — calls #1 | Yes — covered by guard at #1, no code change | — |
| 4 | `controller/ClubLineController.java:133–158` | `GET /v3/clubLine/activateBatch/{orderBatchId}/{locationId}` — calls #1 then `activateOrderBatch` | Yes — covered by guard at #1, no code change | — |
| 5 | `repo/jpa/CustomerorderRepository.java:38–39` | `findByOrderbatchId(Long)` — existing method reused | No change | — |
| 6 | `test/unit/service/CustomerorderBatchServiceUnitTest.java:396–434` | `AssignStagingLaneToOrderBatch` nested class | **Yes — update 2 existing + add 4 new tests** | Phase 1 |

---

## 1. Problem Statement

Club batches can remain open (state < 700) after all child orders are shipped and finished. Because `CustomerorderBatch.state` only advances to `FINISHED (700)` when `closeBOL` processes the batch, a stuck batch (e.g., at `ORDER_BATCH_CLUB_RUN_FINISHED = 530`) with all child orders at 700/800 can still be interacted with through the lane-assignment flow.

Two UI-accessible v2 endpoints allow re-assigning a staging lane:
- `GET /v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}` — sets batch state back to `525`
- `GET /v3/clubLine/activateBatch/{orderBatchId}/{locationId}` — sets batch state to `525` then `520`

Both funnel through the single chokepoint: `CustomerorderBatchService.assignStagingLaneToOrderBatch`.

---

## 2. Root Cause Analysis

`assignStagingLaneToOrderBatch` at v2:L769 checks only staging-lane availability (via `getAvailableStagingLanes`, which filters on batch header state `< ORDER_BATCH_CLUB_RUN_FINISHED`). It does not check child-order state. The batch header state can lag child-order state, so a batch stuck at `530` with all orders at `700` passes the availability check and gets its state written backward to `525`.

**Existing SQL guard (partial — `LocationRepository.java:38–47`):**
```sql
AND ob.state < :state  -- :state = ORDER_BATCH_CLUB_RUN_FINISHED (530)
```
This only blocks re-assignment if the batch header has already advanced to `≥530`. It does not protect the window where header state is `530` but child orders have all finished.

The fix uses child-order aggregate state as the authoritative source of truth.

---

## 3. Design / Proposed Fix

### 3.1 Guard in `assignStagingLaneToOrderBatch` (via private helper)

**Problem:** No guard against child-order completeness before writing batch state backward to `525`.

**Solution:** Add a private helper `batchHasNoActiveOrders(Long batchId)` and call it at the top of `assignStagingLaneToOrderBatch`. Throws `BusinessException` if all child orders are terminal (FINISHED=700, CANCELED=800) or the order list is empty.

**Why a private helper (not inline):** The same child-aggregate-terminal check will be needed at `cancelBatch` (L221) and potentially other call sites. Extracting it now prevents three future copies of the `Integer.valueOf().equals()` lambda. The idiom is already proven at `CustomerorderBatchService.java:168` (`orders.removeIf(o -> Integer.valueOf(WmsConstants.State.CANCELED).equals(o.getState()))`).

**Why order state, not batch state:** Batch state can be stale (stuck at `530` with all orders at `700`). See §9 Alternatives.

**Why this method, not the controllers:** Both affected endpoints call this single chokepoint. Guard here is un-bypassable by any future caller.

**Why `batchOrders.isEmpty()` is also blocked:** A zero-order batch has nothing to process and must not be assigned a lane. The `isEmpty()` branch is explicit (vs. relying on `allMatch`'s vacuous-true semantics).

**Before (v2 `CustomerorderBatchService.java:768–782`):**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void assignStagingLaneToOrderBatch(Location stagingLane, CustomerorderBatch orderBatch) throws BusinessException {
    LOG.debug("start with orderBatch={} and stagingLane={}", orderBatch, stagingLane);

    List<Location> availableStagingLanes = getAvailableStagingLanes(orderBatch.getId());

    if (availableStagingLanes.stream().noneMatch(lane -> lane.getId().equals(stagingLane.getId()))) {
        throw new BusinessException("staging lane is not available anymore. refresh and try again.");
    }

    orderBatch.setStaginglaneId(stagingLane.getId());
    orderBatch.setState(WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED);
    customerorderBatchRepository.save(orderBatch);
    LOG.debug("end with orderBatch={} and stagingLane={}", orderBatch, stagingLane);
}
```

**After:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void assignStagingLaneToOrderBatch(Location stagingLane, CustomerorderBatch orderBatch) throws BusinessException {
    LOG.debug("start with orderBatch={} and stagingLane={}", orderBatch, stagingLane);

    if (batchHasNoActiveOrders(orderBatch.getId())) {
        LOG.warn("assignStagingLaneToOrderBatch: blocked — batch {} has no active orders (all finished or cancelled)", orderBatch.getId());
        throw new BusinessException("Club batch is finished or cancelled — cannot assign a staging lane.");
    }

    List<Location> availableStagingLanes = getAvailableStagingLanes(orderBatch.getId());

    if (availableStagingLanes.stream().noneMatch(lane -> lane.getId().equals(stagingLane.getId()))) {
        throw new BusinessException("staging lane is not available anymore. refresh and try again.");
    }

    orderBatch.setStaginglaneId(stagingLane.getId());
    orderBatch.setState(WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED);
    customerorderBatchRepository.save(orderBatch);
    LOG.debug("end with orderBatch={} and stagingLane={}", orderBatch, stagingLane);
}

/**
 * Returns true if the batch has no active (non-terminal) orders.
 * An empty order list is also considered terminal — a zero-order batch must not be lane-assigned.
 */
private boolean batchHasNoActiveOrders(Long batchId) {
    List<Customerorder> batchOrders = customerorderRepository.findByOrderbatchId(batchId);
    return batchOrders.isEmpty() || batchOrders.stream().allMatch(o -> {
        Integer state = o.getState();
        return Integer.valueOf(WmsConstants.State.FINISHED).equals(state)
            || Integer.valueOf(WmsConstants.State.CANCELED).equals(state);
    });
}
```

**Helper placement:** Insert immediately after the closing `}` of `assignStagingLaneToOrderBatch` (currently L782), before `unlinkStagingLaneFromOrderBatch` (currently L784).

**`@Transactional` status:** Already present at L768 with `value = "tenantTransactionManager"` — no change needed. The guard read (`findByOrderbatchId`) and the downstream save run in the same transaction snapshot, making a stale read within the same call impossible.

**Race condition analysis:** `CustomerorderBatch` has `@Version` (optimistic locking). In v2, neither `ClubLineController.assignStagingLane` (L83–107) nor `activateBatch` (L133–158) wraps the service call in `OptimisticLockRetryTemplate.executeWithRetry` — unlike v1. A concurrent order finalization between the guard read and the batch save would surface as `ObjectOptimisticLockingFailureException`, which the controller's `catch (BusinessException e)` at L95/L146 does NOT catch. This would return HTTP 500 rather than a transparent retry. This is pre-existing v2 behavior (not introduced by this change), and is an edge case in practice. Documented in §10 as a follow-up improvement.

**Error propagation:** `BusinessException` is caught at `ClubLineController.java:95` and `L147` and returned as HTTP 200 with:
```json
{ "errors": [{ "type": "Runtime Error", "message": "Club batch is finished or cancelled — cannot assign a staging lane." }] }
```
This is v2-identical behavior to the existing "staging lane is not available anymore" path. No UI change needed.

---

## 4. V1 → V2 Applicability Analysis

| V1 Fix | Description | V2 Verdict | Rationale |
|---|---|---|---|
| Guard in `assignStagingLaneToOrderBatch` | Throw if all child orders terminal | **Needed** | v2 method at L769 has no terminal-order guard — confirmed by code read |

### V2 adaptation differences from v1

| Aspect | v1 | v2 | Change |
|---|---|---|---|
| Method signature | `(Long stagingLaneId, Long orderBatchId)` | `(Location stagingLane, CustomerorderBatch orderBatch)` | Guard uses `orderBatch.getId()` not raw `Long` |
| `@Transactional` | Not annotated (bare service call) | Already `@Transactional(tenantTransactionManager)` at L768 | No TM work needed |
| Lane availability check | `!availableStagingLanes.contains(stagingLane)` | `noneMatch(lane -> lane.getId().equals(...))` | Already ID-based in v2; no change |
| Controller retry wrapper | `OptimisticLockRetryTemplate.executeWithRetry` present | **Absent** in v2 controller | Documented as follow-up (§10 Q6) |
| Helper extraction | Inline lambda | Extracted to `batchHasNoActiveOrders(Long)` | Architect synthesis — enables reuse at `cancelBatch` L221 |

---

## 5. V2-Specific Adaptation Notes

1. **Transaction manager:** `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` already present at L768 — correct.
2. **Jakarta namespace:** No new imports needed; `findByOrderbatchId` and `WmsConstants.State` constants already in scope.
3. **Entity equality:** `AbstractBaseEntity.equals()` is ID-based in v2. The `noneMatch(lane -> lane.getId().equals(...))` lane-check already uses correct v2 equality — no change.
4. **Constructor injection:** `customerorderRepository` is already constructor-injected in `CustomerorderBatchService` — no injection changes needed.
5. **State constant types:** `WmsConstants.State.*` are `int` primitives; `Customerorder.getState()` returns `Integer` (boxed). Null-safe comparison: `Integer.valueOf(WmsConstants.State.FINISHED).equals(o.getState())` — same idiom already at `CustomerorderBatchService.java:168`.
6. **Mockito:** v2 uses Mockito 5.x with `@Nested`/`@DisplayName` test style — match existing class conventions.

---

## 6. Test Plan

### Test class: `CustomerorderBatchServiceUnitTest$AssignStagingLaneToOrderBatch` (L396–434)

**2 existing tests to update** (add active-order stub so guard passes through):

| Test | Required update |
|---|---|
| `linksStagingLaneToBatch` (L402) | Add `when(customerorderRepository.findByOrderbatchId(1L)).thenReturn(Collections.singletonList(activeOrder))` where `activeOrder.setState(WmsConstants.State.STARTED)` |
| `throwsWhenLaneNotAvailable` (L420) | Same stub — guard must pass before lane-availability check fires; without stub, guard throws "finished or cancelled" instead of "not available", producing a false-green test with the wrong message |

**4 new tests** (insert inside the existing `AssignStagingLaneToOrderBatch` nested class, after `throwsWhenLaneNotAvailable`):

```java
@Test
@DisplayName("should throw when all orders are finished")
void throwsWhenAllOrdersFinished() throws BusinessException {
    // Arrange
    Customerorder finishedOrder = new Customerorder();
    finishedOrder.setId(10L);
    finishedOrder.setState(WmsConstants.State.FINISHED);
    when(customerorderRepository.findByOrderbatchId(1L))
        .thenReturn(Collections.singletonList(finishedOrder));

    // Act + Assert
    assertThatThrownBy(() -> customerorderBatchService.assignStagingLaneToOrderBatch(stagingLane, testBatch))
        .isInstanceOf(BusinessException.class)
        .hasMessageContaining("finished or cancelled");
    verify(customerorderBatchRepository, never()).save(any());
}

@Test
@DisplayName("should throw when all orders are cancelled")
void throwsWhenAllOrdersCancelled() throws BusinessException {
    Customerorder cancelledOrder = new Customerorder();
    cancelledOrder.setId(11L);
    cancelledOrder.setState(WmsConstants.State.CANCELED);
    when(customerorderRepository.findByOrderbatchId(1L))
        .thenReturn(Collections.singletonList(cancelledOrder));

    assertThatThrownBy(() -> customerorderBatchService.assignStagingLaneToOrderBatch(stagingLane, testBatch))
        .isInstanceOf(BusinessException.class)
        .hasMessageContaining("finished or cancelled");
    verify(customerorderBatchRepository, never()).save(any());
}

@Test
@DisplayName("should throw when batch has no orders")
void throwsWhenBatchHasNoOrders() throws BusinessException {
    when(customerorderRepository.findByOrderbatchId(1L)).thenReturn(Collections.emptyList());

    assertThatThrownBy(() -> customerorderBatchService.assignStagingLaneToOrderBatch(stagingLane, testBatch))
        .isInstanceOf(BusinessException.class)
        .hasMessageContaining("finished or cancelled");
    verify(customerorderBatchRepository, never()).save(any());
}

@Test
@DisplayName("should allow assignment when mixed states include active order")
void allowsAssignmentWhenMixedStatesIncludeActive() throws BusinessException {
    // One PACKED (active) + one FINISHED (terminal) → guard passes
    Customerorder activeOrder = new Customerorder();
    activeOrder.setId(12L);
    activeOrder.setState(WmsConstants.State.PACKED);
    Customerorder finishedOrder = new Customerorder();
    finishedOrder.setId(13L);
    finishedOrder.setState(WmsConstants.State.FINISHED);
    when(customerorderRepository.findByOrderbatchId(1L))
        .thenReturn(Arrays.asList(activeOrder, finishedOrder));
    when(locationRepository.getAvailableStagingLanes(1L, WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED))
        .thenReturn(Collections.singletonList(stagingLane));

    // Act — should not throw
    customerorderBatchService.assignStagingLaneToOrderBatch(stagingLane, testBatch);

    verify(customerorderBatchRepository).save(testBatch);
}
```

> **Note:** `stagingLane` must be in scope. The existing `AssignStagingLaneToOrderBatch` class sets it up as a `Location` with `id=10L` in the arrange section of `linksStagingLaneToBatch`. If no `@BeforeEach` initializes it at class level, add one (or declare it as a local in each test).

### Manual test plan

| # | Scenario | Environment | Steps | Expected Result |
|---|----------|-------------|-------|-----------------|
| M1 | Assign lane to active batch | dev | 1. Find a club batch with at least one order at state < 700. 2. `GET /v3/clubLine/assignStagingLane/{id}/{laneId}` with tenant headers | Returns `ASSIGNED STAGING LANE` success |
| M2 | Assign lane to finished batch | dev | 1. Find a club batch whose ALL child orders are state 700. 2. Call `/assignStagingLane` | Returns `{"errors":[{"type":"Runtime Error","message":"Club batch is finished or cancelled — cannot assign a staging lane."}]}` |
| M3 | Activate finished batch | dev | 1. Same finished batch as M2. 2. Call `/activateBatch/{id}/{laneId}` | Returns same error; batch state unchanged |
| M4 | Assign lane to all-cancelled batch | dev | 1. Batch with all orders at state 800. 2. Call `/assignStagingLane` | Same error; state unchanged |
| M5 | Verify state not mutated | dev | After M2/M3: `SELECT state FROM customerorder_batch WHERE id = {id}` | State unchanged from pre-test value |
| M6 | Mixed states — active + finished | dev | 1. Batch with one PACKED + one FINISHED order. 2. Call `/assignStagingLane` | Returns success; batch state = 525 |
| M7 | Web UI — error toast | dev | Perform M2 via web UI club screen | Error toast shown with "finished or cancelled" message |

**SQL helper for M2/M4 setup (wms2 tenant DB):**
```sql
-- Find a v2 batch with all finished orders
SELECT cb.id, cb.state, COUNT(co.id) AS order_count
FROM customerorder_batch cb
JOIN customerorder co ON co.orderbatch_id = cb.id
WHERE cb.type = 'CLUB' AND cb.state < 700
GROUP BY cb.id, cb.state
HAVING COUNT(co.id) = COUNT(CASE WHEN co.state IN (700, 800) THEN 1 END)
LIMIT 10;
```

### Test execution (fill in after running)

| Command | Result |
|---|---|
| `mvn test -Dtest=CustomerorderBatchServiceUnitTest` | — |
| `mvn test` (full suite) | — |

---

## 7. Horizontal Scalability Validation

| Concern | Verdict | Notes |
|---|---|---|
| In-JVM state (local cache, static, ThreadLocal) | N/A | Guard reads DB per-request, no in-JVM state introduced |
| Connection pool math | N/A | One extra `findByOrderbatchId` per lane-assign call; already called 8+ times elsewhere in this service; negligible connection cost |
| Scheduled jobs | N/A | Change is in a request-scoped service method, not a scheduled job |
| Long transactions | N/A | Guard adds one lightweight read inside the existing short transaction; no new lock acquisitions |
| Request affinity | N/A | Stateless per-request guard; no affinity requirement |
| Retry / idempotency | **Note** | v2 controller has no `OptimisticLockRetryTemplate` wrapper (confirmed at `ClubLineController.java:91–97, L141–148`). Concurrent finalization race would surface as HTTP 500, not a transparent retry. Pre-existing v2 behavior — see §10 Q6 for follow-up. |
| Tenant context | N/A | `tenantTransactionManager` at L768; tenant context set before controller entry |
| Distributed lock correctness | N/A | No distributed lock; `@Version` optimistic locking on `CustomerorderBatch` entity |
| Cache invalidation | N/A | No cache on `findByOrderbatchId`; result is read-only within the transaction |
| External notifications | N/A | Guard throws before any save; no OMS/Keycloak/Zipkin interaction on the blocked path |

---

## 8. Notes

- **Architectural follow-up:** `LocationRepository.getAvailableStagingLanes` (L38–47) filters on batch header state (`ob.state < :state`), while this guard filters on child-order aggregate state. These two layers can disagree on the same batch (e.g., batch at state 530 with all orders at 700 passes the SQL filter but fails the Java guard). Reconciling them is a follow-up item — see §10 Q7.
- **`cancelBatch` reuse opportunity:** `CustomerorderBatchService.cancelBatch` (L221) performs a similar "fetch child orders + check state" pattern. Once `batchHasNoActiveOrders` is in place, `cancelBatch` can use it in a future refactor.
- **v2 note — no `@Transactional` gap in v1:** The v1 method had no `@Transactional` at all; v2 already has `tenantTransactionManager` at L768. The guard read is inside the same transaction snapshot as the save — no stale-read risk within the call.

---

## 5.1 Prerequisites

| Prerequisite | Status | Notes |
|---|---|---|
| DB schema change | N/A | No schema change |
| Flyway migration | N/A | No migration needed |
| System property / feature flag | N/A | Guard is always-on; no toggle |
| Deploy-order dependency | N/A | Single-service change |
| Data backfill | N/A | Guard reads live order state |
| External system coordination | N/A | OMS not affected; BOL close flow unchanged |
| Monitoring / alerting | N/A | No new metrics |

---

## 5.2 Implementation Checklist

1. Read `wms2-state-machine-catalog.md` §club-batch and `wms2-transaction-osiv-boundary-map.md` §assignStagingLane before editing.
2. Insert `batchHasNoActiveOrders(Long)` private helper after `assignStagingLaneToOrderBatch` closing brace (after L782, before L784 `unlinkStagingLaneFromOrderBatch`).
3. Add `if (batchHasNoActiveOrders(orderBatch.getId()))` guard as first statement after opening `LOG.debug` in `assignStagingLaneToOrderBatch`.
4. Update `linksStagingLaneToBatch` test — add active-order stub.
5. Update `throwsWhenLaneNotAvailable` test — add active-order stub.
6. Add 4 new tests inside `AssignStagingLaneToOrderBatch` nested class.
7. Run `mvn test -Dtest=CustomerorderBatchServiceUnitTest` — all tests must pass.
8. Run `mvn test` (full suite) — 0 new failures.
9. Deploy to dev; run manual tests M1–M7.
10. Fill in §Implementation Status below.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance criteria (wms-tdd-gate consumable)

| ID | Test method | File | Asserts |
|---|---|---|---|
| A1 | `throwsWhenAllOrdersFinished` | `CustomerorderBatchServiceUnitTest$AssignStagingLaneToOrderBatch` | FINISHED order → `BusinessException` contains "finished or cancelled"; `save()` never called |
| A2 | `throwsWhenAllOrdersCancelled` | same | CANCELED order → same exception |
| A3 | `throwsWhenBatchHasNoOrders` | same | Empty list → same exception |
| A4 | `allowsAssignmentWhenMixedStatesIncludeActive` | same | PACKED + FINISHED → no exception; `save()` called once |

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | Standard | 1 production method + 1 private helper + 4 new tests + 2 updated tests |
| Pre-draft step | none | v1 plan exists; this is a translation |
| Implementation shape | executor | Mechanical, scope-bounded |
| Verification step | verifier | Run targeted test + full suite |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|----------|------------|
| 1 | Should a zero-order batch be blocked? | **Yes.** `batchOrders.isEmpty()` is an explicit early-return. A zero-order club batch has nothing to process and must not be lane-assigned. |
| 2 | Should a batch with some cancelled + some active orders be blocked? | **No.** `allMatch` requires every order to be terminal. One active order (e.g., PACKED=650) lets the guard pass. |
| 3 | Why keep "finished or cancelled" in the error message rather than "no active orders"? | **v1 parity.** The v1 message is already surfaced in both UIs and any verification scripts. Changing the substring would require auditing UI error-toast matchers in `wms2-web-ui` and `wms2-mobile-ui`. Left as v1 wording; the helper name `batchHasNoActiveOrders` documents the empty-list intent at code level. |
| 4 | Should the UI have a proactive disable button? | **Out of scope.** Error toast handles the blocked case. A UI disable is a separate UX improvement. |
| 5 | Does `runClubLine` need the same guard? | **No.** `runClubLine` already fails on the stock check if staging lane has no stock. |
| 6 | v2 controller has no `OptimisticLockRetryTemplate` — does this matter? | **Documented, not blocking.** Concurrent finalization race surfaces as HTTP 500 (not a retry). This is pre-existing v2 behavior across the club controller. Follow-up: add `OptimisticLockRetryTemplate` wrapping to `assignStagingLane` and `activateBatch` endpoints in a separate PR. |
| 7 | `LocationRepository.getAvailableStagingLanes` checks batch header state; this guard checks child-order state — two sources of truth? | **Documented, follow-up required.** The SQL filter (batch state `< 530`) and the Java guard (child-order aggregate) can disagree. A batch at state `530` with all orders at `700` passes the SQL filter but fails the Java guard. The Java guard provides the correct safety net. Follow-up: update `getAvailableStagingLanes` to filter by child-order terminality (or add a `IS TERMINAL` derived query) so SQL and Java agree. |
| 8 | Are there other code paths that write a non-null `staginglane_id` (i.e., assign, not clear)? | **No.** `CustomerorderBatchRepository` only clears `staginglane_id` (`@Modifying` UPDATE sets to NULL). `unlinkStagingLaneFromOrderBatch` also sets to null. Only `assignStagingLaneToOrderBatch` writes a non-null value. Single chokepoint confirmed. |

---

## 11. Alternatives Considered

| Option | Description | Why Rejected |
|---|---|---|
| Guard on batch header state | Check `orderBatch.getState() >= 700` | Root cause is that batch state lags child-order state. A batch stuck at `530` with all orders at `700` would still pass this check. |
| Auto-advance batch to FINISHED | Instead of blocking, advance batch state when guard triggers | Bypasses `closeBOL` OMS notification / pallet-transfer flow. Silent state mutation without BOL-close is operationally incorrect. |
| Guard in both controllers | Duplicate check in `assignStagingLane` and `activateBatch` | DRY violation; future callers bypass the guard. Single service chokepoint is more robust. |
| Fix the state-machine root cause | Auto-close stale batches when last order terminates | Valid complementary fix (see SBDEV-2164). Does not prevent the window before the job runs. Guard is still needed as the immediate protective layer. |

---

## Implementation Status

- [x] Code change applied — `batchHasNoActiveOrders` helper + guard inserted in `assignStagingLaneToOrderBatch`
- [x] Unit tests added / updated — 2 existing `@BeforeEach` updated (active-order stub) + 4 new gate tests; `CustomerorderBatchServiceUnitTest$AssignStagingLaneToOrderBatch`: all 6 pass
- [x] `mvn test` passing — 3815 pass, 0 fail, 65 skipped
- [ ] Manual tests M1–M7 verified on dev
- [x] v2 commit SHA: `049dde0`
- [x] Branch: develop

### Changelog

| Date | Change |
|---|---|
| 2026-05-03 | Initial v2 plan — ported from v1 `1715962` via ralplan consensus (Architect + Critic review). Key v2 adaptations: method signature uses entities not IDs; `@Transactional(tenantTransactionManager)` already present; helper extracted (`batchHasNoActiveOrders`); v2 controller has no retry wrapper (documented as follow-up). |
