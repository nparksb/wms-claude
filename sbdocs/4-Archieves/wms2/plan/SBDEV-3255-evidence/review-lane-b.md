# SBDEV-3255 — Review Lane B: conformance / claim discipline

**Scope**: adversarial fact-check of the SBDEV-3255 change and its written claims (new javadocs, pom
comments, ticket). Read-only lane — no maven, no writing git commands, no edits to the worktree.
**Baseline**: `c4d920eb` (verified on `origin/develop`: `git branch -r --contains c4d920eb` →
`origin/develop`).
**Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3255`
**Date**: 2026-09-09

**Headline**: the six claims I was asked to break are all substantively CONFIRMED. What broke is a
tier below them — three *supporting* claims written in the new javadocs (a commit SHA, an interval,
and a capability claim about the rule's own instrument), plus one stale instruction left in the very
file the ticket fixed that now says the wrong thing. Consistent with this repo's measured pattern:
the quantitative claims reproduced; the sentences that assert *how* something was derived did not.

---

## Verdict table

| # | Claim | Verdict |
|---|---|---|
| 1 | Five `@Tag` sites at `c4d920eb`, three `postgres`; ticket's four is stale | **CONFIRMED** (2 instruments) — but 3 supporting sub-claims **BROKEN** (see 1a–1c) |
| 2 | The two `@Tag("postgres")` on PG-base ITs are redundant; deleting is safe | **CONFIRMED** |
| 3 | `@Tag("idempotency")` selects nothing anywhere | **CONFIRMED** (with positive control) — but see **F1**, a contradicting instruction survives in-tree |
| 4 | `deleteMessages` LIMIT-in-subquery is valid PostgreSQL, no dialect problem | **CONFIRMED** |
| 5 | The new `isEqualTo(2)` assertions are safe against leftover / prior-run rows | **CONFIRMED** — the exactness fails only from *below*, which the seeds make impossible |
| 6 | Nothing in CI depends on the performance IT | **CONFIRMED** (3 workflows + `.gitlab-ci.yml`) |
| 7 | CI really runs `mvn clean verify` on develop today (SBDEV-3195) | **CONFIRMED** |

New findings raised by this lane: **F1 (High)**, **F2 (High)**, **F3 (Medium)**, **F4 (Medium)**,
**F5 (Low)**, **F6 (Low)**.

---

## Claim 1 — "Five `@Tag` sites on `c4d920eb`, three of them postgres; the ticket's four is stale"

### CONFIRMED, derived two ways, independently of the author's method

**Instrument A — targeted source grep at the baseline tree (not the working tree):**

```
git grep -n "@Tag" c4d920eb -- 'src/'
```

Five hits under `src/test`, and 61 under `src/main` (all `io.swagger` `@Tag(name = ...)` on
controllers — a different annotation entirely; see F5):

| # | Site | Value |
|---|---|---|
| 1 | `integration/performance/BillofladingServiceFinishTransferPerformanceIT.java:77` (class) | `performance` |
| 2 | `integration/repository/MessageRepositoryIntegrationTest.java:279` (**nested** `DeleteMessages`) | `postgres` |
| 3 | `integration/repository/MessageRepositoryNativeSearchIT.java:51` (class) | `postgres` |
| 4 | `integration/service/IdempotencyFilterIT.java:52` (class) | `idempotency` |
| 5 | `integration/service/MessageCleanupBatchServiceIT.java:44` (class) | `postgres` |

Three `postgres`. **Five total.** Cross-checked against `import org.junit.jupiter.api.Tag` — exactly
the same five files, no sixth importer.

**Instrument B — a deliberately loose token scan, to catch what a `@Tag`-anchored pattern would miss**
(multi-line annotations, unusual spacing, fully-qualified use, `@Tags` containers):

```
git grep -n "Tag" c4d920eb -- 'src/test/'
```

Returns 5 annotation sites + 5 imports + ~45 unrelated hits (Micrometer `getTag(...)`, method names
containing `Tag`, `Locale.forLanguageTag`). No sixth annotation. Also:

```
git grep -n "@Tags\|jupiter.api.Tags" c4d920eb -- 'src/'   → 0 hits
git grep -ln "@interface"          c4d920eb -- 'src/test/' → 0 hits
```

So there is no `@Tags` repeatable container and **no custom annotation declared anywhere in the test
tree** — which closes the composed-annotation escape for the census itself.

**Instrument C — bytecode, on the current worktree** (confirms the *delivered* state, not the
baseline; `target/test-classes` is the running build's output, read-only):

```
grep -rla "junit/jupiter/api/Tag" target/test-classes   → 2 files
  .../performance/BillofladingServiceFinishTransferPerformanceIT.class
  .../unit/config/JUnitTagWiringArchTest.class          (imports Tag/Tags for the rule itself)
