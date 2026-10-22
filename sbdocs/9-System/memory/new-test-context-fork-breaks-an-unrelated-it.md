---
name: new-test-context-fork-breaks-an-unrelated-it
description: "Adding a context-forking test to BaseRollbackIntegrationTest breaks an UNRELATED IT on CI with \"Table ... not found (this database is empty)\" — green locally, red on CI"
metadata:
  node_type: memory
  type: project
  originSessionId: 4c9d2822-5ef4-4097-8a6f-3924c5311b5a
  modified: 2026-10-07T21:24:05.842Z
---

**39 classes extend `BaseRollbackIntegrationTest`, and they all share ONE in-memory database**
(`jdbc:h2:mem:rollback_tenant`) with `spring.jpa.hibernate.ddl-auto=create-drop`. Spring's test
context cache is bounded (default 32).

Any `@Import`, `@TestPropertySource`, `@TestConfiguration`, or a differing `@MockitoBean` set
**changes the context cache key**. So a new test class can add a context, force an eviction — and the
**evicted** context's `create-drop` then DROPS the shared schema out from under a class that is still
cached. That class dies with:

```
Table "outbox_message" not found (this database is empty)
```

**It fails on CI and passes locally**, because the triggering order is the suite ordering. Measured on
SBDEV-3674 (2026-10-07): `outbox_message not found` appeared **45x in each CI log and 0x in every
local run**, across three attempts. A full local `clean verify` was green every time.

**How to apply:**

1. **A new `BaseRollbackIntegrationTest` subclass should add NO new context.** Copy the `@MockitoBean`
   set of an existing sibling exactly — `MessageServiceSingleRowIT` (`HttpRestService`,
   `SyspropService`, `BasicService`) is a good anchor — and avoid `@Import` / `@TestPropertySource`
   / `@TestConfiguration` entirely.
2. **Need a real transaction? Use `new TransactionTemplate(tenantTransactionManager)`**, not a
   `@TestConfiguration` probe bean. `MoveCronConcurrencyIT` is the precedent. A probe bean forks the
   context; `TransactionTemplate` does not. Register an `afterCommit` synchronization inside the
   template callback to exercise that path.
3. ⚠ **Giving your class its own database does NOT fix it.** Tried on SBDEV-3674 (`d95559b5`) and CI
   failed identically. Isolation does not reduce the *number* of contexts, so the eviction your class
   causes in OTHERS is unchanged. **The damage is the eviction, not the database.** This is the one
   wrong turn to skip.
3b. **Even an IDENTICAL `@MockitoBean` set can break a sibling** (SBDEV-3804, 2026-10-16): the new class joined
   an existing context but ran EARLIER in failsafe's filesystem order, so it created that context before another
   context's eviction dropped the shared schema; `CancellationReversalDestinationIntegrationTest` (9/9) then
   inherited the emptied DB. **The fix that worked: make it a `@Nested` class inside an existing sibling that
   shares the context** (no bean override of its own). It then adds no context AND runs wherever its host runs,
   so neither the context set nor creation order changes. Full suite went 9 errors → 0.
4. **Verify the mechanism, not just a green.** Context-creation markers that DO NOT appear in this
   repo's test log: `Started StartApplication`, `Initialized JPA EntityManagerFactory`,
   `Building JPA container EntityManagerFactory`, `Root WebApplicationContext` — all return **0**, so
   `0 == 0` reads as confirmation while measuring nothing. The one that registers is
   `HikariPool-.*Start completed` (199 forked → 181 de-forked). CI wall-clock also moves: 17m → 12m51s.

**The underlying fragility is pre-existing and unfixed**: 39 classes, one shared `create-drop` schema,
a bounded cache. Any future context-forking test can set it off, and the failure surfaces in an
unrelated class with a message that points at the victim rather than the cause. The direct remedy
would be raising `spring.test.context.cache.maxSize` or giving the base class a per-class schema;
neither was in scope for SBDEV-3674.

Related: [[wms2-has-two-full-context-test-lanes]], [[wms2-test-resources-shadows-main-application-properties]],
[[green-tests-that-prove-nothing]].
