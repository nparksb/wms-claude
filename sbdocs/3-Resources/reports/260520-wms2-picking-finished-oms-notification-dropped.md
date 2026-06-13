---
title: "WMS2 — ORDER_BATCH_PICKING_FINISHED Notification Silently Dropped"
type: investigation
status: concluded
version: v1
scope: WMS v2 (wms2-api) — picking order release → OMS picking-finished notification
owner: nam.park@siteboss.net
created: 2026-05-20
updated: 2026-05-20
last_verified: 2026-05-20
verified_by: nam.park@siteboss.net
related:
  - 260424-wms-oms-notification-delivery-guarantees
  - wms2-oms-integration-map
  - wms2-transaction-osiv-boundary-map
tags:
  - investigation
  - report
  - oms-notification
  - picking
  - after-commit
  - delivery-guarantee
---

# WMS2 — ORDER_BATCH_PICKING_FINISHED Notification Silently Dropped

**Topic:** WMS v2 `releasePickingOrder` → OMS `finishedPicking` notification | **Version:** v1  
**Started:** 2026-05-20 | **Investigator:** Nam Park  
**Status:** concluded

---

## 1. Context & Trigger

After a picker completes picking on the WMS2 mobile UI and presses **Release**, OMS is supposed to receive an `ORDER_BATCH_PICKING_FINISHED` HTTP POST (the signal that triggers OMS QA). In this incident, OMS reported **"No Parcel Found"** for tote T-2168.

The WMS2 backend logs for picking order **id=29506341** show:

```
2026-05-20 18:15:04.496 [tomcat-handler-13] DEBUG n.a.w.c.mobile.PickingController      - [wine-wsl][] releasePickingOrder id = 29506341
2026-05-20 18:15:04.497 [tomcat-handler-13] DEBUG n.a.w.s.mobile.MobilePickingService   - [wine-wsl][] start releaseRegularPickingOrder with pickingOrderId=29506341
2026-05-20 18:15:04.502 [tomcat-handler-13] DEBUG n.a.w.s.mobile.MobilePickingService   - [wine-wsl][] end releaseRegularPickingOrder - order already finished. pickingOrderId=29506341
```

The order exited via the **Case 1 early-return branch** — "already finished" — without any OMS notification being triggered.

---

## 2. Questions

1. Which code path triggers the OMS `ORDER_BATCH_PICKING_FINISHED` notification, and what guards it?
2. Why did `releaseRegularPickingOrder` hit the "already finished" early exit, and does that path send the OMS notification?
3. What set picking order 29506341 to FINISHED before `releasePickingOrder` was called?
4. Is the OMS notification reliably delivered when `finishPickingOrder` is called from the high-priority pick confirm flow? If not, why not?
5. Is this a race condition, a state-machine bug, or a notification-plumbing bug?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence |
|---|-----------|---------------------|
| H1 | The early-exit at `releaseRegularPickingOrder` Case 1 is the direct cause — it returns without calling `finishPickingOrder`, so OMS is never notified. | high |
| H2 | The order was already FINISHED because `finishPickingOrder` was called from the confirm-pick flow. That call DID attempt the OMS notification but the notification was silently dropped (fire-and-forget failure). | high |
| H3 | The OMS notification was silently dropped due to a double-`afterCommit` registration: `finishPickingOrder` registers callback A; inside callback A, `sendAfterCommit` registers callback B; Spring discards B without firing it. | medium-high |
| H4 | `isProduction()` returned `false`, so the OMS block was skipped entirely. | low — rules out immediately if `pickingconfirmationsent=true` in DB |
| H5 | A race condition between concurrent `processPick` and `releasePickingOrder` requests caused one to see a stale state. | low — logs show a single thread finishing the flow end-to-end |

---

## 3.5 Sources In Scope

