---
title: "WMS v2 — BOL / Truck Loading / Shipping Workflow"
type: workflow
status: active
version: v2
scope: bol-truck-loading
owner: Nam Park
created: 2026-04-19
updated: 2026-10-16
last_verified: 2026-09-24
verified_by: SBDEV-3672 docs lane — §1 shipped bullet, §3 diagram enqueue line, §6.5 (rewritten), §7 SHIPPED row, §9 two new rows, §12 one new row only (2026-10-16, code read at wms2-api 1866ab66, re-cited at 057d0e3b, and wms2-web-ui 63b0a89; rest of doc NOT re-verified); earlier: SBDEV-3547 §6.4 pending-reversal paragraph only (2026-09-28, code read in the SBDEV-3547-a worktree); earlier: SBDEV-3487 D0-row only (2026-09-24, code read in the SBDEV-3487 worktree — scoped check, rest of doc NOT re-verified); earlier: SBDEV-2797 API half (bulk BOL export; §"REST endpoints" export row rewritten — endpoint moved 265→276 and its request/response contract changed; empty-export behaviour re-confirmed as deliberate per a8af84f)
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ./wms2-picking-workflow.md
  - ./wms2-club-run-workflow.md
  - ./wms2-cancel-cascade-workflow.md
  - ../../4-Archieves/wms2/plan/260424-CLOSE_BOL_FURTHER_IMPROVEMENTS.md
  - ../../4-Archieves/wms2/plan/260424-oms-palletized-loaded-to-truck-notifications-plan.md
  - ../../4-Archieves/wms2/plan/260424-ORDER_LOADED_TO_TRUCK_DASHBOARD_PLAN.md
tags:
  - workflow
  - bol
  - truck-loading
  - shipping
  - wms2
---

# WMS v2 — BOL / Truck Loading / Shipping Workflow

**Scope:** From `PALLETIZED` customer orders through BOL open / truck loading / close in `v2/wms2-api` · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-05-08

---

## 1. Overview

The BOL (Bill of Lading) flow is how picked+packed orders leave the warehouse. It spans a desktop path (`ParcelMonitorViewService`) and a mobile path (`MobileTruckLoadingService`) that converge on the same `Billoflading` state machine. Closing the BOL (`BillofladingService.closeBOL`) is the single most expensive state transition in the codebase — it:

- Acquires a pessimistic lock on the BOL row + an in-memory `bolToClose` set (double-guard against concurrent closes).
- Bulk-updates all `BillofladingPosition` rows via JPQL (one query instead of N).
- Bulk-finalizes all `Customerorder` + `CustomerorderPosition` rows in the BOL to `FINISHED` (JPQL).
- Bulk-transfers every `Unitload` on the BOL to the SHIPPED location + sets entity locks.
- Enqueues the `ORDER_BATCH_SHIPPED` OMS notification as an outbox row inside the close transaction; the outbox dispatcher POSTs it after commit (§6.5). A REGULAR or HUB_AND_SPOKE BOL with more than K parcels becomes N chunk rows ⏳ pending-merge(SBDEV-3672).

BOL state machine (String — two-L `CANCELLED`):

```
CREATED → OPEN → TRUCK_LOADING → CLOSED
                               └─► TRANSFER   (for TRANSFER_INTRACOMPANY type only)
          └────► CANCELLED
```

---

## 2. Entity Cast

| Entity | Role | State |
|---|---|---|
| `Billoflading` | BOL header | String `state` (`BillOfLadingState.*`) |
| `BillofladingPosition` | Position tree (pallet → parcel → stock) | String `state` |
| `Customerorder` | Order being shipped | Integer `state` |
| `CustomerorderBatch` | Batch rollup | Integer `state` |
| `Unitload` | Pallet / parcel / stock carrier | — (location-based lifecycle) |
| `Stockunit` | Stock on the carriers | — |

BOL state constants live at `service/WmsConstants.java:244-253`. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §4.9 for the full state map and §9 for the two-L spelling gotcha.

---

## 3. Lifecycle

```
Customerorder.state = PALLETIZED
 (set by ParcelMonitorViewService.palletise   [line 103-230]
   or   MobilePalletizingService.palletizeOrder   [line 220])
            │
            │  REST /v3/billOfLading/create    [BillOfLadingController:69]
            ▼
   Billoflading.state = OPEN                       [BillofladingService.createEntity:229]
            │
            │  ┌────────────────────────────────────────────────┐
            │  │ Two paths to loading — desktop or mobile        │
            │  └────────────────────────────────────────────────┘
            │
            ├─► Desktop:  REST /v3/billOfLading/palletize   [BillOfLadingController:316]
            │             → ParcelMonitorViewService.palletiseAndTruckLoad()  [line 232-470]
            │
            └─► Mobile:   REST /mobile/truckLoading/scanGate   [TruckLoadingController:110]
                          → MobileTruckLoadingService.scanGate()     [line 178-325]
            │
            ▼
   Billoflading.state = TRUCK_LOADING              (waterfall from CREATED / OPEN)
   Customerorder.state = LOADED_TO_TRUCK           (via order-level save)
   BOL position tree created: pallet → parcels → stock
            │
            │  post-commit: WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK
            │
            ▼
   REST /v3/billOfLading/closeOutboundBol/{id}   [BillOfLadingController:207]
            │
            ▼  BillofladingService.closeBOL(bolId)            [line 277-699]
            │  (pessimistic row lock + in-memory guard)
            │
            ├─► Billoflading.state = CLOSED    (regular)
            │                    or TRANSFER  (TRANSFER_INTRACOMPANY type)
            ├─► BillofladingPosition.state = CLOSED (or TRANSFER) — BULK JPQL UPDATE
            ├─► Customerorder.state = FINISHED — bulk
            ├─► CustomerorderPosition.state = FINISHED — bulk
            ├─► Unitload storagelocation → SHIPPED, entityLock → SHIPPED (or TRANSFER)
            ├─► Stockunit entityLock → SHIPPED (or TRANSFER)
            ├─► outbox enqueue (same tx): ORDER_BATCH_SHIPPED, 1 row or N chunk rows ⏳ pending-merge(SBDEV-3672) (§6.5)
            └─► CustomerorderBatch.state = FINISHED   (if all child orders FINISHED)
            │
            │  after commit: outbox dispatcher POSTs WEBSERVICE_ORDER_BATCH_SHIPPED
            ▼
   BOL terminal state: CLOSED / TRANSFER

   Sidebar: TRANSFER_INTRACOMPANY type
            │
            ▼  REST /v3/billOfLading/closeIntraCompanyTransfer/{id}   [BillOfLadingController:291]
            │
            └─► BillofladingService.finishTransfer()    [line 898]
                  Billoflading.state = TRANSFER → CLOSED
                  BillofladingPosition → CLOSED (bulk JPQL)
                  Unitloads → SHIPPED location
```

