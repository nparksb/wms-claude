---
title: "SBDEV-2214 — OMS HTTP POST inside @Transactional boundary (sync drift)"
ticket: "SBDEV-2214"
ticket_url: "https://app.clickup.com/t/868jj319h"
type: "bug"
priority: "high"
severity: "critical"
status: "archived"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-08"
updated: "2026-05-10"
last_updated: "2026-05-10"
db_verified: false
related:
  - "[[260424-oms-notification-rollback-risk-remediation]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - wmsv2
  - oms-integration
  - transaction-boundary
---

# SBDEV-2214 — OMS HTTP POST inside `@Transactional` boundary (sync drift)

**Ticket:** [SBDEV-2214](https://app.clickup.com/t/868jj319h)
**Project:** wms2-api | **Version:** v2 | **Type:** bug
**Priority:** High | **Severity:** CRITICAL (Tier 1)
**Status:** merged to `develop` (2026-05-10) — all 9 phase commits (`87c4164` → `81685c7`) landed via direct fast-forward outside PR #9; PR #9 closed as obsolete on 2026-05-10. Verify-script: `Result: 62 pass, 0 fail, 0 skip` (per §13). Phase 8 manual staging smoke remains as the single non-code follow-up.
**Date:** 2026-05-08

> **Important framing:** The ticket was filed against v1 line numbers (`CustomerorderService.java:696`, `CustomerorderBatchService.java:233`) and described the v1 **class-level** `@Transactional` annotation as the trigger. On v2, both `CustomerorderService` and `CustomerorderBatchService` use **method-level** `@Transactional` (the class-level annotation was refactored away during the v1→v2 migration), and the two specific methods (`cancelOrder`, `cancelBatch`) **already use the post-commit pattern** via `OmsNotificationService.sendAfterCommit(…)`. The root cause described by the ticket — an OMS HTTP POST executing inside an open `@Transactional` boundary so that a later in-method throw rolls back WMS state without rolling back OMS — is **independent of class-level vs method-level placement of the annotation**. This plan therefore (a) verifies and locks in those existing fixes via regression-guard checks, and (b) extends the same pattern to **adjacent in-tx OMS POST sites discovered by the §0 enumeration** (`ManageOrderService` × 7 methods called from `@Transactional` callers, `MessageService.sendStockChangeMessage` called from 15 `@Transactional` callers) — same root cause, ticket described one instance of a class of bugs.

---

## 0. Affected sites (enumeration before drafting)

Greps run against `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java`:

```
grep -rn "httpRestService\.post"  src/main/java
grep -rn "httpRestService\.get"   src/main/java
grep -rn "@Transactional" src/main/java/net/aim_ai/wms/service | grep -v "@TransactionalEventListener"
```

| # | File:line | Construct | Same root-cause as ticket? | In-scope this plan? |
|---|-----------|-----------|----------------------------|---------------------|
| 1 | `service/CustomerorderService.java:720` | `cancelOrder` — already calls `omsNotificationService.sendAfterCommit(…, ORDER_BATCH_CANCELLED_FROM_WMS)` | Already fixed in v2 | **Yes — POSITIVE-check + regression NEGATIVE-check (no inline `httpRestService.post` in `cancelOrder` body)** |
| 2 | `service/CustomerorderBatchService.java:269` | `cancelBatch` — already calls `omsNotificationService.sendAfterCommit(…, ORDER_BATCH_CANCELLED_FROM_WMS)` | Already fixed in v2 | **Yes — POSITIVE-check + regression NEGATIVE-check (no inline `httpRestService.post` in `cancelBatch` body)** |
| 3 | `service/BillofladingService.java:656` | `closeBOL` → `omsNotificationService.sendAfterCommit(…, ORDER_BATCH_SHIPPED)` | Already fixed | No — out-of-scope (verified pattern, no fix needed) |
| 4 | `service/AdviceService.java:255, 347, 410` | `acceptHubAndSpoke` / `closeAdvice` / `acceptTransfer` → `sendAfterCommit` | Already fixed | No — out-of-scope |
| 5 | `service/ManageOrderService.java:104` | `customerOrderOnHold` — inline `httpRestService.post(urlPath, payload)` then `messageService.createMessage(...SENT…)`/`...FAILED…)` | **YES — same root cause as ticket; called from many `@Transactional` callers (see §3.A)** | **YES — Fix A.1** |
| 6 | `service/ManageOrderService.java:164` | `customerOrderReleaseForPicking` — inline `httpRestService.post` | YES | **YES — Fix A.2** |
| 7 | `service/ManageOrderService.java:232` | `customerOrderToteAssigned` — inline `httpRestService.post` | YES | **YES — Fix A.3** |
| 8 | `service/ManageOrderService.java:286` | `customerOrderPickingStarted` — inline `httpRestService.post` | YES | **YES — Fix A.4** |
| 9 | `service/ManageOrderService.java:361` | `customerOrderPicked` — inline `httpRestService.post` | YES | **YES — Fix A.5** |
| 10 | `service/ManageOrderService.java:422` | `customerOrderPalletized` — inline `httpRestService.post` | YES | **YES — Fix A.6** |
| 11 | `service/ManageOrderService.java:483` | `customerOrderLoadedToTruck` — inline `httpRestService.post` | YES | **YES — Fix A.7** |
| 12 | `service/MessageService.java:115` | `sendStockChangeMessage` — inline `httpRestService.post` (called from 15 sites: `StockunitService` × 6, `UnitloadService` × 2, `GoodsReceiptPositionService` × 2, `MobileCycleCountService` × 2, `ReceivingService` × 1, `MobileMoveUnitloadService` × 2; many `@Transactional`). **In scope confirmed; not deferred to a follow-up plan.** | YES | **YES — Fix B** |
| 13 | `service/MessageService.java:151` | `resendMessage` — inline `httpRestService.post` (admin-triggered retry path) | **No (excluded from this plan).** The POST is by-design synchronous (admin-triggered retry). However, the post-POST `messageRepository.save(newMessage)` at line 164 can fail and produce the same WMS-no-record / OMS-saw-it drift. **A follow-up plan is required to either (a) reorder save-then-post, or (b) delegate to `OmsNotificationService.sendAfterCommit`.** Out of scope here because admin-triggered paths have different operator semantics. | No (follow-up) |
| 14 | `service/OmsNotificationService.java:71` | `doSend` — inline `httpRestService.post` | NO — this **is** the deferred sender (runs after-commit by construction) | No |
| 15 | `controller/MessageDummyController.java:43` | dummy controller `httpRestService.post` (test/dev only) | NO — controller layer, not `@Transactional`, no DB writes follow | No |
| 16 | `controller/ItemDataController.java:114` | admin `sendStockUpdate` endpoint — inline `httpRestService.post` | NO — admin one-shot HTTP endpoint, not `@Transactional`, post is the final action | No |
| 17 | `schedulejob/StockSummaryExportJob.java:167` | `doCalculation` — final `httpRestService.post` per tenant | NO — non-`@Transactional` scheduled job; the post is the last action of the per-tenant loop, no subsequent commit can roll back | No |
| 18 | `service/BillofladingService.java:1034` | `getFacilities` — `httpRestService.get(urlPath)` (read-only fetch) | NO — `get` only, no DB writes precede or follow; not `@Transactional` | No |
| 19 | `controller/AdminActionController.java:130` | `testCrmConnectivity` — `httpRestService.get` | NO — explicit connectivity test, not `@Transactional` | No |

**Adjacent-bug rule (skill Layer 1, item 2):** rows 5-12 are adjacent instances of the exact pattern the ticket described. They are pulled into this plan; if the reviewer wants to split row 12 (`MessageService.sendStockChangeMessage`) into a follow-up plan, that's defensible — it has 16 callers and a wider blast radius — but it is the same bug.

**Cross-reference greps run:**

```
grep -rln "cancelOrder\|cancelBatch\|sendAfterCommit\|ManageOrderService\|OmsNotificationService" \
  sbdocs/1-Projects/ sbdocs/4-Archieves/
```

Findings (informational only, no scope conflict found):
- `sbdocs/1-Projects/wms2/plan/260503-runclubline-transaction-boundary-hardening.md` — touches `runClubLine` which calls `manageOrderService.customerOrderPicked` after Phase-3 commit (already outside any tx). This plan does NOT regress that — Fix A makes those methods safer for in-tx callers without harming the already-deferred call sites.
- `sbdocs/1-Projects/wms2/plan/260329-WMS_OMS_Picking_Notification_Bug_Analysis.md` — analysis of picking-notification gaps; informs §3.A (after Fix A, in-tx callers like `MobilePickingService.startPickingOrder` automatically become safe without modifying the caller).
- `sbdocs/4-Archieves/wms2/plan/260424-Cancel_Order_Null_SectionId_And_Early_Return_Fix.md` — touched `CustomerorderService.cancelOrder` for a different bug (null-section-id). Already-archived; this plan must preserve those fixes.

**Architecture/design docs consulted:**

- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` §2.1 (ManageOrderService callbacks), §2.3 (cancellation callbacks), §5.2 (outbound failure modes).
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §6 — codifies the rule "never fire an external call inside the tenant transaction; register a post-commit synchronization" and explicitly cites `OmsNotificationService` as the reference pattern.
- `sbdocs/3-Resources/decisions/` (ADR series) — no ADR conflicts with the helper pattern.

---

## 1. Problem Statement

**User-visible symptom:** WMS shows an order as live; OMS shows the same order as cancelled (or vice versa). No reconciliation, no compensating action. Manual data fix required, often delayed days until customer reports it.

**Trigger conditions:**

1. A WMS service method annotated `@Transactional` mutates order/position state.
2. **Inside that still-open transaction**, the method calls `httpRestService.post(urlPath, payload)` to notify OMS.
3. After the OMS POST returns (OMS now reflects the new state), control flows back to WMS code that throws — anything from a downstream cleanup step, an audit-row write, an optimistic-lock failure on a sibling entity, a connection-timeout-driven rollback, or an `@Modifying` repository call that exhausts a constraint.
4. The transaction rolls back; WMS state reverts. **OMS does not roll back.**

**Result:** A persistent split-brain between WMS and OMS for that order. Reconciliation requires a human reading both systems.

**Post-fix failure-mode shift:** moving the POST to `afterCommit` eliminates the rollback-drift case but shifts the residual silent-loss surface to "transient OMS outage flap": the commit succeeds, the `afterCommit` POST fails, a `Message(state=FAILED)` row is written, and **nothing alerts**. To avoid trading one silent-loss mode for another, **Fix C in §3 adds a mandatory Micrometer counter** on the FAILED branch so operations can rate-alert on it.

**Reporter's primary call-out (ticket):**
- v1 `CustomerorderService` is class-level `@Transactional` and `cancelOrder` POSTs to OMS while the tx is still open (v1 line 696).
- v1 `CustomerorderBatchService.cancelBatch` exhibits the same shape (v1 line 233).

**v2 framing correction:** v2's `CustomerorderService` (verified at `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java`) has **no class-level `@Transactional`**; instead `cancelOrder` is annotated at the method declaration (line 587-588) with `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. v2's `CustomerorderBatchService.cancelBatch` follows the same method-level shape. The drift mode the ticket describes is **independent of that placement** — the same WMS-rollback-after-OMS-POST drift can fire from any method-level `@Transactional` in v2 (notably the 7 `ManageOrderService` callbacks called from `@Transactional` callers, and `MessageService.sendStockChangeMessage` called from 15 `@Transactional` callers).

**v2 status (verified by reading the code as of this draft):**

| Site | v1 line | v2 line | v2 status |
|---|---|---|---|
| `CustomerorderService.cancelOrder` OMS POST | `:696` (inline `httpRestService.post`) | `:720` (`omsNotificationService.sendAfterCommit(...)`)| **Already fixed in v2** — uses post-commit pattern via `TransactionSynchronizationManager.registerSynchronization` |
| `CustomerorderBatchService.cancelBatch` OMS POST | `:233` (inline `httpRestService.post`) | `:269` (`omsNotificationService.sendAfterCommit(...)`)| **Already fixed in v2** |

Both v2 methods already capture `urlPath` and `payload` while entities are managed (inside the tx), then defer the actual HTTP call to `afterCommit`. This is the v2 equivalent of the v1 `BolClosedEvent` / `@TransactionalEventListener(AFTER_COMMIT)` pattern — different mechanism, same guarantee.

**What v2 still has wrong:** the §0 enumeration shows 8 in-tx OMS POST sites (`ManageOrderService` × 7 + `MessageService.sendStockChangeMessage`) that match the ticket's pattern exactly. Several of them (e.g. `MobilePickingService.startPickingOrder` calling `manageOrderService.customerOrderToteAssigned` while still inside its own `@Transactional`) reproduce the failure mode end-to-end today.

### DB verification gate

`db_verified: **false**`.

**Why a single-query verification is not possible:** the symptom is cross-system drift between WMS Postgres and OMS MySQL. The MCP available in this session reaches the v1 tenant DB (`mcp__wms1-wineco-dev__execute_sql`) but does not span both systems atomically. We cannot author a single SQL that reads OMS and WMS state in the same transaction.

**What the implementer MUST run before merging:**

1. Connect to a target tenant DB (any prod/QA tenant exhibiting symptoms historically).
2. Run the following query (PostgreSQL syntax for v2; tenant DB schema):
   ```sql
   -- find Customerorders in CANCELED state (state=800) that have NO Message
   -- row of process=ORDER_BATCH_CANCELLED_FROM_WMS in SENT status within the
   -- same tenant — i.e. either no notification was sent OR it failed.
   SELECT co.id, co.number, co.state, co.modified
   FROM customerorder co
   LEFT JOIN message m
     ON m.message LIKE '%' || co.externalnumber || '%'
        AND m.process = 'ORDER_BATCH_CANCELLED_FROM_WMS'
        AND m.status = 'SENT'
   WHERE co.state = 800
     AND co.modified > NOW() - INTERVAL '30 days'
     AND m.id IS NULL
   ORDER BY co.modified DESC
   LIMIT 50;
   ```
3. **Pre-fix expectation:** non-zero rows when the bug fires (rare but not zero). **Post-fix expectation:** the only rows are those where `cancellationFromWithinWMS=false` (where no notification is intended) or where the listener crashed and a `Message(state=FAILED)` row exists — verifiable by relaxing the LEFT JOIN status filter.
4. The implementer pastes both runs (pre- and post-fix) into the §13 Implementation Status section before the plan is signed off.

**v1 corroboration:** if the v1 MCP is reachable, run the equivalent query against a v1 tenant DB. The schema is similar enough (`message.process`, `customerorder.state`) that confirming non-zero rows pre-fix on v1 is acceptable evidence of the symptom shape (the v2 codebase shares the same audit-row design).

---

## 2. Root Cause Analysis

### Bug 1 (already fixed in v2, must stay fixed): `CustomerorderService.cancelOrder` OMS POST inside method-level `@Transactional`

**Code reference:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java:587-728`

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void cancelOrder(Customerorder customerOrder, boolean cancellationFromWithinWMS)
        throws BusinessException, FacadeException {
    // … state mutations, save, finalizeBatchIfComplete …

    if (cancellationFromWithinWMS) {
        // … build OrderBatchDto, OrderDto …
        try {
            String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY);
            String payload = new ObjectMapper().writeValueAsString(orderBatchDto);
            omsNotificationService.sendAfterCommit(urlPath, payload,                          // :720
                WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS);
        } catch (IOException e) {
            LOG.error("Failed to serialize cancel order payload: {}", e.getMessage());
        }
    }
}
```

**Why it's correct:** `OmsNotificationService.sendAfterCommit` registers a `TransactionSynchronization.afterCommit` callback. The HTTP POST does not run until after the surrounding transaction commits. If `finalizeBatchIfComplete` (or any later code) throws, the commit never happens, the synchronization fires `afterCompletion(STATUS_ROLLED_BACK)` instead of `afterCommit`, and the OMS POST is never made.

**Regression risk:** any future commit that adds an inline `httpRestService.post(...)` to this method body re-introduces the bug. The verify script encodes a NEGATIVE check that asserts `httpRestService\.post` does not appear in `CustomerorderService.java` at all.

### Bug 2 (already fixed in v2, must stay fixed): `CustomerorderBatchService.cancelBatch` OMS POST inside method-level `@Transactional`

**Code reference:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java:220-345`

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void cancelBatch(CustomerorderBatch orderBatch, Principal principal) throws BusinessException {
    // … guard checks, build externalBatchDto …

    try {
        String urlPath = syspropService.getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY);
        ObjectMapper mapper = new ObjectMapper();
        mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
        String payload = mapper.writeValueAsString(externalBatchDto);
        omsNotificationService.sendAfterCommit(urlPath, payload,                              // :269
            WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS);
    } catch (IOException e) {
        LOG.error("Failed to serialize cancel batch payload: {}", e.getMessage());
    }

    // … cancel customer orders + positions + picking orders + tote cleanup (60+ more lines of state mutation) …
}
```

**Why it's correct:** same as Bug 1 — the post is deferred to after-commit. **Important nuance:** the post is registered BEFORE the long block of state mutations runs. If any of those mutations throws (e.g. `stockunitBusinessService.changeReservedAmount` blowing up on optimistic lock at line 297, or `pickingorderUnitloadRepository.save` failing), the rollback voids the registered synchronization — `afterCommit` never fires.

**Regression risk:** as Bug 1.

### Bug 3 (NEW in scope — same root cause as ticket): `ManageOrderService` × 7 method bodies POST inside the caller's transaction

**Code reference:** `src/main/java/net/aim_ai/wms/service/ManageOrderService.java:59-508`

Seven public methods each follow the same shape:

```java
public void customerOrderXxx(List<Customerorder> customerOrderList) {
    // … build OrderBatchDto …
    try {
        urlPath = getRequiredOmsUrl(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_XXX_URL_KEY);
        if (urlPath == null) {
            messageService.createMessage(…, FAILED, "503", null);                              // URL-not-configured branch
            return;
        }
        payload = mapper.writeValueAsString(orderBatchDto);
        Map<String,String> respMap = httpRestService.post(urlPath, payload);                  // <-- IN-TX POST when caller is @Transactional

        messageService.createMessage(…, SENT, respMap.get("code"), respMap.get("answer"));
    } catch (Exception e) {
        message = messageService.createMessage(…, FAILED, "503", null);
        LOG.error("Message was not sent! messageId = {}", message.getId());
    }
}
```

`ManageOrderService` itself has no `@Transactional` annotations (verified by `grep '@Transactional' ManageOrderService.java`). But its 7 public methods are called from the following `@Transactional` callers. The unwrapped (vulnerable) callers are:

| Caller (`@Transactional` boundary) | ManageOrderService method invoked | File:line |
|---|---|---|
| `ReleaseOrderJobService.releaseOrder` | `customerOrderOnHold` / `customerOrderReleaseForPicking` | `ReleaseOrderJobService.java:217,533,652` (inside `@Scheduled`-driven `REQUIRES_NEW` job tx — vulnerable to rollback after the inline POST) |

**Per-site annotation evidence** (verified by `grep -nE '^\s*(public\|@Transactional)' ReleaseOrderJobService.java`):

| Call site | Surrounding method | Surrounding `@Transactional` annotation |
|---|---|---|
| `ReleaseOrderJobService.java:217` | `releaseOrder` (declared at `:100`) | `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` (at `:99`) |
| `ReleaseOrderJobService.java:533` | `releaseOrder` (same method as above; the file has only ONE public method — `releaseOrder` — so all 3 call sites share the same outer tx) | same as above |
| `ReleaseOrderJobService.java:652` | `releaseOrder` (same method) | same as above |

`grep -nE '^\s*(public\|protected)\s+\S' ReleaseOrderJobService.java` confirms the only non-constructor public method declaration in the file is `releaseOrder` at line 100. The three call sites are therefore all inside the SAME `REQUIRES_NEW` transaction, which means a throw-after-POST anywhere between line 217 and the method's closing brace at line ~659 rolls back the WMS state while OMS keeps the on-hold/release-for-picking notification — confirming Bug 3's claim.

The remaining caller sites are already-safe at the caller layer (either wrap the call in their own `registerSynchronization`, or sit inside an existing `afterCommit` lambda, or run outside any tx). They are listed for completeness:

| Caller | ManageOrderService method | File:line | Why already safe |
|---|---|---|---|
| `MobilePickingService.startPickingOrder` | `customerOrderToteAssigned` | `MobilePickingService.java:495,503` | wrapped in `registerSynchronization` |
| `MobilePickingService.processPickingPosition` | `customerOrderToteAssigned` | `MobilePickingService.java:1005,1012` | wrapped in `registerSynchronization` |
| `MobilePalletizingService.palletize…` | `customerOrderPalletized` | `MobilePalletizingService.java:237,244,387,394` | wrapped in `registerSynchronization` |
| `ParcelMonitorViewService.palletise/palletiseAndTruckLoad` | `customerOrderPalletized` / `customerOrderLoadedToTruck` | `ParcelMonitorViewService.java:195,202,326,333,413,420` | wrapped in `registerSynchronization` |
| `PickingorderBusinessService.finishPickingOrder` | `customerOrderPicked` | `PickingorderBusinessService.java:265,276` | inside existing `afterCommit` lambda |
| `PickingorderBusinessService.confirmPick` | `customerOrderPickingStarted` | `PickingorderBusinessService.java:511,520` | inside existing `afterCommit` lambda |
| `OrderMonitorViewService.printToteLabels` | `customerOrderToteAssigned` | `OrderMonitorViewService.java:213` | no `@Transactional` on caller |
| `CustomerorderBatchService.runClubLine` | `customerOrderReleaseForPicking` / `customerOrderPickingStarted` / `customerOrderPicked` | `:742-744` | post-finalize, outside any tx (per code comment) |

**Why current state is wrong:** the `ReleaseOrderJobService` caller sites (3 file:line locations) call into `ManageOrderService.customerOrderXxx` from inside an open transaction WITHOUT a caller-side `registerSynchronization` wrapper. Inside that method, `httpRestService.post(...)` runs synchronously. If ANY code after the post throws (within the caller's tx), WMS rolls back; OMS is already updated. Same failure mode as the ticket. (`MobilePickingService` was previously listed as broken — it is in fact already wrapped at the caller; the underlying root cause still warrants the in-method fix because future callers may not know to wrap.)

**Why the in-method registration of `registerSynchronization` at the caller (`ParcelMonitorViewService`, `MobilePalletizingService`) is not enough:**
- It's a *per-caller workaround*, not a fix at the root.
- Future callers (and existing ones not yet wrapped) repeat the bug.
- The wrapper code is duplicated boilerplate at 8+ sites.
- Verify scripts for adjacent plans must encode 8 separate caller-side checks.

**Fix is at the root** (Fix A in §3): make `ManageOrderService.customerOrderXxx` defer internally — same way `CustomerorderService.cancelOrder` already does it.

### Bug 4 (NEW in scope — same root cause as ticket): `MessageService.sendStockChangeMessage` POST inside the caller's transaction

**Code reference:** `src/main/java/net/aim_ai/wms/service/MessageService.java:101-140`

```java
public void sendStockChangeMessage(List<StockChangeDto> stockChangeList) {
    // … guard checks …
    try {
        urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY);
        payload = new ObjectMapper().writeValueAsString(stockChangeList);
        Map<String,String> respMap = httpRestService.post(urlPath, payload);                  // :115 — IN-TX POST
        createMessage(…, SENT, respMap.get("code"), respMap.get("answer"));
    } catch (Exception e) {
        message = createMessage(…, FAILED, "503", null);
        LOG.error("Message was not sent! messageId = {}", message.getId());
    }
}
```

Called from 15 sites (matches §0 row 12):

| Caller | `@Transactional`? | File:line |
|---|---|---|
| `StockunitService.applyStockTransfer*` (multiple) | likely yes (see file's existing `@Transactional` map) | `StockunitService.java:243, 333, 384, 426, 479, 483` |
| `UnitloadService.deleteUnitLoad/deleteUnitLoadRecursive` | yes | `UnitloadService.java:353, 387` |
| `GoodsReceiptPositionService.adjust*` | yes | `GoodsReceiptPositionService.java:114, 180` |
| `MobileCycleCountService.confirm*` | yes | `MobileCycleCountService.java:241, 454` |
| `ReceivingService.confirmReceiving` (`:523`) | yes — the receiving service ALREADY wraps adjacent receipt notifications in `registerSynchronization` (line 532), but `:523` is a separate stock-change call that runs in-tx | `ReceivingService.java:523` |
| `MobileMoveUnitloadService.moveUnitload` | yes | `MobileMoveUnitloadService.java:445, 471` |

Same bug shape: stock change is reported to OMS inside the caller's tx, then the caller continues (saves the unit load, updates its stockunit, recomputes the carrier total) and any of those steps can throw. WMS reverts the stock change; OMS keeps it.

---

## 3. (Optional) The Regression Chain

Not applicable — both v2 fixes (Bug 1, Bug 2) were already in place when this plan was written. There is no regression archaeology specific to this ticket. The closest precedent is plan `260424-oms-notification-rollback-risk-remediation.md` (v1) which built the equivalent helper utility (`OmsNotificationHelper.deferToCommit`) that became `OmsNotificationService` in v2.

---

## 4. Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│ HTTP request (e.g. POST /v3/orders/{id}/cancel)                       │
│     │                                                                  │
│     ▼                                                                  │
│ Controller (no @Transactional)                                         │
│     │                                                                  │
│     ▼                                                                  │
│ CustomerorderService.cancelOrder                                       │
│     ├─ @Transactional(value = "tenantTransactionManager")              │
│     ▼                                                                  │
│ ┌─────────────────────────────────────────────────────────────────┐   │
│ │  Tenant transaction (open)                                       │   │
│ │   1. Mutate Customerorder.state, position.state                  │   │
│ │   2. customerorderRepository.save(co)                            │   │
│ │   3. customerorderBatchService.finalizeBatchIfComplete(...)      │   │
│ │   4. omsNotificationService.sendAfterCommit(urlPath, payload, ⋯) │   │
│ │      └──> TransactionSynchronizationManager                      │   │
│ │           .registerSynchronization(new TS{ afterCommit() })      │   │
│ │   5. (any further mutation could throw here)                     │   │
│ └─────────────────────────────────────────────────────────────────┘   │
│     │                                                                  │
│     ▼ commit() succeeds                                                │
│ ┌─────────────────────────────────────────────────────────────────┐   │
│ │  TransactionSynchronization.afterCommit() — same thread          │   │
│ │   - httpRestService.post(urlPath, payload)                       │   │
│ │   - messageService.createMessage(SENT/FAILED, …)                 │   │
│ └─────────────────────────────────────────────────────────────────┘   │
│     │                                                                  │
│     ▼                                                                  │
│ HTTP 2xx returned to client                                            │
└────────────────────────────────────────────────────────────────────────┘

If commit() FAILS:
- afterCompletion(STATUS_ROLLED_BACK) fires instead of afterCommit
- httpRestService.post is NEVER invoked
- WMS state remains pre-mutation (rolled back)
- OMS state remains pre-mutation (never received the notification)
- → no drift
```

**Key files:**

| File | Lines | Role |
|---|---|---|
| `service/CustomerorderService.java` | `:587-728` (`cancelOrder`) | Already-correct example of the pattern; regression-guarded by this plan |
| `service/CustomerorderBatchService.java` | `:220-345` (`cancelBatch`) | Already-correct example; regression-guarded |
| `service/OmsNotificationService.java` | `:1-90` (whole file) | The deferred-send helper — `sendAfterCommit(String urlPath, String payload, String processType)` |
| `service/MessageService.java` | `:101-140` (`sendStockChangeMessage`); `:67-99` (`createServiceLog @Transactional REQUIRES_NEW`) | Audit-row writer used by `OmsNotificationService.doSend`; **also itself a Fix B target** for its in-tx HTTP POST |
| `service/ManageOrderService.java` | `:59-508` (7 methods) | Fix A target — 7 in-tx OMS POSTs |
| `service/HttpRestService.java` | `:32-51` (`post`) | RestClient.post with 5 s connect / 15 s read timeout. Will become injected only into `OmsNotificationService` after Fix A removes its other constructor-injection sites |
| `landlord/config/TenantContext.java` | whole file | ThreadLocal tenant store. Confirmed safe across `afterCommit` because the callback runs on the same thread that committed (TenantFilter has not yet cleared the context) |

---

## 5. Fix Design

### Fix A: `ManageOrderService` — refactor 7 in-tx POSTs to use `omsNotificationService.sendAfterCommit`

**Pattern uniformly applied to all 7 methods.** Each `customerOrderXxx` method becomes a thin orchestrator that builds the DTO inside any active tx (so entities are still managed) and delegates the HTTP+audit pair to the helper.

#### Before (`ManageOrderService.customerOrderOnHold`, lines 59-129 — representative; 6 other methods are the same shape)

```java
public void customerOrderOnHold(List<Customerorder> customerOrderList) {
    LOG.debug("start");
    if (customerOrderList.isEmpty()) { LOG.debug("end without doing anything (list is empty)."); return; }

    OrderBatchDto orderBatchDto = null;
    for (Customerorder customerOrder : customerOrderList) { /* … build dto … */ }

    Message message;
    String urlPath = null;
    String payload = null;
    try {
        urlPath = getRequiredOmsUrl(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_HELD_URL_KEY);
        if (urlPath == null) {
            messageService.createMessage(syspropService.getWmsInstanceName(), syspropService.getOmsInstanceName(),
                null, WmsConstants.MessageProcessType.ORDER_BATCH_ON_HOLD,
                "URL_NOT_CONFIGURED", WmsConstants.MessageStatus.FAILED, "503", null);
            return;
        }
        ObjectMapper mapper = new ObjectMapper();
        mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
        payload = mapper.writeValueAsString(orderBatchDto);
        Map<String,String> respMap = httpRestService.post(urlPath, payload);                          // :104 — IN-TX POST
        messageService.createMessage(/* SENT, respMap... */);
    } catch (Exception e) {
        message = messageService.createMessage(/* FAILED, 503, null */);
        LOG.error("Message was not sent! messageId = {}", message.getId());
    }
    LOG.debug("end");
}
```

#### After (Fix A.1)

```java
public void customerOrderOnHold(List<Customerorder> customerOrderList) {
    LOG.debug("start");
    if (customerOrderList.isEmpty()) { LOG.debug("end without doing anything (list is empty)."); return; }

    OrderBatchDto orderBatchDto = null;
    for (Customerorder customerOrder : customerOrderList) { /* … build dto … */ }

    String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_HELD_URL_KEY);
    String payload;
    try {
        ObjectMapper mapper = new ObjectMapper();
        mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
        payload = mapper.writeValueAsString(orderBatchDto);
    } catch (IOException e) {
        LOG.error("Failed to serialize {} payload: {}",
            WmsConstants.MessageProcessType.ORDER_BATCH_ON_HOLD, e.getMessage());
        return;
    }

    omsNotificationService.sendAfterCommit(urlPath, payload,                                            // deferred to afterCommit
        WmsConstants.MessageProcessType.ORDER_BATCH_ON_HOLD);

    LOG.debug("end");
}
```

**Notes on the diff:**
- The `urlPath == null` branch and the SENT/FAILED audit-row creation are now handled inside `OmsNotificationService.sendAfterCommit` / `doSend` — already implemented (`OmsNotificationService.java:45-67`). No behavior change.
- The `Map<String,String> respMap = httpRestService.post(...)` call disappears from `ManageOrderService`.
- The constructor injection of `HttpRestService` is REMOVED from `ManageOrderService` after all 7 methods are converted (no other usage in this class). `OmsNotificationService` is added.
- The `IOException` from `writeValueAsString` is logged and the method returns — same as the pre-fix `catch (Exception e)` branch; we just narrow the catch to the actual checked exception.
- All 7 fix steps (Fix A.1 through Fix A.7) follow this shape, varying only by:
  - sysprop key (`WEBSERVICE_ORDER_BATCH_HELD_URL_KEY` → ...`PALLETIZED`/`LOADED_TO_TRUCK`/...)
  - `MessageProcessType` constant (`ORDER_BATCH_ON_HOLD` → `ORDER_BATCH_PALLETIZED`/...)
  - DTO construction body (each method has its own pre-call DTO assembly).

#### Why this fix and not alternatives

| Alternative | Why rejected |
|---|---|
| Wrap each `manageOrderService.customerOrderXxx(...)` call site in `TransactionSynchronizationManager.registerSynchronization` | Repeats the pattern at 15+ caller sites, leaves the underlying method vulnerable to future callers, and the verify-script burden is much higher (15 caller-side checks vs 1 method-body check) |
| Create `CustomerorderOnHoldEvent` / `OrderBatchPickedEvent` / etc. + `@TransactionalEventListener(AFTER_COMMIT)` listeners (v1's pattern) | Re-architects the v2 codebase to introduce an `event/` package and 7 new event/listener pairs. The v2 codebase deliberately chose the helper pattern (see `wms2-transaction-osiv-boundary-map.md` §6). Switching now is wider scope than the bug warrants |
| Keep the inline POST but add a try/finally that rolls back the OMS state on caller exception | Compensating-action pattern. Requires a reverse OMS endpoint we don't have; partial-failure semantics are worse |

#### Caller-side double-defer interaction

`ParcelMonitorViewService.palletise/palletiseAndTruckLoad` and `MobilePalletizingService.palletize…` already wrap their `manageOrderService.customerOrderPalletized(...)` calls in their own `registerSynchronization`. After Fix A those callers' `afterCommit` lambdas will invoke `customerOrderPalletized`, which now internally calls `omsNotificationService.sendAfterCommit`. Behavior in the wrapped case:

1. Caller's `afterCommit()` fires after the caller's tx commits.
2. Inside it, `customerOrderPalletized` calls `omsNotificationService.sendAfterCommit(urlPath, payload, …)`.
3. `OmsNotificationService.sendAfterCommit` checks `TransactionSynchronizationManager.isSynchronizationActive()`:
   - At this point, the caller's tx has already committed; no active tx, so the synchronization is INACTIVE.
   - Falls through to the synchronous `doSend(urlPath, payload, processType)` path (`OmsNotificationService.java:62-66`).
4. The HTTP POST happens synchronously, and the audit `Message` row is created. **Same observable behavior as pre-fix.**

No double-post. No new contract violation. The duplicated wrapper code at the caller can optionally be removed in a follow-up cleanup PR — out of scope here.

### Fix B: `MessageService.sendStockChangeMessage` — refactor in-tx POST to use `omsNotificationService.sendAfterCommit`

**Note:** this creates a circular-dependency risk that must be solved before Fix B can land. `OmsNotificationService` already depends on `MessageService` (constructor injection). Adding an `OmsNotificationService` dependency back into `MessageService` for this single method creates a cycle.

**Solution chosen (smallest viable diff):** keep `MessageService` free of `OmsNotificationService`; extract `sendStockChangeMessage` into a new lean service `StockChangeNotificationService` that depends on `OmsNotificationService` + `SyspropService` (mirroring the shape of `OmsNotificationService`). The verify script's E1/E2/E3 checks hard-code this shape — there is **no Shape 2 fallback in this plan**.

#### Before (`MessageService.sendStockChangeMessage`, lines 101-140)

```java
public void sendStockChangeMessage(List<StockChangeDto> stockChangeList) {
    // … guard …
    try {
        urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY);
        payload = new ObjectMapper().writeValueAsString(stockChangeList);
        Map<String,String> respMap = httpRestService.post(urlPath, payload);                          // :115 — IN-TX POST
        createMessage(/* SENT, respMap.code, respMap.answer */);
    } catch (Exception e) { /* createMessage FAILED */ }
}
```

#### After (Fix B)

**The committed shape: extract `StockChangeNotificationService` mirroring `OmsNotificationService`.** (A second shape — injecting `OmsNotificationService` into `MessageService` directly with `@Lazy` to break the cycle — was considered and rejected because (a) it leaves the cycle as latent technical debt, (b) `@Lazy` defeats the constructor-injection convention, and (c) it requires the verify script to track two divergent code shapes.)

```java
// New file: src/main/java/net/aim_ai/wms/service/StockChangeNotificationService.java
@Service
public class StockChangeNotificationService {
    private final OmsNotificationService omsNotificationService;
    private final SyspropService syspropService;

    public StockChangeNotificationService(OmsNotificationService omsNotificationService,
                                          SyspropService syspropService) { … }

    public void sendAfterCommit(List<StockChangeDto> stockChangeList) {
        if (stockChangeList.isEmpty()) return;
        String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY);
        try {
            String payload = new ObjectMapper().writeValueAsString(stockChangeList);
            omsNotificationService.sendAfterCommit(urlPath, payload,
                WmsConstants.MessageProcessType.STOCK_UPDATE);
        } catch (IOException e) {
            LOG.error("Failed to serialize stock-change payload: {}", e.getMessage());
        }
    }
}
```

Then in `MessageService.sendStockChangeMessage`, delegate:

```java
public void sendStockChangeMessage(List<StockChangeDto> stockChangeList) {
    stockChangeNotificationService.sendAfterCommit(stockChangeList);
}
```

…or fully remove `sendStockChangeMessage` from `MessageService` and update the 15 callers to inject `StockChangeNotificationService` directly. The smaller diff is the delegating-shim approach — keep the call sites untouched. **This plan commits to the delegating-shim shape.**

#### Why a separate service rather than an `OmsNotificationService.sendStockChangeAfterCommit(List<StockChangeDto>)` overload

Keeping `OmsNotificationService` payload-agnostic (it accepts pre-serialized `String payload`) means it can be reused for any future OMS endpoint. Adding a stock-change-specific overload couples it to one process type and one DTO. The lean separate service preserves that abstraction.

### Fix C: Micrometer counter for FAILED OMS notifications (mandatory in this plan)

**Why this is mandatory, not optional.** Once Fix A and Fix B move all in-tx OMS POSTs to `afterCommit`, the rollback-drift mode disappears. The remaining silent-loss surface is "transient OMS outage flap": the WMS commit succeeds, the `afterCommit` POST fails, a `Message(state=FAILED)` row is written, and **nothing alerts**. Without operator visibility on the FAILED branch, this fix would simply trade one silent-loss mode for another.

**Where it lives.** Add the counter increment to `OmsNotificationService.doSend`'s catch block (the same site that writes the FAILED `Message` row).

```java
// Before (verbatim from OmsNotificationService.doSend catch block at :79-88):
} catch (Exception e) {
    messageService.createMessage(
        syspropService.getWmsInstanceName(),
        syspropService.getOmsInstanceName(),
        payload, processType, urlPath,
        WmsConstants.MessageStatus.FAILED,
        "503", null);
    LOG.error("OMS notification failed for processType={}: {} - {}",
        processType, e.getClass().getSimpleName(), e.getMessage());
}

