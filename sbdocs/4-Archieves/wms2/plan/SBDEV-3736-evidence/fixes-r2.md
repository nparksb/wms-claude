---
title: SBDEV-3736 — review r2 fixes (code R2-L1..R2-L5; security R2-L1)
ticket: SBDEV-3736
lane: executor
date: 2026-10-15
worktree: .claude/worktrees/wms2-api/SBDEV-3736 (branch feature/SBDEV-3736-returns-audit-linkage)
base_head: a538785e
head: cd240b06 (not pushed)
---

# SBDEV-3736 — review r2 fixes

## Commits (on top of a538785e)

| SHA | Findings | Subject |
|---|---|---|
| 2b6fdee8 | security R2-L1 | docs(report): the returns audit window cap bounds pages, not the unitload_record scan |
| 81c05317 | code R2-L3 | test(report): correct the allow-control comment on @DateTimeFormat |
| 105f83e8 | code R2-L2 | docs(receiving): row-lock order of the RETURN finisher comes from order_updates |
| 0e9e3c5b | code R2-L4, R2-L1 | fix(receiving): finish a RETURN advice when a receipt adjust or delete makes it exact |
| da08ab4f | code R2-L5 | test(returns): pin that S8, not markFinished, finishes the auto-received positions |
| cd240b06 | (R2-L4 support) | test(arch): register GoodsReceiptPositionReturnFinishIT as a NOT_SUPPORTED class |

## Per finding

**Mutation method:**
- Hand mutants, run with `scratchpad/r2mut.py`, which has the same harness as r1.
- For each mutant, the source file is copied to the scratchpad and edited, and the anchor count is asserted. The named class runs under JDK 21 (`mvn -o test` or `verify -Dit.test=`). The file is then restored by copy.
- `(git diff; git status --short) | sha1sum` was `d58021a6…` both before and after the run.
- Logs are at `scratchpad/r2mut-<id>.log`.

### Security R2-L1: window-cap javadoc · 2b6fdee8
- **Change:** the `ReportController.returnsAudit` and `MAX_RETURNS_AUDIT_WINDOW` javadoc now say the cap bounds the advice side of the query (rows and pages per window). It does **not** bound the per-page `unitload_record` seq scan, which is a fixed cost per request that is accepted behind the gate. An index is a separate T3/Flyway proposal and was not done here.
- **Test/mutant:** none, since this is javadoc only.

### Code R2-L3: stale allow-control comment · 81c05317
- **Change:** the comment now says that 405/404 means the mapping broke and 403 means the endpoint is over-gated. It also says `@DateTimeFormat` is not load-bearing, because Spring falls back to ISO parsing (K7/K7b survive).
- **Test/mutant:** none, since this is a comment only.

### Code R2-L2: write order comes from `order_updates` · 105f83e8
- **Change:** the finisher javadoc now cites `hibernate.order_updates=true` as what orders the UPDATEs and row locks at flush. That setting is already pinned in both lanes by `TestLanesMirrorProductionJpaKeysUnitTest`, so no new pin is needed. The `sorted(...)` call only fixes the order of `save()` calls.
- **Test:** the unit test was renamed to `receiveGoods_shouldCallSaveInAscendingIdOrder_whenReturnAdviceCompletes`, with a new DisplayName and a javadoc saying it pins call order only. Its assertions are unchanged, and the sort was kept.

### Code R2-L1: stale-finish race — (b) javadoc qualification, NOT the lock fix · 0e9e3c5b
> **Superseded by r3 (R3-L1).** The rejection reasoning below is wrong: the deadlock it describes already existed in the shipped finisher, fix (a) adds no lock-order edge, and the carrier path takes no carrier lock. Fix (a) was implemented in `16817014`. See "Not done #1" below and fixes-r3.md.

- **Fix (a) was rejected after the lock-order check.** It would have meant locking the sibling positions through `LockReads` and the existing `findByIdForUpdate`, then re-reading the totals. The reviewer's premise that "a non-finisher never waits on a finisher" does not hold:
  - `receiveGoods` locks its own position first (`:383`).
  - It then locks the put-away location or carrier unit load. `UnitloadBusinessService.transferUnitLoadToLocation` does this with `LockReads.forUpdate(Location…)` at `:245`, and `transferUnitLoadToCarrier` locks the carrier.
  - Say T1 is the finisher on A and already holds location L. If it then locks sibling B while T2 (a receive on B) holds B and is heading for the same L or carrier, the two transactions lock in opposite orders. That is a deadlock, and PostgreSQL aborts one receive.
  - Returns to one dock carrier or location are the normal case, so the deadlock would land on exactly the race fix (a) was meant to close.
  - A bare `findByIdForUpdate` would also trip the SBDEV-3286 lock-read rail, because the positions were already read plain by `findByAdviceId`. That is why `LockReads` would have been needed in the first place.
