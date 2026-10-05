# SBDEV-3362: architect consult on the forceCancelOrder emitter

- **Lane:** architect (read-only), single question
- **Date:** 2026-09-26
- **Code base:** `origin/develop` @ `d9be4188` in `v2/wms2-api`, fetched just before reading; the local checkout was not used
- **DB evidence:** Hydra PRD, ShipItEZ c1wh UAT, WineCo wsl UAT (read-only)

## Verdict

**GO. The design is sound, with two conditions and one accepted trade.** There is no *sequential* path that makes a second `CO-CANCELLED-<id>` enqueue for a force-cancelled order. The one *concurrent* path turns a transaction that succeeds today (a duplicate, silent no-op) into a rolled-back one. That concurrent path is the same trade `WmsConstants.CANCELLED_IDEMPOTENCY_KEY_PREFIX` already documents and accepts for the other two sites. The payload build cannot hit a null `orderbatchId` in production. The existing reflection unit tests of `forceCancelOrder` will need stubs.

---

## 1. Can a second enqueue on `CO-CANCELLED-<id>` happen for one force-cancelled order?

### 1a. All emitters of the key (search: `git grep CANCELLED_IDEMPOTENCY_KEY_PREFIX` and `git grep CO-CANCELLED` over `origin/develop -- src/main`)

Only two sites exist:
- `CustomerorderService.cancelOrder`, in the direct-cancel block: `.idempotencyKey(WmsConstants.CANCELLED_IDEMPOTENCY_KEY_PREFIX + customerOrder.getId())`
- `PickingorderBusinessService.cleanUpCancelledOrder`: the same expression, inside `// Enqueue OMS confirmation for the deferred cancel path (§4 row 6a).`

No native SQL writes `outbox_message` with that prefix. The only `ON CONFLICT (idempotency_key)` is `RestIdempotencyRepository`, which is a different table.

**Blind spots:** the key is built by string concatenation, so a third emitter that spells the prefix differently (`"CO-" + "CANCELLED-"`) would evade both greps. Also, `src/main` only; tests are not a production producer.

### 1b. Within the same transaction (forceCancelOrder's own call tree)

- **Reachable arm (`state == PACKED || state == PALLETIZED`):** it calls `unitloadBusinessService.sendToClearing(parcel, WmsConstants.CODE_TRANSFER, ...)` and `customerorderBatchService.finalizeBatchIfComplete(...)`. Neither emits the key.
  - `CustomerorderBatchService`'s enqueues use `"CO-PICKING-RELEASED-"`, `"CO-PICKING-STARTED-"`, `"CO-PICKED-"` and `keyPrefix + orderBatchId + "-C" + chunkIndex`.
- **Dead arm (`state < PACKED`):** it calls `pickingorderBusinessService.finishPickingOrder(pickingOrder)`. It does so only *after* `customerOrder.setMarkedforcancellation(false)` and `setState(CANCELED)`.
  - `finishPickingOrder` dispatches on `if (customerOrder.getMarkedforcancellation())`, which is now false. The `else if (customerOrder.getState() != WmsConstants.State.CANCELED)` branch is also skipped.
  - Even if the flag were somehow set, `cleanUpCancelledOrder` opens with the guard `if (customerOrder.getState() != null && customerOrder.getState() == WmsConstants.State.CANCELED) { ... return; }`.
- **Where the helper goes:** after `customerorderRepository.save` and `finalizeBatchIfComplete`, which is last in the method. Nothing runs after it in the same transaction except `cancelOrder`'s `return;`. So nothing inside the transaction can add a second emit.

### 1c. Sequential re-entry after the force-cancel commits

- **OMS re-sends the cancel.** `OrderRestController.cancelPositions` calls `customerorderRepository.findByExternalNumber(...)` per order, outside any transaction (the controller is not `@Transactional`, and its own comment says `open-in-view is false`). A re-send after commit therefore loads `state = 800`, and `cancelOrder` returns at `// 1. Already cancelled → no-op (idempotent)`.
  - The same order listed twice in one request behaves the same way, because the first `cancelOrder` has committed before the second `findByExternalNumber`.
