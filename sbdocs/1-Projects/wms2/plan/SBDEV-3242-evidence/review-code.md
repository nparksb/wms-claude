# SBDEV-3242 — independent code review

**Scope**: `be04502d..HEAD` (3 commits, 4 files) on `bugfix/SBDEV-3242-repo-test-rollback-tx-manager`,
worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3242`.
**Method**: read-only. `git diff` / `git log` / `git grep` / targeted reads, plus the Spring 6.2.15
*sources* jar from `~/.m2` (`spring-test-6.2.15-sources.jar`) to settle the propagation question from
the framework source rather than from recollection. No Maven, no git state changes.

**Verdict**: the fix is correct and the diagnosis is right. Ship it after fixing **F1** (a
non-vacuity assertion that does not assert what its message claims) and after deciding what to do
about **F3** (this change silently disarms two existing regression assertions in
`MessageRepositoryIntegrationTest`). The rest are documentation-accuracy and rail-coverage findings.

**Two findings the brief did not ask about and that I would not have expected**: F3 (coverage lost
in an unrelated test as a *consequence* of the fix) and F4 (the root-cause narrative, repeated
verbatim in three places, states Spring's manager-resolution order backwards — the conclusion is
right, the mechanism is not, and the mistake would mislead the next reader into a fix that does not
work).

---

## Findings, severity-rated

### F1 — MEDIUM — `nonVacuityGuard`'s "properly qualified" assertion counts annotations that name no manager

`TestClassTransactionManagerArchTest.java:100-107`:

```java
long qualified = testClasses.stream()
    .filter(c -> c.isAnnotatedWith(Transactional.class))
    .filter(c -> !isBare(c.getAnnotationOfType(Transactional.class)))
    .count();
```

`isBare()` returns `false` for two distinct reasons — "names a manager" **and** "is exempt because
propagation is `NOT_SUPPORTED`/`NEVER`". `!isBare(...)` therefore conflates them. The message
attached to the assertion says:

> positive control: at least one test class must carry a **PROPERLY QUALIFIED** `@Transactional`,
> proving this rule can tell the two apart rather than simply never matching anything

It does not prove that. Enumerating every class-level `@Transactional` in `src/test`
(`grep -rn '^\s*@Transactional\b' src/test`, 20 sites total, of which 3 are class-level):

| class | annotation | counted as "qualified"? | actually qualified? |
|---|---|---|---|
| `BaseRepositoryIntegrationTest` | `@Transactional("tenantTransactionManager")` | yes | yes |
| `integration/service/WarehouseStockReportServiceStreamIT:46` | `@Transactional("tenantTransactionManager")` | yes | yes |
| `unit/service/PickingorderBusinessServiceH2Test:21` | `@Transactional(propagation = NOT_SUPPORTED)` | **yes** | **no — names no manager** |

So `qualified == 3` today, and the guard would still pass at `qualified == 1` with that one being the
`NOT_SUPPORTED` class, i.e. with **zero** properly-qualified classes in the repo. Fix:

```java
.filter(c -> { Transactional t = c.getAnnotationOfType(Transactional.class);
               return !t.value().isEmpty() || !t.transactionManager().isEmpty(); })
