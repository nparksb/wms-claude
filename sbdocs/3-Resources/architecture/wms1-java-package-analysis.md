---
title: WMS v1 Java Package Analysis
tags: [architecture, wms1, java, packages]
created: 2026-04-26
last_verified: 2026-05-01
---

# WMS v1 Java Package Analysis

*Generated: 2026-04-26 | Source: `v1/wms-api/src/main/java/net/aim_ai/wms/`*

## Overview

| Metric | Value |
|--------|-------|
| Total Java files | **359** |
| Top-level packages | 8 (+ root config classes) |
| Root config classes | 17 |
| Java version | 8 |
| Framework | Spring Boot 2.3.7 |

---

## Package Tree with Class Counts

```
net.aim_ai.wms/                        17  (root config/security)
├── controller/                        37  (web-tier entry points)
│   ├── rest/                           7  (REST API for external integration)
│   └── mobile/                        10  (handheld device workflows)
├── service/                           59  (core business logic)
│   ├── mobile/                        10  (mobile-specific operations)
│   ├── job/                            3  (scheduled job logic)
│   └── util/                           2  (service-layer utilities)
├── repo/                               0  (package-only; no root-level files)
│   ├── jpa/                           61  (Spring Data JPA repository interfaces)
│   └── cinterface/                     2  (custom repository base interfaces)
├── model/                             67  (JPA entities + view entities)
├── json/                              33  (API DTOs — web + REST)
│   └── mobile/                        23  (DTOs for mobile endpoints)
├── exceptions/                        17  (exception hierarchy + global handler)
├── schedulejob/                        6  (Quartz/Spring @Scheduled job classes)
└── util/                               5  (general utilities)
```

**Total by top-level group:**

| Package | Files | % of total |
|---------|------:|----------:|
| `model` | 67 | 18.7% |
| `service` (all sub-pkgs) | 74 | 20.6% |
| `repo` (all sub-pkgs) | 63 | 17.5% |
| `controller` (all sub-pkgs) | 54 | 15.0% |
| `json` (all sub-pkgs) | 56 | 15.6% |
| `exceptions` | 17 | 4.7% |
| `schedulejob` | 6 | 1.7% |
| `util` | 5 | 1.4% |
| root (config/security) | 17 | 4.7% |

---

## Per-Package Responsibility

### `net.aim_ai.wms` (root — 17 classes)

Security configuration and application bootstrap. Nothing domain-related lives here.

| Class | Role |
|-------|------|
| `StartApplication` | `@SpringBootApplication` entry point |
| `SecurityConfiguration` / `SecurityConfigurer` / `MethodSecurityConfig` | Spring Security OAuth2 + Keycloak wiring |
| `CustomMethodSecurityExpressionHandler` / `CustomMethodSecurityExpressionRoot` | Custom SpEL security expressions |
| `CustomPermissionEvaluator` | ACL permission evaluation |
| `JwtAccessTokenCustomizer` | Adds WMS claims to JWT |
| `SecurityContextUtils` | Extracts tenant/user from `SecurityContext` |
| `SecurityProperties` | External security config properties |
| `UserMap` / `Authority` | Auth helper types |
| `WebConfig` / `WebConfigurer` | CORS, serialisation, MVC config |
| `MyRepositoryRestConfigurer` | Spring Data REST customisation |
| `RepositoryLinksResourceProcessor` | Suppress auto-generated HAL links |
| `EndpointHealthCheck` | Actuator health indicator |

**Rule:** New infrastructure/security cross-cuts go here. No business logic.

---

### `model` (67 classes)

JPA entity layer. All persistence objects live here; no sub-packages.

**Entity categories:**

