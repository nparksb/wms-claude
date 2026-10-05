---
type: design
status: active
system: wms2
last_verified: 2026-10-02
verified_by: "SBDEV-3636 doc pass 2026-10-02 — re-verified ONLY the SBDEV-3636 sentences of the 'Admin reserved cut' paragraph against branch bugfix/SBDEV-3636-replen-cooldown-after-manual-cut @ fd95b823 (PR #449). SBDEV-3638 doc pass 2026-10-02 — struck the removed handheld single-UL endpoints (checkSource/checkAmount/checkDestination, switchSourceToUnitLoad, public finishReplenishmentOrder, F8a/F8b, SBDEV-3621 single-UL finish rule) against branch bugfix/SBDEV-3638-remove-single-ul-replenish-endpoints (PR pending, not merged). Earlier: SBDEV-3608 doc pass 2026-10-02 — added the 'Who re-sources an order' table + 'The scan wins' and struck startOrder/resetOrder, verified against origin/develop 62c92dd5 (P5/P6/P11 marked as SBDEV-3608, on its branches pending merge). Earlier: SBDEV-3622 doc pass 2026-10-02 — added ONLY the 'Admin reserved cut — SBDEV-3622' paragraph, verified against branch bugfix/SBDEV-3622-adjust-reserved-attributes-cut (unmerged, stacked on SBDEV-3621 PR #444). Prior: SBDEV-3621 doc pass 2026-10-02 — added ONLY the 'Releases outside the cron' paragraph, verified against branch bugfix/SBDEV-3621-release-held-share. Prior: SBDEV-3607 doc pass 2026-10-01 — added ONLY the §2 `MobileReplenishService.update(id, dto)` row, verified against branch bugfix/SBDEV-3607-mobile-put-source-location. Prior: SBDEV-3624 doc pass 2026-10-01 — re-verified ONLY §'Affected item tracking' and job-phase row 10 against branch bugfix/SBDEV-3624-replenish-sweep-starvation @ b1612027 (ReplenishOrderJob.replenish / drainPageZero). Prior: SBDEV-3618 doc pass 2026-10-01 — re-verified ONLY the new §2 sizing/booking paragraph and the §9 move-path sub-bullet against branch bugfix/SBDEV-3618-recalc-held-share (ReplenishmentOrderMaintenanceService shareOf/bound/updateRequestedAmount/releaseHeld, reassignOrCancelForMovedStockUnit). Prior: SBDEV-3605 doc-drift pass 2026-09-30 (round 2) — re-verified ONLY §7 (Multi-Unitload Replenishment Path) against branch SBDEV-3605 @ d6fa6821 (commit 6a4a1bd3 reordered the steps: destination assignment now runs right after the empty-UL guard and BEFORE any SU resolve/lock, with a re-guard of the template afterward and R7's error order reverted to destination-first). Round 1 (same date) verified this section against the pre-reorder a1b8d5e1 and is superseded by this pass. NOTHING ELSE in this doc was re-derived on this pass — treat every other claim as carrying its previous verification date. Prior: SBDEV-3198 doc-drift pass 2026-09-06 — re-verified ONLY the scheduled-job entry-point claims in this doc against origin/develop d4a6ab8a (doCalculation deleted from all of src/main; runFor(TriggerSpec) / runForCurrentTenant() / deriveSpecForCurrentTenant() are the replacements; the advisory lock moved inside the per-tenant loop and takes tenant_db_configuration.id as a second key). (previous last_verified: 2026-09-01.) Prior: Claude (executor)"
tags: [wms2, replenishment, fix-location, stock, inventory]
---

## TL;DR
- Module-level design for the replenishment subsystem in `v2/wms2-api` — moving inventory from bulk storage into fixed pick-face locations (flow bins).
- Four service halves: **Generator** (`ReplenishGeneratorService`) creates orders at `PROCESSABLE(300)`; **Execution** (`MobileReplenishService`) drives the physical move to `FINISHED(700)`; **Maintenance** (`ReplenishmentOrderMaintenanceService`) recalculates/redirects/cancels open orders; **Job** (`ReplenishOrderJob`) runs the cron pipeline across all tenants.
- Core entities: `Replenishorder` (order + state) and `FixLocationAssignment` (FLA — SKU → fixed slot binding with `lowerbound`/`middlebound`/`upperbound` thresholds).
- State machine: `PROCESSABLE(300)` → `STARTED(500)` → `FINISHED(700)` or `CANCELED(800)`; `PICKED(600)` is unused in this flow.
- FLA `middlebound` is the refill trigger — a refill order is generated when on-hand drops below it; `upperbound` is the cancel-if-full threshold.
- Critical constraint: `refillFixedLocations()` has no outer `@Transactional`, so partial completion is its normal outcome. ⚠ **Corrected 2026-09-10 (SBDEV-3244)** — this bullet used to end *"calling it inside `finishReplenishmentOrderInternal` means an unexpected refill failure can roll back the finish transaction"*, which is backwards: that method calls `scheduleRefillAfterCommit(replenishOrder.getNumber())`, so the refill runs **after** the finish transaction commits and cannot roll it back. This was the THIRD copy of the same inverted claim (§11.1 and §5.4 were corrected first); grep the claim, not the section. *(Method removed by SBDEV-3638, merged 2026-10-02, `f839921e`: `finishReplenishmentOrderInternal`, `scheduleRefillAfterCommit` and `runRefillMaintenance` are gone. The only finish is now `finishReplenishmentOrderWithoutRefill`; `fulfillMultipleUnitLoads` runs its own best-effort `refillFixedLocations()` after the commit.)*
- **SBDEV-2074 (2026-07-20):** moving a unit load with an active replen reservation onto a NON-replenishable location is now handled synchronously at move time — `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` delegates to the new `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit`, which reassigns the same order to another eligible source or cancels it. This closes a gap neither cron path (`recalculateOrder`, gated on `state==300`; `cancelUnreachableReplenishment`, gated on `state<=300`) could reach for a `RESERVED(400)` order re-pointed onto a lane. See §9 and §11.
- Read this doc for: replenishment stuck-state bugs, over-replenishment, FLA assignment failures, multi-unitload replenishment path (`MobileReplenishService`), the `ReplenishOrderJob` cron pipeline, or move-time reservation reassignment (`ReplenishmentOrderSourceSyncService`).

# WMS2 Replenishment Subsystem Design

Module-level design for the replenishment subsystem in `v2/wms2-api`.
Audience: engineers fixing replenishment stuck states, over-replenishment bugs, and location assignment failures.

---

## §0 Module Inventory

All files under `v2/wms2-api/src/main/java/net/aim_ai/wms/` unless noted.

### Production classes

| File | Lines | Role | Covered in |
|---|---|---|---|
| `service/ReplenishGeneratorService.java` | 250 | Order creation + stock reservation — the "generator" half | §2, §3, §6 |
| `service/ReplenishmentOrderMaintenanceService.java` | 688 | Periodic recalculation, source redirect, cancellation, move-time reassign/cancel (SBDEV-2074) — the "maintenance" half | §2, §3, §5, §9, §11 |
| `service/ReplenishmentOrderSourceSyncService.java` | 125 | Move-time source re-point (SBDEV-2492) / reassign-or-cancel delegation (SBDEV-2074) for stock units in an active replen | §2, §3, §9 |
| `util/LocationReplenishabilityUtil.java` | 32 | Shared `isReplenishableArea` helper (SBDEV-2074 M1) — single source of truth for the area `useforreplenish` check | §9, §11 |
| `service/ReplenishorderService.java` | 347 | Public CRUD API: create, update, cancel, priority, redirect | §2, §3 |
| `service/job/ReplenishOrderJobService.java` | 277 | Transactional wrappers called by the cron job | §2, §8 |
| `service/mobile/MobileReplenishService.java` | 1004 | Mobile execution: start → check source/dest → finish; multi-unitload path | §2, §7 |
| `schedulejob/ReplenishOrderJob.java` | 470 | Cron orchestrator — iterates tenants, runs pipeline phases | §8 |
| `model/Replenishorder.java` | 164 | JPA entity — `replenishorder` table | §4 |
| `model/FixLocationAssignment.java` | 108 | JPA entity — `fix_location_assignment` table | §4, §6 |
| `model/ReplenishmentMonitorView.java` | 209 | Read-only monitor view entity | §4 |
| `repo/jpa/ReplenishorderRepository.java` | 363 | JPA repository with 20+ native/JPQL queries | §10 |
| `repo/jpa/ReplenishmentMonitorViewRepository.java` | 114 | Monitor view repository | §10 |
| `repo/projection/ReplenishOrderDetailView.java` | 21 | Projection: detail view columns | §10 |
| `repo/projection/ReplenishMonitorSummaryView.java` | 31 | Projection: monitor summary columns | §10 |
| `repo/projection/UnitloadReplenishView.java` | 9 | Projection: unit load replenish fields | §10 |
| `repo/projection/StockunitReplenishInfoView.java` | 8 | Projection: stock unit info for replenishment | §10 |
| `controller/ReplenishOrderController.java` | 353 (on branch SBDEV-3606, pending merge; 347 on develop) | Desktop REST endpoints (HAL) | §2 |
| `controller/mobile/ReplenishController.java` | 248 | Mobile REST endpoints | §2 |
| `json/mobile/ReplenishMobileOrderDto.java` | 325 | Mobile order DTO | §2 |
| `json/mobile/MultiReplenishRequestDto.java` | 60 | Multi-unitload request DTO | §7 |
| `json/mobile/MultiReplenishResponseDto.java` | 65 | Multi-unitload response DTO | §7 |
| `json/mobile/MultiReplenishUnitLoadDto.java` | 63 | Per-unitload entry in multi-unitload request | §7 |

### Test classes

| File | Lines | Notes |
|---|---|---|
| `unit/service/ReplenishGeneratorServiceUnitTest.java` | 988 | 30+ `@Test` methods; Mockito; covers idempotency, stock fallback, template creation |
| `unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | 1168 | 30+ `@Test` methods; covers recalc, source redirect, cancel threshold |
| `unit/service/ReplenishorderServiceUnitTest.java` | 1014 | 30+ `@Test` methods; covers redirect, cancel, priority bulk update |
| `unit/service/job/ReplenishOrderJobServiceUnitTest.java` | 489 | 15+ `@Test` methods; covers FLA deletion, generate with/without FLA |
| `unit/service/mobile/MobileReplenishServiceUnitTest.java` | — | Unit tests for mobile flow |
| `unit/service/mobile/MobileReplenishServiceH2Test.java` | — | H2 in-memory integration tests |
| `integration/service/mobile/MobileReplenishServiceIntegrationTest.java` | — | Testcontainers (PostgreSQL) integration tests |
| `unit/schedulejob/ReplenishOrderJobTest.java` | — | Job-level unit tests |
| `unit/controller/ReplenishOrderControllerUnitTest.java` | — | Controller unit tests |
| `unit/controller/ReplenishOrderControllerH2Test.java` | — | H2 controller tests |
| `unit/controller/mobile/ReplenishControllerUnitTest.java` | — | Mobile controller unit tests |
| `integration/repository/ReplenishorderRepositoryIntegrationTest.java` | — | Native-query integration tests |
| `resources/scripts/mobileReplenishService_multiUnitLoads.sql` | — | Test fixture SQL for multi-unitload scenario |

---

## §1 Overview

Replenishment moves inventory from bulk storage areas into picking/flow-bin locations so pickers never find an empty slot. The subsystem splits cleanly into two halves:

**Generator half** — `ReplenishGeneratorService` decides *whether* and *what* to replenish. It selects a source stock unit, reserves the amount, and persists the `Replenishorder` at state `PROCESSABLE (300)`. It never executes physical movement.

**Execution half** — `MobileReplenishService` handles the physical movement. A warehouse operator scans the source unit load, walks to the destination, and confirms; the service transfers stock, marks the order `FINISHED (700)`, and triggers follow-up refill.

**Maintenance half** — `ReplenishmentOrderMaintenanceService` periodically recalculates open `PROCESSABLE` orders: adjusting requested amounts, redirecting to better source stock if the original becomes unusable, and cancelling orders whose destination is already sufficiently stocked.

**Job orchestrator** — `ReplenishOrderJob` drives the entire pipeline on a cron schedule. Since SBDEV-3198 (2026-09-03) it does so through two entry points rather than one: `runFor(TriggerSpec)` on the scheduled path, which walks every active tenant and processes those whose own schedule matches the firing trigger, and `runForCurrentTenant()` on the manual/admin path, for the caller's tenant only. Both call the same private `replenish(String tenantName)` — the pipeline body below, extracted verbatim from the deleted `doCalculation(Boolean)`.

```
runFor(spec) / runForCurrentTenant()  →  replenish(tenantName)
  │
  ├─ mergePickingOrders()
  ├─ deleteEmptyFixAssignmentWithoutStockToReplenish()
  ├─ cancelUnreachableReplenishment()
  ├─ cancelReplenishmentIfFlowbinIsFull()
  ├─ generateReplenishmentForItemDataWithoutFixedAssignment()
  ├─ generateReplenishmentForItemDataWithFixedAssignmentWithOrders()
  ├─ triggerRegularReplenishment()
  ├─ updateReplenishmentOrderPriority()
  ├─ recalculateReplenishmentOrderWithoutFixedLocationAssignment()
  └─ replenishmentOrderMaintenanceService.recalculateOpenOrders/recalculateForItem()
