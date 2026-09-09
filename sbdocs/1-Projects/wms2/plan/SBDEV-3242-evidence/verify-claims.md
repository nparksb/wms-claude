# SBDEV-3242 — adversarial verification of the seven claims

**Verifier lane.** Independent re-measurement of `be04502d..HEAD` on branch
`bugfix/SBDEV-3242-repo-test-rollback-tx-manager` in the worktree
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3242`. Date: 2026-09-07.

No git state was changed at any point (`git status --porcelain` empty at start and at finish; no
stash/checkout/reset/commit/clean). The pre-fix state was read with `git show be04502d:<path>`, and
where a *behavioural* measurement was needed it was produced by an in-place source mutation, restored
by an inverse Python edit, and the restore verified by `md5sum -c` against checksums taken before the
first mutation plus a clean `git status`.

Toolchain: `JAVA_HOME=/home/nampark/.sdkman/candidates/java/21.0.11-ms`,
`/home/nampark/.sdkman/candidates/maven/current/bin/mvn`. One maven invocation at a time throughout.

Commits under review:

| SHA | Subject |
|---|---|
| `d253eaa6` | SBDEV-3242: roll back the transaction manager that owns the writes |
| `d427cedc` | SBDEV-3242 AC-4: delete the CyclecountRepositoryIntegrationTest workaround |
| `f5f64e4b` | SBDEV-3242 AC-5: rail against bare `@Transactional` in test classes |

---

## Verdict table

| Claim | Verdict |
|---|---|
| 1 — the wrong-manager causal chain | **CONFIRMED**, including empirically. One narrative detail in the new source comment is inverted against Spring's actual resolution order; the outcome is unaffected. |
| 2 — no regression, both lanes | **CONFIRMED**, and stronger than claimed: I measured the pre-fix surefire side too, and both sides reproduce exactly. |
| 3 — no landlord leak relocated | **CONFIRMED** by two instruments plus two positive controls, including a transitive-reachability check the claim did not do. |
| 4 — 11 bare `@Transactional` in exactly 8 classes, those counts | **CONFIRMED** by a bytecode instrument independent of both the author's grep and the rail itself. |
| 5 — the three rules are mutation-killed | **CONFIRMED**. All three re-derived here from scratch. |
| 6 — `BaseIntegrationTest` has 10 subclasses, 7 write, 6 of those in neither lane | **REFUTED in its load-bearing part.** The subclass set is 13, not 10; the writer tally does not reproduce under any definition I tried; and — decisively — the two classes that actually *write through* `repo.jpa` *and* are actually *governed by* the bare annotation both run today in the failsafe lane. A fix to `BaseIntegrationTest` **is** verifiable. The scope decision survives, but on a different and narrower reason. |
| 7 — `NOT_SUPPORTED` / `NEVER` genuinely need no manager | **CONFIRMED** from Spring 6.2.15's own source: the listener returns *before* it ever resolves a manager. The exemption is correct, not a hole. |

---

## CLAIM 1 — the causal chain

**Verdict: CONFIRMED**, every link, with a direct empirical measurement of the pre-fix binding.

### Link-by-link

| Link | Evidence | Verdict |
|---|---|---|
| At `be04502d` the base class carried a bare `@Transactional` | `git show be04502d:src/test/java/net/aim_ai/wms/common/base/BaseRepositoryIntegrationTest.java` → line 28 is bare `@Transactional`, no arguments | CONFIRMED |
| No bean named `transactionManager` exists | Three instruments agree: (a) `grep` over `src/main` + `src/test` finds no `@Bean` producing that name; (b) `StartApplication` excludes `DataSourceAutoConfiguration` and `HibernateJpaAutoConfiguration`, so Boot's `JpaBaseConfiguration#transactionManager` never fires; (c) `DataSourceTransactionManagerAutoConfiguration` is `@ConditionalOnMissingBean(TransactionManager.class)` and two `PlatformTransactionManager` beans exist, so it backs off | CONFIRMED |
| `@Primary` on `landlordTransactionManager`, not on `tenantTransactionManager` | `LandlordDatabaseConfig.java:60-64` — `@Primary @Bean public PlatformTransactionManager landlordTransactionManager(...)`. `TenantDatabaseConfig.java:74-78` — same bean type, **no** `@Primary` | CONFIRMED |
| `net.aim_ai.wms.repo.jpa` is bound to `tenantTransactionManager` | `TenantDatabaseConfig.java:22-26` — `@EnableJpaRepositories(basePackages = "net.aim_ai.wms.repo.jpa", entityManagerFactoryRef = "tenantEntityManagerFactory", transactionManagerRef = "tenantTransactionManager")` | CONFIRMED |
| Therefore the test rollback operated on the wrong manager | See "empirical" below | CONFIRMED |

