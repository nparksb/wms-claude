---
ticket: SBDEV-3865
kind: review-security
lane: security (independent, read-only)
head: 938f9ef336234be2d085e6818be82df1efcef219
base: origin/develop b399ae5d (merge-base f85789d4)
worktree: .claude/worktrees/wms2-api/SBDEV-3865
date: 2026-10-22
verdict: the three ticket attacks are CLOSED; 1 Medium (pre-existing sibling, same root), 5 Low
---

# SBDEV-3865 security review: mobile picking judges the stored line

**Scope:** `git diff origin/develop...HEAD -- src/main` at `938f9ef3`. Files: `controller/mobile/PickingController.java`,
`service/mobile/MobilePickingService.java`, `service/PickingorderBusinessService.java` (`confirmPick`), `WmsConstants`,
both message bundles. Every endpoint in `PickingController` was swept for the same root, not only the changed ones.
I also read the design of record (`architect-consult.md`) and the wms2-mobile-ui `origin/develop` call sites.

**Risk level for this change: LOW.** The fix does what it says. What is still open is one pre-existing sibling endpoint (M1)
and a few hardening items.

**Method:** a static trace from each controller to the stock or claim write. I did not run any build or probe. The worktree
was busy, and the static evidence was enough. `pom.xml` is not in the diff, so no dependency audit applies. A secrets grep
of the diff found only test fixtures (a `'x'` password in an IT seed and `TestingAuthenticationToken`).

## Summary

| Severity | Count | Items |
|---|---|---|
| Critical | 0 | |
| High | 0 | |
| Medium | 1 | M1 `GET /releasePickingOrder/{id}` has no ownership check (pre-existing, same root as (b)) |
| Low | 5 | L1 to L5 |

## 1. Are the ticket's attacks closed? (trace)

### (a) `processRapidPickScanSource` moved the posted amount: **CLOSED, at two layers**

`PickingController:136` → `ProcessRapidPickingScanSource` (`@Transactional` tenant TM, rollbackFor Business/Facade) →
`rapidPickingScanSource`. This is a self-call, so its own annotation is inert, but the outer one covers it with the same
rollbackFor:

1. `:1395` `findByIdForUpdate(postedPosition.getPickingorderId())` locks the order named in the body. `:1398`/`:1403` require
   `operatorId != null && lockedtooperator && operatorId == caller`.
2. `:1413` re-reads the stored line *after* that lock. OSIV is off (`spring.jpa.open-in-view=false`) and the posted object is
   a deserialized, unmanaged entity, so this is a real DB read and not a first-level-cache hit.
3. `:1421` `storedPickMismatch` refuses unless the posted `pickingorderId`, `amount` (`compareTo`), `pickfromstockunitId` and
   `picktounitloadId` equal the stored ones. Because `pickingorderId` must match, the order locked and checked in step 1 is
   the stored line's own order.
4. Everything downstream reads the stored `pickingPosition`. `postedPosition` is used after `:1421` only in log and exception
   arguments (grep: `:1390,1394,1395,1399,1404,1413,1414,1421`). That covers the source fallback `getPickfromlocationname()` /
   `getPickfromunitloadlabel()` (`:1447-1448`), the scan check `stockUnit_original` (`:1489`), the PUL (`:1497`), and
   `confirmPick(pickingPosition, pickingorderUnitload, pickingPosition.getAmount(), user)` (`:1498`).
5. The completion DTO returns the stored line (`:1530`, `:1539`). The stray `dto.setPickingorderPosition(pickingPosition)` that
   was overwritten by `pp` is removed. So `ProcessRapidPickingScanSource:1375-1376` now resolve `clientId`/`itemdataId` from
   the stored row. The fields not compared (`clientId`, `itemdataId`, `customerorderpositionId`, `pickfromlocationname`,
   `pickfromunitloadlabel`, `number`) therefore cannot steer anything: none of them is read from the body.
