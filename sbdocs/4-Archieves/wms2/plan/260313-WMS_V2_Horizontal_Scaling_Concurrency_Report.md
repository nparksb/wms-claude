# WMS v2 Horizontal Scaling & Concurrency Assessment

**Date:** 2026-03-13 (Reviewed & Updated: 2026-03-28, Archived: 2026-05-22)
**Status:** Implementation Complete — Phases 1 & 2 all code items done; GAP D (per-tenant connection pool sizing) and Phase 3 (Redis cross-replica cache) remain as infrastructure/deployment tasks
**Priority:** High

---

## 1. Background

WMS v1 could only run **1 replica per warehouse** due to optimistic locking issues and data corruption/inconsistency between concurrent instances hitting the same PostgreSQL database. With WMS v2 now being **multi-tenant and multi-warehouse**, a single instance may not handle the combined workload of all warehouses. This report assesses whether v2 can safely run multiple replicas.

---

## 2. Summary

**Can we run >1 replica today?** Not safely for the same tenant database. However, v2 is significantly closer than v1 was, and the database-per-tenant architecture provides an immediate low-risk path to horizontal scaling via tenant-aware routing.

---

## 3. What v2 Already Has (Improvements Over v1)

| Mechanism | Coverage | Notes |
|-----------|----------|-------|
| `@Version` optimistic locking | All 45 entities via `AbstractBaseEntity` | Detection is universal |
| `OptimisticLockRetry` utility | Used in palletizing, pick confirmation, replenishment | Created and integrated in Phases 2-3 |
| Pessimistic locks (`SELECT ... FOR UPDATE`) | `StockunitRepository`, `PickingorderRepository`, `UnitloadRepository`, `BillofladingRepository` | **DB-level — works across replicas** |
| `@Transactional` boundaries | ~40 methods across 15 files | Added in Phase 2-3 concurrency fixes |
| Database-per-tenant isolation | Each warehouse gets its own PostgreSQL database | Cross-warehouse contention eliminated at DB level |
| Sequence number retry | `BasicService.getNextSequenceNumber()` retries up to 100x on optimistic lock failure | DB-backed — works across replicas |

### Concurrency Fix Plan Status (from `docs/plan/260424-CONCURRENCY_FIX_PLAN.md`)

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1, Item 1.1 | `StockunitBusinessService` optimistic retry for `changeAmount`/`changeReservedAmount` | ⚠️ **NOT DONE** |
| Phase 1, Item 1.2 | Pessimistic lock for stock reservation in `ReleaseOrderJobService` | ⚠️ **NOT DONE** |
| Phase 1, Item 1.3 | `CustomerorderBatchService` shared mutable state fix | ⚠️ **PARTIALLY DONE** |
| Phase 2 | Transaction boundaries, pick order locking, replenish retry | ✅ COMPLETED |
| Phase 3 | Medium-priority hardening (BOL, bulk updates) | ✅ COMPLETED |

---

## 4. What Would Break With Multiple Replicas

### 4.1 🔴 CRITICAL: JVM-Level Guards Don't Work Across Replicas

**`BillofladingService.bolToClose`** (line 139):
```java
private final Set<Long> bolToClose = ConcurrentHashMap.newKeySet();
```

This in-memory set prevents concurrent `closeBOL()` calls within a single JVM. With 2+ replicas, each has its own empty set — two simultaneous requests for the same BOL on different replicas would both pass the guard. The pessimistic `findByIdForUpdate()` lock on the row (line 280) provides a DB-level fallback, but the in-memory guard gives a misleading error scope.

### 4.2 🔴 CRITICAL: Unprotected Stock Mutations

`StockunitBusinessService.changeReservedAmount()` and `changeAmount()` — the most frequently called mutation methods — **do not use `OptimisticLockRetry`**. These are called from:
- `ReleaseOrderJobService` (order release)
- `MobilePickingService` (pick processing)
- `MobileReplenishService` (replenishment)

