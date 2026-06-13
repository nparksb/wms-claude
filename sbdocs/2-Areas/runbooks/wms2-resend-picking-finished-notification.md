---
title: "Runbook: Resend a Dropped ORDER_BATCH_PICKING_FINISHED Notification (WMS v2)"
type: runbook
status: active
version: "wms2-api (Java 21, Spring Boot 3.x, PostgreSQL)"
scope: "v2/wms2-api → OMS v2 — picking-finished notification delivery"
owner: "nam.park@siteboss.net"
created: "2026-05-20"
updated: "2026-05-20"
last_verified: "2026-05-20"
verified_by: "nam.park@siteboss.net"
alert: "OMS reports 'No Parcel Found' after picking / QA does not trigger after picker releases order"
severity: "SEV2"
escalation: "WMS on-call engineer → OMS on-call (for batch_criteria / parcel lookup)"
related:
  - "[[260520-wms2-picking-finished-oms-notification-dropped]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
tags:
  - runbook
  - wms2
  - oms-notification
  - picking
  - data-repair
---

# Runbook: Resend a Dropped ORDER_BATCH_PICKING_FINISHED Notification (WMS v2)

**Alert:** OMS reports "No Parcel Found" after picking, or QA does not trigger | **Severity:** SEV2  
**Scope:** `v2/wms2-api` — `releasePickingOrder` → OMS `finishedPicking` notification  
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-05-20 (nam.park)

---

## 1. When to Use This Runbook

- OMS reports "No Parcel Found" for a tote after a picker completes picking and presses **Release**.
- OMS QA flow does not trigger after a picking order is finished.
- OMS parcel is stuck in status **Processing (3)** and never transitions to **Waiting for QA (25)**.

**Known root cause (as of 2026-05-20):** A double `afterCommit` registration bug in
`PickingorderBusinessService.finishPickingOrder` causes the OMS HTTP POST to be silently
discarded by Spring on every pick completed via the `rapidPickingScanSource` (high-priority pick)
path. Full analysis: `[[260520-wms2-picking-finished-oms-notification-dropped]]`.

**Do NOT use this runbook if:**
- The picking order is not yet in state FINISHED (700) — the drop has not occurred yet.
- `pickingconfirmationsent` is `false` on the customer order — the code path was not entered
  (e.g., `isProduction()` returned false; investigate the WMS instance config instead).

---

## 2. Severity & Impact

| Aspect | Detail |
|--------|--------|
| User impact | OMS QA blocked — parcel stuck at picker's station. Order cannot be palletized or shipped. |
| Blast radius | One picking order at a time. Each affected customer order needs its own notification. |
| Is it a paging event? | Yes if picked orders are queuing up — escalate to SEV1 if >5 orders affected. |
| Recurrence | **Systemic** — every order finished via `rapidPickingScanSource` is affected. A permanent fix (outbox migration) is the correct resolution; this runbook is the interim recovery. |

---

## 3. First 5 Minutes — Triage

- [ ] Get the **picking order id** (from WMS logs or the mobile UI, e.g. `29506341`).
- [ ] Get the **tote label(s)** reported as missing by OMS (e.g. `T-2168`).
- [ ] Identify the **tenant** and **facility** (`tenant_name` / `facility_code` HTTP headers).
- [ ] Connect to the correct **wms2 tenant DB** (read-only first).

---

## 4. Diagnosis — Confirm the Notification Was Dropped

Run against the WMS v2 tenant DB. Replace `:picking_order_id` with the numeric PO id.

### 4.1 Confirm picking order is FINISHED and orders have the flag set

```sql
SELECT
    po.id            AS picking_order_id,
    po.number        AS picking_order_number,
    po.state         AS po_state,           -- expect 700 (FINISHED)
    co.id            AS customer_order_id,
    co.number        AS co_number,
    co.externalnumber,
    co.state         AS co_state,           -- expect 600 (PICKED)
    co.pickingconfirmationsent,             -- expect TRUE (flag was set, notification attempted)
    co.pickingtote_id,
    ul.labelid       AS tote_label,
    cob.batchid      AS batch_id,           -- the value to send as batch_id to OMS
    cob.number       AS batch_number
FROM pickingorder po
JOIN pickingorder_position pop ON pop.pickingorder_id = po.id
JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
JOIN customerorder co ON co.id = cop.order_id
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
LEFT JOIN unitload ul ON ul.id = co.pickingtote_id
WHERE po.id = :picking_order_id;
```

