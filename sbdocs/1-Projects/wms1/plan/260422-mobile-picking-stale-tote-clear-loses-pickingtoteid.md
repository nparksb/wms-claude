---
title: "Stale Tote Cleanup Drops pickingtoteId of In-Flight PICKED Order"
ticket: ""
ticket_url: ""
type: bug
priority: urgent
status: planning
project: [wms1]
version: v1
requester: production-incident
created: 2026-04-22
updated: 2026-04-22
deployed_env: dev
related:
  - SBDEV-2102
  - 7cf29a9
tags:
  - plan
  - bug
  - picking
  - transactions
  - data-integrity
---

# Stale Tote Cleanup Drops pickingtoteId of In-Flight PICKED Order

**Ticket:** _untracked — production incident on `release` branch_
**Project:** v1/wms-api | **Version:** v1 | **Type:** Bug (Regression of `7cf29a9`)
**Priority:** Urgent (data integrity — orders silently lose tote linkage; OMS QA fails downstream)
**Status:** PLANNING
**Date:** 2026-04-22

---

## 1. Problem Statement

### User-visible symptom

OMS QA on a Pick-Pack (`OrderBatchType.PICK_PACK`) parcel fails with:

```
WmsException None: A general error
```

WMS API logs at QA time show:

```
BusinessException: Cannot package order=<orderNumber> without an assigned picking tote
  at CustomerorderService.packageOrder (CustomerorderService.java:442)
```

Database state at the time of the failure:

```
SELECT id, number, state, pickingtote_id, pickingconfirmationsent
FROM customerorder WHERE number = '<orderNumber>';
-- state = 600 (PICKED)
-- pickingtote_id = NULL          ← unexpected; the order WAS picked into a tote
-- pickingconfirmationsent = true ← OMS was already notified the order is ready for QA
```

### Operator workaround that confirmed the diagnosis

Manually re-populating `customerorder.pickingtote_id` to the tote that originally held the picked stock allowed `packageOrder()` to proceed, and OMS QA completed successfully. The picked stock was still on that tote — only the column linking the order to the tote was missing.

### Inconsistency with OMS

WMS had already sent the `customerOrderPicked` ("ready for QA") OMS notification (`PickingorderBusinessService.finishPickingOrder` afterCommit hook, line ~152–161). For that message to fire, the picking transaction must have committed. Yet `pickingtote_id` was empty. That contradiction is the smoking gun: the field was set during picking, then **silently nulled later** by another transaction.

### Reproduction (synthesized from the production trace)

1. Order **A** is picked normally. After all picks, `A.state = PICKED (600)`, `A.pickingtote_id = T1`, OMS notified.
2. Tote **T1** is sitting on FinishedPicking (or wherever the operator left it after the last pick) — *not yet packaged*, so it still holds Order A's stockunits.
3. While Order A is still PICKED-but-not-yet-PACKED, **another picker scans T1** during a different pick session (own picking order, own pickingPosition).
4. `MobilePickingService.processPick` enters its tote-exists branch. The "stale tote cleanup" block (`MobilePickingService.java:385–411`) finds Order A as the current owner of T1, sees `A.state >= PICKED`, and clears `A.pickingtote_id = null` followed by `save(A)`.
5. The very next validation in the same block throws `BusinessException("not on empty totes location")` (or `"not empty"`), because T1 isn't actually free.
6. Because `processPick` is annotated `@Transactional` **without** `rollbackFor` — and `BusinessException extends Exception` (checked) — Spring's default rollback rule (RuntimeException-only) lets the cleanup `save(A)` **commit**. The picker sees a "tote not on empty totes location" error and tries again with a different tote; nobody notices that Order A's link was just severed.
7. OMS QA call lands. `packageOrder(A)` finds `pickingtote_id == null` and refuses.

---

## 2. Root Cause Analysis

There are **two compounding defects**, both inside the else-branch at `MobilePickingService.java:384–411`. Either alone would be a latent flaw; together they create the silent data loss observed in production.

### Bug 1: State guard `>= PICKED` is wrong; the only orders the query can return at PICKED+ are exactly the ones that still need their tote (PRIMARY)

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java:387–398`

```java
Optional<Customerorder> possibleOldCustomerOrderOpt =
    customerorderRepository.getOrderByToteLabelId(toteName);
if (possibleOldCustomerOrderOpt.isPresent()) {
    Customerorder oldOrder = possibleOldCustomerOrderOpt.get();
    if (oldOrder.getState() >= WmsConstants.State.PICKED) {        // ← TOO LAX
        // Old order finished picking — clear stale tote reference to allow reuse
        LOG.debug("tote=" + toteName + " clearing stale reference from finished order=" + oldOrder.getId());
        oldOrder.setPickingtoteId(null);
        customerorderRepository.save(oldOrder);
    } else {
        LOG.debug("tote=" + toteName + " already/still bound to active order=" + oldOrder.getId());
        throw new BusinessException(toteName + " belongs to different order!");
    }
}
```

Why the guard is wrong:

- `WmsConstants.State.PICKED = 600` is **not terminal**. The full progression after PICKED is `PACKED (650) → PALLETIZED (670) → FINISHED (700)`. An order at PICKED still needs its `pickingtoteId` for the OMS-triggered `CustomerorderService.packageOrder` step (line 441–443):

  ```java
  if (customerOrder.getPickingtoteId() == null) {
      throw new BusinessException("Cannot package order=" + customerOrder.getNumber()
          + " without an assigned picking tote");
  }
  ```

- `getOrderByToteLabelId` (`CustomerorderRepository.java:142–146`) is a native query that joins on `co.pickingtote_id = u.id`. As soon as `packageOrder()` runs, it sets `pickingtote_id = null` (`CustomerorderService.java:470`). So at PACKED+, the query **cannot** return that order anymore — the FK is gone.

- That means **the only realistic state in which `getOrderByToteLabelId` returns a row AND `state >= PICKED` is `state == PICKED`** — exactly the window where clearing the linkage is destructive. Every successful trigger of this branch corrupts an in-flight order.

### Bug 2: Write-before-validate in a transaction that doesn't roll back on `BusinessException` (UNMASKER)

**File:** `MobilePickingService.java:341, 387–411`, plus `exceptions/BusinessException.java:14`.

```java
@Transactional                                          // ← NO rollbackFor
public Pickingorder processPick(...) throws BusinessException, FacadeException {
    ...
    } else {
        // 1. CLEANUP (write) — happens BEFORE validation
        if (oldOrder.getState() >= WmsConstants.State.PICKED) {
            oldOrder.setPickingtoteId(null);            // ← STAGED in PC
            customerorderRepository.save(oldOrder);     // ← STAGED in PC
        }
        // 2. VALIDATION 1 — can throw
        if (!tote.getStoragelocationId().equals(emptyTotesLocation.getId())) {
            throw new BusinessException(toteName + " not on empty totes location...");
        }
        // 3. VALIDATION 2 — can throw
        if (!stockUnitList.isEmpty()) {
            throw new BusinessException(toteName + " not empty!");
        }
    }
