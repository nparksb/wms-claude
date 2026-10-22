---
ticket: SBDEV-3854
lane: independent code review (read-only, no maven)
reviewed: 54be5a40 vs origin/develop fb087689 (v2/wms2-api)
tree: detached worktree at 54be5a40 (scratchpad rev-a), removed after review
date: 2026-10-21
verdict: COMMENT. No High finding at HIGH confidence. Fix M1-M4 before the PR.
---
# SBDEV-3854: code review

## Summary
- Files reviewed: 5. That is 4 main files plus the new IT. I also opened every caller of the 3 newly transactional methods, and their callers.
- Findings: High 0 · Medium 4 · Low 10 · Nit 2. That is L1-L8 plus Q1-Q2; the two Q items are low-confidence and are listed under Open Questions.
- **Stage 1 (spec): pass.** The three annotations plus the FLA pre-proxy refusal follow the architect's recommendation items 1-4.
  Item 5 (the two `MobileCycleCountService` recount methods) was not done. The new comment on `sendStockUnitToNirvana`
  names those methods as beneficiaries, but nothing tests them (M4).

## Focus (1): rollback-only poisoning, caller census
I grepped every call site in `src/main` (`git grep` over service/, mobile/, schedulejob/, controller/).

| Method | Caller | Outer tx? | Catches Business/Facade inside a tx and continues? | Verdict |
|---|---|---|---|---|
| `sendStockUnitToNirvana` | `UnitloadService.deleteUnitLoad:774` | yes, the new one | no. It rethrows and the proxy owner rolls back | safe |
| | `StockunitBusinessService:518` (`transferStockToUnitLoad`) | yes | a `this` call, so the annotation is inert | unchanged |
| | `GoodsReceiptPositionService.deletePosition:227` ← `adjust:93`/`delete:136` (both tx) ← `GoodsReceiptPositionController:89/:133` | yes | no try/catch in the file; the controller catches outside | safe |
| | `MobileCycleCountService:228/:443` ← `CycleCountLosController:162/:286` | none (no class-level tx) | the controller catches outside | safe, but see M4 |
| | `FixLocationAssignmentService.delete:278` ← `FixLocationAssignmentController:129` | none | outside | safe |
| | `FixLocationAssignmentService.delete:278` ← `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` (REQUIRES_NEW) | yes | **yes** | closed by the new guard, see below |
| `deleteUnitLoad` | `UnitLoadController:112/:175`, plus self-calls from `deleteUnitLoadRecursive` | none / the recursive tx | the controller catches outside | safe |
| `deleteUnitLoadRecursive` | `UnitLoadController:208`, plus a self-call | none | outside | safe |

**I found no second poisoning caller.** The FLA guard is *complete* for the job path. `FLA.delete` reaches
`sendStockUnitToNirvana` only with `amount == 0`, because it refuses `amount > 0` at :267. So `changeAmount`, and its
locked-row `STOCKUNIT_HAS_RESERVATION`, never runs on that path. The guard and the method's own pre-check read
the **same** instance (`stockUnit`). The only other checked throw is `orElseThrow("StockUnit not found")` on a
row this same persistence context just loaded inside REQUIRES_NEW, so it cannot fire there. Runtime exceptions
already escaped the job's catch before this change. `FLA.delete` and `UnitloadBusinessService.sendToNirvana` carry no `@Transactional`, so their
own Business refusals still do not poison.

## Findings

### [Medium] M1: two comments now state the opposite of the code (stale sibling comments)
Confidence: HIGH
- `src/main/java/net/aim_ai/wms/service/UnitloadService.java:497-503`:
  > "The third call site below sits inside {@code deleteUnitLoadRecursive}, which carries no {@code @Transactional} (the only one in this file is on {@code moveStockToNewDamagedContainer}), so with two or more children a throw while walking child #2 lands after child #1's delete has already committed."

  All three claims are now false. The method is annotated at :592, the file has 3 `@Transactional` methods (:175, :592, :734), and a throw on
  child #2 now rolls child #1 back. That last point is exactly what the new IT test 3 asserts.
- `src/test/java/net/aim_ai/wms/unit/service/UnitloadServiceUnitTest.java:1375-1377`:
  > "{@code deleteUnitLoadRecursive} carries no {@code @Transactional}, so an unbounded walk here spins while earlier children are already deleted."

  This is now false as well. An unbounded walk would spin inside one open transaction, holding every child's stock-unit locks, which is a different hazard.

