---
title: "WMS v2 — Move Stock + Move Unitload Workflow"
type: workflow
status: active
version: v2
scope: move-stock-unitload
owner: Nam Park
created: 2026-04-19
updated: 2026-08-28
last_verified: 2026-08-29
verified_by: code read of v2/wms2-api MobileMoveUnitloadService + MobileMoveStockService + UnitloadBusinessService + StockunitBusinessService; §4 re-verified 2026-08-28 against SBDEV-2996 (moveStock/scanDestination retired)
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
MobileMoveStockService.selectSource()            [line 70]
  └── Return StockTransferDto with all stockunits on that UL (sorted by item number)

Operator selects stockunit + enters transfer amount
  │  GET /v3/moveStock/selectStockUnit/{id}/{input}    @Transactional(readOnly=true)
  ▼
MobileMoveStockService.selectStockUnit()         [line 162]
  ├── Guard: amount > 0 && amount <= stockunit.amount
  └── Return candidate destinations (flowbins + overstocks, sorted by DefaultStrategy; direction controlled by PICK_PATH_DIRECTION sysprop via PickPathConfig → DefaultStrategy)

Operator scans destination (location OR UL label)
  │  POST /v3/stockUnit/transferStock            [shared with the desktop]
  ▼
StockunitService.transferStock()
  │  (see §4.1 — the mobile screen has used this path since SBDEV-2994)
  └── ... → StockunitBusinessService.transferStockToUnitLoad (below)
