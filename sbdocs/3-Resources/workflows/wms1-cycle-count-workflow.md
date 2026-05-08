---
title: "WMS v1 — Cycle Count Workflow"
type: workflow
status: active
version: v1
scope: cycle-count
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-04-26
verified_by: code read of v1/wms-api CyclecountService + CyclecountPositionService + MobileCycleCountService + CycleCountController + CycleCountLosController
related:
  - wms2-cycle-count-workflow.md
tags:
  - workflow
  - cycle-count
  - wms1
---

## TL;DR

- Describes the full inventory audit (cycle count) lifecycle in `v1/wms-api`: admin creates → mobile operators count → discrepancies trigger stock adjustment → header auto-finishes.
- Key entities: `Cyclecount` (header, String state) and `CyclecountPosition` (per-unit-load count line, also String state); state sequence is `CREATED → STARTED → FINISHED` or `→ CANCELLED` (terminal, no reopen).
- Two parallel counting flows exist — order-driven (position list) and single-UL fast-path (`scanSingleUnitLoad`); mixing them against the same count can create duplicate position rows.
- Stock adjustments call `StockunitBusinessService.changeAmount` and fire `MessageService.sendStockChangeMessage` to OMS; no adjustment fires if counts match.
- Critical constraints: `CANCELLED` uses two L's (not `CANCELED`); `STARTED` state is defined but never written by v1 service code; fast-path positions get prefix `SID` (copy-paste bug) instead of `CCP`.
- No cron job touches cycle counts; entire lifecycle is event-driven. No reopen path exists — corrections require a new cycle count.
- Read this doc before working on any cycle-count bug, stock-adjustment discrepancy, or mobile counting flow change.

# WMS v1 — Cycle Count Workflow

**Scope:** Inventory audit (cycle count) flow — admin creates, operators count on mobile, deltas adjust stock · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26

---

## 1. Overview

A cycle count compares `amountbefore` (quantity snapshot at position creation) against `amountafter` (operator count). When they diverge, `stockunit.amount` is adjusted via `StockunitBusinessService.changeAmount(...)` and a stock-change message fires to OMS via `MessageService.sendStockChangeMessage`.

Key facts to keep in mind:

1. **State is String-typed.** `CycleCountState.CANCELLED` — two L's. Do not confuse with integer `CANCELED`.
2. **No reopen endpoint.** Once a cycle count reaches `FINISHED` or `CANCELLED` it is terminal. Corrections require a new cycle count. `CyclecountService.cancelCycleCount` is the only admin transition path, and it only allows non-terminal → `CANCELLED`.
3. **Two parallel counting flows coexist.** The *single-UL fast-path* (`scanSingleUnitLoad` / `countSingleUnitLoad` / `recountSingleUnitLoad`) and the *order-driven flow* (`orderList` / `locationList` / `processScanUnitLoad` / `countUnitLoad` / `recountUnitLoad`) are independent. Mixing them against the same cycle count can produce duplicate position rows.
4. **No cron job touches cycle count.** The entire lifecycle is event-driven.

Desktop creates/cancels/exports; mobile does the counting.

---

## 2. Entity Cast

| Entity | Table | Key fields |
|---|---|---|
| `Cyclecount` | `cyclecount` | `state` (String), `type` (PLANNED/ADJUSTMENT), `subtype` (SKU/LOCATION), `name`, `comment`, `clientId` |
| `CyclecountPosition` | `cyclecount_position` | `state`, `cyclecountId` (nullable — null for fast-path positions), `locationId`, `unitloadId`, `stockunitId`, `itemdataId`, `operatorId`, `amountbefore` (Decimal 17,4), `amountafter` (Decimal 17,4), `comment` |

State sequence (same for header and each position):

```
CREATED → STARTED → FINISHED       (happy path, terminal)
    ↓        ↓
    └────→ CANCELLED               (admin-only, terminal)
```

