# Order 241019 Cancellation Failure - Analysis & Fix Plan

**Date**: 2026-03-23 (Updated after augment review)
**Branch**: release (code as of pre-March 1st 2026, commit `1836861`)
**Reported Issue**: Order with `clientordernumber = '241019'` cannot be cancelled. OMS displays "The order was NOT cancelled successfully!"

---

## Current State of the Order

| Entity | State | Value | Expected | Issue |
|--------|-------|-------|----------|-------|
| Customerorder | PICKED | 600 | Correct | - |
| CustomerorderPosition | PICKED | 600 | Correct | - |
| Pickingorder | PROCESSABLE | 300 | Should be PICKED(600) or FINISHED(700) | **Inconsistent** |
| PickingorderPosition | PICKED | 600 | Correct | Blocks cancellation |

**The picking order is in an inconsistent state.** Its positions are PICKED (600) but the picking order itself is PROCESSABLE (300). This should never happen — if positions are picked, the picking order should be at least PICKED or FINISHED.

---

## Root Cause Analysis

### Direct Blocker: `pickingorder_position = 600`

In `CustomerorderPositionService.canOrderPositionBeCancelled()` (regular picking path):

```java
if (pickingPosition.getState() >= RESERVED && pickingPosition.getState() < FINISHED) {
    // 600 >= 400 && 600 < 700? YES — RETURNS FALSE
    return false;
}
```

PICKED (600) falls in the blocking range [RESERVED(400), FINISHED(700)). The picking order at 300 is NOT the direct blocker — it's the **evidence** of the broken completion path.

### Why the Inconsistent State Occurred: Race in `confirmPick()`

**Validated against release branch code.** `PickingorderBusinessService.confirmPick()` (line 187) has a concurrent completion race:

1. **Parent reads are unlocked**: Uses `pickingorderRepository.findById()` (line 211) and `customerorderRepository.findById()` (line 282) — NOT `findByIdForUpdate()`
2. **Completion check uses stale reads**: Lines 331-338 check `allPicksDone` via `findByPickingorderId()` without locking the parent pickingorder row
3. **Lock primitives exist but are unused**: `CustomerorderRepository.findByIdForUpdate()` (line 168) and `PickingorderRepository.findByIdForUpdate()` (line 141) exist in the pinned code but are not called in `confirmPick()`

**Race mechanism:**
- Transaction A: confirms pick for position 1 → sets it to PICKED → reads siblings → sees position 2 NOT yet PICKED (tx B uncommitted) → doesn't promote parent pickingorder
- Transaction B: confirms pick for position 2 → sets it to PICKED → reads siblings → sees position 1 NOT yet PICKED (tx A uncommitted) → doesn't promote parent pickingorder
- Both commit → all positions are PICKED but the parent `pickingorder` stays at PROCESSABLE (300) or STARTED (500)

The customer order side can still advance to PICKED independently because its completion check at lines 295-319 may see the committed position states from an earlier statement in the same transaction.

### Why Setting Picking Positions Back to 300 Also Failed

`cancelOrderPosition()` contains a stock release branch:
```java
if (pickingPosition.getState() < RESERVED) {  // 300 < 400? YES — enters
    Stockunit stockUnit = stockunitRepository.findById(pickingPosition.getPickfromstockunitId()).get();
    stockunitBusinessService.changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(), ...);
}
```

This is wrong for already-picked stock because:
- `pickfromstockunitId` is set to **null** during `confirmPick()` (line 260: `pickingPosition.setPickfromstockunitId(null)`)
- Calling `findById(null)` throws `IllegalArgumentException`
- Even if it weren't null, the reservation was already consumed during picking

### Why `cleanUpCancelledOrder()` Fails (First Attempt)

When `canOrderPositionBeCancelled` returns false and `pickingConfirmationSent = true`:
- `cleanUpCancelledOrder()` is called
- It calls `unitloadBusinessService.sendToClearing(tote, ...)` which may throw `FacadeException` or `BusinessException` if the tote is in an unexpected state (locked, already moved, etc.)
- This exception propagates to the controller → HTTP 400 → OMS shows "The order was NOT cancelled successfully!"

