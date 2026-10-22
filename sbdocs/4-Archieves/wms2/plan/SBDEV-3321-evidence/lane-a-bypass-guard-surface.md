# SBDEV-3321 — Lane A: bypass guard surface (bypass #2 and #3)

- **Analysed against** `origin/develop` @ `e113467b` (fetched 2026-09-16; local checkout was 3 commits behind at `4bef7e77` and was **not** used — every citation below is `git show origin/develop:<path>`).
- **DB evidence**: `mcp__wms2-hydra__execute_sql`, database `wh01_hydra_v2` (Hydra PRD, read-only), 2026-09-16 16:26 UTC.
- **Citation form**: file + distinctive quoted snippet. Line numbers appear only where a snippet is ambiguous, and drift.

---

## 0. Executive summary — three findings that change the ticket

1. **Bypass #2 is a non-issue and should be struck.** `UtilRestController` is annotated `@Service` with **no** type-level `@RequestMapping` and **no** `@Controller`/`@RestController` anywhere in the file. Spring MVC's `RequestMappingHandlerMapping.isHandler(...)` requires one of those two at **type** level, so none of its eleven `@RequestMapping` methods — `resetOrdersInReleasedStatus` included — is registered as a handler. There is no HTTP route, and `git grep` finds **no** `src/main` caller and **no** caller in either v2 UI. It is dead code. (§1)

2. **Bypass #3 is real, but the ticket aims at the wrong half of it — and the thing that currently looks like a guard is an accident.** For the two stranded totes the *stock-move* paths are already refused, because their stock carries `entity_lock = 100` (`PICKED_FOR_GOODSOUT`) and `transferStockToUnitLoad` rejects a locked source. But **two of the three cancel paths clear that lock before writing the log row**, so the protection is an artefact of which cancel ran, not a guarantee. Meanwhile the *container-relocation* path (`transferUnitLoadToLocation`) has **no** source-stock guard by explicit, documented design and is reachable today. (§2.4, §2.5)

3. **A doc-drift correction.** `UnitloadBusinessService`'s own enumeration javadoc says *"`PATCH /v3/stockunit/{id}` relocates the same inventory over Spring Data REST with no lock guard and no function check (SBDEV-3017 Class A)"*. That is now **stale**: both `net.aim_ai.wms.model.Stockunit.class` and `net.aim_ai.wms.model.Unitload.class` are in `RestConfiguration.SDR_WRITE_WITHDRAWN`, whose loop disables `WRITE_VERBS` on collection, item and association exposure. That route answers 405. The javadoc's warning should be re-pointed or removed. (§2.3)

---

## 1. Bypass #2 — `UtilRestController.resetOrdersInReleasedStatus()`

### 1.1 Verdict: NOT REACHABLE. Recommend striking it from the ticket.

`src/main/java/net/aim_ai/wms/controller/rest/UtilRestController.java`:

```java
import org.springframework.stereotype.Service;
...
@Service
public class UtilRestController {
```

**Grep over the whole file for `@RestController`, `@Controller`, `@RequiresFunction`, `@PreAuthorize`, `@Secured`, `@RolesAllowed` returns zero hits.** The only class-level annotation is `@Service`. There is no type-level `@RequestMapping` either — the annotation appears eleven times in the file, every one of them on a method.

Spring's `RequestMappingHandlerMapping.isHandler(Class<?>)` is `hasAnnotation(beanType, Controller.class) || hasAnnotation(beanType, RequestMapping.class)`, both evaluated at **type** level. `@Service` is not meta-annotated with `@Controller`. The bean is created; no handler methods are registered from it.

This is not a new observation — `src/main` and `src/test` both already assert it, independently of this lane:

- `WmsConstants.java` — *"UtilRestController, which is annotated @Service, not @RestController — so its @RequestMapping"*
- `V2.2.18__seed_mobile_workflow_functions.sql` — *"Note initDB is unreachable today in any case — UtilRestController"*
- `Sbdev3017TrancheGateContextTest.java` — *"reference outside WmsConstants is UtilRestController, which is @Service, so its mappings do not"*
- `UtilRestControllerUnitTest.java` — *"UtilRestController is annotated with @Service, not @RestController, so we test methods directly."*

### 1.2 The method body — what it resets

```java
@RequestMapping(value = "/resetOrdersInReleasedStatus", method = RequestMethod.GET)
public void resetOrdersInReleasedStatus() throws FacadeException, BusinessException {
    List<Customerorder> allOrdersForStatus = customerorderRepository.findByState(WmsConstants.State.ASSIGNED);
    for (Customerorder customerOrder : allOrdersForStatus) {
        try {
            customerorderService.cancelOrder(customerOrder, false);
        } catch (BusinessException | FacadeException e) {
            LOG.error("resetOrdersInReleasedStatus: skipping order={} due to error: {}", ...);
            continue;
        }
        customerOrder.setState(WmsConstants.State.RAW);
        customerorderRepository.save(customerOrder);
        CustomerorderBatch coBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId())...;
        coBatch.setState(WmsConstants.State.RAW);
        customerorderBatchRepository.save(coBatch);
        List<CustomerorderPosition> coPositions = customerorderPositionRepository.findByOrderId(customerOrder.getId());
        for (CustomerorderPosition customerOrderPosition : coPositions) {
            customerOrderPosition.setState(WmsConstants.State.RAW);
            customerorderPositionRepository.save(customerOrderPosition);
        }
    }
}
```

