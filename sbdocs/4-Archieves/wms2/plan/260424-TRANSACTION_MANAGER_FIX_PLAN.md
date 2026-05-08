# Transaction Manager Fix Plan — COMPLETED

> **Status:** All 5 phases implemented and verified.
> **Commit:** `05d51e0` — fix: specify tenantTransactionManager on all 44 @Transactional annotations
> **Date:** 2026-02-24
> **Tests:** 3,267 passed, 0 failures

## 1. Problem Statement

The application has **two transaction managers** configured:

| Transaction Manager | `@Primary` | Bean Name | DataSource | Persistence Unit | Used For |
|---------------------|-----------|-----------|------------|------------------|----------|
| `landlordTransactionManager` | **Yes** | `landlordTransactionManager` | `landlordDataSource` (master DB) | `landlord` | Tenant config lookups only |
| `tenantTransactionManager` | No | `tenantTransactionManager` | `tenantDynamicRoutingDataSource` (routed per tenant) | `tenant` | **All warehouse operations** |

**Configuration files:**
- `LandlordDatabaseConfig.java` — `@Primary` on DataSource, EntityManagerFactory, and TransactionManager
- `TenantDatabaseConfig.java` — `@EnableJpaRepositories(basePackages = "net.aim_ai.wms.repo.jpa", transactionManagerRef = "tenantTransactionManager")`

### The Bug

Because `landlordTransactionManager` is `@Primary`, any `@Transactional` annotation **without** `value = "tenantTransactionManager"` silently defaults to the landlord (master) transaction manager. This means:

1. **No transactional guarantees** — The landlord TM creates a transaction on the landlord DB, but tenant repository calls use the tenant EMF. Repository operations run in auto-commit mode (each call is its own mini-transaction).
2. **`rollbackFor` is ineffective** — If an exception occurs, the landlord transaction rolls back, but tenant writes have already committed individually. Partial writes remain in the tenant DB.
3. **L1 cache disabled** — Without a shared Hibernate session across repo calls within the same method, entities fetched earlier are not cached. Every `findById` is a fresh DB query.
4. **Connection pool pressure** — Each repository call independently checks out and returns a DB connection, instead of sharing one across the method.

### Why It Works (Mostly)

The bug has been latent because:
- Most operations succeed fully, so rollback never triggers
- The `TenantDynamicRoutingDataSource` correctly routes queries to the right tenant DB regardless of which TM wraps the call
- Spring Data JPA repos in `net.aim_ai.wms.repo.jpa` use `tenantEntityManagerFactory` automatically (configured via `@EnableJpaRepositories`)
- Partial commits on failure go unnoticed in most flows

### Known Production Failures

- `PickingorderBusinessService.confirmPick()` — `entityManager.flush()` threw `TransactionRequiredException: no transaction is in progress` because the constructor-injected EntityManager was bound to the landlord persistence unit, not the tenant's. Fixed by removing the flush (commit `9a625fe`).

---

## 2. Current State Analysis

### Correctly Using `tenantTransactionManager` (21 annotations — NO CHANGES NEEDED)

| File | Lines | Count |
|------|-------|-------|
| `PickingorderBusinessService.java` | 336 | 1 |
| `BillofladingService.java` | 260, 268 | 2 |
| `ReceivingService.java` | 148, 242, 293, 615, 646 | 5 |
| `MobilePickingService.java` | 139, 158, 203, 273, 373, 485, 499, 539, 560, 577, 621, 770, 781, 796, 970, 988 | 16 |
| **Subtotal** | | **24** |

### Correctly Using Default (Landlord) TM (4 annotations — NO CHANGES NEEDED)

| File | Lines | Notes |
|------|-------|-------|
| `LandlordService.java` | 18 (class-level), 40, 54, 88 | Landlord operations — default TM is correct |

### Repositories — OK As-Is (11 annotations — NO CHANGES NEEDED)

