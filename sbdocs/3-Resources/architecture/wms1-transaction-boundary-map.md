---
title: "WMS v1 — Transaction Boundary Map"
type: architecture
status: active
version: v1
scope: transactions
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-04-26
verified_by: code read of v1/wms-api src/main at HEAD
related:
  - wms2-transaction-osiv-boundary-map.md
  - wms1-vs-wms2-delta.md
tags:
  - architecture
  - transactions
  - concurrency
  - wms1
---

# WMS v1 — Transaction Boundary Map

**Scope:** Cross-cutting transaction behavior in `v1/wms-api` · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26 (grep-based code read against `src/main/java`)

---

## 1. Overview

`wms1-api` runs on Spring Boot 2.3.7 with a **single JPA transaction manager** (no multi-tenancy, no `@Primary` landmine). OSIV is on by default in Spring Boot 2.x — it is not explicitly disabled, so the `EntityManager` stays open through the HTTP response phase. Transaction strategy is **inconsistent**: some services use class-level `@Transactional`, others use method-level with explicit `rollbackFor`, and several have no `@Transactional` at all, relying on the OSIV-open session.

`REQUIRES_NEW` appears on all scheduled-job step methods (replenish, release) and on two shared utilities (`MessageService.createMessageInNewTransaction`, `SequenceTransactionService.getNextSequenceNumber`) — the same pattern as v2, but without the dual-TM complexity.

There is no `OptimisticLockRetry` utility. `@Version` is present on 45 entity fields scattered across individual model classes (not via a common base class). Retry on optimistic-lock failures is ad-hoc: `BasicService.getNextSequenceNumber()` has an inline 100-attempt loop; no other service has retry logic.

---

## 2. Topology

```
                             HTTP request
                                  ↓
                         (no tenant interceptor —
                          single DB per deployment)
                                  ↓
  ┌───────────────────────────────────────────────────────────────┐
  │  Controller (no @Transactional)                               │
  │      ↓                                                        │
  │  Service (@Transactional at class OR method level, or none)   │
  │      ↓                                                        │
  │  Single JPA EntityManager / HibernateTransactionManager       │
  │      ↓                                                        │
  │  Single HikariCP pool → PostgreSQL                            │
  └───────────────────────────────────────────────────────────────┘

  Scheduled jobs (SchedulingConfiguration):
    Configured via SchedulingConfigurer reading cron expressions
    from the LosSysprop DB table at startup.
    Each job's outer loop calls REQUIRES_NEW step-service methods.

  Post-commit side effects:
    TransactionSynchronizationManager.registerSynchronization(...)
    via OmsNotificationHelper.deferToCommit() — fires HTTP to OMS
    after the enclosing transaction commits.
    MessageService.createMessageInNewTransaction() opens a fresh
    REQUIRES_NEW tx for Message row persistence inside afterCommit.
```

---

## 3. Configuration Facts

| Fact | Value | Source |
|---|---|---|
| OSIV | **enabled** (Spring Boot 2.x default — never explicitly disabled) | `application.properties` (no `spring.jpa.open-in-view=false`) |
| Transaction manager | Single `HibernateTransactionManager` / `JpaTransactionManager` (Spring Boot auto-config) | Spring Boot autoconfiguration |
| Multi-tenancy | None — single DB per deployment, tenant identified by `tenant_name` + `facility_code` HTTP headers (routing is application-logic, not datasource-routing) | `AbstractRestController`, `SecurityContextUtils` |
| Sequence number retry | Inline 100-attempt loop in `BasicService.getNextSequenceNumber()` via `SequenceTransactionService.getNextSequenceNumber()` (`REQUIRES_NEW`) | `BasicService.java` |
| Exception domain types | `BusinessException`, `FacadeException` | `exceptions/` package |

### OSIV-enabled consequence

Because OSIV is on, the `EntityManager` stays open through the HTTP response serialization phase. Lazy associations can be resolved outside a service method (in the controller or Jackson serialization) without a `LazyInitializationException`. This masks missing eager fetches — code that appears to work in v1 will break in v2 where OSIV is disabled.

