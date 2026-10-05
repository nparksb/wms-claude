---
ticket: SBDEV-3547
pr: B (fail-closed fence)
kind: tdd-gate-report
date: 2026-09-28
---

# SBDEV-3547 PR-B — TDD gate report

- **Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3547-b`
- **Branch:** `bugfix/SBDEV-3547-b-fence`, based on `origin/develop` `35c3428b` (PR-A merged, #429)
- **Gate commit:** `346cbee7` "SBDEV-3547 PR-B: TDD gate — failing tests + CancelLockRelease skeleton". Not pushed.
- **src/main change:** a new file only, `util/CancelLockRelease.java`. `releaseUnlessGoodsOut(Stockunit)` is null-safe on `su` and today sets `NOT_LOCKED` unconditionally, which is the current behaviour. It is **not wired** into C1/C2/C3.
- **Untouched:** the ArchUnit store, and the §7.3 flip tests (these flip in the implementation commit).

## Results

**Unit lane.** The five touched classes plus `NeverMatcherNullBlindnessArchTest` and `MoveSourceLockComparisonRailTest` ran **429 tests: 8 failures, 0 errors**, at 2026-09-28 09:01 KST.
- All 8 failures are new RED rows. Each fails at an assertion.
- The 393 tests that already existed in the touched classes all pass.
- Both arch rails pass: NeverMatcher 4/4, rail self-tests 5 + 8.

**IT lane (H2, failsafe).** 2 tests: 2 failures, 0 errors, both at step 2. Report timestamp 09:03:32.

| Class | Method | Kind | Plan row (§7.1 B) | Today |
|---|---|---|---|---|
| CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown | cancelOrder_keepsPickedForGoodsout_resetsOtherLocks | RED | fixture 100 + 104 | RED (assertion) |
| PickingorderBusinessServiceUnitTest$CleanUpCancelledOrderExtended | cleanUpCancelledOrder_keepsPickedForGoodsout | RED | same | RED (assertion) |
| CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown | forceCancelOrder_belowPacked_keepsPickedForGoodsout | RED | reflection, like AC-5 | RED (assertion) |
| CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown | forceCancelOrder_packedArm_stillClearsParcelStock_noReversalRowExists | GREEN | C4 unchanged | GREEN 1/1 |
| CancelLockReleaseUnitTest (new) | pickedForGoodsout_isKept | RED | case 100 | RED (assertion) |
| CancelLockReleaseUnitTest | nullStockunit_isTolerated, nullLock_releasedToNotLocked, notLocked_staysNotLocked, qualityFault_releasedToNotLocked, onHold_releasedToNotLocked | GREEN guards | cases null su, null lock, 0, 103, 104 | GREEN 5/5 |
| MobileMoveUnitloadServiceUnitTest$Sbdev3547CarrierArmGoodsOutFence (new nested) | scanDestination_carrierArm_refusesToteAtPickedForGoodsout | RED | delete the :512 call | RED (assertion) |
| same | scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload | RED | delete or move the :485 call | RED (assertion) |
| same | scanDestination_locationArm_stillRelocatesToteAt100 | GREEN | also check at :424 | GREEN 1/1 |
| same | scanUnitLoad_toteAt100_notRefused | GREEN | check in scanUnitLoad | GREEN 1/1 |
| same | scanDestination_carrierArm_stillMovesPackageAtPickedForGoodsout | GREEN | drop isToteType | GREEN 1/1 |
| same | scanDestination_carrierArm_toteTypeIdNull_proceedsWithWarn | GREEN | remove the null check | GREEN 1/1 |
| same | scanDestination_carrierArm_noTypeLookupWhenNo100 | GREEN | unconditional lookup | GREEN 1/1 |
| UnitloadServiceUnitTest$DeleteUnitLoad | deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend | RED | move the check after the loop | RED (assertion) |
| UnitloadServiceUnitTest$DeleteUnitLoadRecursivePreRun | deleteUnitLoadRecursivePreRun_refusesWhenChildHolds100 | RED | drop the pre-run check | RED (assertion) |
| CancelPreservesGoodsOutFenceIntegrationTest (new, H2) | cancelKeepsTheFence_handMoveRefused_completeReleases (steps 1–4) | RED at step 2 | revert C1 | RED (assertion, step 2) |
| same | cancelKeepsTheFence_waiveReleases (steps 1, 2, 5) | RED at step 2 | revert C1 | RED (assertion, step 2) |

`CancelLockReleaseUnitTest` shows as RED only on the 100 case. That is expected: the skeleton already resets every lock to 0, so the other five cases guard against over-fixing.

## Failure lines for each RED

These come from `target/surefire-reports` and `target/failsafe-reports`, with XML timestamps from this run.

| Test | Failure line |
|---|---|
| cancelOrder_keepsPickedForGoodsout_resetsOtherLocks | `:4029 [stock unit 9001: a cancel must not lower PICKED_FOR_GOODSOUT (100), the fence the pending reversal relies on] expected: 100 but was: 0` |
| forceCancelOrder_belowPacked_keepsPickedForGoodsout | `:4225 [stock unit 9001: a cancel must not lower PICKED_FOR_GOODSOUT (100), …] expected: 100 but was: 0` |
| cleanUpCancelledOrder_keepsPickedForGoodsout | `:1648 [a cancel must not lower PICKED_FOR_GOODSOUT (100), …] expected: 100 but was: 0` |
| CancelLockReleaseUnitTest.pickedForGoodsout_isKept | `:39 expected: 100 but was: 0` |
| scanDestination_carrierArm_refusesToteAtPickedForGoodsout | `:2279 java.lang.AssertionError: Expecting code to raise a throwable.` |
| scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload | `:2294 Expecting code to raise a throwable.` |
| deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend | `:1473 Expecting code to raise a throwable.` |
| deleteUnitLoadRecursivePreRun_refusesWhenChildHolds100 | `:933 Expecting code to raise a throwable.` |
| IT cancelKeepsTheFence_handMoveRefused_completeReleases | `:263->cancelAndAssertTheFenceHolds:327 [step 2: entity_lock expected 100, was 0]` |
| IT cancelKeepsTheFence_waiveReleases | `:293->cancelAndAssertTheFenceHolds:327 [step 2: entity_lock expected 100, was 0]` |

How the RED assertions are written:
- The three MMU and delete refusals use `assertThatThrownBy(...).isInstanceOf(BusinessException.class).hasMessageContaining(...)`. Neighbouring tests do the same with the 1-arg constructor, whose message is the text.
- The refusals then check `never()` with bare `any()`: `transferUnitLoadToCarrier`, `createUnitload` (with `nullable(String.class)` first, as in AC-9), `sendStockUnitToNirvana` and `sendToNirvana`.
- MMU checks that the message contains the tote label `TOTE-0042` and `Cancellation screen`.
- The delete test checks for `UL-001`, `goods-out` and `Cancellation screen`. The pre-run test checks for `goods-out` and `Cancellation screen`.

## Checking that the IT passes after the fix

A RED IT only proves step 2 today. Steps 3–5 cannot run until the fix is in, so I checked them with a **temporary** edit:
- `CancelLockRelease` was changed to keep 100.
- C1 at `CustomerorderService:1037` was changed to `toteStock.forEach(CancelLockRelease::releaseUnlessGoodsOut)`.

With that edit in place:
- **IT:** 2/2 GREEN. This covers step 3's refusal (`locked=100 (Picked)` and `Cancellation screen`, through the real `findByIdForUpdate`+`refresh`), step 4 (`completeReversal` returns the stock to the pick bin at lock 0), and step 5 (the waive releases the lock and closes both rows).
- **`CancelLockReleaseUnitTest`:** 6/6 GREEN. `cancelOrder_keepsPickedForGoodsout_resetsOtherLocks` flipped GREEN.
- **forceCancel below-PACKED test:** stayed RED. This is correct, because C3 was not wired.
- **§7.3 flips:** exactly the two tests the plan names went RED. They were `…ToteTeardown.cancelOrder_shouldClearPickedForGoodsoutOnToteStock_whenSuccessBranchHasTote:4011` (plan :4001-4014) and `CancelOrderRapidPickingScenarios.shouldSkipRapidPickingCleanupWhenNotStarted:2379` (plan :2379).

I then restored both files from copies saved before the edit. `git status` showed only the gate files. The final RED runs above were on the restored tree.

## Scaffolding adjustments, and where the plan was wrong

1. **The IT needs a `TenantContext`. The plan says it does not.**
   - The plan (§7.1 IT spec) says "`TenantContext` is null, and `CustomerorderPositionService:136-138` tolerates that".
   - The service does tolerate it. But `recordCancellation` then writes a null `facility_code`, which is NOT NULL on `customerorder_cancellation_log`.
   - The first run errored with `DataIntegrityViolation … NULL not allowed for column "facility_code"`, which is a failure for the wrong reason.
   - Fix: the IT sets `TenantContext.setCurrentTenant(new TenantProfile("localhost","develop"))` in `@BeforeEach` and clears it in `@AfterEach`. This follows `CancelOrderRollbackIntegrationTest:127/132`.
2. **The fixture sets `customerorder.historytote = <tote label>`.**
   - Without it, the post-fix IT failed at step 5 (`waive releases the fence … expected 0 but was 100`).
   - Cause: `recordCancellation` copies `tote_label_id` from `customerOrder.getHistorytote()`. On the direct cancel branch that value is still null when the rows are recorded, because teardown sets it later, at `:1059`. So `toteState` returns UNKNOWN and the waive keeps the lock.
   - In production, tote assignment writes `historytote` at pick time (`MobilePickingService:583/:1295`), so the fixture now matches the real state.
   - **Finding for the implementer:** any order that reaches `cancelOrder` with a null `historytote` would, after PR-B, be waived with its lock kept at 100 permanently. That is a strand. Whether PRD has such orders (picked, `pickingtote_id` set, `historytote` null) is unmeasured, so it is worth one DB query before release. It falls under R9/G4, not this gate.
3. **The IT seeds a real `los_sysprop` row for `ORDER_BATCH_CANCELLED_URL`.**
   - `enqueueCancellationSignal` writes `outbox_message.destination_url`, which is NOT NULL.
   - The row is get-or-create, and removed in `@AfterEach` when this class created it. The H2 database outlives the class and shares a context with `CancellationReversalLockClearIntegrationTest`.
   - `SyspropService` is not mocked. `MessageService` is the only `@MockitoBean`, as specified.
4. **Other IT fixture details.**
   - Get-or-create once per context: `Clearing`, `EmptyTotes`, `Spawn` and `Nirwana` (location plus unit load), and the `Tote`/`Case` types, unsuffixed with the precedent's externalIds.
   - Everything else is `RUN`-suffixed.
   - The UNIT_LOAD sequence row uses insert-if-absent.
   - Step 2 reads with the context's `JdbcTemplate` bean. In the H2 lane the tenant and landlord datasources are the same (see `TestDatabaseConfig`).
5. **`forceCancelOrder_packedArm_…_noReversalRowExists`.**
   - `CancellationLogService` is not mocked in `CustomerorderServiceUnitTest`: `@InjectMocks` passes null to the constructor.
   - So a cancellation-log write on this path would NPE. That is how "no reversal row" is enforced; the javadoc says so. There is no `never()` verify.
6. **Stubs that go unused after the fix are `lenient()`.**
   - Delete test: `itemdataService.getById` and `sharedService.getStockChangeDTO` (in a `STRICT_STUBS` class) are reached only by today's loop.
   - Pre-run test: `stockunitRepository.findByUnitloadIdIn(anyCollection())` (the fence's F7 read) and the fixed-assignment stub.
   - Strict stubbing therefore cannot turn the post-fix GREEN into an `UnnecessaryStubbing` failure.
7. **The delete test puts an unlocked stock unit first and the 100 unit second.** This way, a check placed inside the loop (after the first `sendStockUnitToNirvana`) is also caught.
8. **All Mockito `never()` calls use bare `any()`.** No primitive parameter is widened.

## Plan sites, re-located by quoted snippet in the worktree

None of them moved; every one matches the plan's line number.

| Site | Now |
|---|---|
| C1 `toteStock.forEach(su -> …NOT_LOCKED)` / `saveAll(toteStock)` | `CustomerorderService:1037` / `:1038` |
| C2 `stockUnits.forEach(su -> …NOT_LOCKED)` / `saveAll(stockUnits)` | `PickingorderBusinessService:701` / `:702` |
| C3 per-row lambda (below-PACKED force-cancel) | `CustomerorderService:490-493` (setEntityLock at `:491`) |
| C4 PACKED arm stock clear | `CustomerorderService:524` |
| MMU source `findByLabelidForUpdate` | `MobileMoveUnitloadService:336` |
| MMU `stockUnitList` | `:363` |
| MMU location-arm `assertSourceCarrierNotOnTruck` | `:424` |
| MMU inbound-pattern `assertSourceCarrierNotOnTruck` (under `!isMoveStock`) | `:485` |
| MMU `createUnitload` | `:492` |
| MMU carrier-arm `assertSourceCarrierNotOnTruck` | `:512` |
| MMU `transferUnitLoadToCarrier` | `:514` |
| `SourceContainerGuard.judge` | `:129` (`typeId == null` at `:131`) |
| `UnitloadService.deleteUnitLoad` | `:570`; To-Delete throw `:584`; child throw `:590`; SU list `:593`; loop `:596` |
| `deleteUnitLoadRecursivePreRun` | `:427`; top branch `if (unitLoadList == null)` `:430` |
| `StockunitRepository.findByUnitloadIdIn` | `:426` |

Plan B-3 cites "`StockunitRepository.findByUnitloadIdIn` (:426)". That line is in the **repository**. The pre-run does not call it today, so the implementation adds the call. That still meets F7: no new persistence surface.

## Commands used

The environment for every run was `JAVA_HOME=…/ms-21.0.8`, with Maven taken from sdkman. Each run was preceded by `pgrep -fl plexus-classworlds`, and no other Maven process was running at any point.

```bash
mvn -o -q test-compile
mvn -o test -Dtest='CancelLockReleaseUnitTest,CustomerorderServiceUnitTest,PickingorderBusinessServiceUnitTest,MobileMoveUnitloadServiceUnitTest,UnitloadServiceUnitTest,NeverMatcherNullBlindnessArchTest,MoveSourceLockComparisonRailTest'
mvn -o verify -Dit.test=CancelPreservesGoodsOutFenceIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true
```

- **@Nested classes** were run in class form, and I confirmed each new method appears once in the XML: the GREENs have ran=1 and fail=0.
- **Not run:** Docker/Testcontainers ITs and the full suite. Both are left to `wms-plan-executor`, whose baseline must be adjacent in time.
- **Noise:** each IT log contains `Syntax error … create table tenant_discovery (… key varchar …)` from H2 DDL. It is pre-existing context-start output in this lane and not related to this change.

## Test files

- `src/main/java/net/aim_ai/wms/util/CancelLockRelease.java` (new skeleton)
- `src/test/java/net/aim_ai/wms/unit/util/CancelLockReleaseUnitTest.java` (new)
- `src/test/java/net/aim_ai/wms/integration/service/CancelPreservesGoodsOutFenceIntegrationTest.java` (new)
- `src/test/java/net/aim_ai/wms/unit/service/CustomerorderServiceUnitTest.java` (+3 tests in `Sbdev3339_CancelOrderToteTeardown`)
- `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java` (+1 in `CleanUpCancelledOrderExtended`)
- `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileMoveUnitloadServiceUnitTest.java` (new nested `Sbdev3547CarrierArmGoodsOutFence`, 7 tests)
- `src/test/java/net/aim_ai/wms/unit/service/UnitloadServiceUnitTest.java` (+1 in `DeleteUnitLoad`, +1 in `DeleteUnitLoadRecursivePreRun`)

## Orchestrator re-verification (2026-09-28)
- **Independent re-run in the worktree at `346cbee7`:** 429 unit tests, 8 failures, 0 errors, and the failures are exactly the 8 new RED rows. The IT gives 2/2 `[step 2: entity_lock expected 100, was 0]`. The five REDs with blank summary lines are AssertJ `Expecting code to raise a throwable` (the delete and MMU refusals), plus `expected: 100 but was: 0` from `CancelLockReleaseUnitTest`. All of them fail for the right reason.
- **The `historytote` strand finding, measured on PRD** (read-only):
  - Query: `pickingtote_id IS NOT NULL AND historytote IS NULL`, plus `reversal_required AND tote_label_id IS NULL`.
  - Result: **0 on all 4 tenants.**
  - Positive controls: orders holding a tote were c1wh 1, Hydra 1, WineCo 60, nywh-ShipItEZ 0; cancellation-log rows were 4, 17, 2 and 0.
  - Verdict: latent, not live. It stays under R9/G4 and is not a PR-B blocker.
