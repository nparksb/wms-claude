---
title: SBDEV-3736 — TDD gate baseline (A–E)
ticket: SBDEV-3736
lane: test-engineer (TDD gate)
date: 2026-10-15
code_pin: wms2-api origin/develop 371d8a09 (worktree, uncommitted test-only changes)
---

# SBDEV-3736 — TDD gate baseline

## Branch / worktree

- Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3736`
- Branch: `feature/SBDEV-3736-returns-audit-linkage`, off `origin/develop` `371d8a09`
- JDK 21.0.11-ms, Maven 3.9.15, offline (`-o`). One Maven process at a time.
- **Nothing under `src/main` is touched. Nothing is committed.**

Changed or added test files:

- `src/test/java/net/aim_ai/wms/unit/service/ReceivingServiceUnitTest.java` (B, E)
  - Also: `setupHappyPathMocks()` now delegates to a new `setupHappyPathMocks(Goodsreceipt existing)`.
    Every existing caller is unchanged.
- `src/test/java/net/aim_ai/wms/unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java` (C, D)
- `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceDamagedOrderNumberUnitTest.java` (D, **new**)
- `src/test/java/net/aim_ai/wms/unit/service/UnitloadServiceUnitTest.java` (D)
- `src/test/java/net/aim_ai/wms/unit/controller/ReportReadGateUnitTest.java` (A)
- `src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` (A)
  - Adds 2 rows; the pin size goes from 227 to 229.
- `src/test/java/net/aim_ai/wms/unit/repo/ReturnsAuditQueryContractUnitTest.java` (A, **new**)
- `src/test/java/net/aim_ai/wms/integration/ReturnsAuditQueryIntegrationTest.java` (A, **new**, PostgreSQL)
- `src/test/java/net/aim_ai/wms/integration/TransactionDetailReturnOrderRefsIntegrationTest.java` (D)

## Approach for (A): everything compiles today

There is **no deferred or disabled file**.

- **`ReturnsAuditQueryContractUnitTest`** pins the signature by reflection. It asserts the declared set,
  keyed on name + parameter count. It is non-vacuous: `findByIdForUpdate/1` and `findByAdviceId/1` must
  be present first.
- **`ReturnsAuditQueryIntegrationTest`** finds the same method by reflection and reads its `@Query`
  text. It binds the `@Param` names and runs both the query and the `countQuery` with
  `NamedParameterJdbcTemplate` on Testcontainers PostgreSQL 14. The harness matches
  `TransactionDetailReturnOrderRefsIntegrationTest`: Flyway over `db/migration`, no Spring context.
  - It grades the SQL text that ships, not a copy of it.
  - It fails at an assertion ("method does not exist yet") until the method lands.
  - It then becomes the behavioural proof with no edit.
- Gate tests reach the route by HTTP path (`ReportReadGateUnitTest`) and by the context pin
  (`Sbdev3017TrancheGateContextTest`). Neither needs the handler signature.

### Signatures the executor must create (the tests key on these exactly)

| Item | Signature |
|---|---|
| A repo | On `AdvicepositionRepository`: `@Query(value=…, countQuery=…, nativeQuery=true) Page<ReturnsAuditView> findReturnsAudit(@Param("from") OffsetDateTime from, @Param("to") OffsetDateTime to, @Param("clientNumber") String clientNumber, Pageable pageable)` |
| A projection | `net.aim_ai.wms.repo.projection.ReturnsAuditView` (interface). It must have at least these getters: `getAdviceId`, `getAdviceNumber`, `getParcelId`, `getMerchantOrderNumber`, `getPositionNumber`, `getReceivedAmount`, `getUnitLoad`, `getPutawayDestination`, `getReceivingCompletedAt`, `getFullyReceived` (Boolean). **Every** getter must have a same-named SQL alias; the IT checks this case-insensitively. |
| A SQL | See the SQL constraints below the table. |
| A route | `@GetMapping("/returnsAudit")` on `ReportController`, with method-level `@RequiresFunction(WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW)`. Query parameters used by the gate test: `from`, `to` (ISO-8601 with an offset), `page`, `size`. |
| D | `StockunitService.setLockDamaged(Stockunit, BigDecimal, String comment, boolean printLabel, Principal principal, String orderNumber)`. The existing 5-arg form delegates `null`. |
| D | `UnitloadService.moveStockToNewDamagedContainer(String containerLabel, Stockunit, Location, Long, BigDecimal, String comment, String orderNumber)`. `orderNumber` is **appended last** and replaces the 6-arg form. |
| D | `applyDamage` passes `adviceposition.number` as the last argument. Get it either by looking up `line.advicePositionId()` (the test stubs `findById(101L)`) or from a new `AutoReceiveLine.number`. If you use the record, `planWithDamagedLines` must pass `"IBOL012604-000000"` for line 1. |

SQL constraints for the A query:

- Use plain `:name` parameters only, with no SpEL.
- Put the fixed `ORDER BY` inside the query.
- Filter on a half-open `a.created` range `[from, to)`.
- `clientNumber = null` means all clients.
- `countQuery` must not mention `unitload_record`.

## Tests

| Test class | Method | Criterion | Baseline |
|---|---|---|---|
| ReportReadGateUnitTest | `returnsAudit_shouldRequireExactlyReceivedStockOverview_whenMappedOnReportController` | A gate (which function, method-level) | RED |
| ReportReadGateUnitTest | `returnsAudit_shouldBeForbidden_whenCallerLacksTheFunctionOnReportPrefix` | A gate `/v3/report` 403 | RED |
| ReportReadGateUnitTest | `returnsAudit_shouldBeForbidden_whenCallerLacksTheFunctionOnDashboardPrefix` | A gate `/v3/dashboard` twin 403 | RED |
| Sbdev3017TrancheGateContextTest | `everyTrancheRouteCarriesItsIntendedFunctions` (+2 rows) | A path pin, both prefixes | RED |
| ReturnsAuditQueryContractUnitTest | `findReturnsAudit_shouldBeDeclared_whenContractIsImplemented` | A repo method exists (name + arity) | RED |
| ReturnsAuditQueryContractUnitTest | `findReturnsAudit_shouldBeNativeWithCountQuery_whenDeclared` | A native + countQuery | RED |
| ReturnsAuditQueryContractUnitTest | `findReturnsAudit_shouldKeepUnitloadRecordOutOfCountQuery_whenDeclared` | A count must not scan unitload_record | RED |
| ReturnsAuditQueryContractUnitTest | `findReturnsAudit_shouldBindNamedParametersAndPageable_whenDeclared` | A param types/names | RED |
| ReturnsAuditQueryContractUnitTest | `findReturnsAudit_shouldReturnPageOfProjection_whenDeclared` | A interface projection | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldReportStrippedLabel_whenUnitLoadWasRelabelledOnSendToNirvana` | A(1) relabelled UL, stripped label | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldKeepPutawayDestination_whenUnitLoadWasRelabelled` | A(1) destination via stripped label | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldEmitOneRowWithoutPosition_whenReturnAdviceHasNoPositions` | A(2) position-less advice appears once | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldNotReportCompletion_whenReturnAdviceHasNoPositions` | A(2) no vacuous completion | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldResolveDestination_whenPutawayRowIsTheSecondCreatedRow` | A(3) 2025 CREATED shape → PutAwayLane | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldResolveDestination_whenPutawayRowIsTransferred` | A(4) TRANSFERRED shape | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldKeepPerUnitLoadDestination_whenOnePositionFansOutToSeveralUnitLoads` | A(4) dock fan-out (R2-5) | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldDeriveParcelId_whenExternalidIsReturnFormat` | A(5) parcel_id | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldResolveMerchantOrderNumber_whenCustomerorderMatchesTheParcel` | A(5) merchant order via externalnumber | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldReportCompletion_whenEveryPositionIsFullyReceivedDespiteOpenAdviceState` | A(6) completion from positions | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldReportNoCompletion_whenAPositionIsShortDespiteFinishedAdviceState` | A(6) not from advice.state | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldExcludeAdvice_whenTypeIsNotReturn` | A(7) non-RETURN excluded | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldExcludeAdvice_whenCreatedOutsideTheDateRange` | A(7) date range | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAuditCount_shouldEqualRowCount_whenRunWithTheSameParameters` | A countQuery agrees | RED |
| ReturnsAuditQueryIntegrationTest | `returnsAudit_shouldExposeAColumnForEveryProjectionGetter_whenQueried` | A projection binds by alias | RED |
| ReceivingServiceUnitTest$ReceiveGoods | `receiveGoods_shouldStampUtcReceiptdate_whenCreatingTheGoodsreceipt` | B S1 UTC stamp (default TZ = UTC+14 during call) | RED |
| ReceivingServiceUnitTest$ReceiveGoods | `receiveGoods_shouldNotRestampReceiptdate_whenGoodsreceiptAlreadyExists` | B S1 no re-stamp on reuse | GUARD (passes) |
| ReturnAdviceAutoReceiveServiceUnitTest$Execute | `markFinished_shouldSaveAdviceEntityAsFinished_whenCalled` | C S2 entity saveAndFlush, FINISHED | RED |
| ReturnAdviceAutoReceiveServiceUnitTest$Execute | `markFinished_shouldNotUseBulkAdviceStateUpdate_whenCalled` | C S2 no bulk advice update | RED |
| ReturnAdviceAutoReceiveServiceUnitTest$Execute | `markFinished_shouldStillBulkFinishPositions_whenCalled` | C S2 position bulk unchanged | GUARD (passes) |
| ReturnAdviceAutoReceiveServiceUnitTest | `applyDamage_shouldPassAdvicePositionNumberAsOrderNumber_whenLineIsDamaged` | D applyDamage → number, not externalId | RED |
| StockunitServiceDamagedOrderNumberUnitTest | `setLockDamaged_shouldPassOrderNumberToDamagedMove_whenOrderNumberOverloadIsUsed` | D overload → moveStock | RED |
| StockunitServiceDamagedOrderNumberUnitTest | `setLockDamaged_shouldPassNullOrderNumber_whenLegacyFiveArgFormIsUsed` | D 5-arg delegates null | RED |
| UnitloadServiceUnitTest$MoveStockToNewDamagedContainerBoundary | `moveStockToNewDamagedContainer_shouldForwardOrderNumberToTransfer_whenOrderNumberGiven` | D moveStock → transferStockToUnitLoad | RED |
| TransactionDetailReturnOrderRefsIntegrationTest | `damagedRow_shouldCarryTransactionAndOrderNumber_whenStockrecordCarriesThePositionNumber` (AC-10) | D customer-visible contract | CONTRACT PIN (passes) |
| ReceivingServiceUnitTest$ReceiveGoods | `receiveGoods_shouldFinishReturnAdviceViaEntitySave_whenEveryPositionIsFullyReceived` | E S8 RETURN complete → FINISHED via entity save, no bulk | RED |
| ReceivingServiceUnitTest$ReceiveGoods | `receiveGoods_shouldFinishEveryPositionEntity_whenReturnAdviceCompletes` | E S8 position entities FINISHED | RED |
| ReceivingServiceUnitTest$ReceiveGoods | `receiveGoods_shouldLeaveReturnAdviceOpen_whenAnotherPositionIsOnlyPartiallyReceived` | E partial stays OPEN | GUARD (passes) |
| ReceivingServiceUnitTest$ReceiveGoods | `receiveGoods_shouldNotFinishRegularAdvice_whenEveryPositionIsFullyReceived` | E REGULAR not auto-finished | GUARD (passes) |
| ReceivingServiceUnitTest$ReceiveGoods | `receiveGoods_shouldNotFinishReturnAdvice_whenAdviceHasNoPositions` | E position-less not finished | GUARD (passes) |

## Failure output excerpts (key assertion lines)

```
ReportReadGateUnitTest
  returnsAudit_…ReportPrefix      expected: 403  but was: 404
  returnsAudit_…DashboardPrefix   expected: 403  but was: 404
  returnsAudit_shouldRequireExactly…  [expected exactly one handler mapped at '/returnsAudit' on ReportController …]
                                      Expected size: 1 but was: 0