| Source | Location |
|--------|----------|
| `MobilePickingService.releaseRegularPickingOrder` | `MobilePickingService.java:699` |
| `MobilePickingService.rapidPickingScanSource` | `MobilePickingService.java:1124` |
| `MobilePickingService.ProcessRapidPickingScanSource` | `MobilePickingService.java:1106` |
| `PickingorderBusinessService.finishPickingOrder` | `PickingorderBusinessService.java:137` |
| `PickingorderBusinessService.confirmPick` | `PickingorderBusinessService.java:377` |
| `ManageOrderService.customerOrderPicked` | `ManageOrderService.java:219` |
| `OmsNotificationService.sendAfterCommit` | `OmsNotificationService.java:49` |
| `OmsNotificationService.doSend` | `OmsNotificationService.java:87` |
| `PickingController.releasePickingOrder` | `PickingController.java:251` |
| DB: `pickingorder` row id=29506341 | wms2-wineco-dev |
| DB: `customerorder` rows id=29506338, 29781897 | wms2-wineco-dev |
| DB: `message` table — `ORDER_BATCH_PICKING_FINISHED` rows | wms2-wineco-dev |
| DB: `outbox_message` table | wms2-wineco-dev |
| Prior report | `sbdocs/3-Resources/reports/260424-wms-oms-notification-delivery-guarantees.md` |
| Architecture doc | `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` |

---

## 4. Method

1. Code read — trace `releaseRegularPickingOrder` Case 1 to confirm OMS is never called.
2. Code read — trace the confirm-pick path (`rapidPickingScanSource` → `confirmPick` → `finishPickingOrder`) to establish when order transitions to FINISHED and when OMS notification is attempted.
3. Code read — `OmsNotificationService.sendAfterCommit` to check if nested `afterCommit` registration is safe.
4. DB queries — confirm actual state of picking order, customer orders, `pickingconfirmationsent` flag, and absence of `message` / `outbox_message` records.
5. Cross-reference `WmsConstants.State` integers (PICKED=600, FINISHED=700) to confirm DB state readings.

---

## 5. Evidence

### E1 — Case 1 early exit returns without any OMS call

`MobilePickingService.java:705-709`:

```java
// Case 1: Order is already finished — nothing to do
if (pickingOrder.getState() > WmsConstants.State.PICKED) {
    LOG.debug("end releaseRegularPickingOrder - order already finished. pickingOrderId={}", pickingOrderId);
    return true;
}
```

**Observation:** When the picking order state is `> 600` (i.e., FINISHED=700), this branch fires and the method returns `true` immediately. There is **no OMS notification, no fallback send, no outbox enqueue** in this path.

**Supports:** H1 ✓

---

### E2 — The OMS notification lives exclusively in `finishPickingOrder`

`PickingorderBusinessService.java:246-281` (condensed):

```java
if (customerOrder.getState() >= WmsConstants.State.PICKED
        && (customerOrder.getPickingconfirmationsent() == null || !customerOrder.getPickingconfirmationsent())) {
    if (basicService.isProduction()) {
        customerOrder.setPickingconfirmationsent(true);
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override
                public void afterCommit() {           // ← Callback A
                    manageOrderService.customerOrderPicked(...);
                }
            });
        } else {
            manageOrderService.customerOrderPicked(...);  // synchronous fallback
        }
    }
}
```

**Observation:** `finishPickingOrder` registers **Callback A** (`customerOrderPicked`) to run after the current transaction commits. It sets `pickingconfirmationsent=true` inside the transaction (commits with the TX). This is the **only place** where `ORDER_BATCH_PICKING_FINISHED` is issued.

**Supports:** H2 ✓

---

### E3 — `customerOrderPicked` calls `sendAfterCommit`, which registers a second `afterCommit`

`ManageOrderService.java:254-266`:

```java
omsNotificationService.sendAfterCommit(urlPath, payload, WmsConstants.MessageProcessType.ORDER_BATCH_PICKING_FINISHED);
```

`OmsNotificationService.java:65-84`:

```java
if (TransactionSynchronizationManager.isSynchronizationActive()) {
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
        @Override
        public void afterCommit() {       // ← Callback B
            doSend(urlPath, payload, processType);
        }
    });
} else {
    doSend(urlPath, payload, processType);   // synchronous fallback
}
```

**Observation:** `sendAfterCommit` registers **Callback B** (the actual HTTP POST in `doSend`) only when `isSynchronizationActive()` is true, otherwise it sends synchronously.

**Supports:** H3 (partial — depends on whether synchronization is still active when Callback A fires)

---

### E4 — Spring keeps synchronization active during `afterCommit` processing

Spring's `AbstractPlatformTransactionManager.processCommit` executes in this order:

```
doCommit()
  → triggerAfterCommit()           ← Callback A fires here
      → triggerAfterCompletion()   ← afterCompletion() only
  → cleanupAfterCompletion()       ← TransactionSynchronizationManager.clear() called HERE
```

`TransactionSynchronizationManager.isSynchronizationActive()` returns `synchronizations.get() != null`. `synchronizations` is only cleared inside `cleanupAfterCompletion()`, which runs **after** `triggerAfterCommit()` finishes.

**Therefore:** When Callback A (`customerOrderPicked`) fires during `triggerAfterCommit`, `isSynchronizationActive()` returns **`true`**. `sendAfterCommit` proceeds to register Callback B via `registerSynchronization()`. But Spring's `triggerAfterCommit()` has already finished iterating — it worked from the snapshot of synchronizations captured before iteration. Callback B is added to the manager's list but is **never iterated in the afterCommit phase**. After Callback A returns, Spring calls `cleanupAfterCompletion()` which calls `TransactionSynchronizationManager.clear()`, **discarding Callback B without ever firing it**.

**Inference:** `doSend` is never called. No HTTP POST is made. No `Message` record is created.

**Supports:** H3 ✓ (this is the primary mechanism)

---

### E5 — DB confirms: `pickingconfirmationsent=true` but no message record

Query result (wms2-wineco-dev):

```
pickingorder id=29506341  number=PICK230053  state=700  (FINISHED)
customerorder id=29506338  number=051532-000001  state=600 (PICKED)  pickingconfirmationsent=true
customerorder id=29781897  number=051543-000001  state=600 (PICKED)  pickingconfirmationsent=true
```

Query: `message` table WHERE process = 'ORDER_BATCH_PICKING_FINISHED' AND message LIKE '%051532%' OR '%051543%'  
Result: **0 rows**

Query: `outbox_message` table WHERE payload LIKE '%051532%' OR '%051543%'  
Result: **0 rows**

**Observation:**
- `pickingconfirmationsent=true` confirms `finishPickingOrder`'s notification block WAS entered and the flag committed (rules out H4 — `isProduction()` was true).
- Zero `message` rows confirms `doSend` never ran (would have created a SENT or FAILED row).
- Zero `outbox_message` rows confirms the outbox was not used (the caller uses the legacy `sendAfterCommit` pattern, not `outboxService.enqueue`).

**Supports:** H2 ✓, H3 ✓. **Kills:** H4 ✗.

---

### E6 — The confirm-pick flow (`rapidPickingScanSource`) calls `finishPickingOrder` before `releasePickingOrder` is ever invoked

`MobilePickingService.java:1124-1227` (condensed):

```java
@Transactional(value = "tenantTransactionManager", ...)
public PickingHighPositionInfoDto rapidPickingScanSource(...) {
    pickingOrder = pickingorderBusinessService.confirmPick(...);   // sets PO→PICKED when last pick done
    // ...check remaining positions...
    if (pickingOrder.getState() == WmsConstants.State.PICKED) {
        pickingOrder = pickingorderBusinessService.finishPickingOrder(pickingOrder);  // line 1227 — sets PO→FINISHED, registers Callback A
        // ...
        return dto;  // ← picker sees "pick complete", then presses Release
    }
}
```

