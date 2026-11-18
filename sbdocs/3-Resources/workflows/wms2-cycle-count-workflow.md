---
title: "WMS v2 — Cycle Count Workflow"
type: workflow
status: active
version: v2
scope: cycle-count
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: code read of v2/wms2-api origin/develop df30fa62 — CyclecountService + MobileCycleCountService + CycleCountController + CycleCountLosController + CyclecountRepository; export endpoint (SBDEV-2632); SBDEV-3854/3857 transaction and posted-row fixes
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
**Owner:** Nam Park · **Last verified:** 2026-11-11

---

## 1. Overview

Cycle count compares `amountbefore` (expected quantity — snapshotted at creation, then **overwritten with the live stock-unit amount at count time** by `countCycleCountStockUnit` / `countBySKURecount`) against `amountafter` (operator count) per position. The match test itself compares the *live* `stockunit.amount` with the count, not the creation snapshot. When they diverge, `stockunit.amount` is adjusted via `StockunitBusinessService.changeAmount(...)` and a stock-change message fires to OMS via `WEBSERVICE_STOCK_UPDATE`.

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
CREATED ───────────→ FINISHED      (happy path, terminal)
    │
    └─────────────→ CANCELLED     (admin-only, terminal)
```

**`STARTED` is a declared state that no Java code ever writes.** `WmsConstants.CycleCountState.STARTED` is only *compared* (cancel guard `CyclecountService.java:139,155`; mobile filters `MobileCycleCountService.java:362,382,458,557`); `grep -rn 'setState(.*CycleCountState.STARTED' src/main/java` finds nothing, and every `setState` in the cycle-count code targets `CREATED` (`CyclecountService:94,118`, `CyclecountPositionService:51`), `FINISHED` (`MobileCycleCountService:190,247,451,528` positions; `:470,577` header) or `CANCELLED` (`CyclecountService:157,169`). A cycle count is therefore `CREATED` for its whole working life; counting never moves it to STARTED.

---

## 3. Lifecycle

```
Admin creates a cycle count
  │  POST /v3/cycleCount/create {skuIdSet, areaIdSet, name, comment}
  │        [CycleCountController:77]
  ▼
CyclecountService.createCycleCount()
  ├── Create Cyclecount (state = CREATED, type PLANNED, subtype SKU)
  ├── For each stockunit matching the SKU set + area set, excluding entity locks SHIPPED and GOING_TO_DELETE
  │     (stockunitRepository.getStockUnitsBySkuSetAndAreaSetAndStates):
  │     Create CyclecountPosition (state = CREATED, amountbefore = current stockunit.amount, amountafter = 0)
  └── ⚠ NO enclosing transaction (§8): each save() commits on its own

Mobile operator takes it
  │  GET /v3/cycleCountLos/orderList            → every Cyclecount whose state is not FINISHED/CANCELLED (in practice CREATED)
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
  │        MobileCycleCountService.countCycleCountStockUnit()    [line 411]
  │        ├── Re-reads the stored position + locks its stock unit (SBDEV-3857); refuses a FINISHED/CANCELLED one
  │        ├── If count == live stockunit.amount: Position.amountbefore = amountafter = that amount,
  │        │     Position.state = FINISHED, no stock change;
  │        │     if no other position of the cyclecount is non-terminal: parent Cyclecount → FINISHED;
  │        │     returns the COUNTED position (controller then adds the remaining `unitLoads` list and,
  │        │     when that list is empty, `isOrderFinished`)
  │        └── If count != amountbefore: nothing is written; returns null — the app must prompt a recount
  │
  ▼ [only if count != amountbefore]
