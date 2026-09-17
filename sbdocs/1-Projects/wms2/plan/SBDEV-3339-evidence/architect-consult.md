# SBDEV-3339 — architect consult (READ-ONLY design review)

**Graded against `origin/develop` = `221caed163c8fb997dc6546dbe000ac5d123ea71`** ("Merge pull request #353 from SiteBossInc/fix/outbox-latency-config"), read exclusively via `git show origin/develop:<path>` / `git grep … origin/develop`. The local checkout was never read.

**Instrument note.** Every enumeration below names the command that produced it. `git grep` was used throughout (unaffected by the ugrep binary-skip trap). No DB query was run — **all 13 `wms2-*` / `landlord-*` / `wms1-*` MCP servers failed with `CONNECT_TIMEOUT` in this session**, so every DB-shaped claim here is marked as *needs a query* and is the lead's lane, not a finding I am asserting.

---

## TL;DR — where I think you are WRONG

1. **Q1's premise is wrong.** There is **no `entity_lock` guard anywhere on the `sendToClearing` path.** `sendToClearing` calls `transferUnitLoadToLocation(..., ignoreLock=true, ...)`, and `ignoreLock=true` skips the *only* `entity_lock` read in that method. `processTransfer` reads `entity_lock` on nothing. So neither sibling's ordering is enforced by a guard, and "which ordering does the guard demand" has no answer. **The ordering still matters — but for lock order, not for a guard.** See Q1.
2. **You have three siblings, not two.** `CustomerorderBatchService.cancelBatch` is a **fourth cancellation path with the same defect, and a worse variant of it**: it nulls `pickingtote_id` with **no** stock-lock clear, **no** `sendToClearing`, and **no** `historytote`. Fixing only `cancelOrder` leaves a live producer of locked-and-now-unreferenced tote stock. See §Sibling sweep.
3. **Do not copy `forceCancelOrder`'s guard verbatim — it carries a latent NPE.** `pickingTote.getEntityLock() != WmsConstants.BusinessObjectLockState.GOING_TO_DELETE` compares a nullable `Integer` to an `int`; `unitload.entity_lock` is `integer` with **no NOT NULL and no default**. The codebase already knows this and says so out loud elsewhere. See Q3/G2.
4. **`sendToClearing`'s two trailing arguments are swapped relative to its callee.** Pre-existing; the fix must reproduce the swap (i.e. copy the sibling call shape), not "fix" it. See Q2/note.
5. Q5: **I agree with your conclusion, but your stated reason does not hold.** `cancelOrderPosition` has exactly **one** production caller, so "it must stay position-scoped for other callers" protects nothing. The real reasons are different and stronger. See Q5.

---

## Q1 — Ordering: `sendToClearing` first, or lock-clear first?

### The guard you were looking for does not exist

`UnitloadBusinessService.sendToClearing`:

```java
public void sendToClearing(Unitload unitload, String activityCode, String comment, String orderNumber) throws FacadeException, BusinessException {
    Location clearingLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_CLEARING).orElseThrow(...);
    transferUnitLoadToLocation(unitload, clearingLocation, true, activityCode, comment, orderNumber);
}
```

`ignoreLock` is hard-coded `true`. In `transferUnitLoadToLocation` that flag gates **both** of the method's lock-aware steps, and they are the only ones:

```java
if (!ignoreLock) {
    destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId).orElseThrow(...);
    entityManager.refresh(destinationLocation);
}
// if we should check lock state before transfer && if lock state of destinationLocation is other than 0 or 301
if (!ignoreLock && destinationLocation.getEntityLock() != BusinessObjectLockState.NOT_LOCKED) {
    throw new FacadeException("STORAGELOCATION_LOCKED", ...);
}
```

Both are about the **destination Location**, never the unit load and never its stock.

**Method that derived "no other `entity_lock` read on this path":** I read the full bodies of `transferUnitLoadToLocation` (lines ~159-280 of the `origin/develop` blob) and both `processTransfer` overloads (~433-483) and inspected every conditional. `processTransfer`'s only branch is `PickLineActivityCodeClassifier.classify(activityCode, null) == BLOCK_REALIGN`; nothing in it touches `getEntityLock()`. **Blind spot:** `unitloadRecordService.recordForTransferUnitLoad` and `replenishmentOrderSourceSyncService.syncForMovedStockUnit` are called from inside `processTransfer` and I did not read their bodies; if either refuses on a lock state, my "no guard" claim narrows. Positive control for the read: the same sweep *did* surface the `destinationLocation.getEntityLock()` check and the `destinationUnitload.getEntityLock() != null` check in `StockunitBusinessService` — so the instrument does find `entity_lock` reads when they exist.

