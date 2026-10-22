---
ticket: SBDEV-3865
kind: code-review-round2
scope: git show 2c6c7b6e (round-1 fix commit only, plus its interactions)
head: 2c6c7b6e996749f65c161173ca3f21cc2ee19735
worktree: .claude/worktrees/wms2-api/SBDEV-3865
date: 2026-10-22
verdict: COMMENT
findings: { critical: 0, high: 0, medium: 0, low: 6 }
---

# SBDEV-3865: round-2 review of the fix commit 2c6c7b6e

## Evidence base
- I read both round-1 reports (`review-code.md`: M1, L1–L11; `review-security.md`: M1, L1–L5), the full diff of 2c6c7b6e, and the code around it at head: `MobilePickingService` rapid :1388-1440, reset/release/verify :1565-1675; `PickingController` :128-232; `PickingOrderMergeService` :50-180; `FacadeException.resolve`; `RestExceptionHandler.handleEntityNotFound`; `MessageKeyConstantBundleContractTest`; and the `LockReadRail` javadoc and listener.
- I read wms2-mobile-ui at `origin/develop` f51dc6c: `store/picking.js` :353-431, `rapid/scanSource.vue:85`, `rapid/scanSourceSimple.vue:53`, `rapid/verifyPackage.vue:51`.
- **Mutation probe.** I used a detached throwaway worktree at 2c6c7b6e, JDK 21.0.11, and `mvn -o test` over `MobilePickingServiceUnitTest`, `PickingorderBusinessServiceUnitTest` and the three i18n contract tests. The baseline was green: **266 tests, 122 report files** (count and reports confirmed). I applied each mutant to a clean copy, restored the files afterwards, and then removed the worktree. I did not run anything in the ticket worktree.
- I did not run `lsp_diagnostics`. The probe compile of main and test at head stands in for it.

| # | Mutant | Result |
|---|---|---|
| A | identity check moved back below the `>= PICKED` short-circuit | **RED** `rapidPickingScanSource_shouldRefuseAsAnotherOrder_…AlreadyPicked:2738` |
| B | `releasePickingOrder` uses `findById` instead of `findByIdForUpdate` | **RED** (3: `releasePickingOrder_shouldLockTheStoredOrder:2798` + 2 updated helper tests) |
| C | verify looks up `postedPosition.getPicktounitloadId()` | **RED** `processRapidPickScanPackageToVerify_shouldCheckTheStoredTote…:2764` |
| K | verify drops the re-read (`pickingPosition = postedPosition`) | **RED** (1 failure + 2 strict-stub errors) |
| G | drop the `getPickingorderId() == null` guard in rapid | **RED** `…_whenThePostedPositionHasNoPickingOrder:2751` |
| I | neuter `if (pickingOrder == null)` → `PICK_CONFIRM_MISSING_ORDER` in confirmPick | **RED** `SadPath.throwsWhenPickingOrderNotFoundForConfirmPick:642` (code M1 is fixed) |
| J | drop reset's `getPicktounitloadId() == null` early return | **RED** `resetPickingOrder_shouldDoNothing_whenTheStoredLineHasNoTote:2787` (code L7 is fixed) |
| D | restore `(%2$s)` in both bundles | **green** (L-A) |
| E | code passes `pickingOrder.getOperatorId()` again | **green** (L-A) |
| F | drop `@Transactional` from `releasePickingOrder(PickingorderPosition)` | **green** (L-B) |
| H | drop verify's new `getPicktounitloadId() == null` guard | **green** (L-C) |

## Stage 1: does each claimed fix fix its finding?

| Finding | Claimed fix | Verdict |
|---|---|---|
| code M1: missing-order test passes on the amount guard | `setAmount(TEN)` + `hasMessageContaining("PICK_CONFIRM_MISSING_ORDER")` | **Fixed** (mutant I red) |
| code L1 / sec L2: state short-circuit before the identity check | `Objects.equals(posted.pickingorderId, stored.pickingorderId)` moved above the state check, and removed from `storedPickMismatch` | **Fixed** (mutant A red). The refusal echoes `posted.getNumber()`, not the stored number, so another order's line is never described. The log also switched to the posted id. |
| sec §3: `findByIdForUpdate(null)` → 500 | `if (postedPosition.getPickingorderId() == null) throw BusinessException("No pick given")` | **Fixed** (mutant G red). Wording is L-E. |
| code L5 / sec L1: release lock-free and non-transactional | `@Transactional(tenantTransactionManager, rollbackFor …)` + `findByIdForUpdate` | **Fixed in code.** The lock is pinned (B red), but the transaction is not (F green, L-B). |
| code L4 / sec L5: verify trusts the posted PUL | `requirePositionId` + stored re-read + null-PUL refusal | **Fixed** (C, K red). The null guard is unpinned (L-C). |
| code L6: "Scan the pick again" loops | "…it changed since it was shown. Pass the pick and scan the tote again." | **Fixed** for amount, stock unit and pick-to unit load. For the "picking order" field the advice is wrong (L-D). |
| code L7: reset no-tote branch unpinned | new test | **Fixed** (J red) |
| code L8: null stored amount arm | `confirmPick_shouldRefuse_whenTheStoredAmountIsNull` | **Fixed.** It asserts the key and that `changeReservedAmount` is never called. Without the arm the code NPEs, so the key assertion makes it red. |
| code L9 / sec L3 (key part): user id in `PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR` | parameter and slot dropped in both bundles | **Fixed, but unpinned in both directions** (D, E green, L-A) |
| reset/release/verify no-id refusals | three tests | **Fixed.** The tests assert the message and that no lookup happens. |

