---
title: "SBDEV-3339 plan review — round 2 (targeted re-review of revision 2)"
ticket: "SBDEV-3339"
type: "review"
lane: "critic2-3339"
graded_ref: "origin/develop @ 221caed1"
created: "2026-09-14"
verdict: "ITERATE (narrow — 2 findings, both in Fix 3; everything else is sound)"
---

# SBDEV-3339 — plan review, round 2

**Subject:** `sbdocs/1-Projects/wms2/plan/SBDEV-3339-cancelorder-picking-tote-teardown.md`, revision 2, 450 lines.
**Graded against:** `origin/develop` @ `221caed1` (`Merge pull request #353 from SiteBossInc/fix/outbox-latency-config`), exclusively via `git show origin/develop:<path>` / `git grep … origin/develop`. The local checkout was never read.
**Scope:** targeted — Job 1 (are the five round-1 blockers closed?) and Job 2 (what did the revision introduce?). Not a fresh review.

## VERDICT: ITERATE — narrow

All five round-1 blocking findings are **CLOSED**, every one verified against code rather than accepted as present. The revision's new material is overwhelmingly sound: I spot-checked 31 distinct factual claims that are new or changed in revision 2 and **28 verified exactly** — including every arithmetic claim (54 = 36/13/4/1, 308 = 122/92/77/17, 94 `setEntityLock(`, 14 `PICKED_FOR_GOODSOUT`, 12 `setPickingtoteId(50L)`, 9 `cancelPositions` tests, 12 docs files, 1 `src/main` `cancelBatch`).

The ITERATE is for **two findings, both inside Fix 3**, and they are the same defect seen from two sides: the containment set as specified does not contain the teardown failure the plan's own prereq 1 and §9 risk row 3 say it contains, and no test in §8 would catch that. The edit is roughly three sentences in §5 Fix 3 plus one row in §8 — this does not need a re-plan, and nothing else in the document needs to move. Everything below High is advisory.

---

# Job 1 — the five round-1 blockers

## V1 — Fix 1 block 2 (null `pickingorder_unitload.unitload_id`) — **CLOSED**

Block 2 is present, and it is a call-for-call copy of the canonical sibling. `PickingorderBusinessService.cleanUpCancelledOrder`:

```java
if (tote != null) {
    PickingorderUnitload pickingUnitLoad = pickingorderUnitloadService.getByLabel(tote.getLabelid());
    if (pickingUnitLoad != null) {
        pickingUnitLoad.setHistorytote(tote.getLabelid());
        pickingUnitLoad.setUnitloadId(null);
        pickingUnitLoad.setState(WmsConstants.State.CANCELED);
        pickingorderUnitloadRepository.save(pickingUnitLoad);
    }
}
```

The plan's block 2 writes the same three fields plus the same `save`, with terminal state `CANCELED` — matching the sibling, and diverging from `packageOrder`, which writes `FINISHED` (`CustomerorderService`, *"pickingUnitLoad.setState(WmsConstants.State.FINISHED);"*). Correct choice.

**Finder choice — correct and correctly justified.** `PickingorderUnitloadService.getByLabel` is exactly as the plan describes:

```java
public PickingorderUnitload getByLabel(String label) {
    try {
        Optional<PickingorderUnitload> pickingorderUnitloadOptional = pickingorderUnitloadRepository.findByUnitloadLabelid(label);
        return pickingorderUnitloadOptional.get();
    } catch (NoSuchElementException e) { return null; }
}
```

— it catches only `NoSuchElementException`, so `IncorrectResultSizeDataAccessException` escapes it. `findLatestByUnitloadLabelid` exists, is `exported = false` at method level, and carries the SBDEV-2742 rationale in its own javadoc. The divergence is deliberate and is flagged as such in §5 point 7.

**Placement vs the SBDEV-3316 pin — correct.** The pin requires the retirement to sit below the `recordCancellation` writes. On this branch those writes happen inside `CustomerorderPositionService.cancelOrderPosition` — verified: `cancellationLogService.recordCancellation(customerOrderPosition, pickingPosition, pickingOrder, customerOrder, tenantName, facilityCode);` sits inside `public void cancelOrderPosition(CustomerorderPosition customerOrderPosition)`, which has **exactly one** `src/main` caller, the `cancelOrder` loop at `CustomerorderService` (*"customerorderPositionService.cancelOrderPosition(customerOrderPosition);"*). Block 2 after that loop therefore satisfies the pin. Also verified: the insertion point is genuinely adjacent — `for (…) { cancelOrderPosition(…); }` is immediately followed by `customerOrder.setState(WmsConstants.State.CANCELED);`.