So: **the two siblings' opposite orderings are both guard-legal, and the divergence is unexplained by anything in the code.** Any plan sentence of the form "sendToClearing refuses a locked tote" would be false.

### The ordering that *does* matter: lock order

`CODE_TRANSFER` — the activity code **both** siblings pass to `sendToClearing` — is in the **BLOCK_REALIGN** bucket:

```java
static final Set<String> BLOCK_REALIGN_CODES = Set.of(
    WmsConstants.CODE_MOVE_FIX_ASSIGNMENT,
    WmsConstants.CODE_MANUAL_TRANSFER,
    WmsConstants.CODE_TRANSFER,
    WmsConstants.CODE_ON_HOLD);
```

(`PickLineActivityCodeClassifier.java`.) That makes `transferUnitLoadToLocation` open with a **pessimistic `Pickingorder` acquisition before any write**:

```java
// SBDEV-2481 Hook A — owning-Pickingorder PRE-WALK lock (before any write / any other lock).
if (PickLineActivityCodeClassifier.classify(activityCode, null) == PickLineActivityCodeClassifier.Bucket.BLOCK_REALIGN) {
    List<Long> treeStockUnitIds = pickLineRealignmentService.collectStockUnitIdsForUnitloadTree(unitload);
    pickLineRealignmentService.lockOwningPickingorders(treeStockUnitIds);
}
```

and, per stock unit inside `processTransfer`, a **throw site**:

```java
for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId())) {
    pickLineRealignmentService.assertNoActivePickFor(movedStockUnit.getId());
    pickLineRealignmentService.realignForMovedStockUnit(movedStockUnit, unitload, destinationLocation);
    replenishmentOrderSourceSyncService.syncForMovedStockUnit(movedStockUnit, destinationLocation);
}
```

