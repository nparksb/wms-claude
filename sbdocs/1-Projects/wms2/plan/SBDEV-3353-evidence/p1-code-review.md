head: 3bcb4a69

# SBDEV-3353 — P1 independent code review

- Reviewer lane: code-reviewer (separate from the authoring lane). Tree: `.claude/worktrees/wms2-api/SBDEV-3353-review` (detached at `3bcb4a69`). Diff: `5fa9bef0...3bcb4a69`, 20 files, +1745/−45.
- Spec: `architect-consult.md`, `tdd-gate-baseline.md` and `implementation.md`, plus Nam's decisions: type-only, every amount and every arm, no shipped test, no CANCELED exemption, fail-closed ⇒ proceed.
- Method: read-only. I used `git grep`/`sed` against the review tree and ran no Maven. The executor's 275/0/0 targeted lane and 7069/0/0/1 full suite are not re-run here; this review grades the code and the tests, not those counts.

## Verdict: REQUEST CHANGES

There is one HIGH finding at HIGH confidence. H1 is an operator stock-move route out of a Package that no guard covers, and the architect's sweep misclassified it. Everything the spec named is implemented correctly. The RTS rollback is sound, proven below from the annotations. The three `lenient()` edits weaken nothing.

| Severity | Count |
|---|---|
| HIGH | 1 |
| MEDIUM | 1 (+2 open questions) |
| LOW | 9 |

---

## Stage 1 — spec compliance

| Spec item | Status | Evidence |
|---|---|---|
| Guard at the top of `StockunitService.transferStock`, before the arm dispatch | ✅ | `StockunitService.java:332`, after the clamp and log and before `if (isTransferToExistingContainer)`. No write precedes it in the method. |
| RTS covered via `transferStock` | ✅ | `CancellationReversalService.java:355` is the only move in `completeReversal` |
| `MobileTransferOrderService.transferStock` | ✅ | `:367`, the first statement after the log |
| `MobileMoveUnitloadService` stock-move path | ✅ | `:636`, inside `if (stockUnits.size() > 0)`, right before `transferStockToUnitLoad` |
| NOT `handleTruckOffLoading`, NOT inside `transferStockToUnitLoad` | ✅ | Neither is touched. The pin `transferStockToUnitLoad_shouldStillMoveStock_whenBothContainersArePackages` guards the second one. |
| Type-only, every amount and arm, no shipped test, no CANCELED exemption | ✅ | The helper reads only `type.getName()`. Case 7 pins SHIPPED (405). |
| Fail-closed ⇒ proceed | ✅ | A null unitloadId, a missing UL, a null typeId, a missing type row and a null name all return. All five are tested. |
| `Package` removed from `TYPES_THAT_REST_IN_A_STORAGE_LOCATION` | ✅ | `UnitloadService.java:718-722` |
| Keyed exception with a positional message in both bundles | ✅ | See §5 |
| **"Refuse an operator stock move whose source container is a Package"** | ❌ **incomplete** | See H1: `/v3/stockUnit/transferToDamaged` is an operator stock move out of the source container, and it is unguarded |

---

## Findings

### [HIGH] H1: Web "Transfer to Damaged" drains an unlocked parcel with no guard
- **Where:** `StockUnitController.java:531-553` (`@RequiresFunction(WEB_UI_ACTION_ADJUST_LOCK_DAMAGED) @PostMapping("/transferToDamaged")`) and `:570-595` (`/bulkTransferToDamaged`). These call `StockunitService.setLockDamaged:747`, which calls `UnitloadService.moveStockToNewDamagedContainer:158`, which calls:
  ```java
  Stockunit damagedStock = stockunitBusinessService.transferStockToUnitLoad(
      stockUnit, container, amount, WmsConstants.CODE_DAMAGED, null, comment, false, true);
  ```
