---
ticket: SBDEV-3410
phase: P3
lane: re-review of the fix commit
subject: "git diff 97ee9e3e..1430296e"
worktree: .claude/worktrees/wms2-api/SBDEV-3410-p3
branch: feature/SBDEV-3410-p3-export-shipper-filter
head: 1430296e
date: 2026-09-22
mode: read-only (no edits, no mvn)
---

# SBDEV-3410 P3 — re-review of `1430296e` (the review-lane fix commit)

## Verdict

**The four Low fixes are correct and none of them introduced a defect.** Every replacement claim I
was asked to re-derive is TRUE except one, and the one that is false is false only in its stated
*reason* — its conclusion holds for a stronger reason it does not name.

**The new file has one real defect and one real gap**, both in the same place the lead suspected:
its non-vacuity story. `StockrecordExportWithdrawalContextTest` carries **two** assertions that
claim to be the control against vacuity. One of them **cannot fail** — verified against
spring-data-rest-core 4.5.7 source, not inferred. And the answer to the lead's direct question is
**no**: the test does *not* catch a rename or a removal; it goes vacuously green, and the guarantee
that saves it is borrowed from a different class, in a different package, in a different lane, and
is not stated anywhere in the file.

| # | Severity | Finding |
|---|---|---|
| M-1 | **Medium** | `assertThat(searches).isNotNull()` is a **dead assertion** — `getSearchResourceMappings` can never return null — and its `.as()` message claims it is what stops the absence assertion being vacuous |
| M-2 | **Medium** | `WITHDRAWN` is a bare string literal tied to nothing. A rename or removal ⇒ **vacuous green**. The real guard is in `StockrecordExportQueryContractUnitTest`, undocumented here |
| L-1 | Low | `filterReachesRepository`'s javadoc describes the **withdrawn** `never()` prescription, not the shipped code ("uses `anyLong()`/`anyInt()`, never `any()`" — the code uses `any()` and no `anyLong()`) |
| L-2 | Low | The new L-1 comment's claim "all three sibling classes … set `created` **and clean up**" is false on the cleanup half; the conclusion survives for a different reason |
| L-3 | Low | Plan §5.2 P1 item (b)'s **closing sentence is stale** and contradicts the corrected measurement six paragraphs above it — a reader stopping at the end of the bullet concludes the criterion is unmeasured |

Nothing in `1430296e` contradicts the plan. No rail goes red. `H-1` (untracked deliverable) and
`M-1` (stale base) from `p3-code-review.md` are both discharged — I verified the file is tracked and
that both `NeverMatcherNullBlindnessArchTest` inventory entries survived the rebase.

---

## 1 · The new file — `StockrecordExportWithdrawalContextTest`

### M-1 · MEDIUM — a dead assertion carrying the non-vacuity claim

`src/test/java/net/aim_ai/wms/security/StockrecordExportWithdrawalContextTest.java:68-71`

```java
assertThat(searches)
        .as("Stockrecord must still have exported searches at all — without this the absence "
                + "assertion below is vacuous")
        .isNotNull();
```

**This assertion cannot fail.** Verified against the 4.5.7 sources, not the javadoc:

* `RepositoryResourceMappings.getSearchResourceMappings` (line 119) **always** constructs
  `new SearchResourceMappings(mappings)` and returns it; the only cached values come from
  `searchCache.put` on line 120, so a cached `null` is unreachable.
* The base `PersistentEntitiesResourceMappings.getSearchResourceMappings` (line 85-87) returns a
  non-null field unconditionally.
* The one genuine failure mode on that line is a **thrown** `IllegalArgumentException` out of
  `repositories.getRequiredRepositoryInformation(domainType)` (line 105) — which `isNotNull()` does
  not grade, and which would surface as an error regardless.

So the message is the defect: it tells a future auditor that *this* is what prevents vacuity, and it
is the one assertion in the method that is incapable of noticing anything. The thing that actually
prevents vacuity is the `contains(MUST_STAY_EXPORTED)` immediately below — which the class javadoc
already identifies correctly ("the positive arm doubles as this test's non-vacuity control"). The
code and the javadoc disagree about which line does the work, and the code's version is wrong.

Note the path this closes off: `getSearchResourceMappings` also short-circuits on
`if (resourceMapping.isExported())` (line 109), so if `Stockrecord`'s *resource* were ever
un-exported the list would come back **empty, not null** — and `contains(MUST_STAY_EXPORTED)` would
catch that while `isNotNull()` would sail past it. The control that can see the failure is already
there.

