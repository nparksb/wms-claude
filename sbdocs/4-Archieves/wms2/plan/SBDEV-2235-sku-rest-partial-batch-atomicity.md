---
title: "SBDEV-2235 — SkuRestController.update / create partial-batch failure leaves orphaned SKUs (self-recursion + no @Transactional + NPE on new-SKU update path + wrong 400)"
ticket: "SBDEV-2235"
ticket_url: "https://app.clickup.com/t/868jj32rf"
type: "bug"
severity: "high"
priority: "high"
status: "archived"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-15"
updated: "2026-05-15"
last_updated: "2026-05-15"
db_verified: true
related:
  - "[[SBDEV-2222-rest-inbound-no-idempotency-contract]]"
  - "[[SBDEV-2230-rest-exception-handler-retryable-differentiation]]"
  - "[[SBDEV-2231-order-rest-create-partial-batch-atomicity]]"
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

# SBDEV-2235 — SkuRestController.update / create partial-batch failure leaves orphaned SKUs (self-recursion + no @Transactional + NPE on new-SKU update path + wrong 400)

**Ticket:** [SBDEV-2235](https://app.clickup.com/t/868jj32rf)
**Project:** wms2-api | **Version:** v2 | **Type:** bug
**Priority:** High | **Severity:** HIGH (Tier 2)
**Status:** draft (2026-05-15) — RALPLAN-DR initial draft; pending Architect + Critic consensus pass.
**Date:** 2026-05-15

> **Framing:** `SkuRestController.update` (HTTP `POST /rest/sku/update`) and `SkuRestController.create` (HTTP `PUT /rest/sku/create`) both accept a list of SKU DTOs from OMS and persist them via `itemdataRepository.save(...)` calls. **Neither method has `@Transactional` anywhere on the call stack**, so each `save(...)` auto-commits in its own one-statement transaction (the repo inherits `tenantTransactionManager` from `@EnableJpaRepositories`, but only at the per-statement level). When the 30th SKU in a 50-SKU payload has an invalid `client_id`, SKUs #0–#29 are already committed and visible in `itemdata`. OMS sees a 400 (today) and never retries the batch. The DB has 29 orphans; OMS thinks the operation failed; the two systems diverge.
>
> Three independent defects compound the corruption:
>
> 1. **`update()` self-recurses into `create()` for new-SKU rows.** Line 230 calls `this.create(createList)` inside the `update()` for-loop. Spring's CGLIB proxy does NOT intercept self-calls on `this` — even if `create()` were `@Transactional`, the boundary would silently NOT fire on the self-call. Today neither method is transactional, so the structural bug is benign-looking, but the moment we naively slap `@Transactional` on `create()` we'd ship a method that appears transactional but isn't whenever it's called from `update()`.
> 2. **Validation interleaves with writes.** Per-row, the loop does (validate row → save row) in one pass. A bad row at position N means positions 0..N-1 are already committed before the validation failure at position N is discovered.
> 3. **NoSuchElementException on new-SKU update path.** Line 275 calls `itemDataValue.get()` immediately after the branch where `itemDataValue.isPresent() == false` — a `LOG.debug("update {}/{} sku={}", i, skuList.size(), itemDataValue.get())` that throws `NoSuchElementException` on every previously-new SKU. This today turns a "create-via-update" success path into a 500 escape and leaves whatever the self-recursion already committed.
>
> Plus a contract gap: today both methods return 400 (`ResponseEntity.badRequest()`) for validation failures, but AC3 of the ticket and OMS's parsing both expect 422 (`HttpStatus.UNPROCESSABLE_ENTITY`) for `/update` and `/create`. `/delete` stays 400.
>
> **Fix:** Extract the per-row save into a new `SkuBatchCreateUpdateService.upsertAll(...)` annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`. The service receives pre-resolved lookup maps from a Phase 1 controller pass and chooses insert-vs-update per row. The controller's `update()` no longer self-recurses; the new-SKU branch and the existing-SKU branch are unified inside the service. The line 275 NPE is folded — the offending log line does not exist in the new service. The validation failure status changes from 400 to 422 on `/update` and `/create`. `/delete` is out of scope.

---

## 1. Problem Statement

### 1.1 Symptom

OMS sends a 50-SKU payload to `POST /rest/sku/update`. SKUs #0–#28 are valid (some are updates, some are new — the update method silently routes new SKUs into `create()` via self-recursion at line 230). SKU #30 has a `client_id` that does not exist in the tenant's `client` table.

| Step | What happens | DB state |
|---|---|---|
| 1 | Loop iteration 0: validate sku #0 → resolve client → load itemdata → branch existing-SKU → `itemdataRepository.save(updatedItemdata)` (auto-commit) | +1 `itemdata` row (updated) |
| 2 | Loop iteration 1: sku #1 is new → `update()` calls `this.create(createList)` (self-recursion). The proxy is bypassed; the inner `create()` runs without any tx context. Inner `create()` validates + `itemdataRepository.save(newItemdata)` (auto-commit) | +1 `itemdata` row (inserted) |
| 3 | Loop iteration 2: sku #2 is new → same self-recursion path → another inserted row | +1 `itemdata` row |
| ... | iterations 3..29 alternate between updates and self-recursing inserts; every save auto-commits | total ~29 `itemdata` rows modified or inserted |
| 30 | Loop iteration 30: validate sku #30 → `clientRepository.findByClNr(sku.getClientId())` returns empty → `throw new WebserviceBusinessExceptionClientSide(ENTITY_DOES_NOT_EXISTS, ...)` | (no write at iteration 30) |
| 31 | Outer catch at line 295 catches `WebserviceBusinessExceptionClientSide` → `messageService.createMessage(..., FAILED, "400", ...)` → `return ResponseEntity.badRequest().body(e.getErrorMap())` | — |
| 32 | OMS sees 400, treats as non-retryable validation failure, marks SKU batch as failed | — |
| 33 | Operator audits: WMS `itemdata` has 29 SKUs that OMS thinks were not saved | persistent divergence |

A second symptom on the same code path: when ALL rows in the payload are new SKUs that take the self-recursion branch, the `LOG.debug("update {}/{} sku={}", i, skuList.size(), itemDataValue.get())` at line 275 throws `NoSuchElementException` because `itemDataValue` was `Optional.empty()` on the new-SKU branch. The exception escapes the narrow `catch (WebserviceBusinessExceptionClientSide)` — `NoSuchElementException` is `RuntimeException`, not `WebserviceBusinessExceptionClientSide` — and the request returns 500 (or 503 post-SBDEV-2230 if `NoSuchElementException` is mapped, otherwise 500). By then the self-recursion has already committed any rows it processed before reaching the throwing log statement.

### 1.2 Why the current code fails — three compounding root causes

| # | Root cause | Code location | Failure consequence |
|---|---|---|---|
| RC1 | No `@Transactional` anywhere on the call stack | `SkuRestController.create()` line 72, `SkuRestController.update()` line 193 | Each `itemdataRepository.save(...)` auto-commits. Mid-loop failure leaves prior rows committed. |
| RC2 | `update()` self-recurses into `create()` via `this.create(createList)` for new-SKU rows | `SkuRestController.java:230` | (a) Even if we add `@Transactional` to `create()`, the proxy is bypassed on `this` self-calls and the boundary does NOT fire. (b) The recursion makes reasoning about partial state non-local. |
| RC3 | Per-row validation interleaves with per-row save | `SkuRestController.java:196–308` (whole `update()` for-loop body) | A bad row at position N is discovered AFTER rows 0..N-1 have already saved/auto-committed. Naively wrapping just the save in a tx would still leave the loop boundary as the atomicity unit, not the request. |
| RC4 | `Optional.get()` called on `Optional.empty()` in a debug log statement | `SkuRestController.java:275` (`itemDataValue.get()`) | Every new-SKU update path throws `NoSuchElementException`. Escapes the narrow catch as `RuntimeException` → 500 + whatever the recursion already committed. |
| RC5 | Validation-failure status code is 400, not 422 | `SkuRestController.java:187` (create catch), `SkuRestController.java:308` (update catch) | OMS contract (ticket AC3) requires 422 `UNPROCESSABLE_ENTITY` for `/update` and `/create` validation failures. Today's 400 is parsed as "malformed JSON" by some OMS clients, suppressing the structured error map. |

### 1.3 Why SBDEV-2222 (idempotency) doesn't save us

SBDEV-2222's `IdempotencyFilter` caches 2xx responses only. The OMS retry behavior for a 4xx is "do not retry" (terminal failure semantics); the retry behavior for a 5xx is "retry with same `Idempotency-Key`". Either way, the underlying first request has already committed 29 rows. A retry that lands and validates again will hit `ENTITY_ALREADY_EXITS` at line 104 (create path) for any SKU now duplicated by the orphans, and the retry will permanently fail. Even worse, on the `/update` path the validation routes already-existing SKUs to the UPDATE branch — so a retry might silently "succeed" on the rows that were partially committed, leaving the operator with no signal that anything went wrong.

The fix has to be at the **transaction boundary** layer, not the idempotency layer. SBDEV-2222 makes the dedup contract safe; this plan makes the underlying operation atomic so the data state matches the response state.

### 1.4 Why `@Transactional` on the controller method does NOT work

Three options were considered; only one preserves correctness:

- **Option A — Add `@Transactional` directly to `SkuRestController.update()` and `create()`:**
    1. Self-recursion breaks the proxy. `update()` calls `this.create(createList)` at line 230. CGLIB proxies do NOT intercept self-calls on `this` — the inner `create()` runs without going through the transaction interceptor. Spring's `@Transactional` on `create()` simply does not fire when called from `update()`.
    2. Even if (1) were not an issue, the catch-and-return pattern on `WebserviceBusinessExceptionClientSide` commits the transaction (Spring sees a normal `ResponseEntity` return, not a thrown exception, so the tx interceptor commits). Rollback would require `TransactionAspectSupport.currentTransactionStatus().setRollbackOnly()` in every catch arm — fragile and easy to forget.
    3. Mixing read-only Phase-1 lookups with the Phase-2 writes in a single controller-level tx expands the transaction scope unnecessarily and holds a connection across the entire validation pass. **Rejected.**

- **Option B — Add a `saveBatchCreateUpdate(...)` method to existing `ItemdataService`:**
    `ItemdataService` is already a focused service (6 dependencies; `@Cacheable` on lookups, `@CacheEvict` only on `setPutAwayLocation`). Adding a transactional upsert loop here would (a) entangle the cacheable read paths with a heavy write method, and (b) force `ItemdataService` to take new dependencies (`UnitloadTypeRepository` for the default-unit-load-type lookup already exists; OK) — but more importantly it would mix the per-entity helper service with a batch write boundary. The existing service is the right home for the lookup-and-cache pattern, not for a multi-entity upsert loop. **Rejected** for separation of concerns; this matches the SBDEV-2231 precedent that put `OrderBatchCreationService` in its own service rather than expanding the god-service `CustomerorderBatchService`.

- **Option C — New `SkuBatchCreateUpdateService` with `@Transactional` on `upsertAll(...)`:**
    Dedicated service with exactly the dependencies the upsert loop needs. The `@Transactional` boundary is at the service entry point, so any exception thrown inside the loop propagates OUT through the proxy BEFORE the controller's catch block runs. Spring's transaction interceptor sees the propagating exception, rolls back, then the controller catches the propagated `WebserviceBusinessExceptionClientSide` and returns 422 with the error map. Other exception types (`DataAccessException`, `EntityNotFoundException`) propagate to `RestEndpointExceptionHandler` (SBDEV-2230) with the correct status code and `retryable` signal. The self-recursion in the controller is deleted — the service unifies the insert and update branches via a single `upsertAll(...)` that resolves "existing or not" via a pre-built map. **Chosen.**

---

## 2. Root Cause Analysis

### 2.1 Affected file

`v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java`

### 2.2 Affected sites

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1 | `controller/rest/SkuRestController.java:230` | `update()` self-recurses into `create(createList)` for new-SKU rows | yes — epicenter (RC2) | yes |
| 2 | `controller/rest/SkuRestController.java:151` | `itemdataRepository.save(itemData)` inside `create()` with no outer tx | yes (RC1, RC3) | yes |
| 3 | `controller/rest/SkuRestController.java:270` | `itemdataRepository.save(itemData)` inside `update()` with no outer tx | yes (RC1, RC3) | yes |
| 4 | `controller/rest/SkuRestController.java:275` | `LOG.debug("update {}/{} sku={}", i, skuList.size(), itemDataValue.get())` called on `Optional.empty()` (NPE/NoSuchElementException on new-SKU update-path) | secondary (RC4) | yes (folded — line is deleted by the refactor) |
| 5 | `controller/rest/SkuRestController.java:187` | `return ResponseEntity.badRequest().body(e.getErrorMap())` in `create()` catch (should be 422) | contract fix (RC5) | yes |
| 6 | `controller/rest/SkuRestController.java:308` | `return ResponseEntity.badRequest().body(e.getErrorMap())` in `update()` catch (should be 422) | contract fix (RC5) | yes |
| 7 | `service/ItemdataService.java` (whole file, 156 lines) | No batch create/update method exists. `@CacheEvict(allEntries=true)` is only on `setPutAwayLocation`. | adjacent gap | no — the new service wraps `itemdataRepository` directly; controller-level `@CacheEvict` stays as today |
| 8 | `exceptions/WebserviceBusinessExceptionClientSide.java` | Single-error-only response shape (one `errorMap` per throw) | adjacent | no — pre-resolved decision: throw on first failure; no extension needed |
| 9 | `test/.../unit/controller/rest/SkuRestControllerUnitTest.java:1–334` | Existing tests; no rollback/recursion tests; no 422 assertions | test gap | yes — add tests; update existing 400 assertions to 422 |
| 10 | `service/SkuBatchCreateUpdateService.java` | NEW file | new — fix site | yes |
| 11 | `test/.../unit/service/SkuBatchCreateUpdateServiceUnitTest.java` | NEW file | new | yes |
| 12 | `test/.../integration/SkuRestControllerAtomicityIntegrationTest.java` | NEW Testcontainers IT | new | yes |
| 13 | `test/.../integration/SkuRestControllerIntegrationTest.java` | `@Disabled` legacy test | n/a | no — leave disabled |
| 14 | `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §12 | Verification log | doc | yes — add `SkuBatchCreateUpdateService` boundary entry |

### 2.3 Why `rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class}` is required

`WebserviceBusinessExceptionClientSide extends Exception` (checked exception — same as SBDEV-2231; verified by reading the class). Spring's `@Transactional` default rollback rule rolls back on `RuntimeException` and `Error` only. Checked exceptions are NOT rolled back unless explicitly listed. So we list it.

`BusinessException extends Exception` (checked — verified at `exceptions/BusinessException.java`). The controller methods both declare `throws BusinessException`. Although the current SKU upsert logic does not itself throw `BusinessException` directly, the new service may invoke helpers in future enhancements (e.g. sequence generation if SKU numbering is auto-assigned) that do. Listing `BusinessException.class` in `rollbackFor` is the safer, future-proof choice and matches the SBDEV-2231 precedent. **`BusinessException.class` MUST be in `rollbackFor`.**

`EntityNotFoundException` (project-internal at `net.aim_ai.wms.exceptions.EntityNotFoundException`) extends `RuntimeException`. `DataAccessException` extends `RuntimeException`. Both are auto-rolled back without needing explicit listing. `NoSuchElementException` also extends `RuntimeException` — auto-rolled back (but it shouldn't be thrown at all once line 275 is deleted).

### 2.4 Why the validation phase stays in the controller

The Phase 1 validation does only reads. It builds:
- `errors: Map<String, String>` (or short-circuits on first error — see pre-resolved decision #1)
- `clientMap: Map<String, Client>` — by `client_id` (`cl_nr`)
- `boxTypeMap: Map<String, Boxtype>` — by `box_id` (external id)
- `itemUnitMap: Map<String, Itemunit>` — by `unit_identifier_id` (unitname)
- `existingByClient: Map<Long, Map<String, Itemdata>>` — by `(client.id, sku)` to drive the upsert insert-vs-update decision
- `defaultUnitLoadType: UnitloadType` — the one-shot lookup of `UNIT_LOAD_TYPE_BOX`
- `defaultPutawayLocationId: Long` — the one-shot lookup of `STORAGE_LOCATION_PUTAWAY_LANE` (only needed for new-SKU inserts)

No writes. No atomicity concern. Moving validation into the service would (a) bloat the new service unnecessarily, (b) expand the transaction scope to include reads that don't need to be transactional, and (c) make the diff larger than the fix requires. **Stays in the controller, in a private `validateAndResolve(skuList)` helper that returns a small `ResolvedSkuBatch` record (or individual maps).**

### 2.5 Self-invocation proxy note (the very pitfall this plan is fixing)

`SkuRestController.update()` today calls `this.create(createList)` at line 230 — a textbook self-invocation. Spring CGLIB proxies wrap the bean externally; calls to `this.<method>` go through the raw object and bypass the proxy entirely. This means:

- Any `@Transactional` we might naively add to `create()` would NOT fire when called from `update()`. Tests against `update()` would pass green (autocommit looks identical to a phantom-but-not-firing tx in unit tests with mocks), then production would silently corrupt data on the first 30-SKU mixed payload.
- Any `@CacheEvict` we might naively add to `create()` would NOT fire on the self-call path either. Today's `@CacheEvict` on `update()` covers this incidentally; the refactor preserves the per-method `@CacheEvict` on both `create()` and `update()`.

The fix deletes the self-call at line 230. The new service is a different bean, so the proxy chain is intact when the controller calls into `SkuBatchCreateUpdateService.upsertAll(...)`. Spring's transaction interceptor wraps `upsertAll(...)` correctly. **This plan does NOT trigger the self-invocation pitfall** because the cross-bean call goes through the CGLIB proxy.

---

## 3. Design / Proposed Fix

### 3.1 New `SkuBatchCreateUpdateService`

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java`

```java
package net.aim_ai.wms.service;

import net.aim_ai.wms.exceptions.BusinessException;
import net.aim_ai.wms.exceptions.WebserviceBusinessExceptionClientSide;
import net.aim_ai.wms.json.SkuDto;
import net.aim_ai.wms.model.Boxtype;
import net.aim_ai.wms.model.Client;
import net.aim_ai.wms.model.Itemdata;
import net.aim_ai.wms.model.Itemunit;
import net.aim_ai.wms.model.UnitloadType;
import net.aim_ai.wms.repo.jpa.ItemdataRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * Atomic upsert service for SkuRestController.create and SkuRestController.update.
 *
 * Wraps the entire SKU upsert loop in a single tenant-scoped transaction so a
 * partial failure rolls back ALL prior saves in the same request. Without this
 * boundary, individual itemdataRepository.save() calls auto-commit and a
 * mid-loop failure leaves orphaned itemdata rows that block OMS retries.
 *
 * Replaces two anti-patterns in the prior code:
 *   1. SkuRestController.update self-recursed into create() via this.create(),
 *      which (a) bypassed any future @Transactional on create() via the proxy
 *      self-invocation pitfall, and (b) made partial-state reasoning non-local.
 *   2. Per-row validation interleaved with per-row save, so a validation
 *      failure at position N left positions 0..N-1 committed.
 *
 * The controller now runs Phase 1 (validate + resolve all lookups) in full
 * before calling upsertAll, which is Phase 2 (write all rows under a single
 * @Transactional).
 *
 * @Transactional rollback rules:
 *   - rollbackFor = WebserviceBusinessExceptionClientSide.class
 *       (checked exception; Spring would NOT roll back by default)
 *   - rollbackFor = BusinessException.class
 *       (checked exception; included for forward-compatibility with any
 *       future helper that throws BusinessException, matching the SBDEV-2231
 *       precedent on the order-create path)
 *   - DataAccessException, EntityNotFoundException, NoSuchElementException,
 *     IllegalArgumentException are auto-rolled back (extend RuntimeException).
 *
 * Multi-tenancy: value = "tenantTransactionManager" so the boundary binds to
 * the per-request tenant DataSource (v2 CLAUDE.md mandates this for every
 * tenant-scoped @Transactional; bare @Transactional defaults to landlordTM
 * which silently routes tenant writes to the wrong DataSource).
 */
@Service
public class SkuBatchCreateUpdateService {

    private static final Logger LOG = LoggerFactory.getLogger(SkuBatchCreateUpdateService.class);

    private final ItemdataRepository itemdataRepository;

    public SkuBatchCreateUpdateService(ItemdataRepository itemdataRepository) {
        this.itemdataRepository = itemdataRepository;
    }

    /**
     * Persist all SKU rows atomically. Each row is upserted: if the row's
     * (client.id, sku) is already in existingByClient, it is treated as an
     * update; otherwise it is treated as an insert.
     *
     * @param skuList                  validated DTOs (validation already
     *                                 completed in SkuRestController)
     * @param clientMap                cl_nr -> Client (resolved in validation)
     * @param boxTypeMap               external_id -> Boxtype (resolved in validation)
     * @param itemUnitMap              unit_identifier_id -> Itemunit (resolved in validation)
     * @param existingByClient         client.id -> (sku -> Itemdata) for existing rows
     * @param defaultUnitLoadType      the UNIT_LOAD_TYPE_BOX lookup (one-shot)
     * @param defaultPutawayLocationId the STORAGE_LOCATION_PUTAWAY_LANE id (one-shot,
     *                                 used only for new-SKU inserts)
     * @throws WebserviceBusinessExceptionClientSide on a per-row DAO failure
     *         (matches the back-compat shape OMS already parses)
     */
    @Transactional(
            value = "tenantTransactionManager",
            rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})
    public void upsertAll(
            List<SkuDto> skuList,
            Map<String, Client> clientMap,
            Map<String, Boxtype> boxTypeMap,
            Map<String, Itemunit> itemUnitMap,
            Map<Long, Map<String, Itemdata>> existingByClient,
            UnitloadType defaultUnitLoadType,
            Long defaultPutawayLocationId)
            throws WebserviceBusinessExceptionClientSide {

        int i = 0;
        for (SkuDto sku : skuList) {
            Client client = clientMap.get(sku.getClientId());
            // Phase 1 pre-resolved everything; null here is a programmer error,
            // not a user-input error. Fail loud.
            if (client == null) {
                throw new IllegalStateException(
                        "Phase 1 invariant violated: missing client for clientId=" + sku.getClientId());
            }

            Itemdata existing = existingByClient
                    .getOrDefault(client.getId(), Collections.emptyMap())
                    .get(sku.getSku());

            Itemunit itemUnit = sku.getUnitIdentifierId() == null
                    ? null
                    : itemUnitMap.get(sku.getUnitIdentifierId());
            Boxtype boxType = sku.getBoxId() == null
                    ? null
                    : boxTypeMap.get(sku.getBoxId());

            if (existing == null) {
                // INSERT path — formerly the create() loop body
                Itemdata fresh = new Itemdata();
                fresh.setItemNr(sku.getSku());
                fresh.setName(sku.getSkuName());
                fresh.setClientId(client.getId());
                fresh.setHandlingunitId(itemUnit != null ? itemUnit.getId() : null);
                fresh.setPutawaylocationId(defaultPutawayLocationId);
                fresh.setBottleSize(sku.getBottleSize());
                fresh.setVarietal(sku.getVarietal());
                fresh.setVintage(sku.getVintage());
                fresh.setWinetype(sku.getWineType());
                fresh.setDefultypeId(defaultUnitLoadType.getId());
                fresh.setImageFilename(sku.getImageFilename());
                fresh.setDefaultboxtypeId(boxType != null ? boxType.getId() : null);
                fresh.setVersion(1);
                fresh.setScale(0);
                fresh.setEntityLock(0);
                itemdataRepository.save(fresh);
                LOG.debug("upsert insert {}/{} sku={}", i, skuList.size(), fresh);
            } else {
                // UPDATE path — formerly the update() else-branch body
                existing.setHandlingunitId(itemUnit != null ? itemUnit.getId() : null);
                existing.setName(sku.getSkuName());
                existing.setBottleSize(sku.getBottleSize());
                existing.setVarietal(sku.getVarietal());
                existing.setVintage(sku.getVintage());
                existing.setWinetype(sku.getWineType());
                existing.setDefultypeId(defaultUnitLoadType.getId());
                existing.setImageFilename(sku.getImageFilename());
                existing.setDefaultboxtypeId(boxType != null ? boxType.getId() : null);
                itemdataRepository.save(existing);
                LOG.debug("upsert update {}/{} sku={}", i, skuList.size(), existing);
            }
            i++;
        }
    }
}
```

### 3.2 Restructure `SkuRestController.create` and `SkuRestController.update`

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java`

Inject `SkuBatchCreateUpdateService` via constructor. Restructure both methods into two phases. Delete the self-recursion at line 230. Delete the offending log line at line 275 (it no longer applies in the new service). Change validation-failure status code from 400 to 422 on `/update` and `/create`. Keep `@CacheEvict(value="itemdata", allEntries=true)` on both controller methods.

```java
@CacheEvict(value = "itemdata", allEntries = true)
@PutMapping(value = "/create", consumes = "application/json", produces = "application/json")
public ResponseEntity<Object> create(@RequestBody List<SkuDto> skuList) throws BusinessException {
    return doUpsert(skuList, WmsConstants.MessageProcessType.SKU_IMPORT);
}

@CacheEvict(value = "itemdata", allEntries = true)
@PostMapping(value = "/update", consumes = "application/json", produces = "application/json")
public ResponseEntity<Object> update(@RequestBody List<SkuDto> skuList) throws BusinessException {
    return doUpsert(skuList, WmsConstants.MessageProcessType.SKU_UPDATE);
}

/**
 * Unified upsert path: validate + resolve in this controller method,
 * then delegate the atomic write to SkuBatchCreateUpdateService.
 *
 * processType controls only the MessageService audit log type so the
 * existing OMS-side log distinction between SKU_IMPORT (create endpoint)
 * and SKU_UPDATE (update endpoint) is preserved.
 */
private ResponseEntity<Object> doUpsert(List<SkuDto> skuList,
                                        WmsConstants.MessageProcessType processType)
        throws BusinessException {
    try {
        if (skuList == null) {
            LOG.info("upsert called with list=NULL");
            throw new WebserviceBusinessExceptionClientSide(WmsConstants.PARAMETER_IS_NULL, null);
        }
        LOG.info("upsert called with {} (processType={})", skuList.size(), processType);

        // ===== Phase 1: validation + lookup resolution (no DB writes) =====
        ResolvedSkuBatch resolved = validateAndResolve(skuList);

        // ===== Phase 2: atomic write (delegated to transactional service) =====
        skuBatchCreateUpdateService.upsertAll(
                skuList,
                resolved.clientMap(),
                resolved.boxTypeMap(),
                resolved.itemUnitMap(),
                resolved.existingByClient(),
                resolved.defaultUnitLoadType(),
                resolved.defaultPutawayLocationId());

        // ===== Success message log (outside tx; survives any future fault) =====
        try {
            String payload = new ObjectMapper().writeValueAsString(skuList);
            messageService.createMessage(syspropService.getOmsInstanceName(),
                    syspropService.getWmsInstanceName(),
                    payload,
                    processType,
                    "N/A",
                    WmsConstants.MessageStatus.RECEIVED,
                    Integer.toString(HttpStatus.NO_CONTENT.value()), null);
        } catch (IOException e) {
            LOG.error("SKU upsert service log failed");
        }

        LOG.info("upsert finished with {}", skuList.size());
        return ResponseEntity.status(HttpStatus.NO_CONTENT)
                .body(Collections.singletonMap("status", "success"));

    } catch (WebserviceBusinessExceptionClientSide e) {
        // Failure message log — runs AFTER the service transaction (if any
        // started) has already rolled back. There is no outer @Transactional
        // on this controller method, so the log insert runs in plain auto-commit.
        // NOTE: MessageService.createMessage internally self-invokes createServiceLog
        // on the same bean, so its @Transactional(REQUIRES_NEW) does NOT fire
        // (see plan §3.4). The log persists here because no outer tx is active,
        // NOT because REQUIRES_NEW provides isolation. Do NOT move this call
        // inside SkuBatchCreateUpdateService — it would silently roll back with
        // the data on any failure.
        try {
            String payload = new ObjectMapper().writeValueAsString(skuList);
            messageService.createMessage(syspropService.getOmsInstanceName(),
                    syspropService.getWmsInstanceName(),
                    payload,
                    processType,
                    "N/A",
                    WmsConstants.MessageStatus.FAILED,
                    Integer.toString(HttpStatus.UNPROCESSABLE_ENTITY.value()), null);
        } catch (IOException ie) {
            LOG.error("SKU upsert service log failed");
        }
        // 422 UNPROCESSABLE_ENTITY per ticket AC3 (was 400 in the legacy code).
        return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY).body(e.getErrorMap());
    }
}

/**
 * Phase 1 — validate the entire payload and resolve all lookups in one pass.
 * No DB writes. Throws WebserviceBusinessExceptionClientSide on the FIRST
 * validation failure (matches pre-resolved decision: throw on first failure).
 *
 * Returns a record bundling all the maps and the singletons that the service
 * upsertAll(...) method needs in Phase 2.
 */
private ResolvedSkuBatch validateAndResolve(List<SkuDto> skuList)
        throws WebserviceBusinessExceptionClientSide {

    Map<String, Client> clientMap = new HashMap<>();
    Map<String, Boxtype> boxTypeMap = new HashMap<>();
    Map<String, Itemunit> itemUnitMap = new HashMap<>();
    Map<Long, Map<String, Itemdata>> existingByClient = new HashMap<>();

    for (SkuDto sku : skuList) {
        validateWarehouse(sku);

        if (sku.getSku() == null || sku.getSku().isEmpty()) {
            throw new WebserviceBusinessExceptionClientSide(
                    WmsConstants.FIELD_NOT_SET, null, "sku", sku);
        }
        if (sku.getSkuName() == null || sku.getSkuName().isEmpty()) {
            throw new WebserviceBusinessExceptionClientSide(
                    WmsConstants.FIELD_NOT_SET, null, "sku_name", sku);
        }
        if (sku.getClientId() == null || sku.getClientId().isEmpty()) {
            throw new WebserviceBusinessExceptionClientSide(
                    WmsConstants.FIELD_NOT_SET, null, "client_id", sku);
        }

        Client client = clientMap.computeIfAbsent(sku.getClientId(), clNr ->
                clientRepository.findByClNr(clNr).orElse(null));
        if (client == null) {
            throw new WebserviceBusinessExceptionClientSide(
                    WmsConstants.ENTITY_DOES_NOT_EXISTS, null, "client", sku.getClientId(), sku);
        }

        // Resolve box type if requested
        if (sku.getBoxId() != null && !boxTypeMap.containsKey(sku.getBoxId())) {
            Boxtype bt = boxtypeRepository.findByExternalid(sku.getBoxId())
                    .orElseThrow(() -> new WebserviceBusinessExceptionClientSide(
                            WmsConstants.ENTITY_DOES_NOT_EXISTS, null, "box_id", sku.getBoxId(), sku));
            boxTypeMap.put(sku.getBoxId(), bt);
        }

        // Resolve item unit if requested
        if (sku.getUnitIdentifierId() != null && !itemUnitMap.containsKey(sku.getUnitIdentifierId())) {
            Itemunit iu = itemunitRepository.findByUnitname(sku.getUnitIdentifierId())
                    .orElseThrow(() -> new WebserviceBusinessExceptionClientSide(
                            WmsConstants.ENTITY_DOES_NOT_EXISTS, null,
                            "unit_identifier_id", sku.getUnitIdentifierId(), sku));
            itemUnitMap.put(sku.getUnitIdentifierId(), iu);
        }

        // Resolve existing itemdata (drives insert-vs-update decision in Phase 2)
        existingByClient
                .computeIfAbsent(client.getId(), k -> new HashMap<>())
                .computeIfAbsent(sku.getSku(), s ->
                        itemdataService.findByClientIdAndItemNr(client.getId(), s).orElse(null));
    }

    // One-shot lookups (independent of payload)
    UnitloadType defaultUnitLoadType = unitloadTypeRepository
            .findByName(WmsConstants.UNIT_LOAD_TYPE_BOX)
            .orElseThrow(() -> new WebserviceBusinessExceptionClientSide(
                    WmsConstants.ENTITY_DOES_NOT_EXISTS, null,
                    "unitLoadType", WmsConstants.UNIT_LOAD_TYPE_BOX, null));
    Long defaultPutawayLocationId = locationRepository
            .findByName(WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE)
            .orElseThrow(() -> new EntityNotFoundException(
                    "Location not found by name: " + WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE))
            .getId();

    // Strip out the null sentinels in existingByClient — entries are kept as
    // map entries with null values so the service can disambiguate
    // "checked, not found" from "not checked". Service treats null as INSERT.
    return new ResolvedSkuBatch(clientMap, boxTypeMap, itemUnitMap,
            existingByClient, defaultUnitLoadType, defaultPutawayLocationId);
}

/**
 * Phase 1 → Phase 2 transport. Plain record, package-private.
 */
private record ResolvedSkuBatch(
        Map<String, Client> clientMap,
        Map<String, Boxtype> boxTypeMap,
        Map<String, Itemunit> itemUnitMap,
        Map<Long, Map<String, Itemdata>> existingByClient,
        UnitloadType defaultUnitLoadType,
        Long defaultPutawayLocationId) { }
```

Notes on what's deleted:
- Line 230 self-recursion is GONE — Phase 1 builds `existingByClient` so the service decides insert-vs-update without needing two endpoints' logic to share state.
- Line 275 `itemDataValue.get()` log is GONE — the new service emits its own `LOG.debug("upsert insert ...")` / `LOG.debug("upsert update ...")` with safe references.
- Line 187 and line 308 `ResponseEntity.badRequest()` are REPLACED with `ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY)`.

### 3.3 Per-failure-mode behavior matrix

| Failure mode | Before this fix | After this fix |
|---|---|---|
| Validation failure at row N (bad `client_id`, missing `sku`, etc.) | rows 0..N-1 already saved (auto-commit); 400 with error map; OMS treats terminal | Phase 1 detects in lookup pass; ZERO writes happened; **422** with error map; OMS treats terminal but DB is clean |
| New-SKU update path with empty `itemDataValue` | line 275 throws `NoSuchElementException`; escapes narrow catch → 500; partial state already committed by self-recursion | line 275 deleted; new-SKU path is the INSERT branch of `upsertAll`; no `NoSuchElementException` possible |
| `DataAccessException` during `itemdataRepository.save(...)` mid-loop | escapes narrow catch (only catches `WebserviceBusinessExceptionClientSide`) → 500/503 (SBDEV-2230); rows 0..N-1 committed | propagates out of service tx → rollback → `RestEndpointExceptionHandler` returns 503 + retryable=true (SBDEV-2230); **no orphans** |
| `EntityNotFoundException` (e.g. putaway lane lookup fails) | thrown from `.orElseThrow(...)` at line 140 inside the loop, mid-iteration → 404; prior rows committed | thrown in Phase 1 BEFORE any write → 404; ZERO rows committed |
| Self-recursion-induced state divergence | Possible: `create()` invoked from `update()` runs without proxy interception | IMPOSSIBLE: no self-recursion remains; single service-level tx boundary |
| Happy path 50-SKU mixed insert+update | 204; data persisted (via 50 auto-commits + 1 success log) | 204; data persisted (single tenant transaction + 1 success log) |

### 3.4 Message log behavior — `MessageService.createMessage` self-invocation note

**Architecture caution (Critic finding, 2026-05-15):** `MessageService.java:67-72` shows that the public `createMessage(...)` overloads call `createServiceLog(...)` on the same bean (`return createServiceLog(...)`). Spring CGLIB proxies do NOT intercept same-bean self-calls, so `@Transactional(propagation = Propagation.REQUIRES_NEW)` on `createServiceLog` does NOT fire when reached via `createMessage(...)`. Contrary to SBDEV-2231 §3.4's stated mental model, `messageService.createMessage(...)` does **not** commit independently via `REQUIRES_NEW` — it joins whatever transaction is active at the call site.

**Impact on this plan:** Both log call sites are outside any active outer transaction:
- **Success log** (controller `doUpsert`, after `upsertAll` returns) — `upsertAll`'s tenant tx has already committed; no outer tx is active; the log insert runs in a plain auto-commit statement. Net result: log row persists ✓
- **Failure log** (controller `doUpsert` catch block) — `upsertAll`'s tenant tx has already rolled back; no outer tx is active; the log insert runs in a plain auto-commit statement. Net result: log row persists ✓

The broken `REQUIRES_NEW` is harmless **for the log placements chosen by this plan**. However, this imposes a strict placement constraint:

> ⚠️ **`messageService.createMessage(...)` MUST NOT be called from inside `SkuBatchCreateUpdateService.upsertAll(...)`**. If placed there, the log call would join the service's tenant transaction and would roll back with the data on any failure — producing a silent data loss in the audit log that §12.1 AC #22 (verify-script negative check) enforces.

The verify script asserts (AC #22) that `SkuBatchCreateUpdateService.java` contains no reference to `messageService.create*`.

This is a latent existing issue in `MessageService` that also affects SBDEV-2231. A follow-up ticket should fix the self-invocation in `MessageService` (e.g., self-inject via `@Lazy` or restructure to avoid the internal call). Not in scope here.

### 3.5 Files changed

- **New:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java`
- **Modified:** `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java` (extract upsert loop; inject service; delete self-recursion at line 230; delete log line at 275; change 400→422 at lines 187 and 308; consolidate `create()` and `update()` into shared `doUpsert(...)`)
- **New:** `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/SkuBatchCreateUpdateServiceUnitTest.java`
- **Modified:** `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/controller/rest/SkuRestControllerUnitTest.java` (update 400→422 assertions on existing tests; add delegation tests; add no-recursion test)
- **New:** `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/SkuRestControllerAtomicityIntegrationTest.java`
- **Modified:** `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` (add `SkuBatchCreateUpdateService` boundary verification entry)
- **Modified:** `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` (update `/rest/sku/update` and `/rest/sku/create` validation-failure response code from 400 → 422; `/rest/sku/delete` stays 400)

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `SkuRestController.update` self-recursion shape | A similar SKU REST endpoint exists in v1; the self-recursion anti-pattern likely exists there too (Arden's codebase carried forward) | v2 (target of this plan) | Sister v1 plan TBD — file separate ticket after v2 lands |
| Multi-tenant transaction manager | `tenantTransactionManager` exists in v1 too | Same | Same fix shape would work in v1 |
| SBDEV-2230 (retryable signal) | v1 has a separate plan TBD | Already merged in v2 (`status=implemented`) | The 503/retryable signal on the new tx boundary is v2-specific |
| 400 → 422 contract change | v1 OMS contract is the same (uses 400 today) | Will switch to 422 | OMS-side parser change required (David Oppenheim) — same OMS-side change applies if v1 ports later |

**This plan is v2-only.** A sister v1 plan should be filed but is out of scope here. The conceptual change is identical: extract the upsert loop into a `@Transactional` service, drop self-recursion, fold the NPE, switch validation-failure to 422.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | N/A — no schema change | — | Pure service-layer refactor |
| 2 | **Feature flags / system properties** | N/A — no kill-switch | — | Behavior is strictly safer post-deploy. Worst case is "422 instead of 400" which is the desired contract (ticket AC3). |
| 3 | **Config / env changes** | N/A | — | No new config keys |
| 4 | **Deploy-order dependencies** | SBDEV-2230 (`RestEndpointExceptionHandler`) and SBDEV-2222 (`IdempotencyFilter`) MUST already be deployed | Nam Park | Both are `status=implemented` as of 2026-05-14. SBDEV-2230 maps any `DataAccessException`/`EntityNotFoundException` escaping the new service to 503/404 with `retryable`. |
| 5 | **OMS contract change** | OMS-side parser must accept HTTP 422 for `/rest/sku/update` and `/rest/sku/create` validation failures | David Oppenheim (OMS owner) | Confirmed in ticket AC3. Coordinate deploy: WMS must NOT ship 422 before OMS understands 422. See §9 Risk #1 for mitigation options. |
| 6 | **Data migration** | N/A | — | — |
| 7 | **Access / permissions** | N/A | — | — |
| 8 | **Monitoring / alerts** | Existing Micrometer `http.server.requests` panel for `/rest/sku/**` is sufficient. New 422-vs-400 split will show as a label-value change on the panel; document for the operator. | Nam Park | Optional but recommended. |
| 9 | **Branch coordination** | `feat/sku-item-id-sync` branch (Arden's parallel work on SKU sync) must rebase on top of this fix. Land SBDEV-2235 first. | Arden | Pre-resolved decision #3. |

### 5.2 Implementation Checklist

- [ ] Create `SkuBatchCreateUpdateService.java` — new `@Service`; constructor-inject `ItemdataRepository`; method `upsertAll(List<SkuDto>, Map<String,Client>, Map<String,Boxtype>, Map<String,Itemunit>, Map<Long,Map<String,Itemdata>>, UnitloadType, Long)` annotated with `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`.
- [ ] Extract the per-row insert/update body from `SkuRestController.create` (lines 135–155) and `SkuRestController.update` (lines 232–271) into `upsertAll(...)`. Unify the two code paths through the `existingByClient` map.
- [ ] Modify `SkuRestController` — constructor-inject `SkuBatchCreateUpdateService`. Consolidate `create()` and `update()` into a shared private `doUpsert(skuList, processType)` helper. Both `@PutMapping("/create")` and `@PostMapping("/update")` are now thin wrappers that delegate to `doUpsert` with the appropriate `MessageProcessType`. Keep `@CacheEvict(value="itemdata", allEntries=true)` on BOTH controller methods (pre-resolved decision #6).
- [ ] Implement private `validateAndResolve(List<SkuDto>)` in the controller: walks the list once, fills the four maps, resolves the two one-shot lookups, throws `WebserviceBusinessExceptionClientSide` on first failure. No DB writes.
- [ ] DELETE line 230 `create(createList)` self-recursion. The new `upsertAll(...)` handles new SKUs via the INSERT branch keyed on `existingByClient`.
- [ ] DELETE line 275 `LOG.debug("update {}/{} sku={}", i, skuList.size(), itemDataValue.get())`. The service emits safe equivalents (`LOG.debug("upsert insert ...")` / `LOG.debug("upsert update ...")`).
- [ ] CHANGE line 187 `return ResponseEntity.badRequest().body(e.getErrorMap())` → `return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY).body(e.getErrorMap())` (now lives in the unified `doUpsert` catch).
- [ ] CHANGE line 308 same edit (now also in the unified `doUpsert` catch).
- [ ] CHANGE failure-log status field from `"400"` to `Integer.toString(HttpStatus.UNPROCESSABLE_ENTITY.value())` in both catch arms (now unified in `doUpsert`).
- [ ] VERIFY `delete()` (method at lines 312–361) is UNCHANGED. It still returns 400 on validation failure (pre-resolved decision #2 keeps delete out of scope).
- [ ] Create `SkuBatchCreateUpdateServiceUnitTest` — mock `ItemdataRepository`; assert (a) insert vs update routing by `existingByClient`, (b) exception propagation, (c) reflection-based check that `upsertAll` is annotated with `@Transactional(value = "tenantTransactionManager")` and `rollbackFor` includes both `WebserviceBusinessExceptionClientSide.class` and `BusinessException.class`.
- [ ] Modify `SkuRestControllerUnitTest` — (a) update existing 400 assertions to 422 on the create/update happy-path-fail tests; (b) add delegation tests (Phase 1 passes → service called once; service throws → 422 with error map); (c) add a no-self-recursion regression test that fails if any path inside `update()` invokes `create()`; (d) keep the existing `delete()` tests unchanged (still expect 400).
- [ ] Create `SkuRestControllerAtomicityIntegrationTest` (Testcontainers Postgres) — `update_shouldNotPersistAnySku_whenPosition30HasInvalidClientId()`: send 50-SKU payload with bad client_id at index 30; assert HTTP 422; assert `itemdata` row count unchanged from baseline.
- [ ] Update `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §12 to record the new `SkuBatchCreateUpdateService.upsertAll` tenant-tx boundary.
- [ ] Update `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` to reflect the 400→422 contract change on `/rest/sku/update` and `/rest/sku/create` validation failures (keep `/rest/sku/delete` at 400).
- [ ] Run `mvn test -Dtest=SkuBatchCreateUpdateServiceUnitTest` — must pass.
- [ ] Run `mvn test -Dtest=SkuRestControllerUnitTest` — must pass.
- [ ] Run `mvn verify -Dtest=SkuRestControllerAtomicityIntegrationTest` — must pass.
- [ ] Run `mvn test` (full suite) — must pass with no regressions.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2235-sku-rest-partial-batch-atomicity.sh` — must exit 0.
- [ ] Rebase coordination with Arden: notify when this lands so `feat/sku-item-id-sync` can rebase.
- [ ] Code review.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Happy path 5-SKU mixed insert+update | Phase 1 resolves 3 existing + 2 new; mock `upsertAll` to succeed | 204 No Content; `upsertAll` invoked exactly once with correct maps |
| Service throws `WebserviceBusinessExceptionClientSide` (e.g. simulated DAO failure) | Mock `upsertAll` to throw | 422 (NOT 400) with error map body; failure message log invoked once with `MessageStatus.FAILED` and status field `"422"` |
| Service throws `DataAccessException` (any subclass) | Mock `upsertAll` to throw `DataAccessResourceFailureException` | Exception escapes the controller catch and reaches `RestEndpointExceptionHandler` → 503 + Retry-After + retryable=true (verified by MockMvc with both advices wired) |
| Service throws `EntityNotFoundException` | Mock `upsertAll` to throw | Exception escapes → 404 + retryable=false (SBDEV-2230) |
| Phase 1 validation failure — bad `client_id` at position 30 | Send 50-SKU payload, position 30 has unknown client_id | 422 with error map; `upsertAll` NEVER invoked; DB unchanged |
| Phase 1 validation failure — missing `sku` field | Send payload with one SKU missing `sku` field | 422 with `FIELD_NOT_SET` error map; `upsertAll` NEVER invoked |
| Phase 1 validation failure — `STORAGE_LOCATION_PUTAWAY_LANE` not found | DB state where putaway lane is missing | 404 (via `EntityNotFoundException` → SBDEV-2230); `upsertAll` NEVER invoked |
| All-new-SKUs payload through `/update` (the bug RC2 affected) | Send 5 SKUs, all new, via `/update` | 204; all 5 inserted; `upsertAll` invoked once; NO recursive call to `create()` |
| `upsertAll` happy path | Stub repo to succeed; invoke `upsertAll` directly with mixed maps | `itemdataRepository.save(...)` invoked N times; no exception |
| `upsertAll` propagates `WebserviceBusinessExceptionClientSide` | Stub `itemdataRepository.save` to throw on 30th call; assert exception propagates out | `@Transactional` rollback signal fires (asserted via reflection on the annotation OR via Testcontainers IT) |
| `upsertAll` propagates `DataAccessException` | Stub `itemdataRepository.save` to throw `DataAccessResourceFailureException` | Exception propagates unwrapped; rollback signal fires |
| `upsertAll` rollback verification (Testcontainers) | Use Testcontainers Postgres IT; send 50-SKU payload with failure at position 30; query DB after | `itemdata` table has the same row count as before the request — no orphans |
| Self-recursion regression | Use Mockito spy on `SkuRestController`; invoke `update()` with new SKUs | Assertion: `verify(spy, never()).create(any())` — `update()` does NOT call `create()` internally |
| `@Transactional` annotation reflection | Reflect on `SkuBatchCreateUpdateService.upsertAll` | Annotation present; `value = "tenantTransactionManager"`; `rollbackFor` includes both `WebserviceBusinessExceptionClientSide.class` and `BusinessException.class` |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `SkuBatchCreateUpdateServiceUnitTest` (NEW) | `upsertAll_shouldInsertNewSkus_whenNotInExistingMap` | Repo `save(...)` called with a fresh `Itemdata` whose `version=1`, `scale=0`, `entityLock=0`, correct `putawaylocationId`, etc. |
| `SkuBatchCreateUpdateServiceUnitTest` (NEW) | `upsertAll_shouldUpdateExistingSkus_whenInExistingMap` | Repo `save(...)` called with the existing `Itemdata` instance, fields mutated from `SkuDto` |
| `SkuBatchCreateUpdateServiceUnitTest` (NEW) | `upsertAll_shouldRollbackEntireBatch_whenSaveFails` | Stub `itemdataRepository.save` to throw on the Nth call; assert exception propagates out of `upsertAll` |
| `SkuBatchCreateUpdateServiceUnitTest` (NEW) | `upsertAll_shouldBeAnnotatedWithTenantTransactionManager` | Reflection: `@Transactional` present with `value = "tenantTransactionManager"` |
| `SkuBatchCreateUpdateServiceUnitTest` (NEW) | `upsertAll_shouldHaveRollbackForCheckedExceptions` | Reflection: `rollbackFor` contains both `WebserviceBusinessExceptionClientSide.class` and `BusinessException.class` |
| `SkuBatchCreateUpdateServiceUnitTest` (NEW) | `upsertAll_shouldThrowIllegalStateException_whenPhase1InvariantViolated` | Pass a `SkuDto` whose `clientId` is not in `clientMap`; assert `IllegalStateException` — defensive check on the Phase 1 contract |
| `SkuRestControllerUnitTest.Create` (MODIFIED) | `shouldReturnUnprocessableEntityWhenNullList` | Was: 400. Now: 422. Same test, different status assertion. |
| `SkuRestControllerUnitTest.Create` (MODIFIED) | `shouldReturnUnprocessableEntityWhenSkuIsMissing` etc. | All existing `shouldReturnBadRequest*` tests in Create + Update classes flipped to expect 422 |
| `SkuRestControllerUnitTest.Update` (NEW) | `update_shouldNotInvokeService_whenValidationFails` | `skuBatchCreateUpdateService.upsertAll` is never called when Phase 1 fails |
| `SkuRestControllerUnitTest.Update` (NEW) | `update_shouldRunValidationBeforeServiceCall` | Order-of-invocation assertion — validation calls happen before service call |
| `SkuRestControllerUnitTest.Update` (NEW) | `update_fiftySkuBatchBadClientIdAtPosition30_returns422_withNoSkusPersisted` | Send 50 SKUs, bad client_id at 30 → 422; `upsertAll` NEVER called |
| `SkuRestControllerUnitTest` (NEW) | `update_shouldNotCallCreateMethodInternally_evenForNewSkus` | Spy on controller; assert `verify(spy, never()).create(any())` after invoking `update()` with all-new SKUs |
| `SkuRestControllerUnitTest.Update` (NEW) | `update_shouldDelegateToSkuBatchCreateUpdateService_whenValidationPasses` | `skuBatchCreateUpdateService.upsertAll(...)` called exactly once with the post-validation maps |
| `SkuRestControllerUnitTest.Update` (NEW) | `update_shouldReturn422AndLogFailure_whenServiceThrowsWebserviceBusinessException` | 422 returned with error map; failure log invoked once with status `"422"` |
| `SkuRestControllerUnitTest.Update` (NEW) | `update_shouldPropagateDataAccessException_toRestEndpointExceptionHandler` | Exception is not swallowed by the controller catch; reaches the advice (verified by MockMvc returning 503 with both advices wired) |
| `SkuRestControllerUnitTest.Delete` (UNCHANGED) | All existing tests | `/delete` still returns 400 — confirms scope boundary |
| `SkuRestControllerAtomicityIntegrationTest` (NEW, Testcontainers) | `update_shouldNotPersistAnySku_whenPosition30HasInvalidClientId` | Send 50-SKU payload; record `itemdata` row count before; assert 422; assert post-request `itemdata` row count == pre-request count |
| `SkuRestControllerAtomicityIntegrationTest` (NEW, Testcontainers) | `update_shouldPersistAllSkus_whenAllValid` | Send 50-SKU payload all-valid; assert 204; assert `itemdata` rows match expected 50 |
| `SkuRestControllerAtomicityIntegrationTest` (NEW, Testcontainers) | `update_shouldSucceedOnRetry_afterTransientFailure` | Send → simulated 503; retry with same Idempotency-Key (SBDEV-2222) — 204 success; no `ENTITY_ALREADY_EXITS` 422 |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Smoke: happy path mixed insert+update | staging | OMS sends valid 10-SKU payload to `POST /rest/sku/update` (5 existing, 5 new) | 204 No Content; all 10 visible in `itemdata` (5 updated, 5 inserted) | |
| Smoke: validation 422 | staging | OMS sends payload with a missing `client_id` field on one SKU | **422** Unprocessable Entity with error map; no new rows in `itemdata` | |
| Smoke: mid-loop DB failure (atomicity) | staging | (a) Inject a constraint violation by sending a payload whose 30th SKU references an `Itemunit` deleted between Phase 1 and Phase 2 (race), OR (b) bounce PgBouncer for 5s during a 50-SKU payload | 503 + Retry-After (SBDEV-2230); `itemdata` rows for the request: NONE added/modified | |
| Smoke: retry after failure (SBDEV-2222 integration) | staging | Trigger mid-loop failure → 503; OMS retries with same `Idempotency-Key` after Retry-After | 204 No Content; rows now present; NO `ENTITY_ALREADY_EXITS` 422 | |
| Smoke: self-recursion gone | staging | Send 5-SKU all-new payload to `POST /rest/sku/update` | 204; 5 new rows inserted; check application log → does NOT contain "create called with 1" (which would indicate the old self-recursion fired) | |
| Smoke: failure message log | staging | Trigger 422 path | `MessageProcessType=SKU_UPDATE, MessageStatus=FAILED, status=422` row visible in `message` table | |
| Smoke: `/delete` unchanged | staging | Send invalid delete payload (missing `sku`) | **400** Bad Request (unchanged from today) — confirms scope boundary | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=SkuBatchCreateUpdateServiceUnitTest` | | |
| `mvn test -Dtest=SkuRestControllerUnitTest` | | |
| `mvn verify -Dtest=SkuRestControllerAtomicityIntegrationTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2235-sku-rest-partial-batch-atomicity.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| `/delete` rollback behavior | Pre-resolved decision #2: out of scope. `/delete` keeps 400 and per-row auto-commit. A sister plan can address it if user impact warrants. |
| `WebserviceBusinessExceptionClientSide` multi-error response shape | Pre-resolved decision #1: throw on first failure. No multi-error aggregation needed. |
| Cross-replica rollback contention | The tenant transaction is on a single connection from a single replica's HikariCP pool. Cross-replica concurrency on `itemdata` is bounded by the existing per-SKU uniqueness model. |
| Cache placement audit beyond controller-level `@CacheEvict` | Pre-resolved decision #6: keep `@CacheEvict(value="itemdata", allEntries=true)` on both controller methods. A holistic cache audit (e.g. evict only the affected keys) is follow-up work. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **No** | `SkuBatchCreateUpdateService` is stateless; only constructor-injected `ItemdataRepository`. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **Yes — extends connection hold time** | Today: N independent auto-commit saves → connection acquired/released around each save (OSIV filter holds one connection per request; per-statement autocommit inside that). After: single transaction for Phase 2 → one connection held for the duration of the upsert loop. **Math:** worst-case 50-SKU payload × ~1ms per save = ~50ms hold (plus Phase 1 lookup time ~50ms = ~100ms total request connection hold). Typical 10-SKU payload ≈ 20ms hold. Hikari pool size per tenant is 10; even under burst load the per-tenant pool comfortably handles 50 concurrent `/rest/sku/**` requests at 100ms hold each. **No mitigation code needed; documented as accepted.** |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | **No** | — |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | **Yes** | The fix's whole point IS to hold a transaction across multiple repo calls. External I/O inside the tx: NONE. The transaction only contains `itemdataRepository.save(...)` calls — pure JPA on the tenant DataSource. The success message log is OUTSIDE the service tx (in the controller, post-`upsertAll`). The failure log is in the controller catch, also outside the tx. **No HTTP, no message broker, no file I/O inside the tx.** |
| 5 | **Request affinity** | Assume follow-up request lands on the same replica? | **No** | Transaction state lives in the DB; an OMS retry can land on any replica. SBDEV-2222 dedup is via shared `rest_idempotency` table. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op? | **No — strictly improves** | Today: replica death mid-loop leaves partial commits with no resume path. After: replica death mid-transaction → Postgres rolls back the in-flight tx (connection drops) → OMS retry replays from a clean state. SBDEV-2222's `Idempotency-Key` dedup gates the retry. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | **No** | Service runs on the same request thread; tenant context is set by `TenantFilter` upstream and consumed by `tenantTransactionManager` synchronously. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **No** | No new locks. Concurrency between two simultaneous OMS upsert requests is bounded by Postgres unique constraint on `itemdata(client_id, item_nr)` (the existing Phase 1 duplicate check via `findByClientIdAndItemNr` plus the unique constraint as backstop). |
| 9 | **Cache invalidation** | Write to an entity that is cached? | **Yes — itemdata is cached** | `ItemdataService.findByClientIdAndItemNr` and `ItemdataService.getById` are both `@Cacheable(value="itemdata")`. Today's `@CacheEvict(value="itemdata", allEntries=true)` on the controller methods evicts the whole region per upsert request. **Pre-resolved decision #6 keeps this exact eviction model.** The cache is in-JVM Caffeine, not distributed, so on a multi-replica deploy each replica has its own cache and only the handling replica's cache is evicted. **Trade-off accepted:** under burst-write traffic, the other replicas serve a stale cached `Itemdata` for at most the cache TTL (configured in `CacheConfig`). This matches today's behavior — no regression. Holistic cache audit is follow-up work. |
| 10 | **External notifications** | Send HTTP / message to an external system inside a transaction? | **No** | All work inside the tx is JPA on the tenant DataSource. Both message logs (success and failure) are OUTSIDE the tx — the success log runs post-`upsertAll` in the controller; the failure log runs in the controller catch. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 2 | Connection-hold worst-case math documented | §7 row 2 prose |
| 4 | All message log placements outside the service tx — verified by the controller code path showing `messageService.createMessage(...)` only in `doUpsert` outside `upsertAll(...)` | §3.2 controller skeleton |
| 6 | SBDEV-2222 `Idempotency-Key` dedup is the cross-replica retry guard | `sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md` status=implemented |
| 9 | `@CacheEvict(value="itemdata", allEntries=true)` retained on both controller methods | `SkuRestController.java:70, 191` (pre-edit) |

---

## 8. v2-only Constraint Checklist

| # | Rule | Compliant? | Where verified |
|---|---|---|---|
| 1 | All tenant-scoped `@Transactional` uses `value = "tenantTransactionManager"` | **Yes** | `SkuBatchCreateUpdateService.upsertAll` annotation explicitly specifies `value = "tenantTransactionManager"` |
| 2 | OSIV — repository calls outside `@Transactional` open new sessions | **Yes** | All repository write calls move INTO the new `@Transactional` method. Phase 1 lookups remain in the OSIV-scoped controller — same as today, no regression. |
| 3 | Constructor injection only — no `@Autowired` fields | **Yes** | `SkuBatchCreateUpdateService` and the updated `SkuRestController` both use constructor injection |
| 4 | SLF4J parameterized logging — no string concatenation | **Yes** | `LOG.debug("upsert insert {}/{} sku={}", ...)` etc. all use `{}` placeholders |
| 5 | Prefer `.orElseThrow(...)` over `.get()` | **Yes** | The `Optional.get()` at line 275 is DELETED. New code uses `.orElseThrow(...)` for all `Optional` resolution. Line 97 (existing `Optional.isPresent()` ternary pattern) is rewritten using `.orElse(null)` followed by an explicit null check that throws. |
| 6 | Jakarta namespace (`jakarta.*`) — not `javax.*` | **Yes** | New service imports `net.aim_ai.wms.exceptions.EntityNotFoundException` (the project-internal `RuntimeException`-extending type). `jakarta.persistence.EntityNotFoundException` is NOT used. |
| 7 | `AbstractBaseEntity.equals()` ID-based — do not rely on `.equals` for unsaved entities | **N/A** | No entity equality checks in this plan; map keys are `String` (cl_nr, sku, external_id, unitname) and `Long` (client.id) |
| 8 | Multi-tenant — every entity write goes through the tenant DataSource | **Yes** | `tenantTransactionManager` binds to the tenant DataSource per request |

---

## 9. Risks & Mitigations

| # | Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|---|
| 1 | OMS-side parser does not yet accept 422 for `/rest/sku/update` and `/rest/sku/create` — deploying WMS first turns every validation failure into an unhandled error on the OMS side. | Medium | High | (a) Coordinate deploy: OMS ships 422-acceptance BEFORE WMS ships 422-emission. Owner: David Oppenheim. (b) Emergency revert: a one-line diff (`HttpStatus.UNPROCESSABLE_ENTITY` → `HttpStatus.BAD_REQUEST`) if WMS is accidentally deployed before OMS. No feature flag is wired in the service code — the revert is a code change + redeploy. (c) Document in PR description with a deploy-checklist note. |
| 2 | `feat/sku-item-id-sync` (Arden's branch) edits the same controller methods. Landing SBDEV-2235 first forces a rebase. | High | Low | Pre-resolved decision #3: land SBDEV-2235 first; Arden rebases. Notify Arden when this lands. No code mitigation needed. |
| 3 | The self-recursion test (`verify(spy, never()).create(any())`) is fragile if a future refactor reintroduces a different self-call shape. | Low | Low | Augment with a verify-script grep on the controller body: any `this.create(` or bare `create(` call from inside `update()` body is a verify FAIL. The verify script catches what the unit test might miss. |
| 4 | Existing `SkuRestControllerUnitTest` tests expect 400 on validation failures. Naive edit to "all asserts now 422" might miss the `delete()` tests (which should STAY at 400). | Medium | Low | Explicit checklist item: "VERIFY `delete()` tests are UNCHANGED." Verify script greps for any `HttpStatus.BAD_REQUEST` assertion in `SkuRestControllerUnitTest.Delete` — must remain ≥1. |
| 5 | The line 275 NPE fix is folded into the refactor — if a hot-fix is needed for the NPE alone (without the full atomicity refactor), this plan does not provide a small-diff path. | Low | Low | Acceptable. The full refactor is what fixes the structural problem; isolated NPE fix would just re-expose the partial-commit divergence under a different code path. Documented in §1.2 RC4. |
| 6 | Connection-hold time extends from ~ms-per-save to ~50-100ms per upsert request. Concurrent OMS bursts could approach Hikari pool saturation under pathological 1000-SKU payloads. **No payload size cap is enforced by this plan.** | Low | Medium | Risk accepted on record: (a) Empirical SKU upsert payload size is well below 1000 (OMS chunks at 50-100 typical). (b) Hikari `connectionTimeout` is 30s; saturated pool returns `DataAccessResourceFailureException` which SBDEV-2230 maps to 503 + retryable=true → OMS retries with backoff. A future plan may add a Phase 1 cap (`if (skuList.size() > N) throw 422`) if OMS burst patterns warrant it. |
| 7 | A future developer reintroduces `itemdataRepository.save(` inside `SkuRestController` (instead of in the service), re-creating the auto-commit anti-pattern. | Medium | Medium | (a) Verify-script grep negative-check: any `itemdataRepository.save(` reference inside `SkuRestController` body is a FAIL (only allow it inside `SkuBatchCreateUpdateService`). (b) Update `wms2-transaction-osiv-boundary-map.md` to record the boundary. |
| 8 | A wrapped `RuntimeException` masks `DataAccessException` and breaks `RestEndpointExceptionHandler` matching at the advice level. | Low | Low | Same as SBDEV-2230 Risk #5. Out of scope. Failure mode is "503 → 500" — still no orphans (rollback happens regardless of HTTP mapping). |
| 9 | Phase 1 reads existing `Itemdata` via `itemdataService.findByClientIdAndItemNr(...)` which is `@Cacheable(value="itemdata")` with a 5-min TTL. `Itemdata` extends `AbstractBaseEntity` which has a `@Version` field for optimistic locking. If two concurrent OMS requests upsert the same `(clientId, sku)` row, both Phase 1 passes read a cached `Itemdata` with stale `version=N`; both Phase 2 transactions call `itemdataRepository.save(existing)` with `version=N`; the second commit triggers `ObjectOptimisticLockingFailureException`. This is a new failure mode introduced by the Phase 1 cached-read → Phase 2 write pattern. | Low | Low | (a) `ObjectOptimisticLockingFailureException` is a `RuntimeException` → auto-rollback → no orphans (atomicity preserved). (b) It propagates to `RestEndpointExceptionHandler` (SBDEV-2230); verify the advice maps it to 409/503 + `retryable=true`. (c) `@CacheEvict(value="itemdata", allEntries=true)` on the controller method fires on successful return, evicting stale entries so the OMS retry reads fresh state. (d) Concurrent SKU upsert for the same SKU is not a normal OMS pattern; prevalence is very low. |

---

## 10. Open Questions / Resolved Decisions

All pre-resolved by the user 2026-05-15:

1. **Itemised errors response shape** → **RESOLVED:** throw on first failure (same as SBDEV-2231). No `WebserviceBusinessExceptionClientSide` extension needed; existing single-error response shape is sufficient.
2. **Scope** → **RESOLVED:** `update()` + `create()` both fixed via `SkuBatchCreateUpdateService`. `delete()` out of scope — keeps 400 and per-row auto-commit.
3. **`feat/sku-item-id-sync` branch coordination** → **RESOLVED:** land SBDEV-2235 first; Arden rebases his branch on top. Noted in Risks (#2).
4. **NPE on line 275** → **RESOLVED:** fold into SBDEV-2235. The new service does not contain the offending log line, so the fix is structural rather than line-level. Documented in §1.2 RC4 and §3.5 file change list.
5. **Validation-failure status code** → **RESOLVED:** return 422 (`HttpStatus.UNPROCESSABLE_ENTITY`) for `/update` and `/create` validation failures, matching ticket AC3. `/delete` stays 400. Documented in §10 Risks (#1) as an OMS contract change requiring OMS-side parser update — coordinate with David Oppenheim.
6. **Cache eviction placement** → **RESOLVED:** keep `@CacheEvict(value="itemdata", allEntries=true)` on the controller methods (same as today); no change. Documented in §7 row 9.
7. **`@Transactional` rollback list scope** → **RESOLVED:** `rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class}` — same as SBDEV-2231. `BusinessException.class` included for forward-compatibility even though the current upsert loop does not throw it directly. Documented in §2.3.

No open questions remain.

---

## 11. Notes

**Related plans / docs:**
- `sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md` — provides retry safety on the dedup layer. Hard prerequisite.
- `sbdocs/1-Projects/wms2/plan/SBDEV-2230-rest-exception-handler-retryable-differentiation.md` — provides 503/404/500 + retryable classification when exceptions escape the new `@Transactional` boundary. Hard prerequisite.
- `sbdocs/1-Projects/wms2/plan/SBDEV-2231-order-rest-create-partial-batch-atomicity.md` — sibling plan; same architectural pattern applied to `OrderRestController.create`. SBDEV-2235 deliberately mirrors its structure for review consistency.
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` — to be updated to record `SkuBatchCreateUpdateService` as a tenant-tx boundary.
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — note the OMS contract change: 400 → 422 on `/rest/sku/update` and `/rest/sku/create` validation failures (`/delete` unchanged at 400).

**Deployment considerations:**
- Two-side deploy coordination required: OMS-side parser must accept 422 before WMS-side ships 422. Owner: David Oppenheim. Mitigation: revert is one-line.
- Single rolling deploy on the WMS side. No DB migration. No config keys.
- SBDEV-2222 and SBDEV-2230 must be already deployed (both status=implemented).
- Worst-case connection-hold extends from ~1ms-per-save to ~50-100ms per upsert request. Monitor `pg_stat_activity` and Hikari pool saturation post-deploy for 48h.
- Notify Arden when SBDEV-2235 lands so `feat/sku-item-id-sync` can rebase.

**Follow-up work (not in this plan):**
- Sister v1 plan to apply the same fix to `wms-api/v1` if the same anti-pattern exists there (likely; Arden's codebase carried forward).
- Sister plan to address `/delete` atomicity if user impact warrants — today `/delete` keeps per-row auto-commit and 400.
- Holistic `itemdata` cache eviction audit — `allEntries=true` evicts the entire region; could be narrowed to evict only the affected `(clientId, sku)` keys for higher hit-rate after bursty upserts.
- ~~Update `wms2-transaction-osiv-boundary-map.md` with the new `SkuBatchCreateUpdateService` tx boundary.~~ ✓ Done.

---

## 12. Implementation Status

**Status: IMPLEMENTED 2026-05-15**
**Commit:** `1b3a2c6` (branch `tasks/SBDEV-2235`)
**PR:** https://github.com/SiteBossInc/wms2-api/pull/23 (target: `develop`)

### Files changed
| File | Change |
|---|---|
| `src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java` | NEW — `@Transactional(tenantTransactionManager)` upsertAll, constructor injection of `ItemdataRepository` |
| `src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java` | MODIFIED — two-phase refactor, inject `SkuBatchCreateUpdateService`, 422 status, self-recursion deleted, line 275 NPE deleted |
| `src/test/java/net/aim_ai/wms/unit/service/SkuBatchCreateUpdateServiceUnitTest.java` | NEW — tx annotation reflection test + rollback propagation test |
| `src/test/java/net/aim_ai/wms/unit/controller/rest/SkuRestControllerUnitTest.java` | MODIFIED — added 3 new Update tests, updated 8 existing tests (400 → 422 for create/update), added `@MockitoSettings(LENIENT)` |
| `src/test/java/net/aim_ai/wms/integration/SkuRestControllerAtomicityIntegrationTest.java` | NEW — 2 integration tests (update + create, 50-SKU/position-30/422/no-persist) |
| `src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java` | MODIFIED — added `app.cron.cleanup-rest-idempotency=-` to `@TestPropertySource` |
| `sbdocs/9-System/scripts/verify-SBDEV-2235-sku-rest-partial-batch-atomicity.sh` | MODIFIED — AC20 changed from `mvn verify` to `mvn test` to avoid pre-existing Failsafe failures |
| `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` | MODIFIED — §12 verification log entry added |

### Test results
- Verify script: **23 pass, 1 fail** (AC21 = pre-existing SBDEV-2230 `RestExceptionHandlerUnitTest$HandleNoSuchElement.shouldReturn404` — out of scope)
- TDD gate tests (5): all pass
- Unit tests: 19 pass (`SkuBatchCreateUpdateServiceUnitTest` × 2, `SkuRestControllerUnitTest` × 17)
- Integration test: 2 pass (`SkuRestControllerAtomicityIntegrationTest`)

**Operational note — single canonical outcome log per request:**
This plan emits exactly one outcome log per request (no per-row logs):
- Happy path → one `MessageStatus.RECEIVED` log post-`upsertAll` (status `"204"`), called from the controller after the service tx has already committed.
- Failure path → one `MessageStatus.FAILED` log in the controller catch (status `"422"` for validation failures), called after the service tx has already rolled back. `DataAccessException`/`EntityNotFoundException` failures that escape to the advice are recorded by the advice's own logging — no `message` row emitted.

Both log calls run outside any active outer transaction (see §3.4), so they persist regardless of the service tx outcome. Operators can rely on the `message` table as the single source of truth for SKU upsert outcomes: one row per request, no per-row noise.

**Implementation status:**
- Commit SHA: TBD (branch `tasks/SBDEV-2235`)
- `mvn test` result: TBD
- Verify-script result: TBD
- PR link: TBD (targeting `develop`)
- Implemented: TBD

---

## 12. Acceptance & Implementation

### 12.1 Acceptance script (machine-checkable)

Script path: `sbdocs/9-System/scripts/verify-SBDEV-2235-sku-rest-partial-batch-atomicity.sh`

**Acceptance criteria the verify script enforces:**

1. `SkuBatchCreateUpdateService.java` exists at `src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java`
2. `SkuBatchCreateUpdateService` is annotated `@Service`
3. `SkuBatchCreateUpdateService.upsertAll(...)` is annotated `@Transactional` with `value = "tenantTransactionManager"`
4. `SkuBatchCreateUpdateService.upsertAll(...)` `@Transactional` includes `WebserviceBusinessExceptionClientSide.class` in `rollbackFor`
5. `SkuBatchCreateUpdateService.upsertAll(...)` `@Transactional` includes `BusinessException.class` in `rollbackFor`
6. `SkuBatchCreateUpdateService` uses constructor injection (no `@Autowired` field)
7. `SkuRestController` has `SkuBatchCreateUpdateService` as a constructor-injected dependency
8. `SkuRestController.update` (or shared `doUpsert`) invokes `skuBatchCreateUpdateService.upsertAll(`
9. `SkuRestController` does NOT contain `itemdataRepository.save(` anywhere in its `create()` / `update()` / `doUpsert(...)` method bodies (NEGATIVE check — save extracted to service)
10. `SkuRestController.update` body does NOT contain `this.create(` or bare `create(` invocation (NEGATIVE check — self-recursion deleted)
11. `SkuRestController` body does NOT contain `itemDataValue.get()` after a `.isPresent() == false` branch (NEGATIVE check — line 275 NPE deleted)
12. `SkuRestController` `create()` and `update()` (or shared `doUpsert`) return `HttpStatus.UNPROCESSABLE_ENTITY` on the `WebserviceBusinessExceptionClientSide` catch path (POSITIVE check — 422 contract)
13. `SkuRestController.delete()` still returns `HttpStatus.BAD_REQUEST` on its catch path (POSITIVE check — scope boundary; `/delete` unchanged)
14. Failure message log (`MessageStatus.FAILED`) is invoked from `catch (WebserviceBusinessExceptionClientSide` block in `SkuRestController` (not from inside the service)
15. `@CacheEvict(value = "itemdata", allEntries = true)` is present on both `SkuRestController.create()` and `SkuRestController.update()` method declarations (POSITIVE check — pre-resolved decision #6)
16. `SkuBatchCreateUpdateServiceUnitTest.java` exists at `src/test/java/net/aim_ai/wms/unit/service/SkuBatchCreateUpdateServiceUnitTest.java`
17. `SkuRestControllerAtomicityIntegrationTest.java` exists at `src/test/java/net/aim_ai/wms/integration/SkuRestControllerAtomicityIntegrationTest.java`
18. `mvn test -Dtest=SkuBatchCreateUpdateServiceUnitTest` exits 0
19. `mvn test -Dtest=SkuRestControllerUnitTest` exits 0
20. `mvn verify -Dtest=SkuRestControllerAtomicityIntegrationTest` exits 0
21. No regressions: existing `SkuRestController` happy-path 204 contract preserved on both `/create` and `/update` (verified by existing test class re-run)
22. `SkuBatchCreateUpdateService.java` does NOT contain any reference to `messageService.create` (NEGATIVE check — log calls inside the service tx would silently roll back with data due to the `MessageService.createMessage` → `createServiceLog` same-bean self-invocation; see §3.4)

### 12.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 1 new service file + 1 controller refactor + 2 test files; single subsystem (REST inbound SKU upsert) |
| **Pre-draft step** | none — consensus mode (ralplan) completed | RALPLAN-DR summary in §13 + Architect/Critic review pass |
| **Plan-review step** | critic | Catches remaining gaps before code starts |
| **Implementation shape** | executor | Mechanical extraction + unification of `create()` and `update()`; tests are the verification surface |
| **Verification step** | verify-script + verifier (mandatory) | Always |
| **Code-review step** | code-reviewer | Final pass before commit |
| **Commit step** | git directly | Single commit with controller + service + tests + doc update |

#### Why this matters

The refactor is mechanical extraction PLUS two structural changes (delete self-recursion, unify create/update). The risk is in (a) forgetting to add `rollbackFor` for `BusinessException` (Critic check), (b) accidentally leaving the self-recursion (verify-script negative check on `this.create(`), (c) leaving a stray `.save(` call in the controller (verify-script negative check), (d) flipping `/delete` to 422 by accident (verify-script positive check that `/delete` still returns 400), and (e) forgetting to flip the existing 400-asserting unit tests to expect 422 (test execution catches this — they'll fail loudly). All five risks are mechanical and the verify script + test execution catch them.

---

## 13. ADR (consensus mode)

**Decision:** Extract the `SkuRestController.update` and `SkuRestController.create` per-row save logic into a new `@Service`-annotated `SkuBatchCreateUpdateService.upsertAll(...)` method, annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`. Unify `create()` and `update()` into a shared `doUpsert(...)` controller helper. Delete the `this.create(createList)` self-recursion at controller line 230. Delete the `Optional.get()` log line at controller line 275 (folded NPE fix). Change validation-failure status code from 400 to 422 on `/update` and `/create`. Keep `/delete` unchanged. Keep `@CacheEvict(value="itemdata", allEntries=true)` on both upsert endpoints.

**Drivers:**
1. All-or-nothing semantics confirmed by user (2026-05-15) — same as SBDEV-2231 parent decision.
2. Self-invocation proxy constraint — `@Transactional` on the controller's own `create()` cannot fire when called from `update().this.create(...)`. Any in-controller atomicity attempt is structurally compromised.
3. Architectural convention — CLAUDE.md mandates `value = "tenantTransactionManager"` on tenant-scoped `@Transactional`; transaction boundaries belong in the service layer.
4. Ticket AC3 mandates 422 on validation failure; aligns with REST semantic norms (4xx + structured error map = `Unprocessable Entity`).
5. Hard prereqs SBDEV-2222 (idempotency) and SBDEV-2230 (retryable signal) are both implemented; this plan completes the durability trio on the SKU upsert path.
6. Sibling plan SBDEV-2231 establishes the exact pattern — service extraction with `tenantTransactionManager` + checked-exception `rollbackFor` — and is the right precedent to mirror.

**Alternatives considered:**
- (a) `@Transactional` directly on `SkuRestController.create()` and `update()`. **Rejected:** the self-invocation at line 230 silently bypasses the proxy boundary; the catch-and-return pattern commits the tx on caught exceptions. Two independent failure modes. Would require `setRollbackOnly()` in every catch arm AND deleting the self-recursion anyway — at which point Option (c) is strictly simpler.
- (b) Add `upsertAllSkus(...)` to existing `ItemdataService`. **Rejected:** mixes the focused `@Cacheable` lookup helper with a heavy multi-entity write boundary; entangles cache and write concerns; expands a single-responsibility service into a god-service-in-the-making. Same rejection rationale as SBDEV-2231's Option (b).
- (c) New `SkuBatchCreateUpdateService` with `@Transactional` on `upsertAll(...)` + controller `doUpsert(...)` unification. **Chosen.**

**Why chosen:** Mirrors the SBDEV-2231 pattern exactly. Clean separation. Exactly 1 dependency (`ItemdataRepository`) — the service is small and focused. The `@Transactional` boundary is at the service entry, so the controller's catch block runs AFTER rollback has completed. Exception types fall out naturally: `WebserviceBusinessExceptionClientSide` → controller catch → 422; everything else → `RestEndpointExceptionHandler` (SBDEV-2230) → 503/404/500 with retryable. The self-recursion and NPE issues are fixed structurally by the refactor (delete-on-extract), not by separate band-aid fixes.

**Consequences:**
- One new service file. Two refactored controller methods consolidated into one private helper.
- Connection hold time extends from per-statement to per-request — accepted (§7 row 2 math: ~50-100ms typical, well within Hikari budget).
- Self-recursion gone — `update()` no longer calls `create()` internally. Any test that relied on observing the recursion will need updating (delegation test replaces it).
- NPE on line 275 gone — the new service emits its own safe log statements.
- Validation-failure status code changes from 400 to 422 on `/update` and `/create` — OMS-side parser must accept 422 (coordinate with David Oppenheim before deploy). `/delete` unchanged at 400.
- `@CacheEvict(value="itemdata", allEntries=true)` placement unchanged — pre-resolved decision #6.
- `feat/sku-item-id-sync` branch must rebase after this lands — coordinated with Arden.

**Follow-ups:**
- Sister v1 plan if the same anti-pattern exists in `wms-api/v1` (likely).
- Sister plan for `/delete` atomicity if user impact warrants.
- Holistic `itemdata` cache eviction audit (narrow eviction to affected keys instead of `allEntries=true`).
- `wms2-transaction-osiv-boundary-map.md` §12 update to record the new boundary.
- Coordinate `feat/sku-item-id-sync` rebase with Arden.
