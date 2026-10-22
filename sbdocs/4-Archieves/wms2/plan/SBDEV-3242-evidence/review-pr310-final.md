# SBDEV-3242 / PR #310 — review of the FINAL state

**Reviewer lane:** third independent lane. Scope: `git diff origin/develop...HEAD` at
`ed94713cec0408c6b25ff80f4ae3e1c801a9c6f6`, branch `bugfix/SBDEV-3242-repo-test-rollback-tx-manager`,
worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3242`.
4 files, +425/−12. Concentrated on the two commits no lane has seen: `5b233a99`
("apply review findings from two independent lanes") and the `ed94713c` merge of `origin/develop`.

**Date:** 2026-09-07. **Instruments used:** `javap -v -p` over all 1971 compiled
`target/test-classes` classfiles + a Python annotation parser (independent of ArchUnit, and of every
grep the author ran); bytecode superclass-chain walk for the hierarchy tallies; Spring Framework
6.2.15 **sources jars** (`spring-test`, `spring-tx`) for the resolution-order and synchronization
claims; `mvn -o test` on the merged tree.

---

## Verdict

> ⚠ **Read the POSTSCRIPT at the end first.** The working tree acquired uncommitted edits at 18:13:54,
> mid-review, that close M1–M4 and half of H1. This report grades the **committed** tip `ed94713c`,
> which is what PR #310 would merge. The postscript grades the working tree separately and says what
> is still owed there.

**Do not merge as-is** (committed tip `ed94713c`)**.** One new defect in the code (M1), two false statements pinned into a javadoc
that is explicitly meant to be authoritative (M2, M3), one incomplete sibling sweep that the PR's own
fix discipline required (M2), and a disclosed gap that turns out to be **imminent, not hypothetical**
(H1 — an unmerged branch already re-arms the exact defect while the new rail stays green).

The core fix itself — `@Transactional("tenantTransactionManager")` on
`BaseRepositoryIntegrationTest` — is **correct, minimal, and well-pinned**. The contract test is a
genuine two-instrument pin (mechanism + symptom) and both halves pass. Every numeric and structural
claim I could independently reproduce, reproduced (see "Claims that check out" — 14 of them, several
of which had been wrong in earlier revisions and are now right).

The blockers are all in the *rail* and the *prose*, not in the fix. M1 is a ~4-line change.

---

## Findings

### H1 — HIGH — the allow-list ratchet is one-directional, and the branch that breaks it is already written

**This is the gap the author disclosed. It is worse than disclosed.**

`theAllowListMustShrinkNotLinger()` fires only when an allow-listed entry's count **drops**. Nothing
fires when an allow-listed entry becomes newly *dangerous*. The `BasePostgresIntegrationTest` entry
(`TestClassTransactionManagerArchTest.java:105-106`) is justified with "cannot boot a context at all
today".

That justification expires on a branch that exists right now:

```
origin/bugfix/SBDEV-3239-integration-lane-runnable
  0984435e  SBDEV-3239 slice E (1/2): make BasePostgresIntegrationTest able to boot
```

On that branch the class gains `@ActiveProfiles("postgres-integration")` and **keeps the bare
`@Transactional`** (verified: `git show origin/bugfix/SBDEV-3239-integration-lane-runnable:src/test/java/net/aim_ai/wms/common/base/BasePostgresIntegrationTest.java`
lines 46-51), and its subclass count goes **6 → 16** — including the new real-Postgres concurrency
ITs (`StockunitBusinessServiceConcurrencyIT`, `PickingorderBusinessServiceConcurrencyIT`,
`UnitloadBusinessServiceConcurrencyIT`, `LockOverviewViewIT`, …). At that moment SBDEV-3242 is
reproduced at 16 classes against a real PostgreSQL, and this rail — the rail built to stop exactly
that — is green, because the count is still 1 and 1 is allowed.

**Is documentation the ceiling? No.** The justification for every entry is a machine-checkable
predicate. Concretely, add a fifth rule (~25 lines, no new dependency):

```java
@Test
@DisplayName("each allow-list entry's stated justification must still hold")
void allowListJustificationsMustStillHold() {
    JavaClass basePostgres = byName("net.aim_ai.wms.common.base.BasePostgresIntegrationTest");
    assertThat(basePostgres.isAnnotatedWith(ActiveProfiles.class))
        .as("BasePostgresIntegrationTest is allow-listed ONLY because it cannot boot a Spring "
          + "context (no @ActiveProfiles => landlord.datasource.jdbc-url unset => "
          + "LandlordDatabaseConfig throws). It now has @ActiveProfiles, so it boots and every "
          + "subclass inherits a bare @Transactional on the @Primary landlord manager. The "
          + "justification is void — qualify the annotation and delete the entry. See SBDEV-3242.")
        .isFalse();

    // SBDEV-3240 Category-A: allow-listed only because they are @Disabled.
    for (String c : List.of(
            "net.aim_ai.wms.integration.service.mobile.MobilePickingServiceIntegrationTest",
            "net.aim_ai.wms.integration.controller.rest.SkuRestControllerIntegrationTest",
            "net.aim_ai.wms.integration.service.mobile.MobileReplenishServiceIntegrationTest",
            "net.aim_ai.wms.integration.service.mobile.MobileTransferOrderServiceIntegrationTest",
            "net.aim_ai.wms.integration.service.mobile.MobilePutawayServiceIntegrationTest",
            "net.aim_ai.wms.integration.controller.rest.OrderRestControllerIntegrationTest")) {
        assertThat(byName(c).isAnnotatedWith(Disabled.class))
            .as(c + " is allow-listed only because it is @Disabled (SBDEV-3240). It is now "
              + "enabled, so its bare @Transactional is live. Qualify it.")
            .isTrue();
    }
}
```

Both predicates are already true today (verified by javap: all six Category-A classes carry
`@Disabled`; `BasePostgresIntegrationTest` carries no `@ActiveProfiles`), so this rule lands green
and flips red the day SBDEV-3239 or SBDEV-3240 lands. That is the whole ask.

Add a **blast-radius ceiling** alongside it as the general form, since `BaseIntegrationTest`'s
justification (a pom fact) is not annotation-checkable:

```java
private static final Map<String, Integer> MAX_SUBCLASSES = Map.of(
    "net.aim_ai.wms.common.base.BaseIntegrationTest", 13,
    "net.aim_ai.wms.common.base.BasePostgresIntegrationTest", 6);
