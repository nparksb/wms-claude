# SBDEV-3857 — independent code review (code-reviewer lane)

- Branch `fix/SBDEV-3857-recount-locks-db-stock-unit` in `.claude/worktrees/wms2-api/SBDEV-3857`. Reviewed `git diff origin/develop...HEAD`: 3ebf76d0, 5ac73663, 84094313. Four files, +748/−26.
- Read-only. **Nothing was built or run.** No Maven run, because the full suite is running in this worktree. No LSP diagnostics, because jdtls would import or build the same tree. `git diff --check` is clean.
- Also read: `CycleCountLosController` (all four handlers), `LockReads`, `StockunitBusinessService.sendStockUnitToNirvana`/`changeAmount`, `CyclecountPositionService.createEntity`, `UnitloadService.deleteUnitLoad` (the SBDEV-3854 precedent), `architect-consult.md`, and wms2-mobile-ui @39c30b0 (`store/cycleCount.js`, `components/cycleCount/{single,bySku}/{count,recount}UnitLoad.vue`).
- I did not read `review-verifier.md`, so that this lane stays independent.

## Verdict: **APPROVE** (no High; two Medium, nine Low; fix them in the same pass, per the standing rule)

---

## Stage 1: spec compliance
The fix covers each part of the brief and each architect item M1–M5:
- The DB row is locked and judged in `recountSingleUnitLoad`. It is refused unless it is on the posted container (`onPostedContainer`).
- Stored positions are re-read and FINISHED/CANCELLED ones refused (`openPosition`/`requireOpen`). This applies in both SKU paths.
- In `countBySKURecount` the position state is re-checked after the SU lock (M1).
- `@Transactional` is added to `countSingleUnitLoad` and `countCycleCountStockUnit` (M2).
- `originalAmount` and `itemdataId` are snapshotted before the stock call (M3).
- `createEntity` receives the DB row (M4). It is now reached through `stockUnit` in both single-UL methods.
- `recountSingleUnitLoad` gets a `diff != 0` guard.
- M5 (UI) is correctly left as a proposal.

**Legitimate mobile flows: none are newly refused.** I traced each payload:
- Single count posts `stockUnit: this.stockUnitInfo.stockUnit` (`single/countUnitLoad.vue:53`). That object is the server-serialized entity from `scanSingleUnitLoad`. `Stockunit.id` and `unitloadId` carry no `@JsonIgnore`, so both are always present.
- Single recount posts `stockUnitInfo.stockUnit` (`single/recountUnitLoad.vue:56`). After a mismatch that is `result.stockUnit`, which is now the DB row returned by `countSingleUnitLoad`, so it is also complete.
- By-SKU count and recount post `unitLoadInfo.cycleCountPosition` (`bySku/countUnitLoad.vue:51`) and `countData.cyclecountPosition` (`bySku/recountUnitLoad.vue:49`). Both are the entity from `processScanUnitLoad`, so `id` is present.
- A mismatched first count returns `null` without saving (`MobileCycleCountService.java:459-460`). The position stays CREATED, so the recount passes `requireOpen`.
- The only new refusals are real state changes between scan and count: the stock moved, the stock was retired, or the position was finished or cancelled. Refusing those is the intended behaviour.

## Stage 2: brief items (1)–(8)

**(2) Transaction semantics: sound.**
- None of the four methods catches an exception internally. The inner `@Transactional` callees (`sendStockUnitToNirvana`, `changeAmount`) throw straight through. So there is no `UnexpectedRollbackException` path: the outer transaction rolls back on the same Business/Facade exception that the controller then catches.
- `EntityNotFoundException` (runtime) still escapes the controller as a 500. That was already true and is unchanged.
- The returned managed `Stockunit`/`CyclecountPosition` is serialized after commit. Both are plain-column entities (`AbstractBaseEntity`, no associations, nothing lazy), so detached serialization is safe.
- The single-count mismatch path never dirties the returned row, so nothing is flushed from it.

**(3) `entityManager.refresh(position)`: correct.**
- `openPosition` loads the position with `findById` inside the method's transaction, and it is the row's first touch, so the entity is MANAGED when `refresh` runs.
- Nothing is set on it between `openPosition` (`:471`) and `refresh` (`:475`), so the refresh discards no pending change.
- Refresh with no lock mode goes through `DefaultRefreshEventListener`, which removes the entry and reloads it. No version check is involved, so this is not the lock-upgrade trap that `LockReads` documents.

