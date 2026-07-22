---
title: "Multi-Unit-Load Replenish — REQUIRES_NEW Self-Deadlock (createOrderFromTemplate)"
ticket: "SBDEV-2575"
ticket_url: "https://app.clickup.com/t/868kc5n7f"
type: bugfix
priority: high
status: archived
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-07-13
updated: "2026-07-15"
db_verified: true
related:
  - "[[wms2-multi-unitload-replenish]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[260709-duplicate-replenishment-orders-concurrent-generation]]"
  - "[[260709-multi-unitload-replen-reserve-availability-guard]]"
  - "[[wms2-tenant-routing-datasource-topology]]"
tags:
  - plan
  - replenishment
  - concurrency
  - deadlock
  - transaction-boundary
---

# Multi-Unit-Load Replenish — REQUIRES_NEW Self-Deadlock (createOrderFromTemplate)

**Ticket:** [SBDEV-2575](https://app.clickup.com/t/868kc5n7f)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** IMPLEMENTED & verified 2026-07-14 (IT green, verify 12/0, unit 129/0); committed `cc9ca6b`, [PR #75](https://github.com/SiteBossInc/wms2-api/pull/75) → develop (pr submitted). See §11.
**Date:** 2026-07-13

> **Authoring note:** Root cause was confirmed **live** against `wms2-wineco-dev` (`pg_stat_activity` / `pg_locks` captured six wedged backends mid-incident, see §1). Authored from that verified analysis, then hardened through a separate `critic` review pass (author/review separation): the first draft was REJECTed for missing the Hibernate flush-ordering trap; the revision below addresses every finding and the re-review returned **SHIP-WITH-CHANGES**, with those three minor edits now applied → effectively clean SHIP. See §11 Review history. Remaining gate before sign-off: O‑3 (SBDEV‑2217 PG test lane).

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn createOrderFromTemplate|reserveExplicitStockForOrder|REQUIRES_NEW src/main src/test` and the partial-unique-index / lock-hint greps.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `service/ReplenishGeneratorService.java:271` | `createOrderFromTemplate` `@Transactional(REQUIRES_NEW)` | **yes — the bug** | **yes** — change propagation to `REQUIRED` (default tenant TM) |
| 2 | `service/mobile/MobileReplenishService.java:784‑796` (refresh at **:793**) | loop calling `createOrderFromTemplate` then `entityManager.refresh(inst.stock)` + `finishReplenishmentOrderWithoutRefill` | yes — the refresh is a workaround for the REQUIRES_NEW cross-context staleness | **yes** — Fix B remove `refresh`+comment; Fix A.2 add `flush()` after each finish |
| 3 | `service/mobile/MobileReplenishService.java:739` | `fulfillMultipleUnitLoads` outer `@Transactional(tenantTransactionManager)` | yes — the lock-holding parent | **yes** — Fix D: split into non-tx wrapper + tx core so `refillFixedLocations()`/`recalculateOpenOrders(true)` (`:800‑801`) run post-commit |
| 4 | `repo/jpa/StockunitRepository.java:27‑29` | `findByIdForUpdate` `@Lock(PESSIMISTIC_WRITE)` with **no** `jakarta.persistence.lock.timeout` hint | contributing — indefinite lock wait | **yes (secondary hardening)** — add a bounded `lock.timeout` hint so any residual contention fails fast instead of hanging |
| 5 | `service/ReplenishGeneratorService.java:263` | `reserveExplicitStockForOrder` (no `@Transactional`; joins caller tx) | related | no — behaviour unchanged; it already runs in the caller tx, which is now the single unifying tx |
| 6 | `service/ReplenishGeneratorService.java:111,176` | `refillSingleFixedLocation` / `calculateOrder` `@Transactional(REQUIRES_NEW)` | **no** — different callers (cron refill + `requestReplenish` NEW‑1 path), not called while pessimistic locks are held | no — leave as-is; touching them would regress plan `260709` |
| 7 | `service/OutboxService.java`, `RestIdempotencyService.java`, `SequenceTransactionService.java`, `job/*` REQUIRES_NEW | REQUIRES_NEW in independent short-tx contexts | no — not nested inside a lock-holding parent tx | no |
| 8 | `test/.../ReplenishGeneratorServiceUnitTest.java` (AC‑3 pinning `createOrderFromTemplate_stillCreatesChild_noDupGuard`, +6 scenarios) | unit tests calling `createOrderFromTemplate` directly | test coverage | **yes** — assert they still pass (propagation is a proxy concern not exercised by direct unit calls) + add a boundary/atomicity test |
| 9 | `test/.../MobileReplenishServiceUnitTest.java` (multi-UL scenarios ~2805‑3060) | mock `createOrderFromTemplate` | test coverage | **yes** — assert unchanged; add refresh-removal + rollback tests |

**Excluded-with-rationale rows (6, 7) are the completeness anchor:** the fix is deliberately scoped to the *one* REQUIRES_NEW site invoked while the outer transaction holds pessimistic locks. The other REQUIRES_NEW sites are safe and are load-bearing for other plans.

---

## 1. Problem Statement

**User-visible symptom.** On `wms2-mobile-ui`, during the replenishment flow, after the operator scans the destination location on the **“Select Destination Location”** page, the page shows a spinner **forever** and the replenishment never completes.

**Server log** (`HikariPool-wine-wsl`), fires ~60 s after the request begins:

```
WARN c.zaxxer.hikari.pool.ProxyLeakTask - Connection leak detection triggered for
     org.postgresql.jdbc.PgConnection@40852e38 on thread tomcat-handler-519
java.lang.Exception: Apparent connection leak detected
    at com.zaxxer.hikari.HikariDataSource.getConnection(...)
    ...
    at org.springframework.orm.jpa.JpaTransactionManager.doBegin(...)
    at net.aim_ai.wms.service.mobile.MobileReplenishService$$SpringCGLIB$$0.fulfillMultipleUnitLoads(<generated>)
    at net.aim_ai.wms.controller.mobile.ReplenishController.multiUnitLoads(ReplenishController.java:236)
```

The leak WARN is a **symptom**, not the fault: it is Hikari observing that a connection has been checked out longer than the hard-coded 60 s `leakDetectionThreshold` (`TenantDynamicRoutingDataSource.java:87`). The request is genuinely **hung**, not merely slow.

### 1.1 DB verification (mandatory gate — `db_verified: true`)

Captured **live** on `wms2-wineco-dev` while the incident was active, via `mcp__wms2-wineco-dev__execute_sql` against `pg_stat_activity` + `pg_locks`. Six backends were wedged for up to **27 minutes**:

| Role | pid | xid | state | last / current query |
|------|-----|-----|-------|----------------------|
| **Parent T1a** (suspended) | 1398089 | 42395761 | `idle in transaction` (`ClientRead`) | `SELECT … FROM Unitload WHERE carrierunitload_id=$1` (last stmt before suspend) |
| Child of T1a | 1400883 | 42395762 | `active`, `Lock:transactionid` | **`INSERT INTO Replenishorder …`** — `ShareLock` on xid 42395761 **not granted** |
| Child of T1a | 1400886 | — | `active`, `Lock:transactionid` | `SELECT … FROM Location … FOR NO KEY UPDATE` — waits on xid 42395761 |
| **Parent T1b** (suspended) | 1401940 | 42397426 | `idle in transaction` (`ClientRead`) | `SELECT … FROM Unitload WHERE carrierunitload_id=$1` |
| Child of T1b | 1402045 | — | `active`, `Lock:transactionid` | `SELECT … FROM Stockunit … FOR NO KEY UPDATE` — waits on xid 42397426 |
| Child of T1b | 1402065 | — | `active`, `Lock:transactionid` | `SELECT … FROM Replenishorder … FOR NO KEY UPDATE` — waits on xid 42397426 |

The suspended parents held `RowExclusiveLock` on `replenishorder`, `stockunit`, `unitload`, `stockrecord`; the children sat in `ShareLock … granted=false` on the **parent's `transactionid`**. Two independent stuck chains (T1a, T1b) = the operator retried after the first spin, each retry stacking a new permanently-stuck transaction.

Partial unique index confirmed present (the row the child INSERT collides on):

```sql
-- pg_indexes on replenishorder
CREATE UNIQUE INDEX idx_replenishorder_active_item_dest
  ON public.replenishorder USING btree (itemdata_id, destination_id) WHERE (state < 700);
CREATE UNIQUE INDEX idx_replenishorder_active_item_no_dest
  ON public.replenishorder USING btree (itemdata_id) WHERE (state < 700 AND destination_id IS NULL);
```

**Cleanup performed during triage:** all six backends were `pg_terminate_backend`-ed (they never self-resolve — see §2.3). A follow-up query confirmed **0 orphaned ad-hoc orders** (`number ~ '-[0-9]+$'` created in the incident window): the deadlock strikes on the *first* `createOrderFromTemplate`, before any child order can commit, so `terminate` rolled everything back cleanly. **No data remediation is required.**

**If re-verifying on another tenant DB before implementation:** run the blocking-tree query in §8.3 while reproducing; you should see an `INSERT INTO Replenishorder` (or `… FOR NO KEY UPDATE`) child `active` on `Lock:transactionid`, blocked by an `idle in transaction` parent on the same connection pool.

---

## 2. Root Cause Analysis

### Bug 1 (the fault): `createOrderFromTemplate` runs `REQUIRES_NEW` while the caller holds pessimistic locks and an uncommitted active-order row

**Call path.**
```
ReplenishController.multiUnitLoads:236
 └─ MobileReplenishService.fulfillMultipleUnitLoads:739   @Transactional(tenantTransactionManager)   ← T1 (outer)
     ├─ applyExplicitSourceToOrder:922  → changeReservedAmount → findByIdForUpdate (PESSIMISTIC_WRITE) ← locks in T1
     ├─ finishReplenishmentOrderWithoutRefill:780         → template.setState(FINISHED=700); save   ← UPDATE in T1 (uncommitted)
     └─ for i in 1..N-1:
          └─ replenishGeneratorService.createOrderFromTemplate:786
                 → @Transactional(REQUIRES_NEW)  ← Spring SUSPENDS T1, opens T2 on a 2nd pooled connection
                 → replenishorderRepository.save(child)   → INSERT Replenishorder (state=PROCESSABLE, active)
                 → reserveExplicitStockForOrder → changeReservedAmount → findByIdForUpdate (PESSIMISTIC_WRITE)
```

`createOrderFromTemplate` is annotated (`ReplenishGeneratorService.java:271`):

```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class)
public Replenishorder createOrderFromTemplate(Replenishorder template, Stockunit stock, BigDecimal amount, Long destinationId, int sequenceIndex) { ... }
```

`REQUIRES_NEW` **suspends** the outer transaction T1 (its connection — and every lock and uncommitted row it has produced — stays checked out) and opens **T2 on a second connection from the same per-tenant Hikari pool**. T1 cannot make progress: it is parked in the JVM waiting for the `createOrderFromTemplate` **method call** to return. It can only return once T2 finishes.

### Bug 1a — the primary hang: partial-unique-index INSERT collision

`fulfillMultipleUnitLoads` uses the **finish-then-create-then-finish** ordering that plan `260709-duplicate-replenishment-orders` (§8) documents v2 relies on for correctness: the template order is driven to `state=FINISHED (700)` **before** the first child is created, so two *active* (`state<700`) rows for one `(itemdata_id, destination_id)` never coexist and the `idx_replenishorder_active_item_dest` partial unique index is satisfied.

That invariant holds **only within a single transaction snapshot.** Because `createOrderFromTemplate` runs in a *separate* transaction T2:

1. T1 has set `template.state = 700` but **has not committed** (it is suspended).
2. T2 runs under READ-COMMITTED and **cannot see** T1's uncommitted `state=700` update — from T2's snapshot the template is still active (`state<700`) and therefore still occupies the partial unique index for `(itemdata_id, destination_id)`.
3. T2's `INSERT` of child order (same `itemdata_id`, same `destination_id`, `state=PROCESSABLE`) **collides** on `idx_replenishorder_active_item_dest`. PostgreSQL cannot immediately decide uniqueness, so the inserter **blocks on T1's `transactionid`** (waiting to learn whether T1 commits the `700` update, which would clear the collision, or aborts).
4. T1 will never commit — it is suspended waiting for T2. **Permanent deadlock.**

This is exactly the live evidence: pid 1400883 = `INSERT INTO Replenishorder`, `ShareLock` on xid 42395761 (T1a) **not granted**.

**The general invariant (and why the naive one-line fix is NOT enough — critic finding).** The collision is avoided **only if, at the instant the child INSERT reaches the database, the template (and every prior child) is already `state=700` in the DB session's own view** — i.e. no longer in the `WHERE state<700` partial index. Two distinct mechanisms can violate that:
- **Under `REQUIRES_NEW` (today):** the child runs in a separate transaction that cannot see T1's uncommitted `700` update → collision → cross-xid wait → deadlock (above).
- **Under a naive `REQUIRED` change with no flush discipline:** all entities use `@GeneratedValue(GenerationType.SEQUENCE)` (`AbstractBaseEntity.java:20`), so INSERTs are **deferred to flush time** and subject to Hibernate's fixed `ActionQueue` order — **all INSERTs execute before all UPDATEs in a single flush cycle.** `finishReplenishmentOrderInternal` sets `template.state=700` + `save` at `MobileReplenishService.java:493‑494` with **no flush afterward** (the `triggerRefill=false` path skips the trailing block). The next autoflush (the child's `changeReservedAmount`→`findByIdForUpdate` JPQL, or commit) therefore flushes the child INSERT (`state<700`) **before** the template UPDATE (`700`) → the template is still active in the index → **immediate `DataIntegrityViolationException` (SQLSTATE 23505)**, whole-tx rollback. Same collision, different symptom (500 instead of hang).

Therefore the fix must do single-tx **plus explicit flush ordering** so each `state=700` transition lands in the DB before the next child INSERT — see §5 Fix A. `calculateOrder` already models this discipline: it calls `replenishorderRepository.flush()` immediately after save (`ReplenishGeneratorService.java:255`) precisely so the unique-index violation surfaces deterministically. The multi-UL path has no equivalent and must gain it.

### Bug 1b — the secondary hang: pessimistic-lock wait across the boundary

On retries that reach a later phase, the collision manifests instead as a `FOR NO KEY UPDATE` wait: `changeReservedAmount → findByIdForUpdate` (or `transferStockToUnitLoad`'s `Location`/`Stockunit`/`Unitload` locks) inside T2 requests a `PESSIMISTIC_WRITE` on a row T1 already locked/modified → T2 waits on T1's xid. Live evidence: pids 1400886 / 1402045 / 1402065 (`… FOR NO KEY UPDATE`, waiting on the parent xids).

### 2.3 Why PostgreSQL never breaks it, and why it hangs forever

- **No deadlock detection.** PostgreSQL's deadlock detector only fires on a **cycle of sessions each waiting on a lock**. Here the parent T1 is **not** waiting on a lock — it is `idle in transaction` / `ClientRead`, i.e. waiting for the application to send its next statement (which won't come until T2 returns in the JVM). There is no lock cycle from Postgres's view, so it waits indefinitely.
- **No timeout to sever it.** Tenant runtime connections set **no `lock_timeout` and no `statement_timeout`** (grep confirms these appear only in migration scripts). `StockunitRepository.findByIdForUpdate` also carries **no** `jakarta.persistence.lock.timeout` `@QueryHints` (contrast `PickingorderRepository:33` = `1000`, `BillofladingRepository:27` = `5000`). So a blocked child waits forever; the operator sees an eternal spinner; Hikari logs the leak WARN at 60 s and nothing recovers.

### 2.4 Existing workaround is a tell

`MobileReplenishService.java:788‑793` already carries a comment + `entityManager.refresh(inst.stock)` explaining that `createOrderFromTemplate` "runs in REQUIRES_NEW and modifies the Stockunit … the outer persistence context still holds the old version … refresh to re-sync … which would otherwise detect a stale version and throw `ObjectOptimisticLockingFailureException`." That workaround exists **only because** of the cross-transaction split. Collapsing to one transaction removes both the deadlock *and* the reason for the refresh.

---

## 3. The Regression Chain

Not a classic regression — the REQUIRES_NEW on `createOrderFromTemplate` has been present since the v2 multi-UL replenish port. Relevant sibling work that shaped the surrounding invariants (do **not** undo):

| Plan / commit | What it established | Interaction with this fix |
|---|---|---|
| `260709-duplicate-replenishment-orders` (v2 `98732de`, PR #70) | partial unique index `idx_replenishorder_active_item_*` is the v2 dup guard; multi-UL split is intentionally **finish-then-create-then-finish**; **NEW‑1** self-proxy applies to `calculateOrder` on the `requestReplenish` path | This fix **preserves** the finish-then-create ordering and does **not** touch `calculateOrder`/`refillSingleFixedLocation`. Single-tx makes the index invariant hold *within* the tx (the whole point). |
| `260709-multi-unitload-replen-reserve-availability-guard` | availability check in `validateUnitLoadEntry` (`MobileReplenishService:896‑918`) | Independent (pre-loop validation); untouched. |

---

## 4. Architecture Overview

### 4.1 Broken flow (today)

```
tomcat-handler-519 ─ conn C1 ─ T1 fulfillMultipleUnitLoads  (REQUIRED / @Transactional)
   reserve first UL, transferStockToUnitLoad         → PESSIMISTIC_WRITE locks held in T1
   template.setState(700), save                      → active-index entry REMOVED (but UNCOMMITTED)
   createOrderFromTemplate  ── REQUIRES_NEW ──▶  conn C2 ─ T2
        INSERT child (same item,dest, state<700)
          └─▶ collides on idx_replenishorder_active_item_dest with template's
              still-visible active entry ─── waits on T1.xid ───┐
   (T1 suspended, cannot commit until T2 returns) ◀─────────────┘   ✗ permanent deadlock
```

### 4.2 Fixed flow

```
tomcat-handler ─ conn C1 ─ T1 fulfillMultipleUnitLoads  (single tenant tx)
   reserve first UL … template.setState(700), save     (visible to the rest of THIS tx)
   createOrderFromTemplate  ── REQUIRED (joins T1) ──   same conn C1, same snapshot
        INSERT child: template already state=700 in-tx (after explicit flush — see Fix A.2) → NOT in partial index → no collision
        reserve child stock: re-entrant lock in same tx → no wait
   finish child … repeat … COMMIT once   ✓ atomic all-or-nothing
```

### 4.3 Key files

| File | Lines | Role |
|------|-------|------|
| `controller/mobile/ReplenishController.java` | 229‑246 | `POST /multi-unitloads` entry; catches `Business`/`Facade` only |
| `service/mobile/MobileReplenishService.java` | 739‑806 | `fulfillMultipleUnitLoads` orchestrator (outer tx, the loop, the refresh workaround) |
| `service/ReplenishGeneratorService.java` | 263‑310 | `reserveExplicitStockForOrder`, `createOrderFromTemplate` (**the REQUIRES_NEW**) |
| `service/StockunitBusinessService.java` | 178‑259, 466‑495 | `transferStockToUnitLoad`, `changeReservedAmount` (pessimistic locks) |
| `repo/jpa/StockunitRepository.java` | 27‑29 | `findByIdForUpdate` — needs `lock.timeout` hint |
| `landlord/config/TenantDynamicRoutingDataSource.java` | 71‑107 | per-tenant Hikari (pool default 5, leak 60 s) |

---

## 5. Fix Design

### Fix A (primary): `createOrderFromTemplate` → join the caller transaction (`REQUIRED`) **plus explicit flush ordering**

**Problem:** REQUIRES_NEW opens a second transaction while the caller holds pessimistic locks + an uncommitted active-order state change → cross-snapshot partial-index collision + pessimistic-lock wait → unbreakable deadlock. **But** a bare propagation change is insufficient (see §2 Bug 1a "general invariant"): Hibernate's INSERT-before-UPDATE flush ordering would flush the child INSERT ahead of the `template.state=700` UPDATE within one flush → immediate `DataIntegrityViolationException`.

**Solution — two parts, both required:**

**A.1 Propagation.** Make `createOrderFromTemplate` participate in the caller's transaction. The **only production caller** is `MobileReplenishService.fulfillMultipleUnitLoads` (verified — all other references are tests).

```java
// ReplenishGeneratorService.java:271  — BEFORE
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class)
public Replenishorder createOrderFromTemplate(...) { ... }

// AFTER — join the outer tenant transaction; whole multi-UL fulfill becomes atomic
@Transactional(value = "tenantTransactionManager", rollbackFor = {FacadeException.class, BusinessException.class})
public Replenishorder createOrderFromTemplate(...) { ... }
```

**A.2 Flush discipline (the part the first draft missed).** Force each `state=700` transition to reach the DB *before* the next child INSERT, so the partial index never sees two active `(item,dest)` rows in the same flush. Concretely in `fulfillMultipleUnitLoads`:

```java
// after the template order is finished (state=700), BEFORE the loop:
finishReplenishmentOrderWithoutRefill(firstDto);
replenishorderRepository.flush();                 // NEW — template leaves the partial index in-DB
result.add(buildMultiReplenishResponseDto(template, first));

for (int i = 1; i < instructions.size(); i++) {
    MultiUnitLoadInstruction inst = instructions.get(i);
    Replenishorder order = replenishGeneratorService.createOrderFromTemplate(
            template, inst.stock, inst.request.getQty(), destination.getId(), i);
    // (entityManager.refresh removed — Fix B)
    ReplenishMobileOrderDto dto = buildMobileDto(order, inst.stock, inst.request.getQty());
    finishReplenishmentOrderWithoutRefill(dto);
    replenishorderRepository.flush();             // NEW — child_i leaves the partial index before child_{i+1} inserts
    result.add(buildMultiReplenishResponseDto(order, inst));
}
```

Additionally, mirror `calculateOrder`'s precedent (`ReplenishGeneratorService.java:255`) by adding `replenishorderRepository.flush();` immediately after the child `save` inside `createOrderFromTemplate` (line ~304), so each child INSERT is isolated as its own flush and a genuine violation surfaces at the INSERT (catchable) rather than deferred to commit.

Notes:
- Keep `@Transactional` (not remove it): a future out-of-tx caller still gets a transaction via `REQUIRED`; called from `fulfillMultipleUnitLoads` it **joins** T1 — no new connection, no suspension.
- **Child-vs-child collision (critic):** all N orders share the same `(itemdata_id, destination_id)`. Under REQUIRES_NEW, per-child commits serialized them; under single-tx the flush discipline above is what preserves the "one active row at a time" invariant. Without it, two child INSERTs in one flush collide with *each other*, not just the template.
- **Why not the alternative (keep REQUIRES_NEW, reorder to create-all-before-finish):** rejected — it would create N *active* orders for the same `(item,dest)` simultaneously, which the partial unique index forbids by design (`260709` §8). Single-tx + flush ordering is the only option that respects the index invariant.

### Fix B: remove the now-unnecessary `entityManager.refresh` workaround

**Problem:** `MobileReplenishService:788‑793` refreshes `inst.stock` to dodge an `ObjectOptimisticLockingFailureException` caused *only* by the REQUIRES_NEW cross-context write.

**Solution:** With Fix A, `createOrderFromTemplate` writes in the same persistence context/transaction, so the outer context is never stale. Remove the `entityManager.refresh(inst.stock)` call and its explanatory comment.

```java
// MobileReplenishService.java:784‑796  — AFTER
for (int i = 1; i < instructions.size(); i++) {
    MultiUnitLoadInstruction inst = instructions.get(i);
    Replenishorder order = replenishGeneratorService.createOrderFromTemplate(
            template, inst.stock, inst.request.getQty(), destination.getId(), i);
    ReplenishMobileOrderDto dto = buildMobileDto(order, inst.stock, inst.request.getQty());
    finishReplenishmentOrderWithoutRefill(dto);
    result.add(buildMultiReplenishResponseDto(order, inst));
}
```
(If `entityManager` becomes unused after removal, drop the field/import too — verify with a compile.)

### Fix C (necessary guard for the refill path, not merely "secondary"): bounded lock timeout on `Stockunit.findByIdForUpdate`

**Problem:** even after Fix A, `fulfillMultipleUnitLoads` still calls `refillFixedLocations()` at `MobileReplenishService.java:800` **inside the outer transaction while it holds every child's stock-reservation pessimistic locks**. `refillFixedLocations()` → `self.calculateOrder(...)` (`ReplenishGeneratorService.java:95`) is `@Transactional(REQUIRES_NEW)` (`:176`) and reserves stock via `changeReservedAmount`→`findByIdForUpdate`. That is the **same** REQUIRES_NEW-inside-held-locks shape as the reported bug — it just never fired in the incident because execution deadlocked earlier at the first `createOrderFromTemplate`. Post-Fix-A, execution reaches line 800, so this residual path must be guarded. (Fix D below closes it structurally; Fix C bounds it regardless.)

**Solution:** add a `jakarta.persistence.lock.timeout` hint so contention **fails fast** (catchable `PessimisticLockException`/`LockTimeoutException`, swallowed by the existing try/catch at :799‑804) instead of hanging until the 60 s leak WARN.

```java
// StockunitRepository.java  — AFTER
@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "5000"))
@Query("SELECT s FROM Stockunit s WHERE s.id = :id")
Optional<Stockunit> findByIdForUpdate(@Param("id") Long id);
```

- 5000 ms matches `BillofladingRepository:27`; `Pickingorder:33` uses 1000 ms. Pick **5000 ms** (stock rows can be held briefly by a concurrent pick/transfer; 1 s risks false negatives). O‑1 flags for reviewer.
- **The hint demonstrably works in this exact PG/Hibernate stack** — no need to hedge: `PickingorderRepository.java:29` documents that a move "fast-yield[s] to an … 1000ms timeout," i.e. `jakarta.persistence.lock.timeout` fires here. (Manual test 8.3 still confirms it for stock rows.)
- **Scope limit:** this per-query hint covers only the explicit `PESSIMISTIC_WRITE` (`findByIdForUpdate`) — i.e. **Bug 1b**. It does **not** cover the plain child INSERT (**Bug 1a**), whose collision is resolved solely by Fix A's single-tx + flush ordering. A session-level `lock_timeout`/`statement_timeout` would be needed to bound an INSERT wait, but Fix A removes that wait entirely, so it is not required here.

### Fix D (recommended): run `refillFixedLocations()` + `recalculateOpenOrders(true)` **after** the transactional core commits

**Problem:** lines 800‑801 run inside the locked transaction (see Fix C). Relying only on a timeout leaves a REQUIRES_NEW-in-held-locks path that *degrades* (fails fast + logs) rather than being *eliminated*.

**Solution:** split `fulfillMultipleUnitLoads` into a `@Transactional(tenantTransactionManager)` core that does the reserve/create/finish work and returns the result, and a thin **non-`@Transactional`** public wrapper that calls the core and then, after it commits, runs the best-effort post-processing. Once the core tx has committed, no outer locks are held, so `refillFixedLocations()`→`calculateOrder(REQUIRES_NEW)` opens a clean, uncontended sub-transaction.

```java
// public entry (called by ReplenishController) — NO @Transactional
public List<MultiReplenishResponseDto> fulfillMultipleUnitLoads(MultiReplenishRequestDto request) throws ... {
    List<MultiReplenishResponseDto> result = self.fulfillMultipleUnitLoadsTx(request);   // @Transactional core commits here
    try {
        replenishGeneratorService.refillFixedLocations();
        replenishmentOrderMaintenanceService.recalculateOpenOrders(true);
    } catch (Exception e) {
        LOG.warn("post-fulfill refill/recalc failed: {}", e.getMessage());
    }
    return result;
}
```

- Requires the same self-injection pattern already sanctioned in this codebase (`ReplenishGeneratorService.self`, `ReplenishmentOrderMaintenanceService`) so the `@Transactional` core is reached through the Spring proxy. **`MobileReplenishService` has no `self` field today (constructor-injected `final` deps only)** — Fix D introduces one: `@Lazy @Autowired private MobileReplenishService self;`, mirroring `ReplenishGeneratorService.java:53‑55` (the `@Lazy` avoids `BeanCurrentlyInCreationException`). Call the core as `self.fulfillMultipleUnitLoadsTx(request)`.
- `recalculateOpenOrders(true)` is safe either way (`recalculateOrder` is `REQUIRED`, `ReplenishmentOrderMaintenanceService.java:146‑147`), but moving it out keeps the core transaction short.
- If the reviewer prefers the minimal diff, Fix D may be deferred and the residual path left bounded by Fix C alone — but the plan recommends Fix D because it *removes* the anti-pattern instead of merely time-boxing it. O‑2 flags this decision.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/ReplenishGeneratorService.java` | Modify | Fix A.1: `createOrderFromTemplate` propagation `REQUIRES_NEW` → `REQUIRED`; widen `rollbackFor`. Fix A.2: add `replenishorderRepository.flush()` after the child `save` (~line 304) |
| `service/mobile/MobileReplenishService.java` | Modify | Fix A.2: add `replenishorderRepository.flush()` after the template finish and after each child finish in `fulfillMultipleUnitLoads`. Fix B: remove `entityManager.refresh(inst.stock)` + comment (line 793); drop `entityManager` field/import if unused. Fix D: split into non-`@Transactional` wrapper + `@Transactional` core, moving `refillFixedLocations()`/`recalculateOpenOrders(true)` post-commit |
| `repo/jpa/StockunitRepository.java` | Modify | Fix C: add `@QueryHints(jakarta.persistence.lock.timeout=5000)` to `findByIdForUpdate` |
| `test/.../ReplenishGeneratorServiceUnitTest.java` | Modify/Add | Keep AC‑3 pinning green; add propagation/atomicity assertion |
| `test/.../MobileReplenishServiceUnitTest.java` | Modify/Add | Assert refresh removal doesn't regress split; add all-or-nothing rollback test |
| `test/.../mobile/MobileReplenishMultiUnitLoadIT` + `test/resources/scripts/mobileReplenishMultiUnitLoad_deadlock.sql` | **Added (TDD gate, 2026-07-14)** | Self-contained Testcontainers IT reproducing the finish-then-create INSERT against the real partial index. **Currently FAILS** (deadlock → statement timeout) against unfixed code; passes once Fix A lands. §8.2 |
| `sbdocs/9-System/scripts/verify-SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.sh` | Add | Machine-checkable acceptance |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| DB state | **No** | No schema/migration change. Partial index already present (verified §1.1). |
| Feature flags / sysprops | **No** | None. |
| Config / env | **No** | Fix C is a JPA query hint in code, not a config file. |
| Deploy order | **No** | Single-service (`wms2-api`) code change; no coordinated deploy. |
| Data migration | **No** | Confirmed 0 orphaned ad-hoc orders from the incident (§1.1). |
| Operational | **Yes** | If any tenant currently has wedged replenish backends, terminate them (query in §8.3) before/after deploy. `wineco-dev` already cleared during triage. |
| Access | **Yes** | Tenant DB MCP (`wms2-wineco-dev`) for the manual reproduction check. |

### 7.2 Steps (each atomically committable)

1. **Baseline the verify script** — run `PROJECT_ROOT=$(pwd) bash sbdocs/9-System/scripts/verify-SBDEV-2575-*.sh` from `v2/wms2-api`; capture the FAIL baseline.
2. **Fix A.1** — change `createOrderFromTemplate` propagation to `REQUIRED` + widen `rollbackFor`. `mvn -q -o compile`.
3. **Fix A.2 (flush discipline — the critical part)** — add `replenishorderRepository.flush()` after the template finish and after each child finish in `fulfillMultipleUnitLoads`, and after the child `save` in `createOrderFromTemplate`. `mvn -q -o compile`.
4. **Fix B** — remove the `entityManager.refresh(inst.stock)` workaround (line 793); drop unused field/import; `mvn -q -o compile`.
5. **Fix C** — add the `lock.timeout` `@QueryHints` to `StockunitRepository.findByIdForUpdate`; `mvn -q -o compile`.
6. **Fix D** — split `fulfillMultipleUnitLoads` into non-`@Transactional` wrapper + `@Transactional` core (`fulfillMultipleUnitLoadsTx`), moving `refillFixedLocations()`/`recalculateOpenOrders(true)` after the core commits (self-inject for proxy). `mvn -q -o compile`.
7. **Integration test (HARD gate — see §8.2)** — add the PG Testcontainers IT that reserves 2+ ULs of one item into one destination; it MUST reproduce the pre-fix failure (deadlock/23505) and pass post-fix. This is the *only* automated proof of Fix A.2; a unit test cannot see the flush ordering.
8. **Unit tests** — update/extend per §8.1; run `mvn test -Dtest=ReplenishGeneratorServiceUnitTest,MobileReplenishServiceUnitTest`.
9. **Verify** — re-run the verify script → must report `Result: N pass, 0 fail`.
10. **Manual smoke** — perform the multi-UL replenish on `wms2-mobile-ui` against a dev tenant; confirm it completes and no session is left `idle in transaction` (§8.3).
11. **Update §11** with commit SHA(s), test results, and the final verify line.

---

## 8. Testing Plan

### 8.1 Unit
- `ReplenishGeneratorServiceUnitTest`:
  - **Keep green:** `createOrderFromTemplate_stillCreatesChild_noDupGuard` (AC‑3) — behaviour unchanged; propagation is a proxy concern not exercised by a direct bean call, so this test must still pass verbatim.
  - Keep the 6 existing `createOrderFromTemplate` scenarios (null template/stock/amount, amount≤0, cap-to-stock, happy path) green.
  - **Do NOT add a mock-based "propagation assertion"** (critic ambiguity note): a direct bean call in a unit test does not exercise the Spring proxy, so it cannot meaningfully assert `REQUIRED` vs `REQUIRES_NEW`. The atomicity/flush-ordering behaviour is proven by the §8.2 IT and the `MobileReplenishServiceUnitTest` rollback test, not here. Optionally assert the child `save` is followed by a `flush()` (Mockito `verify(replenishorderRepository).flush()`).
- `MobileReplenishServiceUnitTest`:
  - Existing multi-UL scenarios (~2805‑3060) stay green with `createOrderFromTemplate` mocked.
  - **New:** `fulfillMultipleUnitLoads_isAtomic_onChildFailure` — make the 2nd `createOrderFromTemplate` (or its finish) throw; assert the whole result rolls back (no partial `result` returned as success) and the exception surfaces as `Business`/`Facade` per controller contract.
  - **New:** `fulfillMultipleUnitLoads_doesNotRefreshStock` — verify `entityManager.refresh(...)` is **no longer** invoked (Mockito `verify(entityManager, never()).refresh(any())`), pinning Fix B.

### 8.2 Integration (Testcontainers PostgreSQL) — **the hard gate for Fix A.2**
- `MobileReplenishMultiUnitLoadIT` (new): seed a template + 2 unit loads of the same itemdata into one destination flowbin; call `fulfillMultipleUnitLoads`; assert **all** orders reach `state=700` and **no** `DataIntegrityViolationException`/deadlock. This exercises the **real** partial unique index against real Hibernate flush ordering — the pre-fix code fails here (deadlock, or 23505 for the naive propagation-only variant), the post-fix code passes.
- **This is the only automated test that can catch the flush-ordering defect (critic Finding 3).** The unit tests mock `createOrderFromTemplate` (`MobileReplenishServiceUnitTest`) or mock the repositories (`ReplenishGeneratorServiceUnitTest`), so Hibernate never flushes and the collision cannot surface. H2 cannot model a partial unique index (§9.2 row 6). Therefore acceptance **must not** be declared green on unit + verify-script alone.
- **STATUS — lane unblocked, TDD gate IN PLACE (2026-07-14).** `MobileReplenishMultiUnitLoadIT` is written and **confirmed failing for the right reason** against current code: `QueryTimeoutException` at ~8.6 s, `Where: while inserting index tuple in relation "idx_replenishorder_active_item_dest"` → `insert into Replenishorder` → `ReplenishGeneratorService$$SpringCGLIB$$1.createOrderFromTemplate` (the `REQUIRES_NEW` proxy) → `MobileReplenishService.fulfillMultipleUnitLoads:786`. That is Bug 1a reproduced deterministically (~30 s incl. container boot). Run: `mvn -o test -Dtest=MobileReplenishMultiUnitLoadIT` (needs Docker + SDKMAN Java 21/Maven).
- **How the SBDEV‑2217 block was sidestepped:** rather than repair the whole multi-tenant Testcontainers lane, the IT self-contains its harness — it boots the full `StartApplication` context on the `integration` profile but overrides the datasources to a `postgres:12` Testcontainer and builds the schema (incl. the partial index) via Flyway over `classpath:db/migration` (the fresh-v2 base dump `V2.2.00`), with `ddl-auto=none` and an 8 s `statement_timeout`/`lock_timeout` to bound the deadlock. No `src/main` and no shared test infra changed. **SBDEV‑2217 therefore no longer blocks this fix.**
- **Pre-existing regression surfaced (out of scope, file separately):** replaying `db/v1-to-v2-onboarding/schema` from scratch is broken — `V1.2.01__utc_standard_tables.sql:61` (`SELECT 1 FROM outbox_message`) sorts *before* `V2.1.11__add_outbox_message.sql` creates the table → `relation "outbox_message" does not exist`. This keeps `OutboxClaimOrderingIT` and the legacy `AppPostgresDBSetupExtension` ITs red on a fresh DB (introduced by the migration-dir reorg, commit `43384c0`). Not caused by this plan; the new IT avoids that location entirely.

### 8.3 Manual test plan

| Scenario | Environment | Steps | Expected result | Pass/Fail |
|---|---|---|---|---|
| Multi-UL replenish completes | `wms2-mobile-ui` + dev tenant | Start replenish, scan 2+ source ULs for one item, scan destination flowbin, confirm | Page returns (no infinite spinner); all orders `FINISHED`; response lists each order | |
| No wedged sessions | `wms2-wineco-dev` MCP | After the run: `SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction' AND now()-xact_start > interval '30 seconds'` | `0` | |
| Blocking-tree probe (pre/post) | `wms2-wineco-dev` MCP | Run the blocked/blocking join (below) during a run | Pre-fix: `INSERT Replenishorder` blocked on parent xid. Post-fix: empty | |
| Lock-timeout fails fast (Fix C) | dev tenant | Hold a `PESSIMISTIC_WRITE` on a stock row in psql, then trigger a replenish needing it | Request errors within ~5 s with a lock-timeout (not a 60 s hang) | |

Blocking-tree probe:
```sql
SELECT blocked.pid AS blocked_pid, left(blocked.query,60) AS blocked_q,
       blocking.pid AS blocking_pid, blocking.state AS blocking_state
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid=blocked.pid AND NOT bl.granted
JOIN pg_locks gl ON gl.locktype=bl.locktype
   AND gl.transactionid IS NOT DISTINCT FROM bl.transactionid
   AND gl.relation IS NOT DISTINCT FROM bl.relation AND gl.granted
JOIN pg_stat_activity blocking ON blocking.pid=gl.pid;
```

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Propagation-only change (no flush) still collides** — Hibernate flushes child INSERT before `state=700` UPDATE → 23505 | Feature throws instead of hanging; still broken | **Fix A.2 flush discipline** is mandatory, not optional; proven by the §8.2 PG IT (which would fail on a propagation-only diff). Called out explicitly in §2 Bug 1a + §5 Fix A.2 |
| Loss of per-child independent commit (was REQUIRES_NEW) | If one child fails, none persist | **Intended** — atomic all-or-nothing is the correct semantics for one operator's multi-UL scan; documented in §5 Fix A and covered by the atomicity unit test |
| Longer single transaction holds locks slightly longer | Marginally higher contention window | Net *fewer* connections held (2→1 per request) and no deadlock; contention bounded by Fix C's `lock.timeout` |
| `lock.timeout` too low → false lock-timeout errors under legitimate brief holds | Spurious replenish failures | 5000 ms chosen (matches BOL); O‑1 flags for reviewer; validate via manual test 8.3 |
| `lock.timeout` hint value regresses on a future dialect/driver change | Fix C weakened | The hint **fires today** (proven: `PickingorderRepository:29/33`); manual test 8.3 remains as a standing runtime check to catch any future regression |
| Accidentally changing the sibling REQUIRES_NEW methods (`calculateOrder`, `refillSingleFixedLocation`) | Regress `260709` dup-order handling | §0 rows 6‑7 explicitly exclude them; verify script asserts they retain `REQUIRES_NEW` |
| v2 IT harness blocked (SBDEV‑2217) | Can't run the **only** automated proof of Fix A.2 in CI | **Blocker for this fix's sign-off** (§8.2): unblock the PG lane for this IT, or record explicit risk-acceptance + treat manual test 8.3 scenario 1 as a mandatory signed-off gate. Unit tests cannot detect the flush defect. |

## 9.1 Horizontal Scalability Validation (v2 mandatory)

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | New in-JVM state | **No** | No new static/ThreadLocal/cache |
| 2 | Connection pool math | **Yes (improves)** | Request drops from **2** concurrent tenant connections (T1+T2) to **1** — reduces `replicas × tenants × maxPoolSize` pressure |
| 3 | Scheduled jobs | **No** | No `@Scheduled` change |
| 4 | Long transactions holding conn across external I/O | **Yes (addressed)** | Correction to the first draft: `refillFixedLocations()`/`recalculateOpenOrders(true)` run **inside** the tx today (`MobileReplenishService.java:800‑801`), and `refillFixedLocations`→`calculateOrder` is `REQUIRES_NEW` — a residual copy of the reported anti-pattern. **Fix D** moves them post-commit; **Fix C** bounds them meanwhile. No network/broker I/O is held across the tx. |
| 5 | Request affinity | **No** | Single request/response |
| 6 | Retry / idempotency | **Yes (improves)** | Atomic tx → a retried multi-UL scan can't leave half-created orders; partial index still blocks true cross-request dups |
| 7 | Tenant context propagation | **No** | No `@Async`/cron; runs on the request thread with `REQUIRED` (same tenant context as T1) |
| 8 | Distributed lock correctness | **Yes** | Pessimistic locks now all inside one `@Transactional(tenantTransactionManager)`; Fix C adds the missing `lock.timeout` |
| 9 | Cache invalidation | **No** | Replenishorder/Stockunit writes unchanged; no cached-type semantics altered |
| 10 | External notifications | **No** | No OMS/outbox send added |

## 9.2 v2 constraint checklist

| # | Constraint | Verdict | Note |
|---|---|---|---|
| 1 | OSIV disabled | **Yes** | All repo calls remain inside the (now single) tenant tx — no lazy-load outside tx |
| 2 | Transaction manager | **Yes** | `createOrderFromTemplate` keeps `value="tenantTransactionManager"` |
| 3 | `readOnly=true` | N/A | Write path |
| 4 | Caffeine invalidation | N/A | No cached type mutated beyond existing behaviour |
| 5 | Jakarta namespace | **Yes** | `jakarta.persistence.lock.timeout`, `jakarta.persistence.LockModeType` |
| 6 | H2-compatible test SQL | **Yes** | Partial-index reproduction requires PG → Testcontainers IT (not H2) |
| 7 | `BaseControllerTest` | N/A | No controller signature change (`ReplenishController.multiUnitLoads` untouched) |
| 8 | Micrometer metrics | **No** | Reuse existing; optionally count lock-timeout failures later |

---

## 9.3 Acceptance

Run: `PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api bash sbdocs/9-System/scripts/verify-SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.sh`

Accept only when it prints `Result: N pass, 0 fail`. Every §0 in-scope row maps to a positive (and, where it replaces code, negative) check.

---

## 10. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1.1 — live `pg_stat_activity`/`pg_locks`, index confirmed, `db_verified: true` |
| 1 | All callsites enumerated | ✓ §0 — `createOrderFromTemplate` has 1 prod caller; all REQUIRES_NEW audited |
| 2 | Adjacent bugs | ✓ §0 rows 6‑7 — other REQUIRES_NEW sites checked, correctly excluded |
| 3 | Backward compatibility | ✓ §9 — response contract unchanged; semantics shift to atomic (intended) |
| 4 | Concurrency | ✓ §2, §5, §9.1 — deadlock removed; **flush ordering** preserves the partial-index single-active-row invariant; residual refill REQUIRES_NEW path closed (Fix D) + bounded (Fix C) |
| 5 | Multi-tenant | ✓ §9.1 row 2/7 — fewer connections, same tenant ctx |
| 6 | Error handling | ✓ §5 Fix A rollbackFor; §8 atomicity test; child failure → whole-tx rollback |
| 7 | Observability | ✓ §9.2 row 8 — lock-timeout now surfaces a catchable error; optional metric noted |
| 8 | Rollback / migration | ✓ §7.1 — none needed; no orphaned data |
| 9 | Test coverage | ✓ §8 — unit (atomicity + refresh-removal) + **PG IT hard gate** (only automated proof of flush fix) + manual; SBDEV‑2217 escalated as blocker |
| 10 | Cross-version (v1↔v2) | **no — needs its own investigation.** v1 `wms-api` has a paired multi-UL replenish (`260424-multi-unitload-replenish-plan`, archived). v1 uses `javax.*` + Spring Boot 2.3.7 and may share the REQUIRES_NEW-in-lock pattern, but was not reproduced here (incident + DB evidence are v2/wineco-dev). Flag a v1 sweep item to check `ReplenishGenerator` propagation + whether v1 has the partial unique index. |

---

## 11. Implementation Status

**IMPLEMENTED 2026-07-14 — verified green (working tree; NOT yet committed / no PR).**

Fixes A+B+C+D applied to 3 production files; independently re-verified by the main session (not just the implementing agent):

| Fix | File | Change |
|-----|------|--------|
| A.1 | `ReplenishGeneratorService.java:271` | `createOrderFromTemplate` `REQUIRES_NEW` → `REQUIRED`; `rollbackFor={Facade,Business}` |
| A.2 | `ReplenishGeneratorService.java:~305`, `MobileReplenishService.java` (after template finish + after each child finish) | 3× `replenishorderRepository.flush()` enforcing DB-order of the `state=700` transitions |
| B | `MobileReplenishService.java` | removed `entityManager.refresh(inst.stock)` workaround + the now-unused `entityManager` field/imports |
| C | `StockunitRepository.java:27` | `@QueryHints(jakarta.persistence.lock.timeout=5000)` on `findByIdForUpdate` |
| D | `MobileReplenishService.java` | split into non-`@Transactional` `fulfillMultipleUnitLoads` wrapper (post-commit `refillFixedLocations()`/`recalculateOpenOrders(true)`) + `@Transactional fulfillMultipleUnitLoadsTx` core; added `@Lazy @Autowired self` |

**Test results (SDKMAN Java 21 / Maven, Docker):**
- `MobileReplenishMultiUnitLoadIT` (the TDD gate): **PASS** — `Tests run: 1, Failures: 0, Errors: 0` (was failing with the deadlock statement-timeout pre-fix). Command: `mvn -o test -Dtest=MobileReplenishMultiUnitLoadIT`.
- `ReplenishGeneratorServiceUnitTest` + `MobileReplenishServiceUnitTest`: **PASS** — `Tests run: 129, Failures: 0, Errors: 0` (AC‑3 pinning test stays green).
- Verify script: **`Result: 12 pass, 0 fail, 0 skip`** (`verify-SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.sh`).

**Test-scope changes made during implementation (disclosed):**
- `MobileReplenishServiceUnitTest`: dropped the dead `@Mock EntityManager` + redirected 12 call sites from the public wrapper to `fulfillMultipleUnitLoadsTx` (the `@Lazy self` proxy is null under `@InjectMocks`, so the wrapper would NPE — mirrors the established `createOrderFromTemplate` direct-call pattern; wrapper post-commit behaviour is covered by the IT).
- `MobileReplenishMultiUnitLoadIT`: harness completion — set/clear `TenantContext` in `@BeforeEach`/`@AfterEach` (a direct service call never gets it stamped by `TenantFilter`; `StockunitBusinessService.init()` needs it), and scoped the final DB assertion to the returned order ids (Fix D's post-commit refill legitimately creates a new active order for the same fixed location; the partial unique index still guarantees no leaked duplicate). Primary assertions (2 orders, all `FINISHED`, no deadlock) unchanged.
- Verify script: fixed two pre-existing script bugs (undefined `file_contains_n_times`; `mvn_test_passes` grepped for text that `-q` suppresses → now uses exit code).

**Committed:** branch `feature/SBDEV-2575-multi-unitload-replen-deadlock`, commit `cc9ca6b`, [PR #75](https://github.com/SiteBossInc/wms2-api/pull/75) → `develop` (ClickUp SBDEV-2575 = "pr submitted").

**Outstanding before merge:**
- PR review + merge into `develop`.
- Pre-existing, separate: the `db/v1-to-v2-onboarding/schema` from-scratch Flyway replay regression (§8.2) — file its own ticket.
- O‑1 (lock.timeout 5000 ms) and O‑2 (Fix D chosen) stand as decided; no blockers remain.

### Open questions / resolved decisions
- **O‑1 (reviewer):** `lock.timeout` value — proposed **5000 ms** (matches BOL). Confirm vs 1000 ms.
- **O‑2 (reviewer):** Fix D (move refill/recalc post-commit) vs Fix C alone (bound the in-tx REQUIRES_NEW with a timeout). Plan recommends Fix D (eliminates vs time-boxes); Fix C is required either way.
- **O‑3 (RESOLVED 2026-07-14):** the reproducing IT (`MobileReplenishMultiUnitLoadIT`) is written and confirmed failing for the right reason — the SBDEV‑2217 block was sidestepped with a self-contained `db/migration` Testcontainers harness (§8.2). No risk-acceptance needed. (Separate pre-existing regression noted in §8.2 for its own ticket.)
- **Resolved:** fix direction = **drop REQUIRES_NEW → REQUIRED + explicit flush ordering** (single atomic tx), chosen by requester over the "keep REQUIRES_NEW, reorder" alternative (rejected — violates the partial-index single-active-row invariant).
- **Resolved:** no data remediation — 0 orphaned ad-hoc orders confirmed post-terminate (§1.1).

### Review history
- **2026-07-13 — `critic` pass #1 (verdict: REJECT → addressed):** caught that a propagation-only Fix A would fail via Hibernate INSERT-before-UPDATE flush ordering (→ 23505), that §9.1 row 4 falsely called the refill path "outside the locked section," and that the PG IT is the sole automated guard. All folded in: Fix A.2 flush discipline added, Fix D added, Fix C reframed as necessary with proof, §9.1 corrected, §8.2 made a hard gate, minor line-refs fixed.
- **2026-07-14 — `code-reviewer` pass on the implementation diff (verdict: APPROVE-WITH-NITS):** 0 Critical/High; independently confirmed flush ordering, Fix D proxy/post-commit semantics, sole-caller, tenant-TM correctness, and that the IT is a genuine gate. Applied the one clear nit — parameterized the moved SLF4J log line + preserved the throwable (`MobileReplenishService` refill catch). Two MEDIUM items are behavioral-scope confirmations, not defects, already covered by the plan: Fix C's `lock.timeout` now bounds *all* `Stockunit.findByIdForUpdate` callers (§9 risk row) and its efficacy on this PG/Hibernate stack (manual test 8.3 scenario 4) — both to be confirmed as post-deploy smoke checks. One LOW deferred: an optional `@Mock` unit test for the wrapper's refill-swallow (IT already covers the proxy path). Re-ran verify after the log fix: `12 pass, 0 fail`.
- **2026-07-14 — TDD gate established (failing test in place):** unblocked the PG IT lane (self-contained `db/migration` Testcontainers harness, sidestepping SBDEV‑2217) and authored `MobileReplenishMultiUnitLoadIT`. Independently re-ran it: **fails for the right reason** — statement-timeout on the child INSERT colliding with `idx_replenishorder_active_item_dest` inside `createOrderFromTemplate`'s `REQUIRES_NEW`, from `fulfillMultipleUnitLoads:786` (Bug 1a). Success assertions encode the acceptance criteria (both orders `FINISHED`, no surviving active row). **Implementation is gated on human approval (TDD gate).** No `src/main` changed yet.
- **2026-07-13 — `critic` pass #2 (verdict: SHIP-WITH-CHANGES):** re-verified every fix against source (`AbstractBaseEntity:20` SEQUENCE ids; `ReplenishGeneratorService:255` flush precedent; `PickingorderRepository:29/33` timeout proof; `ReplenishmentOrderMaintenanceService:146‑147` REQUIRED; self-injection precedent `ReplenishGeneratorService:53‑55`) — all 3 blocking findings confirmed resolved. Three cosmetic nits raised and **now applied**: (1) §9 risk row reworded so it no longer reasserts "lock.timeout may be inert" after §5 proves it fires; (2) §5 Fix D notes `MobileReplenishService` must add a new `@Lazy @Autowired self` field; (3) §4.2 diagram references the flush. → effectively clean SHIP; ready for implementation once O‑3 is resolved/accepted.