---

## 4. Service Transaction Inventory

### 4.1 Class-level `@Transactional` — entire service is transactional

Every public method participates in the same default propagation (`REQUIRED`). A call from controller → service starts one transaction that spans all repository calls within that method, unless overridden at method level.

| Service | Class annotation | Notes |
|---|---|---|
| `AdviceService` | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | Rolls back on both domain exception types; uses `OmsNotificationHelper.deferToCommit()` for post-commit OMS calls |
| `CustomerorderService` | `@Transactional` | Bare — rolls back on unchecked exceptions only (Spring default); has method-level `deferToCommit` calls for order cancel |
| `CustomerorderBatchService` | `@Transactional` | Bare class-level + one method override (`runClubLine` at line 560: `rollbackFor = {BusinessException, FacadeException}`); injects `MessageService`, `StockunitBusinessService`, `UnitloadService`, `ReplenishorderService`, `ManageOrderService` — widest cross-service fan-out in the codebase |
| `BillofladingService` | `@Transactional` | Bare class-level; calls `unitloadBusinessService`, `stockunitBusinessService`, `unitloadService`, `transferOrderService`, `messageService.createMessageInNewTransaction` (REQUIRES_NEW escape); OMS notification dispatched via Spring `ApplicationEventPublisher` (not `deferToCommit`) — handled by `BolClosedEventListener` with `@TransactionalEventListener(AFTER_COMMIT)` |
| `TransferOrderService` | `@Transactional` | Bare class-level; narrower scope than BillofladingService |

### 4.2 Method-level `@Transactional` — service has no class-level annotation

Each annotated method opens its own transaction; non-annotated methods run without a transaction (OSIV keeps the session open but there is no TX boundary).

| Service | Annotated methods | rollbackFor |
|---|---|---|
| `ReplenishorderService` | Lines 75, 97, 149 | `Exception.class` (all three) |
| `StockunitBusinessService` | Lines 123, 330 | None (bare) |
| `StockunitService` | Line 106 | None (bare); `deferToCommit` used for OMS notifications at lines 220, 318, 377, 420, 478, 484 |
| `UnitloadService` | Lines 276, 313 | `{BusinessException.class, FacadeException.class}` |
| `UnitloadBusinessService` | Lines 76, 148, 277 | None (bare) |
| `PickingorderBusinessService` | Line 222 | None (bare); `registerSynchronization` used at lines 150–157 and 346–348 for OMS pick events |
| `PickingorderPositionService` | Line 76 | `Exception.class` |
| `GoodsReceiptPositionService` | Lines 64, 104 | `{BusinessException.class, FacadeException.class}`; `deferToCommit` used at lines 96, 178 |
| `OrderMonitorViewService` | Lines 91, 334 | `{BusinessException.class, FacadeException.class}`; `deferToCommit` used at lines 189, 363 |
| `MobileReplenishService` | Lines 388, 732 | None (bare) |
| `MobilePickingService` | Lines 115, 176, 242, 341, 576, 599, 797 | `{BusinessException.class, FacadeException.class}` on all; `registerSynchronization` at line 440 |
| `MobileMoveUnitloadService` | Line 182 | None (bare) |

### 4.3 No `@Transactional` at class or method level

These services run without a Spring-managed transaction boundary. Reads work because OSIV keeps the session open; writes succeed if the caller is already inside a transaction (propagation defaults to `REQUIRED`). If called outside a transaction, writes fail silently or throw a JPA exception.

| Service | Notes |
|---|---|
| `BasicService` | Utility only — no direct writes; sequence numbers routed through `SequenceTransactionService` |
| `MessageService` (most methods) | `createMessage` / `createServiceLog` have no annotation — caller must supply a transaction. Only `createMessageInNewTransaction` has `REQUIRES_NEW` for use from afterCommit hooks |
| `ManageOrderService` | Inferred — no `@Transactional` found; called from inside caller transactions |
| `HttpRestService` | External HTTP — no transaction |
| `LosSyspropService` | Read-only lookups; no annotation found |

---

