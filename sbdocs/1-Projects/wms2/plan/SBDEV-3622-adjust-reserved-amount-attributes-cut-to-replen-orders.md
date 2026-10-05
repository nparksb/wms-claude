---
title: "Adjust Reserved Amount attributes a cut to the replenishment orders holding it: shrink/cancel in the same tx, refuse what cannot be attributed"
ticket: "SBDEV-3622"
ticket_url: "https://app.clickup.com/t/868mc1d6q"
type: "bugfix"
priority: ""
status: "implemented"
tier: T3
repos: [wms2-api, wms2-web-ui]
project: ["wms2"]
version: "v2"
target_version: v2
requester: "Nam Park"
created: "2026-10-02"
updated: 2026-10-02
revision: "r3 — ralplan round 2 findings applied (architect r2 APPROVE WITH CHANGES, critic r2 APPROVE; no High). Round 1: architect r1 APPROVE WITH CHANGES, critic r1 ITERATE. Owner decisions D-H1 + D-M6 (§10). Finding map in §10."
db_verified: true
db_verified_note: "DEV wineco (dev_wh01_om1) + PRD wsl-wineco-prd / c1wh-shipitez-prd read-only, 2026-10-01/02. Bundle §3, the ClickUp triage comment (2026-10-02), the r2 queries, and the r3 re-source reconciliation + N-3 trace quoted in §1."
base_commit: "wms2-api 09f861da (origin/develop) + PR #444 5d1faaca (origin/bugfix/SBDEV-3621-release-held-share); wms2-web-ui 3e00a13 (origin/develop)"
related:
  - "[[SBDEV-3621]]"
  - "[[SBDEV-3618]]"
  - "[[SBDEV-3605]]"
  - "[[SBDEV-1615]]"
  - "[[SBDEV-3244]]"
tags:
  - plan
---

# SBDEV-3622 — Adjust Reserved Amount is holder-blind

