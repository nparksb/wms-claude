# Debug Plan: Cron Job Auto-Flush Optimistic Lock Failures

**Date:** 2026-03-31
**Priority:** High
**Reporter:** Production logs (ReplenishOrderJob + OrderReleaseJob)

---

## 1. Problem Summary

Multiple cron jobs (`ReplenishOrderJob`, `OrderReleaseJob`) are crashing with optimistic locking exceptions during Hibernate auto-flush. The exceptions originate from `basicService.showLog()` which calls `losSyspropRepository.findSysvalueBySyskey()` — a **native query** that forces Hibernate to flush the entire persistence context before execution. When a concurrently modified entity (e.g., `Customerorder`) is in the persistence context, the flush detects a version mismatch and throws `StaleObjectStateException`, translated by Spring to `ObjectOptimisticLockingFailureException`. The catch blocks use `javax.persistence.OptimisticLockException` (JPA) which does **not** catch Spring's `ObjectOptimisticLockingFailureException`, so the exception escapes and kills the cron job iteration.

## 2. Root Cause Analysis

### 2.1 The Auto-Flush Trigger Chain

```
basicService.showLog()                                    // called ~50+ times per job run
  └─ losSyspropRepository.findSysvalueBySyskey(key)       // native query (nativeQuery=true)
      └─ NativeQueryImpl.beforeQuery()                     // Hibernate auto-flush before native query
          └─ SessionImpl.flush()                           // flushes ALL dirty entities in persistence context
              └─ StaleObjectStateException                 // version mismatch on concurrently modified entity
                  └─ PersistenceExceptionTranslationInterceptor
                      └─ ObjectOptimisticLockingFailureException  // Spring DAO translation
```

**File:** `BasicService.java:181` — `showLog()` calls `findSysvalueBySyskey()` on every invocation
**File:** `LosSyspropRepository.java:39` — `findSysvalueBySyskey` is `nativeQuery = true`

Hibernate's `FlushMode.AUTO` (the default) forces a session flush before every native query to ensure the query sees up-to-date data. This is by design, but it means **any** native query call becomes a flush point that can throw exceptions for **unrelated** dirty entities in the persistence context.

### 2.2 Why Entities Are Stale

Inside `@Transactional(REQUIRES_NEW)` methods like `ReleaseOrderJobService.releaseOrder()` or `ReplenishOrderJobService` methods:
1. Entities are loaded (e.g., `Customerorder`, `Replenishorder`)
2. Entities are modified and `save()`'d (which schedules an UPDATE at next flush)
3. `basicService.showLog()` is called for logging → triggers native query → triggers flush
4. During flush, Hibernate UPDATEs all dirty entities, including ones modified by concurrent web requests or other cron jobs
5. `@Version` check fails → `StaleObjectStateException`

**Stack Trace 1 (ReplenishOrderJob):**
- Occurs at `ReplenishOrderJob - start` during one of the early steps
- Exception type truncated as `?Exception` — likely `ObjectOptimisticLockingFailureException`
- Job may or may not continue depending on which catch block intercepts it

**Stack Trace 2 (OrderReleaseJob):**
- `ReleaseOrderJobService.releaseOrder()` (line 196) → `basicService.showLog()` → flush
- Fails on `Customerorder#25369380` — stale version from concurrent modification
- Exception escapes catch at `OrderReleaseJob:239` because it catches `javax.persistence.OptimisticLockException`, not Spring's `ObjectOptimisticLockingFailureException`

### 2.3 The Exception Type Mismatch

| Layer | Exception Class | Caught? |
|:------|:---------------|:--------|
| Hibernate | `org.hibernate.StaleObjectStateException` | No (translated by Spring) |
| Spring DAO | `org.springframework.orm.ObjectOptimisticLockingFailureException` | **No** — catch blocks use JPA type |
| JPA | `javax.persistence.OptimisticLockException` | Yes — but this is NOT what's thrown |

**Files affected:**
- `ReplenishOrderJob.java:12` — imports `javax.persistence.OptimisticLockException`
- `OrderReleaseJob.java:12` — imports `javax.persistence.OptimisticLockException`

Spring's `PersistenceExceptionTranslationInterceptor` (present on all `@Repository` proxies) translates Hibernate exceptions to Spring DAO exceptions **before** they reach the calling code. So `StaleObjectStateException` becomes `ObjectOptimisticLockingFailureException` (which extends `org.springframework.dao.OptimisticLockingFailureException`), NOT `javax.persistence.OptimisticLockException`.

## 3. Reproduction Steps

1. Start the application with `app.cron=true` and `SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG=true`
2. Have active customer orders and replenishment orders in PROCESSABLE/ASSIGNED states
3. Trigger concurrent modifications on the same entities (e.g., web UI updates an order while cron is running)
4. Wait for the cron cycle — the ReplenishOrderJob and OrderReleaseJob will hit the auto-flush exception
5. Expected: Job handles optimistic lock gracefully and continues / Actual: Exception escapes, job iteration aborted

## 4. Proposed Fix

### Fix A: Cache `showLog()` Result Per Job Run (Primary Fix)

- **File:** `BasicService.java:180-183`
- **Current:** `showLog()` calls `losSyspropRepository.findSysvalueBySyskey()` (native query) on every invocation — dozens of times per job cycle, each triggering an auto-flush
- **Change:** Cache the result with a short TTL (e.g., 30 seconds) so the native query only executes once per job cycle instead of 50+ times
- **Why:** Eliminates the root cause — no native query means no auto-flush trigger. This reduces both the exception risk and unnecessary DB load (50+ queries per job cycle for a value that rarely changes)

