# Lane 2 — Locking, concurrency and lost-update races (WMS v2, origin/develop df30fa62)

Scope: `scratchpad/wms2-develop/src/main/java` + `src/main/resources/db/migration`. Read-only.
Prior art read first (targeted): `wms2-transaction-osiv-boundary-map.md` §8 (8.1–8.6) + §10, and
`260507-picking-lock-ordering-inconsistency.md` (§5 lock maps). Nothing below re-reports those items.
PostgreSQL default isolation READ COMMITTED assumed (no isolation override found in tenant config).

Paths are relative to `src/main/java/net/aim_ai/wms/`.

## Code Review Summary

Files reviewed (bodies read): 22. Findings: 7 (0 CRITICAL, 0 HIGH, 3 MEDIUM, 4 LOW) plus 1 open question.

| # | Sev | Conf | Title | Callee bodies read |
|---|---|---|---|---|
| F1 | MEDIUM | HIGH (mechanism) / MEDIUM (reachability) | Transfer-lane `FOR UPDATE` does not serialise the availability check (write skew), two orders can get one lane | yes |
| F2 | MEDIUM | HIGH | Staging-lane assignment is check-then-act with no lock or constraint at all | yes |
| F3 | MEDIUM | HIGH (code) / MEDIUM (reachability) | Goods receipt find-or-create per advice is locked on the POSITION, not the advice; duplicate `goodsreceipt` rows + `get(0)` pick | yes |
| F4 | LOW | HIGH | Mobile transfer-order `transferStock` aggregate check is unlocked and non-transactional, so two handhelds over-transfer to the lane | yes |
| F5 | LOW | HIGH | ReplenishOrderJob 6a/6b bulk `UPDATE … WHERE id IN :ids` drops the select's guards (manual override, state) and can clobber a manual priority | yes |
| F6 | LOW | HIGH | Count-based position numbering (`generateNumberWithAdvice`, `generateNumberWithGoodsReceiptByCount`) with no unique constraint, concurrent duplicates | yes |
| F7 | LOW | HIGH | `shipperid` find-or-create during order import races on `UNIQUE(externalid)` and fails the whole batch import | yes |
| OQ1 | LOW | LOW | Native bulk `assignToteToAllPositions` leaves other managed positions stale; full-column UPDATE could revert `picktounitload_id` | partly |

No CRITICAL/HIGH at HIGH confidence. Recommendation: **COMMENT**. F1 and F2 are the ones to fix.

---

## Findings

### F1 [MEDIUM] Transfer-lane lock does not prevent double assignment (write skew under READ COMMITTED)
- **Where:** `repo/jpa/LocationRepository.java:199-215` (`getAvailableTransferLanesForUpdate`), used by
  `service/TransferOrderService.java:102` (`assignTransferLaneToTransferOrder`) and `:144`
  (`activateAndAssignTransferLane`). Endpoints: `controller/TransfersController.java:110,161,190`.
- **Code path:** the query selects lanes `WHERE transferlane AND NOT EXISTS (customerorder co WHERE co.transferlaneId = l.id AND co.id != :me AND co.state < 700)` with `PESSIMISTIC_WRITE` (renders `FOR NO KEY UPDATE`). The service then writes `customerorder.transferlane_id` and state 510. **The lock is on `location` rows; the write is on `customerorder`; the lane row is never updated.** The comment at `:196` says this "serializes concurrent lane assignment (SBDEV phase-3 lane-race fix, a6b8d6b)".
- **Interleaving:**
  1. T1 (assign order A to lane L) runs the query: L passes NOT EXISTS, L is locked.
  2. T2 (assign order B to lane L) runs the same query. Its statement snapshot is taken now: A does not yet hold L, so L passes NOT EXISTS; T2 blocks on L's row lock.
  3. T1 sets `A.transferlane_id = L`, state 510, commits. L itself is unchanged.
  4. T2 gets the lock. PostgreSQL re-evaluates the WHERE (EvalPlanQual) only if **the locked row** changed; L did not, so L is returned as-is, and the NOT EXISTS result from the old snapshot stands.
  5. T2 sets `B.transferlane_id = L`, commits. **Two open transfer orders are on lane L.**