### Items deliberately not changed: does the reasoning hold?

- **code L2 (reset stays lenient): holds.** The security property is that the stored line's order and PUL are used, the order is locked, and its operator must be null or the caller. That property is pinned by the unit test and the IT. The lenient answer cannot touch an order other than the one the stored id belongs to. The cost is only a design-of-record mismatch, so it must be recorded on the ticket as stated. One caveat: the stated reason "the gate tests pin it" is circular, because the gate tests were written for this code. The real justification is the security property, so cite that.
- **code L3 (PUL-customer-order check): holds as deferral.** A `customerordernumber` comparison could refuse honest picks on reused or legacy totes (see the repo memory on tote reuse and non-unique finders), and there is no census to rule that out. There is no live hole today, because processPick creates the PUL from the line's own customer order. Record it as hardening that needs a census.
- **sec L3 (reset "Parcel assigned to user <id>"): holds as a product call.** It matches `rapidPickingScanSource:1404`, which is byte-identical (`"Parcel assigned to user " + pickingOrder.getOperatorId()`), on the same handheld flow. Note that `releasePickingOrder:1647` leaks the operator **name** (see L-D). The two message shapes now sit side by side on one controller, so the "one place" product call sec L3 asked for is still owed.
- **sec L4 (null-or-caller): holds.** This is accepted design from the consult.
- **sec M1 (GET `/releasePickingOrder/{id}` IDOR): correctly out of scope.** It is unchanged by this commit. Propose it as T3. Because the ticket is not `on dev`, folding it in is still an option for Nam.
- **code L10 / L11:** PR-body note / accepted lenient. Acceptable. The new tests reuse the lenient `JudgedOnTheStoredPosition` setUp, but every one of them asserts identity, key or `never()`, so the lenient stubs do not make any of them vacuous. Mutants A, B, C, G and J are the proof.

## Stage 2: interactions and regressions

- **Rapid refusal text vs the tests and the UI: no regression.** The IT (`MobilePickingJudgesTheStoredPositionIT:246`) and the unit test (`:2607`) assert the substring `does not match the stored pick`, which the new text keeps. No test asserted `Scan the pick again` for the rapid path. The UI shows `result.errors[0].message` as a toast (`store/picking.js:358-360`), so a longer string just renders. The posted `number` is echoed into the toast, but that is the caller's own value and toast text is not HTML.
- **release is now `@Transactional`.** It is called through the proxy from `PickingController.processRapidPickScanSourcePass:163`, and no in-class self-call exists (grep). The overload `releasePickingOrder(Pickingorder)` at :265 is a different signature.
  - `BusinessException` (another operator) rolls back, with no writes before it, and the controller reports it as before.
  - A lock timeout now becomes possible and surfaces as `PessimisticLockingFailureException`, which the controller catches as "Conflict".
  - A flush or version failure at commit surfaces as `ObjectOptimisticLockingFailureException` outside the proxy, also caught. In practice it cannot happen now, because the row is locked and managed rather than a merged detached copy.
  - `EntityNotFoundException` (unknown position or order) is not caught by the controller. `RestExceptionHandler.handleEntityNotFound:200` maps it to a 404 ProblemDetail, which `toastApiError` renders. That is pre-existing behaviour from 9c02b224.
  - LockReadRail: in production the order lock is the row's first touch in the new transaction, so it is clean. In `MobilePickingServiceIntegrationTest.mobileRapidPickingService_RapidPass_Test:950` (a class-level test transaction), the order was earlier locked by `rapidPickingScanSource` (entry already `PESSIMISTIC_WRITE`), so I expect no rail violation. This is not proven, so it is listed as an open question.