6. `confirmPick` refuses `amountPicked` ≠ stored amount (`PickingorderBusinessService:1323`). It releases the reservation with
   the stored amount (`:1357`) and moves `amountPicked` (`:1370`), so the two must now be equal.

### (b) `resetPickingOrder` cleared any order the body named: **CLOSED**

`MobilePickingService:1558`. Now `@Transactional(tenantTransactionManager, rollbackFor Business/Facade)`, called through the
proxy from the controller. It re-reads the stored line (`:1561`), takes `pickingorderId`/`picktounitloadId` only from the stored
row, locks the order `findByIdForUpdate` (`:1572`), and refuses `operatorId != null && != caller` (`:1574`). The refusal comes
before any setter. The controller gained the `BusinessException` catch (`PickingController:214`).

### (c) `processPick` did not tie the line to the locked order: **CLOSED**

`MobilePickingService:500` refuses `!pickingOrderId.equals(pickingPosition.getPickingorderId())` right after the locked
re-read. That is before `assertPickNotCancelled`, the operator check, and the tote branch (tote create/reclaim, OMS call,
`assignToteToAllPositions`), so nothing has been written. The body here is ids only (`{orderId, orderPositionId, toteName}`), so
there is no posted entity. As defence in depth, `confirmPick` now locks the **stored** line's order first (`:1231`) and refuses
another operator (`:1236`). That also removes the CO→PO inversion a mismatched line used to cause.

### TOCTOU between the re-read and the lock

- **Rapid:** the PO lock is taken before the re-read, and the identity comparison proves the lock covers the stored line. The
  writers that can move a line between orders take that lock as well: `PickingOrderMergeService:58` `findAllByIdForUpdate`, then
  `:171` `setPickingorderId`. `@Version` on `AbstractBaseEntity` backs up anything that does not. **No window found.**
- **Reset:** the line and PUL are read before the PO lock. Their `pickingorderId`/`picktounitloadId` are read once and only feed
  the lookup. The ownership decision is made on the locked row. **Acceptable.**
- **`releasePickingOrder(PickingorderPosition)`:** no lock at all. See L1.

### Refusal paths leave no partial writes

- Rapid: the only write before a refusal is `pickingOrder.setPickinginprogress(true); save` (`:1486-1487`), ahead of the
  "Scan correct source" throw (`:1494`). `BusinessException` is in rollbackFor, so it rolls back. `confirmPick` is a separate
  bean and is proxied with `REQUIRED` plus the same rollbackFor, so a `FacadeException` thrown there marks the shared
  transaction rollback-only. `EntityNotFoundException` is unchecked and also rolls back.
- Reset: there is no write before the refusal.
- processPick: the cross-order refusal comes before any write.
- confirmPick: the new amount, operator and PUL refusals all precede `changeReservedAmount` (`:1357`).

**Verdict: no partial-write path found.**

## 2. Findings

### M1. `GET /v3/picking/releasePickingOrder/{id}` releases or finishes any picking order with no ownership check

**Severity:** MEDIUM. **Category:** A01 Broken Access Control (IDOR). **Pre-existing**, not introduced by this diff.
**Location:** `PickingController.java:255-263` → `MobilePickingService.java:765-852` (`releaseRegularPickingOrder`)
**Exploitability:** remote. Needs an authenticated user holding `MOBILE_UI_VIEW_PICKING` (class-level `@RequiresFunction`). The
only input is a sequential numeric id in the path.
**Blast radius:** this is the same root as attack (b), reached by an id instead of a body. For another picker's order with
nothing picked yet, Case 3 sets `operatorId = null` and `state = PROCESSABLE`. That strips the claim, and the attacker can then
claim the order themselves through `rapidPickingScanPackage` (`:1223`) or `getPickingOrderPositionsInfo`. For a fully picked
order, Case 2 finishes it and fires the OMS picking-finished path. No stock moves, because every pick is still the stored line
under the fixes above, so this is workflow hijack and disruption, not inventory corruption.