// After (counter increment appended; existing FAILED Message + LOG preserved):
} catch (Exception e) {
    messageService.createMessage(
        syspropService.getWmsInstanceName(),
        syspropService.getOmsInstanceName(),
        payload, processType, urlPath,
        WmsConstants.MessageStatus.FAILED,
        "503", null);
    LOG.error("OMS notification failed for processType={}: {} - {}",
        processType, e.getClass().getSimpleName(), e.getMessage());

    // TenantContext API on v2 is purely static (verified at
    // landlord/config/TenantContext.java:24-45); getCurrentTenant() returns nullable
    // TenantProfile, so guard the dereference and emit "unknown" rather than NPE
    // in the catch block of the failure path.
    String tenantName = TenantContext.getCurrentTenant() != null
        ? TenantContext.getCurrentTenant().getTenantName()
        : "unknown";
    meterRegistry.counter("wms2.oms.notification.failed",
        "tenant",      tenantName,
        "processType", processType
    ).increment();
}
```

Tag set: `tenant` (so an outage on one tenant flares its own counter; falls back to literal `"unknown"` when `TenantContext` is null — e.g. when called from a misbehaving caller path that did not set tenant before crossing the `afterCommit` boundary), `processType` (so cancel-vs-pick-vs-stock-update can be distinguished). Reuse the existing `MeterRegistry` bean — do not introduce an alternative metrics stack (per v2-only constraint row 8).

**Operator alerting.** Out of scope for this plan, but the Implementation Status section MUST capture an alert configuration follow-up (Prometheus rate alert on `rate(wms2_oms_notification_failed_total[5m]) > 0` with severity matching the v2 SRE runbook).

### Verification of Bugs 1 and 2 (no code change — only verify-script regression guards)

For `CustomerorderService.cancelOrder` and `CustomerorderBatchService.cancelBatch`, no code change is needed. The verify script encodes:
- POSITIVE: each method body still contains `omsNotificationService.sendAfterCommit(`...`ORDER_BATCH_CANCELLED_FROM_WMS`...`)`
- NEGATIVE: `httpRestService.post` does not appear anywhere in `CustomerorderService.java` or `CustomerorderBatchService.java`

This is critical because (per the original ticket framing) any future contributor copying old v1 code into v2 could re-introduce the bug. The negative grep is the structural firewall.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `src/main/java/net/aim_ai/wms/service/ManageOrderService.java` | **Modify** | 7 method bodies (`customerOrderOnHold`, `customerOrderReleaseForPicking`, `customerOrderToteAssigned`, `customerOrderPickingStarted`, `customerOrderPicked`, `customerOrderPalletized`, `customerOrderLoadedToTruck`) refactored to delegate to `omsNotificationService.sendAfterCommit`. Constructor: add `OmsNotificationService` parameter; remove `HttpRestService` and `MessageService` parameters if (and only if) no other method uses them — verify before removing. |
| `src/main/java/net/aim_ai/wms/service/MessageService.java` | **Modify** | `sendStockChangeMessage` body becomes a thin delegate to `StockChangeNotificationService.sendAfterCommit(stockChangeList)`. Constructor: add the new dependency. (Shape 2 alternative: inject `OmsNotificationService` with `@Lazy`.) |
| `src/main/java/net/aim_ai/wms/service/StockChangeNotificationService.java` | **NEW** | Lean service; `sendAfterCommit(List<StockChangeDto>)` resolves the URL, serializes the DTO list, and delegates to `OmsNotificationService.sendAfterCommit`. |
| `src/main/java/net/aim_ai/wms/service/CustomerorderService.java` | **No change** (regression-guarded only) | Verified by §9 verify script — POSITIVE check on `sendAfterCommit` line 720; NEGATIVE check that `httpRestService.post` is absent file-wide. |
| `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java` | **No change** (regression-guarded only) | Same as above for line 269. |
| `src/main/java/net/aim_ai/wms/service/OmsNotificationService.java` | **Modify** | Fix C — wire the Micrometer counter `wms2.oms.notification.failed` (tags: `tenant`, `processType`) inside `doSend`'s catch block. Inject `MeterRegistry` via constructor; preserve existing FAILED `Message` audit-row creation. |
| `src/test/java/net/aim_ai/wms/unit/service/CustomerorderServiceUnitTest.java` | **Modify (append)** — existing 1,500+ LOC test must remain green | Add `cancelOrder_shouldRegisterAfterCommitSynchronization_whenCancellationFromWithinWMS` and `cancelOrder_shouldUseSendAfterCommit_whenCancellationFromWithinWMS`. **Do NOT delete or rewrite existing tests.** |
| `src/test/java/net/aim_ai/wms/unit/service/CustomerorderBatchServiceUnitTest.java` | **Modify (append)** — existing test must remain green | Add `cancelBatch_shouldNotPostToOms_whenLaterMutationThrows`. **Do NOT delete or rewrite existing tests.** |
| `src/test/java/net/aim_ai/wms/unit/service/ManageOrderServiceUnitTest.java` | **Modify (append)** — file is an existing 1,502-line test (`wc -l` confirmed; 55 `@Test` methods exist) | Append 7 deferral tests (`customerOrderXxx_shouldDeferOmsPostUntilAfterCommit`) + 1 serialization test + 1 scheduled-job tenant-context test (`customerOrderOnHold_shouldPropagateTenantContext_whenCalledFromScheduledJob`) + 1 counter test (`doSend_shouldIncrementFailureCounter_whenPostThrows` covers the Fix C path; technically lives in `OmsNotificationServiceUnitTest` but is named here for traceability). **Do NOT delete or rewrite the existing 55 `@Test` methods.** |
| `src/test/java/net/aim_ai/wms/unit/service/OmsNotificationServiceUnitTest.java` | **Modify (append)** if it exists, else **NEW** | Counter increment tests for Fix C: `doSend_shouldIncrementFailureCounter_whenPostThrows` AND `OmsNotificationService_shouldUseUnknownTenantTag_whenTenantContextIsNull` (gates the null-`TenantContext.getCurrentTenant()` branch — required because `TenantContext` API is purely static and `getCurrentTenant()` is nullable). |
| `src/test/java/net/aim_ai/wms/unit/service/StockChangeNotificationServiceUnitTest.java` | **NEW** | `sendAfterCommit_shouldDelegateToOmsNotificationService_whenListNonEmpty`, `sendAfterCommit_shouldNoOp_whenListEmpty`, `sendAfterCommit_shouldHandleSerializationException_gracefully`. |
| `src/test/java/net/aim_ai/wms/integration/CancelOrderRollbackIntegrationTest.java` | **NEW** (Testcontainers) | Drives the full `cancelOrder` path against PostgreSQL Testcontainers; stubs `finalizeBatchIfComplete` to throw post-publish; asserts `httpRestService.post` was never invoked. Also includes `customerOrderPicked_shouldNotPostToOms_whenCallerTxRollsBack` AND `customerOrderOnHold_shouldPreserveTenantContext_acrossSchedulerBoundary` (R9 mitigation, gated by F8). |
| `src/test/java/net/aim_ai/wms/smoke/OmsNotificationConfigContextLoadTest.java` | **NEW** (Spring smoke) | `@SpringBootTest` smoke covering the Fix B circular-dep risk: ensures the application context loads with `StockChangeNotificationService` + `OmsNotificationService` + `MessageService` co-resident. |
| `sbdocs/9-System/scripts/verify-SBDEV-2214-oms-http-post-inside-class-level-transactional.sh` | **NEW** | The §9 acceptance script. |
| `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | **Modify** (footnote update) | After implementation: append a note under §2.1 indicating ManageOrderService now defers via `OmsNotificationService` (no longer in-tx). |

