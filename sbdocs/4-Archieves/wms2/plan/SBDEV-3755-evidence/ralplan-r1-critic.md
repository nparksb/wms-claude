---
title: "SBDEV-3755 ralplan r1: Critic review"
ticket: SBDEV-3755
kind: review
lane: critic
created: 2026-10-13
plan: "SBDEV-3755-transferstock-replen-held-opt-in.md (r1)"
code_base: "wms2-api origin/fix/SBDEV-3755-replen-holder-multi-and-child-banner @ c6f0cbc0 (NOT merged into origin/develop a4fd6490; re-checked 2026-10-13 with git merge-base --is-ancestor)"
verdict: ITERATE
counts: "High 2 · Medium 6 · Low 9"
---

# SBDEV-3755 ralplan r1: Critic review

**VERDICT: ITERATE** (High 2 · Medium 6 · Low 9)

**Independence:** I read only the plan and `fix1-analysis.md`. I did not open `ralplan-r1-architect.md` or `review-code.md`.
**Instruments:** I read the code with `git show` / `git grep` on `origin/fix/SBDEV-3755-replen-holder-multi-and-child-banner` (c6f0cbc0) only. I did not run mvn. Every count below is a grep over that ref. The blind spots are runtime-built calls and test helpers that wrap the call under another name.

## Overall assessment

The design is sound and follows from D1–D4:
- The narrow predicate `fla == null && A <= amount`, placed before the `createStockUnit` placeholder, is correct for R ≥ 0. I re-derived it against `StockunitBusinessService.java:206,328-337,415-417`.
- The caller-side trigger correctly avoids the DI cycles. I checked the trigger → `ReplenishmentOrderMaintenanceService` → SBS chain. Nothing in that graph injects `PickingorderBusinessService`.
- The lock-order reasoning holds per stock unit.

The plan is not ready for the TDD gate, for three reasons:
1. The overload switch at the four opt-in callers silently disarms existing `never()` assertions.
2. One named mutant cannot be killed by the AC it is attributed to, so a §5 claim is false.
3. The list of tests that will break is incomplete. One of them is listed as a must-stay-green control.

Each fix is a planning edit. None reopens D1–D4.

## Pre-commitment predictions vs. findings

| Prediction | Outcome |
|---|---|
| Moving 4 callers to a new overload breaks or disarms caller unit tests that stub/verify the 8-arg form | **Confirmed, worse than predicted.** `never()` sites are silently disarmed (H1), and a listed positive control breaks (M1) |
| Fix B's multi-holder `shareOf` claim is not actually pinned by its IT | **Confirmed** (H2) |
| ACs that reference new types are compile-red on base | **Confirmed** (M2) |
| Rails missed (freeze, NeverMatcher, SDR) | Mostly covered. Two unlisted rails: LockReadRail (L8) and TestIdentifierCountArchTest (L9) |
| Displacement predicate wrong at a branch edge | **Not found.** The predicate is correct for R ≥ 0, and R < 0 is also caught |

---

## High

### H1. The overload switch silently disarms existing `never()` assertions on the 8-arg method in the opt-in callers' tests
- **Evidence.** These sites verify `never()` on the **8-arg** overload. After the plan, the production path they guard calls the **policy** overload, so the `never()` passes whatever happens:
  - `MobileReplenishServiceUnitTest:3453,3492,3954,3971`. For example, `finish_rejectsDestinationScopedToAnotherClient` ends `verify(stockunitBusinessService, never()).transferStockToUnitLoad(any(), any(), any(), any(), any(), any(), anyBoolean(), anyBoolean());`. #15 moves to the policy overload, so this assertion can no longer see a finish that moves stock.
  - `UnitloadServiceUnitTest:2387` (`moveStockToNewDamagedContainer` refusal, "never moves stock"). #12 moves to the policy overload.
  - StockunitService tests whose `never()` covers every arm, including the #10 → Damaged arm:
    - `StockunitServiceTransferStockDestinationTest:215` (`verifyNoStockMoved`);
    - `StockunitServiceUnitTest:2993`;
    - `StockunitServiceParcelSourceRefusalUnitTest:417,627`;
    - `StockunitServiceToteContainerRelocationUnitTest:464`.

    For the Damaged arm these become vacuous.