```java
// MobilePickingService.java:768 — no lock, no operator check
Pickingorder pickingOrder = pickingorderRepository.findById(pickingOrderId).orElseThrow(...);
...
// Case 3: No positions picked — reset to pool
if (!anyPicked) {
    pickingOrder.setOperatorId(null);
    pickingOrder.setState(WmsConstants.State.PROCESSABLE);
```

Its sibling `getPickingOrderPositionsInfo` (`:858-863`) already does the right thing: `findByIdForUpdate` plus null-or-caller.
**Remediation**, which matches the only UI caller (`wms2-mobile-ui components/picking/pick.vue:271`, which releases the order
the operator is on):

```java
Pickingorder pickingOrder = pickingorderRepository.findByIdForUpdate(pickingOrderId)
    .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingOrderId));
User user = userRepository.findByName(SecurityContextUtils.getUserName())
    .orElseThrow(() -> new EntityNotFoundException("User not found by name: " + SecurityContextUtils.getUserName()));
if (pickingOrder.getOperatorId() != null && !user.getId().equals(pickingOrder.getOperatorId())) {
    throw new BusinessException("Picking order " + pickingOrder.getNumber() + " is assigned to another user");
}
```

Put it after the Case 1 early return if the OMS re-enqueue safety net should stay open to anyone.
**Scope:** this is the same root on the same controller and costs about three lines. Because it is authz, `wms-triage` may grade
it T3, so **propose it to Nam rather than file it.** My preference is to fold it into SBDEV-3865 if he agrees. The ticket is not
yet `on dev`, so the carve-out does not apply.

### L1. `releasePickingOrder(PickingorderPosition)` (`/processRapidPickScanSourcePass`) is not transactional and takes no lock

**Severity:** LOW. **Category:** A04 Insecure Design (TOCTOU). **In scope** (cheap).
**Location:** `MobilePickingService.java:1616-1635`

```java
public void releasePickingOrder(PickingorderPosition postedPosition) throws BusinessException {
    ...
    Pickingorder pickingOrder = pickingorderRepository.findById(pickingPosition.getPickingorderId())...;
    if (pickingOrder.getOperatorId() != null && !user.getId().equals(pickingOrder.getOperatorId())) { ... }
    pickingOrder.setLockedtooperator(false); ... pickingorderRepository.save(pickingOrder);
```

The fix correctly moved the order source to the stored line. But the read, the check and the write run in three separate
repository transactions (OSIV is off). If another user claims the order between the check and the save, the window is only
closed by `@Version`. `save` merges the detached, stale-version copy, which throws `ObjectOptimisticLockingFailureException`,
and the controller reports that as "Conflict". So this is bounded and not exploitable today. It is still inconsistent with the
`resetPickingOrder` hardening on the same ticket, and it depends on every claimer bumping the version.
**Remediation:**

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void releasePickingOrder(PickingorderPosition postedPosition) throws BusinessException {
    ...
    Pickingorder pickingOrder = pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())...;
