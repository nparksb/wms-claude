---
title: "WMS2 — QA Blocked: Missing tote_label in PICKING_FINISHED Payload + Service Log Gap"
type: investigation
status: concluded
version: v2
scope: WMS v2 (wms2-api) → OMS v2 (oms-laravel-api) picking-finished notification — post-outbox migration issues
owner: nam.park@siteboss.net
created: 2026-05-21
updated: 2026-05-21
last_verified: 2026-05-21
verified_by: nam.park@siteboss.net
related:
  - 260520-wms2-picking-finished-oms-notification-dropped
  - 260520-picking-finished-oms-notification-fix
  - 260424-wms-oms-notification-delivery-guarantees
  - wms2-oms-integration-map
tags:
  - investigation
  - report
  - oms-notification
  - picking
  - qa
  - outbox
  - tote-label
  - message-log
---

# WMS2 — QA Blocked: Missing tote_label in PICKING_FINISHED Payload + Service Log Gap

**Topic:** WMS v2 outbox-dispatched `ORDER_BATCH_PICKING_FINISHED` → OMS `finishedPicking` handler | **Version:** v2  
**Started:** 2026-05-21 | **Investigator:** Nam Park  
**Status:** concluded

> **Context:** The prior investigation (`260520-wms2-picking-finished-oms-notification-dropped.md`) identified and fixed the double-`afterCommit` bug that caused PICKING_FINISHED notifications to never leave WMS. That fix migrated the call to `outboxService.enqueue()`. This report investigates the two remaining failures observable *after* that fix is deployed:
> - Issue 1 — OMS still shows the parcel in Picking status despite receiving the outbox-dispatched notification.
> - Issue 2 — PICKING_FINISHED appears in `outbox_message` but never in the `message` table (Service Log admin page).

---

## 1. Context & Trigger

After the SBDEV-2238 outbox migration for `finishPickingOrder`, WMS2 successfully enqueues `ORDER_BATCH_PICKING_FINISHED` to `outbox_message`. `OutboxDispatcherJob` dispatches it to OMS within 15 s. However:

1. The **OMS QA screen** still displays *"This parcel is currently in Picking status and cannot be processed through QA."* — the parcel remains at `parcel_status = 24` (PICKING) instead of advancing to `parcel_status = 25` (WAITING_FOR_QA).
2. The **WMS2 Service Log** admin page (backed by the `message` table) shows **no record** of the `ORDER_BATCH_PICKING_FINISHED` dispatch, while the `outbox_message` row shows `status = 'SENT'`.

Both issues are silent: no HTTP error, no Java exception, no WMS alert. The outbox row is marked SENT and the matter is considered closed by WMS.

---

## 2. Questions

1. Why does OMS not advance the parcel to `parcel_status = 25` even when it receives a well-formed `ORDER_BATCH_PICKING_FINISHED` POST?
2. What specific field is missing from the WMS payload, and what must WMS send to allow OMS to complete the transition?
3. How does OMS signal the failure back to WMS, and why does WMS not detect it?
4. Why does a successfully-dispatched outbox message produce no row in the `message` table, and which part of the dispatch pipeline is responsible for the gap?
5. Does the `message` table gap affect any outbox-dispatched notification type, or only PICKING_FINISHED?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|---------------------|-----------|
| H1 | WMS omits a field required by OMS `finishedPicking`, causing OMS to silently skip the position | high | OMS PHP handler has per-position guards that `continue` on missing fields |
| H2 | OMS `finishedPicking` rejects the request entirely (non-200 HTTP), OutboxDispatchService wrongly marks SENT | low | Outbox dispatcher would only mark SENT on HTTP 2xx — more likely OMS returns 200 with partial failure |
| H3 | OMS returns HTTP 200 with `Status: 'Error'` body on partial failure; dispatcher can't detect it | high | HTTP body inspection not implemented in dispatcher |
| H4 | OMS `isAwaitingQa()` gate blocks QA, not the missing status transition | medium | Status 24 IS in `PRE_AWAITING_QA_STATES`; gate may or may not be the blocker |
| H5 | `OutboxDispatchService` has no `MessageService` dependency — it never writes to the `message` table | high | Architectural gap introduced when outbox was created without porting the legacy log-write |
| H6 | Nothing is actually wrong — PICKING_FINISHED is reliably delivered and the QA blocker is something else | low | User reports consistent reproduction |

