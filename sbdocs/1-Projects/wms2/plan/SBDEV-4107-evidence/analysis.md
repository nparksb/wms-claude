# SBDEV-4107 analysis bundle — PART 1 (§0–§D)

Lane: ana-4107 (executor, opus), 2026-11-11, graded on `origin/develop` @ `df30fa62` via `git show` / `git grep` only; PRD numbers from read-only wsl-wineco-prd queries.
Saved by the parent session (the harness blocked the subagent's Write). Part 2 (§E–§I): `analysis-part2.md`.

## 0. Affected sites (by enumeration)

### 0.1 Writers of `customerorder.transferlane_id`
**Method:** grep `setTransferlaneId|transferlane_id *=|transferlaneId *=` over `src/main` (Java + resources). Bulk JPQL/native `UPDATE … transferlane`: 0 hits. `copyProperties`/`ModelMapper` on Customerorder: 0 hits. SDR write exposure read from `RestConfiguration`.

Proposed index: `(transferlane_id) WHERE transferlane_id IS NOT NULL AND state < 700`.

| # | Site | Writes | Would the index make it throw? |
|---|---|---|---|
| T1 | `TransferOrderService.assignTransferLaneToTransferOrder`, `customerOrder.setTransferlaneId(transferLane.getId());` | lane, state 510 | **Yes, for the race loser.** Violation fires at commit → `DataIntegrityViolationException` → 500 today (§B). |
| T2 | `activateAndAssignTransferLane` | same | **Yes**, same way. |
| T3 | `unlinkTransferLaneFromTransferOrder` | null | No. |
| T4 | `CustomerorderService` cancel and force-cancel | null | No. |
| T5 | `CustomerorderBatchService.finalizeBatchIfComplete` | null | No. |
| T6 | SDR PATCH/PUT `/v3/customerorder/{id}` | — | **Closed.** `Customerorder.class` and `CustomerorderBatch.class` are in `SDR_WRITE_WITHDRAWN` (`RestConfiguration`). |
| T7 | Bulk `@Modifying` on customerorder (`updateStateByIds`, `markClientHasNoSection`, `releaseDueFutureTransferOrders`) | state only | Only if a row moves ≥700 → <700 while still holding a lane. `updateStateByIds` (`WHERE c.id IN :ids AND c.state != 800`) can lower a 700 row. |

Base schema already has non-unique `index_customerorder_transferlane_id` (V2.2.00).

**Parent-session closure of T7 / §I-4 (2026-11-11):** `updateStateByIds` has exactly one caller on develop — `CustomerorderBatchService` club-run finish (`updateStateByIds(orderIds, WmsConstants.State.PACKED)`), method `git grep -n updateStateByIds origin/develop`. On WineCo PRD every order holding `transferlane_id` belongs to a `TRANSFER_INTRACOMPANY` (320) or `TRANSFER_OFFSITE` (348) batch; 0 CLUB. And finished transfers KEEP their lane: state 700 = 655 rows on 20 lanes, 800 = 6 rows on 4 lanes, 510 = 7 rows on 7 lanes. So no live path re-enters the predicate today, but the plan must pin it, since nothing in code stops a club order from holding a lane.

### 0.2 Writers of `customerorder_batch.staginglane_id`
**Method:** grep `setStaginglaneId|staginglane_id *=|staginglaneId *=` and `UPDATE CustomerorderBatch`; all 8 `[bB]atch*.setState(` sites read.

Proposed index: `(staginglane_id) WHERE staginglane_id IS NOT NULL AND state < 530`.

- **S1 (throws for the race loser):** `assignStagingLaneToOrderBatch` → `setStaginglaneId(stagingLane.getId())` after the unlocked `getAvailableStagingLanes`. Called from `ClubLineController` `assignStagingLane` and `activateBatch`.
- **S2 (clear, never throw):** `unlinkStagingLaneFromOrderBatch`, `finalizeBatchIfComplete`, club-run finish, `BillofladingService`, bulk JPQL `SET cb.state = :finished, cb.staginglaneId = null`.
- **S3 (state rewinds that keep the lane):** `ClubRunJobService.failJob` and `rollbackClubLineState` move 527 back to the original state (already <530) — no rows newly enter the index. `UtilRestController.resetOrdersInReleasedStatus` sets the batch to RAW — edge case only, because every path to 530/700/800 in S2 clears the lane.
- **SDR:** closed, as T6.

### 0.3 Goods receipt creators and `get(0)` reuse
Method: grep `new Goodsreceipt\(|goodsreceiptRepository\.(save|saveAndFlush|saveAll)|findByAdviceId\(` over `src/main`.

- **The only creator and the only `get(0)` reuse are the same site** (`ReceivingService`):
  ```java
  List<Goodsreceipt> goodsreceipts = goodsreceiptRepository.findByAdviceId(advice.getId());
  if (goodsreceipts.isEmpty()) { … goodsreceipt = goodsreceiptRepository.save(goodsreceiptTemp); }
  else { // TODO: WMS support team / select the correct one
         goodsreceipt = goodsreceipts.get(0); }
  ```
- `findByAdviceId` is derived with **no ORDER BY** → arbitrary pick when an advice has >1 receipt.
- **SDR closed:** `GoodsreceiptRepository` is `exported = false`; `Goodsreceipt.class` is in `SDR_WRITE_WITHDRAWN`.
- **PRD (WineCo):** 20,583 receipts, **1,623 advices with >1 receipt**. `pg_indexes`: **no index on `goodsreceipt.advice_id`** (FK only) → every receive seq-scans goodsreceipt (§I-6).

### 0.4 Numbering callers and position deleters
Method: grep `generateNumberWith(Advice|GoodsReceipt|GoodsReceiptByCount)` and `new (Adviceposition|Goodsreceiptposition)\(`; deletes: grep `.(delete|deleteAll|deleteById|deleteAllById|deleteInBatch|deleteAllInBatch)(` filtered to position/advice/goodsreceipt, plus native `delete from …` in Java and migrations.

| Caller | Advice state | Lock held when numbering | Exposure |
|---|---|---|---|
| `ReceivingService.createAdviceWithPositions` | created in same tx | none needed | none |
| `ReceivingService.updateAdviceWithPositions` (from `AdviceController`) | exists; plain `adviceRepository.findById(advId)` | **none** | concurrent adds → duplicate AP number |
| `AdviceRestController` ×3 | just saved by same `create()` (not `@Transactional`) | none | none in practice |
| `FileImportController` | `newAdvice`, just saved | none | none in practice |
| `receiveGoods` → `generateNumberWithGoodsReceiptByCount(goodsreceipt, grpCount)`, `grpCount = (int) countByGoodsreceiptId(...)` | exists | only the advice-position `FOR NO KEY UPDATE` | **live cause:** count drops after delete → number reused; positions of one advice can also race |
| `BasicService.generateNumberWithGoodsReceipt` | — | — | **no caller** (dead code) |

- **Deleters:** only `GoodsReceiptPositionService.deletePosition` (`goodsreceiptpositionRepository.delete(position);`), reached from `GoodsReceiptPositionController`.
- **No advice-position deleter exists in `src/main`** → AP dups only from the `updateAdviceWithPositions` race; GRP dups from delete-then-receive (live) and the cross-position race.
- **PRD (WineCo):** AP duplicate `(advice_id, number)` groups = **0**; GRP duplicate `(goodsreceipt_id, number)` groups = **160**.

### 0.5 Sibling find-free-then-assign patterns
Method: repository methods named `getAvailable*|findAvailable*|findFree*|getFree*|findUnused*|findEmpty*` (5 hits); `find-or-create|findOrCreate|getOrCreate` markers in `src/main/java` (20 hits); count-based numbering in `BasicService`.

All **out of scope**:
1. **Order number = `customerOrders.size() + 1`** (`BasicService.generateOrderNumber`; callers `AdviceService`, `OrderBatchCreationService`). Same count shape, but nothing deletes customerorder rows (`customerorderRepository.delete` 0 hits) and orders are always created into a fresh batch. Residual.
2. **Shipperid find-then-create (hub-and-spoke)**, `AdviceRestController`. Audit #16: collides but fails safe.
3. **Unit load find-or-create by label**, `UnitloadService.createUnitload`. Analysed and accepted under SBDEV-3688/3862.
4. **Mobile transfer over-filling a lane**, `MobileTransferOrderService`. Audit #13, filed as SBDEV-3412.
5. **Club activate as three separate commits**, `ClubLineController.activateBatch`. Covered by SBDEV-4109. `activateOrderBatch` sets 520 after lane assignment set 525 — both <530, staging-lane predicate unaffected.
6. **`findEmptyStoragePalletIds` / `findEmptyByStoragelocationId`** (`UnitloadRepository`). No in-scope caller.

## B. How a unique violation (23505) surfaces today
- **`RestExceptionHandler` has no handler for it.** Bare `@ControllerAdvice`; handlers cover `ApiInvalidParameterException`, `ApiConstraintViolationException`, `MethodArgumentNotValidException`, SSO exceptions, `BusinessException`, `EntityNotFoundException`, `ObjectOptimisticLockingFailureException` (409), `PessimisticLockingFailureException` (409). **No `DataIntegrityViolationException` handler, no `Exception` catch-all** (method: every `@ExceptionHandler` line in the file). `UserGroupController` comment agrees: *"DataIntegrityViolationException, and NOTHING handles it"*.
- **`MobileEndpointExceptionHandler`** maps it to 409 retryable but is scoped to `basePackages = "net.aim_ai.wms.controller.mobile"` — Transfers, ClubLine, Receiving are outside.
- **Path today:** controller loads entity outside a tx → service `save()` merges, no flush → flush in `JpaTransactionManager.doCommit` **after the method returns** → `DataIntegrityViolationException` → controllers catch only `BusinessException` (`TransfersController`, `ClubLineController`) → **500**. `ReceivingController` also has `catch (RuntimeException e)` → generic error.
- **Recommended pattern** — precedent `FixLocationAssignmentService.detach` (SBDEV-4044, guards partial unique index `idx_replenishorder_active_item_no_dest`):
  `try { repo.saveAndFlush(x); } catch (DataIntegrityViolationException e) { … throw new BusinessException("… Please try again."); }`
  Its javadoc covers: the flush waits on the other tx's uncommitted index entry and fails once that commits; catching is safe despite the SBDEV-3854 rollback-only trap because it rethrows at once and rollback is the desired outcome. Both lane methods declare `rollbackFor = BusinessException`.
- **Match the constraint by name; rethrow any other violation unchanged.** Precedents: `ReplenishGeneratorService.isActiveDupViolation` (cause chain → Hibernate `ConstraintViolationException.getConstraintName()`); `AdviceRestController` (`ExceptionUtils.getRootCauseMessage(e).contains(ADVICE_EXTERNALID_UNIQUE_INDEX)`).
- **Reuse existing messages** — "transfer lane is not available anymore. refresh and try again." / "staging lane is not available anymore. refresh and try again." — so the UI path is unchanged; controllers already put `BusinessException.getMessage()` into `errors`.

## C. Flyway
- **Next version: V2.2.51.** Highest on develop: `V2.2.50__message_redeliver_id_index.sql`.
- **No collisions today:** `gh pr list --state open` → `[]`; none of the 80 most recent `origin/*` refs adds a migration (`git diff --diff-filter=A origin/develop...<branch> -- src/main/resources/db/migration`); no `.claude/worktrees/wms2-api/*` worktree holds a `V2.2.5[1-9]` file. Re-check in `wms-merge` preflight.
- **`CONCURRENTLY` is ruled out.** 0 uses in `db/migration`. `db/migration/README.md` §"Do not use CONCURRENTLY here (SBDEV-4092)": *"`CREATE INDEX CONCURRENTLY` hangs forever when `StartupFlywayMigrator` runs it"* — Flyway 11's transactional advisory lock holds a snapshot; measured 9+ min waiting on `Lock/virtualxid`. `wms-database-migration-guide.md` gives the same warning (its generic CONCURRENTLY advice is v1-only). `executeInTransaction=false` is no escape: a failed run records `success=false` and blocks the tenant until `flyway repair`.
- **Recommendation: plain transactional `CREATE UNIQUE INDEX`, copied from V2.2.49:** `SET LOCAL lock_timeout = '2s'; DROP INDEX IF EXISTS …; CREATE UNIQUE INDEX … WHERE …;`
- **Lock impact (estimated, not measured):** SHARE lock on customerorder — writes wait, reads continue. V2.2.49 measured 2.5 s for 1.54M rows / 1.5 GB warm; customerorder on WineCo PRD is 498,709 rows / ~196 MB → expect well under 1 s warm (full heap scan even for a partial index). App writers have 3 s `lock_timeout`; the migration's own 2 s gives up first → tenant stays at V2.2.50, retries next boot, shows on `wms2.flyway.tenant.stale`. Deploy outside heavy order-release windows. `customerorder_batch` is small.
- **`IndexMigrationLockTimeoutUnitTest`** auto-discovers every V2.2.49+ transactional index migration and fails if `lock_timeout` is missing or not below the app's — the new file must set it.
- **Drop first, as V2.2.49 does** — `IF NOT EXISTS` matches by name only and would keep a hand-made or INVALID index.
- **Predicates mirror the queries:** transfer `state < 700` (`co.state < :state`, FINISHED = 700); staging `state < 530` (ORDER_BATCH_CLUB_RUN_FINISHED). NULL state drops out of both query and index.
- **Pre-check:** a DO block counting duplicates and raising a readable error beats a raw 23505. Census: 0 dups on PRD, UAT, dev.
- **IT harness migrates prod's location:** `AppPostgresDBSetupExtension` `MIGRATION_LOCATION = "classpath:db/migration"` → service ITs carry the new indexes. ⚠ `v2/wms2-api/CLAUDE.md` still says the harness scans `db/v1-to-v2-onboarding/schema` — stale; fix in this ticket's doc pass.

## D. Locks and lock order on the receiving path
- **`AdviceRepository` has no locking finder** (no `findByIdForUpdate`, no `@Lock`; only `@Modifying` is `updateAdviceToStateById`). It is SDR-exported → a new locking finder **must** carry `@RestResource(exported = false)` (SBDEV-3169 precedent).
- **Existing pessimistic locks on advice / advice position / goods receipt: exactly two, both on advice position** (method: `findByIdForUpdate|LockReads.forUpdate|lockById|for update`, filtered to these entities): `ReceivingService` `advicepositionRepository.findByIdForUpdate(advicePositionId)`; `finishReturnAdviceIfComplete` `LockReads.forUpdate(entityManager, Adviceposition.class, …)`. Hibernate renders PESSIMISTIC_WRITE as `FOR NO KEY UPDATE` on PG (`LockReads` javadoc; measured in `StockunitSkipLockedIT`) — does **not** block the `FOR KEY SHARE` an FK insert into goodsreceipt/adviceposition takes on the advice row.
- **Current order inside a receive:** (1) lock own position; (2) plain reads of advice etc.; (3) lock put-away location (`UnitloadBusinessService.transferUnitLoadToLocation` via LockReads); (4) RETURN advices only: finisher locks sibling positions ascending id, then advice row updated at flush.
- **Other advice+positions writers:** `AdviceService.close` — `saveAndFlush(advice)` then bulk `updateAdvicepositionToStateByAdviceId` (**advice → positions**); `acceptTransferAdvice` — same; `acceptHubAndSpokeAdvice` — flushed together, `hibernate.order_updates=true` sorts by entity name → Advice before Adviceposition (**advice → position**); `GoodsReceiptPositionService` adjust/delete — SU lock, finisher locks positions, then advice written (**positions → advice**).
- **Inversion risk:** advice lock taken *after* the position lock would oppose close/acceptTransfer → 40P01. No cycle today only because a receive never waits on the advice.
- **Recommendation: lock the advice first.** (1) Advice id via scalar JPQL `select ap.adviceId from Adviceposition ap where ap.id = :id` (`LocationRepository.lockById` shape); (2) `adviceRepository.findByIdForUpdate` as that row's first touch — later `findById` returns the managed row; (3) position `findByIdForUpdate` as today. Matches close/acceptTransfer order.
- **Also lock the advice first in `finishReturnAdviceIfComplete`**, before its sibling-position loop — no-op when called from a receive (already held); without it, receive (holds advice + own position) vs finishing adjust/delete (holds another position, wants advice) can deadlock. Same class as the one documented in `ReceivingService` (~:829-836).
- If a plain advice read cannot be avoided before the lock: `LockReads.forUpdate(entityManager, Advice.class, id, adviceRepository::findByIdForUpdate)` — a plain finder after a read hits the SBDEV-3286 stale-version trap.
- **`updateAdviceWithPositions` needs the same advice lock** for AP numbering (§E).
- **Boundary map has no advice lock-order entry** (`wms2-transaction-osiv-boundary-map.md` mentions receiving only as the post-commit print row and a carrier-join residual). Add one with the fix.
