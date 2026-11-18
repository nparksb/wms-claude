---
title: "WMS v2 — BOL / Truck Loading / Shipping Workflow"
type: workflow
status: active
version: v2
scope: bol-truck-loading
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: "Full-doc re-verification 2026-11-11 against wms2-api origin/develop df30fa62 (detached worktree), §1-§12 re-read from src/main, with git log --since=2026-09-24 on BillofladingService (36 commits). Prior scoped checks, kept verbatim for provenance: SBDEV-4072 phase-B JOINING sentence and phase-D row's re-check only (2026-11-08, code read in the SBDEV-4072 worktree); earlier: SBDEV-4047 phase-B row's JOINING sentence only (2026-11-07, code read in the SBDEV-4047 worktree; rest NOT re-verified); earlier: SBDEV-3441 phase-B table row only (2026-11-06, code read in the SBDEV-3441 worktree @ 30261f92; rest NOT re-verified); earlier: SBDEV-3440 §6.4 row-lock paragraph and the truck-loading residual sentence only (2026-10-28, code read in the SBDEV-3440 worktree; rest NOT re-verified); earlier: SBDEV-3672 docs lane — §1 shipped bullet, §3 diagram enqueue line, §6.5 (rewritten), §7 SHIPPED row, §9 two new rows, §12 one new row only (2026-10-16, code read at wms2-api 1866ab66, re-cited at 057d0e3b, and wms2-web-ui 63b0a89; rest of doc NOT re-verified); earlier: SBDEV-3547 §6.4 pending-reversal paragraph only (2026-09-28, code read in the SBDEV-3547-a worktree); earlier: SBDEV-3487 D0-row only (2026-09-24, code read in the SBDEV-3487 worktree — scoped check, rest of doc NOT re-verified); earlier: SBDEV-2797 API half (bulk BOL export; §'REST endpoints' export row rewritten — endpoint moved 265→276 and its request/response contract changed; empty-export behaviour re-confirmed as deliberate per a8af84f)"
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

The BOL (Bill of Lading) flow is how picked+packed orders leave the warehouse. It spans a desktop palletize path (`ParcelMonitorViewService.palletise`) and a mobile truck-loading path (`MobileTruckLoadingService` → `MobileTruckLoadingWriteService`) that converge on the same `Billoflading` state machine. ⚠ Corrected 2026-11-11: the desktop path no longer loads a truck — `palletiseAndTruckLoad` was deleted by SBDEV-2620 (`fd87a502`, 2026-09-17; it never had a production caller), so only mobile `scanGate` moves a BOL to `TRUCK_LOADING`. Closing the BOL (`BillofladingService.closeBOL`) is the single most expensive state transition in the codebase — it:

- Acquires a pessimistic lock on the BOL row + an in-memory, tenant-qualified `bolToClose` set (double-guard against concurrent closes, §6.1).
- Saves all `BillofladingPosition` rows with one batched `saveAll` (`BillofladingService.java:667`); only `finishTransfer`'s final close uses a JPQL bulk UPDATE for positions (`:1700`). Corrected 2026-11-11: this bullet and §6.3 used to say "via JPQL" for `closeBOL`.
- Finalizes all `Customerorder` + `CustomerorderPosition` rows in the BOL to `FINISHED` with batched `saveAll`, plus one JPQL UPDATE that forces any remaining position of those orders to `FINISHED` (`:746`).
- Bulk-transfers every `Unitload` on the BOL (pallets and their children) to the SHIPPED location + sets entity locks, after locking pallets then children in id order (§6.4).
- Enqueues the `ORDER_BATCH_SHIPPED` OMS notification as an outbox row inside the close transaction; the outbox dispatcher POSTs it after commit (§6.5). A REGULAR or HUB_AND_SPOKE BOL with more than K parcels becomes N chunk rows ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

BOL state machine (String — two-L `CANCELLED`):

```
CREATED → OPEN → TRUCK_LOADING → CLOSED
                               └─► TRANSFER   (for TRANSFER_INTRACOMPANY type only)
          └────► CANCELLED
TRANSFER → CLOSED via finishTransfer (§8); finishTransfer also accepts a BOL still below TRANSFER (§8)
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

BOL state constants live at `service/WmsConstants.java:271-281` (was `:244-253`). See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §4.9 for the full state map and §9 for the two-L spelling gotcha.

---

## 3. Lifecycle

```
Customerorder.state = PALLETIZED
 (set by ParcelMonitorViewService.palletise   [:76-375; PALLETIZED write :327]
   or   MobilePalletizeWriteService.scanPallet / scanParcelBulk   [:221 / :523; PALLETIZED write :663-664],
        reached via MobilePalletizingService.scanPallet :136 / scanParcelBulk :158;
        there is no `palletizeOrder` method)
            │
            │  REST /v3/billOfLading/create    [BillOfLadingController:93]
            ▼
   Billoflading.state = OPEN                       [BillofladingService.createEntity:301]
            │
            │  Loading a truck is MOBILE-ONLY. (Desktop REST /v3/billOfLading/palletize
            │  [BillOfLadingController:536] → ParcelMonitorViewService.palletise() palletizes but does NOT
            │  load: palletiseAndTruckLoad was deleted by SBDEV-2620, 2026-09-17.)
            │
            └─► Mobile:   REST POST /v3/truckLoading/scanGate   [TruckLoadingController:112]
                          → MobileTruckLoadingService.scanGate()          [:172, non-transactional facade]
                          → MobileTruckLoadingWriteService.scanGate()     [:371, @Transactional]
            │
            ▼
   Billoflading.state = TRUCK_LOADING              (waterfall from CREATED / OPEN)
   Customerorder.state = LOADED_TO_TRUCK           (via order-level save)
   BOL position tree created: pallet → parcels → stock
            │
            │  post-commit: WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK
            │
            ▼
   REST /v3/billOfLading/closeOutboundBol/{id}   [BillOfLadingController:269]
            │
            ▼  BillofladingService.closeBOL(bolId)            [:358-431; the work is runShippingPhase :450]
            │  (pessimistic row lock + in-memory guard)
            │
            ├─► Billoflading.state = CLOSED    (regular)
            │                    or TRANSFER  (TRANSFER_INTRACOMPANY type)
            ├─► BillofladingPosition.state = CLOSED (or TRANSFER) — batched saveAll
            ├─► Customerorder.state = FINISHED — batched saveAll
            ├─► CustomerorderPosition.state = FINISHED — saveAll + one JPQL UPDATE for the orders' remaining positions
            ├─► Unitload storagelocation → SHIPPED, entityLock → SHIPPED (or TRANSFER)
            ├─► Stockunit entityLock → SHIPPED (or TRANSFER)
            ├─► outbox enqueue (same tx): ORDER_BATCH_SHIPPED, 1 row or N chunk rows ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) (§6.5)
            └─► CustomerorderBatch.state = FINISHED   (if all child orders FINISHED)
            │
            │  after commit: outbox dispatcher POSTs WEBSERVICE_ORDER_BATCH_SHIPPED
            ▼
   BOL terminal state: CLOSED / TRANSFER

   Sidebar: TRANSFER_INTRACOMPANY type
            │
            ▼  REST /v3/billOfLading/closeIntraCompanyTransfer/{transferId}   [BillOfLadingController:504]
            │
            └─► BillofladingService.finishTransfer(String)   [:1585 → private finishTransfer(bol, skipped) :1658]
                  Billoflading.state = TRANSFER → CLOSED   (a BOL below TRANSFER runs runShippingPhase first, §8)
                  BillofladingPosition → CLOSED (bulk JPQL, :1700)
                  Unitloads → SHIPPED location
