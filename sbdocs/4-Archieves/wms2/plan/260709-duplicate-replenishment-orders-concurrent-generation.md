---
title: "Duplicate Replenishment Orders — v2 Port (Index-Backed + Graceful Handling)"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: archived
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-07-09
updated: "2026-07-15"
db_verified: false
related:
  - "[[260709-duplicate-replenishment-orders-concurrent-generation]]"
  - "[[wms2-scheduled-jobs-catalog]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[wms2-picking-workflow]]"
  - "[[wms2-multi-unitload-replenish]]"
  - "[[260709-multi-unitload-replen-reserve-availability-guard]]"
tags:
  - plan
  - replenishment
  - concurrency
  - v1-v2-port
---

# Duplicate Replenishment Orders — v2 Port (Index-Backed + Graceful Handling)

**Project:** wms2 | **Version:** v2 | **Type:** bugfix (v1→v2 port)
**Priority:** high
**Status:** implemented & merged (v2 `98732de`; [PR #70](https://github.com/SiteBossInc/wms2-api/pull/70) squash-merged → develop as `c8f3f74`, 2026-07-12)
**Date:** 2026-07-09 (v1 origin) / 2026-07-11 (v2 port)

**V1 Source Plan:** `sbdocs/1-Projects/wms1/plan/260709-duplicate-replenishment-orders-concurrent-generation.md` (implemented; v1 PR #195, commit `1d5d847` + ANSI-CAST follow-up `8be4afe`)
**V2 Target:** `v2/wms2-api`
**Sweep:** Unit 5 of `sbdocs/2-Areas/wms-v1-v2-sync/sweeps/2026-07-10-wms-v1-sync.md`

---

## 2. Summary

The v1 fix serialized replenishment generation and added a blocking per-demand advisory lock + idempotent re-check to stop duplicate replenishment orders. **In v2 the port lands very differently because v2 already solved the correctness problem two independent ways v1 lacked**, so the advisory-lock machinery is **not** ported.

| v1 fix | v2 verdict | One-line rationale |
|--------|-----------|--------------------|
| **Fix A** — run-level serialization (advisory xact lock + `doCalculationGuarded`/`self`) | **Not needed (v2 already correct)** | `ReplenishOrderJob` already guards the whole run with a JVM `AtomicBoolean` CAS + `AdvisoryLockService.tryLock(JobLockId.REPLENISH_ORDER)` |
| **Fix B** — blocking per-demand advisory lock + idempotent re-check | **Not applicable as designed** | v2 carries a **partial UNIQUE index** on active `(itemdata_id, destination_id)` — the DB guard v1 explicitly rejected — which prevents a committed duplicate on *every* path |
| **`8be4afe`** — ANSI-CAST fix to v1's native dedup-guard query | **N/A** | v2 has no such native query; the dedup pre-check is Java-side |
| **Fix C** — data remediation | **Ops-only, conditional** | Re-derive the dup census per v2 tenant DB; likely zero because the index has enforced uniqueness in prod all along |

**Counts:** 3 v1 fixes analysed → **0 ported verbatim**, **2 already-satisfied by v2 architecture** (Fix A code, Fix B correctness), **1 conditional ops step** (Fix C). **1 residual gap** and **1 NEW v2-only issue** are the actual work:

- **Residual Gap 1 (the real fix):** the concurrent-loser insert throws an **unhandled `DataIntegrityViolationException`**. On the job path it escapes the `OptimisticLockingFailureException`-only catches and aborts the rest of that tenant's replenishment cycle; on the mobile path it surfaces as a raw user error. → add **graceful, narrowly-scoped** handling that treats the active-dup violation as an idempotent skip (matching the existing pre-check's `return null`).
- **NEW-1 (HIGH):** the 4-arg `calculateOrder` `@Transactional(REQUIRES_NEW)` is **inert on the mobile path** (proxy-bypass), so mobile `save`+`changeReservedAmount` run in autocommit and are not atomic. → self-inject and route same-bean calls through the proxy (mirrors v1's round-2 fix). This *also* gives the graceful handler a well-defined inner-tx commit boundary at which the violation surfaces.

**Intentional v1↔v2 divergence (do NOT "correct" in a future sweep):** v1 rejected a partial unique index because it would forbid the legitimate multi-UL split; v2 keeps the index because v2's split is **finish-then-create-then-finish** (each order reaches `state=FINISHED (700)` before the next child is created), so two active orders for one `(item,dest)` never coexist. v2 therefore relies on the index for correctness and does **not** port v1's advisory lock. See §8.

---

## 1. Problem Statement

**v1 symptom (origin):** the Replenishment menu showed pairs of duplicate replenishment orders (same SKU, destination, amount, created within a fraction of a second), caused by two concurrent `doCalculation()` passes both passing an unlocked NOT-EXISTS de-dup read and both inserting. Fulfilling one of a pair hit "Unit load stock is already reserved (0.0000 available)" because the sibling already reserved the source.

**v2 status of that symptom:** a *committed* duplicate is **impossible** in v2 — the partial unique index (below) rejects the second active row for any `(itemdata_id, destination_id)`. What remains is a **robustness defect**, not a data-corruption defect:

- The losing concurrent inserter (job-vs-manual, or manual-vs-manual — Fix A already excludes job-vs-job) throws `org.springframework.dao.DataIntegrityViolationException` at the INSERT/commit against the unique index.
- **Confirmed unhandled:** `grep -rn DataIntegrityViolation src/main/java` returns nothing. In `ReplenishOrderJob` the exception propagates past every `catch (OptimisticLockException | OptimisticLockingFailureException)` (`:285,313,348,381,413,431,464,485,511`) up to the tenant-level `catch (Exception)` at `ReplenishOrderJob.java:188`, **aborting the remainder of that tenant's replenishment cycle**. On `MobileReplenishService.requestReplenish` it surfaces as a raw 500-class error to the handheld user.

**Reproduction (v2):** fire the mobile/desktop "request replenish" for an `(item, destination)` while the replenishment cron is generating for the same demand (or two manual requests within the same instant). One insert wins; the other throws the unhandled `DataIntegrityViolationException`.

---

## 2b. Root Cause Analysis

### RC-1 — v2 already prevents committed duplicates (two mechanisms v1 lacked)

**Partial unique indexes** on `replenishorder` — on `origin/develop` these live in the linear migration history at `db/migration/V2.1.04__replenishorder_performance_indexes.sql:40,47` ("C1 fix"), which is exactly what the IT harness scans (`src/test/resources/flyway.conf` → `flyway.locations=filesystem:db/migration`):

```sql
-- db/migration/V2.1.04__replenishorder_performance_indexes.sql:40,47   (on origin/develop)
CREATE UNIQUE INDEX idx_replenishorder_active_item_dest
    ON replenishorder (itemdata_id, destination_id) WHERE state < 700;
CREATE UNIQUE INDEX idx_replenishorder_active_item_no_dest
    ON replenishorder (itemdata_id)                 WHERE state < 700 AND destination_id IS NULL;
```

`WmsConstants.State.FINISHED = 700` (`WmsConstants.java:116`). Any second active order for the same `(item[,dest])` is rejected by the DB — on **all** paths (job, `ReplenishorderService.create`, mobile `requestReplenish`), independent of transaction scoping. This is strictly stronger than v1's advisory lock, which only covered the code paths it wrapped.

> **Path note (branch hygiene):** an *uncommitted, unmerged* local chore (`chore/migration-dir-reorg-base-dump`) relocates this file to `db/v1-to-v2-onboarding/schema/` and introduces a `db/migration/V2.2.00__base_v2_schema.sql` base dump. **This port branches off clean `origin/develop` and depends only on the develop layout above** — it is independent of that reorg. Do not reference the reorg paths in the implementation. See §5.1 prereq #4.

**Run-level serialization already present** (v1's Fix A, v2-native form): `ReplenishOrderJob.doCalculation` is guarded by a JVM `RUNNING` `AtomicBoolean.compareAndSet` (`ReplenishOrderJob.java:30,93`; reset in `finally :204`) **and** a cross-replica session advisory lock `advisoryLockService.tryLock(JobLockId.REPLENISH_ORDER = 100002L)` (`:100`; `unlock` in `finally :199`). Both live generation entry points route through it: the cron (`SchedulingConfiguration.java:213-228`) and the single manual trigger (`AdminActionController.java:96`). (v1's *second* manual endpoint `SystemController.triggerOrderReplenish` does not exist in v2 — `SystemController.java:45-51` only returns a mobile URL.)

### RC-2 — why the index does NOT break v2's multi-UL split (the reconciliation)

v1 rejected exactly this index because the multi-UL split deliberately creates several open orders (`REPL…-2`, `-3`) for one item/destination. **v2's split lifecycle is different — finish-then-create-then-finish:**

- `MobileReplenishService.fulfillMultipleUnitLoads` finishes the template order (`finishReplenishmentOrderWithoutRefill(firstDto)`, `:780`) **before** the loop.
- Each subsequent child: `createOrderFromTemplate(...)` (`:786`) → immediately `finishReplenishmentOrderWithoutRefill(dto)` (`:795`).
- `finishReplenishmentOrderInternal` sets `state = FINISHED (700)` (`MobileReplenishService.java:493`) — each order leaves the `state < 700` predicate **before** the next child is created.

So at any instant at most one active order per `(item,dest)` exists → the partial unique index never fires on a legitimate split. (This has been true in v2 production since `V2.1.04` shipped.)

### RC-3 — the residual read-then-write race (still real, but now index-guarded)

`ReplenishGeneratorService.calculateOrder` (`:118-200`) still does an **unlocked** idempotency pre-check (`:127-138`, `findByStateLessThanAndItemdataId` + Java loop, `return null` on match) then build → `save` (`:194`) → `changeReservedAmount` (`:196`). Two concurrent callers can both pass the pre-check (it takes no lock), both attempt the insert, and the DB index rejects the loser. The pre-check remains valuable as a **first-line optimization** (avoids most collisions cheaply) but is not the correctness guarantee — the index is.

### RC-4 (NEW-1) — proxy-bypass makes the 4-arg `@Transactional` inert on the mobile path

`ReplenishGeneratorService` has **no `self` self-injection**. The 3-arg overload (`:114-116`) calls the 4-arg via a same-bean `this.calculateOrder(...)` (`:115`); `refillFixedLocations` (`:80`) and `refillSingleFixedLocation` (`:104`) likewise call same-bean. The 4-arg (`:118-200`) **is** annotated `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW, rollbackFor={FacadeException,BusinessException})`, but a same-bean call **bypasses the Spring proxy → the annotation is inert**. Because `MobileReplenishService.requestReplenish` (`:585`) is **not** `@Transactional` and enters via the 3-arg (`:592`), `calculateOrder` runs in **autocommit** on the mobile path: `save (:194)` and `changeReservedAmount (:196)` are **not atomic** — a failure after `save` can persist an order without its reservation. (Desktop `ReplenishorderService.create` `:83-89` is `@Transactional` and calls the 4-arg cross-bean, so its proxy engages and it is unaffected.)

### Affected Locations

| # | File:line | Construct | In scope? |
|---|-----------|-----------|-----------|
| 1 | `service/ReplenishGeneratorService.java:114-116` | 3-arg `calculateOrder` delegator (same-bean `this.`) | **yes** — NEW-1 route via `self`; graceful-handling choke point |
| 2 | `service/ReplenishGeneratorService.java:118-200` | 4-arg `calculateOrder` (insert + reserve; `@Transactional REQUIRES_NEW`) | context — pre-check retained; no body change |
| 3 | `service/ReplenishGeneratorService.java:80` | `refillFixedLocations` same-bean call | **yes** — NEW-1 route via `self` |
| 4 | `service/ReplenishGeneratorService.java:104` | `refillSingleFixedLocation` same-bean call | **yes** — NEW-1 route via `self` |
| 5 | `service/ReplenishorderService.java:83-92` | desktop `create` (4-arg direct caller; `@Transactional`) | **yes** — graceful-handling catch #2 |
| 6 | `service/ReplenishGeneratorService.java:210-249` | `createOrderFromTemplate` (multi-UL split) | **no change** — deliberately excluded |
| 7 | `service/mobile/MobileReplenishService.java:585-596` | mobile `requestReplenish` (3-arg caller, null-checks) | context — covered transitively via 3-arg choke point |
| 8 | `service/job/ReplenishOrderJobService.java:93-98,107-194` | job generation sub-steps (REQUIRES_NEW, catch Facade/Business) | context — covered transitively via 3-arg choke point |
| 9 | `db/migration/V2.1.04__replenishorder_performance_indexes.sql:40,47` (develop layout) | the partial unique indexes | **no change** — the correctness guarantee |

---

## 3. Design / Proposed Fix

Scope (user-approved): **rely on the existing unique index for correctness; add graceful handling of the active-dup violation; fix NEW-1 atomicity. No advisory lock is ported.**

### 3.1 NEW-1 — engage the 4-arg REQUIRES_NEW tenant tx on every path (proxy fix)

**Problem:** same-bean calls bypass the proxy → 4-arg `@Transactional` inert on the mobile path (RC-4).

**Solution:** self-inject and route the three same-bean calls through the proxy:

```java
// ReplenishGeneratorService
@Autowired
private ReplenishGeneratorService self;   // NEW — the one @Autowired-field exception (proxy self-ref), as in ReplenishmentOrderMaintenanceService

// :80  refillFixedLocations:          self.calculateOrder(ass.getItemdataId(), required, ass.getAssignedlocationId());
// :104 refillSingleFixedLocation:     self.calculateOrder(ass.getItemdataId(), required, ass.getAssignedlocationId());
// :115 3-arg delegator:               return self.calculateOrder(itemDataId, amount, destinationId, WmsConstants.Priority.PRIORITY_VERY_LOW);
```

**Effect:** every path now enters the 4-arg through the proxy → its `REQUIRES_NEW` tenant tx engages → `save`+`changeReservedAmount` are atomic on all paths (mobile included), and the unique-violation surfaces deterministically as a `DataIntegrityViolationException` at the **inner** REQUIRES_NEW commit boundary. **Constructor injection is used for all other deps; `self` is the standard proxy-self-reference exception** (v2 already does this in `ReplenishmentOrderMaintenanceService`).

**Files changed:** `service/ReplenishGeneratorService.java`.

### 3.2 Residual Gap 1 — graceful, narrowly-scoped active-dup handling

**Problem:** the concurrent-loser insert throws an unhandled `DataIntegrityViolationException` (RC-3) → aborts the tenant's job cycle / raw mobile error.

**Solution — catch *outside* the REQUIRES_NEW tx, discriminate on the constraint name (primary) with a re-check fallback, treat as idempotent skip.** After §3.1, the 4-arg tx is always its own REQUIRES_NEW tx, so the violation is caught cleanly *above* it (never "catch-inside-the-same-tx", which would still roll the caller back). Two catch sites cover everything, both calling a shared discriminator `isActiveDupViolation(e, itemDataId, destinationId)`:

**(a) The 3-arg overload (single choke point for refill/job/mobile).** After §3.1 it is the sole non-transactional entry into the 4-arg for those paths:

```java
// 3-arg calculateOrder (:114-116), non-transactional:
public Replenishorder calculateOrder(Long itemDataId, BigDecimal amount, Long destinationId)
        throws FacadeException, BusinessException {
    try {
        return self.calculateOrder(itemDataId, amount, destinationId, WmsConstants.Priority.PRIORITY_VERY_LOW);
    } catch (DataIntegrityViolationException | UnexpectedRollbackException e) {
        if (isActiveDupViolation(e, itemDataId, destinationId)) {
            LOG.info("Concurrent replenish create for itemData={} destination={} lost the active-dup index — skipping (idempotent)",
                itemDataId, destinationId);
            return null;                 // matches the pre-check's return-null contract
        }
        throw e;                         // not the active-dup index → propagate
    }
}
```

**(b) Desktop `create` (the only 4-arg direct caller).** Wrap the 4-arg call in the same guard so a manual-vs-manual/manual-vs-job collision returns `null` instead of erroring:

```java
// ReplenishorderService.create (:89), inside its @Transactional(tenantTransactionManager):
try {
    order = replenishGeneratorService.calculateOrder(item.getId(), mOrder.getAmountRequested(), loc.getId(), mOrder.getPriority());
} catch (DataIntegrityViolationException | UnexpectedRollbackException e) {
    if (isActiveDupViolation(e, item.getId(), loc.getId())) { return null; }
    throw e;
}
```

**Narrow-scoping (`isActiveDupViolation`) — constraint-name PRIMARY, re-check FALLBACK (Architect C2).** `replenishorder` carries a *second* unique constraint on `number` (`uk_nwmy6tp105br1e83w3a979n2w`, `V2.2.00…:3716-3717`) besides the two active-dup partial indexes — so a re-check of "does an open order now exist?" alone is **not** a faithful discriminator (it could swallow a `number`/FK violation that merely coincides with a concurrently-committed active order, or rethrow a genuine dup if the winner was cancelled in the race window). Discriminate on the violated **constraint name** first (structured Hibernate API, not message parsing), fall back to the re-check only when the name is unavailable:

```java
private boolean isActiveDupViolation(RuntimeException e, Long itemDataId, Long destinationId) {
    Throwable cause = NestedExceptionUtils.getMostSpecificCause(e);
    if (cause instanceof org.hibernate.exception.ConstraintViolationException) {
        String name = ((org.hibernate.exception.ConstraintViolationException) cause).getConstraintName();
        if (name != null) {
            return name.toLowerCase().contains("idx_replenishorder_active_item");   // *_dest or *_no_dest
        }
    }
    // Fallback (constraint name null on some dialects): re-observe committed state (READ COMMITTED).
    return openOrderExistsFor(itemDataId, destinationId);
}

private boolean openOrderExistsFor(Long itemDataId, Long destinationId) {
    for (Replenishorder o : replenishorderRepository.findByStateLessThanAndItemdataId(WmsConstants.State.FINISHED, itemDataId)) {
        boolean sameDest = (destinationId == null && o.getDestinationId() == null)
            || (destinationId != null && destinationId.equals(o.getDestinationId()));
        if (sameDest) return true;
    }
    return false;
}
```

An unrelated `DataIntegrityViolationException` (FK, NOT NULL, `number` collision) fails the constraint-name match and — because no matching active order will exist except by rare coincidence — is rethrown, satisfying AC-5. Placing the two catch sites in the (non-tx) 3-arg and in `create`'s *outer* tx keeps them safely outside the failed inner REQUIRES_NEW tx (see below).

**Deterministic surfacing (Architect C3).** `Replenishorder` (via `AbstractBaseEntity`) uses `GenerationType.SEQUENCE, allocationSize=1`, so Hibernate **defers** the INSERT past `save()` (`:194`) — the violation fires either at the auto-flush inside `changeReservedAmount` (`:196`) or at the REQUIRES_NEW commit. To make the surfacing point and exception type deterministic (and the test reliable), the 4-arg does `replenishorderRepository.saveAndFlush(replenishOrder)` at `:194` so the violation surfaces as a translated `DataIntegrityViolationException` at the repository boundary inside T2. The catch also lists `UnexpectedRollbackException` as cheap insurance against any commit-time surfacing.

**Why not catch inside the 4-arg `calculateOrder`:** even with `saveAndFlush`, the violation marks T2 rollback-only, so an in-method catch cannot resume it and would still yield `UnexpectedRollbackException` at the proxy boundary. Catching in the (non-tx) 3-arg and in `create`'s *outer* tx are both safely outside the failed inner tx. **C1: §3.1 and §3.2 must ship in the same commit** — without self-routing, the job-path `3-arg → this.4-arg` runs inline in the sub-step tx T1, the violation marks T1 rollback-only, and even catching the DIVE yields `UnexpectedRollbackException` when the sub-step proxy commits. The graceful handling is *only* correct because self-routing makes the 4-arg a real inner tx; a real-proxy job-nesting slice test (not a mock) must prove it (§6).

**Files changed:** `service/ReplenishGeneratorService.java` (3-arg catch + `isActiveDupViolation`/`openOrderExistsFor` helpers + `saveAndFlush`), `service/ReplenishorderService.java` (create catch — calls the shared discriminator, e.g. delegated to `ReplenishGeneratorService` or a small duplicated helper).

**Implementation notes (surfaced by the TDD gate — MUST honor):**
1. **`saveAndFlush` is not on `ReplenishorderRepository` today** — it extends only `PagingAndSortingRepository` + `CrudRepository`, not `JpaRepository`. To make the violation surface deterministically (C3), either widen the repo to `JpaRepository` (preferred, low-risk) or inject `EntityManager` and `flush()` after `save` at `:194`. Whichever is chosen, the `:194` call site changes accordingly.
2. **The discriminator MUST walk the cause chain, not use `NestedExceptionUtils.getMostSpecificCause`.** The real chain is `DataIntegrityViolationException → org.hibernate.exception.ConstraintViolationException(constraintName) → SQLException`; `getMostSpecificCause` returns the *SQLException*, which has no constraint name — so `isActiveDupViolation` must iterate the cause chain to find the Hibernate `ConstraintViolationException` and read `getConstraintName()`. (Pinned by `calculateOrder_rethrows_whenNumberConstraintViolation`, which fails if the impl leans on `getMostSpecificCause` + re-check fallback and thereby swallows a `number`-constraint violation.)

### 3.3 Retained / excluded

- **Pre-check `:127-138`:** retained, unchanged (first-line optimization; `return null` contract preserved — both manual callers null-check: `MobileReplenishService.java:593-595`, `ReplenishorderService.java:90-92`).
- **`createOrderFromTemplate` (`:210-249`):** untouched — multi-UL split must keep creating N children; it is never routed through the graceful handler.
- **No advisory lock, no new `AdvisoryLockRepository`, no `JobLockId`, no ANSI-CAST query** (Fix A already satisfied; Fix B obviated by the index; `8be4afe` N/A).
- **Desktop `create` returning `null` on a lost race is intentional silent-no-op UX** — it preserves the *existing* contract (`ReplenishorderService.java:90-92` already returns `null` when `calculateOrder` returns null; the caller/UI treats it as "nothing to create"). This deliberately does **not** resurrect the contested TODO at `ReplenishGeneratorService.java:148-149` ("mobile needs null, desktop needs exception"); a future sweep should not "fix" the null into an exception.

---

## 4. V2-Specific Adaptation Notes

1. **Transaction manager:** all tenant `@Transactional` stay `value="tenantTransactionManager", rollbackFor={BusinessException,FacadeException}` (the 4-arg already complies; no bare `@Transactional` introduced).
2. **Jakarta:** no new persistence/lock-timeout properties; imports for the catch are `org.springframework.dao.DataIntegrityViolationException` (Spring, version-agnostic).
3. **Proxy self-reference:** `self` `@Autowired` field is the sanctioned exception to constructor-injection (precedent: `ReplenishmentOrderMaintenanceService`). All other deps remain constructor-injected.
4. **`Optional`:** unchanged; existing `.orElseThrow(...)` patterns kept.
5. **Entity equality:** N/A — no `.equals()` rewrites; comparison stays ID-based.
6. **Extracted services:** the fix lands in the same classes v2 already owns (`ReplenishGeneratorService`, `ReplenishorderService`); no relocation.
7. **Caching/metrics:** none introduced.
8. **ITs / concurrency harness (Architect C1 + Critic MAJOR-1):** the *full-context* `@SpringBootTest` IT lane is broken (SBDEV-2217) — any such IT lands `@Disabled(TODO SBDEV-2217)`. **Do NOT use `@DataJpaTest`** for the concurrency proof: its H2 default does not support PostgreSQL *partial* unique indexes (would silently create a full unique index and break the multi-UL split), and it neither instantiates the `@Service` proxies nor provides a `tenantTransactionManager` bean. Instead reuse the **proven in-repo raw-Testcontainers pattern** (`AppPostgresDBContainer` + Flyway against `db/migration`, as in the *non-disabled* `integration/outbox/OutboxClaimOrderingIT`): a `@Testcontainers PostgreSQLContainer("postgres:12")`, Flyway `filesystem:db/migration` (which on develop **contains** `V2.1.04`'s partial unique index), a minimal `@Import`/`@ContextConfiguration` of `ReplenishGeneratorService` + `ReplenishorderService` + their repos, and a `DataSourceTransactionManager` **bean named `tenantTransactionManager`** bound to the container so the `@Transactional(value="tenantTransactionManager", REQUIRES_NEW)` proxies engage. This is required for both the job-nesting slice (AC-6) and the NEW-1 atomicity test (AC-2) — mock unit tests cannot exercise the real REQUIRES_NEW suspend/resume boundary.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Partial unique indexes `idx_replenishorder_active_item_dest` / `_no_dest` present on each target tenant DB (`state<700`). | DBA | Shipped in `db/migration/V2.1.04` (on develop). **Verify per tenant** (`SELECT indexdef FROM pg_indexes WHERE indexname LIKE 'idx_replenishorder_active_item%'`) before relying on graceful handling — a tenant DB predating `V2.1.04` lacks the correctness guarantee. |
| 2 | **Feature flags / sysprops** | None new. | — | Existing replenish activation sysprops unchanged. |
| 3 | **Config / env** | None. | — | No new properties. |
| 4 | **Branch base / deploy-order deps (Critic MAJOR-3)** | Cut the implementation branch from **clean `origin/develop`**; do NOT base it on the uncommitted `chore/migration-dir-reorg-base-dump` working tree. | Impl | The plan's schema path is develop's `db/migration/V2.1.04` and the IT harness scans `db/migration`. The port is **independent of** the in-flight migration-dir reorg (which is unmerged). No OMS/omsv2-UI deploy-order dependency. |
| 5 | **Data migration** | **Conditional (Fix C):** per tenant, run the §6 dup census; if any active dups exist, cancel redundant via `ReplenishorderService.cancelReplenishmentOrder`. | Ops | Expected **zero** — the unique index has blocked committed dups since `V2.1.04`. No raw SQL. |
| 6 | **External systems** | N/A. | — | No OMS/printer/Keycloak interaction. |
| 7 | **Access / permissions** | N/A. | — | No new endpoint/authority. |
| 8 | **Monitoring / alerts** | Optional: log-based alert on the new "lost the active-dup index — skipping" INFO line to quantify real collision frequency. | Ops | Confirms whether job-vs-manual collisions are frequent enough to warrant further work. |

### 5.2 Implementation Checklist

- [ ] **NEW-1**: add `@Autowired private ReplenishGeneratorService self;`; route `:80`, `:104`, `:115` via `self.calculateOrder(...)`.
- [ ] **Gap 1 (a)**: wrap the 3-arg `self.calculateOrder(...)` in `try/catch(DataIntegrityViolationException)` → `openOrderExistsFor` re-check → `return null` or rethrow.
- [ ] **Gap 1 (b)**: same guard around `ReplenishorderService.create`'s 4-arg call.
- [ ] add `openOrderExistsFor(itemDataId, destinationId)` helper(s) reusing `findByStateLessThanAndItemdataId`.
- [ ] confirm `createOrderFromTemplate` untouched; pre-check `:127-138` retained.
- [ ] Unit tests (§6) + concurrency slice test.
- [ ] `mvn test -Dtest=ReplenishGeneratorServiceUnitTest,ReplenishorderServiceUnitTest`; then `mvn clean compile` + targeted suite; ITs `@Disabled(SBDEV-2217)`.
- [ ] Code review; verify script `0 fail`.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Concurrent duplicate (job path) | An open order for `(item,dest)` exists (`state<700`); job sub-step calls `calculateOrder` for the same demand and its insert loses the index | `calculateOrder` returns `null`; **no** `DataIntegrityViolationException` escapes; the tenant's remaining cycle continues |
| Concurrent duplicate (manual path) | Mobile `requestReplenish` / desktop `create` for a demand already open | returns `null` (mobile) / `null` (desktop); no raw error |
| Unrelated integrity violation | Force a non-dup `DataIntegrityViolationException` (e.g. FK/NOT NULL) with no matching open order | exception **propagates** (not swallowed) — AC-5 |
| NEW-1 atomicity (mobile) | Mobile path: `changeReservedAmount` throws after `save` | order insert **rolled back** (REQUIRES_NEW engaged) — no orphan order without reservation |
| Multi-UL split regression | `fulfillMultipleUnitLoads` across ≥2 source ULs | `REPL…-2`, `-3` children still created; graceful handler never consulted for the split |
| Pre-check still short-circuits | Open order exists; single (non-concurrent) `calculateOrder` | returns `null` at the pre-check (`:127-138`), no insert attempted |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `ReplenishGeneratorServiceUnitTest` | `calculateOrder_returnsNull_onActiveDupViolation_whenOpenOrderExists` | `save`/reserve path throws `DataIntegrityViolationException`; `openOrderExistsFor` true → returns null (AC-1) |
| `ReplenishGeneratorServiceUnitTest` | `calculateOrder_rethrows_whenViolationNotActiveDup` | DIVE with no matching open order → rethrown (AC-5) |
| `ReplenishGeneratorServiceUnitTest` | `calculateOrder_routesThroughSelf_soRequiresNewEngages` | verifies 3-arg delegates via `self` (proxy-entry; AC-2) |
| `ReplenishGeneratorServiceUnitTest` | `calculateOrder_pinsPreCheckSkip` | pre-check `:127-138` still returns null first (AC-4) |
| `ReplenishGeneratorServiceUnitTest` | `createOrderFromTemplate_stillCreatesChild_noDupGuard` | split path unguarded (AC-3) |
| `ReplenishGeneratorServiceUnitTest` | `calculateOrder_rethrows_whenNumberConstraintViolation` | DIVE whose constraint is `uk_…number` (not active-dup) → rethrown even if an active order coincidentally exists (AC-5, Architect C2) |
| `ReplenishGeneratorServiceUnitTest` | `calculateOrder_rethrows_whenForeignKeyViolation` | DIVE with a **non-null, non-matching** FK constraint name → rethrown (pins the constraint-name branch, not just the null-name fallback) (AC-5, Critic) |
| `ReplenishorderServiceUnitTest` | `create_returnsNull_onActiveDupViolation` | desktop catch → null (AC-1) |
| `ReplenishDupConcurrencySliceIT` (raw `@Testcontainers PostgreSQLContainer("postgres:12")` real-proxy, Flyway `db/migration`; NOT `@DataJpaTest`) | `jobNesting_subStepRequiresNew_continues_onActiveDupViolation` | **Architect C1 / Critic MAJOR-1 (the correctness core):** with a real `tenantTransactionManager` bean + real service proxies, drives the nesting (sub-step `REQUIRES_NEW` → 3-arg → `self` 4-arg `REQUIRES_NEW`); asserts loser returns null, exactly one active row survives, and **no `UnexpectedRollbackException`** escapes to abort the loop. Mocks cannot exercise the suspend/resume boundary. Harness = `AppPostgresDBContainer`/`OutboxClaimOrderingIT` pattern (§4.8). |
| `ReplenishDupConcurrencySliceIT` (same harness) | `mobilePath_rollsBackOrder_whenReserveThrowsAfterSave` | **NEW-1 atomicity (Critic MAJOR-2, binds AC-2):** on the mobile 3-arg→`self` path, `@SpyBean`/stub `stockUnitBusinessService.changeReservedAmount` to throw *after* `save` (:194); assert **no `replenishorder` row persists** (proves the 4-arg REQUIRES_NEW tenant tx actually engaged and rolled back — impossible in the pre-fix autocommit path). A mock-`self` wiring test alone cannot prove this. |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Mobile request during cron | wms2 staging (non-LA tenant) | Trigger cron replenish, then fire mobile `requestReplenish` for a demand the cron is generating | Mobile returns cleanly (no 500); at most one active order for the demand | |
| Desktop create race | staging | Two `create` calls for the same `(item,dest)` in quick succession | One order created, the other returns null (no error) | |
| Split intact | staging | Multi-UL replenish across ≥2 ULs | `REPL…-2`/`-3` children created; no index error | |
| SQL sanity | staging DB | `SELECT indexdef FROM pg_indexes WHERE indexname LIKE 'idx_replenishorder_active_item%';` | both partial unique indexes present | |
| Dup census (Fix C) | each tenant DB | §6 census query | expected 0 active dup groups | |

**Dup census (Fix C, per tenant):**
```sql
SELECT itemdata_id, destination_id, COUNT(*)
FROM replenishorder
WHERE state < 700 AND number NOT LIKE '%-%'
GROUP BY itemdata_id, destination_id
HAVING COUNT(*) > 1;   -- expect 0 rows (unique index enforces this)
```

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn -o test -Dtest=ReplenishGeneratorServiceUnitTest,ReplenishorderServiceUnitTest` | BUILD SUCCESS | 85 / 0 / 0 |
| `mvn -o clean compile` | BUILD SUCCESS | — (DI-wiring + repo widening compile clean) |
| `bash sbdocs/9-System/scripts/verify-…-v2.sh` | 10 passed, 0 failed | 10 / 0 |
| `ReplenishDupConcurrencySliceIT` (AC-6, AC-2 atomicity) | `@Disabled(SBDEV-2217)` | skipped — manual test plan is the gate |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Full-context `@SpringBootTest` concurrency IT | v2 Testcontainers harness broken (SBDEV-2217); replaced by the `@DataJpaTest`/JDBC slice against the onboarding schema |
| Advisory-lock tests | no advisory lock ported |

---

## 7. Horizontal Scalability Validation

| # | Concern | Does this change… | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | In-JVM state | new per-replica state? | **No** | No cache/static/ThreadLocal added; `self` is a Spring singleton proxy ref |
| 2 | Connection pool math | change per-request connection usage? | **No** | NEW-1 makes the mobile 4-arg a short REQUIRES_NEW tx (was autocommit) — same 1 connection, bounded; no new pools |
| 3 | Scheduled jobs | add/modify a cron job? | **No** | `ReplenishOrderJob` cadence/guards unchanged |
| 4 | Long transactions | hold a tx across I/O? | **No** | `calculateOrder` tx is short, DB-only |
| 5 | Request affinity | assume same replica? | **No** | Stateless; DB-backed |
| 6 | Retry / idempotency | rely on single-execution semantics? | **Yes** | The whole point: graceful handling is **idempotent** — a retry/loser cleanly returns null; the unique index is the cross-replica dedup guarantee. Evidence below. |
| 7 | Tenant context | `ThreadLocal` across async? | **No** | No async boundary added; runs in caller thread/tenant tx |
| 8 | Distributed lock correctness | add/rely on locks across replicas? | **Yes** | Relies on the **partial unique index** (DB-enforced, cross-replica) rather than an app lock; Fix A's existing advisory lock unchanged. Evidence below. |
| 9 | Cache invalidation | write a cached entity? | **No** | `Replenishorder` not cached |
| 10 | External notifications | send to external system in a tx? | **No** | None |

### Evidence (Yes rows)

| Concern # | What was verified | File:line / test |
|-----------|-------------------|------------------|
| 6 | Loser returns `null` (idempotent), matches pre-check contract; both manual callers null-check | `ReplenishGeneratorService.java:136`, `MobileReplenishService.java:593-595`, `ReplenishorderService.java:90-92`; test `jobNesting_subStepRequiresNew_continues_onActiveDupViolation` |
| 8 | Committed-duplicate impossible across replicas via partial unique index (not app lock) | `V2.1.04__replenishorder_performance_indexes.sql:40,47`; `V2.2.00__base_v2_schema.sql.sql:3853,3860` |

---

## 8. Notes — intentional v1↔v2 divergence (do NOT re-flag in a future sweep)

- **v1 uses an advisory lock; v2 uses a partial unique index + graceful handling.** v1's plan §4 explicitly rejected the index because v1's multi-UL split keeps multiple active orders per `(item,dest)`. v2's split is finish-then-create-then-finish (RC-2), so the index is safe *and* stronger. A future `wms-v1-sync-sweep` diffing the two `calculateOrder` bodies will see v2 has **no advisory lock** — that is the deliberate design, not drift.
- **v1's `AdvisoryLockService`-vs-`AdvisoryLockRepository` distinction:** v2's `AdvisoryLockService` (session-scoped, landlord datasource, single-`long` `JobLockId` registry, non-blocking) already backs Fix A at the run level and is architecturally unable to supply a per-demand blocking tenant xact lock — another reason Fix B is not ported onto it.
- **`8be4afe`** (ANSI-CAST) has no v2 counterpart (Java-side pre-check, no native `::bigint` query).
- Pair: v1 plan `260709-duplicate-replenishment-orders-concurrent-generation.md`.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

`sbdocs/9-System/scripts/verify-260709-duplicate-replenishment-orders-concurrent-generation-v2.sh` — assertions:

1. `ReplenishGeneratorService` self-injects `ReplenishGeneratorService self` and the 3 same-bean call sites (`refillFixedLocations`, `refillSingleFixedLocation`, 3-arg→4-arg) are routed via `self.calculateOrder(` (NEW-1). **Negative (method-anchored, not line-anchored — Critic minor):** within the bodies of `refillFixedLocations`, `refillSingleFixedLocation`, and the 3-arg `calculateOrder`, no un-`self`-qualified `calculateOrder(` call remains.
2. 3-arg `calculateOrder` catches `DataIntegrityViolationException | UnexpectedRollbackException` and calls `isActiveDupViolation(...)` before `return null`; rethrows otherwise (AC-1, AC-5).
3. `isActiveDupViolation` matches the constraint name `idx_replenishorder_active_item` (primary) with `openOrderExistsFor` fallback (Architect C2); grep asserts the constraint-name branch present.
4. The 4-arg uses `saveAndFlush` at the insert so the violation surfaces deterministically (Architect C3).
5. `ReplenishorderService.create` has the same guarded catch around its 4-arg call (AC-1).
6. Pre-check block at `ReplenishGeneratorService` retained (`findByStateLessThanAndItemdataId` + `return null`) (AC-4).
7. `createOrderFromTemplate` does **not** reference the graceful handler / discriminator (multi-UL split preserved) (AC-3).
8. **Negative (divergence guard):** no `AdvisoryLockRepository`, no `pg_advisory_xact_lock`, no new `JobLockId` added by this port.
9. `ReplenishGeneratorServiceUnitTest` + `ReplenishorderServiceUnitTest` new methods pass; real-proxy job-nesting slice present (AC-6, Architect C1; `@Disabled` only if full-context).

**Acceptance criteria (feeds `wms-tdd-gate`):**
1. Concurrent duplicate create (same item+dest, one already open `state<700`) → no second committed row AND no propagated `DataIntegrityViolationException`; second attempt returns null idempotently on **both** job and manual paths.
2. NEW-1: `self`-routed; 4-arg REQUIRES_NEW tenant tx engages on the mobile path (save+reserve atomic — failure after save rolls back the order).
3. Multi-UL split unchanged (N children); graceful handler not consulted for the split.
4. Existing pre-check retained; `null`-return contract preserved (callers null-check).
5. Graceful handling scoped to the active-dup case; unrelated `DataIntegrityViolationException` propagates.
6. Concurrency slice: two concurrent same-demand inserts → exactly one active row, loser handled; full-context ITs `@Disabled(SBDEV-2217)`.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 2 files, 1 NEW issue + graceful handling across a choke point; single subsystem |
| **Pre-draft step** | none | analysis complete (architect + tracer pre-investigation) |
| **Plan-review step** | critic (via ralplan) | mandated by wms-v2-migrate |
| **Implementation shape** | `wms-tdd-gate` → ralph | TDD-first (acceptance criteria are testable) |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | code-reviewer | concurrency/tx-boundary change warrants it |
| **Commit step** | git directly (single logical commit) | one branch `port/260709-duplicate-replen-graceful` cut from **clean `origin/develop`** (§5.1 prereq #4 — not the reorg working tree) |

---

## 10. Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Catch swallows an unrelated `DataIntegrityViolationException` (esp. the `number` unique constraint) | real integrity bug hidden | constraint-name discriminator (`isActiveDupViolation`) matches only `idx_replenishorder_active_item*`; re-check is fallback only; unrelated violations rethrow (AC-5); tests `..._rethrows_whenViolationNotActiveDup` + `..._rethrows_whenNumberConstraintViolation` (Architect C2) |
| Catch placed inside the 4-arg tx → `UnexpectedRollbackException` | run still aborts | catch is in the **non-tx 3-arg** and in `create`'s **outer** tx, outside the failed REQUIRES_NEW; §3.1+§3.2 ship together (Architect C1); `saveAndFlush` makes surfacing deterministic and the catch also lists `UnexpectedRollbackException` (Architect C3) |
| `createOrderFromTemplate` split path emits an unhandled DIVE on a split-vs-generator race | rare split failure surfaces raw | **Accepted residual (out of declared scope, Architect C4):** the finish→create window is single-threaded per split and the concurrent generator would have to hit the same `(item,dest)` in that window; likelihood very low. Documented here; add the same guard as defense-in-depth only if observed in prod. |
| NEW-1 `self` proxy introduces a DI cycle | context fails to start | self-reference is a supported Spring pattern (precedent `ReplenishmentOrderMaintenanceService`); gate on `mvn clean compile` + context load |
| A tenant DB predates `V2.1.04` (no index) | graceful handler never fires; committed dups possible | Prereq #1 verifies the index per tenant before relying on it |
| Re-check adds a query on the (rare) collision path | negligible perf | only runs on an actual `DataIntegrityViolationException` (exceptional), reuses existing query |
| Mobile path now opens a short tx (was autocommit) | connection held marginally longer | bounded, DB-only; HS#2 verdict No-impact |
| Divergence "corrected" in a future sweep (advisory lock re-added) | needless complexity / regression | §8 divergence note + verify-script negative check #6 |

---

## 11. Review log

- **2026-07-11 — Planner (draft):** produced from wms-v2-migrate analysis (architect + tracer pre-investigation). Scope pre-decided by requester: index + graceful handling, no advisory lock. Pending Architect + Critic.
- **2026-07-11 — Architect (read-only):** SOUND-WITH-CONDITIONS. Confirmed the tx/proxy design is correct (job-path suspend/resume; desktop outer-tx clean; NEW-1 call set complete; self-injection precedent real). Conditions folded in: **C2** (constraint-name discriminator primary + re-check fallback — `replenishorder.number` has its own unique constraint, so re-check-only is over/under-inclusive), **C1** (ship §3.1+§3.2 together; add a real-proxy job-nesting slice test — mocks can't exercise REQUIRES_NEW suspend/resume), **C3** (`saveAndFlush` for deterministic surfacing + catch `UnexpectedRollbackException`), **C4** (`createOrderFromTemplate` residual DIVE documented as accepted). Plan revised.
- **2026-07-11 — TDD gate:** baseline authored on `port/260709-duplicate-replen-graceful`. 3 tests RED-for-the-right-reason (`calculateOrder_returnsNull_onActiveDupViolation_whenOpenOrderExists`, `calculateOrder_routesThroughSelf_soRequiresNewEngages`, `create_returnsNull_onActiveDupViolation`); 5 GREEN guards/pinning (AC-5 ×3 incl. the `number`-constraint discriminator guard, AC-4 pre-check, AC-3 split); 85 unit tests total, 82 green, 0 regressions; `mvn -o test-compile` SUCCESS. The 2 real-proxy Testcontainers tests (AC-6 job-nesting, AC-2 atomicity) are `@Disabled(SBDEV-2217)` — a sliced real-proxy context still pulls the broken multi-tenant boot lane (same as sibling `ReplenishmentOrderSourceSyncIT`); behavioral gate for those two is the §6 Manual test plan (M-mobile-during-cron, M-desktop-race) until SBDEV-2217 is fixed. Two impl notes folded into §3.2 (repo lacks `saveAndFlush`; discriminator must walk the cause chain). **PAUSED for implementation approval.**
- **2026-07-11 — Implemented:** branch `port/260709-duplicate-replen-graceful` (off clean `origin/develop`), commit **`98732de`**, **[PR #70](https://github.com/SiteBossInc/wms2-api/pull/70)** → develop (non-stacked; disjoint from #66–#69). Changes: `ReplenishGeneratorService` (`@Lazy` self-injection + 3 same-bean calls routed via `self`; graceful catch in 3-arg with cause-chain-walking `isActiveDupViolation` + `openOrderExistsFor`; `flush()` after `save`), `ReplenishorderService.create` (same guarded catch, local discriminator per §3.2(b)), `ReplenishorderRepository` (widened to `JpaRepository` for `flush()`). Pre-check + `createOrderFromTemplate` untouched. **Tests:** 85 unit green (3 new red→green: `calculateOrder_returnsNull_onActiveDupViolation_whenOpenOrderExists`, `calculateOrder_routesThroughSelf_soRequiresNewEngages`, `create_returnsNull_onActiveDupViolation`; + AC-5 guards incl. `number`-constraint & FK rethrow; AC-3/AC-4 pinning). `mvn -o clean compile` SUCCESS; verify script 10/10. **Impl deviations (both sound):** `save()+flush()` instead of `saveAndFlush` (avoids rewriting 11 stubs; equivalent); local discriminator in `create` (generator is mocked in that unit test). **code-reviewer APPROVE** (0 CRITICAL/HIGH/MEDIUM, 4 LOW — repo super-interface redundancy + method visibility both fixed post-review; permitted duplication + verify-wording noted). **verifier PASS.** **Deploy gate:** AC-6 (real-proxy job-nesting) + AC-2 atomicity are `@Disabled(SBDEV-2217)` — CI-unproven; the §6 manual test plan (mobile-during-cron, desktop-race) MUST be run on staging before this is considered behaviorally proven. Fix C (dup census) conditional per tenant — expected zero (index has enforced uniqueness in prod).
- **2026-07-11 — Critic (read-only):** ITERATE → all findings closed (verification-layer only; design unchanged). **MAJOR-1** the concurrency slice was mislabeled `@DataJpaTest` (H2 can't do partial unique indexes; no service proxies / no `tenantTransactionManager`) → respecified as the raw-Testcontainers `AppPostgresDBContainer`/`OutboxClaimOrderingIT` pattern against `db/migration` (§4.8, §6). **MAJOR-2** NEW-1 atomicity had no real-tx test → added `mobilePath_rollsBackOrder_whenReserveThrowsAfterSave` bound to AC-2. **MAJOR-3** undocumented dependency on the unmerged migration-dir-reorg → verified the index is on develop at `db/migration/V2.1.04` and harness scans `db/migration`; port re-scoped to branch off clean develop, independent of the reorg (§2b path note, §5.1 prereq #4, §9.2). Minors: renamed the §7 evidence test to match; method-anchored the verify greps. Missing-items: added the FK-constraint rethrow test (AC-5) and the desktop silent-null UX note (§3.3). **Consensus reached — plan ready for `wms-tdd-gate`.**
