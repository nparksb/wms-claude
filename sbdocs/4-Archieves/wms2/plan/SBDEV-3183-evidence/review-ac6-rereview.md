---
ticket: SBDEV-3183
type: review
subject: commit 2910a9aa — AC-6 fixes for F-1..F-5, deletes TransferOrderService.activateTransferOrder
reviewed: 2026-10-20
verdict: APPROVE
---

# SBDEV-3183 AC-6: re-review of 2910a9aa

Read-only, via `git show` / `git grep` at `2910a9aa` (worktree HEAD is `2910a9aa`, clean). Maven was not run (a suite is running in that worktree). Findings are static; mutation claims were not re-executed.

## Verdict: APPROVE

No CRITICAL or HIGH findings. Two LOW notes.

## 1. Does the deleted method have a caller?

**No.** `git grep activateTransferOrder 2910a9aa` outside `*.md`:
- `src/main`: only `TransfersController.java:155-156`. That is the MVC handler. It calls `transferOrderService.activateAndAssignTransferLane(...)` at `:168`, and it is the only route mapping (`@GetMapping "/activateTransferOrder/{customerOrderId}/{locationId}"`). No route maps to the service method, because the service is not a controller.
- `src/test/java` (all remaining hits are comments, the HTTP path string, or the controller handler):
  - `ActivateTransferAtomicityIT.java:247,281`
  - `Sbdev3017TrancheGateContextTest.java:423,480`
  - `CustomerorderTransferLaneSdrWriteContextTest.java:24`
  - `MutatingGetGateUnitTest.java:119`
  - `TransfersControllerUnitTest.java:209,220,228,233,240`
  No call to `transferOrderService.activateTransferOrder(` or `TransferOrderService::activateTransferOrder` remains.
- Spring config and resources: no hits. `src/test/resources/archunit_store/*` has no entry for the method.
- Reflection or string references: only the URL path strings above. Nothing uses `getMethod("activateTransferOrder")`.
- Docs: `docs/plan/completed/CONCURRENCY_FIX_PLAN.md:267`, `DEVELOP-TO-V2-MERGE-PLAN.md:188` and `TRANSFER_ORDER_PERFORMANCE_PLAN.md:62` still name the old method (see N-1).
- Sibling UIs: `wms2-web-ui` (origin/develop) calls the Vuex action `outbound/transfer/activateTransferOrder` and the HTTP route `/v3/transfers/activateTransferOrder/...`, which is the controller. `wms2-mobile-ui` has no hit. The Cypress helper uses the route.

The commit's claim that it "had no caller in src/main" is true. The same-named controller handler is unaffected.

## 2. Is the moved never() guard correct Mockito?

**Yes.** `LocationRepository.getAvailableTransferLanes(Long customerOrderId, int state)` (`:142`).
- `verify(locationRepository, never()).getAvailableTransferLanes(any(), anyInt())`: `any()` for the boxed `Long` yields null and is legal. `anyInt()` is used for the primitive `int`. There is no NPE on unboxing.
- It is the same expression already used at `TransferOrderServiceUnitTest:237` for `assignTransferLaneToTransferOrder`.
- The guard now sits in `ActivateAndAssignTransferLane.activateAndAssignTransferLane_availableLane_setsState510AndLane_singleSave` (`:332-348`). The test exercises the live method, and the live method does call `getAvailableTransferLanesForUpdate` (`TransferOrderService:~147`).
- It is not vacuous. If the live method switched to the unlocked query, the `ForUpdate` stub would not match and the method would see an empty list. The test would then fail on `verify(...ForUpdate)` and on the `never()` guard.
- `anyInt`, `any` and `FINISHED` are still imported, and `CUSTOMER_ORDER_ACTIVATED` is still used (`:285,303,365`).
- The deleted unit tests are covered by the live method's tests:
  - happy path: `activateAndAssignTransferLane_availableLane_...`
  - lane not available: `activateAndAssignTransferLane_laneNotAvailable_throws_noSaveNoStateChange`, which also asserts no save

## 3. Does anything in the controller test now pass vacuously?