**Fix.** Delete the `isNotNull()` block. The `contains()` below subsumes it, and the javadoc already
says so. If you want a line that names the property, assert on the iterator having a next element —
but that is exactly what `contains()` proves, so the honest edit is a deletion.

I rate this Medium rather than Low because the harm is to the *claim*, and this repo's own
`green-tests-that-prove-nothing` and `a-zero-scan-needs-a-positive-control` findings are about
precisely this: an assertion that reads as the control and isn't one.

### M-2 · MEDIUM — answering Q1 directly: a rename or removal passes vacuously

The lead asked whether the test also catches "the subtler case where the method is renamed or
removed entirely rather than re-exported." **It does not.**

```java
private static final String WITHDRAWN = "findByClientOffsetAndLimit";
...
assertThat(exported).doesNotContain(WITHDRAWN);
```

`WITHDRAWN` is a string literal bound to nothing. Rename the repository method and `exported` simply
never contains that name; `doesNotContain` passes. The mutation check the lead ran (removing
`exported = false` → red naming all three) exercises the *re-export* direction only, which is why it
looked sufficient.

What saves it today is **external and undocumented in this file**:

* `StockrecordExportQueryContractUnitTest:89-99` — `method(FILTERED, String.class, Long.class,
  int.class, int.class)` throws an `AssertionError` with a written-out explanation if the method is
  missing, so a rename that misses that constant reds there.
* `ReportService`'s call site makes an outright deletion a **compile** error.

That is a real guarantee, but it is a *borrowed* one, and it fails in the one case that matters: a
coordinated edit that updates `StockrecordExportQueryContractUnitTest`'s `FILTERED` constant and
leaves this file's `WITHDRAWN` literal behind. Then the contract test stays green, the withdrawal
test stays green, and nothing is grading the withdrawal. This is the shape of
`absence-of-a-path-is-not-absence-of-the-guarantee`: the ref sweep is defeated by the rename.

**Fix — three lines, makes the file self-contained:**

```java
assertThat(StockrecordRepository.class.getMethods())
        .as("%s must still EXIST on the repository — if it was renamed or deleted the absence "
                + "assertion below is vacuous and grades nothing", WITHDRAWN)
        .anyMatch(m -> m.getName().equals(WITHDRAWN));
```

This is also the assertion M-1's dead `isNotNull()` was reaching for, so the two fixes collapse into
one net-zero-line edit: delete the `isNotNull()`, add the existence check.

### Verified TRUE — the inherited mechanism claim, both halves

The javadoc's stated-rather-than-re-derived assumption is **correct in both directions**, checked
against `spring-data-rest-core-4.5.7-sources.jar`:

* `SearchResourceMappings.iterator()` (lines 159-161) returns `mappings.values().iterator()` with
  **no** exposure filter — and the class separately offers `getExportedMappings()` (line 89-93)
  which *does* `.filter(MethodResourceMapping::isExported)`. So "its own `iterator()` does NOT
  filter" is exactly right, and the existence of the filtering sibling method is the proof.
* The filtering is upstream, where the javadoc says: `RepositoryResourceMappings
  .getSearchResourceMappings` lines 110-116 —
  `if (methodMapping.isExported()) { mappings.add(methodMapping); }`.
* Direction-of-failure claim holds: if that upstream filter were ever removed, this test would
  **over**-report (the withdrawn method would appear and the test would red), not under-report.

So the test reads the surface it claims to read. The `if (search.getMethod() != null)` guard is dead
in the same way `isNotNull()` is — `RepositoryMethodResourceMapping` sets `this.method = method` in
its constructor (line 81) so it is never null — but that one is copied verbatim from the sibling
`SdrMutatingSearchNotExportedContextTest` and is harmless; I am not filing it.

### Verified TRUE — "ANNOTATED per repository, so a query method exports by DEFAULT"

* `src/main/java/net/aim_ai/wms/RestConfiguration.java:891` —
  `config.setRepositoryDetectionStrategy(RepositoryDetectionStrategies.ANNOTATED)`. Per *repository*,
  as claimed.
* `RepositoryMethodResourceMapping:76` —
  `this.isExported = annotation != null ? annotation.exported() : exposeMethodsByDefault;`
* Nothing in `src/main` calls `exposeRepositoryMethodsByDefault(false)` (grepped), and SDR's default
  is `true`.

