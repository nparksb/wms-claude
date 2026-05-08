# Debug Plan: OMS HTTP Calls Inside Transaction Boundaries

**Date:** 2026-04-07
**Priority:** Critical
**Reporter:** Production incident (BOL close with 900+ parcels), pattern analysis

---

## 1. Problem Summary

External HTTP calls to OMS are made **inside `@Transactional` method boundaries** across multiple services. When an HTTP call succeeds but the subsequent DB commit fails (timeout, memory exhaustion, optimistic lock conflict), the transaction rolls back — but the OMS has already received and acted on the notification. This leaves WMS and OMS in an **inconsistent state**.

The immediate trigger was a BOL close with 900+ parcels: the HTTP payload is multi-megabyte, the OMS processing time exceeds the 15-second read timeout, the transaction holds database locks for the entire duration, and when it fails, the BOL remains open in WMS but is marked shipped in OMS.

The same pattern exists in **15 call sites across 10 service classes**.

## 2. Root Cause Analysis

### The fundamental pattern

```
@Transactional
public void businessOperation() {
    // 1. DB reads and writes (inside transaction)
    entity.setState(NEW_STATE);
    repository.save(entity);

    // 2. HTTP call to OMS (BLOCKING, inside transaction)
    httpRestService.post(omsUrl, payload);    // <-- OMS state changes here

    // 3. More DB writes (may fail → rollback)
    otherEntity.setState(ANOTHER_STATE);
    repository.save(otherEntity);             // <-- if this fails, DB rolls back
}                                             //     but OMS already updated
```

**Two failure modes:**

| Failure | WMS State | OMS State | Result |
|---------|-----------|-----------|--------|
| HTTP call times out (OMS was slow but succeeded) | Rolled back | Updated | **OMS ahead of WMS** |
| DB commit fails after HTTP success | Rolled back | Updated | **OMS ahead of WMS** |
| HTTP call fails (OMS down) | Committed (exception caught) | Not updated | **WMS ahead of OMS** |

### Why BOL close is the worst case

`BillofladingService.closeBOL()` (line 280) processes 900+ parcels in a single transaction:
- Acquires pessimistic row lock on BOL (line 290) — held for entire transaction
- Bulk-loads 7 entity sets (lines 348-453) — large memory footprint
- Iterates 3-level nesting: pallets → parcels → order positions (lines 461-542)
- Bulk-saves ~900 BOL positions, ~900 orders, ~900+ order positions (lines 545-547)
- Serializes multi-MB JSON payload (line 658)
- **Blocks on HTTP POST** with 15s read timeout (line 659)
- Post-HTTP DB writes for batch finalization (lines 684-713)

With 900+ parcels, the OMS processing time likely exceeds the 15-second `readTimeout` configured in `HttpRestService.java:28`.

## 3. Complete Audit of Affected Call Sites

### Category A: Direct `httpRestService.post()` inside `@Transactional` methods

| # | Service | Method | Line | HTTP Call Line | OMS Endpoint Key | Severity |
|---|---------|--------|------|---------------|-----------------|----------|
| 1 | `BillofladingService` | `closeBOL(Long)` | 280 | 659 | `ORDER_BATCH_SHIPPED_URL_KEY` | **Critical** (900+ parcels) |
| 2 | `AdviceService` | `createAdvice(...)` | 207 | 254 | `WEBSERVICE_ADVICE_CREATED_URL_KEY` | Medium |
| 3 | `AdviceService` | `close(Advice, Principal)` | 281 | 368 | `WEBSERVICE_ADVICE_CLOSED_URL_KEY` | Medium |
| 4 | `AdviceService` | `acceptTransferAdvice(...)` | 395 | 453 | `WEBSERVICE_ADVICE_CREATED_URL_KEY` | Medium |
| 5 | `CustomerorderService` | `cancelOrder(...)` | 573 | 705 | `WEBSERVICE_ORDER_CANCELLED_URL_KEY` | High |
| 6 | `CustomerorderBatchService` | `cancelBatch(...)` | 212 | 263 | `ORDER_BATCH_CANCELLED_URL_KEY` | High |

### Category B: `manageOrderService.*()` called from `@Transactional` methods (indirect HTTP)

`ManageOrderService` methods are **not** `@Transactional` themselves, but are called from within transactional callers. Each makes one `httpRestService.post()` call.