- **Confidence:** HIGH on reachability, MEDIUM on how large the live population is.
- **Why it is the same defect:**
  - `setLockDamaged`'s lock switch accepts `NOT_LOCKED` (`case NOT_LOCKED: break;`). That is exactly the H2 population, a force-cancelled PACKED parcel whose stock is unlocked. The consult puts it at 1 row on WineCo UAT, lock 0, co 800.
  - `removeUnitLoadIfEmpty=true`, so a full-amount transfer empties the parcel. It then goes to `relocateEmptiedContainer`, whose `default:` branch calls `sendToNirvana` (`UnitloadBusinessService.java:651-660`). That applies the To-Delete lock and the `-X-<id>` label while `customerorder.parcel_id` and the BOL still name the parcel. This is the irreversible H3 outcome the set's javadoc warns about.
  - A partial transfer leaves the parcel short against its manifest (consult §4).
- **Why it was missed:** architect-consult §2 lists "`UnitloadService:175` damage" under *non-operator callers (must NOT be guarded)*. It is operator-reachable through two gated web endpoints. The only non-operator caller of `setLockDamaged` is `ReturnAdviceAutoReceiveService:1003`, whose source is freshly received stock and never a Package, so a guard there costs nothing.
- **Fix:**
  - Add `SourceContainerGuard.assertStockNotInParcel(stockUnit, unitloadRepository, unitloadTypeRepository);` at the top of `StockunitService.setLockDamaged`, after the clamp. `StockunitService` already holds both repositories.
  - Add a refusal test (Package source, lock 0, `never(moveStockToNewDamagedContainer)`) and a Case control.
  - It is sub-T3 and on this ticket's own route family, so per `wms-triage` it goes on SBDEV-3353.

### [MEDIUM] M1: Javadoc and test text now claim more than the code delivers
- **Confidence:** HIGH.
- **Where:**
  - `UnitloadService.java:704-707`: "*That path is now unreachable from the operator moves: `SourceContainerGuard` refuses any stock move out of a `Package`…*"
  - `UnitloadServiceUnitTest.java:2049`, `@DisplayName`: "*…once the source guard makes Nirvana unreachable*"
- **Issue:**
  - While H1 is open, and possibly Q1 below, the Package → Nirvana path is still reachable from an operator action.
  - The sentence "*this set stops the whole-container arm relocating a parcel into a rack, and the guard stops the split arm draining one*" (`:707-709`) also misdescribes the mechanism. `restsInStorageLocation` has exactly one caller, `StockunitService.java:525`, which sits after the guard. So for a known Package type the set entry is unreachable today, and the guard stops both arms. The set is defence in depth, which covers only the fail-closed case where the guard could not resolve the type. That is correct design, but the prose credits the set with a job it does not currently do.
- **Fix:**
  - After H1, reword to "unreachable from the operator stock moves that call `SourceContainerGuard` (…list…)".
  - Describe the set as the backstop: "with the guard in place the set is not consulted for a resolvable Package; it keeps the whole-container arm correct if the guard is removed or bypassed".

### [LOW] L1: The web guard reads the controller's detached snapshot, not an in-transaction row
- **Confidence:** MEDIUM.
- **Where:** `StockunitService.java:332` reads `stockUnit.getUnitloadId()` from the instance that `StockUnitController:150` loaded in its own short read (OSIV off, controller not `@Transactional`; see the SBDEV-3341 F1 comment at `:534-538`).
- **Issue:**
  - The guard runs before, and independently of, the 3341 `freshSource` re-read (`:545`), which only feeds `SourceLockGuard`.
  - It is consistent with the rest of the method, whose every arm keys off the same snapshot `unitloadId` (`:364`, `:439`, `:677`, `:695`), so it does not break correctness on its own.
  - The residual race: packing re-homes the same row into a Package between the controller read and this transaction, and the operator chose Damaged (`ignoreLock=true`, `:585`/`:593`). `transferStockToUnitLoad`'s `findByIdForUpdate`+refresh then operates on a row that is now in a Package, and no guard sees it. The `ignoreLock=false` arms are still covered by the lock-100 check.
