---
title: "Uniform @Transactional Strategy — wms-api v1"
ticket: ""
ticket_url: ""
type: refactor
priority: high
status: draft
project:
  - wms1
version: v1
requester: Nam Park
created: "2026-04-27"
updated: "2026-04-27"
related:
  - ../../../3-Resources/decisions/ADR-004-mixed-transactional-strategy-v1.md
  - ../../../3-Resources/architecture/wms1-transaction-boundary-map.md
tags:
  - plan
  - transactions
  - stability
---

# Uniform @Transactional Strategy — wms-api v1

**Project:** wms1 | **Version:** v1 | **Type:** refactor
**Priority:** high
**Status:** draft
**Date:** 2026-04-27

---

## 0. Affected Sites (Enumeration Before Drafting)

### Stage 1 — Fix `rollbackFor` on bare `@Transactional` (class-level)

| # | File | Line | Construct | In-scope? | Phase |
|---|------|------|-----------|-----------|-------|
| A1 | `service/CustomerorderService.java` | :28 | `@Transactional` (bare, class-level) | Yes | Stage 1 |
| A2 | `service/BillofladingService.java` | :29 | `@Transactional` (bare, class-level) | Yes | Stage 1 |
| A3 | `service/TransferOrderService.java` | :20 | `@Transactional` (bare, class-level) | Yes | Stage 1 |
| A4 | `service/CustomerorderBatchService.java` | :31 | `@Transactional` (bare, class-level) | Yes | Stage 1 |

### Stage 1 — Fix `rollbackFor` on bare `@Transactional` (method-level)

| # | File | Line | Construct | In-scope? | Phase |
|---|------|------|-----------|-----------|-------|
| B1 | `service/StockunitBusinessService.java` | :123 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B2 | `service/StockunitBusinessService.java` | :330 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B3 | `service/UnitloadBusinessService.java` | :76 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B4 | `service/UnitloadBusinessService.java` | :148 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B5 | `service/UnitloadBusinessService.java` | :277 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B6 | `service/PickingorderBusinessService.java` | :222 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B7 | `service/StockunitService.java` | :106 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B8 | `service/mobile/MobileReplenishService.java` | :388 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B9 | `service/mobile/MobileReplenishService.java` | :732 | `@Transactional` (bare, method) | Yes | Stage 1 |
| B10 | `service/mobile/MobileMoveUnitloadService.java` | :182 | `@Transactional` (bare, method) | Yes | Stage 1 |

### Stage 1 — Already correct (no change needed)

