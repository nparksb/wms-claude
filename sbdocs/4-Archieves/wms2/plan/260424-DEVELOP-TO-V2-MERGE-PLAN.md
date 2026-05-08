# Merge Plan: `develop` -> `v2/develop-260228`

**Created:** 2026-03-01
**Branches:** `develop` (source) -> `v2/develop-260228` (target)
**Common Ancestor:** `b0d2dde`

---

## Migration Status

**Last Updated:** 2026-03-02
**Status:** Sections 2.1 and 2.2 COMPLETE (23/23 commits ported)

### Completed (2026-03-02)
- **All 13 Feature Commits (Section 2.1):** Ported and tested
- **All 10 Bug Fix Commits (Section 2.2):** Ported and tested
- **Build:** `mvn clean package` — BUILD SUCCESS
- **Tests:** 3,651 tests run, 0 failures, 0 errors, 3 skipped

### Files Modified (Production Code)
| Layer | Files Modified | Files Created |
|-------|---------------|---------------|
| Repository | 7 (ReplenishorderRepo, StockunitRepo, FixLocationAssignmentRepo, ParcelMonitorViewRepo, PickingorderUnitloadRepo, UnitloadRepo, ReplenishOrderDetailView) | 0 |
| Service | 12 (ReplenishOrderJob, ReplenishOrderJobService, ReplenishGeneratorService, FixLocationAssignmentService, StockunitService, StockunitBusinessService, MobileReplenishService, MobileMoveStockService, MobileMoveUnitloadService, MobilePickingService, UnitloadRecordService, HttpRestService) | 1 (ReplenishmentOrderMaintenanceService) |
| Controller | 5 (AdminActionController, UserController, ReportController, FixLocationAssignmentController, OrderRestController) | 0 |
| DTO/View | 1 (ViewDtoService) | 0 |
| Config | 2 (WmsConstants, messages_en_US.properties) | 0 |

### Test Files Modified/Created
| File | Action |
|------|--------|
| ReplenishmentOrderMaintenanceServiceUnitTest.java | **Created** (32 tests) |
| AdminActionControllerUnitTest.java | Updated (added 3 new mock deps) |
| ReportControllerUnitTest.java | Updated (parcelFilter param) |
| ViewDtoServiceUnitTest.java | Updated (parcelFilter param) |
| ReplenishOrderJobTest.java | Updated (per-FLA loop mocks) |
| FixLocationAssignmentControllerUnitTest.java | Updated (move boolean change) |
| StockunitBusinessServiceUnitTest.java | Updated (pessimistic lock mocks) |
| StockunitServiceUnitTest.java | Updated (setLockDamaged rewrite mocks) |
| UnitloadRecordServiceUnitTest.java | Updated (save return value mock) |

### Remaining (Not Yet Ported)
- **Section 2.3 Performance Commits:** `bcd948d` (closeBOL optimization), `006e24e` (5-phase concurrency fix) — deferred per user request
- **Section 2.4 Test & Infrastructure:** JaCoCo plugin, surefire/failsafe config — not requested
- **Phase 4 HIGH-risk services:** TransferOrderService, CustomerorderBatchService, UnitloadBusinessService, BillofladingService — not part of 2.1/2.2 scope
- **Phase 5 remaining controllers:** BillOfLadingController, ClubLineController, TransfersController — dependent on Phase 4

### Platform Gap Compliance
All ported code follows v2 patterns:
- `jakarta.*` namespaces (no `javax.*`)
- Constructor injection (no `@Autowired` field injection)
- `@Transactional(value = "tenantTransactionManager")` on all tenant service methods
- `User` / `SyspropRepository` (v2 renames applied)
- `.getId().equals()` for entity comparisons
- No manual `getNextId()` calls

---

## Executive Summary

The `develop` branch contains **85 commits** (50 non-merge) with **176 files changed** (+50,002 / -1,751 lines) that are not present in `v2/develop-260228`. The changes span production bug fixes (SBDEV tickets), a new replenishment maintenance service, closeBOL performance optimization, concurrency fixes, unit test infrastructure, and various UI-facing endpoint additions.

**This is NOT a routine merge.** The `v2/develop-260228` branch has undergone a major platform migration (Spring Boot 2.3.7 -> 3.5.9, Java 8 -> 21, Hibernate 5 -> 6, `javax.*` -> `jakarta.*`) with 90+ commits of its own. **44 Java source files were modified on both branches** and will produce merge conflicts.

**Recommended approach:** Treat this as a **port-and-merge** operation. Use `v2/develop-260228` as the base (it has the correct platform patterns) and manually apply `develop`'s business logic changes on top.

---

## Table of Contents

