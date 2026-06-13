---
title: "Runbook: Release an Orphaned Stock Reservation Blocking a Shipment (WMS v1)"
type: runbook
status: active
version: "wms-api v1 (Java 8, Spring Boot 2.3.7, PostgreSQL)"
scope: "v1/wms-api — pick line stuck on 'Not enough stock on location' because stockunit.reservedamount is held by no live order"
owner: "nam.park@siteboss.net"
created: "2026-06-01"
updated: "2026-06-01"
last_verified: "2026-06-01"
verified_by: "nam.park@siteboss.net"
alert: "Ops/CS: 'Not enough stock on location' on a pick line while the SKU Location Report shows stock present (Total = Reserved). Shipment blocked."
severity: "SEV2"
escalation: "WMS on-call engineer -> DB admin (for the reservedamount correction) -> warehouse floor lead (physical count confirmation)"
related:
  - "[[wms1-cancel-packed-parcel]]"
  - "[[260601-wineco-replenishment-pickpack-source-and-order-count]]"
  - "[[wms1-replenish-order-creation]]"
  - "[[wms1-move-stock-unitload-workflow]]"
tags:
  - runbook
  - wms1
  - replenish
  - reservation
  - data-repair
  - inventory
---

# Runbook: Release an Orphaned Stock Reservation Blocking a Shipment (WMS v1)

**Alert:** "Not enough stock on location" on a pick line while stock is physically present and fully reserved | **Severity:** SEV2
**Scope:** `v1/wms-api` — a `stockunit` whose `reservedamount` is held by no live picking/replenish order | **Version:** wms-api v1
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-06-01 (nam.park)

<!--
  A pick line cannot allocate because available = amount - reservedamount = 0,
  but the reservation belongs to nothing live (orphaned/leaked reservation).
  The physical bottles are on the shelf; only the reservation number is wrong.
  This runbook releases the bogus reservation so the order can ship today, then
  points at the follow-up investigation for the leak's root cause.
-->

---

## 1. When to Use This Runbook

Use this when **all** of the following are true:

- A pick line / parcel is stuck with **"Not enough stock on location"** (mobile picking or parcel detail).
- The **SKU Location Report** shows the SKU present on a pick face with **Total Qty = Reserved Qty** (so available = 0).
- Diagnosis (§4) shows the `reservedamount` is held by **no open picking order and no open replenish order** — i.e. the reservation is orphaned.
- The bottles are **physically on the shelf** (floor confirms, or there is no SHIPPED lock).

Do **NOT** use this runbook if:

- The reservation traces to a **live** open picking order or replenish order (§4.3 returns rows) — that is a real allocation; resolve the holding order instead, or it is a genuine shortage.
- `stockunit.entity_lock = 405` (SHIPPED) — the stock has left; use a return flow.
- The SKU genuinely has **no physical stock** anywhere (Total = 0) — this is a true shortage; replenish or receive stock, not a data repair.
- The reservation is a normal in-flight pick that will release on its own within minutes.

> This is a **reporting/data-state** repair. It is unrelated to the Replenishment Monitor's "counts pick-pack as replenishable" display bug (see [[260601-wineco-replenishment-pickpack-source-and-order-count]] §5.3 and the bugfix plan) — that fix does **not** unblock a shipment.

---

## 2. Severity & Impact

| Aspect | Detail |
|--------|--------|
| User impact | One (or more) order lines cannot be picked → parcel stays On Hold → shipment misses its truck. |
| Blast radius | One `stockunit` at a time (single-tenant DB). A wrong `reservedamount` write can over- or under-reserve real stock for other orders. |
| Is it a paging event? | Treat as **SEV2** when a same-day shipment is blocked. Do the correction with a DB admin present. |
| Side effect of the leak | The orphaned reservation also makes the stock **invisible to auto-replenishment**: the source query requires `reservedamount = 0` (`StockunitRepository.java:109` `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage`), so a leaked reservation silently removes the unit as a replenish source too. |

---

## 3. First 5 Minutes — Triage

- [ ] Capture the request source (ticket id, requester, **ship-by deadline**).
- [ ] Get the blocked **SKU number** (`itemdata.item_nr`), the **location** shown on the SKU report, and the **order/parcel** number.
- [ ] Identify tenant + facility (sets `tenant_name` / `facility_code` for the DB connection / app context).
- [ ] Ask the floor lead to **confirm the bottles are physically on the shelf** at that location.
- [ ] Open a **read-only** DB session against the correct tenant schema first. Do not write anything until §4 confirms the reservation is orphaned.