| # | File | Annotation | Status |
|---|------|-----------|--------|
| OK1 | `service/AdviceService.java` | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` | Correct — no change |
| OK2 | `service/CustomerorderBatchService.java:560` | `runClubLine` method override | Correct — no change |
| OK3 | `service/UnitloadService.java` | `rollbackFor = {BusinessException.class, FacadeException.class}` | Correct — no change |
| OK4 | `service/GoodsReceiptPositionService.java` | `rollbackFor = {BusinessException.class, FacadeException.class}` | Correct — no change |
| OK5 | `service/ReplenishorderService.java` | `rollbackFor = Exception.class` | Correct — no change |
| OK6 | `service/MobilePickingService.java` | `rollbackFor = {BusinessException.class, FacadeException.class}` | Correct — no change |

### Stage 1 — `REQUIRES_NEW` sites (DO NOT TOUCH)

| # | File | Method | Why preserved |
|---|------|--------|--------------|
| RN1 | `service/SequenceTransactionService.java` | `getNextSequenceNumber` | Independent commit required; outer TX rollback must not undo it |
| RN2 | `service/MessageService.java:65` | `createMessageInNewTransaction` | Audit message must survive caller rollback |
| RN3 | `service/job/ReleaseOrderJobService.java:72` | `releaseOrder` | Per-order isolation in batch job |
| RN4 | `service/job/ReplenishOrderJobService.java:57` | `deleteEmptyFixAssignment...` | Per-item step isolation |
| RN5 | `service/job/ReplenishOrderJobService.java:75` | `generateReplenishment...WithoutFixedAssignment` | Per-item step isolation |
| RN6 | `service/job/ReplenishOrderJobService.java:89` | `generateReplenishment...WithFixedAssignment` | Per-item step isolation |
| RN7 | `service/job/ReplenishOrderJobService.java:191` | `refillFixedLocationAssignment` | Per-item step isolation |
| RN8 | `service/job/ReplenishOrderJobService.java:213` | `updateReplenishmentOrderPriority` | Per-item isolation |
| RN9 | `service/job/ReplenishOrderJobService.java:224` | `recalculateReplenishment...` | Per-item isolation |
| RN10 | `service/job/ReplenishOrderJobService.java:234` | `cancelReplenishmentOrder` | Per-item isolation |
| RN11 | `schedulejob/ReplenishOrderJob.java:387` | `mergePickingOrders` | Per-merge scheduled-job isolation |

### Stage 2 — Annotate phantom-transaction services

| # | File | Write calls | In-scope? | Phase |
|---|------|------------|-----------|-------|
| C1 | `service/FixLocationAssignmentService.java` | 9 | Yes | Stage 2 |
| C2 | `service/ReceivingService.java` | 6 | Yes | Stage 2 |
| C3 | `service/mobile/MobileCycleCountService.java` | 6 | Yes | Stage 2 |
| C4 | `service/StockrecordService.java` | 6 | Yes | Stage 2 |
| C5 | `service/CyclecountService.java` | 4 | Yes | Stage 2 |
| C6 | `service/mobile/MobileTruckLoadingService.java` | 4 | Yes | Stage 2 |
| C7 | `service/ReplenishmentOrderMaintenanceService.java` | 4 | Yes | Stage 2 |
| C8 | `service/ReplenishGeneratorService.java` | 2 | Yes | Stage 2 |
| C9 | `service/mobile/MobilePalletizingService.java` | 2 | Yes | Stage 2 |
| C10 | `service/ManageOrderService.java` | 1 | Yes | Stage 2 |
| C11 | `service/HttpRestService.java` | 0 | No — external HTTP, no DB writes | — |
| C12 | `service/LosSyspropService.java` | 3 | Yes — config writes | Stage 2 |

### Stage 3 — Convert Pattern A class-level to method-level

| # | File | Action | Phase |
|---|------|--------|-------|
| D1 | `service/CustomerorderService.java` | Remove class-level; add method-level on writes + `readOnly=true` on reads | Stage 3 |
| D2 | `service/BillofladingService.java` | Remove class-level; add method-level on writes + `readOnly=true` on reads | Stage 3 |
| D3 | `service/TransferOrderService.java` | Remove class-level; add method-level on writes + `readOnly=true` on reads | Stage 3 |
| D4 | `service/CustomerorderBatchService.java` | Remove class-level; add method-level on writes + `readOnly=true` on reads | Stage 3 |
| D5 | `service/AdviceService.java` | Convert class-level to method-level (already has correct rollbackFor) | Stage 3 |

### Stage 4 — Disable OSIV

| # | File | Change | Phase |
|---|------|--------|-------|
| E1 | `src/main/resources/application.properties` | Add `spring.jpa.open-in-view=false` | Stage 4 |

---

## 1. Problem Statement

`wms-api` v1 has had multiple production incidents traced to its mixed `@Transactional` strategy. Three structural defects are active:

**Defect 1 — Silent commit on checked exception (data corruption vector).** Four services use bare `@Transactional` with no `rollbackFor`: `CustomerorderService`, `BillofladingService`, `TransferOrderService`, `CustomerorderBatchService`. Spring's default only rolls back on unchecked exceptions. When `BusinessException` or `FacadeException` escapes a method in these services — which happens on every domain-error path — the transaction **commits the partial database state** and returns an error to the caller. The exception is visible in the logs; the half-written data is not.

`BillofladingService.closeBOL()` is the highest-risk single method in the codebase: it is a multi-phase operation (9 phases) under a bare class-level annotation. A `BusinessException` thrown in Phase 4 commits Phases 1–3 and leaves the BOL in a corrupted intermediate state. This is the most likely cause of the BOL-state divergence incidents reported in production.

**Defect 2 — Phantom-transaction write paths (OSIV dependency).** Thirteen services perform `.save()` / `.delete()` calls with no `@Transactional` annotation at any level. They work in HTTP request contexts because OSIV keeps a Hibernate session open for the whole request, auto-flushing at response time. This is not a transaction — it is OSIV masking missing boundaries. These services have no atomicity guarantee, no rollback path, and will throw `TransactionRequiredException` immediately if OSIV is ever disabled or if they are called from a scheduled-job or async context.

**Defect 3 — Ten bare method-level annotations without `rollbackFor`.** Pattern B services have `@Transactional` on individual write methods but without `rollbackFor`. Same silent-commit risk as Defect 1 but scoped to specific write methods.

The ADR-004 decision to accept the mixed strategy was correct at the time (2022) given audit cost and system stability. The "Do NOT revisit unless" trigger in ADR-004 has now been met: production data integrity failures are traced to the missing `rollbackFor` boundary.

---

## 2. Current Architecture

### 2.1 Transaction pattern distribution

| Pattern | Count | Services |
|---------|-------|---------|
| A — class-level `@Transactional` (bare, no rollbackFor) | 4 | CustomerorderService, BillofladingService, TransferOrderService, CustomerorderBatchService |
| A-correct — class-level with rollbackFor | 1 | AdviceService |
| B — method-level (mixed: some with rollbackFor, some bare) | ~15 | StockunitBusinessService, UnitloadBusinessService, PickingorderBusinessService, StockunitService, UnitloadService, GoodsReceiptPositionService, MobilePickingService, MobileReplenishService, MobileMoveUnitloadService, PickingorderPositionService, OrderMonitorViewService, ReplenishorderService, MessageService, others |
| C — no annotation, writes performed via OSIV session | 13+ | FixLocationAssignmentService, ReceivingService, CyclecountService, StockrecordService, ReplenishmentOrderMaintenanceService, ReplenishGeneratorService, ManageOrderService, MobileCycleCountService, MobileTruckLoadingService, MobilePalletizingService, LosSyspropService |
| REQUIRES\_NEW (intentional, correct) | 11 methods | SequenceTransactionService, MessageService, ReleaseOrderJobService, ReplenishOrderJobService, ReplenishOrderJob |

### 2.2 OSIV status

`spring.jpa.open-in-view` is not set in `application.properties`. Spring Boot 2.3.7 defaults to `true`. OSIV is ON and load-bearing for all 13+ Pattern C services.

### 2.3 Transaction manager

Single `JpaTransactionManager` auto-configured by Spring Boot. `@EnableTransactionManagement` declared on `StartApplication.java:39`. No custom timeout override. No secondary transaction manager.

### 2.4 `afterCommit` / OMS notification sites

Five sites register `TransactionSynchronization.afterCommit` callbacks for OMS notifications. All require an active transaction synchronization context:

| Site | File:line |
|------|-----------|
| order-picked notification | `PickingorderBusinessService.java:150-163` |
| confirmPick OMS callback | `PickingorderBusinessService.java:346-348` |
| runClubLine OMS notification | `CustomerorderBatchService.java:742-745` |
| processPick OMS callback | `MobilePickingService.java:440-442` |
| closeBOL OMS notification | `BillofladingService.java:593` |

If a calling method has no `@Transactional`, `TransactionSynchronizationManager.isSynchronizationActive()` returns false and `OmsNotificationHelper.deferToCommit()` falls back to synchronous HTTP — no exception, no warning log. WMS writes; OMS never hears.

---

## 3. Design

The target uniform strategy is **method-level `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` on all write methods, `@Transactional(readOnly = true)` on all pure-read methods.** This is the same pattern already used correctly by `AdviceService`, `UnitloadService`, and `GoodsReceiptPositionService`.

### 3.1 Stage 1 — Fix `rollbackFor` on all bare annotations

**Problem:** Bare `@Transactional` (class-level and method-level) silently commits on `BusinessException` and `FacadeException`.

**Solution — class-level (4 services):** Change `@Transactional` → `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` on the class declaration of `CustomerorderService`, `BillofladingService`, `TransferOrderService`, `CustomerorderBatchService`.

**Solution — method-level (10 annotations):** Change bare `@Transactional` → `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` at each of the B1–B10 sites enumerated in §0.

**Why `{BusinessException.class, FacadeException.class}` and not `Exception.class`:** Aligns with the existing correct pattern used by `AdviceService` (the reference service), `UnitloadService`, `GoodsReceiptPositionService`, and `MobilePickingService`. The domain only throws these two checked exception types from write paths — using `Exception.class` would also trigger rollback on `IOException` from print/HTTP operations that may be handled separately. Either is safe; this is consistent with the codebase majority.

**Risk:** Near-zero. This tightens rollback semantics. The only regression scenario is code that intentionally commits partial state after throwing a `BusinessException` — which would itself be a design bug and should surface.

**Files:** A1–A4 (class-level), B1–B10 (method-level). See §0.

### 3.2 Stage 2 — Annotate phantom-transaction write methods

**Problem:** 13+ services perform `.save()` / `.delete()` with no `@Transactional`. They run under OSIV session auto-flush with no atomicity, no rollback, and no isolation from other concurrent sessions.

**Solution:** For each C1–C12 service, enumerate all public write methods (those that call `.save()` or `.delete()` on any repository) and add `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})`. Pure-read-only methods in these services receive `@Transactional(readOnly = true)`.

**Approach per service:**
1. `grep -n "\.save\|\.delete" ServiceName.java` to locate all write calls.
2. Walk up to the enclosing method signature.
3. Add `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` above the method.
4. For methods that only read (no `.save`, no `.delete`, no state mutation), add `@Transactional(readOnly = true)`.
5. Methods that are always called from within a caller that already has `@Transactional` may be left unannotated only if all callers are confirmed transactional — do not assume; annotate by default.

**Special case — `ManageOrderService` (C10):** Single `.save()` call. This is the OMS gateway. Verify it always has a caller-provided transaction before leaving unannotated. Default: annotate.

**Special case — `StockrecordService` (C4):** Writes are audit-trail records. These should commit even if the outer operation rolls back in some call paths. Audit the callers before deciding between `REQUIRED` (default) and `REQUIRES_NEW`. Flag in implementation report.

**Risk:** Low per service. The write path goes from "relies on OSIV auto-flush or caller TX" to "owns its own transaction." Behavior is identical in HTTP request paths. Regression risk is in: (a) any test that calls these services without a TX context (will now succeed instead of fail silently — this is a fix, not a regression), (b) any caller that expected to commit with the phantom TX already open — cannot happen in practice because OSIV does not provide transactional isolation.

### 3.3 Stage 3 — Convert class-level to method-level, add `readOnly = true`

**Problem:** Class-level `@Transactional` opens a read-write transaction for every public method, including trivial lookups like `getBolDetails()`, `getCustomerOrderDetails()`, and `getAdviceDetails()`. This holds DB connections unnecessarily on polling-heavy endpoints. New methods added to these services silently inherit a read-write transaction with no visible annotation.

**Solution:** For each D1–D5 service:
1. Remove the class-level `@Transactional` annotation.
2. For each write method: add `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})`.
3. For each pure-read method: add `@Transactional(readOnly = true)`.
4. For methods that currently override or supplement the class-level annotation: retain or adjust their existing annotation.

**`readOnly = true` — what qualifies as a pure-read method:** No `.save()`, no `.delete()`, no `@Modifying` repository calls, no entity state mutations (setter calls on managed entities), no sequence number fetches. Query-only methods are safe to mark `readOnly`.

**`afterCommit` site in `BillofladingService:593`:** Remains unchanged. The write method that contains the `deferToCommit` call will have its own explicit `@Transactional` annotation after Stage 3, ensuring transaction synchronization is always active.

**Risk:** Medium. Requires full method-by-method audit of each Pattern A service. `BillofladingService` is ~1200 lines with 11 public methods; `CustomerorderBatchService` is the largest with 19 public methods. Stage 3 must be done per-service and each service PR reviewed before proceeding to the next.

### 3.4 Stage 4 — Disable OSIV

**Problem:** OSIV (`spring.jpa.open-in-view=true`, currently the default) masks missing transaction boundaries, causes N+1 queries to be invisible, holds a Hibernate session open for the entire HTTP request lifecycle, and blocks the v1→v2 migration path (v2 has OSIV disabled).

**Solution:** Add `spring.jpa.open-in-view=false` to `application.properties`. This causes Spring Boot to log a startup warning instead of printing the OSIV warning, and immediately throws `LazyInitializationException` for any lazy association accessed outside a transaction boundary.

**Gate:** Stage 4 MUST NOT proceed until Stages 1–3 are complete AND smoke-tested in QA against all major workflows (picking, replenishment, receiving, cycle count, BOL close). Any `LazyInitializationException` surfaced in QA indicates a missed write method or a lazy association that needs eager loading or an explicit transaction boundary.

**Risk:** High if attempted before Stages 1–3. Low after Stages 1–3.

---

## 4. File Change Summary

### Stage 1

| File | Change Type | Description |
|------|------------|-------------|
| `service/CustomerorderService.java` | Modify | Add `rollbackFor` to class-level `@Transactional` |
| `service/BillofladingService.java` | Modify | Add `rollbackFor` to class-level `@Transactional` |
| `service/TransferOrderService.java` | Modify | Add `rollbackFor` to class-level `@Transactional` |
| `service/CustomerorderBatchService.java` | Modify | Add `rollbackFor` to class-level `@Transactional` |
| `service/StockunitBusinessService.java` | Modify | Add `rollbackFor` to bare method annotations at :123 and :330 |
| `service/UnitloadBusinessService.java` | Modify | Add `rollbackFor` to bare method annotations at :76, :148, :277 |
| `service/PickingorderBusinessService.java` | Modify | Add `rollbackFor` to bare method annotation at :222 |
| `service/StockunitService.java` | Modify | Add `rollbackFor` to bare method annotation at :106 |
| `service/mobile/MobileReplenishService.java` | Modify | Add `rollbackFor` to bare method annotations at :388 and :732 |
| `service/mobile/MobileMoveUnitloadService.java` | Modify | Add `rollbackFor` to bare method annotation at :182 |

### Stage 2

| File | Change Type | Description |
|------|------------|-------------|
| `service/FixLocationAssignmentService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/ReceivingService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/mobile/MobileCycleCountService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/StockrecordService.java` | Modify | Add `@Transactional(rollbackFor=...)` — audit whether any need `REQUIRES_NEW` |
| `service/CyclecountService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/mobile/MobileTruckLoadingService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/ReplenishmentOrderMaintenanceService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/ReplenishGeneratorService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/mobile/MobilePalletizingService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |
| `service/ManageOrderService.java` | Modify | Add `@Transactional(rollbackFor=...)` after confirming all callers |
| `service/LosSyspropService.java` | Modify | Add `@Transactional(rollbackFor=...)` to write methods |

