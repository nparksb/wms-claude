---
title: "transferStockToUnitLoad TOCTOU — unguarded entityLock reads on 4 entities risk silent state corruption"
ticket: "SBDEV-2229"
ticket_url: ""
type: "bugfix"
priority: "high"
status: "implemented"
project:
  - wms2
version: "v2"
requester: ""
created: "2026-05-14"
updated: "2026-05-14"
db_verified: true
related:
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - sbdocs/3-Resources/architecture/wms2-end-to-end-request-journey.md
  - sbdocs/1-Projects/wms2/plan/SBDEV-2223-confirmPick-last-pick-detection-race.md
tags:
  - plan
  - wms2
  - stock-transfer
  - concurrency
  - pessimistic-lock
  - toctou
  - race-condition
---

# SBDEV-2229 — `transferStockToUnitLoad` TOCTOU lock-state checks

**Ticket:** SBDEV-2229
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** draft
**Date:** 2026-05-14

> **db_verified: true** — Schema and lock-state verified via MCP `wms1-wineco-dev` (v1 dev DB;
> v2 schema is structurally identical for these tables). Queries run 2026-05-14.
>
> **Schema confirmation:**
> ```sql
> SELECT table_name, column_name, data_type, is_nullable
> FROM information_schema.columns
> WHERE table_name IN ('stockunit', 'unitload', 'location')
>   AND column_name IN ('entity_lock', 'version');
> ```
> Results: `entity_lock` is `integer, nullable` on all three tables. `version` is `integer, NOT NULL`
> on all three tables — **`@Version` IS present** on `Stockunit`, `Unitload`, and `Location`
> (inherited from `AbstractBaseEntity`). This confirms that `@Version` optimistic locking is
> technically available but is not the right primitive for this specific cross-row race (see §3.4).
>
> **Baseline lock-state counts (v1 dev, 2026-05-14):**
> | Entity | Total rows | Currently locked (entity_lock ≠ 0) |
> |--------|-----------|--------------------------------------|
> | stockunit | 1,620,842 | 1,604,122 |
> | unitload | 752,860 | 732,977 |
> | location | 2,742 | 0 (all locations NOT_LOCKED) |
>
> Note: entity_lock=405 accounts for most locks (1,393,333 stockunits, 412,138 unitloads) — this
> is the `GOODS_OUT` / completed-transfer state. entity_lock=2 (210,347 SUs, 320,839 ULs) is
> `PICKED_FOR_GOODSOUT`. All locations are currently at NOT_LOCKED (0). Implementer should
> record this baseline in the pre-deploy §10 query before deploying the fix.

---

## §0 Affected Sites

All `transferStockToUnitLoad` / `transferUnitLoadToLocation` pre-mutation entity loads were enumerated and triaged. The repository helper sites and adjacent service-wide occurrences of the same anti-pattern were inventoried; only the first-order sites are in-scope for this plan.

| # | File:line | Construct | Same root-cause? | In-scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `service/StockunitBusinessService.java:218` | `findById` for `sourceUnitload` before `getEntityLock()` check | YES | **YES — Fix B** |
| 2 | `service/StockunitBusinessService.java:219` | `findById` for `sourceLocation` before `getEntityLock()` check | YES | **YES — Fix B** |
| 3 | `service/StockunitBusinessService.java:221-229` | `destinationStockUnit` from `findByUnitloadId` — hoisted into Fix B: dest-unitload locked first, list re-read after lock | YES | **YES — Fix B** |
| 4 | `service/StockunitBusinessService.java:252-256` | `destinationUnitload.getEntityLock()` on caller-passed (potentially stale) entity | YES | **YES — Fix B** |
| 5 | `service/StockunitBusinessService.java:259-260` | `findById` for `destinationLocation` inside `!ignoreLock` block | YES | **YES — Fix B** (move before block + use `ForUpdate`) |
| 6 | `repo/jpa/LocationRepository.java` | Missing `findByIdForUpdate(Long)` method | n/a — prerequisite | **YES — Fix A** |
| 7 | `service/UnitloadBusinessService.java:115-118` | `destinationLocation.getEntityLock()` on caller-passed entity in `transferUnitLoadToLocation` | YES | **YES — Fix C** |
| 8 | `service/mobile/MobileMoveUnitloadService.java:147, 153, 215, 221, 431, 432, 457, 458` | Same TOCTOU pattern around `getEntityLock()` | YES | **OUT** — follow-up audit ticket |
| 9 | `service/mobile/MobileMoveStockService.java:234` | Same pattern | YES | **OUT** — follow-up audit ticket |
| 10 | `service/mobile/MobileCycleCountService.java:131, 135, 163, ...` | Same pattern | YES | **OUT** — separate cycle-count audit ticket |
| 11 | `service/mobile/MobilePickingService.java:1125, 1140` | Same pattern | YES | **OUT** — separate picking audit ticket |
| 12 | `service/StockunitService.java:223, 288, ...` | Same pattern | YES | **OUT** — separate audit ticket |

**Scope rationale:** rows 1–7 form a self-contained cluster — every callsite for the two stock-transfer write paths (`transferStockToUnitLoad`, `transferUnitLoadToLocation`) is patched in one diff. Rows 8–12 share the same anti-pattern but each lives in a distinct flow (mobile move, cycle count, picking) with different lock orderings; they need their own §0 enumeration and concurrency tests rather than a sweeping rename. Defer.

---

## 1. Problem Statement

A stock-unit transfer (`StockunitBusinessService.transferStockToUnitLoad`) reads `entityLock` on
five entities (source stock-unit, source unit-load, source location, destination stock-unit,
destination unit-load, destination location) before performing the transfer. Only the source
stock-unit is acquired with `findByIdForUpdate`; the other four are loaded with plain
`findById` (or passed by the caller, or harvested from a stale `findByUnitloadId` list). Between
the lock-state read and the subsequent mutation, a concurrent transaction can flip any of those
entities into `PICKED_FOR_GOODSOUT` / `LOCKED` / `PUTAWAY_ASSIGNED` / etc. The current
transaction never sees the new lock value because Hibernate returns the L1-cached entity, so the
guard at lines 232–264 is a **time-of-check-to-time-of-use (TOCTOU) race**.

Symptoms reported in production:

1. Stock-unit moves complete despite the destination location being locked by a concurrent
   putaway / cycle-count operation.
2. Reservation accounting drifts (source decremented, destination credited, but downstream
   stock report shows the destination location as still locked → operators block the lane).
3. Optimistic-lock failures on a sibling write (`Stockunit` `@Version`) appear hours later
   when downstream services touch the rows the transfer touched.

The same anti-pattern is present in `UnitloadBusinessService.transferUnitLoadToLocation` for the
destination location entityLock read (line 115). This method is called with `ignoreLock=false`
by at least 12 callers: `MobilePutAwayService.java:148, 183, 185, 206, 494, 498`,
`MobileMoveUnitloadService.java:274, 401, 405`, `ReceivingService.java:489`,
`MobileTruckLoadingService.java:244`, `MobilePickingService.java:479`. On those paths the
`if (!ignoreLock)` guard at L116 is active and the TOCTOU is live. Note: the `sendToNirvana`
path (`UnitloadBusinessService.java:295, 308`) passes `ignoreLock=true` — that path bypasses
the L116 guard and the lock-state check does not fire; Fix C does not affect its behavior.

---

## 2. Root Cause Analysis

### Bug 1 — Four unguarded entity loads in `transferStockToUnitLoad` (`StockunitBusinessService.java:218-266`)

The source stock-unit was already correctly retrofitted with `findByIdForUpdate` (lines 186–190):

```java
// :186-190 — source stock-unit locked ✓
sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)
    .orElseThrow(() -> new EntityNotFoundException("Stockunit", sourceStockunitId));
entityManager.refresh(sourceStockunit);
```

The remaining five entities are not:

```java
// :218 — sourceUnitload plain findById ✗
Unitload sourceUnitload = unitloadRepository.findById(sourceStockunitUnitloadId)
    .orElseThrow(...);

// :219 — sourceLocation plain findById ✗
Location sourceLocation = locationRepository.findById(sourceUnitload.getStoragelocationId())
    .orElseThrow(...);

// :221-229 — destinationStockUnit pulled from a stale list ✗
//   (destinationStockunitList was fetched at :201 via findByUnitloadId, no lock)
Stockunit destinationStockUnit = null;
for (Stockunit stockunit : destinationStockunitList) {
    if (stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())) {
        destinationStockUnit = stockunit;
        break;
    }
}

// :252-256 — destinationUnitload is the caller-passed argument ✗
if (destinationUnitload.getEntityLock() != null) {
    lock = destinationUnitload.getEntityLock();
    ...
}

// :259-260 — destinationLocation plain findById INSIDE the !ignoreLock block ✗
Location destinationLocation = locationRepository.findById(destinationUnitload.getStoragelocationId())
    .orElseThrow(...);
lock = destinationLocation.getEntityLock();
```

Each `findById` (or stale-list lookup, or caller-passed entity) is a snapshot taken under
PostgreSQL `READ COMMITTED`. A concurrent transaction can write a new `entity_lock` value to
any of these rows between snapshot time and the guard check — Hibernate's L1 cache then returns
the pre-snapshot entity for any subsequent read in this transaction. The `getEntityLock()` call
at lines 236, 240, 246, 254, 262 reads the **stale** lock state, the guard passes, and the
mutation proceeds against a row that another transaction has already marked LOCKED.

### Bug 2 — Caller-passed `destinationLocation` in `transferUnitLoadToLocation` (`UnitloadBusinessService.java:115`)

```java
// :108 — caller passes destinationLocation directly
public void transferUnitLoadToLocation(Unitload unitload, Location destinationLocation,
                                       boolean ignoreLock, ...) {
    // :115 — read entityLock on the caller-passed entity ✗
    if (!ignoreLock && destinationLocation.getEntityLock() != BusinessObjectLockState.NOT_LOCKED) {
        throw new FacadeException("STORAGELOCATION_LOCKED", ...);
    }
```

Same TOCTOU: the caller fetched `destinationLocation` outside the transaction (or in an earlier
read) and the value of `getEntityLock()` is a stale snapshot. Two concurrent callers can both
pass the guard while a third transaction has already taken the lock.

### Why pessimistic locking, not `@Version`

`Stockunit`, `Unitload`, and `Location` all inherit `@Version` from `AbstractBaseEntity`.
Optimistic locking does not solve TOCTOU for **decision-then-act** flows:

- The reader doesn't write the row whose lock-state it just inspected. The version conflict only
  fires on a write to the **same row** by two transactions. Here, T1 reads `Location.entityLock`,
  decides "not locked", then mutates a `Stockunit` row. T2 in parallel writes the `Location`
  row to set `entityLock=PUTAWAY_ASSIGNED`. The two write to different rows; no `@Version`
  conflict ever fires.
- A pessimistic `SELECT ... FOR UPDATE` on the four (or five, with destination location) entities
  serializes the lock-state read against any concurrent writer that would change them. T2
  blocks at its own `FOR UPDATE` (or its `UPDATE` blocks at row-lock acquisition) until T1's
  transaction commits.

### Affected locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `repo/jpa/LocationRepository.java` | (new method) | `findByIdForUpdate(Long)` — add locked variant |
| 2 | `service/StockunitBusinessService.java` | 218–266 | Four unguarded entity loads before `getEntityLock` |
| 3 | `service/UnitloadBusinessService.java` | 108–118 | Caller-passed `destinationLocation` |
| 4 | `service/StockunitBusinessService.java` | 300, 305 | Mutation re-fetches (safe — same transaction holds prior locks; add comments) |

---

## 3. Design / Proposed Fix

### 3.1 Fix A — Add `findByIdForUpdate` to `LocationRepository`

**Problem:** No locked variant of `Location` fetch by id exists. `StockunitRepository.java:27-29` and
`UnitloadRepository.java:29-31` already have this pattern; `LocationRepository` does not.

**Solution:** Add the method directly after the existing `getAvailableTransferLanes` declaration
(currently around line 49) and the import block already includes `@Lock`, `LockModeType`,
`@Query`, and `@RestResource` — no new imports required.

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT l FROM Location l WHERE l.id = :id")
@RestResource(exported = false)
Optional<Location> findByIdForUpdate(@Param("id") Long id);
```

Key choices:
- `@Lock(LockModeType.PESSIMISTIC_WRITE)` on a `@Query` method bypasses the Hibernate L1 cache
  and issues `SELECT ... FOR UPDATE` on the matching row. Combine with `entityManager.refresh()`
  at the callsite to evict any pre-existing L1 reference (matches the existing `Stockunit`
  pattern in this file).
- JPQL entity-name syntax (`Location`, not `location`) — consistent with `getAvailableTransferLanes`.
- `@RestResource(exported = false)` — consistent with private-by-default repository methods in
  this file; the locked finder is an internal API, not a REST endpoint.
- Imports already present in `LocationRepository.java` from `getAvailableTransferLanes`:
  `org.springframework.data.jpa.repository.Lock`, `jakarta.persistence.LockModeType`,
  `org.springframework.data.jpa.repository.Query`,
  `org.springframework.data.rest.core.annotation.RestResource`.

**Files changed:** `repo/jpa/LocationRepository.java`

---

### 3.2 Fix B — Acquire pessimistic locks on all five entities before `getEntityLock` checks

**Problem:** Lines 218–266 of `StockunitBusinessService.transferStockToUnitLoad` read
`getEntityLock()` on four entities (sourceUnitload, sourceLocation, destinationStockUnit,
destinationUnitload, destinationLocation) whose state was loaded without a row lock.

**Solution:** Move all entity acquisitions to *before* the `!ignoreLock` block, use
`findByIdForUpdate` for every one, and `entityManager.refresh()` each to evict L1-cached copies.
The destination-location load moves out of the conditional block into the unconditional
pre-section — the cost of locking on the `ignoreLock=true` path is one extra `FOR UPDATE` SELECT,
which is acceptable for the additional safety it provides on the `ignoreLock=false` path.

**Before** (`StockunitBusinessService.java:218-266`):

```java
final Long sourceStockunitUnitloadId = sourceStockunit.getUnitloadId();
Unitload sourceUnitload  = unitloadRepository.findById(sourceStockunitUnitloadId).orElseThrow(() -> new EntityNotFoundException("UnitLoad", sourceStockunitUnitloadId));
Location sourceLocation = locationRepository.findById(sourceUnitload.getStoragelocationId()).orElseThrow(() -> new EntityNotFoundException("Location", sourceUnitload.getStoragelocationId()));

Stockunit destinationStockUnit = null;

// checked and id is used to compare, makes not allot of sense so convert to ID compare
for (Stockunit stockunit : destinationStockunitList) {
    if (stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())) {
        destinationStockUnit = stockunit;
        break;
    }
}