Sbdev3017TrancheGateContextTest.everyTrancheRouteCarriesItsIntendedFunctions
  gate drift — 2 of 229 routes wrong. {ReportController /v3/report/returnsAudit=ROUTE NOT DEPLOYED …
                                       ReportController /v3/dashboard/returnsAudit=ROUTE NOT DEPLOYED …}
ReturnsAuditQueryContractUnitTest
  shouldBeDeclared   Expecting HashSet ["findByIdForUpdate/1","generatePositionCountStringByAdviceId/1",
                     "updateAdvicepositionToStateByAdviceId/2","findByAdviceId/1"] to contain ["findReturnsAudit/4"]
  (other 4)          [AdvicepositionRepository must declare exactly one findReturnsAudit/4 …] Expected size: 1 but was: 0
ReturnsAuditQueryIntegrationTest (all 15; fixture seeded OK — failures, not @BeforeAll errors)
  [AdvicepositionRepository.findReturnsAudit(OffsetDateTime from, OffsetDateTime to, String clientNumber,
   Pageable) does not exist yet …] Expected size: 1 but was: 0
ReceivingServiceUnitTest$ReceiveGoods
  shouldStampUtcReceiptdate        [S1: the goodsreceipt must carry a receiptdate — today nothing ever writes it]
                                   Expecting actual not to be null
  shouldFinishReturnAdviceViaEntitySave  [S8: … must be FINISHED …] expected: "FINISHED" but was: "OPEN"
  shouldFinishEveryPositionEntity        Expecting ["OPEN","OPEN"] to contain only ["FINISHED"]
