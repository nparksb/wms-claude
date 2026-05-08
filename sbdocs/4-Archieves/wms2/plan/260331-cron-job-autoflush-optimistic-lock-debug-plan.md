# Migration Plan: Cron Job Auto-Flush Optimistic Lock Fixes (v1 -> v2)

**Date:** 2026-04-01
**Source Plan:** `docs/plan/v1-fixes/260331-cron-job-autoflush-optimistic-lock-debug-plan.md`
**Source Branch:** `release-260327` (wms-api v1)
**Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api v2)
**Priority:** High

---

## 1. Migration Analysis Summary

| v1 Fix | v2 Status | Action Required |
|:-------|:----------|:----------------|
| **Fix A**: Cache `showLog()` with 30s volatile TTL | **Superseded** — v2 uses `@Cacheable` on `SyspropService.getSysvalue()` (5-min TTL via CacheConfig) | None |
| **Fix B**: Catch `OptimisticLockingFailureException` in cron jobs | **NOT applied** — v2 catches only `jakarta.persistence.OptimisticLockException` | **Must apply** |
| **Fix C**: Add `@Transactional` to `recalculateOpenOrders()` | **Already applied** with correct `tenantTransactionManager` | None |

**Additional findings:**
- `BasicServiceUnitTest.java:372-385` — broken test (expects `-1L` return + `atLeast(50)` retries, but v2 code throws `RuntimeException` after 5 retries)
- Existing `ReplenishOrderJobTest.java` only tests `jakarta.persistence.OptimisticLockException` — needs parallel tests for `OptimisticLockingFailureException`

---

## 2. Detailed Analysis

### Fix A: `showLog()` Caching — NOT NEEDED

**v1 approach:** Volatile field cache with 30s TTL in `BasicService.java`
```java
private volatile Boolean showLogCache = null;
private volatile long showLogCacheTime = 0;
private static final long SHOW_LOG_CACHE_TTL_MS = 30_000;
```

**v2 approach (already in place):** `BasicService.showLog()` at line 161 delegates to `syspropService.getSysvalue()`, which has `@Cacheable(value = "sysprops", ...)` at `SyspropService.java:285`. The `sysprops` cache is configured in `CacheConfig.java:24` with:
- `maximumSize`: 200 entries
- `expireAfterAccess`: 5 minutes

**Why v2's approach is sufficient:**
- `@Cacheable` prevents repeated native query execution (the root cause of auto-flush triggers in v1)
- The native query in `SyspropRepository.findSysvalueBySyskey()` is only executed once per 5-minute window per tenant, eliminating the auto-flush storm
- The 5-min TTL is longer than v1's 30s, but `showLog` is a debug toggle — delayed effect is acceptable
- Cache is properly evicted on writes via `@CacheEvict` in `SyspropService.createSystemProperty()`

**Verdict:** No migration needed. The v2 `@Cacheable` approach is architecturally superior.

### Fix B: Exception Catch Type Mismatch — MUST APPLY

**Problem:** Spring's `PersistenceExceptionTranslationInterceptor` (present on all `@Repository` proxies) translates Hibernate's `StaleObjectStateException` to `org.springframework.dao.OptimisticLockingFailureException`, NOT to `jakarta.persistence.OptimisticLockException`. The current v2 catch blocks only catch the JPA type, so Spring-translated exceptions escape and abort the cron job iteration.

This is the same bug as v1, with only the package name changed (`javax.persistence` -> `jakarta.persistence` in Spring Boot 3).

**Files and lines affected:**

| File | Line | Current Catch | Required Change |
|:-----|:-----|:-------------|:---------------|
| `OrderReleaseJob.java` | 19 | `import jakarta.persistence.OptimisticLockException` | Add `import org.springframework.dao.OptimisticLockingFailureException` |
| `OrderReleaseJob.java` | 285 | `catch (OptimisticLockException \| FacadeException \| BusinessException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException \| FacadeException \| BusinessException e)` |
| `ReplenishOrderJob.java` | 16 | `import jakarta.persistence.OptimisticLockException` | Add `import org.springframework.dao.OptimisticLockingFailureException` |
| `ReplenishOrderJob.java` | 305 | `catch (OptimisticLockException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException e)` |
| `ReplenishOrderJob.java` | 339 | `catch (OptimisticLockException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException e)` |
| `ReplenishOrderJob.java` | 374 | `catch (OptimisticLockException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException e)` |
| `ReplenishOrderJob.java` | 393 | `catch (OptimisticLockException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException e)` |
| `ReplenishOrderJob.java` | 424 | `catch (OptimisticLockException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException e)` |
| `ReplenishOrderJob.java` | 444 | `catch (OptimisticLockException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException e)` |
| `ReplenishOrderJob.java` | 462 | `catch (OptimisticLockException e)` | `catch (OptimisticLockException \| OptimisticLockingFailureException e)` |

