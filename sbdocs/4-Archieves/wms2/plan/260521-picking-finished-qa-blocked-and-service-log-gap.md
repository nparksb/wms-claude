---
title: "Fix: PICKING_FINISHED — QA Blocked by Missing tote_label + Service Log Gap in Outbox Dispatcher"
ticket: ""
ticket_url: ""
type: "bug"
priority: "high"
status: "archived"
impl_commit: "d7cc5df"
impl_pr: "https://github.com/SiteBossInc/wms2-api/pull/32"
impl_date: "2026-05-21"
impl_tests: "ManageOrderServiceUnitTest 76/76 (+3); OutboxDispatchServiceUnitTest 6/6 (new)"
project: ["wms2"]
version: "v2"
requester: ""
created: "2026-05-21"
updated: "2026-05-21"
related:
  - "260521-wms2-qa-blocked-tote-label-and-message-log-gap"
  - "260520-picking-finished-oms-notification-fix"
  - "SBDEV-2221"
  - "SBDEV-2238"
db_verified: false
tags:
  - plan
  - outbox
  - oms-notification
  - picking
  - qa
  - message-log
---

# Fix: PICKING_FINISHED — QA Blocked by Missing tote_label + Service Log Gap in Outbox Dispatcher

**Type:** Bug | **Version:** v2 | **Priority:** High  
**Status:** Draft  
**Date:** 2026-05-21

> ⚠️ **db_verified: false** — `wms2-wineco-dev` MCP tool unavailable during plan authoring. Before starting implementation, run the three manual DB queries listed in §1 Symptom to confirm data state.

**Files to change (5):**
- `service/ManageOrderService.java` — Fix A: add no-tote sentinel branch
- `service/job/OutboxDispatchService.java` — Fix B: inject `MessageService` + `SyspropService`; add `writeServiceLog`
- `service/WmsConstants.java` — Fix A: add `NO_TOTE_SENTINEL = "NO_TOTE"` constant
- `unit/service/ManageOrderServiceUnitTest.java` — Fix A tests
- `unit/service/job/OutboxDispatchServiceUnitTest.java` — Fix B tests (new file)

