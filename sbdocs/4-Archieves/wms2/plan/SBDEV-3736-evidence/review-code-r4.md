---
title: SBDEV-3736 — independent code review, round 4 (r3 review-fix commits)
ticket: SBDEV-3736
lane: code-reviewer r4 (sole lane)
date: 2026-10-15
head: 1785684edbab032a436eea7c408f06f098792bcd
scope: git diff cd240b06..1785684e (16817014, f83e545a, 2061df12, 03c0c9ae, 74765d44, 1785684e)
worktree: .claude/worktrees/wms2-api/SBDEV-3736
verdict: COMMENT (approvable; no Critical/High/Medium; 3 Low, 3 Info)
counts: { critical: 0, high: 0, medium: 0, low: 3, info: 3 }
---

# SBDEV-3736 — code review r4

**Read-only.** I did not edit the worktree. `(git diff; git status --short) | sha1sum` returned `da39a3ee…` (empty) both before and after the Maven run.

**Maven:** JDK 21.0.11-ms, Maven 3.9.15, one process, `clean`.
- Command: `mvn -o -B -ntp clean verify -Dtest='ReceivingServiceUnitTest,GoodsReceiptPositionServiceUnitTest,BatchEndpointPerIdLookupUnitTest,TestClassTransactionManagerArchTest' -Dit.test='GoodsReceiptPositionReturnFinishIT,ReturnAdviceAutoReceiveIntegrationTest,GoodsReceiptPositionAdjustIT'`
- Result: **BUILD SUCCESS**. Surefire 150 run / 0 F / 0 E. Failsafe 22 run / 0 F / 0 E (AutoReceive 12, ReturnFinishIT 6, AdjustIT 4). These match the fixer's counts.
- The lock-read rail (`META-INF/spring.factories`, active in every Spring test context) stayed silent. `lock-read-rail-baseline.txt` has no Adviceposition or ReceivingService entry. This is indirect evidence that the `@PersistenceContext(unitName="tenant")` field is injected and that the finisher really takes the managed-row `LockReads` path. If the field were null, the code would fall back to the version-checked `findByIdForUpdate` upgrade, and the rail would flag it.

## 1. Resolution of the r3 findings

| Finding | Status | Evidence at 1785684e |
|---|---|---|
| R3-L1 (stale finish / wrong premise) | **RESOLVED** (in the form Nam chose) | `ReceivingService.finishReturnAdviceIfComplete:775-791`: lock each non-FINISHED position in ascending id order via `LockReads.forUpdate(… findByIdForUpdate)`, then `receivedTotals` again, then finish. The javadoc now names the shared-location deadlock as pre-existing, says the carrier path takes no lock, and lists the residual stale finish. One residual nuance: see R4-L1. |
| R3-L2 (RETURN corrections coded RECEIVING) | **RESOLVED** (RETURN only) | `GoodsReceiptPositionService.receivingCode` is used in adjust (`:124`) and delete (`:230`). The flag gate is unchanged in both. TRANSFER still falls through to REGULAR. See §5 and R4-L2. |
| R3-L3 (no reopen) | **RESOLVED** (documented) | Finisher javadoc, "No reopen" paragraph. The release-note line is in fixes-r3.md. |
| R3-L4 (new rollback cause) | **RESOLVED** | Javadoc paragraph added. `BatchEndpointPerIdLookupUnitTest$GoodsReceiptPositionBatch` gains `adjust_/delete_shouldReportRetry_whenTheFinisherLosesAnOptimisticLockRace`, which pins the retry text and that later ids still run. |
| R3-L5 (version pin counts flushes) | **RESOLVED — refutation verified** | See §7. |
| R3-L6 (duplicate lookups) | **RESOLVED** | `CheckedReceipt` record. See §6. |
| I-1 (propagation unpinned) | **RESOLVED** | `finishReturnAdviceIfComplete_shouldJoinTheCallersTenantTransaction` asserts the value, REQUIRED and not readOnly. |
| I-2 (message residue) | **RESOLVED** | `deleteResidue()` now runs `DELETE FROM message WHERE process = STOCK_UPDATE AND message LIKE '%SBDEV3736R2-SKU%'`. The SKU has no `_` or `%`, so the LIKE cannot over-match. |
| I-3 (inert rollbackFor) | **Accepted** | Kept to match the house form. That is the reasonable call. |