---

## 4. Diagnosis — Is the Reservation Really Orphaned?

Run queries **in order**. Replace `:item_nr` and `:client_id` (or use the location name). Everything here is read-only.

### 4.1 Find the stock unit and its availability

```sql
SELECT su.id  AS stockunit_id,
       su.amount,
       su.reservedamount,
       (su.amount - su.reservedamount) AS available,
       su.entity_lock,                 -- 405 = SHIPPED -> STOP (return flow)
       su.version,                     -- @Version optimistic-lock column; bump on write
       ul.labelid                      AS unitload_label,
       loc.name                        AS location_name,
       la.name                         AS area_name,
       la.useforpicking, la.useforreplenish
FROM stockunit su
JOIN unitload ul       ON su.unitload_id = ul.id
JOIN location loc      ON ul.storagelocation_id = loc.id
JOIN location_area la  ON loc.area_id = la.id
JOIN itemdata i        ON su.itemdata_id = i.id
WHERE i.item_nr = :item_nr
  AND i.client_id = :client_id
  AND su.entity_lock = 0;
```

- Record `stockunit_id`, `amount`, `reservedamount`, `version`. **You need these below.**
- `available = 0` with `amount > 0` is the symptom. If `available > 0`, the line should pick — look elsewhere.
- `entity_lock = 405` → **STOP**, escalate (§6).

### 4.2 Confirm the physical demand is small relative to what's reserved

```sql
-- How much of this SKU does live demand actually need right now?
SELECT co.number AS order_number, co.state AS order_state,
       cop.state AS pos_state, cop.amount AS needed
FROM customerorder_position cop
JOIN customerorder co ON co.id = cop.order_id
JOIN itemdata i       ON i.id = cop.itemdata_id
WHERE i.item_nr = :item_nr AND i.client_id = :client_id
  AND cop.state < 200            -- not yet picked/allocated
ORDER BY co.prio DESC, co.pickingdate;
```

- A large `reservedamount` (e.g. all 11) against tiny open demand (e.g. 2) is the classic leak fingerprint.

### 4.3 The decisive test — is ANY live order holding the reservation?

```sql
-- (a) Open PICKING positions pointing at this stockunit
SELECT pop.id, pop.state, pop.amount, pop.amountpicked,
       po.number AS picking_order_number, po.state AS picking_order_state
FROM pickingorder_position pop
LEFT JOIN pickingorder po ON po.id = pop.pickingorder_id
WHERE pop.pickfromstockunit_id = :stockunit_id
  AND pop.state < 700;          -- < FINISHED = still actively reserving

-- (b) Open REPLENISH orders sourcing from this stockunit
SELECT ro.id, ro.number, ro.state, ro.requestedamount
FROM replenishorder ro
WHERE ro.stockunit_id = :stockunit_id
  AND ro.state < 600;
```

- **Both return zero rows → the reservation is ORPHANED.** Proceed to §5.
- **Any rows → NOT orphaned.** The reservation is legitimate (or a stuck order). Do **not** zero it; resolve the holding order (see [[wms1-cancel-packed-parcel]]) or treat as a real allocation. Sum `amount - amountpicked` (picks) + `requestedamount` (replenish) = the **legitimate** reservation; that becomes your target in §5 instead of 0.

> Note: this DB has **no reservation/transaction log table** — only `stockunit.reservedamount` holds the number (verified 2026-06-01). §4.3 is therefore the authoritative orphan test; there is no audit trail to consult.

---

## 5. Recovery Actions

Pick **one**. Option A is the fastest and most direct; Option B avoids a DB write; Option D is the physical-first fallback. In all cases, the goal is: **release the bogus reservation so `available` covers the order's need.**

### 5.1 Option A — Correct `reservedamount` (supervised DB write, preferred for "ship today")

**Preconditions:** §4.1 `entity_lock = 0`; §4.3 (a) **and** (b) returned zero rows; DB admin on the call; floor confirmed physical stock.

Set `reservedamount` to the **legitimate** held amount — `0` when §4.3 is empty (orphaned), or the computed sum if some live holders exist. Always inside a transaction; re-run §7 before `COMMIT`.

