---
title: WMS v2 Java Package Analysis
type: architecture
project: wms2
status: stable
created: 2026-01-20
last_verified: 2026-11-11
tags: [wms2, java, packages, architecture]
---

# WMS Project Java Package Analysis

*Generated: 2026-01-20 · Re-counted 2026-11-11 against wms2-api `origin/develop` @ `df30fa62`*

## Overview
Total Java files analyzed: **652** under `src/main/java` (`find src/main/java -name '*.java' | wc -l`; was 383 on 2026-01-20). All application code is under `net.aim_ai.wms`.

Counting rule: one file = one class/interface/enum/record; every file is counted in exactly one row (the rows sum to 652). Recount with `find src/main/java/net/aim_ai/wms/<dir> -name '*.java' | wc -l`.

## Package Breakdown

| Package | Count | Percentage | Description |
|---------|--------|------------|-------------|
| **Services** | 153 | 23.5% | Business logic and service layer (`service/` 131 + `service/mobile/` 13 + `service/job/` 9) |
| **Repositories** | 131 | 20.1% | `repo/jpa/` 69 Spring Data repositories + `repo/cinterface/` 2 + `repo/projection/` 60 projection interfaces |
| **JSON DTOs** | 78 | 12.0% | `json/` 55 + `json/mobile/` 23 |
| **Models** | 77 | 11.8% | `model/` — 69 JPA entities + `AbstractBaseEntity` + 5 composite-key `@Embeddable` `*Id` classes + `LockOverviewRow` + `UserRepresentationWithTempPw` |
| **Controllers** | 66 | 10.1% | `controller/` 44 + `controller/mobile/` 12 + `controller/rest/` 9 + `controller/actuator/` 1 |
| **Configuration/Utilities** | 49 | 7.5% | `config/` 10 + `util/` 19 + `util/json/` 7 + 13 root-package files (`StartApplication`, `SecurityConfiguration`, `WebConfig`, ...) |
| **Landlord/Multi-tenant** | 40 | 6.1% | `landlord/` — config 18, service 7, json 5, jpa 4, model 4, controller 2 |
| **Exceptions** | 27 | 4.1% | `exceptions/` |
| **Scheduled jobs** | 16 | 2.5% | `schedulejob/` |
| **Security** | 15 | 2.3% | `security/` (function guard / SDR rule guard) |
| **Total** | **652** | 100% | |

---

## Detailed Subpackage Analysis

### Controllers (66 files)
- **Main Controllers**: 44 files in `controller/` (43 annotated `@RestController`/`@Controller`; `RequestBodyIds` is a helper)
  - Core WMS operations (Client, Stock, Orders, etc.)
- **Mobile Controllers**: 12 files
  - Handheld device workflows (Picking, Putaway, Replenish, Transfer, Truck loading, etc.)
- **REST Controllers**: 9 files in `controller/rest/` (7 annotated controllers; `AbstractRestController` base and `UtilRestController`, a `@Service`)
  - RESTful API endpoints for external (OMS) integration
- **Actuator**: 1 file (`TenantPoolEndpoint`)
- Plus 2 landlord controllers (`TenantDiscoveryController`, `TenantProvisioningController`) counted under Landlord. 64 `@RestController`/`@Controller` classes in total (`grep -rlE '^@(RestController|Controller|RepositoryRestController)\b'`).

### Services (153 files)
- **Main Services**: 131 files in `service/` (102 annotated `@Service`; the rest are policies, value types, constants and helpers such as `WmsConstants`, `LockReads`, `StockAmount`)
  - Core business logic (OrderService, StockService, etc.)
- **Mobile Services**: 13 files (12 annotated `@Service`)
  - Mobile-specific business operations
- **Job Services**: 9 files in `service/job/` (7 annotated `@Service`)
  - Service-layer bodies of the scheduled tasks; the schedulers themselves are the 16 files in `schedulejob/`

### Repositories (131 files)
- **JPA Repositories**: 69 files in `repo/jpa/`
  - Spring Data JPA repository interfaces, one per tenant entity (1:1)
- **Custom Interfaces**: 2 files in `repo/cinterface/`
  - `NoDeletePagingAndSortingRepository`, `ReadOnlyPagingAndSortingRepository`
- **Projections**: 60 files in `repo/projection/`
  - Spring Data projection interfaces (not entities)
- The 4 landlord repositories live in `landlord/jpa/` and are counted under Landlord.

### Models (77 files)
- **Entity Models**: 69 tenant JPA entities (the 4 landlord entities are in `landlord/model/`). 56 table-backed + 13 SQL-view-backed
- **View Models**: 13 database-view entities for reporting and monitoring (`*MonitorView`, `*DtoView`, `StockView`, `StockrecordView`, `LockOverview*`, `ViewWarehouseLocationReport`)
- **Non-entity types**: `AbstractBaseEntity` (`@MappedSuperclass`), 5 `*Id` embeddables, `LockOverviewRow`, `UserRepresentationWithTempPw`
- Entity detail: [wms2-entity-enumeration-report.md](./wms2-entity-enumeration-report.md); landlord/tenant split: [wms2-landlord-vs-tenant-entity-map.md](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md)