// fail if a class carrying an allow-listed bare @Transactional grows new subclasses:
// "you are widening a known defect's blast radius; fix the annotation instead of allow-listing more."
```

Measured today: `BaseIntegrationTest` 13 descendants, `BasePostgresIntegrationTest` 6,
`BaseRepositoryIntegrationTest` 31 (bytecode superclass walk). The 6 → 16 growth trips this.

I would make **H1 gating**: the rail's stated purpose is "the debt cannot quietly become permanent",
and right now the debt can quietly become *bigger*, in a branch that is already written.

---

### M1 — MEDIUM — `nonTransactionalPropagationsMustBeDeclared()` reads only CLASS-level annotations, so the escape hatch it was added to close is still open at METHOD level

This rule is new in `5b233a99` and has never been reviewed. Its stated purpose (commit message, F2)
is that a `NOT_SUPPORTED` "would be **one token** to silence this rail", so the exempt set is pinned
exactly and "adding one is a visible edit".

It does not achieve that. `TestClassTransactionManagerArchTest.java:219-223`:

```java
Set<String> actual = testClasses.stream()
    .filter(c -> c.isAnnotatedWith(Transactional.class))                    // CLASS level only
    .filter(c -> runsNonTransactionally(c.getAnnotationOfType(Transactional.class)))
    .map(JavaClass::getName)
    .collect(Collectors.toCollection(TreeSet::new));
```

Meanwhile `currentViolations()` (line 270-274) **does** walk `c.getMethods()`, and `isBare()` returns
`false` for `NOT_SUPPORTED`/`NEVER` (line 256-258).

So: annotate a **test method** `@Transactional(propagation = Propagation.NOT_SUPPORTED)` and

* `noNewBareTransactionalInTests()` does not count it (exempt via `isBare`), and
* `nonTransactionalPropagationsMustBeDeclared()` cannot see it (class-level only).

One token, zero visible edits, rail green, and that method now commits every write it makes into the
shared H2 — the SBDEV-3242 symptom, reached by the exact route F2 says it closed. The gap is
load-bearing precisely because 9 of the 11 currently-allow-listed annotations are method-level, so
method-level `@Transactional` in tests is an established idiom here, not a hypothetical.

**Fix** — mirror `currentViolations()`'s shape:

```java
Set<String> actual = new TreeSet<>();
for (JavaClass c : testClasses) {
    if (c.isAnnotatedWith(Transactional.class)
            && runsNonTransactionally(c.getAnnotationOfType(Transactional.class))) {
        actual.add(c.getName());
    }
    for (JavaMethod m : c.getMethods()) {
        if (m.isAnnotatedWith(Transactional.class)
                && runsNonTransactionally(m.getAnnotationOfType(Transactional.class))) {
            actual.add(c.getName() + "#" + m.getName());
        }
    }
}
```

(Entry shape `Class#method` keeps the two kinds distinguishable in the frozen set; today the set is
unchanged — javap confirms **zero** method-level `NOT_SUPPORTED`/`NEVER` in `src/test`.)

**Sub-answers to the specific questions asked about this rule:**

* **Is `isEqualTo` on a `TreeSet` vs a `Set.of(...)` actually working?** Yes. `assertThat(Set<String>)`
  binds to `Assertions.assertThat(Iterable)` → `IterableAssert`, which does not override
  `isEqualTo`; it falls through to `AbstractAssert.isEqualTo` → `Objects.areEqual` →
  `actual.equals(expected)`. `TreeSet.equals` is `AbstractSet.equals` (instanceof Set + size +
  `containsAll`), and `containsAll` on a `TreeSet<String>` uses natural ordering, which is total for
  `String`. `Set.of(...)`'s `SetN.equals` is symmetric. It works, and the rule passed on a live run
  (4/4). It is however easy to *believe* is a reference comparison — `containsExactlyInAnyOrderElementsOf`
  would say the same thing with a far better failure message, and AssertJ's own docs discourage
  `isEqualTo` on an iterable assert. Cosmetic, but see L6.
* **Does it double-count with `noNewBareTransactionalInTests`?** No. `isBare()` short-circuits on
  `runsNonTransactionally`, so an exempt class can never appear in `currentViolations()`. The two
  rules partition cleanly. Verified against the live run: `PickingorderBusinessServiceH2Test` appears
  in the exempt set and in no allow-list entry.
* **Can it be defeated?** Yes — M1 above (method level). Also: it does not constrain
  `Propagation.SUPPORTS`, which is correct and deliberately documented, and it says nothing about a
  class that names the *wrong* manager (see L1).

---

### M2 — MEDIUM — the sibling sweep for the "local workaround" pattern was not done; the PR asserts a count that is wrong by 7, and deletes 1 of at least 8 instances

`5b233a99`'s commit body and the rail javadoc (`TestClassTransactionManagerArchTest.java:62-68`)
present `BillofladingServiceFinishTransferIT:52-55` as the **"Second local workaround found, after
`CyclecountRepositoryIntegrationTest`'s CC-TEST cleanup"**, and treat two instances as the corroborating
evidence that "the defect was understood here and never fixed at its source".