### Stage 3

| File | Change Type | Description |
|------|------------|-------------|
| `service/CustomerorderService.java` | Modify | Remove class-level; add method-level write + readOnly read annotations |
| `service/BillofladingService.java` | Modify | Remove class-level; add method-level write + readOnly read annotations |
| `service/TransferOrderService.java` | Modify | Remove class-level; add method-level write + readOnly read annotations |
| `service/CustomerorderBatchService.java` | Modify | Remove class-level; add method-level write + readOnly read annotations |
| `service/AdviceService.java` | Modify | Convert class-level to method-level (annotation already correct) |

### Stage 4

| File | Change Type | Description |
|------|------------|-------------|
| `src/main/resources/application.properties` | Modify | Add `spring.jpa.open-in-view=false` |

---

## 5. Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema changes; no Flyway migration needed | N/A | Pure Java annotation change |
| 2 | **Feature flags / system properties** | None required | N/A | No toggle needed |
| 3 | **Config / env changes** | Stage 4 only: `spring.jpa.open-in-view=false` in `application.properties` | Dev | Must be staged behind Stage 1–3 completion |
| 4 | **Deploy-order dependencies** | None — wms-api is the only service modified | N/A | No cross-service deploy ordering |
| 5 | **Data migration** | None — no DB schema or data changes | N/A | |
| 6 | **External systems** | None — no OMS/printer/Keycloak changes | N/A | OMS notification paths are not modified, only the TX boundary around them |
| 7 | **Access / permissions** | None | N/A | |
| 8 | **Monitoring / alerts** | After Stage 4: watch application logs for `LazyInitializationException` in QA for 48 hours before promoting to production | Dev | Log alert on `LazyInitializationException` in application logs |

