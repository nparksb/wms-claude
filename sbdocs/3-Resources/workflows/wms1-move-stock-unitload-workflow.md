---
title: "WMS v1 — Move Stock + Move Unitload Workflow"
type: workflow
status: active
system: wms1
version: v1
scope: move-stock-unitload
owner: Nam Park
created: 2026-04-27
updated: 2026-04-27
last_verified: 2026-04-27
verified_by: code read of v1/wms-api MobileMoveUnitloadService + MobileMoveStockService + StockunitBusinessService + UnitloadBusinessService + WmsConstants
related:
  - ./wms2-move-stock-unitload-workflow.md
tags:
  - workflow
  - move-stock
  - move-unitload
  - wms1
---

# WMS v1 — Move Stock + Move Unitload Workflow

**Scope:** Two mobile-only flows that relocate inventory on the warehouse floor — full unit load moves and partial stock splits · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-27

---

## 1. Overview

Two mobile pages, one concept with an important split:

- **Move Unitload** (`/v3/moveUnitload`, role `MOBILE_UI_VIEW_TRANSFER`) — moves a whole unit load (pallet, tote, cart, or box) to a new location or onto a carrier pallet. The `Unitload` entity row changes its `storagelocationId` or `carrierunitloadId`; no `Stockunit` rows are created or destroyed in the normal path.
- **Move Stock** (`/v3/moveStock`, role `MOBILE_UI_VIEW_STOCK_TRANSFER`) — splits or fully transfers a stock unit's contents to a destination unit load or flowbin. A new `Stockunit` row may be created at the destination; the source stock unit's `amount` decrements. Activity code: `CODE_MANUAL_SPLIT`.

**Key v1 vs v2 differences:**

| Concern | v1 | v2 |
|---|---|---|
| Transaction annotation | `@Transactional` (default Spring transaction manager — single-tenant) | `@Transactional("tenantTransactionManager")` |
| Optimistic lock retry | Not present | Yes — `optimisticLockRetry.executeWithRetry` on carrier-clear step |
| Pessimistic lock | Not present (`findByIdForUpdate` exists in `StockunitBusinessService` but is NOT called from the move-stock path) | `StockunitRepository.findByIdForUpdate()` called at transfer entry |
| `handleTruckOffLoading` | Present (same logic) | Present |
| `transferStock()` internal helper | Present in `MobileMoveUnitloadService` (marked `TODO: remove`) — handles flowbin scans from the Move Unitload flow | Split into separate `MobileMoveStockService` in v2 |
| Pallet destination in Move Stock | Creates a new box UL, transfers stock, then nests box onto pallet | Not present in v2 |

---

## 2. Actors

| Actor | Role constant | Notes |
|---|---|---|
| Mobile operator | `MOBILE_UI_VIEW_TRANSFER` (Move Unitload) | Scans UL label then destination |
| Mobile operator | `MOBILE_UI_VIEW_STOCK_TRANSFER` (Move Stock) | Scans UL label or stock unit ID, selects stock unit + amount, scans destination |
| Admin (permission gate) | `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | Required to move stock to/from the Damaged location |

---

## 3. Move Unitload — Flow

```
Operator scans UL label on mobile
  │  GET /v3/moveUnitload/selectSource/{input}    [MoveUnitloadController:41]
  ▼
MobileMoveUnitloadService.scanUnitLoad()           [line 88]
  ├── Validate label not empty, not "NIRVANA"
  ├── Look up Unitload by labelid
  ├── Validate:
  │     · not the Nirvana UL
  │     · not on NIRVANA location
  │     · not on SHIPPED location
  │     · UL entityLock != ON_HOLD (104)
  │     · no child Stockunit has entityLock == ON_HOLD (104)
  │     · no FixLocationAssignment on the UL itself
  │     · checkReservedStock() — cancels any open replenish orders, throws if reserved stock remains
  └── Return TransferInfoDto (UL + current location + carrier label + FLA hint)

Operator scans destination label (location name OR pallet label OR inbound-pallet pattern)
  │  POST /v3/moveUnitload/selectDestination      [MoveUnitloadController:66]  [TransferInfoDto body]
  ▼