- **verify now throws `EntityNotFoundException` for an unknown position id.** The controller's catch list (`BusinessException`, OOLF, PLF) does not include it, so it becomes a 404 ProblemDetail through `RestExceptionHandler`, toasted by `toastApiError` (`store/picking.js:418-420`). This is the same shape the old code already produced for an unknown *PUL* id, so the change only widens which input triggers it. **Not a regression.** The honest flow posts `rapidPositionInfo.pickingorderPosition` (`verifyPackage.vue:51`), whose id always exists. After a pick, the stored line's `picktounitloadId` equals the PUL the rapid pick used (`confirmPick:1387` sets it from the stored line's own PUL), so the verify answer for an honest scan is unchanged.

## Issues

### [LOW] L-A: the de-identified `PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR` is pinned in neither direction
Files: `PickingorderBusinessService.java:1239-1240`, `messages.properties:85`, `messages_en_US.properties:131`, `PickingorderBusinessServiceUnitTest.java:2244`
Confidence: HIGH (mutants D and E green)

```java
throw new FacadeException(WmsConstants.MessageKey.PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR,
    new Object[]{pickingOrder.getNumber()});
```

Issue:
- **Mutant E**: re-adding the operator id to the call stays green. The test asserts only that the key appears in `getMessage()` (`"KEY:[PO-001, 999]"` contains the key), so the disclosure regression that sec L3 asked to remove can come back silently. (The id would not *render* while the template has one slot, but `getMessage()` and every log of it carry it.)
- **Mutant D**: restoring `(%2$s)` in the bundles stays green. `MessageKeyConstantBundleContractTest` sizes its arguments from the template itself (`:146`), so it never sees the call site's arity. In production, `String.format` with one argument against `%2$s` throws `MissingFormatArgumentException`. `FacadeException.resolve` catches that and returns `"--- CONVERSION EXCEPTION >>>>> PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR"`, which is what the handheld would show.
- Impact is low, because both callers pre-empt this key, but it is the round-1 fix itself that is unpinned.

Fix: in the operator test, assert `((FacadeException) t).getLocalizedMessage()` is `"Picking order PO-001 is assigned to another user."`, or at least `doesNotContain("999")` and `doesNotContain("CONVERSION EXCEPTION")`. That one assertion makes both D and E red.

### [LOW] L-B: release's new `@Transactional` is unpinned; removing it stays green, and a missing transaction would fail only at runtime
File: `MobilePickingService.java:1633` (`@Transactional(value = "tenantTransactionManager", …) public void releasePickingOrder(PickingorderPosition …)`)
Confidence: HIGH (mutant F green)

Issue:
- Unit tests cannot see the annotation. The only IT caller (`MobilePickingServiceIntegrationTest:950`) runs inside the class-level test transaction, which masks a missing one.
- Without the annotation, `findByIdForUpdate`'s `@Lock` either throws `TransactionRequiredException` in production (OSIV is off; see the repo's other `TransactionRequiredException` regressions) or locks inside a repository-scoped transaction that ends before the check. Either way, the guarantee the commit claims ("the operator check and the release cannot be split") rests on an annotation nothing asserts.

Fix: add a reflection assertion in the unit test, `MobilePickingService.class.getMethod("releasePickingOrder", PickingorderPosition.class).getAnnotation(Transactional.class)` with `value() == "tenantTransactionManager"` and rollbackFor containing `BusinessException`. Alternatively, cover it with a `NOT_SUPPORTED` IT such as `MobilePickingJudgesTheStoredPositionIT`. If an existing tx-qualifier ArchTest already covers "methods calling `*ForUpdate` are transactional", cite it instead.

### [LOW] L-C: verify's new null-PUL refusal is unpinned
File: `MobilePickingService.java:1662-1664`

```java
if (pickingPosition.getPicktounitloadId() == null) {
    throw new BusinessException("Scan correct parcel");
}
```

Confidence: HIGH (mutant H green)

Issue:
- Without the guard, `pickingorderUnitloadRepository.findById(null)` is an `IllegalArgumentException` (500) in production. Under Mockito it is an unstubbed `Optional.empty()`, which gives `EntityNotFoundException`.
- This is the same trap code L7 described for reset, and the commit fixed it there but not here.

Fix: add a test with a stored `picktounitloadId = null`, asserting `BusinessException` "Scan correct parcel" and `verify(pickingorderUnitloadRepository, never()).findById(any())`.

