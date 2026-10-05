Group A is written and every test fails at an assertion that names what's missing, except T19, which passes as intended. Nothing under `src/main` was touched, nothing is committed, and group B has been left to the executor.

Two problems came up that you should know before implementation starts:
- **A red that isn't mine:** `CancellationReversalServiceUnitTest.completeReversalMovesStockBackToSourceLocation` fails when it runs in the same JVM after `FunctionGuardMockMvcUnitTest` (expected `"anonymous"`, got `"sbtest"`). `FunctionGuardMockMvcUnitTest`'s `@BeforeEach` sets a security context and nothing ever clears it. I reproduced it using only existing test methods (`everyGuardedControllerIsForbiddenForAUserHoldingNothing` then that test → 1 failure), and it passes 30/30 when its class runs alone. It depends on run order, so the full suite may or may not show it. T1 and T3 assert `reversalCompletedBy`, so the executor should add `SecurityContextHolder.clearContext()` in an `@AfterEach` first. It's a test-side fix below T3, so it goes on this ticket.
- **One mutant survived at first:** T17's idempotency check didn't catch an `ON CONFLICT DO NOTHING` seed. The plan's premise is wrong (details in section 6), so I added a fixture step that fixes it.

## 1. Files and git status
New:
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3381/src/test/java/net/aim_ai/wms/unit/service/CancellationWaiveContractUnitTest.java`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3381/src/test/java/net/aim_ai/wms/integration/schema/CancellationWaiveMigrationIT.java`

Modified (one method added to each, plus one import in FunctionGuard):
- `.../schedulejob/PendingReversalReconciliationJobUnitTest.java`
- `.../unit/controller/rest/UtilRestControllerUnitTest.java` (inside `@Nested InitDB`)
- `.../unit/controller/rest/UtilRestControllerSeedUnitTest.java`
- `.../unit/controller/mobile/FunctionGuardMockMvcUnitTest.java`
- `.../unit/service/CancellationReversalServiceUnitTest.java`

```
 M src/test/java/net/aim_ai/wms/schedulejob/PendingReversalReconciliationJobUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/controller/mobile/FunctionGuardMockMvcUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/controller/rest/UtilRestControllerSeedUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/controller/rest/UtilRestControllerUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/service/CancellationReversalServiceUnitTest.java
?? src/test/java/net/aim_ai/wms/integration/schema/CancellationWaiveMigrationIT.java
?? src/test/java/net/aim_ai/wms/unit/service/CancellationWaiveContractUnitTest.java
```
`target/test-classes/db/migration` is empty (the sandbox SQL was removed, and `mvn clean` ran afterwards).

## 2. Results
| Class | Method | Row | Result | Key failure line |
|---|---|---|---|---|
| CancellationWaiveContractUnitTest | waiveRequest_shouldDeclareThreeFields_withBoxedStockReturned | contract | correct failure | `class net.aim_ai.wms.json.CancellationWaiveRequest does not exist (SBDEV-3381 plan §3.1)` |
| same | waiveReversal_shouldBeDeclaredTransactionalOnTenantManager_withRollbackForCheckedExceptions | contract | correct failure | `[CancellationReversalService must declare exactly one 4-arg method waiveReversal(...)]` |
| same | cancellationLog_shouldDeclareWaiveColumns | contract | correct failure | `[CustomerorderCancellationLog must declare reversalWaived, reversalWaiveReason and reversalWaiveStockReturned]` |
| same | cancellationLogEntryDto_shouldDeclareFourWaiveFields | contract | correct failure | `[CancellationLogEntryDto must declare reversalWaived, waiveReason, waiveStockReturned and waiveLockRetained]` |
| same | functionEnum_shouldDeclareWaiveConstant_whoseValueEqualsItsName | contract | correct failure | `[WmsConstants.FunctionEnum must declare MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL]` |
| same | controller_shouldDeclareWaiveHandler_gatedOnWaiveFunction | contract | correct failure | `[OrderCancellationController must declare exactly one 2-arg handler waiveReversal(...)]` |
| PendingReversalReconciliationJobUnitTest | reconcile_shouldNameWaiveAndOutboundManager_whenRowsArePending | T16 | correct failure | `[...the alert must say an OUTBOUND MANAGER waives...]` |
| CancellationWaiveMigrationIT | waiveColumns_shouldBeAddedByV2234_withReversalWaivedDefaultFalse | T17 | correct failure | `[no V2.2.34__*.sql migration exists on classpath:db/migration ...] Expecting Optional to contain a value but it was empty.` |
| same | functionSeed_shouldGrantExactlyTwoRoles_andSecondApplyShouldBeANoOp | T17 | correct failure | same line |
| same | waiveCheck_shouldRejectIncompleteWaivedRow_withSqlState23514 | T17 | correct failure | same line |
| UtilRestControllerUnitTest$InitDB | initDB_shouldGrantWaiveFunctionToExactlyOutboundManagerAndSuperAdmin | T13 | correct failure | `Expecting actual: [] to contain exactly: ["outbound-manager", "super-admin"]` |
| UtilRestControllerSeedUnitTest | waiveMigrationAndInitDB_shouldGrantTheSameRoleNameSet | T14 | correct failure | `[exactly one db/migration script must seed MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL ...] Expected size: 1 but was: 0` |
| FunctionGuardMockMvcUnitTest | waive_shouldBeForbiddenForViewOnlyHolder_andAdmitTheWaiveHolder | T11 | correct failure | `[a VIEW_CANCELLATION-only holder must get 403 on POST /v3/cancellation/{id}/waive ...] expected: 403 but was: 404` |
| CancellationReversalServiceUnitTest | completeReversal_shouldReEnqueue_whenRetriedOnAnAlreadyClosedOrder | T19 (first half) | expected pass | — |

