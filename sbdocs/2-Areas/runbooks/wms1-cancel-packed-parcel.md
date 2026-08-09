---
title: "Runbook: Cancel a Packed Parcel in WMS v1 (past QA)"
type: runbook
status: active
version: "wms-api v1 (Java 8, Spring Boot 2.3.7, PostgreSQL)"
scope: "v1/wms-api — order/parcel cancellation when order state >= PACKED (650)"
owner: "nam.park@siteboss.net"
created: "2026-04-20"
updated: "2026-08-05"
last_verified: "2026-08-05"
verified_by: "nam.park@siteboss.net — code read (v1/wms-api CustomerorderService, MessageService, OrderBatchDto; v2/oms-laravel-api LegacyPositionCancelService, LegacyOrderCancelService, OrderRepository) + data validation against wms1-wineco-dev (wh01_om1) during SBDEV-2833"
alert: "Manual cancellation request for a post-QA parcel (support / ops escalation)"
severity: "SEV3"
escalation: "WMS on-call engineer -> DB admin (for manual SQL) -> OMS on-call (MANDATORY — see §5.3, WMS cannot notify OMS)"
related:
  - "[[wms-testing-smoke-test-checklist]]"
  - "[[wms1-cancel-cascade-workflow]]"
  - "[[wms1-cancel-preqa-parcel]]"
  - "[[wms1-revert-shipped-order-to-cancelled]]"
tags:
  - runbook
  - wms1
  - cancellation
  - parcel
  - data-repair
---

# Runbook: Cancel a Packed Parcel in WMS v1 (past QA)

**Alert:** Manual cancellation request for a post-QA parcel | **Severity:** SEV3
**Scope:** `v1/wms-api` — orders at state >= PACKED (650) | **Version:** wms-api v1
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-08-05 (nam.park)

<!--
  Runbook for manually cancelling a customer order whose state is past QA
  (PACKED / PALLETIZED). The REST API blocks this for PICK_PACK batches, so
  the steps below combine code-path decisions with raw SQL fallbacks.
-->

> **⚠️ WMS CANNOT NOTIFY OMS OF THIS CANCEL.** Verified 2026-08-05: v1 has no working
> WMS→OMS cancel notification. Inserting a `message` row does **nothing** — nothing drains
> `status = 'CREATED'` (see §5.2 step 6 and §9). The five `MSG-MANUAL-CANCEL-*` rows written
> during the April 2026 incident were still `CREATED` and unsent 3½ months later, so that
> incident's OMS side was likely never reconciled. **§5.3 (OMS-side reconciliation) is a
> mandatory step of this runbook, not a follow-up.** Never close a ticket after §5.2 alone.

---

## 1. When to Use This Runbook

- Triggered by: Ops / customer service asking to cancel a parcel that has already been packed, palletized, or loaded but has **not yet shipped**.
- Use this when the order's `customerorder.state` is one of:
  - 650 (PACKED)
  - 670 (PALLETIZED)
- Do NOT use this runbook if:
  - Order state is 700 (FINISHED) — shipment is final, use a return flow instead.
  - Any `stockunit.entity_lock = 405` (SHIPPED) — the shipment has left.
  - Parcel is on a `billoflading` row with `state = 'CLOSED'` — use the return / short-ship flow.
  - Order is pre-PACKED (< 650) — use the regular `POST /rest/order/cancelPositions` endpoint; no manual work needed.

---

## 2. Severity & Impact

| Aspect | Detail |
|--------|--------|
| User impact | OMS order stays stuck in PACKING/PICKING until WMS sends a cancellation message. Customer ships late or double-ships if mishandled. |
| Blast radius | One customer order at a time (single-tenant DB). SQL mistakes can desync OMS inventory for the affected SKUs. |
| Is it a paging event? | No — schedule during a quiet window with DB admin present. |
| SLO burn? | Not directly; delay risks customer SLAs if not completed within the day. |

---

## 3. First 5 Minutes — Triage

- [ ] Confirm the request source (ticket ID, requester, ship-by deadline).
- [ ] Get the `customerorder.externalnumber` (OMS number) or `customerorder.number` (WMS `ODR-…`).
- [ ] Identify tenant + facility (sets `tenant_name` / `facility_code` for DB connection).
- [ ] Check that the order is not currently being handled on the floor (ask floor lead).
- [ ] Open a DB session against the correct tenant schema (read-only first).

---

## 4. Diagnosis — Can This Order Be Cancelled?

Run queries **in order**. Replace `:order_id` with the order id, or adjust the first query to look up by `externalnumber`.

### 4.1 Snapshot the order

```sql
SELECT
  co.id                 AS order_id,
  co.externalnumber,
  co.number             AS wms_number,
  co.state              AS order_state,         -- 650=PACKED, 670=PALLETIZED, 700=FINISHED, 800=CANCELED
  co.markedforcancellation,
  co.parcel_id,
  co.pickingtote_id,
  cob.id                AS batch_id,
  cob.type              AS batch_type,          -- CLUB routes to forceCancel via REST; PICK_PACK does not
  cob.state             AS batch_state,
  parcel.labelid        AS parcel_label,
  parcel.entity_lock    AS parcel_lock,         -- 405=SHIPPED -> STOP
  tote.labelid          AS tote_label,
  tote.entity_lock      AS tote_lock
FROM customerorder co
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
LEFT JOIN unitload parcel ON parcel.id = co.parcel_id
LEFT JOIN unitload tote   ON tote.id   = co.pickingtote_id
WHERE co.id = :order_id;
```