**(4) Visibility under READ COMMITTED: correct for recount-vs-recount.**
- The refresh issues a new statement after the SU lock is granted, and under RC each statement takes a fresh snapshot. It therefore sees the winner's FINISHED, because the winner commits before it releases the SU lock.
- The earlier plain `findById` pins nothing: it took no row lock, RC keeps no transaction-wide snapshot, and the L1 entry is replaced by the refresh.
- Limits: see **M-2**.

**(5) Edited pre-existing tests: no assertion was weakened.**
- Every edit to an existing test is one of two kinds: an added stub that returns the same instance as the posted one (`findById`/`findByIdForUpdate` → `Optional.of(stockunit|position)`), or `findById` → `findByIdForUpdate` on the SU in the `countBySKURecount` tests.
- No `assert*`/`verify` line was removed or loosened.
- One cosmetic leftover: see **L-1**.

**(6) Quality of the new tests: mostly discriminating.**
- I checked each new unit test against the pre-fix code, and each one would be red there:
  - posted 6 = count 6 vs DB 12 → mismatch
  - delta −7 vs −5 from the stale plain read
  - `same(dbRow)` passed to `sendStockUnitToNirvana`/`createEntity`
  - `save(same(stored))` vs the posted copy
  - InOrder `findByIdForUpdate` → `refresh`
- The ITs discriminate too. The stale-body test expects `normal:-4` and `amountbefore=12`; the pre-fix delta was +8. The other-container test expects untouched rows. The FINISHED-position test expects a refusal.
- Weak spots: **M-1**, **L-5**, **L-6**, **L-7**.

**(7) Wording and comments.**
- The refusal message reuses the SBDEV-3854 prefix verbatim: `"Stock unit <id> was moved or removed from container <label>"`. Good.
- The new `LOG.debug` labels are name-free and carry no other method's name.
- Comment density matches the SBDEV-3854 blocks around it. One wording issue: see **L-4**.

**(8) Sibling sweep.**
- Within `MobileCycleCountService`/`CycleCountLosController`, all four body-entity entry points are now covered. `scanSingleUnitLoad`/`processScanUnitLoad` are read-only.
- No other caller of the four service methods exists in `src/main`.
- Outside this class the same trust-the-body shape exists in picking: see **L-10**.

---

## Findings

### [MEDIUM] M-1: The AC-3 IT passes on any `FacadeException`, not specifically on the reservation refusal
- **File:** `src/test/java/net/aim_ai/wms/integration/service/CycleCountJudgesTheDatabaseRowIT.java`, `recountSingleUnitLoad_shouldRefuse_whenTheBodyHidesTheReservation`
- **Confidence:** HIGH
- **Snippet:** `})).isInstanceOf(FacadeException.class);`
- **Issue:** This is the test for the DEV incident itself. Post-fix, any `FacadeException` passes it. That includes a failure unrelated to the reservation, for example in the Nirwana unit-load lookup, or in `unitloadBusinessService.sendToNirvana` if the IT DB lacks a seeded Nirwana container. `assertUntouched()` would still be green, because the transaction rolls back either way. Memory rule *BusinessException key-vs-message traps: assert getKey()*.
- **Fix:** `.isInstanceOfSatisfying(FacadeException.class, e -> assertThat(e.getKey()).isEqualTo("STOCKUNIT_HAS_RESERVATION"))`. The key comes from `StockunitBusinessService.java:575`.

### [MEDIUM] M-2: The M1 re-check is sound only against writers that take the SU lock, and its comment overclaims
- **File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileCycleCountService.java:468-477`
- **Confidence:** MEDIUM. I am confident in the mechanism; real-world frequency is likely low.
- **Snippet:** `// ... a concurrent recount of the same position has committed by then, and is refused here instead of failing on the position's version at flush.`
- **Issue:** The refresh-after-lock only orders this recount against writers that also lock the stock unit first. Two other writers of the same position do not:
  - `countCycleCountStockUnit` (`:390-461`) finishes the position with a plain `findById` of the SU and no lock.
  - The web UI's cancel (`CyclecountService:157`, CANCELLED) takes no SU lock either.

  If either commits after this recount's refresh, this recount still saves over a moved `@Version`. That surfaces as `ObjectOptimisticLockingFailureException`, which `CycleCountLosController.recountUnitLoad` (`:285-291`) does not catch, so it becomes a 500. Nothing is corrupted, because the version check fails closed. The comment says "a concurrent recount", which is accurate, but a reader will take it to mean the position is safe against every concurrent writer.
- **Fix (pick one):**
  - (a) Narrow the comment to "a concurrent *recount* (which takes this same stock-unit lock first)", and state that the first count and the web cancel can still lose on the version (500, nothing written).
  - (b) Take the SU lock in `countCycleCountStockUnit` too, through the same `LockReads.forUpdate`, so every mobile writer of a position shares one lock order. That is one line, and the method is now transactional anyway.

  The web cancel stays outside either fix. Record it as a known residual.

