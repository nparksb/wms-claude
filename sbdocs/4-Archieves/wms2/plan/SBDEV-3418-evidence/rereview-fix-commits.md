# SBDEV-3418 — independent re-review of the three fix commits

**Lane:** rereview-fix-commits (independent; did not author any of the code under review)
**Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3418-rereview`, detached at `afb67376`
**Scope:** `git diff 40deb565..afb67376` — `54d1fa08` (F16 + C3/C4/AC-1b), `349c219f` (twelve Lows), `afb67376` (seven `never()` widenings).
`d607abb6` and `40deb565` reviewed only where a later commit touched the same code.
**Date:** 2026-09-22

## Verdict: CHANGES REQUESTED

Two Medium findings, both test-adequacy, both cheap. No correctness defect found in production code — the
`gateNewlyAssigned` contract, the PHASE C predicate equivalence and the `TreeSet` swap all check out against
`origin/develop`, and every load-bearing factual claim I checked in the new comments is **true**, including the
two that reversed earlier assertions. The problem is that two of the new assertions do not grade what their
`@DisplayName` and javadoc say they grade, and one of them is the assertion written specifically to close a
gap the conformance lane raised.

## Summary

| # | Sev | File | What |
|---|-----|------|------|
| M1 | **Medium** | `MobileTruckLoadingWriteService.java` | The PHASE C guard interleaving is **untested** — mutation survives 11/11 green |
| M2 | **Medium** | `MobileTruckLoadingRollbackIT.java` | AC-1b's second witness is **vacuous** — no position is ever created on that path |
| L1 | Low | `MobileTruckLoadingWriteService.java` | Two consecutive javadoc blocks on `TruckLoadOutcome`; the first is silently dropped |
| L2 | Low | `MobileTruckLoadingWriteService.java` | "three rows this method never locks … all named here" is an incomplete enumeration |
| L3 | Low | `MobileTruckLoadingRollbackIT.java` | `@AfterEach` comment asserts a failure history the code cannot produce |
| L4 | Low | `MobileTruckLoadingWriteService.java` | "dedup is O(1)" — `TreeSet.add` is O(log n) |
| L5 | Low | `MobilePalletizeWriteService.java` | F16's correction left a mangled run-on sentence |
| I1 | Info | — | Hydra prd "70 parcels, 88 stockunits" **re-measured and exact** |
| I2 | Info | `MobileTruckLoadingService.java` | The "409 is not a shape the handheld renders" claim is **correct**; cite the file, and note the palletize sibling now contradicts it |
| I3 | Info | `MobileTruckLoadingWriteService.java` | `gateNewlyAssigned` javadoc's "develop set it in that branch only" is true of `scanGate`, not of `loadOrder` |

---

## M1 — Medium. The PHASE C guard interleaving is untested; the mutation survives.

`src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java`

```java
        for (Long parcelId : parcelIds) {
            if (duplicateParcelIds.contains(parcelId)) {
                throw new BusinessException("Too many orders with the same parcel found");
            }
            if (!orderIdByParcelId.containsKey(parcelId)) {
```

`349c219f` replaced `if (!duplicateParcelIds.isEmpty()) { throw … }` with this interleaved form and defended it with
a seven-line comment ("checking every duplicate first would invert that and change which key the operator sees when
a pallet carries both defects").

**The reasoning is right** — I checked it against develop. `origin/develop`'s `MobileTruckLoadingService` raised both
from inside one per-parcel loop (duplicate scan first, then `if (order == null)`), so an orphan on an earlier parcel
did beat a duplicate on a later one. The new loop reproduces that.

**But nothing tests it.** MEASURED in this worktree: I reverted the block to the hoisted shape (the exact pre-`349c219f`
code) and ran `MobileTruckLoadingWriteServiceUnitTest` — **11/11 green, BUILD SUCCESS**. C3 carries an orphan and no
duplicate; C4 carries a duplicate and no orphan; neither can discriminate, because no fixture has both. A future
"tidy these two guards together" edit reverts the documented behaviour with no test failing, which is the exact
failure mode the comment was written to prevent.

**Do:** add a C5 — one pallet, parcel id 2 orphaned and parcel id 3 duplicated — and assert the thrown message is
`unexpectedUnitLoadDoesNotHaveOrder` (naming `PARCEL…`), **not** "Too many orders". That kills the mutant above and
is the only assertion that makes the comment load-bearing. Alternatively, if the ordering is not worth a test, delete
the paragraph rather than leave an unpinned claim.

## M2 — Medium. AC-1b's second witness is vacuous.

`src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingRollbackIT.java`

```java
            softly.assertThat(billofladingPositionRepository.findByBillofladingId(bolId))
                    .as("witness: no BOL position may survive a checked-exception rejection")
                    .isEmpty();
```

AC-1b injects its failure at `unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, …)`. In PHASE D that
call sits **before** the first `billofladingPositionService.createEntity(bol, operator)`:

```java
        Location gate = locationRepository.findByIdForUpdate(resolvedGateId) …
        unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false, …);

        BillofladingPosition palletBOLPos = billofladingPositionService.createEntity(bol, operator);
