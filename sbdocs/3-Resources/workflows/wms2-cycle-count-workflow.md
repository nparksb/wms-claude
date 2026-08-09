---
title: "WMS v2 — Cycle Count Workflow"
type: workflow
status: active
version: v2
scope: cycle-count
owner: Nam Park
created: 2026-04-19
updated: 2026-08-03
last_verified: 2026-08-03
verified_by: code read of v2/wms2-api CyclecountService + MobileCycleCountService + CycleCountLosController; export endpoint re-verified against SBDEV-2632 implementation (line anchors refreshed)
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ../data-dictionary/wms2-sysprop-catalog.md
tags:
  - workflow
  - cycle-count
  - wms2
---

# WMS v2 — Cycle Count Workflow

**Scope:** Inventory audit (cycle count) flow — admin creates, operators count on mobile, deltas feed OMS · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

Cycle count compares `amountbefore` (expected quantity snapshot at creation) against `amountafter` (operator count) per position. When they diverge, `stockunit.amount` is adjusted via `StockunitBusinessService.changeAmount(...)` and a stock-change message fires to OMS via `WEBSERVICE_STOCK_UPDATE`.

Two things to hold in mind:

1. **Cycle count state is String-typed** (`CycleCountState.CANCELLED` — two L's). Don't copy-paste integer `CANCELED` comparisons.
2. **No reopen endpoint exists.** Once a cycle count reaches `FINISHED` or `CANCELLED`, it's terminal. Corrections require a new cycle count. `CyclecountService.cancelCycleCount` is the only transition-writing admin path, and it only allows non-terminal → `CANCELLED`.

Desktop creates/cancels/exports; mobile does the counting. No cron job touches cycle count.

---

## 2. Entity Cast

| Entity | Fields worth knowing | Source |
|---|---|---|
| `Cyclecount` | `state` (String), `type` (PLANNED/ADJUSTMENT…), `subtype` (SKU/Location…), `comment` | `model/Cyclecount.java` |
| `CyclecountPosition` | `state`, `locationId`, `unitloadId`, `stockunitId`, `itemdataId`, `operatorId`, `amountbefore` (Decimal(17,4)), `amountafter` (Decimal(17,4)), `comment` | `model/CyclecountPosition.java` |

State sequence (same for header and each position):

```
CREATED → STARTED → FINISHED       (happy path, terminal)
    ↓        ↓           ↓
    └────→ CANCELLED     (admin-only, terminal)
```

---

## 3. Lifecycle

```
Admin creates a cycle count
  │  POST /v3/cycleCount/create {skuIdSet, areaIdSet, name, comment}
  │        [CycleCountController:60]
  ▼
CyclecountService.createCycleCount()
  ├── Create Cyclecount (state = CREATED)
  ├── For each matching (location, unitload, stockunit) tuple:
  │     Create CyclecountPosition (state = CREATED, amountbefore = current stockunit.amount)
  └── Commit

Mobile operator takes it
  │  GET /v3/cycleCountLos/orderList            → list of CREATED/STARTED Cyclecounts
  │  GET /v3/cycleCountLos/locationList/{id}    → locations sorted by rack strategy (VERTICAL = column-first, HORIZONTAL = row-first; direction controlled by PICK_PATH_DIRECTION sysprop via PickPathConfig → CycleCountStrategy)
  │  GET /v3/cycleCountLos/unitLoadList/{o}/{l} → unit loads at that location
  ▼
Operator scans unit load
  │  POST /v3/cycleCountLos/processScanUnitLoad {orderId, locationId, unitLoadLabel}
  │        returns CyclecountPosition + stockUnit + itemdata + client + unitload + location
  │        (NO state change — query only)
  ▼
Operator enters count
  │  POST /v3/cycleCountLos/countUnitLoad {cyclecountPosition, count, comment, orderId, locationId}
  │        MobileCycleCountService.countCycleCountStockUnit()    [line 319]
  │        ├── Position.state = FINISHED
  │        ├── If count == amountbefore: no stock change
  │        ├── If all positions on cyclecount now FINISHED/CANCELLED: parent Cyclecount → FINISHED
  │        └── Return next position (or null if done)
  │
  ▼ [only if count != amountbefore]
Operator confirms recount
  │  POST /v3/cycleCountLos/recountUnitLoad {cyclecountPosition, count, comment, orderId, locationId}
  │        MobileCycleCountService.countBySKURecount()           [line 388]
  │        ├── Position.amountafter = count; Position.state = FINISHED
  │        ├── diff = count - stockunit.amount
  │        ├── If diff != 0:
  │        │     If count == 0: sendStockUnitToNirvana(stockUnit)
  │        │     Else:          stockunitBusinessService.changeAmount(stockUnit, count, CODE_CYCLE_COUNT, ...)
  │        ├── messageService.sendStockChangeMessage([StockChangeDto(diff, CODE_CYCLE_COUNT)])  → POSTs to WEBSERVICE_STOCK_UPDATE
  │        ├── If all positions done: Cyclecount → FINISHED
  │        └── Return nextProcess: {unitLoad | location | order}
  ▼
Cyclecount.state = FINISHED (auto-rolled when all positions are terminal)

Admin cancels (before completion)
  │  POST /v3/cycleCount/cancel {ids}    [CycleCountController:78]
  ▼
CyclecountService.cancelCycleCount()
  ├── Guard: current state ∈ {CREATED, STARTED}
  ├── Cyclecount.state = CANCELLED
  ├── All positions in {CREATED, STARTED}: state = CANCELLED
  └── Commit

Admin exports
  │  POST /v3/cycleCount/export {ids:[1,2]} | {id:"1, 2"}   [CycleCountController:116]
  ▼
Excel file returned — "aggregated" sheet (by SKU) + "detailed" sheet (per position)
  │  Single selection  → legacy columns, filename CC<number>_<ts>.xlsx
  │  Multi selection   → both sheets gain a leading "Cycle Count" column (CC_Multiple_<ts>.xlsx);
  │                      positionless cycle counts are SKIPPED and named in the
  │                      X-Export-Skipped-Cycle-Counts response header (CORS-exposed)
  ▼
Errors are real status codes + JSON {errors:[{field,message}]} — 422 (bad/empty selection,
nothing exportable), 404 (unknown id), 500 (unexpected; message not echoed to the client).
Before SBDEV-2632 the id was parsed with Long.parseLong OUTSIDE the try, so a multi-select
payload produced an opaque HTTP 500, and a positionless cycle count returned 200 with the
error text as the body — a silently corrupt .xlsx download.
```

---

## 4. Mobile REST Endpoints

All under `/v3/cycleCountLos/...` (LOS = Location/Order/SKU). Owner: `CycleCountLosController`.

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `scanSingleUnitLoad/{input}` | GET | 75 | Resolve UL label → full context (no state change) |
| `countSingleUnitLoad` | POST | 111 | Fast-path count (no position row; returns null or error on mismatch) |
| `recountSingleUnitLoad` | POST | 151 | Fast-path recount — writes position, adjusts stock |
| `orderList` | GET | 180 | List CREATED/STARTED cyclecounts |
| `locationList/{orderId}` | GET | 187 | Locations for this count, sorted by rack strategy |
| `unitLoadList/{orderId}/{locationId}` | GET | 194 | UL pick list (position.id + unitload.labelid) |
| `processScanUnitLoad` | POST | 201 | Resolve scanned UL to a specific position |
| `countUnitLoad` | POST | 239 | Count a position. Returns next position; `isOrderFinished` flag when done |
| `recountUnitLoad` | POST | 275 | Recount on mismatch. Returns `nextProcess ∈ {unitLoad, location, order}` |

---

## 5. Web REST Endpoints

Under `/v3/cycleCount/...`. Owner: `CycleCountController`.

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `create` | POST | 60 | Create new cycle count from SKU + area filters |
| `cancel` | POST | 78 | Cancel one or more cycle counts (`ids` comma-separated) |
| `export` | POST | 116 | Export Excel (aggregated + detailed sheets). Accepts `ids` array **or** legacy comma-separated `id`; multi-selection merges into one workbook. 422 / 404 / 500 + JSON on failure |
| `itemDataView` | POST | 215 | List aggregated by item |
| `locationView` | POST | 227 | List by location within an item |
| `positionView` | POST | 240 | List per-position (drill-down) |
| `detailView` | GET | 253 | Paginated list, filter by state / keyword / clientId |
| `cycleCountDetailsById/{id}` | GET | 274 | Header detail for one cycle count |

**No reopen endpoint.** Terminal states are absolute.

---

## 6. Stock Adjustment Semantics

When `count != amountbefore`, `countBySKURecount` does three things in one transaction:

1. **Position**: `position.amountafter = count; position.state = FINISHED`.
2. **Stock unit**: one of:
   - `count == 0` → `sendStockUnitToNirvana(stockUnit)` (routes stock to the Nirvana unit load, effectively deleting it from inventory).
   - `count > 0` → `stockunitBusinessService.changeAmount(stockUnit, count, WmsConstants.CODE_CYCLE_COUNT, position.getNumber(), comment)`. `changeAmount()` is `@Transactional("tenantTransactionManager")` at `StockunitBusinessService.java:362`.
3. **OMS message** (SBDEV-2214 deferral, 2026-05-10): `messageService.sendStockChangeMessage(List<StockChangeDto>)` now delegates to `StockChangeNotificationService.sendAfterCommit(...)` → `OmsNotificationService.sendAfterCommit(urlPath, payload, STOCK_UPDATE)`. The HTTP POST to `WEBSERVICE_STOCK_UPDATE` (sysprop `SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY`) fires only AFTER the surrounding cycle-count transaction commits — rollback silently drops the POST. Result logged to `message` table as SENT/FAILED by `OmsNotificationService.doSend` on the listener side.

Audit: `Stockrecord` is not written directly from this path — `changeAmount()` writes that itself.

---

## 7. Sysprop Gates

Mobile UI reads these three sysprops before rendering the count screen. See [wms2-sysprop-catalog.md §10](../data-dictionary/wms2-sysprop-catalog.md) Cycle count rows.

| Sysprop | Default | Behavior |
|---|---|---|
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | `true` | If true, show `amountbefore` to operator before they count |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` | `0` | Only show expected amount when the operator's provisional count differs by ≥ N |
| `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT` | `true` | Require a comment on the recount — no mismatch silently commits |

Flipping `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` to `false` is the usual "blind count" policy — operators enter whatever they see, and any mismatch always triggers the recount path.

---

## 8. Transaction Boundaries

- `CycleCountController` methods have no explicit `@Transactional` — repositories inherit `tenantTransactionManager` via Spring Data JPA config.
- `CyclecountService.cancelCycleCount()` walks parent + positions in one logical unit; if it throws mid-way, the whole cancel rolls back.
- `MobileCycleCountService.countBySKURecount()` binds position write + stock adjustment + OMS message logging in one transaction; a failure anywhere rolls everything back — no partial commits.
- No pessimistic locks in the cycle-count path. Optimistic `@Version` on both `Cyclecount` and `CyclecountPosition` (inherited from `AbstractBaseEntity`) is the only concurrency guard.

No `REQUIRES_NEW` anywhere in this flow.

---

## 9. OMS Integration

Only one touchpoint: `WEBSERVICE_STOCK_UPDATE` (via `MessageService.sendStockChangeMessage` line 101). Fires only when the recount path produces a non-zero delta. No cycle-count-lifecycle callback (no `WEBSERVICE_CYCLE_COUNT_*` sysprop) — OMS learns about inventory changes as stock deltas, not count events.

---

## 10. Known Landmines

1. **`CANCELLED` spelling.** String state. `WmsConstants.CycleCountState.CANCELLED`. Don't confuse with integer `CANCELED`.
2. **No reopen.** Once `FINISHED` or `CANCELLED`, terminal. Admin correction = create a new cycle count.
3. **`count == amountbefore` fast-path creates no position row** (`countSingleUnitLoad` returns null). If you need every scan auditable regardless of match, use `countUnitLoad` from the order-driven flow instead.
4. **No Stockrecord written directly** from cycle-count code — it's via the downstream `changeAmount` path. A refactor of `changeAmount` that removes the Stockrecord write breaks cycle-count audit.
5. **No scheduled job touches cycle count.** Don't expect background recalc or cleanup — the whole lifecycle is event-driven.
6. **Cancel guard only accepts `CREATED` or `STARTED`.** Attempting to cancel a `FINISHED` cyclecount is a no-op (error-returning) — not a revert.
7. **Mobile fast-path and order-driven flow coexist.** `scanSingleUnitLoad` / `countSingleUnitLoad` / `recountSingleUnitLoad` are independent of `orderList` / `locationList` / `processScanUnitLoad` / `countUnitLoad` / `recountUnitLoad`. Mixing them on the same cycle count may produce duplicate position rows.
8. **`Cyclecount.state = FINISHED` is auto-rolled** only when ALL positions reach terminal state. A single stuck position blocks parent finalization — check with `positionView` API.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| Cyclecount stuck in STARTED, never finishes | §3 auto-rollup + §10 item 8 — find the non-terminal position via `positionView` |
| Operator can't find the cyclecount on mobile | `orderList` only returns CREATED/STARTED — if someone already cancelled or finished it, it disappears |
| Count matches but expects recount prompt | §6 + §7 — check `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` |
| Stock adjusted but OMS never got the delta | §6 item 3 + `message` / `message_archived` tables |
| Admin pressed cancel but nothing changed | §10 item 6 — state was already terminal |
| Two position rows for the same UL | §10 item 7 — mixing fast-path + order-driven |
| Count of 0 didn't delete the stock unit | §6 item 2 — confirm `sendStockUnitToNirvana` fired; check logs |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `CyclecountService` (6 methods), `MobileCycleCountService` (12 methods), `CycleCountController` (8 endpoints), `CycleCountLosController` (9 mobile endpoints), sysprop gates, cancel guard, stock-change wire-up | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |

**Re-verify every 90 days.** Next due: **2026-07-18**.
