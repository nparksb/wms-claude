---
title: "WMS → OMS Notification Delivery Guarantees — Analysis Report"
type: investigation
status: concluded
version: v1
scope: WMS v1 (wms-api) outbound HTTP notifications to OMS
owner: nam.park@siteboss.net
created: 2026-04-24
updated: 2026-04-24
last_verified: 2026-04-24
verified_by: nam.park@siteboss.net
related:
  - 260424-oms-notification-rollback-risk-remediation
  - 260424-runClubLine-transaction-boundary-hardening
  - OMS_Notification_Rollback_Risk_Audit
tags:
  - investigation
  - report
  - oms-notification
  - delivery-guarantee
  - distributed-systems
  - reliability
---

# WMS → OMS Notification Delivery Guarantees — Analysis Report

**Topic:** WMS v1 outbound notifications to OMS | **Version:** v1
**Started:** 2026-04-24 | **Investigator:** Nam Park
**Status:** concluded

---

## 1. Context & Trigger

WMS communicates state changes (SKU updates, order lifecycle events, advice receipts, BOL shipments, stock changes) to OMS via HTTP POSTs. These notifications drive OMS's view of WMS state — allocation, billing, customer-facing status pages, downstream-system handoffs.

This investigation was triggered by the audit `sbdocs/0-Inbox/OMS_Notification_Rollback_Risk_Audit.md` which flagged rollback-after-notify as one failure mode, and by the user's question:

> "Sending messages to OMS — is it guaranteed? If not, what's the issue and how to fix it?"

The remediation plans (`260424-runClubLine-transaction-boundary-hardening.md` and `260424-oms-notification-rollback-risk-remediation.md`) describe **what to fix**. This report describes **what's actually happening today and why** — the diagnostic foundation those plans rest on. It is intentionally diagnostic, not prescriptive.

---

## 2. Questions

1. What HTTP egress paths exist from WMS v1 to OMS, and what process types do they cover?
2. Under what conditions does a "WMS→OMS notification" reach OMS? Under what conditions does it **not**?
3. Is delivery **guaranteed** by the current architecture? If not, where are the gaps?
4. What evidence (Message rows, logs, metrics) does WMS leave behind in each failure mode?
5. What recovery mechanisms exist, and how complete are they?
6. What design decisions in the codebase suggest the original engineers anticipated these gaps?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence |
|---|-----------|---------------------|
| H1 | Delivery is at-least-once — the audit trail (`Message` table) and `resendMessage` admin path together cover all common failures. | medium |
| H2 | Delivery is at-most-once — OMS can be notified of state WMS later rolls back. | high |
| H3 | Delivery has no formal guarantee — partial-write and notify-and-crash windows exist with no audit trail. | high |
| H4 | The `Message` table schema reveals an intent to support automatic retry that was never implemented. | medium |

---

## 4. Method

- **Code read** — every site calling `httpRestService.post` or `httpRestService.get`. Every method on `MessageService`. The `Message` entity. Every `MessageProcessType` constant. The full `HttpRestService` implementation. The class-level and method-level `@Transactional` annotations on the 8 services that issue notifications.
- **Caller chain** — for each notification site, trace upward to confirm the active TX context and the post-POST work that could roll back the TX after OMS already accepted the notification.
- **Schema inspection** — `Message` model's columns, especially `version`, `resent`, `redeliverId`, `status`, `statuscodeanswer`. These reveal what was anticipated but not built.
- **Cross-validation** — confirmed claims against the existing audit document (`OMS_Notification_Rollback_Risk_Audit.md`) and against the implemented runClubLine fix (commit `f46cf06`).
- **Frontend dead-code probe** — `grep` of `wms-web-ui`, `wms-mobile-ui`, `oms` for any reference to dead-on-the-server code paths.

---

## 5. Evidence

### 5.1 The egress wrapper has one chokepoint

**Source:** `src/main/java/net/aim_ai/wms/service/HttpRestService.java:40-59`
**Observation:** A single class wraps all OMS HTTP traffic. Two methods — `post(url, message)` and `get(url)` — both:

- Declare `throws IOException` only.
- **Do not throw on HTTP 4xx/5xx** — the response status is returned in a `Map<String,String>` under key `"code"`.
- Use RESTEasy with **5s connect timeout, 15s read timeout** (lines 87-88).