```

### L2. Rapid path: the stale-state branch runs before the order-identity comparison, which gives a cross-order oracle

**Severity:** LOW. **Category:** A01 / information disclosure. **In scope** (reorder).
**Location:** `MobilePickingService.java:1415-1426`

```java
if (pickingPosition.getState() != null && pickingPosition.getState() >= WmsConstants.State.PICKED) {
    pickingorderBusinessService.assertPickNotCancelled(pickingPosition);
    throw new FacadeException("PICK_ALREADY_FINISHED", "");
}
String mismatch = storedPickMismatch(postedPosition, pickingPosition);
```

The order lock and the operator check apply to the **posted** `pickingorderId`, which is the caller's own order. The stored line
is then read by any posted `id`. For a line on another order, the caller gets `PICK_CONFIRM_ORDER_CANCELLED` (which carries the
pick number) or `PICK_ALREADY_FINISHED` before the "picking order" mismatch is reached. The mismatch message also echoes the pick
number of any line on another order (`"Pick " + pickingPosition.getNumber() + " does not match..."`). Nothing is written, so this
is an enumeration oracle only.
**Remediation:** compare the identity first, then handle staleness.

```java
if (!Objects.equals(postedPosition.getPickingorderId(), pickingPosition.getPickingorderId())) {
    throw new BusinessException("The pick is not on this picking order. Scan the pick again.");
}
if (pickingPosition.getState() != null && pickingPosition.getState() >= WmsConstants.State.PICKED) { ... }
String mismatch = storedPickMismatch(postedPosition, pickingPosition);
```

Make sure the existing `rapidPickingScanSource_shouldRefuse_whenTheStoredPositionIsOnAnotherPickingOrder` fixture has the stored
line at state < PICKED. If it does, the test never sees this ordering, so add a PICKED-state variant.

### L3. Refusal messages disclose operator identity

**Severity:** LOW. **Category:** information disclosure. **New strings in scope; old ones backlog.**

- New: `messages.properties` `PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR=Picking order %1$s is assigned to another user (%2$s).`,
  where `%2$s` is `pickingOrder.getOperatorId()` (`PickingorderBusinessService:1240`).
- New on the reset path: `throw new BusinessException("Parcel assigned to user " + pickingOrder.getOperatorId());` (`MobilePickingService:1575`).
- Pre-existing, and these leak the **username**: `releasePickingOrder` `:1628` `operator.getName()`, `processPick` `:517`,
  `getPickingOrderPositionsInfo` `:862`, `rapidPickingScanPackage` `:1226`.

The new keys are defence in depth that both callers pre-empt, so the id is close to unreachable in practice. Still, there is no
reason to put an internal user id into a handheld message. In-warehouse names may be wanted operationally. That is a product
call, and it should be made in one place instead of drifting endpoint by endpoint.
**Remediation:** `PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR=Picking order %1$s is assigned to another user.`, with the
operator id moved to the existing `LOG.warn`. Do the same for `:1575`.

### L4. "Null or caller": an unclaimed order can be picked through `processPick` without a claim

**Severity:** LOW (accepted design; record it, do not fix it here). **Category:** A04. **Separate ticket if wanted.**
**Location:** `MobilePickingService.java:514`, `PickingorderBusinessService.java:1236`

`processPick` (and therefore `confirmPick`) accepts `operatorId == null`, and it never claims the order. Any picker with the
function can pick lines of any unclaimed picking order in any section without going through
`startPickingOrder`/`getPickingOrderPositionsInfo`. Stock integrity holds: the amount, the stock unit and the tote are all the
stored line's, and each line is serialised by the PO lock. So the exposure is workflow bypass and attribution, not inventory.
`pickedbyoperatorId` is still recorded (`:1390`). On `resetPickingOrder` the unclaimed case is **not a hole**. With
`operatorId == null`, reset only clears `lockedtooperator`/`pickinginprogress`, and that state (an orphan lock) is exactly what
the SBDEV-3205 notes say should be healed. The architect consult §4 item 4 already records this as deliberate. Tightening it to
"must be the caller" for `processPick` changes behaviour and breaks two ITs.

### L5. `processRapidPickScanPackageToVerify` still acts on the posted `picktounitloadId`

**Severity:** LOW. **Category:** A01 / same root, read-only. **In scope (trivial) or backlog.**
**Location:** `MobilePickingService.java:1637-1645`

```java
PickingorderUnitload pickToUnitLoad = pickingorderUnitloadRepository.findById(pickingPosition.getPicktounitloadId())...
if (! packageName.equals(unitLoad.getLabelid())) { throw new BusinessException("Scan correct parcel"); }
```

There is no write, no transaction and no ownership check. A crafted body turns it into an oracle: a PUL id plus a label
returns match or no match, and a nonexistent id returns not-found. The follow-up `resetPickingOrder` that the UI dispatches on
success (`store/picking.js:403`) now re-reads the stored line, so the oracle cannot be chained into a write. It is the last
consumer of a posted pick entity in this controller. Closing it finishes the sweep "by construction".
**Remediation:**

```java
requirePositionId(pickingPosition);
PickingorderPosition stored = pickingorderPositionRepository.findById(pickingPosition.getId())
    .orElseThrow(() -> new EntityNotFoundException("PickingOrderPosition", pickingPosition.getId()));