So `@RestResource(exported = false)` genuinely is the only thing withdrawing the route, and the
test's stated reason for existing is sound.

### Lane placement — correct and consistent

`*ContextTest` is excluded by **neither** surefire pattern (`**/*IntegrationTest.java`,
`**/*E2ETest.java`), so this class runs in the **surefire** lane, alongside the 15 sibling
`*ContextTest` classes in the same package that also extend `BaseRollbackIntegrationTest`. Same lane
as `SdrMutatingSearchNotExportedContextTest`, whose traversal it mirrors. No pom edit owed.

One genuine improvement over the sibling worth recording: the sibling's control is a **global** floor
(`exportedSearches > 100` across all entities), which would stay green if `Stockrecord` specifically
lost all its searches. The new test's control is **entity-scoped** (`contains("findByOffsetAndLimit")`
on `Stockrecord`'s own mappings). That is strictly stronger, and it is the right construction.

---

## 2 · The four Low fixes

### L-1 (the lead's L-1) — `unfilteredExportRouteIsUnchanged`: the property was NOT lost

The second assertion was **removed**, not rescoped, and replaced by a 12-line comment
(`StockrecordExportClientFilterIT.java:178-188`). The surviving assertion is `KEYWORD`-scoped.

**Does the test still grade what its name and javadoc claim? Yes.** The name is "the lift did not
change what `findByOffsetAndLimit` returns" and the `.as()` is about §3.6's measured failure mode —
an in-place client predicate whose null bind makes the conjunction NULL and returns `[]`. The
surviving `containsExactlyInAnyOrder(SR_SYS, SR_B1, SR_B2)` spans **two shippers** (`0` and
`CLIENT_B`), so it reds on any acquired client predicate, null-bound or not. That is the property the
method exists for, and it is intact.

**Is the escape-arm coverage genuinely preserved elsewhere?** Yes, and the justification given for it
is TRUE, which I checked rather than accepted:

* `StockrecordRepository.java:69-70` — `NATIVE_KEYWORD_CLAUSE` is **one** `String` constant,
  concatenated into both `@Query` values at lines 90 and 116. Both methods bind
  `@Param("keyword") String`. The filtered query is the unfiltered `WHERE` clause **plus** one `AND`
  conjunct, so the escape arm's truth value under a given bind is identical on both routes. So
  "grading it on either route grades it on both" is not rhetoric — it is SQL identity.
* The shared-ness is itself pinned twice, so a divergent hand-copy cannot quietly restore the gap:
  `StockrecordExportQueryContractUnitTest.bothExportQueriesShareOneKeywordClause` asserts the
  filtered SQL `startsWith` the unfiltered SQL up to `order by` **and** pins the five searched
  columns by name; `unfilteredExportQueryTextIsByteIdentical` freezes the unfiltered text against
  `origin/develop`.
* `emptyKeywordTakesTheEscapeArmWhenFiltered` (line 153-159) executes the arm, client-scoped, and is
  immune to the page window.

**And the stated reason for removing it is TRUE.** `stockrecord.created` really is nullable —
`src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:2166` `CREATE TABLE public.stockrecord`
declares `created timestamp with time zone` with no `NOT NULL`. PostgreSQL sorts NULLs first under
`DESC`. The described eviction of the fixture by 100 committed NULL-`created` rows is a real
mechanism, and a red produced that way would indeed read as a predicate regression.

No finding. This fix is correct and the property it claims to preserve is preserved.

### L-2 (imports) — correct, nothing shadowed, nothing redundant

* `ReportControllerUnitTest`: `java.util.*` does **not** cover `java.util.stream.Stream`, so that new
  single-type import is required, not redundant. `ParameterizedTest`, `Arguments` and `MethodSource`
  collide with no type in `java.util`, and `import static org.hamcrest.Matchers.*` imports static
  members of `Matchers` — which declares no nested type of any of those names. Nothing shadowed.
* `ReportServiceUnitTest`: `java.util.Collections` was **already** imported at line 27, so
  de-qualifying the two `Collections.emptyList()` call sites is valid.

Cosmetic leftover, outside the diff, mentioned only because L-2 was framed as an import-hygiene pass:
`ReportServiceUnitTest` lines 129 and 176 still write `new java.util.ArrayList<>()` while `ArrayList`
is imported at line 25.

### L-4 (`ABSENT`) — correct on both counts