- **What the plan says.** It covers only `"caller-test verifies for #5/#10/#12/#15 move to the new overload"` (§6). It does not say that a `never()` left on the old overload stays **green**. A full-suite run cannot find these, which makes this the "sibling change silently disarms your tests" class.
- **Fix.**
  - List every `never()` site above in §6/§8.1.
  - Require each to assert `never()` on **all three** overloads, using one helper such as `verifyNoTransfer(sbs)` that covers the 8-, 9- and 10-arg forms, with `any(ReplenHoldPolicy.class)` and `anyBoolean()` for the primitives.
  - Add a mutation row: "at #15, perform the transfer before the client check → `finish_rejectsDestinationScopedToAnotherClient` must go red."
  - Optional: a text rail that refuses an 8-arg-only `never().transferStockToUnitLoad(` in the four opt-in callers' test classes.

### H2. The mutant "Snapshot `shareOf` once outside the loop → AC-19" is equivalent under AC-19's fixture, so §5 B.5's "AC-19 pins this at IT level" is false
- **Evidence.**
  - AC-19 is `laneMove_twoHolders_noCandidate_cancelsBothAndReleasesExactly`.
  - On NO_CANDIDATE, `redirectSource` returns at `if (candidate == null) { return RedirectOutcome.NO_CANDIDATE; }`, before `currentShare` is read (`ReplenishmentOrderMaintenanceService.java:557-576`).
  - `cancelOrder` then recomputes the share internally: `releaseHeld(order, source, shareOf(order, source), activityCode)` (`:905-911`).

  So a loop that snapshots `share` once still releases the correct amounts in this fixture. The mutant survives, and the only multi-holder arithmetic claim in Fix B is unpinned.
- **Fix.**
  - Add an IT (or make AC-19 two-armed) where holder 5 is **REDIRECTED** to a candidate stock unit and holder 9 then cancels or redirects. That is the path that consumes `currentShare`.
  - Use **distinct** requested amounts (e.g. req₅ = 3, req₉ = 5) so a reused share produces a wrong release row.
  - Re-attribute the mutant to that test.
  - Correct the §5 B.5 sentence.

---

## Medium

### M1. The list of tests that will break is incomplete, and one listed "must stay green unchanged" control will go red
- **`StockunitDamagedRollbackIntegrationTest`** (§8.2 positive control):
  - It stubs a `@MockitoBean StockunitBusinessService` at `:181`: `when(stockunitBusinessService.transferStockToUnitLoad(any(Stockunit.class), …, anyBoolean(), anyBoolean())).thenThrow(new BusinessException("inject-D6"))`.
  - Once #12 calls the policy overload, that stub never fires. The mock returns a null `TransferOutcome`, `.stock()` throws an NPE, and assertion 1 (`hasMessageContaining("inject-D6")`) fails.
- **`PickingorderBusinessServiceUnitTest`.** 12 `when(sbs.transferStockToUnitLoad(<8 args>)).thenReturn(pickToStock)` stubs (e.g. `:1184,1278,1965,2044`). After #5 switches, the stubs go unused (STRICT_STUBS) and `confirmPick` NPEs on the null `TransferOutcome`.
- **`StockunitServiceAuditCommentClampUnitTest:494`.** This class is not listed anywhere in the plan. It stubs the 8-arg overload with `eq(WmsConstants.CODE_DAMAGED)`, which is #10.
- **`MobileReplenishServiceUnitTest:4257,4275`.** `doThrow(…).when(sbs).transferStockToUnitLoad(<8 args>)` stops firing.
- **Deleting `findIdByStateLessThanAndStockunitId` breaks unlisted files:**
  - compile errors in `ReplenishmentOrderSourceSyncServiceBranchTest:104,121,136` and `ReplenishmentOrderMaintenanceServiceUnitTest:2233`;
  - `ReplenishmentIdProjectionContractUnitTest:158`, whose `checkNotExported` array names the deleted method.

  §8.1 lists only `…SourceSyncServiceTest`, `…ReassignTest` and the two F5 `contains` lines.
