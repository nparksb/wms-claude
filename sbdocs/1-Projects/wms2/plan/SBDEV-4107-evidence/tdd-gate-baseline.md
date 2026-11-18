# SBDEV-4107 — TDD gate baseline (2026-11-11)

Lane: gate-4107 (executor, opus). Saved by the parent session (subagents cannot write report files here).
**Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-4107`, branch `feature/SBDEV-4107-concurrent-assignment-races` at `df30fa62`, uncommitted, test files only. `git status --short -- src/main` returns 0 lines (parent-verified).

## Result
- **IT lane:** 30 tests run, 13 failures, 0 errors. All 13 failures are new SBDEV-4107 tests. The 17 passes are the harness controls (12 + 4), IT 6b (green by design), and the 6 arch tests on surefire. Quotes below are from `target/failsafe-reports`.
- **Unit lane:** 202 tests, 6 failures, all intended.
- **Harness default mode unchanged:** GoodsReceiptPositionAdjustIT 4/4 and BusinessServiceLockRefreshStaleVersionIT 12/12 green; TestClassTransactionManagerArchTest 6/6 green.
- **Full log:** `/private/tmp/claude-503/-Users-np1076-dev-spk-owl/accbb0fa-a9ea-4061-b4d7-305226e8dc0b/scratchpad/it1.log`

| Class | Method | IT # | Red reason (quoted) |
|---|---|---|---|
| TransferLaneRaceIT | assignWaitingOnTheSameLaneIsRefusedByTheRecheck | 1 | "assignTransferLaneToTransferOrder: 2 open orders on lane A. The subject waited on lane A's location lock and woke up with its stale 'free' answer…" expected 1, was 2 |
| TransferLaneRaceIT | indexBacksUpAWriterThatSkipsTheLaneLock | 1b | "…2 open orders on lane A. A writer that skips the lane lock must still be backed up by uq_customerorder_open_transferlane" expected 1, was 2 |
| TransferLaneRaceIT | activateWaitingOnTheSameLaneIsRefusedByTheRecheck | 2 | same as IT 1, for activateAndAssignTransferLane: expected 1, was 2 |
| TransferLaneRaceIT | activateIndexBacksUpAWriterThatSkipsTheLaneLock | 2b | same as IT 1b, for activate: expected 1, was 2 |
| StagingLaneRaceIT | indexBacksUpAWriterThatSkipsTheLaneLock | 3 | "2 batches on L: two open club batches hold one staging lane…" expected 1, was 2 |
| StagingLaneRaceIT | assignWaitingOnTheSameLaneIsRefusedByTheRecheck | 3b | the declared harness red: "the subject's lock read must be observably BLOCKED BY THE HOLDER…" |
| GoodsReceiptAdviceLockRaceIT | secondPositionReceiveReusesTheFirstReceipt | 4 | "2 receipts for advice A: the receive on position 2 could not see the holder's uncommitted receipt…" expected 1, was 2 |
| TransferLanePredicateReentryIT | rewindBelow700KeepingTheLaneFailsClosed | 5 | "expected uq_customerorder_open_transferlane violation: order Z rewinds 700 -> 650 … Thrown: null". Red only because the index is absent; develop is not wrong here. |
| GoodsReceiptPositionNumberingIT | numberAfterDeleteIsNotReused | 6 | "duplicate GRP number GRT000029-000001: the count-based draw reissued a number a live row still holds" |
| AdviceNumberingIT | createNumbersThreeLinesInOrder | 6b | PASSES by design: it guards the auto-flush across the change. |
| AdvicePositionNumberingRaceIT | concurrentAddsDrawDistinctNumbers | 7 | "duplicate AP number ADV-SBDEV4107-000000: the subject counted the advice's lines without the holder's uncommitted one" |
| OpenLaneUniqueIndexMigrationIT | indexesHaveTheQueryPredicates | 8 | "index missing: uq_customerorder_open_transferlane (V2.2.51)" |
| OpenLaneUniqueIndexMigrationIT | duplicateGuardNamesTheLanes | 8b | "missing migration file db/migration/V2.2.51__open_lane_unique_and_goodsreceipt_advice_index.sql: IT 8b runs the duplicate guard read from it". A clean assertion, no NPE or IOException. |
| ReturnAdviceFinishRaceIT | lastTwoReceivesFinishTheAdvice | 9 | "advice A still OPEN: both positions are exactly received, but the receive that completed position 2 ran its finisher without seeing position 1's line…" expected FINISHED, was OPEN |

**Bug 1 proven by forced interleaving:** ITs 1 and 2 run in the harness's DEFAULT (strict) mode. The harness confirmed the subject was blocked by the holder's location lock, and the subject still assigned lane A. That is the stale NOT EXISTS the plan argued from the PostgreSQL docs.

**Unit lane failures** (`mvn -o test -Dtest=TransferOrderServiceUnitTest,CustomerorderBatchServiceUnitTest`):
- TransferOrderServiceUnitTest$AssignTransferLaneToTransferOrder.shouldAssignTransferLaneWhenAvailable: "Wanted but not invoked: locationRepository.getAvailableTransferLanes(1L, 700)". It is an InOrder check: ForUpdate, then the re-check, then save.
- $ActivateAndAssignTransferLane.activateAndAssignTransferLane_availableLane_setsState510AndLane_singleSave: same message.
- $ConcurrentLaneTake.assign_staleLockedRead_isRefusedByTheRecheck_withoutWriting: "[SBDEV-4107 A1: the post-lock re-check must refuse a lane another order took while this request waited on the lane lock] Expecting actual not to be null".
- $ConcurrentLaneTake.activate_staleLockedRead_isRefusedByTheRecheck_withoutWriting: same message.
- CustomerorderBatchServiceUnitTest$AssignStagingLaneToOrderBatch.linksStagingLaneToBatch: "Wanted but not invoked: locationRepository.lockById(10L)". It is an InOrder check: lockById, then getAvailableStagingLanes, then save.
- $AssignStagingLaneToOrderBatch.takenLane_isRefusedAfterTheLaneLock_withoutWriting: same message.

## Deviations and setup adjustments
1. **`saveAndFlush` is not declared on CustomerorderRepository or CustomerorderBatchRepository.** Both extend only PagingAndSortingRepository + CrudRepository (parent-verified), so every saveAndFlush stub or verify was a compile error and is deferred. The fix is one line per repository, following the ItemdataRepository (SBDEV-2624) precedent. Plan §5 has been updated.
2. **Two existing assertions contradicted Fix A1 and were rewritten.** They were `verify(locationRepository, never()).getAvailableTransferLanes(any(), anyInt())` in the assign happy path and in the activate happy path (the latter from SBDEV-3183). Both are now InOrder checks: ForUpdate, then the re-check, then save. **The reviewer should check these two.**
3. **Some re-check stubs are lenient.** In changesTheLaneAt510, activatesAnOrderStrandedAt505 and saveThrows, the stubs are lenient because those cases guard other rules; strict stubs would fail with UnnecessaryStubbing.
4. **Arch-test exemptions added.** TransferLaneRaceIT, StagingLaneRaceIT, TransferLanePredicateReentryIT, OpenLaneUniqueIndexMigrationIT and Sbdev4107ReceivingItSupport are added to `TestClassTransactionManagerArchTest.EXEMPT_NON_TRANSACTIONAL`, each with its reason and its cleanup.
5. **Shared fixtures.** `Sbdev4107ReceivingItSupport` is the base for ITs 4, 6, 6b, 7 and 9: it mocks PrintService, uses System-Client 0 plus the V2.2.00 seed, sets printLabel=false, and uses the seeded anonymous operator. `ConcurrentTakeWarnCapture` is the ListAppender helper. Test ids use the 4_107_xxx band.
6. **Beyond §7's wording.** IT 2 is split into a re-check variant and an index variant (2b). IT 5 mocks ManageOrderService. IT 8b asserts an SQLException whose message contains "transfer lane ids [id]" / "staging lane ids [id]".
7. **Harness contract.** `allowUnblockedSubject()` returns BLOCKED, FINISHED or TIMED_OUT, read from the latch. TIMED_OUT throws an AssertionError ("neither blocked on the holder nor finished within 8000 ms"). `subjectBlocked()` throws IllegalStateException if it is read before the probe has run. The default-mode messages are unchanged.
8. **No unexpected passes.**

## Deferred to the executor's first commit (each needs a method that does not exist yet)
- **TransferOrderServiceUnitTest$ConcurrentLaneTake** (after `CustomerorderRepository.saveAndFlush` is declared):
  - switch save to saveAndFlush in the assign and activate cases;
  - assign_namedViolation_becomesTheRefusal: saveAndFlush throws `new DataIntegrityViolationException("x", new org.hibernate.exception.ConstraintViolationException("dup", new SQLException("dup","23505"), "uq_customerorder_open_transferlane"))`; expect a BusinessException containing "transfer lane is not available anymore";
  - assign_otherViolation_isRethrown: the same with "fk_customerorder_client"; expect `isSameAs`;
  - the same pair for activate.
- **CustomerorderBatchServiceUnitTest$AssignStagingLaneToOrderBatch** (after `CustomerorderBatchRepository.saveAndFlush` is declared):
  - switch save to saveAndFlush in linksStagingLaneToBatch, allowsAssignmentWhenMixed… and changesTheLaneBeforeTheRun, plus the four `never()` checks;
  - add namedViolation (uq_customerorder_batch_open_staginglane, "staging lane is not available anymore") and otherViolation (isSameAs).
- **ReceivingServiceUnitTest:**
  - stub `adviceRepository.findByIdForUpdate` and `advicepositionRepository.findAdviceIdById` in every receive case;
  - `findByAdviceId` becomes `findFirstByAdviceIdOrderByIdAsc` (returns Optional);
  - `countByGoodsreceiptId` becomes `findNumbersByGoodsreceiptId` (returns List<String>);
  - finisher cases: stub the advice lock;
  - updateAdviceWithPositions: findById becomes findByIdForUpdate;
  - new cases: the advice is locked before the position (InOrder), and the oldest receipt is reused.
- **BasicServiceUnitTest:**
  - delete the generateNumberWithGoodsReceipt test;
  - re-point the generateNumberWithAdvice stubs to findNumbersByAdviceId;
  - add nextSuffix cases: empty → 0; ["X-000000","X-000003"] → 4; a non-numeric suffix is ignored.
- **ReceivingController:** a test for the PessimisticLockingFailureException arm ("retry" message).

## Completion commands
Set JDK 21 first: `export JAVA_HOME=$(/usr/libexec/java_home -v 21); export PATH="$JAVA_HOME/bin:$HOME/.sdkman/candidates/maven/current/bin:$PATH"`

- **IT lane:** `mvn -o verify -Dit.test='TransferLaneRaceIT,StagingLaneRaceIT,TransferLanePredicateReentryIT,OpenLaneUniqueIndexMigrationIT,GoodsReceiptAdviceLockRaceIT,GoodsReceiptPositionNumberingIT,AdviceNumberingIT,AdvicePositionNumberingRaceIT,ReturnAdviceFinishRaceIT,GoodsReceiptPositionAdjustIT,BusinessServiceLockRefreshStaleVersionIT' -Dtest=TestClassTransactionManagerArchTest -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true`. Confirm the counts in target/failsafe-reports.
- **Unit lane:** `mvn -o test -Dtest=TransferOrderServiceUnitTest,CustomerorderBatchServiceUnitTest`.

## Changed files (`git status --short`, test files only)
```
 M src/test/java/net/aim_ai/wms/common/fixtures/HeldRowLockRace.java
 M src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java
 M src/test/java/net/aim_ai/wms/unit/service/CustomerorderBatchServiceUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/service/TransferOrderServiceUnitTest.java
?? src/test/java/net/aim_ai/wms/common/fixtures/ConcurrentTakeWarnCapture.java
?? src/test/java/net/aim_ai/wms/integration/service/{AdviceNumberingIT,AdvicePositionNumberingRaceIT,GoodsReceiptAdviceLockRaceIT,GoodsReceiptPositionNumberingIT,OpenLaneUniqueIndexMigrationIT,ReturnAdviceFinishRaceIT,Sbdev4107ReceivingItSupport,StagingLaneRaceIT,TransferLanePredicateReentryIT,TransferLaneRaceIT}.java
```

**Not yet done:** mutation-checking the new assertions (plan step 7, after the fix) and an independent review lane.
