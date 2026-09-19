---
name: wms2-repository-tests-commit-they-do-not-roll-back
description: BaseRepositoryIntegrationTest's bare @Transactional rolls back the landlord manager while the repositories commit on the tenant one, so every repo-test row persists in the shared H2
metadata:
  type: project
---

**In `v2/wms2-api`, rows written by a `BaseRepositoryIntegrationTest` subclass are COMMITTED and never
rolled back.** Found 2026-09-06 on SBDEV-3241 by a review lane; the mechanism is pre-existing and
affects **all 32 subclasses**.

The chain:

1. `common/base/BaseRepositoryIntegrationTest` is annotated bare `@Transactional`, no qualifier.
2. There is no bean named `transactionManager`, so Spring falls back to the `@Primary`
   `PlatformTransactionManager` — the **landlord** one (`LandlordDatabaseConfig`).
3. But `net.aim_ai.wms.repo.jpa` is bound by `TenantDatabaseConfig` with
   `transactionManagerRef = "tenantTransactionManager"`. `SimpleJpaRepository.save` is
   `@Transactional`, finds no tenant resource bound, so `PROPAGATION_REQUIRED` starts a **new**
   transaction on a **separate connection** and **commits** it.

The test-method rollback happens on the landlord unit and does not touch those rows. H2 is
`jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1`, so they survive for the life of the Spring context
and are visible to every class sharing it. Corroboration that this is reality and not theory:
`integration/repository/CyclecountRepositoryIntegrationTest` carries a `@BeforeEach cleanupTestData()`
that deletes leftover `CC-TEST*` rows — dead weight if rollback worked.

**How to apply:** in any repo test, assert **by id** (`contains(x.getId())` / `doesNotContain(...)`),
never `isEmpty()` / `hasSize(n)` / `hasSize(0)` — those are order- and history-dependent and will pass
or fail on what earlier classes left behind. Also: a bare `@PersistenceContext` injects the **landlord**
`EntityManager` (it is `@Primary`), so `flush()` on tenant entities silently does nothing; the four
existing IT classes that inject one all write `@PersistenceContext(unitName = "tenant")`. No flush is
needed anyway — the rows are already committed.

The real fix is `@Transactional("tenantTransactionManager")` on the base class plus a regression pass
over all 32 subclasses. Not done; recorded on SBDEV-3241. Related:
[[green-tests-that-prove-nothing]], [[un-suppressing-a-test-can-create-a-false-green]].

**FIXED 2026-09-07 on branch `bugfix/SBDEV-3242-repo-test-rollback-tx-manager`** —
`@Transactional("tenantTransactionManager")` on `BaseRepositoryIntegrationTest`, pinned by
`BaseRepositoryIntegrationTestRollbackContractTest` and an ArchUnit rail. Two siblings still carry the
bare annotation: `BasePostgresIntegrationTest` (SBDEV-3239 AC-1 owns it) and `BaseIntegrationTest` —
the latter deferred because **`MessageCleanupBatchServiceIT` asserts on the NAME of the transaction the
proxy opens** and runs in neither Maven lane, so the risk cannot be measured.

⚠ **Two people already hit this and worked around it locally instead of fixing the base class**, which
is why it survived: `CyclecountRepositoryIntegrationTest` grew a `@BeforeEach` deleting leftover
`CC-TEST*` rows, and `BillofladingServiceFinishTransferIT:52-55` carries a comment diagnosing it
*exactly* — "Override BaseIntegrationTest's bare @Transactional which defaults to the @Primary
landlordTransactionManager … without this override, fixture saves leak across tests". A local override
that fixes one class and leaves the base is the signature of this defect; treat either as a lead.

**Also:** fixing the rollback can *silently disarm* tests that were relying on the leak. Seeds are now
uncommitted in the outer transaction, so a service annotated `REQUIRES_NEW` cannot see them —
`MessageRepositoryIntegrationTest`'s two `deleteOnce` counts fall to 0 while its loose assertions
(`isGreaterThanOrEqualTo(0)`, `isLessThanOrEqualTo(2)`) stay green. An A/B on suite results cannot see
this. Sweep any test whose subject is `REQUIRES_NEW`.