---

## 4. Palletize — Desktop Path

`ParcelMonitorViewService.palletise` at line 103-230 handles the pack → pallet assignment without immediately starting truck load. It:

1. Locates the pallet unit load (creating one if `createPalletBySystem=true`).
2. Finds location `STORAGE_LOCATION_PALLETISING`.
3. For each customer order with `state < PALLETIZED`: sets `state = PALLETIZED`, transfers the parcel unit load onto the pallet carrier with activity code `CODE_PALLETISING`.
4. Registers a post-commit hook → `ManageOrderService.customerOrderPalletized(...)` which fires `WEBSERVICE_ORDER_BATCH_PALLETIZED`.

Guard: `state < PALLETIZED` prevents double-apply (matches the `state == PACKED OR PALLETIZED` check in `CustomerorderService:382` — see `Cancel_Club_Parcels_Packed_State_Fix`).

**Locking — every row's lock is its first touch (SBDEV-3286, 2026-10-08).** The existing pallet is resolved with `findByLabelidForUpdate`, and the orders are read as `(orderId, parcelId)` scalars (`CustomerorderRepository.findParcelOrderIdsByExternalIdList`) before each is locked with `findByIdForUpdate`. Before this, both were read as entities first, so the lock was a version-checked *upgrade* that threw `StaleObjectStateException` (a 409) whenever a concurrent commit touched the row. Lock order is unchanged (pallet → parcels by parcel id → orders by order id, SBDEV-3419). Because each order is now read **fresh** under its lock, its rejections are explicit:
- order `CANCELED` → `BusinessException` *"Order was cancelled: &lt;number&gt;"* (422);
- order `>= FINISHED` → *"Order is already finished"* (422, unchanged);
- order's `parcel_id` changed since the pre-lock read (re-packed meanwhile) → `ObjectOptimisticLockingFailureException` (409, `retryable=true`) — the parcels were chosen and locked from the old value, so it refuses rather than palletising a parcel nobody scanned.

The pallet guards (Pallet type, not already on a carrier, not assigned to a gate) now run on **every** arm, including the two create arms: `UnitloadService.createUnitload(name, …)` is a find-or-create, so a label committed by another session between the miss and the insert comes back as *that* row, which previously skipped every check. `MobilePalletizeWriteService` closed the same hole the same way.

Behaviour change worth knowing for QA: two operators palletising the **same parcel** onto different pallets at the same moment no longer produce a 409 for the second; the second simply re-palletizes it (the serial outcome, permitted since SBDEV-3452).

**SBDEV-2507 guards (added 2026-07-10, v2 port of v1 `9134417`):** two shared helpers in `BillofladingPositionService` close the re-palletize double-ship vectors:
- `assertParcelCarrierNotShipped(parcel)` — called in **both** `palletise` and `palletiseAndTruckLoad` per-parcel loops, after the parcel-own-position handling (`removeBOLPositionIfExists`) and immediately before `transferUnitLoadToCarrier`. Rejects a parcel whose **current carrier pallet** has a `CLOSED` or `TRANSFER` BOL position (the migrated-v1-data shape where only the pallet is the source position; v2-native data creates per-parcel positions and is already caught by the parcel-own guard). Fail-open on null/dangling carrier.
- `assertPalletNotAssignedToGate(label)` — called in `palletise`'s existing-pallet reuse branch (alongside the `carrierunitloadId` guard) and by all 4 `MobilePalletizingService` gate sites (previously 4 inline copies; now single-sourced). Rejects a pallet with **any** BOL position — `"Pallet already assigned to gate!"`, mobile-parity.
Plan: `1-Projects/wms2/plan/SBDEV-2507-web-palletize-already-truckloaded-guard.md`.

`palletiseAndTruckLoad` at line 232-470 does palletize **and** truck-load in one transaction. BOL state rolls `CREATED`/`OPEN → TRUCK_LOADING`. BOL position tree (pallet → parcels → stock) is created inline. Two post-commit callbacks fire: PALLETIZED then LOADED_TO_TRUCK.

---

## 5. Truck Loading — Mobile Path

> **Updated by SBDEV-3418 (2026-09-22).** Before that ticket this method had **zero**
> `@Transactional` and **zero** row locks: it wrote a BOL header, relocated a pallet and inserted a
> three-level position tree with every write committing independently, so any mid-flight failure
> left a partial BOL behind. It is now split in two, following the `MobilePalletizingService` /
> `MobilePalletizeWriteService` precedent from SBDEV-3398.