| # | Caller Service | Caller Method | Caller Line | ManageOrderService Method | HTTP Line | OMS Endpoint Key |
|---|---------------|--------------|-------------|--------------------------|-----------|-----------------|
| 7 | `CustomerorderBatchService` | `runClubLine()` | 683 | `customerOrderReleaseForPicking()` | 164 | `ORDER_BATCH_RELEASED_FOR_PICKING_URL_KEY` |
| 8 | `CustomerorderBatchService` | `runClubLine()` | 684 | `customerOrderPickingStarted()` | 228 | `ORDER_BATCH_PICKING_STARTED_URL_KEY` |
| 9 | `CustomerorderBatchService` | `runClubLine()` | 685 | `customerOrderPicked()` | 356 | `ORDER_BATCH_PICKING_FINISHED_URL_KEY` |
| 10 | `ParcelMonitorViewService` | `palletise()` | 186 | `customerOrderPalletized()` | 417 | `ORDER_BATCH_PALLETIZED_URL_KEY` |
| 11 | `ParcelMonitorViewService` | `palletiseAndTruckLoad()` | 302 | `customerOrderPalletized()` | 417 | `ORDER_BATCH_PALLETIZED_URL_KEY` |
| 12 | `ParcelMonitorViewService` | `palletiseAndTruckLoad()` | 373 | `customerOrderLoadedToTruck()` | 478 | `ORDER_BATCH_TRUCK_LOADED_URL_KEY` |
| 13 | `MobilePalletizingService` | `palletize(...)` | 228 | `customerOrderPalletized()` | 417 | `ORDER_BATCH_PALLETIZED_URL_KEY` |
| 14 | `MobilePalletizingService` | `palletizeAndShip(...)` | 363 | `customerOrderPalletized()` | 417 | `ORDER_BATCH_PALLETIZED_URL_KEY` |
| 15 | `MobileTruckLoadingService` | `truckLoad(...)` | 306 | `customerOrderLoadedToTruck()` | 478 | `ORDER_BATCH_TRUCK_LOADED_URL_KEY` |

### Category C: Already using `afterCommit()` pattern (CORRECT — no fix needed)

These call sites already defer the HTTP call until after the transaction commits:

| # | Service | Method | Line | Pattern |
|---|---------|--------|------|---------|
| -- | `PickingorderBusinessService` | `finishPickingPosition()` | 265 | `TransactionSynchronization.afterCommit()` → `customerOrderPicked()` |
| -- | `PickingorderBusinessService` | `assignToteToPickingOrder()` | 501 | `TransactionSynchronization.afterCommit()` → `customerOrderPickingStarted()` |
| -- | `MobilePickingService` | `processPick()` | 483 | `TransactionSynchronization.afterCommit()` → `customerOrderToteAssigned()` |
| -- | `MobilePickingService` | `assignToteToPickOrder()` | 992 | `TransactionSynchronization.afterCommit()` → `customerOrderToteAssigned()` |
| -- | `ReceivingService` | `receiveGoods()` | 532 | `TransactionSynchronization.afterCommit()` → HTTP advice created call |

### Category D: Called from non-transactional or job context (lower risk)

| # | Caller Service | Caller Method | ManageOrderService Method |
|---|---------------|--------------|--------------------------|
| -- | `ReleaseOrderJobService` | `doCalculation()` (line 217, 533) | `customerOrderOnHold()` |
| -- | `ReleaseOrderJobService` | `doCalculation()` (line 652) | `customerOrderReleaseForPicking()` |
| -- | `OrderMonitorViewService` | `toteAssignment()` (line 209) | `customerOrderToteAssigned()` |

These are called from scheduled jobs or view services where the transaction boundary is smaller. Still affected but lower risk.

## 4. Proposed Solutions

### Option A: `TransactionSynchronization.afterCommit()` — Move HTTP after commit (Recommended)

**Confidence:** High (95%) — This pattern already exists in 5 places in the codebase (`PickingorderBusinessService`, `MobilePickingService`, `ReceivingService`) and is proven to work.

**Approach:** Wrap each HTTP call in a `TransactionSynchronization.afterCommit()` callback so it only fires after the DB transaction successfully commits. If the HTTP call fails, the DB state is already committed (correct), and a retry mechanism handles the OMS notification.

**Example transformation:**

```java
// BEFORE (current — broken)
@Transactional(value = "tenantTransactionManager", rollbackFor = {...})
public void closeBOL(Long bolId) {
    // ... DB work ...
    httpRestService.post(urlPath, payload);  // blocks inside transaction
    // ... more DB work ...
}

// AFTER (fixed)
@Transactional(value = "tenantTransactionManager", rollbackFor = {...})
public void closeBOL(Long bolId) {
    // ... ALL DB work ...
    final String finalPayload = payload;
    final String finalUrlPath = urlPath;
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
        @Override
        public void afterCommit() {
            sendOmsNotification(finalUrlPath, finalPayload,
                WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED);
        }
    });
}
```