- **Why @Version does not help:** A and B are different rows; each version check passes.
- **Impact:** two transfer orders share a lane. Lane stock (`isEnoughStockOnTransferLane`, `calculateStockOnStagingLane`) is computed per lane, so each order counts the other's stock and may be under-built or skip "No stock required". Requires two web operators assigning the same lane within the T1 lock window (select → save → commit, ms to tens of ms). Rare, silent when it happens.
- **Not covered by tests:** `ActivateTransferAtomicityIT` has no concurrent case (`assignOfHeldLane_isRefused…` is sequential).
- **Fix (pick one):**
  (a) After the locking select, re-check availability in a NEW statement. READ COMMITTED takes a fresh snapshot per statement, so the second read sees T1's commit: `getAvailableTransferLanes(...)` (unlocked variant) or an `existsOtherOpenOrderOnLane(laneId, me)` count, and refuse if taken.
  (b) Better: `CREATE UNIQUE INDEX … ON customerorder(transferlane_id) WHERE transferlane_id IS NOT NULL AND state < 700`. First check current data for violations, then map the 23505 to a "lane no longer available" refusal.
  Option (a) keeps the existing facility-wide lock. Option (b) makes the lock unnecessary.

### F2 [MEDIUM] Staging-lane assignment: unlocked check-then-act, no constraint
- **Where:** `service/CustomerorderBatchService.java:1244-1272` (`assignStagingLaneToOrderBatch`) via
  `getAvailableStagingLanes` → `LocationRepository.java:113-123` (plain query, **no lock**). Callers:
  `controller/ClubLineController.java:117` (`/assignStagingLane`) and `:170` (`/activateBatch`).
- **Interleaving:** T1 (batch X → lane S) and T2 (batch Y → lane S) both read S as available (no other batch with `staginglane_id = S AND state < 530`), and both save. Different `customerorder_batch` rows, so both version checks pass, and **two club batches hold one staging lane**. There is no unique index on `customerorder_batch.staginglane_id` in the migrations.
- **Impact:** same class as F1, on the club side: club-line unit-load views (`getClubLineUnitLoads(onlyStagingLocation)`) and stock-on-lane counts mix two batches.
- **Fix:** same as F1. A partial unique index `ON customerorder_batch(staginglane_id) WHERE staginglane_id IS NOT NULL AND state < 530` is the cheapest correct guard. Alternatively, use a locked availability query plus a second fresh-statement re-check (the F1(a) pattern; a lock alone is not enough, see F1).
- Note: `unlinkStagingLaneFromOrderBatch` (`:1276`) is not `@Transactional` and saves a detached batch. The merge version-checks it, so it fails closed. Clean.

### F3 [MEDIUM] Duplicate goods receipts per advice: find-or-create locked on the wrong row
- **Where:** `service/ReceivingService.java:484-505` inside `receiveGoods` (`@Transactional`, `:372`). The only lock taken is `advicepositionRepository.findByIdForUpdate(advicePositionId)` at `:418`.
- **Code:** `goodsreceipts = goodsreceiptRepository.findByAdviceId(adviceId); if (isEmpty) create+save else get(0)` (`// TODO … select the correct one`). Base schema has no unique constraint on `goodsreceipt.advice_id` (only PK + FKs, `V2.2.00:3288-3300`).
- **Interleaving:** operators O1 and O2 receive the FIRST cases of two different positions P1 and P2 of the same advice A at the same time. T1 locks P1, T2 locks P2: no conflict. Both see no goodsreceipt for A. Both insert one. **A now has two `goodsreceipt` rows.** Every later receive attaches to `goodsreceipts.get(0)`, whose order is unspecified (`findByAdviceId` is a derived query with no ORDER BY), so later positions can split across both receipts.
- **Knock-on:** the GR position number is `countByGoodsreceiptId(gr) + i` (`:588`, `:608`). Concurrent receives on different positions that share one GR compute the same count, so goods-receipt position numbers duplicate (see F6).
- **Not covered by the SBDEV-3736 lock-order javadoc** (`ReceivingService.java:805-880`), which deals with advice-finish races only.
- **Fix:** lock the parent before the find-or-create, e.g. `adviceRepository` `lockById(adviceId)` (scalar `select a.id … PESSIMISTIC_WRITE`, LockReads shape). Take it before the position lock to keep a parent→child order, or after it consistently on every receive path. Alternatively, add `UNIQUE(advice_id)` on `goodsreceipt` after a data census, and on 23505 re-read. Either way, add `ORDER BY id` to the reuse read.