Entity number prefixes:
- `Cyclecount.number`: prefix `CC` (`WmsConstants.EntityPrefixes.CYCLECOUNT`)
- `CyclecountPosition.number` (from `CyclecountService`): prefix `CCP` (`WmsConstants.EntityPrefixes.CYCLECOUNT_POSITION`)
- `CyclecountPosition.number` (from `CyclecountPositionService.createEntity`): prefix `SID` (`EntityPrefixes.SHIPPERID`) — **this is a copy-paste bug** from `CyclecountPositionService.java:41`; fast-path position numbers start with `SID` not `CCP`.

---

## 3. Cycle Count Creation and Position Generation

```
Admin submits create form
  │  POST /v3/cycleCount/create
  │    body: { skuIdSet: Long[], areaIdSet: Long[], name, comment }
  │    [CycleCountController.java:62]
  │    type hardcoded = CycleCountType.PLANNED
  │    subtype hardcoded = CycleCountSubType.SKU
  ▼
CyclecountService.createCycleCount()            [CyclecountService.java:70]
  ├── createEntity()                            [CyclecountService.java:52]
  │     Cyclecount.number = "CC" + sequence
  │     Cyclecount.state  = CREATED
  │     Cyclecount.clientId = system client
  │
  ├── StockunitRepository.getStockUnitsBySkuSetAndAreaSetAndStates(
  │       skuSet, areaSet,
  │       exclude: SHIPPED, GOING_TO_DELETE)
  │
  └── For each matching Stockunit:
        Look up Unitload → get storagelocationId
        Create CyclecountPosition:
          number      = "CCP" + sequence
          state       = CREATED
          locationId  = unitload.storagelocationId
          unitloadId  = stockunit.unitloadId
          stockunitId = stockunit.id
          itemdataId  = stockunit.itemdataId
          amountbefore = stockunit.amount    ← snapshot taken here
          amountafter  = 0                   ← zeroed until operator counts
          cyclecountId = cyclecount.id
          version = 0
        Save position
```

No state transition occurs here — both header and all positions are `CREATED` after this step.

---

## 4. Counting Process

### 4a. Desktop View (read-only)

Desktop can view positions grouped three ways (all read-only aggregations):

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `POST /v3/cycleCount/itemDataView` | POST | 137 | Positions aggregated by SKU |
| `POST /v3/cycleCount/locationView` | POST | 149 | Positions for a SKU broken out by location |
| `POST /v3/cycleCount/positionView` | POST | 162 | Individual positions for a SKU + location |
| `GET /v3/cycleCount/detailView` | GET | ~185 | Paginated header list, filterable by state/keyword/clientId |
| `GET /v3/cycleCount/cycleCountDetailsById/{id}` | GET | 195 | Header detail for one cycle count |

### 4b. Mobile — Order-Driven Flow

This is the primary counting path. The operator selects a cycle count order, navigates location by location, and counts each unit load in turn.

```
GET /v3/cycleCountLos/orderList
  MobileCycleCountService.getCycleCountOrders()      [MobileCycleCountService.java:239]
  └── Returns Cyclecounts where state NOT IN (FINISHED, CANCELLED)

GET /v3/cycleCountLos/locationList/{orderId}
  MobileCycleCountService.getLocationList()          [MobileCycleCountService.java:254]
  └── Returns Locations for positions where state NOT IN (STARTED, FINISHED, CANCELLED)
      Sorted by CycleCountStrategy (rack/row order)

GET /v3/cycleCountLos/unitLoadList/{orderId}/{locationId}
  MobileCycleCountService.getCycleCountPositionList() [MobileCycleCountService.java:274]
  └── Returns list of {positionId, unitload.labelid} where state NOT IN (STARTED, FINISHED, CANCELLED)

POST /v3/cycleCountLos/processScanUnitLoad
  body: { orderId, locationId, unitLoadLabel }
  MobileCycleCountService.readCycleCountPositionByScannedUL()  [MobileCycleCountService.java:290]
  └── Resolves scanned label to a CyclecountPosition (query only — NO state change)
      Returns: position + stockUnit + itemdata + client + unitload + location map

POST /v3/cycleCountLos/countUnitLoad
  body: { cyclecountPosition, count, comment, orderId, locationId }
  MobileCycleCountService.countCycleCountStockUnit()  [MobileCycleCountService.java:306]
  ├── Validate: unitload not locked, stockunit not locked, exactly 1 SU on UL, not a carrier UL
  ├── If count == stockunit.amount (no discrepancy):
  │     position.amountbefore = stockunit.amount
  │     position.amountafter  = stockunit.amount
  │     position.state        = FINISHED
  │     Save position
  │     Check if ALL positions are now FINISHED/CANCELLED:
  │       → If yes: Cyclecount.state = FINISHED
  │     Return position (caller gets next UL list)
  └── If count != stockunit.amount:
        Return null → controller routes operator to recount screen
```