MobileMoveUnitloadService.scanDestination()        [line 183]  @Transactional
  │
  ├── Re-validate source UL and stock unit ON_HOLD locks
  ├── Re-run checkReservedStock()
  │
  ├── Destination = DAMAGED location?
  │     Guard: requires WEB_UI_ACTION_ADJUST_LOCK_DAMAGED permission
  │     → setStockDamaged(sourceUL) — sets all stockunit.entityLock = QUALITY_FAULT (103)
  │
  ├── Source on DAMAGED location + destination != DAMAGED?
  │     Guard: requires WEB_UI_ACTION_ADJUST_LOCK_DAMAGED permission
  │     → removeStockDamaged(sourceUL) — resets all stockunit.entityLock = NOT_LOCKED (0)
  │
  ├── Destination = location (non-flowbin)?
  │     Guards: not Nirvana / not Shipped / not EmptyPallets when UL has stock or children
  │     → unitloadBusinessService.transferUnitLoadToLocation(source, dest, false, CODE_TRANSFER, null, null)
  │     → handleTruckOffLoading(sourceUL.labelid)
  │         · matches STRING_PATTERN_OUTBOUND_PALLET or PRINTING_PATTERN_OUTBOUND_PALLET_LABEL?
  │           delete BolPosition row + all child carrier rows
  │
  ├── Destination = location (flowbin)?
  │     → Lookup or create FixLocationAssignment for that flowbin + source item
  │     Guards: no FLA exists + multiple stocks on source → "Multiple stock not allowed on flow bin"
  │             source item already has FLA pointing elsewhere → "SKU already assigned to flow bin X"
  │     → transferStock(sourceUL, assignedUL)   [internal helper, line 345]
  │         · stockunitBusinessService.transferStockToUnitLoad(sourceStockunit, assignedUL,
  │               amount, CODE_TRANSFER, null, null, false, false)
  │         · relocates source UL to EmptyPallets/EmptyTotes or sends to Nirvana by UL type
  │
  ├── Destination = existing UL label (pallet/tote) without FLA?
  │     · dto.isMoveStock() == true → transferStock(sourceUL, destUL)
  │     · dto.isMoveStock() == false → unitloadBusinessService.transferUnitLoadToCarrier(
  │           sourceUL, destUL, CODE_TRANSFER, null, null)
  │
  ├── Destination = existing UL label with FLA → treat as flowbin
  │     → transferStock(sourceUL, flaAssignedUL)
  │
  └── Destination matches inbound-pallet pattern (STRING_PATTERN_INBOUND_PALLET)?
        → create new UL at PutAwayLane with type PALLET, code CODE_CREATE_INBOUND_PALLET
        → dto.isMoveStock() == false → transferUnitLoadToCarrier(sourceUL, newUL, CODE_TRANSFER, null, null)
```

### Core API: `UnitloadBusinessService`

| Method | Line | What changes |
|---|---|---|
| `transferUnitLoadToLocation(Unitload, Location, ignoreLock, code, ref, comment)` | 77 | `unitload.storagelocationId = destination.id`; recursively transfers children; clears `carrierunitloadId` if nested; writes `unitload_record` |
| `transferUnitLoadToCarrier(Unitload source, Unitload dest, code, ref, comment)` | 149 | `source.carrierunitloadId = dest.id`; validates no circular parent chain |
| `sendToNirvana(Unitload, code, ref, comment)` | ~256 | Calls `transferUnitLoadToLocation` to Nirvana location; used when source UL empties |
| `sendToClearing(Unitload, code, ref, comment)` | ~268 | Calls `transferUnitLoadToLocation` to Clearing location |

**No optimistic-lock retry** in v1 — unlike v2, the carrier-clear step is not wrapped in a retry block.

---

## 4. Move Stock — Flow

```
Operator scans stock unit ID (numeric) or UL label
  │  GET /v3/moveStock/selectSource/{input}     [MoveStockController:44]
  ▼