Fix: rewrite both. In the javadoc, keep the SBDEV-3119 history, but say that since SBDEV-3854 the recursive delete is one tx and a throw
on child #2 rolls child #1 back. In the unit test, the termination rationale becomes "an unbounded walk would spin while holding the tree's SU row locks".
This is the "fixing a false claim makes a new one / sweep siblings" pattern: the commit fixed the B-3 comment and the
controller comment but missed these two.

### [Medium] M2: the OMS STOCK_UPDATE delta comes from an unlocked read (newly reachable)
Confidence: MEDIUM
`UnitloadService.java:758` and `:772`:
```java
List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(unitLoad.getId());
...
stockChangeList.add(sharedService.getStockChangeDTO(itemData, stockUnit.getAmount().negate().intValue(), damaged, 0, on_hold, 0, ...));
stockunitBusinessService.sendStockUnitToNirvana(stockUnit, ...);
```
The delta, and the `damaged`/`on_hold` split derived from `entityLock`, are taken from the plain read at :758. `changeAmount`
then locks and **refreshes** the row (`LockReads.forUpdate`) and writes the stockrecord from the *current* amount. If a pick or
adjust commits between :758 and the lock, OMS is told `-12` while WMS removed and recorded `-10`, and OMS drifts. Before this fix the
path 500'd for any stock-bearing container, so this window is new in practice. There is a direct house precedent:
`GoodsReceiptPositionService.java:222-224`
> "SBDEV-3729: locked before its amount becomes the OMS stock-change delta below, as in adjust."

Fix: in the loop, lock first (`LockReads.forUpdate(entityManager, Stockunit.class, id, stockunitRepository::findByIdForUpdate)`),
then build the DTO from the locked row and pass the locked row on. Iterating ids in ascending order also fixes L2. Pin it with a test
whose fixture changes the amount between the read and the lock, or at least assert that the DTO equals the stockrecord delta.

### [Medium] M3: `assumeThat` on heap order can silently SKIP the two rollback tests
Confidence: HIGH (that the mechanism exists) / MEDIUM (that it happens in practice)
`src/test/java/net/aim_ai/wms/integration/service/DeleteContainerWithStockIT.java:197` and `:222`:
```java
assumeThat(order).as("fixture order: the unreserved unit must be processed first").containsExactly(SU_A, SU_B);
assumeThat(children).as("fixture order: the deletable child must be processed first").containsExactly(CHILD_1, CHILD_2);
```
`findByUnitloadId` and `findByCarrierunitloadId` are unordered, so they return heap order. The shared PG IT DB has dead and free space
from every `deleteResidue()`, and from `:216`, which deletes and re-inserts SU_A. Autovacuum can hand that space back to a later insert. When the order flips, these
two tests, the only ones that kill the "remove `@Transactional` from deleteUnitLoad / deleteUnitLoadRecursive" mutants,
are reported as **skipped**, and failsafe counts a skip as a pass. An assumption failure is the wrong instrument for a
precondition the test needs (see the memory "Unordered finder = heap order; UPDATE moves row → assert fixture order").
Fix: use `assertThat` so the test fails loudly. Better, make the tests order-independent. For example, seed two *unreserved*
units plus a third reserved one, and assert that "at least one unit was mutated before the refusal", or
pick the refusal so that it fires after the loop regardless of order.

### [Medium] M4: the cycle-count recount-to-zero paths are newly live, untested and non-atomic
Confidence: MEDIUM
The new comment at `StockunitBusinessService.java:564-569` says:
> "Callers reached with no transaction (the container deletes until SBDEV-3854, MobileCycleCountService's recount-to-zero paths) got a 500 here, so this method opens one itself"

So the commit deliberately turns `recountSingleUnitLoad` (:228) and `countBySKURecount` (:443) from always-500 into working. They still run
with no tx: the position is saved FINISHED, the SU is retired in its own tx, then `unitloadBusinessService.sendToNirvana`
runs auto-commit, and the STOCK_UPDATE goes out **synchronously** (the `else` branch of `OmsNotificationService.sendAfterCommit`).
A refusal in `sendToNirvana` would leave the SU retired, the container live and OMS unnotified. Separately, the delta is
`count - originalAmount`, where `originalAmount = stockUnit.getAmount()` (:216/:426) and `stockUnit` is the **client-deserialized** DTO
entity (`CycleCountInfoDto.stockUnit`). So the delta is whatever the handheld last saw, not the locked row. No test covers either path:
IT test 5 calls `sendStockUnitToNirvana` directly and is named for "cycle count recounts" without exercising them.
Fix: either do architect item 5 (`@Transactional(tenantTransactionManager, rollbackFor=Business,Facade)` on both methods;
the controllers catch outside the proxy, so it is poison-safe) and add one IT per method, or narrow the comment and record
the deferral on the ticket. The architect's "cycle-count residue" census (FINISHED positions whose stock was never zeroed) is still
unrun because the DB MCPs were down.

