---
ticket: SBDEV-3755
lane: Phase 3a conformance (verifier, independent of the implementer)
head: 48387af8ba76cc59ea3382dfc77d2fe7e9c21c03
base: c6f0cbc0 (PR #510 head; diffed with `git diff c6f0cbc0...HEAD`)
worktree: .claude/worktrees/wms2-api/SBDEV-3755-fix1
branch: fix/SBDEV-3755-transferstock-replen-held-opt-in
date: 2026-10-13
verdict: PASS (0 blockers; 1 non-blocking PARTIAL)
---

# SBDEV-3755 Fix 1: conformance check

Plan: `../SBDEV-3755-transferstock-replen-held-opt-in.md` (r3). Every result below was re-run by this lane at
`48387af8` in the fix1 worktree. Nothing was read from `v2/wms2-api` or the stale `.../SBDEV-3755` worktree.
The worktree was clean (`git status --short` empty) at the start and at the end. No `git checkout`, `restore`
or `stash` was used. The two mutant probes copied the file to the scratchpad and restored it from there, then
recompiled (`javap` shows no `orElseThrow` left in `MovedStockUnitHolders.class`).

## Verdict

**PASS. 0 blockers.**
- §0: 15 rows, 15 VERIFIED.
- ACs: 35 in total. 34 VERIFIED, 1 PARTIAL (B2), 0 MISSING.
- §10 D1–D4 are honoured.
- The B2 gap is a missing test, not a code defect: the code does what the plan says, but nothing pins the Fix B
  vanished-row fallbacks (two of my mutants survived; see Deviation 2). Close it before the review lane.

## Evidence (fresh, this lane)

| Check | Command | Result |
|---|---|---|
| DI / compile drift | `mvn -o -q clean test-compile` | EXIT 0 |
| Gate and caller unit classes (36 classes, comma-separated `-Dtest`) | `mvn -o test -Dtest=<36 classes> -Dsurefire.failIfNoSpecifiedTests=false` | **1154 run, 0 F, 0 E, 0 skip.** BUILD SUCCESS. 211 `TEST-*.xml` files were written, and each class was tallied from its XML. Gate classes: Guard 21/0 · A13 2/0 · A14 4/0 · A20 5/0 · H1 self-test 12/0 · SourceSync 20/0 · Reassign 18/0 · B9 contract 7/0 · B10 2/0 · C1 3/0 · Trigger 14/0 · Optional 1/0 · NeverMatcher 4/0 |
| Gate ITs plus the must-stay-green ITs | `mvn -o verify -Dit.test='ReplenishMultiHolderMoveIT,TransferStockReplenHoldGuardIT,StockunitDamagedRollbackIntegrationTest,ReplenishRedirectLockOrderIT,ReplenishorderRedirectSourceIT,ReplenishClaimIT,MobileReplenishMultiUnitLoadIT,MobileReplenishServiceIntegrationTest' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | **84 run, 0 F, 0 E.** Multi-holder 4/0 · Guard 5/0 · Damaged rollback 1/0 · Lock order 4/0 · Redirect source 33/0 · Claim 35/0 · Multi-UL 1/0 · Replenish 1/0. 8 failsafe XMLs written. B8 log: `bWaitedOnA=true (wait_event_type='Lock', blocked pid=149, blocking pid=148) outcomeA=null outcomeB=null` |
| Full suite | `mvn -o -B clean verify -Pci` | **Unit 8333 / 0 F / 0 E / 1 skip; IT 851 / 0 / 0 / 23.** BUILD SUCCESS. The failing set is empty, the same as the c6f0cbc0 baseline (8264/0/0/1, 842/0/0/23). Unit 8333 = 8332 claimed at `0e2f0bf1`, +1 for the A14 planted-shape self-test in `48387af8`. B8's positive control fired again in this run |
| Mutant probe M1: Fix B lock read of a vanished row changed to `.orElseThrow()` | the 4 Fix B unit classes | **SURVIVED** (136/0) |
| Mutant probe M2: Fix B pre-check of a vanished blocking row changed to `.orElseThrow()` | the same 4 classes | **SURVIVED** (136/0) |

I did not re-run the implementer's 43 hand mutants or PIT. Mutant attribution in the AC table below comes from
`implementation-log.md`. Each test it names exists and is green at HEAD.

## §0 Affected sites

**Census.** `git grep -n "transferStockToUnitLoad(" -- src/main` (SBS excluded) gives 18 caller expressions,
the same 18 as the plan. Policy literals in `src/main`: `ReplenHoldPolicy.ALLOW_ANY` appears exactly 4 times
(PBS:1335, StockunitService:609, UnitloadService:198, MobileReplenishService:323). `REFUSE` appears only in the
two SBS delegations. A13 pins the same set structurally (green).

| # | Site | Plan policy | Status | Evidence |
|---|---|---|---|---|
| 1 | BOL combineStock OFF | REFUSE | VERIFIED | `BillofladingService.java` is not in the src/main diff. 8-arg call at :1117 → delegates REFUSE (SBS:181) |
| 2 | BOL combineStock ON | REFUSE | VERIFIED | untouched; :1136, 9-arg → REFUSE (SBS:190) |
| 3 | Club runClubLine | REFUSE | VERIFIED | untouched; :197 |
| 4 | CustomerorderService packageOrder | REFUSE | VERIFIED | untouched; :666 |
| 5 | PBS.confirmPick | ALLOW_ANY + heal | VERIFIED | `TransferOutcome pickTransfer = …(…, null, ReplenHoldPolicy.ALLOW_ANY); replenishmentMaintenanceTrigger.requestIfDisplaced(pickTransfer, stockUnit.getItemdataId());`. Constructor gains the trigger, and the full context loads (IT lane green) |
| 6–9, 11 | StockunitService MANUAL_SPLIT arms | REFUSE | VERIFIED | :378, :382, :428, :597, :640 are unchanged. The only hunk in `transferStock` is the #10 arm. A17 CTRL pins #11 on the 8-arg overload |
| 10 | StockunitService → Damaged | ALLOW_ANY + heal | VERIFIED | :608–610, `ALLOW_ANY` then `requestIfDisplaced(damageTransfer, …)` |
| 12 | UnitloadService.moveStockToNewDamagedContainer | ALLOW_ANY, no trigger | VERIFIED | :196–198 `ReplenHoldPolicy.ALLOW_ANY).stock()`. `grep` finds no trigger in `UnitloadService.java`. A18 reflection rail is green |
| 13 | MobileMoveUnitloadService.transferStock | REFUSE (3747 pre-check stays) | VERIFIED | untouched; `$Sbdev3747ReplenHeldStockMove` 6/0 |
| 14 | MobilePutAwayService flow-bin arm | REFUSE | VERIFIED | untouched; :568 |
| 15 | MobileReplenishService finish | ALLOW_ANY, own number, no heal | VERIFIED | :321–323 `replenishOrder.getNumber(), null, false, true, null, ReplenHoldPolicy.ALLOW_ANY`; no trigger call |
| 16 | MobileTransferOrderService R==0 arm | REFUSE | VERIFIED | untouched; :440 |
| 17, 18 | MobileTransferOrderService available arms | REFUSE (inert) | VERIFIED | untouched; :429, :435 |
| Fix B | `syncForMovedStockUnit` + `reassignOrCancelForMovedStockUnit` | multi-holder | VERIFIED | Both call `MovedStockUnitHolders.lockForMove(...)`. The sync service checks `!isReplenishableDestination` first and delegates, so exactly one service runs the prefix. The finder is deleted, and `git grep findIdByStateLessThanAndStockunitId -- src/main` finds comments only |
| Fix C | `findByStateLessThanAndStockunitId` | `exported = false` + javadoc + rail | VERIFIED | `@RestResource(path = "findByStateLessThanAndStockunitId", rel = "…", exported = false)` with the "do not use in src/main" javadoc. The repository comment is corrected ("The third is NOT exported any more") |

The plan's file list also requires deleting `archunit_store/5fb3fee0…` line 38. That line (`…transferStockToUnitLoad(…FixLocationAssignment)> calls method <java.util.Optional.get()>`) is deleted, and SBS now reads `fixLocationAssignmentOpt.orElse(null)`.

## Acceptance criteria

### Fix A: guard (`StockunitBusinessServiceReplenHoldGuardUnitTest`, 21/0)

| # | Status | Evidence |
|---|---|---|
| A1 | VERIFIED | `…shouldRefuseNamingHolderSuAndUnitLoad…` asserts `contains("REPL-5")`, the SU id and the UL label. `…shouldWriteNothing…` asserts `stockunitRepository.save` never, `clientRepository.findById` never, and `verifyNoInteractions(stockrecordService)`. I read lines 233–405 of SBS: no write precedes the guard. Mutants: guard deleted, `<=`→`<` KILLED (log) |
| A2 | VERIFIED | `…shouldRefuseAndLeaveDestinationAmount…`: dst amount `isEqualByComparingTo("5")`. The fixture stubs Nirwana, so the base cannot pass for the wrong reason |
| A3 | VERIFIED | split 15 < 20: no throw, `findHolders…` never |
| A4 | VERIFIED | FLA present: no throw, `findHolders…` never |
| A5 | VERIFIED | `holders()` empty → re-parented to DST_UL, `recordTransferStockUnit` called |
| A6 | VERIFIED | InOrder `findByIdForUpdate(SRC_SU)` → `findHolders…` → `findById(5L)`, plus `times(1).findById(any())`. ALLOW_ANY: `findById` never |
| A7 | VERIFIED | [5@300, 9@500] → "Replenishment order REPL-9 is in progress for this stock". [5@300, 9@300] → "REPL-5 holds this stock" |
| A8 | VERIFIED | 9 gone → names REPL-5. Both gone → proceeds, InOrder `findById(9)` then `(5)`. Code: `.orElse(null)` then `continue` |
| A9 | VERIFIED | the 8-arg and 9-arg overloads both refuse; the delegations pass `ReplenHoldPolicy.REFUSE` |
| A10 | VERIFIED | ListAppender: one `REPLEN_HELD_DISPLACED` containing `REPL2@500`, not containing `REPL1`; ids `[2]`; null orderNumber names both, no NPE. Code: `!Objects.equals(h.getNumber(), orderNumber)` |
| A11 | VERIFIED | `REPLEN_HELD_REFUSED` + `REPL-5` captured. Code: `LOG.warn("REPLEN_HELD_REFUSED su={} ul={} code={} holder={}@{}", …)` before the throw |
| A12 | VERIFIED | `OptionalSafetyArchTest` 1/0 with store line 38 deleted |
| A13 | VERIFIED | `ReplenHoldPolicyCallerArchTest` 2/0: `getAccessesToSelf()` on the 10-arg signature, SBS excluded, equality to the 4 decided methods once each, and non-vacuity ≥ 4 |
| A14 | VERIFIED | `StockunitBusinessServiceReplenLockFenceArchTest` 4/0, including the `48387af8` supertype-reference self-test. Production SBS calls only `findHoldersByStateLessThanAndStockunitIdOrderById` and `findById` |

### Fix A: opt-ins and heal

| # | Status | Evidence |
|---|---|---|
| A15 | VERIFIED | `MobileReplenishServiceUnitTest:1131` "the finish calls the policy overload with ALLOW_ANY and its own order number" (128/0 in class) |
| A16 | VERIFIED | `PickingorderBusinessServiceUnitTest$Sbdev3755ConfirmPickOptIn` 2/0: ALLOW_ANY, and `requestIfDisplaced(outcome, itemdataId)` |
| A17 | VERIFIED | `StockunitServiceUnitTest:2955/2969/2981`: Damaged → ALLOW_ANY + `verify(trigger).requestIfDisplaced(same(outcome), …)`; #11 stays on the 8-arg overload |
| A18 | VERIFIED | `UnitloadServiceUnitTest:2073` ALLOW_ANY verify; `:2090` reflection, `doesNotContain(ReplenishmentMaintenanceTrigger.class)` with a non-empty-constructor control. The `setLockDamaged` `times(1)` half is the pre-existing `StockunitServiceUnitTest$SetLockDamagedExtended#transfersEntireUnitloadWhenAmountEqualsTotal` (`verify(replenishmentOrderMaintenanceService, times(1)).recalculateForItem(...)`), green. The gate report §161 cites it |
| A19 | VERIFIED | `ReplenishmentMaintenanceTriggerUnitTest:337/345` |
| A20 | VERIFIED | `NoBareTransferNeverRailTest` 5/0: absence outside the helper, positive control inside it, planted shapes, a non-offender, and the floor. `TransferVerifications` uses bare `any()` and `anyBoolean()` on all three overloads. The behavioural pin `finish_rejectsDestinationScopedToAnotherClient` is green |