Operator confirms recount
  │  POST /v3/cycleCountLos/recountUnitLoad {cyclecountPosition, count, comment, orderId, locationId}
  │        MobileCycleCountService.countBySKURecount()           [line 483]
  │        ├── Position.amountbefore = live stockunit.amount; Position.amountafter = count; Position.state = FINISHED
  │        ├── diff = count - stockunit.amount
  │        ├── If diff != 0:
  │        │     If count == 0 and the unit load has no FixLocationAssignment:
  │        │          sendStockUnitToNirvana(stockUnit) + unitloadBusinessService.sendToNirvana(unitLoad)
  │        │     Else:          stockunitBusinessService.changeAmount(stockUnit, count, CODE_CYCLE_COUNT, ...)
  │        │     messageService.sendStockChangeMessage([StockChangeDto(diff, …, activityCode CYCLE_COUNT)])  → STOCK_UPDATE to OMS (after commit)
  │        ├── If all positions done: Cyclecount → FINISHED
  │        └── Return nextProcess: {unitLoad | location | order} (location-not-finished / location-finished / cycle-count-finished)
  ▼
Cyclecount.state = FINISHED (auto-rolled when all positions are terminal; there is no STARTED step before it)

Admin cancels (before completion)
  │  POST /v3/cycleCount/cancel {ids: "1,2"}    [CycleCountController:98]
  │        per id (SBDEV-3562/3731): a bad/unknown id or a service exception is ONE per-id error, never an abort;
  │        the response is HTTP 200 either way, with {errors:[…]} when any id failed
  ▼
CyclecountService.cancelCycleCount()
  ├── State FINISHED/CANCELLED → silent no-op return (the controller still answers success for that id)
  ├── All positions in {CREATED, STARTED}: state = CANCELLED (FINISHED positions are left as counted)
  ├── Cyclecount.state = CANCELLED
  └── ⚠ NO enclosing transaction (§8)

Admin exports
  │  POST /v3/cycleCount/export {ids:[1,2]} | {id:"1, 2"}   [CycleCountController:148]
  ▼
Excel file returned — "aggregated" sheet (by SKU) + "detailed" sheet (per position)
  │  Single selection  → legacy columns (the file name is chosen by the web UI, `exportCyclePop.vue`: the cycle-count number)
  │  Multi selection   → both sheets gain a leading "Cycle Count" column (UI names it `CC_Multiple`);
  │                      server limits: at most 100 cycle counts (`MAX_BULK_EXPORT_CYCLE_COUNTS`) and 50,000 positions
  │                      in total (`MAX_BULK_EXPORT_POSITIONS`) — over either is a 422;
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

All under `/v3/cycleCountLos/...` (LOS = Location/Order/SKU). Owner: `CycleCountLosController` (`controller/mobile/`; class-level `@RequiresFunction(MOBILE_UI_VIEW_CYCLE_COUNT)`). Line = mapping annotation, `df30fa62`.

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `scanSingleUnitLoad/{input}` | GET | 77 | Resolve UL label → full context (no state change) |
| `countSingleUnitLoad` | POST | 113 | Fast-path count. **Match** → writes a `FINISHED` position of type `ADJUSTMENT` (`amountafter` = stock amount) and returns null; **mismatch** → writes nothing and returns the stock unit so the app can ask for a recount |
| `recountSingleUnitLoad` | POST | 153 | Fast-path recount — writes position, adjusts stock |
| `orderList` | GET | 182 | List cyclecounts not FINISHED/CANCELLED (`CyclecountRepository.getCycleCountOrders`) |
| `locationList/{orderId}` | GET | 189 | Locations for this count, sorted by rack strategy |
| `unitLoadList/{orderId}/{locationId}` | GET | 196 | UL pick list (position.id + unitload.labelid) |
| `processScanUnitLoad` | POST | 203 | Resolve scanned UL to a specific position |
| `countUnitLoad` | POST | 241 | Count a position. Match → returns the counted position plus the remaining `unitLoads`; `isOrderFinished` is set only when that list is empty. Mismatch → `cyclecountPosition: null` (prompt a recount) |
| `recountUnitLoad` | POST | 277 | Recount on mismatch. Returns `nextProcess ∈ {unitLoad, location, order}` |