There are at least **nine**. Every one is a `@BeforeEach` that deletes its own fixture rows by literal
name before the test, i.e. the same workaround for the same leak:

| class | lines | shape |
|---|---|---|
| `integration/repository/CyclecountRepositoryIntegrationTest` | *(deleted by this PR)* | `findAll()` → delete `CC-TEST*` |
| `integration/repository/SyspropRepositoryIntegrationTest` | 37-40 | delete `TEST_KEY`, `TEST_KEY_1`, `TEST_KEY_2`, group `TEST_GROUP` |
| `integration/repository/LocationRepositoryIntegrationTest` | 38-41 | delete 4 literal `TEST-*` names |
| `integration/repository/ClientRepositoryIntegrationTest` | 42-43 | delete by `TEST_CLIENT_NUMBER` / `TEST_CLIENT_NAME` |
| `integration/repository/UserRepositoryIntegrationTest` | 34-35 | delete `test-user-001`, `test-user-002` |
| `integration/repository/PickingorderRepositoryIntegrationTest` | 40-41 | delete `PO-TEST-001`, `PO-TEST-002` |
| `integration/repository/PrinterRepositoryIntegrationTest` | 35-38 | delete by `TEST_PRINTER_TYPE` |
| `integration/repository/ReplenishorderRepositoryIntegrationTest` | 54 | filtered delete sweep |
| `integration/service/BillofladingServiceFinishTransferIT` | 52-56 | overrides the annotation instead |

All seven new ones are direct subclasses of `BaseRepositoryIntegrationTest`, i.e. exactly the class
this PR fixed, so by the PR's own AC-4 argument ("the rollback is real, and the helper is dead
weight") they are now dead weight too.

I am **not** asking for their removal in this PR — leaving them is harmless and the diff is already
the right size. Two things do need to change:

1. **The count claim is false.** "Second local workaround found" should be "one of at least nine"
   (or drop the number). This is the same class of error as the "38 assertions" that was 44, the
   "8 writers / 6 *IT" tally that did not reproduce, and the resolution order that was backwards —
   the fourth instance on this ticket of a precise-looking figure that does not survive an
   independent count.
2. **The invariant-over-instance rule was not applied.** The PR fixed the base class (good, that is
   the invariant) but then treated the workaround removal as a one-off. Either sweep them or state
   on the ticket that seven known-dead helpers are being left in place and why.

(For the avoidance of doubt: the *other* sweep this ticket owed — F3's three named siblings — I did
complete, and it is clean. See "Claims that check out" #11. It is only the workaround sweep that is
outstanding.)

---

### M3 — MEDIUM — two completeness claims in the contract test's pinned javadoc are false

`BaseRepositoryIntegrationTestRollbackContractTest.java:32-37` — rewritten by `5b233a99`, so
unreviewed — says:

> the row-count assertions in that lane are **all** scoped by a freshly-created parent id, so leaked
> rows cannot affect them. The unscoped ones live in the `integration/repository/*` classes, several
> dozen of them, and **none** is shaped to catch a foreign row either.

Both universals fail on the first counterexamples I looked for.

**"all scoped by a freshly-created parent id"** — `unit/repo/StockunitRepositoryTest.java:26,33`:

```java
su.setUnitloadId(100L);            // hard-coded literal, not a created parent
...
List<Stockunit> found = stockunitRepository.findByUnitloadId(100L);
assertThat(found).hasSize(1);
```

**"none is shaped to catch a foreign row"** — `integration/repository/SyspropRepositoryIntegrationTest.java:134-136`
and `:166-168`:

```java
List<Sysprop> found = syspropRepository.findByGroupname("TEST_GROUP");
assertThat(found).hasSize(2);
...
List<Sysprop> found = syspropRepository.findBySyskeyContaining("TEST_KEY");
assertThat(found).hasSize(2);
```

Those are exact counts over an unscoped literal predicate — they are *precisely* shaped to catch a
foreign row, which is why that class carries the `@BeforeEach` delete sweep listed in M2. The
javadoc's "none" and the file's own workaround are in direct contradiction, three files apart.

