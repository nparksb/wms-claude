---
title: "changeReservedAmount Caller Rebind — 2351004 Follow-Up"
ticket: ""
ticket_url: ""
type: bugfix
priority: critical
status: draft
project: [wms1]
version: v1
requester: production
created: 2026-04-27
updated: 2026-04-27
related:
  - "[[260422-changeReservedAmount-stale-object-state-fix]]"
tags:
  - plan
  - wms1
  - bugfix
  - replenishment
  - stockunit
  - hibernate
---

# changeReservedAmount Caller Rebind — 2351004 Follow-Up

**Project:** wms1 | **Version:** v1 | **Type:** bugfix
**Priority:** Critical (production replenishment broken)
**Status:** draft
**Date:** 2026-04-27
**Related commit:** `2351004` (`fix(picking): prevent StaleObjectStateException in changeReservedAmount (SBDEV-1710 follow-up)`, merged 2026-04-22, shipped in `v1.26.29`)
**Related plan:** [`260422-changeReservedAmount-stale-object-state-fix.md`](260422-changeReservedAmount-stale-object-state-fix.md) (the in-service fix this plan completes)

---

## 1. Problem Statement

### 1.1 User-visible symptoms

Every mobile replenish completion since `v1.26.29` throws:

```
amount=<X> requested is more than available=0
```

The error fires from `StockunitBusinessService.transferStockToUnitLoad:128` and surfaces in the mobile UI as a generic 500 on the replenish-confirm step. Operators cannot complete a replenish; the source unit-load remains reserved indefinitely.

### 1.2 Reproduction (single-source path)

1. Generate a replenish order whose source unit-load `amount == reservedamount` (the dominant case — replenish reserves the full amount it needs).
2. On the mobile UI, complete the replenish for that order.
3. Server-side the call routes through `MobileReplenishService.finishReplenishmentOrderInternal` → `changeReservedAmount(sourceStock, …)` → `transferStockToUnitLoad(sourceStock, …)`.
4. `transferStockToUnitLoad`'s amount-vs-available guard at `StockunitBusinessService:127` reads `sourceStock.getReservedamount()` from the **detached, stale** Java reference (still the pre-call value), computes `available = amount − reservedamount = 0`, and throws.

### 1.3 What changed and when

Commit `2351004` rewrote `StockunitBusinessService.changeReservedAmount` (lines 317–353) to:

- detach the caller's `staleStockUnit` from the L1 cache **before** acquiring the pessimistic lock, and
- load + mutate + return a brand-new managed instance via `findByIdForUpdate`.

