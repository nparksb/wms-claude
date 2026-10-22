---
ticket: SBDEV-3865
kind: code-review-round3
scope: git show d0cc2ae1 (round-2 fix commit only, plus its interactions)
head: d0cc2ae1378a2553e40d80380db2a77475718332
worktree: .claude/worktrees/wms2-api/SBDEV-3865
date: 2026-10-22
verdict: APPROVE
findings: { critical: 0, high: 0, medium: 0, low: 2 }
---

# SBDEV-3865: round-3 review of the fix commit d0cc2ae1

## Evidence base
- I read `review-round2.md` (L-A to L-F) and the full `git show d0cc2ae1`. I also read the code at head around each hunk:
  - `MobilePickingService` rapid :1388-1430, reset :1565-1592, `requirePositionId` :1595, `storedPickMismatchRefusal` :1621-1638, release :1640-1661, verify :1663-1678;
  - `FacadeException.getLocalizedMessage`/`resolve`;
  - both bundles' `PICK_CONFIRM_ORDER_ASSIGNED_TO_OTHER_OPERATOR`;
  - `TransferVerifications`;
  - the counting rules in `NeverMatcherNullBlindnessArchTest` (`REFERENCE_NULL_BLIND`, `PRIMITIVE_CAPABLE`, inventory);
  - the declarations of `StockunitBusinessService.changeReservedAmount` :651, the three `transferStockToUnitLoad` overloads :194/:203/:250, `UnitloadBusinessService.transferUnitLoadToLocation` :221 and `PickingorderBusinessService.assertPickNotCancelled` :967 (1-arg, public) / :987 (3-arg, package-private).
- **Probe.** I used a detached worktree at d0cc2ae1 under the scratchpad (`r3-probe`) with JDK 21 and `mvn -o test`. I have since removed it, and `git worktree list` shows no `r3-probe`. I did nothing in the ticket worktree.
- **Baseline.** I ran `MobilePickingServiceUnitTest`, `PickingorderBusinessServiceUnitTest`, `NeverMatcherNullBlindnessArchTest`, `NoBareTransferNeverRailTest`, `MessageKeyConstantBundleContractTest`, `PositionalPlaceholderContractTest` and `BaseBundleCompletenessContractTest`. Result: **285 run, 0 fail, 0 error** across 64 report files.
  - ⚠ Surefire writes `tests="0"` in the top-level XML of the three classes that have `@Nested` members. The top-level methods are filed under the nested class's report instead. For example, `noNeverVerifyUsesAReferenceTypedMatcher` and `primitiveCapableMatchersMatchInventory` appear in `NeverMatcherNullBlindnessArchTest$InventoryDriftTest.xml`. I confirmed by name that they ran and passed, so this is not a skipped rail.
- I did not run `lsp_diagnostics`. The probe compile of main and test at head stands in for it.

### Mutation table (each applied alone, files restored from `HEAD` afterwards)

| # | Mutant | Result |
|---|---|---|
| A1 | `confirmPick` passes `pickingOrder.getOperatorId()` again | **RED** `confirmPick_shouldRefuse_whenTheStoredOrderIsAssignedToAnotherOperator` |
| A2 | `(%2$s)` restored in both bundles | **RED**, same test |
| A3 | `(%2$s)` in root `messages.properties` only | **RED** `BaseBundleCompletenessContractTest.everyEnUsKeyIsInBaseWithTheSameTemplate` |
| A4 | `(%2$s)` in `messages_en_US.properties` only | **RED** (2: the same contract test + the operator test) |
| B | `@Transactional` dropped from `releasePickingOrder(PickingorderPosition)` | **RED** `resetAndRelease_shouldEachBeOneTenantTransaction` |
| B2 | reset's `rollbackFor` reduced to `FacadeException` only | **RED**, same test |
| B3 | release's qualifier dropped (`@Transactional(rollbackFor=…)`, the default TM) | **RED**, same test |
| C | verify's `getPicktounitloadId() == null` guard dropped | **RED** `processRapidPickScanPackageToVerify_shouldRefuse_whenTheStoredLineHasNoTote` |
| D | `advice` always the "Pass the pick" text | **RED** `rapidPickingScanSource_shouldNotAdvisePass_whenTheStoredLineIsOnAnotherOrder` |
| D2 | `advice` never the "Pass the pick" text | **RED** `rapidPickingScanSource_shouldAdvisePass_whenAFieldOfTheCallersOwnLineDiffers` |
| E | rapid's no-order refusal reverted to `"No pick given"` | **RED** `rapidPickingScanSource_shouldRefuse_whenThePostedPositionHasNoPickingOrder` |
| G | amount guard calls `changeReservedAmount(null, …)` before throwing | **RED** in both `…AmountPickedDiffersFromTheStoredAmount` and `…StoredAmountIsNull` |
| G-typed | G, with the test at :2213 reverted to `any(Stockunit.class)` | That test goes **green**; only :2226 stays red |

