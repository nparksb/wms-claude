---
name: hub-wms2-test-harness
description: "Test lanes, fixtures, mocks and harness behaviours that make tests lie in wms2-api and v1. Hub: one line per member memory"
metadata:
  node_type: memory
  type: reference
  originSessionId: 7b155671-54ac-4689-8213-a9af450d48d6
  modified: 2026-10-31T08:14:21.274Z
---

Hub for **wms2/v1 test harness & fixture traps**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [Gate Spring bean changes on clean compile](verify-spring-bean-changes-clean-compile-and-context-load.md) — unit tests miss DI wiring
- [Tx tests blind to propagation/readOnly](transactional-tests-blind-to-propagation-and-readonly.md) — a NOT_SUPPORTED mutant was 100% green
- [NOT_SUPPORTED test needs an EXEMPT_NON_TRANSACTIONAL entry](not-supported-test-needs-exempt-list-entry.md) — SBDEV-3980 CI red; test-only commits still need the full suite
- [Green tests that prove nothing](green-tests-that-prove-nothing.md) — STRICT_STUBS is already default; a swallowed
- [Cross-field setter silently un-pins fixtures](cross-field-setter-silently-unpins-fixtures.md) — no diff to the test; PIT scoped to the changed class can't see it
- [CORRECTED: wms2-api *IT DOES run](wms2-api-29-it-classes-run-in-neither-test-lane.md) — since SBDEV-3239; real gap is ITs that hand-COPY native SQL
- [wms2-api has 11 duplicate test-class pairs](wms2-mobile-palletizing-has-two-duplicate-test-classes.md) — SBDEV-3102; 9 real + 2 legit splits;
- [v1 ITs leak a postgres container per run](v1-testcontainers-withreuse-leaks-a-container-per-run.md) — `withReuse(true)` w/o reuse enabled; 43
- [Mockito never(): don't widen primitives to any()](mockito-never-any-primitive-unboxing-trap.md) — any() returns null → NPE at unboxing; a primitive
- [`mvn test` runs DELETED test classes](mvn-without-clean-runs-deleted-tests.md) — stale target/test-classes
- [src-wide scans also pick up test classes](wms2-src-wide-scans-also-pick-up-test-classes.md) — component scan AND reflection pins see src/test; a sibling survives only on a name coincidence
- [wms2 suite baseline + H2 verdict](wms2-test-suite-baseline-and-h2-verdict.md) — no single correct number; ParcelMonitor IT is FLAKY not container-state; run the baseline yourself, adjacent in time
- [Un-suppressing a test can create a false green](un-suppressing-a-test-can-create-a-false-green.md) — a negative assertion on a fixture nobody wrote passes forever
- [wms2 repo tests COMMIT, never roll back](wms2-repository-tests-commit-they-do-not-roll-back.md) — wrong tx manager; assert by id, never isEmpty/hasSize; bare @PersistenceContext = landlord EM
- [test/resources shadows main application.properties](wms2-test-resources-shadows-main-application-properties.md) — no lane sees a production-only property; a mutant there reaches nothing
- [surefire ignores -Duser.language](surefire-does-not-propagate-user-locale-props.md) — use LANG/LC_ALL env; the -D form is a false-negative that reads as a disproved hypothesis
- [wms2 has TWO full-context test lanes](wms2-has-two-full-context-test-lanes.md) — only Testcontainers was broken; the MockMvc lane predates SBDEV-3239 by months
- [v1 IT lane works; @Disabled reasons are stale](v1-it-lane-works-disabled-reasons-are-stale.md) — not ro_id; RepositoryH2TestConfiguration bean collision; 1-property fix
- [v1 `mvn verify` never runs the IT lane](v1-wms-api-verify-aborts-before-it-lane.md) — surefire's 19 pre-existing errors abort the build first; baselines for both lanes
- [wms2 concurrency-IT fixture traps](wms2-concurrency-it-fixture-traps.md) — client_id does NOT isolate a fixture; jdbcTemplate version bump self-deadlocks; context JdbcTemplate (landlord pool, autocommit off) never commits
- [`mvn test` can't see wms2-api's integration lane](mvn-test-cannot-see-the-integration-lane.md) — CI runs `verify`; H2 IT base seeds nothing; seed sequences via committed JDBC
- [A selected -Dtest run is NOT the suite](selected-test-classes-is-not-the-suite.md) — hid 3 reds on one PR, 4 on another; repo-wide ArchUnit rails are unreachable by a targeted selector
- [A sibling merge silently disarms your tests](sibling-merge-silently-disarms-your-tests.md) — green PR check grades a stale base; a new conjunct on a @Mock answers false
- [BaseRollbackIntegrationTest shares one H2 DB with create-drop](wms2-baserollback-shared-h2-create-drop.md) — a context eviction empties it for every sibling; adding a subclass reddens an untouched class in CI. Give new subclasses private DB names
- [IT harness is blind to entity-identity comparisons](wms2-it-harness-blind-to-entity-identity-comparisons.md) — one persistence context per test; the v1-shape mutant survives
- [Mockito varargs captor needs the ARRAY class](mockito-varargs-captor-needs-array-class.md) — one forClass(X.class) matches arity-1 only; reads as "never called"
- [Editing an unmerged migration breaks the reusable IT container](editing-unmerged-migration-breaks-reusable-test-container.md) — 51 ITs FlywayValidate checksum mismatch; delete the history row, not the container
- [entity_lock NULL in IT fixtures](wms2-itemdata-entity-lock-null-in-it-fixtures.md)
- [Static ArchUnit imports OOM CI](wms2-static-archunit-imports-oom-the-ci-fork.md)
- [wms2 PG IT lane has NO tenant pool](wms2-pg-it-lane-has-no-tenant-pool.md) — N threads = N conns; limit max_connections
- [IT seeding System client: evict `clients` cache](wms2-it-seeding-system-client-must-evict-clients-cache.md) — before+after
- [H2 schema reset leaves stale app caches](wms2-h2-schema-reset-leaves-stale-app-caches.md) — cache-reset listener; guard hasApplicationContext
- [Repo IT base is H2: order ties + FKs invisible](wms2-base-repository-it-is-h2-order-ties-and-fks-invisible.md) — pin SQL on PG lane
- [Race-IT worker needs TenantContext](race-it-worker-needs-tenantcontext-or-pin-is-vacuous.md) — copy the caller's into the worker, or a must-fail pin passes on a TimezoneService throw
- [Integration profile has no security chain](wms2-integration-profile-has-no-security-chain.md) — BaseIntegrationTest authz tests pass on open endpoints; slim context importing SecurityConfiguration
- [-DargLine logback override is ignored](wms2-dargline-logback-override-silently-ignored.md) — a level/config control via -DargLine is vacuous; set the logger level in-process
- [MockMvc failure dump leaks secrets into reports](mockmvc-failure-dump-leaks-secrets-into-reports.md) — a red IT on Flyway credential rows writes the value to failsafe-reports; print=NONE + boolean asserts
