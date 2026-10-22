---
ticket: SBDEV-3854
lane: re-review of the review-fix commits (read-only, no maven, no DB)
reviewed: 54be5a40..daa56ee5 (a2bfe006, daa56ee5), v2/wms2-api
tree: detached worktree at daa56ee5 (scratchpad rev-c), removed after review
date: 2026-10-21
verdict: COMMENT. Nothing High at HIGH confidence. 1 Medium (a sibling of M2, newly reachable), 6 Low, 3 Nit.
---
# SBDEV-3854: review round 2

I judged everything from the code. I did not run anything, so I have not seen the new tests pass. A full suite is running in the ticket worktree.

## 1. Closure of the prior findings

### Code review (review-code.md)
| ID | Status | Evidence |
|---|---|---|
| M1 stale comments | **CLOSED** | `UnitloadService.java:503-506`: the javadoc now says the method was untransactional until SBDEV-3854 and that a throw on child #2 now rolls back child #1. Unit test `:1409-1411` gives the new termination rationale (the walk spins while it holds the stock locks). I grepped the sibling files touched by the change for "no @Transactional / no transaction / auto-commit": every remaining hit is about another method and is still true. |
| M2 OMS delta from an unlocked read | **CLOSED for deleteUnitLoad** | `:766-782`: ids are sorted, each row is taken through `LockReads.forUpdate`, and the DTO, the goods-out guard and the `sendStockUnitToNirvana` call all use the locked row. Unit test `deleteUnitLoad_shouldUseTheLockedRow_*` kills the "use the plain read" mutant: it expects -40 and the same instance. **The sibling is not swept**: see N-M1 below. |
| M3 assumeThat can skip the tests | **CLOSED** | The `assumeThat` calls are gone. Production now sorts by id (`:769`, `:603-606`), so the fixture order is by construction. The two unit `InOrder` tests pin the sort, and the IT's `assertThat(SU_A).isLessThan(SU_B)` documents the precondition. |
| M4 recounts untested and non-atomic | **CLOSED (atomicity) / OPEN (delta source)** | `MobileCycleCountService.java:188-191` and `:398-399` add `@Transactional(tenantTransactionManager, rollbackFor={Business,Facade})`. Two new ITs check that a refused stock change leaves no FINISHED position or state behind. The second half of M4, where the delta comes from the client DTO or an unlocked read, is unchanged: see N-M1. |
| L1 javadoc overstates | **CLOSED** | `:735-739` rewritten. The claim is true: the transaction on `sendStockUnitToNirvana` is what makes the delete possible, and this one is what makes it atomic. |
| L2 lock order | **CLOSED within one container / residual** | Stock units are locked in id order within a container, and children are walked in id order at each level. There is still no global id order across the children of a tree, and the Unitload row is still UPDATEd after the stock locks. See N-L3. |
| L3 To-Delete guard on a detached snapshot | **DEFERRED, accepted with a corrected reason** | Data stays correct (the `@Version` merge fails and the tx rolls back), and the verifier confirmed the client gets a readable 409. The stated reason is weak, though. A lock re-read through `UnitloadRepository.findByIdForUpdate` (`UnitloadRepository.java:38`) or `LockReads` would **not** change the SBDEV-3119 `findById` pins (`UnitloadServiceUnitTest:1393-1394` count `findById` only). The real costs are new strict stubs in every deleteUnitLoad test, plus a unitload-before-stock lock order to decide. Record it on the ticket with that reason, not with the call-count one. |
| L4 null-blind never() | **CLOSED** | `DeleteContainerWithStockIT`: both use `post(any(), any())`. |
| L5 recursive rollback of containers not asserted | **CLOSED** | `entity_lock = 0` is asserted for CHILD_1, CHILD_2 and UL, and SU_A's `entity_lock` too. The labelid is not asserted, but `sendToNirvana` sets both in the same save, so `entity_lock` is enough. |
| L6 bulk claim untested | **DEFERRED, accepted** | The claim is still true by reading (`UnitLoadController`: the try sits outside the loop, and each proxied call commits). It is Low. Mention it in the PR. |
| L7 duplicated reservation rule / English message | **DEFERRED, accepted** | No change. Note the wording change of the FLA endpoint in the PR. |
| L8 client-supplied Stockunit | **DEFERRED → propose as T3, accepted, and the scope has changed** | The container-delete path no longer feeds a client or plain-read entity to `sendStockUnitToNirvana` (it passes the locked row). The only path left is `recountSingleUnitLoad` (`CycleCountLosController:162` → `dto.getStockUnit()`). Its reservation pre-check, its `amount > 0` branch and its OMS delta (`originalAmount`, `:220`) still read the client fields. The proposal should name that path and also cover N-M1. |
| N1 double delete | **CLOSED** | `stockunit` was dropped from the table loop. |
| N2 pseudo-javadoc | **CLOSED** | It is now one `/** */` with `{@link Stockunit}`. |
| Q1 outbox dispatcher vs never() | **OPEN (low)** | `OutboxDispatcherJob:62/:83` is still `@Scheduled` with a default cron. I found no outbox gate in `src/test/resources/*.properties`. The never() assertions are now `any(), any()`, which makes them *wider*, so a stray dispatcher POST through the mocked `HttpRestService` would fail them. It is unconfirmed. If the suite shows intermittent failures in tests 2 and 3, narrow the never() to `contains("stockUpdate")`. |
| Q2 fixed ids vs sequences | **OPEN (low)** | Unchanged. Three new ids (38549-38551) are in the same block. |