### 4.2 Decision tree (from §4.1 output)

| Finding | Action | Jump to |
|---------|--------|---------|
| `order_state < 650` | Use the normal REST cancel endpoint — this runbook does not apply | — |
| `order_state = 700` OR `parcel_lock = 405` | **STOP.** Shipment is final; do not cancel. Use a return flow. | §6 (escalation) |
| `batch_type = 'CLUB'` AND `order_state IN (650, 670)` | Use **REST endpoint** — the code's `forceCancelOrder` path handles this | §5.1 |
| `batch_type <> 'CLUB'` AND `order_state IN (650, 670)` AND parcel not shipped | Manual SQL cancellation required | §5.2 (after §4.3 + §4.4 clear) |

> **Expect the manual path.** A CLUB batch can never reach PACKED *via QA* — `finishedQA`
> discards CLUB batches (`OrderRestController.java:823-826`) and `packageOrder` throws for them
> (`CustomerorderService.java:437-439`); club orders only reach PACKED through the club-line run.
> So anything that arrived here from an OMS "QA Complete Outbound" is **not** CLUB and §5.1 is
> closed to it. Confirmed on `wms1-wineco-dev` 2026-08-05: of 20 orders sitting at 650/670,
> **20 were `PICK_PACK` and 0 were `CLUB`** (oldest stuck since 2025-04-23 — this is chronic,
> not a one-off).

### 4.3 Check no stock unit is already SHIPPED

```sql
SELECT su.id, su.amount, su.entity_lock, ul.labelid
FROM stockunit su
JOIN unitload ul ON ul.id = su.unitload_id
WHERE ul.id = (SELECT parcel_id FROM customerorder WHERE id = :order_id)
  AND su.entity_lock = 405;  -- SHIPPED
```
- Zero rows → safe to proceed.
- Any rows → **STOP.** Escalate to §6.

### 4.4 Check for BOL assignment

```sql
SELECT bol.id, bol.number, bol.state AS bol_state,
       bolp.id AS bol_position_id, bolp.order_id
FROM billoflading_position bolp
JOIN billoflading bol ON bol.id = bolp.billoflading_id
WHERE bolp.order_id = :order_id;
```
- Zero rows → proceed.
- **Any non-`CLOSED` state** (`OPEN`, `TRUCK_LOADING`, …) → you must delete the `billoflading_position` as part of the cancel (the code does **not** do this — see TODO at `CustomerorderService.java:364`). Do **not** treat `OPEN` as the only such state: on `wms1-wineco-dev` 2026-08-05, the one BOL-bearing stuck order (`051664-000001`, parcel on `Gate_01`) was on a BOL in state **`TRUCK_LOADING`**. Truck loading means the parcel is staged at a gate — re-confirm with the shipping lead that the truck has not departed before proceeding.
- `bol_state = 'CLOSED'` → **STOP.** Shipment has left. Escalate to §6.

### 4.5 Enumerate reserved stock and picking positions

```sql
SELECT pop.id, pop.state, pop.amount, pop.amountpicked,
       pop.pickfromstockunit_id,
       su.amount AS stock_amount,
       su.reservedamount
FROM pickingorder_position pop
JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
LEFT JOIN stockunit su ON su.id = pop.pickfromstockunit_id
WHERE cop.order_id = :order_id;
```
**Expect `pickfromstockunit_id IS NULL` and `pop.state = 600` on every row.** By the time an order
is PACKED the pick is already consumed: `changeReservedAmount` ran at pick time and
`pickfromstockunit_id` was cleared. Validated on `wms1-wineco-dev` 2026-08-05 — across all 52
picking positions belonging to orders at 650/670, **`pickfromstockunit_id` was NULL on 100% of
rows** and every row was state 600 (`amountpicked` totalling 176 units).

Two consequences, both of which change what you can promise:

1. **There is no reservation left to release**, so this query has no baseline to record and §7.D
   cannot verify anything. Do not report "reservations released" as evidence of a correct cancel.
2. **There is no pointer back to the source stockunit or location.** If the request is to return
   the goods to where they were picked from ("Option B" in
   [wms1-revert-shipped-order-to-cancelled](./wms1-revert-shipped-order-to-cancelled.md)), the
   source must be **reconstructed from `stockrecord` history** — run §4.5b. This is what the April
   2026 incident had to do by hand.

### 4.5b Reconstruct the pick sources from stockrecord

**Do not try to find the pick rows by order number — it does not work.** Verified 2026-08-05 on
`wms1-wineco-dev`: for order `051401-000004` (ext `562868`), filtering `stockrecord.ordernumber` by
the WMS number, the `externalnumber`, the `customerorder_position.externalid` (`562868-0…4`) or the
picking order number (`PICK226391`) **all return only the `PACKAGING` rows** — and those carry
`amount = 0.0000` and `fromstoragelocation = 'FinishedPicking'`, so they tell you nothing about
where the goods came from. The `PICKING` rows exist (38,721 in April 2025 alone; retention is not
the problem — `stockrecord` goes back to 2019, 5.9 M rows) but are stamped with an **OMS-side
pick-request id** (`756248`, `756251`, …) that has no join path from the WMS order.

The linkage that does work is the **tote label**:

```sql
-- Step 1: get the tote and parcel labels
SELECT co.number, co.externalnumber, co.historytote, ul.labelid AS parcel_label
FROM customerorder co
LEFT JOIN unitload ul ON ul.id = co.parcel_id
WHERE co.id = :order_id;

-- Step 2: the PACKAGING rows — confirms the SKU set that went into the parcel
SELECT sr.created, sr.itemdata, sr.fromunitload, sr.tounitload,
       sr.fromstoragelocation, sr.tostoragelocation
FROM stockrecord sr
WHERE sr.ordernumber = (SELECT number FROM customerorder WHERE id = :order_id)
  AND sr.activitycode IN ('PACKAGING', 'PACKAGING_CLUB')
ORDER BY sr.created;

-- Step 3: the PICKING rows — join by tote label + time window, then match on SKU + amount
SELECT sr.created, sr.ordernumber AS oms_pick_request_id, sr.itemdata,
       sr.fromstoragelocation, sr.fromunitload, sr.amount, sr.reservedamountchange
FROM stockrecord sr
WHERE sr.tounitload = :'tote_label'          -- co.historytote from step 1
  AND sr.activitycode = 'PICKING'
  AND sr.created BETWEEN :'pick_window_start' AND :'pick_window_end'
ORDER BY sr.created;
```

- **The tote is reused**, so step 3 returns other orders' picks too. Narrow it by matching
  `itemdata` + `amount` against the SKU set from step 2 and the `amountpicked` values from §4.5.
  In the verified example, tote `T-0096` carried picks for ten different orders on the same day.
- **`fromstoragelocation` is not always a rack location.** Under rapid picking it is the operator's
  own location (e.g. `danielvalentim`), because the pick goes operator-cart → tote. In that case
  `fromunitload` is the useful field, and you may need to walk back a further hop to find the rack.
- Each pick writes a **pair** of rows: one with `reservedamountchange` set (the reservation
  decrement) and one with `amount` set (the physical move). Read the `amount` row for quantities.
- Record whatever you reconstruct in the ticket **before** any write, and state your confidence.
  If you cannot establish the source to the SKU + quantity + location level, **do not attempt a
  return-to-source**; send the parcel to Clearing and let a physical putaway decide the
  destination. Guessing a putaway target is worse than an operator scan.

### 4.6 Look up the "clearing" location id (needed for §5.2)

```sql
SELECT id, name FROM location WHERE name ILIKE '%clearing%';
```
- Record the id — you will set `unitload.storagelocation_id` to this in §5.2.
- On `wms1-wineco-dev` this resolves to exactly one row: **`id = 1`, name `Clearing`** (verified
  2026-08-05). Still run the query — do not hardcode `1` across tenants.
- **Clearing is a holding location, not inventory.** Moving the parcel there does not make the
  goods sellable again. A physical de-consolidation + putaway is required afterwards, and the OMS
  side will have credited the inventory back independently (§5.3) — reconcile the two.

---

## 5. Recovery Actions

### 5.1 CLUB batch — cancel via REST (preferred path)

No SQL writes. The code's `forceCancelOrder` handles PACKED/PALLETIZED for CLUB.

```bash
# Authenticated request to the WMS API (Keycloak JWT, per-tenant headers)
curl -X POST "$WMS_BASE/rest/order/cancelPositions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "tenant_name: $TENANT" \
  -H "facility_code: $FACILITY" \
  -H "Content-Type: application/json" \
  -d '[{"externalNumber":"<OMS_BATCH_NUMBER>","orderNumbers":["<OMS_ORDER_NUMBER>"]}]'
```
- 204 No Content → success. Proceed to §7 (verification).
- 400 + `partial_failure` → pull the `failedOrders[]` from the body, check the DB queries in §4 again for those orders, decide per-order whether to escalate or fall back to §5.2.

### 5.2 PICK_PACK / TRANSFER batch — manual SQL cancellation

**Prerequisites:**
- §4.3 returned zero rows.
- §4.4 returned zero rows **or** only `bol_state = 'OPEN'` rows.
- DB admin is on the call.
- You have the clearing `location_id` from §4.6.
- The system user id (e.g. `SELECT id FROM mywms_user WHERE name = 'system';`). If that row doesn't exist, pick your own user id and document it in the ticket.
- The system-property table name and its `key`/`value` columns. v1 uses the `LosSysprop` entity:
  ```sql
  SELECT table_name FROM information_schema.tables
  WHERE table_schema = current_schema() AND table_name ILIKE '%sysp%';
  -- then inspect columns:
  \d <table_name>
  ```
  Typical shape is `los_sysprop(syskey, sysvalue)` — the INSERT in step 6 below assumes this; adjust the column names if your env differs.
- Sequence name is **`seqentities`** (NOT `hibernate_sequence`). All `id` columns on `stockrecord`, `message`, etc. are allocated from this single sequence.

Run inside a single transaction. Re-run the §7 validation queries **before** `COMMIT`.

