---
name: findbyidforupdate-throws-at-the-lock-read-not-at-flush
description: "A @Lock(PESSIMISTIC_WRITE) re-read of an ALREADY-MANAGED entity throws StaleObjectStateException at the lock read itself, so entityManager.refresh on the next line is unreachable — and all 10 refresh sites in wms2 src/main are the wrong way round"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9d52a4a0-a665-4761-910e-aecb134394a3
  modified: 2026-09-09T17:04:21.768Z
---

In wms2-api, `findByIdForUpdate` (`@Lock(LockModeType.PESSIMISTIC_WRITE)` + full-entity JPQL) does
**not** merely lock. If the entity is already managed in the same persistence context at a stale
`@Version`, Hibernate's `EntityInitializerImpl.upgradeLockMode` → `checkVersion` throws
`StaleObjectStateException` **from inside the repository call**. `SELECT … FOR UPDATE` blocks until the
winner commits, then returns the *latest committed* row, so the loser's result set carries `v+1` while
its `EntityEntry` still holds `v`. The upgrade path fires because Hibernate treats any read entity as
`READ`-locked (level 1) and `PESSIMISTIC_WRITE` is level 5, so `lessThan` is true.

**Therefore `entityManager.refresh(x)` placed AFTER the lock read is unreachable in exactly the race it
is written for.** Measured 2026-09-09 on SBDEV-3244 at `origin/develop` @ `84083464`: all **10**
`.refresh(` sites in `src/main` (`StockunitBusinessService` ×8, `UnitloadBusinessService` ×2) sit
immediately after a `findByIdForUpdate`, and `entityManager.detach` appears nowhere in `src/main`. The
comment "Force refresh from DB to overwrite stale first-level cache entry" describes a protection that
cannot fire in the stale case.

**Why:** the whole idiom is backwards, so a fix modelled on the existing precedent inherits the bug.
Two exemptions worth knowing: `checkVersion` is skipped when the prior `EntityEntry` is already at
`WRITE` (a freshly persisted entity) or already at `PESSIMISTIC_WRITE` — those sites do not throw but
also do not refresh, so a comment promising "fresh state" there is silently false
(`PickingorderBusinessService:689` is one).

**How to apply:** never "fix" stale-entity-under-lock by adding a refresh after the locked read. The
shapes that work are `entityManager.refresh(x, LockModeType.PESSIMISTIC_WRITE)` *instead of* the
locked finder, `detach` *before* it, or never carrying the entity in — pass `Long` ids. The clean
in-repo reference is `MobilePickingService.processPick`, whose callers load outside a transaction so
entities arrive detached. Two instruments disagree by design here: the error message
`"Row was updated or deleted by another transaction (or unsaved-value mapping was incorrect)"` is
emitted by **nine** Hibernate throw sites including the flush path (`ModelMutationHelper`), so the
message alone cannot tell you the throw point — get a stack trace (the swallowed one prints under
`-Dlogging.level.<service>=DEBUG` where the code does `LOG.debug(..., e)`). Related:
[[wms2-requires-new-in-lock-holding-tx-deadlock]], [[wms2-lock-timeouts-are-inert-on-postgres]].

Corollary that matters for transaction-shape fixes: rollback-only on this failure is set by
Hibernate's own `ExceptionConverterImpl.rollbackIfNecessary` → `markForRollbackOnly()`, read back by
`JpaTransactionManager.isRollbackOnly()`. **No cross-bean `@Transactional` proxy is involved**, so
reshaping a callee's `rollbackFor` cannot fix an `UnexpectedRollbackException` of this kind.
