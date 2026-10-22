---
ticket: SBDEV-3865
kind: architect-consult
tier: T2
base: origin/develop c274db50 (worktree .claude/worktrees/wms2-api/SBDEV-3865)
date: 2026-10-21
---

# SBDEV-3865 — architect consult: where do the pick invariants live?

**Verdict: (c) both, split by what each layer can know.** confirmPick owns the invariants that
any caller could break and that it can check from stored rows alone (amount, ownership of
the stored line's picking order, lock order). The callers own the invariants only they can see
(what the operator physically scanned, which order they locked, which tote). Neither layer is
enough by itself, for the reasons in §2.

## 1. What the code does today (quoted, origin/develop c274db50)

`PickingorderBusinessService.confirmPick`:

- Re-reads the stored line: `pickingPosition = pickingorderPositionRepository.findById(pickingPosition.getId())`.
  From here on the line's **stock unit, customer-order line and picking order all come from the stored row**.
  Only `amountPicked` and `pickingUnitLoad` still come from the caller.
- Releases the reservation with the **stored** amount:
  `stockunitBusinessService.changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(), ...)`
- Moves and books the **caller's** amount:
  `transferStockToUnitLoad(stockUnit, puUnitLoad, amountPicked, ...)`, `pickingPosition.setAmountpicked(amountPicked)`,
  `customerOrderPositionAmountAlreadyPicked.add(amountPicked)`. That split is the DEV 7-vs-2 defect.
- Locks in this order: the customer order (`LockReads.forUpdate(... Customerorder.class ...)`), then the
  customer-order line (SBDEV-3729), and only then the picking order:
  `pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())`. The comment there says it
  "re-takes a lock this transaction already holds". That is true only if the caller locked **the stored line's**
  order. Neither caller checks this.
- Checks the PUL only at order level: `if (!pickingOrder.getId().equals(pickingUnitLoad.getPickingorderId()))`.
  Any tote on the same picking order passes. A PUL is per customer order
  (`pickingorderUnitloadService.create(pickingOrder, tote, customerOrder.getNumber())`), so on a multi-order
  picking order a forged `picktounitloadId` would put the goods in **another customer's tote**.
- Checks no operator.

`MobilePickingService.rapidPickingScanSource`: locks `findByIdForUpdate(pickingPosition.getPickingorderId())`
(posted), checks `!user.getId().equals(pickingOrder.getOperatorId())`, then compares the scan against the
**posted** stock unit: `stockunitRepository.findById(pickingPosition.getPickfromstockunitId())`, and the
`pickfromlocationname`/`pickfromunitloadlabel` fallback also uses posted fields. confirmPick then moves the
**stored** `pickfromstockunitId`. So the scan check and the stock movement can be about two different stock
units. On completion it returns the posted object (`dto.setPickingorderPosition(pickingPosition)`), and
`ProcessRapidPickingScanSource` uses it for `clientRepository.findById(poPosition.getClientId())` and `itemdataService.getById(poPosition.getItemdataId())`.

`MobilePickingService.processPick`: locks `findByIdForUpdate(pickingOrderId)`, reads the line by
`pickingPositionId`, checks the operator against the **locked** order, and never checks
`pickingPosition.getPickingorderId().equals(pickingOrderId)`.

`MobilePickingService.resetPickingOrder`: is not `@Transactional`, takes no lock and checks no operator. It
uses posted `getPicktounitloadId()`/`getPickingorderId()`, then
`setLockedtooperator(false); setOperatorId(null); save`. Anyone who knows a tote label and an order id
can strip another picker's claim.

## 2. Why neither (a) nor (b) is enough alone

- **(a) alone** cannot see the scan. The posted-vs-stored `pickfromstockunitId` mismatch and the same-order
  wrong-customer PUL are both invisible inside confirmPick. A "null-or-caller" operator check inside
  confirmPick also lets a line of an **unclaimed** order B through under order A's lock in processPick. It
  also does not restore the "picking order before customer order" lock order unless the picking-order lock is
  hoisted (see §3).
- **(b) alone** fixes today's two callers and leaves the choke point as soft as it is. The SBDEV-3319 G1
  rationale already in confirmPick ("the single stock-moving choke point ... cannot be picked from anywhere")
  applies to amount and ownership just as it does to cancellation. A third caller would bring the bug back.

## 3. Recommendation — concrete

### confirmPick (choke point)

1. **Hoist the picking-order lock above the customer-order lock.** Move
   `pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())` to just after the
   position `findById`, before `copForLockId`. For honest callers it re-takes a lock they already hold, at no
   cost. For a mismatched caller it takes the picking order **before** the customer order, which is the order
   the comments already document ("Pickingorder, then Customerorder"). Today a mismatched call takes the
   customer order and then a picking order it does not hold: an AB/BA inversion of exactly the kind
   SBDEV-3286 and SBDEV-3727 accepted only for the finish clean-up.
2. **Operator check on that locked picking order:** refuse when `operatorId != null && !operatorId.equals(user.getId())`.
   Use **"null or caller", not "must equal caller"**:
   - processPick deliberately allows a null operator (`if (pickingOrder.getOperatorId() != null && !user.getId().equals(...))`).
   - Both picking ITs seed `pickingorder` with no `operator_id` (`PickingorderBusinessServiceConcurrencyIT` and
     `PickingCancelLockReadStaleVersionIT`, the "INSERT INTO pickingorder (... lockedtooperator ...) VALUES (..., false, false ...)" fixtures).
   - Every `confirmPick` unit test leaves the order operator null. The only `setOperatorId(7L/99L)` fixtures are in
     `finishCarriesOperatorAsActor`, `enqueuesOutboxForStrandedCo` and `theCancellationSignalCarriesAPerOrderIdempotencyKey`,
     and none of those calls confirmPick. So "null-or-caller" breaks no existing test. "Must equal" would break the two ITs.
   - No non-mobile production caller exists. confirmPick has exactly two callers, MobilePickingService :649 and :1471.
3. **Amount: keep the parameter and refuse a mismatch** (`amountPicked.compareTo(pickingPosition.getAmount()) != 0`
   → new FacadeException key, for example `PICK_CONFIRM_AMOUNT_MISMATCH`). Put it **after** the existing
   negative and zero guards. That keeps their keyed tests (`AMOUNT_MUST_BE_GREATER_THAN_ZERO`,
   `PICK_CONFIRM_NOT_PICKED_COUNTED`) reaching their own guard, and those fixtures leave the stored amount null.
   Use `compareTo`, not `equals`: `PickingorderBusinessServiceH2Test` uses `new BigDecimal("10.0")`.
   Why keep it rather than remove it:
   - **ArchUnit freeze trap.** `archunit_store/5fb3fee0-...` freezes a violation whose text includes the full signature
     `confirmPick(...PickingorderPosition, ...PickingorderUnitload, java.math.BigDecimal, ...User)`. `archunit.properties`
     sets only `allowStoreCreation=true` (no `allowStoreUpdate`), so a changed signature turns that frozen
     violation into a **new** one and `OptionalSafetyArchTest` goes red. If you do remove the parameter, also replace
     `pickingOrderOpt.isPresent() ? pickingOrderOpt.get() : null` with `.orElse(null)`, which retires the violation.
   - About 40 test call sites (unit, H2, two ITs) and 12 `confirmPick(any(), any(), any(), any())` Mockito stubs stay unchanged.
   - The parameter remains the seam if short-picks are ever allowed. The memory "v2 never short-picks" is a decision about
     today, not a schema property.
   - Removing it is the cleaner by-construction fix. If you choose that, do it as a separate commit with the `.orElse(null)` change.
4. **PUL:** add "stored `picktounitloadId` is null or equals `pickingUnitLoad.getId()`". It **must** be
   null-tolerant. On processPick's first pick, the stored instance is the managed pre-UPDATE copy, and the
   in-code comment says "its picktounitloadId is still the pre-UPDATE value" after the native
   `assignToteToAllPositions`. A strict equality check would refuse every first pick.

### Callers

5. **rapidPickingScanSource:** right after the order lock and the operator check, re-read
   `stored = pickingorderPositionRepository.findById(posted.getId())`. **Refuse** (BusinessException) unless
   `stored.pickingorderId`, `pickfromstockunitId` and `picktounitloadId` equal the posted values and `amount` compares
   equal. Then use `stored` for **everything** downstream: the scan comparison, the location and label fallback,
   the PUL lookup, `confirmPick(stored, pul, stored.getAmount(), user)` and the returned DTO.
   Refuse rather than silently ignore the body: the UI posts the server's own copy
   (`scanSource.vue`: `pickingorderPosition: Object.assign({}, this.positionInfo.pickingorderPosition)`), so a
   mismatch means a stale screen or a forged request, and the operator should rescan. Silently using the stored
   row would confirm a pick the operator never saw on screen.
   One case needs care: a **stale-but-honest** client whose line was already picked. Today it gets
   `PICK_ALREADY_FINISHED` from confirmPick. Compare identity fields only (not `state`/`version`), so that error
   still surfaces instead of a mismatch error.
6. **processPick:** after the locked re-read, refuse when `!pickingPositionId`'s `getPickingorderId().equals(pickingOrderId)`.
   This must come before the tote branch, which creates or reclaims a tote and calls OMS. This, not confirmPick, is
   what stops "a line of unclaimed order B under order A's lock" (§2).
7. **resetPickingOrder:** add `@Transactional(tenantTransactionManager)`. Re-read the stored position by id, and
   use its `pickingorderId`/`picktounitloadId`, refusing a mismatch as in step 5. Lock with `findByIdForUpdate`
   and refuse when `operatorId != null && !operatorId.equals(caller)`.
   **The UI still works.** `store/picking.js` `processRapidPickScanPackageToVerify` dispatches
   `resetPickingOrder` with `pickingorderPosition: Object.assign({}, this.positionInfo.pickingorderPosition)`, which is the
   pre-pick copy. Its `pickingorderId`/`picktounitloadId` never change in a pick. When it fires, rapid's completion branch
   has already run `setLockedtooperator(false); setPickinginprogress(false)` but **not** `setOperatorId(null)`, so the operator is still
   the caller and "null-or-caller" passes. **Do not** add a `lockedtooperator` precondition: it is already false
   at that point and would break the reset.
   The service currently throws nothing checked, so a new refusal must be a `BusinessException`. The controller
   catches only the two locking exceptions, so the controller's catch list has to grow with it. The UI ignores the
   result (`console.log` only), so a refusal is silent to the user, which is acceptable for this cleanup call.

## 4. Risks (ranked)

1. **MobilePickingServiceUnitTest churn.** The rapid tests mock confirmPick and never stub a position
   `findById`, so the new re-read in step 5 throws `EntityNotFoundException` in each existing rapid test until it is
   stubbed. There are 23 references to rapid/reset across 3 test classes. Budget for it, and do not "fix" it with `lenient()`.
2. **ArchUnit freeze** if the signature changes (step 3). It is silent until `OptionalSafetyArchTest` runs.
3. **Lock-hoist behaviour change (step 1).** On the five reject paths, confirmPick now takes the picking-order lock
   before the customer-order lock. Both callers already hold it, so there is no new wait for them. A direct
   test-only caller (the two ITs) now locks the picking order first. Re-run both ITs, which are on the flaky list,
   so re-run once before believing a red. Update the SBDEV-3286 lock comments in confirmPick and processPick
   instead of leaving them to describe the old order.
4. **"Null-or-caller" is deliberately weak.** It refuses only when **another** user owns the order. The stronger rule,
   "must be assigned to the caller", already holds on the rapid path (`getOperatorId() == null || !getLockedtooperator()` → refuse).
   Tightening it for processPick is a behaviour change for the unclaimed-order case and a separate ticket if wanted.
5. **Mismatch false positives.** If any UI path posts a locally modified copy (not found in `scanSource.vue`,
   `scanSourceSimple.vue` or `verifyPackage.vue`), step 5 refuses it. Restricting the comparison to the four
   identity fields keeps that surface small.

## 5. Trade-offs

| Option | Pros | Cons |
|---|---|---|
| (a) confirmPick only | One place; protects future callers | Cannot see the scanned stock unit or the same-order wrong-customer PUL; "null-or-caller" lets an unclaimed cross-order line through |
| (b) callers only | Precise and caller-aware | Choke point stays soft; a third caller brings the bug back; contradicts the SBDEV-3319 G1 choke-point design |
| **(c) both (recommended)** | Each invariant lives where it is decidable; defence in depth for amount and ownership | More test churn (rapid unit tests); two places to keep consistent. Each check is stated once, at the layer that owns it, so it is not duplication |
| Remove `amountPicked` | Wrong amount cannot be passed at all | Signature churn, about 52 sites, ArchUnit freeze trap; loses the short-pick seam |
| Keep + assert | Small diff; mutation-checkable refusal | A parameter that must equal a stored value remains a mild smell |

## References (worktree paths)

- `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` — `confirmPick` (declaration "public Pickingorder confirmPick(PickingorderPosition pickingPosition, PickingorderUnitload pickingUnitLoad, BigDecimal amountPicked, User user)")
- `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java` — `processPick`, `ProcessRapidPickingScanSource`, `rapidPickingScanSource`, `resetPickingOrder`
- `src/main/java/net/aim_ai/wms/controller/mobile/PickingController.java` — `/processPick`, `/processRapidPickScanSource`, `/resetPickingOrder`
- `src/test/resources/archunit.properties`, `src/test/resources/archunit_store/5fb3fee0-6caf-4f48-a5cd-5271da610572`
- `src/test/java/net/aim_ai/wms/service/PickingorderBusinessServiceConcurrencyIT.java`, `PickingCancelLockReadStaleVersionIT.java`
- wms2-mobile-ui `origin/develop`: `store/picking.js` (`processRapidPickScanPackageToVerify` → `resetPickingOrder`), `components/picking/rapid/scanSource.vue`, `verifyPackage.vue`