### Fix B

| # | Status | Evidence |
|---|---|---|
| B1 | VERIFIED | `$MultiHolder` 9/0: ascending InOrder lock, both re-pointed, I-1 fields unchanged, `findById` and `findByStateLessThanAndStockunitId` never |
| B2 | **PARTIAL** | The AC text is met: `…shouldRefuseBeforeAnyLock_whenProjectedHolderStarted`, message names REPL-9, `findByIdForUpdate` never. **However**, §11 Ar L-1 also folds the vanished-row fallback into "AC A8, **B2**" ("if that row is gone, try the next blocking id", §5 B.2), and no Fix B test pins it. Probe M2 (`findById(...).orElseThrow()` in the pre-check) **survived** 136/0 |
| B3 | VERIFIED | 800 under lock → skipped; redirected to SU 4242 → skipped; projected 300 but 500 under lock → throws, and `r5.getRequestedlocationId()` is still 100 |
| B4 | VERIFIED | Reassign: InOrder lock 5, lock 9, then the SU; SU lock `times(1)`; cancel both when there is no candidate |
| B5 | VERIFIED | `locationMove_twoProcessableHolders_repointsBoth` green. The base red, `IncorrectResultSizeDataAccessException` by type, is gate-run evidence (`tdd-gate-baseline.md`); I did not re-run it |
| B6 | VERIFIED | `laneMove_twoHolders_noCandidate_cancelsBoth` green |
| B7 | VERIFIED | `laneMove_twoHolders_bothRedirected_releaseOwnShares` green. Code: `Share share = shareOf(order, lockedSource)` inside the loop. The upfront-share equivalent mutant is recorded in `implementation-log.md` (see Gaps: the plan wanted it in `fix1-review-code.md`) |
| B8 | VERIFIED | Latch design; polls `pg_stat_activity … wait_event_type = 'Lock' AND ? = ANY(pg_blocking_pids(pid))`; asserts `bWaitedOnA` then no 40P01. No `@Tag`, so it ran under `-Pci`. The positive control fired in both of my runs |
| B9 | VERIFIED | `ReplenishmentIdProjectionContractUnitTest` 7/0: `doesNotContain("findIdByStateLessThanAndStockunitId/2")` and `List` return pinned |
| B10 | VERIFIED | `FindByStateLessThanAndStockunitIdNoMainCallerArchTest` 2/0 |

