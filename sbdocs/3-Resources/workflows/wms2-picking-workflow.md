---
title: "WMS v2 — Picking Workflow"
type: workflow
status: active
version: v2
scope: picking
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: "Full-doc re-verification 2026-11-11 against wms2-api origin/develop df30fa62 (detached worktree): every method name, line anchor, sysprop gate, state write, lock order and OMS-callback producer in §1-§10 re-read from src/main. Biggest correction: `finalizePicking` NEVER existed as a method (git history back to 120db547 has only `finishPickingOrder`); §4 now maps the cascade onto `finishPickingOrder` + `confirmPick`. Also corrected: the mobile reserve/start flow (§5), the on-demand release entry point (§1), the rapid side-door (§6), who writes terminal Pickingorder states (§10). Previous last_verified: 2026-09-06 (scoped, scheduled-job entry points only)."
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ../architecture/wms2-scheduled-jobs-catalog.md
  - ./wms2-replenish-workflow.md
  - ../../4-Archieves/wms2/plan/260424-V2_Consolidated_Picking_Fixes_Port.md
  - ../../4-Archieves/wms2/plan/260424-OSIV_MERGE_PICKING_ORDERS_BUG_FIX_PLAN.md
  - ../../4-Archieves/wms2/plan/260424-picking-notification-drop.md
  - ../../4-Archieves/wms2/plan/260424-picking-oms-status-race-condition-fix.md
  - ../../4-Archieves/wms2/plan/260424-PICKING_PERFORMANCE_PLAN.md
tags:
  - workflow
  - picking
  - wms2
---

# WMS v2 — Picking Workflow

**Scope:** End-to-end picking flow in `v2/wms2-api` — from a released customer order to finalized pick cascade · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-11-11

---

## 1. Overview

Picking is the single hottest state-transition surface in `wms2-api`. One finish call (`PickingorderBusinessService.finishPickingOrder`, `:166`; there is no method named `finalizePicking` — see §4) mutates five entities in one transaction: `Customerorder`, `Pickingorder`, `PickingorderPosition`, `PickingorderUnitload`, and indirectly `Stockunit`. Roughly half the archived v2 bug plans touch this flow (OSIV, merge, notification, race conditions, performance).

Two entry points trigger picking work:

- **Scheduled release**: `OrderReleaseJob` (scheduled only when `app.cron=true` — `SchedulingConfiguration` is `@ConditionalOnProperty(app.cron)`; per tenant the body is skipped unless BOTH sysprops `NEW_CRON_JOB_ACTIVATED` and `ORDER_TIMER_ACTIVATED` are true, `OrderReleaseJob.java:245-246`) streams the positions of customer orders with `state < ASSIGNED`, `pickingdate <= today`, batch type `PICK_PACK` (`CustomerorderPositionRepository.streamOrderReleaseInfo`) and creates picking orders for any whose fixed-location / overstock math now allows release.
- **On-demand**: `GET /v3/adminAction/triggerOrderReplenish` (`AdminActionController:112-117`, `@RequiresFunction WEB_UI_VIEW_IMPORT_DATA`) calls `orderReleaseJob.runForCurrentTenant()` and then `replenishJob.runForCurrentTenant()` — the same two sysprop gates and the same `(100001, tenantId)` advisory lock as the cron. ⚠ Corrected 2026-11-11: this section used to say `/v3/clubLine/runClubLine/{batchId}` and `/v3/orders/*` "produce the same downstream work" and that both paths "converge on `ReleaseOrderJobService.releaseOrder`". There is no `/v3/orders` prefix (customer-order routes are `/v3/customerOrder`), and `OrderReleaseJob.java:593` is the ONLY caller of `releaseOrder` in `src/main`; the club run is a separate pipeline in `CustomerorderBatchService` (see the club-run workflow).

The job path then continues through the mobile pick flow.

> **Overstock `partitionallowed` guard (SBDEV-2512, default ON).** In the overstock branch of `releaseOrder`, a non-partitionable position (`partitionallowed=false`, which every v2 position is today) is only released if a **single** stock unit covers its full amount. Round-2 cumulative check (`reserveSingleCoveringUnit`, seeded from the non-locking `getStockUnitsByItemDataId`) **holds** the whole order (position → `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`, order → `RAW_ON_HOLD`, mandatory `LOG.info`) when no single unit can cover — instead of fragmenting the pick across units. Phase 3 (Fix B) then takes exactly one pick from a single covering unit off the already-locked `getStockUnitsByItemDataIdForUpdate` list, with a failsafe `BusinessException` only for the residual inter-order race. Partitionable positions (`partitionallowed=true`) keep the legacy split/greedy path. Kill-switch: sysprop `ENFORCE_PARTITIONALLOWED=false` restores legacy fragmenting with no redeploy (≤2-min Caffeine TTL).

---

## 2. Entity Cast

| Entity | Role | State field |
|---|---|---|
| `Customerorder` | Order we're fulfilling | Integer `state` |
| `CustomerorderPosition` | Order line | Integer `state` |
| `CustomerorderBatch` | Batch / club wave (optional) | Integer `state` |
| `Pickingorder` | Work package for an operator | Integer `state` |
| `PickingorderPosition` | One line of work | Integer `state` |
| `PickingorderUnitload` | Tote / carton being filled | Integer `state` |
| `Stockunit` | Amount + reserved amount at a location | — (no state) |
| `Unitload` | Physical pallet / tote holding stock | — (no state) |