### F4 [LOW] Mobile transfer-order: over-transfer to lane from two handhelds
- **Where:** `service/mobile/MobileTransferOrderService.java:353-447` (`transferStock`). The method is **not** `@Transactional` (comment at `:385-387` confirms).
- **Code:** `amountOnTransferLane = stockunitRepository.getAmountAvailable(lane, item)` (`:370`, `:450`), then `amountLeft = needed - onLane`, then `createUnitload` + `transferStockToUnitLoad(… amountLeft …)`. Neither the customer-order position nor the lane is locked.
- **Interleaving:** handhelds H1 and H2 work the same transfer-order position (need 12, lane has 0). Both read onLane = 0 and amountLeft = 12, and both move 12 from different source SUs. **The lane gets 24 for a need of 12.** Per-SU amount is safe: `transferStockToUnitLoad` re-checks `availableForTransfer` under the SU lock (`StockunitBusinessService.java:277-281`). Only the aggregate overshoots.
- **Impact:** recoverable by moving stock back. Silent, with no error.
- **Fix:** lock the `CustomerorderPosition` (`customerorderPositionRepository.findByIdForUpdate`) at the top of a transactional wrapper and re-read `getAmountAvailable` under it. Mind the "Pickingorder before Stockunit" house order: take the position lock before `transferStockToUnitLoad`'s SU/UL/Location locks.

### F5 [LOW] Cron priority bulk update drops the select's guards (TOCTOU, bypasses @Version)
- **Where:** `schedulejob/ReplenishOrderJob.java:858-897` → `service/job/ReplenishOrderJobService.java:250-256`
  → `repo/jpa/ReplenishorderRepository.java:441-443`: `UPDATE Replenishorder r SET r.prio = :priority WHERE r.id IN :ids`.
- The id page query (`ReplenishorderRepository.java:~380-405`) filters `manuallyOverridePriority = false AND state < STARTED AND prio != …`. The UPDATE re-checks none of it, and the select and the update run in different transactions (the select runs in the job; the update runs in the REQUIRES_NEW `updateReplenishmentOrderPriorityBulk`).
- **Interleaving:** the cron selects R (manual = false, prio 500). An operator calls `ReplenishorderService.updatePriority(R, 900)` (`:219-232` → `:252-258`), which sets prio 900 and `manuallyoverridepriority = true` and commits. The cron runs `UPDATE … SET prio = 0 WHERE id IN (R)`. **The manual 900 is overwritten with 0, while the manual flag stays true**, so no later 6a/6b pass will ever correct it (both skip manual rows). Bulk JPQL does not bump `@Version`, so nothing detects it.
- The window is per page (select → update) and small. The result is persistent until an operator notices.
- Also: the `catch (OptimisticLockException | OptimisticLockingFailureException)` around the bulk call (`ReplenishOrderJob.java:874`, `:891`) is dead code, because a bulk UPDATE cannot raise it.
- **Fix:** copy the guards into the UPDATE: `… WHERE r.id IN :ids AND r.manuallyoverridepriority = false AND r.state < :started`. Then the row lock the UPDATE takes plus PostgreSQL's re-evaluation make it atomic.