### Nothing redirects the resolution

I checked each redirection route the task named, plus two it did not:

- **`TestDatabaseConfig`** (`src/test/java/net/aim_ai/wms/common/config/TestDatabaseConfig.java`) defines
  exactly two beans — a `RestClient` and a `@Primary` mock `tenantDynamicRoutingDataSource`. **No**
  transaction manager, no entity-manager factory.
- **Any other `@TestConfiguration`** — a repo-wide grep for `PlatformTransactionManager` in `src/test`
  returns only *assertions about* the annotation (`UnitloadServiceUnitTest`, the two arch tests) and
  javadoc. No test source declares a transaction-manager bean.
- **`spring.main.allow-bean-definition-overriding=true`** — present on the base class, but there is
  nothing to override: no second bean of that name or type exists to win the override.
- **`TransactionManagementConfigurer`** (checked additionally; it takes *priority* over `@Primary` in
  Spring's resolution) — zero implementations anywhere in `src/main` or `src/test`.
- **An alias bean** — no `@Bean(name = "transactionManager")` and no `registerAlias` anywhere.

### The resolution order — a correction that changes nothing

`spring-test-6.2.15-sources.jar`, `TestContextTransactionUtils#retrieveTransactionManager`, resolves in
this order when no qualifier is given:

1. a single `TransactionManagementConfigurer` — none here;
2. **if exactly one `PlatformTransactionManager` bean exists**, that one — two exist here;
3. **`bf.getBean(PlatformTransactionManager.class)`, "with support for 'primary' beans"** — this is
   where the app lands, and it returns `landlordTransactionManager`;
4. only *then* `bf.getBean("transactionManager", PlatformTransactionManager.class)`.

The new comment in `BaseRepositoryIntegrationTest.java:28-33` and in
`BaseRepositoryIntegrationTestRollbackContractTest`'s javadoc says Spring "looks for a bean literally
named `transactionManager`; there is none, so it falls back to the `@Primary`". The two steps are in the
opposite order: `@Primary` is tried **first**, and the default-name lookup is the fallback that is never
reached. The conclusion — `landlordTransactionManager` wins — is unaffected, because both branches
select it. **Nit, not a defect.** Worth a one-word edit if the comment is meant to be a teaching
artefact, which its length suggests it is.

### Empirical confirmation of the whole chain

Mutation **M1** (below) reverted the qualifier in place and re-ran the surefire lane. The contract test's
failure names the bound resources directly:

```
Expecting UnmodifiableSet:
  [org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean@76bb8770,
    HikariDataSource (LandlordTestPool)]
to contain:
  [org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean@1c56628f]
```

`LandlordTestPool` is the pool name set by `application-integration.properties:landlord.datasource.pool-name`.
Pre-fix, the test-managed transaction bound the **landlord** EMF and the **landlord** Hikari pool, and did
not bind the tenant EMF. That is the claim, measured rather than argued. The companion ordered pair
(`writesARowThatMustNotSurvive` → `mustNotSeeThePreviousMethodsRow`) also went red, i.e. the row genuinely
survived the method's rollback.

**Instrument:** Spring's own source + a live JVM assertion over
`TransactionSynchronizationManager.getResourceMap()`.
**Blind spot:** `getResourceMap()` reports what is bound *at that instant on that thread*. It cannot see a
repository call that opens its own transaction on another thread or after the assertion; and the identity
comparison is by object reference, so it would be defeated by a proxy wrapper around either EMF. Neither
applies here.

### One structural fact worth recording

`application-integration.properties` points `landlord.datasource.jdbc-url` and `spring.datasource.url` at
the **same** H2 URL (`jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1`), and `TestDatabaseConfig` mocks
`tenantDynamicRoutingDataSource` to hand out `landlordDataSource` connections. So both managers sit on one
physical database. The defect is therefore *not* "writes went to the wrong database" — it is "the rollback
was issued on a transaction that never contained the writes, on a different connection". The fix commit's
comment says exactly this. Good.

---

## CLAIM 2 — no regression

**Verdict: CONFIRMED**, with the pre-fix side measured rather than inferred.

### Post-fix, measured by me

`mvn clean verify -Dmaven.test.failure.ignore=true` (single invocation, both lanes,
`/tmp/.../scratchpad/verify-postfix.log`, `BUILD SUCCESS`):

| Lane | Tests run | Failures | Errors | Skipped |
|---|---|---|---|---|
| surefire | **6324** | **6** | 0 | **26** |
| failsafe | **269** | **5** | **15** | **65** |

Failsafe matches the claim exactly (`269 / 5 / 15 / 65`).

The 6 surefire failures are all `StockunitServiceUnitTest`:
`RemoveLock.throwsWhenRemovingLockFromDeleted:795`, `RemoveLock.throwsWhenRemovingLockFromShipped:777`,
`RemoveLock.throwsWhenRemovingNonRemovableLock:831`, `SetLockDamagedExtended.throwsWhenAlreadyLocked:1090`,
`SetLockOnHoldExtended.throwsWhenLocationIsLocked:887`, `SetLockOnHoldExtended.throwsWhenUnitLoadIsLocked:871`.
All are message-text assertions (`"…marked To Delete."` not containing `"deleted"`) with no relationship to
transaction managers — consistent with the SBDEV-3226 attribution.

### Pre-fix, also measured by me

The claim's `6318` was presented as a prior measurement. Rather than take it, I produced the pre-fix
surefire state by mutation **M1** (qualifier stripped, everything else at HEAD) and re-ran the lane:

| State | Tests run | Failures | Skipped |
|---|---|---|---|
| M1 (pre-fix behaviour, new test classes present) | 6324 | **9** | 26 |
| — minus the 3 new-class failures | 6318 | 6 | 26 |

The 3 extra failures are precisely
`BaseRepositoryIntegrationTestRollbackContractTest.testTransactionMustBindTheTenantEntityManagerFactory`,
`…mustNotSeeThePreviousMethodsRow`, and
`TestClassTransactionManagerArchTest.noNewBareTransactionalInTests` — i.e. the new pins, and nothing else.
So: **6318 → 6324 run, 6 failures on both sides, 26 skipped on both sides.** The claim reproduces, and no
existing test changed outcome under the fix.

The two new classes contribute exactly 3 tests each (`Tests run: 3` for both in the post-fix log), which is
the `+3 contract test, +3 rail` decomposition.

**Instrument:** two full maven lane runs.
**Blind spot:** a *single* run of each side. Nothing here rules out a flaky test that happened to land the
same way twice — `SequenceTransactionServiceConcurrencyIT`'s `timer max > mean * 5` assertion is documented
in `pom.xml` as flaky by construction, though it sits in the lane that runs in neither. The 15 failsafe
errors are also environment-shaped (Flyway `V1.2.01__utc_standard_tables.sql`, a missing `JdbcTemplate`
bean in `ClientRepositoryIntegrationTest`) and could move on a different machine.

### AC-4 is verified, not merely asserted

`CyclecountRepositoryIntegrationTest` (failsafe lane) ran **all green** post-fix with the
`cleanupTestData()` workaround deleted — 3+2+1+2+3+1+3+3 passing across its nested classes, 3 skipped in
`NativeSqlWithJoins`. Removing the workaround is a real check that the rollback now works, exactly as the
commit message claims.

---

## CLAIM 3 — no landlord leak is relocated

**Verdict: CONFIRMED**, with better instrumentation than the claim used.

### Direct references

There are **31** subclasses of `BaseRepositoryIntegrationTest` at HEAD (transitive closure over the
compiled superclass graph), one of which is the new contract test — so **30** pre-existing, matching the
claim.

| Instrument | Result |
|---|---|
| Source grep for `net\.aim_ai\.wms\.landlord\.(jpa\|model)` across all 31 files | **0 hits** |
| Bytecode scan for `net/aim_ai/wms/landlord/jpa` or `…/landlord/model` across all 31 classes' compiled forms (including `$Nested` inner classes) | **0 hits** |
| **Positive control** — same bytecode scan over the whole of `target/test-classes` | **135** class files hit |

The positive control matters: a scan that finds nothing and a scan that is broken look identical. This one
finds 135 elsewhere, so the zero is a true zero.

### Indirect access — the part the claim did not check

The task raised two indirect routes. Both are closed:

**(a) A landlord entity reached through an autowired service.** The 31 subclasses autowire exactly six
non-repository beans: `AdviceService`, `CustomerorderService`, `MessageCleanupBatchService`,
`MobileReplenishService`, `PickingorderBusinessService`, `PickingorderService`. I built the transitive
reference closure over `target/classes` bytecode from those six seeds:

```
classes reached transitively: 237
landlord jpa/model reachable: 0
```

**Positive control** for the same instrument, seeded with `OutboxDispatcherJob` (which does import
`landlord.jpa`): 99 classes reached, **5** landlord-referencing classes found
(`TenantDbConfigurationRepository`, `Tenant`, `TenantAuthConfiguration`, `TenantDbConfiguration`, and the
job itself). The instrument works.

For completeness, the only `src/main` classes importing `net.aim_ai.wms.landlord.jpa` are the eight
`schedulejob` classes, `LandlordService`, `StartupFlywayMigrator`, `StartupFlywayMigrationRunner` and
`TenantPoolEndpoint`. None is in the closure, and `app.cron=false` in the integration profile keeps the
scheduled jobs from running anyway.

**(b) `TestDatabaseConfig`'s mocked `tenantDynamicRoutingDataSource` forwarding to `landlordDataSource`.**
Confirmed present and confirmed benign for this claim: because `application-integration.properties` points
*both* datasources at the same `jdbc:h2:mem:wms_integration`, there is only one physical database in this
profile. Switching the transaction manager cannot relocate rows between databases — there is nowhere to
relocate them to. What it changes is which EMF/connection the test transaction owns, which is the point of
the fix. So the claim's conclusion holds, though its phrasing ("relocates no leak") is true for a stronger
reason than the one given.

**Blind spot of the whole section:** the reachability closure is over *static* bytecode references. It
cannot see a landlord entity reached reflectively, through a Spring Data derived-query proxy whose
interface is never named in the CUT, or through SpEL/`@Query` strings. Nothing observed suggests any of
those, but they are outside the instrument.

---

## CLAIM 4 — the population of bare `@Transactional`

**Verdict: CONFIRMED.** 11 bare annotations, in exactly the 8 allow-listed classes, with exactly those
per-class counts.

The author's method (`grep '^\s*@Transactional\s*$'`) is unsound in both directions: it misses
`@Transactional(propagation = NOT_SUPPORTED)` (as noted), and a naive relaxation of it to catch that case
picks up 187 "hits" in this tree, most of them javadoc and string literals inside the arch tests
themselves. So I did not repair the grep — I used bytecode.

**Instrument (independent of both the grep and of ArchUnit):** scan every `target/test-classes/**/*.class`
for the constant-pool descriptor `Lorg/springframework/transaction/annotation/Transactional;` (36 hits),
then `javap -v -p` those and parse the `RuntimeVisibleAnnotations` attributes, classifying each site as
bare / qualified / propagation-exempt.

Result — every **bare** site (no `value`, no `transactionManager`, propagation not `NOT_SUPPORTED`/`NEVER`):

| Class | Level | Count |
|---|---|---|
| `common.base.BaseIntegrationTest` | class | 1 |
| `common.base.BasePostgresIntegrationTest` | class | 1 |
| `integration.controller.rest.OrderRestControllerIntegrationTest` | method (`createTest`) | 1 |
| `integration.controller.rest.SkuRestControllerIntegrationTest` | method (`updateTest`, `deleteTest`) | 2 |
| `integration.service.mobile.MobilePickingServiceIntegrationTest` | method ×3 | 3 |
| `integration.service.mobile.MobilePutawayServiceIntegrationTest` | method | 1 |
| `integration.service.mobile.MobileReplenishServiceIntegrationTest` | method | 1 |
| `integration.service.mobile.MobileTransferOrderServiceIntegrationTest` | method | 1 |
| **Total** | | **11** |

This is byte-for-byte the `ALLOWED` map in `TestClassTransactionManagerArchTest`. Two further corroborations
fell out of the mutation work: under M1 the rule reported exactly
`{BaseRepositoryIntegrationTest=1}` as the *only* class over allowance — proving no other entry is
under-counted — and the un-mutated `theAllowListMustShrinkNotLinger` passes, proving no entry is
over-counted. Three independent confirmations of the same map.

`BaseRepositoryIntegrationTest` itself shows `Transactional(value="tenantTransactionManager")` in the
bytecode, and `PickingorderBusinessServiceH2Test` shows
`Transactional(propagation=…Propagation.NOT_SUPPORTED)` — the two classes that distinguish the classifier.

### Does the rail miss anything?

| Route | Present today? | Would the rail see it? |
|---|---|---|
| Meta-annotation `net.aim_ai.wms.config.TenantTransactional` | **0** uses in `src/test` (bytecode scan for `Lnet/aim_ai/wms/config/TenantTransactional;`) | **No** — ArchUnit's `isAnnotatedWith(Class)` matches the exact type, not meta-annotations (`isMetaAnnotatedWith` would). Currently harmless because `TenantTransactional` is itself *always* qualified (`@Transactional(value = "tenantTransactionManager", …)`), so it can never *be* the defect. A future bare meta-annotation would slip past. |
| `jakarta.transaction.Transactional` / `javax.transaction.Transactional` | **0** uses in `src/test` | **No.** Also low-risk: Spring's `TransactionalTestExecutionListener` only honours the Spring annotation, so the jakarta one on a test would not open a test-managed transaction at all. |
| Inherited class-level `@Transactional` | 30 subclasses inherit from `BaseRepositoryIntegrationTest` | Not counted — **correct**. The rail counts the *declaration site*; counting inheritance would multiply one defect into 30 and make the allow-list meaningless. |
| `@Nested` inner classes | Many (e.g. `PutawayConfigControllerUnitTest$WriteAtomicity`) | **Yes** — they compile to separate class files under `/test-classes/`, and my bytecode scan sees the same set the rail's importer does. |
| Test classes outside `net.aim_ai.wms` (the rail's `importPackages` root) | **0** of 1971 test class files | Moot today; would be a gap if one were ever added. |
| Constructors / static initialisers | n/a | `c.getMethods()` excludes constructors. `@Transactional` on a constructor is meaningless, so no practical gap. |

None of these is a live hole. The meta-annotation one is the only one worth a comment in the rail's javadoc.

---

## CLAIM 5 — the rules are mutation-killed

**Verdict: CONFIRMED.** All three re-derived independently. Every mutation was applied by a Python
in-place edit and reverted by its exact inverse; `md5sum -c` against pre-mutation checksums and
`git status --porcelain` (empty) confirm the tree is byte-identical to HEAD, and a final green run
confirms it functionally.

### M1 — strip the qualifier from `BaseRepositoryIntegrationTest`

`@Transactional("tenantTransactionManager")` → `@Transactional`. Full surefire lane.

Killed **three** assertions across **two** rules:

- `TestClassTransactionManagerArchTest.noNewBareTransactionalInTests` →
  `Expecting empty but was: {"net.aim_ai.wms.common.base.BaseRepositoryIntegrationTest"=1}`
- `BaseRepositoryIntegrationTestRollbackContractTest.testTransactionMustBindTheTenantEntityManagerFactory`
  → bound the landlord EMF + `LandlordTestPool` (quoted under CLAIM 1)
- `BaseRepositoryIntegrationTestRollbackContractTest.mustNotSeeThePreviousMethodsRow` → the row survived

This is the highest-value mutation of the three: it re-derives the pre-fix defect *and* kills the rail
in one run, and it demonstrates that the mechanism assertion and the symptom assertion fail
independently — which is the reason the contract test carries both.

### M2 — raise an allowance above the real count

`ALLOWED.put("…BaseIntegrationTest", 1)` → `2`. Targeted run.

`Tests run: 3, Failures: 1` — killed **only** `theAllowListMustShrinkNotLinger`:

```
Expecting empty but was: {"net.aim_ai.wms.common.base.BaseIntegrationTest"=
  "allow-list says 2, found 1 — fixed, so delete or lower the entry"}
```

The ratchet works, and it is selective: the other two rules stayed green.

### M3 — break the import option

`location.contains("/test-classes/")` → `location.contains("/no-such-dir-mutant/")`. Targeted run.

`Tests run: 3, Failures: 2` — killed `nonVacuityGuard` (size assertion), and collaterally
`theAllowListMustShrinkNotLinger` (all 8 entries report `found 0`).

**The important observation:** under M3, `noNewBareTransactionalInTests` **passed** — on an empty scan, with
zero classes imported. That is precisely the false green the vacuity guard exists to catch, and it caught
it. The guard is load-bearing, not decoration.

### Restore verification

```
src/test/java/net/aim_ai/wms/common/base/BaseRepositoryIntegrationTest.java: OK
src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java: OK
git status --porcelain: (empty)
mvn test -Dtest=TestClassTransactionManagerArchTest,BaseRepositoryIntegrationTestRollbackContractTest
  → Tests run: 6, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS
```

**Blind spot:** three mutations is not a mutation *score*. I did not run PIT, and there are assertions in
both new classes I did not individually mutate — notably `nonVacuityGuard`'s
`hasSizeGreaterThan(500)` threshold (1971 test classes exist, so the bound is loose by 4×; it would not
notice the importer silently dropping two thirds of the tree) and its "at least one qualified
`@Transactional`" positive control.

---

## CLAIM 6 — the `BaseIntegrationTest` scope decision

**Verdict: REFUTED in its load-bearing part.** The pom facts are right. The subclass arithmetic is wrong,
and the conclusion drawn from it — "changing that base class today would come back green because almost
nothing ran" — does not hold.

### The pom half is CONFIRMED

Read directly from `pom.xml`:

- surefire 3.2.5 `<excludes>`: `**/*IntegrationTest.java`, `**/*E2ETest.java`. Its default includes
  (`**/Test*.java`, `**/*Test.java`, `**/*Tests.java`, `**/*TestCase.java`) do **not** match `*IT.java`.
- failsafe 3.1.2 `<includes>`: only `**/*IntegrationTest.java` and `**/*E2ETest.java`. Declaring
  `<includes>` overrides failsafe's own `**/*IT.java` default.

So `*IT` classes run in neither lane. **Confirmed against the pom, and confirmed empirically**: not one
`*IT` class appears in either lane's output across my three full runs. (The pom carries a long SBDEV-3091
comment saying the same thing; I did not rely on it — the `<includes>`/`<excludes>` elements themselves
are the evidence, and the run logs are the second instrument.)

### The subclass arithmetic does not reproduce

`BaseIntegrationTest` has **10 direct** subclasses (`grep -c "extends BaseIntegrationTest"` → 10) but
**13 in total**: `BaseControllerIntegrationTest` is one of the 10 and is itself extended by
`CustomerOrderControllerIntegrationTest`, `SdrReadGateEnforcementContextTest` and `WebContextLaneContextTest`.
The claim's "10" is the direct count, i.e. a `grep`, not a hierarchy walk. Full table, measured from
bytecode (`javap -c -p`, counting invocations of `net/aim_ai/wms/repo/jpa/*` write methods, and
`javap -v` for the class's own `@Transactional`):

| Subclass | Lane | `repo.jpa` write calls | Own class-level `@Transactional`? |
|---|---|---|---|
| `AdviceServiceIntegrationTest` | **failsafe** | **3** | no → inherits the bare one |
| `CustomerOrderControllerIntegrationTest` (via `BaseControllerIntegrationTest`) | **failsafe** | **4** | no → inherits the bare one |
| `MessageCleanupBatchServiceIT` | neither | 1 (on a `@MockitoBean` repo) | no → inherits the bare one |
| `IdempotencyFilterIT` | neither | 0 | no |
| `BaseControllerIntegrationTest` | (abstract) | 0 | no |
| `SdrReadGateEnforcementContextTest` | surefire | 0 | no |
| `WebContextLaneContextTest` | surefire | 0 | no |
| `BillofladingServiceFinishTransferIT` | neither | 6 | **yes, qualified** `"tenantTransactionManager"` |
| `CustomerorderBatchServiceParallelStreamRegressionIT` | neither | 5 | **yes, qualified** |
| `ParcelMonitorViewServiceConcurrencyIT` | neither | 1 | **yes, qualified** |
| `SequenceTransactionServiceConcurrencyIT` | neither | 0 | **yes, qualified** |
| `WarehouseStockReportServiceStreamIT` | neither | 0 | **yes, qualified** |
| `ReplenishmentOrderMaintenanceServiceIntegrationTest` | failsafe | 0 | **yes, qualified** |

Writers: **6** of 13 (or 5 of the direct 10), not 7. Of those 6, **4** are `*IT`, not 6. I could not find a
definition of "write" — source-import count, bytecode type reference, bytecode write-method call — under
which `7` and `6` both come out.

### The conclusion is the part that actually fails

Two facts the tally obscures:

1. **Five of the seven `*IT` subclasses declare their own class-level
   `@Transactional("tenantTransactionManager")`**, which *overrides* the inherited bare annotation
   entirely. They are already correct and are unaffected by anything done to `BaseIntegrationTest`. Four
   of the six writers in the table are in this group. So the population that the bare annotation actually
   governs is much smaller than the subclass count suggests.
2. **The two remaining real writers both run today, in the failsafe lane.**
   `AdviceServiceIntegrationTest` (3 `repo.jpa` save calls, no own annotation) and
   `CustomerOrderControllerIntegrationTest` (4 save calls, no own annotation) both executed in my measured
   failsafe run — `AdviceServiceIntegrationTest` all green (1+1+3 across its nested classes).

So "changing that base class today would come back green because almost nothing ran" is not true: a fix
would be exercised immediately by at least one green, writing, running class. The stated justification for
allow-listing rather than fixing does not stand.

### The decision still survives — for a different reason

`MessageCleanupBatchServiceIT` (`src/test/java/net/aim_ai/wms/integration/service/MessageCleanupBatchServiceIT.java:72`)
carries the comment *"@Transactional on BaseIntegrationTest. Capture its name before the proxy call"* and
asserts on the **name of the transaction the proxy opens**. Qualifying the base class's annotation could
change what that test observes — and it runs in neither lane, so that risk genuinely cannot be measured
today. That is a real, specific, unmeasurable risk, and it is a sound reason to defer. It is simply not the
reason the javadoc gives.

**Recommendation (non-blocking):** the allow-list entry and its javadoc should be rewritten to cite
`MessageCleanupBatchServiceIT`'s transaction-name assertion as the blocker, and to record that
`AdviceServiceIntegrationTest` and `CustomerOrderControllerIntegrationTest` are the two classes that would
verify the fix when it is made. As written, the note tells a future reader that nothing can verify the fix,
which will send them looking in the wrong place. If a follow-up wants to close this, the cheap path is:
fix `BaseIntegrationTest`, re-run failsafe, and check `MessageCleanupBatchServiceIT` by hand with
`mvn verify -Dit.test=MessageCleanupBatchServiceIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`.

**Instrument:** `javap` over compiled test classes + the three measured lane runs.
**Blind spot:** "write call" is counted as a static reference to a `repo.jpa` method whose name starts
`save`/`delete`/`flush`. A write performed through an injected *service*, through `EntityManager.persist`,
or through `@Sql` script fixtures is not counted — `CustomerOrderControllerIntegrationTest` in particular
also drives writes through MockMvc, which this does not see. That biases the writer count *down*, which
strengthens rather than weakens the refutation.

---

## CLAIM 7 — `NOT_SUPPORTED` and `NEVER` need no manager

**Verdict: CONFIRMED**, and the challenge in the task ("`NOT_SUPPORTED` must suspend, which requires
resolving a manager") does not apply to this code path.

`spring-test-6.2.15-sources.jar`,
`TransactionalTestExecutionListener#beforeTestMethod`, in full:

```java
PlatformTransactionManager tm = null;
TransactionAttribute transactionAttribute = this.attributeSource.getTransactionAttribute(testMethod, testClass);

if (transactionAttribute != null) {
    transactionAttribute = TestContextTransactionUtils.createDelegatingTransactionAttribute(...);
    ...
    if (transactionAttribute.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NOT_SUPPORTED ||
            transactionAttribute.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NEVER) {
        return;                                   // ← returns BEFORE any manager lookup
    }
    tm = getTransactionManager(testContext, transactionAttribute.getQualifier());
    ...
}
```

The listener returns before `getTransactionManager` is ever called. No manager is resolved, so there is
nothing for a qualifier to correct. The exemption is not a hole.

The suspension objection is a category error here: suspension is what the **AOP interceptor**
(`TransactionAspectSupport`) does when a *service* method annotated `NOT_SUPPORTED` is invoked inside an
existing transaction. At the test-context level there is no ambient transaction to suspend — the listener
is the thing that would have created one. The rail scopes itself to test-class and test-method annotations
only, so it is exempting exactly the path where the exemption is sound.

The rail is also right to leave `SUPPORTS` un-exempt (documented in its javadoc): `SUPPORTS` falls through
to `getTransactionManager`, so it can bind the wrong one.

### `PickingorderBusinessServiceH2Test` specifically

- Its own `@Transactional(propagation = Propagation.NOT_SUPPORTED)` at class level **overrides** the base
  class annotation entirely, so `d253eaa6` is a **no-op** for it.
- Measured: `Tests run: 2, Failures: 0` in the post-fix run **and** `Tests run: 2, Failures: 0` under M1
  (pre-fix). Identical. Behaves as intended.
- **Does it leak rows? Yes, by construction — and it cleans up after itself.** With no test-managed
  transaction, every `save()` commits. The class carries an `@AfterEach tearDown()`
  (`PickingorderBusinessServiceH2Test.java:74-91`) that `deleteAll()`s fourteen repositories. So the net
  leak is zero for a completed run.

Two residual hazards, both pre-existing and neither introduced by this change:

- That `tearDown()` wipes **fourteen shared tables** in the single JVM-wide H2 (`wms_integration`,
  `DB_CLOSE_DELAY=-1`, surefire default `forkCount=1`/`reuseForks=true`, no `junit-platform.properties`
  enabling parallelism). It is safe only because JUnit runs classes sequentially today. Turning on parallel
  execution would make it destructive to whatever runs alongside it.
- If `tearDown()` itself throws, the rows survive. Nothing asserts they do not.

Worth a sentence in the rail's exemption javadoc: `NOT_SUPPORTED` is exempt from *naming a manager*, but it
is **not** exempt from leaking — it just leaks legitimately, and the cleanup is manual and unpinned.

---

## Summary of things worth acting on

Nothing here blocks the change. In descending order of value:

1. **CLAIM 6's javadoc is misleading** (`TestClassTransactionManagerArchTest.java:41-50`). Rewrite the
   `BaseIntegrationTest` allow-list rationale: the blocker is `MessageCleanupBatchServiceIT`'s
   transaction-name assertion, not "almost nothing runs". Name `AdviceServiceIntegrationTest` and
   `CustomerOrderControllerIntegrationTest` as the two failsafe classes that would verify a future fix.
2. **The resolution-order sentence is inverted** in `BaseRepositoryIntegrationTest.java:29` and in
   `BaseRepositoryIntegrationTestRollbackContractTest`'s javadoc. `@Primary` is consulted *before* the
   `"transactionManager"` default name, not after. Outcome unchanged; the comment is long enough to read
   as teaching material, so it should be right.
3. **The rail cannot see meta-annotated `@Transactional`** (`isAnnotatedWith`, not `isMetaAnnotatedWith`).
   Harmless today — `TenantTransactional` is always qualified — but worth one line of javadoc so the next
   person does not assume coverage it does not have.
4. **`nonVacuityGuard`'s `hasSizeGreaterThan(500)` is loose**: 1971 test classes exist today, so the
   importer could silently lose two thirds of the tree and still pass.

---

## Postscript — concurrent edits, and a residue check

Everything above was measured against the **committed** state `be04502d..f5f64e4b`. Between my final
restore (verified clean: `md5sum -c` OK on both mutated files, `git status --porcelain` empty) and the
writing of this report, another lane began editing three files in this same worktree:
`BaseRepositoryIntegrationTest.java`, `BaseRepositoryIntegrationTestRollbackContractTest.java` and
`TestClassTransactionManagerArchTest.java`. Those working-tree changes are **not mine** and I have left
them untouched.

I re-checked that none of my three mutations left residue in the tree:

| Probe | Expected | Actual |
|---|---|---|
| `no-such-dir-mutant` in the rail (M3) | 0 | **0** |
| `BaseIntegrationTest", 2` in `ALLOWED` (M2) | 0 | **0** |
| bare `^@Transactional$` in the base class (M1) | 0 | **0** |
| `@Transactional("tenantTransactionManager")` in the base class | 1 | **1** |
| `location.contains("/test-classes/")` in the rail | 1 | **1** |

Clean. My mutations are fully reverted; the current diff is entirely the other lane's.

**One flag on those uncommitted edits.** The new javadoc in `TestClassTransactionManagerArchTest`
states *"there are **8** that write via `net.aim_ai.wms.repo.jpa`, of which **6** are `*IT`"*. That
still does not reproduce against my bytecode measurement, which finds **6** writers among the 13
subclasses (4 of them `*IT`), or **7** classes if the criterion is loosened from "calls a
`save`/`delete`/`flush` method on a `repo.jpa` type" to "references a `repo.jpa` type at all" (5 of
those `*IT`). See the CLAIM 6 table for the per-class figures. The *substantive* correction in that
edit — that `AdviceServiceIntegrationTest` and `CustomerOrderControllerIntegrationTest` do run in
failsafe, so the change is partially verifiable — matches my finding and is the part that mattered.
The 8/6 tally should be re-derived or softened to "most" before it is committed, since it is the
third different pair of numbers this rationale has carried.