```

One surviving tag site, exactly as the diff claims. 1996 compiled test classes total, so the rule's
`hasSizeGreaterThan(1000)` positive control has real headroom.

**Independent confirmation of the "stale four":** the census at `cf3486d8` (the commit the ticket
counted at) really is four —

```
git grep -n '@Tag("' cf3486d8 -- src/test   → performance, postgres(MessageRepositoryIntegrationTest),
                                               idempotency, postgres(MessageCleanupBatchServiceIT)
```

`MessageRepositoryNativeSearchIT` is absent there. The four→five drift is real and the rule-not-a-census
argument stands.

### Sub-claims that BROKE

**1a — BROKEN: "a third `@Tag("postgres")` arrived in `5f7d044a`."**
It arrived in **`5c7d7ab7`**, not `5f7d044a`.

```
git log --oneline --diff-filter=A -- .../MessageRepositoryNativeSearchIT.java
  5c7d7ab7 fix(message): SBDEV-3222 correct the root-cause claim and cover the native searches
           on real PostgreSQL                                      (2026-09-09 04:07 UTC)
git log --oneline -1 5f7d044a
  5f7d044a SBDEV-3258 Fix 4b+4c: drain the failsafe exclusion list to EMPTY   (2026-09-08 15:43 UTC)
git merge-base --is-ancestor 5f7d044a cf3486d8 → NO
```

`5f7d044a` did touch `MessageCleanupBatchServiceIT`, but that file's tag has been there since
SBDEV-2220 (`19252cfe`, later reworked in `c2074183`) — it is one of the *original four*, not the
new one. The two SHAs look alike (`5f7d044a` / `5c7d7ab7`), which is presumably how it happened.
Fix the SHA in `JUnitTagWiringArchTest`'s javadoc.

**1b — BROKEN: "four days later."**
`cf3486d8` is `2026-09-07 22:23 -0400`; `c4d920eb` is `2026-09-09 13:27 -0400`. That is **1.6 days**,
not four. The argument (a prose census rots fast) is *strengthened* by the true number, so this is a
cheap fix, but as written it is a false quantitative claim in a document whose whole subject is
false claims.

**1c — BROKEN: "Both `@Tag` and its `@Repeatable` container `@Tags` are read, at class and method
level, directly **and meta-annotated**."** (`JUnitTagWiringArchTest` javadoc, "Instrument" section.)

The rule reads `type.tryGetAnnotationOfType(Tag.class)`. In ArchUnit 1.3.0 that is **direct-only**.
Evidence — ArchUnit exposes meta-annotation resolution as a *separate* API on the same type:

```
javap -cp .../archunit-1.3.0.jar com.tngtech.archunit.core.domain.JavaClass
  public boolean isAnnotatedWith(Class<? extends Annotation>);
  public boolean isMetaAnnotatedWith(Class<? extends Annotation>);   ← distinct method
  public <A extends Annotation> Optional<A> tryGetAnnotationOfType(Class<A>);
```

`getAnnotations()`/`tryGetAnnotationOfType` return what the class file's `RuntimeVisibleAnnotations`
attribute declares. Meta-annotations are not in it. Meanwhile **JUnit does resolve them**:

```
javap -p -c org/junit/jupiter/engine/descriptor/JupiterTestDescriptor.class
  static Set<TestTag> getTags(AnnotatedElement);
    ldc  #22  // class org/junit/jupiter/api/Tag
    invokestatic AnnotationSupport.findRepeatableAnnotations:(...)   ← meta-annotation-aware