### 5.2 Implementation Checklist

#### Stage 1 — Fix `rollbackFor` (target: 1–2 days, one PR)

- [ ] `CustomerorderService.java:28` → add `rollbackFor = {BusinessException.class, FacadeException.class}`
- [ ] `BillofladingService.java:29` → add `rollbackFor = {BusinessException.class, FacadeException.class}`
- [ ] `TransferOrderService.java:20` → add `rollbackFor = {BusinessException.class, FacadeException.class}`
- [ ] `CustomerorderBatchService.java:31` → add `rollbackFor = {BusinessException.class, FacadeException.class}`
- [ ] `StockunitBusinessService.java:123` → add `rollbackFor`
- [ ] `StockunitBusinessService.java:330` → add `rollbackFor`
- [ ] `UnitloadBusinessService.java:76` → add `rollbackFor`
- [ ] `UnitloadBusinessService.java:148` → add `rollbackFor`
- [ ] `UnitloadBusinessService.java:277` → add `rollbackFor`
- [ ] `PickingorderBusinessService.java:222` → add `rollbackFor`
- [ ] `StockunitService.java:106` → add `rollbackFor`
- [ ] `mobile/MobileReplenishService.java:388` → add `rollbackFor`
- [ ] `mobile/MobileReplenishService.java:732` → add `rollbackFor`
- [ ] `mobile/MobileMoveUnitloadService.java:182` → add `rollbackFor`
- [ ] Run `bash sbdocs/9-System/scripts/verify-260427-uniform-transactional-strategy.sh` — all Stage 1 checks must PASS
- [ ] `mvn test` — full test suite must pass

