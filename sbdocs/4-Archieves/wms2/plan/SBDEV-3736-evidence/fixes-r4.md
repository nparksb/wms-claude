---
title: SBDEV-3736 — review r4 fixes (code R4-L1..R4-L3, I-4)
ticket: SBDEV-3736
lane: executor
date: 2026-10-15
worktree: .claude/worktrees/wms2-api/SBDEV-3736 (branch feature/SBDEV-3736-returns-audit-linkage)
base_head: 1785684e
head: 3a475849 (not pushed)
---

# SBDEV-3736 — review r4 fixes

## Commits (on top of 1785684e)

| SHA | Finding | Subject |
|---|---|---|
| 3e0f961d | R4-L1 | fix(receiving): reconcile the RETURN finisher's post-lock receipt re-read with the database |
| 784733de | I-4 | feat(receiving): log the locked sibling position when the RETURN finisher loses a race |
| 0cd102d9 | R4-L2 | test(receiving): pin TRANSFER corrections' RECEIVING code until SBDEV-3775 changes it |
| 3a475849 | R4-L3 | test(returns): rewrap the overlong version-pin comment line |

**Mutation method:** as in r2/r3. Copy the source to the scratchpad, edit it with an asserted anchor count, run the named
class (JDK 21.0.11-ms), then restore by copy. `(git diff; git status --short) | sha1sum` was identical before and after
every mutant. No git checkout, restore or stash was used. Logs are in `scratchpad/r4mut-*.log`.

## R4-L1 — post-lock re-read now reaches the database · 3e0f961d

**Approach:** no new repository method, so escalation trigger 2 did not fire. The post-lock re-read now runs through
the existing `LockReads.reconcileLocked(entityManager, Goodsreceiptposition.class, findByAdvicepositionIdIn(ids))`.
This helper is already used by `CustomerorderPositionService`, `StockunitBusinessService` and
`PickingorderBusinessService`. It works in three steps:
1. `flush()` first, so the caller's own pending GRP write cannot be lost. This addresses the brief's dirty-state concern.
2. One scalar `select e.id, version(e)` query.
3. A `refresh` in place of each receipt whose `@Version` moved.

Supporting details:
- `Goodsreceiptposition` is `@Version`ed through `AbstractBaseEntity`.
- The first read is unchanged. `receivedTotals` now takes the receipt list and is `static`.
- In the unit tests the EntityManager is null, so `reconcileLocked` returns the list unchanged and the mock-level
  tests are unaffected.

**Limits, stated in the javadoc:**
- A write that does not bump the version (raw SQL) is still invisible.
- A receipt deleted between the scalar query and its refresh would make the refresh throw. That is a narrow race and it
  fails closed: the correction rolls back and the operator retries.
- An adjust or delete of a sibling's receipt that commits AFTER the re-read is still not seen. This is the residual
  window, still open.

**Test:** `GoodsReceiptPositionReturnFinishIT.finisher_shouldLeaveReturnAdviceOpen_whenASiblingReceiptAmountChangedAfterTheFirstRead` (PG).
- Setup: in a `TransactionTemplate` on `tenantTransactionManager`, load both receipts so that B's receipt is managed
  at 5. Then UPDATE B's receipt to 7 with `version + 1` through `JdbcTemplate`, which uses its own
  `DriverManagerDataSource` and therefore its own committed connection. Then call the finisher.
- Assertion: the advice and both positions stay OPEN.
- Red before the fix: `expected "OPEN"`, actual FINISHED. It failed for the right reason.

| Mutant | Edit | Killed by |
|---|---|---|
| L1r | drop `reconcileLocked` and use the raw query result | the new IT only (7 run, 1 F) |

The existing ITs still pass. Adjust 50→5 FINISHED, delete → FINISHED and adjust→0 → FINISHED all still finish, so the
caller's own write survives the flush and refresh.

### fixes-r3.md "Not done #1" corrected
At 1785684e, locking the position in adjust/delete would NOT have been enough on its own: the cached re-read would
still see the old amount. With 3e0f961d in place, that lock (taken before their OPEN check and write) WOULD now be
enough to close the remaining window. It has not been done: it is a lock-order change against their stock-unit lock.
fixes-r3.md has been amended in place.

## I-4 — sibling id in the conflict log · 784733de
Before throwing, the finisher now logs
`LOG.info("RETURN finisher conflict: adviceId={} lockedPositionId={} lockedState={}", …)`. The state is shown as
`MISSING` when the row is gone. This covers every caller: dock receive, auto-receive and adjust/delete.