How each group-A test was built:
- **T17 fails at an assertion, not a Flyway error.** Before targeting 2.2.34, the harness asserts via `Flyway.info()` that a V2.2.34 script exists. Each test's absence checks at 2.2.33 had already passed by then, including the check that both target roles exist.
- **T17 was checked against the plan's §3.6 SQL.** I put that SQL in `target/test-classes/db/migration` only, never `src/main`, and ran it: 3/3 green. Then I ran five SQL mutants:

  | Mutant | Result |
  |---|---|
  | drop DEFAULT | red: Flyway fails, because the pre-existing row violates NOT NULL |
  | drop the CHECK | red: `V2.2.34 must create ck_cancel_log_waive_complete` |
  | super-admin → outbound-worker | red: `but was: ["outbound-manager", "outbound-worker"]` |
  | drop the btrim term | red: `a waived row with blank reason must be REJECTED` |
  | targetless ON CONFLICT | first survived (see section 6); after the fixture fix, red: `expected: 2L but was: 4L` |

- **T11's allow paths require the handler to actually be entered** (the null-service throw counts as 200), never just `!= 403`. Today the route is a 404, which a `!= 403` check would accept.
- **T13, T14 and T11 name the function by string.** The executor can switch them to the constant once it exists.
- **T19 mutant (argued, not run — it would need a `src/main` change).** Any edge trigger added to `completeReversal` turns it red at `verify(outboxService).enqueue`: for example "enqueue only if this call stamped a row", or an early `return detail(coId)` when the FOR UPDATE finder is empty. The FOR UPDATE finder returns `[]` for the closed CO, so an edge-triggered complete never reaches the outbox. It also pins no `transferStock`, no `logRepository.save`, and the closed row's `reversalCompletedBy` unchanged.

## 3. Commands and Maven summaries
Setup for every run: Java 21 exported, and `pgrep -fl "surefire|failsafe|maven"` empty beforehand. One `mvn -q clean test-compile` first (fixed one ambiguous `assertThat(SQLException)` by casting to `(Throwable)`).

- **Group A unit run:** `mvn test -Dtest='CancellationWaiveContractUnitTest,PendingReversalReconciliationJobUnitTest,UtilRestControllerUnitTest,UtilRestControllerSeedUnitTest,FunctionGuardMockMvcUnitTest,CancellationReversalServiceUnitTest' -Dsurefire.failIfNoSpecifiedTests=false`
  - `Tests run: 93, Failures: 11, Errors: 0` = my 10 expected reds + the order-dependent red above.
