---
title: "WMS v1 — Picking Workflow"
type: workflow
status: active
version: v1
scope: picking
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-07-09
verified_by: code read of v1/wms-api src/main — all four picking services + mobile service + controllers
related:
  - ./wms2-picking-workflow.md
tags:
  - workflow
  - picking
  - wms1
---

## TL;DR

- Describes the end-to-end picking lifecycle in `v1/wms-api`: order release → picking order creation → assign/reserve → pick confirmation → finish, across four services (`PickingorderService`, `PickingorderPositionService`, `PickingorderBusinessService`, `MobilePickingService`).
- Two picking modes: Regular (TOTES_ON_CART — tote-per-position scan) and Rapid Pick (RAPID_PICKING — scan LPN first, then source location; no tote assignment step).
- State sequence (Integer): `RAW(0) → ASSIGNED(200) → PROCESSABLE(300) → RESERVED(400) → STARTED(500) → PICKED(600) → FINISHED(700)`; `CANCELED(800)` is terminal. `RESERVED` is v1-only (absent in v2).
- Core transaction is `PickingorderBusinessService.confirmPick`: pessimistically locks `Customerorder` then `Pickingorder`, releases stock reservation via `changeReservedAmount`, transfers stock to tote via `transferStockToUnitLoad`, sets `entityLock=PICKED_FOR_GOODSOUT(100)`, then rolls up position/order/picking-order states.
- `MobilePickingService.processPick` is the mobile orchestration entry point — handles tote assignment and delegates to `confirmPick`; over 1000 lines, grep before reading.
- No JPA association annotations — all FK relationships are `Long` fields resolved by explicit repository lookups.
- Read this doc before touching any pick confirmation, tote assignment, stock reservation release, or picking-state rollup bug or feature.

# WMS v1 — Picking Workflow

**Scope:** End-to-end picking flow in `v1/wms-api` — from a released customer order through pick confirmation to finalized state · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26

---

## 1. Overview & Actors

Picking in v1 is split across four services that interact in a strict call chain:

| Service | File | Role |
|---|---|---|
| `PickingorderService` | `service/PickingorderService.java` (71 lines) | Entity factory — generates a picking order shell with a unique number |
| `PickingorderPositionService` | `service/PickingorderPositionService.java` (160 lines) | Creates individual pick lines; fixes broken stock assignments |
| `PickingorderUnitloadService` | `service/PickingorderUnitloadService.java` (49 lines) | Creates the `PickingorderUnitload` record linking a tote to a picking order |
| `PickingorderBusinessService` | `service/PickingorderBusinessService.java` (410 lines) | All state transitions: start, confirm per-pick, finish order |
| `MobilePickingService` | `service/mobile/MobilePickingService.java` (1032 lines) | Mobile operator orchestration — reserve, resume, process tote scan, process pick, rapid-pick flow |

**Two picking modes** are in use:

- **Regular (TOTES_ON_CART)**: operator scans a picking order barcode, is presented a sorted position list, scans a tote per position, confirms each pick. Desktop web UI and mobile UI both interact via `PickingController` at `/v3/picking`.
- **Rapid picking (RAPID_PICKING)**: operator scans the parcel/package label (LPN) first, then scans the source location/unit load. No tote assignment step. Driven by `MobilePickingService.rapidPickingScanPackage` + `rapidPickingScanSource`.

**Desktop path** (`wms-web-ui`): calls the same `PickingController` endpoints. The desktop picks use `processLocation` to validate the source scan, then `processPick` to confirm.

**Mobile path** (`wms-mobile-ui`): calls the same controller. Entry point differs for rapid pick (`processRapidPickScanPackage` / `processRapidPickScanSource`).

---

## 2. Entity Cast

| Entity | Role | State field |
|---|---|---|
| `Customerorder` | Order being fulfilled | Integer `state` |
| `CustomerorderPosition` | One SKU line of the order | Integer `state` |
| `Pickingorder` | Work package for one picking operation | Integer `state` |
| `PickingorderPosition` | One pick instruction (from location, amount, to tote) | Integer `state` |
| `PickingorderUnitload` | Tote/carton being filled; links `Pickingorder` ↔ `Unitload` | Integer `state` |
| `Stockunit` | Quantity + reserved amount at a location | — (no state) |
| `Unitload` | Physical tote or pallet holding stock | — (no state) |