#### Stage 2 — Annotate phantom-TX services (target: 2–3 weeks, one PR per service group)

Priority order within Stage 2:

- [ ] **Group A (high-risk, high-write-count):** `FixLocationAssignmentService` (9 writes), `ReceivingService` (6 writes), `MobileCycleCountService` (6 writes), `StockrecordService` (6 writes — audit callers for REQUIRES_NEW need first)
- [ ] **Group B (medium-risk):** `CyclecountService` (4 writes), `MobileTruckLoadingService` (4 writes), `ReplenishmentOrderMaintenanceService` (4 writes)
- [ ] **Group C (lower-risk):** `ReplenishGeneratorService` (2 writes), `MobilePalletizingService` (2 writes), `LosSyspropService` (3 writes)
- [ ] **Group D (OMS gateway, 1 write, confirm callers first):** `ManageOrderService`
- [ ] For each service: grep for all `.save`/`.delete` calls, confirm method boundaries, add annotation
- [ ] Run `bash sbdocs/9-System/scripts/verify-260427-uniform-transactional-strategy.sh` — all Stage 2 checks must PASS
- [ ] `mvn test` after each group

#### Stage 3 — Class-level to method-level (target: 2–3 weeks, one PR per service)

- [ ] `CustomerorderService` — enumerate all 8 public methods; classify write vs read; apply annotations; remove class-level
- [ ] `BillofladingService` — enumerate all 11 public methods; apply; remove class-level (preserve `deferToCommit` in write method that calls it)
- [ ] `TransferOrderService` — enumerate all 9 public methods; apply; remove class-level
- [ ] `CustomerorderBatchService` — enumerate all 19 public methods; apply; remove class-level (`:560` `runClubLine` already has method-level override — do not duplicate)
- [ ] `AdviceService` — same approach; already has correct `rollbackFor`
- [ ] Run `bash sbdocs/9-System/scripts/verify-260427-uniform-transactional-strategy.sh` — all Stage 3 checks must PASS
- [ ] `mvn test` after each service