```

Why the TX commits the cleanup despite the exception:

- `public class BusinessException extends Exception` (`exceptions/BusinessException.java:14`) — **checked exception**, not a `RuntimeException`.
- Spring's `@Transactional` default rollback rule rolls back only on `RuntimeException` and `Error`. Checked exceptions need explicit `rollbackFor`.
- `processPick` has `@Transactional` with no `rollbackFor`, so any `BusinessException` thrown out of it **does not roll back the transaction**.
- The pre-throw `save(oldOrder)` is therefore flushed at commit. The cleanup persists; the operator sees an error message; the linked order is now broken.

Every other `@Transactional` in the same file is annotated correctly:

| Method | Line | `rollbackFor` |
|---|---|---|
| `selectAndReservePickingOrder` | 115 | ✅ `{BusinessException, FacadeException}` |
| `releasePickingOrder` | 176 | ✅ |
| `startPickingOrder` | 242 | ✅ |
| **`processPick`** | **341** | ❌ **missing** |
| `releaseRegularPickingOrder` | 565 | ✅ |
| `getPickingOrderPositionsInfo` | 588 | ✅ |
| `rapidPickingScanSource` | 880 | ❌ **also missing — same defect class** |

`rapidPickingScanSource` (line 880) is structurally similar — `@Transactional` without `rollbackFor`, and it also performs writes interleaved with `BusinessException` throws against `pickingorderRepository`, `unitloadRepository`, etc. It is not the cause of *this* incident, but it carries the same latent risk.

---

## 3. The Regression Chain

| Commit | Date | Author | Change | Effect |
|---|---|---|---|---|
| `a685e07` | initial | — | Original `processPick` had no stale-tote-cleanup block | No cleanup; if a tote owner reference existed, the scan threw "belongs to different order" outright |
| `7cf29a9` | 2026-03-18 | Nam Park | `fix: prevent tote/pickingorder disconnect by scoping tote assignment and cleaning up orphans` — added the `if (oldOrder.getState() >= WmsConstants.State.PICKED) { setPickingtoteId(null); save; }` block | Introduced the cleanup with state-guard `>= PICKED` and write-before-validate ordering. `processPick` was already `@Transactional` without `rollbackFor`, so the new cleanup save bypassed any rollback on the throws that follow it. |

The original intent of `7cf29a9` was correct: allow a tote to be reused after it had been freed. The mistake was treating `PICKED` as "freed" (it isn't — packaging hasn't happened yet) and placing the destructive write before the validation guards.

---

## 4. Architecture Overview

### Picking flow (TOTES_ON_CART, OrderBatchType=PICK_PACK)

```
Mobile → PickingController.processPick(po, pop, toteName)
  → MobilePickingService.processPick      [@Transactional]   ← bug surface
       ├ re-read po, pop in TX
       ├ load tote by labelid
       ├ pickingUnitLoad == null (first pick of order)?
       │   → IF (tote==null): create tote on emptyTotes
       │   → ELSE (tote exists):
       │       ├ getOrderByToteLabelId(toteName) → oldOrder?           ← Bug 1+2 trigger
       │       │    if oldOrder.state >= PICKED:
       │       │       oldOrder.pickingtoteId = null; save             ⚠️
       │       ├ tote.location == emptyTotes?  else throw              ⚠️
       │       └ tote stockunits empty?        else throw              ⚠️
       │   → create pickingUnitLoad
       │   → transferUnitLoadToLocation(tote → user loc)
       │   → customerOrder.pickingtoteId = tote.id; save
       │   → afterCommit { OMS.customerOrderToteAssigned(co) }
       │   → for each sibling pickingPosition of co: setPicktounitloadId
       │   → re-read pickingPosition
       │
       └ confirmPick(pop, pickingUnitLoad, amount)
             ├ stockunitBusinessService.changeReservedAmount(stockUnit, ...)
             ├ transferStockToUnitLoad(srcSU → tote SU)
             ├ pop.state = PICKED, save
             └ if pickingOrder.state == PICKED:
                  pickingOrderBusinessService.finishPickingOrder
                       └ customerOrder.pickingconfirmationsent = true, save
                       └ afterCommit { OMS.customerOrderPicked(co) }   ← "ready for QA"

OMS QA → MobileShippingController.packageOrder(co.number)
  → CustomerorderService.packageOrder
       └ if (co.pickingtoteId == null) throw "Cannot package order... without picking tote"  ← fails here
```

### Key Files

| File | Lines | Role |
|---|---|---|
| `MobilePickingService.java` | 341 | `processPick` `@Transactional` without `rollbackFor` |
| `MobilePickingService.java` | 384–411 | else-branch: stale-tote-cleanup interleaved with validation throws |
| `MobilePickingService.java` | 423–425 | sets `customerOrder.pickingtoteId = tote.id` (the value subsequently nulled) |
| `MobilePickingService.java` | 880 | `rapidPickingScanSource` `@Transactional` without `rollbackFor` (related risk) |
| `CustomerorderService.java` | 441–443 | `packageOrder` precondition that fails when `pickingtoteId == null` |
| `CustomerorderService.java` | 469–472 | `packageOrder` legitimately clears `pickingtoteId` (the only other writer of NULL) |
| `CustomerorderRepository.java` | 142–146 | `getOrderByToteLabelId` native SQL — joins on `pickingtote_id` |
| `exceptions/BusinessException.java` | 14 | `extends Exception` — checked, requires explicit `rollbackFor` |
| `PickingorderBusinessService.java` | 152–161 | `finishPickingOrder` afterCommit → `OMS.customerOrderPicked` |

### State landscape

```
0 RAW → 200 ASSIGNED → 300 PROCESSABLE → 400 RESERVED → 500 STARTED
      → 550 PENDING (partial) → 600 PICKED → 650 PACKED → 670 PALLETIZED → 700 FINISHED
      → 800 CANCELED                                                          (terminal)