**Result.** The author's A1, A2, B, C and D are reproduced. A3, A4, B2, B3, D2, E, G and G-typed are mine. Every pin goes red for its named reason. G against G-typed shows that the widening made the :2213 assertion strictly *more* sensitive: with `any(Stockunit.class)` it was blind to a null first argument.

## Stage 1: does each fix answer its round-2 finding?

| R2 finding | Fix in d0cc2ae1 | Verdict |
|---|---|---|
| **L-A** operator-id removal unpinned | `.hasMessageNotContaining("999")` + `.satisfies(e -> assertThat(e.getLocalizedMessage()).isEqualTo("Picking order PO-001 is assigned to another user."))` (`PickingorderBusinessServiceUnitTest:2244-2249`) | **Fixed.** A1, A2 and A4 are red. A3 (root bundle only) is not seen by this test, because the machine locale is `en_US` and `getLocalizedMessage()` uses `Locale.getDefault()`. It is caught anyway by `BaseBundleCompletenessContractTest` (same template in both bundles). So both bundles are pinned in any build locale. |
| **L-B** release `@Transactional` unpinned | reflection test `resetAndRelease_shouldEachBeOneTenantTransaction` (`MobilePickingServiceUnitTest:2793`), asserting presence, `value()=="tenantTransactionManager"` and `rollbackFor ∋ BusinessException` for both methods | **Fixed.** B, B2 and B3 are red. Asserting `BusinessException` in `rollbackFor` is the load-bearing part: `BusinessException extends Exception` (checked), and Spring does not roll back on checked exceptions by default. Not asserting `FacadeException` is correct, because neither method declares it. |
| **L-C** verify null-PUL refusal unpinned | `processRapidPickScanPackageToVerify_shouldRefuse_whenTheStoredLineHasNoTote` (:2782), asserting the message and `verify(pickingorderUnitloadRepository, never()).findById(any())` | **Fixed** (C red). The `never()` uses bare `any()`, so it is not null-blind, which matters because the unguarded call would pass `null`. |
| **L-D** cross-order refusal advised "Pass" | `storedPickMismatchRefusal` branches on `"picking order".equals(field)` → `"it is not on picking order " + lockedOrder.getNumber() + "."` | **Fixed**, and pinned in both directions (D, D2). `lockedOrder` is the **posted** order (`findByIdForUpdate(postedPosition.getPickingorderId())` :1398), and the caller has already passed the operator check on it (:1401-1409). So the number echoed is the caller's own claimed order, which is no disclosure. The optional second half of L-D (release naming the other operator) was not taken. See R3-1. |
| **L-E** "No pick given" reused for a missing order id | `"No picking order given for pick " + postedPosition.getNumber()` (:1396) | **Fixed** (E red). Cosmetic residue: R3-2. |
| **L-F** circular deferral reasons | not code | **Correctly not in the commit.** It is a ticket-note item. I could not verify it from the worktree (there is no plan doc; T2 keeps it on the ticket). See Open questions. |

### The three arch-rail repairs

