---
ticket: "SBDEV-3758"
kind: evidence
lane: independent code review (read-only)
created: 2026-10-13
code: wms2-api 260a91f6 vs parent 8553299d (origin/develop)
verdict: APPROVE
---

# SBDEV-3758: code review of 260a91f6

**Verdict: APPROVE.** There are no High findings. There are 2 Medium findings and 8 Low findings,
and none of them blocks the merge. Per standing policy, fix the Lows in the same pass.

## What I ran (in my own detached worktree `/tmp/claude-1000/cr-3758`, now removed)

- `mvn -o test-compile` on JDK 21: **EXIT 0** (main and test lanes both compile, so the constructor change is wired).
- `-Dtest=MobileTransferOrderServiceUnitTest,MobileTransferOrderServiceIntegrationTest`: **44 run, 0 failures**, BUILD SUCCESS.
  The two IT methods ran. (Under that selector the H2 `tenant_discovery` DDL error appears on green runs as well, so it is noise.)
- **Mutation M1**: I disabled the lane pre-check (`if (false && laneLock != null ...)`). Result: **3 failures**, the three
  `shouldRefuseBeforeMinting_whenTransferLaneIsLocked` cases. The new lane assertion is armed.
- **Mutation M2**: I ran the parent's `MobileTransferOrderService` (relocation arm restored) against the new IT. Result: **1 failure**
  in `transferOrder_MoveBothUnitLoadsTest` (`expected: 35L`, the pick-face container's location). The core invariant assertion is armed.
- Source-lock pre-check tests, checked by reasoning against the mocks: if the guard is removed, the mocked `createUnitload` and
  `transferStockToUnitLoad` do not throw, so `assertThatThrownBy` goes red. If the guard is moved below a mint,
  `verifyNothingMintedOrMoved` goes red. If it is kept only on the whole-stock arm, the reserved and partial cases go red. All armed.
- Live DB, read-only:
  - WineCo PRD: `fix_location_assignment` has 1557 rows. 0 locations carry more than one FLA, so `findByAssignedlocationId`
    (an Optional) cannot throw for the newly routed population. 0 locations have a null `entity_lock`. 0 transfer lanes are locked.
    `fla_ul_off_bin = 3`, which agrees with the architect.
  - Hydra PRD: 135 FLAs, 0 duplicates, 0 null locks, 0 locked lanes, 0 off-bin.

## Stage 1: spec compliance — PASS

- The whole-stock arm no longer calls `transferUnitLoadToLocation`. It always does `createUnitload` followed by
  `transferStockToUnitLoad(..., ignoreLock=false, removeUnitLoadIfEmpty=true)`. For a UL on its FLA bin, the split
  (`fixLocationAssignment != null`) keeps the container and a 0-SU on the bin. The IT proves this, and M2 shows the IT would catch a regression.
- SourceLockGuard is hoisted above all three mints, and a transfer-lane lock pre-check is added. This is the architect's GO-WITH-CHANGES item.
- The `FixLocationAssignmentRepository` and `UnitloadBusinessService` dependencies are removed. There is no other
  `new MobileTransferOrderService(` anywhere in src, so `@InjectMocks` and the Spring context were the only construction sites, and both compile and pass.

## Findings

### [MEDIUM] M-1. The commit message says more than the change delivers about orphan unit loads
Commit 260a91f6, body: *"Source-lock (SourceLockGuard) and transfer-lane-lock refusals now run above every arm's createUnitload, so a
refusal no longer leaves an empty unit load minted on the lane"*
Confidence: HIGH. Only **lock** refusals moved. Several refusals inside `transferStockToUnitLoad` still fire after the mint has committed:
- `"amount=... requested is more than available="` (`StockunitBusinessService.java:~206`), from the controller's detached SU being stale
- `"Stock not allowed on destinationUnitload="` (`:~212`). The item's default UL type has `stockunitallowed=false`.
- A lock that lands between the plain-read pre-check and the `findByIdForUpdate` re-check
- A null lane or SU `entity_lock`. The pre-check passes it by the permissive-null rule, but the split's `int lock = ...getEntityLock()` auto-unboxes and NPEs **after** the mint. PRD has 0 such rows, so this is latent.
The in-code comment ("the lock refusals run ABOVE every arm's createUnitload") is accurate. Only the commit/PR prose overclaims.
Fix: in the PR body and on the ticket, say "a *lock* refusal no longer leaves...", and list the remaining post-mint refusals as known residuals (the architect already named the first two).
A cheap optional extra: pre-check `defaultUnitLoadType.getStockunitallowed()` next to the lane check.

### [MEDIUM] M-2. The new comment claims "same text" as the split's refusal, and it is not the same text
`MobileTransferOrderService.java` (lane pre-check comment):
`// ... Same text as that refusal, so an operator sees one message whichever arm runs.`
Confidence: HIGH. The pre-check emits `"Destination location=X is locked=" + LockRefusalMessages.describe(laneLock)`, which renders as `is locked=104 (ON_HOLD)`.
The split's refusal is the bare `"Destination location=" + name + " is locked=" + lock`, which renders as `is locked=104` (`StockunitBusinessService.java:~316`).
The same gap exists for the source UL and location messages. SourceLockGuard uses `describe()`, while the split (`:~293, :~297`) uses the raw code.
**Behavioural consequence:** the pre-check now runs first on every arm. The reserved, partial and non-FLA whole-stock arms used to show
`Source unitLoad=UL is locked=104` and now show `... is locked=104 (ON_HOLD)`. This is arguably an improvement (SBDEV-3226 precedent), but
it is an operator-visible text change on arms the ticket did not target, and the comment hides it. The "one consistent message" claim
in `SourceLockGuard`'s method javadoc ("same message shape") also over-states this, though that is pre-existing.
Tests use `hasMessageContaining("is locked=104")`, so they pass under either form. No exact-equality assert exists in src/test.
Fix: reword to "same prefix as that refusal (plus the describe() state name, as SourceLockGuard renders it)", and note the operator-text change on the ticket.
Medium rather than Low because a "same text" claim in a comment is the kind of thing the next reader relies on.

### [LOW] L-1. Stale SBDEV-3353 comment still names the removed arm
`MobileTransferOrderService.java:379-380`: `// ... above every arm that writes (FLA whole-container relocation and the three splits), each of which ...`
Confidence: HIGH. After this commit there are three arms, all of them splits. Fix: `(the three splits)`.

### [LOW] L-2. Stale IT javadoc on the SBDEV-2371 test
`MobileTransferOrderServiceIntegrationTest.java:446-449`:
`* <p>The third source deliberately carries NO {@code FixLocationAssignment}, so it takes {@code transferStock}'s split branch ... rather than the whole-container relocation the other two take`
Confidence: HIGH. Source 1 is now also split (and source 2 never moves in that test). The distinction is now "partial amount vs. whole
stock", not FLA vs. non-FLA. Fix: "...so it takes the partial-amount split (an explicit `amountLeft`) rather than the whole-stock split source 1 takes — that branch is where the cap is applied".

### [LOW] L-3. A unit-test method name still keys on FLA
`MobileTransferOrderServiceUnitTest.java:~1067`: `void transferStock_shouldSplitTheWholeStock_whenTheSourceIsACaseWithNoFla()`
Confidence: HIGH. The display name was updated ("on the whole-stock split arm"), but the method name was not. FLA presence no longer selects an arm. Fix: rename to `..._whenTheSourceIsACase`.

### [LOW] L-4. An IT comment states the FLA rule as unconditional
`MobileTransferOrderServiceIntegrationTest.java:~372-373`: `// The pick face keeps its (now empty) stock unit: transferStockToUnitLoad never sends an FLA source's stock unit or container to Nirwana.`
The new service comment says the same thing ("keeps a pick face's container").
Confidence: HIGH. `transferStockToUnitLoad` keys the FLA on the **source location** (`findByAssignedlocationId(sourceLocation.getId())`), not on the UL.
An FLA container that is off its bin takes the full-move branch, and `relocateEmptiedContainer(..., CODE_SEND_TO_NIRVANA)` retires it.
The architect recorded this as residual (fix B). PRD has 3 such rows, all in Nirwana with 0 stock, so the exposure is nil today. The comments should still not assert the stronger rule.
Fix: "...never sends a source on an FLA bin to Nirwana (the FLA is looked up by location — an FLA container already off its bin is not protected; fix B)".

### [LOW] L-5. The pre-check resolves the source UL from the detached row, not the fresh re-read
`MobileTransferOrderService.java`: `final Long sourceUnitLoadId = stockUnit.getUnitloadId();` … `Stockunit freshSource = stockunitRepository.findById(stockUnit.getId()).orElse(stockUnit);`
Confidence: MEDIUM. If the SU was re-parented between the controller's read and this call, the guard pairs a fresh SU with the old UL and location.
The in-transaction re-check uses the locked SU's own `unitloadId`, so correctness holds and only the early refusal can be wrong.
The same SU is also read twice by plain `findById`: once inside the `SourceContainerGuard.assertStockNotInParcel(...)` argument and once for `freshSource`.
Fix: read `freshSource` once above the parcel guard, pass it to both guards, and derive `sourceUnitLoadId` from `freshSource.getUnitloadId()`.

### [LOW] L-6. No test proves the fresh re-read is the one judged
`MobileTransferOrderServiceUnitTest`: `stockunitRepository.findById(300L)` is unstubbed in the lock-refusal fixtures, so `.orElse(stockUnit)` returns the same instance as the argument.
Confidence: HIGH. If the code passed the detached `stockUnit` to the guard, every test would stay green. This pattern was inherited from SBDEV-3341, and the hoist widened its reach.
Fix: add one case where the argument SU is NOT_LOCKED but `findById(300L)` returns a copy with PICKED_FOR_GOODSOUT, and assert the refusal.

### [LOW] L-7. Import order
`MobileTransferOrderService.java:12-14`: `SourceContainerGuard`, then `LockRefusalMessages`, then `SourceLockGuard`. The new import is wedged between two `Source*` imports, out of alphabetical order. Fix: put `LockRefusalMessages` before `SourceContainerGuard`.

### [LOW] L-8. The guard's name now misdescribes one of its two call sites
`SourceLockGuard.assertSourceUnlockedForContainerRelocation(freshSource, sourceUnitLoad, sourceLocation);` is now called as a pre-check for a **split**.
Confidence: HIGH. The class javadoc was updated to explain this, which is good. The method name and its `@throws`/"Refuses the relocation" wording still say relocation.
Fix: optional. Either rename it (two call sites) or add one line to the method javadoc: "also used as the split pre-check in MobileTransferOrderService".

## Open questions (not blocking)

- **[MEDIUM, confidence LOW] An audit/monitor signal changes.** As the architect noted, the old arm wrote one `unitload_record` TRANSFERRED with a NULL activity code. The new path writes a MANUAL_SPLIT removal/creation pair plus an amount-0 STOCK_CREATED row (the SBDEV-3382 artefact). Any query or monitor built on the sizing doc's `activitycode IS NULL` signature will go quiet after deploy, which would look like the problem stopped rather than moved. Worth one line on the ticket.
- Non-FLA sources now get three extra plain reads and earlier refusals. The outcome set is unchanged, because all three arms already passed `ignoreLock=false` and the guard checks the same three entities. Only the timing and the message suffix change (M-2).

## Positive observations
- The ordering is deliberate and correct. The pre-check sits below the "No stock required" exit and the parcel guard, and above every mint. The lane check reuses the already-loaded `transferLane`.
- The tests cover every arm for both the source-lock and lane-lock pre-checks. `verifyNothingMintedOrMoved` pins "nothing minted", not just "threw".
- The rewritten IT asserts the actual invariant: each FLA's container is still on `fla.getAssignedlocationId()`, with a 0-SU, and the lane holds 12 in non-pick-face ULs. M2 confirms it goes red on the pre-fix code.
- The dependency removal is clean. No dead fields remain, there are no other construction sites, and both lanes compile.
- The stale-sibling sweep in `StockunitService` and the `SourceLockGuard` javadoc was done in the same commit.

## Counts
High 0 · Medium 2 · Low 8 (plus 1 open question)

---

## Round 2: delta 260a91f6 → c73b15fa (parent still 8553299d)

**Verdict: APPROVE.** All 10 round-1 findings are fixed. The delta adds 2 new Low findings and 0 Medium or High.

### What I ran (fresh detached worktree at c73b15fa, now removed)
- `-Dtest=MobileTransferOrderServiceUnitTest,MobileTransferOrderServiceIntegrationTest,NeverMatcherNullBlindnessArchTest` ran **49 tests with 0 failures**, BUILD SUCCESS. The ArchTest passing confirms the `MobileTransferOrderServiceUnitTest:4` inventory entry matches the real count.
- **L-6 mutation, reproduced independently.** I changed the guard argument from `freshSource` to `stockUnit`. That gave **exactly 1 failure**, `shouldRefuseBeforeMinting_whenOnlyTheReReadStockUnitIsLocked:802`, and the other 42 stayed green. This matches the lead's claim.

### Per-finding check
| # | Fixed? | Evidence |
|---|---|---|
| M-1 | yes | The commit body now reads "so a LOCK refusal no longer leaves...". It lists the four post-mint refusals and the `(ON_HOLD)` text change on the other arms. The same residual list also appears as a `⚠ Only LOCK refusals moved` comment above the pre-check. |
| M-2 | yes | The comment now reads "Same prefix as that refusal ("Destination location=X is locked=N"), plus the describe() state name ... e.g. "is locked=104 (ON_HOLD)"". |
| L-1 | yes | Now "(the three splits)". |
| L-2 | yes | The IT javadoc now describes the partial-amount split vs. the whole-stock split, and notes that FLA "no longer selects an arm". |
| L-3 | yes | Renamed to `transferStock_shouldSplitTheWholeStock_whenTheSourceIsACase`. |
| L-4 | yes | The IT comment and the service comment both say the FLA is looked up by source LOCATION and that a container off its bin is not protected. See R2-L1 for the service wording. |
| L-5 | yes | There is one `freshSource` read above `SourceContainerGuard`, passed to both guards. `sourceUnitLoadId = freshSource.getUnitloadId()`. The SBDEV-3353 cross-reference was repointed to the SBDEV-3758 pre-check. |
| L-6 | yes | The new test is mutation-verified (above). Its fixture is right: the argument is NOT_LOCKED from setUp, and only the stubbed re-read carries 100. |
| L-7 | yes | The import order is now `LockRefusalMessages`, `SourceContainerGuard`, `SourceLockGuard`. |
| L-8 | yes | The method javadoc gained a paragraph: "Despite the name, it is also the pre-check ahead of a SPLIT...". |
| ArchTest 5→4 | correct | The deleted `transferUnitLoadToLocation` never() sites took their primitive-param matchers with them, and the ArchTest is green at 4. |

### New findings (Low)

**[LOW] R2-L1. The service comment points at a "central guard" that does not exist**
`MobileTransferOrderService.java:433`: `// container already OFF its bin is not protected here; that is the central guard's job.`
Confidence: HIGH. `git grep -i "central guard" c73b15fa -- src` returns only this line. Nothing in src is a central guard yet; it is the architect's "fix B", which has not been built. A reader will go looking for a guard that is not there and conclude the off-bin case is covered.
Fix: "...not protected here (fix B, not yet built — see SBDEV-3758 architect consult)", or name the ticket once one exists.

**[LOW] R2-L2. The SourceLockGuard method javadoc still claims message parity**
`SourceLockGuard.java` method javadoc: `Checks the same three sources, in the same order and with the same message shape, as {@code StockunitBusinessService.transferStockToUnitLoad}'s {@code if (!ignoreLock)} block, so an operator sees one consistent error whichever arm a move takes.`
Confidence: HIGH. This was pre-existing and flagged in round 1 under M-2 as "also over-states", but it was not changed. The guard renders `describe()` (`104 (ON_HOLD)`) for the unit load and location, and the split renders the bare code. The new paragraph added directly above it (L-8) makes the stale sentence more likely to be read.
Fix: "same three sources, in the same order, with the same message prefix (the guard appends the describe() state name)".

### Counts, round 2
High 0 · Medium 0 · Low 2 (new). All 10 round-1 findings are verified fixed.