- **cleanUpCancelledOrder via the finishPickingOrder markedforcancellation dispatch, or via cancelOrder's deferred `else` branch.** It is blocked by its entry guard (quoted in 1b). The deferred branch is also unreachable for an order at 800, because `isAlreadyCancelled` returns first.
- **MobilePickingService / MobilePutAwayService / PickingOrderMergeService.** None of them call `cancelOrder`, `forceCancelOrder` or the key. `git grep "cancelOrder("` over `src/main` returns exactly two callers:
  - `OrderRestController.java`: `customerorderService.cancelOrder(customerOrder, false);`
  - `UtilRestController.java`: `customerorderService.cancelOrder(customerOrder, false);`
  - Their only route to the key is `finishPickingOrder` → `cleanUpCancelledOrder`, which is guarded as above.

### 1d. Could the key already exist before the force-cancel? (the key is taken once, but the order leaves 800)

This needs an order to go CANCELED → below 800 → PACKED/PALLETIZED again, while its `CO-CANCELLED-<id>` row is still present. The row survives for 7 days if SENT, and forever if FAILED_TERMINAL, PENDING or FAILED_RETRY, per the `WmsConstants` javadoc.

Writers that move a `Customerorder` state downward:
- **`UtilRestController.resetOrdersInReleasedStatus`: the one real CANCELED → RAW writer.** It runs `customerorderService.cancelOrder(customerOrder, false);` (the direct path, which **enqueues the key**) and then `customerOrder.setState(WmsConstants.State.RAW);`.
  - If such an order is later packed and force-cancelled while the row survives, the new emitter collides and the force-cancel rolls back. Today that force-cancel succeeds.
  - **Not live:** `UtilRestController` is `@Service`, not `@RestController`, so its `@RequestMapping` does not route (see `WmsConstants.java:417` and the project memory). `git grep resetOrdersInReleasedStatus` finds only the definition and `UtilRestControllerUnitTest`. The same hazard already applies to a second *direct* cancel of such an order, so it is not new in kind.
- **`BillofladingService`**, the method containing `customerOrder.setState(WmsConstants.State.PACKED)`: it is preceded by `if (customerOrder.getState() != null && customerOrder.getState() >= WmsConstants.State.PACKED) { throw ...`, so it cannot start from 800.
- **`ParcelMonitorViewService`** and **`MobilePalletizeWriteService.advanceOrderToPalletized`**: both are guarded by `getState() < WmsConstants.State.PALLETIZED`, and 800 is not below 670.
- **Bulk JPQL in `CustomerorderRepository`:** `... WHERE c.id IN :ids AND c.state != 800`, `markClientHasNoSection ... co.state IN (:raw, :futurePickingDate)`, and `releaseDueFutureTransferOrders ... co.state = :futurePickingDate`. All exclude 800.
- **Unmeasured writer:** Spring Data REST. `CustomerorderRepository` is `@RepositoryRestResource(collectionResourceRel = "customerorder", path = "customerorder")`, so `PATCH /v3/customerorder/{id}` can structurally write `state`. I did not probe it; the same blind spot is noted in the `cleanUpCancelledOrder` comment.

**DB check (a zero-scan with a positive control):**

| Tenant | total CO | CO at 800 | flagged at 650/670 | CO at 650/670 now | CO-CANCELLED rows | key present, order ≠ 800 |
|---|---|---|---|---|---|---|
| Hydra PRD | 248 | 9 | 0 | 0 | 1 (SENT) | **0** |
| ShipItEZ c1wh UAT | 111,189 | 1,006 | 0 | 3,896 | 0 (outbox holds 1 row in total) | **0** |
| WineCo wsl UAT | 481,239 | 11,532 | 0 | n/a | 0 | **0** |

The positive control is the Hydra PRD row: the `CO-CANCELLED-%` predicate does match a real key. No tenant has a key on an order that is not at 800, so the 1d hazard has no live instance.

