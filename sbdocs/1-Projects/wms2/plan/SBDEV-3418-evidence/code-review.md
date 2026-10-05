# SBDEV-3418 — independent code review

- **Reviewed:** `bugfix/SBDEV-3418-truck-loading-transaction-boundary` @ `e64bdb5c`, one commit off `origin/develop` @ `3214a9c3`
- **Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3418`
- **Diff:** `git diff origin/develop...HEAD` — 12 files, +1396/−273
- **Reviewer:** independent lane, not the author
- **Date:** 2026-09-22

**Verdict: CHANGES REQUESTED.** The design is sound and the five-phase split is the right shape —
it matches `MobilePalletizeWriteService` verbatim, including the documented table order, the
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class,
FacadeException.class})` signature, and the outer/inner split that keeps the lock translation and
the OMS notification outside the boundary. I am not disputing the plan's design. Two High findings
block: **the branch does not build green**, and **the one first-touch violation the ticket singles
out as the hottest shared row is still there, underneath a javadoc that asserts it is not.**

| # | Sev | Summary |
|---|-----|---------|
| H1 | High | `TestClassTransactionManagerArchTest` is RED — `MobileTruckLoadingRollbackIT` is not in `EXEMPT_NON_TRANSACTIONAL` |
| H2 | High | PHASE D materialises the gate `Location` before `transferUnitLoadToLocation` locks it — first-touch violation, and the adjacent comment claims the opposite |
| M1 | Medium | `handleTruckOffLoadingNoClear`'s null guard is unreachable; the diagnostic it documents can never fire |
| M2 | Medium | AC-2, AC-3 and AC-7 have no test at all; AC-3 is the invariant that makes PHASE D0's placement safe |
| L1 | Low | `outcome.bol().getOutboundlocationId() != null` is always true; `setBolGateName` now fires on a path where it did not |
| L2 | Low | `sortedOrderIds.contains(...)` inside the row loop is O(n²) |
| L3 | Low | `MobileTruckLoadingRollbackIT.@AfterEach` swallows every cleanup failure and can NPE if seeding died early |
| L4 | Low | Guard order changed: duplicate-order now rejects before orphan-parcel |
| L5 | Low | Dead whitespace run and five now-unused `@Mock` fields left behind by the constructor shrink |
| L6 | Low | `assertNothingWasWritten()` is vacuous in A1; IT javadoc cites the pre-fix method and a stale line number |

---

## H1 (High) — the branch does not build green

`MobileTruckLoadingRollbackIT` declares

```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.NOT_SUPPORTED)
class MobileTruckLoadingRollbackIT extends BaseIntegrationTest {
```

`TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared` pins the exact set
of classes allowed to do that, and the commit did not add this one — `git diff --name-only
origin/develop...HEAD | grep ArchTest` returns 0.

Measured in this worktree (surefire run already in flight when I arrived, pid 26195, log at
`/private/tmp/claude-503/-Users-np1076-dev-spk-owl/fa3a1397-756c-4c22-a3bc-ca1190e2307b/scratchpad/unit.log`;
I did not start a second Maven, per the one-build-per-worktree rule):

```
[ERROR] Tests run: 5, Failures: 1, Errors: 0, Skipped: 0 -- in TestClassTransactionManagerArchTest
[ERROR] TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared -- FAILURE!
[NOT_SUPPORTED and NEVER are exempt from the name-a-manager rule ... add or remove the class in
 EXEMPT_NON_TRANSACTIONAL in the same commit, and say why.]
 ... but was: [..., "net.aim_ai.wms.integration.service.mobile.MobileTruckLoadingRollbackIT", ...]
[INFO] BUILD FAILURE
```

Attribution is unambiguous: the only delta between `expected` and `but was` is this commit's new IT
class. The three truck-loading test classes themselves are green in that same run (7/7, 20/20,
11/11) — this is the rail, working as designed, and it was not satisfied.