## 2. Finisher lock and re-read

**Lock order.** `toFinish` is built with `.filter(!FINISHED).sorted(comparing(getId))`, and the lock loop iterates it in that order. So the locks are taken in ascending id order. Two finishers on the same advice therefore acquire position locks in the same order and cannot deadlock with each other.

**What gets locked.**
- Every position not yet FINISHED is locked, including the caller's own position.
- For `receiveGoods`, the caller's own position A already sits at `PESSIMISTIC_WRITE` from `:383`. Its lock comes from the scalar `select e.id … FOR NO KEY UPDATE`, which the transaction already holds, so it does not wait. A is then refreshed in place.
- For adjust/delete, the receipt's advice position is locked here for the first time.
- Already-FINISHED positions are neither locked nor saved.

**No version-checked upgrade.** `findByAdviceId` loads every position plain, so every position is managed when the loop runs. `LockReads.forUpdate` therefore always takes its managed branch: a scalar lock query, then `refresh(managed, PESSIMISTIC_WRITE)`. The refresh removes the entity entry before reloading, so it does not throw `StaleObjectStateException`, which is the trap described in the memory note *findbyidforupdate-throws-at-the-lock-read*. Unit tests have a null EntityManager, so they fall back to the finder. That is why the fixture stubs `findByIdForUpdate(11L)`.

**Pending writes are not discarded.**
- The scalar JPQL is over `Adviceposition`, so AUTO flush runs first whenever the adviceposition table has pending changes. In `receiveGoods` that covers any dirty edit to A.
- The caller's GRP insert or update was already flushed by the first `findByAdvicepositionIdIn`.
- The refresh touches only Adviceposition rows and cascades nowhere, because the codebase uses no association mappings.

**Positions after the refresh.** The refreshed instances are the same objects held in `positions`. So `everyPositionExact(positions, …)` after the lock reads the locked `notifiedamount`, and the later `save`s carry the locked version. The non-toFinish positions (already FINISHED) are not refreshed, which is harmless.

**The re-read does NOT read DB state for receipts already in the persistence context.** `findByAdvicepositionIdIn` is an entity query. Hibernate returns the already-managed instance for any row it saw in the first read and keeps that instance's state; it does not overwrite it from the result set. The consequences:
- **New receipt rows** (a concurrent receive only INSERTs) are hydrated fresh, so they are seen. This is the race the lock is meant to close, and it is closed.
- **Deleted rows** are absent from the result, so they are seen.
- **Updated amounts** (a concurrent adjust of an existing receipt) are **not** seen.

The javadoc states this accurately ("The re-read also returns receipt entities this transaction already holds at their first-read state…"). It matters for the fixer's open item; see R4-L1.

**`order_updates` and the caller's flush.** The UPDATEs are still emitted at flush and sorted by `hibernate.order_updates`. By then the transaction already holds every row it writes, so flush order no longer decides lock order. The javadoc "Lock and write order" paragraph says exactly this. The caller's own GRP is flushed earlier, at the first `findByAdvicepositionIdIn` (adjust) or by the pending remove (delete). The ITs confirm the post-correction totals: 50→5 FINISHED, and delete → FINISHED.

**Advice row.** It is still unlocked and unrefreshed. A concurrent advice writer surfaces as an `@Version` failure at flush. That is the documented, unchanged behaviour.

## 3. The added `ObjectOptimisticLockingFailureException` throw (locked position FINISHED or missing)

`ReceivingService:783-787`:
```java
if (locked == null || AdviceState.FINISHED.equals(locked.getState())) {
    throw new ObjectOptimisticLockingFailureException(Adviceposition.class, position.getId());
}
```

I checked each caller for a case where this rolls back a legitimate operation that would previously have committed.