Repositories in `net.aim_ai.wms.repo.jpa` inherit `tenantTransactionManager` from `@EnableJpaRepositories(transactionManagerRef = "tenantTransactionManager")`. Their bare `@Transactional` annotations are automatically bound to the tenant TM.

| File | Lines | Type |
|------|-------|------|
| `AdviceRepository.java` | 29 | `@Modifying` + `@Transactional` |
| `AdvicepositionRepository.java` | 29 | `@Modifying` + `@Transactional` |
| `BillofladingRepository.java` | 73 | `@Modifying` + `@Transactional` |
| `BillofladingPositionRepository.java` | 103, 109 | `@Modifying` + `@Transactional` |
| `ClientRepository.java` | 44, 84 | `@Modifying` + `@Transactional` |
| `MessageRepository.java` | 31, 39 | `@Modifying` + `@Transactional` |
| `CustomerorderRepository.java` | 156 | `@Modifying` (no explicit `@Transactional`) |
| `CustomerorderPositionRepository.java` | 65 | `@Modifying` (no explicit `@Transactional`) |
| `PickingorderPositionRepository.java` | 108 | `@Modifying` (no explicit `@Transactional`) |

### MISSING `tenantTransactionManager` — NEEDS FIX (44 annotations across 17 files)

These service methods operate on tenant data but default to the landlord transaction manager.

#### Core Business Services (6 files, 16 annotations)

| # | File | Line | Current Annotation | Risk |
|---|------|------|--------------------|------|
| 1 | `TransferOrderService.java` | 79 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 2 | `TransferOrderService.java` | 104 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 3 | `TransferOrderService.java` | 322 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 4 | `BillofladingService.java` | 197 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 5 | `BillofladingService.java` | 711 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 6 | `BillofladingService.java` | 902 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 7 | `CustomerorderBatchService.java` | 124 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 8 | `CustomerorderBatchService.java` | 132 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 9 | `CustomerorderBatchService.java` | 140 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 10 | `CustomerorderBatchService.java` | 198 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 11 | `CustomerorderBatchService.java` | 422 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 12 | `CustomerorderBatchService.java` | 518 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 13 | `CustomerorderService.java` | 475 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 14 | `StockunitService.java` | 124 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 15 | `StockunitBusinessService.java` | 163 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 16 | `UnitloadBusinessService.java` | 107 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 17 | `UnitloadBusinessService.java` | 178 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |

#### Advice & Receiving Services (3 files, 6 annotations)

| # | File | Line | Current Annotation | Risk |
|---|------|------|--------------------|------|
| 18 | `AdviceService.java` | 115 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 19 | `AdviceService.java` | 135 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 20 | `AdviceService.java` | 276 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 21 | `AdviceService.java` | 390 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 22 | `GoodsReceiptPositionService.java` | 78 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |
| 23 | `GoodsReceiptPositionService.java` | 116 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | MEDIUM |

#### Picking & Merge Services (2 files, 2 annotations)

| # | File | Line | Current Annotation | Risk |
|---|------|------|--------------------|------|
| 24 | `PickingOrderMergeService.java` | 45 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | MEDIUM |
| 25 | `SequenceTransactionService.java` | 23 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |

#### Mobile Services (2 files, 8 annotations)

| # | File | Line | Current Annotation | Risk |
|---|------|------|--------------------|------|
| 26 | `MobileReplenishService.java` | 204 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 27 | `MobileReplenishService.java` | 235 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 28 | `MobileReplenishService.java` | 252 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 29 | `MobileReplenishService.java` | 401 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 30 | `MobileReplenishService.java` | 717 | `@Transactional` | LOW |
| 31 | `MobilePutAwayService.java` | 144 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 32 | `MobilePutAwayService.java` | 169 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |
| 33 | `MobilePutAwayService.java` | 406 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | HIGH |

#### Scheduled Job Services (2 files, 8 annotations)