**Expected for a dropped notification:**
- `po_state = 700` (FINISHED)
- `pickingconfirmationsent = TRUE` — flag committed, proves `finishPickingOrder` ran
- `co_state = 600` (PICKED)

### 4.2 Confirm no message or outbox row was created

```sql
-- Should return zero rows for a dropped notification
SELECT id, process, status, created
FROM message
WHERE process = 'ORDER_BATCH_PICKING_FINISHED'
  AND (message LIKE '%' || (
        SELECT externalnumber FROM customerorder co
        JOIN customerorder_position cop ON cop.order_id = co.id
        JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
        WHERE pop.pickingorder_id = :picking_order_id LIMIT 1
      ) || '%')
ORDER BY created DESC LIMIT 5;

SELECT id, process_type, status, created_at
FROM outbox_message
WHERE process_type = 'ORDER_BATCH_PICKING_FINISHED'
ORDER BY created_at DESC LIMIT 5;
```

**If `message` table has a row** with `status = SENT` → the notification **was** delivered;
investigate why OMS did not process it. This runbook does not apply.

### 4.3 Collect payload values for all affected customer orders

Run this for each customer order linked to the picking order. Save the output — you need it in §5.

```sql
SELECT
    co.id                AS customer_order_id,
    co.externalnumber    AS unique_id,        -- used as unique_id in OMS payload
    co.orderbatch_id,
    cob.batchid          AS batch_id,         -- used as batch_id in OMS payload
    ul.labelid           AS tote_label,       -- used as tote_label in OMS payload
    (SELECT sysvalue FROM los_sysprop WHERE syskey = 'MULTIWAREHOUSE_IDENTIFIER')
                         AS facility_code,
    (SELECT sysvalue FROM los_sysprop WHERE syskey = 'WEBSERVICE_ORDER_BATCH_FINISHED_PICKING')
                         AS oms_url,
    (SELECT sysvalue FROM los_sysprop WHERE syskey = 'OMS_TENANT_ID')
                         AS oms_tenant,
    (SELECT sysvalue FROM los_sysprop WHERE syskey = 'OMS_API_USER')
                         AS oms_credentials   -- format: "user/password"
FROM customerorder co
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
LEFT JOIN unitload ul ON ul.id = co.pickingtote_id
JOIN customerorder_position cop ON cop.order_id = co.id
JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
WHERE pop.pickingorder_id = :picking_order_id
  AND co.state <> 800   -- exclude cancelled
GROUP BY co.id, co.externalnumber, co.orderbatch_id, cob.batchid, ul.labelid;
```

> **Important:** `finishPickingOrder` calls `customerOrderPicked(singletonList(order))` — one
> customer order at a time. Each customer order in the picking order may belong to a **different
> order batch** and needs its own separate POST to OMS.
> Code ref: `PickingorderBusinessService.java:265`

---

## 5. Recovery — Resend the Notification

For **each customer order** from §4.3, send one POST to OMS. The three possible OMS responses
and their remedies are documented in §5.1–5.3.

### 5.1 Build and send the curl

Substitute values from §4.3. Split `oms_credentials` on `/` for `-u user:password`.

```bash
# One call per customer order / batch pair
curl -s -X POST "<oms_url>" \
  -H "Content-Type: application/json" \
  -H "x-tenant: <oms_tenant>" \
  -u "<user>:<password>" \
  -d '{
    "facility_code": "<facility_code>",
    "batch_id":      "<batch_id>",
    "positions": [
      {
        "unique_id":  "<unique_id>",
        "tote_label": "<tote_label>"
      }
    ]
  }'
```

**Example (from 2026-05-20 incident):**
```bash
curl -s -X POST https://api-oms.dev.sbo.li/services/call/finishedPicking \
  -H "Content-Type: application/json" \
  -H "x-tenant: wineco" \
  -u "api_user:apiUser@sb" \
  -d '{"facility_code":"WSL","batch_id":"19e47f28309","positions":[{"unique_id":"563720","tote_label":"T-2169"}]}'
```

