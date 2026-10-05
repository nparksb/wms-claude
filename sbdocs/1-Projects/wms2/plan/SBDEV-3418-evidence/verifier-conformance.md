# SBDEV-3418 — independent conformance verification

- **Lane:** independent verifier. No part of this report reuses a result quoted to me; every command below was re-run in this lane.
- **Tree graded:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3418`, branch `bugfix/SBDEV-3418-truck-loading-transaction-boundary`, one commit `e64bdb5c` off `origin/develop` @ `3214a9c3`. Confirmed with `git log --oneline -3` and `git rev-parse --abbrev-ref HEAD`. `/Users/np1076/dev/spk/owl/v2/wms2-api` was not read.
- **Plan graded against:** `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3418-mobile-truck-loading-transaction-boundary.md` (§2, §3.2, §4.1, §4.3, §6.2).
- **Date:** 2026-09-22.

## Overall verdict: **FAIL**

Two things carry the verdict. One is mechanical and certain: **the branch does not pass its own unit
lane** — `TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared` is red
because the new IT was not registered, reproduced below. The other is substantive: **the gate
`Location` first-touch violation that plan Bug 6a exists to close is still present**, moved from
PHASE A to PHASE D, and the code carries an adjacent comment asserting the opposite — which is the
one thing that will stop the next reader from re-checking it.

Everything else in §4.1 is implemented and, where testable at this commit, correct. The transaction
boundary, the phase order, the D0 seat, the canonical lock order, the two outside-the-boundary
concerns and the relocated tests all conform.

| criterion | verdict |
|---|---|
| AC-1 atomicity | **PARTIAL** — the IT is a genuine, attributable kill, but the guard-ordering half of AC-1 and `rollbackFor` are untested |
| AC-2 lock order probe | **DEFERRED** (not graded as a gap) |
| AC-3 no pending write at D0 | **DEFERRED** — but see F5: nothing at all pins it, and the invariant *is* satisfiable statically |
| AC-4 Bug 4a measurement | **DEFERRED** |
| AC-5 OMS notification outside the boundary | **VERIFIED** |
| AC-6 contention translation outside the boundary | **VERIFIED** |
| AC-7 concurrency | **DEFERRED** |
| Bug 6 / 6a first-touch rule | **MISSING for the gate `Location`**; VERIFIED for the other six read sites |
| PHASE C predicate-only | **VERIFIED** |
| D0 precedes every `createEntity` | **VERIFIED** |
| Canonical lock order | **VERIFIED** |
| Relocated tests | **VERIFIED** — no assertion weakened or dropped |
| §4.1 in-scope completeness | **VERIFIED** |
| §4.3 "state the residuals in the javadoc" | **PARTIAL** — 3 of 6 stated, 1 partial, 2 absent |

⚠ On the deferrals: the brief states AC-2/3/4/7 are deferred to a later commit and I have graded
them that way. **I could not find that deferral recorded anywhere.** `grep -n "deferred\|later
commit\|follow-up commit"` over the plan returns nothing; the commit message `e64bdb5c` does not
mention it; and plan §9.2 still reads *"Not started."* Separately, §9.2's two non-optional
pre-implementation items — *"**A clean IT baseline** (§6.4). The measured run was contaminated by a
four-hour-old reused Testcontainers container"* — has no recorded result either. Neither is a code
defect; both mean the plan document currently misdescribes the state of the work.

---

## What I ran

```
export JAVA_HOME=$(/usr/libexec/java_home -v 21); export PATH="$JAVA_HOME/bin:$PATH"
cd /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3418
```

| command | result |
|---|---|
| `mvn -B -ntp clean compile` | **BUILD SUCCESS**, 49 s |
| `mvn -B -ntp test -Dtest='MobileTruckLoadingWriteServiceUnitTest,MobileTruckLoadingServiceTest,MobileTruckLoadingServiceUnitTest,TestClassTransactionManagerArchTest,OptionalSafetyArchTest'` | **BUILD FAILURE** — `Tests run: 44, Failures: 1`. The failure is F1 below. The five truck-loading classes are all green: write-service 7/7, outer-service 20/20, `MobileTruckLoadingServiceUnitTest` 11/11, `OptionalSafetyArchTest` 1/1 |
| `mvn -B -ntp verify -Dit.test=MobileTruckLoadingRollbackIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | **BUILD SUCCESS** — `Tests run: 1, Failures: 0, Errors: 0`, 81.7 s |
| same, with `@Transactional` deleted from `MobileTruckLoadingWriteService.scanGate` (mutant; source restored from a `/tmp` copy immediately after) | **BUILD FAILURE** — `Tests run: 1, Failures: 1`, 79.1 s |

I did **not** run the full suite, and did not touch the Testcontainers container — the rollback IT
extends `BaseIntegrationTest`, whose own javadoc says *"Base class for integration tests using H2
in-memory database"*, so it contends with nothing.

⚠ **The worktree is left with one modified file that is not mine to revert** (the brief forbids `git
restore`): `src/test/resources/archunit_store/5fb3fee0-6caf-4f48-a5cd-5271da610572`, from which the
arch-test run **pruned two entries**:

```
-Method <net.aim_ai.wms.service.mobile.MobileTruckLoadingService.scanGate(...)> calls method <java.util.Optional.get()> in (MobileTruckLoadingService.java:190)
-Method <net.aim_ai.wms.service.mobile.MobileTruckLoadingService.scanGate(...)> calls method <java.util.Optional.get()> in (MobileTruckLoadingService.java:207)
```

That pruning is correct and expected — it is exactly what plan §6.1 predicted (*"a `mvn test` run
**prunes** solved entries rather than failing on them"*) — and it belongs in this commit. See F9.
`target/` also holds classes from the mutant run; `mvn clean` before the next measurement.

---

## Blocking findings

### F1 — BLOCKER: the branch's own unit lane is red. `MobileTruckLoadingRollbackIT` was never registered with the arch rail.

`mvn -B -ntp test` on this branch:

```
[ERROR] net.aim_ai.wms.unit.config.TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared -- FAILURE!
[NOT_SUPPORTED and NEVER are exempt from the name-a-manager rule because Spring resolves no manager
for them — but they also mean NO test transaction, so every write commits into the shared H2 and
outlives the test. … add or remove the class in EXEMPT_NON_TRANSACTIONAL in the same commit, and say why.]
```

The diff between `expected:` (the frozen `EXEMPT_NON_TRANSACTIONAL`) and `but was:` (what the rule
found on the classpath) is exactly one entry:

```
"net.aim_ai.wms.integration.service.mobile.MobileTruckLoadingRollbackIT"
```

Cause, in `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingRollbackIT.java`:

```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.NOT_SUPPORTED)
class MobileTruckLoadingRollbackIT extends BaseIntegrationTest {
```

The propagation is the correct choice and the class javadoc justifies it well. What is missing is the
registration the rule demands, in
`src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java`'s
`EXEMPT_NON_TRANSACTIONAL`, with a stated reason.

Plan §8.2 landmine 2 predicted this verbatim: *"`TestClassTransactionManagerArchTest` fires for
`NOT_SUPPORTED` ITs that commit fixtures. They need registration with a justification and FK-ordered
cleanup keyed on **unique keys, not ids**."* The FK-ordered cleanup half **was** done — `@AfterEach
deleteCommittedFixture()` unwinds in FK order and keys on the `TL1-` label prefix. Only the
registration was missed.

Not a judgement call and not environmental: it is a deterministic, source-only ArchUnit assertion,
it reproduces on a clean compile, and `wms2-api` gates its deploy on tests.

**Remedy:** add the class to `EXEMPT_NON_TRANSACTIONAL` with the justification already written in its
own javadoc (*"`Propagation.NOT_SUPPORTED` makes `TransactionalTestExecutionListener` skip
transaction management for this class entirely, so the writes commit for real and the rollback is a
real rollback"*).

---

### F2 — HIGH: the gate `Location` is still a first-touch violation. It moved from PHASE A to PHASE D; it was not removed.

This is the answer to the specific question in the brief, and my independent read is that **it is a
violation of the SBDEV-3244 rule as this repository states it** — not merely "the shape the rule
warns about".

`src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java`, PHASE D:

```java
// The gate Location's FIRST entity touch happens inside transferUnitLoadToLocation, which
// takes its own findByIdForUpdate on it because ignoreLock=false. Resolving it as an entity
// anywhere above would turn that acquisition into an upgrade — this is exactly why PHASE A
// used a scalar. …
final Long resolvedGateId = gateId;
Location gate = locationRepository.findById(resolvedGateId)
        .orElseThrow(() -> new EntityNotFoundException("Location", resolvedGateId));
unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false,
        WmsConstants.CODE_TRUCK_LOADING, bol.getNumber(), null);