* **`ABSENT.equals(wireValue)` behaves identically.** The anonymous subclass overrides `toString()`
  only, so `Object.equals` — reference identity — is inherited unchanged. The single use site
  (`ReportControllerUnitTest:466`, `if (!ABSENT.equals(wireValue))`) therefore still means "is this
  the sentinel object", which is what the matrix needs for the key-absent row. The field is
  initialised in a static initialiser, so the anonymous class captures no enclosing instance.
* **The parameterised name is now deterministic.** JUnit's `ParameterizedTestNameFormatter` renders
  `{0}` through `StringUtils.nullSafeToString`, which calls `toString()` → `<absent>`. The previous
  `new Object()` rendered `java.lang.Object@<identityHashCode>`, which varies per JVM run — so the
  stated problem was real and the fix resolves it. The `null` row still renders as `null`, and the
  `<>` characters are XML-escaped in the surefire report.

No finding.

### L-2 (the lead's numbering, i.e. the sibling-fixture claim) — L-2 · LOW, the one false replacement

`StockrecordExportClientFilterIT.java:183-184` asserts, in prose:

> Latent rather than live — **all three sibling classes that insert `stockrecord` set `created` and
> clean up** — but closed anyway…

The three siblings are `StockrecordAdjustmentAlertDoubleToastIT`, `ClientRepositoryTransactionDetailIT`
and `StockrecordViewSchemaIT` (grep for `INSERT INTO stockrecord` across `src/test`, four hits
including this class). The `created` half is **true for all three** — all name `created` in the column
list and pass `now()` or a literal timestamp.

**The cleanup half is false for `StockrecordViewSchemaIT`.** It has no `DELETE FROM stockrecord`
anywhere (grep: zero hits), inserts ids `9903410`-`9903412`, and never removes them.

**The conclusion still holds, for a reason the comment does not name and which is stronger than the
one it does.** `StockrecordViewSchemaIT` runs against **its own** container:

```java
// src/test/java/net/aim_ai/wms/integration/schema/StockrecordViewSchemaIT.java:94-98
private static final PostgreSQLContainer<?> DB =
    new PostgreSQLContainer<>(AppPostgresDBContainer.IMAGE) ...
// DB.start() in @BeforeAll, DB.stop() in @AfterAll
```

— not the `AppPostgresDBContainer.container` singleton that `BasePostgresIntegrationTest` binds. Its
rows can never reach this lane's table at all, cleanup or no cleanup. Only the *other two* siblings
share the container, and those two do clean up.

Worth correcting rather than shrugging at, for the reason this repo already records under
`fixing-a-false-claim-tends-to-produce-a-new-one`: this comment is the third revision of the same
paragraph, and it invites a reader to assume shared-container hygiene that does not exist.

**Fix.** Replace with: *"Latent rather than live — of the three sibling classes that insert
`stockrecord`, two share this container and both set `created` and delete their rows, and the third
(`StockrecordViewSchemaIT`) runs on its own throwaway container and cannot reach this table — but
closed anyway, because…"*

---

## 3 · `filterReachesRepository` — L-1 · LOW, a javadoc describing the withdrawn prescription

`src/test/java/net/aim_ai/wms/unit/service/ReportServiceUnitTest.java:546-548`

> ⚠ The `never()` verifications use `anyLong()`/`anyInt()`, never `any()` …

**Both halves are wrong about the code directly beneath them.** Lines 570-574:

```java
verify(stockrecordRepository, never())
    .findByClientOffsetAndLimit(any(), eq(-1L), anyInt(), anyInt());
verify(stockrecordRepository, never())
    .findByClientOffsetAndLimit(any(), isNull(), anyInt(), anyInt());
```

* `anyLong()` appears in **no** `never()` verification — only in the `when(...)` stub at line 553.
* The verifications **do** use `any()`, at position 1.

The rule the code actually follows is the narrower and correct one: *never widen a **primitive**
parameter to `any()`*. Positions 3 and 4 are declared `int`, so `anyInt()` is required there;
position 1 is a `String`, where `any()` is fine; position 2 is a boxed `Long` matched with
`eq(-1L)`/`isNull()`. Both §7.3's trailing ⚠ and `NeverMatcherNullBlindnessArchTest`'s own inventory
comment (lines 506-513) state it that way. This javadoc is the only place that overstates it — and it
overstates it into a form that contradicts the very lines it introduces.