ReturnAdviceAutoReceiveServiceUnitTest
  markFinished_shouldSaveAdviceEntity…   Wanted but not invoked: adviceRepository.saveAndFlush(<Capturing argument: Advice>)
                                         … exactly 1 interaction: adviceRepository.updateAdviceToStateById("FINISHED", 1L)
  markFinished_shouldNotUseBulk…         NeverWantedButInvoked: adviceRepository.updateAdviceToStateById(<any>, <any>)
                                         … invoked at ReturnAdviceAutoReceiveService.java:957
  applyDamage_shouldPassAdvicePositionNumber…  expected: "IBOL012604-000000" but was: null
StockunitServiceDamagedOrderNumberUnitTest
  overload test   [S3 (consult §4): StockunitService must declare setLockDamaged(…, String orderNumber)]
                  Expecting actual not to be null
  legacy test     [S3: the damaged move must gain a trailing orderNumber parameter (6 -> 7 args)]
                  Expected size: 7 but was: 6 in: ["UL-MINTED-3736", …, "RETURN DAMAGED RETURN529599_1"]
UnitloadServiceUnitTest$MoveStockToNewDamagedContainerBoundary
  [S3 (consult §4): moveStockToNewDamagedContainer must declare (…, String comment, String orderNumber)]
  Expecting actual not to be null
