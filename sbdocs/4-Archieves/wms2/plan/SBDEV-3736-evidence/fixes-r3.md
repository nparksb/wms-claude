---
title: SBDEV-3736 — review r3 fixes (code R3-L1..R3-L6, I-1..I-3)
ticket: SBDEV-3736
lane: executor
date: 2026-10-15
worktree: .claude/worktrees/wms2-api/SBDEV-3736 (branch feature/SBDEV-3736-returns-audit-linkage)
base_head: cd240b06
head: 1785684e (not pushed)
---

# SBDEV-3736 — review r3 fixes

## Commits (on top of cd240b06)

| SHA | Findings | Subject |
|---|---|---|
| 16817014 | R3-L1, I-1 | fix(receiving): lock the RETURN finisher's open positions and re-read before finishing |
| f83e545a | R3-L6 | refactor(receiving): reuse the advice rows checkAndGetGoodsReceiptPosition resolved |
| 2061df12 | R3-L2 | fix(receiving): report a RETURN receipt's adjust/delete to OMS as RETURN, not RECEIVING |
| 03c0c9ae | R3-L3, R3-L4 | docs(receiving): document the finisher's adjust/delete rollback and no-reopen outcomes |
| 74765d44 | R3-L5 | test(returns): explain why the auto-receive version pin counts transactions, not flushes |
| 1785684e | I-2 | test(receiving): purge the STOCK_UPDATE message rows GoodsReceiptPositionReturnFinishIT leaves |

**Mutation method:** hand mutants through `scratchpad/r3mut.py` + `r3mutants.py` (same harness as r2): copy the
source to the scratchpad, edit with an asserted anchor count, run the named class under JDK 21.0.11-ms
(`mvn -o test -Dtest=` or `verify -Dit.test= -Dtest=ZzzNone`), restore by copy. `(git diff; git status --short) | sha1sum`
identical before and after every batch. Logs: `scratchpad/r3mut-<id>.log`. No git checkout/restore/stash used.

## R3-L1 — fix (a): lock, re-read, then finish · 16817014

**Change (`ReceivingService.finishReturnAdviceIfComplete`):**
- After the first read says "complete", each not-yet-FINISHED position is locked in ascending id order through
  `LockReads.forUpdate(entityManager, Adviceposition.class, id, advicepositionRepository::findByIdForUpdate)`.
  Existing repository method; no new one. `LockReads` because `findByAdviceId` already read the rows plain, so a bare
  locking finder would be the version-checked upgrade (memory *findbyidforupdate-throws-at-the-lock-read*).
- Then `findByAdvicepositionIdIn` is re-run and the advice finishes only if every position is still exact.
- **Addition beyond the brief, needed to avoid a regression:** a locked position that comes back FINISHED, or
  missing (`FOR UPDATE` on a missing row locks nothing — memory *for-update-on-a-missing-row*), throws
  `ObjectOptimisticLockingFailureException(Adviceposition, id)`. Without it, two adjust/delete finishers that both see
  "complete" would serialise on the lock; the second would re-read "not exact", return, and **commit its correction
  against a FINISHED advice** (before the lock its stale advice save rolled it back). Precedent for throwing it:
  `ParcelMonitorViewService:277`.
- `EntityManager` field-injected (`@PersistenceContext(unitName = "tenant")`), as `UnitloadBusinessService` /
  `GoodsReceiptPositionService` do; null in the unit tests, so `LockReads` falls back to the finder.
- Javadoc rewritten: what the lock closes (receive over-key on a sibling, for any finishing caller — adjust/delete,
  carrier, distinct location); what remains (adjust/delete of a SIBLING's receipt take no position lock, and the re-read
  returns already-managed receipt entities at first-read state, so an adjust committed in the window is not seen);
  lost finish; deadlock on a shared put-away location (40P01, one aborts, operator retries — pre-existing edge, the
  lock adds none); carrier path takes no carrier lock; two finishers. "Write order" paragraph updated: `sorted(...)` now
  IS the lock order.
- fixes-r2.md corrected: R2-L1 section marked superseded, "Not done #1" rewritten (stale finish needs only fix (a);
  the before-location lock is what removing the deadlock needs).