#### Stage 4 — Disable OSIV (target: after Stage 1–3 complete + QA verified)

- [ ] Add `spring.jpa.open-in-view=false` to `application.properties`
- [ ] Deploy to QA
- [ ] Run full manual smoke test (all major workflows — see §7 Manual Test Plan)
- [ ] Monitor QA logs for 48 hours — zero `LazyInitializationException`
- [ ] Run `bash sbdocs/9-System/scripts/verify-260427-uniform-transactional-strategy.sh` — all Stage 4 checks must PASS
- [ ] `mvn verify` (full suite including Testcontainers)

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|--------|--------|-------|--------|
| Rollback on `BusinessException` | Transaction **commits** (silent data corruption) | Transaction **rolls back** | Breaking for callers that assumed commit-on-checked-exception — but those callers relied on a bug |
| OSIV (Stage 4) | `true` — session open for full HTTP request | `false` — session closed at end of TX | `LazyInitializationException` for any lazy association accessed outside TX; these must be fixed |
| Read methods under class-level `@Transactional` (Stage 3) | Open read-write TX | `readOnly = true` TX | Read-only optimisation: Hibernate skips dirty-check; DB uses read-only mode; no functional change |
| `REQUIRES_NEW` sites | Unchanged | Unchanged | No impact |
| API contracts, response shapes | No change | No change | None |
| Frontend (wms-web-ui, wms-mobile-ui) | No change | No change | None |
| Database schema | No change | No change | None |