**Fix:** add `"net.aim_ai.wms.integration.service.mobile.MobileTruckLoadingRollbackIT"` to
`EXEMPT_NON_TRANSACTIONAL` at `src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java:164`,
with the "and say why" line the rail's own message demands. The reason is already written in the IT's
javadoc and is a good one — it just has to be recorded where the rail reads it.

---

## H2 (High) — the gate `Location` first-touch violation is still open, and its javadoc denies it

`MobileTruckLoadingWriteService` PHASE D:

```java
// The gate Location's FIRST entity touch happens inside transferUnitLoadToLocation, which
// takes its own findByIdForUpdate on it because ignoreLock=false. Resolving it as an entity
// anywhere above would turn that acquisition into an upgrade ...
final Long resolvedGateId = gateId;
Location gate = locationRepository.findById(resolvedGateId)
        .orElseThrow(() -> new EntityNotFoundException("Location", resolvedGateId));
unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false, ...);
```

The comment's first sentence is false about the two lines directly beneath it. `findById` **is** an
entity touch on the gate row and it happens *before* the locking finder. `UnitloadBusinessService.transferUnitLoadToLocation`:

```java
if (!ignoreLock) {
    final Long destinationLocationId = destinationLocation.getId();
    destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
        .orElseThrow(() -> new EntityNotFoundException("Location", destinationLocationId));
    entityManager.refresh(destinationLocation);
}
```

and `LocationRepository:112-115` is `@Lock(LockModeType.PESSIMISTIC_WRITE)`. `Location` extends
`AbstractBaseEntity`, which carries `@Version` (`AbstractBaseEntity.java:34`), so the entity is
versioned and the upgrade does get version-checked — this is exactly the SBDEV-3244 shape the class
javadoc spends a paragraph forbidding.

Three things make this worse than a stale comment:

1. **The failure mode is not translated.** A lock upgrade throws `StaleObjectStateException` →
   `ObjectOptimisticLockingFailureException`, which is **not** a subclass of
   `PessimisticLockingFailureException`. `MobileTruckLoadingService.lockContention` therefore does
   not catch it, `TruckLoadingController.scanGate` catches only `BusinessException` /
   `FacadeException` (`TruckLoadingController.java:121-124`), and the operator gets a bare HTTP 500.
   The whole point of Bug 7 / AC-6 was to stop that class of 500.
2. **The comment forbids the fix.** "Do NOT add a `locationRepository.findByIdForUpdate(gateId)`
   here 'for symmetry'" is the opposite of what is needed. Acquiring `PESSIMISTIC_WRITE` here makes
   the inner `findByIdForUpdate` a same-level re-lock, which Hibernate treats as a no-op (the
   upgrade path only runs when the requested mode exceeds the held mode) — so locking here is the
   cheap correct fix, not the symmetric-but-useless one the comment describes.
3. **It is the row the ticket itself calls hottest.** `LocationRepository.findIdByName`'s new
   javadoc says "The gate is the hottest shared row on the truck-loading path, so the upgrade would
   surface as `StaleObjectStateException` exactly when two operators scan the same gate." That is a
   correct description of the bug the code still has.

**Not a regression.** Pre-fix `scanGate` did `locationRepository.findByName(...)` and passed the
entity in, which is the same violation, and there was no boundary for it to bite inside. So this is
"the fix did not land", not "the fix broke something" — but AC-6 and Bug 6 are why the ticket exists,
and the misleading comment will cost the next reader real time.

**Suggested fix:** replace `findById` with `findByIdForUpdate(resolvedGateId)` in PHASE D and invert
the comment, or restructure so the gate entity is never resolved in this method. If the author
believes the upgrade is benign here, that belief needs to be written down with its evidence — it
currently sits as the opposite claim.

*Derivation / blind spot:* I traced every `Location`-typed read reachable from `scanGate` by reading
the PHASE A–D body and `transferUnitLoadToLocation` end to end. I did **not** trace `processTransfer`'s
recursion, so there may be further `Location` touches below; that would add to this finding, not
subtract. I did not reproduce the exception — by construction it only fires under contention, which
is the property that makes it invisible to the test suite.

---

## M1 (Medium) — the new null guard is dead code, and the diagnostic it promises never fires