No JPA association annotations exist — all FK relationships are `Long foreignKeyId` fields resolved by explicit repository lookups.

---

## 3. State Constants (`WmsConstants.State`)

| Constant | Value | Meaning in picking context |
|---|---|---|
| `RAW` | 0 | Order received, not yet eligible for release |
| `RAW_ON_HOLD` | 50 | Release blocked (various sub-codes 55–58) |
| `FUTURE_PICKING_DATE` | 80 | Release deferred by date |
| `ASSIGNED` | 200 | Order assigned; picking order being built |
| `PROCESSABLE` | 300 | Picking order ready to claim; positions created |
| `RESERVED` | 400 | Picking order claimed by an operator (v1-specific — absent in v2) |
| `STARTED` | 500 | First pick confirmed; operator actively picking |
| `PENDING` | 550 | Partially fulfilled; waiting for more stock allocation |
| `PICKED` | 600 | All physical work done; order-level rollup pending |
| `FINISHED` | 700 | Terminal success state |
| `CANCELED` | 800 | Terminal canceled state |

---

## 4. Order Release → Picking Order Creation

**Entry points:**

- **Scheduled**: `ReleaseOrderJobService.releaseOrder(orderId, fixAssignmentMap, availableAmountMap)` — called by the order release cron job (gated by `app.cron=true`).
- **On-demand**: admin endpoints and REST order import trigger the same `releaseOrder` path synchronously.

**`ReleaseOrderJobService.releaseOrder` flow** (`service/job/ReleaseOrderJobService.java:73`):

1. Iterates each `CustomerorderPosition` on the order.
2. Evaluates fixed-location assignments and available stock. If stock is insufficient the position is set to a `RAW_ON_HOLD_*` sub-state (lines 128–442) and the order reverts to `RAW_ON_HOLD` (line 442).
3. When all positions can be fulfilled:
   - Calls `PickingorderService.create()` (line 463) to produce a new `Pickingorder` shell with a unique "PICK"-prefixed number.
   - Sets `Pickingorder.state = PROCESSABLE` (line 465) and saves.
   - For fixed-assignment positions (L473) calls `stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, orderPosition.getAmount(), false, CODE_CREATE_PICK_POSITION, …)` and **rebinds `stockUnit` to the return value** (260427 fix — the input reference is detached after the call; reading `getAvailableamount()` from the stale snapshot would cause over-allocation).
   - For each releasable position calls `PickingorderPositionService.createPickingPosition(amount, stockUnit, orderPosition, pickingOrder)` (lines 477, 498, 522, 530).
   - Sets each `CustomerorderPosition.state = ASSIGNED` (lines 480, 500, 516).
   - Sets `Customerorder.state = ASSIGNED` (line 547).
   - If an `OrderBatch` is present, advances batch state to `STARTED` (line 550–551).