---

## Fix Plan

### Part 1: One-Time Production Repair SQL (Immediate — fixes order 241019)

The repair must handle tote cleanup in addition to state normalization. Simply setting picking rows to FINISHED(700) is **insufficient** because the `cancelOrder` success path has NO tote cleanup — that only exists in the `cleanUpCancelledOrder()` fallback path.

#### Pre-checks

**Step 1 — Identify the exact order row:**
```sql
SELECT co.id,
       co."number" AS wms_order_number,
       co.clientordernumber,
       co.state,
       co.pickingtote_id,
       co.historytote,
       co.pickingconfirmationsent,
       co.markedforcancellation
FROM customerorder co
WHERE co.clientordernumber = '241019'
ORDER BY co.id;
```
Proceed only if this returns exactly one row.

**Step 2 — Inspect all related picking rows** (replace `123456` with actual `customerorder.id`):
```sql
SELECT cop.id AS cop_id, cop.state AS cop_state,
       pop.id AS pop_id, pop.state AS pop_state,
       po.id AS po_id, po."number" AS po_number, po.state AS po_state
FROM customerorder_position cop
LEFT JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
LEFT JOIN pickingorder po ON po.id = pop.pickingorder_id
WHERE cop.order_id = 123456
ORDER BY cop.id, pop.id;
```

**Step 3 — Inspect tote and pickingorder_unitload linkage:**
```sql
SELECT ul.id, ul.labelid, ul.storagelocation_id, loc.name AS location_name,
       ul.carrierunitload_id, ul.entity_lock,
       COALESCE(su.stock_count, 0) AS stock_count,
       COALESCE(child.child_ul_count, 0) AS child_ul_count
FROM customerorder co
JOIN unitload ul ON ul.id = co.pickingtote_id
LEFT JOIN location loc ON loc.id = ul.storagelocation_id
LEFT JOIN (SELECT unitload_id, count(*) AS stock_count FROM stockunit GROUP BY unitload_id) su ON su.unitload_id = ul.id
LEFT JOIN (SELECT carrierunitload_id, count(*) AS child_ul_count FROM unitload WHERE carrierunitload_id IS NOT NULL GROUP BY carrierunitload_id) child ON child.carrierunitload_id = ul.id
WHERE co.id = 123456;

SELECT pul.id, pul.pickingorder_id, pul.unitload_id, pul.state,
       pul.customerordernumber, pul.historytote
FROM pickingorder_unitload pul
WHERE pul.pickingorder_id IN (
    SELECT DISTINCT pop.pickingorder_id
    FROM customerorder_position cop
    JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
    WHERE cop.order_id = 123456 AND pop.pickingorder_id IS NOT NULL
)
ORDER BY pul.id;
```

#### Preconditions

Use the repair only if ALL of these are true:
- The exact target `customerorder.id` is known
- `customerorder.state = 600`
- All related `customerorder_position` rows are `600`
- Related `pickingorder_position` rows are `600` or were previously manually changed to `300`
- Related `pickingorder` rows are below `700`
- The tote exists
- The tote has **no child unitloads** (`child_ul_count = 0`)

If the tote still carries child unitloads, stop and inspect manually.

#### Repair Transaction