### 4c. Mobile — Single-UL Fast-Path Flow

Used for ad-hoc spot checks independent of a named cycle count order. Positions created here have **no `cyclecountId`** link.

```
GET /v3/cycleCountLos/scanSingleUnitLoad/{input}
  MobileCycleCountService.scanSingleUnitLoad()        [MobileCycleCountService.java:78]
  └── Resolve label → Stockunit; validate not locked, not carrier UL, exactly 1 SU

POST /v3/cycleCountLos/countSingleUnitLoad
  MobileCycleCountService.countSingleUnitLoad()       [MobileCycleCountService.java:118]
  ├── If count == stockunit.amount:
  │     Create CyclecountPosition via CyclecountPositionService.createEntity()
  │       type  = ADJUSTMENT, state = FINISHED, amountafter = amount
  │       cyclecountId = NULL (unlinked)
  │     Return null (done)
  └── If count != stockunit.amount:
        Return stockUnit → caller routes to recount
```

---

## 5. Discrepancy Handling and Stock Adjustment

When a count does not match `amountbefore`, the operator re-enters the count on a recount screen. Two paths handle this, depending on which counting flow is active.

### 5a. Order-Driven Recount

```
POST /v3/cycleCountLos/recountUnitLoad
  body: { cyclecountPosition, count, comment, orderId, locationId }
  MobileCycleCountService.countBySKURecount()         [MobileCycleCountService.java:380]
  ├── Validate locks (same as countUnitLoad)
  ├── position.amountbefore = stockunit.amount (re-snapshot)
  ├── position.amountafter  = count
  ├── position.state        = FINISHED
  ├── Save position
  ├── diff = count - stockunit.amount
  ├── If diff != 0:
  │     If count == 0 AND no FixLocationAssignment for unitload:
  │       stockunitBusinessService.sendStockUnitToNirvana(stockUnit,
  │           CODE_CYCLE_COUNT, position.number, comment)
  │       unitloadBusinessService.sendToNirvana(unitLoad,
  │           CODE_CYCLE_COUNT, position.number, comment)
  │     Else:
  │       stockunitBusinessService.changeAmount(stockUnit, count,
  │           CODE_CYCLE_COUNT, position.number, comment)
  │     messageService.sendStockChangeMessage([StockChangeDto(diff)])
  │         → HTTP POST to WEBSERVICE_STOCK_UPDATE sysprop URL
  │         → Result logged to message table as SENT / FAILED
  ├── Check remaining positions on this cyclecount:
  │     If any CREATED/STARTED position shares same locationId:
  │       return CYCLE_COUNT_COUNT_BY_SKU_RECOUNT_LOCATION_NOT_FINISHED
  │     If any CREATED/STARTED position exists (different location):
  │       return CYCLE_COUNT_COUNT_BY_SKU_RECOUNT_LOCATION_IS_FINISHED
  │     If all positions FINISHED/CANCELLED:
  │       Cyclecount.state = FINISHED
  │       return CYCLE_COUNT_COUNT_BY_SKU_RECOUNT_CYCLE_COUNT_IS_FINISHED
  └── Controller routes mobile UI based on returned navigation key
```

### 5b. Fast-Path Recount

