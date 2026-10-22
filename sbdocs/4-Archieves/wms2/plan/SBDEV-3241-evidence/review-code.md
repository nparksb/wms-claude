# SBDEV-3241 — code review of the SBDEV-2099 marker removal

**Reviewed:** working-tree changes in `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3241`,
branch `bugfix/SBDEV-3241-2099-marker-audit`, base `origin/develop @ d4a6ab8a`.
**Date:** 2026-09-06. **Mode:** read-only static review. **Maven was not run** — every claim below is
derived from the source and the diff, not measured. Where a claim depends on runtime behaviour
(persistence-context semantics, thread reuse) I say so at the finding.

**Verdict: the un-suppression itself is clean, but it lets one permanently-green vacuous test out of
the cage (V-1, High) and leaves seven comments across six files asserting the state it just removed.**

Diff scope confirmed: 22 files, 61 lines removed / 25 added, 19 `@Disabled` deleted, 3 added at method
level, 18 imports removed.

---

## 1. Vacuity — the 35 newly-running tests

Method: read every test in the 19 files whose marker was deleted plus the passing halves of the 3
converted files. Arithmetic cross-check: 17 repo + 12 service + 2 (`OrderReleaseJobUnitTest.DoCalculation`)
+ 4 (passing halves of the three mixed classes) = **35**, matching the measured `skipped 67 → 32`.

### V-1 — HIGH — a permanently-green test that asserts nothing, four lines from the one the change disabled for exactly this reason

`src/test/java/net/aim_ai/wms/unit/repo/CustomerorderBatchRepositoryTest.java:62-73`

```java
@Test
@DisplayName("A10 — findStaleClubBatchIds should exclude batch when one child order is still open")
void findStaleClubBatchIds_shouldExcludeActiveBatch_whenOneOrderStillOpen() {
    // Requires Testcontainers: seed CLUB batch state=530, one order state=700, one state=650
    // TODO(SBDEV-2164): seed data via JPA; assert ... does NOT return the batch id
    assertThat(batchRepository.findStaleClubBatchIds(ORDER_BATCH_ACTIVATED, FINISHED, 500))
        .as("Mixed-state CLUB batch must NOT be returned").isEmpty();
}
```

The seeding named in its own TODO (`:66`) was never written. The table is empty, so `findStaleClubBatchIds`
returns empty, so `.isEmpty()` passes — and would pass for a query that returns empty unconditionally,
a query with an inverted predicate, or a query that was deleted. It pins nothing about the exclusion
semantics it is named for.

What makes this the sharpest finding: **the change diagnosed this exact cause four lines above.** The new
`@Disabled` reason on A9 (`:48-50`) says *"The TODO(SBDEV-2164) seeding was never written, so the query has
no rows to find."* That is equally true of A10; the only difference is that A9's assertion is `isNotEmpty()`
so the missing seeding turns red, and A10's is `isEmpty()` so it turns green. The change acted on the red
one and shipped the green one as live coverage. Before this change A10 was skipped and honest; after it, it
is a passing row in the report that a reader will count.

**Recommend:** disable A10 with the same SBDEV-3241 reason (its assertion is unreachable for the same
cause), or write the seeding for both. Do not leave it green. The in-file comment at `:41-44` should also
stop saying only "The A9 test below fails on its own assertion and keeps a marker" — it reads as if A10
were fine.

### V-2 — MEDIUM — four `save()` → `findById()` round trips assert a value the test set, from the first-level cache

| File | Lines |
|---|---|
| `unit/repo/AdvicepositionRepositoryTest.java` | `:30-37` |
| `unit/repo/BillofladingPositionRepositoryTest.java` | `:29-36` |
| `unit/repo/CustomerorderPositionRepositoryTest.java` | `:35-42` |
| `unit/repo/CustomerorderBatchRepositoryTest.java` | `:31-38` |

All four are `repo.save(x); Optional<T> found = repo.findById(x.getId()); assertThat(found).isPresent();
assertThat(found.get().getSomeField()).isEqualTo(<the literal set 6 lines earlier>);`

Mechanism, from the code:

- `AbstractBaseEntity:19-25` uses `GenerationType.SEQUENCE` (`seqentities`, `allocationSize = 1`). `save()`
  on a new entity therefore fetches an id from the sequence but does **not** execute the INSERT — that is
  deferred to flush.
- `SimpleJpaRepository.findById` is `em.find(...)`. For an entity already managed in the persistence
  context this is served from the first-level cache: no flush, no SQL, and the returned reference is the
  *same object* the test constructed. `found.get().getNumber()` is literally `x.getNumber()`.
- `BaseRepositoryIntegrationTest` is `@Transactional` (`common/base/BaseRepositoryIntegrationTest.java:26`),
  so the transaction rolls back and — since nothing forced a flush — the INSERT plausibly never runs at all.

Residual content of each test: "`save()` did not throw and assigned an id." Table creation is proven by
context startup (`ddl-auto=create-drop`), not by these. Per-row column mapping, nullability and value
binding are not exercised.

**Recommend:** either add an explicit `entityManager.flush(); entityManager.clear();` between save and find
(which makes the find a real SELECT and the assertion real), or query by a business key rather than the
primary key, as the eight sibling tests already do.

This is not a defect the change introduced — it inherited these bodies verbatim. But it is the difference
between "35 tests now run" and "35 tests now cover something", and four of the 35 are in this bucket.

### V-3 — LOW — three second assertions that restate the query key

| File:line | Shape |
|---|---|
| `unit/repo/LocationRepositoryTest.java:44` | `findByName("LOC-P01-01-01")` → assert `getName()` equals `"LOC-P01-01-01"` |
| `unit/repo/UnitloadRepositoryTest.java:34` | `findByLabelid("UL-001")` → assert `getLabelid()` equals `"UL-001"` |
| `unit/repo/UserRepositoryTest.java:35` | `findByName("testuser")` → assert `getName()` equals `"testuser"` |

If `isPresent()` on the preceding line holds, the returned row's key field *is* the key by construction.
The second assertion cannot fail independently. Harmless, but it inflates the assertion count and reads as
coverage it is not.

For contrast, these six assert a **different** field than the key and do carry real content (derived-query
name → column mapping, forced by an AUTO flush before the JPQL query): `AdviceRepositoryTest:34-35, :52-53`,
`BillofladingRepositoryTest:36-37, :56-57`, `BoxtypeRepositoryTest:37-38`, `ClientRepositoryTest:33-34, :50-51`,
`CustomerorderRepositoryTest:41-42, :66-67`, `ItemdataRepositoryTest:37-38`, `StockunitRepositoryTest:36-37`.

### V-4 — MEDIUM — the three `adminTriggerDoesNotConsultTheTenantList` tests are now "live coverage" of the weakest available kind

| File:line |
|---|
| `unit/schedulejob/CleanUpOldMessagesJobUnitTest.java:93-113` |
| `unit/schedulejob/ReleaseExpiredPickingOrdersFromUserJobUnitTest.java:63-83` |
| `unit/schedulejob/OrderReleaseJobUnitTest.java:165-190` |

Each calls `job.runForCurrentTenant()` with no `TenantContext` and asserts exactly
`verify(tenantDbConfigurationRepository, never()).findByActiveTrue()`.

`runForCurrentTenant()` returns at its first branch when the context is null
(`ReleaseExpiredPickingOrdersFromUserJob.java:276-280`, `CleanUpOldMessagesJob.java:322-326`). So the
`never()` holds for:

- the intended refusal path;
- an empty method body;
- a method that throws before the branch;
- **and the leaked-context path too** — with a context set, the next call is
  `findByTenantNameAndWarehouse(...)` on a Mockito mock, which returns `Optional.empty()`, so the method
  still returns without ever touching `findByActiveTrue()`.

The contract these methods actually document is a return value:
`ReleaseExpiredPickingOrdersFromUserJob.java:271-273` — *"@return true if the release actually ran; false if
refused (no context, no landlord row, non-int4 id, lock-busy, or not activated) — so callers can surface
the real outcome instead of a hardcoded success."* All three tests discard it.

**Recommend:** `assertThat(job.runForCurrentTenant()).isFalse();`. One line, and it separates the four
refusal reasons from "returned normally".