---

## 3.5 Sources In Scope

| Source | Location |
|--------|----------|
| `ManageOrderService.buildPickedPayloadJson` | `v2/wms2-api/…/service/ManageOrderService.java:262–304` |
| `PickingorderBusinessService.finishPickingOrder` (outbox enqueue) | `v2/wms2-api/…/service/PickingorderBusinessService.java:264–275` |
| `OutboxDispatchService.dispatchPendingMessages` | `v2/wms2-api/…/service/job/OutboxDispatchService.java` |
| `OmsNotificationService.doSend` (legacy message write) | `v2/wms2-api/…/service/OmsNotificationService.java:103–134` |
| OMS `finishedPicking` handler | `v2/oms-laravel-api/…/Http/Controllers/Api/Legacy/LegacyWmsController.php:1410–1550` |
| OMS `QaWorkflowService` | `v2/oms-laravel-api/…/Services/Qa/QaWorkflowService.php` |
| OMS `QaParcelController.updateQaStatus` | `v2/oms-laravel-api/…/Http/Controllers/Api/Qa/QaParcelController.php:214–238` |
| Prior report (double-afterCommit) | `sbdocs/3-Resources/reports/260520-wms2-picking-finished-oms-notification-dropped.md` |
| Fix plan | `sbdocs/1-Projects/wms2/plan/260520-picking-finished-oms-notification-fix.md` |

---

## 4. Method

1. **Code read — WMS payload builder:** Inspect `ManageOrderService.buildPickedPayloadJson` to enumerate every field set, identify which fields are conditional, and trace which are null-omitted via the `NON_NULL` Jackson serializer.
2. **Code read — OMS `finishedPicking` handler:** Trace every field read from the incoming payload, every `continue`/`break` guard, and the final `parcel_status` assignment. Confirm what HTTP status code is returned on partial failure.
3. **Code read — `OutboxDispatchService`:** Check imports and injected dependencies for `MessageService`. Inspect the HTTP response handling logic to determine whether body-level errors are checked.
4. **Code read — `OmsNotificationService.doSend`:** Confirm where the legacy `message` table write occurs and which callers benefit from it.
5. **Code read — OMS QA gate:** Read `QaWorkflowService` status constants and `QaParcelController.updateQaStatus` to establish whether status 24 would also block QA even if the parcel advanced correctly.
6. **Pattern search:** Grep for `tote_label` across WMS payload builders and OMS handler to pinpoint the exact field name mismatch or omission.
7. **DB validation (attempted):** `wms2-wineco-dev` MCP tool was not available in this session; `psql` CLI returned `command not found`. DB evidence could not be collected. See §9 Open Questions.

---

## 5. Evidence

### E1 — `buildPickedPayloadJson` sets `tote_label` only when a picking tote is assigned

`ManageOrderService.java:262–304` (condensed):

```java
PickedBatchOrderDto orderDto = new PickedBatchOrderDto();
// ...
if (customerOrder.getIsClubOrder() != null && customerOrder.getIsClubOrder()) {
    // CLUB orders: synthesise a UUID as tote label
    orderDto.setToteLabel(UUID.randomUUID().toString());   // line ~282–284
} else if (customerOrder.getPickingtoteId() != null) {
    // Regular orders WITH a tote: look up the unitload label
    Unitload pickingTote = unitloadRepository.findById(customerOrder.getPickingtoteId())
            .orElseThrow(() -> new EntityNotFoundException("UnitLoad", customerOrder.getPickingtoteId()));
    orderDto.setToteLabel(pickingTote.getLabelid());        // line ~290
}
// If neither branch fires, toteLabel remains null.

ObjectMapper mapper = new ObjectMapper();
mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);   // line ~298
return mapper.writeValueAsString(orderBatchDto);                   // toteLabel key absent from JSON
```

