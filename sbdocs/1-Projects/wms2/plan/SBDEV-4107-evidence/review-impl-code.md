# SBDEV-4107 — Phase 3b code review (code-reviewer) — head: d77daa01

Lane: rev-4107 (code-reviewer, opus), 2026-11-11. Read-only review: no mvn, no checkout, no stash. It also ran two read-only queries on wsl-wineco-prd. Saved by the parent session.

**Verdict: COMMENT.** 0 High, 1 Medium, 8 Low, 1 open question. No design disputes.

## [MEDIUM] Deviation 5 is a real defect: a lost finish still happens when adjust/delete races a receive or another adjust (confidence HIGH)
- **Where:** `ReceivingService` finisher. `findByAdviceId`, `findByAdvicepositionIdIn` and the `everyPositionExact … return;` check all run BEFORE `LockReads.forUpdate(entityManager, Advice.class, …)`.
- **Trace.** RETURN advice; P1 is notified 5 with 4 received, P2 is notified 5 with 6 received.
  1. Receive R adds 1 to P1, holding the advice lock.
  2. Adjust A sets P2's line from 6 to 5, holding only its SU lock.
  3. R's finisher sees P2 = 6, because A has not committed, and returns.
  4. A's finisher reads without a lock, sees P1 = 4 because R has not committed, and returns BEFORE taking the advice lock.
  5. Both commit, and the advice stays OPEN with every position exact.

  Two concurrent adjusts on different positions end the same way. The javadoc line "Lost finish: closed (SBDEV-4107)" overclaims: only receive-vs-receive is closed.
- **Fix:** move the advice `LockReads.forUpdate` to just after the RETURN check, before `findByAdviceId`.
  - From a receive this changes nothing.
  - From adjust/delete it waits for R to commit, and the reads that follow are fresh statements.
  - Lock order stays SU → advice → positions. A receive never locks an existing SU, and adjust/delete lock no location, so there is no cycle.
  - Scope the javadoc bullet accordingly.
  - Add one HeldRowLockRace IT: the holder makes an adjust-shaped GRP update and takes the advice lock; the subject completes the sibling; the test asserts FINISHED.
  - The "Stale finish that remains" bullet is unaffected and still true.
- **Parent adjudication (2026-11-11):** this overrides the conformance lane's verdict that deviation 5 is "harmless". Conformance argued that moving the lock would not close the race. The wait is what closes it: whichever of R and A takes the advice lock second reads the other's committed write after the lock is granted.

## LOW
- **L1 "no-op" wording.** The comment says the finisher lock is "a no-op from receiveGoods". The advice is already managed, so LockReads runs a scalar PESSIMISTIC_WRITE select plus a refresh: two statements, no wait. Say "no wait (lock re-granted); refreshes the managed advice". The javadoc says the same thing and needs the same fix.
- **L2 `nextSuffix` overflow.** `Integer.parseInt("2147483647")`, then +1, wraps to MIN_VALUE, and `nextGrpSuffix++` can wrap the same way. Parse to long and skip anything ≥ Integer.MAX_VALUE as out of range; add a unit case. Theoretical on PRD: the longest suffix is 6 digits across 323,298 GRP and 54,279 AP rows.
- **L3 separator ignored.** Trailing digits are taken even with no `-`, so `GR000123` counts as 123. The PRD census found 0 non-`-NNNNNN` numbers. Fix: parse only after `lastIndexOf(SEPARATOR)` and skip numbers with no separator, or document the looser rule.
- **L4 vacuous WARN assertion.** `ConcurrentTakeWarnCapture` never pins the logger level. If the effective level is above WARN, the re-check path's `indexWarned … isFalse()` passes with nothing captured. Fix: set WARN in the constructor and restore it in `close()`, or assert `isWarnEnabled()`.
- **L5 refusal tests only forbid the new write method.** The refusal unit cases changed `never().save(any())` to `never().saveAndFlush(any())`, so a mutant that writes through `save()` before throwing passes. Keep both `never()` checks.
- **L6 InOrder is non-strict.** An extra `getAvailableTransferLanes` call before the lock goes unnoticed. Add an unordered `verify(locationRepository, times(1)).getAvailableTransferLanes(any(), anyInt())`. The SBDEV-3183 property itself still holds, because swapping the locked query for the unlocked one fails at the ForUpdate verify.
- **L7 cleanup filters disagree.** `Sbdev4107ReceivingItSupport` deletes goodsreceipt with a wider advice filter than it uses for adviceposition and advice. Use one advice-id subquery for all three.
- **L8 constraint-name walk exists in 3 places.** `UniqueViolations` duplicates `ReplenishGeneratorService` and `ReplenishorderService`. Route those through `UniqueViolations`, or dispatch it to the ticket.
- **L9 import order.** In `ReceivingController`, `PessimisticLockingFailureException` sits between `.http` and `.orm`.

