---
title: SBDEV-3736 — independent code review, round 5 (r4 review-fix commits)
ticket: SBDEV-3736
lane: code-reviewer r5 (sole lane)
date: 2026-10-15
head: 3a475849c5a6d4b361525c3bfe15d2dca16bff00
scope: git diff 1785684e..3a475849 (3e0f961d, 784733de, 0cd102d9, 3a475849)
worktree: .claude/worktrees/wms2-api/SBDEV-3736
verdict: COMMENT (approvable; no Critical/High/Medium; 3 Low, 3 Info)
counts: { critical: 0, high: 0, medium: 0, low: 3, info: 3 }
---

# SBDEV-3736 — code review r5

**This review was read-only.**
- `(git diff; git status --short) | sha1sum` returned `da39a3ee…` (empty) before and after every Maven run.
- Mutants were run in an rsync copy of the worktree under `scratchpad/review-code-r5/mut/`. The worktree itself was
  never edited.

**Maven at HEAD 3a475849:** JDK 21.0.11-ms, Maven 3.9.15, one process, `clean`. No other Maven process was running.
- Command: `mvn -o -B -ntp clean verify -Dtest='ReceivingServiceUnitTest,GoodsReceiptPositionServiceUnitTest,BatchEndpointPerIdLookupUnitTest,TestClassTransactionManagerArchTest,LockReadsUnitTest' -Dit.test='GoodsReceiptPositionReturnFinishIT,ReturnAdviceAutoReceiveIntegrationTest,GoodsReceiptPositionAdjustIT'`
- Result: **BUILD SUCCESS**.
  - Surefire: 166 run, 0 F, 0 E. That is the fixer's 152 plus the 14 tests of `LockReadsUnitTest`, which I added.
  - Failsafe: 23 run, 0 F, 0 E.
- Report files were written:
  - The new IT appears in `TEST-…GoodsReceiptPositionReturnFinishIT.xml`.
  - `StockChangeCode` shows `[1]`–`[3]` for both adjust and delete, so the TRANSFER rows ran.

## 1. Status of the r4 findings

| Finding | Status | Evidence |
|---|---|---|
| R4-L1 (cached re-read) | **RESOLVED** | `ReceivingService.java:796-800`: the post-lock re-read goes through `LockReads.reconcileLocked`. I mutation-checked the new IT myself (§3). The residual windows are now documented, with two inaccuracies in the notes (R5-L2, R5-L3). |
| R4-L2 (TRANSFER unpinned) | **RESOLVED** | `GoodsReceiptPositionServiceUnitTest$StockChangeCode`: both `@CsvSource`s add `"TRANSFER, RECEIVING"` with an SBDEV-3775 owner comment. Rows `[3]` ran. `"TRANSFER"` matches `WmsConstants.AdviceType.TRANSFER`. HUB_AND_SPOKE is still unpinned (I-7). |
| R4-L3 (overlong line) | **RESOLVED** | `ReturnAdviceAutoReceiveIntegrationTest:1380-1382` is rewrapped. The file's other >120-column lines, for example `:901` from `20c97e2b` (already on develop), predate this ticket's diff and are out of scope. |
| I-4 (sibling id in log) | **RESOLVED** | `ReceivingService.java:791-792`. See §4. |

## 2. `LockReads.reconcileLocked` as used at `ReceivingService.java:798`

I read `LockReads.java:182-259` and the 6 existing call sites in 3 classes: `PickingorderBusinessService:217,251,669`, `StockunitBusinessService:508` and `CustomerorderPositionService:163-164`.

**Flush first: yes.**
- `:239` calls `entityManager.flush()` before the version query, so the caller's pending receipt write is never discarded by a refresh.
- In practice there is nothing left to flush at that point. The first `findByAdvicepositionIdIn` is an entity query over the table the caller just wrote (receive inserts, adjust updates, delete removes). Hibernate's AUTO flush has therefore already flushed the whole session, and the position refreshes in the lock loop do not dirty anything.
- So the explicit flush moves no write earlier and widens no lock. The caller's own receipt keeps working:
  - After the flush, its entry version equals the database version, so it is not refreshed.
  - The existing ITs still pass (adjust 50→5 → FINISHED; delete → FINISHED; adjust→0 → FINISHED).

**Only receipts whose version moved are refreshed: yes.**
- One scalar query, `select e.id, version(e) … where e.id in :ids`, runs without a lock mode.
- `refresh(row)` is called only when `persister.getVersionType().isEqual(entry, db)` is false.
- `Goodsreceiptposition` has `@Version` through `AbstractBaseEntity:34`.

**Cost:**
- One extra statement, and only on the "complete" path.
- Plus one refresh per moved receipt, normally zero.
- The `IN` list is one advice's receipts.
- No N+1 pattern, and no new lock: the version query and the refresh take none.