**Success response:**
```json
{"status":"success","message":"All parcels marked as ready for QA","data":{"Status":"Success",...,"processed":1}}
```
→ Proceed to §6 (verification).

---

### 5.2 OMS responds: `"Invalid batch: <batch_id>"`

OMS cannot find a `batch_criteria` row with `batch_label = '<batch_id>'`.

**Most likely causes:**
- The batch was imported weeks/months ago and `batch_label` was NULL at creation
  (older OMS code path did not always set `batch_label`).
- The `batch_criteria` row was soft-deleted or cleaned up in dev.

**Remediation — ask the OMS team to run on the OMS MySQL tenant DB:**

```sql
-- Step 1: find the batch_criteria row via the parcel
SELECT bc.batch_criteria_id, bc.batch_label, bc.batch_name, bc.batch_status, bc.isactive
FROM batch_criteria bc
JOIN parcel p ON p.batch_criteria_id = bc.batch_criteria_id
WHERE p.parcel_id        = <unique_id>    -- if OMS parcel_id matches WMS externalnumber
   OR p.parcel_id_str    = '<unique_id>'  -- if the parcel uses a string identifier
LIMIT 5;

-- Step 2: if the row exists with batch_label IS NULL, stamp it
UPDATE batch_criteria
SET batch_label = '<batch_id>'           -- the WMS batchid value
WHERE batch_criteria_id = <id_from_above>
  AND batch_label IS NULL;
```

Then retry the curl from §5.1.

---

### 5.3 OMS responds: `"<unique_id> not found in PSD"` (or parcel_id does not exist)

OMS cannot find a `parcel` row with `parcel_id = <unique_id>` (or `parcel_id_str = <unique_id>`).

**Most likely causes:**
- The batch was originally created via the legacy v1/Zend OMS path, which used a different
  identifier scheme. `unique_id` (= `customerorder.externalnumber`) may not map to an OMS
  `parcel_id`.
- The parcel was deleted or de-activated in the OMS DB (common in dev after extended periods).

**Recovery — use the parcel's external number to locate it:**

From §4.3 query, the WMS import message stores the `parcel_external_number` OMS sent during
batch import. To find it:

```sql
-- On WMS v2 tenant DB — look up the original batch import message for this customer order
SELECT SUBSTRING(message, 1, 2000) AS import_payload
FROM message
WHERE process = 'ORDER_BATCH_IMPORT'
  AND message LIKE '%' || (
        SELECT externalnumber FROM customerorder WHERE id = <customer_order_id>
      ) || '%'
ORDER BY created DESC
LIMIT 3;
```

Extract `parcel_external_number` from the payload. Then ask the OMS team to run on their DB:

```sql
-- On OMS MySQL tenant DB
SELECT p.parcel_id, p.parcel_id_str, p.parcel_status, p.ul_code, p.isactive, p.batch_criteria_id
FROM parcel p
WHERE p.parcel_id_str = '<parcel_external_number>'   -- e.g. 'WC1774283198224'
   OR p.parcel_id     = <unique_id>;                 -- fallback

-- Also try via the client order number from the import payload:
SELECT p.parcel_id, p.parcel_status, p.ul_code, p.isactive
FROM parcel p
JOIN orders o ON o.order_id = p.order_id
WHERE o.client_order_number = '<client_order_number>';  -- e.g. 'DaveOrder1'
```

**If the parcel is found** (possibly `isactive = 0` or wrong status): apply the effect of
`finishedPicking` manually — this is exactly what the OMS endpoint would have done
(`LegacyWmsController.php:1499–1518`):

```sql
-- On OMS MySQL tenant DB — run in a transaction
BEGIN;

UPDATE parcel
SET parcel_status   = 25,            -- WAITING_FOR_QA
    ul_code         = '<tote_label>',
    ul_code_history = '<tote_label>',
    update_date     = NOW(),
    updated_by      = 1
WHERE parcel_id = <parcel_id_from_above>;

INSERT INTO parcel_status_history
    (parcel_id, parcel_status, status_txt, status_date, updated_date, updated_by)
VALUES
    (<parcel_id>, 25,
     '{"status":"Picking complete, awaiting QA"}',
     NOW(), NOW(), 1);

-- Verify before committing
SELECT parcel_id, parcel_status, ul_code FROM parcel WHERE parcel_id = <parcel_id>;
COMMIT;
```