```

`locationRepository.findById(resolvedGateId)` **is** an entity touch, it is inside the boundary, and
it is two statements above the lock. The comment directly above it says the first touch happens
inside the collaborator. It does not.

Then, in `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`
(`transferUnitLoadToLocation`, `@Transactional … REQUIRED`, so it joins the caller's persistence
context):

```java
if (!ignoreLock) {
    final Long destinationLocationId = destinationLocation.getId();
    destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
        .orElseThrow(() -> new EntityNotFoundException("Location", destinationLocationId));
    entityManager.refresh(destinationLocation);
}
```

Three facts close it:

1. **The finder is a locking one.** `LocationRepository`: `@Lock(LockModeType.PESSIMISTIC_WRITE)` /
   `@Query("SELECT l FROM Location l WHERE l.id = :id")` / `Optional<Location> findByIdForUpdate(...)`.
2. **`Location` is versioned.** `Location extends AbstractBaseEntity`, and `AbstractBaseEntity`
   carries `@Version private Integer version;`. Version-checking on upgrade therefore applies.
3. **The repo's own statement of the rule covers this exact shape**, in
   `ReplenishmentOrderMaintenanceService.recalculateOrder`: *"If any earlier statement in the same
   transaction has already loaded it with a plain finder, the row sits in the persistence context at
   `EntityEntry` lock mode READ; this call is then a lock UPGRADE, and Hibernate version-checks only
   on an upgrade … Do not 'optimise' this back to taking the entity, and **do not add a pre-lock read
   above it**."* `findById` two lines above `findByIdForUpdate` is a pre-lock read above it.

And plan §3.2's PHASE D row says what should have happened instead: *"`transferUnitLoadToLocation` —
its OWN inner `findByIdForUpdate` is the Location row's **first entity touch**"*, with Bug 6a's
design consequence: *"resolve the gate by a scalar id projection during validation and **let
`transferUnitLoadToLocation`'s `findByIdForUpdate` be the Location row's first touch**."* PHASE A
does the scalar half (`locationRepository.findIdByName`, new, correct). PHASE D undoes it.

**How bad, honestly.** Narrower than the plan's framing, and I want to be precise rather than
alarming:

- Uncontended it throws nothing, so no existing test can see it — same as every other instance of
  this class.
- To throw, a `location` row UPDATE must **commit** in the window between our `findById` and the
  collaborator's `findByIdForUpdate`. Nothing on the truck-loading path writes a `Location`:
  `transferUnitLoadToLocation` reads `getEntityLock()`, `getTypeId()`, `getName()` and calls no
  `locationRepository.save`. `git grep -c "locationRepository.save" -- src/main/java` finds writers
  only in `LocationService` (4), `UtilRestController` (39) and `FileImportController` (1) — plus SDR
  on the exported `LocationRepository`. So the trigger is an **out-of-band** location edit (admin
  screen, import, SDR `PATCH`) landing inside that window, not a second scan.
  *Blind spot of that enumeration: it is a literal grep for one call shape over `src/main` only; a
  write through `entityManager.merge`, a native UPDATE, or a v1/DBA path would not appear.*
- When it does fire it is a `StaleObjectStateException` → `ObjectOptimisticLockingFailureException`,
  which is **not** a `PessimisticLockingFailureException`, so the new AC-6 translation in the outer
  service does **not** catch it. It reaches `TruckLoadingController.scanGate`, which catches only
  `BusinessException` and `FacadeException` → **raw HTTP 500**. That is Bug 7's failure mode
  re-entering through a door the fix left open.

**Why I am still calling it High rather than Medium.** The comment at the call site asserts the
invariant holds. A reader auditing this path will read that comment, tick the box and move on — the
same failure mode the plan's own §6.1 and the `UserRoleUserFunctionRepository` precedent are written
to prevent. A wrong comment about a contention-only defect is worse than no comment.

**Remedy sketch (not applied — I have no write access to source):** the collaborator only needs
`destinationLocation.getId()` before it re-reads, so an uninitialised proxy would satisfy both sides.
`LocationRepository extends CrudRepository<Location, Long>`, so `getReferenceById` is not available
today — this is a signature change (add `getReferenceById`, or overload
`transferUnitLoadToLocation` to take a destination **id**), not a one-liner. That is worth saying
plainly rather than filing it as a trivial fix.

---

## The eight checks in the brief

### 1. AC-1 — is the rollback IT genuinely grading rollback? **Mostly yes. Verified first-hand.**

**The four witnesses are all reachable and all meaningful.** Reachability is proved by the IT's own
passing exception assertion, not by inspection: the test asserts

```java
assertThatThrownBy(() -> mobileTruckLoadingService.scanGate(dto))
        .as("the injected D6 failure must surface, and must be THE injected one")
        .isInstanceOf(EntityNotFoundException.class)
        .hasMessageContaining("ItemData");