Scope of the reset, exhaustively (three `save` calls, no others in the method body):

| Reset to `RAW` | Left as `cancelOrder` set it |
|---|---|
| `customerorder.state` | picking orders / picking positions (`CANCELED`) |
| `customerorder_batch.state` (the WHOLE batch, from one order) | `customerorder_cancellation_log` rows (`reversal_required = true`, never completed) |
| every `customerorder_position.state` for that order | tote location (sent to `Clearing`), stock `entity_lock` (cleared), the OMS outbox cancel message |

Two pre-existing defects visible in the body, both moot while unreachable but worth recording so nobody "fixes" the class into reachability without them:
- **No transaction annotation.** `cancelOrder` commits; the four subsequent `save` calls are separate writes. A failure mid-loop leaves a half-reset order.
- **Batch blast radius.** One order at `ASSIGNED` resets its entire `customerorder_batch` to `RAW`, including sibling orders it never touched.

The repo's own prior analysis already recorded this as **B2**, `docs/plan/v2-fixes/phase7-cancel-orchestrator-plan.md`: *"`resetOrdersInReleasedStatus` state corruption — calls `cancelOrder()` then overwrites to RAW, leaving picking positions in CANCELED state"*. Note that same table row claims *"`GET /rest/util/resetOrdersInReleasedStatus` | **No** (controller)"* — i.e. that doc treats it as a live route. It is wrong, on the evidence above.

`State.ASSIGNED = 200`. `reversalRequired = pickingPosition.getState() >= WmsConstants.State.PICKED` (600). So on the *typical* ASSIGNED order the cancel writes rows with `reversal_required = false` — the PRD data agrees (log ids 5–7, 11–16 all have `order_state_at_cancel = 200`, `position_state_at_cancel = 300`, `reversal_required = false`). The order state and the picking-position state are independent columns, though, so an `ASSIGNED` order holding a `PICKED` position is not structurally excluded — just unobserved on PRD. I am not claiming it cannot happen.

### 1.3 Callers and schedulers: none

Method used: `git grep -n "resetOrdersInReleasedStatus" origin/develop` (whole tree), plus `git grep -n "UtilRestController" origin/develop -- 'src/*'`, plus `git grep -n "rest/util\|resetOrders" origin/develop` in `wms2-web-ui` and `wms2-mobile-ui`.

- `src/main`: the declaration only.
- `src/test`: `UtilRestControllerUnitTest` calls it directly on a hand-constructed instance (5 call sites).
- Either v2 UI: **zero**. *Positive control run*: the same `git grep` for `axios` in each UI returns hits (`wms2-web-ui` @ `68ecd83`, `wms2-mobile-ui` @ `ab1e2ae`), so the instrument works and the zero is a true zero, not a broken path spec.
- No `@Scheduled` reference; the only `getBean(` calls in `src/main` are two `getBean(TaskScheduler.class)` in `SchedulingConfiguration`, neither of which can resolve this type.

**Blind spots of that enumeration, stated inline:** it is complete for compiled Java references and for tracked UI source on those three `origin/develop` heads. It is blind to (a) reflective lookup by bean *name* — I checked `getBean(` and found none, but not SpEL or a name-based `ApplicationContext` call constructed from a string; (b) an external caller hitting the path anyway, which cannot succeed because no handler is registered; (c) branches not merged to develop; (d) v1.

### 1.4 Correct behaviour — options, if the class is ever revived

Ranked. I would do **Option A**.

| | Option | Trade-off |
|---|---|---|
| **A** | **Delete the method** (and ideally the whole `@Service`-annotated `UtilRestController` route surface). | Cheapest, removes a live landmine for anyone who "fixes" the annotation. Costs nothing — it has no caller. The `initDB` seed logic in the same class **is** referenced by three Flyway migration comments as the freshly-initialised-tenant counterpart, so delete the *method*, not the class, unless that seeding is separately retired. |
| **B** | Refuse to resurrect: `if (!logRepository.findPendingReversalsForUpdateByCustomerorderId(co.getId()).isEmpty()) { skip + log }` before `setState(RAW)`. | Preserves the (nonexistent) use case. Leaves the order cancelled and the reversal pending — the honest state. Does not fix the batch blast radius or the missing transaction. |
| **C** | Complete the reversals first, then reset. | Wrong. `completeReversal` moves physical stock and notifies OMS; a bulk admin reset must never do that implicitly for every `ASSIGNED` order in the warehouse. |
| **D** | Waive the reversals (`reversal_required = false`, notes = "waived by admin reset"). | Only defensible with a named operator and an audit note. Silently discards a claim that inventory is misplaced. Do not do this from a no-argument bulk endpoint. |