- **Fix:** resolve the container from `stockunitRepository.findById(stockUnit.getId()).orElse(stockUnit).getUnitloadId()` inside the guard's caller. A plain `findById`, not FOR UPDATE, for the same lock-order reason as `:540-543`. This narrows the window the same way F1 did. Alternatively, accept it and note it in the javadoc.

### [LOW] L2: The `lenient()` edits hide nothing, but they route the guard through its fail-closed branch
- **Confidence:** HIGH.
- **Where:**
  - `StockunitServiceToteContainerRelocationUnitTest:516`
  - `StockunitServiceTransferStockDestinationTest:530`
  - `StockunitServiceUnitTest:1696`
- **Analysis, per item 3:**
  - **ToteContainerRelocation `palletCarrierMintSiteIsAlsoGated`:**
    - `findById(CASE_TYPE_ID)` is still consumed by the mint-type lookup, and the test's own `verify(locationConstraintService).isUnitloadTypePermitted(RACK_LOCATION_TYPE_ID, CASE_TYPE_ID)` depends on it. So the stub is live and the assertion is intact.
    - The guard asks `unitloadTypeRepository.findById(TOTE_TYPE_ID)`, which is unstubbed. It therefore passes because the type is *unresolvable*, not because it is a Tote.
  - **TransferStockDestination:530 and StockunitServiceUnitTest:1696:** `findById(FLA_UNITLOAD_ID)` and `findById(500L)` are the FLA-assigned destination UL. The FLA arm still consumes both, and the tests' flow-bin assertions depend on them. The guard's `findById(<source UL id>)` returns empty, so the move proceeds because the unit load is *unresolvable*.
  - None of the three stubs became unused, and no assertion changed. `lenient()` only relaxes argument-mismatch detection on that one stub.
- **Cost:** these three fixtures now exercise the guard's fail-open path for a real, known non-Package container. A later regression that made the guard throw for Tote or Case would still be caught elsewhere, by `storableContainerStillRelocatesTheContainer` and the refusal class's controls, so this is Low.
- **Fix (preferred):** keep the stub strict and add the read the guard makes:
  - `when(unitloadTypeRepository.findById(TOTE_TYPE_ID)).thenReturn(Optional.of(toteType))`
  - `when(unitloadRepository.findById(<source id>)).thenReturn(Optional.of(<source UL>))`
  
  STRICT_STUBS then stays armed, and the guard sees a real type.

### [LOW] L3: The ArchTest ratchet comment for `MobileMoveUnitloadServiceUnitTest` names a site that does not exist
- **Confidence:** HIGH.
- **Where:** `NeverMatcherNullBlindnessArchTest.java:455-458`: "*New never() assertions on transferStockToUnitLoad (params 7-8 …) and transferUnitLoadToLocation (param 3 …)*" (1 → 3).
- **Issue:** the new `Sbdev3353ParcelSourceStockMove` class has no `never().transferUnitLoadToLocation`. Its `verifyNothingMoved` has `transferStockToUnitLoad` (2 primitive positions), `sendToClearing` and `sendToNirvana`. The +2 is fully explained by `transferStockToUnitLoad`. The same comment was pasted onto all three entries, and it is true for the other two (MobileTransferOrder +3 = 2+1, the refusal class 6 = 2×2 + 2×1).
- **Fix:** drop the `transferUnitLoadToLocation` clause from the MobileMoveUnitload entry.

### [LOW] L4: Stale test comment still lists Package as storable
- **Confidence:** HIGH.
- **Where:** `StockunitServiceUnitTest.java:1989-1990`: "*the source container must be one that rests in a storage location (Case / PickLocation / Default / Package — not a Tote)*".
- **Fix:** remove "/ Package". The executor's old-literal sweep did not match this phrasing. It is the same class of miss as memory "prose enumerations rot": the sweep grepped tokens, not the rule.