- **Service class alone:** `mvn test -Dtest=CancellationReversalServiceUnitTest ...` → `Tests run: 30, Failures: 0` (T19 passes).
- **Pollution check with pre-existing methods only:** `mvn test -Dtest='FunctionGuardMockMvcUnitTest#everyGuardedControllerIsForbiddenForAUserHoldingNothing,CancellationReversalServiceUnitTest#completeReversalMovesStockBackToSourceLocation'` → `Tests run: 2, Failures: 1` — `expected: "anonymous" but was: "sbtest"`.
- **IT:** `mvn verify -Dit.test=CancellationWaiveMigrationIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` → `Tests run: 3, Failures: 3`. The sandbox runs used the same command via a scratch script `runit.sh`: plan SQL → `Tests run: 3, Failures: 0`, mutants as listed above.
- **Final:** `mvn clean verify -Dtest=<the 6> -Dit.test=CancellationWaiveMigrationIT -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.test.failure.ignore=true`
  - surefire `Tests run: 93, Failures: 11, Errors: 0, Skipped: 0`
  - failsafe `Tests run: 3, Failures: 3, Errors: 0, Skipped: 0`
  - `BUILD SUCCESS` only because failures were ignored.

## 4. Moved from A to B
- **Nothing moved.** All six A items compile against today's code.
- **Only T19's first half is written.** Its suppression half ("with a `stockReturned=false` waived row → no enqueue") needs `setReversalWaived` / `setReversalWaiveStockReturned`, so it's T19b in section 5.
- **Not written in the contract test:** a check on `reversalWaiveReason`'s `columnDefinition="TEXT"` (plan §3.4). Only the column name is checked; T17 checks the `text` type in the DB.

## 5. Group B specs (executor's first commit)
Shared fixture rules for every row:
- `picktounitloadId ≠ su.unitloadId`, using different numbers. In the unit tests, give the SU `unitloadId = TOTE_UNITLOAD_ID` (159979) and the log `picktounitloadId = 88001L`. Today's `pendingLog` sets both to 159979, so the executor must change that per test (or add a variant builder).
- `toteLabelId` and the unit load's `labelid` are set explicitly.
- `picktostockunitId` is non-null unless the test is about recovery.
- Tote-state setup:
  - **ON:** `findParcelGuardViewById(suUlId)` returns type Tote (2L) with label = `toteLabelId`.
  - **PARCEL:** type Package (3L).
  - **OFF:** a new `givenType(4L, "Default")`.
  - **UNKNOWN:** view empty, or type null, or Tote with a different label.
- Every refusal test verifies `stockunitRepository.save`, `logRepository.save` and `outboxService.enqueue` are never called.

The unit rows below all live in `CancellationReversalServiceUnitTest`.

**T1** `waiveReversal_shouldStampWaivedRowsAndNotTouchStock_whenLiveNirwanaCase`
- **Fixture:** 1 pending row, SU amount 0, lock 2 (GOING_TO_DELETE), OFF; `stockReturned=true`, reason `" tote gone "`.
- **Assert:** `reversalCompletedAt` is set; `reversalCompletedBy` is ANONYMOUS; `reversalWaived` is true; `reversalWaiveReason` is `"tote gone"` (trimmed); `reversalWaiveStockReturned` is TRUE.
- **Assert:** `stockunitRepository.save` and `transferStock` are never called.
- **Kills:** deleting the stamp; writing to the lock-2 SU.

**T2** `waiveReversal_shouldClearPickedForGoodsout_whenOnToteAndOwned`, in two variants:
- **(a)** amount 1, lock 100, ON, Σ amountPicked = 1, `false` → SU saved with lock 0, no `transferStock`.
- **(b) (§7.2a)** amount 0, lock 100, ON, not recovered → cleared to 0.
- **Kills:** dropping the clear; never clearing in (i′).

**T3** `waiveReversal_shouldApplyOwnershipRule_whenLockIs100OnTote`, parameterised:
- **Kept (lock stays 100, row closed, `waiveLockRetained=true` in the returned detail):**
  - amount 3 vs Σ 2;
  - (§7.2a) A(null) + B(3) both waived this call on SU amount 3;
  - an SU recovered in this call: `picktostockunitId` null, `resolvePicktoStockunitId` returns the SU id.
- **Cleared:** amount 2 == Σ 2; and A already waived (`findByCustomerorderId` returns A with `reversalWaived=true, amountPicked=1`) with B(1) now on SU amount 2.
- **Kills:** `<=`→`<`; always clear; dropping the already-waived term; dropping the null guard; dropping the recovered guard; an id-comparison `onTote` (because of distinct ids).

**T4** `waiveReversal_shouldRefuseStockReturnedTrue_whenStockMayStillBeInFlight`, parameterised over:
- (ii) amount 1, lock 100, ON;
- (ii′) amount 1, lock 0: ON / PARCEL / UNKNOWN;
- (ii″) lock 100, OFF;
- SHIPPED 405.
- **Assert:** `BusinessException` whose message contains the position id, the SU id and `getCodeTextOrUnknown`; nothing saved.
- **Kills:** refusing after the writes; dropping a branch; treating Package as OFF.