```

and `@Tag` is declared `@Target({ElementType.TYPE, ElementType.METHOD})` (junit-jupiter-api 5.12.2
sources) — `ElementType.TYPE` includes annotation-interface declarations, so
`@Tag("slow") public @interface Slow {}` compiles and JUnit honours it.

**Concrete false-GREEN**: a composed `@Slow` on a test class is a live tag to JUnit and invisible to
this rule — precisely "an annotation that looks like test-selection policy and is inert", the failure
the rule exists to prevent. Today the tree declares no custom annotations at all (0 `@interface` in
`src/test`), so nothing is being missed **right now**; the defect is that the javadoc's *stated blind
spot list* asserts the opposite of the truth, so the next reader will not think to check. Either
switch to an `isMetaAnnotatedWith`-based collection, or move this line from the "what it reads"
paragraph into the "stated blind spots" list.

Related, same mechanism, **not** a false green: `@Tag` is also `@Inherited` (verified in the 5.12.2
sources, line 60). A subclass of a tagged base inherits the tag at runtime; ArchUnit will not see it
on the subclass. The *value* is still captured from the base class's own declaration, so the census
of tag names stays complete. Worth one sentence in the blind-spot list regardless.

---

## Claim 2 — "The two `@Tag("postgres")` are REDUNDANT because both extend `BasePostgresIntegrationTest`" → **CONFIRMED**

`src/test/java/net/aim_ai/wms/common/base/BasePostgresIntegrationTest.java`:

```java
@SpringBootTest(classes = StartApplication.class)
@ActiveProfiles("postgres-integration")
@Import(PostgresTestSupportConfig.class)
@ExtendWith(AppPostgresDBSetupExtension.class)
@Transactional("tenantTransactionManager")
public abstract class BasePostgresIntegrationTest {
    @DynamicPropertySource
    static void datasources(DynamicPropertyRegistry registry) {
        AppPostgresDBContainer c = AppPostgresDBContainer.container;
        registry.add("spring.datasource.url", c::getJdbcUrl);          // Testcontainers PG
        registry.add("landlord.datasource.jdbc-url", AppPostgresDBSetupExtension::landlordJdbcUrl);
        ...
    }
}
```

The engine is bound **by type**, three ways over: the profile, the container extension, and a
`@DynamicPropertySource` that overwrites `spring.datasource.url` with the container's JDBC URL for
that context only. There is no lane in which a subclass runs on H2. The tag restated it and could
not have changed selection, because nothing read tags.

**Is there a path where the tag would have mattered?** I checked the one that would matter — a
"skip the Docker-dependent tests" escape hatch, e.g. `mvn verify -DexcludedGroups=postgres` on a
machine with no Docker daemon. Two reasons it is not a loss:

1. It never worked. At `c4d920eb`, `git show c4d920eb:pom.xml | grep -n "excludedGroups\|<groups>"`
   returns **nothing** — neither plugin configured groups, so no `-D` could have engaged the tag.
2. It would not work *after* this change either, tag or no tag — see **F3**. The explicit
   `<excludedGroups>${failsafe.excludedGroups}</excludedGroups>` now shadows the shared
   `${excludedGroups}` user property on the failsafe lane.

Deleting them is irreversible policy, but it removes a capability that never existed. **Safe.**

---

## Claim 3 — "`@Tag("idempotency")` selects nothing; `IdempotencyFilterIT` already pins its engine" → **CONFIRMED**

Sweep, repo-wide, over tracked files:

```
git grep -n -E "\-D(groups|excludedGroups|[a-z]+\.excludedGroups)=" -- .
  src/test/.../BillofladingServiceFinishTransferPerformanceIT.java:57  -Dgroups=performance
  src/test/.../BillofladingServiceFinishTransferPerformanceIT.java:82  -Dfailsafe.excludedGroups=
```

Nothing else — no workflow, no script, no doc, no `.gitlab-ci.yml`. Also checked outside the repo:

```
grep -rn "excludedGroups|-Dgroups" sbdocs/9-System/            → 0 hits
grep -rn "groups=idempotency|groups=postgres|groups=performance" sbdocs/  →
  only 4-Archieves/wms2/plan/SBDEV-2216-...md (×3), all "-Dgroups=performance"
```

`.mvn/` does not exist (`ls -a` on the repo root), so there is no `maven.config` carrying a hidden
`-D`. `.gitlab-ci.yml` runs `mvn package -DskipTests=true` — it never selects tests at all.

**Positive control for the zero** (per the "a zero-scan needs a positive control" rule): the same
regex family, run against a flag known to be present, matches —

```
git grep -n -E "\-Dfailsafe\.excludes=" -- .github/
  docker-image-develop.yml:131   (in a comment)
  docker-image-develop.yml:166   (the real run: line)