```

---

## §2 Public API / Contract

### `ReplenishGeneratorService`

⚠ **Corrected 2026-09-10 (SBDEV-3244) — this blanket was wrong on both halves.** It read *"All tenant-write methods use `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class)`."* Two counter-examples in this very table: `createOrderFromTemplate` carries **no `propagation`** (it joins the caller — `cc9ca6b0`, SBDEV-2575) and `rollbackFor` is a **two-element** list on several of them (`{FacadeException.class, BusinessException.class}`). Read each row's own annotation; do not inherit a blanket. Derive with `git grep -n -B3 'public .* <method>' -- src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java`.

| Method | Signature | Tx boundary | Throws | Notes |
|---|---|---|---|---|
| `refillFixedLocations()` | `() → void` | None (iterates; each item calls `refillSingleFixedLocation`) | `FacadeException` (per-item, swallowed) | Walks all FLAs returned by `getRefillFixedLocations(FINISHED)`. Loop errors are logged and skipped. |
| `refillSingleFixedLocation(flaId)` | `(Long) → void` | `REQUIRES_NEW` | `FacadeException` | Single FLA refill in isolation; safe to call from job loop. |
| `calculateOrder(itemDataId, amount, destinationId)` | `(Long, BigDecimal, Long) → Replenishorder` | delegates to 4-arg overload with `PRIORITY_VERY_LOW` | `FacadeException` | Returns `null` if a pending order already exists for same item+destination (idempotency guard). |
| `calculateOrder(itemDataId, amount, destinationId, priority)` | `(Long, BigDecimal, Long, Integer) → Replenishorder` | `REQUIRES_NEW` | `FacadeException` | Core creation logic. Validates amount > 0. Prefers source stock with sufficient amount; falls back to stock with greatest available. Reserves `requestedamount` via `StockunitBusinessService.changeReservedAmount`. |
| `reserveExplicitStockForOrder(order, stock, amount)` | `(Replenishorder, Stockunit, BigDecimal) → void` | None | `FacadeException` | Used by multi-unitload path to reserve stock on an explicitly chosen source unit. Null-safe — does nothing if any param is null. |
| `createOrderFromTemplate(template, stock, amount, destinationId, sequenceIndex)` | `(Replenishorder, Stockunit, BigDecimal, Long, int) → Replenishorder` | **REQUIRED** (joins the caller — `REQUIRES_NEW` removed by `cc9ca6b0`, SBDEV-2575; see §7) | `FacadeException`, `BusinessException` | Clones template metadata; derives number as `template.getNumber() + "-" + (sequenceIndex+1)`; reserves stock. Used by multi-unitload fulfillment for orders 2…N. |

### `ReplenishmentOrderMaintenanceService`

⚠ **Corrected 2026-09-10 (SBDEV-3244).** This preamble read *"No `@Transactional` annotations at method level — all DB writes are done directly via repository save calls within the calling transaction or in helper methods that acquire their own resources."* It was contradicted by the two rows below it in this very table, and by three real annotation sites in `ReplenishmentOrderMaintenanceService.java`: `recalculateForItem`, `reassignOrCancelForMovedStockUnit` and `recalculateOrder(Long, RecalcContext)`. All three are `value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class}`; the latter two spell `propagation = Propagation.REQUIRED` out, `recalculateForItem` takes it from the default — so the effective propagation is `REQUIRED` on all three, but do not quote a `propagation` attribute for `recalculateForItem`, it declares none. What is still true, and is the part worth keeping: **`REQUIRED` in effect on every one of them**, so each joins the caller's transaction rather than opening its own — which is why a caller that pre-loads these rows relocates SBDEV-3244's throw instead of avoiding it (SBDEV-3286).

| Method | Signature | Notes |
|---|---|---|
| `recalculateOpenOrders()` | `() → void` | Calls `recalculateOpenOrders(false)` — respects cadence sysprop. |
| `recalculateOpenOrders(force)` | `(boolean) → void` | Loads all `PROCESSABLE` orders, builds bulk `RecalcContext`, iterates. Skips orders with `manuallyoverridepriority = true`. |
| `recalculateForItem(itemDataId)` | `(Long) → void` | Targeted recalc for a specific item; called by job after detecting affected items. `null` itemDataId falls back to full recalc. |
| `recalculateOrder(orderId)` | package-private `(Long) → void` | Test entry point — wraps with an empty context. Takes a `Long` since SBDEV-3244. |
| `recalculateOrder(orderId, ctx)` | **public** `@Transactional(tenantTransactionManager, REQUIRED)` `(Long, RecalcContext) → void` | Core logic: **its first statement that touches the row** loads the order with `findByIdForUpdate(@Lock PESSIMISTIC_WRITE)` (a `orderId == null` guard precedes it, touching nothing), then checks FLA, validates/redirects source, computes shortage, cancels or adjusts amount. Per-order short tx when called from sweep; annotation bypassed (this. call) when called from `recalculateForItem`. (260520 fix; **signature changed to a `Long` by SBDEV-3244** so the locking read is the FIRST touch of the row — passing the entity meant a caller had already loaded it at READ, making this a version-checked lock upgrade. Both the state and `manuallyoverridepriority` guards now sit under the lock.) |

**Sizing and booking rule — SBDEV-3618 (2026-10-01).** The cron sizes each order against its **held share** of the locked source, never its requested amount. The share is computed once per source under the SU row lock, through the pure `ReservationShare` arithmetic shared with the multi-UL pick (§7):
- `ownShare = max(0, min(res, res − Σreq(other open replen) − Σamount(open picks)))`
- `held = min(requested⁺, ownShare)`, `free = max(0, amount − res)`, `capacity = min(held + free, amount)`.

The rules that use it:
- **Usable source:** `isSourceUsable` requires `capacity > 0`.
- **Respect the cut (Nam, after SBDEV-2033).** An order holding **less** than it requests is shrunk to `held` (cancelled at 0) and is **never re-reserved**. Only a fully-held order grows from `free`.
- **Booking:** the delta is booked against `held`. A booking or release that would leave `res > amount` is skipped with a WARN (`changeReservedAmount` throws on every delta past `amount`, releases included).
- **Releases:** cancel and redirect release `held`, not `requested`.
- **Same-row redirect:** a redirect whose chosen (first-ranked) candidate is the current SU re-points the location and writes no reservation. On the unit-load move path such a candidate counts as no candidate.
- **The shrink cap:** a shrink is to `min(held, capacity)`, so an order is never sized above the stock the unit holds, even when `res > amount`.
- **Another holder is short** (`res < others + picks`): every held share computes to 0 and the ledger cannot say whose reservation was cut. The order is therefore only capped at `capacity`, with nothing booked and a WARN; no order is arbitrarily cancelled. A zero-request order in that state is cancelled.
- **A redirect still reserves `min(requested, available)`** at the new SU (D2‴). The cut belongs to the stock unit it was made on.
- **Logging:**
  - INFO when an order is shrunk below its shortage, or cancelled because its source leaves it nothing.
  - ERROR `SBDEV-3618 STRANDED_RESERVATION` when a release is skipped because it would leave `res > amount`. The held quantity is then reserved with no holder until the admin path releases it.

Before SBDEV-3618, `getAvailableIncludingReservation` (`amount − res + requested`, now deleted) re-granted reservation the SU no longer held. DEV had 53 of 565 open orders requesting more than their SU's physical amount.

**Releases outside the cron — SBDEV-3621 (2026-10-02).** The four release sites outside `ReplenishmentOrderMaintenanceService` released the order's `requestedamount`, so when another open order or an open pick also held stock on the source, the excess came out of theirs (hidden by `zeroIfNegative`). Each now reads the source under its row lock as the row's first touch (SBDEV-3244) and releases:
- **web cancel, web redirect** (old source) — `held`, via `HeldShareRelease.release`. Skipped with the same WARN/ERROR tokens as SBDEV-3618 when `held = 0` or when the release would leave `res > amount`. ~~The handheld single-UL switch (`switchSourceToUnitLoad`) locked the order then both SUs and re-checked reserved / item / unit load~~ — removed by SBDEV-3638 (merged 2026-10-02, `f839921e`), together with `findIdsByUnitloadId`.
- ~~**handheld single-UL finish**~~ — removed by SBDEV-3638 (merged 2026-10-02, `f839921e`); the rule below no longer exists in code and the `REPLENISH_FINISH_BLOCKED_BY_RESERVATIONS` refusal went with it. Historical text: `min(requested⁺, max(held, amountPicked − (amount − res)))`, floored at 0 (Nam, 2026-10-02). The move term is deliberately unclamped: on a source reserved above its amount the move also needs `res − amount` back. Held alone under-releases where other orders' `requested` over-states what they hold (23 such open orders on PRD, 2026-10-02), failing a transfer the old code completed; adding what the move physically needs never releases more than before and never fails a finish that used to succeed. When even that leaves `free < amountPicked` (and `amountPicked ≤ amount`), the finish refuses with `REPLENISH_FINISH_BLOCKED_BY_RESERVATIONS` — a case the old code failed too, via the transfer's generic error. An order with no source holds nothing on the DTO's SU (`held = 0`).
- **multi-UL finish** (`finishReplenishmentOrderWithoutRefill`, now the ONLY finish, private, reached only from `POST /v3/replenish/multi-unitloads`) — exactly `requested`: an undo of the reservation the same transaction just booked. Fails closed with `REPLENISH_MISSING_SOURCE` if the DTO's source stock unit is not the order's.
- Residual, out of scope (Nam): web cancel locks the SU before the order row; the cron and the multi-UL finish (via `fulfillMultipleUnitLoads`, which locks the order first) lock the order first. Same-order races between them are bounded by deadlock detection / `lock_timeout`. (Before SBDEV-3638 the single-UL finish also locked the SU first; it is gone.)

**Who re-sources an order — SBDEV-3608 (2026-10-02).** Besides creation (`ReplenishGeneratorService`: `replenishOrder.setStockunitId(sourceStock.getId())` and `createOrderFromTemplate`), exactly three methods write `Replenishorder.stockunitId` (four on origin/develop `62c92dd5`, before SBDEV-3638 removed writer 3; merged 2026-10-02, `f839921e`). Method: `git grep -n "setStockunitId(" -- src/main`, filtered to `Replenishorder` receivers. Blind spot: a native `UPDATE replenishorder` or a reflective setter would not show; `git grep -niE "update +replenishorder" -- src/main` finds only the two bulk `prio` updates in `ReplenishorderRepository` (positive control: `update +stockunit` → 3 hits).

| # | Writer | Reached from | Locks |
|---|---|---|---|
| 1 | `ReplenishmentOrderMaintenanceService.redirectSource` (`order.setStockunitId(candidate.stockUnitId)`) | cron recalc, `recalculateForItem`, move-time `reassignOrCancelForMovedStockUnit` | order → current SU → target SU, **not** id-ordered — the one writer left that can ABBA with another order (bounded by 40P01 / `lock_timeout`; SBDEV-3608 P5 → **SBDEV-3637**, T3, not built) |
| 2 | `ReplenishorderService.redirectSource(Long, Long)` | web `update`, `updateStockUnit`, `changeSourceStockUnit` | order → both SUs ascending; refuses `state > PROCESSABLE` |
| ~~3~~ | ~~`MobileReplenishService.switchSourceToUnitLoad`~~ **removed by SBDEV-3638 (merged 2026-10-02, `f839921e`)** | handheld single-UL `GET /v3/replenish/checkSource/{id}/{input}` — **API-only**: no screen dispatches it (screens deleted in mobile-ui `5200dc4`; the dead store actions removed by SBDEV-3608 P11) | order → both SUs ascending (SBDEV-3621) |
| 4 | `MobileReplenishService.applyExplicitSourceToOrder` | handheld `POST /v3/replenish/multi-unitloads` — **the live handheld flow** (§7) | order → {old SU} ∪ scanned SUs ascending |

**The scan wins.** The handheld loads a `PROCESSABLE` order and keeps it there until submit (orders never enter `STARTED`: `startOrder` had no caller and was deleted by SBDEV-3608 P6; PRD WineCo and ShipItEZ held **0** rows in state 400–600 on 2026-10-02). Writer 2 accepts a web Change Source at any point before submit, and writer 4 then re-points the order to whatever unit load was scanned, without consulting the web choice. So a web source change made while a handheld is working the order is silently overridden at submit; the web dialog says so in a tooltip (SBDEV-3608 P3). Since the handheld picks what is physically in hand, this ordering is intended, not a race to fix.

**Admin reserved cut — SBDEV-3622 (2026-10-02; merged to develop as PR #446, `7762aa64`).** `StockunitService.adjustReservedAmount` no longer cuts the SU's reservation blind to its holders. `ReservationCut.plan` attributes the cut: the holder-less surplus first, the pool allocated oldest-first, the cut walked newest-first. Orders at or below `PROCESSABLE` are shrunk, or cancelled at 0 through the shared `ReplenishmentOrderMaintenanceService.markCancelled` ("set CANCELED and save, releasing NOTHING" — the reservation was already cut, so a release would book it twice). A holder past `PROCESSABLE`, or a cut below the open picks, refuses (`RESERVATION_CUT_ORDER_IN_PROGRESS` / `RESERVATION_CUT_BELOW_PICKS`). A partial cut leaves `held == requested`, so the next recalc may regrow the order from free stock (D-H1, accepted; `bound` returns capacity). Once an item's last open order is cancelled the generator may re-source the freed SU (P-3; plan §1 measured 14 of 311 WineCo cuts within 24 h). **SBDEV-3636 (PR #449, merged to develop as `e3dfcc72`, on DEV 2026-10-02) closes P-3 for automatic sourcing:** `StockunitRepository.MANUAL_CUT_COOLDOWN_EXCLUSION` hides a stock unit with an operator cut row newer than `REPLENISH_MANUAL_CUT_COOLDOWN_MINUTES` (default 60) from the generator source query (`calculateAutomaticOrder`: both FLA refill crons, the no-FLA generation job and the post-finish refill), from FLA refill eligibility, and from `getAvailableReplenishmentSources`, which serves the recalc redirect and the re-point after an operator's unit-load move. There is no current-source exemption. On the move path an all-cooled candidate set **cancels** the order. Operator-initiated creates keep `calculateOrder` and may still pick the stock unit. Partial-cut regrowth on recalc (D-H1) is unchanged by decision. The no-FLA and FLA-with-orders eligibility reads are not cooled: they check no source availability at all. SBDEV-3622 design: [wms2-stockunit-design](./wms2-stockunit-design.md) ledger and method tables (the SBDEV-3636 cooldown is documented here and in the sysprop catalog, not there).

| `reassignOrCancelForMovedStockUnit(movedStock, destination)` | **public** `@Transactional(tenantTransactionManager, REQUIRED)` `(Stockunit, Location) → void` throws `BusinessException` | **SBDEV-2074 (2026-07-20).** Move-time entry point called by `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` when `destination` is NON-replenishable. Re-checks `isReplenishableDestination` defensively (public method, standalone-callable), finds the active (`state < FINISHED`) order bound to `movedStock` via **`findIdByStateLessThanAndStockunitId`** (an id projection since SBDEV-3244 — reading it as an entity made the next line a version-checked lock upgrade), then loads it under `findByIdForUpdate` to serialize with the cron, blocks with `BusinessException` if `state >= STARTED (500)` (incl. `530`), then calls `redirectSource` — cancelling via `cancelOrder` only if `redirectSource` returns `false` (no candidate or reserve failure). Joins the caller's tenant tx (the move is already `@Transactional(tenantTransactionManager)`), so reassign/cancel commits atomically with the relocation. |

### `ReplenishmentOrderSourceSyncService`

**SBDEV-2492**, extended by **SBDEV-2074 (2026-07-20)**. Re-points or reassigns the replen bound to a stock unit whose unit load has just moved. No class- or method-level `@Transactional` — deliberately joins the caller's tenant transaction (`UnitloadBusinessService.transferUnitLoadToLocation` is already `@Transactional(tenantTransactionManager)`); a bare `@Transactional` here would route to the `@Primary` landlord TM and silently disable rollback on tenant writes.

| Method | Signature | Notes |
|---|---|---|
| `syncForMovedStockUnit(stockUnit, destinationLocation)` | `(Stockunit, Location) → void` throws `BusinessException` | Branches on destination replenishability (via `LocationReplenishabilityUtil.isReplenishableArea`): **non-replenishable** → delegates to `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit` (SBDEV-2074) and returns; **replenishable** → falls through to the original SBDEV-2492 behavior, unchanged: re-points `requestedlocationId` / `requestedrackId` / `sourcelocationname` onto the destination for the active order bound to `stockUnit`, leaving `stockunitId` / `reservedamount` / `requestedamount` untouched (I-1). Blocks with `BusinessException` if the bound order is already `state >= STARTED`. `ReplenishmentOrderMaintenanceService` is injected via a `@Lazy` constructor parameter to break the DI cycle introduced by the new delegation edge. |

### `ReplenishorderService`

All tenant-write methods use `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})`.

> **Web gate note (SBDEV-3606, on branch `feature/SBDEV-3606-replenishment-write-function`, pending merge).** Rule for the `ReplenishOrderController` rows below: **a write goes to `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`, a read stays on `WEB_UI_VIEW_REPLENISHMENT_ORDER`.** Writes: `POST /update`, `/updateStockUnit`, `/updatePriority`, `/changeSourceStockUnit`, `/create`, and `GET /cancelReplenishOrder/{id}`. Reads (5): `/loadOrderByDestination/{locationName}`, `/getPickableLocations`, `/replenishorderDetailsById/{id}`, `/stockUnitInfoForReplenishment/{id}`, and `/detailView` (ANY-of with `MOBILE_UI_VIEW_REPLENISHMENT`). MANAGE does **not** govern the mobile `/v3/replenish` create/edit routes (`POST /requestAmount`, `PUT /order/{id}`). Plan: `4-Archieves/wms2/plan/SBDEV-3606-replenishment-write-endpoints-gated-by-view-function.md`.

| Method | Signature | Tx boundary | Throws | HTTP (via controller) |
|---|---|---|---|---|
| `create(mOrder)` | `(ReplenishMobileOrderDto) → Replenishorder` | `tenantTransactionManager` | `FacadeException` | `POST /v3/replenish` |
| `update(id, stockUnitId, priority)` | `(Long, Long, Integer) → Replenishorder` | `tenantTransactionManager` | `B, F` | `POST /v3/replenishOrder/update` (SBDEV-3561: a stock-unit change goes through the guarded `redirectSource(Long, Long)`, and the priority compare is `Objects.equals` with a null guard). **Gate (SBDEV-3606, pending merge): `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`.** |
| `updateSourceStockUnit(id, stockUnitId)` | `(Long, Long) → Replenishorder` | `tenantTransactionManager` | `B, F` | `POST /v3/replenishOrder/updateStockUnit`, the web **Change Source Stock Unit** dialog. This was dead until SBDEV-3561: the UI dispatched a nonexistent action. **Gate (SBDEV-3606, pending merge): `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`.** |
| `updatePriority(id, priority)` | `(Long, Integer) → Replenishorder` | `tenantTransactionManager` | — | `POST /v3/replenishOrder/updatePriority`. **Gate (SBDEV-3606, pending merge): `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER`.** |
| `getActive(itemId, requestedLocationId)` | `(Long, Long) → List<Replenishorder>` | `readOnly` | — | `GET /v3/replenish/active` |
| `cancelReplenishmentOrder(replenishOrder)` | `(Replenishorder) → void` | `tenantTransactionManager` | `FacadeException` | `DELETE /v3/replenish/{id}` |
| `redirectSource(orderId, newStockUnitId)` | `(Long, Long) → Replenishorder` (SBDEV-3561; the entity overload was deleted) | `tenantTransactionManager` | `B, F` | Called by `update`, by `updateSourceStockUnit`, and by `POST /v3/replenishOrder/changeSourceStockUnit` (no UI caller; kept, but routed here). It locks the order first with `findByIdForUpdate`, then refuses `state > PROCESSABLE (300)` and names the state. It then locks both SUs in ascending id order. The target must have `reservedamount == 0`, the same item, not be the current source, and be a member of `getStockUnitInfoForReplenishment(itemdataId)`, the dialog's own list. It reserves the new SU, then releases the old one. A missing old source is tolerated. Refusals return a **422** `{errors:[{message}]}` from all three endpoints. Via `changeSourceStockUnit` the gate is `WEB_UI_ACTION_MANAGE_REPLENISHMENT_ORDER` (SBDEV-3606, pending merge); `cancelReplenishOrder/{id}` and `create` on the same controller are also MANAGE. The mobile `POST /v3/replenish` row above is **not** governed by MANAGE. |
| `updateReplenishmentOrderPriority(List, int)` | bulk variant | `tenantTransactionManager` | — | Called by picking job |
| `updateReplenishmentOrderPriority(List, int, int)` | bulk variant (old→new) | `tenantTransactionManager` | — | Called by picking job |
| `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` | `() → void` | `tenantTransactionManager` | — | Called by job |
| `existsForStockUnit(stockUnit)` | `(Stockunit) → Replenishorder` | `readOnly` | — | Used by stock movement guards |
| `getReplenishorderDetails(id)` | `(Long) → Map<String,Object>` | `readOnly` | — | `GET /v3/replenish/{id}/details` |
| `getStockunitInfoForReplenishment(id)` | `(Long) → List<Map>` | `readOnly` | — | `GET /v3/replenish/{id}/stockunitInfo` |

### `ReplenishOrderJobService`

All methods use `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`. This service exists to give each job-loop item its own isolated transaction so one failure does not abort the full job run.

| Method | Notes |
|---|---|
| `deleteEmptyFixAssignmentWithoutStockToReplenish(fixedLocationAssignmentId)` | Deletes FLA if it meets the "empty + no stock to replenish + no open orders" criteria. |
| `generateReplenishmentForItemDataWithoutFixedAssignment(itemDataId, amount)` | Calls `ReplenishGeneratorService.calculateOrder` with `destinationId = null`. |
| `generateReplenishmentForItemDataWithFixedAssignment(fixAssignmentId)` | Pre-validates FLA sanity (unitload on location, label matches, active, single SU) before calling `calculateOrder`. Triggers if `amountOnLocation < middleBound`. |
| `triggerRegularReplenishment()` | Iterates FLA IDs from `getRefillFixedLocations(FINISHED)`, calls `replenishGeneratorService.refillSingleFixedLocation(id)` per entry. |
| `updateReplenishmentOrderPriority(replenishOrderId, priority)` | Direct priority set — bypasses `manuallyoverridepriority` flag. |
| `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` | Delegates to `ReplenishorderService`. |
| `getRefillFixedLocationIds()` | Read-only query — returns FLA IDs eligible for refill. |
| `refillFixedLocationAssignment(fixLocationAssignmentId)` | `rollbackFor = FacadeException.class`; delegates to `refillSingleFixedLocation`. |
| `cancelReplenishmentOrder(replenishmentOrderId)` | Delegates to `ReplenishorderService.cancelReplenishmentOrder`. |

### `MobileReplenishService` (selected public methods)

All write methods: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.

| Method | Notes |
|---|---|
| `loadOrderByDestination(locationName)` | Loads order for a fixed-location scan. Throws if location not found or not a FLA. |
| `loadOrderById(id)` | Simple order load; no transaction. |
| ~~`startOrder(mOrder)` / `resetOrder(mOrder)`~~ | **Deleted by SBDEV-3608 P6** (zero callers in any repo). They moved `PROCESSABLE ↔ STARTED`; with them gone nothing in the live flow produces `STARTED (500)`. |
| ~~`checkSource(mOrder, code)`~~ | **Removed by SBDEV-3638 (merged 2026-10-02, `f839921e`).** Validated or switches source unit load via `switchSourceToUnitLoad` (re-source writer 3, §2 table above). **API-only**: no UI dispatches `/checkSource`, `/checkAmount` or `/checkDestination` since SBDEV-3608 P11. |
| ~~`checkDestination(mOrder, code)`~~ | **Removed by SBDEV-3638 (merged 2026-10-02, `f839921e`).** Validated destination; created FLA on-the-fly. Replaced by the private `assignDestinationForMultiUnitLoads`. |
| ~~`finishReplenishmentOrder(mOrder)`~~ | **Removed by SBDEV-3638 (merged 2026-10-02, `f839921e`)** (public finish + its post-commit refill). Replaced by the private `finishReplenishmentOrderWithoutRefill`, reached only from `fulfillMultipleUnitLoads`, which runs its own best-effort `refillFixedLocations()` after the commit. |
| ~~`checkAmountPicked(mOrder, amount)`~~ | **Removed by SBDEV-3638 (merged 2026-10-02, `f839921e`).** Was validation only. |
| `fulfillMultipleUnitLoads(request)` | Multi-unitload path. See §7. |
| `update(id, dto)` | `PUT /v3/replenish/order/{id}`, the handheld's source-location scan (`selectSource.vue`). **Writes nothing (SBDEV-3607, pending merge on `bugfix/SBDEV-3607-mobile-put-source-location`).** Reads the order with `findByIdForUpdate`, refuses a null state or state > `PROCESSABLE(300)` (same guard as `ReplenishorderService.redirectSource`), validates the scanned location and echoes its id + canonical name in the response, because the handheld stages unit loads with `locationId: order.requestedLocationId`. `fulfillMultipleUnitLoads` is the only writer of the source (stock unit, location, name together). Before the fix it set `requestedlocationId`/`sourcelocationname` unlocked and left `stockunitId` alone, so a recalc tick before submit failed `isSourceUsable` and re-sourced or cancelled the order (`MobileReplenishSourceScanIT`). |
| `getCalculatedOrders(code, clientId)` | Returns `PROCESSABLE` orders as select-item list for mobile picker. |
| `getReservedOrder()` | Returns `STARTED` order reserved by current operator. |

---

## §3 Service Dependency Tree

```
ReplenishOrderJob (cron)
├── ReplenishOrderJobService (REQUIRES_NEW wrappers)
│   ├── ReplenishGeneratorService        ← order creation + reservation
│   │   ├── StockunitBusinessService     ← changeReservedAmount
│   │   ├── ItemdataService
│   │   ├── BasicService                 ← generateReplenishNumber
│   │   ├── ReplenishorderRepository
│   │   ├── FixLocationAssignmentRepository
│   │   ├── StockunitRepository
│   │   ├── UnitloadRepository
│   │   └── LocationRepository
│   ├── ReplenishorderService            ← cancel, priority, recalc
│   │   ├── ReplenishGeneratorService
│   │   ├── StockunitBusinessService
│   │   └── [repositories]
│   └── FixLocationAssignmentService     ← delete FLA
│
├── ReplenishmentOrderMaintenanceService ← recalculate open orders; reassign/cancel on move (SBDEV-2074)
│   ├── StockunitBusinessService
│   ├── SyspropService                   ← cadence, threshold, upper-bound sysprops
│   ├── ReplenishorderRepository
│   ├── StockunitRepository
│   ├── UnitloadRepository
│   ├── LocationRepository
│   ├── LocationAreaRepository           ← also: LocationReplenishabilityUtil.isReplenishableArea
│   └── FixLocationAssignmentRepository
│
└── [also drives] MobileReplenishService (via recalculateOpenOrders post-finish)