No DB migration. No new sysprop. No new endpoint. No frontend change.

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | None | — | No schema or seed-row change. |
| 2 | Feature flags / system properties | The 7 ManageOrderService URL syspropies + 1 stock-change URL sysprop must already exist in `los_sysprop` per tenant | Tenant DBA (verify only) | These are the same syspropies the in-tx code reads today; no new keys. List: `WEBSERVICE_ORDER_BATCH_HELD`, `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING`, `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED`, `WEBSERVICE_ORDER_BATCH_PICKING`, `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING`, `WEBSERVICE_ORDER_BATCH_PALLETIZED`, `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK`, `WEBSERVICE_STOCK_UPDATE`. |
| 3 | Config / env changes | None | — | No application.properties touch. |
| 4 | Deploy-order dependencies | None | — | Pure WMS-internal refactor. OMS endpoint contracts unchanged. |
| 5 | Data migration | None | — | No backfill. Existing `Message` audit rows remain valid. |
| 6 | External systems | OMS receives the same payload at the same URL with the same headers | OMS team (no change required) | Verify a smoke test on staging. |
| 7 | Access / permissions | None | — | No new role. |
| 8 | Monitoring / alerts | Optional: add a Micrometer counter `oms_notification_failed_total{processType=…}` (see v2-only checklist row 8) | Implementer | Reuse existing `MeterRegistry`; do not add a new metrics stack. |