| Category | Examples |
|----------|---------|
| Order entities | `Customerorder`, `CustomerorderPosition`, `CustomerorderBatch`, `Pickingorder`, `PickingorderPosition`, `PickingorderUnitload` |
| Inventory | `Stockunit`, `Stockrecord`, `Unitload`, `UnitloadRecord`, `UnitloadType` |
| Location | `Location`, `LocationArea`, `LocationConstraint`, `LocationRack`, `LocationRackRow`, `LocationType`, `Section` |
| Receiving | `Goodsreceipt`, `Goodsreceiptposition`, `Advice`, `Adviceposition` |
| Shipping | `Billoflading`, `BillofladingPosition`, `Shippingmethod`, `ShippingmethodShipperid`, `Shipperid` |
| Replenishment | `Replenishorder` |
| Transfer | (via `Pickingorder` + `PickingorderPosition`) |
| Cycle count | `Cyclecount`, `CyclecountPosition` |
| User/security | `MywmsUser`, `MywmsRole`, `MywmsFunction`, `MywmsGroup` + junction tables |
| Config | `Itemdata`, `Itemunit`, `Boxtype`, `Client`, `Printer`, `Queryrepository`, `LosSequencenumber`, `LosSysprop`, `FixLocationAssignment` |
| Messaging | `Message`, `MessageArchived` |
| View/reporting | `CyclecountDtoView`, `FlowbinMonitorView`, `LockOverviewDtoView`, `OrderDetailMonitorView`, `OrderMonitorView`, `ParcelMonitorView`, `ReceivedDtoView`, `ReceivingDtoView`, `ReplenishmentMonitorView`, `StockView`, `ViewWarehouseLocationReport` |
| Misc | `UserRepresentationWithTempPw` (Keycloak DTO shape) |

**Rule:** Pure JPA entities only — no service logic, no DTO mapping. New entities go here. No sub-packages needed unless entity count exceeds ~100.

---

### `repo` (63 classes across 2 sub-packages)

Data access layer. All database queries originate here.

#### `repo/jpa` (61 interfaces)

Spring Data JPA `JpaRepository` / `PagingAndSortingRepository` extensions, one per entity. Naming follows the entity exactly: `CustomerorderRepository`, `PickingorderRepository`, etc.

Notable interfaces:
- `StockViewRepository`, `CyclecountDtoViewRepository`, `OrderMonitorViewRepository`, `FlowbinMonitorViewRepository` — read-only views (reporting queries)
- `MywmsUserRepository`, `MywmsRoleRepository`, `MywmsFunctionRepository` — security/user management

#### `repo/cinterface` (2 interfaces)

Base interface contracts that override Spring Data defaults:

| Interface | Purpose |
|-----------|---------|
| `NoDeletePagingAndSortingRepository` | Disables `deleteById`/`delete` — prevents hard deletes on protected entities |
| `ReadOnlyPagingAndSortingRepository` | Disables all write methods — used for view/reporting repositories |

**Rule:** All new database access goes in `repo/jpa/`. If an entity should never be hard-deleted, extend `NoDeletePagingAndSortingRepository`. If it maps a DB view, extend `ReadOnlyPagingAndSortingRepository`.

---

### `service` (74 classes across 4 sub-packages)

Business logic layer. This is the largest package and the primary coding target for most features.

#### `service/` root (59 classes)

Core orchestration services. Each major entity has a corresponding `*Service`:

| Service | Domain |
|---------|--------|
| `CustomerorderService` / `CustomerorderBatchService` / `CustomerorderPositionService` | Customer order lifecycle |
| `PickingorderService` / `PickingorderPositionService` / `PickingorderUnitloadService` / `PickingorderBusinessService` | Picking order management |
| `BillofladingService` / `BillofladingPositionService` | Shipping / BOL |
| `ReceivingService` / `GoodsReceiptPositionService` | Goods receipt |
| `StockunitService` / `StockunitBusinessService` / `StockrecordService` | Stock management |
| `UnitloadService` / `UnitloadBusinessService` / `UnitloadRecordService` | Unit load operations |
| `ReplenishorderService` / `ReplenishGeneratorService` / `ReplenishmentOrderMaintenanceService` | Replenishment |
| `CyclecountService` / `CyclecountPositionService` | Cycle counting |
| `TransferOrderService` | Internal transfers |
| `LocationService` / `LocationAreaService` / `LocationConstraintService` / `LocationTypeService` | Location management |
| `ItemdataService` / `ItemunitService` / `BoxtypeService` | Item/SKU master |
| `ClientService` / `SectionService` / `ShipperidService` | Configuration |
| `MywmsUserService` / `MywmsRoleService` / `MywmsGroupService` / `MywmsFunctionService` | User/auth management |
| `KeycloakService` | SSO/Keycloak integration |
| `AccessService` | Permission checks |
| `MessageService` / `ExceptionMessageService` | Messaging |
| `PrintService` | Label printing |
| `ReportService` / `WarehouseStockReportService` / `FileExportService` | Reporting/export |
| `ViewDtoService` | DTO projection assembly (1380 lines — largest class) |
| `OrderMonitorViewService` / `ParcelMonitorViewService` | Monitor view queries |
| `ManageOrderService` / `SequenceTransactionService` / `InventoryRecordService` | Cross-cutting ops |
| `HttpRestService` | Outbound HTTP calls (OMS integration) |
| `LosSyspropService` / `NameTypeService` | System property lookup |
| `BasicService` | Shared base service helpers |
| `WmsConstants` | System-wide constant definitions (1290 lines) |

#### `service/mobile` (10 classes)

Stateful mobile-workflow services. Each maps to a handheld scanner operation:

| Service | Operation |
|---------|-----------|
| `MobilePickingService` | Picking workflow (1032 lines) |
| `MobileReplenishService` | Replenishment workflow (994 lines) |
| `MobileCycleCountService` | Cycle count workflow (482 lines) |
| `MobilePutAwayService` | Put-away workflow |
| `MobileMoveStockService` | Stock move |
| `MobileMoveUnitloadService` | Unit load move |
| `MobilePalletizingService` | Palletising |
| `MobileTransferOrderService` | Transfer order execution |
| `MobileTruckLoadingService` | Truck loading |
| `MobileInfoService` | Lookup/info queries for mobile screens |

#### `service/job` (3 classes)

Background job business logic, invoked by `schedulejob/` entries:

| Service | Purpose |
|---------|---------|
| `ReleaseOrderJobService` | Release picking orders to warehouse floor (565 lines) |
| `ReplenishOrderJobService` | Trigger replenishment order generation |
| `CleanUpOldMessageJobService` | Archive/delete old messages |

#### `service/util` (2 classes)

| Class | Purpose |
|-------|---------|
| `OmsNotificationHelper` | Sends outbound notifications to OMS |
| `OptimisticLockRetryTemplate` | Retry wrapper for `ObjectOptimisticLockingFailureException` |

**Rule:** New features almost always start here. Entity-coupled logic → `service/` root. Mobile scanner step → `service/mobile/`. Scheduled background task logic → `service/job/`. Shared retry/notification helpers → `service/util/`.

---

### `controller` (54 classes across 3 sub-packages)

Web tier. Receives HTTP requests, delegates to services, returns responses.

#### `controller/` root (37 classes)

Spring MVC `@Controller` classes for the internal web UI. One controller per domain area:

`AdminActionController`, `AdminController`, `AdviceController`, `BillOfLadingController`, `BoxTypeController`, `ClientController`, `ClubLineController`, `CustomerOrderBatchController`, `CustomerOrderController`, `CustomerOrderPositionController`, `CycleCountController`, `DashboardController`, `FileImportController`, `FixLocationAssignmentController`, `GoodsReceiptPositionController`, `GroupController`, `ItemDataController`, `LocationController`, `MessageController`, `MessageDummyController`, `PickingOrderPositionController`, `PrinterController`, `ReceivingController`, `ReplenishOrderController`, `ReportController`, `RoleController`, `SectionController`, `ShipperIdController`, `StockRecordController`, `StockUnitController`, `SystemController`, `SystemPropertyController`, `TokenController`, `TransfersController`, `UnitLoadController`, `UnitloadRecordController`, `UserController`