### What Does NOT Change

- All API endpoints, HTTP contracts, and response schemas.
- All `REQUIRES_NEW` isolation boundaries (11 sites — see §0 RN1–RN11).
- Sequence number generation behavior.
- OMS notification delivery mechanism — only the transaction context that wraps it.
- `MessageService.createMessageInNewTransaction` — already correct.
- Any v2/wms2-api code — this plan is v1 only.

---

## 7. Testing Strategy

### Unit tests (new / updated)

| Test class | What it asserts | Phase |
|------------|-----------------|-------|
| `CustomerorderServiceTest` | `cancelOrder` throws `BusinessException` → verify no repository `.save()` call committed; assert rollback | Stage 1 |
| `BillofladingServiceTest` | `closeBOL` throws `BusinessException` mid-phase → verify partial state not committed | Stage 1 |
| `TransferOrderServiceTest` | Write method throws `BusinessException` → rollback confirmed | Stage 1 |
| `FixLocationAssignmentServiceTest` | Write method completes → `.save()` committed; throws → `.save()` rolled back | Stage 2 |
| `StockrecordServiceTest` | Confirm `REQUIRED` vs `REQUIRES_NEW` decision for audit writes | Stage 2 |

### Integration tests (Testcontainers)

| Scenario | Class | Phase |
|----------|-------|-------|
| `closeBOL` mid-phase `BusinessException` → DB state unchanged | `BillofladingServiceIntegrationTest` | Stage 1 |
| `cancelOrder` with `BusinessException` → no partial customerorder state | `CustomerorderServiceIntegrationTest` | Stage 1 |
| `FixLocationAssignmentService` write under TX → committed; write outside TX (OSIV off) → `TransactionRequiredException` | `FixLocationAssignmentServiceIntegrationTest` | Stage 2 |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|----------|------------|-------|-----------------|-----------|
| BOL close — happy path | Staging | Close a BOL with valid picking orders | BOL status = CLOSED, all positions confirmed, OMS notified | |
| BOL close — mid-phase error (inject bad data) | Staging | Attempt to close BOL with one position in invalid state | Error returned; BOL status unchanged; no partial DB state | |
| Customer order cancel | Staging | Cancel an in-progress order | Order status = CANCELLED; stock reservations released | |
| runClubLine — success | Staging | Trigger club-line batch run | Picking orders created; OMS batch notification sent | |
| runClubLine — with error | Staging | Trigger run with one invalid order | Batch rolls back for that order; other orders unaffected; no silent commit | |
| Mobile picking — confirm pick | Staging (mobile device) | Confirm pick via mobile UI | Stock deducted; picking order updated; OMS notified | |
| Mobile replenish — complete | Staging (mobile device) | Complete replenishment via mobile | Replenish order closed; stock moved | |
| Cycle count | Staging | Run cycle count via web UI | Count submitted; stock adjusted | |
| Receiving | Staging | Receive goods | GR position created; stock unit created | |
| Stage 4 smoke: OSIV off | QA after Stage 4 | All above workflows repeated with `spring.jpa.open-in-view=false` | Zero `LazyInitializationException` in logs; all workflows succeed | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| `HttpRestService` annotation test | No DB writes; excluded from this plan entirely |
| `ReplenishOrderJobService` `REQUIRES_NEW` tests | Already covered by existing job-service tests; not modified by this plan |

---

## 8. Rollout Plan

| Stage | Branch | Merge target | Release tag |
|-------|--------|-------------|-------------|
| Stage 1 | `feature/tx-rollbackfor-fix` | `develop` | `dev-tx-s1` |
| Stage 2-A (high risk) | `feature/tx-phantom-group-a` | `develop` | `dev-tx-s2a` |
| Stage 2-B/C/D | `feature/tx-phantom-group-bcd` | `develop` | `dev-tx-s2bcd` |
| Stage 3 (per service) | `feature/tx-method-level-{service}` | `develop` | Per service |
| Stage 4 | `feature/tx-disable-osiv` | `develop` → `main` | `qa-tx-osiv` then `v-tx-final` |