`MobileMoveUnitloadService.handleTruckOffLoadingNoClear`:

```java
if (pattern == null && convertedPrintingPattern == null) {
    // SBDEV-3418: both sysprops unset. The original overload passes null straight into
    // String.matches() and dies with NullPointerException ... Nothing to purge here.
    LOG.warn("Neither {} nor {} is configured; skipping truck-off-loading purge for {}", ...);
    return;
}
```

`convertedPrintingPattern` comes from `StringConverter.convertFormatToRegex`, which **never returns
null**:

```java
public static String convertFormatToRegex(String format) {
    if (format == null || format.isEmpty()) {
        return "";
    }
    ...
    return alpha + "\\d{" + digit + "}";
}
```

So `convertedPrintingPattern == null` is unsatisfiable, the branch is unreachable, and the both-
unset case the comment describes actually takes the fall-through path:
`(null != null && ...) || ("" != null && label.matches(""))` → `false` → **silent skip with no
warning**. The comment's whole justification — "reads as a code defect rather than as missing
configuration" — describes a diagnostic that cannot be emitted.

There is a second, undocumented divergence from the original that the comment does not mention: with
`STRING_PATTERN_OUTBOUND_PALLET` unset but the printing pattern set, the original
`handleTruckOffLoading` throws NPE at `unitLoadLabel.matches(pattern)`, while the new one falls
through to the printing pattern and **purges**. That is probably the better behaviour, but it is a
behaviour change on a destructive DELETE path, and the javadoc says the only difference from the
original is `clearAutomatically`.

The consequence of a silent skip matters on this path specifically: PHASE D0 is what removes the
pallet's positions from its *previous* BOL. Skip it and PHASE D4/D5 insert a second position tree
while the first survives, so the pallet is on two BOLs — the exact state D0 exists to prevent.

**Fix:** guard on emptiness, not null — `boolean noPattern = (pattern == null || pattern.isEmpty())
&& convertedPrintingPattern.isEmpty();` — and either restore the NPE-equivalent hard failure or
state in the javadoc that a misconfigured string pattern now degrades to a purge attempt via the
printing pattern alone.

*Related:* `MobileTruckLoadingRollbackIT`'s fixture comment at the sysprop seeding still says
"scanGate dies at handleTruckOffLoading with NullPointerException ... That NPE fires at :247" —
`handleTruckOffLoading` is no longer on this path and `:247` is a pre-fix line number. Fold the
correction in (L6).

---

## M2 (Medium) — AC-2, AC-3 and AC-7 have no test

The plan (§6.2) defines seven acceptance criteria. The diff adds exactly three test files
(`MobileTruckLoadingRollbackIT`, `MobileTruckLoadingWriteServiceUnitTest`, the rewritten
`MobileTruckLoadingServiceTest`), and `find src/test -iname '*TruckLoading*'` shows no other new
class. Mapping:

| AC | Covered? | By what |
|----|----------|---------|
| AC-1 atomicity | yes | `MobileTruckLoadingRollbackIT`, four soft witnesses with non-vacuity controls — good work |
| AC-2 lock order matches the canonical table order | **no** | no `pg_locks` probe; `ClosebolLockOrderProbeIT` / `PalletizeLockOrderProbeIT` exist as templates and neither was cloned |
| AC-3 D0 precedes every write / no write pending at D0 | **no** | see below |
| AC-4 measure Bug 4a on develop | n/a to the diff | a measurement, not code |
| AC-5 OMS notification outside the boundary | yes | `scanGate_shouldNotifyOmsAfterTheBoundaryAndSwallowItsFailure` |
| AC-6 contention is operator-legible | partly | `scanGate_shouldTranslateLockContentionIntoAnOperatorLegibleRejection` asserts at the service; the plan says "must surface through the controller as an `errors` entry". I checked `TruckLoadingController:122` uses `e.getMessage()`, so it does work — but nothing pins it |
| AC-7 concurrency, grading B1 specifically | **no** | no `MobileTruckLoadingRaceIT`; `MobilePalletizeRaceIT` named as the template was not cloned |