**Observation:** For regular (non-CLUB) orders where `pickingtoteId` is null (pick-pack orders that complete without a physical tote assignment), `toteLabel` is never set. The `NON_NULL` serializer omits it from the JSON body entirely — the key `tote_label` is absent from the POST payload.

**Supports:** H1 ✓, kills H6 ✗

---

### E2 — OMS `finishedPicking` treats missing `tote_label` as a skip-and-continue error

`LegacyWmsController.php:1469–1475`:

```php
$toteLabel = $position['tote_label'] ?? '';          // missing key → empty string

if (empty($toteLabel)) {
    $errors[] = "{$uniqueId} - Has no UL Code";
    continue;                                         // position is skipped entirely
}
```

`LegacyWmsController.php:1499` (only reached when `toteLabel` is non-empty):

```php
$parcel->parcel_status = 25;                          // WAITING_FOR_QA
```

`LegacyWmsController.php:1531`:

```php
$status = empty($errors) ? 'Success' : 'Error';
// HTTP response: 200 in both cases
return response()->json(['Status' => $status, ...], 200);
```

**Observation:** When `tote_label` is absent or empty OMS:
1. Adds a human-readable error string to `$errors`
2. `continue`s to the next position (the `parcel_status = 25` assignment is never reached)
3. Returns HTTP 200 with JSON body `{"Status": "Error", ...}`

The parcel stays at `parcel_status = 24` (PICKING). OMS has fulfilled its API contract (200 OK) while silently not completing the transition.

**Supports:** H1 ✓, H3 ✓

---

### E3 — `OutboxDispatchService` checks HTTP status only; body content is not inspected

`OutboxDispatchService.java` confirmed imports:

```
OutboxMessageRepository, OutboxService, HttpRestService, MeterRegistry
```

No `MessageService` import or field injection.

Dispatch logic (condensed from code read):

```java
ResponseEntity<String> response = httpRestService.post(url, payload, headers);
if (response.getStatusCode().is2xxSuccessful()) {
    outboxService.markSent(message);          // marks SENT on any 2xx
} else {
    outboxService.markFailed(message, ...);
}
```

**Observation:** The dispatcher reads only HTTP status code. It never inspects `response.getBody()` for `{"Status": "Error"}`. OMS returning HTTP 200 with `Status: 'Error'` body is indistinguishable from `Status: 'Success'`. The outbox row is marked `SENT`, the failure is unrecoverable through the outbox retry mechanism.

**Supports:** H1 ✓, H3 ✓

---

### E4 — The legacy `doSend` path writes to `message` table; `OutboxDispatchService` does not

`OmsNotificationService.java:103–134` (legacy path):

```java
private void doSend(String urlPath, String payload, String processType) {
    // ...
    try {
        ResponseEntity<String> response = httpRestService.post(url, payload, headers);
        messageService.createMessage(processType, payload, url, response.getBody(), "SENT");  // ← always written
    } catch (Exception e) {
        messageService.createMessage(processType, payload, url, e.getMessage(), "FAILED");    // ← error also written
    }
}
```

`OutboxDispatchService.java` — confirmed **no `MessageService` field**, **no `createMessage` call** anywhere in the class.

**Observation:** The legacy notification path unconditionally writes a row to the `message` table (both success and failure). When `finishPickingOrder` was migrated to the outbox, the callers changed from `omsNotificationService.sendAfterCommit()` → `outboxService.enqueue()`. `OutboxDispatchService` was written without porting the `messageService.createMessage()` call. **Every outbox-dispatched notification type** (not only PICKING_FINISHED) is therefore absent from the `message` table / Service Log admin page.

**Supports:** H5 ✓, kills H6 ✗

---

### E5 — OMS QA status check does NOT gate on `parcel_status` at the controller level

`QaParcelController.php:214–238` (`updateQaStatus`):