### F6 [LOW] Count-based child numbering, no unique constraint
- `service/BasicService.java:94-100` `generateNumberWithAdvice` = `findByAdviceId(..).size()` (no +1). Callers: `ReceivingService.java:263,315`, `AdviceRestController.java:554,764,926`, `FileImportController.java:525`.
- `BasicService.java:102-107` `generateNumberWithGoodsReceiptByCount`, used with `countByGoodsreceiptId` (`ReceivingService.java:588`).
- `adviceposition.number` and `goodsreceiptposition.number` have no unique constraint (confirmed in base schema; `V2.2.25__…sql:21-23` already acknowledges the advice side and defends the report with LATERAL … LIMIT 1).
- **Interleaving:** two concurrent `updateAdviceWithPositions` calls on one advice (`ReceivingService.java:282-330`, plain `findById` of the advice, no lock) both count N and both number the new position `…-N`. Same for concurrent receives sharing a GR (F3). Deletion also causes reuse, even serially.
- Impact: `stockrecord.ordernumber` carries the position number (`createStockUnit(…, adviceposition.getNumber(), …)`), so the RETURN resolver in V2.2.25 can resolve to the wrong advice position.
- Also seen in passing (not concurrency): `ReceivingService.java:317` `setExternalid(advice.getExternalid() + 1)` is string concatenation, so every position added through this path gets the same externalid `"<ext>1"`.
- **Fix:** draw from `LosSequencenumber` (`generateNumber`), or lock the parent advice/GR before counting (shares the F3 fix).
- `generateOrderNumber` (`BasicService.java:79-85`, count+1) is **clean** for concurrency: both callers (`OrderBatchCreationService.java:106`, `AdviceService.java:253`) mint into a batch they just created in the same transaction, and `customerorder.number` is UNIQUE.

### F7 [LOW] Shipper-id find-or-create during order import
- `service/OrderBatchCreationService.java:66,95-98`: `shipperIDList = findAll()` once, then `createShipperID` if the external id is absent (`ShipperidService.java:42-60`, no lock).
- `shipperid.externalid` is UNIQUE, so two concurrent OMS batch imports that introduce the same new shipper both insert. The loser gets a `DataIntegrityViolationException` from the save at flush/commit, and **its whole batch import rolls back** (the try/catch at `:80-84` wraps only the batch save, not this). It fails closed, with no silent corruption.
- **Fix:** `INSERT … ON CONFLICT (externalid) DO NOTHING` + re-read, or catch DIVE in a REQUIRES_NEW create and re-read.

---

## Open Questions (low confidence, not blocking)

### OQ1 [LOW] Stale managed `PickingorderPosition` siblings after native `assignToteToAllPositions`
- `service/mobile/MobilePickingService.java:627` runs a native UPDATE of `picktounitload_id` for all of the order's positions on the picking order (`PickingorderPositionRepository.java:167-171`, bare `@Modifying`, no clear/flush). The code re-handles the **current** position: `confirmPick` sets `picktounitloadId` itself (`PickingorderBusinessService.java:1387`), and `:1346` is null-tolerant.
- No entity has `@DynamicUpdate` (only `OutboxMessage`), so a full-column UPDATE is issued for any dirty entity. If any **sibling** position of that order is managed in the same persistence context, dirtied and flushed later in the same transaction, its UPDATE writes the stale `picktounitload_id` (null) back over the native write.
- I did not trace whether processPick loads and dirties siblings after `:627`. PLAUSIBLE. Probe: add `clearAutomatically=false` awareness. The simplest fix is `@Modifying(flushAutomatically = true)` plus `entityManager.refresh` of any managed sibling, or set the field on managed siblings in Java instead of native SQL.

---

## Checked and found clean (or already documented, not re-reported)