### Verifier (review-verifier.md)
| ID | Status | Evidence |
|---|---|---|
| M1 root-cause timeline / AC-1, AC-9 evidence | **OPEN (not code)** | Nothing in this diff addresses it. Do not claim "root cause fully identified" until the PRD log and the deployed-build probe are done. |
| M2 partial state in the cycle-count recounts | **CLOSED** | The same annotations as code M4. `CycleCountLosController` has no `@Transactional`, and its try/catch (`:161-166`, `:285-290`) sits outside the service proxy, so the transaction has rolled back before the catch. Rollback-only poisoning is not possible. |
| L1 AC-7 not run through a real tx for the FLA, 3547 and 3500 cases | **OPEN (low)** | No new IT. They refuse before any mutation, so the risk is low. |
| L2 controller-loaded Unitload, possible 409 | **DEFERRED** | Same as code L3. |
| L3 weak IT assertions | **CLOSED (history) / PARTIAL (payload)** | History: `queryForObject` pins exactly one `MANUAL_REMOVAL`/`STOCK_ALTERED` row at -12, because more than one row throws. Payload: SKU plus activity code. The **amount** (-12) is still not asserted in the OMS body. See N-L5. |
| L4 stale UI comments in wms2-web-ui `container.js` | **OPEN** | Not in this repo's diff. The per-container "deleteUnitLoad is not @Transactional" comment is now false. Fix it in the UI repo, or record it on the ticket. |

## 2. Findings in the new code

### [Medium] N-M1: the recount-to-zero OMS delta is still taken from an unlocked or client read, and this is the M2 sibling, newly reachable
Confidence: MEDIUM
- `MobileCycleCountService.java:400-402,437,456`, `countBySKURecount`: `stockUnit = stockunitRepository.findById(...)` is a plain read inside the new tx. `originalAmount = stockUnit.getAmount()` is captured from it, and `diff = count - originalAmount` goes to OMS (`:466`). `changeAmount` then locks and refreshes the same managed instance and records the stockrecord from the *locked* amount. If a pick commits between `:400` and the lock, OMS gets a delta that differs from the stock record. This is exactly the M2 window.
- `MobileCycleCountService.java:220,240`, `recountSingleUnitLoad`: `originalAmount` comes from the **client DTO**.
- Why it counts as new: the recount-to-zero branch always 500'd before SBDEV-3854, so these deltas reach OMS for the first time. M2 was graded Medium by the same argument, and M2 was fixed only in `deleteUnitLoad`. The non-zero branch was reachable before, so on that branch it is pre-existing.
- Fix (small, no T3 needed for `countBySKURecount`): take the stock unit through `LockReads.forUpdate(entityManager, Stockunit.class, id, stockunitRepository::findByIdForUpdate)` *first*, as `deleteUnitLoad` now does, and compute `originalAmount` from that row. For `recountSingleUnitLoad`, load and lock by `stockUnit.getId()` and ignore the client's fields. That is the L8 fix, so either do it here or put it explicitly in the T3 proposal.

### [Low] N-L1: the plain entity read before the lock makes production take the managed-row path, which no unit test sees
Confidence: HIGH
`UnitloadService.java:768-772`: `findByUnitloadId` loads full entities into the persistence context, so every `LockReads.forUpdate` call takes the **managed** branch: a scalar `SELECT id ... FOR NO KEY UPDATE` plus `refresh(PESSIMISTIC_WRITE)`, which is 2 locking statements per SU on top of the list query. The unit tests have no EntityManager, so they only run the finder branch. IT test 1 is the only coverage of the branch that actually runs in production. The behaviour is correct: the refresh brings the current `unitloadId`, `amount` and `entityLock`. The house precedent for this situation is an ids-only projection, `StockunitRepository.findIdsByUnitloadIdAndItemdataIdOrderById` (SBDEV-3605 Fix A, `:142-148`), with the comment "ids only, so the ... findByIdForUpdate set is the FIRST touch of each scanned SU".
Fix: add `@Query("SELECT s.id FROM Stockunit s WHERE s.unitloadId = :id ORDER BY s.id") List<Long> findIdsByUnitloadIdOrderById(...)` (with `@RestResource(exported=false)`). Then each lock is the first touch, a single statement, and the same path the unit tests pin. The Java sort can go.