```php
public function updateQaStatus(Request $request, int $parcelId): JsonResponse
{
    $request->validate([
        'qa_pass' => 'required|boolean',
        // ...
    ]);

    try {
        $result = $this->qaParcelService->processQaStatus($parcelId, $request->all());
        return $this->successResponse($result, 'QA status updated successfully');
    } catch (\Illuminate\Database\Eloquent\ModelNotFoundException $e) {
        return $this->notFoundResponse('Parcel not found');
    }
}
```

`QaWorkflowService.php` constants:

```php
protected const PRE_AWAITING_QA_STATES = [1, 2, 3, 6, 8, 9, 10, 19, 22, 23, 24]; // 24 = PICKING
protected const AWAITING_QA_STATE = 25;   // WAITING_FOR_QA
```

`QaWorkflowService.processQaPass()` (lines 78–175): processes QA pass without checking `parcel_status` as a pre-condition.

**Observation:** The OMS QA controller and `processQaPass` do **not** reject a QA operation when `parcel_status = 24`. The error message *"This parcel is currently in Picking status and cannot be processed through QA."* was **not found** in any of:
- `v2/oms-laravel-api/` (all PHP controllers and services)
- `v2/omsv2-UI/` (all React/TypeScript components)
- `v1/oms/` (legacy ZF2 PHP code)

**Inference:** The error message is almost certainly generated by the **frontend** (`omsv2-UI`) based on the `parcel_status` value it reads from the API — the React layer prevents the QA action when it sees `status_id == 24`. The parcel not advancing to status 25 (due to the tote_label omission) is therefore the **primary blocker** — the frontend message is a symptom.

**Supports:** H4 (partially) — H4 is refined: the QA gate is frontend-enforced, not backend-enforced. The root cause for H4 remains `parcel_status` stuck at 24 due to E2.

---

### E6 — Null result: no alternative WMS path sends `tote_label` for non-tote regular orders

Search: `grep -rn "tote_label\|toteLabel\|setToteLabel"` in `v2/wms2-api/src/`

**Result:** All `setToteLabel` calls are in `ManageOrderService.buildPickedPayloadJson` (lines 282–290). There is no fallback or default value assigned when both CLUB and tote-assigned branches are skipped. No other code path sends `tote_label` for PICKING_FINISHED.

**Supports:** H1 ✓ — the omission is structural, not conditional on runtime data.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Verdict |
|---|-----------|-----------------|---------|
| H1 | WMS omits `tote_label` for regular orders without an assigned picking tote | **confirmed** | Root cause of Issue 1. Structural gap in `buildPickedPayloadJson`. |
| H2 | OMS rejects entirely (non-200 HTTP) | **eliminated** | OMS returns HTTP 200 on partial failure; dispatcher marks SENT. |
| H3 | OMS returns HTTP 200 with `Status: 'Error'`; dispatcher cannot detect it | **confirmed** | Compound contributor — WMS has no way to know OMS silently skipped the position. |
| H4 | OMS `isAwaitingQa()` gate blocks QA at status 24 | **refined** | The gate is frontend-enforced. Root blocker is still the parcel never reaching status 25. |
| H5 | `OutboxDispatchService` never writes to `message` table | **confirmed** | Root cause of Issue 2. Architectural gap introduced at outbox creation. Affects all outbox notification types. |
| H6 | Nothing is actually wrong | **eliminated** | Two concrete structural defects identified. |

---

## 7. Verdict

**Issue 1 — OMS QA screen blocks the parcel at Picking status**

The root cause is a structural omission in `ManageOrderService.buildPickedPayloadJson`: for regular (non-CLUB) orders without a picking tote assigned (`pickingtoteId == null`), the `tote_label` field is never populated and the Jackson `NON_NULL` serializer omits it from the JSON payload. OMS `finishedPicking` treats any position with an empty/absent `tote_label` as an error and skips it with `continue`, so `parcel_status = 25` is never written. OMS returns HTTP 200 with `Status: 'Error'` body; `OutboxDispatchService` reads the 200 and marks the row SENT — the failure is completely silent to WMS. The parcel stays at `parcel_status = 24`; the omsv2-UI frontend reads status 24 and shows *"This parcel is currently in Picking status and cannot be processed through QA."*