This matters more than it would have before the change, because the change's own new comment at each site
now claims *"It is live coverage of the contract flip now, not just a record for a reader"* — that promotion
should come with an assertion that can distinguish outcomes.

### V-5 — MEDIUM — those same three tests depend on ambient thread state they never arrange

Each carries the comment `// Act — no ambient TenantContext, so this must refuse rather than fan out`
(`CleanUpOldMessagesJobUnitTest:108`, `ReleaseExpiredPickingOrdersFromUserJobUnitTest:78`,
`OrderReleaseJobUnitTest:185`) — but none of the three calls `TenantContext.clear()`, and neither
`BaseUnitTest` nor `BaseServiceUnitTest` does either.

`TenantContext` is process-level thread state. Surefire here is single-fork, single-thread — `pom.xml:558-577`
configures no `parallel`, `forkCount` or `threadCount`, and there is no `junit-platform.properties` in
`src/test/resources` — so one thread is reused across every class in the run and a leaked context carries
forward. Every other class in this package clears explicitly: `OrderReleaseJobUnitTest:236`,
`CleanUpOldMessagesJobUnitTest:169`, `AdminTriggerTenantScopeUnitTest:180`, `OrderReleaseJobTest:108`,
`ReplenishOrderJobTest:163`, `StockSummaryExportJobMetricsUnitTest:147`, `OrderReleaseJobStreamingTest:117`,
`OrderReleaseJobSectionGuardTest:126`, `ReplenishOrderJobConnectionBudgetTest:138`,
`CleanUpOldMessagesJobTest:91`.

Because of V-4 the assertion happens to survive a leak, so this will not go red — it will silently execute
a different path than the comment claims. Add `@BeforeEach void clearContext() { TenantContext.clear(); }`
to the two nested `DoCalculation` classes.

### V-6 — LOW — `PickingorderServiceH2Test.createPickingOrder` asserts a prefix of a value it stubbed

`unit/service/PickingorderServiceH2Test.java:36-44`

- `:42` `assertThat(order).isNotNull()` — cannot fail independently; `:43` would NPE first.
- `:43` `assertThat(order.getNumber()).startsWith("PICK")` — the test stubbed
  `basicService.generatePickOrderNumber()` to return `"PICK000001"` at `:36`. A prefix check on a value the
  test supplied. Assert equality with `"PICK000001"` instead — that still fails if `create()` ignores the
  generator, and additionally fails if it mangles the value.
- `:44` `findById(order.getId())` is the V-2 first-level-cache pattern again.

`getByNumber` (`:47-61`) is fine — it goes through a real derived query and compares ids.

### V-7 — LOW — one newly-enabled test is a strict subset of existing coverage in its own class

`unit/schedulejob/OrderReleaseJobUnitTest.java:151-162` (`shouldSkipProcessingWhenNoTenantsConfigured`)
stubs an empty tenant list and asserts one `never()`. The same class already has
`runFor_shouldEnumerateOnlyActiveTenants_viaFindByActiveTrue` (`:86-114`) and
`runFor_tenantNotMatchingSpec_isSkippedWithoutTouchingLockOrPerTenantMetrics` (`:116-145`), both strictly
stronger. Harmless; recorded so it is not counted as new coverage.

### Explicitly cleared as non-vacuous

`PickingorderBusinessServiceH2Test` (both tests — `NOT_SUPPORTED` propagation, real commits, cross-entity
assertions), `MobileReplenishServiceH2Test` (both), `AdviceServiceH2Test` (all three), `CustomerorderServiceTest`
(all three — note `batchUpdatePriorityByOrderIds` at `:140-144` would fail if the service used a bulk JPQL
update, since the cached instance would be stale; it passing is itself informative), and the six
derived-query repo tests listed under V-3.

---

## 2. Did the edit change any test semantics? — PASS

`git diff -U0 | grep -E '^[-+]' | grep -vE '^(\+\+\+|---)'` yields 61 removed and 25 added lines, and every
one of them is an `import org.junit.jupiter.api.Disabled;`, an `@Disabled(...)` annotation, or a `//` comment.

**Zero** changes to test bodies, assertions, fixtures, `@DisplayName` strings, `@Test`/`@Nested` annotations,
helper methods, or production code. No finding.