MobileReplenishService (mobile API)
├── ReplenishGeneratorService
├── ReplenishmentOrderMaintenanceService
├── StockunitBusinessService
├── FixLocationAssignmentService
└── [repositories]

ReplenishorderService (desktop API)
└── ReplenishGeneratorService (via create → calculateOrder)

[stock-move choke point, e.g. UnitloadBusinessService.transferUnitLoadToLocation]
└── ReplenishmentOrderSourceSyncService.syncForMovedStockUnit   ← SBDEV-2492 / SBDEV-2074
    ├── ReplenishorderRepository
    ├── LocationRackRepository
    ├── LocationAreaRepository           ← LocationReplenishabilityUtil.isReplenishableArea
    └── ReplenishmentOrderMaintenanceService (@Lazy — DI-cycle breaker)
        └── reassignOrCancelForMovedStockUnit → redirectSource / cancelOrder
```

---

## §4 Data Model

### 4.1 Entities

#### `Replenishorder` — table `replenishorder`

Extends `AbstractBaseEntity` (provides `id`, `version`, `created`, `modified`).

| Column | Java field | Type | Nullable | Notes |
|---|---|---|---|---|
| `id` (PK) | `id` | `Long` | N | From `AbstractBaseEntity` |
| `version` | `version` | `Integer` | N | Optimistic lock via `@Version` (inherited) |
| `number` | `number` | `String` | N | Unique order number; format `REPL-<seq>` for standard; `REPL-<seq>-<n>` for multi-unitload sub-orders |
| `state` | `state` | `Integer` | N | See §5 state machine; default `RAW (0)` |
| `prio` | `prio` | `Integer` | N | Priority; default `PRIORITY_VERY_LOW (0)` |
| `requestedamount` | `requestedamount` | `NUMERIC(17,4)` | Y | Amount to move; capped at source stock amount |
| `sourcelocationname` | `sourcelocationname` | `String` | Y | Denormalized source location name (snapshot at creation) |
| `entity_lock` | `entityLock` | `Integer` | Y | Always set to `0` at creation |
| `additionalcontent` | `additionalcontent` | `String` | Y | Free-text field; not used by current logic |
| `manuallyoverridepriority` | `manuallyoverridepriority` | `Boolean` | Y | When `true`, maintenance service skips priority recalculation |
| `client_id` (FK→client) | `clientId` | `Long` | N | Client owning the stock |
| `itemdata_id` (FK→itemdata) | `itemdataId` | `Long` | N | SKU being replenished |
| `stockunit_id` (FK→stockunit) | `stockunitId` | `Long` | Y | Source stock unit; reservation is held here |
| `requestedlocation_id` (FK→location) | `requestedlocationId` | `Long` | Y | Source location snapshot |
| `requestedrack_id` (FK→location_rack) | `requestedrackId` | `Long` | Y | Source rack snapshot |
| `destination_id` (FK→location) | `destinationId` | `Long` | Y | Target fixed location; may be `null` for items without FLA |
| `operator_id` (FK→mywms_user) | `operatorId` | `Long` | Y | Operator who claimed the order (`startOrder`) |
| `moved_amount` | `movedAmount` | `NUMERIC(17,4)` | Y | **SBDEV-1714 finish-time snapshot.** Actual moved qty (`amountPicked`), frozen at finish. NULL on pre-V2.2.03 rows. |
| `moved_source_unitload_label` | `movedSourceUnitloadLabel` | `String` | Y | **SBDEV-1714.** Source UL label captured **before** the transfer re-homes the source stock unit. NULL on pre-V2.2.03 rows. |
| `moved_destination_unitload_label` | `movedDestinationUnitloadLabel` | `String` | Y | **SBDEV-1714.** Destination (FLA-assigned) UL label at finish. NULL on pre-V2.2.03 rows. |
| `moved_destination_location_name` | `movedDestinationLocationName` | `String` | Y | **SBDEV-1714.** Destination location name at finish. NULL on pre-V2.2.03 rows. |

#### `FixLocationAssignment` — table `fix_location_assignment`

| Column | Java field | Type | Nullable | Notes |
|---|---|---|---|---|
| `id` (PK) | `id` | `Long` | N | From `AbstractBaseEntity` |
| `active` | `active` | `Boolean` | Y | When `false`, maintenance service ignores FLA |
| `lowerbound` | `lowerbound` | `NUMERIC(17,4)` | N | Minimum desired stock; default `0` |
| `middlebound` | `middlebound` | `NUMERIC(17,4)` | N | Trigger threshold — refill triggered when `amount < middlebound`; default `0` |
| `upperbound` | `upperbound` | `NUMERIC(17,4)` | N | Target fill level; default `0` |
| `assignedlocation_id` (FK→location) | `assignedlocationId` | `Long` | N | The fixed picking location (flowbin slot) |
| `assignedunitload_id` (FK→unitload) | `assignedunitloadId` | `Long` | N | The unit load sitting on the assigned location; stock is transferred here at finish |
| `itemdata_id` (FK→itemdata) | `itemdataId` | `Long` | N | SKU assigned to this slot |
| `entity_lock` | `entityLock` | `Integer` | Y | Lock state |

#### `ReplenishmentMonitorView` — table `replenishment_monitor_view` (DB view)

Read-only aggregate view of replenishment monitor data. Not modified by any service in this module.

### 4.2 Entity Relationships

```
Itemdata 1 ─── N Replenishorder (via itemdata_id)
Location  1 ─── N Replenishorder (via requestedlocation_id — source)
Location  1 ─── N Replenishorder (via destination_id — destination, nullable)
Stockunit 1 ─── 1 Replenishorder (via stockunit_id; reservation held here)
Client    1 ─── N Replenishorder (via client_id)