MobileMoveStockService.selectSource()            [line 75]
  ├── If input is parseable as Long → treat as Stockunit ID
  │     Load all stockunits on that UL, sort by itemNr
  │     Return StockTransferDto (stockUnitList + stockUnitInfoDtos)
  └── Else → treat as UL labelid
        Guard: not Nirvana UL / not on Nirvana location / not on Shipped location
        Return StockTransferDto with all stockunits on UL sorted by itemNr

Operator selects stock unit + enters transfer amount
  │  GET /v3/moveStock/selectStockUnit/{id}/{input}    [MoveStockController:67]
  ▼
MobileMoveStockService.selectStockUnit()         [line 182]
  ├── Load candidate destination locations for the stockunit's itemdata
  │     (flowbins first, overstocks appended, sorted by DefaultStrategy)
  └── Return updated dto with locationList + stockUnitInfoDtos

Operator scans destination (location name OR UL label OR new SU-xxxxxx label)
  │  POST /v3/moveStock/scanDestination         [MoveStockController:98]  [StockTransferDto body]
  ▼
MobileMoveStockService.selectDestination()       [line 214]
  │
  ├── Guard: stockUnit.entityLock == ON_HOLD → throw
  │
  ├── Destination = DAMAGED location?
  │     Guard: WEB_UI_ACTION_ADJUST_LOCK_DAMAGED permission required
  │     → mobileMoveUnitloadService.setStockDamaged(stockUnitUnitLoad)
  │
  ├── Source UL on DAMAGED location + destination != DAMAGED?
  │     Guard: WEB_UI_ACTION_ADJUST_LOCK_DAMAGED permission required
  │     → mobileMoveUnitloadService.removeStockDamaged(stockUnitUnitLoad)
  │
  ├── Destination = location?
  │     · Is flowbin type?
  │         Look up or create FixLocationAssignment (creates implicit FLA on first scan)
  │         If FLA exists: validate flaItemData == sourceItemData ("Flowbin has different SKU")
  │         → stockunitBusinessService.transferStockToUnitLoad(
  │               stockUnit, flaAssignedUL, amount, CODE_MANUAL_SPLIT, null, null,
  │               false, true)
  │         return
  │     · Not flowbin → throw "Destination is not a flowbin!"
  │
  ├── Destination = existing UL label?
  │     · If dest UL type = PALLET:
  │         Create new box/default UL at pallet's location (CODE_MANUAL_SPLIT)
  │         → stockunitBusinessService.transferStockToUnitLoad(stockUnit, newBoxUL, amount,
  │               CODE_MANUAL_SPLIT, null, null, false, true)
  │         → unitloadBusinessService.transferUnitLoadToCarrier(newBoxUL, pallet,
  │               CODE_MANUAL_SPLIT, null, null)
  │     · Otherwise:
  │         → stockunitBusinessService.transferStockToUnitLoad(stockUnit, destUL, amount,
  │               CODE_MANUAL_SPLIT, null, null, false, true)
  │
  └── Destination = new label matching STRING_PATTERN_SEPARATE_STOCK (SU-\d{6})?
        Create new UL at Clearing location using item's default UL type (or BOX fallback)
        → stockunitBusinessService.transferStockToUnitLoad(stockUnit, newUL, amount,
              CODE_MANUAL_SPLIT, null, null, false, true)