```

### 4.1 ⚠️ `POST /v3/moveStock/scanDestination` was RETIRED by SBDEV-2996 (2026-08-28)

Until 2026-08-28 this section documented a second destination-scan path —
`POST /v3/moveStock/scanDestination` → `MobileMoveStockService.selectDestination` — as if it were the
live one. **It was not reachable.** `wms2-mobile-ui store/moveStock.js` held a `scanDestination`
action that nothing dispatched; `components/moveStock/scanDestination.vue` dispatches
`moveStock/checkContainer` then `moveStock/transferStock`, and `wms2-web-ui` never referenced the
route. The endpoint, the service method and the dead store action were deleted.

**The semantics that survive** (this is the answer AC2 of SBDEV-2996 asked to be written down): an
**unknown but well-formed destination label is REJECTED**, with a message naming the container —
the behaviour SBDEV-2994 shipped on `StockunitService.transferStock`. The retired path did the
opposite: it validated the label against `STRING_PATTERN_SEPARATE_STOCK` (`SU-\d{6}`) and
**auto-created** the container at `Clearing`. Two conventions for one operator gesture is what the
retirement removed. Measured at retirement time, zero unitloads matched `^SU-[0-9]{6}$` on either
WineCo dev or Hydra UAT, so the auto-create branch had produced nothing.

What the retired path guarded, and whether the live path guards it too. ⚠️ **This table has now been
wrong twice.** The first draft claimed four gaps; a verifier lane knocked out two; a code-review lane
then knocked out a third. Corrected 2026-08-28 against the code — **only one of the four is actually
absent, and it is a deliberate divergence, not a gap:**

| Guard | On the live path (`StockunitService.transferStock`)? |
|---|---|
| Destination is Nirvana | ✅ **yes** — `:177` calls `destinationEligibilityService.assertCanReceiveStock(unitLoad)` on the existing-container branch, and that sentinel refusal sits **outside** the `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` gate (`DestinationEligibilityService:115`). Shipped by **SBDEV-2994 Fix B**. |
| Source stock unit is locked | ✅ **yes, and broader than the retired check** — `StockunitBusinessService.transferStockToUnitLoad:293-297` throws for **any** `entityLock != NOT_LOCKED` when `ignoreLock == false`, which is what `transferStock` passes at four of its six call sites. The retired path tested `ON_HOLD` alone. The two `ignoreLock = true` sites are the damaged-stock branches, deliberately. |
| Flowbin `FixLocationAssignment` SKU match | ✅ **yes** — `:230-232`, `"Flow bin has different SKU "`. The retired path spelled it `"Flowbin has different SKU "` (no space), which is what made it look absent. |
| Destination must be a FLOWBIN when it is a Location | ❌ **absent — deliberately.** The retired path threw `"Destination is not a flowbin!"`; the live path takes an `else` branch at `:232` and relocates or creates a unit load at the location instead. Restoring the refusal would be a **regression** in capability, not a fix. |

⚠️ **Do not read this table as a to-do list.** An earlier draft of it named SBDEV-2995 as tracking the
Nirvana gap. That is wrong twice over: the guard is present, and **SBDEV-2995 was rewritten on
2026-08-19** and no longer concerns `transferStock` destinations at all — it now covers outbound
palletising type checks and the `MobileMoveUnitloadService` sentinel. The Nirvana-destination concern
was always SBDEV-2994's, and it shipped in PR #167.

The retirement also deleted **two `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` permission checks** that lived
in `selectDestination`. No authorization was lost: the live path gates the same function at
`StockunitService:265`, and the two deleted checks were unreachable along with the method.

---

### Core API: `StockunitBusinessService.transferStockToUnitLoad`

At line 173–322. Two code paths:

| Scenario | Effect | Stockrecord |
|---|---|---|
| Full move (entire source amount, no split) | Reattach `sourceStockunit.unitloadId ← destinationUnitload.id`; source row preserved | `recordTransferStockUnit` |
| Split move (partial) | Source `amount -= transfer`; create new stockunit at destination with `amount = transfer` | `recordRemoval(source)` + `recordCreation(destination)` |

**Pessimistic `PESSIMISTIC_WRITE` lock** on source stockunit via `StockunitRepository.findByIdForUpdate()` at line 188 — prevents TOCTOU under concurrent splits.

---

## 4.2 Scanned-identifier case resolution (SBDEV-3134, PR #234 + mobile-ui #50, merged 2026-08-29)

Before this, both move flows resolved identifiers through `LocationRepository.findByName` and
`UnitloadRepository.findByLabelid` — **exact and case-sensitive** — while Putaway and Replenish
already tolerated the case an operator types (`findByLabelidIgnoreCase`). Nothing had decided the
rule; each screen picked one. `ScannedCodeResolver` is now the single place it is decided.

### The rule

| Step | Behaviour |
|---|---|
| **Exact match first, always** | The case-insensitive query runs *only after* an exact miss. No scan that works today changes behaviour, query plan or cost. |
| **Case-insensitive fallback** | Resolves to the **stored** spelling; the caller then runs its existing, unchanged lookup. |
| **Two or more stored spellings** | **Refused** — never guessed. Raises `scanCodeAmbiguous*` (see the exception taxonomy §5). |
| **No match** | Input returned unchanged, so the caller's own "not found" error still fires. |
| **Case only** | Nothing is trimmed or otherwise rewritten. Pinned by `ScannedCodeResolverUnitTest.surroundingWhitespaceIsNotTrimmed` (`:155`), so the resolver cannot quietly grow a trim. |

⚠ **Why ambiguity is refused.** Verified 2026-08-29 on **both** UAT and PRD hydra: `location.name`
carries `uk_sahixf1v7f7xns19cbg12d946` and `unitload.labelid` carries `uk_s2ujivixnde5dqb2stih8m2vh`
(plus a redundant `uq_unitload_labelid`) — all plain `btree(name)` / `btree(labelid)`, **not**
`lower(...)`. So uniqueness is enforced case-sensitively and `SH-A015` / `sh-a015` can both exist as
separate rows. The pre-existing `findByLabelidIgnoreCase` cannot be reused for the verdict because
its query ends `limit 1` (`UnitloadRepository:80`) and picks one arbitrarily; the two new methods
return `List` for exactly this reason — `findAllByLabelidIgnoreCase` (`UnitloadRepository:118`) and
`findAllByNameIgnoreCase` (`LocationRepository:60`).

Note the asymmetry that is *not* a bug: **two distinct stored spellings** (location `DOCK-1`,
container `Dock-1`) is refused, because the string itself is ambiguous; **one shared spelling**
(both `DOCK-1`) resolves, because nothing is guessed — `scanDestination`'s pre-existing
location-first precedence then decides which entity it denotes.

### Call sites — 7 on `origin/develop` at `e5daa8ca`

| Site | Method |
|---|---|
| `StockunitService.java:185` | `canonicalUnitLoadLabel` |
| `StockunitService.java:230` | `canonicalLocationName` |
| `MobileMoveStockService.java:119` | `canonicalUnitLoadLabel` (source) |
| `MobileMoveUnitloadService.java:134` | `canonicalUnitLoadLabel` |
| `MobileMoveUnitloadService.java:290` | `canonicalUnitLoadLabel` |
| `MobileMoveUnitloadService.java:295` | `canonicalDestinationCode` |
| `StockUnitController.java:775` | `canonicalUnitLoadLabelForProbe` — the **TOTAL** variant |

⚠ `canonicalUnitLoadLabelForProbe` never throws. `isUnitLoadIdValid` is declared to return a bare
`Boolean` and has no room for an error, so the probe swallows the ambiguity and returns the input
unchanged. Do not "simplify" it to the throwing variant.

### The mobile half is not optional

`components/moveStock/scanDestination.vue` is a `v-autocomplete`: `v-model` only ever holds a value
the component **committed from `:items`**, so scanned text that was never confirmed leaves it `null`
and *no request was made at all*. The server-side fix could not have rescued that screen. The UI now
resolves the entered text against the same list the menu is drawn from
(`/stockUnit/storageLocationsForStockMovement`), via `util/commonUtility.resolveIgnoreCase`, which
mirrors this rule.

⚠ `moveUnitload`'s `isDamagedDestination` predicts the backend's `setStockDamaged` branch and was
case-sensitive **on the stated grounds that `findByName` is too**. This change falsifies that premise
— which is why **mobile-ui #50 had to merge before api #234**. With the API case-insensitive and the
UI not, a lower-case scan takes the damaged path on the server while the operator is never prompted,
and the shipper's alert carries the `DAMAGED_LOCATION_NAME` placeholder text.

**No sysprop gate**, deliberately: a rule that can only *widen* acceptance has nothing to roll back.

## 5. Activity Codes

Written to `stockrecord.activitycode` and/or `unitload_record.activitycode`. From `WmsConstants`:

| Code | When | Written by |
|---|---|---|
| `CODE_TRANSFER` | Move unitload (to location or carrier) | `MobileMoveUnitloadService.scanDestination` |
| `CODE_MANUAL_SPLIT` | Move stock split or full move | `StockunitService.transferStock` (was `MobileMoveStockService.selectDestination`, retired by SBDEV-2996) |
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
| Reserved stock held by an in-progress pick (state<600) | `"Stock is reserved by in-progress pick <PICK#>; complete or cancel it before moving..."` | 230 |
| Reserved stock, no active replen, no active pick (stranded) | **allowed** — warn + proceed (SBDEV-2610 B1; the old `"Reserved stock! can not move"` dead-end throw was removed) | 233 |
| Destination = Nirvana | `"Can not move to nirvana"` | 246 |
| Destination = Shipped | `"Can not move to shipped"` | 251 |
| Target pallet not empty (empty-pallet destination) | `"Pallet not empty!"` | 271 |
| Non-flowbin stock split disallowed | `"Moving stock to location ... not allowed!"` | 262 |
| Flowbin with multiple stocks and no assignment | `"Multiple stock not allowed on flow bin"` | 290 |
| Stock already assigned elsewhere | `"SKU already assigned to flow bin ..."` | 297 |
| Damaged-stock permission | checks `FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | 232–238 |

