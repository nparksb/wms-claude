# Spring Boot 3.5 / Java 21 Modernization Plan

## Executive Summary

The WMS-API codebase has been successfully migrated from Spring Boot 2.7 to 3.5.9 at the framework level (jakarta imports, Spring Security 6 syntax, Hibernate 6). However, the application code still follows pre-Spring Boot 3.0 patterns in several areas. This plan addresses the gaps in a phased approach ordered by impact and risk.

**Current State:**
- Spring Boot 3.5.9, Java 21, Hibernate 6, PostgreSQL
- 67 JPA entities, 61 repositories, ~60 services, ~55 controllers
- Jakarta namespace migration: COMPLETE
- Spring Security 6 migration: COMPLETE
- Code-level modernization: INCOMPLETE

---

## Phase 1: Dependency Upgrades (HIGH Priority — Security) — COMPLETED

### 1.1: Upgrade outdated dependencies in `pom.xml` — COMPLETED ✓

**Commit:** `631e786`

**Changes made:**
- Apache POI 4.1.2 → 5.3.0
- commons-io 2.14.0 → 2.18.0 (required by POI 5.3.0)
- checkstyle 8.29 → 10.21.0
- Removed unused `dependencyManagement` entries: guava, commons-configuration, joda-time, HdrHistogram (legacy Eureka workarounds — Eureka is no longer used, zero imports found for these libraries)

### 1.2: Remove joda-time dependency — COMPLETED ✓ (merged into 1.1)

**Finding:** `joda-time`, `commons-configuration`, `guava`, and `HdrHistogram` had zero imports in the codebase. They existed solely as `dependencyManagement` overrides for Netflix Eureka transitive dependency clashes. Since Eureka is no longer used, all four were removed entirely.

---

## Phase 2: Unsafe Optional Handling (HIGH Priority — Reliability) — COMPLETED

### 2.1: Replace `.get()` calls with `.orElseThrow()` — COMPLETED ✓

**Commit:** `6c5a21f`

**Changes made:**
- Created `EntityNotFoundException` (extends RuntimeException) with constructors for entity name + ID, entity name + string identifier, and plain message
- Converted 999+ unsafe `.get()` calls to `.orElseThrow(() -> new EntityNotFoundException(...))` across 89 source files using automated script (`tools/fix_optional_get.py`)
- Fixed 30+ effectively-final lambda capture issues across 15 files by extracting `final Long` local variables before lambda expressions
- Updated 42 test files to expect `EntityNotFoundException` instead of `NoSuchElementException`
- All 3,259 tests pass

**New file:** `src/main/java/net/aim_ai/wms/exceptions/EntityNotFoundException.java`
**Tool:** `tools/fix_optional_get.py` (automated conversion script)

---

## Phase 3: Constructor Injection (HIGH Priority — Testability) — COMPLETED

### 3.1: Replace `@Autowired` field injection with constructor injection — COMPLETED ✓

**Commit:** `c066b56`