**Ticket:** [SBDEV-3622](https://app.clickup.com/t/868mc1d6q) · **Tier:** T3 (reservation data integrity, multi-repo) · **Branch (both repos):** `bugfix/SBDEV-3622-adjust-reserved-attributes-cut` · **Worktrees:** `.claude/worktrees/{wms2-api,wms2-web-ui}/SBDEV-3622` · **Evidence:** bundle `.omc/research/SBDEV-3622-analysis.md` ("bundle §n"); reviews `.omc/research/SBDEV-3622-review-{architect,critic}-r1.md` ("A-x", "C-x") and `…-r2.md` ("A2-N-x", "C2-N-x" / "C2-L-nx").

Abbreviations: SUS `service/StockunitService.java`, SUBS `service/StockunitBusinessService.java`, SUC `controller/StockUnitController.java`, ROS `ReplenishorderService`, ROMS `ReplenishmentOrderMaintenanceService`, MRS `MobileReplenishService`, RGS `ReplenishGeneratorService`, RS `ReservationShare`, HSR `HeldShareRelease` (PR #444).

## 0. Affected sites

**Method:** bundle §0 greps on `origin/develop -- src/main` (`adjustReservedAmount`, `CODE_MANUAL_ADJUSTMENT`, `setReservedamount(`, `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT`); web-ui `git grep -i "adjustReservedAmount\|bulkAdjustReservedAmount\|bulkOpenAdjustAmount\|popups/adjustAmount"`; r2 added the consumers of a cut's outcome (ROMS recalc, RGS source selection, SU→order lock paths). Blind spot: native-SQL `reservedamount` writers — `git grep -n "reservedamount *=" -- src/main` is a step-3 re-check.

| # | Site (file · snippet) | Construct | In scope? |
|---|---|---|---|
| S1 | SUC · `newStockUnit = stockunitService.adjustReservedAmount(stockUnit, adjustAmount, comment);` (POST `/v3/stockUnit/adjustReservedAmount`, `@RequestBody Map<String,Object>`) | catches only Business/Facade → lock failure = 500; a `ClassCastException` from body parsing = 500 | **yes** (B6, B7, optional `expectedOrderIds` parsed into a keyed refusal, B8) |
| S2 | SUC `bulkAdjustReservedAmount` · per-id `addBatchServiceFailure(e, id, errors)` | per-id tx (SBDEV-3562) | **yes**, inherits B unchanged (AC-24) |
| S3 | SUS · `BigDecimal amount = reservedAmount.subtract(stockUnit.getReservedamount());` → `changeReservedAmount(stockUnit, amount, true, WmsConstants.CODE_MANUAL_ADJUSTMENT, null, comment)` | absolute set, holder-blind, null order, stale R | **yes — root cause** |
| S4 | SUBS `changeReservedAmount` · `throw new FacadeException("CANNOT_RESERVE_MORE_THAN_AVAILABLE", …)` on every delta | single-delta writer, 25 callers | reused for increase; **new sibling** `applyReservedCut`; systemic fix = P-2 |
| S5/S6 | `ReplenishmentReservationReconciliationService` (`"SBDEV-2610"`); MRS SBDEV-3605 release under `order.getNumber()` | already holder-aware | no |
| S7 | ROMS `cancelOrder` · `order.setState(WmsConstants.State.CANCELED); replenishorderRepository.save(order);`; ROS `cancelReplenishmentOrder` | two inline cancel copies | **yes** — extract no-release `markCancelled` (B4) |
| S8 | ROMS `bound` · `return share.held().compareTo(requested) < 0 ? share.held().min(share.capacity()) : share.capacity();` → `updateRequestedAmount` books `CODE_REPLENISHMENT` | regrows a partially cut order | **no logic change** — accepted (D-H1), pinned by AC-19; the `bound` javadoc ("Respect an admin's cut … the once-a-minute cron would undo every manual reservation cut") is rewritten, since after 3622 the admin path never leaves `held < requested` (A2-N-7) |
| S9 | `ReplenishorderRepository.findIdsByStateAndItemdataId` · `SELECT r.id FROM Replenishorder r WHERE r.state = :state AND r.itemdataId = :itemdataId` (no ORDER BY), consumed by ROMS `recalculateForItem` in one tx | unordered multi-order lock | **yes**, sibling one-liner `ORDER BY r.id` (§6 r3), pinned by a reflection assertion (A2-N-3) |
| S10 | RGS `calculateOrder` source query `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` (`AND su.reservedamount = 0`) | re-sources a freed SU | **no code** — P-3 (§2.5) |
| G1-G3 | SUC `@RequiresFunction(WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT)` ×2; `FunctionGuardArchTest` allowlist; `ActionGuardAnnotationContractUnitTest` (`hasSize(13)`, "all 13 gated handlers"); `StockUnitControllerActionGuardUnitTest` rows C.1–C.10 (POST-only `Endpoint` record; C.11–C.13 are taken by `UnitLoadControllerActionGuardUnitTest:78-82`); `FunctionGuardArchTest.REVIEWED_SHARED_GATE_FUNCTIONS` (arity-keyed, :737) | gate rails | **yes**, extended for the GET as row **C.14** (C) |
| U1-U3 | web-ui `components/handlingUnits/popups/adjustAmount.vue` (`data-test="replenishment-deferral-note"`); `store/handlingUnits/stockUnits.js` `adjustReservedAmount` | dialog, stale note, store | **yes** (D) |
| U4 | store `bulkAdjustReservedAmount`; bulk button inside an HTML comment | API-only bulk | no (O-5); stale store comment fixed |
| C1 | web-ui `cypress/e2e/wms/inventory-management/inventory-management.cy.js` sets reserved 1 then 0 on a live DEV SU | now cancels a DEV order | flag only (§5.1) |

## 1. Problem statement and DB evidence

Setting a SU's reserved amount below what its replenishment orders hold writes one `MANUAL_ADJUSTMENT` row with **no order number** and leaves every order at its old `requestedamount`: orders are under-held, the ledger cannot say whose reservation was cut, and the cron later shrinks/cancels with no link to the operator.

**PRD, 90 days** — source: the ClickUp triage comment on SBDEV-3622 (2026-10-02, rows = `stockrecord` with `activitycode='MANUAL_ADJUSTMENT'`, `reservedamountchange <> 0`, `ordernumber IS NULL`):

| Tenant | Cuts | …to 0 | …on an SU with a live replen order | Open under-held orders (`R < Σreq`) preceded by a cut |
|---|---|---|---|---|
| wsl-wineco-prd | 311 | **311** | **299** | 17 / 17 |
| c1wh-shipitez-prd | 19 | **19** | **18** | 6 / 6 |

`R > A` today (r2, 2026-10-02, `SELECT count(*) FROM stockunit WHERE reservedamount > amount`): **0** on both tenants. So the final-only validation in B3 is defensive (the shape is reachable through any writer that skips the check — design doc :150 records it historically), not a live PRD shape; r1's "23 SUs have R < Σreq" justified the wrong thing (C-M1).

Per-SU shape (bundle §3): WineCo 563 SUs with one open order, 0 STARTED, 0 open picks, 17 invariant-broken, 1 surplus; c1wh 97 / 0 / 0 / 6 / 1; two orders on one SU in 90 days: **0**. Multi-order, open-pick and STARTED cases are fixture-tested, not reproduced.

**After a cut to 0 today — the next positive reservation change on the same SU** (traced on wsl-wineco-prd 2026-10-02, C2-N-3; cuts = the 311 above, "next" = the first later `stockrecord` with the same `fromstockunitidentity` and `reservedamountchange > 0`, any window):

| Next positive change | Cuts | Detail |
|---|---|---|
| `REPLENISHMENT` (ROMS `updateRequestedAmount`'s booking code, `CODE_REPLENISHMENT`) | **181** | every one under the **pre-existing** order number. 145 by the system/cron operator (135 within 10 minutes of the cut; min 0.1 s, max 51 days). 36 by 3 named web users, all within 2–594 s |
| `REPLENISHMENT_CREATED` (RGS, a new order) | 10 | §2.5 |
| `CREATE_PICK_POSITION` | 4 | — |

**Verdict: the recalc re-grants the cut. It is not a human workflow that keeps using the order.** The 36 named-user rows match the inline `recalculateForItem` triggers that run inside other web actions (SUS `triggerReplenishmentMaintenance` ~:155, `FixLocationAssignmentService` ~:307), which book the triggering user as operator. The cause is the pre-SBDEV-3618 recalc: 3618 is on develop (3d0cf1e7) but not on `main`, so it is not yet on PRD. So **today a cut to 0 is undone within minutes in more than half the cases**, which is the SBDEV-2033 complaint. Cancelling the order at the click closes this, because ROMS skips CANCELED orders (:291). This strengthens decision 1, and no owner question is needed (escalation trigger 3 does not fire). Side effect: once the order is cancelled, the item has no open order, so the item-level `NOT EXISTS` no longer blocks the refill trigger. Some of these 181 can therefore turn into P-3 re-sourcing (§2.5).

**Generator re-sourcing — the counts depend on the definition. All four were re-run on wsl-wineco-prd 2026-10-02 (L-n8):**

| Definition (each counts cuts out of 311) | Count |
|---|---|
| a `REPLENISHMENT_CREATED` row with a positive change on the SU **within 24 h** (critic r2's join) | **21** |
| …and its order (`replenishorder.number = ordernumber`) was **created after the cut**, i.e. a new order re-sourcing the freed SU (r2's figure) | **14** |
| the **first** positive change after the cut is `REPLENISHMENT_CREATED` (the table above) | 10 |
| a `REPLENISHMENT_CREATED` row on the SU at any time after the cut | 94 |

The P-3 blast-radius number is **14**: it counts only new orders that re-source the freed SU within 24 h, with a minimum lag of 44 s. The other 7 of the 21 are creation rows of orders that already existed at cut time. c1wh: 7/19 regrown under the pre-existing order, 0/19 re-sourced (r2 query).

```sql
WITH c AS (SELECT id, created, fromstockunitidentity su FROM stockrecord
           WHERE activitycode='MANUAL_ADJUSTMENT' AND reservedamountchange<>0 AND ordernumber IS NULL
             AND created > now()-interval '90 days')
SELECT count(*) FROM c WHERE EXISTS (
  SELECT 1 FROM stockrecord s JOIN replenishorder r ON r.number = s.ordernumber
  WHERE s.fromstockunitidentity = c.su AND s.activitycode = 'REPLENISHMENT_CREATED'
    AND s.reservedamountchange > 0 AND s.created > c.created
    AND s.created <= c.created + interval '24 hours' AND r.created > c.created);   -- 14
-- drop the replenishorder join and the r.created predicate → 21; drop the 24 h bound as well → 94
```

**DEV (dev_wh01_om1):** 565 open orders, all state 300, one per SU; repro SU **929025745** (A 1, R 1) ← **REPL389508** (state 300, req 1, operator NULL). Partial-cut regrowth, live: SU **30685299** / **REPL389503**, stockrecord **31278102** (`panderson`, MANUAL_ADJUSTMENT −8 → reserved 10, `ordernumber NULL`, 2026-10-01 05:26) then **31278112** (`REPLENISHMENT` +8 → 18, `ordernumber REPL389503`, `anonymous`, 13:45) — C-1.

## 2. Root cause and consumer behaviour

1. **Absolute set, holder-blind.** S3 books one delta against the SU alone; nothing reads `replenishorder` or `pickingorder_position`.
2. **Null order number** by construction.
2a. **The cut is re-granted (N-3 trace, §1).** Because the order keeps its old `requestedamount`, the next recalc (cron, or `recalculateForItem` run inline by another web action) books `REPLENISHMENT` under that order and restores the reservation. That happened in 181 of 311 PRD cuts to 0, most of them within 10 minutes. Cancelling at the click removes the order from the recalc's domain.
3. **Stale pre-lock read.** SUC loads the SU with a plain `findById` (OSIV off); S3 computes `T − R_detached` before SUBS takes `findByIdForUpdate`; SHIPPED/GOING_TO_DELETE read the detached row.
4. **Open, not-started picks unprotected.** SBDEV-1615's `hasActivePickFor` refuses only `>= STARTED`; decision 4's refusal is new behaviour.
5. **Generator re-sources a freed SU (D-M6 verdict: yes, it can).** RGS `calculateOrder` selects from `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage`: `"WHERE unitload.entity_lock = :notLocked AND su.entity_lock = :notLocked AND su.amount > 0 AND su.reservedamount = 0 AND su.itemdata_id = :itemDataId … AND area.useForReplenish = true … ORDER BY su.amount, su.created"`, takes the first candidate with `amountOnStockCandidate.compareTo(amount) >= 0`, else `stockList.get(0)`. The trigger `FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE` needs `stockunit.amount < fla.lowerbound` and `NOT EXISTS (… ro.state < :replenishOrderStatus AND ro.itemdata_id = itemdata.id)`. No cooldown, no `stockrecord`/MANUAL_ADJUSTMENT exclusion, nothing SU-specific. So once 3622 cancels the item's last open order, the next refill run may create a new order, and the freed SU is a candidate exactly when the cut left `reservedamount = 0` and the SU/UL/location are unlocked. It is chosen when it is the smallest qualifying candidate. A cut that leaves `R > 0` (e.g. open picks) or an on-hold SU is not eligible. An SU **cannot be put on hold before** the cut: `setLockOnHold` refuses `R > 0` ("Can not set stock to on hold as stock unit has reserved stock!", SUS ~:766). Putting it on hold **after** a cut to 0 has two costs. It relocates the unit load to the on-hold location (`transferUnitLoadToLocation(…, CODE_ON_HOLD, …)`, SUS ~:769), which takes the stock out of picking as well as out of replenishment. And it races the refill run (minimum observed lag 44 s). See A2-N-2. **Not fixed here** → P-3.

## 3. Fix design

### A. `ReservationCut` — pure arithmetic (new `final` class, static only, `service/`, next to RS)

`ReservationCut.plan(Input) → Plan`; no Spring, no repositories; null-as-0 on every BigDecimal; **every comparison `compareTo`, never `equals`** (implementation round 1: every caller — preview, single POST, bulk POST — parses through `ReservationCut.parseAmount`, an exact `new BigDecimal(text.trim())` bounded to the `numeric(17,4)` column, refused with `RESERVATION_CUT_TARGET_INVALID`; the old `new BigDecimal(Double.parseDouble(amount))` turned `0.2` into `0.2000000000000000111…` and made the preview and the save disagree — code review H, security H-1).

- **Input:** `A`, `R`, `T`, `P` + `pickOrderNumbers`, `entityLock` (the SU's `entity_lock` int), `activePick` (boolean, `hasActivePickFor`), `holders` = `{id, number, state, created, requested, operatorName}` for every open order (`state < FINISHED`) on the SU. `holders` is always built from the widened holder projection (B1b), never from entities, so no holder has a null `requested`/`created` because it was not loaded (A2-N-5). A null in the DB is still handled by the null-as-0 / null-created-oldest rules.
- **Plan:** `kind ∈ {NOOP, INCREASE, CUT, REFUSE_LOCKED, REFUSE_PICK_STARTED, REFUSE_ABOVE_AMOUNT, REFUSE_BELOW_PICKS, REFUSE_STARTED}`, `surplusCut u`, per-order `{id, number, allocated a_i, cut d_i, newRequested, cancel}`, `blockedBy`, `holderIds` (all open ids, for `expectedOrderIds`).
- **Rule, in order:**
  - **00. Refusals that are not arithmetic (C2-N-2).** These mirror the write path's existing refusals, so that the preview predicts them.
    - `entityLock` is SHIPPED or GOING_TO_DELETE → `REFUSE_LOCKED`, with the existing literal messages "…shipped…" / "…going to delete…".
    - `activePick` → `REFUSE_PICK_STARTED` ("Can't adjust reserved amount - picking has already started").
    - On the write path the existing literal `if (stockUnit.getEntityLock() == …) throw` and `hasActivePickFor` throws in SUS fire **first** and stay authoritative, so this rule is reachable there only as a unit-tested consistency property. Its job is the preview.
    - The comparison lives in `ReservationCut`. That class calls none of `MoveSourceLockComparisonRailTest`'s `PRIMITIVES`, so it is outside the rail's scope. It returns a Plan, never throws. `previewReservationCut` only *passes* `stockUnit.getEntityLock()` into Input, with no `if … throw`, so it adds no offence. The two SUS `adjustReservedAmount` EXEMPT keys still match exactly one site each. The rail **stays green unchanged**.
  0. `T < 0` → `T := 0` (**clamp, parity with today's `zeroIfNegative=true`**; then rules 1–6 apply, so with `P > 0` it refuses below picks naming them).
  1. `T > A` → `REFUSE_ABOVE_AMOUNT`, thrown as today's `FacadeException("CANNOT_RESERVE_MORE_THAN_AVAILABLE", …)` so the existing message and SUC `FacadeException` branch are unchanged (C-L1). `T == R` → `NOOP`. `T > R` → `INCREASE` by `T − R`.
  2. Cut `c = R − T`. Any holder with `state > PROCESSABLE` (null state = not shrinkable = refuse) → `REFUSE_STARTED` naming every such order + operator, even if the cut fits in surplus (O-1).
  3. `T < P` → `REFUSE_BELOW_PICKS` (decision 4).
  4. Surplus first: `U = max(0, R − P − Σreq_i⁺)`, `u = min(c, U)`.
  5. Pool `H = min(max(0, R − P), Σreq_i⁺)` allocated **oldest-first** (created asc, **null created = oldest**, id asc): `a_i = min(req_i⁺, H − Σ_older a_j)`.
  6. Walk **newest-first** (reverse of 5) with `c' = c − u`: `d_i = min(a_i, c'_left)`; every order visited while `c'_left > 0` is affected: `newRequested = a_i − d_i`, `cancel = newRequested.signum() == 0`. Orders after exhaustion are untouched.
  7. Post-conditions (unit-asserted): `R − u − Σd_i == T`; `T ≥ 0`; and whenever a cut reaches orders, **`c > U`** (not `U = 0`: case 5 has `U = 3` and the cut still reaches X — C2-L-n5), `T ≥ P + Σ req'` over **all** open orders (the invariant is fully repaired — A-L6). Asserted, not clamped.
- States `< PROCESSABLE` (RAW/ON_HOLD) are shrinkable (O-3).

| # | Case | R | orders old→new (req) | T | Plan |
|---|---|---|---|---|---|
| 1 | cut to 0, one order | 9 | X 9 | 0 | X d 9 → cancel; no null-order row |
| 2 | cut to 0, two orders | 15 | X 9, Y 6 | 0 | Y d 6 cancel; X d 9 cancel |
| 3 | partial, two orders | 15 | X 9, Y 6 | 5 | Y d 6 cancel; X d 4 → req 5 |
| 4 | surplus only | 12 | X 9 | 10 | u 2 (null order); X untouched |
| 5 | surplus + order | 12 | X 9 | 5 | u 3; X d 4 → req 5 |
| 6 | invariant broken | 10 | X 9, Y 6 (a 9, 1) | 8 | Y d 1 cancel; X d 1 → req 8 |
| 7 | below picks | 10 | X 4, P 6 | 5 | REFUSE_BELOW_PICKS |
| 8 | STARTED holder | 9 | X 9 STARTED (`jdoe`) | 3 | REFUSE_STARTED (X, jdoe) |
| 9 | increase | 4 | X 4 | 7 | INCREASE +3, null order |
| 10 | negative target | 9 | X 9 | −3 | clamp T 0 → as case 1 |
| 11 | SU SHIPPED / GOING_TO_DELETE | 9 | X 9 | 0 | REFUSE_LOCKED (before any arithmetic) |
| 12 | active pick (`hasActivePickFor`) | 9 | X 9 | 0 | REFUSE_PICK_STARTED (also on an increase) |

### B. Locked write path (SUS `adjustReservedAmount` + one new SUBS method)

1. **Lock spine** (picks → orders asc → SU, the cron's order → SU direction; A-M2 pruned):
   (a) `pickLineRealignmentService.lockOwningPickingorders(List.of(suId))` + `hasActivePickFor` refusal — unchanged;
   (b) probe with a **new** `ReplenishorderRepository.findHoldersByStateLessThanAndStockunitIdOrderById(FINISHED, suId)`. It is a JPQL projection `(id, state, number, operatorId, requestedamount, created)` (widened, A2-N-5) with `ORDER BY r.id` and `@RestResource(exported = false)`. A new finder is needed because the existing `Optional<Long> findIdByStateLessThanAndStockunitId` throws on more than one row;
   (c) `findByIdForUpdate` **only the holders with `state ≤ PROCESSABLE`**, ascending id (first touch, SBDEV-3244). A holder `> PROCESSABLE` is **never locked**: it holds the picker's finish out of a cycle (finish: plain read → SU lock → order UPDATE). **Re-check each locked entity's own state as well.** If it is `> PROCESSABLE` (started between (b) and (c)), refuse with `REFUSE_STARTED` at once, before (d). This keeps the narrow window from turning into the M-2 cycle: the picker would otherwise finish while 3622 holds a STARTED order and waits for the SU (A2-N-4, §6 r4);
   (d) `stockunitRepository.findByIdForUpdate(suId)` — first touch, **no `entityManager.refresh`** (SUS has no tenant EM, and the first-touch `FOR UPDATE` read is already fresh — C-M5);
   (e) re-probe (b) under the SU lock. If the id set ≠ (b) → `RESERVATION_CUT_CHANGED`. A holder seen `> PROCESSABLE` in the re-probe → `REFUSE_STARTED`, decided by rule 2 only when the locked SU shows a cut; a stale STARTED read is a harmless spurious refusal. `Input.holders` is built from **this** re-probe for every holder, in both paths. Writes go to the locked entities by id, and those match the re-probe because they are locked;
   (f) **after `plan`, and only when `kind == CUT`:** a supplied `expectedOrderIds` ≠ the re-probed id set → `RESERVATION_CUT_CHANGED`, nothing written (B8). On INCREASE/NOOP/REFUSE_* a drifted set changes nothing the operator consented to, so it is not checked (A2-N-1).
2. **Inputs from the locked rows.** SHIPPED/GOING_TO_DELETE re-checked on the locked SU — **keep the variable named `stockUnit`** so the `MoveSourceLockComparisonRailTest` EXEMPT keys `(stockUnit.getEntityLock() == …)` stay literal-identical (C-L6). Shared private builder `buildCutInput(Stockunit su, boolean activePick, List<HolderView> holders, BigDecimal target)`: takes the SU and the holder projection rows from its caller (`entityLock` is read from `su`), runs **only scalar/projection queries** — `P` = `PickingorderPositionRepository.sumOpenAmountByPickfromstockunitId(su, PICKED)`, owning picking-order numbers (new projection, `exported = false`), operator names via `userRepository.findById(operatorId)` with fallback `"unknown"` for null id / missing user (A-L5, C-L2) — so the write path never plain-reads an order or the SU before its lock (A-L2).
3. **Writes by kind.** `NOOP` → nothing. `INCREASE` → existing `changeReservedAmount(stockUnit, T − R_locked, true, CODE_MANUAL_ADJUSTMENT, null, comment)`. `REFUSE_*` → throw, nothing written. `CUT` → **new** `StockunitBusinessService.applyReservedCut(Stockunit lockedSu, List<ReservedCutRow> rows, String activityCode, String comment)`: validates **only the final** `0 ≤ R_final ≤ A` (and still throws, writing nothing, when the final value is above A or below 0 — AC-14b), then per row `lockedSu.setReservedamount(running)` **before** `stockrecordService.recordChangeReservedAmount(lockedSu, −d, CODE_MANUAL_ADJUSTMENT, number, comment)` (surplus row first with `number = null`, then orders newest-first; comment clamped as SBDEV-3085), one save. Row shape = `changeReservedAmount`'s, so P-2 can later reduce it to a loop over that method (A-M7).
4. **Order rows.** Affected order: `cancel` → new no-release `ReplenishmentOrderMaintenanceService.markCancelled(Replenishorder lockedOrder)` (sets CANCELED + save); else `setRequestedamount(newRequested)` + save. ROMS `cancelOrder` calls `markCancelled` after its release. ROS `cancelReplenishmentOrder` does too, **unconditionally**: ROS gains a ROMS constructor dependency. There is no bean cycle (A2-N-9, verified). ROMS's constructor closure (repositories, SUBS, `SyspropService` → … → `ReplenishmentOrderSourceSyncService`'s existing `@Lazy` ROMS) never reaches ROS, and ROS is injected only by ReplenishOrderController, UtilRestController, CustomerorderBatchService, CustomerorderService, FixLocationAssignmentService, ReplenishOrderJobService and MobileMoveUnitloadService. Not `cancelOrder`/`cancelReplenishmentOrder` themselves: both recompute `held` from the lowered R and would release twice. No OMS signal exists on replen cancel (bundle §1).
5. **No replenishment re-trigger**, as today. Rewrite the SUS comment beginning `// Manual reservation adjustment is a deliberate user action; re-triggering` to say the cut is attributed in-tx, a partial cut may regrow on the next recalc (D-H1), and a cancel may be re-sourced (P-3).
6. **Refusal keys.** New `WmsConstants.MessageKey` constants in **both** `messages.properties` and `messages_en_US.properties`, positional `%1$s` (covered by `MessageKeyConstantBundleContractTest`). Wording mirrors `ReplenishmentOrderMessages.replenBlockMessage` ("Replenishment order X is in progress …"); that helper is a package-private hard-coded string with no operator, so it is not reused (A-L9).
   - `RESERVATION_CUT_ORDER_IN_PROGRESS` — "Can't reduce the reserved amount: replenishment order %1$s is in progress (operator %2$s)."
   - `RESERVATION_CUT_BELOW_PICKS` — "Can't reduce the reserved amount below %1$s: it is reserved for picking order(s) %2$s."
   - `RESERVATION_CUT_CHANGED` — "The reservations on this stock unit changed while saving. Reload and try again."
   - `RESERVATION_CUT_LOCK_BUSY` — "This stock unit is being changed by another process. Try again in a moment."
   - `RESERVATION_CUT_EXPECTED_IDS_INVALID` — "Invalid expectedOrderIds: expected a list of replenishment order ids." (B8, A2-N-1).
   **The three parameterless keys are thrown as `new BusinessException(KEY, new Object[0])`** — the one-arg `BusinessException(String)` is the *message* constructor and sets `key = "placeholder"` (0 precedents of the one-arg keyed form in `src/main`). Tests assert `getKey()` equals the constant **and** `getMessage()` is not the raw key (A-M1, C-H1).
7. **O-4 lock failure.** SUC single path adds `catch (PessimisticLockingFailureException e)` (covers 55P03 and 40P01 after translation; precedent `PickingController:76`) → `errors.add(getErrorMessage("Runtime Error", new BusinessException(RESERVATION_CUT_LOCK_BUSY, new Object[0]).getMessage()))`. Bulk already maps it via `addBatchServiceFailure`.
8. **Optional `expectedOrderIds`** (A-M5, A2-N-1). It is an **additive** request-body field on the POST `Map`. The contract has three states:
   - **absent or JSON `null`** → `null` → skip the check. This is today's behaviour, used by bulk and API callers.
   - **`[]`** → the empty set → "the preview saw **no** holders". A CUT that finds any holder under the lock → `RESERVATION_CUT_CHANGED`, nothing written. This is the highest-risk consent case: an order is redirected or generated onto the SU between GET and POST. `isEmpty()` must **never** be treated as absent.
   - **a list of integers** → `Set<Long>`; only `Integer`/`Long` elements are accepted (a fraction or an out-of-range value is the keyed `RESERVATION_CUT_EXPECTED_IDS_INVALID`, never truncated — implementation round 1, security L-2; this supersedes the earlier `Number::longValue`). Jackson gives `Integer` below 2^31 and `Long` above, so the SUC:401 `(Integer)` cast pattern would throw `ClassCastException` on a Long.
   - **any other shape** (not a `List`, or an element that is not a `Number`) → `new BusinessException(RESERVATION_CUT_EXPECTED_IDS_INVALID, new Object[0])`. The parse runs inside SUC's existing `try`, so the `BusinessException` catch maps it to the refusal shape. Today it would be a `ClassCastException` and a 500.

   SUS gains an overload `adjustReservedAmount(su, amount, comment, Set<Long> expectedOrderIds)`, and the 3-arg form delegates with `null`. The comparison is done only when `kind == CUT` (B1f).
9. **New SUS constructor deps:** `ReplenishorderRepository`, `PickingorderPositionRepository`, `UserRepository`. No `new StockunitService(` in `src/test`. The **6** classes that `@InjectMocks StockunitService` (AuditCommentClamp, ParcelSourceRefusal, ToteContainerRelocation, TransferStockDestination, TransferStockGuard, `StockunitServiceUnitTest` — C2-L-n3) get `null` for an unmocked arg. So only the adjust-path classes need new `@Mock`s (§8 "Changed tests"). **New ROS constructor dep:** `ReplenishmentOrderMaintenanceService` (B4).

### C. Preview `GET /v3/stockUnit/reservationHolders/{id}?target=T`

- Path follows the local `/stockunitDetailsById/{id}` convention, not the SDR association shape `/{id}/…` (A-L4). This **differs from the owner's decision-5 text**, which said `/v3/stockUnit/{id}/reservationHolders` (§10, C2-L-n6).
- **Handler signature (C2-N-1), arity 3:** `public ResponseEntity<Object> reservationHolders(@PathVariable("id") Long id, @RequestParam(value = "target", required = false) String target, @AuthenticationPrincipal Principal principal)`. Every SUC handler takes `Principal`; precedent `getStorageLocationsForStockMovement(@PathVariable("labelId") String, @AuthenticationPrincipal Principal)` (SUC:809).
- It carries `@GetMapping(path = "/reservationHolders/{id}", produces = "application/json")` and `@RequiresFunction(WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT)`, and calls `StockunitService.previewReservationCut(id, target)`. That method is annotated **`@TenantTransactionalReadOnly`** (it exists: `config/TenantTransactionalReadOnly.java`).
- **No locks**, because PG rejects `FOR UPDATE` in a READ ONLY tx. It does plain reads of the SU, the plain `pickLineRealignmentService.hasActivePickFor(id)` (a `findByPickfromstockunitId` loop with no lock) and the widened holder projection. Then it runs the **same** `buildCutInput` + `ReservationCut.plan`, so the preview also predicts REFUSE_LOCKED and REFUSE_PICK_STARTED (rule 00, C2-N-2). It never calls `lockOwningPickingorders` or any `findByIdForUpdate`. The write path's (a) stays the authority on picks. JSON: `{reserved, amount, openPick, pickOrders[], surplus, holderIds[], orders[{id, number, state, operator, requested, allocated, cut, newRequested, cancel}], kind, blockedBy[]}`; `target` omitted → holders only (NOOP).
- Gate rails (C2-N-1, A2-N-10):
  - **`FunctionGuardArchTest`**, two entries.
    - `REVIEWED_SHARED_METHOD_GATES` (:362, arity-free): add `"StockUnitController#reservationHolders"` with **its own rationale** ("read-only preview only reached from the gated dialog; gating it cannot blank a page"). It must not be a line inside the "thirteen destructive write endpoints" block (A-L3).
    - **`REVIEWED_SHARED_GATE_FUNCTIONS`** (:737, arity-keyed): add `Map.entry("StockUnitController#reservationHolders/3", Set.of(WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT))`. Without it, AC-4c `reviewedSharedGatesCarryTheirFullAnyOfSet` goes red.
  - **`ActionGuardAnnotationContractUnitTest`:**
    - add `expect(StockUnitController.class, "reservationHolders", 3, reserved)` with its own comment, since the existing `// C.1–C.10 — every handler takes (Map reqMap, Principal principal), so arity 2` (:69) does not cover it;
    - `hasSize(13)` → `hasSize(14)`;
    - rename the method `allThirteenHandlersExistWithTheExpectedArity` (:94) → `allFourteenHandlersExistWithTheExpectedArity`;
    - both `@DisplayName`s 13 → 14. The literal is the drift alarm and is not derivable (C-H2).
  - **`StockUnitControllerActionGuardUnitTest`:**
    - add row **C.14**. C.11–C.13 are the UnitLoadController delete tranche (`UnitLoadControllerActionGuardUnitTest:78-82`, `ActionGuardAnnotationContractUnitTest:80`).
    - The row is two separate named `@Test`s, because this class's `Endpoint` record only POSTs JSON; `UnitLoadControllerActionGuardUnitTest`'s record carries an HTTP-method column, but adding one here is not needed. Both tests go through the real guard (`setupMockMvcWithGuard`):
      - a **deny** leg: 403 + `X-Authz-Denied`, `previewReservationCut` never called;
      - an **allow** leg: 200, called once.
      With both legs, a class-level gate cannot pass vacuously.
    - Update the class `@DisplayName` "(C.1–C.10)" (:67) and the class javadoc "rows C.1–C.10" (:48) to "C.1–C.10, C.14".
  - SUC stays out of `GUARDED`.

### D. UI — `adjustAmount.vue`, store, Jest (wms2-web-ui)

- Store: `fetchReservationHolders(context, {id, target})` → `$get('/stockUnit/reservationHolders/' + id, {params:{target}})`. `adjustReservedAmount` sends `expectedOrderIds = preview.holderIds` whenever a preview loaded, **including `[]`**. It omits the field only when no preview loaded (A2-N-1).
- Dialog (reserved mode): the dialog is always mounted, so fetch from a **watcher on `show` / `item`** and on target change (debounced) — not `mounted`; a **request-sequence guard** drops responses for a superseded target. Rows: "REPL… — will be cancelled" / "will shrink to N (the next replenishment run may re-reserve it)"; surplus line; blocking alert naming the STARTED order + operator or the picking orders, or saying picking has started / the SU is shipped or going to delete (REFUSE_PICK_STARTED / REFUSE_LOCKED); **Submit disabled only while `kind` is `REFUSE_*`; a failed preview (network / 403) leaves Submit enabled** — the server decides (A-L8). POST refusals land as the existing toast with the dialog open.
- Confirm/note copy (replaces `replenishment-deferral-note`, `data-test` → `replenishment-cut-note`): "Reducing the reserved amount changes the replenishment orders listed above now. A cut to 0 cancels the order; a partially reduced order may be re-reserved by the next replenishment cycle, and the replenishment job may later create a new order from this stock unit." (D-H1, D-M6, C-L7). The r2 clause "unless it is put on hold" is **removed** (A2-N-2): an SU with any reservation cannot be put on hold, and putting it on hold afterwards relocates it and races the refill run (§2.5). Rewrite `replenishmentDeferralNote.spec.js`; fix the stale bulk comment in `stockUnits.js` ("The API wraps the whole loop in one try" — false since SBDEV-3562).
- Bulk button stays commented out (O-5).

## 4. File change summary

| Repo | File | Change |
|---|---|---|
| api | `service/ReservationCut.java` | **new**, pure planner |
| api | `service/StockunitService.java` | lock spine, `buildCutInput`, dispatch, 4-arg overload, `previewReservationCut`, 3 ctor deps, comment rewrite |
| api | `service/StockunitBusinessService.java` | **new** `applyReservedCut` |
| api | `service/ReplenishmentOrderMaintenanceService.java`, `ReplenishorderService.java` | `markCancelled` extracted and reused by both (ROS gains a ROMS ctor dep); **`bound` javadoc rewritten** — partial admin cuts now regrow by design, and the `held < requested` branch is reached only by a clamped release or a writer other than 3622 (A2-N-7, no logic change) |
| api | `repo/jpa/ReplenishorderRepository.java`, `PickingorderPositionRepository.java` | widened holder projection `(id, state, number, operatorId, requestedamount, created)`; pick-number projection (both `exported = false`); `ORDER BY r.id` on `findIdsByStateAndItemdataId` |
| api | `controller/StockUnitController.java` | GET handler (arity 3); lock-failure catch; `expectedOrderIds` parse (null / `[]` / Integer-or-Long only / bad shape → keyed refusal); shared `ReservationCut.parseAmount` for both POSTs |
| api | `service/WmsConstants.java`, `messages.properties`, `messages_en_US.properties` | 5 keys |
| api | tests | new `ReservationCutUnitTest`; new `ReservationCutAttributionIT` in package **`net.aim_ai.wms.integration.service`**, because `AbstractReplenishRedirectPgFixture` is package-private (C2-L-n1); `ReplenishmentHeldShareIT.it1` `@DisplayName` "the cut sticks" reworded to say it models a JDBC-seeded `held < requested` shape that 3622's adjust path no longer produces (A2-N-7, comment only); changed tests in §8 |
| ui | `components/handlingUnits/popups/adjustAmount.vue`, `store/handlingUnits/stockUnits.js` | preview, blocked state, copy, `expectedOrderIds` |
| ui | `test/components/handlingUnits/{replenishmentDeferralNote→replenishmentCutNote, reservationHoldersPreview}.spec.js`, `test/store/…` | Jest |
| docs | `3-Resources/design/wms2-stockunit-design.md`, `wms2-replenishment-design.md` | drift fix after merge (incl. D-H1 regrowth, P-3) |

No Flyway migration. No sysprop.

## 5. Implementation steps

### 5.1 Prerequisites
- **PR #444 (SBDEV-3621) merged into wms2-api `develop`.** It was still not an ancestor on 2026-10-02 (develop 09f861da, #444 head 5d1faaca). 3622 uses no HSR code. The reason for waiting is conflict avoidance in ROS/MRS, and that §6's lock analysis was done on the #444 shapes (C-L5). **Branching rule:**
  - Implementation branches off the fresh `origin/develop` **after #444 merges**.
  - If #444 has not merged when the gate runs, stack the wms2-api worktree on `origin/bugfix/SBDEV-3621-release-held-share`. The PR then states the merge order **#444 → 3622**, and it is rebased onto develop once #444 lands.
  - wms2-web-ui always branches off `origin/develop`.
  - Re-run the §0 greps and re-cite moved snippets.
- Check SBDEV-3626 ("in-progress claim", gate commit c99ddaff on a branch) for conflicts in replen-order state transitions at rebase time (critic r2 open question).
- Tell the Cypress e2e owner: `inventory-management.cy.js` resetting reserved to 0 now cancels the DEV order on that SU.
- Baseline: full `mvn test` + `mvn verify`, web-ui `yarn test`, adjacent in time to the final run.

### 5.2 Steps (each ends green except the deliberately-red gate tests)
1. **Gate (wms-tdd-gate):** AC-1..AC-29 (incl. 14b, 17a/b, 18a–c) red for the right reason; mutation-check each new assertion. AC-19 is a pin of accepted behaviour, so it goes green as soon as the cut lands — its red is checked by mutation (skip the requested reset → red).
2. **API: `ReservationCut`** + unit tests (AC-1..AC-9, AC-21, AC-26); PIT (§8).
3. **API: finders, `applyReservedCut`, `markCancelled`, SUS spine, keys, `ORDER BY`, ROMS/`it1` comment rewrites** (AC-10, AC-11, AC-13..AC-15, AC-14b, AC-19, AC-20, AC-22, AC-23, AC-25, AC-28) + update the changed tests (§8).
4. **API: GET + lock-failure catch + `expectedOrderIds` parse + gate rails + bulk pin** (AC-12, AC-16, AC-17a/b, AC-24, AC-27, AC-29); full suite vs baseline; PR into `develop`; merge before step 5's PR.
5. **UI: store + dialog + Jest** (AC-18a..c); PR into `develop` after the API is on dev.
6. **Docs + ticket:** design-doc drift, plan status, ClickUp. The ops release note covers four points:
   - an immediate cancel on a cut to 0, which closes today's re-grant within minutes (§1);
   - partial-cut regrowth;
   - the refill job may create a new order from a freed SU.
   - On hold is **not** a workaround. An SU with any reservation cannot be put on hold. Putting it on hold *after* a cut to 0 is possible, but it moves the unit load to the on-hold location, blocks picks from it, and can still lose the race with the refill run (A2-N-2).

## 6. Horizontal scalability and v2 constraints

| # | Concern | Verdict |
|---|---|---|
| 1 | In-memory state | none; `ReservationCut` static/pure |
| 2 | Multi-instance races | PG row locks (picks → orders ≤ PROCESSABLE asc → SU) |
| 3 | Same direction (order → SU): per-order cron `recalculateOrder`, moved-SU reassign, PR #444 switch, `fulfillMultipleUnitLoadsTx` | no cycle on one SU (A §3 table). `recalculateForItem` locks an item's orders in one tx from an unordered `findIdsByStateAndItemdataId` — two orders on one SU could cycle (C-M2); the sibling `ORDER BY r.id` makes both sides ascending and removes it (0 such SUs on PRD) |
| 4 | **SU → order residuals** | web cancel (PR #444: SU lock then detached `@Version` save); `setLockOnHold` (`@Transactional`) → `triggerReplenishmentMaintenance` → `recalculateForItem` joined in-tx; `recalculateForItem` holding `O_1, SU_1` and a redirect target `SU_x`, then wanting `O_x`. Each can deadlock with 3622; **PG detects it, or the global 5 s `lock_timeout` (SBDEV-3250) bounds it.** Who loses, and the narrow STARTED window: §6.1 |
| 5 | Lock fan-out | ≤ open orders on one SU (PRD max 1) |
| 6 | Query cost | 2 holder probes + 2 scalar queries + N order locks (the preview: 1 probe + `hasActivePickFor` + 2 scalar queries); on `stockunit_id` / `pickfromstockunit_id` (verify `\d replenishorder` in step 3) |
| 7 | Connections | one tx per call (bulk: one per id); no REQUIRES_NEW |
| 8 | Idempotency | re-POST of the same T → `NOOP` |
| 9 | Tenant routing | tenant TM on every tx method (`@Transactional(value="tenantTransactionManager", rollbackFor=…)`, `@TenantTransactionalReadOnly`) |
| 10 | Preview load | read-only, no locks, debounced |

**6.1 Row 4 detail: who loses a deadlock (A2-N-8), and the narrow window (A2-N-4).**

- **3622 loses** → `RESERVATION_CUT_LOCK_BUSY`.
- **The per-order cron loses** → it rolls back that order's recalc and retries next cycle.
- **A joined `recalculateForItem` loses** (inside `setLockOnHold`, or `transferStock` → `createFixedLocationAssignment`) → `triggerReplenishmentMaintenance` **rethrows** `PessimisticLockingFailureException` in a shared tx (SUS ~:153-165, SBDEV-3250). So the victim is **another operator's action**, which fails; nothing retries it. `setLockOnHold` against 3622's own SU is unreachable (it refuses `R > 0`, and a cut needs `R > 0`), so it is reachable only through the cross-SU redirect-target shape.

Handheld finish is no longer on this list, because 3622 never locks a STARTED order (B1c). The one narrow window left: an order read PROCESSABLE at (b) is started before (c) and locked while STARTED; if the picker then finishes inside the same 3622 tx, the M-2 cycle reappears. B1c re-checks the locked entity's state and refuses before taking the SU lock. Even if that check is missed, PG detection or the 5 s bound limits the damage (A2-N-4).

v2 constraints: tenant TM explicit (B, C) · OSIV off — SU re-read under lock, detached controller entity used for the id only · new finders `exported = false` · same function on the GET, rails extended · both bundles, reflection contract · first touch by `findByIdForUpdate` (B1c-d, pinned by AC-23) · no Flyway · no OMS/outbox.

## 7. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Partial cut regrows on the next recalc** (S8: `req' = held` → `bound` returns `capacity`, `updateRequestedAmount` books `+delta` `CODE_REPLENISHMENT` from the freed stock; DEV 31278102 → 31278112) | certain for partial cuts with free stock and a shortage; 0/330 PRD cuts were partial | **accepted (D-H1)**: dialog + release note say so; AC-19 pins it. A cut to 0 cancels and is not regrown (CANCELED is skipped by the recalc) |
| Cut to 0 → generator creates a new order on the freed SU (§2.5) | 14/311 WineCo cuts within 24 h under the status quo (definition and SQL in §1); likely higher once cancel is immediate, since part of the 181 re-grants becomes re-sourcing | not fixed here → **P-3**. The dialog and release note disclose it. There is **no** zero-code workaround: on hold cannot be set before a cut, and set after one it relocates the UL and races the refill run (A2-N-2). M6 measures the rate after deploy |
| SU → order deadlock (§6 r4) | low | PG detection / 5 s timeout → LOCK_BUSY (AC-16); a per-order cron victim retries; a joined-tx victim is another operator's action, which fails (§6 r4) |
| Handheld `startOrder` vs cancel | low (0 STARTED on PRD) | start commits first → re-probe sees STARTED → refuse; cut commits first → start's first read refuses `>= FINISHED`, and its retry branch is probably dead (P-1) |
| Preview/POST drift | low | same builder + planner, including the non-arithmetic refusals (rule 00, AC-26/29); `expectedOrderIds` (including `[]`) → CHANGED on a CUT (AC-22); omitted = server-side re-plan; malformed → keyed refusal |
| Bulk partial failure | by design | per-id error, others commit attributed (AC-24) |
| Ops behaviour change: orders cancel at the click (299/311 WineCo cuts) | certain | dialog lists them; release note |
| Intermediate `R' > A` throw | 0 PRD SUs today | final-only validation (AC-14), defensive |

## 8. Testing plan

One test method per AC. Unit = Mockito; IT = PG Testcontainers on `AbstractReplenishRedirectPgFixture`.

| AC | Behaviour | Test |
|---|---|---|
| AC-1..AC-9 | cases 1–9 of §3A (cut to 0 one/two orders; partial newest-first; surplus only; surplus + order; broken invariant oldest-first alloc; `T < P` refuses and `T == P` allowed; STARTED refuses even surplus-only; increase) — each also asserts the §3A.7 post-conditions | `ReservationCutUnitTest.{cutToZero_oneOrder_cancelsIt, cutToZero_twoOrders_cancelsNewestThenOldest, partialCut_shrinksNewestFirst, cutWithinSurplus_touchesNoOrder, surplusAbsorbedBeforeOrders, brokenInvariant_newestIsTheShortOne, belowOpenPicks_refusesNamingPickingOrders, startedOrder_refusesEvenSurplusOnlyCut, increase_isUnchanged}` |
| AC-10 | detached R 9, locked R 12, T 5 → final 5 | `StockunitServiceUnitTest.adjustReservedAmount_computesFromLockedRow` |
| AC-11 | rows carry number + clamped comment, MANUAL_ADJUSTMENT, surplus row null-order first; **running `reservedamountstock` per row = `[R−u, R−u−d_newest, …, T]`** (A-L1) | `StockunitServiceUnitTest.cut_writesOneAttributedRowPerAffectedOrder` (rows); running `reservedamountstock` per row: `StockunitBusinessServiceUnitTest` (applyReservedCut) + `ReservationCutAttributionIT` on PG |
| AC-12 | GET preview == POST effect (two orders, partial) | `ReservationCutAttributionIT.previewMatchesCommittedCut` |
| AC-13 | committed cut on PG: orders CANCELED/shrunk by id, `R == T`, rows by id | `ReservationCutAttributionIT.cutAttributesAndCancelsInOneTransaction` |
| AC-14 | `R > A` → cut to `T ≤ A` succeeds (intermediates above A do not throw) | `StockunitBusinessServiceUnitTest.applyReservedCut_validatesFinalValueOnly` |
| AC-14b | the final value is still checked: rows whose final R is above A, and rows whose final R is below 0, each throw, with `never()` on `recordChangeReservedAmount` and on save. This kills the "delete the final check" mutant, which AC-14 alone lets survive (critic r2 §4) | `StockunitBusinessServiceUnitTest.applyReservedCut_finalValueOutOfRange_throwsAndWritesNothing` |
| AC-15 | holder set changes between probe and SU lock → `getKey()==RESERVATION_CUT_CHANGED`, message ≠ key, nothing written | `StockunitServiceUnitTest.cut_refusesWhenHolderSetChangesUnderLock` |
| AC-16 | `PessimisticLockingFailureException` on single POST → 200, `errors[0]` = resolved LOCK_BUSY text (≠ key, ≠ "placeholder") | `StockUnitControllerUnitTest.adjustReservedAmount_lockFailure_mapsToRefusalShape` |
| AC-17a | row **C.14** deny: GET `/v3/stockUnit/reservationHolders/1?target=0` without the function → 403 + `X-Authz-Denied`, `previewReservationCut` never called (real guard) | `StockUnitControllerActionGuardUnitTest.reservationHolders_withoutAdjustReservedFunction_isDenied` |
| AC-17b | row **C.14** allow: same GET with `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT` → 200, `previewReservationCut(1L, "0")` called once | `StockUnitControllerActionGuardUnitTest.reservationHolders_withAdjustReservedFunction_isAllowed` |
| AC-18a | **reactivity trap:** dialog fetches from the `show` watcher (not `mounted`), and changing the target **after mount** re-fetches with the new target | `reservationHoldersPreview.spec.js` › `fetches on show and re-fetches when the target changes after mount` |
| AC-18b | stale-drop: a response for a superseded target is discarded (sequence guard); rows render "will be cancelled" / "will shrink to N" for the latest one | `reservationHoldersPreview.spec.js` › `drops a stale preview response and renders the latest rows` |
| AC-18c | Submit disabled while `kind` is `REFUSE_*` (incl. REFUSE_LOCKED / REFUSE_PICK_STARTED); enabled when the preview fails (network/403); a POST refusal shows the existing toast with the dialog open; `expectedOrderIds: []` is sent when the preview loaded with no holders | `reservationHoldersPreview.spec.js` › `disables submit only on a refused plan and sends the preview's holder ids` |
| AC-19 | **pins accepted behaviour (D-H1)**, literal values (A2-N-6, C2-L-n7). Seed `ReplenishmentHeldShareIT.it1`: SU_A amount 18, order X requested 9 and fully held (R 9), default FLA, so the destination shortage is 84. Cut SU_A to 5 → `requested(X) == 5`, `reserved(SU_A) == 5`. `recalculateForItem(ITEM)` → `requested(X) == 18`, `reserved(SU_A) == 18`, and exactly one new `CODE_REPLENISHMENT` row under X with `reservedamountchange == +13`. A 2nd `recalculateForItem` writes no row. X regrows **past** its pre-cut 9 | `ReservationCutAttributionIT.partialCut_regrowsOnNextRecalc_pinsAcceptedBehaviour` |
| AC-20 | STARTED holder on PG → refusal, reserved and orders unchanged by id (split from AC-13, C-L4) | `ReservationCutAttributionIT.startedHolder_refusesAndWritesNothing` |
| AC-21 | `T = −3` → clamped to 0 (case 10); with `P > 0` → REFUSE_BELOW_PICKS | `ReservationCutUnitTest.negativeTarget_clampsToZero` |
| AC-22 | `expectedOrderIds` on a CUT. Each leg is asserted on `getKey()`, with `never()` on `applyReservedCut` / order saves when it refuses:<br>(i) `{1}` vs locked `{1,2}` → RESERVATION_CUT_CHANGED;<br>(ii) **`[]` (empty set) with one holder present under lock → RESERVATION_CUT_CHANGED** (A2-N-1);<br>(iii) `null` → proceeds;<br>(iv) a differing set on an INCREASE → proceeds, so the check is CUT-only | `StockunitServiceUnitTest.cut_refusesWhenExpectedOrderIdsDiffer` |
| AC-23 | `InOrder`: `lockOwningPickingorders` → `replenishorderRepository.findByIdForUpdate(1L)` → `(2L)` → `stockunitRepository.findByIdForUpdate(su)`; `never()` `replenishorderRepository.findById` / `stockunitRepository.findById` in the service | `StockunitServiceUnitTest.cut_locksPicksThenOrdersAscThenStockunit` |
| AC-24 | bulk: one id refused (STARTED) is a per-id error, the others commit (regression pin) | `StockUnitControllerUnitTest.bulkAdjustReservedAmount_refusedIdIsPerIdError_othersCommit` |
| AC-25 | STARTED holder is never locked: `never().findByIdForUpdate(startedId)`; refusal names it + operator ("unknown" if null). Second leg: a holder probed PROCESSABLE whose **locked entity** returns STARTED → REFUSE_STARTED with `never()` on `stockunitRepository.findByIdForUpdate` (A2-N-4) | `StockunitServiceUnitTest.cut_doesNotLockStartedHolder` |
| AC-26 | cases 11–12: `entityLock` SHIPPED / GOING_TO_DELETE → REFUSE_LOCKED; `activePick` → REFUSE_PICK_STARTED, on a cut **and** on an increase; both before any arithmetic | `ReservationCutUnitTest.nonArithmeticRefusals_precedeArithmetic` |
| AC-27 | SUC `expectedOrderIds` parse: `[1, 3000000000]` → `Set.of(1L, 3000000000L)` passed to the 4-arg overload; absent → `isNull()`; `[]` → empty set (not null); `"1,2"` (string) and `[ "x" ]` → 200 with `errors[0]` = resolved `RESERVATION_CUT_EXPECTED_IDS_INVALID` text, service not called | `StockUnitControllerUnitTest.adjustReservedAmount_parsesExpectedOrderIds` |
| AC-28 | `markCancelled(order)` sets CANCELED **and** saves exactly that order, and releases nothing (no `stockunitBusinessService` interaction). ROS delegation is pinned by the changed ROS tests (§8 "Changed tests") | `ReplenishmentOrderMaintenanceServiceUnitTest.markCancelled_setsCanceledAndSaves_releasesNothing` |
| AC-29 | preview parity (C2-N-2): `previewReservationCut` on a SHIPPED SU → `kind == REFUSE_LOCKED`; with `hasActivePickFor` true → REFUSE_PICK_STARTED; and it calls **no** `lockOwningPickingorders` / `findByIdForUpdate` | `StockunitServiceUnitTest.preview_readsPickAndLockStateWithoutLocking` |

**Changed tests (expected reds until updated — do not re-green by loosening):**
- `StockunitServiceUnitTest.AdjustReservedAmount` — `adjustsReservedAmountSuccessfully` (:364), `throwsWhenStockIsShipped`, `throwsWhenPickingHasStarted`, `adjustReservedAmount_doesNotTriggerReplenishmentMaintenance` (:416), and `handlesReservedAmountEqualToTotal` (:1779), `handlesIncreasingReservedAmount` (:1800), `allowsAdjustingReservedAmountToZero` (:1821), `handlesAdjustingAmountOnHoldLock`, `allowsAdjustingReservedAmountWithCreatedPicking` (:1870): add `@Mock`s for the 3 new deps; stub `stockunitRepository.findByIdForUpdate` with the test's R (SHIPPED test: the **locked** row is SHIPPED) and the holder probe → empty; cuts now verify `applyReservedCut` (one null-order surplus row) instead of `changeReservedAmount`; increases still verify `changeReservedAmount` with the delta from the locked row; the no-trigger test keeps `never()` on maintenance.
- `StockunitServiceAuditCommentClampUnitTest.adjustReservedAmount_shouldClampComment_whenCommentExceeds200` (:350): `eq(stockUnit)`/`isNull()` on `changeReservedAmount` → assert the clamped comment on every `applyReservedCut` row.
- `StockUnitControllerUnitTest` (C2-L-n2). Under STRICT_STUBS, change only the **single path**; do not "fix" any red outside it.
  - **Single-path stubs/verifies** (`POST /v3/stockUnit/adjustReservedAmount` nest) move to the 4-arg overload, with `isNull()` for `expectedOrderIds` when the request has no field: :779 + :786 (`adjustsReservedAmountSuccessfully` :771), :800 (`handlesDecimalReservedAmounts` :792), :818 (`returnsErrorsWhenBusinessException` :810), :839 (`returnsErrorsWhenFacadeException` :831).
  - **Bulk stubs stay 3-arg, unchanged**, because bulk keeps calling the 3-arg form: :869, :876 (`adjustsReservedAmountForMultipleUnits` :855) and :890.
- `ReplenishorderServiceUnitTest` `cancelReplenishmentOrder` nest (A2-N-9). Add `@Mock ReplenishmentOrderMaintenanceService` next to the SBDEV-3621 `pickingorderPositionRepository` mock (:92-94); `@InjectMocks` would otherwise pass `null` and NPE. The CANCELED + save assertions move into `verify(maintenance).markCancelled(testOrder)` and are pinned once in AC-28. This applies to:
  - `shouldCancelOrderAndReleaseReservedStock` (~:736);
  - `cancelReplenishmentOrder_sharedSourceStockUnit_releasesOnlyOrderAmount` (:772);
  - `cancelReplenishmentOrder_requestedAmountExceedsReserved_releasesHeldShare` (:794).

  `shouldSkipAlreadyFinishedOrder` adds `never().markCancelled(any())`. The release assertions stay as they are.
- `ReplenishmentOrderMaintenanceServiceUnitTest` `cancelOrder` tests: still assert CANCELED + save through the real `markCancelled`. The class is under test, so nothing is mocked here.
- `ReplenishmentIdProjectionContractUnitTest` (A2-N-3, A2-N-6b):
  - add the holder projection and the pick-number projection names to `newIdProjections_areNotExportedOverSdr`'s enumerated method list (:147-170). That pin is per-method by design;
  - add `findIdsByStateAndItemdataId_ordersById`, which asserts by reflection that the method's `@Query` value ends with `ORDER BY r.id`.
- `ActionGuardAnnotationContractUnitTest` (13 → 14, arity 3, names); `FunctionGuardArchTest` (both `REVIEWED_SHARED_METHOD_GATES` and `REVIEWED_SHARED_GATE_FUNCTIONS` entries, §3C); `StockUnitControllerActionGuardUnitTest` (C.14 legs, DisplayName/javadoc); `replenishmentDeferralNote.spec.js` → `replenishmentCutNote.spec.js`.
- Must stay green unchanged: `MessageKeyConstantBundleContractTest` (it covers the 5 keys), `BatchEndpointPerIdLookupUnitTest`, and `MoveSourceLockComparisonRailTest`. The rail stays green because the variable name is kept and rule 00's comparison lives in `ReservationCut`, outside the rail's primitive-derived scope (§3A).

**Mutation (floor + PIT, JDK 21):** `mvn test-compile && mvn org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.service.ReservationCut,net.aim_ai.wms.service.StockunitBusinessService -DtargetTests=net.aim_ai.wms.unit.service.ReservationCutUnitTest,net.aim_ai.wms.unit.service.StockunitBusinessServiceUnitTest` — **0 surviving mutants on `ReservationCut`**; on SUBS, triage survivors only on `applyReservedCut` lines. Hand mutants on SUS/SUC (not in the PIT scope): swap order/SU lock (AC-23 red); lock STARTED holders (AC-25 red); record before `setReservedamount` (AC-11 red); remove the SUC catch (AC-16 red); revert to detached R (AC-10 red); one-arg `BusinessException(KEY)` (AC-15 red); skip the requested reset on shrink (AC-19 red). Round-2 additions:
- treat `expectedOrderIds.isEmpty()` as absent → AC-22(ii) red;
- run the `expectedOrderIds` check on every kind → AC-22(iv) red;
- parse via `(Integer)` cast → AC-27 red (Long element);
- `markCancelled` without the save → AC-28 red;
- ROS keeps its inline cancel copy → the changed ROS `verify(markCancelled)` red;
- drop `ORDER BY r.id` → `findIdsByStateAndItemdataId_ordersById` red;
- skip the locked-entity state re-check → AC-25 second leg red;
- preview passes `activePick = false` → AC-29 red;
- delete `applyReservedCut`'s final check → AC-14b red. PIT should also flag this one.

Single IT, with the unit lane skipped (C2-L-n1): `mvn verify -Dit.test=ReservationCutAttributionIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`.

**Manual (DEV, after the API deploy):**

| # | Step | Expect |
|---|---|---|
| M1 | Adjust Reserved Amount on SU 929025745, type 0 | dialog lists REPL389508 "will be cancelled" |
| M2 | Submit | REPL389508 state CANCELED; stockrecord `−1`, `ordernumber REPL389508`, comment = typed comment |
| M3 | Seed a STARTED order on a test SU; open the dialog; type a cut | alert names order + operator; Submit disabled; direct POST → one refusal |
| M4 | Increase reserved on any SU | one null-order `+Δ` row, as before |
| M5 | Partial cut on an SU with free stock and a destination shortage; **wait one `ReplenishOrderJob` recalc cycle** (DEV regrew 30685299 within 8 h 19 min — check the job log for the run); re-query `stockrecord` | the order regrows with a `REPLENISHMENT` row under its number (D-H1, accepted) |
| M6 | After M2, wait one refill cycle; query `replenishorder` for SU 929025745 | records whether a new order was created on the freed SU (input to P-3) |
| M7 | After M2, wait one `ReplenishOrderJob` recalc cycle; query `stockrecord` for SU 929025745 | **no** `REPLENISHMENT` row under REPL389508. The §1 re-grant (181/311 on PRD) is closed |

No verify script: every invariant is visible to a JUnit/Jest test.

## 9. Completeness checklist

Sibling sweep ✓ §0 (r2 adds outcome consumers S8–S10) · invariant over instance ✓ §3A.7 · DB evidence ✓ §1 (sourced; r3 adds the N-3 trace and the re-source reconciliation with SQL) · lock order ✓ §3B1, §6 r3–r4, §6.1, AC-23/25 · error shape unchanged ✓ B6–B8 (one additive optional field, three-state contract) · bundles ✓ (5 keys) · gating + rails ✓ §3C (C.14, arity 3, both arch maps) · preview parity ✓ rule 00 · Flyway/sysprop/OMS: none · docs drift ✓ §4, step 6 (incl. ROMS javadoc, `it1` DisplayName).

## 10. Resolved decisions, proposals, ADR

**Resolved (Nam, final):**
0. **Implementation-time decisions and changes (2026-10-02).** (a) **Zero-cut cancel row (Nam):** every order the cut cancels gets a `MANUAL_ADJUSTMENT` row under its number with the operator + clamped comment — amount 0 when nothing was allocated to it (security M-1); supersedes the earlier "cancelled without a ledger row" choice. (b) **Amount parse:** one exact, bounded `ReservationCut.parseAmount` for the preview and both POSTs; out-of-range / >4 decimals / malformed → new key `RESERVATION_CUT_TARGET_INVALID` (zero-param), never echoing the input (code review H, security H-1/L-1). Behaviour change: an amount with more than 4 decimals, or an integer of 14+ digits, is now refused rather than rounded/accepted. (c) `pickOrders` in the preview is filled only on `REFUSE_BELOW_PICKS` (security L-3). (d) Out of scope, noted on the ticket: other `StockUnitController` endpoints still parse amounts via `Double.parseDouble`.
1. Attribute in the same tx; shrink orders `≤ PROCESSABLE` (incl. RAW/ON_HOLD — O-3) to what still fits, cancel at 0; rows `MANUAL_ADJUSTMENT` + number + operator comment (O-2); surplus first, may stay null-order.
2. Any order `> PROCESSABLE` → refuse any cut, even surplus-only, naming order + operator (O-1).
3. Shrink newest-first (created desc, id desc). 4. Cut below open picks → refuse, naming the picking orders.
5. Gated read-only GET preview sharing the pure module; POST keeps its shape + refusal errors; dialog lists orders; bulk button disabled, bulk API follows the rule (O-5). O-4: lock failure → refusal shape.
- **D-H1 (2026-10-02; A-H1 = C-C1): accept partial-cut regrowth and document it.** A partial cut holds until the next recalc; the order then holds all it requests, so `bound` returns `capacity` and `updateRequestedAmount` books `CODE_REPLENISHMENT` from free stock. Live DEV proof: stockrecord 31278102 → 31278112, SU 30685299 / REPL389503. Dialog copy, ADR and release note say so; AC-19 pins it; M5 observes it.
- **D-M6 (2026-10-02): investigate generator re-sourcing; do not widen scope.** Verdict §2.5: it can re-pick → P-3.
- **N-3 trace (2026-10-02, orchestrator, wsl-wineco-prd), recorded without an owner question.** The 181/311 post-cut `REPLENISHMENT` re-reservations are the pre-SBDEV-3618 recalc re-granting the cut, both cron and inline `recalculateForItem` (§1). They are not a human workflow that keeps using the order. So cancel-at-click breaks no workflow and closes the re-grant. This strengthens decision 1.
- **Path shape (C2-L-n6), for Nam's awareness.** Decision 5's ClickUp text says `GET /v3/stockUnit/{id}/reservationHolders`. The plan uses **`GET /v3/stockUnit/reservationHolders/{id}`**, which follows SUC's `/stockunitDetailsById/{id}` convention rather than the SDR association shape (A-L4). Same semantics, different path.

**Proposals (not filed — T3 findings, Nam confirms). Ranked: P-3, then P-2, then P-1.**
- **P-3 — generator re-sources a just-freed SU. FILED 2026-10-02 as SBDEV-3636** (Nam), after the dev test showed it live: REPL389513 created on SU 929025745 ~17–18 s after the cut cancelled REPL389509; the job runs every minute on DEV and PRD. Evidence §2.5: `AND su.reservedamount = 0` is the only reservation predicate, and there is no cooldown.
  - **Blast radius:** WineCo 14/311 cuts to 0 re-sourced within 24 h under the status quo; c1wh 0/19. The definitions and SQL are in §1: 21 counts any creation row in 24 h, 10 counts "first change", 94 counts any window. The rate is likely higher once 3622 cancels at the click, because that removes the item-level `NOT EXISTS` block at once, and part of today's 181 re-grants can then become re-sourcing.
  - **Options:**
    - (a) exclude SUs with a `MANUAL_ADJUSTMENT` cut in the last N minutes from the source query. This is native SQL on `stockrecord` and needs an index check. T3, because it changes cron source selection.
    - (b) an ops procedure: "**after** cutting to 0, put the SU on hold immediately". This is corrected in r3 (A2-N-2). It cannot be done before the cut, because `setLockOnHold` refuses `R > 0`. It relocates the unit load to the on-hold location and blocks picks from it. And it races the refill run (minimum lag 44 s). It is a weak mitigation with an operational cost.
    - (c) leave it. The operator's cut is still attributed; only the new order's reservation is unattributed to their intent.
  - **Recommendation:** (a), **if M6 and the post-deploy re-source rate (re-run the §1 SQL 2–4 weeks after deploy) rise above today's 14/311.** Otherwise (c). Do not promote (b) as a workaround; the release note describes it only with its costs.
  - **Cost:** (a) ~1 day + IT; (b)/(c) a release-note paragraph.
- **P-2 — `changeReservedAmount` validates `> amount` on releases** (A-M7). Apply the check only when `amount.signum() > 0`, then delete the STRANDED skips in ROMS `releaseHeld`/`updateRequestedAmount` and HSR. Blast radius: 25 callers' contract (loosening only); 0 `R > A` SUs on PRD today lowers urgency. Cost ~1 day; T3. `applyReservedCut` is shaped to collapse into a loop over it.
- **P-1 — handheld `startOrder` retry branch** (reframed, A-M4). `replenishorderRepository.save(order)` on a managed entity does not flush, so the `@Version` conflict surfaces at commit, outside `catch (ObjectOptimisticLockingFailureException e)`; the first read already refuses `>= FINISHED`. The branch that "revives" a cancelled order is therefore probably dead; the real defect is a dead catch + a generic handheld error. **Propose only after a PG IT confirms which**; T2 either way.

**Review findings not applied as asked:** C-"real PG 55P03/40P01 IT" (optional) — not added: concurrency ITs here are timing-flaky (OutboxConcurrentEnqueueIT, ReplenishDupConcurrencySliceIT) and the translation is Spring's, already relied on at `PickingController:76`; AC-16 covers the mapping. A-L3 "derive the count from `EXPECTED`" — the `hasSize` literal is the drift alarm, so it is bumped, not derived. (r2's "ROS `markCancelled` reuse is conditional on no bean cycle" is withdrawn: A2-N-9 verified there is no cycle, and B4 is unconditional.) C2-N-2 offered two fixes: model the refusals in the preview, or narrow driver 2. We chose **adding them** (rule 00), so driver 2 is not narrowed. It still has one bound: the preview reflects the state at GET time, and drift after the GET is caught by `expectedOrderIds` (CUT only) or by the server's own refusal. C2-L-n2 is applied as a single/bulk split rather than renumbering the cited lines. Round 2 has **no unapplied finding**.

**Round-2 finding → section map**

| Finding | Sev | Where applied |
|---|---|---|
| A2-N-1 `[]` vs absent; integer elements (was `Number::longValue`, tightened in implementation round 1); bad type → keyed; CUT-only | M | §3B1f, §3B6 (5th key), §3B8, §3D store, AC-22(i–iv), AC-27, AC-18c, mutants |
| A2-N-2 on-hold workaround impossible before a cut | M | §2.5, §3D copy, §5.2 step 6 release note, §7 row 2, P-3(b) + re-rank, ADR consequences |
| A2-N-3 ORDER BY unpinned | L | §0 S9, §8 changed tests (`…_ordersById`), mutant |
| A2-N-4 narrow STARTED window | L | §3B1c locked-entity re-check, §6.1, AC-25 2nd leg, mutant |
| A2-N-5 probe lacks requested/created | L | §3A Input, §3B1b/e, §3B2 builder signature, §4 |
| A2-N-6 AC-19 literals / `it1` seed | L | AC-19 |
| A2-N-6b projections missing from not-exported pin | L | §8 changed tests |
| A2-N-7 `bound` javadoc + `it1` DisplayName stale | L | §0 S8, §4, §5.2 step 3 |
| A2-N-8 joined-tx deadlock victim | L | §6 r4 → §6.1, §7 row 4 |
| A2-N-9 no bean cycle; ROS needs ROMS mock; `markCancelled` mutant | L | §3B4, §3B9, §8 changed tests, AC-28, mutants, this paragraph |
| A2-N-10 C.x needs deny + allow; class text | L | §3C, AC-17a/b |
| C2-N-1 C.14 not C.11; arity 3 + signature; `REVIEWED_SHARED_GATE_FUNCTIONS` | M | §0 G1-G3, §3C, AC-17a/b, §8 changed tests |
| C2-N-2 preview/POST refusal parity | M | §3A rule 00 + cases 11–12, §3C, §3D, AC-26, AC-29, §7, this paragraph |
| C2-N-3 untraced 181 regrowths | M | §1 table + verdict, §2 item 2a, §10 N-3 trace, M7 |
| C2-L-n1 `-Dtest=ZzzNone`; IT package | L | §8 mutation paragraph, §4 |
| C2-L-n2 SUC unit-test stub lines | L | §8 changed tests (single vs bulk) |
| C2-L-n3 6 classes, not 11 | L | §3B9 |
| C2-L-n4 split AC-18 | L | AC-18a/b/c |
| C2-L-n5 `c > U` | L | §3A.7 |
| C2-L-n6 path deviation | L | §3C, §10 |
| C2-L-n7 AC-19 literals | L | AC-19 |
| C2-L-n8 14 vs 21 | L | §1 reconciliation table + SQL, P-3 |
| Critic r2 §4 AC-14 negative case | — | AC-14b, mutant |
| Critic r2 open Qs (SBDEV-3626; preview's `hasActivePickFor` not the authority) | — | §5.1, §3C |

**ADR**
- **Decision:** a pure `ReservationCut` planner shared by a locked write path (picks → orders ≤ PROCESSABLE asc → SU → re-probe) and a read-only preview; one new multi-row SUBS writer; order state/requested set through a shared no-release `markCancelled`.
- **Drivers:** (1) every reserved unit removed below Σheld carries an order number; (2) preview and write must not drift. That is achieved with a shared builder, a shared planner covering the arithmetic **and** the lock/pick-started refusals (rule 00), and `expectedOrderIds` for drift after the GET; (3) no intermediate-state throw, no double release.
- **Alternatives:** (a) N `changeReservedAmount` calls — rejected: per-delta `> amount` check, re-locks per call (the systemic fix is P-2, separate); (b) reuse `cancelOrder`/`cancelReplenishmentOrder` — double release; (c) arithmetic in a `@Service` — rejected on the SBDEV-3618 precedent; (d) client-side preview — duplicates the rule in JS; (e) defer to the cron — rejected by decision 1; (f) a persisted "operator-capped" marker so partial cuts stick — rejected by D-H1 (column + Flyway, and `manuallyoverridepriority` would also stop cancel/redirect); (g) refuse partial cuts on held orders — rejected by D-H1.
- **Why chosen:** one rule in one testable place, two thin consumers; the write path's only new contract is "validate the final value".
- **Consequences:**
  - A cut to 0 cancels at the click and stays cancelled. That closes today's re-grant, in which 181/311 PRD cuts were restored under the same order, mostly within 10 minutes (§1).
  - The generator may still create a **new** order on the freed SU within minutes. That is P-3, and there is no clean zero-code avoidance: on hold works only after the cut, relocates the UL and races the refill run.
  - A **partial cut is honoured only until the next recalc cycle**, when a fully-held order may grow back from free stock (D-H1).
  - The null-order MANUAL_ADJUSTMENT row now means "holder-less surplus or increase".
  - Additions: one more gated GET (arity 3), five keys, one optional POST field with a three-state contract, and a ROS → ROMS constructor edge.
- **Follow-ups:** P-3, P-2, P-1; design-doc drift; e2e owner notice; ops release note; revisit a UI bulk preview only if the bulk button is revived.

## 11. Implementation status (2026-10-02 — PRs open: wms2-api #446, wms2-web-ui #156)

**Branches** `bugfix/SBDEV-3622-adjust-reserved-attributes-cut` in both repos (worktrees `.claude/worktrees/{wms2-api,wms2-web-ui}/SBDEV-3622`).
- **wms2-api** (base: stacked on SBDEV-3621, which merged as #444 on 2026-10-02; `origin/develop` merged in at `a184e828`, incl. #445 SBDEV-3633): `1ab89b9b` TDD gate · `a9fd42fb` ReservationCut planner · `723977b0` locked attributed write path · `484bced7` preview GET, lock-failure refusal, `expectedOrderIds` · `615f80d9` mutation follow-up · `64b3a014` review round 1 (exact bounded parse, ledger row for every cancel, Lows) · `a184e828` merge develop.
- **wms2-web-ui** (base `origin/develop` 3e00a13): `b9b7b04` TDD gate · `0bf3d86` dialog preview · `7efa774` conformance fixes · `a2c855a` review round 1 · `c494ba0` lint · `4f9f86e` review round 2 Lows · `157ef52` round 3 Lows · `47d57e2` round 4 Low.

**Tests.** API full `mvn clean test` at `a184e828`: **7789 run, 0 failures, 1 skipped** (gate commit: 7742 run / 19 failures, all gate tests). ITs: `ReservationCutAttributionIT` 6/0, `ReplenishmentHeldShareIT` 3/0. UI full Jest: **2088 passed, 0 failed**; 5 suites fail to load exactly as at baseline (keycloak-logout-clears-state, labelCsvUpload, telemetry, keycloak-ready, zplPreview — pre-existing, node_modules symlinked from a stale checkout). Every AC (AC-1..AC-29 incl. 14b, 17a/b, 18a/b/c) has its named test; conformance PASS (`.omc/research/SBDEV-3622-conformance.md`).

**Mutation.** API: 17 + 18 + 2 hand mutants, all killed after follow-up tests; PIT `ReservationCut` 48/48 killed, remaining survivors on changed lines are log-only or unreachable-by-construction (dispositioned in `.omc/research/SBDEV-3622-impl-api-report.md`, `-fix-r1-api.md`). UI: every new assertion hand-mutated red; one timeout spec is a labelled regression pin.

**Review lanes** (T3): conformance (verifier, PASS) · code review (1 High: double parse → fixed) · security (1 High: unbounded preview target → fixed; M-1 zero-cut cancel row → owner decision, fixed) · re-review r2 (APPROVE) · scoped r3/r4/r5 on each later Low-fix commit.

**Behaviour changes to call out.** A reserved cut now cancels/shrinks the holding replenishment orders immediately (ops impact: the cron no longer re-grants a cut to 0); partial cuts may regrow on the next recalc (D-H1); an adjust amount with >4 decimals or 14+ integer digits is refused (`RESERVATION_CUT_TARGET_INVALID`); the Cypress e2e that resets reserved to 0 will now cancel DEV orders.

**Not done here:** archive; P-3 filed as SBDEV-3636, P-1/P-2 proposals unfiled; merged + deployed to dev and tested 2026-10-02 (ticket comment); other `StockUnitController` endpoints still parse amounts via `Double.parseDouble` (noted on the ticket).
