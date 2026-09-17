# SBDEV-3321 F5 — adversarial review of the test suite

**Question asked:** are these tests capable of failing?
**Answer:** mostly yes — the suite is well above the local average — but **three defects in the current
`src/main` survive all 10 unit tests, and one of the four repository tests still passes against a query
that returns nothing.** All four are measured, not argued.

---

## 0. What was graded, and the moving-target warning

The implementation lane edited `src/main` and **moved both test classes to new packages while this review
was in progress**. An earlier snapshot of this review (taken 13:03–13:06) is superseded. Everything below
grades these exact files:

| File | md5 |
|---|---|
| `src/main/java/net/aim_ai/wms/schedulejob/PendingReversalReconciliationJob.java` | `50e9171dadcd5800018e67379d4a7aa8` |
| `src/test/java/net/aim_ai/wms/schedulejob/PendingReversalReconciliationJobUnitTest.java` | `8e518cf143bf3355e59abf449aba190e` |
| `src/test/java/net/aim_ai/wms/integration/repository/PendingReversalOlderThanIntegrationTest.java` | `c30658a4701a1220323c5d3128802fb0` |
| `src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderCancellationLogRepository.java` | `741f4cc7e6d92abf81b24e86fbaa9464` |

Note the paths changed: `unit/schedulejob/` → `schedulejob/` and `integration/repo/` → `integration/repository/`.

**How everything below was measured.** A throwaway `git worktree` was created off `e113467b` outside the
SBDEV-3321 worktree, the branch's dirty files copied in, and Maven run there (`JAVA_HOME` =
`~/.sdkman/candidates/java/21.0.11-ms`, Maven from `~/.sdkman/candidates/maven/current` — **neither is on
`PATH` by default; a bare `mvn` exits 127**). **No `mvn` was run in the SBDEV-3321 worktree.** The scratch
worktree has been removed.

Baselines established first, so every red below is attributable:

* unit lane: `mvn test -Dtest=PendingReversalReconciliationJobUnitTest` → **10/10 green**
* failsafe lane: `mvn verify -Dit.test=PendingReversalOlderThanIntegrationTest -Dtest=ZzzNone` → **4/4 green, 28.8 s**

---

## 1. Findings

### F-1 (High) — Three real defects survive all 10 unit tests. Measured, one run, 10/10 green.

I applied these three mutations to the **current** job and the whole class stayed green:

| # | Mutation | Why it is a real defect |
|---|---|---|
| **A′** | `catch (Exception e)` → `catch (BusinessException e)` on the `createServiceLog` call | This is the *exact* branch `reconcile_should_isolateAServiceLogFailure` was added to pin |
| **B** | `oldestHours` = `ChronoUnit.HOURS.between(stale.get(0).getCreatedAt(), now)` instead of `.max()` | The headline age becomes ordering-dependent — the thing `describe`'s own comment says must not happen |
| **C** | Deleted `.limit(MAX_ITEMISED)` **and** the `"...and %d more"` branch | `MAX_ITEMISED` becomes dead code; a 500-row estate produces the wall of text the constant exists to prevent |

```
[INFO] Tests run: 10, Failures: 0, Errors: 0, Skipped: 0 -- PendingReversalReconciliationJobUnitTest
[INFO] BUILD SUCCESS
```

Each one individually:

**A′ — `reconcile_should_isolateAServiceLogFailure` does not pin what its comment claims.**
Its comment reads *"Deleting the inner catch leaves every OTHER test green, because the per-tenant catch
absorbs the throw — so without this test the branch is not pinned to its position."* Two problems:

1. **Deleting the inner catch does not compile.** `MessageService.createServiceLog` declares
   `throws BusinessException`, so the compiler forces a catch. I tried it: `[ERROR] …:[195,44] unreported
   exception net.aim_ai.wms.exceptions.BusinessException; must be caught or declared to be thrown`. The
   mutation the comment defends against cannot be made.
