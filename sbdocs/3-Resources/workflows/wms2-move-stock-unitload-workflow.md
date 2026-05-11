---
title: "WMS v2 — Move Stock + Move Unitload Workflow"
type: workflow
status: active
version: v2
scope: move-stock-unitload
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-10
verified_by: code read of v2/wms2-api MobileMoveUnitloadService + MobileMoveStockService + UnitloadBusinessService + StockunitBusinessService
related:
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ../data-dictionary/wms2-sysprop-catalog.md
  - ./wms2-receiving-putaway-workflow.md
  - ./wms2-bol-truck-loading-workflow.md
tags:
  - workflow
  - move-stock
  - move-unitload
  - wms2
---

# WMS v2 — Move Stock + Move Unitload Workflow

**Scope:** Two mobile-only flows that relocate inventory on the warehouse floor — full unit load moves and partial stock splits · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

Two mobile pages, one concept with an important split:

- **Move Unitload** (`/mobile/move-unitload`, role `MOBILE_UI_VIEW_TRANSFER`) — moves a whole unit load (pallet or tote) to a new location or onto a carrier pallet. One entity row changes location; no stock unit rows created or destroyed.
- **Move Stock** (`/mobile/move-stock`, role `MOBILE_UI_VIEW_STOCK_TRANSFER`) — splits a stock unit's contents. A new `Stockunit` row is created at the destination; the source stock unit's `amount` decrements. Activity code: `CODE_MANUAL_SPLIT`.

Two things to hold:

1. **Both flows write audit trails** (`stockrecord`, `unitload_record`) and **fire `WEBSERVICE_STOCK_UPDATE`** via `MessageService.sendStockChangeMessage` when inventory changes.
2. **Move Unitload on an outbound pallet** cleans up orphaned `BillofladingPosition` rows via `handleTruckOffLoading()` when the destination label matches the outbound-pallet regex. Without that cleanup, a BOL would reference a unit load that's no longer on its gate location.

---

## 2. Entities and Audit Trail

| Entity | Role | Written by both flows? |
|---|---|---|
| `Unitload` | Pallet / tote / carton — carrier of stock | Yes (`storagelocationId`, `carrierunitloadId`) |
| `Stockunit` | Amount at a location — the thing that actually splits in Move Stock | Move Stock only |
| `Stockrecord` | Stock-movement audit ledger | Yes — via `StockrecordService.recordTransferStockUnit / recordRemoval / recordCreation` |
| `UnitloadRecord` | Unit-load movement history | Yes (Move Unitload) — via `UnitloadRecordService.recordForTransferUnitLoad` |
| `Message` / `MessageArchived` | OMS callback audit | Yes when inventory changes |

---

## 3. Move Unitload — Flow

```
Operator scans UL label on mobile
  │  GET /v3/moveUnitload/selectSource/{input}    [MoveUnitloadController]
  ▼
MobileMoveUnitloadService.scanUnitLoad()           [line 111]
  ├── Validate label not empty, not "NIRVANA"
  ├── Look up Unitload; validate:
  │     · not the Nirvana UL
  │     · not on NIRVANA or SHIPPED location
  │     · not ON_HOLD lock
  │     · no fixed-location assignment
  │     · no reserved stock
  └── Return TransferInfoDto (UL + current location + carrier + FLA hints)

Operator scans destination (location OR pallet label)
  │  POST /v3/moveUnitload/selectDestination      [TransferInfoDto]
  ▼
MobileMoveUnitloadService.scanDestination()        [line 205]  @Transactional(tenantTransactionManager)
  │
  ├── Destination = location?
  │     Guards: not locked / not Nirvana / not Shipped / stock compatibility / flowbin rules
  │     → unitloadBusinessService.transferUnitLoadToLocation(source, dest, false, CODE_TRANSFER, ...)
  │
  ├── Destination = unitload label (pallet)?
  │     Guards: not circular / not same UL
  │     → unitloadBusinessService.transferUnitLoadToCarrier(source, parentPallet, CODE_TRANSFER, ...)
  │
  ├── Destination matches outbound-pallet regex?
  │     → handleTruckOffLoading(source.label)
  │         · delete BOL positions pointing at this UL (carrierId chain)
  │
  └── Commit — UL row updated, unitload_record appended, stock_record for child stockunits
```