Itemdata  1 ─── 1 FixLocationAssignment (unique per SKU)
Location  1 ─── 1 FixLocationAssignment (via assignedlocation_id)
Unitload  1 ─── 1 FixLocationAssignment (via assignedunitload_id)
```

---

## §5 State Machine

The `Replenishorder.state` field uses `WmsConstants.State` integer constants.

| From | Event | To | Guard | Code path |
|---|---|---|---|---|
| — | `calculateOrder` creates order | `PROCESSABLE (300)` | `amount > 0`, source stock available, no duplicate pending order | `ReplenishGeneratorService.calculateOrder:187` |
| `PROCESSABLE` | Operator calls `startOrder` ⚠ **no caller in src/main or in wms2-mobile-ui (SBDEV-3561 triage, 2026-09-29): this transition never fires in production, and PRD shows no state-500 rows** | `STARTED (500)` | Order not already finished; no other operator claimed it | `MobileReplenishService.startOrder:233` |
| `STARTED` | Operator calls `resetOrder` | `PROCESSABLE (300)` | State must be ≥ `PROCESSABLE` and < `FINISHED` | `MobileReplenishService.resetOrder:263` |
| `PROCESSABLE` or `STARTED` | `finishReplenishmentOrderWithoutRefill` completes (reached ONLY via `POST /v3/replenish/multi-unitloads`) | `FINISHED (700)` | Source stock present, destination present, state < `FINISHED`. ~~SBDEV-3561 F8a/F8b refusals~~ (removed by SBDEV-3638, merged 2026-10-02, `f839921e`, with the single-UL finish) are replaced by the `REPLENISH_MISSING_SOURCE` guard: the finish fails closed if the DTO's source stock unit is not the order's | `MobileReplenishService.finishReplenishmentOrderWithoutRefill` |
| `PROCESSABLE` | Maintenance detects source gone / destination full | `CANCELED (800)` | Shortage ≤ cancel threshold, or no usable source found | `ReplenishmentOrderMaintenanceService.cancelOrder:375` |
| `PROCESSABLE` or `STARTED` | `cancelReplenishmentOrder` | `CANCELED (800)` | State < `FINISHED (700)` | `ReplenishorderService.cancelReplenishmentOrder:219` |

Note: `PICKED (600)` exists in `WmsConstants.State` but is not used by the replenishment state machine. The state skips from `STARTED (500)` directly to `FINISHED (700)`.

**SBDEV-1714 finish-time audit snapshot (2026-07-20):** at `FINISHED`, `finishReplenishmentOrderInternal` (now `finishReplenishmentOrderWithoutRefill`, SBDEV-3638) now freezes what was moved onto the order — `moved_amount` (= `amountPicked`), `moved_source_unitload_label`, `moved_destination_unitload_label`, `moved_destination_location_name` (§4.1). The source-UL label is captured **before** `transferStockToUnitLoad` because that call re-homes the source stock unit's `unitloadId` in place (full move → destination UL `StockunitBusinessService:346`; partial-to-zero → `Nirwana` `:380/:422`) — reading it afterward would record the wrong label. The closed-record detail (`ReplenishorderService.getReplenishorderDetails`) and the desktop closed/detail list views (`getDetailViewByKeyword`, `getClosedViewByKeyword`) now read these frozen values via `COALESCE(frozen, live)`; `getOpenViewByKeyword` still reads the live join. Forward-only: pre-`V2.2.03` FINISHED rows keep NULL snapshots and degrade to the live join.

### Priority values (`WmsConstants.Priority`)

| Constant | Value | Meaning |
|---|---|---|
| `PRIORITY_VERY_LOW` | 0 | Default; assigned to all auto-generated orders |
| `PRIORITY_LOW` | 100 | — |
| `PRIORITY_MEDIUM` | 1000 | — |
| `PRIORITY_HIGH` | 10000 | — |
| `PRIORITY_URGENT` | 100000 | — |

Priority is inherited from the customer order driving the replenishment, via the job's `updateReplenishmentOrderPriority` phase. Orders with `manuallyoverridepriority = true` are excluded from all automatic priority updates.

---

## §6 `FixLocationAssignment` Relationship

A `FixLocationAssignment` (FLA) represents a permanent SKU-to-location binding: "item X always lives at flowbin slot Y."

### How FLAs gate replenishment

1. **Order creation** — `ReplenishGeneratorService.calculateOrder` accepts a `destinationId`. When called from the job's `generateReplenishmentForItemDataWithFixedAssignment` path, `destinationId = fla.assignedlocationId`. Orders for items without a FLA get `destinationId = null`.

2. **Trigger threshold** — `ReplenishOrderJobService.generateReplenishmentForItemDataWithFixedAssignment` checks `stockUnitList.get(0).getAmount() < fla.middlebound`. Only if below the middle bound does it call `calculateOrder` with `required = fla.upperbound - amountOnLocation`.

3. **Maintenance alignment** — `ReplenishmentOrderMaintenanceService.recalculateOrder` calls `resolveActiveAssignment` to fetch the FLA, then `alignDestination` to set `destinationId` on orphaned orders (orders with `destinationId = null` that now have an active FLA). It also uses `fla.upperbound` as the target fill level for shortage calculation.

4. **Cancellation trigger** — `getIdsToCancelReplenishOrders` query cancels orders where `stockUnit.amount >= fla.upperbound` (flowbin full) — `ReplenishOrderJob:269`.

5. **FLA creation at finish** — `MobileReplenishService.finishReplenishmentOrderWithoutRefill` (formerly `finishReplenishmentOrderInternal`; SBDEV-3638) creates a FLA on-the-fly if none exists for the destination location, calling `FixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, itemData)`. This means destinations scan-confirmed by the operator implicitly become permanent fixed locations.

6. **FLA deletion** — `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` removes FLAs where the assigned unit load has zero stock AND there is no replenishable source stock AND no open advice positions AND no open replenish orders. Controlled by sysprop `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` (default `false`).

### FLA lifecycle during replenishment

```
                  ┌─────────────────────────────────────────────────┐
                  │  FixLocationAssignment                          │
                  │  assignedlocationId → Location (flowbin slot)  │
                  │  assignedunitloadId → Unitload (container)      │
                  │  itemdataId         → Itemdata (SKU)            │
                  │  upperbound / middlebound / lowerbound          │
                  │  active = true/false                            │
                  └─────────────────────────────────────────────────┘
                               │
       Job reads middlebound    │   finishReplenishmentOrderWithoutRefill
       amountOnLocation <       │   transfers stock to
       middlebound → generate   │   assignedunitload
                               ▼
                  ┌─────────────────────────────────────────────────┐
                  │  Replenishorder.destinationId = fla.assignedlocationId │
                  └─────────────────────────────────────────────────┘