The HTTP client is created fresh on every call (no pool), so connect-time DNS or TLS failures can't be amortized.

**Supports:** H2 (at-most-once), H3 (no formal guarantee).

### 5.2 RESTEasy timeouts raise unchecked `ProcessingException`

**Source:** `javax.ws.rs.ProcessingException` is a `RuntimeException`. Confirmed by JAX-RS spec; `HttpRestService.post`'s signature does not declare it.
**Observation:** When OMS does not respond within 15s (read timeout) or the TLS/connect handshake exceeds 5s, RESTEasy throws `ProcessingException`. **None** of the `catch (IOException e)` blocks scattered across `ManageOrderService`, `MessageService`, `AdviceService`, `BillofladingService`, or `CustomerorderBatchService.cancelBatch` catch it. It propagates as an unchecked exception out of the calling method.

For methods running inside `@Transactional`, this triggers Spring's default rollback. **OMS may already have accepted the request** (the timeout is a read timeout, meaning the request was sent and we're waiting for the response), but the WMS state change is reverted.

**Supports:** H2.

### 5.3 The `Message` table is the only durable artifact of an OMS call

**Source:** `src/main/java/net/aim_ai/wms/model/Message.java`
**Observation:** Each `httpRestService.post` is paired with a `MessageService.createMessage(...)` call that persists a row containing:

- `id`, `number` (audit identifier)
- `created`, `modified`
- `version` (`@Version` — optimistic locking on the row itself)
- `sender`, `receiver`, `destination` (URL), `message` (payload, `text` column), `answer` (response body, `text`)
- `process` (one of 26 `MessageProcessType` constants)
- `status` (one of 7 `MessageStatus` constants — but only 2 are used in practice; see §5.5)
- `statuscodeanswer` (HTTP status code as string)
- `clientId`, `operatorId`
- **`resent` (Boolean, default false)**, **`redeliverId` (Long, nullable)** — see §5.4

The Message row is **the only artifact** that records an attempted OMS call after the call returns. There is no separate event log, no metric, no queue.

**Supports:** H1 (audit trail exists), H4 (resent/redeliverId hint at intended retry).

### 5.4 `Message.resent` and `Message.redeliverId` reveal an intent to retry that was only half-built

**Source:** `Message.java:63,73`; `MessageService.resendMessage:132-167`
**Observation:** The `Message` entity has a `resent` boolean and a `redeliverId` foreign key. The `resendMessage(originalMessageFromDB)` method, when invoked on a `FAILED` Message row, makes a fresh POST and creates a NEW Message row with `resent=true` and `redeliverId=originalMessage.id`. Each resend is a new row; the original is never modified.

This is exactly the schema you would design for a redelivery audit trail. **But there is no scheduled job that calls `resendMessage`.** Confirmed by:

```
$ grep -rn "@Scheduled" src/main/java/net/aim_ai/wms/schedulejob
# no result that targets the message table
```

The only invocations of `resendMessage` are admin-triggered (e.g., a "Resend" button in the admin UI). An operator must manually click each `FAILED` row to re-attempt. There is no exponential backoff, no retry budget, no DLQ.

**Supports:** H4. Strongly suggests the original design intended automatic retry; the field was added but the poller never shipped.

### 5.5 `MessageStatus` defines 7 states; only 2 are used in flight

**Source:** `WmsConstants.java:460-472`; egrep across all `messageRepository.save(...)` and `createMessage(...)` calls.
**Observation:** Constants defined: `CREATED`, `ON_HOLD`, `RELEASED`, `SENT`, `FAILED`, `RECEIVED`, `ARCHIVED`. In practice:

- `CREATED` — written ONLY by the no-status overload of `MessageService.createMessage` (line 49) which is never called from a notification path. It's a dead default.
- `SENT` — used everywhere on success.
- `FAILED` — used everywhere on `IOException` catch blocks.
- `RECEIVED` — used by inbound REST endpoints to log incoming messages from OMS, not outbound.
- `ON_HOLD`, `RELEASED`, `ARCHIVED` — defined but **no writer** exists in the codebase.

Three unused states + `redeliverId` + `resent` is unmistakably the skeleton of a state-machine outbox. Only the terminal states (`SENT`/`FAILED`) and the audit fields are wired up.

**Supports:** H4.

### 5.6 Some sites correctly defer the POST to `afterCommit`; most do not