### [LOW] L5: The mobile transfer guard now pre-empts non-moving outcomes
- **Confidence:** MEDIUM.
- **Where:** `MobileTransferOrderService.java:367`, placed before the transfer-lane validation (`"Order has no transfer lane"`, `"Order has transfer lane = …"`) and before the `amountNeeded <= amountOnTransferLane` branch, which returns `"No stock required. Bring back unitload …"` and moves nothing.
- **Issue:** a Package source now gets the parcel refusal where it used to get a lane-mismatch diagnosis or a "nothing to do". This is defensible under type-only, and it never permits a move. It does change operator-visible messages on paths that write nothing.
- **Fix:** either accept it and state it in the call-site comment, or move the guard below the lane checks and the no-stock-required return, just above `int amountLeft`. Every arm that writes is below that line.

### [LOW] L6: An empty-string label renders as "Container  is a parcel"
- **Confidence:** HIGH.
- **Where:** `SourceContainerGuard.java:79`: `Objects.toString(sourceUnitload.getLabelid(), String.valueOf(sourceUnitload.getId()))`. It falls back only on `null`.
- **Fix:** use `(label == null || label.isBlank()) ? String.valueOf(id) : label`, and add a case to `refusal_shouldNameTheParcelById_whenItHasNoLabel`.

### [LOW] L7: Several refusal tests have no same-arm control, so their arm names are unproven
- **Confidence:** HIGH.
- **Where:**
  - `MobileTransferOrderServiceUnitTest$Sbdev3353ParcelSource`: only the partial arm has a Case control. The FLA-whole, whole-split and reserved-split refusals have none.
  - `MobileMoveUnitloadServiceUnitTest`: `scanDestination_shouldRefuse_whenAParcelIsDrainedIntoAFixedAssignedUnitLoad` has no Case control on the FLA-backed arm. The flow-bin LOCATION arm (`:423`) is not exercised at all.
- **Assessment (item 7):**
  - These refusals are not vacuous. Each asserts `getKey() == "transferStockSourceIsParcel"`, and a fixture that fell over earlier would throw a different key or an NPE.
  - The `never()` assertions are load-bearing for "refused before any write", and they are the right assertions for a top-of-method guard.
  - What is unproven is only that each fixture, with the type flipped to Case, reaches the arm its `@DisplayName` names. In `StockunitServiceParcelSourceRefusalUnitTest`, every named arm does have a Case/Default/PickLocation control (partial-rack, damaged, existing container, whole-rack relocation, pallet, flow bin, QF), which is good.
- **Fix:** add one parameterized Case control per mobile arm, or rename the tests to not claim the arm.

### [LOW] L8: The IT's lock-rollback assertion has never been shown to go red
- **Confidence:** HIGH.
- **Where:** `CancellationReversalParcelSourceIntegrationTest.aReversalOutOfAParcelIsRefusedAndRollsBackTheLockClear`.
- **Issue:** the only mutant run against it was (a), guard deleted. That mutant fails at `:271` (no exception) before the `after.lock()` assertion executes, so the assertion this IT exists for, "only the rollback puts 100 back", was never mutation-checked. It is not vacuous by construction:
  - the precondition asserts 100 in a separate transaction;
  - the re-read uses a new read-only `TransactionTemplate(tenantTransactionManager)`;
  - the class is not `@Transactional`;
  - `completeReversal` is invoked on the autowired proxy.
  
  But the floor asks for a red.
- **Fix:** run a mutant that removes `rollbackFor` from **both** `completeReversal:190` and `StockunitService.transferStock:320`. Removing only the outer one is not enough; see §2. Expect `after.lock()` = 0, then restore.

### [LOW] L9: `case UNIT_LOAD_TYPE_PACKAGE: // waterfall` is now dead on the stock-move path
- **Confidence:** HIGH.
- **Where:** `MobileMoveUnitloadService.java:671-672`.
- **Issue:** a Package source now throws at `:636` before this switch. The executor left the case in on purpose to limit scope, which is fine, but a reader will take it as live behaviour.
- **Fix:** add a one-line comment: `// unreachable since SBDEV-3353: SourceContainerGuard refuses a Package source above`.