## 5. `REQUIRES_NEW` Isolation Inventory

`REQUIRES_NEW` suspends the caller's transaction and opens a fresh one. In v1, this pattern appears in two contexts: (1) scheduled-job step isolation so each step commits independently and (2) utility services that must write a row from inside a post-commit callback where no transaction is active.

### 5.1 `ReplenishOrderJobService` — all 7 methods use `REQUIRES_NEW`

Called by `ReplenishOrderJob` (schedulejob), which loops over work items. Each step commits independently so a single-item failure does not roll back already-processed items.

| Line | Method | Extra attributes | What it isolates |
|---|---|---|---|
| 57 | `deleteFixedLocationAssignment(...)` | — | Deletes one FLA record atomically |
| 75 | `calculateReplenishOrdersForItemData(...)` | — | Replenish order calculation for one item |
| 89 | `processFixedLocationAssignment(...)` | — | FLA processing + `replenishGeneratorService.calculateOrder()` |
| 191 | `processReplenishOrder(...)` | `rollbackFor = FacadeException.class` | Single replenish order execution |
| 213 | (unnamed, line 213) | — | Intermediate step |
| 224 | `recalculateReplenishmentOrders(...)` | — | Calls `replenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()` |
| 234 | `cancelReplenishmentOrder(...)` | — | Single order cancel via `replenishorderService.cancelReplenishmentOrder()` |

### 5.2 `ReleaseOrderJobService` — 1 method

| Line | Method | Extra attributes | What it isolates |
|---|---|---|---|
| 72 | `releaseOrder(...)` | — | One order's release cycle: picking position, stock unit, ManageOrderService OMS call |

### 5.3 `ReplenishOrderJob` (schedulejob) — 1 method

| Line | Method | Extra attributes | What it isolates |
|---|---|---|---|
| 387 | (method in `ReplenishOrderJob`) | — | Outer job loop step — calls ReplenishOrderJobService methods |

### 5.4 `MessageService.createMessageInNewTransaction` — post-commit message persistence

| Line | Method | Extra attributes | What it isolates |
|---|---|---|---|
| 65 | `createMessageInNewTransaction(...)` | — | Opens its own TX to persist a `Message` row from inside an `afterCommit` callback where the original TX is already committed and closed. Without `REQUIRES_NEW`, `messageRepository.save()` would fail with no active transaction. |

### 5.5 `SequenceTransactionService.getNextSequenceNumber` — serialized sequence increment

| Line | Method | Extra attributes | What it isolates |
|---|---|---|---|
| 21 | `getNextSequenceNumber(String key)` | — | Reads + increments `LosSequencenumber` row. `REQUIRES_NEW` ensures the increment commits immediately, making the new value visible to concurrent callers before the outer TX commits. Called up to 100 times by `BasicService.getNextSequenceNumber()` in a retry loop. |

---

## 6. Cross-Service Call Map

These are calls where a `@Transactional` service method invokes another `@Transactional` service. The boundary effect depends on propagation: the default `REQUIRED` means the callee joins the caller's transaction (no new boundary). `REQUIRES_NEW` creates a real boundary.

### 6.1 `BillofladingService` (class `@Transactional`) calls

| Callee | Method | Propagation effect | Risk |
|---|---|---|---|
| `UnitloadBusinessService` | `transferPalletTreesToLocation`, `sendToNirvana`, `transferUnitLoadToLocation` | Joins BOL transaction (REQUIRED) | If callee throws unchecked, BOL tx rolls back |
| `StockunitBusinessService` | `transferStockToUnitLoad` | Joins BOL transaction | Same |
| `UnitloadService` | `createUnitload` | Joins BOL transaction | Same |
| `TransferOrderService` | `isEnoughStockOnTransferLane` | Joins BOL transaction | Same |
| `BasicService` | `generateNumber`, `getNextSequenceNumber` | `getNextSequenceNumber` internally calls `SequenceTransactionService.getNextSequenceNumber()` with `REQUIRES_NEW` — **real boundary** | Sequence increment commits even if BOL tx later rolls back |
| `MessageService` | `createMessageInNewTransaction` | `REQUIRES_NEW` — **real boundary** | Message row persists even if BOL tx rolls back |