### 1e. Concurrency: the one path that flips success to rollback

**Scenario A: two concurrent cancels of the same PACKED CLUB order** (an OMS double-send, or an OMS retry that overlaps the first request).

1. Both requests load the entity outside a transaction at `state = 650`.
2. `clubRunCancellationBlockingState` calls `customerorderBatchRepository.findByIdForUpdate(customerOrder.getOrderbatchId())` before the type check. That lock serialises the two requests, but the second still holds a **stale detached** entity at 650.
3. So the second request passes `isAlreadyCancelled`, `isPackedOrPalletized` and `isOmsPreQaPackedCancellationAllowed`, and re-runs `forceCancelOrder`.
4. **Today** the second pass succeeds: `Customerorder` has no `@Version` (grep of `Customerorder.java` finds none), so the merge-save overwrites silently.
5. **With the fix**, the second pass's enqueue collides. `OutboxMessage` uses `@GeneratedValue(strategy = GenerationType.IDENTITY)`, so the INSERT runs at `repo.save(msg)` and the violation surfaces inside `enqueue`, not at commit.
6. The second transaction rolls back and `OrderRestController`'s `catch (Exception e)` returns `GENERIC_ERROR`. That also aborts the remaining orders in *that* request's loop; orders earlier in the loop are already committed.
7. Net effect: the first cancel is committed and signalled exactly once, and the second request gets a 500 where today it gets a 200. **This is exactly the trade the `WmsConstants` javadoc accepts:** "The loser then takes `DataIntegrityViolationException` and rolls back wholesale ... Both directions self-heal on retry ... Do *not* 'fix' it with a pre-check SELECT-then-skip." I recommend accepting it.

**Scenario B: force-cancel racing `finishPickingOrder` → `cleanUpCancelledOrder`.** This needs a `markedforcancellation = true` order at 650/670 that still has a finishable picking order. `finishPickingOrder` holds `customerorderRepository.findByIdForUpdate`, and `forceCancelOrder` does not lock the customer order, so the second inserter would block on the unique index and then fail.
- Today this race would already produce a double state write without a double signal. With the fix, the force-cancel side rolls back.
- **Measured zero:** `flagged_packed = 0` on all three tenants. Whether packing refuses a flagged order was not traced; treat Scenario B as unmeasured-structural, not disproved.

---

## 2. Does the helper's payload build break for a force-cancel order?

**Null `orderbatchId`: no, not in production.**
- `customerorder.orderbatch_id bigint NOT NULL` is in `V2.2.00__base_v2_schema.sql`, inside `CREATE TABLE public.customerorder`. No later migration drops the NOT NULL (`git grep orderbatch_id` over `db/migration` found no `DROP NOT NULL`).
- Both production callers pass `cancellationFromWithinWMS = false` (quoted in 1c). So the **only** production route into `forceCancelOrder` is `isOmsPreQaPackedCancellationAllowed`, which returns false on `customerOrder.getOrderbatchId() == null`. It also requires `orderBatchOpt.isPresent() && CLUB.equals(...)`, and that read happens in the same transaction.
- Therefore `customerorderBatchRepository.findById(orderbatchId).orElseThrow(...)` in the helper cannot throw on this path.
- `forceCancelOrder`'s `if (customerOrder.getOrderbatchId() != null)` guard exists only for test-constructed entities. **Recommendation:** keep the helper unguarded, identical to `cancelOrder`'s block. Do not copy the null guard into it: a silent skip would reintroduce the "zero signals" defect for exactly the case the fix exists to cover.

**Positions:**
- The reachable arm already has `List<CustomerorderPosition> coPositions = customerorderPositionRepository.findByOrderId(...)`, but it is scoped inside the `else if`.
- The helper needs the list as a parameter. Either hoist the list, or re-read `findByOrderId` at the call site at the end of the method.
- Either choice gives the same set `cancelOrder`'s block sends: *all* positions, including ones already at 800. `cancelOrder` also passes the full pre-loop `coPositions`, so a force-cancel payload has the same shape as a direct-cancel payload.
- `itemdataService.getById(position.getItemdataId())` and `position.getAmount().intValue()` are **new failure points** on the force path: a missing item, or a null amount, now rolls back a force-cancel that succeeds today. The direct path already carries the same exposure, so this is parity rather than a regression. Mention it in the PR.