### [LOW] L10: RTS refuses after a write, and relies on rollback
- **Confidence:** HIGH.
- **Where:** `CancellationReversalService.java:350-355`.
- **Issue:** the parcel refusal fires after the lock clear, the `save` and the `flush`, and relies on the rollback. That is correct (§2). But `completeReversal` has a pre-validate loop whose stated purpose is "*fail atomically before any stock movement*". Checking the parcel there would refuse before any write, and before a sibling position's reversal has already moved stock in the same transaction.
- **Fix (optional):** call `SourceContainerGuard.assertStockNotInParcel(sourceStockunit, …)` in the pre-validate loop as well. That needs the two repositories on `CancellationReversalService`, which is a constructor change, so it stays optional.

---

## Open questions (surfaced, not blocking)

### [MEDIUM] Q1: Mobile putaway into a flow bin can drain a parcel that sits in Clearing
- **Confidence:** LOW to MEDIUM.
- **Where:**
  - `MobilePutAwayService.findUnitLoad:120` accepts a unit load whose location is Clearing (`!locationArea.getUseforgoodsin() && !storageLocation.getId().equals(<CLEARING>)` ⇒ throw).
  - `CustomerorderService:527`: the `forceCancelOrder` PACKED arm calls `sendToClearing(parcel, …)`.
  - `storeBoxOnLocation`'s flow-bin arm (`:557`): `transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad, …, CODE_PUT_AWAY, null, null, false, true)`. This drains the parcel, and `removeUnitLoadIfEmpty=true` sends it to Nirvana.
- **Why low confidence:**
  - The consult's one live H2 row is at `Packaging`, not Clearing. The UAT data does not show whether PACKED force-cancels land in Clearing.
  - Nam's decision (a) accepted that restocking an H2 parcel "goes through mobile or an admin". This may be the intended remedy route. If so, its Nirvana outcome contradicts the ticket's rationale.
- **Needs:** Nam's call, and a DB query for Package unit loads in Clearing across tenants.

### [MEDIUM] Q2: Web now refuses a whole-parcel relocation into a rack that mobile still allows
- **Confidence:** LOW.
- **Where:** `MobileMoveUnitloadService.scanDestination:392` (non-flow-bin destination) calls `transferUnitLoadToLocation(sourceUnitLoad, destinationStorageLocation, …)` for any source type, a Package included, into any non-flow-bin location, a rack included.
- **Issue:** after this change the web whole-container arm refuses the same outcome, through the guard and the set.
- **On the executor's out-of-scope call — I agree for this ticket:**
  - That arm moves the parcel whole, so the manifest and parcel contents stay intact. It is not "taking stock out".
  - The neighbouring whole-UL route `transferUnitLoadToCarrier` (`:470-475`) is the legitimate re-palletization / truck-loading workflow (SBDEV-3452 comment at `:466-469`). A type-only guard on whole-UL moves would break it.
  - `handleTruckOffLoading` was excluded by decision.
- The residual rack-relocation asymmetry is a sibling concern. Propose it to Nam as a separate item; do not file it.

---

## §1 Coverage sweep — what matched, and what it cannot see

**Instrument:** `git grep -n "transferStockToUnitLoad(\|stockunitService.transferStock(\|\.transferStock(" 3bcb4a69 -- src/main`, plus the `transferUnitLoadToLocation(`/`transferUnitLoadToCarrier(` caller census and the `setLockDamaged(`/`moveStockToNewDamagedContainer` callers. Positive control: the sweep found all three spec-named sites.