```

---

## §7 Multi-Unitload Replenishment Path

Endpoint: `POST /v3/replenish/multi-unitloads` → `MobileReplenishService.fulfillMultipleUnitLoads`.

Request: `{ orderId, destinationLocationId, destinationLocationName, unitLoads: [{ id, labelId, locationId, qty }] }`.

Response: `[{ id, number, qty, unitLoadId, status, destinationLocationId }]` — one entry per order processed.

### Transaction boundary

⚠ **Corrected — SBDEV-3605 (2026-09-30).** This section used to say the entire method runs in a single `@Transactional`. It does not: the public entry point, `fulfillMultipleUnitLoads`, is deliberately **NOT** `@Transactional` (its own javadoc says so). It calls `self.fulfillMultipleUnitLoadsTx(request)` through the Spring proxy — that method carries `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` and is the actual atomic core: all-or-nothing for every stock transfer, reservation release, and order state change inside it. Only *after* that transaction has committed and released every pessimistic lock does `fulfillMultipleUnitLoads` best-effort run `replenishGeneratorService.refillFixedLocations()` and `replenishmentOrderMaintenanceService.recalculateOpenOrders(true)` — with no ambient transaction, and any exception from either just logged (`LOG.warn`), never rolling back the fulfillment. This split exists so the refill/recalc's own `REQUIRES_NEW` sub-transactions never open while the multi-UL locks are still held (§11 item 4).

### Flow

⚠ **Step order corrected — SBDEV-3605, Nam approved 2026-09-30, commit `6a4a1bd3` (branch HEAD `d6fa6821`).** An earlier revision of this section locked the template, then resolved/locked SUs, then assigned the destination last. Destination assignment now runs BEFORE any SU work — see the flow below and the landmine in the transaction/OSIV boundary map §8.5.

```
fulfillMultipleUnitLoads(request)                         ← NOT @Transactional
  │
  └─ self.fulfillMultipleUnitLoadsTx(request)              ← @Transactional(tenantTransactionManager)
       │
       ├─ 1. Lock the template order FIRST — `replenishorderRepository.findByIdForUpdate(orderId)`
       │      (the transaction's first touch of any row; serialises this path with `redirectSource`,
       │      which also locks the order first). Refuse a null or ≥ FINISHED state before any further
       │      read, with `REPLENISH_ALREADY_FINISHED`.
       │
       ├─ 2. Empty-UL guard: `request.getUnitLoads()` null or empty → `BusinessException`.
       │
       ├─ 3. assignDestinationForMultiUnitLoads() — holding ONLY the order lock. Validates destination
       │      is flowbin (or FLA-free per SBDEV-2854); if the FLA is absent, `createFixedLocationAssignment`
       │      can SYNCHRONOUSLY run `triggerReplenishmentMaintenance` → `recalculateForItem` in the SAME
       │      transaction — which may top up, cancel or re-source THIS template (see the landmine in
       │      §8.5 of the transaction/OSIV boundary map).
       │
       ├─ 4. RE-GUARD the template: re-reads its (possibly maintenance-mutated) state and refuses
       │      `REPLENISH_ALREADY_FINISHED` again if maintenance finished or cancelled it — the step-1
       │      guard alone is stale once step 3 can mutate the same managed entity.
       │
       ├─ 5. resolveUnitLoadEntry() per DTO — ids only, no entity lock yet:
       │      `stockunitRepository.findIdsByUnitloadIdAndItemdataIdOrderById(unitloadId, itemdataId)`.
       │      The own-SU preference reads the template's CURRENT `stockunitId` — i.e. as maintenance in
       │      step 3 may have left it, not necessarily the id the request started with. When the scanned
       │      UL holds two SUs of the template's item, that current own SU is chosen if it is one of
       │      them; otherwise the lowest id (R6, amended 2026-09-30 — the earlier lowest-id-only rule
       │      lost the self-credit).
       │
       ├─ 6. Lock {current old SU} ∪ scanned SU ids in ONE ascending pass — `TreeSet<Long>` →
       │      `stockunitRepository.findByIdForUpdate` per id — so each lock is that row's first touch,
       │      UNLESS step 3's maintenance already read (not locked) the same row: that lock is then an
       │      UPGRADE, version-checked by Hibernate, so a row maintenance changed underneath this read
       │      fails closed as a stale-object 409 rather than silently proceeding. A row that no longer
       │      exists takes no lock and is absent from the `locked` map.
       │
       ├─ 7. `ownShareOfReservation(oldSu, templateId)` — computed ONCE, under the old SU's lock and
       │      AFTER step 3's maintenance, so it sees any top-up maintenance already booked: the part of
       │      `reservedamount` no other open replenish order or open pick position explains (the
       │      holder invariant — see the stockunit design doc §6).
       │
       ├─ 8. validateUnitLoadEntry() per entry, re-checking the LOCKED row (not the id-resolve read):
       │      ├─ refuses `MsgSourceStockNotFound` if the locked SU vanished, moved off this UL, or no
       │      │    longer carries the template's item (post-lock re-check, added in review 2026-09-30)
       │      ├─ gates on availability (amount − reservedamount), not gross amount
       │      └─ self-source credit: when this entry's SU IS the old SU, adds back `ownShare` IN FULL
       │           — the credit equals the total that step 9 will release (Fix C)
       │
       ├─ 9. First instruction reuses the template order:
       │      applyExplicitSourceToOrder() books the release as TWO rows against the old SU, both
       │        under the order's own number: FINISHED `−min(req⁺, ownShare)`, then
       │        MANUAL_ADJUSTMENT `−remainder` (comment: "SBDEV-3605 unexplained reservation
       │        released") — `req⁺ = max(0, requestedamount)`, so attributed + remainder == ownShare
       │        always; then sets destination/source/`requestedamount`.
       │      finishReplenishmentOrderWithoutRefill(buildMobileDto()) transfers stock, sets order
       │        FINISHED (no refill triggered).
       │      `replenishorderRepository.flush()` — the template's state=700 transition is flushed
       │        before any child INSERT, so the child never sees it still occupying the partial
       │        unique index on (state<700).
       │
       ├─ 10. Remaining instructions (index 1..N) — new orders per unit load:
       │      ReplenishGeneratorService.createOrderFromTemplate() (REQUIRED — joins this transaction)
       │        ├─ number = template.number + "-" + (i+1)
       │        ├─ copies client, itemdata, prio, manuallyoverridepriority
       │        └─ reserves stock on the explicit Stockunit
       │      finishReplenishmentOrderWithoutRefill(buildMobileDto()); flush() before the next child.
       │
       └─ 11. Returns to `fulfillMultipleUnitLoads`, which (after commit, no ambient transaction) runs:
              replenishGeneratorService.refillFixedLocations()   ← single refill pass
              replenishmentOrderMaintenanceService.recalculateOpenOrders(true)
```

**Error order (R7, reverted 2026-09-30).** A destination rejection (step 3) now surfaces before any unit-load/stock error (steps 5, 8) — as on `develop` before this fix, not the "UL/stock errors first" order an earlier revision of this plan introduced.

**Batch cap (SBDEV-3605, security review Low).** `MultiReplenishRequestDto.unitLoads` carries `@Size(max = MultiReplenishRequestDto.MAX_UNIT_LOADS)` (`MAX_UNIT_LOADS = 50`), bounding the up-front lock set at step 6. A violation is a bean-validation failure, surfaced as **422** `parameterErrors` via `RestExceptionHandler` — not the 400s used elsewhere on this endpoint. The DEV maximum observed is 3 unit loads per batch; PRD is unmeasured.

### Key subtlety: `entityManager.refresh` after `createOrderFromTemplate`

⚠ **This section described a workaround that no longer exists. Corrected 2026-09-10 (SBDEV-3244).**

It used to read: *"`createOrderFromTemplate` runs in `Propagation.REQUIRES_NEW` … The `entityManager.refresh(inst.stock)` call at line 797 of `MobileReplenishService` re-syncs the entity with the database before that call — this is load-bearing, not ceremonial."*

Both halves are stale. `createOrderFromTemplate` is no longer `REQUIRES_NEW` — it carries `@Transactional(value = "tenantTransactionManager", rollbackFor = {FacadeException.class, BusinessException.class})` and joins the caller's transaction — and the `entityManager.refresh` call was **deleted** by `cc9ca6b0` (SBDEV-2575 / plan `260713` Fix B), which closed the mechanism by reshaping the transaction instead of re-reading the entity. `MobileReplenishService` contains no `entityManager` reference today; the only trace is a comment saying the workaround was removed. Verified with `git log -S 'entityManager.refresh' -- '*MobileReplenishService.java'`, not inferred from a failed grep.

**What remains true, and is worth keeping — the detection point.** The paragraph correctly located the throw at `changeReservedAmount → findByIdForUpdate` rather than at a later `save()`. That is `EntityInitializerImpl.upgradeLockMode → checkVersion`: a `@Lock(PESSIMISTIC_WRITE)` read of an entity **already managed in the same persistence context** is a lock UPGRADE, and Hibernate version-checks only on an upgrade. `SELECT … FOR UPDATE` blocks until the other writer commits and then returns the row at `v+1` while the `EntityEntry` still holds `v`, so it throws from **inside** the repository call.

⚠ **The consequence, which the old wording inverted:** a `refresh` placed *after* the locking read is **unreachable** in exactly the race it is written for. As of 2026-09-10 all 10 `.refresh(` sites in `src/main` sit immediately after a `findByIdForUpdate` (derived by `git grep -n '\.refresh(' -- src/main/java`; blind spot — it would miss a refresh reached indirectly through a helper). The remedy is to make the locking read the **first touch** of the row: carry ids across a lock boundary, never entities. See SBDEV-3244 for the worked case and SBDEV-3286 for the remaining sites.

---

## §8 `ReplenishOrderJob` Integration

`ReplenishOrderJob` is the cron orchestrator. It is not a `@Scheduled` bean itself — `SchedulingConfiguration` registers it programmatically on the `TaskScheduler`.

⚠ **Rewritten 2026-09-06 (SBDEV-3198, PR #304).** Two claims here were falsified by that change:

- **`doCalculation(Boolean isCronJob)` is gone** — deleted, not renamed, and absent from all of `src/main`. Entry points are now `runFor(TriggerSpec)` (scheduled, all matching tenants), `runForCurrentTenant()` (manual/admin, one tenant, returns whether it ran), and `deriveSpecForCurrentTenant()` (package-private; reads this tenant's own timer sysprops and zone, and throws if `TenantContext` is unset). The pipeline body is the private `replenish(String tenantName)` — `:415` at `d4a6ab8a`.
- **The schedule is no longer read once for the whole fleet.** It used to read `REPLENISHMENT_TIMER_MINUTE`/`_HOUR` under whichever single tenant the boot probe happened to land on, and applied that one tenant's hour/minute to every tenant in the process. Each tenant now fires on **its own** configured time, via one `CronTrigger` per distinct firing specification.

### Concurrency guards

Three layers, and the middle one is the load-bearing change:

1. **Distributed lock, per `(job, tenant)`** — `advisoryLockService.tryLock(JobLockId.REPLENISH_ORDER, tenantDbConfigurationId)`, the **two-key** `pg_try_advisory_lock` form. Two tenants firing at the same instant no longer contend; previously one fixed key per job meant N−1 tenants skipped silently at DEBUG. ⚠ A tenant whose `tenant_db_configuration.id` does not narrow to `int4` cannot be locked at all and is skipped **every** occurrence, with an ERROR naming the id — there is no fallback to the one-key form.
2. **Per-row optimistic locking** — the real correctness guarantee for the pipeline's writes. ⚠ **Two different counts, and they are not the same set** (re-derived 2026-09-06 at `d4a6ab8a`): **8 of the 9** private write methods **catch** `OptimisticLockException` / `OptimisticLockingFailureException`, but only **6 of the 9** page through candidate ids via `PageRequest`. The two that catch without paging are `triggerRegularReplenishment`, which iterates `getRefillFixedLocationIds()` **unbounded**, and `recalculateReplenishmentOrderWithoutFixedLocationAssignment`, which has no loop at all — its catch wraps a single service call, so "per row" does not describe it either. All four touched entities (`Replenishorder`, `FixLocationAssignment`, `Itemdata`, `Pickingorder`) inherit `@Version` from `AbstractBaseEntity`. `mergePickingOrders` is the exception: its conflict propagates to the outer per-tenant `catch`, aborting that tenant's whole occurrence rather than just that section — safe, but a coarser failure-isolation blast radius, and deliberately preserved. The two `ReplenishmentOrderMaintenanceService` calls use a different mechanism again — a pessimistic `findByIdForUpdate` (`SELECT … FOR UPDATE`) — though the lock sits one hop down: both loop and call `recalculateOrder`, which takes it. ⚠ The two paths differ in transaction shape: one goes through the proxy (`self.recalculateOrder`), the other deliberately uses a plain `this.` call because proxying there would mark the shared outer transaction rollback-only — the service's own comment explains why. The pessimistic lock is taken either way, but on one path it runs **inside the caller's transaction**, which "stronger mechanism" hides.
3. **JVM-local `AtomicBoolean RUNNING`** — unique among the six scheduled jobs and deliberately kept through the D′ conversion. ⚠ **It is a resource throttle, not a correctness guard**: this is the largest job body in the subsystem (nine sequential bulk operations per tenant, six of which page). Its scope is shared between `runFor()` and `runForCurrentTenant()`, matching its pre-D′ scope exactly.

### Tenant iteration

The job fetches all `TenantDbConfiguration` records from the landlord database, sets `TenantContext.setCurrentTenant(profile)` per tenant, and clears it in the `finally` block. Each tenant runs the full pipeline independently.

### Activation guard

```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(SYSTEM_PROPERTY_REPLENISHMENT_TIMER_ACTIVATED_KEY))) {
    continue;  // skip this tenant
}
```

Both `NEW_CRON_JOB_ACTIVATED` and `REPLENISHMENT_TIMER_ACTIVATED` must be `true`.

### Job pipeline phases

| Phase | Method | What it does |
|---|---|---|
| 1 | `mergePickingOrders()` | Merges tote-on-cart picking orders for TOTES_ON_CART sections. Gated by `MERGE_PICKING_ORDERS` sysprop. |
| 2 | `deleteEmptyFixAssignmentWithoutStockToReplenish()` | Deletes orphaned FLAs. Gated by `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` (default `false`). |
| 3 | `cancelUnreachableReplenishment()` | Cancels orders whose source stock is in a non-replenishable area (`la.useforreplenish = false`). Returns affected IDs. |
| 4 | `cancelReplenishmentIfFlowbinIsFull()` | Cancels orders where `stockUnit.amount >= fla.upperbound`. Returns affected IDs. |
| 5 | `generateReplenishmentForItemDataWithoutFixedAssignment()` | Generates orders for items with open customer orders but no FLA. Uses `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND` as the amount. |
| 6 | `generateReplenishmentForItemDataWithFixedAssignmentWithOrders()` | Generates orders for FLA items where demand exceeds stock. Uses native query to find eligible FLA IDs. |
| 7 | `triggerRegularReplenishment()` | Periodic refill of FLAs below their **lower** bound (the `getRefillFixedLocations` query). The lower bound is the trigger; the upper bound is the fill target used to size the order. |
| 8 | `updateReplenishmentOrderPriority()` | Syncs replenish order priority with customer order priority. Two passes: (a) reset to `PRIORITY_VERY_LOW` orders with no matching customer orders; (b) elevate to match `max(customerOrder.prio)` for orders that have active customer demand. |
| 9 | `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` | Back-fills `destinationId` on orders that gained a FLA since creation. |
| 10 | `recalculateForItem` / `recalculateOpenOrders` | Calls `ReplenishmentOrderMaintenanceService` — `recalculateForItem` per affected item, **then always** the cadence-gated full recalc (SBDEV-3624; it used to run only when nothing was affected). |

### Affected item tracking

Phases 3–7 return lists of affected IDs. The job unions these into `Set<Long> affectedItemIds` and calls `replenishmentOrderMaintenanceService.recalculateForItem(itemId)` per item, and **then always** calls `recalculateOpenOrders(false)`, which respects the cadence sysprop (`REPLENISHMENT_RECALCULATION_CADENCE_SECONDS`, default `0` = every cycle).

⚠ **Corrected — SBDEV-3624 (2026-10-01).** This used to read *"If `affectedItemIds` is empty (quiet cycle), it falls back to `recalculateOpenOrders(false)`"* — and that either/or was the defect. The ids are the ids each phase **attempted**, not the ids it changed, so a candidate the cron can never replenish (an FLA with demand above its flowbin and no source stock) keeps the set non-empty on every cycle and the full sweep never ran. On DEV wineco three such FLAs starved it for months (the latest cron-attributable replenish write was 2026-08-28; the only sweeps were manual forced ones from `fulfillMultipleUnitLoads`). The per-item loop is kept: when a cadence > 0 skips the sweep it is the only path keeping the touched items current.

**Drain loops (SBDEV-3624).** The five page-0 drain loops (phases 3–6 plus `deleteEmptyFixAssignmentWithoutStockToReplenish`) and both priority passes of phase 8 go through `ReplenishOrderJob.drainPageZero`: each id is attempted **at most once per run** (also when it repeats within one page — the fixed-assignment query groups by stock-unit columns), and a page that brings no new id ends the loop with a `"<sub-op> stalled …"` WARN instead of the old misleading `"hit page-limit cap … consider raising REPLENISHMENT_PAGE_LIMIT"`. Before, a stuck row was re-processed on every one of the `REPLENISHMENT_PAGE_LIMIT` (default 100) pages. Known limit, deliberately not fixed: if stuck rows fill an entire page (`REPLENISHMENT_PAGE_SIZE`, default 1000), rows behind them are not reached that run — the stall WARN says so (`"page 0 is full"`); reaching them needs keyset paging (`id > :afterId`). PRD had 0 stuck fixed-assignment candidates on all 4 tenants on 2026-10-01.

---

## §9 Cross-Service Interactions

### With `StockunitBusinessService`

`changeReservedAmount(stock, delta, isDelta, activityCode, orderNumber, comment)` is the central reservation primitive. Activity codes used by replenishment:

| Code constant | Value | When written |
|---|---|---|
| `CODE_REPLENISHMENT_CREATED` | `"REPLENISHMENT_CREATED"` | Order created; reservation added |
| `CODE_REPLENISHMENT` | `"REPLENISHMENT"` | Reservation adjustment during recalc |
| `CODE_REPLENISHMENT_FINISHED` | `"REPLENISHMENT_FINISHED"` | Reservation released at order finish |
| `CODE_REPLENISHMENT_CANCELLED` | `"REPLENISHMENT_CANCELLED"` | Reservation released at cancel |
| `CODE_REPLENISHMENT_SWITCHED` | `"REPLENISHMENT_SWITCHED"` | Reservation transferred when source unit load is switched |
| `CODE_REDIRECT_REPLENISHMENT_SOURCE` | `"REDIRECT_REPLENISHMENT_SOURCE"` | Reservation transferred during manual source redirect |

`transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked, ...)` is called at `finishReplenishmentOrderWithoutRefill` (formerly `finishReplenishmentOrderInternal`) to physically move stock to the FLA's assigned unit load.

### With Picking

The replenish job's phase 8 reads `customerorder.prio` to derive replenishment priority. If a customer order's priority changes, the replenishment order tracking that item will be updated on the next job cycle. The job also reads `customerorder_position` to find items with insufficient stock for upcoming orders (phases 5–6).

### With `FixLocationAssignmentService`

`createFixedLocationAssignment(location, itemdata)` is called in two scenarios:
- ~~`MobileReplenishService.checkDestination`~~ — removed by SBDEV-3638 (merged 2026-10-02, `f839921e`).
- `MobileReplenishService.assignDestinationForMultiUnitLoads` — when the resolved destination has no existing FLA (multi-UL path).
- `MobileReplenishService.finishReplenishmentOrderWithoutRefill` — when no FLA exists at the destination at finish time.

This means replenishment execution can create FLAs as a side effect.

### With stock movement (unit load relocation) — SBDEV-2492 / SBDEV-2074

When a unit load carrying stock bound to an active replen (`state < FINISHED`) is relocated, the move choke point (`UnitloadBusinessService.transferUnitLoadToLocation`, `@Transactional(tenantTransactionManager)`) calls `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit(stockUnit, destinationLocation)` synchronously, inside the move's own transaction. It branches on whether the destination's `LocationArea.useforreplenish` flag is `TRUE` (via `LocationReplenishabilityUtil.isReplenishableArea`; a `null` area is treated as NON-replenishable):

- **Replenishable destination** — original **SBDEV-2492** behavior, unchanged: re-point `requestedlocationId` / `requestedrackId` / `sourcelocationname` on the bound order onto the new location. `stockunitId` and the reservation amounts are never touched (same stock unit, only its location changed).
- **NON-replenishable destination** — **SBDEV-2074 (2026-07-20)**: delegates to `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit`, which releases the reservation from the moved stock unit and reassigns the *same* `Replenishorder` to another eligible source via `redirectSource`, or cancels it via `cancelOrder` if no candidate exists.
  - **SBDEV-3618:** it now locks the moved stock unit (`findByIdForUpdate`) before reading the order's held share. The lock order is order → current → target, the same as recalc. A candidate that *is* the moved SU counts as no candidate (AC5-guard).

Both branches block with `BusinessException` (rejecting the move, HTTP 422) if the bound order is already `state >= STARTED (500)`, including `530` — an in-progress replenishment must be completed or cancelled first, not silently re-pointed or reassigned underneath the operator picking it.

**Why a move-time entry point was needed:** before SBDEV-2074, the only place that could redirect a `RESERVED (400)`-adjacent order's source was the maintenance cron — `recalculateOrder` (gated on `state == PROCESSABLE (300)`) or `ReplenishOrderJob.cancelUnreachableReplenishment` (gated on `state <= 300`). A `RESERVED (400)` order whose source got moved onto a non-replenishable lane at move time fell into neither gate and stayed stuck until the state regressed or a human intervened. `reassignOrCancelForMovedStockUnit` closes that gap by reacting at the moment of the move itself, reusing the same `redirectSource` / `cancelOrder` primitives the cron already relies on.

**DI cycle:** `ReplenishmentOrderSourceSyncService` now depends on `ReplenishmentOrderMaintenanceService`. The dependency is injected via a `@Lazy` constructor parameter to avoid a circular-bean-creation failure (neither service depended on the other before SBDEV-2074).

---

## §10 Repository Native Queries

### `ReplenishorderRepository` — key queries

| Method | Type | Purpose |
|---|---|---|
| `findByIdForUpdate(id)` | JPQL + `PESSIMISTIC_WRITE` | Pessimistic lock for concurrency-sensitive updates |
| `getIdsForUnreachableReplenishOrders(state)` | Native | Finds orders where source stock's location area has `useforreplenish = false` |
| `getIdsToCancelReplenishOrders(state)` | Native | Finds orders where `stockUnit.amount >= fla.upperbound` (flowbin full) |
| `getIdsToDeleteEmptyFixAssignmentWithoutStockToReplenish(...)` | Native | Complex: FLAs with zero stock, no replenishable source, no open advice or replenish orders |
| `getIdsForItemDataWithFixedAssignmentWithOrders(...)` | Native | FLA IDs where demand (sum of open cop.amount + reservedAmount) > stockUnit.amount |
| `getIdsToUpdateReplenishmentOrderPriority(...)` | Native | Replenish orders with no active customer demand (priority should reset to VERY_LOW) |
| `getIdsToUpdateReplenishmentOrderPriority2(...)` | Native | Replenish orders whose priority doesn't match max customer order priority |
| `sumRequestedAmountForOpenOrders(state, itemDataId, destinationId, excludedId)` | JPQL | Sum of inbound replenishment already en route to a location (used by recalc to avoid over-ordering) |
| `findDetailMapById(id)` | Native | Full detail join (client, itemdata, user, locations, rack, stock) for desktop detail view |
| `bulkUpdatePriorityForItems(priority, itemdataIds, state, currentPrio)` | `@Modifying` JPQL | Bulk priority update — used by picking order priority sync |

### `StockunitRepository` — replenishment-specific queries

| Method | Purpose |
|---|---|
| `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage(notLocked, itemDataId, useForDeepStorage)` | Source stock selection in `calculateOrder`. Two passes: non-deep-storage first, then deep-storage fallback. |
| `getAvailableReplenishmentSources(itemDataId)` | Used by `redirectSource` in maintenance service to find best alternative source (prefers same area). Returns `[stockUnitId, amount, reserved, unitloadId, locationId, locationName, areaId]`. |
| `getStockAndReservedForLocation(itemDataId, locationId)` | Returns `[amount, reservedAmount]` at a specific destination location for shortage calculation. |
| `getStockAndReservedForPickingAreas(itemDataId)` | Returns `[amount, reservedAmount]` across all picking areas when no specific destination is set. |
| `getStockUnitInfoForReplenishment(itemDataId)` | Returns available unit loads with amount and location name for the desktop "change source" UI. |

### `FixLocationAssignmentRepository` — key queries

| Method | Purpose |
|---|---|
| `getRefillFixedLocations(replenishOrderStatus)` | FLAs eligible for refill: `stockunit.amount < fla.lowerbound` (the **lower** bound triggers; `ReplenishGeneratorService` then sizes the order as `upperbound - currentAmount`), `fla.active`, no open replenish order below that state on either the assignment's location or its item, and at least one unlocked unreserved source stock unit in a replenishable area. SBDEV-3153 split the open-order exclusion into two `NOT EXISTS` clauses — one per column — because the previous single clause joined them with `OR`, which Postgres cannot index (885.9ms to 59.2ms on dev). The FROM/WHERE is shared with `getRefillFixedLocationIds` via the `REFILL_ELIGIBILITY_FROM_WHERE` constant. |
| `getRefillFixedLocationIds(replenishOrderStatus)` | ID-only variant of above (lighter query for the job loop). |
| `findByItemdataIdIn(ids)` | Bulk FLA fetch by itemdata IDs — used by maintenance service `RecalcContext` builder. |

---

## §11 Known Limitations and Landmines

### 1. `refillFixedLocations()` has no transaction boundary — landmine

`ReplenishGeneratorService.refillFixedLocations()` is `public void` with no `@Transactional`. Each item in its loop calls `refillSingleFixedLocation(ass.getId())` which runs in `REQUIRES_NEW`. A failure in one item is swallowed and logged, but the loop itself has no outer transaction — meaning partial completion is the intended behavior here, but it was also reached from `MobileReplenishService.finishReplenishmentOrderInternal` when `triggerRefill = true` — via `scheduleRefillAfterCommit(replenishOrder.getNumber())`, not by a direct call. ⚠ **Mechanism corrected 2026-09-10 (SBDEV-3244).** It read *"That call runs inside the finish transaction; if refill throws unexpectedly, the finish transaction rolls back."* It does not: `finishReplenishmentOrderInternal` calls **`scheduleRefillAfterCommit(...)`**, whose javadoc opens *"Defers … until AFTER the surrounding transaction commits."* The paragraph's **conclusion still stands** — the deferral exists precisely because a `REQUIRES_NEW` refill inside a lock-holding transaction hangs — but the stated cause was the opposite of the code. Callers should still audit this path. *(Method removed by SBDEV-3638, merged 2026-10-02, `f839921e`: `finishReplenishmentOrderInternal`, `scheduleRefillAfterCommit` and `runRefillMaintenance` are gone. The only finish is now `finishReplenishmentOrderWithoutRefill`; `fulfillMultipleUnitLoads` runs its own best-effort `refillFixedLocations()` after the commit.)*

**Downstream plan needed:** Add a verify script to confirm `refillFixedLocations` is always invoked from within a safe context. See `wms-bugfix-plan` convention.

### 2. `calculateOrder` returns `null` for duplicate — callers must handle

When a `PROCESSABLE` order already exists for the same item + destination, `calculateOrder` returns `null` (not an exception). Several callers silently discard this: `ReplenishorderService.create` returns `null` to the controller which returns HTTP 200 with empty body. Callers should be aware that `null` means "order already exists, nothing to do" — not an error.

### 3. FLA auto-creation at `assignDestinationForMultiUnitLoads` and `finishReplenishmentOrderWithoutRefill` — surprise side effect

(Retitled by SBDEV-3638, merged 2026-10-02, `f839921e`: the former creators `checkDestination` and `finishReplenishmentOrder` are removed.) Both remaining creators can create `FixLocationAssignment` records as a side effect of an operator's scan. This is by design for the flowbin assignment flow, but can create unexpected FLAs if an operator scans the wrong destination. There is no undo mechanism — FLA deletion requires the job's cleanup phase (which is off by default) or manual DB intervention.

### 4. Transaction boundaries on the recalculate methods

**Current state (after 260520 fix):**

| Method | `@Transactional`? | Notes |
|---|---|---|
| `recalculateOpenOrders(boolean)` | **No** | Intentional — 260331 decision. The sweep calls `self.recalculateOrder` per order so each order opens its own short REQUIRED tx. |
| `recalculateForItem(Long)` | **Yes** — `tenantTransactionManager` | The HTTP-callable entry point. Inner loop calls `this.recalculateOrder` (bypasses proxy — see §5.4 warning below). |
| `recalculateOrder(Long, RecalcContext)` | **Yes** — `tenantTransactionManager, REQUIRED` | Added 260520; takes a `Long` since SBDEV-3244. Provides the tx that `findByIdForUpdate(@Lock PESSIMISTIC_WRITE)` requires. Per-order short tx from the sweep; annotation bypassed from `recalculateForItem` (this. call). |

**SBDEV-2234 (2026-05-18):** `recalculateForItem(Long)` gained `@Transactional(tenantTransactionManager)`. `recalculateOpenOrders(boolean)` intentionally remained NON-transactional (260331 decision). `findByIdForUpdate(@Lock PESSIMISTIC_WRITE)` was added expecting the sweep to provide a tx — but no per-order tx was opened, causing `InvalidDataAccessApiUsageException` in production.

**260520 fix:** `recalculateOrder` is now `public @Transactional(tenantTransactionManager, REQUIRED)` (its signature became `(Long, RecalcContext)` under SBDEV-3244). `recalculateOpenOrders(boolean)` calls it via `self.recalculateOrder(order, ctx)` (self-injection through CGLIB proxy) so each order gets its own short REQUIRED tx. The per-order auto-commit design from 260331 is preserved.

**§5.4 WARNING — do NOT change `recalculateForItem`'s inner loop to `self.recalculateOrder`:** `recalculateForItem` has an outer REQUIRED tx. Routing the inner loop through the proxy would cause `@Transactional + rollbackFor` to mark the shared outer tx rollback-only on any unchecked exception, which the try/catch swallows — but `UnexpectedRollbackException` fires on commit, poisoning all sibling orders. Most acute when called from `StockunitService.transferStock`.

⚠ **Corrected 2026-09-10 (SBDEV-3244) — this was backwards.** It read: *"`recalculateOpenOrders(true)` called from `MobileReplenishService.fulfillMultipleUnitLoads` runs inside the outer `@Transactional` method … so saves are still part of the outer transaction."* `fulfillMultipleUnitLoads` carries **no** `@Transactional` — its own javadoc says it is *"deliberately NOT `@Transactional`"* and runs the sweep *"only after that transaction has committed and released every pessimistic lock"*. Only `fulfillMultipleUnitLoadsTx` is annotated, reached through the `self.` proxy. So the sweep runs with **no ambient transaction**, which is exactly why it is immune to SBDEV-3244's defect — and adding `@Transactional` above either caller would reintroduce it. Pinned by `ReplenishmentStaleVersionAtLockReadIntegrationTest`'s AC-6b rail.

### 5. Amount cap at source stock size — silent reduction

`calculateOrder` caps `requestedamount` at `sourceStock.getAmount()`:
```java
replenishOrder.setRequestedamount(amount.compareTo(sourceStock.getAmount()) > 0 ? sourceStock.getAmount() : amount);
```
If a pallet holds less than the FLA's full `required` amount, the order silently delivers less than `upperbound - current`. No partial-fill flag or follow-up order is created. The destination may remain below `upperbound` until the next job cycle.

### 6. Multi-unitload `entityManager.refresh` dependency — fragile ordering

⚠ **Withdrawn 2026-09-10 (SBDEV-3244) — this landmine told the reader to preserve a call that no longer exists.** It read: *"The `entityManager.refresh(inst.stock)` call in `fulfillMultipleUnitLoads` (line 797) is load-bearing (see §7). Removing it, moving it, or calling `createOrderFromTemplate` inside the outer transaction instead of `REQUIRES_NEW` will cause `ObjectOptimisticLockingFailureException` on the second unit load. Any refactoring of the multi-unitload path must preserve this refresh."*

The refresh was deleted and `createOrderFromTemplate` **was** moved into the caller's transaction — by `cc9ca6b0` (SBDEV-2575 / plan `260713` Fix B), which is precisely the change this paragraph forbade, and it is the change that *removed* the hazard rather than causing it. Collapsing `REQUIRES_NEW` → `REQUIRED` means the inner work no longer commits independently, so there is no cross-transaction version bump for the outer context to be stale against, and the workaround became unnecessary. Details in §7.

**The surviving rule, stated so it cannot rot the same way:** on this path, do not reintroduce `REQUIRES_NEW` around `createOrderFromTemplate` without also reintroducing a way to re-sync `inst.stock` — and note that a `refresh` placed *after* the locking read would not work, because the locking read throws first (§7).

### 7. Source stock selector prefers "enough stock" but falls back silently

`calculateOrder` iterates `stockList` in order (returned by `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage`) and picks the first stock unit with `amount >= requestedAmount`. If none exists, it falls back to `stockList.get(0)` (the first available unit). The `requestedamount` is then capped to that stock's actual amount, producing a partial-fill order with no warning.

### 8. `manuallyoverridepriority` bypass is total

Once `manuallyoverridepriority = true`, all automatic priority updates are skipped by both `ReplenishmentOrderMaintenanceService.recalculateOrder` and `ReplenishOrderJob.updateReplenishmentOrderPriority`. There is no TTL or expiry mechanism — the manual override sticks until the operator explicitly changes the priority again via the desktop UI (which sets `manuallyoverridepriority = true` again) or through direct DB correction.

### 9. No cross-tenant replenishment

Each job iteration calls `TenantContext.setCurrentTenant(profile)` before any query. All repositories route to the current tenant's database. There is no mechanism for cross-tenant stock movement.

### 10. `redirectSource` reserve-before-release ordering — fixed 2026-07-20 (SBDEV-2074 M4)

`redirectSource` (used by both `recalculateOrder`'s `ensureValidSource` path and the new `reassignOrCancelForMovedStockUnit` move-time path) now reserves the alternate source stock **before** releasing the old one. Previously it released the old reservation first; if the subsequent reserve on the alternate then threw `FacadeException`, the old source was already released, the order still pointed at it, and the caller's `cancelOrder` released it a *second* time — driving `reservedamount` negative. The reordering fixes this: on a reserve failure the old source is left untouched, `redirectSource` returns `false`, and the caller's `cancelOrder` releases the old source exactly once. The success-path end state is unchanged.

**Accepted follow-on contract (M5):** `changeReservedAmount` is `@Transactional(rollbackFor = FacadeException.class)` and joins the caller's tenant tx, so a `FacadeException` on the alternate reserve marks the shared tx rollback-only even though `redirectSource` swallows it and returns `false`. The outer commit then throws `UnexpectedRollbackException`, rolling back the whole unit — for the move-time path, the relocation is rejected (HTTP 422) and the operator retries; the cron sweep remains the backstop for orders that never get retried through a move. This is intentional: the reserve is **not** `REQUIRES_NEW`, because a committed reservation on the alternate would be orphaned if the outer move then rolled back.

---

## §12 Related Docs

| Document | Location |
|---|---|
| WMS2 Replenish Workflow | `sbdocs/3-Resources/workflows/wms2-replenish-workflow.md` |
| WMS2 Multi-Unitload Replenish Workflow | `sbdocs/3-Resources/workflows/wms2-multi-unitload-replenish.md` |
| WMS2 Replenish Order Creation Workflow | `sbdocs/3-Resources/workflows/wms2-replenish-order-creation.md` |
| WMS1 Replenish Workflow | `sbdocs/3-Resources/workflows/wms1-replenish-workflow.md` |
| WMS1 StockUnit Design | `sbdocs/3-Resources/design/wms1-stockunit-design.md` |
| SBDEV-2074 plan (move-time reassign/cancel) | `sbdocs/1-Projects/wms2/plan/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.md` |
| SBDEV-2492 plan (archived — source re-point on move) | `sbdocs/4-Archieves/wms2/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md` |

---

## §13 Verification Log

| Date | Verified by | Notes |
|---|---|---|
| 2026-04-27 | Claude (executor) | Initial doc — all service methods read from source; all state constants verified against `WmsConstants.java`; entity fields verified against `Replenishorder.java` and `FixLocationAssignment.java`; repository queries verified against `ReplenishorderRepository.java` |
| 2026-05-08 | Claude (executor) | SBDEV-1699 (commit `c4fcfc1`) verified live: `ViewDtoService.getStockPerLocation` (line 672 onwards) uses batched `fixLocationAssignmentRepository.findByItemdataIdIn(itemdataIds)` (line 684); `ReplenishmentMonitorViewRepository` SQL exposes `f.upperbound AS fix_assignment_upperbound` (line 64) with re-projected aggregate column at line 31; `ReplenishMonitorSummaryView.getFix_assignment_upperbound()` getter present (line 32); `ViewDtoService.getReplenishMonitorViewSummary` (line 1194) emits DTO `locationStock` (line 1232 — `dto.put("locationStock", fixUpperBound.subtract(qtyOnLoc).longValue())`); `ViewDtoService.getReplenishMonitorViewSummary` and the detail-view method at line 601 both annotated `@Transactional(value = "tenantTransactionManager", readOnly = true)`. No drift to module body required. |
| 2026-05-19 | Claude (executor) | SBDEV-2234 (merged 2026-05-18): `recalculateForItem(Long)` now `@Transactional(tenantTransactionManager)` — §4 limitation #4 updated to reflect this; `recalculateOpenOrders(boolean)` intentionally remains non-transactional (260331 decision, confirmed in tx-osiv-boundary-map 2026-05-15 entry). `ReplenishorderRepository.findByIdForUpdate` now actively called by `recalculateOrder` (already documented in §key files table). `SyspropService.setSysvalue` added (documented in wms2-sysprop-catalog 2026-05-15). `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` sysprop replaces JVM-local `lastRun` field. |
| 2026-05-20 | Claude (executor) | 260520 fix: `recalculateOrder(Replenishorder, RecalcContext)` now `public @Transactional(tenantTransactionManager, REQUIRED)` (Fix A — plan `260520-replenishment-open-orders-missing-tx`). `@Lazy @Autowired self` field added to service; `recalculateOpenOrders(boolean)` sweep loop changed to call `self.recalculateOrder(order, ctx)` (per-order short REQUIRED tx). §4 method table updated (visibility + annotation), §4 limitation #4 rewritten to reflect new 3-method tx boundary table. §5.4 WARNING documented. |
| 2026-07-20 | Claude (executor) | **SBDEV-1714** (V2), implemented 2026-07-20: finished replenishments lost audit data (closed record showed source UL `Nirwana` / stock-unit amount 0 because it held only a live FK to the drained source stock unit — 164/168 on wms2-wineco-dev). Added 4 nullable finish-time snapshot columns to `replenishorder` (Flyway `V2.2.03`); `finishReplenishmentOrderInternal` (now `finishReplenishmentOrderWithoutRefill`) captures the source-UL label + amount **before** `transferStockToUnitLoad` mutates the source, and freezes them on the order before `setState(FINISHED)`. `findDetailMapById`/`getReplenishorderDetails` surface the frozen values (additive, NULL-safe); `getDetailViewByKeyword` + `getClosedViewByKeyword` `COALESCE(moved_source_unitload_label, u.labelid)` for both display and keyword search; `getOpenViewByKeyword` unchanged. Forward-only. §4.1 table + §5 note updated. Plan: `sbdocs/4-Archieves/wms2/plan/SBDEV-1714-replenishment-finish-audit-snapshot.md`. |
| 2026-07-20 | Claude (writer) | SBDEV-2074 (V2), implemented 2026-07-20: verified against `ReplenishmentOrderMaintenanceService.java` (575→688 lines, new public `reassignOrCancelForMovedStockUnit`), `ReplenishmentOrderSourceSyncService.java` (`syncForMovedStockUnit` now branches on destination replenishability), and new `util/LocationReplenishabilityUtil.java` (M1 shared `isReplenishableArea` helper). §0 module inventory updated (new files + line counts); §2 gained `reassignOrCancelForMovedStockUnit` row and a new `ReplenishmentOrderSourceSyncService` subsection; §3 dependency tree gained the move-choke-point → `ReplenishmentOrderSourceSyncService` → (`@Lazy`) `ReplenishmentOrderMaintenanceService` edge; §9 gained a new "With stock movement" subsection describing the branch and the cron-gap it closes (`recalculateOrder` needs `state==300`; `cancelUnreachableReplenishment` needs `state<=300`; neither reaches a `RESERVED(400)` order re-pointed onto a non-replenishable lane at move time); §11 gained limitation #10 documenting the `redirectSource` reserve-before-release reorder (M4) that fixes a double-release/negative-`reservedamount` bug, plus the M5 accepted rollback contract (reserve is intentionally not `REQUIRES_NEW`); §12 cross-referenced the SBDEV-2074 plan and the archived SBDEV-2492 plan. No unrelated sections touched. |
| 2026-09-17 | Claude (executor) | **SBDEV-2976 Gap 3** (V2), committed `372a6906` on `bugfix/SBDEV-2976-replenish-location-search`: the Open/Closed Replenishment lists could not be searched by location — WineCo reproduced this 2026-09-02 looking for `SH-B03`. Measured on wms2-wineco-dev, keyword `SH-B03`: **0 rows before → 4,623 after** (4,622 destination, 1 source). `r.sourcelocationname` and `l.name` were already SELECTed (as `source`/`destination`) and rendered as the "Source / UL" and "Destination / Qty" columns, but were absent from the `CONCAT(...) LIKE` predicate, so the search failed silently. Fixed as the broader invariant — *every column the Replenishment list renders must be reachable from its keyword box* — which caught two more: `r.number` ("Replenishment #", a clickable drill-down link) and `c.name` ("Shipper / Brand", where only `cl_nr` was searchable). Applied to **all three** predicates: `getOpenViewByKeyword`, `getClosedViewByKeyword` and `getDetailViewByKeyword` (the ticket named only the first two; the third is HAL-reachable via `@RepositoryRestResource` and carried the identical defect). No new joins. **SBDEV-1714's `COALESCE(moved_source_unitload_label, u.labelid)` is untouched** — the §5 note above (frozen values on the closed/detail views, live join on the open view) still holds exactly as written, and is now pinned by a test. New `ReplenishorderLocationKeywordSearchIT` on the PostgreSQL Testcontainers lane, 14 assertions, all mutation-checked across 8 mutants. ⚠ The `CONCAT`-vs-`||` choice is load-bearing and now pinned: `||` propagates NULL and would drop the 7,471 no-destination rows (1.9%) from the Closed list silently. Measured cost: Open list 16.2→22.4 ms (the `location` join goes from `never executed` to a hash build); Closed count 2,332→2,703 ms (+16%). Not this doc's other sections — nothing else was re-derived on this pass. |
| 2026-09-30 | Claude (executor) | **SBDEV-3561** (V2), branch `bugfix/SBDEV-3561-change-source-stock-unit-guard`. Re-verified ONLY the §service-table rows `update`, `updateSourceStockUnit`, `updatePriority` and `redirectSource`, and the §state-table rows `startOrder` and `finishReplenishmentOrder`, against the SBDEV-3561 worktree. The routes were stale from before this ticket (`PUT /v3/replenish/...`); they are really `POST /v3/replenishOrder/*` (`ReplenishOrderController` `@RequestMapping("/v3/replenishOrder")`). `redirectSource` is now `(Long, Long)`, locked and guarded. The finish stale-source refusal was added. `startOrder` has zero callers. Nothing else in this doc was re-derived, and `last_verified` is left unchanged for that reason. |
| 2026-10-02 | Claude (writer) | **SBDEV-3638** (V2), branch `bugfix/SBDEV-3638-remove-single-ul-replenish-endpoints`, PR pending, NOT merged. Doc pass only: struck the removed handheld single-UL endpoints `GET /v3/replenish/checkSource\|checkAmount\|checkDestination` and what only they reached (`switchSourceToUnitLoad` = re-source writer 3, so the writer count is now three; `finishReplenishmentOrder` + refill; F8a/F8b; the SBDEV-3621 single-UL finish rule and `REPLENISH_FINISH_BLOCKED_BY_RESERVATIONS`; `findIdsByUnitloadId`). The only finish is the private `finishReplenishmentOrderWithoutRefill` via `POST /v3/replenish/multi-unitloads`, guarded by `REPLENISH_MISSING_SOURCE`. Verified against the worktree `.claude/worktrees/wms2-api/SBDEV-3638`. `last_verified` unchanged; nothing else re-derived. |