---

## 3. The three retained method-level markers

### M-1 — PASS on placement, PASS on cause

| Marker | On the method that fails? | Stated cause verified |
|---|---|---|
| `CustomerorderBatchRepositoryTest.java:48-50` | Yes — `findStaleClubBatchIds_shouldReturnBatch_whenAllOrdersTerminal` | Yes. `:53` TODO seeding absent → empty table → `.isNotEmpty()` at `:59` fails with the `.as("Seeded all-terminal CLUB batch must be returned")` description quoted verbatim in the reason. |
| `CleanUpOldMessagesJobUnitTest.java:75-79` | Yes — `shouldSkipProcessingWhenNoTenantsConfigured` | Yes. `runFor(spec)` → `CleanUpOldMessagesJob.java:158` empty list → `:161 jobMetrics.markLastSuccess()`, `jobMetrics` null. |
| `ReleaseExpiredPickingOrdersFromUserJobUnitTest.java:47-49` | Yes — `shouldSkipProcessingWhenNoTenantsConfigured` | Yes. `runFor()` → `ReleaseExpiredPickingOrdersFromUserJob.java:146` empty → `:149 jobMetrics.markLastSuccess()`, `jobMetrics` null. |

Pedantic note on the two job markers, not a finding: the NPE that actually propagates out is the one from
the `finally` block (`CleanUpOldMessagesJob.java:273`, `ReleaseExpiredPickingOrdersFromUserJob.java:233`,
both `jobMetrics.markLastRun()`), because it supersedes the one thrown inside the `try`. Same field, same
method, so the reason strings are right as written.

The sibling-passes claim in both reason strings also checks out: `runForCurrentTenant()` returns at its first
branch and never touches `jobMetrics`.

### M-2 — MEDIUM — the CleanUp reason string's dependency count is wrong and its arithmetic does not close

`CleanUpOldMessagesJobUnitTest.java:75-79` says:

> *"The class declares @Mock for 4 of the production constructor's 6 dependencies; AdvisoryLockService,
> SyspropService and JobMetrics are missing, so @InjectMocks leaves them null."*

4 + 3 = 7, not 6. The reason: one of the four `@Mock` fields is **not a constructor dependency at all**.
The class declares `@Mock private SyspropRepository syspropRepository` (`:53-54`), but the constructor takes
`SyspropService` (`CleanUpOldMessagesJob.java:111`). Mockito's constructor injection matches by type, so
`syspropRepository` injects nothing.

Actual state: 4 `@Mock` fields, of which **3** match constructor parameters (`CleanUpOldMessageJobService`,
`TenantDbConfigurationRepository`, `TimezoneService`); `SyspropService`, `AdvisoryLockService` and
`JobMetrics` are left null. The fields are `final`, so there is no field-injection fallback.

Suggested wording: *"declares 4 @Mocks, only 3 of which match constructor parameters — SyspropRepository is
not one of the six; SyspropService, AdvisoryLockService and JobMetrics are left null."*