Whatever is chosen, it should **not** be the trigger for adding `@RestController`. Making this class route would expose eleven unauthenticated-by-function admin methods at once, including `initDB` and `simulateServerFaultException`.

---

## 2. Bypass #3 — hand-moving a cancelled tote's stock

### 2.1 The join from stock back to a pending reversal

`picktounitload_id` is an FK to **`pickingorder_unitload`**, *not* to `unitload`. Confirmed on PRD:

```sql
SELECT con.conname, pg_get_constraintdef(con.oid) FROM pg_constraint con
JOIN pg_class rel ON rel.oid = con.conrelid
WHERE rel.relname = 'customerorder_cancellation_log';
```
```
customerorder_cancellation_log_customerorder_id_fkey           FOREIGN KEY (customerorder_id) REFERENCES customerorder(id)
customerorder_cancellation_log_customerorder_position_id_fkey  FOREIGN KEY (customerorder_position_id) REFERENCES customerorder_position(id)
customerorder_cancellation_log_pkey                            PRIMARY KEY (id)
fk_cancel_log_picktounitload                                   FOREIGN KEY (picktounitload_id) REFERENCES pickingorder_unitload(id)
```

`CancellationLogService` states the same rule and the hop that satisfies it:

> *"`picktounitload_id` is an FK to `pickingorder_unitload`, **not** to `unitload` … It must be hopped through `PickingorderUnitload#getUnitloadId()` before it can be used as a unit load id"*

and flags the hop's own expiry:

> *"⚠ The hop only resolves while `pickingorder_unitload.unitload_id` is still populated. That link is cleared at the FINISHED transition"*

**The guard predicate — SQL (the shape a native guard or a verification query should use):**

```sql
SELECT cl.id, cl.customerorder_id, cl.customerorder_position_id, cl.tote_label_id, cl.amount_picked
FROM customerorder_cancellation_log cl
JOIN pickingorder_unitload pou ON pou.id = cl.picktounitload_id
WHERE cl.reversal_required = true
  AND cl.reversal_completed_at IS NULL
  AND (
        pou.unitload_id = :unitloadId                                   -- container axis
     OR cl.picktostockunit_id = :stockunitId                            -- stock axis (see §2.2 caveat)
  );
```

**JPQL (the shape a repository method should use).** `CustomerorderCancellationLog` has no JPA association to `PickingorderUnitload` — this repo uses manual FK columns, no association annotations — so the hop is a subquery, not a join:

```java
@Query("SELECT l FROM CustomerorderCancellationLog l "
     + "WHERE l.reversalRequired = true AND l.reversalCompletedAt IS NULL "
     + "AND (l.picktostockunitId = :stockunitId "
     + "  OR l.picktounitloadId IN (SELECT p.id FROM PickingorderUnitload p WHERE p.unitloadId = :unitloadId))")
List<CustomerorderCancellationLog> findPendingReversalsTouching(@Param("stockunitId") Long stockunitId,
                                                               @Param("unitloadId") Long unitloadId);
```

**The chain resolves cleanly on PRD today** (7 pending rows, verbatim result condensed to the distinct containers):

| log ids | order | tote | `picktounitload_id` | → `pou.unitload_id` | `unitload.labelid` | location |
|---|---|---|---|---|---|---|
| 1,2,3,4 | 60861 | T-0002 | 60938 (`pou.state=600`) | 17662 | `T-0002` | `FinishedPicking` (id 11) |
| 8,9,10 | 159907 | T-0007 | 159979 (`pou.state=600`) | 37736 | `T-0007` | `FinishedPicking` (id 11) |

### 2.2 ⚠ `picktostockunit_id` is NULL on **every** row on PRD — the stock axis is unusable today

```sql
SELECT id, customerorder_id, picktounitload_id, picktostockunit_id, tote_label_id,
       reversal_required, reversal_completed_at FROM customerorder_cancellation_log ORDER BY id;
```

All **16** rows return `picktostockunit_id: None`. Derivation: full table scan, no predicate — the table has 16 rows total, so this is exhaustive for this tenant/facility. Blind spot: PRD holds one tenant-facility pair (`wh01_hydra_v2`); other tenants were not queried in this lane.

That is the SBDEV-3316 defect (`recordCancellation` fed `picktounitload_id` straight to `findByUnitloadId`, matching zero rows every time). It is fixed on `origin/develop`, but **existing rows were not backfilled**, and `completeReversal` heals them lazily at completion time rather than by migration:

> *"Rows written before the SBDEV-3316 fix all carry picktostockunit_id = NULL … Re-attempt the resolution here, from the SAME implementation the record path uses, and persist what it finds."*

**Consequence for the guard design:** a guard keyed on `picktostockunit_id` matches **nothing** on today's data. Any guard must key on the **container** axis (`picktounitload_id → pou.unitload_id`) as its primary predicate, with the stock axis as an additional `OR` clause for rows written after the fix. Getting this backwards produces a guard that is green everywhere and fences nothing.

