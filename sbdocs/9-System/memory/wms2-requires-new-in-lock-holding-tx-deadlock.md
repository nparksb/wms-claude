---
name: wms2-requires-new-in-lock-holding-tx-deadlock
description: wms2 REQUIRES_NEW nested inside a lock-holding tenant tx = invisible permanent deadlock; and the flush-ordering trap that defeats the naive single-tx fix
metadata: 
  node_type: memory
  type: reference
  originSessionId: fc024b0b-ceba-46a2-80a3-98b9e79fb75e
---

wms2-api concurrency trap, confirmed live on wineco-dev 2026-07-13 (multi-UL replenish `fulfillMultipleUnitLoads` → `createOrderFromTemplate`). Plan: `sbdocs/1-Projects/wms2/plan/260713-multi-unitload-replen-requires-new-self-deadlock.md`.

**Signature:** a `@Transactional(REQUIRES_NEW)` method called from a service method that already holds `PESSIMISTIC_WRITE` locks (`findByIdForUpdate`) or an uncommitted active-row state change. Spring suspends the outer tx (its connection + locks stay held) and opens a 2nd connection; the inner tx blocks on a row/index the suspended parent holds → waits on the parent's `transactionid`. **PostgreSQL never detects it** because the parent is `idle in transaction` (ClientRead), not lock-waiting → no lock cycle. No tenant `lock_timeout`/`statement_timeout` is configured → hangs FOREVER; Hikari logs `ProxyLeakTask "Apparent connection leak"` at the 60s threshold (`TenantDynamicRoutingDataSource:87`). Diagnose via `pg_stat_activity`+`pg_locks`: look for an `active` child on `Lock:transactionid` blocked by an `idle in transaction` parent.

**The flush-ordering trap (defeats naive fixes):** all entities use `@GeneratedValue(SEQUENCE)` (`AbstractBaseEntity`), so INSERTs defer to flush time and Hibernate's ActionQueue runs **all INSERTs before all UPDATEs in one flush**. So just flipping REQUIRES_NEW→REQUIRED does NOT fix a partial-unique-index collision (e.g. `idx_replenishorder_active_item_dest WHERE state<700`): the child INSERT flushes before the `state=700` UPDATE → immediate `DataIntegrityViolationException` (23505). Fix needs single-tx PLUS explicit `repository.flush()` after each state transition (precedent: `ReplenishGeneratorService.calculateOrder` flushes at :255). Also: `jakarta.persistence.lock.timeout` @QueryHints DOES fire in this PG/Hibernate stack (proof: `PickingorderRepository:29/33` = 1000ms), so bounded pessimistic-lock timeouts are a valid guard.

Related: [[wms2-seqentities-dual-island-id-space]], [[wms2-it-harness-broken-sbdev-2217]] (the PG IT that proves the flush fix is the SBDEV-2217-blocked lane).