The commit also rebound one caller (`PickingorderBusinessService.confirmPick`, lines 263–267) and explicitly deferred the other 24 sites to "a cleanup ticket". Two of those deferred sites — `MobileReplenishService.finishReplenishmentOrderInternal` lines 420 and 424 — read `sourceStock.getReservedamount()` (transitively via `transferStockToUnitLoad`'s guard) immediately after the `changeReservedAmount` call and trigger the production crash.

### 1.4 Why it didn't surface in tests pre-merge

`changeReservedAmount` returns `Stockunit`, but the language allows discarding the return value. There is no compile-time signal that the caller's reference is now stale. The unit tests added in `2351004` covered the in-service behavior (`StockunitBusinessServiceUnitTest#changeReservedAmount_doesNotCallRefreshAfterLock`) and the rebound caller (`PickingorderBusinessServiceUnitTest`), but no test stubbed `changeReservedAmount` to return a different instance and assert that downstream callers used the returned instance.

---

## 2. Root Cause Analysis

### Bug 1: Production crash — `MobileReplenishService.finishReplenishmentOrderInternal:420`/`:424`

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` lines 419–447

**Code (current):**

```java
if (sourceStock.getId().equals(replenishOrder.getStockunitId()) || replenishOrder.getStockunitId() == null) {
    stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,   // L420 — return value discarded
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
} else if (replenishOrder.getStockunitId() != null) {
    Stockunit stockUnit = stockunitRepository.findById(replenishOrder.getStockunitId()).get();
    stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,   // L424 — return value discarded
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
    stockunitBusinessService.changeReservedAmount(stockUnit, stockUnit.getReservedamount().negate(), true,       // L426 — return value discarded; OK (see §0)
            WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
}
// ... lines 430–445 (no read of sourceStock fields that changeReservedAmount mutates)
stockunitBusinessService.transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked,                    // L446 — guard reads stale getReservedamount()
        WmsConstants.CODE_REPLENISHMENT, replenishOrder.getNumber(), null, false, true);
```

**Why it fails:**

1. After L420 (or L424), `sourceStock` is detached from the L1 cache. Its in-memory `reservedamount` field still holds the **pre-call** value (e.g., 100), because Java's `entityManager.detach()` removes the entity from the persistence context but does not mutate its fields.
2. L446 invokes `transferStockToUnitLoad(sourceStock, …, amountPicked, …)`.
3. The guard at `StockunitBusinessService:127`:

   ```java
   if (sourceStockunit.getAmount().subtract(sourceStockunit.getReservedamount()).compareTo(amount) < 0) {
       throw new BusinessException("amount=" + amount + " requested is more than available=" + ...);
   }
   ```

   reads from the **stale** Java reference: `100 − 100 = 0`. Throws because `0 < amountPicked`.

**Why amountPicked drives the crash in the dominant case:** L443 sets `amountPicked = sourceStock.getAmount()` when `mobileOrder.getAmountPicked()` is null. So in the common "pick the whole reserved unit-load" flow, `amountPicked == sourceStock.getAmount()`, and any non-zero stale `reservedamount` causes `available < amountPicked`.

**Per-branch impact:**

| Branch | Trigger | Stale read at L446? | Crashes? |
|---|---|---|---|
| L420 (sourceStock matches order's stockunitId, or order has none) | `sourceStock.getReservedamount() > 0` (always true post-reservation) | yes | **always** |
| L424 (split — order's intended stockunitId differs from `sourceStock.getId()`) | `sourceStock.getReservedamount() > 0` (less common since the order targets a different stock) | yes | when sourceStock has any prior reservation |
| L426 (releases reservation on the redirected stockUnit) | `stockUnit` is not read after this call | n/a | safe — no rebind needed |

### Bug 2: Latent data corruption — `ReleaseOrderJobService.createPickingForOrder:473`

**File:** `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java` lines 471–479

**Code (current):**

```java
Stockunit stockUnit = stockunits.get(0);
PickingorderPosition pickingPosition = pickingorderPositionService.createPickingPosition(orderPosition.getAmount(), stockUnit, orderPosition, pickingOrder);
stockunitBusinessService.changeReservedAmount(stockUnit, orderPosition.getAmount(), false, WmsConstants.CODE_CREATE_PICK_POSITION, pickingPosition.getNumber(), null);   // L473 — return value discarded

orderPosition.setState(WmsConstants.State.ASSIGNED);
customerorderPositionRepository.save(orderPosition);

Object[] fixAssignmentID = itemDataFixAssignmentMap.get(orderPosition.getItemdataId());
fixAssignmentID[2] = stockUnit.getAvailableamount();   // L479 — reads detached entity
```

**Why it's wrong:**

1. After L473 `stockUnit` is detached.
2. L479 calls `stockUnit.getAvailableamount()`. `Stockunit.getAvailableamount()` is a `@Transient` getter (`Stockunit.java:114`) that returns `this.amount.subtract(this.reservedamount)` — pure in-memory field arithmetic, no DB hit.
3. The result is the **pre-reservation** available amount.
4. `fixAssignmentID[2]` stores that stale value. Subsequent iterations of the order-release job read it as `lastAvailable` (`ReleaseOrderJobService:151` and `:276`) and compare it to `position.getAmount()` to decide whether the next position can be served from the same fix-location stock. With a stale (over-stated) `lastAvailable`, the job can:
   - Mark a position satisfiable when it isn't (over-allocation pressure).
   - Eventually trip `CANNOT_RESERVE_MORE_THAN_AVAILABLE` inside `changeReservedAmount` itself, throwing later in the same release run.

**Why this is "latent" not "always crashes":** The error only manifests when the same order has multiple positions for the same itemdata, and the per-fix-location stock is tight. Single-position orders or orders with abundant stock will silently observe a stale-but-non-fatal value.

### Bug 3 (potential, deferred): `ReleaseOrderJobService.createPickingForOrder` second loop, lines 508–532

The second inner loop reads `stockUnit.getReservedamount()` at L510 at the start of each iteration. When the outer loop (over `pickFromOverstock` order positions) processes a second position with the **same itemdata**, `stockunitRepository.getStockUnitsByItemDataId(itemdataId)` may return the same Java instances that were detached in the previous outer iteration's `changeReservedAmount` calls.

JPA generally returns fresh managed instances after detach (the cache is cleared for that entity), so this is **likely benign** in practice. But the contract of `getStockUnitsByItemDataId` (a JPQL `@Query` mapped to managed entities) and the L1 cache behavior under detach + native query depend on Hibernate's session-state tracking and are not guaranteed across versions. **Out of scope for this plan; flagged for follow-up investigation.** See §10.

---

## 3. The Regression Chain

| Date | Commit | Change | Effect |
|---|---|---|---|
| 2026-04-22 | `2351004` | `changeReservedAmount` detaches caller's instance; loads fresh via `findByIdForUpdate`; returns the fresh instance. `confirmPick` rebound. | **Closed:** `StaleObjectStateException` in confirm-pick. **Opened:** all other 25 callers now hold detached/stale references. |
| 2026-04-22 | `2351004` (same) | Rejected option B in commit message: *"Change signature to take a Long id | touches ~20 caller sites; deferred to a cleanup ticket."* | Cleanup ticket was never opened; production replenish broke on first warehouse using `v1.26.29`. |

---

## 4. Architecture Overview

### 4.1 The `changeReservedAmount` contract after `2351004`

```
caller's Stockunit ref ──┐
                         ▼
            ┌─────────────────────────────┐
            │ entityManager.detach(ref)   │  ← caller's ref is now detached
            ├─────────────────────────────┤
            │ findByIdForUpdate(ref.id)   │  ← fresh managed instance, pessimistic lock
            ├─────────────────────────────┤
            │ mutate + save               │
            ├─────────────────────────────┤
            │ return fresh managed ref    │  ← only correct post-call view
            └─────────────────────────────┘
```

Caller's old Java reference is now **detached** and its `reservedamount` field reflects the **pre-call** state. Reads of `getReservedamount()`, `getAvailableamount()` (which is `amount − reservedamount`), or `getVersion()` on that reference return stale values.

### 4.2 Mutated vs untouched fields

`changeReservedAmount` mutates `reservedamount` only. Reads of fields it does not touch — `id`, `amount`, `itemdataId`, `unitloadId` — return correct values on the stale reference (provided no other concurrent writer changed them, which the pessimistic lock prevents within this transaction). This distinction is what makes most callsites SAFE.

### 4.3 Key files

| File | Lines | Role |
|---|---|---|
| `service/StockunitBusinessService.java` | 317–353 | The detach-and-rebind contract |
| `service/StockunitBusinessService.java` | 124–129 | `transferStockToUnitLoad` guard that reads `getReservedamount()` and throws |
| `service/mobile/MobileReplenishService.java` | 405–459 | `finishReplenishmentOrderInternal` — primary site of production crash |
| `service/job/ReleaseOrderJobService.java` | 465–533 | `createPickingForOrder` — site of latent over-allocation |
| `model/Stockunit.java` | 114 | `getAvailableamount()` is in-memory `amount − reservedamount` |

---

## 0. Affected sites (enumeration before drafting)

26 total invocations of `changeReservedAmount` (excluding the implementation in `StockunitBusinessService` itself). Verdicts independently re-validated against current source.

Verdict legend: **BUG** = throws or corrupts state today · **LATENT** = silent today, reads stale value with downstream consequences · **COSMETIC** = stale only reaches `LOG.debug` · **SAFE** = entity not read again, or only fields not mutated by the call (`id`, `amount`, `itemdataId`, `unitloadId`) read · **FIXED** = already rebound in `2351004`.

| # | File:Line | Verdict | Validated rationale (post-call code path) | In scope? |
|---|---|---|---|---|
| 1 | `CustomerorderService:238` | SAFE | Local `stockUnit` overwritten on next loop iteration; not read after L238. | no |
| 2 | `CustomerorderService:290` | SAFE | L291 mutates `pickingPosition`, not `pickFromStockUnit`. | no |
| 3 | `ReplenishmentOrderMaintenanceService:291` | SAFE | Method returns `true` at L296; `targetStock` not read again. | no |
| 4 | `ReplenishmentOrderMaintenanceService:348` | SAFE | `updateRequestedAmount` falls through to `order.setRequestedamount`/`save`; `source` not read. | no |
| 5 | `ReplenishmentOrderMaintenanceService:371` | SAFE | `releaseReservation` only reads `source.getId()` in the `catch` block (`getId()` not mutated). | no |
| 6 | `ReplenishorderService:153` | COSMETIC | L172 `LOG.debug("…oldStockUnit=" + source_old)` — stale `toString()` only. `source_old` is local to `redirectSource`; not returned to callers. | no (deferred) |
| 7 | `ReplenishorderService:170` | COSMETIC | Same L172 debug log includes `stockUnit`. **Caller-side audit (per critic M3):** `redirectSource(replenishOrder, stockUnit)` is invoked from `update():80` and `updateSourceStockUnit():101`. In both call sites the `stockUnit` parameter is **never read** after the call — both methods immediately `return replenishOrder` (L92, L104). No outer caller observes the detached `stockUnit` reference. COSMETIC verdict holds. | no (deferred) |
| 8 | `ReplenishorderService:191` | SAFE | L193 `replenishOrder.setState(CANCELED)`; `sourceStock` not read again. | no |
| 9 | `PickingorderBusinessService:267` | **FIXED** | Already rebinds; L272/L278 use rebound instance. | no |
| 10 | **`ReleaseOrderJobService:473`** | **LATENT** | L479 `fixAssignmentID[2] = stockUnit.getAvailableamount()` writes stale `amount − reservedamount` into shared map; consumed at L151/L276 by subsequent positions. | **yes — Fix B** |
| 11 | `ReleaseOrderJobService:494` | SAFE | `break` immediately at L499. | no |
| 12 | `ReleaseOrderJobService:518` | SAFE | Stale ref does not escape loop body — `missing` math uses local `BigDecimal available` (computed L510 *before* the call); next iteration loads `stockUnitCandidates[i+1]`, a different object. (Critic M1 corrected the rationale here — see §10.) | no |
| 13 | `ReleaseOrderJobService:526` | SAFE | `break` immediately at L530. | no |
| 14 | `CustomerorderBatchService:261` | SAFE | L263–266 mutate `poPosition`, not `stockUnit`. | no |
| 15 | `ReplenishGeneratorService:147` | SAFE | L149 `LOG.debug` references `itemData`, `amount`, `replenishOrder` — not `sourceStock`. Method returns. | no |
| 16 | `ReplenishGeneratorService:157` | SAFE | `reserveExplicitStockForOrder` returns immediately. | no |
| 17 | `MobileReplenishService:281` | SAFE | `stockUnit_old` not read after L281. (`stockUnit_new` is read but not yet passed to the call until L288.) | no |
| 18 | `MobileReplenishService:288` | SAFE | After-call reads on `stockUnit_new`: `getId()`, `getAmount()`. `setStockToReplenishMobileOrder` (L161) reads `getUnitloadId()`, `getAmount()`, `getId()` — none are mutated by `changeReservedAmount`. (Critic M2 verified — helper does not read `getReservedamount()`.) | no |
| 19 | **`MobileReplenishService:420`** | **BUG** | L446 `transferStockToUnitLoad(sourceStock, …)` invokes guard that reads stale `getReservedamount()`. **Production crash.** | **yes — Fix A** |
| 20 | **`MobileReplenishService:424`** | **BUG** | Same L446 path. Manifests when redirected order has any prior reservation on `sourceStock`. | **yes — Fix A** |
| 21 | `MobileReplenishService:426` | SAFE | Local `stockUnit` (the OLD reserved unit released by the redirect) not read after L426. | no |
| 22 | `MobileReplenishService:857` | SAFE | `applyExplicitSourceToOrder`: `oldStockOpt.get()` discarded; downstream code uses `sourceStock` (a different parameter) and re-fetches by ID. | no |
| 23 | `StockunitService:418` | COSMETIC | Already rebinds (L418 captures `newStockUnit`); only L426 `LOG.debug("…stockUnit=" + stockUnit + …)` reads the stale ref. | no (deferred) |
| 24 | `CustomerorderPositionService:133` | SAFE | L134–136 mutate `pickingPosition`, not `stockUnit`. | no |
| 25 | `PickingorderPositionService:128` | SAFE | `originalStock` not read again; L135 reads `replacement` (different ref). | no |
| 26 | `PickingorderPositionService:140` | SAFE | L143 `pickingOrderPosition.setPickfromstockunitId(replacement.getId())` — `getId()` not mutated. | no |

**Score:** 1 fixed · **2 production bugs (#19, #20)** · **1 latent (#10)** · 3 cosmetic · 19 safe.

Independent re-validation confirms every verdict and adjusts only the rationale wording for #10, #12, and #18 to match the actual code path (see §10 for the corrected language).

---

## 5. Fix Design

### Fix A — Rebind `sourceStock` in `MobileReplenishService.finishReplenishmentOrderInternal`

**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java`

```diff
         if (sourceStock.getId().equals(replenishOrder.getStockunitId()) || replenishOrder.getStockunitId() == null) {
-            stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,
+            sourceStock = stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,
                     WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
         } else if (replenishOrder.getStockunitId() != null) {
             Stockunit stockUnit = stockunitRepository.findById(replenishOrder.getStockunitId()).get();
-            stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,
+            sourceStock = stockunitBusinessService.changeReservedAmount(sourceStock, sourceStock.getReservedamount().negate(), true,
                     WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
             stockunitBusinessService.changeReservedAmount(stockUnit, stockUnit.getReservedamount().negate(), true,
                     WmsConstants.CODE_REPLENISHMENT_FINISHED, replenishOrder.getNumber(), null);
         }
```

**Why this and not alternatives:**

- *Re-fetch with `findById` after the call* — extra DB round-trip and risks reading a different transactional snapshot than the one `changeReservedAmount` just locked.
- *Inline the guard logic in `transferStockToUnitLoad`* — wrong place; the guard is correct, the caller is wrong.
- *Change `changeReservedAmount` signature to take a `Long id`* — proper end-state but touches all 26 callsites and a non-trivial number of tests; ship this targeted hotfix first (see §12).

**`stockUnit` (the OLD redirected unit) at L426 needs no rebind:** it is not read after L426. Confirmed from §0 row #21.

**Multi-unitloads endpoint coverage:** `POST /v3/mobile/replenishorders/.../multi-fulfill` routes through `finishReplenishmentOrderWithoutRefill` → `finishReplenishmentOrderInternal`. Fixing the latter fixes both endpoints. `applyExplicitSourceToOrder` (L848) is **not** on this path for the production crash and is independently SAFE (row #22).

### Fix B — Rebind `stockUnit` in `ReleaseOrderJobService.createPickingForOrder`

**File:** `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`

```diff
-            stockunitBusinessService.changeReservedAmount(stockUnit, orderPosition.getAmount(), false, WmsConstants.CODE_CREATE_PICK_POSITION, pickingPosition.getNumber(), null);
+            stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit, orderPosition.getAmount(), false, WmsConstants.CODE_CREATE_PICK_POSITION, pickingPosition.getNumber(), null);
```

The other three `changeReservedAmount` calls in this file (L494, L518, L526) are SAFE per §0 and stay as-is.

### Fix C — Add caller-rebind regression tests for `MobileReplenishService`

**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java` (extend existing test class — file exists, ~86KB).

**Public entrypoint to drive:** `finishReplenishmentOrder(ReplenishMobileOrderDto mobileOrder)` at `MobileReplenishService.java:370`. Internally calls `finishReplenishmentOrderInternal(mobileOrder, true)` (which is `private` and not directly testable). Driving from the public method exercises the complete real flow including `readReplenishOrder` lookup at L381.

**Required mocks (every method called by `finishReplenishmentOrderInternal` between L381 and L447):**

| Repository / service | Method | Returned value |
|---|---|---|
| `replenishorderRepository` | `findById(orderId)` | `Optional.of(replenishOrder)` (used by `readReplenishOrder` at L666) |
| `stockunitRepository` | `findById(sourceStockId)` | `Optional.of(preSource)` (L385) — **same instance** that's later matched with `eq(preSource)` |
| `locationRepository` | `findByName(destinationLocationName)` | `Optional.of(destinationLocation)` (L395) |
| `stockunitBusinessService` | `changeReservedAmount(eq(preSource), any(), eq(true), eq(CODE_REPLENISHMENT_FINISHED), eq(replenishOrder.getNumber()), nullable(String.class))` | `postSource` (distinct instance) |
| `fixLocationAssignmentRepository` | `findByAssignedlocationId(destinationLocationId)` | `Optional.of(fixLocationAssignment)` (L431) — set so the `null` branch at L436 is skipped |
| `unitloadRepository` | `findById(fixLocationAssignment.getAssignedunitloadId())` | `Optional.of(assignedUnitLoad)` (L445) |
| `stockunitBusinessService` | `transferStockToUnitLoad(transferCaptor.capture(), any(), any(), any(), any(), nullable(String.class), eq(false), eq(true))` | `postSource` |
| `replenishorderRepository` | `save(any())` | `replenishOrder` (L450) |

**Test methods (two — one per branch):**

```java
// L420 branch — sourceStock matches the order's stockunitId (or order has no stockunitId)
@Test
void finishReplenishmentOrder_rebindsSourceStockBeforeTransfer() throws Exception {
    long sourceStockId = 1001L;
    Long orderStockunitId = sourceStockId;            // L419 first branch fires

    Stockunit preSource = stockunitWith(sourceStockId, /*amount*/ bd(100), /*reservedamount*/ bd(100));
    Stockunit postSource = stockunitWith(sourceStockId, /*amount*/ bd(100), /*reservedamount*/ bd(0));  // distinct instance

    Replenishorder replenishOrder = replenishOrderWith(/*id*/ 9001L, /*stockunitId*/ orderStockunitId,
            /*number*/ "REP-001", /*requestedamount*/ bd(100), /*state*/ WmsConstants.State.PROCESSABLE,
            /*destinationId*/ 5001L);
    ReplenishMobileOrderDto mobileOrder = mobileOrderWith(/*id*/ 9001L, /*sourceStockId*/ sourceStockId,
            /*destinationLocationName*/ "BIN-A1", /*amountPicked*/ bd(100));

    Location destinationLocation = locationWith(5001L, "BIN-A1");
    FixLocationAssignment fixAssignment = fixAssignmentWith(/*assignedunitloadId*/ 7001L);
    Unitload assignedUnitLoad = unitloadWith(7001L);

    when(replenishorderRepository.findById(9001L)).thenReturn(Optional.of(replenishOrder));
    when(stockunitRepository.findById(sourceStockId)).thenReturn(Optional.of(preSource));
    when(locationRepository.findByName("BIN-A1")).thenReturn(Optional.of(destinationLocation));
    when(stockunitBusinessService.changeReservedAmount(
            eq(preSource), any(BigDecimal.class), eq(true),
            eq(WmsConstants.CODE_REPLENISHMENT_FINISHED), eq("REP-001"),
            nullable(String.class)))
        .thenReturn(postSource);
    when(fixLocationAssignmentRepository.findByAssignedlocationId(5001L))
        .thenReturn(Optional.of(fixAssignment));
    when(unitloadRepository.findById(7001L)).thenReturn(Optional.of(assignedUnitLoad));
    when(replenishorderRepository.save(any(Replenishorder.class))).thenReturn(replenishOrder);

    ArgumentCaptor<Stockunit> transferCaptor = ArgumentCaptor.forClass(Stockunit.class);
    when(stockunitBusinessService.transferStockToUnitLoad(
            transferCaptor.capture(), any(Unitload.class), any(BigDecimal.class),
            any(String.class), any(String.class), nullable(String.class),
            eq(false), eq(true)))
        .thenReturn(postSource);

    service.finishReplenishmentOrder(mobileOrder);

    // CRITICAL: must use isSameAs (reference equality) — Stockunit has no @Override equals()
    // Without the rebind, transferCaptor.getValue() == preSource (the stale, detached ref).
    // With the rebind, transferCaptor.getValue() == postSource (the fresh managed ref).
    assertThat(transferCaptor.getValue()).isSameAs(postSource);
}

// L424 split branch — order's stockunitId differs from the actual sourceStock the operator picked from
@Test
void finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer() throws Exception {
    long sourceStockId = 1001L;
    long orderStockunitId = 2002L;                    // L422 split branch fires

    Stockunit preSource = stockunitWith(sourceStockId, bd(100), bd(100));
    Stockunit postSource = stockunitWith(sourceStockId, bd(100), bd(0));        // distinct instance for sourceStock
    Stockunit redirectedOldStock = stockunitWith(orderStockunitId, bd(50), bd(50));   // the OLD reserved unit
    Stockunit postRedirected = stockunitWith(orderStockunitId, bd(50), bd(0));

    Replenishorder replenishOrder = replenishOrderWith(9002L, orderStockunitId,
            "REP-002", bd(100), WmsConstants.State.PROCESSABLE, 5001L);
    ReplenishMobileOrderDto mobileOrder = mobileOrderWith(9002L, sourceStockId, "BIN-A1", bd(100));

    Location destinationLocation = locationWith(5001L, "BIN-A1");
    FixLocationAssignment fixAssignment = fixAssignmentWith(7001L);
    Unitload assignedUnitLoad = unitloadWith(7001L);

    when(replenishorderRepository.findById(9002L)).thenReturn(Optional.of(replenishOrder));
    when(stockunitRepository.findById(sourceStockId)).thenReturn(Optional.of(preSource));
    when(stockunitRepository.findById(orderStockunitId)).thenReturn(Optional.of(redirectedOldStock));
    when(locationRepository.findByName("BIN-A1")).thenReturn(Optional.of(destinationLocation));
    // L424 — sourceStock release (the one we MUST rebind)
    when(stockunitBusinessService.changeReservedAmount(
            eq(preSource), any(BigDecimal.class), eq(true),
            eq(WmsConstants.CODE_REPLENISHMENT_FINISHED), eq("REP-002"), nullable(String.class)))
        .thenReturn(postSource);
    // L426 — redirected-old-stock release (no rebind needed — caller doesn't read it again)
    when(stockunitBusinessService.changeReservedAmount(
            eq(redirectedOldStock), any(BigDecimal.class), eq(true),
            eq(WmsConstants.CODE_REPLENISHMENT_FINISHED), eq("REP-002"), nullable(String.class)))
        .thenReturn(postRedirected);
    when(fixLocationAssignmentRepository.findByAssignedlocationId(5001L))
        .thenReturn(Optional.of(fixAssignment));
    when(unitloadRepository.findById(7001L)).thenReturn(Optional.of(assignedUnitLoad));
    when(replenishorderRepository.save(any(Replenishorder.class))).thenReturn(replenishOrder);

    ArgumentCaptor<Stockunit> transferCaptor = ArgumentCaptor.forClass(Stockunit.class);
    when(stockunitBusinessService.transferStockToUnitLoad(
            transferCaptor.capture(), any(Unitload.class), any(BigDecimal.class),
            any(String.class), any(String.class), nullable(String.class),
            eq(false), eq(true)))
        .thenReturn(postSource);

    service.finishReplenishmentOrder(mobileOrder);

    assertThat(transferCaptor.getValue()).isSameAs(postSource);
}
```

**Helper methods** (`stockunitWith`, `replenishOrderWith`, `mobileOrderWith`, `locationWith`, `fixAssignmentWith`, `unitloadWith`, `bd`) are simple builders setting `id`, `amount`, `reservedamount`, etc. via setters. Either reuse helpers already present in `MobileReplenishServiceUnitTest` or add minimal builders to a `@Nested` `Helpers` block.

**Why `nullable(String.class)` not `any()`** for the comment parameter: production calls pass `null` for `comment` at L420/L424/L446. Mockito's `any()` matcher resolves to `Object.class` and **does not match `null` values for typed primitive-wrapper / String parameters with strict stubbing**. `nullable(String.class)` matches both `null` and any non-null `String`.

**Why `isSameAs` not `isEqualTo`:** Per `v1/wms-api/CLAUDE.md`, only `Location` overrides `equals()` (and incorrectly). `Stockunit` falls through to `Object.equals()` (reference equality). `isEqualTo()` and `isSameAs()` are functionally identical here, but `isSameAs()` documents the intent — the test is asserting "the same managed instance returned by the mock was passed downstream", not "an equal-by-fields instance".

**Why `eq(preSource)` matcher works:** `eq()` calls `preSource.equals(actualArg)` — reference equality for Stockunit. The `when(stockunitRepository.findById(sourceStockId)).thenReturn(Optional.of(preSource))` stub guarantees the SAME `preSource` Java reference flows into `changeReservedAmount`, so `eq(preSource)` matches.

### Fix D — Add caller-rebind regression test for `ReleaseOrderJobService`

**File:** `src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java` (extend existing test class — file exists, ~72KB).

**Public entrypoint to drive:** `releaseOrder(long orderId, Map<Long, Object[]> itemDataFixAssignmentMap, Map<Long, Integer> itemDataAvailableAmountMap)` at `ReleaseOrderJobService.java:72`. The L473 site is reached via `createPickingForOrder` (called from `releaseOrder`) when an order has at least one position with a fixed-location assignment.

**Implementer guidance — crib from existing scaffold.** `releaseOrder` is a long method that touches ~10 repositories before reaching L473. Do **not** reinvent the mock setup from scratch — the test class already declares every required `@Mock` field (verified `ReleaseOrderJobServiceUnitTest.java:31-77`: `stockunitRepository`, `unitloadRepository`, `locationRepository`, `fixLocationAssignmentRepository`, `customerorderBatchRepository`, `pickingorderPositionService`, `stockunitBusinessService`, `customerorderPositionRepository`, `customerorderRepository`, `manageOrderService`, `itemdataRepository`, `pickingOrderService`, `clientRepository`, `sectionRepository`, `pickingorderRepository`, `basicService`). The mock list shown below is the **minimum NEW additions on top of any existing happy-path test scaffold in the same file**. Pattern-match on a sibling test that already exercises `releaseOrder` end-to-end, then add the rebind-specific assertions.

**Critical mock-name corrections (per round-2 critic MAJ-1):**

- `Pickingorder` is created by `pickingOrderService.create()` at `ReleaseOrderJobService:458`, NOT by `new Pickingorder()` or `pickingorderRepository.save(...)`. The mock must be `when(pickingOrderService.create()).thenReturn(pickingOrder)`.
- `pickingorderRepository.save(...)` is then called at `ReleaseOrderJobService:463` to persist the created order — also mock this with `thenReturn(pickingOrder)`.
- `customerorderRepository.findByIdForUpdate(orderId)` (NOT `findById`) is called at `ReleaseOrderJobService:80` for the order lookup. Mock accordingly.
- `Customerorder.getPickingdate()` MUST return a non-null `Date` (used in time-comparison at `:91`). Set via `customerOrderWith(...)` builder.

**Test method:**

```java
@Test
void createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead() throws Exception {
    long orderId = 8001L;
    long itemdataId = 6001L;
    long fixAssignmentId = 4001L;
    long fixedUnitloadId = 3001L;

    // Pre-call: amount=100, reservedamount=0 → getAvailableamount() = 100
    // Post-call: amount=100, reservedamount=40 → getAvailableamount() = 60
    Stockunit preStock = stockunitWith(/*id*/ 1001L, /*amount*/ bd(100), /*reservedamount*/ bd(0));
    Stockunit postStock = stockunitWith(/*id*/ 1001L, /*amount*/ bd(100), /*reservedamount*/ bd(40));

    BigDecimal POST_AVAILABLE = bd(60);   // = 100 - 40, the value that MUST land in fixAssignmentID[2]

    // Build the order with one fixed-assignment position
    Customerorder order = customerOrderWith(orderId, "ORD-001",
            /*orderbatchId*/ 2001L, /*state*/ WmsConstants.State.PROCESSABLE);
    CustomerorderPosition fixedPosition = customerOrderPositionWith(/*id*/ 7001L,
            /*orderId*/ orderId, /*itemdataId*/ itemdataId, /*amount*/ bd(40),
            /*number*/ "POS-001", /*state*/ WmsConstants.State.RAW);
    Itemdata itemdata = itemdataWith(itemdataId, "SKU-A");
    Customerorderbatch orderBatch = orderBatchWith(2001L, /*priority*/ 5,
            /*state*/ WmsConstants.State.PROCESSABLE);
    Pickingorder pickingOrder = pickingOrderWith(/*id*/ 9001L);
    PickingorderPosition pickingPosition = pickingPositionWith(/*number*/ "PICK-001");
    FixLocationAssignment fix = fixAssignmentWith(fixAssignmentId, fixedUnitloadId);
    Unitload fixedUnitload = unitloadWith(fixedUnitloadId);

    // The map the service mutates
    Map<Long, Object[]> itemDataFixAssignmentMap = new HashMap<>();
    Object[] fixAssignmentEntry = new Object[]{fixAssignmentId, /*lastStatus*/ null, /*lastAvailable*/ bd(100)};
    itemDataFixAssignmentMap.put(itemdataId, fixAssignmentEntry);
    Map<Long, Integer> itemDataAvailableAmountMap = new HashMap<>();

    when(customerorderRepository.findByIdForUpdate(orderId)).thenReturn(Optional.of(order));
    when(customerorderPositionRepository.findByOrderId(orderId)).thenReturn(Collections.singletonList(fixedPosition));
    when(itemdataRepository.findById(itemdataId)).thenReturn(Optional.of(itemdata));
    when(customerorderBatchRepository.findById(2001L)).thenReturn(Optional.of(orderBatch));
    when(pickingOrderService.create()).thenReturn(pickingOrder);                              // ← :458
    when(pickingorderRepository.save(any(Pickingorder.class))).thenReturn(pickingOrder);      // ← :463
    when(fixLocationAssignmentRepository.findById(fixAssignmentId)).thenReturn(Optional.of(fix));
    when(unitloadRepository.findById(fixedUnitloadId)).thenReturn(Optional.of(fixedUnitload));
    when(stockunitRepository.findByUnitloadId(fixedUnitloadId)).thenReturn(Collections.singletonList(preStock));
    when(pickingorderPositionService.createPickingPosition(any(BigDecimal.class), any(Stockunit.class),
            eq(fixedPosition), eq(pickingOrder)))
        .thenReturn(pickingPosition);
    when(stockunitBusinessService.changeReservedAmount(
            eq(preStock), any(BigDecimal.class), eq(false),
            eq(WmsConstants.CODE_CREATE_PICK_POSITION), eq("PICK-001"), nullable(String.class)))
        .thenReturn(postStock);
    // The first-pass position-state machinery may also call clientRepository / sectionRepository
    // depending on the existing scaffold — extend mocks as needed when mvn test reveals them.
    // The customerOrderWith(...) builder MUST set a non-null past pickingdate; otherwise L91
    // (order.getPickingdate().compareTo(new Date())) NPEs before reaching the rebind site.

    service.releaseOrder(orderId, itemDataFixAssignmentMap, itemDataAvailableAmountMap);

    // The map slot must now hold the POST-reservation available amount (60), not the PRE value (100).
    // Without the rebind, fixAssignmentEntry[2] would be preStock.getAvailableamount() = 100 (stale).
    // With the rebind, fixAssignmentEntry[2] is postStock.getAvailableamount() = 60.
    assertThat((BigDecimal) fixAssignmentEntry[2]).isEqualByComparingTo(POST_AVAILABLE);
}
```

**Why `isEqualByComparingTo` not `isSameAs` for the BigDecimal assertion:** `BigDecimal.equals` compares scale (`new BigDecimal("60") != new BigDecimal("60.00")`). `isEqualByComparingTo` calls `compareTo` which is value-based and scale-tolerant. The assertion target here is a value, not an entity-reference identity — different invariant from Fix C.

**Helper builders** mirror the Fix C set; reuse where possible from any existing helpers in the file.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `service/mobile/MobileReplenishService.java` | Modify | Rebind `sourceStock` to `changeReservedAmount` return value at L420 and L424 |
| `service/job/ReleaseOrderJobService.java` | Modify | Rebind `stockUnit` to `changeReservedAmount` return value at L473 |
| `test/unit/service/mobile/MobileReplenishServiceUnitTest.java` | Modify (file exists ~86KB) | Two new tests: `finishReplenishmentOrder_rebindsSourceStockBeforeTransfer` (L420 branch) and `finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer` (L424 split branch); both `isSameAs` |
| `test/unit/service/job/ReleaseOrderJobServiceUnitTest.java` | Modify (file exists ~72KB) | New test `createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead` (drives `releaseOrder(long, Map, Map)` public entry; `isEqualByComparingTo` on `fixAssignmentEntry[2]`) |
| `sbdocs/9-System/scripts/verify-260427-changeReservedAmount-caller-rebind-followup.sh` | Add | Verify script (see §11) |

---

## 7. Implementation Steps

Each step is an atomic commit. **Order intentionally puts the production hotfix first** so it can be cherry-picked and shipped if Fix B's tests reveal unexpected complexity.

1. **Fix A** (`MobileReplenishService:420` and `:424`) — **production hotfix; ship same-day**. Includes both Fix C test methods. Verify FA-* checks PASS, then commit.
2. **Fix B** (`ReleaseOrderJobService:473`) — latent bug; safe to soak one cycle. Includes Fix D test. Verify FB-* checks PASS, then commit.
3. **Run verify script** (`bash sbdocs/9-System/scripts/verify-260427-changeReservedAmount-caller-rebind-followup.sh`). Every active check must PASS (16 active + up to 4 mvn).
4. **Full suite green** (`mvn test`).
5. **Manual smoke** in staging — see §8.4 (scenarios 1–4 are required for ship; 5 covers the latent bug).
6. **Tag and ship** as `v1.26.30` (patch over `v1.26.29`). Fix A may ship as a separate `v1.26.29.1` hotfix tag if Fix B is delayed.

### 7.1 Prerequisites

| Item | Status |
|---|---|
| DB state | N/A — pure code change |
| Feature flags | N/A |
| System properties | N/A |
| Config / env | N/A |
| Deploy-order | Ship before any new replenish work in `v1.26.29` warehouses |
| Data migration | N/A |
| External systems | N/A |
| Access | Standard dev environment |
| Monitoring | Watch `BusinessException("amount=… requested is more than available=0")` log rate post-deploy — should drop to zero |

---

## 8. Testing Plan

### 8.1 Unit

- **`MobileReplenishServiceUnitTest#finishReplenishmentOrder_rebindsSourceStockBeforeTransfer`** (new — Fix C, L420 branch) — drives the public `finishReplenishmentOrder(mobileOrder)` entrypoint; asserts `transferStockToUnitLoad` receives the rebound instance via `isSameAs` (reference equality). Mockito 3.3.3 — no static mocking. Uses `nullable(String.class)` for the `comment` parameter matcher.
- **`MobileReplenishServiceUnitTest#finishReplenishmentOrder_splitBranch_rebindsSourceStockBeforeTransfer`** (new — Fix C, L424 split branch) — exercises the `replenishOrder.getStockunitId() != null && !equals(sourceStock.getId())` path with non-zero `sourceStock.reservedamount`. Same `isSameAs` assertion.
- **`ReleaseOrderJobServiceUnitTest#createPickingForOrder_rebindsStockUnitBeforeAvailableamountRead`** (new — Fix D) — drives the public `releaseOrder(orderId, fixMap, availableMap)` entrypoint; asserts `fixAssignmentEntry[2]` (the `BigDecimal` slot the service writes at L479) equals the post-call `getAvailableamount()` value via `isEqualByComparingTo` (scale-tolerant).
- **`StockunitBusinessServiceUnitTest#changeReservedAmount_doesNotCallRefreshAfterLock`** (existing, added by `2351004`) — must still pass unchanged.
- **`PickingorderBusinessServiceUnitTest`** rebind tests at L425/L516 — must still pass (no edits to that file).

### 8.2 Integration

- **`mvn verify`** with Testcontainers PostgreSQL — full suite green. No new integration tests required since the unit tests cover the rebind contract and integration tests already exercise the end-to-end replenish flow.

### 8.3 Regression guards

- The verify script (§11) catches any future regression where a developer reverts the rebind or adds a new caller without rebinding.

### 8.4 Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| 1 | Single-source replenish (`amount == reservedamount`) — primary crash repro | staging | Generate replenish from full UL → confirm on mobile | UL transfers to fix-location; `availableamount` on source = 0 | |
| 2 | Single-source replenish (partial pick, `amountPicked < amount`) | staging | Generate replenish, partial-pick on mobile | Partial transfer succeeds; remainder stays on source | |
| 3 | Split-branch (`replenishOrder.stockunitId` redirected) | staging | Trigger redirect via `redirectSource`, then complete on mobile | Both old reservation released on `stockUnit` AND new `sourceStock` reservation released; transfer succeeds | |
| 4 | Multi-unitloads endpoint | staging | `POST /v3/mobile/replenishorders/{id}/multi-fulfill` with two source ULs | Both transfers succeed | |
| 5 | Order-release job with multi-position order, same itemdata | staging | Drop a customer order with two positions sharing a SKU served from the same fix-location | Job runs without `CANNOT_RESERVE_MORE_THAN_AVAILABLE`; `lastAvailable` decrements correctly across positions | |
| 6 | Smoke: confirmPick (sanity that `2351004` regressed nothing) | staging | Confirm a pick on mobile | Pick completes without `StaleObjectStateException` | |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Detach changes downstream behavior in subtle ways the tests miss | Med | Verify script catches code-shape regressions; manual scenarios 1–5 cover behavioral surface |
| Other deferred sites (cosmetic, latent) accumulate technical debt | Low | Track a follow-up cleanup ticket for the signature change (see §12) |
| `ReleaseOrderJobService` second loop (L508–532) carries cross-iteration stale risk under unusual JPA cache behavior | Low | Documented in §10 as open question; no known production manifestation; defer until reproduced |
| New caller of `changeReservedAmount` is added later without rebinding | Med | Verify script enforces the pattern; long-term fix is the signature change in §12 |

---

## 10. Open Questions / Resolved Decisions

### Resolved (during this re-validation)

- **Q (critic M1):** Is the rationale for §0 row #12 (`ReleaseOrderJobService:518`) accurate?
  **A:** The original wording "next iteration uses fresh stockUnit" was misleading — the for-each iterates the in-memory `stockUnitCandidates` list and reads the next element, not a re-fetched entity. The corrected wording in §0 is: *"Stale ref does not escape loop body — `missing` math uses local `BigDecimal available` (computed L510 before the call); next iteration loads `stockUnitCandidates[i+1]`, a different object."* The SAFE verdict itself is unchanged and correct.

- **Q (critic M2):** Does `setStockToReplenishMobileOrder` (called at L301 after the `changeReservedAmount` at L288) read `getReservedamount()`?
  **A:** No — verified at `MobileReplenishService:161`. The helper reads `getUnitloadId()`, `getAmount()`, `getId()` only. Row #18 SAFE verdict stands.

- **Q (critic M3):** What happens in the L424 split branch if `sourceStock.getReservedamount() == 0`?
  **A:** The negate is 0; `changeReservedAmount` is a no-op-equivalent (it still acquires the lock and writes an audit row). The downstream `transferStockToUnitLoad` guard reads stale `0`, `available = amount − 0 = amount`, no crash. **However**, with any non-zero prior reservation on `sourceStock` the bug is identical to the L420 branch. The rebind is the correct fix in both cases.

- **Q (critic M4):** Should the test use `isEqualTo` or `isSameAs`?
  **A:** `isSameAs`. Documented in Fix C with rationale (Stockunit has no `@Override equals()`).

- **Q (critic M5):** Does this plan need a verify script?
  **A:** Yes; created — see §11.

- **Q (round-2 critic M3 / row #7 audit):** Does any caller of `ReplenishorderService.redirectSource` read the `stockUnit` parameter after the call returns?
  **A:** No. `redirectSource` has exactly two callers — `update()` at `ReplenishorderService:80` and `updateSourceStockUnit()` at `:101`. Both methods immediately `return replenishOrder` after the call (L92, L104). The `stockUnit` local is never read again on the caller side. Row #7 COSMETIC verdict holds with full audit chain documented.

- **Q (commit `2351004` audit):** Did the commit actually land the `confirmPick` rebind and the in-service detach contract?
  **A:** Verified via `git show 2351004` in `v1/wms-api`. Commit hash `23510044261760652cb0074ddb31f972d7c27743`, author Nam Park, dated 2026-04-22. Title: *"fix(picking): prevent StaleObjectStateException in changeReservedAmount (SBDEV-1710 follow-up)"*. Commit message confirms: (1) detach-before-lock contract added at `StockunitBusinessService.changeReservedAmount`; (2) `confirmPick` rebound to use return value; (3) prior `entityManager.refresh()` after lock removed. Production source matches: `StockunitBusinessService.java:324-326` (detach), `:328` (`findByIdForUpdate`), `:352` (returns fresh instance); `PickingorderBusinessService.java:267` (`stockUnit = stockunitBusinessService.changeReservedAmount(...)`).

- **Q (v2 audit — critic recommendation #7):** Does v2/wms2-api carry the same caller-rebind bug?
  **A:** **No (currently)** — but **yes (after the SBDEV-1710 port lands)**. Evidence:
  - v2's `StockunitBusinessService.changeReservedAmount` at `v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:393-421` is in the **pre-`2351004` state**: it uses `entityManager.refresh(stockUnit)` AFTER `findByIdForUpdate` (L398), the original SBDEV-1710 fix that v1 has since abandoned.
  - Because v2 does NOT detach the caller's reference, the caller's instance remains managed via `refresh()` — there is no caller-side staleness today in v2.
  - **However**, v2 retains the original `StaleObjectStateException` risk that drove `2351004` (post-lock refresh sits downstream of the throwing call). v2 will need to port `2351004` eventually.
  - When v2 ports `2351004`, the caller-rebind bug **will manifest at v2 lines 467 and 471** (mirrors v1 L420/L424) and `MobileReplenishService.java:473` (mirrors v1 L426). v2's `ReleaseOrderJobService.java:508/531/555/563` will mirror v1's L473/L494/L518/L526.
  - **Recommendation:** Pair the v2 SBDEV-1710 port with a v2-side caller-rebind plan that mirrors this one. Track via a sibling plan in `sbdocs/1-Projects/wms2/plan/` named `260427-changeReservedAmount-caller-rebind-followup.md` (same base name per the v1↔v2 pairing convention) — author it once the v2 port is scheduled. **Do not block this v1 hotfix on the v2 work.**

### Open

- **Q1:** Does `stockunitRepository.getStockUnitsByItemDataId` return previously-detached cached instances when called twice in the same persistence context (with OSIV enabled, which it is in `application.properties`)? If yes, `ReleaseOrderJobService:510` carries a cross-outer-iteration stale-read risk for orders with multiple positions sharing itemdata. The query is `nativeQuery=true` (`StockunitRepository.java:81-93`); native queries hydrate fresh managed instances via Hibernate's loader, which **likely** evicts the previously-detached entity from L1 cache and returns a new instance. Investigate via a Testcontainers integration test before opening a separate fix plan. Not in scope for this hotfix.
- **Q2:** Should the cleanup ticket (deferred from `2351004`) change the `changeReservedAmount` signature to `(Long id, …)` to make future stale-reference bugs structurally impossible? See §12 — **strongly recommended within 1 sprint**.

---

## 11. Acceptance

Run after every implementation pass:

```bash
bash sbdocs/9-System/scripts/verify-260427-changeReservedAmount-caller-rebind-followup.sh
```

The script encodes Fix A, Fix B, Fix C, Fix D as 25 active grep assertions plus 4 optional `mvn test` invocations (skip with `SKIP_MVN=1` for fast iteration). Exit 0 only when every check passes. The implementation is not complete until the script's output is paste-able with all PASS lines.

**Pre-implementation baseline (verified):** 13 PASS (state-guards: `2351004` contract preserved, SAFE callsites stay bare, test files exist) / 12 FAIL (the items the implementer must turn green). The 12 FAIL items map 1:1 to the four fixes:

| Fix | Failing checks (pre-implementation) |
|---|---|
| Fix A — `MobileReplenishService.java` rebinds | `FA-1-pos`, `FA-1-neg` |
| Fix B — `ReleaseOrderJobService.java` rebind | `FB-1-pos`, `FB-1-neg`, `FB-2d-pos` (count 4→3) |
| Fix C — `MobileReplenishServiceUnitTest` two methods | `FC-2a-pos`, `FC-2b-pos`, `FC-3-pos`, `FC-4-pos` |
| Fix D — `ReleaseOrderJobServiceUnitTest` one method | `FD-2-pos`, `FD-3-pos`, `FD-4-pos` |

**State-guard checks (must stay PASS at all times):** `FA-2-pos` (L426 stays bare), `FB-2a/b/c-pos` (L494/L518/L526 stay bare), `FC-1-pos` / `FD-1-pos` (test files exist), `FC-3-neg` / `FC-5-pos` / `FC-5-neg` (no stale-pattern test code), `RG-1..RG-4` (`2351004` contract preserved).

---

## 12. Alternatives Considered

| Option | Description | Why rejected (for this plan) |
|---|---|---|
| A. Rebind callers (this plan) | Add 3 line-level `x = ` rebinds; tighten 2 tests; ship. | Selected — minimal blast radius, preserves contract, ships fast. |
| B. Change `changeReservedAmount` signature to `(Long id, BigDecimal amount, …)` returning `Stockunit` | Forces every caller to think about identity vs. instance; structurally prevents the class of bug. | Touches all 26 callsites + every test that mocks `changeReservedAmount` (~20 tests). Not a hotfix. **Strongly recommended as a follow-up within 1 sprint** of this hotfix landing. Rationale: the type system is the only structural defense against this bug class — the `2351004` author already deferred this once and the cleanup ticket was never opened, leading directly to the current production crash. Track as `260428-changeReservedAmount-id-signature-refactor.md` (placeholder name); pair with the v2 SBDEV-1710 port (see §10 v2 audit). |
| C. Re-fetch `sourceStock` after the call via `findById` | One extra DB round-trip per call; works without changing service signature. | Strictly worse than Option A — extra DB hit, risks reading a snapshot from a different transaction context, doesn't generalize to the cosmetic / latent sites. |
| D. Roll back `2351004` and accept `StaleObjectStateException` recurrence | Restores the pre-`2351004` state. | Trades one production bug for another, and the original bug (SBDEV-1710) is itself critical. Not viable. |
| E. Inline the rebind inside `transferStockToUnitLoad`'s guard (re-fetch by id) | Treats the symptom at the throwing site only. | Symptom-treating; leaves the LATENT bug at `ReleaseOrderJobService:473` and any future similar callsite undefended. |

---

## 13. Completeness checklist

| # | Concern | Status |
|---|---|---|
| 1 | All callsites enumerated | ✓ §0 — 26/26 invocations validated against current source |
| 2 | Adjacent bugs | ✓ §2 Bug 2 (LATENT) and §2 Bug 3 (potential, deferred) |
| 3 | Backward compatibility | ✓ No contract change (signature, schema, payload, error shape) — only caller-side rebind |
| 4 | Concurrency | ✓ Pessimistic `findByIdForUpdate` already serializes; rebind is per-thread |
| 5 | Multi-tenant | ✓ No tenant boundary affected; all changes are within the existing tenant transaction |
| 6 | Error handling | ✓ Removes the false-throw path; no new throw paths introduced |
| 7 | Observability | no — log volume of the targeted `BusinessException` is the only metric needed; no new metrics required |
| 8 | Rollback / migration | ✓ Pure code change; rollback = revert two commits |
| 9 | Test coverage | ✓ §8.1–8.4; named test methods in Fix C and Fix D |
| 10 | Cross-version (v1↔v2) | ✓ §10 v2-audit Q — verified `v2/wms2-api/.../StockunitBusinessService.java:393-421` is in the pre-`2351004` state (uses post-lock `entityManager.refresh()`, not detach-before-lock). v2 has no caller-rebind bug today. When v2 ports `2351004`, paired plan `sbdocs/1-Projects/wms2/plan/260427-changeReservedAmount-caller-rebind-followup.md` will be needed; sites already enumerated for the port: v2 `MobileReplenishService.java:467,471,473` and `ReleaseOrderJobService.java:508,531,555,563`. **Not a blocker for this v1 hotfix.** |
