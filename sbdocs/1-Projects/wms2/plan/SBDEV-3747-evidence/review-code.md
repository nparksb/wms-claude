---
ticket: SBDEV-3747
lane: code-review (independent)
date: 2026-10-13
worktree: .claude/worktrees/wms2-api/SBDEV-3747 (uncommitted diff on 11468c4a)
verdict: COMMENT (no HIGH at HIGH confidence; one MEDIUM on the operator message is worth fixing before commit)
---

# SBDEV-3747 — independent code review

Scope: `git diff` of 3 files. These were read in full or in the relevant range: `ReplenishmentOrderMessages.java`,
`MobileMoveUnitloadService.java` (`scanUnitLoad`, `checkReservedStock`, `scanDestination`, `transferStock`),
`ReplenishmentOrderSourceSyncService.syncForMovedStockUnit`,
`ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit`,
`UnitloadBusinessService.processTransfer/sendToNirvana/sendToClearing`,
`StockunitBusinessService.transferStockToUnitLoad`, `ReplenishorderService.existsForStockUnit` and
`ReplenishorderRepository` (finders).
No build was run in the worktree, as instructed. Existing evidence: `target/surefire-reports/...$Sbdev3747ReplenHeldStockMove.txt`
reads `Tests run: 4, Failures: 0`. It was written at 12:07:32, after the last source edit at 12:03:58.
Compile check by inspection: `service.mobile` imports `net.aim_ai.wms.service.*`. The two builders are now `public`, so
they resolve. The test uses `isNull`/`anyBoolean`, which come in through `import static org.mockito.Mockito.*` (Mockito extends ArgumentMatchers).

## Stage 1 — spec compliance
- Guard placed before the drain in `transferStock`. All three stock-moving arms reach it: flow-bin location (with or without an FLA), an FLA-backed destination unit load, and `isMoveStock` onto a pallet, including the inbound-pattern branch. **Met.**
- `>= STARTED` reuses `replenBlockMessage`, and not-started uses the new `replenHoldsStockMessage`. **Met.** The boundary is right: `STARTED=500` is inclusive and also covers 530.
- The order is named. **Met.**
- Accuracy of the operator remedy: **not met in the common case.** See F1.

## Findings

### [MEDIUM] F1 — the not-started remedy sends the operator into a loop
Confidence: HIGH
File: `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMessages.java` (new `replenHoldsStockMessage`) and its javadoc
```
"; move the whole unit load to a location, or cancel the replenishment, before moving its"
+ " stock onto a flow bin or another unit load."
```
and the javadoc: *"the location/carrier arms re-point such a replen and let the move through, so the operator is pointed there instead"*.

What the location arm actually does (`UnitloadBusinessService.processTransfer:533-538` → `syncForMovedStockUnit`):
- **Replenishable destination** (the usual storage location): `ReplenishmentOrderSourceSyncService:113-117` re-points the
  source triple. The code comment there says it explicitly: *"stockunitId / reservedamount / requestedamount intentionally UNCHANGED (I-1)"*.
  The replen therefore **stays bound to the same stock unit**. The operator's next try (the flow-bin or pallet stock move)
  calls `existsForStockUnit` again, finds the same order and is refused with the same message. The suggested first
  remedy does nothing toward the operator's goal.
- **Non-replenishable destination** (lane, clearing, staging): `reassignOrCancelForMovedStockUnit:308-310` either
  REDIRECTs to another candidate SU, which unbinds this one, or cancels on NO_CANDIDATE. Either outcome unblocks the next move.
  **CONTENDED** (SBDEV-3637 Fix D, `:299-307`) defers. The order keeps `stockunitId`, so the next move is still refused.
- `checkReservedStock` does not interfere. A reserved SU with an active replen is `continue`d (`MobileMoveUnitloadService:272`),
  so the location move itself is accepted. That half of the javadoc is correct.

So the message is accurate only for a non-replenishable destination with an uncontended redirect or cancel. An operator
following it literally (move the case to a rack slot, then scan it to the flow bin) gets refused twice.
Fix: make cancellation (or completing the replen) the remedy. Say that a location move keeps the replen and re-points it, and drop
the implication that a location move unblocks the stock move. For example:
`"Replenishment order X holds this stock (source S); cancel it, or complete it from Replenish, before moving its stock onto a flow bin or another unit load. Moving the whole unit load to a location keeps the replenishment (it follows the stock)."`
Update the javadoc and the `NOT_STARTED_MESSAGE` constant in the test to match.

