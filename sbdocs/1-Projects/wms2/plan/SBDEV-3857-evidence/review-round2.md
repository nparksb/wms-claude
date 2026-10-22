# SBDEV-3857 — round-2 review of the review-fix commit 75918f67 (code-reviewer lane)

- Scope: `git show 75918f67`, run in `.claude/worktrees/wms2-api/SBDEV-3857`. The commit already contains the `onPostedContainer` Optional.get fix. Three files: `MobileCycleCountService.java`, `CycleCountJudgesTheDatabaseRowIT.java`, `MobileCycleCountServiceUnitTest.java`.
- Read-only. **Nothing was built or run**, because the full suite is running in this worktree. No LSP, for the same reason. `git diff --check origin/develop...HEAD` is clean.
- Also read: `LockReads` (all of it), `UnitloadService` (EntityManager wiring), `CyclecountService`/`CyclecountPositionService` (writer census), `OptionalSafetyArchTest` (freeze semantics), `StockChangeDto`, origin/develop's `countCycleCountStockUnit`, and the IT fixture.

## Verdict: **APPROVE**
No Critical or High. Every round-1 item is addressed. Three new Low findings follow; fix them in the same pass, per the standing rule.

---

## Round-1 findings: status

| # | Status | Evidence |
|---|---|---|
| M-1 | **FIXED** | The IT now uses `isInstanceOfSatisfying(FacadeException.class, e -> assertThat(e.getKey()).isEqualTo("STOCKUNIT_HAS_RESERVATION"))`. The key exists at `StockunitBusinessService.java:575/623`, and `FacadeException.getKey()` at `FacadeException.java:75`. |
| M-2 | **FIXED** (option b, plus a comment) | `countCycleCountStockUnit` (`MobileCycleCountService.java:412-413`) now goes through `lockStockUnitOf` (`:314-320`): `LockReads.forUpdate`, then `entityManager.refresh(position)`, then `requireOpen`. That is the same helper `countBySKURecount` uses (`:485-486`). The javadoc at `:307-312` names the web cancel (`CyclecountService`) as the one unfenced writer, and says it fails on the version and rolls back whole. |
| L-1 | **FIXED** | The three duplicate `setUnitloadId(1L)` lines are removed. An awk scan of the file finds no adjacent duplicate left. |
| L-2 | **FIXED** (guard dropped) | `if (entityManager != null)` is gone. The field comment at `:69` is updated. The unit test declares `@Mock EntityManager` and injects it in `setUp` through `ReflectionTestUtils` (`@InjectMocks` uses constructor injection, so it skips the field). |
| L-3 | **FIXED** | `EntityManager`, `InOrder` and `ReflectionTestUtils` are imported. A grep finds no inline FQN of the three left in a test body. |
| L-4 | **FIXED** | `onPostedContainer` (`:280-282`) first throws `"No stock unit given"` for a null id. Pinned by `recountSingleUnitLoad_shouldRefuse_whenThePostedStockUnitHasNoId` (exact `hasMessage`). |
| L-5 | **FIXED** | Three pins, mutation-reasoned below: zero delta (`recountSingleUnitLoad_shouldSendNothingToOms_whenTheCountEqualsTheLockedAmount`), null position id (`countBySKURecount_shouldRefuse_whenThePostedPositionHasNoId`), position not found (`countCycleCountStockUnit_shouldRefuse_whenThePositionDoesNotExist`). |
| L-6 | **PARTIALLY FIXED** | `findById(5L)` in the stale-read happy path is now a strict `when`. Still lenient: `recountCollaborators`, which is a shared helper, so that is defensible; and `findByIdForUpdate(10L)` in the two FINISHED-refusal tests (`:1889`, `:1940`), which the post-fix path now **must** hit. See N-1. |
| L-7 | **FIXED-DIFFERENTLY** | Round 1 asked for a FINISHED-refusal IT. The commit adds a happy-path first-count IT on PostgreSQL instead (`countCycleCountStockUnit_shouldFinishTheStoredPosition_whenTheBodyNamesAnotherStockUnit`). That IT exercises the real-Hibernate `refresh` and the real `findByIdForUpdate`. M2's rollback-on-refusal is still not pinned on PG, but the FINISHED refusal now fires before any write, so nothing exists to roll back on that path. Acceptable. |

---

## Scrutiny items

**(1) The lock in `countCycleCountStockUnit`: no new deadlock shape. The refresh is safe.**
- Lock order on the new path:
  - SU row (`FOR NO KEY UPDATE`, through the finder path: the SU is not managed yet, since `openPosition` loads only the position);
  - then the `cyclecount_position` row (UPDATE at the auto-flush before `findByCyclecountId`);
  - then, possibly, the `cyclecount` row (UPDATE).