`MobileTruckLoadingService.scanGate` is the mobile operator's primary action. It is **not**
transactional itself — it delegates to `MobileTruckLoadingWriteService.scanGate`, which carries
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class,
FacadeException.class})` and owns every lock. The outer method keeps exactly three jobs: translating
`PessimisticLockingFailureException` into an operator-legible retry, mapping the DTO, and notifying
OMS *after* the boundary has returned.

The write service runs in five named phases, and the order is load-bearing:

| Phase | What it may do |
|---|---|
| **A** — resolve | Scalar id/existence probes only. Never materialises a row it will later lock (SBDEV-3244 first-touch rule). |
| **B** — lock | `findByIdForUpdate` in the canonical TABLE order SBDEV-3419 measured off `pg_locks`: `Billoflading → Unitload` (pallet, then parcels ascending by id) `→ Stockunit → Customerorder` ascending `→ CustomerorderPosition`. `Stockunit` and `CustomerorderPosition` are read here UNLOCKED, at the right position. |

**SBDEV-3465 measured this path's OWN acquisition order** (2026-09-23,
`MobileTruckLoadingLockOrderProbeIT`, PostgreSQL 14, relation-level locks off `pg_locks`) — until
then the order above was inherited from SBDEV-3419's measurement of `closeBOL` and verified here only
by review:

| blocked at | already holds |
|---|---|
| B1 `billoflading` | `billoflading` — **nothing precedes it** |
| B2 `unitload` | `billoflading`, `unitload` |
| B5 `customerorder` | `billoflading`, `customerorder`, `unitload` |
| PHASE D `location` | `billoflading`, `customerorder`, `location`, `unitload` |

It matches. Three things the table above does not say, all measured: only **three** of those five
tables take a lock at all (`Stockunit` and `CustomerorderPosition` are unlocked reads); **`Location`
is a fourth locked table**, absent from the canonical sentence and sitting **last**, after every
PHASE B acquisition; and the locks render as `FOR NO KEY UPDATE`, which is what Hibernate's
`PESSIMISTIC_WRITE` emits on PostgreSQL. `billoflading_position` and `unitload_record` are also
locked, by DML rather than by a finder, and are unranked.

⚠ This measures **one path's internal order**. It is not a proof that no deadlock cycle exists with
any other path — that needs every path locking two of these tables enumerated, and the probe's own
javadoc records the blind spot.
| **C** — guard | **Predicates only. No mutation.** BOL state waterfall (`CREATED`/`OPEN → TRUCK_LOADING`; `TRANSFER`/`CLOSED`/`CANCELLED` rejected), gate-mismatch, duplicate-order and orphan-parcel. The last two used to fire *mid-write-loop*, after positions had already committed. |
| **D0** — purge | `handleTruckOffLoadingNoClear(palletName)` — ahead of every pending write. A no-clear sibling is used because `@Modifying(clearAutomatically = true)` would detach the entire persistence context inside the boundary. **SBDEV-3487:** throws `billOfLadingPositionUnxepectedStateFound` (naming the BOL) when the pallet has a **CLOSED** position — the backstop; the facade `MobileTruckLoadingService.scanGate` rejects the same case before B1, but that pre-lock read races `closeBOL`, so this post-B2 check is the real guarantee. The purge statements also carry `bp.state IS NULL OR bp.state <> 'CLOSED'`, with a re-check when the pallet-row delete hits 0 rows. `TRANSFER` positions are still purged. |
| **D** — write | Apply the pending gate/state and save the header; relocate the pallet via `transferUnitLoadToLocation(pallet, gate, false, CODE_TRUCK_LOADING, bolNumber, null)`; build the pallet → parcels → stock-units position tree at `state = TRUCK_LOADING`; set each customer order to `LOADED_TO_TRUCK` where `state <` it. |

`ManageOrderService.customerOrderLoadedToTruck(...)` → `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK`
fires from the **outer** method once the boundary has committed. It is a direct call, not a
`registerSynchronization`: `sendAfterCommit` already defers internally, so an outer registration
would be a double deferral whose inner half is discarded unseen (SBDEV-3267). A notification failure
is logged, not propagated — the stock has already moved.

⚠ This does not close every deadlock cycle. `billoflading_position` is unrankable from source, the
`unitload`-vs-`unitload` cycle against `closeBOL` is untouched, and `Location` is unranked; all
abort as `40P01` → a retry prompt. See `MobileTruckLoadingWriteService`'s class javadoc, which
carries the full residual list including the unlocked-read isolation gap and the measured fan-out (max 28 B3+B5 acquisitions on Hydra prd today, SBDEV-3470. That is a
property of the data, not a bound: B3 locks every child before PHASE C rejects an order-less pallet.
An earlier "~142" figure counted inbound pallets and was wrong).

**Pallet-label check (SBDEV-3474).** `scanGate` now rejects a pallet label that matches neither
outbound pattern (`STRING_PATTERN_OUTBOUND_PALLET`, `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL`) with
`noValidString`, before any transaction or row lock. The check is `OutboundPalletLabelGuard`, shared
with `scanPallet`'s `checkPallet`. Before it, only `scanPallet` checked, so a direct `scanGate` call
on an inbound pallet row-locked the BOL, the pallet and every child before rejecting it (336 rows
measured on dev). With neither pattern configured the check rejects (fails closed). It does not
bound the fan-out for an outbound-labelled pallet whose children carry no orders.

Related mobile endpoints:

| Endpoint | Method | File:Line | Purpose |
|---|---|---|---|
| `/mobile/truckLoading/orderList` | GET | `TruckLoadingController:46` | Pending orders for truck loading |
| `/mobile/truckLoading/truckLoadingInfo/{bolName}` | GET | `TruckLoadingController:60` | BOL manifest locations |
| `/mobile/truckLoading/loadOrder` | POST | `TruckLoadingController:67` | Lookup BOL, fetch gate/truck/courier |
| `/mobile/truckLoading/scanPallet` | POST | `TruckLoadingController:89` | Validate pallet label + state |
| `/mobile/truckLoading/scanGate` | POST | `TruckLoadingController:110` | **Main** — loads pallet, BOL state → TRUCK_LOADING |

Open TODOs in the code (worth noting):

- `loadOrder:104` — "TODO check BOL state"
- `loadOrder:104` — "TODO check order state"
- `scanGate:213` — "TODO check that gate is a correct location"
- `scanGate:225` — "TODO should not be allowed" (re: CREATED state in truck loading)

---

## 6. Close BOL — `BillofladingService.closeBOL`

The most complex method in the shipping path. The single-arg overload (`closeBOL(Billoflading)`) is at `BillofladingService.java:273`; the long-form `closeBOL(Long bolId)` runs from line 278 through ~699.

### 6.1 Concurrency guards

```java
// In-memory set — atomic contains-and-add
if (!bolToClose.add(bolId)) {
    throw new BusinessException("BOL is currently in process.");
}