**Effort:** Medium (2-3 days)
- 15 call sites to refactor
- Each requires extracting the HTTP call and payload construction into an `afterCommit` callback
- Need to capture all required variables as `final` locals before the callback
- `ManageOrderService` methods can be refactored to accept a "deferred" mode

**Risks:**
- If the application crashes between commit and HTTP call, the OMS is never notified → mitigated by the existing `Message` table (status=PENDING) + retry mechanism
- The `afterCommit` callback runs outside the transaction, so any DB writes inside it need their own transaction → `MessageService.createMessage()` already uses `REQUIRES_NEW`
- `customerOrderPicked()` in `ManageOrderService` writes `historytote` UUIDs to customer orders (line 339-341) — this DB write must stay inside the main transaction, only the HTTP call moves out

### Option B: Transactional Outbox Pattern (Most robust, higher effort)

**Confidence:** High (90%) — Industry-standard pattern for exactly this problem. Guarantees exactly-once delivery semantics.

**Approach:** Instead of making HTTP calls directly, write an "outbox" record to a `pending_oms_messages` table inside the same transaction. A background job polls this table and sends HTTP messages, marking them as sent on success.

```
@Transactional                          Background Job (every 5s)
┌──────────────────────┐               ┌──────────────────────────┐
│ 1. DB mutations      │               │ 1. SELECT * FROM         │
│ 2. INSERT INTO       │               │    pending_oms_messages   │
│    pending_oms_msgs  │──── commit ──→│    WHERE status='PENDING' │
│    (url, payload,    │               │ 2. httpRestService.post() │
│     status=PENDING)  │               │ 3. UPDATE status='SENT'   │
└──────────────────────┘               └──────────────────────────┘
```

**Effort:** High (5-7 days)
- New `pending_oms_messages` table (Flyway migration)
- New `OmsOutboxService` to write outbox records
- New `OmsOutboxJob` scheduled job to process pending messages
- Refactor all 15 call sites to use `OmsOutboxService` instead of direct HTTP
- Dead-letter handling for permanently failed messages
- Monitoring/alerting for stuck messages

**Risks:**
- Adds latency (messages sent on next poll cycle, not immediately)
- More moving parts to monitor
- Need to handle message ordering if OMS cares about sequence

**Note:** The existing `Message` table + `MessageService.resendMessage()` is already a partial outbox — it logs all sent/failed messages. Option B formalizes this.

### Option C: Split Transaction — DB first, HTTP second, compensate on failure

**Confidence:** Medium (70%) — Works but requires compensation logic for each operation.

**Approach:** Split each operation into two phases:
1. **Phase 1 (transactional):** All DB work + write a `Message` record with status `PENDING`
2. **Phase 2 (non-transactional):** HTTP call to OMS, update `Message` to `SENT` or `FAILED`

If Phase 2 fails, a retry job picks up `PENDING` messages and retries.

**Effort:** Medium (3-4 days)
- Similar to Option A but with explicit Message status tracking
- Requires retry infrastructure (already partially exists)

**Risks:**
- If Phase 2 permanently fails, WMS is ahead of OMS (but at least consistent internally)
- Need idempotency on OMS side for retries

### Option D: Increase Timeouts + Async HTTP (Quick fix, low confidence)

**Confidence:** Low (40%) — Band-aid that doesn't fix the fundamental issue.

**Approach:**
- Increase `HttpRestService.readTimeout` from 15s to 60s+
- Optionally make HTTP calls async with `CompletableFuture` (fire-and-forget)

**Effort:** Low (hours)

**Risks:**
- Longer timeouts = longer DB lock hold times = more contention
- Async fire-and-forget loses delivery guarantee
- Doesn't fix the commit-after-HTTP-success problem
- Merely increases the threshold before failure, doesn't eliminate it

## 5. Recommended Implementation Strategy

### Phase 1: Immediate — Fix the BOL close (Critical, 1 day)

Fix `BillofladingService.closeBOL()` using the `afterCommit()` pattern (Option A). This is the most critical path because:
- It handles the highest volume (900+ parcels)
- It has the largest payload (multi-MB JSON)
- It holds a pessimistic lock for the entire duration
- It's the reported production incident

**Files to change:**
- `BillofladingService.java:659` — move `httpRestService.post()` into `afterCommit()` callback
- Keep the `messageService.createMessage()` call but set initial status to `PENDING`, update to `SENT` after successful HTTP

### Phase 2: High priority — Fix `runClubLine` and `cancelBatch`/`cancelOrder` (High, 1 day)

