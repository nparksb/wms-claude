---
title: "Multi-UL pick releases only what no live holder explains, attributed in two rows; one ascending order+source-SU lock set; finished-order guard; attributable maintenance releases"
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
revision: "r3.1 — critic r3 APPROVE (0 High), 2 Lows applied; r3 — r2 architect SOUND-WITH-CHANGES (0 High) and critic ITERATE (1 High) applied; S7 deferred into P-S5S6 (D4b″); r2: D3′ two-row release, D4b′ split"
db_verified: true
db_verified_note: "DEV wineco only; PRD classifier not run. 2026-09-30 07:51Z: 565 open orders (all state 300), 0 SUs with two open orders, 0 open orders with NULL stockunit_id. The 565 equals the analysis count and serves as the positive control. Architect: states 300=565 / 700=170 / 800=388,356; 0 negative or NULL requestedamount out of 389,091 rows."
base_commit: "wms2-api daf64d41 (origin/develop, fetched 2026-09-30); wms2-web-ui 299cec1 and wms2-mobile-ui 108b2f5 read-only"
related:
  - "[[SBDEV-3561]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-2610]]"
  - "[[SBDEV-3319]]"
  - "[[260709]]"
  - "[[260713]]"
tags:
  - plan
---

# SBDEV-3605 — Multi-UL pick releases another order's reservation

