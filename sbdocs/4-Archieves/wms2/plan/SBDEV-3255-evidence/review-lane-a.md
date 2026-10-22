# SBDEV-3255 — Review Lane A (correctness)

**Scope:** the working-tree change in `.claude/worktrees/wms2-api/SBDEV-3255` (base `c4d920eb`):
`pom.xml`, 5 touched test classes, 1 new test class.
**Mode:** read-only. No maven, no git writes, no edits. Everything below is derived from the
files on disk plus the diff at `SBDEV-3255-evidence/implementation.diff`.

**Verdict: do not merge as-is.** The pom wiring is sound and well-reasoned. The rail is a real
rail with real value. But (1) the `DeleteMessages` rewrite commits a `user` row it never sweeps
and commits *more* on the failure path, in the one lane this repo has a dedicated rail against
committing in; (2) the two assertions still cannot see a `refDate`-ignoring mutant; (3) the rail
has a false-GREEN vector that is precisely the defect class it exists to prevent; and (4) the
change left a stale javadoc paragraph carrying a run command that the same commit's new
paragraph contradicts.

---

## HIGH

### H1 — `BillofladingServiceFinishTransferPerformanceIT`: the old javadoc paragraph survived, and its run command is now actively wrong

The class javadoc now contains **two** policy paragraphs. The new one (added by this change) says
the class is on-demand *"by POLICY rather than by `@Disabled`"*. Twenty lines above it, untouched,
still stands:

```
 * <p><b>Disabled by default.</b> CI runs the unit tests + the G1 integration
 * test (delta invariant) ... Run it explicitly:
 * <pre>
 *   mvn test -Dtest=BillofladingServiceFinishTransferPerformanceIT \
 *            -Dgroups=performance
 * </pre>
```

Three separate defects, all *created or worsened* by this commit:

1. **"Disabled by default" is now false** — `@Disabled` was removed in this very diff. A reader
   hitting this paragraph first concludes the annotation is still there.
2. **`-Dgroups=performance` is now harmful, not merely useless.** Before this change `groups` read
   nothing. After it, `groups` is an *inclusion* filter and — by the new pom comment's own
   research — `groups` is *"the shared user property of BOTH plugins"*. So `-Dgroups=performance`
   restricts the **surefire** lane to performance-tagged tests (there are none) while doing
   nothing at all to lift the failsafe exclusion. It is the exact cross-plugin trap the new
   `<properties>` comment was written to warn against, left standing 20 lines above that warning.
3. **`mvn test` is the wrong lane** for an `*IT`, and it contradicts the corrected recipe the same
   commit adds below (`mvn verify -Dfailsafe.excludedGroups= -Dit.test=…`).

This repo's own precedent (`wms2-flyway-migration-facts-corrected`, and the pom's SBDEV-3257
correction block) is that a surviving false claim beside a new true one is worse than either
alone. **Fix:** delete or rewrite the "Disabled by default" paragraph in the same commit.

### H2 — the `@AfterEach` sweep **commits** on the failure path, permanently

```java
@AfterEach
void sweepCommittedRows() {
    if (TestTransaction.isActive()) {
        TestTransaction.flagForCommit();
        TestTransaction.end();
    }
    messageCleanupBatchService.deleteOnce(...);
}
```

`TestTransaction.isActive()` is **only** true when the test threw before reaching its own
`TestTransaction.end()` — i.e. on failure. On that path the seeds are still *uncommitted*, and
this block chooses to **commit them** before sweeping. That is strictly worse than the
alternative in every respect:

* `TestTransaction.end()` **without** `flagForCommit()` rolls back — the seeds vanish, the
  `user` row vanishes with them (see M1), locks release, and the subsequent `deleteOnce` has
  nothing to do. Same lock-release effect, zero residue.
* As written, a failing test leaves committed rows behind *and* re-runs a DELETE over them,
  turning a red test into a data-writing operation against the shared H2 database.

There is no scenario in which the commit is the desired behaviour here: the success path already
committed *inside the test body*, so this branch is failure-only. **Fix:** drop
`flagForCommit()` from the `@AfterEach` (keep `end()`).