### Move Stock

⚠️ **Re-measured 2026-08-28 (SBDEV-2996).** Four of the six rows here cited
`MobileMoveStockService.selectDestination`, which no longer exists — that file is now 195 lines, so
the old pins at 228/273/279/288 pointed past its end. The destination half of the Move Stock flow
lives on `StockunitService.transferStock`; both halves are listed below.

**Source + amount — `MobileMoveStockService` / `MoveStockController` (still live):**

| Guard | Exception | Line |
|---|---|---|
| Source UL is the Nirvana UL | `"Can not move stock from <label>"` | `MobileMoveStockService:111` |
| Source UL on NIRVANA location | `"Can not move unit load from Nirwana"` | `MobileMoveStockService:118` |
| `transfer > available` | `"Entered amount more than available"` | `MoveStockController:80` |

**Destination — `StockunitService.transferStock` (the path both UIs use):**

| Guard | Exception | Line |
|---|---|---|
| Scanned destination label does not resolve | keyed `BusinessException(transferStockDestinationUnitloadNotFound)` | `:171` |
| Destination cannot receive stock (Nirvana sentinel ungated; lock/Shipped sysprop-gated) | keyed `BusinessException(transferStockDestinationNotUsable)` | `:177` → `DestinationEligibilityService:115, :124` |
| Flowbin `FixLocationAssignment` SKU mismatch | `"Flow bin has different SKU <name>"` | `:232` |
| Damaged-stock permission | `"No permission to alter damaged stock"` (`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`) | `:265-267` |

