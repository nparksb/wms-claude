# Order 241019 Cancellation Failure — Real Fix Plan (Augment)

**Date:** 2026-03-23  
**Pinned codebase:** `release` branch as of `1836861a28b4eb25a6dd51f1c4caf5d0eb21717a` (`2026-02-27`, tag `v1.26.10`)  
**Scope:** explain the failure using only the pre-2026-03-01 `release` code, define the permanent code fix, and provide PostgreSQL-safe one-time repair SQL for the already-bad data.

---

## Executive summary

The reported state is:

| Entity | Observed state | Meaning |
|---|---:|---|
| `customerorder` | `600` | picked |
| `customerorder_position` | `600` | picked |
| `pickingorder` | `300` | processable |
| `pickingorder_position` | `600` | picked |

That combination is invalid.

### What is actually broken

1. **OMS cancellation is blocked directly by `pickingorder_position = 600`**, not by `pickingorder = 300`.
2. **Changing picked positions back to `300` is unsafe** because `cancelOrderPosition()` then tries to release source reservations for stock that has already been picked.
3. The **most likely real code bug** is in `PickingorderBusinessService.confirmPick()`:
   - it computes both `customerorder` completion and `pickingorder` completion from **non-locked aggregate reads**,
   - even though pessimistic-lock repository methods already exist,
   - so concurrent “last pick” confirmations can leave child rows at `600` while the parent `pickingorder` never advances.

### Recommended fix shape

- **Permanent code fix:** serialize completion updates in `confirmPick()` by locking the affected `Customerorder` and `Pickingorder` rows, then recomputing parent states from fresh in-transaction reads.
- **Immediate production repair:** use the one-time SQL in this doc to clean tote/unitload links and normalize the inconsistent picking rows so OMS cancel can complete safely.
- **No Flyway schema change is required.** This is a service-layer/state-transition bug, not a schema bug.

---

## What I validated in the pinned release code

### 1) OMS cancel enters `CustomerorderService.cancelOrder()`

- `OrderRestController.cancelPositions()` resolves the `Customerorder` and calls:
  - `customerorderService.cancelOrder(customerOrder, false)`

### 2) The order-level hard guards do **not** reject state `600`

- `CustomerorderService.cancelOrder()` rejects only states at or beyond `PACKED (650)`.
- Therefore:
  - `customerorder = 600` passes
  - `customerorder_position = 600` passes

### 3) The direct blocker is `pickingorder_position = 600`

In the regular-picking branch of `CustomerorderPositionService.canOrderPositionBeCancelled()`:

- cancellation is blocked if `pickingorder.state` is in `[400, 700)`
- cancellation is also blocked if `pickingorder_position.state` is in `[400, 700)`

So even if the parent `pickingorder` is only `300`, a child `pickingorder_position = 600` already makes the order **not directly cancellable**.

### 4) Why setting picked positions back to `300` fails

`CustomerorderPositionService.cancelOrderPosition()` contains this branch:

- if `pickingorder_position.state < RESERVED (400)`, it treats the pick as not yet executed,
- reloads `pickfromstockunitId`,
- and releases reserved amount on the original stock unit.

That is wrong for an already-completed pick because:

- source reservation may already be consumed,
- `pickfromstockunitId` may already be null/cleared,
- stock has already been moved to the tote.

So the manual “600 -> 300” workaround is not just insufficient; it can actively push cancellation down the wrong stock-adjustment path.

### 5) Why the explicit release/reset flows are **not** a good explanation for the observed end state

I reviewed the release/reset code in `MobilePickingService`.

#### `releaseRegularPickingOrder(Long id)`

- refuses to reset the order to `PROCESSABLE` if **any** position is already `>= PICKED`

#### `releasePickingOrder(Pickingorder pickingOrder)`

- if all positions are picked, it promotes the order to `PICKED` and calls `finishPickingOrder()`
- if it sees any picked position while the order is not all-finished, it throws `BusinessException("Finish already started picking order!")`