**T5** `waiveReversal_shouldLeaveForeignLocksUntouched`
- **Fixture:** QUALITY_FAULT / ON_HOLD / 403 / 404 with amount 0 or OFF; (ii″) lock 100 with OFF / PARCEL / UNKNOWN; (i′) lock 100 UNKNOWN. All with `stockReturned=false`.
- **Assert:** `stockunitRepository.save` never called; row closed.
- **Kills:** clearing any non-100 lock; clearing on UNKNOWN or PARCEL; label-only `onTote`; id-comparison `onTote`.

**T5b** `waiveReversal_shouldRefuse_whenClubUuidToteLabel`
- **Fixture:** `toteLabelId` a UUID; the SU's unit load is type Tote with label `C1-0063`; QUALITY_FAULT, amount 1, `stockReturned=true`.
- **Assert:** `BusinessException`.
- **Kills:** UNKNOWN treated as OFF.

**T6** `waiveReversal_shouldEnqueueOnce_whenClosingLastRowWithStockReturned`
- **Fixture:** stubs as in `completeReversalEnqueuesTheOmsNotificationOnlyWhenNothingIsLeftPending`.
- **Assert:** `true` → `enqueue` once, and the payload JSON equals the one a `completeReversal` captures on the same fixture (assertEquals on the strings); `false` → `never()`.
- **Kills:** dropping suppression; payload drift.

**T7** `waiveReversal_shouldDoNothing_whenAllTargetsAlreadyClosed`
- **Fixture (§7.2a):** the first waive closes the last row with `true`. Then `clearInvocations(...)`; the second call's FOR UPDATE finder returns `[]`.
- **Assert:** on the second call, `enqueue`, `logRepository.save` and `stockunitRepository.save` are never called.
- **Kills:** removing the empty-targets early return.

**T8** `waiveReversal_shouldReject_whenInputInvalid`, parameterised:
- `"  "`, a 501-char reason, `[]`, null ids, null `stockReturned`, an id on no row of this CO → `BusinessException` with the §3.1 texts; nothing saved.
- A 500-char reason → accepted.
- **Kills:** `isBlank`→`isEmpty`; `>`→`>=`; silently skipping an unknown id.

**T9** `waiveReversal_shouldLockViaForUpdateFinder`
- `verify(logRepository).findPendingReversalsForUpdateByCustomerorderId(CO_ID)`, and `never().findPendingReversals…` as the lock source.
- **Kills:** swapping the finder.

**T10** new `unit/controller/mobile/OrderCancellationControllerUnitTest extends BaseControllerUnitTest`, method `waive_shouldBindBody_andLeaveOmittedStockReturnedNull`
- **Fixture:** mocked service; POST `/v3/cancellation/7/waive` with body `{"positionIds":[1,2],"reason":"r"}`.
- **Assert:** `verify(service).waiveReversal(7L, List.of(1L, 2L), "r", null)`; a second body with `"stockReturned":false` → `Boolean.FALSE`.
- **Kills:** renaming a field; a primitive `boolean`.

**T11 follow-up** (in `FunctionGuardMockMvcUnitTest`): switch `"MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL"` to the constant. The test stays otherwise unchanged; I left the plan's pins (REVIEWED_METHOD_LEVEL_OVERRIDES, `hasSize(3)`→4) alone as instructed.

**T15** `PendingReversalOlderThanIntegrationTest.findPendingReversalsOlderThan_shouldExcludeWaivedRow`
- **Fixture:** two old rows; one waived via `service.waiveReversal` (stamped); one untouched (positive control).
- **Assert:** the result contains the untouched id and not the waived id (by id, never size).
- **Kills:** not stamping on waive.

**T18 / T18b / T22** (`CancellationReversalLockClearIntegrationTest`) use a new builder `seedWaiveOrder(...)`, following plan §7.1 steps 1–6 plus §7.2a step 7:
1. Tote type via `findByName(UNIT_LOAD_TYPE_TOTE).orElseGet`.
2. A real `PickingorderUnitload`, with `picktounitloadId` = its id (≠ tote id).
3. `toteLabelId` = the tote's label.
4. A `CustomerorderBatch`, with the CO's `orderbatchId` pointing at it.
5. `@MockitoSpyBean SyspropService` stubbing the reversal URL.
6. A fresh CO with no pending sibling.
7. T18b only: the log's `picktostockunitId` is null, `pul.unitload_id` = the tote, and a `PickingorderPosition` carries the SU's itemdata.