#### `controller/rest` (7 classes)

`@RestController` classes for external REST API integration:

| Controller | Domain |
|-----------|--------|
| `AbstractRestController` | Base class (auth, pagination helpers) |
| `AdviceRestController` | Advice/purchase order REST API (637 lines) |
| `OrderRestController` | Customer order REST API (952 lines) |
| `SkuRestController` | Item/SKU REST API |
| `StockCountRestController` | Cycle count REST API |
| `TransactionReportRestController` | Transaction report REST API |
| `UtilRestController` | Utility/lookup REST API (1035 lines) |

#### `controller/mobile` (10 classes)

`@RestController` classes serving the mobile UI (handheld scanners):

`CycleCountLosController`, `LookupController`, `MoveStockController`, `MoveUnitloadController`, `PalletizingController`, `PickingController`, `PutawayController`, `ReplenishController`, `TransferOrderController`, `TruckLoadingController`

**Rule:** Web UI page backing → `controller/` root. OMS or external system integration endpoint → `controller/rest/`. New mobile scanner screen → `controller/mobile/`. All new controllers delegate immediately to a service — no business logic in controllers.

---

### `json` (56 classes across 2 sub-packages)

Data Transfer Objects. No business logic — pure data shapes for serialisation.

#### `json/` root (33 classes)

DTOs for web controllers and REST API:

`AbstractWebServiceDto`, `AcceptTransferDto`, `ActiveOrderBatchViewDto`, `AdviceDto`, `AdvicePositionDto`, `AdviceUploadDto`, `BillOfLadingWebServiceDto`, `ClientUploadDto`, `ClubLineActiveBatchViewDto`, `ClubLineSkuDto`, `ClubLineUnitLoadDto`, `CycleCountItemDataViewDto`, `CycleCountLocationViewDto`, `CycleCountPositionViewDto`, `FacilitiesDto`, `FacilityDto`, `HubAndSpokeAcceptDto`, `LocationUploadDto`, `OrderBatchDto`, `OrderDetailViewDto`, `OrderDto`, `OrderPositionDto`, `PalletDto`, `ParcelMonitorDto`, `SkuDto`, `SkuUploadDto`, `StockChangeDto`, `StockCountDto`, `UnitloadLocationDto`, `WarehouseTransactionDetailedReportRequest`, `WarehouseTransactionDetailedReportResponse`, `WarehouseTransactionReportRequest`, `WarehouseTransactionReportResponse`

#### `json/mobile` (23 classes)

DTOs exclusively for mobile controller endpoints:

`CycleCountInfoDto`, `ItemInfoDto`, `LocationInfoDto`, `MultiReplenishRequestDto`, `MultiReplenishResponseDto`, `MultiReplenishUnitLoadDto`, `OrderInfoDto`, `PalletisingMobileDto`, `PickingHighPositionInfoDto`, `PickingInfoDto`, `PutAwayItemDto`, `PutAwayMobileDto`, `ReplenishMobileOrderDto`, `SelectItemDto`, `StockTransferDto`, `StockUnitInfoDto`, `StockUnitMobileInfoDto`, `TransferInfoDto`, `TransferOrderDto`, `TransferOrderPositionDto`, `TransferOrderPositionPickSourceDto`, `TruckLoadingMobileDto`, `UnitLoadInfoDto`

**Rule:** DTOs for web/REST → `json/`. DTOs used only by mobile controllers/services → `json/mobile/`. DTOs never reference `model` entities directly — map in the service or controller layer.

---

### `exceptions` (17 classes)

Exception hierarchy and global handler.