**If the parcel is not found at all:** the OMS order record for this parcel no longer exists in
the current DB (dev cleanup, or the order was voided on the OMS side). No OMS action is possible.
Confirm with OMS team whether the order still needs to flow through QA. The WMS side is already
correct (PO FINISHED, CO PICKED) and no WMS DB changes are needed.

---

### 5.4 Alternative: insert into `outbox_message` (no curl needed)

If you cannot reach the OMS endpoint directly but the WMS app is running, insert PENDING rows
into the `outbox_message` table. `OutboxDispatcherJob` (every 15 s, advisory lock `100008L`)
will deliver them with standard retry semantics and create `message` audit rows automatically.

```sql
-- On WMS v2 tenant DB — one INSERT per customer order
INSERT INTO outbox_message (
    aggregate_type, aggregate_id, process_type,
    destination_url, payload, idempotency_key,
    status, attempts, next_attempt_at, created_at, modified_at, version
) VALUES (
    'CUSTOMER_ORDER',
    <customer_order_id>,
    'ORDER_BATCH_PICKING_FINISHED',
    (SELECT sysvalue FROM los_sysprop WHERE syskey = 'WEBSERVICE_ORDER_BATCH_FINISHED_PICKING'),
    '{"facility_code":"<facility_code>","batch_id":"<batch_id>","positions":[{"unique_id":"<unique_id>","tote_label":"<tote_label>"}]}',
    'manual-recovery-picking-co-<customer_order_id>',
    'PENDING', 0, now(), now(), now(), 0
);
```

Wait ~15 s, then verify with the queries in §6.

---

## 6. Verification — Confirm Delivery

### 6.1 WMS: message row created

```sql
-- A SENT row should appear within 15 s of a successful curl or outbox dispatch
SELECT id, status, statuscodeanswer, answer, created
FROM message
WHERE process = 'ORDER_BATCH_PICKING_FINISHED'
ORDER BY created DESC
LIMIT 10;
-- EXPECT: status = 'SENT', statuscodeanswer = '200' or '201'
```

### 6.2 WMS: outbox row delivered (if §5.4 was used)

```sql
SELECT id, status, attempts, last_error, sent_at
FROM outbox_message
WHERE idempotency_key LIKE 'manual-recovery-picking-co-%'
ORDER BY created_at DESC;
-- EXPECT: status = 'SENT', sent_at IS NOT NULL
```

### 6.3 OMS: parcel is now WAITING_FOR_QA

Ask OMS team (or check OMS UI for the batch/order):

```sql
-- On OMS MySQL tenant DB
SELECT p.parcel_id, p.parcel_status, p.ul_code, p.update_date
FROM parcel p
WHERE p.parcel_id = <unique_id>
   OR p.parcel_id_str = '<parcel_external_number>';
-- EXPECT: parcel_status = 25 (WAITING_FOR_QA), ul_code = '<tote_label>'
```

---

## 7. Escalation

| When | Who | How |
|------|-----|-----|
| `"Invalid batch"` and OMS team cannot find `batch_criteria` row | OMS on-call | They may need to recreate the batch record or void the order |
| Parcel not found and order was voided in OMS | OMS on-call + customer service | Confirm if fulfilment is still required; may need a new order |
| Multiple orders affected (systemic) | WMS lead + OMS lead | Escalate to SEV1; use §5.4 (outbox batch insert) for bulk recovery |
| `message` row shows `status = FAILED` | OMS on-call | OMS API is down or rejecting; retry after OMS confirms health |

---

## 8. Post-incident

- [ ] Attach the §4.3 query output and the §6.1 verification to the incident ticket.
- [ ] Record which recovery path was used (§5.1 curl / §5.2 batch_label fix / §5.3 direct SQL / §5.4 outbox).
- [ ] If §5.3 direct SQL was used, record the `parcel_id` and operator name for OMS audit.
- [ ] File a follow-up ticket to migrate `finishPickingOrder` to use `outboxService.enqueue()`
  (SBDEV recommendation from `[[260520-wms2-picking-finished-oms-notification-dropped]]` §8).
- [ ] Update `last_verified` date in frontmatter after next use.

---

## 9. Background — Why This Happens