### [LOW] F2 — "merge the stock unit away" holds for only one of the two drain branches
Confidence: HIGH
File: `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:740`
```
// SBDEV-3747: these arms merge the stock unit away, so they cannot re-point a bound replen the way
```
`StockunitBusinessService.transferStockToUnitLoad:328-341`: when the destination has no same-item SU **and** the source location
has no FLA, a full-amount move **re-parents the same row** (`sourceStockunit.setUnitloadId(...)`). The SU id survives, so a
replen bound to it would still be validly bound and could in principle be re-pointed. Only the merge branch (`:382-392`, source → 0
→ `sendStockUnitToNirvana`) truly merges it away. Empty pallet via `isMoveStock` and empty flow-bin unit load are re-parent cases.
Refusing in both cases is still a defensible, conservative choice, because neither branch runs `syncForMovedStockUnit`. Only the stated reason is wrong.
Fix: reword it as "these arms either merge the stock unit away (merge branch → Nirvana) or re-parent it without running
syncForMovedStockUnit (only the pick-line realign runs); in both cases a bound replen would be left stale". Apply the same reword to the nested-test javadoc.

### [LOW] F3 — `existsForStockUnit` is an Optional finder over a predicate that can match several orders
Confidence: MEDIUM
File: `MobileMoveUnitloadService.java:745` → `ReplenishorderService.existsForStockUnit:421` → `ReplenishorderRepository:129`
```
Replenishorder heldBy = replenishorderService.existsForStockUnit(sourceStockUnit);
```
SBDEV-3622 established that one SU can carry more than one open order (`ReplenishorderRepository:226-228`: *"unlike
findIdByStateLessThanAndStockunitId above it must not throw when the SU carries more than one order"*). With two holders this
call throws `IncorrectResultSizeDataAccessException`, which becomes a 500 rather than a named refusal. If one holder is STARTED and
another is not, the message choice is also arbitrary. Exposure added by this diff is small, because `checkReservedStock` already calls the same
finder for every SU with `reservedamount != 0`, so in the normal case the 500 fires there first. The new call adds the
`reservedamount == 0` (drift) case, which is exactly the case this ticket targets.
Fix (optional, cheap): read `findHoldersByStateLessThanAndStockunitIdOrderById(FINISHED, id)`, refuse if non-empty, and pick the
in-progress message if **any** holder is `>= STARTED`. Name the first holder, or all of them. Otherwise record it as a known limitation.

### [LOW] F4 — the refusal comes after avoidable writes on two branches
Confidence: HIGH
File: `MobileMoveUnitloadService.java:451` (`fixLocationAssignmentService.createFixedLocationAssignment(...)` in the flow-bin-without-FLA
branch) and `:497` (`unitloadService.createUnitload(...)` in the inbound-pattern branch with `isMoveStock`). Both run before
`transferStock` and so before the new guard. `scanDestination`'s `rollbackFor` includes `BusinessException`, so nothing persists.
They still do wasted work and may burn sequence numbers. Also, `setStockDamaged/removeStockDamaged` (`:384-394`) flush stock updates first.
This is consistent with where `SourceContainerGuard.assertNotParcel` already sits (same block, same rationale), so it is not a defect.
Fix (optional): leave it, or hoist a stock-arm-only check above the branch fork. The arm is decidable once the destination is resolved, but that adds
branch-shape coupling. I would leave it and add one clause to the comment saying the earlier writes are rolled back.

### [LOW] F5 — the class javadoc still says "TWO sites"
Confidence: HIGH
File: `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMessages.java:8-11`
```
* <p>The {@code >= STARTED} block is thrown from TWO sites: ... Both call this builder so the two messages cannot drift
```
There are now three `replenBlockMessage` call sites: `ReplenishmentOrderSourceSyncService:100`, `ReplenishmentOrderMaintenanceService:285`
and `MobileMoveUnitloadService:748`. The new paragraph explains the visibility but leaves the count stale. "Prose enumerations rot":
state the rule ("every site that refuses a move for an in-progress replen calls this") instead of a count.

### [LOW] F6 — the fixtures prove only the drift case; the realistic reserved case is untested
Confidence: HIGH
File: `src/test/java/.../MobileMoveUnitloadServiceUnitTest.java` (`Sbdev3747ReplenHeldStockMove.arrive`)
```
stock.setReservedamount(BigDecimal.ZERO);
```
This is a deliberate and well-explained choice. The consequence is that no test runs the **normal** production shape (`reservedamount == requestedamount > 0`).
In that shape `checkReservedStock` calls `existsForStockUnit` first and must `continue`, not throw a different message, before
the new guard runs. Today it does (`:272`). A future edit to `checkReservedStock`, for example "block reserved stock held by a replen",
would change the operator message on these arms, and no SBDEV-3747 test would notice.
Fix: add one case with `stock.setReservedamount(new BigDecimal("4"))` and the same exact-message assertion. Optionally add a
`state == null` case (→ not-started message) to pin the null-safe direction of `heldBy.getState() != null &&`.
The tests cannot pass for the wrong reason. Each refusal asserts the exact message string plus `never()` on the
transfer, nirvana and clearing calls, and with the guard removed the mocked transfer runs and no exception is thrown, so all three go red. The
`[pin]` test verifies the transfer with exact arguments. The flow-bin-without-FLA branch (`createFixedLocationAssignment`) is not
covered, which is acceptable because it reaches the same `transferStock` line.

### [LOW] F7 — only `stockUnits.get(0)` is checked; this is pre-existing and handled downstream
Confidence: MEDIUM
File: `MobileMoveUnitloadService.java:731-751`
The FLA-backed-unit-load and `isMoveStock` arms do not refuse a multi-SU source (only the flow-bin-without-FLA branch checks `size() > 1`).
`transferStock` moves SU[0] only. The source then goes to `sendToClearing` (DEFAULT/PACKAGE/other) or EmptyPallets
(PALLET/CART) with SU[1..] still on it. Those routes run `processTransfer` → `syncForMovedStockUnit`, so replens on SU[1..] are re-pointed
or reassigned rather than orphaned. For BOX, `sendToNirvana` throws "has stock". No change needed for this ticket, but a pallet
carrying stock landing in EmptyPallets is odd behaviour worth a line on the ticket.

### [LOW] F8 — the replen read is unlocked (TOCTOU)
Confidence: MEDIUM
File: `MobileMoveUnitloadService.java:745`
The sync path locks the replen row (`findByIdForUpdate`), but this guard reads it plainly. A replen created between this read and
`transferStockToUnitLoad`'s SU lock reserves at creation, so the incidental available-amount guard (which re-reads under
`FOR UPDATE`, `StockunitBusinessService:206-212`) still catches it. The residual window needs drift plus a concurrent
create. That is acceptable and needs no change. It is mentioned so nobody later describes the guard as race-free.

