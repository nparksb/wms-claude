---
ticket: SBDEV-3547
pr: B (fail-closed fence)
kind: implementation-report
date: 2026-09-28
---

# SBDEV-3547 PR-B — implementation report

- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3547-b`, branch `bugfix/SBDEV-3547-b-fence`, gate commit `346cbee7`.
- **Commit:** `09306eed` "SBDEV-3547 PR-B: fence cancelled stock against hand moves (B-1..B-3)" on top of gate `346cbee7`. Not pushed. Tree clean after commit (no untracked files; ArchUnit store untouched).
- **Status:** implementation done, all gate tests green, full suite green, every mutant killed. **Not yet done:** the independent review lane (floor item) — this executor did not self-approve; the orchestrator owns it.

## Diff stat (`git show --stat 09306eed`)

```
 .../aim_ai/wms/service/CustomerorderService.java   | 10 +++-
 .../wms/service/PickingorderBusinessService.java   |  4 +-
 .../net/aim_ai/wms/service/UnitloadService.java    | 28 +++++++++++
 .../service/mobile/MobileMoveUnitloadService.java  | 56 ++++++++++++++++++++++
 .../net/aim_ai/wms/util/CancelLockRelease.java     | 19 ++++++--
 .../unit/service/CustomerorderServiceUnitTest.java | 25 +++++-----
 .../service/MoveSourceLockComparisonRailTest.java  |  8 +++-
 .../PickingorderBusinessServiceUnitTest.java       |  3 +-
 8 files changed, 133 insertions(+), 20 deletions(-)
```

## Per-site changes (paths under `src/main/java/net/aim_ai/wms/`)

**B-1 `util/CancelLockRelease.java`** — real behaviour + javadoc per plan ("a cancel never lowers PICKED_FOR_GOODSOUT, the fence a pending reversal relies on; other locks belong to other processes and reset as before"):
```java
if (su == null) { return; }
if (!Integer.valueOf(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT).equals(su.getEntityLock())) {
    su.setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED);
}
```
- **C1** `service/CustomerorderService.java:1043` `toteStock.forEach(CancelLockRelease::releaseUnlessGoodsOut);` — `saveAll(toteStock)` on the next line unchanged (unconditional).
- **C2** `service/PickingorderBusinessService.java:703` `stockUnits.forEach(CancelLockRelease::releaseUnlessGoodsOut);` — `saveAll` unchanged.
- **C3** `service/CustomerorderService.java:493` inside the existing per-row lambda: `CancelLockRelease.releaseUnlessGoodsOut(stockUnit);` then the unchanged `stockunitRepository.save(stockUnit);`.
- **C4** `service/CustomerorderService.java:526-528` unchanged behaviour, comment added: "Deliberately clears 100: this arm writes no cancellation-log row, so a kept 100 would be a strand with no Cancellation-screen entry, no waive and no removeLock route. See SBDEV-3547 P1."

**B-2 `service/mobile/MobileMoveUnitloadService.java`**
- Calls: `:488` (inbound-pattern branch, inside `if (!dto.isMoveStock())`, right after `assertSourceCarrierNotOnTruck`, before `createUnitload` `:495`) and `:516` (existing-pallet branch, right after `assertSourceCarrierNotOnTruck`, before `assertPalletNotAssignedToGate` / `transferUnitLoadToCarrier`). Both pass `stockUnitList` (read at `:364` under the source `FOR UPDATE`).
- Method (`:570`):
```java
for (Stockunit su : stock) {
    if (Integer.valueOf(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT).equals(su.getEntityLock())) {
        if (!isToteType(source)) return;
        throw new BusinessException("Tote " + source.getLabelid() + " holds stock unit " + su.getId()
            + " locked=" + LockRefusalMessages.describe(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT)
            + " and cannot go onto a carrier" + LockRefusalMessages.goodsOutHint(source.getLabelid()));
    }
}
```
- `isToteType`: `typeId == null` → `LOG.warn("SBDEV-3547 carrier-arm fence: unit load {} has no type id; treated as not a Tote", …)`, false, no `findById`; missing row → WARN, false; else `WmsConstants.UNIT_LOAD_TYPE_TOTE.equals(type.getName())`.
- Javadoc cross-refs `SourceLockGuard`'s javadoc and `UnitloadBusinessServiceUnitTest.TransferUnitLoadToLocationSourceLockAsymmetry` (by name, not line: PR-A shifted the plan's `:69-73` / `:903-907` numbers) and names its rail EXEMPT entry.
- Rendered text: `Tote TOTE-0042 holds stock unit 9001 locked=100 (Picked) and cannot go onto a carrier. Stock on TOTE-0042 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before moving it.`

**B-3 `service/UnitloadService.java`**
- Private check `assertNoGoodsOutStock(Unitload, List<Stockunit>)` (`:584`):
```java
for (Stockunit su : stock) {
    if (Integer.valueOf(BusinessObjectLockState.PICKED_FOR_GOODSOUT).equals(su.getEntityLock())) {
        throw new BusinessException("Container " + originalLabel(unitLoad)
            + " holds stock reserved for goods-out (Picked, 100)"
            + LockRefusalMessages.goodsOutHint(originalLabel(unitLoad)));
    }
}
```
- `deleteUnitLoad`: `assertNoGoodsOutStock(unitLoad, stockUnitList);` right after `stockUnitList` is read (`:621`), i.e. after the To-Delete and child checks and before the stock loop / any Nirwana send.
- `deleteUnitLoadRecursivePreRun` top branch (`:455`), after the existing fixed-assignment refusal: `assertNoGoodsOutStock(unitLoad, stockunitRepository.findByUnitloadIdIn(unitLoadIdList));` — the added `findByUnitloadIdIn` call the gate report flagged (existing repository method, no new persistence surface).

**Rail** `src/test/.../unit/service/MoveSourceLockComparisonRailTest.java` EXEMPT +2 → 10:
- `MobileMoveUnitloadService.java#assertNotFencedToteOntoCarrier :: (Integer.valueOf(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT).equals(su.getEntityLock()))` — "D1′ carrier-arm fence; single-value refusal by decision"
- `UnitloadService.java#assertNoGoodsOutStock :: (Integer.valueOf(BusinessObjectLockState.PICKED_FOR_GOODSOUT).equals(su.getEntityLock()))` — "D3′ destroy guard; single-value refusal by decision"

## §7.3 flips (same commit)