- **`NeverMatcherNullBlindnessArchTest` inventory: justified by the declared types.**
  - `"MobilePickingServiceUnitTest:2"`:
    - The two primitive-capable sites in `never()` spans are :2693 and :3784, both `transferUnitLoadToLocation(any(), any(), anyBoolean(), any(), any(), any())`.
    - The declaration is `transferUnitLoadToLocation(Unitload, Location, boolean ignoreLock, String, String, String)` (`UnitloadBusinessService:221`), so param 3 is a primitive.
    - Blame puts :2693 in `5c294911` (this ticket's gate-test commit, not on `origin/develop`). The base `9c02b224~1` had `:1`. So +1 is exactly this ticket's site.
  - `"PickingorderBusinessServiceUnitTest:5"`:
    - The +2 are :2213 and :2226 `changeReservedAmount(any(), any(), anyBoolean(), any(), any(), any())`. Blame shows both lines were last edited in d0cc2ae1 and are new on this ticket.
    - The declaration is `changeReservedAmount(Stockunit, BigDecimal, boolean zeroIfNegative, String, String, String)` (`StockunitBusinessService:651`), so param 3 is a primitive.
    - The base had `:3`. The rail's per-class equality passes at head.
- **`any(Stockunit.class)` → `any()` on `changeReservedAmount`: no ambiguity, no blinding.**
  - `StockunitBusinessService` declares a single `changeReservedAmount`, so there is no overload for `any()` to collide with.
  - G against G-typed proves the widening increases sensitivity.
- **`any(PickingorderPosition.class)` → `any()` on `assertPickNotCancelled` (:2741): no ambiguity, no blinding.**
  - The two overloads differ in arity (1 against 3). A one-argument call can only bind the public 1-arg method, so there is no ambiguity and it compiles.
  - The 3-arg overload is package-private in `net.aim_ai.wms.service`, so `MobilePickingService` (in `…service.mobile`) cannot call it. The 1-arg `never()` is therefore the complete assertion for this caller.
- **`TransferVerifications.verifyNoTransfer`: covers all overloads.** `StockunitBusinessService` declares exactly three `transferStockToUnitLoad` overloads (8/9/10 args, :194/:203/:250). The helper verifies `never()` on all three, with `anyBoolean()` only on the two declared `boolean` slots. `NoBareTransferNeverRailTest` is green at head (5/5), so no bare transfer `never()` is left in either test class.

## Stage 2: interactions and regressions

- **Asserted message texts are unchanged where the tests rely on them.**
  - `"does not match the stored pick"`: still the prefix for every field, including the cross-order branch (`"Pick X does not match the stored pick (picking order): it is not on picking order PO-001."`). Asserted by `MobilePickingJudgesTheStoredPositionIT:246`, unit tests :2607 and :2739 (`"(picking order)"`), and :2765. All are green in the probe, except the IT, which I did not run (no mvn verify here). The IT's text is a substring the change keeps for the field branch it exercises.
  - `"No pick given"`: still produced by `requirePositionId` (:1597), which is unchanged. Its assertions (:2653, :2826, :2860, :2872) cover the null-id path and are green. Only the no-*order*-id path changed text, and `git grep` finds no other test or IT asserting `"No pick given"` on that path.
- **UI.** `wms2-mobile-ui` toasts `errors[0].message` verbatim (round-2 evidence). The new strings are plain text, and the only caller-controlled part is the posted `number`, echoed back to the caller.
- **No production behaviour change** beyond the two message texts. Every other change in the commit is test-only.

## Issues

### [LOW] R3-1: L-D's optional half is neither done nor recorded: release still names the other operator
File: `MobilePickingService.java:1655-1657`

```java
User operator = userRepository.findById(pickingOrder.getOperatorId()).orElseThrow(...);
throw new BusinessException("Parcel assigned to user " + operator.getName());
```

Confidence: HIGH (fact) / impact LOW (pre-existing; crafted request only)

Issue:
- Round 2 offered this as optional and tied it to the sec L3 / sec M1 product call. The commit leaves it as is, which is a legitimate choice, but neither the commit message nor any evidence file records the deferral.
- There are now four sites with two shapes of "assigned to" message: rapid :1408 (id), reset :1581 (id), release :1657 (**name**), and processPick.

Fix: add one line to the ticket's deviation note. Say that release's operator-name text is deferred to the sec L3 product call, and list the four sites.

### [LOW] R3-2: the no-order refusal renders "for pick null" when the body has no number either
File: `MobilePickingService.java:1396`

```java
throw new BusinessException("No picking order given for pick " + postedPosition.getNumber());
```

Confidence: HIGH (fact) / impact cosmetic (only crafted or broken clients reach it; the honest handheld always sends both id and number)

Fix (optional): fall back to the id, e.g. `"No picking order given for pick " + (postedPosition.getNumber() != null ? postedPosition.getNumber() : "id " + postedPosition.getId())`. Or accept it as is and note it.

## Open questions (not blocking)
- **L-F** is owed on the ticket, not in code. The real reasons are:
  - code L2: the stored-order, locked, null-or-caller property;
  - sec L3: parity with `rapidPickingScanSource:1408`.
  I cannot see from the worktree whether the ClickUp deviation note now cites them instead of "gate-pinned". Check before the PR.
- **Round-2 LockReadRail open question** (`MobilePickingServiceIntegrationTest.mobileRapidPickingService_RapidPass_Test` with release now taking a JPQL lock inside the test transaction). Nothing in d0cc2ae1 changes it. The `mvn clean verify -Pci` running in the ticket worktree is still the instrument; read its failsafe report for that test.
- The reflection pin (L-B) proves the annotation, not that the call goes through the proxy. Round 2 established by grep that there is no in-class self-call to `releasePickingOrder(PickingorderPosition)`. That still holds, because d0cc2ae1 adds no caller. Not a finding.

## Positive observations
- Each round-2 gap now has a pin that I watched go red under the mutant written against it, and also under its sibling mutants: B2/B3 (qualifier and rollback), A3/A4 (single-bundle drift) and D2 (the inverse advice).
- The L-D pin is two-sided. `shouldNotAdvisePass` and `shouldAdvisePass` together rule out both "always" and "never". A one-sided pin would have let the advice silently disappear for the honest stale-copy case.
- The arch-rail repairs follow the rails' own instructions. Each inventory bump cites the declared parameter, and I checked that against the source declaration. Reference slots were widened and primitive slots kept narrow. Bare transfer `never()`s moved into the one helper that covers all three overloads.
- Widening `any(Stockunit.class)` was a real strengthening, not just rail hygiene. G-typed shows the old matcher missed a null-stock-unit call.

## Recommendation
**APPROVE.** There are no CRITICAL, HIGH or MEDIUM findings. L-A to L-E are fixed and mutation-pinned, the rail edits are justified by declared types, and no asserted message text regressed. Per the fix-every-finding policy:
- record **R3-1** together with **L-F** in the ticket deviation note;
- either take **R3-2** (one line) or note it.