That gives the real ordering constraint. Clearing the stock locks **first** (`forceCancelOrder`'s arrangement) issues `Stockunit` UPDATEs — i.e. takes `Stockunit` row locks — **before** `sendToClearing`'s `Pickingorder` pre-walk. That is `Stockunit`-before-`Pickingorder`, the inversion the anchor comment in `StockunitBusinessService.transferStockToUnitLoad` exists to forbid:

```java
// Canonical lock order is Pickingorder BEFORE Stockunit/Unitload/
// Location — acquiring the PO lock here (not after the SU lock) preserves that order and avoids
// inverting it.
```

`cleanUpCancelledOrder`'s arrangement — `sendToClearing` first, stock-lock clear after — preserves it.

### Verdict

**Adopt `cleanUpCancelledOrder`'s ordering: `sendToClearing(tote)` FIRST, then `findByUnitloadId` → `setEntityLock(NOT_LOCKED)` → `saveAll`, then `historytote` + null `pickingtote_id`.**

Two honest caveats, both of which you should put in the plan rather than let a reviewer discover:

- **The inversion is theoretical on this data.** `lockOwningPickingorders` keys on `pickingorderPositionRepository.findByPickfromstockunitId(<tote stock id>)`. Tote stock is *pick-**to*** stock; `pickfromstockunit_id` points at the **source** stock at the pick location. And by the time the teardown runs, `cancelOrderPosition` has already executed `pickingPosition.setPickfromstockunitId(null)` on every line of this order. So the pre-walk almost certainly locks **zero** orders and `assertNoActivePickFor` almost certainly matches **zero** rows. *Needs a query* (yours, not mine): `SELECT count(*) FROM pickingorder_position WHERE pickfromstockunit_id IN (<the 7 stockunit ids>);` — expect 0. **A zero here needs a positive control**: run the same query against a stockunit you know backs a live pick line, and confirm it returns non-zero, or the zero is indistinguishable from a broken query.
- Choosing `cleanUpCancelledOrder`'s order costs nothing even if the pre-walk is always empty, and it matches the more recently hardened sibling. Choose it on those grounds, not on a guard.

**What breaks under the other ordering:** nothing observable today, for the reason above. Do not write "X breaks" in the plan — write "it inverts the canonical order for no benefit."

---

## Q2 — `sendToClearing` on a tote that still carries stock

**Yes, it moves a non-empty tote, and that is the designed behaviour.** There is no emptiness guard on this path. The contrast is explicit and is the strongest evidence:

- `sendToNirvana` — the retire path — refuses: `throw new BusinessException("Can not delete. unitLoad=" + unitload.getId() + " has stock!");`
- `relocateEmptiedContainer` — the empty-pool path — refuses: `"Can not relocate. unitLoad=" + unitload.getId() + " has stock!"` under the comment *"Same emptiness guards as sendToNirvana — never relocate a container that still holds anything."*
- `sendToClearing` — **no such guard**, by design.

The goods move with the tote because **stock has no location of its own**: `Stockunit.java` declares `@Column(name = "unitload_id") private Long unitloadId;` and no storage-location field. `processTransfer` sets `unitload.setStoragelocationId(destinationLocation.getId())` and that is the whole move.

**Clearing is the right destination.** `WmsConstants.STORAGE_LOCATION_CLEARING = "Clearing"` and the row is seeded in the base schema (`V2.2.00__base_v2_schema.sql:2462`, described as *"This is a system used entity. DO NOT REMOVE OR LOCK IT!"*). Both siblings send cancelled-order totes there with `CODE_TRANSFER`. The stock does **not** need to go anywhere else first — Clearing *is* the "goods whose order died, a human must disposition them" lane, and it is where SBDEV-3316's reversal surface expects to find them.

**⚠ Argument-order note (pre-existing, do not "fix" in this ticket).** `sendToClearing(Unitload, activityCode, comment, orderNumber)` forwards as `transferUnitLoadToLocation(unitload, clearingLocation, true, activityCode, comment, orderNumber)` but the callee's signature is `(…, String activityCode, String orderNumber, String comment)`. The last two are transposed, so `forceCancelOrder`'s `sendToClearing(pickingTote, CODE_TRANSFER, null, customerOrder.getNumber())` records `order_number = null` and `comment = <order number>` on the unit-load record. Copy the sibling's call shape verbatim; correcting the swap here would silently change `unitload_record` semantics for every existing caller and belongs on its own ticket.

---

## Q3 — Collision with the RAPID_PICKING pre-branch

**No collision, provided you carry two guards.**

The pre-branch (`CustomerorderService.java`, the `SectionPickingType.RAPID_PICKING && state == ASSIGNED && historytote != null` block) only touches the tote inside a doubly-nested condition:

```java
if (pickingOrder.getState() == WmsConstants.State.STARTED) {
    …
    // SBDEV-2102 follow-up: pick-pack orders can be cancelled without ever having a tote.
    if (customerOrder.getPickingtoteId() != null) {
        Unitload pickingTote = unitloadRepository.findById(customerOrder.getPickingtoteId()).orElseThrow(…);
        …
        if (!stockUnits.isEmpty() || !unitLoads.isEmpty()) { throw new BusinessException("tote=" + pickingTote.getLabelid() + " not empty"); }
        unitloadBusinessService.sendToNirvana(pickingTote, WmsConstants.CODE_CANCELLED_ORDER_FROM_WEBSERVICE, customerOrder.getNumber(), null);
        customerOrder.setPickingtoteId(null);
    }
}
```

On the only route where it retires the tote it **also nulls `pickingtote_id` on the same in-memory instance** the later teardown reads. So:

- **G1 (mandatory): guard the new teardown on `customerOrder.getPickingtoteId() != null`.** This is the SBDEV-2102 guard both siblings already carry, and it is *simultaneously* the double-teardown guard and the pick-pack null guard. With it, a tote already sent to nirvana is structurally unreachable from the new block. No second flag, no `historytote != null` test, no re-read.
- Every other exit from the pre-branch (section not RAPID / state ≠ ASSIGNED / `historytote == null` / `pickingOrder.getState() != STARTED`) leaves the tote fully intact — which is precisely the population the new teardown exists for. **This is also why the pre-branch cannot be widened into the fix**: it fires only for RAPID_PICKING at ASSIGNED, and it *throws* on a non-empty tote, which is the exact state of all 7 of your stuck stockunits.

- **G2 (mandatory, and this is where you must NOT copy the sibling):** `forceCancelOrder` writes

  ```java
  if (pickingTote.getEntityLock() != WmsConstants.BusinessObjectLockState.GOING_TO_DELETE) {
  ```

  `Unitload.getEntityLock()` returns **`Integer`** (`model/Unitload.java:37`) and `BusinessObjectLockState.GOING_TO_DELETE` is `int`, so this **unboxes and NPEs on a null**. `unitload.entity_lock` is declared `entity_lock integer` in `V2.2.00__base_v2_schema.sql:1107` — **nullable, no default**. The codebase already knows the rule and states it, in `relocateEmptiedContainer`: *"entityLock is a nullable Integer — compare null-safely (Integer.equals), never `!= int` (auto-unbox NPE)."* Write the new guard as `!Integer.valueOf(BusinessObjectLockState.GOING_TO_DELETE).equals(tote.getEntityLock())`.
  *Needs a query:* `SELECT count(*) FROM unitload WHERE entity_lock IS NULL;` on Hydra PRD — if non-zero, `forceCancelOrder`'s line is a live NPE and is its own (sub-T3) finding for the existing ticket.

  Note the divergence you are arbitrating: `forceCancelOrder` carries the `GOING_TO_DELETE` guard, `cleanUpCancelledOrder` does **not**. Carry it. Without it, a tote already retired by some other path (label mangled to `<label>-X-<id>`, lock `GOING_TO_DELETE`) but still referenced by `pickingtote_id` would be resurrected onto Clearing. With G1 in place that is a narrow window, but the guard is one line.

- **G3 (mandatory, easy to forget): set `historytote` before nulling the pointer.** Both siblings do (`customerOrder.setHistorytote(pickingTote.getLabelid())`). It is the only surviving link from the cancelled order to the tote once `pickingtote_id` is null, and `cleanUpCancelledOrder` consumes it downstream via `pickingorderUnitloadService.getByLabel(tote.getLabelid())`. Omitting it converts your current "visibly stuck" signature into the *invisible* one `cancelBatch` already produces (§Sibling sweep).

**Open design question you must decide, not inherit:** `cleanUpCancelledOrder` additionally sets the `PickingorderUnitload` to `historytote = <label>, unitloadId = null, state = CANCELED`; `forceCancelOrder` does not. Recommendation: **do not** replicate it in `cancelOrder`. Severing `pickingorder_unitload.unitload_id` is what the large SBDEV-3316 warning comment protects — the `picktounitload_id -> pickingorder_unitload.unitload_id -> stockunit` hop in `CancellationLogService.resolvePicktoStockunitId` is the reversal surface's only route to the goods. `cancelOrder` writes its cancellation-log rows *inside* `cancelOrderPosition` (which calls `recordCancellation`), i.e. strictly before any teardown you add, so the log is safe either way — but leaving the link intact keeps the goods resolvable in Clearing. If you do replicate it, it must go **after** the teardown and the plan must say why.

---

## Q4 — Transaction + outbox + deadlock

**No new lock-order inversion — conditional on placing the teardown after the `cancelOrderPosition` loop.** That placement is load-bearing, not cosmetic.

Acquisition chain `cancelOrder` already establishes, in order:

1. **CustomerorderBatch** — `clubRunCancellationBlockingState` does `customerorderBatchRepository.findByIdForUpdate(customerOrder.getOrderbatchId())`, at step 1.5, before anything else.
2. **Pickingorder** — `cancelOrderPosition` does `pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())`, twice (validation pass, then the mutation pass).
3. **Stockunit** — `cancelOrderPosition` does `stockunitRepository.findByIdForUpdate(pickingPosition.getPickfromstockunitId())` inside `changeReservedAmount`'s caller block.

The teardown adds: **Pickingorder** (the BLOCK_REALIGN pre-walk, empirically zero rows — see Q1) then **Unitload/Stockunit** writes. Both sit at or below what is already held, and the pre-walk puts PO before UL/SU *within* the teardown. **Batch ⊃ Pickingorder ⊃ Stockunit/Unitload/Location holds end to end.**

Against the concurrent move path there is no cycle, and the anchor comment says why:

> the move path locks PO→SU/UL/Location and **NEVER touches CO/CustomerorderBatch**, so there is no CO↔PO lock cycle between move and pick-confirm and the two cannot deadlock. … A future change that makes a move touch CO/CustomerorderBatch would reintroduce the cycle — guard against it.

Your fix does not make a move touch CO/Batch — it makes a **CO path perform a move**, which is the safe direction (outer holds more, in the same order).

Additional facts worth putting in the plan:

- **No `Location` lock is taken.** `ignoreLock=true` skips `locationRepository.findByIdForUpdate` on the destination, so the shared `Clearing` row is **not** a serialization point. This is deliberate — the comment says *"Skipped on ignoreLock=true to avoid serializing all discards through the shared nirvana-location row."* Do not "harden" it to `ignoreLock=false`: that would both serialize every cancel on one row **and** start enforcing `STORAGELOCATION_LOCKED` on Clearing.
- **Same transaction, as required.** `cancelOrder` is `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`; `transferUnitLoadToLocation` and `sendToClearing`'s callee carry the same manager with default REQUIRED propagation, so they join. No `REQUIRES_NEW` anywhere on this path — good, given the known wms2 "REQUIRES_NEW inside a lock-holding tx = undetectable deadlock" failure mode. The outbox `enqueue` is unchanged and still lands in the same tx after the teardown.
- **Rollback semantics tighten, and that is a real behaviour change.** Today the success branch cannot fail after `customerorderRepository.save`. After the fix, a teardown throw rolls back the `CANCELED` state *and* the outbox row — i.e. the cancel becomes all-or-nothing across WMS state and the OMS notification. That is the correct shape (it is what `CancelOrderRollbackIntegrationTest` already pins for the "post-cancel cleanup throws" case, `:187` — *"cancelOrder should not post to OMS when post-cancel cleanup throws (F5)"*), but it means new throw sources are new *cancel refusals*, not new partial states. Enumerate them (Q6).

**Deadlock risk: low, and not new.** The one thing I cannot rule out from source is whether `replenishmentOrderSourceSyncService.syncForMovedStockUnit` (reached per tote stock unit under BLOCK_REALIGN) takes locks of its own — I did not read it. **That is the single highest-value remaining read before you finalise the plan**; if it locks `Replenishorder`, the plan needs a sentence placing `Replenishorder` in the chain.

---

## Q5 — Does `cancelOrderPosition` stay untouched?

**Yes. Your conclusion is right; your stated reason is not.**

"It stays position-scoped and must not clear" implies there are other callers whose contract you would break. There are not. `git grep -n "cancelOrderPosition(" origin/develop -- 'src/main'` returns exactly three lines: the declaration at `CustomerorderPositionService.java:118`, one call at `CustomerorderService.java:818`, and a comment at `:822`. **One production caller.** (Blind spot: a reflective or SpEL invocation would not appear; none is plausible here, and Spring Data REST does not export service methods.)

The reasons that actually hold, best first:

1. **Cardinality.** The teardown is order-scoped; the loop runs once per `CustomerorderPosition`. Inside the loop it would execute N times, with only the first finding a non-null `pickingtote_id` — correct by accident, via the guard, on a path where nothing states the invariant. That is exactly the shape that rots.
2. **It would create the Q1 inversion.** Teardown on position 1 issues `Unitload`/`Stockunit` writes; `cancelOrderPosition` on position 2 then acquires a `Pickingorder` lock. SU-before-PO, per position. Keeping it after the loop keeps the chain monotone.
3. **The rest of the block is already order-level.** `historytote`, `pickingtote_id`, the `ORDER_BATCH_CANCELLED_FROM_WMS` outbox row and `finalizeBatchIfComplete` all live in `cancelOrder`. The teardown belongs with them.
4. **No new dependency is needed where it belongs.** `CustomerorderService` already injects `unitloadBusinessService` (it calls `sendToClearing` at the `forceCancelOrder` site and `sendToNirvana` in the RAPID pre-branch) and `stockunitRepository`. Putting it in `CustomerorderPositionService` would mean wiring `UnitloadBusinessService` into a service that currently injects only repositories plus `StockunitBusinessService` / `CancellationLogService` — new DI surface, and `PickLineRealignmentService`'s class javadoc is an explicit warning about how service→service edges in this neighbourhood become hard startup failures (*"there is no `spring.main.allow-circular-references`, so a service→service cycle is a hard startup failure"*). I did not find an actual cycle, so this is a caution, not a blocker.

**Steelman for the other side, since you asked me to argue it:** the only real case for touching `cancelOrderPosition` would be if a *partial* cancel (some positions cancelled, order still live) could strand tote stock. It cannot, on this code — there is no partial entry point; `cancelOrderPosition`'s sole caller cancels every position of the order in one loop and then cancels the order. If a future ticket adds a per-position cancel endpoint, **that** ticket owns the question, and the plan should say so in one line so the next reader does not re-open it.

---

## Q6 — Blast radius

### Call sites and what each applies

**`OrderRestController.cancelPositions` → `:570`** (`POST /rest/order/cancelPositions`, OMS-facing). Guards before the call: `validateWarehouse(orderBatch)`; non-null/non-empty `batchId` and `positions`; batch must exist by `findByBatchid`; each `order.uniqueId` non-empty; the order must resolve via `findByExternalNumber`. Then:

```java
try {
    customerorderService.cancelOrder(customerOrder, false);
} catch (BusinessException e) {
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.WRONG_STATE, e, WmsConstants.State.getCodeText(customerOrder.getState()), order);
} catch (FacadeException e) {
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);
} catch (Exception e) {
    LOG.error("Unexpected error cancelling order={}: {}", order.getUniqueId(), e.getMessage(), e);
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);
}
```

The catches **re-throw**, so a failure on order *k* aborts the loop — orders `1..k-1` are already committed (neither `OrderRestController` nor its class carries `@Transactional`; `git grep "@Transactional"` over both controller blobs returns nothing, so each `cancelOrder` is its own tenant transaction). **A new throw source therefore converts a previously-total batch cancel into a partial one**, with the remainder reported to OMS as `WRONG_STATE` or `GENERIC_ERROR`. That bare `catch (Exception e)` means the auto-unbox NPE from G2 would surface as `GENERIC_ERROR` with no hint of its cause — another reason to write G2 null-safely rather than copy the sibling.

**`UtilRestController.resetOrdersInReleasedStatus` → `:1089`** (`GET /resetOrdersInReleasedStatus`, an operator/util sweep). It selects `customerorderRepository.findByState(WmsConstants.State.ASSIGNED)` — **every** ASSIGNED (200) order — cancels each, then rewrites order, batch and positions back to `RAW`. It swallows: `catch (BusinessException | FacadeException e) { LOG.error(…); continue; }`.

⚠ **This is the behaviour change you must decide on explicitly.** After the fix, this sweep sends every such order's tote to Clearing, clears its stock locks, stamps `historytote` and nulls `pickingtote_id` — and then resets the order to `RAW`. A RAW order that no longer points at its tote is arguably *more* correct than one pointing at a tote whose goods were just dispositioned (the stock genuinely did move), but it is not what this endpoint does today, and re-releasing those orders will mint new totes. Two defensible answers: (a) accept it and say so in the plan; (b) note it and leave it, since the goods-moved outcome is the honest one. I recommend (a). What is **not** defensible is landing it silently.

### Orders reaching the success branch with no tote — yes, definitely

Three independent populations:

1. **Pick-pack**, named in three separate `SBDEV-2102 follow-up` comments across `CustomerorderService` (`:452`, the RAPID pre-branch) and `PickingorderBusinessService.cleanUpCancelledOrder` (*"pick-pack flows may cancel an order that never had a tote assigned"*), plus `ManageOrderService` (*"pick-pack orders may have no tote assigned"* at two sites). `ManageOrderService` even mints `WmsConstants.NO_TOTE_SENTINEL` for them.
2. **Pre-assignment orders.** Tote assignment happens in `MobilePickingService` (`:559`, `:1188`) and `OrderMonitorViewService:199`; an order cancelled before any of those runs has `pickingtote_id` null.
3. **The Util sweep's ASSIGNED (200) population**, most of which is pre-pick.

`findById(null)` throws `IllegalArgumentException` before returning an `Optional` — the `SBDEV-2102` comment at `:452` spells this out and notes the dead `if (pickingTote != null)` it replaced. **G1 is not optional.**

### New failure modes introduced into an OMS-facing endpoint

Complete list of throw sources the teardown adds, derived by reading `sendToClearing` → `transferUnitLoadToLocation` → `processTransfer` end to end:

| Source | Throws | Trigger |
|---|---|---|
| `locationRepository.findByName("Clearing")` | `EntityNotFoundException` (a `RuntimeException`) | tenant without the seeded Clearing row |
| `locationConstraintService.isUnitloadTypePermitted` | `BusinessException("unitloadTypeNotPermittedOnLocation", …)` | tenant location-constraint config forbids Tote on Clearing's location type |
| `fixLocationAssignmentRepository.findByAssignedlocationId` branch | `FacadeException("CARRIER_NOT_ON_FIXLOC")` / `FacadeException("WRONG_ITEMDATA_FIXASSIGNMENT", …)` | a fix assignment exists on Clearing |
| `assertNoActivePickFor` / `realignForMovedStockUnit` | `BusinessException(PickLineRealignmentService.ACTIVE_PICK_MESSAGE)` | a pick line is backed by tote stock (expected: never — Q1) |
| `processTransfer` recursion | `FacadeException("CARRIER_IS_ITS_OWN_CARRIER" / "CARRIER_HIERARCHY_CYCLE")` | corrupt carrier tree under the tote |
| G2 guard, if copied verbatim | `NullPointerException` → `GENERIC_ERROR` | `unitload.entity_lock IS NULL` |

Clearing **is** seeded in `V2.2.00__base_v2_schema.sql:2462`, so row 1 is unlikely — but *needs a query* per tenant: `SELECT name FROM location WHERE name = 'Clearing';` across all six tenant DBs. Rows 2-3 are per-tenant config and equally query-shaped: `SELECT lc.* FROM location_constraint lc JOIN location l ON l.type_id = lc.storagelocationtype_id WHERE l.name = 'Clearing';` and `SELECT * FROM fix_location_assignment f JOIN location l ON l.id = f.assignedlocation_id WHERE l.name = 'Clearing';`. Both siblings already carry this exposure, but on narrower paths — `cancelOrder` is the wide OMS-facing one.

---

## Sibling sweep — the finding I most want you to act on

**`CustomerorderBatchService.cancelBatch` is a fourth path that cancels orders, and it has the same defect in a worse form.**

```java
// Handle picking tote cleanup
if (customerOrder.getPickingtoteId() != null) {
    Unitload toteUnitload = unitloadRepository.findById(customerOrder.getPickingtoteId()).orElse(null);
    if (toteUnitload != null) {
        pickingorderUnitloadRepository.findByUnitloadId(toteUnitload.getId()).ifPresent(poul -> {
            poul.setState(WmsConstants.State.CANCELED);
            pickingorderUnitloadRepository.save(poul);
        });
    }
    customerOrder.setPickingtoteId(null);
    customerorderRepository.save(customerOrder);
}
```

No `sendToClearing`. No stock `entity_lock` clear. **No `historytote`.** It nulls the pointer anyway.

Why this is worse than the `cancelOrder` bug, and why fixing only `cancelOrder` is incomplete: your PRD signature is *discoverable* — `state=800` **with `pickingtote_id` still populated** is exactly how you found orders 60861 and 159907. `cancelBatch` produces locked stock on a tote that **nothing points at**: `pickingtote_id` null, `historytote` null, `pickingorder_unitload` CANCELED. That residue is invisible to the query that found your seven units. Per the "a guard fences the mechanism you aimed at" rule: enumerate every producer of the outcome, not just the one the ticket named.

`cancelBatch` also releases source reservations in-line (`changeReservedAmount` for `state < PICKED && pickfromstockunit_id != null`) and **swallows** the `FacadeException` with a `LOG.error`, so its own reservation release is already best-effort. It is a separate, older implementation of the same workflow — not a caller of `cancelOrder` and not a caller of `cancelOrderPosition`.

**Two queries that would settle whether this is live** (yours — my MCP servers all timed out):

```sql
-- A: the cancelBatch residue — locked stock on a tote no order references
SELECT su.id, su.entity_lock, u.id AS unitload_id, u.labelid
FROM stockunit su JOIN unitload u ON u.id = su.unitload_id
WHERE su.entity_lock = 100
  AND NOT EXISTS (SELECT 1 FROM customerorder co WHERE co.pickingtote_id = u.id);

-- B: positive control for A — the same shape restricted to your known-bad totes,
--    which MUST return the 7 rows, or query A's emptiness proves nothing
SELECT su.id, su.entity_lock FROM stockunit su WHERE su.unitload_id IN (17662, 37736);
```

Query B is not optional. A zero from A with no positive control is indistinguishable from a broken instrument, and the false zero will agree with the convenient conclusion.

**Recommendation on scope:** `cancelBatch` is its own fix and its own tier assessment. Put it on the **existing** SBDEV-3339 ticket as a proposal with blast radius and cost, ranked **second** behind the `cancelOrder` fix — the `cancelOrder` signature is the one with live evidence and a reachable operator remedy path, and shipping it first is strictly better than shipping neither. Do not fold `cancelBatch` into the same diff: it is a different method, a different transaction shape, and it would double the review surface of a fix that is otherwise ~15 lines.

---

## Why the fix has to be in code at all (severity, for the plan's §1)

The stuck stock has **no operator path out**. `WmsConstants.BusinessObjectLockState.OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD }` (`WmsConstants.java:1516`) — `PICKED_FOR_GOODSOUT` (100) is deliberately excluded, and `CancellationReversalService` says so twice (*"an invented PICKED_FOR_GOODSOUT has no operator path out at all (OPERATOR_REMOVABLE is …"*). And the lock actively blocks the move an operator would attempt:

```java
int lock = sourceStockunit.getEntityLock();
if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
    throw new BusinessException("Source stockUnit=" + sourceStockunit.getId() + " is locked=" + lock);
}
```

(`StockunitBusinessService.transferStockToUnitLoad`, `ignoreLock=false` branch.) So: goods are frozen, the tote is unusable, and the only routes out are a DB edit or a code fix. That is the argument for the ticket.

The lock's origin confirms the invariant the fix restores: `PickingorderBusinessService` sets it on pick confirm —

```java
pickToStock.setEntityLock(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT);
stockunitRepository.save(pickToStock);
```

— i.e. **every path that ends the order without shipping owes a matching clear.** State it in the plan as that invariant, not as "cancelOrder forgot a block". Three of the four cancellation paths discharge it (two correctly, `cancelBatch` not at all); one does not.

---

## Recommended shape (for your §4, not a patch)

In `cancelOrder`'s `orderCanBeCancelled` branch, **after** the `cancelOrderPosition` loop and **before** `customerOrder.setState(CANCELED)` / `save` / `finalizeBatchIfComplete`:

1. `if (customerOrder.getPickingtoteId() == null) → skip entirely` (G1).
2. `Unitload tote = unitloadRepository.findById(...).orElseThrow(EntityNotFoundException)` — matching both siblings.
3. `if (!Integer.valueOf(GOING_TO_DELETE).equals(tote.getEntityLock()))` (G2, null-safe — **not** the sibling's `!=`) then:
   a. `unitloadBusinessService.sendToClearing(tote, WmsConstants.CODE_TRANSFER, null, customerOrder.getNumber())` — **first** (Q1);
   b. `stockunitRepository.findByUnitloadId(tote.getId())` → `setEntityLock(NOT_LOCKED)` → `saveAll` — **second** (Q1);
4. `customerOrder.setHistorytote(tote.getLabelid()); customerOrder.setPickingtoteId(null);` (G3) — outside the G2 branch, so a GOING_TO_DELETE tote still stops being referenced.
5. Do **not** touch `PickingorderUnitload` (Q3 open question), and do **not** touch `cancelOrderPosition` (Q5).

Ordering within the method: after the loop is mandatory (Q4); before `save` keeps the two writes in one flush and matches `cleanUpCancelledOrder`.

**Test note for the gate.** `CustomerorderServiceUnitTest.CancelOrder` currently exercises only the *rejection* branches (already-FINISHED, already-CANCELED, club-batch block) — `git show origin/develop:…/CustomerorderServiceUnitTest.java | sed -n '415,470p'`. There is **no existing test on the success branch's tote handling to break**, and equally none to lean on: the failing test is new, and under `STRICT_STUBS` it will need `unitloadRepository.findById`, `stockunitRepository.findByUnitloadId` and `unitloadBusinessService` stubs that do not exist yet. Mutation-check it by deleting the `saveAll` and confirming red — an assertion that only checks `pickingtote_id == null` will stay green through exactly the bug you are fixing.