**Dock receive (`ReceivingController:438`).**
- A receive reaches "complete" only if its own position A is exact *including* its own uncommitted insert of ≥1 unit (`amountBottles >= 1`).
- Any other finisher that FINISHED A's sibling must have seen A exact *without* that insert. Exact-before plus ≥1 means over-received, which contradicts "complete". So **no finisher can trigger this throw against a receive**.
- The only remaining writers that set positions to FINISHED are bulk updates:
  - `ReturnAdviceAutoReceiveService.markFinished:961-968`, which flips a RETURN advice.
  - `AdviceService.close` (REGULAR only) and accept-transfer (TRANSFER only). These two never reach the RETURN-guarded finisher.
- Before this change, a receive racing `markFinished` already failed. `markFinished` does `adviceRepository.saveAndFlush(advice)`, which bumps the advice `@Version`, so the receive's `adviceRepository.save(advice)` hit OOLFE at flush.
- **The outcome is identical, and only the throw point moved earlier.** The operator sees the existing `ReceivingController:439` arm: "Conflict — Data was modified by another user. Please try again." A retry is then refused by the advice/position OPEN check, which is correct because the advice really is FINISHED.

**Auto-receive (`ReturnAdviceAutoReceiveService:752`).**
- Each line's `receiveGoods` runs in its own transaction, and the per-line `RuntimeException` arm reports PARTIAL.
- By the argument above, the throw needs a concurrent non-finisher FINISHED writer on the same advice. Within one auto-receive run, the only such writer is that run's own `markFinished`, which runs after the loop.
- If a throw did happen, only that line's transaction rolls back. Earlier lines are already committed, so no received stock is lost, and PARTIAL is the honest report.
- This path is unchanged in practice.

**Adjust/delete (batch, per id).** This is the case the throw exists for.
- Two non-additive corrections can both see "complete". The second one's lock waits, then reads FINISHED.
- Without the throw, the second correction would re-read "not exact", return, and commit a correction against a FINISHED advice, which `checkAndGetGoodsReceiptPosition` would have refused.
- Rolling it back matches the pre-lock behaviour, where its stale advice save failed. It is also semantically right: the two corrections' combined effect leaves the position under its notified amount.
- The operator gets "This row could not be completed. Retry id N." (pinned by test). The retry is refused with "Advice in state=FINISHED expected=OPEN", consistent with R3-L3.

**Missing row.** Deleting an advice position under an OPEN advice has no in-app path, so this is defensive. Throwing is better than proceeding without the lock (see the memory note *for-update-on-a-missing-row*).

**Rating: correct, no regression on any caller.** See I-4 (Info) for the observability nuance.

## 4. The fixer's open item: stale finish from a sibling adjust/delete

**Confirmed.**
- `adjust` and `delete` lock only the stock unit (`lockStockUnitOnItsUnitLoad`, `GoodsReceiptPositionService:196-205`), never the advice position.
- So T1, a finisher on A that has locked A and B, does not serialise with T2, an adjust of one of B's receipts.
- If T2 commits after T1's re-read, T1 FINISHES with B off its notified amount.
- If T2 commits *between* T1's two reads, T1 still misses it, because the re-read returns T1's managed GRP at its first-read amount (§2).

**Population:** 0 on PRD (r2/r3). **Rating: LOW**, carried as R4-L1 because the proposed remedy is incomplete.

## 5. R3-L2: correction codes

- `receivingCode`: RETURN → `"RETURN"`, otherwise `"RECEIVING"` (`WmsConstants:1050/1053`).
- It is used for both the comment prefix and the activity code in adjust (`:124-125`) and `deletePosition` (`:230-231`).
- **REGULAR:** unchanged (`"RECEIVING"`).
- **Gating:** unchanged. Both sends are still inside `if (Boolean.parseBoolean(flag))`. Note that the RETURN *receive* in `receiveGoods:629-631` is not flag-gated. All 4 PRD tenants have the flag set to `true` (r3), so this asymmetry is moot today. Nam decided to fix the label only.
- **TRANSFER:** unchanged. It still sends a `"RECEIVING"` delta, by falling through to REGULAR. This is not accidentally changed, but nothing pins it either (R4-L2).
- **Tests:** `GoodsReceiptPositionServiceUnitTest$StockChangeCode` covers RETURN and REGULAR for both adjust and delete, using wire literals. That is a good choice.