With multiple replicas, concurrent picks and order releases hitting the same stock units will throw unhandled `ObjectOptimisticLockingFailureException` — the transaction crashes and the user sees an error instead of an automatic retry.

### 4.3 🔴 CRITICAL: No Pessimistic Lock on Stock Reservation

`ReleaseOrderJobService` reads available stock, checks quantities, then reserves — classic TOCTOU (time-of-check-to-time-of-use). Two replicas releasing orders simultaneously can both see the same available stock and double-allocate it.

### 4.4 🟡 HIGH: Sequence Number Contention Under Load

`SequenceTransactionService.getNextSequenceNumber()` uses `REQUIRES_NEW` + optimistic retry. This works across replicas but under heavy multi-replica load, retry counts spike, causing latency. A `SELECT ... FOR UPDATE` or native PostgreSQL sequence would be more efficient.

### 4.5 🟡 MEDIUM: CustomerorderBatchService Thread Safety

The v1 version used unsafe instance-level cache maps. V2 partially fixed `calculateUnitLoadAmounts()` but the full `BatchContext` refactor from the concurrency plan needs verification.

---

## 5. Recommended Path to Horizontal Scaling

### Option A: Tenant-Aware Routing (Low Risk, Immediate)

Since each warehouse has its own PostgreSQL database, we can route all requests for a given tenant/warehouse to a **specific replica** at the load balancer level. This mirrors the v1 model (1 replica per warehouse) but with a shared application deployment.

**Pros:**
- Zero concurrency risk — each replica only handles one warehouse's traffic
- No code changes required
- Deployable immediately via Traefik/ingress header-based routing on `facility_code`

**Cons:**
- Not truly elastic — a single high-traffic warehouse is still bound to one replica
- Requires load balancer configuration per tenant/warehouse

### Option B: Full Multi-Replica Concurrency (Medium Risk, Requires Code Changes)

Complete the remaining concurrency fixes so any replica can safely handle any tenant.

| # | Change | Effort | Risk |
|---|--------|--------|------|
| 1 | Replace `bolToClose` in-memory set with DB-level advisory lock or remove it (DB pessimistic lock already exists as fallback) | Low | Low |
| 2 | Wrap `StockunitBusinessService.changeAmount()` and `changeReservedAmount()` in `OptimisticLockRetry` with ID-based re-fetch (Phase 1, Item 1.1) | Low-Medium | Low |
| 3 | Add `findAvailableByItemdataIdForUpdate()` pessimistic lock query to `StockunitRepository` and use it in `ReleaseOrderJobService` (Phase 1, Item 1.2) | Medium | Medium |
| 4 | Verify/complete `CustomerorderBatchService` instance field thread safety (Phase 1, Item 1.3) | Medium | Low |
| 5 | Replace `LosSequencenumber` optimistic retry with `SELECT ... FOR UPDATE` or native PostgreSQL `SEQUENCE` to reduce contention | Low | Low |

### Recommended Approach

1. **Phase 1 (Immediate):** Deploy Option A — tenant-aware routing. This gives horizontal scaling now with zero code risk.
2. **Phase 2 (Sprint work):** Complete items 1-5 above to enable true multi-replica concurrency.
3. **Phase 3 (Validation):** Load test with 2 replicas handling the same tenant database to confirm no data corruption.
4. **Phase 4 (Production):** Remove tenant pinning from load balancer, allow any replica to handle any tenant.

---

## 6. Architecture Diagram

```
Current (v1 model carried into v2):

  [All Warehouses] → [Single WMS v2 Replica] → [Tenant DB A]
                                               → [Tenant DB B]
                                               → [Tenant DB C]

Option A — Tenant-Aware Routing:

  [Warehouse A requests] → [Replica 1] → [Tenant DB A]
  [Warehouse B requests] → [Replica 2] → [Tenant DB B]
  [Warehouse C requests] → [Replica 1] → [Tenant DB C]  (shared with A)

Option B — Full Multi-Replica (after concurrency fixes):

  [Any Warehouse] → [Load Balancer (round-robin)] → [Replica 1] → [Any Tenant DB]
                                                   → [Replica 2] → [Any Tenant DB]
                                                   → [Replica N] → [Any Tenant DB]
```