- No other writer takes a position or cycle-count row lock and then waits on a stock unit. Census:
  - `CyclecountService` (create `:97-128`, cancel `:158-170`) writes positions and cycle counts. It takes no SU lock, only a plain `getStockUnitsBySkuSetAndAreaSetAndStates` read.
  - `CyclecountPositionService.createEntity` INSERTs only.
  - The two by-SKU mobile paths both lock the SU first.
- Two first counts of different positions in one cycle count each hold a different SU. Only one of them can go on to update `cyclecount`, so no cycle forms.
- SU-locking paths elsewhere (picking, move, the single-UL recount) never lock a cycle-count row. So the only new edge is SU → position → cyclecount, and it does not close a cycle.
- Holding one SU lock on the mismatch path (returns `null`) is a throughput cost only.
- Refresh safety:
  - `openPosition` loads the position by `findById` as its first touch in the method's transaction, so it is MANAGED.
  - Nothing is set on it before `entityManager.refresh(position)` (`:317`), so no pending change is discarded.
  - The refresh has no lock mode, so there is no version-checked upgrade (the LockReads trap does not apply).
  - The SU finder is a JPQL query on `Stockunit`; it auto-flushes only that table, which is clean here.

**(2) `openPosition` no longer checks state: both callers still refuse before writing anything.**
- `git grep openPosition` finds two callers. Each calls `lockStockUnitOf` on the very next line: `:412-413` and `:485-486`.
- `requireOpen` is reached only through `lockStockUnitOf`.
- Neither path writes anything before that call. The first count's position save (`:448`) and its cycle-count FINISHED save (`:465-466`) both come after it. So does the recount's position save and the stock change.
- Pinned by `countCycleCountStockUnit_shouldRefuse_whenTheStoredPositionIsFinished`, which asserts `never().save` on both `cyclecountPositionRepository` and `cyclecountRepository`.

**(3) Removing the guard is safe.**
- `@PersistenceContext(unitName = "tenant")` on a field of a constructor-injected `@Service` is the same pattern as `UnitloadService.java:53-54`. `PersistenceAnnotationBeanPostProcessor` injects it after construction.
- `recountSingleUnitLoad` already relied on that field in round 1. If the field were ever null, the code would now NPE, so it fails closed.
- `git grep` under `src/test`:
  - `new MobileCycleCountService` has no hits.
  - The only `@InjectMocks MobileCycleCountService` is `MobileCycleCountServiceUnitTest`, which now injects the mock.
  - `CycleCountLosControllerUnitTest` `@Mock`s the service.
  - `CycleCountJudgesTheDatabaseRowIT` and `DeleteContainerWithStockIT` `@Autowired` it.
- No other test can NPE.

**(4) New and edited unit tests: none vacuous. The mock EntityManager does take the finder path.**
- `LockReads.forUpdate` computes `session = entityManager.unwrap(SessionImplementor.class)`. A Mockito mock returns `null`, so the method returns `lockingFinder.apply(id)`, i.e. `findByIdForUpdate`. The comment in the test is accurate.
- Mutation reasoning (none of it run):
  - Zero delta: deleting `if (diff != 0)` makes the code call `sendStockChangeMessage` (the mocks return null, which `list.add` accepts), so `verifyNoInteractions(messageService)` goes red. Computing the delta from the posted amount (3) gives 9, which is also red.
  - Null SU id: dropping the new check gives `"Stock unit null was moved…"`, so the exact `hasMessage` goes red.
  - Null position id: dropping the check calls `findById(null)`. The mock returns `Optional.empty()`, which throws `"Cycle count position null not found"`, so `hasMessage` goes red.
  - Not found: the exact message is pinned.
- First-count SU lock: the existing first-count tests are switched to a strict `findByIdForUpdate(1L)`. A revert to `findById` makes the SU lookup return `Optional.empty()`, which throws `EntityNotFoundException`, so they go red. That also trips STRICT_STUBS.
- The archunit freeze store still lists `MobileCycleCountService` `Optional.get()` sites at old line numbers. Per `OptionalSafetyArchTest`'s own javadoc, the matcher ignores line numbers. The remaining `.get()` calls are at `:121` (`scanSingleUnitLoad`) and `:399/:400` (`readCycleCountPositionByScannedUL`), and both methods are already frozen, so no new violation arises.