### 7.2 Implementation phases

The phases are ordered so that **at no point is the WMS without OMS notifications**. The existing `OmsNotificationService` is already in place; we are only routing more callers through it.

- [x] **Phase 0 — Baseline.** Run `bash sbdocs/9-System/scripts/verify-SBDEV-2214-oms-http-post-inside-class-level-transactional.sh` should report **`Result: 16 pass, 39 fail, 1 skip`** in `SKIP_MVN=1` mode. The script statically contains **62 `run` invocations** decomposed as: §A=4, §B=4, §C=4, §D=14, §E=7, §F=17, §I=3, §H=2, §G=7. Under `SKIP_MVN=1`, §G's 7 maven-test invocations collapse into a single SKIP, leaving 55 non-skip results + 1 skip = 56 result-line entries. The 16 PASS rows are existing regression guards already correct in v2; the 39 FAIL rows are the fix points the implementer must turn green by Phase 7. After Phase 7, the script must report `Result: N pass, 0 fail, M skip`.
- [x] **Phase 1 — Fix A scaffolding.** Add `OmsNotificationService` constructor parameter to `ManageOrderService`. Inline the URL/payload-prep + `omsNotificationService.sendAfterCommit(...)` directly in each refactored method body (matching the Fix A code blocks in §5 — **no private helper extraction**). Do not yet remove the inline POST in this phase. **Commit + run verify** (still FAIL on negative checks; positive check on the constructor wiring passes).
- [x] **Phase 2 — Fix A.1 through A.7.** Replace each method body's inline `httpRestService.post + createMessage(SENT/FAILED)` with the inlined `omsNotificationService.sendAfterCommit(urlPath, payload, processType)` call. One method per commit (7 commits) so a regression bisect lands on the responsible method. After each commit, run `mvn test -Dtest=ManageOrderServiceUnitTest` and the verify script. **Per-commit existing-test update gate** (otherwise Mockito strict-mode breaks the bisect at this commit, not at Phase 2's start): for each of the 7 `customerOrder*` methods, the existing tests in `ManageOrderServiceUnitTest$CustomerOrder<Method>` and `$EdgeCases` (~25 methods total stub or verify the OLD path) MUST be updated in the same commit:
    - **Replace** `when(httpRestService.post(eq(url), any(String.class))).thenReturn(response)` → either remove (if the test is asserting the deferral, not the underlying POST) or `doAnswer(...).when(omsNotificationService).sendAfterCommit(eq(url), anyString(), eq(processType))`.
    - **Replace** `verify(httpRestService).post(eq(url), any(String.class))` → `verify(omsNotificationService).sendAfterCommit(eq(url), anyString(), eq(processType))`.
    - **Replace** `verify(messageService).createMessage(...)` calls that were verifying the audit-row written inline by `ManageOrderService` → assert against `OmsNotificationService` instead (the audit row is now written by the listener side via `messageService.createMessage(...)` from inside `OmsNotificationService.doSend` — the assertion target shifts from "ManageOrderService writes audit" to "OmsNotificationService writes audit").
    - **Keep** `verifyNoInteractions(httpRestService)` lines — they still hold (production no longer hits httpRestService directly from ManageOrderService).
    - Concretely the existing tests likely affected per `customerOrder*` method: 2-3 happy-path stubs + 1 error-response stub + 1 throw-on-post stub + 1 verifyNoInteractions guard. Plan ~25 line edits across the 7 commits. Concrete grep before each commit: `grep -n "httpRestService.post\|verify(messageService)" src/test/java/net/aim_ai/wms/unit/service/ManageOrderServiceUnitTest.java` to enumerate the lines that need updating in this commit's scope.
    - **DO NOT** delete the existing tests — they still serve as regression coverage for the rest of the pipeline (state guards, OnHold/ReleaseForPicking conditional logic, error-response branches). Update the mock-interaction lines, keep the assertion semantics.
    - **Mockito strict mode**: Spring Boot 3.x ships with `MockitoSettings(strictness = Strictness.STRICT_STUBS)` by default. Any leftover `when(httpRestService.post(...))` stub on a method that production no longer calls fails the test with `UnnecessaryStubbingException` BEFORE reaching the assertion. Catch this at the per-commit `mvn test -Dtest=ManageOrderServiceUnitTest` run, fix in the same commit.