`rapidPickingScanSource` is `@Transactional`. When the last pick position is confirmed it calls
`finishPickingOrder`, which registers **Callback A** (`customerOrderPicked`) via
`TransactionSynchronizationManager.registerSynchronization`. The TX commits; Spring fires
Callback A. Inside Callback A, `sendAfterCommit` tries to register **Callback B** (`doSend` —
the actual HTTP POST). Spring's `isSynchronizationActive()` is still `true` at this point, so
registration succeeds — but Spring has already finished iterating the synchronization list.
Callback B is added to the list but never invoked. `cleanupAfterCompletion()` then clears the
list, and Callback B is silently discarded. The HTTP POST to OMS never happens.

```
rapidPickingScanSource (@Transactional)
  └─ finishPickingOrder
        └─ registers Callback A              ← TX commits
[triggerAfterCommit() iterates snapshot]
  └─ Callback A fires: customerOrderPicked()
        └─ sendAfterCommit()
              └─ registers Callback B        ← SILENTLY DISCARDED (not in snapshot)
[cleanupAfterCompletion() clears list]       ← Callback B evaporated
```

`pickingconfirmationsent = true` was committed inside the TX, so the flag is permanently set
even though the notification was never sent. There is **no retry, no error log, no outbox row**.

---

## 10. Code & Schema References

**WMS v2 (wms2-api):**
- `MobilePickingService.java:699–709` — Case 1 early exit in `releaseRegularPickingOrder`
- `MobilePickingService.java:1227` — `finishPickingOrder` call inside `rapidPickingScanSource`
- `PickingorderBusinessService.java:248–281` — Callback A registration + `pickingconfirmationsent` flag
- `PickingorderBusinessService.java:265` — `customerOrderPicked(singletonList(order))` — one call per CO
- `ManageOrderService.java:219–270` — `customerOrderPicked` — builds `OrderBatchDto` payload
- `ManageOrderService.java:266` — `sendAfterCommit(urlPath, payload, ...)` — Callback B registration
- `OmsNotificationService.java:65–84` — `sendAfterCommit` — where Callback B is registered and lost
- `OmsNotificationService.java:87–119` — `doSend` — the HTTP POST that never runs
- `OutboxService.java` — `enqueue()` — correct fix path (atomic with WMS state change)
- `OutboxDispatcherJob.java` — delivers `outbox_message` rows every 15 s (advisory lock `100008L`)

**JSON field names (`@JsonProperty` — all snake_case):**
- `OrderBatchDto`: `facility_code` (from `AbstractWebServiceDto`), `batch_id`, `positions`
- `OrderDto`: `unique_id`, `tote_label`

**WMS v2 DB (sysprop keys):**
- `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` — OMS `finishedPicking` URL
- `MULTIWAREHOUSE_IDENTIFIER` — facility code (e.g. `WSL`)
- `OMS_TENANT_ID` — value for `x-tenant` header (e.g. `wineco`)
- `OMS_API_USER` — Basic Auth credentials, format `user/password`

**OMS v2 (oms-laravel-api):**
- `LegacyWmsController.php:1410` — `finishedPicking` entry point
- `LegacyWmsController.php:1452` — `batch_criteria` lookup by `batch_label`
- `LegacyWmsController.php:1480–1489` — parcel lookup (numeric → `parcel_id`; string → `parcel_id_str`)
- `LegacyWmsController.php:1499` — sets `parcel_status = 25` (WAITING_FOR_QA) and `ul_code`
- `BatchProcessingService.php:411` — `unique_id = parcel_id` (OMS int PK) when building WMS payload
- `BatchProcessingService.php:142` — `batch_label` set from `$batchLabel` at batch creation

**Known edge cases:**
- Batches imported through the legacy v1/Zend OMS path may have `batch_criteria.batch_label = NULL`
  even though a `batch_id` was sent to WMS. Use §5.2 to stamp the label before retrying.
- Batches older than ~30 days in dev environments may have their `batch_criteria` row cleaned up
  or their parcels deleted. Use §5.3 direct SQL if the OMS lookup fails entirely.
- `unique_id` in the WMS→OMS payload is `customerorder.externalnumber`, which equals the OMS
  `parcel_id` (int PK) for batches created by `BatchProcessingService`. For legacy-path batches
  it may be a different identifier — always verify via the import message payload (§5.3).
