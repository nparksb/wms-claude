# SBDEV-3418 Lane B — Test Surface Evidence

Scope: `v2/wms2-api`, graded against `origin/develop` @ `f2ee75f16b36723fb97994c52cb79b2c66754f1e`
(fetched fresh at task start; local checkout was NOT used for grading — it sits on an unrelated
branch). All quotes below are `git show origin/develop:<path>` / `git grep ... origin/develop`
output.

Planned change under evaluation: add `@Transactional` + pessimistic row locks to
`MobileTruckLoadingService.scanGate`, and move the `mobileTransferService.handleTruckOffLoading(...)`
call to the FRONT of the method (today it sits mid-method, after
`unitloadBusinessService.transferUnitLoadToLocation(...)`).

---

## 1. Existing tests of `MobileTruckLoadingService`

Two test classes exist, confirming the repo's documented duplicate-pair history — **these are NOT
duplicates; they are a legitimate (if uneven) split**, one full-coverage, one partial:

### 1a. `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingServiceTest.java` (632 lines)

- **Construction**: hand-built constructor, all 15 args, in `@BeforeEach setUp()`:
  `mobileTruckLoadingService = new MobileTruckLoadingService(billofladingPositionRepository, locationRepository, unitloadRepository, billofladingRepository, customerorderPositionRepository, billofladingPositionService, stockunitRepository, unitloadBusinessService, customerorderRepository, syspropService, userRepository, itemdataRepository, itemdataService, mobileTransferService, manageOrderService);`
  — every dependency including `itemdataService` and `manageOrderService` is a declared `@Mock`.
- **Strictness**: explicit `@MockitoSettings(strictness = Strictness.STRICT_STUBS)` on the class,
  plus `@ExtendWith(MockitoExtension.class)`, extends `net.aim_ai.wms.common.base.BaseUnitTest`.
- **Test methods and what they assert** (scanGate-relevant ones only; full list is 26 methods
  across `loadOrder`/`checkPallet`/`scanGate`/`truckLoadingMobileDTOByBolName`/`resolveBOLType`/
  `getBOLManifestLocations`):
  - `testScanGateSuccessfully` — happy path; stubs every repo call `scanGate` makes in its current
    order and asserts `result.getManifestLocationsOnBOL()` plus
    `verify(unitloadBusinessService).transferUnitLoadToLocation(...)` and
    `verify(mobileTransferService).handleTruckOffLoading("PALLET001")`.
  - `testScanGateWithNullPalletName`, `testScanGateWithNullBolName`, `testScanGateWithNullGateName`,
    `testScanGatePalletNotFound`, `testScanGateGateNotFound`, `testScanGateWithDifferentGate` — all
    early-guard-clause tests; none reach `transferUnitLoadToLocation` or
    `handleTruckOffLoading`.

- **Break analysis**:
  - **(a) class gains `@Transactional`** — a hand-built-constructor Mockito unit test never touches
    a `PlatformTransactionManager` or a real `@Transactional` proxy; the annotation is inert to a
    plain-old-object test. **No break predicted.**
  - **(b) `handleTruckOffLoading` moves to the front of `scanGate`** — `testScanGateSuccessfully`
    stubs every collaborator call unconditionally (no `verify(...).calledBefore/inOrder`
    ordering assertion is used anywhere in this file), so a pure reordering of two already-stubbed
    calls does not fail this test. **No break predicted from reordering alone.**
  - **(c) new locking finders called that mocks do not stub** — under `STRICT_STUBS`, a
    **newly-introduced call** to an unstubbed mock method (e.g. `unitloadRepository.findByLabelidForUpdate(...)`
    if the fix swaps `findByLabelid` for a locking finder) returns `null` from Mockito for an
    object-returning method with no stub, which would NPE inside `scanGate` on first dereference —
    **this WOULD break `testScanGateSuccessfully`** (and only that test; the guard-clause tests
    never reach the locking call). It would surface as an `UnnecessaryStubbingException` on the
    *old* finder's stub too, if the fix removes the old call but the test still stubs it (strict
    stubbing fails a test class at teardown for any stub never invoked).

