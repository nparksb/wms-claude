---
ticket: SBDEV-3547
phase: analysis (T3 bug-fix plan, evidence only — no code, no tests, no git writes)
code_ref: origin/develop a5b36931 (2026-09-27 11:25 +0900, "Merge PR #426 SBDEV-3549") — every citation below is from `git show origin/develop:<path>`
db: c1wh-shipitez-prd, nywh-hydra-prd (read-only MCP), queried 2026-09-27
author: executor lane (analysis)
---

# SBDEV-3547 — analysis: preserve PICKED_FOR_GOODSOUT at cancel, narrow Move Unit Load, rail

## TL;DR — seven things that change the plan

1. **Item 1 alone would have stopped c1wh.** rfernandez's 4× `MANUAL_SPLIT` came from **web Move Stock**'s flow-bin arm (`StockunitService.transferStock` :459, `ignoreLock=false`). At lock 100 that call refuses with `"Source stockUnit=… is locked=100"`. (§1.1)
2. **T-0002 was never moved by an operator.** The ticket says the `== ON_HOLD` arm "succeeded on T-0002". `unitload_record` shows no move of T-0002 between the cancel (2026-07-31 15:52Z) and jgero's reversal (2026-09-23 17:44Z). jgero's `MANUAL_SPLIT` rows are **`completeReversal` itself**: each lands about 18 ms before that row's `reversal_completed_at`. The "succeeded" comes from lane A's static trace (SBDEV-3321 §2.4), not from a recorded event. (§1.2)
3. **Item 3 as worded refuses two live workflows.** The ticket's rule is "refuse any source lock that isn't NOT_LOCKED".
   - (a) **QUALITY_FAULT containers at Damaged.** c1wh PRD holds 30 stock units at 103 on `Damaged` today. Move Unit Load's `removeStockDamaged` arm exists to move exactly these, and the ON_HOLD check runs *before* it.
   - (b) **Packed parcels at lock 100.** Packaging carries 100 into the parcel and nothing clears it before BOL close. On 2026-09-21 bcampbell moved 3 Packages off pallet OUT-001204 (Palletizing → Packaging) with Move Unit Load. All 3 later shipped.

   The narrowing has to be an allowlist `{NOT_LOCKED, QUALITY_FAULT}`, **plus** a decision on 100-on-a-Package. That decision is a type discriminator, not a lookup. The item-6 rail wording has to change to match. (§4)
4. **Known test impact is wrong.** `UnitloadBusinessServiceUnitTest.TransferUnitLoadToLocationSourceLockAsymmetry` calls `transferUnitLoadToLocation` directly. Under the recommended design (policy in the caller, SBDEV-3341) it stays **green**; only its javadoc prose goes stale. The tests that really flip are `CustomerorderServiceUnitTest` :4002 and :2307, and `PickingorderBusinessServiceUnitTest` :1545. There are also three `MobileMoveUnitloadService*Test` families. (§7)
5. **`forceCancelOrder`'s PACKED/PALLETIZED arm (:524) must keep its clear.** That arm writes **no** `customerorder_cancellation_log` row. Preserved 100 would have no Cancellation-screen entry, no Waive and no `removeLock` route (`OPERATOR_REMOVABLE` excludes 100), so it would be a permanent DBA-only strand. Population is 0 on both PRD tenants. (§2)
6. **The fence needs SBDEV-3381 on PRD first, and ideally SBDEV-3548 too.** PRD has no waive columns yet: `column l.reversal_waived does not exist` on c1wh PRD. The mobile Waive button is SBDEV-3548 and is not built. So item 4's "point supervisors at the new Waive" names an action the floor cannot take until 3548 ships. The architect's §4.3 condition applies: do not ship a fail-closed fence without an exit. (§2.4, §9)
7. **Item 1 closes the movement mechanisms but leaves three destroy mechanisms open.** Web **adjust amount** (`StockunitService.adjustAmount` :869 refuses only 405/2) and web **delete container** (`UnitloadService.deleteUnitLoad` :583 has no lock check) both zero or retire lock-100 stock. Web Move Stock **to Damaged** (`StockunitService` :614–616, `ignoreLock=true`) overwrites 100 with 103. None of these is a "movement", so the ticket's "3 of 4" framing leaves them out. (§0.2)

---

## §0 Affected sites, by enumeration

### §0.1 Stockunit/Unitload `entityLock` writes in cancel paths

**Method.** I ran `git grep -n 'setEntityLock(' origin/develop -- 'src/main/**/*.java'`, which returns **97** hits across 55 files. That is the positive control: it finds every write the ticket already knows about. I filtered by receiver type (Stockunit/Unitload) and by reachability from a cancel entry point: `CustomerorderService.cancelOrder` / `forceCancelOrder`, `PickingorderBusinessService.cleanUpCancelledOrder`, `CustomerorderPositionService.cancelOrderPosition`, and `CancellationReversalService`.

**Blind spots.**
- Bulk JPQL is a different shape and is handled in §0.3.
- The search does not see native SQL or direct DB edits.
- It does not see `@RepositoryRestResource` writes. SDR `PATCH /v3/stockunit` is withdrawn (405) per SBDEV-3321 lane A row 16, but I did not re-probe it.
- It does not see unmerged branches or a lock value computed at runtime.

| # | Site (origin/develop) | Construct | Reachable? | Same root cause? | In scope for item 1? |
|---|---|---|---|---|---|
| C1 | `CustomerorderService.java:1037` `toteStock.forEach(su -> su.setEntityLock(...NOT_LOCKED))` in `cancelOrder` success branch (SBDEV-3339). Order: `cancelOrderPosition` loop (log rows) → `sendToClearing` :1034 → clear :1037 → `pickingorder_unitload.unitload_id = null` :1054 | forEach + `saveAll` | **live** — produced c1wh 121691091 (§1.1) | yes | **YES** |
| C2 | `PickingorderBusinessService.java:701` `stockUnits.forEach(su -> su.setEntityLock(...NOT_LOCKED))` in `cleanUpCancelledOrder`. The clear comes **before** the `cancelOpenPickLines` log loop (:732 → :547) | forEach + `saveAll` | live (deferred cancel via `finishPickingOrder`) | yes | **YES** |
| C3 | `CustomerorderService.java:491` tote stock in `forceCancelOrder` `state < PACKED` arm | per-SU save | **unreachable** — the file's own comment at :480–:484 says so. Sole caller is under `isPackedOrPalletized` | yes | YES (keeps the rule by construction, same reasoning as SBDEV-3332 at :447) |
| C4 | `CustomerorderService.java:524` **parcel** stock in `forceCancelOrder` PACKED/PALLETIZED arm | per-SU save | reachable. 0 rows on PRD c1wh (`state=800 AND parcel_id IS NOT NULL` → 0 of 1042 cancelled) and hydra (0 of 9) | **no** — this arm writes **no** `recordCancellation` row (the only `recordCancellation` in `forceCancelOrder` is :427, inside the `< PACKED` arm) | **NO — must keep clearing** (§2.3) |
| C5 | `CustomerorderService.java:488` / `:519` — tote / parcel **Unitload** lock → 0 | UL write | as C3 / C4 | no — UL lock is not the fence. Lane A measured tote UL locks at 0 | no |
| C6 | `CancellationReversalService.java:418` (clear 100 before move), `:482` (restore 100 on residue), `:634` (waive release) | the cure | live | — the *consumers* of the fence | no (must keep working, §2.4) |
| — | `CustomerorderPositionService.cancelOrderPosition` | **no** `setEntityLock` in the file | — | — | lane A §2.5 confirmed the same. This is why Hydra's 7 SUs stayed at 100 before SBDEV-3339 |

`PICKED_FOR_GOODSOUT` producers. I ran a grep of `setEntityLock(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT` plus a scan for lock-copy sites. It finds three:
- `PickingorderBusinessService.java:1161` — confirmPick. It runs in the same tx as `pickingPosition.setState(PICKED)` at :1164.
- `CancellationReversalService.java:482` — residue restore.
- `StockunitService.java:609` — `stockUnitDest.setEntityLock(stockUnit.getEntityLock())`, reached only when the source is `QUALITY_FAULT` (guard at :601).

