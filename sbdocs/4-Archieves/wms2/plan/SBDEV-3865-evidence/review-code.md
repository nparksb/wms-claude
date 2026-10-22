---
ticket: SBDEV-3865
kind: code-review
tier: T2
head: 938f9ef336234be2d085e6818be82df1efcef219
base: origin/develop (merge-base f85789d4)
worktree: .claude/worktrees/wms2-api/SBDEV-3865
date: 2026-10-22
verdict: COMMENT
findings: { high: 0, medium: 1, low: 11 }
---

# SBDEV-3865: independent code review

The scope is `git diff origin/develop...HEAD` at 938f9ef3 (a797da32 gate tests, 938f9ef3 fix): 11 files.

There is one thing outside that scope. At review time the worktree had an uncommitted edit to
`MobilePickingServiceUnitTest.java` (+24 lines: two "no position id" tests for reset and release). It is
not at head and was **not reviewed**.

Evidence base:
- I read the full diff and the surrounding code (confirmPick :1213-1400, processPick :465-668, rapid
  :1371-1545, reset/release/verify :1557-1645, the controller :128-232 and :339-376).
- I read wms2-mobile-ui `origin/develop` f51dc6c (`store/picking.js`, `scanSource.vue`,
  `scanSourceSimple.vue`, `verifyPackage.vue`).
- I ran one mutation probe in a detached throwaway worktree at 938f9ef3 (`mvn -o test
  -Dtest=PickingorderBusinessServiceUnitTest`, 104 tests). That run also confirms that main and test compile at head.
- I did not run `lsp_diagnostics`. The probe compile stands in for it.

## Stage 1: spec / consult conformance

| Requirement (ticket + consult §3) | Status |
|---|---|
| Rapid pick: amount, stock unit and tote come from the stored line, not the body | **Met.** It re-reads by id after the PO lock and refuses on picking order, amount, stock unit or PUL (`storedPickMismatch`). Everything downstream, including `confirmPick(pickingPosition, …, pickingPosition.getAmount(), …)` and the completion DTO, uses the stored row. |
| reset unlocks only an order the caller holds | **Met**, with a deviation (L2). It uses the stored line's order and tote, `findByIdForUpdate`, "null-or-caller", and is `@Transactional("tenantTransactionManager")`. |
| processPick checks that the line is on the locked order | **Met**, before the tote branch: `if (!pickingOrderId.equals(pickingPosition.getPickingorderId()))`. |
| confirmPick: PO lock hoisted above the CO lock | **Met.** The test is now first-invocation-sequence based (see Positives). |
| confirmPick: operator "null-or-caller" | **Met.** |
| confirmPick: amount check after the ≤0 guards, `compareTo` | **Met.** |
| confirmPick: PUL check, null-tolerant | **Met** (L3 on its strength). |
| Controller `/resetPickingOrder` catches `BusinessException` | **Met.** This was required anyway: reset now `throws BusinessException` (checked). |
| Consult step 7: reset "refusing a mismatch as in step 5" | **Not met, deliberately** (choice 1). See L2. |
| Consult step 5: identity-only compare so that `PICK_ALREADY_FINISHED` still surfaces | **Met, and done better than the consult wrote it.** The consult missed that `confirmPick` clears `pickfromstockunitId` (`PickingorderBusinessService:1389`), so an identity compare alone would answer a stale client with "stock unit" mismatch. The implementation's state short-circuit (choice 2) closes that. Its ordering is L1. |

Sibling sweep of the endpoints that take a `PickingorderPosition` from the body (all in `PickingController` → `MobilePickingService`):
- `/processRapidPickScanSource` → closed.
- `/resetPickingOrder` → closed.
- `/processRapidPickScanSourcePass` (`releasePickingOrder`) → now uses the stored order (L5 on its tx/lock shape).
- `/processRapidPickScanPackageToVerify` → **still uses the posted `picktounitloadId`** (L4). It is read-only and moves no stock.
- `/processPick` takes ids, not a body entity. It is now closed.
- `confirmPick` has exactly two callers (:655, :1498). `PickingorderPositionRepository` is `exported = false`.
- **No remaining path moves stock from a posted copy.**

## Lock ordering

There is no new inversion.
- **rapid:** PO(posted id) FOR UPDATE, then the stored line (plain). A mismatch on `pickingorderId` is refused before any CO lock, and confirmPick re-takes the same PO, then the CO, then the COP.
- **processPick:** unchanged PO → CO.
- **reset:** the only row lock is the PO, after plain reads of the PUL and unit load.
- **confirmPick's hoist:** for a hypothetical mismatched caller it now takes PO_B before CO, the canonical direction, where before it was CO → PO_B.
- **rapid `>= PICKED` short-circuit:** `assertPickNotCancelled(1-arg)` does plain reads of the COP/CO (`PickingorderBusinessService:967-976`) while holding PO_A. No lock is taken.