```
POST /v3/cycleCountLos/recountSingleUnitLoad
  MobileCycleCountService.recountSingleUnitLoad()     [MobileCycleCountService.java:164]
  ├── Create CyclecountPosition via CyclecountPositionService.createEntity()
  │     type = ADJUSTMENT, amountafter = count, state = FINISHED
  │     cyclecountId = NULL (unlinked)
  ├── If count == 0 AND no FixLocationAssignment:
  │     sendStockUnitToNirvana + sendToNirvana (unitload)
  ├── Else:
  │     stockunitBusinessService.changeAmount(stockUnit, count, CODE_CYCLE_COUNT, ...)
  ├── messageService.sendStockChangeMessage([StockChangeDto(diff)])
  └── (no parent cycle count to advance)
```

---

## 6. Count Completion and Stock Record Reconciliation

Completion is **automatic** — there is no explicit "close" API call. The parent `Cyclecount` transitions to `FINISHED` when the last non-terminal `CyclecountPosition` is resolved.

**Auto-rollup logic** (present in both `countCycleCountStockUnit` and `countBySKURecount`):

```
After saving a position as FINISHED:
  For each CyclecountPosition where cyclecountId = this cyclecount:
    If any position.state IN (CREATED, STARTED):
      → do NOT finish the parent; return
  All positions are FINISHED or CANCELLED:
    → Cyclecount.state = FINISHED
    → Save cyclecount
```

**Stock record reconciliation** is handled entirely by `StockunitBusinessService.changeAmount()`, not by cycle-count code directly. `changeAmount` is responsible for writing `Stockrecord` rows. Cycle-count code only calls `changeAmount` — it does not write `Stockrecord` itself. A refactor of `changeAmount` that removes `Stockrecord` writes will silently break cycle-count audit trails.

---

## 7. State Transitions — Service Method References

### Cyclecount (header)

| From | To | Trigger | Service method | Line |
|---|---|---|---|---|
| — | CREATED | Admin creates | `CyclecountService.createEntity` | 52 |
| CREATED/STARTED | FINISHED | All positions terminal (auto-rollup) | `MobileCycleCountService.countCycleCountStockUnit` | 369 |
| CREATED/STARTED | FINISHED | All positions terminal after recount | `MobileCycleCountService.countBySKURecount` | 475 |
| CREATED/STARTED | CANCELLED | Admin cancels | `CyclecountService.cancelCycleCount` | 138 |
| FINISHED/CANCELLED | — | No-op (guard returns early) | `CyclecountService.cancelCycleCount` | 113 |

### CyclecountPosition

| From | To | Trigger | Service method | Line |
|---|---|---|---|---|
| — | CREATED | Position created during cycle count setup | `CyclecountService.createCycleCount` | 87 |
| — | CREATED | Fast-path position created | `CyclecountPositionService.createEntity` | 43 |
| CREATED | FINISHED | Count matches expected | `MobileCycleCountService.countCycleCountStockUnit` | 350 |
| CREATED | FINISHED | Recount submitted (order-driven) | `MobileCycleCountService.countBySKURecount` | 425 |
| CREATED | FINISHED | Fast-path count (no discrepancy) | `MobileCycleCountService.countSingleUnitLoad` | 153 |
| CREATED | FINISHED | Fast-path recount | `MobileCycleCountService.recountSingleUnitLoad` | 200 |
| CREATED/STARTED | CANCELLED | Admin cancels parent | `CyclecountService.cancelCycleCount` | 126 |

**Note:** `STARTED` state exists in constants and queries but **no service method explicitly sets it**. Positions created by `createCycleCount` start as `CREATED`; fast-path positions also start as `CREATED`. The `STARTED` state is never written by v1 service code — it is reserved or used externally (possibly via direct DB update or a path not present in these files).

---

## 8. Web REST Endpoints — Desktop (`/v3/cycleCount/`)