// DB-level pessimistic lock
Billoflading bol = billofladingRepository.findByIdForUpdate(bolId)
    .orElseThrow(() -> new BusinessException("BOL not found: " + bolId));
```

Both layers exist because `bolToClose` is JVM-local (one replica) and the DB lock crosses replicas. Without both, concurrent closes on different replicas could both pass the add() check on their own JVMs.

### 6.2 State validation

| Source state | Target state | Result |
|---|---|---|
| `CREATED` | — | waterfall to OPEN path |
| `OPEN` | — | waterfall to TRUCK_LOADING path |
| `TRUCK_LOADING` | `CLOSED` / `TRANSFER` | proceed |
| `TRANSFER` | — | reject — "Can not close BOL. BOL is in transfer!" |
| `CLOSED` / `CANCELLED` | — | reject — "Can not close BOL. BOL already closed!" |
| anything else | — | `RuntimeException("unknown state=...")` |

Target state depends on BOL `type`:
- `type == "TRANSFER_INTRACOMPANY"` → `TRANSFER`
- anything else → `CLOSED`

### 6.3 Bulk optimizations

Three ways `closeBOL` avoids N+1 queries (documented inline at lines 345-347, 661-685):

1. **Pre-load positions** — one query loads all positions for the BOL, then an in-memory tree is built. Eliminates per-position carrier-check queries.
2. **Bulk position update** — one JPQL UPDATE sets every BillofladingPosition to the target state. Replaces N saves.
3. **Bulk order finalization** — two JPQL queries finalize all Customerorder + CustomerorderPosition rows on the BOL. Replaces ~2N-3N queries.

### 6.4 Entity-lock writes

At `closeBOL:596-611`:

```
UPDATE Unitload u SET u.storagelocationId = :shippedLocationId, u.entityLock = :lock
UPDATE Stockunit  s SET s.entityLock = :lock
```

Entity lock value:
- `BusinessObjectLockState.SHIPPED` for CLOSED path
- `BusinessObjectLockState.TRANSFER` for TRANSFER path

Stock under shipped unit loads is locked from further edits until the receiving end (other warehouse) acknowledges.

**Pending-reversal visibility (SBDEV-3547 PR-A).** The Stockunit bulk UPDATE overwrites whatever lock the pallets' children held, including `PICKED_FOR_GOODSOUT` on stock still owed to a cancellation reversal. It enters neither move chokepoint, and that is deliberate: refusing a close would strand a loaded truck. So in both `closeBOL` and `finishTransfer`, `reportPendingReversalsOnShippedPallets` runs **immediately before** that UPDATE.
- It calls `CustomerorderCancellationLogRepository.findPendingReversalsOnPallets(palletIds)`. The query matches children of the pallets one level down, which mirrors the UPDATE's WHERE clause. Stock sitting directly on a pallet is matched by neither.
- On a hit it writes a WARN inline ("closing BOL X will ship …"), then registers an **after-commit** Service Log row: sender/receiver `WMS`/`OPS` (the same queue as `PendingReversalReconciliationJob`) and process `PENDING_REVERSAL_SHIPPED`.
- It never refuses. If the Service Log write fails after commit, the failure is logged and swallowed.
- Pinned by `BillofladingServiceUnitTest$Sbdev3547_ShippedPalletPendingReversal` and `PendingReversalsOnPalletsIntegrationTest` (H2).

### 6.5 OMS shipped notification (outbox)

> **⚠ Parked 2026-10-17.** Every passage marked `⏳ pending-merge(SBDEV-3672)` describes code that is parked rather than merged: wms2-api#526 and wms2-web-ui#176 are drafts, deferred to SBDEV-3757 (async finishedShipping), which will replace the chunking, status and requeue described here with its own design. Today's develop sends **one** `ORDER_BATCH_SHIPPED` row per BOL with the 5-attempt budget.

*Rewritten 2026-10-16 (SBDEV-3672 docs lane). The `sendAfterCommit` snippet that stood here had been stale since SBDEV-2221. Citations are against wms2-api `057d0e3b` and wms2-web-ui `63b0a89`.*

`runShippingPhase` (`BillofladingService.java:444`) enqueues the `ORDER_BATCH_SHIPPED` notification as an `outbox_message` row **inside the close transaction** (SBDEV-2221). The outbox dispatcher POSTs it after commit, so a rollback leaves no row. A serialization failure throws `FacadeException` and rolls back the close. An empty BOL (no pallet) skips the notification and counts `wms2.oms.notification.skipped_empty` (SBDEV-2737, `:778-784`). Otherwise `:786` calls `enqueueBolShippedNotification` (`:837`), a helper that exists only on the SBDEV-3672 branch; every line number in this paragraph is at `057d0e3b`, and develop has the skip and enqueue at about `:779-806` ⏳ pending-merge(SBDEV-3672).

#### 6.5.1 Chunking

A REGULAR or HUB_AND_SPOKE BOL with more than K parcels is split into N outbox rows of at most K parcels each, one OMS `finishedShipping` call per row ⏳ pending-merge(SBDEV-3672). OMS costs about 0.19 s per parcel against the 15 s read timeout; a 1,528-parcel BOL never completed.

| Rule | Value | Source |
|---|---|---|
| K | sysprop `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE`, read once per close; seeded `40` by V2.2.40; blank falls back to 40 silently, non-numeric or < 1 falls back with a WARN, > 60 clamps to 60 with a WARN; never throws ⏳ pending-merge(SBDEV-3672) | `BillofladingService.java:844`, `BolShippedNotificationChunker.java:38,46,58` |
| Who is chunked | REGULAR and HUB_AND_SPOKE only, and only when parcels > K. Transfers and BOLs with ≤ K parcels keep the single unchanged `BILL_OF_LADING` row ⏳ pending-merge(SBDEV-3672) | `BillofladingService.java:840,846` |
| Chunk row | aggregate type `BILL_OF_LADING_CHUNK`, aggregate id `bol.id × 100000 + i`, idempotency key `BOL-SHIPPED-<bol.id>-C<i>of<N>` (i 0-based), lane `CLUB`. Each chunk is its own aggregate, so a terminal chunk never holds its siblings. N ≥ 100000 throws ⏳ pending-merge(SBDEV-3672) | `BillofladingService.java:852,885-889`; `WmsConstants.java:1412-1413` |
| Payload | every chunk carries the full header and the same `bol_id`, plus `chunk_index` (0-based) and `chunk_count`. Parcels are cut every K in source order; a pallet that straddles a cut is copied into each chunk with the same `pallet_label`. An unchunked payload carries neither key ⏳ pending-merge(SBDEV-3672) | `BolShippedNotificationChunker.java:99`; `BillOfLadingWebServiceDto.java:46,49` |
| Retry budget | every `ORDER_BATCH_SHIPPED` row, single or chunk, gets 29 attempts (≈24 h at the 1 h backoff cap) instead of 5. 400/404/422 stay terminal at once ⏳ pending-merge(SBDEV-3672) | `OutboxDispatchService.java:107,333-342` |

#### 6.5.2 BOL detail: "OMS notification" row

`GET /v3/billOfLading/omsNotificationStatus/{id}` (`BillOfLadingController.java:616-621`, gate `WEB_UI_VIEW_BILL_OF_LADING`) returns the per-BOL delivery status; an unknown BOL is 404 ⏳ pending-merge(SBDEV-3672). The service reads both row shapes through one native query fenced on `process_type='ORDER_BATCH_SHIPPED'` (`OutboxMessageRepository.java:109-120`, called at `BolOmsNotificationService.java:131`) ⏳ pending-merge(SBDEV-3672). "Confirmed" means OMS answered HTTP 2xx; a 2xx whose body OMS rejected is SBDEV-2736's concern ⏳ pending-merge(SBDEV-3672).

| `state` | When ⏳ pending-merge(SBDEV-3672) |
|---|---|
| `NOT_SHIPPED` | BOL is neither `CLOSED` nor `TRANSFER`. The UI hides the row |
| `FAILED` | any row `FAILED_TERMINAL` and not reconciled by a resend. Wins over the other two |
| `PENDING` | any row `PENDING`, `IN_FLIGHT` or `FAILED_RETRY` |
| `CONFIRMED` | neither of the above |
| `NO_RECORD` | shipped, but no outbox row exists. `noRecordReason` says why (below) |

`confirmed = chunkCount − pending − failed`, so SENT rows already purged by retention count as delivered, since rows leave the table only as SENT (`BolOmsNotificationService.java:161-162`) ⏳ pending-merge(SBDEV-3672).

| `noRecordReason` | When ⏳ pending-merge(SBDEV-3672) | UI text |
|---|---|---|
| `EMPTY_BOL` | the BOL has no top-level pallet, so the close skipped the notification (same classification as `runShippingPhase`, `BillofladingPositionRepository.existsTopLevelPallet`) | "None sent: empty BOL, no pallets to notify" |
| `PURGED` | shipped more than retention + 1 days ago (`app.outbox.dispatcher.retention-days`, default 7). The extra day covers a last send up to ~24 h after the ship date | "Record purged (outbox retention N days)" |
| `UNKNOWN` | anything else, including the boundary day | "No record found (unknown)" |

(`BolOmsNotificationService.java:246-255`.) The UI (`outboundBolDetails.vue:81`, summary `:229`) shows `confirmed/chunkCount delivered · P pending · F failed`, a "delivered via manual resend" caption when `resendConfirmed > 0`, and one line per failed row (chunk index, attempts, `lastError`) ⏳ pending-merge(SBDEV-3672). `lastError` has every URL replaced by `<oms-url>`, then every remaining occurrence of the OMS host (case-insensitive) by `<oms-host>`, and is cut to 300 characters (`BolOmsNotificationService.java:289`). The host is taken from the **current** `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop, so a bare host from an endpoint configured earlier is not caught ⏳ pending-merge(SBDEV-3672). The unredacted text stays in the Service Log ⏳ pending-merge(SBDEV-3672). The line links to the Service Log entry (`/admin?messageId=…`) only when the viewer has `WEB_UI_VIEW_MESSAGES` and the linked message still exists (`:102`, with `canViewMessages` at `:226`) ⏳ pending-merge(SBDEV-3672). The link is the native column `outbox_message.last_message_id`, written by the dispatcher after each attempt on an `ORDER_BATCH_SHIPPED` row (`OutboxDispatchService.java:317-331`) ⏳ pending-merge(SBDEV-3672).

