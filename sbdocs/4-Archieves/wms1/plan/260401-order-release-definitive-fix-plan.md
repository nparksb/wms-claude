# Debug Plan: Order Release Definitive Fix — Pessimistic Lock

**Date:** 2026-04-01
**Priority:** Critical
**Reporter:** Production log (recurring issue)

---

## 1. Problem Summary

`ReleaseOrderJobService.releaseOrder()` continues to throw `ObjectOptimisticLockingFailureException` on `Customerorder` despite the `entityManager.refresh()` fix. The error now occurs at `pickingorderRepository.getNextId()` (line 465) — a native `select nextval('seqentities')` query — which triggers Hibernate auto-flush. The auto-flush attempts to re-flush the managed Customerorder entity whose version has been incremented by a concurrent transaction (e.g., `closeBOL`, web UI) since the last successful save/flush within this transaction.

## 2. Root Cause: Why `entityManager.refresh()` Before Save Points Is Insufficient

The `refresh()` approach only narrows the stale window around explicit `save()` calls. But the entity remains **managed** in the persistence context after the save. Hibernate's AUTO flush mode re-flushes ALL dirty-or-recently-flushed entities before every native query. The Customerorder entity gets its version from the last `refresh()` or `save()` within this transaction, but a concurrent writer can increment the DB version at any time between flush points.

**Timeline of the failure:**

```
Line 183: entityManager.refresh(order)  → gets version M from DB
Line 184: order.setMarkasvisited(true)  → entity is dirty
Line 185: save(order)                   → entity queued for flush (NOT immediately flushed)
Line 225: getStockUnitAvailable()       → native query → AUTO-FLUSH → flushes order
                                          → UPDATE ... WHERE version=M → SUCCESS → version=M+1
 ... long processing window (hundreds of ms) ...
Line 465: getNextId()                   → native query → AUTO-FLUSH
                                          → Hibernate checks: is order dirty? No.
                                          → But entity IS in persistence context with version=M+1
                                          → If concurrent writer set DB to version=M+2 since line 225...
                                          → Hibernate detects version mismatch → StaleObjectStateException
```

**Wait — Hibernate doesn't re-flush clean entities.** So why does line 465 fail?

The answer is subtler: after the flush at line 225, the entity version in the persistence context is M+1. The entity is "clean" (not dirty). But Hibernate's optimistic lock check happens at **commit time** when the transaction ends. However, `getNextId()` is itself a repository call that goes through the Spring Data proxy with `PersistenceExceptionTranslationInterceptor`. The auto-flush before the native query CAN re-check managed entities if there are other dirty entities in the session (e.g., `CustomerorderPosition` entities modified in the first loop at lines 126, 135, etc. that were never explicitly saved).

When those dirty `CustomerorderPosition` entities are flushed, Hibernate walks the entire persistence context to determine what needs flushing, and if the `Customerorder` entity's snapshot doesn't match what was last read, it throws.

**The real fix: prevent concurrent modification entirely with a pessimistic lock.**

## 3. Options With Confidence Levels

### Option A: Pessimistic Lock on Load (RECOMMENDED) — Confidence: 95%

Replace `findById` with `findByIdForUpdate` at line 84 to acquire a `SELECT ... FOR UPDATE` row lock when loading the Customerorder. This prevents ANY concurrent transaction from modifying the row until this transaction completes.

```java
// Line 84: Change from
Customerorder order = customerorderRepository.findById(orderId).get();
// To
Customerorder order = customerorderRepository.findByIdForUpdate(orderId)
    .orElseThrow(() -> new FacadeException("Order not found: " + orderId));
```

**Why this is definitive:**
- No concurrent writer can increment the version while the lock is held
- Auto-flush at any native query point will always see the correct version
- Single-line change, no restructuring needed
- The existing `entityManager.refresh()` calls become unnecessary (but harmless to keep)

**Lock duration concern (addressed):**
- Lock is per-order, not a table lock — other orders process in parallel
- The transaction is `REQUIRES_NEW` — scoped to this single order
- The order being released is in RAW/RAW_ON_HOLD state — not actively used by pickers
- UI operations on the SAME order during release are extremely unlikely and would be blocked briefly
- Lock held for ~100ms-2s per order — acceptable for a cron job

**Risk:** If a UI operation targets the same order concurrently, it will block until the release completes (or timeout). This is acceptable because:
1. Order release operates on RAW orders — users rarely modify these simultaneously
2. A brief block is better than a failed release that delays fulfillment

### Option B: Detach Order Immediately After Load — Confidence: 85%

Detach the Customerorder from the persistence context right after loading. Auto-flushes will never touch it. Re-fetch fresh before each save point.

```java
// Line 84-85:
Customerorder order = customerorderRepository.findById(orderId).get();
entityManager.detach(order); // remove from persistence context

// Before each save point, re-attach with fresh version:
order = customerorderRepository.findById(orderId).get(); // fresh from DB (not cached, because detached)
order.setMarkasvisited(true);
order = customerorderRepository.save(order);
entityManager.detach(order); // detach again immediately after save
```

**Why confidence is lower:**
- More complex — must detach/re-attach at every save point
- `findById()` after detach WILL hit the DB (entity not in L1 cache), but the window between re-fetch and save is still non-zero
- Fragile: any code that accidentally references the detached `order` variable and modifies it could cause `merge()` issues

### Option C: Set FlushMode.COMMIT for the Session — Confidence: 85%

Disable auto-flush before native queries for this transaction only.

```java
// At method start:
Session session = entityManager.unwrap(Session.class);
FlushMode originalMode = session.getHibernateFlushMode();
session.setHibernateFlushMode(FlushMode.COMMIT);
try {
    // ... entire method body ...
} finally {
    session.setHibernateFlushMode(originalMode);
}
```

**Why confidence is lower:**
- Native queries may read stale data for entities modified in this transaction (e.g., `CustomerorderPosition` states set in the first loop but not yet flushed)
- Introduces Hibernate-specific API dependency
- The stale-read risk is low for this specific method (native queries target stock/unitload tables, not customerorder), but it's fragile for future changes

## 4. Recommendation

**Option A (pessimistic lock)** is the definitive fix. It eliminates the race condition entirely with a single-line change. The lock duration concern is a non-issue in practice for this cron job.

Additionally, the `entityManager.refresh()` calls we added earlier should be **removed** — they add complexity without benefit when the pessimistic lock is in place (no concurrent writer can change the version).

## 5. Task Checklist

- [x] Change `findById(orderId)` to `findByIdForUpdate(orderId)` at line 84 of `ReleaseOrderJobService.java` ✓ Implemented 2026-04-01
- [x] Remove `entityManager.refresh(order)` calls (4 occurrences) ✓ Implemented 2026-04-01
- [x] Remove `EntityManager` import and `@PersistenceContext` injection (no other usage) ✓ Implemented 2026-04-01
- [x] Update `ReleaseOrderJobServiceUnitTest` — changed 24 `findById` mocks to `findByIdForUpdate`, removed `EntityManager` mock ✓ Implemented 2026-04-01
- [x] Full test suite: 1603 tests, 0 failures, 2 pre-existing errors (unrelated), 0 skipped ✓ Verified 2026-04-01
- [ ] Verify in staging

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java` | `findById` → `findByIdForUpdate` (pessimistic lock), removed 4x `entityManager.refresh()`, removed `EntityManager` import/injection |
| `src/test/java/net/aim_ai/wms/unit/service/job/ReleaseOrderJobServiceUnitTest.java` | 24x `findById` → `findByIdForUpdate` mocks, removed `EntityManager` mock/import |