**Related investigation:** `sbdocs/3-Resources/reports/260521-wms2-qa-blocked-tote-label-and-message-log-gap.md`  
**Prior plan (double-afterCommit fix, PR #31):** `sbdocs/1-Projects/wms2/plan/260520-picking-finished-oms-notification-fix.md`

---

## 0. Affected Sites (Enumeration Before Drafting)

| # | File:line | Construct | Bug # | In-scope this plan? |
|---|-----------|-----------|-------|---------------------|
| 1 | `service/ManageOrderService.java:286–291` | `buildPickedPayloadJson` — non-CLUB no-tote branch leaves `toteLabel` null; Jackson `NON_NULL` drops key | Bug 1 | **Yes — Fix A** |
| 2 | `service/ManageOrderService.java:143–186` | `customerOrderToteAssigned` — adjacent no-tote pattern for `ORDER_BATCH_PICKING_TOTE_ASSIGNED` process | Bug 1 (adjacent) | **No** — OMS handler for that process type does not guard on `tote_label`; safe as-is |
| 3 | `service/PickingorderBusinessService.java:260` | `finishPickingOrder` — consumer of `buildPickedPayloadJson` | Bug 1 | **No** — fix is upstream in builder; inherits fix automatically |
| 4 | `service/PickingorderBusinessService.java:376` | `reenqueuePickingFinishedIfMissing` — also consumes builder | Bug 1 | **No** — inherits fix automatically |
| 5 | `service/job/OutboxDispatchService.java:33–133` | Entire class — no `MessageService`; `markSent`/`markRetry`/`markTerminal` branches all skip message-log write | Bug 2 | **Yes — Fix B** |
| 6 | `service/PickingorderBusinessService.java:265,382,582` | 3× `outboxService.enqueue(...)` — PICKING_FINISHED + recovery + PICKING_STARTED | Bug 2 (callers) | **No** — single dispatcher fix covers all |
| 7 | `service/AdviceService.java:265,365,436` | 3× `outboxService.enqueue(...)` — advice notifications | Bug 2 (callers) | **No** — single dispatcher fix covers all |
| 8 | `service/CustomerorderService.java:733` | `outboxService.enqueue(...)` — cancel | Bug 2 (callers) | **No** — single dispatcher fix covers all |
| 9 | `service/BillofladingService.java:672` | `outboxService.enqueue(...)` — BOL close | Bug 2 (callers) | **No** — single dispatcher fix covers all |
| 10 | `service/CustomerorderBatchService.java:280` | `outboxService.enqueue(...)` — batch cancel | Bug 2 (callers) | **No** — single dispatcher fix covers all |

Zero `messageService.createMessage` calls exist in `service/job/` (grep confirmed). Fix B at the dispatcher is the single-site cure for all 9 enqueue callsites across 6 service classes.

---

## 1. Problem Statement

**After SBDEV-2238 migrated the PICKING_FINISHED notification to the transactional outbox, two new silent failures emerged:**

### Symptom A — OMS QA screen blocked at "Picking status"

The `outbox_message` row reaches `status = 'SENT'` (HTTP 200 from OMS), but the parcel never advances to `parcel_status = 25` (WAITING_FOR_QA). The omsv2-UI frontend reads `parcel_status = 24` and renders:

> *"This parcel is currently in Picking status and cannot be processed through QA."*

No WMS error is logged. The outbox dispatcher considers the dispatch successful. Affects **every** regular (non-CLUB) picking order where no physical tote is assigned to the picking order (`pickingtoteId == null`).

### Symptom B — PICKING_FINISHED absent from Service Log

The WMS2 Service Log admin page (backed by the `message` table) shows no record of any `ORDER_BATCH_PICKING_FINISHED` dispatch. The outbox row shows `status = 'SENT'`; the `message` table has zero matching rows. This gap extends to **all** outbox-dispatched notification types (9 process types across 6 services) — not only PICKING_FINISHED.

**Manual DB checks to run before implementation:**

```sql
-- 1. Confirm stuck parcels (replace tenant DB)
SELECT id, parcel_status, updated_at FROM parcel
WHERE parcel_status = 24 ORDER BY updated_at DESC LIMIT 20;

-- 2. Confirm outbox rows marked SENT despite OMS failure
SELECT id, process_type, status, created_at, sent_at FROM outbox_message
WHERE process_type = 'ORDER_BATCH_PICKING_FINISHED'
ORDER BY created_at DESC LIMIT 10;

-- 3. Confirm zero message rows post-outbox-migration
SELECT COUNT(*) FROM message
WHERE process = 'ORDER_BATCH_PICKING_FINISHED'
  AND created_at > '2026-05-01';
```

---

## 2. Root Cause Analysis

### Bug 1 — Missing `tote_label` in PICKING_FINISHED payload

**File:** `service/ManageOrderService.java:286–291`

```java
// Current — no else branch for non-CLUB, no-tote orders
} else if (customerOrder.getPickingtoteId() != null) {
    Unitload pickingTote = unitloadRepository.findById(customerOrder.getPickingtoteId())
            .orElseThrow(() -> new EntityNotFoundException("UnitLoad", customerOrder.getPickingtoteId()));
    orderDto.setToteLabel(pickingTote.getLabelid());
}
// FALLTHROUGH: non-CLUB + pickingtoteId == null → toteLabel stays null
// Jackson NON_NULL serializer drops the key entirely from the POST body
```

**Causal chain:**

```
ManageOrderService.buildPickedPayloadJson
  └─ Non-CLUB, pickingtoteId == null → toteLabel = null
  └─ Jackson NON_NULL → key absent from JSON

OutboxDispatchService.dispatchOne → POST to OMS finishedPicking

OMS LegacyWmsController.php:1469
  └─ $toteLabel = $position['tote_label'] ?? '';   // missing key → ""
OMS line 1472
  └─ if (empty($toteLabel)) { $errors[] = "…Has no UL Code"; continue; }
  └─ parcel_status = 25  ← NEVER REACHED
OMS line 1531
  └─ return response()->json(['Status' => 'Error'], 200)   // HTTP 200

OutboxDispatchService
  └─ code >= 200 && code < 300  → outboxService.markSent()  // SILENT FAILURE
```

The failure is deterministic and systemic: every regular pick-pack order with no tote assigned will silently fail to advance to QA.

### Bug 2 — Outbox dispatcher never writes to `message` table

**File:** `service/job/OutboxDispatchService.java:50–57` (constructor)

```java
// Current — no MessageService, no SyspropService
public OutboxDispatchService(OutboxMessageRepository repo,
                              OutboxService outboxService,
                              HttpRestService httpRestService,
                              MeterRegistry meters) { ... }
```

`OmsNotificationService.doSend()` (lines 103–134) unconditionally calls `messageService.createMessage()` on both success and failure paths — this is what populates the `message` table:

```java
// OmsNotificationService.doSend() — what the legacy path does
messageService.createMessage(
    syspropService.getWmsInstanceName(),
    syspropService.getOmsInstanceName(),
    payload, processType, urlPath,
    WmsConstants.MessageStatus.SENT,
    respMap.get("code"),
    respMap.get("answer"));
```

When SBDEV-2238 migrated callers from `sendAfterCommit()` → `outboxService.enqueue()`, the HTTP POST moved from `doSend()` to `OutboxDispatchService.dispatchOne()`. The `messageService.createMessage()` call was never ported to the dispatcher. Result: all 9 outbox-dispatched notification types produce zero `message` rows — the Service Log is incomplete for every critical WMS→OMS event.

---

## 3. Fix Design

### Fix A — Always emit non-empty `tote_label` from `buildPickedPayloadJson`

**File:** `service/ManageOrderService.java:286–295`

**Before:**
```java
} else if (customerOrder.getPickingtoteId() != null) {
    Unitload pickingTote = unitloadRepository.findById(customerOrder.getPickingtoteId())
            .orElseThrow(() -> new EntityNotFoundException("UnitLoad", customerOrder.getPickingtoteId()));
    orderDto.setToteLabel(pickingTote.getLabelid());
}
```

**After:**
```java
} else if (customerOrder.getPickingtoteId() != null) {
    Unitload pickingTote = unitloadRepository.findById(customerOrder.getPickingtoteId())
            .orElseThrow(() -> new EntityNotFoundException("UnitLoad", customerOrder.getPickingtoteId()));
    orderDto.setToteLabel(pickingTote.getLabelid());
} else {
    // Pick-pack orders with no tote assigned must still send a non-empty tote_label.
    // OMS finishedPicking (LegacyWmsController:1472) skips any position with empty
    // tote_label, leaving parcel_status=24 and silently blocking QA.
    // "NO_TOTE" is stored as ul_code/ul_code_history then cleared at QA completion
    // by QaWorkflowService — no persistent residue, no physical-routing impact.
    orderDto.setToteLabel(WmsConstants.NO_TOTE_SENTINEL);
}
```

**`WmsConstants.java` addition** (place near other string constants):
```java
/** Sentinel tote label for pick-pack orders with no physical tote assigned.
 *  Required by OMS finishedPicking to pass the empty-tote guard and advance
 *  parcel_status from 24 (PICKING) to 25 (WAITING_FOR_QA). */
public static final String NO_TOTE_SENTINEL = "NO_TOTE";
```

**OMS safety analysis — `"NO_TOTE"` is safe:**

| OMS file:line | Use of tote_label / ul_code | Safe? |
|---|---|---|
| `LegacyWmsController.php:1469` | `$toteLabel = $position['tote_label'] ?? '';` | ✅ non-empty, passes guard |
| `LegacyWmsController.php:1472` | `if (empty($toteLabel)) continue;` | ✅ `"NO_TOTE"` not empty |
| `LegacyWmsController.php:1500–1501` | `$parcel->ul_code = $parcel->ul_code_history = $toteLabel` | ✅ string column, no format constraint |
| `QaWorkflowService.php:366` | `'ul_code' => null` (cleared at QA) | ✅ sentinel cleared; no persistent residue |
| `QaWorkflowService.php:449,461` | Echoes `ul_code` back to WMS QA-complete payload | ✅ WMS receives `"NO_TOTE"` back; no routing use |
| `QaParcelService.php:64–65` | `where('ul_code', $term)` (parcel search) | ⚠️ minor: searching `"NO_TOTE"` would match all pre-QA no-tote parcels; `ul_code` is cleared at QA so exposure is short-lived. Acceptable. |

**Why not alternatives:**

| Alternative | Rejected because |
|---|---|
| Use `customerOrder.getNumber()` as fallback | Muddies `ul_code` semantics; column is also a tote-scan search target |
| Force `pickingtoteId` non-null upstream | High blast radius across all picking controllers and mobile flows |
| Drop `NON_NULL` serializer for this DTO | Risks emitting null for other OMS-bound fields (e.g. `palletLabel`, `boxSku`) |
| Fix OMS to treat missing tote_label as optional | Two-system change; root cause is on WMS side |

---

### Fix B — Add `MessageService` log write to `OutboxDispatchService`

**File:** `service/job/OutboxDispatchService.java`

**Constructor — before:**
```java
public OutboxDispatchService(OutboxMessageRepository repo,
                              OutboxService outboxService,
                              HttpRestService httpRestService,
                              MeterRegistry meters) {
    this.repo = repo;
    this.outboxService = outboxService;
    this.httpRestService = httpRestService;
    this.meters = meters;
}
```

**Constructor — after (add two deps + fields):**
```java
private final MessageService messageService;
private final SyspropService syspropService;

public OutboxDispatchService(OutboxMessageRepository repo,
                              OutboxService outboxService,
                              HttpRestService httpRestService,
                              MeterRegistry meters,
                              MessageService messageService,
                              SyspropService syspropService) {
    this.repo = repo;
    this.outboxService = outboxService;
    this.httpRestService = httpRestService;
    this.meters = meters;
    this.messageService = messageService;
    this.syspropService = syspropService;
}
```

**`dispatchOne` — after (add `writeServiceLog` call after each `mark*`):**
```java
private void dispatchOne(OutboxMessage msg) {
    try {
        Map<String, String> result = httpRestService.postWithIdempotencyKey(
            msg.getDestinationUrl(), msg.getPayload(), msg.getIdempotencyKey());
        int code = Integer.parseInt(result.get("code"));

        if (code >= 200 && code < 300) {
            outboxService.markSent(msg.getId());
            meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "sent").increment();
            writeServiceLog(msg, WmsConstants.MessageStatus.SENT,
                result.get("code"), result.get("answer"));
        } else if (isTerminal(code, msg.getAttempts())) {
            outboxService.markTerminal(msg.getId(), "HTTP " + code + ": " + result.get("answer"));
            meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "terminal").increment();
            LOG.error("outboxDispatcher: terminal failure for {}/{} key={} code={}",
                msg.getAggregateType(), msg.getAggregateId(), msg.getIdempotencyKey(), code);
            writeServiceLog(msg, WmsConstants.MessageStatus.FAILED,
                result.get("code"), result.get("answer"));
        } else {
            outboxService.markRetry(msg.getId(), "HTTP " + code + ": " + result.get("answer"), msg.getAttempts());
            meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "retry").increment();
            writeServiceLog(msg, WmsConstants.MessageStatus.FAILED,
                result.get("code"), result.get("answer"));
        }
    } catch (Exception e) {
        if (msg.getAttempts() >= maxAttempts) {
            outboxService.markTerminal(msg.getId(), e.getMessage());
            meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "terminal").increment();
            LOG.error("outboxDispatcher: terminal failure (attempts={}) for {}/{} key={}",
                msg.getAttempts(), msg.getAggregateType(), msg.getAggregateId(),
                msg.getIdempotencyKey(), e);
        } else {
            outboxService.markRetry(msg.getId(), e.getMessage(), msg.getAttempts());
            meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "retry").increment();
            LOG.warn("outboxDispatcher: retry (attempt={}) for {}/{} key={}: {}",
                msg.getAttempts() + 1, msg.getAggregateType(), msg.getAggregateId(),
                msg.getIdempotencyKey(), e.getMessage());
        }
        writeServiceLog(msg, WmsConstants.MessageStatus.FAILED, "503", e.getMessage());
    }
}
```

**New private helper:**
```java
/**
 * Best-effort audit-log write to the {@code message} table — mirrors
 * {@link OmsNotificationService#doSend}. Called after each outbox mark* to restore
 * Service Log visibility for all outbox-dispatched notification types (SBDEV-2238 gap).
 *
 * <p>Never throws: a logging failure must not revert an already-committed outbox row.
 */
private void writeServiceLog(OutboxMessage msg, String status, String stateCode, String answer) {
    try {
        messageService.createMessage(
            syspropService.getWmsInstanceName(),
            syspropService.getOmsInstanceName(),
            msg.getPayload(),
            msg.getProcessType(),
            msg.getDestinationUrl(),
            status,
            stateCode,
            answer);
    } catch (net.aim_ai.wms.exceptions.BusinessException be) {
        // Best-effort audit log — mirror OmsNotificationService.doSend swallow (line 121–124).
        LOG.error("outboxDispatcher: failed to persist message-log row for outbox id={} processType={}",
            msg.getId(), msg.getProcessType(), be);
        meters.counter("wms2.outbox.message_log.failed", "processType", msg.getProcessType()).increment();
    } catch (Exception e) {
        // Defensive: never let a logging failure flip an already-committed outbox status.
        LOG.error("outboxDispatcher: unexpected exception persisting message-log row for outbox id={}",
            msg.getId(), e);
        meters.counter("wms2.outbox.message_log.failed", "processType", msg.getProcessType()).increment();
    }
}
```

**Key design decisions:**

| Decision | Rationale |
|---|---|
| `writeServiceLog` called **after** each `mark*` | Audit-log write is a best-effort tail; ordering ensures outbox state is committed before log write is attempted |
| Two-level try-catch in `writeServiceLog` | `BusinessException` matches `OmsNotificationService.doSend` swallow pattern; broad `Exception` ensures logging failure cannot flip an already-committed outbox row |
| `MessageService.createServiceLog` (called via public `createMessage` overloads at lines 67–73) carries `@Transactional(value = "tenantTransactionManager", propagation = REQUIRES_NEW)` at `MessageService.java:75–76`. The public `createMessage` overloads are unannotated — scanning them for `@Transactional` will not find it; look at `createServiceLog`. External callers like `OutboxDispatchService` enter via the Spring proxy on the public `createMessage` method; the self-call from `createMessage` → `createServiceLog` inside the same bean instance does bypass the proxy (classic Spring self-invocation), but because `dispatchOne` runs with **no surrounding transaction**, the practical effect is identical: a fresh `REQUIRES_NEW` tenant tx is always opened regardless of whether the proxy boundary is crossed. | Opens its own short tenant tx; safe to call from non-transactional `dispatchOne`. |
| Use `syspropService.getWmsInstanceName()/getOmsInstanceName()` | Exact same arguments as `OmsNotificationService.doSend` (lines 107–108); tenant-scoped lookups; mirrors legacy log format |
| `WmsConstants.MessageStatus.SENT/.FAILED` | Existing constants; same values as legacy path |

**Why not alternatives:**

| Alternative | Rejected because |
|---|---|
| Inject `OmsNotificationService` for a log-only method | Muddies SRP; `OmsNotificationService` is the legacy send path |
| Put `createMessage` inside `OutboxService.markSent` | Circular dep risk (`MessageService` already has `@Lazy` for `StockChangeNotificationService`) |
| Per-caller `createMessage` at each enqueue site (11 sites) | Only the dispatcher has the OMS HTTP response (code + body) |
| `TransactionalEventListener` fired by mark* | Spring event-bus complexity; mark* already runs in `REQUIRES_NEW` isolated tx |

---

## 4. Architecture Overview

```
PickingorderBusinessService.finishPickingOrder
  │  @Transactional(tenantTransactionManager)
  │
  ├─ outboxService.enqueue(OutboxMessage)      ← row commits atomically with WMS state
  │
  └─ [TX commits]

OutboxDispatcherJob (every 15 s, advisory lock 100008L)
  └─ for each tenant:
       OutboxDispatchService.dispatchBatch()
         Phase 0: reclaimStaleInFlight (REQUIRES_NEW)
         Phase 1: claimDueBatch (REQUIRES_NEW)  ← flip PENDING → IN_FLIGHT
         Phase 2: for each msg: dispatchOne()   ← NO tx held
           ├─ httpRestService.postWithIdempotencyKey()
           ├─ outboxService.markSent/markRetry/markTerminal (REQUIRES_NEW)
           └─ [NEW] writeServiceLog → messageService.createMessage (REQUIRES_NEW)
                     └─ INSERT INTO message (process, status, payload, answer, ...)
```

**Key files:**

| File | Lines | Role |
|------|-------|------|
| `service/ManageOrderService.java` | 435 | Builds PICKING_FINISHED payload JSON — Fix A site |
| `service/job/OutboxDispatchService.java` | 133 | Per-tenant outbox dispatcher — Fix B site |
| `service/WmsConstants.java` | ~568 | Constants — `NO_TOTE_SENTINEL` addition |
| `service/OmsNotificationService.java` | 136 | Legacy path reference — `doSend` pattern to mirror |
| `service/MessageService.java` | ~150 | `createMessage(…)` 8-param overload target |
| `service/SyspropService.java` | — | `getWmsInstanceName()/getOmsInstanceName()` |
| `service/OutboxService.java` | — | `markSent/markRetry/markTerminal` (REQUIRES_NEW) |

---

## 5. Implementation Steps

### 5.1 Prerequisites

| # | Prerequisite | Status |
|---|---|---|
| P1 | Run 3 manual DB queries from §1 to baseline the data state (parcels stuck at 24; outbox SENT count; message table zero rows) | Required before starting |
| P2 | Confirm `OutboxDispatchService` is the only outbox dispatcher (no parallel implementation) — `grep -rn "outboxService\.claimDueBatch" src/` | N/A — confirmed single dispatcher |
| P3 | Confirm `MessageService.createMessage` 8-param overload exists — `grep -n "createMessage" service/MessageService.java` | Confirmed: line 71 |
| P4 | Confirm `SyspropService.getWmsInstanceName()/getOmsInstanceName()` exist — `grep -n "getWmsInstanceName\|getOmsInstanceName" service/SyspropService.java` | Verify before Fix B |
| P5 | No Flyway migration needed — pure Java changes only | ✓ |
| P6 | Feature flags / sysprops: no new sysprop needed; both fixes are always-on | ✓ |

### Step 1 — Add `NO_TOTE_SENTINEL` to `WmsConstants.java`

Add the constant near existing string constants:
```java
public static final String NO_TOTE_SENTINEL = "NO_TOTE";
```

Commit: `fix(wms2): add NO_TOTE_SENTINEL constant for pick-pack tote-less orders`

### Step 2 — Fix A: add sentinel branch to `ManageOrderService.buildPickedPayloadJson`

In `ManageOrderService.java:291`, add the `else` branch after the existing `else if (customerOrder.getPickingtoteId() != null)` block (as shown in §3 Fix A).

Add unit test `buildPickedPayloadJson_nonClubNoTote_emitsSentinel()` to `ManageOrderServiceUnitTest.java`.

Run: `mvn test -Dtest=ManageOrderServiceUnitTest` — all must pass.

Commit: `fix(wms2): emit NO_TOTE sentinel in PICKING_FINISHED payload for pick-pack orders without tote`

### Step 3 — Fix B: add `MessageService` + `writeServiceLog` to `OutboxDispatchService`

- Add `messageService` and `syspropService` fields and constructor parameters (as shown in §3 Fix B).
- Add `writeServiceLog` private helper.
- Add four `writeServiceLog(...)` calls in `dispatchOne` (one per outcome branch: 2xx success, terminal, retry, catch).

Create `OutboxDispatchServiceUnitTest.java` in `src/test/java/net/aim_ai/wms/unit/service/job/`.

Run: `mvn test -Dtest=OutboxDispatchServiceUnitTest` — all must pass.

Commit: `fix(wms2): write message-log row in OutboxDispatchService to restore Service Log visibility`

### Step 4 — Extend verify script

Add Fix A and Fix B checks to `sbdocs/9-System/scripts/verify-260520-picking-finished-oms-notification-fix.sh` (see §9 Acceptance).

### Step 5 — Integration smoke

Run `mvn -DskipTests compile` — must be clean.  
Run `mvn verify` — full suite including Testcontainers must pass.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/ManageOrderService.java` | Modify | Add `else { orderDto.setToteLabel(WmsConstants.NO_TOTE_SENTINEL); }` branch in `buildPickedPayloadJson` |
| `service/job/OutboxDispatchService.java` | Modify | Add `MessageService` + `SyspropService` constructor params; add `writeServiceLog` helper; call it in all 4 branches of `dispatchOne` |
| `service/WmsConstants.java` | Modify | Add `NO_TOTE_SENTINEL = "NO_TOTE"` constant |
| `unit/service/ManageOrderServiceUnitTest.java` | Modify | Add `buildPickedPayloadJson_nonClubNoTote_emitsSentinel()` test |
| `unit/service/job/OutboxDispatchServiceUnitTest.java` | Add (new file) | Unit tests for Fix B: `createMessage` called on 2xx, `BusinessException` swallowed, outbox state not reverted on log failure |

---

## 7. Testing Plan

### 7.1 Unit Tests

**Fix A — `ManageOrderServiceUnitTest.java` (add to existing test class):**

| Test method | Assert |
|---|---|
| `buildPickedPayloadJson_nonClubNoTote_emitsSentinel()` | `pickingtoteId = null`, non-CLUB → JSON contains `"tote_label":"NO_TOTE"` |
| `buildPickedPayloadJson_clubOrder_emitsUuid()` (regression) | CLUB order → `tote_label` is a UUID, not `"NO_TOTE"` |
| `buildPickedPayloadJson_regularWithTote_emitsLabel()` (regression) | `pickingtoteId != null` → `tote_label` = `pickingTote.getLabelid()` |

**Fix B — `OutboxDispatchServiceUnitTest.java` (new file in `unit/service/job/`):**

| Test method | Assert |
|---|---|
| `dispatchOne_success_writesMessageLogWithSentStatus()` | HTTP 200 → `messageService.createMessage(...)` called with `status=SENT`, correct processType/payload/url |
| `dispatchOne_terminal_writesMessageLogWithFailedStatus()` | HTTP 400 (terminal) → `messageService.createMessage(...)` called with `status=FAILED` |
| `dispatchOne_retry_writesMessageLogWithFailedStatus()` | HTTP 503, attempts < max → `messageService.createMessage(...)` called with `status=FAILED` |
| `dispatchOne_networkException_writesMessageLogWithFailedStatus()` | `httpRestService` throws → `writeServiceLog(...)` called with `status=FAILED`, `stateCode="503"` |
| `dispatchOne_messageServiceThrowsBusinessException_doesNotRevertMarkSent()` | `createMessage` throws `BusinessException` → `markSent` already called; no re-throw; `markRetry` NOT called |
| `dispatchOne_messageServiceThrowsRuntimeException_doesNotRevertMarkSent()` | `createMessage` throws `RuntimeException` → outbox row stays SENT; `LOG.error` called |

### 7.2 Integration Tests

No new Testcontainers test required (dispatch logic is unit-testable via mocks). Note: the `@Transactional(REQUIRES_NEW)` lives on `MessageService.createServiceLog` at line 75–76, not on the public `createMessage` overloads — the proxy is entered correctly for external callers like `OutboxDispatchService`, so no special test setup is needed.

### 7.3 Manual Test Plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| QA screen unblocked after pick | Dev/staging with wineco tenant | 1. Pick a regular order with no tote. 2. Release. 3. Check OMS QA screen. | Parcel advances to `parcel_status=25`; QA screen shows parcel, no "Picking status" error. | |
| Service Log populated | Dev/staging | 1. Complete a pick that triggers outbox PICKING_FINISHED. 2. Wait ≤30 s for OutboxDispatcherJob. 3. Admin → Service Log. | `ORDER_BATCH_PICKING_FINISHED` row visible with `status=SENT` and OMS response body. | |
| Sentinel stored and cleared at QA | Dev/staging | 1. After pick without tote, check OMS parcel `ul_code`. 2. Process QA pass. 3. Re-check `ul_code`. | `ul_code = "NO_TOTE"` pre-QA; `ul_code = null` post-QA. | |
| Existing CLUB order unchanged | Dev/staging | 1. Pick a CLUB order. 2. Check outbox payload. | `tote_label` is a UUID (not `"NO_TOTE"`); parcel advances normally. | |
| Service Log for BOL/Advice/Cancel | Dev/staging | 1. Close a BOL (or accept an advice / cancel an order). 2. Check Service Log. | BOL-close / advice / cancel entries now visible for all outbox-dispatched types. | |

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| OMS downstream code stores `"NO_TOTE"` permanently or groups by `ul_code` in analytics | Low — cleared at QA (`QaWorkflowService.php:366`); display/search only | Confirmed short-lived exposure. If OMS team adds `GROUP BY ul_code` reporting, `"NO_TOTE"` would appear as a synthetic "tote" with all pick-pack orders. Track as OQ-7: confirm with OMS team that `ul_code = 'NO_TOTE'` is excluded from analytics views, or change sentinel to `"NO_TOTE_" + customerOrder.getNumber()` for uniqueness. |
| `writeServiceLog` REQUIRES_NEW tx adds per-dispatch DB write | Negligible — one INSERT per outbox message; same load as pre-SBDEV-2238 legacy path | No action needed. Outbox batch size is ≤10; `OutboxDispatcherJob` tick is 15 s. |
| `SyspropService.getWmsInstanceName()` / `getOmsInstanceName()` missing or wrong name | Medium — logs would show incorrect sender/receiver in Service Log | Verify method names in Step P4 before implementation |
| Duplicate `message` rows on stale-IN_FLIGHT reclaim | Low — two SENT rows for the same dispatch | Acceptable; mirrors legacy retry behaviour. Rows are keyed by `id` sequence; no uniqueness constraint on `process + created_at`. |
| Fix A tests fail because `buildPickedPayloadJson` is `@Deprecated` in CLUB path | Low — method is retained public per PR #31 | Confirmed: `@Deprecated` annotation preserved, method still callable in tests. |

---

## 9. Acceptance / Verify Script

**Extend:** `sbdocs/9-System/scripts/verify-260520-picking-finished-oms-notification-fix.sh`

**Fix A additions (inline grep — same style as existing script):**
```bash
info "=== Fix A: NO_TOTE sentinel (260521) ==="
WMSCONST="$WMS2_SRC/service/WmsConstants.java"
MANAGE="$WMS2_SRC/service/ManageOrderService.java"
MANAGE_TEST="$(dirname "$WMS2_SRC")/test/java/net/aim_ai/wms/unit/service/ManageOrderServiceUnitTest.java"

# A1: sentinel constant declared in WmsConstants (content-level, not just file presence)
if grep -qE 'NO_TOTE_SENTINEL\s*=\s*"NO_TOTE"' "$WMSCONST"; then
  pass "WmsConstants declares NO_TOTE_SENTINEL = \"NO_TOTE\""
else
  fail "WmsConstants missing NO_TOTE_SENTINEL constant"
fi

# A2: sentinel referenced by name in ManageOrderService (not a magic inline string)
if grep -q 'NO_TOTE_SENTINEL' "$MANAGE"; then
  pass "ManageOrderService references NO_TOTE_SENTINEL"
else
  fail "ManageOrderService does not reference NO_TOTE_SENTINEL — magic string risk"
fi

# A3: sentinel is set via setToteLabel in buildPickedPayloadJson
if grep -q 'setToteLabel(WmsConstants.NO_TOTE_SENTINEL)' "$MANAGE"; then
  pass "buildPickedPayloadJson emits sentinel via setToteLabel"
else
  fail "buildPickedPayloadJson missing setToteLabel(WmsConstants.NO_TOTE_SENTINEL)"
fi

# A4: new no-tote test present
if grep -q 'nonClubNoTote_emitsSentinel' "$MANAGE_TEST"; then
  pass "ManageOrderServiceUnitTest has no-tote sentinel test"
else
  fail "ManageOrderServiceUnitTest missing nonClubNoTote_emitsSentinel"
fi

# A5 (regression): existing CLUB test still present
if grep -q 'clubOrder_emitsUuid\|buildPickedPayloadJson.*club\|club.*buildPickedPayloadJson' "$MANAGE_TEST"; then
  pass "ManageOrderServiceUnitTest retains CLUB regression test"
else
  fail "ManageOrderServiceUnitTest missing CLUB regression test — sentinel may have broken CLUB branch"
fi

# A6 (regression): existing tote-assigned test still present
if grep -q 'regularWithTote\|withTote.*emits\|tote.*label.*test' "$MANAGE_TEST"; then
  pass "ManageOrderServiceUnitTest retains tote-assigned regression test"
else
  fail "ManageOrderServiceUnitTest missing tote-assigned regression test"
fi
```

**Fix B additions (inline grep — same style as existing script):**
```bash
info "=== Fix B: OutboxDispatchService message-log write (260521) ==="
DISPATCH="$WMS2_SRC/service/job/OutboxDispatchService.java"
DISPATCH_TEST="$(dirname "$WMS2_SRC")/test/java/net/aim_ai/wms/unit/service/job/OutboxDispatchServiceUnitTest.java"

# B1: MessageService field injected (content-level — field declaration)
if grep -q 'MessageService messageService' "$DISPATCH"; then
  pass "OutboxDispatchService declares MessageService field"
else
  fail "OutboxDispatchService missing MessageService field"
fi

# B2: SyspropService also injected
if grep -q 'SyspropService syspropService' "$DISPATCH"; then
  pass "OutboxDispatchService declares SyspropService field"
else
  fail "OutboxDispatchService missing SyspropService field"
fi

# B3: writeServiceLog call sites — pattern 'writeServiceLog(msg,' excludes the helper definition
# Expected: exactly 4 call sites (2xx success, terminal, retry, catch)
B3_COUNT=$(grep -c 'writeServiceLog(msg,' "$DISPATCH" || true)
if [[ "$B3_COUNT" -ge 4 ]]; then
  pass "writeServiceLog(msg,...) called in ≥4 branches ($B3_COUNT found)"
else
  fail "writeServiceLog(msg,...) called in fewer than 4 branches ($B3_COUNT found — missing branch?)"
fi

# B4: best-effort BusinessException swallow in writeServiceLog
if grep -q 'catch.*BusinessException' "$DISPATCH"; then
  pass "writeServiceLog swallows BusinessException"
else
  fail "writeServiceLog missing BusinessException catch — not best-effort"
fi

# B5: OQ-5 counter present — 'wms2.outbox.message_log.failed' in both catch blocks
B5_COUNT=$(grep -c 'wms2.outbox.message_log.failed' "$DISPATCH" || true)
if [[ "$B5_COUNT" -ge 2 ]]; then
  pass "writeServiceLog increments message_log.failed counter in ≥2 catch blocks ($B5_COUNT found)"
else
  fail "writeServiceLog missing message_log.failed counter in catch blocks ($B5_COUNT found — expected ≥2)"
fi

# B6: new test class exists and has success test
if [[ -f "$DISPATCH_TEST" ]] && grep -q 'dispatchOne_success_writesMessageLogWithSentStatus' "$DISPATCH_TEST"; then
  pass "OutboxDispatchServiceUnitTest exists with success log test"
else
  fail "OutboxDispatchServiceUnitTest missing or lacks dispatchOne_success_writesMessageLogWithSentStatus"
fi
```

Expected final PASS count: ~24 (existing ~12 + ~12 new).  
**Final acceptance gate:** script reports `Result: N pass, 0 fail`.

---

## 10. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|---|---|
| OQ-1 | Is `"NO_TOTE"` safe for the OMS `ul_code` column? | **Resolved** — confirmed stored then cleared at QA (`QaWorkflowService.php:366`); no format constraint; minor search-noise risk is short-lived and acceptable. |
| OQ-2 | Should `OutboxDispatchService` also detect `{"Status":"Error"}` in the OMS body and mark FAILED? | **Out of scope** — body inspection requires OMS API contract change (agreed response schema); separate latent issue. Track as follow-up. |
| OQ-3 | Are other `OmsNotificationService.sendAfterCommit()` callers also affected by the double-afterCommit bug? | **Investigated in 260520 plan** — PR-A guard added; `OmsNotificationServiceUnitTest` verifies. Not in scope here. |
| OQ-4 | DB validation (§1 queries) | **Deferred** — wms2-wineco-dev MCP unavailable. Mark `db_verified: true` after manual queries confirm expected data state. |
| OQ-5 | Metric for audit-log failures | **Include in Fix B** — add `meters.counter("wms2.outbox.message_log.failed", "processType", msg.getProcessType()).increment()` inside the `catch (Exception e)` block of `writeServiceLog`. Without it the best-effort swallow recreates the silent-failure symptom Fix B was filed against. One counter, 1 line in `writeServiceLog`. |
| OQ-6 | Should Service Log admin query `outbox_message` directly instead of double-writing? | **Deferred** — `outbox_message` is already a complete audit record. A UNION-view in the omsv2-UI admin SQL would be architecturally cleaner (single source of truth) but requires a UI/reporting change across two repos. Dispatcher injection is the tactical fix; re-evaluate when the next outbox-only migration lands. |
| OQ-7 | Is `"NO_TOTE"` safe for OMS analytics / reporting queries that `GROUP BY ul_code`? | **Gate before merge** — confirm with OMS team before merging this PR. If any OMS reporting groups by `ul_code` without filtering nulls/sentinels, `"NO_TOTE"` would aggregate all pick-pack parcels into a phantom "tote". If confirmed unsafe, change `WmsConstants.NO_TOTE_SENTINEL` to `"NO_TOTE_" + customerOrder.getNumber()` — one line change in `buildPickedPayloadJson`. If OMS team not reachable within sprint, apply the per-order suffix by default (cheap, irreversible risk avoided). |

---

## 11. Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---------|---------|---------|
| 1 | In-JVM state (Caffeine / static / ThreadLocal) | **N/A** | No new in-JVM state introduced |
| 2 | Connection pool math — new DB writes per dispatch | **No regression** | `createMessage` opens a REQUIRES_NEW tx (one INSERT) and releases immediately; same connection load as pre-SBDEV-2238 `OmsNotificationService.doSend`; no net pool increase |
| 3 | Scheduled jobs — no new cron added | **N/A** | Existing `OutboxDispatcherJob` unchanged; no new job |
| 4 | Long transactions | **N/A** | `dispatchOne` runs with no tx; `writeServiceLog` is REQUIRES_NEW short tx |
| 5 | Request affinity | **N/A** | Outbox dispatcher is stateless per-row |
| 6 | Retry / idempotency | **Acceptable** | Duplicate `message` rows possible if stale-IN_FLIGHT reclaim re-dispatches; mirrors existing retry behaviour; no uniqueness constraint violated |
| 7 | Tenant context propagation | **Safe** | `OutboxDispatcherJob` sets `TenantContext` per-tenant; `SyspropService` and `MessageService` are tenant-scoped; `writeServiceLog` inherits the already-set context |
| 8 | Distributed lock correctness | **N/A** | Advisory lock 100008L on `OutboxDispatcherJob` unchanged; `writeServiceLog` needs no additional lock |
| 9 | Cache invalidation | **N/A** | `message` table is not cached |
| 10 | External notifications — deferred to afterCommit | **N/A** | `writeServiceLog` is an audit-log write, not a further external notification |

---

## 12. v2 Constraint Checklist

| # | Constraint | Verdict | Evidence |
|---|------------|---------|---------|
| 1 | OSIV disabled — no lazy-load outside tx | **N/A** | `dispatchOne` operates on `OutboxMessage` fields only; all accessed before the tx boundary |
| 2 | Tenant tx manager — `@Transactional` specifies `tenantTransactionManager` | **N/A** | No new `@Transactional` on `OutboxDispatchService` (already non-transactional); `MessageService.createMessage` already correctly uses `tenantTransactionManager` |
| 3 | `@Transactional(readOnly=true)` on read-only methods | **N/A** | No new read-only methods |
| 4 | Caffeine cache invalidation | **N/A** | `message` table not cached |
| 5 | Jakarta namespace (not `javax.*`) | **Yes — verify** | Ensure any new imports use `jakarta.persistence` / `jakarta.transaction`; no `javax.*` in new code |
| 6 | H2-compatible test SQL | **N/A** | No new repository queries; no native SQL |
| 7 | `BaseControllerTest` for controller changes | **N/A** | No controller changes |
| 8 | Micrometer metrics — existing counters preserved | **Yes** | All 3 existing `wms2.outbox.dispatched{outcome=*}` counters preserved; add `wms2.outbox.message_log.failed{processType}` in `writeServiceLog` catch block (OQ-5) |

---

## 13. ADR

**Decision:** Fix the missing `tote_label` by adding a sentinel value `"NO_TOTE"` and fix the Service Log gap by injecting `MessageService` into `OutboxDispatchService`.

**Drivers:**
1. OMS `finishedPicking` requires non-empty `tote_label` to advance parcel to QA — the only path that unblocks the QA screen
2. Service Log is the operator's primary forensic tool; the outbox migration silently disabled it for all 9 notification types
3. Both fixes must not introduce rollback risk for the outbox state machine

**Alternatives considered:**
- CO number as tote fallback: rejected — muddies `ul_code` semantics; column is also a tote-scan search target
- Force `pickingtoteId` non-null: rejected — high blast radius across all picking controllers
- Per-caller `createMessage` at enqueue sites: rejected — only the dispatcher has the OMS HTTP response (code + body)
- OMS body-inspection for `{"Status":"Error"}`: deferred — requires OMS API contract change (agreed response schema)
- **UNION-view in Service Log admin UI:** The `outbox_message` table already carries payload, status, process_type, and destination — every column the `message` table holds. Retrofitting the admin SQL to `UNION outbox_message` would be architecturally cleaner (single source of truth, no double-write). Rejected for this plan because: (a) the admin UI lives in omsv2-UI — a cross-repo change with higher coordination cost than a 30-line WMS dispatcher patch; (b) the legacy `message` row carries `sender`/`receiver` fields (WMS instance name, OMS instance name) that `outbox_message` does not; (c) downstream alerting may read `message` directly. Re-evaluate when the next outbox-only migration lands (OQ-6).

**Why chosen:** Smallest viable diffs. Both fixes are single-file changes. Sentinel is OMS-safe (stored then cleared). Dispatcher injection mirrors the exact legacy `OmsNotificationService.doSend` pattern without adding new abstractions.

**Consequences:** After Fix A, all regular pick-pack orders advance to QA regardless of tote assignment. After Fix B, Service Log shows all outbox-dispatched notifications (PICKING_FINISHED, ADVICE, BOL_CLOSE, CANCEL, etc.).

**Follow-ups:**
- OQ-2: OMS body-inspection for `{"Status":"Error"}` (separate plan)
- OQ-5: `wms2.outbox.message_log.failed` counter — include in Fix B (1 line in `writeServiceLog` catch)
- OQ-6: UNION-view in Service Log admin UI (longer-term, cross-repo, re-evaluate after next outbox migration)
- OQ-7: Confirm `"NO_TOTE"` sentinel excluded from any OMS `GROUP BY ul_code` analytics
- P4: Confirm `SyspropService.getWmsInstanceName()/getOmsInstanceName()` method names before implementation

---

## 14. Implementation Status

*To be filled in after implementation.*