The identical mis-mock exists in `ReleaseExpiredPickingOrdersFromUserJobUnitTest:29-30` (`SyspropRepository`
vs the constructor's `SyspropService` at `ReleaseExpiredPickingOrdersFromUserJob.java:120`) — that reason
string names no counts and so is not wrong.

### M-3 — MEDIUM — a comment the change rewrote is now false

`CleanUpOldMessagesJobUnitTest.java:65-66`, rewritten by this change:

> *"SBDEV-3198 step 5: doCalculation(Boolean) is gone — runFor(spec)/runForCurrentTenant() replace it.
> **Only the one test noted below is still @Disabled, so this spec is exercised by the rest.**"*

`ANY_SPEC` has exactly two references in the file: its declaration at `:67` and one use at `:85` — which is
inside the still-`@Disabled` test. Nothing in `RunForCurrentTenantLocking` touches it. The field is
currently dead, and "exercised by the rest" is false.

The old text ("This class stays @Disabled per the note below, so the spec's exact value is immaterial") was
correct; it was replaced with an incorrect one. Contrast `OrderReleaseJobUnitTest`, where `ANY_SPEC` really
is used by four tests (`:110, :135, :158`) — the sentence appears to have been written for that file's
situation and applied to this one.

---

## 4. Comments still asserting the old state

### C-1 — MEDIUM — the one file whose comment block was not rewritten is the file the change un-suppressed

`unit/schedulejob/OrderReleaseJobUnitTest.java:172-181` still reads:

> *"Kept and inverted rather than deleted. ⚠ But this assertion DOES NOT RUN: the enclosing @Nested class
> is @Disabled, so neither the old nor the new version has ever executed. Treat it as a record of the
> contract flip for a reader, not as coverage. Every executing pin for this behaviour is in
> AdminTriggerTenantScopeUnitTest.*
> *The @Disabled reason above is also inaccurate — enabling this class fails with "advisoryLockService is
> null" ... Fixing that is a separate cleanup (plan §5.3 flags these six tests already)."*

The `@Disabled` it refers to is the one this change deleted, and "the @Disabled reason above" now refers to
nothing. Its two siblings received exactly this rewrite (`CleanUpOldMessagesJobUnitTest:100-103`,
`ReleaseExpiredPickingOrdersFromUserJobUnitTest:70-73`); this third one was missed. Also at `:189-190`
`"replacement (still un-executed, same @Disabled class)"` — the sibling files got that phrase updated to
`"(now executing, per SBDEV-3241)"`, this one did not.

### C-2 — LOW — unused import left behind in that same file

`unit/schedulejob/OrderReleaseJobUnitTest.java:26` — `import org.junit.jupiter.api.Disabled;` with no
remaining `@Disabled` annotation in the file (`grep -n "Disabled"` returns only this import plus the C-1
comment lines). Compiles with a warning. It is the only one of the 19 files whose import was not removed —
consistent with C-1, both look like the same missed file.

### C-3 — MEDIUM — the class the removed markers pointed readers to now describes a world that no longer exists

`unit/schedulejob/AdminTriggerTenantScopeUnitTest.java:100-111` (class javadoc, not in the diff):

> *"⚠ But do not count them as coverage, and an earlier version of this javadoc did. All three sit inside
> @Nested @Disabled class DoCalculation, so neither the old assertion nor the new one has ever executed —
> surefire reports skipped=2 for each of those classes. The inversion is a record for a human reader, not a
> running assertion. **Every executing pin for this behaviour is in this class.**"*
>
> *"Their @Disabled reason is also wrong ... enabling CleanUpOldMessagesJobUnitTest fails with
> NullPointerException: ... "this.advisoryLockService" is null — the class never wires its mocks."*

After this change: all three `DoCalculation` classes run, `skipped=2` is no longer true for any of them, the
three inverted assertions **are** executing pins, and "every executing pin is in this class" is false.

Secondary: this javadoc names `advisoryLockService` as the null field while the three new markers name
`jobMetrics`. Both are null; which one the JVM reports depends on which line executes first. Worth
reconciling to one account so a future reader does not think one of them is wrong.

### C-4 — MEDIUM — three test classes justify their own existence on the premise this change removed

| File:line | Claim, now false |
|---|---|
| `unit/repo/ScanResolutionQueryDerivationUnitTest.java:39` | *"invisible to the *RepositoryTest classes, because `LocationRepositoryTest` is `@Disabled` for a pre-existing datasource problem"* |
| `unit/repo/OnHandQueryContractUnitTest.java:22` | *"there is no `@DataJpaTest` anywhere in src/test, and `unit/repo/StockunitRepositoryTest` is `@Disabled`. So the new native SQL would otherwise ship with its correctness resting entirely on manual rows M4-M6."* |
| `unit/repo/UnitloadRepositoryTransferableAreasContractTest.java:30` | *"per plan §7.4 nothing in this repo does (`UnitloadRepositoryTest` is `@Disabled`, everything else mocks the repository...)"* |

All three named classes now run. The reflection-only design of these three tests may still be right on other
grounds (the enabled classes exercise derived queries, not the native `@Query` text these pin), but the
stated ground is gone and a reader will now be misled about what the repo lane can do.

### C-5 — LOW — `service/TransferLaneLeakOnCancelIT.java:23`

> *"and the H2 `LocationRepositoryTest` slice is itself `@Disabled` (landlord-datasource env gap)"* — false now.

### C-6 — LOW — dangling cross-reference in a marker the change did not touch

`integration/repository/ClientRepositoryIntegrationTest.java:259` — its `@Disabled` reason cites
*"same root cause as `BillofladingPositionRepositoryTest` `@Disabled`"*. That marker no longer exists, so the
cross-reference points at nothing. The IT's own SBDEV-2217 cause is unaffected; only the pointer is stale.

### C-7 — LOW / no action — `src/test/resources/application.properties:126`

> *"which also makes the 'landlord datasource not configured (SBDEV-2099)' note on the two @Disabled H2
> MockMvc tests a stale attribution."*

Still accurate: both MockMvc classes (`CustomerOrderControllerH2Test:35`, `ReplenishOrderControllerH2Test:26`)
are still `@Disabled` with that note. Listed only so a straggler sweep does not "correct" it by mistake.

### C-8 — INFO / no action — `smoke/WebContextLaneContextTest.java:20, :31-32`

Phrased forward-looking (*"whether the @Disabled markers citing ... have any remaining cause of their own"*)
and still true of the five markers that remain. No change needed.

### Correctly not touched (per instruction, confirmed absent from the diff)

`unit/service/ViewDtoServiceUnitTest.java:2285, :2351, :2384` and `unit/controller/ReportControllerUnitTest.java:848, :873`
— `@DisplayName` strings citing SBDEV-2099 as the v2 port of the real v1 fix. Also
`repo/jpa/LocationRepository.java:274` and `repo/jpa/UnitloadRepository.java:239` in `src/main`, same reason.

---

## 5. Scope and consistency

### X-1 — MEDIUM — five markers still assert the disproven reason verbatim

27 − 19 deleted − 3 converted = 5 remaining, so this matches the change's stated scope. They are:

| File:line | Level |
|---|---|
| `unit/controller/CustomerOrderControllerH2Test.java:35` | class |
| `unit/controller/ReplenishOrderControllerH2Test.java:26` | class |
| `unit/service/SequenceTransactionServiceUnitTest.java:46` | method |
| `unit/service/SequenceTransactionServiceUnitTest.java:228` | method |
| `unit/controller/mobile/PickingControllerUnitTest.java:377` | method |

All five still read `"Pre-existing env issue: landlord datasource not configured (SBDEV-2099 env skip)"`.

The ticket's premise is that this string is false. Leaving them enabled-as-is is defensible (they belong to
the "26 genuinely broken" bucket and enabling them is out of scope), but **the reason strings are the cheap
half and were not fixed**. Anyone who reads one of these five still gets the wrong cause, and the next
person to audit markers will re-derive the same finding. Recommend re-wording all five to name the real
cause — or, if the real cause per marker was not measured, a placeholder such as
`"SBDEV-3241: reason unverified; the SBDEV-2099/landlord-datasource attribution is known false — see plan"`.