```

The instrument is live; the zero for `idempotency` is a true zero.

Engine pinning: `IdempotencyFilterIT extends BasePostgresIntegrationTest` (line 52 area of the file),
so Claim 2's evidence applies verbatim. **CONFIRMED.**

> ⚠ See **F1** — the sweep turned up a survivor that contradicts this ticket's own fix.

---

## Claim 4 — "`deleteMessages` puts LIMIT inside the subquery, which PostgreSQL supports, so there is no dialect problem" → **CONFIRMED**

`src/main/java/net/aim_ai/wms/repo/jpa/MessageRepository.java:101`:

```java
@Modifying(clearAutomatically = true)
@RestResource(exported = false)
@Query(value = "DELETE FROM message WHERE id IN (SELECT id FROM message AS m WHERE m.created < :refDate LIMIT :batchSize)",
       nativeQuery = true)
int deleteMessages(@Param("refDate") Date refDate, @Param("batchSize") int batchSize);
```

- **Valid PostgreSQL: yes.** PostgreSQL has no `LIMIT` clause on `DELETE` itself, which is exactly why
  the LIMIT is pushed into a scalar-list subquery — a `SELECT` where `LIMIT` is unrestricted. A bind
  parameter in `LIMIT` is also supported.
- **Portable to H2 (the lane it actually runs in here): yes** — H2 in `MODE=PostgreSQL` accepts
  `LIMIT` in a subquery. So the removed `@Tag("postgres")` on the nested `DeleteMessages` group was
  describing a dialect problem that does not exist. The pom comment's "there was never a dialect
  problem for a tag to describe" is correct.

**Does it need `ORDER BY`?** No, for correctness. The rows are a delete-everything-eventually set;
which `batchSize` of the eligible rows goes first is immaterial, and the cron loop
(`MessageCleanupBatchService.deleteOnce` called per batch by `CleanUpOldMessageJobService`) re-runs
until drained. An `ORDER BY created` would make batches deterministic and marginally friendlier to
the index, but its absence is not a defect.

**Does it need `FOR UPDATE SKIP LOCKED`?** Not for correctness, and I would not add it here:

- Within one statement the DELETE re-checks each row under READ COMMITTED, so a row another
  transaction already deleted is simply skipped — no error, no double-delete.
- Two *concurrent* cleanup runs picking overlapping id sets would **block** on row locks rather than
  interleave, which is a throughput question, not a correctness one, and `deleteOnce` is
  `REQUIRES_NEW` precisely so each batch's locks are released at the per-batch commit.
- The realistic effect of adding `SKIP LOCKED` would be to let two runners drain in parallel. Nothing
  in this ticket needs that, and it is out of scope.

One thing worth stating rather than leaving implicit: the return value is "rows this statement
deleted", so an overlapping concurrent run makes the count non-deterministic. The *test* is
single-threaded, so this does not touch Claim 5.

---

## Claim 5 — "the fix's exact `isEqualTo(2)` assertions are safe against leftover rows" → **CONFIRMED**

The underlying diagnosis first, because the assertions depend on it:

- `AbstractBaseEntity` is `@MappedSuperclass @EntityListeners(AuditingEntityListener.class)` with
  `@CreatedDate private LocalDateTime created` — and `StartApplication:29` carries
  `@EnableJpaAuditing`. So auditing **is** live and does stamp `created` on persist. The
  "auditing overwrites `created`" diagnosis is structurally sound, not just measured.
- `saveCreatedDaysAgo` works around it with save → `setCreated(...)` → save; `@CreatedDate` is
  applied on insert only, `@LastModifiedDate` on update, so the back-date survives the second write.

**Why exactness is safe.** The seeding is 5 rows aged 30 days, committed via
`TestTransaction.flagForCommit(); TestTransaction.end();`, then two `deleteOnce(refDate, 2)` calls
with `refDate = now-7d`. `DELETE ... IN (SELECT ... LIMIT 2)` removes **exactly 2 whenever ≥2 rows
are eligible**. So:

- **More** eligible rows than expected (a sibling group's leak, a prior run's residue) → still
  exactly 2 per call. The assertion is *robust from above*.
- **Fewer** than 2 eligible → would break it — and cannot happen: 5 rows are committed by this test
  itself immediately before the calls.

The only genuine leak source is a committed row aged past the 7-day cutoff, and the only committer of
back-dated rows in the whole tree is this class:

```
git grep -ln "TestTransaction" -- src/test   → MessageRepositoryIntegrationTest.java (only)
```

Sibling groups (`FindAllFromDaysPeriod`, `GetDetailViewByKeyword`) do seed 10–11-day-old rows via the
same helper, but they never commit, and rollback genuinely works now —
`BaseRepositoryIntegrationTest` carries `@Transactional("tenantTransactionManager")` with the
SBDEV-3242 qualifier and is pinned by `BaseRepositoryIntegrationTestRollbackContractTest`. Even if
one leaked, per the paragraph above it would not move either assertion.

**The `@AfterEach` sweep is well-founded and I could not break it**, but two consequences should be
written down rather than discovered:

- The H2 lane is one shared, JVM-lifetime database — `application-integration.properties:20` is
  `jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1;MODE=PostgreSQL`, and the pom sets no
  `forkCount`/`reuseForks`, so the default single reused fork means every `integration`-profile class
  in the lane shares it. The sweep's `deleteOnce(now + 1 day, 10_000)` therefore **truncates the
  `message` table for every later class in the lane**, not just for this one. Benign today (nothing
  asserts on a message count across classes: `git grep "messageRepository.count()\|messageRepository.findAll()" -- src/test` → 0 hits), but it is a
  cross-class side effect, not a local cleanup. → **F6**.
- If a test throws *before* reaching its `TestTransaction.end()`, the sweep's
  `if (TestTransaction.isActive()) { flagForCommit(); end(); }` **commits** what a failing test wrote
  instead of rolling it back. The messages are then swept, but non-message fixtures are not — notably
  `setUp`'s `admin` `User`, which leaks permanently into the shared H2 for the rest of the lane.
  Nothing currently asserts on the user table from an H2 integration class, so this is Low. → **F6**.

---

## Claim 6 — "Nothing in CI depends on the performance IT" → **CONFIRMED**

All four CI definitions, exhaustively:

| File | Trigger (parsed, not grepped) | Runs tests? |
|---|---|---|
| `.github/workflows/docker-image-develop.yml` | `push: [develop]`, `pull_request: [develop]` | **yes** — `mvn -B -ntp clean verify` (line 165) |
| `.github/workflows/docker-image-uat.yml` | `push: [release]` | no — no `mvn`/`maven` token in the file |
| `.github/workflows/docker-image.yml` | `push: [main]` | no — same |
| `.gitlab-ci.yml` | `if: $CI_COMMIT_TAG` | no — `mvn package -DskipTests=true` |

No scheduled trigger anywhere: `grep -n "schedule\|cron" .github/workflows/*.yml` returns three hits,
all of them prose or a Portainer service name, none a `schedule:` trigger key. So the `performance`
group runs on **no automated lane at all**, and no CI job references the class by name.

---

## Claim 7 (sanity check) — CI really runs `mvn clean verify` on develop today → **CONFIRMED**

`.github/workflows/docker-image-develop.yml`, on `origin/develop` (`git diff --stat
origin/develop..HEAD -- .github/workflows/` is empty, so the worktree copy is the deployed copy):

```yaml
on:
  push:         { branches: [ "develop" ] }
  pull_request: { branches: [ "develop" ] }
jobs:
  test:
    - name: Run the test suite
      run: mvn -B -ntp clean verify -Dmaven.javadoc.skip=true -Dspringdoc.skip=true
           -Dfailsafe.excludes='**/SequenceTransactionServiceConcurrencyIT.java'
  build:
    needs: test
    if: github.event_name == 'push'