**Ticket:** [SBDEV-3605](https://app.clickup.com/t/868mbjatz)

**Tier:** T3. This is data integrity: reservations move between SUs, and a check-then-act on the reservation runs on unlocked reads inside the only live pick transaction. Escalation trigger #2 fired, because the fix needs new repository methods.

**Sources:**
- *A§Qn* is `SBDEV-3605-evidence/analysis.md`.
- *AR/CR* are the architect and critic reviews, round-suffixed (`r1`, `r2`).
- Every code snippet is from `git show origin/develop:<path>` at `daf64d41`.

## RALPLAN-DR summary

**Principles**
1. The release **frees everything no live holder explains**. It attributes the order's requested share to the order, and books the remainder as an explicit adjustment (D3′).
2. The credit and the release are one value, computed under the lock.
3. **Within the order and source-SU rows**, the order is locked first, then all SUs as one ascending set, each lock the row's first touch (SBDEV-3244). Finish-path locks are unchanged (§7 #4).
4. Fail closed. Contention rolls the transaction back and surfaces as 409.
5. Minimal surface: three `exported = false` queries, each justified in §4.

**Decision drivers**
1. Order Y's reservation must survive order X's pick (IT-M1b).
2. X's own leak must not wait for an admin reconcile.
3. The change must stay small inside the SBDEV-260713 multi-UL transaction.

**Options**

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Requested-based:** release `min(requested, reserved)` | Trivial | The own-leak remainder is **stranded until an admin reconcile** (`countStrandedReservationById`; `IS_SB_ADMIN`, unscheduled), and the generator cannot see that SU because it requires `reservedamount = 0`. On REPL049240 it would strand 7, on REPL049628 5 (A§Q3b) | Rejected |
| **Ledger-derived:** net Σ`reservedamountchange` for X's number | Exact on a clean ledger | The ledger is corrupt: NULL-number CANCELLED rows; SU 988285734 nets 26,724 against 12 reserved (A§Q8) | Rejected |
| **Invariant-based (chosen):** `ownShare = max(0, min(res, res − Σreq(other open replen) − Σamount(open picks)))` under the lock, booked as FINISHED −min(req⁺, ownShare) plus MANUAL_ADJUSTMENT −remainder | Keeps explained holders, frees own leaks, reads only current state, is correct on the 430 "holds" SUs (A§Q2), and the two rows keep the ledger truthful | Holder-less reservations are released, but visibly (D3′). Adds query surface | **Chosen** |

## 0. Affected sites

**How the sites were enumerated:**
- `git grep -n 'changeReservedAmount(' origin/develop -- src/main`: 27 delta arguments, all read (A§Q5). Positive control: the `applyExplicitSourceToOrder` site is among the hits.
- `git grep -n 'findIdByStateLessThanAndStockunitId\|findByStateLessThanAndStockunitId' origin/develop -- src`. Positive control: both declarations are among the hits.

| # | Site | Construct | Disposition |
|---|---|---|---|
| S1 | `MobileReplenishService.applyExplicitSourceToOrder` | `oldStockOpt.get().getReservedamount().negate()` from a plain `stockunitRepository.findById` | **Fix B** |
| S2 | `MobileReplenishService.validateUnitLoadEntry` | credit `template.getRequestedamount().min(reserved)`; SU from `stockunitRepository.findByUnitloadId` | **Fix C** (D2), plus Fix A's lock set |
| S3 | `MobileReplenishService.fulfillMultipleUnitLoadsTx` | `replenishorderRepository.findById(request.getOrderId())`, no state check | **Fix A** |
| S4 | `ReplenishmentOrderMaintenanceService.releaseReservation` | `…CODE_REPLENISHMENT_CANCELLED, null, null)`; `cancelOrder(…, String activityCode)` ignores its code | **Fix D** (D4a) |
| S5 | `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit` | `.findIdByStateLessThanAndStockunitId(FINISHED, movedStock.getId()).orElse(null)` | **Out → P-S5S6** (T3) |
| S6 | `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` | same probe | **Out → P-S5S6** |
| S7 | `ReplenishorderService.existsForStockUnit` (`MobileMoveUnitloadService` scan banner and `checkReservedStock`) | `findByStateLessThanAndStockunitId(...).orElse(null)` | **Out → P-S5S6** (D4b″). With two open orders it throws at the **first UL scan**, before anything moves. That is the best failure point available today |
| S8 | SDR search `findByStateLessThanAndStockunitId` | Optional over HTTP | **Kept** (HTTP contract). 0 HTTP callers in web-ui 299cec1 and mobile-ui 108b2f5 (controls: `replenishorder` in 3 web-ui files; `/replenish` in 3 mobile-ui files) and in oms-laravel-api HEAD. Blind spot: external callers. P-3 |
| X1 | `ReplenishmentReservationReconciliationService` | admin zeroing | Excluded: intended |
| X2 | `StockunitService.adjustReservedAmount` | admin absolute set | Excluded: deliberate |
| X3 | `updateRequestedAmount`, mobile `checkSource`/finish, `redirectSource`, cancel, generator, 12 picking sites | release the holder's own amount | Excluded: a different root cause (A§Q10) |
| X4 | `getAvailableIncludingReservation`; clamped-delta ledger | over-grant; recorded delta is wrong | D5a / D5b, proposed |

## 1. Problem

**The defect.** On `/multi-unitloads`, the first scanned UL re-sources the template order X. `applyExplicitSourceToOrder` then releases the old SU's **entire** `reservedamount` under `CODE_REPLENISHMENT_FINISHED` and X's number.
- Any other order's or open pick's reservation on that SU is stripped silently.
- Y's later finish then clamps at 0 via `zeroIfNegative`.
- SBDEV-3561's web redirect added a trigger for this (3561 R8b).
- IT-M1b measured B = `0.0000` against an expected 3, with a FINISHED row of −8.

**DB evidence (DEV WineCo):**
- 18 multi-UL releases. The only 3 whole-amount releases since 2026-01-01 (REPL050660 −12, REPL049240 −12, REPL050443 −82) cleaned up the order's **own** leak.
- The ledger artefact: SU 988285734 nets 26,724 against 12 reserved.
- The invariant, across 2,238 SUs:
  - 430 hold;
  - 1,753 leak (1,658 are stranded; the repo's own stranded SQL, run verbatim, agrees);
  - 55 are under, e.g. 985090431 (reserved 5, REPL049523 requesting 12).
- 0 SUs carry two open orders, and 0 carry both pick and replen holders. **Harm is latent on DEV.**
- Blind spot: DEV only. The PRD MCP servers failed to connect, and the PRD classifier has not run.

## 2. Root cause

- **Bug 1: whole-amount release (S1).** The delta comes from an unlocked snapshot and does not know whose reservation it is. `changeReservedAmount` locks and refreshes, but applies the caller's delta as given.
- **Bug 2: credit/release mismatch (S2).** The credit is `min(req, res)` but the release is `res`.
  - The own leak (res 12, req 5, qty 12) is wrongly rejected.
  - The under case (res 2, Y 3) credits 2 that belong to Y.
- **Bug 3: liveness and no state guard (S3; AR-r1 M3).** Today the path already fails closed: a stale template fails `@Version` at the Fix A.2 flush, which is a 409. What remains:
  - A 700/800 order is processed as far as that flush.
  - The transaction takes SU A (via `changeReservedAmount`) before X's row lock at the flush, while the cron locks order → SU. That is a **live ABBA on develop**, and Fix A removes it.
- **Bug 4 (D4a): NULL `ordernumber` (S4).** Maintenance redirect and cancel releases are anonymous in `stockrecord`, which is what made the ledger unusable.
- **Deferred (P-S5S6): the Optional-by-SU finders (S5–S7)** throw `IncorrectResultSizeDataAccessException` when two open orders share an SU.

## 3. Architecture / key files

```
ReplenishController POST /v3/replenish/multi-unitloads
   Business/FacadeException → 200 {errors};  Optimistic/PessimisticLockingFailure → 409 (RestExceptionHandler @Order(0))
 └ fulfillMultipleUnitLoads (no tx) → self.fulfillMultipleUnitLoadsTx (@Transactional tenantTM)
     1 [A] template findByIdForUpdate → refuse state ≥ FINISHED / null
     2     per UL: resolveUnitloadId, duplicate check, unitload location check, SU id via id-only query  (no SU entity read)
     3 [A] lock {old SU} ∪ scanned SU ids ascending, findByIdForUpdate (each a first touch)
     4 [B] ownShare = ownShareOfReservation(oldSu, templateId)          (two scalar sums)
     5     assignDestinationForMultiUnitLoads                           (save #1 of the template)
     6 [C] availability on the locked entities; credit = ownShare on the same SU
     7 [B] applyExplicitSourceToOrder: FINISHED −attributed, MANUAL_ADJUSTMENT −remainder; save #2; reserve
     8     finish / children, unchanged (transferStockToUnitLoad locks; Fix A.2 flushes)
   post-commit, best-effort: refillFixedLocations(); recalculateOpenOrders(true)   (unchanged)
```

**Files:**
- `service/mobile/MobileReplenishService.java` (1503 lines; grep-only)
- `repo/jpa/{ReplenishorderRepository, StockunitRepository, PickingorderPositionRepository}.java`
- `service/ReplenishmentOrderMaintenanceService.java`
- `service/WmsConstants.java` (`MessageKey`)
- `resources/messages.properties`

## 4. Fix design

### Fix A — template lock, finished guard, one ascending SU lock set (Bug 3)

Before: `Optional<Replenishorder> templateOpt = replenishorderRepository.findById(request.getOrderId());`

After (step 1):
```java
Replenishorder template = replenishorderRepository.findByIdForUpdate(request.getOrderId())
        .orElseThrow(() -> new FacadeException("MsgCannotReadOrder"));
if (template.getState() == null || template.getState() >= WmsConstants.State.FINISHED) {
    throw new FacadeException(WmsConstants.MessageKey.REPLENISH_ALREADY_FINISHED, new Object[]{});
}
```

- **Threshold (D6).** Only state ≥ FINISHED is rejected, which is exactly what finish accepts today, so nothing is narrowed. A null state is corrupt data and gets the same key.
- **First touch.** The transaction starts at the `self.` call, and `spring.jpa.open-in-view=false`, so this lock is the row's first touch.

**Message key (CR-r2 N5).** `REPLENISH_ALREADY_FINISHED` exists only in `messages_en_US.properties` (`REPLENISH_ALREADY_FINISHED=The order is already finished`). `FacadeException` resolves against `Locale.getDefault()`, so the gap already exists on develop for the three existing uses.
- Fix: add the constant `WmsConstants.MessageKey.REPLENISH_ALREADY_FINISHED = "REPLENISH_ALREADY_FINISHED"`, and add the same line to base `messages.properties`.
- Pin: `MessageKeyConstantBundleContractTest` (SBDEV-3319) derives its population by reflection over `MessageKey`, so the new constant is pinned in both bundles automatically.
- Mutant: delete the base line → that test goes red.

**Steps 2–3.** Resolve everything, then lock everything once, in ascending order:
```java
// step 2, per dto, after resolveUnitloadId + duplicate check + unitload location check
List<Long> suIds = stockunitRepository.findIdsByUnitloadIdAndItemdataIdOrderById(unitload.getId(), template.getItemdataId());
if (suIds.isEmpty()) throw new FacadeException("MsgSourceStockNotFound");
resolved.put(unitload.getId(), suIds.get(0));
// step 3
SortedSet<Long> lockIds = new TreeSet<>(resolved.values());
if (template.getStockunitId() != null) lockIds.add(template.getStockunitId());
Map<Long, Stockunit> locked = new HashMap<>();
for (Long id : lockIds) {
    stockunitRepository.findByIdForUpdate(id).ifPresent(su -> locked.put(id, su)); // missing row → no lock, absent
}
// in step 6, per instruction: Stockunit matching = locked.get(resolved.get(ulId));
// matching == null (vanished between 2 and 3) → throw new FacadeException("MsgSourceStockNotFound")
```

- **New query.** `StockunitRepository.findIdsByUnitloadIdAndItemdataIdOrderById`:
  - JPQL `SELECT s.id FROM Stockunit s WHERE s.unitloadId = :unitloadId AND s.itemdataId = :itemdataId ORDER BY s.id`;
  - `@RestResource(exported = false)`.
- **Why not an existing finder.** `findByUnitloadIdAndItemdataId` returns entities, so a later lock would be an upgrade, not a first touch. `findByUnitloadId` would return the locked instances from the L1 cache. It would also load the UL's other SUs unlocked, and pick "first" in unspecified order, so step 6 uses `locked` instead.
- **Behaviour change (R6).** When one UL holds two SUs of the same item, the lowest id is now chosen deterministically.
- **Remaining upgrades.** `Unitload` rows are read in step 2 and later locked by finish, which is a pre-existing upgrade (409 if stale; AR-r2).
- **Error order (R7).** UL and stock errors now come before destination errors. The messages are unchanged.

### Fix B — own share, computed once, booked in two rows (Bug 1; D1, D3′)

**Step 4 helper** (package-private, so it can be tested directly):
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

**New sums.** Both are JPQL wrapped in `COALESCE(…, 0)`, each with method-level `@RestResource(exported = false)`:
- `ReplenishorderRepository.sumRequestedAmountOfOtherOpenOrdersOnStockunit`: `SUM(r.requestedamount) … WHERE r.stockunitId = :stockunitId AND r.state < :state AND r.id <> :excludedId`.
- `PickingorderPositionRepository.sumOpenAmountByPickfromstockunitId`: `SUM(p.amount) … WHERE p.pickfromstockunitId = :id AND p.state < :state`.
  - It is a scalar sum, not an entity list, because it mirrors SBDEV-2610's SQL `p.state < 600`, loads no entities (up to 52 per SU on DEV), and gives one mutation target.

**Supporting facts:**
- Both columns are indexed in `V2.2.00__base_v2_schema.sql` (`replenishorder_stockunit_id_index`, `index_pickingorder_position_pickfromstockunit_id`).
- The sums run before step 5, so their AUTO flush finds nothing dirty. U-5 pins this.

**Step 7, the release.** `applyExplicitSourceToOrder` receives `(oldSu, ownShare)`. The attribution is computed **before** `order.setRequestedamount(qty)`:
```java
if (oldSu != null) {
    BigDecimal req = (order.getRequestedamount() == null ? BigDecimal.ZERO : order.getRequestedamount()).max(BigDecimal.ZERO);
    BigDecimal attributed = ownShare.min(req);
    BigDecimal remainder = ownShare.subtract(attributed);           // attributed + remainder == ownShare, always
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

- **The requested-amount floor (AR-r2 N1, CR-r2 N2).** Without it, a negative `req` makes the remainder exceed `ownShare`, so the release would exceed the credit, and `zeroIfNegative` would strip other holders. A NULL, 0 or negative `req` books the **whole** share as one MANUAL_ADJUSTMENT row.
- **Precedent.** The MANUAL_ADJUSTMENT row mirrors SBDEV-2610's reconcile (`CODE_MANUAL_ADJUSTMENT, "SBDEV-2610", "SBDEV-2610 stranded reservation reconciliation"`).
- **Missing old SU:** it is not in `locked`, so no lock is held and nothing is released.
- **Under class** (`ownShare = 0`): no row is written.
- **What kills the `max(0)` mutant (CR-r2 N4).** Only U-2 and U-2b. At the release site, the `signum() > 0` guards mask it, because a negative share writes nothing either way.
- **Same-SU double call.** Two `changeReservedAmount` calls on the same locked SU re-lock without an upgrade, and the auto-flush runs before the second call's read, so no delta is lost (AR-r2).

### Fix C — credit == release (Bug 2; D2)

In step 6, the four-clause add-back becomes:
```java
if (oldSu != null && oldSu.getId().equals(matching.getId())) effectiveAvailable = effectiveAvailable.add(ownShare);
```

The credit is the **total** release (attributed + remainder), and the floor keeps that identity for every `req`.

The old `min(req, res)` rule guarded against over-crediting a reservation that would not be freed. The new release frees exactly what is credited, so the two cannot diverge.

### Fix D — attributable maintenance releases (Bug 4; D4a)

- `releaseReservation(Stockunit source, BigDecimal releaseAmount, String activityCode, String orderNumber)`.
- `cancelOrder` threads its `activityCode` through. All 4 callers pass `CODE_REPLENISHMENT_CANCELLED` (`git grep -n 'cancelOrder('`), so behaviour is identical and the parameter no longer lies.
- `redirectSource` passes `CODE_REPLENISHMENT_CANCELLED, order.getNumber()`.

## 5. File change summary

| File | Change |
|---|---|
| `MobileReplenishService.java` | Fix A/B/C. New constructor parameter `PickingorderPositionRepository`; the test needs a `@Mock`, or `@InjectMocks` passes null (SBDEV-3091) |
| `ReplenishorderRepository.java` | + `sumRequestedAmountOfOtherOpenOrdersOnStockunit` |
| `StockunitRepository.java` | + `findIdsByUnitloadIdAndItemdataIdOrderById` |
| `PickingorderPositionRepository.java` | + `sumOpenAmountByPickfromstockunitId` (method-level `exported = false`, although the class is also `exported = false`) |
| `ReplenishmentOrderMaintenanceService.java` | Fix D |
| `WmsConstants.java`, `messages.properties` | `MessageKey.REPLENISH_ALREADY_FINISHED`, and the base-bundle line |

**Pins and stubs that break, with counts:**
- **4 `isNull()` order-number pins.** `git grep -c 'CODE_REPLENISHMENT_CANCELLED), isNull()'` = 4:
  - `ReplenishmentOrderMaintenanceServiceUnitTest:628, :736`;
  - `…ReassignTest:206, :309`.
  - Each flips to `eq(<number>)`. That flip **is** U-A1's kill.
- **`MobileReplenishServiceUnitTest`** extends `BaseServiceUnitTest` → `BaseUnitTest`, which is `@ExtendWith(MockitoExtension.class)` with no `@MockitoSettings`, so **STRICT_STUBS** applies. An unused stub is an `UnnecessaryStubbingException`.
  - **Order stubs.** The 18 `fulfillMultipleUnitLoads*` calls **add** `findByIdForUpdate(orderId)` stubs alongside the `findById` ones. The existing stubs are never moved, because `readReplenishOrder` → `findById(mOrder.getId())` runs later in the same transaction.
  - **The 13 `findByUnitloadId` references**, split by path:

    | Group | References | Enclosing method | Change |
    |---|---|---|---|
    | Multi-UL path (3 sites, 12 effective uses) | :647 | `fulfillMultiple_recordsScannedUlLabel_whenScannedDiffersFromOrderSource` | Replace with `findIdsByUnitloadIdAndItemdataIdOrderById` + stockunit `findByIdForUpdate` + both sum stubs, or strict stubs fail |
    | | :3945 | helper `stubUnitLoadAndStock`, used ×10 by `PartitionAvailabilityGuard` | same |
    | | :4580 | `multiUnitLoads_acceptsAllowedNonFlowbinDestination_withoutCreatingFla` | same |
    | Unchanged paths (10 sites) | :1470, :1561, :1625, :1662, :1688, :1724, :1769 | switch/checkSource tests | none |
    | | :2944 | `switchSource_thenFinish_proceeds` | none |
    | | :4275 | `stubReachAreaCheck` | none |
    | | :4723 (`lenient`) | `finish_doesNotMergeIntoExistingUnitLoadOnNonFlowbinDestination` | none |

  - **AC-5** `…whenSelfSourceAddBackStillBelowRequestedQty` is **reversed** (D2).
- **`OptionalSafetyArchTest`** (a FreezingArchRule).
  - 5 frozen `Optional.get()` entries become obsolete: `applyExplicitSourceToOrder` ×4 and `fulfillMultipleUnitLoadsTx` ×1. No new `.get()` is added.
  - Commit the −5-line store diff deliberately. Do **not** set `freeze.refreeze=true`, which its javadoc forbids for line drift.
- **`ReplenishmentIdProjectionContractUnitTest`:** add the 3 new names to its per-method `exported = false` check.
- **`NeverMatcherNullBlindnessArchTest`:** every new `never()` uses `any()`/`nullable()`, and `anyBoolean()` for the primitive.

### 5.1 Prerequisites

- **#0 PRD classifier** (3561 §5.1 #0), read-only, on the 4 PRD tenants. It **does not gate** this ticket; its result re-ranks D5a and P-S5S6.
- **Worktree** `.claude/worktrees/wms2-api/SBDEV-3605`, on branch `bugfix/SBDEV-3605-multi-ul-release-own-share`, cut from a freshly fetched `origin/develop`.
- **No Flyway** is needed; the indexes exist.
- **JDK 21** for the build and PIT.

## 6. Implementation steps (atomic commits)

1. **Red tests (§8).** Confirm each fails for its stated reason, and remove IT-M1b's `@Disabled`.
2. **Repository methods.** Add the 3 methods and their contract-test names.
3. **Fix D.** Flip the 4 pins → U-A1 green.
4. **Fix A.** Template lock, guard, message key, resolve-then-lock, the stub additions and replacements → U-4, U-5, U-7, U-8, U-8b, U-9 green.
5. **Fix B + C, plus the AC-5 reversal** → IT-1..IT-8, U-1..U-3, U-6, U-10 green.
6. **Housekeeping.** ArchUnit store diff; docs.
7. **Verification.** PIT, then the full suite against the baseline.

## 7. Horizontal scalability and v2 constraints

| # | Concern | Assessment |
|---|---|---|
| 1 | JVM-local state | None added |
| 2 | Lock medium | PG row locks inside `tenantTransactionManager`, so they hold across replicas |
| 3 | Timeout | `SET LOCAL lock_timeout` applies per acquisition: 3 s in main, 10 s in the IT profile. Worst case is (n + 2) order and source-SU locks × timeout, plus the finish-path locks. IT-7's hold must be **shorter** than 10 s. An IT asserting a timeout would have to hold longer than 10 s; it is not added, and U-9 pins the mapping instead |
| 4 | Cycles | **Within the order and source-SU rows**, there is no cycle against `redirectSource` or another multi-UL, because all of them take the order first and then an ascending SU set (3561 D7). See the detail below |
| 5 | Others-sum timing | Read after the old-SU lock. A cron placing Y must take that lock in `changeReservedAmount` first |
| 6 | Post-commit | Refill and recalc stay outside the transaction (AC-6b rail); IT-6 |
| 7 | Caches | 0 `@Cacheable` on the touched classes (`git grep`; control: `ClientController` has 4) |
| 8 | Failure surface | Lock timeout, deadlock or a stale row → `PessimisticLockingFailureException` / `ObjectOptimisticLockingFailureException` → **409** (`RestExceptionHandler` `@Order(0)`, `HttpStatus.CONFLICT`) |
| 9 | Handheld on 409 | `submitULBatchToDestination` (`store/replenish.js`) reads only `srcRes?.errors`. A 409 makes axios throw, and the operator gets "Failed to submit replenish". The retry is safe because the rollback covers the whole transaction. P-UI |
| 10 | Migration | None |

**§7 #4 in detail:**
- **Unchanged, outside that set:**
  - finish's `transferStockToUnitLoad` locks the unitload, location and destination SU late, in path order (`StockunitBusinessService` `unitloadRepository.findByIdForUpdate` / `locationRepository.findByIdForUpdate` / destination `stockunitRepository.findByIdForUpdate`);
  - the pickingorder lock is taken only for `BLOCK_REALIGN_CODES` (`PickLineActivityCodeClassifier`), and `CODE_REPLENISHMENT` is not in that set.
- **Residuals, bounded by 40P01 or lock_timeout → 409:**
  - the cron (order → current SU → target SU, not ascending);
  - another order scanning a UL at X's destination.
- **Removed:** develop's SU-then-order ABBA (Bug 3).

**v2 constraints:**

| Constraint | How the plan conforms |
|---|---|
| First touch (SBDEV-3244) | The template and every source SU are locked before any entity read; ids come from the id-only query |
| `@Query` on an SDR interface | `exported = false` per method; covered by the contract test |
| Self-proxy transaction, OSIV | Unchanged; `open-in-view=false` |
| REQUIRES_NEW under locks | None added |
| `@InjectMocks` | New `@Mock PickingorderPositionRepository` |
| STRICT_STUBS | The 3 multi-UL `findByUnitloadId` sites are replaced (§5) |
| `never()` null-blindness | `any()`/`nullable()` only |
| Repository ITs commit | Assert by id; the fixture band is 999x |

## 8. Testing

**Release-assertion rule (CR-r2 N1).** A test that asserts a release must assert **both** codes on the old SU: the ordered `(code, delta)` sequence captured before the first CREATED, or an explicit `never()` on the absent code. Asserting FINISHED alone would let a MANUAL_ADJUSTMENT mutant pass. ITs read rows ordered by `created, id` for X's number, with `reservedamountchange IS NOT NULL`.

**Integration** (`ReplenishorderRedirectSourceIT`, calling `fulfillMultipleUnitLoadsTx` on the injected bean unless noted):

| # | Scenario | Assert (both codes) | Mutant that must turn it red |
|---|---|---|---|
| IT-1 | IT-M1b enabled: B res 8 (X 5, Y 3); scan A | B = 3; on B: FINISHED −5, **0 MANUAL** | Whole-amount (measured −8, B = 0); drop `others` (MANUAL −3) |
| IT-2 | Own leak, cross-SU: B res 12, X req 5 | B = 0; FINISHED −5, then MANUAL −7 (comment set) | (a) requested-based: B = 7, no MANUAL; (b) **single row**: FINISHED −12 |
| IT-3 | Own leak, same SU: amount 12, res 12, req 5, qty 12 | Accepted; FINISHED −5, MANUAL −7, CREATED +12, FINISHED −12; res 0 | (a) old credit rule → `MsgUnitLoadStockAlreadyReserved`; (b) single row |
| IT-4 | Open pick (state < 600, amount 2) on B; B res 7 | B = 2; FINISHED −5, **0 MANUAL** | Drop the pick term (MANUAL −2) |
| IT-5 | Under: B res 2; X req 5 and Y req 3 on B | B = 2; **0 rows of either code** on B for X | Whole-amount or requested-based (B = 0) |
| IT-6 | Wrapper `fulfillMultipleUnitLoads`; FLA `lowerbound ≤` post-transfer amount; `Y.manuallyoverridepriority = true` | Y keeps 3 after the post-commit recalc; X's transaction rows on B: FINISHED −5, 0 MANUAL; only X-numbered rows | Whole-amount |
| IT-7 | R10: T1 = `TransactionTemplate { redirectSource(X, A→B) }` held on a latch (< 10 s); T2 = multi-UL scanning A | T2 waits on the **order** row (`awaitOrderLockWait`, `pg_stat_activity` filtered to replenishorder). After release: on B, FINISHED −5 and 0 MANUAL; on A, rows with an id above a watermark taken after T1 commits are exactly **CREATED +5 then FINISHED −5** (AR-r2 N4). T1's own X-numbered `REDIRECT_REPLENISHMENT_SOURCE` −5 on A sits below the watermark, so an unfiltered exact sequence would go red on correct code (CR-r3); A booked −5 | Template read reverted to `findById`: T2 blocks on **SU A**, so the order-lock filter never sees the wait (red, attributable). After release, the A.2 flush fails `@Version` → 409 |
| IT-8 | B has MANUAL_ADJUSTMENT +10 on top of X +5; no other holder | Release 15: FINISHED −5, then MANUAL −10, both under X's number; B = 0 | (a) single row; (b) remainder dropped (B = 10) |

IT-M1 is unchanged and must stay green: X is B's only holder, so FINISHED −5 and no MANUAL row. It is a pin.

**Unit** (`MobileReplenishServiceUnitTest`; BigDecimal matched by `argThat(v -> v.compareTo(x) == 0)`):

| # | Assert | Mutant |
|---|---|---|
| U-1 | res 8, others 3, picks 0, req 5 → FINISHED −5, and `verify(sbs, never()).changeReservedAmount(any(), any(), anyBoolean(), eq(WmsConstants.CODE_MANUAL_ADJUSTMENT), any(), any())` | Drop `others` (adds MANUAL −3) |
| U-2 | Direct: `ownShareOfReservation(su{res 2}, id)`, others 3 → `compareTo(ZERO) == 0` | Drop `max(0)` (−1) |
| U-2b | Same SU: amount 10, res 2, Y req 3, qty 8 → accepted; captured sequence on the SU starts with CREATED +8 (no FINISHED or MANUAL before it) | Drop `max(0)`: credit −1 → available 7 < 8 → `MsgUnitLoadStockAlreadyReserved` |
| U-3 | Another order's stored req −4, res 8, X req 5 → FINISHED −5, then MANUAL −3 (total 8) | Drop `min(res)`: MANUAL −7 (total 12) |
| U-4 | `InOrder`: `findByIdForUpdate(orderId)` before any `findById(orderId)` and before the first `save` | Revert to `findById` |
| U-5 | `InOrder`, in sequence: order lock → `findIdsByUnitloadIdAndItemdataIdOrderById` → SU locks ascending (request SU ids 30, 20; old 25 → locks 20, 25, 30) → both sums → **save #1** = `assignDestinationForMultiUnitLoads`'s `save(template)` (the first save after the sums; `inOrder.verify` matches the first unverified call) → first `changeReservedAmount` → save #2 (`applyExplicitSourceToOrder`) | Unsorted set; sums moved after save #1 |
| U-6 | Reversed AC-5 (res 12, req 5, qty 12) accepted; FINISHED −5, then MANUAL −7 | Old credit rule; single row |
| U-7 | Template 700 / 800 / null → `REPLENISH_ALREADY_FINISHED`; `verify(sbs, never()).changeReservedAmount(any(), any(), anyBoolean(), any(), any(), any())`; `verify(repo, never()).save(any())` | Guard removed |
| U-8 | Old SU missing (lock returns empty) → no release of either code | Unguarded `locked.get` |
| U-8b | Scanned SU id resolves, then `findByIdForUpdate` returns empty → `MsgSourceStockNotFound`; `never()` on `changeReservedAmount` (any/nullable) | Missing null check → NPE |
| U-9 | Controller MockMvc: `standaloneSetup(ReplenishController).setControllerAdvice(RestExceptionHandler, MobileEndpointExceptionHandler)`, **both registered** (pattern: `StockUnitControllerUnitTest`). Service throws `PessimisticLockingFailureException` → **409** (`@Order(0)` beats the mobile catch-all `@Order(LOWEST_PRECEDENCE)`) | Global handler removed → the mobile catch-all answers (not 409) |
| U-10 | req −4, res 5, no others → exactly one MANUAL −5 (total 5); `never()` on FINISHED | No floor: remainder 9 → MANUAL −9 (total 9) |
| U-A1 | The 4 flipped pins: maintenance releases carry `eq(order number)` | Pass `null` back |

**Commands:**
- **One IT on JDK 21:** `JAVA_HOME=$(/usr/libexec/java_home -v 21) mvn -Dit.test=ReplenishorderRedirectSourceIT -Dtest=NoSuchTest -Dsurefire.failIfNoSpecifiedTests=false verify`.
  - Use a positive selector only.
  - Run `pgrep -f 'surefire|failsafe'` first, because peer Maven runs share the reusable postgres.
- **Baseline:** a detached origin/develop worktree, adjacent in time; rerun the known flakies first.
- **PIT:** the 3561 §8.4 pom recipe with `-DtargetClasses=net.aim_ai.wms.service.mobile.MobileReplenishService -DtargetTests=net.aim_ai.wms.unit.service.mobile.MobileReplenishServiceUnitTest`. Every survivor in Fix A/B/C is killed or justified in the PR.

**Manual (DEV WineCo, handheld):**

| Case | Setup | Expect |
|---|---|---|
| Same-SU pick | Order on its own source | FINISHED −req (plus MANUAL −leak, if any), CREATED +qty |
| Cross-SU pick | Scan a different UL | Old SU released by exactly X's share (both codes checked) |
| Other holder | Place Y on X's old SU through the **cron candidate path**: `entity_lock` Y's source SU, run `recalculateOpenOrders`, confirm `REPLENISHMENT_SWITCHED +` under Y's number. A multi-UL child also works. **Not** a web redirect, which 3561 F3 refuses for a reserved target | Y's reservation intact |
| Finished order | Resubmit a 700 order | `{errors}` "The order is already finished". It now resolves on any default locale via the base bundle (no Dockerfile on develop pins LANG/LC_ALL, so the base bundle is the only guarantee; CR-r3). Nothing written |

**No verify script.** It is T3 opt-in, and every assertion here is stronger as JUnit.

## 9. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Holder-less reservations released by a pick (D3′) | A separate MANUAL_ADJUSTMENT row with the SBDEV-3605 comment; IT-8 |
| R2 | AC-5 reversal | Intended (D2); U-6, IT-3 |
| R3 | Residual cycles with the cron and at the destination | Bounded by 40P01 / lock_timeout → 409; retry-safe |
| R4 | 409 shows a generic handheld toast | Whole-transaction rollback; P-UI |
| R5 | Two open orders on one SU: the UL scan throws (S7), and so would the move's S5/S6 probe | Unchanged by this ticket, fail-closed **at the first scan, before any physical move**; P-S5S6 |
| R6 | A UL with two same-item SUs now picks the lowest id | Deterministic, where today's choice is unspecified; named in the PR |
| R7 | UL errors now come before destination errors | Message order only |
| R8 | PRD may hold real harm | #0 classifier; the fix is correct either way |

## 10. Decisions, proposals, ADR

**Decisions**
- **D1 (Nam 2026-09-30):** invariant-based `ownShare` under the lock; `exported = false` sums; the pick term is a scalar SUM.
- **D2:** credit == total release. This reverses 260709 AC-5 and the "Do NOT 'correct'" rule; record the reason in both.
- **D3′ (Nam, round 2):** two rows, both under X's number:
  - FINISHED −min(req⁺, ownShare);
  - MANUAL_ADJUSTMENT −remainder, with the comment "SBDEV-3605 unexplained reservation released".
  - The credit is the total. `req⁺ = max(0, req)` (r3).
- **D4a:** releases carry the order number; `activityCode` is threaded through.
- **D4b′ (Nam, round 2):** S5/S6 → P-S5S6.
- **D4b″ (orchestrator, round 3):** **S7 is deferred too.** On its own it would worsen the failure point: the scan would pass, and the S5/S6 probe would then throw into the mobile catch-all (500) at the destination step, often after the pallet has physically moved. Nam's D4b′ split is otherwise unchanged. Fix E is removed.
- **D6 (planner):** the guard rejects ≥ FINISHED with `REPLENISH_ALREADY_FINISHED`, which is now in the base bundle.

**Proposals (not filed; ranked):**
1. **D5a — `getAvailableIncludingReservation` over-grant** (`amount − reserved + currentRequest`).
   - Evidence: 55 "under" SUs, net −445. REPL050060 was raised to 13 on a 12-unit SU.
   - Blast radius: orders exceed stock, causing pick shortfalls; this is the population that meets Fix B's clamp.
   - Cost: about ½ day, T2 (subtract other holders via the §4 sums).
   - **Do this first.**
2. **P-S5S6 (T3) — two open orders on one SU, covering S5, S6 and S7 together.**
   - Evidence: 0 cases on DEV. The state is creatable by the cron (`getAvailableReplenishmentSources` requires only `amount > reserved`) and by multi-UL children. Today it fails closed at the first UL scan.
   - Fix direction:
     - S7 counts the open orders and, when there is more than one, throws a BusinessException naming both, **at the scan**;
     - S5/S6 switch to `List<Long> …OrderById` in **two phases**: lock every order id ascending, check STARTED on all of them, and only then write.
     - A per-order loop is not acceptable: it holds `movedStock` and order 1, then asks for order 2, while a multi-UL or cron on order 2 holds order 2 and asks for `movedStock` (CR-r1 H4, AR-r1 M2). That is ABBA.
     - The SU → order inversion against order → SU takers exists today for one order too; it is bounded by 40P01.
   - Concurrency IT: T1 = a move of the UL, latched while holding order 1; T2 = a multi-UL on order 2 whose source is the moved SU. Assert a bounded outcome (one waits, or one 409s), no negative reservation, and each order's reservation consistent.
   - Blast radius: every UL move that carries a replen-bound SU, plus the scan banner.
   - Cost: about 1 day, including roughly 27 test references (Reassign 9, SourceSync 11 + 3, contract 2, ReplenishorderService 2).
3. **D5b — `changeReservedAmount` records the requested delta, not the clamped change.** Ledger drift only. 1 line plus a test (T1), but every clamping caller's rows change.
4. **P-UI (T1, mobile-ui) — `submitULBatchToDestination` surfaces the 409 ProblemDetail "Please retry".**
5. **P-3 (T1) — un-export the SDR `findByStateLessThanAndStockunitId` search** (0 HTTP callers; §0 S8), following the SBDEV-3486 pattern.

**ADR**
- **Decision.** The multi-UL pick releases `ownShareOfReservation` (the invariant remainder), booked as an attributed FINISHED row (requested amount floored at 0) plus an explicit MANUAL_ADJUSTMENT remainder. It runs under an order-first, one-ascending-source-SU-set lock, taken as first touches, and feeds the same total to the self-source credit.
- **Drivers:**
  - protect other holders;
  - free own leaks without waiting for a reconcile;
  - keep the ledger truthful;
  - minimal change to the 260713 transaction.
- **Alternatives rejected:**
  - requested-based: strands until reconcile;
  - ledger-derived: corrupt instrument;
  - single-row release: misattributes;
  - r1's old-SU-then-ascending lock order: a cycle against redirect (CR-r1 H3);
  - S7 alone: worsens the failure point (D4b″).
- **Why chosen:**
  - correct on every measured class (holds, own leak, under, manual);
  - no cycle among the order-first source-SU takers;
  - reads current state only.
- **Consequences:**
  - manual reservations are released, visibly;
  - AC-5 is reversed;
  - 3 new `exported = false` queries and 1 message key;
  - the template is locked for the whole pick transaction;
  - the same-item multi-SU choice becomes deterministic;
  - 5 ArchUnit store entries are retired.
- **Follow-ups:** D5a, P-S5S6, D5b, P-UI, P-3, the #0 classifier.

## Acceptance criteria

| AC | Statement | Test |
|---|---|---|
| AC1 | Another order's reservation on the old SU survives, and no MANUAL row is written | IT-1, U-1 |
| AC2 | The own leak is released in full, as two attributed rows | IT-2, IT-8, U-6 |
| AC3 | The same-SU credit equals the total release | IT-3, U-2b, U-6 |
| AC4 | Open-pick reservations survive | IT-4 |
| AC5 | Under class: nothing released, no row | IT-5, U-2, U-3 |
| AC6 | The post-commit recalc leaves other orders intact | IT-6 |
| AC7 | A concurrent redirect is serialised on the order row | IT-7, U-4 |
| AC8 | A finished, cancelled or null-state template is refused before any write, with a key present in both bundles | U-7, `MessageKeyConstantBundleContractTest` |
| AC9 | Locks: template, then the ascending source-SU set, before any SU read; the sums run before save #1 | U-5 |
| AC10 | A vanished old or scanned SU releases nothing | U-8, U-8b |
| AC11 | Contention surfaces as 409, and the global handler wins | U-9 |
| AC12 | Release total = ownShare for every req, including negative and NULL | U-10, U-3 |
| AC13 | Maintenance releases carry the order number and code | U-A1 |
| AC14 | Full suite equals the baseline; PIT survivors resolved; ArchUnit store diff is −5 only | §8, §5 |

## Docs to update

- `3-Resources/design/wms2-replenishment-design.md` §7.
  - The transaction is on `fulfillMultipleUnitLoadsTx`.
  - The steps become: lock and guard; resolve; lock set; own share; two-row release.
- `3-Resources/workflows/wms2-multi-unitload-replenish.md`.
  - Line 110: the credit rule; replace "Do NOT 'correct'" with the D2 reason.
  - Lines 54 and 100.
  - A changelog row.
- `3-Resources/design/wms2-stockunit-design.md` (around line 389): the holder invariant, and D3′'s MANUAL_ADJUSTMENT row.
- `3-Resources/architecture/wms2-transaction-osiv-boundary-map.md`: a multi-UL entry with the lock order, the unchanged finish-path locks, and the 409 surface.
- `wms2-function-to-docs-map.md` §9: a `MobileReplenishService` row.

## Layer-2 completeness checklist

| # | Item | ✓ | Ref |
|---|---|---|---|
| 0 | DB verified | ✓ | §1: DEV re-query with control. PRD #0 not run (stated) |
| 1 | Call sites | ✓ | §0: two greps with positive controls; UI/OMS HTTP sweep with controls; `cancelOrder` callers (4); 13 `findByUnitloadId` test references |
| 2 | Adjacent bugs | ✓ | D4a in scope. D5a, P-S5S6 (S5–S7), D5b, P-UI, P-3 proposed |
| 3 | Backward compat | ✓ | SDR search kept; 200 `{errors}` shape kept; AC-5 reversal intended; R5–R7 |
| 4 | Concurrency | ✓ | Fix A lock set; §7 #3–5 (scoped to order and source-SU rows; finish-path locks named); IT-7; R3 |
| 5 | Multi-tenant | ✓ | Row-level, inside the tenant transaction |
| 6 | Error handling | ✓ | Guard key in both bundles; vanished SUs (U-8/8b); clamps and the requested-amount floor; 409 (U-9) |
| 7 | Observability | ✓ | D4a attribution; D3′ MANUAL row with comment; #0 classifier |
| 8 | Rollback / migration | ✓ | No Flyway; single-repo revert |
| 9 | Test coverage | ✓ | §8: both-codes rule, each test paired with a mutant; STRICT_STUBS impact enumerated in §5 |
| 10 | v1↔v2 | no | v1 is reference-only |
