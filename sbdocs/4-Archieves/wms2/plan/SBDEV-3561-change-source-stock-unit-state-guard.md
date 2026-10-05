---
title: "Change Source Stock Unit — state guard, candidate validation, locked redirect, 422 contract, UI dispatch, API-path stale-source finish refusal"
ticket: "SBDEV-3561"
ticket_url: "https://app.clickup.com/t/868mafy20"
type: "bugfix"
priority: ""
status: "archived"
tier: T3
repos: [wms2-api, wms2-web-ui]
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-29"
updated: 2026-09-30
revision: "r4 — round-3 mechanical edits (architect SOUND-WITH-CHANGES, critic ITERATE/1 High); r3: D9 reversed, D10 ship + measure P10"
db_verified: true
db_verified_note: "PRD read-only 2026-09-29 (DEV tunnel down): replenishorder states wineco 300=563/700=864/800=60916, hydra 300=2, c1wh-shipitez 300=103/700=4263/800=1125, nywh-shipitez 800=34; stockrecord REDIRECT_REPLENISHMENT_SOURCE = 0 rows on all 4 (positive control REPLENISHMENT_SWITCHED 108/46)"
base_commit: "wms2-api 5d08e9fc, wms2-web-ui a38b798 (moved from 3e10b54 by SBDEV-3564 only; F7 files untouched), wms2-mobile-ui 108b2f5 (read-only reference) — origin/develop, fetched 2026-09-29"
related:
  - "[[SBDEV-3560]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-2074]]"
  - "[[SBDEV-2690]]"
  - "[[SBDEV-3017]]"
  - "[[SBDEV-1714]]"
tags:
  - plan
---

# SBDEV-3561 — Change Source Stock Unit: state guard, locked redirect, live-path characterisation

