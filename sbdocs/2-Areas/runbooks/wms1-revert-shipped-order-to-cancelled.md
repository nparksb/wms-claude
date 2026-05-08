---
title: "Runbook: Revert a Mistakenly Shipped Order to CANCELED in WMS v1"
type: runbook
status: active
version: "wms-api v1 (Java 8, Spring Boot 2.3.7, PostgreSQL)"
scope: "v1/wms-api — undo an unintended ship (customerorder.state=700 or 800 with parcel on 'Shipped')"
owner: "nam.park@siteboss.net"
created: "2026-04-24"
updated: "2026-04-24"
last_verified: "2026-04-24"
verified_by: "nam.park@siteboss.net"
alert: "Ops / customer-service escalation: a WMS order was shipped after OMS had already cancelled it"
severity: "SEV3"
escalation: "WMS on-call engineer -> DB admin (for manual SQL) -> OMS on-call (for ORDER_BATCH_SHIPPED / cancellation reconciliation)"
related:
  - "[[wms1-cancel-packed-parcel]]"
tags:
  - runbook
  - wms1
  - cancellation
  - shipping
  - parcel
  - data-repair
---

# Runbook: Revert a Mistakenly Shipped Order to CANCELED in WMS v1

**Alert:** Ops / CS escalation — WMS shipped an order after OMS cancelled it | **Severity:** SEV3
**Scope:** `v1/wms-api` — `customerorder.state` in `{700 FINISHED, 800 CANCELED}` with the parcel still on `Shipped` location | **Version:** wms-api v1
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-04-24 (nam.park)

<!--
  Paired with: wms1-cancel-packed-parcel (which covers cancellation at PACKED/PALLETIZED BEFORE shipping).
  This runbook picks up when the order has already crossed into FINISHED / shipped
  and needs to be rolled back to CANCELED post-hoc.
-->

---

## 1. When to Use This Runbook

- Triggered by: Ops / CS reports that WMS shipped an order that OMS had cancelled, OR that an order was picked / packed / shipped despite an OMS cancel already being in flight.
- Use this when **all** of the following are true:
  - `customerorder.state` is `700` (FINISHED) **or** `800` (CANCELED with ship side-effects still in place from a partial prior fix).
  - `customerorder.parcel_id IS NOT NULL` and that parcel unit-load sits on the `Shipped` location with `entity_lock = 405` (SHIPPED).
  - OMS-side the order is cancelled (or should be).
- Do NOT use this runbook if:
  - `customerorder.state < 700` — the order has not shipped; use `wms1-cancel-packed-parcel` (if state ≥ 650) or the regular `POST /rest/order/cancelPositions` (if state < 650).
  - `state = 800 AND parcel_id IS NULL AND no billoflading_position for the order` — already cleanly cancelled, nothing to do.
  - The parcel is already off `Shipped` (someone partly reversed it) — diagnose the half-reversal first before re-running §5 blindly.
  - The truck has physically left and the boxes are on the road — this is a return flow, not a reversal.

---

## 2. Severity & Impact

| Aspect | Detail |
|--------|--------|
| User impact | OMS thinks the order is cancelled; WMS thinks it's shipped. Inventory is understated at the pick-from locations until reversed. Customer may receive a box OMS says was cancelled. |
| Blast radius | One customer order at a time. A wholesale-pallet move would drag sibling orders with it — the runbook is strict about scope. Incorrect SQL desyncs inventory for the affected SKUs. |
| Paging event? | No — schedule during a quiet window with DB admin present. |
| SLO burn? | Only via the customer-facing wrong-shipment exposure; DB itself is single-tenant. |

---

## 3. First 5 Minutes — Triage

- [ ] Confirm the symptom: OMS says cancelled, WMS says shipped. Pull the OMS-side `message` audit and the WMS `billoflading.shipped` date.
- [ ] Note `'<ORDER_NUMBER>'` (`customerorder.number`), `'<ORDER_EXT_NUMBER>'` (OMS unique_id), and `'<OPERATOR>'` (your username).
- [ ] Check whether the physical parcel is still on-site (outbound lane / Gate_*) or has been truck-loaded out. If out, stop — this is a return flow.
- [ ] Check for prior repair attempts: look for `modified` timestamps on `customerorder` / `stockunit` that post-date the ship but don't actually change `state` / `entity_lock` (see §4.8). A `stockrecord` with operator `db_manual_cancel:*` is the telltale sign.

---

## 4. Diagnosis — Run These First (Read-Only)

> **Placeholder substitution.** The SQL below uses quoted placeholder tokens that you hand-replace **before** pasting into your DB client. Do a find-and-replace in your editor:
>
> | Placeholder | Replace with | Example result |
> |---|---|---|
> | `'<ORDER_NUMBER>'` | the order's `customerorder.number`, keeping the surrounding single quotes | `'051617-000001'` |
> | `'<ORDER_EXT_NUMBER>'` | the OMS-side unique id, keeping the single quotes | `'564297'` |
> | `'<OPERATOR>'` | your DBA/operator username, keeping the single quotes | `'nam.park'` |
> | `'<SPECIFIC_PICKING_POSITION_NUMBER>'` | (only in §5.4-alt) a specific `pickingorder_position.number`, keeping the quotes | `'756961'` |
>
> Do NOT use `:NAME`-style client parameters — DBeaver / pgAdmin / JDBC handle those inconsistently and they do not substitute inside `DO $$ … $$` blocks. Hand-substitution is the portable choice.