**The invariant behind block 2 is real.** `findByUnitloadLabelid` is `select a.* from pickingorder_unitload a, unitload b where a.unitload_id = b.id and b.labelid like :labelid` returning `Optional` — an implicit inner join, so a null `unitload_id` cannot produce a row. The three `src/main` consumers named by the plan are the three that exist: `CustomerorderService` (inside `packageOrder`, confirmed — the `findByUnitloadLabelid` call sits below `stockunitBusinessService.transferStockToUnitLoad(... CODE_PACKAGING ...)`), `PickingorderBusinessService` via `getByLabel` (the only `getByLabel(` call site in `src/main`), and `MobileInfoService`. See M3 for the one thing this census misses.

## V2 — §3's discriminator re-derived — **CLOSED** (with one over-strong sentence, M1)

The mechanism is right and it is the mechanism the code has:

- `cancelOrder`: `if (coPositions.stream().anyMatch(position -> position.getState() >= PACKED && position.getState() < WmsConstants.State.CANCELED)) { throw new BusinessException("order contains position with status beyond PACKED. can not be cancelled anymore"); }` — and this sits **above** the `canOrderPositionBeCancelled` loop.
- `CustomerorderPositionService.canOrderPositionBeCancelled` opens with `if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) { return false; }`.
- `PACKED = 650`, `PALLETIZED = 670`, `FINISHED = 700`, `CANCELED = 800` — all confirmed in `WmsConstants.State`.
- The real order-state split is confirmed: `isPackedOrPalletized(customerOrder)` → `forceCancelOrder(customerOrder)`, else `throw new BusinessException("order is beyond status PACKED and not a pre-QA club order")`.
- The regular-picking arm is quoted correctly: `if (pickingOrder.getState() >= WmsConstants.State.PACKED && pickingOrder.getState() < WmsConstants.State.FINISHED) { return false; }` and the same on the position.
- The deriving-method claim is exact: `git grep -n "canOrderPositionBeCancelled" origin/develop -- 'src/main'` returns the declaration + **nine** `LOG.debug` matches inside the method + **one** call site (`CustomerorderService`). Not approximately — exactly.

Severity now reads as universal-for-below-PACKED rather than a narrow window. That re-derivation is correct. The residual problem is one absolute sentence — see **M1**.

## V3 — §8 no longer claims the fix breaks nothing — **CLOSED**

Verified line by line against `CustomerorderServiceUnitTest` on the blob:

- `@MockitoSettings(strictness = Strictness.LENIENT)` — present at class level. `PickingorderBusinessServiceUnitTest` is `@MockitoSettings(strictness = Strictness.STRICT_STUBS)`. The plan's "do not generalise from one to the other" is right.
- Exactly **one** `@BeforeEach` in the file.
- **12** `testOrder.setPickingtoteId(50L)` sites — exactly the plan's figure.
- `shouldSkipRapidPickingCleanupWhenNotStarted` is exactly as described: `testOrder.setState(WmsConstants.State.ASSIGNED); testOrder.setPickingtoteId(50L);`, `pickingOrder.setState(WmsConstants.State.PROCESSABLE); // Not STARTED`, `when(customerorderPositionService.canOrderPositionBeCancelled(position)).thenReturn(true);`, and **no** `when(unitloadRepository.findById(50L))` stub anywhere in the method. Under Fix 1 the mock returns `Optional.empty()`, `.orElseThrow` fires, the test goes red. Confirmed red, for the stated reason.
- *"Any deviation is a regression, not noise"* does not appear anywhere in revision 2. Replaced by the correct instruction.

I independently checked the **other two** tests in the same nest, which the plan implies stay green:
- `shouldHandleRapidPickingCancellationWithEmptyTote` — `pickingOrder.setState(WmsConstants.State.STARTED)`, so the rapid branch runs and nulls the tote; it even asserts `assertThat(testOrder.getPickingtoteId()).isNull();`. Fix 1 skips. Green.
- `shouldThrowWhenRapidPickingToteNotEmpty` — throws `"not empty"` before the loop. Green.