| Caller of `transferStockToUnitLoad` / `transferStock` | Operator? | Source can be a Package? | Guarded? |
|---|---|---|---|
| `StockUnitController:156/:270` → `StockunitService.transferStock` (8 arms) | yes | yes | ✅ `:332` |
| `CancellationReversalService:355` → `transferStock` | yes (RTS) | residual gap (consult §3) | ✅ via `:332` |
| `TransferOrderController:101` → `MobileTransferOrderService.transferStock` (`:420/:426/:431`, plus FLA whole-UL) | yes | yes | ✅ `:367` |
| `MobileMoveUnitloadService:637` (private `transferStock`, from `:423/:465/:479`) | yes | yes | ✅ `:636` |
| **`StockUnitController:553/:595` → `setLockDamaged` → `UnitloadService:175`** | **yes** | **yes (lock 0)** | ❌ **H1** |
| `MobilePutAwayService:557` (flow-bin putaway) | yes | only if a parcel is in Clearing | ❌ **Q1** |
| `MobileReplenishService:631` | yes | only for a legacy parcel standing in a rack | no (system replenishment source; out of scope) |
| `PickingorderBusinessService:1150` | picking | same as above | no (out of scope, by design) |
| `CustomerorderService:646` (`packageOrder`), `BillofladingService:1075/:1094`, `ClubLineOrderProcessor:197` | system | Package is the destination or a legitimate source | must NOT be guarded ✅ (not guarded; pinned by the FullMoveInvariant test) |

**Moves the whole parcel, not its stock:** `MobileMoveUnitloadService:392` (Q2), `:470` (`transferUnitLoadToCarrier`, legitimate palletizing), `handleTruckOffLoading` (excluded), the putaway whole-UL arms, and `ParcelMonitorViewService`. These are out of scope.

**Blind spots:**
- Direct `stockunit.setUnitloadId(` / `setAmount(` writers: 18 non-comment `setUnitloadId(` hits in `src/main`, not individually traced.
- Inventory adjustments: `/adjustAmount` and `/bulkAdjustAmount` reduce a parcel's quantity. That is not a move, so it is outside the spec, but it is the same manifest-corruption class.
- `StockunitRepository` is `@RepositoryRestResource(path = "stockunit")`, so an SDR `PATCH` of `unitloadId` is not seen by any service guard. See memory "Access-chain hops writable over SDR". The SDR programme owns this.
- Reflection and proxy-mediated calls.
- Callers reached only from `src/test`.

## §2 Guard placement vs lock/transaction — RTS rollback, proven from the annotations

- `CancellationReversalService.completeReversal:190-191`: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, public, `throws BusinessException, FacadeException`. The only caller is `OrderCancellationController:64` through the injected bean, so it is cross-bean and the proxy applies.
- `BusinessException extends Exception` (`exceptions/BusinessException.java:14`), so it is **checked**. Without `rollbackFor` Spring would commit. It is listed.
- `StockunitService.transferStock:320`: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. It has the same manager and default propagation REQUIRED, so it **joins** the reversal's transaction. When the guard's `BusinessException` leaves the inner proxy, `rollbackFor` matches, and a participating transaction marks the shared transaction **rollback-only**.
- `completeReversal` does not catch around `:355`, so the exception propagates, and the outer `rollbackFor` rolls back the whole unit:
  - the `setEntityLock(NOT_LOCKED)` plus `save` plus `entityManager.flush()` at `:350-352`;
  - any earlier position's completed move in the same call.
  
  A flush sends SQL inside the transaction but does not commit it, so the rollback reverts it.
- The design is doubly protected. Removing only the outer `rollbackFor` would still leave the inner rollback-only mark, producing `UnexpectedRollbackException` at commit and a rolled-back lock. Hence L8's mutant must remove both.
- **Placement vs the 3341 re-read:** the guard runs before it and reads the snapshot `unitloadId`, not `freshSource` (L1). For RTS this does not matter: `completeReversal` loads the stock unit in-transaction at `:279` (`stockunitRepository.findById`), so the snapshot is fresh.
- **The IT really does re-read in a new transaction:**
  - `rereadInANewTransaction` builds a `new TransactionTemplate(tenantTransactionManager)` with `setReadOnly(true)`.
  - The class extends `BaseRollbackIntegrationTest` and is not `@Transactional`.
  - The service is `@Autowired`, i.e. the proxy.
  - The Case control shows the same fixture commits: lock 0, the stock moves, and 1 outbox row is written.
  - Remaining gap: L8.