```

`needs: test` with no `continue-on-error` anywhere (the single `if: always()` is on the
report-recording step, not on a gate). The gate is real. Consistent with the known caveat that the
**PR** check is advisory (no branch protection), while the **push** path genuinely blocks the image.

So the ticket's "do NOT land before SBDEV-3195" precondition is satisfied — and it matters more than
usual here: this change removes an `@Disabled` from a long-running load test and replaces it with a
group exclusion. If the exclusion did not engage, the failure lands on the branch that gates the dev
deploy, and a red develop stops deploying silently.

---

## Findings

### F1 — HIGH · The perf IT still documents `-Dgroups=performance`, which is now actively wrong, in the same javadoc that documents the right command

`src/test/java/net/aim_ai/wms/integration/performance/BillofladingServiceFinishTransferPerformanceIT.java:49-57`
is untouched by this change and still says:

```java
 * <p><b>Disabled by default.</b> CI runs the unit tests + the G1 integration
 * ...
 *   mvn test -Dtest=BillofladingServiceFinishTransferPerformanceIT \
 *            -Dgroups=performance
```

25 lines below, the new SBDEV-3255 block says:

```java
 * <pre>{@code mvn verify -Dfailsafe.excludedGroups= -Dit.test=BillofladingServiceFinishTransferPerformanceIT}</pre>
