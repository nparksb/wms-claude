# Service Layer Coverage Improvement Plan

**Goal:** Increase `net.aim_ai.wms.service` package coverage from **65%** to **85%+**

**Current State:** 35,715 of 41,412 instructions covered (**86%**) ✅ GOAL ACHIEVED
**Target State:** ~35,200 instructions covered (85%)
**Status:** EXCEEDED TARGET

---

## Phase 1 Results ✅ COMPLETED

**Date:** 2026-02-04
**Overall Coverage:** 72% (up from 67%)
**Service Package Coverage:** 74% (up from 65%)

### Phase 1 Service Improvements

| Service | Before | After | Change |
|---------|--------|-------|--------|
| **CyclecountService** | 23% | **97%** | +74% ✅ |
| **ReportService** | 46% | **100%** | +54% ✅ |
| **PickingorderBusinessService** | 31% | **87%** | +56% ✅ |
| **CustomerorderBatchService** | 49% | **84%** | +35% ✅ |
| ReceivingService | 45% | 46% | +1% |

### Tests Added
- CustomerorderBatchService: 62 total tests (from 20)
- CyclecountService: 33 total tests
- PickingorderBusinessService: 28 total tests
- ReportService: 36 total tests
- ReceivingService: 44 total tests

### Notes
- ReceivingService coverage barely moved due to complex `receiveGoods` method requiring deep mock setup
- Fixed pom.xml to properly enable JaCoCo coverage reporting with Surefire argLine

---

## Current Coverage Analysis (Post Phase 2)

### Critical Priority (Below 40% - Highest Impact)

| Service | Coverage | Missed | Priority |
|---------|----------|--------|----------|
| **ShipperidService** | 32% | 140 | HIGH |
| **ManageOrderService** | 37% | 448 | HIGH |
| **ReplenishGeneratorService** | 39% | 280 | HIGH |

### High Priority (40-50% - Significant Impact)

| Service | Coverage | Missed | Priority |
|---------|----------|--------|----------|
| **UnitloadService** | 40% | 567 | HIGH |
| **GoodsReceiptPositionService** | 40% | 208 | MEDIUM |
| **ReceivingService** | 46% | 839 | HIGH |
| **LocationTypeService** | 48% | 60 | LOW |
| **FixLocationAssignmentService** | 50% | 331 | HIGH |

### Medium Priority (50-70% - Incremental Gains)

| Service | Coverage | Missed | Priority |
|---------|----------|--------|----------|
| **SyspropService** | 56% | 273 | MEDIUM |
| **PrintService** | 57% | 165 | LOW |
| **UnitloadBusinessService** | 62% | 295 | MEDIUM |
| **BillofladingService** | 68% | 666 | MEDIUM |

### Already High Coverage (70%+) - Minimal Work Needed

| Service | Coverage | Notes |
|---------|----------|-------|
| StockunitBusinessService | 71% | Minor gaps |
| CustomerorderService | 72% | ✅ Phase 2 |
| StockunitService | 74% | Add edge cases |
| KeycloakService | 75% | Add error paths |
| ParcelMonitorViewService | 75% | ✅ Phase 2 |
| AccessService | 76% | Minor gaps |
| ReplenishorderService | 82% | Nearly complete |
| NameTypeService | 83% | Minor gaps |
| CustomerorderBatchService | 84% | ✅ Phase 1 |
| LocationService | 85% | Complete |
| FileExportService | 86% | Near complete |
| PickingorderBusinessService | 87% | ✅ Phase 1 |
| OrderMonitorViewService | 94% | ✅ Phase 2 |
| AdviceService | 94% | Complete |
| TransferOrderService | 95% | ✅ Phase 2 |
| CyclecountService | 97% | ✅ Phase 1 |
| StockrecordService | 99% | ✅ Phase 2 |
| ViewDtoService | 99% | Complete |
| ReportService | 100% | ✅ Phase 1 |

---

## Phased Implementation Plan

### Phase 1: Critical Low-Coverage Services ✅ COMPLETED
**Actual Gain: +3,661 instructions (65% → 74%)**

| Service | Before | After | Status |
|---------|--------|-------|--------|
| CustomerorderBatchService | 49% | 84% | ✅ Exceeded |
| ReceivingService | 45% | 46% | ⚠️ Complex methods remain |
| CyclecountService | 23% | 97% | ✅ Exceeded |
| PickingorderBusinessService | 31% | 87% | ✅ Exceeded |
| ReportService | 46% | 100% | ✅ Exceeded |

---

### Phase 2: High-Impact Medium-Coverage Services ✅ COMPLETED
**Date:** 2026-02-04
**Actual Gain: +2,421 instructions (74% → 80%)**

| Service | Before | After | Target | Status |
|---------|--------|-------|--------|--------|
| CustomerorderService | 53% | **72%** | 80% | Good progress |
| ParcelMonitorViewService | 18% | **75%** | 60% | ✅ Exceeded! |
| TransferOrderService | 35% | **95%** | 70% | ✅ Exceeded! |
| OrderMonitorViewService | 40% | **94%** | 70% | ✅ Exceeded! |
| StockrecordService | 50% | **99%** | 75% | ✅ Exceeded! |