So the normal reset/release paths do **not** cleanly explain “all related positions are `600`, but the parent picking order persisted as `300`”.

### 6) The code already has the locking primitives needed for the real fix

In the pinned snapshot, the repositories already define:

- `CustomerorderRepository.findByIdForUpdate()`
- `PickingorderRepository.findByIdForUpdate()`
- `StockunitRepository.findByIdForUpdate()`

But `PickingorderBusinessService.confirmPick()` uses:

- `pickingorderRepository.findById(...)`
- `customerorderRepository.findById(...)`
- aggregate `findByPickingorderId(...)`
- aggregate `findByOrderId(...)`

without locking the parent rows whose completion state it is deriving.

---

## Root cause conclusion

### Why this split state can happen in the pinned code

The most likely root cause is a **concurrent completion race in `PickingorderBusinessService.confirmPick()`**.

### Mechanism

`confirmPick()` does all of the following in one transaction:

1. marks the current `pickingorder_position` as `PICKED`
2. updates the linked `customerorder_position`
3. recalculates the parent `customerorder` state from `findByOrderId(...)`
4. recalculates the parent `pickingorder` state from `findByPickingorderId(...)`

The problem is that steps 3 and 4 are based on **ordinary reads**, not parent-row locks.

That means two concurrent pick confirmations can each:

- mark their own child row as picked,
- fail to see the other transaction’s not-yet-committed child update,
- conclude “not all picks are done yet”,
- and commit child state changes without promoting the parent `pickingorder`.

### Why the final persisted shape matches the production symptom

This race can leave:

- `pickingorder_position` rows at `600`
- the parent `pickingorder` still at `300` / `500`

Then a later transaction can still independently advance the `customerorder` side to `600` once all `customerorder_position` rows appear complete.

That is the only explanation I found in the pinned code that is fully consistent with all of these facts together:

- child picking rows persisted as `600`
- parent `pickingorder` persisted below `600`
- normal reset flows would have rejected or finished instead of leaving this exact end state
- pessimistic-lock methods already exist but are not used here

### Important nuance

`pickingorder = 300` is **not** the direct cancellation blocker.

It is the **evidence of the broken completion path**.

The direct cancellation blocker is still the child `pickingorder_position = 600` row.

---

## Permanent code fix plan

### Goal

Make it impossible for child pick confirmations to commit `600` while leaving the parent `Pickingorder` stale.

## Fix 1 — lock parent rows in `confirmPick()`

Update `PickingorderBusinessService.confirmPick()` to stop using unlocked parent reads.

### Required behavior

1. Resolve the current `CustomerorderPosition` from the input `PickingorderPosition`
2. Resolve the owning `Customerorder`
3. Lock the parent entities in a stable order:
   - `CustomerorderRepository.findByIdForUpdate(customerOrderId)`
   - `PickingorderRepository.findByIdForUpdate(pickingOrderId)`
4. Continue the pick confirmation using those locked parent instances
5. Recompute parent state from fresh repository reads **inside the same transaction after the child save**
6. Persist the updated parents before returning

### Why this is the right fix

- it uses locking primitives already present in the pinned branch
- it serializes the exact rows whose state is being derived
- it prevents two concurrent “last pick” transactions from both deciding “not all done yet”
- it stays local to the actual race point instead of adding broad new locking elsewhere

### Implementation notes

- keep the existing `@Transactional` boundary on `confirmPick()`
- follow the existing repository lock-order comments: lock `Customerorder` before `Pickingorder`
- keep stock-unit reservation changes going through `StockunitBusinessService.changeReservedAmount()`, which already uses `findByIdForUpdate()` internally

## Fix 2 — recompute parent state only from fresh post-update reads

After saving the current `pickingorder_position`, do **not** rely on stale in-memory assumptions about sibling rows.

Recompute using fresh repository queries:

- `customerorderPositionRepository.findByOrderId(lockedCustomerOrder.getId())`
- `pickingorderPositionRepository.findByPickingorderId(lockedPickingOrder.getId())`

Then:

- if all customer-order positions are complete, advance `customerorder` to `PICKED` or `PENDING`
- if all picking-order positions are `>= PICKED`, advance `pickingorder` to `PICKED`

This logic already exists conceptually; the fix is to run it on a locked parent and fresh sibling reads.

## Fix 3 — optional but recommended operational recovery endpoint

There is already an admin endpoint in the pinned code:

- `GET /v3/adminAction/finishStuckPickingOrder/{number}`

Today it only accepts picking orders already in state `PICKED`.

I recommend extending it so support can recover split orders without SQL when all child positions are already picked:

### Proposed extension

- allow `pickingorder.state < PICKED` **if** all related `pickingorder_position.state >= PICKED`
- under lock, promote the order to `PICKED`
- then call `finishPickingOrder()`

This is not required to prevent recurrence, but it would give support a safer service-layer recovery option for future stuck orders.

## Fix 4 — add regression tests

At minimum add/update tests in:

- `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java`
- optionally an integration/concurrency test under `src/test/java/net/aim_ai/wms/service/...`

### Required test cases

1. **Last pick on a locked picking order**
   - all positions become `>= PICKED`
   - parent `Pickingorder` becomes `PICKED`

2. **Concurrent final picks on the same picking order**
   - final persisted state must not be `child = 600`, `parent < 600`

3. **Customer order completion remains correct**
   - final `Customerorder` becomes `PICKED` only after all relevant order positions are done

4. **Cancellation regression**
   - order already picked can still follow the expected cleanup path after finish/cancel

## No schema migration required

This fix does **not** need a Flyway DDL change.

What is needed in the database is only:

- one-time DML repair for already-bad rows
- optional detection SQL to find other affected orders

---

## One-time production repair for order `241019`

### Intent

This SQL is a **targeted data repair** for the already-corrupted order so that OMS cancellation can succeed without forcing WMS down the wrong stock-release path.

It is designed against:

- `src/main/resources/db/migration/V1.0.01__wms_tables.sql`
- the pinned `release` service code
- PostgreSQL syntax

### What this repair does

It intentionally mirrors the **outcome** of `cleanUpCancelledOrder()` before retrying OMS cancel:

1. unlock stock on the picking tote
2. move the tote to `Clearing`
3. detach/cancel the related `pickingorder_unitload`
4. preserve `historytote` and clear `pickingtote_id`
5. normalize `pickingorder_position` and `pickingorder` to `FINISHED (700)`
6. then allow OMS cancel to complete on the order/customer-order-position rows

### Why not just set the picking rows to `700`

Because by itself that would skip tote cleanup and leave:

- `customerorder.pickingtote_id`
- tote stock locks
- `pickingorder_unitload.unitload_id`

dirty in the database.

The cleanup portion is required.

## Pre-checks

### Step 1 — identify the exact WMS order row

`clientordernumber` is **not unique** in the schema, so use it only to find the exact `customerorder.id` first.

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

Proceed only if this returns exactly one row for the order you intend to repair.

### Step 2 — inspect all related picking rows

Replace `123456` below with the exact `customerorder.id`.

```sql
SELECT cop.id AS customerorder_position_id,
       cop.state AS customerorder_position_state,
       pop.id AS pickingorder_position_id,
       pop.state AS pickingorder_position_state,
       po.id AS pickingorder_id,
       po."number" AS pickingorder_number,
       po.state AS pickingorder_state
FROM customerorder_position cop
LEFT JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
LEFT JOIN pickingorder po ON po.id = pop.pickingorder_id
WHERE cop.order_id = 123456
ORDER BY cop.id, pop.id;
```

### Step 3 — inspect tote and picking-unitload linkage