## Visibility change (`ReplenishmentOrderMessages` → public)
Acceptable. It is a final, stateless builder with a private constructor, and making it public is the smallest change that keeps a single wording source.
No test or ArchUnit rule depends on it being package-private (`grep -rln ReplenishmentOrderMessages src/test` → none). An alternative that
would also serve the siblings below: a `ReplenishorderService.assertNoOpenReplenHolds(Stockunit, ...)` that owns both
the lookup (list-based, F3) and the message. That would keep the builder package-private. It is not required.

## Siblings — same "stock moved out from under an open replen" class
Every other full-drain caller of `StockunitBusinessService.transferStockToUnitLoad` relies on the same incidental guard
(`amount <= amount - reservedamount`, `:210-212`), which is unconditional on `ignoreLock`. Each is exposed the same way once the
reservation drifts to 0:
- `MobilePutAwayService:568`: `transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad, sourceStockUnit.getAmount(), CODE_PUT_AWAY, ...)`. A full drain into an FLA unit load. Its source is normally on a putaway-lane pallet, so a replen source is unlikely but not excluded.
- `CustomerorderService:666` (packaging, `ignoreLock=true`, full amount), `BillofladingService:1117` (full amount into the parcel).
- `StockunitService:597/605` (web split/damage, `ignoreLock=true`), and `:378/382/428/634`, `MobileTransferOrderService:429-440` (MANUAL_SPLIT, partial).
- Structural: the **re-parent branch** of `transferStockToUnitLoad` (`:337-349`) runs only the pick-line realign and never
  `syncForMovedStockUnit`. Every caller that moves a whole replen-bound SU between unit loads therefore leaves the replen's
  `requestedlocationId`/`sourcelocationname` stale even when the move is legal. This is the invariant-level version of this ticket.
  The fix would be "in the BLOCK_REALIGN bucket, sync or refuse when the SU has open replen holders", inside
  `transferStockToUnitLoad`, rather than per caller. It is multi-caller and touches reservation semantics, so I'd tier it T2–T3 and **propose** it rather than file it.
  If you pick one first, pick the re-parent-branch sync gap: it applies without any drift, while the drain siblings need drift.