**Concurrent deletes.** There are three windows:

| Deleted and committed… | Effect |
|---|---|
| before the entity re-read | Absent from the result, never passed in. **Seen**, so the advice stays OPEN. |
| between the entity re-read and the version query | Absent from the version result. `reconcileLocked` skips it (`:246-248`), and its own javadoc (`:211-212`) says so: "stays in the list at its stale state". It is **counted at its stale amount**, so the finisher can FINISH. This fails open, and it is the same outcome as the documented residual window. |
| between the version query and its refresh (version moved AND then deleted; needs two concurrent writers) | `DefaultRefreshEventListener:212` → `UnresolvableObjectException` → `ExceptionConverterImpl:135-137` → jakarta `EntityNotFoundException`, with the transaction marked rollback-only → `HibernateJpaDialect.translateExceptionIfPossible:243` (cause is a `HibernateException`) → `:322-323` → **`org.springframework.orm.ObjectRetrievalFailureException`**. That is not OOLFE. |

**How the throw surfaces on each caller:**
- **Dock (`ReceivingController:438`):**
  - The exception is not `ObjectOptimisticLockingFailureException`, so the "Conflict, please try again" arm does not catch it.
  - `ObjectRetrievalFailureException` is not `net.aim_ai.wms.exceptions.EntityNotFoundException` either. That is the type imported at `:26`.
  - It falls to the `RuntimeException` arm (`:452-461`): `LOG.error("Unexpected error during receive …")` with the payload, and the operator sees *"Receiving failed due to an unexpected internal error. Please contact support."*
  - The receive is fully rolled back, so a retry works. The message is misleading but no data is wrong.
- **Batch adjust/delete:** `AdminController.addBatchServiceFailure:375-385`. The exception is not the app's `EntityNotFoundException`, so the operator gets the WARN and *"This row could not be completed. Retry id N."* This is correct.
- **Auto-receive:** the per-line catch at `ReturnAdviceAutoReceiveService:761` counts `partial_failure` and reports PARTIAL. That line's transaction is rolled back, so its receipt is gone, and the advice stays OPEN. **PARTIAL is accurate here, not a misreport.** This differs from the accepted architect-§5-risk-3 case, where every unit is received but the save lost a race.

**Precondition mismatch.** See R5-L1. `reconcileLocked`'s contract (`:182-197`) is for rows the transaction has LOCKED, either directly or through "a parent lock that every writer able to commit in the caller's window takes … name the lock at the call site". Neither holds here: the finisher holds the positions, but adjust and delete never take them. Nothing fails because of this. The helper is simply giving a best-effort snapshot, not a stable state.

**Lock scope and order:** unchanged. The position lock loop, its ascending order and the FINISHED/missing throw are untouched.

## 3. The new IT: `finisher_shouldLeaveReturnAdviceOpen_whenASiblingReceiptAmountChangedAfterTheFirstRead`

**Separate connection, committed: yes.**
- `jdbcTemplate` is `PostgresTestSupportConfig:98-106`: a `DriverManagerDataSource`, which opens a fresh auto-commit connection per call.
- The JPA side runs in `TransactionTemplate(tenantTransactionManager)`. Its routing stub hands out its own `DriverManager` connection, so the UPDATE commits outside the JPA transaction.

**Version bumped: yes.** The statement is `SET amount = 7, version = version + 1`, which matches what an entity save does.

**What it simulates.** The pre-read inside the transaction makes receipt B managed at 5. From the finisher's point of view that is the same persistence-context state as "B changed between my first read and my re-read":
- The finisher's own first read returns the managed 5, so it decides "complete".
- Only a re-read that reaches the database sees 7.

The pre-read is load-bearing. Without it the first read would hydrate 7 and the test would pass even with the mutant. As the fixer states, it is not a real contending transaction.

**Fails for the right reason: verified independently.**

| Mutant (my run, scratch copy) | Edit | Result |
|---|---|---|
| L1r | `:798-799` → raw `findByAdvicepositionIdIn(positionIds)` without `reconcileLocked` | **Killed.** ReturnFinishIT 7 run, 1 F. `[R4-L1: B holds 7 of 5 …] expected: "OPEN" but was: "FINISHED"` at `:304`. AdjustIT 4/4 green. Log: `mut-L1r.log`. |
| T-nover (test-side) | the IT's UPDATE without `version = version + 1` (production code at HEAD) | **Red.** `but was: "FINISHED"`. This proves the fix works through the version gate, as documented ("a write that does not bump the version stays invisible"). Log: `mut-T-noversion.log`. |

## 4. I-4 log line

```java
LOG.info("RETURN finisher conflict: adviceId={} lockedPositionId={} lockedState={}",
        advice.getId(), position.getId(), locked == null ? "MISSING" : locked.getState());
```

