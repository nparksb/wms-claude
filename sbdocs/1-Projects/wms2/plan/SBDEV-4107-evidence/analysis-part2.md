# SBDEV-4107 analysis bundle — PART 2 (§E–§I)

Lane: ana-4107 (executor, opus), 2026-11-11, graded on `origin/develop` @ `df30fa62` via `git show` / `git grep` only.
Saved by the parent session: the harness blocked the subagent's own Write. Part 1 (§0–§D) is in `analysis.md`.

## E. Numbering
- **Format:** `<parent>.getNumber()` + `"-"` (`WmsConstants.EntityPrefixes.SEPARATOR`) + `String.format("%1$06d", n)` (`getFormat()`), e.g. `<ADVICE#>-000003`.
- **Numbers are zero-based.** `generateNumberWithAdvice` uses `advPositions.size()` read before the new position is saved; receive uses `grpCount` before `grpCount++`. PRD minimum suffix is 0 for both tables.
- **PRD conformance (WineCo):** 0 advice-position and 0 goods-receipt-position numbers fail `-[0-9]{6,}$`; 0 numbers have a prefix that differs from the parent's number + `-`.
- **Nothing in Java parses these numbers.** Method: grep `getNumber()…(split|substring|lastIndexOf|replace)` and `(split|lastIndexOf)(…SEPARATOR` → 0 hits; `[gG]oodsreceipt[pP]osition….getNumber()` → 0 hits. Only SQL reports consume them: `AdvicepositionRepository` (joins `r.ordernumber = ap.number`) and `GoodsreceiptpositionRepository`. The advice-position number is also copied onto stock units (`createStockUnit(..., adviceposition.getNumber(), ...)`) and into `transaction_detail` references (V2.2.25 comment).
- **Broken but unused (flag only, out of scope):** `generatePositionCountStringBy{Goodsreceipt,Advice}Id` are native `SELECT lpad(count(...)) where …` with **no FROM clause**, SDR-exported, no Java caller.
- **Safest max+1:** in SQL over the numeric suffix, scoped by parent FK:
  `select coalesce(max(cast(substring(number from '[0-9]+$') as integer)), -1) + 1 from goodsreceiptposition where goodsreceipt_id = :id` (same shape for advice positions).
  - Stays zero-based (empty parent → 0); equals today's count when nothing was deleted; no Java parsing.
  - Inside the receive loop: draw once, then `++` in Java as today.
  - Caveat: deleting the highest-numbered row then receiving again re-issues that deleted number. Never a duplicate among live rows (§I-2).
- **Concurrency without a constraint:**
  - GRP max+1 is safe only if every writer of a receipt's positions holds the same lock. With the §D advice lock in `receiveGoods`, every position insert for an advice is serialized. `deletePosition` needs no lock (deleting cannot create a duplicate).
  - Advice-position max+1: `updateAdviceWithPositions` must take the advice lock. The other four callers number positions of an advice created in the same request — no concurrent writer known.

## F. SBDEV-4038 (`7235ac4e`, merged 2026-11-05; ancestor of develop)
- Files: `TransferOrderService` +18, `CustomerorderBatchService` +24, `ClubLineController` +1, tests +155.
- Guards added at the top of the same methods:
  - `assignTransferLaneToTransferOrder` refuses `state > 510`: "has already run (…), so its transfer lane can't change."
  - `activateAndAssignTransferLane` refuses `state >= 510`: "is already active (…)."
  - `assignStagingLaneToOrderBatch` refuses `state >= 527`.
  - New `requireNotYetActivated` refuses ≥520; `ClubLineController.activateBatch` calls it before the lane change.
- Guards read state from the controller's detached entity; a concurrent writer to the same row is caught by `@Version` (`AbstractBaseEntity`) → `ObjectOptimisticLockingFailureException` → 409.
- **How 4107 builds on it:** change goes **after** the guards — replace `save` with a guarded `saveAndFlush`; keep guard order and messages; switch SBDEV-4038's `save` verifications in `TransferOrderServiceUnitTest` / `CustomerorderBatchServiceUnitTest` to `saveAndFlush`.

## G. Existing tests and the race-test harness
Method: `git grep -l` of each method name over `src/test`.

| Area | Unit | IT |
|---|---|---|
| Transfer lane | `unit/service/TransferOrderServiceUnitTest`, `unit/controller/TransfersControllerUnitTest` | `service/ActivateTransferAtomicityIT` (NOT_SUPPORTED + `TransactionTemplate`; its SBDEV-3183 AC-6 "held lane is refused" case is **sequential only**); `security/CustomerorderTransferLaneSdrWriteContextTest` |
| Staging lane | `unit/service/CustomerorderBatchServiceUnitTest`, `unit/controller/ClubLineControllerUnitTest` | none |
| Receipt find-or-create | `unit/service/ReceivingServiceUnitTest`, `ReceivingServiceReturnLabelContractUnitTest`, `ReturnAdviceAutoReceiveServiceUnitTest` | `integration/service/GoodsReceiptPositionAdjustIT`, `GoodsReceiptPositionReturnFinishIT` |
| Numbering | none (grep of `generateNumberWith*` over src/test = 0) | — |

**Race-test precedent:** `src/test/java/net/aim_ai/wms/common/fixtures/HeldRowLockRace.java` (209 lines). Holder tx locks/writes then waits; subject runs the service on another thread; holder commits only once the subject is observed blocked **by the holder's pid** (`holderPid = ANY(pg_blocking_pids(pid))`) — forced interleaving, not timing. `subjectOwnsItsTransaction()` handles `@Transactional` entry points. Raw-JDBC holder + `pg_stat_activity` probe precedent: `ReleaseOpenCartLockRaceIT`.