```

### Core API: `StockunitBusinessService.transferStockToUnitLoad`

At line 123–264. Two code paths based on whether a destination `Stockunit` already exists for the same itemdata:

| Scenario | Condition | Effect | Stockrecord |
|---|---|---|---|
| Full move (reattach) | `destinationStockUnit == null` AND `source.amount == amount` AND no FLA on source location | `sourceStockunit.unitloadId ← destinationUnitload.id`; source row preserved | `recordTransferStockUnit` |
| Split / merge | `destinationStockUnit != null` OR partial amount OR FLA on source | Create new dest stockunit (if needed); `dest.amount += amount`; `source.amount -= amount` | `recordRemoval(source)` + `recordCreation(dest)` |
| Source reaches zero (split path) | `source.amount == 0` after decrement | `sendStockUnitToNirvana(source)` | Included in split record |
| Source UL empties | `removeUnitLoadIfEmpty=true` AND no stock/children remain | `unitloadBusinessService.sendToNirvana(sourceUL)` | Via `sendToNirvana` |

**Note on pessimistic lock:** `StockunitRepository.findByIdForUpdate()` exists at `StockunitBusinessService:342` but is NOT called from the move-stock path in v1. The v1 split path reads the source stockunit at the service entry point without a DB-level lock. This is a concurrency gap compared to v2.

---

## 5. Activity Codes

Written to `stockrecord.activitycode` and `unitload_record.activitycode`. From `WmsConstants` (line ~837):

| Constant | Value | When | Written by |
|---|---|---|---|
| `CODE_TRANSFER` | `"TRANSFER"` | Move unitload to location or carrier; transferStock internal helper | `MobileMoveUnitloadService.scanDestination` |
| `CODE_MANUAL_SPLIT` | `"MANUAL_SPLIT"` | Move stock split or full move | `MobileMoveStockService.selectDestination` |
| `CODE_CREATE_INBOUND_PALLET` | `"CREATE_INBOUND_PALLET"` | Move unitload destination matches inbound-pallet pattern | `MobileMoveUnitloadService.scanDestination` (line 298) |
| `CODE_SEND_TO_NIRVANA` | `"SEND_TO_NIRWANA"` | Source UL becomes empty after transfer | `StockunitBusinessService.transferStockToUnitLoad` (line 235, 259) |

Note the typo in the constant value: `"SEND_TO_NIRWANA"` (not `"NIRVANA"`) — this matches v2 and is intentional at the constant definition.

---

## 6. Lock State During Move

Lock states are integer constants in `WmsConstants.BusinessObjectLockState`:

| Constant | Value | Meaning |
|---|---|---|
| `NOT_LOCKED` | 0 | Normal, moveable |
| `GOING_TO_DELETE` | 2 | Marked for deletion |
| `PICKED_FOR_GOODSOUT` | 100 | Reserved for outbound pick |
| `QUALITY_FAULT` | 103 | Damaged stock — needs `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` to move |
| `ON_HOLD` | 104 | Blocked — move rejected at source scan |

**During Move Unitload:**
- Source scan (`scanUnitLoad`) checks UL and all direct child stockunits for `ON_HOLD` (104). Does NOT recurse into child ULs' stockunits.
- `setStockDamaged()` sets all stockunits on the UL (recursing into children) to `QUALITY_FAULT` (103) and fires OMS stock-change callback.
- `removeStockDamaged()` resets `QUALITY_FAULT` → `NOT_LOCKED` (0) and fires OMS callback.
- `transferStockToUnitLoad` (called from `transferStock` internal helper) checks source stockunit, source UL, source location, dest stockunit, dest UL, dest location all != `NOT_LOCKED` when `ignoreLock=false`. The `transferStock` helper passes `ignoreLock=false`.

**During Move Stock:**
- `selectDestination` checks only the selected stockunit for `ON_HOLD` (104) — does not check the UL.
- `transferStockToUnitLoad` called with `ignoreLock=true` from `MobileMoveStockService` — lock checks inside the business service are bypassed; the service-layer ON_HOLD check above is the sole guard.

---

## 7. Location Constraint Checks

### Move Unitload (non-flowbin destination)

| Check | Exception message | Code location |
|---|---|---|
| Destination = Nirvana | `"Can not move unit load to nirvana location: ..."` | `scanDestination:220` |
| Destination = Shipped | `"Can not move unit load to shipped location:..."` | `scanDestination:225` |
| Destination = EmptyPallets + source not empty | `"Pallet not empty!"` | `scanDestination:246` |
| Destination = flowbin, no stock on source | `"No stock to assign to flow bin"` | `scanDestination:263` |
| Destination = flowbin, multiple stocks on source | `"Multiple stock not allowed on flow bin"` | `scanDestination:266` |
| Destination = flowbin, source item already has FLA elsewhere | `"SKU already assigned to flow bin X"` | `scanDestination:274` |
| Destination not found + not inbound-pallet pattern | `"No destination found for ..."` | `scanDestination:301` |
| `dto.isMoveStock()=true` + non-flowbin location | `"Moving stock to location X is not allowed! Move Unit Load instead!"` | `scanDestination:237` |

### Move Stock

| Check | Exception message | Code location |
|---|---|---|
| Source UL = Nirvana UL | `"Can not move stock from ..."` | `selectSource:124` |
| Source on Nirvana location | `"Can not move unit load from ..."` | `selectSource:133` |
| Source on Shipped location | `"Can not move unit load from ..."` | `selectSource:140` |
| Stock unit ON_HOLD | `"Stock unit is locked on hold!"` | `selectDestination:220` |
| Destination location = non-flowbin | `"Destination is not a flowbin!"` | `selectDestination:268` |
| Flowbin has different SKU | `"Flowbin has different SKU X"` | `selectDestination:262` |
| Destination label fails STRING_PATTERN_SEPARATE_STOCK | `"noValidString"` | `selectDestination:277` |
| Destination = Nirvana UL | `"Can not move stock to ..."` | `selectDestination:294` |
| Amount > (source.amount - reservedAmount) | `"amount=X requested is more than available=Y"` | `transferStockToUnitLoad:128` |
| Mixed stock on dest UL type | `"Mixed stock not allowed on unitLoad=..."` | `transferStockToUnitLoad:151` |

---

## 8. State Transitions with Service Method References

### Move Unitload — to location

```
Unitload.storagelocationId:  sourceLocationId  →  destinationLocationId
Unitload.carrierunitloadId:  parentId (if nested)  →  null (cleared)
UnitloadRecord:              appended via recordForTransferUnitLoad (inside UnitloadBusinessService:77)
Stockrecord:                 appended for each child stockunit via recordTransferStockUnit
```

### Move Unitload — to carrier pallet

```
Unitload.carrierunitloadId:  null  →  destinationUnitload.id
Unitload.storagelocationId:  (unchanged — inherited from carrier)
UnitloadRecord:              appended via transferUnitLoadToCarrier (UnitloadBusinessService:149)
```

### Move Stock — full move (reattach path)

```
Stockunit.unitloadId:        sourceUnitload.id  →  destinationUnitload.id
Stockunit.amount:            unchanged
Stockrecord:                 recordTransferStockUnit (StockunitBusinessService:229)
Source UL (if empty):        sendToNirvana → Unitload.storagelocationId = Nirvana (StockunitBusinessService:235)
```

### Move Stock — split path

```
Stockunit(source).amount:    N  →  N - transfer
Stockunit(dest).amount:      M  →  M + transfer  (or new row created at 0 then incremented)
Stockrecord(source):         recordRemoval (StockunitBusinessService:249)
Stockrecord(dest):           recordCreation (StockunitBusinessService:250)
If source.amount == 0:       sendStockUnitToNirvana(source) (StockunitBusinessService:253)
If source UL empties:        sendToNirvana(sourceUL) (StockunitBusinessService:259)
```

---

## 9. OMS Callback

`setStockDamaged()` and `removeStockDamaged()` fire `messageService.sendStockChangeMessage(List<StockChangeDto>)` when damaged-lock state changes. The callback URL is sysprop `WEBSERVICE_STOCK_UPDATE` (`SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY`, line 871 in `WmsConstants`).

Pure unit-load relocations via `CODE_TRANSFER` (moving a pallet between locations without changing stock amount) do NOT fire OMS callbacks. Stock amount changes within `transferStockToUnitLoad` also do not directly fire the callback in v1 — the callback is only triggered from the damaged-lock helpers.

---

## 10. Transaction Boundaries

- `MobileMoveUnitloadService.scanDestination` — `@Transactional` (line 182). Default Spring transaction manager (single-tenant). All entity mutations, audit records, and BOL cleanup are atomic.
- `MobileMoveUnitloadService.scanUnitLoad` — no `@Transactional`; read-only lookup.
- `MobileMoveStockService.selectDestination` — no `@Transactional` annotation on the method itself; relies on `@Transactional` on the called business service methods (`StockunitBusinessService.transferStockToUnitLoad` at line 123, `UnitloadBusinessService` methods).
- `StockunitBusinessService.transferStockToUnitLoad` — `@Transactional` (line 123). Split writes (source decrement + destination create + stockrecords) commit together.
- `UnitloadBusinessService.transferUnitLoadToLocation` — `@Transactional` (line 76).
- `UnitloadBusinessService.transferUnitLoadToCarrier` — `@Transactional` (line 148).

**No outer transaction wrapping `MobileMoveStockService.selectDestination`** — if the pallet destination path calls both `transferStockToUnitLoad` and `transferUnitLoadToCarrier`, each runs in its own `@Transactional` method. A failure between them leaves the stock transferred but the new box UL not yet nested on the pallet.

---

## 11. Sysprop Gates

| Sysprop key constant | Default value | Purpose |
|---|---|---|
| `SYSTEM_PROPERTY_STRING_PATTERN_INBOUND_PALLET_KEY` | `CART-\d{4}\|IN-\d{6}` | Move Unitload: destination matching this creates a new inbound pallet at PutAwayLane |
| `SYSTEM_PROPERTY_STRING_PATTERN_OUTBOUND_PALLET_KEY` | `OUT-\d{6}` | `handleTruckOffLoading` — match triggers BOL position cleanup |
| `SYSTEM_PROPERTY_PRINTING_PATTERN_OUTBOUND_PALLET_LABEL_KEY` | `OUT-%1$06d` | Secondary match for outbound pallet labels in `handleTruckOffLoading` |
| `SYSTEM_PROPERTY_STRING_PATTERN_SEPARATE_STOCK_KEY` | `SU-\d{6}` | Move Stock: destination label matching this creates a new UL at Clearing |
| `SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY` | `WEBSERVICE_STOCK_UPDATE` | OMS callback URL for damaged-lock state changes |

---

## 12. Known Landmines

1. ~~**No pessimistic lock on split path.**~~ **FIXED 2026-08-20 — SBDEV-3003** (wms-api `0a16aba`).
   This landmine predicted the defect correctly ("inventory count drifts positive over time") and it
   was then reported by WineCo as ST#1116 and reproduced on v1 DEV: one Move Stock of 12 left 3012 on
   hand against 3000 ever received.

   **The diagnosis in the original note was wrong in a way worth keeping.** It was not a missing
   pessimistic lock, and it was not two writes of the same value. `transferStockToUnitLoad` re-fetched
   the source row and then assigned it an **absolute** amount computed from the *caller's stale
   instance* — value and version drawn from different snapshots. The losing transaction issued **no
   UPDATE at all**: Hibernate's dirty check found the freshly-loaded 2988 equal to the computed
   `3000 − 12`, so no SQL was emitted, `@Version` was never consulted, and the row kept **no trace**
   (`stockunit 21376110`: version=1, modified at the *first* transaction's timestamp).

   The fix adds **no lock**: it detaches the caller's instance, re-fetches in-transaction, and uses
   that one instance for both the availability guard and the arithmetic. A pessimistic lock was
   considered and **rejected** — it would have applied to all 23 callers of the method, two of them
   batch loops (`BillofladingService:992`, `CustomerorderBatchService:666-684`), in a codebase with
   zero lock timeouts in `src/main`. `findByIdForUpdate` is also **JPQL**, so an L1 hit returns the
   cached instance unrefreshed; without also replicating the `detach` at `changeReservedAmount:372`
   the lock would have been decorative.

   **Detection** (a `stockunit`-vs-ledger drift query cannot find victims — there is no trace on the
   row): group `stockrecord` `STOCK_REMOVED` rows by `(itemdata, fromunitload, amount, amountstock)`
   and flag any group with `count(*) > 1` inside ~10 seconds. Validated both ways — finds the known
   case on `wh01_om1`, returns zero on `wh01_om1_v2`.

   Full analysis: [[../../1-Projects/wms1/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation]].
   v2 is unaffected — it locks and refreshes, and computes from the locked instance.

2. **No outer transaction in `MobileMoveStockService.selectDestination`.** The pallet-destination path in `selectDestination` calls `transferStockToUnitLoad` then `transferUnitLoadToCarrier` as two separate `@Transactional` methods. A crash between them leaves a dangling box UL at the pallet's location with stock but no carrier assignment.

3. **`transferStock()` internal helper is marked `TODO: remove`** (`MobileMoveUnitloadService:347`). It conflates two concerns: transferring stock for the flowbin path and relocating the now-empty source UL. Do not add new callers. This logic should be in `MobileMoveStockService`.

4. **`handleTruckOffLoading` is destructive.** Deletes `BillofladingPosition` rows. Recoverable only by replaying the truck-loading flow. Fires silently on every non-flowbin Move Unitload call — not just on out-bound pallets. Pattern match is the only guard.

5. **BOL cleanup only fires when destination label matches outbound pattern.** A UL erroneously placed on a BOL gate without a matching label will orphan its `BillofladingPosition`. Symptom: BOL close fails with "unit load not at gate."

6. **`scanUnitLoad` does not recurse into child ULs** when checking ON_HOLD stock unit locks (lines 128–133). If a pallet contains nested totes and a tote's stockunit is ON_HOLD, `scanUnitLoad` will pass validation. The lock will then be caught in `scanDestination`'s re-check only if the same direct stock unit list is inspected again — but nested UL children are not re-checked there either.

7. **Implicit FLA creation on first flowbin scan** (`scanDestination:277`, `selectDestination:254`). An operator who scans the wrong flowbin implicitly locks that SKU into that location. Requires admin intervention to remove the FixLocationAssignment.

8. **`removeUnitLoadIfEmpty=true` in Move Stock path.** `selectDestination` always passes `removeUnitLoadIfEmpty=true` (implicitly `false` is passed via the `transferStock` helper in Move Unitload, line 358). A full move of all stock off a box/tote sends that UL to Nirvana. This is intentional but can surprise integrators watching UL lifecycle events.

9. **`CODE_MANUAL_SPLIT` reused for full-move scenarios.** When `amount == source.amount` and there is no existing dest stockunit, `transferStockToUnitLoad` reattaches the source row (full move), yet `MobileMoveStockService` always passes `CODE_MANUAL_SPLIT`. Reports counting splits by this code will over-count.

10. **Damaged location checks in both flows share logic through `mobileMoveUnitloadService`.** `MobileMoveStockService` calls `mobileMoveUnitloadService.setStockDamaged()` / `removeStockDamaged()` directly (lines 234, 239). This couples the two services — avoid changing the damaged-lock helpers without auditing both callers.

---

## 13. How to Debug

| Symptom | Start here |
|---|---|
| "Moved a pallet but its BOL position still exists" | §3 + §12 item 5 — destination label didn't match outbound-pallet regex |
| "Cannot move pallet — fixed assignment error" | §7 Move Unitload guard — remove FLA via admin UI first |
| "Stock split silently consumed entire source" | §4 — if `amount == source.amount` and no dest stockunit exists, full reattach happens |
| "Inventory drifting positive on busy flowbins" | §12 item 1 — concurrent splits without pessimistic lock |
| "Box UL at pallet location with stock but no carrier" | §12 item 2 — crash between the two `@Transactional` calls in pallet-destination path |
| "Operator without damaged-stock role can't move anything" | §7 / §12 item 10 — check Keycloak composite role for `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` |
| "Move Stock doesn't show flowbin as candidate destination" | §4 `selectStockUnit` — location must be FLOWBIN type AND have an FLA or no FLA (first-time creation) |
| "OMS never saw a UL relocation" | §9 — pure location moves don't fire OMS callback; only damaged-lock changes do |

---

## 14. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-27 | `MobileMoveUnitloadService` (scanUnitLoad, scanDestination, transferStock helper, handleTruckOffLoading, setStockDamaged, removeStockDamaged), `MobileMoveStockService` (selectSource, selectStockUnit, selectDestination), `UnitloadBusinessService.transferUnitLoadToLocation / transferUnitLoadToCarrier`, `StockunitBusinessService.transferStockToUnitLoad`, `MoveUnitloadController`, `MoveStockController`, `WmsConstants` (activity codes, lock states, sysprop keys, FunctionEnum) | All file:line refs confirmed against `v1/wms-api/src/main/java` | Code read (grep + targeted Read) |

**Re-verify every 90 days.** Next due: **2026-07-26**.