### Fix C

| # | Status | Evidence |
|---|---|---|
| C1 | VERIFIED | `SdrUncalledSurfaceNotExportedContextTest:393` adds `Withdrawn(…ReplenishorderRepository.class, "findByStateLessThanAndStockunitId")`; 3/0 |

### E2E: `TransferStockReplenHoldGuardIT` (5/0)

| # | Status | Evidence |
|---|---|---|
| E1a | VERIFIED | two tests: refusal names the order; X's UL is unchanged, with no new SU and no stockrecord |
| E1b | VERIFIED | half move succeeds, replen untouched |
| E1c | VERIFIED | `fulfillMultipleUnitLoads_shouldFinishOrder_whenItMovesItsOwnHeldStockUnit` |
| E1d | VERIFIED | sole-SU whole-container route re-points and does not refuse |

## §10 decisions

| Decision | Status | Evidence |
|---|---|---|
| D1: narrow branches only | VERIFIED | `displacing = fixLocationAssignment == null && sourceStockunit.getAmount().compareTo(amount) <= 0`, placed after FLA resolution and above the placeholder block. Splits pass (A3, E1b) |
| D2: pick confirm opts in, WARN + after-commit heal | VERIFIED | Site #5 above. The WARN is emitted inside SBS |
| D3: damage #10 heals, #12 relies on `setLockDamaged` | VERIFIED | Sites #10 and #12. The SBDEV-2033 comment is amended with the plan's wording: "Except when a damage move displaced an active holder (SBDEV-3755 D3), after commit. Since SBDEV-3622 a release to 0 cancels the holder, so this does not re-reserve a released hold." (StockunitService:651–652) |
| D4: multi-holder fix + `exported = false` | VERIFIED | Fix B and Fix C rows |
| Exactly four opt-ins | VERIFIED | grep census (4 `ALLOW_ANY` literals) and A13 equality |
| WARN tokens | VERIFIED | `REPLEN_HELD_REFUSED su={} ul={} code={} holder={}@{}` and `REPLEN_HELD_DISPLACED su={} ul={} code={} holders={}` (rendered `NUMBER@state`), both as written in §5 A.4/A.5 |