```sql
SELECT ul.id,
       ul.labelid,
       ul.storagelocation_id,
       loc.name AS location_name,
       ul.carrierunitload_id,
       ul.entity_lock,
       COALESCE(su.stock_count, 0) AS stock_count,
       COALESCE(child.child_ul_count, 0) AS child_ul_count
FROM customerorder co
JOIN unitload ul ON ul.id = co.pickingtote_id
LEFT JOIN location loc ON loc.id = ul.storagelocation_id
LEFT JOIN (
    SELECT unitload_id, count(*) AS stock_count
    FROM stockunit
    GROUP BY unitload_id
) su ON su.unitload_id = ul.id
LEFT JOIN (
    SELECT carrierunitload_id, count(*) AS child_ul_count
    FROM unitload
    WHERE carrierunitload_id IS NOT NULL
    GROUP BY carrierunitload_id
) child ON child.carrierunitload_id = ul.id
WHERE co.id = 123456;

SELECT pul.id,
       pul.pickingorder_id,
       pul.unitload_id,
       pul.state,
       pul.customerordernumber,
       pul.historytote
FROM pickingorder_unitload pul
WHERE pul.pickingorder_id IN (
    SELECT DISTINCT pop.pickingorder_id
    FROM customerorder_position cop
    JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
    WHERE cop.order_id = 123456
      AND pop.pickingorder_id IS NOT NULL
)
ORDER BY pul.id;
```

## Preconditions for the repair transaction

Use the repair below only if all of these are true:

- the exact target `customerorder.id` is known
- `customerorder.state = 600`
- all related `customerorder_position` rows are `600`
- related `pickingorder_position` rows are `600` or were previously manually changed to `300`
- related `pickingorder` rows are below `700`
- the tote exists
- the tote has **no child unitloads** (`child_ul_count = 0`)

If the tote still carries child unitloads, stop and inspect manually.

## One-time repair transaction

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
        SELECT 1
        FROM customerorder co
        WHERE co.id = v_order_id
          AND co.state <> 600
    ) THEN
        RAISE EXCEPTION 'customerorder.id % is not in state 600', v_order_id;
    END IF;

    IF v_tote_id IS NULL THEN
        RAISE EXCEPTION 'customerorder.id % has no pickingtote_id', v_order_id;
    END IF;

    SELECT ul.labelid
      INTO v_tote_label
    FROM unitload ul
    WHERE ul.id = v_tote_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'unitload.id % not found for customerorder.id %', v_tote_id, v_order_id;
    END IF;

    SELECT l.id
      INTO v_clearing_id
    FROM location l
    WHERE l.name = 'Clearing';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'location.name = Clearing not found';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unitload child
        WHERE child.carrierunitload_id = v_tote_id
    ) THEN
        RAISE EXCEPTION 'tote unitload.id % still has child unitloads; inspect manually first', v_tote_id;
    END IF;

    -- 1) Unlock stock currently on the tote.
    UPDATE stockunit su
    SET entity_lock = 0
    WHERE su.unitload_id = v_tote_id
      AND COALESCE(su.entity_lock, 0) <> 0;

    -- 2) Move tote to Clearing and remove any carrier relationship.
    UPDATE unitload ul
    SET storagelocation_id = v_clearing_id,
        carrierunitload_id = NULL,
        entity_lock = 0
    WHERE ul.id = v_tote_id;

    -- 3) Detach/cancel the related pickingorder_unitload rows.
    UPDATE pickingorder_unitload pul
    SET historytote = COALESCE(pul.historytote, v_tote_label),
        unitload_id = NULL,
        state = 800
    WHERE pul.pickingorder_id IN (
        SELECT DISTINCT pop.pickingorder_id
        FROM customerorder_position cop
        JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
        WHERE cop.order_id = v_order_id
          AND pop.pickingorder_id IS NOT NULL
    )
      AND (
          pul.unitload_id = v_tote_id
          OR pul.customerordernumber = v_wms_order_number
          OR pul.historytote = v_tote_label
      );

    -- 4) Preserve tote history on the order and clear the live tote link.
    UPDATE customerorder co
    SET historytote = COALESCE(co.historytote, v_tote_label),
        pickingtote_id = NULL,
        markedforcancellation = FALSE
    WHERE co.id = v_order_id;

    -- 5) Normalize related picking positions to FINISHED.
    UPDATE pickingorder_position pop
    SET state = 700
    WHERE pop.customerorderposition_id IN (
        SELECT cop.id
        FROM customerorder_position cop
        WHERE cop.order_id = v_order_id
    )
      AND pop.state NOT IN (700, 800);

    -- 6) Normalize related picking orders to FINISHED.
    UPDATE pickingorder po
    SET state = 700
    WHERE po.id IN (
        SELECT DISTINCT pop.pickingorder_id
        FROM customerorder_position cop
        JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
        WHERE cop.order_id = v_order_id
          AND pop.pickingorder_id IS NOT NULL
    )
      AND po.state NOT IN (700, 800);