### [Low] N-L2: a stock unit deleted while the lock waited surfaces as a 404 "StockUnit not found with id: N"
Confidence: HIGH
`UnitloadService.java:776`: `orElseThrow(() -> new EntityNotFoundException("StockUnit", stockUnitId))`. The transaction does roll back, because a RuntimeException always does. But the operator gets a 404 ProblemDetail naming the surrogate key (the verifier's (b) already calls this ugly). The moved-off case two lines down gets a readable BusinessException in the 200+errors envelope instead. Both are the same race ("the container's stock changed under the delete"). Fix: throw the same `BusinessException` (for example "Stock unit N changed while container X was being deleted ... try again").

### [Low] N-L3: the lock order is id order only within one container
Confidence: MEDIUM
The comment at `:603-605` ("the order is the lock order") is true per level. In a tree delete, though, the SU locks are taken depth-first: child 1's SUs (sorted), then child 2's (sorted), and so on. That is not global id order, and the Unitload rows are UPDATEd after their stock. Another tx that locks the same SUs in global id order can still deadlock against it. Postgres aborts one side, which then 409s per the verifier's (b), so this is a retry, not a hang. Accept it. Just don't read the comment as a global ordering guarantee. Optionally say "per container".

### [Low] N-L4: the two recount ITs do not prove that the position was written before the refusal
Confidence: MEDIUM
`recountSingleUnitLoad_shouldLeaveNoPosition_*` asserts that the count of rows is 0, and `countBySKURecount_shouldLeavePositionUnfinished_*` asserts the state is CREATED. Both outcomes are also what you would see if the method threw *before* `cyclecountPositionRepository.save`. `isInstanceOf(FacadeException.class)` narrows this well: before the save, the method throws only BusinessException or EntityNotFoundException, so the Facade must come from `sendStockUnitToNirvana`, which runs after the save. I judge the tests non-vacuous by that argument. They would become robust to a future refactor if they asserted something that only the save produces, for example a burned position-number sequence value (memory: burned sequence numbers prove a path ran). Also record the mutation check (drop `@Transactional` → red) on the ticket. I could not run it.

### [Low] N-L5: the OMS payload amount is still not asserted
Confidence: HIGH
IT test 1 checks `payload.contains(SKU) && payload.contains(CODE_MANUAL_REMOVAL)`. The -12 that M2 is about is checked on the stockrecord, but not on the wire. Add `&& payload.contains("-12")`, or parse the JSON for the amount field. Verifier L3 is otherwise closed.

### [Low] N-L6: the recount paths' happy path (recount to zero succeeds atomically, OMS after commit) has no IT
Confidence: HIGH
The new ITs cover only the refusal. Now that `sendStockUnitToNirvana` and `unitloadBusinessService.sendToNirvana` both run inside one tx for the first time on this path, `sendToNirvana`'s `findByUnitloadId(...).isEmpty()` relies on the AUTO flush of the SU's move to Nirwana. That is the same reliance `deleteUnitLoad` has, and IT test 1 proves it there, so the risk is low. One IT where `recountSingleUnitLoad(su, 0)` succeeds and the container is retired, with one stockUpdate POST, would pin it.

### Behaviour check (c): the transactional recounts with detached inputs
I found no new dirty-checking write.
- `recountSingleUnitLoad`: `stockUnit` is the client entity and is never managed. Only `changeAmount` and `sendStockUnitToNirvana` touch the row, through the locked or `findById` managed copy.
- `countBySKURecount`: `cycleCountPosition` (detached, from the DTO) is mutated and then `save`d, which is a merge, as before. Nothing in the method mutates the managed copy that the merge returns, or the managed candidates from `findByCyclecountId`, without saving. `cycleCount` is saved explicitly.
- Changes that are real and intended:
  - `changeAmount` (rollbackFor Facade) now joins instead of committing on its own, so a refused non-zero recount no longer leaves a FINISHED position behind. A handheld that retries after an error is unaffected.
  - `messageService.sendStockChangeMessage` now defers to afterCommit, so a rolled-back recount, including a late `"Unknown status"` throw in the candidate loop, no longer notifies OMS.
  - The SU lock is now held until commit.

### Wiring check (b): `@PersistenceContext(unitName = "tenant")` on a constructor-injected @Service
Correct. `PersistenceAnnotationBeanPostProcessor` injects fields independently of constructor injection. The unit name matches `TenantDatabaseConfig:130` (`.persistenceUnit("tenant")`). The idiom is the same as 12 other services, including `StockunitBusinessService:31` and `GoodsReceiptPositionService:27`, which are also constructor-built. In `UnitloadServiceUnitTest`, `@InjectMocks` uses the constructor, so the field stays null and `LockReads` falls back to the finder. The field comment is true.

### Test-quality check (d)
- `deleteUnitLoad_shouldProcessStockUnitsInIdOrder_*`: the finder returns [2, 1]. `InOrder` over `stockunitRepository` and `stockunitBusinessService` kills both the "no sort" mutant and the "lock sorted, retire in finder order" mutant. Correct.
- `deleteUnitLoadRecursive_shouldDeleteChildrenInIdOrder_*`: the finder returns [3, 2], then empty for the parent's own child check. The `InOrder` on `sendToNirvana(same(..))` kills the mutant that removes the sort. With STRICT_STUBS, every stub must be used. Correct.
- `deleteUnitLoad_shouldRefuse_whenAStockUnitWasMovedOffMeanwhile`: `verifyNoInteractions` on both business services proves the refusal comes before any mutation. Correct.
- SBDEV-3547 `setId(0L)`: the unlocked unit (id 0) still sorts before the goods-out unit (id 1), so "a check placed inside the loop after the first send" is still caught. The intent is preserved. The added `findByIdForUpdate(0L)` stub is needed under strict stubs.
- The `setUp` stub `lenient().when(findByIdForUpdate(1L))` is shared, and tests that need another row override it. It is fine, but because it is lenient, a test that silently uses the wrong row would not be flagged. Nit.

## 3. Comment-claim audit (e)
| Claim | True? |
|---|---|
| `UnitloadService:52` "Null in constructor-built unit tests, where LockReads uses the finder" | Yes |
| `:503-506` recursive javadoc | Yes |
| `:603-605` "the order is the lock order" | Per container. See N-L3 |
| `:735-739` deleteUnitLoad javadoc | Yes |
| `:766-770` "lock each stock unit, in id order, **before anything reads it**" | **Slightly false.** The plain `findByUnitloadId` reads and loads the rows first. What is true is that nothing *uses* them before the lock. Nit, and it goes away with the N-L1 fix |
| `:770` "As in GoodsReceiptPositionService.lockStockUnitOnItsUnitLoad (SBDEV-3729)" | Yes. The same lock and the same moved-off shape (`:211-219` there), except that the precedent has no prior plain read |
| `:784-785` "Since SBDEV-3854 it reads the locked rows, and a refusal also releases those locks" | Yes (rollback releases the locks) |
| Moved-off message "Nothing was deleted; try again." | True for this container and for a recursive tree. In a **bulk** delete the containers before it stay deleted (L6). Nit: say "This container was not deleted" |
| `StockunitBusinessService` javadoc ("until SBDEV-3854") | Yes |
| `MobileCycleCountService:188-190` "The position is saved FINISHED before the stock is changed ..." | Yes (`:226` save, then `:231-236`) |
| `TestClassTransactionManagerArchTest` "ids 38540-38552" | **Off by one.** The highest id is 38551 (`CYCLECOUNT_POSITION`). Nit |
| IT `runAsUser` javadoc "the controller runs them as the caller" | Yes (`SecurityContextUtils.getUserName` takes a String principal) |

## Nits
- Nit 1: the "before anything reads it" wording (above).
- Nit 2: the 38552 range in the arch-test allow-list comment.
- Nit 3: `final Long unitLoadId` sits under the SBDEV-3500 To-Delete comment block (`:755`), which it does not belong to. Move it after the guard or above the comment.

## Positive observations
- M2 was fixed the house way (`LockReads`, moved-off refusal, id order). It is pinned by a unit test that changes the amount between the read and the lock, and that test kills the mutant.
- M3 was closed at the root: production order is now deterministic, so the test precondition holds by construction rather than by assumption.
- The cycle-count annotations are poison-safe. The controller catches outside the proxy, and no in-method catch swallows a joined-tx exception.
- The new ITs use detached inputs (`findById` outside any tx, a jdbc-seeded position), which matches how the mobile DTO arrives.

## Recommendation
**COMMENT.** Nothing blocks at HIGH confidence. Before the PR, fix N-M1 for `countBySKURecount` (lock first, then take the delta), or fold it explicitly into the L8 T3 proposal together with `recountSingleUnitLoad`. Correct the L3 deferral reason. Take N-L1 (the ids-only projection) and N-L2 (BusinessException instead of a 404) in the same pass, per the house rule on Lows.