```

## Verdict counts

| Verdict | Count | Notes |
|---|---|---|
| **Fail for the right reason** | **33** | Every one fails at an assertion: AssertJ `AssertionError`, `AssertionFailedError`, Mockito `WantedButNotInvoked` or `NeverWantedButInvoked`. None fails on a compile error, an NPE in arrange, or an `UnnecessaryStubbingException`. |
| **Setup-adjusted** | **2** | See the two items below this table. |
| **Expected passes (by design)** | **6** | 5 GUARDs plus 1 CONTRACT PIN, each labelled in its javadoc/DisplayName. Also `thePinHasNotBeenQuietlyShrunk`, a ratchet bumped 227 → 229, which passes. |
| **Unexpected passes** | **0** | |

The two setup adjustments:

1. `receiveGoods_shouldNotRestampReceiptdate…` first errored with `UnnecessaryStubbingException`: the
   helper's create-branch stubs went unused on the reuse branch. Fixed by parameterising
   `setupHappyPathMocks`; existing callers are unchanged.
2. AC-10's `package_number` expectation was **my error**. I first asserted `sr.tounitload`. The outer
   CASE of `transaction_detail` blanks `package_number` for every row except QA and Returned (the same
   rule AC-6 pins), so the assertion is now `isEmpty()`. The consult's §4 line "package_number stays
   `sr.tounitload`" describes the inner CASE only. The visible output is `''`.

Why the 6 expected passes cannot be red pre-fix:

- **E: partial, REGULAR, position-less.** Today nothing ever finishes a RETURN advice. Each fixture
  differs from the FINISH case in **one** variable only:
  - sibling amount 3 vs 5
  - type REGULAR vs RETURN
  - empty positions

  So post-fix each guard is the only thing standing between its fixture and FINISHED. Mutation targets
  are: drop the RETURN guard; drop `positions.isEmpty()`; use `>` instead of `>=`, or ignore the sibling.
- **B: no-restamp.** Nothing stamps today.
- **C: positions bulk.** The call is already there.
- **D AC-10.** It seeds the post-S3 stockrecord shape directly. The `transaction_detail` body is
  unchanged, so it already resolves. This is the intended *contract* the customer will see; the Java
  half of S3 is red in the 4 unit tests above. I investigated it rather than weakening it.

## What missing behaviour makes each RED test fail (one line each)

- **A gate (3 + 1):** `ReportController` has no `/returnsAudit` handler, so the guard is never reached
  (404), and the context pin reports ROUTE NOT DEPLOYED for both prefixes.
- **A contract (5):** `AdvicepositionRepository` declares no `findReturnsAudit/4`, so there is no
  native query, no countQuery, no `@Param` names and no `ReturnsAuditView` to inspect.
- **A IT (15):**
  - All 15 fail because there is no query yet. Once one exists:
  - (1) needs an FK UL join plus `regexp_replace(…'-X-[0-9]+$','')` on output and on the ur join.
  - (2) needs `LEFT JOIN adviceposition` and a ≥1-position completion rule.
  - (3) needs `unitload_record` over any recordtype.
  - (4) needs a TRANSFERRED row keyed `(ordernumber, stripped label)`, with no cross-product.
  - (5) needs `substring(externalid from 7)` and `customerorder.externalnumber` → `clientordernumber`.
  - (6) needs `bool_and(Σgrp ≥ notified)` / `max(grp.created)`, never `advice.state`.
  - (7) needs `a.type='RETURN'` and `[from,to)` on `a.created`.
  - The countQuery and the projection aliases must also agree.
- **B S1:** `ReceivingService` never calls `goodsreceiptTemp.setReceiptdate(LocalDateTime.now(ZoneOffset.UTC))`.
- **C S2 (2):** `markFinished` still calls `adviceRepository.updateAdviceToStateById(FINISHED, id)`.
  It should load the advice, `setState(FINISHED)` and `saveAndFlush`.
- **D applyDamage:** it calls the 5-arg `setLockDamaged(…, null)`, so no position number reaches the
  damaged move.
- **D setLockDamaged overload:** the 6-arg `(…, Principal, String orderNumber)` overload does not exist.
- **D legacy form:** `moveStockToNewDamagedContainer` has no 7th `orderNumber` parameter for the 5-arg
  form to pass `null` into.
- **D moveStock:** the helper has no `orderNumber` parameter and passes a literal `null` to
  `transferStockToUnitLoad`.
- **E S8 (2):** `receiveGoods` has no tail finisher. A RETURN advice whose every position is received in
  full stays OPEN, along with its positions.

## Executor notes (pre-existing tests the change will move)

- **C.** `ReturnAdviceAutoReceiveServiceUnitTest$Execute.markFinishedFlipsBothPositionsAndAdviceInOneTransaction`
  pins the old `updateAdviceToStateById` call and goes red on purpose. Retarget it, and the other verify
  sites the consult §3 lists.
  - Also retarget `FileImportControllerUnitTest:1144` and `AdviceRestControllerUnitTest:593-594`, which
    are `never()` checks; otherwise they turn vacuous.
  - New S8 / S2 lenient stubs anticipate `adviceRepository.findById` + `saveAndFlush`.
- **D.** The 6 → 7 change to `moveStockToNewDamagedContainer` breaks **compilation** of these existing
  call sites:
  - Stubs/verifies: `StockunitServiceAuditCommentClampUnitTest:323,332`, `StockunitServiceUnitTest:1820,1852`.
  - Calls: `UnitloadServiceUnitTest:1996,2021,2380`.
  - Grep the other users first: `StockunitServiceParcelSourceRefusalUnitTest`,
    `StockUnitControllerUnitTest`, `StockunitDamagedRollbackIntegrationTest`.

  My new tests are arity-agnostic and stay compilable.
- **E.** The completion fixture is lenient on `findByAdviceId`, `findByAdvicepositionIdIn`,
  `findByAdvicepositionId(10L/11L)`, `adviceRepository.save` and `adviceRepository.saveAndFlush`. Any of
  those read paths satisfies it.
  - The "entity save" check accepts `save` or `saveAndFlush` called with the *same* advice instance.
  - `never()` spans use bare `any()` on boxed `(String, Long)`, so the `NeverMatcherNullBlindnessArchTest`
    inventory is unchanged; that rail was verified green.
- **Mutation-check after implementing; not doable at the gate without touching `src/main`:**
  - Drop `setState` in `markFinished` → the S2 test goes red.
  - Drop the RETURN guard → the REGULAR guard goes red.
  - Drop `isEmpty()` → the position-less guard goes red.
  - Use bare `now()` → the S1 test goes red (TZ = UTC+14).
  - Use `positionExternalId` → the applyDamage test goes red.
  - Use `ur.label = u.labelid` → the A(1) destination test goes red.
  - Use `recordtype='TRANSFERRED'` → the A(3) test goes red.
  - Use `JOIN adviceposition` → the A(2) test goes red.
  - Use `advice.state` for completion → the A(6) tests go red.
- **Arch rails over the test tree** (`*ArchTest`, `PostgresTestHarnessPinTest`, `TestIdentifierCount*`):
  143 run, 0 failures with these changes in place.

## Run commands (class form, JDK 21)

```bash
cd /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3736
export JAVA_HOME=$HOME/.sdkman/candidates/java/21.0.11-ms
export PATH=$JAVA_HOME/bin:$HOME/.sdkman/candidates/maven/current/bin:$PATH

# Unit + context lane (surefire). Comma-separated, never '+'.
mvn -o -B -ntp test \
  -Dtest='ReceivingServiceUnitTest,ReturnAdviceAutoReceiveServiceUnitTest,StockunitServiceDamagedOrderNumberUnitTest,UnitloadServiceUnitTest,ReportReadGateUnitTest,ReturnsAuditQueryContractUnitTest,Sbdev3017TrancheGateContextTest' \
  -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true

# PostgreSQL ITs (failsafe). Through `verify`, never `failsafe:integration-test`.
mvn -o -B -ntp verify \
  -Dit.test='ReturnsAuditQueryIntegrationTest,TransactionDetailReturnOrderRefsIntegrationTest' \
  -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true
```

Baseline measured:

- Surefire: 280 run in the six unit classes, 17 failures, all new tests.
- Context pin: 5 run, 1 failure.
- Failsafe: 25 run, 15 failures, all `ReturnsAuditQueryIntegrationTest`. `TransactionDetailReturnOrderRefsIntegrationTest` is 10/10 green, including AC-10.
- Plus the 3 S8/S1 red tests rerun after the helper change: 32 run in `$ReceiveGoods`, 3 failures, 0 errors.