Packaging (`CustomerorderService:659`, `ignoreLock=true`) carries 100 into the parcel.

**Consequence:** a stock unit at 100 on a tote was produced by confirmPick for a pick line of the tote's order. That line is at ≥ PICKED, and `CancellationLogService:47` sets `reversalRequired = pickingPosition.getState() >= PICKED` for it. So at C1 and C2 **"lock == 100" is equivalent to "a reversal_required row exists or is about to be written in this tx" without any lookup** (§2.1).

### §0.2 Operator paths that move or destroy stock, and how each reads `entityLock`

**Method.** I enumerated callers of the four primitives: `transferStockToUnitLoad` (19 call sites, `git grep -n 'transferStockToUnitLoad('`), `transferUnitLoadToLocation` (24 sites per its javadoc, re-derived by lane A), `sendStockUnitToNirvana` and `changeAmount`. I kept the operator-facing entry points and read each one's lock check. I also ran `git grep -nE 'getEntityLock\(\)[[:space:]]*(==|!=)'`: 37 comparisons in 10 files. Its positive control is the 4 known MMU `== ON_HOLD` hits.

**Blind spots.** Controllers I did not open, v1, and batch jobs.

| Mechanism | Entry | Lock check on the source stock | Lock 100 today → | After item 1 |
|---|---|---|---|---|
| M1 inter-container split, web Move Stock | `StockunitService.transferStock` :409/:413/:459/:645 → `transferStockToUnitLoad(..., ignoreLock=false)` | `StockunitBusinessService:286-289` `if (!ignoreLock) { int lock = …; if (lock != NOT_LOCKED) throw "Source stockUnit=… is locked=" + lock` | refused | refused (**c1wh path**) |
| M2 web Move Stock whole-container | `StockunitService:571` `SourceLockGuard.assertSourceUnlockedForContainerRelocation` → `transferUnitLoadToLocation` :572 | any non-zero refused (`SourceLockGuard:94`) | refused | refused |
| M3 mobile transfer picking | `MobileTransferOrderService:423` (guard), `:429/:435/:440` (`ignoreLock=false`) | same two guards | refused | refused |
| M4 mobile **Move Unit Load** | `MobileMoveUnitloadService.scanUnitLoad` :163/:169, `scanDestination` :359/:365 | `== ON_HOLD` **only** | container relocation **allowed** (location :426, carrier :514). Stock-moving arms (:457/:505/:519 → private `transferStock` :682, `ignoreLock=false`) refused | same — **item 3** |
| M4a Move Unit Load → Damaged | `scanDestination:384` `setStockDamaged` | `:767` `!= NOT_LOCKED && != QUALITY_FAULT` → `"Can't move! stock=… already locked! (100)"` | refused | refused |
| M4b Move Unit Load out of Damaged | `:389` `removeStockDamaged` | `:804` same shape → `"… has different lock=100"` | refused | refused |
| M5 web Move Stock **to Damaged** (non-QF source) | `StockunitService:614-616` `transferStockToUnitLoad(..., CODE_DAMAGED, …, true, true)` then `setEntityLock(QUALITY_FAULT)` | **`ignoreLock=true`**, no check | **allowed, 100 overwritten by 103** | **still allowed — escape** |
| M6 web adjust amount | `StockUnitController:318/:360` → `StockunitService.adjustAmount` :869/:871 | refuses only `SHIPPED`, `GOING_TO_DELETE` | **allowed** (can zero a lock-100 SU) | **still allowed — escape** |
| M7 web delete container | `UnitLoadController:116/:178` → `UnitloadService.deleteUnitLoad` :583 | only `isGoingToDelete` on the UL; the stock loop :596–605 has no lock check | **allowed** (sends lock-100 SUs to Nirwana) | **still allowed — escape** |
| M8 removeLock | `StockunitService.removeLock` :970 | switch; `default:` :997 throws `"Only Quality Fault or On Hold locks can be removed here."` | refused | refused |
| M9 SDR PATCH stockunit/unitload | `RestConfiguration.SDR_WRITE_WITHDRAWN` | 405 (lane A row 16) | refused | refused |
| M10 mobile putaway / replenish | `MobilePutAwayService:568` (`false`), `MobileReplenishService:631` | `!ignoreLock` block | not reachable from a tote at Clearing (source is putaway/pick stock) | n/a |
| M11 empty-tote reuse | `MobilePickingService` assignment block (≈:540–557) | tote must be at `EmptyTotes` **and** `findByUnitloadId` empty → `"<tote> not empty!"` | n/a | fail-safe: a tote holding preserved stock cannot be re-assigned (§3) |

**Findings.**
- M5, M6 and M7 are the "destroy" mechanisms that item 1 does not close. They are not movements, so the SBDEV-3321 architect's "3 of 4 movement mechanisms" framing is correct but not a total.
- Per `a-guard-fences-the-mechanism-you-aimed-at`, the plan must name them.
- Recommended treatment: the SBDEV-3321 architect's own §4.2 already accepts M5 as pre-existing SBDEV-3341 asymmetry. M6 and M7 are sub-T3 findings for this ticket; they are listed in §9(e).

### §0.3 Bulk JPQL writers of `entityLock`

**Method.** `git grep -n 'entityLock = :' origin/develop -- src/main` plus the `BillofladingService` read. **Blind spot:** native `@Modifying` SQL. None was found by `git grep -n 'entity_lock *=' … repo`, whose hits are all SELECT filters (§3).

| Site | Statement | Path |
|---|---|---|
| `BillofladingService.java:666-671` | `UPDATE Unitload u SET u.storagelocationId = :shippedLocationId, u.entityLock = :lock …` | `closeBOL` |
| `BillofladingService.java:675-680` | `UPDATE Stockunit s SET s.entityLock = :lock … WHERE s.unitloadId IN (SELECT u.id FROM Unitload u WHERE u.carrierunitloadId IN :palletIds)` | `closeBOL`. `:lock` is `SHIPPED` or `TRANSFER` (:405) |
| `BillofladingService.java:1595-1600` / `:1604-1609` | same pair, `SHIPPED` literal | `finishTransfer` (:1483) |

Both overwrite whatever lock the stock had. They enter neither `processTransfer` nor `transferStockToUnitLoad`. Recommendation: exclude them and make it visible (item 5, §6).

---

## §1 Which operator path executed each live incident

### §1.1 c1wh-shipitez-prd, order 121691091, tote C1-0063

`stockrecord` rows at 21:54–21:55Z are pairs. The first half is `MANUAL_SPLIT/STOCK_REMOVED` from `C1-0063 @ Clearing`. The second half is `MANUAL_SPLIT/STOCK_CREATED` into `A301C5`, `A301C4`, `AT01-15` and `AC01-84`. The DB says all four destinations are `location_type.sltname = 'flowbin'` with one `fix_location_assignment` each.

`unitload_record` for C1-0063:
- 21:50:19 `TRANSFER FinishedPicking→Clearing` by `anonymousUser` — this is `sendToClearing` from `cancelOrder` :1034.
- 21:55:51 `CONTAINER_RELOCATED_EMPTYPOOL Clearing→EmptyTotes` by rfernandez — this is `relocateEmptiedContainer` from `transferStockToUnitLoad` :423 once the last SU drained.
- The tote was then **re-assigned 6 times** between 2026-09-22 and 09-25, most recently to order 009773-000016.

`CODE_MANUAL_SPLIT` sources (`git grep -n 'CODE_MANUAL_SPLIT'`):
- `StockunitService` :408–:645. Only the flow-bin arm `:459` writes a `MANUAL_SPLIT` into an FLA unit load at a flowbin location. The "existing container" non-pallet arm `:413` could also target an FLA unit load by label. Both pass `ignoreLock=false`.
- `MobileTransferOrderService` :427–:440. Its destination is always a newly minted UL in the transfer lane, not a flowbin, so it is excluded.
- `CancellationReversalService` (via `stockunitService.transferStock`). Excluded because c1wh's rows have `reversal_completed_at IS NULL`.