## Issues

### [MEDIUM] M1: the "picking order not found" confirmPick test now passes because of the new amount guard; `PICK_CONFIRM_MISSING_ORDER` is unpinned
File: `src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java:617-640` (`SadPath.throwsWhenPickingOrderNotFoundForConfirmPick`)
Confidence: HIGH (mutation-proven)

Issue:
- The fixture never sets the stored amount. `PickingorderPosition.amount` defaults to `BigDecimal.ZERO` (`model/PickingorderPosition.java:20`), and the call passes `BigDecimal.TEN`.
- The new check, placed before `if (pickingOrder == null)`, therefore throws `PICK_CONFIRM_AMOUNT_MISMATCH`. The assertion is only `.isInstanceOf(FacadeException.class)`, so it stays green.
- Probe: I deleted the whole `if (pickingOrder == null) { … PICK_CONFIRM_MISSING_ORDER … }` block. All 104 tests stayed green, and this test's captured log reads `Amount picked differs from the stored pick amount. Abort. position=null, stored=0, given=10`.
- The author fixed the sibling `WRONG_UNITLOAD` test (:1568, `setAmount(BigDecimal.TEN)` + `hasMessageContaining`) but missed this one.
- (The consult §3.3 claim that the fixtures "leave the stored amount null" is also wrong: they leave it ZERO.)

Fix:
- Add `position.setAmount(BigDecimal.TEN)`.
- Assert `((FacadeException) thrown).getKey()` is `"PICK_CONFIRM_MISSING_ORDER"` (or `.hasMessageContaining`).
- The other bare `isInstanceOf(FacadeException.class)` confirmPick tests (:390 no-stock, :684 already-picked) hit guards that come *before* the amount check, so they are unaffected.

### [LOW] L1: the rapid `>= PICKED` short-circuit runs before the identity comparison
File: `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java:1418-1423`
Confidence: HIGH

```java
if (pickingPosition.getState() != null && pickingPosition.getState() >= WmsConstants.State.PICKED) {
    pickingorderBusinessService.assertPickNotCancelled(pickingPosition);
    throw new FacadeException("PICK_ALREADY_FINISHED", "");
}
String mismatch = storedPickMismatch(postedPosition, pickingPosition);
```

Issue:
- A body whose id names a finished or cancelled line of *another* picking order gets that line's state ("already finished" or "cancelled") back, plus a plain read of another customer order. It should get "picking order" mismatch.
- No stock moves, so this is only a minor oracle and a wrong message.
- `pickingorderId` is never cleared by picking, so it is safe to compare first.

Fix: move the `!Objects.equals(posted.getPickingorderId(), stored.getPickingorderId())` refusal above the state check, and keep the state check above the amount, stock-unit and PUL comparison.

### [LOW] L2: reset accepts a body naming other ids (deviation from consult §3 step 7)
File: `MobilePickingService.java:1557-1585`. The behaviour is pinned by `MobilePickingServiceUnitTest` `resetPickingOrder_shouldUseTheStoredOrderAndTote_whenTheBodyNamesOthers` and the IT `resetPickingOrder_shouldResetOnlyTheStoredOrder_whenTheBodyNamesAnother`.
Confidence: MEDIUM

Issue:
- The security property holds. The stored line's order and PUL are used, and the order must be null or the caller's, so naming a victim's line id is refused.
- But a body whose `pickingorderId`/`picktounitloadId` disagree with its own id is answered `true`, and it resets the order the *id* points at, not the one the body names.
- The consult asked for a refusal, for the same "stale screen or crafted request" reason the rapid path uses. The UI's reset body is the pre-pick copy, and its `pickingorderId`/`picktounitloadId` never change in a pick (verified in `store/picking.js:401-403` → `verifyPackage.vue` data), so a refusal would not break the honest flow.

Fix: either refuse when a non-null posted `pickingorderId`/`picktounitloadId` differs from the stored one (and flip the two tests), or record in the consult/ticket why lenient was chosen. At present the design of record and the code disagree.

### [LOW] L3: the PUL-per-customer-order check is null-tolerant, so it is not enforced where the line has no PUL yet
File: `PickingorderBusinessService.java` (new block after `PICK_CONFIRM_WRONG_UNITLOAD`): `if (pickingPosition.getPicktounitloadId() != null && !…equals(pickingUnitLoad.getId()))`
Confidence: MEDIUM

