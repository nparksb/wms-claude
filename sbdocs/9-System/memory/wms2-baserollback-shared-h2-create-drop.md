---
name: wms2-baserollback-shared-h2-create-drop
description: "BaseRollbackIntegrationTest's ~30 subclasses share two fixed H2 DB names with create-drop across SEPARATE Spring contexts — adding any subclass can redden an untouched sibling in CI"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0a3c8a18-078e-4915-af56-c67bd7a21d3d
  modified: 2026-09-15T20:13:48.090Z
---

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