The **conclusion** the paragraph draws ("it went unseen because no assertion was shaped to notice
it") still survives — the leak-sensitive assertions were defused by hand-written cleanup helpers
rather than being absent. But the sentence as written is wrong, and it is in the file the PR
nominates as the authoritative record. Rewrite as: *"the assertions that could have caught it were
defused one by one with `@BeforeEach` cleanup helpers (see the nine listed on SBDEV-3242) rather than
traced to a cause; what remained was leak-tolerant."* That is both true and a better story.

Given the review history on this ticket, I would apply the two-instrument rule to any remaining
"all"/"none"/"every" in these four files before merge. I did not audit the other 71 assertions in
`integration/repository/*`; I found two counterexamples by checking the two shapes most likely to
break, and stopped.

---

### M4 — MEDIUM — the rewritten `BaseIntegrationTest` deferral names a blocker that Spring's own source says is not one

`TestClassTransactionManagerArchTest.java:54-59` — rewritten by `5b233a99` — states:

> **The blocker is `MessageCleanupBatchServiceIT`**, which captures and asserts on the NAME of the
> transaction the proxy opens … qualifying the base annotation could change what it observes

The quoted comment is real (`MessageCleanupBatchServiceIT.java:72`, verbatim). The risk is not.

Both captured values are manager-agnostic:

* `outerTxName` is the **test-managed** transaction's name, which
  `TestContextTransactionUtils.createDelegatingTransactionAttribute` sets to
  `TestClass.testMethod` regardless of which `PlatformTransactionManager` executes it.
* `innerTxName` is set by `AbstractPlatformTransactionManager.prepareSynchronization` →
  `setCurrentTransactionName(definition.getName())`, which runs iff
  `status.isNewSynchronization()`. From spring-tx 6.2.15 sources:
  * **today** (outer = landlord, inner = tenant `REQUIRES_NEW`): the tenant manager finds no existing
    tenant transaction, so `getTransaction` takes the no-existing-transaction path and calls
    `suspend(null)` (line 400). `suspend` with a null transaction still executes
    `doSuspendSynchronization()` and `setCurrentTransactionName(null)` (lines 616-624) whenever
    synchronization is active — so `isSynchronizationActive()` is false by the time
    `newTransactionStatus` computes `actualNewSynchronization` (line 566), and the inner name IS set.
  * **after the fix** (outer = tenant, inner = tenant `REQUIRES_NEW`): `isExistingTransaction` is
    true → `handleExistingTransaction` → `suspend(transaction)` → same clearing → same result.

Same in both worlds. The repository is a `@MockBean` in that IT, so the visibility change (the one
real consequence of the fix, cf. F3) cannot reach it either.

I could not *run* the class to prove this — it is `@Tag("postgres")` and runs in neither Maven lane —
so I am reporting a source-derived analysis, not a measurement. But the rewrite replaced one wrong
directional claim (the resolution order) with another one that also does not survive reading the
source. The honest form is: *"the risk is believed nil on reading `AbstractPlatformTransactionManager`
— the captured names do not depend on which manager runs; it is deferred only because the class runs
in neither lane and 'believed nil' is not 'measured nil'."* Same decision, defensible reason.

Note this **strengthens** the case for fixing `BaseIntegrationTest`, and weakens the case for keeping
its allow-list entry — which interacts with H1.

---

### M5 — MEDIUM — the PR's headline evidence figure is stale after the `ed94713c` merge, and no post-merge run is recorded

`5b233a99`'s commit message ends:

> Suite: 6325 run (6318 + 3 contract + 4 rail), 6 failures, 26 skipped. The 6 are the pre-existing
> `StockunitServiceUnitTest` set (SBDEV-3226).

`ed94713c` then merged `origin/develop`, which contains `21222f0c SBDEV-3226: update 6 stale
assertions to match the new lock messages`. The merge diff is exactly that one file
(`StockunitServiceUnitTest.java`, +15/−6) — it touches none of the four files under review, so
nothing in the diff went stale. But the **only recorded suite evidence describes a tree that no
longer exists**, and its merge message says "the suite should now be fully green" — a prediction, not
a measurement.

I ran it on the merged tree (`mvn -o test`, JDK 21.0.11-ms, this worktree, no other Maven running
in it):

```
[WARNING] Tests run: 6325, Failures: 0, Errors: 0, Skipped: 26
[INFO] BUILD SUCCESS
```

with `TestClassTransactionManagerArchTest` **4/4** and
`BaseRepositoryIntegrationTestRollbackContractTest` **3/3**. So the prediction holds — 6325 run,
**0 failures** (the 6 are gone), 26 skipped. Put this figure on the PR in place of the stale one; the
one currently recorded says "6 failures" and a reader comparing it to a fresh run will think
something changed.

**A second instrument fell out of this run for free.** `noNewBareTransactionalInTests` green means
`actual <= allowed` for every entry, and `theAllowListMustShrinkNotLinger` green means
`actual >= allowed` — together, `actual == allowed` exactly, for all 8 classes. That is ArchUnit
independently confirming the javap census in "Claims that check out" #1. Two instruments, agreeing.

**And I ran the lane that actually exercises AC-4**, which `mvn test` cannot:
`CyclecountRepositoryIntegrationTest` is excluded from surefire by name, so **nothing in the recorded
6325-test evidence touches the change this PR makes to it.**

```
mvn -o verify -Dit.test='*RepositoryIntegrationTest' -Dtest=ZzzNone \
    -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.test.failure.ignore=true
[ERROR] Tests run: 135, Failures: 0, Errors: 13, Skipped: 28
```

* **`CyclecountRepositoryIntegrationTest`: 21 run, 0 failures, 0 errors, 3 skipped, across all nine
  `@Nested` classes.** AC-4 is now genuinely verified — with the `cleanupTestData()` workaround
  deleted, the class is green because the rollback is real. This is the single most important
  measurement in the PR and it was missing; add it to the PR body.
* The 13 errors are **all** `ClientRepositoryIntegrationTest`, all the same cause:
  `No qualifying bean of type 'org.springframework.jdbc.core.JdbcTemplate'` while creating the test
  instance's own `@Autowired JdbcTemplate` field (`ClientRepositoryIntegrationTest.java:33`).
  **Not caused by this diff**: that file is not in the diff (last touched on `origin/develop` by
  `b907f20f`, SBDEV-3241), and a transaction-manager *qualifier* cannot make a `JdbcTemplate` bean
  definition appear or disappear. It is the condition `origin/bugfix/SBDEV-3239-integration-lane-runnable`
  fixes in `15ed8e04 "slice C: give the H2 test context a JdbcTemplate"`. I did not run
  `origin/develop` to prove it pre-exists, so I am asserting structural independence, not a measured
  A/B — worth one line on the PR either way, because a reader running this lane will otherwise think
  the PR broke it.

---

### L1 — LOW — the rail permits a test that names the *wrong* manager, and does not list that among its blind spots

`isBare()` returns `false` as soon as `value` or `transactionManager` is non-empty. A test annotated
`@Transactional("landlordTransactionManager")` over `net.aim_ai.wms.repo.jpa` repositories reproduces
SBDEV-3242 exactly and passes all four rules. The javadoc's "What this rail cannot see" list
(lines 72-85) names meta-annotations, `jakarta.transaction.Transactional`, and
`@Commit`/`@Rollback(false)` — all three verified at zero uses — but not this one, which is the
closest neighbour of the defect the file is named after.

Cheap and probably correct to close rather than document, given `landlordTransactionManager` is
almost never right for a test: add to `currentViolations()` a second bucket for
`"landlordTransactionManager".equals(value|transactionManager)` on classes outside
`net.aim_ai.wms.landlord`, allow-listed at zero (measured: zero today).

### L2 — LOW — the rail grades `target/test-classes`, not source, and says so nowhere

The importer matches `location.contains("/test-classes/")`. A stale `target` therefore produces both
false greens (a fixed source whose old classfile lingers) and false reds (a deleted test class still
on disk — a known trap in this repo). One sentence next to `importTestClasses()`: *"reads compiled
bytecode; run after `mvn test-compile`, and prefer `mvn clean test` when classes have been deleted."*

### L3 — LOW — `hasSizeGreaterThan(1500)` is a reasonable floor, but it is one-sided

Measured: **1971** classfiles under `target/test-classes/net/aim_ai/wms` (488 top-level + inner /
`@Nested` / anonymous). ArchUnit imports all of them, so 1500 is a 24 % shrink margin — sane, and a
real improvement on the old 500 (F10). Two caveats worth one line each: (a) it cannot detect the
importer accidentally *widening* to `src/main` (that would raise the count, and only the
`endsWith("BaseRepositoryIntegrationTest")` positive control constrains that, weakly); (b) it is a raw
classfile count, so a refactor that inlines anonymous classes moves it for reasons unrelated to test
coverage. Neither is worth changing today.

### L4 — LOW — the `nonVacuityGuard`'s qualified-count duplicates `isBare`'s logic instead of sharing it

`nonVacuityGuard()` lines 160-164 open-code `!t.value().isEmpty() || !t.transactionManager().isEmpty()`.
The F1 fix is right — asking directly is the point, and the comment at 157-159 explains why it must
NOT be `!isBare(...)`. But it is now a second, independent definition of "qualified", and it counts
**class-level only**. Measured today it returns **7** (`BaseRepositoryIntegrationTest`,
`BillofladingServiceFinishTransferIT`, `CustomerorderBatchServiceParallelStreamRegressionIT`,
`ParcelMonitorViewServiceConcurrencyIT`, `ReplenishmentOrderMaintenanceServiceIntegrationTest`,
`SequenceTransactionServiceConcurrencyIT`, `WarehouseStockReportServiceStreamIT`), so
`isGreaterThanOrEqualTo(1)` is **genuinely non-vacuous** — F1 is fixed. Extracting
`private static boolean namesAManager(Transactional)` and using it in both places would keep them
from drifting.

### L5 — LOW — five LOW findings from the previous lanes were silently not applied

`review-code.md` raised 17. `5b233a99` addresses F1-F10, F14, F15 and rewrites the F6/Claim-6
material. **F11** (`ALLOWED` keys are `Outer$Inner` for `@Nested`), **F12** (the rail depends on
ArchUnit reporting *declared* annotations even though Spring's `@Transactional` is `@Inherited` —
load-bearing and unstated), **F13** (the `CyclecountRepositoryIntegrationTest` comment still claims
"removing it is a check that the fix works", which it is not — every assertion in that class is
leak-tolerant; I re-verified all 6), **F16** (the outer test transaction now holds real tenant row
locks — see L7), and **F17** (the stray `@Order(1)`, the block comment wedged between annotations,
and the class javadoc still saying *"Follow the naming convention `*IntegrationTest.java`"* which 22
of 31 subclasses do not) are all still open, and the commit message does not mention declining them.
Per the standing rule that Low findings get fixed in the same pass, each needs either a fix or an
explicit "not doing this, because".

F12 in particular is worth the one comment it asks for: if ArchUnit ever followed `@Inherited`, all
31 `BaseRepositoryIntegrationTest` subclasses and all 13 `BaseIntegrationTest` subclasses would
appear as violations at once and the failure would be unreadable.

### L6 — LOW — assertion-style nits in the new rule and the contract test

* `nonTransactionalPropagationsMustBeDeclared()`: `containsExactlyInAnyOrderElementsOf(EXEMPT_NON_TRANSACTIONAL)`
  gives a diff ("unexpected: […], missing: […]") where `isEqualTo` gives two whole-set toString dumps.
  Same semantics here, much better failure output — and it removes the "is this comparing by
  reference?" question entirely.
* `BaseRepositoryIntegrationTestRollbackContractTest:83` uses
  `TransactionSynchronizationManager.getResourceMap().keySet()`. Stability: fine —
  `getResourceMap()` is public, not deprecated in 6.2.x, and returns the thread-bound resource map
  whose key for `JpaTransactionManager` is the `EntityManagerFactory` it was constructed with
  (`doBegin` binds eagerly, before the test body, so there is no lazy-binding race). Flakiness risk is
  low but non-zero: the assertion depends on the injected `@Qualifier("tenantEntityManagerFactory")`
  bean being the *same instance* the manager binds, which `bindResource`'s
  `unwrapResourceIfNecessary` could disturb if the EMF ever became an `InfrastructureProxy`. The
  documented accessor says the same thing more directly and survives that:
  `assertThat(TransactionSynchronizationManager.getResource(tenantEntityManagerFactory)).isNotNull()`
  plus the landlord `isNull()`. Keep the `getResourceMap()` form only if you want the "what IS bound"
  detail in the failure message — in which case say so in a comment.
* `PROBE_NAME`'s javadoc says *"The number is unique to this class"* — it is a name (used for both
  `setName` and `setNumber`). Cosmetic.