## OPEN QUESTION (HIGH if true; confidence LOW): rewinds back into the index predicate
Any path that rewinds a lane-holder below 700 / 530 would raise a raw 23505 → 500 through `save`.
**Parent answer:** not live. Plan §0 T7 checked customerorder with two instruments: the bulk `updateStateByIds` (club orders only, and 0 CLUB orders hold a lane on PRD) and every sub-700 `setState` constant, all guarded. For batches, every path to ≥530 clears the lane (A§0.2 S2). The 527 rewinds (`failJob`, `rollbackClubLineState`) land on states already below 530, so the row was already inside the predicate and gains no new index entry. IT 5 pins fail-closed (§10.11).

## Answers to the brief
- **Session after a failed flush:** safe. Only detached fields are read before the throw, there is no query or write, `rollbackFor` includes BusinessException, and the callers are non-transactional controllers.
- **Stale @Version:** `saveAndFlush` raises OOLFE at the flush (inside the method) rather than at commit; the result is the same 409. The lane loser's own row is never touched by the winner, so it gets the re-check or index refusal, not OOLFE.
- **Lock order:** no inversion found. `markFinished` is advice → bulk positions; `order_updates=true` writes Advice before Adviceposition; auto-receive runs one transaction per line and reports a 55P03 as a partial failure; labels print after commit.
- **V2.2.51:** matches plan §4 byte for byte, and the predicates match WmsConstants. No existing goodsreceipt(advice_id) index on PRD. The non-unique lane indexes stay.
- **Tests:** TenantContext is set in the subject threads. Every `allowUnblockedSubject` test asserts `subjectBlocked()`. Default mode is unchanged. The `never()` matchers fit their parameter types. Cleanup deletes children first.
- **v2 rules:** OK.

**Positives:** the scalar `findAdviceIdById` lets the position lock be its row's first touch; the catch is narrow; the refusal message is a shared constant; the WARN capture makes A1 vs A2 attributable.

---

# Scoped re-review (rev2-4107) — d77daa01..ab3f1082 — head: ab3f1082 — REQUEST CHANGES

**Verdict:** all prior findings are FIXED (M1, L1–L7, L9, countByGoodsreceiptId, and the mutation follow-ups a–d). The M1 lock move itself introduces a new Medium.

## [MEDIUM, confidence HIGH] The lock move makes the "Two finishers" rollback unreachable
**Trace.** P is notified 5, with receipts X = 2 and Y = 5.
1. C2 trims Y from 5 to 3.
2. C1 deletes X, takes the advice lock, reads Y = 5 (C2 is uncommitted), sees exact, FINISHES and commits.
3. C2 takes the advice lock and reads committed state: the positions are FINISHED and its own Y = 3, so `everyPositionExact` is false.
4. C2 returns before the position-lock loop and commits its correction against a FINISHED advice (3 of 5 received).