Save every output to the ticket — §7 compares against these snapshots.

### 4.1 Order header sanity

```sql
SELECT co.id                AS customerorder_id,
       co.number,
       co.externalnumber,
       co.state              AS co_state,            -- expect 700 or 800
       co.entity_lock        AS co_entity_lock,
       co.parcel_id          AS parcel_unitload_id,
       co.pickingtote_id,
       co.historytote,
       co.markedforcancellation,
       co.pickingconfirmationsent,
       co.orderbatch_id,
       cob.number            AS batch_number,
       cob.type              AS batch_type,          -- typically PICK_PACK or REGULAR
       cob.state             AS batch_state,
       co.created, co.modified
FROM   customerorder co
JOIN   customerorder_batch cob ON cob.id = co.orderbatch_id
WHERE  co.number = '<ORDER_NUMBER>';
```

**Abort if** `co_state NOT IN (700, 800)`, or if `co_state = 800` but the parcel is *not* on `Shipped`. Treat `co_state = 800 AND parcel_id IS NULL AND no billoflading_position for the order` as "already cleanly cancelled — nothing to do."

### 4.2 Customer order positions

```sql
SELECT cop.id, cop.number, cop.externalid,
       cop.itemdata_id, it.item_nr AS sku,
       cop.amount, cop.amountpicked, cop.state
FROM   customerorder_position cop
JOIN   customerorder          co ON co.id = cop.order_id
LEFT   JOIN itemdata it ON it.id = cop.itemdata_id
WHERE  co.number = '<ORDER_NUMBER>'
ORDER  BY cop.index;
```