| # | File | Line | Current Annotation | Risk |
|---|------|------|--------------------|------|
| 34 | `ReplenishOrderJobService.java` | 69 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |
| 35 | `ReplenishOrderJobService.java` | 87 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |
| 36 | `ReplenishOrderJobService.java` | 101 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |
| 37 | `ReplenishOrderJobService.java` | 199 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |
| 38 | `ReplenishOrderJobService.java` | 227 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |
| 39 | `ReplenishOrderJobService.java` | 238 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |
| 40 | `ReplenishOrderJobService.java` | 248 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |
| 41 | `ReleaseOrderJobService.java` | 91 | `@Transactional(propagation = Propagation.REQUIRES_NEW)` | HIGH |

#### View Services (1 file, 2 annotations)

| # | File | Line | Current Annotation | Risk |
|---|------|------|--------------------|------|
| 42 | `ParcelMonitorViewService.java` | 91 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | LOW |
| 43 | `ParcelMonitorViewService.java` | 179 | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | LOW |

#### Generator Services (1 file, 1 annotation)

| # | File | Line | Current Annotation | Risk |
|---|------|------|--------------------|------|
| 44 | `ReplenishGeneratorService.java` | 90 | `@Transactional(propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class)` | HIGH |

---

## 3. Fix Approach

### The Fix

For every `@Transactional` in tenant service classes, add `value = "tenantTransactionManager"`:

**Before:**
```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
```