**Ticket:** [SBDEV-3561](https://app.clickup.com/t/868mafy20) · **Tier:** T3 (data integrity: reservations move between stock units; check-then-act runs unlocked; the contract changes on 3 endpoints; 2 repos) · **Mode:** SHORT
**Evidence:** `.omc/research/SBDEV-3561-analysis.md` (*A§n*), plus the reviews `SBDEV-3561-review-{architect,critic}-r{1,2}.md` (*AR/CR*, suffixed `-r2` for round 2). Every code citation is `git show origin/develop:<path>` at the base commits. Snippets are quoted; a line number is given only where it matters.

## RALPLAN-DR summary

**Principles**
1. **The server guard is the invariant.** The UI only helps. The API refuses whatever the UI sends.
2. **First touch is the lock.** The order and both stock units are read FOR UPDATE the first time this transaction touches them (SBDEV-3244).
3. **One primitive, one guard.** The three web entry points reach one locked, validated method, and they pass ids.
4. **Reuse, don't re-derive.** A target is eligible only if it is in the exact query that built the operator's list.
5. **Refuse where we own the consuming code; measure what we don't fix.**
   - The web endpoints refuse with a 422 the UI can read.
   - The API-only `/checkDestination` finish refuses a stale source.
   - On the live handheld path (`/multi-unitloads`) the stale state is consumed in `applyExplicitSourceToOrder`, which this ticket does not change. That interaction is **characterised by test** (IT-M1/M1b), and its defect is proposed as P10.

**Decision drivers (top 3)**
1. **No reservation moves twice, and no other order's reservation is eaten.** Picked orders sit at PROCESSABLE (300) throughout (H1). The live pick path re-sources the order to whatever unit load the picker scans (`applyExplicitSourceToOrder`). It releases the old SU's **whole** `reservedamount` (P10), and the web redirect becomes a new, operator-driven trigger for that release.
2. **Blast radius.** The hardened cron and move primitives (SBDEV-2074/3244) stay unchanged, and so does the live mobile pick path.
3. **Turning on a dead path safely.** PRD has 0 `REDIRECT_REPLENISHMENT_SOURCE` rows, so the web path has never written. The API guard must reach every environment before the web fix does.

**Viable options**

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. Patch `ReplenishorderService.redirectSource` in place on the Maintenance model. Add an API-path finish refusal. Characterise the live multi-UL interaction** | Touches 1 service, 1 controller and 1 mobile-service branch. Cron, move and live pick paths are untouched. The live interaction is measured rather than asserted | Four re-source writers keep four disciplines (§0). The ABBA residual stays bounded (§7 #8). P10 stays live and gains a trigger, bounded by F3 (R8b) | **Chosen** |
| B. Delegate to `ReplenishmentOrderMaintenanceService.redirectSource` | One implementation | It is `private boolean redirectSource(Replenishorder order, Stockunit currentSource)` and chooses its own candidate. Widening it pulls the operator contract into the cron primitive | Rejected (driver 2) |
| C / B′. A shared guarded `redirectTo(orderId, targetId, code)` | One lock topology | Refactors a hardened primitive for one new caller. Does not touch `applyExplicitSourceToOrder`, where the live stale state is consumed | Deferred (P5) |
| A + fix P10 now | Closes the live defect in the same PR | T3 change to the only live pick transaction (multi-UL, SBDEV-260713 fixes A.2/B). Needs its own ITs and Nam's call. Findings at T3 are proposed, not folded in | Rejected for this ticket (D10: ship + measure, P10 proposed) |
| P8. Wire `startOrder` so that ≤300 means "not being picked" | The state guard would mean what it says | Every picker's flow changes. The live path would still release wholesale in `applyExplicitSourceToOrder` | Rejected (§10 P8) |

---

## 0. Affected sites

**Derivation:**
- (i) **Callers:** `git grep -n -E "redirectSource|updateSourceStockUnit|changeSourceStockUnit|replenishorderService\."` over wms2-api `src/` (A§0).
- (ii) **Writers:** `git grep -n -E "setStockunitId\(|setRequestedlocationId\(" origin/develop -- src/main`, minus model/DTO/cycle-count/receiving. Positive control: our own `replenishOrder.setStockunitId(stockUnit.getId())`.
- (iii) **Bulk:** `git grep -i "update +replenishorder"` finds only `prio` updates (×3).
- (iv) **Finish callers:** `git grep -n -E "finishReplenishmentOrder(WithoutRefill)?\("` gives mobile `ReplenishController` checkDestination and `fulfillMultipleUnitLoadsTx` ×2.
- (v) **UI dispatchers (mobile, CR-H1-r2):** `git grep -n -E "checkSource|checkAmount|checkDestination" origin/develop -- pages components layouts mixins plugins middleware` in wms2-mobile-ui returns **0**. The positive control finds `replenish/submitULBatchToDestination` at `components/replenish/process/selectDestination.vue`.
- (vi) **Tests pinning the finish split branch:** a keyword grep (`differ|split branch|orderStock|DifferentStockUnits`) over every `*Replenish*` test class. `MobileReplenishServiceUnitTest` scores 48. `MobileReplenishServiceH2Test` and mobile `ReplenishControllerUnitTest` score 0 and have no `setSourceStockId(`. The mobile controller test mocks the service with `any()`.
- **Blind spots:** reflection/SpEL, native SQL outside `@Query`, external `/v3` clients, and a computed `dispatch(name)`. None exists in the replenish components (CR-H1-r2 self-audit).

| # | Site | In scope | Where |
|---|---|---|---|
| S1 | `ReplenishorderService.redirectSource(Replenishorder, Stockunit)`: the defective primitive | yes | F1–F4 |
| S2 | `ReplenishorderService.updateSourceStockUnit`: unlocked pre-load (the live web path once Bug 1 is fixed) | yes | F2 |
| S3 | `ReplenishorderService.update(id, stockUnitId, priority)`: pre-load + Bug 7 | yes | F2, F6 |
| S4 | `ReplenishOrderController.changeSourceStockUnit`: controller pre-load (OSIV off); 0 UI callers | yes, KEPT and re-routed | F2 |
| S5 | the 3 web handlers' 200-with-errors | yes | F5 |
| S6 | `updateStockUnitPop.vue`: nonexistent action, unconditional close | yes | F7 |
| S7 | web store `updateSourceStockUnit` (no return); `apiErrorMessage` reads only `errors[0].message` | yes | F7 |
| S8 | `ReplenishorderService.updatePriority`: Bug 7 (live) | yes | F6 |
| S9 | `openRequest.vue` menu on `state < 670`; `changeStockUnit(item)` dispatches not awaited | no | P3 |
| S10 | Maintenance cron `redirectSource` (`order.setStockunitId(candidate.stockUnitId)`) | no (precedent). A second trigger for R8a, and it feeds R8b | §7, R8 |
| S11 | `MobileReplenishService.switchSourceToUnitLoad`: no state check, no order lock, old→new. Reached only via `/checkSource` (**0 UI dispatchers**, v) | no; API-path lock participant | §7 #8 |
| S12 | `MobileReplenishService.update` (`PUT /v3/replenish/order/{id}`, **live**: selectSource → `updateOrderSourceLocation` on every pick where the scanned location differs). Plain `findById`, no lock, no state check; sets `requestedlocationId` without the SU | no; T3 | R3, P9 |
| S13 | `MobileReplenishService.applyExplicitSourceToOrder` (`/multi-unitloads`, **the live pick path**). Plain `findById` template; releases the old SU's **whole** `reservedamount` under `CODE_REPLENISHMENT_FINISHED`; re-points the order to the scanned UL | characterised (IT-M1/M1b, AC13); fix is T3 → **P10** | R8b |
| S14 | `finishReplenishmentOrderInternal` `else if (replenishOrder.getStockunitId() != null)`: the double-release branch | **yes (D8)**, API-path defence | F8a |
| S15 | mobile `ReplenishController.checkDestination`: rebuilds the DTO via `loadOrderById(id)` outside the finish tx; 0 UI dispatchers | yes (optional param), API-path defence | F8b |
| S16 | wms2-web-ui `cypress/e2e/wms/replenishment/replenishment.cy.js`, "PART 2 — Mobile UI Replenish Process": `GET /v3/replenish/checkSource/{orderId}/{ul}` … `GET /v3/replenish/checkDestination/{orderId}/{dest}`. The **only non-unit-test caller** of `/checkDestination`. Its header is stale against the mobile UI | no change. Must stay green: the parameter is optional, and it drives consistent source/order state | §8.4 |
| S17 | wms2-mobile-ui `store/replenish.js` actions `checkSource`/`checkAmount`/`checkDestination`: 0 dispatchers; their screens were deleted in `5200dc4` (2025-10-14); `pages/replenish.vue` renders only `2_source`, `2.5_unitLoad`, `1.5_destination` | no (D9 reversed) | §10 |
| — | `ReplenishGeneratorService` `setStockunitId` ×2 | no; creation only | — |
| — | `ReplenishmentOrderSourceSyncService` `setRequestedlocationId(destinationLocation.getId())` | no; same SU, locked, refuses `>= STARTED` | — |
| T1 | `ReplenishorderServiceUnitTest.RedirectSource.shouldThrowExceptionWhenNewStockUnitHasNegativeReservedAmount` pins the inverted guard | rewrite | U-5 |
| T2 | `ReplenishOrderControllerUnitTest` `isOk()` + `$.errors[0].message` on `/updateStockUnit`, `/changeSourceStockUnit` | flip to 422 | C-1, C-3 |
| T3 | `NeverMatcherNullBlindnessArchTest.PRIMITIVE_MATCHER_INVENTORY` has `"ReplenishorderServiceUnitTest:2"` and `"MobileReplenishServiceUnitTest:12"` (an exact inventory, not a budget) | update by the exact deltas in §8.1 | A0 |
| T4 | `Sbdev3017TrancheGateContextTest`, `FunctionGuardArchTest` name `changeSourceStockUnit` | untouched | — |
| T5 | `ReplenishOrderControllerUnitTest`: rows stubbing/verifying `redirectSource(testReplenishOrder, testStockunit)`; a 200 pin for `updateSourceStockUnit(id, null)` | re-stub to ids | A0.0 |
| T6 | `ReplenishorderServiceUnitTest`: 8 call sites incl. SadPath/EdgeCases stubbing plain `findById` (these become `UnnecessaryStubbingException` under STRICT_STUBS) | re-stub to `findByIdForUpdate` | A0.0/A1 |
| **T7** | `MobileReplenishServiceUnitTest` split-branch pins that F8a turns red (CR-H2-r2): `finishReplenishmentOrder_shouldRecordTransferredSourceUl_whenExplicitSourceDiffersFromOrder` (SBDEV-1714 **AC-5** audit label), `shouldHandleDifferentStockUnitsInOrder` (asserts both releases, `eq(sourceStock)` **and** `eq(orderStock)`), `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer` | invert to refusal. `:2290`/`:2468` are absorbed by U-F1. **Re-home AC-5's audit-label assertion onto the first branch** (U-F8) so SBDEV-1714 keeps a pin. **3 reds expected at A5** | §6 A5, §8.1 |

## 1. Problem

On the web UI, *Internal Ops → Replenishment → Open → Change Source Stock Unit* does nothing: the dialog closes and no request is sent (Bug 1). The API method behind it would:
- re-source an order in any state;
- accept a reserved target, a target of another item, the current source itself, or a locked or lane target;
- do all of this without locks, and report a refusal as HTTP 200.

**What the state guard protects (H1).**
- On origin/develop a live order goes **300 → 700** (finish) or **→ 800** (cron/cancel).
- `startOrder`, the only STARTED writer, is referenced only by its own declaration in src/main, and `resetOrder` is the same (positive control: `requestReplenish(`). PRD has 500 = 0.
- So ≤300 refuses **stale-list redirects of FINISHED/CANCELED orders**, plus 400/500 defensively. Nothing on the server marks an order as being picked.

**The live handheld path** (CR-H1-r2, AR-N1; derivation §0 v):
- The flow is `/loadOrderById` → selectSource `PUT /replenish/order/{id}` (S12) → stage unit loads → selectDestination `submitULBatchToDestination` → `POST /replenish/multi-unitloads` → `fulfillMultipleUnitLoadsTx`.
- The per-step `/checkSource` → `/checkAmount` → `/checkDestination` loop sits inside `/* … */` in `submitULBatchToDestination`, and its components were deleted in `5200dc4`.
- Those endpoints remain **API-reachable**: the Cypress harness S16 and any `/v3` client.
- **Fact for Nam (CR-H1-r2 f): on the live path, the picker's scanned UL always wins.**
  - `applyExplicitSourceToOrder` re-points the order to the scanned UL (`order.setStockunitId(sourceStock.getId())`).
  - S12 has already re-pointed the location on every pick where the scanned location differs.
  - So web "Change Source" changes only **which source the handheld is shown**, until a picker scans.
- **What the web redirect then triggers.** After a redirect A→B, the picker's `/multi-unitloads` on A goes like this:
  - `validateUnitLoadEntry` accepts A, because its availability was restored by our release.
  - `applyExplicitSourceToOrder` releases **B's entire `reservedamount`** (`oldStockOpt.get().getReservedamount().negate()`, `CODE_REPLENISHMENT_FINISHED`).
  - It then reserves A (`reserveExplicitStockForOrder` → `CODE_REPLENISHMENT_CREATED`), and finish books from A.
  - The booking is correct when X is B's only reservation. It eats order Y's reservation if the cron has since placed one on B's remainder (R8b, P10).

**DB evidence.**
- PRD: 0 `REDIRECT_REPLENISHMENT_SOURCE` rows on 4 tenants.
- DEV wineco, 2026-09-29: the r2 probe returned 8 order numbers with `REPLENISHMENT_FINISHED` releases on more than one SU, against 161 with one.
  - **r2 inferred "order-number reuse". That inference was wrong** (AR-N1, CR-M3-r2).
  - Every one of the 8 shows the multi-UL transaction within 10–140 ms: `FINISHED(−, SU1)` → `CREATED(+, SU2)` → `FINISHED(−, SU2)`.
  - Re-measured in round 3 (AR-H1-r3, CR-M1-r3): DEV shows **18 multi-UL transactions, 8 cross-SU and 10 same-SU** (the picker scanning the order's own source).
  - In the 2 cross-SU cases where the release exceeded `requestedamount` (REPL049240 −12 for 5, REPL050660 −12 for 2), **the excess was the same order's own leaked reservation**. The net per-SU `Σ reservedamountchange` before the release was exactly 12 in both, made up of the order's own +5 plus its own `REPLENISHMENT` +7/+10 rows written on 2025-12-05 during the switch storm. **No other order number ever reserved either SU before the release** (400-day window). After it, the post-commit refill did: REPL389452 CREATED +12 on `916462814` and REPL389450 CREATED +12 on `852143738`, each right after the −12 (CR-N2-r4).
  - So these rows show the whole-amount release, **not harm**: the release cleaned up an own leak. **No DEV case of another order's reservation being consumed has been found.** r3's "Two of them are P10 firing" was false.

## 2. Root cause

- **Bug 1: the web dispatch is a no-op.**
  - `await this.$store.dispatch('internalOps/replenishments/updateStockUnit', data)` is followed by `this.close();`. The action is named `updateSourceStockUnit`.
  - `e58d08e` fixed it, and `ba157ae` reverted only this part.
- **Bug 2: no state guard.** `redirectSource` never reads `getState()`.
- **Bug 3: inverted reserved guard.**
  - `if (BigDecimal.ZERO.compareTo(stockUnit.getReservedamount()) > 0)` is true only when reserved < 0, so a reserved target passes.
  - It is pinned by "`The condition seems inverted in the service, but we test actual behavior`".
  - It is the only inverted-intent site among 6 (A§0).
- **Bug 4: no candidate validation.**
  - The item, `!= current`, and the list predicates of `getStockUnitInfoForReplenishment` are all unchecked.
  - For a rackless location, `findById(location.getRackId())` → IAE → 500.
- **Bug 5: unlocked check-then-act.**
  - `replenishorderRepository.findById(id)` and `stockunitRepository.findById(stockUnitId)` run before any lock, and the controller pre-loads the same way.
  - The old SU is released before the new one is reserved.
- **Bug 6: 200-with-errors.** `return ResponseEntity.ok(errorMap);` ×3.
- **Bug 7: boxed identity compare.**
  - `if (replenishOrder.getPrio() != priority)` compares `Integer` with `Integer`. Of the levels `0 / 100 / 1000 / 10000 / 100000`, 3 of 5 lie outside the Integer cache.
  - A same-value save sets `manuallyoverridepriority`. That exempts the order from `recalculateOrder` and from the job's bulk `… AND r.manuallyoverridepriority = false` updates.
  - Both methods can also unbox a null `priority` into `updateReplenishmentOrderPriority(…, int priority)`, which throws an NPE.
- **Bug 8 (D8), API-path only: finish double-releases a stale source.**
  - When `mobileOrder.getSourceStockId()` differs from `replenishOrder.getStockunitId()`, `} else if (replenishOrder.getStockunitId() != null) {` releases `requestedamount` from both SUs.
  - A supplied source id that does not resolve logs `"Cannot find stock. id={}"` and silently falls back to the order's source (AR-M-b, CR-L1-r2).
  - Reachable only through `/checkDestination`, which has 0 UI dispatchers.

## 3. Architecture / key files

```
WEB     openRequest.vue ─▶ updateStockUnitPop.vue ─dispatch(updateSourceStockUnit)─▶ store (true/false)
        POST /v3/replenishOrder/{updateStockUnit|update|changeSourceStockUnit} ─▶ ReplenishOrderController
          └─▶ ReplenishorderService.redirectSource(orderId, newSuId)    [tenantTM, rollbackFor Business/Facade]
               lock order → state ≤300 → self-check → lock SUs ascending id → item/reserved/list membership
               → reserve new (REDIRECT) → release old (REDIRECT; skip if absent) → re-point order
          422 {errors} | 404/409 ProblemDetail (store reads detail)
MOBILE  live:     loadOrderById → PUT /order/{id} (S12) → stage → POST /multi-unitloads
                  → fulfillMultipleUnitLoadsTx → applyExplicitSourceToOrder (S13: release old SU WHOLE; re-point
                    to scanned UL; reserve) → finish (first branch)             [unchanged; IT-M1/M1b characterise]
        API-only: checkSource → checkAmount → checkDestination(id,code[,sourceStockId]) → finish
                  F8a: dto source > 0 && != order source → refuse; F8b: supplied id unresolved → refuse
CRON    ReplenishmentOrderMaintenanceService.recalculateOrder → private redirectSource / cancelOrder  [unchanged]
```

| File | Role |
|---|---|
| wms2-api `service/ReplenishorderService.java` | S1–S3, S8 |
| wms2-api `controller/ReplenishOrderController.java` | S4, S5 |
| wms2-api `service/mobile/MobileReplenishService.java` `finishReplenishmentOrderInternal` | S14 (F8a/F8b) |
| wms2-api `controller/mobile/ReplenishController.java` `checkDestination` | S15 (F8b) |
| wms2-api `repo/jpa/{Replenishorder,Stockunit}Repository.java` `findByIdForUpdate`, `getStockUnitInfoForReplenishment` | reused unchanged |
| wms2-web-ui `updateStockUnitPop.vue`, `store/internalOps/replenishments.js` | S6, S7 |

## 4. Fix design

### F1 — State guard (Bug 2). Threshold is Nam's (2026-09-29), unchanged

- **Allowed:** any `state <= PROCESSABLE (300)`, i.e. 0, 58, 80, 200 ASSIGNED and 300. In practice orders are created at 300.
- **Refused:** a `null` state (fail-closed), and anything `> 300`, via `BusinessException`:
  `"Replenishment order " + number + " is " + stateLabel(state) + " (" + state + "); the source can only be changed while it is PROCESSABLE (≤300)."`
- `stateLabel` is a private switch over 400/500/700/800 with a numeric fallback. No shared helper exists (`git grep -i -E "static String (state|getState)[A-Za-z]*\(int|stateName\("` returns 0).
- The refusals reachable today are 700 and 800. 400 and 500 are defensive.

### F2 — Lock-first, id-based entry (Bug 5); ascending-id SU locks (D7)

`public Replenishorder redirectSource(Long orderId, Long newStockUnitId)`, keeping the same `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
- `updateSourceStockUnit` and `update` delegate with ids. `updateSourceStockUnit(id, null)` keeps today's behaviour: a plain `findById`, no write, 200.
- `/changeSourceStockUnit` is kept (SBDEV-3017 §9.15 dec 6), with its `findById` pair removed.

Sequence inside the transaction. Each `findByIdForUpdate` is that row's first touch.
1. `replenishorderRepository.findByIdForUpdate(orderId)`. If empty, throw `EntityNotFoundException` (404).
2. F1, evaluated under the lock.
3. `Objects.equals(newStockUnitId, order.getStockunitId())` → `"Stock unit <id> is already the source of order <number>; no change made."`. This runs before any SU lock.
4. Take `stockunitRepository.findByIdForUpdate` on `sorted{new, old (if non-null)}`, ascending. A missing new SU throws `EntityNotFoundException`. A missing or null old SU means the release is skipped.
5. F3, then F4.
6. Set `newRequested = requested.min(new.amount)`, commented `// reserved == 0 by F3, so amount is the availability` (CR-L6-r3). The `− new.reserved` term would always be 0 under F3, and PIT would report it as an equivalent survivor, so it is dropped and U-9 pins the `min`. Then:
   - reserve new: `changeReservedAmount(newSu, newRequested, false, CODE_REDIRECT_REPLENISHMENT_SOURCE, number, null)`;
   - if old is present, release it with the **old** requested amount: `changeReservedAmount(oldSu, requested.negate(), true, CODE_REDIRECT_REPLENISHMENT_SOURCE, number, null)`;
   - `setRequestedamount(newRequested)`.
   - A comment forbids catching `FacadeException` here, because the inner proxy marks the transaction rollback-only.
7. Re-point: `setStockunitId`, `setRequestedlocationId(loc.getId())`, `setRequestedrackId(loc.getRackId())` (nullable, Maintenance precedent), `setSourcelocationname(loc.getName())`, then `save`.

**Lock-order decision.** No pair order is cycle-free while the siblings disagree (§7 #8), so we pick ascending ids.
- It closes the one cycle that lies wholly inside our own path: two operator redirects `X: A→B` and `Z: B→A`. Z refuses A, but only after locking it.
- It halves the overlap with recalc.
- It is the P5 end state.
- Every residual cycle is bounded by 40P01 / SBDEV-3250 `lock_timeout`, rolls back fully, and surfaces as a 409.
- Reserve-before-release is kept for SBDEV-2074 M4 parity.

### F3 — Reserved guard (Bug 3)

`if (newSu.getReservedamount() == null || newSu.getReservedamount().signum() != 0)` → `"Stock unit <id> already has a reserved amount (<n>); choose an unreserved stock unit."`.

F3 is also what **bounds R8b**: at redirect time the target has no other reservation.

### F4 — Candidate validation (Bug 4)

Gate: `stockunitRepository.getStockUnitInfoForReplenishment(order.getItemdataId()).stream().anyMatch(v -> Objects.equals(v.getId(), newStockUnitId))`. On a miss: `"Stock unit <id> is not an eligible replenishment source (empty, locked, in a lane, or in a non-replenishment area)."`.
- This is the dialog's own query (AR-M4 confirmed), so it adds no repository method and no predicate copy.
- It returns a projection, so no entity enters the persistence context.
- The auto-flush finds nothing dirty.

**Freshness:**
- The SU predicates are fresh, because the row is locked and a new READ COMMITTED statement reads it.
- The UL/location/area predicates, and the step-7 UL/location read, are point-in-time. The cron has the same TOCTOU. A later `isSourceUsable` → cron redirect heals it (R3).

**Java checks before the gate** (item; F3) exist only for specific messages. The item check is load-bearing against a stale `selectedItem` in the dialog.

### F5 — 422 contract (Bug 6)

- `return ResponseEntity.unprocessableEntity().body(errorMap);` in all 3 handlers, following the precedent of `create`, which returns `ResponseEntity.status(HttpStatus.CONFLICT).body(errorMap)` (SBDEV-2690).
- 404 and 409 stay ProblemDetail, and the store reads their `detail` (F7).
- axios retries only 401/403.

### F6 — Bug 7

`if (priority != null && !Objects.equals(replenishOrder.getPrio(), priority))` in **both** `update` and `updatePriority`. The effects, stated in the PR body (R4):
- (a) A same-value save of 1000/10000/100000 no longer pins the order, so the cron recalc and job re-derivation apply to it.
- (b) Already-pinned rows stay pinned.
- (c) A null priority is a no-op.
- (d) The change goes live with the API deploy.

### F7 — Web UI (re-apply the SBDEV-3560 `e58d08e` hunks, plus error reading)

- `updateStockUnitPop.vue` `update()`:
  `CommUtil.showPageSpinner(this); try { const ok = await this.$store.dispatch('internalOps/replenishments/updateSourceStockUnit', data); if (ok) this.close() } finally { CommUtil.hidePageSpinner(this) }`.
- Store `updateSourceStockUnit`:
  - if `result?.errors?.length`, toast and return `false`;
  - otherwise return `true`;
  - in `catch`, toast `apiErrorMessage(error)` and return `false`.
- `apiErrorMessage` becomes `…errors?.[0]?.message || error?.response?.data?.detail || '…'`. This is benign for the whole module, since no catch-all handler leaks raw text into `detail` (AR-r2 §2d).
- Tests:
  - restore **only** the two SBDEV-3560 describe blocks from `git show ba157ae -- test/` (7 tests);
  - add J-8 (422), J-9 (409 `detail`) and J-10 (spinner hidden on refusal).

### F8 — Finish refuses a stale source (Bug 8; D8). API-path defence only

**Scope label.** F8 is an API-path defence. No production screen reaches it today: `/checkSource`/`/checkAmount`/`/checkDestination` have **0 UI dispatchers** in wms2-mobile-ui (§0 v, with the `submitULBatchToDestination` positive control). F8 hardens the routed endpoint for the Cypress harness (S16) and any `/v3` client. It closes R8a. It does nothing for the live path (R8b).

**Scope of F8a (review api-r1 D2, 2026-09-30).** F8a reads the order **without** a lock. So it covers the **sequential** case: the redirect commits before finish reads. In a true **concurrent** race, `@Version` on the order and SU rows is what stops a stale finish. The picker then gets a 409 ("locked/modified by another operation") rather than F8a's message naming both unit loads. There is no data harm either way. This is deliberate: taking the order lock in finish would add a new lock participant to the live pick path.

**F8a, the refusal.** In `finishReplenishmentOrderInternal`, the `else if (replenishOrder.getStockunitId() != null)` branch becomes:
```java
} else {
    throw new FacadeException(staleSourceMessage(replenishOrder, sourceStock)); // before any changeReservedAmount / transfer
}
```
- The first branch's compare becomes `Objects.equals` (boxed `Long`).
- Message, when the named SU resolves: `"The source of replenishment order <number> was changed to unit load <B-label> at <B-location>; the request named <A-label>. No stock or reservation was booked. Reload the order and retry."`.
- Message, when the named SU does not resolve (CR-L4-r3: there is no SU, so there is no label): `"The source of replenishment order <number> is unit load <B-label> at <B-location>; the request named stock unit <id> (not found). No stock or reservation was booked. Reload the order and retry."`. U-F7 and IT-F2 assert this fixed text.
- **What persists (CR-M4-r2, AR-L-a):**
  - Finish writes nothing, because it is `rollbackFor` Business+Facade.
  - The mobile controller first calls `mobileReplenishService.checkDestination(mOrder, input)` as its **own** committed transaction. So `order.setDestinationId(storageLocation.getId())`, and on a flowbin destination a new FLA with its virtual UL, **stay committed**.
  - A retry is idempotent: re-scanning the same flowbin passes because the FLA's item matches.
- **Response:** the mobile controller catches `FacadeException` and returns 200 `{errors:[{message}]}`. `FacadeException.resolve` falls back to the literal message. There is no screen to show it on today.

**F8b, the optional parameter.**
- `@RequestParam(value = "sourceStockId", required = false) Long sourceStockId` on mobile `checkDestination`. When it is non-null and `> 0`, call `mOrder.setSourceStockId(sourceStockId)` before finish.
- **L1-r2 / N5, with no marker (AR-L1-r3):** in `finishReplenishmentOrderInternal`, when `mobileOrder.getSourceStockId() > 0` and `stockunitRepository.findById` finds nothing, throw the stale-source refusal, **unconditionally**, instead of falling back to the order's source.
  - **Why no marker is needed.** A server-built DTO gets `sourceStockId > 0` only when `setOrderToReplenishMobileOrder`'s `findById(order.getStockunitId())` was present at build time. Otherwise the id stays at `-1` and never enters the `> 0` branch. So on the no-parameter path, "id > 0 but not found at finish" means the SU was deleted between build and finish. Today that either (a) falls back to `findById` of the same id and throws `EntityNotFoundException` (404) anyway, or (b) if the order was re-sourced in between, silently books from the new SU, which is exactly F8's harm. Multi-UL DTOs are built in the same transaction from a just-reserved SU, so they cannot be not-found. So the unconditional refusal is equivalent or safer on every path.
  - **Why no marker is wanted.** `ReplenishMobileOrderDto` is a Jackson POJO bound as `@RequestBody` in 3 handlers and serialised in responses. A Java `transient` field would not hide a getter/setter-backed property, so it would leak into every contract. The r3 DTO change is therefore dropped.
  - The server-rebuilt `-1` fallback is unchanged (U-F3).
- Backward compatible, since the parameter is optional.
- **D9 reversed:** no mobile-UI sender ships.

**No exemption is needed**, derived by reading the 3 finish callers (§0 iv):
- the single flow's DTO is rebuilt from the order;
- the switch saves the order and sets the DTO source together;
- `applyExplicitSourceToOrder` saves the order and then builds the DTO from it (children do the same via `createOrderFromTemplate`).

The first two of those are pinned by U-F5 and U-F6.

## 5. File change summary

| Repo | File | Change |
|---|---|---|
| wms2-api | `service/ReplenishorderService.java` | F1–F4, F6 |
| wms2-api | `controller/ReplenishOrderController.java` | F2, F5 |
| wms2-api | `service/mobile/MobileReplenishService.java` | F8a, F8b (unresolved supplied id) |
| wms2-api | `controller/mobile/ReplenishController.java` | F8b param |
| wms2-api | tests: `ReplenishorderServiceUnitTest`, `ReplenishOrderControllerUnitTest`, `MobileReplenishServiceUnitTest` (incl. T7), mobile `ReplenishControllerUnitTest`, new `ReplenishorderRedirectSourceIT` (incl. IT-M1/M1b), new `ReplenishFinishStaleSourceIT`, `NeverMatcherNullBlindnessArchTest` inventory | §8 |
| wms2-web-ui | `updateStockUnitPop.vue`, `store/internalOps/replenishments.js`, `test/components/opsDialogRefusalSweep.spec.js`, `test/store/opsSaveResultSweep.spec.js` | F7 |

### 5.1 Prerequisites

| # | Prerequisite | Value / action |
|---|---|---|
| 0 | **DB probe** (CR-M3-r2, AR-N4, AR-M2-r3, CR-M1-r3). Read-only on 4 PRD tenants when a tunnel is up; results go to the ticket; does not gate | Classify stockrecord rows per `ordernumber`, ordered by `created, id`. **Multi-UL:** a `REPLENISHMENT_FINISHED` with `reservedamountchange < 0` on SU1, followed within 1 s by a `REPLENISHMENT_CREATED` with `reservedamountchange > 0` on SU2, where **SU2 = SU1 (same-SU: the picker scanned the order's own source) or SU2 ≠ SU1**. Excluded from the double-release count. **Double-release signature (Bug 8):** two `FINISHED(−)` rows on distinct `fromstockunitidentity` with **no** `CREATED(+)` between them. **P10 harm:** at a multi-UL release on SU1, some **other non-null `ordernumber`** holds a positive net `Σ reservedamountchange` on SU1 over all rows before the release. **Own-leak bucket** (reported separately): a release greater than the order's latest requested amount with no other-order net reservation on SU1. The whole release clears the order's own over-reservation. **Ambiguous flag** (set *alongside* P10 / own-leak, not a bucket of its own; CR-N3-r4): SU1 carries rows with NULL `ordernumber` (the Dec-2025 SWITCHED/CANCELLED storm writes CANCELLED with NULL). The first CREATED is **not** a baseline, since recalc and other rows change an order's reservation after creation. **Positive controls:** (a) the single-SU finished count; (b) REPL049240 and REPL050660 classify as **multi-UL cross-SU, P10 = no, own-leak, ambiguous flag set** (both SUs carry NULL-ordernumber CANCELLED rows: −11125 and −4452); (c) **REPL050443** (same SU `21568079`: +53, +29, −82, all its own) classifies as **multi-UL same-SU, P10 = no**. A true-P10 shape reference exists only after IT-M1b runs (its measured rows) |
| 1 | DB state | N/A (no Flyway) |
| 2 | Flags / sysprops | N/A |
| 3 | Config / env | N/A |
| 4 | **Deploy order, per env** | **wms2-api before wms2-web-ui in every env (dev, UAT, PRD); never the UI alone.** On an old API the web fix would hit the inverted-guard `redirectSource` **and** show success. **Dev:** PR-B merges only after the PR-A SHA shows on `/api/public/version`. **UAT/PRD:** the PR-B body and the release ticket carry "wms2-web-ui SBDEV-3561 must not be promoted to an env until wms2-api SBDEV-3561 is running there — check `/api/public/version` on that env". **Rollback:** revert B before A, in every env |
| 5 | Data migration | N/A |
| 6 | External systems | N/A |
| 7 | Access | Unchanged (`WEB_UI_VIEW_REPLENISHMENT_ORDER`); P1 |
| 8 | Monitoring | One week after the web deploy, on 4 PRD tenants: per `ordernumber`, `REDIRECT_REPLENISHMENT_SOURCE` rows should number **2, or 1 when the old SU was absent**; list singletons. For redirected orders, re-run the #0 classifier to count **P10 harm after a redirect** (the #0 definition: another order's positive net reservation on the released SU), separately from the own-leak bucket (R8b). **F8 refusal WARNs will read 0 on PRD by construction**, since no production screen calls `/checkDestination`. A zero is **not** evidence that the race never happens |

## 6. Implementation steps

The worktrees are `.claude/worktrees/wms2-api/SBDEV-3561` and `.claude/worktrees/wms2-web-ui/SBDEV-3561`, each off freshly fetched `origin/develop`. PRs go into `develop` only. Tests come first, and each must be red **on an assertion**, not on a compile error.

**wms2-api (PR-A)**
- **A0.0 — compile staging (CR-M1-r2). Choice: keep the entity overload `public @Deprecated` until A1.**
  - Add `public Replenishorder redirectSource(Long orderId, Long newStockUnitId)` as a thin delegate (`findById` ×2 → the legacy body).
  - Mark `redirectSource(Replenishorder, Stockunit)` `@Deprecated(forRemoval = true)`. It stays public, because `ReplenishOrderController` (package `controller`) still calls it until A2.
  - Re-stub T5 and T6.
  - The suite stays green; this is a structural commit.
  - Why this choice rather than moving the re-route here: A0.0 then changes no behaviour, so each later commit's diff stays attributable.
- **A0 — tests.**
  - Rewrite T1. Add U-1…U-14b, U-F1…U-F8, C-1…C-5, M-1/M-2. All must be red on assertions against the delegate.
  - **Matcher rule (H3-r2 / N2):** inside `never()`, use **bare `any()` on every reference or boxed position, including `Long` ids** (`findById(any())`, `findByIdForUpdate(any())`). Use `anyBoolean()`/`anyInt()` **only where the declared parameter is primitive**.
  - Update `PRIMITIVE_MATCHER_INVENTORY` by exactly the §8.1 deltas.
  - IT fixture ids come from a swept band: `git grep -n -E "99[0-9]{2}L" -- src/test`, 9990–9999 suggested.
- **A1:** F1–F4. Delete the deprecated overload.
- **A2:** F2 entry points and the controller re-route.
- **A3:** F5.
- **A4:** F6.
- **A5:** F8a + F8b. **3 reds are expected (T7).** Invert them to refusal and re-home the AC-5 audit label (U-F8). Any *other* red is a regression, not an expected casualty.
- **A6:** ITs (§8.3, including IT-M1/M1b), the full suite, then the §8.4 gate. The PR body states R8b, the per-env promotion rule, F6's live effect, and the S12/S13 "scan wins" fact.

**wms2-web-ui (PR-B, merged only under §5.1 #4)**
- **B1:** restore the two describe blocks and add J-8…J-10 (red).
- **B2:** F7, then full Jest vs the baseline.

## 7. Horizontal scalability and v2 constraints

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | stateless |
| 2 | Connection pool math | No | +1 short query |
| 3 | Scheduled jobs | No | cron unchanged; serialises on the order lock |
| 4 | Long transactions | No | ≤3 row locks, ≤2 `changeReservedAmount`, no I/O |
| 5 | Request affinity | No | — |
| 6 | Retry / idempotency | Yes, safe | a repeat redirect → "already the source; no change made" (IT-1b); a repeat finish → `REPLENISH_ALREADY_FINISHED` |
| 7 | Tenant context | No | request thread |
| 8 | Distributed lock correctness | Yes | see below |
| 9 | Cache invalidation | No | `git grep -n -E "@Cache(able\|Evict\|Put)" origin/develop -- src/main \| grep -i -E "replenish\|stockunit"` = 0 (positive control: `ClientController` 8×) |
| 10 | External notifications | No | none |

**#8 in detail (AR-N3, CR-M2-r2).** We lock the order FOR UPDATE, then the SUs in ascending id. The other lockers:
- **Order-first partners:** recalc (current→target) and move/reassign (target→current). Same-order collisions serialise on the order lock. Different orders can still cycle on SUs.
- **SU→order partners**, each of which locks SUs via `changeReservedAmount` and UPDATEs the order row at flush. These are **inverted on the order axis**:
  - the mobile switch (API-path only);
  - the mobile finish (`changeReservedAmount`/transfer, then the order UPDATE);
  - **the live `/multi-unitloads` transaction**: plain `findById(template)`, `save` in `assignDestinationForMultiUnitLoads`, then `applyExplicitSourceToOrder` locks the old SU and then the scanned SU.
- In every case the loser gets 40P01 or `lock_timeout`, a full rollback and a 409 (web: store `detail`; mobile: `toastApiError` reads `detail`). There is no corruption. `@Version` on `Replenishorder` catches a sequential stale save.
- **The overlapping multi-UL-vs-redirect case is unmeasured.** Whether the dirty template flushes before the first SU lock depends on Hibernate's AUTO flush query spaces. IT-M1 measures the **sequential** case only (R10).

| v2 constraint | Compliance |
|---|---|
| No JPA associations; compare by id | `Objects.equals` on boxed `Long`/`Integer` (F2, F4, F6, F8a) |
| First-touch lock (SBDEV-3244) | F2 steps 1/4; U-10 |
| OSIV off | no detached entities from the controller |
| Tenant TM on writes | kept; `rollbackFor` Business+Facade (checked) |
| Reserve-before-release (SBDEV-2074 M4) | F2 step 6 |
| Function gating | unchanged |
| Repo tests commit | ITs assert by id; `wipe()` |
| Merge to develop = dev deploy + Flyway | no migration; §5.1 #4 |

## 8. Testing

### 8.1 Unit tests

Matcher rule (A0). In `never()`, bare `any()` on reference/boxed positions, and a primitive matcher only on a declared primitive. `StockunitBusinessService.changeReservedAmount(Stockunit, BigDecimal, boolean zeroIfNegative, String, String, …)` has one primitive (param 3).

**Inventory deltas.** Each class gets one helper holding the new `never()` spans, so the deltas are fixed:
- `ReplenishorderServiceUnitTest`: `assertNoReservationChange()` = `verify(stockunitBusinessService, never()).changeReservedAmount(any(), any(), anyBoolean(), any(), any(), any())`. This gives **+1, 2 → 3**. The new `findById(any())` and `findByIdForUpdate(any())` spans add 0.
- `MobileReplenishServiceUnitTest`: `assertNothingBooked()` = the same `changeReservedAmount` span (+1), plus `never().transferStockToUnitLoad(…, anyBoolean(), anyBoolean())`. The latter has two declared primitives (`ignoreLock`, `removeUnitLoadIfEmpty`, per the rail's own javadoc), so +2, and every reference position is `any()`. This gives **+3, 12 → 15**. The T7 inversions remove no counted span: `:2469`'s `anyBoolean()` sits in a `when(...)`, not a `never()`.
- A5 re-measures both with the rail and records the numbers. A mismatch means a span shape is wrong. Do not bump the inventory to fit.

`ReplenishorderServiceUnitTest` `@Nested RedirectSource`, STRICT_STUBS:

| ID | Test | Asserts | Kills |
|---|---|---|---|
| U-1 | `redirect_refusesFinished700_andCanceled800` (**primary**) | message has "FINISHED (700)" / "CANCELED (800)"; `assertNoReservationChange()`; paired positive row U-3 | drop F1 |
| U-2 | `redirect_refusesReserved400_andStarted500` (**defensive**) | refused | `> 300` → `>= 500` |
| U-3 | `redirect_allows300_200_0` | allowed; reserve and release happen | `>` → `>=` |
| U-4 | `redirect_refusesNullState` | refused | drop the null term |
| U-5 | **T1 rewrite** `redirect_refusesTargetWithReservedAmount` (5) | refused, names 5 | inverted guard |
| U-6 | `redirect_refusesTargetOfDifferentItem` | "different item" | drop the item check |
| U-7 | `redirect_refusesTargetEqualToCurrentSource` (ids ≥ 128) | "already the source; no change made"; `verify(stockunitRepository, never()).findByIdForUpdate(any())`; paired with U-10's positive `findByIdForUpdate` rows | `Objects.equals` → `==`; check moved after lock |
| U-8 | `redirect_refusesTargetNotInEligibleList` | refused | drop `anyMatch` |
| U-9 | `redirect_shrinksToAvailable_releasesOldRequested` | reserve = `min`; release = old requested | swap order |
| U-10 | `redirect_locksOrderThenSusAscendingThenReservesThenReleases` (param: new<old, new>old) | `inOrder`: order FU → min FU → max FU → list query → reserve(new) → release(old). `verify(replenishorderRepository, never()).findById(any())`, `verify(stockunitRepository, never()).findById(any())`, `verifyNoMoreInteractions(stockunitRepository)` (UL/location repos excluded) | new-first; plain `findById` |
| U-11 | `redirect_missingOldSource_skipsRelease`, `redirect_nullOldStockunitId_skipsRelease`, `redirect_racklessLocation_setsNullRack` | no release; rack null | `orElseThrow` |
| U-12 | `updateSourceStockUnit_update_delegateById`; `updateSourceStockUnit_nullSu_returnsOrderNoWrite` | delegation; no pre-load | pre-load |
| U-13 | `updatePriority_sameHigh10000_isNoOp` + `updatePriority_sameNormal100_isNoOp` | **Construction (L3-r2):** stub `order.getPrio()` to return `Integer prio = new Integer(10000)` under `@SuppressWarnings("removal")`; pass `Integer.valueOf(10000)`; assert `isNotSameAs` first (the test proves its own premise), then assert no save and the flag untouched. The ≤127 row passes before and after | revert to `!=` |
| U-14 / U-14b | `update_nullPriority_noNpe`, `updatePriority_nullPriority_noNpe` | no NPE, no save | drop `priority != null` |

`MobileReplenishServiceUnitTest` `@Nested FinishStaleSource`:

| ID | Test | Asserts |
|---|---|---|
| U-F1 | `finish_dtoSourceDiffersFromOrder_refuses` (absorbs T7 `:2290`, `:2468`) | `FacadeException` naming both labels; `assertNothingBooked()`; no save |
| U-F2 | `finish_dtoSourceEqualsOrder_proceeds` (ids ≥ 128) | one release, as today |
| U-F3 | `finish_dtoSourceMinusOne_fallsBackToOrderSource` | first branch (today's server-rebuilt `-1` recovery) |
| U-F4 | `finish_orderStockunitNull_dtoSource_proceeds` | first branch |
| U-F5 | `switchSource_thenFinish_proceeds` | switch-built DTO matches the order |
| U-F6 | existing multi-UL finish tests stay green | `applyExplicitSourceToOrder` path unaffected |
| U-F7 | `finish_positiveSourceIdUnresolved_refuses` (L1-r2 / N5, no marker) | `sourceStockId > 0`, `findById` empty → the fixed "stock unit <id> (not found)" refusal text; `assertNothingBooked()` |
| U-F8 | **T7 `:2000` re-home (CR-M2-r3)** `fulfillMultiple_recordsScannedUlLabel_whenScannedDiffersFromOrderSource`, in the `fulfillMultipleUnitLoads` nest | template `stockunitId` = the SU on "UL-ORDER"; the request scans "UL-SCANNED"; assert `movedSourceUnitloadLabel == "UL-SCANNED"`. That is the guarantee `:2000` really pins: the **transferred** UL's label, not the order's original source. After F8a its live analogue is the multi-UL path, where `applyExplicitSourceToOrder` re-points the order before finish captures the label, and today no `getMovedSourceUnitloadLabel` assertion sits in that nest. The same-source case is **already** covered by `:1764` `finishReplenishmentOrder_shouldRecordPreMoveSourceUl_whenSourceReHomedToDestination`. Green before and after (a re-home). **Kill:** capture the label from the order's original SU before `applyExplicitSourceToOrder` |

### 8.2 Controller tests (`BaseControllerUnitTest`)

- **C-1…C-3:** the 3 web endpoints refused → 422 + `$.errors[0].message` containing "CANCELED (800)". C-3 also verifies `redirectSource(id, suId)` and that the controller calls no repository.
- **C-4:** success → 200.
- **C-5:** `PessimisticLockingFailureException` → 409 `detail`.
- **M-1:** mobile `checkDestination?sourceStockId=` sets the DTO source before finish.
- **M-2:** without the parameter, unchanged.

### 8.3 Integration tests (`BasePostgresIntegrationTest`, commit semantics, assert by id)

`ReplenishorderRedirectSourceIT`:
- **IT-1 (AC3):** A→B. The order points at B; A −req, B +req; `REDIRECT_REPLENISHMENT_SOURCE` = 2.
- **IT-1b:** repeat → refused; still 2.
- **IT-2 (AC1 primary):** 700 / 800 → refused naming the state; nothing written; `version` unchanged.
- **IT-3 (AC2):** B.reserved = 5 → refused.
- **IT-4 (AC5):** parameterised over su/ul/loc/area `entity_lock`, `useforreplenish = false`, staging lane, transfer lane, `amount = 0` → each refused. Positive control: IT-1's B.
- **IT-C1 (AC6):**
  1. T1 = `TransactionTemplate { maintenance.recalculateForItem(item) }` with A unusable and **no** cron candidate existing yet. The cron cancels X (800) while holding X FOR UPDATE, then waits on a latch.
  2. The test inserts eligible B.
  3. T2 `redirectSource(X, B)` must be **blocked**, polling `pg_stat_activity.wait_event_type = 'Lock'`.
  4. Release the latch. T2 refuses "CANCELED (800)", and B.reserved = 0.
- **IT-C2 (AC6):** the IT-C1 harness ordering (L4-r2), so the cron's candidate set is fixed.
  1. At T1's recalc, **C is the only eligible candidate**, because **B is inserted only after T1 latches**. The cron therefore deterministically switches X from A to C, with no reliance on the `ORDER BY su.amount DESC` / area comparator.
  2. T2 `redirectSource(X, B)` waits, then proceeds on the fresh row.
  3. Assert: A released once (cron), C.reserved = 0 (released by us), B.reserved = req.
- **T-9 (AC10):** fixture: **B on a different location than A** (otherwise the kill below survives, because a dropped `setRequestedlocationId` still leaves a matching id; CR-N5-r4). After IT-1, `maintenance.recalculateForItem(itemId)`. The source stays B. Caveat R3: S12 undoes it on the next differing location scan. It is green before and after (legacy also sets `requestedlocationId`), so it is a pin, not red-first. **Kill (CR-L7-r3):** drop `setRequestedlocationId(loc.getId())` from the new `redirectSource` body; `isSourceUsable` then fails and the cron re-sources, so T-9 goes red.
- **IT-M1 (AC13) — the live-path characterisation.** It measures only the sequential interleaving; the overlapping one is unmeasured (R10).
  - **Entry point (AR-M1-r3, CR-H1-r3):** call `mobileReplenishService.fulfillMultipleUnitLoadsTx(request)` on the **injected bean**. It is `public` and `@Transactional`, so the proxy engages, and it is exactly the transaction being characterised. Do **not** call the wrapper `fulfillMultipleUnitLoads`.
    - The wrapper runs `self.fulfillMultipleUnitLoadsTx(request)` and then, after commit and inside a best-effort `catch (Exception e) { LOG.warn(...) }`, runs `replenishGeneratorService.refillFixedLocations()` and `replenishmentOrderMaintenanceService.recalculateOpenOrders(true)`.
    - `assignDestinationForMultiUnitLoads` creates the flowbin FLA with the default bounds lower 36 and upper 84. After X moves 5, the bin is below its lower bound and no active order exists for the item. So the refill creates a new order under another number and reserves B (now unreserved and eligible) and/or A's remainder.
    - `recalculateOpenOrders(true)` sweeps every PROCESSABLE order in the shared, committed IT database, including Y in IT-M1b.
    - DEV shows exactly this: within 0.6 s of REPL049240's multi-UL finish, a different order, **REPL389452**, wrote `REPLENISHMENT_CREATED +12` on the SU that had just been released.
    - The Javadoc states that the post-commit refill and recalc are excluded on purpose: they are best-effort, they create new orders under other numbers, and they would perturb A, B and Y.
    - A wrapper-level variant (with the FLA `lowerbound ≤` the post-transfer amount and `Y.manuallyoverridepriority = true`) is **not** added here. It belongs to the P10 ticket, where the post-commit effect on Y matters.
  - **Fixture (CR-M3-r3, AR-L2-r3):**
    - order X on A (req 5, A.reserved 5);
    - **A.amount > 5** (e.g. 20), so the move is partial and "A booked −5" is well-defined;
    - a **flowbin destination** carrying the item's FLA;
    - B eligible, reserved 0.
  - **Steps:**
    1. `redirectSource(X, B)`.
    2. `mobileReplenishService.fulfillMultipleUnitLoadsTx(request)`, where the request is `{orderId: X, unitLoads: [{id: A.ul, locationId: A.loc, qty: 5}], destination…}`.
  - **Asserts:**
    - X.state = 700 and X.stockunit_id = A;
    - A.amount decreased by 5; A.reserved = 0, B.reserved = 0;
    - **isolation:** no replenishorder other than X exists for the item after the call (the positive statement that the harness is isolated);
    - **reservation rows** for X's number (`reservedamountchange IS NOT NULL`), as an **exact ordered sequence** by `created, id`:
      1. `REDIRECT_REPLENISHMENT_SOURCE` (+5, B)
      2. `REDIRECT_REPLENISHMENT_SOURCE` (−5, A)
      3. `REPLENISHMENT_FINISHED` (−5, B), the `applyExplicitSourceToOrder` whole release
      4. `REPLENISHMENT_CREATED` (+5, A)
      5. `REPLENISHMENT_FINISHED` (−5, A)
    - **transfer rows, asserted separately:** one `REPLENISHMENT` row with `amount = −5` on A and one with `+5` on the destination SU. The FLA/partial branch of `transferStockToUnitLoad` writes `recordRemoval` + `recordCreation`, as DEV REPL050443 shows. The destination SU may be created by the transfer, so its id is read after the call.
  - Green before and after by design (a characterisation, D10). **Kill (CR-L7-r3):** delete the old-SU `changeReservedAmount` release in `applyExplicitSourceToOrder`. Row 3 disappears and B.reserved stays 5, so both go red. (The critic's suggested mutant, releasing `requestedamount` instead, survives IT-M1 because X is B's only reservation and 5 = 5. IT-M1b goes green under it **too**, so IT-M1b alone cannot tell the rejected requested-based fix from the P10 direction. The own-leak IT listed under P10 Cost is what separates them; CR-N1-r4.)
- **IT-M1b — P10 characterisation.** `@Disabled("P10 — SBDEV-3561 characterises, does not fix")`. Same `fulfillMultipleUnitLoadsTx` entry point.
  - **Setup (AR-L3-r3):** as IT-M1, then after step 1 the **fixture places Y directly**. Do not use the generator, whose candidate choice is comparator-dependent.
    - Y is a PROCESSABLE order on B with its own destination (because of `idx_replenishorder_active_item_dest`) and requestedamount 3.
    - `stockunitBusinessService.changeReservedAmount(B, +3, false, CODE_REPLENISHMENT_CREATED, Y.number, null)`.
    - **Premise asserts before step 2:** B.reserved = 8, and **B.amount ≥ 8** (otherwise Y's reserve throws `CANNOT_RESERVE_MORE_THAN_AVAILABLE`).
  - **Isolation assert:** no replenishorder other than X and Y exists for the item after the call.
  - **Assert:** B.reserved = 3, i.e. Y's reservation survives.
  - **Value it produces today (derived by reading `applyExplicitSourceToOrder`):**
    - `B.reservedamount = 0.0000` (expected 3);
    - the `REPLENISHMENT_FINISHED` row on B has `reservedamountchange = −8.0000`, the whole 8 rather than X's 5;
    - Y still points at B with requestedamount 3, and 0 of it is reserved. Y's later finish clamps at 0 via `zeroIfNegative`.
  - **A6 runs it once with `@Disabled` removed** and records the **measured** values in the `@Disabled` reason and in §11. If they differ from the derived values, P10's evidence is re-stated before the PR.

`ReplenishFinishStaleSourceIT` (AC11, API path). Driven through MockMvc on the mobile `ReplenishController`, using the **`IdempotencyFilterIT` pattern (CR-L5-r3)**: `MockMvcBuilders.standaloneSetup(controller)` on `BasePostgresIntegrationTest`. That skips the security and tenant filters and leaves `@AuthenticationPrincipal` null, which the handler tolerates. Do **not** use `@AutoConfigureMockMvc`, which pulls in the Keycloak / `X-Tenant-ID` filter chain.
- **IT-F1:**
  1. Order X on A. `GET /v3/replenish/checkSource/X/<A-label>` records `picked = A`.
  2. Redirect X→B, parameterised: (a) `redirectSource`, (b) the cron `recalculateForItem` with A unusable.
  3. `GET /v3/replenish/checkDestination/X/<dest>?sourceStockId=<A>`.
  - Assert the refusal names both labels; the reservations are exactly post-redirect; 0 `REPLENISHMENT_FINISHED` rows for X; X.state = 300; no transfer.
  - **Persisted, asserted explicitly (M4-r2):** X.destination_id = dest. For a flowbin dest, the FLA row count +1.
- **IT-F2:** `?sourceStockId=<deleted id>` → refused (U-F7 end-to-end).
- **IT-F3:** finish first (700), then the web redirect → refused naming FINISHED (700).

### 8.4 Jest, commands, gate

**Jest (web):** J-1…J-7 (restored), J-8 (422 → `false`, server text, dialog open), J-9 (409 `detail`), J-10 (`hidePageSpinner` on refusal). Use the nvm-node recipe.
- The web-ui base is now `a38b798`. SBDEV-3564 added `test/store/commitNamesExist.spec.js`, a store-wide rail for unknown `commit` names (CR-L1-r3). It **will scan F7's edits**, so every `commit(...)` in `replenishments.js` must name a real mutation.
- That rail's own header says it cannot see a `dispatch` of an unknown action, which is exactly Bug 1. So J-1…J-7, including "dispatched action name is a key of the module's actions", remain the only guard.
- The Jest baseline count moved with SBDEV-3564. Take it fresh on `origin/develop`.

**Commands (H4-r2, CR-L2-r3).** **Never run Maven concurrently with another Maven run.** The ITs share one reusable postgres container, and a peer force-removes it, which gives false reds. Run `pgrep -fl maven` (or `pgrep -fl surefire`) first, and wait if anything is listed.
```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
"$JAVA_HOME/bin/java" -version 2>&1 | grep -q '"21' || { echo 'JDK 21 required'; false; }   # JDK 25 = silent PIT 0%; `false`, not `exit`, so an interactive shell survives
LOG=/Users/np1076/dev/spk/owl/.omc/logs; mkdir -p "$LOG"; set -o pipefail
pgrep -fl 'maven|surefire|failsafe' && { echo 'another Maven run is active — wait'; false; }
# baseline: a DETACHED origin/develop worktree, adjacent in time to the post-change run
git -C /Users/np1076/dev/spk/owl/v2/wms2-api fetch origin
git -C /Users/np1076/dev/spk/owl/v2/wms2-api worktree add --detach /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3561-baseline origin/develop
( cd /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3561-baseline && mvn clean verify 2>&1 | tee "$LOG/SBDEV-3561-baseline-$(date +%Y%m%d%H%M).log" )
# the rest run in the ticket worktree /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3561
# both ITs (*IT.java is in failsafe <include>**/*IT.java</include>; comma-separated, never `+`)
mvn clean verify -Dit.test=ReplenishorderRedirectSourceIT,ReplenishFinishStaleSourceIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false 2>&1 | tee "$LOG/SBDEV-3561-it-$(date +%Y%m%d%H%M).log"
# PIT, scoped (pom recipe), incl. the mobile controller for F8b
mvn clean test-compile org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses='net.aim_ai.wms.service.ReplenishorderService,net.aim_ai.wms.service.mobile.MobileReplenishService,net.aim_ai.wms.controller.mobile.ReplenishController' \
  -DtargetTests='net.aim_ai.wms.unit.service.ReplenishorderServiceUnitTest,net.aim_ai.wms.unit.service.mobile.MobileReplenishServiceUnitTest,net.aim_ai.wms.unit.controller.mobile.ReplenishControllerUnitTest' \
  2>&1 | tee "$LOG/SBDEV-3561-pit-$(date +%Y%m%d%H%M).log"
```
- Verified 2026-09-29: `/usr/libexec/java_home -v 21` → `/Users/np1076/Library/Java/JavaVirtualMachines/ms-21.0.8/Contents/Home`. The test class paths exist on origin/develop.
- Never use `-Dit.test='!X'` or a standalone `failsafe:integration-test`. `mvn clean` after a constant mutant.
- S16 (Cypress) is run once against dev after PR-A (P2.5–P2.7), since it is the only non-unit caller of `/checkDestination`.

**Gate (the floor, T3):**
1. Mutation-check every new assertion with an attributed kill (§8.1 "Kills"; IT-2/3/4/F1 by reverting F1/F3/F4/F8a in turn).
2. PIT survivors in `redirectSource`/`update*`/`finishReplenishmentOrderInternal`/`checkDestination` are triaged in the PR. There is no expected equivalent survivor on `newRequested`, because the `− new.reserved` term was dropped (F2 step 6).
3. Full `mvn verify` vs the baseline log. Flaky ITs (OutboxConcurrentEnqueue, ReplenishDupConcurrencySlice) are re-run before being counted.
4. Full Jest vs the baseline.
5. One `code-reviewer` lane per repo with a report file, and every finding fixed, Lows included.

There is **no verify script**.

### 8.5 Manual tests (DEV once the tunnel is up; UAT otherwise)

| Scenario | Steps | Expected |
|---|---|---|
| Happy path | Open → a PROCESSABLE row → Change Source → a listed SU → Save | dialog closes; new source shown; 2 REDIRECT rows |
| Stale list, finished | open the dialog; finish that order on the handheld (`/multi-unitloads`); Save | toast "…is FINISHED (700)…"; dialog stays open; no stockrecord |
| Stale list, reserved | open the dialog; reserve the chosen SU elsewhere; Save | toast "already has a reserved amount" |
| **Live path, handheld (CR-H1-r2 edit 5)** | web: redirect X from A to B. Handheld: open X, scan A's location in selectSource, stage A's UL, choose the destination, submit | X = 700, booked **from A**; A released once. **B.reserved = 0 from X's rows. Any other reservation on B must carry a different ordernumber created after X's finish**, because the production wrapper's post-commit refill can immediately reserve B for a new order (the DEV REPL389452 pattern) (CR-L3-r3). X's stockrecords: the REDIRECT pair, then `FINISHED(B, whole)` / `CREATED(A)` / `FINISHED(A)`, plus the transfer pair `REPLENISHMENT` −5 on A / +5 on the destination SU. The handheld showed B until the scan; the scan wins |
| DB sanity | `SELECT number,state,stockunit_id,requestedamount FROM replenishorder WHERE id=…`; `SELECT id,reservedamount FROM stockunit WHERE id IN (A,B)` | reservations moved exactly once |

## 9. Risks & mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | The web UI is promoted ahead of the API | §5.1 #4 per-env rule; revert B first |
| R2 | ABBA vs recalc, reassign, and the SU→order partners (switch, finish, **live multi-UL**) | ascending ids closes operator-vs-operator; the rest is bounded (40P01 / `lock_timeout`), rolls back fully, and surfaces as a 409 with a readable `detail`; P5 |
| R3 | The operator's pick doesn't stick | **On the live path the picker's scanned UL always wins.** S12 re-points the location on every differing scan, and `applyExplicitSourceToOrder` re-points the source. So web "Change Source" changes only what the handheld is shown until a picker scans. There is also the point-in-time UL/location read (F4). The cron heals desyncs unless `manuallyoverridepriority` is set |
| R4 | F6 changes live priority behaviour | intended; pinned rows stay; stated in the PR body |
| R5 | The 422 breaks an unknown `/v3` client | 0 callers on both UIs; residual: external scripts |
| R6 | `findByIdForUpdate` on a missing old SU takes no lock | skip only; no find-or-create |
| R7 | False-green harnesses | `pg_stat_activity` wait asserts; `mvn clean`; JDK-21 guard; `pipefail` so logs are never silently lost |
| **R8a** | **API path:** a redirect (web or cron) between `/checkSource` and `/checkDestination` makes finish double-release the old SU, or book from the new SU | **Closed by F8a + F8b** for any caller that sends `?sourceStockId=`. Without it, F8a still closes the millisecond `loadOrderById`→`readReplenishOrder` window. No production screen uses this path (0 dispatchers) |
| **R8b** | **Live path:** web redirect A→B, then the picker's `/multi-unitloads` on A → `applyExplicitSourceToOrder` releases **B's whole `reservedamount`**. That is correct when X is B's only reservation, but eats order Y's reservation otherwise. **No DEV case of another order's reservation being consumed has been found.** REPL049240 and REPL050660 released their own leaked reservation (§1). The exposure is established by the code reading and by IT-M1b | **Bounded by F3:** B.reserved == 0 at redirect, so only a reservation placed on B *after* the redirect and *before* the scan is exposed (a cron `getAvailableReplenishmentSources` pick of B's remainder). Characterised by IT-M1/M1b; counted by the §5.1 #8 classifier; fix is P10 (T3, proposed) |
| R9 | Operators expect "Change Source" to steer the picker | it does not (R3). Stated in the PR-B body and release note; P3's menu tooltip could say so |
| R10 | Overlapping multi-UL tx vs redirect is unmeasured | `@Version` on the template's flush, or 40P01, makes one side fail, so no corruption is expected. The flush-vs-lock order is unverified. A follow-up IT on the IT-C latch pattern is noted under P10 |

## 10. Decisions, open questions, proposals

**Resolved:**
- **D1:** ≤ PROCESSABLE, named state; 0–300 incl. ASSIGNED 200 allowed.
- **D2:** Option A.
- **D3:** `/changeSourceStockUnit` kept and re-routed.
- **D4:** 422 `{errors}` on the 3 web endpoints; the store also reads `detail`.
- **D5:** the candidate gate is the list query.
- **D6:** keep `REDIRECT_REPLENISHMENT_SOURCE` and `zeroIfNegative` parity.
- **D7:** SUs locked in ascending id; the residual is bounded.
- **D8:** finish refuses a stale source, labelled API-path defence; plus the unresolved-supplied-id refusal (U-F7).
- **D9, reversed (Nam 2026-09-29): mobile-ui dropped.**
  - There is no PR-C, no F9, no MJ-*, and no AC12. The ticket is back to 2 repos.
  - **Record of the premise error:**
    - r1 and r2 described the picker flow as `/checkSource` → `/checkAmount` → `/checkDestination`. Both reviewers' r1 H1 and this plan's r2 narrated it from the store's action list, without checking for a dispatcher.
    - The coordinator's framing of the D9 question inherited that error.
    - On origin/develop those actions have **0 dispatchers**; their screens were deleted in `5200dc4` (2025-10-14). The live flow is `submitULBatchToDestination` → `/multi-unitloads`.
    - Lesson: a zero-caller claim needs a dispatcher grep with a positive control, not an action list.
- **D10 (Nam 2026-09-29): ship + measure P10.**
  - The web enable is kept.
  - IT-M1 pins the live interaction (AC13), and IT-M1b characterises P10 while disabled.
  - P10 is proposed as the top-ranked follow-up.
  - This also answers the critic's stakeholder question ("should Change Source be kept at all?") with **yes, kept**, with R9 stated.

**Open questions:** none.

**Proposals** (not filed; Nam decides; ranked):
1. **P10 (T3), top:** `applyExplicitSourceToOrder` releases the old SU's **entire** `reservedamount` (`oldStockOpt.get().getReservedamount().negate()`, `CODE_REPLENISHMENT_FINISHED`, an unlocked pre-read).
   - **Triggers** (a multi-UL pick where the old SU also carries **another** order's reservation):
     - a cross-SU pick (the picker scanning a UL other than the order's source) or a **same-SU** pick. `validateUnitLoadEntry` credits back only `min(requested, reserved)`, but the release is still the whole `reservedamount`;
     - **new with this ticket: the operator's web redirect**, followed by the picker scanning the old source (R8b).
   - **Evidence:** **none observed.** The two DEV cases once cited (REPL049240, REPL050660) released the order's **own** leaked reservation (§1). **IT-M1b is the only demonstration.** The rank rests on the code mechanism and the new operator trigger, not on data. Nam may re-rank against P1 and P9 once the §5.1 #0 PRD classifier reports.
   - **Blast radius:** any multi-UL pick whose old SU carries another order's reservation. That order's reservation is stripped, and its later finish clamps at 0 via `zeroIfNegative`, so no error ever surfaces.
   - **Fix direction (not a sketch to implement here):** release **this order's net outstanding reservation on the old SU**, under the lock, and lock the template order first.
     - It must **not** be `requested.min(reserved)`. On REPL049240 and REPL050660 that would have released only 5 and 2, stranding 7 and 10 for good, because nothing else releases an own leak once the order is 700.
     - The exact derivation of "net outstanding" (from the order's own reservation rows, or from a reservation ledger) is left to the P10 ticket.
   - **Cost:** about ½ day of code plus the ITs already written here (IT-M1b is enabled). **Plus an own-leak IT**: the old SU carries X's own +7 on top of its +5 and no other order's reservation. Assert the release is 12 and B.reserved = 0. It goes red under a requested-based fix, which IT-M1b cannot detect (CR-N1-r4).
   - **Deferred to the P10 ticket (CR-N4-r4):**
     - the **wrapper-level IT-M1 variant**, run through `fulfillMultipleUnitLoads` with the post-commit refill and recalc: FLA `lowerbound ≤` the post-transfer amount, `Y.manuallyoverridepriority = true`, asserting only X-numbered rows;
     - the **R10 overlapping-tx IT** on the IT-C latch pattern (`pg_stat_activity` wait), measuring the flush-vs-lock order of `fulfillMultipleUnitLoadsTx` against `redirectSource`. Touches the SBDEV-260713 A.2/B multi-UL transaction.
   - **Before the P10 ticket:**
     - run the §5.1 #0 PRD classifier;
     - `git log -S` for what wrote `REPLENISHMENT` rows with `amount 0, reservedamountchange +7/+10` under a replenish order's own number on 2025-12-05. That is a separate reservation leak (the own-leak source), possibly already fixed.
2. **P1 (T3 authz):** `WEB_UI_VIEW_REPLENISHMENT_ORDER` gates every replenishment write (11 uses). 6 of the 11 uses were writes; they are re-gated by SBDEV-3606 (pending merge).
3. **P9 (T3):** mobile `PUT /replenish/order/{id}` re-points the location without the SU, with no lock or state check. It is live on every differing scan (S12), and it defeats AC10.
4. **P5 (T2):** ascending-id SU locking across all writers, or the shared primitive C/B′.
5. **P8 (T3), rejected for now:** wire `startOrder`.
   - **Evidence:** 0 callers; PRD 500 = 0.
   - **Blast radius:** every picker.
   - **Why rejected:** after N1 the live path's consuming point is `applyExplicitSourceToOrder` (P10), not state, so a claim marker would not stop the wholesale release.
6. **P2 (T1, this ticket, executor doc-sync):**
   - `wms2-replenishment-design.md`: route drift, the four re-source writers, the live `/multi-unitloads` flow and "scan wins";
   - `wms-exception-taxonomy.md`: the 422-shape contradiction;
   - the stale "PART 2 — Mobile UI" header in `replenishment.cy.js` (S16).
7. **P3 (T1):** hide the menu for `state > 300`; await the `changeStockUnit(item)` dispatches; add a tooltip for R9.
8. **P11 (T1):** delete the dead mobile store actions `checkSource`/`checkAmount`/`checkDestination` and the commented loop (S17). Otherwise a future re-wire resurrects an unguarded client.
9. **P4 (T1):** a WHERE-parity rail for the two list queries.
10. **P6 (T1):** `startOrder` is dead code; delete it or wire it (P8).
11. **P7 (T1):** `PickingorderBusinessService` lets 0 through under `AMOUNT_MUST_BE_GREATER_THAN_ZERO`.

## Acceptance criteria

| AC | Criterion | Tests |
|---|---|---|
| AC1 (ticket, reworded) | A source change on an order with state **> PROCESSABLE** is refused with HTTP 422 naming the state. **Primary:** 700/800 (reachable). **Defensive:** 400/500 | U-1, U-2, U-4, C-1…C-3, IT-2 |
| AC2 (ticket) | A target with reservedamount ≠ 0 is refused | U-5, IT-3 |
| AC3 (ticket) | A PROCESSABLE redirect moves the reservation exactly once and writes 2 REDIRECT rows (1 if the old SU is absent) | IT-1, IT-1b, U-9, U-11 |
| AC4 (ticket) | The web UI dispatches an existing action and closes only on success. A refusal (422/409/404) shows the server text, and the spinner is hidden | J-1…J-10 |
| AC5 | A target of another item, the current source, or outside the list predicates is refused | U-6, U-7, U-8, IT-4 |
| AC6 | A redirect racing a real order-locking writer (cron recalc) waits, then refuses on 800 or re-sources from the fresh source with no double release | IT-C1, IT-C2, U-10 |
| AC7 | A rackless target or a missing/null old source does not 500 | U-11 |
| AC8 | The 3 web endpoints reach one locked method by id | U-12, C-3 |
| AC9 | The same priority (> 127) is a no-op; a null priority does not NPE | U-13, U-14, U-14b |
| AC10 | The operator's source survives the next cron recalc (not a later differing handheld scan, R3) | T-9 |
| AC11 (D8, API path) | `/checkDestination` finish refuses a source that differs from the order's, or a supplied source that does not resolve. The refusal names both, and no stock or reservation is booked; the destination assignment persists | U-F1…U-F8, M-1, M-2, IT-F1…IT-F3 |
| **AC13 (D10)** | After a web redirect A→B, the live `/multi-unitloads` pick on A books from A, leaves B.reserved = 0, finishes X (700), and writes the stockrecord sequence in §8.3 | IT-M1 (IT-M1b characterises P10 while disabled) |

## Layer-2 completeness checklist

| # | Item | ✓ | Ref |
|---|---|---|---|
| 0 | DB verified | ✓ | §1 (4 PRD tenants + control; DEV multi-UL re-read, P10 evidence); §5.1 #0 classifier |
| 1 | Call sites | ✓ | §0 i–vi (callers, writers, finish callers, **UI dispatchers with positive control**, pinning tests) |
| 2 | Adjacent bugs | ✓ | Bug 7, Bug 8; P9, P10 (characterised), P6, P7, P11 |
| 3 | Backward compat | ✓ | F5; F8b optional param; S16 stays green; R4, R5 |
| 4 | Concurrency | ✓ | F2, §7 #8 (incl. SU→order partners), IT-C1/C2, IT-M1; R10 unmeasured, stated |
| 5 | Multi-tenant | ✓ | row-level; 4 PRD tenants |
| 6 | Error handling | ✓ | F1, F3–F5, F7, F8 |
| 7 | Observability | ✓ | §5.1 #8 (pairs/singletons, P10-after-redirect count; F8 WARN = 0 by construction) |
| 8 | Rollback / migration | ✓ | no Flyway; revert B before A in every env |
| 9 | Test coverage | ✓ | §8, incl. T7 inversion and the inventory deltas |
| 10 | v1↔v2 | no | v1 is reference-only |

## ADR

- **Decision.**
  - Restructure `ReplenishorderService.redirectSource` in place into an id-based, lock-first, validated primitive:
    - order lock → `<= PROCESSABLE` → self-check → SUs in ascending id → item, reserved == 0 and list membership → reserve-then-release, tolerating a missing old SU → nullable rack.
  - Route the 3 web endpoints to it, with 422 `{errors}` refusals and a store that reads `detail`.
  - Harden the API-only `/checkDestination` finish against a stale or unresolvable source (D8).
  - Re-apply the SBDEV-3560 web hunks after the API in every env, and fix the boxed priority compare.
  - Characterise, and do not change, the live `/multi-unitloads` interaction (D10).
- **Drivers.**
  - No reservation moves twice, and no other order's reservation is eaten.
  - Minimal blast radius on the hardened and live primitives.
  - The dead web path goes live safely.
- **Alternatives considered.**
  - B, delegate: private, chooses its own candidate.
  - C/B′, shared primitive: high blast radius, and it misses the live consuming point.
  - Fix P10 now: a T3 change to the only live pick transaction, so it is proposed.
  - P8: a claim marker does not stop the wholesale release.
  - An id-scoped eligibility query: a third copy of the predicates.
  - Target-first locking (r1): a false cycle claim.
  - A mobile-UI sender (r2 F9): a flow with 0 dispatchers; D9 reversed.
- **Why chosen.**
  - It is the smallest change that makes every web entry pass one guarded path, with an eligibility gate that cannot drift from the operator's list.
  - F3 bounds the live-path exposure the web enable creates to reservations placed on B after the redirect.
  - That residual is measured (IT-M1/M1b, §5.1 #8), not asserted away.
  - F8 hardens a routed API endpoint cheaply. It is **not** claimed to protect the handheld.
- **Consequences.**
  - The ≤300 guard stops stale-list redirects, not in-flight picks.
  - On the live path, the picker's scan always wins over the web redirect (R3/R9).
  - The web redirect is a new trigger for P10, bounded by F3 (R8b).
  - F8's refusal counters read 0 on PRD by construction.
  - The ABBA residual is bounded (R2), and the overlapping multi-UL case is unmeasured (R10).
  - `updatePriority` stops pinning same-value saves (R4).
  - The API must precede the web UI in every env.
- **Follow-ups.**
  - P10 first (with the §5.1 #0 PRD classifier), then P1, P9, P5, P2 (this ticket), P3, P11, P4, P6, P7, P8 (revisit).
  - A6 records IT-M1b's measured values.
  - The one-week check in §5.1 #8.

## Revision r2 — changelog (condensed)

| Finding | Resolution |
|---|---|
| AR-H1 / CR-H1 (STARTED unreachable) | §1, Driver 1, F1, AC1 primary/defensive, IT-C1/C2, R8 → now R8a/R8b |
| Nam D8 | Bug 8, F8a/F8b, AC11 |
| AR-H2 / CR-M3 (lock order) | F2 D7, §7 #8, R2, U-10 |
| AR-M1 (deploy per env) | §5.1 #4 |
| AR-M2 / CR-M1 (writers) | §0 derivation, S12, S13, P9, P10 |
| CR-M2 (red for right reason) | A0.0, T5/T6 |
| AR-M3 (F6 effects) | Bug 7, F6, U-13, U-14b, R4 |
| AR-M4 / CR-M4 (freshness) | F4 |
| AR-L1…L4, CR-L1…L7 | F7 spinner, U-7, F2 step 3, IT-1/AC3, U-11, T-9, F7 blocks, P6, F1 |
| Nam D9 (r2b: mobile-ui in scope) | superseded, see r3 |

## Revision r3 — changelog

| Finding | Resolution |
|---|---|
| **CR-H1-r2 / AR-N1** (0 UI dispatchers; the live path is `/multi-unitloads`) | §0 (v), S11/S12/S13/S16/S17; §1 live path + "scan wins" fact; §3; F8 scope label; Principle 5; Driver 1; R3, R8a/R8b, R9, R10; §8.5 live-path handheld row (edit 5); IT-M1/M1b (edit 6); AC13; §10 D9 premise record; ADR (Decision, Why chosen, Consequences) |
| **Nam D9 reversed** | frontmatter `repos` → 2; F9, MJ-*, PR-C, mobile-ui worktree, AC12 removed; §5/§6/§5.1 #4 back to 2 repos; §10 D9 |
| **Nam D10** (ship + measure P10) | IT-M1 (AC13), IT-M1b `@Disabled` with the derived today-value (B.reserved 0.0000 vs 3; FINISHED −8.0000) and A6 measurement; P10 ranked first, with triggers, blast radius and cost; R8b; §10 D10. ⚠ The "DEV evidence" cited for P10 in r3 was false (own leak); corrected in r4 |
| AR-N1 DB re-read / **CR-M3-r2 / AR-N4** (probe) | §1 "order-number reuse" inference corrected; §5.1 #0 classifier (multi-UL, double-release signature). ⚠ r3's "P10 = old-SU release > requested" rule and its "REPL049240/REPL050660 = P10" control were **false** and are superseded in r4 |
| **CR-H2-r2** (F8a reds) | §0 T7 (3 tests, both inverted and re-homed); U-F1 absorbs `:2290`/`:2468`; U-F8 re-homes SBDEV-1714 AC-5; §6 A5 "3 reds expected"; H2Test and mobile ControllerUnitTest grepped, 0 hits (§0 vi) |
| **CR-H3-r2 / AR-N2** (`never()` rule inverted) | §6 A0 rule rewritten; §8.1 matcher rule + inventory deltas with signatures (`ReplenishorderServiceUnitTest` 2→3, `MobileReplenishServiceUnitTest` 12→15); U-1/U-7/U-10/U-F1 fixed; §0 T3 |
| **CR-H4-r2** (commands) | §8.4: `java_home -v 21` + version guard; `LOG=…; mkdir -p; set -o pipefail`; every run tee'd; PIT targets include mobile `ReplenishController` + its test |
| **CR-M1-r2** (A0.0 compile) | §6 A0.0: `public @Deprecated(forRemoval = true)` until A1, with rationale |
| **CR-M2-r2 / AR-N3** (lock participants) | §7 #8 rewritten: SU→order partners (switch, finish, live multi-UL) bounded; overlapping case unmeasured (R10); IT-M1 sequential |
| **CR-M4-r2 / AR-N6** (committed destination) | F8a "What persists"; IT-F1 asserts `destination_id` and the FLA count; AC11 wording |
| **CR-L1-r2 / AR-N5** (unresolved supplied id) | F8b refusal; U-F7, IT-F2; AC11 (the r3 `sourceExplicit` marker was dropped in r4) |
| Cypress harness (CR §5) | §0 S16; §8.4 run note; P2 header fix |
| CR-L2-r2 | moot (mobile-ui dropped) |
| **CR-L3-r2** (U-13 construction) | U-13: `new Integer` under `@SuppressWarnings("removal")` via the stubbed `getPrio()`, with an `isNotSameAs` premise assert |
| **CR-L4-r2** (IT-C2 ordering) | IT-C2: B inserted after T1 latches, so C is the only cron candidate |
| CR-L5-r2 | moot (mobile-ui dropped) |
| §5.1 #8 (F8 WARN zero by construction) | §5.1 #8 |
| "stays on the amount step" | removed everywhere (F8, AC11, §8.5) |
| Principle 5 / ADR truth (CR §2) | Principle 5 rewritten; ADR Why chosen and Consequences re-scoped to the live system |
| CR open question (keep Change Source at all?) | answered by D10 (kept), R9 |
| New: dead mobile store actions | P11 (delete S17) |

## Revision r4 — changelog

| Finding | Resolution |
|---|---|
| **CR-H1-r3 / AR-M1-r3** (IT-M1/M1b call the wrapper) | §8.3 IT-M1/M1b now call `fulfillMultipleUnitLoadsTx` through the bean proxy. The why: post-commit `refillFixedLocations()` + `recalculateOpenOrders(true)`, FLA defaults 36/84, DEV REPL389452. Added the "no other replenishorder for the item" isolation assert. The wrapper variant is deferred to the P10 ticket |
| **AR-L3-r3** (Y placed by fixture) | IT-M1b: Y inserted directly + `changeReservedAmount(B, +3, …)`; premise asserts B.reserved = 8 and B.amount ≥ 8 |
| **CR-L3-r3** (post-commit refill in the manual row) | §8.5 live-path row: "B.reserved = 0 from X's rows; any other reservation on B carries a different ordernumber created after X's finish" |
| **AR-H1-r3 / CR-M1-r3** (P10 DEV evidence false) | §1 DB evidence re-attributed (18 multi-UL: 8 cross, 10 same; the 2 cases are own leaks, net 12; no other order on those SUs); R8b; P10 evidence "none observed; IT-M1b is the only demonstration", with the rank re-justified on the mechanism + the new trigger; P10 fix direction "release this order's net outstanding reservation", explicitly **not** `requested.min(reserved)` (it would strand 7 and 10); r3 changelog rows annotated |
| **AR-M2-r3 / CR-M1-r3** (probe) | §5.1 #0: same-SU pairs count as multi-UL; P10 harm = another non-null ordernumber with positive net reservation on SU1 at release; own-leak and ambiguous (NULL ordernumber) buckets; first CREATED is not a baseline; controls REPL049240/REPL050660 → multi-UL, P10 = no; REPL050443 (+53, +29, −82, all its own) → multi-UL same-SU, P10 = no |
| **CR-M2-r3** (U-F8 duplicates `:1764`) | U-F8 redefined on the multi-UL path: scanned UL ≠ the order's source → the recorded label is the scanned one; `:1764` already covers same-source; kill stated |
| **CR-M3-r3 / AR-L2-r3** (transfer writes 2 rows) | IT-M1 fixture A.amount > 5 + flowbin destination; reservation rows asserted as an exact sequence; transfer pair (−5 A, +5 destination SU) asserted separately; §8.5 wording |
| **AR-L1-r3** (`sourceExplicit` unnecessary, Jackson-visible) | F8b: marker dropped; "id > 0 and not found → refuse" unconditionally, with the equivalence argument; §5 DTO row removed; U-F3 / U-F7 / M-1 renamed |
| **CR-L4-r3** (message for an unresolved id) | F8a: second fixed message, "stock unit <id> (not found)", with no label |
| **CR-L2-r3** (commands) | §8.4: detached origin/develop baseline worktree path; never concurrent with another Maven run (`pgrep` guard); both ITs comma-separated in `-Dit.test`; JDK guard `\|\| { echo 'JDK 21 required'; false; }` |
| **CR-L1-r3** (web-ui base moved) | frontmatter `base_commit` → `a38b798`; §8.4 note on the SBDEV-3564 `commitNamesExist` rail scanning F7, and that it cannot see Bug 1 |
| **CR-L5-r3** (IT-F1 wiring) | `ReplenishFinishStaleSourceIT` names the `IdempotencyFilterIT` `standaloneSetup` pattern; no `@AutoConfigureMockMvc` |
| **CR-L6-r3** (`− new.reserved` always 0) | F2 step 6: the term is dropped with a comment; gate item 2 notes there is no equivalent survivor |
| **CR-L7-r3** (kills for pins) | IT-M1 kill (drop the old-SU release → row 3 missing, B.reserved 5); T-9 kill (drop `setRequestedlocationId`); U-F8 kill |
| CR/AR open question (the +7/+10 own-leak writer) | P10 "Before the P10 ticket": `git log -S` |

### Revision r4.1 (2026-09-29, applied directly after the narrow critic confirmation `SBDEV-3561-review-critic-r4.md`)
| Finding | Resolved in |
|---|---|
| CR-N1-r4: the IT-M1 kill note called the rejected requested-based fix "the P10 direction" | §8.3 IT-M1 kill note; P10 Cost (own-leak IT) |
| CR-N2-r4: "no other order ever reserved" was false after the release | §1 |
| CR-N3-r4: ambiguous bucket conflicted with control (b) | §5.1 #0 (made a flag) |
| CR-N4-r4: deferred work not recorded under P10 | P10 "Deferred to the P10 ticket" (wrapper variant + R10 latch IT) |
| CR-N5-r4: T-9 kill survives when A and B share a location | §8.3 T-9 fixture |

## 11. Implementation Status (2026-09-30)

**PRs** (both into `develop`, not merged). Merge order: API first; never promote the UI ahead of the API in any environment.
- wms2-api: https://github.com/SiteBossInc/wms2-api/pull/434
- wms2-web-ui: https://github.com/SiteBossInc/wms2-web-ui/pull/153

Both are on branch `bugfix/SBDEV-3561-change-source-stock-unit-guard`.

**wms2-api commits** (base `5d08e9fc`)

| SHA | Step |
|---|---|
| `2f2730f4` | A0.0 staging |
| `4caf33a0` | A1: F1–F4 |
| `f986fa05` | A2: F2 entry points |
| `f1371eed` | A3: F5 422 |
| `0af4cd02` | A4: F6 |
| `87221c72` | A5: F8a/F8b; T7 inverted, U-F8 re-homed |
| `21aa09ff` | PIT survivors closed |
| `a3a4ba8c` | A6: ITs |
| `2af83c9c` | attributable guard kills |
| `16b83faf` | review r1 fixes |
| `db564ff6` | review r2 fixes |

**wms2-web-ui commits** (base `a38b798`)

| SHA | Step |
|---|---|
| `bace4c4` | F7 plus restored SBDEV-3560 tests |
| `f90d06d`, `fc4bd76`, `f20f595`, `88a8d76`, `c77c2e8`, `41a3fc7`, `f6ae53a` | review rounds 1–7 |

**Test classes**
- wms2-api: `ReplenishorderServiceUnitTest`, `ReplenishOrderControllerUnitTest`, mobile `ReplenishControllerUnitTest`, `MobileReplenishServiceUnitTest`, `ReplenishorderRedirectSourceIT`, `ReplenishFinishStaleSourceIT`, and `AbstractReplenishRedirectPgFixture`. Arch-rail updates in `NeverMatcherNullBlindnessArchTest` (inventory 2→3, 12→15) and `TestClassTransactionManagerArchTest` (fixture exemption).
- wms2-web-ui: `test/components/opsDialogRefusalSweep.spec.js`, `test/store/opsSaveResultSweep.spec.js`.

**Results**
- wms2-api gate classes: 335 run, 0 failures.
- wms2-api ITs: 22 run, 0 failures, 1 skipped (IT-M1b, `@Disabled` P10 characterisation). Measured values: B.reserved 0.0000, FINISHED row on B −8.0000, equal to the derivation.
- wms2-api full unit suite: 7493 run, 0 failures. Baseline origin/develop: 7435 run, 0 failures.
- wms2-api full `mvn clean verify`: 7490 unit / 573 IT. The same 3 IT failures appear on a fresh origin/develop baseline, in untouched classes: `CancellationReversalParcelSourceIntegrationTest` ×2 (H2 table missing) and `SequenceTransactionServiceConcurrencyIT` ×1 (connection).
- PIT: the only survivor on a changed line is equivalent (lock ordering). Every guard deletion fails a test whose message names that guard.
- Jest: 117/117 suites, 2094/2094 tests. Baseline 2052, all green. Hand mutation checks were run on every new assertion.
- No verify script, by design.

**Conformance:** verifier PASS. AC1–AC11 and AC13 are VERIFIED; AC12 was dropped with mobile-ui.

**Review:** wms2-api got 3 rounds, wms2-web-ui 8. 0 High and 0 Medium remain. One Low was deliberately left: a redundant `java.util.Locale` import.

**Owner-approved deviations (Nam, 2026-09-30):** two IT oracle corrections.
- IT-M1 now expects the zero-amount `STOCK_CREATED` placeholder row.
- IT-F1 cron variant: the no-transfer check is narrowed to stock-movement row types.

**Deliberately skipped:**
- G1: IT-F1 does not assert the FLA row count +1. Creating the FLA triggers a recalc that disturbs the asserted reservations, so the fixture pre-seeds it.
- The 4 sibling `if (result.errors)` sites in web-ui are left unguarded; see the ticket note.

**Landmines found during implementation that the plan did not predict:**
- A second Claude session worked in these same worktrees mid-round. It discarded an uncommitted `.vue` fix and overwrote a review file. It was recovered and recorded in memory `review-lanes-must-not-share-a-worktree`.
- `mvn clean verify` on develop is **not** green: it has 3 pre-existing IT failures.
- `startOrder` has no caller (P6/P8).

## Archive note (2026-09-30)

> Archived 2026-09-30 at Nam's request. Both PRs are merged: wms2-api #434 (`68e3d029`, live on dev as `develop-68e3d029`) and wms2-web-ui #153 (`299cec1c`). SBDEV-3561 is `on dev`, with all 4 ACs ticked. Live-tested on dev as panderson on 2026-09-30: the UI happy path, the refusals, and a restore.
> No acceptance script existed for this plan (T3 opt-in; none was written).
> Implementation worktree(s) removed 2026-09-30: wms2-api/SBDEV-3561, wms2-web-ui/SBDEV-3561. Both local branches `bugfix/SBDEV-3561-change-source-stock-unit-guard` were deleted, and both were merged and pushed.

**Findings disposition (archive gate, §10 proposals):**

| Finding | Disposition |
|---|---|
| P10 (T3) whole-reservation release in `applyExplicitSourceToOrder` | **On a ticket:** SBDEV-3605 (high) |
| P1 (T3 authz) VIEW function gates the replenishment writes | **On a ticket:** SBDEV-3606 |
| P9 (T3) mobile `PUT /replenish/order/{id}` location-only, unlocked | **On a ticket:** SBDEV-3607 |
| P5 (T2), P3, P4, P6, P7, P11 (T1) | **On a ticket:** SBDEV-3608 (bundled cleanup) |
| P2 doc sync | **Partly fixed:** design-doc routes and finish row corrected in SBDEV-3561. The rest (re-source writers, "scan wins", the stale `replenishment.cy.js` header) is **on a ticket:** SBDEV-3608 |
| P8 (T3) wire `startOrder` | **Dropped:** Nam rejected it 2026-09-29 in favour of the finish refusal (F8a) |
| Web `result.errors` sibling sites (4) | **On a ticket:** SBDEV-3608 |
| Verifier gap G1 (IT-F1 has no FLA-count assertion) | **Dropped:** deliberate. Creating the FLA triggers a recalc that disturbs the asserted reservations; persistence is proven through `destination_id` |
| Pre-existing develop `mvn verify` reds (3 ITs, untouched classes) | **Not machine-knowable, owner named:** Nam. Reported on SBDEV-3561; unrelated to this change |
| Promotion order API before UI (UAT/PRD) | **Not machine-knowable, owner named:** DevOps promotion (Nam). Stated in both PR bodies and on the ticket |

