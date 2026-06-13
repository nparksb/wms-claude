---
title: "Fix: PICKING_FINISHED OMS Notification Silently Dropped (Double afterCommit)"
ticket: ""
ticket_url: ""
type: "bug"
priority: "critical"
status: "archived"
project: ["wms2"]
version: "v2"
requester: ""
created: "2026-05-20"
updated: "2026-05-20"
pr: "https://github.com/SiteBossInc/wms2-api/pull/31"
commit_pra: "9df17bc"
commit_prb: "f559b3d"
related:
  - "260520-wms2-picking-finished-oms-notification-dropped"
  - "260521-wms2-qa-blocked-tote-label-and-message-log-gap"
  - "260520-content-derived-idempotency-key"
  - "SBDEV-2221"
  - "SBDEV-2238"
tags:
  - plan
  - outbox
  - oms-notification
  - picking
db_verified: true
---

# Fix: PICKING_FINISHED OMS Notification Silently Dropped (Double afterCommit)

**Type:** Bug | **Version:** v2 | **Priority:** Critical (production OMS sync broken)
**Status:** Implemented — [PR #31](https://github.com/SiteBossInc/wms2-api/pull/31) — verify script 12/12 ✅, `mvn compile` clean
**Date:** 2026-05-20 | **Implemented:** 2026-05-20

**Files changed (8, +670/-80):**
- `service/OmsNotificationService.java` — PR-A guard (`isSynchronizationActive() && isActualTransactionActive()`)
- `service/ManageOrderService.java` — `buildPickedPayloadJson` + `buildPickingStartedPayloadJson` helpers; old methods `@Deprecated` + retained
- `service/PickingorderBusinessService.java` — Fix A (outbox enqueue in `finishPickingOrder`), Fix C (`confirmPick`), `reenqueuePickingFinishedIfMissing`
- `service/mobile/MobilePickingService.java` — Fix B safety net in Case 1
- `unit/service/OmsNotificationServiceUnitTest.java`, `PickingorderBusinessServiceUnitTest.java`, `ManageOrderServiceUnitTest.java`, `mobile/MobilePickingServiceUnitTest.java` — new/updated unit tests
**Related report:** `sbdocs/3-Resources/reports/260520-wms2-picking-finished-oms-notification-dropped.md`

---

## 0. Affected Sites (Enumeration Before Drafting)

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `service/PickingorderBusinessService.java:246-281` | `finishPickingOrder` — registers Callback A; Callback A body calls `customerOrderPicked` → `sendAfterCommit` → Callback B silently dropped by Spring | **Yes — primary** | **Yes (Fix A, PR-B)** |
| 2 | `service/PickingorderBusinessService.java:504-523` | `confirmPick` — identical pattern for `ORDER_BATCH_PICKING_STARTED` via `customerOrderPickingStarted` | **Yes — adjacent** | **Yes (Fix C, PR-B)** |
| 3 | `service/mobile/MobilePickingService.java:705-709` | `releaseRegularPickingOrder` Case 1 — early-return on `state > PICKED` with no recovery check for `pickingconfirmationsent=false` | Adjacent (compounding gap) | **Yes (Fix B, PR-B)** |
| 4 | `service/OmsNotificationService.java:65` | `sendAfterCommit` uses `isSynchronizationActive()` to gate synchronization — true during `afterCommit` loop, causing silent discard of nested registration | **Root cause** | **Yes (PR-A hotfix)** |
| 5 | `service/ManageOrderService.java:219-270` | `customerOrderPicked` — payload assembly extracted to `buildPickedPayloadJson` helper; method **RETAINED** (not deleted) — called by `CustomerorderBatchService:764` | Downstream of Fix A | **Yes — extract helper, keep method** |
| 6 | `service/ManageOrderService.java:187-217` | `customerOrderPickingStarted` — same as row 5 for STARTED; **RETAINED** — called by `CustomerorderBatchService:763` | Downstream of Fix C | **Yes — extract helper, keep method** |
| 7 | `service/CustomerorderBatchService.java:763-764` | `runClubLine` Phase 4 — calls both methods **outside any TX** (no `@Transactional` on `runClubLine`; Phase 4 javadoc: "fire-and-forget, outside any transaction"); `isSynchronizationActive()=false` → `doSend` fires synchronously today — correct | Not double-nested | **No change required; future outbox migration out of scope** ⚠️ See §8 Risk 5 |
| 8 | Tests | Unit + integration for picking-finish and picking-started paths | Need update | **Yes** |

---

## 1. Problem Statement

**Symptom:** After a WMS v2 rapid-pick flow completes, OMS reports "No Parcel Found" for the tote (e.g., T-2168, `pickingorder.id=29506341`). The WMS backend log shows:

```
DEBUG end releaseRegularPickingOrder - order already finished. pickingOrderId=29506341
```

No `ORDER_BATCH_PICKING_FINISHED` POST is ever sent to OMS. OMS never updates to Shipped state. QA flow is permanently blocked for affected orders.

**Affected orders (wms2-wineco-dev, 2026-05-20):**
- `customerorder.id=29506338` — `state=600 (PICKED)`, `pickingconfirmationsent=true`, 0 OMS notifications
- `customerorder.id=29781897` — `state=600 (PICKED)`, `pickingconfirmationsent=true`, 0 OMS notifications

**Reproduction path:**
1. Operator scans final pick item via mobile rapid-pick.
2. `rapidPickingScanSource` → `finishPickingOrder` runs inside `@Transactional("tenantTransactionManager")`.
3. TX commits with `pickingconfirmationsent=true` and `pickingorder.state=FINISHED` — but **no OMS POST fires** (bug described in §2).
4. A retry or second call to `releasePickingOrder` hits the Case 1 early-exit at `MobilePickingService.java:705` ("order already finished").
5. OMS never receives the notification. Order permanently stranded.

**DB evidence (confirmed via `mcp__wms2-wineco-dev__execute_sql`):**
- `pickingorder.id=29506341` — `state=700 (FINISHED)`
- Both COs above — `state=600 (PICKED)`, `pickingconfirmationsent=true`
- 0 rows in `message WHERE process='ORDER_BATCH_PICKING_FINISHED'` for these orders
- 0 rows in `outbox_message` for these orders

---

## 2. Root Cause Analysis

### Bug 1 — Double `afterCommit` Registration (Primary)

**Files:** `PickingorderBusinessService.java:256-272` + `OmsNotificationService.java:65`

`PickingorderBusinessService.finishPickingOrder` runs inside `@Transactional("tenantTransactionManager")`. When a CO reaches PICKED:

1. `customerOrder.setPickingconfirmationsent(true)` — will commit with TX.
2. `isSynchronizationActive()` → `true` (inside open TX).
3. Registers **Callback A** (`afterCommit` body: calls `manageOrderService.customerOrderPicked(...)`).

After TX commits, Spring fires Callback A. Inside Callback A:
- `ManageOrderService.customerOrderPicked:266` calls `omsNotificationService.sendAfterCommit(url, payload, PICKING_FINISHED)`.
- `OmsNotificationService.sendAfterCommit:65` checks `isSynchronizationActive()` → **still `true`** ⚠️

**Why `isSynchronizationActive()` is still `true` during `afterCommit`:**

Spring's `AbstractPlatformTransactionManager.processCommit()` executes:
1. `doCommit()` — commits the DB TX
2. `triggerAfterCommit()` — iterates the synchronizations list, fires each `afterCommit()` callback
3. `triggerAfterCompletion()` — fires each `afterCompletion()` callback
4. `cleanupAfterCompletion()` — calls `TransactionSynchronizationManager.clear()`, clears the list

The synchronizations set is **not cleared** between steps 2 and 4. So `isSynchronizationActive()` returns `true` throughout step 2. `sendAfterCommit` registers **Callback B** — but Callback B is added after Spring has already iterated past the insertion point. `cleanupAfterCompletion()` in step 4 discards it without firing. **No HTTP POST. No Message row.**

**The correct signal:**

| API | Inside open TX | Inside `afterCommit` callback |
|-----|----------------|-------------------------------|
| `isSynchronizationActive()` | `true` | **`true`** ← trap |
| `isActualTransactionActive()` | `true` | **`false`** ← correct signal (DB TX already committed) |

### Bug 2 — Identical Double-afterCommit in `confirmPick`

**File:** `PickingorderBusinessService.java:504-523`

Same mechanism: registers an `afterCommit` callback calling `customerOrderPickingStarted` → `sendAfterCommit(ORDER_BATCH_PICKING_STARTED)` → Callback B discarded.

### Bug 3 — No Recovery Path in `releaseRegularPickingOrder` Case 1

**File:** `MobilePickingService.java:705-709`

```java
if (pickingOrder.getState() > WmsConstants.State.PICKED) {
    LOG.debug("end releaseRegularPickingOrder - order already finished. pickingOrderId={}", pickingOrderId);
    return true;  // ← no check for pickingconfirmationsent=false, no OMS recovery
}
```

Orders stranded by Bug 1 are permanently silenced. Every retry of `releasePickingOrder` hits this exit.

---

## 3. Fix Design

### 3.0 Alternatives Considered

| Alternative | Rejected Because |
|---|---|
| **Fix only `OmsNotificationService` guard (PR-A only, skip outbox)** | Closes the silent-discard but leaves fire-and-forget semantics with no retry. OMS downtime still drops notifications. Acceptable as emergency unblock; insufficient as permanent solution. |
| **`@TransactionalEventListener(phase=AFTER_COMMIT)` on `PickingorderBusinessService`** | Decoupled but adds Spring event bus complexity; still fire-and-forget with no retry. Also requires refactoring the caller chain. No delivery guarantee over outbox. |
| **`TransactionSynchronization.afterCompletion(STATUS_COMMITTED)` in Callback A** | Same `isSynchronizationActive()=true` trap applies during `afterCompletion`. Doesn't fix the nested-registration problem. |
| **Full two-PR migration now (skip PR-A)** | PR-B structural migration touches 5 files and requires `260520-content-derived-idempotency-key.md` deployed first. Cannot unblock production today. PR-A is needed as an immediate fix. |
| **Reset `pickingconfirmationsent=false` and rely on existing code + operator retry** | Possible as a one-time recovery for the 2 known stranded orders, but the root cause remains — next pick triggers the same bug again. Not a fix. |

**Decision: Two-PR sequence.** PR-A (emergency, 1 file) → PR-B (structural migration, next sprint).

### 3.1 Approach: Two-PR Sequence

| PR | Scope | Risk | Unblocks |
|----|-------|------|---------|
| **PR-A** | `OmsNotificationService.java` — 1 file, ~12 lines | Minimal | All callers immediately; production pick notifications restored |
| **PR-B** | `PickingorderBusinessService`, `ManageOrderService`, `MobilePickingService` | Medium | At-least-once delivery with retry; stranded-order recovery safety net |

**PR-B prerequisite:** `260520-content-derived-idempotency-key.md` plan must be deployed first. `reenqueuePickingFinishedIfMissing` enqueues outbox rows; without content-derived keys, concurrent re-enqueue calls risk UNIQUE constraint violations on `outbox_message.idempotency_key`.

---

### PR-A — Fix 0: Correct `OmsNotificationService.sendAfterCommit` Guard

**File:** `service/OmsNotificationService.java:65`

**Before:**
```java
if (TransactionSynchronizationManager.isSynchronizationActive()) {
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
        @Override
        public void afterCommit() {
            doSend(urlPath, payload, processType);
        }
        @Override
        public void afterCompletion(int status) {
            if (status == TransactionSynchronization.STATUS_ROLLED_BACK) {
                LOG.warn("TX rolled back — OMS notification suppressed for processType={}, payload size={}",
                    processType, payload != null ? payload.length() : 0);
            }
        }
    });
} else {
    LOG.warn("No active transaction synchronization for processType={}. Sending synchronously.", processType);
    doSend(urlPath, payload, processType);
}
```

**After (2 branches — not 3):**
```java
if (TransactionSynchronizationManager.isSynchronizationActive()
        && TransactionSynchronizationManager.isActualTransactionActive()) {
    // Normal case: inside an open TX. Defer POST until after commit.
    // Both conditions are required: isSynchronizationActive() alone is true DURING
    // the afterCommit callback loop (TX already committed), which would cause
    // registerSynchronization() to enqueue a callback that Spring immediately discards
    // in cleanupAfterCompletion(). isActualTransactionActive()=false is the signal that
    // the DB TX has already committed — i.e., we are in a nested afterCommit context.
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
        @Override
        public void afterCommit() {
            doSend(urlPath, payload, processType);
        }
        @Override
        public void afterCompletion(int status) {
            if (status == TransactionSynchronization.STATUS_ROLLED_BACK) {
                LOG.warn("TX rolled back — OMS notification suppressed for processType={}, payload size={}",
                    processType, payload != null ? payload.length() : 0);
            }
        }
    });
} else {
    // Two scenarios reach this branch:
    // (a) isSynchronizationActive()=true, isActualTransactionActive()=false
    //     → inside an afterCommit/afterCompletion callback; TX already committed.
    //     Registering a new synchronization here would be silently discarded.
    //     Call doSend directly.
    // (b) isSynchronizationActive()=false → non-transactional context (e.g.,
    //     CustomerorderBatchService Phase 4, AdminActionController without @Transactional).
    //     Call doSend directly.
    // Both cases: fire synchronously.
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
        LOG.debug("Nested afterCommit context for processType={} — sending synchronously to avoid discard.",
            processType);
    } else {
        LOG.warn("No active transaction for processType={}. Sending synchronously.", processType);
    }
    doSend(urlPath, payload, processType);
}
```

**Effect:** All 7+ existing callers (including `customerOrderPicked`, `customerOrderPickingStarted`, `customerOrderPalletized`, `customerOrderHeld`, `customerOrderReleaseForPicking`, and BOL-shipped path) immediately start firing `doSend` correctly when called from inside an `afterCommit` callback. **No caller changes required for PR-A.**

**PR-A rollback plan:** Revert the single method. No schema change, no data migration. The only regression risk is if a caller relied on the *silent discard* behavior (impossible, as discarded callbacks produce no observable output). Safe to revert in under 5 minutes.

---

### PR-B — Fix A: Replace Double-afterCommit in `finishPickingOrder` with `outboxService.enqueue`

**File:** `service/PickingorderBusinessService.java:246-281`

**Ordering constraint:** `buildPickedPayloadJson` is called **before** `setPickingconfirmationsent(true)`. If serialization fails, `FacadeException` is thrown (rolls back TX) with the flag still `false` — CO is recoverable on retry. The current code sets the flag before the notification attempt, permanently stranding the order on serialization error.

**`FacadeException` type rationale:** `finishPickingOrder` is annotated `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})`. Throwing `FacadeException` triggers rollback. Throwing `JsonProcessingException` (checked) does not appear in `rollbackFor` and would NOT roll back the TX. Must throw `FacadeException`.

**Before (lines 249-281):**
```java
if (basicService.isProduction()) {
    customerOrder.setPickingconfirmationsent(true);  // ← set BEFORE notification attempt
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
        final Customerorder pickedOrder = customerOrder;
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                try {
                    manageOrderService.customerOrderPicked(
                        new ArrayList<>(Collections.singletonList(pickedOrder)));
                } catch (Exception e) {
                    LOG.error("OMS picked callback failed ...", e);
                }
            }
        });
    } else {
        manageOrderService.customerOrderPicked(
            new ArrayList<>(Collections.singletonList(customerOrder)));
    }
} else {
    LOG.warn("WMS is NOT in production mode");
}
```

**After:**
```java
if (basicService.isProduction()) {
    // Build payload FIRST: if serialization fails, FacadeException rolls back TX
    // and pickingconfirmationsent stays false (order recoverable on retry).
    // Must not call buildPickedPayloadJson after setPickingconfirmationsent(true).
    String urlPath = syspropService.getSysvalue(
        WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_FINISHED_PICKING_URL_KEY);
    String payload = manageOrderService.buildPickedPayloadJson(
        Collections.singletonList(customerOrder));  // throws FacadeException on JsonProcessingException

    customerOrder.setPickingconfirmationsent(true);  // ← set AFTER payload built

    LOG.info("Enqueuing PICKING_FINISHED outbox notification for order={}", customerOrder.getNumber());
    outboxService.enqueue(OutboxMessage.builder()
        .aggregateType("CUSTOMER_ORDER")
        .aggregateId(customerOrder.getId())
        .processType(WmsConstants.MessageProcessType.ORDER_BATCH_PICKING_FINISHED)
        .destinationUrl(urlPath)
        .payload(payload)
        .build());
} else {
    LOG.warn("WMS is NOT in production mode — skipping PICKING_FINISHED for order={}",
        customerOrder.getNumber());
}
```

**`JsonProcessingException` behavior change (documented):**

| Scenario | Pre-fix behavior | Post-fix behavior |
|---|---|---|
| Serialization error in `customerOrderPicked` | `JsonProcessingException` caught at `ManageOrderService.java:261-265`; logged; returns silently. `pickingconfirmationsent=true` already committed. Order permanently stranded. | `buildPickedPayloadJson` wraps as `FacadeException` and throws BEFORE `setPickingconfirmationsent(true)`. TX rolls back. Flag stays `false`. Order recoverable on retry. |

This is a **net improvement**: the pre-fix behavior permanently strands the order with no recovery path. Post-fix, the order can be retried.

---

**New helper: `ManageOrderService.buildPickedPayloadJson`**

```java
/**
 * Builds the JSON payload for the ORDER_BATCH_PICKING_FINISHED OMS notification.
 *
 * Called by PickingorderBusinessService.finishPickingOrder (outbox path, inside TX)
 * and by the legacy customerOrderPicked method (CustomerorderBatchService non-TX path).
 *
 * @param customerOrderList orders to include; cancelled orders are filtered out
 * @return JSON string, or null if list is empty after filtering
 * @throws FacadeException if Jackson serialization fails (triggers TX rollback when
 *         called inside @Transactional(rollbackFor=FacadeException.class))
 */
public String buildPickedPayloadJson(List<Customerorder> customerOrderList) {
    customerOrderList = new ArrayList<>(customerOrderList);
    customerOrderList.removeIf(o -> o.getState() == WmsConstants.State.CANCELED);
    if (customerOrderList.isEmpty()) return null;

    Customerorder representative = customerOrderList.get(0);
    CustomerorderBatch orderBatch = customerorderBatchRepository
        .findById(representative.getOrderbatchId())
        .orElseThrow(() -> new EntityNotFoundException("CustomerOrderBatch", representative.getOrderbatchId()));
    OrderBatchDto orderBatchDto = createOrderBatch(orderBatch);
    final boolean isClub = WmsConstants.OrderBatchType.CLUB.equals(orderBatch.getType());

    List<Customerorder> clubOrdersToSave = new ArrayList<>();
    customerOrderList.forEach(co -> {
        OrderDto orderDto = addOrderToOrderBatch(co, orderBatchDto);
        if (isClub) {
            String toteLabel = String.valueOf(UUID.randomUUID());
            orderDto.setToteLabel(toteLabel);
            co.setHistorytote(toteLabel);
            clubOrdersToSave.add(co);
        } else if (co.getPickingtoteId() != null) {
            Unitload pickingTote = unitloadRepository.findById(co.getPickingtoteId())
                .orElseThrow(() -> new EntityNotFoundException("UnitLoad", co.getPickingtoteId()));
            orderDto.setToteLabel(pickingTote.getLabelid());
        }
    });
    if (!clubOrdersToSave.isEmpty()) {
        customerorderRepository.saveAll(clubOrdersToSave);
    }

    try {
        ObjectMapper mapper = new ObjectMapper();
        mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
        return mapper.writeValueAsString(orderBatchDto);
    } catch (JsonProcessingException e) {
        throw new FacadeException(
            "Failed to serialize ORDER_BATCH_PICKING_FINISHED payload: " + e.getMessage(), e);
    }
}
```

**`customerOrderPicked` (RETAINED, delegates to helper):**

```java
/**
 * Sends the ORDER_BATCH_PICKING_FINISHED OMS notification via sendAfterCommit.
 *
 * ⚠️ Called by CustomerorderBatchService.runClubLine (Phase 4, non-TX context).
 *    For the transactional picking path, use outboxService.enqueue + buildPickedPayloadJson.
 *
 * @deprecated Prefer outboxService.enqueue(buildPickedPayloadJson(...)) for new transactional callers.
 *             CustomerorderBatchService.runClubLine Phase 4 runs outside any TX; outbox migration
 *             for that path is tracked separately and requires TenantContext verification.
 */
@Deprecated
public void customerOrderPicked(List<Customerorder> customerOrderList) {
    String payload = buildPickedPayloadJson(customerOrderList);
    if (payload == null) {
        LOG.debug("customerOrderPicked: empty list after filtering cancelled orders.");
        return;
    }
    String urlPath = syspropService.getSysvalue(
        WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_FINISHED_PICKING_URL_KEY);
    omsNotificationService.sendAfterCommit(urlPath, payload,
        WmsConstants.MessageProcessType.ORDER_BATCH_PICKING_FINISHED);
    LOG.info("customerOrderPicked: sendAfterCommit enqueued for {} order(s)", customerOrderList.size());
}
```

---

### PR-B — Fix B: Safety-Net Re-enqueue in `releaseRegularPickingOrder` Case 1

**File:** `service/mobile/MobilePickingService.java:705-709`

**Dependency:** Deploy `260520-content-derived-idempotency-key.md` plan before this fix. Without content-derived keys, repeated calls to `reenqueuePickingFinishedIfMissing` can produce UNIQUE constraint violations on `outbox_message.idempotency_key`.

**Before:**
```java
if (pickingOrder.getState() > WmsConstants.State.PICKED) {
    LOG.debug("end releaseRegularPickingOrder - order already finished. pickingOrderId={}", pickingOrderId);
    return true;
}
```

**After:**
```java
if (pickingOrder.getState() > WmsConstants.State.PICKED) {
    // Safety net: recover any missed PICKING_FINISHED notifications (pre-fix double-afterCommit bug
    // could commit pickingconfirmationsent=true without the OMS POST ever firing).
    pickingorderBusinessService.reenqueuePickingFinishedIfMissing(pickingOrder);
    LOG.debug("end releaseRegularPickingOrder - order already finished. pickingOrderId={}", pickingOrderId);
    return true;
}
```

**`PickingorderBusinessService.reenqueuePickingFinishedIfMissing`:**

```java
/**
 * Recovery method: enqueues PICKING_FINISHED outbox notifications for customer orders
 * that were stranded by the pre-fix double-afterCommit bug
 * (pickingconfirmationsent=true committed but doSend never called).
 *
 * Idempotent: does nothing if pickingconfirmationsent=true for all linked COs.
 * Requires 260520-content-derived-idempotency-key.md deployed for safe idempotency_key generation.
 * Runs inside the caller's tenantTransactionManager TX (REQUIRED).
 */
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void reenqueuePickingFinishedIfMissing(Pickingorder pickingOrder) {
    List<Customerorder> stranded = customerorderRepository
        .findByPickingorderIdWithState(pickingOrder.getId())
        .stream()
        .filter(co -> co.getState() >= WmsConstants.State.PICKED
                   && co.getState() != WmsConstants.State.CANCELED
                   && (co.getPickingconfirmationsent() == null
                       || !co.getPickingconfirmationsent()))
        .toList();

    if (stranded.isEmpty()) return;

    LOG.warn("reenqueuePickingFinishedIfMissing: {} stranded CO(s) for pickingOrderId={}",
        stranded.size(), pickingOrder.getId());

    for (Customerorder co : stranded) {
        String urlPath = syspropService.getSysvalue(
            WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_FINISHED_PICKING_URL_KEY);
        String payload = manageOrderService.buildPickedPayloadJson(Collections.singletonList(co));
        if (payload == null) continue;

        co.setPickingconfirmationsent(true);
        customerorderRepository.save(co);

        outboxService.enqueue(OutboxMessage.builder()
            .aggregateType("CUSTOMER_ORDER")
            .aggregateId(co.getId())
            .processType(WmsConstants.MessageProcessType.ORDER_BATCH_PICKING_FINISHED)
            .destinationUrl(urlPath)
            .payload(payload)
            .build());

        LOG.info("reenqueuePickingFinishedIfMissing: enqueued PICKING_FINISHED for CO={}", co.getId());
    }
}
```

---

### PR-B — Fix C: Replace Double-afterCommit in `confirmPick` with `outboxService.enqueue`

**File:** `service/PickingorderBusinessService.java:504-523`

Same pattern as Fix A for `ORDER_BATCH_PICKING_STARTED`. Extract `ManageOrderService.buildPickingStartedPayloadJson(List<Customerorder>)` from `customerOrderPickingStarted` (mirror of `buildPickedPayloadJson`). Replace the `registerSynchronization` block with `outboxService.enqueue(...)`. Keep `customerOrderPickingStarted` public — called by `CustomerorderBatchService:763`. Mark `@Deprecated`.

---

## 4. Principles

| ID | Principle | Applied In |
|----|-----------|-----------|
| P1 | **Never delete a publicly-called method without full callsite audit.** `customerOrderPicked` and `customerOrderPickingStarted` are called by `CustomerorderBatchService:763-764`. They are deprecated, not deleted. | §0 row 5-6; Fix A+C |
| P2 | **Build payload before mutating persisted state.** `buildPickedPayloadJson` is called before `setPickingconfirmationsent(true)`. Serialization failure rolls back TX; flag stays `false`; order recoverable. | Fix A ordering constraint |
| P3 | **Transactional outbox for at-least-once delivery.** `outboxService.enqueue` commits atomically with the WMS state change. `OutboxDispatcherJob` delivers with retry. Removes fire-and-forget gap. | Fix A, Fix B, Fix C |
| P4 | **Emergency hotfix must close all callers, not just one.** PR-A patches `OmsNotificationService` (the callsink), not `PickingorderBusinessService` (one caller). All 7+ existing callers benefit immediately. | PR-A Fix 0 |
| P5 | **No cross-plan dependency slip.** `reenqueuePickingFinishedIfMissing` (Fix B) has a hard prerequisite on content-derived idempotency keys. Deployment order is gated and tracked in §7.1. | Fix B, §7.1 |

---

## 5. Architecture Overview

```
Mobile Rapid-Pick Flow (affected path):
═══════════════════════════════════════════════════════════════════════════

PickingController.releasePickingOrder(id)
  └─ MobilePickingService.releaseRegularPickingOrder(id)     [@Transactional("tenantTM")]
       │
       ├─ Case 1: pickingOrder.state > PICKED  ← stranded orders land here
       │    ├─ [NEW Fix B] reenqueuePickingFinishedIfMissing(pickingOrder)
       │    └─ return true
       │
       └─ Case 2: all positions picked
            └─ pickingorderBusinessService.finishPickingOrder(pickingOrder)

        PickingorderBusinessService.finishPickingOrder(po)   [@Transactional("tenantTM")]
          ├─ [NEW Fix A] payload = buildPickedPayloadJson(co)  ← BEFORE flag
          ├─ [NEW Fix A] co.setPickingconfirmationsent(true)   ← AFTER payload
          ├─ [NEW Fix A] outboxService.enqueue(PICKING_FINISHED row)
          └─ TX commits atomically: CO state + flag + outbox row

                          ── up to 15s later ──

        OutboxDispatcherJob → OutboxDispatchService
          └─ POST OMS /ORDER_BATCH_PICKING_FINISHED → QA flow unblocked

PR-A guard (OmsNotificationService):
═══════════════════════════════════════════════════════════════════════════
sendAfterCommit(url, payload, processType):
  isSynchronizationActive() && isActualTransactionActive()
     → registerSynchronization  (open TX: normal case)
  else
     → doSend() directly        (nested afterCommit OR non-TX context)
```

**Key Files:**

| File | Lines | Role |
|------|-------|------|
| `service/OmsNotificationService.java` | 65-85 | **PR-A:** 2-branch guard (`isActualTransactionActive`) |
| `service/PickingorderBusinessService.java` | 246-281, 504-523 | **PR-B Fix A+C:** outbox enqueue; new `reenqueuePickingFinishedIfMissing` |
| `service/mobile/MobilePickingService.java` | 705-709 | **PR-B Fix B:** safety-net recovery call |
| `service/ManageOrderService.java` | 187-270 | **PR-B:** new payload helpers; `customerOrderPicked`/`customerOrderPickingStarted` retained + `@Deprecated` |
| `service/OutboxService.java` | — | Outbox enqueue (existing, no changes) |
| `service/CustomerorderBatchService.java` | 762-764 | **No change** — runs outside TX, `sendAfterCommit` → `doSend` synchronously |

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/OmsNotificationService.java` | **Modify** | PR-A: 2-branch guard with `isActualTransactionActive()` |
| `service/PickingorderBusinessService.java` | **Modify** | PR-B Fix A+C: outbox enqueue; new `reenqueuePickingFinishedIfMissing` method |
| `service/mobile/MobilePickingService.java` | **Modify** | PR-B Fix B: Case 1 safety-net call |
| `service/ManageOrderService.java` | **Modify** | PR-B: `buildPickedPayloadJson`, `buildPickingStartedPayloadJson`; retain + `@Deprecated` public methods |
| `repo/jpa/CustomerorderRepository.java` | **Modify** | PR-B: add `findByPickingorderIdWithState(Long)` if not present |
| Test files (see §7) | **Modify / Add** | Unit + integration for both PR-A and PR-B |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Status |
|---|---|---|
| 1 | `outbox_message` table live in tenant DB (Flyway V2.1.11) | ✅ Deployed (SBDEV-2238 Phase-1) |
| 2 | `OutboxDispatcherJob` live (advisory lock `100008L`) | ✅ Deployed (SBDEV-2238 Phase-2) |
| 3 | `260520-content-derived-idempotency-key.md` plan deployed | **Hard prerequisite for PR-B Fix B** |
| 4 | `app.outbox.dispatcher.enabled=true` (or equivalent sysprop) per tenant | Verify before PR-B deploy |
| 5 | DB recovery for known stranded COs | Day-of PR-A deploy (see §7.2 step 5) |

### 7.2 PR-A Steps (Emergency Hotfix)

1. **Modify `OmsNotificationService.sendAfterCommit`** — replace the 2-branch guard (line 65) with the 2-branch guard using `&& isActualTransactionActive()`. See §3 PR-A Fix 0 Before/After.
2. **Add unit tests** — `OmsNotificationServiceUnitTest`: 3 scenarios (active TX, nested afterCommit, no TX). See §8 Unit Tests (PR-A).
3. **Verify compilation:** `mvn -q -DskipTests compile` — must succeed.
4. **Commit:** `fix(wms2): guard OmsNotificationService against nested afterCommit registration`
5. **Manual DB recovery for known stranded orders (wms2-wineco-dev):**

```sql
-- 1. Confirm orders are still stranded (PICKED, flag set, no outbox row)
SELECT co.id, co.state, co.pickingconfirmationsent
FROM customerorder co
WHERE co.id IN (29506338, 29781897);

-- Expected: state=600, pickingconfirmationsent=true for both rows

-- 2. Reset flag so next releasePickingOrder re-enters the notification block
-- (PR-A's doSend guard is now in place; sendAfterCommit will call doSend directly from Callback A)
UPDATE customerorder
SET pickingconfirmationsent = false,
    modified = NOW()
WHERE id IN (29506338, 29781897)
  AND state = 600;  -- PICKED only; do not reset SHIPPED/CANCELED

-- 3. Verify reset
SELECT id, state, pickingconfirmationsent FROM customerorder WHERE id IN (29506338, 29781897);

-- 4. After operator or admin triggers releasePickingOrder for these orders,
--    verify message row was created:
SELECT id, process, status, created FROM message
WHERE process = 'ORDER_BATCH_PICKING_FINISHED'
ORDER BY created DESC LIMIT 5;
```

6. **Deploy to dev** — trigger a pick completion, confirm a `message` row with `process='ORDER_BATCH_PICKING_FINISHED'` appears.

### 7.3 PR-B Steps (Structural Migration — deploy after §7.1 prerequisite #3)

1. **`ManageOrderService`** — add `buildPickedPayloadJson` (extract body from `customerOrderPicked`; wrap `JsonProcessingException` as `FacadeException`). Add `buildPickingStartedPayloadJson` (same for `customerOrderPickingStarted`). Mark both old public methods `@Deprecated` with Javadoc noting the club-line caller.
2. **`PickingorderBusinessService.finishPickingOrder`** — replace `registerSynchronization` block with `outboxService.enqueue`; move `setPickingconfirmationsent(true)` to AFTER `buildPickedPayloadJson` call.
3. **`PickingorderBusinessService.confirmPick`** — same for `ORDER_BATCH_PICKING_STARTED` using `buildPickingStartedPayloadJson`.
4. **`PickingorderBusinessService.reenqueuePickingFinishedIfMissing`** — add new method.
5. **`MobilePickingService.releaseRegularPickingOrder`** Case 1 — add `reenqueuePickingFinishedIfMissing` call.
6. **`CustomerorderRepository`** — add `findByPickingorderIdWithState` JPQL query if not present. Use safe null/empty-string pattern per CLAUDE.md.
7. **Run tests:** `mvn test -Dtest=PickingorderBusinessServiceUnitTest,MobilePickingServiceUnitTest,ManageOrderServiceUnitTest,OmsNotificationServiceUnitTest`.
8. **Run TDD gate** (`wms-tdd-gate`): write failing tests for ACs 4-13 before implementing PR-B fixes.
9. **Commit:** `feat(wms2): migrate picking-finished OMS notification to transactional outbox`

---

## 8. Testing Plan

### 8.1 Unit Tests (PR-A) — `OmsNotificationServiceUnitTest`

- `givenActiveTx_whenSendAfterCommit_thenRegistersTransactionSynchronization()` — mock `isSynchronizationActive()=true`, `isActualTransactionActive()=true` → verify `registerSynchronization` called; `doSend` NOT called directly.
- `givenNestedAfterCommit_whenSendAfterCommit_thenSendsSynchronously()` — mock `isSynchronizationActive()=true`, `isActualTransactionActive()=false` → verify `doSend` called directly; NO `registerSynchronization`.
- `givenNoTx_whenSendAfterCommit_thenSendsSynchronously()` — mock `isSynchronizationActive()=false` → verify `doSend` called directly.
- `givenNullUrl_whenSendAfterCommit_thenCreatesFailedMessage()` — existing coverage, must still pass.

### 8.2 Unit Tests (PR-B) — `PickingorderBusinessServiceUnitTest`

- `givenPickedCO_productionMode_whenFinishPickingOrder_thenEnqueuesOutboxRow()` — verify `outboxService.enqueue` called with `processType=ORDER_BATCH_PICKING_FINISHED`; `pickingconfirmationsent=true` set.
- `givenSerializationFails_whenFinishPickingOrder_thenFacadeExceptionThrownAndNoEnqueue()` — mock `buildPickedPayloadJson` throwing `FacadeException` → verify `outboxService.enqueue` NOT called; `pickingconfirmationsent` still `false`.
- `givenAlreadySentCO_whenFinishPickingOrder_thenNoEnqueue()` — `pickingconfirmationsent=true` → no enqueue.
- `givenNonProductionMode_whenFinishPickingOrder_thenNoEnqueue()`.
- `givenStrandedCO_whenReenqueuePickingFinishedIfMissing_thenEnqueuesAndSetsFlag()`.
- `givenNoStrandedCOs_whenReenqueuePickingFinishedIfMissing_thenNoEnqueue()`.
- `givenCanceledCO_whenReenqueuePickingFinishedIfMissing_thenSkipped()`.

### 8.3 Unit Tests (PR-B) — `ManageOrderServiceUnitTest`

- `givenValidOrders_whenBuildPickedPayloadJson_thenReturnsJsonString()`.
- `givenEmptyList_whenBuildPickedPayloadJson_thenReturnsNull()`.
- `givenSerializationError_whenBuildPickedPayloadJson_thenThrowsFacadeException()`.
- `givenValidOrders_whenCustomerOrderPicked_thenDelegatesToHelperAndCallsSendAfterCommit()` — verifies the `@Deprecated` method still works for the club-line path.

### 8.4 Unit Tests (PR-B) — `MobilePickingServiceUnitTest`

- `givenFinishedPickingOrderWithStrandedCO_whenRelease_thenCallsReenqueuePickingFinishedIfMissing()`.
- `givenFinishedPickingOrderAllSent_whenRelease_thenReenqueueCalledButProducesZeroEnqueues()`.

### 8.5 Integration Tests — `PickingorderBusinessServiceH2Test` / Testcontainers

- Full path: create PO + CO in PICKED state, call `finishPickingOrder` in production mode, assert exactly 1 `outbox_message` row with `aggregate_id=co.id`, `process_type='ORDER_BATCH_PICKING_FINISHED'`, `status='PENDING'`. Assert `pickingconfirmationsent=true` on CO.
- Rollback scenario: mock `buildPickedPayloadJson` to throw `FacadeException` mid-TX → assert 0 `outbox_message` rows; `pickingconfirmationsent=false` on CO.
- `reenqueuePickingFinishedIfMissing`: set up CO with `pickingconfirmationsent=false, state=PICKED` → call method → assert 1 outbox row, flag set to `true`.

### 8.6 Manual Test Plan

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Happy path — rapid pick to completion | wms2-wineco-dev | Scan final item via mobile rapid-pick; wait up to 15s | `SELECT * FROM outbox_message WHERE process_type='ORDER_BATCH_PICKING_FINISHED' AND status='SENT'` — 1 row | |
| Double-call idempotency | wms2-wineco-dev | Call `releasePickingOrder` twice for same order | Second call: CO has `pickingconfirmationsent=true`; 0 additional outbox rows | |
| Non-production mode | dev (`basicService.isProduction()=false`) | Pick completion | No outbox row, WARN log present | |
| Stranded order recovery (Fix B) | wms2-wineco-dev | Run recovery SQL §7.2; call `releasePickingOrder` when PO in FINISHED state | `reenqueuePickingFinishedIfMissing` fires; outbox row created; flag set | |
| OMS QA unblocked | OMS side | Complete pick; wait 15s | OMS QA flow unblocked; no "No Parcel Found" | |
| `CustomerorderBatchService` club-line not broken | wms2-wineco-dev | Run a club-line batch | `customerOrderPicked` fires via `sendAfterCommit` → `doSend`; OMS receives PICKING_FINISHED notification (legacy path unchanged) | |

---

## 9. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|------|--------|------------|
| 1 | `JsonProcessingException` now rolls back TX | Medium — picking state reverts (pre-fix: stranded silently) | Build payload before setting flag (§4 P2). Alert on `FacadeException` in `finishPickingOrder`. Net improvement over silent strand. |
| 2 | `reenqueuePickingFinishedIfMissing` deployed before content-derived idempotency key | Medium — UNIQUE `idempotency_key` constraint violation on `outbox_message` for repeated re-enqueues | Hard prerequisite in §7.1 #3. Gate PR-B deploy on it. |
| 3 | `customerOrderPicked`/`customerOrderPickingStarted` accidentally deleted | High — compilation failure | Methods retained and marked `@Deprecated` only. §4 P1. |
| 4 | `doSend` (PR-A) blocks `afterCommit` thread on OMS latency | Low — synchronous HTTP inside Spring TX callback thread | Pre-existing behavior (the `else` fallback was already synchronous). PR-B outbox removes this concern entirely. |
| 5 | `CustomerorderBatchService` Phase 4 wrapped in `@Transactional` by future maintainer | Low — reintroduces double-afterCommit for club-line path | Comment in `customerOrderPicked` Javadoc warns: "club-line caller runs outside TX; outbox migration requires TenantContext verification first." PR-A's `OmsNotificationService` guard also catches this safely. |
| 6 | `OutboxDispatcherJob` not enabled for tenant | Low — outbox row PENDING but never dispatched | Verify `app.cron.outbox_dispatcher=true` per tenant before PR-B deploy. |

---

## 10. Acceptance Criteria

1. **[PR-A]** `sendAfterCommit` called with `isSynchronizationActive()=true` and `isActualTransactionActive()=false` → `doSend` called directly; zero `registerSynchronization` calls. *(Unit test: `givenNestedAfterCommit_*`)*
2. **[PR-A]** `sendAfterCommit` called inside active TX (`isActualTransactionActive()=true`) → synchronization registered; `doSend` fires after commit. *(Unit test: `givenActiveTx_*`)*
3. **[PR-A]** After PR-A deploy + recovery SQL, trigger a pick on wms2-wineco-dev → `SELECT * FROM message WHERE process='ORDER_BATCH_PICKING_FINISHED'` returns a new row within 5 s. *(Manual test §8.6 row 1)*
4. **[PR-B Fix A]** `finishPickingOrder` with `pickingconfirmationsent=false` CO in production mode → exactly 1 `outbox_message` row committed in the same TX (`process_type='ORDER_BATCH_PICKING_FINISHED'`, `aggregate_id=co.id`, `status='PENDING'`). *(Integration test §8.5)*
5. **[PR-B Fix A]** TX rollback (serialization `FacadeException`) → 0 `outbox_message` rows; `pickingconfirmationsent=false` on CO. *(Integration test §8.5)*
6. **[PR-B Fix A]** Second call for same CO (`pickingconfirmationsent=true`) → 0 additional outbox rows. *(Unit test)*
7. **[PR-B Fix A]** `grep -n "registerSynchronization" src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` — zero matches in non-comment code. *(Verify script check)*
8. **[PR-B Fix A]** `setPickingconfirmationsent(true)` line appears AFTER `buildPickedPayloadJson` call in `finishPickingOrder`. *(Code review + verify script line-order check)*
9. **[PR-B Fix B]** Case 1 with CO `pickingconfirmationsent=false AND state>=PICKED AND state!=CANCELED` → 1 outbox row created, flag set to `true`. *(Integration test §8.5)*
10. **[PR-B Fix B]** Case 1 with all COs `pickingconfirmationsent=true` → 0 new outbox rows. *(Unit test)*
11. **[PR-B Fix C]** `grep -n "registerSynchronization" src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` — zero matches in non-comment code (covers both Fix A and Fix C). *(Same verify script check as AC #7)*
12. **[PR-B]** `ManageOrderService.customerOrderPicked` and `customerOrderPickingStarted` compile, are callable, and produce correct OMS notifications for club-line batch path. *(Unit test §8.3 `givenValidOrders_whenCustomerOrderPicked_*`)*
13. **[PR-B]** Non-production mode: `finishPickingOrder` and `confirmPick` enqueue 0 outbox rows. *(Unit tests)*
14. **[Observability]** After pick completion on wms2-wineco-dev, within 30 s: `SELECT * FROM outbox_message WHERE process_type='ORDER_BATCH_PICKING_FINISHED' AND status='SENT'` — at least 1 row. *(Manual test §8.6 row 1 — DB check, not metrics)*

---

## 11. Verification Script

**File:** `sbdocs/9-System/scripts/verify-260520-picking-finished-oms-notification-fix.sh`

The script validates both PR-A and PR-B acceptance criteria statically (code checks) and optionally via compilation.

Checks to include:
1. **AC #1 / AC #7 / AC #11:** `grep -c "registerSynchronization" .../PickingorderBusinessService.java` — expect 0 in non-comment lines.
2. **AC #1 (PR-A guard):** `grep -n "isActualTransactionActive" .../OmsNotificationService.java` — expect ≥ 1 match.
3. **AC #8 (ordering):** verify `setPickingconfirmationsent(true)` line number > `buildPickedPayloadJson` line number in `finishPickingOrder`.
4. **AC #12 (methods retained):** `grep -n "customerOrderPicked\|customerOrderPickingStarted" .../ManageOrderService.java` — expect both present.
5. **AC #12 (deprecated):** `grep -n "@Deprecated" .../ManageOrderService.java` — expect ≥ 2 matches.
6. **PR-A guard shape:** `grep -n "isSynchronizationActive.*isActualTransactionActive\|isActualTransactionActive.*isSynchronizationActive" .../OmsNotificationService.java` — expect match.
7. **Compile check:** `mvn -q -pl v2/wms2-api -DskipTests compile` — expect exit 0.

*(Script to be created during PR-A implementation step 2.)*

---

## 12. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|---|---|
| 1 | **Delete `customerOrderPicked`/`customerOrderPickingStarted`?** | **No.** `CustomerorderBatchService:763-764` calls both. Retained + `@Deprecated`. Club-line outbox migration is out of scope (tracked separately; requires TenantContext audit for Phase 4). |
| 2 | **Two-PR or single PR?** | **Two-PR.** PR-A is deployable immediately (1 file, 12 lines). PR-B is structural migration deployable at next sprint after content-derived idempotency key plan is live. |
| 3 | **`JsonProcessingException` rollback behavior change?** | **Accepted as net improvement.** Pre-fix: silent strand. Post-fix: rollback + recovery path. Document in release notes. |
| 4 | **Idempotency for `reenqueuePickingFinishedIfMissing`?** | **Hard prerequisite.** `260520-content-derived-idempotency-key.md` deployed before PR-B Fix B. UNIQUE constraint on `outbox_message.idempotency_key` makes re-enqueue safe only with content-derived keys. |
| 5 | **`AdminActionController` calling `finishPickingOrder`?** | Safe. `finishPickingOrder` is `@Transactional("tenantTransactionManager")`, opens its own TX. `outboxService.enqueue` joins it. No controller change. |
| 6 | **`OutboxDispatcherJob` emitting `processType` metric tag?** | `JobMetrics.java` emits `wms2.cron.outbox_dispatcher.*` counters without per-`processType` breakdown (per SBDEV-2238-4.5 design). AC #14 uses DB check (`outbox_message.status='SENT'`), not the metrics counter. |

---

## 13. Implementation Status

*To be filled when implemented.*