**Verdict:** web Move Stock, `transferStockToUnitLoad(..., ignoreLock=false)`. At lock 100 this refuses at `StockunitBusinessService:288`. **Item 1 alone would have stopped c1wh.** (Confidence: high. The only residual ambiguity is :459 vs :413, and both refuse.)

Current state (PRD): 4 log rows `reversal_required`, `reversal_completed_at NULL`, `tote_label_id='C1-0063'`. Their `picktostockunit_id`s (121691900/930/950/975) are `amount 0, entity_lock 2`, on `unitload_id 5069679` (Nirwana).

### §1.2 nywh-hydra-prd, T-0002 / T-0007

- Log rows 1–4 (T-0002, created 2026-07-31 15:52:44Z) and 8–10 (T-0007, 2026-09-04 19:15Z): all `position_state_at_cancel 600`, `picktostockunit_id` populated, completed by jgero 2026-09-23 17:44:55–17:45:38Z.
- `stockrecord` for those SU ids after cancel: only `MANUAL_SPLIT/STOCK_REMOVED` at `FinishedPicking` by jgero. Each is timestamped 13–18 ms before its row's `reversal_completed_at`. For example, SU 60941: stockrecord 17:44:55.609, log row 1 completed 17:44:55.627.
- `unitload_record` for T-0002 between 2026-07-31 and 2026-09-24: the last pre-cancel event is `FINISHED_PICKING thomasjr→FinishedPicking` 14:59:47Z. The next is `CONTAINER_RELOCATED_EMPTYPOOL FinishedPicking→EmptyTotes` by jgero 2026-09-23 17:44:55.949Z (the drain inside `completeReversal`). **There is no operator move in between.**

**Verdict:**
- T-0002 and T-0007 were stuck at 100 (cancelled via the pre-SBDEV-3339 `cancelOrder`, which never cleared). They sat untouched and were resolved by the **legitimate** `completeReversal`, which uses `CODE_MANUAL_SPLIT` (`CancellationReversalService:389` comment; `PickLineActivityCodeClassifier:42`).
- The ticket's "It is the arm that succeeded on T-0002" is lane A's static trace (SBDEV-3321 `lane-a-bypass-guard-surface.md:222-253`: "**SUCCEEDS.** … The tote relocates anywhere the operator scans"). It was not an incident.
- The `== ON_HOLD` hole is **real but unexercised**. Item 3 is therefore prevention, not incident repair.
- Hydra is also the proof that the fence worked while it existed: 54 days at 100, zero operator drains.

---

## §2 Cancel sites vs `reversal_required`

### §2.1 Can the site know `reversal_required` without a lookup? Yes, by the lock value itself

- `CancellationLogService.recordCancellation` :47 computes `boolean reversalRequired = (pickingPosition.getState() >= PICKED)`. It is `Propagation.MANDATORY` (:38), so it always runs inside the cancel tx.
- **C1** (`cancelOrder`): log rows are written in `cancelOrderPosition` (`CustomerorderPositionService:143`, for every line `< PACKED` including PICKED 600). This happens **before** the teardown at :1037, in the same tx. The row exists when the clear runs.
- **C2** (`cleanUpCancelledOrder`): the clear at :701 runs **before** `cancelOpenPickLines` → `recordCancellation` :547. That call logs every non-CANCELED line, and `≥ PICKED` gives true. The row does not exist yet when the clear runs, but the decision input (pick-line state) is already fixed.
- Either way the predicate "this SU is at 100" is sufficient (§0.1 producer census). The rule becomes **"a cancel does not overwrite PICKED_FOR_GOODSOUT"**, keyed on the lock value. It needs no lookup, no discriminator and no dependency on statement order. That makes it robust to someone hoisting the clear above the log loop.

### §2.2 What exactly to preserve

| Thing | Preserve? | Reason |
|---|---|---|
| Stock-unit lock 100 on the tote | **yes** | it is the fence |
| Stock-unit locks 103 / 104 on the tote | **recommend: do not write them either** (see §9 d) | today the clear wipes them. `PickingorderBusinessServiceUnitTest:1545` pins ON_HOLD→0. c1wh PRD has 1 tote SU at 103 right now. Every non-100 lock "was set by a DIFFERENT process" — `CancellationReversalService:283-286`, the same rule the cure states |
| Tote **unitload** lock (:488) | keep writing 0 | UL lock is not the fence. Lane A measured 0 |
| `sendToClearing(tote, CODE_TRANSFER, …)` | keep | `transferUnitLoadToLocation(..., ignoreLock=true)` (`UnitloadBusinessService:691`) has no source guard, so preserved locks cannot self-block the cancel (SBDEV-3321 architect §2.1). `completeReversal` works by SU id, and `toteState` checks only the label (`CancellationReversalService:800-822`), not the location |
| `pickingorder_unitload.unitload_id = null` (:1054, :795) | keep, and keep it **after** the log | `picktostockunit_id` is resolved at record time (`CancellationLogService:54`) while the link exists. Both paths already order this correctly (C1: `cancelOrderPosition` before :1054; C2: pinned by `Sbdev3316_CancellationLogOrdering`). Removing the null re-opens the `IncorrectResultSizeDataAccessException` on tote reuse (comment :1041-:1049) |
| `customerOrder.setHistorytote/PickingtoteId(null)` | keep | `recordCancellation` reads `customerOrder.getHistorytote()` for `tote_label_id` (:78). That is set at tote assignment (`MobilePickingService:583`), so it is already populated. c1wh rows carry `C1-0063`; Hydra 0/7 null |

### §2.3 Why C4 (forceCancelOrder PACKED arm) must keep clearing

- `forceCancelOrder`'s PACKED/PALLETIZED arm (:499-:528) writes **no** cancellation-log row.
- Parcel stock arrives at 100 because packaging carries it: `UnitloadBusinessService:183-189` javadoc; c1wh PRD shows 28 Package SUs at 100 in `Palletizing` today.
- If C4 preserved 100, the parcel would be at `Clearing` with lock 100 and no row. `listPendingReversals` would not show it, Waive has nothing to act on, `removeLock` refuses 100 (M8) and M1–M3 refuse it. The result is a permanent DBA-only strand, which is the architect's §4.3 failure shape.
- **Keep :524 as-is, with a comment stating why.** Population: 0 cancelled-with-parcel orders on c1wh PRD (of 1042 cancelled) and hydra PRD (of 9).
- *Separate finding* (propose, do not fold in): a force-cancelled packed order owes a reversal row and has none. The goods sit at Clearing, unlocked and untracked. SBDEV-3353's `SourceContainerGuard` already refuses Move Stock out of a Package, so today the only exits are Move Unit Load and `deleteUnitLoad`.

### §2.4 What `completeReversal` and Waive expect, and whether the fence is escapable

- **`completeReversal`** pre-validate `CancellationReversalService:288-297` refuses any lock outside `{null, NOT_LOCKED, PICKED_FOR_GOODSOUT}` with `"… is locked as To Delete (2) — manual intervention required"`. It then clears 100→0 and flushes (:410-:420) before `stockunitService.transferStock` (:423).
  - It accepts 0 **and** 100, so preserving 100 does not change what it accepts.
  - What it changes is that the stock is still there. Today c1wh's SUs are at `2 / amount 0` and `completeReversal` refuses them. With item 1 they would have stayed at `100 / amount>0` on C1-0063, and `completeReversal` would have moved them back.