- **No new repository method was needed.** I rejected (a) because of the deadlock, not because of the "new method → stop" rule.
- **Javadoc:** the Concurrency section now separates two cases:
  - *lost finish*: the advice stays OPEN; the audit shows `fullyReceived=true, adviceState=OPEN`.
  - *stale finish (R2-L1)*: an over-key on a sibling, whether by receive, adjust or delete, commits concurrently. The advice is FINISHED and over-received; the audit shows `FINISHED, fullyReceived=false`. The population on PRD is 0.
- The javadoc also records why the lock fix was rejected, and that two adjust/delete finishers *can* both see "complete". The second one then fails the advice `@Version` check and rolls back.
- **Test/mutant:** none, since this is javadoc only. The race is not reproducible without a two-transaction harness, which was not built.

### Code R2-L4: adjust/delete run the finisher (approved by Nam 2026-10-15) · 0e9e3c5b
- **Change:**
  - `ReceivingService.finishReturnAdviceIfComplete(Advice)` is now `public` and `@Transactional(tenantTransactionManager, rollbackFor=…)` with REQUIRED propagation, so it joins the caller's transaction. It keeps the same exact-match rule and the same entity saves.
  - `GoodsReceiptPositionService` gets it by constructor injection (no cycle).
  - The finisher is called at the end of `adjust`, after both the amount-change branch and the zero→delete branch, and at the end of `delete`.
  - The advice is resolved by a private `adviceOf(position)`. Both of its rows are already managed from `checkAndGetGoodsReceiptPosition`.
- **New IT:** `integration/service/GoodsReceiptPositionReturnFinishIT` (PostgreSQL, `NOT_SUPPORTED`, so the service owns its transaction and the lock-read rail is active).
  - **Fixture:** positions A and B, each notified 5. A is received exactly. Every receipt has its own unit load and stock unit.

  | Test | Scenario | Expected |
  |---|---|---|
  | `adjust_shouldFinishReturnAdvice_whenOverKeyIsCorrectedToExact` | B 50 → 5 | advice and both positions FINISHED |
  | `adjust_shouldLeaveReturnAdviceOpen_whenCorrectionIsStillOver` | B 50 → 6 | OPEN |
  | `delete_shouldFinishReturnAdvice_whenDeletingTheOverKeyLeavesEveryPositionExact` | B = 5 + 3, delete the 3 | FINISHED |
  | `adjust_shouldFinishReturnAdvice_whenAdjustingTheOverKeyToZeroLeavesEveryPositionExact` | adjust the 3 → 0 (delete branch) | FINISHED |
  | `delete_shouldLeaveReturnAdviceOpen_whenThePositionIsLeftUnreceived` | B's only receipt (50) deleted | OPEN, ready to re-receive (guard) |
  | `adjust_shouldLeaveRegularAdviceOpen_whenCorrectedToExact` | REGULAR advice | stays OPEN; the adjust itself still applies |

- **New unit tests:** `GoodsReceiptPositionServiceUnitTest$ReturnFinisher` (4 tests):
  - adjust, adjust-to-0 and delete each call the finisher with the receipt's advice;
  - a refused adjust calls nothing (`verifyNoInteractions`).
  - `@Mock ReceivingService` was added; without it `@InjectMocks` would pass null.
- **Deviation from the requested list:** I replaced "delete over-keyed GRP + re-receive exact → FINISHED" with the delete and adjust-to-0 tests above.
  - The re-receive leg is `receiveGoods`' own finisher call, which finished the advice before R2-L4 as well. A test of it cannot show whether `delete` runs the finisher, so no mutant of this change could kill it.
  - That receive path is already covered by `ReceivingServiceUnitTest` S8 and `ReturnAdviceAutoReceiveIntegrationTest`.
  - The "delete leaves it OPEN, ready to re-receive" half is pinned by the guard test.