I also mapped all twelve `setPickingtoteId(50L)` sites to their enclosing nest: only three land in `CancelOrderRapidPickingScenarios` (the only nest that invokes the real `cancelOrder`); the rest are in `CleanUpCancelledOrder`, `PackageOrderSuccessPaths`, `CleanUpCancelledOrderExtended`, `CleanUpCancelledOrderStagingLaneCleanup`, `CleanUpCancelledOrderBatchFinalization` — all of which drive `cleanUpCancelledOrder` or `packageOrder`, neither touched. The "exactly one existing test goes red" claim holds **within this file**. See **M2** for what the file-scoped derivation does not cover.

## V4 — Fix 3 contains only teardown failures — **CLOSED**

The rail exists verbatim:

```java
doThrow(new BusinessException("Wrong state")).when(customerorderService).cancelOrder(existingOrder, false);
…
assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
```

And the controller's current three arms are exactly as the plan re-describes them — `catch (BusinessException e) { throw new WebserviceBusinessExceptionClientSide(WmsConstants.WRONG_STATE, e, …); }`, `catch (FacadeException e) { throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e); }`, `catch (Exception e) { … GENERIC_ERROR … }`. **There is no `continue` in the loop** — AC-6's correction of revision 1's phantom mutant is right.

Scoping the new arm to `ToteTeardownException` leaves that stub untouched, so the 400 contract holds. The Java-ordering claim is also correct, and for a reason the plan does not state: `BusinessException extends Exception` and `FacadeException extends Exception` are **siblings**, not parent/child (`public class BusinessException extends Exception` / `public class FacadeException extends Exception`), so placing `catch (ToteTeardownException)` above both is legal; the only constraint that binds is that it must precede `catch (FacadeException)`, which it does.