- **Driver 3 overclaims.** It says *"the 14 REFUSE sites and ~147 test mentions stay untouched"*. StockunitService owns both REFUSE arms and opt-in #10, so its 7 test classes are touched.
- **Fix.**
  - Enumerate the files above in §6.
  - Move `StockunitDamagedRollbackIntegrationTest` out of §8.2 into "re-target the injection stub to the policy overload; the assertion stays".
  - State the re-stub form: `thenReturn(new TransferOutcome(stock, List.of()))`.

### M2. Several ACs are compile-red, not assertion-red, on the base commit
- **Evidence.** These ACs reference `ReplenHoldPolicy`, `TransferOutcome` or the 10-arg overload, none of which exist at c6f0cbc0:
  - the ALLOW_ANY half of AC-6;
  - AC-9, AC-10, AC-11 (the "uses ALLOW_ANY" half) and AC-12;
  - AC-13, if it imports the type.

  §7.2 step 3 says *"failing AC-1…AC-8 in a new unit class, then the overload, guard, policy"*. That orders the red run before the types exist. The floor requires "failing for the right reason".
- **Fix.** Add step 2.5, a scaffold commit:
  - the enum and the record;
  - the 10-arg overload carrying the body **without** the guard;
  - the 8/9-arg overloads delegating to it;
  - callers unchanged.

  Then write the red tests. Each red is then an assertion failure (no refusal, wrong policy, no trigger).

### M3. Base-commit behaviour is not stated per AC; several pass on base and two are vacuous for this change
- **Green on base by construction:**
  - AC-3, AC-4 (`never()` on a finder base never calls);
  - AC-5;
  - AC-11's "MANUAL_SPLIT arms still call the 8-arg overload" and "`setLockDamaged` → `requestForItem` `times(1)`";
  - AC-12;
  - AC-22(b), AC-22(c).
- **AC-8** is red only once the store line is deleted ahead of the code.
- **AC-18** (`moveAndAttributedCut_sameTwoHolderSu_noDeadlock`) is **green on base**: the move throws `IncorrectResultSizeDataAccessException` before taking any order lock. It is also timing-dependent; this repo has three known-flaky concurrency ITs (memory).
- **AC-12** ("`UnitloadService` declares no trigger field") can only be killed by a mutant that adds the field. It is a rail, not an acceptance criterion for this change.
- **Fix.**
  - Add a column to the AC list: *red on base (assertion) / control (green on base, killed by mutant X) / rail*.
  - For AC-18: name its mutant (descending lock order in Fix B), state an iteration count, and record it as a non-regression probe rather than a red-first test.

### M4. Several ACs have no attributable mutant in §8.3