## The three reported deviations

1. **New class `MovedStockUnitHolders`: ACCEPT.**
   - **Shape:** it is `final`, package-private, has a private constructor, and exposes one `static lockForMove(repo, suId)`.
   - **DI and lock graph:** no bean, so no DI edge and no new lock edge.
   - **Behaviour matches §5 B.1–B.4 and B.7 step for step:**
     - projection;
     - pre-check on projected state with `findById`, where a present row throws and a vanished row continues;
     - ascending `findByIdForUpdate`, keeping a row only if `state < FINISHED` and it is bound to the SU;
     - re-check under lock, first by id.
   - **Why it is better than the plan:** it removes the drift risk of two copies of the lock-order logic. This is the risk §5 B's heading ("both services, same prefix") is about.
   - **Coverage:** both services' unit tests and B5–B8 exercise it.
   - **Action:** add `MovedStockUnitHolders` to the plan's §6 production list (documentation only). PIT already covers it (10/10 per the log).

2. **A holder row vanished at lock is skipped, not thrown: CONSISTENT with the plan, but UNTESTED.**
   - **Consistent:** §5 B.7 says "Act on the locked set. A holder that disappeared after the probe is skipped", and Choice 2A gives the reason: a move is not a consented cut, and the cron also skips rows that are gone. The skip is exactly "act on the locked set".
   - **Old behaviour:** at c6f0cbc0 a vanished row hit `orElseThrow(EntityNotFoundException)`. That was single-holder code that the plan explicitly replaces.
   - **Untested:** nothing pins the skip. Probe M1 (lock read → `orElseThrow()`, the old behaviour) survived all 136 Fix B unit tests. Probe M2 (the §5 B.2 pre-check fallback) also survived.
   - **Fix:** add two unit tests to `ReplenishmentOrderSourceSyncServiceTest$MultiHolder`:
     - `findByIdForUpdate(9)` empty → 5 re-pointed, no throw;
     - projected 9@500 with `findById(9)` empty, and 5@300 → no refusal, both locked.
   - Each test must be shown red under M1 and M2 respectively.