> **SBDEV-2512 (reinstated 2026-07-09, PR #194) — `partitionallowed` guard in overstock release.** When the `ENFORCE_PARTITIONALLOWED` sysprop is ON (default), a `CustomerorderPosition` with `partitionallowed = false` must be filled from a **single** stock unit. In phase 2 a cumulative per-order per-SKU ledger (`reserveSingleCoveringUnit`) checks whether one unit can still cover the amount after prior same-SKU admissions; if not, the position is held (`RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` → order `RAW_ON_HOLD`) instead of being fragmented across source unit loads. In phase 3 a non-partitionable position takes exactly one pick from a single covering unit (no greedy split). Set the sysprop `false` to restore the legacy fragment-and-ship behavior. **Line numbers above predate SBDEV-2512 — grep before trusting them.**

**`PickingorderService.create()`** (`service/PickingorderService.java:32`):
- Loops up to 10 000 times generating a candidate number via `BasicService.generatePickOrderNumber()`, checking uniqueness via `PickingorderRepository.findByNumber`.
- Creates `Pickingorder` with `entityLock=0`, assigns system client, saves and returns.

**`PickingorderPositionService.createPickingPosition()`** (`service/PickingorderPositionService.java:49`):
- Resolves the source unit load and storage location from the `Stockunit`.
- Creates `PickingorderPosition` with:
  - `pickingorderId`, `customerorderpositionId`, `itemdataId`, `amount`
  - `pickfromstockunitId` — the specific stock unit to pick from
  - `pickfromlocationname`, `pickfromunitloadlabel` — denormalized location info for display
  - `state = PROCESSABLE`

---

## 5. Picking Order Assignment Workflow

After creation the `Pickingorder` sits in `PROCESSABLE`. An operator claims it via the mobile or desktop UI.

**Reserve path** — `MobilePickingService.selectAndReservePickingOrder(pickingOrderID)` (line 116):
1. Locks the row with `findByIdForUpdate`.
2. Delegates to `processPickingOrderForStart(pickingOrder)` (line 128).

**Resume path** — `MobilePickingService.resumePickingOrderIfExists()` (line 133):
- Queries `findByOperatorAndStates(userId, RESERVED, FINISHED)` — finds any order the user already owns.
- For `RAPID_PICKING` sections: immediately releases the lock (`lockedtooperator=false`, `operatorId=null`) and returns null.
- For `TOTES_ON_CART` sections: routes back through `processPickingOrderForStart`.

**`processPickingOrderForStart(pickingOrder)`** (line 281):

| Condition | Action |
|---|---|
| `state < RESERVED` and `state >= PICKED` | Throws `FacadeException("PICK_ALREADY_STARTED")` |
| `state < RESERVED` and `state >= RESERVED` and same user | Throws `FacadeException("ORDER_RESERVED")` |
| `state < RESERVED` (normal case) | Sets `operatorId = currentUser`, `state = RESERVED` (line 303) |
| `state >= RESERVED` and different user | Throws `BusinessException("Picking Order reserved by different user!")` |
| All positions already `>= PICKED` | Sets order `state = PICKED`, calls `finishPickingOrder`, returns null |
| `sectionPickingType == RAPID_PICKING` | Releases lock, returns null (rapid pick uses its own flow) |
| Normal | Saves and returns the reserved picking order |

**`startPickingOrder(pickingOrder)`** (line 243):
- Called explicitly (e.g. from `getPickingOrderPositionsInfo` at line 611) when positions are loaded.
- If `state < PICKED`: calls `PickingorderBusinessService.startPickingOrder` (line 249) — sets `operatorId` from current user, sets `state = STARTED` (line 87), saves.
- If all positions already `>= PICKED`: immediately calls `finishPickingOrder`, returns null.

---

## 6. Pick Confirmation — Desktop Path

The desktop UI (`wms-web-ui`) drives picking through two sequential calls:

**Step 1 — Load positions:** `GET /v3/picking/pickingOrderPositionsInfo/{id}`
- Controller calls `MobilePickingService.getPickingOrderPositionsInfo(id)` (line 600).
- Locks the order row, calls `startPickingOrder` if needed, sorts positions by physical location (rack/row strategy), returns a list of maps with `id`, `pickFromLocation`, `pickFromUnitLoad`, `pickAmount`, `pickStatus`, `skuName`, `skuNumber`, `pickUnit`, `pickToUnitLoad`.

**Step 2 — Validate source location:** `GET /v3/picking/processLocation/{id}/{input}`
- Controller calls `MobilePickingService.processLocation(positionId, locationName)` (line 673).
- Resolves `pickfromstockunitId` → `Unitload` → `Location` and compares to the scanned input. Throws `BusinessException("Location not valid. Scan again.")` on mismatch.

**Step 3 — Confirm pick:** `POST /v3/picking/processPick` with `{ orderId, orderPositionId, toteName }`
- Controller validates `isToteLabel(toteName)`, then calls `MobilePickingService.processPick(order, orderPosition, toteName)` (line 342).
- See §8 for `processPick` detail.

---

## 7. Pick Confirmation — Mobile Path (Regular)

Mobile UI (`wms-mobile-ui`) uses the same controller endpoints but a different screen flow:

**Step 1 — Claim order:** `GET /v3/picking/pickingOrders/{input}` → list of available orders.

**Step 2 — Select and reserve:** calls `selectAndReservePickingOrder` or `resumePickingOrderIfExists` via the controller.

**Step 3 — Load positions:** `GET /v3/picking/pickingOrderPositionsInfo/{id}` — same as desktop.

**Step 4 — (Optional) Validate location:** `GET /v3/picking/processLocation/{id}/{input}`.

**Step 5 — Confirm pick:** `POST /v3/picking/processPick` with `{ orderId, orderPositionId, toteName }` — same endpoint as desktop, same `processPick` logic.

---

## 8. `MobilePickingService.processPick` — Tote Assignment + Pick Confirmation

`processPick(pickingOrder, pickingPosition, toteName)` (line 342, `@Transactional`):

**1. Re-read entities** (line 347–348): re-fetches both `Pickingorder` and `PickingorderPosition` within the TX to get managed copies with current optimistic-lock versions.

**2. Operator ownership check** (line 352): if `operatorId != null && operatorId != currentUser`, throws `BusinessException("Parcel already assigned to user …")`.

**3. Position integrity check** (line 358): if `getPickingorderPositionsById(positionId)` returns issues, calls `PickingorderPositionService.fixPickingPosition(position)` to reassign stock (see §11).

**4. Tote assignment** (lines 375–476) — only when no `PickingorderUnitload` is yet assigned to this position:
- Resolves `emptyTotesLocation` (`STORAGE_LOCATION_EMPTY_TOTES`).
- If tote does not exist: creates it via `UnitloadService.createUnitload`.
- If tote exists: validates it is at `emptyTotesLocation`, has no stock, and is not still bound to an in-flight order (state `< FINISHED`).
- Calls `PickingorderUnitloadService.create(pickingOrder, tote)` — creates the `PickingorderUnitload` record.
- Moves tote to user location: `UnitloadBusinessService.transferUnitLoadToLocation(tote, userLocation, …)`.
- Sets `Customerorder.pickingtoteId` and `historytote`.
- Registers after-commit callback to fire `ManageOrderService.customerOrderToteAssigned` (OMS notification).
- Propagates `picktounitloadId` to all positions on the same customer order in this picking order.
- Re-reads `pickingPosition` to get the version-bumped instance (line 464).

**5. Confirm pick** (line 478): calls `PickingorderBusinessService.confirmPick(pickingPosition, pickingUnitLoad, pickingPosition.getAmount())`.

**6. Terminal check** (lines 480–488): if `pickingOrder.state == PICKED` calls `finishPickingOrder`; if `state > PICKED` returns null directly.

---

## 9. `PickingorderBusinessService.confirmPick` — The Core Pick Transaction

`confirmPick(pickingPosition, pickingUnitLoad, amountPicked)` (line 223, `@Transactional`):

**Guards** (lines 226–245):
- `pickingPosition.state >= PICKED` → `FacadeException("PICK_ALREADY_FINISHED")`
- `pickfromstockunitId == null` → `FacadeException("PICK_CONFIRM_NO_STOCK")`
- `amountPicked <= 0` → `FacadeException("AMOUNT_MUST_BE_GREATER_THAN_ZERO")` / `PICK_CONFIRM_NOT_PICKED_COUNTED`
- `pickingUnitLoad == null` → `FacadeException("PICK_CONFIRM_MISSING_UNITLOALD")`

**Lock ordering** (lines 250–259): acquires pessimistic lock on `Customerorder` first (`findByIdForUpdate`), then on `Pickingorder` — prevents concurrent "last pick" transactions from both skipping parent-state promotion.

**Unit load cross-check** (lines 261–266): verifies `pickingUnitLoad.pickingorderId == pickingOrder.id`; throws `FacadeException("PICK_CONFIRM_WRONG_UNITLOAD")` otherwise.

**Stock movement** (lines 268–301):
1. `StockunitBusinessService.changeReservedAmount(stockUnit, amount.negate(), true, CODE_PICKING, …)` — releases the reservation on the source stock unit; returns the managed re-attached instance.
2. Checks if the source unit load is on a carrier pallet.
3. `StockunitBusinessService.transferStockToUnitLoad(stockUnit, puUnitLoad, amountPicked, …)` — moves stock to the pick-to unit load.
4. If the carrier pallet is now empty: `UnitloadBusinessService.sendToNirvana(pallet, CODE_PICKING_CARRIER_EMPTY, …)`.
5. Sets `pickToStock.entityLock = PICKED_FOR_GOODSOUT` (lock state 100).

**Position state update** (lines 303–308):
- `pickingPosition.state = PICKED`
- `picktounitloadId` set, `amountpicked` set, `pickfromstockunitId` nulled, `pickedbyoperatorId` set.

**Customer order position rollup** (lines 310–333):
- Adds `amountPicked` to `CustomerorderPosition.amountpicked`.
- If `amountpicked >= amount` → `customerOrderPosition.state = PICKED`.
- If partially filled: checks remaining open picks; if any open picks → `STARTED`; if no open picks → `PENDING`.

**Customer order state rollup** (lines 337–388):
- If `customerOrder.state < STARTED` → promotes to `STARTED`; registers after-commit OMS callback `customerOrderPickingStarted` (status 24).
- After the position save: walks all positions. If every position is `>= PENDING`:
  - If any are exactly `PENDING` → `customerOrder.state = PENDING`.
  - If all are `>= PICKED` (none `PENDING`) → `customerOrder.state = PICKED`.

**Picking order state update** (lines 391–405):
- If `pickingOrder.state < STARTED` → calls `startPickingOrder` (sets operator, state = `STARTED`).
- If `pickingUnitLoad.state < STARTED` → `pickingUnitLoad.state = STARTED`.
- If all positions on the picking order are `>= PICKED` and order `state < PICKED` → `pickingOrder.state = PICKED`.

**Returns** the updated `Pickingorder`.

---

## 10. `PickingorderBusinessService.finishPickingOrder` — Order Finalization

`finishPickingOrder(pickingOrder)` (line 101):

**Guard**: if `state >= FINISHED` throws `FacadeException("ORDER_ALREADY_FINISHED")`.

**Per-position processing** (lines 117–205):
- If any position has `state < PICKED` → throws `BusinessException` (cannot finish with open picks).
- Determines `orderState`: starts as `CANCELED`; flips to `FINISHED` if any position is `PICKED` and not `CANCELED`.
- For each position's parent `Customerorder`:
  - Skips if already processed (de-duplicated by `processedOrderIds`).
  - If `markedforcancellation`: calls `CustomerorderService.cleanUpCancelledOrder`.
  - If not canceled and production mode:
    - Sets `customerOrder.pickingconfirmationsent = true` optimistically.
    - Registers after-commit callback → `ManageOrderService.customerOrderPicked` (OMS status 25). The deferred registration ensures status 25 fires **after** any earlier-registered status 24 callback, preventing the race condition where 24 overwrites 25 on OMS.
    - Falls back to synchronous OMS call if TX synchronization is not active (admin/non-transactional context).
  - Tote transfer: if `pickingtoteId` is set and the `PickingorderUnitload` is not yet `PICKED`, calls `UnitloadBusinessService.transferUnitLoadToLocation(unitLoad, finishedPickingLocation, …)` and sets `pickingUnitLoad.state = PICKED`.

**Sets** `pickingOrder.state = orderState` (FINISHED or CANCELED), saves, and returns.

---

## 11. Rapid Pick Path

For `RAPID_PICKING` sections the operator never claims an order explicitly — they scan the parcel LPN first.

**Step 1 — Scan package:** `GET /v3/picking/processRapidPickScanPackage/{section}/{input}`
- Controller calls `MobilePickingService.ProcessRapidPickingScanPackage(packageName, sectionName)`.
- `rapidPickingScanPackage(packageName, section)` (line 701):
  - Validates input is a parcel label (`isParcelLabel`).
  - Queries `pickingorderRepository.getForRapidPickingScanPackage(packageName, CANCELED)` — finds a `PROCESSABLE` picking order for this LPN.
  - Validates order is `< PICKED`, belongs to the requested section.
  - Checks operator lock: if `lockedtooperator && operatorId != currentUser` → throws.
  - Sets `operatorId = currentUser`, `lockedtooperator = true`, saves.
  - Returns the first `PickingorderPosition` with `state < PICKED`.

**Step 2 — Scan source:** `POST /v3/picking/processRapidPickScanSource` with `{ pickingPositionId, source }`
- Controller calls `MobilePickingService.ProcessRapidPickingScanSource(pickingPosition, source)`.
- `rapidPickingScanSource(pickingPosition, source)` (line 798, `@Transactional`):
  - Verifies operator owns the order (`lockedtooperator == true && operatorId == currentUser`).
  - Resolves `source` as a `Unitload` label or location name fallback.
  - Validates: unit load not locked, on a pickable area (`locationArea.useforpicking == true`), stock unit not locked, stock is unique on the unit load.
  - Sets `pickingOrder.pickinginprogress = true`.
  - Compares scanned stock unit to the position's `pickfromstockunitId` — throws if wrong source.
  - Calls `PickingorderBusinessService.confirmPick(pickingPosition, pickingorderUnitload, amount)`.
  - If more positions remain `< PICKED`: returns DTO with next position and `pickCompleted = false`.
  - If `pickingOrder.state == PICKED`: calls `finishPickingOrder`, clears `lockedtooperator`, `pickinginprogress`, returns DTO with `pickCompleted = true`.

**Step 2 (pass variant) — Scan source pass:** `POST /v3/picking/processRapidPickScanSourcePass`
- Handles the case where the operator confirms the position without a source scan (pass-through). Calls `rapidPickingScanSource` via `ProcessRapidPickingScanSource`.

---

## 12. Unit Load Handling

`PickingorderUnitloadService.create(pickingOrder, unitLoad)` (line 22):
- Creates a `PickingorderUnitload` with:
  - `pickingorderId`, `unitloadId`, `clientId`
  - `positionindex = -1` (unordered)
  - `historytote = unitLoad.labelid` — preserved for history even if the tote is later reallocated
  - `entityLock = 0`
- The record is the pivot between a `Pickingorder` and the physical tote being filled.

`PickingorderUnitloadService.getByLabel(label)` (line 40):
- Looks up a `PickingorderUnitload` by the underlying unit load's `labelid`.

Tote location lifecycle during picking:
1. Tote starts at `STORAGE_LOCATION_EMPTY_TOTES`.
2. On first scan: `transferUnitLoadToLocation(tote, userLocation, …)` moves it to the operator's named location.
3. On `finishPickingOrder`: `transferUnitLoadToLocation(unitLoad, finishedPickingLocation, …)` moves it to `STORAGE_LOCATION_FINISHED_PICKING` and sets `PickingorderUnitload.state = PICKED`.

---

## 13. Position Completion and Order Finish

**`PickingorderPositionService.fixPickingPosition(position)`** (line 77, `@Transactional`):
Called automatically by `processPick` when `getPickingorderPositionsById` returns issues (stock mismatch).

1. Resolves a replacement stock unit — prefers the fixed-location assignment for the item; otherwise scans `getStockUnitsByItemDataId` for any unit load with sufficient available amount.
2. Unreserves the original stock unit (if different from replacement).
3. Reserves the replacement.
4. Updates `position.pickfromstockunitId`, `pickfromunitloadlabel`, `pickfromlocationname`.

**Order completion cascade** (all initiated from `confirmPick`):

```
confirmPick()
  ├─ pickingPosition.state = PICKED
  ├─ customerOrderPosition.state = PICKED | STARTED | PENDING
  ├─ customerOrder.state = STARTED  (first pick, via afterCommit OMS status 24)
  ├─ customerOrder.state = PENDING | PICKED  (all positions accounted for)
  ├─ pickingOrder.state = STARTED  (via startPickingOrder if not yet started)
  ├─ pickingUnitLoad.state = STARTED
  └─ pickingOrder.state = PICKED  (when all positions >= PICKED)
       └─  processPick() detects PICKED → calls finishPickingOrder()
             ├─ pickingUnitLoad.state = PICKED  (tote moved to FINISHED_PICKING)
             ├─ customerOrder.pickingconfirmationsent = true
             ├─ afterCommit → ManageOrderService.customerOrderPicked()  (OMS status 25)
             └─ pickingOrder.state = FINISHED | CANCELED
```

---

## 14. State Transitions — Method:Line Reference

| Entity | From → To | Service method | Line |
|---|---|---|---|
| `Pickingorder` | (new) → `PROCESSABLE` | `ReleaseOrderJobService.releaseOrder` | :465 |
| `PickingorderPosition` | (new) → `PROCESSABLE` | `PickingorderPositionService.createPickingPosition` | :68 |
| `Customerorder` | — → `ASSIGNED` | `ReleaseOrderJobService.releaseOrder` | :547 |
| `Pickingorder` | `PROCESSABLE` → `RESERVED` | `MobilePickingService.processPickingOrderForStart` | :303 |
| `Pickingorder` | `RESERVED` → `STARTED` | `PickingorderBusinessService.startPickingOrder` | :87 |
| `PickingorderPosition` | `PROCESSABLE` → reset | `MobilePickingService.releasePickingOrder` | :219 |
| `Pickingorder` | any → `PROCESSABLE` (release) | `MobilePickingService.releasePickingOrder` | :229 |
| `Customerorder` | `<STARTED` → `STARTED` | `PickingorderBusinessService.confirmPick` | :342 |
| `CustomerorderPosition` | — → `PICKED` / `STARTED` / `PENDING` | `PickingorderBusinessService.confirmPick` | :322–333 |
| `Customerorder` | `STARTED` → `PENDING` / `PICKED` | `PickingorderBusinessService.confirmPick` | :380–385 |
| `PickingorderPosition` | `PROCESSABLE` → `PICKED` | `PickingorderBusinessService.confirmPick` | :303 |
| `PickingorderUnitload` | — → `STARTED` | `PickingorderBusinessService.confirmPick` | :397 |
| `Pickingorder` | `STARTED` → `PICKED` | `PickingorderBusinessService.confirmPick` | :403 |
| `PickingorderUnitload` | `STARTED` → `PICKED` | `PickingorderBusinessService.finishPickingOrder` | :196 |
| `Pickingorder` | `PICKED` → `FINISHED` / `CANCELED` | `PickingorderBusinessService.finishPickingOrder` | :207 |
| `Pickingorder` | `STARTED` → `PICKED` (rapid) | `MobilePickingService.rapidPickingScanSource` | :898 |
| `Pickingorder` | `PICKED` → cleared flags | `MobilePickingService.rapidPickingScanSource` | :900–902 |

---

## 15. OMS Callback Touchpoints

All OMS calls are deferred to post-commit via `TransactionSynchronizationManager.registerSynchronization`. A WMS rollback silently drops the callback. Use the `message` / `message_archived` tables to verify delivery.

| OMS event | Fired from | Trigger condition |
|---|---|---|
| Tote assigned (status ?) | `MobilePickingService.processPick:440` | First tote scan for an order |
| Picking started (status 24) | `PickingorderBusinessService.confirmPick:346` | `Customerorder.state` first reaches `STARTED` |
| Order picked (status 25) | `PickingorderBusinessService.finishPickingOrder:158` | `finishPickingOrder` completes for non-canceled order |

**Race condition guard** (SBDEV-2102 follow-up): `confirmPick` registers the status 24 callback; `finishPickingOrder` registers the status 25 callback. Because both run in the same outer TX, `TransactionSynchronizationManager` fires them in registration order, ensuring 24 always precedes 25.

The fallback synchronous OMS call in `finishPickingOrder` (line 169) fires only in non-transactional contexts (e.g., admin controller invocation). It logs an error when it triggers.

---

## 16. Common Failure Modes

| Symptom | Where to look |
|---|---|
| "Pick confirm fails with PICK_CONFIRM_NO_STOCK" | `PickingorderPosition.pickfromstockunitId` is null — the position was never fixed after stock moved. Call `fixPickingPosition` via `GET /v3/pickingOrderPosition/fixPickingPosition/{id}` |
| "Picking order stuck in PROCESSABLE, not RESERVED" | `processPickingOrderForStart` guard: section is `RAPID_PICKING` — those orders never get `RESERVED`; they go directly from `PROCESSABLE` to locked-to-operator in `rapidPickingScanPackage` |
| "Picking order stuck in PICKED, never finishes" | `finishPickingOrder` not called — check `processPick` terminal check (line 480) and `startPickingOrder` (line 266). May also be a position with `state < PICKED` that was not detected by the `allPicksDone` stream check |
| "OMS never received status 25" | Check `basicService.isProduction()` — returns false in non-prod; check `message` table for a row; check for TX rollback after the afterCommit registration |
| "Tote rejected — 'not on empty totes location'" | Tote was not returned to `STORAGE_LOCATION_EMPTY_TOTES` after previous use |
| "Tote rejected — still bound to in-flight order" | `getOrderByToteLabelId` found an order with `state < FINISHED` (600). Tote was used for a PICKED order that hasn't yet been packed. Do not null `pickingtoteId` on PICKED orders |
| "Optimistic lock error during processPick" | Position version bumped by the tote-assignment loop before `confirmPick` — fixed by re-read at line 464. If recurring, check for concurrent processPick calls on the same position |
| "Parcel already assigned to user X" | `Pickingorder.operatorId` is set to a different user. Release via `GET /v3/picking/releasePickingOrder/{id}` (calls `releaseRegularPickingOrder`) |
| "No picks left for parcel" (rapid pick) | All positions already `>= PICKED` but `finishPickingOrder` was not called — the TODO at `rapidPickingScanPackage:774` marks this as unimplemented |

---

## 17. Key Differences from v2

| Aspect | v1 | v2 |
|---|---|---|
| Reserved state | `RESERVED` (400) exists — operator explicitly claims order | No `RESERVED` state — `reserveOrder` goes straight to operator binding |
| Finalization method | `finishPickingOrder` in `PickingorderBusinessService` | `finalizePicking` in `PickingorderBusinessService` (single 5-entity cascade) |
| Picking order merge | Not present | `ReplenishOrderJob.mergePickingOrders` for `TOTES_ON_CART` sections |
| Optimistic lock retry | No automatic retry — callers handle exceptions | `OptimisticLockRetry.executeWithRetry` wraps mobile flow |
| OMS callback registration | Manual `TransactionSynchronizationAdapter` | `omsNotificationService.sendAfterCommit` abstraction |
| Expired pick release job | No timeout release job for `TOTES_ON_CART` | `ReleaseExpiredPickingOrdersFromUserJob` for `RAPID_PICKING` |

---

## 18. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | All four picking services (full read) + `MobilePickingService` (full read, 1032 lines) + `PickingController` (full read) + `PickingOrderPositionController` (full read) + `ReleaseOrderJobService` (grep + targeted read) + `WmsConstants.State` constants | All file:line refs confirmed against `v1/wms-api/src/main/java` | Code read |

| 2026-07-09 | SBDEV-2512 impl in `ReleaseOrderJobService.releaseOrder` (phase-2 cumulative `partitionallowed` hold guard + `reserveSingleCoveringUnit`, phase-3 single-pick branch, `ENFORCE_PARTITIONALLOWED` kill-switch) — reinstated via PR #194 after the #192 revert | Re-added §4 SBDEV-2512 note; §4 numbered line refs predate this change (grep before trusting) | Code read (SBDEV-2512 impl) |

**Re-verify when any of these files change:** `PickingorderBusinessService.java`, `MobilePickingService.java`, `ReleaseOrderJobService.java`.