All 9 routes answer HTTP 200 with an `{errors:[…]}` body on a `BusinessException` (no 4xx). **Enumeration:** `grep -cE '@(Get|Post)Mapping' controller/mobile/CycleCountLosController.java` = 9.

---

## 5. Web REST Endpoints

Under `/v3/cycleCount/...`. Owner: `CycleCountController`; every route is `@RequiresFunction(WEB_UI_VIEW_CYCLECOUNT)`. Line = mapping annotation, `df30fa62`.

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `create` | POST | 77 | Create new cycle count from SKU + area filters (type PLANNED, subtype SKU) |
| `cancel` | POST | 98 | Cancel one or more cycle counts (`ids` comma-separated); per-id errors, HTTP 200 |
| `export` | POST | 148 | Export Excel (aggregated + detailed sheets). Accepts `ids` array **or** legacy comma-separated `id`; multi-selection merges into one workbook. 422 / 404 / 500 + JSON on failure |
| `itemDataView` | POST | 286 | List aggregated by item |
| `locationView` | POST | 299 | List by location within an item |
| `positionView` | POST | 313 | List per-position (drill-down) |
| `detailView` | GET | 327 | Paginated list, filter by state / keyword / clientId |
| `cycleCountDetailsById/{id}` | GET | 343 | Header detail for one cycle count |

**No reopen endpoint.** Terminal states are absolute. **Enumeration:** `grep -cE '@(Get|Post)Mapping|@RequestMapping\(value' controller/CycleCountController.java` = 8.

---

## 6. Stock Adjustment Semantics

