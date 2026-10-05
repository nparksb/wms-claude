# SBDEV-3547 — architect review, round 1 (2026-09-27)

## 1. Verdict

**SOUND-WITH-CHANGES.** The main mechanism holds up. At C1/C2, "SU at lock 100" is a lookup-free proxy for "reversal owed" that doesn't depend on statement order, and completeReversal on fenced stock has already worked end to end on PRD: the Hydra T-0002/T-0007 SUs sat at 100 at Clearing and were reversed on 2026-09-23. But one premise of D3 is false (M6 already refuses 100), the rail's PR-B "green" is partly false, and the D1 cost measurement is missing a tenant that shows the exact workflow D1 blocks.

## 2. Steelman antithesis

The plan makes one lock value mean two things. Lock 100 already means "picked for a live order". Using it to also mean "owed to a reversal" is what forces the extra machinery:
- Move Unit Load has to check the container type (Tote vs Package).
- deleteUnitLoad refuses without looking at type, and so also blocks packed parcels.
- Every refusal message has to hedge ("if its order was cancelled…").
- The Waive `lockRetained` branch now leaves a closed row next to an SU that stays at 100 forever.

The alternative: at C1/C2, write a distinct "pending reversal" lock state. Guards could then refuse exactly that state, with no type heuristics. Messages could name the Cancellation screen outright. Live picked totes would never be refused, and a closed row with that state left behind would be easy to detect.

The cost would be new state handling in completeReversal, Waive, removeLock, stock_view and the web lock report, plus a Flyway seed. That is more scope than D2 accepted, and D2 is settled. Still, this is the honest price of the chosen design: each future guard has to rediscover "is this 100 a cancel or a live pick?".

## 3. Tradeoff tension and synthesis

**Tension:** D1 fences container relocation, but relocating the container doesn't harm the reversal. completeReversal works by SU id, and `toteState` checks the label, not the location (A§2.2, CancellationReversalService:800-822). Only the carrier arm (MMU:514), followed by BOL close, is actually harmful. Meanwhile the relocation is a real floor workflow. On wsl-wineco-prd, `unitload_record` shows `T-0082` sent Clearing → StagingLane05 by `adriantorres` on 2026-09-15 at 22:35, seven minutes after its cancel-to-Clearing row. Those rows are probably v1-era history, since WineCo went live on v2 on 2026-09-26. So the plan's "0 Tote TRANSFER, no workflow cost" is true only for c1wh and hydra.

**Synthesis (without re-opening D1):**
- Run R5 **before PR-B merges to develop**, not only before the PRD release.
- Brief the WineCo floor before PR-B reaches PRD: "a cancelled tote stays at Clearing until it is completed or waived".
- If Nam wants to narrow D1 later, the narrow version is "refuse Tote+100 only on the carrier arm (:514)". The plan's `MoveUnitloadSourceLockPolicy` could take an `arm` parameter so that change is one line.

## 4. Findings

**F1 — High. M6 (adjustAmount) already refuses 100. B3's root cause is false and the planned test cannot start red.**
- Evidence: `StockunitService.java:885` `switch (stockUnit.getEntityLock())` only allows ON_HOLD, QUALITY_FAULT and NOT_LOCKED. The `default:` arm at `:896` throws `"unexpected lock=… value not changed"` before `changeAmount` at `:899`. SBDEV-3086 F4 already moved that check ahead of the mutation.
- An existing test already pins this: `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java:2498` `adjustAmount_pickedForGoodsout_doesNotCommit`.
- The only callers are `StockUnitController:318/:360`. There is no internal caller, so no picking, packing, cycle-count or reversal path goes through it.
- Changes to the plan:
  - Rewrite §2 B3 and the §0 M6 row as "already refused, message is unhelpful".
  - Move the adjustAmount change to **PR-A**. It is fail-open and message-only.
  - Rewrite the §7.1 row so it asserts the `goodsOutHint` substring. As written it is green before the fix, which breaks the floor rule, and the mutant "remove 100 from the predicate" survives because `default:` still refuses.
  - Take adjustAmount `:869/:871` out of the rail's `KNOWN_OFFENDERS`. They are redundant with an allowlist switch, so they belong in `EXEMPT` with that reason. As a side point, the plan lists `switch(getEntityLock())` as a rail blind spot, and here the switch is the real guard.

