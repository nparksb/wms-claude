# SBDEV-3605 — Critic review, round 1 (2026-09-30), independent of the Architect
VERDICT: ITERATE (4 High). Base origin/develop daf64d41; DEV: all 565 open orders are state 300.

## High
- H1: The max(0) mutant is masked by the `ownShare.signum() > 0` guard, so IT-5 and U-2 cannot go red. U-2's `any(BigDecimal.class)` and `anyString()` inside `never()` turn NeverMatcherNullBlindnessArchTest red. Fix: a same-SU test (amount 10, res 2, Y req 3, qty 8: accept vs `MsgUnitLoadStockAlreadyReserved`), or unit-test ownShareOfReservation directly. Use any()/nullable() inside every never().
- H2: U-4's never().findById contradicts `readReplenishOrder` → `replenishorderRepository.findById(mOrder.getId())` in the same transaction. If the stubs are MOVED, finish throws MsgCannotReadOrder. Fix: ADD the findByIdForUpdate stubs; assert with InOrder that the lock precedes findById and save.
- H3: The §7 #4 no-cycle claim is false across different orders. Multi-UL takes X → old B → scanned A; redirectSource(Y, A→B) takes locks ascending, A then B. Fix: resolve the scanned SU ids with an id-only query, then lock {old} ∪ scanned as one ascending set, each lock as a first touch.
- H4: Fix E's per-order loop inside UnitloadBusinessService.processTransfer → syncForMovedStockUnit → reassignOrCancel holds movedStock and then locks order 2. Multi-UL on order 2 (and the cron) take order 2 and then movedStock. That is ABBA. Fix: two phases — lock all orders ascending, reject if any is ≥ STARTED, then write. That also makes U-B1 achievable.

## Medium
- M1: Lock and stale failures return 409 (RestExceptionHandler handles `ObjectOptimisticLockingFailureException` and `PessimisticLockingFailureException` with HttpStatus.CONFLICT), not 500. Add a test that pins the 409.
- M2: Fix D breaks 4 isNull() pins: ReplenishmentOrderMaintenanceServiceUnitTest:628,:736 and ...ReassignTest:206,:309. The finder references to migrate are Reassign 9, SourceSyncServiceTest 11, SourceSyncServiceBranchTest 3, ReplenishorderServiceUnitTest 2, contract test 2.
- M3: D3 conflicts with P1 and no test pins it. Reword P1. Add IT-8: a MANUAL_ADJUSTMENT +10 on B with X req 5 releases 15. Get Nam's explicit yes.
- M4: The requested-based Cons cell overstates the harm. Leaks are stranded only "until an admin reconcile" (countStrandedReservationById), not forever.
- M5: Fix A narrows the accepted states from < FINISHED to ≤ PROCESSABLE. Cite the evidence: DEV has only state 300, and startOrder has 0 callers. Or reject only ≥ FINISHED.
- M6: Fix E is T3-shaped. Keep it with the H4 fix plus a concurrency IT, or split it out.

## Low
- L1: U-5 — save(template) is called twice, so the InOrder must pin which call it means.
- L2: OptionalSafetyArchTest is frozen and must be deliberately re-frozen; add it to §5.
- L3: IT-7's kill is attributable (the awaitOrderLockWait filter), but the mutant's described effect is wrong.
- L4: §7 #3's worst case must count locks, not ULs. The IT lock timeout is 10 s, so latch holds must exceed that.

## Verified OK
U-1, U-3, IT-1, IT-2, IT-4 and IT-6 mutants are observable. IT-3's arithmetic holds. createOrderFromTemplate and reserveExplicitStockForOrder take no extra locks.