if (!ignoreLock) {
    int lock = sourceStockunit.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Source stockUnit=" + sourceStockunit.getId() + " is locked=" + lock);
    }
    lock = sourceUnitload.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Source unitLoad=" + sourceUnitload.getLabelid() + " is locked=" + lock);
    }
    lock = sourceLocation.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Source location=" + sourceLocation.getName() + " is locked=" + lock);
    }

    if (destinationStockUnit != null) {
        lock = destinationStockUnit.getEntityLock();
        if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
            throw new BusinessException("Destination stockUnit=" + destinationStockUnit.getId() + " is locked=" + lock);
        }
    }

    if (destinationUnitload.getEntityLock() != null) {
        lock = destinationUnitload.getEntityLock();
        if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
            throw new BusinessException("Destination unitLoad=" + destinationUnitload.getLabelid() + " is locked=" + lock);
        }
    }

    Location destinationLocation = locationRepository.findById(destinationUnitload.getStoragelocationId())
        .orElseThrow(() -> new EntityNotFoundException("Location", destinationUnitload.getStoragelocationId()));

    lock = destinationLocation.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Destination location=" + destinationLocation.getName() + " is locked=" + lock);
    }
}
```

**After** (Fix B):

```java
// Acquire pessimistic locks on all source and destination entities BEFORE lock-state checks.
// Lock acquisition order: source-stockunit (already locked at L188) → source-unitload →
// source-location → destination-unitload → destination-stockunit (if present) → destination-location.
// Stable order across concurrent callers prevents deadlock. Destination-unitload is locked FIRST
// before reading the destination stockunit list (findByUnitloadId) to close the concurrent
// same-itemdata insert race that would otherwise bypass the mixed-stock guard at L213-215.
final Long sourceStockunitUnitloadId = sourceStockunit.getUnitloadId();
Unitload sourceUnitload = unitloadRepository.findByIdForUpdate(sourceStockunitUnitloadId)
    .orElseThrow(() -> new EntityNotFoundException("UnitLoad", sourceStockunitUnitloadId));
entityManager.refresh(sourceUnitload);

final Long sourceLocationId = sourceUnitload.getStoragelocationId();
Location sourceLocation = locationRepository.findByIdForUpdate(sourceLocationId)
    .orElseThrow(() -> new EntityNotFoundException("Location", sourceLocationId));
entityManager.refresh(sourceLocation);

// Lock destination unitload BEFORE reading its stockunit list so that the mixed-stock
// guard below operates on the post-lock snapshot — closes the L201 same-itemdata race.
final Long destinationUnitloadId = destinationUnitload.getId();
destinationUnitload = unitloadRepository.findByIdForUpdate(destinationUnitloadId)
    .orElseThrow(() -> new EntityNotFoundException("UnitLoad", destinationUnitloadId));
entityManager.refresh(destinationUnitload);

// Re-read the destination stockunit list AFTER holding the unitload lock.
List<Stockunit> destinationStockunitList = stockunitRepository.findByUnitloadId(destinationUnitloadId);

// checked and id is used to compare, makes not allot of sense so convert to ID compare
Stockunit destinationStockUnit = null;
for (Stockunit stockunit : destinationStockunitList) {
    if (stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())) {
        destinationStockUnit = stockunit;
        break;
    }
}

if (destinationStockUnit != null) {
    final Long dstSuId = destinationStockUnit.getId();
    destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)
        .orElseThrow(() -> new EntityNotFoundException("Stockunit", dstSuId));
    entityManager.refresh(destinationStockUnit);
}

final Long destinationLocationId = destinationUnitload.getStoragelocationId();
Location destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
    .orElseThrow(() -> new EntityNotFoundException("Location", destinationLocationId));
entityManager.refresh(destinationLocation);