**F2 — Medium. PR-B's rail "green" is achieved by moving the MMU comparisons out of the rail's scope.**
- The rail's scope is classes whose text calls the four primitives. `util/MoveUnitloadSourceLockPolicy` calls none of them, so it is out of scope.
- It still contains `UL ON_HOLD → throw` and `SU ON_HOLD → throw`. By the rail's own definition, those are single non-zero-constant throw guards.
- So emptying `KNOWN_OFFENDERS` shows only that the code moved, not that it complies. This is exactly the helper-wrapped blind spot the plan lists.
- Change: add the policy class explicitly to the rail's scope. Put its ON_HOLD checks in `EXEMPT` with a reason ("ON_HOLD refusal kept by D1; the Tote-100 rule is the move policy"). Add a self-test that fails if the Tote-100 branch is removed from the policy.

**F3 — Medium. §7.5 row 9 overstates what afterCommit buys on connection-pool slots.**
- During `afterCommit`, Spring has not released the outer tenant connection yet; cleanup runs after afterCompletion. So `createServiceLog`, which is `REQUIRES_NEW` (`MessageService:75`), holds a **second pool slot at the same moment** as the first. Row locks are released, but slots are not.
- This is acceptable. It only happens on the rare non-empty path (4 rows on c1wh, 0 on hydra), and `REQUIRES_NEW` is required there: a REQUIRED call from afterCommit would join a transaction that has already finished, and its write would be lost.
- Change: correct the row to "2 slots briefly, row locks released; bounded by the pending-row population". Keep the design. The plan is right to call `createServiceLog` directly rather than through a self-deferring wrapper (`OmsNotificationService:68-105`).

**F4 — Low. The A1 swap test's captor cannot see a self-call.**
- `sendToClearing` calls `transferUnitLoadToLocation` on `this` (`UnitloadBusinessService:691`, method at `:221`), so a Mockito captor on it only works with a spy.
- Change: capture `unitloadRecordService.recordForTransferUnitLoad(...)` arguments 8/9 instead. `processTransfer` passes the values through at around `:542`, and that is the observable effect.
- The sibling sweep is clean. Every other wrapper (`sendToNirvana:586`, `relocateEmptiedContainer:674`, `transferUnitLoadToCarrier/Cart`) passes `(orderNumber, comment)` in the right order. `sendToClearing` is the only wrapper whose own signature is `(comment, orderNumber)` (`:688`), which invites the same mistake again. Add a javadoc warning; don't reorder two same-typed String parameters.
- Only audit rows and ReportService read `ordernumber`, so the fix changes no behaviour. It is confirmed on a third tenant: the WineCo cancel-to-Clearing rows carry the order number in `additionalcontent` and NULL in `ordernumber`.

**F5 — Low. B-2's null-safety text must guard against `findById(null)`.**
- `types.findById(source.getTypeId())` with a null id throws `IllegalArgumentException` before any Optional comes back (the SBDEV-2102 precedent, `CustomerorderService:1026-1027`).
- Change: spell out `typeId == null → not a Tote, WARN` **before** the lookup, and name it in the `_toteTypeUnresolvable_` test.
- Type naming is clean. On both c1wh and hydra PRD, `unitload_type` id 2 = `Tote` exactly, and every tote label (`C1-*`, `T-*`, some `UL*`) carries that type.

**F6 — Low. C3's snippet does not match the code's shape.**
- `CustomerorderService:490-493` saves inside the lambda, and there is no `saveAll`.
- Change: in C3, call `CancelLockRelease.releaseUnlessGoodsOut(stockUnit)` inside the existing lambda and keep the per-row save.