**Serialization:** the `catch (IOException e)` arm increments `wms2.outbox.serialize_failed` and throws `FacadeException`, which is in `rollbackFor`. It needs no change.

---

## 3. Other design points (in scope)

1. **The `enqueue` is `Propagation.MANDATORY`** (`OutboxService`: `@Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)`). `forceCancelOrder` is package-private and not `@Transactional`; it runs inside the transaction only because `cancelOrder` is its sole caller.
   - If anyone ever calls `forceCancelOrder` directly from another bean, it throws `IllegalTransactionStateException`. That is a fail-loud outcome, which is acceptable.
   - Put one line in the helper's javadoc saying it requires the caller's tenant transaction.
2. **Unit tests will break:** `CustomerorderServiceUnitTest` reflects into `forceCancelOrder` at two sites (`getDeclaredMethod("forceCancelOrder", Customerorder.class)`).
   - With mocks, `customerorderBatchRepository.findById` returns `Optional.empty()` and `itemdataService.getById` returns `null`.
   - The new tail will therefore throw `EntityNotFoundException`, or NPE at `itemData.getItemNr()`. Stub both, or give the fixtures a batch.
   - This is expected churn, not a design objection. Make sure a fixture failure does not get "fixed" by adding a null guard to the helper (see §2).
3. **Ordering relative to `finalizeBatchIfComplete`:** it matches `cancelOrder`, which also saves, then finalizes, then enqueues, so outbox row order is consistent across both direct paths.
4. **Stale comments to update in the same change** (the rule-not-instance discipline):
   - `forceCancelOrder`'s "Note forceCancelOrder notifies OMS of nothing at all, so 'one cancellation signal per order' is currently ZERO for every force-cancelled order; pre-existing, proposed separately, not fixed here."
   - The `WmsConstants.CANCELLED_IDEMPOTENCY_KEY_PREFIX` javadoc's "Two sites emit it". After the change, the helper is called from two places in `CustomerorderService` plus `cleanUpCancelledOrder`. State the rule ("every path that takes an order to CANCELED emits exactly one, under this key") rather than a count.
   - `cancelOrder`'s `// Note: finalizeBatchIfComplete is called inside forceCancelOrder (v2)` could add "and the OMS signal".
5. **Test the invariant, not the instance:** add a test that a force-cancel enqueues exactly one message with key `CO-CANCELLED-<id>` and process type `ORDER_BATCH_CANCELLED_FROM_WMS`. Mutation-check it by deleting the helper call, and by changing the prefix at one site.

## 4. Search method and blind spots

- **Callers:** `git grep -n "cancelOrder("`, `"forceCancelOrder"`, `"cleanUpCancelledOrder("` over `origin/develop -- src/main`.
  - Blind spots: reflection, and SDR/HTTP-driven entry points; `UtilRestController`'s mappings are unrouted.
- **Emitters:** grep on the constant name and on the literal `CO-CANCELLED`.
  - Blind spot: a key assembled from split literals.
- **State reverters:** `git grep "setState(WmsConstants.State.(RAW|PACKED|PALLETIZED|RESERVED))"` plus JPQL `UPDATE Customerorder`.
  - Blind spots: setters with a computed state variable (e.g. `setState(orderState)`) are not matched by this regex; the SDR PATCH is unprobed; the onboarding shell scripts under `db/v1-to-v2-onboarding` (these are migration-time only: `state=505 WHERE state=510`).
- **DB:** three of the six v2 tenant DBs (Hydra PRD, c1wh UAT, wsl UAT). Not checked: nywh-hydra-uat, nywh-shipitez-uat/prd, c1wh-prd, wineco-dev.