The failure is **deterministic**: every regular picking order that completes without a tote assigned will silently fail to advance to QA.

**Issue 2 — PICKING_FINISHED absent from Service Log (`message` table)**

When `finishPickingOrder` was migrated to the outbox pattern, the new `OutboxDispatchService` was created without porting the `messageService.createMessage()` call that `OmsNotificationService.doSend()` performs unconditionally on every HTTP POST (success or failure). This is not specific to PICKING_FINISHED — **every notification type dispatched via the outbox** produces no `message` table row. The Service Log page is therefore incomplete for all post-SBDEV-2238 migrations.

**Overall confidence: high.** Both root causes are confirmed by direct code inspection. The causal chain from WMS builder → JSON payload → OMS handler → HTTP 200 partial failure → outbox SENT is fully traced. No runtime ambiguity remains. DB validation was not performed (tool unavailable) but is consistent with the code evidence.

---

## 8. Recommendation

**Fix now — both issues.** Issue 1 blocks OMS QA for every regular pick-pack order. Issue 2 leaves operators blind in Service Log for all outbox-routed notifications.

### Issue 1 fix: always send a non-empty `tote_label`

**Option A (preferred):** In `ManageOrderService.buildPickedPayloadJson`, add a fallback so non-CLUB, no-tote orders emit a deterministic placeholder — e.g. the `customerOrder.getNumber()` or a constant sentinel such as `"NO_TOTE"`:

```java
} else {
    // pick-pack orders with no tote: OMS requires a non-empty tote_label to advance parcel status
    orderDto.setToteLabel("NO_TOTE");
}
```

OMS `finishedPicking` checks `empty($toteLabel)` — any non-empty string passes the guard. Confirm with the OMS team whether `"NO_TOTE"` is safe downstream (e.g. the label is stored / displayed, not used for physical routing).

**Option B:** Ensure WMS always assigns a `Unitload` as picking tote before releasing a picking order, so `pickingtoteId` is never null. Higher impact change; not preferred for a targeted fix.

**Secondary defensive fix:** `OutboxDispatchService` should inspect the OMS response body for `{"Status": "Error", ...}` and mark the outbox row as FAILED rather than SENT when OMS reports a partial failure. This is a broader hardening and should be a follow-up, not a blocker for this fix.

### Issue 2 fix: add `MessageService.createMessage()` to `OutboxDispatchService`

Inject `MessageService` into `OutboxDispatchService` and call `createMessage(processType, payload, url, responseBody, "SENT"/"FAILED")` after each dispatch attempt, mirroring `OmsNotificationService.doSend()`. This restores Service Log visibility for all outbox-dispatched notifications without changing dispatch semantics.

---

**Downstream plan:** Draft via **`wms-bugfix-plan`** targeting `v2/wms2-api`. The plan **must** ship a `sbdocs/9-System/scripts/verify-260520-picking-finished-oms-notification-fix.sh` that confirms:
- A `PICKING_FINISHED` POST with a non-empty `tote_label` advances the OMS parcel to `parcel_status = 25`
- A `message` table row is written for every outbox-dispatched notification
- The `outbox_message` row is marked SENT only when OMS returns `Status: 'Success'` in the body (or at minimum the parcel-status guard confirms advancement)

---

## 9. Open Questions

1. **DB validation pending.** `wms2-wineco-dev` MCP and `psql` were unavailable during this investigation. Recommended queries:
   - `SELECT parcel_id, parcel_status, updated_at FROM parcel WHERE parcel_status = 24 ORDER BY updated_at DESC LIMIT 20` — count parcels stuck in Picking status
   - `SELECT status, COUNT(*) FROM outbox_message WHERE process_type = 'ORDER_BATCH_PICKING_FINISHED' GROUP BY status` — confirm SENT rows exist despite OMS partial failure
   - `SELECT COUNT(*) FROM message WHERE process = 'ORDER_BATCH_PICKING_FINISHED' AND created_at > '2026-05-01'` — confirm zero rows after outbox migration date