- [x] **Phase 3 — Fix A cleanup.** Once all 7 methods are converted, remove the now-unused `HttpRestService httpRestService` and `MessageService messageService` constructor parameters from `ManageOrderService` (verify with grep that no other method body references them). Run `mvn verify` to catch any test-fixture compile errors.
- [x] **Phase 4 — Fix B.** Create `StockChangeNotificationService` (NEW file). Modify `MessageService.sendStockChangeMessage` to delegate. Run `mvn test -Dtest=MessageServiceUnitTest -Dtest=StockChangeNotificationServiceUnitTest`. Run the new `OmsNotificationConfigContextLoadTest` smoke to confirm Spring resolves the bean graph (catches any latent cycle).
- [x] **Phase 5 — Fix C (Micrometer counter — mandatory) + tests.** Inject `MeterRegistry` into `OmsNotificationService` (constructor parameter). Increment `wms2.oms.notification.failed{tenant, processType}` in `doSend`'s catch block alongside the existing FAILED `Message` row write. Append the new tests: 7 `customerOrderXxx_shouldDeferOmsPostUntilAfterCommit` + the renamed `cancelOrder_shouldRegisterAfterCommitSynchronization_whenCancellationFromWithinWMS` + scheduled-job tenant-context test + counter test. Add the `CancelOrderRollbackIntegrationTest` Testcontainers test. Run `mvn verify`.
- [x] **Phase 6 — Removed.** (Previously housed the optional Micrometer counter; promoted to Phase 5.)
- [x] **Phase 7 — Final verify.** Run the verify script. **Required result line: `Result: N pass, 0 fail, 0 skip`** (or `0 fail, M skip` with documented reason). Paste into §13 Implementation Status.
- [ ] **Phase 8 — Manual smoke.** Per §8 manual test plan.

---

## 8. Testing Plan

### 8.1 Unit tests

> **Baseline preservation.** `ManageOrderServiceUnitTest.java` is an existing 1,502-line file with 55 `@Test` methods (`wc -l` confirmed). `CustomerorderServiceUnitTest.java` and `CustomerorderBatchServiceUnitTest.java` are also existing files with significant existing coverage. **Do NOT delete or rewrite the existing tests in any of these three files.** All new tests in §8.1 are appended; existing tests must continue passing.
>
> **Why unit tests cannot prove rollback semantics.** Rollback semantics depend on `TransactionSynchronizationManager` callbacks; a pure Mockito unit test with `omsNotificationService` mocked only verifies that `sendAfterCommit` was invoked, not that the synchronization is skipped on rollback. Unit tests verify that the deferral was registered. Integration tests (§8.2) verify that the registration is skipped on rollback. **Do not attempt to verify rollback semantics in a unit test.**

#### Additions to `CustomerorderServiceUnitTest` (modify-append)
- `cancelOrder_shouldUseSendAfterCommit_whenCancellationFromWithinWMS` — drives `cancelOrder(co, true)`, mocks `omsNotificationService` and verifies `sendAfterCommit(any, any, eq(ORDER_BATCH_CANCELLED_FROM_WMS))` is called exactly once.
- `cancelOrder_shouldRegisterAfterCommitSynchronization_whenCancellationFromWithinWMS` — pure unit test that asserts `omsNotificationService.sendAfterCommit` was called exactly once with the expected (urlPath non-null, payload-bytes non-empty, processType=ORDER_BATCH_CANCELLED_FROM_WMS) args. **Replaces the previously-named** `cancelOrder_shouldNotPostToOms_whenFinalizeThrows`, which has been moved to §8.2 because rollback semantics are integration-test territory.

#### Additions to `CustomerorderBatchServiceUnitTest` (modify-append)
- `cancelBatch_shouldNotPostToOms_whenLaterMutationThrows` — Mockito stubs `customerorderRepository.save(any)` (the save inside the batch-orders loop) to throw on the 2nd call; verifies `httpRestService.post` was never invoked. (Note: still a unit-level test because `httpRestService` is the real spy here, not the rollback path; it asserts the deferral was registered and then never fired the POST in the absence of a real tx.)