### [LOW] L-D: the "Pass the pick" advice, for a **picking order** mismatch, releases the stored line's order, not the caller's; release's refusal then names another operator
Files: `MobilePickingService.java:1421-1423` (identity refusal via `storedPickMismatchRefusal`, text `"Pass the pick and scan the tote again."`) and `:1640-1648` (release on `pickingPosition.getPickingorderId()`, `"Parcel assigned to user " + operator.getName()`)
Confidence: MEDIUM

Issue:
- For the three field mismatches, the identity check has already proved stored order == posted order. Pass then releases the caller's own order, and the tote rescan re-reads from the DB, so the advice is correct.
- For the "picking order" mismatch, Pass posts the same copy, and release acts on the **stored** line's order B:
  - B unclaimed: clears flags on B. Harmless.
  - B is the caller's: releases it.
  - B is another picker's: refuses with **that picker's user name**.
  The caller's own order A stays claimed and locked.
- The honest reachability of this branch is effectively nil. `PickingOrderMergeService` re-homes lines only on orders `< RESERVED` (`:65`), never on a claimed in-walk order, which also supports the code comment "picking never changes a line's picking order". So this is a crafted-request path. The name oracle through release by line id is pre-existing (since 9c02b224; before that it was by order id). It is listed because the new message steers to it.

Fix (cheap):
- Give the identity refusal its own text without the Pass advice (e.g. "Pick X is not on this picking order.").
- Optionally, make release refuse a stored line whose order the caller does not hold, rather than naming the holder. This folds naturally into the sec M1 / sec L3 product call.

### [LOW] L-E: "No pick given" is the refusal for a body with an id but no picking order id
File: `MobilePickingService.java:1395-1397`
Confidence: HIGH (fact) / impact cosmetic

Issue: the message is reused from `requirePositionId`, so a log or toast reader cannot tell "no id" from "no order id". The honest UI always sends both, so only crafted or broken clients see it.

Fix: `"No picking order given"`, or fold the check into a `requirePositionAndOrderId` helper.

### [LOW] L-F: the deferral reasons for code L2 and sec L3 are stated as "gate-pinned", which is circular
Where: the commit message, and wherever the deviation is recorded on the ticket. Process only; no code change.
Confidence: MEDIUM

Issue:
- "Kept because the gate tests pin it" is true but proves nothing: the gate tests were authored for this design. A future reader could flip the test and the code together.
- The load-bearing reasons are different:
  - for L2, the stored-order, locked, null-or-caller property;
  - for sec L3, parity with `rapidPickingScanSource:1404`.

Fix: record those reasons in the ticket deviation note.

## Open questions (low confidence, not blocking)
- [LOW] LockReadRail on `MobilePickingServiceIntegrationTest.mobileRapidPickingService_RapidPass_Test`: release now takes a JPQL lock inside the shared test transaction. I expect the order's entry to be `PESSIMISTIC_WRITE` already, from `rapidPickingScanSource`'s lock, so no violation. The `mvn clean verify` running in the worktree is the instrument that answers this. Check that test and the rail listener output in its failsafe report before relying on this.
- [LOW] Sibling check: `rapidPickingScanSource` still answers `"Parcel not assigned to user"` / `"Parcel assigned to user <id>"` from the **posted** order before the stored line is read (:1400-1405). That is the caller's own claimed order, so it is no oracle on another order's line. It is listed only so that the sec L3 product call covers all four message sites (rapid :1404, reset :1580, release :1647, processPick).

## Positive observations
- Every round-1 fix that carries a test is mutation-sound: A, B, C, G, I, J and K all go red on the test written for them, and each turns red for the named reason rather than a collateral one.
- Moving the identity check out of `storedPickMismatch` into the caller, with the javadoc updated, means the helper can no longer be called in an order that leaks state. The refusal helper deliberately names only the *posted* number and logs the posted id.
- The M1 fix both sets the amount and tightens the assertion to the key. That closes the false-green class, not only the instance.
- The new release lock is the order row's first touch in its transaction (after plain reads of the user and position only), so it is clean against the SBDEV-3286 rail invariant in production.
- The verify re-read was checked against the post-pick state: `confirmPick` writes the same PUL id it was given, so honest verifies are unaffected.

## Recommendation
**COMMENT.** There are no CRITICAL, HIGH or MEDIUM findings. All round-1 findings the commit claims to fix are fixed, and the deliberate non-changes hold on their merits. Per the repo's fix-every-finding policy:
- take **L-A**, **L-B** and **L-C** (each is one assertion or one test, and each has a mutant that currently survives);
- reword the identity refusal (**L-D**) and the order-id refusal (**L-E**);
- record the real reasons for L2 and sec L3 on the ticket (**L-F**).
