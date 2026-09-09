---
name: pr288-fact-check2
description: Round-2 adversarial fact-check of wms2-api PR #288's review-round-1 fix claims (SBDEV-3198 step 4, StockSummaryExportJob D')
lane: fact-check (round 2 — verifies the round-1 review's "all fixed" claims, not a design review)
reviewed: 2026-09-03
base: 680f1f15 (PR #288 as it stood after round-1 code review, before fixes)
head: 67241727 (PR #288 tip — claims to fix all round-1 findings)
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-288-review-round2-fact
---

# PR #288 — round-2 fact-check of the "review round 1 — all fixed" claims

## Verdict

**8 of 9 checked claims PASS as stated (one, #2, PASSes but only under a narrow reading that a
careless skim would miss). 2 claims FAIL on an exact number** (full-suite total, and touched-test-file
count — both off by a small, findable amount). **1 claim (M-1's "mirrors ... reviewed shape") is
CORRECTED** — the behavioral outcome matches, but the code shape does not, and could not, because the
reference job carries no equivalent mechanism to mirror. None of the three findings changes the
merge-readiness verdict; all three are precision defects in the PR description, not defects in the code.

## Summary table

| # | Claim | Verdict | Detail |
|---|---|---|---|
| 1 | Full suite 6237/0/67, +7 over 6230 baseline | **FAIL** (off by 1) | Actual: **6238/0/67**. Round 1 added **8** new `@Test` methods, not 7 — the PR's own breakdown (5+1+1) omits `AdminActionControllerUnitTest.surfacesRefusalInsteadOfHardcodedSuccess()` (the L-2 fix's test). |
| 2 | PIT: every boolean-return/lock-unlock mutant from this round killed; 2 survivors are equivalent no-ops | **PASS** (narrowly true; the unqualified phrasing invites a broader misreading) | Exactly 2 survivors are boolean-return mutants, both genuinely equivalent no-ops, both on lines round 1 itself introduced. But the *whole class* PIT run has **~47** non-killed mutants total — all in pre-existing, round-1-untouched code (`exportStockSummary` and friends). "PIT on `StockSummaryExportJob`" is not itself scoped in the PR text; only the surrounding sentence is. |
| 3 | H-1: one-key taken/released per matching tenant, immediately wrapping the two-key lock | **PASS** | Confirmed by direct code read, `StockSummaryExportJob.java:244-276`. |
| 4 | H-2: `runFor`-level tests exist for both unlock paths, and actually pin the unlock | **PASS** | `throwingTenantReleasesBothLocks` and `twoTenantGroupReleasesEachLockTwice` in `StockSummaryExportJobTest.java`, both asserting `verify(advisoryLockService).unlock(...)`. Independently corroborated: my own PIT run shows **zero** surviving mutants on either `unlock(...)` call site. |
| 5 | M-1: catch-block split "mirrors `StaleClubBatchCleanupJob`'s reviewed shape" | **CORRECTED** | The *outcome* matches (pre-membership failure → only `anyReadFailure`). The *shape* does not and structurally cannot: `StaleClubBatchCleanupJob` uses **one** catch block and carries **zero** `JobMetrics` calls (its own javadoc says so explicitly), so it never needed a split. `StockSummaryExportJob` DOES track per-tenant `anyFailure`/`tenantFailure` metrics that must not fire pre-membership, which is *why* it needs the two-level try/catch the reference job doesn't have. "Mirrors the reviewed shape" overstates a structural resemblance that isn't there; the correct claim is "reproduces the reviewed *outcome* by a different, necessarily more complex mechanism." |
| 6 | "10 pre-existing test files touched across both submission and round 1" | **FAIL** | Actual: **12** files, all pre-existing (`git diff --name-status 3941fb26..67241727 -- src/test`, all `M`). Round 1 alone touched 7; the initial submission touched the other 5 (`SchedulingReconcileIdempotencyUnitTest`, `StaleClubBatchCleanupJobDeriveSpecUnitTest`, `NeverMatcherNullBlindnessArchTest`, `StockCountRestControllerUnitTest`, plus one already in the round-1 set). |
| 7 | `NeverMatcherNullBlindnessArchTest` inventory still accurate after round 1 | **PASS** | Ran the class in isolation: `Tests run: 4, Failures: 0, Errors: 0`. |
| 8 | L-4: `noScheduleTenantIsNamed` now actually distinguishes the two grouped jobs' identical-shaped log message | **PASS**, mutation-confirmed | Both `LOG.error` call sites (`SchedulingConfiguration.java:809-812` and `:975-978`) are byte-identical apart from the substituted `JOB_NAME` (`"stockSummaryExport"` vs `"staleClubBatchCleanup"`). Hand-mutant: disabled the `staleClubBatchCleanup` log line → test went **RED** (`Expecting any element of: [] to satisfy...`) as predicted. Restored cleanly. |
| 9 | M-3: "substantially mitigated" by H-1's per-tenant scoping | **PASS**, honest characterization | `landlord.datasource.maximum-pool-size=2` confirmed unchanged. Old code held the one-key lock for the *entire per-tenant walk* of a group; new code holds both one-key and two-key only for one tenant's critical section, released before advancing to the next tenant. Genuine reduction in concurrent-hold duration; the live-cap verification gap is honestly still flagged as open, not glossed over. |

---

## 1. Full suite test count

**Claim:** "Full suite: 6237/0/67 (0 failures, 0 errors), +7 over the 6230 baseline."

**Method:** `mvn -o clean test` run twice in this worktree (the first run was contaminated by a
concurrent `mvn -Dtest=...` I ran in the same worktree while it was in flight — see the note below;
the second, clean, isolated run is authoritative). Cross-checked two ways per the repo's "two
independent instruments" convention:

- Maven's own aggregate line: `[WARNING] Tests run: 6238, Failures: 0, Errors: 0, Skipped: 67`
- Independent Python sum across all 1677 `target/surefire-reports/*.txt` files (never trust a single
  file):

```
files: 1677
Tests run: 6238 Failures: 0 Errors: 0 Skipped: 67
```

Both instruments agree: **6238/0/67**, not 6237/0/67. The failure/error counts are correct (0/0); only
the total is off by one, and it undercounts the delta (+8 actual vs the claimed +7).

**Root cause of the miscount, confirmed:**

```
$ git diff 680f1f15..67241727 -- src/test | grep -cE '^\+.*@Test'
8
$ git diff 680f1f15..67241727 -- src/test | grep -cE '^-.*@Test'
0
```

8 new `@Test` methods, 0 removed — a net +8, not +7. The PR's own itemization ("5 new
`DualLockPerTenantScoping` tests, 1 unlock-on-throw test, 1 whole-run-gauge test" = 7) is missing:

```java
// src/test/java/net/aim_ai/wms/unit/controller/AdminActionControllerUnitTest.java
@Test
void surfacesRefusalInsteadOfHardcodedSuccess() throws Exception, net.aim_ai.wms.exceptions.BusinessException {
```

This is the L-2 fix's test (`AdminActionController.triggerUpdateStock` now returns the job's real
outcome instead of a hard-coded `true`) — real, correctly testing a real fix, just not counted in the
PR description's arithmetic.

**A methodology note for whoever re-derives this:** do not run any other `mvn` invocation in this same
worktree while a `mvn -o clean test` is in flight. I made this mistake myself mid-check — I ran
`mvn -o test -Dtest=NeverMatcherNullBlindnessArchTest` and later a hand-mutant `mvn -o test
-Dtest=SchedulingConfigurationUnitTest` concurrently with a backgrounded `mvn -o clean test`, and the
first full-suite run's `target/surefire-reports/` ended up polluted with one stale `Failures: 1` from
my own mid-flight mutant (`SchedulingConfigurationUnitTest$GroupedRegistration`, not a real defect —
I had deliberately broken the source to mutation-test L-4, and the concurrent `clean` phase raced with
that write). The second, isolated run reproduced 6238/0/67 with zero contamination and is the number to
trust. (Matches this repo's own documented landmine: "Concurrent Maven in one worktree = false reds.")

## 2. PIT mutation testing on `StockSummaryExportJob`

**Claim:** *"PIT on `StockSummaryExportJob`: every real boolean-return and lock/unlock-path mutant
introduced or exposed by this round is now killed (the two remaining PIT survivors are equivalent
no-op mutants — mutating a `return true;`/`return false;` statement to the value it already
returns)."*

**Method:**

```bash
mvn -o test-compile -q
mvn org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.schedulejob.StockSummaryExportJob \
  -DtargetTests='net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobUnitTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobBulkInsertTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobOmsDecouplingTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobMetricsUnitTest'
```

Result: `Generated 108 mutations Killed 61 (56%)`, `Line Coverage 213/267 (80%)`. Parsed
`target/pit-reports/mutations.xml` for every non-`KILLED` mutant (48 rows: SURVIVED + NO_COVERAGE +
1 TIMED_OUT).

**The two boolean-return survivors, exact lines:**

```
(368, 'SURVIVED', 'runForCurrentTenant', 'BooleanTrueReturnValsMutator',  'replaced boolean return with true')
(371, 'SURVIVED', 'runForCurrentTenant', 'BooleanFalseReturnValsMutator', 'replaced boolean return with false')
```

Source at those exact lines (`StockSummaryExportJob.java`):

```java
367  try {
368      exportStockSummary(null);
369      return true;
370  } catch (Exception e) {
371      LOG.error("Error during stockSummaryExport (single-tenant trigger)", e);
372      return false;
```

Line 368 already returns `true` — the `BooleanTrueReturnValsMutator` mutating it "to `true`" is
literally a no-op. Line 371 already returns `false` — same reasoning for
`BooleanFalseReturnValsMutator`. **The "equivalent no-op" characterization is correct**, not just
asserted.

**Confirmed these two lines were introduced by round 1, not pre-existing:**

```diff
-            return;
+            return false;
 ...
         try {
             exportStockSummary(null);
+            return true;
         } catch (Exception e) {
             LOG.error("Error during stockSummaryExport (single-tenant trigger)", e);
+            return false;
```

(`git diff 680f1f15..67241727` — round 1 converted `runForCurrentTenant()` from `void` to `boolean` per
L-2; these two `return` statements did not exist before this round.)

**No lock/unlock-path mutant survives.** Every `unlock(...)` call site in `runFor` and
`runForCurrentTenant` is fully killed — none appears anywhere in the 48-row non-killed list. This
independently corroborates claim #4 (H-2's tests).

**Where the claim needs a caveat, not a correction:** the sentence *"PIT on `StockSummaryExportJob`"*
reads, out of context, like a whole-class result. It is not — the whole class actually has **~47**
non-killed mutants (SURVIVED + NO_COVERAGE), overwhelmingly in `exportStockSummary` and its two lambda
bodies (queue-draining logic, `InventoryRecord` setter calls, `Thread.interrupt()` calls,
`recordOmsVerdict`), none of which round 1 touched (confirmed: the round-1 diff's last hunk ends before
line 377, where `exportStockSummary` begins). Read in the context of the sentence it sits in — scoped
explicitly to "boolean-return and lock/unlock-path mutant introduced or exposed by this round" — the
claim is accurate and the scoping is honest, not cherry-picked (the pre-existing survivors are all
genuinely pre-existing and genuinely outside that scope). But a reader skimming just the first clause
could walk away thinking the whole class is nearly mutant-clean, which it is not. Verdict: **PASS as
literally scoped**, flagged for anyone citing this PR description out of context.

## 3. H-1's structural claim

**Claim:** *"one-key now taken/released per matching tenant, immediately wrapping that tenant's
two-key lock."*

**Method:** direct read, `StockSummaryExportJob.java:240-277`.

```java
240  // H-1 (PR #288 review): one-key acquired PER TENANT, immediately wrapping the
241  // two-key acquisition — take one-key, take two-key, work, release two-key,
242  // release one-key, sequentially per tenant.
244  if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT)) {
...  //   (busy → continue to next tenant, no export)
250  }
251  try {
252      if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT, tenantId)) {
...
256      }
257      tenantSample = jobMetrics.startTenantTimer();
258      try {
...      //   activation check, exportStockSummary(tenantName), tenantSuccess()
272      } finally {
273          advisoryLockService.unlock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT, tenantId);
274      }
275  } finally {
276      advisoryLockService.unlock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT);
277  }
```

Lock order: one-key acquired (244) → try { two-key acquired (252) → try { work } finally { two-key
released (273) } } finally { one-key released (276) }. This is exactly "take one-key, take two-key,
work, release two-key, release one-key, sequentially per tenant, per matching tenant" — nested, never
shared across tenants (each tenant gets its own acquire/release pair inside the loop body). **PASS.**

## 4. H-2's tests

**Claim:** *"added `runFor`-level tests for both paths (a throwing tenant still releases both locks; a
two-tenant group releases each lock the correct number of times), each mutation-verified by deleting
the `finally` body it protects."*

**Method:** located and read the tests in `StockSummaryExportJobTest.java` (task instructed reading,
not re-running PIT for mutation-verification since a parallel code-review lane covers that; I also got
independent corroboration for free from my own PIT run in §2).

```java
@Test
@DisplayName("H-2a: a throwing tenant still releases BOTH its two-key lock and its one-key lock")
void throwingTenantReleasesBothLocks() throws ... {
    ...
    stockSummaryExportJob.runFor(tenant1Spec);
    verify(advisoryLockService).unlock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT, 1L);
    verify(advisoryLockService).unlock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT);
}

@Test
@DisplayName("H-2b: a two-tenant group releases the two-key lock twice and the one-key lock twice")
void twoTenantGroupReleasesEachLockTwice() throws ... {
    ...
    stockSummaryExportJob.runFor(tenant1Spec);
    verify(advisoryLockService, times(2)).unlock(eq(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT), anyLong());
    verify(advisoryLockService, times(2)).unlock(AdvisoryLockService.JobLockId.STOCK_SUMMARY_EXPORT);
}
```

Both assert on `verify(advisoryLockService).unlock(...)` directly — not merely "the method didn't
throw" — so deleting either `finally`'s unlock call (H-2's own round-1 mutant target) would leave the
`verify` unsatisfied and fail the test. Both exist, both test names/`@DisplayName`s match the PR's
description exactly. **PASS.** Independently corroborated by §2's PIT run: no unlock-path mutant
survives anywhere in the class.

## 5. M-1's "mirrors `StaleClubBatchCleanupJob`'s reviewed shape" claim

**Claim:** *"split the per-tenant catch so pre-membership failures set only `anyReadFailure`,
mirroring `StaleClubBatchCleanupJob`'s reviewed shape."*

**Method:** side-by-side read of both methods' catch-block structure.

`StockSummaryExportJob.runFor` (current, `:203-288`) — **two** levels of try/catch:

```java
try {                                                    // outer try
    TenantContext.setCurrentTenant(profile);
    TenantSchedule own;
    try {                                                //   inner try — derivation ONLY
        own = deriveSpecForCurrentTenant();
    } catch (Exception e) {
        anyReadFailure = true;                           //   pre-membership: ONLY this
        continue;
    }
    if (own == null || !own.spec().equals(spec)) continue;
    anyMember = true;
    ...                                                   //   post-membership work
} catch (Exception e) {                                   // outer catch — post-membership ONLY
    anyFailure = true;
    jobMetrics.tenantFailure(tenantName, e.getClass().getSimpleName());
    ...
}
```

`StaleClubBatchCleanupJob.runFor` (`:154-225`) — **one** level:

```java
try {                                                    // single try, derivation AND work together
    TenantContext.setCurrentTenant(profile);
    TenantSchedule own = deriveSpecForCurrentTenant();    //   no inner try
    if (own == null || !own.spec().equals(spec)) continue;
    anyMember = true;
    ...
} catch (Exception e) {                                   // single catch — reached from EITHER phase
    LOG.error("Error processing tenant {} - {}", ..., e);
    anyReadFailure = true;                                //   always this, never anything else
}
```

`StaleClubBatchCleanupJob` has **zero** `JobMetrics` calls anywhere in the file (confirmed by
`grep -n "JobMetrics\." StaleClubBatchCleanupJob.java` → 0 hits; its own class javadoc says so
explicitly: *"has no `JobMetrics` at all"*). It gets away with a single catch block precisely
**because** it has no `anyFailure`/`tenantFailure` state that a pre-membership exception could
wrongly set — the class's own in-code comment explains this is safe *by reasoning*, not by structural
separation (*"by the time real work can throw, `anyMember` is already true"*).

**Verdict: CORRECTED, not a clean PASS.** The *outcome* the PR claims is true — both jobs end up
setting only `anyReadFailure` for a pre-membership failure. But "mirrors ... reviewed shape" overstates
it: there is no split to mirror in the reference file, because the reference job never needed one. The
two-level try/catch in `StockSummaryExportJob` is a **new** mechanism, required specifically because
this job (unlike its reference) tracks per-tenant failure metrics that must not fire before membership
is established. The accurate description is "reproduces the *outcome* `StaleClubBatchCleanupJob`'s
review established as correct, via a different mechanism this job's extra metrics require" — not
"mirrors the shape."

## 6. "10 pre-existing test files touched" claim

**Claim:** *"10 pre-existing test files touched across both submission and round 1."*

**Method:**

```
$ git diff --name-status 3941fb26..67241727 -- src/test
M   src/test/java/net/aim_ai/wms/schedulejob/SchedulingConfigurationUnitTest.java
M   src/test/java/net/aim_ai/wms/schedulejob/SchedulingReconcileIdempotencyUnitTest.java
M   src/test/java/net/aim_ai/wms/schedulejob/StaleClubBatchCleanupJobDeriveSpecUnitTest.java
M   src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java
M   src/test/java/net/aim_ai/wms/unit/controller/AdminActionControllerUnitTest.java
M   src/test/java/net/aim_ai/wms/unit/controller/rest/StockCountRestControllerUnitTest.java
M   src/test/java/net/aim_ai/wms/unit/schedulejob/StockSummaryExportJobBulkInsertTest.java
M   src/test/java/net/aim_ai/wms/unit/schedulejob/StockSummaryExportJobMetricsUnitTest.java
M   src/test/java/net/aim_ai/wms/unit/schedulejob/StockSummaryExportJobOmsDecouplingTest.java
M   src/test/java/net/aim_ai/wms/unit/schedulejob/StockSummaryExportJobTest.java
M   src/test/java/net/aim_ai/wms/unit/schedulejob/StockSummaryExportJobUnitTest.java
M   src/test/java/net/aim_ai/wms/unit/schedulejob/WholeRunSuccessGaugeUnitTest.java
```

**12 files, all `M` (modified, none `A`dded — all genuinely pre-existing).** Not 10. `3941fb26` is
develop's tip immediately before this PR (post `#286`/`#287`), the correct base for "pre-existing."
Round 1 alone (`680f1f15..67241727`) touched 7 of these 12; the other 5
(`SchedulingReconcileIdempotencyUnitTest`, `StaleClubBatchCleanupJobDeriveSpecUnitTest`,
`NeverMatcherNullBlindnessArchTest`, `StockCountRestControllerUnitTest`, and one more already in the
round-1 set) were touched in the initial submission. **FAIL** — off by 2.

## 7. `NeverMatcherNullBlindnessArchTest` census, still accurate after round 1?

**Claim:** implicit — the PR states the census was "updated for the added test coverage"; round-1
review's own claim #5 said the 144→148 bump was arithmetically right *at the initial submission*. Task
was to check it's **still** accurate after round 1's further test additions.

**Method:** ran the test class in isolation (`mvn -o test -Dtest=NeverMatcherNullBlindnessArchTest`).

```
Tests run: 4, Failures: 0, Errors: 0, Skipped: 0
```

Green. The test's own `primitiveCapableMatchersMatchInventory` method does an exact per-class
`never().xxx(anyLong()/anyInt()/anyDouble()/anyFloat()/anyShort()/anyByte()/anyChar())`-style census
against a hard-coded `PRIMITIVE_MATCHER_INVENTORY` list and fails on ANY drift in either direction (not
just an upper bound) — so a green result here is a strong instrument: round 1 did not add any
`never()`-wrapped primitive-capable matcher to a `StockSummaryExportJob*` test class without updating
the inventory, and did not remove one while leaving a stale count either. **PASS.**

## 8. L-4's fix

**Claim:** *"`noScheduleTenantIsNamed`'s assertion now names the job so it can't pass on the wrong
grouped job's identical message."*

**Method:** read the assertion, read both log-emitting sites, then mutation-tested by hand.

Assertion (`SchedulingConfigurationUnitTest.java:1099-1101`):

```java
assertThat(messagesAt(Level.ERROR))
    .anySatisfy(m -> assertThat(m).contains("staleClubBatchCleanup")
        .contains("timer sysprops absent or blank").contains(LA_KEY));
```

Both log sites, confirmed byte-identical apart from the substituted `JOB_NAME` argument:

```java
// SchedulingConfiguration.java:809-812 (stockSummaryExport)
LOG.error("{}: timer sysprops absent or blank for tenant(s) {} — those tenants are in "
    + "no group and this job will not run for them", StockSummaryExportJob.JOB_NAME, noSchedule);

// SchedulingConfiguration.java:975-978 (staleClubBatchCleanup)
LOG.error("{}: timer sysprops absent or blank for tenant(s) {} — those tenants are in "
    + "no group and this job will not run for them", StaleClubBatchCleanupJob.JOB_NAME, noSchedule);
```

`JOB_NAME` constants confirmed distinct: `"stockSummaryExport"` vs `"staleClubBatchCleanup"`.

**Hand mutant:** temporarily wrapped the `staleClubBatchCleanup` log site's guard as
`if (false && !noSchedule.isEmpty())` (i.e., simulated "staleClubBatchCleanup's ERROR stopped logging
while stockSummaryExport's still did," exactly the regression L-4 exists to catch). Ran the outer test
class (not the `#method` form — this project's own CLAUDE.md documents that `-Dtest='Outer#method'`
silently matches 0 tests for a `@Nested` class and reports false `BUILD SUCCESS`; confirmed that trap
myself before correcting to running the whole class):

```
[ERROR] SchedulingConfigurationUnitTest$GroupedRegistration.noScheduleTenantIsNamed:1100
Expecting any element of: [] to satisfy the given assertions requirements but none did
[ERROR] Tests run: 43, Failures: 1, Errors: 0, Skipped: 0
```

RED, exactly as predicted. File restored (`git diff` clean afterward). **PASS.**

## 9. M-3's "substantially mitigated" claim

**Claim:** *"Substantially mitigated by H-1's per-tenant scoping (both connections are now held only
for one tenant's critical section, not the whole walk) — the live-cap verification itself remains an
open item."*

**Method:** confirmed the pool cap is unchanged, and reasoned from the code (not speculation) about
hold duration under old vs. new scoping.

```
$ grep -n "landlord.datasource.maximum-pool-size" src/main/resources/application.properties
66:landlord.datasource.maximum-pool-size=2
```

Still 2 — unchanged by this PR, as claimed.

**Old scoping** (pre-round-1, per the round-1 review's own H-1 finding): one-key lock acquired once at
method entry, held across the `finally` at the very end of the whole per-tenant loop — i.e., for the
duration of the *entire group's fleet walk* (every tenant, sequentially, including every tenant's own
two-key hold). Two connections held simultaneously for the group's total export time (could be tens of
minutes per the H-1 finding's own "40 minutes" example).

**New scoping** (§3 above, code-confirmed): one-key acquired immediately before, and released
immediately after, each individual tenant's two-key-guarded critical section. Both connections are
still held simultaneously (2 of 2 landlord pool slots, unchanged) — M-3's underlying starvation
mechanism is not eliminated — but the *duration* per acquisition drops from "the whole group's walk" to
"one tenant's lock-check-plus-export." This is a real, structural reduction, not merely asserted. The
claim does not overclaim: it says "substantially mitigated," not "resolved," and it explicitly leaves
the live-pool-cap verification open rather than declaring the risk closed. **PASS** — an honest,
code-grounded characterization.

---

## Reproduction notes

- `mvn`/`java` are not on this environment's default `PATH`; use
  `export PATH="/home/nampark/.sdkman/candidates/maven/3.9.15/bin:$PATH"` (sdkman-provided Maven
  3.9.15 + Java 21.0.11-ms, matching the project's declared toolchain).
- Full suite: `mvn -o clean test`, ~3.5 min. Do not run any other `mvn` command in the same worktree
  concurrently — see the contamination note in §1.
- PIT: `mvn -o test-compile -q` then
  `mvn org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.schedulejob.StockSummaryExportJob -DtargetTests='net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobUnitTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobBulkInsertTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobOmsDecouplingTest,net.aim_ai.wms.unit.schedulejob.StockSummaryExportJobMetricsUnitTest'`,
  ~25s. Survivor list is in `target/pit-reports/mutations.xml`.
- L-4 hand-mutant: run the whole outer class (`-Dtest=SchedulingConfigurationUnitTest`), never
  `-Dtest='SchedulingConfigurationUnitTest#noScheduleTenantIsNamed'` — the latter is a JUnit 5
  `@Nested`-class false pass documented in this repo's own `CLAUDE.md` (`Tests run: 0`,
  `BUILD SUCCESS`), and I hit it myself before correcting.