1. [Platform Gap](#1-platform-gap)
2. [Commit Inventory](#2-commit-inventory)
3. [File Conflict Classification](#3-file-conflict-classification)
4. [Decision Points](#4-decision-points)
5. [Merge Strategy](#5-merge-strategy)
6. [Phase-by-Phase Implementation](#6-phase-by-phase-implementation)
7. [Migration Checklist](#7-migration-checklist)
8. [Risk Assessment](#8-risk-assessment)

---

## 1. Platform Gap

| Property | `v2/develop-260228` (target) | `develop` (source) |
|----------|------------------------------|---------------------|
| Spring Boot | **3.5.9** | 2.3.7.RELEASE |
| Java | **21** | 1.8 |
| Spring Cloud | 2025.0.1 | Hoxton.SR10 |
| Hibernate | 6.x | 5.x |
| Namespace | `jakarta.*` | `javax.*` |
| Dockerfile | `eclipse-temurin:21-alpine` | `adoptopenjdk/openjdk8:alpine` |
| cups4j | `org.cups4j:cups4j:0.7.9` (Maven Central) | `cups4j:cups4j:0.6.4` (local JAR) |

**Every file ported from `develop` must have:**
- `javax.persistence.*` -> `jakarta.persistence.*`
- `javax.validation.*` -> `jakarta.validation.*`
- `javax.servlet.*` -> `jakarta.servlet.*`
- `javax.annotation.*` -> `jakarta.annotation.*`
- `@Autowired` field injection -> constructor injection (v2 pattern)
- Bare `@Transactional` -> `@Transactional(value = "tenantTransactionManager")` (for tenant services)
- Manual `getNextId()` calls removed (Hibernate 6 handles IDs)
- `MywmsUser` -> `User`, `LosSyspropRepository` -> `SyspropRepository` (v2 renames)
- Entity `.equals()` comparisons -> `.getId().equals()` (entities lack proper equals/hashCode)

---

## 2. Commit Inventory

### 2.1 Feature Commits (Port Required)

| Commit | SBDEV | Description | Risk | Status |
|--------|-------|-------------|------|--------|
| `74e22e8` | SBDEV-1955 | Admin endpoint to finish stuck picking orders with OMS notification | MEDIUM | PORTED 2026-03-02 |
| `fd13cd2` | SBDEV-1742 | New `ReplenishmentOrderMaintenanceService` | HIGH | PORTED 2026-03-02 |
| `c64948a` | SBDEV-1742 | Enhance replenishment order management | HIGH | PORTED 2026-03-02 |
| `d72c4f6` | SBDEV-1742 | Integrate maintenance service for open orders recalculation | HIGH | PORTED 2026-03-02 |
| `27d842a` | SBDEV-1742 | Refactor `sumRequestedAmountForOpenOrders` query | MEDIUM | PORTED 2026-03-02 |
| `7109798` | SBDEV-1742 | Enhance source usability check (available amount incl. reservations) | MEDIUM | PORTED 2026-03-02 |
| `cec88c0` | SBDEV-1742 | Case-insensitive unit load search | LOW | PORTED 2026-03-02 |
| `26d4ca2` | SBDEV-1708 | Multi-unit-load replenishment | MEDIUM | PORTED 2026-03-02 (controller already existed on v2) |
| `2d8fa8c` | - | Bulk edit printer for users API | LOW | PORTED 2026-03-02 |
| `4f6a453` | - | Enhance filtering in outbound parcel report | LOW | PORTED 2026-03-02 |
| `0e852c2` | - | Sort CART containers first | LOW | PORTED 2026-03-02 |
| `daadb87` | - | Sort completed column desc by default | LOW | PORTED 2026-03-02 |
| `6389d4b` | - | Add item name under picking order number | LOW | PORTED 2026-03-02 |

### 2.2 Bug Fix Commits (Port Required)

| Commit | SBDEV | Description | Risk | Status |
|--------|-------|-------------|------|--------|
| `b545fee` | - | Isolate replenishment refill loop (one FLA failure doesn't abort all) | HIGH | PORTED 2026-03-02 |
| `112cd74` | SBDEV-1953 | Move to Damaged assigns wrong type to UL | MEDIUM | PORTED 2026-03-02 |
| `85f786f` | SBDEV-1710 | Pessimistic locking for `changeReservedAmount` | HIGH | PORTED 2026-03-02 |
| `c4ac107` | SBDEV-1710 | Allocation more than on hand | MEDIUM | PORTED 2026-03-02 |
| `05dea1b` | SBDEV-1526 | Move fixed location updates picking order positions | MEDIUM | PORTED 2026-03-02 |
| `a52b78a` | SBDEV-1514 | Allow re-creation of cancelled transfer order | LOW | PORTED 2026-03-02 |
| `a29738a` | SBDEV-1746 | Transfer to Damaged breaks flowbins | MEDIUM | PORTED 2026-03-02 |
| `cfc3ae2` | - | Transaction boundaries + silent failure fixes on UL move paths | HIGH | PORTED 2026-03-02 |
| `0fc58c7` | - | Transaction boundaries + HTTP timeouts to picking flow | MEDIUM | PORTED 2026-03-02 |
| `58f2b5d` | SBDEV-1604 | Fixed lacking column (modified field) | LOW | PORTED 2026-03-02 |

### 2.3 Performance Commits (Port Required - Conflict)

| Commit | Description | Risk |
|--------|-------------|------|
| `bcd948d` | closeBOL() optimization (~2,160 queries -> ~30-50) | **CRITICAL** |
| `006e24e` | 5-phase concurrency fix (optimistic lock safety) | HIGH |

### 2.4 Test & Infrastructure Commits (Port As-Is)

| Commit | Description | Risk |
|--------|-------------|------|
| `a6631f1` - `d68371e` | 1500+ unit tests across 12 phases | LOW |
| `415585e` | JaCoCo coverage plugin | LOW |
| `4eb0e10` | Separate unit/integration test Maven config | LOW |
| `3f1edc7` | Replace cups4j local JAR with Maven Central | LOW (already done on v2) |

### 2.5 Commits Already Superseded on v2 (Skip)

| Commit | Description | Why Skip |
|--------|-------------|----------|
| `3f1edc7` | cups4j replacement | Already done on v2 |
| `fa87a26` | Remove duplicate methods | Compilation fix for develop only |
| `eb4ed67` | Replace `Optional.isEmpty()` with `!isPresent()` | Java 8 fix; v2 uses Java 21 (keep `isEmpty()`) |
| `ccf861d` | Dockerfile Java 8 JRE update | v2 uses Java 21 |
| `5979d8a` | Docker UAT Image CI workflow | Review separately |
| `ee249c4`, `f149843` | Flyway config changes | v2 has its own flyway config |

---

## 3. File Conflict Classification

### 3.1 HIGH Risk - Manual Merge Required (6 files)

These files were **substantially rewritten on both branches** for different reasons. Automated merge will produce broken code.

#### `BillofladingService.java` - **CRITICAL**
- **develop:** closeBOL optimization with bulk pre-loading, in-memory position tree, repository-based bulk JPQL updates, `transferPalletTreesToLocation()`, `deleteGarbageByBillofladingId()`
- **v2:** Its own independent closeBOL optimization with `EntityManager` bulk queries, `batchRecordForTransfer()`, `ConcurrentHashMap.newKeySet()`, projection-based `ManifestLocationView`
- **Resolution:** Keep v2's optimization as base (more advanced with EntityManager bulk queries). Port develop's `closeBOL(Long bolId)` ID-based signature (avoids stale entity issues). Port `deleteGarbageByBillofladingId()` repository method.

#### `StockunitBusinessService.java` - **CRITICAL**
- **develop:** `changeReservedAmount()` uses pessimistic locking (`findByIdForUpdate()`). Removed `transferStockToUnitLoad()` overload with pre-loaded FLA.
- **v2:** `changeReservedAmount()` uses optimistic retry loop. Has `transferStockToUnitLoad()` overload with FLA (performance optimization). Has `@Lazy`, `ensureInitialized()`.
- **Resolution:** Adopt develop's pessimistic locking for `changeReservedAmount()` (cleaner, more correct). Keep v2's `transferStockToUnitLoad()` FLA overload and `createStockUnit()` overload. Keep v2's `ensureInitialized()` pattern. See [Decision Point #1](#dp1).

#### `TransferOrderService.java` - **CRITICAL**
- **develop:** Method signatures changed to IDs: `assignTransferLaneToTransferOrder(Long, Long)`, `activateTransferOrder(Long, Long)`. Pessimistic locking via `findByIdForUpdate()`.
- **v2:** Methods accept entity objects. Has batch pre-fetch optimizations.
- **Resolution:** Adopt develop's ID-based signatures (enables internal pessimistic locking). Keep v2's batch pre-fetch optimizations inside methods. Update all controller callers to pass IDs.

#### `CustomerorderBatchService.java` - **CRITICAL**
- **develop:** Same ID-based signature pattern as TransferOrderService. Pessimistic locking.
- **v2:** Entity-based signatures. Has batch pre-fetch in `runClubLine()`.
- **Resolution:** Same as TransferOrderService. Adopt ID signatures, keep v2 pre-fetch optimizations.

#### `UnitloadBusinessService.java` - HIGH
- **develop:** Added `transferPalletTreesToLocation()` for closeBOL optimization. BFS tree traversal, bulk `updateStoragelocationByIds()`, batch `UnitloadRecord` creation.
- **v2:** Has `@Lazy`, `ensureInitialized()`, `OptimisticLockRetry` injection. Does NOT have `transferPalletTreesToLocation()`.
- **Resolution:** Port `transferPalletTreesToLocation()` from develop into v2 base, adapting to v2 patterns (`jakarta.*`, `tenantTransactionManager`, constructor injection).

#### `WmsConstants.java` - HIGH
- **develop:** Added replenishment recalculation constants, CUPS defaults. Removed `LOADED_TO_TRUCK` state and related URLs. Removed `String.format()` error guard.
- **v2:** Has `LOADED_TO_TRUCK`, has safe `String.format()` guard.
- **Resolution:** Port new constants. Keep v2's `String.format()` guard (prevents crashes). See [Decision Point #3](#dp3) for `LOADED_TO_TRUCK`.

### 3.2 MEDIUM Risk - Targeted Porting (16 files)

These files have localized changes on `develop` that can be ported into the v2 base with care.

| File | develop Change | v2 Adaptation Needed |
|------|----------------|----------------------|
| `StockunitService.java` | Added `triggerReplenishmentMaintenance()` calls after stock operations. Changed `markAsDamaged()` logic. | Port maintenance triggers. Keep v2's conditional `markAsDamaged()` logic (more correct). Map `SharedService` references. |
| `ReplenishGeneratorService.java` | Updated source validation | Keep v2's `refillSingleFixedLocation()` + idempotency check. Port any new validation logic. |
| `ReplenishOrderJobService.java` | Added `getRefillFixedLocationIds()`, integrated `ReplenishmentOrderMaintenanceService` | Port new methods. Keep v2's `@Scheduled` pattern. |
| `ReplenishOrderJob.java` | Refactored to per-FLA loop with try/catch isolation | Port the per-FLA loop pattern. Inject `ReplenishmentOrderMaintenanceService`. |
| `MobilePickingService.java` | Removed `User` parameter from `startPickingOrder()` / `confirmPick()`. Pessimistic locking. | Adopt simplified signatures. Both branches have `findByIdForUpdate()` - merge cleanly. |
| `MobileReplenishService.java` | Added `fulfillMultipleUnitLoads()` for multi-UL replenishment | Verify v2 already has this (likely ported). Compare implementations. |
| `PickingorderBusinessService.java` | Simplified signatures (removed `User` parameter). Removed `cleanUpCancelledOrder()`. | Adopt simplified signatures. Verify `cleanUpCancelledOrder()` unused before removing. |
| `ViewDtoService.java` | Added `parcelFilter` parameter to `getParcelMonitorViewByKeyword()` | Port parameter addition. v2 uses projections - adapt query. |
| `UnitloadRecordService.java` | Standard patterns only | Keep v2's `batchRecordForTransfer()`. Minimal functional change. |
| `AdminActionController.java` | New `finishStuckPickingOrder` endpoint | Purely additive. Map `LosSyspropService` -> `SyspropService`. |
| `BillOfLadingController.java` | `closeBOL(id)` signature change + `OptimisticLockRetryTemplate` wrapping | Align with v2's closeBOL signature. v2 has its own `OptimisticLockRetry`. |
| `ClubLineController.java` | ID-based service calls + retry wrapping | Coupled to `CustomerorderBatchService` signature changes. Apply together. |
| `TransfersController.java` | ID-based service calls + retry wrapping | Coupled to `TransferOrderService` signature changes. Apply together. |
| `OrderRestController.java` | Transfer order deduplication fix (allow re-create if FINISHED). Priority retry wrapping. | Port deduplication fix. Use v2's `OptimisticLockRetry` instead of `OptimisticLockRetryTemplate`. |
| `UserController.java` | New `bulkEditUsers` endpoint | Map `MywmsUser` -> `User`, `mywmsUserRepository` -> `userRepository`. |
| `ReportController.java` | Added `parcelFilter` parameter | Purely additive. |
| `MultiReplenishUnitLoadDto.java` | Added `@JsonAlias` annotations | `javax.validation.*` -> `jakarta.validation.*` |

### 3.3 LOW Risk - Additive Repository Changes (14 files)

These are purely additive new queries/methods. Port directly with `javax` -> `jakarta` fix.

| File | New Methods | Notes |
|------|-------------|-------|
| `BillofladingPositionRepository.java` | `updateStateByBillofladingId()`, `deleteGarbageByBillofladingId()` | Additive |
| `CustomerorderPositionRepository.java` | `updateStateByOrderIds()` | Additive |
| `CustomerorderRepository.java` | `updateStateByIds()` | **Signature conflict with v2** - v2 has `int updateStateByIds(List<Long>, int)`, develop has `void updateStateByIds(Integer, Collection<Long>)`. Reconcile parameter order. |
| `FixLocationAssignmentRepository.java` | `getRefillFixedLocationIds()`, query filter additions | Additive |
| `ParcelMonitorViewRepository.java` | `findByKeywordAndParcelPalletized()`, `findByKeywordAndParcelUnpalletized()` | Additive |
| `PickingorderRepository.java` | `findByIdForUpdate()` | **Already exists on v2** - skip |
| `PickingorderUnitloadRepository.java` | `findByPickingorderId()` | Additive |
| `ReplenishorderRepository.java` | `findByState()`, `sumRequestedAmountForOpenOrders()` | Additive |
| `StockunitRepository.java` | `getStockAndReservedForLocation()`, `getStockAndReservedForPickingAreas()`, `getAvailableReplenishmentSources()`, `updateEntityLockByUnitloadIds()` | Additive. `findByIdForUpdate()` already on v2 - skip |
| `UnitloadRecordRepository.java` | `getNextIds()` | Additive |
| `UnitloadRepository.java` | `findByLabelidIgnoreCase()`, `updateEntityLockByIds()`, `updateStoragelocationByIds()` | Additive. `findByCarrierunitloadIdIn` bug fix already on v2. |
| `AdviceRepository.java` | Version bump + idempotency guard on `updateAdviceToStateById` | Additive |
| `AdvicepositionRepository.java` | Version bump + idempotency guard on `updateAdvicepositionToStateByAdviceId` | Additive |
| `BillofladingRepository.java` | `findByIdForUpdate()` | **Already exists on v2** - skip. `deleteBolByBolNumber` guard already on v2. |

### 3.4 New Files to Port (2 files)

| File | Description | Dependencies |
|------|-------------|--------------|
| `ReplenishmentOrderMaintenanceService.java` | Cadence-based replenishment recalculation, source validation/redirect, cancel/update logic | Needs `SyspropRepository` (not `LosSyspropRepository`), `tenantTransactionManager`, `jakarta.*` |
| `OptimisticLockRetryTemplate.java` | Static retry utility with exponential backoff | **v2 already has `OptimisticLockRetry.java`** in `net.aim_ai.wms.util` - consolidate. See [Decision Point #2](#dp2). |

### 3.5 Test Files (90+ files, LOW risk)

All test files from `develop` can be ported with these adaptations:
- `javax.*` -> `jakarta.*` imports
- `MywmsUser` -> `User`, `LosSyspropRepository` -> `SyspropRepository`
- `BaseServiceTest`, `BaseControllerTest`, `BaseRepositoryTest` base classes must exist on v2
- Remove `demo/*` test files (already deleted on v2)
- Test config `application.properties` may need merge with v2's test config

### 3.6 Documentation & Config (Safe to Port)

| File | Action |
|------|--------|
| `docs/analysis/*` | Copy as-is |
| `docs/plan/*` | Copy as-is (already exist some) |
| `docs/260424-replenish-order-updates.md` | Copy as-is |
| `src/main/resources/application.properties` | Port Hibernate batch settings (3 lines) |
| `src/main/resources/messages_en_US.properties` | Port `MsgUnitLoadNotFound` message |
| `src/test/resources/schema-repoh2.sql` | Port if H2 still used for tests |
| `.gitignore` | Merge additions |
| `pom.xml` | Port JaCoCo plugin + surefire/failsafe config. H2 dependency - see decision. |

---

## 4. Decision Points

<a id="dp1"></a>
### Decision #1: Concurrency Strategy for `changeReservedAmount()`

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| **A (Recommended)** | Pessimistic lock (`findByIdForUpdate()`) from develop | Simpler, more correct, no retry loop | May cause contention under high concurrency |
| B | Optimistic retry from v2 | No lock contention | Complex retry loop, harder to reason about |

**Recommendation:** Option A - pessimistic locking is cleaner and `changeReservedAmount()` is not a high-contention path.

<a id="dp2"></a>
### Decision #2: Optimistic Lock Retry Utility

| Option | Approach | Notes |
|--------|----------|-------|
| **A (Recommended)** | Keep v2's `OptimisticLockRetry.java` only | Already a Spring `@Component`, catches `StaleObjectStateException`, injectable. More complete. |
| B | Port develop's `OptimisticLockRetryTemplate.java` too | Static utility, different API. Redundant with v2's version. |

**Recommendation:** Option A - keep v2's `OptimisticLockRetry` and rewrite develop's controller-level retry wrapping to use it.

<a id="dp3"></a>
### Decision #3: `LOADED_TO_TRUCK` State

| Option | Approach | Notes |
|--------|----------|-------|
| A | Remove from v2 (follow develop) | If truck loading feature is deprecated |
| **B (Recommended)** | Keep on v2 | v2 already uses it. Removing may break existing functionality. |

**Recommendation:** Option B - keep it until explicitly deprecated.

<a id="dp4"></a>
### Decision #4: `closeBOL` Optimization Approach

| Option | Approach | Notes |
|--------|----------|-------|
| **A (Recommended)** | Keep v2's EntityManager-based optimization as primary | More advanced, better performance. Add develop's `deleteGarbageByBillofladingId()`. Adopt `closeBOL(Long id)` signature. |
| B | Replace with develop's repository-based approach | Simpler code but less performant. Loses v2's `batchRecordForTransfer()`. |

**Recommendation:** Option A - v2's optimization is more mature.

<a id="dp5"></a>
### Decision #5: Method Signature Pattern (Entity vs ID)

| Option | Approach | Notes |
|--------|----------|-------|
| **A (Recommended)** | Adopt develop's ID-based signatures for `TransferOrderService`, `CustomerorderBatchService` | Cleaner API, enables internal pessimistic locking, less stale-entity risk |
| B | Keep v2's entity-based signatures | Less controller refactoring, but callers must manage entity freshness |

**Recommendation:** Option A - ID-based signatures are safer and more maintainable.

---

## 5. Merge Strategy

### Approach: **v2 Base + Develop Feature Port**

```
v2/develop-260228 (target - keep as base)
    |
    +-- Port develop features manually, file by file
    |
    +-- Adapt each file to v2 patterns (jakarta, constructor injection, tenantTM)
    |
    +-- Compile-check after each phase
```

**DO NOT run `git merge develop` directly.** The 44 conflicting files will produce unresolvable auto-merge conflicts due to the platform gap.

### Workflow Per File

1. Read v2 version (current state)
2. Read develop version (source features)
3. Identify the delta (what develop added that v2 doesn't have)
4. Apply the delta to v2's version, adapting patterns
5. Run `mvn compile -DskipTests` to verify
6. Commit

---

## 6. Phase-by-Phase Implementation

### Phase 0: Preparation
- [ ] Create a working branch from `v2/develop-260228`: `git checkout -b merge/develop-to-v2 v2/develop-260228`
- [ ] Verify `mvn clean compile -DskipTests` passes on the clean branch
- [ ] Review and confirm decision points above

### Phase 1: New Files & Dependencies (No Conflicts)
**Estimated effort: 1-2 hours**

- [ ] Port `ReplenishmentOrderMaintenanceService.java` (adapt `javax` -> `jakarta`, `LosSyspropRepository` -> `SyspropRepository`, add `@Transactional(value="tenantTransactionManager")`)
- [ ] Port new `WmsConstants` entries (replenishment recalculation constants, CUPS defaults)
- [ ] Port `messages_en_US.properties` addition (`MsgUnitLoadNotFound`)
- [ ] Port `application.properties` Hibernate batch settings
- [ ] Compile check

### Phase 2: Repository Layer (LOW Risk Additives)
**Estimated effort: 1-2 hours**

- [ ] Port additive repository methods (skip methods already on v2):
  - `BillofladingPositionRepository` - `updateStateByBillofladingId()`, `deleteGarbageByBillofladingId()`
  - `CustomerorderPositionRepository` - `updateStateByOrderIds()`
  - `CustomerorderRepository` - reconcile `updateStateByIds()` signature conflict
  - `FixLocationAssignmentRepository` - `getRefillFixedLocationIds()`, query filter additions
  - `ParcelMonitorViewRepository` - two new filter methods
  - `PickingorderUnitloadRepository` - `findByPickingorderId()`
  - `ReplenishorderRepository` - `findByState()`, `sumRequestedAmountForOpenOrders()`
  - `StockunitRepository` - 3 new native queries, `updateEntityLockByUnitloadIds()`
  - `UnitloadRecordRepository` - `getNextIds()`
  - `UnitloadRepository` - `findByLabelidIgnoreCase()`, 2 bulk update methods
  - `AdviceRepository` - version bump + idempotency guard
  - `AdvicepositionRepository` - version bump + idempotency guard
- [ ] All `javax.persistence.LockModeType` -> `jakarta.persistence.LockModeType`
- [ ] Compile check

### Phase 3: Service Layer - LOW/MEDIUM Risk
**Estimated effort: 2-3 hours**

- [ ] `StockunitService.java` - Add `triggerReplenishmentMaintenance()` calls. Keep v2's `markAsDamaged()` logic.
- [ ] `ReplenishGeneratorService.java` - Port new validation logic. Keep v2's `refillSingleFixedLocation()`.
- [ ] `ReplenishOrderJobService.java` - Add `getRefillFixedLocationIds()`, integrate `ReplenishmentOrderMaintenanceService`.
- [ ] `ReplenishOrderJob.java` - Port per-FLA loop with try/catch isolation.
- [ ] `PickingorderBusinessService.java` - Simplify signatures (remove `User` parameter). Verify `cleanUpCancelledOrder()` unused.
- [ ] `ViewDtoService.java` - Add `parcelFilter` parameter.
- [ ] `HttpRestService.java` - Port HTTP timeout setting.
- [ ] `MobileMoveStockService.java` - Minor changes.
- [ ] `MobileMoveUnitloadService.java` - Keep v2's method-level `tenantTransactionManager`.
- [ ] `MobilePickingService.java` - Adopt simplified `startPickingOrder()`/`confirmPick()` signatures.
- [ ] `MobileReplenishService.java` - Verify `fulfillMultipleUnitLoads()` already ported. If not, port with jakarta adaptations.
- [ ] `UnitloadRecordService.java` - Keep v2's `batchRecordForTransfer()`.
- [ ] `CustomerorderService.java` - Minor changes.
- [ ] `FixLocationAssignmentService.java` - Minor changes.
- [ ] Compile check

### Phase 4: Service Layer - HIGH Risk (Manual Merge)
**Estimated effort: 4-6 hours**

- [ ] `StockunitBusinessService.java`:
  - Replace v2's optimistic retry in `changeReservedAmount()` with develop's pessimistic lock
  - Keep v2's `transferStockToUnitLoad()` FLA overload
  - Keep v2's `createStockUnit()` overload
  - Keep v2's `ensureInitialized()` pattern
  - Fix entity comparison: `.getId().equals()` not `.equals()`

- [ ] `TransferOrderService.java`:
  - Change method signatures to ID-based (from develop)
  - Keep v2's batch pre-fetch optimizations inside methods
  - Add pessimistic locking from develop
  - Fix `.contains()` -> `.stream().noneMatch(lane -> lane.getId().equals(...))`

- [ ] `CustomerorderBatchService.java`:
  - Same pattern as TransferOrderService
  - Change to ID-based signatures
  - Keep v2's `runClubLine()` FLA pre-fetch
  - Keep v2's `transferStockToUnitLoad()` with FLA overload

- [ ] `UnitloadBusinessService.java`:
  - Port `transferPalletTreesToLocation()` from develop
  - Adapt to v2 patterns (jakarta, tenantTM, constructor injection)
  - Keep v2's `@Lazy`, `ensureInitialized()`, `OptimisticLockRetry` injection

- [ ] `BillofladingService.java` (**most complex**):
  - Keep v2's closeBOL optimization as base
  - Adopt `closeBOL(Long bolId)` signature from develop (fetch entity internally)
  - Port `deleteGarbageByBillofladingId()` call
  - Evaluate whether `transferPalletTreesToLocation()` should replace or complement v2's inline approach

- [ ] `WmsConstants.java`:
  - Port new replenishment constants
  - Port CUPS defaults
  - Keep v2's `LOADED_TO_TRUCK` state
  - Keep v2's `String.format()` error guard

- [ ] Compile check

### Phase 5: Controller Layer
**Estimated effort: 2-3 hours**

- [ ] `AdminActionController.java` - Add `finishStuckPickingOrder` endpoint. Map to v2 service names.
- [ ] `BillOfLadingController.java` - Update `closeBOL()` call to match new service signature. Use v2's `OptimisticLockRetry`.
- [ ] `ClubLineController.java` - Update to pass IDs to service methods. Use v2's `OptimisticLockRetry`.
- [ ] `TransfersController.java` - Update to pass IDs to service methods. Use v2's `OptimisticLockRetry`.
- [ ] `OrderRestController.java` - Port transfer order deduplication fix (FINISHED state check). Priority retry.
- [ ] `UserController.java` - Port `bulkEditUsers`. Map `MywmsUser` -> `User`.
- [ ] `ReportController.java` - Add `parcelFilter` parameter.
- [ ] `FixLocationAssignmentController.java` - Port boolean argument change.
- [ ] `AdviceRestController.java` - Port code cleanup (cosmetic, low risk).
- [ ] Compile check

### Phase 6: Test Infrastructure
**Estimated effort: 3-4 hours**

- [ ] Port pom.xml changes: JaCoCo plugin, surefire/failsafe test separation config
- [ ] Port H2 test dependency (if needed for develop's test patterns)
- [ ] Port `BaseServiceTest`, `BaseControllerTest`, `BaseRepositoryTest` base classes (adapt to v2)
- [ ] Port unit test files in batches (adapt `javax` -> `jakarta`, entity/repo renames)
- [ ] Port `schema-repoh2.sql` if H2 tests retained
- [ ] Run full test suite: `mvn test`

### Phase 7: Documentation & Cleanup
**Estimated effort: 30 min**

- [ ] Port `docs/analysis/*` files
- [ ] Port `docs/260424-replenish-order-updates.md`
- [ ] Merge `.gitignore` additions
- [ ] Remove develop's `OptimisticLockRetryTemplate.java` (use v2's `OptimisticLockRetry` instead)
- [ ] Final compile + test run

---

## 7. Migration Checklist

### Global Pattern Replacements

```
javax.persistence.* -> jakarta.persistence.*
javax.validation.*  -> jakarta.validation.*
javax.servlet.*     -> jakarta.servlet.*
javax.annotation.*  -> jakarta.annotation.*
```

### Entity/Repository Renames

```
MywmsUser            -> User
MywmsUserRepository  -> UserRepository
LosSyspropRepository -> SyspropRepository
LosSyspropService    -> SyspropService (verify)
```

### Transaction Manager

Every `@Transactional` on a tenant service method MUST specify:
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
```

### Entity Comparison

Never use `.equals()` on JPA entities (they lack equals/hashCode). Use:
```java
// WRONG
entity1.equals(entity2)
list.contains(entity)

// CORRECT
entity1.getId().equals(entity2.getId())
list.stream().noneMatch(e -> e.getId().equals(target.getId()))
```

### Manual ID Generation

Remove all manual `getNextId()` calls - Hibernate 6 handles ID generation:
```java
// WRONG (develop pattern)
entity.setId(repository.getNextId());

// CORRECT (v2 pattern - let Hibernate generate IDs on save)
entity = repository.save(entity);
```

---

## 8. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| closeBOL merge breaks BOL processing | HIGH | CRITICAL | Extensive testing with production-like data. Keep v2's optimization, port selectively. |
| Transaction manager annotations missed | MEDIUM | HIGH | Grep for bare `@Transactional` in all ported code. |
| Entity comparison bugs | MEDIUM | MEDIUM | Grep for `.equals()` and `.contains()` on entity types in ported code. |
| Replenishment service integration breaks existing flow | MEDIUM | HIGH | Test replenishment end-to-end after Phase 3. |
| Test failures from javax/jakarta mismatch | HIGH | LOW | Systematic find-and-replace before running tests. |
| Missing method on v2 that develop's code calls | LOW | MEDIUM | Compile check after each phase catches this immediately. |

### Estimated Total Effort

| Phase | Effort |
|-------|--------|
| Phase 0: Preparation | 30 min |
| Phase 1: New Files | 1-2 hours |
| Phase 2: Repositories | 1-2 hours |
| Phase 3: Services (LOW/MED) | 2-3 hours |
| Phase 4: Services (HIGH) | 4-6 hours |
| Phase 5: Controllers | 2-3 hours |
| Phase 6: Tests | 3-4 hours |
| Phase 7: Cleanup | 30 min |
| **Total** | **~15-21 hours** |

---

## Appendix: Full Commit List (Non-Merge)

```
fa87a26 fix: remove duplicate method/variable definitions causing compilation errors
3f1edc7 Replace custom cups4j-0.6.4.jar with standard org.cups4j:cups4j:0.7.9 from Maven Central
b545fee fix: isolate replenishment refill loop so one FLA failure doesn't abort all remaining
58f2b5d Fixed for lacking column which is the modified field.
ea3235a SBDEV-1955: Add unit tests for finishStuckPickingOrder admin endpoint
eb4ed67 SBDEV-1955: Fix compilation error - replace Optional.isEmpty() with !isPresent()
74e22e8 SBDEV-1955: Add admin endpoint to finish stuck picking orders with OMS notification
112cd74 Fixed Using Move to Damaged Assigns Wrong Type to UL.
39e2f09 fix: update closeBOL unit tests for bulk-optimized implementation
bcd948d feat: optimize closeBOL() performance
006e24e feat: implement 5-phase concurrency fix plan for optimistic lock safety
9120b00 docs: add club order analysis and concurrency fix plan
d0bc247 chore: reorganize docs into analysis/ and plan/ subdirectories
d68371e feat: complete test improvement plan phases 12-21, add 1500+ unit tests
4cfcf67 feat: deepen 4 services + add 7 new service tests to reach 50.8% coverage
a1692a4 feat: add 84 unit tests for 6 services (Phase 11a)
57a2783 feat: add 119 unit tests for 6 services (Phase 10)
81f7234 feat: add 55 unit tests (Phase 9)
cb0b79d feat: add 49 unit tests (Phase 8)
f0f6984 feat: add 53 unit tests (Phase 7)
027f90f feat: add 65 unit tests (Phase 6)
415585e build: add JaCoCo code coverage plugin
91c0349 feat: add 98 unit tests (Phases 3-5)
cf17f5d feat: add 90 Mockito-based unit tests
4eb0e10 refactor: separate unit and integration tests
a6631f1 fix: repair test infrastructure
0fc58c7 fix: add transaction boundaries and HTTP timeouts to picking flow
a2756b8 docs: correct branch discrepancy table in RCA document
fd13cd2 feat: add replenishment order maintenance service (SBDEV-1742)
85f786f fix: add pessimistic locking to changeReservedAmount (SBDEV-1710)
cfc3ae2 fix: add transaction boundaries and fix silent failures on UL move paths
4f6a453 Fix / Enhance Filtering in Outbound Parcel Report
0e852c2 Sorted in asc by default to display CART containers first
2d8fa8c Added bulk edit of printer for users api
daadb87 Added and sorted completed col in desc by default
6389d4b Added item name under picking order number
f149843 restored back to original flyway.con content
ee249c4 removed old flyway config file
a52b78a SBDEV-1514: allow re-creation of cancelled transfer order
838bf70 cleaned up the code
27d842a feat: Refactor sumRequestedAmountForOpenOrders query
9f59d88 feat: Refactor sumRequestedAmountForOpenOrders query (type casting)
aba0821 feat: Update sumRequestedAmountForOpenOrders query (parameter casting)
7109798 feat: Enhance source usability check (reservations)
5979d8a Add Docker UAT Image CI workflow
cec88c0 feat: Add case-insensitive search for unit load by label
d72c4f6 feat: Integrate ReplenishmentOrderMaintenanceService
c64948a feat: Enhance replenishment order management
a29738a SBDEV-1746: Transfer to Damaged Breaks Flowbins
3e6016b Refine replenishment order updates plan
7300447 Add comprehensive replenishment order updates plan
1052f54 cleaned up the code
ccf861d update docker file to use Java 8 JRE
c4ac107 SBDEV-1710: Allocation More Then On Hand
05dea1b SBDEV-1526: Move Fixed Location Not Working
1d2651e SBDEV-1704: Add destinationLocationId handling
```
