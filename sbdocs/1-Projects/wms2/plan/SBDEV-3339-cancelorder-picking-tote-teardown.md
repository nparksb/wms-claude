---
title: "SBDEV-3339 (V2): cancelOrder success branch never tears down the picking tote"
ticket: "SBDEV-3339"
ticket_url: "https://app.clickup.com/t/868m4cb5j"
type: "bug"
priority: "high"
status: "implemented — PR #354 submitted 2026-09-14"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-14"
updated: "2026-09-14"
db_verified: true
related:
  - "../../../3-Resources/workflows/wms2-cancel-cascade-workflow.md"
  - "../../../2-Areas/runbooks/free-63-units-t0002-t0007.md"
  - "./SBDEV-3339-evidence/analysis-bundle.md"
  - "./SBDEV-3339-evidence/plan-review-architect.md"
  - "./SBDEV-3339-evidence/plan-review-critic.md"
tags: [plan, sbdev-3339, cancel, picking-tote, entity-lock, tdd-gate]
---

# SBDEV-3339 (V2): `cancelOrder` success branch never tears down the picking tote

**Ticket:** [SBDEV-3339](https://app.clickup.com/t/868m4cb5j) | **wms2/wms2-api** | v2 (Java 21 / Spring Boot 3.5.9) | Bug (data integrity) | **Tier T3** — data integrity, OMS-facing endpoint, stock with no operator path out.
**Graded ref:** `origin/develop` @ `221caed1`. The local checkout was 35 behind and was never read; every code claim was derived with `git show origin/develop:<path>` / `git grep … origin/develop`.
**Evidence:** [`SBDEV-3339-evidence/`](./SBDEV-3339-evidence/) — `analysis-bundle.md`, `db-evidence.md`, `enumeration.md`, `architect-consult.md`, and the two independent review reports (§14).

> **Citation form.** File + a distinctive quoted snippet. Line numbers in this repo drift; the snippet is the anchor.
> **Size.** Revision 2 is larger than revision 1's "~16 lines". Fix 1 is ~20 lines in one file, Fix 2 is one line, and Fix 3 is a new exception type + a wrap in the service + a scoped catch in the controller — **not** the "~8 lines in the controller" revision 1 claimed (§5.2).

## 0. Affected sites

From [`enumeration.md` §6](./SBDEV-3339-evidence/enumeration.md), amended by review.

| # | File | Construct | Same root-cause? | In scope? |
|---|---|---|---|---|
| 1 | `service/CustomerorderService.java` | `cancelOrder` success branch (`LOG.debug("cancelOrder: cancelling order positions")` → `setState(CANCELED)`) — no lock clear, no `pickingtote_id` null, no `sendToClearing`, no `historytote`, **no `pickingorder_unitload` retirement** | **Yes — this is the defect** | **Yes** |
| 2 | `service/CustomerorderBatchService.java` | `cancelBatch` — nulls `pickingtote_id` (`customerOrder.setPickingtoteId(null);` at `:506`) but never clears stock `entity_lock` and never relocates the tote | Yes, and worse | **No** — *proposed for deletion*, §5.4. No step below touches it |
| 3 | `service/CustomerorderService.java` | `forceCancelOrder` — clears tote lock + stock lock + nulls + `sendToClearing`, but does **not** retire `pickingorder_unitload` | Partial sibling, pre-existing gap | **Yes, one line only** (Fix 2, §5) — corrected 2026-09-14: this row previously read "No (read-only)", contradicting §5/§6/§7 which all direct Fix 2's null-safe guard change here. Its teardown *shape* is reference-only and must not be copied (§5 point 5); only the `GOING_TO_DELETE` comparison changes. See also §5.6 |
| 4 | `service/PickingorderBusinessService.java` | `cleanUpCancelledOrder` — the **only complete** teardown; two blocks, both required | No — reference implementation | No (read-only; **preserve the SBDEV-3316 ordering pin**) |
| 5 | `repo/jpa/PickingorderUnitloadRepository.java` | `findByUnitloadLabelid` — native join `a.unitload_id = b.id` returning `Optional`; *"blows up with `IncorrectResultSizeDataAccessException` once a tote has been used twice"* | The invariant Fix 1 must not break | Read-only; it is the reason for Fix 1 block 2 |
| 6 | `service/CustomerorderService.java` | rapid-pick sub-branch of `cancelOrder` — `sendToNirvana` + null, throws on a non-empty tote | No — empty-tote retire | No |
| 7 | `service/CustomerorderPositionService.java` | `cancelOrderPosition` — no tote teardown | No — position-level (AC-3) | No |
| 8 | `repo/jpa/CustomerorderRepository.java`, `service/BillofladingService.java` | `@Modifying updateStateByIds` (can write 800, invisible to a `setState` grep) and the bulk `entityManager.createQuery("UPDATE Stockunit s SET s.entityLock = :lock")` → `SHIPPED` | No | No — the two proven blind spots of this plan's greps (§12) |
| 9 | `service/StockunitService.java` | `removeLock` refuses `PICKED_FOR_GOODSOUT` (`OPERATOR_REMOVABLE = {QUALITY_FAULT, ON_HOLD}`) | No — but it is **why** there is no operator workaround | No — widening it is a security-shaped change |
| 10 | `sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md` | 8 false claims (D-1…D-8), incl. *"cancelBatch releases entity locks"* — asserts this defect is already fixed | Doc drift on the defect's own surface | **Yes** — D-1, D-2 in this PR |
| 11 | `sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md` | `BusinessObjectLockState` documented nowhere in `sbdocs/` | Doc gap | No — **propose** a doc ticket |

## 1. Problem and severity

Cancelling a **picked, not-yet-packed** order leaves its picking tote full of stock locked `PICKED_FOR_GOODSOUT` (100), still pointed at by `customerorder.pickingtote_id`, and physically still on the pick path. The tote can never be reused; the goods can never be moved.

**Measured on Hydra PRD** (`wh01_hydra_v2`, 2026-09-14, `psql` direct — the MCP servers were timing out): 7 `stockunit` rows at `entity_lock = 100`, on 2 totes (`T-0002`, `T-0007`), 63 units, from 2 cancelled orders five weeks apart. *Positive control:* `select count(*) from stockunit` → **804**, so the census is not reading an empty column. ([`db-evidence.md` §1-§2](./SBDEV-3339-evidence/db-evidence.md).)

**There is no operator path out.** `StockunitService.removeLock` refuses (`OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD }`, so 100 hits `default:` — *"Can't remove lock: this stock unit is Picked."*), and the lock also blocks the move an operator would try — `StockunitBusinessService.transferStockToUnitLoad`: `if (lock != …NOT_LOCKED) { throw new BusinessException("Source stockUnit=" + … + " is locked=" + lock); }`. The only routes out today are a DB edit ([`free-63-units-t0002-t0007.md`](../../../2-Areas/runbooks/free-63-units-t0002-t0007.md)) or this fix.

**It sits on the normal OMS cancellation path:** `POST /rest/order/cancelPositions` resolves the batch and loops `customerorderService.cancelOrder(customerOrder, false)`. Proven on PRD — 8 `message` rows with `process = 'ORDER_BATCH_CANCELLED_FROM_PSD'` **at status `RECEIVED`**, spanning both stranding dates; control 2066 message rows / 18 distinct processes. ⚠ The status qualifier is load-bearing: `cancelPositions` writes that same process on **both** exits — `MessageStatus.RECEIVED`/200 on success and `MessageStatus.FAILED`/400 in the `catch`, so a bare row count would not prove the cancels landed.

**Deterministic, not a race:** `customerorder_cancellation_log` on PRD is bimodal — 9 cancels at order state 200 / position 300 (no tote stock, harmless), **7 of 7** at position state **600 `PICKED`** stranded.

**Severity is higher than revision 1 stated** — see §3. On Hydra PRD the corrective branch is effectively unreachable, so this is not a narrow timing window: it is what happens to **every** cancel of a below-PACKED order that still holds a tote.

## 2. Root cause

`CustomerorderService.cancelOrder`, success branch (`orderCanBeCancelled == true`, identified by the log line `"cancelOrder: cancelling order positions"`), cancels the positions, sets state, saves, finalizes the batch and enqueues the OMS outbox row — and never touches the tote:

```java
LOG.debug("cancelOrder: cancelling order positions");
for (CustomerorderPosition customerOrderPosition : coPositions) { customerorderPositionService.cancelOrderPosition(customerOrderPosition); }
customerOrder.setState(WmsConstants.State.CANCELED);
…  customerorderRepository.save(customerOrder);  customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
```

**Four omissions, not three** (revision 1 listed three; the fourth was found by both review lanes):

| | clears stock `entity_lock` | nulls `pickingtote_id` | `sendToClearing(tote)` | sets `historytote` | retires `pickingorder_unitload` |
|---|---|---|---|---|---|
| `cancelOrder` success branch | ❌ | ❌ | ❌ | ❌ | ❌ |
| `forceCancelOrder` | ✅ (+ the tote's **own** lock) | ✅ | ✅ | ✅ | ❌ (pre-existing gap, §5.6) |
| `cleanUpCancelledOrder` | ✅ (stock only) | ✅ | ✅ | ✅ | ✅ |
| `packageOrder` (happy path) | n/a | ✅ | n/a | ✅ | ✅ (`FINISHED`) |

**Two invariants, not one.**

**(a) The lock.** `PickingorderBusinessService` mints it on pick confirm — `pickToStock.setEntityLock(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT);` — so **every path that ends an order without shipping owes a matching clear**. *Deriving method:* `git grep -n "PICKED_FOR_GOODSOUT" origin/develop -- 'src/main/**/*.java'` → 14 hits, filtered to assignments → 2, of which `CancellationReversalService`'s re-locks a residue it just cleared and is not an independent producer. *Blind spot, and it is real here:* a bulk/native write is invisible to a `setEntityLock` grep — `BillofladingService` writes `SHIPPED` only via `entityManager.createQuery("UPDATE Stockunit s SET s.entityLock = :lock …")`, which is how 328 of 804 PRD rows reach the DB. It happens not to write 100, so the producer count survives.

**(b) The `pickingorder_unitload` link.** **Every path that frees a tote for reuse nulls `pickingorder_unitload.unitload_id`.** `findByUnitloadLabelid` is a native query joining `a.unitload_id = b.id` and returning `Optional`; a row whose `unitload_id` is null cannot join, so nulling it is what keeps the `Optional` single-valued. The repository says so itself: *"Totes are reused, so a label accumulates one row per pick it has served. `findByUnitloadLabelid` above returns `Optional` and blows up with `IncorrectResultSizeDataAccessException` once a tote has been used twice (SBDEV-2742)."* *Deriving method:* `git grep -n "setUnitloadId(null)" origin/develop -- 'src/main'` plus a read of each tote-releasing method on the blob; it finds `packageOrder` and `cleanUpCancelledOrder` (*positive control:* both sites appear). *Blind spot:* a bulk/native `UPDATE pickingorder_unitload SET unitload_id = NULL`, or a Flyway/trigger write, would be invisible to any `src/main` grep — the same class of miss §12 records for `BillofladingService`.

**Measured on Hydra PRD 2026-09-14:** `pickingorder_unitload` = 162 rows; **exactly 2** carry a non-null `unitload_id` — precisely the two stranded totes (17662/T-0002, 37736/T-0007), both at state 600; the 160 rows at state 700 have it nulled; **zero** `unitload_id` values are shared by more than one row. *Positive control:* the 162-row total and the 160 nulled rows show the column and the census are both live. So invariant (b) holds on PRD today — and it holds **because** released totes get nulled.

⚠ **This is why Fix 1 must carry block 2.** Today the defect is self-limiting: the tote is locked and still pointed at, so it never re-enters circulation and its label never accumulates a second joinable row. Fix 1 removes exactly that limit — that is its purpose. Without block 2 the next pick onto `T-0002` creates a second joinable row and `findByUnitloadLabelid('T-0002')` throws `IncorrectResultSizeDataAccessException` at three live call sites: `CustomerorderService:614` (**the packing path** — a 500 when an operator packs an order, days later, on a different order, with no link back to the cancel), `PickingorderBusinessService:669` via `getByLabel` (which catches only `NoSuchElementException`, so the multi-row exception escapes), and `MobileInfoService:352`. *Deriving method:* `git grep -n "getByLabel(\|findByUnitloadLabelid" origin/develop -- 'src/main/**/*.java'` → the declarations plus exactly these three call sites. *Blind spots:* reflection/SpEL; SDR export is ruled out — the repository carries `@RepositoryRestResource(… exported = false)` at type level. Separately, `ToteStateService.stillHoldsTote` (`state < FINISHED && state != CANCELED`) keeps reporting the tote as assigned to the cancelled order until block 2 sets `CANCELED`.

**The DB signature identifies the path uniquely.** Both working siblings null `pickingtote_id` in the same block that clears the lock, so an order at `CANCELED` with `pickingtote_id` **still populated** is reachable from neither — exactly what both stranded PRD orders look like. ⚠ `historytote` being populated there is **not** evidence of teardown: `MobilePickingService` writes it at tote *assignment*, beside `setPickingtoteId`.

## 3. Which branch fires — re-derived

**Not a regression: a day-one omission.** At the initial check-in (`a685e07b`) the success branch already had no teardown; nothing removed it.

⚠ **Revision 1's discriminator was wrong.** It named the first guard of `CustomerorderPositionService.canOrderPositionBeCancelled` — `if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) { return false; }`. That guard **cannot return false from `cancelOrder`**: thirteen lines earlier `cancelOrder` has already thrown for any such position —

```java
if (coPositions.stream().anyMatch(position -> position.getState() >= PACKED && position.getState() < WmsConstants.State.CANCELED)) {
    throw new BusinessException("order contains position with status beyond PACKED. can not be cancelled anymore");
}
```

`PACKED = 650`, `CANCELED = 800`, so any `customerorder_position` in [650, 800) throws first and anything below 650 passes the cited guard. *Deriving method:* `git grep -n "canOrderPositionBeCancelled" origin/develop -- 'src/main'` → the declaration, nine `LOG.debug` string matches inside the method, and **one** call site (`CustomerorderService`). *Blind spots:* reflection/SpEL; and `src/test` callers, which **can** invoke it directly with a position ≥ 650 and watch the guard work — which is exactly what a dead guard looks like from a unit test.

**The real split, in order:**

1. `isPackedOrPalletized(order)` **and** (WMS-internal **or** pre-QA club) → `forceCancelOrder` → correct teardown. This is the **order-state** discriminator.
2. `isPackedOrPalletized` without that permission → `BusinessException("order is beyond status PACKED and not a pre-QA club order")` → 400.
3. any position in [650, 800) → the throw quoted above → 400.
4. otherwise `canOrderPositionBeCancelled` runs per position. Its **regular-picking arm** returns `false` only for a `Pickingorder` **or** `PickingorderPosition` in **[650, 700)**: `if (pickingOrder.getState() >= WmsConstants.State.PACKED && pickingOrder.getState() < WmsConstants.State.FINISHED) { return false; }` and the same on the position.
5. `false` → `pickingconfirmationsent ? cleanUpCancelledOrder(order)` (correct teardown) `: setMarkedforcancellation(true)` (SBDEV-3332 owns that arm; it has no terminal path and this plan does not re-open it).
6. `true` → **the success branch → strands.**

**On Hydra PRD the [650,700) band is empty, so step 5 is effectively unreachable and step 6 always fires.** *Measured 2026-09-14, `psql` direct:* **0 of 169** `pickingorder` rows and **0 of 341** `pickingorder_position` rows fall in [650,700). *Second instrument:* the SBDEV-3332 comment in `CustomerorderService` records an independent measurement three days earlier — *"a band holding ZERO rows on Hydra PRD: pickingorder is 166 rows (states 300/700/800) and pickingorder_position is 337 (300/600/800)"*. *Positive control for the zero:* both censuses return non-zero totals with populated state columns (169/341 and 166/337 rows across states 300/600/700/800), so the query shape does resolve rows and states — the zero is the band, not the instrument. *Blind spot:* one tenant, and the tenant the ticket was filed from — biased by construction (§12).

**Consequence for severity.** "7 of 7 stranded at position state 600" therefore reads as *"7 of 7 cancels that still had a live tote"*, not *"7 of 7 that landed in a narrow window"*. Revision 1 under-stated its own severity because of the wrong mechanism. The thing that actually determines exposure is **whether `pickingtote_id` is non-null at cancel time**, not dwell time at any state.

⚠ **Revision 1's WineCo/Hydra contrast is withdrawn.** It was derived from the wrong predicate, and it cannot be re-grounded: WineCo has **zero** `customerorder_cancellation_log` rows, so post-hoc attribution on that tenant is not possible. Do not assert a cause there. For the manual test (§8) select a tenant on the real criterion — one where an order can be brought below PACKED with a non-null `pickingtote_id` — not on state dwell time.

## 4. Architecture

```
OMS → POST /rest/order/cancelPositions      OrderRestController  (not @Transactional, no wrapper round the per-order loop)
   └─ per batch → per order → customerorderService.cancelOrder(order, false)   @Transactional(tenantTransactionManager)
        ├─ clubRunCancellationBlockingState → batch findByIdForUpdate (CLUB batches only)         [lock: Batch]
        ├─ isPackedOrPalletized + permitted → forceCancelOrder                  ← correct teardown
        ├─ any position in [650,800) → BusinessException → 400
        ├─ rapid-pick pre-branch (RAPID_PICKING && ASSIGNED && historytote != null && STARTED) — empty-tote retire, throws on a full tote
        └─ canOrderPositionBeCancelled (regular arm: Pickingorder/Position in [650,700) → false)
              false → pickingconfirmationsent ? cleanUpCancelledOrder  ← correct teardown
                                              : markedforcancellation  (SBDEV-3332, no terminal path)
              true  → loop cancelOrderPosition(...)                     [lock: Pickingorder, Stockunit]
                      ★ TEARDOWN MISSING HERE ★
                      setState(CANCELED) → save → finalizeBatchIfComplete → outbox ORDER_BATCH_CANCELLED_FROM_WMS
```

`UtilRestController.resetOrdersInReleasedStatus` is the other `cancelOrder` call site and is **dead**: the class is `@Service`, not `@RestController`, so its `@RequestMapping` does not route. *Positive control:* `OrderRestController` carries `@RestController` + `@RequestMapping("/rest/order")` and does route. *Blind spot:* a reflective or SpEL invocation would not appear.

| File | Role |
|---|---|
| `service/CustomerorderService.java` | the defect (`cancelOrder`) and the adjacent NPE (`forceCancelOrder`) — Fixes 1, 2, and the service half of Fix 3 |
| `controller/rest/OrderRestController.java` | `cancelPositions`, the single live entry point — the controller half of Fix 3 |
| `exceptions/ToteTeardownException.java` | **new** — the type that lets Fix 3 contain teardown failures without touching the pre-existing rejection contract (§5.2) |
| `service/PickingorderBusinessService.java` | `cleanUpCancelledOrder`, the shape to copy — read-only; its SBDEV-3316 ordering pin must not move |
| `repo/jpa/PickingorderUnitloadRepository.java` | the finder whose uniqueness Fix 1 block 2 maintains — read-only |
| `service/UnitloadBusinessService.java` | `sendToClearing` → `transferUnitLoadToLocation(…, ignoreLock=true, …)` — read-only |

## 5. Fix design

### Fix 1 — the teardown (~20 lines, two blocks)

Insert immediately **after** the `cancelOrderPosition` loop and **before** `customerOrder.setState(WmsConstants.State.CANCELED)`:

```java
// SBDEV-3339: confirmPick mints PICKED_FOR_GOODSOUT and the pick assignment row keeps
// pickingorder_unitload.unitload_id populated, so every path that ends an order without
// shipping owes BOTH the lock clear and the assignment retirement. Both blocks are copied
// from cleanUpCancelledOrder — the only complete teardown in the codebase. sendToClearing
// runs before the stock clear to match that sibling call-for-call, so the two branches stay
// diffable (plan §5 point 2: this ordering is NOT a lock argument).
// SBDEV-2102: pick-pack orders reach this branch with no tote; findById(null) throws.
if (customerOrder.getPickingtoteId() != null) {
    Unitload tote = unitloadRepository.findById(customerOrder.getPickingtoteId())
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad", customerOrder.getPickingtoteId()));
    unitloadBusinessService.sendToClearing(tote, WmsConstants.CODE_TRANSFER, null, customerOrder.getNumber());

    List<Stockunit> stockUnits = stockunitRepository.findByUnitloadId(tote.getId());
    stockUnits.forEach(su -> su.setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED));
    stockunitRepository.saveAll(stockUnits);

    customerOrder.setHistorytote(tote.getLabelid());
    customerOrder.setPickingtoteId(null);

    // Block 2 — retire the pick assignment. Nulling unitload_id is what keeps
    // findByUnitloadLabelid single-valued on a reused tote (SBDEV-2742); without it this fix
    // trades stranded stock for an IncorrectResultSizeDataAccessException on the packing path.
    // SBDEV-3316 requires this to sit BELOW the recordCancellation writes — on this branch those
    // happen inside cancelOrderPosition, in the loop that has already run, so this placement
    // satisfies the pin. Pinned by the InOrder assertion in AC-7.
    pickingorderUnitloadRepository.findLatestByUnitloadLabelid(tote.getLabelid())
        .ifPresent(pul -> {
            pul.setHistorytote(tote.getLabelid());
            pul.setUnitloadId(null);
            pul.setState(WmsConstants.State.CANCELED);
            pickingorderUnitloadRepository.save(pul);
        });
}
```

Seven points, each load-bearing:

1. **Placement after the loop.** Inside the loop it would run once per position. After the loop, `cancelOrderPosition` has already nulled `pickfromstockunit_id` on every line of this order, and the `recordCancellation` writes SBDEV-3316 pins are already done — which is what makes block 2's placement legal here.
2. **`sendToClearing` first — for sibling parity, not for locking.** ⚠ Revision 1 justified this as *"keeps Pickingorder before Stockunit"*; withdrawn, because the plan cannot assert that and its own no-guard finding at once. `WmsConstants.CODE_TRANSFER = "TRANSFER"` **is** in `PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES`, so `pickLineRealignmentService.lockOwningPickingorders(...)` does run — but it resolves owners via `pickingorderPositionRepository.findByPickfromstockunitId(...)` over the **tote's** stock, which is picked-*to* stock backing no pick line, and `cancelOrderPosition` has just nulled `pickfromstockunitId` on this order's lines. So either the pre-walk takes a `Pickingorder` lock *after* the loop's `Stockunit` locks (an inversion, not a preservation) or it takes nothing — exactly one holds, and neither supports revision 1's sentence. **The reason to keep the order is that it matches the canonical sibling call-for-call.** AC-2 stays; its justification changes.
3. **No `entity_lock` guard on the `sendToClearing` path.** `ignoreLock=true` skips the only lock read in `transferUnitLoadToLocation`, and that read is on the destination *Location*. *Deriving method:* full read of `transferUnitLoadToLocation` and both `processTransfer` overloads on the blob. *Positive control:* the same sweep surfaced `destinationLocation.getEntityLock()` and `StockunitBusinessService`'s `destinationUnitload.getEntityLock() != null`, so the instrument finds lock reads where they exist. *Blind spot:* `unitloadRecordService.recordForTransferUnitLoad` and `replenishmentOrderSourceSyncService.syncForMovedStockUnit` bodies were not read.
4. **`sendToClearing` moves a non-empty tote by design** — no emptiness guard, deliberately, unlike `sendToNirvana` (*"has stock!"*) and `relocateEmptiedContainer`. `STORAGE_LOCATION_CLEARING` is seeded in `V2.2.00__base_v2_schema.sql`, marked *"This is a system used entity. DO NOT REMOVE OR LOCK IT!"*
5. **Copy the sibling's call shape verbatim, transposition included.** `sendToClearing(Unitload, activityCode, comment, orderNumber)` forwards into `transferUnitLoadToLocation(…, activityCode, orderNumber, comment)` — the last two are swapped, so `unitload_record.order_number` is null. Pre-existing on every caller; **do not correct it here**.
6. **Clear the stock's lock, not the tote's own.** `cleanUpCancelledOrder` clears stock only; `forceCancelOrder` also clears the tote's. Measured: both stranded totes, and all 8 totes on the tenant, sit at `entity_lock = 0` — the extra clear buys nothing, and copying it drags in the guard Fix 2 exists to repair.
7. **Block 2 uses `findLatestByUnitloadLabelid`, not `getByLabel`** — a deliberate one-line divergence. `getByLabel` wraps the *unsafe* finder and catches only `NoSuchElementException`, so on a tenant that already has a duplicate it throws the very exception block 2 exists to prevent. `findLatestByUnitloadLabelid` was added for this hazard (SBDEV-2742), joins the same way, and returns the identical row in the measured single-row case. Terminal state **`CANCELED`**, matching the sibling. ⚠ `cleanUpCancelledOrder` still calls the unsafe finder — pre-existing, not this ticket's (§5.6).

### Fix 2 — the latent NPE in `forceCancelOrder` (one line)

`forceCancelOrder` guards its teardown with `if (pickingTote.getEntityLock() != WmsConstants.BusinessObjectLockState.GOING_TO_DELETE) {`. `Unitload.getEntityLock()` returns `Integer`; the constant is `int`; the column is `entity_lock integer` in `V2.2.00__base_v2_schema.sql` with **no NOT NULL and no default** — so this auto-unboxes and NPEs on a null, surfacing as `GENERIC_ERROR`. The codebase already states the rule, in `relocateEmptiedContainer`: *"entityLock is a nullable Integer — compare null-safely (Integer.equals), never `!= int` (auto-unbox NPE)."*

```java
if (!Integer.valueOf(WmsConstants.BusinessObjectLockState.GOING_TO_DELETE).equals(pickingTote.getEntityLock())) {
```

Sub-T3 finding in code adjacent to the fix ⇒ it rides this ticket (the ticket is `in development`, not `on dev` or later).

### Fix 3 — contain teardown failures only (new exception type + wrap + scoped catch)

⚠ **Revision 1 specified a blanket catch around `customerorderService.cancelOrder(...)`. That is wrong and is corrected here.** A blanket catch cannot distinguish a new teardown throw from the rejections that already flow through the same call: `BusinessException("order is already shipped or past cancellation boundary")`, `BusinessException("order contains position with status beyond PACKED. can not be cancelled anymore")`, `BusinessException("order is beyond status PACKED and not a pre-QA club order")`, and the club-batch block. Today every one of those becomes **HTTP 400 `WRONG_STATE`**, and that is pinned: `OrderRestControllerUnitTest.shouldReturnBadRequestWhenOrderInWrongState` does `doThrow(new BusinessException("Wrong state")).when(customerorderService).cancelOrder(existingOrder, false)` then asserts `HttpStatus.BAD_REQUEST`. Containing those would turn a correct refusal into a 200-with-errors — a much larger OMS contract change than intended.

**Mechanism.** Three parts:

1. **New `ToteTeardownException extends FacadeException`** (`net.aim_ai.wms.exceptions`). `FacadeException extends Exception`, so it is checked and already covered by `cancelOrder`'s `rollbackFor = {BusinessException.class, FacadeException.class}` and by its `throws` clause — **no signature change anywhere**.
2. **In `cancelOrder`**, wrap only the Fix 1 block, catching **`Exception`, not an enumerated list**:

   ```java
   try { …teardown… }
   catch (Exception e) { throw new ToteTeardownException(…, e); }
   ```

   ⚠ **Do NOT enumerate the catch as `BusinessException | FacadeException` (+ `DataAccessException`).** That list is provably incomplete, and it fails in the single most likely scenario:

   - `net.aim_ai.wms.exceptions.EntityNotFoundException` is **`extends RuntimeException`** — unchecked, and **not** a `DataAccessException`, so an enumerated list misses it.
   - `sendToClearing` opens with `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_CLEARING).orElseThrow(() -> new EntityNotFoundException("Location not found by name: " + …))` — i.e. **prerequisite 1's exact scenario** (a tenant with no `Clearing` row) and §5.2's **first-listed** new throw source. Fix 1's own `unitloadRepository.findById(...).orElseThrow(...)` throws the same type.
   - Uncaught, it falls past the new arm into the controller's existing `catch (Exception e)` → `GENERIC_ERROR` → **the whole batch aborts**. Containment silently degrades to Option A precisely where Option B was chosen to help, and §9's mitigation would be false as written.

   Catching `Exception` is **fail-closed**: any teardown throw, checked or unchecked, present or future, becomes one contained type. The teardown block calls four collaborators and this plan does not claim to have enumerated every exception they can raise — an enumerated list would have to be re-audited on every change to any of them, which is exactly the maintenance trap the sibling-sweep discipline warns about.

   The wrap covers **only** the Fix 1 block, so it cannot swallow anything from the position loop or the state write.
3. **In `cancelPositions`**, add `catch (ToteTeardownException e)` **above** the existing `catch (BusinessException)` / `catch (FacadeException)` arms (Java requires the subtype first): `LOG.error` with the order's `unique_id`, increment a counter, put the order into the already-declared `errors` map, and continue the loop. Every other arm keeps throwing exactly as today.

**Why containment is safe.** Not `rollbackFor` — Spring already rolls back on any `RuntimeException`. The real guarantee is `spring.jpa.open-in-view=false` (`src/main/resources/application.properties`; *positive control:* the surrounding `spring.jpa.*` block is present in the same output, so the file was read), so each `cancelOrder` gets its own persistence context and one order's rollback cannot poison the next. If anyone flips OSIV on later, Fix 3 becomes unsafe silently. Separately, `finalizeBatchIfComplete` is self-protecting: the failed order stays non-terminal, so a sibling's finalization cannot mark the batch complete over it.

**Scope the catch to the `cancelOrder` call, not the loop body.** `validateWarehouse`, the `batchId`/`positions` validation, `findByBatchid` and `findByExternalNumber` all throw `WebserviceBusinessExceptionClientSide` *before* `cancelOrder`. Those are request-shape errors and must keep aborting.

**The `errors` map exists already.** `Map<String, String> errors = new HashMap<>();` is declared in `cancelPositions` and never read or written. *Deriving method:* `git grep -n "errors"` over the whole file → exactly 2 occurrences, both bare declarations. *Positive control:* the second is an identical declaration in another method, so the grep reads the file.

⚠ **Three response-surface decisions Fix 3 cannot make on its own** — all go to prerequisite 6: the response **body shape**, the **HTTP status** (200-with-errors vs 207 vs 400 — materially different for an OMS client that branches on status before parsing), and the **service-log row**. That last one matters to this very ticket: `cancelPositions` writes `ORDER_BATCH_CANCELLED_FROM_PSD` / `RECEIVED` / 200 on the success exit, and under containment a batch with a failed order still takes that exit — destroying the exact forensic trail §1 used as primary evidence. Decide it (FAILED, or a partial status, or the failed `unique_id` list in the payload); the ERROR log is not a substitute, because nothing scrapes Prometheus (prereq 5) and logs are not queryable at the five-week horizon at which this ticket was diagnosed.

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner |
|---|---|---|---|
| 1 | **DB state** | `SELECT name FROM location WHERE name = 'Clearing';` returns a row on every tenant DB (seeded in `V2.2.00`; a tenant missing it turns a cancel into `EntityNotFoundException`) | implementer |
| 2 | **Tenant config — location constraint** | `SELECT lc.* FROM location_constraint lc JOIN location l ON l.type_id = lc.storagelocationtype_id WHERE l.name = 'Clearing';` — nothing forbidding `Tote` | implementer |
| 3 | **Tenant config — fix assignment** | `SELECT * FROM fix_location_assignment f JOIN location l ON l.id = f.assignedlocation_id WHERE l.name = 'Clearing';` — expect empty | implementer |
| 4 | **Duplicate-label pre-check** | `SELECT u.labelid, count(*) FROM pickingorder_unitload pu JOIN unitload u ON pu.unitload_id = u.id GROUP BY u.labelid HAVING count(*) > 1;` — expect empty on every tenant. Non-empty **before** this ships means the duplicate hazard is already live and Fix 1 block 2 alone will not clear it | implementer |
| 5 | **Data migration, sequenced** | The 63 already-stranded units are **not** fixed by the code change — run [`free-63-units-t0002-t0007.md`](../../../2-Areas/runbooks/free-63-units-t0002-t0007.md) separately. ⚠ That runbook **does not null `pickingorder_unitload.unitload_id`** (the table appears in it only in a diagnostic `JOIN`, never in a write), so running it returns `T-0002`/`T-0007` to circulation with the link still populated. Either extend the runbook to null it, or run it **after** Fix 1 ships and re-run prereq 4 | Nam |
| 6 | **OMS response contract** | ✅ **RESOLVED 2026-09-14 — see §18.** All three answered by reading the client (`WmsApiService`), not by choosing: body token **`"failure"`** (the earlier `"partial"` was read by OMS as *success* — silent loss), HTTP **200** (a non-2xx sets `error_type = TYPE_VALIDATION`, which `OrderWmsRecallService` treats as non-retryable), service log **`FAILED`/400**. No longer blocks merge | closed |
| 7 | **Warehouse-ops notification** | `sendToClearing` writes `unitload.storagelocation_id = Clearing` for a tote physically still on a cart. After this ships, someone has to walk cancelled totes to Clearing. Release-note line + ops notification — the cheapest item here and the only one that fails silently in the physical world | Nam / ops |
| 8 | **Monitoring** | ERROR log on a contained teardown failure. ⚠ A Micrometer counter is published but **nothing scrapes Prometheus yet**, so the log is the operative control | implementer |
| 9 | Sysprops / feature flags · config & env · deploy order · access & permissions | **N/A** — unconditional fix, no new bean or property, no new endpoint, no new `FunctionEnum` constant | — |

### 5.2 DECISION — partial-batch semantics on `cancelPositions`

`cancelPositions` has **no transaction wrapper around its per-order loop**, and neither controller is `@Transactional`; each `cancelOrder` commits on its own, so a throw mid-loop *already* leaves a partially-cancelled batch. Today the loop converts any `cancelOrder` throw into a `WebserviceBusinessExceptionClientSide` and **rethrows** — the remaining orders are never attempted and OMS gets a 400.

The new throw sources are all per-tenant-config or per-data rather than per-order: `locationRepository.findByName("Clearing")` → `EntityNotFoundException`; `locationConstraintService.isUnitloadTypePermitted` → `BusinessException("unitloadTypeNotPermittedOnLocation")`; the fix-assignment branch → `FacadeException("CARRIER_NOT_ON_FIXLOC" / "WRONG_ITEMDATA_FIXASSIGNMENT")`; `assertNoActivePickFor` → `BusinessException(ACTIVE_PICK_MESSAGE)`; `processTransfer` recursion → `FacadeException("CARRIER_IS_ITS_OWN_CARRIER" / "CARRIER_HIERARCHY_CYCLE")`; plus the unchecked `DataAccessException` family from block 2.

⚠ Revision 1 said a teardown throw rolls back *"the `CANCELED` state and the outbox row"* and cited `CancelOrderRollbackIntegrationTest` for it. Both halves are withdrawn (§8, §14): Fix 1 sits *before* `setState(CANCELED)` and well before `outboxService.enqueue(...)`, so a teardown throw short-circuits both — there is no `CANCELED` state and no outbox row to roll back. What rolls back is the teardown's own partial writes.

| Option | Behaviour | Trade-off |
|---|---|---|
| **A — status quo (abort)** | the first teardown failure denies the rest of the batch | One tenant-config fault stops WMS cancelling orders OMS believes are cancelled — it makes a cancel *less* complete than today |
| **B — contained per-order (recommended)** | catch **`ToteTeardownException` only**: `LOG.error` with the `unique_id`, increment a counter, record the order into the `errors` map, continue; return the accumulated errors in the response body | The rest still cancel; the pre-existing rejection contract is untouched. Costs a new exception type, a wrap in the service, and the three prereq-6 answers |
| C — pre-flight the Clearing config | check the tenant's Clearing row before the loop | Rejected: covers the first throw source only |

**DECIDED — Option B (Nam, 2026-09-14), scoped to `ToteTeardownException`, with an ERROR log and a counter.** This is Fix 3, in scope, not conditional. **Never a bare 200 when an order failed** — a containment that reports success is silent loss to OMS, strictly worse than today's loud 400.

### 5.3 DECISION — breadth of the lock clear

`cleanUpCancelledOrder` clears **unconditionally** (`stockUnits.forEach(su -> su.setEntityLock(NOT_LOCKED))`), so it would also clear an operator's `ON_HOLD`. `CancellationReversalService` made the **opposite** choice on the reversal path, refusing to clear anything but `PICKED_FOR_GOODSOUT` (`final boolean clearNeeded = arrivedLocked || stockUnit.getEntityLock() == null;`). Two live paths, two policies.

**DECIDED — unconditional, copying `cleanUpCancelledOrder` (Nam, 2026-09-14).** ⚠ Revision 1 justified this as *"the two branches of `cancelOrder` must leave identical state"*. Both review lanes showed that premise was **false of revision 1's own fix**, which left the two branches differing in exactly the row that governs tote reuse (§2 invariant b). Fix 1 block 2 restores the symmetry — but the decision should not rest on a claim the plan had disproved, so it is re-justified on its own merits:

- **The unconditional policy is already pinned by a live test.** `PickingorderBusinessServiceUnitTest.shouldCleanUpWithStockUnitsAndPositions` fixtures `stockUnit2.setEntityLock(WmsConstants.BusinessObjectLockState.ON_HOLD)` and asserts it becomes `NOT_LOCKED`. Narrowing here without narrowing there breaks a real test — free evidence that the repo has already chosen this policy on the live deferred path.
- **A filtered clear would leave the defect in place for the held subset.** Stock left at `QUALITY_FAULT`/`ON_HOLD` on a cancelled order's tote is still un-movable by `transferStockToUnitLoad` and still un-releasable by `removeLock` only in the `PICKED_FOR_GOODSOUT` case — so a filter buys authority at the cost of re-creating a smaller version of the stranding.
- **The branches ending in the same state is a real benefit**, just not a load-bearing premise: an order differing in whether an `ON_HOLD` survived depending on which branch cancelled it is a support nightmare.

⚠ **State the exposure honestly.** Revision 1 said this *"introduces no new exposure"*; that is false and is withdrawn. Today the success branch clears **nothing**, so an operator's `QUALITY_FAULT` (103) or `ON_HOLD` (104) on tote stock **survives** a success-branch cancel. After the fix it does not. The correct sentence is: **this extends an existing exposure from one branch to both, deliberately, because asymmetry is judged worse than the exposure** — and per §3 that is *every* below-PACKED cancel on Hydra PRD, not a narrow window. **Any future narrowing must narrow both paths together**, in its own ticket.

### 5.4 FILED as SBDEV-3354 (2026-09-14) — delete `CustomerorderBatchService.cancelBatch`

> ✅ **No longer a proposal.** Filed at Nam's direction as **SBDEV-3354** (https://app.clickup.com/t/868m4x898), Fulfillment Development Backlog, priority `normal`, tier **T2**. Out of scope for this ticket; no step in §7 touches it. Three corrections were carried into that ticket so they are not re-derived: the reference count is **54 across 4 files** (not the 18 an earlier revision of this section claimed), `CancelOrderRollbackIntegrationTest`'s batch test is that class's **only** batch coverage and its removal needs an explicit decision, and WineCo UAT's `T-0010` orphan has **no established provenance** and must not be attributed to this method.

`cancelBatch` carries the same root cause in a worse shape: it nulls `pickingtote_id` but never clears the stock lock and never relocates the tote.

**It is dead.** *Deriving method:* `git grep -n "cancelBatch" origin/develop` over the whole tree. `src/main` contains **exactly 1** occurrence — its own declaration, `public void cancelBatch(CustomerorderBatch orderBatch, Principal principal)`. *Positive control:* the same grep returns **54** occurrences across **4** test files, so the search works. `docs/plan/completed/WMS_Staging_Lane_Bug_Fix_Plan.md` says it outright: *"`cancelBatch()` has no callers; wiring it to a controller is a separate enhancement."* *Blind spot:* reflective/SpEL invocation; Spring Data REST does not export service methods.

⚠ Revision 1's per-file counts were wrong and are corrected (`git grep -o "cancelBatch" origin/develop -- <file> | wc -l`): `CustomerorderBatchServiceUnitTest` **36** (not 13), `CustomerorderBatchOutboxIntegrationTest` **13** (not 4), `CancelOrderRollbackIntegrationTest` **4** (not 1), `PickingorderBusinessServiceUnitTest` **1** (omitted entirely) — **54 across 4 test files**, plus **12** `docs/plan/**` files (not 4). The deletion conclusion is unaffected; the **cost estimate is not** — revision 1's "18 test call sites … half a day at most" rested on the wrong arithmetic and should be re-scoped on the real 54 when the follow-up ticket is written.

**Blast radius of deletion: nil** in production. **Why delete rather than fix:** fixing dead code creates a second maintained copy of the teardown, and a future caller inherits whichever copy drifted.

⚠ An earlier lane attributed WineCo UAT's orphaned tote unit `T-0010` to `cancelBatch`. **That attribution is withdrawn** — a method with no caller cannot have produced a live row. `T-0010` has **no established provenance**; do not attribute it.

### 5.5 Doc corrections (same PR)

`sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md` is 69 days past its own re-verify date and carries 8 false claims (D-1…D-8, [`enumeration.md` §5.1](./SBDEV-3339-evidence/enumeration.md)). **Two must be corrected here** because they tell a reader this defect is already fixed:

- **D-1** — §5's `cancelBatch` pseudocode: *"release entity locks (so stock is returnable)"*. **False.** *Deriving method:* `git grep -n "setEntityLock(" origin/develop -- 'src/main/**/*.java'` → **94** hits across `src/main` (revision 1 said 90; `git grep -n | wc -l` and `git grep -o | wc -l` both return 94, so there are no multi-match lines to explain a gap), **none** in `CustomerorderBatchService` — `git grep -c` returns no line at all for that file. The single most dangerous line in the vault for this ticket.
- **D-2** — §2's entry-point table: `cancelBatch` triggered by *"REST `/clubLine/...` + admin"*. **False** — no caller, no route (§5.4).

D-3…D-8 are real but do not assert the defect fixed; fold them into the `verify-docs` pass. `BusinessObjectLockState` being documented nowhere in `sbdocs/` is **out of scope** — propose a doc ticket.

### 5.6 Follow-ups to propose, not absorb

Ranked, each grounded, none in this PR. Nam confirms before any is filed.

1. **Extract `releasePickingTote(Customerorder)`.** There are not three teardowns but six partial ones (`forceCancelOrder` ×2 arms, `cleanUpCancelledOrder`, `packageOrder`, `cancelBatch`, and now Fix 1), drifted on six axes: lock clear · the tote's own lock · `sendToClearing` vs clear order · the `GOING_TO_DELETE` guard · `save` vs `saveAll` · retires `pickingorder_unitload`. Extraction would have made the block-2 omission structurally impossible. **Not now:** unifying requires *choosing* on the two axes where `forceCancelOrder` deliberately differs — a behaviour change on a path this plan declares read-only — and the safety net is three unit-test classes whose largest is `LENIENT`. First AC of that ticket: the six-axis table with every cell agreeing.
2. **`forceCancelOrder` does not retire `pickingorder_unitload`** (§2 table) — the same gap Fix 1 block 2 closes, on a path this plan must not touch; currently masked because it runs on PACKED orders whose assignment row is usually already `FINISHED`.
3. **`cleanUpCancelledOrder` and `packageOrder` call the unsafe `findByUnitloadLabelid`** while `findLatestByUnitloadLabelid` exists for that hazard. Pre-existing; a tenant that already has a duplicate row breaks the packing path regardless of this ticket.
4. **Delete `cancelBatch`** (§5.4), re-scoped on the corrected 54 references.

## 6. File change summary

| File | Change | Description |
|---|---|---|
| `service/CustomerorderService.java` | modify | **Fix 1** — ~20 lines (two blocks) in `cancelOrder`'s success branch, after the `cancelOrderPosition` loop. **Fix 2** — 1 line in `forceCancelOrder`. **Fix 3** — the `try/catch` wrap around the Fix 1 block |
| `exceptions/ToteTeardownException.java` | **add** | `extends FacadeException`; checked, so `rollbackFor` and the existing `throws` clauses already cover it |
| `controller/rest/OrderRestController.java` | modify | **Fix 3** — a `catch (ToteTeardownException)` arm above the existing arms: ERROR log + counter + populate the existing `errors` map + `continue`; return accumulated errors in the response body |
| `src/test/.../CustomerorderServiceUnitTest.java` | modify | 4 new tests (§8) **and one existing test amended** — `shouldSkipRapidPickingCleanupWhenNotStarted` (§8) |
| `src/test/.../OrderRestControllerUnitTest.java` | modify | 1 new test (AC-6) **and `shouldReturnBadRequestWhenOrderInWrongState` kept green as the rejection-contract rail** |
| `sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md` | modify | D-1, D-2, `last_verified` |

No new dependency, no new bean, no migration, no sysprop, no new endpoint, no new `FunctionEnum` constant.

## 7. Implementation steps

1. Worktree off freshly-fetched `origin/develop` (`.claude/worktrees/wms2-api/SBDEV-3339`); record the base SHA. **Baseline all four test classes first** (§8) — the `OrderRestControllerUnitTest` figure has never been measured green.
2. **Tests first** (§8) — write, run, confirm each fails for the stated reason.
3. Apply **Fix 2** (one line), then **Fix 1** (both blocks) after the `cancelOrderPosition` loop and before `setState(CANCELED)`.
4. **Amend `shouldSkipRapidPickingCleanupWhenNotStarted`** — it is expected to go red (§8). Stub the tote and assert the teardown, turning it into a second AC-1 witness.
5. **Mutation-check with PIT scoped to `CustomerorderService`**: remove `saveAll`, remove `sendToClearing`, remove `setPickingtoteId(null)`, remove block 2's `setUnitloadId(null)` — four omissions, four mutants, each red on its own; plus swap the two calls for the AC-2 `InOrder` assertion and hoist block 2 above the loop for the AC-7 one.
6. Run `CustomerorderServiceUnitTest` + `CustomerorderPositionServiceUnitTest` + `PickingorderBusinessServiceUnitTest` against the §8 baseline.
7. Add `ToteTeardownException`, the service-side wrap, and the controller catch arm (**Fix 3**); add the AC-6 test; confirm `shouldReturnBadRequestWhenOrderInWrongState` still passes unchanged. **Get the three prereq-6 answers before merging.**
8. Doc pass — D-1, D-2, `last_verified`.
9. Independent review lane (`code-reviewer`); fix **every** finding including Low. Then commit, PR into `develop`, update plan status + ClickUp.

**Non-goals, explicitly:** do not touch `cancelOrderPosition` (AC-3); do not touch `cancelBatch` (§5.4); do not touch `forceCancelOrder` beyond Fix 2's one line; do not move the SBDEV-3316 ordering pin in `cleanUpCancelledOrder`; do not re-open the `markedforcancellation` branch (SBDEV-3332 owns it); do not "fix" the `sendToClearing` argument transposition; do not widen `OPERATOR_REMOVABLE`; do not change `cleanUpCancelledOrder`'s finder (§5.6 item 3).

## 8. Testing

⚠ **Revision 1 claimed the fix breaks no existing test. That is false, and the claim is withdrawn.** `CustomerorderServiceUnitTest.CancelOrderRapidPickingScenarios.shouldSkipRapidPickingCleanupWhenNotStarted` sets `testOrder.setPickingtoteId(50L)` at state `ASSIGNED`, stubs `canOrderPositionBeCancelled → true` (the success branch), and sets `pickingOrder.setState(WmsConstants.State.PROCESSABLE); // Not STARTED`, so the rapid-picking branch that would null the tote id is skipped and `50L` survives into the teardown. It does **not** stub `unitloadRepository.findById(50L)`; the class has exactly **one** `@BeforeEach` and every `when(unitloadRepository.findById(...))` sits inside a *different* test method body. Under Fix 1 that call returns `Optional.empty()`, `.orElseThrow` fires, and **the test goes red.**

> **This red is expected churn, not a regression.** Revision 1's *"Any deviation is a regression, not noise"* would have made the implementer revert a correct fix; that sentence is deleted. The correct instruction: **exactly one named pre-existing test is expected to fail, and the fix for it is to stub the tote and assert the teardown** (turning it into a second AC-1 witness). Any *other* deviation is a regression.
>
> ⚠ **`CustomerorderServiceUnitTest` is `@MockitoSettings(strictness = Strictness.LENIENT)`** — any "STRICT_STUBS will catch it" reasoning is **false for this class**, and an unstubbed **void** `sendToClearing` is a no-op under either setting. `PickingorderBusinessServiceUnitTest` is `STRICT_STUBS`; do not generalise from one to the other. This observation is unchanged from revision 1 and remains correct and useful.
>
> *Deriving method for the amended claim:* every `setPickingtoteId` site in the file mapped to its enclosing `@Nested` class and method, then each site landing in a `cancelOrder` nest read to see whether the tote is nulled before the success branch. *Positive control:* the file contains **12** `testOrder.setPickingtoteId(50L)` sites, so the grep does find the setter where it is. *Blind spot:* a fixture setting the field reflectively, via a builder, or through `TestDataFactory` would not match — `TestDataFactory` internals were not audited; `createTestCustomerorder` itself was read in full and sets no tote.

⚠ **Four unit classes is still not the whole exposed surface — three more classes run the REAL `cancelOrder`.** *Deriving method:* `git grep -ln "customerorderService.cancelOrder" origin/develop -- 'src/test/**/*.java'` → four files, one being `CustomerorderServiceUnitTest` itself; *blind spot:* a test reaching `cancelOrder` transitively through another service would not match.

| class | lane | why it matters here |
|---|---|---|
| `TransferLaneLeakOnCancelIT` | failsafe (`*IT` is in the lane since SBDEV-3239) | grades the transfer-lane release sitting a few lines below Fix 1's insertion point — the closest thing to a real regression detector for this change |
| `CustomerorderOutboxIntegrationTest` | integration | exercises the outbox enqueue that Fix 1 now precedes |
| `CancelOrderRollbackIntegrationTest` | integration (H2) | cited as evidence nowhere (§8 "Deliberately skipped"), but it runs the real method, so it must stay green |

Run each as `mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`. ⚠ **Never** the standalone `failsafe:integration-test` goal — it reports `Tests run: 0` with BUILD SUCCESS for *any* class, included or not, and proves nothing.

**MEASURED baseline @ `221caed1`** (detached worktree at `origin/develop`, 2026-09-14 — not a declared count):

| lane | classes | result |
|---|---|---|
| unit | `CustomerorderServiceUnitTest` + `CustomerorderPositionServiceUnitTest` + `PickingorderBusinessServiceUnitTest` | **216 tests, 0 failures, 0 errors, 0 skipped** |
| unit | `OrderRestControllerUnitTest` | **92 tests, 0 failures** (`CancelPositionsEndpoint` = **9**, confirming the declared figure) |
| failsafe | `TransferLaneLeakOnCancelIT` **2** · `CustomerorderOutboxIntegrationTest` **3** · `CancelOrderRollbackIntegrationTest` **4** | **9 tests, 0 failures** |

**Total 317 tests, 0 failures.** *Verification that the selector was not a silent no-match:* all three failsafe classes produced their own `target/failsafe-reports/*.txt`, and 4+3+2 reconciles with the lane total of 9 — the check that catches the `Tests run: 0` / BUILD SUCCESS trap above. ⚠ Outer-class `.txt` files read `Tests run: 0` for any class with `@Nested` children; read the nested reports or the lane total, never the outer file.

**Baseline — four unit classes, not three.** `OrderRestControllerUnitTest` is the only class whose behaviour Fix 3 changes and revision 1 omitted it. Declared tests at `221caed1`, by `grep -c "@Test"` on the `origin/develop` blobs: `CustomerorderServiceUnitTest` **122**, `OrderRestControllerUnitTest` **92** (of which **9** exercise `cancelPositions`), `PickingorderBusinessServiceUnitTest` **77**, `CustomerorderPositionServiceUnitTest` **17** — **308 total**. *Positive control:* the same grep returns **0** `@Disabled` and **0** `@ParameterizedTest` across all four, so declared == executed. *Blind spot:* `@TestFactory` / `@RepeatedTest` would not match this grep; none appear by the same instrument. The three-class figure 216/0/0/0 was observed green by the drafting lane; **the 92 is a declared count only and must be run green before the first edit.**

| Test class | Test method | Asserts |
|---|---|---|
| `CustomerorderServiceUnitTest` | `cancelOrder_SuccessBranchWithPickingTote_TearsDownTote` | stock `entity_lock == NOT_LOCKED`; `getPickingtoteId() == null`; `getHistorytote()` equals the tote label; `verify(unitloadBusinessService).sendToClearing(eq(tote), eq(CODE_TRANSFER), isNull(), eq(order.getNumber()))`; `InOrder` — `sendToClearing` **before** `stockunitRepository.saveAll` |
| `CustomerorderServiceUnitTest` | `cancelOrder_SuccessBranchWithPickingTote_RetiresPickingorderUnitload` | block 2 — `pul.getUnitloadId() == null`, `pul.getState() == CANCELED`, `pul.getHistorytote()` equals the label, `verify(pickingorderUnitloadRepository).save(pul)`; `InOrder` — the block-2 `save` **after** the `cancelOrderPosition` loop (AC-7) |
| `CustomerorderServiceUnitTest` | `cancelOrder_SuccessBranchWithNoPickingTote_SkipsTeardown` | pick-pack negative control: `verify(unitloadRepository, never()).findById(any())`, `verify(unitloadBusinessService, never()).sendToClearing(any(), any(), any(), any())`, `verify(pickingorderUnitloadRepository, never()).findLatestByUnitloadLabelid(any())`, cancel still completes |
| `CustomerorderServiceUnitTest` | `forceCancelOrder_ToteWithNullEntityLock_DoesNotThrow` | Fix 2 — a tote with `entityLock == null` completes instead of NPEing |
| `CustomerorderServiceUnitTest` | `shouldSkipRapidPickingCleanupWhenNotStarted` *(amended)* | stub `unitloadRepository.findById(50L)`; keep the `CANCELED` assertion and add the teardown assertions |
| `CustomerorderServiceUnitTest` | `cancelOrder_TeardownThrows_WrapsAsToteTeardownException` | AC-8 — parameterised over `BusinessException`, `FacadeException`, `EntityNotFoundException`, `DataAccessException`; each must surface as `ToteTeardownException` with the original as `getCause()`. Mutant = narrow the wrap to the two checked types; both unchecked parameters must go red |
| `OrderRestControllerUnitTest` | `cancelPositions_ToteTeardownFailureOnOneOrder_ContinuesBatch` | AC-6 |
| `OrderRestControllerUnitTest` | `shouldReturnBadRequestWhenOrderInWrongState` *(unchanged — the rail)* | the pre-existing `BusinessException` → 400 contract must still hold after Fix 3 |

**Model to copy:** `PickingorderBusinessServiceUnitTest` — fixture `stockUnit1.setEntityLock(PICKED_FOR_GOODSOUT)`, then `verify(unitloadBusinessService).sendToClearing(eq(tote), …)` and `assertThat(stockUnit1.getEntityLock()).isEqualTo(NOT_LOCKED)`; the only lock-after-cancel assertion in those classes (*blind spot:* an assertion routed through an `ArgumentCaptor` on `saveAll` or through `extracting(...)` would not match that grep). For the AC-7 ordering, copy `PickingorderBusinessServiceUnitTest$Sbdev3316_CancellationLogOrdering`. **Every new assertion** must be mutation-checked with **PIT scoped to the class** (not a hand-rolled harness), one mutant per omission, and carry a failure message that **names the state** — `assertThat(su.getEntityLock()).as("stock %s still locked PICKED_FOR_GOODSOUT after cancel", su.getId())`. A bare `isEqualTo` failure reads as a fixture problem.

### Manual test plan

| Scenario | Environment | Steps | Expected |
|---|---|---|---|
| Cancel a picked order, tote freed | UAT tenant | release + pick an order to a tote, keep every position below 650; OMS `POST /rest/order/cancelPositions`; re-query | `stockunit.entity_lock = 0` for the tote's stock; `pickingtote_id IS NULL`; `historytote` set; tote's `unitload.storagelocation_id` = Clearing; **`pickingorder_unitload.unitload_id IS NULL` and `state = 800`** |
| Tote reuse after cancel | UAT tenant | pick a **second** order onto the same tote, then pack it | `packageOrder` completes; no `IncorrectResultSizeDataAccessException`. This is the scenario Fix 1 block 2 exists for and the one a green unit suite cannot reach |
| Pick-pack order with no tote | UAT tenant | cancel an order that never had a tote | cancels normally; no `EntityNotFoundException`, no `IllegalArgumentException` |
| Before/after census (ticket AC-5) | UAT tenant DB | `SELECT count(*) FROM stockunit su JOIN unitload ul ON ul.id=su.unitload_id JOIN unitload_type t ON t.id=ul.type_id WHERE su.entity_lock=100 AND t.name='Tote';` before and after | count does not grow across a cancel. **Positive control required:** the same query without the type filter must return non-zero — packed `Package` unit loads sit at 100 legitimately |
| Batch partial failure (Fix 3) | UAT | cancel a 3-order batch with the middle order's tenant config broken | orders 1 and 3 cancel; order 2 reported in the body; ERROR log names order 2's `unique_id`; response is **not** a bare 200 |
| Rejection contract unchanged (Fix 3 rail) | UAT | cancel a batch whose middle order is already shipped | still **HTTP 400 `WRONG_STATE`**, batch aborted — exactly as today |

⚠ **Ticket AC-5 is blocked on environment access, not on this plan.** Ports 25060 (dev) and 25062 (UAT) are listening but reject every configured user including `wms_landlord`; 25061 (PRD) authenticates normally, so this is not a credential-parsing fault. Owner: refresh those tunnel targets or credentials. **Tenant selection criterion (revised):** pick a tenant where an order can be brought below PACKED with a non-null `pickingtote_id` — *not* by state dwell time, which was revision 1's discredited model (§3). WineCo has **zero** `customerorder_cancellation_log` rows, so it can neither confirm nor deny the defect post hoc; do not use it to argue either way.

### 8.1 Acceptance criteria

| # | Criterion | Graded by |
|---|---|---|
| **AC-1** | After the success branch runs on an order with a picking tote: every stock unit on that tote is `NOT_LOCKED`, `pickingtote_id` is null, `historytote` carries the tote label, and the tote has been sent to Clearing | `cancelOrder_SuccessBranchWithPickingTote_TearsDownTote`, each of the four assertions mutation-checked separately |
| **AC-2** | `sendToClearing` is invoked **before** the stock-lock clear — for parity with the canonical sibling, **not** for lock ordering (§5 point 2) | `InOrder` assertion; mutant = swap the two calls |
| **AC-3** | `cancelOrderPosition` stays position-scoped and performs **no** teardown — the two paths are *supposed* to disagree, because `pickingorder_position` cannot express a position-scoped clear (no pick-to-stockunit column; `picktounitload_id` FKs `pickingorder_unitload`; `pickfromstockunit_id` is nulled at pick confirm; `transferStockToUnitLoad` merges by itemdata, so two pick lines of one SKU become one stockunit) | `CustomerorderPositionService` absent from the diff; the disagreement documented here and on the ticket |
| **AC-4** | An order with `pickingtoteId == null` (pick-pack) still cancels, with no `findById(null)`, no `sendToClearing` and no block-2 lookup | `cancelOrder_SuccessBranchWithNoPickingTote_SkipsTeardown` |
| **AC-5** | `forceCancelOrder` no longer NPEs on a tote whose `entity_lock` is null | `forceCancelOrder_ToteWithNullEntityLock_DoesNotThrow`; mutant = restore the `!=`, confirm red |
| **AC-6** | A **teardown** failure on one order of a batch does not deny the rest: the remaining orders still cancel, the failed order is named in the response body, an ERROR log carries its `unique_id`, and the response is **not** a bare 200. **And the pre-existing rejection contract is unchanged**: a `BusinessException` from `cancelOrder` still yields 400 `WRONG_STATE` | `cancelPositions_ToteTeardownFailureOnOneOrder_ContinuesBatch`; plus `shouldReturnBadRequestWhenOrderInWrongState` still green. ⚠ **Do not parameterise this over checked vs unchecked sources — that would be vacuous.** `customerorderService` is a **mock** in `OrderRestControllerUnitTest`, so both parameters hand the controller the identical `ToteTeardownException` and the test cannot distinguish them. The checked/unchecked distinction lives entirely in the **service-side wrap**, and is graded by AC-8, not here. Mutant = delete the `catch (ToteTeardownException)` arm so the wrap falls through to `catch (FacadeException)` and rethrows, confirm red. ⚠ Revision 1 named *"drop the `continue`"* as the mutant; today's loop has **no** `continue` — it has three `catch` arms that each `throw new WebserviceBusinessExceptionClientSide(...)`, so PIT had nothing to remove |
| **AC-8** | The service-side wrap converts **every** teardown throw into `ToteTeardownException` — checked *and* unchecked. In particular `EntityNotFoundException` (which `extends RuntimeException`, is **not** a `DataAccessException`, and is what `sendToClearing` raises when a tenant has no `Clearing` row) must be wrapped, not escape | `CustomerorderServiceUnitTest.cancelOrder_TeardownThrows_WrapsAsToteTeardownException`, **parameterised** over: `BusinessException` (checked), `FacadeException` (checked), `EntityNotFoundException` (unchecked), `DataAccessException` (unchecked) — stub `unitloadBusinessService.sendToClearing(...)` to throw each, assert `ToteTeardownException` with the original as `getCause()`. **This is where the checked/unchecked distinction is actually observable**, because the collaborators are real mocks on the service under test rather than a mocked service. Mutant = narrow the wrap to `catch (BusinessException \| FacadeException e)`; the two unchecked parameters must go red. ⚠ That mutant is exactly the specification round 2 rejected — if it does **not** go red, the test is not grading the wrap |
| **AC-7** | The `pickingorder_unitload` row for the tote is retired: `unitload_id` null, `state = CANCELED`, `historytote` set — and the retirement happens **after** the `cancelOrderPosition` loop, preserving the SBDEV-3316 constraint | `cancelOrder_SuccessBranchWithPickingTote_RetiresPickingorderUnitload`; mutants = remove `setUnitloadId(null)` (confirm red), and hoist block 2 above the loop (confirm the `InOrder` assertion goes red) |

### Deliberately skipped

- **Verify script** — T3 opt-in, declined: every assertion here is expressible in JUnit, where it runs in CI, survives refactors and can be mutation-checked. Verify scripts have been a measured net negative in this repo.
- ⚠ **`CancelOrderRollbackIntegrationTest` is cited nowhere in this revision.** Revision 1 cited it three times — for the rollback shape (§5.2), as a risk mitigation (§9), and for "existing batch coverage" of a contained failure. All three are withdrawn, because the test does not pin any of it: it forces its throw with `order.setState(WmsConstants.State.FINISHED)`, which trips `isShippedOrPastCancellationBoundary` — a *pre*-cancel guard — so no state write, no position loop, no teardown and no outbox enqueue ever happen; its own comment concedes *"The exact throwing site doesn't matter for this assertion"*; its single assertion is `verify(httpRestService, never()).post(any(), any())`, which would hold with rollback entirely broken; and its batch test exercises `cancelBatch`, the dead method §5.4 proposes deleting. It also runs on H2, so it proves nothing about PostgreSQL locking.
- **Rollback coverage for Fixes 1–2 is therefore absent, and this plan does not claim otherwise.** No SQL, no JPQL, no migration is introduced, and the failing order's rollback is guaranteed by the `@Transactional` proxy boundary rather than by anything this change adds — so the gap is accepted, named here, and left to §5.6 item 1's ticket if the extraction lands. If Nam wants it closed in this PR, the test is: stub `unitloadBusinessService.sendToClearing` to throw, assert the order is still at its pre-cancel state and no outbox row exists, and re-read by id — **not** `@Transactional` at the method level, since wms2 repository tests commit rather than roll back.
- **`cancelBatch` coverage** — out of scope by decision (§5.4).

## 9. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Fix 1 without block 2 would create duplicate `pickingorder_unitload` rows ⇒ a delayed 500 on the packing path** | was certain, now closed | Block 2 is in Fix 1, pinned by AC-7 and two mutants. Prereq 4 checks the hazard is not already live; prereq 5 sequences the runbook, which does not null `unitload_id` |
| **Fix 3 changes the rejection contract**: a cancel OMS was correctly refused starts reading as accepted-with-errors | was likely under revision 1's blanket catch; now closed by design | Containment is scoped to `ToteTeardownException`; `shouldReturnBadRequestWhenOrderInWrongState` is kept as the rail (AC-6) and must pass unchanged |
| A tenant lacks the seeded `Clearing` row or forbids Tote on it ⇒ cancels start failing where they succeeded | low (seeded in `V2.2.00`) | Prereqs 1-3 are queries, run before deploy; Fix 3 bounds the blast radius when it happens anyway |
| The `ORDER_BATCH_CANCELLED_FROM_PSD` service-log row keeps saying `RECEIVED`/200 for a partially-failed batch, destroying the forensic trail §1 relied on | certain unless decided | Prereq 6 — decide the status/code alongside the response shape. The ERROR log is not a substitute (nothing scrapes Prometheus) |
| Quality-held stock (`QUALITY_FAULT`/`ON_HOLD`) on a cancelled order's tote is released where it previously survived | certain, by design | §5.3 — deliberate, and it extends rather than introduces the exposure. Both paths must be narrowed together if ever narrowed |
| The tote's inventory record says Clearing while it is physically on a cart | certain, matches both live siblings | Prereq 7 — ops notification + release-note line. The plan's manual test grades this as a pass, so nothing automated will catch it |
| `replenishmentOrderSourceSyncService.syncForMovedStockUnit` takes locks of its own, adding `Replenishorder` to the chain | unknown — **body not read** | Highest-value remaining read before implementation |
| Someone later narrows the clear on one path only | low | §5.3 records the decision and the both-paths-together requirement |

## 10. Horizontal scalability validation (v2 — mandatory)

Rows **1 (in-JVM state), 2 (pool math), 3 (scheduled jobs), 5 (request affinity), 7 (tenant context), 9 (cache invalidation), 10 (external notifications): No** — no cache/static/`ThreadLocal`, no new pool or extra connection, no job, stateless, no async boundary, `Stockunit`/`Unitload` are not cached on this path, and the outbox `enqueue` is untouched and still lands in the same transaction after the teardown.

| # | Concern | Verdict | Evidence / mitigation |
|---|---|---|---|
| 4 | Long transactions | **Yes, marginally** | Adds one `findById`, one `findByUnitloadId`, one `saveAll`, one `findLatestByUnitloadLabelid` + `save`, and the `sendToClearing` move inside the existing `cancelOrder` transaction. Bounded by the tote's stock count (7 on the worst PRD case); no external I/O |
| 6 | Retry / idempotency | **Yes — and it is idempotent** | A re-run finds `pickingtote_id` already null and skips both blocks; setting `NOT_LOCKED` on an already-cleared stock unit is a no-op |
| 8 | Distributed lock correctness | **Yes, and the previous rationale is withdrawn** | ⚠ Revision 1 asserted *"the chain stays `Batch ⊃ Pickingorder ⊃ Stockunit/Unitload`"*. That is a completeness claim with no deriving method and it is not true as stated: the Batch lock is taken only for a CLUB batch with a non-null `orderbatchId`, the loop's sequence is Pickingorder,Stockunit per position (monotone only if every position belongs to one `Pickingorder`, which the plan does not verify), and `sendToClearing`'s BLOCK_REALIGN pre-walk would acquire `Pickingorder` **after** those Stockunit locks — or acquire nothing, since `cancelOrderPosition` has already nulled `pickfromstockunitId` (§5 point 2). **What is verified:** no new lock *type* is introduced, everything runs inside the existing `@Transactional(tenantTransactionManager)`, and no `Location` lock is taken (`ignoreLock=true` skips `findByIdForUpdate` on the destination) — **do not "harden" that to `false`**, it would serialize every cancel through the shared Clearing row. A real lock-ordering argument would have to reason about flush-time ordering, not call order, and is not made here |

## 11. v2-only constraint checklist

The `v2/wms2-api/CLAUDE.md` rules all hold: qualified `tenantTransactionManager` with `rollbackFor` preserved (no annotation added — the new code joins `cancelOrder`'s transaction at REQUIRED, and `ToteTeardownException extends FacadeException` so the existing `rollbackFor` covers it without change); **no `REQUIRES_NEW` on this path**, which matters given the known wms2 failure mode where `REQUIRES_NEW` inside a lock-holding transaction deadlocks undetectably; constructor injection unchanged — `unitloadRepository`, `stockunitRepository`, `unitloadBusinessService` **and `pickingorderUnitloadRepository`** are all already `private final` fields on `CustomerorderService` (`private final PickingorderUnitloadRepository pickingorderUnitloadRepository;`, already used by `packageOrder` and the rapid-pick sub-branch), so block 2 adds no dependency; `jakarta.*`; SLF4J parameterised logging; `.orElseThrow`/`.ifPresent` over `.get()`; no JPA associations introduced (`Stockunit.unitloadId` stays a plain `Long`); entity comparison by id; no new query, no native SQL, no Flyway migration; no new `FunctionEnum` constant and no SDR surface change (`PickingorderUnitloadRepository` is `exported = false` at type level).

## 12. Blind spots and open items

- The `setEntityLock` grep has a **proven** miss: `BillofladingService` writes `entityLock` via bulk JPQL; `SHIPPED` (405) reaches the DB only that way — 328 of 804 PRD rows. Any future "who locks this stock" sweep that greps only `setEntityLock` misses 100% of that population. The same class of miss applies to the `setUnitloadId(null)` census in §2(b).
- `@Modifying updateStateByIds` (`CustomerorderRepository`) can write 800 and is invisible to a `setState` grep; its sole caller passes `PACKED`. Latent only.
- **Flyway migrations / DB triggers writing `customerorder.state = 800` were not probed.** No `src/main` grep can see them.
- **Fleet blast radius is NOT established.** Only Hydra PRD and the two WineCo tenants were reachable, and Hydra is the tenant the ticket was filed from — a biased sample by construction. The §3 "[650,700) is empty" measurement inherits that bias: it is a **Hydra PRD** fact, verified by two instruments three days apart, not a fleet fact.
- **WineCo UAT's orphaned tote unit `T-0010` has no established provenance** and the earlier `cancelBatch` attribution is withdrawn (§5.4). Do not attribute it. WineCo also has zero `customerorder_cancellation_log` rows, so nothing on that tenant can be attributed post hoc.
- `replenishmentOrderSourceSyncService.syncForMovedStockUnit` and `unitloadRecordService.recordForTransferUnitLoad` bodies were not read; if either refuses on a lock state, §5 point 3's "no guard on the `sendToClearing` path" narrows.
- **`sendToClearing` also reaches a pick-line *write* path**: the same BLOCK_REALIGN arm calls `pickLineRealignmentService.realignForMovedStockUnit(...)`, which writes `pp.setPickfromunitloadlabel(newUl.getLabelid()); pp.setPickfromlocationname(newLoc.getName());` (`UnitloadBusinessService` and `StockunitBusinessService`, 2 call sites). Fix 1 therefore adds a pick-line write to cancel, not only reads and a move. Not read end to end.
- ⚠ `entity_lock = 100` on a **`Package`** unit load is normal — a packed parcel awaiting goods-out. The defect signature is lock 100 on a **Tote**; a census that does not split by `unitload_type` overstates the problem, as the first analysis pass did.
- **`TestDataFactory` internals were not audited** — a fixture that sets `pickingtoteId` through it would not appear in the §8 `setPickingtoteId` census, so a second unexpected red is possible.
- The AC-2 ordering measurement (`pickfromstockunit_id IN (7 ids) → 0`) is **measured-theoretical, not a positive control**: exactly 1 row tenant-wide has a non-null `pickfromstockunit_id` at all, so the zero is a base-rate artifact and cannot show the scan would detect a true positive. Revision 1 labelled it a positive control; that label is withdrawn. The ordering decision does not depend on it (§5 point 2).

## 13. OMC composition

**T3** (data integrity · no operator path out · OMS-facing endpoint). Pre-draft done (DB lane, enumeration lane, architect consult) → **two independent review lanes, both ITERATE** (§14) → this revision → **`executor`** for implementation → the floor: DB query (done, §1–§3) · failing test first · **PIT** mutation-check per assertion · `code-reviewer` independent pass with every finding fixed including Low · all four test classes vs the §8 baseline. **No verify script** (§8). Commit directly: one commit for code, one for the doc corrections.

## 14. Review log

Revision 1 (336 lines) was frozen and graded by **two independent lanes** on the same `origin/develop` snapshot (`221caed1`). Neither saw the other's report; both returned **ITERATE**, and they converged on the same top finding.

| Lane | Verdict | Report |
|---|---|---|
| architect (`arch-review-3339`) | ITERATE — 3 blocking, 8 required | [`plan-review-architect.md`](./SBDEV-3339-evidence/plan-review-architect.md) |
| critic (`critic-3339`) | ITERATE — 3 High, 4 Medium, 5 Low | [`plan-review-critic.md`](./SBDEV-3339-evidence/plan-review-critic.md) |

**Convergent findings (both lanes, independently):**

1. **Fix 1 copied only half of `cleanUpCancelledOrder`** — the `pickingorder_unitload` retirement was dropped, and dropping it trades stranded stock for an `IncorrectResultSizeDataAccessException` on the packing path. Verified against the code and against Hydra PRD (162 rows, exactly 2 with a non-null `unitload_id`, zero duplicates today). → Fix 1 block 2, §2 invariant (b), AC-7, prereq 4, prereq 5's runbook sequencing, §5.6 items 2-3.
2. **`CancelOrderRollbackIntegrationTest` does not pin what revision 1 cited it for**, three times over. → all three citations struck; the rollback-coverage gap is named rather than papered over (§8 "Deliberately skipped").

**Architect-only:** §3's discriminator is dead code from this caller, raising severity (→ §3 re-derived, §4 diagram corrected, §8 tenant advice inverted); the lock-order rationale asserted two claims that cannot both hold (→ §5 point 2 and §10 row 8 rewritten, and the production comment in the Fix 1 snippet corrected — a wrong comment frozen next to a mutation-checked test is durable misinformation); §5.3's "introduces no new exposure" is false (→ re-stated as *extending* one); `spring.jpa.open-in-view=false` is the real guarantee under Fix 3 (→ §5.2); AC-6 graded one exception class (→ parameterised); no operator prerequisite for the physical tote move (→ prereq 7); `realignForMovedStockUnit` writes pick lines (→ §12); extraction follow-up (→ §5.6 item 1).

**Critic-only:** §8's central claim — that the fix breaks no existing test — is **false**; `shouldSkipRapidPickingCleanupWhenNotStarted` goes red, and revision 1's *"Any deviation is a regression, not noise"* would have made the implementer revert a correct fix (→ §8 rewritten, §6–§7 amended); Fix 3's blanket catch would have changed the pre-existing 400 rejection contract and broken `shouldReturnBadRequestWhenOrderInWrongState` (→ Fix 3 re-specified around `ToteTeardownException`, `OrderRestControllerUnitTest` added to the baseline, §9 row added, prereq 6 widened); §5.4's per-file counts were wrong throughout (→ 36/13/4/1 = 54 across 4 test files, 12 docs files, cost re-scoped); `setEntityLock` was 90, not 94 (→ corrected); AC-6's named mutant does not exist in the code (→ real mutant named); §1's `RECEIVED` qualifier (→ restored); §0 row 2's line number (→ `:506`); the AC-2 "positive control" is a base-rate artifact (→ relabelled, §12); the unconditional-clear policy is already pinned by `shouldCleanUpWithStockUnitsAndPositions` (→ §5.3 evidence).

**Unchanged and re-confirmed by both lanes:** the root-cause quote and the omission table, the day-one-not-a-regression chain, the `PICKED_FOR_GOODSOUT` producer census and its blind spot, Fix 2's NPE mechanism, the §5.2 throw-source list, the `errors`-map claim, the `UtilRestController` dead-route finding, the argument-transposition non-goal, not clearing the tote's own lock, `cancelBatch`'s deadness, the `T-0010` withdrawal, the `LENIENT`-strictness observation, and declining the verify script.

### Round 2 (2026-09-14) — targeted re-review of revision 2

Verdict **ITERATE**, narrow: all five round-1 blockers verified **CLOSED** (each checked as *correct*, not merely present), plus two new findings inside Fix 3. Both applied below; the reviewer stated it would approve with them applied and no further round.

1. **H1 — the containment catch list was provably incomplete, and failed in the most likely case.** Revision 2 specified `catch (BusinessException | FacadeException e)` plus `DataAccessException`. But `net.aim_ai.wms.exceptions.EntityNotFoundException` is **`extends RuntimeException`** and is **not** a `DataAccessException`, and it is exactly what `sendToClearing` raises via `locationRepository.findByName(STORAGE_LOCATION_CLEARING).orElseThrow(...)` — prerequisite 1's scenario and §5.2's first-listed new throw source. Uncaught, it reaches the controller's `catch (Exception e)` → `GENERIC_ERROR` → the whole batch aborts, i.e. Option A, silently, precisely where Option B was chosen. → **wrap now catches `Exception`** (fail-closed); §9's mitigation corrected.
2. **H2 — the wrap was graded by no test.** AC-6's checked-vs-unchecked parameterisation sat on `OrderRestControllerUnitTest`, where `customerorderService` is a **mock**, so both parameters deliver the identical `ToteTeardownException` — vacuous exactly where H1's defect lives. → **AC-8 added** on `CustomerorderServiceUnitTest`, parameterised over `BusinessException` / `FacadeException` / `EntityNotFoundException` / `DataAccessException`, with the narrowing mutant that must go red; AC-6's vacuous parameterisation removed.
3. **M2 — the baseline was too narrow.** Three classes run the **real** `cancelOrder` and were absent: `TransferLaneLeakOnCancelIT` (grades a line just below Fix 1's insertion point), `CustomerorderOutboxIntegrationTest`, `CancelOrderRollbackIntegrationTest`. → all three **measured green** and folded into the baseline above; total is now **317 tests, 0 failures**, measured rather than declared.

**Cumulative:** three review passes (architect · critic · targeted re-review), two independent ITERATE verdicts in round 1 reaching the same blocking finding by different routes. Every finding across all rounds concerned the **fix's completeness** or **what the existing suite actually proves** — none touched the diagnosis, which has stood unchanged since the triage probe.

---

## 15. TDD gate results (2026-09-14)

**Worktree:** `.claude/worktrees/wms2-api/SBDEV-3339` · **branch** `feature/SBDEV-3339-cancelorder-picking-tote-teardown` off `origin/develop` @ `221caed1`.
**8 gate tests written · 7 fail for the right reason · 1 unexpected pass · 0 broken scaffolding.** `mvn -o test-compile` clean.

Failure types (parsed from surefire XML, reconciling with Maven's own `Tests run: 8, Failures: 7`): 3 × `AssertionFailedError`, 2 × Mockito *Wanted but not invoked*, 2 × `AssertionError` with attributable messages. **No setup NPEs, no compile errors.**

### 15.1 ⚠ AC-4 currently passes and is NOT a gate

`cancelOrder_shouldSkipTeardown_whenNoPickingTote` is green **before** the fix, because it asserts that no teardown happens when there is no tote — and today no teardown happens at all. It is vacuous until Fix 1 lands, after which it guards the null check. Keep it as a **regression guard**; do not count it as evidence that AC-4 is satisfied, and do not read its green as gate progress.

### 15.2 ⚠ CORRECTION — Fix 2's target line is unreachable in production

§5's Fix 2 justification ("a latent NPE surfacing as `GENERIC_ERROR`") is **false as the code is currently wired**, and neither review round caught it.

`forceCancelOrder`'s guard sits inside `if (customerOrder.getState() < WmsConstants.State.PACKED)`. *Deriving method:* `git grep -n "forceCancelOrder" -- 'src/main/**/*.java'` → exactly **one** call site, `cancelOrder`'s `forceCancelOrder(customerOrder);`, reached only under `if (isPackedOrPalletized(customerOrder))`, which is `Integer.valueOf(PACKED).equals(state) || Integer.valueOf(PALLETIZED).equals(state)` — i.e. state is 650 or 670, so `< PACKED` is never true. *Positive control:* the same grep returns the declaration and two `LOG.debug` lines, so it reads the file. *Blind spot:* reflective invocation — which is exactly how the gate test reaches it, and how `AC-13` already does.

**The NPE itself is real** — the gate test reproduces it: `java.lang.NullPointerException: Cannot invoke "java.lang.Integer.intValue()" because the return value of "net.aim_ai.wms.model.Unitload.getEntityLock()" is null`.

**Disposition: keep Fix 2** (one line, correct, and the dead branch is a trap for whoever makes it reachable) but **re-state its justification as hardening unreachable code, not fixing a live production fault.** AC-5 grades it by reflection, following the precedent already in `CustomerorderServiceUnitTest`'s AC-13 test.

### 15.3 AC-6 / AC-8 behavioural tests are deferred by design

`ToteTeardownException` does not exist, so those tests cannot be expressed in compiling Java yet. The gate wrote a **reflection contract test** (`toteTeardownException_shouldExistAndExtendFacadeException`) which fails correctly today and pins: the type exists, extends `FacadeException`, is **not** a `RuntimeException`, and accepts a cause.

⚠ **The parameterised AC-8 test is the only thing that grades the service-side wrap — it is why round 2 returned ITERATE, and it must land in the executor's first commit once the type exists.** Its mutant (narrowing the wrap to `catch (BusinessException | FacadeException)`) must turn **both** unchecked parameters red; if it does not, the wrap is not being graded and the gate has not actually passed.

---

## 16. Review-lane findings and dispositions (2026-09-14)

Two independent lanes on commit `c84c799f`: `verifier` → **PASS** conditional on 2 must-fix; `code-reviewer` → **ITERATE**, 1 High / 2 Medium / 3 Low. They converged on the same two top findings from different directions.

| # | Finding | Disposition |
|---|---|---|
| **H1** | A partial batch still writes the clean-success service-log row (`createMessage(... RECEIVED, "200" ...)` is unconditional and sits **above** the partial return), while a source comment claimed it did not | **Comment corrected** to state the gap plainly as unresolved. **Behaviour pinned** by an `ArgumentCaptor` assertion in AC-6 so the row's status/code cannot change silently. ⚠ The status *vocabulary* is **prerequisite 6 — owner's decision, deliberately not guessed.** Measured by the reviewer with a captor probe, not inferred |
| **M1** | AC-7's `InOrder` ordering assertion was specified twice in §8 and never written; hoisting the whole teardown above the `cancelOrderPosition` loop left the suite green (measured 134 run, 0 failures) | **Fixed** — `InOrder` on `cancelOrderPosition` → block-2 `save`. Hoist mutant now kills AC-7; revert MD5-verified |
| **M2** | Accumulated teardown errors were discarded when a *later* order in the batch hit a hard rejection — the 400 path never reads the `errors` map | **Fixed** — `logDiscardedTeardownFailures(...)` on both throwing arms. Each failure was already logged at ERROR when it happened; this adds the aggregate at the abort |
| **L1** | AC-4 was missing its third specified `never()` (`findLatestByUnitloadLabelid`) | **Fixed** |
| **L2** | The lock clear is not tree-recursive while `processTransfer` is, so a **carrier child's** stock stays at `entity_lock = 100` | **Dispatched, not fixed.** Same shape as both siblings, so pre-existing and not introduced here — fixing it in this diff would change `cleanUpCancelledOrder`'s behaviour too, which is outside this ticket. Recorded in §5.6 as a follow-up; **AC-1's wording is scoped to stock directly on the tote**, not its carrier children |
| **L3** | The Micrometer counter named in §5.2/§6 was neither implemented nor dispatched | **Dispatched, not fixed.** `OrderRestController` has no `MeterRegistry` (positive control: `grep -c MeterRegistry` → 0 there, ≥1 in `CustomerorderService`), so adding one is a new dependency on a controller. Prerequisite 5 already records that **nothing scrapes Prometheus**, so the counter would be unread on arrival while the ERROR log is the operative control. If metrics land later, add it with the rest |

**Design dispute, owner's call (prereq 6):** the reviewer's view is that `200` + an explicit `status: "partial"` is right and `207` is not — *conditional on the service-log row agreeing*, which H1 shows it currently does not. Recorded, not resolved.

⚠ **Hazard for any future lane working in this worktree:** the reviewer's first suite run reported 2 failures that were **its own artifact** — it copied the tree while a sibling lane had `CustomerorderService.java` transiently modified, producing a copy missing `setPickingtoteId(null)`. Verify a copy byte-for-byte (`diff -r`, or md5) against a clean `git status` before trusting any result taken from it.

### §5.6 follow-up register (candidates for their own tickets, none filed)

1. **Carrier-child stock is never unlocked on cancel** (L2). Present in `cancelOrder` (new), `forceCancelOrder` and `cleanUpCancelledOrder` alike. Blast radius unmeasured — no Hydra PRD tote in the stranded set had a carrier child, so it has never fired there.
2. **`cleanUpCancelledOrder` still calls the unsafe `PickingorderUnitloadService.getByLabel`**, which wraps `findByUnitloadLabelid` and catches only `NoSuchElementException` — so it throws `IncorrectResultSizeDataAccessException` uncaught once a tote has two live rows. Not reachable while the invariant holds; this ticket's Fix 1 uses the safe finder and preserves the invariant.
3. **`forceCancelOrder`'s `state < PACKED` branch is dead** (see §15.2) — a large block of untested, unreachable code. PIT corroborates: most surviving mutants in that method sit inside it.

---

## 17. Implementation status — PR submitted 2026-09-14

**PR:** https://github.com/SiteBossInc/wms2-api/pull/354 (base `develop`) · **Branch:** `feature/SBDEV-3339-cancelorder-picking-tote-teardown` · **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3339` (retained for review feedback; `archive-plan` step 5f owns removal after merge)

| Commit | Subject |
|---|---|
| `c84c799f` | SBDEV-3339 cancelOrder must tear down the picking tote |
| `43df4d75` | SBDEV-3339 address review-lane findings (H1, M1, M2, L1) |

Based on `origin/develop` @ `221caed1`, confirmed ancestor of HEAD.

### Files changed (5; +593 / −1)

| File | Change |
|---|---|
| `exceptions/ToteTeardownException.java` | **new** — checked `FacadeException` subclass; no signature change needed anywhere |
| `service/CustomerorderService.java` | Fix 1 teardown (incl. `pickingorder_unitload` retirement) + Fix 2 null-safe guard + the `catch (Exception)` wrap |
| `controller/rest/OrderRestController.java` | Fix 3 scoped containment, partial response, `logDiscardedTeardownFailures` |
| `unit/service/CustomerorderServiceUnitTest.java` | AC-1/2/4/5/7/8 + contract test; amended `shouldSkipRapidPickingCleanupWhenNotStarted` into a second AC-1 witness |
| `unit/controller/rest/OrderRestControllerUnitTest.java` | AC-6 + the service-log captor pin |

### Tests

- Targeted: **321 pass / 0 fail / 0 error / 0 skipped** (baseline 308 + 13 new — reconciles exactly)
- **Full unit suite: 6,582 pass / 0 fail / 0 error / 1 skipped**
- Failsafe (`TransferLaneLeakOnCancelIT` 2 · `CustomerorderOutboxIntegrationTest` 3 · `CancelOrderRollbackIntegrationTest` 4): **9 / 0**, unchanged from baseline
- No verify script (T3 opt-in, declined). Working tree clean after every suite run — no ArchUnit store mutation.

**Mutation checks.** PIT scoped to `CustomerorderService`: of 11 mutants inside the new teardown block, 9 killed, 1 `NO_COVERAGE`, **1 survived** (`setHistorytote` on the retired row) — a genuine assertion gap in AC-7, now closed and re-killed. Two mutants PIT cannot express were hand-applied with byte-exact reverts (md5-verified): narrowing the wrap to the checked types (turns **both** unchecked AC-8 parameters red) and hoisting the teardown above the loop (now kills AC-7; previously left 134 run / 0 failures).

### Deliberately skipped / deferred

- **AC-5 grades unreachable code** — see §15.2. Kept; justification corrected.
- **`cancelOrder_shouldSkipTeardown_whenNoPickingTote` was green pre-fix** — regression guard, not a gate (§15.1).
- **L2 carrier-child stock, L3 Micrometer counter** — dispatched to the §5.6 register, not fixed (§16).
- **AC-6's ERROR-log clause is asserted only via the response body**, not the log line itself.
- **No DB/prerequisite verification was run** against a live tenant; the manual test plan (§8) is unexecuted.

### ⚠ Open, blocking merge only

Prerequisite 6 — the OMS response contract: body shape, HTTP status, and the **service-log row status**. Current behaviour (`200` + `{status: partial, errors}`, service log still `RECEIVED` / `200`) is pinned by an `ArgumentCaptor` assertion so any change is deliberate. Owner's decision; does not block review.

### Landmines found during implementation that the plan did not predict

1. **`OrderRestControllerUnitTest` runs under STRICT_STUBS** (unlike `CustomerorderServiceUnitTest`, which is `@MockitoSettings(LENIENT)`). A `doThrow` on one order made the other orders' calls a strict-stubbing violation — raised *inside* the controller's try block and swallowed by its `catch (Exception)` as GENERIC_ERROR, so it presented as a production bug in the fix. Mockito's summary printed wanted and actual as visually identical; only the logged stack named `PotentialStubbingProblem`. Fix: `lenient().doThrow(...)`.
2. **`-Dtest` separates multiple CLASSES with `,`; `+` separates methods** — using `+` matched nothing, printed no output at all, and left stale surefire XML.
3. **A regex-based surefire XML parse mis-attributes failures across a self-closing `<testcase/>`**, silently moving a failure onto the preceding (passing) test. Use a real XML parser and reconcile against Maven's own totals.

---

## 18. Prerequisite 6 — RESOLVED 2026-09-14

Settled by reading the only client rather than choosing a shape. Commit `65665705`.

### The earlier `"partial"` token was a defect, not a placeholder

```php
// v2/oms-laravel-api — WmsApiService::isFailureResponse
return isset($response['status']) && $response['status'] === 'failure';
```

Any token other than exactly `failure` is read as **success**. So the first implementation's `{status: "partial"}` made OMS log *"Order positions cancelled in WMS successfully"* for a batch that left an order uncancelled — **silent loss, the exact failure the containment exists to prevent.** Caught only by going to the client; every review lane had passed it, because nothing in the WMS repo reveals it.

### The three sub-decisions

| Sub-decision | Resolution | Why — derived, not preferred |
|---|---|---|
| **Body** | `{status: "failure", message, errors}` | `"failure"` is the only token `isFailureResponse` recognises. `errors` keeps the per-order detail the caller would otherwise lose |
| **HTTP status** | **200**, not 4xx or 207 | A non-2xx makes `makeWmsRequest` throw `WmsException` → `error_type = TYPE_VALIDATION` → `OrderWmsRecallService` reads it as the WRONG_STATE refusal, documented there as *"Not retryable"*. A teardown failure **is** retryable: `cancelOrder` short-circuits on `isAlreadyCancelled`, so re-sending no-ops the successes and retries only the failure. **207 changes nothing** — Laravel's `successful()` covers all 2xx — while adding a status no caller handles |
| **Service-log row** | `FAILED` / `400` for a partial batch | Those rows are the instrument this defect was diagnosed from (8 `ORDER_BATCH_CANCELLED_FROM_PSD` rows matched the 8 cancelled orders and dated both stranding events). A partial batch recorded as a clean `RECEIVED`/`200` receipt is invisible to that technique next time. **Not an OMS-facing change** — OMS keeps its own `service_log` via `WmsApiService::logWmsRequest` and never reads this table. `FAILED`/`400` follows the precedent already in `updatePriority`'s rejection path |

### Caller impact, checked on both sites

- `OrderWmsRecallService` — declines the hold, and because `error_type` is absent it correctly does **not** flag `wrong_state`, so the failure reads as retryable rather than as a state refusal.
- `LegacyOrderCancelService` — logs a warning and returns `true` regardless (*"WMS failure should not block OMS cancellation"*), so the OMS-side cancel proceeds and the signal is recorded.

Neither cascades harmfully; both now see a failure they previously could not.

### Grading

AC-6 was rewritten to grade the resolved contract instead of pinning the gap. Both new assertions mutation-checked with md5-verified reverts: reverting the token to `"partial"`, and making the service-log row unconditionally `RECEIVED`/`200`, each turn AC-6 red with a message naming the cause.

**Full unit suite 6,582 / 0 fail / 1 skipped · targeted 321/0 · failsafe 9/0.**

⚠ **Generalisable lesson:** the response contract could not be settled from inside `wms2-api`. Four review passes accepted `"partial"` as reasonable; the client's one-line equality check is what made it wrong. For any contract question, read the consumer.