**Before the move**, C2 read before C1 committed, saw "complete", waited on the position lock, found FINISHED, threw OOLFE and rolled back. The bad outcome was timing-dependent; it is now deterministic. The javadoc still claims the position check prevents it.

**Fix:**
- Use the advice that LockReads returns, and fail closed when it is FINISHED (throw OOLFE).
- Receives are safe: `receiveGoods` checks that the advice is OPEN under its own lock.
- This also closes the "Stale finish that remains" window, so rewrite both javadoc bullets.
- Add an IT (holder: lock the advice, delete X, mark FINISHED, all uncommitted; subject: adjust Y; expect OOLFE, Y unchanged, advice FINISHED) and a unit case (findByIdForUpdate → FINISHED: throw, no save). Mutation-check both.

**Parent adjudication:** correct. Traced independently: it is a regression introduced by the M1 fix, not a design dispute. Fix it before push.

## LOW
- **`nextGrpSuffix++` can wrap.** `nextSuffix` may return `Integer.MAX_VALUE`. Use `Math.addExact`, or a skip margin. Cannot happen on PRD today.
- **`nirwanaUnitloadId()`** has no ORDER BY and takes `get(0)`. Assert exactly one row, or add ORDER BY.
- **`labelid <> 'Nirwana'`** drops rows whose labelid is NULL. Use `IS DISTINCT FROM`.

## Checked and clean
- ReturnAdviceCorrectionFinishRaceIT is deterministic and non-vacuous.
- `nextSuffix` matches the old count when nothing was deleted.
- The unit InOrder check kills M7.
- The `never()` matchers are ArchTest-safe.
- The changed javadocs are accurate apart from the two finisher bullets above.

---

# Scoped re-review round 3 (rev2-4107): ab3f1082..b406a6c5 · head b406a6c5 · APPROVE (0 High, 0 Medium, 3 Low)

## Medium fix: verified
- **Check placement:** the null/FINISHED check comes straight after `LockReads.forUpdate`, before any read, and uses the locked instance.
- **Receive path cannot trip it:** the advice is locked first, the OPEN check runs before any write, and the advice is never set FINISHED before the finisher.
- **Callers:** exactly 3 (receive; GRP adjust and delete).
- **Javadoc "Stale finish: closed" holds:** every GRP writer in src/main runs the finisher, and Goodsreceiptposition is in `SDR_WRITE_WITHDRAWN`, so "raw SQL only" is an accurate residual.
- **ReturnAdviceStaleCorrectionRaceIT:** deterministic (the only place the subject can block is the advice lock) and non-vacuous.
- **Low 1** is correct at the boundary. **Lows 2 and 3** are fixed. The sed slip is confirmed clean.

## LOW
- **Overflow refusal placement.** It fires after the case's `createUnitload` / `createStockUnit` writes. Rollback makes it harmless, but compute the suffix at the top of the loop body.
- **`nextSuffix` skips a suffix equal to `Integer.MAX_VALUE`.** So {…646, …647} returns 2147483647 again, a reissue. Skip only values `> MAX_VALUE` and let `MAX_VALUE` produce the overflow refusal. Theoretical on PRD (6-digit suffixes).
- **Javadoc "it never reads" is loose.** The correction did read in checkAndGet; write "it never runs the completeness reads".

---

# Scoped re-review round 4 (rev2-4107) — b406a6c5..a6d59da2 — head a6d59da2 — APPROVE (0 High, 0 Medium, 2 Low)

**Fixed and verified**
- `nextSuffix` returns a long and skips only values `> MAX_VALUE`, so a live MAX_VALUE suffix gives MAX_VALUE + 1. Suffixes above MAX_VALUE cannot be produced by the int formatter, so ignoring them reissues nothing.
- In `receiveGoods`, the suffix is computed before any write.
- All 6 callers of `generateNumberWithAdvice` handle the new checked exception, and normal input is unchanged.
- **FileImportController**
  - The relabel is accurate: the advice is already saved when the draw runs.
  - Normal input is unchanged.
  - A failed draw still produces one error per row; only the label text changes.
  - The BusinessException arm is covered by `positionNumberExhausted`.
