---
title: "Runbook: Cancel a Single Pre-QA Parcel in WMS v1 (state < PACKED)"
type: runbook
status: active
version: "wms-api v1 (Java 8, Spring Boot 2.3.7, PostgreSQL)"
scope: "v1/wms-api — cancel ONE parcel of a multi-parcel order via the standard REST path when order state < PACKED (650)"
owner: "nam.park@siteboss.net"
created: "2026-07-09"
updated: "2026-07-09"
last_verified: "2026-07-09"
verified_by: "nam.park@siteboss.net"
alert: "Client asks to cancel one parcel of a multi-parcel order that has not yet been packed (support / ops request)"
severity: "SEV3"
escalation: "WMS on-call engineer -> OMS on-call (to originate the cancel / reconcile the message) -> DB admin (only if the parcel turns out to be past PACKED — switch runbooks)"
related:
  - "[[wms1-cancel-packed-parcel]]"
  - "[[wms1-revert-shipped-order-to-cancelled]]"
tags:
  - runbook
  - wms1
  - cancellation
  - parcel
  - club
---

# Runbook: Cancel a Single Pre-QA Parcel in WMS v1 (state < PACKED)

**Alert:** Client asks to cancel one parcel of a multi-parcel order, not yet packed | **Severity:** SEV3
**Scope:** `v1/wms-api` — cancel ONE parcel at state `< PACKED (650)` via the standard REST path | **Version:** wms-api v1
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-07-09 (nam.park)

<!--
  The clean, standard-path counterpart to wms1-cancel-packed-parcel.md.
  When a parcel is still pre-QA (RAW / ASSIGNED / PROCESSABLE / STARTED, i.e. state < 650),
  cancellation is OMS-driven through POST /rest/order/cancelPositions and requires NO manual
  SQL — cancelOrder() flips it to CANCELED and finalizes the (single-parcel) batch on its own.
  Key point this runbook makes concrete: in WMS v1 each parcel is its OWN customerorder in its
  OWN customerorder_batch, so cancelling one parcel does NOT touch the order's other parcels.
-->

---

## 1. When to Use This Runbook

- **Triggered by:** Ops / client wants to cancel **one parcel** of an order (usually a split/CLUB order) that has **not yet been packed**.
- **Use this when** the parcel's `customerorder.state` is **below** PACKED (650):
  - 0 (RAW), 50/55/56/57/58 (RAW_ON_HOLD*)
  - 200 (ASSIGNED), 300 (PROCESSABLE)
  - 500 (STARTED), 510 (TRANSFER_LANE_ASSIGNED), 525/530 (batch staging/club states)
  - 600 (PICKED) — still cancellable via the REST path (no position ≥ PACKED)
- **Do NOT use this runbook if:**
  - `customerorder.state >= 650` (PACKED/PALLETIZED) → use **[[wms1-cancel-packed-parcel]]** (REST is blocked for PICK_PACK; manual SQL for others).
  - `customerorder.state = 700` (FINISHED) or `800` (already CANCELED) → shipment final / nothing to do; use a return flow (**[[wms1-revert-shipped-order-to-cancelled]]** if WMS shipped after OMS cancelled).
  - You need to cancel the **entire** order (all parcels) → list every parcel's `unique_id` in the payload (§5), or have OMS cancel the whole order.

> **Terminology (v1).** "OMS order" (e.g. `96564149567A:807`) → many parcels. In WMS each **parcel = one `customerorder`** carrying its own `parcelexternalnumber`, and each `customerorder` sits in its **own** `customerorder_batch`. Cancelling one parcel = cancelling one `customerorder` = one batch. Siblings are untouched.

---

## 2. Severity & Impact

| Aspect | Detail |
|--------|--------|
| User impact | One parcel of an order is voided. If OMS is not the originator, OMS/WMS can desync (WMS cancelled, OMS still open). |
| Blast radius | **Exactly one `customerorder`** and its (single-parcel) batch. Sibling parcels of the same OMS order are in different batches and are never referenced. |
| Is it a paging event? | No — routine ops request. |
| Data repair? | **None.** Pre-PACKED means no parcel entity, no shipped stock, no BOL. `cancelOrder()` does all the work; this runbook is verify-only around a REST call. |

---

## 3. First 5 Minutes — Triage

- [ ] Confirm the request source (ticket ID, requester) and **which parcel** (OMS `unique_id` / `parcelexternalnumber`, or WMS `customerorder.number`).
- [ ] Confirm it is **one parcel**, not the whole order (ask explicitly — see §4.3).
- [ ] Identify tenant + facility (sets `tenant_name` / `facility_code`; e.g. WineCo = facility `WSL`).
- [ ] Open a **read-only** DB session against the tenant schema for diagnosis (§4).
- [ ] Prefer having **OMS originate the cancel** — it is the correct source of truth and fires the WMS call for you.

---

## 4. Diagnosis — Confirm the Parcel Is Pre-QA and Isolated

Run in order. Replace `:order_id` with the WMS `customerorder.id`, or adjust the first query to look up by `externalnumber` / `parcelexternalnumber`.