Owner: `CycleCountController.java`

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `create` | POST | 62 | Create cycle count from SKU + area filter sets |
| `cancel` | POST | 83 | Cancel one or more cycle counts (comma-separated `ids`) |
| `export` | POST | 113 | Stream Excel file (aggregated + detailed sheets) |
| `itemDataView` | POST | 137 | Positions aggregated by SKU |
| `locationView` | POST | 149 | Positions for a SKU by location |
| `positionView` | POST | 162 | Per-position drill-down |
| `detailView` | GET | ~185 | Paginated header list, filter by state/keyword/clientId |
| `cycleCountDetailsById/{id}` | GET | 195 | Header detail for one cycle count |

**No reopen endpoint.** Terminal states are absolute.

---

## 9. Mobile REST Endpoints (`/v3/cycleCountLos/`)

Owner: `CycleCountLosController.java`

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `scanSingleUnitLoad/{input}` | GET | 65 | Resolve UL label → Stockunit (no state change) |
| `countSingleUnitLoad` | POST | 101 | Fast-path count — creates unlinked position if match |
| `recountSingleUnitLoad` | POST | 141 | Fast-path recount — writes position, adjusts stock |
| `orderList` | GET | 170 | List CREATED/STARTED cycle count orders |
| `locationList/{orderId}` | GET | 177 | Locations for this count, sorted by rack strategy |
| `unitLoadList/{orderId}/{locationId}` | GET | 184 | Position list as {positionId, labelid} pairs |
| `processScanUnitLoad` | POST | 191 | Resolve scanned label to a CyclecountPosition |
| `countUnitLoad` | POST | 229 | Count a position; routes to recount or next UL |
| `recountUnitLoad` | POST | 265 | Recount on mismatch; returns navigation key |

---

## 10. Sysprop Gates

`MobileCycleCountService` reads three sysprops at request time (no caching):

| Sysprop key | Default | Behavior |
|---|---|---|
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | `true` | Show `amountbefore` to operator before they enter count |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` | `0` | Only reveal expected amount when provisional count differs by ≥ N |
| `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT` | `true` | Require a comment when submitting a recount |

Setting `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT=false` enables a "blind count" policy — operators cannot see the expected quantity and any mismatch routes through the full recount path.

---

## 11. Transaction Boundaries

- Neither `CyclecountService` nor `MobileCycleCountService` carries a class-level `@Transactional`. Repository operations inherit `tenantTransactionManager` via Spring Data JPA configuration.
- `cancelCycleCount` walks the header and all positions in one logical unit — any mid-walk failure rolls back the entire cancel.
- `countBySKURecount` binds position write + stock adjustment + OMS message dispatch in one effective transaction; failure anywhere rolls everything back.
- `countCycleCountStockUnit` (no discrepancy path) binds only the position write and the optional parent finish — no stock adjustment is involved.
- No `REQUIRES_NEW` anywhere in this flow.
- Optimistic `@Version` on both `Cyclecount` and `CyclecountPosition` is the only concurrency guard — no pessimistic locks.

---

## 12. OMS Integration

One touchpoint only: `MessageService.sendStockChangeMessage(List<StockChangeDto>)`.

- Fires on every non-zero delta from `countBySKURecount` and `recountSingleUnitLoad`.
- Does **not** fire when count matches `amountbefore` (the `STARTED == 0` fast path through `countCycleCountStockUnit`).
- The message HTTP-POSTs to the URL in sysprop `SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY`.
- Result logged to the `message` table as `SENT` or `FAILED`.
- There is no `WEBSERVICE_CYCLE_COUNT_*` event — OMS learns about inventory changes as stock deltas, not as count lifecycle events.

---

## 13. Common Failure Modes

### Orphaned cycle count positions

**Symptom:** `cyclecount_position` rows exist with `cyclecount_id = NULL`.

**Cause:** Fast-path flows (`countSingleUnitLoad`, `recountSingleUnitLoad`) create positions via `CyclecountPositionService.createEntity`, which sets `cyclecountId` to null. These rows are intentional audit records but have no parent header. They will never appear in desktop view filters (which query by `cyclecount_id`).

**Fix / diagnosis:**
```sql
-- Find all unlinked positions
SELECT * FROM cyclecount_position WHERE cyclecount_id IS NULL ORDER BY created DESC;
```
These are expected artefacts of the fast-path. They need no remediation unless they represent a bug where `createCycleCount` failed to set the FK.

### Cycle count stuck in CREATED, never progresses to FINISHED

**Cause A:** One or more positions are still in `CREATED` state. The auto-rollup only fires when every position is `FINISHED` or `CANCELLED`. A single unvisited position blocks the parent.

**Diagnosis:**
```sql
SELECT id, number, state, unitload_id, stockunit_id, location_id
FROM cyclecount_position
WHERE cyclecount_id = <id>
  AND state NOT IN ('FINISHED', 'CANCELLED');