Pre-existing in `97ee9e3e`, so this is a residual the three earlier lanes had in front of them and did
not flag, not a regression from `1430296e`. I raise it because `1430296e` edited this exact method and
was the natural place to catch it, and because a mechanism claim that is false in a comment is the
category this repo treats as load-bearing.

**Fix.** *"⚠ The `never()` verifications never widen a **primitive** parameter to `any()`: positions 3
and 4 are declared `int`, so `anyInt()` is required — a bare `any()` returns `null` and NPEs at
unboxing, which reads as a test defect rather than as the assertion it is. Position 1 is a `String`,
where `any()` is correct, and position 2 is a boxed `Long` narrowed to `eq(-1L)`/`isNull()` because
`anyLong()` would match the two prior invocations in this same method."*

### §7.3 vs the code — the corrected prescription MATCHES

The plan's corrected §7.3 row prescribes `never()).findByClientOffsetAndLimit(any(), eq(-1L),
anyInt(), anyInt())` plus a second with `isNull()`, and notes the `anyInt()`s are required on
positions 3-4. That is verbatim what the code does. The correction is right, and the withdrawn
`anyLong()` form would indeed have failed against correct code — the same method invokes the filtered
method twice (`60500L`, `0L`) before the `never()`, and `anyLong()` matches both.

---

## 4 · Plan document (Q4)

### Could a reader come away with the wrong export-plan criterion?

**Mostly no.** The navigation now works: §5.2 P3 opens with "⚠ Read P1's item (b) above before gating
this phase" and closes that paragraph with "Read item (b), **not** §9A's table, for the current
criterion." §9A's 760 ms table is explicitly annotated as measured on a container "where
`index_stockrecord_client_created` did not exist", its conclusion is marked **FALSE**, and its
suggested restatement is marked **WITHDRAWN**. Item (b) ends on the condition-form criterion — *given
`index_stockrecord_client_created` exists on the tenant, the filtered export plans as an ordered index
walk with no `Sort` in either arm* — which is the right shape and states its precondition.

### L-3 · LOW — but item (b)'s closing sentence is stale and inverts its own conclusion

The last sentence of §5.2 P1 item (b):

> The 0.455 ms figure is custom-plan-and-literal; **the generic-plan claim currently rests on the
> qual's shape**, because `hypopg` is not installed on that server (`pg_available_extensions` → 0;
> control: 61 rows) and building a 276 MB index was outside the read-only review lanes.

That sentence is from the era **before** `V2.2.33` reached `dev_wh01_om1`. It says the generic-plan
claim is *inferred, not measured* — while the `EXPLAIN EXECUTE p3exp('receiv', 60500, 0, 100)` output
six paragraphs above it is a `force_generic_plan` measurement with real `PREPARE`/`EXECUTE` binds on
that exact tenant with the index applied. The `hypopg` rationale is moot once the real index exists;
there is nothing left to simulate.

A reader following normal reading order stops at the end of the bullet and comes away believing the
criterion rests on the shape of the qual. That is the opposite of what the item establishes, and it is
the same failure mode the item itself names two paragraphs earlier ("this criterion has now been wrong
twice in opposite directions").

**Fix.** Delete from *"The 0.455 ms figure…"* to the end of that bullet, or mark it as history the way
the two preceding revisions are marked. §9A's "Still owed — DISCHARGED" already carries the honest
residual (*"⚠ Absolute milliseconds were not re-taken — this measured plan SHAPE"*), which is the
accurate caveat and does not need this sentence's help.

---

## 5 · Rails and inventories swept — none go red

| Rail | Why the diff is safe |
|---|---|
| `TestIdentifierCountArchTest` | `DISPLAY_NAME_COUNT` needs `the\|exactly\|all` + a **2-digit** number + a lowercase word inside one unbroken `"…"`. Neither new `@DisplayName` matches. `METHOD_NAME_COUNT` needs `Exactly\|All` + a number-word; `filteredExportIsNotAnExportedSearch` has neither |
| `CommentOnlyTestBodyArchTest` | `noEnabledTestMethodIsEmpty` filters on `getAccessesFromSelf().isEmpty()`. L-1 replaced an assertion with a 12-line comment, but `unfilteredExportRouteIsUnchanged` retains a live `assertThat` chain, so it has accesses. This was the rail most exposed by that fix |
| `TestClassTransactionManagerArchTest` | `ALLOWED` is empty; `EXEMPT_NON_TRANSACTIONAL` is a frozen set compared with `isEqualTo`. The new class extends `BaseRollbackIntegrationTest` and declares no `@Transactional` of its own, so it needs an entry in neither |
| `NeverMatcherNullBlindnessArchTest` | `"ReportServiceUnitTest:8"` intact at line 514, and its comment's arithmetic is correct (2 `never()` sites × the 3rd and 4th **primitive `int`** parameters = 4 new positions; the boxed `Long` at position 2 adds none). `1430296e` adds no `never()`, so 8 still holds |
| SDR surface counts | `SdrUncalledSurfaceNotExportedContextTest.WITHDRAWN hasSize(27)`, `SdrWriteWithdrawalContextTest hasSize(49)`/`(9)` are self-consistency pins on literal arrays; the exported-search floors are `isGreaterThan(100)`. An `exported = false` method perturbs none of them |
| surefire / failsafe | `*ContextTest` matches neither surefire exclude, so the new class runs in surefire with its 15 siblings. No pom edit owed |

### `p3-code-review.md`'s H-1 and M-1 are discharged

* **H-1** — `git ls-files --error-unmatch src/test/java/net/aim_ai/wms/security/StockrecordExportWithdrawalContextTest.java` resolves; the file is tracked in `1430296e`.
* **M-1** — the branch is now `[ahead 2]` of `origin/develop` with `97ee9e3e` sitting on `3214a9c3`,
  which contains `86180b4d`. Both inventory entries survived the rebase: `86180b4d`'s own
  `"MobileMoveUnitloadServiceUnitTest:1"` at line 455 (with its SBDEV-3452 comment at 451) and P3's
  `"ReportServiceUnitTest:8"` at line 514. The merge risk that finding named did not materialise.

---

## 6 · What I could not check, and the commands for you

Read-only lane, no `mvn`. Everything above is derived from source — the repository declarations, the
`spring-data-rest-core-4.5.7` sources in `~/.m2`, the migration DDL, and the rails' own patterns — so
none of it is waiting on an execution. What execution would add:

```bash
cd /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p3