```

**On the brief's specific worry — is the assertion self-referential?** No.
`WarehouseStockReportServiceStreamIT` carries a class-level `@Transactional("tenantTransactionManager")`
and predates this change, so reverting `BaseRepositoryIntegrationTest` would leave the count at 2 and
the guard would still pass. That is the intended behaviour for a vacuity guard (it is not supposed to
be a regression guard — the contract test is), so no finding there beyond F1.

### F2 — MEDIUM — the `NOT_SUPPORTED`/`NEVER` exemption is an unguarded escape hatch that reproduces this exact defect

The exemption's **stated reasoning is correct** — see the Q3 answer below, confirmed from Spring
source, for both propagations. But the consequence deserves saying out loud, and the commit message
does the opposite:

> The rule tests the right axis, not the literal

The axis the rail actually enforces is *"an annotation that will use a transaction manager must name
one."* The invariant this ticket exists to protect is *"writes made by a repository test must roll
back."* Those are not the same, and `@Transactional(propagation = NOT_SUPPORTED)` is precisely where
they come apart: it produces **exactly** the SBDEV-3242 behaviour — no test transaction, every
`save()` commits into the shared `jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1` for the life of the
JVM — and the rail blesses it.

`PickingorderBusinessServiceH2Test` is a live instance: it extends `BaseRepositoryIntegrationTest`,
its own class-level `NOT_SUPPORTED` overrides the base class's qualifier, and its writes leak today,
after this fix, with the rail green. Whether that is deliberate for that one class is a fair call —
but a future author who wants the rail quiet has a one-token way to get it, and it is the wrong one.

Recommendation: keep the exemption (it is technically right), but require the exempt classes to be
*named*, e.g. a small frozen `EXEMPT` set alongside `ALLOWED`, so a new `NOT_SUPPORTED` is a
deliberate list edit rather than an invisible pass. At minimum, add the sentence to the javadoc: *"a
NOT_SUPPORTED test class leaks its writes by design; that is allowed here but it is not free."*

### F3 — MEDIUM — the fix silently makes two existing regression assertions vacuous, and the A/B evidence cannot see it

`src/test/java/net/aim_ai/wms/integration/repository/MessageRepositoryIntegrationTest.java`
(a `BaseRepositoryIntegrationTest` subclass) routes its deletion tests through
`MessageCleanupBatchService.deleteOnce`, which is
`@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`
(`service/job/MessageCleanupBatchService.java:62`).

- **Before** this change, the test's `messageRepository.save(...)` calls committed on their own tenant
  transactions — the defect. The `REQUIRES_NEW` sub-transaction therefore *saw* those rows and deleted
  them: `shouldDeleteOldMessages` got `deleted == 1`, and
  `deleteMessages_respectsBatchSizeLimit` (line 288/290) got `firstBatch == 2`, `secondBatch == 2`,
  which is what makes `assertThat(firstBatch).isLessThanOrEqualTo(2)` a real test of the
  `LIMIT :batchSize` bind parameter (its stated purpose — SBDEV-2220 Fix B/D).
- **After** this change the seeds are uncommitted inside the outer tenant transaction, the suspended
  `REQUIRES_NEW` transaction cannot see them, and both counts become **0**. `deleted >= 0` and
  `firstBatch <= 2` are then trivially true regardless of whether the native query honours `LIMIT` at
  all.

The tests stay green, which is exactly why the "failsafe A/B identical" evidence cannot detect this:
the assertions were written loosely enough (`isGreaterThanOrEqualTo(0)`, `isLessThanOrEqualTo(2)`,
and the comment at line 291-295 already anticipates the visibility problem) that they absorb the
change. "No new breakage in either lane" is true; "no behaviour change" is not, and the commit
message reads as the latter.

This is not a reason to withhold the fix — the fix is right and the test was already weak. It is a
reason to (a) say so in the commit message, and (b) either flush the seeds (`saveAndFlush` does not
help across a `REQUIRES_NEW` boundary — the seeds would need to be created inside their own committed
transaction, or the test moved off the outer transaction) or file the coverage loss onto the existing
ticket per the sub-T3 policy. Worth also sweeping the other subclasses that touch `REQUIRES_NEW`
services for the same silent disarming: `CustomerorderServiceTest` and `AdviceServiceH2Test`
(`MessageService`), `MobileReplenishServiceH2Test` (`MobileReplenishService`,
`ReplenishGeneratorService`).

### F4 — MEDIUM — the root-cause narrative states Spring's manager-resolution order backwards, in three places

The claim, repeated in commit `d253eaa6`, in the new comment at
`BaseRepositoryIntegrationTest.java:27-33`, and in the contract test's javadoc:

> Spring's `TestContextTransactionUtils` looks for a bean literally named `"transactionManager"` —
> there is none — then falls back to the `@Primary` `PlatformTransactionManager`

The actual order in `TestContextTransactionUtils.retrieveTransactionManager`
(spring-test 6.2.15 sources, verified):

1. explicit qualifier, if any — `bf.getBean(name, PlatformTransactionManager.class)`;
2. a single `TransactionManagementConfigurer`;
3. a single `PlatformTransactionManager` by type — there are two here, so no;
4. **`bf.getBean(PlatformTransactionManager.class)` — "with support for 'primary' beans"** ← resolves
   to `landlordTransactionManager` here, and returns;
5. only if 4 threw: `bf.getBean("transactionManager", PlatformTransactionManager.class)`.

The literal-name lookup is the **last** resort, not the first, and it is never reached in this
context. The conclusion (landlord wins because it is `@Primary`) is right; the mechanism is inverted.

This matters practically: as written, the comment implies that defining a bean named
`transactionManager` would have fixed it. It would not — step 4 succeeds first and the name is never
consulted. Suggested wording: *"with no qualifier, Spring resolves the single `PlatformTransactionManager`
by type; there are two, so it falls through to the `@Primary` one — `landlordTransactionManager`."*

### F5 — MEDIUM-LOW — the contract test's javadoc misstates which lane the affected classes run in

> Nothing in the surefire lane asserts a row count over the affected tables, and the 38 assertions
> that do (`hasSize`/`isEmpty` across nine `integration/repository/*` classes) live in the failsafe
> lane [...] The leak was therefore invisible rather than absent.

Surefire's excludes are `**/*IntegrationTest.java` and `**/*E2ETest.java`. Of the 31 subclasses of
`BaseRepositoryIntegrationTest`, **22 match neither** — `*RepositoryTest`, `*H2Test`,
`CustomerorderServiceTest`, and the new contract test — so they run in **surefire**, every build.
The leak was live and unmeasured in the lane that actually runs, not confined to an unreached one.

The narrower claim survives scrutiny: the only two row-count assertions among those 22
(`AdviceServiceH2Test:118` and `StockunitRepositoryTest:36`, both `hasSize(1)`) are scoped by a
freshly-created parent id and so are leak-immune. So "nothing asserts a row count over the affected
tables" is defensible in spirit but false as written, and the lane framing around it is wrong. Rewrite
to say what is true: *most subclasses do run in surefire; none of their assertions were shaped to
notice a leak.*

### F6 — LOW — the `BaseIntegrationTest` deferral rationale undercounts its subclasses and overstates "almost nothing ran"

`TestClassTransactionManagerArchTest` javadoc:

> `BaseIntegrationTest` has 10 subclasses, 7 of which write through `net.aim_ai.wms.repo.jpa` — but
> 6 of those 7 are `*IT` classes that run in NEITHER Maven lane [...] Changing that base class today
> would come back green because almost nothing ran

The 10 direct subclasses and the 7 `repo.jpa` writers check out exactly. But one of the 10,
`BaseControllerIntegrationTest`, is itself an abstract base with **3 further subclasses** that the
count omits:

| transitive subclass | lane | writes via `repo.jpa`? |
|---|---|---|
| `WebContextLaneContextTest` | **surefire** | no |
| `SdrReadGateEnforcementContextTest` | **surefire** | no |
| `CustomerOrderControllerIntegrationTest` | failsafe | **yes (4 `save()` calls)** |

So the writer set is 8, not 7, and **two** of them are runnable rather than one:
`AdviceServiceIntegrationTest` and `CustomerOrderControllerIntegrationTest`, both in the failsafe
lane — the lane the author successfully ran for the A/B (269 tests). The deferral may still be the
right call on risk grounds, but "cannot be verified here" is stronger than the evidence supports:
it could be partially verified by the same failsafe run already performed.

### F7 — LOW — meta-annotation blind spot (real, but narrow — and the obvious fix is wrong)

`isAnnotatedWith` does not follow meta-annotations, so a test class annotated with a composed
annotation that wraps a **bare** `@Transactional` would be invisible to all three rules.

Today this costs nothing: the only two composed annotations in the repo,
`config/TenantTransactional.java` and `config/TenantTransactionalReadOnly.java`, both hard-code
`value = "tenantTransactionManager"`, and neither is used in `src/test` (0 hits). So the gap misses
only *correctly-qualified* usage — i.e. it produces no false negative today and, importantly, no
false positive either.

Worth recording in the javadoc, along with the trap: **switching to `isMetaAnnotatedWith` would be a
regression, not a fix.** ArchUnit reads raw bytecode attributes and performs no `@AliasFor` merging,
so `getAnnotationOfType(Transactional.class)` on a meta-annotated class does not surface the
meta-annotation's `value`; `isBare()` would read `""` and report every `@TenantTransactional` test
class as a violation. (The existing `isBare()` checking *both* `value()` and `transactionManager()`
is correct for the same reason — they are `@AliasFor` aliases that ArchUnit will not merge, so both
raw attributes must be read. Good as-is.)

### F8 — LOW — `jakarta.transaction.Transactional` blind spot; cheap to close with a zero-scan

Confirmed 0 uses across `src/main` **and** `src/test` (`grep -rn 'jakarta.transaction'` → empty), so
nothing is being missed today. But it is the worse variant if it ever appears: it has no manager
attribute at all, so a test carrying it resolves the `@Primary` landlord manager with **no way to
qualify it**, and the rail would never see it.

A one-line addition inside `noNewBareTransactionalInTests` — assert that no scanned class or method
is annotated with `jakarta.transaction.Transactional` — closes it. Note the repo rule that a
zero-scan needs a positive control: this one has one for free, since the same scan is already proving
it can find the Spring annotation 11 times.

### F9 — LOW — `@Rollback(false)` / `@Commit` are a second silent path to the same leak

A test class with `@Commit` or `@Rollback(false)` and a perfectly qualified `@Transactional` commits
every write, and the rail passes. `grep -rn '@Rollback\|@Commit' src/test` returns nothing today, so
this is prophylactic — but it is the same shape as F2 and belongs in the same list of "ways to get
the defect past this rail."

### F10 — LOW — `hasSizeGreaterThan(500)` has ~4x slack

`target/test-classes` currently holds **1971** compiled classes under `net/aim_ai/wms` (488 source
files plus `@Nested`/inner/anonymous classes). A `>500` floor tolerates a 74% collapse of the import
option before it complains. It also cannot see the *over*-matching direction — though that is
adequately covered by side effect: if `src/main` were pulled in, `noNewBareTransactionalInTests`
would fail loudly on the service-layer bare annotations. Suggest `>1500`, or better, add the
complementary assertion that a known `src/main`-only class (e.g. `net.aim_ai.wms.StartApplication`)
is **absent** from the scanned set — that pins both directions and does not drift with test count.

### F11 — LOW — the allow-list key shape assumes no `@Nested`; true today, undocumented

ArchUnit imports `@Nested` inner classes as separate `JavaClass` entries named `Outer$Inner`, so a
bare `@Transactional` inside a nested class is *caught* — but reported under a key that an `Outer`
allow-list entry will not match. Verified all 8 allow-listed classes contain **0** `@Nested` blocks,
so the frozen counts are correct as written. One sentence in the `ALLOWED` javadoc ("keys are
ArchUnit class names; a nested class is `Outer$Inner`") prevents a confusing future failure.

### F12 — LOW — the rail silently depends on ArchUnit *not* honouring `@Inherited`

Spring's `@Transactional` **is** `@Inherited`. ArchUnit's `isAnnotatedWith` reports only
*declared* annotations, which is what makes the allow-list counts work. Empirical confirmation:
`currentViolations()` must be returning exactly the 11 source-declared sites (1+1+3+2+1+1+1+1), which
matches `grep -rn '^\s*@Transactional\b' src/test` exactly; had inheritance been followed, the
31 subclasses of `BaseRepositoryIntegrationTest` and the 13 of `BaseIntegrationTest` would all be
counted and the rule could not pass. This is load-bearing and unstated — an ArchUnit upgrade that
changed it would produce a wall of confusing violations. Worth a comment.

### F13 — LOW — deleting `cleanupTestData()` is not "a check that the fix actually works"

Commit `d427cedc` and the replacement comment both claim:

> removing it is a check that the fix actually works

It is not. Reading every assertion in `CyclecountRepositoryIntegrationTest`, all of them are
leak-tolerant: `isNotEmpty()`, `anyMatch(...)`, `noneMatch(cc -> cc.getId().equals(saved.getId()))`
on a freshly-generated id, `hasSizeLessThanOrEqualTo(3)`, and `allMatch(clientId == 1L)` where every
seed uses `clientId = 1L`. The class stays green whether the rollback works or not — which is exactly
why the leak survived there behind a workaround in the first place. The deletion is correct and
welcome as dead-code removal; the claim attached to it overstates what it demonstrates. (The genuine
check is the new contract test, which is enough.)

Two smaller notes on the same file: the 5-line historical comment now sits inside `@BeforeEach`,
where it will be re-read on every future edit of a hot method — the class javadoc is the better home;
and no leftover unused imports were introduced by the deletion (verified).

### F14 — LOW — "38 assertions" is off

The contract test javadoc says *"the 38 assertions that do (`hasSize`/`isEmpty` across nine
`integration/repository/*` classes)"*. The nine `integration/repository` classes that actually extend
`BaseRepositoryIntegrationTest` contain **44** lines matching `hasSize|isEmpty()`
(3+5+5+5+6+6+7+3+4). "Nine classes" is right if `RefillFixedLocationPredicateIntegrationTest` is
excluded (it is in that directory but is not a subclass); the count is not. Either correct it or drop
the number — a precise-looking figure that does not reproduce is worse than "several dozen".

### F15 — LOW — a temporally-fragile claim baked into javadoc

> [the failsafe lane], which `mvn verify` never reaches today because surefire fails first — see
> SBDEV-3239

True only while the 6 `StockunitServiceUnitTest` failures (SBDEV-3226) are unfixed, and already in
tension with this ticket's own evidence, which includes a full failsafe A/B (269 run). Once
SBDEV-3226 lands, this sentence becomes false and nothing will flag it. Qualify it ("as of
2026-09-07, with SBDEV-3226 open") or point at the ticket without asserting the present tense.

### F16 — LOW — forward risk: the outer test transaction now holds real tenant locks

Before this change the test-managed transaction was a landlord transaction holding nothing relevant;
`REQUIRES_NEW` sub-transactions in services under test saw a clean, committed database. After it, the
outer transaction holds uncommitted rows and, where the code path takes them, row locks — while a
suspended `REQUIRES_NEW` sub-transaction opens a *second* connection from a 4-connection pool
(`landlord.datasource.maximum-pool-size=4`) and may contend for the same rows. `StockunitRepository`
already documents this shape (`repo/jpa/StockunitRepository.java:30-34`: *"refillFixedLocations'
REQUIRES_NEW sub-transaction reserving stock while the outer tx holds other locks"*, bounded by a 5s
`jakarta.persistence.lock.timeout` hint). Subclasses in reach: `MobileReplenishServiceH2Test`,

> ⚠ **WITHDRAWN 2026-09-07 by SBDEV-3250.** The `jakarta.persistence.lock.timeout` hint this paragraph relies on **never had any effect on PostgreSQL** — `PostgreSQLDialect.withTimeout` translates only `0` and `-2`, `supportsWait()` returns `false`, and hibernate-core never issues `SET lock_timeout`. Measured: a move waited 30.92 s on an in-flight pick and then succeeded. Bounds now come from `LockTimeoutHibernateJpaDialect` (`SET LOCAL lock_timeout`, `wms.tenant.lock-timeout-ms`, default 10 s) at tenant-transaction begin, **per lock acquisition** rather than per statement.

`ReplenishOrderControllerH2Test`, `PickingorderBusinessServiceH2Test` (the last is `NOT_SUPPORTED`,
so exempt).

Nothing fails today and the A/B is the right evidence for that. Flagging it because the failure mode
is a slow, intermittent lock timeout rather than a clean red, and because it will surface for the
first time when SBDEV-3239 AC-5 switches the `*IT` lane on.

### F17 — LOW / cosmetic

- `@Order(1)` on `testTransactionMustBindTheTenantEntityManagerFactory()` is unnecessary and mildly
  contradicts the javadoc two lines above it, which correctly says the method is order-independent.
  Harmless, but the annotation invites a reader to think ordering matters there.
- The SBDEV-3242 note in `BaseRepositoryIntegrationTest` is a `/* */` block *between* annotations.
  Legal and it will be seen by anyone editing the annotation, but the class already carries a real
  Javadoc block above `@SpringBootTest` and that is where a reader looks first.
- That existing class Javadoc still reads *"Follow the naming convention `*IntegrationTest.java`"*,
  which 22 of the 31 subclasses do not — and per F5 that naming is what decides their lane. Since
  this commit touches the file and the new material is about lanes, it is the moment to fix it.

---

## Answers to the specific questions

**1. Rail blind spots.** Real ones, in descending order of consequence: F2 (`NOT_SUPPORTED` escape
hatch — the only one I would call a *design* gap), F9 (`@Commit`/`@Rollback(false)`), F8
(`jakarta.transaction.Transactional`), F7 (meta-annotations, with the warning that
`isMetaAnnotatedWith` is not the fix). Non-issues, checked and clean: every test class lives under
`net.aim_ai.wms` (verified — no package escapes the `importPackages` scope); `@Nested` classes *are*
scanned (F11 is only about key shape); `c.getMethods()` returning declared-only methods is the
correct choice, since an inherited method is counted against its declaring class, and every declaring
class is in scope; annotation inheritance is handled correctly by accident rather than by design
(F12).

**2. Is `nonVacuityGuard` non-vacuous?** Yes, but not for the reason it claims — see F1. It is *not*
self-referential: `WarehouseStockReportServiceStreamIT` is an independent, pre-existing,
properly-qualified class-level `@Transactional`. But the assertion as coded also counts
`PickingorderBusinessServiceH2Test`, which names no manager at all, so it does not demonstrate the
discrimination its message advertises. `>500` is not brittle in the false-red direction — F10.

**3. The `NOT_SUPPORTED`/`NEVER` exemption.** **The reasoning is correct**, and correct for both
propagations — confirmed from `TransactionalTestExecutionListener.beforeTestMethod`, spring-test
6.2.15:

```java
if (transactionAttribute.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NOT_SUPPORTED ||
        transactionAttribute.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NEVER) {
    return;
}
tm = getTransactionManager(testContext, transactionAttribute.getQualifier());
```

The early `return` precedes `getTransactionManager` entirely, so in the TestContext framework
**no manager is resolved at all** for either propagation — there is nothing to suspend and nothing to
mis-bind. `PickingorderBusinessServiceH2Test` is genuinely unaffected by this change, before and
after.

Two caveats. (a) The javadoc's phrasing is general ("they run the method non-transactionally by
design"), but the early return is a **TestContext-framework** behaviour, not a `@Transactional` AOP
behaviour — in `src/main`, `NOT_SUPPORTED` *does* resolve a manager in order to suspend. The rail is
test-only so nothing is wrong today, but the sentence would become false if the rule were ever
widened. (b) The stated rationale for *not* exempting `SUPPORTS` — "it joins an existing transaction
when there is one, so it can still bind the wrong manager" — does not hold in the test context
either: `beforeTestMethod` asserts there is no existing transaction context, so `SUPPORTS` starts an
empty transaction and never rolls back. Not exempting it is still the right (stricter) call; the
reason given for it is not the real one. And see F2 for the consequence of the exemption itself.

**4. The mechanism assertion.** Sound, and I could not construct a false pass or a flake.
`JpaTransactionManager.doBegin` binds the `EntityManagerFactory` as the resource key eagerly at
transaction start, before and independently of connection acquisition, so there is no timing window;
the observed `HikariDataSource (LandlordTestPool)` key in the pre-fix output is the *second* resource
the same manager binds (`JpaTransactionManager.afterPropertiesSet` auto-detects the EMF's DataSource),
not a competing binding. `spring.jpa.open-in-view=false` in `application-integration.properties`
removes the one realistic contaminating binder. Identity holds because
`@Autowired @Qualifier("tenantEntityManagerFactory") EntityManagerFactory` resolves the same
`LocalContainerEntityManagerFactoryBean` product instance that
`tenantTransactionManager(@Qualifier("tenantEntityManagerFactory") EntityManagerFactory emf)` was
constructed with, and Spring's EMF proxy implements `equals` as identity. The paired
`contains(tenant)` + `doesNotContain(landlord)` is what makes it robust: a stray binding by a third
party would satisfy the first but not the second. Only note: it asserts *what is bound on the thread*
rather than *which manager the TestContext chose*, which is one inferential step — acceptable, and I
have no better instrument to suggest that is not more fragile.

**5. Test-order fragility.** Sound. There is no parallel execution anywhere: no
`junit-platform.properties` in `src/test/resources` (only `application.properties`,
`application-integration.properties`, `archunit.properties`), and `grep -n parallel pom.xml
src/test/resources/` returns nothing — surefire 3.2.5 runs with default `forkCount=1`,
`reuseForks=true`, no `parallel` configuration. `@TestMethodOrder(OrderAnnotation.class)` is therefore
deterministic. One residual, inherent to any ordered-pair symptom test: running method 3 alone
(`-Dtest=...#mustNotSeeThePreviousMethodsRow`) passes vacuously, as does the case where method 2 is
ever skipped. The order-independent mechanism assertion is the mitigation and it is present, so I
would not change anything here.