### [LOW] L-1: A duplicated setter was left behind by the stub insertion in three edited tests
- **File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileCycleCountServiceUnitTest.java:275/277`, `:298/300`, `:335/337`
- **Confidence:** HIGH
- **Snippet:**
  ```java
  stockunit.setUnitloadId(1L);
  when(stockunitRepository.findById(1L)).thenReturn(Optional.of(stockunit));
  stockunit.setUnitloadId(1L);
  ```
- **Fix:** Delete the second `setUnitloadId(1L)` in each of the three places.

### [LOW] L-2: A test-double branch sits in production code
- **File:** `MobileCycleCountService.java:474-476`
- **Confidence:** MEDIUM
- **Snippet:** `if (entityManager != null) { entityManager.refresh(cycleCountPosition); }`
- **Issue:** The null guard exists only for constructor-built unit tests. If the EntityManager were ever mis-wired in production, the M1 re-check would be skipped silently instead of failing. `LockReads`' own null fallback has the same rationale but documents it in `LockReads`. Here the field comment (`:69-71`) explains the fallback for `LockReads` only, not for this refresh.
- **Fix:** Either extend the field comment to name this second use ("…and the under-lock position refresh is skipped"), or drop the guard and have the `@InjectMocks` setup inject a mock EntityManager. The refresh test already does that with `ReflectionTestUtils`.

### [LOW] L-3: Fully-qualified names inline in the refresh test
- **File:** `MobileCycleCountServiceUnitTest.java`, `countBySKURecount_shouldRefuse_whenTheStoredPositionIsFinishedWhileTheLockWaits`
- **Confidence:** HIGH
- **Snippet:** `jakarta.persistence.EntityManager entityManager = mock(jakarta.persistence.EntityManager.class); org.springframework.test.util.ReflectionTestUtils.setField(...); org.mockito.InOrder inOrder = ...`
- **Fix:** Import `EntityManager`, `ReflectionTestUtils` and `InOrder`, as the rest of the class does.

### [LOW] L-4: The refusal message for a posted stock unit with a null id reads "Stock unit null was moved…"
- **File:** `MobileCycleCountService.java:280-286`, reached from `:158-159` and `:211-212` when `postedStockUnit.getId() == null`
- **Confidence:** HIGH
- **Snippet:** `throw new BusinessException("Stock unit " + postedStockUnit.getId() + " was moved or removed from container " + label + "; scan the container again.");`
- **Fix:** Mirror `openPosition`'s `"No cycle count position given"`: refuse a null id first with `"No stock unit given"`. (A null body `stockUnit` NPEs in the controller's log line before this point anyway.)

### [LOW] L-5: Three new branches have no pin (a mutation would survive)
- **Files:** `MobileCycleCountService.java:262` (`if (diff != 0)` in `recountSingleUnitLoad`) and `:296-300` (`openPosition`'s null-id and not-found refusals)
- **Confidence:** HIGH
- **Issue:** No test has `recountSingleUnitLoad` with DB amount == count asserting `verify(messageService, never()).sendStockChangeMessage(any())`. The only `never()` on that call is in a `countBySKURecount` test (`:1635`). Deleting the guard, or either `openPosition` check, stays green. The five-item floor asks for a mutation check on every new behaviour.
- **Fix:** Add three small tests to `JudgedOnTheDatabaseRow`:
  - DB 12, posted 0, count 12 → no OMS message;
  - posted position with null id → "No cycle count position given";
  - `findById` empty → "not found".

### [LOW] L-6: `lenient()` hides unused stubs on happy paths
- **File:** `MobileCycleCountServiceUnitTest.java`: `recountCollaborators` (all seven stubs lenient), and `lenient().when(cyclecountPositionRepository.findById(5L))` in `countBySKURecount_shouldSendTheDeltaFromTheLockedRow_whenThePlainReadIsStale`
- **Confidence:** MEDIUM
- **Issue:** In the refusal tests, lenient stubs are justified: they let a pre-fix run reach the assertion instead of NPE-ing. In the happy-path tests, the stubs are required on the post-fix path. Making them lenient means that if the code stops calling them (for example, `findById(5L)` replaced by something else), STRICT_STUBS will not report it.
- **Fix:** Use plain `when` for stubs the post-fix path must hit. Keep `lenient()` only for stubs that exist so the pre-fix path can run, and add a one-line comment saying so.

### [LOW] L-7: The IT does not cover the two newly transactional methods or the real-Hibernate refresh
- **File:** `CycleCountJudgesTheDatabaseRowIT.java`
- **Confidence:** HIGH
- **Issue:**
  - Nothing exercises `countSingleUnitLoad`/`countCycleCountStockUnit` against PostgreSQL, so M2's rollback (no CREATED ADJUSTMENT orphan, no FINISHED-positions/unfinished-order split) is unpinned.
  - M1's `refresh` is proven only against a mocked EntityManager.
- **Fix:** Optional. One IT that has `countCycleCountStockUnit` refuse a FINISHED position, asserting the `cyclecount_position` row count. If concurrency fixtures are cheap here, a two-thread recount IT; see the *Concurrency-IT fixture traps* memory first.

### [LOW] L-8: The implicit optimistic check against the scan-time snapshot is gone
- **File:** `MobileCycleCountService.java:395`, `:471`
- **Confidence:** MEDIUM
- **Issue:** Before, saving the posted position merged it with its scan-time `@Version`, so any web-side change to the position after the scan failed the count. Accidental, but real. Now only `state` is compared. A web edit to other fields of an open position between scan and count is silently counted against. This is intended (the architect's (b)), but it is a semantic change.
- **Fix:** None required. Mention it in the PR body.

### [LOW] L-9 (propose, UI): stale-screen success toast (architect M5) is now more reachable
- **File:** `wms2-mobile-ui/store/cycleCount.js:238-248`
- **Confidence:** HIGH
- **Snippet:** `if (data.count === data.stockUnit.amount) { const result = await this.$axios.$post('/cycleCountLos/countSingleUnitLoad', data) ... this.$toast.success(result.message)`
- **Issue:** Now that the server judges the DB amount, a mismatch on this branch returns `stockUnit` plus "Amount X differs expected. Count again!". The UI shows that as a success toast and resets. Nothing is recorded, but the operator is told the count succeeded.
- **Fix:** Branch on `result.stockUnit` as `countSingleUnitLoad` does at `:218-222`. This is a separate UI ticket (T1). Propose it; do not file it.

### [LOW] L-10 (propose, sibling, out of this diff): picking endpoints trust posted `PickingorderPosition` FKs
- **Files:** `controller/mobile/PickingController.java:129-213` (`PickingInfoDto.pickingorderPosition` from the body); `service/mobile/MobilePickingService.java:1523-1531` (`resetPickingOrder`) and `:1388` (`rapidPickingScanSource`)
- **Confidence:** MEDIUM. I did not trace them end to end.
- **Snippets:**
  - `pickingorderRepository.findById(pickingPosition.getPickingorderId())` → `pickingOrder.setPickinginprogress(false); pickingOrder.setLockedtooperator(false);`
  - `pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())`
- **Issue:** This is the same class of defect as SBDEV-3857: the FKs are taken from a request-body entity instead of from the stored position. `resetPickingOrder` can release the operator lock on whichever picking order the body names.
- **Fix:** Re-read the stored `PickingorderPosition` by id and use its FKs. Its blast radius is the picking subsystem, which may make it T2/T3, so propose it with that note rather than adding it to this ticket.

---

## Open questions (low-confidence; not blocking)
- None at High/Critical. M-2's 500 path needs a real interleaving to confirm. I did not run one.

## Positive observations
- The `onPostedContainer` refusal is the 3854 shape (`Objects.equals` on the locked row's `unitloadId`), down to the message prefix. It also turns a double-submitted recount-to-zero into a clean refusal (the row is in Nirwana by then), with no extra code.
- The locked row is the one instance handed to `createEntity`, `sendStockUnitToNirvana` and `changeAmount`. So the audit row, the retirement guard and the delta all read the same state, and the M3 snapshot is taken before the in-place refresh mutates it.
- `LockReads.forUpdate` is used rather than `findByIdForUpdate` plus `refresh`, so a future plain read earlier in the method cannot reintroduce the lock-upgrade `StaleObjectStateException`.
- The IT runs `NOT_SUPPORTED` (the controller's real shape) and is registered in `TestClassTransactionManagerArchTest`, with a class-unique id block. It checks OMS payloads and stock records together, which is exactly what AC-4 needs.
- The new unit tests use distinct posted and DB values (6 vs 12, 0/0 vs 12/5, stockunitId 99 vs 10), so a test cannot pass by accident on equal fixtures.

## Recommendation
**APPROVE.** There is no High or Critical finding. Fix M-1 (one line) and settle M-2 by comment or lock before the PR. Per Nam's rule, L-1 to L-7 go in the same pass. L-8 goes in the PR body. L-9 and L-10 are proposals.