**Retired by SBDEV-2996, listed so nobody hunts for them:** `"Stock unit is locked on hold!"`,
`"Destination is not a flowbin!"`, `"Flowbin has different SKU"` (no space — distinct from the live
one above) and the `noValidString` destination-regex check all lived in `selectDestination`. Only the
first two are genuine gaps on the live path; see §4.1.

#### Destination error contract — `POST /v3/stockUnit/transferStock` (SBDEV-2994, 2026-08-19)

This endpoint is the **desktop + mobile Move Stock** path (distinct from `/v3/moveStock/*`, which is the
mobile-only flow above). Its destination failures now have a stated contract:

| Condition | Type | HTTP | Operator sees |
|---|---|---|---|
| Scanned destination label does not resolve | `BusinessException(transferStockDestinationUnitloadNotFound)` | **200** `{errors:[{field,message}]}` | *"Container UL314581 was not found. It may have been emptied or removed — scan a container that is currently in use."* |
| Client-supplied destination location does not resolve | `BusinessException(transferStockDestinationLocationNotFound)` | **200** `{errors:…}` | *"Location X was not found."* |
| Destination exists but cannot receive stock | `BusinessException(transferStockDestinationNotUsable)` | **200** `{errors:…}` | *"Container UL1 is To Delete / retired / already shipped and cannot receive stock."* |
| Internal reference lookup fails (`UnitloadType`, `Location` by id, `Client`, FLA …) | `EntityNotFoundException`, caught at the controller | **200** `{errors:[{field:"Runtime Error"}]}` | a fixed *"This move could not be completed. Please report reference <id> to support."* — never the exception's own text |
| Bad `stockUnit.id` (surgorate key, before the `try`) | `EntityNotFoundException` → advice | **404** | deliberately unchanged |

The discriminator behind that split — operator-supplied vs internally-derived — is documented in
[[wms-exception-taxonomy]] §3. Before SBDEV-2994 the first row threw `EntityNotFoundException` and
returned **404**, which both UIs render as *"Request failed due to a network or server issue"*: the
scanned-label case, the most likely failure on the screen, produced the least informative message.

**Destination eligibility** is centralised in `DestinationEligibilityService`, with two entry points over
one rule — `assertCanReceiveStock` (throws, write paths) and `canReceiveStock` (**TOTAL**, never throws,
backs the `isUnitLoadIdValid` probe both UIs pre-validate with). A destination may receive stock only
while its lock is `NOT_LOCKED` — an allowlist, because `BusinessObjectLockState` has eight members and a
denylist silently drifts on the next addition.