### JSON DTOs (78 files)
- **API DTOs**: Request/response objects for REST APIs (`json/`, 55)
- **Mobile DTOs**: Specialized DTOs for mobile operations (`json/mobile/`, 23)
- Upload/import and report DTOs are mixed into `json/` by name (4 files match `*upload*`/`*import*`, 4 match `*report*`); there is no separate sub-package for them.

### Landlord/Multi-tenant (40 total)
- **Configuration**: 18 files in `landlord/config/`
  - Multi-tenant database routing, tenant-config caches, JWT decoding and startup Flyway migration
- **Services**: 7 files
  - Tenant management, warehouse provisioning and startup Flyway migration services
- **JSON**: 5 files
  - Tenant profile and provisioning request/result DTOs
- **Repositories**: 4 files in `landlord/jpa/`
- **Models**: 4 files
  - Tenant data models (`Tenant`, `TenantDbConfiguration`, `TenantAuthConfiguration`, `TenantDiscovery`)
- **Controllers**: 2 files
  - Tenant discovery and provisioning APIs

### Other packages
- **Exceptions** (27): 18 exception classes, 4 `@ControllerAdvice` handlers, 4 error-message types, 1 interface (`ApiExceptionInterface`)
- **Scheduled jobs** (16): `schedulejob/` — job classes plus `JobMetrics`, `SchedulingConfiguration`, `TenantSchedule`, `TriggerSpec`
- **Security** (15): `security/` — function-guard interceptor, SDR function guard and rule startup assertions

---

## Key Architectural Insights

### Service Layer Dominance
- **23.5%** of codebase is business logic services
- **Largest individual category** indicating service-oriented architecture
- **Good separation of concerns** with dedicated service classes

### Data Access Layer
- **31.9%** combined for Repositories + Models
- **Strong persistence layer** with comprehensive entity coverage
- **Well-structured** JPA repository pattern

### API Layer Structure
- **22.1%** combined for Controllers + DTOs
- **Comprehensive API coverage** for all operations
- **Mobile-first approach** with dedicated mobile controllers

### Multi-tenant Infrastructure
- **6.1%** dedicated to multi-tenancy (`landlord/`)
- **Sophisticated tenant isolation** and management
- **Enterprise-grade** architecture

---

## File Categories by Function

### Core Business Operations
- **Order Management**: CustomerOrder, PickingOrder, BillOfLading
- **Inventory Management**: StockUnit, UnitLoad, Location
- **Receiving Operations**: Receiving, GoodsReceipt, Advice
- **Mobile Operations**: Picking, Putaway, Replenish, Transfer

### Integration & Reporting
- **REST APIs**: External system integration
- **Report Services**: Data extraction and analytics
- **File Operations**: Bulk import/export capabilities

### Infrastructure & Security
- **Multi-tenant Support**: Tenant isolation and routing
- **Security**: Authentication, authorization, role management
- **Exception Handling**: Comprehensive error management
- **Job Scheduling**: Background task processing

---

## Quality Metrics

### Code Distribution
- **Well-balanced** distribution across layers
- **Service-heavy** architecture (good for testability)
- **Comprehensive** data access layer
- **Extensive** API coverage

### Architectural Patterns
- **MVC Pattern**: Clear separation of concerns
- **Repository Pattern**: Clean data access abstraction  
- **DTO Pattern**: Proper API contract management
- **Multi-tenant Pattern**: Enterprise-grade isolation

### Scalability Indicators
- **Modular structure**: Easy to extend and maintain
- **Service layer**: Supports business logic complexity
- **Mobile support**: Modern warehouse operations
- **Multi-tenant**: Enterprise deployment capability

---

## Recommendations

### Test Coverage Priority
1. **Services (153 files)**: Highest business logic value
2. **Controllers (66 files)**: API contract validation
3. **Models (77 files; 69 entities)**: Data integrity testing
4. **Mobile Services (13 files)**: Critical field operations

### Architecture Strengths
- **Service-oriented design** supports maintainability
- **Comprehensive API layer** enables integration
- **Multi-tenant architecture** supports scalability
- **Mobile-first approach** meets modern warehouse needs

### Areas for Review
- **Model complexity**: 69 tenant entities (+4 landlord) may indicate domain complexity
- **DTO proliferation**: 78 DTOs suggest API complexity
- **Exception handling**: 18 exception classes (27 files in `exceptions/`) show robust error management

---

*Analysis based on 652 Java files across `src/main/java/net/aim_ai/wms` (re-counted 2026-11-11)*

---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |
| 2026-11-11 | Re-counted every package vs wms2-api `origin/develop` @ `df30fa62`: `find src/main/java -name '*.java'` per directory (total 652, rows sum to 652), annotation scans (`@RestController`/`@Controller`/`@Service`/`@Entity`/`@ControllerAdvice`), entity/repository/projection counts, `extends *Exception` scan (18). New packages since 2026-05-08 (`git ls-tree` directory diff of `d61040c5` vs `df30fa62`): `controller/actuator`, `security`, `util/json`; none removed. 451 → 652 files since that commit. Rebuilt table, subpackage sections, percentages and recommendation counts; added Security / Scheduled jobs / Config rows and re-based the bucket definitions (projections now counted under Repositories). | 383 → 652 files; every 2026-01 count superseded | Claude (re-verify pass) |

**Re-verify every 90 days.** Next due: **2027-02-09**.
