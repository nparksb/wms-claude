---
title: "Multi-UL pick releases only what no live holder explains, attributed in two rows; one ascending lock set; finished-order guard; attributable maintenance releases; deterministic SU-order banner"
ticket: "SBDEV-3605"
ticket_url: "https://app.clickup.com/t/868mbjatz"
type: "bugfix"
priority: ""
status: "pending approval"
tier: T3
repos: [wms2-api]
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-30"
updated: "2026-09-30"
revision: "r2 — architect SOUND-WITH-CHANGES and critic ITERATE (4 High) applied; D3′ and D4b′ (Nam, round 2)"
db_verified: true
db_verified_note: "DEV wineco only; PRD classifier not run. Re-checked 2026-09-30 07:51Z: 565 open orders (all state 300, per the critic), 0 SUs with two open orders, 0 open orders with NULL stockunit_id. The 565 equals the analysis count, which serves as the positive control. Architect: DEV states 300=565 / 700=170 / 800=388,356."
base_commit: "wms2-api daf64d41 (origin/develop, fetched 2026-09-30); wms2-web-ui 299cec1 and wms2-mobile-ui 108b2f5 read-only"
related:
  - "[[SBDEV-3561]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-2610]]"
  - "[[260709]]"
  - "[[260713]]"
tags:
  - plan
---

# SBDEV-3605 — Multi-UL pick releases another order's reservation