```sql
BEGIN;

-- Variables (psql). Adjust for your SQL client.
\set order_id            12345
\set clearing_location   42     -- from §4.6 (= 1 on wineco-salem, but re-query per tenant)
\set system_user_id      1      -- from mywms_user
\set operator_audit      'db_manual_cancel:nam.park@<ticket-id>'
\set facility_code       'wsl'  -- from §3 triage; goes into the step-6 payload

-- 1. Cancel order + positions
UPDATE customerorder_position
SET state = 800, modified = now()
WHERE order_id = :order_id;

UPDATE customerorder
SET state = 800,
    modified = now(),
    historytote = (SELECT labelid FROM unitload WHERE id = customerorder.pickingtote_id)
WHERE id = :order_id;

-- 2. Unlock the parcel and every stock unit inside it
--    NOTE: usually a NO-OP at 650/670 — verified 2026-08-05 that all 20 stuck orders on
--    wms1-wineco-dev already had parcel.entity_lock = 0 and no stockunit at 405. Keep the
--    statements (idempotent, and they matter for the rarer locked-parcel case), but do NOT
--    treat "0 rows changed" as a failure, and do not cite this step as evidence of anything.
UPDATE unitload
SET entity_lock = 0, modified = now()
WHERE id = (SELECT parcel_id FROM customerorder WHERE id = :order_id);

UPDATE stockunit
SET entity_lock = 0, modified = now()
WHERE unitload_id = (SELECT parcel_id FROM customerorder WHERE id = :order_id);

-- 3. Send the parcel to the clearing location
UPDATE unitload
SET storagelocation_id = :clearing_location, modified = now()
WHERE id = (SELECT parcel_id FROM customerorder WHERE id = :order_id);

-- 4. Clean up any OPEN BOL positions (the code has an open TODO for this)
DELETE FROM billoflading_position WHERE order_id = :order_id;

-- 5. Write a stockrecord audit row (mirrors what changeReservedAmount would write)
INSERT INTO stockrecord (
  id, version, created, modified, client_id,
  activitycode, operator, ordernumber, type,
  fromstoragelocation, tostoragelocation, additionalcontent
)
SELECT
  nextval('seqentities'), 0, now(), now(), co.client_id,
  'CANCELLED_ORDER_FROM_WEBSERVICE', :'operator_audit', co.number, 'STOCK_ALTERED',
  (SELECT l.name FROM location l
     JOIN unitload ul ON ul.storagelocation_id = l.id
    WHERE ul.id = co.parcel_id),
  (SELECT name FROM location WHERE id = :clearing_location),
  'Manual SQL force-cancel of PACKED order — ticket <ticket-id>'
FROM customerorder co
WHERE co.id = :order_id;

-- 6. Write the OMS cancellation message row.
--    This row is a LOG ENTRY + a resend vehicle. It does NOT deliver itself — see the
--    box below. The payload MUST be the JSON OrderBatchDto shape or OMS will reject it.
INSERT INTO message (
  id, version, created, modified, client_id, operator_id,
  number, process, status, sender, receiver, destination,
  resent, message
)
SELECT
  nextval('seqentities'), 0, now(), now(), co.client_id, :system_user_id,
  'MSG-MANUAL-CANCEL-' || co.number,
  'ORDER_BATCH_CANCELLED_FROM_WMS',
  'CREATED',
  -- sender MUST equal losSyspropService.getWmsInstanceName() or resendMessage throws
  -- "Message not from WMS!". That resolves from syskey SYSTEM_WMS_NAME (= 'WMS' on
  -- wineco-salem), NOT from the similarly-named decoy WMS_INSTANCE_NAME (= 'wineco-salem').
  -- Safest check: SELECT sender FROM message WHERE status='SENT' ORDER BY created DESC LIMIT 1
  -- — an @Value-injected override wins over the DB row when set.
  (SELECT sysvalue FROM los_sysprop
    WHERE syskey = 'SYSTEM_WMS_NAME' AND workstation = 'DEFAULT' LIMIT 1),
  (SELECT sysvalue FROM los_sysprop
    WHERE syskey = 'SYSTEM_OMS_NAME' AND workstation = 'DEFAULT' LIMIT 1),  -- 'OMS_om1', not 'OMS'
  (SELECT sysvalue FROM los_sysprop
    WHERE syskey = 'WEBSERVICE_ORDER_BATCH_CANCELLED'
      AND workstation = 'DEFAULT'
    LIMIT 1),  -- key is WEBSERVICE_ORDER_BATCH_CANCELLED (no _URL suffix)
  false,
  json_build_object(
    'facility_code', :'facility_code',
    'batch_id',      cob.batchid,
    'positions', json_build_array(
      json_build_object('unique_id', co.externalnumber)
    )
  )::text
FROM customerorder co
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
WHERE co.id = :order_id;

-- ---- Re-run §7 verification queries inside this txn ----
-- If any query fails expectations, ROLLBACK. Otherwise COMMIT.
COMMIT;
```