---

## 7. Files Referenced

| File | Relevance |
|------|-----------|
| `v2/wms-api/docs/plan/260424-CONCURRENCY_FIX_PLAN.md` | Full concurrency audit with 270 `.save()` calls, fix plan, and completion status |
| `v2/wms-api/src/.../util/OptimisticLockRetry.java` | Retry utility (3 retries, exponential backoff) |
| `v2/wms-api/src/.../model/AbstractBaseEntity.java` | `@Version` field on all entities |
| `v2/wms-api/src/.../service/BillofladingService.java` | `bolToClose` in-memory guard (line 139) |
| `v2/wms-api/src/.../service/StockunitBusinessService.java` | `changeAmount()` / `changeReservedAmount()` — unprotected |
| `v2/wms-api/src/.../service/job/ReleaseOrderJobService.java` | Stock reservation without pessimistic lock |
| `v2/wms-api/src/.../service/CustomerorderBatchService.java` | Partially fixed shared mutable state |
| `v2/wms-api/src/.../service/SequenceTransactionService.java` | Sequence generation with `REQUIRES_NEW` |
| `v2/wms-api/src/.../landlord/config/TenantDynamicRoutingDataSource.java` | Database-per-tenant routing + pool size config (line 92) |
| `v2/wms-api/src/.../exceptions/RestExceptionHandler.java` | Missing lock exception handlers (GAP A) |
| `v2/wms-api/src/.../service/KeycloakService.java` | Non-thread-safe `PassiveExpiringMap` userCache (GAP B, line 56) |
| `v2/wms-api/src/.../landlord/config/TenantPoolEvictor.java` | `@Scheduled` eviction bypassed on non-cron replicas (GAP E, line 30) |
| `v2/wms-api/src/.../landlord/config/MultiTenantJwtDecoder.java` | JVM-local JWT decoder cache (GAP F, line 25) |
| `v2/wms-api/src/.../landlord/model/TenantDbConfiguration.java` | Default maxPoolSize=2 (GAP D, line 47) |
| `v2/wms-api/src/.../schedulejob/OrderReleaseJob.java` | No distributed lock guard (GAP C) |
| `v2/wms-api/src/.../config/CacheConfig.java` | Caffeine TTLs 15-60 min (Item 7) |

---

## 8. Validation Review (2026-03-28)

Deep code analysis was performed against the current v2 codebase to validate each finding. Results below.

### 8.1 Original Findings — Validation Status

| Finding | Original Severity | Current Status | Updated Severity |
|---------|------------------|----------------|-----------------|
| 4.1 `bolToClose` JVM guard | 🔴 CRITICAL | **Mitigated** — `findByIdForUpdate` pessimistic lock at line 284 provides DB-level fallback | 🟢 LOW |
| 4.2 Unprotected stock mutations | 🔴 CRITICAL | **Partially fixed** — `changeReservedAmount()` now uses `findByIdForUpdate` (line 385); `changeAmount()` still unprotected (line 351) | 🟡 MEDIUM |
| 4.3 Stock reservation TOCTOU | 🔴 CRITICAL | **Still valid** — TOCTOU gap remains, but `changeReservedAmount`'s pessimistic lock prevents actual data corruption; causes unnecessary `FacadeException` failures instead | 🟡 MEDIUM |
| 4.4 Sequence contention | 🟡 HIGH | **Confirmed** — also found silent failure: `BasicService.java:154` returns `-1` instead of throwing when retries exhausted | 🔴 HIGH |
| 4.5 BatchService thread safety | 🟡 MEDIUM | **Confirmed FIXED** — shared instance fields removed, replaced with method-local state (line 133-134 comment documents the fix) | 🟢 RESOLVED |