AC-3 is the one I would insist on. The plan is explicit that the assertion must be the *invariant*
— "no write is pending at D0" — mutation-checked by moving the call after the writes. What exists
instead is `assertNothingWasWritten()`, which asserts `verify(mobileTransferService,
never()).handleTruckOffLoadingNoClear(anyString())` on the **rejection** paths. That is the opposite
direction: it grades that D0 does not run when a guard fires, and says nothing about D0's position
relative to the writes on the happy path. A mutant that moves
`mobileTransferService.handleTruckOffLoadingNoClear(dto.getPalletName())` to the bottom of PHASE D
— which would delete the tree this scan just built, per the code's own D0 comment — leaves all
seven unit tests and the rollback IT green.

AC-7 is the AC the plan calls "the one that grades B1's load-bearing role". B1's javadoc makes a
strong claim — that the BOL lock is what stops two concurrent `createEntity` count-reads minting the
same position number — and nothing in the diff tests it.

This is a scope call, not a correctness defect: if AC-2/3/7 are being deferred, say so on the ticket
with a reason. Right now the plan asserts them and the branch silently does not carry them.

---

## Things I checked and found CORRECT

Recording these so they are not re-litigated.

- **Lock order matches the sibling verbatim.** `MobileTruckLoadingWriteService`'s documented order
  (`Billoflading → Unitload (pallet, then parcels asc by PARCEL id) → Stockunit → Customerorder asc
  → CustomerorderPosition`) is character-identical to the table order in
  `MobilePalletizeWriteService.java:104-107`. No contradiction between the two classes.
- **The ordering is a property of the query, not the call site.** `findIdsByCarrierunitloadIdOrderById`
  carries `ORDER BY u.id` in the JPQL; `findParcelOrderIdsByParcelIdIn` carries `ORDER BY parcel.id,
  co.id`. Both survive a call-site edit, which is what the javadoc claims.
- **First-touch is genuinely respected everywhere except the gate.** `existsByLabelid` (boolean),
  `findIdByName` ×2 (`Long`), `findIdsByCarrierunitloadIdOrderById` (`List<Long>`),
  `findParcelOrderIdsByParcelIdIn` (interface projection over a native query) all create no
  `EntityEntry`. `User` is touched as an entity but nothing locks `mywms_user` — the comment says so
  and it is true.
- **The duplicate-order detection via `Map.put`'s return value is sound.** The native query joins
  `co.parcel_id = parcel.id` where `parcel.id` is the PK, so it emits exactly one row per
  `customerorder`. Two rows for one parcel ⟺ two orders on that parcel, which is precisely the
  condition. Deliberately omitting `DISTINCT` is correct and the javadoc explains why.
- **`findParcelOrderIdsByParcelIdIn` is injection-safe.** `:parcelIds` is a bound `@Param`
  collection; nothing is concatenated. The `INNER JOIN` is the right semantics — a parcel with no
  order produces no row, which is what feeds the orphan guard.
- **`rollbackFor` covers everything reachable.** The only checked exceptions the method can throw
  are `BusinessException` and `FacadeException` (both listed). `EntityNotFoundException` extends
  `RuntimeException` (`EntityNotFoundException.java:7`) and the bare `RuntimeException` from the
  switch `default:` arm both get Spring's default rollback. Nothing inside the boundary catches
  anything, so nothing can leave it rollback-only-but-committing.
- **The `PessimisticLockingFailureException` catch is in the right place.** It is on the caller side
  of the proxy, so the rollback has already completed when it runs — catching it inside would
  produce `UnexpectedRollbackException`, exactly as the javadoc says. `CannotAcquireLockException`
  (40P01) is a subclass, so deadlock aborts are covered.
- **`BusinessException`'s one-arg constructor does not eat the message here.** It routes through
  `resolveMessage(locale, "placeholder", message)`; the passing assertion
  `.hasMessageContaining("PALLET001").hasMessageContaining("scan again")` in the green run confirms
  the operator text survives, and `TruckLoadingController:122` renders `e.getMessage()`, not
  `getKey()`.