### H3 — the rail counts a group as "wired" without regard to **which lane** filters it

`wiredGroups()` scans the whole `pom.xml` for `<groups>|<excludedGroups>` with no notion of which
plugin the element belongs to:

```java
Matcher groups = POM_GROUPS.matcher(pom);
while (groups.find()) { addAll(wired, resolve(groups.group(1).trim(), properties)); }
```

`<excludedGroups>` exists **only on maven-failsafe-plugin**. Surefire has none. So today:

* `@Tag("performance")` on a **unit** test (`*Test`, surefire lane) → rail says WIRED → test runs
  anyway. False GREEN, and it is silent, and it is exactly the "annotation that looks like policy
  and is inert" defect the rail's own javadoc says it exists to prevent.
* The inverse also holds: a group wired only in `<groups>` (an *inclusion* filter, opposite
  semantics) counts identically to one in `<excludedGroups>`.

This matters concretely for the next step this repo has already planned: the develop workflow
comment says *"tag every IT that starts threads or asserts on elapsed time"* — a mix of `*IT`
and `*IntegrationTest` classes, all in the failsafe lane, so it happens to be safe. The first
unit-lane tag is the one that gets through. **Fix:** parse the enclosing
`<artifactId>maven-failsafe-plugin</artifactId>` / `maven-surefire-plugin` block and record
`(lane, group)`; then check each tag against the lane its owning class actually runs in
(derivable from the class name against the pom's `<includes>`/`<excludes>`). At minimum, state
the limitation in the "blind spots" list, which currently does not mention it.

---

## MEDIUM

### M1 — the sweep reclaims `message` rows but leaks the committed `user` row

`BaseRepositoryIntegrationTest.setUp` → `MessageRepositoryIntegrationTest.setUp()` runs *inside*
the test transaction and may insert the operator:

```java
testOperator = userRepository.findByName("admin")
    .orElseGet(() -> { User user = new User(); ... return userRepository.save(user); });
```

Both `DeleteMessages` tests then call `TestTransaction.flagForCommit(); TestTransaction.end();`,
which commits **everything the transaction holds** — the messages *and* that `user` row. The
`@AfterEach` sweeps only `message`. The `admin` user is therefore committed into the shared H2
database for the remaining life of the JVM.

The repo already knows this hazard by name.
`BaseRepositoryIntegrationTestRollbackContractTest`'s javadoc is about precisely this:
*"…which is what makes count assertions in sibling repository tests…"*, and it names
`SyspropRepositoryIntegrationTest:134,166` as asserting *"exact counts over unscoped literal
predicates"*.

I checked for a currently-breaking sibling and **did not find one**:
`UserRepositoryIntegrationTest:143 assertThat(found).hasSize(2)` is scoped by
`findByPrinterId(999L)` and the leaked admin has a null `printerId`; the `hasSize()` assertions in
`MessageRepositoryIntegrationTest` (152, 251, 440) are page-size bounds. So this is latent, not
live. It is still a Medium because the leak is undeclared and the next unscoped `user` count
assertion inherits a mystery failure.

**Fix (pick one):** sweep the operator too; or adopt the pattern this repo has already declared
for leaking tests — `@Transactional(propagation = NOT_SUPPORTED)` as `IdempotencyFilterIT` does,
plus an entry in `TestClassTransactionManagerArchTest.EXEMPT_NON_TRANSACTIONAL`.

### M2 — `TestTransaction.flagForCommit()` is a second, undeclared way to leak, invisible to the SBDEV-3242 rail

`TestClassTransactionManagerArchTest` has a rule *"a NOT_SUPPORTED/NEVER test class must be
declared — it leaks its writes by design"*, keyed on the **annotation**. This change introduces a
class that leaks its writes by design through `TestTransaction.flagForCommit()` instead, so the
rail cannot see it and nothing forced the author to declare it. That rail's blind-spot list should
gain a `flagForCommit` clause, or the rule should scan for the call. Worth raising in the same
ticket because SBDEV-3255 is the commit that creates the first instance.

### M3 — the two `DeleteMessages` assertions still cannot see a `refDate`-ignoring mutant

`shouldDeleteOldMessages` now asserts:

```java
assertThat(deleted).isPositive();
assertThat(messageRepository.findById(saved.getId())).isEmpty();
```

Both survive a mutant that deletes the `WHERE m.created < :refDate` predicate entirely (delete
everything → `deleted` still positive, the seeded row still gone). Given the ticket's whole
subject is "an assertion that passed on a DELETE that removed nothing", shipping the replacement
without a **survivor control** is the same failure one notch up. Neither test seeds a *recent*
message and asserts it is still there afterwards.

`deleteMessages_respectsBatchSizeLimit` has the same gap plus a second: after `2 + 2` deletions it
never asserts that **one** of the five survives, so a mutant that ignores `LIMIT` on the *second*
call only (`5` then `0`) is caught, but one that deletes the fifth row as a side effect is not.

**Fix:** in each test add a `MSG-RECENT` seeded via `messageRepository.save(...)` (auditing stamps
`now()`, which is what you want here) and assert `findById(recent.getId())` is **present** after
the sweep-target DELETE; in the batch test assert exactly one eligible row remains.

### M4 — the rail's `<properties>` restriction does not restrict what the comment says it restricts

`POM_PROPERTIES_BLOCK` is a global, non-greedy scan:

```java
Pattern.compile("<properties>(.*?)</properties>", Pattern.DOTALL);
...
Matcher block = POM_PROPERTIES_BLOCK.matcher(pom);
while (block.find()) { ... }
```

It matches **every** `<properties>` element in the file, not the project-level one. Two
consequences, both false GREEN:

* A `<properties>` inside a `<profile>` supplies values as if they were unconditional. The same
  applies to `POM_GROUPS`, which will read an `<excludedGroups>` sitting inside an **inactive
  profile** and report the tag wired. This pom has **no `<profiles>` today** (verified: `<properties>`
  occurs exactly twice, lines 19 and 63, and there is no `<profiles>` element), so this is a
  future-proofing gap, not a live bug — but a rail whose entire job is "the config that looks
  applied is not applied" should not itself be fooled by the most common way Maven config is
  conditionally applied.
* A plugin `<configuration><properties>…</properties></configuration>` (surefire's JUnit4-style
  property block, for one) would be harvested as project properties.

**Fix:** anchor the properties lookup to the first `<properties>` that is a direct child of
`<project>`, or reject any block whose surrounding text contains `<profile>`. Also worth stating
in the blind-spots list.

### M5 — the rail treats any `-D…groups=` anywhere in a workflow file as wiring

```java
Matcher cli = CLI_GROUPS.matcher(stripHashComments(Files.readString(file)));
```

After comment-stripping, this matches a `-Dgroups=` in **any** non-comment line of **any** file
under `.github/workflows` — an `echo`, a step guarded by `if: false`, a `workflow_dispatch`-only
job, or a workflow for an unrelated branch. It also does not check that the surrounding command is
`mvn`. That is the false-GREEN direction, and it is the direction the class javadoc says it is
careful about. Low blast radius today (the three workflows contain no `-D…groups=` at all — the
only hits are `-Dfailsafe.excludes`, which correctly does not match the pattern), but it is a
stated-guarantee gap.

### M6 — the rail's javadoc claims meta-annotation coverage the instrument does not appear to have

The javadoc asserts: *"Both `@Tag` and its `@Repeatable` container `@Tags` are read, at class and
method level, **directly and meta-annotated**."* The code only ever calls:

```java
type.tryGetAnnotationOfType(Tag.class).orElse(null)
```

ArchUnit's `tryGetAnnotationOfType` returns **directly-declared** annotations; traversing
meta-annotations is a separate API (`isMetaAnnotatedWith` / `getMetaAnnotation…`). JUnit *does*
honour `@Tag` through composed annotations, so a `@Tag("slow") @interface Slow {}` would tag its
targets and be invisible here — a false GREEN.

I could not settle this by running anything (read-only lane, no `javap` on this box), so treat it
as **one of the two statements is wrong and they must be reconciled**, not as a confirmed bug.
Per this repo's own discipline ("a zero-scan needs a positive control"), the cheap discharge is a
3-line probe: add a composed meta-annotated `@Tag("zzz-probe")` test class and confirm the rail
goes RED. If it stays green, fix the code; if it reds, the javadoc is right and this finding
dissolves.

---

## LOW

### L1 — `MessageCleanupBatchServiceIT`: dangling "Tagged postgres because…" paragraph

The `@Tag("postgres")` was deleted from this class, but the paragraph explaining it was not:

```
 * <p>Tagged {@code postgres} because the underlying {@code deleteMessages} native
 * query uses PostgreSQL-only {@code DELETE … WHERE id IN (SELECT … LIMIT)} syntax.
 * The test does not execute real SQL (the repository is mocked), so the H2 backend
 * from {@link BaseIntegrationTest} is sufficient at runtime.
```

Same defect shape as H1, smaller. It also contains a second falsehood the diff walks past: the
class extends `BasePostgresIntegrationTest`, so "the H2 backend from `BaseIntegrationTest`" is
wrong independently — and `BaseIntegrationTest` is not imported, so the `{@link}` does not
resolve either (harmless only because `-Xdoclint:none` and CI passes `-Dmaven.javadoc.skip=true`).
The pom's own new comment *cites* this class's tag as "restated by the TYPE", which is right —
the class javadoc should say so too.

### L2 — the new on-demand recipe contradicts the pom's own recipe

The new perf-IT javadoc says:

```
mvn verify -Dfailsafe.excludedGroups= -Dit.test=BillofladingServiceFinishTransferPerformanceIT
```

The failsafe block's own HOW-TO, ~90 lines above the new `<excludedGroups>`, says:

```
WORKS:  mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
```

The new command omits `-Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`, so it runs the
entire ~6000-test unit lane first. It is not *wrong* (an inclusion-only `-Dit.test` preserves the
pom `<includes>`; only an exclusion-only pattern discards them, per the develop workflow's
measurement), just needlessly expensive and inconsistent with the recipe it sits next to.

### L3 — `assertThat(deleted).isPositive()` could be `isEqualTo(1)`

With the `@AfterEach` sweep guaranteeing an empty `message` table entering each test in this
group, and only one row back-dated past the 7-day cutoff, the exact answer is knowable. `isPositive()`
is a weaker bound than the evidence supports, in a ticket about weak bounds. (The sibling test
already does this right with `isEqualTo(2)`.)

### L4 — `stripHashComments` truncates at the first `#` regardless of quoting

```java
int hash = line.indexOf('#');
return hash < 0 ? line : line.substring(0, hash);
```

A `run:` line containing `#` inside a quoted string (a URL fragment, a `sed 's/#//'`) loses
everything after it. Errs toward false RED, which the javadoc correctly calls the safe direction,
so this is informational only.

### L5 — the rail reads `pom.xml` from the process CWD and tags from `target/test-classes`

`Path.of("pom.xml")` resolves against surefire's working directory (`${basedir}` by default, so
fine in CI and on the command line, potentially not under an IDE run configuration). More
usefully: the tag side is read from `target/test-classes`, so a **stale** build directory can
surface a `@Tag` from a class already deleted from source → false RED. The develop workflow uses
`mvn clean verify` and already documents this trap, so it is bounded; worth one line in the
blind-spots list.

