# SBDEV-4107 — Phase 3a conformance (verifier) — head: d77daa01

Lane: conf-4107 (verifier, opus), 2026-11-11. Read-only; no mvn run; test counts are cited AS REPORTED. Saved by the parent session.

**Verdict:** conformance **PASS**, 0 blockers. Overall **INCOMPLETE**: three items are still owed, listed at the end.

## §0 rows
| Row | Verdict | Evidence |
|---|---|---|
| T1 | VERIFIED | `refuseIfTakenWhileWaiting(transferLane, customerOrder);` → `saveLaneAssignment(...)` → `customerorderRepository.saveAndFlush(customerOrder)` |
| T2 | VERIFIED | the same two calls in `activateAndAssignTransferLane`, after the SBDEV-4038 guards and the locked read |
| T7 | VERIFIED (pin) | `TransferLanePredicateReentryIT`: `DataIntegrityViolationException`, the index name, and Z stays FINISHED |
| S1 | VERIFIED | `locationRepository.lockById(stagingLane.getId());` before `getAvailableStagingLanes`; `saveAndFlush` with a catch on the staging index |
| G1 | VERIFIED | `findAdviceIdById` → `adviceRepository.findByIdForUpdate` before the position lock; `findFirstByAdviceIdOrderByIdAsc(...).orElse(null)`; the TODO is gone |
| G2 | VERIFIED | finisher calls `LockReads.forUpdate(entityManager, Advice.class, …)` |
| N1 | VERIFIED | `nextSuffix(findNumbersByGoodsreceiptId(...))`, then `++` |
| N2 | VERIFIED | `generateNumberWithAdvice` uses `nextSuffix(findNumbersByAdviceId)`; `updateAdviceWithPositions` uses `findByIdForUpdate` |
| N3 | VERIFIED | both count-based GRP methods deleted; 0 references left in src |

## Fixes
- **Fix A: VERIFIED.**
  - The post-lock re-check and the S1 lane lock are in place.
  - `saveAndFlush` is declared on both repositories that are not `JpaRepository`.
  - The catch rethrows any violation it does not name, and the WARN text matches §7.
  - V2.2.51 matches the plan's SQL line for line.
- **Fix B: VERIFIED.**
  - `findByIdForUpdate` has `@Lock`, an explicit `@Query` and `exported = false`.
  - The controller arm comes before the `RuntimeException` catch.
  - The javadoc now says the lost-finish and shared-location deadlock cases are closed.
- **Fix C: VERIFIED.** Both reads are JPQL. The output format is byte-identical, through the existing `generatePositionNumber`.
- **Fix D, code side: VERIFIED.** The `LocationRepository` comment is corrected, and `db/migration/README` has a V2.2.51 row. The sbdocs half is PENDING (Phase 4).
- **ITs:** all present; none `@Disabled`, no TODO and no skip. The harness `allowUnblockedSubject()` contract matches L-b.
- **Unit-test list:** VERIFIED.

## Deviations
- **5 (finisher lock placed after the first, unlocked completeness read): CONFORMS and is harmless.**
  - The lock sits literally before the sibling loop.
  - From a receive it changes nothing: the advice is already locked at the top of the receive.
  - From adjust/delete, a false FINISH is impossible: the decision is made again on the `reconcileLocked` read, a fresh statement taken after the lock.
  - The only cost is a possible missed finish. Moving the lock earlier would not close that either, because adjust/delete write before calling the finisher and take no advice lock first. That is the documented "Stale finish that remains" residual, which Fix B never claimed to close.
  - Upside: an adjust/delete that does not complete the advice takes no advice lock at all.
- **1 (new `UniqueViolations` util): CONFORMS.** The plan allowed it. `isActiveDupViolation` is private, has a domain fallback, and is duplicated, so it could not be lifted out.
- **2 (`generatePositionNumber` reused): CONFORMS.** It is an existing method with an identical format.
- **3 (unused `BasicService` dependency removed): CONFORMS.**
- **4 (`countByGoodsreceiptId` now dead): LOW.** It is dead in src/main, and `GoodsreceiptpositionRepository` is SDR-exported with no `@RestResource` on this method, so it stays a public `/search` endpoint with zero internal users. This predates the branch. Fix: delete it and drop its `never()` verify.

`@RestResource(exported = false)` is present on all 7 new repository methods (7/7 verified).

## ACs
1. **Duplicate census:** VERIFIED by citation.
2. **A two-transaction IT per path:** VERIFIED.
3. **Red → green:** VERIFIED as reported. Mutation checking is PENDING.
4. **Business refusal instead of a 500:** VERIFIED. By design (§8), a lane holder that runs longer than 3 s gives the loser 409, not the refusal.
5. **Flyway collision check:** PARTIAL. Checked against local refs only, so it needs a fresh fetch and `gh pr list` at merge preflight. **Suite vs baseline:** PARTIAL. No post-fix full `verify` has been run on d77daa01.
6. **Docs:** PARTIAL. The code side is done; sbdocs is PENDING.

## Gaps
- **Medium:** run a full `mvn clean verify -Pci` on the head and compare failures with the baseline.
- **Low:** `countByGoodsreceiptId` is dead but still exported.
- **Low:** the Flyway check used stale refs. Do a fresh fetch at merge preflight.
- **Info:** the §6.1 pre-deploy build-time gate has not been evidenced.