```sql
BEGIN;

DO $$
DECLARE
    v_order_id bigint := 123456; -- replace with the exact customerorder.id
    v_tote_id bigint;
    v_tote_label varchar(255);
    v_wms_order_number varchar(255);
    v_clearing_id bigint;
BEGIN
    SELECT co.pickingtote_id, co."number"
      INTO v_tote_id, v_wms_order_number
    FROM customerorder co
    WHERE co.id = v_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'customerorder.id % not found', v_order_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM customerorder co
        WHERE co.id = v_order_id AND co.state <> 600
    ) THEN
        RAISE EXCEPTION 'customerorder.id % is not in state 600', v_order_id;
    END IF;

    IF v_tote_id IS NULL THEN
        RAISE EXCEPTION 'customerorder.id % has no pickingtote_id', v_order_id;
    END IF;

    SELECT ul.labelid INTO v_tote_label
    FROM unitload ul WHERE ul.id = v_tote_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'unitload.id % not found', v_tote_id;
    END IF;

    SELECT l.id INTO v_clearing_id
    FROM location l WHERE l.name = 'Clearing';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'location.name = Clearing not found';
    END IF;

    IF EXISTS (
        SELECT 1 FROM unitload child WHERE child.carrierunitload_id = v_tote_id
    ) THEN
        RAISE EXCEPTION 'tote unitload.id % still has child unitloads; inspect manually', v_tote_id;
    END IF;

    -- 1) Unlock stock on the tote
    UPDATE stockunit su
    SET entity_lock = 0
    WHERE su.unitload_id = v_tote_id
      AND COALESCE(su.entity_lock, 0) <> 0;

    -- 2) Move tote to Clearing and remove carrier relationship
    UPDATE unitload ul
    SET storagelocation_id = v_clearing_id,
        carrierunitload_id = NULL,
        entity_lock = 0
    WHERE ul.id = v_tote_id;

    -- 3) Detach/cancel related pickingorder_unitload rows
    UPDATE pickingorder_unitload pul
    SET historytote = COALESCE(pul.historytote, v_tote_label),
        unitload_id = NULL,
        state = 800
    WHERE pul.pickingorder_id IN (
        SELECT DISTINCT pop.pickingorder_id
        FROM customerorder_position cop
        JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
        WHERE cop.order_id = v_order_id AND pop.pickingorder_id IS NOT NULL
    )
      AND (pul.unitload_id = v_tote_id
           OR pul.customerordernumber = v_wms_order_number
           OR pul.historytote = v_tote_label);

    -- 4) Preserve tote history on order, clear live tote link
    UPDATE customerorder co
    SET historytote = COALESCE(co.historytote, v_tote_label),
        pickingtote_id = NULL,
        markedforcancellation = FALSE
    WHERE co.id = v_order_id;

    -- 5) Normalize picking positions to FINISHED (700)
    UPDATE pickingorder_position pop
    SET state = 700
    WHERE pop.customerorderposition_id IN (
        SELECT cop.id FROM customerorder_position cop WHERE cop.order_id = v_order_id
    )
      AND pop.state NOT IN (700, 800);

    -- 6) Normalize picking orders to FINISHED (700)
    UPDATE pickingorder po
    SET state = 700
    WHERE po.id IN (
        SELECT DISTINCT pop.pickingorder_id
        FROM customerorder_position cop
        JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
        WHERE cop.order_id = v_order_id AND pop.pickingorder_id IS NOT NULL
    )
      AND po.state NOT IN (700, 800);
END $$;

COMMIT;
```

After running, retry cancellation from OMS. Expected flow:
1. `canOrderPositionBeCancelled` → picking positions at 700, NOT in [400,700) → returns **true**
2. `cancelOrderPosition` → stock release: 700 < 400? NO → **skipped** (correct)
3. Order and positions set to CANCELED (800)

#### Post-repair verification
```sql
SELECT co.id, co."number", co.state, co.pickingtote_id, co.historytote
FROM customerorder co WHERE co.id = 123456;

SELECT cop.id, cop.state FROM customerorder_position cop WHERE cop.order_id = 123456;

SELECT po.id, po."number", po.state FROM pickingorder po
WHERE po.id IN (
    SELECT DISTINCT pop.pickingorder_id
    FROM customerorder_position cop
    JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
    WHERE cop.order_id = 123456
);
```

**Caveat:** This SQL repair bypasses service-layer movement/audit record creation. It is a targeted one-time fix, not a normal operational recovery process.

### Part 2: Permanent Code Fix (Prevents Recurrence)

#### Fix 1 — Lock parent rows in `confirmPick()` -- IMPLEMENTED