**6. Deleting the cyclecount cleanup.** Safe — no `@BeforeAll` in the class, and `CC-TEST` appears in
exactly two files repo-wide, this test and the new contract test's javadoc, so no sibling class writes
rows the helper was absorbing. But it does not "check that the fix works": every assertion in the
class is leak-tolerant, so it would stay green under a regressed base class. See F13.

**7. Commit-message and javadoc claims.** F4 (mechanism inverted, three places), F5 (lane split),
F6 (subclass accounting and "almost nothing ran"), F13 ("a check that the fix works"), F14 ("38
assertions"), F15 ("`mvn verify` never reaches"), and the F1/F2 mismatch between what the rail
enforces and what the commit says it enforces. Claims I checked and found **accurate**: "three base
classes carried it" (`BaseIntegrationTest`, `BasePostgresIntegrationTest`,
`BaseRepositoryIntegrationTest` — exactly 3); `TransactionManagerArchTest` being scoped to
`methods()` in `net.aim_ai.wms.service` with `DO_NOT_INCLUDE_TESTS` (read the file, confirmed on both
axes); "30 subclasses" pre-change (31 today, the 31st being the new contract test); the 11
allow-listed violations summing exactly to the 11 declared sites in `src/test`; the `BaseIntegrationTest`
7-writers / 6-are-`*IT` split among its *direct* subclasses; `BasePostgresIntegrationTest` being
unbootable with the reason given (its own `TODO SBDEV-2217` block says the same thing); and "one JVM,
shared in-memory H2" (`DB_CLOSE_DELAY=-1`, `reuseForks` default true).

---

## What I would require before merge

1. **F1** — fix the `qualified` filter. One line, and the guard currently does not assert what it says.
2. **F3** — decide and record: either restore real coverage to
   `MessageRepositoryIntegrationTest`'s two delete assertions, or note the loss on the ticket. Do not
   let "no new breakage" stand as the whole story.
3. **F4** — correct the resolution-order sentence in all three copies; the current text points the
   next reader at a fix that would not work.

Everything else is worth doing but does not need to gate the merge. F2 and F9 in particular would be
better as two sentences of javadoc now than as a second SBDEV ticket later.
