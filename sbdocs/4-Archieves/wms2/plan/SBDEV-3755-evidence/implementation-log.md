---
title: "SBDEV-3755 Fix 1 — implementation log"
ticket: SBDEV-3755
created: 2026-10-13
---

# SBDEV-3755 Fix 1: implementation log

**Worktree:** `.claude/worktrees/wms2-api/SBDEV-3755-fix1`, branch `fix/SBDEV-3755-transferstock-replen-held-opt-in`, on top of gate commit `7b59ae5c`. Nothing pushed.

## Outcome

- Every gate test class is green, and the full `mvn clean verify -Pci` has **0 failures** in both lanes. That is the same empty failing set as the c6f0cbc0 baseline.
- **43 of 43 hand mutants KILLED attributably.** A14 first survived because its rail could not see supertype-owned method references. The coordinator approved strengthening the rail, which landed in `48387af8`, and the mutant is now killed (see "A14 rail fix").
- Scoped PIT: **0 survivors in new code** after four kill tests were added.

## Commits per story

| Story | SHA | Subject | Tests at the commit |
|---|---|---|---|
| 1. Fix C | `e93a7046` | un-export `findByStateLessThanAndStockunitId` (javadoc warning; repository comment corrected) | C1 green. `Sdr*` classes: 210 run, 0 F/E. B10 rail: 2/0 |
| 2. Fix B | `2481e101` | move-path sync acts on every holder | Fix B unit set: 155 run, 0 F. `ReplenishMultiHolderMoveIT` (B5–B8): 4/0. Move/replen IT subset (11 classes): 77/0 |
| 3. Fix A guard | `c23185d5` | refuse a transfer that displaces a replen-held SU | Guard unit test: 18/18. A12 and A14 green. E1a/E1b/E1d green. Interim reds as expected: A13 (no opt-in caller yet) and E1c (#15 still REFUSE, which is E1c's named mutant) |
| 4. Opt-ins (now includes story 5) | `3f2a98ee` (was `8aaf9f08`) | #15, #5, #10, #12 → ALLOW_ANY, plus the real `requestIfDisplaced` body | A13, A15–A19, A20 green. `TransferStockReplenHoldGuardIT`: 5/5. Must-stay-green ITs green: `MobileReplenishServiceIntegrationTest`, `MobileReplenishMultiUnitLoadIT`, `ReplenishClaimIT`, `ReplenishorderRedirectSourceIT`, `MobilePickingServiceIntegrationTest`. Interim reds (migrated in story 5): 11 F + 28 E in the caller unit classes, and `StockunitDamagedRollbackIntegrationTest` |
| 5. Caller migration (folded into `3f2a98ee`) | was `da550f32` | opt-in-path stubs and verifies → policy overload | Caller classes: 1293 run, 0 F/E. `StockunitDamagedRollbackIntegrationTest`: 1/0 |
| Floor | `cffc5d80` (was `0e2f0bf1`) | 4 PIT kill tests | PIT re-run: 0 survivors in new code |
| A14 rail | `99331e32` (was `48387af8`) | A14 rail sees supertype-owned references on `replenishorderRepository` | Rail 4/4. `*ArchTest,*RailTest`: 148/0 (`OptionalSafetyArchTest` 1/0, `NeverMatcherNullBlindnessArchTest` 4/0) |

**Fix B design note.** The shared prefix lives in a new package-private `MovedStockUnitHolders.lockForMove`, called by both services. It runs the projection, then a pre-check refusal by projected state, then locks ascending with `findByIdForUpdate`, keeping only rows still `< FINISHED` and bound to the SU, then re-checks under lock. This is a deviation from §6, which lists no new file. I made it so the two copies of the lock-order logic cannot drift. The behaviour is exactly §5 B.1–B.7.

| B2 fallbacks | `b37f0d1a` (was `e6b6e2e4`) | pin the vanished-holder fallbacks in the multi-holder move sync | 4 new tests (2 in `…SourceSyncServiceTest$MultiHolder`, 2 in `…ReassignTest`). Fix B unit classes: 140/0. Probe M1 (lock read → `orElseThrow()`) KILLED: 4 red, including both `…RowIsGoneAtTheLockRead` tests (`NoSuchElementException`). Probe M2 (pre-check read → `orElseThrow()`) KILLED: both `…ProjectedStartedHolderRowIsGone` tests red. Both restored from git |

### History rewrite: story 5 folded into story 4 (plan §7.2 step 5)

Done non-interactively, without an interactive rebase:
1. Created a temp branch at `c23185d5`.
2. Ran `git cherry-pick -n 8aaf9f08 da550f32` and committed the result as `3f2a98ee`, reusing 8aaf9f08's message with a folded-in note.
3. Cherry-picked the PIT, A14 and B2 commits on top.
4. Checked `git diff e6b6e2e4 b37f0d1a`: **empty**.
5. Moved `fix/SBDEV-3755-transferstock-replen-held-opt-in` to `b37f0d1a` and deleted the temp branch.

Nothing is pushed.

**Branch now** (on top of `7b59ae5c`):

| SHA | Commit |
|---|---|
| `e93a7046` | Fix C |
| `2481e101` | Fix B |
| `c23185d5` | Fix A guard |
| `3f2a98ee` | opt-ins + caller migration |
| `cffc5d80` | PIT kills |
| `99331e32` | A14 rail |
| `b37f0d1a` | B2 fallbacks |

**The folded commit is green on its own.** I checked out `3f2a98ee` in a detached worktree at `/tmp/claude-1000/wt-3f2a98ee` (removed afterwards) and ran:
- **Unit, 535 run, 0 F/E, BUILD SUCCESS:** `PickingorderBusinessServiceUnitTest`, `MobileReplenishServiceUnitTest`, `StockunitServiceUnitTest`, `StockunitServiceAuditCommentClampUnitTest`, `StockunitServiceParcelSourceRefusalUnitTest`, `UnitloadServiceUnitTest`, `ReplenHoldPolicyCallerArchTest`, `ReplenishmentMaintenanceTriggerUnitTest`, `NoBareTransferNeverRailTest` and `NeverMatcherNullBlindnessArchTest`.
- **IT, 6 run, 0 F/E:** `StockunitDamagedRollbackIntegrationTest` and `TransferStockReplenHoldGuardIT`.

**Gate unit set on the new tip `b37f0d1a`:** 20 classes (comma `-Dtest`), **678 run, 0 F/E**, BUILD SUCCESS. The Fix B unit classes are 140 of these (136 + the 4 B2 tests).

**SHA note:** the evidence tables and narrative below keep the original SHAs (`8aaf9f08`, `da550f32`, `0e2f0bf1`, `48387af8`), because that is what the runs were recorded against. The content is identical to the new SHAs above (empty diff).

## Gate classes (from the full `-Pci` run)

| Class | Run | Fail |
|---|---|---|
| `StockunitBusinessServiceReplenHoldGuardUnitTest` (A1–A11 + 3 PIT kills) | 21 | 0 |
| `ReplenHoldPolicyCallerArchTest` (A13) | 2 | 0 |
| `StockunitBusinessServiceReplenLockFenceArchTest` (A14) | 3 | 0 |
| `NoBareTransferNeverRailTest` (A20) | 5 | 0 |
| `TransferVerificationsUnitTest` (H1 self-test) | 12 | 0 |
| `ReplenishmentOrderSourceSyncServiceTest` (B1–B3 + 1 PIT kill) | 20 | 0 |
| `ReplenishmentOrderMaintenanceServiceReassignTest` (B4) | 18 | 0 |
| `ReplenishmentIdProjectionContractUnitTest` (B9) | 7 | 0 |
| `FindByStateLessThanAndStockunitIdNoMainCallerArchTest` (B10) | 2 | 0 |
| `SdrUncalledSurfaceNotExportedContextTest` (C1) | 3 | 0 |
| `ReplenishmentMaintenanceTriggerUnitTest` (A19) | 14 | 0 |
| `PickingorderBusinessServiceUnitTest` (A16) | 99 | 0 |
| `MobileReplenishServiceUnitTest` (A15, A20 pin) | 128 | 0 |
| `StockunitServiceUnitTest` (A17) | 116 | 0 |
| `UnitloadServiceUnitTest` (A18) | 111 | 0 |
| `OptionalSafetyArchTest` (A12) | 1 | 0 |
| **IT** `ReplenishMultiHolderMoveIT` (B5–B8) | 4 | 0 |
| **IT** `TransferStockReplenHoldGuardIT` (E1a–E1d) | 5 | 0 |
| **IT** `StockunitDamagedRollbackIntegrationTest` | 1 | 0 |

## B8 contention evidence

The positive control fired under the real Fix B every time it ran. In each run, B (the move) waited on a lock that A (the cut) held, and both transactions completed with no 40P01:

| Run | `wait_event_type` | Blocked pid (B, move) | Blocking pid (A, cut) | Outcome A | Outcome B |
|---|---|---|---|---|---|
| Story-2 run | `Lock` | 149 | 148 | null | null |
| Full `-Pci` | `Lock` | 690 | 689 | null | null |

**How it is detected:** `pg_stat_activity WHERE pid = B AND wait_event_type = 'Lock' AND A = ANY(pg_blocking_pids(pid))`.

**Named mutant (descending lock order):** KILLED with `[B8: the move must not end in a deadlock] … found ["40P01"]`.

**Scaffolding edit:** I added the two pids to B8's existing `log.info` line. The assertions are unchanged.

## Full suite (`mvn -o clean verify -Pci`, HEAD `0e2f0bf1`)

| Lane | This run | Baseline c6f0cbc0 | Failing set |
|---|---|---|---|
| Unit (surefire) | **8332** / 0 F / 0 E / 1 skip | 8264 / 0 / 0 / 1 | ∅, same as baseline |
| IT (failsafe) | **851** / 0 F / 0 E / 23 skip | 842 / 0 / 0 / 23 | ∅, same as baseline |

- **Unit delta +68:** 12 (H1 self-test, scaffold) + 52 (gate unit tests) + 4 (PIT kill tests).
- **IT delta +9:** the two gate IT classes.
- Result: BUILD SUCCESS.

## Scoped PIT (§8.3)

**Run settings:** `mvn -o org.pitest:pitest-maven:mutationCoverage` under Java 21.0.11. Survivors were read from `target/pit-reports/mutations.xml`.
- **Target classes:** SBS, `ReplenishmentOrderSourceSyncService`, `ReplenishmentOrderMaintenanceService`, `ReplenishmentMaintenanceTrigger`, `MovedStockUnitHolders`.
- **Target tests:** `StockunitBusinessService*`, `ReplenishmentOrderSourceSyncService*`, `ReplenishmentOrderMaintenanceService*`, `ReplenishmentMaintenanceTriggerUnitTest`.

| Class | Run 1, all code (killed / generated) | Run 2, all code | New / changed code, run 2 |
|---|---|---|---|
| `StockunitBusinessService` | 56/91 | 56/91 | every guard / `refuseIfHeld` / overload-return mutant KILLED |
| `ReplenishmentOrderSourceSyncService` | 16/22 → 7/7 in `syncForMovedStockUnit` | 17/22 | all KILLED |
| `ReplenishmentOrderMaintenanceService` | 174/202 overall | 174/202 | 4/4 in `reassignOrCancelForMovedStockUnit` KILLED |
| `ReplenishmentMaintenanceTrigger` | 5/6 | 5/6 | `requestIfDisplaced` 2/2 KILLED |
| `MovedStockUnitHolders` | 9/10 | 10/10 | all KILLED |
| **Total** | 305/428 | 309/428 | **0 survivors in new code** |

**Survivors killed** (by commit `0e2f0bf1`):

| Survivor | Kill test |
|---|---|
| `refuseIfHeld` non-blocking filter replaced with `true` | `…shouldLoadEachCandidateOnce_whenAllHolderRowsAreGone` |
| 8-arg return → null | `transferStockToUnitLoad8_shouldReturnTheReparentedStockUnit_whenNoHolders` |
| 9-arg return → null (no coverage) | `transferStockToUnitLoad9_shouldReturnTheReparentedStockUnit_whenNoHolders` |
| `MovedStockUnitHolders` `state < FINISHED` → `<=` | `syncForMovedStockUnit_shouldSkipHolder_whenItReachedFinishedAfterProjection` |

**Survivors justified (not in SBDEV-3755 code).** All of these are in the transfer body that the scaffold moved verbatim into the policy overload. `git blame` dates the lines to 0baee3a02 (2026-06-26), 676421371 (2026-05-14) and ^a685e07b (2024-07-16), so they would survive the same scoped test set on the base:
- SBS lines 250/252: the BLOCK_REALIGN classify and `lockOwningPickingorders`;
- 310/312: the mixed-stock re-check;
- 426: `realignForMovedStockUnit`;
- 484/490: the merge `setAmount` and `recordRemoval`;
- the `orElseThrow` supplier lambdas (NO_COVERAGE).

Pick-line realignment is covered by `PickLineRealignmentServiceUnitTest` and `PickLineRealignmentIT`, which are outside the scoped test set. Remaining survivors in the Maintenance service and the trigger (`runNow`) are in untouched methods.

**Equivalent mutant recorded, not to be "repaired":** "every share computed upfront" (Ar R2.2(d)) survives B7 by construction. The snapshot-once mutant is killed (below).

## Hand mutants (§8.2): one at a time, restored with `git checkout --`, worktree clean after each

**Method:** `/tmp/claude-1000/s/mutants.py` applied one mutant, ran the named class, parsed the reports, then restored with `git checkout --` and asserted `git status` was empty. "First failure" is the first failing test and its message.

| Mutant | Lane | Result | # failing | First failure (message) |
|---|---|---|---|---|
| A1-guard-deleted | unit | KILLED | 16 | transferStockToUnitLoad_shouldWriteNothing_whenReparentIsRefused :: [A1: the re-parent must be refused before its first write]  Expecting actual not t |
| A1-le-to-lt | unit | KILLED | 16 | transferStockToUnitLoad_shouldWriteNothing_whenReparentIsRefused :: [A1: the re-parent must be refused before its first write]  Expecting actual not t |
| A2-narrowed-to-dst-null | unit | KILLED | 1 | transferStockToUnitLoad_shouldRefuseAndLeaveDestinationAmount_whenDrainToZeroDisplacesHolder :: [A2: merging the whole source into a same-item SU drai |
| A3-read-above-predicate | unit | KILLED | 2 | transferStockToUnitLoad_shouldSucceedWithoutHolderRead_whenSplit :: replenishorderRepository.findHoldersByStateLessThanAndStockunitIdOrderById(     <a |
| A4-fla-dropped | unit | KILLED | 1 | transferStockToUnitLoad_shouldSucceedWithoutHolderRead_whenSourceHasFixLocationAssignment :: [with an FLA the source SU stays on its location (placeho |
| A5-refuse-whenever-displacing | unit | KILLED | 4 | transferStockToUnitLoad9_shouldReturnTheReparentedStockUnit_whenNoHolders :: refused |
| A6-findById-every-holder | unit | KILLED | 2 | transferStockToUnitLoad_shouldLoadEachCandidateOnce_whenAllHolderRowsAreGone :: replenishorderRepository.findById(<any>); Wanted 2 times: -> at net.ai |
| A7-always-get0 | unit | KILLED | 3 | transferStockToUnitLoad_shouldLoadEachCandidateOnce_whenAllHolderRowsAreGone :: replenishorderRepository.findById(<any>); Wanted 2 times: -> at net.ai |
| A8-orElseThrow | unit | KILLED | 3 | transferStockToUnitLoad_shouldLoadEachCandidateOnce_whenAllHolderRowsAreGone :: replenishorderRepository.findById(<any>); Wanted 2 times: -> at net.ai |
| A9-8arg-allow-any | unit | KILLED | 11 | transferStockToUnitLoad_shouldWriteNothing_whenReparentIsRefused :: [A1: the re-parent must be refused before its first write]  Expecting actual not t |
| A10-exclusion-dropped | unit | KILLED | 2 | transferStockToUnitLoad_shouldReturnForeignHoldersOnly_whenAllowAnyDisplacesWithOwnOrder :: [A10: the outcome carries the displaced siblings so the ca |
| A10-npe-on-null | unit | KILLED | 1 | transferStockToUnitLoad_shouldNameAllHolders_whenAllowAnyWithNullOrderNumber :: [#10 and #12 pass orderNumber = null; the filter must be null-safe]  e |
| A11-refused-log-deleted | unit | KILLED | 1 | transferStockToUnitLoad_shouldLogRefusal_whenRefusing :: [A11: support finds refusals by the REPLEN_HELD_REFUSED token]  Expecting any element of:   [ |
| A12-get-kept | unit | KILLED | 1 | noNewOptionalGetCallsInServiceClasses :: Architecture Violation [Priority: MEDIUM] - Rule 'no classes that reside in a package 'net.aim_ai.wms.service |
| A13-fifth-caller | unit | KILLED | 1 | policyOverload_shouldBeReachedOnlyByDecidedOptIns_whenScanningProductionCode :: [A caller of transferStockToUnitLoad(..., ReplenHoldPolicy) was added, |
| A14-lockreads-methodref | unit | KILLED (after `48387af8`; first run SURVIVED) | 1 | sbs_shouldNotReferenceReplenishorderRepositoryMethods_whenScanningProductionCode :: … references method <org.springframework.data.repository.CrudRepository.findById(java.lang.Object)> |
| A15-finish-8arg | unit | KILLED | 13 | finishReplenishmentOrder_shouldCallPolicyOverloadWithAllowAnyAndOwnNumber_whenFinishing :: Argument(s) are different! Wanted: stockunitBusinessService |
| A16-pick-refuse | unit | KILLED | 15 | shouldDeferPickingStartedToAfterCommit :: Strict stubbing argument mismatch. Please check:  - this invocation of 'transferStockToUnitLoad' method:     |
| A16-heal-dropped | unit | KILLED | 1 | confirmPick_shouldRequestHealForDisplacedHolders_whenTransferDisplacedOne :: Wanted but not invoked: replenishmentMaintenanceTrigger.requestIfDisplace |
| A17-damaged-refuse | unit | KILLED | 3 | transferStock_shouldCallPolicyOverloadWithAllowAny_whenMovingToDamaged :: Argument(s) are different! Wanted: stockunitBusinessService.transferStockToU |
| A17-arm11-allow-any | unit | KILLED | 1 | transferStock_shouldStayOnRefusingOverload_whenMovingToNewContainerElsewhere :: Argument(s) are different! Wanted: stockunitBusinessService.transferSt |
| A18-container-refuse | unit | KILLED | 3 | helperTakesTheDamagedLocationLockFirst :: Strict stubbing argument mismatch. Please check:  - this invocation of 'transferStockToUnitLoad' method:     |
| A18-trigger-injected | unit | KILLED | 1 | unitloadService_shouldNotDependOnTheTrigger_whenConstructed :: [A18: setLockDamaged already requests maintenance after the helper's transaction. A tri |
| A19-unconditional | unit | KILLED | 1 | requestIfDisplaced_shouldRequestNothing_whenOutcomeHasNoDisplacedHolders :: replenishmentOrderMaintenanceService.recalculateForItem(     <any> ); Neve |
| A20a-transfer-before-client-check | unit | KILLED | 5 | snapshot_recordsPreMoveSourceUl_whenSourceReHomedToDestination :: Strict stubbing argument mismatch. Please check:  - this invocation of 'transferStoc |
| A20b-bare-never-readded | unit | KILLED | 1 | bareTransferNevers_shouldBeAbsent_whenOutsideTransferVerifications :: [A never()/times(0) verify of transferStockToUnitLoad sees ONE of its three over |
| A20c-10arg-line-dropped | unit | KILLED | 1 | verifyNoTransfer_shouldThrowNeverWantedButInvoked_whenOverloadCalledWithNulls(int)[3] :: Expecting code to raise a throwable. |
| A20d-floor | unit | KILLED | 1 | helperCallSitesMeetTheFloor :: [18 verifyNoTransfer* call sites outside the helper and its self-test (floor 19, the plan §6 H1 migration). Fewer means |
| B1-descending | unit | KILLED | 1 | syncForMovedStockUnit_shouldLockAscendingAndRepointBoth_whenTwoProcessableHolders :: Verification in order failure Wanted but not invoked: replenishor |
| B1-first-only | unit | KILLED | 2 | syncForMovedStockUnit_shouldLockAscendingAndRepointBoth_whenTwoProcessableHolders :: [B1: every holder of the moved stock unit is re-pointed onto the  |
| B2-precheck-removed | unit | KILLED | 4 | syncForMovedStockUnit_shouldNameReplenOrder_whenStartedReplenBlocks :: Expecting code to raise a throwable. |
| B3-recheck-skipped | unit | KILLED | 1 | syncForMovedStockUnit_shouldRefuseWithoutRepointing_whenHolderStartedUnderLock :: [B3: re-checked under lock, REPL-9 is now in progress, so the move i |
| B3-repoint-before-checks | unit | KILLED | 1 | syncForMovedStockUnit_shouldRefuseWithoutRepointing_whenHolderStartedUnderLock :: [B3: nothing is re-pointed before every lock is held and re-checked] |
| B4-su-before-orders | unit | KILLED | 1 | reassignOrCancelForMovedStockUnit_shouldLockOrdersThenStockUnitThenAct_whenTwoHolders :: Verification in order failure Wanted but not invoked: stockun |
| B4-su-per-order | unit | KILLED | 1 | reassignOrCancelForMovedStockUnit_shouldLockStockUnitOnce_whenTwoHolders :: stockunitRepository.findByIdForUpdate(42L); Wanted 1 time: -> at net.aim_a |
| B10-main-call | unit | KILLED | 1 | findByStateLessThanAndStockunitId_shouldHaveNoMainAccess_whenScanningProductionCode :: [findByStateLessThanAndStockunitId throws on two or more holder |
| C1-exported-removed | unit | KILLED | 1 | callerlessSearchesOnExportedTypesAreWithdrawnIndividually :: [a search with no HTTP caller is routed and unguarded. Withdraw it with @RestResource(exp |
| B7-share-snapshot | it | KILLED | 1 | laneMove_twoHolders_bothRedirected_releaseOwnShares :: [B7: the source drops by both shares (8 -> 0)]  expected: 0  but was: 2.0000 |
| B8-descending | it | KILLED | 1 | moveAndAttributedCut_sameTwoHolderSu_noDeadlock :: [B8: the move must not end in a deadlock]  Expecting   ["40P01"] not to contain   ["40P01"] but fou |
| E1a-guard-deleted | it | KILLED | 2 | transferStock_shouldLeaveNoTrace_whenWholeHeldStockUnitMoveIsRefused :: [E1a: the move must be refused]  Expecting actual not to be null |
| E1b-keyed-on-holder | it | KILLED | 1 | transferStock_shouldSplitAndLeaveReplen_whenHalfOfHeldStockUnitMoves :: [E1b: a split never displaces the binding (D1, SBDEV-2492 manual row 5)]  expe |
| E1c-finish-refuse | it | KILLED | 1 | fulfillMultipleUnitLoads_shouldFinishOrder_whenItMovesItsOwnHeldStockUnit :: [E1c: the finish opts in (#15 ALLOW_ANY) and must not be refused by its o |
| E1d-precheck-widened | it | KILLED | 1 | transferStock_shouldMoveContainerAndRepoint_whenHeldStockUnitIsAloneOnItsUnitLoad :: [E1d: the whole-container route never calls transferStockToUnitLo |
**A17-arm11 note:** the first attempt mutated the flowbin MANUAL_SPLIT arm (`StockunitService` ~:428) instead of #11, and only `transfersToFlowbinWithNewAssignment` failed. I re-ran it on the #11 (non-QF new-container) arm, and it was KILLED by `transferStock_shouldStayOnRefusingOverload_whenMovingToNewContainerElsewhere`. The table shows the re-run.

**Mutants checked through PIT or a gate run instead of by hand:**
- **A1 `<=`→`<`:** also killed by PIT, with the killing test `…RefuseNamingHolderSuAndUnitLoad…`.
- **A19:** also killed by PIT, at line 119 (negated conditional).
- **B5, B6, B9:** each has "base" as its mutant. Each was red on the scaffold in the gate run, with failures asserted by type.

## A14 rail fix (approved by the coordinator; landed in `48387af8`)

- **What happened:** mutant `LockReads.forUpdate(entityManager, Replenishorder.class, id, replenishorderRepository::findById)` added in SBS. `StockunitBusinessServiceReplenLockFenceArchTest` stayed **3/0 green**, so the mutant **SURVIVED**.
- **Cause, from `javap -v` on the mutant build:** `findById` is inherited, so javac emits the method handle as `REF_invokeInterface org/springframework/data/repository/CrudRepository.findById`, not as a handle on `ReplenishorderRepository`. The rail filters accesses on `getTargetOwner().isEquivalentTo(ReplenishorderRepository.class)`, so it never sees a method reference to an inherited method.
- **Why the positive control passes anyway:** it uses `stockunitRepository::findByIdForUpdate`, which is declared on the repository itself.
- **Production code:** has no such reference. A14's current assertions hold, and the real guard calls `findById` directly. The gap is only in the rail's reach, which is exactly what Cr N3 meant it to close.
- **Fix, as approved:** the reference rule now also flags a `JavaMethodReference` whose owner is any supertype of `ReplenishorderRepository` (`CrudRepository`, `JpaRepository`, …), when the same code unit reads the `replenishorderRepository` field on the same line. That field read is the captured receiver, so `stockunitRepository::findById` is not caught.
  - **New self-test:** `detector_shouldFlagPlantedInheritedFindByIdReference_whenGivenTheEscapedShape`. It compiles `PlantedShapes`: the escaped shape is flagged, and the same handle on `stockunitRepository` is not. The positive control is unchanged.
- **Re-run:** the mutant is KILLED. The failure names `transferStockToUnitLoad(...)` referencing `CrudRepository.findById(java.lang.Object)`. SBS was restored from git and the worktree is clean.
- **Blind spot (narrower now):** a receiver stashed in a local variable on an earlier line (`var r = replenishorderRepository; … r::findById`) is not matched. Production SBS has no such code.

## Scaffolding and test edits (non-gate assertions unchanged)

1. `ReplenishMultiHolderMoveIT`: added the B8 blocked/blocking pids to its diagnostic `log.info`. No assertion was touched.
2. **Re-targets for the deleted `findIdByStateLessThanAndStockunitId` (plan §6):**
   - `ReplenishmentOrderSourceSyncServiceTest` (9 stubs);
   - `…SourceSyncServiceBranchTest` (3);
   - `ReplenishmentOrderMaintenanceServiceReassignTest` (8 stubs and 1 positive verify);
   - `ReplenishmentOrderMaintenanceServiceUnitTest` `moveFixture` (1);
   - all of the above now stub the holders list with the order's own id/state/number.
   - The six STARTED/530 cases now stub `findById(7)` instead of `findByIdForUpdate(7)`, because the projected-state pre-check refuses from a plain read (§5 B.2). Their assertions are unchanged.
   - `ReplenishmentIdProjectionContractUnitTest`: the F5 `contains` assertion now names `findHoldersByStateLessThanAndStockunitIdOrderById/2`, and the `newIdProjections_areNotExportedOverSdr` list swaps the deleted finder for the holders finder.
   - `AttributedReservedCutContractUnitTest:176`: the positive control now names the surviving entity finder `findByStateLessThanAndStockunitId/2`.
3. **Story 5 caller migration (plan §6):** listed in the `da550f32` message. The lenient stubs `stubDamagedSplitArm` and `UnitloadServiceUnitTest:2438` were converted by hand, and `ParcelSourceRefusalUnitTest` gained a policy stub beside its 8-arg one.
   - **Left as-is:** the gate tests' own lenient 8-arg stubs (`PickingorderBusinessServiceUnitTest$Sbdev3755ConfirmPickOptIn`, `UnitloadServiceUnitTest.arrangeHelperCallForEitherOverload`). They are now orphaned, but they are harmless and live in gate code.
4. **`NeverMatcherNullBlindnessArchTest`:** re-measured, green with its inventory unchanged. No `never()` site moved in stories 1–5.
5. **New tests:** the 4 PIT kill tests listed above, plus the A14 planted-shape self-test.
6. **A14 rail detection widened** (`48387af8`, approved). It is stricter, not weaker.

## Deviations

- New `MovedStockUnitHolders` class (see story 2).
- Fix B skips a locked row that has vanished. Before this change it threw `EntityNotFoundException`. Plan §5 B.3/B.7 calls for "skip". Pinned since `b37f0d1a` (conformance B2 PARTIAL, now closed).
- Story 4 was first committed separately from story 5 (with interim reds). It has since been folded into one commit (`3f2a98ee`), as plan §7.2 step 5 requires.

## Review round 1 fixes (fix1-review-code.md, read at `b37f0d1a`; plus SEC-1 from the commit security review)

Every finding is fixed. Lows are fixed, not just recorded. Each mutant was applied with `/tmp/claude-1000/s/mutants.py`, then restored with `git checkout --`, and the worktree was confirmed clean afterwards.

| Finding | SHA | What changed | Test(s) | Mutant: result and attributable message |
|---|---|---|---|---|
| **M1** refusal on the projected state was unpinned | `d908efb6` | Tests only | `…SourceSyncServiceTest$MultiHolder.syncForMovedStockUnit_shouldRefuseOnProjectedState_whenLoadedRowNoLongerBlocks`, `…ReassignTest.reassignOrCancelForMovedStockUnit_shouldRefuseOnProjectedState_whenLoadedRowNoLongerBlocks` (projection REPL-9@500, loaded row @300 → refused naming REPL-9, `findByIdForUpdate` never called) | `blocking != null && blocksMove(blocking)`: **KILLED** in both classes, `[B2 (§5 B.2, Ar R2-L4): the refusal is on the PROJECTED state; a present row always throws…]`. The review suggested projecting @400; I used 500 (STARTED), because 400 is RESERVED and does not block, so @400 would have tested the wrong thing |
| **M2** A14 bypass through helper delegation | `11af88b5` | Two new A14 rules: SBS never passes the `replenishorderRepository` field as an argument to any call, and SBS never accesses `MovedStockUnitHolders`. The blind-spot javadoc now also names a local copy of the field and another bean that holds its own repository | `sbs_shouldNotPassReplenishorderRepositoryAsArgument…`, `sbs_shouldNotAccessMovedStockUnitHolders…`; production positive control `detectors_shouldSeeTheSyncServicePassingTheRepository…`; planted shape `detector_shouldFlagPlantedRepositoryArgument_whenGivenTheHelperShape`. Rail 8/8 | `probeA14() { return MovedStockUnitHolders.lockForMove(replenishorderRepository, id); }` in SBS: **KILLED** by both new rules, `[Passing the repository to a helper (e.g. MovedStockUnitHolders.lockForMove…) … R3 inversion]` |
| **L1** subset rule had no floor | `11af88b5` | `containsAll(ALLOWED)` after `isSubsetOf` | `sbs_shouldCallOnlyNonLockingReplenFinders…` | `findById` → `getReferenceById` in SBS: KILLED (by the subset half). The floor half is non-vacuous by construction, since both finders are called in SBS today |
| **L2** dead lenient 8-arg stubs | `e5b71d78` | `PickingorderBusinessServiceUnitTest$Sbdev3755ConfirmPickOptIn`: the 8-arg stub is deleted and the 10-arg one is now strict. `UnitloadServiceUnitTest`: `arrangeHelperCallForEitherOverload` removed; A18 uses `arrangeHelperCall` (already strict on the policy overload) | A16 and A18 tests green; PBS 99/0, Unitload 111/0 | — (stub cleanup) |
| **L3** B8 asserted no end state | `292b8cd8` | After both legs, B8 now checks: REPL-9 CANCELED (cut, newest first); REPL-5 PROCESSABLE and re-pointed to `LOC_DST_REPLEN`; REPL-9 not re-pointed (drift filter); REPL-5 still bound to the SU; SU reserved = 3 | `ReplenishMultiHolderMoveIT` 4/0; contention fired (blocked pid 149, blocking pid 148) | — (the existing B8 mutant still applies) |
| **L4** "every order" overclaims | `ab56eb20` | `MovedStockUnitHolders.lockForMove` `@return`, the maintenance javadoc and the sync javadoc now say "every order the holders projection returned that is still open and bound under lock", and name the born-after-projection residual | — (docs) | — |
| **L5** self-move onto the source's own unit load | `3dfe7a1a`, **superseded by SEC-1 `f7fe0883`** | **Reachable:** web Move Stock's existing-container arm (`StockunitService.transferStock`, non-pallet type) passes the scanned unit load straight to `transferStockToUnitLoad`, with no same-unit-load check. A true self-merge moves nothing and is now excluded from `displacing`. Javadoc updated | `StockunitBusinessServiceSelfMoveGuardUnitTest.transferStockToUnitLoad_shouldNotRefuse_whenDestinationIsTheSourcesOwnUnitLoad` | Exclusion dropped: **KILLED**, `[L5: a self-move merges the SU into itself…] … BusinessException: Stock unit 4711 on unit load UL-OWN: Replenishment order REPL-5…` |
| **SEC-1** (commit security review) the L5 exclusion was keyed on the unit load | `f7fe0883` | 3dfe7a1a excluded any transfer onto the source's own unit load. When that unit load holds a same-item sibling listed first, the sibling is the merge target and the held source drains to Nirwana, which is a real displacement. The exclusion now keys on the chosen destination SU being the source itself (`selfMerge`). Javadoc and comment updated | `…SelfMoveGuardUnitTest.transferStockToUnitLoad_shouldRefuse_whenOwnUnitLoadHoldsASameItemSiblingListedFirst`. **RED on 3dfe7a1a's predicate**, green after; the L5 test stays green (2/2) | UL-equality predicate restored: **KILLED** by the SEC-1 test, `[SEC-1: the source drains to 0 into its sibling and goes to Nirwana, stranding REPL-5…]`. `selfMerge` dropped: **KILLED** by the L5 test |
| **L6** import order and long line | `ab56eb20` | `java.util.List` moved into the `java.*` group in `ReplenishmentOrderSourceSyncService`; the ~150-char javadoc line in `ReplenishmentOrderMaintenanceService` re-wrapped | — | — |
| **L7** no end-to-end IT for an ALLOW_ANY heal | `75346acd` | It fits `TransferStockReplenHoldGuardIT` cleanly. Web Move Stock of the whole held X to the seeded `Damaged` location (#10) is not refused and X is re-parented. After commit, the deferred `requestIfDisplaced → recalculateForItem` cancels the holder. The log shows `REPLEN_HELD_DISPLACED … holders=[RO-3755-E1@300]` | `transferStock_shouldHealDisplacedHolderAfterCommit_whenWholeHeldStockUnitIsDamaged`; IT 6/0 | `requestIfDisplaced` dropped at #10: **KILLED**, `[L7: the displaced holder was healed after commit…] expected: 800 but was: 300` |

**Final verification at `75346acd`:**
- **Unit:** the affected and gate set (22 patterns, comma `-Dtest`): **831 run, 0 F/E**, BUILD SUCCESS.
- **ITs:** `ReplenishMultiHolderMoveIT`, `TransferStockReplenHoldGuardIT` and `StockunitDamagedRollbackIntegrationTest`: **11 run, 0 F/E**. The B8 contention control fired (`wait_event_type='Lock'`, blocked pid 149, blocking pid 148), and both legs completed with no 40P01.
- The full `-Pci` suite was not re-run for this round. The coordinator will run it before the push.

**Branch now** (on top of `7b59ae5c`; nothing pushed):

| SHA | Commit |
|---|---|
| `e93a7046` | Fix C |
| `2481e101` | Fix B |
| `c23185d5` | Fix A |
| `3f2a98ee` | opt-ins + caller migration |
| `cffc5d80` | PIT kills |
| `99331e32` | A14 inherited-method references |
| `b37f0d1a` | B2 fallbacks |
| `d908efb6` | M1 |
| `11af88b5` | M2 + L1 |
| `3dfe7a1a` | L5 |
| `ab56eb20` | L4 + L6 |
| `e5b71d78` | L2 |
| `292b8cd8` | L3 |
| `f7fe0883` | SEC-1 |
| `75346acd` | L7 |

## Review round 2 fix

**R2-L1** (round-2 re-review, which otherwise APPROVED) is fixed in **`06e79608`**: the M2 rail skipped parameters typed `Object`.

**Route taken: the stronger fix (allow-list), not the javadoc fallback.**
- `Object`-typed parameters are now in scope, and checked explicitly.
- Checking them explicitly turned out to be necessary. ArchUnit does not treat an interface as assignable to `Object`, so `isAssignableFrom` alone never matched an `Object` parameter at all.
- A real scan of SBS hit exactly one callee: `java.util.Optional#orElse`, on `replenishorderRepository.findById(id).orElse(null)`. There the field read on that line is the receiver of `findById`, not an argument to `orElse`.
- So the allow-list `HARMLESS_OBJECT_CALLEES` has that single entry. It is not noisy or fragile, and its javadoc says an entry may be added only together with the scan hit that needs it.
- The allow-list is also named in the rail's blind-spot list.

**Tests:**
- New planted shape `<R> R lockAnything(R, Long)`, called as `lockAnything(replenishorderRepository, id)`.
- Its self-test `detector_shouldFlagPlantedGenericHelperArgument_whenParameterErasesToObject` was **RED before the change** and is green after.
- Rail: **9/9**.

**Mutants:**
- A generic helper inside SBS that receives the repository: **KILLED** by `sbs_shouldNotPassReplenishorderRepositoryAsArgument_whenScanningProductionCode`.
- The round-1 M2 mutant (`lockForMove(replenishorderRepository, id)` in SBS): still **KILLED**.
- Both were restored from git, and the worktree is clean.

**Branch tip:** `06e79608`. Nothing pushed.

## Review round 3 fixes (round 3 APPROVED with two Lows)

Both Lows are fixed in **`5caf29f2`**, test only, in `StockunitBusinessServiceReplenLockFenceArchTest`. The branch tip is `5caf29f2`, and nothing is pushed.

| Finding | Fix | Evidence |
|---|---|---|
| **R3-L1** orphaned, stale javadoc above the allow-list | `replenRepositoryPassedAsArgument` now has one merged, accurate javadoc. It excludes receiver calls and allow-listed callees, and covers parameters typed `ReplenishorderRepository`, any supertype of it, or `Object` (it explains why `Object` is checked explicitly) | Rail **10/10** |
| **R3-L2** allow-list semantics and staleness | The allow-list javadoc says the exemption is **per callee**: any `Optional#orElse`, whatever the argument. It explains why that is safe: `orElse` cannot lock, and any same-line onward use is caught by the argument, finder-subset and method-reference rules. It also names the residual: a local copy used on a later line, which is the existing blind spot. New control `allowList_shouldStillMatchACallInSbs_whenScanningProductionCode` fails when an entry no longer matches a hit in SBS | With the allow-listed `findById(...).orElse(null)` call removed from SBS, the control went **RED**: "allow-list entry java.util.Optional#orElse no longer matches any call ...". Restored from git; the worktree is clean |
