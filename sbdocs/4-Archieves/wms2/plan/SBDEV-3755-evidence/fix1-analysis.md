---
title: "SBDEV-3755 Fix 1: analysis bundle (transferStockToUnitLoad replen-hold refusal, option c)"
ticket: SBDEV-3755
kind: evidence
created: 2026-10-13
code_base: "v2/wms2-api origin/develop a4fd6490; PR #510 branch origin/fix/SBDEV-3755-replen-holder-multi-and-child-banner @ c6f0cbc0"
author: Claude (executor, analysis phase; no production code written, no mvn run)
---

# SBDEV-3755 Fix 1: analysis bundle

**Scope:** option (c), decided by Nam on 2026-10-13. `StockunitBusinessService.transferStockToUnitLoad`
refuses stock that an active replen (state < FINISHED=700) holds, unless the caller opts in. This
bundle is analysis only. There is no plan and no code in it.

Code was read from `origin/develop` (a4fd6490) with `git show` / `git grep`. Code from PR #510
(`hasActiveHolder`, `blocksMove(Integer)`, `existsForStockUnit`) was read from
`origin/fix/SBDEV-3755-replen-holder-multi-and-child-banner` (c6f0cbc0).

---

## 0. Headline findings (read these first)

1. **The available-amount guard already confines the hazard to one data state.** The check reads
   `if (sourceStockunit.getAmount().subtract(sourceStockunit.getReservedamount()).compareTo(amount) < 0) throw`.
   Every caller is bound by it: there is no `ignoreLock`-style bypass, and it runs on the locked row.
   Only two branches displace a replen's source:
   - **re-parent**: `destinationStockUnit == null` and `amount >= getAmount()`;
   - **merge-to-zero**: the source amount reaches 0, which sends it to Nirvana when the source has
     no FLA.

   Both need `amount >= A` and `amount <= A − R`, so **R ≤ 0** on the source stock unit. A replen
   that still holds a positive reservation therefore *cannot* be displaced by this method today. A
   partial split, or a merge that leaves the source above 0, leaves the source stock unit in place,
   so the replen's `stockunitId` and `requestedlocation` stay correct.

   This argument holds for every caller and does not depend on enumerating them. It holds only while
   reservedamount ≥ 0. With R < 0, `amount` could exceed A; PRD and dev both have 0 such rows (§7).
2. **PRD shows the R ≤ 0 state is produced on purpose, as an operator workflow.** Over 180 days on
   WineCo PRD there were **110** drains to 0 (104 `TRANSFER`, 6 `MANUAL_SPLIT`) of a stock unit that
   an active replen held. In **108 of 110**, a `MANUAL_ADJUSTMENT` reserved change to 0 came within
   the 10 minutes before. That is the "Adjust Reserved → release replen hold" button. In every case
   the cron then cancelled the replen, within 0.2–50 s.

   Monthly: Jul 32, Aug 28, Sep 40, Oct 1 (to the 13th). A Fix 1 that refuses these moves would put
   about 30–40 new refusals a month in front of WineCo operators, unless SBDEV-3622 removes the holder
   first (§8 R1).
3. **Recommendation: a narrow refusal, not a wide one.** Refuse only on the re-parent and
   merge-to-zero branches, after the branch is decided and under the source-SU lock. The split and
   partial-merge branches displace nothing, and refusing them would contradict a standing acceptance
   row of SBDEV-2492: manual test 5, *"split a SU backing a replen → split succeeds; replen
   untouched"*.

   With the narrow refusal, most callers can never reach the guard while the replen holds R > 0. The
   opt-in set shrinks to replen execution, plus picking if Nam agrees (§2).
4. **Opt-in shape: a new overload that takes a trailing policy parameter.** The existing 8- and 9-arg
   methods delegate to it with `REFUSE`. That costs **1–2 main call-site edits** and no test-file
   churn for the other 18 sites. Adding a parameter to the existing signatures would cost 20 main
   edits and about 147 test mentions in 23 files. Reject ThreadLocal (§3).
5. **Two traps for the implementer.**
   - **OptionalSafetyArchTest freeze.** `archunit_store/5fb3fee0…:38` freezes an `Optional.get()`
     inside the **9-arg signature** (`fixLocationAssignmentOpt.get()`). Moving the body into a new
     overload re-attributes that violation to a new signature, and the freeze then counts it as a
     *new* violation. Rewrite it to `.orElse(null)` in the same change.
   - **DI cycle.** `ReplenishorderService` already injects `StockunitBusinessService` (its ctor at
     `ReplenishorderService.java:61`). The guard must use `ReplenishorderRepository` directly, not
     `replenishorderService.hasActiveHolder`.

---

## 1. `transferStockToUnitLoad` anatomy (origin/develop)