### 6.2 `CustomerorderBatchService` (class `@Transactional`) calls

| Callee | Method | Propagation effect | Risk |
|---|---|---|---|
| `ReplenishorderService` | `updateReplenishmentOrderPriority` | Joins batch transaction | Callee rollback rolls back batch |
| `StockunitBusinessService` | `changeReservedAmount`, `transferStockToUnitLoad` | Joins batch transaction | Same |
| `UnitloadService` | `createUnitload` | Joins batch transaction | Same |
| `ManageOrderService` | `assignClubHistoryTotes`, `customerOrderReleaseForPicking`, `customerOrderPickingStarted`, `customerOrderPicked` | Joins batch transaction — **but** these OMS HTTP calls are deferred via `afterCommit` at line 743 | If sync not active, afterCommit silently no-ops |
| `MessageService` | `createMessage` (plain, no annotation) | No new TX — runs inside caller's transaction; `messageRepository.save` works because a TX is already active | Message row rolled back if batch tx rolls back |
| `BasicService` → `SequenceTransactionService` | `getNextSequenceNumber` | `REQUIRES_NEW` — real boundary | Sequence increment survives rollback |

### 6.3 `PickingorderBusinessService` (method `@Transactional` at line 222) calls

| Callee | Method | Propagation effect | Risk |
|---|---|---|---|
| `CustomerorderService` | `cleanUpCancelledOrder` | `CustomerorderService` is class-level bare `@Transactional` → joins caller's TX | Single shared TX; callee exception rolls back pick completion |
| `StockunitBusinessService` | `changeReservedAmount`, `transferStockToUnitLoad` | Joins caller's TX | Same |
| `UnitloadBusinessService` | `transferUnitLoadToLocation`, `sendToNirvana` | Joins caller's TX | Same |
| `ManageOrderService` | `customerOrderPicked`, `customerOrderPickingStarted`, `customerOrderOnHold` | Deferred to `afterCommit` via `registerSynchronization` at lines 155, 346 | OMS notification; if sync not active it drops silently |
| `BasicService` → `SequenceTransactionService` | `getNextSequenceNumber` | `REQUIRES_NEW` — real boundary | Sequence survives rollback |

### 6.4 `ReplenishOrderJobService` (all `REQUIRES_NEW`) calls

| Callee | Method | Propagation effect |
|---|---|---|
| `ReplenishorderService` | `recalculateReplenishmentOrderWithoutFixedLocationAssignment`, `cancelReplenishmentOrder` | `ReplenishorderService` methods are method-level `@Transactional(rollbackFor=Exception)` — when called from within a `REQUIRES_NEW` context, they join the job's fresh transaction |
| `ReplenishGeneratorService` | `calculateOrder` | Joins the `REQUIRES_NEW` job tx |
| `FixLocationAssignmentService` | `delete` | Joins the `REQUIRES_NEW` job tx |
| `BasicService` → `SequenceTransactionService` | `getNextSequenceNumber` | Nested `REQUIRES_NEW` — commits immediately inside the outer `REQUIRES_NEW` job tx |

### 6.5 `ReleaseOrderJobService` (`REQUIRES_NEW`) calls

| Callee | Method | Propagation effect |
|---|---|---|
| `PickingorderPositionService` | (release methods) | Joins the `REQUIRES_NEW` release tx |
| `StockunitBusinessService` | (stock operations) | Joins the `REQUIRES_NEW` release tx |
| `ManageOrderService` | `customerOrderOnHold` | Called inline inside the `REQUIRES_NEW` tx (line 192) — HTTP to OMS inside an active transaction (not deferred) |

---

## 7. Post-commit Hooks

v1 uses `TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() { afterCommit() {...} })` directly, plus the `OmsNotificationHelper.deferToCommit()` utility which wraps the same pattern. The pattern is identical to v2 but without the v2 helper's `MessageService.createMessageInNewTransaction` pairing being standardized — some call sites use both, some use only one.