```

**Fix:** The operator must count the remaining positions, or an admin must cancel the whole cycle count and create a new one covering only the remaining stock.

**Cause B:** The `STARTED` state never has a service method that transitions away from it in v1. If a position was externally set to `STARTED` (e.g., direct DB update or a mobile app that sets it optimistically), the auto-rollup loop in `countCycleCountStockUnit:353` treats `STARTED` as non-terminal and will never finish the parent — even if the operator counted it. Check whether any positions are stuck in `STARTED`:

```sql
SELECT * FROM cyclecount_position WHERE state = 'STARTED';
```

**Forced resolution (last resort):** After confirming the positions are genuinely counted and the stock values are correct, manually transition stuck positions:
```sql
UPDATE cyclecount_position SET state = 'FINISHED' WHERE id = <position_id>;
-- Then re-check if all positions on the parent are terminal:
UPDATE cyclecount SET state = 'FINISHED'
WHERE id = <cyclecount_id>
  AND NOT EXISTS (
    SELECT 1 FROM cyclecount_position
    WHERE cyclecount_id = <cyclecount_id>
      AND state NOT IN ('FINISHED', 'CANCELLED')
  );
```

### Cycle count stuck in STARTED at header level

The header has no explicit `STARTED` transition in service code either. If a header record has `state = 'STARTED'`, it was set externally. The auto-rollup only sets the header to `FINISHED` — it never sets it to `STARTED`. Safe to manually fix with the same pattern as above.

### Count of 0 did not delete stock unit

`sendStockUnitToNirvana` is only called when **both** conditions hold:
1. `count == 0`
2. No `FixLocationAssignment` exists for the unitload

If a fix-location assignment is present, `changeAmount(stockUnit, 0, ...)` is called instead, leaving a zero-quantity stock unit in place. This is intentional — the fix-location slot is preserved. Check for fix assignment:
```sql
SELECT * FROM fix_location_assignment WHERE assigned_unitload_id = <unitload_id>;
```

### OMS never received the stock delta

Check the `message` table for the position's number:
```sql
SELECT * FROM message WHERE reference_number = '<position_number>' ORDER BY created DESC;
```
A `FAILED` row means the HTTP POST to `WEBSERVICE_STOCK_UPDATE` failed. The stock was still adjusted locally — the OMS sync is fire-and-forget with no automatic retry in v1.

### Position numbers starting with `SID` instead of `CCP`

Fast-path positions created by `CyclecountPositionService.createEntity` use `EntityPrefixes.SHIPPERID` (`SID`) as the number prefix (line 41) instead of `EntityPrefixes.CYCLECOUNT_POSITION` (`CCP`). This is a copy-paste bug. Order-driven positions created by `CyclecountService.createCycleCount` use the correct `CCP` prefix. Do not use the number prefix to distinguish fast-path from order-driven positions — use `cyclecount_id IS NULL` instead.

---

## 14. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | `CyclecountService.java` (6 methods), `CyclecountPositionService.java` (1 method), `MobileCycleCountService.java` (12 methods), `CycleCountController.java` endpoints, `CycleCountLosController.java` endpoints, `WmsConstants.java` (CycleCountState, CycleCountType, CycleCountSubType, EntityPrefixes, MobileNavigation, sysprop keys), `Cyclecount.java`, `CyclecountPosition.java` — all file:line refs verified | Confirmed | Code read |

**Re-verify every 90 days.** Next due: **2026-07-25**.