### 1b. `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingServiceUnitTest.java` (268 lines)

- **Construction**: `@InjectMocks private MobileTruckLoadingService mobileTruckLoadingService;`
  (Mockito constructor injection). Declares 14 `@Mock` fields — **missing `itemdataService` and
  `manageOrderService`** (confirmed absent from the field list; grep for those two names in this
  file returns nothing). Mockito's constructor-injection `@InjectMocks` passes `null` for any
  constructor parameter it cannot match by type, so both fields are `null` on the constructed
  instance.
- **Strictness**: no explicit `@MockitoSettings`; extends `BaseServiceUnitTest extends BaseUnitTest`,
  and `BaseUnitTest` carries `@ExtendWith(MockitoExtension.class)` with no strictness override —
  `MockitoExtension`'s own default is `STRICT_STUBS`, so this class is also strict by the
  library default, not by an in-repo declaration.
- **Test methods**: organized under `@Nested` classes `LoadOrder` (3 tests), `CheckPallet` (4 tests),
  `TruckLoadingMobileDTOByBolName` (2), `ResolveBOLType` (1), `GetBOLManifestLocations` (1) — **11
  tests total, ZERO of them exercise `scanGate`.** There is no `@Nested class ScanGate` in this file.
- **Break analysis**: since no test here calls `scanGate` at all, **none of (a)/(b)/(c) can break
  anything in this file today.** Flag for the implementer, not a prediction of breakage: because
  `itemdataService`/`manageOrderService` are unmocked here, a future contributor adding a `scanGate`
  test to *this* class (rather than to 1a) will NPE immediately on `manageOrderService.customerOrderLoadedToTruck(...)`
  unless those two `@Mock` fields are added first.

---

## 2. The arch rails

All four live under `src/test/java/net/aim_ai/wms/unit/config/` except `NestedCallSiteRailTest`
(`src/test/java/net/aim_ai/wms/unit/service/`).

### `OptionalSafetyArchTest`
- **Invariant**: `FreezingArchRule.freeze(noClasses().that().resideInAPackage("net.aim_ai.wms.service..").should().callMethod(Optional.class, "get")...)`
  — no class under `net.aim_ai.wms.service..` may call `Optional.get()`, frozen against a stored
  baseline (call-site presence only, no dataflow — a guarded `isPresent() ? get() : ...` still
  counts as a call site and must be frozen to pass).
- **Scan set**: `new ClassFileImporter().withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS).importPackages("net.aim_ai.wms.service")`.
- **Store**: `src/test/resources/archunit_store/5fb3fee0-6caf-4f48-a5cd-5271da610572`, keyed by
  `src/test/resources/archunit_store/stored.rules` → rule text maps to that filename. Path is
  configured in `src/test/resources/archunit.properties`:
  `freeze.store.default.path=src/test/resources/archunit_store` /
  `freeze.store.default.allowStoreCreation=true`.
- **`MobileTruckLoadingService` frozen entries — verified, exactly 2, confirming SBDEV-3398 §4.4.6**:
  ```
  Method <net.aim_ai.wms.service.mobile.MobileTruckLoadingService.scanGate(net.aim_ai.wms.json.mobile.TruckLoadingMobileDto)> calls method <java.util.Optional.get()> in (MobileTruckLoadingService.java:190)
  Method <net.aim_ai.wms.service.mobile.MobileTruckLoadingService.scanGate(net.aim_ai.wms.json.mobile.TruckLoadingMobileDto)> calls method <java.util.Optional.get()> in (MobileTruckLoadingService.java:207)
  ```
  (a third, unrelated entry exists for `truckLoadingMobileDTOByBolName:337`, not in `scanGate`).
  Line 190 is `Unitload pallet = palletOpt.isPresent() ? palletOpt.get() : null;` (pallet lookup);
  line 207 is `Location gate = gateOpt.isPresent() ? gateOpt.get() : null;` (gate lookup) — matching
  the ternary idiom the ticket describes.