| Aspect | Detail (quoted) |
|---|---|
| Overloads | 8-arg `transferStockToUnitLoad(Stockunit, Unitload, BigDecimal amount, String activityCode, String orderNumber, String comment, boolean ignoreLock, boolean removeUnitLoadIfEmpty)` delegates with `null` to the 9-arg overload, which adds `FixLocationAssignment preloadedFixLocationAssignment`. |
| Tx | Both are `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, so REQUIRED: they join the caller's transaction. |
| Lock order | (1) For a BLOCK_REALIGN activity code, `pickLineRealignmentService.lockOwningPickingorders(List.of(sourceStockunit.getId()))`. (2) Source SU: `LockReads.forUpdate(... stockunitRepository::findByIdForUpdate)`. (3) Src UL → src Location → dst UL → dst SU (same itemdata) → dst Location. |
| Available guard | Runs right after the SU lock and is unconditional: `getAmount().subtract(getReservedamount()).compareTo(amount) < 0` throws `"amount=… requested is more than available=…"`. |
| Lock-state guard | `if (!ignoreLock)` refuses any non-`NOT_LOCKED` lock on the src SU, src UL, src Location, dst SU, dst UL or dst Location. |
| Branch decision | The FLA is looked up on the **source** location (`findByAssignedlocationId(sourceLocation.getId())`, or the caller-preloaded one). `if (destinationStockUnit == null && (A > amount \|\| fla != null))` creates a 0-amount dst SU, which makes the merge branch run. |
| **Re-parent branch** | Runs when `destinationStockUnit == null`, i.e. no same-item dst SU, `amount >= A` and no FLA at the source. It does `sourceStockunit.setUnitloadId(destinationUnitload.getId())`; the **same SU id** now lives at the destination. Then: realign the pick line (BLOCK_REALIGN only); `recordTransferStockUnit`; a CODE_DAMAGED `recordCreation`; `relocateEmptiedContainer` of the source UL if it is empty and `removeUnitLoadIfEmpty`. **No replen sync.** |
| **Merge branch** | Runs when a dst SU exists or was created. Dst amount += amount, src amount −= amount, then `recordRemoval` and `recordCreation`. When the source has **no FLA and its amount is 0**, `sendStockUnitToNirvana(sourceStockunit, …)`, which itself throws `STOCKUNIT_HAS_RESERVATION` if reserved > 0. The source SU id survives, moved onto the Nirwana UL and set to `GOING_TO_DELETE`. With an FLA, the source stays at 0 on the FLA location. **No replen sync.** |
| Replen execution | `MobileReplenishService.finishReplenishmentOrderWithoutRefill`, the only route to it being `POST /v3/replenish/multi-unitloads`. It calls `transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked, CODE_REPLENISHMENT, replenishOrder.getNumber(), null, false, true)` **while the order is still < 700**, because `setState(FINISHED)` comes afterwards. Before that, `releaseOwnBooking(replenishOrder, sourceStock)` releases only this order's share (SBDEV-3605). |

### Branch reachability for replen-held stock

| Branch | Precondition | Can a replen-held SU reach it? | Replen effect |
|---|---|---|---|
| Split, or merge leaving src > 0 | `amount < A` or FLA at the source | yes, routinely | none: same SU, same UL, reservation still covered (amount ≤ A − R) |
| Merge-to-zero | `amount = A`, so **R ≤ 0** | only when R ≤ 0 (drift or a manual release) | the replen points at a 0-amount SU in Nirwana, or at 0 on the FLA location |
| Re-parent | `amount ≥ A`, no FLA, no same-item dst SU, so **R ≤ 0** | only when R ≤ 0 | the replen points at the right SU but its `requestedlocationId`/`sourcelocationname` are stale |

**Self-heal.** `ReplenishmentOrderMaintenanceService.isSourceUsable` returns false when
`source.getAmount() <= 0` and when `!locationId.equals(order.getRequestedlocationId())`. The cron
therefore redirects or cancels a displaced replen, but **only at PROCESSABLE (300)**: its recalc
selects `findIdsByState(PROCESSABLE)`. RESERVED (400) and STARTED (500/530) do not self-heal (see the
`REDIRECT_NO_HEAL` WARN in `redirectSource`). PRD and dev today hold **only state-300** active replens
(§7), which is why the observed damage is transient.

---

## 2. Caller census

**Instrument 1** was `git grep -n "transferStockToUnitLoad(" origin/develop -- src/main`. It returned
**20 call expressions** in 10 production files, plus the method's own 2 declarations and
comment-only hits in `StockunitService:557,803`, `MobilePutAwayService:544,565` and
`SourceLockGuard:25`.

**Instrument 2** was `git grep -nE "::transferStockToUnitLoad|transferStockToUnitLoad\b[^(]"`, a
reference-style sweep for method references, reflection or non-call uses. All 42 hits are comments or
javadoc; there is **no method reference, no reflection and no proxy call**. Blind spot: callers
generated at runtime (SDR, AOP) are not visible to either instrument. `StockunitBusinessService` is
not an SDR repository, so SDR cannot reach it.

**SourceLockGuard (listed on the ticket) is not a caller.** Its only hit is javadoc
(`SourceLockGuard.java:25`, *"this javadoc said 'the split route delegates to
transferStockToUnitLoad(…)'"*).

**Indirect callers** (they reach it through `StockunitService.transferStock`):
- `CancellationReversalService` (RTS `completeReversal`);
- web `/v3/stockUnit/transferStock`;
- mobile Move Stock.

`StockunitService.setLockDamaged` reaches it through `UnitloadService.moveStockToNewDamagedContainer`.

**Legend for the "Reach" column.** "R>0 blocked" means the available guard already prevents any
displacing branch while the replen holds a reservation, so the narrow guard fires only on R ≤ 0.

| # | Site | Activity code / ignoreLock / removeIfEmpty | Source stock | Can replen-held stock reach it? (evidence) | Branch(es) hit | Upstream replen guard? | Recommendation |
|---|---|---|---|---|---|---|---|
| 1 | `BillofladingService:1117` combineStock OFF | TRANSFER_BUILD_TRUCK / false / true, with `transferLaneFla` | every SU on the order's **transfer lane** | Unlikely. Lanes are not replen sources (SBDEV-3654 `isUsableSourceLocation`, unconditional), so a replen SU is there only if it drifted. Full amount with R>0 throws "more than available" and **fails the whole BOL** today. | FLA on the lane → merge (src stays at 0); no FLA → re-parent or merge-to-zero | none | **REFUSE** under the narrow guard (fires only on R≤0 drift). ⚠ Unsure: a refusal aborts a truck build. Message must name the replen. |
| 2 | `BillofladingService:1136` combineStock ON (SBDEV-1762) | same | same lane | Same as #1. Moves `min(want, amount − reserved)`. | mostly split; re-parent or drain only when R≤0 and want ≥ A | none | **REFUSE** (narrow) |
| 3 | `ClubLineOrderProcessor:197` | PACKAGING_CLUB / false / true, staging-lane FLA | staging-lane stock (`CustomerorderBatchService` snapshots use `su.getAvailableamount()`) | Unlikely (lane). | FLA → merge; else split or re-parent | none | **REFUSE** (narrow). ⚠ Unsure: a club-run abort |
| 4 | `CustomerorderService:666` packageOrder | PACKAGING / **true** / false | SUs on the order's **picking tote** | Only if a replen bound to a tote SU, which needs drift (a tote is not a usable source). | full amount → re-parent or merge-to-zero | none | **REFUSE** (narrow). Practically unreachable. |
| 5 | `PickingorderBusinessService:1326` pick confirm | PICKING / **true** / true | the pick line's `pickfromstockunitId`, which can be a reserve SU | **Yes.** It first releases the pick's own reservation (`changeReservedAmount(..., pickingPosition.getAmount().negate(), ...)`). A co-holding replen with R>0 then blocks a full-SU pick via the available guard (today). | partial → split; full-SU pick with replen R≤0 → re-parent into the tote | none | **OPT-IN (recommended, ⚠ Nam to confirm).** The goods are already physically picked, and refusing a pick confirm strands the picker. The replen self-heals at 300 because its SU is no longer at `requestedlocation`. Alternative: REFUSE with the replen named. |
| 6 | `StockunitService:378` transferStock → existing pallet (new child UL) | MANUAL_SPLIT / false / true | any SU (web/mobile Move Stock, RTS) | **Yes** | new empty UL → re-parent when amount = A (R≤0), else split | none (the whole-container route at `:542` syncs via `transferUnitLoadToLocation` only because `CODE_MANUAL_TRANSFER` is BLOCK_REALIGN) | **REFUSE** (narrow) |
| 7 | `StockunitService:382` → existing container | MANUAL_SPLIT / false / true | any | yes | merge or merge-to-zero, or re-parent into an empty container | none | **REFUSE** |
| 8 | `StockunitService:428` → flow bin (FLA UL) | MANUAL_SPLIT / false / true | any | yes | merge-to-zero or re-parent | none | **REFUSE** |
| 9 | `StockunitService:597` damaged, QUALITY_FAULT stock within Damaged | MANUAL_SPLIT / **true** / true | already-damaged stock at Damaged | Only if a replen holds damaged stock, which needs drift. | new UL → re-parent or split | none | **REFUSE** (narrow) |
| 10 | `StockunitService:605` → Damaged location | DAMAGED / **true** / true | any | yes | new UL → re-parent or split | none | **REFUSE** (⚠ unsure: damage is a physical fact. An alternative is an opt-in followed by an after-commit `requestForItem`, which `setLockDamaged` already does, but that heals only state 300.) |
| 11 | `StockunitService:634` → new container, generic | MANUAL_SPLIT / false / true | any | yes | **this is the re-parent the ticket describes**: new UL, amount = A | none | **REFUSE** |
| 12 | `UnitloadService:192` moveStockToNewDamagedContainer (from `setLockDamaged`) | DAMAGED / false / true | any | yes | new UL → re-parent or split | none. `setLockDamaged` calls `replenishmentMaintenanceTrigger.requestForItem` after the move. | **REFUSE** (same caveat as #10) |
| 13 | `MobileMoveUnitloadService:760` (branch `:782`) private transferStock: flow-bin / FLA / isMoveStock arms | TRANSFER / false / false | the scanned UL's first SU | **Yes, and it is the PRD hazard path** (104 drains, §7) | merge-to-zero (most common) or re-parent | **YES.** SBDEV-3747's `existsForStockUnit(sourceStockUnit)` → `replenBlockMessage` / `replenHoldsStockMessage`. Pre-lock, not TOCTOU-safe. | **REFUSE.** The central guard makes 3747's check redundant but harmless. Keep it: it is the earlier, more specific diagnosis, and its tests pin it. |
| 14 | `MobilePutAwayService:568` storeBoxOnLocation, flow-bin arm | PUT_AWAY / false / true | any UL label scanned (not only inbound) | Yes, if an operator "puts away" a stored box | merge-to-zero (src has no FLA) or re-parent into the FLA UL | none | **REFUSE.** ⚠ Unsure whether operators use putaway on stored stock. |
| 15 | `MobileReplenishService:317` finish | REPLENISHMENT / false / true | the order's own source | **always**: the executing order is the holder | split, merge-to-zero or re-parent | n/a | **OPT-IN** for *this* order. ⚠ Sibling holders: see §3 and §5. |
| 16 | `MobileTransferOrderService:429` | MANUAL_SPLIT / false / true | any SU the transfer picker scans | Yes, but it runs **only when `stockUnit.getReservedamount().intValue() == 0`**, which is exactly the drift state. | new UL on the lane, amount = A → **re-parent onto the transfer lane** | none | **REFUSE.** (SBDEV-2074 D2b called this path safe because it is `reservedamount==0` guarded. That reasoning missed a holder with R=0.) |
| 17 | `MobileTransferOrderService:435` | MANUAL_SPLIT / false / true | R>0 | moves `availableAmount` < A | split only | none | unaffected under narrow; REFUSE under wide |
| 18 | `MobileTransferOrderService:440` | MANUAL_SPLIT / false / true | any | amountLeft < available | split only | none | unaffected under narrow |

Instrument 1 lists 20 call expressions (2 + 1 + 1 + 1 + 6 + 1 + 1 + 1 + 1 + 3 + the
self-delegation). The table has 18 rows because the self-delegation `StockunitBusinessService:171`
is not a caller, and SourceLockGuard has no call.

### Recommended opt-in set

- **Definite: #15** (replen finish).
- **Proposed: #5** (pick confirm). ⚠ Nam to confirm; the alternative is REFUSE.
- Every other site: **REFUSE** under the narrow guard. Under the narrow guard, #17 and #18 cannot
  reach it.

### Sites I am unsure about

| Site(s) | Doubt |
|---|---|
| #1–#3 | A refusal aborts a whole BOL or club run on a data drift. Today the same drift with R>0 already aborts it via "more than available", so this is no worse in kind. |
| #5 | opt-in vs refuse |
| #10, #12 | Damage is physical; refuse or opt in? |
| #14 | Is putaway of stored stock a real workflow? |

### Out-of-scope sibling (not Fix 1)

`UnitloadBusinessService.processTransfer` runs `syncForMovedStockUnit` **only for BLOCK_REALIGN
codes**: `CODE_MOVE_FIX_ASSIGNMENT`, `CODE_MANUAL_TRANSFER`, `CODE_TRANSFER` and `CODE_ON_HOLD`.
Whole-container relocations under a PASS_THROUGH or null code skip the sync. This was accepted
deliberately by SBDEV-2492 R-1 and SBDEV-2074 AC5. One such route is
`MobileTransferOrderService:424`, which calls `transferUnitLoadToLocation(unitLoad, transferLane, false, null, ...)`
with a null code. It moves a replen-held UL to a lane with no sync, gated only by `reservedamount == 0`.
This is the same R=0 hole by another primitive. Propose it separately; it is not T3-blocking for
Fix 1.

---

## 3. Opt-in mechanism options

| Option | Shape | Main call-site edits | Test churn | Verdict |
|---|---|---|---|---|
| A. New boolean on both existing signatures | `…, boolean removeUnitLoadIfEmpty, boolean allowReplenHeld)` | **20** (every call) | ~**147** mentions in 23 test files. Every `verify`/`when` on the 8/9-arg overloads changes. `NeverMatcherNullBlindnessArchTest` per-class counts (`never()` on params 7–8) shift. | Reject: churn with no benefit, and a positional boolean is easy to pass wrongly. |
| B. **New overload with a trailing policy; existing 8/9-arg delegate with REFUSE** | `transferStockToUnitLoad(…9 args…, ReplenHoldPolicy policy)`, e.g. `REFUSE` / `ALLOW_ORDER(id)` / `ALLOW_ANY` | **1** (#15) or **2** (#5 too) | Only those callers' unit tests (`MobileReplenishServiceUnitTest`, 16 mentions; `PickingorderBusinessServiceUnitTest`, 12) switch their verify to the new overload, plus the `NeverMatcher` counts for those classes. | **Recommended.** Default-safe: every new or forgotten caller refuses. |
| C. Separate named method | `transferReplenishedStock(…, Long executingOrderId)` | 1–2 | as B | Equivalent to B. A named method reads better at #15 but duplicates the javadoc surface. Choose B or C by taste. |
| D. Enum parameter replacing `ignoreLock` | — | 20 | as A | Reject (as A). |
| E. ThreadLocal "replen opt-in scope" | set around the call | 1–2 | low | **Reject.** It is invisible at the call site; it leaks onto pooled threads unless every path clears it in `finally`; it would also apply to *nested* transfers that the scope did not mean to allow; it is the same class of hazard as SBDEV-3190's singleton tenant state; and unit tests calling the bean directly cannot see it. |

### Policy granularity at #15 (decision needed)

`ALLOW_ORDER(id)` allows only the executing order. It would still refuse the finish when a **sibling**
active holder exists on the same SU while the branch displaces it, which requires the sibling's share
to be ≤ 0. Refusing a replen finish for that reason blocks the operator.

`ALLOW_ANY` lets the finish through and leaves the sibling stale. A stale sibling self-heals at 300
only.

PRD and dev both show **0 SUs with ≥2 active holders** today (§7), so this is latent.

**Recommendation:** `ALLOW_ANY` for the finish, with a WARN naming the sibling order numbers. A
narrower policy would add a refusal on the one path that must not refuse.

### Two implementation constraints

**OptionalSafetyArchTest freeze.** The store
`5fb3fee0-6caf-4f48-a5cd-5271da610572:38` freezes:

> `Method <…transferStockToUnitLoad(Stockunit, Unitload, BigDecimal, String, String, String, boolean, boolean, FixLocationAssignment)> calls method <java.util.Optional.get()> in (StockunitBusinessService.java:333)`

The source is `fixLocationAssignmentOpt.isPresent() ? fixLocationAssignmentOpt.get() : null`. If the
body moves into the new overload, rewrite it to `.orElse(null)`. Otherwise the frozen rule reports a
new violation under the new signature.

**Injection.** Use `ReplenishorderRepository.findHoldersByStateLessThanAndStockunitIdOrderById` (a
projection: no entity enters the persistence context, and no lock is taken). Do not inject
`ReplenishorderService`: it injects `StockunitBusinessService` (a cycle). The three unit tests use
`@InjectMocks` on a constructor (`StockunitBusinessServiceUnitTest`,
`…DamagedFullMoveUnitTest`, `…FullMoveInvariantUnitTest`). A new constructor parameter with no
`@Mock` gets `null`, so each needs a `@Mock ReplenishorderRepository`.

### Where the guard goes (narrow form)

Place it after the branch decision, i.e. after the `createStockUnit` placeholder block, so that
`destinationStockUnit == null` is known. Fire when:
- re-parent: `destinationStockUnit == null`; or
- merge-to-zero: `sourceStockunit.getAmount().compareTo(amount) == 0 && fixLocationAssignment == null`.

All row locks are held at that point, so the holder read happens under the source-SU lock. It still
**must run before any write**: the `createStockUnit` placeholder is a write, and it is rolled back by
the throw, which is acceptable because it shares the transaction.

**TOCTOU residual.** `ReplenGeneratorService.calculateOrder` does `replenishorderRepository.save(replenishOrder)`
(the insert) **before** `changeReservedAmount(sourceStock, …)`, which takes the SU lock. A replen
created concurrently is invisible to the move's projection read under READ COMMITTED. The move
commits; the creation then reserves on the displaced SU with a `requestedlocationId` taken from the
pre-move unitload. The creation reserves R > 0, so the next move is guarded, but this one replen
starts stale; at 300 it self-heals. Accept and document it; do not try to close it.

---

## 4. Multi-holder sibling: `findIdByStateLessThanAndStockunitId` (Optional<Long>)

| Site | Snippet | 2+ holders today |
|---|---|---|
| `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` (replenishable dest) | `.findIdByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, stockUnit.getId()).orElse(null)` | `IncorrectResultSizeDataAccessException` → 500, and the whole Move Unit Load (location or carrier arm) rolls back |
| `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit` (non-replenishable dest) | same | same |

The repository comment says so itself: *"Optional<Long> on a predicate that can match several rows
throws IncorrectResultSizeDataAccessException exactly as Optional<Replenishorder> does today:
behaviour preserved, not improved"*. PR #510's code review M1 accepted it as residual.

### Proposed semantics (both sites)

1. Read the holders with `findHoldersByStateLessThanAndStockunitIdOrderById(FINISHED, suId)`: an
   ascending-id projection with no locks.
2. **Pre-check (no lock):** if any holder has `blocksMove(state)`, throw `replenBlockMessage` for the
   first such holder in id order (matches `existsForStockUnit`). This is optional; step 3 re-checks
   under lock.
3. Lock each holder with `findByIdForUpdate` **in ascending id order**. Re-check `blocksMove` on each
   locked row. If any is started, throw `replenBlockMessage(thatOrder)`; the whole move rolls back.
4. Act on each holder:
   - **Replenishable destination:** re-point every holder (`requestedlocationId`, `requestedrackId`,
     `sourcelocationname`). Nothing else changes (I-1).
   - **Non-replenishable destination:** lock the moved SU **once**, after all orders (order… → SU,
     matching SBDEV-3618 Fix D). Then, for each holder in ascending id, `shareOf(order, lockedSource)`
     → `redirectSource(…, recalcPath=false)` → cancel on `NO_CANDIDATE`.
     - The `shareOf` held-share arithmetic (SBDEV-3618 `ReservationShare`) must be read **per order
       after the previous order's release**. Each `redirectSource`/`cancelOrder` mutates
       `lockedSource.reservedamount`. Verify `shareOf` reads the live entity, not a snapshot.
5. **Holder-set drift:** if the post-lock set differs from the probe (a holder appeared or finished),
   either re-read and act on the locked set, or refuse with `RESERVATION_CUT_CHANGED`, mirroring
   `adjustReservedAmount` step (e). Recommendation: act on the locked set; this is a move, not a
   consented cut.

### Lock order and deadlock analysis

| Locker | Order | Source |
|---|---|---|
| SBDEV-3622 reserved cut (`StockunitService.adjustReservedAmount`) | owning POs → holders ≤ PROCESSABLE, **ascending id** (`findHoldersBy…OrderById`) → SU | `StockunitService:997-1027` |
| Cron `recalculateForItem` (one tx per item) | per order in `findIdsByStateAndItemdataId(PROCESSABLE, item)` (**`ORDER BY r.id`**): order → its current SU → target SU (ascending edge waits; descending edge skip-locked, SBDEV-3637) | `ReplenishmentOrderMaintenanceService:161`, repo comment *"ascending id, so recalculateForItem locks an item's orders in the same order as the attributed reserved cut"* |
| Cron full sweep `recalculateOpenOrders` | `self.recalculateOrder(orderId, ctx)`, one transaction per order (each `recalculateOrder` is REQUIRED via the self proxy from a non-tx loop) | `:133-140` |
| Move (proposed) | owning POs (tree) → source UL (`findByLabelidForUpdate`, SBDEV-3442) → per moved SU: holders ascending → SU → target (skip-locked on the move path) | `UnitloadBusinessService.processTransfer`, `ReplenishmentOrderMaintenanceService:263-311` |

- **Move vs cut on the same SU.** Both lock holders ascending, then the SU, so there is no cycle. The
  cut skips holders > PROCESSABLE; the move locks all holders < FINISHED and refuses on started ones,
  so the move's set is a superset of the cut's. Both are ascending, so the subset ordering is
  preserved.
- **Move vs `recalculateForItem`.**
  - The cron holds order A, then SU S, then wants order B (the same item, also holding S). The move
    holds A, waits on... it cannot hold B without A, because it takes them ascending. No cycle.
  - The cron holding order C (a different SU S2) and waiting on target S (ascending edge) while the
    move holds S and wants target S2: the move path is **always skip-locked** on the target, so the
    move defers (`CONTENDED`) instead of waiting. No cycle.
- **Residual (pre-existing, not introduced).**
  - The move walks moved SUs in `findByUnitloadId` order (no ORDER BY), so two concurrent moves of
    overlapping trees can still ABBA. That is SBDEV-3637 Scope limit, accepted as N1/N2 in
    `MobileMoveUnitloadService` (*"0 such overlaps in 90 days on Hydra prd"*).
  - Multi-holder adds more order rows per SU, but they are always taken before that SU and
    ascending, so it adds no new edge class.
- **Fix 1 itself must not lock orders.** It runs after the source-SU lock (SU → order would invert
  order → SU). The proposed guard reads the holders projection only (no `FOR UPDATE`), so it adds no
  lock edge.

### SDR search `findByStateLessThanAndStockunitId`

```java
@RestResource(path = "findByStateLessThanAndStockunitId", rel = "findByStateLessThanAndStockunitId")
Optional<Replenishorder> findByStateLessThanAndStockunitId(...)
```

It is a live search at `/v3/replenishorder/search/findByStateLessThanAndStockunitId` that 500s for a
multi-holder SU. On PR #510 it has **no src/main caller** (repo comment: *"The third no longer has a
src/main caller"*).

**UI sweep:** `git grep "findByStateLessThanAndStockunitId\|StateLessThanAndStockunit"` on
`origin/develop` of `wms2-web-ui` (9e31726) and `wms2-mobile-ui` (36368b6) returns **0 hits in both**.

Positive control: the same `git grep` form finds `'/sysprop/search/findByGroupname'` and
`'/userGroup/search/…'` in `wms2-web-ui/store/admin/*.js`, so the instrument does see SDR search
URLs.

Blind spots:
- a URL assembled at runtime from parts;
- non-UI clients (OMS, scripts). OMS calls `/rest/**`, not SDR; that was not re-verified here.

Test refs: `ReplenishorderServiceUnitTest:455,470` (stubs, which PR #510 likely removes) and
`ReplenishmentOrderMaintenanceServiceReassignTest:185` (a `never()`).

| Option | Effect | Risk |
|---|---|---|
| `@RestResource(exported = false)` | removes the endpoint; the method stays for tests | API contract change with no known consumer. Check `SdrSurfaceInventoryContextTest`'s counts: its comment notes `searches == exportedSearches` is always counted, so check which number it asserts. |
| Change to `List<Replenishorder>` | keeps the endpoint and returns all holders | changes the response shape for a consumer nobody has found; keeps a finder that loads entities (the SBDEV-3244 first-touch hazard if reused in src/main) |
| Delete it | the cleanest | the same contract change, plus the test refs |

**Recommendation: `exported = false`**, matching the four sibling finders the repo comment lists
(*"All four are @RestResource(exported = false)"*).

---

## 5. Merge-branch semantics under (c)

- **Merge-to-zero:** the source SU **id persists**. `sendStockUnitToNirvana` re-parents it onto the
  Nirwana UL with `GOING_TO_DELETE`. The replen's `stockunitId` therefore still resolves, to a
  0-amount SU in Nirwana. Nothing updates the replen. PRD shows the cron's cancel follows at 300 (§7):
  `isSourceUsable` checks `amount <= 0` and Nirwana ≠ `requestedlocation`.
- **Merge leaving the source > 0:** the replen is untouched and correct. The destination SU is a
  different id that no replen references.
- **Re-parent:** the same id moves location. The replen's `stockunitId` is right and its location
  fields are stale.
- **Opted-in caller that merges replen-held stock:**
  - **#15, the finish:** the executing order is set to FINISHED right afterwards, and its frozen
    snapshot (SBDEV-1714 `moved_source_unitload_label`, captured *before* the transfer) records the
    origin. Nothing else is needed for that order. **Siblings** (≥2 holders) are the gap; see §3's
    policy note.
  - **#5, picking (if opted in):** the replen keeps pointing at the drained or re-parented SU. Heal is
    left to the cron at 300. At 400/500 the replen blocks (`blocksMove`) at the Move Unit Load layer,
    but the pick-confirm path has no such check.

    Recommend a WARN log naming the holder. Optionally use an after-commit
    `ReplenishmentMaintenanceTrigger.requestForItem(itemdataId)`, the same mechanism `setLockDamaged`
    already uses; it is deferred to after commit (SBDEV-3286), so it adds no lock edge.
- **Already handled anywhere?** No.
  - `transferStockToUnitLoad` has no replen awareness at all; its only collaborators are repositories,
    `stockrecordService`, `unitloadBusinessService` and `pickLineRealignmentService`.
  - `ReplenishmentOrderSourceSyncService` is reached only from `UnitloadBusinessService.processTransfer`
    (BLOCK_REALIGN codes).
  - `git grep syncForMovedStockUnit` on src/main returns exactly that one call site plus its
    definition.

---

## 6. Existing tests

**Unit tests on `StockunitBusinessService` itself** (they need `@Mock ReplenishorderRepository`;
none seeds a holder, so none refuses):
- `StockunitBusinessServiceUnitTest` (17 refs)
- `StockunitBusinessServiceDamagedFullMoveUnitTest` (4)
- `StockunitBusinessServiceFullMoveInvariantUnitTest` (3)
- `MoveSourceLockComparisonRailTest` (2)

**ITs that call it directly or through callers:**
- `StockunitBusinessServiceConcurrencyIT` (2)
- `BusinessServiceLockRefreshStaleVersionIT`
- `ClubLineRetryIntegrationTest`
- `MobilePutawayServiceIntegrationTest`
- `StockunitDamagedRollbackIntegrationTest`

None seeds an active replen on the moved SU, by grep of `replenishorder` in `*IT.java` /
`*IntegrationTest.java` combined with a transfer-caller call. Only
`MobileReplenishServiceIntegrationTest` and `ReplenishRedirectLockOrderIT` match both, and both are
replen-execution or move tests.

**Caller unit tests** (they mock `StockunitBusinessService`, so the guard is invisible to them):

| Test class | Refs |
|---|---|
| `BillofladingServiceUnitTest` | 10 |
| `ClubLineOrderProcessorUnitTest` | 9 |
| `MobileMoveUnitloadServiceUnitTest` | 8 |
| `MobilePutAwayServiceUnitTest` | 9 |
| `MobileReplenishServiceUnitTest` | 16 |
| `MobileTransferOrderServiceUnitTest` | 7 |
| `PickingorderBusinessServiceUnitTest` | 12 |
| `StockunitServiceAuditCommentClampUnitTest` | 2 |
| `StockunitServiceParcelSourceRefusalUnitTest` | 12 |
| `StockunitServiceToteContainerRelocationUnitTest` | 7 |
| `StockunitServiceTransferStockDestinationTest` | 5 |
| `StockunitServiceUnitTest` | 13 |
| `UnitloadServiceUnitTest` | 4 |

**Rails:**
- `NeverMatcherNullBlindnessArchTest` keeps per-class `never()` counts on `transferStockToUnitLoad`
  params 7–8 (e.g. `"MobileReplenishServiceUnitTest:25"`), and those shift when a test moves to the
  new overload.
- `OptionalSafetyArchTest` freeze (§3).

**Would break under a default refusal**

| Design | Breaks |
|---|---|
| Wide (refuse at entry) and #15 not opted in | Every replen-finish IT: `MobileReplenishServiceIntegrationTest`, `MobileReplenishMultiUnitLoadIT`, `ReplenishClaimIT`, `ReplenishLaneExclusionUnconditionalIT`, `MobileReplenishSourceScanIT`, `ReplenishorderRedirectSourceIT` and `ReplenishmentStaleVersionAtLockReadIntegrationTest` (all reach `fulfillMultipleUnitLoads`). Also any IT doing a partial split of a replen-backed SU (SBDEV-2492 manual row 5 has no automated twin found). |
| Narrow, with #15 opted in | **None found** by the grep above. Blind spot: fixtures loaded from `src/test/resources/scripts/*.sql` (e.g. `mobileReplenishService_multiUnitLoads.sql`) that seed holders were not cross-checked against non-replen transfer callers. |
| Signature change (option A) | Compile breaks in all 23 test files above |

---

## 7. DB evidence (floor item 1)

Constants: PROCESSABLE=300, RESERVED=400, STARTED=500, FINISHED=700 (`WmsConstants.java:66,71,76,136`).

### Q1: active replens vs their stock unit

Run on both **WineCo PRD** (`wsl-wineco-prd`) and **WineCo dev** (`wms2-wineco-dev`). On dev, the
first attempt dropped (*"server closed the connection unexpectedly"*) and the retry succeeded.

```sql
with a as (select r.id, r.state, r.stockunit_id, r.requestedlocation_id, r.requestedamount, s.id sid, s.amount, s.reservedamount, u.storagelocation_id, u.labelid
  from replenishorder r left join stockunit s on s.id=r.stockunit_id left join unitload u on u.id=s.unitload_id where r.state < 700)
select now(), count(*) active_total,
 count(*) filter (where sid is not null) active_join_su_POSITIVE_CONTROL,
 count(*) filter (where state=300) s300, count(*) filter (where state=400) s400, count(*) filter (where state>=500) s500plus,
 count(*) filter (where sid is not null and storagelocation_id is distinct from requestedlocation_id) su_not_at_requestedloc,
 count(*) filter (where sid is not null and storagelocation_id = requestedlocation_id) su_at_requestedloc_CONTROL,
 count(*) filter (where stockunit_id is not null and sid is null) su_missing, count(*) filter (where stockunit_id is null) su_null,
 count(*) filter (where amount = 0) su_amount_zero, count(*) filter (where labelid ilike 'nirwana' or labelid ilike 'nirvana') su_in_nirvana,
 count(*) filter (where reservedamount <= 0) su_reserved_le0, count(*) filter (where reservedamount < 0) su_reserved_neg,
 count(*) filter (where reservedamount > 0 and reservedamount < requestedamount) su_reserved_below_requested,
 count(*) filter (where reservedamount >= requestedamount) su_reserved_covers_requested
from a
```

| Metric | PRD (2026-10-13 19:31:02Z) | dev (19:31:16Z) |
|---|---|---|
| active_total | 572 | 564 |
| active ⋈ stockunit (**positive control**) | 572 | 564 |
| state 300 / 400 / ≥500 | 572 / 0 / 0 | 564 / 0 / 0 |
| **SU's unitload not at requestedlocation** | **0** | **0** |
| SU at requestedlocation (control) | 572 | 564 |
| stockunit_id missing / null | 0 / 0 | 0 / 0 |
| SU amount 0 / in Nirwana | 0 / 0 | 0 / 0 |
| SU reserved ≤ 0 / < 0 | 0 / 0 | 0 / 0 |
| 0 < reserved < requested | 0 | 0 |
| reserved ≥ requested | 572 | 564 |

### Q2: multi-holder exposure

```sql
select (select count(*) from (select stockunit_id from replenishorder where state<700 and stockunit_id is not null group by stockunit_id having count(*)>=2) x) su_with_2plus_active_holders,
 (select count(distinct stockunit_id) from replenishorder where state<700) distinct_su_held_CONTROL,
 (select count(*) from (select stockunit_id from replenishorder group by stockunit_id having count(*)>=2) y) su_with_2plus_holders_any_state_CONTROL,
 (select max(created) from replenishorder) newest_replen, (select count(*) from replenishorder) replen_total
```

| Metric | PRD | dev |
|---|---|---|
| SUs with ≥2 active holders | **0** | **0** |
| distinct SUs held (control) | 572 | n/a |
| SUs with ≥2 holders in any state (control: the grouping can return >0) | 13,862 | n/a |
| replen_total / newest | 62,980 / 2026-10-13 19:14Z | 389,110 / n/a |

*Snapshot only. Blind spot: a multi-holder state can exist transiently between cron ticks.*

### Q3: history, i.e. did `transferStockToUnitLoad` displace replen-held stock?

Re-parent rows: `STOCK_TRANSFERRED` with the same from/to SU identity and a changed unitload,
joined to replens active at that time. "Active at that time" is approximated by
`r.created < sr.created and (r.state < 700 or r.modified > sr.created)`, which is an
**over-approximation**: `modified` moves on any update.

```sql
select sr.activitycode, (sr.ordernumber = r.number) own_replen, r.state, count(*), count(distinct r.id), min(sr.created), max(sr.created)
from stockrecord sr join replenishorder r on r.stockunit_id = sr.fromstockunitidentity::bigint
where sr.created > now() - interval '180 days' and sr.type='STOCK_TRANSFERRED' and sr.fromstockunitidentity = sr.tostockunitidentity
  and sr.fromunitload is distinct from sr.tounitload and r.created < sr.created and (r.state < 700 or r.modified > sr.created)
  and sr.fromstockunitidentity ~ '^[0-9]+$'
group by 1,2,3
```

PRD results:
- `REPLENISHMENT`, own replen, 75 rows / 75 replens. This is the **positive control**: the finish
  re-parents.
- `TRANSFER`, a foreign replen (now 800), **1 row** (2026-04-27).

Drain-to-zero rows use the same join with `sr.amountstock = 0 and sr.amount < 0`. PRD results:

| type / code | own | rows | last seen |
|---|---|---|---|
| STOCK_REMOVED / REPLENISHMENT | yes (**positive control**) | 249 | 2026-10-13 |
| **STOCK_REMOVED / TRANSFER** | no | **104** | 2026-10-06 |
| STOCK_ALTERED / MANUAL_REMOVAL | no | 12 | 2026-07-15 (an adjustAmount, not this method) |
| **STOCK_REMOVED / MANUAL_SPLIT** | no | **6** | 2026-08-25 |

All 110 `TRANSFER`/`MANUAL_SPLIT` holders are now state 800, with `moved_amount` null (none
finished).

The six most recent, per SU stockrecord sequence:
- `REPL062966`, `REPL058249`, `REPL058250`, `REPL062806`, `REPL061088`, `REPL062311`.
- Each shows `MANUAL_ADJUSTMENT:STOCK_RESERVED_CHANGED` (seconds before), then the drain
  (`TRANSFER:STOCK_REMOVED:-N`), then `REPLENISHMENT_CANCELLED` 1.3–50 s later.
- `REPL062966` (2026-10-06) has the replen modified 0.156 s after the drain with no
  `REPLENISHMENT_CANCELLED` row; its cancel route is unexplained.
- Operators: danielvalentim, adriantorres, adampetersen.

By month, with "a `MANUAL_ADJUSTMENT` reserved change within the 10 min before" in brackets:

| Month (2026) | Drains | Preceded by manual reserved change |
|---|---|---|
| Apr | 6 | 4 |
| May | 2 | 2 |
| Jun | 1 | 1 |
| Jul | 32 | 32 |
| Aug | 28 | 28 |
| Sep | 40 | 40 |
| Oct (to the 13th) | 1 | 1 |

Dev, running the same combined query over 180 days: only own-replen `REPLENISHMENT:STOCK_REMOVED`,
22 rows (positive control). **0 foreign displacements.**

**Reading.**
- The R≤0 state is created by the "Adjust Reserved" release button, then the stock is moved through
  the Move Unit Load stock arm (`TRANSFER` = `MobileMoveUnitloadService.transferStock`, now guarded by
  SBDEV-3747) or Move Stock (`MANUAL_SPLIT`).
- Damage so far is transient, because every holder was at 300 and the cron cancelled it.
- The October drop to 1 is consistent with SBDEV-3622 (a cut to 0 cancels the order in the same
  transaction) and/or SBDEV-3747 reaching PRD, but **which PRD build is deployed was not checked**.
  Use `actuator/info` build time per memory, not branch HEAD.

---

## 8. Risks

| # | Risk | Who sees it | Mitigation |
|---|---|---|---|
| R1 | **New refusals on a live operator workflow** ("release the replen hold, then move"): 30–40 a month on PRD in Jul–Sep (§7) | Mobile Move Stock / Move Unit Load / web Move Stock users at WineCo | If SBDEV-3622 is on PRD, a cut to 0 cancels the holder in the same tx, so the later move finds no holder and is not refused. **Confirm the PRD build contains 3622 before shipping Fix 1**, or the operator's documented remedy stops working. The message must say what to do: "cancel replenishment order X (or cut its reservation to 0) first". |
| R2 | Refusal aborts batch flows (BOL build #1/#2, club run #3, package #4) on drift | Shipping, club, packing | Today the same drift with R>0 already aborts them via "more than available". Under the narrow guard they refuse only on R≤0 + holder, which PRD has 0 of now. The message names the order. |
| R3 | Pick confirm (#5) refused, if not opted in | Picker, with goods in hand | Opt in (recommended) + WARN + after-commit `requestForItem` |
| R4 | Replen finish (#15) refused because of a sibling holder | Replen operator | `ALLOW_ANY` for the finish (§3). 0 multi-holder SUs today. |
| R5 | Damage (#10, #12) refused | Inventory control | Decide REFUSE vs opt-in (§2, unsure) |
| R6 | Concurrency: the guard reads holders under the source-SU lock, but replen **creation inserts before it locks the SU** (`ReplenishGeneratorService`: `save` then `changeReservedAmount`) | none visible; one replen born stale (self-heals at 300) | Accept and document |
| R7 | Lock inversion if an implementer makes Fix 1 *lock* or *sync* orders inside `transferStockToUnitLoad` (SU → order vs everyone else's order → SU) | 40P01 deadlocks vs cron and cut | The guard reads the projection only; no `findByIdForUpdate` on orders inside the method. If a SYNC variant is ever wanted, do it in the caller *before* the transfer (order → SU). |
| R8 | Message duplication with SBDEV-3747 (`replenBlockMessage` / `replenHoldsStockMessage`) | Operator | Reuse `ReplenishmentOrderMessages` builders, which take an entity. Either add projection overloads (number + sourcelocationname, available from the holders view? **No**: the view carries `id, state, number, operatorId, requestedamount, created`, not `sourcelocationname`), or `findById` the chosen holder *after* deciding to throw. A read-only load before a throw is harmless. |
| R9 | Multi-holder fix (§4) changes the move-path lock count per SU from 1 order to N | Move Unit Load latency | N = 0 or 1 on PRD today |
| R10 | `exported=false` on the SDR search | an unknown external consumer | 0 UI callers (both UIs swept, with a positive control) |

### What each refused path's operator sees

The keyed or plain `BusinessException` returns HTTP 422 through `RestExceptionHandler`:
- **Mobile:** `apiError.js` renders it.
- **Web:** it appears as a toast.

Reuse the 3747 texts:
- *"Replenishment order {n} is in progress for this stock (source {loc}); complete or cancel it
  before moving."* for a started holder;
- `replenHoldsStockMessage` for a not-started holder.

On batch paths (BOL, club), the message surfaces through the batch's own error reporting and names a
replen the shipping operator may not own. Consider prefixing it with the SU and UL label.

---

## 9. Post-analysis: R1 resolved + Nam's decisions (main session, 2026-10-13)

**R1: SBDEV-3622 IS live on WineCo PRD, so the "Adjust Reserved → move" workflow will not hit the new refusal.**

Evidence (wsl-wineco-prd):
- Content check: `git show origin/main:…/StockunitService.java` carries `findHoldersByStateLessThanAndStockunitIdOrderById` and the SBDEV-3622 javadoc. No "Hold SBDEV-3622 out" revert exists on main.
- Data check: `MANUAL_ADJUSTMENT`/`STOCK_RESERVED_CHANGED` rows carry an `ordernumber`, which is 3622's attributed cut. The weekly series is:
  - weeks of Jul 13 to Sep 28: 0 attributed;
  - week of Oct 5: 3 attributed;
  - week of Oct 12: 2 attributed.
- All 5 attributed cuts (Oct 8 to Oct 12) left their replen at state 800, with `modified` 0.35–1.4 ms after the cut row, so it was the same transaction. Each was followed by a drain of the stock unit within 1 h, and **by then no holder existed**.
- The last pre-3622 shape (unattributed cut, then a drain while the replen was still active) is REPL062966, 2026-10-06 19:49.
- Instrument note: a first cut→cancel query matched `type ILIKE '%CANCEL%'` and returned 0 everywhere. The weekly `REPLENISHMENT_CANCELLED` activitycode control (24–289/wk) exposed that the predicate was wrong. 3622's cancel is recorded as the attributed MANUAL_ADJUSTMENT row, not as REPLENISHMENT_CANCELLED.

**Consequence:** after 3622, R ≤ 0 together with an active holder arises only from reservation drift, never from the operator workflow. Fix 1 is a latent-invariant guard again.

**Decisions (Nam, 2026-10-13):**

| Topic | Decision |
|---|---|
| D1 refusal scope | **Narrow.** Refuse only on the re-parent and drain-to-zero branches. Split and partial merge stay allowed (keeps SBDEV-2492 manual row 5). |
| D2 pick confirm (#5) | **Opt in + WARN** naming the holder, plus an after-commit `requestForItem`. |
| D3 damage (#10, #12) | **Opt in + WARN.** `setLockDamaged` already triggers `requestForItem`; the direct Damaged route (#10) gets the same. |
| D4 scope | **Include** the multi-holder sync/maintenance fix (§4: lock all holders in ascending id order, refuse if any is started, otherwise re-point / reassign-or-cancel each) **and** `exported = false` on the SDR search `findByStateLessThanAndStockunitId`. |

Opt-in set:
- #15 replen finish: `ALLOW_ANY` + WARN on siblings, per the §3 recommendation;
- #5 pick confirm;
- #10 damage;
- #12 damage.

Every other caller uses REFUSE (the default overload).