```

The old command was harmless when nothing read tags. It is not harmless now:

- `-Dgroups=performance` sets the **shared** `${groups}` user property — the same aliasing the new
  pom comment correctly warns about for `excludedGroups`. I verified it on the descriptors:
  `<groups implementation="java.lang.String">${groups}</groups>` is present in **both**
  surefire-3.2.5 and failsafe-3.1.2 `META-INF/maven/plugin.xml`. So it filters the unit lane too, to
  the empty set.
- On failsafe the class would then be simultaneously in `groups` and in `excludedGroups`; exclusion
  wins, so it still does not run.
- `mvn test` never reaches the failsafe lane at all, so an `*IT` was never going to run under it.

Net: following line 57 gives "BUILD SUCCESS, 0 tests" twice over — the exact "looks like policy,
selects nothing" shape SBDEV-3255 exists to eliminate, left in the file it just fixed. The
"**Disabled by default.**" heading is also now naming a mechanism the change deleted.

**Fix**: delete lines 49-58's run block (and demote "Disabled by default" to "Excluded from CI by
default"), leaving the single correct command. This is also the second instrument for the ticket's own
rule — the rule cannot catch it, because it validates `@Tag` values, not run instructions.

### F2 — HIGH · The rule's javadoc claims meta-annotated `@Tag`s are read; they are not

Full evidence in **1c**. `tryGetAnnotationOfType` is direct-only (ArchUnit 1.3.0 exposes
`isMetaAnnotatedWith` as a separate method for exactly this reason), while JUnit resolves tags with
`AnnotationSupport.findRepeatableAnnotations`, which is meta-aware, and `@Tag`'s `@Target` permits
composition. A composed `@Fast`/`@Slow` annotation would be live to JUnit and invisible to the rule
— a **false GREEN**, the direction the rule's own javadoc calls dangerous. No such annotation exists
today (0 `@interface` in `src/test`), so this is a documentation defect with a latent instrument gap,
not a live miss. Fix the sentence at minimum; consider collecting via `isMetaAnnotatedWith`.

### F3 — MEDIUM · You can no longer *add* an excluded group without re-enabling the performance IT

`<excludedGroups>${failsafe.excludedGroups}</excludedGroups>` is an explicit configuration element,
so it shadows the shared `${excludedGroups}` user property on the failsafe lane. Consequences:

- `-DexcludedGroups=slow` has **no effect on failsafe** any more (it still filters surefire).
- `-Dfailsafe.excludedGroups=slow` **replaces** the value — it does not append — so it silently
  re-includes `performance`.

This is the correct trade (the indirection is what makes the on-demand run possible, and the pom
comment justifies it well), but the one-lever-with-one-slot property is worth a sentence in that
comment, because the natural next step — "exclude the threading ITs too", which the develop workflow
explicitly asks SBDEV-3255 to do — runs straight into it. Suggested shape:
`<failsafe.excludedGroups>performance</failsafe.excludedGroups>` documented as *the whole expression*,
extended as `performance,slow`, never appended to from the CLI.

Separately verified and worth recording as a **confirmation**, since it is the one claim in the pom
that could have failed silently: the documented override `-Dfailsafe.excludedGroups=` (empty) really
does disable the filter rather than throwing a tag-expression parse error.
`surefire-junit-platform-3.1.2`'s `JUnitPlatformProvider.getPropertiesList` reads the provider
property and returns `Optional.empty()` when `StringUtils.isBlank(...)`:

```
javap -p -c org/apache/maven/surefire/junitplatform/JUnitPlatformProvider.class
  private Optional<List<String>> getPropertiesList(String);
    ... ProviderParameters.getProviderProperties() → Map.get(name)
     20: invokestatic  StringUtils.isBlank:(Ljava/lang/String;)Z
     23: ifeq 32
     26: invokestatic  java/util/Optional.empty
