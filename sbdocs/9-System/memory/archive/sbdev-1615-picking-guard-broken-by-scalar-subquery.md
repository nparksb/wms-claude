---
name: sbdev-1615-picking-guard-broken-by-scalar-subquery
description: SBDEV-1615 — the picking-started guard was BOTH crashing and on the wrong state axis; the "one-word fix" is real but insufficient. MERGED on dev (#231 + #94)
metadata:
  type: project
---

**MERGED to develop 2026-08-28** — api #231 (`980a7718`), web-ui #94 (`4dceb16`); ticket `on dev`.
Not on release/main. No Flyway migration in either.

**The `=`→`IN` one-liner this memory used to advertise is REAL BUT NOT ENOUGH.** It stops the
`SQLSTATE 21000` crash (`PickingorderPositionRepository`, scalar subquery — note it fires on the
subquery's **row count**, so two positions sharing one `pickingorder_id` crash it too, not just
multiple orders). It does **not** make the guard work.

**Why: `PickingorderPosition.state` never reaches STARTED(500).** Positions are created at
PROCESSABLE(300) and every terminal transition NULLs `pickfromstockunit_id` in the *same operation*
that sets the state (`PickingorderBusinessService:566+568` PICKED; `CustomerorderPositionService:152`
and `CustomerorderService:405` CANCELED). So `pickfromstockunit_id = :id AND state >= 500` is
**unsatisfiable by construction**. Measured DEV 2026-08-28: state 300 → 108 rows all carrying the FK;
600 → 750,042 rows **zero**; 800 → 2,992 rows **zero**.

Measured against ground truth (owning `Pickingorder.state >= 500`):

| | population | truly active | `IN` refuses | direct filter |
|---|---|---|---|---|
| wms2-wineco-dev | 11 | 5 | 1 — **misses 4 of 5** | **0** |
| nywh-hydra-uat | 29 | 3 | 8 — **5 false blocks** | **0** |

So `IN` alone is wrong in **both** directions and *looks healthy*; the tempting narrow rewrite
(filter directly on `pickfromstockunit_id`) is a **permanent no-op**. Fix is
**[[wms2-picklinerealignment-is-the-shared-pick-activity-predicate]]** — the owning-order axis.

**Traps this ticket cost real time on, all still live:**
- **`isActive` assumes its caller took `lockOwningPickingorders`** — its javadoc says the lock is
  acquired "at the move entry method ... not here". Both sibling call sites do. I skipped it and
  introduced a TOCTOU hole on an inventory path; only the adversarial review lane caught it.
- **`pickingorder_position.pickingorder_id` is NULLABLE** and `findById(null)` throws uncaught →
  same 500 shape, same class as [[sbdev-3119-null-parent-walk]].
- **A test can claim a pin it does not provide.** My test's comment said it pinned the
  FINISHED/CANCELED wart while mocking the predicate that decides it — it held for *any*
  implementation. PIT cannot catch that class (`CONDITIONALS_BOUNDARY` only makes `>=` into `>`);
  hand-mutate `>= STARTED && < FINISHED` instead.
- **Impossible-state fixtures.** Two test classes set a position to STARTED(500), a value the
  lifecycle never writes — green against data that cannot occur, which is how a 100%-non-functional
  guard kept a healthy suite for ten months. See [[green-tests-that-prove-nothing]].
- **Measuring on one axis and generalising to another.** I claimed "strict tightening" from a
  stock-unit-axis measurement (where cancel NULLs the FK so cancelled rows *structurally cannot
  appear*) and it was false on the parcel axis: 2 parcels loosened on UAT. Re-measure per axis.

**Problem 2 (ex-SBDEV-2473) is a DECISION, not a defect** — Nam 2026-08-28: keep the deferred
replenishment re-sync (an immediate one would re-reserve the stock just released), explain it in the
UI. No API change.

`getPickingorderPositionsByStockunitId` now has **zero production callers** — SDR export only.