2. **The mutation that *can* be made — narrowing the catch to `BusinessException` — this test does not
   catch.** The test stubs a `RuntimeException`; under the narrowed catch it propagates one frame up to the
   loop's `catch (Exception e)`, tenant 1 aborts, tenant 2 still runs, `times(2)` still holds. Green.

   The honest statement is that **nothing observable to a mock distinguishes the inner catch from the loop
   catch** — the only difference is which `LOG.error` label is emitted. The test *is* worth keeping (it
   proves the sweep survives a Service Log failure and the lock is still released), but its comment should
   say that, not claim a branch pin it does not have.

   **Fix:** either accept it and rewrite the comment, or make the difference observable. The cheapest real
   pin is to assert the *remaining* tenants' rows are written when tenant 1 throws a **checked**
   `BusinessException` — which the narrowed catch would still absorb — plus a second row stubbing a
   `RuntimeException` and asserting `times(2)` holds for that too. Only the second one dies under narrowing.

**B — the max-vs-first invariant is untested, and the fixture is ordered to hide it.**
`describe`'s comment says *"The query orders by createdAt ASC, so the oldest is first — but do not depend on
that here. A caller-side ordering change must not silently turn the headline age into the newest row's."*
The fixture at `PendingReversalReconciliationJobUnitTest:99-101` puts the **47-day row first**, so
`get(0)` and `.max()` return the same 1128. The test cannot see the difference.

**Fix — one line, no new test.** Swap the two fixture rows:
```java
when(repo.findPendingReversalsOlderThan(any())).thenReturn(List.of(
    pendingRow(2L, 159907L, "T-0007", OffsetDateTime.now().minusDays(11)),   // newest FIRST
    pendingRow(1L, 60861L,  "T-0002", OffsetDateTime.now().minusDays(47))));
```
`.contains("1128h")` then fails for a `get(0)` implementation. This *strengthens* an existing assertion
rather than adding a test, and it is the only change here I would call mandatory.

**C — `MAX_ITEMISED` has zero tests.** Neither the cap nor the `"...and N more"` suffix nor the claim that
"the headline count is always exact, so a truncated list never understates the problem" is exercised.

**Fix — one new test:**
```java
List<CustomerorderCancellationLog> many = IntStream.rangeClosed(1, 25)
    .mapToObj(i -> pendingRow((long) i, 1000L + i, "T-" + i, OffsetDateTime.now().minusDays(47)))
    .toList();
when(repo.findPendingReversalsOlderThan(any())).thenReturn(many);
// ... capture body ...
assertThat(body.getValue())
    .as("the headline count must be exact even when the list is truncated")
    .contains("25 cancellation reversal(s) pending")
    .as("only MAX_ITEMISED rows are itemised")
    .contains("...and 5 more");
assertThat(StringUtils.countMatches(body.getValue(), " logId "))
    .as("exactly MAX_ITEMISED itemised entries")
    .isEqualTo(PendingReversalReconciliationJob.MAX_ITEMISED);
```

---

### F-2 (Medium-High) — One repository test still passes vacuously. Measured.

Three of the four now carry a positive control (added by the lane during this review — good). **The fourth
does not**, and it behaves exactly as the failure pattern predicts.

With the repository predicate hand-mutated `l.createdAt` → `l.reversalInitiatedAt` (the mutation the class
exists to defend against, which makes the query return **nothing**):

```
[ERROR] Tests run: 4, Failures: 3
[ERROR]   excludesACompletedReversal:120                                    <- RED (control)
[ERROR]   excludesARowInsideTheThreshold:93                                 <- RED (control)
[ERROR]   findsARowWhoseCreatedAtIsOlderThanTheCutoff_evenWhenNeverInitiated:66  <- RED (control)
          excludesARowThatNeverRequiredAReversal                            <- GREEN
```

`excludesARowThatNeverRequiredAReversal` (`:128-139`) is green against a query that returns zero rows
forever. It is a negative assertion on a fixture nobody wrote.

**Fix — three lines, mirroring its three siblings exactly:**
```java
void excludesARowThatNeverRequiredAReversal() {
    CustomerorderCancellationLog notRequired = save(row(OffsetDateTime.now().minusDays(47), false, null));
    CustomerorderCancellationLog control     = save(row(OffsetDateTime.now().minusDays(47), true,  null));

    List<Long> found = idsFrom(repository.findPendingReversalsOlderThan(OffsetDateTime.now().minusHours(24)));

    assertThat(found)
        .as("positive control: log id %s is old, required and incomplete, so the query MUST return it. "
            + "If this is absent the query is broken outright and the exclusion below is vacuous.",
            control.getId())
        .contains(control.getId());
    assertThat(found).as(...).doesNotContain(notRequired.getId());
}
```