Issue:
- The null tolerance is correct and necessary for processPick's first pick, where the managed instance is stale after `assignToteToAllPositions`.
- But it means the "tote belongs to this customer order" invariant is not checked on exactly that path, or for any future caller holding a line with a null PUL. Only the order-level check applies there.
- Today processPick creates the PUL from the line's own customer order, so there is no live hole.

Fix (optional, stronger and never null on a good path): also compare `pickingUnitLoad.getCustomerordernumber()` with `lockedCustomerOrder.getNumber()`. The CO is already locked in confirmPick, and the PUL is created with `customerOrder.getNumber()`.

### [LOW] L4: `/processRapidPickScanPackageToVerify` still trusts the posted `picktounitloadId`
File: `MobilePickingService.java:1637-1644`
```java
PickingorderUnitload pickToUnitLoad = pickingorderUnitloadRepository.findById(pickingPosition.getPicktounitloadId())…
```
Confidence: HIGH (fact) / impact low

Issue:
- It is read-only. A forged body can only make its own verify pass, which then makes the UI dispatch reset. Reset is now independently guarded.
- It is the one remaining body-trusting sibling in this controller.

Fix: re-read by `requirePositionId` + `findById` and use the stored `picktounitloadId`, for consistency with the rest of the ticket.

### [LOW] L5: `releasePickingOrder(PickingorderPosition)` is still non-transactional and lock-free
File: `MobilePickingService.java:1616-1635`
Confidence: MEDIUM

Issue:
- It is check-then-act across separate repository transactions (OSIV is off, `application.properties:85`).
- The `@Version` merge on `save` turns a racing claim into an optimistic failure, which the controller reports, so it is not exploitable.
- It is now inconsistent with its sibling `resetPickingOrder`, which locks.

Fix: give it the same `@Transactional(value = "tenantTransactionManager", rollbackFor = …)` + `findByIdForUpdate` shape as reset.

### [LOW] L6: the stale-copy refusal tells the operator to "Scan the pick again", but rescanning re-posts the same stale copy
File: `MobilePickingService.java:1427`: `"… does not match the stored pick (" + mismatch + "). Scan the pick again."`
Confidence: LOW-MEDIUM

Issue:
- On an error, `store/picking.js:358-360` toasts and keeps `rapidPositionInfo`. The next source scan therefore posts the identical body and is refused again.
- Recovery is "Pass" (`processRapidPickScanSourcePass`) and then a rescan of the tote, which re-reads from the database.
- How often this happens depends on how often an open line's `pickfromstockunitId`/amount changes mid-walk (for example via `fixPickingPosition`).

Fix: word it as "… changed since it was shown. Pass this pick and scan the tote again." Alternatively, return the stored line in the error payload so that the UI can refresh.

### [LOW] L7: reset's new early-return branch and the reset/release `requirePositionId` are unpinned at head
File: `MobilePickingService.java:1562-1565` (`if (pickingPosition.getPicktounitloadId() == null) { … return; }`)
Confidence: HIGH

Issue:
- No test sets a null stored `picktounitloadId`. Deleting the guard would not go red either: Mockito's default for an unstubbed `Optional` return is `Optional.empty()`, so `findById(null)` silently returns empty in unit tests. In production it is an `IllegalArgumentException` (500).
- The uncommitted worktree tests add the `requirePositionId` cases, but not this branch.

Fix: add a unit test with a stored `picktounitloadId = null` that asserts `never().findByIdForUpdate(any())` and `never().save(any())`. Mutate the guard to `if (false)` and confirm red. To be red it needs a strict `when(pickingorderUnitloadRepository.findById(isNull()))…thenThrow(IllegalArgumentException.class)`.

### [LOW] L8: confirmPick's `getAmount() == null` arm is effectively dead and unpinned
File: `PickingorderBusinessService.java`, new amount block: `if (pickingPosition.getAmount() == null || pickingPosition.getAmount().compareTo(amountPicked) != 0)`
Confidence: HIGH

Issue:
- The entity defaults to `BigDecimal.ZERO`, and the DB column is the only route to null.
- Without the arm, a null amount would NPE, which is still a refusal but an unkeyed one. No test covers it.

Fix: keep the arm and add a one-line test (stored amount null → `PICK_CONFIRM_AMOUNT_MISMATCH` key), or drop it with a comment.