> **⚠️ The `message` row does not send itself — corrected 2026-08-05.**
> The previous version of this runbook said to "check that the message outbox picks up the new
> row" and to "set `status = 'RELEASED'`" if it didn't. **Both are wrong:**
> - There is **no outbox cron** for `message`. Outbound sends are inline in the service code
>   (`CustomerorderBatchService.java:229-240` POSTs, *then* logs the row with the outcome).
>   `MessageService.createServiceLog` writes `CREATED` purely as a log. Nothing scans for it.
> - **`RELEASED` is not a valid status.** The only values in use are `SENT`, `CREATED`, `FAILED`
>   (outbound) and `RECEIVED` (inbound).
> - Evidence: on `wms1-wineco-dev`, `sender = 'WMS'` has **1,223,576 `SENT`** rows (latest
>   2026-08-04, so the path is healthy) against just **17 `CREATED`** — five of which are the
>   `MSG-MANUAL-CANCEL-*` rows this runbook created on 2026-04-20/22/24, still unsent with
>   `statuscodeanswer = NULL`.
> - The old XML payload (`<manual_cancel><externalnumber>…`) would have been rejected anyway:
>   `LegacyWmsController::cancelPosition` validates `batch_id`, `positions`, and
>   `positions.*.unique_id` as JSON. Hence the `json_build_object` form above.
>
> **To actually deliver it:** call the authenticated resend endpoint with the id of the row you
> just inserted — `MessageService.resendMessage` POSTs `message.message` verbatim to
> `message.destination` and logs a new row with the real outcome:
> ```bash
> curl -X GET "$WMS_BASE/v3/message/resend/<message_id>" \
>   -H "Authorization: Bearer $TOKEN" \
>   -H "tenant_name: $TENANT" -H "facility_code: $FACILITY"
> ```
> Then confirm a **new** row exists with `resent = true`, `redeliver_id = <message_id>`,
> `status = 'SENT'` and a 2xx `statuscodeanswer`. A `FAILED` row with `503` means the POST threw.
> **Even on `SENT`, go on to §5.3** — OMS accepting the call does not move the OMS *order* status.
>
> Also check `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` — it was **`false`** on
> `wms1-wineco-dev` (2026-08-05). It does not gate `resendMessage`, but it does mean the
> automatic callback is switched off in this environment, which is part of why this gap is
> invisible in normal operation.

---

### 5.3 OMS-side reconciliation — MANDATORY

Neither §5.1 nor §5.2 leaves OMS in a correct state. Do not skip this and do not hand the ticket
back to the client before it is done. Two independent reasons:

1. **The inbound handler never touches the order.**
   `LegacyPositionCancelService::cancelPositions` (`v2/oms-laravel-api/app/Services/Legacy/`)
   sets `order_item_parcel.qa_status = 28`, `parcel.parcel_status = 28`,
   `batch_criteria.batch_status = 28` and credits inventory back via
   `returnInventoryToAvailable` — but it issues **no update to `orders.order_status`**. A
   successful delivery therefore yields parcel = 28 / order = 27: still mismatched.
2. **OMS refuses to cancel at 27 by itself**, in two places —
   `OrderRepository::isOrderActionable` (allow-list `[1,2,3,6,8,9,10,19,22,23,24]`, 27 absent) and
   `LegacyOrderCancelService::UNCANCELABLE_ORDER_STATUSES` (27 listed explicitly). Editing the
   order instead is also blocked: `isOrderEditable` allows only `[1,2,6,8,9,10]`.

So the OMS order status must be moved deliberately, by OMS on-call:

- [ ] Set `orders.order_status` → **28 (CANCEL)** for each affected order.
- [ ] Write the matching `order_status_history` row (mirror what
      `LegacyOrderCancelService::updateOrderStatus` writes, incl. the `order_status_lut` string).
- [ ] Confirm the inventory credit happened **exactly once** — if §5.2's message was delivered,
      `returnInventoryToAvailable` already ran; if it was not, OMS inventory still shows the
      goods allocated. Do not double-credit.
- [ ] Reconcile against the WMS side: the parcel is in **Clearing**, not back in stock, until
      someone physically puts it away.
- [ ] **Reupload is a separate question.** `OrderProcessingService::validateOrderBusinessRules`
      rejects any `orderID` that already exists *regardless of status*, and there is a unique key
      behind the `"Duplicate entry … for key … orderID"` upload error. SBDEV-1925's fix cleared
      stale **staging** rows (`OrderRepository::insertOrderInputData`), which is not the same
      thing. **Prove cancel-then-reupload on a throwaway order in UAT before telling the client
      their original order IDs can be reused.**

---

## 6. Escalation

| When | Who | How |
|------|-----|-----|
| Any `stockunit.entity_lock = 405` (SHIPPED) in the parcel | Warehouse floor lead + OMS on-call | Switch to a return / short-ship flow; do NOT proceed with cancellation |
| `billoflading.state = 'CLOSED'` for the order's BOL | Shipping lead | Confirm if truck has left; if yes, return flow; if no, un-close BOL first |
| **Every run of this runbook** (not conditional) | OMS on-call | §5.3 — they must move `orders.order_status` to 28 and confirm the inventory credit. WMS cannot do it and cannot tell them automatically. |
| OMS `message` row stuck in `FAILED` after §5.1 or §5.2 | OMS on-call | They retry the webhook; if it keeps failing, they hand-adjust the OMS order |
| Message row stuck in `CREATED` (never sent) | WMS on-call | Fire `/v3/message/resend/{id}` per §5.2; if the payload is rejected, check it is the JSON `OrderBatchDto` shape, not XML |
| Floor already reported the parcel as physically shipped | Stop immediately | Treat as a return; do not manipulate DB state |
| Anything outside this list | WMS on-call engineer | Slack #wms-oncall with ticket id |

---

## 7. Verification — Confirm Resolved

Run each query after cancellation (post-COMMIT for §5.2; post-REST-204 for §5.1). The **EXPECT** line tells you what a correct cancellation looks like.

```sql
-- A. Order is CANCELED
SELECT id, state, markedforcancellation, modified
FROM customerorder
WHERE id = :order_id;
-- EXPECT: state = 800, modified within the last few minutes
```

```sql
-- B. Every order position is CANCELED
SELECT id, state
FROM customerorder_position
WHERE order_id = :order_id AND state <> 800;
-- EXPECT: zero rows
```