- **The `deleteBolPositionByIdNoClear` / `...CarrierIdsNoClear` sibling-rather-than-edit decision is
  right, and the SBDEV-3452 evidence for it checks out.** `MobileMoveUnitloadService.scanDestination`
  does reach `BillofladingPosition` entities before its own `handleTruckOffLoading` call, so the
  original's `clearAutomatically` is load-bearing on that path.
- **`flushAutomatically = true` is harmless at D0.** PHASE C is predicate-only and every entity
  locked in PHASE B is clean, so the flush is a no-op — the javadoc's reasoning holds.
- **The relocation claim is accurate.** Six of the seven deleted `scanGate` tests have a direct
  counterpart (A1↔null pallet, A2↔pallet-not-found, A3↔null BOL, A5↔null gate, A6↔gate-not-found,
  C1↔different gate); A4 is new; the happy path is the one not relocated, as stated. A2 and A6 add
  real first-touch assertions (`verify(unitloadRepository, never()).findByLabelid(...)`,
  `verify(locationRepository, never()).findByName(...)`) the originals could not make.
- **`MobileTruckLoadingRollbackIT`'s fixture is sound and the `@MockitoBean` choice is correct.**
  `ItemdataService` carries no `@Transactional`, so the SBDEV-3398 §10.5 spy landmine does not
  apply. The injection site is genuinely below the writes both before and after the fix —
  `itemdataService.getById(...)` is an eagerly-evaluated argument to `LOG.warn`, reached only when
  `orderpositionId` is null, which the position-less order guarantees. The four non-vacuity controls
  and the message-identity assertion on the thrown exception are exactly right, and recording that
  the predicted mutation kill is *unreachable* (the pessimistic finders make the boundary structural)
  rather than quietly deleting the prediction is the honest thing to do.
- **`@AfterEach` does run and its FK ordering is correct** given `NOT_SUPPORTED` commits everything;
  and the integration profile is `ddl-auto=create-drop` (`src/test/resources/application-integration.properties:27`),
  so leaked rows die with the context rather than poisoning later Maven runs. See L3 for what is
  still wrong with it.
- **No dead fields in the shrunk outer service.** All eight surviving constructor args are still
  referenced. Wildcard imports mean no unused-import fallout.

---

## Low findings

**L1 — the new `setBolGateName` condition can never be false, and the behaviour did change.**

```java
if (outcome.bol().getOutboundlocationId() != null) {
    truckLoadingMobileDTO.setBolGateName(outcome.gateName());
}
```

