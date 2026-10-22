---
ticket: SBDEV-3490
lane: independent code review (sole lane)
reviewer: oh-my-claudecode:code-reviewer
date: 2026-09-24
worktree: .claude/worktrees/wms2-api/SBDEV-3490
branch: bugfix/SBDEV-3490-shipped-source-guard
base: origin/develop 978b3a14
head: 06503426 (2 commits: 01225d91, 06503426)
verdict: APPROVE (Lows to fix in the same pass per standing rule)
---

# SBDEV-3490 — Code Review

Read-only review. No mvn run (suite in progress in the worktree); no file in the worktree touched.
Compile evidence: `javap` on `target/test-classes/.../MobileMoveUnitloadServiceUnitTest$ScanDestination.class`
(built 12:45, after HEAD commit 12:42) lists all 5 new test methods, so the test tree compiles.
Java LSP diagnostics were not run (no mvn allowed, no Java LSP server attached). The javap check stands in for them.

## Summary

**Files reviewed:** 4 (1 main, 3 test)
**Total findings:** 9. High 0 · Medium 1 (a sibling outside this diff, proposed) · Low 8

## Stage 1: spec compliance: PASS

| Requirement | Where | Status |
|---|---|---|
| Nirwana-location source refused, scanUnitLoad message | `MobileMoveUnitloadService.java:314-318` | ✓ same text as `:153-155` |
| Shipped-location source refused, scanUnitLoad message | `:319-322` | ✓ same text as `:157-160` |
| After `assertNotNirvanaSentinel`, before ON_HOLD and every branch | `:308` → `:314-322` → `:324` | ✓ |
| Fixed-assignment check where scanUnitLoad has it (after the stock ON_HOLD loop, before `checkReservedStock`) | `:335-338` vs `:173-178` | ✓ same order, same message |

### Is the guard ahead of every branch that mutates the source? Yes.
Branches in order: Damaged-set `:345-349`, Damaged-remove `:350-355`, location move `:369-394`, flow bin
`:396-422`, create-inbound-pallet + container `:423-479`. The earliest mutation is `setStockDamaged`
at `:349`. All three new checks sit above `:340`, so each branch is covered.

### Callers / legitimate workflows: nothing breaks
- `scanDestination` has one production caller: `MoveUnitloadController.java:75` (`POST /selectDestination`). No service reuses it.
- UIs on `origin/develop`: only `wms2-mobile-ui/store/moveUnitload.js:56` posts to it, and `components/moveUnitload/scanDestination.vue:167-175`
  builds the body from `this.info.unitLoadLabel`, i.e. the result of `selectSource` (`store/moveUnitload.js:35`). `wms2-web-ui` has zero references.
  So every UI-reachable call has already passed `scanUnitLoad`'s identical guards. The new checks only refuse
  (a) direct API calls and (b) the stale-scan window, where the unit load was shipped or fixed-assigned between the two scans. Refusing (b) is the correct outcome.
- TRANSFER receiving, returns (SBDEV-2778) and inbound receiving never reach `scanDestination`. They go through `ReceivingService`/`AdviceService`.
- `moveStock=true` with a fixed-assigned (flow-bin) source is now refused. `scanUnitLoad` already refuses that source, and the shipped client never sets the flag (`:438-442` comment). Not a regression.

### Behaviour preservation of the refactor
- **Hoisted `sourceStorageLocation`** replaces the Damaged-source `findById` (old `:332`, new `:350`). `unitload.storagelocation_id` is `bigint NOT NULL`
  (`V2.2.00__base_v2_schema.sql`, `CREATE TABLE public.unitload`), so the `findById(null)` → IllegalArgumentException case can't happen.
  The one behavioural delta: a dangling location id now throws `EntityNotFoundException` for every destination, including Damaged
  (before, the Damaged-destination arm never evaluated it). `scanUnitLoad:152` already throws for the same row, so this is consistent and acceptable.
- **Removed later `findByName(Nirwana/Shipped)`**: same objects, now fetched earlier. The only change is that a tenant with a missing
  Nirwana/Shipped location now fails before `setStockDamaged` instead of after it. It is an error either way, and the transaction rolls back
  (EntityNotFoundException: runtime exception or in rollbackFor). Net query count is +1 `findById` on the Damaged-destination path and +1 fix-assignment lookup. Negligible.

## Stage 2: code quality

### Location.equals (question 2): behaves exactly as in scanUnitLoad
`Location.java:163-167` is id-based: `getId() != null && getId().equals(other.getId())`, with the same shape as `AbstractBaseEntity:70-74`.
Both operands are the same types scanUnitLoad compares, loaded by the same repository calls, so the semantics are identical.
The id-0 Nirwana fixture (`NIRVANA_LOCATION_ID = 0L`) is non-null and compares correctly.

