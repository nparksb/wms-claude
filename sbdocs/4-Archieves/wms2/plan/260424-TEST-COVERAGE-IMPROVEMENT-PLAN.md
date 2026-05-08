# Test Coverage Improvement Plan

## Current State (Feb 27, 2026)

| Metric | Baseline | After Phase 1 | After Phase 2 | After Phase 3+4 | Target |
|--------|----------|---------------|---------------|-----------------|--------|
| **Line Coverage** | 77.2% (18,661 / 24,169) | **78.6%** (19,001 / 24,167) | **78.7%** (19,023 / 24,167) | **83.2%** (20,127 / 24,167) | **78%+** |
| Instruction Coverage | 73.6% (87,641 / 119,105) | 74.8% | 75.0% (89,295 / 119,105) | **79.3%** (94,520 / 119,105) | — |
| Branch Coverage | 67.6% (4,503 / 6,666) | 68.9% | 68.9% (4,592 / 6,666) | **72.2%** (4,817 / 6,666) | — |
| Total Tests | 3,276 | 3,319 (+43) | 3,332 (+13) | **3,619** (+287) | — |

**Phase 1 — COMPLETE** (commit `53247ff`): +335 lines, +43 tests. Target of 78% **MET**.
**Phase 2 — COMPLETE** (commit `fb62669`): +22 lines, +13 tests. New commit functionality covered.
**Phase 3 — COMPLETE**: +23 controller test files, ~250 tests. Controller coverage 54% → 85%.
**Phase 4 — COMPLETE**: +4 utility/infrastructure test files, ~37 tests. Utility coverage 39% → 74%.

## Scope

All commits after **February 4th, 2026** (~70 commits). Key categories:

- **New features**: OMS palletized/loaded-to-truck notifications, order_loaded_to_truck dashboard
- **Bug fixes**: Receiving concurrency, replenishment poison-pill, picking finish state, StaleObjectStateException
- **Performance**: closeBOL optimization, picking 60-80% query reduction, receiveGoods optimization, AdviceService bulk JPQL
- **Modernization**: Constructor injection (130 files), Object[] to projections (22 repos), RestTemplate to RestClient, javax to jakarta

## Per-Package Coverage

| Package | Instruction Cov. | Biggest Gaps |
|---------|-----------------|--------------|
| `service` | 79% | ReceivingService (11%), HttpRestService (10%) |
| `service.mobile` | 73% | — |
| `service.job` | 64% | ReleaseOrderJobService, ReplenishOrderJobService |
| `controller` | **54%** | 26 controllers have NO test file |
| `controller.rest` | 80% | — |
| `controller.mobile` | 82% | — |
| `schedulejob` | 65% | SchedulingConfiguration (0%) |
| `util` | 39% | InMemoryLocationComparator (7%), OptimisticLockRetry |
| Root (`net.aim_ai.wms`) | 45% | SecurityConfiguration (14%), CustomMethodSecurityExpressionRoot (0%) |

---

## Phase 1: Quick Wins — Reach 78% (Priority: HIGH) — COMPLETE

**Status:** DONE (commit `53247ff`) — +335 lines, +43 tests, 77.2% → 78.6%

### 1.1 ReceivingService — DONE (+30 tests, 7 → 37)

- `ReceivingServiceUnitTest.java` expanded with 6 new nested classes
- Covers: `receiveGoods()` happy path, RETURN type, pessimistic lock, checked exceptions, `createAdviceWithPositions()`, `updateAdviceWithPositions()`, `updatePallet()`, `assignPallet()`, `unassignPallet()`
- Manual constructor (no @InjectMocks) due to duplicate `UnitloadBusinessService` params

### 1.2 HttpRestService — DONE (+7 tests, new file)

- `HttpRestServiceUnitTest.java` created with 7 tests
- Covers: `post()`, `get()`, `applyHeaders()` (Basic Auth, x-tenant, null credentials)
- Uses `ReflectionTestUtils.setField` to inject mock RestClient

### 1.3 DashboardController — DONE (+10 tests, new file)

- `DashboardControllerUnitTest.java` created with 10 tests
- Covers: all 6 endpoints + 3 error paths for `printToteLabels`

---

## Phase 2: Cover New Functionality from Feb 4+ Commits (Priority: MEDIUM) — COMPLETE

**Status:** DONE (commit `fb62669`) — +13 tests, 78.6% → 78.7%
**Focus:** Targeted tests for specific commit functionality rather than raw line coverage.

### 2.1 Replenishment Poison-Pill Fix (commit `34a8062`) — DONE (+3 tests)