Also worth flagging to whoever writes the plan: **PRD's `customerorder_cancellation_log` has no `pickingorder_position_id` column.** The first query I ran failed with `column "pickingorder_position_id" does not exist`; `information_schema.columns` confirms 23 columns ending at `created_by`. Migration `V2.2.31__cancellation_log_pickingorder_position_id.sql` exists on `origin/develop` but has not reached this PRD database. Anything in the fix that reads that column will fail on PRD until Flyway runs.

### 2.3 Affected-sites table — every path that relocates stock or a container

**Method used** (stated so its blind spots are checkable): `git grep` against `origin/develop` restricted to `src/main/java`, on the *state-mutating field writers* rather than on method names — `setStoragelocationId(`, `setUnitloadId(`, `setCarrierunitloadId(` — then a second pass for bulk DML (`UPDATE Unitload`, `UPDATE Stockunit`, `SET storagelocation_id`, `SET unitload_id`, case-insensitive). Writing the census on the *writers* rather than on `transferX(` names is deliberate: a rename cannot hide a field write, whereas it does hide a method-name grep.

**Blind spots of this method, inline:** it is complete for compiled Java in `src/main` on this head. It is blind to (a) true **native** SQL issued outside JPQL — I searched for the obvious column-name forms and found none, but a dynamically-assembled statement would evade it; (b) direct DB edits and operator psql; (c) v1; (d) branches not merged to develop; (e) Spring Data REST auto-generated writes — checked separately in the last two rows below.