**No.** In `TransfersControllerUnitTest:228-243`:
- The positive `verify(transferOrderService).activateAndAssignTransferLane(...)` still pins that the route calls the atomic method exactly once.
- The remaining `never().assignTransferLaneToTransferOrder(any(), any())` is a real guard. The method is live, the params are objects, and `any()` is fine.
- The removed `never().activateTransferOrder(...)` is enforced by the compiler. It cannot be reintroduced silently. If someone re-adds the method and wires the controller to it, the positive verify fails.
- The other test in that nested class (`shouldReturnErrorWhenBusinessException`) is unchanged.

## 4. Disposition of F-1..F-5

| ID | Claimed | Accurate? | Evidence |
|---|---|---|---|
| F-1 | `LocationRepository` comment names the live callers | **Yes** | `:146` now reads `assignTransferLaneToTransferOrder / activateAndAssignTransferLane`. No remaining `activateTransferOrder` in `src/main` other than the controller handler. |
| F-2 | Delete the dead method and its tests | **Yes** | `TransferOrderService` -18 lines. Unit tests deleted: nested `ActivateTransferOrder` (2 tests) and `throwsWhenActivatingOrderWithoutAvailableLanes`. See sections 1-3. |
| F-3 | Import `catchThrowable` and `BusinessException` | **Yes** | Both imports added. The 4 fully qualified uses are replaced. |
| F-4 | No change, because `getKey()` would not distinguish the copies | **Yes** | `BusinessException(String)` (`BusinessException.java`, the single-arg constructor) sets `key = "placeholder"` and `parameter = {message}` for every call. All three copies passed the identical string, so `getKey()` is `"placeholder"` and the parameter is the same text in each. The reason is true, and in fact stronger: `getKey()` can never tell any two `BusinessException(String)` throws apart. The commit's "each assertion names its method" is right (the `.as()` text names the method). |
| F-5 | Reword the "binds nothing" messages | **Yes** | Both messages now read "the refusal came before any write: nothing bound to order 2". The javadoc adds "pin the refusal's position, not a rollback". Accurate: both methods throw before `setTransferlaneId`. |

## 5. New false claims in comments / commit message

None that are false. The checked ones:
- "had no caller in src/main": true.
- "held a third copy of the held-lane refusal": true (it had the same `noneMatch` + throw).
- "saved an order at 505 with a lane: the stranded shape 260629 removed": true, it set `transferlaneId` and `CUSTOMER_ORDER_ACTIVATED` in one save.
- "killed: switching the live method to getAvailableTransferLanes reds it": consistent with the code (section 2). I did not re-run it.
- "The controller test's never().activateTransferOrder line is now enforced by the compiler": true.
- The IT javadoc: "A third copy ... was deleted in the same change": true.

## Findings

| ID | Sev | Conf | Where | Note | Fix |
|---|---|---|---|---|---|
| N-1 | LOW | HIGH | `docs/plan/completed/CONCURRENCY_FIX_PLAN.md:267`, `DEVELOP-TO-V2-MERGE-PLAN.md:188`, `TRANSFER_ORDER_PERFORMANCE_PLAN.md:62` | Completed historical plans still list `TransferOrderService.activateTransferOrder()`. They are history, not a live claim. `TRANSFER_ORDER_PERFORMANCE_PLAN:62` maps the route to the deleted service method, which a reader may take as current. | Optional: leave as is (completed plans), or add a one-line "removed in SBDEV-3183" note. Also check `sbdocs/3-Resources` for the method name (not searched here, outside this repo). |
| N-2 | LOW | MEDIUM | `TransfersControllerUnitTest:209-243` | The test name and `@DisplayName` still say "not the two legacy calls", but the "two calls" are now one live method and one deleted one. The comment explains it, so only the name lags. | Cosmetic. No action required. |

## Open questions

None.

## Positive observations

- Deleting the dead third copy removes the only non-atomic activate shape (505 with a lane), instead of pinning it with a test.
- The guard was moved to the live method instead of being dropped, and it is the same `any()`/`anyInt()` form used elsewhere in the class.
- The commit message states the F-4 non-change and its reason, and that reason holds.