#### 6.5.3 Requeue

`POST /v3/billOfLading/requeueOmsNotification/{id}` (`BillOfLadingController.java:628-642`), behind the "Requeue failed OMS notification" button (`outboundBolDetails.vue:118`) that the UI shows when `failed > 0` (`:109`) ⏳ pending-merge(SBDEV-3672).

- **Who.** Anyone holding `WEB_UI_VIEW_BILL_OF_LADING`, the screen's own function, which already gates `closeOutboundBol`, the action that emitted the notification ⏳ pending-merge(SBDEV-3672).
- **What it does.** One transaction (`BolOmsNotificationService.java:176-237`) ⏳ pending-merge(SBDEV-3672). It reads the BOL's rows, takes the `FAILED_TERMINAL` rows not reconciled by a resend, and runs one guarded UPDATE: `FAILED_TERMINAL → FAILED_RETRY`, `attempts = 0`, due now, `destination_url` = the **current** `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop ⏳ pending-merge(SBDEV-3672). Idempotency keys are untouched, and a legacy single row is sent whole, never re-chunked (`OutboxMessageRepository.java:175-188`) ⏳ pending-merge(SBDEV-3672). Nothing eligible returns 200 `{requeued: 0, mode: NONE, reason}`, with reason `"in flight, nothing to requeue"` or `"nothing failed"` ⏳ pending-merge(SBDEV-3672). The loser of a double click also gets `NONE` ⏳ pending-merge(SBDEV-3672). A blank shipped-URL sysprop is a `BusinessException` ⏳ pending-merge(SBDEV-3672).
- **409.** The UPDATE locks only rows still `FAILED_TERMINAL`, which the dispatcher never claims ⏳ pending-merge(SBDEV-3672). A second requeue blocks on the first's row locks; if it waits out the 3 s tenant `lock_timeout`, the controller maps `PessimisticLockingFailureException` to a 409 ProblemDetail ("Requeue In Progress", `retryable: true`) outside the service transaction ⏳ pending-merge(SBDEV-3672). The UI shows "Another requeue is in progress — refresh and retry" with no toast (`outboundBolDetails.vue:296`) ⏳ pending-merge(SBDEV-3672).
- **Audit row.** A successful requeue writes one Service Log row in the **same** transaction (`MessageService.createServiceLogInCallerTx`, `MANDATORY`): process `ORDER_BATCH_SHIPPED_REQUEUE`, destination `'N/A'`, code `REQUEUE`, sender `wms:requeue`, answer `{bolId, outboxIds, mode, user}` (`BolOmsNotificationService.java:62-69,219`) ⏳ pending-merge(SBDEV-3672). `'N/A'` is the egress watchdog's exclusion literal, so the row is never graded as a failed egress ⏳ pending-merge(SBDEV-3672). The sender is not the WMS instance name, so Service Log refuses to "Resend" it ⏳ pending-merge(SBDEV-3672). INFO log `requeue bolId=… user=… mode=… rows=…` and counter `wms2.outbox.requeued{aggregate_type, mode}` (+1 per call) fire **after commit** (`:231-234`); `NONE` and 409 count nothing ⏳ pending-merge(SBDEV-3672).