**Files to change:**
- `CustomerorderBatchService.java:683-685` — wrap 3 `manageOrderService.*()` calls in `afterCommit()`
- `CustomerorderBatchService.java:263` — move cancel HTTP call to `afterCommit()`
- `CustomerorderService.java:705` — move cancel HTTP call to `afterCommit()`

**Special case:** `ManageOrderService.customerOrderPicked()` writes `historytote` to DB at line 339. This write must remain inside the transaction. Split the method: DB write stays in-transaction, HTTP call moves to `afterCommit`.

### Phase 3: Medium priority — Fix remaining direct HTTP calls (Medium, 1 day)

**Files to change:**
- `AdviceService.java:254, 368, 453` — 3 HTTP calls in advice workflows
- `ParcelMonitorViewService.java:186, 302, 373` — palletize and truck load flows
- `MobilePalletizingService.java:228, 363` — mobile palletize flows
- `MobileTruckLoadingService.java:306` — mobile truck loading

### Phase 4: Create a shared utility (Low, 0.5 day)

Extract the `afterCommit` + message creation pattern into a reusable helper to avoid duplicating the boilerplate across 15 call sites:

```java
@Service
public class OmsNotificationService {

    private final HttpRestService httpRestService;
    private final MessageService messageService;
    private final SyspropService syspropService;

    /**
     * Defers an OMS HTTP notification until after the current transaction commits.
     * Creates a Message record for audit/retry regardless of outcome.
     */
    public void sendAfterCommit(String urlPropertyKey, Object dto,
                                String processType) {
        // Serialize payload NOW (inside transaction, entities still attached)
        String payload = MAPPER.writeValueAsString(dto);
        String urlPath = syspropService.getSysvalue(urlPropertyKey);

        TransactionSynchronizationManager.registerSynchronization(
            new TransactionSynchronization() {
                @Override
                public void afterCommit() {
                    try {
                        Map<String, String> resp = httpRestService.post(urlPath, payload);
                        messageService.createMessage(..., WmsConstants.MessageStatus.SENT,
                            resp.get("code"), resp.get("answer"));
                    } catch (Exception e) {
                        messageService.createMessage(..., WmsConstants.MessageStatus.FAILED,
                            "503", null);
                        LOG.error("OMS notification failed: {}", e.getMessage());
                    }
                }
            });
    }
}
```

Then all 15 call sites simplify to:
```java
omsNotificationService.sendAfterCommit(
    WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY,
    billOfLadingWebServiceDto,
    WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED);
```

### Phase 5: Future — Evaluate Outbox pattern (Optional)

If `afterCommit` + retry proves insufficient (e.g., application crashes between commit and HTTP), implement Option B (transactional outbox). The `OmsNotificationService` from Phase 4 makes this a straightforward swap — change the implementation from `afterCommit` to outbox table insert without touching callers.

## 6. Risks & Side Effects

| Risk | Impact | Mitigation |
|------|--------|------------|
| App crash between commit and `afterCommit` callback | OMS never notified | Existing `Message` table with `FAILED`/`PENDING` status + `resendMessage()` retry. Add monitoring for messages stuck in PENDING. |
| `afterCommit` runs outside transaction — no rollback | HTTP failure after commit leaves WMS ahead of OMS | This is **better** than current state (OMS ahead of WMS). WMS is the source of truth. Retry handles eventual consistency. |
| Payload serialization in `afterCommit` may fail if entities are detached | `LazyInitializationException` | Serialize payload **before** registering the callback (while entities are still managed). Pass the serialized `String` into the callback. |
| `customerOrderPicked()` DB write (`historytote`) mixed with HTTP call | Can't simply move entire method to afterCommit | Split the method: DB write stays in transaction, HTTP notification moves to afterCommit. |
| Multiple `afterCommit` callbacks in `runClubLine` (3 HTTP calls) | All fire sequentially after commit | Acceptable. Could parallelize with `CompletableFuture` inside callbacks if latency is a concern. |

## 7. Task Checklist

