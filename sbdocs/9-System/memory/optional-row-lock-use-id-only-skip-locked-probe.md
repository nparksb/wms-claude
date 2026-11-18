---
name: optional-row-lock-use-id-only-skip-locked-probe
description: "When a code path has a fallback if a row is busy, probe with a native id-only FOR NO KEY UPDATE SKIP LOCKED before LockReads — LockReads waits then RETHROWS the lock timeout, failing the whole tx"
metadata:
  node_type: memory
  type: feedback
  originSessionId: f2a9488c-7592-4763-ae7c-34861c76dc41
  modified: 2026-11-05T13:15:13.814Z
---

If a wms2 path can do something else when a row is busy (e.g. SBDEV-2045 release joining an open cart, else minting a new picking order), do NOT lock it with `LockReads.forUpdate` / `findByIdForUpdate` alone. Those wait up to the tenant lock_timeout (3 s prod, 10 s in ITs) and then rethrow `CannotAcquireLockException`, so the fallback never runs and the whole transaction (e.g. the order's release) fails.

Pattern that worked (wms2-api PR #621): native `SELECT id FROM <t> WHERE id = :id FOR NO KEY UPDATE SKIP LOCKED` returning `Optional<Long>`. If it comes back empty, take the fallback. If it returns the id, call `LockReads.forUpdate` to refresh the entity, which does not wait because the lock is already held.

**Why:** found by the SBDEV-2045 security lane (L-1). Its mutant check: without the probe, the IT skip test times out.

**How to apply:**
- **Id-only, not the entity.** If the row is already managed from an unlocked read, an entity-returning lock hands back the stale instance. That is the SBDEV-3286 trap, which `LockReadRail` flags.
- **`NO KEY UPDATE`, not `FOR UPDATE`.** It is the strength Hibernate's PESSIMISTIC_WRITE takes on PostgreSQL, and it doesn't block child-row FK inserts. `UnitloadRepository.lockIdForUpdateSkipLocked` uses a full `FOR UPDATE` on purpose.
- **SKIP LOCKED, never NOWAIT.** NOWAIT's 55P03 aborts the transaction.
- **Fix the census grep.** `LockTimeoutHibernateJpaDialect`'s census needs `FOR (NO KEY )?UPDATE`; a plain `FOR UPDATE` grep misses these queries.
- Related: [[wms2-lock-timeouts-are-inert-on-postgres]], [[findbyidforupdate-throws-at-the-lock-read-not-at-flush]], [[race-it-worker-needs-tenantcontext-or-pin-is-vacuous]].