**Tests (`ReceivingServiceUnitTest$ReceiveGoods`, +4; fixture adds a lenient `findByIdForUpdate(11L)` stub):**
- `…shouldLeaveReturnAdviceOpen_whenThePostLockReReadIsNoLongerExact` — first read 5/5,5/5; re-read 5/5,6/5 → OPEN, no saves.
- `…shouldLockOpenPositionsInAscendingIdOrderBeforeTheReRead…` — InOrder: findByAdviceId → read → lock 10 → lock 11 → re-read → saves; lookup returned descending.
- `…shouldThrowOptimisticLockFailure_whenALockedPositionWasFinishedConcurrently`
- `…shouldThrowOptimisticLockFailure_whenALockedPositionNoLongerExists`

| Mutant | Edit | Killed by |
|---|---|---|
| L1a | gate on the pre-lock totals | re-read-gate test (+ lock-order test's InOrder) |
| L1g | drop the re-read gate | same two |
| L1b | remove the lock call | lock-order, finished-concurrently, no-longer-exists |
| L1c | lock in descending order | lock-order test only |
| L1d | drop the FINISHED check | finished-concurrently only |
| L1e | drop the null check | no-longer-exists only |
| L1f | lock every position, not just OPEN ones | lock-order + existing `…shouldNotResaveFinishedPosition…` |

PG ITs with the real lock (`GoodsReceiptPositionReturnFinishIT` 6, `ReturnAdviceAutoReceiveIntegrationTest` 12):
green, lock-read rail silent. **No two-transaction race IT was built**; the race itself is pinned only at mock level.

## I-1 — REQUIRED propagation pin · 16817014
`finishReturnAdviceIfComplete_shouldJoinTheCallersTenantTransaction`: `findMergedAnnotation` → value
`tenantTransactionManager`, propagation REQUIRED, not readOnly. Mutant I1 (REQUIRES_NEW) killed by it alone.

## R3-L6 — no duplicate lookups · f83e545a
`checkAndGetGoodsReceiptPosition` returns `CheckedReceipt(advicePosition, advice)`; `adviceOf` removed; adjust's
message path and `deletePosition` use the record instead of a second `findById`. No behaviour change (all were L1 hits).
Committed before R3-L2 with the REGULAR literals intact; `GoodsReceiptPositionServiceUnitTest` 19/0 at that state.
No mutant: a pure refactor, covered by the existing finisher-argument tests (`finishReturnAdviceIfComplete(testAdvice)`).

## R3-L2 — RETURN correction code · 2061df12
- `receivingCode(advice)`: RETURN → `CODE_RECEIVING_RETURN`, else `CODE_RECEIVING_REGULAR`; used for both the comment
  prefix and the activity code in adjust and delete. Flag gating and TRANSFER untouched, as directed.
- Sweep: `CODE_RECEIVING_REGULAR + ": "` remains nowhere in `GoodsReceiptPositionService`; repo-wide only
  `ReceivingService.receiveGoods`' REGULAR case (correct).
- OMS consumer (oms-laravel-api origin/develop): `LegacyInventoryAdjustService::ACTIVITY_CODE_TO_LUT_KEY` maps
  `RETURN → RETURN`, `RECEIVING → RECEIVING`, so the correction now lands in the same product_update_type as the receive.
- Tests `GoodsReceiptPositionServiceUnitTest$StockChangeCode` (2 parameterized × 2 = 4): adjust and delete,
  RETURN → "RETURN", REGULAR → "RECEIVING", wire literals.

| Mutant | Edit | Killed by |
|---|---|---|
| L2a | helper always REGULAR | adjust+delete RETURN cases |
| L2f | helper always RETURN | adjust+delete REGULAR cases |
| L2b / L2d | adjust reverted (both / prefix only) | adjust RETURN only |
| L2c / L2e | delete reverted (both / activity code only) | delete RETURN only |

## R3-L4 — optimistic-lock failure → retry text · 03c0c9ae
The cheap existing pattern already covers it: `AdminController.addBatchServiceFailure` maps every non-not-found
`RuntimeException` to "This row could not be completed. Retry id N." and the loop continues. No new mapping; the
finisher javadoc documents it (and 40P01 → `CannotAcquireLockException`, same arm). New pins in
`BatchEndpointPerIdLookupUnitTest$GoodsReceiptPositionBatch`: `adjust_/delete_shouldReportRetry_whenTheFinisherLosesAnOptimisticLockRace`.

| Mutant | Edit | Killed by |
|---|---|---|
| L4a | route OOLFE to the support-reference arm | both new tests only |
| L4b / L4c | adjust / delete catch OOLFE and leak `getMessage()` | the matching new test only |

## R3-L3 — no reopen · 03c0c9ae
Javadoc only (finisher). **Release-note line:** "A RETURN advice that becomes exactly received through a receipt
adjust/delete is now finished automatically and can no longer be corrected; in a multi-row correction, rows after the
one that completes the advice are refused with 'Advice in state=FINISHED expected=OPEN'."

## R3-L5 — version pin · 74765d44
The premise does not hold for this test, so the pin stays `containsExactly(2, 1)` (not loosened). `executeInternal`
receives every line first, each `receiveGoods` its own transaction, S8 firing in line B's; then `applyDamage` →
`self.stampDamageApplied` writes A in its own transaction. A's two writes are two commits, not two saves in one flush.
Comment rewritten to say so. Re-measured: R6 (S8 removed) still killed by this assertion alone; mutant L5s (stamp
without save) reds it too (and the worklist test).

## I-2 — message residue · 1785684e
`deleteResidue()` also deletes `message` rows with `process = 'STOCK_UPDATE'` and the class's SKU in the payload
(SkuRenameInPlaceIT pattern). Measured with a temporary probe (removed): each test leaves 1 row; the @AfterEach deletes 1.

## I-3 — rollbackFor
Left. Repo convention (v2 CLAUDE.md "Dual Transaction Manager") writes tenant service methods as
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`;
the reviewer calls it inert but harmless. Removing it would diverge from the house form for no gain.

## Suite

- `mvn -o -B -ntp clean compile` → BUILD SUCCESS.
- Touched classes: `verify -Dtest=ReceivingServiceUnitTest,GoodsReceiptPositionServiceUnitTest,BatchEndpointPerIdLookupUnitTest,TestClassTransactionManagerArchTest -Dit.test=GoodsReceiptPositionReturnFinishIT,ReturnAdviceAutoReceiveIntegrationTest,GoodsReceiptPositionAdjustIT` → 150 unit / 22 IT, 0 F, 0 E.
- Full: `mvn -o -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` (JDK 21.0.11-ms) → **BUILD SUCCESS**; reports written (3708 surefire, 447 failsafe files).

| Lane | Before (cd240b06, r2) | After (1785684e) | Delta |
|---|---|---|---|
| Surefire (unit) | 8304 run, 0 F, 0 E, 1 skip | **8315** run, 0 F, 0 E, 1 skip | +11 (ReceivingServiceUnitTest +5, GoodsReceiptPositionServiceUnitTest +4, BatchEndpointPerIdLookupUnitTest +2) |
| Failsafe (IT) | 878 run, 0 F, 0 E, 23 skip | **878** run, 0 F, 0 E, 23 skip | 0 |

`git status` clean after the commits. Not pushed.

## Not done / for Nam
1. **Stale finish from a sibling adjust/delete remains.** They lock only their stock unit, not the advice position,
   so the finisher's lock does not serialise against them. Closing it means locking the receipt's advice position in
   adjust/delete — a lock-order change (stock unit vs position) worth its own review. Documented in the javadoc.
   **Corrected 2026-10-15 (code review r4 R4-L1):** as of 1785684e that lock alone would NOT have been sufficient. The
   finisher's re-read was an entity query that returns already-managed receipts at their first-read amount, so even
   after waiting for the sibling adjust to commit it would still have seen the old amount and finished. Fixed in r4
   (`3e0f961d`): the re-read goes through `LockReads.reconcileLocked`, so an amount committed before the re-read is
   seen. With that in place, locking the receipt's advice position in adjust/delete (before their OPEN check and
   write) WOULD now be sufficient to close the remaining window; still not done. See fixes-r4.md.
2. **Shared-location deadlock** remains (pre-existing): removing it needs every position locked before the location,
   serialising all receives on one advice. Not done.
3. **No two-transaction race harness**: the lock/re-read behaviour is pinned at mock level plus the PG ITs' uncontended
   path, not under real contention.
4. TRANSFER adjust/delete still send a REGULAR-coded delta for stock never reported (R3-L2 second half), per Nam: separate finding.

## Correction (round-5 review R5-L2, 2026-10-15)
"Not done #1": a position lock in adjust/delete would close the residual window, but it would also add a deadlock edge. Two corrections on different positions of one advice could deadlock against the finisher's ascending sibling locks. See fixes-r4.md, "Corrections from round-5 review".