```java
// BasicService.java
private volatile Boolean showLogCache = null;
private volatile long showLogCacheTime = 0;
private static final long SHOW_LOG_CACHE_TTL_MS = 30_000; // 30 seconds

public Boolean showLog() {
    long now = System.currentTimeMillis();
    if (showLogCache == null || (now - showLogCacheTime) > SHOW_LOG_CACHE_TTL_MS) {
        showLogCache = Boolean.parseBoolean(
            losSyspropRepository.findSysvalueBySyskey(
                WmsConstants.SYSTEM_PROPERTY_CRON_JOB_SHOW_LOG_KEY));
        showLogCacheTime = now;
    }
    return showLogCache;
}
```

### Fix B: Fix Exception Catch Type Mismatch (Critical Safety Net)

- **File:** `OrderReleaseJob.java:12, 239`
- **Current:** `catch (OptimisticLockException | ...)` — catches `javax.persistence.OptimisticLockException`
- **Change:** Also catch `org.springframework.dao.OptimisticLockingFailureException` (Spring's translation)
- **Why:** Spring's exception translation converts Hibernate's `StaleObjectStateException` to `ObjectOptimisticLockingFailureException`, which is NOT a subclass of `javax.persistence.OptimisticLockException`. The catch block misses it entirely, causing the job to abort.

```java
// Change import
import org.springframework.dao.OptimisticLockingFailureException;

// Change catch block
} catch (OptimisticLockException | OptimisticLockingFailureException | FacadeException | BusinessException e) {
```

Apply the same fix in:
- **File:** `ReplenishOrderJob.java:12` + all catch blocks (lines 221, 255, 288, 342, 380)

### Fix C: Add `@Transactional` to `recalculateOpenOrders()` (Preventive)

- **File:** `ReplenishmentOrderMaintenanceService.java:70`
- **Current:** `recalculateOpenOrders()` has **no `@Transactional`** but modifies entities via `recalculateOrder()` → `replenishorderRepository.save()`, and calls native queries via `getStockAndReservedForLocation()`, `getAvailableReplenishmentSources()`, etc.
- **Change:** Add `@Transactional` annotation to ensure proper session/transaction management
- **Why:** Without a transaction boundary, each repository call creates its own short-lived transaction. Entity state management becomes unpredictable — entities loaded in one mini-transaction are detached, then passed to `save()` in another, while native queries in yet another mini-transaction trigger flushes on an inconsistent persistence context.

```java
@Transactional
public synchronized void recalculateOpenOrders(boolean force) {
```

## 5. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| `showLog()` cache returns stale value | Log verbosity toggle delayed by up to 30s | Acceptable — this is a debug flag, not business-critical |
| Catching `OptimisticLockingFailureException` masks real concurrency bugs | Could silently swallow genuine conflicts | Already the intended behavior — the catch blocks log warnings and continue to next iteration |
| Adding `@Transactional` to `recalculateOpenOrders()` increases transaction duration | Longer-held DB connections during maintenance | Acceptable — the method already operates within a single cron cycle and processes orders sequentially |
| Other cron jobs may have the same `showLog()` auto-flush issue | Same exception pattern in other jobs | Audit all `schedulejob/` classes for the same pattern (see Task 5) |

**Regression areas to test:**
- Replenishment order generation and priority updates under concurrent load
- Order release job under concurrent order modifications
- `showLog()` toggle behavior (verify cache invalidation works)

## 6. Task Checklist

- [x] **Fix A**: Cache `basicService.showLog()` with 30s TTL (`BasicService.java:180-193`) — (Critical, eliminates root cause) ✓ Implemented 2026-03-31
- [x] **Fix B-1**: Change `OrderReleaseJob.java:240` catch block to also catch `OptimisticLockingFailureException` — (Critical, prevents job abort) ✓ Implemented 2026-03-31
- [x] **Fix B-2**: Change `ReplenishOrderJob.java` all 7 catch blocks to also catch `OptimisticLockingFailureException` — (Critical, prevents job abort) ✓ Implemented 2026-03-31
- [x] **Fix C**: Add `@Transactional` to `ReplenishmentOrderMaintenanceService.recalculateOpenOrders(boolean)` — (High) ✓ Implemented 2026-03-31
- [x] **Audit**: Checked all `schedulejob/*.java` and other classes — only `ReplenishOrderJob` and `OrderReleaseJob` had the mismatch. Other classes (`PickingController`, `BasicService`, `OptimisticLockRetryTemplate`, `MobilePalletizingService`) already catch the Spring exception type correctly. ✓ Completed 2026-03-31
- [x] Add/update unit tests for `BasicService.showLog()` caching behavior (`BasicServiceUnitTest.java`) — added `showLog_cachesPreviousResult` and `showLog_refreshesCacheAfterTTLExpires` tests ✓ Implemented 2026-03-31
- [x] Full test suite: 1601 tests run, 0 failures, 2 pre-existing errors (unrelated `ViewDtoServiceUnitTest` ArrayIndexOutOfBounds), 0 skipped ✓ Verified 2026-03-31
- [ ] Verify fix in staging under concurrent cron + web load

## 7. Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/BasicService.java` | Added 30s TTL cache to `showLog()` |
| `src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java` | Added `OptimisticLockingFailureException` import + catch |
| `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` | Added `OptimisticLockingFailureException` import + all 7 catch blocks |
| `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` | Added `@Transactional` to `recalculateOpenOrders(boolean)` |
| `src/test/java/net/aim_ai/wms/unit/service/BasicServiceUnitTest.java` | Added 2 cache-specific tests |