**Source:** `PickingorderBusinessService.finishPickingOrder:147-169`, `confirmPick:329-341`, `MobilePickingService.processPick:438-450`, and (post-2026-04-24) `CustomerorderBatchService.runClubLine:738-755` (commit `f46cf06`).
**Observation:** Four sites in production use `TransactionSynchronizationManager.registerSynchronization(...).afterCommit(...)` correctly:

- `PickingorderBusinessService.finishPickingOrder` (primary branch)
- `PickingorderBusinessService.confirmPick`
- `MobilePickingService.processPick`
- `CustomerorderBatchService.runClubLine` (added by F1 of the runClubLine plan; deferred but inside the SAME transactional unit, so still subject to JVM crash between commit and callback)

In these sites:
- Rollback of the surrounding TX silently drops the registered callback — **delivery does NOT happen on rollback**.
- A `ProcessingException` inside the callback is caught by an explicit `catch (Exception)` — does NOT roll back (TX is already committed).
- A JVM crash between commit and callback DOES drop the notification — no Message row written, no audit.

**18+ other sites** call `httpRestService.post` directly inside the active transaction, with material work that can fail after the POST. These sites are at-most-once: rollback after the POST has already been accepted by OMS leaves WMS in the prior state.

**Supports:** H2, H3.

### 5.7 The 26 `MessageProcessType` constants represent every WMS→OMS contract

**Source:** `WmsConstants.java:424-455`
**Observation:** Inventory of declared process types. Grouped by concern:

| Category | Process types | Direction |
|---|---|---|
| SKU master data | `SKU_IMPORT`, `SKU_UPDATE` | WMS → OMS |
| Inbound advice lifecycle | `ADVICE_IMPORT`, `ADVICE_CLOSE`, `ADVICE_TRANSFER_IMPORT`, `ADVICE_HUB_AND_SPOKE_IMPORT`, `ADVICE_HUB_AND_SPOKE_RECEIVED`, `ADVICE_ACCEPT_TRANSFER` | WMS → OMS (or vice versa) |
| Outbound order batch lifecycle | `ORDER_BATCH_IMPORT`, `ORDER_BATCH_UPDATE_PRIORITY`, `ORDER_BATCH_ON_HOLD`, `ORDER_BATCH_CANCELLED_FROM_PSD`, `ORDER_BATCH_CANCELLED_FROM_WMS`, `ORDER_BATCH_PICKING_RELEASED`, `ORDER_BATCH_PICKING_TOTE_ASSIGNED`, `ORDER_BATCH_PICKING_STARTED`, `ORDER_BATCH_PICKING_FINISHED`, `ORDER_BATCH_QA_FINISHED`, `ORDER_BATCH_SHIPPED`, `ORDER_BATCH_FINISHED_TRANSFER` | WMS → OMS |
| Stock | `INVENTORY_FULL_EXPORT`, `STOCK_UPDATE` | WMS → OMS |
| Diagnostics | `TEST_CRM_CONNECTIVITY`, `UNDEFINED` | both |
| Reports | `REPORT_TRANSACTION_SUMMARISED`, `REPORT_TRANSACTION_DETAILED` | WMS → OMS (likely scheduled) |

**Counting outbound POSTs (verified by `grep "httpRestService.post"`)**:

- 6 sites in `ManageOrderService` (one per outbound order-batch lifecycle event)
- 3 sites in `AdviceService`
- 1 site in `BillofladingService` (`closeBOL`)
- 1 site in `CustomerorderBatchService` (`cancelBatch`)
- 1 site in `CustomerorderService` (`cancelOrder`)
- 1 site in `MessageService` (`sendStockChangeMessage` — fans out to 9 callers across `StockunitService`, `UnitloadService`, `GoodsReceiptPositionService`)
- 1 site in `MessageService` (`resendMessage` — admin-only)
- 1 site in `StockSummaryExportJob` (cron)
- 1 site in `ItemDataController` (admin SKU push)
- 1 site in `MessageDummyController` (developer-only)
- 1 dead/commented site in `BillofladingService` (line 792)

≈ **18+ live outbound POST sites** + 1 `httpRestService.get` in `BillofladingService.getFacilities` (read-only).

**Supports:** H3 — the surface area is wide enough that ad-hoc per-site remediation will leave gaps.

### 5.8 OMS-side idempotency is not implemented (no key in the payload)