### Core API: `UnitloadBusinessService`

| Method | Line | What changes |
|---|---|---|
| `transferUnitLoadToLocation(Unitload, Location, ignoreLock, code, ref, null)` | 108 | `unitload.storagelocationId = destination.id`; clears `carrierunitloadId` if was nested; recursively transfers children; writes `unitload_record` |
| `transferUnitLoadToCarrier(Unitload source, Unitload destination, code, ref, null)` | 179 | `source.carrierunitloadId = destination.id`; validates no circular parent chain |

**Optimistic-lock retry** wraps the carrier-clear step at line 161–166 via `optimisticLockRetry.executeWithRetry(...)`.

---

## 4. Move Stock — Flow

```
Operator scans stock unit ID or UL label
  │  GET /v3/moveStock/selectSource/{input}     [MoveStockController:1-119]
  ▼
MobileMoveStockService.selectSource()            [line 99]
  └── Return StockTransferDto with all stockunits on that UL (sorted by item number)

Operator selects stockunit + enters transfer amount
  │  GET /v3/moveStock/selectStockUnit/{id}/{input}    @Transactional(readOnly=true)
  ▼
MobileMoveStockService.selectStockUnit()         [line 191]
  ├── Guard: amount > 0 && amount <= stockunit.amount
  └── Return candidate destinations (flowbins + overstocks, sorted by DefaultStrategy; direction controlled by PICK_PATH_DIRECTION sysprop via PickPathConfig → DefaultStrategy)

Operator scans destination (location OR UL label)
  │  POST /v3/moveStock/scanDestination         [StockTransferDto]
  ▼
MobileMoveStockService.selectDestination()       [line 223]  @Transactional(tenantTransactionManager)
  │
  ├── Validate destination:
  │     · Not Nirvana / Shipped
  │     · If location: must be FLOWBIN type
  │     · If flowbin has FixLocationAssignment: source itemdata must match
  │     · If UL label: must match STRING_PATTERN_SEPARATE_STOCK (SU-\d{6}), or be an existing UL
  │
  ├── stockunitBusinessService.transferStockToUnitLoad(source, destUL, amount, CODE_MANUAL_SPLIT, ref, null, removeIfEmpty, ignoreLock)
  │     Depends on amount:
  │       · amount == source.amount AND no split needed:
  │           full move — reattach source to destUL
  │       · amount < source.amount:
  │           split — source.amount -= amount; NEW stockunit at dest with amount
  │
  ├── If source.amount reaches 0 and removeIfEmpty=true:
  │     sendStockUnitToNirvana(source) — effectively deletes from inventory
  │
  └── Commit — stockrecord (removal + creation or transfer), unitload_record if new UL created
```

### Core API: `StockunitBusinessService.transferStockToUnitLoad`

At line 173–322. Two code paths:

| Scenario | Effect | Stockrecord |
|---|---|---|
| Full move (entire source amount, no split) | Reattach `sourceStockunit.unitloadId ← destinationUnitload.id`; source row preserved | `recordTransferStockUnit` |
| Split move (partial) | Source `amount -= transfer`; create new stockunit at destination with `amount = transfer` | `recordRemoval(source)` + `recordCreation(destination)` |

**Pessimistic `PESSIMISTIC_WRITE` lock** on source stockunit via `StockunitRepository.findByIdForUpdate()` at line 188 — prevents TOCTOU under concurrent splits.

---

## 5. Activity Codes

Written to `stockrecord.activitycode` and/or `unitload_record.activitycode`. From `WmsConstants`:

| Code | When | Written by |
|---|---|---|
| `CODE_TRANSFER` | Move unitload (to location or carrier) | `MobileMoveUnitloadService.scanDestination` |
| `CODE_MANUAL_SPLIT` | Move stock split or full move | `MobileMoveStockService.selectDestination` |
| `CODE_CREATE_INBOUND_PALLET` | Move unitload to a location matching inbound pattern creates a new pallet | `MobileMoveUnitloadService.scanDestination` (line 321) |
| `CODE_SEND_TO_NIRVANA` | Source becomes empty, deleted from inventory | `unitloadBusinessService.sendToNirvana` / `stockunitBusinessService.sendStockUnitToNirvana` |