## 6. R3-L6 refactor (`CheckedReceipt`)

- **Old code:** `checkAndGetGoodsReceiptPosition` returned the same `position` argument it was given (verified at `cd240b06`). So switching callers from `position = checkAndGet(position)` to using the argument directly changes nothing.
- **Validations:** all of them are still present and in the same order: null, advice OPEN, stock unit on unit load, goods-in area.
- **Message externalid:** this now comes from the advice position checked at entry, not from a second `findById`. Within one persistence context those are the same instance, an L1 hit.
- **Finisher argument:** this is the advice whose OPEN state was checked, as before.
- **Verdict:** no behaviour change.

## 7. R3-L5 refutation

Verified against `ReturnAdviceAutoReceiveService`:
- `execute()` is not `@Transactional`.
- The receive loop (`:749-760`) calls `receivingService.receiveGoods` per line. Each call is its own tenant transaction through the proxy, and S8 fires in the last line's transaction.
- After that loop finishes, the damage loop (`:830-840`) calls `applyDamage` → `self.stampDamageApplied` (`:1067-1074`), which runs in its own `@Transactional(tenantTransactionManager)` transaction.
- So A's two version bumps come from two separate commits. The new `LockReads` refresh in S8 does not bump the version.
- **The fixer is right.** `containsExactly(2, 1)` is not brittle in the way r3 claimed, and the rewritten comment is accurate.

## 8. Assertion-loosening check

Every `-` line under `src/test` in `cd240b06..HEAD` is in `GoodsReceiptPositionReturnFinishIT`'s itemdata seed INSERT, where the SKU literal became the bind parameter `SKU` with the same value. **No assertion was removed, loosened or retargeted.** All other test changes are additions.

## 9. Findings

### [LOW] R4-L1 — the finisher's re-read is cached for receipt UPDATEs, so the fixer's proposed fix for the residual stale finish would not work by itself
- **File:** `ReceivingService.java:802-809`:
  ```java
  private Map<Long, BigDecimal> receivedTotals(List<Long> positionIds) {
      for (Goodsreceiptposition grp : goodsreceiptpositionRepository.findByAdvicepositionIdIn(positionIds)) {
  ```
  This is called a second time at `:789`, after the locks.
- **Confidence:** HIGH on the mechanism, which is standard Hibernate identity-map semantics for entity queries. MEDIUM on impact.
- **Issue:**
  - The post-lock re-read is an entity query. Every GRP row that the first read loaded comes back as the managed instance, with its first-read amount.
  - It does see INSERTs and DELETEs, but not amount UPDATEs.
  - fixes-r3.md "Not done #1" proposes closing the residual stale finish by locking the receipt's advice position in adjust/delete. That would make T1 wait for T2's adjust to commit. But T1's re-read would still return T2's receipt at its old amount, so T1 would finish anyway.
- **Failure scenario:**
  1. Position B is notified 5 and has receipt Y=5. Position A is exact after T1's correction.
  2. T1 (delete on A) reads "complete" and locks A and B.
  3. T2 (adjust Y 5→7) commits. Today it never waits. Under the fixer's proposal it would wait for T1's lock, so the interleaving would differ, but with the same blindness if T2 commits between T1's reads.
  4. T1's re-read still sees Y=5, and T1 FINISHES the advice with B at 7/5. The advice is now uncorrectable.
- **Population:** 0 on PRD. The javadoc already admits the between-reads blindness.
- **Fix:** make the re-read a scalar aggregate that bypasses the identity map, for example a repository method `@Query("select g.advicepositionId, coalesce(sum(g.amount),0) from Goodsreceiptposition g where g.advicepositionId in :ids group by g.advicepositionId")`. Use it for the post-lock read; AUTO flush still pushes this transaction's own pending GRP change first. Mutation-check it with a PG IT that adjusts a sibling receipt in a committed transaction between the two reads, or with a unit test that stubs a different scalar result for the re-read. If the residual case is later closed by locking the position in adjust/delete, this change is a **prerequisite**. In any case, correct fixes-r3.md "Not done #1" so that the next fixer does not ship a lock that does nothing.

