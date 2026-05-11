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
  - ../../1-Projects/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md
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
- Pallet / cart label matches regex `STRING_PATTERN_INBOUND_PALLET` (default `CART-\d{4}|IN-\d{6}`), validated by `verifyPalletOrCartLabel` at line 545-549.

### 4.2 Core loop (line 459-499)

```
for each case being received on the adviceposition:
    Unitload unitload = unitloadService.createUnitload(workstation, typeId, client, CODE_RECEIVING, ...)
    Stockunit stockUnit = stockunitBusinessService.createStockUnit(client, item, amount, false, unitload, ...)
    Goodsreceiptposition pos = new Goodsreceiptposition()
    pos.setStockunitId(stockUnit.getId()); pos.setAmount(stockUnit.getAmount())
    goodsreceiptpositionRepository.save(pos)

    if (carrier == null)
        unitloadBusinessService.transferUnitLoadToLocation(unitload, putAwayLocation, ...)
    else
        unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, ...)
```

The loop runs once per case (`amountBottlesPerCase` drives the divisor). Each iteration creates: 1 `Unitload` + 1 `Stockunit` + 1 `Stockrecord` (via `createStockUnit`) + 1 `Goodsreceiptposition` row.

Pessimistic-write lock on the `Adviceposition` row guards against concurrent receivers doing the same case twice.

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

### 5.2 Target-location classification (line 263-283)

```java
List<Location> candidates = locationRepository.getStorageLocationsForPutAwayItemData(currentSku.getId());
for (Location loc : candidates) {
    LocationType type = locationTypeRepository.findById(loc.getTypeId()).orElseThrow(...);
    switch (type.getSltname()) {
        case STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN:
            flowBinLocationList.add(loc.getName()); break;
        case STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK:
        case STORAGE_LOCATION_TYPE_PALLET_RESTRICTION_OVERSTOCK:
            overstockLocationList.add(loc.getName()); break;
    }
}
```

FLOWBIN locations are pick-face (fast-moving) — they take priority in the UI. OVERSTOCK absorbs overflow.

### 5.3 Fixed-assignment constraint (line 418-439)

When the operator scans a FLOWBIN target, `verifyScannedLocation` enforces:

- If the item has a `FixLocationAssignment`, the scanned location must match the assigned location.
- If the scanned location has an assignment, the item being put away must match.
- If neither side has an assignment, the put is allowed.

Mismatches throw `BusinessException` with a UI-facing message.

---

## 6. REST + File-Import Entry Points

### Advice creation

| Endpoint | Method | File:Line | Input |
|---|---|---|---|
| `/rest/advice/create` | PUT | `AdviceRestController.java` | `List<AdviceDto>` — creates REGULAR or RETURN advices |
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

**Re-verify every 90 days.** Next due: **2026-07-18** — receiving logic is stable but mobile putaway (SBDEV-2102 area) is fix-prone.