**Source:** Inspection of payload builders in `ManageOrderService.createOrderBatch` (line 346), `customerOrderPicked`, `cancelBatch`'s `OrderBatchDto` construction, and `ManageOrderService.assignClubHistoryTotes` (the new method post-F1).
**Observation:** The DTO payloads include `facilityCode`, `batchId`, the order's `externalnumber`/`uniqueId`, `toteLabel`, `parcelExternalNumber`. There is no idempotency key in the wire format — OMS receives the same `batchId` + `process` combination on every retry without a stable per-attempt identifier.

This means: even if WMS deduplicated retries on its side, OMS cannot independently reject duplicates. A retry from WMS that lands at OMS is observationally indistinguishable from a fresh notification.

**Supports:** H2 — at-most-once is the actual contract because at-least-once would produce duplicates OMS cannot reject.

### 5.9 No JVM-crash recovery exists for in-flight notifications

**Source:** `grep` for any startup hook that scans `Message WHERE status='CREATED' OR status='ON_HOLD'`. None found.
**Observation:** Every notification path either:

1. Synchronously POSTs and writes the Message row in one transaction (or one auto-commit sequence), so a crash mid-call leaves nothing recorded — neither WMS state nor OMS state.
2. Uses `afterCommit`, where a crash between commit and callback drops the registration silently — no Message row, no signal.

There is no `@PostConstruct` retry sweep, no startup outbox-replay, no in-flight tracking. A WMS pod restart in the middle of a busy operator session can lose OMS notifications without trace.

**Supports:** H3.

### 5.10 The `httpRestService.get` paths are mostly safe but one is interesting

**Source:** `BillofladingService.getFacilities:1169` (GET); `AdminActionController:127` (GET); read-only sites.
**Observation:** GET paths read OMS data into WMS — they don't change OMS state. A failure simply returns an empty/error response to the WMS caller. **No delivery-guarantee concern.**

`BillofladingService.getFacilities` is wrapped in the class-level `@Transactional` but performs only reads; rollback has no effect. **Safe.**

**Supports:** No bearing on H1-H4 except confirming the scope is only POSTs.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H1 | Delivery is at-least-once via Message audit + `resendMessage` | **rejected** — confidence low | §5.4: no scheduled poller; manual operator action only. §5.6: 18+ sites can rollback after notify, leaving SENT row + reverted WMS state. |
| H2 | Delivery is at-most-once (rollback-after-notify is real) | **confirmed** — confidence high | §5.2: ProcessingException uncaught. §5.6: 18+ at-risk sites. §5.8: no OMS-side dedup. |
| H3 | Delivery has no formal guarantee in some windows | **confirmed** — confidence high | §5.7: 18+ sites. §5.9: crash-window has no audit trail. §5.6: rollback paths drop afterCommit registrations silently. |
| H4 | Schema reveals intended-but-unbuilt automatic retry | **confirmed** — confidence high | §5.3-5.5: `resent`, `redeliverId`, `ON_HOLD`/`RELEASED`/`ARCHIVED` defined but never written by any code path. |

---

## 7. Findings

### 7.1 Headline answer: delivery is **NOT guaranteed**

WMS today provides:

- **At-most-once** delivery for the 18+ sites that POST inside an active TX — OMS may be notified of state WMS later rolls back. Manual reconciliation required.
- **Best-effort** delivery for the ~4 sites already using `afterCommit` (only fires if TX commits) — but no guarantee against crash-window or OMS-outage.
- **No automatic retry** — `FAILED` Message rows accumulate indefinitely without action; only an admin can resend, one row at a time.
- **No idempotency** — OMS cannot dedupe retries; clean recovery requires WMS to know exactly which messages OMS already accepted, which is not knowable from WMS-side data alone.
- **No crash-window protection** — JVM restart mid-call leaves nothing recorded if the call hadn't committed yet.

### 7.2 Failure-mode catalog

For each plausible failure, what happens today:

| # | Failure | OMS state | WMS state | Audit trail | Recovery |
|---|---|---|---|---|---|
| F1 | OMS down (connection refused) | not changed | TX commits if POST is the last op; otherwise depends | `FAILED` row written | manual `resendMessage` |
| F2 | OMS slow (>15s read timeout) | **may be partially processed** | TX rolls back if POST is mid-method | NO row (ProcessingException uncaught) | none — silent loss |
| F3 | OMS returns 500 | **may be partially processed** | TX commits (no exception thrown) | `SENT` row with code=500 | manual `resendMessage` |
| F4 | OMS returns 200, then WMS rolls back (rollback-after-notify) | committed | reverted | `SENT` row with code=200 | **manual reconciliation only**; clicking the UI again duplicates |
| F5 | JVM crash mid-POST | unknown — depends on whether bytes reached OMS | TX rolls back on restart | NO row | none |
| F6 | JVM crash between TX commit and `afterCommit` callback (the 4 fixed sites) | not notified | committed | NO row | none |
| F7 | Network partition mid-call | unknown | rolls back as F2 | NO row | none |
| F8 | DB constraint violation persisting Message row after successful POST | committed | TX rolls back, WMS state lost | NO row (Message also rolled back) | none |
| F9 | Operator clicks "Resend" twice | OMS sees 2 events for same `batchId` | unchanged | TWO `SENT` rows with `resent=true` | none — duplicate already in OMS |

**Observability gap:** F2, F5, F6, F7, F8 leave NO trace in the Message table. There is no way to detect them post-hoc except by reconciliation against OMS.

### 7.3 What WMS does well

- **Audit trail for happy paths** — `Message` rows record every successful POST with payload, response, status code, operator. SQL forensics on declared process types is straightforward.
- **Some sites correctly defer to `afterCommit`** — picking-order pipeline + the recently-fixed runClubLine.
- **`OptimisticLockRetryTemplate`** is a good pattern that already exists; it is referenced by the runClubLine plan as the model for a future `OmsNotificationHelper`.
- **Process-type taxonomy is well-defined** — 26 constants cover the contract space; not ad-hoc strings.
- **Schema includes redelivery affordances** — `resent` and `redeliverId` fields already exist; an automatic poller can be wired up without a migration.

### 7.4 What's missing (root causes of the gaps)

1. **No transactional outbox.** All notifications are sent to OMS by the same thread that owns the WMS transaction. The `Message` row is written in the same transaction OR right after it, never as a pre-commit "intent to send" record that an independent worker could replay.
2. **No automatic retry sweeper.** `resendMessage` is the exact verb a poller would use, but no `@Scheduled` task invokes it. An OMS outage of any duration produces a growing `FAILED` table that requires human triage.
3. **No idempotency contract with OMS.** Even if WMS started retrying automatically, OMS would receive duplicates with no key to dedupe by. This is a cross-system coordination problem requiring an OMS API change.
4. **`ProcessingException` not caught.** Every `catch (IOException)` block is a near-miss for the most common transient failure (timeout). Either the catch should be broadened or the root method's `throws` clause should declare `ProcessingException` so the compiler enforces handling.
5. **18+ rollback-after-notify sites.** Documented in `260424-oms-notification-rollback-risk-remediation.md`. Each one independently violates the "WMS state must reflect what OMS was told" invariant.
6. **No crash-window protection.** Even the correct `afterCommit` sites lose notifications if the JVM dies between commit and callback. Spring's TX synchronization is in-memory.
7. **No observability beyond the Message table.** No counters for `oms_notification_failures_total{process,site}`, no gauge for `oms_message_pending_resend`, no alert when failure rate spikes.

### 7.5 Why the audit missed sites the code review surfaced

The audit (`OMS_Notification_Rollback_Risk_Audit.md`) inventoried `manageOrderService.*` calls and `httpRestService.post` direct calls. It missed:

- **`MessageService.sendStockChangeMessage`** — the STOCK_UPDATE egress, called from 9 places across `StockunitService`, `UnitloadService`, `GoodsReceiptPositionService`. Same `IOException`-only catch, same rollback-after-notify shape. (See `260424-oms-notification-rollback-risk-remediation.md` revision 2 §2.2 for the deep-dive findings S11-S13.)
- **`OrderMonitorViewService.reprintToteLabels`** — sibling of `printToteLabels` with the same `cupsPrint` rollback gap (S14).

Audit completeness is itself a hypothesis — we should expect future reviews of unrelated code paths to surface additional egress sites.

---

## 8. Verdict

**Q: Is sending messages to OMS guaranteed?**

**A: No.** Today's architecture provides **at-most-once** delivery for most call sites, **best-effort** for the four `afterCommit`-correct sites, and has multiple windows where notifications are silently lost (timeout, JVM crash, post-commit failure). The Message audit trail exists for happy paths and admin-triggered retries but cannot detect or recover from silent-loss windows.