### [LOW] L9: `PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR` renders a user id; the siblings render a name
File: `PickingorderBusinessService.java` operator block (`new Object[]{pickingOrder.getNumber(), pickingOrder.getOperatorId()}`). The bundle text is `…assigned to another user (%2$s).`
Confidence: HIGH

Issue: processPick and `releasePickingOrder` show `operator.getName()`, and the rapid path shows the raw id. This key is reachable only by a future or crafted caller, so it is cosmetic.

Fix: resolve the name, or drop the parameter.

### [LOW] L10: an unrelated SBDEV-3857 review fix rides in the gate commit
File: `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileCycleCountServiceUnitTest.java:1916,1928,1945,1957` (`refresh(stored)` → `refresh(same(stored))`)
Confidence: HIGH

Issue: it strengthens the tests (identity instead of id-based `equals`) and is disclosed in a797da32's message ("SBDEV-3857 review N5-1"). But it is another ticket's scope inside this PR.

Fix: none required. Mention it in the PR body so that the SBDEV-3857 finding is closed against this PR.

### [LOW] L11: `lenient()` added to the existing rapid nested setUp, against consult risk 1
File: `MobilePickingServiceUnitTest.java:2166`: `lenient().when(pickingorderPositionRepository.findById(1L)).thenReturn(Optional.of(testPosition));`
Confidence: MEDIUM

Issue:
- The consult said "do not 'fix' it with `lenient()`". The comment does justify it ("the tests refused before the re-read never reach it").
- Lenient only suppresses unused-stub errors and does not weaken an assertion. But it also hides a future test that stops reaching the re-read.
- The new `JudgedOnTheStoredPosition` setUp is lenient wholesale too. Its assertions are message- and identity-specific (`same(stored)`, field names, `PO-001`), which mitigates this.

Fix: make it strict per test, or accept it with the comment (acceptable).

## Open questions (low confidence, not blocking)

- [LOW] Does the IT's `deleteResidue` leave rows in tables without `client_id` after the positive-control pick? `MobilePickingJudgesTheStoredPositionIT` purges 13 tables by `client_id`. `isProduction()` is false in the IT, so no OMS or outbox send is expected. I did not check whether `confirmPick`/`transferStockToUnitLoad` write to a non-client-scoped table (for example `los_sequencenumber` draws). In a reused container that would be harmless residue, not cross-talk.
- [LOW] The completion DTO now returns the post-pick stored row (`state=PICKED`, `pickfromstockunitId=null`) where it used to return the pre-pick posted copy. In UI `origin/develop`, `newRapidPositionInfo.pickingorderPosition` is read only for `pickCompleted` on the completion path. `verifyPackage.vue` posts `rapidPositionInfo` (the pre-pick copy), so I found no consumer of the changed fields. Worth one DEV click-through.

## Positive observations

- Choice 2 is right and catches a consult gap: identity-only comparison would mislabel every stale-but-honest re-scan, because `confirmPick` nulls `pickfromstockunitId`. The unit test `rapidPickingScanSource_shouldAnswerAlreadyFinished_whenTheStoredLineIsAlreadyPicked` pins exactly that, with `verify(...).assertPickNotCancelled(same(stored))`.
- The lock-order test was rewritten to compare **first-invocation sequence numbers**. The comment correctly notes that an `InOrder` match pairs the PO lock with a *later* CO lock and passes on the old order. That is a real false-green trap, and it was avoided.
- The processPick refusal is placed before the tote branch, so a cross-order line can no longer create or reclaim a tote or call OMS before being refused.
- The amount is compared with `compareTo` on both layers, and there is a scale test (`10.0000` vs `10`).
- The PG IT runs `NOT_SUPPORTED`, the way the controller calls, reproduces the DEV 7-vs-2 probe with a positive control, and asserts source amount, reservation, tote contents, pick-line and CO-line `amountpicked`. It is registered in `TestClassTransactionManagerArchTest` with a client-scoped id block.
- New keys are declared in `WmsConstants.MessageKey` and present in **both** bundles, so `MessageKeyConstantBundleContractTest` pins them.
- `requirePositionId` turns the former `findById(null)` 500s into a keyed refusal.
- The double `dto.setPickingorderPosition(pickingPosition); dto.setPickingorderPosition(pp);` dead store was removed.

## Recommendation

**COMMENT.** There are no HIGH or CRITICAL findings. Every path that moved stock from a posted copy is closed, and the lock order is canonical everywhere. Fix **M1** before the PR: it is a guard silently left without coverage, proven by mutation. Per the repo's fix-every-finding policy, take L1, L2 (or record the deviation), L4, L5 and L7 in the same pass. The rest are wording and optional hardening.