| Class | Role |
|-------|------|
| `RestExceptionHandler` | `@ControllerAdvice` — maps exceptions to HTTP responses |
| `ApiException` / `ApiExceptionInterface` | Base API exception |
| `ApiConstraintViolationException` | Validation failures |
| `ApiInvalidParameterException` | Bad request parameters |
| `ApiMissingUserException` | Authentication required |
| `BusinessException` | Domain rule violations |
| `FacadeException` | Service facade errors |
| `WebserviceBusinessExceptionClientSide` / `WebserviceBusinessExceptionServerSide` | Inbound WS error mapping |
| `ApiErrorMessage` / `ApiParameterErrorMessage` | Error response shapes |
| `SsoException` / `SsoCreateUserException` / `SsoGroupMembershipException` | Keycloak SSO errors |
| `SsoMessage` / `SsoGroupMembershipMessage` | SSO response shapes |

**Rule:** New business rule violations → `BusinessException`. New API input errors → `ApiInvalidParameterException`. New SSO/auth errors → extend `SsoException`. Never add new exception types for conditions already covered by an existing type.

---

### `schedulejob` (6 classes)

Quartz/Spring `@Scheduled` trigger classes. These are thin wrappers — actual logic lives in `service/job/`.

| Class | Schedule / purpose |
|-------|--------------------|
| `SchedulingConfiguration` | `@EnableScheduling` + cron configuration |
| `OrderReleaseJob` | Periodically releases orders to the floor |
| `ReplenishOrderJob` | Triggers replenishment generation (499 lines — config-heavy) |
| `ReleaseExpiredPickingOrdersFromUserJob` | Frees stale user-locked picking orders |
| `CleanUpOldMessagesJob` | Deletes archived messages past retention window |
| `StockSummaryExportJob` | Exports stock summary to file |

**Rule:** New scheduled tasks get a thin `*Job` class here (just the `@Scheduled` method + delegation) and a `*JobService` in `service/job/` for the logic.

---

### `util` (5 classes)

General-purpose helpers with no Spring context dependency.

| Class | Purpose |
|-------|---------|
| `CycleCountStrategy` | Strategy interface for cycle count algorithms |
| `DefaultStrategy` | Default implementation of `CycleCountStrategy` |
| `Pair` | Generic two-element tuple |
| `StringConverter` | String parsing/conversion utilities |
| `WebserviceError` | Enum of external webservice error codes |

**Rule:** Pure Java utility logic with no Spring injection → `util/`. Spring-aware utilities → `service/util/`.

---

## Key Classes by Size (Top 20)

| Rank | Lines | Class | Package | Notes |
|------|------:|-------|---------|-------|
| 1 | 1380 | `ViewDtoService` | `service/` | DTO projection assembly for all view types |
| 2 | 1290 | `WmsConstants` | `service/` | System-wide constants; not actually a service |
| 3 | 1247 | `CustomerorderBatchService` | `service/` | Club-line batch order processing |
| 4 | 1210 | `BillofladingService` | `service/` | BOL lifecycle including close/manifest |
| 5 | 1122 | `KeycloakService` | `service/` | Full SSO lifecycle (create user, roles, groups) |
| 6 | 1035 | `UtilRestController` | `controller/rest/` | Lookup/utility REST endpoints |
| 7 | 1032 | `MobilePickingService` | `service/mobile/` | Mobile picking state machine |
| 8 | 994 | `MobileReplenishService` | `service/mobile/` | Mobile replenishment state machine |
| 9 | 952 | `OrderRestController` | `controller/rest/` | Customer order REST API |
| 10 | 781 | `CustomerorderService` | `service/` | Core order CRUD + status transitions |
| 11 | 676 | `ReceivingService` | `service/` | Goods receipt + advice processing |
| 12 | 637 | `AdviceRestController` | `controller/rest/` | Advice/PO REST API |
| 13 | 635 | `StockunitService` | `service/` | Stock unit moves + adjustments |
| 14 | 578 | `AdviceService` | `service/` | Advice management |
| 15 | 577 | `StockUnitController` | `controller/` | Stock unit web controller |
| 16 | 565 | `ReleaseOrderJobService` | `service/job/` | Order release job logic |
| 17 | 519 | `FileImportController` | `controller/` | Bulk file import controller |
| 18 | 499 | `ReplenishOrderJob` | `schedulejob/` | Replenishment scheduler config |
| 19 | 492 | `ReplenishmentOrderMaintenanceService` | `service/` | Replenishment order state management |
| 20 | 482 | `MobileCycleCountService` | `service/mobile/` | Mobile cycle count state machine |