// then use stored.getPicktounitloadId()
```

## 3. Robustness notes (not security, no finding)

- Rapid: a body with `id` set but `pickingorderId` null reaches `findByIdForUpdate(null)` (`:1395`). That raises
  `IllegalArgumentException` / `InvalidDataAccessApiUsageException`, which is a 500 through `RestExceptionHandler` and not a
  handheld error. Nothing is written. `requirePositionId` could also require `getPickingorderId() != null`.
- `PickingController:345-346` casts `(String) reqMap.get("orderId")` / `(Integer) reqMap.get("orderPositionId")`. A malformed body
  gives a 500 `ClassCastException` / `NumberFormatException`. This is pre-existing.
- `pickingOrder.getLockedtooperator()` is unboxed at `:1398`, so a null column gives a 500 NPE. This is pre-existing.

## 4. Endpoint sweep: `PickingController` × "acts on a client-supplied entity or id without ownership"

| Endpoint | Input | Ownership after this diff | Status |
|---|---|---|---|
| `POST /processRapidPickScanSource` | body `PickingorderPosition` | locked order, caller==operator, stored line, identity compare | **fixed** (L2 ordering) |
| `POST /processRapidPickScanSourcePass` | body `PickingorderPosition` | stored line's order, null-or-caller, no lock | fixed source (**L1**) |
| `POST /processRapidPickScanPackageToVerify` | body `PickingorderPosition` | none; read-only | **L5** |
| `POST /resetPickingOrder` | body `PickingorderPosition` | stored line, locked, null-or-caller | **fixed** |
| `POST /processPick` | ids | locked order, line∈order, null-or-caller | **fixed** (L4 by design) |
| `GET /releasePickingOrder/{id}` | path id | **none** | **M1** |
| `GET /pickingOrderPositionsInfo/{id}` | path id | locked, null-or-caller | ok |
| `GET /processLocation/{id}/{input}` | path id | read-only tx | ok (no write) |
| `GET /processRapidPickScanPackage/{section}/{input}`, `.../ScanPackageAndType` | scan strings | claim refuses another locked operator (`:1223`) | ok (out of scope) |
| `GET /pickingOrders/{input}`, `/pickTimeOutValue` | strings | read-only | ok |

## 5. Test evidence (read, not run)

New tests cover each attack: the IT `MobilePickingJudgesTheStoredPositionIT` (amount 7-vs-2 refused, stored amount moved, reset
refused for another operator, reset uses the stored order). Unit tests cover the rapid mismatches on all four fields plus no-id,
already-finished and the cross-order line, `processPick` cross-order, reset and release on the stored order, and `confirmPick`
on amount (including scale), operator, PUL and lock order. Gaps: there is no test that the completion DTO carries the **stored**
`clientId`/`itemdataId` (`ProcessRapidPickingScanSource:1375`). There is no test for M1, L1 or L5, which is expected because they
are not fixed.

## Security checklist

- [x] No hardcoded secrets in the diff (test fixtures only)
- [x] Inputs validated. The posted entity is reduced to an id and compared on every field it could steer.
- [x] Injection: none. All access goes through Spring Data finders, no string-built queries in the diff.
- [~] Authorization: the three ticket paths are closed. **M1** is still open on the same controller.
- [x] Refusal paths roll back fully (rollbackFor Business/Facade; unchecked exceptions roll back by default)
- [x] Dependencies: `pom.xml` unchanged, no audit applicable
- [~] Error messages: L3 (operator id/name disclosure)
