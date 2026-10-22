---
title: SBDEV-3736 — independent code review, round 3 (r2 review-fix commits)
ticket: SBDEV-3736
lane: code-reviewer r3 (sole lane)
date: 2026-10-15
head: cd240b0632a11f9860a318ab3aa04e38e269cc75
scope: git diff a538785e..cd240b06 (2b6fdee8, 81c05317, 105f83e8, 0e9e3c5b, da08ab4f, cd240b06)
worktree: .claude/worktrees/wms2-api/SBDEV-3736
verdict: COMMENT (approvable; no blocking finding; one Low disputes the r2-L1 resolution's reasoning)
counts: { critical: 0, high: 0, medium: 0, low: 6, info: 3 }
---

# SBDEV-3736 — code review r3

**Read-only.** Worktree untouched: `(git diff; git status --short) | sha1sum` = `da39a3ee…` (empty) before and after.

**Maven (JDK 21.0.11-ms, Maven 3.9.15, one process):**
`mvn -o clean verify -Dtest='GoodsReceiptPositionServiceUnitTest,ReceivingServiceUnitTest,TestClassTransactionManagerArchTest' -Dit.test='GoodsReceiptPositionReturnFinishIT,ReturnAdviceAutoReceiveIntegrationTest'`
→ BUILD SUCCESS. Surefire 95/0F/0E, Failsafe 18/0F/0E (ReturnFinishIT 6, AutoReceive 12). The run used `clean`, so no stale classes or XML.
(A first attempt returned rc=127 because Maven was off PATH. Its stale report XML was discarded, not counted.)

**DB (read-only), 4 PRD tenants:** WineCo, Hydra, ShipItEZ NY, ShipItEZ C1. Every one has `los_sysprop INBOUND_UPDATE_STOCK_IMMEDIATELY = 'true'`. See R3-L2.

## 1. Round-2 resolution

| Finding | Status | Evidence at cd240b06 |
|---|---|---|
| code R2-L1 (stale finish) | **PARTIAL** | The javadoc qualification exists (`ReceivingService.java:678-700`). But the reason it gives for rejecting fix (a) is wrong, and it leaves out the deadlock outcome. See R3-L1. |
| code R2-L2 (sort ≠ lock order) | **RESOLVED** | The javadoc "Write order" paragraph cites `hibernate.order_updates`. The test is renamed `…shouldCallSaveInAscendingIdOrder…` and its javadoc says it pins call order only. |
| code R2-L3 (stale comment) | **RESOLVED** | `ReportReadGateUnitTest:588-590` now reads "405/404 mapping … @DateTimeFormat is not load-bearing". |
| code R2-L4 (adjust/delete finisher) | **RESOLVED** | 0e9e3c5b. See §3 for propagation and flush. Two new Lows are side-effects (R3-L3, R3-L4). |
| code R2-L5 (S8 pin) | **RESOLVED** | It adds `containsExactly(2, 1)` on `adviceposition.version`. Mutant R6 is killed by this assertion alone (fixer's log). One brittleness note: R3-L5. |
| security R2-L1 (cap ≠ scan bound) | **RESOLVED** | The `ReportController` javadoc says the cap "does NOT bound the per-page unitload_record sequential scan". |

## 2. The fixer's deadlock argument for rejecting R2-L1 fix (a), checked against the code

**Lock acquisitions in `receiveGoods`, in order:**
1. `advicepositionRepository.findByIdForUpdate(advicePositionId)` at `ReceivingService:383`. This locks its **own** position.
2. Per case, inside the loop:
   - **Location path:** `unitloadBusinessService.transferUnitLoadToLocation(unitload, putaway.location(), false, …)` at `:587`. Because `ignoreLock=false`, it runs `LockReads.forUpdate(… Location …, locationRepository::findByIdForUpdate)` at `UnitloadBusinessService:245`, a `FOR UPDATE` on the put-away location that is held until commit.
   - **Carrier path:** `transferUnitLoadToCarrier` → `transferUnitLoadToCarrierCore` (`UnitloadBusinessService:408`). It takes **no** lock on the carrier ("NOT locked — lock must be held by caller", `:411`), and `receiveGoods` reads the carrier with a plain `findById`. `processTransfer` saves only the moving child unit load, so the carrier row is never locked on this path.
3. `finishReturnAdviceIfComplete(advice)` at `:607`. When it sees "complete", it **entity-saves every OPEN sibling position**:
   ```java
   List<Adviceposition> toFinish = positions.stream()
           .filter(p -> !AdviceState.FINISHED.equals(p.getState())) …
   for (Adviceposition position : toFinish) { position.setState(AdviceState.FINISHED); advicepositionRepository.save(position); }
   ```
   At flush this becomes `UPDATE adviceposition … WHERE id=B AND version=?`, which takes B's **row lock** after the location lock from step 2.

**Verdict: the cycle the fixer attributes to fix (a) already exists in the shipped finisher.** Fix (a) does not introduce it.
- Fix (a)'s `FOR UPDATE` on sibling B would be taken at the same point in T1's lock sequence as today's flush-time UPDATE: after the location lock, and only once "complete" is seen. So fix (a) adds no new lock-order edge.
- **Shared put-away location L.** T1 (finishing receive on A) holds L. T2 (over-key receive on B) holds B and waits on L, because receiving locks positions first and locations second. T1's UPDATE of B then waits on T2. This is a **deadlock today**: PostgreSQL raises 40P01 and aborts one of the two. It is not a stale finish.
- **No shared lock.** This covers the carrier path, distinct put-away locations, and every adjust/delete finisher (which holds only its own stock-unit lock, `lockStockUnitOnItsUnitLoad`). T1's UPDATE of B waits for T2 to commit. T2 never wrote B's row, so the version still matches, and T1 FINISHES with B over-received. **This is the only case in which the stale finish happens.** Fix (a) would close it there without deadlocking: T1 would wait on B, re-read the totals and see the over-key.

So fix (a) is no worse than the current code, and strictly better in the no-shared-lock cases. That includes all of R2-L4's adjust/delete callers, which were added in this same commit.

**The fixer's "Not done #1" also needs a correction.** It says closing R2-L1 "would need the sibling locks taken before the location lock". That is what removing the **deadlock** requires. Closing the **stale finish** only requires fix (a).

**Is the javadoc honest about both windows?** Partly.
- "Lost finish" is accurate.
- "Stale finish" is accurate as far as it goes. It correctly includes adjust and delete as the over-keying sibling.
- It is wrong to present the deadlock as a property of the rejected alternative. It is a property of the current finisher.
- It does not mention that, on a shared location, a concurrent sibling receive at the moment of completion aborts one receive with a deadlock.

## 3. Production change 0e9e3c5b

| Aspect | Verdict |
|---|---|
| **Propagation and transaction manager** | `@Transactional(value = "tenantTransactionManager", …)`, REQUIRED by default. `GoodsReceiptPositionService.adjust/delete` are `@Transactional("tenantTransactionManager")`. The call goes through the injected `ReceivingService` bean, i.e. through the proxy, so it **joins** the caller's tenant transaction. The bare-`@Transactional` trap does not apply because the qualifier is explicit. From `receiveGoods` it is a self-call, so the annotation is inert there, and `receiveGoods` is itself tenant-transactional. That is correct and matches the javadoc's "joins the caller's transaction". |
| **Dependency cycle** | None. `ReceivingService` does not inject `GoodsReceiptPositionService` (fields `:61-116`). The context loads in the IT lane. |
| **Flush ordering** | The finisher reads the **post-adjust** total. In the adjust branch, `findByAdvicepositionIdIn` (derived JPQL) returns the managed GRP instance from the identity map, which already holds `amount=newAmount`. Its query space also overlaps the dirty GRP, so AUTO flush writes it first. In the delete branch, the pending `em.remove` is flushed before the JPQL runs, so the removed row is not counted. The PG IT confirms both: 50→5 FINISHED, and delete 3 → FINISHED. A finisher that read a stale DB sum would leave both OPEN. |
| **Type guard** | `AdviceType.RETURN.equals(advice.getType())` comes first and is null-safe. REGULAR, TRANSFER and HUB_AND_SPOKE return before any read or write. The REGULAR leg is pinned by an IT (mutant R4 killed). |
| **Null safety** | `adviceOf` throws `EntityNotFoundException` on a missing row. That cannot happen, because `checkAndGetGoodsReceiptPosition` already resolved both rows in the same persistence context, and the `findById` calls are L1-cache hits. After `deletePosition`, `position.getAdvicepositionId()` is still populated on the removed instance. |
| **Refused paths** | `checkAndGet`, the stock mismatch and a negative amount all throw before the finisher runs (unit `adjust_shouldNotRunFinisher_whenRefused`, mutant R7 killed). |
| **OMS stock-change message** | The send is unchanged and goes through `StockChangeNotificationService.sendAfterCommit`, an after-commit callback. If the finisher's advice/position save loses an optimistic-lock race at flush, the whole correction rolls back and **no** message is sent. That is consistent behaviour. The finisher sends no message of its own. |

## 4. Test adequacy

- **Delete scenarios substituted for "delete + re-receive": I agree.**
  - The re-receive leg runs `receiveGoods`' own finisher at `:607`, which already finished the advice before this commit. Such a test stays green with or without the new `delete` call.
  - The two substitutes cover `delete` and the adjust-to-0 → `deletePosition` branch, and they kill R2 and R3.
  - The OPEN guard (B left at 0 of 5) covers "finisher must not finish unconditionally".
- **Version pin `[2,1]`: adequate, but brittle on A.** See R3-L5.
- **ArchUnit exemption for `GoodsReceiptPositionReturnFinishIT`: legitimate, not masking a problem.**
  - `NOT_SUPPORTED` is required so that `adjust`/`delete` open their **own** transaction the way the controller drives them. Under a wrapping test transaction, a propagation mutant on the finisher would be invisible.
  - Residue is handled: fixed ids in the class-unique 8737xx block, with a client-scoped `deleteResidue()` in both `@BeforeEach` and `@AfterEach`.
  - It follows the precedent of `GoodsReceiptPositionAdjustIT`.
  - The "repository tests commit and never roll back" memory is about `BaseRepositoryIntegrationTest`'s accidental landlord rollback. This class commits on purpose and purges.
  - One residue gap: see I-2.
- **Propagation is not mutation-tested.** The unit tests mock `ReceivingService`, so REQUIRED, REQUIRES_NEW and NOT_SUPPORTED look the same to them. I reason that the IT kills REQUIRES_NEW and NOT_SUPPORTED: the finisher would read the committed 50 or 8, not the uncommitted 5, and stay OPEN. I could not measure this, because the brief forbids editing the worktree. See I-1.

## 5. Assertion-loosening check

Every `-` line under `src/test` in `a538785e..HEAD`:
- `ReportReadGateUnitTest`: two comment lines were reworded.
- `ReceivingServiceUnitTest`: one `@DisplayName` and one method name changed (R2-L2 rename). The body is unchanged.

**No assertion was removed, loosened or retargeted.** All other test changes are additions.

## 6. Findings

### [LOW] R3-L1 — R2-L1 is resolved on the wrong premise: the deadlock is in today's finisher, and fix (a) would not add one
- **File:** `ReceivingService.java:692-697`:
  ```java
  * Locking the siblings ({@code findByIdForUpdate} through {@code LockReads}) after seeing "complete" and
  * re-reading the totals was considered and rejected: {@code receiveGoods} locks its own position FIRST and
  * then the put-away location / carrier unit load ({@code UnitloadBusinessService.transferUnitLoadTo*}), so a
  * finisher locking sibling B after its location lock inverts the order of a concurrent receive on B …
  ```
- **Confidence:** MEDIUM-HIGH. The lock sequence is read from the code (§2). I did not reproduce it with two transactions.
- **Issues:**
  - (i) The finisher's own `advicepositionRepository.save(B)` already locks B after L at flush, so the inversion exists now (S8 is new in this ticket) and fix (a) adds no new edge.
  - (ii) The javadoc does not mention the real outcome on a shared location: a concurrent sibling receive at the moment of completion gets 40P01 and one receive aborts.
  - (iii) The javadoc also says the carrier unit load is locked. `transferUnitLoadToCarrierCore` takes no carrier lock (`:411`).
- **Failure scenario (stale finish, still open):**
  1. T1 (an adjust, delete or carrier-path receive on A) sees "complete".
  2. A concurrent over-key receive T2 on B commits.
  3. T1's UPDATE of B succeeds after waiting, because the version is unchanged.
  4. The advice is FINISHED with B over-received, and the receipt is no longer correctable.
- **Population:** 0 on PRD (r2).
- **Fix (pick one):**
  - **(a)** Implement r2's fix (a): after "complete", run `LockReads.forUpdate` on each OPEN sibling in ascending id order, then re-run `findByAdvicepositionIdIn` and return if the totals are not exact. This is no worse on deadlocks and closes the stale finish for every adjust/delete caller and for carrier and distinct-location receives. Mutation-check it with the existing finisher tests plus a unit test that the re-read result gates the finish.
  - **(b)** Keep the code and correct the javadoc:
    - drop "inverts the order" as the reason for rejection;
    - state that the finisher's sibling UPDATE already orders B after L, so on a shared location the race resolves as a deadlock abort (one receive fails with 40P01), and elsewhere as the stale finish;
    - remove "carrier unit load" from the list of locked rows;
    - correct fixes-r2.md "Not done #1" the same way.

### [LOW] R3-L2 — adjust and delete report RETURN (and TRANSFER) corrections to OMS as REGULAR receiving
- **File:** `GoodsReceiptPositionService.java:126` (adjust) and `:220` (deletePosition):
  ```java
  list.add(sharedService.getStockChangeDTO(itemData, diffAmount.intValue(), 0, 0, 0, 0, WmsConstants.CODE_RECEIVING_REGULAR + ": " + p.getExternalid(), WmsConstants.CODE_RECEIVING_REGULAR));
  ```
  compared with `receiveGoods` (`ReceivingService:612-627`):
  ```java
  case AdviceType.RETURN: … WmsConstants.CODE_RECEIVING_RETURN + ": " + adviceposition.getExternalid(), WmsConstants.CODE_RECEIVING_RETURN)   // always sent, no flag
  case AdviceType.TRANSFER: // intentionally empty
  ```
- **Confidence:** HIGH on the mechanism. LOW on the OMS impact, because I did not read the OMS v2 consumer.
- **Issues:**
  - The receive sends +50 under reason `RETURN`, and the correction sends −45 under `RECEIVING`.
  - The quantity balances, but if OMS buckets or audits by reason code, the two do not net.
  - For TRANSFER advices the receive sends nothing, yet adjust and delete send a delta. OMS gets a correction for stock it was never told about. ShipItEZ C1 PRD has 1 TRANSFER advice.
  - The adjust/delete send is gated on `INBOUND_UPDATE_STOCK_IMMEDIATELY`, while the RETURN receive is not. The flag is `'true'` on all 4 PRD tenants I checked (WineCo, Hydra, ShipItEZ NY, ShipItEZ C1), so the REGULAR-coded message **is** emitted on PRD.
  - RETURN receipts on PRD: WineCo 10,173 grp and C1 2,988 grp. The number of past adjust/delete corrections is unknown.
- **Status:** pre-existing and not introduced here. It surfaces because R2-L4 makes adjust/delete part of the RETURN flow. Under the ticket policy it goes on **this** ticket (not yet on dev) as a finding. It was not fixed silently.
- **Fix:**
  - Choose the code by advice type, mirroring `receiveGoods`: RETURN → `CODE_RECEIVING_RETURN`, sent whatever the flag; TRANSFER → nothing; REGULAR → as today.
  - Add a unit test per type in both adjust and delete.
  - Before changing it, check the OMS v2 consumer's handling of `reason/code` (`v2/oms-laravel-api`, from origin/develop).

### [LOW] R3-L3 — once finished, a RETURN advice cannot be reopened; a multi-id batch correction can finish it partway and refuse the rest
- **Files:**
  - `GoodsReceiptPositionController.java:78-96` and `:118-140`: the per-id loop runs one service transaction per id ("ids before it have already committed").
  - `GoodsReceiptPositionService.checkAndGetGoodsReceiptPosition`: `if (!currentState.equals(WmsConstants.AdviceState.OPEN)) throw …`.
- **Confidence:** MEDIUM on the mechanism; LOW that it matters in practice.
- **Scenario:**
  1. Position B (notified 5) has receipts X=5 and Y=5.
  2. The operator batch-deletes X and Y, intending to re-key B.
  3. Deleting X leaves B at exactly 5, so the advice and all positions are FINISHED.
  4. Deleting Y is then refused with "Advice in state=FINISHED expected=OPEN", which comes back as a per-id error.
- **Outcome:** the end state is exact, so it is consistent, but it is not what the operator asked for. There is no reopen path for RETURN, because `AdviceService.close` handles REGULAR only and nothing sets a RETURN advice back to OPEN.
- **Fix:** none required. Note it in the finisher javadoc and the release note. If the operators object, defer the finish until the batch ends: the controller could collect the advice ids and call the finisher once after the loop.

### [LOW] R3-L4 — adjust/delete gained a new rollback cause (advice and position `@Version`), and it reaches the UI only as a generic per-id "Runtime Error"
- **File:** `GoodsReceiptPositionService.java:134`/`:142`, which call into `ReceivingService:741-745` (entity saves of the positions and the advice).
- **Confidence:** HIGH on the mechanism.
- **Issue:**
  - Before this change, adjust never wrote the advice or its positions. Now, when the correction completes the advice, it does.
  - A concurrent writer on the advice or a position makes the flush fail with `ObjectOptimisticLockingFailureException`, and **the correction itself rolls back**. Concurrent writers include a second correction that also finishes (documented in the javadoc) and the auto-receive damage stamp.
  - The controller's `RuntimeException` arm reports it through `addBatchServiceFailure`.
- **Rating:** correct fail-safe behaviour, and the javadoc covers the double-finisher case.
- **Fix:** none required. Optionally map the optimistic-lock failure to a "retry" message in the per-id error.

### [LOW] R3-L5 — the version pin's A=2 encodes the number of flushes, not the number of saves
- **File:** `ReturnAdviceAutoReceiveIntegrationTest.java:1371-1379`, `.containsExactly(2, 1)`. The comment reads "A = stampDamageApplied (+1, A carries damage) + S8 (+1) = 2".
- **Confidence:** MEDIUM.
- **Issue:**
  - Hibernate increments `@Version` once per flush of a dirty entity, not once per `save()`.
  - A=2 holds only because some query auto-flushes A between the damage stamp and S8. A refactor that drops that query would make A=1 with the same semantics, and the test would go red for an unrelated reason.
  - B's value of 1 is the part that kills R6 (B=0 when S8 is removed).
- **Fix:** say so in the comment ("A=2 relies on an intervening flush"), or assert `B == 1` and `A >= 1` and keep the R6 kill on B.

### [LOW] R3-L6 — `adviceOf` duplicates `checkAndGetGoodsReceiptPosition`'s two lookups
- **File:** `GoodsReceiptPositionService.java:145-149` duplicates `:156-157`.
- **Confidence:** HIGH. It is harmless: both calls are L1-cache hits.
- **Fix:** have `checkAndGetGoodsReceiptPosition` return, or expose, the resolved `Advice` (for example as a small record), so the "this is the advice whose OPEN state we checked" link is explicit.

## 7. Informational

- **I-1:** The finisher's REQUIRED propagation is pinned only indirectly, by the PG IT, which I expect kills REQUIRES_NEW and NOT_SUPPORTED. It is not measured. A one-line `findMergedAnnotation(...).propagation() == REQUIRED` unit assertion would pin it cheaply (per memory "transactional-tests-blind-to-propagation-and-readonly").
- **I-2:** The test DB seeds `INBOUND_UPDATE_STOCK_IMMEDIATELY = 'true'` (`V2.2.00__base_v2_schema.sql`, row 78). So the IT's committed adjust/delete transactions register an after-commit STOCK_UPDATE POST. Any `message` row it writes is not client-scoped and is not purged by `deleteResidue()`. `GoodsReceiptPositionAdjustIT` has the same pattern. This is cosmetic on a reused container.
- **I-3:** `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` on a method that declares no checked exceptions is inert but harmless. It keeps the house convention.

## Positive observations

- The fixer refused to write a vacuous "delete + re-receive" test and explained why. The explanation is correct.
- The finisher integrates cleanly: it is RETURN-guarded first, it joins the caller's transaction through the proxy, and it introduces no dependency cycle. The PG IT exercises the real flush semantics for both the dirty-update and the pending-remove branches.
- Mutants R1–R7 each map to a named assertion, and R6 is killed by exactly the new version pin.
- The javadoc names the double-adjust case and its optimistic-lock resolution unprompted.
- Every r2 Low was addressed. Five were resolved outright, and R2-L1 was dispositioned openly rather than silently.

## Recommendation

**COMMENT.** No Critical, High or Medium findings, so this is approvable.
- **R3-L1:** fix it in this pass, either with fix (a) or with the corrected javadoc. The present text records a false reason for rejecting a fix and omits a live deadlock outcome.
- **R3-L2:** goes on this ticket as a finding. Nam decides whether to fix it here; first check the OMS consumer.
- **R3-L3 to R3-L6:** cheap; per house rule, fix them in the same pass.