### L6 — `MessageRepositoryNativeSearchIT` javadoc still says a class is "excluded in pom.xml"

```
 * ...which is why {@code MessageCleanupBatchServiceIT} is excluded in {@code pom.xml}.
```

`<excludes/>` is empty (SBDEV-3258 drained it to zero) and `MessageCleanupBatchServiceIT` runs.
Pre-existing, not introduced here — but the diff touches this file's import block, and the
adjacent claim is false.

---

## What I checked and found **sound** — recorded so it is not re-derived

* **(c) The pom indirection is the right shape.** `<excludedGroups>${failsafe.excludedGroups}</excludedGroups>`
  is a *POM property* interpolation, not a plugin user-property, so `-Dfailsafe.excludedGroups=`
  overrides it while a literal value could not. The reasoning in the comment is correct, and the
  deliberate choice *not* to name it `excludedGroups` genuinely does avoid filtering the surefire
  lane (surefire declares no `<excludedGroups>`, so a bare `-DexcludedGroups=x` would bind to it).
* **Empty override.** `-Dfailsafe.excludedGroups=` resolves to `""`. Surefire's JUnit-Platform
  filter factory blank-filters group expressions before building a `TagFilter`, and the failure
  mode if it did not is a **loud** `PreconditionViolationException: Tag expression must not be
  blank`, not a silent mis-filter. Safe direction either way, but I could not execute it — this is
  the assumption AC-3 must actually discharge.
