---
title: "SBDEV-2231 — OrderRestController.create partial-batch failure leaves orphaned DB records (no @Transactional)"
ticket: "SBDEV-2231"
ticket_url: "https://app.clickup.com/t/868jj32re"
type: "bug"
severity: "high"
priority: "high"
status: "implemented"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-14"
updated: "2026-05-14"
last_updated: "2026-05-14"
related:
  - "[[SBDEV-2222-rest-inbound-no-idempotency-contract]]"
  - "[[SBDEV-2230-rest-exception-handler-retryable-differentiation]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-end-to-end-request-journey]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - wmsv2
  - oms-integration
  - rest-contract
  - reliability
  - transaction-boundary
---

# SBDEV-2231 — OrderRestController.create partial-batch failure leaves orphaned DB records (no @Transactional)

**Ticket:** [SBDEV-2231](https://app.clickup.com/t/868jj32re)
**Project:** wms2-api | **Version:** v2 | **Type:** bug
**Priority:** High | **Severity:** HIGH (Tier 2)
**Status:** reviewed (2026-05-14) — RALPLAN-DR consensus complete; verify script ships alongside this plan; implementation pending.
**Date:** 2026-05-14

> **Framing:** `OrderRestController.create` (HTTP `PUT /rest/order/create`) accepts a list of order batches from OMS and saves them. The method has NO `@Transactional` annotation. Each `repository.save()` inside the save loop auto-commits in its own transaction. When any save in the middle of the loop fails — `DataAccessException`, `EntityNotFoundException`, or a wrapped `WebserviceBusinessExceptionClientSide` — the prior batches/orders/positions are already committed and visible in the database. OMS's view (failure response) and WMS's persisted state disagree.
>
> SBDEV-2222's idempotency filter does NOT save error responses, so OMS retries on failure. The retry then hits the duplicate-batch-id guard at line 162 (`ENTITY_ALREADY_EXITS`) because the orphaned `customerorder_batch` row from the original partial commit blocks it. The retry permanently fails with a 400 even though the original logical operation never succeeded.
>
> **Fix:** Extract the save loop into a new `OrderBatchCreationService.createAll()` annotated with `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`. Any exception propagates OUT of the `@Transactional` boundary BEFORE the controller's catch block runs → Spring's transaction interceptor rolls back the entire save phase. Validation phase stays in the controller (no DB writes, no atomicity concern). Both `WebserviceBusinessExceptionClientSide` and `BusinessException` are checked exceptions and MUST be listed explicitly.

---

## 1. Problem Statement

### 1.1 Symptom

OMS sends a 2-batch payload to `PUT /rest/order/create`. Validation passes. Batch 1 saves successfully (auto-commits). Batch 2's first position save fails with a `DataAccessException` (e.g. PgBouncer blip, constraint violation, query timeout).

| Step | What happens | DB state |
|---|---|---|
| 1 | Validation phase (lines 112–338) passes | unchanged |
| 2 | Batch 1's `customerorder_batch` row inserted (auto-commit) | +1 batch row |
| 3 | Batch 1's N `customerorder` rows inserted (each auto-commit) | +N order rows |
| 4 | Batch 1's M `customerorder_position` rows inserted (each auto-commit) | +M position rows |
| 5 | Batch 2's `customerorder_batch` row inserted (auto-commit) | +1 batch row |
| 6 | Batch 2's first `customerorder` row insert throws `DataAccessException` | (uncommitted) |
| 7 | Exception escapes the controller's narrow catch (which only catches `WebserviceBusinessExceptionClientSide`) | — |
| 8 | Spring default 500 (post-SBDEV-2230: 503 + retryable=true from `RestEndpointExceptionHandler.handleResourceFailure`) | — |
| 9 | OMS retries (SBDEV-2222 didn't cache the 5xx response) | — |
| 10 | Validation re-runs; batch 1 + batch 2 `batch_id` already exist in DB (orphaned from step 2 + step 5) → `ENTITY_ALREADY_EXITS` | retry returns 400 — terminal failure |

The user-visible result: OMS thinks the order create permanently failed, but WMS has committed half of batch 1 and an orphan `customerorder_batch` row for batch 2. Manual DB cleanup is required to allow OMS to retry.

### 1.2 Why the current narrow catch makes it worse

The controller's outer try/catch is `try { ... } catch (WebserviceBusinessExceptionClientSide e) { return 400; }`. This catches **only** the controller's own internal validation exception. Anything else (`DataAccessException`, `EntityNotFoundException`, `IllegalArgumentException` wrapped by `customerorderRepository.save` at line 440 only for `IllegalArgumentException` — NOT for `DataAccessException`) escapes to Spring's default error pipeline.

So today there are four distinct failure modes inside the save loop, and **all four** leave partial data:

| # | Exception type | Where it can be thrown | Today's controller behavior | Today's DB state |
|---|---|---|---|---|
| F1 | `DataAccessException` during batch save | `customerorderBatchRepository.save()` line 375 | wraps into `WebserviceBusinessExceptionClientSide` → 400 (caught) | prior batches in DB committed |
| F2 | `DataAccessException` during order save | `customerorderRepository.save()` line 440 | escapes (only wrapped for `IllegalArgumentException`) → 500 (or 503 post-SBDEV-2230) | prior batches + current-batch row in DB |
| F3 | `DataAccessException` during position save | `customerorderPositionRepository.save()` line 468 | escapes → 500 / 503 | prior batches + current batch + current orders in DB |
| F4 | `EntityNotFoundException` during client lookup | `clientRepository.findByClNr(...)` line 346/417/460 | escapes → 404 | prior batches + current batch in DB |

### 1.3 Why SBDEV-2222 (idempotency) doesn't save us

SBDEV-2222's `IdempotencyFilter` caches 2xx responses only. Error responses (4xx, 5xx) are not cached — by design, so that the caller can retry a transient failure with the same `Idempotency-Key`. But because the failed request **already wrote data**, the retry's validation phase trips on the orphaned `customerorder_batch.batch_id` and returns `ENTITY_ALREADY_EXITS` 400. Retry permanently fails.

The fix has to be at the **transaction boundary** layer, not the idempotency layer. The two are complementary: SBDEV-2222 makes retries safe at the dedup layer; this plan makes the underlying operation atomic so the data state matches the response state.

### 1.4 Why `@Transactional` on the controller method does NOT work

Three options were considered and only one preserves correctness:

- **Option A — Add `@Transactional` directly to `OrderRestController.create()`:** Technically the CGLIB proxy fires because Spring MVC dispatches via the proxy. But the controller's catch block at line 494 catches `WebserviceBusinessExceptionClientSide` and returns a `ResponseEntity.badRequest()` **without rethrowing**. Spring's `@Transactional` interceptor sees a normal return, not a thrown exception, and **commits** the transaction. Partial saves persist. To force rollback we'd have to call `TransactionAspectSupport.currentTransactionStatus().setRollbackOnly()` inside the catch block — fragile, easy to forget, and inverts the natural flow. **Rejected.**

- **Option B — Add a `saveBatches()` method to `CustomerorderBatchService`:** Avoids creating a new file. But `CustomerorderBatchService` is already a god-service with 20+ dependencies. The save loop needs `BasicService`, `ShipperidRepository`, `ShipperidService`, `MessageService`, `SyspropService`, `ClientRepository`, `CustomerorderRepository`, `CustomerorderPositionRepository` — adding any of these that aren't already there increases coupling on a service that already needs to be split. **Rejected.**

- **Option C — New `OrderBatchCreationService` with `@Transactional` on `createAll(...)`:** Dedicated service with exactly the dependencies the save loop needs. The `@Transactional` boundary is at the service entry point, so any exception thrown inside the loop propagates OUT through the proxy BEFORE the controller's catch block runs. Spring's transaction interceptor sees the propagating exception, rolls back, then the controller catches the propagated `WebserviceBusinessExceptionClientSide` and returns 400. Other exception types (`DataAccessException`, `EntityNotFoundException`) propagate to `RestEndpointExceptionHandler` (SBDEV-2230) with the correct status code and `retryable` signal. **Chosen.**

---

## 2. Root Cause Analysis

### 2.1 Affected file

`v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java`

### 2.2 Affected sites

| # | File:line | Construct | Same root-cause? | In-scope? |
|---|---|---|---|---|
| 1 | `controller/rest/OrderRestController.java:110-509` (`create()`) | Method has no `@Transactional`; runs validation + save in one HTTP handler thread; each `repository.save()` auto-commits | yes | yes |
| 2 | `controller/rest/OrderRestController.java:343-491` (save loop) | Iterates `orderBatchList`; per-iteration `customerorderBatchRepository.save` + nested loops over orders and positions; each save auto-commits | yes | yes |
| 3 | `controller/rest/OrderRestController.java:374-378` | Only `customerorderBatchRepository.save` wraps `DataAccessException` into `WebserviceBusinessExceptionClientSide`; order/position saves wrap only `IllegalArgumentException` | yes | yes |
| 4 | `controller/rest/OrderRestController.java:494-508` (catch block) | Catches only `WebserviceBusinessExceptionClientSide`; `DataAccessException` / `EntityNotFoundException` / other `RuntimeException` escape with partial DB state already committed | yes | yes |
| 5 | (new) `service/OrderBatchCreationService.java` | New `@Service` with `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})` on `createAll(...)` | yes — fix site | yes |

### 2.3 Why `rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class}` is required

`WebserviceBusinessExceptionClientSide extends Exception` (checked exception — verified by reading the class). Spring's `@Transactional` default rollback rule rolls back on `RuntimeException` and `Error` only. Checked exceptions are NOT rolled back unless explicitly listed. So we list it.

`BusinessException extends Exception` (checked — verified at `exceptions/BusinessException.java:14`). `BasicService.generateNumber(...)` is called inside the save loop (line 345) and declares `throws BusinessException`. It throws `BusinessException("BusinessException.SequenceInvalid", ...)` on negative sequence (line 50) and `BusinessException("BusinessException.SequenceExhausted", ...)` after 5 retries (line 170). If `BusinessException` propagates out of `createAll(...)` without being listed in `rollbackFor`, Spring commits the transaction — prior batch/order saves persist. This is a realistic failure mode (sequence exhaustion under load), not a corner case. **`BusinessException.class` MUST be in `rollbackFor`.**

`EntityNotFoundException` and `DataAccessException` both extend `RuntimeException` (Jakarta and Spring respectively) — they are auto-rolled back without needing explicit listing. `IllegalArgumentException` also extends `RuntimeException` — auto-rolled back.

### 2.4 Why the validation phase (lines 112–338) stays in the controller

The validation phase does only reads. It builds:
- `errors: Map<String, String>` — collected validation errors
- `clientMap: Map<String, Client>` — client lookups
- `boxTypeMap: Map<String, Boxtype>` — box type lookups
- `clientItemDataMap: Map<String, Map<String, Itemdata>>` — item data lookups

No writes. No atomicity concern. Moving it would (a) bloat the new service unnecessarily, (b) expand the transaction scope to include reads that don't need to be transactional, and (c) make the diff larger than the fix requires. **Stays in the controller.**

### 2.5 Self-invocation proxy edge case (NOT a concern here)

A common `@Transactional` pitfall is self-invocation: method `A` (with `@Transactional`) calls method `B` on the same class — `B` runs on `this`, not the proxy, so its `@Transactional` is bypassed. **This plan does NOT trigger that pitfall** because the controller calls into a **different bean** (`OrderBatchCreationService`), so the proxy chain is intact. Spring's transaction interceptor wraps `createAll(...)` correctly.

---

## 3. Design / Proposed Fix

### 3.1 New `OrderBatchCreationService`

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/OrderBatchCreationService.java`

```java
package net.aim_ai.wms.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import net.aim_ai.wms.constants.WmsConstants;
import net.aim_ai.wms.dto.OrderBatchDto;
import net.aim_ai.wms.entities.Boxtype;
import net.aim_ai.wms.entities.Client;
import net.aim_ai.wms.entities.Customerorder;
import net.aim_ai.wms.entities.CustomerorderBatch;
import net.aim_ai.wms.entities.CustomerorderPosition;
import net.aim_ai.wms.entities.Itemdata;
import net.aim_ai.wms.entities.Shipperid;
import net.aim_ai.wms.exceptions.WebserviceBusinessExceptionClientSide;
import net.aim_ai.wms.repositories.ClientRepository;
import net.aim_ai.wms.repositories.CustomerorderBatchRepository;
import net.aim_ai.wms.repositories.CustomerorderPositionRepository;
import net.aim_ai.wms.repositories.CustomerorderRepository;
import net.aim_ai.wms.repositories.ShipperidRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import net.aim_ai.wms.exceptions.EntityNotFoundException;
import java.io.IOException;
import java.util.List;
import java.util.Map;

/**
 * Atomic save service for OrderRestController.create.
 *
 * Wraps the entire batch-create save loop in a single tenant-scoped
 * transaction so a partial failure rolls back ALL prior saves in the
 * same request. Without this boundary, individual repository.save()
 * calls auto-commit and a mid-loop failure leaves orphaned rows that
 * block OMS retries (the orphan trips the duplicate-batch-id guard
 * in OrderRestController validation).
 *
 * @Transactional rollback rules:
 *   - rollbackFor = WebserviceBusinessExceptionClientSide.class
 *       (checked exception; Spring would NOT roll back by default)
 *   - rollbackFor = BusinessException.class
 *       (checked exception; thrown by basicService.generateNumber() on
 *       SequenceInvalid/SequenceExhausted — confirmed at BasicService.java:50,170)
 *   - DataAccessException, EntityNotFoundException, RuntimeException
 *       are auto-rolled back (extend RuntimeException)
 *
 * Multi-tenancy: value = "tenantTransactionManager" so the boundary
 * binds to the per-request tenant DataSource (CLAUDE.md mandates this
 * for every tenant-scoped @Transactional in v2).
 */
@Service
public class OrderBatchCreationService {

    private static final Logger LOG = LoggerFactory.getLogger(OrderBatchCreationService.class);

    private final CustomerorderBatchRepository customerorderBatchRepository;
    private final CustomerorderRepository customerorderRepository;
    private final CustomerorderPositionRepository customerorderPositionRepository;
    private final ClientRepository clientRepository;
    private final BasicService basicService;
    private final ShipperidRepository shipperidRepository;
    private final ShipperidService shipperidService;
    private final MessageService messageService;
    private final SyspropService syspropService;

    public OrderBatchCreationService(
            CustomerorderBatchRepository customerorderBatchRepository,
            CustomerorderRepository customerorderRepository,
            CustomerorderPositionRepository customerorderPositionRepository,
            ClientRepository clientRepository,
            BasicService basicService,
            ShipperidRepository shipperidRepository,
            ShipperidService shipperidService,
            MessageService messageService,
            SyspropService syspropService) {
        this.customerorderBatchRepository = customerorderBatchRepository;
        this.customerorderRepository = customerorderRepository;
        this.customerorderPositionRepository = customerorderPositionRepository;
        this.clientRepository = clientRepository;
        this.basicService = basicService;
        this.shipperidRepository = shipperidRepository;
        this.shipperidService = shipperidService;
        this.messageService = messageService;
        this.syspropService = syspropService;
    }

    /**
     * Persist all batches / orders / positions atomically. Any exception
     * propagates to the caller and triggers a full rollback of the
     * tenant transaction.
     *
     * @param orderBatchList         validated DTOs (validation already
     *                               completed in OrderRestController)
     * @param clientMap              cl_nr -> Client (resolved in validation)
     * @param boxTypeMap             box type name -> Boxtype (resolved in validation)
     * @param clientItemDataMap      cl_nr -> (item id -> Itemdata)
     * @throws WebserviceBusinessExceptionClientSide on a per-row DAO failure
     *         translated to a 400-shaped error map (kept for back-compat with
     *         OMS's existing 400 parsing)
     */
    @Transactional(
            value = "tenantTransactionManager",
            rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})
    public void createAll(
            List<OrderBatchDto> orderBatchList,
            Map<String, Client> clientMap,
            Map<String, Boxtype> boxTypeMap,
            Map<String, Map<String, Itemdata>> clientItemDataMap)
            throws WebserviceBusinessExceptionClientSide {

        List<Shipperid> shipperIDList = (List<Shipperid>) shipperidRepository.findAll();

        for (OrderBatchDto orderBatch : orderBatchList) {
            // ... save loop verbatim from OrderRestController lines 343-491:
            //   - resolve client, generate batch number via basicService
            //   - customerorderBatchRepository.save(...) [DataAccessException → WebserviceBusinessExceptionClientSide]
            //   - inner loop: customerorderRepository.save(...) per order
            //   - inner loop: customerorderPositionRepository.save(...) per position
            //   - shipper resolution / shipperidService.createShipperID(...) as needed
            //   - per-batch SUCCESS messageService.createMessage(...) at end
            //
            // NOTE: the per-batch SUCCESS message log stays here. It is
            // intentionally inside the transaction — if the transaction
            // rolls back later, the success log also rolls back, which is
            // correct: we don't want a success log for a rolled-back batch.
            //
            // The FAILURE message log (today line ~502 in OrderRestController)
            // does NOT live here. It is moved to the controller's catch block
            // so it persists even after this transaction rolls back.
        }
    }
}
```

### 3.2 Restructure `OrderRestController.create`

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java`

Inject `OrderBatchCreationService` via constructor. Restructure the method into two phases.

```java
@PutMapping(value = "/create", consumes = MediaType.APPLICATION_JSON_VALUE,
            produces = MediaType.APPLICATION_JSON_VALUE)
public ResponseEntity<Object> create(@RequestBody List<OrderBatchDto> orderBatchList)
        throws BusinessException {

    // ===== Phase 1: validation (unchanged — lines 112-338 stay here) =====
    Map<String, String> errors = new HashMap<>();
    Map<String, Client> clientMap = new HashMap<>();
    Map<String, Boxtype> boxTypeMap = new HashMap<>();
    Map<String, Set<String>> clientItemDataIdentifierMap = new HashMap<>();
    // ... existing validation (duplicate batch_id check at line 162,
    //     order_nr collisions, position quantity sanity, etc.) ...
    Map<String, Map<String, Itemdata>> clientItemDataMap =
            resolveItemData(clientItemDataIdentifierMap);

    if (!errors.isEmpty()) {
        // existing 400 path on validation failure — unchanged
        return ResponseEntity.badRequest().body(errors);
    }

    // ===== Phase 2: atomic save (delegated to transactional service) =====
    try {
        orderBatchCreationService.createAll(
                orderBatchList, clientMap, boxTypeMap, clientItemDataMap);
    } catch (WebserviceBusinessExceptionClientSide e) {
        // Failure message log — runs AFTER the service transaction has
        // already rolled back. Must be outside the rolled-back tx so the
        // log entry persists.
        try {
            messageService.createMessage(
                    syspropService.getOmsInstanceName(),
                    syspropService.getWmsInstanceName(),
                    new ObjectMapper().writeValueAsString(orderBatchList),
                    WmsConstants.MessageProcessType.ORDER_BATCH_IMPORT,
                    "N/A",
                    WmsConstants.MessageStatus.FAILED,
                    Integer.toString(HttpStatus.BAD_REQUEST.value()),
                    null);
        } catch (IOException ie) {
            LOG.error("Order create import service log failed", ie);
        }
        return ResponseEntity.badRequest().body(e.getErrorMap());
    }
    // DataAccessException, EntityNotFoundException, RuntimeException
    // propagate to RestEndpointExceptionHandler (SBDEV-2230):
    //   - DataAccessResourceFailureException, CannotAcquireLockException,
    //     DeadlockLoserDataAccessException, RecoverableDataAccessException,
    //     QueryTimeoutException → 503 + Retry-After + retryable=true
    //   - EntityNotFoundException → 404 + retryable=false
    //   - other RuntimeException → 500 + retryable=false
    // In every case the transaction has already rolled back; the DB is clean.

    return ResponseEntity.status(HttpStatus.NO_CONTENT)
            .body(Collections.singletonMap("status", "success"));
}
```

### 3.3 Per-failure-mode behavior matrix

| Failure mode | Before this fix | After this fix |
|---|---|---|
| F1 `DataAccessException` during batch save | wrapped to `WebserviceBusinessExceptionClientSide` → 400; prior batches committed | wrapped → propagates out of service tx → rollback → controller catches → 400; **no orphans** |
| F2 `DataAccessException` during order save | escapes (only `IllegalArgumentException` wrapped) → 500 / 503; prior data committed | propagates out of service tx → rollback → `RestEndpointExceptionHandler` returns 503 + retryable=true (SBDEV-2230); **no orphans** |
| F3 `DataAccessException` during position save | escapes → 500 / 503; prior data committed | propagates → rollback → 503 + retryable=true; **no orphans** |
| F4 `EntityNotFoundException` during client lookup | escapes → 404; prior data committed | propagates → rollback → 404 + retryable=false (SBDEV-2230); **no orphans** |
| F5 `BusinessException` from `basicService.generateNumber()` | escapes → 500; prior data committed (`BusinessException` is checked, NOT auto-rolled back) | included in `rollbackFor` → rollback → controller rethrows → `RestExceptionHandler.handleBusinessException` → 422 + retryable=false. Routing note: `RestEndpointExceptionHandler` (`@Order(HIGHEST_PRECEDENCE)`) does NOT have a `@ExceptionHandler(BusinessException.class)` — only an `Exception.class` catch-all. `RestExceptionHandler` has an exact-depth match for `BusinessException`. Spring's `ExceptionDepthComparator` picks the exact-depth match regardless of advisor `@Order`, so the global handler wins. |
| Happy path | 204; data persisted | 204; data persisted (single tenant transaction) |
| Validation failure (Phase 1) | 400 with error map | 400 with error map (unchanged — Phase 1 has no DB writes) |

### 3.4 Message log behavior — `MessageService.createMessage` uses `REQUIRES_NEW`

**Critical finding (Architect review):** `MessageService.createServiceLog` at `service/MessageService.java:67-68` is annotated `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`. The public `createMessage(...)` overloads are thin pass-throughs that delegate to `createServiceLog(...)` as a cross-bean call — the CGLIB proxy fires and `REQUIRES_NEW` starts an independent transaction. **Each `messageService.createMessage(...)` call commits independently of the caller's transaction, regardless of whether the caller's transaction later rolls back.**

Consequence for this plan:
- **Per-batch success log** (inside `OrderBatchCreationService.createAll(...)`, called once per batch in the loop) — commits independently via `REQUIRES_NEW`. On mid-loop rollback, the success log rows for already-processed batches **persist** even though the batch/order/position rows are rolled back.
- **Failure log** (in the controller catch block, outside the tx) — commits normally via its own `REQUIRES_NEW` tx.

The plan's original §11 claim ("success logs roll back with data") is **false**. The corrected operational semantics are documented in §11.

**Implementation consequence:** No change to code placement is needed. The success log can stay inside `createAll(...)` (it commits independently via `REQUIRES_NEW`). The failure log stays in the controller catch block. Operators must read the message log as recording *intent per batch* (each batch's SUCCESS log row fires at the point the batch save succeeded), not *final outcome of the whole request*. The FAILED row is the canonical failure marker — it always appears in the catch path. See §11 operational note.

### 3.5 `shipperidService.createShipperID(...)` propagation — resolved

**Finding (Architect review):** `ShipperidService.createShipperID` at `service/ShipperidService.java:42` has **NO `@Transactional` annotation**. It runs under whatever transaction the caller provides. When called from `OrderBatchCreationService.createAll(...)` (which owns a `tenantTransactionManager` transaction), `createShipperID` joins that transaction via default `REQUIRED` propagation. Shipper inserts roll back with the rest of the batch data if the outer transaction rolls back. **No orphaned shipper rows.** Open Question 1 is resolved — no action needed at implementation time.

### Files changed

- **New:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/OrderBatchCreationService.java`
- **Modified:** `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java` (extract save loop; inject service; restructure try/catch)
- **New:** `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/OrderBatchCreationServiceUnitTest.java`
- **Modified:** `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/controller/rest/OrderRestControllerUnitTest.java` (delegation tests; no-regression on existing tests)

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `OrderRestController.create` shape | Similar shape exists in v1 | v2 (target of this plan) | Sister v1 plan TBD if v1 has the same gap |
| Multi-tenant transaction manager | `tenantTransactionManager` exists in v1 too | Same | Same fix shape would work |
| SBDEV-2230 dependency | v1 has a separate exception-handler plan | Already merged in v2 | The 503/retryable signal is v2-specific via SBDEV-2230 |

### What Needs Porting

1. Same conceptual change: extract the save loop into a `@Transactional` service method; restructure the controller catch block. The v1 port uses `javax.*` namespace and the v1 project-internal `EntityNotFoundException` (if it has one — check before porting).

### What Does NOT Need Porting

- The `RestEndpointExceptionHandler` interaction (SBDEV-2230) is v2-specific. v1's exception-handler ladder is different — the v1 port should target whatever the v1 plan for SBDEV-2230's sister ticket lands on.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | N/A — no schema change | — | Pure service-layer refactor |
| 2 | **Feature flags / system properties** | N/A — no kill-switch | — | Behavior is strictly safer post-deploy; worst case is "503 instead of partial 500" which is what we want |
| 3 | **Config / env changes** | N/A | — | No new config keys, no Hikari/PgBouncer tuning needed |
| 4 | **Deploy-order dependencies** | SBDEV-2230 (`RestEndpointExceptionHandler`) MUST be deployed first or together; SBDEV-2222 (`IdempotencyFilter`) MUST already be deployed | Nam Park | SBDEV-2230 maps `DataAccessException` / `EntityNotFoundException` escaping the new service to 503/404 with `retryable` signal. SBDEV-2222 status=implemented as of 2026-05-12. SBDEV-2230 status=implemented as of 2026-05-14. |
| 5 | **Data migration** | N/A | — | — |
| 6 | **External systems** | None | — | OMS contract is unchanged: same status codes for happy path (204) and validation failure (400). Transient/permanent error codes change from "500 default" to "503 / 404 / 500 with retryable" — already part of the SBDEV-2230 contract. |
| 7 | **Access / permissions** | N/A | — | — |
| 8 | **Monitoring / alerts** | Existing Micrometer `http.server.requests` panel for `/rest/order/create` is sufficient. Optional: add a Grafana panel that diffs `2xx + 4xx` count vs `customerorder_batch` insertion rate to detect any regression where the tx rolls back successful-looking saves. | Nam Park | Optional. |

### 5.2 Implementation Checklist

- [ ] Create `OrderBatchCreationService.java` — new `@Service`; constructor-inject 9 dependencies; method `createAll(List<OrderBatchDto>, Map<String,Client>, Map<String,Boxtype>, Map<String,Map<String,Itemdata>>)` annotated with `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`.
- [ ] Extract the save loop body from `OrderRestController.create` lines 343–491 verbatim into `createAll(...)`. Preserve per-batch success message logging inside the tx.
- [ ] Modify `OrderRestController` — constructor-inject `OrderBatchCreationService`. Remove the save-loop body. Replace with `orderBatchCreationService.createAll(orderBatchList, clientMap, boxTypeMap, clientItemDataMap);` inside the existing try block.
- [ ] Ensure the failure message log (`messageService.createMessage(..., MessageStatus.FAILED, ...)` at controller lines 494-507) remains in the controller's `catch (WebserviceBusinessExceptionClientSide e)` block. Do NOT move it into `OrderBatchCreationService.createAll(...)`. The existing catch block already has this log — keep it there and ensure no copy ends up inside the service.
- [x] ~~Confirm `ShipperidService.createShipperID` propagation~~ — **Resolved** (no `@Transactional`, joins caller tx, no orphans).
- [ ] Create `OrderBatchCreationServiceUnitTest` — mock all 9 dependencies; assert exception propagation (DataAccessException, EntityNotFoundException, IllegalArgumentException, WebserviceBusinessExceptionClientSide) and happy-path save count.
- [ ] Modify `OrderRestControllerUnitTest` — add delegation tests (Phase 1 passes → service called once; service throws `WebserviceBusinessExceptionClientSide` → 400 with error map; service throws `DataAccessException` → escapes the controller catch). Keep all existing tests green.
- [ ] Run `mvn test -Dtest=OrderBatchCreationServiceUnitTest` — must pass.
- [ ] Run `mvn test -Dtest=OrderRestControllerUnitTest` — must pass.
- [ ] Run `mvn test` (full suite) — must pass with no regressions.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2231-order-rest-create-partial-batch-atomicity.sh` — must exit 0.
- [ ] Code review.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Happy path 2-batch create | `OrderRestController.create` with valid 2-batch payload; mock service `createAll` to succeed | 204 No Content; `orderBatchCreationService.createAll` invoked exactly once |
| Service throws `WebserviceBusinessExceptionClientSide` | Mock `createAll` to throw | 400 with error map body; failure message log invoked once with `MessageStatus.FAILED` |
| Service throws `DataAccessException` (any subclass) | Mock `createAll` to throw `DataAccessResourceFailureException` | Exception escapes the controller catch and reaches `RestEndpointExceptionHandler` → 503 + Retry-After + retryable=true (verified by MockMvc with both advices wired) |
| Service throws `EntityNotFoundException` | Mock `createAll` to throw | Exception escapes → 404 + retryable=false (SBDEV-2230 H.7) |
| Validation failure in Phase 1 (no DB write) | Send payload with duplicate batch_id | 400 with error map; `createAll` NEVER invoked |
| `OrderBatchCreationService.createAll` happy path | Stub all 4 repos to succeed; invoke `createAll` | `customerorderBatchRepository.save` called N times; `customerorderRepository.save` called M times; `customerorderPositionRepository.save` called K times; no exception |
| `OrderBatchCreationService.createAll` — `DataAccessException` mid-batch | Stub `customerorderBatchRepository.save` to throw on 2nd call | `WebserviceBusinessExceptionClientSide` propagates out (per existing wrap at line 375); `@Transactional` rollback signal fires (asserted via TestTransaction or by verifying exception escapes service) |
| `OrderBatchCreationService.createAll` — `DataAccessException` during order save | Stub `customerorderRepository.save` to throw `DataAccessResourceFailureException` | Exception propagates unwrapped (order save does NOT wrap DataAccessException today); rollback signal fires |
| `OrderBatchCreationService.createAll` — `EntityNotFoundException` during client lookup | Stub `clientRepository.findByClNr` to return `Optional.empty()` | `EntityNotFoundException` thrown by `.orElseThrow(...)`; rollback signal fires |
| `OrderBatchCreationService.createAll` rollback verification | Use Testcontainers Postgres integration test; insert batch 1; throw mid-batch-2; query DB after | `customerorder_batch`, `customerorder`, `customerorder_position` tables are empty (no orphans) |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `OrderBatchCreationServiceUnitTest` | `createAll_shouldCompleteSuccessfully_whenAllSavesSucceed` | Repos called expected N/M/K times; method returns normally |
| `OrderBatchCreationServiceUnitTest` | `createAll_shouldPropagateWebserviceBusinessException_whenBatchSaveFailsWithDao` | Existing wrap at line 375 still works; exception propagates |
| `OrderBatchCreationServiceUnitTest` | `createAll_shouldPropagateDataAccessException_whenOrderSaveFails` | Order save does NOT wrap DataAccessException; raw exception propagates |
| `OrderBatchCreationServiceUnitTest` | `createAll_shouldPropagateDataAccessException_whenPositionSaveFails` | Position save does NOT wrap DataAccessException; raw exception propagates |
| `OrderBatchCreationServiceUnitTest` | `createAll_shouldPropagateEntityNotFoundException_whenClientLookupFails` | `clientRepository.findByClNr(...).orElseThrow(...)` fires; `EntityNotFoundException` propagates |
| `OrderBatchCreationServiceUnitTest` | `createAll_shouldPropagateIllegalArgumentException_whenOrderSaveValidationFails` | Existing wrap for `IllegalArgumentException` still works |
| `OrderBatchCreationServiceUnitTest` | `createAll_shouldPropagateBusinessException_whenSequenceExhausted` | Mock `basicService.generateNumber(...)` to throw `BusinessException`; assert exception propagates out of `createAll(...)`. This verifies the realistic F5 failure path (sequence exhaustion under load). |
| `OrderBatchCreationServiceUnitTest` | `createAll_isAnnotatedWithTenantTransactionManagerAndRollbackFor` | Reflection: assert `@Transactional` with `value = "tenantTransactionManager"` and `rollbackFor` includes both `WebserviceBusinessExceptionClientSide.class` and `BusinessException.class`. |
| `OrderRestControllerUnitTest` | `create_shouldDelegateToOrderBatchCreationService_whenValidationPasses` | `orderBatchCreationService.createAll(...)` called exactly once with the post-validation maps |
| `OrderRestControllerUnitTest` | `create_shouldReturn400AndLogFailure_whenServiceThrowsWebserviceBusinessException` | 400 returned with error map; `messageService.createMessage(..., MessageStatus.FAILED, ...)` invoked once |
| `OrderRestControllerUnitTest` | `create_shouldPropagateDataAccessException_toRestEndpointExceptionHandler` | Exception is not swallowed by the controller catch; reaches the advice (verified by MockMvc returning 503 with both advices wired) |
| `OrderRestControllerUnitTest` | `create_shouldNotInvokeService_whenValidationFails` | `orderBatchCreationService.createAll` is never called when Phase 1 fails (duplicate batch_id) |
| `OrderRestControllerIntegrationTest` (Testcontainers) | `create_shouldRollBackAllSaves_whenMidLoopFailureOccurs` | Send 2-batch payload; inject failure mid-batch-2; query `customerorder_batch` / `customerorder` / `customerorder_position` — all empty |
| `OrderRestControllerIntegrationTest` (Testcontainers) | `create_shouldSucceedOnRetry_afterMidLoopFailure` | Send → 500/503; retry with same Idempotency-Key (SBDEV-2222) — 204 success; no `ENTITY_ALREADY_EXITS` 400 |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Smoke: happy path | staging | OMS sends valid 2-batch payload to `PUT /rest/order/create` | 204 No Content; both batches visible in `customerorder_batch`; all orders/positions present | |
| Smoke: validation 400 | staging | OMS sends payload with a duplicate `batch_id` of an existing row | 400 with error map; no new rows in `customerorder_batch` | |
| Smoke: mid-loop DB failure (atomicity) | staging | (a) Inject a constraint violation by sending a payload whose second batch references a non-existent `cl_nr` via DB-side check, OR (b) bounce PgBouncer for 5s during a 10-batch payload | 503 + Retry-After (SBDEV-2230); `customerorder_batch` / `customerorder` / `customerorder_position` rows for the request: NONE | |
| Smoke: retry after failure (SBDEV-2222 integration) | staging | Trigger mid-loop failure → 503; OMS retries with same `Idempotency-Key` after Retry-After | 204 No Content; rows now present; NO `ENTITY_ALREADY_EXITS` 400 | |
| Smoke: failure message log | staging | Trigger 400 path | `MessageProcessType=ORDER_BATCH_IMPORT, MessageStatus=FAILED` row visible in `message` table (i.e. failure log was outside the rolled-back tx) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=OrderBatchCreationServiceUnitTest` | | |
| `mvn test -Dtest=OrderRestControllerUnitTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2231-order-rest-create-partial-batch-atomicity.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Cross-replica rollback contention | The tenant transaction is on a single connection from a single replica's HikariCP pool. Cross-replica concurrency is handled by Postgres MVCC + optimistic locks where applicable; no new lock surface is introduced by this plan. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **No** | `OrderBatchCreationService` is stateless; only constructor-injected collaborators. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **Yes — extends connection hold time** | Today: N+M+K independent auto-commit saves → connection is acquired/released around each save (Hikari `autoCommit=true` default per-statement model + the OSIV filter keeps one connection per request). After: single transaction for Phase 2 → one connection held for the duration of the save loop. **Math:** assume worst-case 50-batch payload × 100 orders × 10 positions = ~50k saves at ~1ms each = ~50s connection hold per request. Worst case: a slow burst can saturate a tenant pool. **Mitigation:** (a) typical payload is ≤10 batches ≤20 orders ≤5 positions → ≤1000 saves ≈ 1s hold — safe. (b) Hikari pool size per tenant is 10; even worst-case 50s × concurrent OMS clients < `maxLifetime` (30 min). (c) PgBouncer-fronted topology has a per-tenant cap that's already sized for the OSIV-era hold time. **No mitigation code needed; documented as accepted.** |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | **No** | — |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | **Yes** | The fix's whole point IS to hold a transaction across multiple repo calls. External I/O inside the tx: (a) `basicService.generateNumber(...)` — touches `los_sysprop` via JPA, same DataSource, same connection. Safe. (b) `shipperidService.createShipperID(...)` — same DataSource; propagation TBD (Open Question 1). No HTTP / message I/O inside the tx. **Mitigation:** the failure message log (potentially HTTP-adjacent — depends on `MessageService` impl) is explicitly moved OUTSIDE the tx (controller catch block). The success message log inside the tx is JPA-only (`message` table insert). |
| 5 | **Request affinity** | Assume follow-up request lands on the same replica? | **No** | Transaction state lives in the DB; an OMS retry can land on any replica. SBDEV-2222 dedup is via shared `rest_idempotency` table. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op? | **No — strictly improves** | Today: replica death mid-loop leaves partial commits with no resume path. After: replica death mid-transaction → Postgres rolls back the in-flight tx (connection drops) → OMS retry replays from a clean state. SBDEV-2222's `Idempotency-Key` dedup gates the retry. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | **No** | Service runs on the same request thread; tenant context is set by `TenantFilter` upstream and consumed by `tenantTransactionManager` synchronously. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **No** | No new locks. The `@Transactional` boundary is per-request; concurrency between two simultaneous OMS create requests is handled by Postgres unique constraint on `customerorder_batch.batch_id` (the existing Phase 1 duplicate check plus the unique constraint as backstop). |
| 9 | **Cache invalidation** | Write to an entity that is cached? | **No** | `customerorder_batch`, `customerorder`, `customerorder_position`, `shipperid` writes — none of these are in the Caffeine cache configuration. Verified: `grep -rn "Cacheable.*customerorder" v2/wms2-api/src` → no hits on these entities. |
| 10 | **External notifications** | Send HTTP / message to an external system inside a transaction? | **No** | All work inside the tx is JPA on the tenant DataSource. The failure message log (which is a DB insert on `message`, not an external HTTP call) is OUTSIDE the tx in the controller catch — for log persistence, not for I/O-in-tx safety. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 2 | Connection-hold worst-case math documented; payload-size empirical assumption noted | §7 row 2 prose |
| 4 | Failure message log moved out of tx; success log left in tx intentionally | §3.4 |
| 4 | `ShipperidService.createShipperID` has no `@Transactional` — joins caller tx, rolls back atomically | §3.5 (resolved by Architect review) |
| 6 | SBDEV-2222 `Idempotency-Key` dedup is the cross-replica retry guard | `sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md` status=implemented |

---

## 8. v2-only Constraint Checklist

| # | Rule | Compliant? | Where verified |
|---|---|---|---|
| 1 | All tenant-scoped `@Transactional` uses `value = "tenantTransactionManager"` | **Yes** | `OrderBatchCreationService.createAll` annotation explicitly specifies `value = "tenantTransactionManager"` |
| 2 | OSIV — repository calls outside `@Transactional` open new sessions | **Yes** | All repository calls in this plan move INTO the new `@Transactional` method; no new OSIV-only paths |
| 3 | Constructor injection only — no `@Autowired` fields | **Yes** | `OrderBatchCreationService` and the updated `OrderRestController` both use constructor injection |
| 4 | SLF4J parameterized logging — no string concatenation | **Yes** | `LOG.warn`/`LOG.error` use `{}` placeholders |
| 5 | Prefer `.orElseThrow(...)` over `.get()` | **Yes** | Existing pattern preserved in extracted save loop (`clientRepository.findByClNr(...).orElseThrow(...)`) |
| 6 | Jakarta namespace (`jakarta.*`) — not `javax.*` | **Yes** | New service imports `net.aim_ai.wms.exceptions.EntityNotFoundException` (the project-internal `RuntimeException`-extending type used by all `.orElseThrow(...)` sites in the controller). `jakarta.persistence.EntityNotFoundException` is NOT used — that would be a wrong import that breaks `RestExceptionHandler.handleEntityNotFound` mapping. |
| 7 | `AbstractBaseEntity.equals()` ID-based — do not rely on `.equals` for unsaved entities | **N/A** | No entity equality checks in this plan |
| 8 | Multi-tenant — every entity write goes through the tenant DataSource | **Yes** | `tenantTransactionManager` binds to the tenant DataSource per request |

---

## 9. Risks & Mitigations

| # | Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|---|
| 1 | `ShipperidService.createShipperID` is `REQUIRES_NEW` → shipper row commits outside the outer tx → orphaned `shipperid` row on rollback. | ~~Medium~~ **Resolved** | Low | **Resolved by Architect review:** `ShipperidService.createShipperID` has NO `@Transactional` annotation — joins caller's tx via default `REQUIRED` propagation. Shipper inserts roll back with batch data. No orphaned rows. No action needed. |
| 2 | Worst-case 50-batch × 100-order × 10-position payload (~50k saves) holds a tenant DB connection for ~50s. Concurrent OMS bursts could saturate the per-tenant Hikari pool. | Low | Medium | (a) Empirical payload size is ≤10 batches × ≤20 orders × ≤5 positions (~1000 saves, ~1s hold). (b) Hikari `connectionTimeout` is 30s; a saturated pool returns a `DataAccessResourceFailureException` which SBDEV-2230 maps to 503 + retryable=true → OMS retries with backoff. **No code change needed**; behavior is graceful degradation. |
| 3 | `BusinessException` from `basicService.generateNumber(...)` would bypass rollback if not listed in `rollbackFor`. | ~~Low~~ **Resolved** | ~~Low~~ High | **Resolved by Architect review:** `BasicService.generateNumber` declares `throws BusinessException` and throws on `SequenceInvalid` (line 50) and `SequenceExhausted` (line 170) — realistic failure paths under load. `BusinessException extends Exception` (checked). **Fix already applied to this plan:** `rollbackFor` now includes `BusinessException.class`. No further action needed. |
| 4 | Existing `OrderRestControllerUnitTest` expects the save loop to be in the controller and asserts repo-call counts directly on the controller. | High | Low | The plan explicitly modifies `OrderRestControllerUnitTest`. Delegation tests REPLACE the direct-repo-call-count tests. The repo-call-count assertions move to `OrderBatchCreationServiceUnitTest`. |
| 5 | A future developer adds a new repository call to the controller (instead of the service) and reintroduces the auto-commit anti-pattern. | Medium | Medium | (a) Verify-script grep negative-check: any `*Repository.save(` reference inside `OrderRestController.create` body is a FAIL (only allow it inside `OrderBatchCreationService`). (b) Update `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` to record the boundary. |
| 6 | A wrapped `RuntimeException` (e.g. a service rethrows `DataAccessException` as a generic `RuntimeException`) breaks Spring's `ExceptionDepthComparator` matching at the `RestEndpointExceptionHandler`. | Low | Low | Same as SBDEV-2230 Risk #5. Out of scope for this plan. The failure mode is "503 → 500 with retryable=false" — still no orphans (rollback happens regardless of how the exception is mapped to HTTP). |

---

## 10. Open Questions

1. ~~**`ShipperidService.createShipperID` propagation**~~ **RESOLVED:** has NO `@Transactional` — joins caller's tx, rolls back with data. No action needed. (`service/ShipperidService.java:42`)
2. ~~**`BasicService.generateNumber` exception type**~~ **RESOLVED:** throws `BusinessException` (checked) on `SequenceInvalid`/`SequenceExhausted`. Added `BusinessException.class` to `rollbackFor`. No further action needed. (`service/BasicService.java:50,170`)
3. **`Idempotency-Key` cache TTL coverage** — does SBDEV-2222's cache TTL outlast OMS's typical retry window? If a transient 503 leads OMS to retry past the TTL, the retry skips dedup. **Owner:** David Oppenheim. **Blocks:** No — SBDEV-2222 TTL is currently 24h, OMS retries within seconds; safe by 4 orders of magnitude.
4. **Per-batch success message logging on rollback** — when the tx rolls back mid-batch, the success log for previously-iterated batches in the same tx also rolls back. This is intentional (no false-positive success logs), but operators should be aware that **partial success is not loggable** under this design — the entire batch list is either logged as success or logged as failure (failure log in the controller catch). Documented in §11.

---

## 11. Notes

**Related plans / docs:**
- `sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md` — provides retry safety on the dedup layer. Hard prerequisite.
- `sbdocs/1-Projects/wms2/plan/SBDEV-2230-rest-exception-handler-retryable-differentiation.md` — provides 503/404/500 + retryable classification when exceptions escape the new `@Transactional` boundary. Hard prerequisite.
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` — to be updated to record `OrderBatchCreationService` as a tenant-tx boundary.
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — already updated for SBDEV-2230; no further change needed for SBDEV-2231 since the OMS contract is unchanged (same status codes; same `retryable` shape).

**Deployment considerations:**
- Single rolling deploy. No DB migration. No config keys.
- SBDEV-2222 and SBDEV-2230 must be already deployed (both status=implemented).
- Worst-case connection-hold extends from ~1ms-per-save to ~1s-per-request typical / ~50s-per-request pathological. Monitor `pg_stat_activity` and Hikari pool saturation post-deploy for 48h.

**Follow-up work (not in this plan):**
- Update `wms2-transaction-osiv-boundary-map.md` with the new `OrderBatchCreationService` tx boundary.
- Note: `ShipperidService.createShipperID` has no `@Transactional` — it joins its caller's tx correctly, but a future CLAUDE.md-compliance audit should add `@Transactional(value = "tenantTransactionManager", readOnly = false)` for clarity.
- Consider extending the same atomicity pattern to other `/rest/**` controllers that today have unwrapped save loops (SBDEV audit candidate).

**Operational note — message log records intent per batch, not final request outcome:**
`MessageService.createMessage` uses `Propagation.REQUIRES_NEW` (confirmed at `service/MessageService.java:67-68`). Each `createMessage(...)` call commits in its own independent transaction regardless of the caller's transaction state. Consequence: on a mid-loop failure in `OrderBatchCreationService.createAll(...)`, the per-batch SUCCESS log rows for already-processed batches **persist** even though the batch/order/position DB rows are rolled back.

Operators auditing the `message` table after a failure will see N-1 SUCCESS rows (for the N-1 batches that saved before the failure) **plus** one FAILED row (from the controller catch block). The FAILED row is the canonical outcome marker for the whole request. The SUCCESS rows record that individual batches' save logic executed, not that the overall request completed. This is an accepted trade-off of the `REQUIRES_NEW` audit-trail design — operators should treat the FAILED row as authoritative when it is present.

**Implementation status:**
- Commit SHA: `808d714` (branch `tasks/SBDEV-2231`)
- `mvn test` result: 3966 tests, 0 failures, 0 errors, 65 skipped — BUILD SUCCESS
- Verify-script result: 18/18 ACs pass
- PR link: https://github.com/SiteBossInc/wms2-api/pull/19 (targeting `develop`)
- Implemented: 2026-05-14

---

## 12. Acceptance & Implementation

### 12.1 Acceptance script (machine-checkable)

Script path: `sbdocs/9-System/scripts/verify-SBDEV-2231-order-rest-create-partial-batch-atomicity.sh`

**Acceptance criteria the verify script enforces:**

1. `OrderBatchCreationService.java` exists at `src/main/java/net/aim_ai/wms/service/OrderBatchCreationService.java`
2. `OrderBatchCreationService` is annotated `@Service`
3. `OrderBatchCreationService.createAll(...)` is annotated `@Transactional` with `value = "tenantTransactionManager"`
4. `OrderBatchCreationService.createAll(...)` `@Transactional` includes `WebserviceBusinessExceptionClientSide.class` in `rollbackFor`
5. `OrderBatchCreationService` uses constructor injection (no `@Autowired` field)
6. `OrderRestController` has `OrderBatchCreationService` as a constructor-injected dependency
7. `OrderRestController.create` invokes `orderBatchCreationService.createAll(`
8. `OrderRestController.create` does NOT contain `customerorderBatchRepository.save(` anywhere in its method body (NEGATIVE check — save loop fully extracted)
9. `OrderRestController.create` does NOT contain `customerorderRepository.save(` anywhere in its method body (NEGATIVE check)
10. `OrderRestController.create` does NOT contain `customerorderPositionRepository.save(` anywhere in its method body (NEGATIVE check)
11. The failure message log (`MessageStatus.FAILED`) is invoked from a `catch (WebserviceBusinessExceptionClientSide` block in `OrderRestController` (not from inside the service)
12. `OrderBatchCreationServiceUnitTest.java` exists at `src/test/java/net/aim_ai/wms/unit/service/OrderBatchCreationServiceUnitTest.java`
13. `mvn test -Dtest=OrderBatchCreationServiceUnitTest` exits 0
14. `mvn test -Dtest=OrderRestControllerUnitTest` exits 0
15. No regressions in the existing `OrderRestController` happy-path 204 contract (verified by an existing test class re-run)

### 12.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 1 new service file + 1 controller refactor; single subsystem (REST inbound order create) |
| **Pre-draft step** | none — consensus mode (ralplan) completed | RALPLAN-DR summary in §13 + Architect/Critic review pass |
| **Plan-review step** | critic | Catches remaining gaps before code starts |
| **Implementation shape** | executor | Mechanical extraction; tests are the verification surface |
| **Verification step** | verify-script + verifier (mandatory) | Always |
| **Code-review step** | code-reviewer | Final pass before commit |
| **Commit step** | git directly | Single commit with controller + service + tests |

#### Why this matters

The save loop is ~150 lines extracted verbatim from one method into another. The risk is not in the extraction — it's in (a) forgetting to add `rollbackFor` (Critic check), (b) accidentally moving the failure log inside the tx (verify-script negative check), and (c) leaving a stray `.save(` call in the controller (verify-script negative check). All three risks are mechanical and the verify script catches them.

---

## 13. ADR (consensus mode)

**Decision:** Extract the `OrderRestController.create` save loop into a new `@Service`-annotated `OrderBatchCreationService.createAll(...)` method, annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`. Keep the Phase 1 validation in the controller. Keep the failure message log in the controller's catch block (it was already there).

**Drivers:**
1. All-or-nothing semantics — confirmed by user (2026-05-14).
2. Self-invocation proxy constraint — `@Transactional` on the controller's own `create()` method commits on caught-and-returned exceptions; rollback would require `setRollbackOnly()` which is fragile.
3. Architectural convention — CLAUDE.md mandates `value = "tenantTransactionManager"` on tenant-scoped `@Transactional`, and transaction boundaries belong in the service layer.
4. Hard prereqs SBDEV-2222 (idempotency) and SBDEV-2230 (retryable signal) are both implemented; this plan completes the durability trio.

**Alternatives considered:**
- (a) `@Transactional` directly on `OrderRestController.create()`. **Rejected:** the catch-and-return pattern on `WebserviceBusinessExceptionClientSide` commits the transaction (Spring sees a normal return). Would require `TransactionAspectSupport.currentTransactionStatus().setRollbackOnly()` in every catch arm — fragile.
- (b) Add `saveBatches(...)` to existing `CustomerorderBatchService`. **Rejected:** `CustomerorderBatchService` is already a god-service with 20+ deps; adding 3 new dependencies (`BasicService`, `ShipperidRepository`, `ShipperidService`) to satisfy the loop's needs makes it worse.
- (c) New `OrderBatchCreationService` with `@Transactional` on `createAll(...)`. **Chosen.**

**Why chosen:** Clean separation. Exactly 9 dependencies — every one required by the save loop. The `@Transactional` boundary is at the service entry, so the controller's catch block runs AFTER rollback has completed. Exception types fall out naturally: `WebserviceBusinessExceptionClientSide` → controller catch → 400; everything else → `RestEndpointExceptionHandler` (SBDEV-2230) → 503/404/500 with retryable.

**Consequences:**
- One new file. One refactored controller method.
- Connection hold time extends from per-statement to per-request — accepted (§7 row 2 math).
- Failure message log location changes (controller catch, not inside service) — operators should know about this if they're auditing log placement.
- Per-batch success logs roll back with the data on mid-loop failure — intentional, matches all-or-nothing semantics.

**Follow-ups:**
- `ShipperidService.createShipperID` propagation check (Open Question 1).
- `BasicService.generateNumber` exception type check (Open Question 2).
- `wms2-transaction-osiv-boundary-map.md` update to record the new boundary.