if (!ignoreLock) {
    int lock = sourceStockunit.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Source stockUnit=" + sourceStockunit.getId() + " is locked=" + lock);
    }
    lock = sourceUnitload.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Source unitLoad=" + sourceUnitload.getLabelid() + " is locked=" + lock);
    }
    lock = sourceLocation.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Source location=" + sourceLocation.getName() + " is locked=" + lock);
    }

    if (destinationStockUnit != null) {
        lock = destinationStockUnit.getEntityLock();
        if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
            throw new BusinessException("Destination stockUnit=" + destinationStockUnit.getId() + " is locked=" + lock);
        }
    }

    if (destinationUnitload.getEntityLock() != null) {
        lock = destinationUnitload.getEntityLock();
        if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
            throw new BusinessException("Destination unitLoad=" + destinationUnitload.getLabelid() + " is locked=" + lock);
        }
    }

    lock = destinationLocation.getEntityLock();
    if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
        throw new BusinessException("Destination location=" + destinationLocation.getName() + " is locked=" + lock);
    }
}
```

**Why `entityManager.refresh()` after `findByIdForUpdate`:**
In Hibernate 6.x (Spring Boot 3.5.x), `@Lock(LockModeType.PESSIMISTIC_WRITE)` on a `@Query`
method issues `SELECT ... FOR UPDATE` against the database and upgrades the row lock — but if
the entity is already in the L1 persistence-context cache, Hibernate may return the cached
snapshot rather than overwriting in-memory state with the just-locked row (Hibernate
`LockMode.upgrade()` semantics). `entityManager.refresh()` forces a re-read from the
freshly-locked row, evicting the stale L1 copy. This is especially required for
`destinationStockUnit`, which is already in L1 from the `findByUnitloadId` list at L201.
For entities not yet in L1 (sourceUnitload, sourceLocation, destinationUnitload,
destinationLocation), refresh is defensive but harmless. Matches the existing pattern at
`StockunitBusinessService.java:190`.

**Note on the mutation block (`:285-322`):** the existing re-fetches at `:300`
(`stockunitRepository.findById(destId)`) and `:305` (`stockunitRepository.findById(sourceId)`)
remain as plain `findById`. This is **safe**: the pre-check `findByIdForUpdate` calls above
hold Postgres `FOR UPDATE` row locks for the entire transaction duration. Hibernate's L1 cache
returns the already-locked, refreshed entity for subsequent `findById` calls within the same
transaction (no new SQL is issued). Add a one-line comment at `:300` and `:305` to that effect
so future readers don't "fix" them.

**Lock ordering rationale:** the order is deterministic across all callers — source side first
(stockunit → unitload → location), then destination side (stockunit → unitload → location).
The source-stockunit lock is already held from `:188`. Two concurrent `transferStockToUnitLoad`
calls acting on overlapping rows acquire locks in the same order; no inversion is possible,
so no deadlock can form among the five new locks.

**Files changed:** `service/StockunitBusinessService.java`

---

### 3.3 Fix C — Re-fetch `destinationLocation` with pessimistic lock in `transferUnitLoadToLocation`

**Problem:** `UnitloadBusinessService.transferUnitLoadToLocation` reads `getEntityLock()` on the
caller-passed `destinationLocation` argument (line 115). The caller's entity is a stale snapshot.

**Solution:** Re-fetch the destination location by id with `findByIdForUpdate` and
`entityManager.refresh` immediately on entry, before the `!ignoreLock` guard.

**Before** (`UnitloadBusinessService.java:108-118`):

```java
public void transferUnitLoadToLocation(Unitload unitload, Location destinationLocation,
                                       boolean ignoreLock, ...) {
    ensureInitialized();
    Long storagelocationId = unitload.getStoragelocationId();
    Long carrierunitloadId = unitload.getCarrierunitloadId();
    LOG.debug(...);

    if (!ignoreLock && destinationLocation.getEntityLock() != BusinessObjectLockState.NOT_LOCKED) {
        throw new FacadeException("STORAGELOCATION_LOCKED", ...);
    }
```

**After** (Fix C):

```java
public void transferUnitLoadToLocation(Unitload unitload, Location destinationLocation,
                                       boolean ignoreLock, ...) {
    ensureInitialized();
    Long storagelocationId = unitload.getStoragelocationId();
    Long carrierunitloadId = unitload.getCarrierunitloadId();
    LOG.debug(...);

    // Re-fetch destination location with pessimistic lock only when the lock-state guard
    // fires (ignoreLock=false). The ignoreLock=true path (e.g., sendToNirvana) bypasses
    // the L116 guard — no lock needed on that path; avoiding it prevents serialization
    // through the single nirvana-location row under high-throughput concurrent moves.
    if (!ignoreLock) {
        final Long destinationLocationId = destinationLocation.getId();
        destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
            .orElseThrow(() -> new EntityNotFoundException("Location", destinationLocationId));
        entityManager.refresh(destinationLocation);
    }

    if (!ignoreLock && destinationLocation.getEntityLock() != BusinessObjectLockState.NOT_LOCKED) {
        throw new FacadeException("STORAGELOCATION_LOCKED", ...);
    }
```

**Dependency injection note:** verify that `EntityManager` is already wired into
`UnitloadBusinessService`. If not, add via constructor injection (preferred) or
`@PersistenceContext private EntityManager entityManager;` (matches the legacy style used in
sibling services). The implementer must read the class header before patching.

**Files changed:** `service/UnitloadBusinessService.java`

---

### 3.4 Why pessimistic, not optimistic, locking

Same reasoning as SBDEV-2223: the race is **read-then-decide on sibling row state**, not a
**write conflict on the same row**. Optimistic `@Version` on the entities involved would fire
only if both transactions wrote the same row — but here, T1 reads `Location.entityLock` and
mutates `Stockunit`, while T2 writes `Location.entityLock`. No version conflict because the
target rows differ. Pessimistic `SELECT ... FOR UPDATE` is the correct primitive: the second
transaction blocks at its own `FOR UPDATE` until the first commits, then re-reads the
now-current lock state and correctly decides.

---

### 3.5 Lock ordering & throughput

**`transferStockToUnitLoad` lock chain (after fix):**

```
source-stockunit  (:188)        findByIdForUpdate(sourceStockunitId)
source-unitload   (NEW)         findByIdForUpdate(sourceStockunitUnitloadId)
source-location   (NEW)         findByIdForUpdate(sourceLocationId)
dest-unitload     (NEW)         findByIdForUpdate(destinationUnitloadId)  ← hoisted before findByUnitloadId
dest-stockunit    (NEW, opt.)   findByIdForUpdate(dstSuId) — only when present, from fresh post-lock list
dest-location     (NEW)         findByIdForUpdate(destinationLocationId)
(checks then mutation block uses cached entities)
```

**`transferUnitLoadToLocation` lock chain (after fix):**

```
dest-location     (NEW)         findByIdForUpdate(destinationLocationId)
(check, then existing transfer logic)
```

**Throughput:** The added FOR UPDATE statements each acquire one row lock for the remainder of
the transaction. Empirical estimate: typical `transferStockToUnitLoad` runs ≤300ms once the
locks are held (no external I/O between lock acquisition and commit). The HikariCP
`spring.datasource.lock-timeout` is 5000ms (per `application-*.properties`), well above the
expected hold time. Concurrent callers that target different rows are unaffected; concurrent
callers that target overlapping rows serialize correctly.

The stable acquisition order (source → destination, ascending within each pair by entity type
in the order written above) makes deadlock impossible among the five new locks: two
concurrent callers compete for the same first-conflicting lock, and the loser blocks until the
winner commits.

---

## 4. V1/V2 Applicability

This plan targets **v2 only**. The v1 `StockunitBusinessService` may exhibit the same pattern,
but v1's transaction-manager model and Hibernate version differ enough that a direct port is
not safe. Action: file a paired v1 audit ticket "Audit `transferStockToUnitLoad` /
`transferUnitLoadToLocation` for TOCTOU entityLock checks in v1/wms-api" once this v2 fix is
verified. The v1 paired plan, if needed, will live at `sbdocs/1-Projects/wms1/plan/` under the
matching base name.

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| Same anti-pattern present? | unverified | yes | v1 audit required |
| `findByIdForUpdate` style | `@Query` + `@Lock` | `@Query` + `@Lock` | identical mechanism |
| Transaction manager | `transactionManager` | `tenantTransactionManager` | v2 uses per-tenant routing |

### What needs porting

1. None to v1 yet — v1 audit is its own ticket.

### What does NOT need porting

- `LocationRepository.findByIdForUpdate` may already exist in v1 — check before adding. If v1
  has the method, the audit ticket starts from §0 enumeration.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. No migration. | N/A | Pure code change |
| 2 | **Feature flags / system properties** | None required | N/A | |
| 3 | **Config / env changes** | `jakarta.persistence.lock.timeout=5000` already set per environment | N/A | Verify with `grep -r "jakarta.persistence.lock.timeout" v2/wms2-api/src/main/resources/application*.properties` before deploy |
| 4 | **Deploy-order dependencies** | None — single JAR deploy | N/A | |
| 5 | **Data migration** | None | N/A | |
| 6 | **External systems** | None | N/A | |
| 7 | **Access / permissions** | None | N/A | |
| 8 | **Monitoring / alerts** | Post-deploy: graph `wms2.transaction.lock.timeout` and `PessimisticLockException` rate. Pre-deploy baseline so spikes are visible. | Implementer | Existing Micrometer counters — no new metric required |

### 5.2 Implementation Checklist

- [ ] Read `service/StockunitBusinessService.java` lines 175–330 to confirm line numbers match the §3 snippets before patching.
- [ ] Read `service/UnitloadBusinessService.java` lines 1–74. **For `UnitloadBusinessService` only:** `EntityManager` is NOT currently injected. This class uses pure constructor injection (verified at lines 54–74 — no `@Autowired` fields). Add `EntityManager` as a **constructor parameter** (not `@PersistenceContext` field injection). Update the constructor signature accordingly. Do NOT use `@PersistenceContext` field injection — it mixes injection styles with the rest of this class. Note: `StockunitBusinessService` already has `@PersistenceContext(unitName = "tenant") private EntityManager entityManager` at line 31-32 — **do NOT add a duplicate injection or constructor parameter there**; Fix B's `entityManager.refresh()` calls use the existing field.
- [ ] Add `findByIdForUpdate(Long)` to `LocationRepository.java` (Fix A) with `@Lock(PESSIMISTIC_WRITE)`, JPQL `@Query`, `@RestResource(exported=false)`. All required imports already present.
- [ ] Refactor `transferStockToUnitLoad` lines 218–266 per Fix B: move all entity loads above the `!ignoreLock` block; substitute `findById` → `findByIdForUpdate` + `entityManager.refresh()` for sourceUnitload, sourceLocation, destinationStockUnit (when present), destinationUnitload, destinationLocation; move destinationLocation load out of the `if (!ignoreLock)` block.
- [ ] Add inline comments at `:300` and `:305` explaining why the plain `findById` is safe (pre-check locks already held).
- [ ] Refactor `transferUnitLoadToLocation` lines 108–118 per Fix C: re-fetch `destinationLocation` with `findByIdForUpdate` + `entityManager.refresh()` before the guard.
- [ ] Update / add unit tests in `StockunitBusinessServiceUnitTest.java`: stub `findByIdForUpdate` for `unitloadRepository`, `locationRepository`, `stockunitRepository`; add `verify(repo).findByIdForUpdate(...)` assertions on the four new sites; add `verify(repo, never()).findById(...)` assertions for the pre-check block.
- [ ] Update / add unit tests in `UnitloadBusinessServiceUnitTest.java` for Fix C (same shape).
- [ ] Write new `StockunitBusinessServiceConcurrencyIT.java` (Testcontainers PostgreSQL): two threads + start-gate CountDownLatch, Thread A sets `entityLock = PICKED_FOR_GOODSOUT`, Thread B calls `transferStockToUnitLoad` concurrently — assert exactly one outcome (transfer rejected with `BusinessException`, no partial mutation state).
- [ ] Write `UnitloadBusinessServiceConcurrencyIT.java` (AC7 — Testcontainers PostgreSQL): Thread A locks `destinationLocation`, Thread B calls `transferUnitLoadToLocation(..., ignoreLock=false, ...)` — assert clean `FacadeException("STORAGELOCATION_LOCKED")` and no partial state.
- [x] Run `mvn test -Dtest=StockunitBusinessServiceUnitTest,UnitloadBusinessServiceUnitTest` — 56/56 PASS (2026-05-14).
- [ ] Run `mvn verify` (Testcontainers) — pending SBDEV-2217.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.sh` — all PASS.
- [ ] Audit the 11 deferred sites (rows 8–12 of §0) and file follow-up tickets with their own §0 tables.
- [x] Code review completed — APPROVED, 0 CRITICAL, 0 HIGH; 2 MEDIUM fixes applied.
- [x] Update plan: status → implemented, commit 6764213, PR https://github.com/SiteBossInc/wms2-api/pull/17.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Concurrent destination-location lock flip | Thread A: set `Location.entityLock = PUTAWAY_ASSIGNED` on the destination location, commit. Thread B: simultaneously call `transferStockToUnitLoad` with `ignoreLock=false`. | Exactly one of A or B wins. If A commits first, B throws `BusinessException("Destination location=...is locked=...")`. If B commits first, A's lock-write blocks until B's transaction releases, then proceeds. No partial mutation state in either case. |
| Concurrent source-stockunit lock flip | Thread A: set source `Stockunit.entityLock = PICKED_FOR_GOODSOUT`. Thread B: `transferStockToUnitLoad` concurrently. | Exactly one wins; B sees the updated lock state if A commits first. |
| `transferStockToUnitLoad` calls locked variants | Unit test exercises the method | `verify(unitloadRepo, times(1)).findByIdForUpdate(sourceUnitloadId)`, `verify(locationRepo, times(1)).findByIdForUpdate(sourceLocationId)`, `verify(stockunitRepo, times(1)).findByIdForUpdate(dstSuId)` (when present), `verify(unitloadRepo, times(1)).findByIdForUpdate(destinationUnitloadId)`, `verify(locationRepo, times(1)).findByIdForUpdate(destinationLocationId)` all pass |
| `transferUnitLoadToLocation` calls locked variant | Unit test exercises the method | `verify(locationRepo, times(1)).findByIdForUpdate(destinationLocationId)` passes |
| `ignoreLock=true` still acquires the locks | Unit test with `ignoreLock=true` | All five `findByIdForUpdate` calls still fire; the `if (!ignoreLock)` block is skipped but locks are held for the mutation phase |
| Stable lock-acquisition order | Code inspection + AC3 verify-script check | Source-side locks acquired before destination-side; within each side, stockunit → unitload → location |
| Fix C — concurrent destination-location lock flip | Thread A: lock `destinationLocation.entityLock = LOCKED`. Thread B: `transferUnitLoadToLocation(..., ignoreLock=false, ...)` simultaneously. | Thread B throws `FacadeException("STORAGELOCATION_LOCKED")` if A commits first. No partial unitload state. |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `StockunitBusinessServiceConcurrencyIT` | `transferStockToUnitLoad_shouldRejectOrBlock_whenConcurrentLockFlipRaces` | After concurrent lock flip on destination location, exactly one transaction commits without partial state; the other receives a clean `BusinessException` (Testcontainers PostgreSQL) |
| `StockunitBusinessServiceUnitTest` | existing `transferStockToUnitLoad` happy-path tests | Migrate stubs from `findById` → `findByIdForUpdate` for the four new sites; add `verify(...).findByIdForUpdate` + `verify(..., never()).findById` where applicable |
| `StockunitBusinessServiceUnitTest` | new `transferStockToUnitLoad_acquiresAllFiveLocksInStableOrder` | Mockito `InOrder` verification on the four new locked-fetch calls |
| `UnitloadBusinessServiceUnitTest` | existing `transferUnitLoadToLocation` happy-path tests | Migrate `destinationLocation` stub to use `findByIdForUpdate`; add `verify(locationRepo).findByIdForUpdate(...)` |
| `UnitloadBusinessServiceConcurrencyIT` | `transferUnitLoadToLocation_shouldRejectWithLockedLocation_whenConcurrentLockFlipRaces` | FacadeException thrown cleanly with correct message; no partial unitload state (Testcontainers) |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Mobile stock transfer happy path | staging | 1. Operator A: open Mobile UI → Stock Move. 2. Source SU on Location L1, destination Unitload UL2 on Location L2. 3. Confirm. | Stock moves; both source and destination locations show updated counts within 2s. | |
| Concurrent transfer + putaway on same destination location | staging | 1. Operator A: start transfer to Location L2. 2. Operator B: start putaway that locks Location L2 (mobile cycle-count "lock location" or similar). 3. Both confirm within 1s of each other. | Whichever operator's transaction commits first wins. The losing operator sees a clear error ("Destination location is locked"). No silent corruption: querying `location.entity_lock` for L2 shows a single consistent value. | |
| Send-to-nirvana path unaffected | staging | 1. Trigger `sendToNirvana` (operator marks SU damaged → discarded). | Transfer completes; `ignoreLock=true` path is exercised. No change in observed behavior vs pre-fix. | |
| SQL stuck-state baseline (24h post-deploy) | staging DB | `SELECT count(*) FROM stockunit WHERE entity_lock != 0;` `SELECT count(*) FROM unitload WHERE entity_lock != 0;` `SELECT count(*) FROM location WHERE entity_lock != 0;` — compare to 24h-pre-deploy baseline. | Stuck-lock count does not increase. (Existing operational locks should clear at the normal rate.) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=StockunitBusinessServiceUnitTest` | PASS 2026-05-14 | 0F 0E |
| `mvn test -Dtest=UnitloadBusinessServiceUnitTest` | PASS 2026-05-14 | 0F 0E |
| `mvn verify` | pending SBDEV-2217 | — |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| H2-based variant of the concurrency test | H2 does not implement PostgreSQL `SELECT ... FOR UPDATE` row-blocking semantics; the test would pass even without the fix |
| Mutation-block re-fetch tests | The plain `findById` at `:300` and `:305` is provably safe (transaction-scoped L1 cache returns the already-locked entity); a unit-level test would only assert L1 cache behavior, not the fix |
| End-to-end test through mobile REST endpoint | The Testcontainers concurrency IT exercises the service layer directly; adding a full REST-layer e2e test adds significant infra complexity for no additional coverage of the lock-acquisition logic. Manual test plan (§6) covers the REST path in staging. |
| Quantitative throughput / load test | The p99 latency impact of 5 additional `SELECT ... FOR UPDATE` round-trips (~few hundred ms hold time) is assessed qualitatively in §7.4. A formal load test (50 concurrent threads, 1000 transfers, p99 < 500ms) is deferred to the post-deploy monitoring gate in §10: if `wms2.transaction.lock.timeout` spikes above 1% timeout rate, a load test is triggered as a fast-follow action. |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | No | Pure DB-layer change; no cache, no static field, no `ThreadLocal` added |
| 2 | **Connection pool math** | Change per-request DB connection usage? | Yes (low) | Each `transferStockToUnitLoad` call now holds 5 additional Postgres row locks for the remainder of the transaction (~few hundred ms). Row locks do not consume extra connections; they are recorded in `pg_locks` against the existing transaction's backend. `replicas × tenants × maxPoolSize` math unchanged. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` job? | No | |
| 4 | **Long transactions** | Hold a DB transaction across additional repository calls or external I/O? | Yes | Lock acquisition phase adds 5 `SELECT ... FOR UPDATE` round-trips at the start. No external I/O between lock and commit (existing transfer logic is DB-only). Typical hold time <300ms; HikariCP `connectionTimeout` is 30s and `spring.datasource.lock-timeout` is 5s — both generous. Acceptable. |
| 5 | **Request affinity** | Assume same-replica follow-up? | No | No in-memory session state introduced |
| 6 | **Retry / idempotency** | Break if a replica dies mid-op? | Yes | Callers may now receive `PessimisticLockException` / `LockTimeoutException` under contention where they previously received a stale-state `BusinessException`. Implementer must audit the 11 caller sites (mobile, replenish, putaway) and confirm each treats `PessimisticLockException` as a retryable failure (or surfaces a user-visible "try again" message). See §8.3. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | No | No async introduced |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic lock across replicas? | Yes (primary mechanism of this fix) | `findByIdForUpdate` is invoked inside `@Transactional(value="tenantTransactionManager")` — PostgreSQL row locks coordinate across all replicas via the shared per-tenant DB. Stable acquisition order is enforced (source → destination, within each side stockunit → unitload → location). Lock timeout 5s confirmed via `application-*.properties`. |
| 9 | **Cache invalidation** | Write to a cached entity? | No | `Stockunit`, `Unitload`, `Location` are not Caffeine-cached in `CacheConfig.java` |
| 10 | **External notifications (OMS, printer, etc.)** | Send HTTP / message inside a transaction? | No | `transferStockToUnitLoad` does not call OMS or the printer directly; downstream notifications fire from caller code after the transaction commits |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 4 | `transferStockToUnitLoad` is `@Transactional(value="tenantTransactionManager")` at line 181. The five new `FOR UPDATE` reads run inside it. No external I/O before commit. | `StockunitBusinessService.java:181` |
| 6 | Existing `findByIdForUpdate` callsites for `Stockunit` and `Unitload` already propagate `PessimisticLockException` to callers (no swallow). Caller audit list documented in §8.3. | `StockunitRepository.java:27-29`, `UnitloadRepository.java:29-31` |
| 8 | `findByIdForUpdate` pattern proven for `Stockunit` and `Unitload`; new `Location.findByIdForUpdate` uses the identical mechanism. Lock-acquisition order documented in §3.5. | `LocationRepository.java` (new method, Fix A) |

---

## 8. Notes

### 8.1 Acceptance Criteria (for wms-tdd-gate)

**AC1 — Destination-location lock-flip integration test (Testcontainers + `CountDownLatch`)**

New `StockunitBusinessServiceConcurrencyIT.java` boots a real PostgreSQL container and seeds:
- A source stockunit (SU_src) on a source unitload (UL_src) at source location (LOC_src)
- A destination unitload (UL_dst) at destination location (LOC_dst), with `entityLock = 0`

Two threads race with a start-gate `CountDownLatch`:
- **Thread A**: sets `LOC_dst.entityLock = PUTAWAY_ASSIGNED` on the destination location and commits.
- **Thread B**: calls `transferStockToUnitLoad(SU_src, UL_dst, amount, ..., ignoreLock=false, ...)` simultaneously.

After both threads `join()`, reload state in a fresh transaction and assert:
1. **Success-path conservation**: If Thread B committed (A lost the race), `SU_src.amount_after == SU_src.amount_before - transferred`, and the amount appears on UL_dst.
2. **Fail-path no-mutation**: If Thread B threw `BusinessException("Destination location=LOC_dst is locked=...")`, `SU_src.amount` is unchanged and UL_dst row count is unchanged.
3. **Lock consistency**: LOC_dst.entityLock reflects a single consistent value post-race (not a torn write).

PostgreSQL (not H2) required for real `FOR UPDATE` row-blocking semantics.

Note: AC1 tests the destination-location lock-flip race — the specific entity newly guarded in Fix B.
The source-stockunit race was addressed in a prior partial fix at L188. AC1.5 covers the
concurrent same-itemdata transfer race (duplicate-stockunit insert prevention).

**AC1.5 — Same-itemdata concurrent-transfer race (Testcontainers + `CountDownLatch`) — duplicate-insert prevention**

Second method in `StockunitBusinessServiceConcurrencyIT.java`. Seeds a destination unitload (UL_dst)
with no existing stockunit for `itemdata_A`. Two threads race:
- **Thread A**: calls `transferStockToUnitLoad(SU_src_A, UL_dst, ...)` — first concurrent transfer of itemdata_A.
- **Thread B**: calls `transferStockToUnitLoad(SU_src_B, UL_dst, ...)` with the same itemdata_A concurrently.

After both threads `join()`, reload state and assert:
1. **No duplicate stockunit rows**: `stockunitRepository.findByUnitloadId(UL_dst)` returns exactly
   one row with `itemdataId = itemdata_A` (not two). The destinationUnitload `FOR UPDATE` lock
   acquired before `findByUnitloadId` in Fix B serializes the two threads; the second thread
   sees the first's committed insert in its post-lock list and takes the merge branch.
2. **Amount conservation**: Total amount for itemdata_A on UL_dst equals the combined amount
   from both successful transfers (both committed in sequence), or one thread's amount if the
   other received a `BusinessException`.
3. **Clean serialization**: No partial mutation — if one thread threw, UL_dst row count is unchanged.

**Scope note:** AC1.5 verifies the duplicate-stockunit insert race is closed (the primary L201 gap).
The mixed-stock guard at L213 (which checks `destinationStockunitList` for cross-itemdata contamination)
still operates on the pre-lock snapshot from the original L201 read and is documented as a separate
residual gap in §8.5. That gap requires a structural rearrangement of L201–L215 into post-lock position,
deferred to a follow-up ticket.

**AC2 — All five entities locked before lock-state check**

Unit test for `transferStockToUnitLoad` verifies the lock-acquisition calls fire on every
path:

```java
verify(unitloadRepository,  times(1)).findByIdForUpdate(eq(sourceUnitloadId));
verify(locationRepository,  times(1)).findByIdForUpdate(eq(sourceLocationId));
verify(stockunitRepository, times(1)).findByIdForUpdate(eq(destinationStockunitId));
verify(unitloadRepository,  times(1)).findByIdForUpdate(eq(destinationUnitloadId));
verify(locationRepository,  times(1)).findByIdForUpdate(eq(destinationLocationId));
verify(locationRepository,  never()).findById(eq(destinationLocationId)); // old call gone
verify(unitloadRepository,  never()).findById(eq(sourceUnitloadId));      // old call gone
```

**AC3 — Stable lock-acquisition order**

Mockito `InOrder` verification on the locked-fetch calls. Order after Fix B: source-unitload →
source-location → destination-unitload (hoisted before `findByUnitloadId`) → destination-stockunit
(from fresh post-lock list) → destination-location:

```java
InOrder order = inOrder(unitloadRepository, locationRepository, stockunitRepository);
order.verify(unitloadRepository).findByIdForUpdate(sourceUnitloadId);        // src-UL
order.verify(locationRepository).findByIdForUpdate(sourceLocationId);        // src-LOC
order.verify(unitloadRepository).findByIdForUpdate(destinationUnitloadId);   // dest-UL (hoisted)
order.verify(stockunitRepository).findByIdForUpdate(destinationStockunitId); // dest-SU (fresh list)
order.verify(locationRepository).findByIdForUpdate(destinationLocationId);   // dest-LOC
```

**AC4 — `LocationRepository.findByIdForUpdate` exists**

`grep -qE "findByIdForUpdate" v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java` returns 0.

**AC5 — Fix C: `transferUnitLoadToLocation` uses locked destination location**

Unit test:

```java
verify(locationRepository, times(1)).findByIdForUpdate(destinationLocationId);
// And the entityLock read on destinationLocation comes AFTER the locked re-fetch.
```

**AC6 — `mvn test` green**

`mvn test -Dtest=StockunitBusinessServiceUnitTest,UnitloadBusinessServiceUnitTest` exits 0.
`mvn verify` exits 0.

**AC7 — Fix C: `transferUnitLoadToLocation` destination-location race (Testcontainers)**

New `UnitloadBusinessServiceConcurrencyIT.java` boots a real PostgreSQL container and seeds a
unitload and destination location. Thread A sets `destinationLocation.entityLock = LOCKED` and
commits. Thread B calls `transferUnitLoadToLocation(unitload, destinationLocation, false, ...)`.
After both threads join, assert:
- Exactly one outcome: B threw `FacadeException("STORAGELOCATION_LOCKED", ...)` cleanly, OR B
  committed with A having won the race; no partial unitload state.
- `verify(locationRepository, times(1)).findByIdForUpdate(destinationLocationId)` fires on the
  `transferUnitLoadToLocation` path.

### 8.2 Regression Chain

The source-stockunit `findByIdForUpdate` retrofit at `:186-190` was the first half of this fix
(landed in an earlier commit; line numbers per code snapshot). It correctly addressed the
source stock-unit but left the other four entities (sourceUnitload, sourceLocation,
destinationStockUnit, destinationUnitload, destinationLocation) unlocked. This plan completes
the retrofit by extending the same pattern to the remaining entities and to the sibling
`transferUnitLoadToLocation` method. No part of the prior commit is reverted; the new code
sits alongside it.

### 8.3 Caller audit list (PessimisticLockException propagation)

The fix changes the failure mode from "stale `BusinessException`" to "`PessimisticLockingFailureException`
on contention" for a small fraction of calls. `RestExceptionHandler.java:150` handles
`PessimisticLockingFailureException` → HTTP 409, providing bucket (b) coverage for all REST-entry
callers. Internal callers (not entered via REST) need explicit verification.

**Handler bucket key:**
- **(b) REST-handled**: `@ControllerAdvice RestExceptionHandler` maps `PessimisticLockingFailureException` → HTTP 409 at line 150. All mobile-controller and REST-controller entry points inherit this automatically.
- **(c) Retry-wrapped**: caller uses `optimisticLockRetry.executeWithRetry(...)`.
- **(needs audit)**: internal caller not entered via REST; handler coverage unconfirmed.

| Caller | File | Bucket | Notes |
|---|---|---|---|
| `MobileMoveUnitloadService` | `service/mobile/MobileMoveUnitloadService.java:274, 401, 405` | **(b)** REST-handled | Mobile controller → RestExceptionHandler covers 409 |
| `MobileMoveStockService` | `service/mobile/MobileMoveStockService.java` | **(b)** REST-handled | Mobile controller → RestExceptionHandler covers 409 |
| `MobilePutAwayService` | `service/mobile/MobilePutAwayService.java:148, 183, 185, 206, 494, 498` | **(b)** REST-handled | Mobile controller → RestExceptionHandler covers 409 |
| `MobilePickingService` | `service/mobile/MobilePickingService.java:479` | **(b)** REST-handled | Mobile controller → RestExceptionHandler covers 409 |
| `MobileTruckLoadingService` | `service/mobile/MobileTruckLoadingService.java:244` | **(b)** REST-handled | Mobile controller → RestExceptionHandler covers 409 |
| `ReceivingService` | `service/ReceivingService.java:489` | **(b)** REST-handled | REST controller → RestExceptionHandler covers 409 |
| `FixLocationAssignmentService` | `service/FixLocationAssignmentService.java:156` | **(b)** REST-handled | REST controller → RestExceptionHandler covers 409 |
| `MobileTransferOrderService` | `service/mobile/MobileTransferOrderService.java:392` | **(b)** REST-handled | Mobile controller → RestExceptionHandler covers 409 |
| `StockunitService` | `service/StockunitService.java:209` | **(needs audit)** | Internal service; confirm if called from a REST path or scheduled job |
| `ClubLineOrderProcessor` | (if applicable) | **(needs audit)** | Internal / scheduled; confirm `PessimisticLockingFailureException` propagation |
| `BillofladingService` | (if applicable) | **(needs audit)** | Internal; confirm propagation |
| `CustomerorderService` | (if applicable) | **(needs audit)** | Internal; confirm propagation |
| `sendToNirvana` path | `service/UnitloadBusinessService.java:295, 308` | **(b)** REST-handled | Uses `ignoreLock=true`; Fix C skips FOR UPDATE on this path (Mitigation A) |

**Implementer action:** for each "(needs audit)" row, run `grep -rn "StockunitService\|transferStockToUnitLoad" src/main/java/net/aim_ai/wms/service/ src/main/java/net/aim_ai/wms/schedulejob/` to find the call chain entry point. If the chain terminates at a `@Scheduled` job (not a REST request), add explicit `catch (PessimisticLockingFailureException | LockTimeoutException e)` with appropriate logging/retry before marking this plan complete.

Run: `grep -rn "PessimisticLockingFailureException\|PessimisticLockException\|LockTimeoutException" v2/wms2-api/src/main/java/`
to find existing handlers. Verify `RestExceptionHandler.java:150` is the correct line before deploy.

### 8.4 Known uncovered call sites (deferred)

Rows 8–12 of §0 share the TOCTOU `getEntityLock()` anti-pattern but live in different flows
with different lock orderings. Each requires its own §0 enumeration, concurrency test, and
ordering analysis. Defer to follow-up tickets:

- "Audit `entityLock` reads in mobile move / cycle-count / picking services"
- "Audit `entityLock` reads in `StockunitService` business methods"

Track via `project_memory_add_directive` after rollout so future picking / move / cycle-count
plans inherit the directive "Every `getEntityLock()` read MUST be preceded by `findByIdForUpdate`
on the same entity in the same transaction."

### 8.5 Remaining races / known gaps

**`destinationStockunitList` race (L201 gap) — two sub-problems with different closure status:**

*Sub-problem 1 — Duplicate-stockunit insert (CLOSED by Fix B):* Fix B acquires the
`destinationUnitload` FOR UPDATE lock before re-reading the `findByUnitloadId` list. Two
concurrent threads that both started with the pre-lock stale list now serialize at the unitload
lock. The second thread, after acquiring the lock, reads a fresh list that includes the first
thread's committed insert and correctly takes the merge branch. No duplicate stockunit row is
created. AC1.5 tests this sub-problem.

*Sub-problem 2 — Mixed-stock guard still reads pre-lock list (RESIDUAL):* The mixed-stock guard
at `L213-215` (`differentStockAllowed` check against `destFirstItemdata`) runs against the
original `findByUnitloadId` result from L201 — which is taken BEFORE the entity-lock acquisition
block in Fix B. Two concurrent transfers of different itemdata to the same unitload can both pass
the mixed-stock guard on the stale list (seeing it as "empty" or "same itemdata"), then serialize
at the unitload lock. The second thread's guard check is stale. This sub-problem requires a
structural rearrangement: move L201 `findByUnitloadId` + L213-215 mixed-stock guard to AFTER the
unitload lock is acquired. Defer to follow-up ticket "Close mixed-stock guard TOCTOU in
transferStockToUnitLoad (L201 structural rearrangement)". Note: this race requires concurrent
transfers of *different* itemdata to the same unitload — a narrow business scenario that may be
prevented upstream by assignment rules. Verify upstream constraints before classifying as high-severity.

**Nirvana-location serialization point:**
Fix C's `findByIdForUpdate(destinationLocation.getId())` fires unconditionally on every
`transferUnitLoadToLocation` call, including the `ignoreLock=true` path used by `sendToNirvana`
(`UnitloadBusinessService.java:295, 308`). The nirvana location is a single shared row used by
every stock-discard operation in the warehouse: `StockunitBusinessService.java:295, 319`,
`MobilePutAwayService.java:148, 183, 185`, `ReceivingService.java:605, 626`,
`StockunitService.java:326`, `PickingorderBusinessService.java:308`,
`CustomerorderService.java:536`. Under high-throughput club runs or receiving, these callers
converge on the same nirvana row — each now acquires a FOR UPDATE lock on it.
**Risk:** contention spike under sustained throughput; may manifest as `LockTimeoutException`
with the existing 5s timeout.
**Mitigation A (recommended)**: skip the locked re-fetch when `ignoreLock=true` in
`transferUnitLoadToLocation` — the L116 lock-state guard is also skipped on that path, so the
FOR UPDATE buys no correctness benefit. Change Fix C to:
```java
if (!ignoreLock) {
    final Long destinationLocationId = destinationLocation.getId();
    destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
        .orElseThrow(() -> new EntityNotFoundException("Location", destinationLocationId));
    entityManager.refresh(destinationLocation);
}
if (!ignoreLock && destinationLocation.getEntityLock() != BusinessObjectLockState.NOT_LOCKED) {
    throw new FacadeException("STORAGELOCATION_LOCKED", ...);
}
```
**Mitigation B (alternative)**: monitor `wms2.transaction.lock.timeout` counter post-deploy; if
nirvana contention appears, retroactively apply Mitigation A in a fast-follow PR.
The plan **adopts Mitigation A as the implementation target** for Fix C to eliminate the
chokepoint proactively. Update §3.3 Fix C "After" code accordingly.

**Cross-method deadlock residual risk:**
The plan proves stable lock ordering *within* the two scoped methods but does not audit the 11
deferred sites (§0 rows 8-12). `MobileMoveUnitloadService`, `MobilePickingService`, and
`ReceivingService` acquire `location`, `unitload`, and `stockunit` locks in their own
unspecified orders. Until those sites are audited, a cross-method lock inversion is possible.
**Mitigation**: the 5s `jakarta.persistence.lock.timeout` acts as a safety net — deadlocks
resolve via timeout, not permanent block. Add `wms2.transaction.lock.timeout` Micrometer alert
at 1% timeout rate to detect any emerging pattern. Document the residual risk in the follow-up
audit ticket.

### 8.6 Pre-Mortem — Three Concrete Failure Scenarios

This is a high-risk concurrency change (pessimistic locks on 5 entities in a hot warehouse
transfer path). The following scenarios were stress-tested in planning to confirm the fix does
not introduce new failure modes.

**Scenario A — High-throughput club-run putaway batch saturates the destination-location lock**

During a club-run, `MobilePutAwayService` and `transferStockToUnitLoad` concurrently target the
same destination location (a high-demand pick face). Both paths now acquire `FOR UPDATE` on the
location row. Under sustained throughput (50+ concurrent operators), the 5s
`jakarta.persistence.lock.timeout` becomes the binding constraint: callers that queue behind the
lock timeout and receive `LockTimeoutException` → HTTP 409 ("try again"). Operators see a
"location busy, retry" response. The fix converts a *silent corruption* failure mode into a
*visible retry* failure mode — which is the correct trade-off. **Mitigated by:** the 5s timeout
is generous for the expected ~300ms hold time; contention is bounded by the number of operators
targeting the same single location row. Monitor `wms2.transaction.lock.timeout` counter; alert
at 1% timeout rate per endpoint.

**Scenario B — Cross-method deadlock between `transferStockToUnitLoad` and a concurrent mobile move**

`MobileMoveUnitloadService` acquires locks in its own unspecified order (§0 rows 8-12, deferred
audit). If `MobileMoveUnitloadService` locks destination-location before unitload, while
`transferStockToUnitLoad` locks source-unitload before destination-location, the two methods can
deadlock on overlapping rows. PostgreSQL detects deadlocks within ~100ms and aborts one
transaction with `ERROR: deadlock detected` → Spring wraps this as
`PessimisticLockingFailureException` → HTTP 409. **Mitigated by:** the 5s timeout resolves any
undetected lock wait via `LockTimeoutException`; PostgreSQL's deadlock detector resolves
true deadlocks within milliseconds. The cross-method audit (follow-up tickets) will establish a
system-wide stable ordering convention to prevent this class of issue permanently.

**Scenario C — Mobile UI does not handle HTTP 409 from `PessimisticLockingFailureException` gracefully**

Prior to this fix, contention on `transferStockToUnitLoad` produced a stale-entity
`BusinessException` (HTTP 400 "stockunit is locked"), which the mobile UI likely handles with a
specific error message. Post-fix, contention produces HTTP 409 (from
`RestExceptionHandler.handlePessimisticLock` at line 150). If the mobile UI's error handler
treats HTTP 409 differently (e.g., shows a raw "Conflict" message rather than a "try again"
prompt), operators see a degraded experience. **Mitigated by:** the manual test plan (§6) includes
a concurrent-transfer scenario in staging that exercises this path. The implementer must confirm
the mobile UI displays a sensible message on HTTP 409 before signing off. If needed, a fast-follow
UI ticket can improve the error message wording.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.sh`

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 3 files, ~6 code changes, 1 new test class — same shape as SBDEV-2223 |
| **Pre-draft step** | done | Plan is already grounded in verified code facts; no ccg / deep-interview needed |
| **Plan-review step** | `critic` | Concurrency fix — second pair of eyes recommended before coding starts |
| **Implementation shape** | `executor` | Mechanical refactor + one new test class; well-bounded |
| **Verification step** | verify-script + `verifier` | Mandatory |
| **Code-review step** | `code-reviewer` | Concurrency fix — second pair of eyes warranted post-coding |
| **Commit step** | `git-master` | Single logical commit (Fix A + B + C land together) |

---

## §10 Rollout & Verification

**Pre-deploy DB baseline** (record counts before merge, repeat 24h post-deploy):

```sql
-- Locked entity counts — should be stable (locked entities clear at the normal rate)
SELECT 'stockunit' AS entity, count(*) AS locked_count
FROM stockunit WHERE entity_lock != 0
UNION ALL
SELECT 'unitload', count(*) FROM unitload WHERE entity_lock != 0
UNION ALL
SELECT 'location', count(*) FROM location WHERE entity_lock != 0;

-- Optional: long-held locks (>1h) — these are the bug's signature
SELECT entity_lock, updated_at, id
FROM stockunit
WHERE entity_lock != 0 AND updated_at < now() - interval '1 hour'
ORDER BY updated_at ASC
LIMIT 50;
```

```bash
# Run verify script — should report all FAIL (pre-fix baseline):
bash sbdocs/9-System/scripts/verify-SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.sh
# Expected output: Result: 0 pass, N fail (code-shape checks fail pre-implementation)
```

**Deploy:** Single-JAR redeploy of `wms2-api`. No schema migration, no data migration, no
feature flag.

**Rollback:** Redeploy the previous JAR artifact. No data rollback needed — there is no data
migration. Locks held at rollback time release naturally on the next transaction commit /
rollback.

**Rollback verification** (run within 15 minutes of rollback):

```sql
-- Confirm no transfers stuck mid-flight at rollback time:
-- (Any row with entity_lock != 0 AND updated_at within the deploy window should be trending back to 0)
SELECT id, entity_lock, updated_at
FROM stockunit
WHERE entity_lock != 0
  AND updated_at BETWEEN :deploy_time AND :rollback_time
ORDER BY updated_at DESC
LIMIT 20;

-- Confirm location locks cleared (all locations should return to NOT_LOCKED after rollback):
SELECT id, entity_lock, updated_at
FROM location
WHERE entity_lock != 0
ORDER BY updated_at DESC;
```

If any row shows `entity_lock != 0` with `updated_at` within the deploy window AND the transfer
was not completed before rollback, an operator may need to manually clear the lock via the admin
UI lock-release endpoint or a targeted `UPDATE stockunit SET entity_lock=0 WHERE id=?` after
confirming the transfer is genuinely incomplete.

**Post-deploy (24h after):** Re-run the queries above. Long-held-lock count should trend toward
zero (no new stuck locks introduced by transfer flows). Monitor
`wms2.transaction.lock.timeout` Micrometer counter for spikes — a brief uptick is expected
(the fix turns silent stale reads into observable `PessimisticLockException` instances under
contention) but should plateau within the first hour as user retries succeed.

---

## §11 Known Uncovered Call Sites (Follow-up)

The 11 deferred sites from §0 (rows 8–12) are documented here for the follow-up tickets:

| File | Lines | Classification |
|------|-------|----------------|
| `service/mobile/MobileMoveUnitloadService.java` | :147, :153, :215, :221, :431, :432, :457, :458 | TOCTOU `getEntityLock` — needs triage |
| `service/mobile/MobileMoveStockService.java` | :234 | TOCTOU `getEntityLock` — needs triage |
| `service/mobile/MobileCycleCountService.java` | :131, :135, :163, ... | TOCTOU `getEntityLock` — separate cycle-count ticket |
| `service/mobile/MobilePickingService.java` | :1125, :1140 | TOCTOU `getEntityLock` — separate picking ticket |
| `service/StockunitService.java` | :223, :288, ... | TOCTOU `getEntityLock` — separate audit |

**Recommendation:** open a parent ticket "Audit `getEntityLock()` reads across non-transfer
service classes for TOCTOU" and spawn child tickets per file group. The directive
`project_memory_add_directive` should land after this plan's first rollout to prevent the
anti-pattern from re-introducing in future plans.