**Proposed tests:**
1. **Transfer lane.** Holder (raw JDBC): `SELECT … FROM location WHERE id=:A FOR NO KEY UPDATE`, then `UPDATE customerorder SET transferlane_id=:A, state=510 WHERE id=:X`, uncommitted. Subject: `assignTransferLaneToTransferOrder(A, Y)` blocks on A; holder commits. Before fix: two open orders on A (red). After: `BusinessException("transfer lane is not available anymore…")`, one order on A. Repeat for `activateAndAssignTransferLane`.
2. **Staging lane.** Holder: `UPDATE customerorder_batch SET staginglane_id=:L, state=525 WHERE id=:B1`, uncommitted. Subject: assign L to B2. Before fix the subject never blocks (no lock) → test must accept "subject finished", then commit holder and assert one batch on L (red). After fix the subject's flush blocks on the holder's index entry; once observed, holder commits and subject gets `BusinessException`.
3. **Goods receipt.** Holder: `SELECT … FROM advice WHERE id=:A FOR NO KEY UPDATE`, then `INSERT INTO goodsreceipt (advice_id=:A …)`. Subject: `receiveGoods` on a different position of the same advice. Before: no block, second receipt (red). After: subject blocks on the advice, then reuses the holder's receipt.
4. **Numbering (no race).** Receive 2, `deletePosition` the first, receive 1, assert numbers distinct — red with count, green with max+1. Plus one `HeldRowLockRace` test of `updateAdviceWithPositions` called twice for AP numbers.

**Traps (memory):** set `TenantContext` inside the worker thread or "must throw" passes vacuously (SBDEV-3491); NOT_SUPPORTED fixtures commit — delete in `@AfterEach`, children first; bump versions through the holder's own tx, never `jdbcTemplate` (self-deadlock); assert cause chain (class **and** message) and mutation-check each; do not copy the free-running shape of `ReplenishDupConcurrencySliceIT` (documented timing-flaky).

## H. Prior plans and the transaction audit
- `4-Archieves/wms2/plan/260424-CONCURRENCY_FIX_PLAN.md`: describes the lane race and claims `@Lock(PESSIMISTIC_WRITE)` "serializes concurrent lane assignment attempts" (commit `a6b8d6b`) — **the claim SBDEV-4107 disproves.**
- Related archived plans: `260629-activate-transfer-atomicity` (origin of `ActivateTransferAtomicityIT`); `260629-transfer-lane-leak-on-cancel` (the T4 lane-clearing writers); `SBDEV-2163-prevent-finished-club-batch-lane-reassignment`; `260629-transfers-available-lanes-orderbatchid-mislabel`; `SBDEV-3183-evidence/review-ac6-held-lane-refusal.md` (sequential only); `260424-RECEIVING_{QUANTITIES,PERFORMANCE}_PLAN` — no receipt-lock/uniqueness decisions.
- `3-Resources/reports/261111-wms2-transaction-audit.md`: #1 transfer lane (Medium, author-checked); #3 staging lane (Medium, one review lane); #5 goods receipt (Medium, author-checked; latent on PRD); #16 count-based numbering.
- ⚠ **The audit's alternative fix for #1 would not work.** Touching the lane row under the lock (`UPDATE location SET version=version+1`) does not help: under READ COMMITTED, EvalPlanQual re-checks only the **locked target row**; the `NOT EXISTS` subquery over customerorder still uses the statement's original snapshot. Source: PostgreSQL docs, "Read Committed Isolation Level" — not measured; race test G-1 would prove it. Unique index is the right fix.
- Doc to update with the fix: `3-Resources/workflows/wms2-transfer-order-workflow.md` §4 row (line ~147) and landmine 13.

## I. Open questions (ranked)
1. **Customerorder index build time on PRD-sized data.** Estimate (<1 s warm) extrapolated from V2.2.49, not measured. Measure on a synthetic/UAT copy (as SBDEV-4092 did) and choose the deploy window.
2. **Is re-issuing a deleted top GRP number acceptable?** If not, a per-receipt counter column is needed — bigger change, own migration.
3. **Which receipt should `get(0)` pick** for the multi-receipt advices (1,623 WineCo; 2,036 estate-wide)? Lowest id via `findFirstByAdviceIdOrderByIdAsc` is the minimal deterministic choice. Nam to confirm.
4. **Can a row re-enter the transfer index predicate?** Any path moving customerorder from ≥700 back below 700 while `transferlane_id` is set would start throwing 23505. `updateStateByIds` only excludes 800. PRD count of `state >= 700 AND transferlane_id IS NOT NULL` would size it — not run.
5. **Lane-duplicate census on UAT and dev.** PRD 0 on all 4. A duplicate on UAT/dev fails that tenant's migration and blocks every later V2.2.x there. (Parent session: dev `dev_wh01_om1` = 0/0 with controls 6 and 9; all four UAT MCPs dropped the connection — still open.)
6. **Add a non-unique `goodsreceipt(advice_id)` index in the same migration?** Every receive scans ~20k receipt rows. Cheap, outside decided scope — Nam's call.
7. **Should `finishReturnAdviceIfComplete` take the advice lock first in this ticket?** Closes the receive-vs-adjust/delete deadlock shape; otherwise leave to SBDEV-4109 or later.