| File | Lines | Mechanism | Purpose |
|---|---|---|---|
| `service/util/OmsNotificationHelper.java` | 63–68 | `registerSynchronization` + `afterCommit` | Reusable utility; wraps HTTP OMS call; exceptions caught and logged |
| `service/AdviceService.java` | 233, 344, 434 | `OmsNotificationHelper.deferToCommit` | OMS notifications: hub-and-spoke accept, close advice, transfer advice |
| `service/UnitloadService.java` | 305, 342 | `OmsNotificationHelper.deferToCommit` | OMS notification on unitload delete |
| `service/StockunitService.java` | 220, 318, 377, 420, 478, 484 | `OmsNotificationHelper.deferToCommit` | Stock split damaged, on-hold lock, damaged lock, adjust amount, lock removal |
| `service/CustomerorderBatchService.java` | 227, 707–750 | Both `deferToCommit` (line 227) and inline `registerSynchronization` (line 743) | Cancel batch, and three-step OMS progression after club line |
| `service/CustomerorderService.java` | 693 | `OmsNotificationHelper.deferToCommit` | Order cancel OMS notification |
| `service/GoodsReceiptPositionService.java` | 96, 178 | `OmsNotificationHelper.deferToCommit` | Goods receipt position adjust and delete OMS notifications |
| `service/OrderMonitorViewService.java` | 189, 363 | `OmsNotificationHelper.deferToCommit` | Tote label print and reprint OMS notifications |
| `service/PickingorderBusinessService.java` | 150–157, 346–348 | Inline `registerSynchronization` | Pick completion and pick-started OMS events |
| `service/BillofladingService.java` | 587 | `ApplicationEventPublisher.publishEvent(BolClosedEvent)` → `BolClosedEventListener` (`@TransactionalEventListener(AFTER_COMMIT)`) | BOL close OMS notification + Message row persistence; failure caught and recorded as `FAILED` message (not silently dropped) |
| `event/BolClosedEventListener.java` | 34 | `@TransactionalEventListener(phase = AFTER_COMMIT)` | Handles `BolClosedEvent`: HTTP POST to OMS + `createMessageInNewTransaction`; catches all exceptions and persists `FAILED` message on error |
| `service/mobile/MobilePickingService.java` | 440–445 | Inline `registerSynchronization` | Mobile pick post-commit OMS action |

**Landmine**: `OmsNotificationHelper.deferToCommit` checks `isSynchronizationActive()` before registering. If the calling method has no active transaction (e.g., called from a test, or from a no-`@Transactional` method), the registration is silently skipped and the OMS notification never fires.

---

## 8. Locking Strategy

### 8.1 Optimistic — `@Version` fields