3. **The story-4 commit (`8aaf9f08`) leaves caller-test reds that story 5 (`da550f32`) fixes: Low, fix before push.**
   - **Why bisect is not hurt much:** the range is already non-green by design. Gate commit `7b59ae5c` is "red on purpose", and `c23185d5` is still red on A13 and E1c. Bisect will not land a clean commit inside `7b59ae5c..da550f32` anyway.
   - **What differs at `8aaf9f08`:** existing, pre-SBDEV-3755 tests are red there (11 F + 28 E per the log). A later bisect over `develop` would see that as a regression. It also contradicts plan §7.2 step 5 ("In the same commit: migrate the opt-in-path stubs and verifies").
   - **Fix:** nothing is pushed yet, so either fold `da550f32` into `8aaf9f08` now, or squash-merge the PR. Squashing per merge-base is safe; see the memory note on soft-reset squash.

## Gaps

- **Fix B vanished-row fallbacks are untested** (B2 PARTIAL; Deviation 2). Risk: low to medium. A later refactor that restores `orElseThrow` would turn a benign race into a 500 on Move Unit Load, and no test would notice. Close with the two tests above.
- **`fix1-review-code.md` does not exist yet.** `review-code.md` in this folder reviews PR #510 (`05e8c27c`), not Fix 1. §7.2 step 7.4/7.5 (code-review lane, fix every finding) is still pending. B7's equivalent-mutant note is in `implementation-log.md`, but the plan wants it in `fix1-review-code.md`. Risk: process. Next phase.
- **Baseline location.** The step-0 baseline is recorded in `tdd-gate-baseline.md` (8264/842, empty failing set), not in a plan *Implementation Status* section. Risk: low. Fold it in when the plan doc is updated.
- **Plan §6 file list omits `MovedStockUnitHolders`.** Risk: documentation only.
- **Not re-run by this lane:** the 43 hand mutants, PIT, and B5's base-red. Attribution comes from the implementer's log. The two mutants I did run are listed above.

## Recommendation

**APPROVE for conformance.**
- The build matches the plan on every §0 row, every decided policy, every WARN token and every AC but one.
- Compile, the gate classes, the ITs and the full `-Pci` run are green with an empty failing set.
- Before the review lane, add the two Fix B vanished-row tests and fold story 5 into story 4.
