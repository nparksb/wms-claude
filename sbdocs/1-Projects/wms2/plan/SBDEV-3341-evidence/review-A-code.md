# SBDEV-3341 — Review lane A (code)

**Reviewer:** lane A · **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3341-reviewA`
**Date:** 2026-09-14 · **Diff under review:** 4 files, +331 / −0, uncommitted

## VERDICT: APPROVE WITH FIXES — but F0 is BLOCKING: **this change leaves the build red**

The design is sound and the fix for F0 is two lines. The guard is on the correct side of the branch. The reversal path still works, and I verified why
rather than assuming it. Every one of the 9 new assertions is non-vacuous — I killed each with a
targeted mutant. **Nothing found at Critical, and nothing at High in the runtime behaviour** — no
data-integrity, authorization, transaction-boundary or concurrency-*correctness* defect; the guard
writes nothing, runs before the first write in its branch, and `@Transactional(rollbackFor =
{BusinessException.class, FacadeException.class})` on `transferStock` covers the throw. The one High
is F0: the change takes the unit suite red on an anti-drift rail, and that must be fixed before this
can merge.

Seven findings below — one stale-read weakness the javadoc overstates away, a blast radius materially
larger and differently shaped than the plan records, an operator-facing message that reverts a
correction this same class already made, a missing regression pin on the exact branch the placement
decision exists to protect, and two false claims in the new javadoc — plus one red test.

---

## F0 — HIGH, BLOCKING — the change turns the unit suite red on an anti-drift rail

Full suite in this worktree, `mvn -o test`: **6591 run, 1 failure, 0 errors, 1 skipped, BUILD
FAILURE.** The single failure is caused by this change and by nothing else:

```
net.aim_ai.wms.unit.config.NeverMatcherNullBlindnessArchTest.primitiveCapableMatchersMatchInventory
Expecting empty but was: ["StockunitServiceUnitTest: expected 0, found 4",
    "UnitloadBusinessServiceUnitTest: expected 0, found 1"]