| Mutant | Edit | Result |
|---|---|---|
| R1 / R1i | drop the finisher call at the end of `adjust` | **KILLED**. Unit: `adjust_shouldRunFinisherOnTheAdvice_whenAmountChanges` and `…whenAdjustedToZero`. IT: `adjust_shouldFinishReturnAdvice_whenOverKeyIsCorrectedToExact` ("R2-L4: B corrected 50 -> 5…") and `…AdjustingTheOverKeyToZero…` |
| R2 / R2i | drop the finisher call in `delete` | **KILLED**. Unit: `delete_shouldRunFinisherOnTheAdvice`. IT: `delete_shouldFinishReturnAdvice_whenDeletingTheOverKey…` ("with the 3 deleted, B holds exactly 5…") |
| R3 / R3i | call the finisher only in the amount-change branch | **KILLED** by the adjust-to-0 tests only (unit and IT): "adjust to 0 deletes the receipt; the finisher must run on that branch too" |
| R4 | remove the RETURN type guard | **KILLED** by `adjust_shouldLeaveRegularAdviceOpen_whenCorrectedToExact` only |
| R5 | `== 0` → `>= 0` | **KILLED** by `adjust_shouldLeaveReturnAdviceOpen_whenCorrectionIsStillOver` only |
| R7 | call the finisher before the amount check | **KILLED**. `adjust_shouldNotRunFinisher_whenRefused`, plus the two call-count tests (they see 2 calls) |

The guard `delete_shouldLeaveReturnAdviceOpen_whenThePositionIsLeftUnreceived` is not killed by any mutant above. It would catch a finisher that finishes unconditionally.

### Code R2-L5: pin the `adviceposition.version` · da08ab4f
- **Change:** the L7 IT also asserts `SELECT version FROM adviceposition … ORDER BY id` = `[2, 1]`. I derived the expected values before running:
  - A = `stampDamageApplied` entity save + S8 entity save = 2;
  - B = S8 only = 1.

  `markFinished` flips the positions by a JPQL bulk update, which leaves `version` unchanged.
- **Mutant R6** (drop `finishReturnAdviceIfComplete(advice)` in `receiveGoods`, leaving `markFinished` as is): **KILLED** by exactly the new assertion, "R2-L5: the positions were FINISHED by S8's entity saves…". Every other L7 assertion still passed under this mutant, so the new one is what closes the gap.

## Suite

Commands:
- `mvn -o -B -ntp clean compile` → OK.
- Touched classes (5 unit + 4 IT classes) → 161 unit, 34 IT, 0 failures.
- Full: `mvn -o -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` (JDK 21) → see below.

First full run: BUILD FAILURE, with 8304 unit tests run and 1 failure. The failure was `TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared`: the new `NOT_SUPPORTED` IT was not listed in `EXEMPT_NON_TRANSACTIONAL`. Commit cd240b06 adds it with a reason, matching `GoodsReceiptPositionAdjustIT`. Re-run result: **BUILD SUCCESS**.

| Lane | Before (a538785e, r1) | After (cd240b06) | Delta |
|---|---|---|---|
| Surefire (unit) | 8300 run, 0 F, 0 E, 1 skip | **8304** run, 0 F, 0 E, 1 skip | +4 (GoodsReceiptPositionServiceUnitTest$ReturnFinisher) |
| Failsafe (IT) | 872 run, 0 F, 0 E, 23 skip | **878** run, 0 F, 0 E, 23 skip | +6 (GoodsReceiptPositionReturnFinishIT) |

`git status` is clean after the commits.

## Not done / for Nam

1. **R2-L1 is mitigated by documentation only.** The stale-finish window remains, and the audit detects it (`FINISHED && !fullyReceived`).
   - **Corrected in r3 (code review r3 R3-L1, 2026-10-15).** The original text here said the lock fix "would need the sibling locks taken before the location/carrier lock". That conflated two things:
     - *Closing the stale finish* needs only fix (a): lock each OPEN sibling after seeing "complete", re-read, finish only if still exact. Implemented in r3 (`16817014`, see fixes-r3.md).
     - *Removing the deadlock* is what would need every position locked before the put-away location, i.e. serialising all receives on one advice. Not done.
   - The deadlock is not a property of fix (a). The shipped finisher's flush-time UPDATE of sibling B already took B's row lock after the put-away location lock, so two receives on the same advice into the SAME location can deadlock today (40P01, one aborts, the operator retries). Fix (a) adds no new lock-order edge.
   - The carrier path takes no carrier lock (`transferUnitLoadToCarrierCore`, "NOT locked — lock must be held by caller"), so the "carrier unit load" in the r2 reasoning above was wrong too.
2. **Security R2-L1 index.** The partial index on `unitload_record (ordernumber, label) WHERE activitycode='RETURN'` needs a Flyway migration (T3). It is proposed, not done.
3. **Pre-existing, out of scope (reviewer's side note).** `adjust` and `delete` emit their stock-change DTO with `CODE_RECEIVING_REGULAR` even for RETURN advices. I left it untouched. *(r3: fixed for RETURN as R3-L2, `2061df12`; TRANSFER and the flag gating left as is.)*