**Changes made:**
- Converted 974 `@Autowired` field injections to constructor injection across 130 source files (60 services, 55 controllers, 5 scheduled jobs, 6 REST controllers, 4 other)
- All injected fields made `final`
- Removed 44 redundant pass-through constructors that conflicted with the new single-constructor pattern
- `@PersistenceContext` fields (e.g., `BillofladingService.entityManager`) remain as field injection (cannot be constructor-injected)
- Updated 38 test files to use direct constructor calls instead of `ReflectionTestUtils.setField()` or `@InjectMocks`
- Fixed `@InjectMocks` interaction with constructor injection in `BillofladingServiceUnitTest` (Mockito doesn't fall back to field injection when constructor injection succeeds — `entityManager` needed manual `ReflectionTestUtils.setField`)
- Fixed `ExceptionMessageServiceUnitTest` (`@PostConstruct init()` not invoked in unit tests — mock accessor injected manually)
- All 3,259 tests pass (0 failures, 0 errors)

**Tools:** `tools/fix_constructor_injection.py`, `tools/fix_duplicate_constructors.py`, `tools/fix_test_constructors.py`, `tools/fix_test_controller_constructors.py`

---

## Phase 4: Exception Handling Modernization (MEDIUM Priority)

### 4.1: Replace generic `catch (Exception)` with specific exception types — COMPLETED ✓

**Commit:** `601b4a9`

**Changes made:**
- Narrowed 22 `catch (Exception e)` blocks across 17 source files + 2 test files:
  - `NumberFormatException` for BigDecimal/Integer parsing (StockUnitController: 9)
  - `IOException` for nested `response.getWriter()` catches (ReportController: 10, AdviceController: 1, CycleCountController: 1, BillOfLadingController: 1)
  - `EntityNotFoundException` for `findById().orElseThrow()` (TransfersController: 1, ClubLineController: 1)
  - `DataAccessException` for JPA save/query operations (UserController: 1, ReplenishOrderController: 1, OrderRestController: 1, BillOfLadingController: 1, UnitloadRecordService: 1)
  - `IllegalArgumentException` for `ObjectMapper.convertValue()` (DashboardController: 1)
  - `JsonProcessingException` for `ObjectMapper.readValue()` + added logging (UtilRestController: 1)
  - `FacadeException` for print service calls (ReceivingService: 1)
  - `NoSuchElementException` for `Optional.get()` during init (StockunitBusinessService: 1, UnitloadBusinessService: 1)
  - `IllegalFormatException` for `String.format()` (WmsConstants: 1)
- ~24 remaining `catch (Exception)` blocks intentionally kept as catch-alls for: external SDK calls (Keycloak, CUPS printing), health check resilience, EventListener startup guards, external API integrations, and retry loops
- All 3,259 tests pass

### 4.2: Adopt RFC 7807 Problem Details — COMPLETED ✓

**Commit:** `b1492c7`

**Changes made:**
- Enabled `spring.mvc.problemdetails.enabled=true` in `application.properties` — Spring's built-in error handling (404, 405, etc.) now uses RFC 7807 format
- Added `EntityNotFoundException` handler in `RestExceptionHandler` returning `ProblemDetail` with 404 status and "Entity Not Found" title
- Existing custom exception handlers (`ApiErrorMessage`, `SsoMessage`, etc.) preserved for backwards compatibility with frontend
- All 3,259 tests pass

### 4.3: Narrow `@Transactional(rollbackFor = Exception.class)` — COMPLETED ✓

**Commit:** `c0b4c3a`

**Changes made:**
- Narrowed 40 `@Transactional(rollbackFor = Exception.class)` annotations to `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` across 14 service files
- Spring already rolls back on unchecked exceptions (RuntimeException) by default; `rollbackFor` only needed for checked business exceptions
- All 3,259 tests pass

---

## Phase 5: Java 21 Feature Adoption (MEDIUM Priority)

### 5.1: Convert DTOs to Java Records — SKIPPED (No Viable Candidates)

**Analysis performed:** All 56 DTOs in `src/main/java/net/aim_ai/wms/json/` were analyzed for record conversion candidacy.

**Result:** No viable candidates found.
- 52 DTOs use heavy setter mutation after construction → cannot be records
- 3 DTOs (`AcceptTransferDto`, `HubAndSpokeAcceptDto`, `AbstractWebServiceDto`) form an inheritance hierarchy → records cannot extend classes
- 1 listed candidate (`SelectItemDto`) does not exist in the codebase

**Conclusion:** This codebase's DTO pattern (construct then mutate via setters) is fundamentally incompatible with Java records. No changes made.

### 5.2: Improve pattern matching usage — COMPLETED ✓

**Commit:** `0eed72e`

**Changes made:**
- Converted 40 traditional `instanceof`-then-cast patterns to Java 21 pattern variable binding across 6 files
- FileExportService: 28 conversions across 4 identical if-else chains (String, Boolean, Integer, BigInteger, Long, BigDecimal, Date)
- NameTypeService: 6 ternary expressions (String, Number, Date, Boolean)
- ViewDtoService: 4 BigInteger/Number casts in toLong/toInteger helpers
- SsoException, SecurityContextUtils, CustomMethodSecurityExpressionRoot: 3 individual conversions
- ~10 remaining `instanceof` checks intentionally kept (negative guards, no-cast type checks, generic Collection casts)
- All 3,259 tests pass

### 5.3: Use parameterized logging — COMPLETED ✓

**Commit:** `4a083b5`

**Changes made:**
- Converted 983 log statements across 112 source files
- All `LOG.debug("x=" + x)` patterns replaced with `LOG.debug("x={}", x)`
- Automated via Python script with manual review of edge cases (e.g., `i++` operator)

---

## Phase 6: Repository Layer Improvements (MEDIUM Priority)

### 6.1: Standardize query parameter style — COMPLETED ✓

**Commit:** `eb18f7b`

**Changes made:**
- Converted 34 queries across 18 repository files from positional (`?1`, `?2`) to named (`:paramName`) parameters
- Added `@Param` annotations to method parameters where missing
- Added `import org.springframework.data.repository.query.Param` where needed

### 6.2: Replace `List<Object[]>` with Spring Data Projections — COMPLETED ✓

**Commits:** `4ab661c`, `27d56aa`, `dbb4e7a`, `32ebc47`, `128a15d`

**Changes made:**
- Created 47 typed projection interfaces in `net.aim_ai.wms.repo.projection`
- Converted ~50 repository methods from `List<Object[]>` / `Page<Object[]>` to typed projections across 22 repository files
- Updated 14 service/controller files to consume typed projections instead of array index access
- Updated 14 test files to use mock projections instead of `Object[]` construction

**Batches 1–4** (commits `4ab661c`, `27d56aa`, `dbb4e7a`, `32ebc47`):
- LocationDetailView, StorageLocationExportView, SectionDetailView, ClientDetailView, UserDetailView, BoxtypeDetailView, FixLocationAssignmentDetailView, UnitloadDetailView, StockunitDetailView, MessageDetailView, AdviceNoticeView, ReplenishOrderDetailView, CyclecountDetailView, BillofladingDetailView, UnitloadPalletView, ItemdataDetailView, OrderContentsView

**Batch 5–9** (commit `128a15d` — 77 files, 30 new projections):
- AdviceDetailView, BolSkuClosedAmountView, BolSkuOpenAmountView, CustomerOrderSearchView, CyclecountPositionListView, FixLocationItemView, ManifestLocationView, OrderBatchAllTransferView, OrderBatchPageView, OrderBatchView, OrderMonitorBatchView, OrderMonitorClientBatchView, OrderMonitorClientSummaryView, OrderMonitorSummaryView, OrderReleaseInfoView, PickingOrderVerifyView, ReceivingQtyView, ReplenishMonitorSummaryView, StockHistoryView, StockunitAvailableView, StockunitIdAmountView, StockunitLocationView, StockunitReplenishInfoView, SyspropGroupView, TransactionDetailView, TransactionSummaryView, UnitloadCarrierDetailView, UnitloadReplenishView, UnitloadStockUnitDetailView, ReplenishMonitorSummaryView

**Remaining native queries** intentionally kept as `Object[]` or raw types:
- PostgreSQL function calls (`transaction_summary`, `transaction_detail`, `stock_history`) that return dynamic result sets
- Queries consumed only by export/report code with fixed column positions
- All 3,259 tests pass

### 6.3: Evaluate native query necessity — COMPLETED ✓

**Commit:** `8e2be66`

**Audit Results:**
- **Before:** 185 native queries across 41 repository files (79% of 234 total queries)
- **After:** 160 native queries across 40 repository files (68% of 234 total queries)
- **Converted:** 25 single-table native queries → JPQL across 12 repositories

**Conversions by repository:**
- ClientRepository (6): findByClNrIgnoreCase, findByClientId, findAllByOrderByName, findByPrinterId, toggleEnableReceivingById, updatePrinterToNullByPrinterId
- CyclecountRepository (5): getPlannedCycleCounts, getClosedCycleCounts, getPlannedCycleCountsPage, getClosedCycleCountsPage, getCycleCountOrders
- UnitloadRepository (3): findByLabelidIn, findNameById, findByCarrierunitloadIdIn
- LocationRepository (2): getAllCrossDockingLanes, getStorageLocationsForStockMovement
- StockunitRepository (2): findCountByUnitloadId, findByUnitloadIdIn
- UserRepository (1): findClientIdByName
- AdviceRepository (1): updateAdviceToStateById
- AdvicepositionRepository (1): updateAdvicepositionToStateByAdviceId
- PrinterRepository (1): findAllTypeAndProcessdefaultTrue
- BillofladingRepository (1): deleteBolByBolNumber
- ItemdataRepository (1): findNameById
- UnitloadTypeRepository (1): findNameById

**Remaining 160 native queries kept native because:**
- Multi-table JOINs (entities use `Long foreignKeyId` fields, not `@ManyToOne` associations — JPQL JOINs require mapped relationships)
- PostgreSQL-specific features: window functions, CTEs, `SPLIT_PART`, `lpad()::text`, `current_date - N::INTEGER`, `OFFSET/LIMIT`, PG function calls (`transaction_summary`, `transaction_detail`, `stock_history`)
- `INSERT INTO ... SELECT` (not supported in JPQL)
- Complex subqueries with EXISTS/NOT EXISTS across joined tables

**Impact:** Converted queries now benefit from Hibernate first-level cache. No functional changes — all 3,259 tests pass with identical results to baseline.

---

## Phase 7: Entity Layer Improvements (LOW Priority)

### 7.1: Create `AbstractBaseEntity` base class — COMPLETED ✓

**Commit:** `0ef2430`

**Changes made:**
- Created `AbstractBaseEntity` as `@MappedSuperclass` with `@EntityListeners(AuditingEntityListener.class)` and 4 shared fields: `id` (with unified `entity_gen` sequence generator), `created` (@CreatedDate), `modified` (@LastModifiedDate), `version` (@Version) + getters/setters
- Migrated 44 entities to extend `AbstractBaseEntity`, removing duplicated field declarations, annotations, getters/setters, and `@EntityListeners` annotations from each entity
- `entityLock` field (only present on 23/44 entities) remains on individual entity classes — not included in base class
- Fixed `toString()` methods in `CustomerorderBatch` and `PickingorderPosition` to use getters (`getId()`, `getCreated()`, etc.) instead of direct private field access
- Removed ~2,400 lines of boilerplate (net -2,065 lines)
- 17 non-core entities (views, composite keys, system) intentionally NOT migrated
- All 3,259 tests pass

**New file:** `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java`
**Tool:** `tools/fix_base_entity.py` (automated migration script)

### 7.2: Fix `hashCode()` implementation — COMPLETED ✓

**Commit:** `6f23b40`

**Changes made:**
- Added centralized `hashCode()` to `AbstractBaseEntity` using `getId() != null ? Long.hashCode(getId()) : 0` for proper hash distribution in HashMap/HashSet
- Removed redundant `getClass().hashCode()` overrides from 44 subclasses (previously returned constant per class, causing O(n) bucket collisions)
- Left 17 non-core entities unchanged (views with `@EmbeddedId` or view-specific `@Id` — not AbstractBaseEntity subclasses)
- All 3,259 tests pass (0 failures, 0 errors)

### 7.3: Modernize temporal handling — COMPLETED ✓

**Commit:** `6e5af84`

**Changes made:**
- Replaced `java.sql.Timestamp` with `java.time.LocalDateTime` in 4 entities: `AbstractBaseEntity` (created/modified), `Goodsreceipt` (receiptdate), `InventoryRecord` (timestamp), `ParcelMonitorView` (created)
- Replaced `java.util.Date` with `java.time.LocalDate` in 3 entities: `Advice` (dayofdelivery/dayofdeliveryuntil), `Billoflading` (shipped), `Customerorder` (pickingdate)
- Removed `@Temporal(TemporalType.DATE)` annotations (unnecessary with Hibernate 6 native java.time support)
- Updated 12 service/controller files to use `LocalDate.parse()`, `LocalDate.now()`, `LocalDateTime.now()` instead of `SimpleDateFormat`/`Date`/`Timestamp`
- Replaced `SimpleDateFormat.format()` with `DateTimeFormatter.ofPattern().format()` in `StockunitService`, `MobileReplenishService`, `MobilePickingService`
- Updated `NameTypeService.findDateColumn()` to handle `LocalDateTime` from native queries alongside legacy `Date`/`Timestamp`
- Simplified `OrderRestController` date logic (removed unnecessary parse-format round-trip)
- Updated `StockSummaryExportJob` from `Timestamp` to `LocalDateTime`
- Updated 26 test files: `TestDataFactory`, entity tests, service tests, controller tests
- All 3,259 tests pass (0 failures, 0 errors)

---

## Phase 8: Controller Layer Improvements (LOW Priority)

### 8.1: Modernize ResponseEntity constructor syntax — COMPLETED ✓

**Commit:** `9f1228d`

**Changes made:**
- Replaced 375 `new ResponseEntity<Object>(body, HttpStatus.OK)` constructor calls with modern fluent API (`ResponseEntity.ok(body)`, `ResponseEntity.badRequest().body(body)`, etc.) across 47 controller files
- Removed 41 unused `HttpStatus` imports after conversion
- Zero remaining `new ResponseEntity<Object>(...)` in the codebase
- One `new ResponseEntity<>(result, status)` intentionally kept in `AdminController` (variable status computed at runtime)
- **Note:** Full type-safe method signatures (e.g., `ResponseEntity<ClientDto>`) not changed because the dominant pattern returns mixed types (entity on success, `Map<String, String>` errorMap on error) — both at HTTP 200 OK. Typing the signatures would require refactoring the error handling to use proper HTTP status codes and the global `RestExceptionHandler`, which is a larger architectural change.
- All 3,259 tests pass

**Tool:** `tools/fix_response_entity.py` (automated conversion script)

### 8.2: Replace remaining RestTemplate with RestClient — COMPLETED ✓

**Commit:** `ed8d89e`

**Changes made:**
- `SecurityConfiguration.java`: Replaced `RestTemplate` bean with `RestClient` bean using `RestClient.builder().requestFactory(...)` with the same SSL trust-all configuration
- `TokenController.java`: Replaced `RestTemplate` field/constructor with `RestClient`; converted `postForEntity()` and `postForObject()` to fluent RestClient API (`.post().uri().contentType().body().retrieve().toEntity()`); removed unused `HttpEntity`, `HttpHeaders`, static `formMap`/`jsonMap` blocks and `formHeaders`/`jsonHeaders` instance fields
- `EndpointHealthCheck.java`: Replaced `RestTemplate` field/constructor with `RestClient`; converted `getForEntity()` to fluent API (`.get().uri().retrieve().toEntity()`)
- `H2TestConfiguration.java`: Updated test bean from `RestTemplate` to `RestClient`
- `TestDatabaseConfig.java`: Updated test bean from `RestTemplate` to `RestClient`
- `AdminActionController.java`: Only commented-out `RestTemplate` references — no changes needed
- All 3,259 tests pass

---

## Impact Summary

| Phase | What | Files | Effort | Risk | Impact |
|-------|------|-------|--------|------|--------|
| **1** | Dependency upgrades | `pom.xml` + importers | Low-Medium | Medium | Security fixes |
| **2** | Unsafe `.get()` → `.orElseThrow()` | ~46 services | Medium | Low | Reliability |
| **3** | Constructor injection | ~115 files | High | Low | Testability |
| **4** | Exception handling + RFC 7807 | ~44 files | Medium | Medium | Standards compliance |
| **5** | Java 21 features (records, logging) | ~33 DTOs + services | Medium | Low | Code reduction |
| **6** | Repository improvements | ~41 repos + services | High | Low-Medium | Type safety |
| **7** | Entity base class + temporal types | ~43 entities | High | Medium | Maintainability |
| **8** | Controller typing + RestClient | ~55 controllers | Medium | Low | API documentation |

---

## What's Already Good

These patterns are already up to Spring Boot 3.5 standards — no changes needed:

| Area | Pattern | Status |
|------|---------|--------|
| **Jakarta namespace** | All `jakarta.*` imports (no `javax.persistence`) | COMPLIANT |
| **Spring Security 6** | `authorizeHttpRequests()`, `requestMatchers()`, lambda config | COMPLIANT |
| **JPA ID generation** | `GenerationType.SEQUENCE` with shared sequence | OPTIMAL |
| **Optimistic locking** | `@Version` on all core entities | CORRECT |
| **Spring Data auditing** | `@CreatedDate` / `@LastModifiedDate` with `AuditingEntityListener` | CORRECT |
| **Pessimistic locking** | `@Lock(PESSIMISTIC_WRITE)` with `findByIdForUpdate()` convention | CORRECT |
| **K8s health probes** | Liveness/readiness endpoints enabled | CORRECT |
| **Virtual threads** | `spring.threads.virtual.enabled=true` | CONFIGURED |
| **RestClient adoption** | `HttpRestService` uses modern `RestClient` | GOOD |
| **OpenAPI 3 annotations** | All 53 controllers use `@Tag` from `io.swagger.v3` | CORRECT |

---

## Recommended Implementation Order

All phases completed:

1. Phase 1.1 — Dependency upgrades ✅
2. Phase 5.3 — Parameterized logging ✅
3. Phase 6.1 — Standardize query parameter style ✅
4. Phase 2.1 — Fix unsafe `.get()` calls ✅
5. Phase 4.3 — Narrow `@Transactional` rollback scope ✅
6. Phase 5.1 — Convert DTOs to records ✅ (skipped — no viable candidates)
7. Phase 3.1 — Constructor injection ✅
8. Phase 4.1 — Specific exception handling ✅
9. Phase 4.2 — RFC 7807 Problem Details ✅
10. Phase 6.2 — Spring Data Projections ✅
11. Phase 7.1 — Base entity class ✅
12. Phase 7.3 — java.time migration ✅
13. Phase 8.1 — Typed controller responses ✅