**Status**: DONE
**File**: `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`

Changes made:
1. **Method entry** (before line 237): Added early lock acquisition — resolves `CustomerorderPosition` to get the owning `Customerorder`, then locks both parents in order:
   - `customerorderRepository.findByIdForUpdate(copForLock.getOrderId())` — locks Customerorder first (3rd in lock order)
   - `pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())` — locks Pickingorder second (5th in lock order)
2. **Customer order read** (line ~313): Changed `customerorderRepository.findById(...)` to `customerorderRepository.findByIdForUpdate(...)` — reads the already-locked row with fresh state
3. **Fresh order re-read** (line ~353): Changed `customerorderRepository.findById(...)` to `customerorderRepository.findByIdForUpdate(...)` — ensures the completion check sees committed sibling states

#### Fix 2 — Recompute parent state from fresh post-update reads -- IMPLEMENTED

**Status**: DONE (included in Fix 1)

The existing sibling queries (`findByOrderId`, `findByPickingorderId`) now execute under the parent row lock, ensuring they see all committed sibling state changes before computing parent promotion.

#### Fix 3 — Optional: Extend admin recovery endpoint -- DEFERRED

**Status**: DEFERRED (separate task)

`GET /v3/adminAction/finishStuckPickingOrder/{number}` currently only accepts picking orders already in state PICKED. Extending to allow recovery of stuck orders with `state < PICKED` is a separate improvement.

#### Fix 4 — Regression tests -- IMPLEMENTED

**Status**: DONE
**File**: `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java`

Updated 4 existing `confirmPick` tests to use `findByIdForUpdate` mocks:
- `confirmPick_noOrder_throwsFacadeException` — verifies locked read for missing order
- `confirmPick_wrongUnitLoadOrder_throwsFacadeException` — verifies locked read with wrong UL
- `confirmPick_validPick_setsPickedState` — verifies last-pick promotes parent under lock
- `confirmPick_partialPick_setsStartedState` — verifies partial pick doesn't over-promote

All 23 tests pass (16 existing + 7 from Transfer fix).

### Part 3: Detection SQL for Other Affected Orders

```sql
SELECT co.id, co."number" AS customerorder_number, co.clientordernumber,
       co.state AS customerorder_state
FROM customerorder co
WHERE co.state = 600
  AND NOT EXISTS (
      SELECT 1 FROM customerorder_position cop
      WHERE cop.order_id = co.id AND cop.state <> 600
  )
  AND EXISTS (
      SELECT 1
      FROM customerorder_position cop
      JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
      JOIN pickingorder po ON po.id = pop.pickingorder_id
      WHERE cop.order_id = co.id AND po.state < 600
  )
ORDER BY co.id;
```

---

## Implementation Priority

| Priority | Fix | Type | Status | Impact |
|----------|-----|------|--------|--------|
| 1 | Run pre-check queries (Part 1) | Manual/SQL | PENDING | Confirms exact state |
| 2 | Run repair transaction (Part 1) | SQL | PENDING | Unblocks order 241019 cancellation |
| 3 | Run detection query (Part 3) | SQL | PENDING | Find other affected orders |
| 4 | Lock parent rows in confirmPick (Part 2, Fix 1+2) | Code | **DONE** | Prevents recurrence |
| 5 | Regression tests (Part 2, Fix 4) | Code | **DONE** | Validates fix |
| 6 | Extend admin endpoint (Part 2, Fix 3) | Code | DEFERRED | Operational recovery option |

---

## What NOT to Do

- **Do NOT** reset picked picking positions back to 300 — this drives the wrong stock-release path and can cause `NullPointerException` (pickfromstockunitId is already null)
- **Do NOT** only set picking rows to 700 without tote cleanup — the `cancelOrder` success path has no tote cleanup, leaving `pickingtote_id`, stock locks, and `pickingorder_unitload` dirty
- **Do NOT** use this SQL repair as the normal operational recovery process — it bypasses service-layer audit/movement records