### [LOW] R4-L2 — TRANSFER's "unchanged" correction code is not pinned
- **File:** `GoodsReceiptPositionServiceUnitTest$StockChangeCode`: `@CsvSource({"RETURN, RETURN", "REGULAR, RECEIVING"})`.
- **Confidence:** HIGH.
- **Issue:**
  - The brief requires TRANSFER to be left unchanged for SBDEV-3775. It is, through the `else` branch of `receivingCode`.
  - No test covers it. A mutant `TRANSFER → RETURN`, or one that skips TRANSFER, survives.
  - SBDEV-3775 will change this deliberately, so an explicit pin now gives that ticket a clear red-to-green.
- **Fix:** add `"TRANSFER, RECEIVING"` to both `@CsvSource`s, with a comment pointing to SBDEV-3775 as the owner of that behaviour.

### [LOW] R4-L3 — overlong comment line in the version-pin explanation
- **File:** `ReturnAdviceAutoReceiveIntegrationTest.java:1380`: `// … in its own tenant transaction. Each commit flushes A once. A = 1 would therefore mean those two writes were merged into one transaction`, about 215 characters on one line. The surrounding lines wrap at about 120.
- **Confidence:** HIGH. Cosmetic only.
- **Fix:** rewrap the line.

## 10. Informational

- **I-4:** On the dock-receive path, the new throw is reachable only from a concurrent bulk `markFinished` on the same RETURN advice. The previous failure was also an OOLFE (advice `@Version`), so the outcome is unchanged. The `ObjectOptimisticLockingFailureException(Adviceposition.class, id)` message names a position the operator did not touch. That is fine, because the controller replaces it with generic "Conflict" text. Server-side, it is logged at WARN as "Receive conflict" with the position id of the receive, not of the locked sibling. If you want the rate to be diagnosable, `LOG.info` the sibling id and state just before throwing. Optional.
- **I-5:** Three finisher unit tests drive the scenario through `receiveGoods`: `…whenALockedPositionWasFinishedConcurrently` and the re-read/lock-order tests. §3 argues that a *receive* cannot meet the "finished concurrently" case except against `markFinished`. The tests are valid as mechanism pins, because the finisher is shared. Their javadoc already names adjust/delete as the real case. No change needed.
- **I-6:** New lock edge in the delete finisher. `deletePosition` sends the stock unit and possibly the unit load to Nirvana before the finisher locks positions, so it may hold Nirvana-side locks while it waits on a sibling position held by a receive. A cycle would need that receive to want the same Nirvana or unit-load rows, and I found no such path. The edge is not new: the r2 flush-time UPDATE of the sibling had it at the same point.

## Positive observations
- Nam's chosen fix (a) is implemented exactly as specified: the existing `findByIdForUpdate` through `LockReads`, no new repository method, ascending order, and a re-read gate.
- The fixer found and closed a regression the brief did not anticipate: two finishing corrections, where without the FINISHED check the second would have committed against a FINISHED advice. I verified the reasoning for every caller, and the throw changes no legitimate outcome.
- The javadoc is now honest. It states what the lock closes, what remains (including the identity-map blindness), that the deadlock predates the lock, that the carrier path takes no lock, the two-finisher case, the rollback cause and its retry text, and the no-reopen rule.
- The R3-L5 refutation is correct and well argued. The pin was kept, not loosened.
- Every mutant L1a–L1g, L2a–L2f, L4a–L4c and I1 maps to a named test. The wire-literal assertions guard against renamed constants.
- No assertion was loosened. The worktree is clean. The targeted lanes are green at HEAD.

## Recommendation

**COMMENT — approvable.** There are no Critical, High or Medium findings at any confidence.
- **R4-L1:** fix it in this pass with the scalar re-read, which is cheap and strictly improves the finisher. At minimum, correct fixes-r3.md "Not done #1" so that the future lock-in-adjust/delete fix is not built on a cached read.
- **R4-L2 and R4-L3:** trivial; fix them in the same pass under the house rule.