The no-signature-change claim is verified end to end: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class}) public void cancelOrder(Customerorder customerOrder, boolean cancellationFromWithinWMS) throws BusinessException, FacadeException`. A `FacadeException` subclass needs no `rollbackFor` edit and no `throws` edit. And nothing swallows `FacadeException` between the throw and the controller: the two `src/main` callers of `cancelOrder` are `OrderRestController.cancelPositions` and `UtilRestController.resetOrdersInReleasedStatus`, and `UtilRestController` is `@Service` (not `@RestController`), so the plan's dead-route finding is confirmed.

`FacadeException` does provide `public FacadeException(String message, Throwable cause)`, so `ToteTeardownException` is constructible in the wrapping shape the plan uses.

## V5 — §5.4 counts — **CLOSED, exact**

`git grep -o "cancelBatch" origin/develop -- <file> | wc -l`:

| File | Count |
|---|---|
| `CustomerorderBatchServiceUnitTest` | **36** |
| `CustomerorderBatchOutboxIntegrationTest` | **13** |
| `CancelOrderRollbackIntegrationTest` | **4** |
| `PickingorderBusinessServiceUnitTest` | **1** |
| **total, `src/test`** | **54** across **4** files |

`src/main` contains exactly **one** occurrence — `public void cancelBatch(CustomerorderBatch orderBatch, Principal principal) throws BusinessException, FacadeException` — and `docs/` contains **12** files. The `docs/plan/completed/WMS_Staging_Lane_Bug_Fix_Plan.md` quote is verbatim: *"`cancelBatch()` has no callers; wiring it to a controller is a separate enhancement"*. All five numbers correct.

---

# Job 2 — defects the revision introduced

## HIGH

### H1 — Fix 3's containment set misses `EntityNotFoundException`, which is the teardown's most likely failure and the one prereq 1 and §9 row 3 claim it covers

§5 Fix 3 specifies the wrap as `catch (BusinessException | FacadeException e) { throw new ToteTeardownException(…, e); }`, plus the ⚠ note *"The wrap must also catch the unchecked `DataAccessException` family"*. That set does not include `EntityNotFoundException`, and on `origin/develop`:

```java
public class EntityNotFoundException extends RuntimeException {
```

`net.aim_ai.wms.exceptions.EntityNotFoundException` is a bare `RuntimeException` — not a `DataAccessException`, not checked. It is thrown at **both** of the teardown's entry points:

1. `UnitloadBusinessService.sendToClearing`: `Location clearingLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_CLEARING).orElseThrow(() -> new EntityNotFoundException("Location not found by name: " + WmsConstants.STORAGE_LOCATION_CLEARING));` — this is prereq 1's scenario word for word (*"a tenant missing it turns a cancel into `EntityNotFoundException`"*), and §5.2 lists it **first** among the new throw sources.
2. Fix 1's own opening line: `unitloadRepository.findById(customerOrder.getPickingtoteId()).orElseThrow(() -> new EntityNotFoundException("UnitLoad", …))`.

So under the wrap as specified, the single most likely teardown failure is never converted to `ToteTeardownException`. It falls past the new arm into the controller's existing `catch (Exception e) { LOG.error(…); throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e); }` and **aborts the whole batch** — precisely Option A, the behaviour §5.2's DECISION rejected.

Three statements in the plan are false as a consequence:
- §9 risk row 3, *"Fix 3 bounds the blast radius when it happens anyway"* — it does not, for that risk.
- §5.2 Option B, *"the rest still cancel"* — not for the first throw source Option B's own list names.
- Prereq 1's implicit containment.

We have a demonstration rather than a hypothesis: §8's own analysis of `shouldSkipRapidPickingCleanupWhenNotStarted` predicts an `EntityNotFoundException` escaping Fix 1 — that *is* this path.

**Fix:** state the catch set as an explicit enumeration in §5 Fix 3 and include `EntityNotFoundException`. Safer still, given that `EntityNotFoundException` is only one of the unchecked types reachable through `transferUnitLoadToLocation` → `processTransfer` → `unitloadRecordService` / `replenishmentOrderSourceSyncService` (two bodies §12 concedes were never read): catch `RuntimeException` inside the teardown block and rethrow as `ToteTeardownException`, and say so, rather than enumerating a set that §12 already says is not fully derived. The counter-argument — that a blanket `RuntimeException` catch could contain a genuine bug — is real but bounded here: the block spans ~20 lines of known calls, it sits before `setState(CANCELED)` so nothing is half-committed, and the alternative is an enumeration the plan cannot show is complete.

### H2 — the service-side wrap is graded by no test, and AC-6's parameterisation is vacuous where it is placed

§8's test table assigns AC-6 to exactly one method: `OrderRestControllerUnitTest.cancelPositions_ToteTeardownFailureOnOneOrder_ContinuesBatch`. AC-6 asks for it to be *"parameterised over at least one checked (`BusinessException` wrapped as `ToteTeardownException`) and one unchecked (`DataAccessException` wrapped) source"*.

In `OrderRestControllerUnitTest`, `customerorderService` is a Mockito mock — the test stubs it with `doThrow(...)`. Both parameterisations therefore hand the controller **the same `ToteTeardownException` instance shape**; the controller cannot observe what the service wrapped, because wrapping happens inside the mock that was replaced. The parameterisation grades nothing. The architect lane's concern — *"a `continue` that works for one and not the other"* — is a property of the **service's catch clause**, and that is exactly the clause H1 shows is mis-specified.

There is no row in §8 and no PIT mutant in §7 step 5 that exercises the service-side wrap at all. §7 step 5 lists four Fix-1 omission mutants plus two ordering mutants; none touches Fix 3.

**Fix:** add a `CustomerorderServiceUnitTest` row that stubs `unitloadBusinessService.sendToClearing` (and separately `unitloadRepository.findById`) to throw each representative type — a `BusinessException`, a `DataAccessException`, and an `EntityNotFoundException` — and asserts `cancelOrder` throws `ToteTeardownException` in every case, with the mutant being *narrow the catch set* (confirm red for the type dropped). Keep the controller test single-typed; that is all it can honestly grade.

Taken together, H1 and H2 are the mechanism by which a mis-specified catch set ships green: the only test that would notice sits on the wrong side of the mock.

## MEDIUM

### M1 — §3's *"cannot return false from `cancelOrder`"* is refuted by a position at state ≥ `CANCELED`

The `anyMatch` guard is bounded on both sides: `position.getState() >= PACKED && position.getState() < WmsConstants.State.CANCELED`. A position at **800 or above** does not trip it. It then reaches `canOrderPositionBeCancelled`, whose first line is `if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) { return false; }` — `800 >= 650` — and the order routes to step 5, not step 6.

So the guard is not dead from this caller; it is dead only for positions **below** `CANCELED`. The same over-reach appears in §3 bullet 4: *"returns `false` **only** for a `Pickingorder` **or** `PickingorderPosition` in **[650, 700)**"* — wrong for the same reason, and wrong again because the *rapid* arm has its own `false` conditions on a different band (`pickingOrderState == STARTED` with the position in `(PROCESSABLE, FINISHED)`, or `pickingOrderState` in `[STARTED, FINISHED)`), which §3's "[650,700) is empty" measurement does not address at all.

How much this matters: the plan's own second instrument reports `customerorder_position` on Hydra PRD as *"337 (300/600/800)"* — the 800 band is populated, so the precondition is not vacuous. What is unmeasured is whether a **mixed** order exists (order state < 800 with a position ≥ 800). I looked for a producer and did not find an obvious one: `cancelOrderPosition` has exactly one `src/main` caller (the same-transaction `cancelOrder` loop), and the only other writers of a position to `CANCELED` are `CustomerorderBatchService` (`cancelBatch`, dead) and `PickingorderBusinessService.cleanUpCancelledOrder` (whole order at once). So the conclusion "step 6 always fires on Hydra PRD" probably survives. The **sentence** does not.

**Fix:** narrow to *"cannot return false for a position below `CANCELED`"*, and either add the mixed-order count to §1's DB evidence or name it in §12 as a blind spot. This is a one-line edit; I raise it because §3's absolute is the load-bearing premise for revision 2's whole severity re-derivation, and an absolute that can be refuted by one counter-example should not carry that weight unqualified.

### M2 — the "four classes, not three" baseline omits three test classes that execute the real `cancelOrder`

`git grep -l "\.cancelOrder(" origin/develop -- 'src/test'` returns six files. Three of them invoke the **real** service, not a mock, and none appears in §8's baseline, §7 step 1, or §13:

- `src/test/java/net/aim_ai/wms/integration/CustomerorderOutboxIntegrationTest.java` — four call sites (`customerorderService.cancelOrder(order, true);`, `assertThatThrownBy(() -> customerorderService.cancelOrder(order, true))`, `cancelOrder(order1, true)`, `cancelOrder(order2, true)`)
- `src/test/java/net/aim_ai/wms/service/TransferLaneLeakOnCancelIT.java` — `customerorderService.cancelOrder(co, false);`
- `src/test/java/net/aim_ai/wms/integration/CancelOrderRollbackIntegrationTest.java` — `assertThatThrownBy(() -> customerorderService.cancelOrder(order, true))`

`TransferLaneLeakOnCancelIT` matters most: it grades `if (customerOrder.getTransferlaneId() != null) { customerOrder.setTransferlaneId(null); }`, which sits **six lines below** Fix 1's insertion point in the same success branch. It is the only lane that runs Fix 1's new reads and writes against real PostgreSQL.

They are safe today — `git grep -ci "pickingtote"` returns **0** in all three, so `getPickingtoteId()` is null and Fix 1 skips. But that is an unasserted fixture property, and the plan's derivation was explicitly file-scoped to `CustomerorderServiceUnitTest` (*"every `setPickingtoteId` site in the file"*), so it could not have found them. `CancelOrderRollbackIntegrationTest` is separately safe because it forces `State.FINISHED` — which the plan already establishes.

**Fix:** add the three to §8's baseline and to §7 step 1. Cheap, and it is the only instrument that would catch a Fix-1 regression against a real database.

### M3 — "SDR export is ruled out" is derived from the wrong repository

§2's blind-spot sentence reads: *"SDR export is ruled out — the repository carries `@RepositoryRestResource(… exported = false)` at type level."* True of `PickingorderUnitloadRepository` — verified. But the plan's own quoted grep (`getByLabel(\|findByUnitloadLabelid` over `src/main`) also returns a **second declaration of the byte-identical unsafe query**, on a repository that carries no type-level withdrawal:

`ReplenishorderRepository.java` — `@RepositoryRestResource(collectionResourceRel = "replenishorder", path = "replenishorder")` (no `exported = false`) declaring

```java
@RestResource(path = "findByUnitloadLabelid", rel = "findByUnitloadLabelid")
@Query(value = "select a.* from pickingorder_unitload a, unitload b where a.unitload_id = b.id and b.labelid like :labelid", nativeQuery = true)
Optional<PickingorderUnitload> findByUnitloadLabelid(@Param("labelid") String labelid);
```

with no method-level `exported = false` — unlike the four methods the same file elsewhere notes are withdrawn (*"All four are `@RestResource(exported = false)`"*).

I am **not** asserting the route resolves: SDR's search-resource handling of a query method whose return type is not the repository's domain type (`PickingorderUnitload` on a `Replenishorder` repository) is untested by me, and it may well fail to export or fail at serialization. State the uncertainty, don't resolve it by assumption. The finding is that the plan's census folded a live second declaration into "the declarations", and the SDR dismissal covers only one of the two.

**Fix:** either verify the route (an `OPTIONS`/`GET` against `/replenishorder/search/findByUnitloadLabelid` on dev — noting that an advertised `Allow` proves nothing, so grade the actual response), or restate the sentence as scoped to `PickingorderUnitloadRepository` and add `ReplenishorderRepository`'s duplicate declaration to §5.6 item 3, which already owns the "unsafe finder still in use" follow-up.

## LOW

### L1 — *"joins the same way"* is not exact

§5 point 7 says `findLatestByUnitloadLabelid` *"joins the same way … and returns the identical row in the measured single-row case."* The join is the same two tables on the same key, but the **predicate differs**:

- `findByUnitloadLabelid`: `and b.labelid like :labelid` — case-sensitive, and `%`/`_` in a label are wildcards.
- `findLatestByUnitloadLabelid`: `where lower(u.labelid) = lower(:labelid)` — case-insensitive, literal.

For `T-0002` they agree. For a label differing only in case, or containing `_`, they do not. Restate as *"joins the same two tables on the same key, with a different label predicate (case-insensitive exact vs case-sensitive LIKE); on the measured labels the two agree"*.

### L2 — the OSIV guarantee Fix 3 rests on is already flipped in the only lane that could regress-detect it

`spring.jpa.open-in-view=false` is confirmed at `src/main/resources/application.properties` (line 85, inside the `spring.jpa.*` block — the plan's positive control is valid). But `src/test/resources/application.properties` contains **zero** occurrences of `open-in-view`, and it shadows the main file on the test classpath, so every integration lane runs at Spring Boot's default `true`.

§5.2's sentence *"If anyone flips OSIV on later, Fix 3 becomes unsafe silently"* understates this: no test lane can observe the difference today, because the test lane is already on the unsafe side. Cheapest closure: pin the property with an assertion (`@Value("${spring.jpa.open-in-view}")` or an `Environment` read in a context test), or set it explicitly in the test properties. Either belongs in §12's blind-spot list at minimum.

### L3 — §0 row 2 under-describes `cancelBatch`

Row 2 lists `cancelBatch`'s omissions as "never clears stock `entity_lock` and never relocates the tote". It does in fact partially retire the assignment row:

```java
pickingorderUnitloadRepository.findByUnitloadId(toteUnitload.getId()).ifPresent(poul -> {
    poul.setState(WmsConstants.State.CANCELED);
    pickingorderUnitloadRepository.save(poul);
});
customerOrder.setPickingtoteId(null);
```

— state to `CANCELED`, but **`unitload_id` left populated**, i.e. the same half-fix Fix 1 block 2 exists to avoid. Immaterial to scope (the method is dead), but §5.6 item 1's six-axis table will need the cell, and it is a seventh partial teardown rather than the sixth.

---

# Proportionality

**Proportionate.** The production change is still ~25 lines and the non-goals list is tight and enforced. The 336→450 growth is almost entirely *withdrawals* — revision 1's discriminator, the lock-order rationale, the "no new exposure" claim, the `CancelOrderRollbackIntegrationTest` citations, the WineCo contrast, the `T-0010` attribution, the AC-2 "positive control" label — each replaced by either a derivation or an explicit "not established". That is the right direction for a document to grow in.

Two places where precision still slightly exceeds evidence, neither blocking:
- §5 point 2's three-way disjunction (*"either the pre-walk takes a `Pickingorder` lock after … or it takes nothing — exactly one holds"*) is honest but longer than the decision needs; the decision rests on sibling parity, which is one sentence.
- §10 row 4's *"Bounded by the tote's stock count (7 on the worst PRD case)"* is a tenant-specific bound presented as a general one; §12's fleet caveat covers it, but the number reads as a guarantee.

Everything else I checked in the new material verified: `CODE_TRANSFER = "TRANSFER"` and its membership in `PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES`; the argument transposition (`sendToClearing(… activityCode, comment, orderNumber)` into `transferUnitLoadToLocation(… String activityCode, String orderNumber, String comment)`); `ignoreLock=true`; `GOING_TO_DELETE = 2` as an `int` against `private Integer entityLock` (Fix 2's unboxing NPE is real), and the codebase's own stated rule quoted from `relocateEmptiedContainer`; `OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD }`; `"is locked=" + lock` in `StockunitBusinessService`; `ToteStateService.stillHoldsTote` = `state < WmsConstants.State.FINISHED && state != WmsConstants.State.CANCELED`; the `errors` map (exactly 2 occurrences in `OrderRestController`, both bare `Map<String, String> errors = new HashMap<>();` declarations, the second in `cancelPositions`); `UtilRestController` being `@Service`; `shouldCleanUpWithStockUnitsAndPositions` fixturing `stockUnit2.setEntityLock(… ON_HOLD)` and asserting it becomes `NOT_LOCKED`; `Sbdev3316_CancellationLogOrdering` existing as a nested class; all four repositories being `private final` fields on `CustomerorderService`; `ORDER_BATCH_CANCELLED_FROM_PSD` written at `MessageStatus.RECEIVED`/`HttpStatus.OK` on the success exit and `FAILED`/`BAD_REQUEST` in the catch; `CustomerorderBatchService:506` being `customerOrder.setPickingtoteId(null);`.

---

# What to change before approval

| # | Where | Change | Size |
|---|---|---|---|
| H1 | §5 Fix 3 part 2; §9 row 3; prereq 1 | State the catch set explicitly and include `EntityNotFoundException` (or catch `RuntimeException` and say so). Correct the two containment claims that follow from it | ~3 sentences |
| H2 | §8 table; §7 step 5; AC-6 | Add a `CustomerorderServiceUnitTest` row grading the service-side wrap over a checked, an unchecked-`DataAccessException` and an `EntityNotFoundException` source, with "narrow the catch set" as the mutant. Drop or re-scope the controller-level parameterisation | 1 row + 1 mutant |
| M1 | §3 | Narrow *"cannot return false"* to *"for a position below `CANCELED`"*; same for bullet 4's "only" | 2 lines |
| M2 | §8 baseline; §7 step 1 | Add `CustomerorderOutboxIntegrationTest`, `TransferLaneLeakOnCancelIT`, `CancelOrderRollbackIntegrationTest` | 1 line |
| M3 | §2 | Scope the SDR sentence to `PickingorderUnitloadRepository`; note `ReplenishorderRepository`'s duplicate declaration in §5.6 item 3 | 2 lines |
| L1–L3 | §5 pt 7, §12, §0 row 2 | As described | 3 lines |

None of these changes the fix design, the acceptance criteria's substance, the tier, or any prerequisite other than sharpening prereq 1. With H1 and H2 applied I would approve without a further round.

## Completeness of this review — what I did not do

- I did not run any test. Every test claim here is read from the `origin/develop` blob; the §8 baseline figures (122/92/77/17) are **declared** counts by the same `@Test` grep the plan used, re-run and matched exactly, plus a stricter `^\s*@Test\s*$` line count that also returned 122/92/77/17 — so the count is not inflated by `@TestInstance`-style prefixes. Green-ness is still unmeasured, as the plan itself says of the 92.
- I did not query any database. Every DB figure in the plan is carried forward from round 1's evidence unverified by me; the MCP servers for this session all failed to connect (`CONNECT_TIMEOUT`).
- I did not verify that SDR actually exposes `ReplenishorderRepository.findByUnitloadLabelid` (M3) — that is why M3 is phrased as a census gap rather than an exposure.
- My "28 of 31 new claims verified" is a count of the claims I chose to check, not of every claim in the revision. I did not re-grade material the prompt marked as round-1-confirmed and unchanged.