| # | Site | What it moves | Guards on the source | Can it touch a pending-reversal tote? |
|---|---|---|---|---|
| 1 | `UnitloadBusinessService.processTransfer` — `"unitload.setStoragelocationId(destinationLocation.getId());"` | **container** location (recursively, whole carrier tree) | **none on the source** — see §2.4 | **YES** — the single service-layer chokepoint for container relocation |
| 2 | `UnitloadBusinessService.transferUnitLoadToLocation` | entry point → #1 | destination-location lock only, and only when `ignoreLock=false` | via #1 |
| 3 | `UnitloadBusinessService.transferUnitLoadToCarrier` — `"unitload.setCarrierunitloadId(destinationUnitload.getId());"` then `processTransfer(...)` | nests container under a carrier, then → #1 | unit-load *type* rules (`onotherunitloadallowed`, `unitloadallowed`) — **no lock, no stock check** | via #1 |
| 4 | `UnitloadBusinessService.sendToClearing` | → #2 with `ignoreLock=true` | none | via #1; **this is what the cancel itself calls** |
| 5 | `UnitloadBusinessService.relocateEmptiedContainer` | → #2 with `ignoreLock=true` | none | via #1 |
| 6 | `StockunitBusinessService.transferStockToUnitLoad` — `"sourceStockunit.setUnitloadId(destinationUnitload.getId());"` (full move) / `createStockUnit(...)` (split) | **stock** between containers | under `!ignoreLock`: source stockunit, source unitload, source location, destination stockunit, destination unitload, destination location locks — all must be `NOT_LOCKED` | **YES** — the single chokepoint for inter-container stock movement |
| 7 | `StockunitBusinessService` — `"stockUnit.setUnitloadId(nirvanaUnitload.getId());"` | stock → nirvana (discard) | (separate method; not a Move-Stock/Move-UL route) | yes, structurally |
| 8 | `StockunitService.transferStock` | web + mobile Move Stock commit; six calls into #6, one into #2 | `SourceLockGuard` on the whole-container arm; #6's guards on the split arms | via #6 / #2 |
| 9 | `MobileMoveUnitloadService.scanDestination` | Move Unit Load — branches into #2, #3, or its private `transferStock` → #6 | `ON_HOLD` only (UL and each stock unit) + `checkReservedStock` | **YES** — §2.4 |
| 10 | `MobileMoveStockService` | **read-only** — `selectSource` / `selectStockUnit` return DTOs; no `save`, no `set*` on a persisted entity | n/a | **no** — it does not commit anything |
| 11 | `MoveStockController` (`/v3/moveStock`) | two `@GetMapping` lookups only | `@RequiresFunction(MOBILE_UI_VIEW_STOCK_TRANSFER)` | no (see #10) |
| 12 | `MoveUnitloadController` (`/v3/moveUnitload`) | `selectSource` (GET), `selectDestination` (POST) → #9 | `@RequiresFunction(MOBILE_UI_VIEW_TRANSFER)` | **YES** |
| 13 | `StockUnitController` `POST /v3/stockUnit/transferStock` (+ the bulk sibling) | → #8 | gated; SBDEV-3017-C closed the ungated bulk sibling | via #8 |
| 14 | `BillofladingService` — `"UPDATE Unitload u SET u.storagelocationId = :shippedLocationId, u.entityLock = :lock"` (**two** occurrences) | bulk relocate pallets + children to `Shipped` | **bypasses #1 and #2 entirely** — bulk JPQL, no per-row guard | yes, structurally — this is the native-query blind spot the lane was asked about, and it is real |
| 15 | `MobilePutAwayService`, `MobileReplenishService`, `MobilePickingService`, `MobileTruckLoadingService`, `MobileTransferOrderService`, `ReceivingService`, `ClubLineOrderProcessor`, `ParcelMonitorViewService`, `FixLocationAssignmentService`, `PickingorderBusinessService`, `CustomerorderService`, `UnitloadService` | all reach #1 or #6 | per-caller | via #1 / #6 |
| 16 | SDR `PATCH /v3/stockunit/{id}`, `PATCH /v3/unitload/{id}` | — | **withdrawn**: both classes are in `RestConfiguration.SDR_WRITE_WITHDRAWN`, loop disables `WRITE_VERBS` on collection/item/association exposure → **405** | **no** |
| 17 | `UtilRestController.*` | — | `@Service`, not routed (§1) | **no** |

**Fresh call-site counts** (re-derived, not quoted from the javadoc, per the "prose enumerations rot" rule — they happen to reproduce it exactly):

```
transferUnitLoadToLocation call sites in src/main/java, excl. declaration:  24   (16 ignoreLock=false, 8 true)
transferStockToUnitLoad    call sites in src/main/java, excl. declarations: 19
```

### 2.4 Is bypass #3 reachable? Yes — but **not** by the route the ticket names

Trace `MobileMoveUnitloadService.scanDestination` against the live PRD state of T-0002 / T-0007:

```java
if (sourceUnitLoad.getEntityLock() == WmsConstants.BusinessObjectLockState.ON_HOLD) {
    throw new BusinessException("Unit load is locked on hold!");
}
List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(sourceUnitLoad.getId());
for (Stockunit stockUnit : stockUnitList) {
    if (stockUnit.getEntityLock() == WmsConstants.BusinessObjectLockState.ON_HOLD) {
        throw new BusinessException("Stock unit is locked on hold!");
    }
}
checkReservedStock(sourceUnitLoad);
```

Measured state (PRD):

```sql
SELECT 'stockunit', su.id, su.entity_lock, NULL, su.unitload_id FROM stockunit su WHERE su.unitload_id IN (17662, 37736)
UNION ALL SELECT 'unitload', ul.id, ul.entity_lock, ul.labelid, ul.storagelocation_id FROM unitload ul WHERE ul.id IN (17662,37736)
UNION ALL SELECT 'location', l.id, l.entity_lock, l.name, NULL FROM location l WHERE l.id = 11;
```
```
location  11     entity_lock 0    FinishedPicking
stockunit 60941  entity_lock 100  → unitload 17662      stockunit 159982 entity_lock 100 → unitload 37736
stockunit 60947  entity_lock 100  → unitload 17662      stockunit 160025 entity_lock 100 → unitload 37736
stockunit 60952  entity_lock 100  → unitload 17662      stockunit 160050 entity_lock 100 → unitload 37736
stockunit 60957  entity_lock 100  → unitload 17662
unitload  17662  entity_lock 0    T-0002 @ location 11
unitload  37736  entity_lock 0    T-0007 @ location 11
```

`ON_HOLD = 104`, `PICKED_FOR_GOODSOUT = 100` (`WmsConstants.BusinessObjectLockState`). So:

- UL lock `0` ≠ `104` → **passes**.
- Every stock unit's lock is `100` ≠ `104` → **passes**. The `ON_HOLD`-only comparison lets `PICKED_FOR_GOODSOUT` straight through.
- `checkReservedStock`: `reservedamount = 0.0000` on all 7 units (measured), so the loop hits `continue; // no reservation on this stock -> nothing to check` on every row → **passes**.

Then the branches diverge, and this is the crux:

| Branch | Reaches | Outcome for T-0002 today |
|---|---|---|
| destination is a plain location, `!moveStock` → `unitloadBusinessService.transferUnitLoadToLocation(sourceUnitLoad, destinationStorageLocation, false, CODE_TRANSFER, null, null)` | #2 → #1 | **SUCCEEDS.** `ignoreLock=false` gates *only the destination location's* lock. The tote relocates anywhere the operator scans. |
| destination is a flow bin / carrier with `moveStock` → private `transferStock(...)` → `transferStockToUnitLoad(..., ignoreLock=false, false)` | #6 | **REFUSED** — `"Source stockUnit=" + sourceStockunit.getId() + " is locked=" + lock` (100). |
| `transferUnitLoadToCarrier` | #3 → #1 | **SUCCEEDS** if the unit-load *type* rules allow the nesting. No lock or stock check at all. |

So today, for these two totes, **the container moves and the stock does not**. The ticket's framing ("an operator can hand-move a cancelled tote's stock") describes the arm that is currently blocked.

### 2.5 …and the block is an accident. Two of three cancel paths clear the lock first.

`recordCancellation` has exactly three `src/main` call sites (`git grep -n "recordCancellation" origin/develop -- 'src/main'`):

| Call site | Clears the picked stock's lock? | Sends the tote to `Clearing`? | Resulting exposure |
|---|---|---|---|
| `CustomerorderPositionService:143` — per-position cancel | **NO.** `git grep -n "setEntityLock" …/CustomerorderPositionService.java` returns **zero** hits in the whole file. | no | stock stays at `100` → stock-move arm refused. **This is where T-0002 / T-0007 came from** — consistent with their being at `FinishedPicking`, not `Clearing`. |
| `CustomerorderService:424` — order cancel | **YES** — `"pickingTote.setEntityLock(...NOT_LOCKED)"`, `"stockUnit.setEntityLock(...NOT_LOCKED)"` (twice, tote + parcel), and again in `forceCancelOrder`: `"toteStock.forEach(su -> su.setEntityLock(...NOT_LOCKED))"` | yes — `sendToClearing(pickingTote, …)` / `sendToClearing(parcel, …)` | stock unlocked → **stock-move arm fully open** |
| `PickingorderBusinessService:547`, reached from `cleanUpCancelledOrder` | **YES**, and demonstrably *before* the log rows exist: the clear is `"stockUnits.forEach(su -> su.setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED))"` at :701, `cancelOpenPickLines(customerOrder, coPositions)` — which contains the `recordCancellation` call — is at :732. | yes — `unitloadBusinessService.sendToClearing(tote, …)` immediately above the clear | stock unlocked → **stock-move arm fully open** |

`CancellationReversalService` names this asymmetry itself:

> *"Precedent: `PickingorderBusinessService.cleanUpCancelledOrder` does the same clear for the order-level cancel … The per-position path, `CustomerorderPositionService.cancelOrderPosition`, never got it — which is why these rows are locked at all."*

**Therefore: do not design the fix around `entity_lock`.** On two of three cancel paths a pending-reversal tote sits at `Clearing`, unlocked, holding the picked stock, and both Move Stock and Move Unit Load will move it. The reason PRD shows no such case right now is that PRD has no such case *yet*:

```sql
SELECT l.name, su.entity_lock, count(DISTINCT ul.id) unitloads, count(*) stockunits
FROM unitload ul JOIN stockunit su ON su.unitload_id = ul.id JOIN location l ON l.id = ul.storagelocation_id
WHERE l.name IN ('Clearing','FinishedPicking','EmptyTotes') GROUP BY 1,2 ORDER BY 1,2;
```
```
FinishedPicking | 100 | 2 unitloads | 7 stockunits
```
One row. Nothing at `Clearing`, nothing at `EmptyTotes`, and the only stock in the three locations is exactly the known strand.

### 2.6 What actually breaks the reversal — be precise about it

`completeReversal` reverses by **stock unit id**, not by location:

```java
stockunitService.transferStock(stockUnit, log.getAmountPicked(), false, log.getPickfromlocationname(), null, null, false);
```

Consequences, which the plan should not blur together:

- **A pure container relocation does *not* strand the reversal.** The stock unit rides with the tote; `picktostockunit_id` still resolves; the reversal still moves `amount_picked` back to `pickfromlocationname`. What changes is that the tote is no longer where the operator screen expects it — a UX and traceability problem, not a lost reversal. *(Caveat: `transferStock`'s whole-unit-load arm relocates the whole container rather than splitting when the amounts line up, so a reversal after a relocation can drag the container somewhere unintended. `CancellationReversalService` already flags this arm.)*
- **A full inter-container stock move does *not* orphan the row either**, because `transferStockToUnitLoad`'s full-move branch reassigns the *same* row: `"sourceStockunit.setUnitloadId(destinationUnitload.getId());"`. `picktostockunit_id` still resolves — to stock that now legitimately belongs somewhere else. The reversal would then move stock the operator deliberately relocated. **This is the genuine correctness hole.**
- **A partial (split) move is the one that hard-fails.** The split branch creates a new destination stock unit and decrements the source. `picktostockunit_id` then points at a unit holding less than `amount_picked`, and the reversal fails at the amount check — loudly, leaving the row pending forever. That is the permanent-strand shape the ticket describes.
- **`removeUnitLoadIfEmpty=true` compounds it**: a drained source container is sent to nirvana via `relocateEmptiedContainer`, so the tote the operator would scan on the cancellation screen no longer exists at a scannable location.

### 2.7 Where the guard goes

**There is a chokepoint for each of the two verbs, and only two.** Derived from the field-writer census in §2.3.

- **Stock between containers → `StockunitBusinessService.transferStockToUnitLoad`.** Every inter-container stock movement in `src/main` writes `stockunit.unitload_id` through this method (19 call sites) or through `createStockUnit` inside it. The one sibling writer, `"stockUnit.setUnitloadId(nirvanaUnitload.getId())"`, is the discard path in the same class.
- **Container relocation → `UnitloadBusinessService.processTransfer`.** It is the sole `setStoragelocationId` writer on an *existing* container; the only other three writers are `UnitloadService.createUnitload` ×2 and `getNirvana`, all of which set the field on a `new Unitload()` before the first `save` and so cannot relocate anything. Both public verbs (`transferUnitLoadToLocation`, `transferUnitLoadToCarrier`) funnel into it, as do `sendToClearing` and `relocateEmptiedContainer`.

**That set is closed for the service layer, and the closure has exactly one hole I can name:** `BillofladingService`'s two `"UPDATE Unitload u SET u.storagelocationId = :shippedLocationId"` bulk statements, which never enter `processTransfer`. A guard at the chokepoints will not see them. That is acceptable — a BOL close on an order with a pending reversal is a different and larger problem — but it must be stated, not assumed away.

**Recommended shape** (for the plan to evaluate, not a decision I am making):

1. Put the check in `transferStockToUnitLoad`, keyed on the **container** axis via the §2.1 JPQL — *not* on `picktostockunit_id`, which is NULL on every existing row (§2.2). Resolve the source stock unit's `unitload_id`, ask whether any pending reversal's `picktounitload_id` hops to it, refuse if so with a keyed `BusinessException` naming the order and the tote.
2. Put the *same* check in `processTransfer` only if the team wants container relocation blocked too — and I would argue **not**, see §2.8.
3. Give it a sysprop gate defaulting **ON** but individually disengageable, matching the `SBDEV-3340` precedent in `StockunitService` for a newly-added constraint check.

### 2.8 Operator impact — where blocking would be wrong

A guard at `processTransfer` fences *every* container relocation. These paths would break, and every one of them is legitimate:

| Path | Why blocking is wrong |
|---|---|
| `sendToClearing` — called **by the cancel itself**, `PickingorderBusinessService` and `CustomerorderService` | The cancel would deadlock against its own guard: it writes the log row and moves the tote in the same transaction. **This alone rules out an unconditional guard in `processTransfer`.** |
| `PickingorderBusinessService` → `FinishedPicking` | The move that *creates* the state the guard is protecting. |
| `MobileTruckLoadingService`, `ParcelMonitorViewService` → gate | Refusing a truck load because one line on one order was cancelled halts outbound. |
| `ReceivingService` (×3), `MobilePutAwayService` (×5) | Inbound and putaway; unrelated to cancellation. |
| `relocateEmptiedContainer` → nirvana | A container that is now empty by definition holds nothing to reverse. |
| `FixLocationAssignmentService` | Flow-bin housekeeping. |
| `MobileMoveUnitloadService` → `EmptyTotes` / `EmptyPallets` | Returning a *drained* tote to the pool. |

And a guard at `transferStockToUnitLoad` is much safer but still not free — it must **not** fire for:

- `CancellationReversalService` itself, whose `transferStock` call is the reversal. It must be exempt, or the fix blocks the cure.
- `PickingorderBusinessService:1150` (pick confirm), `CustomerorderService:646` (packaging), `BillofladingService` (×2), `ClubLineOrderProcessor` — none of these are hand moves.
- The `CODE_DAMAGED` arm in `StockunitService.transferStock`: marking cancelled stock damaged is a *legitimate* operator response to finding it, and hard-blocking it leaves the operator no action at all.

The operator-facing failure mode to design against is the one the repo has already been bitten by twice (`SBDEV-3226`, `SBDEV-3326`): a refusal that reaches the floor as `"is locked=100"`. Any new `BusinessException` here must name the order number, the tote label, and the action ("complete or waive the cancellation reversal for order 000026-000001 on tote T-0002"), and there must be a screen that *does* that — `OrderCancellationController` `POST /v3/cancellation/{id}/complete` exists and is gated `@RequiresFunction(MOBILE_UI_VIEW_CANCELLATION)`, so the exit door is there; the message must point at it.

### 2.9 Existing test coverage

| Path | Tests on `origin/develop` |
|---|---|
| `transferStockToUnitLoad` | `StockunitBusinessServiceUnitTest`, `StockunitBusinessServiceFullMoveInvariantUnitTest`, `StockunitBusinessServiceConcurrencyIT` |
| `transferUnitLoadToLocation` / `processTransfer` | `UnitloadBusinessServiceUnitTest` (incl. `TransferUnitLoadToLocationSourceLockAsymmetry`, which **pins the absence of the source guard** — a new guard there breaks it *by design*, and that is the signal, not a flake), `UnitloadBusinessServiceCartContractUnitTest`, `UnitloadBusinessServiceReplenBranchTest`, `UnitloadBusinessServiceReplenSyncTest`, `UnitloadBusinessServiceConcurrencyIT` |
| `StockunitService.transferStock` | `StockunitServiceTransferStockGuardTest`, `StockunitServiceTransferStockDestinationTest`, `StockunitServiceToteContainerRelocationUnitTest`, `StockunitServiceLockOnHoldTxTest`, `StockunitServiceUnitTest`, `StockunitServiceAuditCommentClampUnitTest` |
| Mobile Move UL / Move Stock | `MobileMoveUnitloadServiceTest`, `MobileMoveUnitloadServiceUnitTest`, `MobileMoveStockServiceTest`, `MoveUnitloadControllerUnitTest`, `MoveStockControllerUnitTest`, `MoveStockScanDestinationRetiredUnitTest` |
| Cancellation log / reversal | `CancellationLogServiceUnitTest`, `CancellationReversalServiceUnitTest`, `CancellationReversalLockClearIntegrationTest`, `CancellationLogPickingorderPositionIdIT`, `CancellationLogEntryDtoSerializationTest` |
| `UtilRestController` | `UtilRestControllerUnitTest` (5 direct calls to `resetOrdersInReleasedStatus`), `UtilRestControllerSeedUnitTest` |

**No test asserts the interaction between a pending reversal and a stock/container move.** That is the gap this ticket's TDD gate should fill, and the mutation check is: make the guard's predicate key on `picktostockunit_id` instead of the container axis, and confirm the new test goes red — if it stays green, the test is matching on today's NULL column and proves nothing (§2.2).

---

## 3. Things that contradict the premise — stated loudly

1. **Bypass #2 does not exist.** No route, no caller, no scheduler. Strike it. The ticket's own reference doc (`phase7-cancel-orchestrator-plan.md`) records it as a live `GET /rest/util/...`; that is wrong.
2. **The `MoveStockController` half of bypass #3 does not move stock.** `MobileMoveStockService` is read-only; the commit lives at `POST /v3/stockUnit/transferStock` on `StockUnitController`. A plan that guards `MoveStockController` guards a lookup.
3. **SDR is already closed for this.** `Stockunit`, `Unitload`, `PickingorderUnitload`, `Pickingorder`, `PickingorderPosition`, `Customerorder`, `CustomerorderPosition` are all in `SDR_WRITE_WITHDRAWN`. The `UnitloadBusinessService` javadoc's claim that `PATCH /v3/stockunit/{id}` is an open bypass is stale and should be corrected in the same PR.
4. **The `entity_lock = 100` that currently blocks the stock-move arm is not a guard.** It survives only on the per-position cancel path; the other two cancel paths clear it before the log row is written (§2.5). Any argument of the form "this is already protected because the stock is locked" is wrong.
5. **PRD is missing `V2.2.31`** (`pickingorder_position_id` column absent on `wh01_hydra_v2`). A fix that reads that column will not run on PRD until Flyway does.

---

## Appendix — DB queries, verbatim

All against `mcp__wms2-hydra__execute_sql`, database `wh01_hydra_v2`, 2026-09-16.

1. `SELECT current_database(), now()` → `wh01_hydra_v2`, `2026-09-16 16:26:01 UTC` *(warm-up; the first query after idle can drop)*
2. Full `customerorder_cancellation_log` scan → 16 rows; 7 pending (`reversal_required=true AND reversal_completed_at IS NULL`): ids 1–4 (order 60861, tote T-0002, `picktounitload_id=60938`, amounts 24/12/12/12) and 8–10 (order 159907, tote T-0007, `picktounitload_id=159979`, amounts 1/1/1). **`picktostockunit_id` NULL on all 16.**
3. `information_schema.columns` for the log table → 23 columns, no `pickingorder_position_id`.
4. `pg_constraint` on the log table → `fk_cancel_log_picktounitload FOREIGN KEY (picktounitload_id) REFERENCES pickingorder_unitload(id)`.
5. `information_schema.columns` for `pickingorder_unitload` / `stockunit` → `pou.unitload_id`, `stockunit.unitload_id` confirmed; `unitload` has `storagelocation_id` + `carrierunitload_id`, no `location_id`.
6. Three-hop join (log → pou → unitload → location) for the 7 pending rows → both totes resolve; `pou.state=600`, `pou.unitload_id` populated (17662 / 37736), both at `FinishedPicking` (location 11), `carrierunitload_id` NULL.
7. `SELECT … FROM stockunit WHERE unitload_id IN (17662, 37736)` → 7 rows; T-0002 = 24+12+12+12 = **60 units**, T-0007 = 1+1+1 = **3 units** (**63 total**, matching `sbdocs/2-Areas/runbooks/free-63-units-t0002-t0007.md`); `reservedamount = 0.0000` on all 7.
8. `SELECT labelid, count(*) … WHERE labelid IN ('T-0002','T-0007') GROUP BY labelid` → 1 each. *Caveat: that is data, not a constraint — `unitload` carries only a PK, so tote-label uniqueness is not enforced and a label-keyed lookup is not safe in general.*
9. Lock census on the two totes → all 7 stock units `entity_lock=100`; both unit loads `0`; location 11 `0`.
10. `SELECT id, name, entity_lock FROM location WHERE name IN (…)` → `Clearing`=1, `Damaged`=6, `EmptyTotes`=10, `FinishedPicking`=11, `Nirwana`=0, `Shipped`=15; all unlocked. *(Note the spelling is `Nirwana`, not `Nirvana`.)*
11. Stock-by-location census across `Clearing` / `FinishedPicking` / `EmptyTotes` → exactly one group: `FinishedPicking, lock 100, 2 unitloads, 7 stockunits`. Nothing else.