```sql
BEGIN;

-- psql variables — adjust for your client
\set stockunit_id   985079706
\set target_reserved 0          -- 0 when §4.3 is empty; else the computed legitimate sum

-- 1. Re-assert the orphan test INSIDE the txn (guard against a race with a new pick)
SELECT count(*) AS live_holders
FROM (
  SELECT 1 FROM pickingorder_position WHERE pickfromstockunit_id = :stockunit_id AND state < 700
  UNION ALL
  SELECT 1 FROM replenishorder        WHERE stockunit_id          = :stockunit_id AND state < 600
) h;
-- EXPECT live_holders = 0 (for an orphaned reservation). If not 0 -> ROLLBACK.

-- 2. Lock the row, snapshot, correct it, bump @Version
SELECT id, amount, reservedamount, version
FROM stockunit WHERE id = :stockunit_id FOR UPDATE;   -- mirrors findByIdForUpdate (StockunitRepository.java:30-32)

UPDATE stockunit
SET reservedamount = :target_reserved,
    version        = version + 1,                      -- entity has @Version; keep it consistent
    modified       = now()
WHERE id = :stockunit_id;

-- 3. Audit row (mirrors what StockunitBusinessService.changeReservedAmount writes).
--    Confirm stockrecord columns first:  \d stockrecord
INSERT INTO stockrecord (
  id, version, created, modified, client_id,
  activitycode, operator, ordernumber, type, additionalcontent
)
SELECT nextval('seqentities'), 0, now(), now(), su.client_id,
       'STOCK_RESERVED_CHANGED',
       'db_manual_resv_fix:nam.park@<ticket-id>',
       NULL, 'STOCK_ALTERED',
       'Manual release of orphaned reservation on stockunit ' || su.id
         || ' (was ' || su.reservedamount || ' -> ' || :target_reserved || ') — ticket <ticket-id>'
FROM stockunit su WHERE su.id = :stockunit_id;

-- ---- Re-run §7 verification queries here. If good: COMMIT; else: ROLLBACK. ----
COMMIT;
```

**After COMMIT:** re-release / re-allocate the order (re-run picking allocation for the batch, or have the picker re-scan the location). The line now allocates because `available >= needed`.

### 5.2 Option B — In-app stock move (no DB write)

Use **Move Stock / move unit load** to relocate the unit load off the affected pick location to another pick location (or the same area). A move typically materialises a fresh `stockunit`, which starts with `reservedamount = 0` and is immediately pickable. See [[wms1-move-stock-unitload-workflow]].

- **Validate once before relying on it:** after the move, query the new stockunit's `reservedamount` — confirm it is `0` (the move must not carry the old reservation forward). If it copies the reservation, fall back to Option A.
- Pros: no raw SQL. Cons: requires a floor action + the validation check.

### 5.3 Option C — Cycle count on the location

Initiate a cycle count on the affected location; the recount confirms physical quantity and rewrites the stockunit.

- **Caveat:** whether the cycle-count flow zeroes `reservedamount` is **environment-dependent and not guaranteed**. Verify with §7 afterward; if the reservation persists, use Option A. Slower (10–30 min) than A/B.

### 5.4 Option D — Physical pick + manual reconcile (last resort)

If A/B/C cannot be done before the truck leaves: physically pull the needed bottles and ship, then reconcile the system after (adjust the line / inventory). Creates a temporary system↔physical mismatch — only use under deadline pressure and record it for same-day reconciliation.

---

## 6. Escalation

| When | Who | How |
|------|-----|-----|
| §4.1 shows `entity_lock = 405` (SHIPPED) | Warehouse floor lead + OMS on-call | Stock has left — switch to a return / short-ship flow; do not edit reservation |
| §4.3 returns live holders you cannot explain | WMS on-call engineer | Treat as a stuck order, not a leak — see [[wms1-cancel-packed-parcel]]; do not zero the reservation |
| Floor cannot physically confirm the stock | Floor lead | Do **not** release the reservation — may be a genuine shortage |
| Reservation reappears after release | WMS on-call engineer | A live process is re-leaking — capture timing and open the leak investigation (§8) |
| Anything outside this list | WMS on-call engineer | Slack #wms-oncall with the ticket id and the §4.1 snapshot |

---

## 7. Verification — Confirm Resolved

Run after the recovery action (post-COMMIT for Option A; post-move for B; post-count for C).

```sql
-- A. Reservation released, physical amount untouched
SELECT id, amount, reservedamount, (amount - reservedamount) AS available, version, modified
FROM stockunit WHERE id = :stockunit_id;
-- EXPECT: available >= the order's needed qty; amount UNCHANGED; reservedamount = target; modified just now
```