```

---

## 4. Palletize — Desktop Path

`ParcelMonitorViewService.palletise` (`:76-375`, `@Transactional(tenantTransactionManager, rollbackFor={BusinessException, FacadeException})`) handles the pack → pallet assignment without starting a truck load. It:

1. Locates the pallet unit load (creating one if `createPalletBySystem=true`).
2. Finds location `STORAGE_LOCATION_PALLETISING`.
3. For each customer order with `state < PALLETIZED`: sets `state = PALLETIZED`, transfers the parcel unit load onto the pallet carrier with activity code `CODE_PALLETISING`.
4. Calls `ManageOrderService.customerOrderPalletized(...)` directly (`:368`, inside a `try/catch` that logs and swallows a notification failure); `sendAfterCommit` defers it to after the commit, which fires `WEBSERVICE_ORDER_BATCH_PALLETIZED`. (SBDEV-3267 removed the outer `registerSynchronization`, a double deferral whose inner half was discarded — the old "registers a post-commit hook" wording was wrong from then on.)

Guard: `state < PALLETIZED` (`:326`) prevents double-apply (matches the `state == PACKED OR PALLETIZED` check in `CustomerorderService:555` — see `Cancel_Club_Parcels_Packed_State_Fix`).

**Locking — every row's lock is its first touch (SBDEV-3286, 2026-10-08).** The existing pallet is resolved with `findByLabelidForUpdate`, and the orders are read as `(orderId, parcelId)` scalars (`CustomerorderRepository.findParcelOrderIdsByExternalIdList`) before each is locked with `findByIdForUpdate`. Before this, both were read as entities first, so the lock was a version-checked *upgrade* that threw `StaleObjectStateException` (a 409) whenever a concurrent commit touched the row. Lock order is unchanged (pallet → parcels by parcel id → orders by order id, SBDEV-3419). Because each order is now read **fresh** under its lock, its rejections are explicit:
- order `CANCELED` → `BusinessException` *"Order was cancelled: &lt;number&gt;"* (422);
- order `>= FINISHED` → *"Order is already finished"* (422, unchanged);
- order's `parcel_id` changed since the pre-lock read (re-packed meanwhile) → `ObjectOptimisticLockingFailureException` (409, `retryable=true`) — the parcels were chosen and locked from the old value, so it refuses rather than palletising a parcel nobody scanned.

The pallet guards (Pallet type, not already on a carrier, not assigned to a gate) now run on **every** arm, including the two create arms: `UnitloadService.createUnitload(name, …)` is a find-or-create, so a label committed by another session between the miss and the insert comes back as *that* row, which previously skipped every check. `MobilePalletizeWriteService` closed the same hole the same way.

Behaviour change worth knowing for QA: two operators palletising the **same parcel** onto different pallets at the same moment no longer produce a 409 for the second; the second simply re-palletizes it (the serial outcome, permitted since SBDEV-3452).

**SBDEV-2507 guards (added 2026-07-10, v2 port of v1 `9134417`):** two shared helpers in `BillofladingPositionService` close the re-palletize double-ship vectors (re-anchored 2026-11-11):
- `assertParcelCarrierNotShipped(parcel)` (`BillofladingPositionService:120`) — called in `palletise`'s per-parcel loop (`ParcelMonitorViewService:311`) and in `MobilePalletizeWriteService` (`:381`, `:570`) and `MobileMoveUnitloadService:987`. (It used to be called in `palletiseAndTruckLoad` too; that method is deleted.) In `palletise` it runs before `removeBOLPositionIfExists` (`:342`) and `transferUnitLoadToCarrier` (`:348`). Rejects a parcel whose **current carrier pallet** has a `CLOSED` or `TRANSFER` BOL position (the migrated-v1-data shape where only the pallet is the source position; v2-native data creates per-parcel positions and is already caught by the parcel-own guard). Fail-open on null/dangling carrier.
- `assertPalletNotAssignedToGate(label)` (`BillofladingPositionService:54`) — called in `palletise` (`ParcelMonitorViewService:203`, after the `carrierunitloadId` guard, on every pallet arm), in `MobilePalletizeWriteService` (`:375`, `:497`, `:538` — the former "4 `MobilePalletizingService` gate sites"), `StockunitService:546` and `MobileMoveUnitloadService:588/:653`. Rejects a pallet with **any** BOL position. Since SBDEV-3452 the message names the pallet and the remedy ("Pallet <label> is already assigned to gate (loaded on a truck/BOL)…"), no longer the bare `"Pallet already assigned to gate!"`.
- `assertParcelCarrierNotOnTruck(parcel)` (`:98`, SBDEV-3452) — rejects a parcel whose current pallet is loaded on a truck/BOL; `palletise` calls it at `:324`, right after the shipped guard and before the `PALLETIZED` write.
Plan: `1-Projects/wms2/plan/SBDEV-2507-web-palletize-already-truckloaded-guard.md`.

~~`palletiseAndTruckLoad` at line 232-470 does palletize **and** truck-load in one transaction.~~ **Deleted 2026-09-17 (SBDEV-2620, `fd87a502`).** The method (262 lines) never had a production caller — `git log -S palletiseAndTruckLoad` showed only the initial check-in, and `BillOfLadingController.palletize` calls `palletise` only (`:558`). The TRUCK_LOADING transition, the BOL position tree and the LOADED_TO_TRUCK callback exist only on the mobile `scanGate` path (§5). The §3 diagram, this section and the 2026-05-19 log row described a path that could not run; they were stale from the doc's creation, not just from the deletion.

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
| **B** — lock | `findByIdForUpdate` in the canonical TABLE order SBDEV-3419 measured off `pg_locks`: `Billoflading → Unitload` (pallet, then parcels ascending by id) `→ Stockunit → Customerorder` ascending `→ CustomerorderPosition`. `Stockunit` and `CustomerorderPosition` are read here UNLOCKED, at the right position. **SBDEV-3441:** the parcel ids come from an unlocked scalar, so B3 re-checks each LOCKED parcel's `carrierunitloadId` against the pallet. It refuses with `palletContentChangedDuringScan` (naming the pallet and the parcel; the operator rescans) when a writer that never locks the pallet (web `palletise` onto another pallet, Move Unit Load onto a location) moved the parcel off during the lock wait. A child deleted during the wait is refused the same way under `palletChildGoneDuringScan` (by id, "was removed"). This B3 check covers parcels LEAVING; a parcel JOINING the pallet mid-scan is refused in PHASE D (see the **D** row, SBDEV-4072) and is also fenced writer-side by [SBDEV-4047](https://app.clickup.com/t/868mtu3qj) ✓ merged(SBDEV-4047: #639 0b9704dd, 2026-11-07): the two add-to-pallet writers its §0 grep found (Move Unit Load's CARRIER_WHOLE arm and the manual split onto a pallet) lock the destination pallet (`FOR NO KEY UPDATE`) before judging it, so they wait behind B2 and their gate guard then reads committed positions. `ReceivingService`'s carrier join is a recorded residual; the inbound find-or-create is excluded by label-pattern disjointness, not by this lock. Before this, scanGate wrote that parcel's positions under the wrong pallet and finished its order on close without shipping it. ✓ merged(SBDEV-3441: #636 5ed6f000, 2026-11-06) |

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
| **C** — guard | **Predicates only. No mutation.** BOL state waterfall (`CREATED`/`OPEN → TRUCK_LOADING`; `TRANSFER`/`CLOSED`/`CANCELLED` rejected), gate-mismatch, duplicate-order and orphan-parcel. The last two used to fire *mid-write-loop*, after positions had already committed. **SBDEV-1564 (#568 4531e773; narrowed by ✓ merged(SBDEV-1564: #569 bb3e3580, 2026-10-26), 2026-10-26):** then the transfer rule, `assertTransferRule` — on a `TRANSFER_INTRACOMPANY`/`TRANSFER_OFFSITE` BOL every order's batch must match the BOL's type **and** a non-blank `transferid` equal to `bol.transferId`. A **non-transfer BOL is not checked**: transfers of both kinds ride `REGULAR` BOLs on WineCo PRD (305 intra-company + 325 offsite batches). Batches are read unlocked. `checkPallet` runs the same rule on plain reads as an early, advisory warning at the pallet scan. |
| **D0** — purge | `handleTruckOffLoadingNoClear(palletName)` — ahead of every pending write. A no-clear sibling is used because `@Modifying(clearAutomatically = true)` would detach the entire persistence context inside the boundary. **SBDEV-3487:** throws `billOfLadingPositionUnxepectedStateFound` (naming the BOL) when the pallet has a **CLOSED** position — the backstop; the facade `MobileTruckLoadingService.scanGate` rejects the same case before B1, but that pre-lock read races `closeBOL`, so this post-B2 check is the real guarantee. The purge statements also carry `bp.state IS NULL OR bp.state <> 'CLOSED'`, with a re-check when the pallet-row delete hits 0 rows. `TRANSFER` positions are still purged. |
| **D** — write | Apply the pending gate/state and save the header; relocate the pallet via `transferUnitLoadToLocation(pallet, gate, false, CODE_TRUCK_LOADING, bolNumber, null)` (its `processTransfer` re-reads the pallet's children and moves every one); **SBDEV-4072:** right after that move, re-read the child ids and refuse when they differ from B3's: `palletChildJoinedDuringScan` (naming the pallet and the joined parcel's label, "was added to it") for a parcel that joined after B3, which would otherwise stand at the gate with no position and be shipped by closeBOL with its order stranded; `palletContentChangedDuringScan` if a B3 parcel is missing (unreachable under B3's locks). The refusal rolls the scan back. Residual: a join committed after that re-read is fenced only writer-side (SBDEV-4047) and detected by SBDEV-4068. ✓ merged(SBDEV-4072: #648 7566da19, 2026-11-08); build the pallet → parcels → stock-units position tree at `state = TRUCK_LOADING`; set each customer order to `LOADED_TO_TRUCK` where `state <` it. |

`ManageOrderService.customerOrderLoadedToTruck(...)` → `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK`
fires from the **outer** method once the boundary has committed. It is a direct call, not a
`registerSynchronization`: `sendAfterCommit` already defers internally, so an outer registration
would be a double deferral whose inner half is discarded unseen (SBDEV-3267). A notification failure
is logged, not propagated — the stock has already moved.

⚠ This does not close every deadlock cycle. `billoflading_position` is unrankable from source and
`Location` is unranked; both abort as `40P01` → a retry prompt. (The `unitload`-vs-`unitload` cycle
against `closeBOL`'s ctid-order bulk update is closed by `closeBOL`'s locked pre-pass, pallets then
children by id — ✓ merged(SBDEV-3440: #580 1378aedd, 2026-10-28). Against a close of the same BOL this path never met it:
both lock the BOL row first.) See `MobileTruckLoadingWriteService`'s class javadoc, which
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
| `/v3/truckLoading/orderList` | GET | `TruckLoadingController:48` | Pending orders for truck loading |
| `/v3/truckLoading/truckLoadingInfo/{bolName}` | GET | `TruckLoadingController:62` | BOL manifest locations |
| `/v3/truckLoading/loadOrder` | POST | `TruckLoadingController:69` | Lookup BOL, fetch gate/truck/courier |
| `/v3/truckLoading/scanPallet` | POST | `TruckLoadingController:91` | Validate pallet label + state (`checkPallet`, advisory transfer-rule check) |
| `/v3/truckLoading/scanGate` | POST | `TruckLoadingController:112` | **Main** — loads pallet, BOL state → TRUCK_LOADING |

> ⚠ Corrected 2026-11-11: this table (and the §3 diagram) used `/mobile/truckLoading/*`. The controller is `@RequestMapping("/v3/truckLoading")` (`:30`); `git log -S'/mobile/truckLoading' -- src/main` is empty — that prefix never existed in v2. Line numbers are the `@…Mapping` annotation lines.

Open TODOs in the code (worth noting):

- `MobileTruckLoadingService.loadOrder:75` — "TODO check BOL state"
- `MobileTruckLoadingService.loadOrder:76` — "TODO check order state"
- The two `scanGate` TODOs this list used to carry ("check that gate is a correct location", "should not be allowed" for CREATED) are gone from `src/main`. `scanGate` now checks the scanned gate against the BOL's assigned gate once one exists (`scannedAndRequiredGateDiffer`, `MobileTruckLoadingWriteService` PHASE C) and, on a BOL with no gate yet, assigns the scanned one. ⚠ unverified 2026-11-11: no check was found that the scanned location is a gate-type location (PHASE A only resolves its id by name); CREATED/OPEN are accepted and waterfall to `TRUCK_LOADING`.

---

## 6. Close BOL — `BillofladingService.closeBOL`

The most complex method in the shipping path. The single-arg overload (`closeBOL(Billoflading)`) is at `BillofladingService.java:348`; the long form `closeBOL(Long bolId)` is `:358-431` and now holds only the guards (§6.1-6.2). The shipping work was extracted into `runShippingPhase` (`:450`, SBDEV-3728), which `finishTransfer` also calls for a BOL still below TRANSFER (§8). Both closeBOL overloads are `@Transactional(tenantTransactionManager, rollbackFor = Exception.class)`.

### 6.1 Concurrency guards

```java
// In-memory set — atomic contains-and-add, keyed tenant#bolId (closeGuardKey, :216)
final String guardKey = closeGuardKey(bolId);      // null with no tenant context -> guard skipped, WARN logged
if (guardKey != null && !bolToClose.add(guardKey)) {   // :366
    throw new BusinessException("BOL is currently in process.");
}

// DB-level pessimistic lock
billOfLading = billofladingRepository.findByIdForUpdate(bolId)
    .orElseThrow(() -> new BusinessException("BOL not found: " + bolId));
// ... finally { bolToClose.remove(guardKey); }       // :427
```

Both layers exist because `bolToClose` is JVM-local (one replica) and the DB lock crosses replicas. Without both, concurrent closes on different replicas could both pass the add() check on their own JVMs. `bolToClose` is a `Set<String>` (`:194`), no longer a `Set<Long>`: the key is `TenantKeyBuilder.cacheKey(tenant) + "#" + bolId` because two warehouses are two databases with independent id sequences and must not share a guard entry. With no tenant context the in-JVM guard is skipped (the row lock still applies). Corrected 2026-11-11: this snippet showed the old `bolToClose.add(bolId)` and a bare lock call.

### 6.2 State validation

Re-derived 2026-11-11 (`closeBOL(Long)`, `BillofladingService.java:358-431`); the old table (waterfall rows, "BOL already closed!" rejection) no longer matches the code.

| Source state | Result |
|---|---|
| `CREATED` / `OPEN` / `TRUCK_LOADING` | proceed to the type check, then `runShippingPhase` (there is no waterfall inside `closeBOL`; the `CREATED`/`OPEN → TRUCK_LOADING` waterfall lives in mobile `scanGate`, §5) |
| `TRANSFER` | reject — `BusinessException("Can not close BOL. BOL is in transfer!")` |
| `CLOSED` / `CANCELLED` | **silent no-op return** (`LOG.debug "BOL already closed/cancelled, skipping close"`) — idempotent, not an error |
| anything else | `RuntimeException("unknown state=...")` |

BOL `type` check (same method): `REGULAR`, `TRANSFER_OFFSITE`, `TRANSFER_INTRACOMPANY`, `HUB_AND_SPOKE` proceed; `CLUB` and `PICK_PACK` → `BusinessException("Only regular, hub and spoke, and transfer types are allowed")`; anything else → `RuntimeException("Unknown type=...")`.

Target state depends on BOL `type` (`runShippingPhase:454-461`):
- `type == "TRANSFER_INTRACOMPANY"` → `TRANSFER` (entity lock `TRANSFER`, activity code `CODE_TRANSFER_TRANSFER_IN_SHIPPING`)
- anything else, including `TRANSFER_OFFSITE` → `CLOSED` (entity lock `SHIPPED`, activity code `CODE_SHIPPING`)

### 6.3 Bulk optimizations

Three ways `closeBOL` avoids N+1 queries (documented inline in `runShippingPhase`, `:450-:830`):

1. **Pre-load positions** — one query loads all positions for the BOL, then an in-memory tree is built. Eliminates per-position carrier-check queries.
2. **Batched position save** — every BillofladingPosition is mutated in memory and written with one `saveAll` (`:667`). It is NOT a JPQL UPDATE in `closeBOL`; the only JPQL position UPDATE is `finishTransfer`'s final close (`:1700`). Garbage positions (no operator, carrier, item or source) are removed with one JPQL DELETE first.
3. **Batched order finalization** — Customerorder and CustomerorderPosition rows go through `saveAll` (`:668-669`), then one JPQL UPDATE (`:746`) forces every other position of those orders to `FINISHED`, and one JPQL UPDATE finalizes the batches whose orders are all `FINISHED` (`:818`). Replaces ~2N-3N queries. Corrected 2026-11-11: this item and the old item 2 said "JPQL" for all of it.

### 6.4 Entity-lock writes

In `runShippingPhase` (Unitload UPDATE `:723`, Stockunit UPDATE `:736`):

```
UPDATE Unitload u SET u.storagelocationId = :shippedLocationId, u.entityLock = :lock
UPDATE Stockunit  s SET s.entityLock = :lock
```

Entity lock value:
- `BusinessObjectLockState.SHIPPED` for CLOSED path
- `BusinessObjectLockState.TRANSFER` for TRANSFER path

Stock under shipped unit loads is locked from further edits until the receiving end (other warehouse) acknowledges.

**Unitload row-lock order (SBDEV-3440).** ✓ merged(SBDEV-3440: #580 1378aedd, 2026-10-28) The bulk Unitload UPDATE has no
`ORDER BY` and locks rows in ctid order, which takes a child ahead of its pallet (27.32% of 480,332
WineCo UAT pairs, 23.4% on dev) and deadlocked against palletize, which locks the pallet and then its
parcels. Both bulk-update sites (`runShippingPhase` and the private `finishTransfer`) now first call
`lockPalletsThenChildren` (`:1894`; called at `:541` and `:1683`): every pallet by id, then every child by id, at `FOR NO KEY UPDATE`
(scalar JPQL at `PESSIMISTIC_WRITE`, so FK writes onto a locked pallet still do not wait). In
`runShippingPhase` it runs before the first unitload read and before the customerorder `saveAll`,
so the table order Billoflading → Unitload → Stockunit → Customerorder is unchanged. Pinned row by
row by `ClosebolUnitloadRowOrderIT`.

**Pending-reversal visibility (SBDEV-3547 PR-A).** The Stockunit bulk UPDATE overwrites whatever lock the pallets' children held, including `PICKED_FOR_GOODSOUT` on stock still owed to a cancellation reversal. It enters neither move chokepoint, and that is deliberate: refusing a close would strand a loaded truck. So in both `closeBOL` and `finishTransfer`, `reportPendingReversalsOnShippedPallets` runs **immediately before** that UPDATE.
- It calls `CustomerorderCancellationLogRepository.findPendingReversalsOnPallets(palletIds)`. The query matches children of the pallets one level down, which mirrors the UPDATE's WHERE clause. Stock sitting directly on a pallet is matched by neither.
- On a hit it writes a WARN inline ("closing BOL X will ship …"), then registers an **after-commit** Service Log row: sender/receiver `WMS`/`OPS` (the same queue as `PendingReversalReconciliationJob`) and process `PENDING_REVERSAL_SHIPPED`.
- It never refuses. If the Service Log write fails after commit, the failure is logged and swallowed.
- Pinned by `BillofladingServiceUnitTest$Sbdev3547_ShippedPalletPendingReversal` and `PendingReversalsOnPalletsIntegrationTest` (H2). The method is `:2016`; its calls are at `:732` (`runShippingPhase`) and `:1781` (`finishTransfer`).

**Position-less children (SBDEV-4068, 2026-11-07).** The bulk Unitload UPDATE ships every direct child of a shipped pallet by carrier, but orders are closed and reported to OMS only from BOL positions, so a child with no position of this BOL ships while any order it carries is never closed or reported. `reportChildrenWithoutPosition` (`:1935`) detects this on the same child read the UPDATE then ships (`:678` in `runShippingPhase`, tag `operation=shipping_phase`; `:1722` in `finishTransfer`'s final close, tag `transfer_close`). It writes an after-commit WARN (capped at 20 named children, `CHILD_WITHOUT_POSITION_LOG_LIMIT`) and increments `wms2.bol.child_without_position{operation}` by the number found. **Detect only, by decision (Nam, 2026-11-07): it never throws and changes nothing that ships** — a fault in the detector is caught and the close continues. A `finishTransfer` of a BOL below TRANSFER runs the shipping-phase report and skips the close-phase one, so the same children are not counted twice in one call. Census at write time: WineCo PRD, 2 position-less children (v1 era) against 56,323 with one.

### 6.5 OMS shipped notification (outbox)

> **On PRD since 2026-10-27 (wms2-api v0.0.43).** The 2026-10-17 parking was overtaken: wms2-api#526 (`f85789d4`) and wms2-web-ui#176 (`98accaf9`) merged to develop 2026-10-22 and shipped in release v2.0.161. Verified on WineCo and c1wh PRD 2026-10-28: Flyway 2.2.41, sysprop `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE=40`, and c1wh BOL 122232183 went out as 12 chunk rows, all SENT. ⚠ **Not async-safe:** before SBDEV-3757 turns `X-OMS-Async` on for any tenant, chunking must be skipped for that tenant, or OMS reads each chunk as a revised BOL and each chunk's callback overwrites the last (tracked on SBDEV-3757).

*Rewritten 2026-10-16 (SBDEV-3672 docs lane). The `sendAfterCommit` snippet that stood here had been stale since SBDEV-2221. Citations are against wms2-api `057d0e3b` and wms2-web-ui `63b0a89`.*

`runShippingPhase` (`BillofladingService.java:450`) enqueues the `ORDER_BATCH_SHIPPED` notification as an `outbox_message` row **inside the close transaction** (SBDEV-2221). The outbox dispatcher POSTs it after commit, so a rollback leaves no row. A serialization failure throws `FacadeException` and rolls back the close. An empty BOL (no pallet) skips the notification and counts `wms2.oms.notification.skipped_empty` (SBDEV-2737, `:790-795`). Otherwise `:797` calls `enqueueBolShippedNotification` (`:848`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). Re-anchored 2026-11-11 at `df30fa62`; the `057d0e3b` citations that stood here were branch lines. ⚠ unverified 2026-11-11: the `outboundBolDetails.vue` line cites in §6.5.2-6.5.4 (wms2-web-ui, outside this pass's code of record) were not re-checked.

#### 6.5.1 Chunking

A REGULAR or HUB_AND_SPOKE BOL with more than K parcels is split into N outbox rows of at most K parcels each, one OMS `finishedShipping` call per row ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). OMS costs about 0.19 s per parcel against the 15 s read timeout; a 1,528-parcel BOL never completed.

| Rule | Value | Source |
|---|---|---|
| K | sysprop `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE`, read once per close; seeded `40` by V2.2.40; blank falls back to 40 silently, non-numeric or < 1 falls back with a WARN, > 60 clamps to 60 with a WARN; never throws ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | `BillofladingService.java:855-856`, `BolShippedNotificationChunker.java:38,46,58` |
| Who is chunked | REGULAR and HUB_AND_SPOKE only, and only when parcels > K. Transfers and BOLs with ≤ K parcels keep the single unchanged `BILL_OF_LADING` row ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | `BillofladingService.java:850-851,857` |
| Chunk row | aggregate type `BILL_OF_LADING_CHUNK`, aggregate id `bol.id × 100000 + i`, idempotency key `BOL-SHIPPED-<bol.id>-C<i>of<N>` (i 0-based), lane `CLUB`. Each chunk is its own aggregate, so a terminal chunk never holds its siblings. N ≥ 100000 throws ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | `BillofladingService.java:861-869,893-900`; `WmsConstants.java:1459-1460` |
| Payload | every chunk carries the full header and the same `bol_id`, plus `chunk_index` (0-based) and `chunk_count`. Parcels are cut every K in source order; a pallet that straddles a cut is copied into each chunk with the same `pallet_label`. An unchunked payload carries neither key ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | `BolShippedNotificationChunker.java:99`; `BillOfLadingWebServiceDto.java:46,49` |
| Retry budget | every `ORDER_BATCH_SHIPPED` row, single or chunk, gets 29 attempts (≈24 h at the 1 h backoff cap) instead of 5. 400/404/422 stay terminal at once ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | `OutboxDispatchService.java:107,333-342` |

#### 6.5.2 BOL detail: "OMS notification" row

`GET /v3/billOfLading/omsNotificationStatus/{id}` (`BillOfLadingController.java:638-644`, gate `WEB_UI_VIEW_BILL_OF_LADING`) returns the per-BOL delivery status; an unknown BOL is 404 ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The service reads both row shapes through one native query fenced on `process_type='ORDER_BATCH_SHIPPED'` (`OutboxMessageRepository.java:109-120`, called at `BolOmsNotificationService.java:132`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). "Confirmed" means OMS answered HTTP 2xx; a 2xx whose body OMS rejected is SBDEV-2736's concern ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

| `state` | When ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |
|---|---|
| `NOT_SHIPPED` | BOL is neither `CLOSED` nor `TRANSFER`. The UI hides the row |
| `FAILED` | any row `FAILED_TERMINAL` and not reconciled by a resend. Wins over the other two |
| `PENDING` | any row `PENDING`, `IN_FLIGHT` or `FAILED_RETRY` |
| `CONFIRMED` | neither of the above |
| `NO_RECORD` | shipped, but no outbox row exists. `noRecordReason` says why (below) |

`confirmed = chunkCount − pending − failed`, so SENT rows already purged by retention count as delivered, since rows leave the table only as SENT (`BolOmsNotificationService.java:162-163`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

| `noRecordReason` | When ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | UI text |
|---|---|---|
| `EMPTY_BOL` | the BOL has no top-level pallet, so the close skipped the notification (same classification as `runShippingPhase`, `BillofladingPositionRepository.existsTopLevelPallet`) | "None sent: empty BOL, no pallets to notify" |
| `PURGED` | shipped more than retention + 1 days ago (`app.outbox.dispatcher.retention-days`, default 7). The extra day covers a last send up to ~24 h after the ship date | "Record purged (outbox retention N days)" |
| `UNKNOWN` | anything else, including the boundary day | "No record found (unknown)" |

(`BolOmsNotificationService.java:246-254`.) The UI (`outboundBolDetails.vue:81`, summary `:229`) shows `confirmed/chunkCount delivered · P pending · F failed`, a "delivered via manual resend" caption when `resendConfirmed > 0`, and one line per failed row (chunk index, attempts, `lastError`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). `lastError` has every URL replaced by `<oms-url>`, then every remaining occurrence of the OMS host (case-insensitive) by `<oms-host>`, and is cut to 300 characters (`BolOmsNotificationService.java:297`, `LAST_ERROR_MAX_CHARS` `:74`). The host is taken from the **current** `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop, so a bare host from an endpoint configured earlier is not caught ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The unredacted text stays in the Service Log ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The line links to the Service Log entry (`/admin?messageId=…`) only when the viewer has `WEB_UI_VIEW_MESSAGES` and the linked message still exists (`:102`, with `canViewMessages` at `:226`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The link is the native column `outbox_message.last_message_id`, written by the dispatcher after each attempt on an `ORDER_BATCH_SHIPPED` row (`OutboxDispatchService.java:317-331`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

#### 6.5.3 Requeue

`POST /v3/billOfLading/requeueOmsNotification/{id}` (`BillOfLadingController.java:650-664`), behind the "Requeue failed OMS notification" button (`outboundBolDetails.vue:118`) that the UI shows when `failed > 0` (`:109`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

- **Who.** Anyone holding `WEB_UI_VIEW_BILL_OF_LADING`, the screen's own function, which already gates `closeOutboundBol`, the action that emitted the notification ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).
- **What it does.** One transaction (`BolOmsNotificationService.java:179-237`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). It reads the BOL's rows, takes the `FAILED_TERMINAL` rows not reconciled by a resend, and runs one guarded UPDATE: `FAILED_TERMINAL → FAILED_RETRY`, `attempts = 0`, due now, `destination_url` = the **current** `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). Idempotency keys are untouched, and a legacy single row is sent whole, never re-chunked (`OutboxMessageRepository.java:175-188`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). Nothing eligible returns 200 `{requeued: 0, mode: NONE, reason}`, with reason `"in flight, nothing to requeue"` or `"nothing failed"` ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The loser of a double click also gets `NONE` ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). A blank shipped-URL sysprop is a `BusinessException` ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).
- **409.** The UPDATE locks only rows still `FAILED_TERMINAL`, which the dispatcher never claims ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). A second requeue blocks on the first's row locks; if it waits out the 3 s tenant `lock_timeout`, the controller maps `PessimisticLockingFailureException` to a 409 ProblemDetail ("Requeue In Progress", `retryable: true`) outside the service transaction ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The UI shows "Another requeue is in progress — refresh and retry" with no toast (`outboundBolDetails.vue:296`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).
- **Audit row.** A successful requeue writes one Service Log row in the **same** transaction (`MessageService.createServiceLogInCallerTx`, `MANDATORY`): process `ORDER_BATCH_SHIPPED_REQUEUE`, destination `'N/A'`, code `REQUEUE`, sender `wms:requeue`, answer `{bolId, outboxIds, mode, user}` (`BolOmsNotificationService.java:62-69,219`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). `'N/A'` is the egress watchdog's exclusion literal, so the row is never graded as a failed egress ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The sender is not the WMS instance name, so Service Log refuses to "Resend" it ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). INFO log `requeue bolId=… user=… mode=… rows=…` and counter `wms2.outbox.requeued{aggregate_type, mode}` (+1 per call) fire **after commit** (`:228-235`); `NONE` and 409 count nothing ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

#### 6.5.4 Accepted reconciliation gaps (plan R-9)

A FAILED_TERMINAL row counts as delivered (`resendConfirmed`) when a Service Log resend **of its latest linked message** (`redeliver_id = last_message_id`) answered 2xx (`OutboxMessageRepository.java:138-142`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). Two gaps are accepted, and the UI tooltip states them (`outboundBolDetails.vue:197`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22):

1. A Service Log resend of an **earlier** attempt's message is not reconciled ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). Only one hop, from `last_message_id`, is followed ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).
2. If the final attempt's link write failed (`wms2.outbox.service_log_link.failed{process_type}`), `last_message_id` still names the previous attempt, so a resend of the truly latest message is not reconciled either ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

Both leave the row reading `failed`, the conservative direction; the operator can requeue (OMS NOOPs parcels already shipped) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). A manual SQL DELETE of a terminal row reads as confirmed; this is documented, not defended ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

#### 6.5.5 Known limitation: legacy oversized row

A single `BILL_OF_LADING` row written **before** the deploy, on a REGULAR or HUB_AND_SPOKE BOL with more than 60 parcels (`CHUNK_SIZE_CEILING`, not today's K) and not yet SENT, is not re-chunked ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). The screen labels it "1 legacy notification (N parcels)" (service side `legacyParcels`, `BolOmsNotificationService.java:323`, flag at `:165-167`), and a requeue sends it whole, so it times out again for ~24 h ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22). **Do not requeue it.** ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) Use the manual recipe in [SBDEV-3672 plan §7, "Known limitation: legacy oversized row"](../../1-Projects/wms2/plan/SBDEV-3672-chunk-bol-shipped-notification.md) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22).

---

## 7. OMS Callbacks

| Callback | Fired from | Sysprop URL key |
|---|---|---|
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `ManageOrderService.customerOrderPalletized` (`:311`; `sendAfterCommit` at `:345`) | `…PALLETIZED_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `ManageOrderService.customerOrderLoadedToTruck` (`:350`) | `…LOADED_TO_TRUCK_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_SHIPPED` | `BillofladingService.runShippingPhase` → outbox enqueue at `:797`, inside the close tx (§6.5); 1 row, or N chunk rows ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | `…SHIPPED_URL_KEY` |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `AdviceService` (`:279`) | `…ACCEPT_HUB_AND_SPOKE_URL_KEY` |

PALLETIZED and LOADED_TO_TRUCK use the `omsNotificationService.sendAfterCommit(...)` wrapper (post-commit only; the call sites invoke `customerOrderPalletized` / `customerOrderLoadedToTruck` directly, inside a swallow-and-log `try/catch` — SBDEV-3267 removed the outer `registerSynchronization`). Exception: `…SHIPPED` goes through the transactional outbox (§6.5).

---

## 8. Transfer Flow (TRANSFER_INTRACOMPANY)

BOLs of type `TRANSFER_INTRACOMPANY` go through a two-step close instead of one:

1. `closeBOL(bolId)` — BOL state `TRUCK_LOADING → TRANSFER`. Positions move to TRANSFER state. Unit loads go to SHIPPED location with `entityLock = TRANSFER`.
2. Receiving warehouse accepts: `finishTransfer(String transferId)` (`BillofladingService.java:1585`, `@Transactional(rollbackFor={BusinessException, FacadeException})`) — BOL state `TRANSFER → CLOSED`. Positions to CLOSED via JPQL (`:1700`). Unit loads go to the SHIPPED location (private overload `:1658`, `UPDATE Unitload … storagelocationId = :shippedLocationId` `:1771`).

Re-derived 2026-11-11 — `finishTransfer` is no longer "TRANSFER → CLOSED" only (SBDEV-3286 Phase 3, 3728, 3491):
- Looks the BOL up by `transferId`, then locks it through `LockReads.forUpdate` (a bare `findByIdForUpdate` after the plain read was a version-checked upgrade that threw on a concurrent commit). Refuses any type but `TRANSFER_INTRACOMPANY`.
- `CANCELLED` → `BusinessException` ("… is cancelled; the transfer cannot be finished"); `CLOSED` → logged no-op (idempotent). **Every other state is finished**, including `CREATED`/`OPEN`/`TRUCK_LOADING`: OMS completes an intra-company transfer on the destination's acceptance and calls this endpoint best-effort first, so refusing a BOL the source never moved to TRANSFER would leave WMS holding stock for goods OMS records as arrived.
- A BOL **below TRANSFER** first runs `runShippingPhase` (orders and positions FINISHED, batches finalised, shipped date, `TRANSFER_IN_SHIPPING` audit, `ORDER_BATCH_SHIPPED` to OMS — skipped for an empty BOL), and inherits `closeBOL`'s refusals for a broken tree (SBDEV-3728). It then calls the private close with `shippingPhaseSkipped = false`.
- Lock discipline of the final close (SBDEV-3491, 2026-10-31): pallets, then children, are locked in id order (`lockPalletsThenChildren`, `:1683`) BEFORE the positions are written, and the positions are re-read under those locks. A pallet re-scanned onto another BOL while the close waited is dropped from the close with a WARN (decided 2026-10-31) instead of being shipped while it sits on the open BOL. Accepted residual: for a BOL below TRANSFER, a re-scan during `runShippingPhase`'s lock wait rolls the call back on an optimistic-lock failure; nothing retries it, recovery is a manual call of the admin GET `closeIntraCompanyTransfer`.

Why two steps? TRANSFER marks "in flight between warehouses" — neither side has operational access to the stock, which is why the `entityLock` is set. Normal shipments skip this and go straight to CLOSED.

---

## 9. REST Endpoints — Desktop

| Endpoint | Method | Line (annotation) | Purpose |
|---|---|---|---|
| `POST /v3/billOfLading/create` | POST | 93 | Create BOL (state = OPEN) |
| `GET /v3/billOfLading/nameExists/{name}` | GET | 156 | Name uniqueness check |
| `POST /v3/billOfLading/setTrackingDeviceID` | POST | 171 | Set tracking device (guarded: rejects TRANSFER/CLOSED/CANCELLED) |
| `POST /v3/billOfLading/setDestinationFacility` | POST | 236 | Set destination |
| `GET /v3/billOfLading/closeOutboundBol/{id}` | GET | 269 | Single close → `closeBOL` |
| `POST /v3/billOfLading/closeOutboundBols` | POST | 300 | Batch close |
| `POST /v3/billOfLading/exportOutboundBol` | POST | 339 | Export **one or many** BOLs as an xlsx / HTTP response. Accepts `{ids:[…]}` **or** the legacy scalar `{id:N}`; N ≥ 2 yields a leading `Summary` index tab plus one sheet per BOL, N == 1 delegates to the single-BOL path with no Summary tab. Sheets are named by BOL number on **both** paths (SBDEV-2797 retired the `"Inbound BOL"` literal, which was a mislabel on an outbound export). Errors are now real **422 / 404 / 500 with a JSON body** — previously HTTP 200 carrying `errors.toString()`. Caps: 100 BOLs, 250,000 total SKU rows. Position-less BOLs still export an **empty** sheet by design (see `a8af84f`, and the 2026-08-03 row below) |
| `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` | GET | 504 | Finish transfer → `finishTransfer` |
| `POST /v3/billOfLading/palletize` | POST | 536 | Palletize orders → `ParcelMonitorViewService.palletise` (gate `WEB_UI_VIEW_PARCEL_MONITOR`); `palletiseAndTruckLoad` was deleted 2026-09-17 |
| `GET /v3/billOfLading/openBol` | GET | 592 | List open BOLs |
| `GET /v3/billOfLading/closedBol` | GET | 611 | List closed BOLs |
| `GET /v3/billOfLading/bolDetailsById/{id}` | GET | 628 | BOL details |
| `GET /v3/billOfLading/getDestinations` | GET | 667 | Destination facilities (added to the table 2026-11-11; `getFacilities`, SBDEV-3324 distinguishes non-2xx / unparseable / no response) |
| `GET /v3/billOfLading/omsNotificationStatus/{id}` | GET | 639 | Per-BOL OMS delivery status of the shipped notification (§6.5.2) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |
| `POST /v3/billOfLading/requeueOmsNotification/{id}` | POST | 651 | Requeue the BOL's failed shipped-notification rows; 409 on lock timeout (§6.5.3) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |

---

## 10. Transaction Boundaries

- `closeBOL` (both overloads): `@Transactional(value="tenantTransactionManager", rollbackFor=Exception.class)`. `palletise`, `MobileTruckLoadingWriteService.scanGate` and `finishTransfer(String)`: `rollbackFor={BusinessException.class, FacadeException.class}` (corrected 2026-11-11 — they are not `Exception.class`; a `RuntimeException` still rolls back by default). `palletiseAndTruckLoad` no longer exists. The mobile `MobileTruckLoadingService.scanGate` facade is deliberately NOT transactional (§5). One atomic unit per write call.
- **Pessimistic lock on BOL row** during close — `findByIdForUpdate` (see [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8.2).
- **Bulk JPQL updates inside `closeBOL`** avoid the N+1 that plagued earlier implementations — see `CLOSE_BOL_FURTHER_IMPROVEMENTS` archive.
- Post-commit hooks for label printing, OMS callbacks.

---

## 11. Known Landmines

1. **String state — `CANCELLED` with two L's.** BOL uses `BillOfLadingState.CANCELLED`, not `State.CANCELED`. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §9.
2. **`closeBOL` is long and bulk-heavy.** The 3 bulk optimizations at §6.3 are correctness-critical. Refactoring any of them back to save-per-row reintroduces the performance cliff documented in `CLOSE_BOL_FURTHER_IMPROVEMENTS`.
3. **Dual concurrency guard (in-memory `bolToClose` + DB pessimistic lock)**. The in-memory set only protects against double-submit on the same JVM; the DB lock crosses replicas. Remove either and you have a race.
4. **TRANSFER vs CLOSED branching lives in `closeBOL`.** The target state depends on BOL `type` field, checked three times in `runShippingPhase:454-461` (state, entity lock, activity code). A third path added for a new BOL type needs both checks updated.
5. **Mobile gate validation is partial** (§5; re-derived 2026-11-11 — the `scanGate` TODOs this item cited are gone). A scan is refused (`scannedAndRequiredGateDiffer`) only when the BOL already has a gate and the scan differs; the first scan on a gate-less BOL assigns whatever location it names. ⚠ unverified: whether the scanned location is checked to be a gate-type location. `loadOrder` still has two TODOs (BOL state, order state).
6. **BOL positions created with `state = TRUCK_LOADING`** (hardcoded in `BillofladingPositionService.createEntity:153`). Subsequent transitions via bulk JPQL. Don't override at creation time.
7. **Entity locks on Unitload + Stockunit during TRANSFER** prevent intra-facility moves of in-flight stock. Clearing these locks manually (e.g. via SQL) during a stuck transfer is the wrong fix — invoke `finishTransfer` with the right transferId.
8. **Palletize guard `state < PALLETIZED`**. Only advances; never regresses. Force-paths in cancel (`forceCancelOrder`) bypass this. A custom admin flow that tries to "un-palletize" must also clear the pallet unit load linkage, or state and physical reality diverge.
9. **~~Palletize's post-commit hook must capture the order list + pallet before commit.~~ OBSOLETE (re-derived 2026-11-11).** `palletise` no longer registers a post-commit hook and has no `capturedOrders` / `capturedPallet` variables: it calls `manageOrderService.customerOrderPalletized(customerOrderList, pallet)` directly (`ParcelMonitorViewService:368`) with the locked entities in hand, and `sendAfterCommit` does the deferral (SBDEV-3267). Do NOT re-wrap that call in `registerSynchronization` — that is the double deferral whose inner half Spring discards unseen.
10. **~~`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` default is `false`~~ — WITHDRAWN 2026-09-15 (SBDEV-3332).** ⚠ **This sysprop gates NOTHING in v2** (verified 2026-09-15, SBDEV-3332): `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED_KEY` has exactly two references in `src/main` — its own declaration in `WmsConstants` and a **commented-out** seed line in `UtilRestController` — so no code reads it. v2 enqueues `ORDER_BATCH_CANCELLED_FROM_WMS` **unconditionally**. Cancels are NOT silent by default, and flipping this to `true` changes nothing. (v1 does read it; do not carry the v1 behaviour across.)

---

## 12. How to debug

| Symptom | Start here |
|---|---|
| "BOL stuck in TRUCK_LOADING, close rejects" | §6.2 state guards + confirm `bolToClose` set isn't poisoned (JVM restart clears) |
| "Concurrent close on two replicas produced partial state" | §6.1 dual guard — check that DB pessimistic lock actually fired (DB-side pg_stat_activity during the window) |
| "OMS didn't get SHIPPED callback" | §7 + `message` / `message_archived` tables + check for rollback between state write and commit |
| "BOL detail says OMS notification failed" | §6.5.2–6.5.5: the failed-row line's `lastError` and Service Log link; Requeue once OMS is reachable; a "legacy notification" label means the manual recipe, not Requeue ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |
| "Intracompany transfer stuck in TRANSFER" | §8 — `finishTransfer` wasn't invoked on the receiving side |
| "Performance regression during close" | §6.3 — verify bulk JPQL paths still active |
| "Mobile operator scanned wrong gate — no error" | §5 — the check only fires against an already-assigned gate; see §11 item 5 |
| "Order shipped but batch still ORDER_BATCH_CLUB_RUN_FINISHED" | §6.3 — batch rollup is part of close; absence means close didn't commit |

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-11-11 | **Full-doc re-verification, §1-§12** against wms2-api origin/develop `df30fa62` (36 commits on `BillofladingService` since 2026-09-24 read by subject; the closeBOL, runShippingPhase, finishTransfer, palletise, scanGate, BolOmsNotificationService and controller bodies re-read). Code read on origin/develop `df30fa62`. | **Corrections:** `palletiseAndTruckLoad` deleted 2026-09-17 (§1, §3, §4, §9, §10); `/mobile/truckLoading/*` never existed — `/v3/truckLoading/*` (§3, §5); `closeBOL` guard state table, `bolToClose` key and silent CLOSED/CANCELLED no-op (§6.1, §6.2); position/order updates are `saveAll`, not JPQL (§1, §3, §6.3); `finishTransfer` now accepts any non-terminal BOL, runs the shipping phase below TRANSFER and locks pallets first (§8); SBDEV-4068 position-less-children detector (§6.4); mobile palletize moved to `MobilePalletizeWriteService` (§3); gate TODOs gone (§5, §11); capturedOrders hook obsolete (§11); rollbackFor per method (§10); all file:line anchors in §3, §6, §7, §9 re-pinned. **Confirmed unchanged:** §6.5 chunking/status/requeue behaviour and the repo/dispatcher/chunker anchors (`OutboxMessageRepository:109-120,138-142,175-188`, `OutboxDispatchService:107,333-342`, `BolShippedNotificationChunker:38,46,58,99`, `BillOfLadingWebServiceDto:46,49`), §5 PHASE A-D contents, export caps (100 BOLs, 250,000 rows). **Not re-verified:** the wms2-web-ui line cites in §6.5.2-6.5.4; PRD facts in §6.5 intro (v0.0.43, 12 chunk rows); live-data counts quoted in §5/§6.4. | doc-drift pass, 2026-11-11 |
| 2026-04-19 | `BillofladingService` (closeBOL, finishTransfer, createEntity, setTrackingDeviceID, transferOrder); `ParcelMonitorViewService.palletise` + `palletiseAndTruckLoad`; `MobileTruckLoadingService.scanGate`; `BillofladingPositionService`; all REST + mobile endpoints; OMS callback wiring | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-05-08 | Group B (BOL/palletize) ports verified live: v1 `98fce54` → v2 `cd73716` (new BOL no shipped date — confirmed via commit log); v1 `8957b9a` → v2 `a8af84f` (empty BOL export no SKU rows); v1 `83dddd8` palletize filter → v2 `ReportController` palletize filter routes via `/parcelMonitorView` GET (line 366) + ViewDtoService at the cited 1334-1338 region. `closeBOL` Phase 8 (Customerorder + Position FINISHED bulk) writes at lines 481 / 524; Phase 9 (post-commit OMS callback registration) per §6.5 — both confirmed. `finishTransfer` declaration shifted from cited 898 → actual line 899 (within tolerance, not edited). `BillOfLadingController` REST endpoint table re-confirmed against current source. | All claims still accurate; closeBOL header range expanded to reflect 273/278 method overloads. | Code read (grep-based) |
| 2026-05-19 | SBDEV-2232: `ParcelMonitorViewService.palletise` pessimistic-lock refactor shifted `palletiseAndTruckLoad` start from 210 → 232 (end of file: 470). `palletise` body end shifted from 207 → 230. Updated §3 diagram, §4 narrative, §4 `palletiseAndTruckLoad` line refs. Narrative and transaction shape unchanged — only `SELECT FOR UPDATE` guard added at top of `palletise`. | Line refs confirmed by grep against `src/main/java` | Code read (grep-based) |
| 2026-10-16 | SBDEV-3672: §6.5 rewritten (chunking, status row, requeue, R-9 gaps, legacy row); §1, §3, §7, §9, §12 touched. Code read at wms2-api `1866ab66` (`BillofladingService`, `BolShippedNotificationChunker`, `BolOmsNotificationService`, `BillOfLadingController`, `OutboxMessageRepository`, `OutboxDispatchService`) and wms2-web-ui `63b0a89` (`outboundBolDetails.vue`). Re-cited at `057d0e3b` (round 2: `BolOmsNotificationService` lines moved; `lastError` redaction now also masks the bare OMS host). Also corrected the stale `sendAfterCommit` snippet and the §7 `closeBOL` line-653 cite (outbox since SBDEV-2221). | New behaviour marked ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22); other sections not re-verified | SBDEV-3672 docs lane |

**Re-verify every 90 days.** Next due: **2027-02-09** — `BillofladingService` took 36 commits in the last 48 days, so treat the 90-day cadence as an upper bound.