```sql
-- C. Picking positions still read PICKED (600) with no source pointer
SELECT pop.id, pop.state, pop.pickfromstockunit_id, pop.amountpicked
FROM pickingorder_position pop
JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
WHERE cop.order_id = :order_id;
-- EXPECT: every row state = 600 and pickfromstockunit_id IS NULL — UNCHANGED from §4.5.
-- The §5.2 script does not touch pickingorder_position, and it should not: the pick genuinely
-- happened. Do NOT expect state 800 here. (The pre-2026-08-05 version of this check asserted
-- "zero rows where state <> 800", which fails on every correct post-QA cancel.)
```

```sql
-- D. (REMOVED) Reserved-stock release — NOT APPLICABLE past PACKED.
-- Reservations were consumed at pick time and pickfromstockunit_id is already NULL, so there is
-- no baseline to diff and nothing to release. Validated 2026-08-05: 52/52 picking positions on
-- orders at 650/670 had pickfromstockunit_id NULL. The old query joined on that NULL column and
-- returned zero rows, which reads as "verified" while proving nothing.
--
-- Instead, verify that your own audit row landed (step 5 stamps it with ordernumber = co.number,
-- so this filter does find it — unlike the PICKING rows, see §4.5b):
SELECT sr.created, sr.activitycode, sr.type, sr.operator,
       sr.fromstoragelocation, sr.tostoragelocation, sr.amount
FROM stockrecord sr
WHERE sr.ordernumber = (SELECT number FROM customerorder WHERE id = :order_id)
ORDER BY sr.created DESC LIMIT 10;
-- EXPECT: a new row with operator = your 'db_manual_cancel:…' audit string, tostoragelocation
-- = Clearing. The goods are NOT sellable until a putaway moves them out of Clearing — track
-- that separately; this runbook does not complete it.
```

```sql
-- E. stockrecord audit row exists
SELECT id, created, operator, activitycode, type, ordernumber,
       amount, reservedAmountChange, fromstoragelocation, tostoragelocation
FROM stockrecord
WHERE ordernumber = (SELECT number FROM customerorder WHERE id = :order_id)
   OR activitycode IN ('CANCELLED_PICK_FROM_WEBSERVICE', 'CANCELLED_ORDER_FROM_WEBSERVICE')
ORDER BY created DESC
LIMIT 20;
-- EXPECT: at least one row with activitycode in CANCELLED_* family OR type = STOCK_RESERVED_CHANGED
```

```sql
-- F. Parcel is unlocked and in clearing
SELECT ul.id, ul.labelid, ul.entity_lock, ul.storagelocation_id, loc.name AS location_name
FROM unitload ul
LEFT JOIN location loc ON loc.id = ul.storagelocation_id
WHERE ul.id = (SELECT parcel_id FROM customerorder WHERE id = :order_id);
-- EXPECT: entity_lock = 0, location_name LIKE '%clearing%'

SELECT su.id, su.entity_lock, su.reservedamount
FROM stockunit su
WHERE su.unitload_id = (SELECT parcel_id FROM customerorder WHERE id = :order_id);
-- EXPECT: every row has entity_lock = 0
```

```sql
-- G. Picking tote released + cleared
SELECT ul.id, ul.labelid, ul.entity_lock, loc.name AS location_name
FROM unitload ul
LEFT JOIN location loc ON loc.id = ul.storagelocation_id
WHERE ul.labelid = (SELECT historytote FROM customerorder WHERE id = :order_id);
-- EXPECT: entity_lock = 0, location_name LIKE '%clearing%'
```

```sql
-- H. OMS notification emitted or received
SELECT id, process, status, created, statuscodeanswer, answer
FROM message
WHERE process IN ('ORDER_BATCH_CANCELLED_FROM_WMS', 'ORDER_BATCH_CANCELLED_FROM_PSD')
  AND (message LIKE '%' || (SELECT externalnumber FROM customerorder WHERE id = :order_id) || '%'
    OR message LIKE '%' || (SELECT number         FROM customerorder WHERE id = :order_id) || '%')
ORDER BY created DESC
LIMIT 5;
-- EXPECT (corrected 2026-08-05): TWO rows for a §5.2 cancel you actually delivered —
--   1. the row you INSERTed, status = 'CREATED'  (a log entry; it never sends itself)
--   2. a row written by resendMessage with resent = true, redeliver_id = <row 1 id>,
--      status = 'SENT' and a 2xx statuscodeanswer
-- A single 'CREATED' row means the cancel was NEVER delivered to OMS. That is the exact
-- failure state the five April-2026 MSG-MANUAL-CANCEL-* rows are still sitting in.
-- 'FAILED' + 503 -> the POST threw; retry the resend, then escalate to OMS on-call.
-- status = RECEIVED on a FROM_PSD row is inbound (OMS -> WMS) and unrelated to this step.
```

```sql
-- H2. Sanity-check that a 'CREATED' row really is stuck, not merely young
SELECT status, count(*) AS n, max(created) AS newest
FROM message WHERE sender = (SELECT sysvalue FROM los_sysprop
  WHERE syskey = 'SYSTEM_WMS_NAME' AND workstation = 'DEFAULT' LIMIT 1)
GROUP BY status;
-- EXPECT: a large SENT count with a recent `newest` (1,223,576 / 2026-08-04 on wineco-dev) and a
-- tiny CREATED count. If CREATED is growing, hand-written message rows are piling up undelivered.
```

