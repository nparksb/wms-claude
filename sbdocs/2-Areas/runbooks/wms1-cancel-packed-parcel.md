---
title: "Runbook: Cancel a Packed Parcel in WMS v1 (past QA)"
type: runbook
status: active
version: "wms-api v1 (Java 8, Spring Boot 2.3.7, PostgreSQL)"
scope: "v1/wms-api — order/parcel cancellation when order state >= PACKED (650)"
owner: "nam.park@siteboss.net"
created: "2026-04-20"
updated: "2026-04-20"
last_verified: "2026-04-20"
verified_by: "nam.park@siteboss.net"
alert: "Manual cancellation request for a post-QA parcel (support / ops escalation)"
severity: "SEV3"
escalation: "WMS on-call engineer -> DB admin (for manual SQL) -> OMS on-call (for message reconciliation)"
related:
  - "[[wms-testing-smoke-test-checklist]]"
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
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-04-20 (nam.park)

<!--
  Runbook for manually cancelling a customer order whose state is past QA
  (PACKED / PALLETIZED). The REST API blocks this for PICK_PACK batches, so
  the steps below combine code-path decisions with raw SQL fallbacks.
-->

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
- `bol_state = 'OPEN'` → you must delete the `billoflading_position` as part of the cancel (the code does **not** do this — see TODO at `CustomerorderService.java:364`).
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
- Record `reservedamount` per stockunit as a **pre-cancel baseline**. You will diff this in §7 to confirm the release happened.

### 4.6 Look up the "clearing" location id (needed for §5.2)

```sql
SELECT id, name FROM location WHERE name ILIKE '%clearing%';
```
- Record the id — you will set `unitload.storagelocation_id` to this in §5.2.

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
\set clearing_location   42     -- from §4.6
\set system_user_id      1      -- from mywms_user
\set operator_audit      'db_manual_cancel:nam.park@<ticket-id>'

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

-- 6. Emit the OMS cancellation message
INSERT INTO message (
  id, version, created, modified, client_id, operator_id,
  number, process, status, sender, receiver, destination,
  resent, message
)
SELECT
  nextval('seqentities'), 0, now(), now(), co.client_id, :system_user_id,
  'MSG-MANUAL-CANCEL-' || co.number,
  'ORDER_BATCH_CANCELLED_FROM_WMS',
  'CREATED', 'WMS', 'OMS',
  (SELECT sysvalue FROM los_sysprop
    WHERE syskey = 'WEBSERVICE_ORDER_BATCH_CANCELLED'
      AND workstation = 'DEFAULT'
    LIMIT 1),  -- key is WEBSERVICE_ORDER_BATCH_CANCELLED (no _URL suffix)
  false,
  '<manual_cancel><externalnumber>' || co.externalnumber || '</externalnumber></manual_cancel>'
FROM customerorder co
WHERE co.id = :order_id;

-- ---- Re-run §7 verification queries inside this txn ----
-- If any query fails expectations, ROLLBACK. Otherwise COMMIT.
COMMIT;
```

**After COMMIT:** check that the message outbox picks up the new `message` row and posts to OMS. If the outbox cron is stuck, set `status = 'RELEASED'` manually after confirmation.

---

## 6. Escalation

| When | Who | How |
|------|-----|-----|
| Any `stockunit.entity_lock = 405` (SHIPPED) in the parcel | Warehouse floor lead + OMS on-call | Switch to a return / short-ship flow; do NOT proceed with cancellation |
| `billoflading.state = 'CLOSED'` for the order's BOL | Shipping lead | Confirm if truck has left; if yes, return flow; if no, un-close BOL first |
| OMS `message` row stuck in `FAILED` after §5.1 or §5.2 | OMS on-call | They retry the webhook; if it keeps failing, they hand-adjust the OMS order |
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
-- C. Picking positions are CANCELED and no longer hold pickfromstockunit_id
SELECT pop.id, pop.state, pop.pickfromstockunit_id
FROM pickingorder_position pop
JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
WHERE cop.order_id = :order_id
  AND (pop.state <> 800 OR pop.pickfromstockunit_id IS NOT NULL);
-- EXPECT: zero rows
```

```sql
-- D. Reserved stock released (diff against §4.5 baseline)
SELECT su.id, su.amount, su.reservedamount
FROM stockunit su
WHERE su.id IN (
  SELECT DISTINCT pop.pickfromstockunit_id
  FROM pickingorder_position pop
  JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
  WHERE cop.order_id = :order_id
);
-- EXPECT: reservedamount lower than in §4.5 by the total picked quantity
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
-- EXPECT: at least one row. status = SENT (FROM_WMS success) or RECEIVED (FROM_PSD inbound).
-- status = FAILED -> investigate with OMS on-call.
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

OMS-side verification (outside WMS DB):
- [ ] OMS order status moved out of PICKING/PACKED and reflects the cancellation.
- [ ] OMS inventory counts updated for affected SKUs.
- [ ] Customer-facing order in the storefront shows cancelled / voided.

---

## 8. Post-incident

- [ ] Attach queries A–J output to the ticket.
- [ ] Record total reserved stock released (sum of §4.5 baseline diff) for inventory reconciliation.
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

**Known limitations / caveats:**
- There is no `cancelled_by` or `cancelled_at` column. Audit trail is `customerorder.modified` + `stockrecord.operator`.
- `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` may be `false` in some envs — confirm before relying on the outbound webhook.
- The outbox cron pushes `message` rows with `status = 'RELEASED'`; a fresh manual row starts at `'CREATED'` and may need a status bump.
- BOL position cleanup is an open code TODO (`CustomerorderService.java:364`). Always run §7.J.
