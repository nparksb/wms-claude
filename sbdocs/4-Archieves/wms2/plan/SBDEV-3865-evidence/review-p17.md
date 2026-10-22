---
head: 5008d2223b6595e1bcafbd1d006a5529cda13c26
ticket: SBDEV-3865
scope: P17 / security finding M1, GET /v3/picking/releasePickingOrder/{id}
reviewer: independent security + code review lane (did not author the commit)
date: 2026-10-22
---

# Review P17: release-by-id ownership check (commit 5008d222)

**Scope:** `MobilePickingService.releaseRegularPickingOrder` (`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java:765-872`)
and `MobilePickingServiceUnitTest` (5 new tests, 7 re-stubbed, 1 edited case3 test). I read everything from `git show 5008d222:<path>`.
The worktree was clean and HEAD = 5008d222 before and after.
**Risk level for this commit: LOW.** The IDOR is closed for Case 2 and Case 3. I found no new lock inversion and no legitimate flow that breaks.
What is left is one unpinned behaviour and some notes.

## Summary

| Severity | Count | Items |
|---|---|---|
| Critical | 0 | |
| High | 0 | |
| Medium | 0 | |
| Low | 2 | L1 orphan-lock release is unpinned (a mutant survives); L2 the Case 2 refusal test asserts only the exception type |
| Info | 4 | I1 Case 1 open to any caller (safe); I2 refusal names the holder (consistent); I3 Case 4 response changes for a foreign order; I4 no IT for the lock |

## Verdicts on the questions asked

### IDOR closed for Case 2 (finish) and Case 3 (reset to pool): YES
```java
// MobilePickingService.java:772
Pickingorder pickingOrder = pickingorderRepository.findByIdForUpdate(pickingOrderId)...
// :790-798
if (pickingOrder.getOperatorId() != null) {
    User user = userRepository.findByName(SecurityContextUtils.getUserName())...
    if (!user.getId().equals(pickingOrder.getOperatorId())) { ... throw new BusinessException("Parcel already assigned to user " + operator.getName()); }
}
```
- The guard runs after Case 1 and before the `allPicked`/`anyPicked` evaluation, so it sits in front of both Case 2 and Case 3 (and Case 4).
  The only way past it is `operatorId == null` (a free order) or `operatorId == caller`.
- TOCTOU: `findByIdForUpdate` is `@Lock(PESSIMISTIC_WRITE)` (`PickingorderRepository.java:50-55`, `exported = false`). A concurrent claim through
  `getPickingOrderPositionsInfo`, `processPick`/`confirmPick` or `rapidPickingScanSource` also takes this row lock first, so the check and the write
  cannot be split. The method is `@Transactional(tenantTransactionManager, rollbackFor = BusinessException)`, so the throw rolls back and nothing is saved.
- `Long.equals` on boxed ids is a value comparison, not the `!=` trap.
- Bypass via the state: Case 1 is gated on `state > PICKED`, and a caller cannot move the state there through this endpoint. No bypass.

### Case 1 left open to any caller: SAFE (I1)
`reenqueuePickingFinishedIfMissing` (`PickingorderBusinessService.java:508-571`) releases nothing and changes no operator, state or stock. For each
customer order on the picking order with `state >= PICKED && != CANCELED && pickingconfirmationsent != true`, it sets `pickingconfirmationsent=true`
and enqueues one `ORDER_BATCH_PICKING_FINISHED` outbox row with `idempotencyKey("CO-PICKED-" + co.getId())`.
- **Idempotent:** the first run sets the flag, so a second call finds nothing stranded. `uk_outbox_message_idempotency_key`
  (`V2.2.00__base_v2_schema.sql:3748`) backs that up. Two calls on the same picking order are now serialized by the new PO lock. Before this commit
  they could interleave.
- **What a caller can trigger:** it only re-sends a notification the order is owed. The picker is attributed from `operator_id`, not from the caller.
  The response is `true` either way, so the caller learns nothing.
- Residual edge (pre-existing, not introduced here): two picking orders sharing one stranded customer order, released at the same moment, can race
  to the unique key, and the loser gets a `DataIntegrityViolationException`. The controller does not catch it, so it becomes a rolled-back 500 with
  no harm. The `AdviceService:249` hub-and-spoke customer orders (`PALLETIZED`, `sent=false`) are created without picking positions, so Case 1 cannot reach them.
- Pinned by `shouldStillReenqueue_whenAFinishedOrderIsHeldByAnotherUser` (`verify(userRepository, never()).findByName(any())`).