```

**Proved new, not pre-existing.** I reverted only the two test files to HEAD, left both `src/main`
changes in place, and re-ran that class: `Tests run: 4, Failures: 0, Errors: 0 — BUILD SUCCESS`.
Restoring the test files reproduces the failure. Both files were restored from backup; `git diff
--stat` re-verified at 4 files / +331 / −0.

This matters beyond a red local run: wms2-api has gated its deploy on tests since 2026-09-08, and a
red `develop` stops deploying without announcing itself.

`PRIMITIVE_MATCHER_INVENTORY` is a per-class exact-equality inventory of primitive-capable matchers
inside `never()` spans; neither test class appears in it, so both are expected to be 0. The rail's
own failure text says what to do: *"read the DECLARED PARAMETER TYPE before accepting it, because the
matcher name cannot tell a boxed Long from a primitive long."* I read both, and the answer differs
per class:

- **`StockunitServiceUnitTest`, 4 sites — `anyBoolean()` is REQUIRED, keep it.**
  `transferUnitLoadToLocation(Unitload, Location, boolean ignoreLock, String, String, String)` — the
  third parameter is a **primitive** `boolean`, so bare `any()` returns null and NPEs at the unboxing
  site. The inventory already carries this exact precedent for this exact method under
  `MobilePickingServiceUnitTest:1` ("transferUnitLoadToLocation's third parameter is a PRIMITIVE
  `boolean ignoreLock` ... bare any() would NPE at the unboxing site"). Fix: add
  `"StockunitServiceUnitTest:4",` between `"StockunitServiceTransferStockDestinationTest:2",` and
  `"TransferOrderServiceUnitTest:3",` with a comment recording that the signature was read.

- **`UnitloadBusinessServiceUnitTest`, 1 site — `anyLong()` is an unnecessary NARROWING; widen it.**
  `StockunitRepository.findByUnitloadId` is declared

  ```java
  List<Stockunit> findByUnitloadId(@Param("unitloadId") Long unitloadId);
  ```

  — a **boxed** `Long`. `verify(stockunitRepository, never()).findByUnitloadId(anyLong())` in
  `transferUnitLoadToLocation_neverReadsCarriedStock_onPassThroughMove` is therefore exactly the
  re-narrowing SBDEV-3170 widened away and this rail exists to catch. Fix: change it to `any()` — the
  count returns to 0 and **no inventory entry is needed**. Do not add one; adding an entry here would
  bank the narrowing, which is precisely the failure mode the rail's javadoc calls out ("never
  because the count was inconvenient").

---

## F1 — Medium — the guard reads a DETACHED, cross-transaction snapshot; the javadoc claims parity with a guard that does not

`spring.jpa.open-in-view=false` (`v2/wms2-api/src/main/resources/application.properties:85`), and
neither `StockUnitController` nor its base `AdminController` carries `@Transactional`. So
`stockunitRepository.findById(id)` at `StockUnitController.java:154` runs in its own short read
transaction and the `Stockunit` it returns is **detached** by the time `transferStock` opens the
tenant transaction. The new guard reads that detached instance:

```java
// StockunitService.java
private void assertWholeContainerSourceUnlocked(Stockunit sourceStockunit, Unitload sourceUnitload, Location sourceLocation) throws BusinessException {
    if (isLocked(sourceStockunit.getEntityLock())) {
```

The sibling it claims to mirror reads an authoritative row first:

```java
// StockunitBusinessService.java
sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)
    .orElseThrow(() -> new BusinessException("Source stock unit " + sourceStockunitId + " not found"));
entityManager.refresh(sourceStockunit);
...
if (!ignoreLock) {
    int lock = sourceStockunit.getEntityLock();
```

The window is the whole prologue of `transferStock`: canonical-code resolution, `findByName`, two
`findById`s, an FLA lookup and `findByUnitloadId`. A pick confirm that stamps
`PICKED_FOR_GOODSOUT` inside that window is invisible to the guard, and the container relocates out
from under an active pick — the outcome the ticket exists to prevent. The converse also holds: a
lock cleared inside the window produces a spurious refusal on a legitimate move.

**Scope is narrower than it first looks, and that matters.** Only the stock-unit arm is stale, and
only on the controller path. `suUnitLoad` and `ulLocation` are read *inside* the transaction:

```java
Unitload suUnitLoad = unitloadRepository.findById(stockUnit.getUnitloadId()).orElseThrow(...);
Location ulLocation = locationRepository.findById(suUnitLoad.getStoragelocationId()).orElseThrow(...);
```

and `CancellationReversalService` hands in a managed instance it just wrote. So two of three arms
are already fresh-in-transaction.

The javadoc says the guard "Checks the same three sources the sibling guard checks — stock unit,
unit load, location — and uses the same message shape". True of the *policy*, false of the
*authority*, and it does not say so.

**Fix** — re-read the stock unit inside the guard with a plain, non-locking read:

```java
Stockunit fresh = stockunitRepository.findById(sourceStockunit.getId()).orElse(sourceStockunit);
if (isLocked(fresh.getEntityLock())) { ... }
```

Plain `findById` is deliberate and **not** `findByIdForUpdate`: taking a stockunit row lock here
would precede the owning-`Pickingorder` lock that `transferUnitLoadToLocation` acquires for
`CODE_MANUAL_TRANSFER` (which `PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES` contains),
inverting the canonical "Pickingorder BEFORE Stockunit/Unitload/Location" order SBDEV-2481
established. Narrowing the window without taking a lock is the safe change; on the reversal path the
L1 cache returns the managed, already-flushed instance, so nothing regresses. If the team prefers to
accept the stale read, say that in the javadoc instead of claiming parity.

### Q1 answered explicitly — does the reversal still work?

Yes, and the ordering holds. `CancellationReversalService`'s atomic pre-validate loop refuses every
lock state except `NOT_LOCKED` / `PICKED_FOR_GOODSOUT` / null *before* the movement loop:

```java
if (sourceLock != null
        && sourceLock != WmsConstants.BusinessObjectLockState.NOT_LOCKED
        && sourceLock != WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT) {
    throw new BusinessException("Reversal for position " + log.getCustomerorderPositionId() ...
```

so the stock unit reaches `transferStock` at 0 in every case that gets that far.

**But the flush is not what makes the new guard pass.** The guard reads the in-memory instance,
which is `NOT_LOCKED` the moment `stockUnit.setEntityLock(...)` runs — flush or no flush. The new
guard therefore adds **no** dependency on `entityManager.flush()`; that flush remains load-bearing
only for the split route's `entityManager.refresh`. This is the one place where F1's stale read is
actually a *feature*.

The UL and location arms are new exposure for the reversal path (the tote and its location were
never checked on this branch before). I could not find a state where that bites: on Hydra PRD every
whole-container-shape row with a locked unit load also has a locked stock unit (table in F2), and
both of the two writers of a non-zero `Unitload.entity_lock` in `src/main` — `sendToNirvana`
(`GOING_TO_DELETE`) and BOL close (`SHIPPED`, bulk JPQL) — move the carried stock to the same state,
so the pre-validate refuses first with its better message. **Residual I did not close:** I proved
the co-movement empirically from row counts, not from the code of BOL close. `customerorder_cancellation_log`
on Hydra PRD has 16 rows, 0 with a `picktostockunit_id` and 0 reversed, so there is no production
evidence for this path either way.

---

## F2 — Medium — blast radius is larger and differently shaped than the plan records; two of three lock states have no operator remedy

`architect-guard-placement.md` fixes the newly-refused population at "76 alone in their container"
(Hydra PRD `SHIPPED`). Measured today, stock units alone in their container — the exact
whole-container shape — grouped by the stock unit's own lock:

| tenant | 0 (still allowed) | 100 | 103 | 104 | 404 | 405 |
|---|---|---|---|---|---|---|
| Hydra PRD (`wms2-hydra`) | 439 | 0 | 0 | 0 | 0 | **76** |
| Hydra UAT (`nywh-hydra-uat`) | 354 | **1** | **12** | 0 | 0 | **4847** |
| WineCo dev (`wms2-wineco-dev`) | 21547 | **145** | **299** | **2** | **1** | **90230** |

Positive control: the same query returns the non-zero `lock=0` counts, so a zero above is a true
zero and not a broken instrument.

Two things "those 76" does not capture:

- **`QUALITY_FAULT` (103) is a real population in this shape** — 299 on wineco-dev, 12 on Hydra UAT,
  0 on Hydra PRD. A lone damaged unit moved in FULL takes the whole-container branch (that test is
  evaluated before the damaged arms), so it is newly refused. A remedy exists but is three steps:
  `removeLock` → move → re-damage.
- **`SHIPPED` (405) and `PICKED_FOR_GOODSOUT` (100) have NO operator remedy.**
  `BusinessObjectLockState.OPERATOR_REMOVABLE` is `{QUALITY_FAULT, ON_HOLD}`, so
  `POST /stockUnit/removeLock` refuses both. After this change a shipped container cannot be
  relocated through web Move Stock at all. That is consistent with the split route, which already
  refuses them — so it is plausibly the intended policy — but it is a capability removal, and on the
  migrated datasets it is ~3 orders of magnitude larger than the number on the ticket.

**Good news the plan also does not record:** the unit-load and location arms add *zero* new refusals
on PRD. Grouping the whole-container shape by `(su_lock, ul_lock, loc_lock)` on Hydra PRD returns
exactly two rows — `(0,0,0)`×439 and `(405,405,0)`×76 — so every container the UL arm would refuse
is already refused by the SU arm, and all 267 PRD `location` rows are at 0. The two extra arms are
invariant-completeness, not blast radius. That is worth saying out loud, because it is the strongest
available argument that checking all three sources was the right call.

**Fix:** no code change. Replace "those 76" on the ticket with the table above, and get an explicit
yes from Nam on SHIPPED containers becoming unmovable via web Move Stock.

---

## F3 — Medium — the message reverts a correction this same class already made, and lands at 422 in a mobile toast

`StockunitService` already contains the same three-source guard, and SBDEV-3226 explicitly corrected
it to name the state in words:

```java
// StockunitService.setLockOnHold
if (stockUnit.getEntityLock() != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
    // SBDEV-3226: name the state. "is locked!" told the operator nothing they could act on —
    // "is On Hold" tells them the row is already held, "is Picked" tells them to look at the order.
    throw new BusinessException("Can not set stock to on hold: this stock unit is already "
            + WmsConstants.BusinessObjectLockState.getCodeTextOrUnknown(stockUnit.getEntityLock()) + ".");
```

with the same treatment for its container and its location arms. `CancellationReversalService` made
the identical correction for the reversal flow, calling the raw form unactionable: *"the code alone
reached the warehouse floor as `is locked=100`, which is unactionable (SBDEV-3226 made the same
correction on removeLock)"*.

The new guard picks the *other* precedent — `StockunitBusinessService`'s raw
`"Source stockUnit=" + id + " is locked=" + lock` — and the javadoc defends it as "the same message
shape". Defensible for the web toast. Wrong for the reversal path: `completeReversal` is reached
from `controller/mobile/OrderCancellationController:62`, where `BusinessException` maps to **422**
and the mobile UI renders `detail` verbatim. A picker sees `Source unitLoad=T0012 is locked=2`.

**Fix** that satisfies both precedents and keeps the new tests green (they assert
`hasMessageContaining("is locked=405")`, so the code must stay adjacent to `is locked=`):

```java
throw new BusinessException("Source stockUnit=" + sourceStockunit.getId() + " is locked="
    + sourceStockunit.getEntityLock() + " ("
    + WmsConstants.BusinessObjectLockState.getCodeTextOrUnknown(sourceStockunit.getEntityLock()) + ")");
```

Same for the unit-load and location arms. Worth doing on the three sibling sites in
`StockunitBusinessService` in the same pass so the shapes stay identical — that is the property the
javadoc is actually protecting.

---

## F4 — Medium — no regression pin on the damaged branch, which is the entire reason the guard sits where it does

The placement decision rests on one argument, which `architect-guard-placement.md` calls DECISIVE: a
top-of-method guard would make both damaged arms unreachable —

```java
if (stockUnit.getEntityLock() == WmsConstants.BusinessObjectLockState.QUALITY_FAULT && ulLocation.getId().equals(destinationLocation.getId()) && destinationLocation.getName().equals(WmsConstants.STORAGE_LOCATION_DAMAGED)) {
```
```java
} else if (stockUnit.getEntityLock() != WmsConstants.BusinessObjectLockState.QUALITY_FAULT && destinationLocation.getName().equals(WmsConstants.STORAGE_LOCATION_DAMAGED)) {
```

— both of which deliberately pass `ignoreLock=true`. **Nothing tests either arm.**
`git grep -n "\.transferStock(" -- src/test` returns only controller tests with the service mocked,
`StockUnitBulkTransferGateUnitTest`, and `MobileTransferOrderServiceIntegrationTest` (a different
method on a different class). `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` appears nowhere in `src/test`. The
new `TransferStockSourceLockGuard` class is the **first** test in this repo that drives
`StockunitService.transferStock` at all.

So the single failure mode the placement analysis calls decisive ships with zero coverage — and the
same analysis's §3 invites the refactor that triggers it ("a guard inside a branch can be dropped
when the branch is rewritten"). A maintainer who hoists `assertWholeContainerSourceUnlocked` to the
top of `transferStock` for durability gets a fully green suite and a dead damaged-stock path.

**Fix** — two tests in the new nested class, both of which fail if the guard is hoisted:
1. partial move of a `QUALITY_FAULT` unit with source location == destination == `Damaged`:
   assert `transferStockToUnitLoad(..., ignoreLock=true, ...)` is still reached, and that the
   `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` check still runs;
2. partial move of an unlocked unit to `Damaged`: assert the `CODE_DAMAGED` transfer still happens
   and the result is stamped `QUALITY_FAULT`.

---

## F5 — Low — two false claims in the new `UnitloadBusinessService` javadoc

**(a) The 15/9 split is wrong.** The javadoc states *"Of the 24 call sites in `src/main` (15 passing
`ignoreLock=false`, 9 passing `true`)"*. The total is right; the split is **16 false / 8 true**.
`git grep -n "transferUnitLoadToLocation(" -- src/main`, minus the declaration, gives 24. The eight
`true` sites are `CustomerorderService:650`, `PickingorderBusinessService:352`,
`ReceivingService:721`, `ReceivingService:749`, `StockunitService:533`, and
`UnitloadBusinessService:548` / `:629` / `:646`.

**(b) "the two that need one already have one" is wrong twice.** There is a third caller with its own
source policy, in the sibling class the javadoc already names: `StockunitService.setLockOnHold` runs
a full three-source guard before calling `transferUnitLoadToLocation(stockUnitLoad, location, true,
WmsConstants.CODE_ON_HOLD, null, comment)`.

More substantively, the sentence conflates *has a policy* with *has this policy*.
`MobileMoveUnitloadService` refuses **`ON_HOLD` only**:

```java
if (sourceUnitLoad.getEntityLock() == WmsConstants.BusinessObjectLockState.ON_HOLD) {
    throw new BusinessException("Unit load is locked on hold!");
}
```

so mobile **Move Unit Load** still relocates a `SHIPPED` or `PICKED_FOR_GOODSOUT` container — the
same physical operation web Move Stock now refuses. This change closes the web split-vs-whole
divergence and opens a web-vs-mobile one. That may well be acceptable (Move Unit Load is a different,
deliberately looser operation), but the javadoc presents the enumeration as settling the invariant
and it does not. There is also a third producer of the same outcome that neither has nor can have a
caller policy: `StockUnitController`'s own comment records that `PATCH /v3/stockunit/{id}` relocates
the same inventory over Spring Data REST with no function check and no lock guard (SBDEV-3017 Class A).

**Fix:** correct 15/9 → 16/8; add `StockunitService.setLockOnHold`; and replace the enumeration with
the rule — *the source-lock policy belongs to the caller; `transferUnitLoadToLocation` enforces the
destination only* — plus one line noting the three existing caller policies differ from one another.
A prose list of call sites rots; the rule does not.

---

## F6 — Low — the `isLocked` javadoc describes a hazard that cannot occur here

```java
 * SBDEV-3341 — null-safe "carries a lock" test. {@code intValue()} is explicit rather than
 * relying on {@code Integer != int} auto-unboxing, so the line cannot be misread as the boxed
 * reference comparison that SBDEV-3091 fixed elsewhere in this class.
```

`WmsConstants.BusinessObjectLockState.NOT_LOCKED` is `public static final int NOT_LOCKED = 0;`.
`Integer != int` **always** unboxes — it can never be a reference comparison. SBDEV-3091 was
`Integer != Integer` (two boxed `Itemdata` ids from different persistence contexts), a different
shape. The `.intValue()` is harmless and the readability argument is fine; the stated *reason* is
false, and it is exactly the kind of comment a later reader cites as precedent.

**Fix:** reword to "explicit for readability; `NOT_LOCKED` is an `int`, so the comparison already
unboxes — the null check above is what does the work."

Related, no code change needed: the javadoc is right not to claim the null-permissive arm is
consistent with the class. It is not — `setLockOnHold`'s three arms, the three `switch
(stockUnit.getEntityLock())` sites and the `==` comparisons in `transferStock`'s damaged arms all
unbox unguarded and NPE on null. Measured 0 nulls across all three DBs above, so the divergence is
latent. Worth one sentence saying so rather than leaving the reader to infer it.

---

## F7 — Low — the third UBS pin does not cover the route under change

`transferUnitLoadToLocation_neverReadsCarriedStock_onPassThroughMove` uses `CODE_TRUCK_LOADING`,
which `PickLineActivityCodeClassifier.PASS_THROUGH_CODES` does contain — the name is accurate. But
the branch this ticket touches passes `CODE_MANUAL_TRANSFER`, which is in `BLOCK_REALIGN_CODES`, and
there `collectStockUnitIdsForUnitloadTree` **does** walk the carried stock (through the mocked
`pickLineRealignmentService`, which is why the `never()` on `stockunitRepository` still holds). Not a
defect — the pin proves what it says. Add a `CODE_MANUAL_TRANSFER` variant if the pin is meant to
cover the code path under change.

---

## Test quality — verified, not assumed

All 9 new tests pass, but see **F0** — they take the wider suite red.
`mvn -o test -Dtest='StockunitServiceUnitTest,UnitloadBusinessServiceUnitTest'` in this worktree:
**141 run, 0 failures, 0 errors, 0 skipped**;
`StockunitServiceUnitTest$TransferStockSourceLockGuard` 6/6 and
`UnitloadBusinessServiceUnitTest$TransferUnitLoadToLocationSourceLockAsymmetry` 3/3.

I mutation-checked every new assertion rather than trusting the green:

| mutant | result |
|---|---|
| delete the `assertWholeContainerSourceUnlocked(...)` call | **4 of 6** `TransferStockSourceLockGuard` tests fail |
| keep only the stock-unit arm; drop the UL + location arms | **2** fail (the UL and location tests) |
| `isLocked` → `entityLock == null \|\| entityLock.intValue() != NOT_LOCKED` (null refuses) | **1 error** (the AC-4 null test) |
| add the forbidden symmetric source guard to `transferUnitLoadToLocation` (UL lock + source-location lock + carried-stock read) | **all 3** asymmetry tests fail |

No vacuous assertions. The AC-3 and AC-4 positive tests survived the guard-removal mutant, which is
what shows they pin the allow path rather than piggybacking on the refuse path. Both main files were
restored from backup after each mutant; `git diff --stat` re-verified at 4 files / +331 / −0.

**Full-suite baseline comparison (the five-item floor's last item).** With the change:
6591 run / **1 failure** / 0 errors / 1 skipped. Without the two new test files (both `src/main`
changes still applied): the same rail runs 4/4 green. The delta is F0 and only F0 — no other test in
the repo reacts to this change, which is itself a useful negative result: the 16 other
`ignoreLock=false` callers of `transferUnitLoadToLocation` and the split route are all unaffected.

**Q4 specifically — no primitive-unboxing NPE trap, but one matcher is wrong in the other direction.**
`verify(unitloadBusinessService, never()).transferUnitLoadToLocation(any(), any(), anyBoolean(), any(), any(), any())`
correctly uses `anyBoolean()` for the `boolean ignoreLock` parameter — bare `any()` there would be
the NPE the brief asks about. `recordRelocation`'s six parameters are all reference types
(`Stockunit, Location, Location, String, String, String`), so bare `any()` is right there. The one
that is wrong is `findByUnitloadId(anyLong())` on a boxed `Long` parameter — not an NPE risk, a
re-narrowing of an SBDEV-3170 widening, and the cause of half of F0.

**Methodological note for whoever re-runs this:** `-Dtest='A+B'` silently matches nothing, and
without `clean` you then read the previous run's surefire XML as a verdict. Use a comma.

---

## Q5 — exception type

`BusinessException` is correct.

- Both sibling guards throw it, so a Move Stock refusal reads the same on either route.
- `StockUnitController` catches it and builds the `errors[]` envelope — HTTP 200 with a message the
  web toast renders. `FacadeException` would land in the adjacent `getLocalizedMessage()` catch and
  attempt a bundle lookup for a key that does not exist.
- On the reversal path it maps to **422** via `RestExceptionHandler` and reaches the mobile toast —
  correct status; see F3 for the message content.
- `BusinessException(String)` routes through `resolveMessage(locale, "placeholder", message)`; the
  new messages contain no `{` or `%`, so nothing is mangled. Identical to the sibling.

Note the destination side of this same branch throws `FacadeException("STORAGELOCATION_LOCKED", ...)`
— a bundle key — while the new source side throws a raw string. That asymmetry within one branch is
pre-existing on the destination side and is another reason to take F3's fix.

---

## Explicitly nothing found at

- **Critical** — nothing. The one High is F0, a red build with a two-line fix, not a runtime defect.
- **High, runtime** — no data integrity, authorization, transaction-boundary or concurrency-
  correctness defect. The guard takes no locks (deliberately — see F1), writes nothing, and cannot
  invert SBDEV-2481's Pickingorder-first lock order.
- **Style** — I found no style divergence worth reporting, per the brief.