```sql
-- I. Batch terminality
SELECT cob.id, cob.state,
       COUNT(*) FILTER (WHERE co.state NOT IN (700, 800)) AS non_terminal_count
FROM customerorder_batch cob
JOIN customerorder co ON co.orderbatch_id = cob.id
WHERE cob.id = (SELECT orderbatch_id FROM customerorder WHERE id = :order_id)
GROUP BY cob.id, cob.state;
-- EXPECT: if non_terminal_count = 0, batch state should be 700 or 800
```

```sql
-- J. No dangling BOL position (the open TODO at CustomerorderService.java:364)
SELECT bolp.id, bolp.order_id, bolp.billoflading_id, bol.state AS bol_state, bolp.state AS bolp_state
FROM billoflading_position bolp
JOIN billoflading bol ON bol.id = bolp.billoflading_id
WHERE bolp.order_id = :order_id;
-- EXPECT: zero rows. Any rows -> run `DELETE FROM billoflading_position WHERE order_id = :order_id;`
```

OMS-side verification (outside WMS DB) — this is §5.3's output, and it will **not** happen by
itself:
- [ ] `orders.order_status = 28` — check this explicitly. The inbound handler only sets
      `order_item_parcel.qa_status` / `parcel.parcel_status` / `batch_criteria.batch_status`, so
      order = 27 with parcel = 28 is the expected *broken* result of relying on the notification.
- [ ] A matching `order_status_history` row exists.
- [ ] OMS inventory credited for affected SKUs **exactly once** (not zero, not twice).
- [ ] Customer-facing order in the storefront shows cancelled / voided.
- [ ] If reupload was promised: cancel-then-reupload was proven in UAT first (see §5.3).

---

## 8. Post-incident

- [ ] Attach queries A–J output to the ticket (note D is removed — see §7).
- [ ] Record the §4.5b source-location list and the quantity moved to Clearing, for inventory reconciliation. (Do **not** report "reserved stock released" — there was none to release.)
- [ ] Confirm §5.3 is signed off by OMS on-call. **The ticket is not done until this is.**
- [ ] Confirm the physical putaway out of Clearing is tracked somewhere — this runbook does not complete it.
- [ ] If manual SQL was used (§5.2), log entries with `stockrecord.operator = 'db_manual_cancel:…'` — reconcile them weekly.
- [ ] If §7.J required a manual `DELETE`, open a follow-up ticket to resolve the code TODO at `CustomerorderService.java:364`.
- [ ] Update `last_verified` date in frontmatter after the next use.

---

## 9. Related Docs & Evidence

**Code references (v1/wms-api):**
- `src/main/java/net/aim_ai/wms/service/CustomerorderService.java:282-369` — `forceCancelOrder` (what this runbook emulates for PICK_PACK)
- `src/main/java/net/aim_ai/wms/service/CustomerorderService.java:533-550` — `isShippedOrPastCancellationBoundary`
- `src/main/java/net/aim_ai/wms/service/CustomerorderService.java:561-720` — `cancelOrder` (OMS-facing entry point)
- `src/main/java/net/aim_ai/wms/service/CustomerorderService.java:364` — **TODO**: BOL position cleanup missing
- `src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java:116-157` — position-level cancel
- `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java:675-777` — REST entrypoint for §5.1
- `src/main/java/net/aim_ai/wms/service/WmsConstants.java:12-163` — state + entity_lock constants

**Schema references:**
- `src/main/resources/db/migration/V1.0.01__wms_tables.sql` — base tables (customerorder, parcel, unitload, stockunit, message, billoflading)
- `src/main/resources/db/migration/V1.0.04__wms_init_data.sql:48-49` — `WEBSERVICE_ORDER_BATCH_CANCELLED` (webhook URL) and `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` (toggle) system properties in `los_sysprop`

**Code references (v1/wms-api) — added 2026-08-05:**
- `src/main/java/net/aim_ai/wms/service/MessageService.java:141-177` — `resendMessage`: the only way to deliver a hand-written `message` row; rejects any `sender` != `getWmsInstanceName()`
- `src/main/java/net/aim_ai/wms/service/MessageService.java:53` — `createServiceLog` writes `CREATED` as a **log only**
- `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java:229-240` — the real outbound send: POST first, log the outcome second (no queue, no cron)
- `src/main/java/net/aim_ai/wms/json/OrderBatchDto.java` + `OrderDto.java` + `AbstractWebServiceDto.java` — the `facility_code` / `batch_id` / `positions[].unique_id` wire contract
- `src/main/java/net/aim_ai/wms/service/LosSyspropService.java:280-292` — `SYSTEM_WMS_NAME` / `SYSTEM_OMS_NAME` resolution (with `@Value` override)
- `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java:823-826` — `finishedQA` discards CLUB batches (why post-QA orders are never CLUB)

**OMS-side references (v2/oms-laravel-api):**
- `app/Services/Legacy/LegacyPositionCancelService.php:45-250` — inbound `/services/call/cancelPosition`; sets qa/parcel/batch status + credits inventory, **never `orders.order_status`**
- `app/Http/Controllers/Api/Legacy/LegacyWmsController.php:3044-3056` — validates JSON `batch_id` / `positions.*.unique_id`
- `app/Repositories/OrderRepository.php:79-125` — `isOrderEditable` `[1,2,6,8,9,10]`, `isOrderActionable('CANCEL')` `[1,2,3,6,8,9,10,19,22,23,24]` — both exclude 27
- `app/Services/Legacy/LegacyOrderCancelService.php:51` — `UNCANCELABLE_ORDER_STATUSES` includes 27
- `app/Services/OrderProcessingService.php:1127-1132` — rejects an existing `orderID` regardless of status (reupload risk)