| Test | Change |
|---|---|
| `CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown` AC-1 (`:4001`) | rewritten as its inverse and renamed `cancelOrder_shouldClearPickedForGoodsoutOnToteStock_whenSuccessBranchHasTote` → `cancelOrder_shouldKeepPickedForGoodsoutOnToteStock_whenSuccessBranchHasTote`; both SUs now asserted `PICKED_FOR_GOODSOUT` |
| `CustomerorderServiceUnitTest$CancelOrderRapidPickingScenarios.shouldSkipRapidPickingCleanupWhenNotStarted` (`:2379`) | `rapidStock` asserted `PICKED_FOR_GOODSOUT` (was `NOT_LOCKED`) |
| `PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended.shouldCleanUpWithStockUnitsAndPositions` (`:1593`) | `stockUnit1` asserted `PICKED_FOR_GOODSOUT`; `:1594` `stockUnit2` ON_HOLD → `NOT_LOCKED` unchanged |

**No other test flipped.** Second instrument: a testcase-name set diff between a fresh `mvn -o clean test` of `35c3428b` (detached scratch worktree, 10:15 KST, adjacent in time, since removed) and this branch shows exactly 1 removed name (the renamed AC-1 test) and 20 added (the renamed AC-1 + the 19 gate unit tests).

## Full-suite numbers

| Run | Run | Fail | Err | Skip |
|---|---|---|---|---|
| Baseline `35c3428b` (develop), `mvn -o clean test`, 10:15 KST | 7377 | 0 | 0 | 1 |
| This branch, `mvn -o clean test`, 09:56 KST | **7396** | **0** | **0** | **1** |

7377 + 19 gate unit tests = 7396, exact. ⚠ The brief's baseline figure "7291 run" is stale: develop `35c3428b` measures 7377 today.

## Deviations from the plan

1. **Message punctuation.** The plan writes `" and cannot go onto a carrier." + goodsOutHint(...)` and `"… (Picked, 100)." + goodsOutHint(...)`, but `LockRefusalMessages.goodsOutHint` already opens with `". "` (its javadoc: "opens with \". \" to end the refusal's own sentence"), so the literal plan text renders `carrier.. Stock on …`. I dropped the trailing `.` from both prefixes; the rendered text ends each sentence once. All gate assertions are substring checks and are unaffected.
2. **Pre-run check placement.** Placed after the existing fixed-assignment refusal in the top branch, so that existing refusal keeps precedence (the gate stub for it is `lenient`, "may run before or after").
3. **Javadoc cross-refs by name, not line.** PR-A moved `SourceLockGuard:69-73` and `UnitloadBusinessServiceUnitTest:903-907`; the javadoc cites `SourceLockGuard`'s javadoc and `UnitloadBusinessServiceUnitTest.TransferUnitLoadToLocationSourceLockAsymmetry`.
4. **No count literal in the rail.** The brief asked to update entry-count literals; the rail has none (`hasSize(EXEMPT.size())`), so nothing changed beyond the two entries.
5. **Mutation harness.** `../mut3547/mut*.py` does not exist in the scratchpad (no `mut3547` directory anywhere under `/private/tmp/claude-503`), so the harness was written fresh to the brief's spec (`scratchpad/mut3547b/mut.py`, `mut_it.py`; per-mutant logs in `mut3547b/logs/`). Restore uses touch rather than preserving the old mtime, because an old mtime would let the compiler keep the mutant's newer `.class` file.

## Gate results (final, post-mutation re-run 10:2x KST)