**Implication for ops:** when the team observes "OMS says X, WMS says Y" desync, the cause is one of F1-F9 in §7.2. The Message table is sufficient to diagnose F1, F3, F4, and F9 (the rows are present). F2, F5, F6, F7, F8 require out-of-band reconciliation against OMS to detect.

**Implication for engineering:** the gap between today's behavior and a guaranteed at-least-once contract is achievable in three increments:
- **Short-term (weeks):** afterCommit migration of the 18+ sites — closes rollback-after-notify class. Already planned (`260424-oms-notification-rollback-risk-remediation.md`).
- **Medium-term (1-2 weeks):** Scheduled FAILED-resender — closes OMS-outage class for sites that produce `FAILED` rows. Achievable with one Flyway migration + one new constant + one new scheduled job.
- **Long-term (separate plan):** Transactional outbox — closes crash-window class. Requires schema change, OMS-side idempotency, and the migration of every notification site to enqueue-instead-of-POST. This is the "once-for-all" fix referenced in the audit's option 3.

---

## 9. Recommendations (verdicts)

| # | Recommendation | Verdict | Reason |
|---|---|---|---|
| R1 | Continue execution of `260424-runClubLine-transaction-boundary-hardening.md` (already at status `implemented-pending-review`) | **fix now** | Highest-volume amplification site; up to 15× duplicate events per Club run before fix. F1-F7 implemented in `f46cf06`. |
| R2 | Execute `260424-oms-notification-rollback-risk-remediation.md` Phase 1 (afterCommit migration of 18+ sites) | **fix soon** | Closes the at-most-once → best-effort gap. Single biggest improvement per engineer-week. |
| R3 | Bundle Phase 2a (FAILED-resender daemon) into the `260424-oms-notification-rollback-risk-remediation` ship train | **fix soon** | 1-2 days of work; closes OMS-outage class. Re-uses existing `MessageService.resendMessage`. The plan already concretizes this. |
| R4 | Broaden the `IOException` catch to `Exception` (or specifically include `ProcessingException`) at every notification site | **fix soon (bundle with R2)** | Single most common transient failure (timeout) is currently dropping silently with no Message row. Fixing once via the proposed `OmsNotificationHelper` covers all sites. |
| R5 | Add observability: Prometheus counter `oms_notification_failures_total{process,site,reason}` and gauge `oms_message_pending_resend{process}` | **fix soon (bundle with R2)** | Today the only signal is the Message table. Counters/gauges turn this into actionable alerting. The proposed `OmsNotificationHelper` is a single instrumentation seam. |
| R6 | Coordinate with OMS team on idempotency-key contract before scoping Phase 2b | **investigate further** | Phase 2b transactional outbox is at-least-once; OMS must dedupe to prevent operator-visible duplicates. Unknown today whether OMS supports this. |
| R7 | Phase 2b — full transactional outbox with `oms_outbox` lifecycle states, `OmsOutboxService.enqueue`, scheduled deliverer | **fix later** (separate plan) | Closes the crash-window class. Higher implementation cost; depends on R6. Sketched in `260424-oms-notification-rollback-risk-remediation.md` §3.14. |
| R8 | Delete dead code `MobilePickingService.rapidPickingScanPackageAndType` + `rapidPickingConnectPackageAndType` and the commented controller block | **fix now (low cost)** | Dead-code claim verified across all frontends. Removes a latent defect that would manifest the moment the controller is uncommented. |
| R9 | Don't re-architect the Message table schema | **do not fix** | The existing `resent`, `redeliverId`, `version` fields plus the unused `ON_HOLD`/`RELEASED`/`ARCHIVED` constants are sufficient for Phase 2a and a substantial part of Phase 2b. Avoid scope creep into renames. |
| R10 | Document this report at `sbdocs/3-Resources/reports/` and link from the runbook | **fix now** | This report itself; ensures ops has a single page to consult during incident triage. (Done — you're reading it.) |

---

## 10. Operational reference: how to read the Message table during an incident

For any suspected WMS↔OMS desync, run:

```sql
-- All messages for an entity in the last 24h
SELECT id, process, status, statuscodeanswer,
       LENGTH(message) AS payload_bytes, resent, redeliver_id, created
FROM   message
WHERE  message LIKE '%<ENTITY-IDENTIFIER>%'
  AND  created > now() - interval '24 hours'
ORDER  BY created DESC
LIMIT  50;
```

Interpret:

| You see | Likely failure | Action |
|---|---|---|
| `status=SENT, statuscodeanswer=200`, but WMS state is pre-notification | F4 rollback-after-notify | Manual reconciliation. **Do NOT click the UI action again.** |
| `status=SENT, statuscodeanswer=500` | F3 OMS error | Verify OMS state; click admin `resendMessage` once OMS is healthy. |
| `status=FAILED, statuscodeanswer=503` | F1 OMS unreachable | OMS outage; admin `resendMessage` once recovered. |
| No row at all, but WMS state suggests a notification should have fired | F2/F5/F6/F7/F8 silent loss | Cannot diagnose from WMS data alone. Reconcile against OMS. |
| `resent=true, redeliver_id=<id>` row alongside an original `FAILED` row | Operator already retried | Confirm result of retry before further action. |

For STOCK_UPDATE specifically (no entity-number to grep on), filter by process type:

```sql
SELECT id, process, status, statuscodeanswer, created, message
FROM   message
WHERE  process = 'STOCK_UPDATE'
  AND  created > now() - interval '1 hour'
  AND  status = 'FAILED'
ORDER  BY created DESC
LIMIT  100;
```

---

## 11. Next steps for the reader

1. **Validate the verdict** — does the conclusion "delivery is not guaranteed" match operator experience? Specifically, confirm with ops whether F2/F5/F6 silent-loss windows have been observed (or suspected) in the field.
2. **Decide R6** — open a conversation with the OMS team about idempotency-key support. The answer gates whether Phase 2b is feasible.
3. **Schedule R2 + R3 + R4 + R5** as the next ship train. The `260424-oms-notification-rollback-risk-remediation.md` plan is the implementation scope; it has already been re-validated to revision 2.
4. **Quarterly review** — after R2-R5 ship, measure incident rate over a quarter to decide if Phase 2b (R7) is worth the engineering cost.

---

## 12. References

### Code citations (validated 2026-04-24, develop @ `f46cf06`)

- **HTTP egress wrapper:** `src/main/java/net/aim_ai/wms/service/HttpRestService.java:40-105`
- **Message audit entity:** `src/main/java/net/aim_ai/wms/model/Message.java`
- **Audit-trail writer:** `src/main/java/net/aim_ai/wms/service/MessageService.java:53-89`
- **Manual resend:** `src/main/java/net/aim_ai/wms/service/MessageService.java:132-167`
- **Process-type taxonomy:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java:418-455`
- **Status taxonomy:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java:457-472`
- **Reference afterCommit implementations (already in production):**
  - `PickingorderBusinessService.finishPickingOrder:147-169`
  - `PickingorderBusinessService.confirmPick:329-341`
  - `MobilePickingService.processPick:438-450`
  - `CustomerorderBatchService.runClubLine:738-755` (post-F1, commit `f46cf06`)
- **Outbound POST sites (18+):** see `260424-oms-notification-rollback-risk-remediation.md` §2.1 + §2.2 for the full enumeration; this report cites the count, not the per-site detail.

### Companion documents

- **Source audit:** `sbdocs/0-Inbox/OMS_Notification_Rollback_Risk_Audit.md` — the trigger for this work.
- **Sibling fix plan:** `sbdocs/1-Projects/wms1/plan/260424-oms-notification-rollback-risk-remediation.md` — what to do (revision 2).
- **Implemented fix plan:** `sbdocs/1-Projects/wms1/plan/260424-runClubLine-transaction-boundary-hardening.md` — F1-F7 shipped in `f46cf06`.

### Related incidents and observations

- Prior fix `dee2e0f` (`changeReservedAmount` StaleObjectStateException) — adjacent concurrency class; also produces 500s under contention. Fixed via cherry-pick from release-hotfix-260422.
- Prior fix `90ef812` (stale tote scan must not null `pickingtote_id` of in-flight PICKED order) — adjacent state-corruption class.

### Methodology references

- `wms-investigation-report` skill — template at `sbdocs/9-System/templates/wms-investigation-report-template.md`.
- Pattern source for the proposed `OmsNotificationHelper` utility: `OptimisticLockRetryTemplate.java:19-56` (functional-interface utility, already in production).