#### 4.1 Details — `bolToClose` Severity Downgrade

The `bolToClose` in-memory set (line 143) is redundant with the `findByIdForUpdate` pessimistic lock at line 284. With multiple replicas, two JVMs can both pass the in-memory check, but the DB row lock serializes the actual `closeBOL()` execution correctly. The in-memory set is now just a single-JVM fast-fail optimization.

**Recommendation:** Keep as-is (or add a comment clarifying it's a single-JVM optimization). Not worth changing.

#### 4.2 Details — `changeReservedAmount` Fixed, `changeAmount` Still Exposed

- `changeReservedAmount()` (line 383): Now uses `stockunitRepository.findByIdForUpdate()` with `PESSIMISTIC_WRITE` — properly protected
- `changeAmount()` (line 349): Still uses plain `findById()`, no `@Transactional`, no retry — vulnerable to lost updates under concurrent goods receipt, cycle count, or manual inventory operations
- `OptimisticLockRetry` is NOT injected into `StockunitBusinessService` — only used in `PickingorderBusinessService`, `UnitloadBusinessService`, `MobileReplenishService`, `MobilePalletizingService`

#### 4.3 Details — TOCTOU Nuanced

The actual flow is: read stock (no lock) → check availability (stale) → reserve (with lock inside `changeReservedAmount`). The pessimistic lock prevents data corruption (over-reservation), but the stale availability check causes unnecessary failures when concurrent releases see the same available stock. The impact is **delayed order processing** (orders released on next job cycle), not data integrity loss.

#### 4.4 Details — Silent Failure Path Found

`BasicService.getNextSequenceNumber()` at line 154 has a commented-out `throw` with a TODO:
```java
// TODO: need to figure out how to deal with this situation - no next sequence number
```
It returns `-1` on retry exhaustion, which propagates an invalid sequence number downstream. This should throw `BusinessException`.

---

### 8.2 NEW Findings — Not in Original Report

#### NEW-1: 🔴 CRITICAL — Scheduled Jobs Run on ALL Replicas

`SchedulingConfiguration.java:25-26` enables scheduling based on `app.cron=true`. If multiple replicas have this flag, every `@Scheduled` job fires on every replica simultaneously.

**Affected jobs:**

| Job | File | Guard | Risk |
|-----|------|-------|------|
| `OrderReleaseJob` | `OrderReleaseJob.java:54` | **None** | 🔴 Duplicate order releases, double-allocated stock |
| `ReplenishOrderJob` | `ReplenishOrderJob.java:24,77` | `AtomicBoolean` (JVM-local only) | 🔴 Duplicate replenishments; TODO at line 77 acknowledges need for `pg_try_advisory_lock` |
| `CleanUpOldMessagesJob` | `CleanUpOldMessagesJob.java:32` | **None** | 🟡 Duplicate message cleanup (idempotent but wasteful) |
| `ReleaseExpiredPickingOrdersFromUserJob` | Line 40 | **None** | 🟡 Idempotent (nulls out operatorId) |
| `StockSummaryExportJob` | Line 58 | **None** | 🟡 Duplicate exports |

**Impact:** `OrderReleaseJob` is the highest risk — concurrent execution causes duplicate picking order generation and double-released orders.

**Deployment decision:** Only ONE replica will run with `app.cron=true` (confirmed by team). This eliminates duplicate job execution without code changes. ShedLock / advisory locks remain a future hardening option if the cron replica needs failover capability.

#### NEW-2: 🟡 HIGH — Caffeine Cache is JVM-Local (Cross-Replica Inconsistency)

`CacheConfig.java:16-37` configures Caffeine (in-memory) caches for `sysprops`, `clients`, `locations`, and `itemdata` with TTLs of 15-60 minutes.

**Two problems:**
1. **Cross-replica staleness:** A SKU update on Replica A evicts its local cache, but Replica B serves stale data until TTL expires (up to 60 minutes)
2. **Cross-tenant over-eviction:** `ItemdataService.java:56` uses `@CacheEvict(allEntries = true)` which flushes ALL tenants' cached data when any single tenant modifies an item

**Recommended fix:**
- **Immediate:** Reduce TTLs to 2-5 minutes
- **Long-term:** Switch to Redis-backed Spring Cache for cross-replica consistency
- Fix `allEntries = true` evictions to use tenant-scoped keys

#### NEW-3: 🟡 MEDIUM — TenantContext ThreadLocal Leak in SchedulingConfiguration

`SchedulingConfiguration.java:124-137` — `isTenantDatabaseInitialized()` sets `TenantContext` at line 129 but never clears it in a `finally` block. The scheduler thread pool reuses threads, so stale tenant context persists.

**Mitigated by:** All scheduled jobs explicitly set tenant context before processing. But there's a window between thread reuse and the first `setCurrentTenant` call where stale context exists.

**Fix:** Add `finally { TenantContext.clear(); }` after the try block.

#### NEW-4: TenantFilter Cleanup — NO ISSUE

`TenantFilter.java:51-55` correctly uses `try/finally` to clear `TenantContext` after every HTTP request. Properly implemented.

---

### 8.3 Updated Recommendation Table (Option B)

| # | Change | Effort | Risk | Severity | Status |
|---|--------|--------|------|----------|--------|
| 1 | `bolToClose` — keep as-is (DB lock is the real guard) | None | None | ~~CRITICAL~~ → LOW | **No action needed** |
| 2 | `changeAmount()` — add `findByIdForUpdate` (like `changeReservedAmount`) | Low | Low | MEDIUM | **TODO** |
| 3 | `ReleaseOrderJobService` — add pessimistic lock on stock query or accept retry-based conflict resolution | Medium | Medium | MEDIUM | **TODO** |
| 4 | `CustomerorderBatchService` — shared mutable state | — | — | ~~MEDIUM~~ → RESOLVED | **Already fixed** |
| 5 | Sequence generation — replace with PostgreSQL native sequences | Medium | Low | HIGH | **TODO** |
| 5b | `BasicService.getNextSequenceNumber()` — uncomment `throw`, remove silent `-1` return | Low | Low | HIGH | **TODO** |
| **6** | **Scheduled jobs — single cron replica (`app.cron=true` on one instance only)** | **None** | **None** | **🔴 CRITICAL** | **NEW — RESOLVED (deployment config)** |
| **7** | **Caffeine cache — reduce TTLs, plan Redis migration** | **Low-High** | **Low** | **🟡 HIGH** | **NEW — TODO** |
| **8** | **TenantContext leak — add `finally { TenantContext.clear(); }` in SchedulingConfiguration** | **Low** | **Low** | **🟡 MEDIUM** | **NEW — TODO** |

### 8.4 Revised Priority Order

1. ~~**Set `app.cron=true` on only ONE replica**~~ — **RESOLVED**: confirmed deployment strategy is single cron replica
2. **Reduce Caffeine TTLs** (immediate, 1 line per cache) — mitigates NEW-2
3. **Fix silent sequence failure** (item 5b, 1 line) — prevents invalid data
4. **Add `TenantContext.clear()` in SchedulingConfiguration** (item 8, 3 lines) — prevents tenant leak
5. **Add `findByIdForUpdate` to `changeAmount()`** (item 2) — prevents lost stock updates
6. **Replace sequence generation with PostgreSQL sequences** (item 5) — eliminates contention
7. **Add ShedLock to scheduled jobs** (item 6) — enables true multi-replica scheduling
8. **Evaluate Redis cache** (item 7) — enables cross-replica cache consistency

---

---

## 9. Option B Deep Validation (2026-03-28)

Critical review of the Option B (Full Multi-Replica Concurrency) plan uncovered **7 new gaps** not previously identified. The original plan items were also scrutinized for completeness.

### 9.1 Original Plan Items — Critical Review

| Item | Original Assessment | Validation Result |
|------|-------------------|-------------------|
| 1. `bolToClose` | LOW | **CORRECT** — DB lock is the real guard. In-memory set is dead code under multi-replica. |
| 2. `changeAmount()` | MEDIUM | **UNDERSPECIFIED** — must also add `@Transactional(value="tenantTransactionManager")`. Without it, the pessimistic lock is released immediately in auto-commit mode. |
| 3. `ReleaseOrderJobService` | MEDIUM | **CORRECT** — but depends on Item 6 (single cron replica) being bulletproof. Advisory lock recommended as defense-in-depth. |
| 4. `CustomerorderBatchService` | RESOLVED | **CONFIRMED** |
| 5. Sequence generation | HIGH | **CORRECT** — PostgreSQL native sequences are the right fix. Current design is O(N^2) under concurrent load. |
| 5b. Silent `-1` failure | HIGH → **CRITICAL** | **UNDERRATED** — `-1` propagates as a corrupted sequence number (e.g., `"PICK-1"` instead of `"PICK-00001"`). Data corruption bug. |
| 6. Single cron replica | RESOLVED | **HAS A GAP** — see Gap E below (`TenantPoolEvictor` silently stops on non-cron replicas) |
| 7. Caffeine cache | HIGH | **CORRECT** — especially dangerous for `sysprops` cache (controls feature flags, 60-min TTL) |
| 8. TenantContext leak | MEDIUM | **CORRECT** — low practical risk since jobs re-set context |

### 9.2 NEW Gaps Found

#### GAP A: 🔴 CRITICAL — No Global Handler for Optimistic/Pessimistic Lock Exceptions

`RestExceptionHandler.java:21-122` has **no `@ExceptionHandler`** for `ObjectOptimisticLockingFailureException` or `PessimisticLockingFailureException`. Only `PickingController` catches these (9 catch blocks). All other controllers (20+ endpoints) return HTTP 500 with a stack trace on lock contention.

Under multi-replica load, lock contention increases dramatically — every unhandled lock exception becomes a user-facing 500 error.

**Fix:** Add to `RestExceptionHandler`:
```java
@ExceptionHandler(ObjectOptimisticLockingFailureException.class)
// Return HTTP 409 Conflict with retry guidance

@ExceptionHandler(PessimisticLockingFailureException.class)
// Return HTTP 409 Conflict with retry guidance
```

**Effort:** Low | **Impact:** Critical

#### GAP B: 🟡 HIGH — `KeycloakService.userCache` is Not Thread-Safe

`KeycloakService.java:56` uses Apache Commons `PassiveExpiringMap` which is **not thread-safe** (documented in its Javadoc). Under concurrent load this is already a latent bug. Under multi-replica, user group changes (e.g., permission revocation at line 279) are only evicted from one replica's cache — other replicas continue granting stale permissions for up to 15 minutes.

**Fix:** Replace with `Caffeine` cache (thread-safe, TTL-aware, matches existing codebase pattern). Plan Redis migration for cross-replica consistency.

**Effort:** Low | **Impact:** High (security: stale permissions after revocation)

#### GAP C: 🟡 MEDIUM — `ReplenishOrderJob.RUNNING` AtomicBoolean is JVM-Local

`ReplenishOrderJob.java:24` uses `static AtomicBoolean RUNNING` to prevent overlapping executions. This is useless across replicas. `OrderReleaseJob` has no such guard at all. The TODO at line 77 already acknowledges the need for `pg_try_advisory_lock`.

**Fix:** Add `pg_try_advisory_lock` to all scheduled jobs as defense-in-depth against `app.cron` misconfiguration.

**Effort:** Medium | **Impact:** Medium

#### GAP D: 🟡 HIGH — DB Connection Pool Exhaustion Under Multi-Replica

`TenantDynamicRoutingDataSource.java:92` creates a HikariCP pool per tenant per replica with `maxPoolSize` defaulting to 2-5. Total connections = N replicas × T tenants × maxPoolSize.

Example: 3 replicas, 5 tenants, pool size 5 = **75 connections** + landlord pools (6 more) = **81 connections**. PostgreSQL default `max_connections` is **100**. This leaves only 19 connections for superuser, monitoring, backups — dangerously close to exhaustion.

**Fix:** Either:
- Configure `maxPoolSize = ceil(currentMax / replicaCount)` per tenant
- Deploy PgBouncer as a connection pooler in front of PostgreSQL
- Increase PostgreSQL `max_connections` (requires restart and RAM assessment)

**Effort:** Medium | **Impact:** High (DB exhaustion = total outage)

#### GAP E: 🟡 HIGH — `TenantPoolEvictor` Silently Stops on Non-Cron Replicas

`@EnableScheduling` is inside `SchedulingConfiguration` which is `@ConditionalOnProperty(name = "app.cron")`. Non-cron replicas have **no scheduling infrastructure at all**. The `TenantPoolEvictor.java:30` `@Scheduled` annotation is silently ignored — connection pools grow monotonically without eviction on all replicas except the cron replica.

**Fix:** Extract `@EnableScheduling` into a separate unconditional `@Configuration` class. Keep the conditional logic only for business job bean registration.

**Effort:** Low | **Impact:** High (memory/connection leak on non-cron replicas)

#### GAP F: 🟢 LOW — `MultiTenantJwtDecoder.jwtDecoders` JVM-Local Cache

`MultiTenantJwtDecoder.java:25` caches JWT decoders per-tenant in a `ConcurrentHashMap`, never evicted. If a tenant's Keycloak key rotates, stale decoders reject valid tokens until JVM restart. Acceptable for now; document as a known limitation.

**Effort:** None (document only) | **Impact:** Low

#### GAP G: 🟢 LOW — `NameTypeService` Mutable Singleton State

`NameTypeService.java:26-27` has mutable fields on what appears to be a utility bean. Verify usage pattern — if per-request instantiation, no issue. If singleton with concurrent access, data corruption risk.

**Effort:** Low (verify) | **Impact:** Low

### 9.3 Revised Option B Implementation Plan

**Priority order (highest first):**

| # | Item | Effort | Severity | Phase | Status |
|---|------|--------|----------|-------|--------|
| A | Add global lock exception handlers to `RestExceptionHandler` | Low | 🔴 CRITICAL | 1 | **DONE** |
| 5b | Fix silent `-1` return in `BasicService.getNextSequenceNumber()` | Low | 🔴 CRITICAL | 1 | **DONE** |
| E | Extract `@EnableScheduling` so `TenantPoolEvictor` runs on all replicas | Low | 🟡 HIGH | 1 | **DONE** |
| 2 | Add `findByIdForUpdate` + `@Transactional` to `changeAmount()` | Low | 🟡 HIGH | 1 | **DONE** |
| B | Replace `KeycloakService.userCache` with thread-safe Caffeine | Low | 🟡 HIGH | 1 | **DONE** |
| D | Audit and resize DB connection pools for N replicas | Medium | 🟡 HIGH | 1 | TODO (deployment config) |
| 5 | Pessimistic lock on sequence table (eliminates retry storms) | Low | 🟡 HIGH | 2 | **DONE** |
| 7 | Reduce Caffeine TTLs immediately; plan Redis migration | Low-High | 🟡 HIGH | 1 / 3 | **DONE** (TTLs) / TODO (Redis) |
| 3 | Pessimistic lock on stock candidates in `ReleaseOrderJobService` | Medium | 🟡 MEDIUM | 2 | **DONE** |
| C | `pg_try_advisory_lock` on all 5 scheduled jobs | Medium | 🟡 MEDIUM | 2 | **DONE** |
| 8 | Add `TenantContext.clear()` in `SchedulingConfiguration` | Low | 🟡 MEDIUM | 1 | **DONE** |
| 1 | Document `bolToClose` as single-JVM optimization | Low | 🟢 LOW | 1 | **DONE** |
| F | Document JWT decoder cache limitation | Low | 🟢 LOW | 1 | TODO |

### 9.4 Phase 1 Implementation Status (2026-03-28)

**8 of 10 Phase 1 items implemented. 357 unit tests pass, 0 failures.**

| Item | File(s) Changed | Change |
|------|----------------|--------|
| **A** | `RestExceptionHandler.java` | Added `@ExceptionHandler` for `ObjectOptimisticLockingFailureException` (→ HTTP 409) and `PessimisticLockingFailureException` (→ HTTP 409) |
| **5b** | `BasicService.java:150-156` | Replaced silent `return -1` with `throw new RuntimeException(msg)` on sequence retry exhaustion |
| **E** | `SchedulingEnablementConfig.java` (new), `SchedulingConfiguration.java` | Extracted `@EnableScheduling` into unconditional config class; removed from conditional `SchedulingConfiguration` so `TenantPoolEvictor` runs on all replicas |
| **2** | `StockunitBusinessService.java:349` | Added `@Transactional(value="tenantTransactionManager")` + changed `findById` → `findByIdForUpdate` on `changeAmount()` |
| **B** | `KeycloakService.java:56` | Replaced non-thread-safe `PassiveExpiringMap` with thread-safe `Caffeine` cache; updated API calls (`get`→`getIfPresent`, `remove`→`invalidate`) |
| **7** | `CacheConfig.java:21-25` | Reduced all Caffeine TTLs from 15-60 min to 5 min for multi-replica safety |
| **8** | `SchedulingConfiguration.java:127-136` | Added `finally { TenantContext.clear(); }` to `isTenantDatabaseInitialized()` |
| **1** | `BillofladingService.java:143` | Added comment documenting `bolToClose` as single-JVM fast-fail optimization (DB lock is the real guard) |

**Remaining Phase 1 items (deployment/documentation):**
- **D** — DB connection pool sizing: requires PostgreSQL `max_connections` audit and `maxPoolSize` tuning per replica count (deployment config, not code)
- **F** — JWT decoder cache: document as known limitation

### 9.5 Phase Summary

- **Phase 1 (Sprint):** 8/10 code items **DONE**, 2 remaining (deployment config + documentation)
- **Phase 2 (Follow-up sprint):** Items 5, 3, C — **ALL DONE**
  - Pessimistic lock on sequence table (replaced optimistic retry storms, reduced maxTries from 100 to 5)
  - Pessimistic lock on stock candidates in `ReleaseOrderJobService` (`FOR UPDATE OF stockunit`)
  - `pg_try_advisory_lock` on all 5 scheduled jobs via `AdvisoryLockService`
  - 5 job test files updated with mock `AdvisoryLockService`, 1 service test updated for `ForUpdate` mock
  - **75 job tests pass, 0 failures**
- **Phase 3 (Infrastructure):** Redis cache migration — enables true round-robin load balancing without stale data

---

## 10. Additional Files Referenced

| File | Relevance |
|------|-----------|
| `schedulejob/SchedulingConfiguration.java:25-26,124-137` | Scheduling enablement + TenantContext leak |
| `schedulejob/OrderReleaseJob.java:54` | No distributed lock on order release |
| `schedulejob/ReplenishOrderJob.java:24,77` | JVM-local AtomicBoolean guard + advisory lock TODO |
| `config/CacheConfig.java:16-37` | Caffeine (JVM-local) cache configuration |
| `service/ItemdataService.java:56` | `@CacheEvict(allEntries=true)` cross-tenant over-eviction |
| `service/BasicService.java:109-158` | Sequence retry loop with silent `-1` failure at line 154 |
| `landlord/config/TenantFilter.java:51-55` | Correct ThreadLocal cleanup (no issue) |
| `landlord/config/TenantContext.java:18` | ThreadLocal definition |

