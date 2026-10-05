## Code Review: SBDEV-3487 (Phase 3b, independent lane)

**Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487` @ `690a4109`. I read the whole branch diff (`b950c994..HEAD`) and plan §0, §2, §2.1, §5 and §6.1.

**Files reviewed:** 13 (5 main, 8 test).
**Total findings:** 16 (High 0, Medium 2, Low 14) plus 2 open questions.

**What I checked**
- **Unit tests:** I ran the 6 affected classes with `mvn -o test` after `pgrep` showed no Maven running. All green: BillofladingPositionServiceUnitTest, MobileMoveUnitloadServiceUnitTest, MobileMoveUnitloadServiceTest, MobileTruckLoadingServiceTest, MobileTruckLoadingServiceUnitTest and MobileTruckLoadingWriteServiceUnitTest.
- **ITs:** I did not run the PG ITs, so their results rest on the commit messages.
- **Base:** origin/develop has not touched the reviewed paths since `b950c994`.
- **Schema:** `billoflading_position.number` is NOT NULL (`V2.2.00:692`) and `index_billoflading_position_source_id` exists (`:4002`).
- **Rollback:** no `REQUIRES_NEW` or `sendAfterCommit` on the `transferUnitLoadToLocation` path, so rejecting V2 rolls back cleanly.
- **Stubs:** no leftover TDD stubs or placeholders in `src/main`.

### Stage 1: does the code do what §5 designed?
It does.
- **Fix A:** the facade call sits after `requireOutboundPalletLabel` and outside the lock-failure `try`.
- **Finder:** exactly as in §5.2.
- **Fixes B and C:** inside `if (matches)`, before R1, with the right site tags.
- **Fix D:** the predicate is on R3–R6, R3/R5 now return `int`, and the 0-row re-check uses the `_RECHECK` sites.
- **Fix E:** the comments and both workflow docs are updated.
- **§5.7 test edits:** all present, including the single `FIXED_PALLET_LABELS` constant.

### Stage 2: correctness
- **Rollback:** a throw rolls back on both paths. Write-service `scanGate` and `scanDestination` both declare `rollbackFor = BusinessException`, and `scanDestination`'s only caller is the controller.
- **Flushing / first-touch (SBDEV-3244):** the new finder loads no entity.
  - In D0 nothing is dirty before it runs.
  - The NoClear deletes flush and don't clear, so the re-check sees an unchanged persistence context.
  - On the facade the finder runs with no transaction, which is fine for a read.
- **Mixed trees:** these give a 23503 error and a full rollback, as §5.5 intends. I found no logic defect in production code.

---

### Medium

**[M1] The fixture's javadoc now contradicts the two subclasses this branch added**
File: `src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java`, class javadoc (~`:88-112`) and the `@MockitoBean OutboundPalletLabelGuard` javadoc (~`:140-148`). Confidence: HIGH.
> "No assertion in either subclass depends on whether D0 fires." … "The purge-and-rebuild path that production does take has no integration test … Do not read a green run of this lane as covering D0's purge."
> "Consequence: this lane exercises only PHASE D0's no-match exit"

- **What's wrong:** `MobileTruckLoadingClosedBolPurgeIT` and `MobileMoveUnitloadClosedBolPurgeIT` extend this fixture and use BOUT labels that match.
  - `reScanFromAnOpenBolMovesThePallet` and AC-7 are exactly the purge-and-rebuild IT the javadoc says doesn't exist.
  - The javadoc also still says it is "Shared by" only the probe and race ITs.
- **Why it matters:** this branch edited the file, so the contradiction is new. A reader will either distrust the new ITs or write a duplicate. False comments are the recurring defect type here.
- **Fix:**
  - Say that the prefixed labels take the no-match exit, and that the two SBDEV-3487 subclasses use outbound labels and do cover the purge.
  - Update the "Shared by" list.
  - While there: "{@link #PREFIX} carries {@link System#nanoTime()}" is false and predates this branch. `PREFIX` is the fixed `"TL3465-"`; it is `runKey` that carries nanoTime.

**[M2] The new `seedPallet` overload's javadoc prescribes a cleanup order that fails**
File: `AbstractTruckLoadingPgFixture.java`, `seedPallet(String, String)` javadoc (~`:227-231`). Confidence: HIGH.
> "the caller must delete that pallet row itself (override {@code purgeByPrefix} and call super first)."

- **What's wrong:** both overrides call super in the middle, and they have to. Pallets are moved to location 0, then super runs, then the rows are deleted by label.
  - `MobileTruckLoadingClosedBolPurgeIT:357-360` records that calling super first "failed exactly that way" on the location FK.
- **Why it matters:** the next author who follows this javadoc reproduces that measured failure.
- **Fix:** describe the three steps: move each fixed-label pallet to `SEEDED_LOCATION_ID`, call super, then delete `unitload_record` and `unitload` rows by exact label.

### Low

**[L1] `advanceBolToTruckLoadingAtGate` lost its javadoc**
File: `AbstractTruckLoadingPgFixture.java:269-307`. Confidence: HIGH.
- `seedOpenBol` (added in `682483fe`) was inserted between `advanceBolToTruckLoadingAtGate`'s javadoc ("Put the BOL into the steady state… Written with {@code JdbcTemplate}…") and the method.
- The old doc is now a dangling comment above `seedOpenBol`'s doc, and `seedOpenBol` is written through the repository, which is the opposite of what that doc says.
- **Fix:** move `seedOpenBol` and its javadoc above line 269, or below `advanceBolToTruckLoadingAtGate`.

**[L2] No V1 test checks that a 1-row delete skips the re-check**
File: `MobileMoveUnitloadService.java:585`. Confidence: HIGH.
```java
int deleted = billofladingPositionRepository.deleteBolPositionByIdNoClear(bolPositionId);
if (deleted == 0) {
```
- The mutant `if (deleted == 0)` → `if (true)` survives for V1.
  - No test stubs R3 to return 1 and then verifies `never()` on `SCAN_GATE_D0_RECHECK`. Only V2's happy path does that for R5.
  - In the ITs, a passing re-check logs no guard WARN, so they can't see it either.
- **Fix:** add `HandleTruckOffLoadingNoClear#oneRowDeleteDoesNotRecheck`: stub R1, R2 and `deleteBolPositionByIdNoClear(1L)` returning 1, then `verify(bps, never()).assertPalletNotShipped(any(), eq(SCAN_GATE_D0_RECHECK))`.

**[L3] AC-9 pins the `IS NULL` arm on R3 only**
File: `MobileTruckLoadingClosedBolPurgeIT.java:263,276,292-293`. Confidence: HIGH.
- Removing `bp.state IS NULL OR` from R4, R5 or R6 survives, because only R3 has a null-state control.
- **Fix:** add null-state controls for R5 (a childless row) and for R4/R6 (a null-state child under a TRUCK_LOADING parent).

**[L4] The "warns and continues" tests don't check the WARN**
File: `MobileMoveUnitloadServiceUnitTest.java`, both `zeroRowDeleteWithRowGoneWarnsAndContinues`. Confidence: HIGH.
- The names promise a WARN, but only no-throw and the re-check call are verified. Deleting the `LOG.warn("SBDEV-3487: pallet position {} …")` line survives, even though P5 ("fail loud") is the stated reason for the WARN.
- **Fix:** attach a `ListAppender` to `MobileMoveUnitloadService`'s logger and assert exactly one WARN starting with `"SBDEV-3487: pallet position"`, or drop "warns" from the names.

**[L5] Both new IT class javadocs describe pre-fix behaviour in the present tense**
Confidence: HIGH.
- `MobileTruckLoadingClosedBolPurgeIT.java:34-37` says: "D0 … deletes the scanned pallet's positions matched by LABEL alone, with no filter on BOL or BOL state." After Fix D, R3–R6 do filter on state.
- `:40-41` says "every other test in this lane only ever takes D0's no-match exit." The sibling IT also matches.
- `MobileMoveUnitloadClosedBolPurgeIT.java:45-48` says: "So a direct call deletes the CLOSED tree and commits the move out of Shipped."
- **Fix:** mark these as "pre-fix (reproduced at `682483fe`)", and say what the fixed code does.

**[L6] The `purgeByPrefix` overrides skip the base class's lock bound**
Files: `MobileTruckLoadingClosedBolPurgeIT.java:363-374` and `MobileMoveUnitloadClosedBolPurgeIT.java:403-414`. Confidence: MEDIUM.
- The base javadoc calls `SET lock_timeout = '30s'` load-bearing: without it, a purge that meets a row still locked hangs silently.
- The overrides' `update unitload …`, `delete from unitload_record …` and `delete from unitload …` each run on a fresh autocommit connection with no bound and no named-statement error.
- **Fix:** add a `protected` hook to the base (e.g. `deleteFixedLabels(Connection)`, or a pre/post hook) so these statements run inside the bounded `ConnectionCallback` and through `exec`.

**[L7] The inherited `tx()` is a landlord transaction (already known, on the ticket)**
File: `AbstractTruckLoadingPgFixture.java` (`@Autowired private PlatformTransactionManager tenantTransactionManager;`). Confidence: HIGH.
- The fallback by field name loses to the `@Primary` landlord manager, as `MobileMoveUnitloadClosedBolPurgeIT:82-91` correctly records.
- New code still leans on `tx()` as if it were a tenant transaction:
  - AC-9's javadoc says "each call inside `tx()`".
  - `savePosition`, `seedOpenBol` and `closeBolAsShipped` are all wrapped in `tx()`.
- The results are still right, because each repository call commits in its own tenant transaction. But "inside `tx()`" implies a boundary that doesn't exist.
- **Fix:** add `@Qualifier("tenantTransactionManager")` to the fixture field and delete the local `tenantTx()` workaround. If that has to wait for its own ticket, reword the AC-9 javadoc.

**[L8] The `'CLOSED'` literal is repeated in five queries**
File: `BillofladingPositionRepository.java:113,134,142,179,190`. Confidence: HIGH.
- `WmsConstants.BillOfLadingState.CLOSED` is a compile-time `static final String` (`WmsConstants:261`), so it can be concatenated inside an annotation.
- **Fix:** write `" AND (bp.state IS NULL OR bp.state <> '" + WmsConstants.BillOfLadingState.CLOSED + "')"`, or one private constant for the predicate fragment. The literal can then no longer drift from the constant. This does change §5.5's stated choice of a literal.

**[L9] The facade call uses the fully-qualified enum name on a ~170-character line**
File: `MobileTruckLoadingService.java:170`. Confidence: HIGH.
> `billofladingPositionService.assertPalletNotShipped(truckLoadingMobileDTO.getPalletName(), BillofladingPositionService.ShippedGuardSite.SCAN_GATE_FACADE);`
- **Fix:** `import net.aim_ai.wms.service.BillofladingPositionService.ShippedGuardSite;`, as `MobileMoveUnitloadService` already does.

**[L10] The null guard in `assertPalletNotShipped` can't be reached and isn't tested**
File: `BillofladingPositionService.java:42`, `if (palletLabel == null) return;`. Confidence: HIGH.
- The facade's `requireOutboundPalletLabel` throws on a null or empty label first, and both D0 variants would NPE on `unitLoadLabel.matches` before reaching it.
- AC-8 has no null case, so deleting the line survives.
- It also fails open without saying why.
- **Fix:** either add an AC-8(e) null test with a comment explaining why passing a null label is safe, or replace the guard with `Objects.requireNonNull`.

**[L11] The finder's non-null result doubles as the "row exists" signal**
Files: `BillofladingPositionRepository.java:111-114` and `BillofladingPositionService.java:43-44`. Confidence: HIGH.
- `closedBolName != null` stands for "a CLOSED row exists". That holds only because `bp.number` is NOT NULL, a fact that lives in the schema, not the code.
- When `b.name` is null, `coalesce` falls back to the position number, which is then logged as "CLOSED BOL {}". That is cosmetic, per §5.2.
- **Fix:** add one sentence to the finder javadoc: "never returns null for an existing row — `bp.number` is NOT NULL (V2.2.00:692) — so null means no CLOSED row."

**[L12] The write-service comment credits the new check with choosing D0's position**
File: `MobileTruckLoadingWriteService.java:427-428`. Confidence: MEDIUM.
> "it lives here, after B2's pallet lock, because only then can closeBOL not overtake it."
- D0's position was chosen by SBDEV-3418, for the reasons listed just above this comment. The backstop inherits that position; it did not choose it.
- **Fix:** "The backstop lives inside this purge, so it inherits D0's position after B2; that is what makes it race-free against closeBOL."

**[L13] `MOVE_UNITLOAD_D0` names a phase the move path doesn't have**
File: `BillofladingPositionService.java:36`. Confidence: LOW. A naming nit, and the name comes from the plan.
- "D0" is a phase inside the write-service `scanGate`; the move-unitload path has no phases. The name will read oddly in logs.
- **Fix (optional):** `MOVE_UNITLOAD_PURGE` / `MOVE_UNITLOAD_PURGE_RECHECK`. Tests compare enum identity, so the rename is mechanical.

**[L14] On the move path the rejection comes after locks have been taken**
File: `MobileMoveUnitloadService.java:376-379` then `:499`. Confidence: HIGH. Informational; the placement is by design.
- By the time the backstop throws, `transferUnitLoadToLocation` has already locked DEST, the owning pickingorders and the pallet row. That departs from P1 ("no lock before a rejection") on this path.
- The early rejection belongs to SBDEV-3490. It would help to name the P1 trade-off in the Fix C comment, so no one "optimises" by moving the backstop out of V2.

---

### Open questions (low confidence, not blocking)

**[OQ1, Medium] An AC-6b pallet may have no way back, and the remedy messages now loop**
Files: `BillofladingPositionService.java:55-57` and `MobileMoveUnitloadService.java:499`. Confidence: LOW. This is about the remedy, not a re-argument of decision 1.
- A pallet off Shipped with CLOSED positions (the AC-6b state) can no longer be moved to a location from the handheld.
- `assertPalletNotAssignedToGate`'s message tells the operator to "Remove it from the truck and return it to Palletizing first!", and that move is now rejected with "Pallet X already part of BOL Y".
- **Suggestion:** confirm with the owner that this dead end is acceptable, and give the SBDEV-3487 rejection (or the destination guard, for CLOSED rows) a message that names the real remedy or escalation path.

**[OQ2, Medium] A scanGate/finishTransfer interleaving on a TRANSFER pallet (predates this branch)**
Confidence: LOW. Found by reading code, not measured.
- **Sequence:**
  1. scanGate holds the pallet (B2), purges the TRANSFER rows in D0 and commits.
  2. finishTransfer's bulk position UPDATE, which was waiting on those row locks, re-evaluates and matches 0 rows.
  3. finishTransfer then moves the pallet to Shipped with lock 405, although it now sits on BOL Y in TRUCK_LOADING.
- No CLOSED row is deleted, and decision 2 keeps TRANSFER re-scannable, so this is outside this ticket.
- **Suggestion:** record it on the ticket as a proposal. It is not a finding against this change.

---

### What's done well
- **Every layer can be attributed:** each IT checks the guard WARN's site tag by enum identity. The facade → D0 → RECHECK chain means deleting one layer shows up as a changed site, not a silent pass.
- **No vacuous passes:**
  - `reScanFromAnOpenBolMovesThePallet` proves the labels reach the purge.
  - The NOWAIT positive control rules out a 0-row pass on AC-10b.
  - AC-9 has a delete control for every predicate.
- **Assertion order:** data is checked before exceptions everywhere, so a red names the lost shipping record.
- **Fixture diagnosis:** the `tenantTx()` workaround and its javadoc measured the landlord-transaction trap instead of accepting a red that meant nothing.
- **The finder is minimal:** scalar, indexed and with no lock, so it keeps the first-touch rule and adds no deadlock edge.
- **Commit `628524bf`:** a correct test fix. It changes no assertion, the strict-stub reasoning (PotentialStubbingProblem on a differently-argumented call) is accurate, and the new `doNothing()` is both strictly used and verified.
- **The `IS NULL` arm:** its reasoning is stated in the R5 javadoc, and it is pinned at least for R3.

### Recommendation
**APPROVE.** There are no High findings. Both Mediums are false or harmful comments in test code, and none of the findings is a production logic defect. Fix M1 and M2 and the Lows in the same pass, as you planned.