### 4.1 Snapshot the parcel

```sql
SELECT
  co.id                 AS order_id,
  co.externalnumber     AS parcel_unique_id,     -- this is the OMS "unique_id" used in the cancel payload
  co.number             AS wms_number,
  co.clientordernumber,
  co.parcelexternalnumber,
  co.state              AS order_state,          -- < 650 required for this runbook
  co.markedforcancellation,
  co.parcel_id,                                  -- EXPECT NULL when pre-pack
  co.pickingtote_id,                             -- often NULL pre-pack
  cob.id                AS batch_pk,
  cob.batchid           AS batch_id,             -- this is the "batch_id" used in the cancel payload
  cob.type              AS batch_type,
  cob.state             AS batch_state
FROM customerorder co
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
WHERE co.id = :order_id;
```

**Gate:** `order_state` must be `< 650`. If `>= 650`, stop and switch to **[[wms1-cancel-packed-parcel]]**.

### 4.2 Confirm nothing has been picked

```sql
SELECT id, number, state, amount, amountpicked, itemdata_id
FROM customerorder_position
WHERE order_id = :order_id
ORDER BY index;
-- EXPECT: state < 650 and amountpicked = 0.0000 on every row (clean cancel, no reservation to unwind).
-- If any position has amountpicked > 0 or state >= 650, treat as packed — switch runbooks.
```

### 4.3 Prove parcel isolation — how many parcels are in this batch, and what are the siblings

```sql
-- Parcels in THIS batch (must be the target only for a clean single-parcel cancel)
SELECT co.id, co.externalnumber AS unique_id, co.number, co.state
FROM customerorder co
WHERE co.orderbatch_id = (SELECT orderbatch_id FROM customerorder WHERE id = :order_id);

-- All sibling parcels of the SAME OMS order (by clientordernumber) and their batches —
-- shows they live in different batches and will NOT be affected.
SELECT co.id, co.externalnumber AS unique_id, co.number, co.state,
       cob.batchid, cob.state AS batch_state
FROM customerorder co
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
WHERE co.clientordernumber = (SELECT clientordernumber FROM customerorder WHERE id = :order_id)
ORDER BY co.id;
```

- The first query returning **just the target row** confirms the batch-finalization step (§5) cannot reach a sibling.
- The second query is your evidence to the requester that only the one parcel is cancelled.

---

## 5. Recovery Action — Standard REST Cancel (OMS-driven)

**There is no manual SQL for a pre-PACKED parcel.** Cancellation is a webservice call to WMS. **Preferred:** have the client/OMS cancel the parcel in OMS, which fires this call automatically and keeps both systems in sync.

If you must issue it directly (e.g. OMS webhook is stuck and ops approved a manual push):

```bash
# POST /rest/order/cancelPositions  (OrderRestController.java:688)
# NOTE: /rest/** is unauthenticated per SecurityConfiguration — no bearer token needed,
# but the body MUST carry the correct facility_code (validated against the
# MULTIWAREHOUSE_IDENTIFIER sysprop; WineCo = "WSL").
curl -X POST "$WMS_BASE/rest/order/cancelPositions" \
  -H "Content-Type: application/json" \
  -d '[{
        "facility_code": "WSL",
        "batch_id": "50429-2",
        "positions": [
          { "unique_id": "685194" }
        ]
      }]'
```

**Payload field reference (Jackson snake_case — verified against `OrderBatchDto` / `OrderDto`):**

| JSON key | Maps to | Source of value |
|---|---|---|
| `facility_code` | `OrderBatchDto.facilityCode` → `validateWarehouse` | `los_sysprop.MULTIWAREHOUSE_IDENTIFIER` (WineCo = `WSL`) |
| `batch_id` | `OrderBatchDto.batchId` → `findByBatchid(...)` | `customerorder_batch.batchid` from §4.1 (e.g. `50429-2`) |
| `positions[].unique_id` | `OrderDto.uniqueId` → `findByExternalNumber(...)` | `customerorder.externalnumber` from §4.1 (e.g. `685194`) |

> **Do NOT use** the `{"externalNumber": ..., "orderNumbers": [...]}` shape — that is incorrect for this endpoint (the DTOs are `batch_id` + `positions[].unique_id`).

**Responses:**
- **204 No Content** → success. Proceed to §6.
- **400 + `{"status":"partial_failure","errors":{...}}`** → per-parcel failure map. Common causes: `"order not found"` (wrong `unique_id`), `"order is beyond status PACKED..."` (state ≥ 650 → wrong runbook), `WRONG_FACILITY_CODE` (bad `facility_code`). Re-check §4 and retry the failing entries.

**What the code does for a pre-PACKED parcel** (`CustomerorderService.cancelOrder`, `CustomerorderService.java:561`):
1. Not already cancelled; not shipped/past-QA; not packed/palletized; no position ≥ PACKED → all pass.
2. `canOrderPositionBeCancelled` true (nothing picked) → cancels each position, sets `customerorder.state = CANCELED (800)`, saves.
3. `finalizeBatchIfComplete(orderbatch_id)` (`CustomerorderBatchService.java:333`): since the batch's every order is now ≥ FINISHED and all CANCELED, the **batch** goes to `CANCELED (800)` and `staginglane_id` is cleared.