**Take-away:** The five largest service classes (`ViewDtoService`, `WmsConstants`, `CustomerorderBatchService`, `BillofladingService`, `KeycloakService`) are each over 1000 lines. When modifying any of these, grep for the target symbol first — never full-read the file.

---

## Coupling Observations

```
controller ──→ service       (53 of 54 controller files import service classes)
service    ──→ repo/jpa      (68 of 74 service files import repo interfaces)
service    ──→ model         (66 of 74 service files import model entities)
service    ──→ json          (25 of 74 service files import DTOs)
repo/jpa   ──→ model         (61 of 61 repo interfaces parameterised on model entities)
```

**Dependency direction (strict):**

```
controller → service → repo → model
                     ↘ json (in/out DTOs)
                     ↘ exceptions (thrown)
```

**Observations:**

1. **Layered, no reverse dependencies.** `model` and `repo` classes do not import from `service` or `controller`. The direction is strictly top-down.
2. **Service-to-JSON coupling is partial (25/74).** Most DTO assembly is confined to `ViewDtoService` and a few business services. Controllers generally receive/return entity-like objects and map in the controller or rely on `ViewDtoService`.
3. **No direct controller-to-repo access.** Controllers always go through services — verified by zero `import net.aim_ai.wms.repo` occurrences in `controller/`.
4. **`WmsConstants` is a cross-cutting dependency.** Almost all services import it. It lives in `service/` but is effectively a global constants file, not a service.
5. **Mobile layer is self-contained.** `service/mobile/` imports from `service/` root (shared utilities) and `repo/jpa/`, but `controller/mobile/` only imports `service/mobile/` and `json/mobile/`. Mobile and web layers do not share controllers.
6. **`service/util/` utilities (`OmsNotificationHelper`, `OptimisticLockRetryTemplate`) are used across the service layer** — these are Spring beans injected where needed, not static helpers.

---

## Sub-Package Breakdown

### `service/mobile/` — Mobile Workflow Services

Each service represents one end-to-end handheld scanner operation. They are stateful in the sense that each step method is called in sequence by the mobile controller:

```
MobilePickingService:      startPicking → scanLocation → scanStockUnit → confirmPick → completePicking
MobileReplenishService:    startReplenish → scanSource → scanTarget → confirmReplenish
MobilePutAwayService:      startPutAway → scanUnitLoad → scanLocation → confirmPutAway
MobileCycleCountService:   startCount → scanLocation → countItem → confirmCount
```

These are the largest mobile services because they encode the full step-state logic inline. New mobile operations follow this same pattern.

### `service/job/` — Scheduled Job Logic

Three services backing the six scheduler classes:

- `ReleaseOrderJobService` (565 lines) — the heaviest; queries eligible orders, validates constraints, transitions order status, locks resources
- `ReplenishOrderJobService` — queries low-stock locations, generates `Replenishorder` entities
- `CleanUpOldMessageJobService` — straightforward purge with retention-window config

### `repo/jpa/` — JPA Repository Interfaces

61 Spring Data JPA interfaces. Naming is deterministic: entity `Customerorder` → `CustomerorderRepository`. Custom query methods use `findBy*`, `countBy*`, JPQL `@Query`, or native SQL `@Query(nativeQuery=true)`. No custom implementations — all method-name derived or `@Query` annotated.

### `repo/cinterface/` — Custom Base Interfaces