- [x] **Phase 4** (Low): Extract `OmsNotificationService` shared utility — `OmsNotificationService.java` created
- [x] **Phase 1** (Critical): Move `closeBOL` HTTP call to `afterCommit` — `BillofladingService.java`
- [x] **Phase 2a** (High): Move `runClubLine` 3 HTTP calls to `afterCommit` — `CustomerorderBatchService.java`
- [x] **Phase 2b** (High): Move `cancelBatch` HTTP call to `afterCommit` — `CustomerorderBatchService.java`
- [x] **Phase 2c** (High): Move `cancelOrder` HTTP call to `afterCommit` — `CustomerorderService.java`
- [x] **Phase 3a** (Medium): Move `AdviceService` 3 HTTP calls to `afterCommit` — `AdviceService.java`
- [x] **Phase 3b** (Medium): Move `ParcelMonitorViewService` 3 HTTP calls to `afterCommit` — `ParcelMonitorViewService.java`
- [x] **Phase 3c** (Medium): Move `MobilePalletizingService` 2 HTTP calls to `afterCommit` — `MobilePalletizingService.java`
- [x] **Phase 3d** (Medium): Move `MobileTruckLoadingService` 1 HTTP call to `afterCommit` — `MobileTruckLoadingService.java`
- [x] **Phase 4b** (Low): Refactor all 15 call sites to use `OmsNotificationService` or `afterCommit` pattern
- [x] Add/update tests: `OmsNotificationServiceUnitTest` (3 tests), updated `BillofladingServiceUnitTest`, `CustomerorderBatchServiceUnitTest`, `AdviceServiceUnitTest`, `CustomerorderServiceUnitTest`
- [ ] Add monitoring: alert on `Message` records stuck in `PENDING` or `FAILED` status
- [ ] Verify `resendMessage()` retry mechanism works for all message types
- [ ] Load test BOL close with 900+ parcels after fix

---

## 9. Implementation Status (2026-04-07)

### Files changed

| File | Change |
|------|--------|
| **`OmsNotificationService.java`** (new) | Shared utility — defers HTTP POST to afterCommit with synchronous fallback. Creates Message records for audit/retry. |
| **`BillofladingService.java`** | `closeBOL()` — replaced inline `httpRestService.post()` with `omsNotificationService.sendAfterCommit()` |
| **`CustomerorderBatchService.java`** | `runClubLine()` — wrapped 3 `manageOrderService.*()` calls in `afterCommit` callback. `cancelBatch()` — replaced inline HTTP with `omsNotificationService.sendAfterCommit()` |
| **`CustomerorderService.java`** | `cancelOrder()` — replaced inline HTTP with `omsNotificationService.sendAfterCommit()` |
| **`AdviceService.java`** | 3 methods — replaced inline HTTP with `omsNotificationService.sendAfterCommit()` |
| **`ParcelMonitorViewService.java`** | 3 call sites — wrapped `manageOrderService.*()` in `afterCommit` callback |
| **`MobilePalletizingService.java`** | 2 call sites — wrapped `manageOrderService.*()` in `afterCommit` callback |
| **`MobileTruckLoadingService.java`** | 1 call site — wrapped `manageOrderService.*()` in `afterCommit` callback |

### Test files updated

| File | Change |
|------|--------|
| **`OmsNotificationServiceUnitTest.java`** (new) | 3 tests: success path, HTTP error, null URL |
| **`BillofladingServiceUnitTest.java`** | Added `@Mock OmsNotificationService`, updated constructor call |
| **`CustomerorderBatchServiceUnitTest.java`** | Added `@Mock OmsNotificationService`, updated cancel/runClubLine verifications |
| **`AdviceServiceUnitTest.java`** | Added `@Mock OmsNotificationService`, updated 4 verifications |
| **`CustomerorderServiceUnitTest.java`** | Added `@Mock OmsNotificationService` |

### Test results

- All unit tests pass (0 new failures)
- Pre-existing failures in `SequenceTransactionServiceUnitTest` (16 failures) are unrelated
- **15 call sites refactored** across 8 service files
- **3 new tests** in `OmsNotificationServiceUnitTest`

## 8. Solution Comparison Summary

| Criteria | Option A: afterCommit | Option B: Outbox | Option C: Split TX | Option D: Timeout |
|----------|----------------------|-----------------|-------------------|------------------|
| **Confidence** | 95% | 90% | 70% | 40% |
| **Effort** | Medium (2-3 days) | High (5-7 days) | Medium (3-4 days) | Low (hours) |
| **Delivery guarantee** | At-most-once (retry via Message table) | Exactly-once | At-most-once + retry | None |
| **Latency impact** | None (fires immediately after commit) | Polling interval (5-10s) | None | Increases lock time |
| **Existing pattern in codebase** | Yes (5 call sites) | No | No | No |
| **Crash safety** | Loses in-flight callbacks | Full guarantee | Loses in-flight | N/A |
| **Code complexity** | Low (callback wrapper) | Medium (new table + job) | Medium (split methods) | Very low |

**Recommendation:** Start with **Option A** (afterCommit). It's proven in this codebase, has the best effort-to-confidence ratio, and the `OmsNotificationService` utility (Phase 4) creates a clean abstraction that can later be swapped to Option B (outbox) without changing callers.