> [!warning] The probe must never throw
> `canReceiveStock` backs `GET /v3/stockUnit/isUnitLoadIdValid/{labelId}`, which has no `try` and whose
> contract is a bare `Boolean`. `Unitload.storagelocationId` is a plain `Long` with no FK guarantee and
> `findById(null)` raises `InvalidDataAccessApiUsageException`, so a null or dangling location would turn
> the probe into a 404 — reproducing this exact ticket's toast on the desktop, on a healthy container.
> Contract: null or unresolvable `storagelocation_id` ⇒ `false`.
>
> Note the deliberate asymmetry: the probe fails **closed** there, while `assertCanReceiveStock` does not
> refuse the same data. A probe cannot explain itself, so "no" is the safe answer; the write path will not
> invent an ungated rejection over unresolvable reference data.

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
- `StockunitService.transferStock` — the live Move Stock write. (`MobileMoveStockService.selectDestination` carried the same annotation and is listed in this doc's history only; SBDEV-2996 retired it — see §4.1.)
- `MobileMoveStockService.selectStockUnit` is `readOnly=true` (line 162; re-measured 2026-08-28).
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
| `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` (**default `false`**, seeded by `V2.2.17`) | SBDEV-2994: when `true`, `transferStock` refuses a destination whose lock is not `NOT_LOCKED` or which sits at `Shipped`. While `false` the rule runs in **shadow mode** — evaluated and logged as `SBDEV-2994 shadow: …` at WARN, but the move is **allowed**. Read via the house pattern `Boolean.parseBoolean(getSysvalue(KEY))`, so an absent row is OFF. ⚠ The **Nirvana-sentinel** refusal is deliberately **outside** this gate: it is the SBDEV-2995 silent-data-loss path |

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
9. **Damaged-stock permission gate** (`FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`) is checked in both flows — `MobileMoveUnitloadService:303, 308` for Move Unitload, and `StockunitService:265` for Move Stock. ⚠️ Re-measured 2026-08-28: the old "stock lines 240–247" pin referred to `MobileMoveStockService.selectDestination`, retired by SBDEV-2996; the gate on the stock flow is now solely the `StockunitService` one. A Keycloak realm that doesn't grant this role blocks all moves involving damaged stock. Check the role matrix before provisioning a new operator composite role.
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
| 2026-08-29 | **New §4.2 — scanned-identifier case resolution** (SBDEV-3134; wms2-api PR #234 + mobile-ui PR #50, both merged 2026-08-29). Documents the exact-first / case-insensitive-fallback / refuse-ambiguity rule, all 7 call sites, the TOTAL probe variant, the mobile `v-autocomplete` half, and the merge-order constraint between the two PRs. | All 7 call sites confirmed line-exact on `origin/develop` at `e5daa8ca`. `findByLabelidIgnoreCase`'s `limit 1` confirmed at `UnitloadRepository:80`; the two new `List`-returning methods at `UnitloadRepository:118` and `LocationRepository:60`. **UNIQUE-but-case-sensitive confirmed by live query on BOTH UAT and PRD hydra** — `uk_sahixf1v7f7xns19cbg12d946` on `location(name)` and `uk_s2ujivixnde5dqb2stih8m2vh` on `unitload(labelid)`, both plain `btree`, not `lower(...)`. `/storageLocationsForStockMovement` confirmed at `StockUnitController:749`. **Scoped check — the rest of the doc was NOT re-verified.** | Code read on `origin/develop` + `pg_index` on `wms2-hydra` (PRD) and `nywh-hydra-uat` |
| 2026-04-19 | `MobileMoveUnitloadService` (scanUnitLoad, scanDestination, handleTruckOffLoading), `MobileMoveStockService` (selectSource, selectStockUnit, selectDestination), `UnitloadBusinessService.transferUnitLoadToLocation / transferUnitLoadToCarrier`, `StockunitBusinessService.transferStockToUnitLoad`, REST endpoints, activity code constants, pessimistic lock site | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |

**Re-verify every 90 days.** Next due: **2026-11-27**.

_2026-07-22 (SBDEV-2610): reserved-stock guard (`checkReservedStock`) rewritten — now blocks only on an in-progress pick and allows stranded reservations; `TransferInfoDto.activeReplenNumber` added and surfaced on the source-scan screen._

_2026-08-28 (SBDEV-2996): `POST /v3/moveStock/scanDestination` and
`MobileMoveStockService.selectDestination` **retired** as unreachable code — see §4.1. §6's Move Stock
guard table re-measured (four of six rows pointed into the deleted method), §10 landmine 9 corrected,
and the create-vs-reject semantics written down. Verified by an independent review lane, which found
and corrected two wrong rows in §4.1's own guard table._

_2026-08-19 (SBDEV-2994): destination error contract added to §6 — operator-supplied lookups on
`POST /v3/stockUnit/transferStock` now raise keyed `BusinessException`s instead of 404-ing, internal
lookups are netted at the controller with an operator-safe string, and destination eligibility is
centralised in `DestinationEligibilityService` behind `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED`
(default OFF, shadow-logging). `RestExceptionHandler`'s `EntityNotFoundException` log raised debug→warn._