- It is parameterized.
- It carries only ids and a state: no user, SKU, quantity or payload. **No sensitive data.**
- `position.getId()` is the sibling just locked, so it is correct.
- INFO is suitable for a rare, self-healing race. The dock path also emits its existing WARN with a stack trace.
- The unit assertion pins the formatted message, `adviceId=30 lockedPositionId=11 lockedState=FINISHED`. The `ListAppender` is detached in `finally`. It is never `stop()`ped, which is harmless.
- I did not re-run the fixer's mutants I4a and I4b. The assertion is exact enough that both would plainly be killed.

## 5. Assertion-loosening check

I reviewed every `-` line under `src/test` in `1785684e..HEAD`:
- `ReceivingServiceUnitTest`: the `assertThatThrownBy(...).isInstanceOf(OOLFE)` assertion was moved unchanged inside `try`, and one blank line was removed. Its two follow-on assertions are unchanged.
- `GoodsReceiptPositionServiceUnitTest`: each `@CsvSource` was replaced by a strict superset.
- `ReturnAdviceAutoReceiveIntegrationTest`: comment only.

**No assertion was removed, loosened or retargeted.**

## 6. Accuracy of the fixer's notes ("Not done" list and the R4-L1 limits)

- **Not done #1 / fixes-r3 #1:** "locking the position in adjust/delete WOULD now be enough". That is true for correctness, but it understates the cost. See R5-L2.
- **R4-L1 limits** ("a receipt deleted between the scalar query and its refresh would make the refresh throw … fails closed: the correction rolls back and the operator retries"). This is incomplete. See R5-L3.
- **Not done #2** (the IT uses a committed side-connection update, not a contending transaction): accurate.
- **Not done #3** (TRANSFER pinned; SBDEV-3775 owns it): accurate.
- "Helper already used by CustomerorderPositionService, StockunitBusinessService and PickingorderBusinessService": accurate (6 call sites).
- "Unit tests unaffected (EntityManager null → list returned)": accurate (`LockReads:223-227`). Consequence: **only the PG IT** pins the reconcile, and the unit lane cannot see mutant L1r. That is acceptable, because the IT is in the failsafe lane that CI runs.

## 7. Findings

### [LOW] R5-L1 — `reconcileLocked` is called outside its documented precondition, and the call site does not say so
- **File:** `ReceivingService.java:796-799`
  ```java
  // R4-L1: the re-read is an entity query, so every receipt this transaction already holds comes back at its
  // first-read state. reconcileLocked flushes, then refreshes in place each one whose version has moved.
  List<Goodsreceiptposition> receipts = LockReads.reconcileLocked(entityManager, Goodsreceiptposition.class, …
  ```
- **Confidence:** HIGH on the contract mismatch. LOW on any runtime impact beyond the already-documented residual window.
- **Issue:**
  - `LockReads.reconcileLocked`'s javadoc (`:182-197`) limits it to rows the caller has locked, or that sit under a parent lock taken by every writer. It also requires the call site to *name* that lock.
  - The receipts here are under neither. `GoodsReceiptPositionService.adjust/delete` take only the stock-unit lock.
  - So the helper's guarantee ("rows … may be behind by whatever committed before the lock was granted, and by nothing after") does not hold. Its statement that "neither statement waits … no writer can be mid-commit" is also not true here, although under READ COMMITTED a plain SELECT never waits anyway.
  - The ReceivingService javadoc does describe the residual window. But the next reader of `LockReads` will see a 4th caller and assume the precondition holds there, which is the "prose enumerations rot" trap.
- **Scenario:** A future change relies on "every `reconcileLocked` call site is lock-covered", for example a rail or arch test, or a reviewer reasoning from the helper's javadoc. That would misgrade this site.
- **Fix:** One comment line at the call site, such as: "NOT lock-covered: adjust/delete take no position lock, so this is a best-effort snapshot; a sibling write committing after this statement is the residual window (javadoc)". Alternatively, use the r4-suggested scalar `sum(amount) group by advicepositionId`, which bypasses the identity map and has no precondition. Either works. The comment is the cheap fix.

### [LOW] R5-L2 — "the position lock in adjust/delete would now be enough" omits a new deadlock edge with the finisher's ascending locks
- **Files:**
  - `ReceivingService.java:707-711`: "with the reconciled re-read, that lock would now be enough (a lock-order change against their stock-unit lock, not done)"
  - fixes-r4.md "Not done #1"
  - fixes-r3.md #1 (amended)