* **No interaction with `<excludes/>` or `argLine`.** Different parameters; the empty `<excludes/>`
  is orthogonal, and `@{argLine}` late-binding is untouched.
* **Lane routing is right.** `MessageRepositoryIntegrationTest` is excluded from surefire
  (`**/*IntegrationTest.java`) and included in failsafe, so the rewritten group runs where the
  author thinks it does. The new rail is `*Test`, matches no surefire exclude, and runs in the
  unit lane.
* **Removing `@Disabled` does not execute the rotted fixtures in CI** — tag exclusion happens at
  discovery, so no Spring context is built. And removing the pom wiring *is* caught: `wired`
  collapses to empty, `used` still holds `performance`, rail goes RED.
* **`@AfterEach` / rollback ordering is sound.** `TransactionalTestExecutionListener.afterTestMethod`
  runs after JUnit's `@AfterEach`, and it guards on a non-null, non-completed `TransactionStatus`,
  so ending the test transaction inside the test body (or inside `@AfterEach`) does not throw.
* **The exact-count rewrite is a real detector.** `firstBatch == 2 && secondBatch == 2` goes red if
  auditing silently re-stamps `created` (the original defect) *and* red if `LIMIT :batchSize` stops
  being honoured. That is a genuine improvement over `<= 2`.