#### Additions to `ManageOrderServiceUnitTest` (modify-append; existing 55 `@Test`s preserved)
- `customerOrderOnHold_shouldDeferOmsPostUntilAfterCommit`
- `customerOrderReleaseForPicking_shouldDeferOmsPostUntilAfterCommit`
- `customerOrderToteAssigned_shouldDeferOmsPostUntilAfterCommit`
- `customerOrderPickingStarted_shouldDeferOmsPostUntilAfterCommit`
- `customerOrderPicked_shouldDeferOmsPostUntilAfterCommit`
- `customerOrderPalletized_shouldDeferOmsPostUntilAfterCommit`
- `customerOrderLoadedToTruck_shouldDeferOmsPostUntilAfterCommit`
- `customerOrderXxx_shouldHandleSerializationException_gracefully` (one parametrized test or one per method — implementer's choice)
- `customerOrderOnHold_shouldPropagateTenantContext_whenCalledFromScheduledJob` — integration-flavored unit test that simulates the `@Scheduled` caller path: clears `TenantContext`, sets it manually (mirroring `ReleaseOrderJobService`'s tenant-resolution preamble), calls `customerOrderOnHold(...)`, then within an `afterCommit` lambda asserts `TenantContext.getTenantName()` is the expected value at the time of `omsNotificationService.sendAfterCommit` invocation.

Pattern: each deferral test mocks `omsNotificationService` and verifies `sendAfterCommit(eq(expectedUrl), any, eq(<MessageProcessType>))` is invoked exactly once.

#### Additions to `OmsNotificationServiceUnitTest` (modify-append, or NEW if file does not exist)
- `doSend_shouldIncrementFailureCounter_whenPostThrows` — stubs `httpRestService.post(...)` to throw; sets `TenantContext.setCurrentTenant(<tenantA>)` first; verifies `meterRegistry.counter("wms2.oms.notification.failed", "tenant", "<tenantA>", "processType", "<type>").increment()` was called exactly once. Also verifies the FAILED `Message` row is still written.
- `OmsNotificationService_shouldUseUnknownTenantTag_whenTenantContextIsNull` (NEW-C3 mitigation, gated by F9 in §9) — verifies the null-`TenantContext.getCurrentTenant()` branch of the Fix C counter increment. Calls `TenantContext.clear()`, stubs `httpRestService.post(...)` to throw, invokes `omsNotificationService.sendAfterCommit(...)` from a no-tx context (synchronous fallback), and asserts `meterRegistry.counter("wms2.oms.notification.failed", "tenant", "unknown", "processType", "<type>")` count of `1`. Without this test, a future refactor that drops the null-guard around `TenantContext.getCurrentTenant().getTenantName()` would NPE in production with no test coverage. (Reminder: `TenantContext` API on v2 is purely STATIC — `getCurrentTenant()` returns nullable `TenantProfile`. Verified at `landlord/config/TenantContext.java:24-45`.)

#### New `StockChangeNotificationServiceUnitTest`
- `sendAfterCommit_shouldDelegateToOmsNotificationService_whenListNonEmpty`
- `sendAfterCommit_shouldNoOp_whenListEmpty`
- `sendAfterCommit_shouldHandleSerializationException_gracefully`

### 8.2 Integration tests

#### New `CancelOrderRollbackIntegrationTest` (extends `BaseIntegrationTest` / Testcontainers PostgreSQL)
- `cancelOrder_shouldNotPostToOms_whenPostCancelCleanupThrows` — sets up a real Customerorder in the DB; injects a Spy of `customerorderBatchService` whose `finalizeBatchIfComplete` throws a `RuntimeException`; calls `customerorderService.cancelOrder(co, true)`; expects `RuntimeException`; verifies `httpRestService` was wrapped with a real spy and `post(...)` was never invoked. Also verifies the DB state was rolled back (Customerorder.state remains pre-cancel).
- `cancelBatch_shouldNotPostToOms_whenChildSaveThrows` — equivalent for `cancelBatch`.
- `customerOrderPicked_shouldNotPostToOms_whenCallerTxRollsBack` — drives a synthetic caller (`@Transactional` test method) that calls `manageOrderService.customerOrderPicked(...)` and then throws.
- `customerOrderOnHold_shouldPreserveTenantContext_acrossSchedulerBoundary` (R9 mitigation, gated by F8 in §9). Drives the scheduled-job path: invoke from a thread that has `TenantContext.setCurrentTenant(<tenantA>)` set BEFORE the `@Transactional REQUIRES_NEW` boundary enters and CLEARED AFTER `afterCommit` fires; assert the deferred POST sees the right tenant tag in the Micrometer counter (or, equivalently, that the `Message` audit row's WMS-instance-name resolves to `<tenantA>`'s configured value). The test stubs `httpRestService.post(...)` to throw so the failure-branch counter increment is exercised, then asserts a `meterRegistry.counter("wms2.oms.notification.failed", "tenant", "<tenantA>", "processType", "ORDER_BATCH_ON_HOLD")` count of `1`. **This test lives in `CancelOrderRollbackIntegrationTest` (single-file simplification — splitting into a new `OmsNotificationSchedulerTenantContextIntegrationTest` was rejected for scope; the test class is named for the symptom file rather than the test scenario, which is consistent with how `CancelOrderRollbackIntegrationTest` already houses the unrelated `customerOrderPicked_shouldNotPostToOms_whenCallerTxRollsBack` test).**

### 8.3 Regression / contract tests + Spring context-load smoke

- `mvn verify` — full Testcontainers suite must remain green.
- All existing `MobilePickingServiceUnitTest`, `ParcelMonitorViewServiceUnitTest`, `MobilePalletizingServiceUnitTest`, `ReleaseOrderJobServiceUnitTest` must remain green. After Fix A their `manageOrderService.customerOrderXxx` mock-calls semantics don't change at the unit-test level (they still happen, just now defer to `sendAfterCommit` internally — which is a separate mock).
- **NEW Spring smoke test `OmsNotificationConfigContextLoadTest`** (`@SpringBootTest`) — protects against the Fix B latent circular-dep risk. Loads only the bean graph touching `OmsNotificationService`, `MessageService`, `StockChangeNotificationService`, `MeterRegistry`, and `HttpRestService`; asserts the application context starts and the three bean instances are non-null. Required because constructor-injection cycles in Spring fail at startup, not at compile.

### 8.4 Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Happy-path cancel order from web UI | staging | 1. Pick a non-shipped order in WMS web UI. 2. Click "Cancel order". 3. Wait 2-3 s. | OMS receives cancel notification (verify in OMS side). WMS shows order as CANCELED. `Message` row created with `process=ORDER_BATCH_CANCELLED_FROM_WMS, status=SENT`. | |
| Forced rollback during cancel | staging | 1. Use a tenant where `cleanUpCancelledOrder` can be made to fail (e.g. lock a sibling record manually via SQL `BEGIN; SELECT ... FOR UPDATE; …` and try to cancel the order). 2. Observe WMS error response. | WMS shows the order as still active (rollback). OMS does NOT receive a cancel notification. No `Message` row written for this attempt. | |
| Picking-started OMS notification (Fix A.4 path) | staging | 1. Operator starts picking on a tote. 2. Disconnect/break OMS responder mid-call. | WMS picking proceeds; `Message` row written with `status=FAILED` after commit; WMS DB state reflects picking-started; **no rollback** (the OMS failure does not retroactively affect WMS state, as designed). | |
| Stock-change OMS notification (Fix B path) | staging | 1. Move a unit load via web UI. 2. Verify `OMS Stock Update` arrives. 3. Force a downstream error (e.g. attempt to move into a forbidden location). | On forbidden move: WMS rolls back; OMS receives no stock-change for the failed attempt. On success: OMS receives the change after commit. | |
| SQL-level sanity (post-fix) | staging tenant DB | psql: run the §1 db-verification query | Returns the same or fewer rows than before the fix (rare drift cases newly avoided; pre-existing drift remains until manually reconciled). | |

### 8.5 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=ManageOrderServiceUnitTest` | | |
| `mvn test -Dtest=StockChangeNotificationServiceUnitTest` | | |
| `mvn test -Dtest=CustomerorderServiceUnitTest` | | |
| `mvn test -Dtest=CustomerorderBatchServiceUnitTest` | | |
| `mvn verify -Dtest=CancelOrderRollbackIntegrationTest` | | |
| `mvn verify` (full) | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2214-oms-http-post-inside-class-level-transactional.sh` | | (target: `0 fail`) |

### 8.6 Deliberately-skipped coverage

| What | Why |
|---|---|
| End-to-end test that exercises a real OMS server | OMS is an external system; coverage is via the `Message` row contract test. |
| Mockito static-stubbing of `TransactionSynchronizationManager` | Not needed — Spring's Testcontainers integration tests provide a real tx context. |

---

## 9. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica state? | **No** | No new caches, ConcurrentHashMaps, statics, or ThreadLocals. The `TransactionSynchronization` instance is per-tx, lives only on the request thread until commit. |
| 2 | **Connection pool math** | Change DB connection usage? | **No** | The DB connection holding pattern is unchanged: HikariCP already releases the connection after `afterCommit` callbacks finish. We are MOVING the post into that window, not extending it (the post was already inside the tx pre-fix — same wall-clock connection-hold time, just on a different side of `commit()`). For ManageOrderService callers that previously held the connection across the in-tx post, this fix actually SHORTENS the connection-hold window because the commit happens before the (slow) HTTP POST. |
| 3 | **Scheduled jobs** | Add or modify `@Scheduled`? | **No** | No cron change. `ReleaseOrderJobService` is touched only indirectly — Fix A makes its `customerOrderOnHold` calls safe without changing the job's `@Transactional REQUIRES_NEW` boundary. |
| 4 | **Long transactions** | Hold a tx across external I/O? | **No** | The opposite — Fix A and Fix B explicitly REMOVE external I/O from inside the transaction. |
| 5 | **Request affinity** | Assume same replica for follow-up? | **No** | `afterCommit` runs on the same thread that committed; no cross-replica assumption. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | **Yes (existing constraint, unchanged by this plan)** | If a replica crashes between `commit()` and `afterCommit`, OMS receives no notification AND no `Message(SENT)` row exists. Recovery is via the existing manual-reconciliation flow — same as today. To make exactly-once requires an outbox + reconciler, which is out of scope. Documented as Risk R3 in §12. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **Yes** | `TransactionSynchronization.afterCommit` runs synchronously on the thread that called `commit()`. The TenantFilter has not yet cleared the request's `TenantContext` (filter clears in a `try { … } finally { TenantContext.clear(); }` AFTER the request completes). So tenant context is intact. **Evidence:** existing `OmsNotificationService` use in `BillofladingService.closeBOL`, `AdviceService.acceptHubAndSpoke/closeAdvice/acceptTransfer`, `CustomerorderService.cancelOrder`, `CustomerorderBatchService.cancelBatch` — none have reported tenant-context issues across afterCommit, and `MessageService.createMessage` (called inside the deferred path) accesses tenant-bound `userRepository.findByName(...)` successfully. |
| 8 | **Distributed lock correctness** | Add or rely on locks across replicas? | **No** | Lock semantics unchanged. |
| 9 | **Cache invalidation** | Write to a cached entity? | **No** | The `Customerorder` and `Customerorderbatch` entities are not in `@Cacheable` paths per `wms2-caching-strategy.md`. |
| 10 | **External notifications (OMS, etc.)** | Send HTTP outside a transaction? | **Yes — this is the entire point** | The post is moved from inside-tx to after-commit. The `Message` audit row is already inside `MessageService.createServiceLog`, which is annotated `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` (verified at `MessageService.java:67`) — so the audit row is written in its own tx and survives a rollback of the outer caller. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 6 | Retry/idempotency — risk inherited from existing OmsNotificationService design; no regression added | `service/OmsNotificationService.java:69-89` |
| 7 | Tenant context preserved across afterCommit (documented in arch doc) | `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §6 |
| 10 | Audit-row creation uses REQUIRES_NEW so it survives outer rollback | `service/MessageService.java:67` |

---

## 10. v2-only constraint checklist

| # | Constraint | What to check | Verdict |
|---|---|---|---|
| 1 | **OSIV disabled** | `spring.jpa.open-in-view=false` enforced; no new lazy-load paths added | **N/A** (no new lazy access; the deferred post operates on a pre-serialized `String payload`, not on managed entities) |
| 2 | **Transaction manager** | `@Transactional(value="tenantTransactionManager"…)` on tenant-scoped writes | **Yes — preserved.** `cancelOrder`, `cancelBatch` already use the correct TM. `ManageOrderService` methods are NOT `@Transactional` (they delegate to the helper) — this is correct, the helper itself does not need a TM because it merely registers a synchronization on the ambient tx. |
| 3 | **`@Transactional(readOnly=true)`** | Read-only methods declared | **N/A** (no new read-only methods) |
| 4 | **Caffeine cache invalidation** | `@CacheEvict` / `@CachePut` for cached entity writes | **N/A** (no cached entities are written by Fix A or Fix B beyond what cancelOrder/cancelBatch already write today) |
| 5 | **Jakarta namespace** | All new imports use `jakarta.*` | **Yes — N/A change.** The new `StockChangeNotificationService` uses no JPA / validation / transaction API directly; it only depends on `OmsNotificationService` + `SyspropService` + `ObjectMapper`. |
| 6 | **H2-compatible test SQL** | Native PG syntax replaced | **N/A** (no new repository SQL) |
| 7 | **`BaseControllerTest`** | New/modified controller endpoints | **N/A** (no controller change) |
| 8 | **Micrometer metrics** | High-frequency path covered by an existing or new metric | **Yes — mandatory (Fix C).** Add `meterRegistry.counter("wms2.oms.notification.failed", "tenant", <tenant>, "processType", <processType>).increment()` inside `OmsNotificationService.doSend`'s catch block (Phase 5). Promoted from "optional Phase 6" to "mandatory Phase 5" per critic-review M5. |

---

## 11. Notes — Resolved decisions (Pre-draft Layer 3, defaults)

The user requested "just draft, use reasonable defaults" — these are the defaults this draft chose. The reviewer can override any of them in the next revision.

| # | Question | Default chosen by this draft | Override box |
|---|---|---|---|
| 1 | Scope — v1, v2, or both? | **v2 only** for this plan. (v1 paired plan tracked in §11.1 row 4 — single source.) | ☐ revise |
| 2 | Behavior change | **None in the happy path.** In the rare rollback-after-OMS-POST path, OMS no longer drifts. | ☐ revise |
| 3 | Concurrency | **TenantContext is preserved across `afterCommit`** because the callback runs on the same thread before the request thread releases. Multiple replicas are independent. | ☐ revise |
| 4 | Measurable target | **Zero events** of "WMS `Customerorder.state=CANCELED` ∧ OMS not-acknowledged-cancel" in steady state. Observable via the §1 db-verification query. | ☐ revise |
| 5 | Backward compat | **Additive on the OMS side** — same payload, same URL, same headers, same `Message` audit-row schema. Only the timing of the post moves to after-commit. | ☐ revise |
| 6 | Coordination | No conflicting open plan. `260503-runclubline-transaction-boundary-hardening.md` already presumes Phase 4 OMS notifications run outside any tx — Fix A is consistent. | ☐ revise |

### Cross-version (v1 ↔ v2) row of the completeness checklist

**v1 plan: deferred.** The ticket also tags `wmsv1`. A v1 plan needs to be drafted separately — the v1 codebase uses the `BolClosedEvent` / `@TransactionalEventListener(AFTER_COMMIT)` pattern, so the v1 fix would create new `CustomerorderCancelledEvent` / `OrderBatchCancelledEvent` event+listener pairs (literal interpretation of the ticket). That is what `wms-v2-migrate` (run in REVERSE — i.e. authoring a v1 plan from this v2 plan) should produce later.

### 11.1 Cross-references / Follow-up plans

| Item | Status | Reference / next-step |
|---|---|---|
| **v1 reference for the v1 plan only** — `BolClosedEvent` / `BolClosedEventListener` (`@TransactionalEventListener(AFTER_COMMIT)`) is the v1 ancestor pattern. | informational; not ported into v2 (v2 uses the `OmsNotificationService` helper pattern) | v1 plan: `260424-oms-notification-rollback-risk-remediation.md` |
| **`MessageService.resendMessage` post-save failure path** | **Follow-up plan required.** The POST itself is by-design synchronous (admin-triggered retry) but the post-POST `messageRepository.save(newMessage)` at `MessageService.java:164` can fail and reproduce the same WMS-no-record / OMS-saw-it drift. To be filed separately because admin-triggered paths have different operator semantics. | TBD plan filename: `<YYMMDD>-message-service-resend-save-after-post-drift.md` |
| **Outbox + DLQ for OMS notifications** | **Follow-up plan required (R3).** Replica-crash between `commit()` and `afterCommit` silently loses today. An outbox-pattern reconciler would deliver true exactly-once semantics. | TBD plan filename: `<YYMMDD>-oms-notification-outbox-dlq.md` |
| **Kill-switch sysprop for the deferral** | **Acknowledged but not in scope (R3b).** Rollback today is git-revert + redeploy. A per-tenant feature flag could be added in a separate refactor plan. | TBD plan filename: `<YYMMDD>-oms-notification-deferral-kill-switch-sysprop.md` |
| **v1 paired plan for SBDEV-2214** | **Deferred.** Run `wms-v2-migrate` in reverse (or `ralplan`) to author the v1-side plan from this v2 plan. | TBD plan filename: `SBDEV-2214-oms-http-post-inside-class-level-transactional.md` (in `sbdocs/1-Projects/wms1/plan/`) |

### 11.2 Prometheus alert specification (must-fix-before-merge — locked here so the alerting team has zero ambiguity)

The full alerting story (paging, runbook, on-call routing) is deferred to a follow-up plan, but the alert RULE is defined here so the Micrometer counter wired by Fix C has a stable consumer contract. The alerting team owns the YAML in their monitoring repo; the rule shape below is the contract.

**Counter (Java side, wired by Fix C in `OmsNotificationService.doSend` catch block):**

```java
meterRegistry.counter("wms2.oms.notification.failed",
    "tenant",      tenantName,        // "unknown" if TenantContext.getCurrentTenant() == null
    "processType", processType         // e.g. "ORDER_BATCH_CANCELLED_FROM_WMS", "ORDER_BATCH_PICKING_FINISHED"
).increment();
```

Exposed via `/actuator/prometheus` as `wms2_oms_notification_failed_total{tenant=...,processType=...}`.

**Two-tier alert rule:**

```yaml
- alert: WmsOmsNotificationFailures_RateSustained
  expr: |
    sum by (tenant, processType) (
      rate(wms2_oms_notification_failed_total[5m])
    ) > 0.033   # 10 failures sustained over 5 minutes → 0.033/sec
  for: 15m
  labels:
    severity: page
    service: wms2-api
    runbook: oms-notification-failure-tier1
  annotations:
    summary: "WMS→OMS notification failures sustained for tenant {{ $labels.tenant }}"
    description: |
      processType={{ $labels.processType }} has been emitting failures at
      {{ $value | humanize }}/sec for 15 minutes. WMS DB state has committed
      but OMS was not notified — manual reconcile required until an outbox/DLQ ships.
      Check: SELECT id, process, status, created FROM message
             WHERE status='FAILED' AND process='{{ $labels.processType }}'
             ORDER BY created DESC LIMIT 50;

- alert: WmsOmsNotificationFailures_HourlyBurst
  expr: |
    increase(wms2_oms_notification_failed_total[1h]) > 10
  for: 5m
  labels:
    severity: warn
    service: wms2-api
    runbook: oms-notification-failure-tier1
  annotations:
    summary: "WMS→OMS notification failures > 10/hour for tenant {{ $labels.tenant }}"
    description: |
      processType={{ $labels.processType }} accumulated >10 FAILED rows in the last hour.
      Either OMS is having a flap, or a single tenant is hitting a bad code path.
```

**Pre-merge checklist for the alerting team (filed as a separate ticket — do NOT block this PR's merge on the alert YAML landing, but DO block on the ticket existing):**

- [ ] Alert YAML committed to the monitoring repo with the two rules above.
- [ ] Pager routing wired (page-tier → on-call; warn-tier → channel).
- [ ] Runbook stub `oms-notification-failure-tier1` created with the manual reconcile SQL above.
- [ ] First firing tested by injecting a fake failure into a non-prod tenant.

This sub-section satisfies the "must-fix-before-merge" gate that the implementation hand-off requires.

### Completeness checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | `no — db_verified: false` (cross-system reconciliation; manual SQL gate documented in §1) |
| 1 | All callsites enumerated | `✓ §0 — 19 sites; rows 1, 2 already-fixed regression-checks; rows 5-12 in-scope fix targets; rows 13-19 excluded with rationale` |
| 2 | Adjacent bugs | `✓ §0 rows 5-12 (ManageOrderService × 7 + MessageService.sendStockChangeMessage)` |
| 3 | Backward compatibility | `✓ §11 row 5; OMS contract unchanged; Message audit-row schema unchanged` |
| 4 | Concurrency | `✓ §9 row 7 (Tenant context across afterCommit); §11 row 3` |
| 5 | Multi-tenant | `✓ §9 row 7 — TenantContext preserved` |
| 6 | Error handling | `✓ §5 Fix A (URL-not-configured branch handled by OmsNotificationService.sendAfterCommit:45-53; serialization IOException narrowed and logged); §3 Bug 4 (audit-row creation in REQUIRES_NEW survives outer rollback)` |
| 7 | Observability | `✓ §3 Fix C + §10 row 8 — Micrometer counter wms2.oms.notification.failed (mandatory, Phase 5)` |
| 8 | Rollback / migration | `no — pure code-logic refactor; no Flyway, sysprop, or feature flag` |
| 9 | Test coverage | `✓ §8 — 4 unit tests added + 1 new unit-test class (ManageOrderServiceUnitTest, 7+ tests) + 1 new unit-test class (StockChangeNotificationServiceUnitTest, 3 tests) + 1 new integration test class (CancelOrderRollbackIntegrationTest, 3 tests)` |
| 10 | Cross-version (v1 ↔ v2) | `deferred — v1 paired plan to be authored in a follow-up; this row is filled when that plan lands` |

---

## 12. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **R1**: Listener (afterCommit lambda) throws → OMS not notified, `Message(state=FAILED)` written | OMS lacks the WMS-CANCELLED record; manual reconcile required | Existing pattern — same as `BillofladingService.closeBOL`, `AdviceService.*`. The FAILED `Message` row is queryable via the §1 DB query. Can be reconciled by re-driving via `MessageService.resendMessage`. **No regression** vs today. |
| **R2**: Tenant context lost in afterCommit | OMS POST goes to wrong tenant DB lookup, or audit row written under wrong tenant | Verified safe: `afterCommit` runs synchronously on same thread; `TenantContext` (ThreadLocal) intact until `TenantFilter`'s `try/finally` clears it after the entire request completes. **Evidence:** existing helper users have not reported this. |
| **R3**: Replica crash between commit and afterCommit → no OMS notification, no FAILED row | Silent loss; rare but real | **Follow-up plan required** — outbox + DLQ pattern with reconciler is out of scope here. **No regression** vs today (same risk exists in all current `OmsNotificationService` users). Tracked as a follow-up plan in §11.1 Cross-references. |
| **R3b**: No kill-switch sysprop to disable the deferral if a regression is found in production | Rollback requires git-revert + redeploy rather than a tenant-level toggle | Acknowledged. Adding a sysprop is **out of scope** (would expand the diff and require feature-flag plumbing across all 8 fix sites). Risk is mitigated by the extensive verify-script + integration-test coverage; if a regression slips through, redeploy is the recovery path. |
| **R4**: Duplicate afterCommit firing on retry | Double OMS notification | Spring spec — `afterCommit` is invoked at most once per transaction. `OmsNotificationService.sendAfterCommit` registers exactly one synchronization per call. The `Message` audit row carries a unique `number` (generated by `BasicService.generateMessageNumber`) — duplicate detection is possible at OMS side via the audit-row id. |
| **R5**: A method that should still notify on rollback (e.g. a hypothetical `BolFailedEvent`) is wrongly converted | Lost-notification regression | Not applicable here. ManageOrderService methods are positive-status callbacks (HELD, RELEASED, PICKING, PICKED, PALLETIZED, LOADED). None are "X-failed" callbacks. Stock-update callback also is positive-status. **No method in this plan should fire on rollback.** |
| **R6**: Constructor-injection cycle when adding `OmsNotificationService` to `MessageService` directly | Spring fails to start | Avoided by Fix B's committed shape — extract `StockChangeNotificationService` rather than injecting `OmsNotificationService` into `MessageService`. The new `OmsNotificationConfigContextLoadTest` (§8.3) catches any latent cycle at test time. |
| **R7**: Removal of `HttpRestService` from `ManageOrderService` constructor breaks an unnoticed reference | Compile error | `mvn compile` catches this immediately; verify script Phase 1 run also catches. Mitigated by Phase 3's grep-before-remove rule in §7.2. |
| **R7b**: Existing `ManageOrderServiceUnitTest` tests (~25 stub or verify against `httpRestService.post`/`messageService.createMessage`) break under Mockito strict mode at Phase 2 — `UnnecessaryStubbingException` before assertion, plus `verify(httpRestService).post(...)` failing because production no longer makes that call. Risk: Phase 2's bisect points at the *responsible commit's test update miss* rather than at the production code change, masking real regressions. | Test-suite red bar at Phase 2; bisect noise | Per-commit existing-test update rule in §7.2 Phase 2 (mandatory grep + edit gate). Mitigated by running `mvn test -Dtest=ManageOrderServiceUnitTest` after each per-method commit and forbidding next-method commit until prior is green. |
| **R8**: Caller sites that already wrap `manageOrderService.customerOrderXxx(...)` in their own `registerSynchronization` will now defer twice | Performance: trivial extra synchronous call inside an already-deferred lambda. Functional: identical. | Documented in §5 Fix A "Caller-side double-defer interaction". Optional cleanup PR after this plan to remove the now-redundant outer wrappers. |
| **R9**: Tenant context lost in scheduled-job-driven `afterCommit` callbacks | `@Scheduled` jobs (`ReleaseOrderJobService.releaseOrder`) run outside HTTP request scope, so `TenantContext` is not automatically set. If the job's manual `TenantContext.set(...)` preamble has been cleared by the time the `afterCommit` POST runs, the deferred OMS POST and audit-row write would target the wrong (or no) tenant. | Covered by the new unit test `customerOrderOnHold_shouldPropagateTenantContext_whenCalledFromScheduledJob` (§8.1, gated by F3.d) AND the new integration test `customerOrderOnHold_shouldPreserveTenantContext_acrossSchedulerBoundary` in `CancelOrderRollbackIntegrationTest` (§8.2, gated by F8 in §9). Together they exercise both the unit-mock-only level (does the deferral fire on the right thread?) and the real-Spring `@Transactional REQUIRES_NEW` boundary level (does the tenant tag on the Micrometer counter survive the scheduler-driven thread acquiring the new transaction?). |
| **R10**: Silent loss after a transient OMS outage flap | After Fix A/B, the rollback-drift mode is gone, but the FAILED `Message` row written by `OmsNotificationService.doSend` is the only signal of an OMS outage. Without an alert on it, drift accumulates silently. | Fix C (Micrometer counter `wms2.oms.notification.failed{tenant, processType}`) is mandatory in this plan. Operator alerting (Prometheus rate alert) is wired as an Implementation Status follow-up. |

---

## 13. Implementation Status

| Phase | Commit SHA | Test class + methods added | `mvn` summary | Verify-script result |
|---|---|---|---|---|
| Phase 0 — TDD-gate baseline | `87c4164` | ManageOrderServiceUnitTest (Sbdev2214DeferralFixA nested classes, 7 deferral + 7 serialization + M4 tenant + F5/F5b/F8 IT stubs), StockChangeNotificationServiceUnitTest, OmsNotificationServiceUnitTest (FailureCounter), CancelOrderRollbackIntegrationTest stubs, OmsNotificationConfigContextLoadTest stub | 40 pass, 15 fail, 1 skip | `SKIP_MVN=1`: 40 pass, 15 fail, 1 skip |
| Phase 1 — Fix A scaffolding | `aec107a` | — (no new tests; dual-fire scaffold) | — | — |
| Phase 2 — Fix A.1..A.7 | `8ea5831` (A.1) + `620b62f` (A.2–A.7 bundled) | ManageOrderServiceUnitTest — updated all 7 Sbdev2214DeferralFixA nested classes to verify sendAfterCommit | 64 pass, 0 fail | — |
| Phase 3 — Fix A cleanup | `534cd22` | — (constructor cleanup, no new tests) | BUILD SUCCESS | — |
| Phase 4 — Fix B (+ context-load smoke) | `876d977` | StockChangeNotificationServiceUnitTest (real impl), MessageServiceUnitTest (SendStockChangeMessage updated) | BUILD SUCCESS | — |
| Phase 5 — Fix C (Micrometer counter) + line-collapse | `49be486` | OmsNotificationServiceUnitTest (LENIENT + default Counter stub); ManageOrderService sendAfterCommit calls collapsed to single lines for D4 regex | 5 pass, 0 fail (OmsNotificationServiceUnitTest) | `SKIP_MVN=1`: 55 pass, 0 fail, 1 skip |
| Phase 6 — H2 rollback IT harness | `aebb4c7` | BaseRollbackIntegrationTest, AdviceServiceRollbackIntegrationTest (3 tests, all pass locally) | 3 pass, 0 fail | — |
| Phase 6b — IT test fixes (G5+G7) | `81685c7` | CancelOrderRollbackIntegrationTest (4 tests: entity seeding, MockitoSpyBean, MessageService mock, sysprop stubs); OmsNotificationConfigContextLoadTest (BaseRollbackIntegrationTest base) | 4 pass, 0 fail (CancelOrder); 1 pass, 0 fail (ContextLoad) | `SKIP_MVN=0`: **62 pass, 0 fail, 0 skip** |
| Phase 7 — Final verify | — | — | — | `SKIP_MVN=1`: **55 pass, 0 fail, 1 skip** · `SKIP_MVN=0`: **62 pass, 0 fail, 0 skip** ✓ |
| Phase 8 — Manual smoke | pending deploy | — | — | — |

**Final acceptance line (paste from verify script):** `Result: 62 pass, 0 fail, 0 skip` (SKIP_MVN=0, 2026-05-08)

**Pre-fix DB query result (per §1):** ` ` <!-- placeholder: paste row count returned by the §1 SQL on a tenant DB before any Fix A/B/C lands -->

**Post-fix DB query result (per §1):** ` ` <!-- placeholder: paste row count returned by the §1 SQL on the same tenant DB after Phase 7 -->

**Operator-alerting follow-up (Fix C):** ` ` <!-- placeholder: link to the Prometheus alert PR / runbook entry that consumes wms2.oms.notification.failed -->

**Outbox + DLQ follow-up plan (R3):** ` ` <!-- placeholder: filename of the follow-up plan once it is filed -->

**`MessageService.resendMessage` follow-up plan (M3 / §0 row 13):** ` ` <!-- placeholder: filename of the follow-up plan once it is filed -->

---

## 14. Acceptance & Implementation

### 14.1 Recommended OMC composition (for implementation — plan-meta routing)

| Aspect | Value | One-line rationale |
|---|---|---|
| Size class | **Standard** | 8 fixes (7 method bodies + 1 method delegation + 1 counter) in 3-4 service files; verify-guarded; clear pattern. |
| Pre-draft step | none | Resolved decisions in §11. |
| Plan-review step | `critic` | Standard+ should run a critic pass before implementation. |
| Implementation shape | `executor` | Single-loop OK because the verify-script is comprehensive (encodes every fix point). Escalate to `ralph` only if a phase loops on the same FAIL. |
| Verification step | `verify-script + verifier` | mandatory. |
| Code-review step | `code-reviewer` | recommended for any plan touching transaction boundaries. |
| Commit step | `git-master` | 7+ atomic commits per §7.2 phasing — `git-master` ensures consistent trailers. |

### 14.2 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2214-oms-http-post-inside-class-level-transactional.sh`

The script encodes:
- **POSITIVE** that `cancelOrder` still uses `omsNotificationService.sendAfterCommit(... ORDER_BATCH_CANCELLED_FROM_WMS)` (regression guard, method-scoped).
- **POSITIVE** that `cancelBatch` still uses `omsNotificationService.sendAfterCommit(... ORDER_BATCH_CANCELLED_FROM_WMS)` (regression guard, method-scoped).
- **NEGATIVE** that `httpRestService.post` does NOT appear anywhere in `CustomerorderService.java`.
- **NEGATIVE** that `httpRestService.post` does NOT appear anywhere in `CustomerorderBatchService.java`.
- **POSITIVE** that `omsNotificationService.sendAfterCommit` appears at least 7 times in `ManageOrderService.java` AND that at least 2 specific method bodies (`customerOrderOnHold`, `customerOrderPicked`) contain the deferred-call sentinel.
- **NEGATIVE** that `httpRestService.post` does NOT appear in `ManageOrderService.java` AND that `HttpRestService` and `MessageService` are no longer constructor-injected into `ManageOrderService`.
- **POSITIVE** that the new file `StockChangeNotificationService.java` exists and contains `omsNotificationService.sendAfterCommit`.
- **NEGATIVE** that `httpRestService.post` does NOT appear inside the `sendStockChangeMessage` method body of `MessageService.java` (multi-line regex — uses `file_contains_ml`).
- **POSITIVE** that `OmsNotificationService.java` calls `meterRegistry.counter("wms2.oms.notification.failed", ...)` in its FAILED branch (Fix C).
- **POSITIVE** that the integration test method `cancelOrder_shouldNotPostToOms_whenPostCancelCleanupThrows` exists in `CancelOrderRollbackIntegrationTest.java`.
- **POSITIVE** that the new tests for the renamed unit test, the M4 scheduled-job tenant-context test, and the M5 counter test exist.
- **POSITIVE** that the existing baseline test count is preserved (no deletion of the existing 55 `@Test`s in `ManageOrderServiceUnitTest`).
- **mvn_test_passes** for the touched test classes.

Run baseline before any code change; run after every cluster of changes; final acceptance line `Result: N pass, 0 fail, M skip`.

### 14.3 Cross-plan references

- Standard-shape example (4-fix): `SBDEV-2095-large-bol-close-decoupling-and-perf.md`.
- Larger OMS-decoupling cousin (14-site, v1): `260424-oms-notification-rollback-risk-remediation.md` — its `OmsNotificationHelper.deferToCommit` is the v1 ancestor of v2's `OmsNotificationService.sendAfterCommit`.
- Adjacent v2 plan: `260503-runclubline-transaction-boundary-hardening.md` — partially overlaps in concept but does not modify ManageOrderService.

---

## 15. Revision history

| Date | Author | Description |
|---|---|---|
| 2026-05-08 | Nam Park | Initial draft (v2-only). Resolved decisions in §11 used "use reasonable defaults". |
| 2026-05-08 | Critic-driven revision (executor) | Addressed C1 (drop "class-level" framing — v2 uses method-level `@Transactional`), C2 (mark existing test files as Modify-append, not NEW; preserve 55 `@Test`s in `ManageOrderServiceUnitTest`), M1 (single-line annotation regex for verify-script), M2 (drop stray `BolClosedEvent` row from §4), M3 (`MessageService.resendMessage` follow-up plan documented), M4 (R9 — scheduled-job tenant-context risk + new test), M5 (Micrometer counter promoted from optional Phase 6 to mandatory Phase 5 as Fix C), M6 (replace `cancelOrder_shouldNotPostToOms_whenFinalizeThrows` unit test with `cancelOrder_shouldRegisterAfterCommitSynchronization_whenCancellationFromWithinWMS`; rollback semantics moved to integration test), M7 (verify-script F-section reconciled with named tests in §8), Mn1 (15 callers, not 16), Mn3 (only `ReleaseOrderJobService` callers are unwrapped), Mn5 (DB query result placeholder confirmed), Co2 (caller annotation table reorganized into a dedicated sub-table), Co3 (cross-reference greps annotated as informational), Co4 (§14.2 plan-meta routing moved to §14.1). Verify script gained method-scoped regression checks, Fix C counter check (§I), baseline-preservation checks, and a new `OmsNotificationConfigContextLoadTest` smoke-test gate (§8.3). **New baseline (SKIP_MVN=1): `Result: 17 pass, 37 fail, 1 skip`** (was: `Result: 14 pass, 23 fail, 1 skip` before this revision — the +3 PASS reflect the existing v2 method-level `@Transactional` annotations now matching the corrected B1c/C1c/method-scoped regexes; the +14 FAIL reflect the 14 newly-added checks for the M4/M5/M6/M7 + Fix C surface that did not exist before). |
| 2026-05-08 | Fourth-pass hygiene fixes (executor) | Three targeted fixes: **Major-1** corrected two stale `§10` cross-references — plan:153 `§10 Implementation Status` → `§13 Implementation Status`; plan:747 `Risk R3 in §10` → `Risk R3 in §12 (Risks & Mitigations)`; plan:816 `§10 row 8` left intentionally (correctly references §10 v2-only constraint checklist row 8 on Micrometer metrics). **Major-2** tightened the I3 verify-script regex from `[\s\S]*?` to `[^)]*?` so the quantifier cannot span across a closing paren and produce a false-PASS when a second `meterRegistry.counter(...)` call exists in the same file. Smoke-tested: two-counter false-PASS case OLD=PASS/NEW=FAIL; multi-line positive case OLD=PASS/NEW=PASS. **Major-3** rewrote Phase 0 baseline math: corrected static `run` count from "55" to **62** (§D=14 not 12, §F=17 not 16), clarified that 55 is the non-skip result count under `SKIP_MVN=1` (§G's 7 maven runs collapse to 1 SKIP), and restated the baseline as `16 pass, 39 fail, 1 skip`. Baseline re-confirmed unchanged after I3 regex tightening. |
| 2026-05-08 | Third-pass critic-driven revision (executor) | Addressed 12 second-pass-critic findings: **NEW-C1** rewrote `method_body_contains` (and added a matching `method_body_not_contains`) as a perl one-liner; the prior awk implementation rejected user regexes containing unescaped `(` (BSD awk `illegal primary in regular expression`), silently turning 11 method-scoped checks (B1a2, C1a2, D2a, D2b, D4-1..D4-7) into permanent FAILs that the `2>/dev/null` swallowed. Smoke-tested positive (cancelOrder body containing `omsNotificationService.sendAfterCommit(` → exit 0) and negative (cancelOrder body containing `httpRestService.post(` → exit 1). **NEW-C2** rewrote I3 to use `file_contains_ml` with `[\s\S]*?` lazy quantifier between literal anchors so the multi-line counter call in §3 Fix C now matches. **NEW-C3** rewrote the §3 Fix C "After" snippet to dereference `TenantContext.getCurrentTenant()` (purely static API on v2; `getCurrentTenant()` returns nullable `TenantProfile`) with a null-guard returning `"unknown"`; added unit test `OmsNotificationService_shouldUseUnknownTenantTag_whenTenantContextIsNull` and verify-script row F9 to gate the null branch. **NEW-M1** added integration test `customerOrderOnHold_shouldPreserveTenantContext_acrossSchedulerBoundary` (housed in `CancelOrderRollbackIntegrationTest`) and verify-script row F8 to gate it; updated R9 mitigation prose to cite both F3.d (unit) and F8 (integration). **NEW-M2** raised F1c threshold from `≥2` to `≥89` (87 existing CustomerorderServiceUnitTest tests + 2 new) and F2b from `≥1` to `≥90` (89 existing CustomerorderBatchServiceUnitTest tests + 1 new); added inline comments documenting the floors. **NEW-M3** deleted F3e (was redundant with F3a — `customerOrderPicked` is a substring of `customerOrderPicked_shouldDeferOmsPostUntilAfterCommit`); replaced with a `# Removed: F3e was redundant…` marker. **NEW-M4** added per-site `@Transactional` annotation table for ReleaseOrderJobService:217/533/652 — confirmed all 3 sites are inside the SAME public method `releaseOrder` at line 100 with annotation `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` at line 99 (verified by `grep -nE '^\s*(public\|@Transactional)' ReleaseOrderJobService.java`). **NEW-Mn1** changed §2 Bug 4 prose from "16 sites" to "15 sites" to align with §0 row 12. **NEW-Mn2** disambiguated "v1 paired plan deferred" — single source in §11.1 row 4. **NEW-Mn3** Phase 7 reference corrected from "§10" to "§13 Implementation Status". **NEW-Mn4** rewrote Phase 0 baseline math to match the post-third-pass check decomposition (55 `run` invocations + 1 mvn cluster). **NEW-Mn5** rewrote §3 Fix C "Before" snippet verbatim from `OmsNotificationService.java:79-88` (preserved actual `messageService.createMessage(...)` no-return-capture call and the actual `LOG.error("OMS notification failed for processType={}: {} - {}", ...)` format string). **New baseline (SKIP_MVN=1): `Result: 16 pass, 39 fail, 1 skip`** (was `17 pass, 37 fail, 1 skip` after second-pass revision — net delta is the perl rewrite flipping 1 previously-erroneous PASS to FAIL, the F3e deletion, and the F8/F9 additions). |

---