### X-2 — INFO — arithmetic cross-check passes

17 repo tests + 12 service tests + 2 (`OrderReleaseJobUnitTest.DoCalculation`) + 4 (passing halves of the
three converted classes) = 35, matching the reported `skipped 67 → 32`. No test was silently gained or lost.

### X-3 — LOW — a newly-enabled class now commits into the H2 instance every other newly-enabled class shares

`unit/service/PickingorderBusinessServiceH2Test.java:21` is `@Transactional(propagation = NOT_SUPPORTED)`
with a 14-repository `deleteAll()` `@AfterEach` (`:75-91`). The datasource is
`jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1` (`application-integration.properties:9`, `:19`), JVM-wide and
shared by every class in this batch. Before this change the class was disabled and committed nothing; now it
does.

Surefire is single-threaded here (see V-5), so this is an ordering hazard rather than a race, and the
teardown covers the happy path. But if the class ever aborts before `@AfterEach` — a JVM error, a
`deleteAll` FK failure part-way down the list — the leftover rows will break `Optional`-returning derived
finders in sibling classes, e.g. `PickingorderServiceH2Test:64` `clientRepository.findByClNr(...)` raising
`IncorrectResultSizeDataAccessException` on two rows. Worth a `@BeforeEach` cleanup or a note in the class;
no action strictly required.