**Note:** `org.springframework.dao.OptimisticLockingFailureException` is the same class in both Spring Boot 2 and 3 — no package migration needed.

### Fix C: `@Transactional` on `recalculateOpenOrders()` — ALREADY APPLIED

**v2 status:** Both overloads and related methods in `ReplenishmentOrderMaintenanceService.java` are correctly annotated:
- Line 68-69: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` on `recalculateOpenOrders()`
- Line 73-74: Same annotation on `recalculateOpenOrders(boolean force)`
- Line 96-97: Same annotation on `recalculateForItem()`
- Line 119-120: Same annotation on `recalculateOrder(Replenishorder)`

This was implemented correctly with the v2-specific `tenantTransactionManager` requirement. No action needed.

---

## 3. Additional Fix: Broken `BasicServiceUnitTest`

**File:** `src/test/java/net/aim_ai/wms/unit/service/BasicServiceUnitTest.java:372-385`

**Current test (broken):**
```java
@Test
@DisplayName("should return -1 when sequence service fails max times")
void shouldReturnNegativeWhenSequenceServiceExceedsMaxRetries() {
    when(sequenceTransactionService.getNextSequenceNumber("TEST"))
        .thenThrow(new ObjectOptimisticLockingFailureException("test", null));

    long result = basicService.getNextSequenceNumber("TEST");

    assertThat(result).isEqualTo(-1L);
    verify(sequenceTransactionService, atLeast(50)).getNextSequenceNumber("TEST");
}
```

**Why it's broken:**
1. v2 `BasicService.getNextSequenceNumber()` (line 151-155) now **throws `RuntimeException`** after exhausting retries, instead of returning `-1`
2. v2 `maxTries` was reduced from 100 to 5 (line 112), but the test asserts `atLeast(50)` invocations

**Required fix:**
```java
@Test
@DisplayName("should throw RuntimeException when sequence service fails max times")
void shouldThrowWhenSequenceServiceExceedsMaxRetries() {
    when(sequenceTransactionService.getNextSequenceNumber("TEST"))
        .thenThrow(new ObjectOptimisticLockingFailureException("test", null));

    assertThatThrownBy(() -> basicService.getNextSequenceNumber("TEST"))
        .isInstanceOf(RuntimeException.class)
        .hasMessageContaining("Exceeded maxTries=5");

    verify(sequenceTransactionService, times(5)).getNextSequenceNumber("TEST");
}
```

---

## 4. Test Plan

### 4.1 New Tests for Fix B — `OptimisticLockingFailureException` Handling

**ReplenishOrderJobTest.java** — add parallel tests for each existing `OptimisticLockException` test:

| Existing Test (jakarta OLE) | New Test (Spring OLFE) | Location |
|:---------------------------|:----------------------|:---------|
| `shouldHandleOptimisticLockExceptionAndContinue` (line 490) | `shouldHandleSpringOptimisticLockingFailureExceptionAndContinue` | Same nested class |
| `shouldHandleOptimisticLockExceptionAndContinue` (line 649) | `shouldHandleSpringOptimisticLockingFailureExceptionAndContinue` | Same nested class |
| `shouldHandleOptimisticLockExceptionGracefully` (line 733) | `shouldHandleSpringOptimisticLockingFailureExceptionGracefully` | Same nested class |
| `shouldHandleOptimisticLockExceptionFromTrigger` (line 796) | `shouldHandleSpringOptimisticLockingFailureExceptionFromTrigger` | Same nested class |
| `shouldHandleOptimisticLockExceptionDuringPriorityUpdate` (line 877) | `shouldHandleSpringOptimisticLockingFailureExceptionDuringPriorityUpdate` | Same nested class |
| `shouldHandleOptimisticLockExceptionDuringRecalculation` (line 923) | `shouldHandleSpringOptimisticLockingFailureExceptionDuringRecalculation` | Same nested class |

Each new test should mirror its counterpart but throw `new ObjectOptimisticLockingFailureException("entity", null)` instead of `new OptimisticLockException("Lock failed")`, and verify the same graceful-handling behavior (continue processing, no propagation).

**OrderReleaseJobTest.java** / **OrderReleaseJobUnitTest.java** — check if optimistic lock tests exist; if not, add tests for both exception types at the `releaseOrder()` catch block (line 285).

### 4.2 Fix Broken `BasicServiceUnitTest`

- Update `shouldReturnNegativeWhenSequenceServiceExceedsMaxRetries` to expect `RuntimeException` and `times(5)` as described in Section 3.

---

## 5. Implementation Checklist

- [x] **Fix B-1**: Add `import org.springframework.dao.OptimisticLockingFailureException` to `OrderReleaseJob.java` ✓ Implemented 2026-04-01
- [x] **Fix B-2**: Update catch block at `OrderReleaseJob.java:286` to include `OptimisticLockingFailureException` ✓ Implemented 2026-04-01
- [x] **Fix B-3**: Add `import org.springframework.dao.OptimisticLockingFailureException` to `ReplenishOrderJob.java` ✓ Implemented 2026-04-01
- [x] **Fix B-4**: Update all 7 catch blocks in `ReplenishOrderJob.java` (lines 306, 340, 375, 394, 425, 445, 463) ✓ Implemented 2026-04-01
- [x] **Fix D**: Update broken `BasicServiceUnitTest.shouldReturnNegativeWhenSequenceServiceExceedsMaxRetries` — now expects `RuntimeException` and `times(5)` ✓ Implemented 2026-04-01
- [x] **Test-1**: Add 6 `OptimisticLockingFailureException` tests to `ReplenishOrderJobTest.java` (new `SpringOptimisticLockingFailureExceptionTests` nested class) ✓ Implemented 2026-04-01
- [x] **Test-2**: Add 1 `OptimisticLockingFailureException` test to `OrderReleaseJobTest.java` (new `SpringOptimisticLockingFailureExceptionTests` nested class) ✓ Implemented 2026-04-01
- [x] **Verify**: All 79 affected tests pass (0 failures, 0 errors). Full suite has 10 failures + 56 errors, all pre-existing and unrelated (AdvisoryLockService null, H2 context failures, StockunitBusinessService entity-not-found) ✓ Verified 2026-04-01

---

## 6. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Catching `OptimisticLockingFailureException` masks real conflicts | Low — this is already the intended behavior; catch blocks log warnings and continue | Same pattern as v1; cron jobs are designed to retry on next cycle |
| Test changes to `BasicServiceUnitTest` | None — aligning test expectations with actual code behavior | Test was already broken (would fail if run) |
| Other scheduled jobs missing Spring exception catch | Low — `CleanUpOldMessagesJob`, `ReleaseExpiredPickingOrdersFromUserJob`, `StockSummaryExportJob` don't catch any optimistic lock exceptions | These jobs don't perform retry-sensitive entity modifications in loops |

---

## 7. Recommendations

1. **Audit other `@Cacheable` usages in cron job hot paths** — The `SyspropService.getSysvalue()` cache with 5-min TTL effectively prevents the auto-flush storm that caused v1's issues. However, if any cron job calls a non-cached method that internally uses a native query, the same auto-flush pattern could resurface. A quick grep for `nativeQuery = true` in frequently-called repository methods would be prudent.

2. **Consider a shared catch utility** — Both `OrderReleaseJob` and `ReplenishOrderJob` have identical catch patterns for optimistic lock exceptions. A small static helper like `isOptimisticLockException(Exception e)` could centralize the check and prevent future drift between the two exception types. However, this is optional and cosmetic — the multi-catch approach is clearer and idiomatic.

3. **Verify `sysprops` cache TTL is appropriate for cron context** — The 5-minute `expireAfterAccess` TTL means that toggling `SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG` at runtime won't take effect for up to 5 minutes in cron jobs. If faster toggle response is needed, consider adding a `@CacheEvict` call for the `showLog` key when the property is updated, or reducing the TTL. This is a minor operational concern, not a bug.

---

## 8. Files to Modify

| File | Change Type |
|:-----|:-----------|
| `src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java` | Add import + update 1 catch block |
| `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` | Add import + update 7 catch blocks |
| `src/test/java/net/aim_ai/wms/unit/service/BasicServiceUnitTest.java` | Fix broken test (line 372-385) |
| `src/test/java/net/aim_ai/wms/unit/schedulejob/ReplenishOrderJobTest.java` | Add 6 new `OptimisticLockingFailureException` tests |
| `src/test/java/net/aim_ai/wms/unit/schedulejob/OrderReleaseJobTest.java` | Add/verify `OptimisticLockingFailureException` test |
