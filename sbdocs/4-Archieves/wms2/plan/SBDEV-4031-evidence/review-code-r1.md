---
lane: code-reviewer (Phase 3b round 1), opus
head: 85daa64b
verdict: APPROVE (1 Medium, 7 Low)
saved_by: main session, summary of the lane's reply
---
## Medium

**M1. A1's late order→F lock is justified by a false reason.**
- The comment claims nothing else locks a null-destination order after F. That is wrong: R3 (`assignFixedDestination`) and `recalculateForItem` both take F → O on null-destination orders.
- It is safe today only because `detach` commits in the same transaction as the FLA delete. A new FLA committed in that window can still produce a 40P01.
- The hint is load-bearing, not an optimisation. I08 (hint removed) creates a real cycle with `recalculateForItem`.
- **Decision (Nam, 2026-11-06): option "skip align".** When the hint missed and the destination is null under the order lock, do not lock F. Skip alignment for this pass (`assignment = null`). R3 or the next `recalculateForItem` aligns it under F → O. This removes the O → F edge.

## Low

| ID | Fix |
|---|---|
| L1 | Reword commit 91860679 to drop "(WIP)". |
| L2 | Remove the dead `ReplenishorderService.itemdataRepository` field, its constructor parameter, and the matching unit-test construction. |
| L3 | Relabel `ReplenishOrderJob` :825 and :924 from "optimistic lock exception" to "lock conflict occurred". |
| L4 | Rename `flaLocked` to `flaLockAttempted`, or add a comment. Likely moot after the M1 rework. |
| L5 | Add a per-order unit test (`recalculateOrder` direct or `recalculateOpenOrders(true)`). Under the M1 decision it asserts: no `lockIdByItemdataId` after `findByIdForUpdate`, and the destination stays null. |
| L6 | `ReplenishorderServiceUnitTest`: in `shouldSkipOrdersWithoutFixedAssignment`, stub `lockIdByItemdataId` empty. Rename `handlesRecalculateWhenAssignedLocationNotFound` to `...WhenFlaInactiveUnderLock`, then assert the destination is null and add InOrder lock → read. |
| L7 | Change the `move_refusesWhenAnOrderAlreadyTargetsTheDestination` DisplayName to "no order locked, nothing moved", and add `verify(locationRepository).lockById(2L)`. |