- The BasicService diff matches the stated intent; nothing else regressed after the implementer's checkout slip.
- The `never()` matchers are bare `any()`; the inventory is unaffected.
- The L3 javadoc wording is fixed.

**LOW**
- The RuntimeException relabel ("inbound-bol (advice saved, position failed)") has no test. Add one where `generateNumberWithAdvice` throws IllegalStateException, or accept the gap.
- Informational: the new arm is practically unreachable, because each row saves a brand-new advice whose suffix is 0. Harmless defence. **Disposition:** accepted, no change.

---

# Scoped re-review round 5 (rev2-4107): a6d59da2..70e695fa (test-only) · head 70e695fa · APPROVE

- **Scope:** 1 file, FileImportControllerUnitTest (+37). No production file changed.
- **Non-vacuous:** the ListAppender is attached to the same logger as `LOG`, and the test asserts the exact new label with `containsExactly`. The pre-a6d59da2 label would fail it.
- **Logger state:** the appender is detached in `finally`. No level pin is needed, because ERROR is always enabled.
- **Rejection asserted:** accepted = 0, rejected = 1 (REF002, REASON). The raw LEAK text does not reach the response. `never().save(any())` uses a bare matcher, so it is ArchTest-safe.
- **[LOW, info]** `captured.stop()` is never called. Harmless, because the appender is detached. **Disposition:** accepted, no change. It is informational; fixing it would cost another commit and another review lap for no behaviour change.

**Reviewed SHA = tip = 70e695fa.** `git log 70e695fa..HEAD` is empty.

---

# Scoped re-review round 6 (rev2-4107): 70e695fa..c7808d28 (FIX5 commits + develop merge) · head c7808d28 · APPROVE (0 High, 0 Medium, 4 Low)

- **Guard:** coherent. It refuses before any lock, read or write, and `setStaginglaneId` is the only lane writer in src/main. The tests are non-vacuous, and the 5→6 matcher inventory bump is justified.
- **V2.2.51:** the predicate matches the DO guard. Both mdlw/west and east migrate cleanly. IT 8c is non-vacuous, and its CLUB control really fails.
- **Fixture:** correct for both variants, and a reload converges.
- **Merge:** clean. The exemption list is the exact union of both sides. Neither SBDEV-4108's CUPS/Keycloak rail nor SBDEV-4114's IdempotencyFilter interacts with SBDEV-4107: `receiveGoods`' in-transaction `isPrintAvailable` runs before the advice lock.

**LOW**
1. A non-CLUB batch at state ≥527 gets the state-guard message, not "not a club batch". Swap the two guards. **Disposition:** fix.
2. Editing V2.2.51 changes its checksum. It is not applied anywhere yet, so this is informational. **Disposition:** accepted.
3. The fixture reload reasserts 920702 → lane 23. If a demo user had given lane 23 to another open CLUB batch, the reload would fail with 23505. It needs manual demo misuse. **Disposition:** accepted, and noted on the ticket for the demo-reset runbook.
4. Two exemption comments are incomplete: `Sbdev4107ReceivingItSupport` omits two subclasses, and the `OpenLaneUniqueIndexMigrationIT` comment omits 8c. **Disposition:** fix.

---

# Scoped re-review round 7 (rev2-4107): c7808d28..b22387f3 · head b22387f3 · APPROVE (0 findings)

- **Guard order:** the CLUB check comes first, then the SBDEV-4038 state guard. Both read only fields, and both run before any lock, read or write.
- **New 527 test:** non-vacuous. With the old order it fails both message assertions.
- **Other ordering:** the existing state-guard cases still run under the CLUB setUp, so they still reach the state guard.
- **Exemption comments:** accurate. They name all 7 subclasses and IT 8/8b/8c.

**Reviewed SHA = tip = b22387f3.**