Outbox rows are counted `WHERE aggregate_id = coId`.

**T18** `waiveAndComplete_shouldEnqueueOnceOnClose_andReSendOnExtraComplete`
- **Row shapes (§7.2a):** the waived row's SU is amount 0, lock 100, ON; the completed row has a distinct SU, amount > 0, lock 100.
- **Sequences:** positive control complete-only → 1; waive→complete → 1; complete→waive → 1. Then an extra `/complete` naming the waived row → that row is unchanged (`reversal_waived`, `reversal_completed_by`, SU amount/lock) and outbox = 2. The `false` variant → 0, then still 0.
- **Kills:** a finder without the stamp predicate; an edge trigger in complete; suppression dropped on the re-send; a fixture that never enqueues.

**T18b** `waive_shouldCommitNothing_whenRefusedAfterRecovery`
- **Fixture:** ON, amount > 0, lock 100, `stockReturned=true` → expect `BusinessException`.
- **Assert (reading the DB afterwards):** `picktostockunit_id` IS NULL and `reversal_completed_at` IS NULL.
- **Kills:** dropping `rollbackFor`.

**T19b** `completeReversal_shouldNotReEnqueue_whenAStockReturnedFalseWaiveExistsOnOrder`
- **Fixture:** the T19 fixture plus a `findByCustomerorderId` row with `reversalWaived=true, reversalWaiveStockReturned=FALSE`.
- **Assert:** `never().enqueue`.
- **Kills:** dropping suppression on the re-send path.

**T20** `completeReversal_shouldHonourWaiveSuppression_whenClosingLastRow`
- **Fixture:** a sibling row waived with `false` → closing complete produces no enqueue; waived with `true` → one enqueue.
- **Kills:** dropping the predicate; suppressing on any waive.

**T21a** `CancellationLogEntryDtoSerializationTest.shouldSerializeWaiveKeys`
- **Assert:** the JSON has the keys `reversalWaived`, `waiveReason`, `waiveStockReturned`, `waiveLockRetained` with their set values.
- **Kills:** dropping a field or getter.

**T21b** `detail_shouldSetWaiveLockRetained_onlyForWaivedLockedNonOffRows`
- **Fixture:** waived rows with lock 100, amount 1, under ON / PARCEL / UNKNOWN → true; OFF → false; a non-waived row with the same SU → false.
- **Kills:** a dropped mapping; `!= OFF`→`== ON`; id-comparison `onTote`.

**T22** `completeAfterWaive_shouldRestoreResidueLockPerWaivedShare`
- **Base fixture:** A(1) + B(2) on SU amount 3, lock 100, ON.
- **Base case:** waive A `false`, then complete B → residue 1, lock 0.
- **Variants:**
  - A(null) → lock 100;
  - **(c)** A1(null) + A2(1) waived, B(2) → lock 100;
  - **(d)** A(null) waived, B(3) drains the SU → not lock 100.
- **Kills:** the old predicate; `waivedShare` summed from `logs`; dropping `anyNull`; the standalone-OR form.

## 6. Plan statements that are wrong against the code
1. **§7.2a T17** says "these tables have no unique index", so only row counts can kill `ON CONFLICT`. That's true of the V2.2.00 dump but not of a database built through `db/migration`: V2.2.20 adds a primary key on `mywms_role_mywms_function`, and `mywms_function.function` has been UNIQUE since V2.2.00:3700.
   - Measured: the targetless `ON CONFLICT DO NOTHING` mutant passed all count assertions.
   - Fix I applied: the test now drops every PK/unique index on the join table before the second apply. That reproduces the unkeyed tenants V2.2.20's header lists (Hydra PRD, shipitez-nywh), and the mutant then fails `expected: 2L but was: 4L`.
2. **§3.7 / T16:** today's text is already `"Complete or waive them on the mobile Cancellation screen."`. So the "waive" half of T16 passes now; only "outbound manager" catches a revert.
3. **§7.1 T11 "waive holder → 200":** in this harness a real 200 can't happen (the collaborators are null). 200 is a stand-in meaning "handler entered".

Everything else I checked held: the `:179-186` / `:216` / `:238-245` / `:647` references in `CancellationReversalLockClearIntegrationTest`, the method-level gate override, both target roles in the base schema, and the plan's §3.6 SQL passing T17 unchanged.