#### 6.5.4 Accepted reconciliation gaps (plan R-9)

A FAILED_TERMINAL row counts as delivered (`resendConfirmed`) when a Service Log resend **of its latest linked message** (`redeliver_id = last_message_id`) answered 2xx (`OutboxMessageRepository.java:138-142`) ⏳ pending-merge(SBDEV-3672). Two gaps are accepted, and the UI tooltip states them (`outboundBolDetails.vue:197`) ⏳ pending-merge(SBDEV-3672):

1. A Service Log resend of an **earlier** attempt's message is not reconciled ⏳ pending-merge(SBDEV-3672). Only one hop, from `last_message_id`, is followed ⏳ pending-merge(SBDEV-3672).
2. If the final attempt's link write failed (`wms2.outbox.service_log_link.failed{process_type}`), `last_message_id` still names the previous attempt, so a resend of the truly latest message is not reconciled either ⏳ pending-merge(SBDEV-3672).

Both leave the row reading `failed`, the conservative direction; the operator can requeue (OMS NOOPs parcels already shipped) ⏳ pending-merge(SBDEV-3672). A manual SQL DELETE of a terminal row reads as confirmed; this is documented, not defended ⏳ pending-merge(SBDEV-3672).

#### 6.5.5 Known limitation: legacy oversized row