The existing test `receiveGoods_shouldThrowOptimisticLockFailure_whenALockedPositionWasFinishedConcurrently` gains a
logback `ListAppender` assertion that the message contains `adviceId=30 lockedPositionId=11 lockedState=FINISHED`.
Nothing in that test was removed.

| Mutant | Edit | Killed by |
|---|---|---|
| I4a | log `toFinish.get(0).getId()` (the caller's position 10) | that test, I-4 assertion |
| I4b | remove the log line | that test, I-4 assertion |

## R4-L2 — TRANSFER pinned · 0cd102d9
Both `StockChangeCode` `@CsvSource`s gain `"TRANSFER, RECEIVING"`, with a comment saying that SBDEV-3775 owns changing
it. The test count goes from 23 to 25.

| Mutant | Edit | Killed by |
|---|---|---|
| L2T | `receivingCode`: TRANSFER → RETURN | adjust[3] and delete[3] only |

## R4-L3 · 3a475849
The comment was rewrapped to about 120 columns. Comment only.

## Suite
- `mvn -o -B -ntp clean compile`: BUILD SUCCESS.
- Touched classes: `clean verify -Dtest=ReceivingServiceUnitTest,GoodsReceiptPositionServiceUnitTest,BatchEndpointPerIdLookupUnitTest,TestClassTransactionManagerArchTest -Dit.test=GoodsReceiptPositionReturnFinishIT,ReturnAdviceAutoReceiveIntegrationTest,GoodsReceiptPositionAdjustIT` gave **152 unit / 23 IT, 0 F, 0 E**. Before r4 it was 150 / 22.
- Full: `mvn -o -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` gave **BUILD SUCCESS**. It wrote
  3708 surefire and 447 failsafe report files. It started only after the SBDEV-3775 worktree's Maven process had exited.

| Lane | Before (1785684e) | After (3a475849) | Delta |
|---|---|---|---|
| Surefire (unit) | 8315 run, 0 F, 0 E, 1 skip | **8317** run, 0 F, 0 E, 1 skip | +2 (TRANSFER rows) |
| Failsafe (IT) | 878 run, 0 F, 0 E, 23 skip | **879** run, 0 F, 0 E, 23 skip | +1 (R4-L1 IT) |

`git status` was clean after the commits. Nothing was pushed.

## Not done / for Nam
1. **Residual window:** an adjust or delete of a sibling's receipt that commits after the re-read is still not seen.
   Closing it means locking the position in adjust/delete. See the corrected fixes-r3.md #1.
2. **Shared-location deadlock and the missing two-transaction race harness:** unchanged from r3 (#2 and #3). The new
   IT simulates the concurrent write with a committed side-connection update, not with a real contending transaction.
3. **TRANSFER code:** TRANSFER corrections still send RECEIVING. That is now pinned, and SBDEV-3775 owns the change.

## Corrections from round-5 review (2026-10-15)
- **R5-L1:** `ReceivingService`'s `reconcileLocked` call site now states that it is NOT lock-covered. That puts it outside `reconcileLocked`'s documented precondition, so the read is a best-effort snapshot.
- **R5-L2 (corrects "Not done #1" above and fixes-r3.md #1):** taking a position lock in adjust/delete would close the residual window, but it adds a second cost besides the lock-order change against the stock-unit lock. Two corrections on *different* positions of the same advice could deadlock against the finisher's ascending sibling locks. That fails safe, with one rolled back and the operator retrying, but it is a new deadlock edge, not a free fix.
- **R5-L3 (corrects R4-L1 "Limits" bullet 2):** a concurrently deleted sibling receipt has two sub-windows.
  - **Deleted after the entity re-read, before the version query:** silently counted at its stale amount, so the advice can FINISH. This fails open, and it is the same residual window as #1.
  - **Deleted after the version query:** `refresh` throws `ObjectRetrievalFailureException` (not OOLFE) and the transaction rolls back.
    - Batch adjust/delete reports "Retry id N".
    - Auto-receive reports PARTIAL.
    - The **dock** shows the generic "unexpected internal error. Please contact support" and logs at ERROR.
  - Requires a version-moving write *and* a delete of the same receipt within a microsecond window.
  - Rethrowing it as OOLFE was optional per the reviewer and was not done.