```

and `"ItemData"` can only come from the `@MockitoBean ItemdataService` stub. Reaching that line means
PHASE D1 (`billofladingRepository.save(bol)`), D2 (`transferUnitLoadToLocation`), D4
(`save(palletBOLPos)`) and D5 (`save(parcelBOLPos)`) all executed — i.e. each of witnesses 1–4 had a
real committed-or-pending write to undo. Meaningfulness is separately pinned by four pre-call
controls asserting the BOL starts `OPEN`, with a null `outboundlocationId`, the pallet at `storage`
and the BOL with no positions; each control carries an `as("control: … or witness N proves
nothing")`. The `SoftAssertions` wrapper is the right call and is justified in a comment.

The `@MockitoBean`-vs-`@MockitoSpyBean` reasoning is correct: `ItemdataService` carries no
`@Transactional`, so the SBDEV-3398 §10.5 landmine does not apply.

**I re-ran the documented mutation check rather than trusting it, and it reproduces exactly**, down
to the diagnostic:

```
[the injected D6 failure must surface, and must be THE injected one]
Expecting actual throwable to be an instance of:
  net.aim_ai.wms.exceptions.EntityNotFoundException
but was:
  org.springframework.dao.InvalidDataAccessApiUsageException: Query requires transaction be in
  progress, but no transaction is known to be in progress
```

So the class javadoc's self-correction is accurate and honest: the mutant is an **attributable** kill
(the diagnostic names the thing removed), but it dies at the exception-identity assertion and never
reaches the four witnesses, so **the four witnesses themselves are not mutation-checked by any
mutant that exists**. The javadoc says so and explains why an isolating mutant would be contrived. I
agree with that reasoning and record it as a known, bounded limit rather than a finding.

The IT also incidentally discharges two things nothing else covers: Spring **context load** with the
new bean graph (`MobileTruckLoadingService → MobileTruckLoadingWriteService → MobileMoveUnitloadService`
— no cycle; the three other `src/main` files mentioning `MobileTruckLoadingService` reference it in
javadoc only), and the new native interface projection `ParcelOrderIdView`. On the projection: the
query aliases camelCase (`SELECT parcel.id AS parcelId, co.id AS orderId`) where the repo's other
native projections use snake_case (`AS manifest_location`). H2 folds unquoted aliases to upper case,
so the IT passing proves the mapping is case-insensitive, which covers Postgres's lower-case fold
too. No concern.

**Where AC-1 is PARTIAL — F5.** AC-1 has a second, explicit half that is not implemented:

> *"**Then keep the guard fixture as a separate test** asserting the orphan/duplicate errors now fire
> before any write — that is a real behaviour change and worth pinning on its own."*

There is no test for the orphan-parcel guard and none for the duplicate-order guard anywhere — not in
`MobileTruckLoadingWriteServiceUnitTest` (its seven tests are A1–A6 and C1, the gate-mismatch guard),
not in the IT. Those two are precisely the guards that moved from mid-write-loop to pre-write, i.e.
the behaviour change the ticket delivers. The IT javadoc acknowledges the gap (*"A checked-exception
rollback needs its own test once PHASE C exists — at which point the orphan-parcel fixture becomes
useful again, but as a guard-ordering test"*) without closing it.

Related and untested: `rollbackFor = {BusinessException.class, FacadeException.class}` on the write
service. It is load-bearing on the real path — `transferUnitLoadToLocation` at D2 throws
`FacadeException` for `STORAGELOCATION_LOCKED`, `CARRIER_NOT_ON_FIXLOC` and constraint violations,
all *after* the D1 BOL save — yet the only rollback test drives an **unchecked**
`EntityNotFoundException`, which Spring rolls back by default. The IT javadoc states this limit
explicitly (*"This test therefore pins the *presence* of a boundary, not `rollbackFor =
BusinessException.class`"*). Both of these are cheap unit-level additions.

### 2. Bug 6 / 6a — the first-touch rule, walked PHASE A→D. **Six of seven sites clean; the gate is F2.**

Every read inside the boundary, against the plan's seven-site checklist:

| plan's site | what the branch does | verdict |
|---|---|---|
| pallet `findByLabelid` | `unitloadRepository.existsByLabelid(dto.getPalletName())` — scalar boolean; B2 then `findByLabelidForUpdate` | clean |
| BOL `findByName` | new scalar `billofladingRepository.findIdByName`; B1 `findByIdForUpdate(lockedBolId)` | clean |
| **gate `findByName`** | new scalar `locationRepository.findIdByName` in A — **then `locationRepository.findById(resolvedGateId)` in D, above the collaborator's lock** | **F2** |
| parcels `findByCarrierunitloadId` | new scalar `findIdsByCarrierunitloadIdOrderById`; loop `findByIdForUpdate(parcelId)` | clean |
| orders `getByParcelIdList` | new scalar projection `findParcelOrderIdsByParcelIdIn`; loop `findByIdForUpdate(orderId)` | clean |
| stockunits `findByUnitloadId` | entities materialised at B4 — but the design never locks `Stockunit`, so there is no upgrade | clean, and correctly flagged in-code |
| order positions `findByOrderId` | entities at B6 — never locked | clean |

Two further entity touches inside the boundary, both benign and both checked rather than assumed:
`userRepository.findByName(...)` (nothing locks `User`; `createEntity` only reads `operator.getId()`),
and `billofladingPositionService.createEntity`'s `clientService.getSystemClient()` /
`findByBillofladingId` (nothing locks `Client` or `BillofladingPosition`; and see check 4 on why the
`BillofladingPosition` reads being *after* D0 matters). Inside `transferUnitLoadToLocation`, the two
extra reads plan §4.3.5 names — `unitloadRepository.findById(carrierunitloadId)` and
`locationRepository.findById(storagelocationId)` — both sit **after** the `findByIdForUpdate`, so
neither adds a violation even in the degenerate case where the pallet is already at the gate.

*Method and blind spot for this table: I read `MobileTruckLoadingWriteService` end to end, then read
`transferUnitLoadToLocation` and grepped `UnitloadBusinessService` for `ForUpdate|locationRepository.findById|unitloadRepository.findById`,
and read `BillofladingPositionService.createEntity`. It is blind to anything reached through a
further layer of delegation inside `processTransfer`, and to anything reached reflectively.*

**F3 — MEDIUM: `LocationRepository.findIdByName`'s javadoc states a trigger that cannot occur.** It
says the upgrade *"would surface as `StaleObjectStateException` **exactly when two operators scan the
same gate**."* Two concurrent scans do not produce it: the second blocks on the row lock, and since
nothing on the path writes the `Location`, the version is unchanged when it proceeds. The real
trigger is an out-of-band `location` UPDATE committing inside the window (see F2). This matters
because it is the sentence a reviewer would use to size the risk, in both directions.

**F4 — MEDIUM: there is no first-touch / lock-order rail for this service, and the precedent the plan
says it follows has one.** `MobilePalletizeFirstTouchInvariantUnitTest` exists precisely for this:

> *"`MobilePalletizeRaceIT` proves two operators cannot both win, but it cannot distinguish a correct
> implementation from the *read-then-lock* shape SBDEV-3244 forbids … This class closes that escape
> statically and costs milliseconds."*

Its shape is `InOrder` on the locking finders, `verify(..., never())` on each non-locking sibling,
and `verifyNoMoreInteractions` to catch a newly-added finder. Applied to
`MobileTruckLoadingWriteService`, the row `verify(locationRepository, never()).findById(any())` would
have gone red on F2 at authoring time, in milliseconds, with no database. This is the single
highest-value missing test on the ticket, and it does **not** depend on any deferred AC.

### 3. PHASE C is predicate-only. **VERIFIED.**

Between the PHASE C banner and the D0 call, `MobileTruckLoadingWriteService` contains no `set*` on a
managed entity and no `save`. The develop-era mutation inside the state switch is replaced by two
locals:

```java
String pendingState = null;
switch (bol.getState()) {
    …
    case WmsConstants.BillOfLadingState.OPEN:
        pendingState = WmsConstants.BillOfLadingState.TRUCK_LOADING;
```

and the gate assignment likewise via `Long pendingOutboundLocationId`, both applied only at D1 after
the purge. The waterfall semantics are byte-for-byte the develop ones (`CREATED` falls into `OPEN`
falls into `TRUCK_LOADING: break`). The only repository call in C is the scalar
`locationRepository.findNameById(...)` on the throwing arm. C-9 holds.

### 4. D0 precedes every `createEntity`. **VERIFIED.**

`mobileTransferService.handleTruckOffLoadingNoClear(dto.getPalletName())` is the last statement before
the PHASE D banner; the first `billofladingPositionService.createEntity(bol, operator)` is 23 lines
below it. Nothing between them creates a BOL position — D1 saves the BOL header and D2 relocates the
pallet, neither of which touches `billoflading_position`. The plan's stated hazard (*"Running the
purge after D4/D5 would delete the tree this very scan just built"*) cannot occur.

Two things I checked because the no-clear variant makes them load-bearing, and both hold: **nothing
reads a `BillofladingPosition` as an entity above D0**, so dropping `clearAutomatically` strands no
stale instance; and `createEntity`'s count read `findByBillofladingId(billOfLading.getId())` runs
*after* the bulk DELETE, so it counts post-purge rows. The `flushAutomatically = true` on the new
siblings is a no-op here by construction (C-9 guarantees nothing pending) but is the right defensive
default and is correctly distinguished from the `UserRoleUserFunctionRepository` "no-op" precedent in
the javadoc.

### 5. Lock order. **VERIFIED, including both ordering sub-questions.**

The class javadoc declares
`Billoflading → Unitload (pallet, then parcels asc by PARCEL id) → Stockunit → Customerorder asc → CustomerorderPosition`,
which is character-identical to `MobilePalletizeWriteService`'s line 106 and consistent with
`ParcelMonitorViewService`'s `Billoflading -> Unitload -> Stockunit -> Customerorder -> CustomerorderPosition`.
B1…B6 execute in that order.

- **Parcel ordering comes from the query, as required.** `UnitloadRepository`:
  `@Query("SELECT u.id FROM Unitload u WHERE u.carrierunitloadId = :carrierunitloadId ORDER BY u.id")`,
  with the javadoc *"`ORDER BY u.id` is load-bearing, not cosmetic … Do not remove the ordering or
  sort at the call site instead — keeping it here makes the guarantee a property of the query."* The
  call site iterates `parcelIds` directly with no re-sort, and D4–D6 iterate the same list, so the
  write loop runs in lock order too.
- **Order ids are sorted ascending at the call site**, which is necessary because the projection's
  `ORDER BY parcel.id, co.id` is a parcel-major order, not an order-id order:
  `sortedOrderIds.sort(Long::compareTo);` immediately before the `findByIdForUpdate` loop. Correct.
  De-duplication is by `!sortedOrderIds.contains(...)`, which is O(n²) but bounded by orders-per-pallet
  (measured worst case in the plan: 70 parcels) — not worth raising as a defect.

### 6. AC-5 and AC-6. **Both VERIFIED.**

`grep -n "Transactional" src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java`
returns exactly one hit, and it is prose inside a javadoc — there is **no** `@Transactional`
annotation anywhere in the outer class. Both concerns therefore run with no transaction open:

```java
outcome = truckLoadingWriteService.scanGate(truckLoadingMobileDTO);
} catch (PessimisticLockingFailureException e) {
    throw lockContention(e, truckLoadingMobileDTO.getPalletName());
}
…
notifyOms(outcome);
```

AC-6's translation follows the pinned `MobilePalletizingService.lockContention` precedent, including
logging only `cause.getClass().getSimpleName()` (that precedent's comment explains why the full
message must not be logged). The one-argument `BusinessException` ctor resolves through
`placeholder=%1s` in `messages.properties`, so `e.getMessage()` at
`TruckLoadingController.scanGate:122` yields the operator text — which the unit test pins via
`.hasMessageContaining("PALLET001")` and `.hasMessageContaining("scan again")`. The javadoc's note
that `CannotAcquireLockException` (40P01) is a subclass and therefore covered is correct, and the
test drives that subclass specifically.

AC-5's test also asserts the negative that matters — `verify(manageOrderService, never())
.customerOrderLoadedToTruck(...)` when the write service threw — so a notification cannot fire for a
scan that never committed.

### 7. The relocated tests. **VERIFIED — nothing weakened, nothing silently dropped.**

Compared line by line against `git show origin/develop:src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingServiceTest.java`:

| develop test | now | assertions |
|---|---|---|
| `testScanGateWithNullPalletName` | `A1` | preserved, **plus** `assertNothingWasWritten()` |
| `testScanGatePalletNotFound` | `A2` | `hasMessageContaining("No entity Unitload found for name")` preserved, **plus** `verify(unitloadRepository, never()).findByLabelid(anyString())` |
| `testScanGateWithNullBolName` | `A3` | preserved, plus an explicit message-order pin |
| — | `A4` | **new** (unknown BOL name); develop had no such test |
| `testScanGateWithNullGateName` | `A5` | preserved |
| `testScanGateGateNotFound` | `A6` | preserved, **plus** `verify(locationRepository, never()).findByName(anyString())` |
| `testScanGateWithDifferentGate` | `C1` | `hasMessageContaining("differs from required")` preserved |
| `testScanGateSuccessfully` | dropped | see below |

Every relocated assertion survived, and each gained a `never()` write check that the originals could
not make. No assertion was weakened.

The happy path was **dropped, not relocated.** Its two verifies were
`verify(unitloadBusinessService).transferUnitLoadToLocation(mockPallet, mockGate, false,
WmsConstants.CODE_TRUCK_LOADING, mockBilloflading.getNumber(), null)` and
`verify(mobileTransferService).handleTruckOffLoading("PALLET001")`. Both properties are now covered
behaviourally by the rollback IT (which cannot reach D6 unless the transfer and the purge both ran),
so this is a real substitution rather than a loss — but note that the IT covers them *implicitly*,
and the exact-argument check on `ignoreLock=false` is no longer asserted anywhere. Restoring it as
one row of the F4 rail would close that.

**F12 — informational.** The commit message says *"The seven scanGate unit tests were relocated, not
deleted"*. Precisely: six were relocated, one (`A4`) is new, and the seventh (the happy path) was
replaced by the IT. Worth correcting in the PR body so the next reader does not go looking for a
relocated happy path.

### 8. §4.1 in-scope, and anything unsanctioned.

**Everything in §4.1 is implemented.** Boundary and lock sequence ✓. `handleTruckOffLoading` ahead of
every pending write ✓. `PessimisticLockingFailureException` translation ✓. OMS notification outside ✓.
On *"the five id projections"*: four were added (`Billoflading.findIdByName`,
`Unitload.findIdsByCarrierunitloadIdOrderById`, `Customerorder.findParcelOrderIdsByParcelIdIn`,
`Location.findIdByName`) plus `Location.findNameById` for the mismatch message. §2's affected-locations
table also lists a `StockunitRepository` id projection; it was correctly **not** added, because §3.2
B4 settles that `Stockunit` is read unlocked and §4.3.4 requires any future locked finder to *replace*
that read rather than sit beside it. §3.2 governs. Not a gap.

**F6 — MEDIUM: `handleTruckOffLoadingNoClear` is not the faithful copy its javadoc claims.** The
javadoc says *"Identical resolution and identical deletes; the only difference is that neither delete
issues `EntityManager.clear()`."* That is false — the new overload also adds a guard the original
does not have:

```java
if (pattern == null && convertedPrintingPattern == null) {
    // SBDEV-3418: both sysprops unset. The original overload passes null straight into
    // String.matches() and dies with NullPointerException …
    return;
}
boolean matches = (pattern != null && unitLoadLabel.matches(pattern))
        || (convertedPrintingPattern != null && unitLoadLabel.matches(convertedPrintingPattern));
```

against the original's `if (unitLoadLabel.matches(pattern) || unitLoadLabel.matches(convertedPrintingPattern))`.
Three points: (a) the two overloads now diverge on unset or partially-unset sysprops, which is a
behaviour difference the javadoc denies; (b) the guard is not in §4.1 and is not covered by any test —
no case drives either sysprop null; (c) the IT javadoc's parenthetical *"(The NPE itself is a real
robustness gap in `handleTruckOffLoading`, **recorded in the plan**…)"* is a mis-citation —
`grep -n "NullPointer\|NPE\|this.pattern"` over the plan finds only §6.1's note about a *mocked*
`syspropService` in `MobileTruckLoadingServiceUnitTest`, which is a different thing entirely. The
change is defensible on its merits; the javadoc claim and the citation are not.

**F7 — LOW: §4.3 requires the residuals in the javadoc; three of six are not there.** Stated well:
residual 1 (`billoflading_position` unplaced), 2 (unitload-vs-unitload, with the 27.32%/480,334
figures), 3 (`Location` unranked). **Partial:** residual 4 — the B4 comment covers the future-writer
case but neither B4 nor B6 states that `billoflading_position.amount` and `.orderposition_id` are
therefore **non-repeatable reads**. **Absent:** residual 5 (the three rows
`transferUnitLoadToLocation` touches outside the lock set — only the gate is named) and residual 6
(lock fan-out, *"up to ~142 acquisitions"* on a worst-case Hydra prd pallet). `grep -n
"142\|fan-out\|non-repeatable\|acquisitions"` over the write service returns one hit, and it is the
word "acquisitions" in an unrelated sentence. §4.3's instruction is explicit: *"state them in the
javadoc, do not imply safety."*

**F8 — LOW: this change strands a cross-reference in another file.**
`src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` cites
`…ParcelMonitorViewService:227/:383/:469, MobileTruckLoadingService:310)` as one of *"six other
sites"* using the `TransactionSynchronizationManager` else-branch shape. This commit removed that
code from `MobileTruckLoadingService` (the diff drops both `TransactionSynchronization` imports), and
the file is now 262 lines, so `:310` does not exist. The count of six is now five.

**F9 — LOW: the ArchUnit freeze-store pruning is not in the commit.** See the note under "What I
ran". As committed, the store still freezes two `Optional.get()` violations at
`MobileTruckLoadingService.java:190` and `:207` — code this commit deleted. Harmless at runtime
(pruning happens on the next run and the default fuzzy line matcher tolerates the drift), but the
first person to run `mvn test` gets an unexplained dirty file.

**F10 — LOW: `bolGateName` is now always populated, and its guard is constant-true.**
Outer service: `if (outcome.bol().getOutboundlocationId() != null) { truckLoadingMobileDTO.setBolGateName(outcome.gateName()); }`.
After D1 the BOL's `outboundlocationId` is non-null on every path that returns an outcome (either
pre-existing or just assigned), so the condition never fails. On develop, `setBolGateName` was called
**only** in the newly-assigned-gate branch, so a scan against an already-assigned gate now returns a
`bolGateName` it previously left alone. The value is the same gate either way, so this looks benign —
but it is a DTO contract change that no test distinguishes and the plan does not sanction.

**F11 — LOW: two small operator-visible ordering changes inside PHASE C.** Develop interleaved the
orphan and duplicate checks per parcel in `findByCarrierunitloadId` order; PHASE C now runs *all*
duplicate checks, then *all* orphan checks, over parcels in ascending-id order. So for a pallet with
both an orphan parcel and a duplicated one, the reported error can flip from
`"unexpectedUnitLoadDoesNotHaveOrder"` to `"Too many orders with the same parcel found"`, and the
parcel named in the orphan message can differ. Unavoidable given the hoist, correct to do, worth one
line in the PR body.

---

## Summary of findings

| # | severity | finding |
|---|---|---|
| F1 | **Blocker** | `TestClassTransactionManagerArchTest` red — `MobileTruckLoadingRollbackIT` missing from `EXEMPT_NON_TRANSACTIONAL`. Reproduced on a clean build |
| F2 | **High** | Gate `Location` first-touch violation at `MobileTruckLoadingWriteService` PHASE D (`locationRepository.findById` above the collaborator's `findByIdForUpdate`), with a comment asserting the opposite. Surfaces as an untranslated HTTP 500 |
| F3 | Medium | `LocationRepository.findIdByName` javadoc names a trigger ("two operators scan the same gate") that cannot occur |
| F4 | Medium | No first-touch / lock-order unit rail, though the precedent the plan follows (`MobilePalletizeFirstTouchInvariantUnitTest`) has one. It would have caught F2 statically |
| F5 | Medium | AC-1's guard-ordering half unimplemented; `rollbackFor` (checked-exception rollback) untested |
| F6 | Medium | `handleTruckOffLoadingNoClear` adds an unsanctioned, untested null-sysprop guard; its javadoc denies the divergence and mis-cites the plan |
| F7 | Low | §4.3 residuals 4 (partial), 5 and 6 absent from the javadoc |
| F8 | Low | `MobileReplenishService:700` now cites a `MobileTruckLoadingService:310` that no longer exists |
| F9 | Low | ArchUnit freeze-store pruning not committed |
| F10 | Low | `bolGateName` DTO change; guard is constant-true |
| F11 | Low | Guard message-order change inside PHASE C |
| F12 | Info | Commit message's "seven relocated" is 6 relocated + 1 new + 1 replaced |
| — | Info | AC-2/3/4/7 deferral is recorded nowhere; plan §9.2 still says "Not started" and its two non-optional pre-implementation items have no recorded result |

F1 and F2 are the two that should block. F4 and F5 are the cheapest high-value additions and neither
depends on a deferred AC.

---

## ADDENDUM — the worktree moved under this lane while it was being graded

**Everything above grades commit `e64bdb5c`, and still does.** The tree was clean (`git status
--short` empty) when this lane started. On finishing, it is not:

```
 M src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java
 M src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java
 M src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java
 M src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingWriteServiceUnitTest.java
 M src/test/resources/archunit_store/5fb3fee0-6caf-4f48-a5cd-5271da610572
```

Another lane has been editing the same worktree concurrently, and its **uncommitted** working tree
already addresses F1, F2 and part of F5:

- **F1** — `MobileTruckLoadingRollbackIT` is now in `EXEMPT_NON_TRANSACTIONAL` with a written
  justification covering the FK-ordered cleanup, the shared `"System"` client and the `TL1-` prefix.
- **F2** — PHASE D now reads
  `Location gate = locationRepository.findByIdForUpdate(resolvedGateId)`, with a comment that
  reaches the same diagnosis this report did, independently (*"Location extends AbstractBaseEntity,
  which carries @Version … the upgrade throws ObjectOptimisticLockingFailureException, which is NOT
  a PessimisticLockingFailureException"*).
- **F5 (part)** — a new `scanGate_shouldPurgeStalePositions_beforeAnyWrite` `InOrder` test pins D0
  ahead of the header write and the position inserts.

**None of that is verified by this lane.** I re-ran nothing against it, and it is not in any commit.
Three things a follow-up must settle:

1. **⚠ My mutant probe wrote to this shared worktree while another lane was editing it.** I copied
   `MobileTruckLoadingWriteService.java` to the scratchpad, deleted its two `@Transactional` lines,
   ran the IT, and copied the backup back. If the other lane's F2 edit landed between my backup and
   my restore, my restore would have reverted it. The file currently **does** carry their fix, so
   either the ordering was benign or they re-applied it — but I cannot prove which from here, and
   the other four modified files were never touched by me. **Diff the working tree against what that
   lane believes it wrote before committing.** This is my error: a mutant probe belongs in a private
   worktree, not in the tree another lane is editing.
2. **The F2 fix contradicts a "settled constraint".** Plan §3.2 PHASE D says *"⚠ Do **not** add a
   `locationRepository.findByIdForUpdate(gateId)` of our own here — with A6's scalar projection the
   gate has no `EntityEntry`, so the inner lock is already an acquisition."* The premise is false in
   practice: `transferUnitLoadToLocation(Unitload, Location, …)` takes a `Location` **object**, so
   PHASE D must materialise the row somehow, and `LocationRepository extends CrudRepository`, which
   has no `getReferenceById`. Given that, taking the lock ourselves is the right call — a
   `WRITE→WRITE` re-lock at the same mode is a no-op in `LoaderHelper.upgradeLock` (not greater than
   the held mode ⇒ no version check), so the inner call cannot throw. But §3.2 now instructs the
   opposite of the code, and **the plan must be amended rather than left to contradict it**,
   otherwise the next reader "fixes" it back.
3. The remaining findings — F3, F4, F6, F7, F8, F9, F10, F11, F12 and the undocumented
   AC-2/3/4/7 deferral — appear untouched. F4 (the `MobilePalletizeFirstTouchInvariantUnitTest`-shaped
   rail) is the one that would have caught F2 at authoring time and would stop it returning; the new
   `InOrder` D0 test is a good step but does not carry the `never()` / `verifyNoMoreInteractions`
   rows that grade the first-touch rule.

**Re-verification needed** once the working tree is committed: the full targeted unit selection plus
the rollback IT, both re-run on a clean build. The numbers in "What I ran" are valid for `e64bdb5c`
only. `target/` also still holds classes from my mutant run — `mvn clean` first.

---

# PART 2 — re-verification after the concurrent-Maven warning

The lead reported that two Maven processes ran in the SBDEV-3418 worktree at once and corrupted
`target/`, and asked me to discard suspect Maven output, always pass `clean`, and concentrate on
three areas the other lanes did not cover.

**My exposure to the corruption.** Of my four Part 1 Maven runs, only the first (`clean compile`)
passed `clean`; the unit run, the IT run and the mutant run did not. Those three are therefore
suspect and are **withdrawn as measurements** — see the re-measurement below for what replaces them.
None of them reported a `bad class file`, a `cannot find symbol` on an existing class, or
`DamagedTransfer`; the failures they reported were an ArchUnit set-equality assertion and an AssertJ
type assertion, neither of which is a corruption shape. That is an argument, not evidence, so I
re-ran them anyway.

**Two more collisions happened during this re-run, and they are worth recording as a process fact.**

1. My first re-run attempt died in `clean` itself —
   `Failed to clean project: Failed to delete …/target/classes/net/aim_ai/wms` — on *both* the unit
   and IT invocations. No tests ran. `rm -rf target` then failed with `Directory not empty`, and a
   `java` process (pid 78038) was holding `cwd` on the SBDEV-3418 worktree with all 646 files under
   `target/` written in the preceding 60 seconds. So a third build was live in that worktree while I
   was told I had it to myself. This is the same failure mode, and `clean` does not protect against
   it — `clean` is what loses the race.
2. **Fighting for the shared tree is the wrong fix.** I created my own detached worktree at the
   commit under review and re-measured there:
   `git worktree add --detach /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3418-verify e64bdb5c`.
   It is clean, it is pinned to the commit rather than to a working tree three lanes are editing, and
   it cannot contend. **It is still on disk** — remove it with
   `git worktree remove .claude/worktrees/wms2-api/SBDEV-3418-verify` when this ticket closes.

## Re-measurement — clean, serialized, in an isolated worktree at `e64bdb5c`

| run | result |
|---|---|
| `mvn -B -ntp clean test -Dtest='MobileTruckLoadingWriteServiceUnitTest,MobileTruckLoadingServiceTest,MobileTruckLoadingServiceUnitTest,TestClassTransactionManagerArchTest,OptionalSafetyArchTest'` | `TestClassTransactionManagerArchTest` — **`Tests run: 5, Failures: 1`**. `MobileTruckLoadingWriteServiceUnitTest` 7/7 green, `OptionalSafetyArchTest` 1/1 green |

**F1 is confirmed, not corruption.** It reproduces in a pristine worktree, on a `clean` build, with
no other Maven process in that tree — a different filesystem location from the one that was
corrupted. Combined with the lead's independent source-level confirmation, F1 stands as a genuine
red.

⚠ The Part 1 numbers for the rollback IT (`Tests run: 1, Failures: 0`) and for the mutant
(`Tests run: 1, Failures: 1`, dying at the exception-identity assertion with
`InvalidDataAccessApiUsageException: Query requires transaction be in progress`) were taken without
`clean` and are formally withdrawn. The IT re-run in the isolated worktree was still executing when
this report was handed back — **treat AC-1's runtime evidence as re-measurement-pending**, though
its *reasoning* (below) is source-derived and unaffected.

---

## The three assigned areas

Everything in this section is derived from `git show e64bdb5c:<path>`, not from the working tree, so
it is immune both to `target/` corruption and to the concurrent edits.

### A. Was anything in §4.1 silently not implemented? — **No. But the plan contradicts itself, and the count in §4.1 is wrong.**

Complete ledger of what `e64bdb5c` adds under `repo/`, by
`git diff origin/develop e64bdb5c -- src/main/java/net/aim_ai/wms/repo/`:

| added | where |
|---|---|
| `Long findIdByName(String)` | `BillofladingRepository` |
| `List<Long> findIdsByCarrierunitloadIdOrderById(Long)` | `UnitloadRepository` |
| `List<ParcelOrderIdView> findParcelOrderIdsByParcelIdIn(Collection<Long>)` | `CustomerorderRepository` |
| `Long findIdByName(String)` | `LocationRepository` |
| `String findNameById(Long)` | `LocationRepository` |
| `void deleteBolPositionByIdNoClear(Long)` · `void deleteBolPositionsCarrierIdsNoClear(List<Long>)` | `BillofladingPositionRepository` |
| `ParcelOrderIdView` (interface) | `repo/projection/` |

Measured against §2's *Affected locations* table, which is where the "five id projections" of §4.1
actually come from:

| §2 row | implemented? |
|---|---|
| `BillofladingRepository` — new id projection by name | **yes** |
| `UnitloadRepository` — pallet id by label | **no** — §3.2 PHASE A specifies the pre-existing scalar `existsByLabelid(palletLabel)` instead, and that is what the code calls |
| `UnitloadRepository` — child parcel ids by pallet id | **yes** |
| `CustomerorderRepository` — order ids by parcel ids | **yes** |
| `StockunitRepository` — stockunit ids by unitload id | **no** — §3.2 B4 settles `Stockunit` as an *unlocked entity read*, and §4.3.4 requires any future locked finder to **replace** that read rather than sit beside it. `git diff --name-only` confirms `StockunitRepository.java` is untouched by the commit |

So **three of §2's five**, with both omissions superseded by §3.2, which governs. Not gaps. Two
projections were added that §2 does not list: `Location.findIdByName` (required by §3.2 PHASE A,
*"new `findIdByName` on Location"* — §2's table simply omits `LocationRepository` entirely) and
`Location.findNameById` (in neither section; it makes the PHASE C mismatch message scalar, which is
*stricter* than Bug 6a required — that text allows the mismatch branch to materialise freely
"because it throws").

**No locked finders were added, and none needed to be.** All eight finders the write service relies
on already exist on `origin/develop` — verified with a positive control (`findByLabelid` = 10 hits)
and a negative control (`zzzNotAMethod` = 0), after an initial run of this scan returned a false
all-zero because my pattern carried a trailing space:

| finder | hits on develop |
|---|---|
| `BillofladingRepository.findByIdForUpdate` | 1 |
| `UnitloadRepository.findByIdForUpdate` | 1 |
| `UnitloadRepository.findByLabelidForUpdate` | 2 |
| `UnitloadRepository.existsByLabelid` | 1 |
| `CustomerorderRepository.findByIdForUpdate` | 2 |
| `LocationRepository.findByIdForUpdate` | 1 |
| `CustomerorderPositionRepository.findByOrderId` | 1 |
| `StockunitRepository.findByUnitloadId` | 1 |

The two no-clear deletes are not in §4.1's list but are sanctioned by §5.1 P6: *"⇒ **no-clear sibling
methods scoped to the write service**; leave both existing deletes untouched."* The commit does
exactly that — both originals appear only as unchanged context in the diff.

**Action for the plan, not the code:** §2's table and §3.2 disagree on two rows and §4.1 inherits
§2's count. A reader auditing "the five id projections" finds three and will report a gap that is
not one. Reconcile §2 with §3.2, and add `LocationRepository` to §2's table.

**No dead code left behind.** Every one of the eight remaining `private final` fields on the slimmed
outer service is still referenced at least once (`billofladingPositionRepository` 1,
`locationRepository` 1, `unitloadRepository` 1, `billofladingRepository` 6, `customerorderRepository`
1, `syspropService` 2, `manageOrderService` 1, `truckLoadingWriteService` 1), and the `Optional`
import is still used.

### B. Did the relocated guard assertions lose strength? — **No. They are strictly stronger, with one specific and real weakness that is not about the relocation.**

Diffed against `git show origin/develop:src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingServiceTest.java`.
Both the old and new classes run `@ExtendWith(MockitoExtension.class)` +
`@MockitoSettings(strictness = Strictness.STRICT_STUBS)`, so there is **no strictness delta** — a
relocation into a LENIENT class would have silently weakened everything, and that did not happen.

Every message assertion survived verbatim: `"No entity Unitload found for name"` (A2) and
`"differs from required"` (C1) are the only two the originals had, and both are present. Six guards
relocated, one added (A4, unknown BOL name — develop had no such test), one dropped (the happy path).

**Three ways the relocated set is stronger than develop's:**

1. Each gained `assertNothingWasWritten()` — four `never()` rows the originals could not express,
   because on develop the orphan and duplicate rejections fired mid-write-loop.
2. A2 and A6 gained first-touch negatives: `verify(unitloadRepository, never()).findByLabelid(anyString())`
   and `verify(locationRepository, never()).findByName(anyString())`.
3. **A3 and A5 genuinely pin the operator-visible message order**, which develop could not. A3 sets a
   null BOL name and asserts `verify(unitloadRepository).existsByLabelid(PALLET)`; if the BOL were
   resolved first, the BOL null-check would throw before the pallet probe ran and that verify would
   fail. Under STRICT_STUBS, A5's two stubs likewise force both prior resolutions to have happened.
   This is a real contract that was previously unguarded.

**The one weakness, and it is a genuine finding — F13 (Medium).** `assertNothingWasWritten()` is a
bank of four `never()` rows, and at `e64bdb5c` **not one of them has a positive control anywhere in
the class**. Mechanically:

```
grep -nE "verify\((billofladingRepository|billofladingPositionRepository|customerorderRepository|mobileTransferService)\)\." \
  MobileTruckLoadingWriteServiceUnitTest.java | grep -v never
→ NONE — every verify on a write collaborator is a never()
```

That is exactly the shape this repository has already written a rule against, in the sibling the
plan says this work mirrors — `MobilePalletizeFirstTouchInvariantUnitTest`:

> *"**Why every `never()` here is paired with a positive row.** A `never()` on a method the code
> never calls under any circumstance passes before the fix, after the fix, and after someone deletes
> the fix. The paired positive verification is what proves the path actually executed, so the
> negative means something."*

To be fair to the tests: the rows are **not** structurally vacuous today — moving a guard below the
BOL save would make `verify(billofladingRepository, never()).save(any())` fire. The gap is that
nothing in the class demonstrates the four named methods are the ones the write path actually calls,
so a refactor that routes a write through a different collaborator leaves all seven tests green.
Note in particular that `billofladingPositionService` is mocked here, so on the real happy path the
position rows are created through that mock — only the *direct* `billofladingPositionRepository.save`
calls in D4–D6 would register.

*Partially closed by the working tree:* the other lane's new `scanGate_shouldPurgeStalePositions_beforeAnyWrite`
does reach `billofladingRepository.save(bol)` and `handleTruckOffLoadingNoClear`, giving positive
control for two of the four. `billofladingPositionRepository.save` and `customerorderRepository.save`
still have none. **Remedy:** extend that test's fixture to one parcel with an order and one stockunit;
it then exercises all four write collaborators positively in a single case, and the `never()` bank
becomes graded rather than merely asserted. This is the same cheap addition as F4 and they should be
done together.

**On the dropped happy path.** `testScanGateSuccessfully` carried two verifies that now live nowhere
at unit level: `verify(unitloadBusinessService).transferUnitLoadToLocation(mockPallet, mockGate,
false, WmsConstants.CODE_TRUCK_LOADING, mockBilloflading.getNumber(), null)` and
`verify(mobileTransferService).handleTruckOffLoading("PALLET001")`. The rollback IT covers both
*implicitly* — it cannot reach D6 unless the transfer and the purge both ran — but the **exact-argument
check on `ignoreLock=false` is no longer asserted anywhere**, and `ignoreLock` is the argument that
decides whether the gate row is locked at all, i.e. the argument F2 turns on. One row in the F4 rail
restores it.

### C. Is PHASE C genuinely predicate-only? — **Yes. Verified mechanically, with a working positive control.**

PHASE C is lines 258–305 of `MobileTruckLoadingWriteService` at `e64bdb5c` (banner-to-banner; the
phase banners sit at A 159, B 193, C 258, D0 305, D 324). Scanning that 48-line region for
`\.set[A-Z]`, `\.save(`, `\.delete`, `\.merge`, `\.flush`:

- **PHASE C: 0 hits.**
- **The identical scan over PHASE D: 16 hits** — the positive control that proves the instrument
  works. A zero with no control is indistinguishable from a broken pattern, which is precisely how
  the finder scan in section A misled me a few minutes earlier.

The only collaborator call in the whole region is a read:

```java
String requiredGateName = locationRepository.findNameById(bol.getOutboundlocationId());
```

— a JPQL scalar projection, which cannot mutate. The develop-era mutations are correctly deferred
into locals and applied only at D1:

```java
String pendingState = null;
switch (bol.getState()) {
    …
    case WmsConstants.BillOfLadingState.OPEN:
        pendingState = WmsConstants.BillOfLadingState.TRUCK_LOADING;
```

with `Long pendingOutboundLocationId` doing the same for the gate. The `CREATED → OPEN →
TRUCK_LOADING` waterfall is semantically identical to develop's. C-9 holds, and therefore so does the
D0 precondition that no write is pending at the purge.

*Blind spot of this check: it is a textual scan of the region between the two banner comments. It
would not see a mutation performed inside a collaborator called from C (there is only one, and it is
a SELECT), nor one in code that executes during C but is textually outside the banners (there is
none — C is straight-line).*

One clarification worth recording, because it looks like a §3.2 deviation and is not: the
**detection** of duplicate orders per parcel happens in B5, while populating `orderIdByParcelId`
and `duplicateParcelIds`; only the **throw** is in C. §3.2 lists the "duplicate-order-per-parcel
check" under C. Building a local `List<Long>` is not a mutation of persistent state, so C-9 is
unaffected.

Also confirmed while here: **witness 4 of the rollback IT corresponds to a real write** —
`UnitloadBusinessService` does `unitload.setStoragelocationId(destinationLocation.getId());`
immediately followed by `unitload = unitloadRepository.save(unitload);`. So asserting the pallet
returns to `storage` after the rollback is a meaningful assertion, not a tautology.

---

## Findings added in Part 2

| # | severity | finding |
|---|---|---|
| F13 | Medium | `assertNothingWasWritten()`'s four `never()` rows have **no positive control** anywhere in `MobileTruckLoadingWriteServiceUnitTest` — the exact shape `MobilePalletizeFirstTouchInvariantUnitTest`'s javadoc forbids. Fix together with F4 by extending the new D0 test's fixture |
| F14 | Low (plan, not code) | §2's *Affected locations* table and §3.2 disagree on two of the "five id projections", and omit `LocationRepository` entirely. §4.1 inherits the wrong count, so an auditor finds three of five and reports a phantom gap |
| F15 | Low (process) | A third Maven build was live in the SBDEV-3418 worktree during the re-run, after it was declared free; `clean` does not protect against this — it is what loses the race. Per-lane worktrees do. `SBDEV-3418-verify` is left on disk for removal |

Unchanged from Part 1: F1 (now confirmed in an isolated clean build) and F2 are the blockers; F3–F12
stand. **Overall verdict remains FAIL for `e64bdb5c`**, with F1 and F2 already addressed in the
uncommitted working tree by the implementing lane.

---

# PART 3 — the four post-review fixes, and a premise that is wrong in three places

Part 1 graded commit `e64bdb5c`. Part 2 re-measured it after the corruption warning. Part 3 grades
the four fixes that landed in the working tree afterwards. **Parts 1 and 2 stand as the record of
the pre-fix state, as the lead asked** — nothing below retracts a pre-fix verdict; where a fix has
since closed a finding, it is marked CLOSED rather than deleted.

## Housekeeping first

**The outstanding AC-1 measurement came back green.** The isolated `clean verify` at `e64bdb5c`
finished: `MobileTruckLoadingRollbackIT` — `Tests run: 1, Failures: 0, Errors: 0`, 77.8 s, **BUILD
SUCCESS**. Part 1's IT result is therefore re-established on a clean build in a worktree with no
other Maven process. AC-1's runtime evidence is no longer pending.

**Did any of my runs show the corruption shape?** Grepping all eight of my logs for
`cannot find symbol|TenantDbConfigCache|bad class file|DamagedTransfer` returns **no match** for any
Part 1 or Part 2 run. So the withdrawn Part 1 numbers were withdrawn out of caution, and both have
since been re-measured to the same values.

**But my first Part 3 attempt reproduced it exactly, and I can name the mechanism.** Running
`clean test` in the shared SBDEV-3418 worktree (after `rm -rf target`) failed with
`package net.aim_ai.wms.landlord.json does not exist` and `cannot find symbol` across ~30 test files.
The source is intact — `src/main/java/net/aim_ai/wms/landlord/json/TenantProfile.java` is present.
The log shows why:

```
[INFO] --- compiler:3.13.0:compile (default-compile) @ wms-api ---
[INFO] Compiling 573 source files with javac [debug parameters release 21] to target/classes
…
[INFO] --- compiler:3.13.0:testCompile (default-testCompile) @ wms-api ---
[INFO] Compiling 549 source files with javac [debug parameters release 21] to target/test-classes
[ERROR] …/H2TestConfiguration.java:[6,36] package net.aim_ai.wms.landlord.json does not exist
```

**The main compile succeeded and emitted 573 classes; the test compile then could not see them.**
That is only possible if something deleted `target/classes` in between — i.e. another Maven's
`clean` landing mid-build. So the shape is diagnosable rather than mysterious: *main compiles, test
compile cannot find main's output* is the concurrent-`clean` signature, and `clean` on your own
invocation is no defence against it.

**I have stopped using the shared worktree.** Part 3's measurements were taken by capturing the
working tree as a patch (`git diff` → 5 files, 216 insertions, 17 deletions), applying it into
`SBDEV-3418-verify` (the archunit store was already byte-identical there, so it is excluded from the
patch), and building in that worktree, which nothing else touches. The applied diffstat matches the
source tree's exactly.

## The four fixes — read and graded

### Fix 1 — PHASE D gate lock. **CORRECT as a fix. Its new comment carries a new false claim.**

The code is right:

```java
Location gate = locationRepository.findByIdForUpdate(resolvedGateId)
        .orElseThrow(() -> new EntityNotFoundException("Location", resolvedGateId));
```

This makes our call the Location row's first touch, so it is an acquisition; the inner
`findByIdForUpdate` inside `transferUnitLoadToLocation` is then a same-mode re-lock, which
`LoaderHelper.upgradeLock` treats as a no-op because the requested mode is not greater than the held
one. **F2 is CLOSED.**

The comment's citation checks out too — `MobilePalletizeWriteService` does state that rule, and
in almost these words: *"the entity is already at EntityEntry lock level WRITE (SBDEV-3244), which
is Hibernate's highest internal mode, so this is not an upgrade, no version check runs, and nothing
can throw."*

**But the same precedent contradicts the new comment's other claim**, and reading on is what caught
it. Fix 1's comment says the upgrade *"escapes as the bare HTTP 500 that AC-6 exists to prevent."*
Six lines further down in that precedent:

> *"⚠ Where that rejection surfaces. Two review lanes disagreed here, so it was settled by reading
> the advice chain rather than by taking either: the resulting `ObjectOptimisticLockingFailureException`
> is NOT caught by `MobilePalletizingService.lockContention` — deliberately, see AC-7 — and it does
> NOT fall through to a reference-coded 500 either. `RestExceptionHandler` is `@Order(0)` and maps it
> explicitly to 409 'The record was modified by another user. Please retry.'"*

**Verified independently, from source rather than from that javadoc.**
`src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` is `@Order(0)` + `@ControllerAdvice`
(unscoped), and carries:

```java
@ExceptionHandler(ObjectOptimisticLockingFailureException.class)
protected ResponseEntity<ProblemDetail> handleOptimisticLock(ObjectOptimisticLockingFailureException ex) {
    …ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, "The record was modified by another user. Please retry.");
    problemDetail.setProperty("retryable", true);
```

Its own class javadoc states the scope and precedence: *"`@Order(0)` sits between
`RestEndpointExceptionHandler` (HIGHEST_PRECEDENCE, scoped to controller.rest) and
`MobileEndpointExceptionHandler` (LOWEST_PRECEDENCE, scoped to controller.mobile) … The explicit
order guarantees the specific mappings below keep winning over the mobile advice's `Exception`
catch-all."* `TruckLoadingController` is in `controller.mobile`, so this advice applies to it and
wins.

So the pre-fix consequence was a **409 with an operator-legible, `retryable`-flagged ProblemDetail**,
not a bare 500.

**This correction applies to me too.** Part 1's F2 wrote *"It reaches `TruckLoadingController.scanGate`
… → raw HTTP 500."* That was wrong for the same reason, and I am recording it rather than quietly
editing it. F2's defect was real — an avoidable contention-time abort where a clean acquisition
would have blocked and then succeeded — but its blast radius was a spurious 409 retry prompt under a
narrow race, not a 500. **F2 was correctly rated as a real defect and over-rated on consequence.**

### Fix 2 — arch rail registration. **CORRECT. F1 CLOSED**, pending the run below.

`MobileTruckLoadingRollbackIT` is now in `EXEMPT_NON_TRANSACTIONAL` with a justification that names
the commit-and-outlive behaviour, the FK-ordered cleanup, the shared `"System"` client find-or-create
and the `TL1-` prefix — i.e. it satisfies the rule's stated demand ("*add or remove the class in
`EXEMPT_NON_TRANSACTIONAL` in the same commit, and say why*") rather than just silencing it.

### Fix 3 — the null guard. **CORRECT, and the premise checks out.**

I verified the claim rather than accepting it. `StringConverter.convertFormatToRegex`:

```java
public static String convertFormatToRegex(String format) {
    if (format == null || format.isEmpty()) {
        return "";
    }
```

So it never returns null, the old `convertedPrintingPattern == null` half of the guard was indeed
unreachable, and its `LOG.warn` could never fire. The replacement is NPE-free on both values
(`pattern != null && !pattern.isEmpty()` for the nullable sysprop; `!convertedPrintingPattern.isEmpty()`
for the never-null one), only tests configured patterns, and the javadoc now states the divergence
from the original overload instead of denying it. **The documentation half of F6 is CLOSED**; the
behavioural divergence remains real but is now correctly described and justified.

⚠ One thing the new guard does **not** cover, offered as information rather than as a finding,
because it is pre-existing and identical in both overloads: `convertFormatToRegex` is only
null/empty-safe, not malformed-safe. On a non-empty `format` with no `"-"` it throws
`ArrayIndexOutOfBoundsException` at `split[1]`; with a short tail it throws
`StringIndexOutOfBoundsException` at `substring(digitLen - 3, digitLen - 1)`; with a non-numeric tail,
`NumberFormatException`. That call is the third statement of both overloads, so a malformed
`PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` sysprop still fails the scan before any guard runs. Not a
regression and not this ticket's to fix.

### Fix 4 — the D0 ordering test. **CORRECT, and it does more than advertised.**

```java
org.mockito.InOrder inOrder = org.mockito.Mockito.inOrder(
        mobileTransferService, billofladingRepository, billofladingPositionRepository);
inOrder.verify(mobileTransferService).handleTruckOffLoadingNoClear(PALLET);
inOrder.verify(billofladingRepository).save(bol);
inOrder.verify(billofladingPositionRepository).save(any());
```

That pins both properties AC-3 needs: D0 before the header write and D0 before the first position
insert. Two bonuses worth recording:

- It stubs `locationRepository.findByIdForUpdate(20L)`, and under `STRICT_STUBS` an unused stub
  fails the test — so this test now also **pins fix 1**: revert the gate to `findById` and the stub
  goes unused and the class goes red. That is a first-touch pin obtained for free, and it is worth
  saying so in the test's javadoc so nobody "tidies" the stub away.
- **It closes most of F13.** Part 2 found that all four `never()` rows in `assertNothingWasWritten()`
  had no positive control anywhere in the class. This test positively verifies three of the four —
  `handleTruckOffLoadingNoClear`, `billofladingRepository.save`, `billofladingPositionRepository.save`.
  **Only `customerorderRepository.save` still has none**, because the fixture uses no child parcels
  and so never reaches D7. Adding one parcel with an order to that fixture closes it completely;
  that is now a small, single-fixture change rather than a new test.

## The finding Part 3 adds

### F16 — MEDIUM: Bug 7's premise is false, so AC-6's stated justification is wrong in the plan *and* in the new javadoc.

The same `RestExceptionHandler` verified above also carries:

```java
@ExceptionHandler(PessimisticLockingFailureException.class)
protected ResponseEntity<ProblemDetail> handlePessimisticLock(PessimisticLockingFailureException ex) {
    …ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, "The record is currently locked by another operation. Please retry.");
    problemDetail.setProperty("retryable", true);
```

Plan §2 Bug 7 says: *"It does not catch `PessimisticLockingFailureException`. Once locks exist, a
lock timeout … **would propagate as a raw 500**."* It would not. An `@Order(0)` unscoped advice
already mapped it to a 409 with an operator-legible, `retryable`-flagged message, before this ticket
was written. `MobileTruckLoadingService`'s new class javadoc repeats the error — *"would escape as a
bare HTTP 500 with no operator-legible message, which is what this converts"* — and so does my own
Part 1 AC-6 write-up, which took the plan's framing at face value.

**What AC-6 actually does** is convert a 409 ProblemDetail into a **200 with an `errors` map**. That
is still defensible and probably right: `TruckLoadingController.scanGate` returns 200 + `errors` for
every `BusinessException`, so that is the shape the handheld is built to render, and a 409
ProblemDetail may not be rendered at all. But it is a *different* change from the one the plan
describes, and it has a cost nobody has weighed: the 409 status and the `retryable: true` property
both disappear, so an API client that keys on either loses its retry signal.

Note the sibling deliberately went the other way. `MobilePalletizeWriteService`'s javadoc records
that `ObjectOptimisticLockingFailureException` is *"NOT caught by `MobilePalletizingService.lockContention`
— **deliberately**, see AC-7"*, i.e. the palletize path chose to let the 409 stand. SBDEV-3418
translates the pessimistic sibling into a 200 instead. Both may be right for their paths, but the
divergence should be a decision, not an accident of a false premise.

**Recommended:** correct Bug 7 in the plan and the class javadoc to say what the pre-fix behaviour
was, and state explicitly that AC-6 is chosen to match the handheld's `errors` contract — and
confirm with whoever owns the handheld that 200+`errors` is preferred over 409+`retryable`. This is a
documentation and decision-record fix; I am not proposing a code change.

## Status after the fixes

| # | was | now |
|---|---|---|
| F1 | Blocker | **CLOSED** by fix 2 |
| F2 | High | **CLOSED** by fix 1 — and re-rated: the pre-fix consequence was a spurious 409, not a 500 |
| F3 | Medium | open — `LocationRepository.findIdByName`'s javadoc still names a trigger ("two operators scan the same gate") that cannot occur |
| F4 | Medium | largely superseded — fix 4 now pins the gate finder via STRICT_STUBS. A full `MobilePalletizeFirstTouchInvariantUnitTest`-shaped rail (`verifyNoMoreInteractions`, the `ignoreLock=false` exact-argument row) is still the durable version |
| F5 | Medium | partly closed — AC-3 is pinned by fix 4. The orphan/duplicate guard-ordering tests and the `rollbackFor` checked-exception test are still missing |
| F6 | Medium | **doc half CLOSED** by fix 3; the behavioural divergence stands, now correctly described |
| F7, F8, F9, F10, F11, F12, F14, F15 | Low/Info | open |
| F13 | Medium | ¾ closed by fix 4; only `customerorderRepository.save` lacks a positive control |
| **F16** | **Medium** | **new** — Bug 7's "raw 500" premise is false in the plan, in the new javadoc, and in my own Part 1 AC-6 note |

## A fifth fix landed that was not in the list — and it is the important one

The handover named four fixes. The working tree contains **five**:
`MobileTruckLoadingWriteServiceUnitTest` went from 7 tests to 9, and the extra one is

```
@DisplayName("first-touch rail: no locked row class is materialised by a plain finder first")
void scanGate_shouldNeverMaterialiseALockedRowBeforeLockingIt()
```

This is F4, and it is well built. It drives the full happy path (pallet + one parcel + one order),
then asserts the negative for **every** locked row class rather than for the one line that broke:

```java
verify(locationRepository, never()).findById(any());
verify(locationRepository, never()).findByName(anyString());
verify(billofladingRepository, never()).findByName(anyString());
verify(unitloadRepository, never()).findByLabelid(anyString());
verify(unitloadRepository, never()).findByCarrierunitloadId(any());
verify(customerorderRepository, never()).getByParcelIdList(any());
```

Three things make it a real rail rather than a box-tick, and the third is the one I would not have
thought of:

1. Its javadoc states the rule instead of the instance — *"A pin on that one line would close one
   instance and leave the rule unguarded"* — and names both blind spots honestly: happy path only,
   and blind to a future finder it does not name, with bytecode/ArchUnit given as the complete check.
2. It diagnoses why the original defect survived review: *"it throws only under contention, so every
   test was green either way; and the comment directly above it asserted the opposite, so review read
   the comment rather than the code."* That is the correct post-mortem.
3. **The `lenient()` stub on `locationRepository.findById(20L)` is load-bearing and the reasoning is
   subtle.** Without it, the F2 mutant dies at `EntityNotFoundException: Location not found with id: 20`
   — red, but naming a missing stub rather than the broken rule. With it, the mutant runs to
   completion and the `never()` is what fires. The comment says this was *"measured both ways"*,
   which is the attributable-kill standard this repo asks for, applied without being asked.

**Consequences for my earlier findings:**

- **F4 is CLOSED.** One gap against the precedent remains, and it is cheap: the precedent pairs its
  `never()` rows with `verifyNoMoreInteractions`, which it calls *"the third gap: the `never()` rows
  name specific methods and cannot see a **newly added** non-locking finder."* This rail names its
  finders and acknowledges that blind spot rather than closing it. Adding
  `verifyNoMoreInteractions(locationRepository)` — scoped to the one class where the defect actually
  lived, not to all six repositories — would close it for the row that matters, at no fixture cost.
- **F13 is CLOSED in substance.** Part 2 found all four `never()` rows in `assertNothingWasWritten()`
  lacked any positive control. The D0 test now positively verifies three
  (`handleTruckOffLoadingNoClear`, `billofladingRepository.save`, `billofladingPositionRepository.save`),
  and this rail's fixture reaches D7 with an order at state `PACKED` — below `LOADED_TO_TRUCK` — so
  it **executes** `customerorderRepository.save` as well. The fourth is exercised rather than
  explicitly verified, which is enough to defeat the vacuity the finding was about.
- It also **pins fix 1 for free**: the rail and the D0 test both stub
  `locationRepository.findByIdForUpdate(20L)`, and under `STRICT_STUBS` an unused stub fails the
  class. Revert the gate to `findById` and two tests go red, one of them naming the rule. Worth a
  line in the D0 test's javadoc so the stub is not "tidied" away later.

## Re-measurement of the fixed state — clean, isolated worktree

Taken in `SBDEV-3418-verify` with the working-tree patch applied (5 files, 216 insertions,
17 deletions — diffstat identical to the source tree), `clean` on every invocation, nothing else
touching that worktree:

| lane | result |
|---|---|
| `mvn -B -ntp clean test -Dtest='MobileTruckLoadingWriteServiceUnitTest,MobileTruckLoadingServiceTest,MobileTruckLoadingServiceUnitTest,TestClassTransactionManagerArchTest,OptionalSafetyArchTest'` | **`Tests run: 46, Failures: 0, Errors: 0` — BUILD SUCCESS** |

Per class: `TestClassTransactionManagerArchTest` **5/5 green** (was 5/1 — **F1 confirmed CLOSED**),
`MobileTruckLoadingWriteServiceUnitTest` **9/9**, `MobileTruckLoadingServiceTest` **20/20**,
`MobileTruckLoadingServiceUnitTest` **11/11**, `OptionalSafetyArchTest` **1/1**. No `cannot find
symbol` anywhere in the log.

| lane | result |
|---|---|
| `mvn -B -ntp clean verify -Dit.test=MobileTruckLoadingRollbackIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | **`Tests run: 1, Failures: 0, Errors: 0`, 48.3 s — BUILD SUCCESS** |

That IT matters more after fix 1 than before it: the gate is now resolved with
`findByIdForUpdate`, so on H2 the test exercises a real `SELECT … FOR UPDATE` on the gate row that
the pre-fix code did not issue. It passes. (`[ERROR] An error has occured` in the log is an
application log line, present in the green `e64bdb5c` run too, not a test failure.)

**Both lanes of the fixed state are green in an isolated clean build.**

---

# FINAL STATUS

**`e64bdb5c` as committed: FAIL** (F1 blocker, F2 high) — that verdict stands as the record of what
was wrong.

**The working tree with the five fixes applied: no blocking finding remains.** Both lanes green,
46 unit tests and the rollback IT, measured clean and isolated.

| # | severity | status |
|---|---|---|
| F1 arch rail red | Blocker | **CLOSED** — verified 5/5 green |
| F2 gate first-touch violation | High | **CLOSED** — verified; consequence re-rated from "raw 500" to "spurious 409" |
| F4 no first-touch rail | Medium | **CLOSED** by the fifth, unlisted fix; `verifyNoMoreInteractions(locationRepository)` would close its stated blind spot |
| F6 no-clear doc contradiction | Medium | **CLOSED** (doc half); behavioural divergence remains, now correctly described |
| F13 `never()` rows without a positive control | Medium | **CLOSED** in substance |
| F5 AC-1 second half | Medium | **partly closed** — AC-3 pinned; orphan/duplicate guard-ordering tests and the `rollbackFor` checked-exception test still missing |
| **F16 Bug 7's "raw 500" premise is false** | **Medium** | **open** — wrong in the plan, in `MobileTruckLoadingService`'s new javadoc, and in my own Part 1 note. Documentation/decision-record fix, no code change proposed |
| F3 `findIdByName` javadoc names an impossible trigger | Medium | open |
| F7 §4.3 residuals 4/5/6 not in the javadoc | Low | open |
| F8 stale `MobileTruckLoadingService:310` cross-reference | Low | open |
| F9 archunit prune not committed | Low | open — the lead has confirmed it is intended and is keeping it |
| F10 `bolGateName` guard is constant-true | Low | open |
| F11 PHASE C guard message-order change | Low | open |
| F12 "seven relocated" is 6 + 1 new + 1 replaced | Info | open |
| F14 §2 ↔ §3.2 projection-count mismatch | Low (plan) | open |
| F15 concurrent-Maven process hazard | Low (process) | see below |

**Still to do before this is mergeable**, in my order of value: F16 (the false premise, because it
is now asserted in three places and a reader will build on it), then F5's two missing tests, then
the Low documentation items. None is a blocker.

**Housekeeping:** `SBDEV-3418-verify` is my worktree and is still on disk with the fix patch applied
— remove it with `git worktree remove .claude/worktrees/wms2-api/SBDEV-3418-verify`. Note also that
a sibling lane's wait loop uses `pgrep -f "SBDEV-3418"`, which substring-matches
`SBDEV-3418-verify` and `SBDEV-3418-run`; it will block on builds in those worktrees even though
they cannot collide with the shared one.