**(5) The new IT fails on origin/develop for the right reason.**
- origin/develop's `countCycleCountStockUnit` reads `stockunitRepository.findById(cycleCountPosition.getStockunitId())` from the posted copy. That resolves to `SU_OTHER`, which has amount 4 in the fixture.
- Count 12 ≠ 4, so develop returns `null`, and the first assertion (`isNotNull`, "12 matches the stored stock unit, not the body's (4)") goes red.
- Even if develop had matched, it would have saved the posted copy with `stockunit_id = SU_OTHER`, and the `stockunit_id` assertion would catch that.
- On the round-1 code (5ac73663) the IT is green. It pins the 5ac73663 fix on PG; it does not discriminate 75918f67.

---

## New findings

### [LOW] N-1: The FINISHED-refusal tests keep `lenient()` on the lock the post-fix path now must take
- **File:** `MobileCycleCountServiceUnitTest.java:1889` (`countBySKURecount` FINISHED) and `:1940` (`countCycleCountStockUnit_shouldRefuse_whenTheStoredPositionIsFinished`)
- **Confidence:** HIGH
- **Issue:**
  - The state is now checked only after `lockStockUnitOf`, so `findByIdForUpdate(10L)` is on the post-fix path. Being lenient, it hides a regression that checks the state before, or without, the lock. This is the L-6 residue.
  - Separately, the `findByIdForUpdate → refresh` order is pinned only for `countBySKURecount` (the InOrder test at `:1927-1929`). A call-site mutant in `countCycleCountStockUnit` that inlines `findByIdForUpdate` plus `requireOpen` and drops the refresh stays green in the unit lane.
- **Fix:**
  - Make `:1889`/`:1940` strict `when`.
  - In `countCycleCountStockUnit_shouldRefuse_whenTheStoredPositionIsFinished`, add `InOrder inOrder = inOrder(stockunitRepository, entityManager); inOrder.verify(stockunitRepository).findByIdForUpdate(10L); inOrder.verify(entityManager).refresh(any());`, or clone the `doAnswer`-refresh test for the first count.

### [LOW] N-2: A missing stock unit now outranks a closed position, giving a 500 instead of a clean refusal
- **File:** `MobileCycleCountService.java:315-318`
- **Confidence:** LOW
- **Issue:**
  - In round 1, `openPosition` refused a FINISHED/CANCELLED position with a `BusinessException`, which the controller catches, before any SU lookup.
  - Now the SU is locked first, and a missing SU throws `EntityNotFoundException` (a RuntimeException, uncaught by `CycleCountLosController`, so a 500) before `requireOpen`.
  - `git grep` finds no hard delete of `stockunit` in `src/main`, so this is probably unreachable, which is why the confidence is LOW.
- **Fix:** None needed unless SUs can be deleted, for example through an exported SDR repository. If they can, check the state from the `openPosition` read first as a fast refusal, and keep the under-lock re-check.

### [LOW] N-3: The javadoc does not say what the residual web-cancel race looks like to the operator
- **File:** `MobileCycleCountService.java:307-312`
- **Confidence:** MEDIUM
- **Issue:** "fails this count on the version, rolling it back whole" is accurate. The surface is `ObjectOptimisticLockingFailureException`, which `CycleCountLosController` does not catch (`:163-165`, `:287-289` catch only Business/Facade), so the operator sees a 500. A maintainer reading this comment would not know that.
- **Fix:** Append "(an uncaught `ObjectOptimisticLockingFailureException`: a 500, nothing written)". Keep it as a known residual in the PR body, next to L-8.

### Open questions (low confidence, not blocking)
- The payload anchor `"\"normal\":-4,"` assumes Jackson puts `normal` before another field. `StockChangeDto` declares `damaged` right after `normal` (`:15-16`), so it should hold. The running suite will confirm it.

## Positive observations
- `lockStockUnitOf` gives a single place for "lock the SU, refresh the position, check the state", so the two by-SKU writers cannot drift apart. The javadoc now states its exact fence and its one hole.
- The Optional.get fix keeps the logic the same and satisfies `OptionalSafetyArchTest` without a refreeze.
- Removing the test-only null guard moves the test double into the test, and production now fails closed.
- The new IT uses a body that names a different stock unit with a different amount (4 vs 12), so develop fails it on the very first assertion rather than incidentally.

## Recommendation
**APPROVE.** M-1, M-2 and L-1 to L-5 are fixed. L-6 is partially fixed (N-1). L-7 is fixed differently, and that is acceptable. N-1 to N-3 are Low; per Nam's standing rule, fix them in the same pass. N-3's residual also goes into the PR body.