* **No parallelism to corrupt.** The sweep deletes every row in `message`, which would be
  destructive under concurrent classes — but no `forkCount`/`parallel` is configured (the develop
  workflow comment states this explicitly), so classes run sequentially. Flagging only as a
  constraint to remember if parallelism is ever enabled.
* **No checkstyle enforcement.** `com.puppycrawl.tools:checkstyle` appears as a *dependency*
  (pom line ~258), not as a plugin execution, so the removed-import edits cannot break a lint gate.
  All four `Tag` import removals are clean — no remaining `@Tag` usage in those files; the
  `Disabled` import in `MessageRepositoryIntegrationTest` is still needed (`ArchiveMessages`, line
  258); `LocalDateTime` is still used (lines 265, 469); `{@link net.aim_ai.wms.model.Location}` and
  `{@link …BillofladingPosition}` both resolve.

---

## Out-of-scope observation worth a line on the ticket

The develop workflow's comment block names SBDEV-3255 as the fix for something this change does
not deliver:

```
#     The durable fix is SBDEV-3255 (JUnit @Tag is inert in this pom): tag every IT that
#     starts threads or asserts on elapsed time ... and exclude the tag, so the deploy gate
#     stops depending on runner capacity. This one-class exclusion is a stopgap and should
#     shrink to zero when that lands.
```

and, separately, *"SBDEV-3255 is what restores automated coverage"* for
`SequenceTransactionServiceConcurrencyIT`. This commit wires the mechanism but tags nothing new,
and the `-Dfailsafe.excludes='**/SequenceTransactionServiceConcurrencyIT.java'` stopgap is
untouched. That is a defensible scope call (the ticket is tag *wiring*), but the workflow comment
now reads as satisfied when it is not. Either narrow that comment to say the mechanism landed and
the tagging is follow-up, or file the follow-up and cite it there.

---

*Lane A · read-only · derived from the working tree at `c4d920eb` + uncommitted changes.
No build was run; every "sound" item above is a static derivation, and the two items that need
execution to settle are called out as such (empty-override behaviour, and M6's meta-annotation
probe).*
