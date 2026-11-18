# Conformance re-check r2 — SBDEV-4031 @ e60a10c4 (verifier lane, saved by main session 2026-11-06)

Scope: §10.z (M1 skip align, 03850bb0) and the move refusal reorder (fd1a5378).

## Verdict
PASS for code. One plan-text drift item (medium, doc only) and two low test gaps.
Confidence: high for (a), (c), (d); medium for the lock-order argument (read, not deadlock-probed).

## Evidence
- Unit: ReplenishmentOrderMaintenanceServiceUnitTest + FixLocationAssignmentServiceUnitTest: 201 run, 0 failures (surefire XML includes the staleHint tests).
- IT (TESTCONTAINERS_REUSE_ENABLE=false): FixLocationAssignmentMoveIT 5/0; FixLocationAssignmentLockRaceIT 11/0.
- The `[ERROR] ... ConnectException` line in the log is springdoc-openapi:generate, not a test.
- Worktree clean at e60a10c4 after the run.

## (a) Code vs §10.z: PASS
- The pre-lock hint `findItemdataIdByIdAndDestinationIdIsNull(orderId).map(fixLocationAssignmentRepository::lockIdByItemdataId)` runs before `findByIdForUpdate(orderId)`, so F is taken before O.
- On a stale hint the code takes no late lockIdByItemdataId, does no alignDestination and no findActiveLocationIdByItemdataId. destinationId stays null and assignment is null for the pass.
- `grep lockIdByItemdataId` finds only two sites: the recalculateForItem outer lock and the pre-lock hint.

## (b1) AC-4d: verified, not superseded
`perOrderRecalc_nullDest_blockedByHeldFla` seeds a null destination, so the hint fires and F is taken before O. It passed, and it is mutation-sensitive: removing the hint lock goes red.

## (b2) Plan text drift (doc only)
These passages still describe the late lock, or the monotonicity premise, as current:
- §10.x "Rule" bullet (late lock "proven cycle-free")
- §10.x "Tests" bullet (test for a lock taken after the order lock)
- §10.x "Lock order" bullet (ABBA-1 still holds)
- §10.y "A1 placement"
- §4.2 "Monotonicity premise" paragraph
- §6 Fix D code comment ("a stale 'null' costs one unneeded lock")

Low drift: line 122's "Accepted tension" and the ADR consequence still say move takes P and L′ before its refusal checks.

## (c) Move reorder: PASS
- Lock order: F, then the lock-free refusals (requireFlowbin, the in-processing `exists`, the already-targets projection), then P, then L′, then the L′-guarded checks (FLA or UL at L′), then O ascending.
- The reorder adds no new lock edge.
- The in-processing state is re-checked under the order lock.
- AC-10, AC-10b, AC-10c and AC-10c-bis pass. AC-10c parks on findByStoragelocationId with the OLD location id, which the reorder did not move.

## (d) Tests not vacuous: PASS, two low gaps
- Both stale-hint unit tests use `never().lockIdByItemdataId(any())` after the order lock. The item-sweep test also asserts requestedamount 84, which proves the context FLA was not used.
- Gap 1 (low): the stale-hint path has no IT. Acceptable, because the path deliberately skips and takes no lock.
- Gap 2 (low): only the already-targets refusal test asserts that no P or L′ lock is taken. The in-processing and not-a-flowbin refusal tests do not, so moving those two checks back after P/L′ would survive the unit tests.

## Recommendation
APPROVE the code. Fix the plan text: mark §10.x Rule/Tests superseded by §10.z, reword §4.2 and the §6 comment, and note the narrowing at line 122 and in the ADR.