Two marker interfaces that restrict Spring Data defaults. Repositories for protected entities (e.g., audit records) extend these instead of `JpaRepository` to prevent accidental deletes.

### `controller/rest/` — External REST Controllers

All extend `AbstractRestController` which provides:
- Tenant/auth extraction helpers
- Standard pagination parameter handling
- Common error response formatting

These endpoints are consumed by the OMS (v1/oms PHP), external carriers, and the Club Line integration.

### `controller/mobile/` — Mobile API Controllers

Thin REST controllers mapping HTTP calls from `wms-mobile-ui`. Each delegates immediately to its corresponding `service/mobile/` class. Response objects are exclusively `json/mobile/` DTOs.

---

## Where to Put New Code

| Scenario | Target package |
|----------|---------------|
| New JPA entity / DB table | `model/` |
| New Spring Data repository | `repo/jpa/` |
| Protected entity (no hard delete) | `repo/jpa/` extending `NoDeletePagingAndSortingRepository` |
| Read-only view repository | `repo/jpa/` extending `ReadOnlyPagingAndSortingRepository` |
| Core business logic | `service/` root |
| New mobile scanner workflow | `service/mobile/` + `controller/mobile/` + `json/mobile/` |
| New scheduled background job | `schedulejob/` (thin trigger) + `service/job/` (logic) |
| Web UI endpoint | `controller/` root |
| External integration REST endpoint | `controller/rest/` extending `AbstractRestController` |
| Request/response DTO (web or REST) | `json/` |
| DTO used only by mobile screens | `json/mobile/` |
| New business rule exception | `exceptions/` extending `BusinessException` |
| New input validation exception | `exceptions/` extending `ApiInvalidParameterException` |
| New SSO/auth error | `exceptions/` extending `SsoException` |
| Pure Java utility (no Spring) | `util/` |
| Spring-aware shared helper | `service/util/` |
| Security / JWT / CORS config | root `net.aim_ai.wms` |
| System-wide constants | Add to `service/WmsConstants.java` |

---

## v1 vs v2 Structural Differences

| Dimension | v1/wms-api | v2/wms2-api |
|-----------|-----------|-----------|
| Java version | 8 | 21 |
| Spring Boot | 2.3.7 | 3.5.9 |
| Total classes | 359 | 383 |
| Multi-tenancy | HTTP headers → dynamic datasource routing | Same pattern, 4-char routing key |
| Multi-tenant infra package | **Absent** — routing handled in root config classes | Dedicated `landlord/` package (23 classes) |
| Service sub-packages | `mobile/`, `job/`, `util/` | Same structure |
| Controller sub-packages | `rest/`, `mobile/` | Same structure |
| Repo base interfaces | `cinterface/` (2) | Same concept |
| Caching | None (Spring Cache not wired) | Caffeine cache |
| Metrics / tracing | None | Micrometer + Zipkin |
| JSON/DTO count | 56 | 56 (same) |
| Exception count | 17 | 18 |
| Scheduled jobs | 6 classes | Comparable |
| `WmsConstants` | In `service/` root, 1290 lines | Same location, similar size |
| `ViewDtoService` | In `service/` root, 1380 lines | Equivalent class, comparable size |

**Key structural difference:** v2 adds a `landlord/` package (23 classes) for multi-tenant infrastructure that does not exist in v1. In v1, tenant routing is handled entirely in the root config classes (`SecurityConfiguration`, `SecurityContextUtils`, etc.) without a dedicated sub-package. When porting v1 features to v2, account for any tenant-context wiring changes in this package.

**What is the same:** The `controller → service → repo → model` layering, the mobile sub-package pattern, the `service/job/` + `schedulejob/` split, and all repository base interface conventions are identical between v1 and v2.

---

*Analysis based on 359 Java files. Run `find src/main/java -name "*.java" | wc -l` in `v1/wms-api/` to verify currency.*


---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |

**Re-verify every 90 days.** Next due: **2026-07-29**.