- `ReplenishGeneratorServiceUnitTest.java` — added `RefillSingleFixedLocation` nested class
- Covers: happy path, FLA not found (EntityNotFoundException), unitload not found

### 2.2 Picking Performance Optimization (commit `33eb874`) — SKIPPED

- `PickingOrderMergeService` (5 tests) and `PickingorderBusinessService` (23 tests) already have adequate coverage
- OMS notification trigger already tested (4 tests for `releaseRegularPickingOrder`)
- Deferred to Phase 3/4 if more coverage needed

### 2.3 CustomerorderBatchService Fixes (commits `073083c`) — DONE (+2 tests)

- `CustomerorderBatchServiceUnitTest.java` — added to `ActivateOrderBatch` nested class
- Covers: re-fetch by ID verification (stale vs fresh batch), EntityNotFoundException on missing batch
- Note: `calculateUnitLoadAmounts()` is private — tested indirectly through public methods

### 2.4 AdviceService Fixes (commits `9ff08be`, `6ba599e`) — DONE (+2 tests)

- `AdviceServiceUnitTest.java` — added to `CloseSuccessPath` nested class
- Covers: batch pre-fetch verification (findAllById + findByAdvicepositionIdIn, no N+1), date formatting (LocalDate with DateTimeFormatter)

### 2.5 Receiving Controller Hardening (commit `d44ac7d`) — DONE (+6 tests)

- `ReceivingControllerUnitTest.java` — added `RuntimeExceptionHandling` nested class
- Covers: RuntimeException catch blocks on all 6 endpoints (setPallet, createAndSelectPallet, createPallet, unlinkSelectedPallet, updatePallet, receive)

---

## Phase 3: Untested Controllers (Priority: MEDIUM-LOW) — COMPLETE

**Status:** DONE — +23 controller test files, ~250 tests. Controller coverage 54% → 85%.
**Pattern:** Mock service layer, verify delegation. Each controller test covers ~50-100 lines.

### 3.1 High-Impact Controllers (>200 lines)

| Controller | Lines | Missed Instructions |
|-----------|-------|-------------------|
| `PrinterController` | 282 | 584 |
| `AdminController` | 366 | 541 |
| `UnitLoadController` | 229 | 530 |
| `FixLocationAssignmentController` | 210 | 440 |
| `CycleCountController` | 206 | 356 |
| `SystemPropertyController` | 148 | 319 |
| `ItemDataController` | 191 | 287 |
| `TokenController` | 195 | 249 |
| `ShipperIdController` | 130 | 216 |

### 3.2 Medium-Impact Controllers (100-200 lines)

| Controller | Lines |
|-----------|-------|
| `GoodsReceiptPositionController` | 126 |
| `MessageController` | 96 |
| `UserGroupController` | 124 |
| `UserRoleController` | 111 |
| `AdminActionController` | 146 |
| `DashboardController` | 116 |
| `CustomerOrderBatchController` | 96 |

### 3.3 Low-Impact Controllers (<100 lines)

| Controller | Lines |
|-----------|-------|
| `SectionController` | 83 |
| `PickingOrderPositionController` | 75 |
| `TenantHealthController` | 66 |
| `SystemController` | 59 |
| `LocationController` | 53 |
| `MessageDummyController` | 47 |
| `StockRecordController` | 38 |
| `UnitloadRecordController` | 38 |
| `AbstractRestController` | 29 |

---

## Phase 4: Infrastructure & Utility Coverage (Priority: LOW) — COMPLETE

**Status:** DONE — +4 test files (~37 tests). Utility coverage 39% → 74%.
**Goal:** Cover remaining low-coverage infrastructure classes.

### 4.1 Utility Classes

- `InMemoryLocationComparator` (7% covered, 193 missed) — comparison logic tests
- `OptimisticLockRetry` — retry template behavior tests
- `CycleCountStrategy` — strategy pattern tests

### 4.2 Security & Config

- `SecurityConfiguration` (14%) — security filter chain tests
- `CustomMethodSecurityExpressionRoot` (0%) — expression evaluation tests

### 4.3 Scheduled Jobs

- `SchedulingConfiguration` (0%) — cron task registration tests
- `StockSummaryExportJob` — export execution tests

---

## Summary

| Phase | Effort | Tests Added | Line Coverage | Status |
|-------|--------|-------------|---------------|--------|
| **Phase 1** | ~2 hrs | +43 | 77.2% → **78.6%** (+335 lines) | **COMPLETE** `53247ff` |
| **Phase 2** | ~1 hr | +13 | 78.6% → **78.7%** (+22 lines) | **COMPLETE** `fb62669` |
| **Phase 3** | ~2 hrs | +250 | 78.7% → **83.2%** (+1,104 lines) | **COMPLETE** |
| **Phase 4** | ~1 hr | +37 | (included in Phase 3 run) | **COMPLETE** |
| **Total** | — | **+343** | 77.2% → **83.2%** (+6.0pp) | **ALL COMPLETE** |