**F7 — Low. Bulk and recursive deletes stay partial-commit (pre-existing).**
- I confirmed that neither `deleteUnitLoad` (`UnitloadService:570`) nor `deleteUnitLoadRecursive` (`:466`) has `@Transactional`. Refusing before the loop at `:593`, and in the pre-run top branch at `:430`, is correctly placed after the To-Delete check (`:583`) and the child check.
- `bulkDeleteContainer` (`UnitLoadController`, loop at about `:176-178`) still commits container #1 before refusing #2. That matches the existing fixed-assignment refusal, so document it and don't fix it.
- For the pre-run check, use the existing `StockunitRepository.findByUnitloadIdIn` (`:426`, currently SDR-exported). It needs no new persistence surface.

**Verified, no change needed:**
- **(a) Producers of 100 on stock units** are `PickingorderBusinessService:1161` (confirmPick) and `CancellationReversalService:482` (reversal residue, which is still owed to a sibling row, so it is consistent). `StockunitService:609` copies QF only. The BOL bulk update writes 405/SHIPPED.
- **(a) Tote sharing and orphan rows:**
  - Multi-order totes: 0 shared `pickingtote_id` on c1wh.
  - `reversal_required` rows with a null `picktostockunit_id`: 0 on c1wh and on hydra.
  - The N4 "reused tote names another order's SU" case (`CancellationReversalService:608-609`) only arises in recovery. PR-B shrinks it, because M11 keeps a fenced tote out of reuse.
  - The RAPID arm is dead on every tenant (`CustomerorderService:960-966`).
- **(b) The rest of the cancel tx is unaffected by keeping 100.** `sendToClearing` passes `ignoreLock=true`. `resolvePicktoStockunitId` does not look at locks (`CancellationLogService:115-134`). The `pickingorder_unitload` nulling, `stock_view` (which counts `NOT IN (405,2)`, so 0 and 100 are equivalent) and ReconciliationJob don't read locks either. `relocateEmptiedContainer` is not reached.
- **(e) The BOL query mirrors the bulk UPDATE's WHERE** (`BillofladingService:675-680`, `:1604-1609`): children of pallets, one level. Entity fields exist (`picktostockunitId`, `unitloadId`, `carrierunitloadId`). Every caller of `closeBOL` and `finishTransfer` goes through a proxy with an active transaction, so `registerSynchronization` is safe.
- **(h) No new locking.** Every added read is an unlocked SELECT, and C1/C2 now issue fewer Stockunit UPDATEs.
- **(g) PR-A can deploy alone safely.** Its only behavioural change is message text, and nothing in `src/main` matches on `is locked=`.

## References
- `v2/wms2-api` origin/develop `a5b36931`: `StockunitService.java:864-899`, `StockunitBusinessService.java:236-297`, `UnitloadBusinessService.java:221,333,586,674,688-691`, `MobileMoveUnitloadService.java:125,163-172,289,359-368,696-721`, `UnitloadService.java:427-500,570-610`, `CustomerorderService.java:470-528,1027-1059`, `PickingorderBusinessService.java:1161,697-703`, `CancellationReversalService.java:288-297,410-482,580-613`, `BillofladingService.java:340-355,665-680,1594-1609`, `MessageService.java:75`
- Tests: `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java:2498`, `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java:1559,1593`
- DB (read-only, 2026-09-27):
  - c1wh: lock-100 SUs = 28 Package @ Palletizing only; 4 pending rows, all with an SU id.
  - hydra: 0 SUs at lock 100; 7 closed rows.
  - wsl-wineco-prd: 5 Tote TRANSFER rows in 60 days, including the operator move Clearing → StagingLane05; 2 log rows, both `reversal_required=false`.
  - nywh-shipitez-prd: 0 rows.
- Plan: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-fence-cancelled-stock-against-hand-moves.md`; evidence: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-evidence/analysis.md`