v1 has 45 `@Version` fields spread across individual entity classes (no shared base class like v2's `AbstractBaseEntity`). Coverage is uneven — major transactional entities (listed below) have it, but not all.

Notable `@Version` entities:
`Advice`, `Unitload`, `FixLocationAssignment`, `Message`, `Client`, `LocationArea`, `LocationRack`, `Boxtype`, `MywmsGroup`, `Queryrepository` (plus ~35 others).

Notably **missing** `@Version` (no shared base, must check each entity manually): `Stockunit`, `Pickingorder`, `Customerorder`, `CustomerorderBatch`, `Billoflading`, `Replenishorder` — these high-contention entities rely on pessimistic locks or application-level coordination, not optimistic versioning.

### 8.2 Pessimistic — `@Lock(PESSIMISTIC_WRITE)` repository methods

| Repository | Entity | Timeout hint |
|---|---|---|
| `StockunitRepository` | `Stockunit` | None |
| `PickingorderRepository` | `Pickingorder` | None |
| `CustomerorderRepository` | `Customerorder` | None |
| `CustomerorderBatchRepository` | `CustomerorderBatch` | None |
| `BillofladingRepository` | `Billoflading` | None |

No lock timeout hints exist in v1. All 5 pessimistic locks will wait indefinitely (limited only by the Hikari connection-acquire timeout). Under picking bursts or BOL close contention, this can cause connection pool exhaustion.

### 8.3 Sequence number retry — inline loop in `BasicService`

No `OptimisticLockRetry` utility exists (that was introduced in v2). Sequence number generation in `BasicService.getNextSequenceNumber()` has an inline retry loop (up to 100 attempts) that calls `SequenceTransactionService.getNextSequenceNumber()` with `REQUIRES_NEW`. Each attempt is a separate committed transaction. This is the only systematic retry in v1.

No other service has optimistic-lock retry logic. An `ObjectOptimisticLockingFailureException` on any `@Version`-bearing entity outside the sequence path will propagate to the controller and result in an HTTP 500 unless caught explicitly.

---

## 9. Scheduled Jobs

Jobs are wired via `SchedulingConfiguration implements SchedulingConfigurer`. Cron expressions are read from the `LosSysprop` DB table at startup (not hardcoded). Jobs run when `app.cron=true`.

| Class | Role | `@Transactional`? | Notes |
|---|---|---|---|
| `ReplenishOrderJob` | Outer replenish loop | One method at line 387 uses `REQUIRES_NEW` | Iterates replenish work; calls `ReplenishOrderJobService` REQUIRES_NEW step methods |
| `ReleaseOrderJobService` | Order release | `REQUIRES_NEW` at line 72 | Each order release is its own tx |
| `ReplenishOrderJobService` | Replenish steps | All 7 methods `REQUIRES_NEW` | See §5.1 |

Scheduled job threads have no special context setup — they use whatever DB connection Spring provides via the single datasource.

---

## 10. Common Bug Patterns

### 10.1 Silent rollback on unchecked exception in bare `@Transactional` services

`CustomerorderService`, `CustomerorderBatchService`, `BillofladingService`, `TransferOrderService` all use bare `@Transactional` with no `rollbackFor`. Spring's default is to roll back only on `RuntimeException` (unchecked) and `Error`, NOT on checked exceptions (including `BusinessException` and `FacadeException` if they extend `Exception` rather than `RuntimeException`). If a domain checked exception propagates out of these services, the transaction **commits** even though the operation failed. Developers expecting rollback must add `rollbackFor`.

**Diagnosis**: exception logged, no DB changes visible, but no HTTP error either — caller got a success response.

### 10.2 Missing `rollbackFor` masked by OSIV

Because OSIV is on, detached entity access in the response phase does not throw. Code that would produce a `LazyInitializationException` in v2 silently loads the association. This masks service methods that return lazily-associated entities without fetching them inside the transaction. When this code is ported to v2, it breaks.

### 10.3 `REQUIRES_NEW` inside a rollback: sequence numbers are not rolled back

`BasicService.getNextSequenceNumber()` calls `SequenceTransactionService.getNextSequenceNumber()` which is `REQUIRES_NEW`. That sequence increment commits in its own transaction. If the outer service transaction later rolls back, the sequence number is already incremented — gaps in entity numbers are permanent.

Same applies to `MessageService.createMessageInNewTransaction`: a `Message` row can be persisted in the DB even when the surrounding BOL or pick transaction rolls back.

### 10.4 `afterCommit` OMS notification silently drops when no sync is active

`OmsNotificationHelper.deferToCommit` and inline `registerSynchronization` calls all guard with `isSynchronizationActive()`. A service method that has no `@Transactional` (or is called from a test context or a non-transactional path) will silently skip the OMS notification. No exception is thrown, no log entry is written at WARN or above by default. OMS state and WMS state diverge without any visible error.

**Diagnosis**: WMS DB shows updated state, OMS has no corresponding event, no exception in logs.

### 10.5 Pessimistic locks with no timeout can exhaust the connection pool

All 5 `PESSIMISTIC_WRITE` repositories have no `jakarta.persistence.lock.timeout` hint. Under concurrent picking or BOL close, threads queue on the row lock and hold their HikariCP connections. Once the pool is exhausted, new requests fail with connection-acquire timeouts. v2 addressed this on two of the five repositories; v1 has no mitigation.

**Diagnosis**: connection pool exhaustion during high-throughput picking windows; `HikariPool-1 - Connection is not available` in logs.

### 10.6 Cross-service calls inside `@Transactional` with inconsistent `rollbackFor`

When a class-level bare `@Transactional` service (e.g., `CustomerorderBatchService`) calls a method-level `@Transactional(rollbackFor=Exception)` service (e.g., `ReplenishorderService`), the callee's `rollbackFor` attribute is irrelevant — the callee joins the caller's transaction (REQUIRED propagation) and the **caller's** rollback rules govern. A checked exception that would have triggered rollback in `ReplenishorderService` may commit silently inside `CustomerorderBatchService`.

**Diagnosis**: replenishment update appears to succeed (no exception propagated to controller), but replenish state is inconsistent.

### 10.7 `ManageOrderService` OMS calls inside a `REQUIRES_NEW` job transaction (not deferred)

`ReleaseOrderJobService.releaseOrder` calls `ManageOrderService.customerOrderOnHold` at line 192 **inside** the `REQUIRES_NEW` transaction, not via `deferToCommit`. If the OMS HTTP call fails (timeout, 500), the exception propagates and rolls back the entire release step. The order stays in its pre-release state and the job must retry. This differs from the `CustomerorderBatchService` pattern where OMS calls are deferred to afterCommit to prevent OMS failures from rolling back WMS state.

---

## 11. v1 vs v2 Key Differences

| Concern | v1 | v2 |
|---|---|---|
| Transaction managers | 1 (single DB) | 2 (`landlordTransactionManager` @Primary, `tenantTransactionManager`) |
| OSIV | Enabled (default) | Disabled (`spring.jpa.open-in-view=false`) |
| `@Version` base class | None — per-entity, inconsistent coverage (45 fields) | `AbstractBaseEntity.version` — all tenant entities inherit it |
| Optimistic lock retry | Inline loop in `BasicService` (sequence only) | `OptimisticLockRetry` utility (3 attempts, exponential backoff) |
| Lock timeouts | None on any pessimistic lock | 5s hint on `CustomerorderBatch` and `Billoflading` |
| `@Primary` landmine | None — single TM | Yes — bare `@Transactional` silently uses landlord, not tenant |
| Post-commit pattern | `OmsNotificationHelper.deferToCommit()` + inline `registerSynchronization` | Same utility pattern; standardized more consistently |
| `REQUIRES_NEW` sites | 10 (excluding `ReplenishOrderJob` outer) | 17 |

---

## 12. How to Use This Doc

| Task | Section |
|---|---|
| Debug a silent rollback (exception thrown but DB not rolled back) | §10.1 (missing rollbackFor), §4.1–4.2 (service annotations) |
| Debug a "picks committed but OMS never notified" incident | §7 (post-commit hooks), §10.4 (silent drop) |
| Debug connection pool exhaustion during picking | §8.2 (pessimistic locks), §10.5 |
| Debug a detached entity exception after porting code to v2 | §3 (OSIV), §10.2 |
| Understand why a sequence number gap appeared after a rollback | §5.5 (SequenceTransactionService), §10.3 |
| Trace which transaction a cross-service call runs in | §6 (cross-service call map), §4 (service inventory) |
| Add a new scheduled job step | §9, §5 (REQUIRES_NEW pattern) |
| Add a post-commit OMS notification | §7 (OmsNotificationHelper.deferToCommit), §10.4 (isSynchronizationActive guard) |

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | All `@Transactional` annotations (class + method level), `REQUIRES_NEW` inventory, `rollbackFor`/`noRollbackFor`/`readOnly` flags, `@Version` model fields, `@Lock` repository methods, `registerSynchronization`/`deferToCommit` call sites, scheduled job classes, cross-service injection and call sites in hot files | All counts and file:line refs confirmed against `src/main/java` | Grep-based code read |

**Re-verify when any of the following change:** service transaction annotations, new services added to `service/job/`, `OmsNotificationHelper`, `SequenceTransactionService`, `BasicService.getNextSequenceNumber`. Next scheduled review: 2026-07-26.