Never invent a new code at a call site — add a constant to `WmsConstants` first. See also [wms2-sysprop-catalog.md §11](../data-dictionary/wms2-sysprop-catalog.md) for the canonical code set (lines 870-877 in `WmsConstants`).

---

## 6. Guards (short list — the hot ones)

### Move Unitload

| Guard | Exception | Line |
|---|---|---|
| UL is Nirvana UL | `"Can not move"` | 132 |
| UL on NIRVANA location | `"Can not move from nirvana"` | 139 |
| UL on SHIPPED location | `"Can not move from shipped"` | 144 |
| UL / stockunit ON_HOLD lock | `"Unit load/Stock unit is locked on hold!"` | 148–155 |
| UL has fixed assignment | `"Cannot move fixed assigned"` | 161 |
| Has reserved stock | `"Reserved stock! can not move"` | 200 |
| Destination = Nirvana | `"Can not move to nirvana"` | 246 |
| Destination = Shipped | `"Can not move to shipped"` | 251 |
| Target pallet not empty (empty-pallet destination) | `"Pallet not empty!"` | 271 |
| Non-flowbin stock split disallowed | `"Moving stock to location ... not allowed!"` | 262 |
| Flowbin with multiple stocks and no assignment | `"Multiple stock not allowed on flow bin"` | 290 |
| Stock already assigned elsewhere | `"SKU already assigned to flow bin ..."` | 297 |
| Damaged-stock permission | checks `FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | 232–238 |

### Move Stock

| Guard | Exception | Line |
|---|---|---|
| Source UL on NIRVANA/SHIPPED | `"Can not move stock from nirvana/shipped"` | 147, 153 |
| Stock unit ON_HOLD | `"Stock unit is locked on hold!"` | 228 |
| `transfer > available` | `"Entered amount more than available"` | 78 |
| Destination not flowbin | `"Destination is not a flowbin!"` | 279 |
| Flowbin itemdata mismatch | `"Flowbin has different SKU"` | 273 |
| Destination label fails regex | `"noValidString"` | 288 |

---

## 7. OMS Callback

Both flows fire `MessageService.sendStockChangeMessage(List<StockChangeDto>)` when inventory amount changes (any split; full unit-load moves that don't alter stock *amount* don't fire). **SBDEV-2214 (2026-05-10):** the call now delegates to `StockChangeNotificationService.sendAfterCommit(...)` → `OmsNotificationService.sendAfterCommit(urlPath, payload, STOCK_UPDATE)`, which registers a `TransactionSynchronization.afterCommit` listener. The HTTP POST fires post-commit only — rollback silently drops it.

- URL: sysprop `SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY` (line 113 in `MessageService`)
- Process type: `MessageProcessType.STOCK_UPDATE`
- Audit: `message` table row with SENT/FAILED status

See [wms2-bol-truck-loading-workflow.md §7](./wms2-bol-truck-loading-workflow.md) for the broader OMS-callback pattern.

---

## 8. Transaction Boundaries

- `MobileMoveUnitloadService.scanDestination` — single `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`. All entity mutations + audit + BOL cleanup atomic.
- `MobileMoveStockService.selectDestination` — same annotation. Split writes (source decrement + destination create + records) commit together.
- `MobileMoveStockService.selectStockUnit` is `readOnly=true` (line 191).
- `transferStockToUnitLoad` takes a pessimistic write lock on the source stockunit row — this is the primary concurrency guard in the split path.

See [wms2-transaction-osiv-boundary-map.md §8](../architecture/wms2-transaction-osiv-boundary-map.md) for the pessimistic-lock site inventory.

---

## 9. Sysprop Gates

| Sysprop | Purpose |
|---|---|
| `STRING_PATTERN_INBOUND_PALLET` (`CART-\d{4}\|IN-\d{6}`) | Move Unitload: destination matching this pattern creates a new inbound pallet at PUTAWAY_LANE |
| `STRING_PATTERN_OUTBOUND_PALLET` (`OUT-\d{6}`) | `handleTruckOffLoading` uses this to decide whether the moved UL is an outbound pallet (triggers BOL cleanup) |
| `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` (`OUT-%1$06d`) | Secondary match for outbound pallet labels |
| `STRING_PATTERN_SEPARATE_STOCK` (`SU-\d{6}`) | Move Stock: destination label matching this pattern creates a new unit load at CLEARING location |
| `WEBSERVICE_STOCK_UPDATE` | Target URL for stock-change notification to OMS |

---

## 10. Known Landmines

1. **Two distinct flows, same backend audit.** Move Unitload writes both `unitload_record` and (via children) `stockrecord`. Move Stock writes only `stockrecord` for the split. If a user report says "audit row is missing for a UL move," check the unit_load_record side first.
2. **Pessimistic lock in split path.** High-contention flowbins under concurrent split attempts will serialize and may time out. No timeout hint set on `StockunitRepository.findByIdForUpdate` — it waits on the session default. Document this before scaling up replicas.
3. **BOL cleanup only fires when destination matches outbound-pallet pattern.** A UL that was erroneously placed on a BOL gate without matching the regex will orphan its `BillofladingPosition` when moved. Symptom: BOL close fails with "unit load not at gate."
4. **`handleTruckOffLoading` is destructive** (deletes `BillofladingPosition` rows). Recoverable only by replaying the truck-loading flow. Don't run this on production during a tenant migration without pausing truck-loading.
5. **Move Unitload guards do not check stock-unit reservations of children.** If a child stock unit has been reserved by an open pick order, the move succeeds but the pick order now points at the wrong location. The fixed-location / reserved-stock guards only check the unit load itself, not its children. Bug waiting to happen.
6. **Move Stock to a flowbin without an assignment** creates an implicit fixed-assignment on first scan (line 290 check). This is intentional — it's how flowbins get populated the first time. But an operator who scans the wrong flowbin locks that SKU into that location until an admin removes the assignment.
7. **`removeUnitLoadIfEmpty=true` default** sends source UL to Nirvana when `amount` hits zero. Desirable for manual splits; unexpected if a caller is iterating splits and expects to reuse the source UL. Audit `transferStockToUnitLoad` call sites before changing this flag.
8. **No OMS callback for `CODE_TRANSFER` when stock amount doesn't change.** Pure unit-load relocation (moving a pallet to a different location) is invisible to OMS. If OMS needs location visibility, it has to poll or subscribe to the monitor-view endpoints.
9. **Damaged-stock permission gate** (`FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`) is checked in both flows (unitload lines 232–238, stock lines 240–247). A Keycloak realm that doesn't grant this role blocks all moves involving damaged stock. Check the role matrix before provisioning a new operator composite role.
10. **`CODE_MANUAL_SPLIT` reused for full-move scenarios** in `transferStockToUnitLoad` when the transfer amount equals the source amount. Reports that count "splits" by this code over-count by the number of full moves. Downstream analytics need to check source vs destination unit load IDs to distinguish.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| "Moved a pallet but its BOL position still exists" | §3 + §10 item 3 — destination label didn't match outbound regex |
| "Cannot move pallet — fixed assignment error" | §6 Move Unitload guard + remove the FLA via admin UI first |
| "Stock split silently consumed entire source" | §4 — if `amount == source.amount`, the split becomes a full move |
| "OMS never saw a UL relocation" | §10 item 8 — pure location moves don't fire |
| "Flowbin now has a SKU I didn't intend" | §10 item 6 — implicit fixed-assignment creation |
| "Move is slow under burst operator activity" | §10 item 2 — pessimistic lock contention |
| "Operator without damaged-stock role can't move anything" | §6 / §10 item 9 — check composite role |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `MobileMoveUnitloadService` (scanUnitLoad, scanDestination, handleTruckOffLoading), `MobileMoveStockService` (selectSource, selectStockUnit, selectDestination), `UnitloadBusinessService.transferUnitLoadToLocation / transferUnitLoadToCarrier`, `StockunitBusinessService.transferStockToUnitLoad`, REST endpoints, activity code constants, pessimistic lock site | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |

**Re-verify every 90 days.** Next due: **2026-07-18**.