`mvn -o test -Dtest='CancelLockReleaseUnitTest,CustomerorderServiceUnitTest,PickingorderBusinessServiceUnitTest,MobileMoveUnitloadServiceUnitTest,UnitloadServiceUnitTest,NeverMatcherNullBlindnessArchTest,MoveSourceLockComparisonRailTest'` → **429 run / 0 fail / 0 err** (the gate report's 429 with 8 failures, now 0). IT: 2/2 green (09:49:24 KST failsafe XML); rail 10 EXEMPT, 0 unlisted, 0 stale.

## Progress log
- B-1, B-2, B-3 source edits applied; rail EXEMPT +2 (10 total). Before the EXEMPT edit, the rail reported exactly the two new sites as UNLISTED (`MobileMoveUnitloadService.java#assertNotFencedToteOntoCarrier`, `UnitloadService.java#assertNoGoodsOutStock`) and nothing else — compile clean.
- The rail carries no entry-count literal (checked with `git grep -nE '[^0-9.]8[^0-9]|eight'` on the file: 0 hits in text); `hasSize(EXEMPT.size())` derives it, so no count literal needed updating.
- §7.3 flips applied (CustomerorderServiceUnitTest AC-1 test renamed/inverted to `cancelOrder_shouldKeepPickedForGoodsoutOnToteStock_whenSuccessBranchHasTote`; `shouldSkipRapidPickingCleanupWhenNotStarted` rapidStock → 100; `PickingorderBusinessServiceUnitTest.shouldCleanUpWithStockUnitsAndPositions` stockUnit1 → 100, stockUnit2 ON_HOLD → 0 unchanged).
- Gate unit run 09:47 KST: 9 classes (5 gate classes + both rails + MobileMoveUnitloadServiceTest + UnitloadBusinessServiceUnitTest) **508 run / 0 fail / 0 err**; every gate method present once in the fresh XML.
- Gate IT 09:49:24 KST (failsafe XML): `CancelPreservesGoodsOutFenceIntegrationTest` **2 run / 0 fail / 0 err**.
- `mvn -o clean compile` → BUILD SUCCESS. `mvn -o clean test` (finished ~09:56 KST, 5:42 min) → **7396 run / 0 fail / 0 err / 1 skipped**, BUILD SUCCESS.

## Mutation table (hand mutants, harness `scratchpad/mut3547b/mut.py`, run 2026-09-28 ~10:00–10:25 KST)

Harness: back up to /tmp, assert every anchor matches exactly once, apply, `mvn -o test -Dtest=<selector>`, restore by copy + `os.utime` (touch, so the compiler recompiles) + `filecmp` byte check. No git checkout/restore/stash. No constant mutants, so no `mvn clean` needed. `fresh xml` = surefire XML files newer than the run start.

| # | Mutant | Selector | Run/Fail/Err | fresh xml | Red line(s) | Verdict |
|---|---|---|---|---|---|---|
| M01 | B-1 CancelLockRelease unconditional (drop the 100 skip) | `CancelLockReleaseUnitTest,CustomerorderServiceUnitTest,PickingorderBusinessServiceUnitTest` | 244/7/0 | 66 | `CustomerorderServiceUnitTest$CancelOrderRapidPickingScenarios.shouldSkipRapidPickingCleanupWhenNotStarted:2380` [stock unit 9101: the rapid-picking cancel teardown lowered PICKED_FOR_GOODSOUT (100), the <br>`CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.cancelOrder_keepsPickedForGoodsout_resetsOtherLocks:4032` [stock unit 9001: a cancel must not lower PICKED_FOR_GOODSOUT (100), the fence the pending <br>`CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.cancelOrder_shouldKeepPickedForGoodsoutOnToteStock_whenSuccessBranchHasTote:4014` [stock unit 9001: cancelOrder's success branch lowered PICKED_FOR_GOODSOUT (100), the fence<br>`CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.forceCancelOrder_belowPacked_keepsPickedForGoodsout:4228` [stock unit 9001: a cancel must not lower PICKED_FOR_GOODSOUT (100), the fence the pending <br>`PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended.cleanUpCancelledOrder_keepsPickedForGoodsout:1649` [a cancel must not lower PICKED_FOR_GOODSOUT (100), the fence the pending reversal relies o<br>`PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended.shouldCleanUpWithStockUnitsAndPositions:1594`<br>`CancelLockReleaseUnitTest.pickedForGoodsout_isKept:39` | **KILLED** |
| M02 | B-1 CancelLockRelease skip-all (never reset) | `CancelLockReleaseUnitTest,CustomerorderServiceUnitTest,PickingorderBusinessServiceUnitTest` | 244/7/0 | 66 | `CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.cancelOrder_keepsPickedForGoodsout_resetsOtherLocks:4035` [stock unit 9002: ON_HOLD (104) belongs to another process and still resets]<br>`CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.forceCancelOrder_belowPacked_keepsPickedForGoodsout:4231` [stock unit 9002: ON_HOLD (104) belongs to another process and still resets]<br>`PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended.cleanUpCancelledOrder_keepsPickedForGoodsout:1652` [ON_HOLD (104) belongs to another process and still resets]<br>`PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended.shouldCleanUpWithStockUnitsAndPositions:1595`<br>`CancelLockReleaseUnitTest.nullLock_releasedToNotLocked:49`<br>`CancelLockReleaseUnitTest.onHold_releasedToNotLocked:79`<br>`CancelLockReleaseUnitTest.qualityFault_releasedToNotLocked:69` | **KILLED** |
| M03 | B-1 CancelLockRelease equals -> == (NPE on null lock) | `CancelLockReleaseUnitTest` | 6/0/1 | 1 | `CancelLockReleaseUnitTest.nullLock_releasedToNotLocked:47` | **KILLED** |
| M04 | C1 revert to unconditional NOT_LOCKED lambda | `CustomerorderServiceUnitTest` | 147/3/0 | 40 | `CustomerorderServiceUnitTest$CancelOrderRapidPickingScenarios.shouldSkipRapidPickingCleanupWhenNotStarted:2380` [stock unit 9101: the rapid-picking cancel teardown lowered PICKED_FOR_GOODSOUT (100), the <br>`CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.cancelOrder_keepsPickedForGoodsout_resetsOtherLocks:4032` [stock unit 9001: a cancel must not lower PICKED_FOR_GOODSOUT (100), the fence the pending <br>`CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.cancelOrder_shouldKeepPickedForGoodsoutOnToteStock_whenSuccessBranchHasTote:4014` [stock unit 9001: cancelOrder's success branch lowered PICKED_FOR_GOODSOUT (100), the fence | **KILLED** |
| M05 | C2 revert to unconditional NOT_LOCKED lambda | `PickingorderBusinessServiceUnitTest` | 91/2/0 | 25 | `PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended.cleanUpCancelledOrder_keepsPickedForGoodsout:1649` [a cancel must not lower PICKED_FOR_GOODSOUT (100), the fence the pending reversal relies o<br>`PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended.shouldCleanUpWithStockUnitsAndPositions:1594` (both: `expected: 100`) | **KILLED** |
| M06 | C3 revert per-row lambda to NOT_LOCKED | `CustomerorderServiceUnitTest` | 147/1/0 | 40 | `CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.forceCancelOrder_belowPacked_keepsPickedForGoodsout:4228` [stock unit 9001: a cancel must not lower PICKED_FOR_GOODSOUT (100), the fence the pending  | **KILLED** |
| M07 | C4 apply the skip at the PACKED arm | `CustomerorderServiceUnitTest` | 147/1/0 | 40 | `CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.forceCancelOrder_packedArm_stillClearsParcelStock_noReversalRowExists:4270` [the PACKED arm has no reversal row to fence for, so it must keep clearing 100] | **KILLED** |
| M08 | B-2 delete the existing-pallet (:512) call | `MobileMoveUnitloadServiceUnitTest` | 79/1/0 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_carrierArm_refusesToteAtPickedForGoodsout:2279` (`Expecting code to raise a throwable`) | **KILLED** |
| M09 | B-2 delete the inbound-pattern (:485) call | `MobileMoveUnitloadServiceUnitTest` | 79/1/0 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload:2301` (`NeverWantedButInvoked: unitloadService.createUnitload(`) | **KILLED** |
| M10 | B-2 move the inbound call after createUnitload | `MobileMoveUnitloadServiceUnitTest` | 79/1/0 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload:2301` (`NeverWantedButInvoked: unitloadService.createUnitload(`) | **KILLED** |
| M11 | B-2 also check on the location arm (:424) | `MobileMoveUnitloadServiceUnitTest` | 79/0/1 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_locationArm_stillRelocatesToteAt100:2312` | **KILLED** |
| M12 | B-2 check in scanUnitLoad | `MobileMoveUnitloadServiceUnitTest` | 79/0/1 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanUnitLoad_toteAt100_notRefused:2325` | **KILLED** |
| M13 | B-2 drop isToteType (refuse any type) | `MobileMoveUnitloadServiceUnitTest` | 79/0/2 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_carrierArm_stillMovesPackageAtPickedForGoodsout:2336`<br>`MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_carrierArm_toteTypeIdNull_proceedsWithWarn:2347` | **KILLED** |
| M14 | B-2 remove the typeId null check | `MobileMoveUnitloadServiceUnitTest` | 79/1/0 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_carrierArm_toteTypeIdNull_proceedsWithWarn:2351` (`NeverWantedButInvoked: unitloadTypeRepository.findById(<any>)`) | **KILLED** |
| M15 | B-2 look the type up unconditionally | `MobileMoveUnitloadServiceUnitTest` | 79/1/0 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_carrierArm_noTypeLookupWhenNo100:2363` (`NeverWantedButInvoked: unitloadTypeRepository.findById(<any>)`) | **KILLED** |
| M16 | B-2 drop the goods-out hint from the message | `MobileMoveUnitloadServiceUnitTest` | 79/2/0 | 12 | `MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_carrierArm_refusesToteAtPickedForGoodsout:2282`<br>`MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload:2297` (`Expecting throwable message … to contain "Cancellation screen"`) | **KILLED** |
| M17 | B-3 move the deleteUnitLoad check after the loop | `UnitloadServiceUnitTest` | 89/1/0 | 15 | `UnitloadServiceUnitTest$DeleteUnitLoad.deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend:1479` (`NeverWantedButInvoked: stockunitBusinessService.sendStockUnitToNirvana(`) | **KILLED** |
| M18 | B-3 drop the pre-run check | `UnitloadServiceUnitTest` | 89/1/0 | 15 | `UnitloadServiceUnitTest$DeleteUnitLoadRecursivePreRun.deleteUnitLoadRecursivePreRun_refusesWhenChildHolds100:933` (`Expecting code to raise a throwable`) | **KILLED** |
| M19 | B-3 drop the goods-out hint from the message | `UnitloadServiceUnitTest` | 89/2/0 | 15 | `UnitloadServiceUnitTest$DeleteUnitLoad.deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend:1477`<br>`UnitloadServiceUnitTest$DeleteUnitLoadRecursivePreRun.deleteUnitLoadRecursivePreRun_refusesWhenChildHolds100:936` (`Expecting throwable message`) | **KILLED** |
| M20 | rail: remove the B-2 check (its if) | `MoveSourceLockComparisonRailTest` | 13/1/0 | 3 | `MoveSourceLockComparisonRailTest.everySingleValueSourceLockRefusalInScopeIsExempt:153` [SBDEV-3547 A4 rail. A single-value source-lock refusal (== / equals against one lock, with (`STALE key MobileMoveUnitloadService.java#assertNotFencedToteOntoCarrier :: … matches no site`) | **KILLED** |
| M21 | rail: remove the B-3 check (its if) | `MoveSourceLockComparisonRailTest` | 13/1/0 | 3 | `MoveSourceLockComparisonRailTest.everySingleValueSourceLockRefusalInScopeIsExempt:153` [SBDEV-3547 A4 rail. A single-value source-lock refusal (== / equals against one lock, with (`STALE key UnitloadService.java#assertNoGoodsOutStock :: … matches no site`) | **KILLED** |

**All 21 unit-lane hand mutants KILLED**, each by the test(s) the §7.1 "Mutant → must go red" column names (plus, for M01/M02/M04/M05, the §7.3-flipped tests). M13 additionally kills `toteTypeIdNull_proceedsWithWarn` (a null-typed source is then refused too). After the run the tree was byte-identical to the pre-run state (harness filecmp assertions; `git status` unchanged, 8 modified files).

| # | Mutant | Selector | Result | Red line | Verdict |
|---|---|---|---|---|---|
| M22 | IT: revert C1 (`toteStock.forEach(su -> su.setEntityLock(NOT_LOCKED))`) | `mvn -o verify -Dit.test=CancelPreservesGoodsOutFenceIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` | failsafe XML fresh, `tests="2" failures="2"` | `cancelKeepsTheFence_handMoveRefused_completeReleases:263->cancelAndAssertTheFenceHolds:327 [step 2: entity_lock expected 100, was 0]`; `cancelKeepsTheFence_waiveReleases:293->…:327 [step 2: entity_lock expected 100, was 0]` | **KILLED** |

## PIT (JDK 21.0.8, pitest-maven 1.19.1)

`mvn -o org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.util.CancelLockRelease -DtargetTests=net.aim_ai.wms.unit.util.CancelLockReleaseUnitTest` (after `mvn -o test-compile`), 10:09 KST:

| Status | Line | Mutator |
|---|---|---|
| KILLED | 28 | negated conditional (`su == null`) |
| KILLED | 31 | negated conditional (the `PICKED_FOR_GOODSOUT` skip) |
| KILLED | 32 | removed call to `Stockunit::setEntityLock` |

3/3 killed, 0 survived, 0 no-coverage. Line coverage 5/7: the 2 uncovered lines are the private constructor.

## Review fix round 1

- **Commit:** `d714a968` "SBDEV-3547 PR-B: address review (M1-M4, L1-L6, L9, L10)" on `09306eed`. Not pushed. `git status` clean after commit; ArchUnit store untouched (no file under it in the diff). 12 files, +80/−32.

### Per-finding changes (paths under `src/`)

- **M1** `main/.../util/SourceLockGuard.java` (javadoc of `assertSourceUnlockedForContainerRelocation`, the MMU bullet) + `test/.../UnitloadBusinessServiceUnitTest.java` (`TransferUnitLoadToLocationSourceLockAsymmetry` javadoc): added "Since SBDEV-3547 D1′, Move Unit Load additionally refuses a Tote-type source carrying PICKED_FOR_GOODSOUT stock on the carrier arm only (`MobileMoveUnitloadService.assertNotFencedToteOntoCarrier`); relocation to a location … is unchanged." MMU javadoc reworded to what is now true: "The rule is recorded, next to Move Unit Load's ON_HOLD-alone relocation policy, in `SourceLockGuard.assertSourceUnlockedForContainerRelocation`'s javadoc and in `UnitloadBusinessServiceUnitTest.TransferUnitLoadToLocationSourceLockAsymmetry`."
- **M2** `main/.../service/UnitloadService.java`: `assertNoGoodsOutStock(Unitload root, List<Unitload> containers, List<Stockunit> stock)`; the holder is `containers.stream().filter(ul -> Objects.equals(ul.getId(), su.getUnitloadId())).findFirst().orElse(root)` and the message uses `originalLabel(holder)`. Pre-run passes `unitLoadList` (the collected list); `deleteUnitLoad` passes `List.of(unitLoad)`. Method name and the condition text `(Integer.valueOf(BusinessObjectLockState.PICKED_FOR_GOODSOUT).equals(su.getEntityLock()))` unchanged, so the rail EXEMPT entry needed no text change.
- **M3** `test/.../UnitloadServiceUnitTest.deleteUnitLoadRecursivePreRun_refusesWhenChildHolds100`: all four `lenient()` removed (the unused `findById(2L)` stub deleted; the class is `STRICT_STUBS`); added `ArgumentCaptor<Collection<Long>>` on `findByUnitloadIdIn` with `.as("unit-load ids the goods-out fence reads").containsExactlyInAnyOrder(1L, 2L)`, and `.hasMessageStartingWith("Container UL-CHILD-001 cannot be deleted: it holds stock unit 20")`.
- **M4** `main/.../service/CustomerorderService.java` C1 comment: "owes the clear" → "owes the teardown (Clearing move, then a lock reset of every lock except PICKED_FOR_GOODSOUT, which SBDEV-3547 B-1 keeps as the reversal fence)"; "then the stock-lock clear" → "then the stock-lock release".
- **L1** `main/.../service/CancellationReversalService.java`: the stale "Precedent: cleanUpCancelledOrder does the same clear …" paragraph replaced with "Since SBDEV-3547 B-1 no cancel path lowers PICKED_FOR_GOODSOUT (CancelLockRelease keeps it as the reversal fence) except forceCancelOrder's PACKED arm, which writes no cancellation-log row and so owes no reversal. This release and the waive are therefore the only exits from 100 for stock a cancellation left behind." **⚠ Corrected in round 2 (N1): that last sentence was false** — the BOL close (`BillofladingService` closeBOL / finishTransfer bulk `UPDATE Stockunit s SET s.entityLock = :lock …`) also overwrites 100 when the pallet ships, and `reportPendingReversalsOnShippedPallets` only reports it. The comment now says "the only OPERATOR exits", with the BOL close named as the exception.
- **L2** `main/.../util/LockRefusalMessages.java`: new overload `goodsOutHint(String label, String verb)`; the one-arg `goodsOutHint(label)` now delegates with `"moving"`, so every PR-A caller renders byte-identically (`LockRefusalMessagesUnitTest` unchanged, 4/4 green). Delete refusal reworded (see before/after below) and uses `goodsOutHint(label, "deleting")`. No existing test asserted the old exact prefix (grep for "holds stock reserved" / "before moving it" in `src/test`: 0 hits); the old substrings `UL-001`, `goods-out`, `Cancellation screen` all still occur in the new text, so they were kept as-is; `"Picked"` and `"before deleting it"` added.
- **L3** `main/.../service/mobile/MobileMoveUnitloadService.java`: both label uses → `UnitloadService.originalLabel(source)` (public static; `net.aim_ai.wms.service.*` already imported). Not pinned by a test (the fixture label carries no `-X-<id>` mangle; the unmangle itself is pinned by UnitloadService's SBDEV-3500 tests).
- **L4** `test/.../CustomerorderServiceUnitTest` PACKED-arm javadoc: dropped "(this class does not even mock CancellationLogService, so a write would NPE)"; now says "Pins only that this arm still resets the parcel stock's 100 to NOT_LOCKED; it does not itself prove the arm writes no log row."
- **L5** `test/.../MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence.scanDestination_carrierArm_toteTypeRowMissing_proceedsWithWarn`: type id `67399L`, `findById → Optional.empty()` (strict `when`), stock at 100; verifies `transferUnitLoadToCarrier(source, palletB, CODE_TRANSFER, …)` and `findById(67399L)` called.
- **L6** `.hasMessageContaining("Picked")` added to `scanDestination_carrierArm_refusesToteAtPickedForGoodsout`, `scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload`, `deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend`, `deleteUnitLoadRecursivePreRun_refusesWhenChildHolds100`.
- **L9** `test/.../MoveSourceLockComparisonRailTest`: `private static final String ULS = "UnitloadService.java";`, EXEMPT entry uses `ULS`.
- **L10** `test/.../CancelPreservesGoodsOutFenceIntegrationTest` javadoc: "This class mocks only `MessageService`; the base class additionally mocks `TenantHealthService` and `EndpointHealthCheck`."

### Rendered refusal text (before → after)

Delete (`deleteUnitLoad`, fixture `UL-001`, stock unit 1):
- before: `Container UL-001 holds stock reserved for goods-out (Picked, 100). Stock on UL-001 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before moving it.`
- after: `Container UL-001 cannot be deleted: it holds stock unit 1 locked=100 (Picked). Stock on UL-001 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before deleting it.`
- recursive pre-run, root `UL-001`, child `UL-CHILD-001` holds unit 20 — before: named `UL-001`; after: `Container UL-CHILD-001 cannot be deleted: it holds stock unit 20 locked=100 (Picked). Stock on UL-CHILD-001 is reserved for goods-out. …, before deleting it.`

Move Unit Load carrier arm (fixture `TOTE-0042`, stock unit 9001) — unchanged for an unmangled label:
- before/after: `Tote TOTE-0042 holds stock unit 9001 locked=100 (Picked) and cannot go onto a carrier. Stock on TOTE-0042 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before moving it.` (a retired `<orig>-X-<id>` label now renders as `<orig>`, L3).

(After-texts quoted from the mutant logs below, where AssertJ printed the actual message with one token mutated; the unmutated remainder is the live text. Before-texts are the `09306eed` source literals, not observed output.)

### Mutation table (harness `scratchpad/mut3547b/mut_rf1.py`, logs `logs-rf1/`)

| ID | Mutant | Selector | Verdict | Killing assertion (attributable) |
|---|---|---|---|---|
| R01 | M3a: pre-run reads `List.of(unitLoad.getId())` (root only) | UnitloadServiceUnitTest | KILLED 89/1 | `refusesWhenChildHolds100:942` `[unit-load ids the goods-out fence reads] Expecting actual [1L] to contain exactly in any order [1L, 2L]` |
| R02 | M2/M3b: `originalLabel(root)` instead of holder | UnitloadServiceUnitTest | KILLED 89/1 | `:933` actual `"Container UL-001 cannot be deleted…"` to start with `"Container UL-CHILD-001 …"` |
| R03 | L5: `.orElse(null)` → `.orElseThrow()` in `isToteType` | MobileMoveUnitloadServiceUnitTest | KILLED 80/0/1err | `toteTypeRowMissing_proceedsWithWarn:2363 » NoSuchElement No value present` |
| R04 | L6: MMU `describe(PICKED_FOR_GOODSOUT)` → `"100"` | MobileMoveUnitloadServiceUnitTest | KILLED 80/2 | both RED MMU tests (`:2282`, `:2298`) — message `…locked=100 and cannot go…` to contain `"Picked"` |
| R05 | L6: ULS `describe(PICKED_FOR_GOODSOUT)` → `"100"` | UnitloadServiceUnitTest | KILLED 89/2 | `deleteUnitLoad_refuses…:1482` and `refusesWhenChildHolds100:934` — to contain `"Picked"` |
| R06 | L2: `goodsOutHint(label, "deleting")` → one-arg (moving) | UnitloadServiceUnitTest | KILLED 89/1 | `deleteUnitLoad_refuses…:1483` — to contain `"before deleting it"` |

Restore verified by `filecmp` per mutant; `git status` after the run showed only the intended edits.

### Verification

- Touched classes (`UnitloadServiceUnitTest` 89, `MobileMoveUnitloadServiceUnitTest` 80, `MoveSourceLockComparisonRailTest` 13, `CustomerorderServiceUnitTest` 147, `UnitloadBusinessServiceUnitTest` 54, `PickingorderBusinessServiceUnitTest` 91, `LockRefusalMessagesUnitTest` 4 (unchanged), `SourceLockGuardUnitTest` 2, `CancellationReversalServiceUnitTest` 102, `CancelLockReleaseUnitTest` 6): all green, XMLs (incl. `$Nested`) timestamped 10:34–10:35, none stale.
- Rail: 10 EXEMPT entries (non-self-test), `everySingleValueSourceLockRefusalInScopeIsExempt` green → 0 unlisted, 0 stale.
- H2 IT `CancelPreservesGoodsOutFenceIntegrationTest`: 2/2, BUILD SUCCESS (failsafe XML 10:39).
- Full suite `mvn -o clean test`: **Tests run: 7397, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. Delta vs 7396 = +1, the new L5 test; no other test added or removed.
- Diff scan: no `lenient()`, `System.out`, TODO/HACK/FIXME, `@Disabled` or `.only` added.
- Not done here: the independent review of this round (never self-approved).

## Review fix round 2

Re-review N1–N8 against `d714a968`.

- **Commit:** `885bba83` "SBDEV-3547 PR-B: address re-review (N1-N8)" on `d714a968`. Not pushed. 9 files, +64/−19. `git status` clean after commit; ArchUnit store untouched (no file under it in the diff).

### Per-finding changes

- **N1 (Medium)** `CancellationReversalService.java` completeReversal comment. Verified first: `BillofladingService.java:690` and `:1622` are `UPDATE Stockunit s SET s.entityLock = :lock, s.version = s.version + 1 WHERE s.unitloadId IN (… carrierunitloadId IN :palletIds)`, run right after `reportPendingReversalsOnShippedPallets` (`:686`, `:1618`). Now reads:
  > This release and the waive are therefore the only OPERATOR exits from 100 for stock a cancellation left behind. The BOL close is the exception: its bulk UPDATE (BillofladingService closeBOL / finishTransfer) overwrites 100 with the shipped lock, and reportPendingReversalsOnShippedPallets only reports it, it does not fence it.

  Round-1 report L1 line annotated with the same correction (above).
- **N2 (Low)** `UnitloadService.assertNoGoodsOutStock`:
  ```java
  String label = originalLabel(holder);
  String subject = Objects.equals(holder.getId(), root.getId())
      ? "Container " + label + " cannot be deleted: it holds"
      : "Container " + originalLabel(root) + " cannot be deleted: " + label + " on it holds";
  throw new BusinessException(subject + " stock unit " + su.getId() … + LockRefusalMessages.goodsOutHint(label, "deleting"));
  ```
  Hint label stays the holder. Javadoc updated to say the root is named, plus the holder when different. Tests: the recursive pin is now `hasMessageStartingWith("Container UL-001 cannot be deleted: UL-CHILD-001 on it holds stock unit 20")` + `hasMessageContaining("Stock on UL-CHILD-001 is reserved")`; the single-container test `deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend` gained `hasMessageStartingWith("Container UL-001 cannot be deleted: it holds stock unit 1 ")`. Before this round nothing pinned the holder == root wording, so a mutant making every refusal use the two-container form would have survived; it is S03 below.
- **N3 (Low)** `LockRefusalMessages` class javadoc: the site list is gone; now "lookup-free text shared by the source-lock, adjust and destroy refusals that hand the floor a lock code."
- **N4 (Low)** Neither fail-open test asserts a WARN (no log appender in either; only `transferUnitLoadToCarrier` and `findById` are verified). **Both renamed:**
  - `scanDestination_carrierArm_toteTypeIdNull_proceedsWithWarn` → `scanDestination_carrierArm_toteTypeIdNull_failsOpen` (DisplayName: "…fails open and never calls findById(null)"). **This one is plan-named (§7.1)**, so the plan needs the same rename.
  - `scanDestination_carrierArm_toteTypeRowMissing_proceedsWithWarn` → `scanDestination_carrierArm_toteTypeRowMissing_failsOpen` (DisplayName: "…fails open and still moves onto the pallet").
  Round-1 mutation row R03 still quotes the old name; that was its name at `d714a968`.
- **N5 (Low)** New `MobileMoveUnitloadServiceUnitTest.scanDestination_carrierArm_mangledToteLabel_refusalNamesOriginalLabel`: source label set to `SOURCE_LABEL + "-X-" + SOURCE_ID` (`TOTE-0042-X-67101`, the exact suffix `UnitloadBusinessService.unmangleLabel` strips: `"-X-" + unitloadId`), type Tote, stock at 100, onto existing pallet `PM-000B` → asserts `"Tote TOTE-0042 holds"`, `"Stock on TOTE-0042 is reserved"`, `hasMessageNotContaining("-X-")`.
- **N6 (Low)** `goodsOutHint(label, verb)` now starts `if (verb == null) verb = "moving";` (javadoc says why: a refusal path must never NPE; the concatenation would not NPE, it would render "before null it"). Three new `LockRefusalMessagesUnitTest` cases: `goodsOutHint_verbOverload_rendersVerb` (ends " before deleting it."), `goodsOutHint_nullVerb_defaultsToMoving` (ends " before moving it."), `goodsOutHint_oneArg_equalsMovingOverload` (`isEqualTo`).
- **N7 (Low)** `StockunitService.adjustAmount` default arm: `LockRefusalMessages.goodsOutHint(containerLabelForHint(stockUnit), "adjusting")`; `adjustAmount_lock100_messageCarriesGoodsOutHint` gained `.contains("before adjusting it.")`.
- **N8 (Low)** `MobileMoveUnitloadService.assertNotFencedToteOntoCarrier`: `String label = UnitloadService.originalLabel(source);` computed once, used in the subject and in `goodsOutHint(label)`.

### Rendered messages, before and after

Recursive delete (root `UL-001`, child `UL-CHILD-001` holds unit 20):
- before: `Container UL-CHILD-001 cannot be deleted: it holds stock unit 20 locked=100 (Picked). Stock on UL-CHILD-001 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before deleting it.`
- after: `Container UL-001 cannot be deleted: UL-CHILD-001 on it holds stock unit 20 locked=100 (Picked). Stock on UL-CHILD-001 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before deleting it.`
- single container (holder == root): unchanged, `Container UL-001 cannot be deleted: it holds stock unit 1 locked=100 (Picked). Stock on UL-001 …, before deleting it.`

Adjust amount (stock on `UL-001` at 100):
- before: `unexpected lock=100 found. value not changed. Stock on UL-001 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before moving it.`
- after: `unexpected lock=100 found. value not changed. Stock on UL-001 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before adjusting it.`

(Built from the source literals and the passing pins; the pins cover the prefix, the holder hint and the verb.)

### Mutation table (harness `scratchpad/mut3547b/mut_rf2.py`, logs `logs-rf2/`)

One mutant per run, restore `filecmp`-verified, fresh XMLs counted per run.

| ID | Mutant | Selector | Verdict | Killing test (only failure) |
|---|---|---|---|---|
| S01 | N2 holder-only: condition → `true` (old single wording naming the child) | UnitloadServiceUnitTest | KILLED 89/1 | `refusesWhenChildHolds100:933` |
| S02 | N2 root-only: condition → `true` and label → `originalLabel(root)` | UnitloadServiceUnitTest | KILLED 89/1 | `refusesWhenChildHolds100:933` |
| S03 | N2 condition → `false` (always two-container wording) | UnitloadServiceUnitTest | KILLED 89/1 | `deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend:1484` (the new holder == root pin) |
| S04 | N2 hint names root instead of holder | UnitloadServiceUnitTest | KILLED 89/1 | `refusesWhenChildHolds100:935` |
| S05 | N5/N8 `source.getLabelid()` instead of `originalLabel(source)` | MobileMoveUnitloadServiceUnitTest | KILLED 81/1 | `mangledToteLabel_refusalNamesOriginalLabel:2297` |
| S06 | N6 null-verb default removed | LockRefusalMessagesUnitTest | KILLED 7/1 | `goodsOutHint_nullVerb_defaultsToMoving:66` |
| S07 | N6 verb ignored (literal "moving") | LockRefusalMessagesUnitTest | KILLED 7/1 | `goodsOutHint_verbOverload_rendersVerb:60` |
| S08 | N6 one-arg form passes "shifting" | LockRefusalMessagesUnitTest | KILLED 7/1 | `goodsOutHint_oneArg_equalsMovingOverload:72` |
| S09 | N7 back to one-arg (moving) | StockunitServiceUnitTest | KILLED 92/1 | `adjustAmount_lock100_messageCarriesGoodsOutHint:2552` |

S07 catches only the verb test and S08 only the byte-identity test, so each new case kills something no other case does.

### Verification

- Touched classes, one run (XMLs incl. `$Nested` timestamped 10:52, none stale): `LockRefusalMessagesUnitTest` 7 (4 + 3 new), `StockunitServiceUnitTest` all nested green (`AdjustAmount` 4, `NonTransactionalWritePathOrdering` 9, …), `UnitloadServiceUnitTest` 89, `MobileMoveUnitloadServiceUnitTest` 81 (80 + 1 new; `Sbdev3547CarrierArmGoodsOutFence` 9), `CancellationReversalServiceUnitTest` 102, `MoveSourceLockComparisonRailTest` 13 + main rail. The two holder-pin edits in `UnitloadServiceUnitTest` landed after that run and were exercised green by the full suite below (every mutant run also compiles and runs them).
- Rail: 10 EXEMPT entries; `everySingleValueSourceLockRefusalInScopeIsExempt` green (surefire files it under `$BookkeepingSelfTests` XML) → 0 unlisted, 0 stale. The N2/N8 edits touch messages only, not the EXEMPT-pinned conditions.
- H2 IT `CancelPreservesGoodsOutFenceIntegrationTest`: 2/2, BUILD SUCCESS (failsafe XML 10:57).
- Full suite `mvn -o clean test`: **Tests run: 7401, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. 7401 = 7397 + 4 new (N5 × 1, N6 × 3); the two N4 renames and the added assertions (N2, N7) change no count. The 1 skip is the pre-existing `TenantPoolEndpointSecurityTest` skip.
- Diff scan: no `lenient()`, `System.out`, TODO/HACK/FIXME, `@Disabled` or `.only` added.
- Test renames: `…toteTypeIdNull_proceedsWithWarn` → `…toteTypeIdNull_failsOpen` (**plan §7.1 name**), `…toteTypeRowMissing_proceedsWithWarn` → `…toteTypeRowMissing_failsOpen`.
- Not done here: the independent review of this round (never self-approved).

## D5 — Move Stock → Damaged fence

Decision D5 (Nam 2026-09-29). Worktree `.claude/worktrees/wms2-api/SBDEV-3547-b`, branch `bugfix/SBDEV-3547-b-fence`, parent `d0cfb81a`. Commit **`c2d71a42`** (not pushed).

### Where the check sits, and why

`StockunitService.transferStock`, split arm (the `else` of the whole-container `if`): it is the **first statement** of that arm, before `itemdataService.getById`. Condition: destination name is `Damaged` **and** `Integer.valueOf(PICKED_FOR_GOODSOUT).equals(stockUnit.getEntityLock())`.

Side-effect order on this path before the fix: `itemdataService.getById` / `unitloadTypeRepository.findById` / `clientRepository.findById` (reads), then `assertMintedContainerIsPermittedAtDestination` (may emit the SBDEV-3340 shadow WARN, which is a counted metric), then **`unitloadService.createUnitload`, which mints and persists the destination container**, then the Damaged branch's `transferStockToUnitLoad(..., ignoreLock=true, ...)`, the 103 restamp, `stockunitRepository.save` and `messageService.sendStockChangeMessage`. Putting the refusal inside the Damaged `else if` would come after `createUnitload`, so it would depend on `rollbackFor` to undo a write. At the top of the arm, nothing is created, logged as a shadow violation, moved, saved or sent.

- The whole-container arm isn't touched. `SourceLockGuard.assertSourceUnlockedForContainerRelocation` already refuses 100 there (SBDEV-3341).
- 100 stock sent to any other destination still goes through the final `else`, `transferStockToUnitLoad(ignoreLock=false)`, which refuses it. Behaviour there is unchanged.
- The QF-in-place branch can't see 100, because it requires lock == 103. ON_HOLD, unlocked and null locks still reach the non-QF → Damaged arm and get stamped 103, as before. Nothing earlier in `transferStock` refuses ON_HOLD. The only up-front lock refusal is To-Delete (2).
- `/transferToDamaged` already refuses 100 and was left alone.
- The condition is inline in `transferStock` rather than in a helper. `transferStock` had no rail entry before this change, so the new key can't over-match.

Rendered message (fixture container `TOTE-7`, stock unit 100):

```
Source stockUnit=100 is locked=100 (Picked). Stock on TOTE-7 is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before moving it.
```

The label comes from `UnitloadService.originalLabel(suUnitLoad)`. `suUnitLoad` is the source container, already read in-transaction at the top of the non-flowbin branch. The lock is read from the same `stockUnit` snapshot that the two sibling Damaged conditions read, so the three stay consistent.

Comments updated: the `CancellationReversalService` "only OPERATOR exits from 100" paragraph now says Move Stock → Damaged used to be a third exit and is fenced by D5. `StockunitService` bullet 3 of the SBDEV-3340 note now says 100 is refused before the Damaged branch.

### Tests (StockunitServiceUnitTest$TransferStockSourceLockGuard)

- `transferStock_toDamaged_refusesPickedForGoodsout_beforeAnyTransfer`: a source at 100 on `TOTE-7`, a partial move of 40 of 100 (so the split arm), destination Damaged. It expects a `BusinessException` containing `Source stockUnit=100`, `locked=100 (Picked)`, `Stock on TOTE-7 is reserved for goods-out` and `Cancellation screen`. It also asserts `never()` on `transferStockToUnitLoad` (the 8-arg overload the arm calls; both booleans are `anyBoolean()`), `createUnitload(any(Location.class), …)`, `stockunitRepository.save` and `sendStockChangeMessage`. The downstream stubs are `lenient()`, so on unfixed code the test reaches the transfer and fails at its assertion rather than on an NPE.
- `transferStock_toDamaged_stillMarksOnHoldOrUnlockedStockDamaged` (GREEN guard): a source at **ON_HOLD (104)** is still moved with `CODE_DAMAGED, ignoreLock=true, removeIfEmpty=true` and stamped 103. The source is ON_HOLD rather than 0 because 104 does reach this arm today, and only a non-zero, non-100 lock kills the "refuse any non-zero lock" widening. The unlocked case is already pinned by `damagedArm_stampsQualityFault_whenSourceWasUnlocked`.

RED on the pre-fix code (`mvn -o test -Dtest=StockunitServiceUnitTest`):

```
[ERROR] StockunitServiceUnitTest$TransferStockSourceLockGuard.transferStock_toDamaged_refusesPickedForGoodsout_beforeAnyTransfer:2369
Expecting code to raise a throwable.
[ERROR] Tests run: 94, Failures: 1, Errors: 0, Skipped: 0
```

That is the correct reason: the move went through. The ON_HOLD guard was already green before the fix, as intended.

After the fix, `StockunitServiceUnitTest,MoveSourceLockComparisonRailTest,LockRefusalMessagesUnitTest` gives 115/0/0, BUILD SUCCESS. The rail's outer `everySingleValueSourceLockRefusalInScopeIsExempt` was confirmed by its `<testcase>` in the fresh XML.

### Rail

`MoveSourceLockComparisonRailTest.EXEMPT` goes from 10 to **11** entries: `SUS#transferStock :: (destinationLocation.getName().equals(WmsConstants.STORAGE_LOCATION_DAMAGED) && Integer.valueOf(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT).equals(stockUnit.getEntityLock()))`, with the reason "D5 Damaged-arm fence; single-value refusal by decision".

### Mutation check

Harness: `scratchpad/mut3547b/mut_d5.py`. For each mutant it backs up the file, checks the anchor matches exactly once, waits for no other Maven, runs the selector, restores by copy + touch, and filecmp-verifies the restore. Logs are in `logs-d5/`.

| ID | Mutant | Selector | Verdict | Killed by |
|---|---|---|---|---|
| D01 | delete the refusal | StockunitServiceUnitTest | KILLED (94/1/0) | `refusesPickedForGoodsout…:2369`, "Expecting code to raise a throwable" |
| D02 | move the refusal after `transferStockToUnitLoad` | StockunitServiceUnitTest | KILLED (94/1/0) | `refusesPickedForGoodsout…:2377`, `never().transferStockToUnitLoad` |
| D03 | move the refusal after `createUnitload` (before the Damaged branch) | StockunitServiceUnitTest | KILLED (94/1/0) | `refusesPickedForGoodsout…:2379`, `never().createUnitload` |
| D04 | widen to `!NOT_LOCKED` (refuse any non-zero lock) | StockunitServiceUnitTest | KILLED (94/0/2) | `stillMarksOnHoldOrUnlockedStockDamaged:2396` ("locked=104 (On Hold)"). The existing `damagedArm_stillReachable_whenSourceIsQualityFault` also fails ("locked=103"). |
| D05 | remove the rail EXEMPT entry | MoveSourceLockComparisonRailTest | KILLED (13/1/0) | `everySingleValueSourceLockRefusalInScopeIsExempt:154` |

D03 is the side-effect-ordering pin. The refusal still fires under D03, but only after the container has been minted. After the matcher change below, D03 was re-run: still KILLED (`:2381`).

### Existing tests changed by the first full-suite run

The first `mvn -o clean test` gave 7404 / 2 failures / 3 errors. There were two causes.

1. **`StockunitServiceParcelSourceRefusalUnitTest.transferStock_shouldProceed_whenNonParcelStockMovesToDamaged` ×3 (legitimate flip).** This control asserted that a lock-**100** non-parcel unit moved to Damaged goes through on the CODE_DAMAGED arm. That is exactly the move D5 refuses, so the test failed with the D5 message (`Source stockUnit=100 is locked=100 (Picked). Stock on PKG-0002 …`). The control exists to show that the parcel guard doesn't over-refuse non-parcel stock on the damaged arm, and the lock value isn't what it tests. Its fixture now uses **ON_HOLD**, which is non-zero and still reaches the ignoreLock=true arm, and its javadoc and display name were updated. The parcel case 3 (`…shouldRefuse_whenLock100ParcelStockMovesToDamaged`) stays green without changes. `SourceContainerGuard` runs before the arm dispatch, so a parcel refusal still takes precedence over D5.
2. **`NeverMatcherNullBlindnessArchTest` ×2 (my test's matchers).**
   - (a) `any(Location.class)` inside `never().createUnitload` is null-blind. It is now `(Location) any()`. The cast only selects the `(Location, Long, Long, String, Long)` overload over `(String, Location, Long, Long, String)`.
   - (b) The primitive inventory for `StockunitServiceUnitTest` went from 5 to 7, from the two `anyBoolean()` at `transferStockToUnitLoad` params 7-8, which I confirmed are primitive `boolean` in the signature. The inventory entry was updated with a comment.

After these changes, `StockunitServiceUnitTest,StockunitServiceParcelSourceRefusalUnitTest,NeverMatcherNullBlindnessArchTest,MoveSourceLockComparisonRailTest,LockRefusalMessagesUnitTest` gives 162/0/0.

### Verification

- H2 IT `CancelPreservesGoodsOutFenceIntegrationTest` (`mvn -o verify -Dit.test=… -Dtest=ZzzNone …`): **2/2, BUILD SUCCESS**. Fresh failsafe XML at 05:07. Only test files changed after that run.
- Full suite `mvn -o clean test`: **Tests run: 7404, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. 7404 = baseline 7402 at `d0cfb81a` + the 2 new D5 tests. The parcel flip and the ArchTest edits don't change the count. The 1 skip is the pre-existing one.
- `git status` is clean after the commit. No ArchUnit store file changed. No push.
- Diff scan: no `System.out`, TODO/HACK/FIXME, `@Disabled` or `.only`. The `lenient()` stubs in `stubDamagedSplitArm` are deliberate: they let the RED test reach the transfer on unfixed code, and the helper's javadoc says so.
- Not done here: an independent review of D5 (never self-approved).
