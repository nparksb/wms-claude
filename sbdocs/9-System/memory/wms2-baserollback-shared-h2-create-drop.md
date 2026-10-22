---
name: wms2-baserollback-shared-h2-create-drop
description: "FIXED in BOTH H2 lanes: rollback lane SBDEV-1581 #537, integration profile SBDEV-3843 #544 (initializer via test META-INF/spring.factories; Boot 3.5 ignores context.initializer.classes)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0a3c8a18-078e-4915-af56-c67bd7a21d3d
  modified: 2026-09-15T20:13:48.090Z
---

**⚠ STATUS 2026-10-19: fixed for `BaseRollbackIntegrationTest` by SBDEV-1581** — `RollbackDatabaseNameInitializer`
publishes a per-context id embedded in both URLs, so an evicted context drops only its own database. Forced-eviction
proof (all 40 subclasses, `-Dspring.test.context.cache.maxSize=1`): develop `8c9960eb` 159 run / **78 errors in 14
classes**; with the fix 159 / 0. It went red on develop twice in a row right after PR #533 added PG-lane contexts
(runs 39283352255, 39291648188, attempt 1). Only `landlord.datasource.jdbc-url` is live (DataSourceAutoConfiguration
is excluded). **Also FIXED, SBDEV-3843 #544 (on dev 2026-10-20, d44d79ae):** the `wms_integration` H2 lane (was dormant: forced evictions gave 73 errors + 1 failure in 33 of 53 classes; 0 CI hits in 200 runs). TRAP hit there: Spring Boot 3.5 has no DelegatingApplicationContextInitializer, so `context.initializer.classes` is silently ignored and an unresolved `${…}` URL placeholder becomes a literal SHARED name; register the initializer in src/test/resources/META-INF/spring.factories instead, and assert it with a live-context test, not just a properties pin. Lane (`BaseIntegrationTest`, `BaseRepositoryIntegrationTest`,
`BasePerformanceTest`) has the same fixed-name create-drop shape — proposed on SBDEV-1581. Everything below is the
pre-fix history.


`src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java` pins **fixed** H2 database
names — `jdbc:h2:mem:rollback_tenant` and `rollback_landlord` — with
`spring.jpa.hibernate.ddl-auto=create-drop`. All ~30 subclasses share those names, **but not a Spring
context**: the test context cache keys on the bean-override set, so subclasses with different
`@MockitoBean` declarations get *separate* contexts pointing at the *same* database.

**Evicting any one of those contexts runs Hibernate's drop and empties the database out from under
every other context still cached and still using it.** The next class to run dies with
`Table "los_sequencenumber" not found (this database is empty)` or `Sequence "seqentities" not found`
— **in a class nobody touched**, so the apparent cause is whichever test was added last.

**Reproduce deterministically** with `-Dspring.test.context.cache.maxSize=1` (forces an eviction at
every context switch). Measured 2026-09-15 on unmodified `origin/develop` `9e294d4b`:
`mvn verify -Dit.test='CancelOrderRollbackIntegrationTest,AdviceServiceRollbackIntegrationTest' -Dtest=ZzzNone -Dspring.test.context.cache.maxSize=1`
→ `CancelOrderRollbackIntegrationTest` red. **The bug is on develop today and simply is not tripped.**

It bit SBDEV-3363 PR #362: a new subclass whose bean-override set happened to *match*
`AdviceServiceRollbackIntegrationTest`'s joined that context and pulled its creation from late in the
failsafe lane to position ~11, leaving it cached and eviction-eligible across far more of the run.
Local `clean verify` was green; CI was red — ordering, not logic.

**Adding a subclass? Give it private database names**, overriding both URLs in its own
`@TestPropertySource`. That confines its `create-drop` to its own schema and leaves the shared pool at
develop's topology.

⚠ **`ddl-auto=update` on the base is NOT the fix**, though it passes the forced-eviction repro.
`create-drop` is *also* the per-context DATA reset, and siblings assert on an empty table
(`SkuRestControllerAtomicityIntegrationTest` — "must leave the itemdata table empty";
`CancellationReversalLockClearIntegrationTest` — "Query did not return a unique result: 2 results").
Measured: the full suite goes from 3 errors to **3 failures + 6 errors**. Strictly worse.

The real fix is per-class database names on the base class — unowned as of 2026-09-15. Related:
[[wms2-testcontainers-reuse-breaks-an-it]], [[wms2-test-suite-baseline-and-h2-verdict]],
[[concurrent-maven-one-worktree-false-reds]].