### L7 — LOW — carried forward from F16, and now more relevant: the fix hands the outer test transaction real tenant row locks

Before: the test-managed transaction was a landlord transaction holding nothing the tenant code
touches, so a `REQUIRES_NEW` sub-transaction in a service under test always saw a clean, committed
database. After: the outer transaction holds uncommitted rows and, on the paths that take them,
`FOR UPDATE` locks — while the suspended `REQUIRES_NEW` sub-transaction opens a **second**
connection and can contend for the same rows. 26 classes in `src/main` use `REQUIRES_NEW`;
31 classes extend the fixed base.

Nothing fails today (the suite run below is the evidence), and the failure mode is a lock timeout
rather than a clean red, so it will not announce itself. I raise it again only because M4 above
argues for fixing `BaseIntegrationTest` too, and H1's `BasePostgresIntegrationTest` case would put
this shape on a **real PostgreSQL**, where — unlike H2 — there is no short default lock timeout to
convert a deadlock into a fast failure. Worth one sentence in the contract test's javadoc so the
next person debugging an intermittent lock timeout in a repository test finds the cause in one hop.

### L8 — LOW — cross-reference drift on the `BasePostgresIntegrationTest` entry

The rail says "SBDEV-3239 AC-1 owns that file"; the file's own in-place TODO says `SBDEV-2217`
(`BasePostgresIntegrationTest.java:23`), and the SBDEV-3239 branch's rewritten javadoc says SBDEV-2217
is Closed and unrelated. Both statements are defensible, but a reader following the rail's pointer
lands on a comment naming a different, closed ticket. One clause: *"(the file's own TODO still cites
SBDEV-2217, which is closed and unrelated — SBDEV-3239 AC-1 replaces it)."*

