---
title: "WMS v2 — Receiving & Putaway Workflow"
type: workflow
status: active
version: v2
scope: receiving-putaway
owner: Nam Park
created: 2026-04-19
updated: 2026-04-19
last_verified: 2026-05-10
verified_by: code read of v2/wms2-api service/AdviceService + ReceivingService + mobile/MobilePutAwayService
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ../data-dictionary/wms2-sysprop-catalog.md
  - ../../4-Archieves/wms2/plan/260424-RECEIVING_PERFORMANCE_PLAN.md
  - ../../4-Archieves/wms2/plan/260424-RECEIVING_QUANTITIES_FIX_PLAN.md
  - ../../4-Archieves/wms1/plan/260424-receiving-stockunit-unitload-error-analysis-review.md
  - ../../4-Archieves/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md
tags:
  - workflow
  - receiving
  - putaway
  - wms2
---

# WMS v2 — Receiving & Putaway Workflow

**Scope:** Physical inbound flow in `v2/wms2-api` — from supplier ASN arrival through goods receipt, stock creation, and putaway to a storage location · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

Receiving takes a promised shipment (an `Advice` / ASN) and turns it into physical stock at a warehouse location. The flow spans three distinct phases:

1. **Advice lifecycle** — the paper-trail: `CREATED → OPEN → PROCESSING → CLOSED → FINISHED` (String states, two-L `CANCELLED`).
2. **Physical receive** — scanner-driven ingestion that creates `Goodsreceiptposition`, `Stockunit`, `Stockrecord`, and `Unitload` rows. Owner: `ReceivingService.receiveGoods()`.
3. **Putaway** — mobile-driven movement from the receiving lane to a storage slot. Owner: `MobilePutAwayService`. Target-location selection classifies by `LocationType` (`FLOWBIN` vs `OVERSTOCK`) and enforces `FixLocationAssignment` constraints.

Three things to hold in mind:

- **String-state entities** — `Advice` and `Adviceposition` use `AdviceState.CANCELLED` (two L's), not the Integer `CANCELED`. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §7 item 2.
- **`INBOUND_UPDATE_STOCK_IMMEDIATELY` (default `true`)** gates whether a stock-change message is fired to OMS synchronously during receive. Flipping it moves stock updates out of the hot path but delays OMS visibility.
- **`SBDEV-2102`** (active) documents the fix for a multi-replica race where `storePalletBackOnPutawayLane` would yank a pallet off another replica's operator. The fix requires "pallet must be on the current user's location" — don't remove that guard.

---

## 2. Entity Cast

| Entity | Role | State field |
|---|---|---|
| `Advice` | Header for a promised inbound shipment | String `state` (`AdviceState.*`) |
| `Adviceposition` | Line — SKU + expected qty | String `state` (same set) |
| `Goodsreceipt` | Header for the physical receiving event (one per advice) | — (no state) |
| `Goodsreceiptposition` | One physical case received | — |
| `Unitload` | The pallet / tote that holds the received stock | — |
| `Stockunit` | Amount at a location (created per case) | — |
| `Stockrecord` | Audit entry for stock movement | — |
| `Location` | The physical slot | — |
| `FixLocationAssignment` | Item → designated pick face binding | — |

---

## 3. Advice Lifecycle

```
  (OMS creates / file import arrives)
            │
            │  AdviceService (various)  OR  AdviceRestController.create/createTransfer/createHubAndSpoke
            ▼
   Advice.state = OPEN                 (created with state=OPEN; never dwells in CREATED for long)
   Adviceposition.state = OPEN
            │
            │  ⚠ SBDEV-2778 EXCEPTION — type=RETURN via /rest/advice/create does NOT stop here.
            │  Unless the RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED sysprop is 'false', the advice is
            │  received and closed synchronously inside the same request: no dock scan, no operator.
            │  See §3.5 below. Every other path (REGULAR, TRANSFER, and RETURN via FILE IMPORT)
            │  still follows the arrow below.
            │
            │  physical receive per position
            │  ReceivingService.receiveGoods() [line 303-543]
            ▼
   Adviceposition.state = OPEN → (stays OPEN until close)
   Goodsreceiptposition rows created
   Stockunit rows created
   Unitload rows created / transferred
            │
            │  AdviceService.close()       [line 264-353]
            ▼
   Advice.state = FINISHED
   Adviceposition.state = FINISHED  (bulk JPQL update via updateAdvicepositionToStateByAdviceId)
            │
            ▼
   Post-commit OMS callback: WEBSERVICE_CLOSE_ADVICE
```

### Variants

| Entry method | Path | Purpose |
|---|---|---|
| `AdviceService.close(Advice)` | `AdviceService.java:264` | Regular advice finalize; fires `WEBSERVICE_CLOSE_ADVICE` |
| `AdviceService.acceptTransferAdvice(...)` | `AdviceService.java:356` | Transfer-type advice accept; fires `WEBSERVICE_ACCEPT_TRANSFER` |
| `AdviceService.acceptHubAndSpokeAdvice(...)` | `AdviceService.java:145` | Hub-and-spoke accept; fires `WEBSERVICE_ACCEPT_HUB_AND_SPOKE`; creates `Unitload`, `CustomerorderBatch`, `Customerorder` in the same TX |
| `AdviceRestController.reopen(...)` | `AdviceRestController.java:648` | **NOT IMPLEMENTED** — throws `RuntimeException("method not supported")`. See §9 item 3. |

All three state-writing methods: `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`.

---

## 4. Physical Receive — `ReceivingService.receiveGoods`

The core inbound operation at `ReceivingService.java:303-543`. Called from the receiving workstation when an operator scans items at the inbound gate.

### 4.1 Preconditions

- `Advice.state == OPEN` (close handler rejects PROCESSING / CLOSED / FINISHED / CANCELLED).
- A `Goodsreceipt` header exists for the advice, or is created on first receive (line 405-414).
- Pallet / cart label matches regex `STRING_PATTERN_INBOUND_PALLET` (default `CART-\d{4}|IN-\d{6}`), validated by `verifyPalletOrCartLabel` at `ReceivingService.java:616-628`.
  ⚠ **Updated 2026-08-25 for SBDEV-3004.** The stated default is now actually applied in code: `getSysvalue` returns the raw repository result, so a tenant with no `STRING_PATTERN_INBOUND_PALLET` row previously produced `label.matches(null)` → NPE. `verifyPalletOrCartLabel` now falls back to `WmsConstants.SYSTEM_PROPERTY_STRING_PATTERN_INBOUND_PALLET_DEFAULT_VALUE` when the row is absent or blank. Measured across WineCo dev, four UAT tenants and Hydra prd, the key is seeded everywhere, so this is a guard rather than a fix for an observed failure. Same commit also added the missing `verifyPalletOrCartLabel` call to `unassignPallet:697` (it validated nothing before) and made `updatePallet:652` the transaction boundary for the unassign→assign pair.

### 4.2 Core loop (line 459-499)

**Updated 2026-08-10 for SBDEV-2732 (wms2-api PR #139) — MERGED 2026-08-11; this is shipped behaviour.** `putAwayLocation` is no
longer `itemdata.putawaylocation_id`. It is resolved through a **four-tier hierarchy** ONCE above the
loop, on **both** the carrier and non-carrier branches, and a pick-face destination is diverted before
placement.

```java
// ABOVE the loop. Resolving inside `if (carrier == null)` is SBDEV-2731's root cause: the configured
// destination then never reaches the display and the operator cannot see where the receipt is going.
Resolution putaway = putawayDestinationResolver.resolve(itemdata, client, adviceposition.getUnitloadtypeId());
//   tier 1 itemdata.putawaylocation_id → tier 2 client.defaultputawaylocation_id
// → tier 3 sysprop DEFAULT_PUTAWAY_LOCATION (system client, workstation DEFAULT) → tier 4 PutAwayLane
putawayResolutionMetrics.resolved(putaway.source(), carrier != null, putaway.compatible());

// (iv-b) PLACEMENT GATE. A pick face is a LEGAL configuration at every tier, but a receipt is never
// placed into one: receiving moves a whole unit load and a flowbin permits only PickLocation. The
// receipt goes to the lane and putaway routes it into the bin (SBDEV-2821, §5.2).
// The OR is deliberate — the constraint is a location TYPE property, useforpicking is an AREA
// property, and nothing in the schema ties them.
boolean pickFace = area.getUseforpicking() == TRUE || locationType.getSltname() == 'flowbin';
if (pickFace && putaway.source() != STANDARD_PUTAWAY_LANE)
    putaway = putawayDestinationResolver.divertPickFaceToLane(putaway, unitloadtypeId);

// Hard-fail ONLY on the non-carrier branch (D10): on the carrier path the destination is surfaced but
// not applied, so a config error irrelevant to this receipt must not abort it.
if (carrier == null) putawayDestinationResolver.requireCompatible(putaway);
```

```
for each case being received on the adviceposition:
    Unitload unitload = unitloadService.createUnitload(workstation, typeId, client, CODE_RECEIVING, ...)
    Stockunit stockUnit = stockunitBusinessService.createStockUnit(client, item, amount, false, unitload, ...)
    Goodsreceiptposition pos = new Goodsreceiptposition()
    pos.setStockunitId(stockUnit.getId()); pos.setAmount(stockUnit.getAmount())
    goodsreceiptpositionRepository.save(pos)

    if (carrier == null)
        unitloadBusinessService.transferUnitLoadToLocation(unitload, putaway.location(), ...)
    else
        unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, ...)
```

The loop runs once per case (`amountBottlesPerCase` drives the divisor). Each iteration creates: 1 `Unitload` + 1 `Stockunit` + 1 `Stockrecord` (via `createStockUnit`) + 1 `Goodsreceiptposition` row.

Pessimistic-write lock on the `Adviceposition` row guards against concurrent receivers doing the same case twice.

**The resolution is per-RECEIPT, not per-case** — the SKU, merchant and unit-load type are identical for
every case in the loop, and a bad destination fails before any unit load exists. `GET
/v3/receiving/getPutawayDestination/{advicePositionId}` returns the same resolution for the display,
including a `divertedTo` field when the gate retargets it, so the screen and the placement cannot
disagree.

### 4.3 OMS stock-change gate (line 505-523)

```java
if (advice.getType() == REGULAR) {
    if (Boolean.parseBoolean(syspropService.getSysvalue(INBOUND_UPDATE_STOCK_IMMEDIATELY_KEY))) {
        list.add(getStockChangeDTO(...));
    }
} else if (advice.getType() == RETURN) {
    list.add(getStockChangeDTO(...));  // always
}
messageService.sendStockChangeMessage(list);
```

- `INBOUND_UPDATE_STOCK_IMMEDIATELY` (default `true`) — when true, every REGULAR receive fires a stock-change message. When false, no message is sent during receive (OMS catches up via the nightly `StockSummaryExportJob`).
- RETURN advices **always** fire a stock-change message regardless of the sysprop.

### 3.5 RETURN auto-receive at advice-create time (SBDEV-2778, supersedes SBDEV-2236)

**History matters here, because this behavior has flipped twice.** v1/wms-api always auto-received a
RETURN advice at create time. SBDEV-2236 (merged 2026-05-15, PR #24, `7f9c250`) deliberately deleted
that, on the requirement that physical confirmation must precede the stock increment. SBDEV-2778
restored it on BA decision (2026-08-03) — Return QA *is* the physical confirmation. **Do not "re-fix"
this by citing SBDEV-2236; its plan carries a SUPERSEDED banner.**

Path: `AdviceRestController.create` → `ReturnAdviceAutoReceiveService`. Two insertion points, and the
order is load-bearing:

| Phase | What | Why there |
|---|---|---|
| `validate(dto)` | printer + boxtype + amount + SKU resolution, then ONE CUPS reachability probe | Runs **before** `adviceRepository.save(...)`. `create()` is not `@Transactional`, so a rejection after the save would commit an orphan OPEN advice holding `externalid=RETURN{parcel_id}`, and every OMS retry would then fail the duplicate guard — the return becomes unrecoverable without DB surgery |
| `bind(validated, savedAdvice, savedPositions)` | zips validated lines to persisted position ids **positionally** | Keying by `externalid` collapses two positions that share a `reference_id` (the duplicate checks are on SKU, not reference_id) |
| `execute(plan)` | per-position `receiveGoods`, each in its own tenant tx | Deliberately NOT wrapped in an outer transaction: it would hold one connection across all N CUPS round-trips, batch all N STOCK_UPDATEs onto one commit, and poison the outer tx via `receiveGoods`'s `rollbackFor` |
| `markFinished(adviceId)` | both FINISHED flips, in ONE tenant tx, only after every position succeeded | Split commits can leave positions FINISHED with the advice OPEN, which `ReceivingService:344` then refuses to dock-receive — a BOL no path can ever receive |

**Kill switch:** `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`, seeded `'true'` by Flyway `V2.2.09`.
⚠ **It is read DEFAULT-ON** — `!"false".equalsIgnoreCase(trimToEmpty(getSysvalue(...)))`, deliberately
**not** the house `Boolean.parseBoolean(getSysvalue(...))` pattern used by every other flag, because
`parseBoolean(null) == false` would silently restore the bug on any tenant missing V2.2.09. An absent
row means ON.

**Landmine — v1 has a defect that was NOT ported.** `v1:307` wraps `receiveGoods` in
`if (printerOptional.isPresent())` with no `else`, while the FINISHED flips at `v1:317-318` sit
*outside* that guard. On a tenant with no `processdefault` RETURN printer, v1 therefore marks the
advice FINISHED having received nothing — a phantom-**closed** return, worse than the open BOL the
ticket reported. v2 throws instead.

**Per-tenant prerequisites** (any missing one makes every RETURN advice 400, or worse):
a `processdefault=true` `type='RETURN'` printer; a `boxtype` with `externalid='1'`; a `mywms_user`
named `anonymous` (`ReceivingService:359` — `/rest/**` is unauthenticated, so
`SecurityContextUtils.getUserName()` returns its fallback); and the `MAXIMUM_RECEIVING_DURING_INBOUND`
and `WAREHOUSE_NAME` sysprops set (both are unguarded reads inside `receiveGoods`).

**Note the notification timing moved.** `CODE_RECEIVING_RETURN` `STOCK_UPDATE` now fires at
advice-create time for auto-received RETURNs, not at dock-receive time — which is v1's timing, and
what SBDEV-2236 had deliberately changed.

### 4.4 Post-commit label print

Label printing is registered via `TransactionSynchronizationManager.registerSynchronization` (line 532-541) so the printer only fires after the receive commits. If the transaction rolls back, no label is printed — this is the correct behavior.

---

## 5. Putaway — Mobile Flow

Owner: `MobilePutAwayService`. All six methods use `@Transactional("tenantTransactionManager")`; three are `readOnly=true`.

| Method | Line | `@Transactional` mode | Purpose |
|---|---|---|---|
| `findUnitLoad` | 91 | write | Validate scanned unit load is in PUTAWAY_LANE or CLEARING; transfer to operator's current location |
| `storePalletOnLocation` | 156 | write | Transfer pallet → scanned storage location. Activity code `CODE_PUT_AWAY` or `CODE_UNASSIGN_PUT_AWAY` depending on `useforstorage` |
| `storePalletBackOnPutawayLane` | 185 | write | Error-recovery path. **SBDEV-2102 fix**: only recovers if pallet is on the *current user's* location (prevents yanking under multi-replica) |
| `calculatePutAwayList` | 212 | readOnly | Classify target locations as FLOWBIN or OVERSTOCK (§5.2) |
| `updateCurrentItemDataUnitLoadList` | 354 | readOnly | Per-SKU filtering as operator works through a mixed pallet |
| `verifyScannedLocation` | 397 | readOnly | Validate `FixLocationAssignment` constraint on the scanned location (§5.3) |
| `storeBoxOnLocation` | 446 | write | Box-level (case-level) putaway. **SBDEV-2102 Bug 6 fix**: passes `removeUnitLoadIfEmpty=true` to prevent stale-object-state on consecutive empty transfers |

### 5.1 Scan flow (happy path)

```
Operator scans pallet
   │
   ▼ findUnitLoad()
   Unitload moved to operator's current location; pallet contents + SKUs loaded
   │
   ▼ calculatePutAwayList()
   Query Location.getStorageLocationsForPutAwayItemData(itemId)
   Classify each location by LocationType.sltname:
     - STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN → flowBinLocationList
     - STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK or PALLET_RESTRICTION_OVERSTOCK → overstockLocationList
   Sort by DefaultStrategy (rack + rack-row; direction controlled by PICK_PATH_DIRECTION sysprop via PickPathConfig → DefaultStrategy)
   │
   ▼ operator walks to suggested location, scans it
   │
   ▼ verifyScannedLocation()
   If FLOWBIN: confirm FixLocationAssignment matches (or target has no assignment)
   │
   ▼ storeBoxOnLocation() or storePalletOnLocation()
   unitloadBusinessService.transferUnitLoadToLocation(...) OR transferStockToUnitLoad(...)
```

### 5.2 Target-location classification (`MobilePutAwayService` lines 268–295, inside `calculatePutAwayList` at :217)

⚠ **Updated 2026-08-09 for SBDEV-2821.** Two things changed: where candidates come from, and a fourth
location type that was previously dropped.

**Updated again 2026-08-10 for SBDEV-2732 step 17a (PR #139) — MERGED 2026-08-11.** The second argument is no
longer the tier-1 column: `V2.2.13` nulls `putawaylocation_id` wherever it merely held the seeded lane
id, and §4.2's gate diverts pick-face destinations at **every** tier — so a merchant- or
warehouse-scope destination left on tier 1 would be diverted to the lane at receipt and then never
offered here, stranding the unit load on the lane with nowhere the screen will send it.

```java
// SBDEV-2821: was getStorageLocationsForPutAwayItemData(skuId), which derives candidates ONLY from
// where the SKU already has stock — so a SKU being received into a dedicated bin for the first time
// got ZERO candidates and its configured destination was never offered.
// SBDEV-2732 step 17a: the destination is the FOUR-TIER resolution, not the SKU column. Tier 4 maps
// back to null — resolve() always answers, and passing the lane id would offer the lane the unit load
// is being moved OFF as somewhere to move it TO.
List<Location> candidates = locationRepository.getPutAwayCandidateLocations(
        currentSku.getId(), resolveCandidateDestinationId(currentSku, skuClient));
for (Location loc : candidates) {
    LocationType type = locationTypeRepository.findById(loc.getTypeId()).orElseThrow(...);
    switch (type.getSltname()) {
        case STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN:
            flowBinLocationList.add(loc.getName()); break;
        case STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK:
        case STORAGE_LOCATION_TYPE_PALLET_RESTRICTION_OVERSTOCK:
        case STORAGE_LOCATION_TYPE_STOCK_RESTRICTION:   // SBDEV-2821 — 'cases and pallets'
            overstockLocationList.add(loc.getName()); break;
        default:
            // still only LOGS — any other type is silently not offered
    }
}
```

FLOWBIN locations are pick-face (fast-moving) — they take priority in the UI. OVERSTOCK absorbs overflow.

**`cases and pallets` (`STORAGE_LOCATION_TYPE_STOCK_RESTRICTION`, `WmsConstants:741`) used to hit
`default:` here and be silently dropped** — the destination never reached the operator. It is the type
wineco's club lanes use. It is bucketed with overstock because it takes a **whole unit load**, unlike
flowbin which merges stock into a resident `PickLocation` UL.

**The candidate query's second leg carries `(useforstorage = 'true' OR staginglane = true)`, mirroring
§5.3's own gate.** That predicate is load-bearing, not decorative: `PutAwayLane` is itself a
`cases and pallets` location with `useforstorage = false`, and on `wms2-wineco-dev` 8,803 of 8,804 SKUs
have `putawaylocation_id = PutAwayLane`. Without it, adding the type to this switch would offer every
operator "put it back on the PutAwayLane".

### 5.3 Fixed-assignment constraint (line 433-455)

When the operator scans a FLOWBIN target, `verifyScannedLocation` enforces:

- If the item has a `FixLocationAssignment`, the scanned location must match the assigned location.
- If the scanned location has an assignment, the item being put away must match.
- If neither side has an assignment, the put is allowed.

Mismatches throw `BusinessException` with a UI-facing message.

**This whole block is FLOWBIN-only** — `verifyScannedLocation`'s fixed-assignment branch is gated on
`sltname == 'flowbin'`. A `cases and pallets` target (a club lane) is deliberately **not** subject to it,
and `storeBoxOnLocation` must never create a `FixLocationAssignment` for one: a club lane is a live
multi-SKU pick face (`Club01` carries 27 distinct SKUs on `wsl-wineco-uat`; 15 on `wms2-wineco-dev`), and `fix_location_assignment` is
`UNIQUE(assignedlocation_id)`, so binding it to the first SKU put away would break every other SKU on
that lane. Pinned by `casesAndPalletsDestinationShouldPlaceWithoutCreatingFixLocationAssignment`.

What `verifyScannedLocation` *does* apply to every type is its area gate at `:427` —
`!useforstorage && !staginglane` ⇒ `locationNotUsableForStorage`. SBDEV-2821's candidate query mirrors
that gate exactly (§5.2) so a location can never be offered that the scan would then refuse.

---

## 6. REST + File-Import Entry Points

### Advice creation

| Endpoint | Method | File:Line | Input |
|---|---|---|---|
| `/rest/advice/create` | PUT | `AdviceRestController.java` | `List<AdviceDto>` — creates REGULAR or RETURN advices. **RETURN is also received + closed here** unless the kill switch is off (SBDEV-2778, §3.5). Reads `printer_id`, which was accepted-and-discarded before SBDEV-2778 |
| `/rest/advice/createTransfer` | PUT | | `BillOfLadingWebServiceDto` — TRANSFER-type advice from OMS |
| `/rest/advice/createHubAndSpoke` | PUT | | `BillOfLadingWebServiceDto` with manifest — hub-and-spoke flow |
| `/rest/advice/reopen` | POST | `AdviceRestController.java:648` | **Throws RuntimeException — not implemented** |

### File import

| Controller | Endpoint | File:Line | Creates |
|---|---|---|---|
| `FileImportController` | `POST /v3/import/clients` | 97 | `Client` entities (supports receiving flow by seeding clients) |
| `FileImportController` | `POST /v3/import/locations` | 146 | `Location`, `LocationArea`, `LocationRack`, `LocationRackRow` |
| `ReceivingController` | `POST /v3/receiving/createPallet` | 144 | `Unitload` (pallet at INBOUND) |
| `ReceivingController` | `POST /v3/receiving/createAndSelectPallet` | 99 | `Unitload` + pallet swap |
| `ReceivingController` | `POST /v3/receiving/setPallet` | 60 | Pallet assignment swap |

### Mobile putaway REST

All under `/mobile/putAway/...`, delegating directly to `MobilePutAwayService` methods.

---

## 7. OMS Callbacks

| Callback | Fired from | Sysprop URL key |
|---|---|---|
| `WEBSERVICE_CLOSE_ADVICE` | `AdviceService.close` (line 343-347) | `SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY` |
| `WEBSERVICE_ACCEPT_TRANSFER` | `AdviceService.acceptTransferAdvice` (line 406) | `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY` |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `AdviceService.acceptHubAndSpokeAdvice` (line 251) | `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL_KEY` |
| Per-receive stock-change | `ReceivingService.receiveGoods` (line 507-523) | via `messageService.sendStockChangeMessage` — gated by `INBOUND_UPDATE_STOCK_IMMEDIATELY` |

All callbacks use `omsNotificationService.sendAfterCommit(...)` — post-commit only. Rollback silently drops the callback.

---

## 8. Transaction Boundaries

- `AdviceService.close` / `acceptTransferAdvice` / `acceptHubAndSpokeAdvice`: single `@Transactional` atomic.
- `ReceivingService.receiveGoods`: single `@Transactional` atomic — all cases for one adviceposition commit together, all roll back together.
- `MobilePutAwayService` write methods: single TX each. The 3 `readOnly=true` methods (lines 211, 353, 396) are the cache-friendliest read paths.
- Pessimistic-write lock on `Adviceposition` during receive (see [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8.2).
- Post-commit hooks: label printing (receive), OMS callbacks (close / accept), stock-change message (receive).

---

## 9. Known Landmines

1. **`CANCELLED` spelling** — String-state entity. Use `WmsConstants.AdviceState.CANCELLED`, not `State.CANCELED`.
2. **`SBDEV-2102` putaway-lane recovery** — `storePalletBackOnPutawayLane` only recovers pallets at the current user's location. Any change to that guard re-opens the multi-replica race. See the active plan.
3. **`AdviceRestController.reopen` is a stub.** Calling it throws `RuntimeException("method not supported")`. If an operator UI exposes a reopen button, it silently errors. Either implement it or remove the endpoint.
4. **`INBOUND_UPDATE_STOCK_IMMEDIATELY` flip is load-bearing.** When `false`, no stock-change message fires during receive — OMS visibility depends on nightly `StockSummaryExportJob`. Be explicit per-tenant.
5. **`RETURN` advices always fire stock-change**, ignoring the sysprop. The branch at line 515 is unconditional. Don't "consolidate" both cases.
6. **`receiveGoods` loop-per-case can produce hundreds of rows.** One palletful of bottles at 12/case × 12 cases creates 12 Unitloads + 12 Stockunits + 12 Stockrecords + 12 Goodsreceiptpositions per receive — all in one TX. Large advices sustain pessimistic-lock contention.
7. **Fixed-assignment mismatch throws `BusinessException`, not a soft warning.** The mobile UI surfaces this as a red error. A legitimate one-off override requires admin action (unset the assignment, then re-put).
8. **Pallet label regex is tenant-configurable** (`STRING_PATTERN_INBOUND_PALLET`, default `CART-\d{4}|IN-\d{6}`). A tenant with a different barcode scheme must override it.
9. **`GoodsreceiptService` doesn't exist as a class.** The goods-receipt writes happen inside `ReceivingService.receiveGoods`. Don't grep for `GoodsreceiptService` — nothing there.
10. **Label printing is post-commit.** If the printer is down, the commit still succeeds; the label is lost. No automatic re-queue.

---

## 10. How to debug

| Symptom | Start here |
|---|---|
| "Advice stuck in OPEN, won't close" | §3 close path + guard at `AdviceService.close:290-294` |
| "Stock shows at wrong location after receive" | §4.2 loop — one `Unitload` per case, each transferred independently |
| "Putaway refuses scanned location" | §5.3 fixed-assignment constraint + §9 item 7 |
| "Two operators ended up with the same pallet on putaway" | §9 item 2 SBDEV-2102 — the fix is already in place |
| "OMS didn't get stock update from a regular receive" | §4.3 — check `INBOUND_UPDATE_STOCK_IMMEDIATELY` + `message` table |
| "Label didn't print after receive" | §10 item 10 — post-commit, no retry |
| "`reopen` endpoint throws" | §6 + §9 item 3 — intentional |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `AdviceService` (close, accept variants, reopen stub); `ReceivingService.receiveGoods` loop + stock-change gate; `MobilePutAwayService` all 6 methods + location classification + fixed-assignment validator; OMS callbacks | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-08-03 | §3.5 added: RETURN auto-receive at advice-create time (SBDEV-2778, supersedes SBDEV-2236); advice-lifecycle diagram annotated; `/rest/advice/create` row corrected | Verified against the SBDEV-2778 branch only — **the rest of the doc was NOT re-verified, so `last_verified` is deliberately left at 2026-05-10** | Code read (SBDEV-2778 diff) |

| 2026-08-06 | §4 receiving loop's `if (carrier == null)` fork and §5.2 target-location classification, re-checked for SBDEV-2731 (PRs wms2-api #133 / wms2-web-ui #39) | Both **confirmed accurate** against `ReceivingService:491-495` and `MobilePutAwayService:268-288`. §5.2's anchor was stale (`line 263-283`) and is corrected to `268–288`, now naming the enclosing method. SBDEV-2731 changed only the *message* thrown on constraint rejection, not the routing this doc describes, so no behavioural text needed updating. **Scoped check — the rest of the doc was NOT re-verified, so `last_verified` stays at 2026-05-10.** | Code read (SBDEV-2731 diff + targeted greps) |

| 2026-08-09 | §5.2 and §5.3 **rewritten** for SBDEV-2821. §5.2's quoted code block was invalidated on two counts: candidates now come from `getPutAwayCandidateLocations(skuId, configuredLocationId)` rather than the stock-derived `getStorageLocationsForPutAwayItemData(skuId)`, and the switch gained a fourth case (`cases and pallets`) that previously fell to `default:` and was silently dropped. §5.3 gained the flowbin-only scoping of the fixed-assignment branch and the club-lane no-FLA rule. Anchor corrected `268–288` → `268–295`; §5.3 anchor and its `:418` citation rebased to `433-455` / `:427`. | Confirmed against the SBDEV-2821 branch. The `(useforstorage OR staginglane)` predicate on the query's second leg was additionally proven by executing the shipped SQL against `wms2-wineco-dev` — it is what keeps `PutAwayLane` (itself `cases and pallets`, `useforstorage=false`, the configured destination of 8,803/8,804 SKUs) out of the candidate list. **Scoped check — the rest of the doc was NOT re-verified, so `last_verified` stays at 2026-05-10.** | Code read (SBDEV-2821 diff) + live SQL on `wms2-wineco-dev` |
| 2026-08-10 | §4.2 and §5.2 updated for **SBDEV-2732** (wms2-api PR #139, **MERGED 2026-08-11**). §4.2's `putAwayLocation` is no longer `itemdata.putawaylocation_id`: it is a four-tier resolution taken ONCE above the loop on both branches, followed by the (iv-b) pick-face placement gate and a `carrier == null`-only `requireCompatible`. §5.2's second query argument moves from the tier-1 column to that same resolution, with tier 4 mapping back to null. | Confirmed against the SBDEV-2732 branch at `aff434e`. **Described unmerged behaviour when written; PR #139 MERGED 2026-08-11, so this row now describes the shipped code** (status corrected 2026-08-25). **Scoped check: the rest of the doc was NOT re-verified, so `last_verified` stays at 2026-05-10** — it is now 92 days old and due a full pass. | Code read (SBDEV-2732 diff) |

**Re-verify every 90 days.** Next due: **2026-07-18** — receiving logic is stable but mobile putaway (SBDEV-2102 area) is fix-prone. ⚠️ **Overdue as of 2026-08-06.** Two scoped checks have landed since (2026-08-03, 2026-08-06) but neither was a full pass; a top-to-bottom re-verification is still owed.