**After:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
```

**For `REQUIRES_NEW` methods — Before:**
```java
@Transactional(propagation = Propagation.REQUIRES_NEW)
```

**After:**
```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
```

### What NOT to Change

1. **`LandlordService.java`** — Correctly uses default (landlord) TM for master DB operations
2. **Repository `@Transactional`** — Automatically uses `tenantTransactionManager` via `@EnableJpaRepositories` config
3. **Repository `@Modifying`** — Same as above, inherits TM from config

---

## 4. Implementation Phases

### Phase 1: Scheduled Jobs & Sequence Service (HIGH priority)
**Risk:** Medium — Jobs run independently, easy to test in isolation
**Files:** 3 files, 9 annotations

These are the most critical because `REQUIRES_NEW` creates **new** transactions. Without the correct TM, each new transaction is on the landlord DB.

| File | Lines | Fix |
|------|-------|-----|
| `ReplenishOrderJobService.java` | 69, 87, 101, 199, 227, 238, 248 | Add `value = "tenantTransactionManager"` to all 7 |
| `ReleaseOrderJobService.java` | 91 | Add `value = "tenantTransactionManager"` |
| `SequenceTransactionService.java` | 23 | Add `value = "tenantTransactionManager"` |

### Phase 2: Core Business Services (HIGH priority)
**Risk:** Medium-High — These are write-heavy services called from multiple paths
**Files:** 5 files, 11 annotations

| File | Lines | Fix |
|------|-------|-----|
| `TransferOrderService.java` | 79, 104, 322 | Add `value = "tenantTransactionManager"` to all 3 |
| `StockunitService.java` | 124 | Add `value = "tenantTransactionManager"` |
| `StockunitBusinessService.java` | 163 | Add `value = "tenantTransactionManager"` |
| `UnitloadBusinessService.java` | 107, 178 | Add `value = "tenantTransactionManager"` to both |
| `BillofladingService.java` | 197, 711, 902 | Add `value = "tenantTransactionManager"` to all 3 |

### Phase 3: Mobile Services (HIGH priority)
**Risk:** Medium — Active mobile operations, handheld device flows
**Files:** 2 files, 8 annotations

| File | Lines | Fix |
|------|-------|-----|
| `MobileReplenishService.java` | 204, 235, 252, 401, 717 | Add `value = "tenantTransactionManager"` to all 5 |
| `MobilePutAwayService.java` | 144, 169, 406 | Add `value = "tenantTransactionManager"` to all 3 |

### Phase 4: Order & Picking Services (MEDIUM priority)
**Risk:** Low-Medium — Some methods called from already-fixed callers
**Files:** 3 files, 9 annotations

| File | Lines | Fix |
|------|-------|-----|
| `CustomerorderBatchService.java` | 124, 132, 140, 198, 422, 518 | Add `value = "tenantTransactionManager"` to all 6 |
| `CustomerorderService.java` | 475 | Add `value = "tenantTransactionManager"` |
| `PickingOrderMergeService.java` | 45 | Add `value = "tenantTransactionManager"` |
| `ReplenishGeneratorService.java` | 90 | Add `value = "tenantTransactionManager"` |

### Phase 5: Advice, Receiving & View Services (MEDIUM priority)
**Risk:** Low — Mostly batch operations and views
**Files:** 3 files, 8 annotations

| File | Lines | Fix |
|------|-------|-----|
| `AdviceService.java` | 115, 135, 276, 390 | Add `value = "tenantTransactionManager"` to all 4 |
| `GoodsReceiptPositionService.java` | 78, 116 | Add `value = "tenantTransactionManager"` to both |
| `ParcelMonitorViewService.java` | 91, 179 | Add `value = "tenantTransactionManager"` to both |

---

## 5. Testing Strategy

### Per-Phase Verification
After each phase:
1. `mvn compile -DskipTests` — verify compilation
2. `mvn test` — run full test suite
3. Smoke test the affected flows in a local environment

### Key Flows to Test
- **Phase 1:** Trigger replenish and release jobs via scheduler or manual endpoint
- **Phase 2:** Transfer stock, close BOL, modify stock units
- **Phase 3:** Mobile replenish scan, mobile put-away scan
- **Phase 4:** Order batch processing, picking order merge, order release
- **Phase 5:** Receive advice, close advice, goods receipt

---

## 6. Risk Assessment

### Behavioral Change

Adding the correct transaction manager changes behavior in the following ways:

| Aspect | Before (landlord TM) | After (tenant TM) |
|--------|----------------------|---------------------|
| Transaction scope | Each repo call auto-commits independently | All repo calls share one transaction |
| Rollback on exception | Only landlord TX rolls back (no effect) | All tenant writes roll back together |
| L1 cache | Disabled (separate sessions) | Enabled (shared session) |
| Connection usage | N connections for N repo calls | 1 connection for the entire method |
| Entity state | Always detached between calls | Managed within transaction |

### Potential Risks

1. **Longer transactions** — Wrapping multiple repo calls in one transaction means DB locks are held longer. This is correct behavior but may surface latent concurrency issues that were previously masked by auto-commit.
2. **Rollback changes behavior** — Previously, a failure midway would leave partial writes committed. Now it rolls back everything. This is *correct* but *different*. Any code that depends on partial writes surviving failures will break.
3. **Managed entity state** — Entities loaded within the transaction are now managed (dirty-checking active). If code modifies entity fields without intending to persist them, those changes may now auto-flush.
4. **`REQUIRES_NEW` with correct TM** — Methods with `Propagation.REQUIRES_NEW` will now correctly create new tenant transactions. Previously they created landlord transactions. This is a significant behavioral change for `ReplenishOrderJobService` and `SequenceTransactionService`.

### Mitigation

- Deploy phase-by-phase, testing each flow in isolation
- Monitor database connection pool metrics after deployment
- Watch for `OptimisticLockException` increases (longer transactions = higher conflict probability)
- Each phase is independently revertible (just remove the `value` parameter)

---

## 7. Summary

| Phase | Files | Annotations | Priority | Risk | Status |
|-------|-------|-------------|----------|------|--------|
| 1 | 3 | 9 | HIGH | Medium | DONE |
| 2 | 5 | 11 | HIGH | Medium-High | DONE |
| 3 | 2 | 8 | HIGH | Medium | DONE |
| 4 | 4 | 8 | MEDIUM | Low-Medium | DONE |
| 5 | 3 | 8 | MEDIUM | Low | DONE |
| **Total** | **17** | **44** | | | **ALL COMPLETE** |
