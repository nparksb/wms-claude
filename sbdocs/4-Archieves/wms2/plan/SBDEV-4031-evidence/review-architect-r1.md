---
lane: architect (ralplan round 1, independent of the critic)
snapshot: plan-snapshot-r1.md sha1 00f40453
verified_against: origin/develop d6424491 (only SBDEV-4032 CORS/ETag since 05f962b3)
saved_by: main session, summary of the lane's reply (architect agents cannot write files)
---
# Architect review, round 1

The core design holds up: lock the FLA row first at C0, in both deletes and at the recalc entry points. `delete(Long)` with MANDATORY and no rollbackFor is confirmed correct, and nothing can self-deadlock across REQUIRES_NEW. The scalar @Lock renders as `FOR NO KEY UPDATE` (LockReads:39-44, measured by StockunitSkipLockedIT). That still conflicts with a DELETE and with the key-column UPDATE in move. The UNIQUE constraints come from Flyway V2.2.00:3712-3764, so they exist in every tenant. Re-point is semantically sound.

- **F1 HIGH: move() lock order.** CODE_MOVE_FIX_ASSIGNMENT is classed BLOCK_REALIGN, so `transferUnitLoadToLocation` locks the owning Pickingorders (Hook A, UnitloadBusinessService:237-239) and then the destination location (:245-248). Every BLOCK_REALIGN transfer locks Pickingorder, then location, then the holder orders (via syncForMovedStockUnit and MovedStockUnitHolders.lockForMove). Fix F as written locks F, then O, then Pickingorder, so a cycle (ABBA-10b) appears whenever one pick order has lines on both the flowbin SU and O's source pallet S. **Fix:** in move, right after the F lock, call `pickLineRealignmentService.lockOwningPickingorders(collectStockUnitIdsForUnitloadTree(flaUL))`, then `locationRepository.lockById(destinationId)`, then lock the orders ascending, then transfer. Resulting order: F → P → L′ → O. Add an IT where move is parked after its order locks while a concurrent CODE_TRANSFER moves S.
- **F2 MED: R3 catch.** The catch at ReplenishOrderJob:907-912 handles optimistic-lock failures only, so a pessimistic-lock failure from R3 aborts the rest of the tick. Add PessimisticLockingFailureException there; better, run one REQUIRES_NEW per order.
- **F3 MED: three new lock calls have no mutation kill.** Add AC-4c (recalculateForItem parked after lockIdByItemdataId, B asserted blocked by A's pid, no orphan), plus the same for per-order recalculateOrder and for R3.
- **F4 MED: regression list.** FixLocationAssignmentServiceIT (class-level tenant tx) saves an FLA and then calls move or delete in the same tx at :148, :221, :369, :565. That trips LockReadRail, which is registered for every test context. Reseed via committed TransactionTemplate plus NOT_SUPPORTED (the AdjustCommitted pattern, :392-405). Also update about 9 FixLocationAssignmentServiceUnitTest delete(1L) cases, and refresh the archunit store entry 5fb3fee0…:6 (delete Optional.get).
- **F5 LOW: advisory-lock rejection.** The stated reason is wrong: advisory locks are visible in pg_blocking_pids. The real reasons: no tenant-tx advisory helper exists, and it loses the free "row gone/moved → empty" result.
- **F6 LOW.** The F lock only narrows the checkRemovable staleness (finding F4); @Version still fences it.
- **F7 LOW.** Say `FOR NO KEY UPDATE`, and cite the Flyway source for uniqueness.
- **F8 LOW.** alignDestination: when findActiveLocationIdByItemdataId is empty, set assignment to null for the rest of the recalc (resolveUpperBound at :368 still reads ctx).
- **F9 LOW, optional.** Widen the :754 catch to a final catch (Exception e), as :832 already does, so an UnexpectedRollbackException from sendStockUnitToNirvana's FacadeException is caught.
- **F10 LOW.** Name ReplenishmentMaintenanceCallSiteArchTest:45-46 as the transitive ABBA-5 fence alongside AC-8b. recalculateForItem has 3 callers, not 4.

**Steelman antithesis.** Ship a narrow fix (C0 + D1 + D2 + D3) for the one observed PRD orphan. Split recalc, R3 and move into separate tickets, since the breadth is where F1 crept in. A per-item `pg_advisory_xact_lock` would be a valid alternative.

**Tension.** move cannot match both confirm's lock order and the transfer lock order unless P and L′ are taken before O. The cost: move briefly blocks pickers on that flowbin even when it ends up refusing.

**Synthesis.** Keep the FLA row lock. Apply F2 and F3. Ship Fix F only with the F1 lock order plus the ABBA-10b IT, or split move into its own ticket.