---

## Summary table

| ID | Sev | Where | One line |
|---|---|---|---|
| V-1 | **High** | `CustomerorderBatchRepositoryTest:62-73` | A10 now runs permanently green on an unseeded table — same missing seeding the change cited when disabling A9 |
| V-2 | Medium | 4 files (`Adviceposition/BillofladingPosition/CustomerorderPosition/CustomerorderBatch RepositoryTest`) | `save()`→`findById()` returns the same object from the L1 cache; SEQUENCE ids mean the INSERT likely never runs |
| V-3 | Low | `Location:44`, `Unitload:34`, `User:35` `RepositoryTest` | second assertion restates the query key; cannot fail independently |
| V-4 | Medium | 3 × `adminTriggerDoesNotConsultTheTenantList` | `never()`-only; passes on an empty method body; discards the documented `false` return |
| V-5 | Medium | same 3 tests | depend on "no ambient TenantContext" but never clear it; every sibling class does |
| V-6 | Low | `PickingorderServiceH2Test:42-44` | asserts a prefix of the value it stubbed; `isNotNull()` cannot fail independently |
| V-7 | Low | `OrderReleaseJobUnitTest:151-162` | strict subset of two stronger tests in the same class |
| S-1 | — | whole diff | **PASS** — only imports, annotations and comments changed; no body/assertion/fixture/`@DisplayName` edits |
| M-1 | — | 3 retained markers | **PASS** — right methods, causes verified against the production source |
| M-2 | Medium | `CleanUpOldMessagesJobUnitTest:75-79` | "4 of 6 dependencies" is wrong — one @Mock is `SyspropRepository`, not a constructor param; 3 of 6 wired |
| M-3 | Medium | `CleanUpOldMessagesJobUnitTest:65-66` | new comment claims `ANY_SPEC` is "exercised by the rest"; its only use is in the still-disabled test |
| C-1 | Medium | `OrderReleaseJobUnitTest:172-181, :189-190` | stale "this assertion DOES NOT RUN / the @Disabled reason above" block — the one file whose rewrite was missed |
| C-2 | Low | `OrderReleaseJobUnitTest:26` | unused `import ...Disabled;` — the only one of 19 files not cleaned |
| C-3 | Medium | `AdminTriggerTenantScopeUnitTest:100-111` | javadoc still says the three siblings never execute and "every executing pin is in this class" |
| C-4 | Medium | `ScanResolutionQueryDerivationUnitTest:39`, `OnHandQueryContractUnitTest:22`, `UnitloadRepositoryTransferableAreasContractTest:30` | three classes justify their own design on "that RepositoryTest is @Disabled" |
| C-5 | Low | `TransferLaneLeakOnCancelIT:23` | same stale premise |
| C-6 | Low | `ClientRepositoryIntegrationTest:259` | `@Disabled` reason cross-references a marker that no longer exists |
| C-7 | Low | `application.properties:126` | still accurate — do not "fix" it |
| C-8 | Info | `WebContextLaneContextTest:31-32` | still accurate for the 5 remaining markers |
| X-1 | Medium | 5 markers in 4 files | still carry the disproven SBDEV-2099 reason string verbatim |
| X-2 | Info | — | 35-test arithmetic reconciles exactly |
| X-3 | Low | `PickingorderBusinessServiceH2Test:21, :75-91` | newly commits into the shared in-memory H2; ordering hazard if teardown ever aborts |

## What I would fix before merge

1. **V-1** — disable A10 or seed both. This is the one finding that makes the branch net-negative for a
   reader: it converts a skip into a false green.
2. **C-1 + C-2** — finish the rewrite on `OrderReleaseJobUnitTest`; the change did this correctly on two of
   three files.
3. **M-3** and **M-2** — two new comments that state something false.
4. **C-3** — one line of javadoc in `AdminTriggerTenantScopeUnitTest` that now actively misdirects.
5. **X-1** — reword the five surviving reason strings, even if they stay disabled.

V-2 / V-4 / V-5 are worth a follow-up but are inherited, not introduced, and do not block.