## §3 The `lenient()` edits
They weaken nothing; see L2. Each stub is still consumed, and the assertion that depends on it is unchanged. The cost is only that the guard takes its fail-closed branch in those fixtures.

## §4 The deleted `shouldBeTrue_forPackage`
It is net-renamed and flipped into `restsInStorageLocation_shouldBeFalse_whenTheContainerIsAPackage` (`UnitloadServiceUnitTest:2050`). The rest of `RestsInStorageLocation` still pins:
- Box, PickLocation and Default true (`:2083-2084`);
- Tote and Pallet false (`:2097-2098`);
- unknown and custom names false (`:2106/:2117`);
- null type and null UL false (`:2126-2127`).

Hand mutant (c), Package re-added, turns the new test red. Nothing is uncovered. The deleted test's prose about the 405 grid filter was rationale, not coverage.

## §5 Message key
- Present in both bundles that carry the `transferStockDestination*` siblings (`messages.properties:37`, `messages_en_US.properties:367`). `git ls-files` shows no other `messages*` bundle.
- It uses positional `%1$s`, not bare `%1s`.
- The argument is `labelid` with an id fallback, so it is operator-facing. It cannot render "null": a null label falls back to the id, and a persisted UL has a non-null id. An empty label is a gap (L6).
- The web and mobile controllers render `e.getMessage()`, which the keyed constructor resolves through the bundle.
- The constant equals the literal, pinned by `refusal_shouldNameTheParcelByLabel`.

## §6 Stale comments
- Stale: `StockunitServiceUnitTest:1989` (L4). Overstated: `UnitloadService:704-709` and `UnitloadServiceUnitTest:2049` (M1).
- The `KNOWN_NON_REUSABLE_TYPE_NAMES` claim, "now DIFFERS by exactly `Package`", is **true**:
  - `UnitloadBusinessService.java:601-606` = {Box, PickLocation, Package, Default};
  - `TYPES_THAT_REST…` = {Box, PickLocation, Default}.
- Its javadoc (`:594-600`) makes no equality claim, so there is nothing to update there.
- The `UnitloadBusinessService:640` "under SBDEV-3340" disambiguation is correct.
- No `src/main` comment still says Package rests in storage or that a parcel ticket is pending.

## §7 Test quality
See L7 and L8. The refusal class in `StockunitServiceParcelSourceRefusalUnitTest` is well built:
- key-asserting, so a different `BusinessException` cannot pass;
- a full `never()` write set;
- same-arm controls for every named arm, across three storable types;
- a fail-closed trio;
- bundle checks that load each file with its own UTF-8 `Properties.load`, avoiding the ResourceBundle parent-chain trap.

## Positive observations
- A static guard with the repositories passed in avoids the "refusal graded against a stub" trap. The javadoc explains why and cites the `SourceLockGuard` precedent.
- The guard sits before the arm dispatch, not inside the `restsInStorageLocation` arm, so it covers every amount and both `ignoreLock=true` damaged arms (H1 in the consult). Deliberately keeping it out of `transferStockToUnitLoad` is pinned by a positive test.
- The null-safe `CONSTANT.equals(name)` and the skipped `findById(null)` avoid two known traps.
- The mobile guard placement respects the SBDEV-3490 diagnosis order and the SBDEV-3452 AC-10 empty-source message, and the call-site comment records why.
- The RTS IT is a real committed-state test with a non-vacuity control: the Case case writes exactly 1 outbox row. It also cleans up its shared-context `los_sysprop` row.
- PIT shows 0 survivors on the new lines, and hand mutants (a)/(b)/(c) each fail the expected set.

## Recommendation
**REQUEST CHANGES.**
1. Fix H1 on this ticket and test it.
2. Then fix M1's wording and L2–L7 and L9.
3. Run the L8 mutant.
4. Put Q1 and Q2 to Nam as proposals, not filed tickets.
5. L1 and L10 are optional hardening.