### Tests (question 3)
- **Attribution is good.** `assertRefusedBeforeAnyWork` pins the message *and* `name='<loc>'` (from `Location.toString`, `:170-176`),
  plus `never(findByUnitloadId)`, `never(doesUserHaveAccess)` (which fences the Damaged arms) and
  `verifyNoInteractions(unitloadBusinessService, stockunitBusinessService, billofladingPositionService)` (which fences every transfer and the carrier guard).
  A guard placed below the stock load, or below the Damaged arms, is red. The fixture ties `entity_lock` to the location, so a lock-keyed guard fails the Nirwana case.
- **The lenient stubs are justified.** They exist so the no-guard run reaches the transfer call rather than dying on an unstubbed mock.
  `findByLabelid("CASE-1")` is strict. `Stockunit.reservedamount` defaults to `BigDecimal.ZERO` (`Stockunit.java:18`), so `checkReservedStock`
  doesn't NPE pre-fix. That matches the author's claim that the pre-fix reds were assertion failures (moves completed silently), not a wrong-reason throw.
- **Fixture stub additions** (`MobileMoveUnitloadServiceUnitTest:487-491`, `MobileMoveUnitloadServiceTest:627-628`) are legitimate. The ids differ
  from the source location's (300 vs 1; 98 vs 10), so the guard passes and the unchanged assertion still pins the Nirwana-*destination* message.
  This does not weaken anything.
- **The sentinel test tightening** (`:454-456`, `hasMessage("Can not move " + sentinel)`) is a strengthening. It replaces a swallow-all `catch`,
  and it is the only thing that distinguishes `assertNotNirvanaSentinel` from the new Nirwana-location check, since the sentinel sits on Nirwana.
- **The AC-6a adaptation is sound** (`MobileMoveUnitloadClosedBolPurgeIT:161-181`). All three SBDEV-3487 data invariants are kept verbatim
  (positions intact, still on Shipped, lock still 405), the rejection is attributed to 3490 by message + `name='Shipped'`, and
  `shippedGuardWarns().isEmpty()` proves the layering. The backstop's own coverage survives in AC-6b (`:192-219`, still `assertShippedRejection(... MOVE_UNITLOAD_D0 ...)`).
  The `shippedGuardWarns()` extraction (`:397-403`) is a clean DRY move and is reused by `assertShippedRejection`.

## Findings

### [MEDIUM] Sibling (outside this diff, propose, don't widen): a container *destination* standing on Shipped is not refused
File: `MobileMoveUnitloadService.java:459-473`
Confidence: MEDIUM (reasoned from code; not reproduced)
Issue: the destination side of the container arm checks only `assertPalletNotAssignedToGate(destinationUnitLoad.getLabelid())`
(`BillofladingPositionService.java:52-60`: "has a BOL position keyed by *this* label"). A shipped **child** (a Case/Package on a shipped pallet, lock 405, on Shipped)
has no position keyed by its own label, and `transferUnitLoadToCarrier` checks no lock (per the ticket). So `destinationLabel=<shipped parcel>` would re-parent a live
unit load into a shipped tree. This is the mirror image of 3490 on the destination side. The location arm's `shipped.equals(destinationStorageLocation)` (`:361`)
does not cover it, because it compares the destination *location*, not the destination unit load's location.
Fix: propose on the ticket rather than widen this diff. A one-line `if (shipped.getId().equals(destinationUnitLoad.getStoragelocationId())) throw …` before `:472`,
plus a unit test that mirrors the new fixture. Needs a DB probe first (count child unit loads on Shipped that carry no own-label position).

### [LOW] Stale test comment now asserts a false fact
File: `MobileMoveUnitloadServiceUnitTest.java:402-405`
Confidence: HIGH
Issue: `"scanDestination RE-RESOLVES the same source (:277) and checks only ON_HOLD and reservations"`. As of this diff it also checks the Nirwana/Shipped location and fix-assignment.
The line refs (`:123 :133 :139 :144 :161 :277 :290 :264`) were already off and point nowhere now.
Fix: reword to "…checked only ON_HOLD and reservations before SBDEV-2995/3490", and drop the line numbers or replace them with symbol names.

### [LOW] AC-6a javadoc's first paragraph contradicts its second
File: `MobileMoveUnitloadClosedBolPurgeIT.java:130-132`
Confidence: HIGH
Issue: `"The Fix C throw is what rolls back the move out of Shipped"`. For AC-6a there is now no move and no Fix C throw. The new paragraph at `:134-137` says so, so the two sentences disagree.
The `@DisplayName("… is rejected and rolls back")` (`:140`) likewise implies a rollback that no longer happens.
Fix: drop or past-tense the Fix C sentence. Rename the display name to e.g. "AC-6a: selectDestination of a pallet standing on Shipped is refused before any write".

