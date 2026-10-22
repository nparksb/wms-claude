---
title: "transferStockToUnitLoad displaces replen-held stock, and the move-path replen sync throws on a multi-holder stock unit"
ticket: "SBDEV-3755"
ticket_url: "https://app.clickup.com/t/868mgxpx8"
type: "bugfix"
priority: ""
status: archived
archived: 2026-10-15
archived_from_status: "on dev — #510 merged ebb52109, #513 merged 3734751f (2026-10-15); dev-tested 6/7 §8.4 scenarios"
tier: T3
repos: [wms2-api]
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-10-13"
updated: 2026-10-15
revision: "r3 (consensus): folds in the round-2 findings (architect APPROVE 0H/1M/6L, critic APPROVE with conditions 0H/1M/6L; §11 Round 2). r2 was revised against ralplan-r1-architect.md (APPROVE WITH CHANGES, 0H/5M/9L) and ralplan-r1-critic.md (ITERATE, 2H/6M/9L). Every finding is dispositioned in §11. r1 was grounded on SBDEV-3755-evidence/fix1-analysis.md, including the §9 decisions D1–D4."
db_verified: true
db_verified_note: "wsl-wineco-prd + wms2-wineco-dev, 2026-10-13 19:31Z (analysis §7 Q1–Q3, §9 R1). P-1 reachability was checked on all 4 PRD tenants (ticket comment 90110278941728). Positive controls are in every query."
base_commit: "wms2-api origin/fix/SBDEV-3755-replen-holder-multi-and-child-banner @ c6f0cbc0 (PR #510). As of 2026-10-13 it is NOT merged into origin/develop a4fd6490 (checked with git merge-base --is-ancestor)."
related:
  - "[[SBDEV-2033]]"
  - "[[SBDEV-2492]]"
  - "[[SBDEV-2074]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-3618]]"
  - "[[SBDEV-3622]]"
  - "[[SBDEV-3637]]"
  - "[[SBDEV-3747]]"
tags:
  - plan
---

# SBDEV-3755: transferStockToUnitLoad replen-hold guard (opt-in) + multi-holder move sync