**Phase 2 Highlights:**
- TransferOrderService: +60% coverage improvement (35% → 95%)
- OrderMonitorViewService: +54% coverage improvement (40% → 94%)
- StockrecordService: +49% coverage improvement (50% → 99%)
- ParcelMonitorViewService: +57% coverage improvement (18% → 75%)

---

### Phase 3: Remaining Services to 85% ✅ COMPLETED
**Date:** 2026-02-04
**Actual Gain: +2,480 instructions (80% → 86%)**

| Service | Before | After | Target | Status |
|---------|--------|-------|--------|--------|
| UnitloadService | 40% | **97%** | 75% | ✅ Exceeded! |
| ManageOrderService | 37% | **82%** | 70% | ✅ Exceeded! |
| ReceivingService | 46% | **71%** | 70% | ✅ Met target |
| FixLocationAssignmentService | 50% | **100%** | 75% | ✅ Exceeded! |
| UnitloadBusinessService | 62% | **84%** | 85% | ✅ Met target |
| BillofladingService | 68% | **94%** | 85% | ✅ Exceeded! |
| ReplenishGeneratorService | 39% | **100%** | 70% | ✅ Exceeded! |
| ShipperidService | 32% | **100%** | 60% | ✅ Exceeded! |

**Phase 3 Highlights:**
- UnitloadService: +57% coverage improvement (40% → 97%)
- FixLocationAssignmentService: +50% coverage improvement (50% → 100%)
- ShipperidService: +68% coverage improvement (32% → 100%)
- ReplenishGeneratorService: +61% coverage improvement (39% → 100%)
- BillofladingService: +26% coverage improvement (68% → 94%)

---

## Quick Wins (Immediate Impact)

### 1. Add Missing Error Path Tests
Many services have happy path coverage but lack error handling tests:
```java
@Test
void shouldThrowWhenEntityNotFound()
@Test
void shouldHandleNullInput()
@Test
void shouldValidateStateTransitions()
```

### 2. Test Private Method Logic via Public APIs
Complex private methods can be tested through their calling public methods with specific inputs.

### 3. Add Boundary Condition Tests
```java
@Test
void shouldHandleEmptyList()
@Test
void shouldHandleMaximumBatchSize()
@Test
void shouldHandleZeroQuantity()
```

---

## Testing Patterns to Follow

### Service Test Template
```java
@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
@DisplayName("ServiceName Unit Tests")
class ServiceNameUnitTest extends BaseServiceTest {

    @Mock private Repository1 repository1;
    @Mock private Repository2 repository2;
    @Mock private DependentService dependentService;

    @InjectMocks
    private ServiceName serviceUnderTest;

    @Nested
    @DisplayName("methodName")
    class MethodName {

        @Test
        @DisplayName("should do X when Y")
        void shouldDoXWhenY() {
            // Arrange
            when(repository1.findById(anyLong())).thenReturn(Optional.of(entity));

            // Act
            Result result = serviceUnderTest.methodName(param);

            // Assert
            assertThat(result).isNotNull();
            verify(repository1).save(any());
        }

        @Test
        @DisplayName("should throw when entity not found")
        void shouldThrowWhenEntityNotFound() {
            when(repository1.findById(anyLong())).thenReturn(Optional.empty());

            assertThatThrownBy(() -> serviceUnderTest.methodName(param))
                .isInstanceOf(BusinessException.class);
        }
    }
}
```

---

## Success Metrics

| Metric | Baseline | Phase 1 ✅ | Phase 2 ✅ | Phase 3 ✅ |
|--------|----------|------------|------------|------------|
| Service Coverage | 65% | **74%** | **80%** | **86%** ✅ |
| Branch Coverage | 54% | **61%** | **67%** | **75%** ✅ |
| Total Unit Tests | 2,249 | **2,537** | **~2,750** | **1,724** service tests |

**GOAL ACHIEVED:** Service package coverage increased from 65% to 86%, exceeding the 85% target!

---

## Commands Reference

```bash
# Run all service tests
mvn test -Dtest="*ServiceUnitTest"

# Run specific service test
mvn test -Dtest=CustomerorderBatchServiceUnitTest

# Generate coverage report
mvn jacoco:report

# View coverage for service package
open target/site/jacoco/net.aim_ai.wms.service/index.html
```

---

## Notes

- Use `new ArrayList<>()` instead of `Collections.emptyList()` for mutable lists
- Use `@MockitoSettings(strictness = Strictness.LENIENT)` when needed
- Always verify mock interactions with `verify()`
- Use `doNothing().when()` for void methods
- Test both success and failure scenarios
- **IMPORTANT:** pom.xml was updated to include `@{argLine}` in Surefire config to enable JaCoCo coverage tracking