- **`waiveReversal`** is on develop (SBDEV-3381 item 1, `CancellationReversalService:529`).
  - `stockReturned=false` releases 100→0 when all of these hold (:603-:614): `toteState == ON` (the tote's label equals `log.tote_label_id`), the SU was not recovered in this call, and `ownsAllStock`.
  - Evidence: SBDEV-3381 plan line ~797, dev test M3: "`false` releases lock 100→0 with amount 2 still on the tote".
  - **So the fence is escapable, but only on dev.** On PRD the waive columns do not exist (c1wh PRD: `column l.reversal_waived does not exist`).
- ⚠ Waive has a **retained-lock** outcome (:613, `lockRetained`). When the tote label differs (`UNKNOWN`), when the SU id had to be recovered, or when `ownsAllStock` fails, "the row closes with the lock kept for good" (comment :609-:610).
  - After item 1, that outcome leaves a closed row plus a stock unit permanently at 100. That is the strand shape.
  - Today the outcome is rare because 2 of 3 cancel paths clear first. Item 1 makes 100 the common input to Waive, so this branch becomes reachable in practice. The SBDEV-3381 plan anticipated exactly this ("Item 2, fencing the cancel lock-clear sites, makes case (i) rarer and case (ii) the main waive input", plan line 422).
  - Its measured exposure is 0 today (cancel-cascade workflow doc line 351). The plan must re-state it as an accepted residual, or give the retained case an exit.

---

## §3 Consumers that will newly see 100 on a cancelled tote's stock

| Consumer | Evidence | Effect of item 1 |
|---|---|---|
| Pick allocation / replenish source | every allocation query filters `su.entity_lock = 0 AND ul.entity_lock = 0 AND location.entity_lock = 0` (`StockunitRepository:111-113, :163, :177-180, :190-193, :210-212, :225-227, :258-264, :279-282, :297-300, :314-317, :332-334, :432-434`); `ReplenishmentMonitorViewRepository:114/:126/:155`. Also `Clearing` is in area `Default` with `useforpicking=false, useforreplenish=false, usefortransfer=false` (c1wh PRD) | **none**. Excluded both before and after |
| Cycle count | `CyclecountService:107` → `getStockUnitsBySkuSetAndAreaSetAndStates` excludes only 405/2 (`StockunitRepository:348`) | shows up in a count of Clearing's area, **same as today** (today at 0 it also shows). Mobile cycle-count confirm refuses non-zero SU locks (`MobileCycleCountService:135/:167/:212/:349/:420`), so an adjust-by-count on it is refused rather than corrupting it. Improvement |
| Stock-unit grid | `StockunitRepository:373` excludes 405 and (optionally) 2 | renders as "Picked". This is the visibility the architect wanted ("the lock at least renders") |
| `removeLock` | M8 | refuses. Same as today for per-position cancels |
| Tote reuse | M11: must be at `EmptyTotes` and empty | a tote with preserved stock stays out of circulation until complete or waive. c1wh C1-0063 was reused 6× in 4 days, so the cost is one tote per pending reversal. **Fail-safe** — it cannot mix into the next order |
| `relocateEmptiedContainer` | reached only when the tote drains (`StockunitBusinessService:403/:423`) | not reached while stock is fenced |
| BOL close | §6. The Stockunit bulk update targets only stock on children of BOL pallets | a cancelled tote reaches a pallet only via Move Unit Load's carrier arm (:514), which item 3 closes, or M5/M7 variants. Population today: 0 |
| `PendingReversalReconciliationJob` | reads log rows only (`findPendingReversalsOlderThan`); message at :195 names the Cancellation screen and Waive | unchanged. The stale-row alarm is now over stock that is still present rather than drained |
| `completeReversal` / Waive | §2.4 | the success path becomes available; the retained-lock residual grows |
| Outbound live orders | 100 is also the normal state of every live picked tote and packed parcel | no change. Item 1 only stops *cancel* from lowering it |

---

## §4 Items 3 and 6 — Move Unit Load narrowing and the rail

### §4.1 The four `== ON_HOLD` comparisons and every sibling in operator-move paths

Census: `git grep -nE 'getEntityLock\(\)[[:space:]]*(==|!=)[[:space:]]*(WmsConstants\.)?BusinessObjectLockState\.[A-Z_]+' origin/develop -- src/main | grep -v NOT_LOCKED` returns **12** hits. The positive control is that all 4 MMU hits the ticket names appear. Operator-move subset:

| Site | Compares | Role |
|---|---|---|
| `MobileMoveUnitloadService:163` `unitLoad.getEntityLock() == ON_HOLD` | UL | refusal (scanUnitLoad) |
| `:169` `stockUnit.getEntityLock() == ON_HOLD` | SU | refusal |
| `:359` / `:365` | UL / SU | refusal (scanDestination) — the one that matters, since it is `@Transactional` and writes |
| `:767` `!= NOT_LOCKED && != QUALITY_FAULT` | SU | refusal (setStockDamaged) — already allowlist-shaped |
| `:771` / `:808` `!= / == QUALITY_FAULT` | SU | **not a refusal** — it decides whether to toggle QF. It must stay |
| `:804` | SU | refusal (removeStockDamaged) — allowlist-shaped |
| `StockunitService:601` / `:614` `Integer.valueOf(QUALITY_FAULT).equals(stockUnit.getEntityLock())` | SU | branch selection (damaged arms). **equals-form — the regex above misses it** |
| `StockunitService:869/:871`, `:918/:920` `== SHIPPED / GOING_TO_DELETE` | SU | refusal in adjustAmount / adjustReservedAmount — denylist-shaped (M6) |
| `StockunitBusinessService:287-297` `int lock = …; if (lock != NOT_LOCKED)` | SU/UL/Loc | refusal via local variable. **The regex misses it** |

Unboxing note: `unitLoad.getEntityLock() == ON_HOLD` is `Integer == int`, so it auto-unboxes and throws NPE on null. There are 0 nulls on PRD (`SourceLockGuard:48-52`). Keep the null-permissive semantics when rewriting.

### §4.2 Why "refuse anything not NOT_LOCKED" is wrong for Move Unit Load — measured

1. **QUALITY_FAULT.**
   - `scanDestination` runs the `:365` check **before** `removeStockDamaged` (:389). That arm's whole purpose is moving QF stock out of `Damaged` and clearing it (:808-:815).
   - c1wh PRD now: **30** SUs at 103 on `Damaged` (19 PickLocation, 11 Case).
   - A strict rule kills that workflow. The allowlist must be `{NOT_LOCKED, QUALITY_FAULT}`, the exact shape of :767/:804. SourceLockGuard's own javadoc names this: "explicitly PERMITS QUALITY_FAULT" (:69-:73).
2. **PICKED_FOR_GOODSOUT on a Package.**
   - Packed parcels carry 100 until BOL close (§2.3; 28 at Palletizing on c1wh now).
   - c1wh PRD `unitload_record`, last 60 days, `activitycode='TRANSFER'` (Move Unit Load's code at :426/:514), operator ≠ anonymous: **219 Case + 3 Package**. The 3 Packages (`UR1780931202261`, `RX1780931202259`, `GP1780931202257`) were moved `Palletizing→Packaging` off `OUT-001204` by bcampbell on 2026-09-21 and are now at `Shipped` with lock 405.
   - Hydra PRD, 90 days: 98 Case, 0 Package, **0 Tote**.
   - Refusing 100 unconditionally refuses a live parcel re-handling workflow. SBDEV-3452 calls re-palletizing "a required workflow" (`MobileMoveUnitloadService:499-503` comment).
   - Caveat: `entity_lock` is not historised, so the lock *at move time* rests on the code chain (pick → packaging carries → BOL close stamps 405), the same caveat `UnitloadBusinessService:193-199` states.
3. **Totes.** 0 operator `TRANSFER` of a Tote in 60 days (c1wh) or 90 days (hydra). Refusing 100 on a **Tote** source has no measured workflow cost. The blind spots are the other 2 PRD tenants (nywh-shipitez, wsl-wineco), which were not queried.

**Recommended rule for item 3 (a proposal the plan must decide).** In `scanUnitLoad` and `scanDestination`, refuse a source SU lock `∉ {NOT_LOCKED, QUALITY_FAULT}`, **except** `PICKED_FOR_GOODSOUT` on a Package-type source. Keep the UL check as `== ON_HOLD` or widen it to the same allowlist. The UL side measured 2 ULs at lock 2 outside Shipped/Nirwana on c1wh; everything else is 0 or at Shipped/Nirwana, where the location checks :350-:357 fire first.
- The type test uses `unitloadTypeRepository` already injected in MMU (used at :697). It is **not** a pending-reversal lookup: it reads no log rows, so it cannot see the cancel's uncommitted rows and has none of the three failure modes the ticket lists.
- Alternative (b): refuse only 100 on a **Tote**. This is narrower and leaves 405/404/403/2 as today. It is the minimum that closes lane A's trace.
- Alternative (c): defer item 3. Container relocation of a fenced tote does not destroy the reversal target: `completeReversal` works by SU id, and `toteState` is label-based. The only harmful continuation is carrier (:514) → BOL close, which item 5 makes visible.

### §4.3 SourceLockGuard — contract and callers

- Callers (`git grep -n 'SourceLockGuard\.'`): `StockunitService:571` and `MobileTransferOrderService:423`. Exactly 2.
- Contract: refuse any non-zero lock on SU / UL / Location. It is null-permissive and static by design, so the refusal tests assert the rule rather than a mock (:31-:33). Message: `"Source stockUnit=<id> is locked=<code> (<text>)"`.
- **Do not reuse it for item 3.** Its semantics are *refuse all non-zero*, and Move Unit Load must *permit QF* (and probably Package-100). Reusing it would either break §4.2.1 or force a flag parameter onto a guard whose javadoc argues for one policy.
- Better: a sibling static in `util/` (e.g. `MoveUnitloadSourceLockPolicy`) or a private method in MMU used at the 4 sites. It is static for the same test-honesty reason (§9 b).
- Update SourceLockGuard's javadoc :69-:73 ("That divergence is accepted …") to record the 100 revisit.

### §4.4 SBDEV-3341 / SBDEV-3353 constraints the rail must agree with

- SBDEV-3341 (`UnitloadBusinessService:200-207`): "**THE RULE — where a source-lock policy belongs: in the caller.** This method enforces the DESTINATION only." The rail must **not** demand a source check in `transferUnitLoadToLocation`/`processTransfer`. `TransferUnitLoadToLocationSourceLockAsymmetry` pins exactly that, including `verify(stockunitRepository, never()).findByUnitloadId(any())`.
- SBDEV-3353: `SourceContainerGuard.assertNotParcel` refuses draining a Package (MMU:674-:681). "The lock guard inside transferStockToUnitLoad refuses 100/405 but accepts an UNLOCKED parcel" — so a force-cancelled parcel (C4, lock 0) is already fenced by container type. That is further reason §2.3's keep-clearing is safe.
- SBDEV-3353 p4 rail precedent: a source-text lexer rail with self-tests (`NeverMatcherNullBlindnessArchTest`). SBDEV-3267 precedent: `NestedCallSiteRailTest`, which scans `src/main/java` text and states its blind spots in its javadoc.

### §4.5 Proposed rail (item 6)

- **Rule.** In the operator-move entry classes, a *refusal* decision on a source `getEntityLock()` must go through a named allowlist predicate. A bare `getEntityLock() ==/!= <single non-zero constant>` guarding a `throw` is forbidden.
- **Scope set.** Stated as a rule, not a list: every class in `service/mobile/` and `service/` whose public method calls `transferUnitLoadToLocation`, `transferUnitLoadToCarrier`, `transferStockToUnitLoad`, or the `StockunitService.transferStock` entry. Derive the set at test time from call sites, not from a hard-coded list (`prose-enumerations-rot-state-the-rule`).
- **Instrument.** A source scan (the NestedCallSiteRailTest shape), not ArchUnit. ArchUnit sees method calls and field access in bytecode but not the comparison operand. `==` on `Integer` vs `int` compiles to `intValue()` plus `if_icmpne` against a constant, and ArchUnit cannot see the constant.
- **Patterns it must catch:**
  - `getEntityLock() == X` and `getEntityLock() != X` (with the `[[:space:]]` form; `\s` silently returns 0 in `git grep -E`, as I measured while building this census).
  - `Integer.valueOf(X).equals(….getEntityLock())`.
  - `int|Integer <v> = ….getEntityLock()` followed by `<v> == X`.
  - In each case only where the enclosing `if` body throws.
- **Positive control.** On `origin/develop` the rail must report **4** offenders: MMU :163, :169, :359, :365. That is the failing-test-first for item 6, and it goes green after item 3. A self-test with a synthetic snippet per pattern, built at runtime as in 3353 p4, proves the patterns fire.
- **Blind spots (to go in the rail's javadoc).**
  - A lock read through a differently-named helper (e.g. `isLock(...)` in `CancellationReversalService:826`, which is out of scope as a non-operator path).
  - `switch (getEntityLock())` (e.g. `removeLock` :986).
  - Proxy/reflection.
  - A new entry class that reaches the primitives only through a wrapper.
  - The rule treats non-refusal comparisons (MMU :771/:808) as allowed. It must distinguish them by the throw-in-body test, and that is a heuristic.
  - Green means "the known shape has not recurred", not "the policy is enforced".

---

## §5 Item 4 — messages at the refusal sites

"Both refusal sites" most plausibly means the two that hand the floor `is locked=100`. The SBDEV-3321 architect §5.2 names exactly "in `SourceLockGuard` and in `transferStockToUnitLoad`'s `!ignoreLock` block". Item 3 adds the MMU sites.

| Site | Current message | Reachable without a query | Needs a query |
|---|---|---|---|
| R1 `StockunitBusinessService:288-289` | `"Source stockUnit=" + id + " is locked=" + lock` (bare code, **no** `describe()`) | SU id, lock, `sourceUnitload.getLabelid()` (the tote label, loaded at ≈:270), `sourceLocation.getName()` | order number |
| R2 `SourceLockGuard:94-96` | `"Source stockUnit=<id> is locked=100 (Picked)"` | SU id, UL label, location name (all three parameters) | order number — and it is static with no repositories |
| R3 MMU :365 / :169 (after item 3) | `"Stock unit is locked on hold!"` (wrong text for 100) | `dto.getUnitLoadLabel()` / `sourceUnitLoad.getLabelid()`, SU id | order number |
| R4 MMU :767 / :804 | `"Can't move! stock=… already locked! (100)"` / `"… has different lock=100"` | same | order number |

**Truthfulness constraint.**
- Lock 100 is also the lock on every **live** picked tote and packed parcel. A message that says "reserved by a pending cancellation reversal" without checking would be false in the common case.
- Two options:
  - (a) **Lookup-free conditional wording**, e.g. `"Stock unit 60941 on T-0002 is reserved for goods-out (Picked, 100). If its order was cancelled, complete the reversal on the mobile Cancellation screen (or ask an outbound manager to waive it) before moving it."`
  - (b) **Refusal-branch-only lookup** of the pending log row by `picktostockunit_id` to name the order. That needs a **new repository method**; the existing ones key on `customerorderId`, `cutoff` or all (`CustomerorderCancellationLogRepository:17/:40/:45`).
- (b) does not decide anything, so it is not the forbidden guard. But it trips escalation trigger (2), "a repository method you had not anticipated". It also runs a query inside the operator's tx on an already-failing path. The SBDEV-3321 architect §5.2 accepted this cost.
- **Recommend (a).** It also avoids pointing at a Waive button that does not exist yet (SBDEV-3548).
- R1 should at least gain `describe()` parity with R2. The SBDEV-3226 precedent is `SourceLockGuard:104-110`.

**i18n/key.**
- `BusinessException(String message)` sets `key = "placeholder"` (`BusinessException.java:42-46`). `BusinessException(String key, Object... parameter)` resolves through `messages.properties`; there is only 1 `BusinessException.*` key in `messages.properties` and 8 in `messages_en_US.properties`.
- Precedent for keys on move paths: `StockunitService` throws `new BusinessException(WmsConstants.MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND, label)`.
- If a key is used, write positional `%1$s` (`java-bare-percent-ns-is-not-positional`) and assert `getKey()`.
- If the 1-arg form is kept, as SourceLockGuard and MMU do, assert substrings and say in the test why `getKey()` pins nothing (`wms2-businessexception-key-vs-message-traps`).

---

## §6 Item 5 — BOL close visibility

- **"Service Log row"** means `MessageService.createServiceLog(sender, receiver, message, process, destination, status, stateCode, answer)` (`MessageService.java:75-107`), which is `@Transactional(propagation = REQUIRES_NEW)` and inserts a `message` row with a sequence-generated number (`BasicService.generateMessageNumber` → `getNextSequenceNumber("WEBSERVICE_MESSAGE")`). Precedent caller: `PendingReversalReconciliationJob:195` (sender/receiver/process constants, body lists `order … tote … logId`).
- **Cheap count.** The pending set is tiny: 4 rows c1wh PRD, 0 hydra PRD pending. The partial index `idx_cancel_log_reversal_pending … WHERE reversal_required AND reversal_completed_at IS NULL` exists (V2.2.00:3869). One JPQL
  `SELECT l FROM CustomerorderCancellationLog l, Stockunit s, Unitload u WHERE l.reversalRequired = true AND l.reversalCompletedAt IS NULL AND s.id = l.picktostockunitId AND u.id = s.unitloadId AND u.carrierunitloadId IN :palletIds`
  over the same `palletUnitloadIds` the bulk UPDATE uses (:672/:679) costs one indexed probe. It must run **before** :675, while the locks are still the pre-close values.
  - It is a **new repository method** (escalation trigger 2 again). It is not a guard: it never refuses.
- **Placement and lock ordering.**
  - `closeBOL` holds `billofladingRepository.findByIdForUpdate` (:353) and, after :666/:675, row locks on every pallet, child UL and stock unit.
  - `createServiceLog` is REQUIRES_NEW, so calling it inline takes a **second pool connection** while the outer tx holds those locks (`pool-exhaustion-counts-slots-not-milliseconds`).
  - It commits even if `closeBOL` later rolls back, which would leave a false "shipped" record.
  - There is no lock inversion on the `message`/sequence rows, because `closeBOL` itself never calls `messageService` (grep: only the field at :49/:137). The `wms2-requires-new-in-lock-holding-tx-deadlock` shape therefore does not apply here, but the slot cost and the rollback divergence do.
- **Recommendation.** Compute the list in-tx before the bulk UPDATE. `LOG.warn` it inline, as a breadcrumb that survives even if the service log fails (the ReconciliationJob pattern :188-:192). Write the Service Log row **after commit**.
  - Beware `wms2-sendaftercommit-guard-is-inverted` and `NestedCallSiteRailTest`: the afterCommit body must call `createServiceLog` directly, not a self-deferring notifier.
  - Apply the same to `finishTransfer` :1604 (same statement, same overwrite). One shared private method is justified by two call sites.
  - Say in the javadoc that the exclusion is deliberate (SBDEV-3321 architect §1.3.1).
- **Population today: 0.** No pending-reversal SU is on a BOL pallet child on c1wh or hydra PRD (c1wh's 4 are on Nirwana, and hydra has none pending). Item 5 is observability for a path that items 1+3 make harder to reach.

---

## §7 Tests that flip, and candidate new tests

### §7.1 Existing tests pinning current behaviour

**Method.** I ran `git grep -nE 'NOT_LOCKED' origin/develop -- src/test | grep -iE 'assert|isEqualTo|verify'`, filtered to cancel classes. Then I ran `git grep -ln 'locked on hold'` and `git grep -n 'already locked\|has different lock'`.

**Blind spots.** Assertions written as `isZero()` or `== 0`; IT fixtures that assert by SQL.

| Test | Pins | Flips under |
|---|---|---|
| `CustomerorderServiceUnitTest` :4001-:4002 `cancelOrder_shouldClearPickedForGoodsoutOnToteStock_whenSuccessBranchHasTote` ("AC-1: releases the goods-out lock on every stock unit on the tote"), asserts :4011/:4014 `NOT_LOCKED` on a 100 fixture | C1 clear | item 1 — **by design**, rewrite as the inverse |
| `CustomerorderServiceUnitTest` :2307 `shouldSkipRapidPickingCleanupWhenNotStarted`, asserts :2379 `rapidStock` 100→`NOT_LOCKED` | C1 clear via the RAPID-arm fixture | item 1 |
| `PickingorderBusinessServiceUnitTest` :1545 `shouldCleanUpWithStockUnitsAndPositions`, asserts :1593/:1594 (fixture su2 = `ON_HOLD`) | C2 clear of **any** lock | item 1 **only if** §9(d) "write nothing" is chosen; green under "skip only 100" |
| `UnitloadBusinessServiceUnitTest.TransferUnitLoadToLocationSourceLockAsymmetry` (:910) | primitive has no source guard | **does NOT flip** under the recommended design; javadoc :903-:907 ("MobileMoveUnitloadService refuses ON_HOLD before calling in") goes stale → update prose. **Contradicts the ticket's "known test impact"** |
| `MobileMoveUnitloadServiceUnitTest` :321-:353, `MobileMoveUnitloadServiceTest` :420-:451, `…UnitTest` :1243-:1278 — `hasMessageContaining("locked on hold")` | ON_HOLD message text | item 3 if the message text changes (keep "on hold" for 104 or update) |
| `MobileMoveUnitloadServiceUnitTest` :690 SBDEV-3490 "Shipped check runs before the ON_HOLD check"; fixture :593-:598 sets lock = SHIPPED on a Shipped source | ordering | stays green (location check first) — but it becomes a pin that the new policy must also run **after** the Shipped/Nirwana location checks |
| `MobileMoveUnitloadService*` setStockDamaged/removeStockDamaged :1147-:1208, `…Test` :679-:721 | `:767/:804` messages | item 4 if R4 messages change |
| `CancellationReversalLockClearIntegrationTest`, `CancellationReversalParcelSourceIntegrationTest`, `CancellationReversalServiceUnitTest` | cure clears 100 | stay green — they start from a 100 fixture; item 1 makes that fixture the production shape |

### §7.2 Candidate new tests (each tied to an AC)

| AC | Test | Lane | Mutation to prove it |
|---|---|---|---|
| AC-1 cancelOrder preserves 100 | `CustomerorderServiceUnitTest.cancelOrder_shouldKeepPickedForGoodsout_onToteStock` (inverse of :4002) | unit | re-add the forEach clear → red |
| AC-1 cleanUpCancelledOrder preserves 100 | `PickingorderBusinessServiceUnitTest.cleanUpCancelledOrder_shouldKeepPickedForGoodsout` | unit | same |
| AC-1 forceCancelOrder dead arm | `forceCancelOrder_stateBelowPacked_keepsPickedForGoodsout` (reflection, as :483's NPE test) | unit | same |
| AC-1b PACKED arm still clears (no log row) | `forceCancelOrder_packedArm_stillClearsParcelStock_becauseNoReversalRowExists` | unit | delete :524 → red |
| AC-1c end-to-end | `CancelPreservesGoodsOutFenceIT` (Testcontainers): pick 2 lines → OMS cancel → assert SU lock 100 **committed**, 2 rows `reversal_required` with `picktostockunit_id` = those SUs → web `transferStock` to a flowbin → `BusinessException` contains `locked=100` → `completeReversal` → stock back in bin, lock 0 | IT (the only lane that sees the committed lock + the refresh in `transferStockToUnitLoad` :283) | revert C1 → Move Stock succeeds |
| AC-1d waive exit exists | same IT: `waiveReversal(stockReturned=false)` on the fenced tote → lock 0 | IT | — |
| AC-3 Move Unit Load refuses a cancelled tote | `MobileMoveUnitloadServiceUnitTest.scanDestination_refusesToteWithPickedForGoodsoutStock` (+ scanUnitLoad twin) | unit | restore `== ON_HOLD` → red |
| AC-3 regressions | `…_stillMovesQualityFaultContainerOutOfDamaged`, `…_stillMovesPackageWithPickedForGoodsout` (if §4.2 exemption adopted), `…_stillRefusesOnHold` | unit | widen to strict `!= NOT_LOCKED` → first two red |
| AC-4 message | assert substrings: tote label, `Picked`, `Cancellation` (1-arg form — say why not `getKey()`) | unit | revert text |
| AC-5 BOL visibility | `BillofladingServiceUnitTest.closeBOL_writesServiceLog_whenShippedPalletCarriesPendingReversal` + `…_writesNothing_whenNone` (negative control) | unit + optional IT | delete the call → red; invert the predicate → negative control red |
| AC-6 rail | `MoveSourceLockComparisonRailTest` — 4 offenders on develop, 0 after; self-tests per pattern | unit (source scan) | revert one MMU site → red |

Baseline: run the full `mvn -o clean test` + failsafe adjacent in time (`wms2-test-suite-baseline-and-h2-verdict`). Use `-Dfailsafe.excludes`, never `-Dit.test='!…'` (`maven-it-test-exclusion-discards-includes`).

---

## §8 Concurrency, multi-replica, Flyway

- **Lock order.** Canonical is Customerorder → Pickingorder → Stockunit (SBDEV-2481). Item 1 removes Stockunit UPDATEs at C1/C2, which is strictly fewer row locks.
  - C1's comment :1015-:1027 about ordering the clear *after* `sendToClearing` stops mattering for 100-locked SUs. Keep the order for any residual write (for example, if §9(d) keeps clearing 103/104).
  - Item 3 adds reads only. MMU `scanDestination` already locks UL(source) first (:326, SBDEV-3442), and the new type lookup is an unlocked read. Item 4 option (a) adds nothing.
  - Item 5 adds one read before the bulk UPDATE, plus an afterCommit REQUIRES_NEW (a second slot, taken after the outer locks are released).
- **Race: cancel vs. operator Move Stock.**
  - `transferStockToUnitLoad` re-reads the source with `findByIdForUpdate` + `refresh` (`CancellationReversalService:368-:372` describes it), so it judges the committed lock.
  - Before the fix there was a window: once the cancel commits, the lock is 0 and Move Stock succeeds. That window is c1wh's 3 minutes. After the fix the lock goes 100 → 100, so there is no window.
  - Race: completeReversal vs. Move Unit Load. The MMU stock-lock read is unlocked (`findByUnitloadId` :363). It can see 100 (refuse — safe) or the committed 0 after reversal (the tote is empty by then). There is no unsafe interleaving.
- **Multi-replica.** The fence is a DB column value. No in-JVM state, cache or singleton is introduced. `closeBOL`'s in-JVM `bolToClose` guard (:344-:349) is pre-existing and unaffected. The rail and the type check are stateless.
- **Flyway: none needed.**
  - No new column or constraint. `entity_lock` already holds 100.
  - The waive columns are V2.2.34 (SBDEV-3381), already on dev and not on PRD. That is a **deploy prerequisite**, not a migration of this ticket.
  - A Service Log uses the existing `message` table.
  - Evidence: every change in items 1–6 is Java or test-only, per §0–§6.

---

## §9 Open questions a reviewer could dispute, with recommended answers

**(a) Preserve for ALL cancel paths, or only where `reversal_required` is known?**
- Recommendation: key the rule on the **lock value** ("a cancel never lowers PICKED_FOR_GOODSOUT") at C1, C2 and C3. **Exclude C4** (forceCancel PACKED arm), which writes no log row (§2.3).
- The lock value is the lookup-free proxy for "this tx writes or wrote a reversal_required row" (§0.1 producer census; §2.1). A literal "only where reversal_required is known" rule would need a lookup at C2, because C2 clears before it logs.
- Write the C4 exclusion as a code comment naming the missing row. Propose the missing reversal row for packed force-cancels as a separate finding.

**(b) Item 3: reuse SourceLockGuard or own check?**
- Recommendation: **own check**, in a static sibling in `util/`, with an allowlist `{NOT_LOCKED, QUALITY_FAULT}` and the Package-100 exemption decided explicitly (§4.2–4.3).
- SourceLockGuard's contract is "refuse every non-zero". Reusing it breaks Damaged-QF moves (30 live SUs on c1wh) and parcel re-handling (3 moves in 60 days on c1wh).

**(c) Split into two PRs?**
- Recommendation: **yes, two, in this order.**
  - **PR-A** = items 5 + 4(a) + 6's scaffolding. This PR is observability plus messages, and it is fail-open.
  - **PR-B** = items 1 + 3 + 6 green. This PR is the fence, and it is fail-closed.
- PR-B must not reach **PRD** before SBDEV-3381 (waive API + V2.2.34) is on PRD, and should wait for SBDEV-3548 (mobile Waive button). The SBDEV-3321 architect §4.3 says so: "If the team will not take the waive … do not ship a fail-closed fence."
- Merging to develop deploys to dev and runs Flyway (`wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway`). Develop is fine because 3381 is already there; the gate is the release to PRD.

**(d) At C1/C2, "skip 100" or "write no stock lock at all"?**
- Recommendation: **write none**. The only lock the cancel's own logic produced is 100 (§0.1). 103/104 belong to other processes (the same rule `CancellationReversalService:283-286` applies). c1wh PRD has 1 tote SU at 103 that a cancel would silently un-damage today.
- Cost: `PickingorderBusinessServiceUnitTest:1545` flips (its ON_HOLD fixture), and there may be a stock-change message divergence for 103 (unmeasured).
- Reviewer counter: this enlarges scope beyond the ticket's wording. If that wins, "skip 100" gives the same fence.

**(e) What about M5/M6/M7 (Damaged move, adjust amount, delete container)?**
- Recommendation: name them in the plan as un-fenced. **Propose on this ticket (sub-T3):**
  - `adjustAmount` refuses 100 (`StockunitService:869`, denylist → add 100). It has the same shape as its SHIPPED/To-Delete refusals.
  - `deleteUnitLoad` refuses a container carrying 100 stock (`UnitloadService:596`).
- Leave M5 as the SBDEV-3341-accepted asymmetry (architect §4.2) but record it.
- Rank: M7 > M6 > M5 by blast radius, since delete retires the stock to Nirwana, which is the c1wh end shape.
- Each is one guard at one site. Nam decides whether these ride in this PR or a follow-up.

**(f) Does the ON_HOLD arm need fixing at all, given §1.2?**
- It is prevention, not incident repair. Its one harmful continuation is loading the tote onto a pallet (carrier arm :514) and then BOL close.
- Recommendation: keep item 3 but take it at its narrowest (alternative (b) in §4.2: refuse 100 on a Tote). The broader allowlist is a separate design call with measured costs. **Correct the ticket's claim** that it "succeeded on T-0002".

**(g) The waive's retained-lock residual (§2.4).**
- After item 1, `lockRetained` becomes a live strand shape: a row closed while the SU stays at 100 forever.
- Recommendation: add the case to the plan's residual-risk section with its current exposure (0). Add a `PendingReversalReconciliationJob`-style detector for "closed row ∧ SU still 100 on a tote" as a propose-only follow-up, and do not fold it in.

**(h) Item 4 wording promises a Waive the floor cannot press.**
- Recommendation: use wording that names the Cancellation screen and "an outbound manager" (the Waive API grant holders per the 3381 plan: `outbound-manager`, `super-admin`). It should not name a button until SBDEV-3548 ships. Re-word when 3548 lands.

### Side findings (propose, not in scope)

1. **`UnitloadBusinessService.sendToClearing` swaps two arguments.**
   - Signature: `sendToClearing(Unitload, String activityCode, String comment, String orderNumber)`.
   - Body at :691: `transferUnitLoadToLocation(unitload, clearingLocation, true, activityCode, comment, orderNumber)`. The target's signature is `(…, activityCode, orderNumber, comment)`, so comment and order number trade places.
   - Evidence: c1wh `unitload_record` 121692146 (the cancel's TRANSFER to Clearing) has `ordernumber NULL`, `additionalcontent '009729-000020'`.
   - Every cancel's Clearing move loses its order number from the audit column. T1, one line; there is a sibling sweep of the 8 `sendToClearing` callers to do.
2. **Force-cancel of a PACKED/PALLETIZED order writes no reversal row** (§2.3). Population 0 on PRD today.
3. **R1 message lacks `describe()` parity with SourceLockGuard** (the SBDEV-3226 precedent). This belongs in item 4 anyway.

---

## Method notes and instruments

- Code: `git fetch origin`, then `git show origin/develop:<path>` into the scratchpad for files ≥600 lines, grepped and sliced (`CustomerorderService` 1153 lines, `PickingorderBusinessService` 1309, `StockunitService` 1133, `BillofladingService` 1647, `UnitloadBusinessService` 985, `CancellationReversalService` 915, `MobileMoveUnitloadService` 823). The stale working checkout was never read.
- zsh trap hit while building this: `git show $R:src/...` with `R=origin/develop` is parsed as a zsh `:s` history modifier and fails with `ambiguous argument 'origin/developvice.java'`. Use literal `origin/develop:` or `${R}:`.
- `git grep -E` with `\s` returned a **false zero** for the lock-comparison census. The rerun with `[[:space:]]` found 37. The positive control (the 4 known MMU hits) is what caught it.
- DB queries (all read-only; I list only the ones I relied on):
  - c1wh PRD: stockrecord for C1-0063 and rfernandez 21:40–22:10Z; flowbin/FLA check for the 4 destinations; unitload_record for C1-0063; cancellation_log ⨝ stockunit; stockunit lock distribution; locks 100/103 by location and type; operator TRANSFER by UL type (60d) and the 3 Package rows plus their current state; area flags for Clearing et al.; cancelled-with-parcel count; tote-stock lock distribution; UL lock distribution.
  - hydra PRD: cancellation_log reversal rows; stockrecord for the 7 SU ids; unitload_record for T-0002; operator TRANSFER by UL type (90d); cancelled-with-parcel; tote-stock locks (empty, with a positive control: 8 Tote-type ULs exist).
- Not queried: nywh-shipitez-prd and wsl-wineco-prd (the brief reports 0 reversal rows on both). No UAT/dev tenant was queried. Every "0 on PRD" in this doc covers the **two** tenants named, not all four.

---

## Main-session verification (2026-09-27)
- Spot-checked on origin/develop a5b36931. `UnitloadBusinessService:688` `sendToClearing(Unitload, String activityCode, String comment, String orderNumber)` calls `:691` `transferUnitLoadToLocation(unitload, clearingLocation, true, activityCode, comment, orderNumber)`, against the signature at `:221` `(…, String activityCode, String orderNumber, String comment)`. **The swap is confirmed.**
- Also confirmed: `StockunitBusinessService:286-289` `if (!ignoreLock) { int lock = …; if (lock != NOT_LOCKED) throw "Source stockUnit=… is locked=" + lock` (§1.1 verdict).
- Instrument note: this analysis lane could not write its own file (the harness refused subagent report files). The main session extracted it verbatim from the lane transcript.

## Resolved decisions (Nam, 2026-09-27) — do not re-open
| # | Question | Decision |
|---|---|---|
| D1 | Item 3 rule (§4.2, §9 f) | **Refuse PICKED_FOR_GOODSOUT (100) on a Tote-type source**, in `MobileMoveUnitloadService.scanUnitLoad` and `scanDestination`. Every other lock and unit-load type keeps today's behaviour: QUALITY_FAULT moves out of Damaged and Package-at-100 moves still work, and `== ON_HOLD` stays. This is a container-type check, not a pending-reversal lookup. The item 6 rail is re-worded to match. |
| D2 | Cancel-site lock write (§9 d) | **Skip only 100.** C1/C2/C3 no longer lower PICKED_FOR_GOODSOUT and still reset every other lock to 0, as today. C4 (forceCancel PACKED arm, no log row) **keeps clearing**, with a comment naming the missing row. |
| D3 | Destroy paths M5/M6/M7 (§9 e) | **Guard M6 and M7 in this ticket.** `StockunitService.adjustAmount` refuses 100, like its SHIPPED/To-Delete refusals, and `UnitloadService.deleteUnitLoad` refuses a container carrying lock-100 stock. M5 (Move Stock to Damaged, `ignoreLock=true`) stays the SBDEV-3341-accepted asymmetry and is documented as a residual. |
| D4 | Delivery (§9 c, side finding 1) | **Two PRs.** PR-A is fail-open: item 5 BOL visibility, item 4(a) lookup-free messages, the item 6 rail scaffold, and the one-line **`sendToClearing` argument-swap fix** with its sibling sweep of callers. PR-B is fail-closed: item 1 (D2), item 3 (D1), M6/M7 guards (D3), and the rail going green. **PR-B must not reach PRD before SBDEV-3381 (V2.2.34 + waive API) and SBDEV-3548 are on PRD.** Merging to develop is fine. |

Carried as-is from the analysis's recommendations, not re-asked:
- Item 4 uses wording (a), with no lookup, naming the Cancellation screen and "an outbound manager" rather than a Waive button.
- Item 5 counts in-transaction before the bulk UPDATE, logs a WARN inline, writes the Service Log row after commit, and applies the same to `finishTransfer`.
- The rail is a source scan, not ArchUnit.
- The waive's retained-lock residual (§9 g) is an accepted risk with a propose-only detector.
- The ticket's two errors get corrected in the plan: "known test impact" and "it succeeded on T-0002".

## Round-1 review decisions (Nam, 2026-09-27) — settled
| # | Decision |
|---|---|
| D1′ (supersedes D1) | **Move Unit Load refuses lock 100 on a Tote-type source ONLY on the carrier arm**: the move that puts the tote onto a pallet or carrier (`MobileMoveUnitloadService` ~:514), the one path that leads to BOL close. Relocations between locations are unchanged for cancelled and live totes alike. Why: the premise "0 operator tote moves" was false on WineCo PRD (365 d: 19 Clearing→Staging/Club/PutAway moves of cancelled totes, including T-0082 7 min after its cancel; 3 FinishedPicking→Staging moves of LIVE totes; almost all v1-era). Relocation does not harm the reversal (completeReversal works by SU id, toteState is label-based). Item 5 keeps a BOL close over pending reversals visible. |
| D3′ (restates D3) | The M6 half of D3 is already true on develop: `StockunitService.adjustAmount`'s `switch` `default:` arm (:885-:897) refuses 100 before `changeAmount`, pinned by `StockunitServiceUnitTest:2498`. D3 reduces to **the M7 guard in `deleteUnitLoad`** plus an actionable message on the adjustAmount refusal, which moves to PR-A as fail-open. |

## D5 (Nam, 2026-09-29): fence M5 in PR-B. This supersedes D3's M5 carve-out.
- **Trigger:** the final full-branch security lane found that D3 had left M5 out partly because plan R2 said the route "Needs `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`". That premise is false.
  - `StockunitService.transferStock`'s split arm checks the function only on the QF→Damaged-in-place branch.
  - The non-QF→Damaged branch (`transferStockToUnitLoad(..., CODE_DAMAGED, …, true, true)` then `setEntityLock(QUALITY_FAULT)`) has no lock check and no function check beyond `/transferStock`'s `MOBILE_UI_VIEW_STOCK_TRANSFER` / `WEB_UI_VIEW_STOCK_UNIT`.
  - 103 is operator-removable, so `removeLock` → free move is an escape in R2's case (a) as well as case (b).
- **Decision:** refuse PICKED_FOR_GOODSOUT on that branch with the goods-out hint (verb "moving"). TDD, mutation check and review, pushed to #431.