No tote teardown, no stock return, no BOL cleanup — none exist pre-pack.

---

## 6. Verification — Confirm Resolved

Run after the 204 (or after OMS reports success).

```sql
-- A. Parcel + batch are CANCELED, staging lane cleared
SELECT co.id, co.state AS order_state, co.markedforcancellation, co.modified,
       cob.batchid, cob.state AS batch_state, cob.staginglane_id
FROM customerorder co
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
WHERE co.id = :order_id;
-- EXPECT: order_state = 800, batch_state = 800, staginglane_id = NULL, modified recent.
```

```sql
-- B. Every position CANCELED
SELECT id, state FROM customerorder_position
WHERE order_id = :order_id AND state <> 800;
-- EXPECT: zero rows.
```

```sql
-- C. Siblings UNTOUCHED (the whole point) — compare against §4.3
SELECT co.id, co.externalnumber AS unique_id, co.state, cob.batchid, cob.state AS batch_state
FROM customerorder co
JOIN customerorder_batch cob ON cob.id = co.orderbatch_id
WHERE co.clientordernumber = (SELECT clientordernumber FROM customerorder WHERE id = :order_id)
  AND co.id <> :order_id
ORDER BY co.id;
-- EXPECT: every sibling's state is unchanged from the §4.3 baseline (no sibling flipped to 800).
```

OMS-side (outside WMS DB):
- [ ] OMS shows the single parcel cancelled/voided; the rest of the order intact.
- [ ] If WMS was pushed directly (not OMS-originated), confirm OMS received/reconciled the cancellation.

---

## 7. Escalation

| When | Who | How |
|------|-----|-----|
| §4.1 shows `state >= 650` | — | Switch to **[[wms1-cancel-packed-parcel]]**; this runbook does not apply |
| §4.2 shows `amountpicked > 0` on a state `< 650` row (unexpected) | WMS on-call | Investigate before cancelling — a partial pick may need reservation release |
| REST returns `partial_failure` you can't resolve from §5 | OMS on-call | Have OMS originate the cancel / reconcile the message |
| Client actually wants the **whole** order cancelled | — | List all sibling `unique_id`s (§4.3) in one payload, or have OMS cancel the order |
| Parcel already past PACKED on the floor / shipped | Warehouse floor lead + OMS on-call | Return / short-ship flow, not cancellation |

---

## 8. Post-incident

- [ ] Attach §6 A–C output to the ticket (esp. C, proving siblings untouched).
- [ ] If WMS was pushed directly rather than OMS-originated, note it and confirm OMS reconciliation.
- [ ] Re-verify this runbook every 90 days or after any change to `cancelOrder` / `cancelPositions` / the DTOs; bump `last_verified` + `verified_by`.

---

## 9. Related Docs & Evidence

**Worked example (this runbook was verified against it — wms1-wineco, 2026-07-09):**
- OMS order `96564149567A:807`, parcel `685194` (WMS `060881-000001`, `customerorder.id 33560542`), state **0 (RAW)**, batch `50429-2` (type CLUB). 8 parcels total, each in its own batch — confirmed via §4.3. Clean single-parcel cancel path.

**Code references (v1/wms-api):**
- `controller/rest/OrderRestController.java:688-790` — `cancelPositions` REST entry point (`findByBatchid` → `findByExternalNumber` → `cancelOrder`)
- `controller/rest/AbstractRestController.java:15-26` — `validateWarehouse` (`facility_code` vs `MULTIWAREHOUSE_IDENTIFIER`)
- `service/CustomerorderService.java:561-660` — `cancelOrder` (pre-PACKED branch: positions cancel + state 800 + batch finalize)
- `service/CustomerorderBatchService.java:333-356` — `finalizeBatchIfComplete` (batch → 800 when all orders CANCELED; clears staging lane)
- `service/WmsConstants.java:20-109` — state constants (RAW 0 … PACKED 650, FINISHED 700, CANCELED 800)
- `json/OrderBatchDto.java` (`batch_id`, `facility_code`, `positions`) / `json/OrderDto.java` (`unique_id`) — payload field names

**Contrast:** for `state >= 650`, the REST path throws `"order is beyond status PACKED..."` (or, for CLUB, force-cancels) — see **[[wms1-cancel-packed-parcel]]**.

**Known caveats:**
- `/rest/**` is unauthenticated (`SecurityConfiguration`); the `facility_code` in the body is the guard, not a token.
- No `cancelled_by`/`cancelled_at` columns — audit trail is `customerorder.modified` + the `ORDER_BATCH_CANCELLED_FROM_PSD` service-log `message` row written by `cancelPositions`.
- Single-parcel batches make batch finalization trivially terminal; a multi-parcel batch would only flip to 800 once **all** its orders are terminal.