**Stage 1 must ship independently** — it is a safety fix and should not be bundled with Stages 2–4.

---

## 9. Alternatives Considered

| Option | Description | Why rejected |
|--------|-------------|-------------|
| **A — Class-level `@Transactional(rollbackFor=Exception.class)` everywhere** | Apply class-level to every service; simplest migration | Every read method opens a full read-write TX; new methods silently become transactional; no `readOnly` optimisation; does not reduce OSIV dependency; over-broad for services always called inside REQUIRES_NEW |
| **B — Method-level on writes + `readOnly=true` on reads (chosen)** | Explicit per-method annotation; `readOnly` on reads; no class-level | More annotations to maintain; requires full method audit of Pattern A services |
| **C — Class-level with `readOnly=true` method overrides (AdviceService pattern)** | Class-level annotation as safe default; override reads to `readOnly=true` | Same "new method silently transactional" risk as Option A; two annotation layers harder to audit; does not reduce OSIV dependency |
| **D — Do nothing (extend ADR-004 acceptance)** | Accept the mixed strategy indefinitely | The ADR-004 "Do NOT revisit unless" trigger has been met — production data integrity failures are traced to missing `rollbackFor`; continuing is not an option |
| **E — Full rewrite as v2 migration** | Port all affected v1 services to v2/wms2-api instead of fixing v1 | v1 is still the production system; v2 migration is a separate multi-quarter effort; production incidents cannot wait |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Status |
|---|----------|--------|
| 1 | Should `StockrecordService` write methods use `REQUIRED` (default) or `REQUIRES_NEW`? Audit records should ideally survive outer TX rollback. | **Open** — audit callers before Stage 2 Group A implementation |
| 2 | `ManageOrderService` (1 write): is it always called from within an existing transaction? | **Open** — confirm caller set before Stage 2 Group D implementation |
| 3 | v2 applicability: does `wms2-api` have the same pattern? | **Resolved** — v2 already has OSIV disabled and uses method-level annotations. However, v2 may have its own phantom-TX or rollbackFor gaps inherited from v1 ports. A separate `wms-v2-migrate` plan should audit v2 against this plan's findings. |
| 4 | Should `rollbackFor = Exception.class` be used instead of `{BusinessException.class, FacadeException.class}`? | **Resolved** — use `{BusinessException.class, FacadeException.class}` for consistency with existing correct patterns. `Exception.class` is also safe; choose it if a service throws other checked exception types. |
| 5 | Which Pattern B services have read methods that currently run under no TX and should get `readOnly=true` in Stage 3? | **Open** — enumerate per service during Stage 3 implementation |

---

## 9.1 Acceptance Script

Verify script: `sbdocs/9-System/scripts/verify-260427-uniform-transactional-strategy.sh`

Run after every stage:
```bash
bash sbdocs/9-System/scripts/verify-260427-uniform-transactional-strategy.sh
```

The implementing agent's end-of-task report **must** paste the line:
```
Result: N pass, 0 fail, M skip
```

A "DONE" claim with any FAIL lines is not accepted.

---

## 9.2 Recommended OMC Composition

| Aspect | Value | Rationale |
|--------|-------|-----------|
| **Size class** | Large | 4 stages, 30+ files, cross-service, phased rollout |
| **Pre-draft step** | Complete (this session) | Analysis and advisory already done |
| **Plan-review step** | `critic` | Standard for Large; catches gaps in §0 enumeration before coding starts |
| **Implementation shape** | `ralph` | Loops: implement cluster → run verify-script → fix FAILs → repeat until 0 fail. Exit condition = `Result: N pass, 0 fail` from verify script. Stage 1 can use `executor` alone (mechanical change, 14 files). |
| **Verification step** | verify-script + `verifier` | Mandatory at end of every stage |
| **Code-review step** | `code-reviewer` | Mandatory before merging Stage 3 (class-level conversion is nuanced) |
| **Commit step** | `git-master` | Multiple logical commits; trailers document the rollbackFor rationale |

**Stage 1 only:** `executor` is sufficient — mechanical annotation change, verify-script provides the exit gate.

**Stage 2–3:** Use `ralph` with verify-script as exit condition. One ralph loop per service group.

**Stage 4:** Manual deploy + QA monitoring; no agent needed.