- **Confidence:** MEDIUM. This is reasoning from the lock order, not a run.
- **Issue:**
  - If adjust/delete lock their *own* receipt's position before the write, that lock is taken in caller order, not ascending order.
  - Two corrections on *different* positions of one advice can both see "complete". "Two finishers" in the javadoc already allows that for non-additive corrections, because neither sees the other's uncommitted change.
  - Then T1 holds A and its finisher wants B, while T2 holds B and its finisher wants A. PostgreSQL aborts one of them with 40P01.
  - This fails safe: it surfaces as `CannotAcquireLockException` → "Retry id N". But it is a second new lock-order cost beside the stock-unit one, and the notes name only the stock-unit one.
- **Fix:** Add it to the note, e.g. "…and against the finisher's ascending sibling locks (two corrections on different positions can then deadlock; fail-safe retry)". Alternatively, specify that adjust/delete lock *every* open position of the advice in ascending id order up front, which keeps a single lock order.

### [LOW] R5-L3 — the R4-L1 "deleted receipt" limit is incomplete, and "operator retries" is not what the dock shows
- **File:** fixes-r4.md, R4-L1 "Limits" bullet 2: "A receipt deleted between the scalar query and its refresh would make the refresh throw … it fails closed: the correction rolls back and the operator retries."
- **Confidence:** HIGH. It follows from `LockReads:211-212,246-248` and the Hibernate 6.6.39 and Spring ORM 6.2.15 sources (§2).
- **Issue:**
  - **(a) The likelier sub-window fails open.** A sibling receipt deleted between the entity re-read and the version query is silently kept at its stale amount and counted, so the advice can be FINISHED. The impact is the same as the documented residual window, but the notes present the delete case only as fail-closed.
  - **(b) The narrow sub-window has a different exception and message.** The fail-closed case throws `ObjectRetrievalFailureException`, not OOLFE. On the dock it shows "unexpected internal error. Please contact support." and logs at ERROR with the full payload, not "Conflict … try again".
  - Batch adjust/delete ("Retry id N") and auto-receive (PARTIAL, line rolled back) are correct.
- **Scenario:** An operator on the dock hits the narrow race and opens a support ticket for a self-healing condition. The odds are very low: it needs a version-moving write *and* a delete of the same sibling receipt inside a microsecond window.
- **Fix:**
  - Correct the bullet in fixes-r4.md, and optionally add a sentence to the finisher javadoc. Suggested wording: "Deleted after the re-read: counted stale (residual window). Deleted after the version query: refresh throws `ObjectRetrievalFailureException`, the transaction rolls back; dock shows the generic error."
  - Optional code change: catch `ObjectRetrievalFailureException` around the reconcile and rethrow it as `ObjectOptimisticLockingFailureException(Goodsreceiptposition.class, …)`, so every caller reports it as a conflict and retry. This is not required.

## 8. Informational

- **I-5 (carried, no action):** the unit lane cannot see the reconcile, because the EntityManager is null. Only the PG IT kills mutant L1r. That is acceptable, since CI runs failsafe.
- **I-6:** the explicit flush in `reconcileLocked` flushes the whole session, not only receipts. On all three callers the session is already clean at that point (AUTO flush at the first receipt read; see §2), so lock acquisition does not move earlier. A future caller that dirties a non-receipt entity between the first read and the finisher would see that write flushed (and its row lock taken) slightly earlier than commit. That is benign.
- **I-7:** HUB_AND_SPOKE adjust/delete also fall through `receivingCode` to `"RECEIVING"` (`GoodsReceiptPositionService:157-160`) and are not pinned. This is outside R4-L2's ask. If SBDEV-3775 touches `receivingCode`, it should pin that type as well.

## Positive observations

- R4-L1 was fixed by reusing the existing helper, with no new repository method and no new lock. The re-read is now version-reconciled at the cost of one statement. The caller's own write survives, which I verified both by mechanism and with the existing ITs.
- The new IT is well built:
  - Its precondition asserts that the rows are managed and that the side-connection write committed.
  - Its pre-read is exactly the step that makes it discriminating.
  - It fails for the right reason (`but was: "FINISHED"`), which I verified independently, and it also proves that the fix is version-gated.
- The fixer caught that R4-L1 made fixes-r3 "Not done #1" wrong, and amended it in place.
- The I-4 log is minimal, parameterized and pinned by an exact formatted-message assertion, without weakening the existing OOLFE assertion.
- No assertion was loosened. The worktree is clean. The targeted lanes are green at HEAD (166 unit, 23 IT).

## Recommendation

**COMMENT: approvable.** There are no Critical, High or Medium findings at any confidence.
- R5-L1, R5-L2 and R5-L3 are comment and evidence-note corrections (about 3 lines in `ReceivingService` plus edits to fixes-r4.md and fixes-r3.md).
- Under the house rule, fix all three in the same pass. None changes runtime behaviour, so no new test is needed. A re-review of the comment-only diff is enough.
