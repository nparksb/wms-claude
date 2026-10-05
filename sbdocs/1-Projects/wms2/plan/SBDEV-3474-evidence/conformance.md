# SBDEV-3474 — conformance check (verifier lane)

Commit under review: `3b8b19e1b9ae52c947feca89744a2a79b3c6c218`, worktree
`/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3474`. Read-only pass: no edits, no
git state changes, no Maven invoked by this lane. A `mvn verify` was mid-run in this worktree
throughout the check (surefire-reports climbing from 2596 → 3278+ files); this report does not
depend on its outcome except where noted.

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|---|---|---|
| AC1 | scanGate rejects a non-outbound label with `noValidString`, no row locks, proved by a test | **MET** (with a caveat on the proof instrument — see below) | `OutboundPalletLabelGuard.requireOutboundPalletLabel` (main:57-84) throws before any repository call; `MobileTruckLoadingService.scanGate` (mobile/MobileTruckLoadingService.java, calls guard before the `try` around `truckLoadingWriteService.scanGate`); test `MobileTruckLoadingServiceTest.scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService` asserts `noValidString` + `verifyNoInteractions(truckLoadingWriteService, manageOrderService)` |
| AC2 | Check runs before B1, adds no entity touch; first-touch invariant tests still pass | **MET** | `MobileTruckLoadingService` is not `@Transactional` (class has no such annotation; confirmed by grep); `OutboundPalletLabelGuard` only calls `SyspropService.getSysvalue` and `StringConverter` statics — no `Repository`/`EntityManager`/model-persistence import anywhere in the new class. `MobileTruckLoadingWriteService.scanGate` remains the sole `@Transactional(value="tenantTransactionManager", ...)` entry point (`:245-247`), untouched by this diff except its javadoc |
| AC3 | One test per accept pattern (regex sysprop, printing-pattern sysprop), matching checkPallet's coverage | **MET** | `OutboundPalletLabelGuardUnitTest`: `acceptsALabelMatchingTheRegexPattern`, `acceptsALabelMatchingThePrintingPattern`, plus paired "only-that-pattern-configured" accept/reject tests for each; pre-existing `MobileTruckLoadingServiceUnitTest.CheckPallet` tests (`shouldThrowExceptionWhenPalletDoesNotMatchPattern`, etc.) still pass unmodified through the real guard wired in `@BeforeEach buildService()` |
| AC4 | Mutation check: removing the guard call makes AC1's test fail, naming the missing rejection | **PARTIAL — cannot independently confirm via PIT; confirmed by hand-trace instead** | See "PIT evidence" section below. `target/pit-reports/mutations.xml` does not exist in this worktree and the running `mvn verify` cannot regenerate it (pom.xml:536-537: pitest-maven is "Not bound to any lifecycle phase: it runs only when invoked explicitly"). I traced the removal by hand (not by executing a mutant) — see reasoning below — which supports the claim but is not the same evidence class as an actual PIT run. |

## AC1's proof instrument — is "never called" equivalent to "no lock, no transaction"?

Verified by reading the full body of `MobileTruckLoadingService.scanGate` (mobile/MobileTruckLoadingService.java)
from its first line to the `try { truckLoadingWriteService.scanGate(...) }` block:

```
public TruckLoadingMobileDto scanGate(...) throws FacadeException, BusinessException {
    LOG.debug(...);
    long start = ...;
    outboundPalletLabelGuard.requireOutboundPalletLabel(truckLoadingMobileDTO.getPalletName());
    MobileTruckLoadingWriteService.TruckLoadOutcome outcome;
    try {
        outcome = truckLoadingWriteService.scanGate(truckLoadingMobileDTO);
    } catch (PessimisticLockingFailureException e) { ... }
    ...
}
```

- There is **no repository call, no `EntityManager` access, and no annotation** on this method or
  its class between entry and the guard call, and none between the guard call and the write-service
  call either — the only statements are `LOG.debug` and a `System.currentTimeMillis()` read.
- `MobileTruckLoadingService` carries no `@Transactional` anywhere in the file (confirmed by
  `grep -n "@Transactional"` — zero hits). `MobileTruckLoadingWriteService.scanGate` is the only
  `@Transactional(value = "tenantTransactionManager", ...)` boundary on this call path
  (MobileTruckLoadingWriteService.java:245-247).