- **Exception mapping.** `ObjectOptimisticLockingFailureException` → 409 and `PessimisticLockingFailureException` → 409 (`exceptions/RestExceptionHandler.java:384-399`). `/rest/**` maps `CannotAcquireLock`/`DeadlockLoser` to 503 (`RestEndpointExceptionHandler.java:80-115`). Mobile maps `DataIntegrityViolationException` (`MobileEndpointExceptionHandler.java:90`). Version conflicts from detached-entity saves therefore surface as 409, not 500 and not swallowed. **Gap:** non-mobile, non-`/rest` controllers have no `DataIntegrityViolationException` handler, so unique-constraint races there (F7, label collisions) return a generic 500. LOW, noted only.
- **`LockReads.forUpdate`** (`service/LockReads.java`): for a managed row, it scalar-locks, auto-flushes pending edits of that table (JPQL auto-flush), then refreshes. It does not discard unflushed edits and has no version-checked upgrade. Item 4 of the brief ("lock after unlocked read returns stale entity") is handled by this helper for the 51 call sites that use it. The raw `findByIdForUpdate` sites I sampled (`MobilePickingService` 394/493/772/878, `CustomerorderPositionService:192,198`, `PickingorderBusinessService:1424,1465,1483`) fail **closed** (SBDEV-3244 version-checked upgrade → stale-object 409), not silently. They are not lost updates. I did not exhaustively trace whether each of the ~117 raw sites can see a pre-managed row.
- **Stockunit amount/reserved RMW.** All mutation is centralised in `StockunitBusinessService`: `changeAmount` `:612` and `changeReservedAmount` `:662` lock via LockReads and re-check `amount >= reserved` under the lock. `transferStockToUnitLoad` `:277-358` locks src SU → src UL → src Loc → dst UL → (dst SU) → dst Loc and re-reads the destination SU list under the dst UL lock, which closes the duplicate-SU find-or-create. `sendStockUnitToNirvana` `:583` pre-checks reserved on a stale copy, but the amount>0 branch re-checks under the lock, and the amount=0 branch cannot have a reservation. Clean.
- **`StockunitService.setLockOnHold`** `:884` (unlocked `findById` in tx, then save) and **`removeLock`** `:1440` (no tx, then save): each concurrent change bumps `@Version`, so the save fails 409. Clean, fail-closed.
- **Bulk `@Modifying` on hot entities.**
  - `CustomerorderRepository.updateStateByIds` + `CustomerorderPositionRepository.updateStateByOrderIds` (club finalize, `CustomerorderBatchService.java:878-879`): predicate `state != 800` is re-evaluated after a row-lock wait. `findAllById` afterwards runs in a fresh tx with no prior order load, so it is fresh. No `@Version` bump is a known, documented design. Clean for this lane.
  - `markClientHasNoSection` / `releaseDueFutureTransferOrders`: the WHERE is the CAS guard. Documented. Clean.
  - `bulkUpdatePriorityForItems` (`ReplenishorderRepository.java:636`): guarded predicate. Clean.
  - `updatePriorityByIdIn`: see F5.
  - `LocationRepository.updateDefaultBounds` (SBDEV-3128): locked by `lockById` per its javadoc. Not re-traced.
- **Sequence generation.** `LosSequencenumber` via `BasicService.generateNumber`/`getNextSequenceNumber` (`SequenceTransactionService`). Pick, replenish and batch numbers all go through it. Outside it: F6 only. `ClubRunJobRepository:31` uses DB `nextval('seqentities')`. Fine.
- **Find-or-create, other.** `unitload.labelid` UNIQUE (`createUnitload(name…)` find-or-create, already documented, SBDEV-3688/4050). `replenishorder` partial unique indexes back duplicate-order creation. `fix_location_assignment` UNIQUE on item, location and UL. `customerorder.externalnumber` UNIQUE. All fail closed.
- **Lock ordering.** Release (`ReleaseOrderJobService:141` CO → `:670` SU candidates → `:877-882` cart PO) does take PO after SU. That inverts "Pickingorder before Stockunit", but the cart lock is `SKIP LOCKED` (`lockIdForNoKeyUpdateSkipLocked`), so it cannot wait and cannot deadlock. Clean. Pick confirm CO→PO vs processPick PO→CO(implicit) is already documented in report 260507. Move, replenish, FLA and add-to-pallet orders are already documented in boundary-map §8.5/§8.6 (and their residuals: SBDEV-3787 cross-SU order in `processTransfer`, `getStockUnitsByItemDataIdForUpdate` amount-DESC order, per-position cancel loops).
- **Not covered by this lane (time-boxed):** BOL close lock order beyond the `lockIdsForUpdateOrderById` / `lockChildIdsForUpdateOrderById` id-ordered locks (`BillofladingService.java:1899-1900`, ordered, looks right); cycle-count write paths (`MobileCycleCountService`, 11 plain UL reads); `CancellationReversalService` (6 plain SU reads); `GoodsReceiptPositionService.adjust/delete` (documented residual in the SBDEV-3736 javadoc).

## Positive observations
- `LockReads` is a careful, well-documented answer to the Hibernate lock-upgrade trap, and it is used consistently on the stock paths.
- `lock_timeout` is set at transaction begin, deadlock/timeout exceptions are translated, and both map to 409/503. No silent retries remain inside open transactions.
- State-transition bulk updates use the WHERE clause as a CAS guard (`markClientHasNoSection`, `state != 800`).
- The open-cart fill in release uses `SKIP LOCKED` and re-checks under the lock, which is the right pattern for an opportunistic lock that runs against the house order.