---

## Claims that check out

Independently reproduced, all with instruments other than the ones the author used
(javap bytecode scan / bytecode superclass walk / Spring sources jar):

1. **`ALLOWED` is exactly right** — 11 bare `@Transactional` across 8 classes, and every per-class
   count matches: `BaseIntegrationTest` 1, `BasePostgresIntegrationTest` 1,
   `MobilePickingServiceIntegrationTest` 3, `SkuRestControllerIntegrationTest` 2,
   `MobileReplenishServiceIntegrationTest` 1, `MobileTransferOrderServiceIntegrationTest` 1,
   `MobilePutawayServiceIntegrationTest` 1, `OrderRestControllerIntegrationTest` 1. Derived from
   `javap -v -p` over all 1971 classfiles, decoding annotation attributes rather than matching text —
   so it is immune to the fully-qualified-annotation blind spot that made the author's greps wrong
   three times.
2. **"The nine method-level ones"** — exactly 9, all method-level, all in the six SBDEV-3240 classes,
   and all six carry `@Disabled`.
3. **`EXEMPT_NON_TRANSACTIONAL` is exactly right** — `PickingorderBusinessServiceH2Test` is the only
   `NOT_SUPPORTED`/`NEVER` in `src/test`, class or method level. (And its own `@BeforeEach`
   `deleteAll()` sweep corroborates the javadoc's "leaks its writes by design".)
4. **F1's non-vacuity fix is real** — 7 class-level properly-qualified `@Transactional` in `src/test`
   (list in L4). The old `!isBare(...)` form would indeed have passed on the single `NOT_SUPPORTED`
   class alone.
5. **F4's corrected resolution order is right, and the old one was backwards.**
   `spring-test-6.2.15-sources` → `TestContextTransactionUtils.retrieveTransactionManager` lines
   164-217: explicit qualifier → single `TransactionManagementConfigurer` → single
   `PlatformTransactionManager` by type → `bf.getBean(PlatformTransactionManager.class)` (honours
   `@Primary`) → **last** `bf.getBean("transactionManager", …)`. Supporting facts verified in-repo:
   exactly two `PlatformTransactionManager` beans (`LandlordDatabaseConfig:60-62` carries `@Primary`;
   `TenantDatabaseConfig:74-75`), zero `TransactionManagementConfigurer`, zero beans named
   `transactionManager`, and `TestDatabaseConfig` adds no third. So the name lookup is unreachable and
   "defining such a bean would NOT have fixed this" is correct.
6. **The routing half** — `TenantDatabaseConfig:22-26` binds `net.aim_ai.wms.repo.jpa` with
   `transactionManagerRef = "tenantTransactionManager"`. The causal chain holds end to end.
7. **The `BaseIntegrationTest` subclass tally now reproduces** — 13 descendants, 10 direct + 3 through
   the abstract `BaseControllerIntegrationTest`. (Bytecode superclass walk. The earlier "10 subclasses
   / 7 writers / 6 *IT" tally did not reproduce; this one does.)
8. **"6 already declare their own qualified `@Transactional`, five written fully qualified"** — exact.
   The six: `BillofladingServiceFinishTransferIT`, `CustomerorderBatchServiceParallelStreamRegressionIT`,
   `ParcelMonitorViewServiceConcurrencyIT`, `ReplenishmentOrderMaintenanceServiceIntegrationTest`,
   `SequenceTransactionServiceConcurrencyIT`, `WarehouseStockReportServiceStreamIT`; the last is the
   only one using the imported short form, the other five use
   `@org.springframework.transaction.annotation.Transactional`.
9. **"The two real writers that DO inherit the bare annotation"** — correct.
   `AdviceServiceIntegrationTest` (7 repository writes) and `CustomerOrderControllerIntegrationTest`
   (4); the other bare-inheriting descendants (`BaseControllerIntegrationTest`,
   `SdrReadGateEnforcementContextTest`, `WebContextLaneContextTest`, `IdempotencyFilterIT`,
   `MessageCleanupBatchServiceIT`) write nothing through a repository. And both writers do run in
   failsafe: `pom.xml:709-712` includes `**/*IntegrationTest.java` and `**/*E2ETest.java`.
10. **`MessageCleanupBatchServiceIT` runs in neither lane** — `pom.xml:564-567` (surefire excludes
    `*IntegrationTest`/`*E2ETest`) and `:709-712` (failsafe `<includes>` overrides the `**/*IT.java`
    default). Confirmed, and the pom's own SBDEV-3091 block says so.
11. **F3's coverage-loss disclosure is accurate.**
    `MessageRepositoryIntegrationTest:272` is `isGreaterThanOrEqualTo(0)` and `:296-297` are
    `isLessThanOrEqualTo(2)`; `MessageCleanupBatchService.deleteOnce` is
    `@Transactional(value = "tenantTransactionManager", propagation = REQUIRES_NEW)`. Post-fix the
    seeds are uncommitted in the outer tenant transaction and the suspended sub-transaction sees none,
    both counts fall to 0, and both assertions stay green. Recording it rather than fixing it is the
    right call for this PR. **I completed the sibling sweep the commit message deferred, and it is
    clean**: of the three named siblings, `MobileReplenishServiceH2Test` calls only `loadOrderById` /
    `startOrder`; `CustomerorderServiceTest` calls `batchUpdatePriorityByOrderIds`, `setPriority`,
    `getCustomerOrderDetails`; `AdviceServiceH2Test` calls `fixHubAndSpokePalletIssues`,
    `setPurchaseOrderNumber`, `getAdviceDetails`. **None of those six service methods is
    `REQUIRES_NEW`** — they are `@Transactional(value = "tenantTransactionManager", …)` REQUIRED or
    unannotated (`CustomerorderService.java:497,505,197`; `AdviceService.java:144,462,474`), so they
    join the outer test transaction and see the seeds. No second instance of the F3 shape exists in
    the three named classes. Worth recording on the ticket so nobody re-opens it.
12. **The three stated blind spots are all genuinely zero-use today** — `jakarta.transaction.Transactional`:
    0 (bytecode scan). `@TenantTransactional` / `@TenantTransactionalReadOnly` in `src/test`: 5 hits,
    all javadoc/string literals, 0 real usages — and both meta-annotations do hard-code
    `tenantTransactionManager` (`config/TenantTransactional.java:26`,
    `config/TenantTransactionalReadOnly.java:16`), so the gap can only miss *correct* usage as claimed.
    `@Commit` / `@Rollback`: 1 hit, which is this rail's own javadoc.
13. **F5's corrected lane framing is right** — of the 31 `BaseRepositoryIntegrationTest` descendants,
    22 run in surefire on every build (names ending `Test`/`H2Test`/`ContractTest`) and 9 in failsafe
    (`*RepositoryIntegrationTest`). "Most subclasses … run on every build" is accurate, and the
    dropped "invisible because failsafe never runs" framing was indeed wrong. `"several dozen"`
    unscoped assertions in `integration/repository/*` is also honest — 71 across the nine subclass
    files by `hasSize|isEmpty()|isNotEmpty()`.
14. **`TransactionManagerArchTest` really is out of scope on both axes** —
    `TransactionManagerArchTest.java:43-44` uses `DO_NOT_INCLUDE_TESTS` and
    `importPackages("net.aim_ai.wms.service")`, and its rule is `methods()`. The "a guard fences the
    mechanism its author aimed at, not the invariant" framing is earned.
15. **The merge is clean and narrow** — `ed94713c` brings in exactly `StockunitServiceUnitTest.java`
    (+15/−6). None of the four files under review changed after `5b233a99`, and no comment in them
    references the SBDEV-3226 baseline, so F15's removal did its job. No parallel JUnit execution is
    configured (no `junit-platform.properties`, no surefire `parallel`), so the contract test's
    `@Order(2)`/`@Order(3)` pair is safe.

---

## What I would require before merge

**Gating:**

1. **H1** — add the justification-predicate rule (and ideally the subclass-count ceiling). The
   SBDEV-3239 branch is written; without this the rail is green through the regression it exists to
   prevent.
2. **M1** — extend `nonTransactionalPropagationsMustBeDeclared()` to method level. ~6 lines. Without
   it, F2 is not actually fixed.
3. **M3** — correct the two false universals in the contract test's javadoc.
4. **M5** — record a post-merge suite run and the AC-4 failsafe run (both are in this report, ready
   to paste); the only figure currently on the PR describes a tree that no longer exists, and no
   recorded run exercises AC-4 at all.

**Should fix in the same pass (per the standing "fix the Lows too" rule):**

5. **M2** — correct "Second local workaround found" and either sweep or explicitly defer the seven
   remaining `@BeforeEach` cleanup helpers.
6. **M4** — restate the `MessageCleanupBatchServiceIT` blocker as "believed nil on reading the
   source, but unmeasured because the class runs in neither lane".
7. **L5** — F11, F12, F13, F16, F17: apply or explicitly decline, on the record.

**Nice to have:** L1, L2, L4, L6, L8.

**Not blocking and explicitly endorsed:** the fix itself, the contract test's two-instrument design,
the deletion of `cleanupTestData()`, the `NOT_SUPPORTED`/`NEVER` exemption's reasoning, the
`SUPPORTS`-is-not-exempt decision, and the decision to record rather than repair the
`MessageRepositoryIntegrationTest` coverage loss.

---

## What I did not verify

* I did not run `MessageCleanupBatchServiceIT` (M4 is source-derived, not measured — the class is
  `@Tag("postgres")` and runs in neither Maven lane).
* I ran the failsafe lane only for `*RepositoryIntegrationTest` (135 tests), not the whole lane, so
  I have not re-done the author's full failsafe A/B.
* I did not perform a live mutation of the rail (no repo mutations were permitted in this lane), so
  M1 is derived from reading the two rules' code, not from watching a planted method-level
  `NOT_SUPPORTED` slip through. The reading is unambiguous: rule 4 calls only
  `c.getAnnotationOfType(...)`.
* I did not audit all 71 unscoped assertions in `integration/repository/*` — M3 reports two
  counterexamples found by checking the two most likely shapes, not an exhaustive census.


---

## POSTSCRIPT — the working tree changed under me at 18:13:54, mid-review

**Read this before acting on anything above.** Everything in this report was derived against
**`ed94713c`, the committed tip of PR #310**, which is what I was asked to review. While I was
writing it, two of the four files acquired **uncommitted** modifications:

```
 M src/test/java/net/aim_ai/wms/common/base/BaseRepositoryIntegrationTestRollbackContractTest.java
 M src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java
HEAD still ed94713cec0408c6b25ff80f4ae3e1c801a9c6f6
```

I did not make these edits and did not revert them. **My measurements are unaffected**: `mvn test`
compiled at 18:03 and finished at 18:09; the failsafe lane compiled at ~18:12:50 and wrote its
reports at 18:13:25–18:13:27. Both predate the 18:13:54 mtimes, so both graded the committed tree.

**What the uncommitted edits do**, and how much of this report they close:

| finding | status in the working tree |
|---|---|
| **M1** (method-level `NOT_SUPPORTED` hole) | **fixed** — rule 4 now mirrors `currentViolations()`, walking `c.getMethods()` and keying method entries `Class#method` |
| **M3** (two false universals) | **fixed** — and the retraction is stated in place, which is the right call |
| **M2** (workaround count) | **fixed** — "at least NINE places, not the two an earlier draft claimed", all seven remaining named, and the decision to leave them stated explicitly rather than silently |
| **M4** (the "blocker" that is not one) | **fixed** — reworded to "residual risk … the risk looks like nil … the deferral rests on 'unmeasured', not on 'known to break'" |
| **H1** (ratchet is one-directional) | **partially fixed** — a new `allowListJustificationsMustStillHold()` pins `BasePostgresIntegrationTest` has no `@ActiveProfiles` and all six SBDEV-3240 classes are `@Disabled`, with a `byName()` helper that throws rather than passing vacuously if an entry vanishes. **The `BaseIntegrationTest` entry still has no expiry check** — its justification is a pom fact, which is why I also recommended the subclass-count ceiling; that half is not in. |
| **M5** (stale evidence figure) | not addressed (it lives in the commit message / PR body, not a file) |
| **L1, L2, L4, L5, L6, L8** | not addressed |

**I ran the modified files** (one Maven invocation, this worktree):

```
mvn -o test -Dtest='TestClassTransactionManagerArchTest,BaseRepositoryIntegrationTestRollbackContractTest'
[INFO] Tests run: 5, ... -- in TestClassTransactionManagerArchTest
[INFO] Tests run: 3, ... -- in BaseRepositoryIntegrationTestRollbackContractTest
[INFO] Tests run: 8, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

They compile and pass — rail 4 → **5** rules, contract 3/3 — and the new rule is **not vacuous**:
it passed because both predicates are genuinely true today (`BasePostgresIntegrationTest` carries no
`@ActiveProfiles`; all six Category-A classes carry `@Disabled`), and `byName()` throws on a missing
class rather than skipping it.

**What is still owed on the working-tree version:**

1. **It is uncommitted, so it is not in PR #310.** As things stand a merge of #310 ships `ed94713c`,
   which still has M1, M2, M3, M4 and all of H1 in it.
2. **The full suite has not been run against it.** I ran 8 tests, not 6325. Rule 4's widening is a
   scan over every method of all 1971 classes — cheap, and my javap census says the exempt set is
   unchanged (zero method-level `NOT_SUPPORTED`/`NEVER` anywhere in `src/test`), so I expect green;
   but expecting is not measuring, and this ticket's history is a list of confident expectations that
   did not survive an instrument.
3. **`import java.util.stream.Collectors;` (line 23) is now unused** — rule 4 no longer streams.
   Remove it.
4. **A javadoc line now overruns** — the sentence ending `…do not repeat it as the latter. Closing
   this: fix the base class, re-run failsafe, …` is one long line in a file otherwise wrapped near
   100 columns. Re-wrap.
5. **H1's remaining half.** Add the blast-radius ceiling so `BaseIntegrationTest`'s entry is covered
   too:
   `MAX_SUBCLASSES = { BaseIntegrationTest: 13, BasePostgresIntegrationTest: 6 }`, failing when a
   class carrying an allow-listed bare `@Transactional` grows new subclasses. Measured today: 13 and
   6. On the SBDEV-3239 branch the second becomes 16 — which is the case that motivated H1 in the
   first place, and the `@ActiveProfiles` predicate happens to catch it, but only by coincidence of
   *that* branch's implementation. A branch that made those 16 classes boot some other way would slip
   past the predicate and be caught by the ceiling.
6. **L5 is still open** — F11, F12, F13, F16, F17 from the earlier lanes remain unapplied and
   undeclined, and F13's specific artefact (the "removing it is a check that the fix works" claim) is
   in `CyclecountRepositoryIntegrationTest`, a file the working tree has *not* modified.

**Revised bottom line.** Against the committed tip, the verdict at the top stands: do not merge.
Against the working tree, the four Medium findings and most of the High are closed and the result is
close to mergeable — but it needs to be **committed**, needs a **full-suite run**, needs the two
one-line nits (3, 4) and H1's second half, and still owes the five Low findings from the earlier
lanes an answer.