- **Orphaned vs. new violation — does the test FAIL on an orphan?** No. The store's own in-repo
  javadoc states plainly: *"a plain `mvn test` run also mutates the file (it prunes solved
  entries)"* and separately documents that `freeze.lineMatcher` is unset so ArchUnit's default
  `FuzzyViolationLineMatcher` is used, which "ignores numbers that are potentially line numbers" —
  i.e. matching is by **method signature**, not line number, and a **rename** (not a body edit)
  is what orphans an entry. The javadoc's measured example: *"55 of the 148 stored entries point at
  a source line that holds no `.get()` at all ... and the build is green."* **The actual
  fail/pass-deciding code is ArchUnit's own `FreezingArchRule`/`TextFileBasedViolationStore`
  library classes (`com.tngtech.archunit:archunit`), not repo source** — this repo only supplies
  the rule definition and the properties file; I could not find an in-repo override of the pruning
  behavior. Practical consequence for this ticket: **restructuring `scanGate` so the two
  `palletOpt.get()`/`gateOpt.get()` call sites simply move to different line numbers, or even
  disappear because the extraction changes them to `.orElseThrow()`, will NOT fail this test** — it
  will either match the surviving signature (if the method name `scanGate` doesn't change) or
  silently prune the entry (if the code path is genuinely removed). It WOULD fail if the fix
  **renames** `scanGate` (signature-keyed) while a `.get()` call survives under the new name, or if
  the fix adds a **new, distinct** unguarded `.get()` call site elsewhere that isn't already frozen.

### `NestedCallSiteRailTest` (SBDEV-3267 gate)
- **Invariant**: no `TransactionSynchronizationManager.registerSynchronization(...)` callback body
  (brace-matched, source-text scan) may reach a method in a fixed `SELF_DEFERRING` list (things that
  themselves call `OmsNotificationService.sendAfterCommit`, including
  `manageOrderService.customerOrderLoadedToTruck`).
- **Scan set**: `Files.walk(Paths.get("src/main/java/net/aim_ai/wms"))`, filtered to files
  containing the literal string `TransactionSynchronizationManager.registerSynchronization` — a
  text scan, not ArchUnit.
- **Store**: none — assertion is inline (`assertThat(offenders).isEmpty()`), no freeze file.
- **Relevance to `MobileTruckLoadingService`**: **none today.** Confirmed by
  `git grep -n "registerSynchronization" origin/develop -- .../MobileTruckLoadingService.java`
  returning only a comment line (`// registerSynchronization made this a DOUBLE deferral...`), no
  live call. The source itself documents why: SBDEV-3267 already de-nested this exact call
  (`manageOrderService.customerOrderLoadedToTruck(...)` is called directly inside a bare
  `try/catch`, not inside a `registerSynchronization` callback) — so this rail's scan won't even
  pick up `MobileTruckLoadingService` as a source file to inspect, and adding `@Transactional` or
  reordering calls inside `scanGate` cannot make it reappear unless a NEW `registerSynchronization`
  call is introduced.

### `HttpInTransactionArchTest`
- **Invariant**: `methods().that().areAnnotatedWith(Transactional.class).should(notCallHttpRestService())`
  — a **direct** call from an `@Transactional`-annotated method to `HttpRestService` is forbidden.
  Explicitly, by design, **not transitive**: *"A transitive variant — a `@Transactional` caller
  invoking a non-annotated helper that does the HTTP — is deliberately out of scope: a
  reachability rule would false-positive on legitimate after-commit registration paths such as
  `OmsNotificationService.sendAfterCommit`."*
- **Scan set**: whole app tree, `new ClassFileImporter().withImportOption(DO_NOT_INCLUDE_TESTS).importPackages("net.aim_ai.wms")`.
- **Store**: none — not a `FreezingArchRule`, a plain `ArchCondition` check each run.
- **Relevance**: `scanGate` does not call `HttpRestService` directly anywhere in its body (grepped;
  only repository/service calls). Even if `@Transactional` is added to `scanGate`, and even though
  `manageOrderService.customerOrderLoadedToTruck(...)` may transitively reach HTTP via
  `sendAfterCommit`, this rule is **scoped to direct calls only by its own documented design**, so
  it will not fire. **Would only fire if the fix adds a literal `httpRestService.someMethod(...)`
  call directly inside `scanGate` (or another newly-`@Transactional` method) once `@Transactional`
  is present.**

### `TestClassTransactionManagerArchTest`
- **Invariant**: no **test** class or method may carry a bare (unqualified) `@Transactional`
  (falls back to the `@Primary` `landlordTransactionManager` and silently routes tenant writes to
  the wrong DB) — two sub-checks, `noNewBareTransactionalInTests` (an `ALLOWED` allow-list, **now
  empty** per the class's own javadoc: *"Historical — `ALLOWED` is now EMPTY"*) and
  `nonTransactionalPropagationsMustBeDeclared`.
- **Scan set**: test classes only, matched by compiled-class location rather than package —
  `ImportOption onlyTestClasses = (Location location) -> location.contains("/test-classes/");` then
  `importPackages("net.aim_ai.wms")`.
- **Store**: no freeze file; the allow-list is an in-code `Map<String,Integer> ALLOWED` (currently
  empty) plus a companion `Set<String> EXEMPT_NON_TRANSACTIONAL`.
- **Relevance**: not about `MobileTruckLoadingService`'s main-code annotation at all — it fences
  **new test classes** we write for SBDEV-3418. Both existing concurrency-IT templates
  (`ClosebolLockOrderProbeIT`, `MobilePalletizeRaceIT`) already comply by using the qualified,
  non-participating form `@Transactional(value = "tenantTransactionManager", propagation = Propagation.NOT_SUPPORTED)`
  — any new IT cloned from that shape is safe by construction; a bare `@Transactional` on a new test
  class would fail this rail.

---

## 3. `UnitloadBusinessServiceUnitTest` — SBDEV-3398's prediction is **WRONG**

File: `src/test/java/net/aim_ai/wms/unit/service/UnitloadBusinessServiceUnitTest.java` (1802 lines).

- **Construction**: `@InjectMocks private UnitloadBusinessService unitloadBusinessService;` with 12
  `@Mock` fields (all `UnitloadBusinessService`'s own collaborators — `LocationRepository`,
  `UnitloadRepository`, `EntityManager`, etc.) plus manual `ReflectionTestUtils.setField(...,
  "entityManager", entityManager)` for the `@PersistenceContext` field Mockito's constructor
  injection can't reach.
- **Grep confirms zero coupling to `MobileTruckLoadingService`**:
  `git grep -n "MobileTruckLoadingService\|import net.aim_ai.wms.service.mobile"` on this file
  returns **one hit, a comment**, at the SBDEV-3341 javadoc (`"{@code MobileTruckLoadingService}
  and {@code ParcelMonitorViewService} then move the pallet to the gate with ignoreLock=false"`) —
  prose explaining a *production* call chain for context, not a test dependency. There is **no
  `import`, no field, no mock, no instantiation** of `MobileTruckLoadingService` anywhere in this
  file.
- **Why the prediction fails**: every test in this class (e.g.
  `transferUnitLoadToLocation_doesNotRefuse_whenSourceUnitLoadIsLocked`,
  `transferUnitLoadToLocation_shouldFetchDestinationLocationWithPessimisticLock_whenIgnoreLockFalse`)
  calls `unitloadBusinessService.transferUnitLoadToLocation(...)` **directly**, as the method under
  test, with `unitloadBusinessService` built standalone via `@InjectMocks`. A caller-side
  `@Transactional` on `MobileTruckLoadingService`, or a reordering of statements inside
  `MobileTruckLoadingService.scanGate`, has **no code path by which it could reach this test file**
  — Mockito never invokes a real Spring transaction manager, and this test never constructs or
  calls through `MobileTruckLoadingService` at all. **Stated plainly, not rationalized: SBDEV-3398's
  prediction that this class "goes red" does not hold against today's develop, and there is no
  mechanism by which it could.** (If SBDEV-3398 meant a *different*, not-yet-written test — e.g. an
  integration test exercising the real caller chain — that would be a distinct claim than "this
  existing unit test class breaks.")

---

## 4. Concurrency / integration test templates

Three named classes all exist. Best template for the target (proving whether a pending
`UPDATE billoflading` survives `@Modifying(clearAutomatically = true)`) is
**`ClosebolLockOrderProbeIT`** — it is BOL-centric (locks `billoflading`/`unitload`/`customerorder`
rows via the real `billofladingService.closeBOL(...)` call) and uses raw multi-connection JDBC,
which is what's needed to observe persistence-context/flush timing independent of the test's own
transaction. `MobilePalletizeRaceIT` shares the identical class-level shape but races two threads
through the Spring-managed service layer instead of raw connections; `ParcelMonitorViewServiceConcurrencyIT`
is the weakest fit — its own javadoc is stale (see below).

### `ClosebolLockOrderProbeIT` (`src/test/java/net/aim_ai/wms/integration/service/ClosebolLockOrderProbeIT.java`, 383 lines) — the template to clone

- **Class-level annotations, verbatim**:
  ```java
  @DisplayName("SBDEV-3419 — closeBOL's measured unitload/customerorder lock order")
  @Transactional(value = "tenantTransactionManager", propagation = Propagation.NOT_SUPPORTED)
  class ClosebolLockOrderProbeIT extends BasePostgresIntegrationTest {
  ```
  `BasePostgresIntegrationTest` itself carries:
  ```java
  @SpringBootTest(classes = StartApplication.class)
  @ActiveProfiles("postgres-integration")
  @Import(PostgresTestSupportConfig.class)
  @ExtendWith(AppPostgresDBSetupExtension.class)
  @Transactional("tenantTransactionManager")   // per its class comment: qualifier is load-bearing
  ```
  (the subclass's own `propagation = Propagation.NOT_SUPPORTED)` overrides the base class's plain
  `@Transactional("tenantTransactionManager")` so the **test method itself does not run inside a
  Spring-managed transaction** — required so raw JDBC connections opened inside the test see
  committed state independently).
- **How it obtains two (here three) concurrent connections**: raw JDBC via
  `DriverManager.getConnection(c.getJdbcUrl(), c.getUsername(), c.getPassword())` against the
  shared `AppPostgresDBContainer.container` — a **holder** connection (`Connection holder = open()`)
  that parks on a `SELECT ... FOR UPDATE` and never commits until released, a **worker** (submitted
  to a single-thread `ExecutorService`, calls the real `billofladingService.closeBOL(bolId)` through
  the normal Spring-managed service — this is where the actual code-under-test's transaction runs),
  and an **observer** connection that polls `pg_stat_activity` / `pg_blocking_pids()` / `pg_locks`
  to see what the worker is blocked on and what it already holds.
- **How it asserts contention** (not a hard deadlock/timeout — a **lock-order snapshot**): after the
  holder parks on one row, it submits the worker, then polls (100ms interval, 30s deadline) via
  `awaitBlockedBackend` for a backend that `pg_blocking_pids(pid)` reports as blocked BY the holder's
  pid, and once found, snapshots that backend's held row locks
  (`select distinct c.relname ... where l.pid = <blockedPid> and l.granted and l.mode in
  ('RowShareLock','RowExclusiveLock') and c.relkind = 'r'`). Assertions then check
  `snap.rowLockedRelations` contains/does-not-contain specific table names, each with an explicit
  **non-vacuity control** comment (e.g. *"non-vacuity control: PostgreSQL grants the relation-level
  lock before blocking on the row, so the table the worker is blocked on is necessarily in the
  snapshot"*).
- **Cleanup**: `@AfterEach void cleanUp() { deleteResidue(); }`, plus the same `deleteResidue()` also
  runs at the top of `@BeforeEach seed()`. `deleteResidue()` is a fixed FK-ordered sequence of
  `jdbcTemplate.update("delete from ... where <col> like ?", TAG + "%")` calls keyed off a
  class-unique `TAG` constant (`"SBDEV3419"`), because *"the container is shared and reused across
  BUILDS"* — there is no per-test-run isolation, cleanup is by naming convention. The holder
  connection releases via `holder.rollback()` in a `finally`, and the worker is always joined
  (`worker.get(90, TimeUnit.SECONDS)`) even on the timeout path, with the comment: *"Leaving it
  unjoined would wedge the subsequent deleteResidue(), which runs with lock_timeout = 0 and would
  hang rather than fail."*

### `MobilePalletizeRaceIT` — same class-level shape

`git show origin/develop:.../MobilePalletizeRaceIT.java` lines 70–72, verbatim:
```java
@DisplayName("SBDEV-3398 AC-6 — two operators, one parcel, two pallets: exactly one must win")
@Transactional(value = "tenantTransactionManager", propagation = Propagation.NOT_SUPPORTED)
class MobilePalletizeRaceIT extends BasePostgresIntegrationTest {
```
Confirms the `NOT_SUPPORTED` pattern is the established convention for this repo's real-contention
ITs, not a one-off.

### `ParcelMonitorViewServiceConcurrencyIT` — weaker fit, and stale self-description

```java
@DisplayName("ParcelMonitorViewService Concurrency IT (SBDEV-2232)")
@org.springframework.transaction.annotation.Transactional("tenantTransactionManager")
class ParcelMonitorViewServiceConcurrencyIT extends BasePostgresIntegrationTest {
```
No `NOT_SUPPORTED` override — uses two `TransactionTemplate`s run on separate threads instead of raw
JDBC connections, each opening its own Spring-managed transaction. **Its own javadoc is wrong**:
*"Uses {@link BaseIntegrationTest} (H2 in-memory) — consistent with all other v2 integration tests."*
— the class actually `extends BasePostgresIntegrationTest` (real PostgreSQL Testcontainers), not
`BaseIntegrationTest`/H2 as the comment claims. Flagging this as a doc-vs-code drift found in
passing, not something SBDEV-3418 needs to fix.

---

## 5. How to run them

**One unit test class** (either `MobileTruckLoadingServiceTest` or `MobileTruckLoadingServiceUnitTest`):
```
mvn test -Dtest=MobileTruckLoadingServiceTest
```
No traps apply here — surefire's default includes cover any `*Test.java` class in the unit tree.

**One `*IT` class** (e.g. `ClosebolLockOrderProbeIT`) — quoted verbatim from
`pom.xml`'s failsafe `<configuration>` comment (the pom's own documented recipe, current as of
SBDEV-3091):
```
mvn verify -Dit.test=ClosebolLockOrderProbeIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
```
The pom explicitly warns against the alternative:
```
LIES:   mvn failsafe:integration-test -Dit.test=<Class>
        The standalone goal reports "Tests run: 0" + BUILD SUCCESS for ANY
        class — included or not. It is a no-op outside the lifecycle, so it
        looks like a pass and proves nothing.
```

**Traps checked against this pom, verdicts**:
- `*IntegrationTest` not in surefire includes — **CONFIRMED**. Surefire's `<excludes>`:
  ```xml
  <excludes>
      <exclude>**/*IntegrationTest.java</exclude>
      <exclude>**/*E2ETest.java</exclude>
  </excludes>
  ```
  (`*IT.java` classes were never in surefire's default includes to begin with — surefire's built-in
  default include patterns are `**/Test*.java`, `**/*Test.java`, `**/*Tests.java`,
  `**/*TestCase.java`, none of which match `*IT.java`; this repo adds no explicit `<includes>` to
  surefire, so the built-in defaults apply.)
- `-Dsurefire.failIfNoSpecifiedTests=false` needed for the `mvn verify -Dit.test=` recipe —
  **CONFIRMED**, it's in the pom's own documented "WORKS" command quoted above (needed because
  `-Dtest=ZzzNone` matches nothing in the surefire/unit lane, and surefire would otherwise fail the
  build on "no tests found" before failsafe ever runs).
- `-Dit.test='!Class'` discards the pom's `<includes>` — **not directly testable from the pom text**
  (this is documented ArchUnit/Maven Failsafe behavior referenced in the pom's own comment: *"⚠ Use
  -Dfailsafe.excludes, NOT -Dit.test. An exclusion-only -Dit.test pattern DISCARDS this pom's
  &lt;includes&gt; and makes failsafe run the ENTIRE test tree"* — quoted from the CI workflow file
  `.github/workflows/docker-image-develop.yml`, not the pom itself, but referencing this same pom's
  `<includes>`).
- `mvn` without `clean` runs DELETED test classes from stale `target/test-classes` — **repo's own CI
  workflow explicitly guards against this**: `.github/workflows/docker-image-develop.yml` runs
  `mvn -B -ntp clean verify ...` (quoted above at line 183), and its comment says why: *"`clean`
  because a stale target/test-classes makes Maven run test classes that no longer exist in
  source."* Not a pom-level setting — it's operational discipline encoded in the CI invocation.

---

## 6. Baseline

**Surefire vs. failsafe lanes, per pom** (both fully wired as of SBDEV-3239/SBDEV-3091, measured
2026-09-06 per the pom's own history comment):
- Surefire (unit, `mvn test` / phase `test`): everything EXCEPT `**/*IntegrationTest.java` and
  `**/*E2ETest.java`.
- Failsafe (integration, `mvn verify` / phase `integration-test`+`verify`):
  ```xml
  <includes>
      <include>**/*IntegrationTest.java</include>
      <include>**/*E2ETest.java</include>
      <include>**/*IT.java</include>
  </includes>
  <excludes/>
  <excludedGroups>${failsafe.excludedGroups}</excludedGroups>
  ```
  with `<excludedGroups>` defaulting to `performance` (property `failsafe.excludedGroups` at pom
  line 42) — i.e. the failsafe `<excludes/>` list itself is **empty** (pom's own comment: *"this
  list is EMPTY, and that is the finish line SBDEV-3239 set"*), the only filtering left is the
  `performance`-tagged group.
- CI gate: `.github/workflows/docker-image-develop.yml`, job `test`, runs `mvn -B -ntp clean verify
  -Dmaven.javadoc.skip=true -Dspringdoc.skip=true`, triggered on `push: branches: [develop]` AND
  `pull_request: branches: [develop]`. A downstream `deploy` job `needs: test`, so a failing test
  job blocks the image build. This is the authoritative gate for both lanes together.

**No authoritative static in-repo baseline (pass/fail counts) exists.** I searched
`docs/plan/**/*.md` for "baseline" and found only unrelated planning documents (refactor/migration
plans that happen to use the word), none of which record a current expected pass/fail count for
`mvn clean verify`. This matches the standing project memory that the baseline must be measured
live from a detached `develop` worktree rather than trusted from a doc or from memory — consistent
with the CI workflow itself being the only mechanism that actually re-establishes "green" on every
push/PR, with no committed snapshot of what that run currently reports. Per this task's instructions
I did **not** run the full suite to produce a fresh count.

---

## Summary of corrections to SBDEV-3398's predictions

1. **CONFIRMED**: `OptionalSafetyArchTest` has exactly 2 frozen entries for
   `MobileTruckLoadingService.scanGate` (lines 190, 207 — the pallet and gate `isPresent() ? get() :
   null` idioms). Restructuring that moves these lines or converts them to `.orElseThrow()` will NOT
   fail the rail (signature-keyed matching + automatic pruning of solved entries on any `mvn test`
   run); it WOULD fail on a `scanGate` rename that still calls `.get()`, or a genuinely new unguarded
   `.get()` call site.
2. **WRONG, stated plainly**: `UnitloadBusinessServiceUnitTest` cannot be affected by a caller-side
   `@Transactional` or call-reordering in `MobileTruckLoadingService` — it has zero code-level
   coupling to that class (one comment mention only, no import/field/call).
3. `NestedCallSiteRailTest` (SBDEV-3267 gate) does not currently scan `MobileTruckLoadingService` at
   all — no live `registerSynchronization` call exists there.
4. `HttpInTransactionArchTest` is scoped to **direct** `HttpRestService` calls from `@Transactional`
   methods by explicit design; adding `@Transactional` to `scanGate` alone cannot trip it unless a
   direct HTTP call is also added.