### [Low] L1: the deleteUnitLoad javadoc overstates what this annotation fixes
Confidence: HIGH
`UnitloadService.java:728-729`:
> "Without it a container holding stock could not be deleted at all (the stock unit's lock read needs a transaction, and UnitLoadController opens none)"

With (a) on `sendStockUnitToNirvana`, the delete works without (b). (b) is what makes it **atomic** and moves the
STOCK_UPDATE to after commit. The second sentence ("a refusal part-way ... already retired") is the real reason for (b). Fix: drop or reword the first sentence.

### [Low] L2: lock order and lock duration
Confidence: MEDIUM
`deleteUnitLoad` takes `FOR UPDATE` on each SU in heap order (:758 → `changeAmount`) and then UPDATEs the unitload row
(:777, via `transferUnitLoadToLocation`'s save). It holds all of them to commit. `deleteUnitLoadRecursive` holds every SU lock in the
whole tree for the full walk. Id-ordered lockers of the same rows, such as `lockPickingCandidates` (by item, in its query's
order), can deadlock against a heap-ordered delete when one container holds two SUs of the same SKU. Postgres resolves the deadlock by aborting
one side, so it shows up as a 500 rather than a hang. The Nirwana location is **not** locked (`ignoreLock=true`), and none of these
activity codes is BLOCK_REALIGN, so no Pickingorder lock is taken. Good. The OMS POST runs in `afterCommit`, after the locks are released. Fix: sort
`stockUnitList` by id before locking (this falls out of the M2 fix).

### [Low] L3: the To-Delete guard reads a detached, controller-time snapshot
Confidence: MEDIUM
`UnitloadService.java:748`: `if (BusinessObjectLockState.isGoingToDelete(unitLoad.getEntityLock()))`. `unitLoad` was loaded by the
controller outside any tx (`open-in-view=false`). For a double-submit, safety now rests only on the Unitload `@Version` check when
`sendToNirvana` merges the stale entity. The second request then ends in `ObjectOptimisticLockingFailureException`, which
`UnitLoadController` does not catch, so the client gets a 409/500 instead of the friendly "already To Delete". Data stays correct: the tx rolls back and no
second STOCK_UPDATE is sent. Fix (optional): re-read and lock the unitload by id at the top of `deleteUnitLoad`.

### [Low] L4: `never().post(anyString(), anyString())` is null-blind
Confidence: HIGH
`DeleteContainerWithStockIT.java:209`, `:232`. `anyString()` does not match null, so a post with a null URL or payload would pass
`never()`. House precedent: `NestedSendAfterCommitIT.java:126-129`
> "any(), NOT anyString(): anyString() does not match null, so a null-blind never()"

Fix: `verify(httpRestService, never()).post(any(), any())`.

### [Low] L5: the recursive rollback test does not assert that the containers were rolled back
Confidence: HIGH
`DeleteContainerWithStockIT.java:224-232` checks SU_A, stockrecords and the POST, but not CHILD_1's `entity_lock`/`labelid`. Fix: add
`labelid = LABEL+"-C1"` and `entity_lock = 0` for CHILD_1, and the parent untouched.

### [Low] L6: the new bulk-delete claim is untested
Confidence: HIGH
`UnitLoadController.java:148-149`:
> "each deleteUnitLoad is its own transaction (SBDEV-3854), so the containers before the refused one stay deleted."

The claim is true by reading the code (the try sits outside the loop, and each proxied call commits). It changes the meaning of a documented contract, but no test pins it.
Fix: optionally add a 2-container bulk IT where #2 is refused, asserting that #1 is retired and notified once.

### [Low] L7: duplicated reservation rule and a user-visible wording change
Confidence: HIGH
`FixLocationAssignmentService.java:274-277` copies the predicate in `sendStockUnitToNirvana:572`
(`BigDecimal.ZERO.compareTo(...getReservedamount()) < 0`). The FLA web endpoint's error changes from the translated
`STOCKUNIT_HAS_RESERVATION` (`getLocalizedMessage`) to new English text. Acceptable, because the guard must sit before the proxy, but note
it in the PR. Optionally extract a non-transactional `StockunitBusinessService.isReserved(su)` so the rule has one home.

### [Low] L8: pre-existing, not introduced. A client-supplied Stockunit drives `sendStockUnitToNirvana`
Confidence: MEDIUM
`CycleCountLosController.java:162` passes `dto.getStockUnit()`, an entity deserialized from the request body, into
`recountSingleUnitLoad`. In `sendStockUnitToNirvana`, both the reservation pre-check (:572) and the `amount > 0` branch (:577) read the
**client's** fields. A body with `amount=0, reservedamount=0` skips `changeAmount`, the only locked re-check, and
retires the real row whatever its amount or reservation. This worked before the change too, so it is pre-existing, and M4 now widens
the reachable set. Data-integrity/authz shaped, so T3: **propose, do not file**. Fix: re-load the SU by id in the controller or
service and ignore client fields.

## Open Questions (low confidence, not blocking)

### [Low] Q1: outbox dispatcher in the IT context vs `never().post`
Confidence: LOW
`app.cron=false` in `application-postgres-integration.properties:194`, but `OutboxDispatcherJob` is
`@Scheduled(cron = "${app.cron.outbox-dispatcher:*/15 * * * * *}")` (:62/:83). I did not confirm that it is gated off in this lane.
If it runs and finds outbox rows left by another IT that shares the context, a POST through the mocked `HttpRestService` during
test 2 or 3 fails `never()` intermittently. Check: grep for the gate, or narrow the verify to `contains("stockUpdate")`.

### [Low] Q2: fixed ids 38540-38548 vs sequence-generated ids in the shared PG IT DB
Confidence: LOW
No other test uses 3854x (I confirmed this with grep). But client, unitload, stockunit and location ids that other ITs generate from a sequence could reach that range in a
long-lived container. That would give a duplicate-key failure or, worse, the client-scoped `deleteResidue` deleting nothing of theirs (which is fine). Check
the sequences' current values in the IT schema, or move the block far above them.

## Nits
- N1: `DeleteContainerWithStockIT.java:140` deletes `stockunit` by client, and the loop at :143 deletes it again. Drop one.
- N2: `StockunitBusinessService.java:558-569`: the new `//` block sits under the legacy `//` pseudo-javadoc (with `{@link}` tags).
  Fold both into one real `/** */` javadoc so IDEs show it.

## Focus (2): behaviour changes for callers that relied on per-statement commits
- **bulkDeleteContainer**: unchanged semantics. Each container is one tx, so earlier containers stay deleted and notified. The comment is accurate (L6).
- **deleteUnitLoadRecursive**: it was never really per-statement for stock: it 500'd. Now the whole tree is all-or-nothing and the single
  STOCK_UPDATE goes after commit. Inside one tx, `sendToNirvana`'s `findByUnitloadId(...).isEmpty()` and `deleteUnitLoad(parent)`'s
  child check rely on Hibernate AUTO flush before the query. IT test 1 proves this for the single path, and test 3 exercises it for children.
- **sendAfterCommit**: deferral is now real on the delete paths (sync → afterCommit), and rollback suppresses it (`afterCompletion`
  logs it). The path is not nested inside an `afterCommit` (SBDEV-3267 rail). The cycle-count paths stay synchronous (M4).
- **FLA via the web controller**: `sendStockUnitToNirvana` now runs in its own tx, and `unitloadBusinessService.sendToNirvana` still runs auto-commit.
  This is no worse than before.

## Positive observations
- The FLA refusal goes **before** the proxy rather than adding `UnexpectedRollbackException` to the job's catch, so it fixes the invariant rather than the symptom.
- Every new `@Transactional` uses the literal tenant manager and `rollbackFor={Business,Facade}`, consistent with `TransactionManagerArchTest`
  and the SBDEV-3242 bare-tx trap.
- The IT runs `NOT_SUPPORTED` at class level, which is the only way to see this defect. Under the base test tx it is invisible. Each annotation has
  a dedicated killing test (test 5 → (a), test 2 → (b), test 3 → recursive, test 4 → FLA guard).
- The B-3 and controller comments were updated in the same change, and the IT records why each fixture exists.

## Recommendation
**COMMENT.** No blocking defect at high confidence. Before the PR, fix M1 (stale comments) and M3 (assume → assert),
and decide M2 and M4 explicitly: fix them in this ticket, or record them on SBDEV-3854 with their blast radius. Address the Lows in the same pass,
as house policy requires. L8 is a T3 proposal for Nam.