```

So on this path **no `billoflading_position` row is ever written**, by a correct implementation or by any mutant —
including deleting `@Transactional` outright. The assertion passes forever. It is also the one assertion in this class
with no paired control: AC-1 has `.as("control: the BOL must start with no positions, or witness 3 proves nothing")`;
AC-1b has no equivalent, so nothing flags the vacuity either.

This matters more than a stray assertion normally would, because AC-1b exists specifically to close a gap the
conformance lane raised, and the test's own javadoc already concedes "the two witnesses below stay green under that
mutant, by design". With witness 2 structurally unable to fail, the test rests on one witness (`after.getState()`) plus
the exception-shape assertion.

**Do:** replace it with the gate-header witness, which **is** written before the throw and does discriminate:

```java
            softly.assertThat(after.getOutboundlocationId())
                    .as("witness: the gate write must be rolled back")
                    .isNull();
```

`bol.setOutboundlocationId(pendingOutboundLocationId)` + `billofladingRepository.save(bol)` both run in PHASE D ahead
of `transferUnitLoadToLocation`, so this is a real second witness for the same price. Add the matching pre-call control
(`before.getOutboundlocationId()).isNull()`), as AC-1 does.

## L1 — Low. Two consecutive javadoc blocks on `TruckLoadOutcome`; the first is dropped.

`MobileTruckLoadingWriteService.java`

```java
     * repository lookups, each of which opens its own read transaction (OSIV is off).
     */
    /**
     * @param gateName          the gate the pallet was moved to, …
```

`54d1fa08` added the `@param` block as a **second** javadoc comment rather than extending the existing one. Javadoc
binds only the last comment before a declaration, so the original block — "What the outer service needs AFTER the
boundary has committed…", including the detachment rationale and the `PalletizeOutcome` precedent — is now orphaned
and will not appear in generated docs. Merge the two blocks, `@param` tags last.

## L2 — Low. "three rows this method never locks … all named here" is incomplete.

`MobileTruckLoadingWriteService.java`, the new *Lock-set completeness* bullet in `349c219f`:

> `transferUnitLoadToLocation` touches three rows this method never locks, all benign today, **all named here rather
> than rediscovered**

The three named (`unitloadRepository.findById(carrierunitloadId)`, `locationRepository.findById(storagelocationId)`,
`stockunitRepository.findByUnitloadId(…)` in the `fixLocationAssignment != null` branch) are all real — I confirmed
each in `UnitloadBusinessService.transferUnitLoadToLocation`. But the same method also reads, unlocked:
`locationTypeRepository.findById(destinationLocation.getTypeId())`,
`fixLocationAssignmentRepository.findByAssignedlocationId(…)`,
`locationConstraintRepository.findByStoragelocationtypeId(…)`, and
`unitloadRepository.findByCarrierunitloadId(unitload.getId())` inside the same fix-assignment branch.

They are configuration/reference rows and genuinely benign, so the *conclusion* stands — but "all named here" is a
completeness word on a hand-maintained list, which is the shape the sibling `MobileReplenishService` javadoc in this
very commit was rewritten to stop doing. Either scope the sentence ("the three **business** rows"), or state the
derivation the way the replenish javadoc now does.

## L3 — Low. The `@AfterEach` comment asserts a failure history the code cannot produce.

`MobileTruckLoadingRollbackIT.java`

```java
        // Guarded: if seeding threw before the BOL was saved, bolId is null. This was the one
        // unguarded statement in the method, and it runs FIRST — so a seeding failure surfaced as
        // an exception out of @AfterEach, masking the real cause with a cleanup stack trace.
        if (bolId != null) {
```

`findByBillofladingId(Long)` is a plain derived query (`BillofladingPositionRepository:24`, no `@Query`). A null
argument yields `IS NULL` / `= null` and an empty list — it does not throw. So the stated history ("surfaced as an
exception out of `@AfterEach`") is very unlikely to be what was observed. The guard itself is harmless and the new
`deleteQuietly` wrapper makes it redundant twice over; it is the confident causal claim that should go or be
re-grounded.

**Answering the question this lane was asked:** the `deleteQuietly` wrapping does **not** change which rows get deleted
if the lambda throws part-way through the `forEach`. Each element already goes through `deleteByIdQuietly`, which
delegates to the same `deleteQuietly` and swallows `RuntimeException` per element, so the `forEach` never aborts on a
delete failure. The only throw the new wrapper newly catches is one from `findByBillofladingId` itself. One property
worth knowing: `cleanupFailures` counts *steps*, so a run where the block throws and several elements also failed
records them separately — it is a count of failed steps, not of leaked rows.

The `private int cleanupFailures;` declared after its use site is legal (the forward-reference restriction applies to
initializers, not method bodies) and JUnit's default PER_METHOD lifecycle makes the `cleanupFailures = 0` reset
belt-and-braces. Style only.

## L4 — Low. "dedup is O(1)" is wrong for a `TreeSet`.

`MobileTruckLoadingWriteService.java`

```java
        // TreeSet, not a list + contains(): dedup is O(1) rather than O(n) per row, and the
```

`TreeSet.add` is **O(log n)**, not O(1). The direction of the claim is right and the change is a real improvement over
the O(n) `contains()`; only the complexity class is wrong. (If O(1) is wanted, a `HashSet` plus one `sort` gets it —
but `TreeSet` is the better code here because it also removes the separate sort.)

## L5 — Low. F16's correction left a mangled sentence.

`MobilePalletizeWriteService.java`

```java
 * that turns a silent lost update into a spurious 409 — {@code StaleObjectStateException} is
 * translated to {@code ObjectOptimisticLockingFailureException}, which {@code RestExceptionHandler}
 * (@Order(0), unscoped) maps to 409 with {@code retryable=true}; an earlier revision of this
 * sentence said "HTTP 500" and was wrong (corrected under SBDEV-3418) — instead of the guard rejection this ticket
 * exists to produce — and <b>uncontended it throws nothing, …
```

The trailing em-dash clause "instead of the guard rejection this ticket exists to produce" was written to attach to the
outcome ("turns … into an HTTP 500 — instead of the guard rejection …"); the inserted correction now sits between them
and the sentence no longer parses. The fourth line also runs well past the wrap width every other line in the file
honours. The sibling in `MobileTruckLoadingWriteService` was rewritten cleanly for the same correction — mirror that
wording here.

---

## I1 — Info. The Hydra prd fan-out measurement re-verified, exactly.

`349c219f`'s *Fan-out is a new exposure* bullet claims "a worst-case Hydra prd pallet — measured at **70 parcels, 88
stockunits**". Re-measured this lane against Hydra prd:

```sql
SELECT max(parcels), max(stockunits) FROM (
  SELECT u.carrierunitload_id, count(DISTINCT u.id) AS parcels, count(s.id) AS stockunits
  FROM unitload u LEFT JOIN stockunit s ON s.unitload_id = u.id
  WHERE u.carrierunitload_id IS NOT NULL GROUP BY u.carrierunitload_id) t
-- → max_parcels 70, max_stockunits 88
```

Exact match. The bullet's own caveat — that the max is the wrong statistic and p99 is what should gate the decision —
is correct and remains open; the MCP validator rejects `percentile_disc`, so p99 was not obtained here.

## I2 — Info. The "409 is not a shape the handheld renders" claim is **correct** — cite it, and note the contradiction.

`MobileTruckLoadingService.lockContention` javadoc:

> `TruckLoadingController.scanGate` catches `BusinessException` and returns 200 with an `errors` entry, which the
> mobile client displays. A 409 `ProblemDetail` is not a shape it renders.

Verified in `v2/wms2-mobile-ui/store/truckLoading.js`, action `scanGate`: a non-2xx rejects the axios promise, the
`catch` fires, and the operator gets the **generic** toast
`'Error: Request failed due to a network or server issue. Please retry.'`. The ProblemDetail `detail` is never read on
this path. The javadoc is right and would be stronger citing that file.

> ### ⚠ RETRACTED 2026-09-23 — this paragraph was WRONG, and acting on it caused a regression
>
> The text below claimed `util/apiError.js` does not exist in `v2/wms2-mobile-ui`. **It does** — on
> `origin/develop`, `origin/main` and `origin/release` (same blob), added 2026-08-28 by `3174486b`.
> The lane and the author both checked a **local working copy 77 commits behind** `origin/develop`,
> where it genuinely is absent. A `find`/`ls` over a checkout has no ref and cannot establish absence.
>
> `MobilePalletizingService`'s javadoc — the one this paragraph called wrong — was **correct**.
> Acting on this finding in `ed2ed97a` overwrote two correct `src/main` javadocs with the falsehood;
> `cca3aaf3` withdrew it. Kept here with this marker rather than deleted, because an unmarked
> retraction in an evidence file is how the claim gets re-derived. Original text follows.

Worth flagging to whoever owns the palletize sibling: `MobilePalletizingService.lockContention`'s javadoc (from an
earlier ticket's re-review) asserts the **opposite** — "the operator gets a 409 whose `detail` the handheld *does*
render — as a toast, via `wms2-mobile-ui util/apiError.js`". There is no `util/apiError.js` anywhere in
`v2/wms2-mobile-ui`. The two javadocs now contradict each other on a load-bearing point; the new one is the one
backed by a file that exists. Out of scope for these three commits, but it is the sibling-copy pattern, so it should
not be left to be rediscovered.

## I3 — Info. Scope the `gateNewlyAssigned` claim to `scanGate`.

Both the record javadoc and the caller comment say develop "set `bolGateName` inside its 'no gate defined yet' branch
**ONLY**". True of `scanGate`. `loadOrder` — a different method, unchanged, still present at
`MobileTruckLoadingService.java` — sets `bolGateName` unconditionally (null or the resolved name). Naming `scanGate`
explicitly costs one word and stops a future reader concluding `loadOrder` needs the same flag.

---

## What I checked and found clean

**1. `TruckLoadOutcome.gateNewlyAssigned` — equivalent to develop on every path.**
`git show origin/develop:…/MobileTruckLoadingService.java` sets `bolGateName` in `scanGate` only inside
`if (billOfLading.getOutboundlocationId() == null)`; the mismatch arm throws `scannedAndRequiredGateDiffer`; the
matching-gate arm leaves the DTO untouched. There is no third path. The new flag is
`pendingOutboundLocationId != null`, set in PHASE C under exactly `bol.getOutboundlocationId() == null`, and the
mismatch arm still throws before any outcome is built. `gateName` comes from the `Location` resolved from the scanned
name, so it is the same string develop wrote. The javadoc's "deriving this at the caller is not possible" is also
correct — PHASE D applies the pending id before the record is constructed.
**Mutation-checked:** flipping the caller guard to `if (true)` fails
`scanGate_shouldNotEchoTheGateName_whenTheBolAlreadyCarriedTheGate` at `MobileTruckLoadingServiceTest.java:433` and
nothing else. Attributable kill.

**2. The duplicate-detection predicate is the same predicate.**
Develop: two `Customerorder` rows matching one parcel inside `getByParcelIdList` →
`SELECT DISTINCT(co.*) FROM customerorder co INNER JOIN unitload parcel ON co.parcel_id = parcel.id WHERE parcel.id IN :parcelIds`.
New: `orderIdByParcelId.put(...)` returning non-null over
`SELECT parcel.id, co.id FROM customerorder co INNER JOIN unitload parcel ON co.parcel_id = parcel.id WHERE parcel.id IN :parcelIds ORDER BY parcel.id, co.id`.
Same join, same population; `co.id` is the PK, so "two rows for one parcel" is "two distinct orders" in both, and no
row can repeat. Per-parcel the order is duplicate-then-orphan in both. Equivalent. (What is *not* tested is the
cross-parcel ordering — M1.)

**3. The `TreeSet` swap is behaviour-preserving.**
`new TreeSet<Long>` iterates ascending by natural order, identical to the removed `sort(Long::compareTo)` on the
insertion-ordered list. No null is possible (`co.id` is the PK), so the NPE-on-null difference between `TreeSet` and
`ArrayList` is unreachable. `sortedOrderIds = new ArrayList<>(distinctOrderIds)` is still a mutable `ArrayList`; the
only two consumers (the B5 lock loop and the B6 positions loop) iterate it and never mutate it, and nothing depends on
insertion order. `duplicateParcelIds` moving `List` → `LinkedHashSet` is used only via `add`/`contains`.

**4. All seven widened `never()` matchers are safe.** Signatures confirmed from source:
`MobileMoveUnitloadService.handleTruckOffLoadingNoClear(String)`,
`UnitloadRepository.findByLabelid(String)`, `LocationRepository.findByName(String)`,
`BillofladingRepository.findByName(String)`,
`ManageOrderService.customerOrderLoadedToTruck(List<Customerorder>, Unitload, Billoflading)`.
None is varargs, none is primitive, none is overloaded — so both carve-outs
`NeverMatcherNullBlindnessArchTest` names (varargs at its lines 133-144/228, primitives in its class javadoc) are
satisfied and bare `any()` is the correct widening. The `anyString` and `anyList` imports are still used at stubbing
sites (`when(userRepository.findByName(anyString()))` ×4; `doThrow(...).when(manageOrderService).customerOrderLoadedToTruck(anyList(), any(), any())`),
so no unused import was left behind.

**5. Every load-bearing factual claim in the new comments, checked against source.**

| Claim | Where | Verdict |
|---|---|---|
| `RestExceptionHandler` is `@Order(0)` and unscoped `@ControllerAdvice` | `RestExceptionHandler:46-48` | ✅ |
| `ObjectOptimisticLockingFailureException` → 409 "The record was modified by another user. Please retry.", `retryable=true` | `:361-366` | ✅ verbatim |
| `PessimisticLockingFailureException` → 409 "The record is currently locked by another operation. Please retry.", `retryable=true` | `:370-375` | ✅ verbatim |
| `UnexpectedRollbackException` is not mapped → bare 500 | no handler; `MobileEndpointExceptionHandler` `@Order(LOWEST_PRECEDENCE)` catch-all `@ExceptionHandler(Exception.class)` → `INTERNAL_SERVER_ERROR` | ✅ |
| Controller catches `BusinessException` → 200 + `errors` | `TruckLoadingController:119-133` | ✅ (it also catches `FacadeException`; harmless omission) |
| `transferUnitLoadToLocation` carries its own `rollbackFor = {BusinessException, FacadeException}` | `UnitloadBusinessService:220` | ✅ — so AC-1b's corrected "the data still rolls back, only the exception shape changes" is right |
| Locked-gate guard `!ignoreLock && getEntityLock() != NOT_LOCKED` → `FacadeException("STORAGELOCATION_LOCKED", …)` | `UnitloadBusinessService:250-252` | ✅ |
| `FacadeException extends Exception` (checked); `FacadeException(String,Object[])` puts the key in `getMessage()` | `FacadeException:26, :51` | ✅ — `hasMessageContaining("STORAGELOCATION_LOCKED")` is a real assertion |
| `EntityNotFoundException extends RuntimeException` (unchecked), so AC-1 cannot grade `rollbackFor` | `EntityNotFoundException:7` | ✅ |
| `StringConverter.convertFormatToRegex` returns `""`, never null, for null/empty input | `StringConverter:28-31` | ✅ |
| `handleTruckOffLoadingNoClear` guards on `pattern != null && !pattern.isEmpty()` and returns with `LOG.warn` | `MobileMoveUnitloadService:533-561` | ✅ |
| the original `handleTruckOffLoading` still passes a null pattern into `String.matches()` | `MobileMoveUnitloadService:488-493` | ✅ |
| only `OmsNotificationService` still carries the `isSynchronizationActive()` shape, at a different line than the old list cited | `grep -rn "isSynchronizationActive()" src/main/java` → `OmsNotificationService:68, :105` (not `:95`); `MobileTruckLoadingService` no longer has line 310 at all | ✅ — the delisting in `MobileReplenishService` is the right call |
| `LocationRepository`: nothing on the truck-loading path writes the `Location`, so two gate scans do **not** collide | zero `locationRepository.save` and zero `destinationLocation.set*`/`sourceLocation.set*` in `UnitloadBusinessService` | ✅ — the correction overturns the earlier javadoc correctly |
| no surviving false "lock exception → HTTP 500" claim anywhere in `src/main` | tree-wide grep; the only remaining hits are corrections quoting the old claim to rebut it | ✅ sweep complete |

**6. The suite.** `mvn -o -Dtest='MobileTruckLoadingServiceTest,MobileTruckLoadingWriteServiceUnitTest,NeverMatcherNullBlindnessArchTest' test`
→ **36/36 green** (rail 4, write-service 11, outer 21), BUILD SUCCESS. Matches `afb67376`'s claimed counts exactly.

**7. Worktree restored.** Both mutations were applied from scratchpad copies and restored by `cp` (no `git restore`,
no `git stash`). `git status --short` is empty and `git diff HEAD` is empty at `afb67376`.

## Process note

My first scoped run used `+` as the `-Dtest` separator
(`-Dtest='A+B+C' -Dsurefire.failIfNoSpecifiedTests=false`). It exited **0 with BUILD SUCCESS and zero tests run**, and
left no `target/surefire-reports/` at all. Use commas. Anyone re-running these classes off the commit message should
check the reports directory exists before reading a green as evidence.