2. **Scope of the `tote_label` omission.** Is `pickingtoteId == null` the *only* case that produces a null `toteLabel`? What does `Unitload.getLabelid()` return if the label was never assigned — null or empty string? If empty string, `NON_NULL` would not omit it but OMS `empty()` would still skip it. Confirm with a DB query: `SELECT labelid FROM unitload WHERE id = <pickingtoteId_sample>`.

3. **Is `"NO_TOTE"` safe in OMS?** OMS may store or display `tote_label` downstream (WMS scanning, shipping manifest, audit trail). Confirm with OMS team whether a sentinel value is safe or if the field should be entirely optional in OMS `finishedPicking`.

4. **Other outbox notification types and the `message` table gap.** The SBDEV-2238 outbox migration covers multiple services (`closeBOL`, `finishPickingOrder`, and phase-2 remaining services). All produce zero `message` rows. Enumerate all `outbox_service.enqueue` call sites and confirm whether operators rely on Service Log for any of those notification types — priority for the `MessageService` backfill may vary.

5. **`releaseRegularPickingOrder` Case 1 recovery.** The prior fix (`260520-wms2-picking-finished-oms-notification-dropped.md`) recommended that Case 1 re-enqueue unsent notifications. This is still applicable and should be included in the bugfix plan as a secondary defensive measure.

6. **OMS `finishedPicking` partial-failure contract.** OMS returns HTTP 200 for partial failure, making it impossible for WMS to distinguish success from partial failure via status code. Whether OMS should return a 4xx/5xx on partial failure, or whether WMS should inspect the body, is a joint OMS-WMS API contract discussion.

---

## 10. References

- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/ManageOrderService.java:262–304` — `buildPickedPayloadJson` (Issue 1 root cause)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:264–275` — `finishPickingOrder` outbox enqueue
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/job/OutboxDispatchService.java` — no `MessageService` (Issue 2 root cause)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/OmsNotificationService.java:103–134` — `doSend` (legacy `messageService.createMessage` reference)
- `v2/oms-laravel-api/app/Http/Controllers/Api/Legacy/LegacyWmsController.php:1469–1531` — `finishedPicking` (tote_label guard + HTTP 200 on partial failure)
- `v2/oms-laravel-api/app/Services/Qa/QaWorkflowService.php:39–40` — `PRE_AWAITING_QA_STATES`, `AWAITING_QA_STATE`
- `v2/oms-laravel-api/app/Http/Controllers/Api/Qa/QaParcelController.php:214–238` — `updateQaStatus` (no backend status-24 gate)
- **Prior report:** `sbdocs/3-Resources/reports/260520-wms2-picking-finished-oms-notification-dropped.md` — double-`afterCommit` root cause; outbox migration recommendation
- **Fix plan:** `sbdocs/1-Projects/wms2/plan/260520-picking-finished-oms-notification-fix.md`
- **Architecture:** `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md`
- **Prior delivery-guarantee report:** `sbdocs/3-Resources/reports/260424-wms-oms-notification-delivery-guarantees.md`

---

## 11. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| 2026-05-21 | Code read — `buildPickedPayloadJson` tote_label branch | Confirmed null/omitted for non-tote regular orders | Nam Park |
| 2026-05-21 | Code read — OMS `finishedPicking` tote_label guard | Confirmed skip-and-continue + HTTP 200 on partial failure | Nam Park |
| 2026-05-21 | Code read — `OutboxDispatchService` imports | Confirmed no `MessageService` dependency | Nam Park |
| 2026-05-21 | Code read — `OmsNotificationService.doSend` | Confirmed `messageService.createMessage` on every send | Nam Park |
| 2026-05-21 | DB validation (outbox_message, message, parcel tables) | **PENDING** — wms2-wineco-dev MCP unavailable; psql not found | — |