Expect every `state` to match the order header (700 or 800) and `amountpicked > 0` (otherwise the order can't physically have been shipped).

### 4.3 Picking order, positions, and picking-tote linkage

```sql
SELECT po.id AS pickingorder_id, po.number AS pickingorder_number, po.state AS po_state,
       pop.id AS pop_id, pop.number AS pop_number, pop.state AS pop_state,
       pop.amount, pop.amountpicked,
       pop.pickfromstockunit_id, pop.pickfromlocationname, pop.pickfromunitloadlabel,
       pop.picktounitload_id,
       pul.id AS pickingorder_unitload_id, pul.state AS pul_state,
       pul.unitload_id AS picking_tote_unitload_id, pul.historytote
FROM   customerorder             co
JOIN   customerorder_position    cop ON cop.order_id = co.id
JOIN   pickingorder_position     pop ON pop.customerorderposition_id = cop.id
JOIN   pickingorder              po  ON po.id = pop.pickingorder_id
LEFT   JOIN pickingorder_unitload pul ON pul.id = pop.picktounitload_id
WHERE  co.number = '<ORDER_NUMBER>'
ORDER  BY pop.number;
```

Capture:
- `pickingorder_id`s touched (usually 1, may be >1 for multi-tote picks — check whether any picking order is shared with other orders via §4.3b below).
- `pickfromstockunit_id` values (may be NULL — the pick flow clears them; §4.6 uses a label-based fallback).
- `picking_tote_unitload_id` (may be NULL on pick-pack; tote is cleaned up at finish time and its label is kept in `pul.historytote`).

#### 4.3b — Is the picking order shared with other orders?

```sql
SELECT po.id, po.number, po.state,
       count(DISTINCT cop.order_id) AS distinct_orders,
       array_agg(DISTINCT co.number) AS order_numbers
FROM   pickingorder po
JOIN   pickingorder_position pop ON pop.pickingorder_id = po.id
LEFT   JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
LEFT   JOIN customerorder co ON co.id = cop.order_id
WHERE  po.id IN (
  SELECT DISTINCT pop2.pickingorder_id
  FROM pickingorder_position pop2
  JOIN customerorder_position cop2 ON cop2.id = pop2.customerorderposition_id
  JOIN customerorder co2 ON co2.id = cop2.order_id
  WHERE co2.number = '<ORDER_NUMBER>')
GROUP BY po.id, po.number, po.state;
```

If `distinct_orders > 1`, the picking order is shared — §5.3 (cancel the picking order wholesale) must NOT run; only flip picking positions for this order. The default §5.3 SQL already guards against this.

### 4.4 Parcel unit-load and its tree

```sql
WITH co AS (
  SELECT id, number, parcel_id FROM customerorder WHERE number = '<ORDER_NUMBER>'
)
SELECT ul.id, ul.labelid, ul.carrierunitload_id, ul.storagelocation_id,
       loc.name AS current_location_name,
       ul.entity_lock, ul.type_id, ult.name AS unitload_type
FROM   unitload ul
JOIN   location loc ON loc.id = ul.storagelocation_id
LEFT   JOIN unitload_type ult ON ult.id = ul.type_id
WHERE  ul.id IN (SELECT parcel_id FROM co)
   OR  ul.carrierunitload_id IN (SELECT parcel_id FROM co);
```

Expect the parcel's `current_location_name = 'Shipped'` and `entity_lock = 405`.

If the parcel has `carrierunitload_id` set, pull the outbound pallet:

```sql
SELECT ul_pallet.id, ul_pallet.labelid, loc.name AS location, ul_pallet.entity_lock,
       (SELECT count(*) FROM unitload c WHERE c.carrierunitload_id = ul_pallet.id) AS child_count
FROM   unitload ul_parcel
JOIN   unitload ul_pallet ON ul_pallet.id = ul_parcel.carrierunitload_id
JOIN   location loc       ON loc.id = ul_pallet.storagelocation_id
WHERE  ul_parcel.id = (SELECT parcel_id FROM customerorder WHERE number = '<ORDER_NUMBER>');
```

**If `child_count > 1`** — the pallet carries sibling parcels of other orders. §5.1 defaults assume this case and detach only our parcel from the pallet. Never run a wholesale pallet move.

### 4.5 Stock units currently on the parcel

```sql
SELECT su.id AS stockunit_id,
       su.amount, su.reservedamount, su.entity_lock,
       su.itemdata_id, it.item_nr AS sku, it.name AS sku_name,
       su.unitload_id, ul.labelid AS unitload_label
FROM   stockunit su
JOIN   itemdata  it ON it.id = su.itemdata_id
JOIN   unitload  ul ON ul.id = su.unitload_id
WHERE  su.unitload_id IN (
  SELECT ul_child.id
  FROM   unitload ul_child
  WHERE  ul_child.carrierunitload_id = (SELECT parcel_id FROM customerorder WHERE number = '<ORDER_NUMBER>')
  UNION
  SELECT parcel_id FROM customerorder WHERE number = '<ORDER_NUMBER>'
);
```

`amount` per row is what has to be put back (per SKU) if choosing Option B.

### 4.6 Original pick-from stock units — do they still exist?

**Important:** after a successful pick, `pickingorder_position.pickfromstockunit_id` is commonly **NULL** — the FK is cleared by the pick/finish flow. The text fields `pickfromunitloadlabel` and `pickfromlocationname` are retained and are the authoritative way to re-identify the source. The query below resolves by **label + SKU** and falls back to the FK when it's still populated.

```sql
WITH coids AS (
  SELECT cop.id AS cop_id
  FROM   customerorder cop_co
  JOIN   customerorder_position cop ON cop.order_id = cop_co.id
  WHERE  cop_co.number = '<ORDER_NUMBER>'
)
SELECT pop.number AS picking_position,
       pop.pickfromstockunit_id,
       pop.pickfromlocationname   AS recorded_pickfrom_location,
       pop.pickfromunitloadlabel  AS recorded_pickfrom_unitload,
       pop.amount                  AS picked_amount,
       pop.itemdata_id,
       it.item_nr AS sku,
       COALESCE(su_fk.unitload_id,  ul_by_label.id)      AS resolved_src_unitload_id,
       COALESCE(ul_fk.labelid,      ul_by_label.labelid) AS resolved_src_unitload_label,
       COALESCE(loc_fk.name,        loc_by_label.name)   AS resolved_src_location,
       COALESCE(su_fk.id,           su_by_label.id)      AS resolved_src_stockunit_id,
       COALESCE(su_fk.amount,       su_by_label.amount)  AS resolved_src_amount_now,
       COALESCE(su_fk.entity_lock,  su_by_label.entity_lock) AS resolved_src_entity_lock,
       COALESCE(su_fk.reservedamount, su_by_label.reservedamount) AS resolved_src_reservedamount
FROM   pickingorder_position pop
JOIN   customerorder_position cop ON cop.id = pop.customerorderposition_id
JOIN   coids ON coids.cop_id = cop.id
LEFT   JOIN stockunit  su_fk         ON su_fk.id = pop.pickfromstockunit_id
LEFT   JOIN unitload   ul_fk         ON ul_fk.id = su_fk.unitload_id
LEFT   JOIN location   loc_fk        ON loc_fk.id = ul_fk.storagelocation_id
LEFT   JOIN unitload   ul_by_label   ON pop.pickfromstockunit_id IS NULL
                                    AND ul_by_label.labelid = pop.pickfromunitloadlabel
LEFT   JOIN stockunit  su_by_label   ON pop.pickfromstockunit_id IS NULL
                                    AND su_by_label.unitload_id = ul_by_label.id
                                    AND su_by_label.itemdata_id = pop.itemdata_id
LEFT   JOIN location   loc_by_label  ON pop.pickfromstockunit_id IS NULL
                                    AND loc_by_label.id = ul_by_label.storagelocation_id
LEFT   JOIN itemdata   it            ON it.id = pop.itemdata_id
ORDER  BY pop.number;
```

Per-row interpretation:
- `resolved_src_stockunit_id` non-null and `resolved_src_entity_lock = 0` → **Option B** (merge quantities back) is viable for this position.
- `resolved_src_stockunit_id` non-null, `resolved_src_entity_lock <> 0` → source is locked — decide per position: unlock-then-merge, or fall back to Option A.
- `resolved_src_stockunit_id` NULL → neither FK nor label+SKU resolves. Fall back to Option A for this position, or create a new stockunit explicitly on the recorded source unit-load (§5.4-alt).

### 4.7 Bill of Lading coverage

```sql
SELECT bol.id, bol.number, bol.type, bol.state, bol.shipped,
       bp.id AS bolp_id, bp.name AS bolp_name, bp.state AS bolp_state,
       bp.amount, bp.order_id, bp.orderposition_id, bp.source_id, bp.carrier_id
FROM   billoflading          bol
JOIN   billoflading_position bp  ON bp.billoflading_id = bol.id
WHERE  bp.order_id = (SELECT id FROM customerorder WHERE number = '<ORDER_NUMBER>')
   OR  bp.orderposition_id IN (
        SELECT cop.id FROM customerorder_position cop
         JOIN customerorder co ON co.id = cop.order_id
         WHERE co.number = '<ORDER_NUMBER>');

-- Also see if the BOL carries siblings (positions not tied to this order)
SELECT bp.id, bp.name, bp.state, bp.order_id, bp.orderposition_id, bp.source_id, bp.carrier_id
FROM   billoflading_position bp
WHERE  bp.billoflading_id IN (
  SELECT DISTINCT bp2.billoflading_id
  FROM   billoflading_position bp2
  WHERE  bp2.order_id = (SELECT id FROM customerorder WHERE number = '<ORDER_NUMBER>'));
```

If the BOL has rows that do **not** belong to our order, the runbook default holds: flip only our positions, leave the BOL header and sibling positions alone.

### 4.8 Audit-trail reference — what the ship already wrote

```sql
SELECT id, created, activitycode, recordtype, fromlocation, tolocation,
       label, fromunitload, tounitload, ordernumber, operator
FROM   unitload_record
WHERE  ordernumber = '<ORDER_NUMBER>'
   OR  label IN (
     SELECT labelid FROM unitload WHERE id IN (
       SELECT parcel_id FROM customerorder WHERE number = '<ORDER_NUMBER>'
       UNION
       SELECT id FROM unitload
        WHERE carrierunitload_id = (SELECT parcel_id FROM customerorder WHERE number = '<ORDER_NUMBER>')
     )
   )
ORDER  BY created DESC
LIMIT  50;

SELECT id, created, activitycode, type, itemdata, amount, amountstock,
       fromstoragelocation, tostoragelocation, fromunitload, tounitload,
       reservedamountchange, reservedamountstock, ordernumber, operator
FROM   stockrecord
WHERE  ordernumber = '<ORDER_NUMBER>'
ORDER  BY created DESC
LIMIT  50;
```

Look for: `activitycode = 'SHIPPING'` + `recordtype = 'TRANSFERRED'` rows as the ground truth of the ship; `activitycode = 'PICKING'` / `'PACKAGING'` rows as the ground truth of the pick; operator `db_manual_cancel:*` rows as evidence of prior repair attempts.

### 4.9 OMS message state (helps decide OMS reconciliation)

```sql
SELECT m.id, m.created, m.modified, m.status, m.process, m.sender, m.receiver,
       left(m.message, 500) AS msg_head
FROM   message m
WHERE  m.message LIKE '%<ORDER_NUMBER>%'
   OR  m.message LIKE '%<ORDER_EXT_NUMBER>%'
ORDER  BY m.created;
```

Look for `ORDER_BATCH_SHIPPED` (sent by WMS to OMS after shipping) and `ORDER_BATCH_CANCELLED_FROM_PSD` (received from OMS).

---

## 5. Recovery Actions

Decide Option A vs Option B **before** opening the transaction. Options may be chosen per picking position if §4.6 shows a mix of viable / non-viable source resolutions.

### 5.0 — Reversal options

**Option A — Minimal: send parcel to `Clearing`** (mirrors `CustomerorderService.forceCancelOrder` PACKED branch):
- Moves the parcel (and any descendants — almost never any for PICK_PACK) to `Clearing`.
- Sets `customerorder` / `customerorder_position` state to CANCELED.
- Unlocks `entity_lock` on parcel + stockunits on it.
- Does **not** return quantities to source stockunits — the operator physically breaks down the parcel at Clearing.
- Recommended when §4.6 shows any unresolved source, or when the pick-from locations have drifted.

**Option B — Full: return quantities to original pick-from stockunits**:
- Everything from Option A, plus:
- For each picking position, add the picked amount back to the resolved source stockunit (from §4.6).
- Zero-then-delete the stockunits on the parcel.
- Only valid if every position in §4.6 resolves a live source (`resolved_src_stockunit_id IS NOT NULL`).
- Riskier: rewrites live inventory rows. Always run inside `BEGIN…ROLLBACK` and verify §7 before `COMMIT`.

### 5.1 — Open transaction and guard

```sql
BEGIN;

-- 5.1.a: Pessimistic re-check. Run this SELECT inside the transaction. Eyeball the
-- output; if any expectation fails, run ROLLBACK; and re-diagnose.
--
-- Expectations (abort / ROLLBACK if any is violated):
--   * row count = 1
--   * co_state IN (700, 800)
--   * parcel_id IS NOT NULL
--   * current_location_name = 'Shipped'
--   * parcel_entity_lock = 405  (if not, continue but verify §7 output carefully)

SELECT co.id                 AS customerorder_id,
       co.number,
       co.state               AS co_state,
       co.parcel_id,
       loc.name               AS current_location_name,
       ul.entity_lock         AS parcel_entity_lock
  FROM customerorder co
  LEFT JOIN unitload  ul  ON ul.id  = co.parcel_id
  LEFT JOIN location  loc ON loc.id = ul.storagelocation_id
 WHERE co.number = '<ORDER_NUMBER>'
   FOR UPDATE OF co;
```

> **If the row returned violates any of the expectations above, run `ROLLBACK;` now and stop.** Do not proceed to §5.2. Re-run §4 diagnostics, understand what changed, and either revise the runbook or bail.

### 5.2 — Move parcel (+ its own descendants) back to `Clearing` (both options)

**Scope:** only the order's parcel unit-load and anything it directly carries. Never the pallet above it.

```sql
-- 5.2.a: Capture parcel + descendants (NOT the pallet above) into a temp table
CREATE TEMP TABLE tmp_ul_ids ON COMMIT DROP AS
WITH RECURSIVE subtree(id) AS (
  SELECT co.parcel_id AS id
    FROM customerorder co
   WHERE co.number = '<ORDER_NUMBER>'
     AND co.parcel_id IS NOT NULL
  UNION ALL
  SELECT c.id
    FROM unitload c
    JOIN subtree s ON c.carrierunitload_id = s.id
)
SELECT id FROM subtree;

-- 5.2.a-check: Eyeball this. Must be >= 1 (the parcel). For PICK_PACK orders
-- it's almost always exactly 1 (the parcel is a leaf). If 0, ROLLBACK — the
-- recursive CTE did not resolve the parcel.
SELECT count(*) AS tmp_ul_ids_row_count FROM tmp_ul_ids;

-- 5.2.b: Detach parcel from its outbound pallet (if any). Pallet stays on Shipped
-- with its original lock — it may legitimately carry other orders' parcels.
UPDATE unitload
   SET carrierunitload_id = NULL,
       modified = now(),
       version  = version + 1
 WHERE id = (SELECT parcel_id FROM customerorder WHERE number = '<ORDER_NUMBER>')
   AND carrierunitload_id IS NOT NULL;

-- 5.2.c: Move parcel subtree to Clearing + unlock entity_lock
WITH clearing AS (SELECT id FROM location WHERE name = 'Clearing')
UPDATE unitload
   SET storagelocation_id = (SELECT id FROM clearing),
       entity_lock        = 0,                 -- NOT_LOCKED
       modified           = now(),
       version            = version + 1
 WHERE id IN (SELECT id FROM tmp_ul_ids);

-- 5.2.d: Unlock stockunits on the parcel subtree
UPDATE stockunit
   SET entity_lock = 0,
       modified    = now(),
       version     = version + 1
 WHERE unitload_id IN (SELECT id FROM tmp_ul_ids);

-- 5.2.e: Audit trail — one unitload_record per moved unit-load
INSERT INTO unitload_record
  (id, version, entity_lock, created, modified,
   activitycode, recordtype, label, operator,
   fromlocation, tolocation, fromunitload, tounitload, unitloadtype,
   ordernumber, additionalcontent, client_id)
SELECT nextval('seqentities'),
       1, 0, now(), now(),
       'MANUAL_ADJUSTMENT',
       'TRANSFERRED',
       ul.labelid,
       '<OPERATOR>',
       'Shipped',
       'Clearing',
       NULL,                                   -- parent already nulled in 5.2.b
       NULL,
       ult.name,
       '<ORDER_NUMBER>',
       'Revert of mistaken ship — runbook wms1-revert-shipped-order-to-cancelled.md',
       ul.client_id
FROM   unitload ul
JOIN   unitload_type ult ON ult.id = ul.type_id
WHERE  ul.id IN (SELECT id FROM tmp_ul_ids);
```

> **Sequence name — verify before running.** v1/wms-api uses `seqentities` on `wms1-wineco-dev`. Confirm with:
> `SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public';`
> Patch every `nextval('seqentities')` if a different DB uses a different name.

### 5.3 — Reset order + position + picking states (both options)

```sql
-- 5.3.a: Customer order positions -> CANCELED
UPDATE customerorder_position
   SET state    = 800,
       modified = now(),
       version  = version + 1
 WHERE order_id = (SELECT id FROM customerorder WHERE number = '<ORDER_NUMBER>');

-- 5.3.b: Customer order -> CANCELED. Keep parcel_id set (matches built-in
-- PACKED cancel behavior); clear pickingtote_id only if still set.
UPDATE customerorder
   SET state          = 800,
       historytote    = COALESCE(historytote,
                                  (SELECT labelid FROM unitload
                                    WHERE id = customerorder.parcel_id)),
       pickingtote_id = NULL,
       modified       = now(),
       version        = version + 1
 WHERE number = '<ORDER_NUMBER>';

-- 5.3.c: Picking positions -> CANCELED
UPDATE pickingorder_position pop
   SET state    = 800,
       modified = now(),
       version  = version + 1
 WHERE pop.customerorderposition_id IN (
    SELECT cop.id FROM customerorder_position cop
     JOIN customerorder co ON co.id = cop.order_id
     WHERE co.number = '<ORDER_NUMBER>');

-- 5.3.d: pickingorder_unitload -> CANCELED
UPDATE pickingorder_unitload pul
   SET state       = 800,
       historytote = COALESCE(historytote, pul.customerordernumber),
       unitload_id = NULL,
       modified    = now(),
       version     = version + 1
 WHERE pul.customerordernumber = '<ORDER_NUMBER>';

-- 5.3.e: pickingorder -> CANCELED ONLY if ALL its positions are now CANCELED.
-- Leaves shared picking orders alone.
UPDATE pickingorder po
   SET state    = 800,
       modified = now(),
       version  = version + 1
 WHERE po.id IN (
    SELECT DISTINCT pop.pickingorder_id
    FROM pickingorder_position pop
    JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
    JOIN customerorder co            ON co.id = cop.order_id
    WHERE co.number = '<ORDER_NUMBER>'
  )
  AND NOT EXISTS (
    SELECT 1 FROM pickingorder_position pop2
     WHERE pop2.pickingorder_id = po.id AND pop2.state <> 800);
```

> **Optional variant — null `parcel_id`.** `CustomerorderService.forceCancelOrder` (PACKED branch, `CustomerorderService.java:334-356`) does NOT null `parcel_id`. The default above mirrors that. If a downstream consumer cannot deal with a CANCELED order that still has `parcel_id`, add `parcel_id = NULL,` to the UPDATE in 5.3.b.

### 5.4 — Bill of Lading: flip only this order's positions (both options)

BOL positions form a tree: parcel-level (`source_id` = parcel, `order_id` = customer order), stock-level children (`orderposition_id` set, `carrier_id` = parcel-level BOL position id), and the top-level pallet position (`source_id` = pallet, no order_id/orderposition_id). Cancel only this order's parcel-level and stock-level positions — never the pallet position or sibling orders' positions or the BOL header.

```sql
WITH our_order AS (
  SELECT id FROM customerorder WHERE number = '<ORDER_NUMBER>'
), our_positions AS (
  SELECT cop.id FROM customerorder_position cop
    JOIN our_order oo ON oo.id = cop.order_id
)
UPDATE billoflading_position bp
   SET state    = 'CANCELLED',
       modified = now(),
       version  = version + 1
 WHERE bp.order_id IN (SELECT id FROM our_order)
    OR bp.orderposition_id IN (SELECT id FROM our_positions);
```

**Do NOT** flip `billoflading.state`, the pallet-level BOL position, or sibling positions. The BOL's `shipped` date stays set — it records a real truck event.

> Exception: if §4.7 shows the BOL is 100% this order (no sibling positions at all) AND the user requests full BOL rollback, a separate one-off `UPDATE billoflading ... SET state='CANCELLED'` is safe. Default is "leave the BOL header alone."

### 5.5 — Option B only: return quantities to source stock units

Skip to §5.6 if running Option A. Run §5.5 only if every row of §4.6 resolves a live `resolved_src_stockunit_id`.

```sql
-- 5.5.a: Add picked amount back to the resolved source stockunit for each picking position
WITH resolved_sources AS (
  SELECT pop.id      AS pop_id,
         pop.amount  AS picked_amount,
         pop.itemdata_id,
         COALESCE(pop.pickfromstockunit_id,
                  (SELECT su.id
                     FROM stockunit su
                     JOIN unitload  ul ON ul.id = su.unitload_id
                    WHERE ul.labelid    = pop.pickfromunitloadlabel
                      AND su.itemdata_id = pop.itemdata_id
                    LIMIT 1))                       AS src_stockunit_id
    FROM pickingorder_position pop
    JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
    JOIN customerorder          co  ON co.id  = cop.order_id
   WHERE co.number = '<ORDER_NUMBER>'
)
UPDATE stockunit src_su
   SET amount   = src_su.amount + rs.picked_amount,
       modified = now(),
       version  = version + 1
  FROM resolved_sources rs
 WHERE src_su.id = rs.src_stockunit_id
   AND rs.src_stockunit_id IS NOT NULL;

-- 5.5.b: Guard — compare expected vs resolved picking positions.
-- Eyeball the output. Must have expected_positions = resolved_positions.
-- If they differ, run ROLLBACK; and either (a) re-check §4.6 for the
-- unresolved rows, (b) fall back to Option A for those positions, or
-- (c) insert new source stockunits via §5.4-alt.
SELECT
  (SELECT count(*)
     FROM pickingorder_position pop
     JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
     JOIN customerorder          co  ON co.id  = cop.order_id
    WHERE co.number = '<ORDER_NUMBER>') AS expected_positions,
  (SELECT count(*)
     FROM pickingorder_position pop
     JOIN customerorder_position cop ON cop.id = pop.customerorderposition_id
     JOIN customerorder          co  ON co.id  = cop.order_id
    WHERE co.number = '<ORDER_NUMBER>'
      AND COALESCE(pop.pickfromstockunit_id,
                   (SELECT su.id
                      FROM stockunit su
                      JOIN unitload  ul ON ul.id = su.unitload_id
                     WHERE ul.labelid    = pop.pickfromunitloadlabel
                       AND su.itemdata_id = pop.itemdata_id
                     LIMIT 1)) IS NOT NULL) AS resolved_positions;

-- 5.5.c: Audit record for the put-back, one row per picking position
INSERT INTO stockrecord
  (id, version, entity_lock, created, modified,
   activitycode, type, itemdata, operator, ordernumber, scale,
   amount, amountstock, reservedamountchange, reservedamountstock,
   fromstoragelocation, tostoragelocation, fromunitload, tounitload,
   fromstockunitidentity, tostockunitidentity, unitloadtype, client_id)
SELECT nextval('seqentities'),
       1, 0, now(), now(),
       'MANUAL_ADJUSTMENT',
       'STOCK_ALTERED',
       it.item_nr,
       '<OPERATOR>',
       '<ORDER_NUMBER>',
       it.scale,
       pop.amount,
       src_su.amount,                             -- post-update (already incremented by 5.5.a)
       NULL,
       src_su.reservedamount,
       'Shipped',
       src_loc.name,
       parcel_ul.labelid,
       src_ul.labelid,
       'SU-' || src_su.id::text,
       'SU-' || src_su.id::text,
       src_ult.name,
       co.client_id
  FROM customerorder           co
  JOIN customerorder_position  cop ON cop.order_id = co.id
  JOIN pickingorder_position   pop ON pop.customerorderposition_id = cop.id
  JOIN stockunit               src_su ON src_su.id = COALESCE(
         pop.pickfromstockunit_id,
         (SELECT su.id
            FROM stockunit su
            JOIN unitload  ul ON ul.id = su.unitload_id
           WHERE ul.labelid    = pop.pickfromunitloadlabel
             AND su.itemdata_id = pop.itemdata_id
           LIMIT 1))
  JOIN unitload                src_ul ON src_ul.id = src_su.unitload_id
  JOIN location                src_loc ON src_loc.id = src_ul.storagelocation_id
  LEFT JOIN unitload_type      src_ult ON src_ult.id = src_ul.type_id
  LEFT JOIN unitload           parcel_ul ON parcel_ul.id = co.parcel_id
  LEFT JOIN itemdata           it ON it.id = cop.itemdata_id
 WHERE co.number = '<ORDER_NUMBER>';

-- 5.5.d: Drop the stockunits that were on the parcel (their amount has moved back to source)
UPDATE stockunit
   SET amount   = 0,
       modified = now(),
       version  = version + 1
 WHERE unitload_id IN (SELECT id FROM tmp_ul_ids);

DELETE FROM stockunit
 WHERE unitload_id IN (SELECT id FROM tmp_ul_ids)
   AND amount = 0
   AND (reservedamount IS NULL OR reservedamount = 0);
```

> Option B assumes each picking position resolves to a single source stockunit (one SKU per position). Multi-source picks (same position split across multiple source stockunits) must be handled per-position manually.

> **§5.4-alt — recreate a stockunit when no live source exists.** If §4.6 shows a position whose source unit-load still exists but whose stockunit has been drained/deleted, insert a new stockunit on the source unit-load instead of updating:
>
> ```sql
> INSERT INTO stockunit (id, version, entity_lock, created, modified,
>                        amount, reservedamount, client_id, itemdata_id, unitload_id)
> SELECT nextval('seqentities'), 1, 0, now(), now(),
>        pop.amount, 0, co.client_id, pop.itemdata_id, src_ul.id
>   FROM customerorder co
>   JOIN customerorder_position cop ON cop.order_id = co.id
>   JOIN pickingorder_position  pop ON pop.customerorderposition_id = cop.id
>   JOIN unitload               src_ul ON src_ul.labelid = pop.pickfromunitloadlabel
>  WHERE co.number = '<ORDER_NUMBER>'
>    AND pop.number = '<SPECIFIC_PICKING_POSITION_NUMBER>';
> ```

### 5.6 — Verify (§7) then COMMIT (or ROLLBACK)

```sql
-- Only after §7 verification queries look right:
COMMIT;
-- Otherwise:
-- ROLLBACK;
```

---

## 6. Escalation

| When | Who | How |
|------|-----|-----|
| §5.1 guard aborts with unexpected state | WMS on-call | Re-run §4 diagnostics; file incident with dump |
| §5.5.b guard aborts (Option B source unresolved) | WMS on-call + DB admin | Switch to Option A for affected positions, document in ticket |
| Any §5 DML fails with a FK / version error | DB admin | `ROLLBACK` immediately, diagnose before re-running |
| BOL already reported `ORDER_BATCH_SHIPPED` to OMS | OMS on-call | Coordinate corrective cancel message / manual OMS reconciliation |
| Physical parcel has already left on a truck | Ops manager | This is a return flow, not a reversal — abort this runbook |

---

## 7. Verification — Confirm Resolved (run BEFORE `COMMIT`)

Run these inside the open transaction. Every result should match expectations before committing.

```sql
-- 7.1 Order + positions are CANCELED
SELECT co.number, co.state AS co_state, co.entity_lock, co.parcel_id, co.pickingtote_id,
       (SELECT string_agg(state::text, ',') FROM customerorder_position WHERE order_id = co.id) AS cop_states
FROM   customerorder co WHERE co.number = '<ORDER_NUMBER>';
-- expect: co_state=800, every cop_state=800

-- 7.2 Parcel unitload is on Clearing and unlocked (pallet above — if any — still on Shipped, still locked)
SELECT ul.id, ul.labelid, loc.name AS location, ul.entity_lock, ul.carrierunitload_id
FROM   unitload ul JOIN location loc ON loc.id = ul.storagelocation_id
WHERE  ul.id IN (SELECT id FROM tmp_ul_ids);
-- expect: location='Clearing', entity_lock=0, carrierunitload_id IS NULL on the parcel

-- 7.3 Picking entities cancelled (where applicable)
SELECT po.number, po.state AS po_state,
       (SELECT string_agg(state::text, ',') FROM pickingorder_position pop
         WHERE pop.pickingorder_id = po.id
           AND pop.customerorderposition_id IN (
             SELECT cop.id FROM customerorder_position cop
              JOIN customerorder co ON co.id = cop.order_id
              WHERE co.number = '<ORDER_NUMBER>')) AS pop_states
FROM   pickingorder po
WHERE  po.id IN (
  SELECT DISTINCT pop2.pickingorder_id FROM pickingorder_position pop2
  JOIN customerorder_position cop ON cop.id = pop2.customerorderposition_id
  JOIN customerorder co ON co.id = cop.order_id
  WHERE co.number = '<ORDER_NUMBER>');
-- expect: pop_states all 800; po_state 800 only if pickingorder is not shared

-- 7.4 BOL positions cancelled; BOL header untouched
SELECT bp.name, bp.state, bp.order_id, bp.orderposition_id
FROM   billoflading_position bp
WHERE  bp.billoflading_id = (
  SELECT bp2.billoflading_id FROM billoflading_position bp2
   WHERE bp2.order_id = (SELECT id FROM customerorder WHERE number = '<ORDER_NUMBER>') LIMIT 1)
ORDER BY bp.id;
-- expect: our positions (order_id = our order OR orderposition_id in our positions) = 'CANCELLED';
--         sibling/pallet rows untouched; BOL header state unchanged

-- 7.5 (Option B only) Source stockunit amounts went up by the correct delta
-- Compare against §4.6 snapshot taken before §5.

-- 7.6 Parcel has no stockunits (Option B) OR parcel stockunits still present (Option A)
SELECT count(*) FROM stockunit WHERE unitload_id IN (SELECT id FROM tmp_ul_ids);
-- expect: 0 under Option B; unchanged count under Option A
```

---

## 8. Post-incident

- [ ] `COMMIT` only if every §7 check is clean, else `ROLLBACK` and re-diagnose.
- [ ] File an OMS-side reconciliation ticket if `ORDER_BATCH_SHIPPED` was already sent.
- [ ] Physically pull the parcel from the outbound lane: Option A → break it down at Clearing; Option B → restock the items at the recorded pick-from locations.
- [ ] Schedule a cycle count on the affected SKU(s) to confirm on-hand matches system.
- [ ] Open / update the root-cause ticket: **why did WMS advance a cancelled order past PACKED?** Likely candidates:
  - OMS cancel message was `RECEIVED` but not yet `PROCESSING`d before WMS close-BOL ran.
  - `markedforcancellation` flag was not read at ship time.
  - Cancel and ship raced across transactions.
  - `BillofladingService.closeBillOfLading` bulk-updates `customerorder.state` via `customerorderRepository.updateStateByIds(FINISHED, …)` with **no state guard** — it will overwrite a CANCELED order back to FINISHED if its parcel is still on an open BOL.
- [ ] Update `last_verified` / `verified_by` in this runbook's frontmatter.
- [ ] Add the incident to the related-incidents list in §9 below, with the incident plan file path.

---

## 9. Related Docs

- Sibling runbook: `[[wms1-cancel-packed-parcel]]` — cancel at PACKED/PALLETIZED **before** shipping.
- Source code:
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` — `closeBillOfLading(...)` phases 4–7, lines ~280–549 (the flow this runbook reverses).
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java` — `transferPalletTreesToLocation(...)`, lines ~277–418.
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` — `finishPickingOrder(...)`, lines ~100–205.
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java` — `forceCancelOrder` PACKED branch, lines 334–356 (the logical template for the reversal).
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java` — `State`, `BusinessObjectLockState`, activity codes.
- Schema: `v1/wms-api/src/main/resources/db/migration/V1.0.01__wms_tables.sql` — `customerorder`, `pickingorder*`, `unitload`, `stockunit`, `billoflading*`, `unitload_record`, `stockrecord`.
- Past incidents using this runbook:
  - 2026-04-24 — order `051617-000001` (wineco dev). Plan: `1-Projects/wms1/plan/260423-revert-mistakenly-shipped-order-to-cancelled.md`.