### [LOW] Backstop comment keeps a now-unreachable premise
File: `MobileMoveUnitloadService.java:511-513`
Confidence: HIGH
Issue: `"Runs after scanDestination's transferUnitLoadToLocation, so this throw is what rolls the move back out of Shipped"`. The following sentence (`:516-518`) correctly says a Shipped
pallet is now refused earlier. `handleTruckOffLoading`'s only caller is `:394`, so "move back out of Shipped" can no longer reach this line.
Fix: "…so this throw is what rolls the move back (scanDestination's rollbackFor includes BusinessException)". Drop "out of Shipped".

### [LOW] Fixed-assignment test pins only the container branch
File: `MobileMoveUnitloadServiceUnitTest.java:663-678`
Confidence: HIGH
Issue: only `PALLET-9` is exercised, and there is no ordering verify. A mutant that moves the fix-assignment check into the container `else` arm (just before `:473`)
still passes, because `verifyNoInteractions(unitloadBusinessService…)` still holds when the throw precedes the transfer. The location and flow-bin arms are then unguarded, and no test is red.
Fix: add `verify(locationRepository, never()).findByName("PALLET-9")` (the destination lookup at `:342`, which follows the check), or parameterize over `AISLE-01 / FLOW-01 / PALLET-9`.

### [LOW] "Before ON_HOLD" is part of the spec but not pinned
File: `MobileMoveUnitloadService.java:314-326`
Confidence: HIGH
Issue: every Shipped fixture has lock 405, never ON_HOLD, so swapping the location checks below the ON_HOLD check is green. The consequence is only message precedence
("Unit load is locked on hold!" vs "Can not move unit load from Shipped"), but the stated contract is scanUnitLoad parity.
Fix: optional. Add one case with source on Shipped + `entityLock = ON_HOLD` that asserts the Shipped message. Or accept and note it as intentionally unpinned.

### [LOW] Nirwana-source case covers only the location arm
File: `MobileMoveUnitloadServiceUnitTest.java:680-684`
Confidence: MEDIUM
Issue: acceptable because the guard is a single straight-line block, and `never(findByUnitloadId)` plus `never(doesUserHaveAccess)` put it ahead of all arms. Noted for completeness only.
Fix: none required.

### [LOW] User-facing message exposes `Location.toString()`
File: `MobileMoveUnitloadService.java:317,321` (copied from `:154,159`)
Confidence: HIGH
Issue: the operator sees `Can not move unit load from Location{xpos=…, ypos=…, name='Shipped'}`. This is deliberate parity with scanUnitLoad, and the IT/unit tests now key on `name='…'`,
so changing it later means touching both methods and the tests together.
Fix: none in this ticket. If the wording is ever cleaned up, change both sites and the `name='` assertions in one commit.

### [LOW] Duplicated guard block (DRY), accepted trade-off
File: `MobileMoveUnitloadService.java:150-160,173-177` vs `:314-322,335-338`
Confidence: HIGH
Issue: two copies of the same four checks. The `assertNotNirvanaSentinel` javadoc now enumerates which checks live where, which is a prose enumeration that will rot the first time someone edits one copy.
Fix: optional follow-up. Extract `assertSourceMovable(Unitload, Location, String label)` used by both methods (keep the fixed-assignment call after the stock ON_HOLD loop in both),
and let the javadoc name the method instead of listing the checks.

## Open questions (low confidence, non-blocking)
- None at CRITICAL/HIGH.
- Sibling sweep, informational: the web Move Stock container arm (`StockunitService.java:~539-540`) is fenced by `SourceLockGuard.assertSourceUnlockedForContainerRelocation` (SBDEV-3341),
  which refuses a lock-405 source. So the web path is covered by lock, not location. No action.

## Positive observations
- Guard placement is exactly right: after the sentinel identity check (which preserves the SBDEV-2995 "no 210k-row load" contract) and before the first read of stock or any write.
- The Shipped/Nirwana lookups are reused for the destination checks instead of re-queried, and the Damaged-source lookup reuses the hoisted location. The refactor is tidy.
- The new tests are built to fail for the right reason: a fully-stubbed happy path, locks tied to locations, and ordering pinned by `never`/`verifyNoInteractions`.
- Tightening the sentinel test after PIT showed it could no longer tell the layers apart is good mutation discipline.
- The AC-6a adaptation follows the test's own pre-written coupling instruction ("adapt the key assertion, keep the data assertions") to the letter, and adds a negative WARN assertion that proves the layering.

## Recommendation
**APPROVE.** No CRITICAL or HIGH findings. Fix the three stale comments and the fixed-assignment ordering pin (all Low) in the same pass, per the address-Lows rule.
Propose the MEDIUM destination-side sibling on the ticket (sub-T3, so it goes on SBDEV-3490 itself if Nam wants it in scope; otherwise it goes in a proposal).
