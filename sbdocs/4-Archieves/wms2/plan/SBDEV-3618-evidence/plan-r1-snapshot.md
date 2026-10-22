---
title: "Recalc books against the order's held share, not its requested amount: no over-grant, reserved == requested after every recalc"
ticket: "SBDEV-3618"
ticket_url: "https://app.clickup.com/t/868mbz1jp"
type: "bugfix"
priority: "high"
status: "draft"
tier: T3
repos: [wms2-api]
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-10-01"
updated: "2026-10-01"
revision: "r1 — planner draft"
db_verified: true
db_verified_note: "DEV wineco (dev_wh01_om1) only, 2026-10-01. PRD not measured: every PRD MCP failed to connect this session. That is a §5.1 prerequisite, and it does not gate the work."
base_commit: "wms2-api 652f37f7 (origin/develop, fetched 2026-10-01)"
related:
  - "[[SBDEV-3605]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-2610]]"
tags:
  - plan
---

# SBDEV-3618 — Replenishment recalc over-grants an order's requested amount

**Ticket:** [SBDEV-3618](https://app.clickup.com/t/868mbz1jp) · **Tier:** T3 (reservation data integrity) · **Branch:** `bugfix/SBDEV-3618-recalc-held-share` · **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3618`

## 0. Affected sites (enumeration before drafting)

**How this was enumerated.** The sites below come from three greps on `origin/develop`, each with a stated blind spot:
- the symbol grep `getAvailableIncludingReservation`, which returned 2 callers;
- the pattern grep for the "add back the requested amount" idiom (`subtract(.*reserved.*).add(`), which returned 1 site;
- `changeReservedAmount(` together with a `getRequestedamount` within 3 lines, which returned 7 sites.

Blind spot: a release amount derived indirectly, through a local variable more than 3 lines away, is invisible to the last grep. `redirectSource`'s release was found by reading the file.

| # | Site (file · quoted snippet) | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `ReplenishmentOrderMaintenanceService` · `return amount.subtract(reserved).add(currentRequest);` | capacity adds back full requested | **yes** | **yes**, Fix A |
| 2 | same · `BigDecimal desiredAmount = shortage.min(getAvailableIncludingReservation(source, order));` | caller 1 (`recalculateOrder`) | yes | yes, via Fix A |
| 3 | same · `BigDecimal availableForOrder = getAvailableIncludingReservation(source, order);` | caller 2 (`isSourceUsable`) | yes | yes, via Fix A |
| 4 | same · `BigDecimal delta = desiredAmount.subtract(currentRequested);` (`updateRequestedAmount`) | books the delta against requested, not against held | **yes** | **yes**, Fix B |
| 5 | same · `BigDecimal releaseAmount = safe(order.getRequestedamount());` (`cancelOrder`) | releases full requested | yes: on an under-reserved shared SU it strips the other holder (clamped at 0) | **yes**, Fix C |
| 6 | same · `releaseReservation(currentSource, safe(order.getRequestedamount()),` (`redirectSource`) | same | yes | **yes**, Fix C |
| 7 | `ReplenishorderService` · `changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true, WmsConstants.CODE_REPLENISHMENT_CANCELLED` | manual cancel releases requested | yes | **no**: these are non-maintenance callers and a different entry surface. They fall under the SBDEV-3605 P-S5S6 proposal (§10 P-1) |
| 8 | `MobileReplenishService` · `changeReservedAmount(stockUnit_old, requestedAmount.negate(), true, WmsConstants.CODE_REPLENISHMENT_SWITCHED` | single-UL switch | yes | **no**: same as #7 |
| 9 | `MobileReplenishService` · `changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,` (finish) | single-UL finish | yes | **no**: same as #7 |
| 10 | `ReplenishGeneratorService` · `changeReservedAmount(sourceStock, replenishOrder.getRequestedamount(), false, WmsConstants.CODE_REPLENISHMENT_CREATED` | create reserves requested | no: a create adds, and `changeReservedAmount` refuses over-amount | no |
| 11 | `MobileReplenishService.ownShareOfReservation` | the SBDEV-3605 holder invariant | n/a (this is the fix's building block) | **yes**, extracted by Fix A |

**Why #7–#9 stay out of scope.** Once Fix B holds, a PROCESSABLE order leaves every recalc with `held == requested`, so a later release of `requested` equals a release of `held`. The residual exists only between drift and the next recalc, and for non-300 states (recalc touches only `PROCESSABLE`). On DEV, the count of SUs that carry two open orders is **0** (§1). They are proposed, not dropped.

## 1. Problem statement and DB evidence

Recalc can raise `replenishorder.requestedamount` above the stock unit's physical `amount`. The picker is then sent for stock that does not exist, and the destination's inbound is overstated, so its refill is suppressed.

**Live case (DEV, 2026-10-01).** SU **30685299** has `amount 18` and `reservedamount 18`. **REPL389503** (state 300) has `requestedamount 26`. The SBDEV-3618 ticket has the full ledger. In short:
- an admin absolute set (`StockunitService.adjustReservedAmount`) cut the reservation to 1 while the order requested 9;
- then recalc computed `18 − 1 + 9 = 26` and booked `+17`.

**Population, and what the new rule would do (DEV, 2026-10-01).** The query is in the appendix. Of the **565** open orders, all state 300:

| Measure | Count | Meaning |
|---|---|---|
| `would_shrink` (req > held + free) | **53** orders, **393** units | the over-granted orders; the units equal the ticket's "units unbacked", which is the cross-check |
| `topup_only` (held < req ≤ capacity) | **2** | under-reserved orders that can be re-reserved without shrinking |
| `holderless_surplus` (ownShare > req) | **93** | SUs carrying reservation no order explains, e.g. admin `MANUAL_ADJUSTMENT`. **The fix must not release these.** This is why "held" is `min(req, ownShare)`, not `ownShare` |
| `shared_su` (another open order on the same SU) | **0** | the positive control for the "others" term is by unit test only (§8) |

## 2. Root cause

### Bug 1: capacity adds back reservation that is not there
`getAvailableIncludingReservation` returns `amount − reserved + requested`. It assumes that all of `requested` sits inside `reserved`. On an under-reserved SU (`reserved < requested`), it adds back `requested − reserved` that does not exist. Both callers inherit the inflation:
- `recalculateOrder` grows the order;
- `isSourceUsable` keeps an exhausted source "usable".

### Bug 2: the reservation delta is booked against requested
`updateRequestedAmount` books `desired − requested`. With Bug 1 alone fixed, the example (amount 18, reserved 18, requested 26) gives `desired 18` and `delta −8`. That leaves reserved 10 against requested 18: stable, but still under-reserved. The top-up case is also missed: `if (desiredAmount.compareTo(currentRequested) == 0) return;` exits before an under-reserved order is re-reserved.

### Bug 3: releases use requested
`cancelOrder` and `redirectSource` release `requested`. When the order holds less than that, the excess comes out of another holder's reservation, and `zeroIfNegative=true` hides it. This is the SBDEV-3605 defect class, on the maintenance path.

**Existing guard (it does not prevent this).** `StockunitBusinessService.changeReservedAmount` throws `CANNOT_RESERVE_MORE_THAN_AVAILABLE` when `reserved + delta > amount`. So `reservedamount` never exceeds `amount`; only `requestedamount` can. The +17 in the live case landed exactly at 18.

## 3. Fix design

**Definitions.** All are computed under the source SU's row lock. `ensureValidSource` already takes that lock with `findByIdForUpdate` as the first touch (SBDEV-3244 F3); after a redirect, the source is the target, locked by F4.
- `ownShare = max(0, min(res, res − Σreq(other open replen, state<700, ≠ this order) − Σamount(open picks, state<600)))`. This is SBDEV-3605's invariant, unchanged.
- `held = min(max(req, 0), ownShare)`. This is the part of the reservation the order can claim. It never includes holder-less surplus beyond its own requested amount.
- `free = max(0, amount − res)`.
- `capacity = held + free`. This is the most the order can hold without taking from anyone.

### Fix A: one shared helper (`ReservationShareService`, new `@Service`)
- `ownShareOfReservation(Stockunit locked, Long excludeOrderId)` moves here from `MobileReplenishService`. The body is identical and uses the same two `@RestResource(exported=false)` queries.
- `heldShare(order, locked)` and `capacity(order, locked)` are added.
- `MobileReplenishService` delegates to it. Its package-private method stays as a one-line delegate, so the SBDEV-3605 unit tests and `MultiUnitLoadOwnShareContractUnitTest` stay unchanged.
- `ReplenishmentOrderMaintenanceService` gets it through a new constructor parameter.
- `getAvailableIncludingReservation` is **deleted**; both callers use `capacity`.
- Why a service and not a second copy: two copies of the invariant is exactly the drift this ticket is about. Why not `StockunitBusinessService`: it would gain a replenishment dependency, and it is already central.

### Fix B: `updateRequestedAmount` books against held
```java
// Before
if (desiredAmount.compareTo(currentRequested) == 0) return;
BigDecimal delta = desiredAmount.subtract(currentRequested);

// After
BigDecimal held = reservationShareService.heldShare(order, source);
BigDecimal delta = desiredAmount.subtract(held);
if (delta.signum() == 0 && desiredAmount.compareTo(currentRequested) == 0) return;
if (delta.signum() != 0) changeReservedAmount(source, delta, true, CODE_REPLENISHMENT, order.getNumber(), null);  // same catch → WARN, return
LOG.info when desiredAmount < currentRequested because capacity bound it (the convergence signal)
order.setRequestedamount(desiredAmount); save
```
Post-condition: `held' == requested'`. Proof sketch: `res' = res + desired − held`, and `ownShare'` rises by the same delta, because the other holders are unchanged under the lock. `desired ≤ capacity` means `res' ≤ amount`, so `changeReservedAmount` never throws on this path.

### Fix C: releases use held
- `cancelOrder` releases `heldShare(order, source)` instead of `requested`, when `source != null`.
- `redirectSource` releases `heldShare(order, currentSource)`, and computes it **before** the target reservation. The target *can* be the current source: the method's own comment says "So current and target CAN be the same row". Capturing `held` first makes a same-row redirect net `+newRequested − held` on that one row, and IT-3 covers it.
- `reassignOrCancelForMovedStockUnit` reaches `cancelOrder`, so it is covered with no separate edit.

**Behaviour changes, named:**
1. Over-granted orders shrink on their next recalc; on DEV that is 53 orders, 393 units. There is no data script (Nam, D3).
2. Under-reserved orders are re-reserved from free stock (2 on DEV).
3. Cancel and redirect release less when the order is under-reserved.
4. Holder-less surplus is untouched by recalc.

## 4. File change summary

| File | Change |
|---|---|
| `service/ReservationShareService.java` | **new**: `ownShareOfReservation`, `heldShare`, `capacity` |
| `service/ReplenishmentOrderMaintenanceService.java` | ctor param; delete `getAvailableIncludingReservation`; Fixes B and C |
| `service/mobile/MobileReplenishService.java` | `ownShareOfReservation` delegates (ctor param) |
| tests | see §8 |
| `sbdocs/3-Resources/design/wms2-replenishment-design.md` §7, `design/wms2-stockunit-design.md` §6, `architecture/wms2-function-to-docs-map.md` §9 | recalc booking rule, the helper, and the new class |

## 5. Implementation steps
1. **TDD gate:** failing tests U-1 to U-8 and IT-1 to IT-3 (§8).
2. Extract `ReservationShareService`; `MobileReplenishService` delegates. The SBDEV-3605 suites must stay green unchanged.
3. Fix A in ROMS (capacity), then Fix B, then Fix C, each as its own commit.
4. Update the docs, run the full suite against a fresh baseline, and run PIT scoped to ROMS and `ReservationShareService`.

### 5.1 Prerequisites
| Item | State |
|---|---|
| DB / Flyway | **N/A.** No migration; both indexes exist (`replenishorder_stockunit_id`, `index_pickingorder_position_pickfromstockunit_id`, checked on DEV) |
| Sysprop / flag | N/A |
| PRD measurement | **Required before and after deploy, does not gate.** Run the ticket's population query on the 4 PRD tenants. Positive control on DEV: SU 30685299 |
| Deploy order | N/A: single repo |

## 6. Horizontal scalability and v2 constraints

| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | No: the new service is stateless |
| 2 | Pool math | No: same tx, same connection |
| 3 | Scheduled jobs | No new job. The existing replenish cron's work per order grows by 2 indexed scalar queries (565 orders on DEV) |
| 4 | Long tx | No: per-order short tx unchanged |
| 5 | Affinity | N/A |
| 6 | Retry / idempotency | **Yes, improved.** The booking is idempotent: a re-run gives `delta 0`, because `held == requested` afterwards. Today a replay can re-grow a drifted order |
| 7 | Tenant context | Unchanged: same thread, same tx |
| 8 | Locks | **Yes.** Reads happen under the existing SU row lock; no new lock, no order change. Residual ABBA unchanged (`redirectSource` comment) |
| 9 | Cache | N/A: none on these entities |
| 10 | External notify | N/A |

v2 constraints: `tenantTransactionManager` is inherited (no new `@Transactional`; the service joins the caller's tx) · no OSIV reliance (all reads are in the tx) · jakarta · constructor injection · no H2 native SQL (JPQL scalar sums) · no controller change · metrics: the existing cron metrics, plus a Fix B INFO log.

## 7. Risks

| Risk | Mitigation |
|---|---|
| The shrink surprises an operator mid-pick | The shrink is only to what physically exists, and only on PROCESSABLE (not started) orders |
| `ownShare` misattributes when two orders share an SU and the invariant is broken | `held` is capped by req, and `max(0,…)` makes a broken invariant yield 0 held (U-4). 0 shared SUs on DEV |
| ROMS `@InjectMocks` tests get a null `ReservationShareService` | Add `@Mock` in the 4 classes; the unit tests stub it |
| Same-row redirect double-counts | `held` is captured pre-reserve; IT-3 |

## 8. Testing plan
Each test names the mutant it kills.

**Unit (`ReplenishmentOrderMaintenanceServiceUnitTest`, `ReservationShareServiceUnitTest`)**
- **U-1** amount 18, reserved 1, requested 9, no others, shortage 40 → requested 18, reservation delta +17. Kills: the old add-back `amount−res+req` (it gives 26).
- **U-2** amount 18, reserved 18, requested 26 → requested 18, **no** `changeReservedAmount`. Kills: delta against requested (it gives −8).
- **U-3** under-reserved with `desired == requested` (amount 20, reserved 5, requested 9, shortage 9) → +4 is booked. Kills: the old early return.
- **U-4** `heldShare` with others > res → 0; with ownShare > req → req. Kills: the `max(0)` floor, and `min(req)` (holder-less surplus released).
- **U-5** `isSourceUsable` with capacity 0 (reserved == amount, all held by another order) → false, so redirect or cancel. Kills: the old helper, which says usable.
- **U-6** `cancelOrder` on an under-reserved SU (reserved 3, requested 9) → releases 3. Kills: release of requested.
- **U-7** `redirectSource` releases `held` from the current source. Kills: same as U-6.
- **U-8** `MobileReplenishService.ownShareOfReservation` delegates (a verify on the mock). The SBDEV-3605 suites (164 plus contract) pass unchanged.

**Integration (Testcontainers, commit semantics, `ReplenishmentOrderMaintenanceServiceIntegrationTest`)**
- **IT-1** reproduces the live sequence: create the order (req 9), admin `adjustReservedAmount` to 1, `recalculateForItem`. Asserts `requestedamount ≤ amount` and `reservedamount == requestedamount`, both read by id.
- **IT-2** the already-inflated order (18/18/26) converges to 18 in one recalc, and a second recalc writes no stockrecord row (watermark by `created`).
- **IT-3** a same-row redirect keeps `reserved ≤ amount` and `held == requested`.

**Regression:** the full `mvn clean verify` against a fresh `origin/develop` baseline, and PIT scoped to both classes.

**Manual test plan**
| Scenario | Env | Steps | Expected |
|---|---|---|---|
| Converge the live case | DEV wineco | After the deploy, wait one replenish cron (or the admin trigger) | REPL389503 requested 18; SU 30685299 reserved 18 |
| Population | DEV, then PRD | the appendix query, before and after | `would_shrink` → 0; `holderless_surplus` unchanged |
| Normal refill | DEV | an FLA below lowerbound on an unaffected item | order created and sized as before |

## 9. Completeness checklist
| # | Concern | Considered |
|---|---|---|
| 0 | DB verified | ✓ §1 (DEV). PRD is §5.1 |
| 1 | Callsites | ✓ §0: 11 rows, each fixed or excluded |
| 2 | Adjacent bugs | ✓ §0 #7–#9 → §10 P-1 |
| 3 | Backward compat | ✓ no API, schema or payload change; behaviour changes named in §3 |
| 4 | Concurrency | ✓ §6 #8: under the existing lock |
| 5 | Multi-tenant | ✓ no cross-tenant path |
| 6 | Error handling | ✓ unchanged `FacadeException` → WARN; Fix B makes the throw unreachable when the invariant holds |
| 7 | Observability | ✓ INFO on a capacity-bound shrink |
| 8 | Rollback | ✓ a plain revert. Reservations re-reserved or released stay as written, and each is attributable (order number) |
| 9 | Tests | ✓ §8 |
| 10 | v1↔v2 | no: v1 is reference-only |

## 10. Resolved decisions and proposals

**Resolved (Nam, 2026-10-01):**
- **D1** held share uses the SBDEV-3605 holder invariant, under the SU lock. Refined here to `min(req, ownShare)` so holder-less surplus is never claimed (93 DEV SUs).
- **D2** re-reserve then shrink: book against held, top up from free, cap at capacity.
- **D3** no data-fix script; recalc converges. PRD is measured before and after.

**Proposed (not filed):**
- **P-1 (T3)** the non-maintenance release sites §0 #7–#9 release `requested`. This merges into SBDEV-3605's P-S5S6 when that is filed. Blast radius: shared SUs only (0 on DEV). Cost: about ½ day using the Fix A service.
- **P-2 (T3)** `StockunitService.adjustReservedAmount`, the admin absolute set, can cut below what open orders hold. That is the precondition for this bug. Options are to warn or refuse below Σheld. Cost: small, but it is a UI and contract change.

## Appendix — DEV population query (2026-10-01)
```sql
WITH o AS (SELECT r.id, r.state, r.requestedamount req, s.amount, coalesce(s.reservedamount,0) res,
 (SELECT coalesce(sum(r2.requestedamount),0) FROM replenishorder r2 WHERE r2.stockunit_id=s.id AND r2.state<700 AND r2.id<>r.id) oth,
 (SELECT coalesce(sum(p.amount),0) FROM pickingorder_position p WHERE p.pickfromstockunit_id=s.id AND p.state<600) picks
 FROM replenishorder r JOIN stockunit s ON s.id=r.stockunit_id WHERE r.state<700),
 h AS (SELECT *, greatest(0, least(res, res-oth-picks)) own FROM o),
 c AS (SELECT *, least(req, own) held, least(req,own)+greatest(0,amount-res) cap FROM h)
SELECT state, count(*) orders, count(*) FILTER (WHERE req>cap) would_shrink, sum(req-cap) FILTER (WHERE req>cap) units_shrunk,
 count(*) FILTER (WHERE held<req AND req<=cap) topup_only, count(*) FILTER (WHERE own>req) holderless_surplus,
 count(*) FILTER (WHERE oth>0) shared_su FROM c GROUP BY state;
-- 300 | 565 | 53 | 393 | 2 | 93 | 0
```