| AC | Missing mutant (proposal) |
|---|---|
| AC-5 | "refuse whenever `displacing`, even when holders are empty" |
| AC-7 (holder choice) | "always `holders.get(0)`", which leaves the [5 @300, 9 @500] case naming 5 |
| AC-11 | "#10 left at REFUSE" and "trigger unconditional at #10" (AC-10 covers only #5) |
| AC-13 | "add a 5th caller of the policy overload" (and "≥ 4 found" non-vacuity) |
| AC-16 (2nd half) | "re-point each holder before checking `blocksMove` on the rest"; the assertion must read holder 5's **fields**, not `save` counts |
| AC-9 | instrument unstated: how is "exactly one WARN naming the sibling only" captured (`ListAppender` / `OutputCaptureExtension`)? |
| AC-17, AC-20, AC-21 | fine (the base itself is the mutant), but say so |
| AC-22(b)/(c) | controls; say so |

### M5. AC-22(a) and the manual "Refusal" row will take the whole-container route unless the fixture has ≥ 2 stock units on the source unit load
- **Evidence.** `StockunitService.transferStock` (#510, ~`:517-534`) checks `if (stockUnit.getAmount().compareTo(amountToTransfer) == 0 && !flaOpt.isPresent() && stockUnitList.size() == 1 && unitloadService.restsInStorageLocation(suUnitLoad))`. On that branch it calls `unitloadBusinessService.transferUnitLoadToLocation(suUnitLoad, destinationLocation, false, WmsConstants.CODE_MANUAL_TRANSFER, …)`, which is processTransfer → Fix B re-point, **not** #11.
- **Consequence.** A natural one-stock-unit-on-a-pallet fixture fails AC-22(a) after the fix for a fixture reason. The manual row would show "succeeds, replen re-pointed" rather than a 422.
- **Fix.** Specify ≥ 2 stock units on the source unit load (or a non-storage container) for AC-22(a) and the manual row. Add a manual row for the sole-stock-unit case, whose expected result is a Fix B re-point with no refusal.

### M6. The verification floor is not concrete
- **Evidence.** §7.2 step 6: *"full suite vs a baseline on the base commit; `code-reviewer`"*. Missing:
  - no command (`mvn clean verify -Pci`; the `ci` profile exists at `pom.xml:949`);
  - no PIT scoping (`pitest-maven` is configured at `pom.xml:552-571`; §8.3 is hand mutation only);
  - no statement of where the baseline numbers are recorded.

  Two repo traps bite this ticket specifically:
  - `mvn test` cannot see the integration lane, where AC-17–19 and AC-22 live.
  - mvn without `clean` runs deleted test classes, and this plan deletes a finder whose stubs live in test classes.
- **Fix.** Name the base-commit baseline command and its output file, the `-Pci` full run, the PIT `targetClasses`/`targetTests` scope for SBS and the two Fix B services, and that the review lane writes its report to a file.

---

## Low

- **L1.** The REFUSE path's `findById(chosen.getId())` empty case is unspecified. #510's own head commit (c6f0cbc0, *"pin existsForStockUnit when the chosen holder's row is gone"*) treats it as real. Fall back to a message built from the projection's `getNumber()`; never `.get()` (OptionalSafetyArchTest).
- **L2.** AC-1's `"createStockUnit are never called"` cannot be verified. It is a self-invocation on the real SBS under `@InjectMocks`, and it is vacuous because re-parent never reaches it. Assert `clientRepository.findById` / `itemdataService.getById` `never()` instead.
- **L3.** The `ALLOW_ANY` sibling filter must be null-safe (`!Objects.equals(h.getNumber(), orderNumber)`). #10 and #12 pass `orderNumber = null`.
- **L4.** AC-21 as a **new** context test adds a Spring context fork; the repo memory has an unrelated IT broken by one. The natural home is `SdrUncalledSurfaceNotExportedContextTest`, which already lists `ReplenishorderRepository` searches at `:384-388`. Unexported searches are **absent** from `ResourceMappings`; they are not present with `isExported()==false` (`SdrSurfaceInventoryContextTest:95-103`). So assert absence by method name.
- **L5.** `replenHoldsStockMessage` says *"…before moving its stock onto a flow bin or another unit load"*. It reads wrongly on BOL, club and package refusals (#1–#4). It is acceptable given the SU/UL prefix, but say so.
- **L6.** §4 says *"every locker takes orders → SU"*. That is true per stock unit. Within one Move Unit Load, the maintenance branch locks SU S1 and then S2's holders, which is an SU → order edge across stock units. It is pre-existing (R6), but the sentence overclaims.
- **L7.** R3's mitigation (AC-6 `never()` on `replenishorderRepository.findByIdForUpdate`) cannot see `LockReads.forUpdate(entityManager, Replenishorder.class, …)` or a native lock. An ArchUnit rule ("SBS calls no locking method on `ReplenishorderRepository` and no `LockReads` for `Replenishorder`") fences the mechanism rather than one instance.
- **L8.** Rail not listed: `LockReadRail` (SBDEV-3286, baseline-gated, runs in every Spring test context). AC-17–19's new per-holder `findByIdForUpdate` loop runs under it. List it as an instrument. The `existsForStockUnit` javadoc already warns that a holder `findById`-loaded earlier in the same transaction turns the lock into a version-checked upgrade.
- **L9.** AC-13's phrase *"exactly one call site"* must not go into a `@DisplayName` or method name, because `TestIdentifierCountArchTest` flags "exactly one".

---

## Gate checks

| Gate | Result | Note |
|---|---|---|
| Principle–option consistency | **Pass** | A (policy overload) follows from P1/P5. Fix A's no-order-lock rule follows from P2. Fix B's projection-then-lock follows from P3. Narrow scope follows from P4 / D1. Driver 3's "untouched" is overstated (M1) but does not contradict the choice |
| Alternatives depth | **Pass** | Option B (named method) and refuse-on-drift are argued on their merits, not as straw men. Boolean, ThreadLocal and `ALLOW_ORDER` rejections cite An §3 |
| Risk / verification rigour | **Fail (fixable)** | H2 (a false pin claim), M3/M4 (base behaviour and mutants), M6 (floor commands) |
| Acceptance criteria encodable and red-on-base | **Partial** | 11 are assertion-red on base: AC-1, 2, 6 (REFUSE half), 7, 14, 15, 16, 17, 19, 20, 21, plus 22a with the M5 fixture. The rest are compile-red (M2) or controls (M3) |

## Completeness against the code

- **Callers.** The 18 call expressions are confirmed by `git grep -n "transferStockToUnitLoad("` on #510. Per-site codes and `ignoreLock` match. #3 passes `stagingLaneFixAssignment` and BOL #1/#2 pass `transferLaneFla`, so they are non-displacing whenever an FLA exists. The Fix B callers are confirmed: `syncForMovedStockUnit` is called only from `UnitloadBusinessService.processTransfer:537`.
- **DI.** `ReplenishorderRepository` in SBS: no cycle. Trigger in `PickingorderBusinessService`: no cycle. Only `AdminActionController`, `CustomerorderService`, `MobilePickingService` and `FixLocationAssignmentService` inject `PickingorderBusinessService`, and none is in the trigger's graph.
- **Rails.** The freeze entry `archunit_store/5fb3fee0…:38` is verified. The freeze matches on signature, not line, so `.orElse(null)` plus the store deletion is right. `mvn test` also auto-prunes the store, so check it in deliberately.
  - `SdrSurfaceInventoryContextTest` asserts only `resources > 20` (verified at `:133-135`).
  - The NeverMatcher per-class counts will move for the 4 caller test classes once H1's helper lands. Re-measure them, as the plan says.
  - `ReplenishmentMaintenanceCallSiteArchTest` pins callers of `recalculateForItem`, not `requestForItem`, so it is unaffected.
  - `MoveSourceLockComparisonRailTest` is a text scan and constructs no SBS, so §6's "if it constructs one" is a no-op.
- **Branch hygiene.** #510 is not merged (ancestor check false). No other origin feature branch touches SBS, the two Fix B services, `ReplenishorderRepository` or the archunit store. Only release/main/promote divergence shows. §7.1 row 4's stacked-PR rule is correct.

## Claim-discipline notes

- §5 B.5, *"AC-19 pins this at IT level"*, is false (H2).
- §8.2, *"must stay green unchanged"*, is false for `StockunitDamagedRollbackIntegrationTest` (M1).
- Driver 3, *"~147 test mentions stay untouched"*, is false for the StockunitService test classes (M1).
- §0, *"Both are reached only from UnitloadBusinessService.processTransfer"*, names no instrument in the plan. It is true, verified by git grep.
- §0's census does name its instruments and blind spot.

## What would upgrade this to APPROVE

1. Fix H1 and H2.
2. Fold in the M1 file list, the M2 scaffold step, the M3 AC classification column, the M4 mutant rows, the M5 fixture and the M6 commands.

None of these touches D1–D4.

---

## Round 2

**VERDICT: APPROVE, with conditions** (new findings: High 0 · Medium 1 · Low 6). Fold N1 and N2 into the TDD gate. Neither needs another ralplan round.

**Independence and instruments.** I read only the r2 plan (599 lines) and this file. I did not open `ralplan-r1-architect.md` or any other review file. I checked the code read-only on `origin/fix/SBDEV-3755-replen-holder-multi-and-child-banner` @ c6f0cbc0 and did not run mvn.

### R2.1 Round-1 findings: resolution check

| Finding | r2 text (quoted) | Verified against code | Status |
|---|---|---|---|
| H1 never() disarm | §6: *"every `never()` on `transferStockToUnitLoad` → `TransferVerifications.verifyNoTransfer(sbs)`… 8-, 9- and 10-arg… 19 sites"*, plus A20 | I ran `git grep -A2 "never())"` over `src/test` and found 24 hits. 5 are false positives: a `never()` on a different method followed by a positive transfer verify (`ClubLine:227`, `PutAway:1702`, `MobileReplenish:3965,4243`, `TransferStockDestination:360`). The remaining **19 match the plan's list exactly**. There are no `doReturn`/`times(0)` forms beyond the two `doThrow` sites, which §6 lists | **Resolved** (the A20 rail has a gap; see N1) |
| H2 shareOf mutant | §5 B.6: *"A cancel does not consume the loop's `share`… A **redirect** does consume it"*; B7: two redirects, requests 3/5, mutant *"`shareOf` snapshotted once… (REPL-9 would release 3)"* | `redirectSource` releases `releaseHeld(order, currentSource, currentShare, …)` after the reserve on the target (ReplenishmentOrderMaintenanceService ~:744). A snapshot from order 5 (held 3) reused for order 9 releases 3, not 5, so B7's per-order release rows go red. The kill is attributable to B7 | **Resolved** |
| M1 test-break census | §6 churn table names `PickingorderBusinessServiceUnitTest` (12), `AuditCommentClamp:494`, `MobileReplenish:4257,4275`, *"`StockunitDamagedRollbackIntegrationTest:181`: re-target the `inject-D6` throw stub… leaves the 'unchanged' control list"*, `…SourceSyncServiceBranchTest:104,121,136`, `…MaintenanceServiceUnitTest:2233`, `…IdProjectionContractUnitTest:93,158`; Driver 3: *"the 14 REFUSE **production** sites stay untouched"* | I matched these against my round-1 greps. I also checked the Damaged-arm sites in StockunitService tests: `StockunitServiceUnitTest` stubs at 2884/2924/2964 are listed | **Resolved** |
| M2 compile-red | §7.2 step 1: *"Scaffold, with no behaviour change… From here on, every red AC fails on an assertion"* | Every RED row in R2.2 fails on an assertion after the scaffold | **Resolved** |
| M3 base labels | §8.1 *"Base: RED… CTRL… RAIL… PROBE"* on every row | Labels checked in R2.2 | **Resolved** |
| M4 mutants | *"Mutant: every row names one"*; A10/A11 *"captured with a Logback `ListAppender`… (precedent: `StockUnitControllerUnitTest`)"* | The precedent exists (35 test files use `ListAppender`, including `StockUnitControllerUnitTest`). One attribution is weak (N2) | **Resolved** except N2 |
| M5 whole-container route | E1 preamble: *"The source UL carries **at least 2 SUs**; otherwise `transferStock` takes the whole-container route"*; E1d; the manual *"Sole-SU route"* row | Matches the `stockUnitList.size() == 1 && restsInStorageLocation` predicate | **Resolved** |
| M6 floor commands | §7.2 steps 0 and 7: `mvn clean verify -Pci`, *"Never use `mvn test` alone"*, §8.3 PIT command, review written to `fix1-review-code.md` | The `ci` profile exists; `timing-sensitive` is excluded only under `ci` (pom.xml:42) | **Resolved** (baseline provenance: N5) |
| L1 vanished row | §5 A.4: *"a candidate whose row is gone is treated as no holder… Never call `.get()`"*; A8 | — | Resolved |
| L2 createStockUnit | A1: *"`clientRepository.findById` is never called (the first statement of the placeholder block)"* | Matches SBS:330 | Resolved |
| L3 null-safety | §5 A.5: `!Objects.equals(h.getNumber(), orderNumber)`; A10 null case | — | Resolved |
| L4 context fork | C1: added to `SdrUncalledSurfaceNotExportedContextTest.callerlessSearchesOnExportedTypesAreWithdrawnIndividually` | The method and `record Withdrawn` exist (:380-381), with premise checks for method existence and type exported | Resolved |
| L5 message on batch paths | §5 A.4: *"still literally true… Accepted"* | — | Resolved (accepted with reason) |
| L6 lock-order overclaim | §4: *"Per stock unit"* and a *"What does not hold"* list | — | Resolved |
| L7 R3 fence | A14 ArchUnit plus a named blind spot | Gap in the blind-spot list (N3) | Resolved except N3 |
| L8 LockReadRail | §6 rails row | — | Resolved |
| L9 naming | §8.1: *"Naming: … avoid 'exactly N' and 'all N'"* | — | Resolved |

### R2.2 AC labels and mutants

Each RED row checked against the post-scaffold base: no guard, callers unchanged, the old Fix B probe still in place.

| AC | Label check | Mutant attributable? |
|---|---|---|
| A1, A2 | RED: no throw on the scaffold → `assertThatThrownBy` fails | yes |
| A3–A5 | CTRL, correct | yes (A3: the read hoisted above the predicate; A4: `fla == null` dropped; A5: refuse with no holders) |
| A6 | RED (REFUSE InOrder; the scaffold never calls `findHolders…`) | **weak (N2)** |
| A7 | RED | yes: `holders.get(0)` names 5 in the [5@300, 9@500] case |
| A8 | RED | yes |
| A9 | RED | yes. The A1 test also kills it, which is acceptable |
| A10, A11 | RED: the scaffold has an empty outcome and no log | yes |
| A12 | CTRL: the scaffold already does `.orElse(null)`, and ArchUnit prunes the store | yes |
| A13 | RAIL, red after the scaffold (0 found, non-vacuity ≥ 4) | yes |
| A14 | RAIL | partial (N3) |
| A15–A17 | RED: verifies on the policy overload fail while callers are unchanged | yes. A17's "#11 → ALLOW_ANY" also fails A13 (two accesses in `transferStock`) |
| A18 | RED / RAIL, as labelled | yes |
| A19 | RED (no-op helper) | yes |
| A20 | CTRL / RAIL | the behavioural half, yes; **the rail half has a gap (N1)** |
| B1–B4 | RED: the base probe calls the unstubbed `findIdBy…`, Mockito returns `Optional.empty()`, the method returns early, and the InOrder or throw assertion fails | yes |
| B5–B7 | RED on base via `IncorrectResultSizeDataAccessException` | B5/B6: base; B7: the snapshot mutant (H2) |
| B8 | PROBE: on base the move throws before any order lock, so the `pg_stat_activity` control fails | yes: descending order against the ascending cut gives 40P01 (see N4 for the CI exclusion) |
| B9 | RED | yes |
| B10 | RAIL (green on base: #510 removed the last src/main caller) | yes |
| C1 | RED | yes |
| E1a | RED | yes |
| E1b–E1d | CTRL | yes. E1c: if #15 stays at REFUSE, the R = 0 finish is refused once the guard is in |

### R2.3 New findings introduced by r2

**N1 (Medium). The A20 text rail, as worded, cannot see the multi-line `never()` shape that already exists in this codebase.**
- **Evidence.**
  - A20: *"`NoBareTransferNeverRailTest` (text scan of `src/test`): no `never()).transferStockToUnitLoad(` outside `TransferVerifications`"*.
  - `StockunitServiceTransferStockDestinationTest:214-215` has `verify(stockunitBusinessService, never())` and `.transferStockToUnitLoad(…)` on separate lines.
  - `NeverMatcherNullBlindnessArchTest` documents that `never ()` (a space before the parenthesis) was "triple-silent" to a literal scan.
  - A literal scan would also miss `Mockito.never()` and `times(0)`.
- **Why it matters.** This rail is H1's regression fence. A scan that misses the shapes present here is green whatever happens, and it has no positive control.
- **Fix.**
  - Scan the comment-stripped text with a whitespace- and newline-tolerant pattern: `never\s*\(\s*\)\s*\)\s*\.\s*transferStockToUnitLoad\s*\(`, plus `times\s*\(\s*0\s*\)`. Reuse the NeverMatcher scanner if possible.
  - Add a non-vacuity control: the scan must find the ≥ 3 occurrences inside `TransferVerifications`.
  - Add a self-test on a two-line literal.

**N2 (Low). A6's mutant cannot be killed as worded.**
- **Evidence.**
  - §5 A.4 now reads *"`findById` each candidate in turn. The first present one is the chosen holder"*.
  - A6 asserts *"`findById(chosen)` once"*.
  - The mutant is *"`findById` called on every holder before deciding"*.
- **Why the mutant survives.** It loads 5 and 9 and still calls `findById(5)` exactly once, so a per-id verify stays green.
- **Fix.** In the [5@300, 9@300] fixture, assert `verify(replenishorderRepository, times(1)).findById(any())`, or `never().findById(9L)`.

**N3 (Low). A14 has a blind spot it does not name.**
- **Evidence.** `LockReads.forUpdate(entityManager, Replenishorder.class, id, replenishorderRepository::findById)` takes `PESSIMISTIC_WRITE` through `entityManager` when the row is already managed (`LockReads.java:85-110`: a scalar JPQL lock, then `entityManager.refresh(managed, PESSIMISTIC_WRITE)`). The only repository member it touches is `findById`, which is in A14's allowed set.
- **Fix.** Either name this blind spot in A14, or forbid **method references** to `ReplenishorderRepository` in SBS (only direct calls allowed). ArchUnit reports method references separately from calls.

**N4 (Low). B8 may never run in CI.**
- **Evidence.** B8 says *"If it is flaky… tag it `timing-sensitive` (excluded under `-Pci`)"*. If it is tagged, the only deadlock probe is excluded from every pipeline run (pom.xml:42).
- **Fix.** If tagged, record a passing on-demand run (`-Dfailsafe.excludedGroups=performance`) and its iteration count in `fix1-review-code.md` as a floor item.

**N5 (Low). The baseline's provenance is unconfirmed.**
- **Evidence.** §7.2 step 0 uses *"the #510 run at c6f0cbc0 (ticket comment… unit 8263… IT 842…)"*. c6f0cbc0 was committed today at 15:14, and it is the commit that pins the "chosen holder's row is gone" case.
- **Fix.** Confirm that the comment names c6f0cbc0, not its parent. If it does not, re-run at step 0.

**N6 (Low). §4 is ambiguous about the order of steps.**
- **Evidence.** §4 reads *"projection → refuse… → lock holders asc → re-check → replenishable: re-point each / else … reassignOrCancelForMovedStockUnit (same prefix)"*. This can be read as `syncForMovedStockUnit` running the prefix (locks included) **before** the replenishability branch, then delegating so that maintenance runs the prefix a second time.
- **Fix.** State that `syncForMovedStockUnit` checks `isReplenishableDestination` first, as today at :74, so only one service runs the prefix.

**N7 (Low). One step mislabels a RAIL.**
- **Evidence.** §7.2 step 3 says *"ACs B1–B10 red"*, but B10 is a RAIL and is green on base. This is wording only.

### R2.4 Declines

None of my round-1 findings was declined. L5 was accepted with a stated reason, which I agree with. Two other declines are visible in §11:
- Ar L-1: projection widening declined.
- Ar L-3: the finder is kept, with B10 and a javadoc warning, under D4.

Both are reasoned and within D1–D4. I would not reopen them.

### R2.5 Gate checks

| Gate | Result |
|---|---|
| Principle–option consistency | Pass. The caller-guard steelman was added, and its rejection is reasoned by P1/P2 |
| Alternatives depth | Pass |
| Risk / verification rigour | **Pass, with conditions** (N1, N2) |
| ACs red for the right reason | Pass. Every RED row fails on an assertion after the scaffold |

**Why APPROVE.** Every round-1 High and Medium is resolved, with code-verified text. The one new Medium is a precision fix to a test rail and changes no design decision. Fold N1 and N2 into the TDD gate. N3–N7 can go into the same edit or into `fix1-review-code.md`.
