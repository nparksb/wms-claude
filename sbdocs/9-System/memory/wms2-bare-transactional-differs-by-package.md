---
name: wms2-bare-transactional-differs-by-package
description: A bare @Transactional resolves to the LANDLORD manager in net.aim_ai.wms.service but to the TENANT manager in net.aim_ai.wms.repo.jpa — the two packages have opposite defaults
metadata:
  type: reference
---

The rule "a bare `@Transactional` silently routes tenant writes to the `@Primary` landlord manager" is
asserted in five `src/main` javadocs, in `CLAUDE.md`, and in the architecture docs. **It is true of a
`@Service` and FALSE of a Spring Data repository interface.**

Spring Data's `TransactionalRepositoryProxyPostProcessor` builds each repository proxy's
`TransactionInterceptor` with `transactionManagerBeanName` taken from
`@EnableJpaRepositories(transactionManagerRef = ...)`, and `TransactionAspectSupport.determineTransactionManager`
falls back to that name whenever the annotation carries no qualifier. So in `net.aim_ai.wms.repo.jpa`
a bare `@Transactional` defaults to **`tenantTransactionManager`**.

**Measured on SBDEV-3250, two instruments** — after three review passes (a caller audit, a claim audit
and a code review) all asserted the opposite and **none of them ran it**:
1. The interceptor on every `repo.jpa` proxy reports `transactionManagerBeanName = "tenantTransactionManager"`.
2. The six bare-`@Transactional` bulk `@Modifying` methods **execute successfully**. They run through the
   tenant `EntityManager` and `Query.executeUpdate()` requires an active transaction on *that* EM — under
   a landlord-managed transaction they would throw `TransactionRequiredException`.

**Consequences:**
- **Do not widen `TransactionManagerArchTest` (which imports only `net.aim_ai.wms.service`) to `repo.jpa`.**
  It would flag six correct methods.
- **The real hazard is `transactionManagerRef` itself.** Delete that one attribute from
  `TenantDatabaseConfig`'s `@EnableJpaRepositories` and all six silently move to the landlord manager —
  no annotation changes, no ArchUnit rule notices. Pinned by
  `TenantRepositoryTransactionManagerContextTest`.
- **`ClientRepository` is double-proxied**: its `@CacheEvict` wraps the Spring Data proxy in a cache proxy
  whose only advice is `CacheInterceptor`. A single-level `getAdvisors()` scan reports "no
  TransactionInterceptor" for it and nothing else — wrong, and specific enough to look like a finding.
  Walk the chain via `getTargetSource().getTarget()`.

Related: [[wms2-lock-timeouts-are-inert-on-postgres]], [[advertised-capability-is-not-exploitable-capability]],
[[a-guard-fences-the-mechanism-you-aimed-at]].