- Therefore in this specific codebase, for this specific call path, "the write service was never
  invoked" **is** equivalent to "no transaction was opened and no row was locked" — there is no
  intervening transactional or persistence-touching code the mock could be hiding. This is a
  narrower claim than "verifyNoInteractions always proves no lock" in general (it would not hold if
  someone later inserted a repository call between the guard and the try-block), but for the diff as
  it stands the equivalence holds and is not a leap.
- The regression test additionally uses `verifyNoInteractions(truckLoadingWriteService,
  manageOrderService)`, not just an assertion on the exception type, which is the correct assertion
  for "was the transactional collaborator ever touched."

**Verdict: MET.** The unit-test proof is sound for this code path. A DB-level "no FOR UPDATE" IT
would be strictly stronger (it would also catch a future regression that adds a repository call
between the guard and the write-service call without touching this reasoning), but the architect's
own recommendation (§5) explicitly accepted the unit-test form as sufficient here, for the same
reason worked out above ("the write service is the only component that takes locks... so 'never
reached' is the lock-free proof"). The diff matches that recommendation exactly.

## AC4 — the named-failure mutation test

`MobileTruckLoadingServiceTest.scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService`:

```java
lenient().when(truckLoadingWriteService.scanGate(dto)).thenThrow(new AssertionError(
        "SBDEV-3474: the write service was reached for non-outbound label IN-000002, "
                + "so its row locks would have been taken"));

assertThatThrownBy(() -> mobileTruckLoadingService.scanGate(dto))
        .isInstanceOf(BusinessException.class)
        .extracting(thrown -> ((BusinessException) thrown).getKey())
        .isEqualTo("noValidString");

verifyNoInteractions(truckLoadingWriteService, manageOrderService);
```

Hand-traced what happens if the guard call in `scanGate` is deleted (the mutation the ticket asks
about): `truckLoadingMobileDTO.getPalletName()` ("IN-000002") flows straight to
`truckLoadingWriteService.scanGate(dto)`, which is stubbed to throw the named `AssertionError`. That
propagates out of `mobileTruckLoadingService.scanGate(dto)` un-wrapped (it is a `RuntimeException`,
not caught by the method). `assertThatThrownBy(...).isInstanceOf(BusinessException.class)` then
fails with an AssertJ message of the form "Expecting actual throwable to be an instance of
[BusinessException] but was [AssertionError]" whose cause/message includes the named string
"SBDEV-3474: the write service was reached for non-outbound label IN-000002...". This does name the
missing rejection, satisfying AC4's letter. The `lenient()` marker is required only because
Mockito's `STRICT_STUBS` would otherwise fail the *passing* run (guard present, stub never invoked)
on `UnnecessaryStubbingException` — it does not weaken the failure-path assertion; the stub still
throws unconditionally when invoked, `lenient` only suppresses the unrelated "stub never used"
complaint on the green path. I do not see a way this stub could mask a real problem: it throws
regardless of the argument used to invoke `scanGate` on the mock (no `argThat` guard, no partial
match), so any invocation at all is caught.

**What I could NOT verify:** the ticket's own framing states PIT's *actual* killing test for this
mutant was reported as a *different* test, killed via `UnnecessaryStubbingException`, not this
regression test. I cannot confirm or refute that from this worktree — see below.

## PIT evidence — not available in this worktree

`find . -name mutations.xml` and `target/pit-reports/` both come up empty. Two facts explain why,
and why the currently-running `mvn verify` will not fix it:

1. `pom.xml:536-537` states outright: "Mutation testing (PIT). **Not bound to any lifecycle
   phase: it runs only when invoked explicitly**, so `mvn test` and `mvn package` are unaffected."
   PIT here is only ever run as an explicit `mvn org.pitest:pitest-maven:mutationCoverage
   -DtargetClasses=... -DtargetTests=...` command (pom.xml:544-547), never as part of `verify`.
2. `target/classes` and `target/test-classes` all carry timestamps in the 02:10–02:11 window,
   i.e. a full recompile happened right around the commit time — consistent with the currently
   running build having done a `clean` first. Whatever `target/pit-reports/mutations.xml` existed
   from the PIT run the task description refers to ("a PIT run already done on this change") was
   almost certainly wiped by that clean, and a plain `mvn verify` cannot regenerate a PIT report
   because PIT isn't wired into `verify`'s lifecycle at all.

I waited (bounded poll, ~15 min budget) for `target/pit-reports/mutations.xml` to appear in case a
parallel PIT invocation was also in flight; it did not appear, consistent with point 1 above — no
in-flight `mvn verify` will ever produce it.

**Consequence:** I cannot independently confirm or refute, from primary evidence:
- That the two PIT survivors are at `OutboundPalletLabelGuard.java` line ~69 specifically.
- That PIT's actual killing test for the "remove the guard call in scanGate" mutant was a
  *different* test than `scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService`, killed via
  `UnnecessaryStubbingException`.

This is a genuine evidence gap, not a rubber stamp of the executor's claim. **Recommendation:**
re-run the scoped PIT command from the recipe once the current `mvn verify` finishes and the
worktree is free, e.g.:
```
mvn test-compile
mvn org.pitest:pitest-maven:mutationCoverage \
    -DtargetClasses=net.aim_ai.wms.service.mobile.OutboundPalletLabelGuard,net.aim_ai.wms.service.mobile.MobileTruckLoadingService \
    -DtargetTests=net.aim_ai.wms.unit.service.mobile.OutboundPalletLabelGuardUnitTest,net.aim_ai.wms.unit.service.mobile.MobileTruckLoadingServiceTest,net.aim_ai.wms.unit.service.mobile.MobileTruckLoadingServiceUnitTest
```
and re-attach `mutations.xml` to this evidence folder before treating AC4 as closed.

## The 2 PIT survivors at OutboundPalletLabelGuard line ~69 — reasoned from source (not from the report)

Since I cannot read the actual PIT XML, I evaluated the claim ("equivalent mutants") purely from the
code at `OutboundPalletLabelGuard.java:69-75`:

```java
boolean patternConfigured = pattern != null && !pattern.isEmpty();
boolean printingPatternConfigured = !convertedPrintingPattern.isEmpty();
if (!patternConfigured && !printingPatternConfigured) {
    LOG.warn("Neither {} nor {} is configured; rejecting pallet {} because an outbound pallet cannot"
                    + " be told apart from any other label.", ..., palletLabel);
}

boolean matches = (patternConfigured && palletLabel.matches(pattern))
        || (printingPatternConfigured && palletLabel.matches(convertedPrintingPattern));
if (!matches) {
    throw new BusinessException("noValidString", palletLabel, ...);
}
```

The `if (!patternConfigured && !printingPatternConfigured)` block's **only** effect is the
`LOG.warn` call — it does not set any flag, does not alter `patternConfigured`/
`printingPatternConfigured`, and does not early-return (unlike its sibling in
`MobileMoveUnitloadService`'s D0, which does `return` here). The subsequent `matches` computation
and the `throw` are reached identically whether or not this block's condition or its body executes.
Any mutant that (a) negates/removes this `if` condition, or (b) removes the `LOG.warn` call itself,
changes **zero** externally observable behavior (return value, thrown exception, exception key,
exception message) — because no test in this suite asserts on log output (confirmed: no
`ListAppender`/log-capture in `OutboundPalletLabelGuardUnitTest` or the surrounding test files).

**Verdict on this specific point: plausibly true equivalent mutants, but I have not seen the actual
PIT XML to confirm the mutated line numbers match this block precisely**, nor to rule out that a
survivor is instead on the `matches` boolean expression itself (which WOULD be a real assertion
gap — e.g., a mutant flipping `||` to `&&` in the `matches` expression should be killed by the
"only-the-printing-pattern-configured" / "only-the-regex-pattern-configured" tests, which do
exist and do cover both disjuncts independently). Re-running PIT (see above) is needed to close
this out with certainty.

## Coverage gap: no IT exercises the real guard

Confirmed: `AbstractTruckLoadingPgFixture` adds `@MockitoBean private OutboundPalletLabelGuard
outboundPalletLabelGuard;` and `MobileTruckLoadingRollbackIT` adds the same. A Mockito
`@MockitoBean` with no stubbing is a no-op for a `void` method, so every existing IT that goes
through `scanGate`/`checkPallet` bypasses the real guard entirely. **This is acceptable**, for the
reasons the architect gave and that the diff satisfies:
- The guard is pure (no repository/entity access — confirmed above), so nothing about its
  correctness depends on a live Postgres container or JPA context; a Mockito unit test exercises
  its full logic surface (regex accept, printing-pattern accept, both-configured, either-alone,
  neither, null/empty) with no test-double gap.
- Its *placement* (called before the write service opens its transaction) is proven by
  `TruckLoadingWriteEntryPointArchTest`, which does not need the guard's own logic to be live —
  it only needs to know the write service's `scanGate` has exactly one production caller.
- Mocking it in the ITs is deliberate and load-bearing for those ITs' own purpose: their fixture
  labels are chosen specifically to land on PHASE D0's no-clear branch (per the class javadoc), and
  a live guard rejecting them outright would make those ITs fail for a reason unrelated to what they
  test (the write-path lock/rollback behavior).

**What is lost versus a DB-level test:** an end-to-end IT that hits the real `POST
/v3/truckLoading/scanGate` with the real guard wired in and a real inbound-shaped label would
directly re-demonstrate "336 rows not locked" against Postgres, which is strictly closer to the
originally observed defect than a Mockito `verifyNoInteractions`. That was the architect's own
"risk/cost" call (§Risks: "The mocked guard means no IT exercises the real guard. That is
acceptable...."), and the diff implements exactly what was pre-approved, not a unilateral
deviation. I have no basis to override the architect's risk-acceptance in a verifier pass, but flag
it as a residual gap of low severity given the unit coverage.

## Architect recommendation checklist

| Rec. | Content | Status | Evidence |
|---|---|---|---|
| 1 | Extract pure check into `@Component OutboundPalletLabelGuard`, no repo access | MET | New file, `@Component`, only `SyspropService` + `StringConverter` deps |
| 2 | `checkPallet` delegates to the guard | MET | `MobileTruckLoadingService.checkPallet` calls `outboundPalletLabelGuard.requireOutboundPalletLabel(palletLabel)` in place of the inline check |
| 3 | `scanGate` calls the guard first, before/outside the try block | MET | Confirmed by full method read (above) |
| 4 | ITs get `@MockitoBean OutboundPalletLabelGuard`, no-op by default, no new Spring context key | MET | Both `AbstractTruckLoadingPgFixture` and `MobileTruckLoadingRollbackIT` add the mock in-place, alongside existing `@MockitoBean`s |
| 5 | Unit regression tests: non-outbound → guard throws + `verifyNoInteractions`; outbound → guard then write service | MET | `scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService` (reject case); `scanGate_shouldDelegateToTheWriteServiceAndMapTheDto` and siblings now call `stubOutboundPalletPatterns()` first (accept case) |
| Rail | ArchUnit rule pinning `MobileTruckLoadingService` as sole production caller of the write service's `scanGate`, plus a positive control against a vacuous pass | MET | `TruckLoadingWriteEntryPointArchTest` has both `onlyTheFacadeCallsTheWriteServiceScanGate` and `theFacadeDoesCallTheWriteServiceScanGate` (positive control), matching the exact rationale in the architect doc almost verbatim |
| Fail-closed sub-answer | Fail closed on neither-configured; reuse `noValidString`; configured-only matching (D0's rule); verify `describeExpectedFormat` tolerates null | MET | `OutboundPalletLabelGuard:69-83` fails closed via the existing `matches=false` fallthrough (no early return, unlike D0); reuses `noValidString`; `patternConfigured`/`printingPatternConfigured` gating mirrors `MobileMoveUnitloadService`'s D0 exactly (compared side-by-side, `:545-563`); `StringConverter.describeExpectedFormat` verified by reading source — `printingPattern != null` guard at line 65 and `acceptPatterns != null` + per-element `p != null` at lines 82-84 both tolerate the all-null case and fall through to the `"(no label format configured)"` sentence, matching `OutboundPalletLabelGuardUnitTest.rejectsWhenNeitherPatternIsConfigured`'s assertion |

## Anything the diff does not address

- `MobileTruckLoadingWriteService.scanGate` (write-service level) remains reachable without the
  guard if some future code calls it directly — the architect flagged this explicitly as an
  accepted residual risk under Option C, mitigated only by the new ArchUnit rule, not eliminated.
  The diff's javadoc update to `MobileTruckLoadingWriteService.scanGate` (":147-153" region)
  correctly documents this rather than overclaiming the gap is closed.
- `StringConverter.convertFormatToRegex`'s unchecked-exception risk on a malformed printing format
  is explicitly out of scope per the architect doc (§Risks) and the diff does not touch it — correctly
  left alone.
- No production code or test exercises the combination "both patterns configured but pallet label
  is empty string after trim-like normalization" — not a real gap since `palletLabel.isEmpty()` is
  checked first and is exact (no trimming anywhere in the codebase's use of these labels), so this is
  not a missing case, just noting it was considered and correctly excluded.
- Fresh test execution: **not obtained.** The worktree's own `mvn verify` was mid-flight throughout
  this pass (I was instructed not to run Maven), so I cannot show fresh green/red output for
  `OutboundPalletLabelGuardUnitTest`, `MobileTruckLoadingServiceTest`, `MobileTruckLoadingServiceUnitTest`,
  `TruckLoadingWriteEntryPointArchTest`, `MobileTruckLoadingRollbackIT`, or the full suite baseline.
  This report's "MET" verdicts above are based on static reading of the diff and hand-tracing of
  control flow, not on executing the tests. Once the in-flight `mvn verify` completes, its
  `target/surefire-reports/` and `target/failsafe-reports/` should be read (fresh, not by me
  re-running anything) to confirm these tests actually pass, before this ticket is treated as fully
  verified.

## Recommendation

**GAPS FOUND** — not because the implementation appears wrong (everything checked against the
architect consult and the stated ACs is MET on static/hand-traced evidence), but because two pieces
of evidence this verification was asked to confirm are currently unobtainable from this worktree:
(1) the actual PIT `mutations.xml` for the two claimed survivors and the claimed
`UnnecessaryStubbingException` killing-test detail — the file does not exist and the running
`mvn verify` cannot regenerate it, since PIT is not bound to any Maven lifecycle phase in this
project; and (2) fresh test execution output for any of the new/changed tests, since Maven was
off-limits to this lane while a verify run was already in flight. Both are closeable with a
follow-up: re-run the scoped PIT command above, and read (do not re-run) the completed
`mvn verify`'s surefire/failsafe reports once it finishes.

GAPS FOUND

---

## Addendum — 2026-09-24, second pass (AC4 evidence now available)

Scope: close the AC4 evidence gap flagged in the first pass. Commit under review is now
`d9a708b9` (review-fix commit, "address the code review (M1, L1, L3-L8)"), on top of
`d62a663d` (identical in substance to the `3b8b19e1` reviewed above — same worktree, ticket
branch rebuilt/recommitted). Still read-only except as explicitly authorized: no edits, no
git-state changes; one exception granted for this pass — `mvn -o -q test -Dtest=<class>` on
existing, unmodified test classes, used below to obtain fresh execution evidence.

### (1) Reading `pit-mutations.xml` — killing-test and survivor claims

Read `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3474-evidence/pit-mutations.xml`
in full (49 mutation records, `partial="true"`, scoped to `MobileTruckLoadingService` and
`OutboundPalletLabelGuard`, run against HEAD `d62a663d` + the working tree since committed as
`d9a708b9`).

**The scanGate guard-removal mutant — this is the one AC4 is actually about:**
```xml
<mutation detected='true' status='KILLED' numberOfTestsRun='1'>
  <mutatedMethod>scanGate</mutatedMethod><lineNumber>162</lineNumber>
  <mutator>...VoidMethodCallMutator</mutator>
  <killingTest>...MobileTruckLoadingServiceTest.../scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService()</killingTest>
  <description>removed call to net/aim_ai/wms/service/mobile/OutboundPalletLabelGuard::requireOutboundPalletLabel</description>
</mutation>
```
This **directly contradicts** the earlier-reported concern (that this mutant was killed via a
*different* test through `UnnecessaryStubbingException`). In this run, it is killed by exactly
the intended regression test, `scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService`, whose
failure message on that mutant is the named `AssertionError` string traced in the first pass
("SBDEV-3474: the write service was reached for non-outbound label IN-000002…"). **This is a
clean, attributable kill — AC4's literal requirement is met by primary evidence, not by hand-trace
alone anymore.**

**A related but distinct mutant — checkPallet's own guard-removal, NOT what AC4 asks about:**
```xml
<mutation detected='true' status='KILLED' numberOfTestsRun='5'>
  <mutatedMethod>checkPallet</mutatedMethod><lineNumber>87</lineNumber>
  <mutator>...VoidMethodCallMutator</mutator>
  <killingTest>...MobileTruckLoadingServiceTest.../testCheckPalletSuccessfully()</killingTest>
  <description>removed call to .../OutboundPalletLabelGuard::requireOutboundPalletLabel</description>
</mutation>
```
This is where the "killed via an incidental mechanism, not a targeted assertion" pattern *does*
show up — just on `checkPallet`, not `scanGate`. `MobileTruckLoadingServiceTest` is
`@MockitoSettings(strictness = Strictness.STRICT_STUBS)`, and `testCheckPalletSuccessfully`
stubs `syspropService.getSysvalue(...)` twice for a label that WOULD pass the guard anyway. When
the guard call is removed, those two stubs go unused and the test fails on
`UnnecessaryStubbingException` at teardown — a message that says a stub was never used, not
"checkPallet's outbound-pallet check is missing." A more attributable test also exists and covers
the same mutant — `checkPallet_shouldIncludeExpectedFormat_whenLabelMatchesNoPattern`, which
would see the exception key flip from `noValidString` to `entityNotFoundForName` and
`verifyNoInteractions(unitloadRepository)` fail with a named interaction — but PIT ran
`testCheckPalletSuccessfully` first among the 5 tests covering that line and stopped there, so the
report never shows the stronger kill. **This does not affect AC4** (worded specifically around
"AC1's test", i.e. the scanGate path), but it is a real, minor asymmetry between the two call
sites' mutation-attributability, worth a follow-up note rather than a blocker.

**The two SURVIVED mutants, `OutboundPalletLabelGuard.java:70`:**
```xml
<mutation detected='false' status='SURVIVED' ...><lineNumber>70</lineNumber>
  <mutator>...NegateConditionalsMutator</mutator><killingTest/>
  <description>negated conditional</description></mutation>
```
(both `index=78` and `index=80`, same line). Current source at that line:
```java
if (!patternConfigured && !printingPatternConfigured) {
    LOG.warn(...);   // only statement in the block — no return, no flag mutation
}
```
Confirms the first-pass hand analysis exactly: this `if`'s only effect is a log call, no test
asserts on logging, and negating/removing the condition changes zero observable behavior (the
`matches` computation and the subsequent throw are reached identically either way). **True
equivalent mutants, not an assertion gap.** Verdict unchanged from the first pass, now confirmed
against the actual mutant records instead of inferred from source alone.

### (2) Hand-mutation claims — verified against the review-fix commit and the PIT file

`d9a708b9`'s own message states: "Each new assertion (L5, L8) was hand-mutated and went red with a
message naming its target," matching the coordinator's claims (b) and (c):

- **(a)** scanGate guard-call removal → `scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService`
  fails with the named string. **Now confirmed by the PIT XML itself** (see above), not just the
  hand-trace — strongest form of evidence available.
- **(b)** Moving checkPallet's guard call after the pallet lookup → read the current
  `checkPallet_shouldIncludeExpectedFormat_whenLabelMatchesNoPattern`
  (`MobileTruckLoadingServiceTest.java:326-352`, review-fix "L8"): ends with
  `verifyNoInteractions(unitloadRepository)` and the comment "the label check runs BEFORE the
  pallet lookup, so a bad label costs no query." A reordering that puts the lookup first would
  produce a Mockito failure literally reading "No interactions wanted here... unitloadRepository"
  — attributable to the specific mock, which is enough to point an engineer at the right code even
  though it doesn't spell out "guard order" in English. **Plausible and consistent with the diff
  as read; not independently re-executed (would require an edit, outside this pass's authorization).**
- **(c)** Reading sysprops before the null check → `rejectsANullOrEmptyLabel`
  (`OutboundPalletLabelGuardUnitTest.java:190-199`, review-fix "L5"): ends with
  `verifyNoInteractions(syspropService)`. Confirmed this assertion exists and is new versus the
  version reviewed in the first pass (it was absent from the original `3b8b19e1`/`d62a663d`
  version I read then). A reordering that reads sysprops before the null/empty check would call
  `syspropService.getSysvalue(...)` and this assertion would fail, naming `syspropService`
  directly. **Consistent with the diff; not independently re-executed for the same reason as (b).**

**Judgment on whether the hand mutations close AC4's attributability gap:** yes for the literal
AC4 (scanGate), which is now closed by primary PIT evidence rather than by hand mutation at all.
The hand mutations (b) and (c) close two *adjacent* invariants (ordering, and no-read-before-
null-check) that AC4 does not literally ask about but that the architect consult's Recommendation
5 and the "no entity touch" language in AC2 depend on — both are now test-enforced with named,
attributable failures, which is a net strengthening of the diff versus the first-pass version.

### Fresh test execution (new this pass)

Ran (offline, single classes, no edits, no full verify — `mvn -o -q test -Dtest=...`):
```
OutboundPalletLabelGuardUnitTest, MobileTruckLoadingServiceTest,
MobileTruckLoadingServiceUnitTest, TruckLoadingWriteEntryPointArchTest
```
Fresh surefire output, this pass, this machine:

| Class | Tests run | Failures | Errors |
|---|---|---|---|
| `OutboundPalletLabelGuardUnitTest` | 12 | 0 | 0 |
| `MobileTruckLoadingServiceTest` | 22 | 0 | 0 |
| `MobileTruckLoadingServiceUnitTest` (+ 5 nested classes) | 0 + 11 (4+1+3+1+2) | 0 | 0 |
| `TruckLoadingWriteEntryPointArchTest` (incl. positive control) | 2 | 0 | 0 |

Total 47/47 green, `mvn` exit code 0. This directly closes the first pass's "no fresh test
execution obtained" gap for the four classes central to this ticket. I did not reproduce the
coordinator-reported full-suite numbers (unit lane 6871/0 vs. baseline 6858/0; integration lane
130 classes/0 failures, stopped before the truck-loading ITs before the host killed the run for
memory) — that remains the coordinator's claim, not independently re-run by me in this pass, since
re-running the full suite was out of scope for a bounded single-class reproduction.

### (3) Re-graded acceptance criteria

| # | Criterion | First-pass status | **This-pass status** | What changed |
|---|---|---|---|---|
| AC1 | No lock, `noValidString`, proved by a test | MET (hand-traced) | **MET** | Unchanged reasoning; now also backed by a fresh green run of the exact test |
| AC2 | Runs before B1, no entity touch, first-touch invariant intact | MET | **MET** | `d9a708b9`'s L3 fix corrected an overclaim in the write-service javadoc (it no longer claims a non-outbound label "never reaches B1" universally — only through the facade); tightens documentation accuracy, no code-behavior change |
| AC3 | One test per accept pattern, matching checkPallet's coverage | MET | **MET** | Two new guard tests for empty-string sysprop values (L6) strictly add coverage |
| AC4 | Mutation check names the missing rejection | **PARTIAL** (hand-traced only, primary PIT evidence unavailable) | **MET** | `pit-mutations.xml` now exists and shows the scanGate guard-removal mutant (line 162) killed directly and attributably by `scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService` — the earlier-reported "killed via a different test/UnnecessaryStubbing" concern does not apply to this mutant in this run. Two hand-mutations (L5, L8) independently confirm attributable kills on adjacent invariants. The one residual observation (checkPallet's own guard-removal mutant is killed by an incidental `UnnecessaryStubbingException` in `testCheckPalletSuccessfully` rather than by the more on-point `checkPallet_shouldIncludeExpectedFormat_whenLabelMatchesNoPattern`) is outside AC4's literal scope (checkPallet, not scanGate) and does not block this verdict |

### Updated recommendation

All four ACs are now MET on primary evidence (an actual PIT mutation report I read myself, plus a
fresh test run I executed myself this pass) rather than on hand-trace/inference. The architect
consult's recommendations and rail are all implemented and verified (unchanged from the first
pass). Residual items, none blocking:
- Low: `checkPallet`'s guard-removal mutant is killed by an order-dependent, less-attributable
  test (`testCheckPalletSuccessfully` via `UnnecessaryStubbingException`) even though a more
  attributable test for the same mutant exists in the suite. Optional follow-up: add an explicit
  `verify(syspropService, atLeastOnce())...` or reorder so PIT's reported kill is the intentional
  one, but this is cosmetic — the mutant IS killed, by the suite as a whole, either way.
- Informational: the full `mvn verify` (unit lane 6871/0 vs. baseline 6858/0; integration lane
  incomplete, stopped by the host before the truck-loading ITs) is the coordinator's report, not
  independently reproduced by me this pass. CI will run the integration lane on the PR per the
  coordinator; nothing in this ticket's ACs depends on an IT exercising the real guard (the
  architect's mock-the-guard-in-ITs call, reaffirmed and documented as a proposed follow-up by
  review finding M1, is unchanged and still sound).

**VERIFIED**