### Lock order: no new inversion
The release path now takes **PO (row lock) → [Case 2] `finishPickingOrder`: PO again (re-take of a lock already held, `PickingorderBusinessService.java:202`) → customer orders ascending → their lines**.
Case 1 takes PO → CO row UPDATE locks (plain `findAllById` + `save`). That is the documented canonical order ("a picking order, then customer orders
(ascending), then their lines", `:180`). `confirmPick` takes the PO first (`:1231`), and `processPick`/`rapidPickingScanSource` lock the PO before
they reach it. Before this commit, Case 2 entered `finishPickingOrder` without the PO lock and took it there, so the order was the same, only later.
The one known exception (the SBDEV-3727 marked-order clean-up reaching other picking orders) belongs to `finishPickingOrder` and is unchanged.
The new effect is lock waits: a release now blocks behind an in-flight pick on the same order. The controller maps a timeout or deadlock to
`PessimisticLockingFailureException` → "Conflict / Another operation is in progress" (`PickingController.java:268-269`). The old
`ObjectOptimisticLockingFailureException` → success branch becomes mostly unreachable, which does no harm.

### Does any legitimate flow need to release someone else's order through this endpoint? NO
- `wms2-mobile-ui` origin/develop `f51dc6c`: there is one caller, `components/picking/pick.vue:271` `goBackToList()` → `store/picking.js:466` with
  `this.orderSelected.id`, the order this handheld opened (and claimed via `getPickingOrderPositionsInfo`, which applies the same free-or-caller rule).
  The other hits are e2e route mocks only (`tests/e2e/picking.spec.ts:290,343,397,486`).
- `wms2-web-ui` origin/develop `98accaf`: no hits.
- `ReleaseExpiredPickingOrdersFromUserJob` does not call this method. It works off `getPickingOrdersToReleaseExpiredPickingOrders` under an advisory lock.
  Supervisor force actions go through `AdminActionController`. No IT calls `releaseRegularPickingOrder` (only javadoc mentions in
  `ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest:107` and `PickingCancelLockReadStaleVersionIT:590`). `PickingControllerUnitTest:290,301` mocks the service.
- The one changed outcome for a real operator is when A's order timed out, B claimed it, and then A presses back. A now gets "Parcel already assigned
  to user B" instead of silently stripping B's claim. That is the intended behaviour.

### Controller mapping and UI handling: not silent
`BusinessException` is caught at `PickingController.java:270-271` → `errors.add(getErrorMessage("Runtime Error", e.getMessage()))` → HTTP 200 `{errors:[...]}`.
`BusinessException(String)` resolves through the `placeholder` key to the literal text, and the unit test confirms `hasMessageContaining("assigned to user otheruser")`.
The UI does **not** ignore it: `store/picking.js:468-470` `if (result && result.errors) this.$toast.error(result.errors[0].message)`. The page then
returns to the list as before. The refusal is visible, and because the order is not the caller's, going back to the list is the right next step. Acceptable.
`EntityNotFoundException` (holder or caller user row missing) is a `RuntimeException` handled by `RestExceptionHandler:200`, the same as the sibling.

### Orphan lock (lockedtooperator=true, operator null): still releasable. Correct but UNPINNED (L1)
The guard keys on `getOperatorId() != null` only, so an orphan skips it and goes to Case 3. There, `setOperatorId(null)` clears `lockedtooperator`
as a side effect (`Pickingorder.java:165-170`). That is the right behaviour, and it is the self-heal the SBDEV-3205 comment wants (`PickingorderRepository.java:98-113`).

## Findings

### L1. Nothing pins "orphan lock stays releasable". A mutant that refuses it survives the whole test class
**Severity:** LOW (test gap. The behaviour is correct today). **Location:** `MobilePickingServiceUnitTest.java`, nested `ReleaseRegularPickingOrder` / `OperatorHoldInvariant`.
**Measured** in a detached probe worktree at 5008d222 (removed afterwards). I applied this mutant:
```java
if (pickingOrder.getOperatorId() != null || Boolean.TRUE.equals(pickingOrder.getLockedtooperator())) {
    User user = ...;
    if (!user.getId().equals(pickingOrder.getOperatorId())) {
        if (pickingOrder.getOperatorId() == null) throw new BusinessException("orphanMUTANT");
```
The bytecode was confirmed (`javap` shows `orphanMUTANT`). `mvn -o test -Dtest='MobilePickingServiceUnitTest*'` exited 0 with 0 failures
(`ReleaseRegularPickingOrder` 11/11, `OperatorHoldInvariant` 2/2). So "harden" the guard to treat any held flag as owned, which is a plausible
future edit, and the orphan state becomes un-releasable from the handheld again. The scan path's orphan handling
(`shouldClaimWhenLockedButOperatorIdIsOrphanNull`, `:1961`) covers `rapidPickingScanPackage`, not this method. The edited
`case3_resetToPool_clearsTheLock` used to hold the order by 7L and is now held by the caller, so it does not cover the orphan either. The edit itself is right.
**Remediation:**
```java
@Test
@DisplayName("SBDEV-3865: an orphan lock (locked, no operator) is still released to the pool by anyone")
void shouldRelease_whenTheOrderIsAnOrphanLock() throws Exception {
    testPickingOrder.setState(WmsConstants.State.STARTED);
    testPickingOrder.setLockedtooperator(true);      // operatorId stays null: the orphan
    testPosition.setState(WmsConstants.State.STARTED);
    when(pickingorderRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(testPickingOrder));
    when(pickingorderPositionRepository.findByPickingorderId(1L)).thenReturn(Collections.singletonList(testPosition));
    when(pickingorderRepository.save(any(Pickingorder.class))).thenReturn(testPickingOrder);
    try (MockedStatic<SecurityContextUtils> security = Mockito.mockStatic(SecurityContextUtils.class)) {
        security.when(SecurityContextUtils::getUserName).thenReturn("testuser");
        lenient().when(userRepository.findByName("testuser")).thenReturn(Optional.of(testUser));
        assertThat(mobilePickingService.releaseRegularPickingOrder(1L)).isTrue();
    }
    assertThat(testPickingOrder.getState()).isEqualTo(WmsConstants.State.PROCESSABLE);
    assertThat(testPickingOrder.getLockedtooperator()).isFalse();
}
```
Mutation-check it against the mutant above.

### L2. `shouldRefuseToFinish_whenTheCompleteOrderIsHeldByAnotherUser` asserts only `isInstanceOf(BusinessException.class)`
**Severity:** LOW (test precision). **Location:** `MobilePickingServiceUnitTest.java`, the second new test.
```java
assertThatThrownBy(() -> mobilePickingService.releaseRegularPickingOrder(1L))
    .isInstanceOf(BusinessException.class);
```
Any `BusinessException` on the path satisfies it. Today the `never().finishPickingOrder` and `never().save` verifications carry the test, and the
"ownership check disabled" mutant goes red through them, so it is not vacuous. But if the refusal moved after a step that throws its own
`BusinessException`, the test would pass for the wrong reason. Its sibling already pins the text.
**Remediation:** `.isInstanceOf(BusinessException.class).hasMessageContaining("assigned to user otheruser");`

### I2. The refusal message names the holder's username (note only)
`throw new BusinessException("Parcel already assigned to user " + operator.getName());` (`:797`). This is byte-identical to the sibling
`getPickingOrderPositionsInfo` (`:881-882`), and `verifyPickingOrders` (`:757`) already shows the holder's first and last name to any picker. The
audience is warehouse staff who share a floor. This is consistent and needs no change. Deviating would make one endpoint the odd one out.
The `LOG.warn` at `:796` logs ids only. Good.

### I3. Case 4 (partially picked) held by another user now gets an error instead of `false`
Before: `ok(false)`, no toast. After: `{errors:[...]}`, toast. No state change either way. This is benign and arguably better.

### I4. The lock is pinned by a call verification, not by an IT
`shouldLockTheOrder` verifies that `findByIdForUpdate(1L)` was called and `findById` was not. It catches the `findById` regression (the author measured
this), but it cannot see whether `@Lock(PESSIMISTIC_WRITE)` stays on the finder. That annotation is guarded elsewhere (SBDEV-3169 export rule,
`MultiRowLockOrderUnitTest` for the multi-row finder). It is proportionate for this change, so no action is needed.

## Test quality of the 5 new tests + the edited case3 test
| Test | What it pins | Verdict |
|---|---|---|
| `shouldRefuse_whenTheOrderIsHeldByAnotherUser` | Case 3 refused. Message, operator, state unchanged. No save, no finish | Strong. Precondition change visible (999 ≠ testUser 1) |
| `shouldRefuseToFinish_whenTheCompleteOrderIsHeldByAnotherUser` | Case 2 refused. No finish, no save | Good. L2 (type-only exception assertion) |
| `shouldRelease_whenTheOrderIsHeldByTheCaller` | Own-order Case 3 still works | Good. Kills a "refuse whenever held" mutant |
| `shouldStillReenqueue_whenAFinishedOrderIsHeldByAnotherUser` | Case 1 stays open and the check stays after it | Good. Kills "check moved above Case 1" |
| `shouldLockTheOrder` | Locked finder used, plain finder not | Adequate (I4) |
| `case3_resetToPool_clearsTheLock` (edited 7L → caller) | Lock cleared on Case 3 | Correct edit. It is no longer foreign-held, and the orphan is not covered (L1) |

The free-order path stays pinned by the pre-existing tests, whose fixture has `operatorId == null`. Under `STRICT_STUBS` an unconditional user
lookup would hit the real `SecurityContextUtils` and fail. No gap there.

## Security checklist
- [x] No hardcoded secrets in the diff (scanned: no key, password or token literals)
- [x] Input validated: path id → locked lookup → `EntityNotFoundException` on a miss
- [x] Injection: none (JPQL with bound parameter)
- [x] Authorization: free-or-caller ownership enforced on Case 2, 3 and 4. Case 1 is deliberately open and safe (I1)
- [x] Concurrency: check and act under one PESSIMISTIC_WRITE row lock. Canonical PO → CO → lines order kept
- [x] Dependencies: no dependency change in this commit, so no audit applies (no mvn in the ticket worktree, per the brief)
- [x] Logging: refusal logged at WARN with ids only

**Severity count: 0 Critical, 0 High, 0 Medium, 2 Low, 4 Info.**