A single `BILL_OF_LADING` row written **before** the deploy, on a REGULAR or HUB_AND_SPOKE BOL with more than 60 parcels (`CHUNK_SIZE_CEILING`, not today's K) and not yet SENT, is not re-chunked ⏳ pending-merge(SBDEV-3672). The screen labels it "1 legacy notification (N parcels)" (`BolOmsNotificationService.java:319`), and a requeue sends it whole, so it times out again for ~24 h ⏳ pending-merge(SBDEV-3672). **Do not requeue it.** ⏳ pending-merge(SBDEV-3672) Use the manual recipe in [SBDEV-3672 plan §7, "Known limitation: legacy oversized row"](../../1-Projects/wms2/plan/SBDEV-3672-chunk-bol-shipped-notification.md) ⏳ pending-merge(SBDEV-3672).

---

## 7. OMS Callbacks

| Callback | Fired from | Sysprop URL key |
|---|---|---|
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `ManageOrderService.customerOrderPalletized` (line 413) | `…PALLETIZED_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `ManageOrderService.customerOrderLoadedToTruck` (line 474) | `…LOADED_TO_TRUCK_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.runShippingPhase` → outbox enqueue at `:786`, inside the close tx (§6.5); 1 row, or N chunk rows ⏳ pending-merge(SBDEV-3672) | `…SHIPPED_URL_KEY` |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `AdviceService` (line 251) | `…ACCEPT_HUB_AND_SPOKE_URL_KEY` |

All use `TransactionSynchronizationManager.registerSynchronization(...)` or the `omsNotificationService.sendAfterCommit(...)` wrapper — post-commit only. Exception: `…SHIPPED` goes through the transactional outbox (§6.5).

---

## 8. Transfer Flow (TRANSFER_INTRACOMPANY)

BOLs of type `TRANSFER_INTRACOMPANY` go through a two-step close instead of one:

1. `closeBOL(bolId)` — BOL state `TRUCK_LOADING → TRANSFER`. Positions move to TRANSFER state. Unit loads go to SHIPPED location with `entityLock = TRANSFER`.
2. Receiving warehouse accepts: `finishTransfer(transferId)` at `BillofladingService.java:898` — BOL state `TRANSFER → CLOSED`. Positions to CLOSED via JPQL. Unit loads transferred to the receiving WH's storage area.

Why two steps? TRANSFER marks "in flight between warehouses" — neither side has operational access to the stock, which is why the `entityLock` is set. Normal shipments skip this and go straight to CLOSED.

---

## 9. REST Endpoints — Desktop

| Endpoint | Method | Line | Purpose |
|---|---|---|---|
| `POST /v3/billOfLading/create` | POST | 69 | Create BOL (state = OPEN) |
| `GET /v3/billOfLading/nameExists/{name}` | GET | 108 | Name uniqueness check |
| `POST /v3/billOfLading/setTrackingDeviceID` | POST | 119 | Set tracking device (guarded: rejects TRANSFER/CLOSED/CANCELLED) |
| `POST /v3/billOfLading/setDestinationFacility` | POST | 179 | Set destination |
| `GET /v3/billOfLading/closeOutboundBol/{id}` | GET | 207 | Single close → `closeBOL` |
| `POST /v3/billOfLading/closeOutboundBols` | POST | 233 | Batch close |
| `POST /v3/billOfLading/exportOutboundBol` | POST | 276 | Export **one or many** BOLs as an xlsx / HTTP response. Accepts `{ids:[…]}` **or** the legacy scalar `{id:N}`; N ≥ 2 yields a leading `Summary` index tab plus one sheet per BOL, N == 1 delegates to the single-BOL path with no Summary tab. Sheets are named by BOL number on **both** paths (SBDEV-2797 retired the `"Inbound BOL"` literal, which was a mislabel on an outbound export). Errors are now real **422 / 404 / 500 with a JSON body** — previously HTTP 200 carrying `errors.toString()`. Caps: 100 BOLs, 250,000 total SKU rows. Position-less BOLs still export an **empty** sheet by design (see `a8af84f`, and the 2026-08-03 row below) |
| `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` | GET | 291 | Finish transfer → `finishTransfer` |
| `POST /v3/billOfLading/palletize` | POST | 316 | Palletize orders → `palletise` / `palletiseAndTruckLoad` |
| `GET /v3/billOfLading/openBol` | GET | 355 | List open BOLs |
| `GET /v3/billOfLading/closedBol` | GET | 381 | List closed BOLs |
| `GET /v3/billOfLading/bolDetailsById/{id}` | GET | 405 | BOL details |
| `GET /v3/billOfLading/omsNotificationStatus/{id}` | GET | 617 | Per-BOL OMS delivery status of the shipped notification (§6.5.2) ⏳ pending-merge(SBDEV-3672) |
| `POST /v3/billOfLading/requeueOmsNotification/{id}` | POST | 629 | Requeue the BOL's failed shipped-notification rows; 409 on lock timeout (§6.5.3) ⏳ pending-merge(SBDEV-3672) |

---

## 10. Transaction Boundaries

- `palletise`, `palletiseAndTruckLoad`, `scanGate`, `closeBOL`, `finishTransfer`: all `@Transactional(value="tenantTransactionManager", rollbackFor=Exception.class)`. One atomic unit per call.
- **Pessimistic lock on BOL row** during close — `findByIdForUpdate` (see [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8.2).
- **Bulk JPQL updates inside `closeBOL`** avoid the N+1 that plagued earlier implementations — see `CLOSE_BOL_FURTHER_IMPROVEMENTS` archive.
- Post-commit hooks for label printing, OMS callbacks.

---

## 11. Known Landmines

1. **String state — `CANCELLED` with two L's.** BOL uses `BillOfLadingState.CANCELLED`, not `State.CANCELED`. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §9.
2. **`closeBOL` is long and bulk-heavy.** The 3 bulk optimizations at §6.3 are correctness-critical. Refactoring any of them back to save-per-row reintroduces the performance cliff documented in `CLOSE_BOL_FURTHER_IMPROVEMENTS`.
3. **Dual concurrency guard (in-memory `bolToClose` + DB pessimistic lock)**. The in-memory set only protects against double-submit on the same JVM; the DB lock crosses replicas. Remove either and you have a race.
4. **TRANSFER vs CLOSED branching lives in `closeBOL`.** The target state depends on BOL `type` field, checked twice (state + entity lock). A third path added for a new BOL type needs both checks updated.
5. **Mobile `scanGate` has open TODOs** (§5). BOL-state + gate-location validation are marked incomplete. An operator scanning the wrong gate does not error at the API level today.
6. **BOL positions created with `state = TRUCK_LOADING`** (hardcoded in `BillofladingPositionService.createEntity:44`). Subsequent transitions via bulk JPQL. Don't override at creation time.
7. **Entity locks on Unitload + Stockunit during TRANSFER** prevent intra-facility moves of in-flight stock. Clearing these locks manually (e.g. via SQL) during a stuck transfer is the wrong fix — invoke `finishTransfer` with the right transferId.
8. **Palletize guard `state < PALLETIZED`**. Only advances; never regresses. Force-paths in cancel (`forceCancelOrder`) bypass this. A custom admin flow that tries to "un-palletize" must also clear the pallet unit load linkage, or state and physical reality diverge.
9. **Palletize's post-commit hook must capture the order list + pallet *before* commit.** The closure variable `capturedOrders` / `capturedPallet` in `palletise` is there for a reason — reading these from the EMF after commit can return stale state under OSIV-disabled config.
10. **~~`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` default is `false`~~ — WITHDRAWN 2026-09-15 (SBDEV-3332).** ⚠ **This sysprop gates NOTHING in v2** (verified 2026-09-15, SBDEV-3332): `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED_KEY` has exactly two references in `src/main` — its own declaration in `WmsConstants` and a **commented-out** seed line in `UtilRestController` — so no code reads it. v2 enqueues `ORDER_BATCH_CANCELLED_FROM_WMS` **unconditionally**. Cancels are NOT silent by default, and flipping this to `true` changes nothing. (v1 does read it; do not carry the v1 behaviour across.)

---

## 12. How to debug

| Symptom | Start here |
|---|---|
| "BOL stuck in TRUCK_LOADING, close rejects" | §6.2 state guards + confirm `bolToClose` set isn't poisoned (JVM restart clears) |
| "Concurrent close on two replicas produced partial state" | §6.1 dual guard — check that DB pessimistic lock actually fired (DB-side pg_stat_activity during the window) |
| "OMS didn't get SHIPPED callback" | §7 + `message` / `message_archived` tables + check for rollback between state write and commit |
| "BOL detail says OMS notification failed" | §6.5.2–6.5.5: the failed-row line's `lastError` and Service Log link; Requeue once OMS is reachable; a "legacy notification" label means the manual recipe, not Requeue ⏳ pending-merge(SBDEV-3672) |
| "Intracompany transfer stuck in TRANSFER" | §8 — `finishTransfer` wasn't invoked on the receiving side |
| "Performance regression during close" | §6.3 — verify bulk JPQL paths still active |
| "Mobile operator scanned wrong gate — no error" | §5 open TODOs |
| "Order shipped but batch still ORDER_BATCH_CLUB_RUN_FINISHED" | §6.3 — batch rollup is part of close; absence means close didn't commit |

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `BillofladingService` (closeBOL, finishTransfer, createEntity, setTrackingDeviceID, transferOrder); `ParcelMonitorViewService.palletise` + `palletiseAndTruckLoad`; `MobileTruckLoadingService.scanGate`; `BillofladingPositionService`; all REST + mobile endpoints; OMS callback wiring | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | Group B (BOL/palletize) ports verified live: v1 `98fce54` → v2 `cd73716` (new BOL no shipped date — confirmed via commit log); v1 `8957b9a` → v2 `a8af84f` (empty BOL export no SKU rows); v1 `83dddd8` palletize filter → v2 `ReportController` palletize filter routes via `/parcelMonitorView` GET (line 366) + ViewDtoService at the cited 1334-1338 region. `closeBOL` Phase 8 (Customerorder + Position FINISHED bulk) writes at lines 481 / 524; Phase 9 (post-commit OMS callback registration) per §6.5 — both confirmed. `finishTransfer` declaration shifted from cited 898 → actual line 899 (within tolerance, not edited). `BillOfLadingController` REST endpoint table re-confirmed against current source. | All claims still accurate; closeBOL header range expanded to reflect 273/278 method overloads. | Code read (grep-based) |
| 2026-05-19 | SBDEV-2232: `ParcelMonitorViewService.palletise` pessimistic-lock refactor shifted `palletiseAndTruckLoad` start from 210 → 232 (end of file: 470). `palletise` body end shifted from 207 → 230. Updated §3 diagram, §4 narrative, §4 `palletiseAndTruckLoad` line refs. Narrative and transaction shape unchanged — only `SELECT FOR UPDATE` guard added at top of `palletise`. | Line refs confirmed by grep against `src/main/java` | Code read (grep-based) |
| 2026-10-16 | SBDEV-3672: §6.5 rewritten (chunking, status row, requeue, R-9 gaps, legacy row); §1, §3, §7, §9, §12 touched. Code read at wms2-api `1866ab66` (`BillofladingService`, `BolShippedNotificationChunker`, `BolOmsNotificationService`, `BillOfLadingController`, `OutboxMessageRepository`, `OutboxDispatchService`) and wms2-web-ui `63b0a89` (`outboundBolDetails.vue`). Re-cited at `057d0e3b` (round 2: `BolOmsNotificationService` lines moved; `lastError` redaction now also masks the bare OMS host). Also corrected the stale `sendAfterCommit` snippet and the §7 `closeBOL` line-653 cite (outbox since SBDEV-2221). | New behaviour marked ⏳ pending-merge(SBDEV-3672); other sections not re-verified | SBDEV-3672 docs lane |

**Re-verify every 90 days.** Next due: **2026-08-06** — close BOL is stable but mobile truck-loading open TODOs invite future change.