**Known limitations / caveats (revised 2026-08-05):**
- There is no `cancelled_by` or `cancelled_at` column. Audit trail is `customerorder.modified` + `stockrecord.operator`.
- **WMS has no working outbound cancel notification.** A `message` row does not send itself; there is no cron for `status = 'CREATED'` and no such thing as `'RELEASED'` (valid values: `SENT`, `CREATED`, `FAILED`, `RECEIVED`). Use `/v3/message/resend/{id}`. *This corrects the previous version of this runbook, which was wrong on both counts.*
- **Delivery still isn't reconciliation.** Even a `SENT` row leaves `orders.order_status = 27` — §5.3 is mandatory.
- `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` was `false` on `wms1-wineco-dev`. It does not gate `resendMessage`, but it does mean the automatic callback is off.
- Past PACKED there are **no reservations to release** and **no `pickfromstockunit_id`** — source locations must be reconstructed from `stockrecord` (§4.5b), and that reconstruction is **not reliable**: `PICKING` rows are keyed by an OMS pick-request id with no join path from the WMS order, the tote-label join is polluted by other orders sharing the tote, and `fromstoragelocation` may be an operator location rather than a rack. Treat return-to-source as best-effort, not guaranteed.
- Clearing is a holding location. The cancel does not return goods to sellable stock.
- Unlocking the parcel (§5.2 step 2) is normally a no-op — 20/20 stuck orders already had `entity_lock = 0`.
- BOL position cleanup is an open code TODO (`CustomerorderService.java:364`). Always run §7.J, and treat **any** non-`CLOSED` BOL state (incl. `TRUCK_LOADING`) as requiring the DELETE.
- Ticket-specific data validation still needs a **production** connection; the dev copy does not contain prod orders (OMS ids overlap across environments — `externalnumber` collisions there are coincidental, not the same order).

---

## 10. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-20 | Initial authoring against v1 code paths | Runbook created | nam.park |
| 2026-08-05 | Data validation on `wms1-wineco-dev` (`wh01_om1`, 405,045 orders, fresh to 2026-07-14) during SBDEV-2833: stuck-order population by batch type; parcel locks; shipped stockunits; BOL membership; `pickfromstockunit_id`; `message` status distribution; sysprop keys; clearing location | 20 orders at 650/670, **all PICK_PACK, 0 CLUB**, oldest 2025-04-23 · 0 shipped stockunits · 1 order on a `TRUCK_LOADING` BOL · `parcel.entity_lock = 0` on 20/20 · `pickfromstockunit_id` NULL on 52/52 picking positions · `sender='WMS'`: 1,223,576 SENT / 17 CREATED / 11 FAILED, incl. **5 `MSG-MANUAL-CANCEL-*` rows from Apr 2026 still unsent** · `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED = false` · `SYSTEM_WMS_NAME = 'WMS'`, `SYSTEM_OMS_NAME = 'OMS_om1'` · Clearing = id 1 | nam.park |
| 2026-08-05 | Executed the new §5.2 step-6 `json_build_object` payload and the §7.H2 query read-only against `wms1-wineco-dev` | Both run clean. Payload emits exactly the shape `LegacyWmsController::cancelPosition` validates: `{"facility_code":"wsl","batch_id":"41653-1","positions":[{"unique_id":"564401"}]}` | nam.park |
| 2026-08-05 | Attempted the §4.5b source reconstruction against order `051401-000004` / ext `562868` | **First draft of §4.5b was wrong and was rewritten.** `stockrecord.ordernumber` yields only `PACKAGING` rows (`amount = 0`, `from = FinishedPicking`) for every candidate key — WMS number, `externalnumber`, position `externalid`, picking-order number. `PICKING` rows carry an unjoinable OMS pick-request id (`756248`…); the only working link is `tounitload = historytote` + SKU/amount matching, and `fromstoragelocation` was an operator location (`danielvalentim`) under rapid picking | nam.park |

**Corrections applied 2026-08-05:** §5.2 step 6 payload (XML → JSON) and delivery mechanism (nonexistent outbox cron / invalid `RELEASED` status → `/v3/message/resend/{id}`); §5.2 step 6 `sender` (decoy `WMS_INSTANCE_NAME` → `SYSTEM_WMS_NAME`) and `receiver` (`'OMS'` → `SYSTEM_OMS_NAME`); §5.2 step 2 flagged as a no-op; §7.C expectation inverted (was asserting state 800 on picking positions, which fails on every correct run); §7.D removed as vacuous and replaced with a `stockrecord` check; new §4.5b (source reconstruction) and new **§5.3 (mandatory OMS reconciliation)**.

**Follow-up tickets this validation should generate:**
1. **No WMS→OMS cancel notification path on v1** — the manual row + resend dance is a workaround for missing product behaviour.
2. **`cancelPosition` never sets `orders.order_status`** — every WMS-initiated cancel leaves OMS order/parcel status divergent.
3. **Post-QA cancellation is unsupported end-to-end** — SBDEV-1892 stops pre-QA; SBDEV-1921 built the v2 reversal workflow (`OrderCancellationController` + `CancellationReversalService`); nothing bridges OMS 27 → cancelled on v1.
4. **Reconcile the April 2026 incident** — orders `564278`, `564279`, `564287`, `564290`, `564297` have unsent cancel messages; their OMS side may still be at 27.