**Also measured, in the other direction, so the picture is complete:** with the predicate replaced by a
tautology (`WHERE (reversalRequired = true OR reversalRequired = false) AND (:cutoff IS NOT NULL)`), **all
three exclusion tests go red**. So the negatives are live against over-inclusion and blind to
under-inclusion — the controls close exactly the open half.

---

### F-3 (Medium) — Two comments claim coverage the tests do not have. Both are load-bearing for a future reader.

**(a) `reconcile_should_queryByCreatedAt_notByReversalInitiatedAt` is misnamed, and the class javadoc
overclaims it.** The class javadoc (`:46-49`) calls it *"the mutation-sensitive one… a predicate keyed on
[`reversalInitiatedAt`] returns zero rows forever and every other test here would still pass. This one pins
the cutoff actually handed to the repository."* The last sentence is true and the name contradicts it: the
repository is a **mock**, so the column is structurally invisible to this test. Only
`PendingReversalOlderThanIntegrationTest` sees the column. As written, someone deleting or skipping the IT
would read this name and believe the column is still guarded.

**Fix:** rename to `reconcile_should_passACutoffOfNowMinusThresholdHours`, and change the javadoc bullet to
point at the IT for the column.

**(b) `reconcile_should_notFloorAThresholdOfExactlyOne`'s comment (`:292-293`) asserts a mutant kill that
PIT reports as SURVIVED.** It says *"without this, `thresholdHours < 1` and `thresholdHours <= 1` are
indistinguishable and PIT's conditional-boundary mutant survives."* The mutant survives **with** it — your
own PIT run says so, and the job's javadoc (`safeThresholdHours`) correctly explains why it is equivalent.
The test cannot kill it: at `thresholdHours == 1` both branches return 1. Keep the test (it pins that 1 is a
legitimate threshold, which is worth having), but the comment must stop claiming the kill — it is the kind
of note that sends the next reader hunting a mutant that is already documented as equivalent two files away.

---

### F-4 (Medium) — `JobLockId` has no uniqueness test, and the diff's own comment says a collision is silent.

`AdvisoryLockService.JobLockId` now carries ten `long` constants and **nothing anywhere asserts they are
distinct**. The only test touching the class, `AdvisoryLockServiceJobLockIdContractTest`, pins one constant
(`CLEANUP_REST_IDEMPOTENCY == 100007L`) by name.

This matters specifically here because the new constant's own javadoc records that the catalog said
`100009L` was free when it was not, and that *"a collision here is silent, since two jobs sharing a lock
simply take turns."* The remedy for a documented, silent, already-realised hazard should be a rail, not a
comment.

**Fix — one test, ~12 lines, no new dependency:**
```java
@Test
void jobLockIds_mustAllBeDistinct() {
    Map<Long, String> byValue = new HashMap<>();
    for (Field f : AdvisoryLockService.JobLockId.class.getDeclaredFields()) {
        if (f.getType() != long.class || !Modifier.isStatic(f.getModifiers())) continue;
        f.setAccessible(true);
        String clash = byValue.put(f.getLong(null), f.getName());
        assertThat(clash)
            .as("%s and %s share advisory lock id %d — two jobs sharing a lock silently take turns "
                + "instead of running, and nothing logs it", clash, f.getName(), f.getLong(null))
            .isNull();
    }
    assertThat(byValue).as("the reflection found no constants — broken instrument, not a clean result")
        .hasSizeGreaterThanOrEqualTo(10);
}
```
The last assertion is the positive control: without it a renamed inner class makes the scan find nothing and
report green.

---

### F-5 (Low-Medium) — `verifyNoServiceLogWritten` uses `anyString()` where it needs `any()`.

`PendingReversalReconciliationJobUnitTest:327-334`:
```java
verify(messageService, never()).createServiceLog(
    anyString(), anyString(), anyString(), anyString(), any(), any(), any(), any());
```
`anyString()` **does not match `null`**. So this proves only *"no call was made with four non-null leading
Strings"*. An implementation that wrote a row with a null `sender` or null `process` satisfies the `never()`
and `reconcile_should_writeNothing_whenNoRowIsOverThreshold` stays green while a row was in fact written.
Contrived, but free to close.