## Open questions (surfaced, not blocking)
- [MEDIUM, conf LOW] **Manual replen into its own destination.** When the scanned flow bin is the replen's destination, the operator is
  doing the replenishment by hand. Before this fix, that was refused incidentally by the reservation. Now it is refused by name, and the only way out is to cancel.
  No regression, but product may want "complete it from Replenish" spelled out (F1's rewording covers it).
- [LOW, conf LOW] `checkReservedStock` loads the `Replenishorder` as a managed entity (`existsForStockUnit`) earlier in the same
  transaction that later runs `syncForMovedStockUnit`'s `findByIdForUpdate` on the location/carrier arms. That is the SBDEV-3244 F5 "lock upgrade"
  shape. It is pre-existing and this diff does not change it (the new call is on the stock arms only, which never sync SU[0]).

## Positive observations
- Placement is right in the ways that matter. The guard runs after every more specific source diagnosis (Shipped/Nirwana/ON_HOLD/FLA source/parcel),
  and **before** `transferStockToUnitLoad`'s Hook-B Pickingorder lock, so no PO lock is taken before the refusal.
- The STARTED boundary reuses the shared builder, so all three in-progress refusals read identically.
- The tests assert exact messages and `never()` on every downstream mutation, and include a pin for the happy path. The nested-class javadoc
  explains why `reservedamount = 0` was chosen and that the incidental guard is absent under mocks, which is honest about what the fixture proves.
- The comment states the real defect (the incidental guard names no order and fails open on drift) rather than restating the code.

## Recommendation
**COMMENT.** Nothing is blocking. Fix F1 (operator remedy text) before commit, because it is user-facing and currently tells the
operator to do something that, in the common case, does not unblock them. F2/F5 are cheap comment corrections, and F6 is one more
test. F3 is optional hardening. The siblings section is for a separate proposal and does not belong in this ticket.

## Re-review (delta only, 2026-10-13)

Read-only. Re-ran `git diff` (now 4 files, including `NeverMatcherNullBlindnessArchTest.java`). I ran no build.
⚠ No green is confirmed by this lane. `target/surefire-reports/` holds no SBDEV-3747 or NeverMatcher report at the moment
(the suite running in this worktree appears to have cleaned `target/`). The test file was last modified at 12:10:20, after
the first-round report. Take the pass/fail verdict from that suite run, and check its run COUNT for
`$Sbdev3747ReplenHeldStockMove`. The expected count is **6**.

### Disposition of first-round findings
- **F1, resolved.** The message now reads `"...; complete or cancel the replenishment before moving its stock onto a flow bin or another unit load."`
  That is accurate on every path: cancelling or finishing the replen moves the order to `state >= FINISHED`, so
  `existsForStockUnit` (`state < FINISHED`) stops matching. The test constant `NOT_STARTED_MESSAGE` matches it character for character.
- **F2/F4, resolved.** The new comment is accurate. I checked `StockunitBusinessService.transferStockToUnitLoad`: the merge branch
  (`:382-392`) and the re-parent branch (`:337-349`) run only the pick-line realign and record writes, and neither calls
  `syncForMovedStockUnit`. "Runs after the flow-bin FLA / inbound-pallet creation ... the throw rolls those back" is correct
  (`scanDestination` declares `rollbackFor = {BusinessException.class, FacadeException.class}`).
- **F5, resolved but with a leftover** (R2 below).
- **F6, resolved.** `scanDestination_shouldRefuse_whenTheReplenStillReservesTheStock` (reserved = 4) runs `checkReservedStock`.
  Its `existsForStockUnit(stock)` stub returns the replen, so the SU is skipped (`continue`), and the exact-message assert proves the refusal
  comes from the new guard, not from the pick-reservation throw. `..._whenTheReplenStateIsNull` kills the
  removal of `heldBy.getState() != null`, which would otherwise unbox and throw an NPE, so the message assert goes red.
- **NeverMatcher inventory 3 → 5: correct.** The inventory counts primitive-capable matcher **positions** inside `never()` spans, not
  spans. The one new span (`assertRefusedWith`, `transferStockToUnitLoad(..., anyBoolean(), anyBoolean())`) adds 2. Params 7-8 are
  declared `boolean ignoreLock, boolean removeUnitLoadIfEmpty` (`StockunitBusinessService:170`), so `anyBoolean()` is the required
  form. The two `never()` on `sendToNirvana`/`sendToClearing` take `(Unitload, String, String, String)`, all reference types, so they add 0.
  There are now two such spans in the file (`:2007`, `:2541`). The comment "One new never() ... (params 7-8)" is consistent
  with +2, mirroring the SBDEV-3353 entry above it. (The first-round diff did not touch the inventory, so the arch test would
  have been red at 3. That is now fixed.)
- **F3, declined; F7/F8, left as is.** Declining F3 is reasonable for T1: the shared finder already throws first via `checkReservedStock`
  whenever stock is reserved, and the change belongs with all callers. Recording it on the ticket is the right home.

### New findings in the delta
**[LOW] R1: the javadoc overstates "a location move does NOT free the stock"**
Confidence: HIGH
File: `ReplenishmentOrderMessages.java` (`replenHoldsStockMessage` javadoc)
```
* first does NOT free the stock, since {@code syncForMovedStockUnit} re-points the replen and keeps it
* bound to the same stock unit.
```
That holds only for a **replenishable** destination (`ReplenishmentOrderSourceSyncService:113-117`, I-1). On a non-replenishable
destination, `reassignOrCancelForMovedStockUnit` REDIRECTs to another SU or cancels on NO_CANDIDATE (`ReplenishmentOrderMaintenanceService:308-310`),
and either outcome does free this stock. The operator message is unaffected. Only the javadoc's reason is too broad.
Fix: "moving the whole unit load to a (replenishable) location does NOT free the stock: syncForMovedStockUnit re-points
the replen and keeps it bound to the same stock unit. A non-replenishable destination may redirect or cancel it, but that is not
something to send an operator to."

**[LOW] R2: the class javadoc says THREE but still argues for two**
Confidence: HIGH
File: `ReplenishmentOrderMessages.java:9-15`
```
* <p>The {@code >= STARTED} block is thrown from THREE sites: the SBDEV-2074 refactor split it across
* the replenishable-destination path (...) and the non-replenishable-destination path (...). Both call this
* builder so the two messages cannot drift ...  SBDEV-3747 added the third: ...
```
After "THREE sites", the sentence that follows lists two and says "Both"/"the two messages". The next paragraph then repeats
the SBDEV-3747 reason almost verbatim ("public because Move Unit Load's stock-moving arms ..."). Fix: "...from three sites, and all
of them call this builder so the messages cannot drift: the two the SBDEV-2074 refactor split (...), and SBDEV-3747's
stock-moving arms ...". Merge the duplicated SBDEV-3747 sentence into the visibility paragraph.

**[LOW] R3: the nested-class javadoc still says "Fixture: reservedamount = 0 on purpose"**
Confidence: HIGH
File: `MobileMoveUnitloadServiceUnitTest.java` (javadoc of `Sbdev3747ReplenHeldStockMove`)
It is still true as the **default**, but one test now overrides it to 4 specifically to exercise `checkReservedStock`. Add
"(one case overrides it to 4 to run the real-world shape through checkReservedStock)".
Optional, in the same test: `verify(replenishorderService, times(2)).existsForStockUnit(stock)`. That proves `checkReservedStock`
actually consulted the replen rather than the fixture bypassing it, though the exact-message assert already makes a wrong-path pass unlikely.

### Re-review verdict
**APPROVE (pending the suite's green and a run count of 6 for the nested class).** Every first-round finding is addressed or
consciously deferred, and the delta introduces no correctness defect. R1–R3 are comment and javadoc accuracy only. Fixing them in the same
pass is cheap, per the address-every-Low rule.