**Ticket:** [SBDEV-3605](https://app.clickup.com/t/868mbjatz) · **Tier:** T3. It is data integrity: reservations move between SUs, and a check-then-act on the reservation runs on unlocked reads inside the only live pick transaction. Escalation trigger #2 fired because the fix adds new repository methods.

**Evidence:**
- *A§Qn* = `SBDEV-3605-evidence/analysis.md`.
- *AR* = `r1-architect.md`; *CR* = `r1-critic.md`.
- Every snippet is from `git show origin/develop:<path>` at `daf64d41`.

## RALPLAN-DR summary

**Principles**
1. The release **frees everything no live holder explains**. It attributes the order's requested share to the order, and books the remainder as an explicit adjustment (D3′).
2. The credit and the release are one value, computed under the lock.
3. The order is locked first, then all SUs as **one ascending set**. Every lock is the row's first touch in the transaction (SBDEV-3244).
4. Fail closed. Contention rolls back and surfaces as 409, never as progress on stale data.
5. Minimal surface: three `exported = false` queries (two sums, one id projection), each justified in §4.

**Decision drivers:** (1) Order Y's reservation must survive order X's pick (IT-M1b). (2) X's own leak must not be left for an admin reconcile. (3) The change must stay small inside the SBDEV-260713 multi-UL transaction.

**Options**

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Requested-based:** release `min(requested, reserved)` | Trivial | The own-leak remainder is **stranded until an admin reconcile** (`countStrandedReservationById`; `IS_SB_ADMIN`, unscheduled). Meanwhile the SU is invisible to the generator, which requires `reservedamount = 0`. REPL049240 would strand 7, REPL049628 would strand 5 (A§Q3b) | Rejected |
| **Ledger-derived:** net Σ`reservedamountchange` for X's number on the SU | Exact when the ledger is clean | The ledger is corrupt. `releaseReservation` writes CANCELLED with a NULL number, and SU 988285734 nets 26,724 against 12 reserved (A§Q8) | Rejected |
| **Invariant-based (chosen):** `ownShare = max(0, min(res, res − Σreq(other open replen) − Σamount(open picks)))` under the lock, booked as FINISHED −min(req, ownShare) plus MANUAL_ADJUSTMENT −remainder | Keeps every explained holder, frees own leaks, uses only current state. Correct on the 430 "holds" SUs (A§Q2). Two rows keep the ledger truthful (AR synthesis) | Holder-less reservations are released, but visibly (D3′). Adds query surface | **Chosen** |

## 0. Affected sites

**How the sites were found:**
- `git grep -n 'changeReservedAmount(' origin/develop -- src/main`: 27 delta arguments, all read (A§Q5). Positive control: the `applyExplicitSourceToOrder` site is among the hits.
- Finder callers: `git grep -n 'findIdByStateLessThanAndStockunitId\|findByStateLessThanAndStockunitId' origin/develop -- src`. Positive control: both declarations are among the hits.

| # | Site | Construct | Disposition |
|---|---|---|---|
| S1 | `MobileReplenishService.applyExplicitSourceToOrder` | `oldStockOpt.get().getReservedamount().negate()` from a plain `stockunitRepository.findById` | **Fix B** |
| S2 | `MobileReplenishService.validateUnitLoadEntry` | credit `template.getRequestedamount().min(reserved)`; SU from `stockunitRepository.findByUnitloadId` | **Fix C** (D2), plus Fix A's lock set |
| S3 | `MobileReplenishService.fulfillMultipleUnitLoadsTx` | `replenishorderRepository.findById(request.getOrderId())`, no state check | **Fix A** |
| S4 | `ReplenishmentOrderMaintenanceService.releaseReservation` | `…CODE_REPLENISHMENT_CANCELLED, null, null)`; `cancelOrder(…, String activityCode)` ignores its code | **Fix D** (D4a) |
| S7 | `ReplenishorderService.existsForStockUnit` (readOnly; `MobileMoveUnitloadService` scan banner and `checkReservedStock`) | `findByStateLessThanAndStockunitId(...).orElse(null)`, which throws with two open orders | **Fix E** (D4b′): `findFirst…OrderByIdAsc` |
| S5 | `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit` | `.findIdByStateLessThanAndStockunitId(FINISHED, movedStock.getId()).orElse(null)` | **Out**, proposal **P-S5S6** (T3). Unchanged; still throws with two orders (fail-closed) |
| S6 | `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` | same probe | **Out**, P-S5S6 |
| S8 | SDR search `findByStateLessThanAndStockunitId` (`@RestResource(path = "findByStateLessThanAndStockunitId")`) | Optional over HTTP | **Kept** (HTTP contract). 0 HTTP callers in web-ui 299cec1 and mobile-ui 108b2f5 (controls: `replenishorder` in 3 web-ui files, `/replenish` in 3 mobile-ui files) and in oms-laravel-api HEAD. Blind spot: external callers. Proposal P-3 |
| X1 | `ReplenishmentReservationReconciliationService` | admin zeroing | Excluded: intended |
| X2 | `StockunitService.adjustReservedAmount` | admin absolute set | Excluded: deliberate |
| X3 | `updateRequestedAmount`, mobile `checkSource`/finish, `redirectSource`, cancel, generator, 12 picking sites | release the holder's own amount | Excluded: different root cause (A§Q10) |
| X4 | `getAvailableIncludingReservation`; clamped-delta ledger drift | over-grant; wrong recorded delta | D5, proposed |

## 1. Problem

**What happens.** On `/multi-unitloads`, the first scanned UL re-sources the template order X. `applyExplicitSourceToOrder` then releases the old SU's **entire** `reservedamount` under `CODE_REPLENISHMENT_FINISHED` and X's number. Order Y's reservation, or an open pick's reservation, on that SU is stripped silently; Y's later finish clamps at 0 via `zeroIfNegative`. SBDEV-3561's web redirect added a new trigger for this (3561 R8b). IT-M1b measured B = `0.0000` against an expected 3, with FINISHED −8.

**DB evidence (DEV WineCo):**
- 18 multi-UL releases on DEV. All 3 whole-amount releases since 2026-01-01 (REPL050660 −12, REPL049240 −12, REPL050443 −82) cleaned up the order's own leak. **No harm observed.**
- The ledger artefact: SU 988285734 nets 26,724 for the order's number against 12 reserved.
- The invariant, across 2,238 SUs:
  - 430 hold;
  - 1,753 leak (1,658 of them stranded; the repo's stranded SQL, run verbatim, agrees);
  - 55 are under, e.g. 985090431 (reserved 5, REPL049523 requesting 12).
- 0 SUs have two open orders, and 0 SUs have both a pick and a replen holder, so **harm is latent on DEV**. Blind spot: DEV only; the PRD MCP servers failed and the PRD classifier has not run.

## 2. Root cause

- **Bug 1: whole-amount release (S1).** The delta comes from an unlocked snapshot and has no notion of whose reservation it is. `changeReservedAmount` locks and refreshes, but applies the caller's delta unchanged.
- **Bug 2: credit/release mismatch (S2).**
  - The credit is `min(req, res)`, while the release is `res`.
  - The own-leak case (res 12, req 5, qty 12) is wrongly rejected.
  - The under case (res 2, Y req 3) credits 2 that belong to Y.
- **Bug 3: liveness plus a missing state guard (S3; AR M3).** Today's path is already **fail-closed**. A stale template read fails `@Version` at the Fix A.2 flush, which is a 409, so no corruption follows. Two problems remain:
  - A 700/800 order is processed as far as that flush, with no guard.
  - The transaction takes SU A (via `changeReservedAmount`) and only then X's row lock at the flush. The cron does order → SU, so this is a **live ABBA on develop**, which Fix A removes.
- **Bug 4 (D4a): NULL `ordernumber` (S4).** Every maintenance redirect and cancel release is anonymous in `stockrecord`. That is what made the ledger unusable.
- **Bug 5 (D4b′): the scan banner throws `IncorrectResultSizeDataAccessException` when two open orders share an SU (S7).** It falls to the mobile catch-all (`MobileEndpointExceptionHandler` `@ExceptionHandler(Exception.class)`). The multi-UL children and the cron (`getAvailableReplenishmentSources` requires only `su.amount > su.reservedamount`) can both create that state.

## 3. Architecture / key files

```
ReplenishController POST /v3/replenish/multi-unitloads
   Business/FacadeException → 200 {errors};  Optimistic/PessimisticLockingFailure → 409 (RestExceptionHandler @Order(0))
 └ fulfillMultipleUnitLoads (no tx) → self.fulfillMultipleUnitLoadsTx (@Transactional tenantTM)
     1 [A] template findByIdForUpdate → guard state ≥ FINISHED
     2     resolve per UL: unitload read, location check, SU id via id-only query   (no SU entity read)
     3 [A] lock {old SU} ∪ scanned SU ids, ascending, findByIdForUpdate (each a first touch)
     4 [B] ownShare = ownShareOfReservation(oldSu, templateId)                         (2 scalar sums)
     5     assignDestinationForMultiUnitLoads  (save #1 of template)
     6 [C] validate availability on locked entities; credit = ownShare on the same SU
     7 [B] applyExplicitSourceToOrder: FINISHED −attributed, MANUAL_ADJUSTMENT −remainder; save #2; reserve
     8     finish / children (unchanged; Fix A.2 flushes kept)
   post-commit, best-effort: refillFixedLocations(); recalculateOpenOrders(true)       (unchanged)
```

**Files:**
- `service/mobile/MobileReplenishService.java` (1503 lines; grep-only);
- `repo/jpa/ReplenishorderRepository.java`, `repo/jpa/StockunitRepository.java`, `repo/jpa/PickingorderPositionRepository.java`;
- `service/ReplenishmentOrderMaintenanceService.java`, `service/ReplenishorderService.java`.

## 4. Fix design

### Fix A — template lock, finished guard, one ascending SU lock set (Bug 3; CR H3, AR M1)

**Before:** `Optional<Replenishorder> templateOpt = replenishorderRepository.findById(request.getOrderId());`

**After (step 1):**
```java
Replenishorder template = replenishorderRepository.findByIdForUpdate(request.getOrderId())
        .orElseThrow(() -> new FacadeException("MsgCannotReadOrder"));
if (template.getState() == null || template.getState() >= WmsConstants.State.FINISHED) {
    throw new FacadeException("REPLENISH_ALREADY_FINISHED", new Object[]{});
}
```
- **Guard choice (CR M5, AR L1).** It rejects only ≥ FINISHED, with the existing localized key (`REPLENISH_ALREADY_FINISHED=The order is already finished`, the one the mobile service already uses in 3 places). That is exactly what finish accepts today, so nothing is narrowed. 3561's ≤ PROCESSABLE threshold belongs to a different operation (changing the source).
- **Null state** is corrupt data and is refused with the same key.
- **First touch.** This lock is the first touch: the transaction starts at the `self.` call, and `spring.jpa.open-in-view=false`.

**Steps 2–3.** Resolve before reading any SU entity, then lock everything in one ascending pass:
```java
// step 2, per dto (after resolveUnitloadId + duplicate check + unitload location check)
List<Long> suIds = stockunitRepository.findIdsByUnitloadIdAndItemdataIdOrderById(unitload.getId(), template.getItemdataId());
if (suIds.isEmpty()) throw new FacadeException("MsgSourceStockNotFound");
resolved.put(unitload.getId(), suIds.get(0));
// step 3
SortedSet<Long> lockIds = new TreeSet<>(resolved.values());
if (template.getStockunitId() != null) lockIds.add(template.getStockunitId());
Map<Long, Stockunit> locked = new HashMap<>();
for (Long id : lockIds) {
    stockunitRepository.findByIdForUpdate(id).ifPresent(su -> locked.put(id, su)); // missing old SU → no lock, absent
}
```

**New repository query.** `StockunitRepository.findIdsByUnitloadIdAndItemdataIdOrderById`:
- JPQL `SELECT s.id FROM Stockunit s WHERE s.unitloadId = :unitloadId AND s.itemdataId = :itemdataId ORDER BY s.id`, with `@RestResource(exported = false)`.
- It is needed because the existing `findByUnitloadIdAndItemdataId` returns entities. Using it would make the lock an upgrade, not a first touch.

**`findByUnitloadId` (the brief's question).** Hibernate would return the managed, locked instances from the L1 cache, because the identity map is not overwritten by the result set. It would still load the UL's *other* SUs unlocked and pick "first" in unspecified list order. So `validateUnitLoadEntry` takes `locked.get(resolved.get(ulId))` instead. That is a behaviour change: with two same-item SUs on one UL, the lowest id is chosen deterministically.

**Error order changes.** UL and stock errors now precede destination errors, a message-only change (R7). A scanned SU vanishing between steps 2 and 3 gives `MsgSourceStockNotFound`.

**Lock count and timeout.** The transaction takes 1 + |lockIds| ≤ n + 2 locks for n scanned ULs. `changeReservedAmount`'s own `findByIdForUpdate` then re-locks rows already held in PESSIMISTIC_WRITE, which is no upgrade and no wait.

### Fix B — own share, computed once, booked in two rows (Bug 1; D1, D3′)

**Step 4, the helper** (package-private so it can be tested directly):
```java
/** SBDEV-3605: the part of lockedOldSu's reservation no other live holder explains. Caller holds the row lock. */
BigDecimal ownShareOfReservation(Stockunit lockedOldSu, Long templateId) {
    BigDecimal reserved = lockedOldSu.getReservedamount() == null ? BigDecimal.ZERO : lockedOldSu.getReservedamount();
    BigDecimal others = replenishorderRepository.sumRequestedAmountOfOtherOpenOrdersOnStockunit(
            lockedOldSu.getId(), WmsConstants.State.FINISHED, templateId);
    BigDecimal picks = pickingorderPositionRepository.sumOpenAmountByPickfromstockunitId(
            lockedOldSu.getId(), WmsConstants.State.PICKED);
    return reserved.subtract(others).subtract(picks).min(reserved).max(BigDecimal.ZERO);
}
```

**New sums** (both JPQL, `COALESCE(…, 0)`, `@RestResource(exported = false)` per method):
- `ReplenishorderRepository.sumRequestedAmountOfOtherOpenOrdersOnStockunit`: `SUM(r.requestedamount) … WHERE r.stockunitId = :stockunitId AND r.state < :state AND r.id <> :excludedId`.
- `PickingorderPositionRepository.sumOpenAmountByPickfromstockunitId`: `SUM(p.amount) … WHERE p.pickfromstockunitId = :id AND p.state < :state`.
- **Why a scalar sum for the pick term (AR L4).** It mirrors SBDEV-2610's SQL `p.state < 600`. It loads no entities into the persistence context (up to 52 per SU on DEV), and it gives one mutation target instead of a Java filter loop.
- Both indexes exist (`replenishorder_stockunit_id_index`, `index_pickingorder_position_pickfromstockunit_id` in `V2.2.00__base_v2_schema.sql`).
- **No early flush.** Both sums run before step 5, so their AUTO flush finds nothing dirty. U-5 pins that ordering.
- **The signum guard is dropped** in the helper. The max(0) clamp is the only floor, which makes it killable (§8).

**Step 7, the release.** `applyExplicitSourceToOrder` receives `(oldSu, ownShare)`. The attribution is computed **before** `order.setRequestedamount(qty)`:
```java
if (oldSu != null) {
    BigDecimal req = order.getRequestedamount() == null ? BigDecimal.ZERO : order.getRequestedamount();
    BigDecimal attributed = ownShare.min(req);
    BigDecimal remainder = ownShare.subtract(attributed);
    if (attributed.signum() > 0) {
        stockunitBusinessService.changeReservedAmount(oldSu, attributed.negate(), true,
                WmsConstants.CODE_REPLENISHMENT_FINISHED, order.getNumber(), null);
    }
    if (remainder.signum() > 0) {
        stockunitBusinessService.changeReservedAmount(oldSu, remainder.negate(), true,
                WmsConstants.CODE_MANUAL_ADJUSTMENT, order.getNumber(), "SBDEV-3605 unexplained reservation released");
    }
}
```
- The second row mirrors the SBDEV-2610 reconcile, which writes `CODE_MANUAL_ADJUSTMENT, "SBDEV-2610", "SBDEV-2610 stranded reservation reconciliation"`.
- **Missing old SU:** it is not in `locked`, so no lock is held and nothing is released.
- **Under class** (ownShare = 0): no row is written.

### Fix C — credit == release (Bug 2; D2)

In step 6, the four-clause add-back becomes:
```java
if (oldSu != null && oldSu.getId().equals(matching.getId())) effectiveAvailable = effectiveAvailable.add(ownShare);
```
The credit equals the **total** released (attributed + remainder), so the two cannot diverge. The old rule guarded against over-crediting a reservation that would not be freed; the new release frees exactly what is credited.

### Fix D — attributable maintenance releases (Bug 4; D4a)

- `releaseReservation(Stockunit source, BigDecimal releaseAmount, String activityCode, String orderNumber)`.
- `cancelOrder` **threads its `activityCode` through** instead of the parameter being ignored. All 4 callers pass `CODE_REPLENISHMENT_CANCELLED` (`git grep -n 'cancelOrder('`), so behaviour is identical, and the parameter no longer lies.
- The `redirectSource` release passes `CODE_REPLENISHMENT_CANCELLED, order.getNumber()` explicitly.

### Fix E — deterministic banner lookup (Bug 5; D4b′)

- `ReplenishorderService.existsForStockUnit` calls a new derived `Optional<Replenishorder> findFirstByStateLessThanAndStockunitIdOrderByIdAsc(Integer state, Long stockunitId)` (`exported = false`). It is read-only and returns the lowest id.
- **The move itself stays fail-closed** with two orders: S5/S6 still throw, until P-S5S6.
- `findIdByStateLessThanAndStockunitId` stays, because S5/S6 use it. `ReplenishmentIdProjectionContractUnitTest` is therefore unchanged apart from the new names being added to its `exported = false` arrays (§5).

## 5. File change summary

| File | Change |
|---|---|
| `MobileReplenishService.java` | Fix A/B/C. New constructor parameter `PickingorderPositionRepository`; the unit test needs a `@Mock`, or `@InjectMocks` passes null (SBDEV-3091) |
| `ReplenishorderRepository.java` | + `sumRequestedAmountOfOtherOpenOrdersOnStockunit`, + `findFirstByStateLessThanAndStockunitIdOrderByIdAsc` |
| `StockunitRepository.java` | + `findIdsByUnitloadIdAndItemdataIdOrderById` |
| `PickingorderPositionRepository.java` | + `sumOpenAmountByPickfromstockunitId` (method-level `exported = false`, even though the class is `exported = false`) |
| `ReplenishmentOrderMaintenanceService.java` | Fix D |
| `ReplenishorderService.java` | Fix E |

**Pins and stubs that break, with counts:**
- **4 `isNull()` ordernumber pins** (`git grep -c 'CODE_REPLENISHMENT_CANCELLED), isNull()'` = 4): `ReplenishmentOrderMaintenanceServiceUnitTest:628, :736` and `…ReassignTest:206, :309`. They flip to `eq(<number>)`, which **is** U-A1's kill.
- **`MobileReplenishServiceUnitTest`**, 18 `fulfillMultipleUnitLoads*` calls:
  - **add** `findByIdForUpdate(orderId)` stubs **alongside** the `findById` stubs; never move them, because `readReplenishOrder` → `findById(mOrder.getId())` runs later in the same transaction (CR H2, AR H1);
  - add `findIdsByUnitloadIdAndItemdataIdOrderById`, stockunit `findByIdForUpdate`, and both sum stubs;
  - update the `stubUnitLoadAndStock` helper;
  - AC-5 `…whenSelfSourceAddBackStillBelowRequestedQty` is **reversed** (D2).
- `ReplenishorderServiceUnitTest:428, :443`: 2 stubs move to `findFirst…`. `ReassignTest:155` `never().findByStateLessThanAndStockunitId(any(), any())` stays valid.
- **`OptionalSafetyArchTest`** (a FreezingArchRule):
  - 5 frozen entries become obsolete: `applyExplicitSourceToOrder` ×4 and `fulfillMultipleUnitLoadsTx` ×1, all `Optional.get()`;
  - no new `.get()` is added;
  - the −5-line store diff is committed deliberately, and **not** via `freeze.refreeze=true` (the test's javadoc forbids a refreeze for line drift).
- `ReplenishmentIdProjectionContractUnitTest`: add the 4 new names to its per-method `exported = false` check.
- `NeverMatcherNullBlindnessArchTest`: every new `never()` uses `any()`/`nullable()` (and `anyBoolean()` for the primitive).

### 5.1 Prerequisites

- **#0 PRD classifier** (3561 §5.1 #0), read-only on 4 PRD tenants. It **does not gate** this plan. It re-ranks D5 and P-S5S6.
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3605`, branch `bugfix/SBDEV-3605-multi-ul-release-own-share` off a freshly fetched `origin/develop`.
- **No Flyway** (the indexes exist). JDK 21 for the build and PIT.

## 6. Implementation steps (atomic commits)

1. Red tests (§8), each confirmed failing for its stated reason. IT-M1b's `@Disabled` is removed.
2. The 4 repository methods, plus the contract-test names.
3. Fix E → U-B3, IT-B1.
4. Fix D, plus the 4 pin flips → U-A1.
5. Fix A (template lock, guard, resolve-then-lock, 18 stub additions) → U-4, U-5, U-7, U-9.
6. Fix B + C, plus the AC-5 reversal → IT-1..IT-8, U-1..U-3, U-6.
7. ArchUnit store diff; docs.
8. PIT and a full-suite baseline comparison.

## 7. Horizontal scalability and v2 constraints

| # | Concern | Assessment |
|---|---|---|
| 1 | JVM-local state | None added |
| 2 | Lock medium | PG row locks in `tenantTransactionManager`; they hold across replicas |
| 3 | Timeout | `SET LOCAL lock_timeout`, **per acquisition**: 3 s in main, 10 s in the IT profile. Worst case is (n + 2) locks × timeout. IT-7's hold must be **shorter** than 10 s (T2 must wait, not time out); an IT asserting a timeout would have to hold longer than 10 s (not added; U-9 pins the mapping) |
| 4 | Cycles | **No cycle against `redirectSource` or another multi-UL.** All of them take the order first, then an ascending SU set (3561 D7). **Residual:** the cron (order → current SU → target SU, not ascending) can cycle with any ascending SU taker. It is bounded by 40P01 or lock_timeout → 409, the same class as the one already accepted. **Removed:** develop's SU-then-order ABBA (Bug 3) |
| 5 | Others-sum timing | Read after the old-SU lock. A cron placing Y on the SU must take that lock in `changeReservedAmount` first |
| 6 | Post-commit refill/recalc | Outside the transaction (AC-6b rail); IT-6 |
| 7 | Caches | 0 `@Cacheable` on the touched classes (`git grep`; control: `ClientController` has 4) |
| 8 | Failure surface | Lock timeout, deadlock or a stale row → `PessimisticLockingFailureException` / `ObjectOptimisticLockingFailureException` → **409** (`RestExceptionHandler`, `HttpStatus.CONFLICT`, "Please retry") |
| 9 | Handheld on 409 | `submitULBatchToDestination` (`store/replenish.js`) handles only `srcRes?.errors`. A 409 makes axios throw, and the operator sees the generic "Failed to submit replenish". The retry is safe because the rollback is whole-transaction. Proposal P-UI |
| 10 | Migration | None |

| v2 constraint | Conforms by |
|---|---|
| First touch (SBDEV-3244) | Template and every SU are locked before any entity read; SUs are resolved by id-only query |
| `@Query` on an SDR interface | `exported = false` per method; contract test |
| Self-proxy transaction | Unchanged |
| OSIV | `spring.jpa.open-in-view=false` |
| REQUIRES_NEW under locks | None added |
| `@InjectMocks` | New `@Mock PickingorderPositionRepository` |
| `never()` null-blindness | `any()`/`nullable()` only |
| Repository ITs commit | Assert by id; fixture band 999x |

## 8. Testing

**Integration** (`ReplenishorderRedirectSourceIT`, `fulfillMultipleUnitLoadsTx` on the injected bean unless stated). Rows are asserted as an ordered sequence by `created, id`, for X's number, `reservedamountchange IS NOT NULL`.

| # | Scenario | Assert | Mutant that must turn it red |
|---|---|---|---|
| IT-1 | IT-M1b enabled: B res 8 (X 5, Y 3), scan A | B = 3; FINISHED −5 on B only | Whole-amount release (measured −8, B = 0) |
| IT-2 | Own leak, cross-SU: B res 12, X req 5 | B = 0; rows FINISHED −5, MANUAL_ADJUSTMENT −7 (comment set) | (a) requested-based: B stays 7; (b) **single row**: FINISHED −12 |
| IT-3 | Own leak, same SU: amount 12, res 12, req 5, qty 12 | Accepted; FINISHED −5, MANUAL −7, CREATED +12, FINISHED −12; final res 0 | (a) old credit rule → `MsgUnitLoadStockAlreadyReserved`; (b) single row |
| IT-4 | Open pick (state < 600, amount 2) on B; B res 7 | B = 2 | Drop the pick term |
| IT-5 | Under: B res 2; X req 5 and Y req 3 on B | B stays 2; 0 rows on B for X | Whole-amount or requested-based (both → B = 0) |
| IT-6 | Wrapper `fulfillMultipleUnitLoads`; FLA `lowerbound ≤` post-transfer amount; `Y.manuallyoverridepriority = true` | Only X-numbered rows from the transaction; Y keeps 3 after the post-commit recalc | Whole-amount release |
| IT-7 | R10: T1 = `TransactionTemplate { redirectSource(X, A→B) }` held on a latch (< 10 s). T2 = multi-UL scanning A | T2 waits on the **order** row (`awaitOrderLockWait`, `pg_stat_activity` filtered to replenishorder). After the release, T2 releases X's 5 from **B** and books A −5 | Template read reverted to `findById`: T2 blocks on **SU A** instead, so the order-lock filter never sees a wait (red, attributable). After the release its A.2 flush fails `@Version` → 409 |
| IT-8 | B has MANUAL_ADJUSTMENT +10 on top of X's +5; no other holder | Release 15: FINISHED −5, MANUAL −10, both under X's number; B = 0 | (a) single row; (b) remainder dropped: B stays 10 |
| IT-B1 | New `ReplenishorderStockunitFinderIT`: two open orders plus one 700 order on one SU | `findFirst…` = lower id; 700 excluded (by id) | Drop `OrderByIdAsc` (insert the higher id first) |

IT-M1 is unchanged and must stay green (X is B's only holder: FINISHED −5, no remainder). It is a pin.

**Unit** (`MobileReplenishServiceUnitTest`; BigDecimal compared via `argThat(v -> v.compareTo(x) == 0)`):

| # | Assert | Mutant |
|---|---|---|
| U-1 | res 8, others 3, picks 0 → FINISHED −5 | Drop `others` |
| U-2 | Direct call: `ownShareOfReservation(su{res 2}, id)` with others 3 → `compareTo(ZERO) == 0` | Drop `max(0)` (returns −1) |
| U-2b | Same SU: amount 10, res 2, Y req 3, qty 8 → accepted | Drop `max(0)`: credit −1, so available 7 < 8 → `MsgUnitLoadStockAlreadyReserved` |
| U-3 | Other order's stored requested −4, res 8 → release 8 | Drop `min(res)` (12) |
| U-4 | `InOrder`: `findByIdForUpdate(orderId)` before any `findById(orderId)` and before the first `save` | Revert to `findById` |
| U-5 | `InOrder`: order lock → `findIdsByUnitloadIdAndItemdataIdOrderById` → SU locks ascending (request lists SU ids 30, 20, old 25 → 20, 25, 30) → both sums → **save #1**, i.e. `assignDestinationForMultiUnitLoads`'s `save(template)`, the first save after the sums (`inOrder.verify` matches the first unverified call) → first `changeReservedAmount` → save #2 (`applyExplicitSourceToOrder`) | Unsorted set; sums moved after save #1 |
| U-6 | Reversed AC-5 (res 12, req 5, qty 12) accepted; FINISHED −5, MANUAL −7 | Old credit rule |
| U-7 | Template 700 / 800 / null → `REPLENISH_ALREADY_FINISHED`; `verify(stockunitBusinessService, never()).changeReservedAmount(any(), any(), anyBoolean(), any(), any(), any())`; no `save` | Guard removed |
| U-8 | Missing old SU (lock returns empty) → no release | Unguarded `locked.get` |
| U-9 | Controller MockMvc, `standaloneSetup(ReplenishController).setControllerAdvice(RestExceptionHandler, …)` (pattern: `StockUnitControllerUnitTest`). Service throws `PessimisticLockingFailureException` → **409** | Advice removed / handler changed |
| U-A1 | The 4 flipped pins: releases carry `eq(order number)` | Pass `null` back |
| U-B3 | `existsForStockUnit` uses `findFirst…OrderByIdAsc` | Revert to the Optional finder |

**Commands:**
- **One IT on JDK 21:** `JAVA_HOME=$(/usr/libexec/java_home -v 21) mvn -Dit.test=ReplenishorderRedirectSourceIT -Dtest=NoSuchTest -Dsurefire.failIfNoSpecifiedTests=false verify`. Use a positive selector only. Run `pgrep -f 'surefire|failsafe'` first, because peer Maven runs share the reusable postgres.
- **Baseline:** a detached origin/develop worktree, run adjacent in time. Rerun the known flakies first.
- **PIT:** the 3561 §8.4 pom recipe with `-DtargetClasses=net.aim_ai.wms.service.mobile.MobileReplenishService -DtargetTests=net.aim_ai.wms.unit.service.mobile.MobileReplenishServiceUnitTest`. Survivors in Fix A/B/C are killed or justified in the PR.

**Manual (DEV WineCo, handheld):**

| Case | Setup | Expect |
|---|---|---|
| Same-SU pick | Order on its own source | FINISHED −req (+ MANUAL −leak if any), CREATED +qty |
| Cross-SU pick | Scan a different UL | Old SU released by exactly X's share |
| Other holder (AR L5) | Place Y on X's old SU **through the cron candidate path**: `entity_lock` Y's source SU, run `recalculateOpenOrders`, and confirm `REPLENISHMENT_SWITCHED +` on the SU under Y's number. Or place it as a multi-UL child. **Not** via web redirect, which 3561 F3 refuses for a reserved target | Y's reservation intact after X's pick |
| Finished order | Resubmit a 700 order | `{errors}` "The order is already finished"; nothing written |

No verify script: this is T3 opt-in, and every assertion here is stronger as JUnit.

## 9. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Holder-less reservations are released by a pick (D3′) | Visible as a separate MANUAL_ADJUSTMENT row with the SBDEV-3605 comment; IT-8 |
| R2 | AC-5 reversal | Intended (D2); U-6 and IT-3 |
| R3 | Cron ABBA residual | 40P01 / lock_timeout → 409; retry-safe |
| R4 | Stale or contended lock → **409** with a generic handheld toast | Whole-transaction rollback; P-UI |
| R5 | Two open orders on one SU: the move is still refused (S5/S6) | Fail-closed, no data harm; P-S5S6 |
| R6 | Same-item multi-SU UL now picks the lowest id | Deterministic, where today's order is unspecified; named in the PR |
| R7 | Error precedence: UL errors now before destination errors | Message-only |
| R8 | PRD may hold real harm | #0 classifier; the fix is correct either way |

## 10. Decisions, proposals, ADR

- **D1 (Nam 2026-09-30):** invariant-based `ownShare` under the lock. The sums are `exported = false`. The pick term is a scalar SUM (§4, AR L4).
- **D2:** credit == total release. Reverses 260709 AC-5 and the "Do NOT 'correct'" rule, with the reason recorded in both.
- **D3′ (Nam, round 2; replaces D3):** two rows. FINISHED −min(X.req, ownShare) and MANUAL_ADJUSTMENT −remainder, both under X's number, the second with the comment "SBDEV-3605 unexplained reservation released". The credit is still the total.
- **D4a:** the release carries the order number; `activityCode` is threaded through.
- **D4b′ (Nam, round 2; replaces D4b):** only S7 is in scope. S5/S6 become P-S5S6.
- **D6 (planner; CR M5 / AR L1):** the guard rejects ≥ FINISHED with `REPLENISH_ALREADY_FINISHED`, matching finish's acceptance.

**Proposals (not filed; ranked):**
1. **D5a — `getAvailableIncludingReservation` over-grant** (`amount − reserved + currentRequest`).
   - **Evidence:** 55 "under" SUs, net −445; REPL050060 was raised to 13 on a 12-unit SU.
   - **Blast radius:** orders exceed stock; pick shortfalls. It is the population Fix B's clamp meets.
   - **Cost:** about ½ day, T2 (subtract other holders using the §4 sums).
   - **Do this first.**
2. **P-S5S6 (T3) — move path with two open orders on one SU.**
   - **Evidence:** 0 cases on DEV; the state is creatable by the cron and by multi-UL children. Today the move fails closed via `IncorrectResultSizeDataAccessException`.
   - **Fix direction:** replace the Optional probe with `List<Long> …OrderById`, in **two phases**: lock every order id ascending, check STARTED on all of them, and only then write. A per-order loop would hold `movedStock` plus order 1 and then ask for order 2, while a multi-UL or cron on order 2 holds order 2 and asks for `movedStock` (CR H4, AR M2).
   - **Residual:** the SU → order inversion against order → SU takers exists today for one order too. It is bounded by 40P01.
   - **Concurrency IT:** T1 = a move of the UL, held on a latch while it holds order 1. T2 = a multi-UL on order 2, whose source is the moved SU. Assert a bounded outcome (one waits, or one 409s), no negative reservation, and each order's reservation consistent.
   - **Blast radius:** every UL move carrying a replen-bound SU.
   - **Cost:** about 1 day, including 25 test references (Reassign 9, SourceSync 11 + 3, contract 2).
3. **D5b — `changeReservedAmount` records the requested delta, not the clamped change.** Ledger drift only; 1 line plus a test (T1), but every clamping caller's rows change.
4. **P-UI (T1, mobile-ui) — `submitULBatchToDestination` shows the 409 ProblemDetail "Please retry" message** instead of "Failed to submit replenish".
5. **P-3 (T1) — un-export the SDR `findByStateLessThanAndStockunitId` search** (0 HTTP callers, §0 S8), following the SBDEV-3486 pattern.

**ADR**
- **Decision:** the multi-UL pick releases `ownShareOfReservation` (the invariant remainder), booked as an attributed FINISHED row plus an explicit MANUAL_ADJUSTMENT remainder. It runs under order-first, one-ascending-SU-set locks taken as first touches, and feeds the same total to the self-source credit.
- **Drivers:** protect other holders; free own leaks without waiting for the admin reconcile; a truthful ledger; minimal change to the 260713 transaction.
- **Alternatives:**
  - requested-based: strands until reconcile;
  - ledger-derived: corrupt instrument;
  - single-row release: misattributes;
  - old-SU-then-ascending locks (r1): a cycle against redirect (CR H3).
- **Why chosen:** correct on every measured class (holds, own leak, under, manual). No cycle among the order-first takers. Only current state is read.
- **Consequences:**
  - manual reservations are released, visibly;
  - AC-5 is reversed;
  - 4 new `exported = false` queries;
  - the template is locked for the whole pick transaction;
  - the same-item multi-SU choice becomes deterministic;
  - 5 ArchUnit store entries are retired.
- **Follow-ups:** D5a, P-S5S6, D5b, P-UI, P-3, #0 classifier.

## Acceptance criteria

| AC | Statement | Test |
|---|---|---|
| AC1 | Another order's reservation on the old SU survives | IT-1, U-1 |
| AC2 | The own leak is released, attributed in two rows | IT-2, IT-8, U-6 |
| AC3 | Same-SU credit equals the total release | IT-3, U-2b, U-6 |
| AC4 | Open-pick reservations survive | IT-4 |
| AC5 | Under class: nothing released, no row | IT-5, U-2, U-3 |
| AC6 | Post-commit recalc leaves other orders intact | IT-6 |
| AC7 | Concurrent redirect is serialised on the order row | IT-7, U-4 |
| AC8 | A finished or cancelled template is refused before any write | U-7 |
| AC9 | Lock order: template → ascending SU set, before any SU read and before the sums; sums before save #1 | U-5 |
| AC10 | Contention surfaces as 409 | U-9 |
| AC11 | Maintenance releases carry the order number and code | U-A1 |
| AC12 | Banner is deterministic with two open orders | U-B3, IT-B1 |
| AC13 | Full suite equals baseline; PIT survivors resolved; ArchUnit store diff is −5 only | §8, §5 |

## Docs to update

- `3-Resources/design/wms2-replenishment-design.md` §7:
  - the transaction is on `fulfillMultipleUnitLoadsTx`;
  - steps become: lock and guard; resolve; lock set; own share; two-row release.
- `3-Resources/workflows/wms2-multi-unitload-replenish.md`: line 110 (credit rule; "Do NOT 'correct'" replaced by the D2 reason); lines 54 and 100; a changelog row.
- `3-Resources/design/wms2-stockunit-design.md` (around line 389): the holder invariant and D3′'s MANUAL_ADJUSTMENT row.
- `3-Resources/architecture/wms2-transaction-osiv-boundary-map.md`: a multi-UL entry with the lock order and the 409 surface.
- `wms2-function-to-docs-map.md` §9: `MobileReplenishService` row.

## Layer-2 completeness checklist

| # | Item | ✓ | Ref |
|---|---|---|---|
| 0 | DB verified | ✓ | §1: DEV re-query with control; PRD #0 not run (stated) |
| 1 | Call sites | ✓ | §0: two greps with positive controls; UI/OMS HTTP sweep with controls; `cancelOrder` callers (4) |
| 2 | Adjacent bugs | ✓ | D4a, D4b′ in scope; D5a, P-S5S6, D5b, P-UI, P-3 proposed |
| 3 | Backward compat | ✓ | SDR search kept; 200 `{errors}` shape kept; AC-5 reversal intended; R6, R7 |
| 4 | Concurrency | ✓ | Fix A lock set; §7 #3–5; IT-7; R3 |
| 5 | Multi-tenant | ✓ | Row-level, inside the tenant transaction |
| 6 | Error handling | ✓ | Guard key; missing SUs; clamps; 409 (U-9) |
| 7 | Observability | ✓ | D4a attribution; D3′ MANUAL_ADJUSTMENT row with comment; #0 classifier |
| 8 | Rollback / migration | ✓ | No Flyway; single-repo revert |
| 9 | Test coverage | ✓ | §8: each test paired with a mutant; broken pins enumerated in §5 |
| 10 | v1↔v2 | no | v1 is reference-only |