**Fix:** `verifyNoInteractions(messageService);` — which is what "writes NOTHING" actually means, and is
immune to overload selection too (the 6- and 7-arg `createServiceLog` overloads are not covered by the
8-arg `never()` on a mock, since the delegation never runs).

---

### F-6 (Informational) — the `1128h` literal is **not** flaky. Verdict: leave it.

You asked specifically. It is stable, for a reason worth writing down:

* `OffsetDateTime.now()` captures a **fixed** offset; `minusDays(47)` keeps that offset and subtracts 47
  local days. Because the offset never changes, the instant difference is **exactly** 47 × 24 h. This is the
  crucial difference from `ZonedDateTime`, where `minusDays` *would* absorb a DST transition and give 1127 or
  1129.
* `ChronoUnit.HOURS.between` truncates toward zero, and the `now()` inside `describe` is strictly later than
  the one in the fixture, so the value is `1128h + δ` with δ in milliseconds → truncates to **1128**.
* Java's clock does not expose leap seconds (they are smeared), so that is a non-issue.
* The only way to get 1127 is a **backwards NTP step** between the two `now()` calls. Not worth defending.

It also does real work: it kills PIT's "replaced long return with 0" on the age lambda, which the previous
`containsIgnoringCase("h")` did not. Two small improvements if you want them, neither blocking:
* the sibling cutoff assertions all carry ±5 s slack and this one has none — deriving the number
  (`long expected = ChronoUnit.HOURS.between(oldest, OffsetDateTime.now());`) would also survive someone
  editing `minusDays(47)` to a different age;
* it is currently the **only** thing tying the fixture to the assertion, so the 47 appears twice, unlinked.

---

### F-7 — Reflection-based field access: **the question is now moot, and the answer is good either way.**

The lane moved the test into `net.aim_ai.wms.schedulejob`, the class-under-test's own package, and replaced
the reflection helpers with direct `job.thresholdHours = 24`. So a rename is now a **compile error** — the
loudest possible failure. Strictly better than before.

For the record, the previous reflection form was also safe: `getDeclaredField` threw
`NoSuchFieldException`, the helper wrapped it in `AssertionError("thresholdHours field is missing or
renamed")`, and three tests went red. It never skipped silently.