# 1. the new file's lane, plus the two rails most exposed by the L-1 comment-for-assertion swap.
#    `clean` because `mvn test` runs DELETED test classes from a stale target/test-classes;
#    `,` not `+` between selectors, or the selector matches nothing and leaves stale XML.
mvn clean test -Dtest='StockrecordExportWithdrawalContextTest,CommentOnlyTestBodyArchTest,TestIdentifierCountArchTest,NeverMatcherNullBlindnessArchTest,TestClassTransactionManagerArchTest,ReportControllerUnitTest,ReportServiceUnitTest,StockrecordExportQueryContractUnitTest'

# 2. M-1's proof, if you want it measured rather than read out of the SDR source: comment out the
#    isNotNull() block and confirm NOTHING changes — same green, same count. An assertion whose
#    removal changes no outcome is the definition of the finding.

# 3. M-2's proof: rename findByClientOffsetAndLimit -> findByClientOffsetAndLimitX in the repository
#    AND update StockrecordExportQueryContractUnitTest's FILTERED constant to match.
#    Expect StockrecordExportWithdrawalContextTest to stay GREEN. That is the vacuity.

# 4. the floor — both lanes, against the known baseline
mvn clean test
mvn clean verify
```

---

## 7 · Method and limits

* Subject was exactly `git diff 97ee9e3e..1430296e` — 4 files, +149/-22. I read the three prior P3
  reports' finding indexes first and reviewed the delta; I did not re-derive the byte-identity claim,
  the `toFilterId` cast, or the `4 → 8` inventory arithmetic beyond confirming `1430296e` leaves them
  untouched.
* Mechanism claims were checked against **source**, not javadoc: `spring-data-rest-core-4.5.7-sources.jar`
  for `SearchResourceMappings` / `RepositoryResourceMappings` / `RepositoryMethodResourceMapping`,
  `V2.2.00__base_v2_schema.sql:2166` for `created`'s nullability, `RestConfiguration.java:891` for the
  detection strategy, and the two `pom.xml` plugin blocks for lane membership.
* **Not covered:** whether the suite is green (no execution); anything in `97ee9e3e` beyond the three
  spots `1430296e` touches; the UI half of P3; and authorization — an un-exported path is unreachable,
  not refused, and nothing here changes the `wms_user`-only gate on `/v3/**`.
* A pass on the two Mediums above would not have been available to the three earlier lanes: the new
  file did not exist in `97ee9e3e`.