```

`pickingtoteId` lifecycle:
- Set: `MobilePickingService.processPick:423` (regular) and `:822` (rapid pickingConnectPackageAndType, non-transactional — separate concern).
- Cleared (legitimate): `CustomerorderService.packageOrder:470` (PACKED), `cleanUpCancelledOrder:720` (CANCEL), `cancelOrder` RAPID branch:613 (CANCEL), `cancelOrderPosition:319` (POSITION CANCEL), `CustomerorderBatchService:292` (BATCH CANCEL).
- Cleared (defective): **`MobilePickingService.processPick:392`** — the bug.

---

## 5. Fix Design

Three fixes in one file (`v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`). Fix A is the actual repair; B and C close the *class* of bug for symmetry.

### Fix A: Validate the tote BEFORE clearing any owning-order reference; tighten the state guard from `PICKED` to `FINISHED` (PRIMARY)

**File:** `MobilePickingService.java:385–411`

**Before (defective):**

```java
} else {
    Optional<Customerorder> possibleOldCustomerOrderOpt =
        customerorderRepository.getOrderByToteLabelId(toteName);

    if (possibleOldCustomerOrderOpt.isPresent()) {
        Customerorder oldOrder = possibleOldCustomerOrderOpt.get();
        if (oldOrder.getState() >= WmsConstants.State.PICKED) {
            LOG.debug("tote=" + toteName + " clearing stale reference from finished order=" + oldOrder.getId());
            oldOrder.setPickingtoteId(null);
            customerorderRepository.save(oldOrder);
        } else {
            LOG.debug("tote=" + toteName + " already/still bound to active order=" + oldOrder.getId());
            throw new BusinessException(toteName + " belongs to different order!");
        }
    }

    if (!tote.getStoragelocationId().equals(emptyTotesLocation.getId())) {
        Location location = locationRepository.findById(tote.getStoragelocationId()).get();
        LOG.debug("tote=" + toteName + " not on empty totes location but " + location.getName());
        throw new BusinessException(toteName + " not on empty totes location but " + location.getName());
    }

    List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(tote.getId());
    if (!stockUnitList.isEmpty()) {
        LOG.debug("tote=" + toteName + " not empty!");
        throw new BusinessException(toteName + " not empty!");
    }
}
```

**After (fixed):**

```java
} else {
    // Verify the tote is genuinely available BEFORE touching any owning-order reference.
    // If a check below throws, Fix B's rollbackFor will roll back the transaction; ordering
    // the writes after validation makes the contract obvious and tolerant of future TX-attribute
    // changes. (Reverses the original 7cf29a9 ordering that surfaced the production incident.)

    if (!tote.getStoragelocationId().equals(emptyTotesLocation.getId())) {
        Location location = locationRepository.findById(tote.getStoragelocationId()).get();
        LOG.debug("tote=" + toteName + " not on empty totes location but " + location.getName());
        throw new BusinessException(toteName + " not on empty totes location but " + location.getName());
    }

    List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(tote.getId());
    if (!stockUnitList.isEmpty()) {
        LOG.debug("tote=" + toteName + " not empty!");
        throw new BusinessException(toteName + " not empty!");
    }

    // Tote is genuinely free for reuse. Now safely clear any orphan owning-order reference.
    // State guard tightened from >= PICKED (600) to >= FINISHED (700): an order at PICKED still
    // needs its pickingtoteId for OMS QA → packageOrder. The only realistic case where
    // getOrderByToteLabelId returns a row at PACKED+ would be a manual DB poke, since
    // packageOrder() nulls pickingtote_id at that transition.
    Optional<Customerorder> possibleOldCustomerOrderOpt =
        customerorderRepository.getOrderByToteLabelId(toteName);
    if (possibleOldCustomerOrderOpt.isPresent()) {
        Customerorder oldOrder = possibleOldCustomerOrderOpt.get();
        if (oldOrder.getState() >= WmsConstants.State.FINISHED) {
            LOG.debug("tote=" + toteName + " clearing stale reference from finished order=" + oldOrder.getId());
            oldOrder.setPickingtoteId(null);
            customerorderRepository.save(oldOrder);
        } else {
            // PICKED / PACKED / PALLETIZED — the tote is still load-bearing for QA → package.
            // Refuse the scan; do NOT null the owning order's pickingtoteId.
            LOG.debug("tote=" + toteName + " still bound to in-flight order=" + oldOrder.getId()
                + " state=" + oldOrder.getState());
            throw new BusinessException(toteName + " is still bound to order "
                + oldOrder.getNumber() + " (state=" + oldOrder.getState() + ")");
        }
    }
}
```

**Why this is correct:**
- All throwable validations precede the only write. With Fix B's `rollbackFor`, any throw rolls back cleanly. Without Fix B, no write has been staged yet — there is nothing to leak.
- `>= FINISHED (700)` is the only state where `pickingtoteId` is genuinely orphaned and safe to clear.
- The new error message names the binding order so operations can find it quickly.

### Fix B: Add `rollbackFor` to `processPick`'s `@Transactional` (DEFENSE-IN-DEPTH)

**File:** `MobilePickingService.java:341`

**Before:**

```java
@Transactional
public Pickingorder processPick(Pickingorder pickingOrder, PickingorderPosition pickingPosition,
        String toteName) throws BusinessException, FacadeException {
```

**After:**

```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public Pickingorder processPick(Pickingorder pickingOrder, PickingorderPosition pickingPosition,
        String toteName) throws BusinessException, FacadeException {
```

Brings `processPick` in line with every other `@Transactional` in this file. Without it, *any* `save()` followed by a `BusinessException` in `processPick` is a latent partial-commit bug.

### Fix C: Add `rollbackFor` to `rapidPickingScanSource` (SYMMETRY)

**File:** `MobilePickingService.java:880`

**Before:**

```java
@Transactional
public PickingHighPositionInfoDto rapidPickingScanSource(PickingorderPosition pickingPosition,
        String source) throws BusinessException, FacadeException {
```

**After:**

```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public PickingHighPositionInfoDto rapidPickingScanSource(PickingorderPosition pickingPosition,
        String source) throws BusinessException, FacadeException {
```

This method also stages writes (e.g. `pickingOrder.setPickinginprogress(true); save`) and throws `BusinessException` mid-flow. It is not the cause of *this* incident, but the same latent risk applies. One-line change, no behavior change on the happy path.

### Alternatives considered (and rejected)

| Option | Why not |
|---|---|
| Make `BusinessException extends RuntimeException` | Would fix this *and* every similar latent bug across the codebase, but too broad for an urgent hotfix; many existing `try/catch (BusinessException)` blocks rely on the checked-ness for control flow signalling and would silently change behavior. Worth a follow-up tech-debt ticket. |
| Use programmatic TX management with explicit rollback in the catch block | Bigger diff; loses the declarative `@Transactional` clarity; doesn't fix Bug 1 (the wrong state guard). |
| Skip the cleanup entirely (delete lines 387–398) | Loses the legitimate orphan-recovery intent of `7cf29a9`. Tighter state guard at FINISHED preserves intent. |
| Only apply Fix B without Fix A | Fix B alone closes the symptom: cleanup save would roll back on the subsequent throw. But the wrong state guard (Bug 1) remains — if the tote IS clean and on the empty lane (e.g., manual move), the cleanup would still fire on a PICKED order and silently break it. Need Fix A to address the underlying guard. |

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java` | Modify | Fix A: reorder else-branch (`385–411`) — validate location + emptiness before any owning-order write; tighten state guard to `>= FINISHED`; throw informative error when refusing a PICKED-bound tote. Fix B: add `rollbackFor` to `processPick @Transactional` (line 341). Fix C: add `rollbackFor` to `rapidPickingScanSource @Transactional` (line 880). |
| `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePickingServiceUnitTest.java` | Modify | Add 5 new tests (see §8). Audit any existing test that asserts state changes after a `BusinessException` from `processPick` and update or remove. |
| `v1/wms-api/src/test/java/net/aim_ai/wms/service/mobile/MobilePickingServiceIT.java` | Modify | Add 2 new integration tests covering the production scenario (see §8). |

**No DB migration. No DTO/API changes. No frontend changes.**

---

## 7. Implementation Steps

Ordered, each step a self-contained commit so it can be reverted independently.

### Step 1 — Apply Fix A (else-branch reorder + state guard)

`MobilePickingService.java:385–411`. Move the location and stockunit checks above the `getOrderByToteLabelId`/`setPickingtoteId(null)` block. Tighten the state guard from `>= WmsConstants.State.PICKED` to `>= WmsConstants.State.FINISHED`. Replace the "active order" else with the more informative "still bound to in-flight order" message that includes the binding order number and state.

### Step 2 — Apply Fix B (`rollbackFor` on `processPick`)

`MobilePickingService.java:341`. One-line annotation change.

### Step 3 — Apply Fix C (`rollbackFor` on `rapidPickingScanSource`)

`MobilePickingService.java:880`. One-line annotation change.

### Step 4 — Add unit tests

New tests added to `MobilePickingServiceUnitTest`. See §8 for the explicit test list and assertions.

### Step 5 — Add integration tests

New tests added to `MobilePickingServiceIT` (or a new `MobilePickingServiceStaleToteIT` if the existing IT file gets too crowded). See §8.

### Step 6 — Audit existing test fixtures for behavioral change

Any pre-existing `processPick` test that asserts state changes after a thrown `BusinessException` may now fail — those assertions were validating the bug. Update them to assert no state change instead.

### Step 7 — Build & verify

```bash
cd v1/wms-api
mvn test -Dtest=MobilePickingServiceUnitTest
mvn verify -Dit.test=MobilePickingServiceIT
mvn clean package -DskipTests -Dmaven.javadoc.skip=true     # smoke-build
```

### Step 8 — Cherry-pick to `release`, then forward-port

`release-hotfix-260422` is already off `release` for the SBDEV-1710 follow-up (`2351004`). Land this fix as a follow-up commit on the same hotfix branch, then forward-port to `develop` and `main` via standard GitFlow.

---

## 8. Testing Plan

> **Mandatory gate (per `wms-bugfix-plan` skill):** Every code change in this plan must have at least one unit test asserting the new behavior. Run `mvn test -Dtest=MobilePickingServiceUnitTest` first for fast feedback, then `mvn verify` before the fix leaves the branch. Update §10 Implementation Status with commit SHAs and `mvn` result counts before sign-off.

### Unit tests (Mockito 3.3.3 — no `mockStatic`)

Add to `MobilePickingServiceUnitTest`:

| Test method | Asserts |
|---|---|
| `processPick_existingToteOwnedByPickedOrder_throwsAndDoesNotClearPickingtoteId` | `getOrderByToteLabelId` returns an order at state `PICKED`. Tote is on emptyTotes and empty. Verify `BusinessException` thrown with message matching "still bound to in-flight order"; verify `customerorderRepository.save(oldOrder)` is **never** called with `pickingtoteId == null` (use `verify(repo, never()).save(argThat(co -> co.getPickingtoteId() == null))`). This is the regression guard for Bug 1. |
| `processPick_existingToteOnNonEmptyLocation_throwsBeforeAnyClear` | Tote `storagelocationId != emptyTotesLocation.id`. Verify `BusinessException` thrown with "not on empty totes location" and `getOrderByToteLabelId` is **never** called and no `save` on prior owner. Regression guard for the validation-before-write reordering of Bug 2. |
| `processPick_existingToteWithStock_throwsBeforeAnyClear` | Tote on emptyTotes but `findByUnitloadId(tote.id)` returns non-empty list. Same assertion as above (`getOrderByToteLabelId` never called; no save on prior owner). |
| `processPick_existingToteOwnedByFinishedOrder_clearsAndContinuesWithNewAssignment` | `getOrderByToteLabelId` returns order at state `FINISHED (700)`. Tote on emptyTotes, empty. Verify `oldOrder.pickingtoteId` set to null and saved exactly once; the calling order's `pickingtoteId` is set to the tote and saved. |
| `processPick_brandNewTote_isCreatedAndAssigned_unchanged` | Existing happy-path test (tote == null). Should still pass after Fix A and Fix B; included in the regression matrix to confirm no behavior change on the create-tote path. |

### Integration tests (Testcontainers PostgreSQL)

Add to `MobilePickingServiceIT` (or new `MobilePickingServiceStaleToteIT`):

| Test method | Scenario | Expected |
|---|---|---|
| `staleToteScan_doesNotNullPickingtoteIdOfPickedOrder` | Seed Order A with `state=PICKED, pickingtoteId=T1`, T1 on FinishedPicking with A's stockunits. Trigger `processPick(po_for_orderC, position_C, "T1")` with appropriate `@Sql` fixture. Catch `BusinessException`. Re-read Order A from DB. | `A.pickingtoteId == T1` (unchanged), `A.pickingconfirmationsent == true` (unchanged). |
| `cleanToteScan_clearsFinishedOrphanReference` | Seed Order A with `state=FINISHED, pickingtoteId=T1`, T1 on emptyTotes, empty. Call `processPick` for Order C using T1. | A.pickingtoteId == null after; Order C's `pickingtoteId == T1`; both saved successfully. |

### Regression — manual smoke against staging (TOTES_ON_CART, PICK_PACK batch)

| Scenario | Expected |
|---|---|
| Two pickers on the same warehouse, different orders, accidentally share a tote label still bound to a PICKED order | Second picker's scan throws "is still bound to order …"; **first picker's order proceeds to QA cleanly** (`pickingtoteId` survives). |
| Order completes pick → reaches PICKED → OMS QA → package | Succeeds end-to-end; no need to manually backfill `pickingtoteId`. |
| Operator scans a tote that was orphaned on a long-finished (FINISHED) order | Cleanup fires, tote re-binds to the new order, no error. |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=MobilePickingServiceUnitTest` | _to fill_ | _to fill_ |
| `mvn verify -Dit.test=MobilePickingServiceIT` | _to fill_ | _to fill_ |
| `mvn verify` (full suite) | _to fill_ | _to fill_ |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| `rapidPickingScanSource` integration test of the new `rollbackFor` | Out of scope of *this incident* — Fix C is preventive only. A targeted unit test that throws after a `pickingorderRepository.save` and verifies the save is not visible post-throw is sufficient; full IT can be deferred. |
| `rapidPickingConnectPackageAndType` (line 769, NOT @Transactional, sets `pickingtoteId` at line 822) | Has its own latent issue class (no transaction at all) but doesn't use the bug-1 path. Track as follow-up ticket; outside this hotfix's blast radius. |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Throwing on a PICKED-bound tote may surface "stuck" totes operations was unknowingly relying on | Medium | The new error message names the binding order (`"is still bound to order <X> (state=600)"`). Operators can immediately query / unblock that order. Far better than silently breaking it. |
| Adding `rollbackFor` to `processPick` causes any partial state previously committed-on-throw to now roll back | Low | Those half-committed states are exactly the bugs we want to prevent. Any caller that *relied* on save-and-throw was already broken. Audit existing tests for assertions after a thrown `BusinessException`; update them. |
| Reordering the else-branch puts the `getOrderByToteLabelId` query after the `findByUnitloadId(tote.id)` query — small extra DB roundtrip in the throw path | Negligible | Both are cheap PK/index lookups. Net query count is unchanged on the success path. |
| Hot-fix branch concurrency with the SBDEV-1710 fix already on `release-hotfix-260422` (`2351004`) | Low | Different files (`MobilePickingService.java` vs `StockunitBusinessService.java` / `PickingorderBusinessService.java`); no merge conflict expected. The `processPick` change is at the top of the method (annotation) and middle (else-branch); the SBDEV-1710 caller change touched line 263. Independent diffs. |
| Forward-port to `develop` and `main` later finds drift | Low | Single-file scope; cherry-pick should be clean. If drift exists, redo Fix A by hand on each branch — it's small. |
| The same defect class likely hides elsewhere in the codebase (other `@Transactional` methods without `rollbackFor` that throw `BusinessException` mid-state-change) | Medium (long term) | Open a follow-up ticket: grep `@Transactional\n.*throws.*BusinessException` and audit each. SBDEV-2116 (the unguarded-Optional plan) already touches the surrounding territory. Out of scope here. |

---

## 10. Implementation Status

**Date applied:** 2026-04-22
**Branch:** `release-hotfix-260422` (continuation of the SBDEV-1710 follow-up branch; commit `2351004` already on it)

### Changes Applied

| Fix | File | Lines | Status | Commit SHA |
|---|---|---|---|---|
| A: Reorder else-branch + tighten state guard to FINISHED | `MobilePickingService.java` | 384–423 (post-edit) | ✅ Applied | `1752452` |
| B: `rollbackFor` on `processPick` | `MobilePickingService.java` | 341 | ✅ Applied | `1752452` |
| C: `rollbackFor` on `rapidPickingScanSource` | `MobilePickingService.java` | 891 (post-edit) | ✅ Applied | `1752452` |
| Unit test 1: refused-message + no-save regression guard | `MobilePickingServiceUnitTest.java` (`processPick_PickingUnitLoadNullToteBelongsToDifferentOrder_ThrowsBusinessException`) | edited | ✅ Updated | `1752452` |
| Unit test 2: validation-before-lookup guard (wrong location) | `MobilePickingServiceUnitTest.java` (`processPick_PickingUnitLoadNullToteNotOnEmptyTotesLocation_ThrowsBusinessException`) | edited | ✅ Updated | `1752452` |
| Unit test 3: validation-before-lookup guard (non-empty tote) | `MobilePickingServiceUnitTest.java` (`processPick_PickingUnitLoadNullToteHasStock_ThrowsBusinessException`) | edited | ✅ Updated | `1752452` |
| Unit test 4: PRIMARY regression guard for PICKED-bound | `MobilePickingServiceUnitTest.java` (`processPick_existingToteOwnedByPickedOrder_throwsAndDoesNotClearPickingtoteId`) | new | ✅ Added | `1752452` |
| Unit test 5: FINISHED-orphan happy path | `MobilePickingServiceUnitTest.java` (`processPick_existingToteOwnedByFinishedOrder_clearsAndContinues`) | new | ✅ Added | `1752452` |
| Existing-test audit: corrected the codified-bug test | `MobilePickingServiceUnitTest.java` (`processPick_ToteReuse_ClearsStaleReferenceFromFinishedOrder`) | state PICKED → FINISHED | ✅ Updated | `1752452` |
| Integration test 1: production-scenario regression | `MobilePickingServiceIT.java` (`staleToteScan_doesNotNullPickingtoteIdOfPickedOrder`) | new | ✅ Added | `1752452` |
| Integration test 2: FINISHED-orphan happy path | `MobilePickingServiceIT.java` (`cleanToteScan_clearsFinishedOrphanReference`) | new | ✅ Added | `1752452` |

### Test Results

| Command | Result | Counts |
|---|---|---|
| `mvn test -Dtest=MobilePickingServiceUnitTest` | **PASS** | 77 / 0 / 0 (Tests / Failures / Errors) — includes 2 new + 4 modified |
| `mvn test` (full suite, `-Dmaven.javadoc.skip=true -Dcheckstyle.skip`) | 3 pre-existing failures only | 1621 / 1 / 2 — net +2 tests vs. the 1619 baseline; **zero regressions from this fix** |
| `mvn test-compile` | **PASS** | IT class compiles clean |
| `mvn verify -Dit.test=MobilePickingServiceIT` (local) | **BLOCKED (env)** | Same Testcontainers / Hibernate schema-validation env drift documented in the SBDEV-1710 follow-up `2351004`. ITs will run in CI; compile-tested locally. |

#### Pre-existing test failures (confirmed identical on the same branch via SBDEV-1710 fix run)

| Test | Pre-existing? |
|---|---|
| `ViewDtoServiceUnitTest.testGetReplenishOrderViewByKeyword_OpenState` (ERROR) | ✅ yes |
| `ViewDtoServiceUnitTest.testGetReplenishOrderViewByKeyword_ClosedState` (ERROR) | ✅ yes |
| `MobileMoveStockServiceUnitTest.selectDestination_destinationLabelDoesNotMatchPattern_ThrowsBusinessException` (FAILURE) | ✅ yes |

**Net regression impact of this fix: zero.**

### Deliberately-skipped coverage

| What | Why |
|---|---|
| `mvn verify` full integration-test run locally | Same pre-existing Testcontainers / Hibernate schema-validation drift that affected the SBDEV-1710 IT (`StockunitBusinessServiceConcurrencyIT`) on this machine. New ITs are written correctly and will run in CI. |
| `rapidPickingConnectPackageAndType` / `rapidPickingScanPackageAndType` | Out of hotfix scope per §13. Currently dead code (sole controller endpoint commented out). Tracked as follow-up #3 in §12. |

### Branches / PRs

- **Hotfix branch:** `release-hotfix-260422` (currently checked out, off `release`, with SBDEV-1710 fix `2351004` already on it).
- **Forward-port:** Cherry-pick onto `develop` after `release` merge. Cherry-pick onto `main` as the final step.

### Files touched

```
src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java                           (Fix A, B, C)
src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePickingServiceUnitTest.java              (3 edited, 2 added, 1 audited)
src/test/java/net/aim_ai/wms/service/mobile/MobilePickingServiceIT.java                         (2 added)
```

---

## 11. Dev Server Verification Plan

> **Context:** Fixes A / B / C are deployed on the **dev server** (2026-04-22, branch `release-hotfix-260422`, commit `1752452`). Goal: prove on a running system that (1) a concurrent scan of a PICKED-bound tote refuses the scan instead of silently nulling `customerorder.pickingtote_id`; (2) end-to-end OMS QA → `packageOrder` still succeeds; and (3) the legitimate FINISHED-orphan cleanup path still works. Unit/IT tests cover the code path; this section proves the **integration** (mobile client → API → DB → OMS QA call).

### 11.1 Pre-checks (one-time setup before running any scenario)

| # | Check | Command / Action | Expected |
|---|-------|------------------|----------|
| 1 | Deployed JAR contains all three fixes | `ssh dev-app "unzip -p /opt/wms-api/wms-api.jar BOOT-INF/classes/net/aim_ai/wms/service/mobile/MobilePickingService.class" \| javap -p -v - 2>/dev/null \| grep -E 'rollbackFor\|FINISHED'` | See `rollbackFor` in at least two `@Transactional` annotations; see a reference to `WmsConstants$State.FINISHED` in `processPick`. |
| 2 | Source-level spot check (if JAR is inaccessible) | `ssh dev-app "cat /opt/wms-api/release-tag"` or `curl https://<dev-host>/api/actuator/info` | Git SHA = `1752452` (or forward-port SHA). |
| 3 | Log tail reachable | `ssh dev-app "tail -F /var/log/wms-api/*.log"` | Live stream. |
| 4 | `app.cron` state on dev | `grep app.cron= /opt/wms-api/application-*.properties` | Note the value (`true` or `false`) for Scenario F interpretation. |
| 5 | Stage a hot SKU | Same SKU used for the SBDEV-1710 verification. Ensure `Stockunit.amount ≥ 3` and `reservedamount = 0`. | `SELECT id, amount, reservedamount FROM stockunit WHERE id = :hotUnitId;` returns one clean row. |
| 6 | Stage an empty-totes location | Identify the location name configured in `LosSysprop` key `app.warehouse.emptytotes.locationname` (or whatever the tenant setting is). | `SELECT id, name FROM location WHERE name = '<emptytotes>';` |
| 7 | Pick two reusable tote labels | Choose `T-DEVQA-1`, `T-DEVQA-2` that are not currently owned by any active order. | `SELECT id, pickingtote_id FROM customerorder WHERE pickingtote_id IN (SELECT id FROM unitload WHERE labelid IN ('T-DEVQA-1','T-DEVQA-2'));` → 0 rows. |
| 8 | Pick-Pack batch-type order workflow available | Tenant must have `OrderBatchType.PICK_PACK` enabled. Confirm a past PICK_PACK order has flowed end-to-end. | `SELECT COUNT(*) FROM customerorder_batch WHERE type='PICK_PACK' AND state >= 700;` > 0 |

> If step 1 shows the old state guard or missing `rollbackFor`, **stop** — the deployed build is not the fix.

#### 11.1.1 Important field contract — `customerorder.pickingtote_id` lifecycle (so verification asserts the right thing)

| `customerorder.state` | `pickingtote_id` | Meaning |
|-----------------------|------------------|---------|
| `< 600` (pre-pick) | NULL | Not yet bound to a tote |
| `500 STARTED … 600 PICKED` | NOT NULL | **Load-bearing** — OMS QA / `packageOrder` requires this FK |
| `650 PACKED` | NULL (set by `packageOrder:470`) | Legitimately cleared — post-pack |
| `700 FINISHED` | usually NULL; rarely NOT NULL as orphan from a rare upstream failure | If NOT NULL, this is the only state where the stale-tote cleanup is *supposed* to clear it |
| `800 CANCELED` | NULL | Cleared by cancellation paths |

**Key invariant** this fix enforces: **at state 500 ≤ state < 700, `pickingtote_id` must not be silently nulled by a sibling picker's scan.** Every scenario below asserts this.

### 11.2 Scenario A — Happy path single-picker end-to-end (sanity)

Purpose: confirm Fixes A+B don't regress the normal pick → QA → package flow.

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create one PICK_PACK sales order for the hot SKU, quantity 1. | Order created. |
| 2 | Release to picking; operator logs into mobile UI, starts picking order, scans tote `T-DEVQA-1`. | First-pick path: new tote created (line 355–367 branch), `T-DEVQA-1.storagelocation` = emptyTotes initially. |
| 3 | Confirm pick. | **HTTP 200.** Mobile shows "Pick complete." |
| 4 | SQL verify the customer order | `SELECT id, state, pickingtote_id, pickingconfirmationsent FROM customerorder WHERE number = :ordNum;` | `state = 600 (PICKED)`, `pickingtote_id` = unitload id of `T-DEVQA-1` (NOT NULL), `pickingconfirmationsent = true`. |
| 5 | Trigger OMS QA → `packageOrder` on that order (via OMS UI, or `POST /mobile-shipping/packageOrder?orderNumber=:num`). | **HTTP 200.** Order transitions to `PACKED (650)`; `pickingtote_id` becomes NULL (legitimate clear by `packageOrder:470`). |
| 6 | Log tail for steps 2–5 | `grep -E 'still bound\|not empty\|not on empty'` | **0 matches** on the happy path. |

### 11.3 Scenario B — THE production bug reproduction (PRIMARY regression test)

Purpose: reproduce the exact production incident. Before the fix this silently nulls the victim order's `pickingtote_id`; after the fix it refuses the scan with a clear error and leaves the victim intact.

**Setup:**

1. Complete a full pick on **Order A**. End state: `A.state = 600`, `A.pickingtote_id = T1 (unitload id for T-DEVQA-1)`, `A.pickingconfirmationsent = true`. `T-DEVQA-1` is sitting wherever the picker left it — e.g., on `FinishedPicking` or on the operator's cart — and the tote still physically holds Order A's stockunit(s) (i.e., `stockunit.unitload_id = T1` for A's picked stock).
2. Baseline capture:
   ```sql
   SELECT id, state, pickingtote_id, pickingconfirmationsent
   FROM customerorder WHERE number = :A_num;
   -- expect: state=600, pickingtote_id=T1_unitload_id, pickingconfirmationsent=true
   ```
3. Create & release **Order C** for the same SKU, quantity 1. Identify its `pickingorder_position.id = POS_C`.
4. Log into mobile UI as a **different picker**. Start Order C's picking order. Reach the tote-scan prompt.

**Execution:**

| Step | Action | Expected (post-fix) | Pre-fix behavior (for contrast) |
|------|--------|---------------------|---------------------------------|
| 1 | Picker C scans tote label `T-DEVQA-1` at the first-pick prompt | **`BusinessException` — HTTP 4xx.** Mobile shows an error like `"T-DEVQA-1 is still bound to order <A_num> (state=600)"`. | Depends on T1's current location / emptiness. If not on emptyTotes **or** not empty, a different error is shown; either way, pre-fix silently nulls A.pickingtote_id before throwing. |
| 2 | **Re-read Order A immediately after step 1 fails** | `SELECT pickingtote_id, pickingconfirmationsent FROM customerorder WHERE number=:A_num;` → `pickingtote_id` **UNCHANGED** (still = T1_unitload_id), `pickingconfirmationsent` **UNCHANGED** (still true). | `pickingtote_id` = **NULL** (the bug). |
| 3 | Log check during step 1 | `grep 'still bound to order' /var/log/wms-api/*.log \| tail` | Single line naming order A and state 600. Absence of any `UPDATE customerorder SET pickingtote_id=NULL WHERE id=<A_id>` SQL (see step 4). |
| 4 | Hibernate SQL log for step 1 (requires `logging.level.org.hibernate.SQL=DEBUG` or `spring.jpa.show-sql=true` on dev) | `grep -E 'update customerorder.*pickingtote_id' /var/log/wms-api/*.log \| tail` | **NO row** updating A.pickingtote_id to NULL. (If seen, the fix is not active — re-run §11.1 step 1.) |
| 5 | Complete Order A's OMS QA → `packageOrder` | `POST /mobile-shipping/packageOrder?orderNumber=:A_num` | **HTTP 200.** Order A transitions PICKED → PACKED cleanly. (Pre-fix: this call throws `"Cannot package order=<A> without an assigned picking tote"` because step 1 nulled the FK.) |

**Success criterion for this scenario:** Order A's `pickingtote_id` survives step 1–4, and step 5 packages cleanly. **Repeat this scenario at least 5 times** with fresh A/C order pairs to defend against timing flukes.

**Diagnostic query — "has any recent pick attempt silently orphaned a PICKED order":**

```sql
SELECT id, number, state, pickingtote_id, pickingconfirmationsent, modified
FROM customerorder
WHERE state = 600                         -- PICKED
  AND pickingtote_id IS NULL              -- but no tote!
  AND pickingconfirmationsent = true      -- OMS was notified — the contradiction
  AND modified > now() - interval '1 hour'
ORDER BY modified DESC;
-- Post-fix: 0 rows. Pre-fix: every triggered bug appears here.
```

### 11.4 Scenario C — FINISHED-order orphan cleanup still works (legitimate-path smoke)

Purpose: Fix A tightens the state guard. Make sure the *legitimate* orphan-cleanup path still fires when it should (an order that truly finished, tote is genuinely clean, but the FK wasn't nulled upstream for whatever reason).

**Setup (requires one manual DB poke to simulate the orphan):**

1. Pick Order D fully → PACKED → PALLETIZED → FINISHED (state=700). After normal flow, `D.pickingtote_id = NULL` already. Note the tote `T-DEVQA-2` labelid.
2. **Simulate an upstream orphan** — manually re-set the orphan FK on dev only:
   ```sql
   UPDATE customerorder
      SET pickingtote_id = (SELECT id FROM unitload WHERE labelid = 'T-DEVQA-2')
    WHERE number = :D_num;
   ```
   (In production this rare case arises from a pre-fix race, cancellation-without-cleanup, or manual admin poke. Forcing it on dev is the only way to exercise the cleanup path.)
3. Ensure `T-DEVQA-2` is on emptyTotes and its stockunit list is empty:
   ```sql
   SELECT id, storagelocation_id FROM unitload WHERE labelid = 'T-DEVQA-2';
   SELECT COUNT(*) FROM stockunit WHERE unitload_id = (SELECT id FROM unitload WHERE labelid='T-DEVQA-2');
   -- storagelocation = emptyTotes id; stockunit count = 0
   ```
4. Create Order E for the hot SKU; release to picking; start picking order on mobile.

**Execution:**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Scan `T-DEVQA-2` at the first-pick prompt | **HTTP 200.** First-pick succeeds. |
| 2 | Re-read Order D | `SELECT pickingtote_id FROM customerorder WHERE number = :D_num;` → NULL (orphan cleaned). |
| 3 | Re-read Order E | `SELECT state, pickingtote_id FROM customerorder WHERE number = :E_num;` → `state = 500 or 600`, `pickingtote_id = T-DEVQA-2 unitload_id`. |
| 4 | Log check | `grep 'clearing stale reference from finished order' /var/log/wms-api/*.log` | One match naming order D. |

### 11.5 Scenario D — Validation-before-write (wrong location)

Purpose: prove the reordered else-branch **refuses the scan before touching any owner's FK** when the tote is in the wrong place.

**Setup:** Pick Order F fully → `F.state=600`, `F.pickingtote_id = T3 (T-DEVQA-3)`. Physically / logically move T3 off `emptyTotes` — e.g., transfer it to a staging lane. (Or pick any tote known to currently reside outside emptyTotes.)

**Execution:**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Pre-scan snapshot | `SELECT pickingtote_id FROM customerorder WHERE number = :F_num;` → T3 unitload_id. |
| 2 | Start a new pick on Order G; scan `T-DEVQA-3` | **HTTP 4xx** with message `"T-DEVQA-3 not on empty totes location but <location>"`. |
| 3 | Post-scan snapshot | `SELECT pickingtote_id FROM customerorder WHERE number = :F_num;` → **UNCHANGED** (still T3 unitload_id). |
| 4 | SQL log check | `grep -E 'update customerorder.*pickingtote_id.*WHERE id=<F_id>' /var/log/wms-api/*.log` | **No update row**. |

### 11.6 Scenario E — Validation-before-write (non-empty tote)

Purpose: same principle, different validation branch.

**Setup:** Pick Order H fully → `H.state=600`, `H.pickingtote_id = T4 (T-DEVQA-4)`. T4 is on emptyTotes **but** still has H's stock on it (this is the exact production shape — tote on operator cart is conceptually "on emptyTotes" in some tenant configs but stockunits remain).

**Execution:**

| Step | Action | Expected |
|------|--------|----------|
| 1 | Pre-scan snapshot on Order H | `pickingtote_id` = T4 unitload_id. |
| 2 | Start a new pick on Order J; scan `T-DEVQA-4` | **HTTP 4xx** with message `"T-DEVQA-4 not empty!"`. |
| 3 | Post-scan snapshot | Order H `pickingtote_id` **UNCHANGED**. |
| 4 | SQL log check | No `update customerorder` for H. |

### 11.7 Scenario F — `rollbackFor` behavior (defense-in-depth check)

Purpose: verify that *if* the cleanup save (legit FINISHED path) is followed by a thrown `BusinessException` later in `processPick`, the cleanup is rolled back. Hard to induce on a running dev server without code tweaks — primary coverage is the unit test `processPick_existingToteOwnedByFinishedOrder_clearsAndContinuesWithNewAssignment` combined with a negative-path test. Skip on dev unless a specific test hook is available.

> Optional: if you have DB admin access, force a post-cleanup failure by taking the `pickingorder_position` FK offline mid-request (e.g., `BEGIN; LOCK TABLE pickingorder_position; ...`), then trigger a pick. You'd see the cleanup roll back. Typically not worth the blast radius on dev.

### 11.8 End-to-end OMS QA smoke (golden path must still work)

Purpose: confirm that OMS's full QA → `packageOrder` → parcelize → ship sequence works on a freshly picked order.

| Step | Action | Expected |
|------|--------|----------|
| 1 | Pick a fresh PICK_PACK Order K end-to-end. | Order K at PICKED with valid `pickingtote_id`. |
| 2 | OMS `customerOrderPicked` notification | Fired `afterCommit` — check WMS outgoing-message table or OMS inbound queue. |
| 3 | OMS triggers `packageOrder(K.number)` | WMS `CustomerorderService.packageOrder` succeeds; K transitions to PACKED (650); `pickingtote_id` legitimately becomes NULL. |
| 4 | Verify parcel & BOL downstream | Normal palletize / BOL / shipment closure flow runs. |

### 11.9 Log & metric monitoring (run during and after scenarios)

| Signal | How to check | Pass criterion |
|--------|--------------|----------------|
| New "still bound" rejections | `grep -c 'still bound to' /var/log/wms-api/*.log` over the test window | > 0 during Scenario B (proves the new path fires); 0 during happy-path scenarios. |
| Silent pickingtote_id nullings | Diagnostic query from §11.3 step B-end | **0 rows** post-test. |
| `packageOrder` pre-condition failures | `grep 'Cannot package order.*without an assigned picking tote' /var/log/wms-api/*.log` | **0** across the test window. |
| `processPick` HTTP 500 (vs expected 4xx) | Nginx/access log: `awk '$9 ~ /^5/' \| grep processPick` | **0**. The new error path should return 4xx (`BusinessException` → `RestExceptionHandler` maps to 422 or 409), not 500. Confirm the HTTP code class once in Scenario B. |
| `finishPickingOrder` OMS call failures | `grep 'customerOrderPicked\|OMS' /var/log/wms-api/*.log` (or your OMS outgoing queue) | Unchanged from pre-deploy baseline. |
| Picking latency | Grafana / actuator `/metrics` for `processPick` p95 | Within ±10% of pre-deploy baseline. The reorder adds two extra queries in the throw path only. |

### 11.10 Exit criteria (verification PASSED when all are true)

- Scenarios A, B (≥ 5 iterations), C, D, E all pass with the expected assertions.
- Scenario B's SQL diagnostic (§11.3 end) returns **0 rows** after the run.
- Scenario A's OMS `packageOrder` call returns HTTP 200 end-to-end.
- Zero `"Cannot package order … without an assigned picking tote"` log lines post-deploy.
- Picking latency p95 unchanged (±10%).
- New error message `"is still bound to order"` appears **only** when Scenario B is triggered — not on the happy path.

If any criterion fails: capture the SQL snapshot, the log excerpt, and the mobile client's request body; reopen the plan with a §14 follow-up. Do not promote to staging/prod.

### 11.11 Rollback trigger

If Scenario B reproduces the silent-null on dev — i.e., Order A's `pickingtote_id` becomes NULL after a refused tote-scan — roll back `release-hotfix-260422` to the previous `release` artifact. That restores the original known bug (rare pre-`7cf29a9` "belongs to different order" error) while the fix is re-examined. Safer than leaving a half-working fix that masks but doesn't resolve the data-integrity issue.

---

## 12. Notes

### Cross-reference with the morning's SBDEV-1710 follow-up

This is the second incident this week traced to checked-exception / TX-attribute mismatch in v1/wms-api. The first (`2351004`, `StockunitBusinessService.changeReservedAmount`) was a Hibernate L1-cache mismatch under contention. This one is a Spring TX-attribute mismatch under operator error. Both involve `processPick` as the entry point; both surface as "data is wrong but the request returned a 'success-ish' looking error".

### Follow-up tickets to file

1. **Audit `@Transactional` declarations in v1/wms-api for missing `rollbackFor`.** Grep `@Transactional\b(?!\(.*rollbackFor)` in the service layer; flag any method that throws `BusinessException` or `FacadeException`. Likely list includes anything still using bare `@Transactional`.
2. **Reconsider whether `BusinessException` should extend `RuntimeException`.** Would close the entire defect class but is a significant API contract change; needs a separate scoped review.
3. **Fix or delete `rapidPickingConnectPackageAndType` and `rapidPickingScanPackageAndType`** — see §13 below. Same defect family but worse (no `@Transactional` at all, synchronous OMS call mid-write-sequence). Currently dead code (only callsite is commented out in `PickingController`), but the methods are `public` and remain on the service surface.
4. **Consider deprecating the `>= PICKED` shorthand for "done".** Multiple sites in this codebase conflate "picking done" with "order done"; this is the second time it's caused a production data issue (SBDEV-2102 §11 was the first).

---

## 13. Adjacent-defect scan: `rapidPickingConnectPackageAndType` and `rapidPickingScanPackageAndType`

**Scope of this section:** Asked to verify whether `rapidPickingConnectPackageAndType` (`MobilePickingService.java:769`) — which is **not `@Transactional` at all** — has the same defect class as the main bug. Findings inform the follow-up ticket above; **no code change is proposed inside this hotfix**, but the analysis is captured here so a reviewer doesn't have to re-derive it.

### Reachability

| Caller | File:Line | Status |
|---|---|---|
| `rapidPickingScanPackageAndType` | `MobilePickingService.java:845` | Live in source (calls `rapidPickingConnectPackageAndType`); itself only reachable via the next row |
| `processRapidPickScanPackageType` controller endpoint | `PickingController.java:78–115` | **Commented out** — entire `@PostMapping` block is dead in source |
| Any other controller / REST / test / reflective call | _searched_ | None found |

**Verdict:** the connect-method is **currently unreachable through the HTTP surface**. It is `public` and lives in a `@Service` bean, so a future controller, test, or reflective caller could pick it up. The analysis below treats it as if it were live.

### Defects observed

#### D1 — No `@Transactional` at all on a method that performs 6 distinct writes

Method body writes, in order:

| # | Line | Operation |
|---|---|---|
| 1 | 816 | `unitloadRepository.save(tote)` — persists the newly-created tote with `boxtypeId` set |
| 2 | 820 | `pickingorderUnitloadRepository.save(pickingUnitLoad)` — links picking order ↔ tote |
| 3 | 824 | `customerorderRepository.save(customerOrder)` — sets `pickingtoteId` + `historytote` |
| 4 | 826 | `manageOrderService.customerOrderToteAssigned(...)` — **synchronous** OMS HTTP call |
| 5 | 831 | per-position `pickingorderPositionRepository.save(pickPos)` — sets `picktounitloadId` (loop, N writes) |
| 6 | 836 | `pickingorderRepository.save(pickingOrder)` — sets `state = STARTED` |

Without an outer `@Transactional`, Spring Data JPA's repository proxy creates a new transaction per `save()` call (default `SimpleJpaRepository` behavior is `@Transactional` per method). Each of the 6 writes commits independently. Any failure between writes leaves a **partially-built state across five tables** with no rollback.

This is strictly worse than the main bug: there, at least the writes were grouped in one (mis-configured) TX; here, every write is an independent TX.

#### D2 — Synchronous OMS notification interleaved between writes (worse than `processPick`'s pattern)

`processPick` registers `customerOrderToteAssigned` as an `afterCommit` synchronization (line 427–438), so the OMS call only fires once the WMS-side TX has committed *and* it never blocks the local writes.

`rapidPickingConnectPackageAndType` calls `manageOrderService.customerOrderToteAssigned(...)` **synchronously** at line 826, **between** the customerOrder save and the pickingPosition loop. Two failure modes:

- **OMS call fails (HTTP timeout, network error, exception).** The first three saves are committed; the loop and final pickingOrder save never run. Final state: customerOrder has a `pickingtoteId` pointing at a tote, the pickingorder_unitload exists, but pickingorder_position rows are unset and the picking order is not STARTED. The picker cannot scan-pick because their pickingorder is in an inconsistent state.
- **OMS call succeeds, then the loop or final save throws.** OMS now believes the tote is assigned to the customer order; WMS persists the same belief partially (customerOrder + pickingorder_unitload), but pickingorder + pickingorder_position are unsynchronized.

#### D3 — `findByHistorytote` early-throw rejects legitimately reusable totes

Lines 786–794 reject any pre-existing tote whose label appears in `customerorder.historytote`. But `historytote` is a *historical* breadcrumb set when a tote is unbound — e.g., `CustomerorderService.packageOrder` at line 469 sets it on the order being packaged. So a tote that was used by Order X (now PACKED/PALLETIZED/FINISHED) and freed correctly will still have its label preserved in `X.historytote`, and this method will permanently refuse to reuse the tote with "FAILURE: LPN ... already associated to parcel ...". This is a different defect from the main bug, but in the same "treats post-PICKED as terminal-but-not-clear" family.

#### D4 — Caller `rapidPickingScanPackageAndType` is also non-transactional and adds two more writes

`rapidPickingScanPackageAndType` (line 842):

```java
public PickingorderPosition rapidPickingScanPackageAndType(...) throws BusinessException {
    Pickingorder pickingOrder = rapidPickingConnectPackageAndType(...);  // 6 independent TXs above
    if (pickingOrder == null) return null;

    MywmsUser user = mywmsUserRepository.findByName(SecurityContextUtils.getUserName()).get();  // can throw NoSuchElementException
    pickingOrder.setOperatorId(user.getId());
    pickingOrder.setLockedtooperator(true);
    pickingorderRepository.save(pickingOrder);  // 7th independent TX

    PickingorderPosition pickingPosition = pickingorderPositionRepository.findByPickingorderId(...).get(0);  // can throw IndexOutOfBoundsException
    return pickingPosition;
}
```

Two additional unguarded failure points:

- `mywmsUserRepository.findByName(...).get()` (no user found → `NoSuchElementException` → uncaught → returns 500 to client; the connect-method's 6 commits stick)
- `findByPickingorderId(...).get(0)` (no positions → `IndexOutOfBoundsException` → same)

Same defect class as SBDEV-2116's "unguarded `Optional.get()`" inventory; this caller belongs in that ticket too.

### Comparison table — defect family

| Aspect | `processPick` (this plan, fixed by A+B) | `rapidPickingConnectPackageAndType` |
|---|---|---|
| `@Transactional` | Yes, but bare (no `rollbackFor`) | **None** |
| Atomicity of writes | One TX (commits despite checked-throw) | One independent TX per `save()` — no atomicity at all |
| OMS notification timing | `afterCommit` (registered, deferred, swallowed errors) | **Synchronous, mid-write-sequence** |
| Write-before-validate ordering bug | Yes (else-branch cleanup before checks) | No checks performed mid-write — but each write is independent so order doesn't help |
| Currently reachable via HTTP | **Yes** — production hot path | **No** — only callsite commented out in `PickingController:78` |
| Severity if invoked | **High** (this is the production incident) | **Critical if re-enabled**; harmless while dormant |

### Recommendation (for the follow-up ticket, not this hotfix)

Two acceptable options, in increasing order of effort:

**Option 1 (cheap, 1-line):** annotate both methods with `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})`. This wraps all six writes plus the OMS call in a single TX. Throws roll back. The synchronous OMS call would then need to be moved into an `afterCommit` synchronization (mirroring the pattern at `processPick:427–438`) to avoid mixed local-DB-and-remote-IO inside the transaction.

**Option 2 (correct, larger):** delete both methods if no production tenant uses the rapid pick-pack flow — the only HTTP entry point has been commented out for some time. If retained for a future re-enable, refactor the OMS notification onto an `afterCommit` synchronization, fix the `findByHistorytote` rejection logic to consider order state, and replace the unguarded `.get()` calls with `.orElseThrow(BusinessException...)`.

**This hotfix should NOT touch these methods.** Risk/reward is wrong: they're dormant in source; changing them ships a behavior change with no production validation path. File the follow-up ticket and address it under SBDEV-2116's umbrella or its own ticket.

### What to grep for during the follow-up

Other service methods in this repo follow the same anti-pattern. To enumerate them in one pass:

```bash
# Public service methods that throw BusinessException/FacadeException
# without a @Transactional declaration anywhere on the method or class:
grep -rnE "public .* throws .*(Business|Facade)Exception" v1/wms-api/src/main/java/net/aim_ai/wms/service/ \
  | while read line; do
      file=$(echo "$line" | cut -d: -f1)
      lineno=$(echo "$line" | cut -d: -f2)
      # Look 3 lines above for @Transactional (method-level) and at the class top
      head -n "$lineno" "$file" | tail -n 5 | grep -q "@Transactional" || \
        head -n 30 "$file" | grep -q "^@Transactional" || \
        echo "$file:$lineno NEEDS REVIEW"
  done
```

Result of that scan goes into the SBDEV-2116-adjacent ticket.
