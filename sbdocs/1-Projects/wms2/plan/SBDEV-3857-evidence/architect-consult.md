# SBDEV-3857 architect consult — trust-the-DB-row design for mobile cycle count
Read at origin/develop c9e8f9a1 (wms2-api worktree) + wms2-mobile-ui 39c30b0. Read-only; nothing run.

## Verdict
The design is right. It needs five additions (M1–M5 below) before the TDD gate. None of them changes the tier (T2). M3 adds no repository method.

## (a) Refuse when the posted unitloadId does not match: yes, refuse
- The UI posts the server's own serialized entity back: `stockUnit: this.stockUnitInfo.stockUnit` (single/recountUnitLoad.vue:56, countUnitLoad.vue:53). That entity comes from `map.put("stockUnit", stockUnit)` (CycleCountLosController scan/count handlers). `Stockunit.unitloadId` has no `@JsonIgnore` (model/Stockunit.java:27), so an honest client always sends it.
- The operator sees `Unitload: {{ stockUnitInfo.unitLoad.labelid }}` (recountUnitLoad.vue:5), which is the posted container. A count of container X says nothing about stock that has since moved to Y. Recording it against Y would be a silent misattribution, so refuse.
- The refusal also catches double-submits for free. A second recount-to-zero locks the row after the first one committed and finds `unitloadId == Nirwana`. The mismatch refuses it before a second ADJUSTMENT position and a second OMS message are created. Use `Objects.equals` so a null posted id also refuses. This is the same shape as `UnitloadService.deleteUnitLoad` (`if (locked == null || !Objects.equals(locked.getUnitloadId(), unitLoadId))`, UnitloadService.java:779).

## (b) The CREATED/STARTED guard fits the real flow
- No main code ever sets a position to STARTED. The only writers set CREATED (CyclecountService:118, CyclecountPositionService:51), FINISHED (MobileCycleCountService:177/227/368/441) or CANCELLED (CyclecountService:157). So the guard really means "not FINISHED/CANCELLED", the same predicate the scan uses (`WHERE ccp.state NOT IN (:finished, :cancelled)`, CyclecountPositionRepository:78).
- A mismatched first count leaves the position untouched: `countCycleCountStockUnit` returns `null` without saving (:394-395), so it stays CREATED and the recount passes the guard.
- No UI path recounts a FINISHED position. bySku/recountUnitLoad.vue:49 re-posts `countData.cyclecountPosition`, the snapshot taken at scan time. The guard also closes a real gap: when the web UI cancels an order, its positions become CANCELLED (CyclecountService:157), and today only the accidental `@Version` mismatch on the posted snapshot stops a device that still has the screen open.

## (c) Lock ordering: no new deadlock shape
- The established order is stockunit → unitload → location (`Stable order: src-stockunit … → src-unitload → src-location`, StockunitBusinessService:302). The recount locks one SU, then `sendToNirvana → transferUnitLoadToLocation` locks the Nirwana location (UnitloadBusinessService:245). That matches the order.
- Both methods refuse more than one SU on the container (:155, :204), so there is never a second SU to order against. `deleteUnitLoad` takes the same SU-first path (id order). Picking locks `pickingorder → SU` (StockunitBusinessService:270); the recount takes no pickingorder lock, so no cycle.
- **M1 (missed): race between two devices on one position (countBySKURecount).** Read the DB position plainly first to get its stockunitId, lock the SU, and only then re-check the position state with `entityManager.refresh(position)`. If the state check runs before the SU lock, the loser of the race fails only at flush with a version error, which surfaces as a 500 (CycleCountLosController.recountUnitLoad, ~:286, catches only Business/FacadeException). Re-checking after the lock gives a clean BusinessException. Refreshing after the SU lock is enough, because the winner commits before it releases the SU lock. No `findByIdForUpdate` is needed on CyclecountPositionRepository (none exists).

## (d) Transactions for the two non-@Transactional methods
- A `@Transactional` boundary is not required for correctness. Neither method takes a lock: `LockReads` sits only on the stock-change paths, and OSIV is off (application.properties:85), so each repository call is its own transaction and a plain re-read is enough.
- **M2: add one anyway (Low, same pass).** `countSingleUnitLoad` writes twice: `createEntity` saves CREATED (CyclecountPositionService:60), then :178 saves FINISHED. If the second write fails, a CREATED ADJUSTMENT orphan is left behind.
- `countCycleCountStockUnit` saves the position FINISHED (:369) and then the order FINISHED (:388). If the second write fails, every position is FINISHED but the order is not, and no mobile path can close it.
- Use `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, as at :191.

## (e) Passing the locked managed row into sendStockUnitToNirvana/changeAmount: correct, with care
- Today's bug: `if (BigDecimal.ZERO.compareTo(staleStockUnit.getReservedamount()) < 0)` (:573) and `if (... staleStockUnit.getAmount()) < 0) changeAmount(...)` (:578-579) both read the instance passed in. With the posted amount at 0, the only lock and re-read are skipped. `findById` (:586) then returns the managed row as it is (the comment says "not a database re-read") and retires it.
- With the locked row passed in:
  - :573 sees reserved=5 and throws STOCKUNIT_HAS_RESERVATION, which rolls back the whole recount (SBDEV-3854 transaction).
  - With reserved=0, changeAmount's `LockReads.forUpdate` takes the managed path. The scalar lock is a no-op wait because the lock is already held, it auto-flushes, then it refreshes in place. :586 returns that same instance.
- **M3: snapshot `originalAmount = locked.getAmount()` (and itemdataId) BEFORE the stock call.** The refresh plus `setAmount` mutate the caller's instance in place, so `locked.getAmount()` reads 0 after the call. The current code already snapshots at :221/:433; keep that order.
- **M4: `createEntity` must receive the locked row.** It copies `amountbefore`, `unitloadId`, `clientId` and `itemdataId` from its argument (CyclecountPositionService:52-57). Today `countSingleUnitLoad` (:173) and `recountSingleUnitLoad` (:223) pass the posted object, so a forged payload also falsifies the audit row. Item 4 of the plan must pass the DB row to `createEntity` and return it to the controller, which reads `getClientId`/`getUnitloadId` from it.
- Do not mutate the locked SU between the lock and the stock call. The auto-flush keeps any edits, but nothing needs edits there.

## Also missed
- **M5 (Low, UI, propose rather than fix).** In store/cycleCount.js:238-248, the "count equals expected" branch calls countSingleUnitLoad and ignores `result.stockUnit`. Once the server judges against the DB, a stale screen will toast "Amount X differs expected. Count again!" as a success and reset. That is safe (nothing is recorded) but misleading.
- `recountSingleUnitLoad` has no `if (diff != 0)` guard, unlike :446. It sends OMS a stock-change message of 0 whenever DB amount == count. Add the guard in the same pass.
- countBySKURecount's location loop (:471) must compare against the DB position's locationId.

## Steelman against refusing
"The DB container is the truth; refusing forces a re-scan." That is true, and a re-scan is cheap (one scan). The cost of not refusing is a stock adjustment attributed to a container nobody counted. Refuse.