END $$;

COMMIT;
```

## After the repair

Retry cancellation for order `241019` from OMS.

Expected result after OMS cancel:

- `customerorder.state = 800`
- all `customerorder_position.state = 800`
- `customerorder.pickingtote_id IS NULL`
- related `pickingorder_unitload.unitload_id IS NULL`

## Post-repair verification

```sql
SELECT co.id,
       co."number",
       co.state,
       co.pickingtote_id,
       co.historytote,
       co.pickingconfirmationsent,
       co.markedforcancellation
FROM customerorder co
WHERE co.id = 123456;

SELECT cop.id, cop.state
FROM customerorder_position cop
WHERE cop.order_id = 123456
ORDER BY cop.id;

SELECT po.id, po."number", po.state
FROM pickingorder po
WHERE po.id IN (
    SELECT DISTINCT pop.pickingorder_id
    FROM customerorder_position cop
    JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
    WHERE cop.order_id = 123456
)
ORDER BY po.id;

SELECT pul.id, pul.state, pul.unitload_id, pul.historytote
FROM pickingorder_unitload pul
WHERE pul.pickingorder_id IN (
    SELECT DISTINCT pop.pickingorder_id
    FROM customerorder_position cop
    JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
    WHERE cop.order_id = 123456
)
ORDER BY pul.id;
```

## Important caveat

This SQL repair bypasses service-layer movement/audit record creation.

So although it is suitable as a targeted one-time production repair, it should **not** become the normal operational recovery process.

---

## Detection SQL for other already-corrupted orders

Use this query to look for other orders with the same shape before or after deploying the code fix:

```sql
SELECT co.id,
       co."number" AS customerorder_number,
       co.clientordernumber,
       co.state AS customerorder_state
FROM customerorder co
WHERE co.state = 600
  AND EXISTS (
      SELECT 1
      FROM customerorder_position cop
      WHERE cop.order_id = co.id
  )
  AND NOT EXISTS (
      SELECT 1
      FROM customerorder_position cop
      WHERE cop.order_id = co.id
        AND cop.state <> 600
  )
  AND EXISTS (
      SELECT 1
      FROM customerorder_position cop
      JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
      WHERE cop.order_id = co.id
  )
  AND NOT EXISTS (
      SELECT 1
      FROM customerorder_position cop
      JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
      WHERE cop.order_id = co.id
        AND pop.state <> 600
  )
  AND EXISTS (
      SELECT 1
      FROM customerorder_position cop
      JOIN pickingorder_position pop ON pop.customerorderposition_id = cop.id
      JOIN pickingorder po ON po.id = pop.pickingorder_id
      WHERE cop.order_id = co.id
        AND po.state < 600
  )
ORDER BY co.id;
```

---

## Final recommendation

### Approve for implementation

1. **Permanent code fix:** lock `Customerorder` and `Pickingorder` in `confirmPick()` and recompute completion under lock.
2. **Regression coverage:** add unit/integration tests for the concurrent-final-pick scenario.
3. **Production repair:** use the one-time SQL above for order `241019` after verifying the preconditions.

### Do not use as the permanent fix

- resetting picked picking rows to `300`
- forcing only `pickingorder`/`pickingorder_position` to `700` without tote cleanup

Those approaches either drive the wrong service path or leave tote/unitload cleanup incomplete.