By the end of PHASE D, `bol.getOutboundlocationId()` is non-null on both arms — either PHASE C set
`pendingOutboundLocationId = gateId` and D applied it, or it was already equal to `gateId` (the
differing-gate case throws). So the guard is always true. Pre-fix, `setBolGateName` was called
**only** on the assign-gate branch; now it is called on the already-assigned branch too. The value
written is provably the same (`gateId` equals the BOL's outbound location on the surviving path), so
I could not construct an operator-visible difference — but the conditional reads as if it guards
something. Either drop the `if` and say the DTO is always populated, or state why it is kept.

**L2 — `sortedOrderIds.contains(...)` in the row loop.**

```java
for (ParcelOrderIdView row : customerorderRepository.findParcelOrderIdsByParcelIdIn(parcelIds)) {
    ...
    if (!sortedOrderIds.contains(row.getOrderId())) {
        sortedOrderIds.add(row.getOrderId());
    }
}
sortedOrderIds.sort(Long::compareTo);
```

O(n²) on a list. Parcels per pallet is small, so this is not a performance defect — but a
`LinkedHashSet` then `new ArrayList<>(set)` is the same number of lines and removes the question.
Worth changing only because this loop sits inside a transaction holding row locks.

**L3 — the IT's `@AfterEach` is quieter than it should be, and has one unguarded call.**

Every step goes through `deleteQuietly`, which downgrades any `RuntimeException` to `log.warn`. The
class therefore cannot fail on a cleanup it did not perform, and nothing asserts the schema is clean
afterwards. `ddl-auto=create-drop` bounds the damage to other classes sharing this Spring context
(the `@MockitoBean` pair gives it its own cache key, so the blast radius is small) — but the
*first* statement is not wrapped:

```java
billofladingPositionRepository.findByBillofladingId(bolId)
        .forEach(p -> deleteByIdQuietly(...));
```

If `seed()` throws before `bolId = billofladingRepository.save(newBol()).getId()` — which the
javadoc's own list of fixture landmines shows is a live possibility — `bolId` is null and this call
runs with a null argument, masking the real seeding failure with a second one. Wrap it, or null-guard
it the way every line below it is.

**L4 — guard order changed between the two hoisted rejections.** Pre-fix, the per-parcel loop raised
`unexpectedUnitLoadDoesNotHaveOrder` for parcel *n* before ever reaching parcel *n+1*'s duplicate
check. PHASE C now checks `duplicateParcelIds` globally first, then orphans. For a pallet that has
both an orphan parcel and a duplicate-order parcel, the operator now sees "Too many orders with the
same parcel found" where they used to see the orphan message. Almost certainly fine — flagging it
because the A3 test explicitly treats message order as a contract elsewhere in this same change, and
this one moved without a note.

**L5 — leftovers from the constructor shrink.** `MobileTruckLoadingService` now has a run of ~8
consecutive blank lines in the field block and again in the constructor where the removed
declarations were (visible in the diff as ` ` context lines between the `-` lines).
`MobileTruckLoadingServiceTest` still declares `@Mock` fields for `customerorderPositionRepository`,
`billofladingPositionService`, `stockunitRepository`, `unitloadBusinessService`, `userRepository`,
`itemdataRepository`, `itemdataService` and `mobileTransferService`, none of which are passed to the
constructor any more. They are unstubbed so `STRICT_STUBS` does not complain, but they will mislead
the next person into thinking this class still touches those collaborators.

**L6 — two documentation defects in the tests.**
(a) `assertNothingWasWritten()` in `scanGate_shouldReject_whenPalletNameIsNull` is vacuous — the null
check throws on the first line, so no mock is ever reached and the four `never()` verifications pass
without exercising anything. Harmless, but the class javadoc calls the `never()` verifications "what
grades it", which over-sells A1.
(b) `MobileTruckLoadingRollbackIT`'s sysprop comment refers to `handleTruckOffLoading` and line
`:247`; the path now calls `handleTruckOffLoadingNoClear` and the line number is pre-fix.

---

## On the design

I do not think the plan's design is wrong. The phase split, the canonical order, the scalar-resolution
rule, keeping the boundary off the outer class, and the explicit enumeration of the three residual
cycles rather than a safety claim are all right, and the javadocs are unusually good at saying *why*
rather than *what*. H2 is a failure to apply the design's own rule at one site; M1 is a guard that
does not do what its comment says; M2 is missing coverage. None of them argues for a different shape.

One design-adjacent note: the class javadoc's third residual says "`Location` is unranked. PHASE D
fixes the gate row's first-touch violation; it does not order Location against anything." Per H2, the
first half of that sentence is not true today. Once H2 is fixed the sentence becomes accurate, which
is a reason to fix H2 rather than to soften the sentence.

## What I did not do

- Did not run Maven — a `mvn test` on these exact classes was already running in this worktree when
  I started (pid 26195); starting a second would have produced false reds. I read its log instead.
- Did not run `MobileTruckLoadingRollbackIT`. It is in the failsafe lane (`**/*IT.java`, pom line
  775) and there are no `target/failsafe-reports` in this worktree, so **I have no evidence this IT
  has ever been executed green.** That should be established before merge, independently of the
  findings above.
- Did not exercise the new native projection query against H2. `findParcelOrderIdsByParcelIdIn` is
  the only new native query with an interface projection; alias-case handling between H2 and the
  `ParcelOrderIdView` getters is the kind of thing that only shows up at runtime. The rollback IT
  reaches it, so running that IT settles this too.