> **Archived 2026-10-15** at Nam's request. Both PRs are merged and on dev (`develop-7ccb98e2`). Promotion to UAT/PRD is devops.
> **Findings dispositions** (archive gate, approved by Nam 2026-10-15):
> - **P-2:** on a ticket, [SBDEV-3787](https://app.clickup.com/t/868mhwphf).
> - **P-1:** dropped. 0 reachable on 4 PRD tenants (ticket comment 90110278941728). Re-check if FLA locations ever become replen sources.
> - **Self-merge landmine:** fixed in `f7fe0883`.
> - **#510 review M1:** fixed in `2481e101`.
> - **TOCTOU residual:** dropped as accepted; it heals at 300.
> - **ALLOW_ANY over a STARTED holder:** dropped as an accepted design residual (D2/D3; visible through `@state` in the `REPLEN_HELD_DISPLACED` WARN).
> - **Upfront-share mutant:** dropped as equivalent.
> - **Damage opt-in dev test:** not machine-knowable; owner Nam.
> - **200 + `errors` instead of 422:** dropped. That is the StockUnitController convention.
> - **No acceptance script** existed (T3, opted out; ArchUnit rails A13/A14/A20 instead).
> **Implementation worktrees removed 2026-10-15:** `wms2-api/SBDEV-3755` (`fix/SBDEV-3755-replen-holder-multi-and-child-banner`, #510) and `wms2-api/SBDEV-3755-fix1` (`fix/SBDEV-3755-transferstock-replen-held-opt-in`, #513).

**Ticket:** [SBDEV-3755](https://app.clickup.com/t/868mgxpx8). **Tier:** T3 (lock topology on the move choke point, plus data integrity). **Status:** consensus approved (ralplan round 2), pending Nam approval.
**Evidence:** `SBDEV-3755-evidence/fix1-analysis.md` (cited as *An §n*), `ralplan-r1-architect.md` (*Ar*), `ralplan-r1-critic.md` (*Cr*). Code is cited from the #510 branch.

---

## 0. Affected sites

**Census.**
- **Instrument 1:** `git grep -n "transferStockToUnitLoad("` on `src/main` finds 18 caller expressions, 2 declarations and the 8→9-arg self-delegation. The architect re-ran it and got the same 18.
- **Instrument 2:** the reference sweep `::transferStockToUnitLoad|transferStockToUnitLoad\b[^(]` finds comments only.
- **Blind spot:** runtime-generated callers (AOP or SDR). SBS is not a repository.
- **Indirect callers** go through `StockunitService.transferStock`: web Move Stock, mobile Move Stock and RTS `CancellationReversalService.completeReversal`. These inherit the policy of whichever arm they hit.

**Reach.** The guard fires only when a holder exists and reserved ≤ 0 on the source. While R > 0, the available-amount check already blocks every displacing branch (An §0.1).

| # | Site (file · enclosing method) | Code / ignoreLock | Reach | Policy |
|---|---|---|---|---|
| 1 | `BillofladingService` combineStock OFF (`transferStockToUnitLoad(stockUnit, parcel, stockUnit.getAmount(),`) | TRANSFER_BUILD_TRUCK / false | drift only (lane) | REFUSE |
| 2 | `BillofladingService` combineStock ON (`transferStockToUnitLoad(stockUnit, parcel, transfer,`) | same | drift only | REFUSE |
| 3 | `ClubLineOrderProcessor` runClubLine | PACKAGING_CLUB / false | drift only (lane) | REFUSE |
| 4 | `CustomerorderService` packageOrder | PACKAGING / true | tote; practically unreachable | REFUSE |
| 5 | `PickingorderBusinessService.confirmPick` | PICKING / true | **yes**: a full-SU pick where a co-holder has R ≤ 0 | **ALLOW_ANY + WARN + after-commit heal** (D2) |
| 6–9, 11 | `StockunitService.transferStock` MANUAL_SPLIT arms | MANUAL_SPLIT | yes (#11 is the ticket's re-parent) | REFUSE |
| 10 | `StockunitService.transferStock` → Damaged (`transferStockToUnitLoad(stockUnit, unitLoad, amountToTransfer, WmsConstants.CODE_DAMAGED, null, comment, true, true)`) | DAMAGED / true | yes | **ALLOW_ANY + WARN + after-commit heal** (D3) |
| 12 | `UnitloadService.moveStockToNewDamagedContainer` (only caller: `setLockDamaged`) | DAMAGED / false | yes | **ALLOW_ANY + WARN.** No new trigger: `setLockDamaged` already calls `replenishmentMaintenanceTrigger.requestForItem(stockUnit.getItemdataId())` after the helper's tx (D3) |
| 13 | `MobileMoveUnitloadService.transferStock` | TRANSFER / false | yes; this is the PRD hazard path. The SBDEV-3747 pre-check stays | REFUSE |
| 14 | `MobilePutAwayService.storeBoxOnLocation` flow-bin arm | PUT_AWAY / false | yes | REFUSE |
| 15 | `MobileReplenishService.finishReplenishmentOrderWithoutRefill` | REPLENISHMENT / false | always (its own order) | **ALLOW_ANY + WARN naming sibling holders** |
| 16 | `MobileTransferOrderService` (reserved == 0 arm) | MANUAL_SPLIT / false | yes (exactly the R = 0 state) | REFUSE |
| 17, 18 | `MobileTransferOrderService` (available-amount arms) | MANUAL_SPLIT / false | split only, so never | REFUSE (inert) |

**Fix B sites.**
- `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` and `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit` are the only `src/main` callers of `findIdByStateLessThanAndStockunitId` (git grep on #510).
- `syncForMovedStockUnit` is called only from `UnitloadBusinessService.processTransfer` (`replenishmentOrderSourceSyncService.syncForMovedStockUnit(movedStockUnit, destinationLocation); // SBDEV-2492`), git grep. That call runs for BLOCK_REALIGN codes only.

**Fix C site.**
- `ReplenishorderRepository.findByStateLessThanAndStockunitId` is an SDR search.
- It has 0 src/main callers.
- It has 0 UI callers in both UIs, checked with a positive control (An §4).

---

## 1. Problem

1. **Displacement.** `transferStockToUnitLoad` has no replen awareness.
   - **Re-parent:** `if (destinationStockUnit == null) { sourceStockunit.setUnitloadId(destinationUnitload.getId());` moves the held SU, and the replen's `requestedlocationId` and `sourcelocationname` go stale.
   - **Drain-to-zero:** `sendStockUnitToNirvana(sourceStockunit, …)` leaves the replen pointing at a 0-amount SU in Nirwana.
   - In both cases only the cron heals, and only at PROCESSABLE (An §1).
2. **Multi-holder 500.** Since SBDEV-3622 one SU can carry several active replens. The move-path probe `Optional<Long> findIdByStateLessThanAndStockunitId` throws `IncorrectResultSizeDataAccessException` when there are two or more holders, and the whole Move Unit Load rolls back. Its own comment says *"behaviour preserved, not improved"*.
3. **Same 500 over HTTP:** `/v3/replenishorder/search/findByStateLessThanAndStockunitId`.

**DB evidence (An §7, §9).**

- **History (WineCo PRD, 180 days):** 110 drains-to-0 of replen-held SUs (104 `TRANSFER`, 6 `MANUAL_SPLIT`). In 108 of them a manual "Adjust Reserved" release came just before. The cron cancelled every one within 50 s. Positive control: 249 drains by the replen's own finish.
- **Since SBDEV-3622 reached PRD:** 5 of 5 attributed cuts cancelled the holder in the same transaction. No later drain found a holder (R1 resolved).
- **Snapshot:**

  | Metric | Value |
  |---|---|
  | Active replens | 572, all at state 300 |
  | Stale | 0 |
  | R ≤ 0 | 0 |
  | SUs with ≥ 2 active holders | 0 (control: 13,862 multi-holder SUs across all states) |

- **Dev:** 0 foreign displacements.

Every defect here is latent. This plan adds an invariant guard.

---

## 2. Root cause

- **Fix A.** The displacing branches run without consulting holders. The available guard `getAmount().subtract(getReservedamount()).compareTo(amount) < 0` checks a number, not the binding.
- **Fix B.** SBDEV-3244 F5 narrowed the probe to an id but kept single-row semantics. SBDEV-3622 then made multi-holder legal without widening the two move-path consumers (PR #510 review M1 accepted this as a residual).
- **Fix C.** The search was kept exported "*because removing any is an API contract change*", even though no consumer was ever found.

---

## 4. Architecture

```
caller (tx REQUIRED)
 └─ StockunitBusinessService.transferStockToUnitLoad(…, ReplenHoldPolicy) → TransferOutcome   [Fix A]
      PO lock (BLOCK_REALIGN) → src SU FOR UPDATE → available guard → src UL → src Loc → dst UL → dst SU → dst Loc
      → FLA resolve → ★ displacement guard (projection read, no lock) → createStockUnit / re-parent / merge
UnitloadBusinessService.processTransfer (BLOCK_REALIGN codes; the UL is already locked and saved), per moved SU
 └─ ReplenishmentOrderSourceSyncService.syncForMovedStockUnit                                   [Fix B]
      isReplenishableDestination(dest)?   ← checked FIRST, as today; exactly one service runs the prefix
      ├─ yes: [prefix] projection → refuse if any projected state ≥ STARTED (no lock)
      │        → lock holders asc → re-check → re-point each
      └─ no:  ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit
               [prefix, as above] → lock SU once → per holder: shareOf → redirectSource → cancel on NO_CANDIDATE
```

**Lock order. What holds:**
- **Per stock unit,** every replen locker takes orders ascending by id, then the SU.
  - The 3622 cut: `findHoldersBy…OrderById`, then the SU.
  - The cron: `ORDER BY r.id`, one transaction per item, order → SU.
  - Fix B: holders ascending, then the SU.
- **Fix A takes no order lock.** It runs after the SU lock, so locking an order there would invert the order (An §8 R7). This is fenced by ArchUnit (AC A14).

**Lock order. What does not hold (all pre-existing, none introduced here):**
- **UL vs order.** The Move Unit Load takes the **UL** (`unitloadRepository.findByLabelidForUpdate(...)` at entry; `processTransfer` saves the UL before `syncForMovedStockUnit`) before any order. The replen finish takes order → SU → UL (`replenishorderRepository.findByIdForUpdate(request.getOrderId())`, then `transferStockToUnitLoad` locks the source UL). That is a UL↔order ABBA, already present at N = 1. PostgreSQL detects it and returns 40P01. Fix B narrows it for STARTED holders, which are refused before any lock is taken.
- **Across stock units within one move:** SU S1 is locked, then S2's orders are locked. That is an SU → order edge across stock units (`findByUnitloadId` has no ORDER BY; SBDEV-3637 P-1).

---

## 5. Fix design

### Fix A: narrow displacement guard with an opt-in policy

**Before:**
- No holder check.
- The 9-arg overload carries the body, including `fixLocationAssignment = fixLocationAssignmentOpt.isPresent() ? fixLocationAssignmentOpt.get() : null;`, which is frozen in `archunit_store/5fb3fee0…:38`.

**After:**

1. **Types and overloads.**
   - `enum ReplenHoldPolicy { REFUSE, ALLOW_ANY }`.
   - `record TransferOutcome(Stockunit stock, List<ReplenishorderHolderView> displacedHolders)`.
   - New overload: `TransferOutcome transferStockToUnitLoad(…9 args…, ReplenHoldPolicy policy)`. It carries the body, with the same `@Transactional` as today.
   - The 8-arg and 9-arg overloads keep their `Stockunit` return. They delegate with `REFUSE` and return `.stock()`.
   - The record has a compact constructor: `Objects.requireNonNull(stock); displacedHolders = List.copyOf(displacedHolders);`. That makes "never null" a property of the type.
   - Production code never null-checks a `TransferOutcome`. A null outcome means an unstubbed test, and the test should fail.
2. **Predicate.**
   - **Placement:** after FLA resolution and before the `createStockUnit` placeholder block. No write in SBS precedes it.
   - **Expression:** `displacing = fixLocationAssignment == null && sourceStockunit.getAmount().compareTo(amount) <= 0`.
   - **Why it matches the two displacing branches:** a placeholder is created only when `A > amount || fla != null`, so when R ≥ 0, `displacing` holds exactly for re-parent and drain-to-zero. Ar claim 1 verified this, including a caller-preloaded FLA (BOL `transferLaneFla`, club `stagingLaneFixAssignment`).
   - **Javadoc names two accepted edges:**
     - *FLA drain-to-zero is excluded on purpose.* The SU stays on its location, and `isSourceUsable`'s `amount <= 0` heals it at 300.
     - *R < 0 over-approximates.* A merge could leave the source negative. That state is already corrupt, so a refusal is acceptable.
3. **Holder read.** If `displacing`, read `holders = replenishorderRepository.findHoldersByStateLessThanAndStockunitIdOrderById(FINISHED, srcId)`. If the list is empty, proceed.
4. **REFUSE.**
   - **Candidate order:** first the holders with `ReplenishmentOrderMessages.blocksMove(h.getState())`, then the rest, keeping id order within each group. This is the `existsForStockUnit` rule.
   - **Load:** `findById` each candidate in turn. The first present one is the chosen holder.
   - **Vanished-row fallback:** a candidate whose row is gone is treated as no holder, as `existsForStockUnit` does at c6f0cbc0. Move on to the next candidate. If every candidate is gone, proceed as if there were no holders. Never call `.get()`.
   - **Log:** `LOG.warn("REPLEN_HELD_REFUSED su={} ul={} code={} holder={}@{}", …)`.
   - **Throw:** `BusinessException("Stock unit " + srcId + " on unit load " + srcUl.getLabelid() + ": " + (blocksMove ? replenBlockMessage(o) : replenHoldsStockMessage(o)))`.
   - **Message on batch paths (#1–#4):** the `replenHoldsStockMessage` tail (*"…before moving its stock onto a flow bin or another unit load"*) is still literally true, since these paths move stock into another UL. The SU/UL prefix tells the shipping operator which stock it is. Accepted.
5. **ALLOW_ANY.**
   - `displaced = holders.filter(h -> !Objects.equals(h.getNumber(), orderNumber))`. This is null-safe: #10 and #12 pass `orderNumber = null`. #15's own order is excluded.
   - If `displaced` is non-empty, write one `LOG.warn("REPLEN_HELD_DISPLACED su={} ul={} code={} holders={}", …)`. Holders are rendered as `NUMBER@state`, e.g. `REPL062966@500`, so support can see when an in-progress replen has been stranded.
   - Return `displaced` in `TransferOutcome`.
6. **Freeze rewrite.** Rewrite the frozen `Optional.get()` as `.orElse(null)`, and delete store line 38. ArchUnit prunes a resolved store line on its own; deleting it by hand just commits that deliberately.
7. **Dependencies.**
   - Inject `ReplenishorderRepository` into SBS through the constructor.
   - Do **not** inject `ReplenishorderService`: it has `private final StockunitBusinessService` (cycle).
   - Do **not** inject the trigger: trigger → `ReplenishmentOrderMaintenanceService` → `private final StockunitBusinessService` (cycle).
   - So healing is done by the caller, driven by `TransferOutcome`. Ar claim 3 verified that `PickingorderBusinessService` → trigger closes no cycle.
8. **Heal helper (Ar L-9).**
   - Add `ReplenishmentMaintenanceTrigger.requestIfDisplaced(TransferOutcome outcome, Long itemdataId)`. It calls `requestForItem(itemdataId)` only when `displacedHolders` is non-empty. One rule, one test (AC A19).
   - The trigger defers the request to after commit and de-duplicates per transaction.
   - Side effect: `recalculateForItem` recalculates **every** PROCESSABLE order of the item, so a partially-cut order may grow back (3622 D-H1). The cron would do the same within about a minute.
9. **Opt-in callers.**

   | Caller | Policy | Heal |
   |---|---|---|
   | #15 replen finish | `ALLOW_ANY` | none: the order goes FINISHED in the same tx, and siblings self-heal at 300 |
   | #5 `confirmPick` | `ALLOW_ANY` | `requestIfDisplaced`. New constructor dependency on the trigger; the test uses `@InjectMocks`, and there are no `new PickingorderBusinessService(` call sites |
   | #10 Damaged arm | `ALLOW_ANY` | `requestIfDisplaced`. **Amend the SBDEV-2033 comment** in `transferStock` (*"Intentionally NOT triggering replenishment maintenance here… undoing a reservation the operator just released"*) to add: *"except when a damage move displaced an active holder (SBDEV-3755 D3), after commit. Since SBDEV-3622 a release to 0 cancels the holder, so this does not re-reserve a released hold."* |
   | #12 damaged container | `ALLOW_ANY` | none. `UnitloadService` must not gain the trigger. `setLockDamaged` is not `@Transactional`, so a second request would defer to the helper's transaction and run a second recalc (Ar claim 6) |

10. **Residuals, recorded in the javadoc.**
    - **TOCTOU.** `ReplenishGeneratorService.calculateOrder` saves the order *before* `changeReservedAmount` locks the SU. A replen created concurrently is therefore invisible to the guard. It is born with R > 0, so the next move is guarded, but its `requestedlocationId` is stale. That heals at 300.
    - **ALLOW_ANY over a STARTED holder** strands the holder. The moved SU is then at `PICKED_FOR_GOODSOUT` or `QUALITY_FAULT`, so that holder's own finish is refused by the lock-state guard, and the recalc does not heal 400 or 500. This is visible through the `@state` field in the WARN.

**Why not the alternatives:**

| Alternative | Why rejected |
|---|---|
| Wide refusal | Breaks every replen-finish IT and SBDEV-2492 manual row 5 (D1) |
| New boolean on the existing signatures | 20 call-site edits plus about 147 test edits (An §3 A) |
| ThreadLocal | Invisible at the call site, leaks onto pooled threads (An §3 E) |
| `ALLOW_ORDER(id)` | Refuses a finish because of a stale sibling (An §3) |
| Locking holders inside SBS | Inverts the lock order (R7) |
| Unconditional trigger | One recalc per pick confirm |
| Guard at the callers (Ar §3 steelman) | Pre-lock, so not TOCTOU-safe, and opt-out by default. Only inside the primitive can the predicate key on the locked branch variables |

### Fix B: multi-holder move sync (both services, same prefix)

**Before:** `Long probeId = replenishorderRepository.findIdByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, stockUnit.getId()).orElse(null);`, then a single `findByIdForUpdate`, then the action.

**After:**
1. Read `holders = findHoldersByStateLessThanAndStockunitIdOrderById(FINISHED, suId)`. This is a projection, so no entity is loaded before its lock and the SBDEV-3244 F5 first-touch property is kept. If the list is empty, return.
2. **Pre-check before any lock (Ar M-1).**
   - If any **projected** state satisfies `blocksMove(Integer)`, take the first such id and `findById` it. Throw `replenBlockMessage(o)`; the throw ends the transaction, so no lock follows the plain read.
   - If that row is gone, try the next blocking id. If every blocking row is gone, fall through to step 3.
   - This removes the wait on a STARTED holder that a finish may be holding, which is the UL↔order ABBA in §4.
   - **Stale-projection refusal is intended (Ar R2-L4).** Under READ COMMITTED, the holder may have been reset, finished or redirected between the projection and `findById`. The refusal still stands, and the operator's retry succeeds. Javadoc: *"refusal is on the projected state by design; a present row always throws; do not fall through after a present `findById`"*. Falling through would leave a **managed** order that step 3 then locks, which is the version-checked upgrade that SBDEV-3244 F5 and `LockReadRail` exist to stop.
3. For each holder id, **in ascending order**, call `findByIdForUpdate(id)`. Keep the order only if `state < FINISHED` **and** `stockunitId.equals(suId)`; otherwise the cron finished or redirected it after the probe. The kept orders form the **locked set**.
4. **Re-check under lock.** If any locked order `blocksMove(order)`, throw `replenBlockMessage` for the first such order by id. Nothing is saved, and the whole move rolls back.
5. **Replenishable destination.** Resolve the rack once, then re-point every locked order (`requestedlocationId`, `requestedrackId`, `sourcelocationname`). Do not change `stockunitId` or the amounts (I-1).
6. **Non-replenishable destination.**
   - After all orders are locked, take `LockReads.forUpdate(…Stockunit…)` **once**.
   - Then, for each locked order in ascending order: `share = shareOf(order, lockedSource)` → `redirectSource(order, lockedSource, share, false)` → on `NO_CANDIDATE`, `cancelOrder`.
   - **Why the share must be computed per order:**
     - A cancel does not consume the loop's `share`: `cancelOrder` recomputes it through `releaseHeld(order, source, shareOf(order, source), …)`.
     - A **redirect** does consume it, because it releases `currentShare` on the source.
     - `shareOf` is live: `locked.getReservedamount()` reads the managed entity, and `LockReads.forUpdate` refreshes and returns the same instance. `sumRequestedAmountOfOtherOpenOrdersOnStockunit` is JPQL, so it auto-flushes first.
     - The test that pins this is **AC B7**, which has two redirects and distinct amounts. AC B6 (cancel only) cannot catch a snapshot.
7. **Drift.** Act on the locked set.
   - A holder that disappeared after the probe is skipped.
   - A holder that appeared after the probe is not seen. This is the same creation-before-lock residual as in Fix A, and it heals at 300 because its `requestedlocationId` is the location before the move.
8. **Delete `findIdByStateLessThanAndStockunitId`.**
   - It has 0 src/main callers after this change, and its own comment says it throws on multiple holders.
   - Re-target the test references listed in §6.
   - Do **not** edit `V2.1.04__…indexes.sql`. It is an applied migration, and the reference there is only a comment.

**Fixture traps (Ar M-3, Cr M5):**
- Two active holders of one SU need **distinct `destination_id`**. Otherwise `idx_replenishorder_active_item_dest (itemdata_id, destination_id) WHERE state < 700` raises 23505. Never "fix" that by putting a holder at 700.
- Fix B ITs must enter through a BLOCK_REALIGN whole-UL move: `UnitloadBusinessService.transferUnitLoadToLocation(ul, dest, false, CODE_MANUAL_TRANSFER, …)`. Entering through the mobile stock arm would hit the SBDEV-3747 refusal first.

### Fix C: un-export the SDR search

- Add `exported = false` to its `@RestResource`.
- Correct the repository comment that calls the three entity finders "*SDR-exported searches… removing any is an API contract change*".
- **The finder itself stays** (D4 scoped this to un-exporting). It also throws on multiple holders and loads an entity, so:
  - add a javadoc warning: *"throws on ≥2 holders; do not use in src/main"*;
  - add an ArchUnit rule that `src/main` has no caller (AC B10).
- `SdrSurfaceInventoryContextTest` asserts only `resources > 20`, so no counts change there.

---

## 6. File changes and measured test churn

**Production:**
- New: `ReplenHoldPolicy`, `TransferOutcome`.
- `StockunitBusinessService`
- `ReplenishmentMaintenanceTrigger` (`requestIfDisplaced`)
- `PickingorderBusinessService`
- `StockunitService` (#10 and the SBDEV-2033 comment)
- `UnitloadService`
- `MobileReplenishService`
- The two Fix B services
- `ReplenishorderRepository`
- `archunit_store/5fb3fee0…` (delete line 38)

**Test churn.** Found with `git grep` over `src/test` on #510 @ c6f0cbc0. Blind spot: helpers that wrap the call under another name; `verifyNoStockMoved` was found by hand.

| Change | Sites |
|---|---|
| **H1: every `never()` on `transferStockToUnitLoad` → `TransferVerifications.verifyNoTransfer(sbs)`.** The helper asserts `never()` on the 8-, 9- and 10-arg overloads. Every reference parameter uses bare `any()` or `nullable(...)`, never `any(Class)`: `any(Foo.class)` excludes null and would fail `NeverMatcherNullBlindnessArchTest` (Ar R2-L1). `anyBoolean()` is used only for the two primitives. The overloads have different arities, so bare `any()` is unambiguous. **Helper self-test:** call each overload on a mock with null in every reference slot, then assert the helper throws `NeverWantedButInvoked`. All sites are migrated, so a REFUSE caller that is opted in later cannot silently disarm its tests | 19 sites: `BillofladingServiceUnitTest:3366,3432` · `ClubLineOrderProcessorUnitTest:376` · `StockunitServiceParcelSourceRefusalUnitTest:417,627` · `StockunitServiceToteContainerRelocationUnitTest:464` · `StockunitServiceTransferStockDestinationTest:214` (`verifyNoStockMoved`) · `StockunitServiceUnitTest:2993` · `UnitloadServiceUnitTest:2387` · `MobileMoveUnitloadServiceUnitTest:2008,2545` · `MobilePutAwayServiceUnitTest:1758,2493,2519` · `MobileReplenishServiceUnitTest:3453,3492,3954,3971` · `MobileTransferOrderServiceUnitTest:1027` |
| **Stubs and verifies on an opt-in path → the policy overload,** done in §7.2 step 5 together with the caller switch, not in the scaffold. Default stub: `thenReturn(new TransferOutcome(stock, List.of()))`. **Convert `lenient()` 8/9-arg stubs by hand** (Ar R2-L5). Grep the four caller test classes for `lenient().when(stockunitBusinessService.transferStockToUnitLoad(`. STRICT_STUBS does not report an orphaned lenient stub, and `catch (Exception ignored)` blocks (e.g. `PickingorderBusinessServiceUnitTest` ~`:500`) can swallow the resulting NPE | `PickingorderBusinessServiceUnitTest` (12 stubs, e.g. `:493,1184,1278,1378,1449,1520`) · `MobileReplenishServiceUnitTest` (stubs and verifies incl. `doThrow` `:4257,4275`) · `UnitloadServiceUnitTest:1967,2369` · `StockunitServiceUnitTest:2884,2924,2934,2964` (Damaged arm) · `StockunitServiceParcelSourceRefusalUnitTest:343` (add a policy-overload stub next to the 8-arg one), `:849-861,930` (Damaged pins) · `StockunitServiceAuditCommentClampUnitTest:494` · **`StockunitDamagedRollbackIntegrationTest:181`**: re-target the `inject-D6` throw stub to the policy overload. The assertion stays the same, and the test leaves the "unchanged" control list |
| `@Mock ReplenishorderRepository` (default: empty list, so nothing is refused) | `StockunitBusinessServiceUnitTest`, `…DamagedFullMoveUnitTest`, `…FullMoveInvariantUnitTest`. `MoveSourceLockComparisonRailTest` is a text scan and needs no change (Cr) |
| `findIdByStateLessThanAndStockunitId` → restub with the list finder | `ReplenishmentOrderSourceSyncServiceTest` (9, `:100…:275`) · `…SourceSyncServiceBranchTest:104,121,136` · `ReplenishmentOrderMaintenanceServiceReassignTest` (8, `:143…:367`) · `ReplenishmentOrderMaintenanceServiceUnitTest:2233` · `ReplenishmentIdProjectionContractUnitTest:93,158` · `AttributedReservedCutContractUnitTest:176` |
| Rails to re-measure, not guess | `NeverMatcherNullBlindnessArchTest` per-class counts (they move with H1). `OptionalSafetyArchTest` store. **`LockReadRail`** runs in every Spring test context: the new per-holder `findByIdForUpdate` loop must not report a violation (instrument) |

**Driver 3, corrected:** the 14 REFUSE **production** sites stay untouched. The test churn above is the measured cost; there are no zero-touch test classes.

---

## 7. Implementation steps

### 7.1 Prerequisites

| # | Prerequisite | Value / action |
|---|---|---|
| 1 | Database state | none; no Flyway |
| 2 | Flags / sysprops | none |
| 3 | Config / env | none |
| 4 | Deploy order | **PR #510 merges into `develop` first.** Cut `fix/SBDEV-3755-transferstock-replen-held-opt-in` off the #510 branch, or off fresh `origin/develop` once #510 has merged. Stacked-PR rule: merge the base first, then rebase onto `develop` and retarget the PR to `develop`. Never merge into the #510 branch after #510 has merged |
| 5 | Data migration | none (0 stale and 0 multi-holder rows on PRD) |
| 6 | External systems | none; the error shape is the existing 422 `BusinessException` |
| 7 | Access | none |
| 8 | Monitoring | WARN tokens `REPLEN_HELD_REFUSED` and `REPLEN_HELD_DISPLACED` (log search only) |
| 9 | Worktree | `.claude/worktrees/wms2-api/SBDEV-3755-…`. Run ListAgents for peer sessions on the #510 worktree first |

### 7.2 Steps (also the commit order)

**Applies to every step below:**
- **RED** rows are written first and fail on an assertion.
- **CTRL** rows are written green, then shown red under their named mutant.
- **RAIL** and **PROBE** rows are added with their non-vacuity controls (Ar R2-L6, Cr N7).

0. **Baseline (Cr N5).** Do **not** reuse the #510 ticket figures (unit 8263, IT 842). That run was on 08132098, and c6f0cbc0 adds one test.
   - Re-measure `mvn clean verify -Pci` on the actual base commit: the #510 head, or `origin/develop` once #510 has merged.
   - Record the commit SHA, the per-lane run/fail/skip counts and the **names of any failing tests** in this plan's *Implementation Status* section.
1. **Scaffold, with no behaviour change (Cr M2).**
   - Add `ReplenHoldPolicy` and `TransferOutcome` (with its compact constructor).
   - Add the 10-arg overload, carrying the body **without** the guard; the 8/9-arg overloads delegate to it.
   - Add `.orElse(null)` and a no-op `requestIfDisplaced`.
   - Callers stay unchanged, and so do caller test stubs (those move in step 5).
   - Add `verifyNoTransfer` plus its self-test, and migrate the 19 `never()` sites.
   - Run the full suite. Its **failing-test set** must equal step 0's.

   From here on, every RED row fails on an assertion, not on a compile error.
2. **Fix C:** C1 (RED) first, then the change.
3. **Fix B:**
   - Write B1–B9 (RED) and B8 (PROBE, with its control), then add B10 (RAIL).
   - Change both services.
   - Delete the finder and re-target the tests in §6.
4. **Fix A core:**
   - Write A1, A2 and A6–A11 (RED), then the guard.
   - Then A3–A5 and A12 (CTRL), each shown red under its mutant.
   - Then A13 and A14 (RAIL).
5. **Opt-ins:**
   - Write A15–A19 (RED), then switch the four callers.
   - In the same commit: migrate the opt-in-path stubs and verifies in §6 (lenient ones by hand), the helper body, and the SBDEV-2033 comment.
   - A20 (CTRL / RAIL) comes last.
6. **E2E:** E1a (RED), then E1b–E1d (CTRL).
7. **Floor:**
   1. Mutation-check every new assertion (§8.2).
   2. Run scoped PIT (§8.3).
   3. Run `mvn clean verify -Pci` on the work and compare its **set of failing tests** against step 0, not the totals; totals move by design as tests are added. Always use `clean`: this change deletes a finder, and a stale test class would otherwise still run. Never use `mvn test` alone, because it cannot see the IT lane.
   4. Run a `code-reviewer` lane that writes `SBDEV-3755-evidence/fix1-review-code.md`.
   5. Fix every finding, Low included.

---

## 8. Testing

### 8.1 Acceptance criteria (each one is a single JUnit test)

**How to read this list.**
- **Base:** `RED` means the test fails with an assertion against the post-scaffold base. `CTRL` means it is green on base and is killed by the named mutant. `RAIL` is a structural rule. `PROBE` is a non-regression probe.
- **Mutant:** every row names one. For `RED` rows the base is the first mutant; the named mutant is the attributable one.
- **Naming:** test names and `@DisplayName`s avoid "exactly N" and "all N" (`TestIdentifierCountArchTest`).
- **Unit vs IT:** unit rows run in `StockunitBusinessServiceReplenHoldGuardUnitTest` unless another class is named. Rows named `…IT` are PostgreSQL / Testcontainers.

**Fix A: guard**

| # | Test | Base | Mutant that must redden it |
|---|---|---|---|
| A1 | Re-parent (no same-item dst SU, amount = A, no FLA), one 300 holder, 8-arg call → `BusinessException` containing the holder number, the src SU id and the src UL label. `stockunitRepository.save` is never called, `clientRepository.findById` is never called (the first statement of the placeholder block), and `stockrecordService` has no interactions | RED | guard deleted; `<=` → `<` |
| A2 | Drain-to-zero (existing same-item dst SU, amount = A, no FLA) plus a holder → refused, and the dst SU amount is unchanged | RED | predicate narrowed to `destinationStockUnit == null` |
| A3 | Split (amount < A) with a holder → succeeds, and `findHolders…` is never called | CTRL | holder read moved above the predicate (always queries) |
| A4 | FLA on the source, amount = A, holder → succeeds, and `findHolders…` is never called | CTRL | `fla == null` dropped |
| A5 | Displacing, no holders → succeeds with today's writes | CTRL | refuses whenever `displacing`, even with no holders |
| A6 | REFUSE: InOrder `stockunitRepository.findByIdForUpdate` → `findHolders…` → `findById`. In the [5@300, 9@300] fixture assert `verify(replenishorderRepository, times(1)).findById(any())` (Cr N2: a per-id verify cannot see extra loads). ALLOW_ANY: `findById` is never called | RED | `findById` called on every holder before deciding |
| A7 | Holder choice: [5@300, 9@500] → the "is in progress" text naming 9. [5@300, 9@300] → the "holds this stock" text naming 5 | RED | always `holders.get(0)` |
| A8 | Vanished row: `findById(9)` is empty → refusal names 5. Both rows empty → the transfer proceeds | RED | `.orElseThrow(EntityNotFoundException)` |
| A9 | The 8-arg and 9-arg overloads both refuse in the A1 fixture | RED | 8-arg delegates with `ALLOW_ANY` |
| A10 | ALLOW_ANY WARN, captured with a Logback `ListAppender` on the SBS logger (precedent: `StockUnitControllerUnitTest`). Holders {REPL1@300, REPL2@500} with `orderNumber = "REPL1"` → one WARN containing `REPLEN_HELD_DISPLACED` and `REPL2@500` but not `REPL1`; `displacedHolders` ids = [2]. With `orderNumber = null` → both holders named, no NPE | RED | `orderNumber` exclusion dropped; `h.getNumber().equals(orderNumber)` (NPE on null) |
| A11 | A REFUSE logs `REPLEN_HELD_REFUSED` with the holder number before throwing (`ListAppender`) | RED | log line deleted |
| A12 | `OptionalSafetyArchTest` is green with store line 38 deleted | CTRL | body moved but `.get()` kept |
| A13 | `ReplenHoldPolicyCallerArchTest` (`ImportOption.DoNotIncludeTests`, `getAccessesToSelf()` on the 10-arg signature). Outside SBS, the accesses come only from {`MobileReplenishService.finishReplenishmentOrderWithoutRefill`, `PickingorderBusinessService.confirmPick`, `StockunitService.transferStock`, `UnitloadService.moveStockToNewDamagedContainer`}, with one access per method. Non-vacuity: at least 4 found. *Blind spots:* which arm of `transferStock` holds the access (A17 covers it); transitive callers of the helper or of `setLockDamaged` | RAIL (red after scaffold: 0 found) | a 5th caller (e.g. #13) switched to the overload |
| A14 | `StockunitBusinessServiceReplenLockFenceArchTest`: SBS's accesses to `ReplenishorderRepository` are **direct calls only** (no method references: ArchUnit reports these separately), and the calls are a subset of {`findHoldersByStateLessThanAndStockunitIdOrderById`, `findById`}. Banning method references closes `LockReads.forUpdate(entityManager, Replenishorder.class, id, replenishorderRepository::findById)`, which locks through `entityManager` while touching only `findById` (Cr N3). *Remaining blind spot:* a native lock or `entityManager.find(…, PESSIMISTIC_WRITE)` issued directly | RAIL | `LockReads.forUpdate(…, replenishorderRepository::findById)` added in SBS |

**Fix A: opt-ins and heal**

| # | Test | Base | Mutant |
|---|---|---|---|
| A15 | `MobileReplenishServiceUnitTest`: the finish calls the policy overload with `ALLOW_ANY` and `orderNumber = replenishOrder.getNumber()` | RED | #15 left on the 8-arg overload |
| A16 | `PickingorderBusinessServiceUnitTest`: `confirmPick` → `ALLOW_ANY`, then `trigger.requestIfDisplaced(outcome, itemdataId)` | RED | #5 left at REFUSE; helper call dropped |
| A17 | `StockunitServiceUnitTest`: the Damaged arm (#10) → `ALLOW_ANY` plus `requestIfDisplaced`; the MANUAL_SPLIT arms still verify the 8-arg overload | RED | #10 left at REFUSE; #11 switched to `ALLOW_ANY` |
| A18 | `UnitloadServiceUnitTest`: the damaged-container helper → `ALLOW_ANY`. `UnitloadService` has no `ReplenishmentMaintenanceTrigger` constructor parameter (reflection). `setLockDamaged` → `requestForItem` `times(1)` | RED (first assertion) / RAIL | #12 left at REFUSE; trigger injected into `UnitloadService` |
| A19 | `ReplenishmentMaintenanceTriggerUnitTest`: `requestIfDisplaced` with a non-empty list → one request; with an empty list → none | RED (scaffold no-op) | unconditional request |
| A20 | H1 fence. **Behavioural pin:** `MobileReplenishServiceUnitTest.finish_rejectsDestinationScopedToAnotherClient` goes red under the mutant on the right. **Rail** `NoBareTransferNeverRailTest`, which reuses `NeverMatcherNullBlindnessArchTest`'s comment stripper, paren lexer and `NEVER_VERIFY` pattern where they fit (Cr N1, Ar R2-L2). Over comment-stripped `src/test` text, it matches whitespace- and newline-tolerant shapes: `never\s*\(\s*\)` (incl. `Mockito.never()` and `never ()`), `never().description(...)`, `times\s*\(\s*0\s*\)`, then `)\s*\.\s*transferStockToUnitLoad\s*\(`, including the two-line `verify(sbs, never())` / `.transferStockToUnitLoad(` form. Assertions: no match outside `TransferVerifications`. **Positive control:** at least 3 matches inside `TransferVerifications`. **Planted-offender self-test:** one literal per shape (two-line, `never ()`, `times(0)`, `.description(...)`) must be flagged. **Floor:** at least 19 `verifyNoTransfer(` call sites in `src/test` | CTRL / RAIL | at #15, transfer moved before the client check; a bare `never()` re-added in any shape; the 10-arg line dropped from `verifyNoTransfer`; a `verifyNoTransfer` site replaced by `verifyNoInteractions` (floor) |

**Fix B**

| # | Test | Base | Mutant |
|---|---|---|---|
| B1 | `ReplenishmentOrderSourceSyncServiceTest`: replenishable destination, holders [5, 9] @300 → InOrder `findByIdForUpdate(5)`, `(9)`. Both get location id, rack id and name re-pointed; `stockunitId`, `requestedamount` and `reservedamount` are unchanged. `findById` and `findByStateLessThanAndStockunitId` are never called | RED | descending order; only the first holder re-pointed |
| B2 | Projected holder 9 @500 → `replenBlockMessage` naming 9, and `findByIdForUpdate` is never called | RED | pre-check removed (the under-lock check still throws, but after a lock) |
| B3 | Under lock, 9 is now 800 **or** has another `stockunitId` → 9 skipped, 5 re-pointed. Under lock 9 is @500 while projected @300 → throws, and **holder 5's `requestedlocationId` still holds the old value** (fields asserted, not save counts) | RED | re-check skipped; re-point done before the remaining checks |
| B4 | `ReplenishmentOrderMaintenanceServiceReassignTest`: non-replenishable destination, holders [5, 9] → InOrder lock 5, lock 9, SU lock `times(1)`, then redirect/cancel 5 then 9 | RED | SU locked before the orders, or once per order |
| B5 | `ReplenishMultiHolderMoveIT.locationMove_twoProcessableHolders_repointsBoth`, through `transferUnitLoadToLocation(…, CODE_MANUAL_TRANSFER, …)` with distinct `destination_id` → no exception, and both orders point at the new location | RED: on base, `IncorrectResultSizeDataAccessException` in the cause chain (asserted by type in the gate run) | base |
| B6 | `…IT.laneMove_twoHolders_noCandidate_cancelsBoth`. Requests 3 and 5; no other stock of the item anywhere → both orders at 800. SU `reservedamount` = pre − 8, never negative. Release rows: −3 attributed to REPL-5 and −5 to REPL-9 | RED | base |
| B7 | `…IT.laneMove_twoHolders_bothRedirected_releaseOwnShares` (Cr H2, Ar R2-L3). Requests 3 and 5. The moved SU S is seeded with `amount == reservedamount` (= 8), so S can never be a redirect candidate, whatever the flush timing. There is one candidate SU C with free ≥ 8, on a `useforreplenish` area with no lane flags, clear of `MANUAL_CUT_COOLDOWN_EXCLUSION`. Assert: **both orders' `stockunitId == C`**; source `reservedamount` = pre − 8; C's increases by 8; release rows −3 / −5 per order. The equivalent "every share computed upfront" mutant (Ar R2.2(d)) survives by construction; record it in `fix1-review-code.md` so that it is not "repaired" | RED | `shareOf` snapshotted once, outside the loop (REPL-9 would release 3) |
| B8 | `…IT.moveAndAttributedCut_sameTwoHolderSu_noDeadlock`. Deterministic latch design (Ar R2-M1), 3 connections: (1) thread A opens a `TransactionTemplate`, takes `replenishorderRepository.findByIdForUpdate(5)` (the cut's first lock) and parks on a latch. (2) Thread B runs the move and records `pg_backend_pid()` inside its transaction. (3) The test polls `pg_stat_activity` for that pid until `wait_event_type = 'Lock'`, and fails if that does not happen within 10 s (positive control). (4) Only then is A released; it runs the real `adjustReservedAmount` **in the same transaction**. Re-locking 5 is a no-op; A then locks 9 and the SU. Pass: both transactions end, and neither ends in SQLSTATE 40P01. Because contention is forced rather than raced, B8 is **not** tagged `timing-sensitive` and **runs under `-Pci`** (Cr N4) | PROBE (red on base: the move throws before any order lock, so the control fails) | descending lock order in Fix B → B holds 9 and waits on 5 while A wants 9 → reliable 40P01 |
| B9 | Contract tests: `ReplenishorderRepository` declares no `findIdByStateLessThanAndStockunitId`, and declares `findHoldersByStateLessThanAndStockunitIdOrderById/2` returning `List` | RED | base |
| B10 | `FindByStateLessThanAndStockunitIdNoMainCallerArchTest` (`DoNotIncludeTests`): no `src/main` access to it | RAIL | a src/main call added |

**Fix C**

| # | Test | Base | Mutant |
|---|---|---|---|
| C1 | `SdrUncalledSurfaceNotExportedContextTest.callerlessSearchesOnExportedTypesAreWithdrawnIndividually`: add `new Withdrawn(Replenishorder.class, ReplenishorderRepository.class, "findByStateLessThanAndStockunitId")` to `expected`. It asserts the search is **absent** from the mappings. This reuses an existing context, so there is no new context fork | RED | `exported = false` removed |

**End to end: `TransferStockReplenHoldGuardIT`** (PostgreSQL). The source UL carries **at least 2 SUs**; otherwise `transferStock` takes the whole-container route (`… && stockUnitList.size() == 1 && unitloadService.restsInStorageLocation(suUnitLoad)`) into Fix B.

| # | Test | Base | Mutant |
|---|---|---|---|
| E1a | Full SU X → new container; holder at 300 with R = 0 → `BusinessException` naming the order. X's `unitload_id` unchanged, no new stockunit, no stockrecord since t₀ | RED | guard deleted |
| E1b | Same fixture, half the amount → succeeds; the replen row is unchanged (SBDEV-2492 manual row 5) | CTRL | guard keyed on the holder alone (refuses the split) |
| E1c | Same fixture through the replen finish → succeeds; order at 700 | CTRL | #15 left at REFUSE |
| E1d | Fixture with a single SU on the UL → whole-container route; holder re-pointed, no refusal | CTRL | Fix B pre-check widened to refuse 300 holders |

**Must stay green, unchanged:** `MobileReplenishServiceIntegrationTest`, `MobileReplenishMultiUnitLoadIT`, `ReplenishClaimIT`, `ReplenishorderRedirectSourceIT`, `ReplenishRedirectLockOrderIT`, and the SBDEV-3747 refusals in `MobileMoveUnitloadServiceUnitTest`. `StockunitDamagedRollbackIntegrationTest` moved to §6. **Blind spot (An §6):** `src/test/resources/scripts/*.sql` fixtures that seed holders were not cross-checked against non-replen callers; the full `-Pci` run covers that.

### 8.2 Mutation discipline

Apply each named mutant by hand, observe the named test go red, and revert. A PIT kill is not proof that the assertion did the killing (memory), so attribution comes from the hand mutant.

### 8.3 Scoped PIT

Run after `mvn test-compile`:

```
mvn org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.service.StockunitBusinessService,net.aim_ai.wms.service.ReplenishmentOrderSourceSyncService,net.aim_ai.wms.service.ReplenishmentOrderMaintenanceService,net.aim_ai.wms.service.ReplenishmentMaintenanceTrigger \
  -DtargetTests=net.aim_ai.wms.unit.service.StockunitBusinessServiceReplenHoldGuardUnitTest,net.aim_ai.wms.unit.service.ReplenishmentOrderSourceSyncService*,net.aim_ai.wms.unit.service.ReplenishmentOrderMaintenanceServiceReassignTest,net.aim_ai.wms.unit.service.ReplenishmentMaintenanceTriggerUnitTest
```

Every surviving mutant **in a changed method** is killed or justified in `fix1-review-code.md`. The recipe is `sbdocs/9-System/mutation-testing-recipe.md`.

### 8.4 Manual test plan (wms2-wineco-dev)

| Scenario | Steps | Expected |
|---|---|---|
| Refusal | Seed a 300 replen on SU X, which shares its UL with another SU; set X.reservedamount = 0; web Move Stock X (full) → new container | 422 toast with `Stock unit X on unit load …:` + REPL number; X not moved; `REPLEN_HELD_REFUSED` in the log |
| Sole-SU route | Same, but X is alone on its UL | Moves as a container; replen re-pointed (Fix B); no refusal |
| Split | Move Stock half of X | Succeeds; replen unchanged |
| Replen finish | Mobile finish on X | Succeeds; order 700; no WARN unless a sibling exists |
| Damage opt-in | Set X damaged (full) | Succeeds; `REPLEN_HELD_DISPLACED …@300`; replen cancelled or redirected after commit |
| Multi-holder | Seed 2 replens at 300 on SU Y with **distinct destinations**; Move Unit Load Y to a replenishable location, then to a lane | First move: both re-pointed. Second move: each redirected or cancelled; Y.reservedamount ≥ 0 |
| SDR | `GET /v3/replenishorder/search/findByStateLessThanAndStockunitId?…` | 404 |

---

## 9. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | New refusals on a live workflow | Resolved. SBDEV-3622 is on PRD and cancels the holder inside the cut's transaction (An §9). The message names the remedy |
| R2 | Batch abort on drift: BOL #1/#2, club #3, RTS `completeReversal` (its source stock is cancelled-order totes and parcels, so practically unreachable) | Today the same drift with R > 0 already aborts through "more than available". PRD has 0 rows with R ≤ 0. The message carries the SU/UL, and the abort is findable by `REPLEN_HELD_REFUSED` |
| R3 | Lock inversion if someone later "improves" Fix A by locking orders | AC A14 (ArchUnit fence on the mechanism) and the javadoc rule |
| R4 | TOCTOU (creation inserts before it locks); ALLOW_ANY over a STARTED holder strands it | Documented (§5 A.10). Heals at 300 only; 400 and 500 do not self-heal (pre-existing `REDIRECT_NO_HEAL`). `@state` is in the WARN |
| R5 | DI cycle | Repository only in SBS; trigger only in PBS (Ar claim 3); `-Pci` loads the full context |
| R6 | Fix B: N order locks per SU, plus the pre-existing UL↔order ABBA with the finish and the cross-SU SU→order edge (§4) | N ≤ 1 on PRD today. The pre-check removes waits on STARTED holders. A residual cycle is detected by PostgreSQL (40P01) and is not a hang |
| R7 | Unknown SDR consumer | 0 UI callers, with a positive control; OMS uses `/rest/**`. Blind spots: URLs built at runtime, scripts |
| R8 | A refusal burns a label | A caller's REQUIRES_NEW label mint (#6/#11 `createUnitload`) commits before the refusal and leaves a harmless gap |
| R9 | Stacked-PR orphaning | §7.1 row 4 |

### Horizontal scalability

| # | Concern | Verdict | Note |
|---|---|---|---|
| 1 | In-JVM state | No | enum and return value; no ThreadLocal |
| 2 | Pool math | No | one indexed projection query, on displacing branches only; Fix B adds N−1 lock reads (N ≤ 1 today); B8 uses 3 connections |
| 3 | Scheduled jobs | No | the cron is untouched |
| 4 | Long transactions | No | no I/O added; the heal runs after commit |
| 5 | Request affinity | N/A | stateless |
| 6 | Retry / idempotency | Yes, satisfied | a refusal commits nothing in the caller's transaction. A caller's REQUIRES_NEW label draw may be burned (R8). Fix B is all-or-nothing inside the move transaction |
| 7 | Tenant context | No | the trigger already records the tenant per id |
| 8 | Distributed lock correctness | Yes, this is the point of the change | orders ascending, then the SU; Fix A takes no order lock; everything runs inside `tenantTransactionManager`; the residual edges are in §4 |
| 9 | Cache invalidation | No | neither entity is cached |
| 10 | External notifications | No | no OMS or outbox write |

### v2 constraints

| # | Constraint | Status |
|---|---|---|
| 1 | No new `@Transactional` boundary; methods join the caller | ✓ the new overload copies the existing annotation (REQUIRED) |
| 2 | No reliance on OSIV | ✓ |
| 3 | Constructor injection, no `@Lazy` added | ✓ (§5 A.7) |
| 4 | JPQL only, H2-parseable | ✓ no new query |
| 5 | No controller or payload change | ✓ (Fix C removes one HTTP search) |
| 6 | No new `FunctionEnum` constant or gate | ✓ |
| 7 | Repository methods `@RestResource(exported = false)` | ✓ Fix C |
| 8 | Observability through WARN tokens, no metric | ✓ `REPLEN_HELD_REFUSED`, `REPLEN_HELD_DISPLACED` |

### Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1; An §7, §9; P-1 checked on 4 PRD tenants |
| 1 | All call sites | ✓ §0: 18 rows, the indirect callers (incl. RTS), and the Fix B/C sites; two instruments, with the blind spot named |
| 2 | Adjacent bugs | ✓ see below |
| 3 | Backward compatibility | ✓ the 8/9-arg signatures are unchanged; one SDR search is removed (R7); the error shape is the existing 422 |
| 4 | Concurrency | ✓ §4, §5 B.2/B.3, R3/R4/R6, ACs B1–B4 and B8 |
| 5 | Multi-tenant | ✓ no tenant routing is touched; the trigger carries the tenant |
| 6 | Error handling | ✓ the new throws are `BusinessException` → 422; mobile `apiError.js` renders them |
| 7 | Observability | ✓ two WARN tokens, including holder state |
| 8 | Rollback / migration | ✓ no migration; revert = revert the PR (after #510's ordering) |
| 9 | Test coverage | ✓ §8: unit, PostgreSQL IT, ArchUnit, context test, manual; every AC has a mutant |
| 10 | Cross-version | no: v1 is reference-only (since 2026-10-02) |

**Adjacent findings.**
- **P-1, checked 2026-10-13, not filed.** The concern is `MobileTransferOrderService`'s whole-stock arm: `transferUnitLoadToLocation(…, null code)` is PASS_THROUGH, so no sync runs. That arm runs only when `reservedamount == 0` **and** the UL has an FLA.
  - **Not reachable in the data:** 0 FLA-sourced replens in 180 days on all 4 PRD tenants, each with a positive control.

    | Tenant | FLA-sourced replens | Control (FLA destinations) |
    |---|---|---|
    | WineCo | 0 of 3,656 | 2,764 |
    | c1wh | 0 of 538 | 501 |
    | Hydra | 0 of 3 | 2 |
    | nywh | 0 (no replens) | – |

  - Active holders currently on an FLA UL: 0 on every tenant.
  - **Caveat:** this is a configuration convention, not a code guarantee. `isUsableSourceLocation` has no FLA check.
  - Recorded on the ticket (comment 90110278941728). No ticket.
- **P-2, proposed, not filed:** `findByUnitloadId` has no ORDER BY (the same as SBDEV-3637 P-1). It matters more now that Fix B locks N orders per SU.
  - **Blast radius:** every BLOCK_REALIGN move.
  - **Cost:** about 1 day with an IT.

---

## 10. Resolved decisions (Nam, 2026-10-13; do not reopen)

- **D1:** narrow refusal, on re-parent and drain-to-zero only. Splits and partial merges are allowed (SBDEV-2492 manual row 5).
- **D2:** pick confirm (#5) opts in, with a WARN and an after-commit heal.
- **D3:** damage (#10, #12) opts in, with a WARN. #12 relies on `setLockDamaged`'s existing trigger; #10 adds one and amends the SBDEV-2033 comment.
- **D4:** the multi-holder sync/maintenance fix is in scope, as is `exported = false` on the SDR search.
- **R1:** closed. SBDEV-3622 is live on WineCo PRD (An §9).
- **Verify script:** none. Every cross-file invariant is an ArchUnit or text-rail test (A13, A14, A20, B10). These run in CI and are mutation-checked.

---

## 11. Review disposition

### Round 1

| Finding | Disposition |
|---|---|
| Ar M-1 | Folded in. §4 now states the UL↔order ABBA and the cross-SU edge honestly. Fix B gains the pre-lock projection refusal plus the under-lock re-check (§5 B.2–B.4, AC B2). R6 updated |
| Ar M-2 | Folded in. The SBDEV-2033 comment is amended in the same commit, and the item-wide recalc is noted (§5 A.8, A.9) |
| Ar M-3 | Folded in. Fixture traps: distinct `destination_id`, BLOCK_REALIGN whole-UL entry, failure on base asserted by type, empty candidate pool for B6 (§5 B, AC B5/B6) |
| Ar M-4 | Folded in. B8 gets a `pg_stat_activity` positive control, a mutant and a connection budget, and is labelled PROBE |
| Ar M-5 | Folded in. Measured churn table in §6; default `TransferOutcome` stub; no production null-check (§5 A.1) |
| Ar L-1 | Folded in. A vanished candidate is treated as no holder and the next candidate is tried, as at c6f0cbc0 (§5 A.4, AC A8, B2). Widening the projection was declined: it would change the 3622 contract-test shape for no gain |
| Ar L-2 | Folded in. `@state` in the WARN; the residual is named in R4 |
| Ar L-3 | Partly folded in. D4 scopes Fix C to un-exporting, so the finder stays, now with a javadoc warning and an ArchUnit no-main-caller rule (B10) |
| Ar L-4 | Folded in. A13 uses `DoNotIncludeTests` and `getAccessesToSelf()` on the full signature; transitive blind spot named |
| Ar L-5 | Folded in. A1 asserts `clientRepository.findById` never is called; A12's mutant is "body moved, `.get()` kept" |
| Ar L-6 | Folded in. Both edges are in the javadoc (§5 A.2) |
| Ar L-7 | Folded in. Scalability row 6 reworded; R8 |
| Ar L-8 | Folded in. §0 indirect callers; R2 |
| Ar L-9 | Folded in. `requestIfDisplaced` helper (§5 A.8, AC A19) |
| Cr H1 | Folded in. `verifyNoTransfer` helper across all 3 overloads; all 19 `never()` sites migrated (§6); behavioural pin, mutant and text rail in A20 |
| Cr H2 | Folded in. B7 is a two-redirect fixture with distinct amounts; the §5 B.6 claim is corrected (a cancel recomputes the share; only a redirect consumes it) |
| Cr M1 | Folded in. §6 lists every file; `StockunitDamagedRollbackIntegrationTest` moved out of "unchanged"; Driver 3 corrected |
| Cr M2 | Folded in. Scaffold commit at §7.2 step 1 |
| Cr M3 | Folded in. Base column (RED / CTRL / RAIL / PROBE) on every AC |
| Cr M4 | Folded in. Every AC has a mutant; A10 and A11 are captured with a `ListAppender` |
| Cr M5 | Folded in. E1 needs at least 2 SUs on the source UL; E1d and the manual "Sole-SU route" row cover the whole-container route |
| Cr M6 | Folded in. Baseline source and re-run rule, the `-Pci` command, scoped PIT, and the review report written to a file (§7.2, §8.3) |
| Cr L1 | Folded in (= Ar L-1) |
| Cr L2 | Folded in (= Ar L-5) |
| Cr L3 | Folded in. `Objects.equals` filter; the null case is in A10 |
| Cr L4 | Folded in. C1 lives in `SdrUncalledSurfaceNotExportedContextTest` and asserts absence |
| Cr L5 | Folded in. Batch-path wording accepted, with the reason (§5 A.4) |
| Cr L6 | Folded in. The §4 sentence is scoped per SU, and the cross-SU edge is stated |
| Cr L7 | Folded in. R3 is now ArchUnit rule A14 (it fences the mechanism; native-query blind spot named) |
| Cr L8 | Folded in. `LockReadRail` listed as an instrument (§6) |
| Cr L9 | Folded in. Naming rule stated in the §8.1 preamble |
| Coordinator: P-1 | Moved to "checked, not filed", with the 4-tenant data and the configuration-convention caveat |

### Round 2 (architect APPROVE 0H/1M/6L · critic APPROVE with conditions 0H/1M/6L)

| Finding | Disposition |
|---|---|
| Ar R2-M1 | Folded in. B8 uses the deterministic latch design: A holds the lock on 5 in its own transaction; the test polls `pg_stat_activity` for B's pid until it waits on a lock; then A runs the real cut in the same transaction. The descending-order mutant now gives a reliable 40P01 |
| Ar R2-L1 | Folded in. `verifyNoTransfer` uses bare `any()`/`nullable(...)`, with `anyBoolean()` only on the primitives, plus a null-slot self-test per overload (§6) |
| Ar R2-L2 | Folded in with Cr N1. The A20 rail reuses the NeverMatcher lexer, with one planted offender per shape and a floor of ≥19 helper uses |
| Ar R2-L3 | Folded in. In B7 the moved SU is fully reserved (never a candidate); the C seeding preconditions are stated; both orders' `stockunitId == C` is asserted; the equivalent upfront-share mutant goes into the review report |
| Ar R2-L4 | Folded in. Refusing on a stale projection is intended, and the javadoc says "do not fall through after a present `findById`" (§5 B.2) |
| Ar R2-L5 | Folded in. `TransferOutcome` gets a compact constructor (`requireNonNull`, `List.copyOf`) (§5 A.1); lenient 8/9-arg stubs are converted by hand (§6) |
| Ar R2-L6 | Folded in. §7.2 labels follow RED / CTRL / RAIL / PROBE; the stub migration is named in step 5, not step 1 |
| Cr N1 | Folded in (= Ar R2-L2). The A20 pattern tolerates whitespace and newlines and covers `never ()`, `Mockito.never()`, `times(0)` and `.description(...)`; it has a positive control inside `TransferVerifications` |
| Cr N2 | Folded in. A6 asserts `times(1).findById(any())` |
| Cr N3 | Folded in. A14 bans method references to `ReplenishorderRepository` in SBS, which closes the `LockReads::findById` route; the remaining blind spot (a direct native or `entityManager` lock) is named |
| Cr N4 | Folded in. Because R2-M1 makes B8 deterministic, it is not tagged `timing-sensitive` and runs under `-Pci` |
| Cr N5 | Folded in. The baseline is re-measured on the actual base commit (8263/842 came from 08132098, and c6f0cbc0 adds a test). It is recorded in *Implementation Status*, and the gate compares failing-test sets, not totals (§7.2 steps 0 and 7) |
| Cr N6 | Folded in. The §4 diagram shows `syncForMovedStockUnit` checking replenishability first, so exactly one service runs the prefix |
| Cr N7 | Folded in (= Ar R2-L6). B10 is labelled RAIL in step 3 |

---

## RALPLAN-DR summary

**Mode:** SHORT.

**Principles**
1. Default-safe: a new or forgotten caller refuses, and every opt-in is explicit at its call site.
2. Never invert the lock order: per SU, orders ascending, then the SU. Never take an order lock after an SU lock.
3. The first touch of a row we will lock is the lock read itself (SBDEV-3244 F5).
4. Refuse only where the replen's binding is actually displaced; splits are never refused.
5. Put cross-file invariants in tests (ArchUnit, JUnit, text rails), not in scripts.

**Decision drivers**
1. No refusal on paths that must not refuse: the replen finish, a pick confirm with the goods in hand, physical damage.
2. Deadlock freedom against the cut and the cron, without new edges.
3. Minimal production churn (14 REFUSE sites untouched), with the test churn measured and disarm-proof (H1).

**Choice 1: policy shape**

| Option | Pros | Cons |
|---|---|---|
| **A. Trailing `ReplenHoldPolicy` enum on a new overload returning `TransferOutcome` (chosen)** | One body and one guard. Opt-ins can be grepped by type, and ArchUnit pins them by signature. The outcome feeds the caller-side heal without a DI cycle | The overload's return type differs from its siblings. A two-value enum looks like a boolean. Every caller test has to learn the record |
| B. A separate named method, `transferReplenHeldStock(…)` | Reads best at #15. No enum | Duplicates the javadoc surface. Four opt-ins with different heal semantics share a name that fits only one of them. Still needs an outcome type for the heal |

Rejected outright: a boolean parameter, a ThreadLocal (An §3 A, E), and an implicit Spring event, which would hide the opt-in's consequence (Ar T-3).

**Choice 2: Fix B drift handling**

| Option | Pros | Cons |
|---|---|---|
| **A. Act on the locked set (chosen)** | A move is not a consented cut, so a benign race should not fail the operator's move. Matches the cron's skip-if-gone behaviour. No new refusal surface | A holder created after the probe is not acted on (it heals at 300 only, the same residual as in Fix A) |
| B. Refuse on any drift (like `RESERVATION_CUT_CHANGED`) | Strict; mirrors `adjustReservedAmount` step (e) | Fails a move on a benign race, and still does not close the insert-after-probe residual, because creation locks the SU later |

**ADR** (final: consensus after ralplan round 2)
- **Status:** consensus approved by the architect and the critic in round 2, pending Nam's approval.
- **Decision:**
  - **(A)** A narrow guard inside `transferStockToUnitLoad`. It fires only on re-parent and drain-to-zero (`fla == null && A <= amount`), after the source-SU lock and before the first write, and it reads the holders projection only.
    - The policy is a trailing `ReplenHoldPolicy {REFUSE, ALLOW_ANY}` on a new overload that returns a non-null `TransferOutcome`. The existing overloads delegate with REFUSE.
    - Four callers opt in with ALLOW_ANY: #15, #5, #10 and #12.
    - #5 and #10 heal after commit through `requestIfDisplaced`.
    - Refusals and displacements log `REPLEN_HELD_REFUSED` / `REPLEN_HELD_DISPLACED`.
  - **(B)** The multi-holder move sync:
    1. Check replenishability first.
    2. Read the projection, and refuse if any projected state is ≥ STARTED. No lock is taken; this refusal on the projected state is deliberate.
    3. Lock the holders in ascending id order, then re-check under lock and act on the locked set: re-point, or lock the SU once and run `shareOf` → redirect/cancel per order.
    4. Delete `findIdByStateLessThanAndStockunitId`.
  - **(C)** `exported = false` on `findByStateLessThanAndStockunitId`, with a rule that it has no `src/main` caller.
- **Drivers:** as listed above.
- **Alternatives considered:**
  - a wide refusal;
  - a caller-side guard (Ar steelman);
  - a boolean parameter, a ThreadLocal, or an implicit Spring event;
  - a separate named method (Choice 1B);
  - `ALLOW_ORDER(id)`;
  - refusing on drift (Choice 2B);
  - keeping the `Optional` probe and catching its exception;
  - widening the holder projection;
  - deleting the SDR finder (outside D4).
- **Why chosen:** it closes both latent defects with no new refusal on any decided opt-in path, and without a new lock edge. Only inside the primitive can the predicate key on the locked branch variables. The pre-lock STARTED refusal also narrows the pre-existing UL↔order ABBA.
- **Consequences:**
  - The primitive now reads replen state, a known layering cost. It uses the repository only, and A14 fences it to direct, non-locking calls.
  - The policy overload has a new return type, and the `PickingorderBusinessService` constructor grows.
  - One HTTP search disappears.
  - About 19 `never()` sites, plus the opt-in-path stubs, are migrated, and rails A20 and B10 guard them.
  - The TOCTOU and ALLOW_ANY-over-STARTED residuals are documented, not closed.
  - The UL↔order and cross-SU lock edges stay pre-existing and are detected by PostgreSQL. B8 is a deterministic probe for move vs. cut.
- **Follow-ups:**
  - P-2.
  - Self-heal at RESERVED/STARTED (`REDIRECT_NO_HEAL`) stays out of scope.
  - P-1 was closed by the data check; re-check it if FLA locations ever become replen sources by configuration.
  - The upfront-share equivalent mutant is recorded in `fix1-review-code.md`.

---

## 12. Implementation Status (2026-10-13)

**PR:** https://github.com/SiteBossInc/wms2-api/pull/513. It is stacked on #510 (base `fix/SBDEV-3755-replen-holder-multi-and-child-banner`). Merge #510 into `develop` first.
**Branch:** `fix/SBDEV-3755-transferstock-replen-held-opt-in`. Worktree: `.claude/worktrees/wms2-api/SBDEV-3755-fix1`.

| Commit | Content |
|---|---|
| `2113fdc5` | TDD-gate scaffold: `ReplenHoldPolicy`, `TransferOutcome`, overload; no behaviour change |
| `7b59ae5c` | TDD-gate failing tests: 36 unit + 6 IT, all failing on assertions |
| `e93a7046` | Fix C: SDR search `exported = false` |
| `2481e101` | Fix B: multi-holder move sync (`MovedStockUnitHolders`); `findIdByStateLessThanAndStockunitId` deleted |
| `c23185d5` | Fix A: displacement guard |
| `3f2a98ee` | Opt-ins (#15, #5, #10, #12) plus caller-test migration (story 5 folded in) |
| `cffc5d80` | PIT survivor kills |
| `99331e32` | A14 rail sees supertype-owned references |
| `b37f0d1a` | B2 vanished-holder fallbacks (conformance PARTIAL) |
| `d908efb6`, `11af88b5`, `3dfe7a1a`, `ab56eb20`, `e5b71d78`, `292b8cd8`, `75346acd` | Code-review round 1: M1, M2+L1, L5, L4+L6, L2, L3, L7 |
| `f7fe0883` | SEC-1: only a true self-merge escapes the guard. A commit security review caught the 3dfe7a1a bypass |
| `06e79608`, `5caf29f2` | R2-L1, R3-L1/L2 (lock-fence rail) |

**Results**
- **Baseline `c6f0cbc0`:** unit 8264/0/0/1, IT 842/0/0/23.
- **Final `mvn clean verify -Pci` on `5caf29f2`:** unit **8347/0/0/1**, IT **852/0/0/23**, BUILD SUCCESS. No new failures.
- **Mutation:**
  - all 43 named hand mutants are killed, each attributably;
  - scoped PIT finds no survivors in new code;
  - reviewer-made mutants were killed too: M1, M2, SEC-1 a/b, the generic helper, the allow-list staleness control.
- **B8:** the contention control fired (`wait_event_type = Lock`, the move blocked by the cut, no 40P01). Not tagged timing-sensitive.
- **Conformance (verifier):** PASS, 15/15 sites. B2 was the one PARTIAL, closed in `b37f0d1a`.
- **Code review:** 4 rounds, the last one reading the tip `5caf29f2` with 0 findings. Report: `SBDEV-3755-evidence/fix1-review-code.md`.
- **Verify script:** none, by design. A13/A14/A20 ArchUnit rails replace it.

**Deviations from the plan**
- A new package-private `MovedStockUnitHolders` class. The verifier accepted it.
- A holder row that vanished at lock time is skipped rather than thrown, which matches §5 B.7.
- The guard also excludes a true self-merge. That was review L5, corrected by SEC-1.

**Landmine the plan didn't predict:** keying the self-merge exclusion on the destination *unit load* opens a drain-into-sibling bypass. `destinationStockUnit` is the first same-item stock unit on the destination unit load, not necessarily the source.

**Docs updated (merged 2026-10-15; the 13 "pending merge" markers were flipped and a SBDEV-3787 cross-SU caveat added to the transaction map):**
- `wms2-replenishment-design.md`
- `wms2-stockunit-design.md`
- `wms2-move-stock-unitload-workflow.md`
- `wms2-transaction-osiv-boundary-map.md` (`@Transactional` count 358 → 359; `REQUIRES_NEW` unchanged)

**Not done here:** archiving the plan, removing the worktrees.

### 12.1 Merge and deploy (2026-10-15)

- **#510 merged** into `develop` as `ebb52109` (head `c6f0cbc0` is an ancestor of `develop`). The first develop build failed on a Maven Central 502 while resolving `checker-qual`; the test job passed. A re-run of the failed job went green and deployed.
- **#513 retargeted to `develop` by hand.** `deleteBranchOnMerge` is false, so it was not auto-retargeted. It was then closed and reopened to trigger CI, because retargeting fires `edited`, which the workflow does not listen to. It **conflicted** with SBDEV-3758 (#512):
  - `b133e018` merges `develop`. `MobileTransferOrderServiceUnitTest.verifyNothingMoved` keeps `verifyNoTransfer` and drops the `transferUnitLoadToLocation` never-check that 3758 deleted with its arm.
  - `dca41983` adds 3758's `verifyNothingMintedOrMoved` (a bare `never().transferStockToUnitLoad`, added in parallel), which `NoBareTransferNeverRailTest` caught, routed through `verifyNoTransfer`. The `NeverMatcherNullBlindnessArchTest` entry for `MobileTransferOrderServiceUnitTest` is removed (5 → 0).
  - `e74ae955` adds the removal note.
  - Full `-Pci` on the merge: unit 8359/0/0/1, IT 852/0/0/23. Reviewed independently: APPROVE, 1 Low fixed.
- **#513 merged** as `3734751f`. Commits `e74ae955`, `5caf29f2` and `c23185d5` are confirmed on `develop`, and `TransferVerifications` is present.
- **Follow-on in #518 (SBDEV-3736).** Merging `develop` into #518 hit `UnitloadService.moveStockToNewDamagedContainer`:
  - 3736 passes `orderNumber`, and 3755 calls the `ALLOW_ANY` overload. The merged call does both.
  - `ReplenHoldPolicyCallerArchTest`'s decided-caller key moved from `moveStockToNewDamagedContainer/6` to `/7`: same caller, same D3 decision.
  - These are #518 commits `5d84a4d5`, `304f7925` and `f6445546`; #518 merged as `a05e8998`.
- **Dev deploy:** `develop-7ccb98e2` with `drift: false`.

### 12.2 Dev test (2026-10-15, wineco/wsl, user panderson)

§8.4 scenarios, recorded in ticket comments `90110279760194`, `90110279765839` and `90110279767188`:

| Scenario | Result |
|---|---|
| SDR | ✅ 404, and gone from the search index. The control `findByStateLessThanAndItemdataId` returns 200 |
| Split | ✅ Succeeds; the replen is unchanged |
| Refusal | ✅ The message names the SU, the UL and the REPL; nothing moved. **The web endpoint returns HTTP 200 + `errors`, not 422.** That is the StockUnitController convention |
| Sole-SU route | ✅ The UL moves as a container, and the replen's source and requested location are re-pointed |
| Replen finish (D1) | ✅ 700, `moved_amount` 12, source drained to 0. That is the drain-to-zero branch, allowed by the opt-in |
| Damage opt-in (D3) | ⏸ Not run: it would move 12 units into Damaged on dev |
| Multi-holder | ✅ Move 1: both holders re-pointed, no 500. Move 2 to a lane: each holder redirected to a different SU, with no negative reservation. **Deviation:** the destinations were not FLAs, because dev has 0 items with 2+ active FLAs and `idx_replenishorder_active_item_dest` allows one active replen per (item, destination) |
| Banner (#510) | ✅ A STARTED replen shows on the UL **and** on its carrier; the control shows nothing; both moves are refused |

- **Seeds and restores:** one `reservedamount` was set to 0 and restored. Two replens (`REPL-T3755-A/B`) were inserted, cancelled through the API and deleted. Every reservation for the item matches the pre-test snapshot.
- **Logs (checked by Nam, 2026-10-15):**
  - `REPLEN_HELD_REFUSED` is **present**, from the Refusal test.
  - `REPLEN_HELD_DISPLACED` is **absent**. That is expected: `transferStockToUnitLoad` logs it only for holders other than the caller's own `orderNumber` (`.filter(h -> !Objects.equals(h.getNumber(), orderNumber))`).
    - The replen finish passes `replenishOrder.getNumber()`, and `REPL389524` was the stock unit's only holder, so it had no sibling to displace.
    - D2 (pick confirm) and D3 (damage), the opt-ins that would log it, were not exercised.

### 12.3 Follow-ups

- **P-2 is filed as [SBDEV-3787](https://app.clickup.com/t/868mhwphf)** (2026-10-15, at Nam's request): `findByUnitloadId` has no `ORDER BY`, so cross-SU lock order is unspecified. It is T3.
- **Still out of scope:** self-heal at RESERVED/STARTED, and the P-1 re-check if FLA locations ever become replen sources.