```

So the on-demand command in the javadoc is valid. (The `-Dit.test=<Class>` half is an *inclusion*
pattern, so the `-Dit.test='!Class'` trap from SBDEV-3258 does not apply.)

### F4 — MEDIUM · Surefire has no `excludedGroups`, so a `@Tag` on a unit test passes the rule and still selects nothing

The rule treats a group as wired if the name appears in **any** `<groups>`/`<excludedGroups>` in the
pom. Only failsafe has one. `@Tag("performance")` on a `*UnitTest` would satisfy the rule and be run
anyway by surefire — a false GREEN for the rule's stated purpose. Either scope the rule's notion of
"wired" per lane, or state this in the blind-spot list.

### F5 — LOW · The "five `@Tag` sites" phrasing is only true for `org.junit.jupiter.api.Tag` under `src/test`

`git grep -n "@Tag" c4d920eb -- 'src/'` returns **66**: 61 are Swagger `@Tag(name = "...")` on
controllers in `src/main`. The rule is scoped correctly (`ImportOption` = `/test-classes/`), so this
is purely a wording risk in the pom comment and ticket — but per the "src-wide scans also pick up
test classes" lesson, the reverse mistake is easy for the next person to make. Say "five JUnit
`@Tag` sites in `src/test`".

### F6 — LOW · Two undocumented side effects of the new `@AfterEach` sweep

Detail in Claim 5. (a) It truncates `message` for every later class in the shared JVM-lifetime H2
database, not just for its own group. (b) On a test that throws before its `TestTransaction.end()`,
the `isActive()` branch **commits** the failing test's writes rather than rolling them back; the
messages are swept, `setUp`'s `admin` `User` is not. Both are currently harmless (no cross-class
assertions on either table) — worth two sentences in the `sweepCommittedRows` javadoc, which
currently explains only why the sweep is needed, not what else it touches.

---

## Conformance note (not a claim I was asked to check, but it bears on scope)

`.github/workflows/docker-image-develop.yml:131-156` states, in the comment justifying the
`SequenceTransactionServiceConcurrencyIT` CI exclusion:

> "The durable fix is SBDEV-3255 (JUnit @Tag is inert in this pom): **tag every IT that starts
> threads or asserts on elapsed time** … and exclude the tag, so the deploy gate stops depending on
> runner capacity. This one-class exclusion is a stopgap and should shrink to zero when that lands."
> … "SBDEV-3255 is what restores automated coverage."

The delivered change wires the mechanism but tags **one** class. It does not tag the 11–15 threading
ITs the same comment enumerates, the `-Dfailsafe.excludes` stopgap is untouched, and no automated
coverage is restored (the perf IT went from `@Disabled`/never-runs to excluded-group/never-runs,
and is excluded on developer machines too, since the exclusion lives in the pom rather than the
workflow). That is a defensible scope cut — the wiring is the prerequisite and the ticket says its
scope is tag wiring — but two statements on `origin/develop` now over-claim what landing SBDEV-3255
achieves. Either narrow that workflow comment in this PR, or file the follow-up and point the
comment at it.

---

## What I could not verify from this lane

- **AC-3, "verified by running the lane both ways."** Read-only lane, no maven. I confirmed every
  *static* precondition for it — the property indirection resolves, the blank-override path is real
  (F3), no CI reference to the class exists — but I cannot confirm Maven actually honours
  `<excludedGroups>` at runtime. This is the measurement the rule's own javadoc correctly says it
  cannot make, and it fails in the dangerous direction, so it must not be inferred from a green rule
  or from this report.
- **"This class does NOT currently pass … `seedShared` dies at commit with
  `ConstraintViolationException`."** Not reproducible here. The supporting arithmetic does check out:
  `Location` has 12 `@NotNull` fields (`grep -c "@NotNull" src/main/java/net/aim_ai/wms/model/Location.java`)
  and `seedShared` sets exactly one of them (`shippedLocation.setName(...)`, line 136), so "needs
  eleven `@NotNull` fields it does not set" is arithmetically consistent.
- The RED evidence in `rail-test-RED.txt` is a genuine negative control — the rule fails at baseline
  naming all three unwired tags (`[idempotency, performance, postgres]`, `wired: []`), which is the
  right failure for the right reason.