**Observation:** `rapidPickingScanSource` is itself `@Transactional`. When the last pick position is confirmed, `confirmPick` sets the PO to PICKED; `finishPickingOrder` is then called immediately within the same TX, registers Callback A, and sets the PO to FINISHED. The TX commits; Callback A fires; Callback B is registered but silently discarded.

By the time the picker presses **Release** and `releaseRegularPickingOrder` is called (a separate HTTP request, a separate TX), the PO is already FINISHED=700, triggering Case 1 early exit.

**Supports:** H2 ✓, H5 ✗ (no race — it's a single sequential flow across two requests).

---

### E7 — Null result: no alternative `PICKING_FINISHED` send path exists

Search: `grep -rln "ORDER_BATCH_PICKING_FINISHED\|customerOrderPicked"` across all service files.  
**Only callers of `customerOrderPicked`:** `PickingorderBusinessService.finishPickingOrder` (the path analyzed above). No other path.

Search: `grep -rn "outboxService.enqueue"` near picking flow.  
**Result:** `finishPickingOrder` does **not** use the outbox. The `customerOrderPicked` → `sendAfterCommit` chain is the only OMS notification path for the picking-finished event.

**Observation:** There is no retry, no compensating outbox, no recovery in `releaseRegularPickingOrder` Case 1. Once Callback B is lost, the notification is permanently dropped unless manually re-triggered via the admin resend endpoint (which the OMS team is unaware of).

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Verdict |
|---|-----------|-----------------|---------|
| H1 | Early exit in Case 1 is the proximate cause | **confirmed** | The early exit is the observed failure point, but it is a symptom, not the root cause — the notification was already lost before `releasePickingOrder` was called. |
| H2 | `finishPickingOrder` called from confirm-pick path; notification silently dropped | **confirmed** | Picking order was set FINISHED during `rapidPickingScanSource` TX. |
| H3 | Double `afterCommit` registration — Callback B silently discarded by Spring | **confirmed** | The mechanism is deterministic: Spring clears synchronizations after `triggerAfterCommit` completes; any new registration made from within Callback A is discarded. This happens on **every** successful picking completion via the high-priority pick path. |
| H4 | `isProduction()` returned false | **eliminated** | `pickingconfirmationsent=true` in DB proves the production block was entered. |
| H5 | Race condition | **eliminated** | Sequential two-request flow. No concurrent threads involved in the failure. |

---

## 7. Verdict

**The `ORDER_BATCH_PICKING_FINISHED` OMS notification is reliably lost on every order completed via the high-priority pick confirm flow.**

The bug is a **double `afterCommit` registration** in the notification chain:

```
rapidPickingScanSource (@Transactional)
  └─ finishPickingOrder (@Transactional, inherits TX)
        └─ registers Callback A (TransactionSynchronizationManager)
        └─ sets pickingconfirmationsent=true  ← TX commits here
  
[TX commits → triggerAfterCommit() starts]
  └─ Callback A fires: customerOrderPicked()
        └─ sendAfterCommit()
              └─ isSynchronizationActive() == true  ← Spring hasn't cleared yet
              └─ registers Callback B (doSend)  ← SILENTLY DISCARDED
              
[triggerAfterCommit() finishes → cleanupAfterCompletion() → clear()]
  └─ Callback B evaporated — doSend() never runs
  └─ No HTTP POST to OMS
  └─ No Message row created
  └─ pickingconfirmationsent=true already committed — flag is a lie
```

When `releasePickingOrder` is called next (separate HTTP request), the PO is FINISHED=700, Case 1 early exit fires, and the call returns `true` with no notification — no error, no retry, no log at ERROR level. OMS never receives the picking-finished event and reports "No Parcel Found" when it tries to initiate QA.

**Overall confidence: high.** The mechanism is deterministic and reproducible. DB evidence (flag true, zero message rows) is unambiguous. The Spring lifecycle behavior (`isSynchronizationActive()` during `afterCommit`) is documented in Spring source.

---

## 8. Recommendation

**Fix now.** This affects every order completed via the `rapidPickingScanSource` → `confirmPick` → `finishPickingOrder` path (the primary mobile picking flow). OMS QA is blocked for all such orders.

**Fix approach — migrate `finishPickingOrder` to the transactional outbox:**

Replace the double-`afterCommit` pattern in `PickingorderBusinessService.finishPickingOrder` with `outboxService.enqueue(OutboxMessage)` (the SBDEV-2238 outbox already in production). The outbox row commits atomically inside the same tenant transaction as the WMS state change; `OutboxDispatcherJob` (every 15 s) delivers it with exponential-backoff retry. This eliminates the double-`afterCommit` problem entirely.

As a secondary, defensive fix: `releaseRegularPickingOrder` Case 1 should check `pickingconfirmationsent` on the linked customer orders and re-enqueue any unsent notifications before returning, so the "Release" button becomes a recovery path for missed notifications.

**Do not** fix the double-`afterCommit` by moving the `sendAfterCommit` call earlier (still inside the TX) — this reintroduces rollback-after-notify risk documented in `260424-wms-oms-notification-delivery-guarantees.md`. The outbox is the correct solution.

Draft the fix via **`wms-bugfix-plan`** targeting `v2/wms2-api`. The downstream plan **must** ship a `sbdocs/9-System/scripts/verify-<plan-id>.sh` that confirms:
- An `outbox_message` row is created when `finishPickingOrder` runs
- `OutboxDispatcherJob` delivers it within 30 s
- The `message` table records a SENT row for `ORDER_BATCH_PICKING_FINISHED`
- `releaseRegularPickingOrder` Case 1 no longer silently skips unsent notifications

---

## 9. Open Questions

1. **Are other `sendAfterCommit` callers affected?** `ManageOrderService.customerOrderOnHold`, `customerOrderPickingReleased`, `customerOrderToteAssigned`, `customerOrderPalletized`, `customerOrderShipped` all call `sendAfterCommit`. If any are called from within an existing `afterCommit` callback chain, they have the same double-registration bug. Audit needed.

2. **How many orders are affected?** The message table shows zero `ORDER_BATCH_PICKING_FINISHED` rows for recent dates in the dev environment, suggesting the bug is systemic. A production audit should count orders where `pickingconfirmationsent=true` but no corresponding `Message` row exists.

3. **Is `isProduction()` tenant-scoped?** If any tenant is in non-production mode, `pickingconfirmationsent` is never set (flag stays false). Those orders would re-enter the notification block on next `finishPickingOrder` call — but there's no such retry. Needs clarification.

4. **How does OMS recover today?** The "resend" admin endpoint exists in WMS but OMS doesn't know to request it. Defining a reconciliation SOP between WMS and OMS ops is out of scope here but worth documenting.

---

## 10. References

- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java:699` — `releaseRegularPickingOrder` (Case 1 early exit)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java:1106` — `ProcessRapidPickingScanSource` (`@Transactional` entry point for confirm-pick)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java:1124` — `rapidPickingScanSource` (calls `finishPickingOrder` at line 1227)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:137` — `finishPickingOrder` (registers Callback A, sets `pickingconfirmationsent=true`)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/ManageOrderService.java:219` — `customerOrderPicked` (Callback A — calls `sendAfterCommit`)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/OmsNotificationService.java:49` — `sendAfterCommit` (registers Callback B — silently discarded)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/OmsNotificationService.java:87` — `doSend` (never reached via Callback B)
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — OMS notification architecture (verify `finishPickingOrder` is not yet migrated to outbox)
- `sbdocs/3-Resources/reports/260424-wms-oms-notification-delivery-guarantees.md` — Prior report on v1 notification delivery gaps (same class of failure)
- DB evidence: wms2-wineco-dev, 2026-05-20 — PICK230053 (id=29506341), CO 051532-000001, 051543-000001