`countBySKURecount` (the recount) always writes the position and, only when `count != the live stock amount`, adjusts stock and tells OMS. All of it runs in one transaction (true only since SBDEV-3854 ✓ merged(SBDEV-3854: wms2-api #552 c9e8f9a1, 2026-10-21); before it the method had no `@Transactional`, so the FINISHED position committed on its own and a recount to **zero** always failed with HTTP 500):

1. **Position**: `position.amountafter = count; position.state = FINISHED`.
2. **Stock unit**: one of:
   - `count == 0` and the unit load has **no `FixLocationAssignment`** → `sendStockUnitToNirvana(stockUnit)` **and** `unitloadBusinessService.sendToNirvana(unitLoad)` (retires the stock and the container, effectively deleting them from inventory). With a fixed-location assignment the zero count goes through `changeAmount(stockUnit, 0, …)` instead and the container stays.
   - `count > 0` → `stockunitBusinessService.changeAmount(stockUnit, count, WmsConstants.CODE_CYCLE_COUNT, position.getNumber(), comment)`. `changeAmount()` is `@Transactional("tenantTransactionManager")` (`StockunitBusinessService.changeAmount`; re-verified 2026-10-21, SBDEV-3854). It takes the stock unit's PESSIMISTIC_WRITE lock through `LockReads.forUpdate`.
3. **OMS message** (SBDEV-2214 deferral, 2026-05-10): `messageService.sendStockChangeMessage(List<StockChangeDto>)` now delegates to `StockChangeNotificationService.sendAfterCommit(...)` → `OmsNotificationService.sendAfterCommit(urlPath, payload, STOCK_UPDATE)` (still one of the 5 remaining `omsNotificationService.sendAfterCommit` call-sites, see [wms2-oms-integration-map.md §2.9](../architecture/wms2-oms-integration-map.md)). The `StockChangeDto` carries `activityCode = CYCLE_COUNT` as the machine-readable adjustment reason (SBDEV-2658, `SharedService.getStockChangeDTO`). The HTTP POST to `WEBSERVICE_STOCK_UPDATE` (sysprop `SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY`) fires only AFTER the surrounding cycle-count transaction commits — rollback silently drops the POST. Result logged to `message` table as SENT/FAILED by `OmsNotificationService.doSend` on the listener side.

Audit: `Stockrecord` is not written directly from this path — `changeAmount()` writes that itself.

---

## 7. Sysprop Gates

⚠ **These three sysprops are inert in the code of record (checked 2026-11-11).** `MobileCycleCountService` declares the accessors `isShowExpectedAmount()` (`:336`), `isShowExpectedAmountWhenDiffBy()` (`:340`) and `isForceCommentAfterRecount()` (`:332`), but **nothing calls them**: `grep -rn 'isForceCommentAfterRecount\|isShowExpectedAmount' src/main/java` returns only the three declarations, no `CycleCount*Controller` exposes them, and the server never enforces a recount comment. The mobile UI side is not proven either: `git grep -i 'expected_amount\|force_comment\|ShowExpected'` on `v2/wms2-mobile-ui` `origin/develop` (`65ec4dd`) finds nothing. ⚠ unverified 2026-11-11: whether `wms2-mobile-ui` or a deployed build reads the rows through a generic sysprop fetch under another spelling; the table below is therefore the *intended* behaviour from the seed descriptions (`V1.0.04` rows 63-65), not observed behaviour. Decision needed: wire them or delete them. See [wms2-sysprop-catalog.md §10](../data-dictionary/wms2-sysprop-catalog.md) Cycle count rows; absent-row behaviour (`parseBoolean(null)` = false, `Integer.parseInt(null)` throws) is in that catalog's absent-sysprop table. **Decision 2026-11-12 (Nam): delete, don't wire.** SBDEV-4125 removes the three accessors, their constants, and the rows (migration `V2.2.52`) ✓ merged(SBDEV-4125: #668 465a4908, 2026-11-12). Once it merges, the table below describes settings that no longer exist.

| Sysprop | Default | Behavior |
|---|---|---|
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` | `true` | If true, show `amountbefore` to operator before they count |
| `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` | `0` | Only show expected amount when the operator's provisional count differs by ≥ N |
| `CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT` | `true` | Require a comment on the recount — no mismatch silently commits |

~~Flipping `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` to `false` is the usual "blind count" policy — operators enter whatever they see, and any mismatch always triggers the recount path.~~ Never true in v2: the setting was inert, and SBDEV-4125 deletes it ✓ merged(SBDEV-4125: #668 465a4908, 2026-11-12).

---

## 8. Transaction Boundaries

- `CycleCountController` methods have no explicit `@Transactional` — repositories inherit `tenantTransactionManager` via Spring Data JPA config.
- ⚠ **`CyclecountService.createCycleCount()` and `cancelCycleCount()` are NOT transactional** (`grep -n Transactional src/main/java/net/aim_ai/wms/service/CyclecountService.java` → no hits; neither is `CycleCountController`). Each `save()` commits on its own. A failure part-way through `createCycleCount` (e.g. a missing unit load for one stock unit, `EntityNotFoundException`) leaves a `CREATED` cycle count with only some of its positions; a failure part-way through `cancelCycleCount` leaves some positions `CANCELLED` under a header still `CREATED`. The earlier claim here that a mid-way throw "rolls the whole cancel back" was wrong. Recovery for a half-cancelled count: cancel it again (the position loop skips terminal positions).
- `MobileCycleCountService.countBySKURecount()`, `recountSingleUnitLoad()`, `countCycleCountStockUnit()` and `countSingleUnitLoad()` are each `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` (`MobileCycleCountService.java:152,204,410,482`). The two recounts bind position write + stock adjustment + OMS message in one transaction; a failure anywhere rolls everything back — no partial commits. **True only since SBDEV-3854 ✓ merged(SBDEV-3854: wms2-api #552 c9e8f9a1, 2026-10-21).** Before it neither method was `@Transactional`: the position was saved FINISHED on its own, and a recount to zero reached `sendStockUnitToNirvana` with no transaction and returned HTTP 500 (its self-invoked `changeAmount` lock read needs one). Measured 2026-10-21: no v2 PRD tenant has run a cycle count since 2026-02-05, so no residue. **Every mobile count judges the database row, never the posted copy, since SBDEV-3857 ✓ merged(SBDEV-3857: wms2-api #554 56797fed, 2026-10-21).** The request body carries whole `Stockunit` / `CyclecountPosition` entities.
  - `recountSingleUnitLoad` locks the stock unit by the posted id (`LockReads.forUpdate`) and refuses unless it is still on the posted container ("was moved or removed from container … scan the container again").
  - `countSingleUnitLoad` re-reads the stock unit and applies the same container check.
  - `countCycleCountStockUnit` and `countBySKURecount` re-read the stored position and refuse a FINISHED or CANCELLED one ("is already counted or cancelled"), instead of saving the posted copy.
  - `countBySKURecount` locks the position's stock unit, then refreshes the position and checks its state again under that lock.
  - Both recounts take `amountbefore` and the OMS delta from the locked row.
  - Before the fix, a posted `amount=0, reservedamount=0` retired a real stock unit (12 units, 5 reserved) on DEV and told OMS `normal:0`. The two first counts also run in one tenant transaction now.
- Locks: the recount's stock change takes the stock unit's PESSIMISTIC_WRITE row lock (`changeAmount` → `LockReads.forUpdate`, also reached via `sendStockUnitToNirvana` on a recount to zero); since SBDEV-3854 ✓ merged(SBDEV-3854: wms2-api #552 c9e8f9a1, 2026-10-21) it is held until the recount commits. `Cyclecount` and `CyclecountPosition` themselves are guarded only by optimistic `@Version` (inherited from `AbstractBaseEntity`). *(Corrected 2026-10-21: this line used to say there were no pessimistic locks in the path.)*

`REQUIRES_NEW`: only the position-number draw (`basicService.generateNumber` → `SequenceTransactionService`); everything else joins the recount's transaction. *(Corrected 2026-10-21: this line used to say there was none.)*

---

## 9. OMS Integration

Only one touchpoint: `WEBSERVICE_STOCK_UPDATE` (via `MessageService.sendStockChangeMessage`; payload `activityCode = CYCLE_COUNT`, SBDEV-2658). A cycle-count adjustment otherwise reaches OMS only as this stock delta; the cycle-count code has no `outboxService.enqueue` and no `_ACTIVATED` gate (census: [wms2-oms-integration-map.md §2.9](../architecture/wms2-oms-integration-map.md)). `countBySKURecount` sends it only when the recount produces a non-zero delta; `recountSingleUnitLoad` does the same since SBDEV-3857 ✓ merged(SBDEV-3857: wms2-api #554 56797fed, 2026-10-21); before that it always sent one, with a 0 delta when the count matched. *(Corrected 2026-10-21, SBDEV-3854 round-3 review.)* No cycle-count-lifecycle callback (no `WEBSERVICE_CYCLE_COUNT_*` sysprop) — OMS learns about inventory changes as stock deltas, not count events.

---

## 10. Known Landmines

1. **`CANCELLED` spelling.** String state. `WmsConstants.CycleCountState.CANCELLED`. Don't confuse with integer `CANCELED`.
2. **No reopen.** Once `FINISHED` or `CANCELLED`, terminal. Admin correction = create a new cycle count.
3. **The fast-path `countSingleUnitLoad` creates the position row only on a MATCH.** A match writes a `FINISHED` `ADJUSTMENT` position (`amountafter` = stock amount) and returns null; a mismatch writes nothing and returns the stock unit, so a count that is abandoned before the recount leaves no audit row. ⚠ Corrected 2026-11-11: this item said the *match* path creates no row (inverted; the code has done this since the initial check-in, `MobileCycleCountService.java:185-193`).
4. **No Stockrecord written directly** from cycle-count code — it's via the downstream `changeAmount` path. A refactor of `changeAmount` that removes the Stockrecord write breaks cycle-count audit.
5. **No scheduled job touches cycle count** (`grep -il cyclecount` over `schedulejob/` and `service/job/` finds none). Don't expect background recalc or cleanup — the whole lifecycle is event-driven.
6. **Cancel guard only accepts `CREATED` or `STARTED`.** Attempting to cancel a `FINISHED` or `CANCELLED` cyclecount is a **silent no-op** — the service returns without error and `/cancel` still answers success (`REMOVED SELECTED ITEM`) for that id. It is not a revert. ⚠ Corrected 2026-11-11: this said "error-returning".
7. **Mobile fast-path and order-driven flow coexist.** `scanSingleUnitLoad` / `countSingleUnitLoad` / `recountSingleUnitLoad` are independent of `orderList` / `locationList` / `processScanUnitLoad` / `countUnitLoad` / `recountUnitLoad`. Mixing them on the same cycle count may produce duplicate position rows.
8. **`Cyclecount.state = FINISHED` is auto-rolled** only when ALL positions reach terminal state (checked by `countCycleCountStockUnit` on a match and by `countBySKURecount`; the fast-path `countSingleUnitLoad` / `recountSingleUnitLoad` never touch a cycle count header). A single stuck position blocks parent finalization — check with `positionView` API.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| Cyclecount never finishes (it will show `CREATED`; STARTED is never written, §2) | §3 auto-rollup + §10 item 8 — find the non-terminal position via `positionView` |
| Operator can't find the cyclecount on mobile | `orderList` excludes FINISHED and CANCELLED — if someone already cancelled or finished it, it disappears |
| Count matches but expects recount prompt | §6 + §7 — note the server compares the count with the *live* stock amount, and the `…_WHEN_DIFF_BY` sysprop is unread server-side |
| Stock adjusted but OMS never got the delta | §6 item 3 + `message` / `message_archived` tables |
| Admin pressed cancel but nothing changed | §10 item 6 — state was already terminal |
| Two position rows for the same UL | §10 item 7 — mixing fast-path + order-driven |
| Cycle count has fewer positions than expected / header still CREATED with some CANCELLED positions | §8 — create/cancel are not transactional; re-run the cancel, or cancel and recreate |
| Count of 0 didn't delete the stock unit | §6 item 2 — confirm `sendStockUnitToNirvana` fired; check logs |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `CyclecountService` (6 methods), `MobileCycleCountService` (12 methods), `CycleCountController` (8 endpoints), `CycleCountLosController` (9 mobile endpoints), sysprop gates, cancel guard, stock-change wire-up | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-11-11 | Re-verified against wms2-api `origin/develop` `df30fa62`: all 17 routes re-anchored (mobile +2, web +17..+69); states (STARTED never written; 3 setState targets); `createCycleCount`/`cancelCycleCount` have no `@Transactional`; countSingleUnitLoad match path writes a FINISHED ADJUSTMENT position (item 3 was inverted); `countUnitLoad` returns the counted position / null (not "next position"); zero-count recount also retires the unit load unless a FixLocationAssignment exists; cancel of a terminal count is a silent no-op; export limits 100 counts / 50,000 positions; export filename is a web-UI choice; the three CYCLE_COUNT_* sysprops have no caller in wms2-api and no hit in wms2-mobile-ui `65ec4dd`; SBDEV-2658 activity code on the STOCK_UPDATE payload. SBDEV-3854/3857 claims (§6, §8, §9) re-read and confirmed in `MobileCycleCountService`. Not re-verified: web-ui/mobile-ui behaviour beyond the grep above; `CycleCountStrategy` sort order (§3 `locationList` line) and the Nirvana retire internals. | See corrections | Code read (grep-based) |

**Re-verify every 90 days.** Next due: **2027-02-09**.