One consequence of the same edit is worth flagging to the implementation lane, because it is a new sharp
edge rather than a test defect: **`thresholdHours` no longer has a field initialiser.** Outside Spring it is
`0`, which `safeThresholdHours()` floors to 1. Two tests now set it explicitly (correctly), but
`reconcile_should_writeAServiceLogRow_namingTheOrdersAndTotes` does not — so the row it grades says
"beyond 1h", and **no test in the suite exercises the production threshold of 24 at all**. The `@Value`
binding itself is likewise unexercised: a typo in
`app.reconcile.pending-reversal.threshold-hours` falls through to the `:24` default silently.
(The *cron* key is safe — `@Scheduled` has no default, and `SchedulingReconcileIdempotencyUnitTest` now
asserts the key's presence in `src/main/resources/application.properties`, which is the right rail given that
`src/test/resources/application.properties` shadows main's copy.)

---

### F-8 — Does the integration test actually run, and does it roll back? **Yes and yes. Measured.**

* **In the lane.** `*IntegrationTest.java` is in failsafe's `<includes>` and in surefire's `<excludes>`;
  failsafe's `<excludes/>` is empty. Confirmed by execution, not by reading the pom:
  `Tests run: 4 … 28.75 s -- in …PendingReversalOlderThanIntegrationTest`. Not silently excluded.
* **It rolls back, on the right transaction manager.** `BaseRepositoryIntegrationTest` carries
  `@Transactional("tenantTransactionManager")` — the qualifier whose absence caused the SBDEV-3242 leak —
  and `BaseRepositoryIntegrationTestRollbackContractTest` pins it. I ran that contract test **in the same
  JVM** as this IT: `Tests run: 3, Failures: 0`.
* **Corroborated independently by the fixtures themselves.** Across runs the assigned ids climbed 1, 2, 3, 4
  (the IDENTITY sequence is not transactional, as expected) while **each test's query returned only its own
  rows** — under the tautology mutant every test saw exactly its own fixture and no sibling's. No leakage.
* **Credit where due:** asserting on extracted **ids** rather than `hasSize`/`isEmpty` is the right call for a
  shared H2, and it is what makes the three exclusion tests immune to foreign rows from other classes. Keep
  it, and keep the javadoc paragraph that explains it.

---

## 2. Behaviour with no test at all — honest enumeration

Ordered by what I would actually write. Everything above `MAX_ITEMISED` is already covered in F-1/F-2.

| # | Untested | Worth a test? |
|---|---|---|
| 1 | `MAX_ITEMISED` truncation + `"...and N more"` + exact headline count | **Yes** — F-1 C |
| 2 | Empty tenant list (`tenantProfiles.isEmpty()` → warn, `return`, lock still released) | **Yes.** `tenantRepoWith()` with no configs; `verify(lockService).unlock(...)`, `verify(repo, never()).findPendingReversalsOlderThan(any())`. A `return` placed before the `try` would release nothing and nothing would notice |
| 3 | `TenantContext.setCurrentTenant` NPE → outer catch → remaining tenants run | **Yes**, and it is the outer catch's *only* stated reason for existing. `TenantContext:28` dereferences `getTenantName().length()` whenever the facility code is non-null, so `tenantConfig(null, "01")` reproduces it exactly. Currently the outer catch is entirely uncovered |
| 4 | `findByActiveTrue()` throwing → propagates out of `reconcile()` after `unlock` | Marginal. One line: `verify(lockService).unlock(...)` inside an `assertThatThrownBy` |
| 5 | Null `toteLabelId` → `"(none)"` | Marginal — add a null-tote row to the F-1 C fixture and assert `contains("tote (none)")`; costs nothing once that test exists |
| 6 | Null `createdAt` → filtered out; all-null → `orElse(0L)` | No. The column is `nullable = false`; the filter is defensive |
| 7 | `LOG.error` emitted **before** the `try` (so the breadcrumb survives a Service Log failure) | No. Needs a log appender; the value does not justify the brittleness. But say so in the comment instead of implying it is pinned |
| 8 | Inner-vs-outer catch label distinction | No — see F-1 A′; it is not observable |
| 9 | `ORDER BY l.createdAt ASC` in the repository query | No — `describe` deliberately does not depend on it (once F-1 B is fixed) |
| 10 | The `@Scheduled` cron **value** `0 30 2 * * *` and its stated rationale (02:30 to avoid the 02:00 job) | Low. `SchedulingReconcileIdempotencyUnitTest` now pins that the key *exists*; nothing pins the value or the no-collision claim |
| 11 | The body naming the **right tenant/facility** | Low but real: `describe` interpolates `tenantName - facilityCode` and **no test asserts it**. With two tenants a row naming the wrong warehouse sends an operator to the wrong building. One `.contains("test - 01")` in the positive test closes it |

**Not a test gap, but flagged for the record:** the job omits `JobMetrics`, which the repo's canonical
four-item scheduled-job pattern requires. The class javadoc now argues the omission explicitly (nothing
scrapes `/actuator/prometheus`) and matches `RestIdempotencyCleanupJob`. That reasoning is sound and
consistent with what is known about this estate; I note it only so the deviation is a recorded decision
rather than an oversight.

---

## 3. Verdict

The suite is genuinely good — the tenant-context capture-as-the-query-runs test, the id-scoped IT
assertions, and the `1128h` strengthening are all better than the local norm, and three of the six things I
came in expecting to find had already been fixed by the lane while I was measuring.

**Blocking before merge (both one-liners):**
1. **F-1 B** — reverse the two fixture rows in `reconcile_should_writeAServiceLogRow_namingTheOrdersAndTotes`.
2. **F-2** — add the positive control to `excludesARowThatNeverRequiredAReversal`.

**Should also land in this pass** (all cheap, none risky): F-1 C (the `MAX_ITEMISED` test), F-4 (the
`JobLockId` uniqueness rail), F-5 (`verifyNoInteractions`), the two comment corrections in F-3, and items
2 and 3 from the untested table.