For full state-value enumeration see [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §2.1. This doc assumes those constants.

---

## 3. Lifecycle

```
(customer order arrives, via OMS REST or file import)
         │
         ▼
   Customerorder.state = RAW (or FUTURE_PICKING_DATE)
         │
         ▼  CustomerorderService.setPickingDate()   [was createForRelease() — ZERO hits repo-wide; real symbol is setPickingDate, now at :309 (was :257 on 2026-09-06)]
         │
  ┌──────┴────────┐
  │ scheduled?    │
  └──┬────────┬───┘
     │        │
     │ no     │ yes
     │        ▼
     │   OrderReleaseJob.runFor(TriggerSpec)          [SBDEV-3198; was doCalculation()]
     │   ├─ for each ACTIVE tenant: set TenantContext
     │   ├─ skip unless this tenant's own schedule == the firing spec
     │   ├─ advisory lock (ORDER_RELEASE 100001L, tenant_db_configuration.id)   ← TWO-key  [tryLock :237]
     │   ├─ THEN the sysprop gate (NEW_CRON_JOB_ACTIVATED && ORDER_TIMER_ACTIVATED) [:245-246] — the lock is taken before the gate
     │   └─ for each order with state < ASSIGNED (RAW / RAW_ON_HOLD*), via streamOrderReleaseInfo:
     │        ReleaseOrderJobService.releaseOrder(...)   [@Transactional REQUIRES_NEW, :132-133]
     │             ├─ CustomerorderPosition.state → ASSIGNED (or a RAW_ON_HOLD_* state when it cannot be released)
     │             ├─ Customerorder.state → ASSIGNED if it was lower (:754); CustomerorderBatch.state → STARTED (:758)
     │             └─ Pickingorder created, state = PROCESSABLE (:637)
     │                ✓ merged(SBDEV-2045: #621 689334e2, 2026-11-05): TOTES_ON_CART → first JOINS one open cart (§7) if one fits
     │
     ▼
   Pickingorder.state = PROCESSABLE
         │
         │  optional: ReplenishOrderJob.mergePickingOrders()
         │           ├─ for TOTES_ON_CART sections
         │           └─ Pickingorder.state stays PROCESSABLE
         │
         ▼
   [ Mobile operator flow ]
         │
         │ MobilePickingService.getPickingOrderPositionsInfo()  [:875 → startPickingOrder :356 → PickingorderBusinessService.startPickingOrder :139]
         │   (REST: GET /v3/picking/pickingOrderPositionsInfo/{id}; claims the order: operator_id set, state → STARTED)
         │   ⚠ RESERVED is written only by MobilePickingService.claimPickingOrderAtomically (:404, via selectAndReservePickingOrder :164),
         │     which has NO caller in src/main (tests only) — the live mobile flow goes PROCESSABLE → STARTED directly.
         ▼
   Pickingorder.state = STARTED
         │
         │ … operator scans items, fills totes …
         │
         │ MobilePickingService.processPick() → PickingorderBusinessService.confirmPick()   [per pick, :1213]
         │    sets Pickingorder.state = PICKED when no open lines remain (:1531)
         │ then the all-picked branch (`state == PICKED → finishPickingOrder`) in processPick :658 /
         │    releaseRegularPickingOrder :854 / startPickingOrder :375 / releasePickingOrder :288 / the rapid path :1551
         │
         ├──► PickingorderBusinessService.finishPickingOrder()  [:166-499]
         │    {5-entity cascade — see §4}
         │
         ▼
   Customerorder.state = PICKED   (or PENDING or STARTED)
   Pickingorder.state = FINISHED  (or PICKED, PROCESSABLE, CANCELED)
   PickingorderPosition.state = PICKED / STARTED / PENDING
   PickingorderUnitload.state = PICKED / STARTED
         │
         │  downstream: pack → palletize → load-to-truck → BOL close
         │  (see wms2-bol-truck-loading-workflow.md)
         ▼
   Customerorder.state = FINISHED

   Sidebar: RapidPicking releases stale picks
         │
         ▼  ReleaseExpiredPickingOrdersFromUserJob (every :40s, gated by PICK_TIME_OUT_SYSTEM_ACTIVATED)
         │
         └─ if Pickingorder.lockedtooperator=true && pickinginprogress=false
              && state<PICKED && section.type=RAPID_PICKING && modified older than PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE
              → clear operatorId, lockedtooperator=false
              (state unchanged — the order goes back to the pool for another picker)
              ⚠ operatorId!=null is deliberately NOT in the predicate. This doc claimed it until 2026-09-08;
                #285 dropped it so the job also heals an ORPHAN lock (locked, operator_id NULL).
              ⚠ SBDEV-3205: this predicate was unsatisfiable from 326b20dc (2025-10-31) until 2026-09-02 — the job released nothing
              ⚠ SBDEV-3262: one row failing no longer aborts the tenant's remaining rows
```

---

## 4. The `finishPickingOrder` / `confirmPick` Cascade

> ⚠ **Corrected 2026-11-11 — `finalizePicking` does not exist.** No method of that name has ever been in `src/main` (`git grep -n finalizePicking 120db547 -- src/main` is empty; the only hits on `df30fa62` are the unrelated `finalizePickingOrderIfTerminal` / `finalizePickingOrderForStart`). This section previously described a single "finalizePicking, lines 238-568" whose write sites actually belong to two methods: `confirmPick` (per-pick writes) and `finishPickingOrder` (the close-out). The table below is rebuilt from both, at `df30fa62`.

`PickingorderBusinessService.finishPickingOrder()` (`:166-499`, `@Transactional(tenantTransactionManager, rollbackFor={BusinessException, FacadeException})`) is the single most dangerous method in the picking path; `confirmPick` (`:1213-1537`, same annotation) is its per-pick sibling. Read both entirely before changing any part of them.

**`finishPickingOrder`** (`PickingorderBusinessService.java`) — locks the picking order first (`LockReads.forUpdate`, `:202`), refuses `state >= FINISHED` (`ORDER_ALREADY_FINISHED`), then locks the touched customer orders in ascending id (`TreeSet`) before any write:

| Line | Entity | Target state |
|---|---|---|
| 380 | Customerorder | `PENDING` (every CO position ≥ `PENDING`, at least one `PENDING`) |
| 383 | Customerorder | `PICKED` (every CO position ≥ `PENDING`, none `PENDING`) |
| `cleanUpCancelledOrder` (`:758`) via `:352` | Customerorder | `CANCELED` (`:857`) for an order with `markedforcancellation`; its CO positions → `CANCELED` (`:878`), its PickingorderUnitloads → `CANCELED` (`:947`) |
| 449 | PickingorderUnitload | `PICKED` (and the tote is moved to the `FINISHED_PICKING` location) |
| 491 | Pickingorder | `orderState`: `FINISHED` if any non-cancelled position is at `PICKED`+, else `CANCELED` (also clears `lockedtooperator` / `pickinginprogress`, keeps `operator_id`) |

**`confirmPick`** (per pick) — takes the picking-order lock first, then the customer order (SBDEV-3865):

| Line | Entity | Target state |
|---|---|---|
| 1386 | PickingorderPosition | `PICKED` |
| 1410 | CustomerorderPosition | `PICKED` (picked amount ≥ ordered) |
| 1416 | CustomerorderPosition | `STARTED` (short, open pick lines remain) |
| 1418 | CustomerorderPosition | `PENDING` (short, no open pick line left) |
| 1437 | Customerorder | `STARTED` (+ `PICKING_STARTED` outbox row, see §8) |
| 1488 / 1491 | Customerorder | `PENDING` / `PICKED` (all CO positions done) |
| 1502 | PickingorderUnitload | `STARTED` |
| 1531 | Pickingorder | `PICKED` (no unpicked line left) |

**Cancel-path writes** (`cancelOpenPickLines :628`, called from `cleanUpCancelledOrder :883`): PickingorderPosition → `CANCELED` (`:708`); `finalizePickingOrderIfTerminal` (`:739`) then sets the Pickingorder to `CANCELED` (all lines cancelled) or `FINISHED` (`:745`) and **clears `operator_id`**, `lockedtooperator`, `pickinginprogress`.

**Why three outcomes for one CustomerorderPosition?** `PICKED` is the happy path; `STARTED` means the position is only partially filled and pick lines remain; `PENDING` means it is short and nothing is left to pick it. Missing one of the three branches when you modify `confirmPick` produces stuck state. (This paragraph said "three terminal states for one PickingorderPosition" before 2026-11-11 — the three-way branch is on the CO position, `:1408-1418`.)

For the full cascade map see [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §5.5. The catalog was re-verified the same day and uses `finishPickingOrder` + `confirmPick`; its remaining `finalizePicking` mentions only record that the method does not exist.

---

## 5. Mobile Operator Flow

Mobile UI (`v2/wms2-mobile-ui`) drives the operator side. Each screen action maps to a REST call under `/v3/picking` (`PickingController`) on `MobilePickingService`. Re-derived 2026-11-11; the earlier table named `reserveOrder`, `startPicking` and `finishPicking`, none of which exist.

| Screen action | REST → service method | State change |
|---|---|---|
| List pickable orders | `GET /pickingOrders/{section}` → `getPickingOrders` (`:728`) | — (read-only) |
| Open an order (claim + start) | `GET /pickingOrderPositionsInfo/{id}` → `getPickingOrderPositionsInfo` (`:875`, locks the order, refuses another operator) → `startPickingOrder` (`:356`) → `PickingorderBusinessService.startPickingOrder` (`:139`) | Pickingorder `PROCESSABLE` → `STARTED`, `operator_id` set (only when `state < STARTED`, `:885`); if every line is already done/cancelled it instead calls `finishPickingOrder` and returns an empty list |
| (not wired) reserve | `selectAndReservePickingOrder` (`:164`; two short transactions, `claimPickingOrderAtomically :392`) | `PROCESSABLE` → `RESERVED` (`:404`). ⚠ **No caller in `src/main`** (only `MobilePickingServiceUnitTest`) — RESERVED is never written by a live flow today |
| Scan source location | `GET /processLocation/{id}/{input}` → `processLocation` (`:1096`) | — |
| Scan tote / confirm the pick | `POST /processPick` → `processPick` (`:465`) → `PickingorderBusinessService.confirmPick` (`:1213`) | PickingorderPosition `PICKED`; Pickingorder `PICKED` when no open line is left (§4); if so `finishPickingOrder` runs in the same call (`:657-658`) |
| Release / abandon | `GET /releasePickingOrder/{id}` → `releaseRegularPickingOrder` (`:766`) | all picked → finish; none picked → `PROCESSABLE`, operator cleared; partly picked → refused ("cannot release") |
| Cancellation | arrives via OMS / `CustomerorderService.cancelOrder` (`:899`); a picked-in-progress order is flagged `markedforcancellation` and settled by `finishPickingOrder` → `cleanUpCancelledOrder` | Customerorder → `CANCELED` (`:857`) |

Rapid-picking sections use a different REST set (`/processRapidPickScanPackage`, `/processRapidPickScanSource`, `/processRapidPickScanSourcePass`, `/processRapidPickScanPackageToVerify`, `/resetPickingOrder`); the `/processRapidPickScanPackageType` route is commented out in `PickingController:89`.

> Picking-position sort order (VERTICAL = column-first, HORIZONTAL = row-first) is controlled by the `PICK_PATH_DIRECTION` sysprop via `PickPathConfig` → `DefaultStrategy`.

Per-operator guards in `MobilePickingService` (re-derived 2026-11-11; the old line numbers 222/303/328/333/340 no longer match anything):

| Line | Guard |
|---|---|
| 246-254, 274-296, 370-383, 422-429 | `allFinished` (demand-aware `isPickingOrderComplete`) and `state <= PICKED` → set `PICKED`; `== PICKED` → `finishPickingOrder` then return; `> PICKED` → return (already finished). Same shape in `releasePickingOrder`, `startPickingOrder`, `finalizePickingOrderForStart` |
| 298-301 | any line `== PICKED` in `releasePickingOrder` → `BusinessException("Finish already started picking order!")` |
| 398-402 | claim: `< RESERVED`; `>= PICKED` → `PICK_ALREADY_STARTED` |
| 406-408 | already reserved by another operator → `"Picking Order reserved by different user!"` |
| 520-521 | `processPick`: `>= PICKED` → `BusinessException("Picking order … is already in state …")` |
| 781-785 | `releaseRegularPickingOrder`: `> PICKED` → `reenqueuePickingFinishedIfMissing` and return |
| 878-882 | `getPickingOrderPositionsInfo`: `operator_id` set to a different user → `"Parcel already assigned to user …"` |

> **SBDEV-3865 — the pick is judged on the STORED line, not the request body** ✓ merged(SBDEV-3865: #558 bafa2301, 2026-10-22). The rapid
> endpoints (`/processRapidPickScanSource`, `/processRapidPickScanSourcePass`, `/processRapidPickScanPackageToVerify`,
> `/resetPickingOrder`) take a whole `PickingorderPosition` in the body; they now re-read it by id and act on the stored row.
> The rapid pick refuses a body whose picking order, amount, pick-from stock unit or pick-to unit load differs from it
> (`"does not match the stored pick (<field>)"`), comparing the picking order **before** reading the line's state; an
> already-picked line still answers `PICK_ALREADY_FINISHED`. `processPick` refuses a line that is not on the order it
> locked. Reset and release lock the stored line's order and refuse one held by another operator, and so does
> `GET /releasePickingOrder/{id}` (`releaseRegularPickingOrder`), after its Case 1 OMS re-enqueue safety net.
> `PickingorderBusinessService.confirmPick` (the one stock-moving step of both pick paths) takes the picking-order lock
> **first**, then the customer order, and refuses an amount other than the stored one (`PICK_CONFIRM_AMOUNT_MISMATCH`), a
> stored order held by another operator (`PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR`, "free or the caller") and a
> tote other than the stored pick-to unit load (`PICK_CONFIRM_WRONG_PICK_TO_UNITLOAD`, null-tolerant for the first pick).
> Before this, a rapid pick posted with amount 7 against a stored 2 moved 7 units on DEV, 5 of them unreserved stock.

---

## 6. Rapid Pick Side-Door

`RAPID_PICKING` sections behave differently. When a customer order is cancelled AND the tote was already rapid-picked, the rapid-pick branch in `CustomerorderService.cancelOrder` (`:899`; guard at `:984`: the client's section is `RAPID_PICKING` AND `customerOrder.state == ASSIGNED` AND `historytote != null`; `Pickingorder.setState(PROCESSABLE)` at `:1032`, and only when that picking order is `STARTED`) bounces the `Pickingorder` **back to `PROCESSABLE`** instead of `CANCELED`, so the tote's contents can be redistributed to other orders. Its pick-to unit loads are set `CANCELED` (`:1037`) and an empty picking tote is sent to Nirvana (`:1051`). Re-derived 2026-11-11: there is no method `handleRapidPickingForCancelledOrder` — the branch is inline, and it runs BEFORE the `cancelOrderPosition` loop, so the order is not yet `CANCELED` when it fires.

```
cancelOrder()  (CustomerorderService:899)
     │
     ├── all positions cancellable?  (canOrderPositionBeCancelled)
     │
     ├── RAPID_PICKING section && CO.state == ASSIGNED && historytote != null   [:984]
     │      └── first CO position's first pick line's Pickingorder, if STARTED:
     │            Pickingorder.state = PROCESSABLE  ← NOT CANCELED              [:1032]
     │            its PickingorderUnitloads → CANCELED
     │
     └── cancelOrderPosition() for every non-cancelled position → Customerorder CANCELED
```

⚠ Code comments at `CustomerorderService:998` and `:1023` state "the RAPID arm is dead estate-wide" / "Dead on all six tenants today: both RAPID_PICKING sections carry zero orders" (and SBDEV-3363 documents that `coPositions.get(0)` is deliberately unfiltered, so on a mixed order the side-door may inspect a cancelled position's picking order). ⚠ unverified 2026-11-11: whether any tenant still exercises the arm — taken from the comment, not from data.

Don't "simplify" the `historytote != null` branch — see `Cancel_Order_Null_SectionId_And_Early_Return_Fix` for the original incident.

`ReleaseExpiredPickingOrdersFromUserJob` also only fires on `RAPID_PICKING` sections. See [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §4.5.

---

## 7. Merge Pass

`ReplenishOrderJob.mergePickingOrders()` runs before each replenish pass (gated by sysprop `MERGE_PICKING_ORDERS=true`, default `true`). For sections with picking type `TOTES_ON_CART`, it groups compatible picking orders into a single cart-sized work unit respecting `PICKING_BOX_PER_CART` (default `6`).

- Sets `Pickingorder.state = PROCESSABLE` for the merged group at `PickingOrderMergeService.java:161`.
- Every donor `Pickingorder` the pass does not reuse as a cart is cancelled (state → `CANCELED`, `section_id` and `customerordernumber` → null) — on SUCCESS, not on failure as this line used to say (`pickingOrder.setState(WmsConstants.State.CANCELED)` in the donor loop). These are the empty CANCELED picking orders that accumulate (DEV, 90 days to 2026-11-04: 55).

**Fill at release ✓ merged(SBDEV-2045: #621 689334e2, 2026-11-05).** `ReleaseOrderJobService.lockOpenCart` makes the release itself fill carts, so the merge pass becomes cleanup. For a `TOTES_ON_CART` section, and under the same two sysprop gates as the merge (`MERGE_PICKING_ORDERS=true`, `PICKING_BOX_PER_CART > 1`), release:
- picks ONE candidate from the merge's own capacity query `findByStateAndBoxesPerCartAndSectionId`, skipping carts already claimed, locked to an operator or in progress, and preferring the order's prio and then the NEWEST cart (pickers are offered the oldest first);
- takes the row lock WITHOUT waiting (`lockIdForNoKeyUpdateSkipLocked`, native `FOR NO KEY UPDATE SKIP LOCKED`). A cart someone holds is skipped to a new picking order, so release never queues behind a picker or the merge. It then refreshes the cart through `LockReads.forUpdate` and re-checks it under the lock: `PROCESSABLE`, same section, no operator, not `lockedtooperator`, not `pickinginprogress`, and still under the cap (`countDistinctCustomerordersOnPickingorder`);
- on success, joins it (nulls `customerordernumber`, since non-null means "exactly one order", and dirties the row so its `@Version` bumps), attaches the order's pick lines and recomputes prio via `PickingorderPriorityService`;
- on any failed re-check, mints a new picking order as before. It never tries a second candidate: a rejected candidate stays locked to commit, and a second lock could invert against the merge's ascending-id multi-row lock.

Lock order is CO → PO → stock units. The picking-date cleanup (`CustomerorderService.checkAndCleanUpPickingOrderPositions`) used to take stock units BEFORE the picking order (`changeReservedAmount`, then an unlocked cancel-save). That is a cycle with a release holding a cart, and it could cancel a cart a release had just joined. It now locks its picking orders first, in ascending id order, via `LockReads` ✓ merged(SBDEV-2045: #621 689334e2, 2026-11-05). `batchUpdatePickingDate` (one transaction for every order) locks the UNION of all orders' picking orders up front, so it never holds one order's stock while it waits for the next order's cart.  `RAPID_PICKING` is untouched. A newly minted picking order now takes `customerorder.prio`, not `orderBatch.priority`, which went stale once one order was re-prioritised (4 such orders on DEV, 2026-11-04). Race proof: `ReleaseOpenCartLockRaceIT`.

Merge is a silent optimization — an operator never sees it. But it means: when a new pick order appears unexpectedly, check whether merge produced it before treating it as anomalous.

---

## 8. OMS Callback Touchpoints

Picking-lifecycle OMS callbacks use **two delivery mechanisms** depending on the call-site (see `wms2-oms-integration-map.md` §2.1):

| OMS callback | Fired from | Delivery | Sysprop URL key |
|---|---|---|---|
| `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | Every producer enqueues on the outbox: the release job (`ReleaseOrderJobService.releaseOrder()`), club finalize (`CustomerorderBatchService.finalizeClubLine()`) and the BOL transfer path (`BillofladingService.transferOrder()`, sysprop-gated). Only the job builds with `ManageOrderService.buildReleasedForPickingPayloadJson`; the other two send the STARTED payload (`buildPickingStartedPayloadJson`) | **outbox** (SBDEV-2381; the former `customerOrderReleaseForPicking` dispatcher was deleted by SBDEV-3102 D2, 2026-10-21) | `…RELEASED_FOR_PICKING_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED` | `ManageOrderService.customerOrderToteAssigned()` | `sendAfterCommit` | `…PICKING_TOTE_ASSIGNED_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_PICKING` | `PickingorderBusinessService.confirmPick()` (`:1441`; SBDEV-3556: the payload now names the confirming picker as batch-level actor via `OmsActorResolver`) | **outbox** ¹ | `…PICKING_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_FINISHED_PICKING` | `PickingorderBusinessService.finishPickingOrder()` (`:395`), the `reenqueuePickingFinishedIfMissing` safety net (`:549`) and club finalize (`CustomerorderBatchService:971`) | **outbox** ¹ | `…FINISHED_PICKING_URL_KEY` |
| `WEBSERVICE_ORDER_BATCH_HELD` | `ManageOrderService.customerOrderOnHold()` | `sendAfterCommit` | `…HELD_URL_KEY` |

> ¹ **2026-05-20 (picking-finished fix):** `PICKING_STARTED` and `PICKING_FINISHED` were previously routed through `ManageOrderService.customerOrderPickingStarted/Picked` via a nested `registerSynchronization` call inside `sendAfterCommit`, which Spring silently discarded (double-afterCommit bug — see investigation report `260520-wms2-picking-finished-oms-notification-dropped.md`). Both call-sites in `PickingorderBusinessService` now call `outboxService.enqueue(OutboxMessage)` directly inside the still-open `@Transactional("tenantTransactionManager")` boundary — the outbox row commits atomically with the state change. `OutboxDispatcherJob` delivers with at-least-once retry. `ManageOrderService.customerOrderPickingStarted()` and `customerOrderPicked()` were later retired to no-op shims (SBDEV-2381) and deleted (SBDEV-3102 D2, 2026-10-21); every caller now uses the `build*PayloadJson` builders plus `outboxService.enqueue`.
>
> **Safety net:** `MobilePickingService.releaseRegularPickingOrder` Case 1 (already-finished early exit) now calls `PickingorderBusinessService.reenqueuePickingFinishedIfMissing(pickingOrder)` before returning, to recover any CO with `state≥PICKED` AND `pickingconfirmationsent=false` stranded by the pre-fix bug.

> **SBDEV-2381 (2026-06-01) — backward-STARTED guard:** `confirmPick` now **skips the `PICKING_STARTED` outbox enqueue when the CO has already advanced** — `state ≥ PICKED` OR `pickingconfirmationsent == true` (snapshot taken before `setState(STARTED)`). This is the primary defense against emitting a backward `STARTED` after a parcel has reached Ready-to-QA. It complements the dispatcher-side ordering gate + `event_version` field added in the same ticket — see `architecture/wms2-oms-integration-map.md` §2.1.

`sendAfterCommit`-based callbacks fire **after the WMS transaction commits**. A WMS rollback silently drops the callback. If OMS claims it never heard about a non-outbox callback, check the `message` / `message_archived` tables for a matching row — absence means the commit itself never happened or the nested-afterCommit bug fired. For outbox-based callbacks, check `outbox_message WHERE process_type IN ('ORDER_BATCH_PICKING_FINISHED','ORDER_BATCH_PICKING_STARTED')`.

---

## 9. Transaction Boundaries

- `OrderReleaseJob` → `ReleaseOrderJobService.releaseOrder(...)` — each order release is `@Transactional(propagation=REQUIRES_NEW, value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`. A single order failure does not abort the rest of the tenant's run. **`rollbackFor` is load-bearing (SBDEV-2512):** without it, the checked `BusinessException` throws inside `releaseOrder` (the pre-existing "Section not configured" `orElseThrow` and the Fix B overstock failsafe) would COMMIT partial work in this `REQUIRES_NEW` tx rather than roll it back.
- `finishPickingOrder` runs under a single `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` — all 5 entity writes succeed or all roll back atomically. No cascade is "halfway through" on an exception. `confirmPick` has the same annotation. Neither method opens `REQUIRES_NEW`, so when called from a mobile `@Transactional` method they join the caller's transaction.
- Optimistic locking on `AbstractBaseEntity.version` guards every save; retries are NOT automatic inside the picking transactions — a conflict surfaces at commit and is mapped to HTTP 409 (`RestExceptionHandler`) for the operator to retry. The former `OptimisticLockRetry` wrapper inside `confirmPick` was removed as inert (260610 Phase A: inside an open `@Transactional` the optimistic-lock exception only fires at the outer commit, outside the retry loop); the path is serialized by the PO then CO `findByIdForUpdate` locks taken at method entry (SBDEV-3865 moved the PO lock first; `confirmPick` `:1231-1260`).
- OMS POSTs use either `omsNotificationService.sendAfterCommit(...)` (fire-and-forget, no retry) or `outboxService.enqueue(...)` (at-least-once, retried by `OutboxDispatcherJob`) — see §8 table. Never block the TX on network I/O.

For the full transaction + locking picture see [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §5 and §8.

---

## 9.1 Pick-path ordering (SBDEV-3133, PR #233, merged 2026-08-29)

The route order is decided by `LocationPathOrdering` (`util/`), shared by **all three** comparators so
the handheld route and the printed tote label cannot drift apart:

| Comparator | Used for |
|---|---|
| `InMemoryLocationComparator` | the handheld pick route |
| `DefaultStrategy` | the printed tote label |
| `CycleCountStrategy` | cycle-count routes |

### Tiers

1. **Rack row** — and **unzoned racks (`rackrowId == null`) sort after every zoned rack, as one
   contiguous block.** Two unzoned racks tie here and fall through.
2. **Rack** ordinal.
3. **Column and level**, in the configured `PickPathDirection`, then **depth (`zpos`)** — `LocationPathOrdering.DepthTier.COMPARED` for the two picking comparators, `IGNORED` for cycle counting (added by `fd91922a`, 2026-08-29, so the count sequence keeps going from column/level straight to name).
4. **Deterministic tiebreaks** (name, then id) so a sort never aborts on a tie.

`CycleCountStrategy` keeps two conventions of its own on top of the shared tiers: a null location or a location with no rack sorts **last** (the opposite of `DefaultStrategy`), and two racks that are both unzoned are ordered on coordinates alone, without rack ordinals (`CycleCountStrategy.java`, class javadoc).

### ⚠ Why tier 1 must not "skip" instead of ordering

Before SBDEV-3133 the comparators compared rack-row ordinals **only when both racks had a rack row**,
and otherwise fell straight through to the rack tier. Rack ordinals are only meaningful *within* a
row — every row numbers its racks from 1 — so any pair involving an unzoned rack was decided on a
number from a different scale, while zoned pairs were still decided on the row tier.

The relation that produces is **cyclic**, not merely wrong. With shelf `{row 1, rack 9}`, shelf
`{row 2, rack 2}` and unzoned `{rack 5}`:

```
SH-1-09 < SH-2-02   (row tier: row 1 before row 2)
SH-2-02 < FB-A      (rack tier: 2 < 5)
FB-A    < SH-1-09   (rack tier: 5 < 9)
```

Sorting against a cyclic comparator emits an **arbitrary** order — the reported symptom was a route
running shelf locations, crossing to another pick area, then returning to *more* shelf locations.
WineCo hit it with bottle/flow-bin locations that are intentionally unzoned and shared across
wineries.

`LocationPathOrderingUnitTest.ComparatorContract` guards this — note it asserts the **properties**
(`isAntisymmetric`, *"is transitive for every triple — the property the old comparator broke"*)
against the **fixed** comparators; it does not re-run the old ones. Its `mixedFixture()` is the exact
set above: racks with ordinals 9 (row 1), 2 (row 2) and 5 (unzoned), plus a `LOOSE` location with no
rack at all. `handheldAndToteLabelAgree` is what pins the handheld route and the printed tote label
to the same order.

Unzoned racks stay unzoned and shared — they are simply **visited once, at the end of the route**.
This is the posture `CycleCountStrategy` already took, and the one the comparators already took for a
location with no rack at all.

⚠ **A comparator that is merely "wrong" and one that is non-transitive are different failure
classes.** The second can also throw `IllegalArgumentException: Comparison method violates its
general contract!` from `TimSort` on larger inputs. If you touch these tiers, test the *relation*
(transitivity across a mixed zoned/unzoned set), not just a couple of expected orderings.

## 10. Known Landmines

1. **`finishPickingOrder` (+ `confirmPick`) writes 5 entities in one TX.** Read §4 in full before modifying any branch. Missing one case produces stuck state (e.g. `Pickingorder=FINISHED` but `Customerorder=STARTED`).
2. **`RAPID_PICKING` cancellation side-door** (§6). Cancelling an order with `historytote != null` leaves the `Pickingorder` in `PROCESSABLE`, not `CANCELED`. Archive: `Cancel_Order_Null_SectionId_And_Early_Return_Fix`.
3. **Terminal `Pickingorder` states have five writer sites, not one** (the fifth, `CustomerorderPositionService:208`, sets `CANCELED`/`FINISHED` once every position is terminal; added after independent review 2026-11-11). (Re-derived 2026-11-11; this item used to say only `MobilePickingService:267` writes `FINISHED`, a line that no longer carries that write.) `PickingorderBusinessService.finishPickingOrder:491` (`FINISHED`/`CANCELED`; reached from 9 call sites — 7 in `MobilePickingService`, `AdminActionController:313`, `CustomerorderService:520`), `PickingorderBusinessService.finalizePickingOrderIfTerminal:745` (after `cancelOpenPickLines`; also clears `operator_id`), and `MobilePickingService.releasePickingOrder:338` (`FINISHED`) / `:347` (`CANCELED`). A path that believes it is "finished picking" must route through `finishPickingOrder` — flagged in `WMS_API_Problem_Areas_Analysis_And_Refactoring_Plan`.
4. **`Pickingorder=PICKED` vs `FINISHED`**. `PICKED` means the physical work is done but the `Customerorder` hasn't rolled up yet. `FINISHED` is the terminal tenant-DB state. Treat them as distinct in queries.
5. **Merge pass runs quietly.** A new `Pickingorder` can materialize between two scheduler ticks due to `ReplenishOrderJob.mergePickingOrders`. Don't treat unexpected picks as anomalies without checking §7.
6. **OMS callbacks drop silently on rollback.** Use `message` table to verify delivery — see `picking-notification-drop` archive.
7. **`ReleaseExpiredPickingOrdersFromUserJob` is off by default.** `PICK_TIME_OUT_SYSTEM_ACTIVATED=false` ships in every environment. Enable it explicitly or rapid-pick orders abandoned mid-flight stay locked indefinitely.
8. **`Pickingorder.lockedtooperator` is manipulated by both the mobile flow and the release job.** Only the two `rapidPickingScanPackage*` paths in `MobilePickingService` ever set it `true` (`:1249` in `rapidPickingScanPackage`, `:1380` in `rapidPickingScanPackageAndType`; the `AndType` path also sets `STARTED`, via `rapidPickingConnectPackageAndType:1361`); the reserve path (`:403-404`, itself unreferenced — §5) sets `operator_id` + `RESERVED` without it. The timeout release (§6) only clears the operator binding, not state — the order stays at whatever sub-`PICKED` state it held (typically `STARTED`) for another operator to claim. ⚠ **SBDEV-3205 (SHIPPED to `develop` 2026-09-03, PRs #284 + #285):** the release query was unsatisfiable from 2025-10-31 to 2026-09-02, so abandoned rapid-pick holds were never released even with `PICK_TIME_OUT_SYSTEM_ACTIVATED=true`. ⚠ **SBDEV-3262:** the ORPHAN-LOCK state (`lockedtooperator = true` with `operator_id NULL`) had a **producer** that #285 never closed — it only taught the consumer to tolerate it and the job to heal it. Three sites cleared `operator_id` without clearing the hold, so the invariant is now enforced in `Pickingorder.setOperatorId`: **clearing `operator_id` also clears `lockedtooperator`**. The rule is DIRECTIONAL — clearing the lock does NOT clear `operator_id`, because five sites keep the operator as provenance for who picked the order. A **second family** of violators never calls `setOperatorId` at all, so no setter guard reaches them: the `state == PICKED → finishPickingOrder(); return;` shape, which occurs at **six** call sites (`MobilePickingService` `:250`, `:288`, `:375`, `:426`, `:658` and `releaseRegularPickingOrder`'s all-picked branch `:854`; re-anchored 2026-11-11). Only the two rapid-pick completion paths cleared the flag themselves. Fixed once inside **`PickingorderBusinessService.finishPickingOrder`**, where all **nine** of its call sites converge (seven in `MobilePickingService`, plus `CustomerorderService:520` and `AdminActionController:313`; was "ten" — re-counted 2026-11-11) — including `AdminActionController`'s force-finish recovery action, which is where an operator resolves a STUCK order and therefore the one most likely to be holding a stale lock. A finished order now clears both `lockedtooperator` and `pickinginprogress` and keeps `operator_id` (`:489-490`). Contrast `finalizePickingOrderIfTerminal` (cancel path), which also nulls `operator_id` (`:746`). ⚠ **PRODUCER-ONLY — this heals no EXISTING orphan.** `finishPickingOrder` throws `ORDER_ALREADY_FINISHED` for `state >= FINISHED` before reaching the clear, so re-finishing an already-stranded row does nothing for it. Such a row needs an operator re-scan or a manual `UPDATE`; the pick-timeout job cannot see it. Measured 2026-09-08: zero such rows on dev and Hydra UAT — but the control (any lock held at all) was also zero, so read that as *the mechanism is unexercised*, not as proof there are none. ⚠ This family is the one **no automatic healer** reaches: the stranded row sits at `FINISHED`/`CANCELED`, which the timeout query excludes via `state < PICKED`. Three paths can still clear it — `rapidPickingScanPackage`, its verify sibling, and `CustomerorderPositionService` on OMS cancellation — but each needs an operator re-scan or an OMS event.
9. **State-value numeric ordering is load-bearing.** `MobilePickingService` uses `>= PICKED`, `< RESERVED` comparisons. Renumbering constants in `WmsConstants.State` silently breaks these. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §7 item 4.

---

## 11. How to debug

| Symptom | Start here |
|---|---|
| "Picking order stuck in PICKED, never progresses" | §4 cascade map + §10 item 3 (non-mobile terminal writer) |
| "Order cancelled but Pickingorder still PROCESSABLE" | §6 rapid-pick side-door + §10 item 2 |
| "OMS says it never got picking notification" | §8 + `message` / `message_archived` tables + §10 item 6 |
| "Unexpected pick order appeared" | §7 merge pass |
| "Operator can't finish pick — validation error" | §5 guard table |
| "Replica A fires release, Replica B fires again" | advisory lock [wms2-scheduled-jobs-catalog.md](../architecture/wms2-scheduled-jobs-catalog.md) §2 |
| "Optimistic lock storm during burst picking" | [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8 + archive `260401-replenish-stockunit-optimistic-lock-debug-plan` |

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-11-11 | **Full-doc re-verification, §1-§10.** Every method name, line anchor, sysprop gate, state write, lock order, OMS-callback producer, and the §9.1 comparator tiers, against `src/main` at origin/develop `df30fa62`. | **Corrections:** `finalizePicking` never existed (§4 rebuilt on `finishPickingOrder` + `confirmPick`; sections 1-5, 9, 10 renamed); §1 on-demand entry point (`/v3/adminAction/triggerOrderReplenish`, not clubLine/`/v3/orders`) and the false claim that both paths converge on `releaseOrder`; release stream is `co.state < ASSIGNED`, not ASSIGNED; `releaseOrder` writes CO positions to `ASSIGNED` (not `PROCESSABLE`), batch → `STARTED`; lock is taken before the sysprop gate; mobile flow (§3 diagram, §5 table: `reserveOrder`/`startPicking`/`finishPicking` do not exist, `selectAndReservePickingOrder` has no `src/main` caller); §5 guard-table line anchors; §6 (no `handleRapidPickingForCancelledOrder`, guard also needs `CO.state==ASSIGNED`, arm documented dead); §8 producer lists + SBDEV-3556 actor; §9.1 depth tier + CycleCount conventions (`fd91922a`); §10 item 3 (four terminal writers), item 8 anchors and counts (nine call sites, `finalizePickingOrderIfTerminal` nulls `operator_id`). **Confirmed unchanged:** SBDEV-2045 §7 cart-fill text, SBDEV-3865 §5 note, merge-pass anchors (`PickingOrderMergeService:127/161`), release-expired job predicate and `40 * * * * *` cron, `PICK_TIME_OUT_SYSTEM_ACTIVATED` default `false`, `PICKING_BOX_PER_CART` default `6`, `MERGE_PICKING_ORDERS` default `true`, §9.1 test names. **Not re-derived:** the live-data measurements in §10 item 8 (2026-09-08), the state-machine catalog §5.5/§7 cross-references (that doc was corrected the same day). *Method:* Code read on origin/develop `df30fa62` + `git log --since=2026-09-06` on the picking surface | doc-drift pass, 2026-11-11 |
| 2026-11-04 | SBDEV-2045: §2 flow line and §7 release-time cart fill ✓ merged(SBDEV-2045: #621 689334e2, 2026-11-05); §7 donor-cancel line corrected (cancel happens on success, not on failure). Nothing else re-derived; `last_verified` NOT bumped | Code read of branch `feature/SBDEV-2045-fill-open-cart-at-release` + `PickingOrderMergeService` on origin/develop 3b77a3c0 | SBDEV-2045 executor |
| 2026-10-22 | SBDEV-3865: §5 note — the rapid endpoints, processPick, reset and release judge the stored pick line; confirmPick's picking-order-first lock and three new refusals. ✓ merged(SBDEV-3865: #558 bafa2301, 2026-10-22). Nothing else re-derived | Code read of the SBDEV-3865 branch (`fix/SBDEV-3865-picking-trusts-posted-position`) plus its unit tests and PG IT |
| 2026-08-29 | **New §9.1 — pick-path ordering** (SBDEV-3133, wms2-api PR #233, merged 2026-08-29). The four tiers, the three comparators sharing `LocationPathOrdering`, and the cyclic-relation explanation. | Tier logic read directly from `LocationPathOrdering.compareResolved` on `origin/develop`; all three comparators confirmed delegating to it. The worked cycle (rack ordinals 9 / 2 / 5) matches `LocationPathOrderingUnitTest.mixedFixture()` exactly. ⚠ **Correction made during verification:** an earlier draft of §9.1 said that test *"reproduces it against the pre-fix comparators"* — it does not. It asserts `isAntisymmetric` / `is transitive for every triple` against the **fixed** comparators, i.e. it is a regression guard, not a reproduction. Text corrected. **Scoped check — the rest of the doc was NOT re-verified.** | Code + test read on `origin/develop` |
| 2026-04-19 | `PickingorderBusinessService.finalizePicking` (lines 238-568) + all mobile guards (lines 222-340) + release job release path + merge service + rapid-pick side-door | All file:line refs confirmed against `src/main/java` | Code read + state-machine / transaction architecture docs |
| 2026-05-08 | Group P verification follow-up (commits da64cc0, 99340b0, 4430824, 892169b, 930be52, b68cbbf, d61040c). Re-confirmed `ReleaseOrderJobService.releaseOrder` pessimistic lock at line 107, `findByIdForUpdate` sites in `MobilePickingService` (4 sites incl. line 400 in `processPick` per the Group-P lock-ordering note in the file), `PickingOrderMergeService.saveAll` at lines 194/198 (state writes still at 127 / 161). `finalizePicking` write sites shifted +1 (line 451/464/485 etc.) and §4 table was rebumped to current line numbers. §6 rapid-pick guard cite updated from `645` to `639` (guard) + `645` (state write). | Code read of v2/wms2-api at HEAD |
| 2026-06-01 | SBDEV-2381: `confirmPick` now skips the `PICKING_STARTED` outbox enqueue when the CO already advanced (`state ≥ PICKED` OR `pickingconfirmationsent`), snapshot taken before `setState(STARTED)`. §8 note added. | Confirmed against `PickingorderBusinessService.confirmPick` (PR #35, commits 567fba3 + 41ad7d3) | Code read (grep-based) |
| 2026-07-10 | SBDEV-2512 (v1→v2 port of 30a6ca4): added the overstock `partitionallowed` hold-or-single-pick guard note to §2 and the `rollbackFor` clause to the §9 `releaseOrder` transaction boundary. | Code read of `ReleaseOrderJobService.releaseOrder` on branch `port/SBDEV-2512-partitionallowed-guard` | SBDEV-2512 v2 port |

**Re-verify every 60 days.** Next due: **2027-01-10** — picking is the most change-prone surface; a single PR to `finishPickingOrder` or `confirmPick` invalidates §4.