```sql
-- B. Still no live holder created a conflict
SELECT
  (SELECT count(*) FROM pickingorder_position WHERE pickfromstockunit_id = :stockunit_id AND state < 700) AS open_picks,
  (SELECT count(*) FROM replenishorder        WHERE stockunit_id          = :stockunit_id AND state < 600) AS open_replenish;
-- EXPECT: both 0 (for the orphaned case)
```

```sql
-- C. Audit row written (Option A)
SELECT id, created, operator, activitycode, type, additionalcontent
FROM stockrecord
WHERE operator LIKE 'db_manual_resv_fix:%'
ORDER BY created DESC LIMIT 5;
-- EXPECT: one row describing was -> now for this stockunit
```

Application-side:
- [ ] Re-run picking allocation / re-scan the location — the blocked line now allocates (no "Not enough stock on location").
- [ ] Parcel moves off On Hold; the order picks and ships.
- [ ] SKU Location Report shows `Reserved < Total` (available > 0).

---

## 8. Post-incident

- [ ] Attach §4.1 snapshot, §4.3 result, and §7 output to the ticket.
- [ ] Record `was -> now` reservation values for inventory reconciliation.
- [ ] If Option A was used, the `stockrecord.operator = 'db_manual_resv_fix:…'` rows are your manual-change log — reconcile weekly.
- [ ] **Root-cause the leak (do not skip).** Releasing the reservation unblocks today; it does not stop recurrence. As of 2026-06-01, WineCo had ~120 pick-face stockunits carrying a reservation and ~11 fully reserved — open a `wms-investigation-report` / `wms-bugfix-plan` to find what leaves `reservedamount` behind (relates to [[260601-wineco-replenishment-pickpack-source-and-order-count]] §9, and prior reservation-leak work `260522-sbdev-2033-reserve-amount-adjust-not-sticking`).
- [ ] Update `last_verified` in frontmatter after the next use.

---

## 9. Worked Example — BW23CPN / Brooks Winery (2026-06-01)

The case this runbook was written from:

| Field | Value |
|---|---|
| SKU | `BW23CPN` (2023 Cahiers Pinot Noir 750 ml), client Brooks Winery (`client_id = 419800`) |
| Stock unit | `985079706` at location **10-B01**, area "Storage and Picking" (`useforpicking=true, useforreplenish=false`) |
| State | `amount = 11`, `reservedamount = 11`, `available = 0` |
| Live demand | order **060554-000002**, BW23CPN line needs **2** (every other line on the order was pickable) |
| §4.3 result | **zero** open picking positions, **zero** open replenish orders referencing 985079706 → **orphaned** |
| Action | Option A: `reservedamount 11 -> 0`; re-release order 060554-000002 → all lines pick → shipment goes out |

```sql
-- Confirm before / after for this exact unit:
SELECT id, amount, reservedamount, (amount - reservedamount) AS available
FROM stockunit WHERE id = 985079706;
-- before: 11 / 11 / 0     after: 11 / 0 / 11
```

---

## 10. Related Docs & Evidence

**Investigation / plans:**
- [[260601-wineco-replenishment-pickpack-source-and-order-count]] — the investigation that surfaced this orphaned reservation (§5.5) plus the separate Monitor display bug.
- Bugfix plan `SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md` — fixes the Monitor's *reporting*, not this reservation state.

**Code references (v1/wms-api):**
- `repo/jpa/StockunitRepository.java:30-32` — `findByIdForUpdate` (pessimistic lock used by the app when changing a stockunit; the §5.1 `FOR UPDATE` mirrors it).
- `repo/jpa/StockunitRepository.java:101-116` — `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage`; note `su.reservedamount = 0` (line 109) is why a leaked reservation also hides the unit from auto-replenishment.
- `service/ReplenishGeneratorService.java:158` — `stockUnitBusinessService.changeReservedAmount(...)`; the canonical path that adjusts `reservedamount` (the §5.1 SQL emulates a release of it).
- `service/StockunitBusinessService.java` — `changeReservedAmount` (writes the `stockrecord` audit row the §5.1 INSERT mirrors; confirm exact columns with `\d stockrecord`).

**Known limitations / caveats:**
- No reservation/transaction log table exists — `stockunit.reservedamount` is the only state. §4.3 is the definitive orphan test.
- `stockunit` has an `@Version` column — always bump `version` on a manual write so a later app load doesn't trip optimistic locking.
- This runbook releases a reservation; it does **not** address *why* it leaked. Always complete the §8 root-cause follow-up.