## Test Patterns

All new tests should follow the existing project patterns:

- **Unit tests**: `@ExtendWith(MockitoExtension.class)`, `@Mock`, `@InjectMocks`
- **Naming**: `{ClassName}UnitTest.java` in `src/test/java/net/aim_ai/wms/unit/`
- **Structure**: `@Nested` classes with `@DisplayName` per method group
- **Assertions**: AssertJ (`assertThat(...)`)
- **Controllers**: Mock `@WebMvcTest` or pure unit test with mocked services
- **MockedStatic**: Mockito 5.2.0 supports `MockedStatic` (upgraded from 3.3.3)
- **Base classes**: `BaseServiceUnitTest` (provides `@ExtendWith`), `BaseControllerUnitTest` (provides `setupMockMvc()`, `toJson()`)

## Lessons Learned

- **Duplicate constructor params**: `@InjectMocks` fails when two params have the same type (e.g., `ReceivingService` has two `UnitloadBusinessService` params). Solution: manual construction in `setUp()`.
- **Lenient stubs**: When `setUp()` stubs are not used in all test branches, use `lenient().when(...)` to avoid `UnnecessaryStubbingException`.
- **RestClient testing**: `RestClient` is built internally — use `ReflectionTestUtils.setField()` to inject a mock after construction.
- **Private methods**: `calculateUnitLoadAmounts()` is private — test indirectly through public methods.

## Pre-existing Test Issues

- **Stale class file**: `OptimisticLockRetryTemplateTest.class` in `target/test-classes` references `javax.persistence.OptimisticLockException`. Fixed by `mvn clean`. Root cause: deleted/renamed test source file left a compiled artifact.

## Commits Reviewed (Since Feb 4, 2026)

| Commit | Description | Tests Exist? | Phase |
|--------|------------|-------------|-------|
| `7ffdbe2` | order_loaded_to_truck propagation | YES | — |
| `3da078a` | OMS palletized/loaded-to-truck notifications | YES (49 tests in ManageOrderServiceUnitTest) | — |
| `74f3c22` | remove parallelStream in calculateUnitLoadAmounts | Partial (private method, tested indirectly) | P2 |
| `073083c` | resolve StaleObjectStateException in activateOrderBatch | **YES** — re-fetch + EntityNotFound tests added | P2 |
| `46392fe` | optimize view endpoints and batch OMS operations | Partial | — |
| `34a8062` | replenishment poison-pill fix | **YES** — 3 tests for `refillSingleFixedLocation` added | P2 |
| `49f870b` | finished picking: CO state eval, optimistic lock | YES (4 tests for `releaseRegularPickingOrder`) | — |
| `33eb874` | picking performance 60-80% query reduction | Partial (PickingOrderMergeService 5 tests) | — |
| `9ff08be` | AdviceService.close() DateTimeFormatter fix | **YES** — date formatting test added | P2 |
| `d44ac7d` | harden receiving controller | **YES** — 6 RuntimeException tests added | P2 |
| `07099b9` | receiving: RuntimeExceptions to checked | **YES** — covered by Phase 1 receiveGoods tests | P1 |
| `6ba599e` | AdviceService bulk JPQL optimization | **YES** — batch pre-fetch verification test added | P2 |
| `f21a588` | receiving concurrency pessimistic lock | **YES** — covered by Phase 1 receiveGoods tests | P1 |
| `0b6262d` | receiveGoods optimization | **YES** — covered by Phase 1 receiveGoods tests | P1 |
| `630d24a` | receiving Phase 1 fixes | **YES** — covered by Phase 1 receiveGoods tests | P1 |
| `128a15d` | Object[] to projections (22 repos) | YES (ViewDtoServiceUnitTest covers projections) | — |
| `c066b56` | constructor injection (130 files) | Covered by existing tests | — |
| `ed8d89e` | RestTemplate to RestClient | **YES** — 7 tests in HttpRestServiceUnitTest | P1 |
| Concurrency phases 1-4 | Pessimistic locks, retries, thread safety | **YES** — Phase 1 ReceivingService tests | P1 |
| closeBOL phases A-D | Bulk operations, optimization | YES (56 tests in BillofladingServiceUnitTest) | — |
| Entity comparison fixes | equals/hashCode on all entities | YES (EntityEqualsHashCodeContractTest) | — |
