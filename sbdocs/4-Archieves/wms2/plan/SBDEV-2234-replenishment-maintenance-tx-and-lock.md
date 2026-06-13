---
title: "ReplenishmentOrderMaintenanceService Concurrency Hardening"
ticket: "SBDEV-2234"
ticket_url: "https://app.clickup.com/t/868jj34v7"
type: "bugfix"
priority: "high"
status: "archived"
project:
  - wms2
version: "v2"
requester: ""
created: "2026-05-15"
updated: "2026-05-15"
db_verified: true
related:
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md
  - sbdocs/3-Resources/data-dictionary/wms2-sysprop-catalog.md
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.md
tags:
  - plan
  - wms2
  - replenishment
  - concurrency
  - pessimistic-lock
  - transaction
  - multi-replica
  - sysprop
---

# SBDEV-2234 — `ReplenishmentOrderMaintenanceService` Concurrency Hardening

**Ticket:** [SBDEV-2234](https://app.clickup.com/t/868jj34v7)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** draft
**Date:** 2026-05-15

> **db_verified: true** — `replenishorder` table confirmed on tenant PostgreSQL DB
> with `state`, `version`, `entity_lock` columns (verified 2026-05-15 via MCP).
> 601 rows in state `PROCESSABLE` at time of analysis — the recalculation path is
> a hot, multi-row write loop. Multi-replica deployment is confirmed by
> `wms2-tenant-routing-datasource-topology.md`.
>
> **Baseline counts (tenant DB, 2026-05-15):**
> | Metric | Count |
> |---|---|
> | `replenishorder` total rows | (tenant-scoped) |
> | `replenishorder` in PROCESSABLE state | 601 |
> | Replicas behind LB | ≥2 (per deployment topology) |
> | `lastRun` field type | `private Instant` — bean-local |
>
> The `synchronized` keyword discussed in the original SBDEV-2234 framing was
> removed in commit `b68cbbf4`. This plan completes the remaining concurrency
> hardening that the synchronized-removal commit did not address.

---

## §0 Affected Sites

All call sites in the recalculation cluster were enumerated and triaged. Rows 1–6 are the primary in-scope sites in the service itself; rows 7–12 are caller / sibling sites verified for correctness alignment; row 13 is the prerequisite repository method that already exists.

| # | File:line | Construct | Outer tx context | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|------------------|----------------------|
| 1 | `service/ReplenishmentOrderMaintenanceService.java:67-69` | `recalculateOpenOrders()` no-arg dispatch | none | yes | yes |
| 2 | `service/ReplenishmentOrderMaintenanceService.java:71-91` | `recalculateOpenOrders(boolean force)` — cadence read + iteration | none (intentional, per 260331) | yes | yes |
| 3 | `service/ReplenishmentOrderMaintenanceService.java:93-113` | `recalculateForItem(Long)` — non-transactional, per-order auto-commit | varies (see callers below) | yes | **yes — Fix A + Fix A.1 (null guard)** |
| 4 | `service/ReplenishmentOrderMaintenanceService.java:115-117` | `recalculateOrder(Replenishorder)` package-private | inherits caller | yes | yes |
| 5 | `service/ReplenishmentOrderMaintenanceService.java:119-157` | `recalculateOrder(Replenishorder, RecalcContext)` — uses plain `findById` for re-fetch | inherits caller | yes | **yes — Fix B** |
| 6 | `service/ReplenishmentOrderMaintenanceService.java:47` | `private Instant lastRun = Instant.EPOCH` — JVM-local cadence | n/a | yes | **yes — Fix C** |
| 7 | `schedulejob/ReplenishOrderJob.java:84-87` | already coordinated by `AdvisoryLockService.JobLockId.REPLENISH_ORDER` | advisory lock; no JPA tx | no | no (orthogonal mechanism — confirmed safe) |
| 8 | `schedulejob/ReplenishOrderJob.java:155` | calls `recalculateForItem` under advisory lock | no JPA tx (advisory lock only) | safe | yes (verify) |
| 9 | `schedulejob/ReplenishOrderJob.java:162` | calls `recalculateOpenOrders(false)` under advisory lock | no JPA tx (advisory lock only) | safe | yes (verify) |
| 10 | `service/FixLocationAssignmentService.java:292` (via `triggerReplenishmentMaintenance`) | uncoordinated caller of `recalculateForItem` | **mixed** — see callsite map below | yes | yes (covered by Fix A scope) |
| 11 | `service/StockunitService.java:123` (via `triggerReplenishmentMaintenance`) | uncoordinated caller of `recalculateForItem` from `transferStock`/`adjustAmount`/`adjustReservedAmount` etc. | **per-caller** — `@Transactional("tenantTransactionManager")` only on `transferStock` (`:145`) and `adjustReservedAmount` (`:435`); `adjustAmount` (`:395`) has **no** `@Transactional` | yes | yes (covered by Fix A scope) |
| 12 | `service/mobile/MobileReplenishService.java:807` | calls **`recalculateOpenOrders(true)`** (NOT `recalculateForItem`) inside outer `@Transactional` | inside outer tx | yes (separate concern) | **no — Fix A does not apply** (see §1 / §10) |
| 13 | `repo/jpa/ReplenishorderRepository.java:27-29` | `findByIdForUpdate(Long)` with `@Lock(PESSIMISTIC_WRITE)` — **already exists**, currently unused by this service | — | — | yes (use it in Fix B) |

### §0.1 Caller Propagation Matrix (post-Fix A behavior)

This matrix is the canonical source of truth for how Fix A's `@Transactional` interacts with each caller. The architect's review (2026-05-15) corrected three earlier errors here.

| Caller | Outer tx active when calling `recalculateForItem`? | After Fix A behavior | Lock window (Fix B FOR UPDATE) | Failure semantics |
|---|---|---|---|---|
| `ReplenishOrderJob` via `recalculateForItem(itemId)` (`ReplenishOrderJob.java:155`) | Advisory lock only (DB row lock on `JobLockId.REPLENISH_ORDER`); **no JPA tx** | Fix A opens a fresh tenant tx | Held for duration of recalc for this item (typically tens of ms; bounded by 1-3 orders per item) | Tx rollback on uncaught throw; advisory lock released by surrounding job code |
| `StockunitService.transferStock` (`StockunitService.java:145`) / `adjustReservedAmount` (`:435`) → `triggerReplenishmentMaintenance` | **YES** — `@Transactional("tenantTransactionManager")` on both methods | `Propagation.REQUIRED` JOINS the outer tx; Fix A does **not** open a new tx | **Held until the outer business tx commits** — may include `messageService.sendStockChangeMessage` and other writes in the same tx. Likely 100–500ms. | Outer tx rollback would also roll back the recalc (atomic) |
| `StockunitService.adjustAmount` (`:395`) → `triggerReplenishmentMaintenance` | **NO** — method has **no** `@Transactional` annotation (verified: `StockunitService.java:395`; only `transferStock:145` and `adjustReservedAmount:435` carry the annotation) | Fix A opens a **fresh** tenant tx for the recalc only | Held for duration of recalc only (tens of ms; same as the job path) | **Asymmetric:** `adjustAmount` performs writes (incl. `messageService.sendStockChangeMessage` at `:427`) in implicit auto-commits **outside** Fix A's recalc tx. If the recalc throws, those upstream writes are **not** rolled back. Pre-existing asymmetric-failure pattern analogous to §9 Risk-8 (`changeActive`). Out of scope for SBDEV-2234. |
| `FixLocationAssignmentService.changeActive` (`FixLocationAssignmentService.java:271`) → `triggerReplenishmentMaintenance(:279)` | **NO** — method has no `@Transactional` annotation | Fix A opens a **fresh** tenant tx for the recalc only | Held for duration of recalc only | **Asymmetric:** the prior `fixLocationAssignment.setActive(...)` + `save()` at lines 276–277 ran in its own implicit auto-commit and is **not enclosed** in the recalc tx. If the recalc throws, the assignment flip is **not** rolled back. See §9 Risk-8 below. |
| `FixLocationAssignmentService` other entry points (lines 99, 172, 189, 207, 225, 268) calling `triggerReplenishmentMaintenance` | **NO** — verified `FixLocationAssignmentService.java` has **zero** `@Transactional` annotations anywhere in the file. Same asymmetric-failure pattern as `changeActive`: any prior `save()` runs in its own implicit auto-commit, outside Fix A's fresh recalc tx. | Fix A opens a **fresh** tenant tx for the recalc only | Held for duration of recalc only | **Asymmetric:** any upstream `save()` in the calling method is in its own auto-commit and is **not enclosed** in the recalc tx. Pre-existing pattern; out of scope for SBDEV-2234. |
| `MobileReplenishService.confirmAndClose` (line 744) → calls `recalculateOpenOrders(true)` at `:807` | **YES** — outer `@Transactional("tenantTransactionManager")` | **Fix A does NOT apply** — this call site invokes `recalculateOpenOrders(true)`, not `recalculateForItem`. The 600+ row sweep runs inside the mobile tx (per-order auto-commit suspended? no — the inner code is non-`@Transactional`, so it joins the active tx). This is a separate concern out of scope for SBDEV-2234. | n/a for SBDEV-2234 | Out of scope — file follow-up ticket (see §10) |

**Scope rationale:** rows 1–6 form a self-contained cluster — every recalculation
write path in `ReplenishmentOrderMaintenanceService` is patched in one diff.
Rows 7–9 are pre-existing advisory-lock coordination (`AdvisoryLockService.JobLockId.REPLENISH_ORDER`)
that is unaffected by Fix A/B/C and intentionally not modified. Rows 10–11 are
upstream callers whose contract changes only in that their nested call's new
annotation now opens its own transaction (Fix A) if none is active, or **joins
the outer tx** if one is active (the architect-corrected behavior — see §0.1).
Row 12 invokes `recalculateOpenOrders`, not `recalculateForItem`, and is
**deliberately excluded** from Fix A's scope; it is recorded as a follow-up
concern in §10.

---

## 1. Problem Statement

`ReplenishmentOrderMaintenanceService` recalculates replenishment-order
`requestedamount` and the corresponding `Stockunit.reservedamount` on three
trigger paths:

1. **Scheduled job** — `ReplenishOrderJob` calls `recalculateOpenOrders()` /
   `recalculateForItem(itemDataId)` once per cron tick, under
   `AdvisoryLockService.JobLockId.REPLENISH_ORDER` (cross-replica safe).
2. **HTTP** — `FixLocationAssignmentService` (multiple entry points incl.
   `changeActive`) and `StockunitService` (`transferStock`, `adjustAmount`,
   `adjustReservedAmount`) call `recalculateForItem(itemDataId)` synchronously
   inside the request thread via `triggerReplenishmentMaintenance`, with **no
   advisory-lock coordination**. Among the `StockunitService` callers, only
   `transferStock` (`:145`) and `adjustReservedAmount` (`:435`) carry
   `@Transactional("tenantTransactionManager")`; `adjustAmount` (`:395`) does
   **not**, so its prior writes (incl. `messageService.sendStockChangeMessage`
   at `:427`) run in implicit auto-commits. `FixLocationAssignmentService` has
   **zero** `@Transactional` annotations on any method, so all of its entry
   points (including `changeActive`) have the same asymmetric-failure pattern
   — prior `save()` calls happen in implicit auto-commits outside Fix A's
   fresh recalc tx (see §0.1).
3. **Mobile** — `MobileReplenishService.confirmAndClose` (line 744) calls
   **`recalculateOpenOrders(true)`** (not `recalculateForItem`) at line 807,
   inside the method's outer `@Transactional`. **This call site is out of
   scope for SBDEV-2234**; Fix A targets `recalculateForItem` only. The
   long-mobile-tx interaction with the 600+ row sweep is filed as a follow-up
   concern in §10.
4. **Operator-triggered** — admin UI direct invocation.

Three concurrency bugs make paths (2) and (3) unsafe in the multi-replica
deployment confirmed by `wms2-tenant-routing-datasource-topology.md`:

**Symptom 1 — drift between `Replenishorder.requestedamount` and `Stockunit.reservedamount`.**
Two replicas simultaneously process a stock-movement triggering
`recalculateForItem(itemX)`. Both load the same `Replenishorder` and the same
`Stockunit`, compute different `requestedamount` values based on slightly
different `RecalcContext` snapshots, and each calls `save()`. The
`Replenishorder.requestedamount` row reflects whichever transaction commits
last (last-writer-wins). The `Stockunit.reservedamount` increment happens
twice — both transactions added their own delta in separate auto-commits,
producing a +N over-reservation that operators see as "phantom" reserved stock
that never releases.

**Symptom 2 — cadence-throttling bypassed on multi-replica.**
The `lastRun` field is a `private Instant` on the singleton bean. With two
replicas, each pod starts at `Instant.EPOCH` and every `recalculateOpenOrders`
call satisfies the cadence check on at least one pod, defeating the
`REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` throttle and producing
back-to-back recalc runs visible as bursts of `replenishorder.modified`
timestamps within a few ms of each other.

**Symptom 3 — silent optimistic-lock loss + inconsistent state.**
`recalculateOrder(Replenishorder, RecalcContext)` re-fetches with a plain
`findById` at line 124. Two replicas race on the same order; the loser's
`save()` throws `ObjectOptimisticLockingFailureException` which is **caught and
swallowed** by the outer `try { ... } catch (Exception e) { LOG.warn(...) }` at
lines 84–89 / 106–111. The loser's `Stockunit` write may have already partially
committed in a separate auto-commit (since `recalculateForItem` is non-`@Transactional`),
leaving `Stockunit.reservedamount` skewed while `Replenishorder.requestedamount`
holds the winner's value. No visible error; quiet drift.

**Reproduction (deterministic):**
1. Pick a tenant with ≥2 replicas. Find an `itemdataId` with at least one open
   `Replenishorder`.
2. Trigger two concurrent stock movements affecting the same `itemdataId` (e.g.,
   two operators on different mobile devices simultaneously confirming picks).
3. Both replicas hit `recalculateForItem(itemdataId)`.
4. Observe in DB: `SELECT requestedamount FROM replenishorder WHERE id=R;` and
   `SELECT reservedamount FROM stockunit WHERE id=S;` — the
   pair-invariant `reservedamount = sum(requestedamount)` is violated.

---

## 2. Root Cause Analysis

### Bug A1 — JVM-local `lastRun` cadence field (`ReplenishmentOrderMaintenanceService.java:47, 71-91, 159-166`)

```java
// :47
private Instant lastRun = Instant.EPOCH;
```

```java
// :71-75 — gate
public void recalculateOpenOrders(boolean force) {
    if (!force && shouldSkipForCadence()) {
        return;
    }
    lastRun = Instant.now();
    ...
}

// :159-166
private boolean shouldSkipForCadence() {
    Duration cadence = getCadence();
    if (cadence.isZero() || cadence.isNegative()) {
        return false;
    }
    Instant now = Instant.now();
    return Duration.between(lastRun, now).compareTo(cadence) < 0;
}
```

`lastRun` is bean-local. In a multi-replica deployment each pod has its own
copy. Pod A runs at T+0, sets its `lastRun=T+0`. Pod B receives the next
trigger at T+1; its `lastRun` is still `EPOCH`; cadence check passes; Pod B
runs immediately. The configured `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS`
throttle is effectively bypassed for any tenant with N>1 replicas.

This violates the architectural contract documented in
`wms2-tenant-routing-datasource-topology.md`: shared runtime state for
horizontally-scaled services must live in the per-tenant DB.

### Bug A2 — `recalculateForItem(Long)` is non-transactional (`ReplenishmentOrderMaintenanceService.java:93-113`)

```java
// :93 — NO @Transactional annotation
public void recalculateForItem(Long itemDataId) {
    if (itemDataId == null) {
        recalculateOpenOrders();
        return;
    }
    List<Replenishorder> openOrders = replenishorderRepository.findByStateAndItemdataId(...);
    RecalcContext ctx = buildRecalcContext(openOrders);

    for (Replenishorder order : openOrders) {
        if (Boolean.TRUE.equals(order.getManuallyoverridepriority())) {
            continue;
        }
        try {
            recalculateOrder(order, ctx);  // each save() is its own auto-commit
        } catch (Exception e) {
            LOG.warn("Failed to recalculate replenishOrder={} : {}", order.getNumber(), e.getMessage());
            LOG.debug("Recalculation failure", e);
        }
    }
}
```

Without `@Transactional(value="tenantTransactionManager")`, every
`replenishorderRepository.save(...)` and downstream `stockunitRepository.save(...)`
inside `recalculateOrder(...)` runs in its own implicit auto-commit. Two
replicas concurrently calling `recalculateForItem(itemX)`:

- Both load `Replenishorder R` via `findById` (snapshot v=5).
- Both compute `requestedamount = old + delta1` and `old + delta2` in memory.
- Both `save()`. Hibernate optimistic-lock check on `R.version` lets only one
  win — the loser's `save()` throws `ObjectOptimisticLockingFailureException`.
- **But** the corresponding `Stockunit.reservedamount` mutation happened in a
  **different prior auto-commit** within `recalculateOrder` (because every
  repo write is its own tx). The Stockunit row already shows
  `reservedamount += delta_loser` from the loser's auto-committed write.
- The catch-all at `:84-89` swallows the optimistic-lock exception. Outcome:
  `Stockunit.reservedamount` includes both deltas; `Replenishorder.requestedamount`
  only the winner's. Drift.

The original `260331` plan deliberately kept `recalculateOpenOrders` per-order
auto-commit to bound transaction width on a multi-hundred-row sweep. That
decision is **preserved** for `recalculateOpenOrders` but does not apply to
`recalculateForItem`, which is single-item-scoped and benefits from a tight
transactional wrapper.

### Bug A3 — `recalculateOrder(...)` uses plain `findById` not `findByIdForUpdate` (`ReplenishmentOrderMaintenanceService.java:119-127`)

```java
// :119-127
void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null) {
        return;
    }
    // Re-fetch to get latest version and avoid stale-entity optimistic lock failures
    order = replenishorderRepository.findById(order.getId()).orElse(null);   // ✗ no FOR UPDATE
    if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
        return;
    }
    ...
    updateRequestedAmount(order, source, desiredAmount);   // ← mutates and saves
}
```

The comment claims the re-fetch avoids stale-entity optimistic-lock failures.
It does not. Plain `findById` issues `SELECT * FROM replenishorder WHERE id=?`
with no row lock. Between this `SELECT` and the eventual `updateRequestedAmount`
call (which performs the `UPDATE`), any concurrent transaction can write the
row first. The optimistic-lock check on `@Version` fires at flush time, throws
`ObjectOptimisticLockingFailureException`, which is then swallowed by the
outer catch — leaving the row in an inconsistent state because the
`Stockunit.reservedamount` half of the pair already committed.

The repository already exposes `findByIdForUpdate(Long)` with
`@Lock(PESSIMISTIC_WRITE)` at `ReplenishorderRepository.java:27-29`. It is
unused at this call site. Swapping to it issues `SELECT ... FOR UPDATE`,
serializing concurrent recalculators on the same `Replenishorder` row at the
DB layer. **Note:** the FOR UPDATE row lock is only effective while the current
transaction is open; it is released on commit. This is why Fix B must land
together with (or before) Fix A — the lock is meaningful only when held inside
a transactional scope that brackets the subsequent `save()`.

---

## §3 Regression Chain

Commit `b68cbbf4` (predecessor) removed the `synchronized` keyword from
`recalculateForItem` per archived plan `260331-replenishment-maintenance-tx-and-lock.md`.
That plan correctly identified that JVM-level `synchronized` is meaningless
across replicas and removed it; it deferred the DB-layer coordination (this
plan's Fix A + Fix B) and the sysprop cadence (Fix C) to a follow-up — which
is SBDEV-2234.

The `260331` plan also explicitly documented the decision to **keep
`recalculateOpenOrders` per-order auto-commit** (not transactional) to bound
sweep duration on the 600+ row PROCESSABLE list. This plan preserves that
decision: Fix A applies ONLY to `recalculateForItem`, NOT to
`recalculateOpenOrders`.

---

## §4 Architecture Overview

### ASCII flow (post-fix)

```
                                  ┌──────────────────────────────────────────────┐
   Trigger sources                │  ReplenishmentOrderMaintenanceService        │
   ────────────────               │                                              │
                                  │  recalculateOpenOrders(boolean force)        │
   ReplenishOrderJob ─────────────│  ─ checks shouldSkipForCadence()             │
   (advisory lock REPLENISH)      │       └─ reads lastRun via syspropService    │ ◄─┐
                                  │  ─ iterates openOrders (per-order auto-cmt)  │   │
   FixLocationAssignmentService ──│                                              │   │
   StockunitService              ─│  recalculateForItem(Long itemDataId)         │   │
   MobileReplenishService         │  @Transactional("tenantTransactionManager") │   │  Tenant DB
                                  │  ─ iterates openOrders for item              │   │  ───────
                                  │       └─ recalculateOrder(order, ctx)        │   │
                                  │             └─ findByIdForUpdate(id) ─SELECT FOR UPDATE──► replenishorder
                                  │             └─ updateRequestedAmount  ───── UPDATE ──────►
                                  │             └─ stockunit save        ───── UPDATE ──────► stockunit
                                  │                                              │   │
                                  │  setLastRun(Instant) ───── @CacheEvict + UPDATE sysprop ─►  los_sysprop
                                  │                                              │
                                  └──────────────────────────────────────────────┘   │
                                                                                     │
   Multi-replica safe via:                                                           │
     - REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS sysprop ◄────────────────────── ┘
     - PESSIMISTIC_WRITE row lock on replenishorder
     - @Transactional wrapper around recalculateForItem
```

### Key files

| File | Role |
|---|---|
| `service/ReplenishmentOrderMaintenanceService.java` | Primary fix target — Fix A + Fix B + Fix C land here |
| `service/SyspropService.java` | Needs a new public `setSysvalue(String, String)` with `@CacheEvict` + `@Transactional` for Fix C |
| `repo/jpa/ReplenishorderRepository.java` | Already has `findByIdForUpdate` — no change needed |
| `service/WmsConstants.java` | Add `SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY` + default |
| `schedulejob/ReplenishOrderJob.java` | Caller — verified safe, no change |
| `service/FixLocationAssignmentService.java` | Caller of `recalculateForItem` — verified: **no `@Transactional` annotation on any method** in this file. All entry points (including `changeActive`) exhibit the same asymmetric-failure pattern (§9 Risk-8). No change in this plan; follow-up ticket recommended. |
| `service/StockunitService.java` | Caller of `recalculateForItem` — outer `@Transactional("tenantTransactionManager")` active only on `transferStock` (`:145`) and `adjustReservedAmount` (`:435`); `adjustAmount` (`:395`) has **no** `@Transactional`. For the two transactional callers, Fix A joins outer tx (Risk-2 hold-time impact). For `adjustAmount`, Fix A opens a fresh tx (asymmetric-failure pattern similar to §9 Risk-8). No change here. |
| `service/mobile/MobileReplenishService.java` | Caller of `recalculateOpenOrders(true)` at `:807` (NOT `recalculateForItem`). **Out of scope for SBDEV-2234.** Filed as follow-up (see §10 Open Question #4). |

---

## §5 Fix Design

### Fix A — Add `@Transactional` to `recalculateForItem(Long)` (only)

**Problem:** `recalculateForItem` is non-transactional; concurrent calls
auto-commit partial state and the FOR UPDATE lock from Fix B has no scope to
hold within.

**Solution:** Add the per-tenant transaction manager annotation to
`recalculateForItem(Long)` only. **Do NOT add it to `recalculateOpenOrders(boolean)`**
— that path was deliberately kept per-order auto-commit by the 260331 plan to
bound transaction width on a 600+ row sweep.

**Before:**

```java
// :93
public void recalculateForItem(Long itemDataId) {
    if (itemDataId == null) {
        recalculateOpenOrders();
        return;
    }
    List<Replenishorder> openOrders = replenishorderRepository.findByStateAndItemdataId(WmsConstants.State.PROCESSABLE, itemDataId);
    RecalcContext ctx = buildRecalcContext(openOrders);
    for (Replenishorder order : openOrders) {
        if (Boolean.TRUE.equals(order.getManuallyoverridepriority())) {
            continue;
        }
        try {
            recalculateOrder(order, ctx);
        } catch (Exception e) {
            LOG.warn("Failed to recalculate replenishOrder={} : {}", order.getNumber(), e.getMessage());
            LOG.debug("Recalculation failure", e);
        }
    }
}
```

**After:**

```java
// Single-item recalculation runs in a tenant transaction so the
// findByIdForUpdate lock (Fix B) is held across the subsequent
// updateRequestedAmount + stockunit save calls. The recalculateOpenOrders
// sweep path is intentionally NOT wrapped — see archived plan 260331.
// Null-branch behavior is changed by Fix A.1 below to prevent the sweep
// from running inside this transaction.
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void recalculateForItem(Long itemDataId) {
    if (itemDataId == null) {
        // Fix A.1 — early-return; do NOT delegate to recalculateOpenOrders()
        // (which would now run inside this @Transactional scope, breaking
        // the 260331 decision). Verified 2026-05-15: no production caller
        // passes null.
        LOG.warn("recalculateForItem(null) is ambiguous and no longer routes "
            + "into recalculateOpenOrders(). Call recalculateOpenOrders() "
            + "directly for a full sweep. Skipping.");
        return;
    }
    List<Replenishorder> openOrders = replenishorderRepository.findByStateAndItemdataId(WmsConstants.State.PROCESSABLE, itemDataId);
    RecalcContext ctx = buildRecalcContext(openOrders);
    for (Replenishorder order : openOrders) {
        if (Boolean.TRUE.equals(order.getManuallyoverridepriority())) {
            continue;
        }
        try {
            recalculateOrder(order, ctx);
        } catch (Exception e) {
            LOG.warn("Failed to recalculate replenishOrder={} : {}", order.getNumber(), e.getMessage());
            LOG.debug("Recalculation failure", e);
        }
    }
}
```

**Caller-side propagation:** see the complete **Caller Propagation Matrix** in
§0.1 above. Summary:
- `ReplenishOrderJob.java:155` — no JPA tx active (advisory lock only); Fix A
  opens a fresh tenant tx cleanly.
- `StockunitService.transferStock` (`:145`) / `.adjustReservedAmount` (`:435`)
  — both sit **inside** an outer `@Transactional("tenantTransactionManager")`.
  `Propagation.REQUIRED` JOINS the outer tx. The Fix B FOR UPDATE lock will
  therefore be held until the **outer business tx commits**, not just the
  recalc loop. See §9 Risk-2 for the re-quantified lock-hold impact.
- `StockunitService.adjustAmount` (`:395`) — has **no `@Transactional`**
  (verified). Fix A opens a fresh tx for the recalc only; lock hold bounded
  by recalc duration (tens of ms, same as the job path). Prior writes in
  `adjustAmount` (incl. `messageService.sendStockChangeMessage` at `:427`)
  run in implicit auto-commits outside Fix A's recalc tx → asymmetric-failure
  pattern analogous to §9 Risk-8 (pre-existing; out of scope).
- `FixLocationAssignmentService.changeActive` (`:271`) — has **no
  `@Transactional`**. Fix A opens a fresh tx for the recalc only. The prior
  `fixLocationAssignment.setActive(...) + save()` at lines 276–277 runs in
  its own auto-commit and is **not enclosed** in the recalc tx. Failure inside
  the recalc rolls back only the recalc, not the active-flip. See §9 Risk-8.
- `FixLocationAssignmentService` other entry points (`:99, :172, :189, :207,
  :225, :268`) — verified: **no `@Transactional` annotation on any method**
  in this file. Same asymmetric-failure pattern as `changeActive`: Fix A
  opens a fresh tx for the recalc only; any prior `save()` in the calling
  method is in its own auto-commit, outside the recalc tx. Pre-existing
  pattern; out of scope for SBDEV-2234.
- `MobileReplenishService.confirmAndClose:807` — **not a `recalculateForItem`
  caller**; it calls `recalculateOpenOrders(true)`. Fix A does not apply.
  Out of scope for SBDEV-2234 (see §10).

### Fix A.1 — Null-itemDataId guard (architect-required)

**Problem:** `recalculateForItem(Long)` currently has a null guard that
delegates to `this.recalculateOpenOrders()`:

```java
// :93-97 BEFORE
public void recalculateForItem(Long itemDataId) {
    if (itemDataId == null) {
        recalculateOpenOrders();
        return;
    }
    ...
}
```

After Fix A wraps `recalculateForItem` in `@Transactional`, a call with
`itemDataId == null` would route the 600+ row sweep into the new transaction
(because `this.recalculateOpenOrders()` is a self-call that bypasses the
proxy, but more importantly because `recalculateOpenOrders` has no
`@Transactional` annotation and `Propagation.REQUIRED`-style behavior is
inherited from the active transaction). This **violates the explicit §10
decision (preserved from 260331) to keep `recalculateOpenOrders` non-transactional**.

**Caller audit (verified 2026-05-15):** A repo-wide grep for
`recalculateForItem(null)` returns **zero hits** in `v2/wms2-api/src/main/java`.
Both upstream wrappers (`StockunitService.triggerReplenishmentMaintenance:121`
and `FixLocationAssignmentService.triggerReplenishmentMaintenance:292`) guard
against null with an early `return` before calling. `ReplenishOrderJob:155`
passes a non-null `itemDataId`. No production caller passes `null` today.

**Solution:** Change the null branch from a silent delegate-into-full-sweep
to an explicit early-return with a warning log. Any caller that genuinely
wants a full sweep must call `recalculateOpenOrders()` directly.

**Before:**

```java
public void recalculateForItem(Long itemDataId) {
    if (itemDataId == null) {
        recalculateOpenOrders();
        return;
    }
    ...
}
```

**After:**

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void recalculateForItem(Long itemDataId) {
    if (itemDataId == null) {
        // Pre-fix behavior delegated to recalculateOpenOrders(), which would
        // now run inside this @Transactional wrapper — bypassing the explicit
        // 260331 decision to keep the 600+ row sweep non-transactional.
        // Callers that want a full sweep must invoke recalculateOpenOrders()
        // directly. Verified 2026-05-15: no production caller passes null.
        LOG.warn("recalculateForItem(null) is ambiguous and no longer routes "
            + "into recalculateOpenOrders(). Call recalculateOpenOrders() "
            + "directly for a full sweep. Skipping.");
        return;
    }
    List<Replenishorder> openOrders = replenishorderRepository.findByStateAndItemdataId(...);
    ...
}
```

**Why early-return instead of self-proxy injection:** A self-injection pattern
(`@Autowired @Lazy ReplenishmentOrderMaintenanceService self; self.recalculateOpenOrders();`)
was considered but rejected: because `recalculateOpenOrders` is **not**
annotated `@Transactional`, calling it through the proxy from inside an
active transaction has the same effect as calling it on `this` — Spring's
proxy interceptor only opens / suspends transactions when annotations
dictate; it does not "exit" the active transaction on every method call.
The only safe way to ensure the 600+ row sweep runs outside the recalc tx is
to **not call it from inside a `@Transactional` method**. Early-return is the
cleanest enforcement.

**Verification:** the verify script (§11.1) adds check `A4` to assert the
null branch contains `return` and `LOG.warn` and **no** call to
`recalculateOpenOrders()`.

**Rationale for in-loop try/catch retention:** the loop catches per-order
exceptions to ensure one bad order doesn't abort the entire sweep. With the
new `@Transactional` wrapper, a thrown `BusinessException` / `FacadeException`
would normally roll back the entire batch. The existing try/catch swallows the
exception inside the loop, so the rollback marker is **not** propagated up.
This means the tx commits cleanly for orders that succeeded — preserving the
existing batch semantics — and only logs warnings for individual failures.
The acceptance test must verify this behavior is preserved (AC-4 includes a
"one failing order does not rollback siblings" case).

### Fix B — Use `findByIdForUpdate` in `recalculateOrder(...)`

**Problem:** the re-fetch uses plain `findById`; no row lock; concurrent
recalculators race.

**Solution:** replace with `findByIdForUpdate`. The repository method already
exists at `ReplenishorderRepository.java:27-29`. The FOR UPDATE lock is held
inside the `@Transactional("tenantTransactionManager")` scope established by
Fix A (or by `MobileReplenishService`'s outer tx). Once Fix A is in place, the
lock spans the entire `updateRequestedAmount` + `stockunit save` sequence.

**Before:**

```java
// :119-127
void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null) {
        return;
    }
    // Re-fetch to get latest version and avoid stale-entity optimistic lock failures
    order = replenishorderRepository.findById(order.getId()).orElse(null);
    if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
        return;
    }
    ...
}
```

**After:**

```java
// :119-127
void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null) {
        return;
    }
    // Re-fetch under PESSIMISTIC_WRITE so concurrent recalculators on the
    // same row serialize at the DB layer. Lock is held for the remainder of
    // the enclosing @Transactional scope (Fix A: recalculateForItem, or
    // MobileReplenishService's outer tx). For the recalculateOpenOrders
    // path the lock is released on the next auto-commit — still safer than
    // a plain findById because the brief lock window prevents two replicas
    // from both reading a stale snapshot at the same instant.
    order = replenishorderRepository.findByIdForUpdate(order.getId()).orElse(null);
    if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
        return;
    }
    ...
}
```

**Why `entityManager.refresh()` is NOT called here:** `findByIdForUpdate` is
the first read of `Replenishorder` in this transaction (the inbound `order`
parameter was loaded in the caller's prior list-fetch but is replaced by the
locked variant). The persistence-context-cache scenario that requires
`entityManager.refresh()` in SBDEV-2229 does not apply here — the locked read
is the canonical entity for this method scope.

### Fix B lock-hold semantics by caller path (architect-required clarification)

The effect of `findByIdForUpdate` depends on the **active transaction
context** at call time. This is a runtime property of the caller, not of the
method itself.

| Caller context | Tx scope when `recalculateOrder` runs | Lock window | Race safety |
|---|---|---|---|
| `recalculateForItem` (Fix A `@Transactional`) | Fresh tenant tx opened by Fix A | Held from `findByIdForUpdate` → through `updateRequestedAmount` → through `stockunit save` → released on tx commit | **Full** — no concurrent recalculator on the same row can interleave |
| `StockunitService.{transferStock, adjustReservedAmount}` → `recalculateForItem` | Outer business tx already active (`:145`, `:435`); Fix A's `Propagation.REQUIRED` joins it | Held from `findByIdForUpdate` → through the recalc → **and continuing through the rest of the outer business tx** (e.g., messaging, additional writes) — released only when the outer tx commits | Full for the recalc; see §9 Risk-2 for the **extended lock-hold** impact on hot SKUs |
| `StockunitService.adjustAmount` (`:395`) → `recalculateForItem` | **No outer tx** — `adjustAmount` has no `@Transactional`; Fix A opens a fresh one | Same as Fix A row above (tens of ms, bounded by recalc duration) | Full for the recalc; **but** prior writes in `adjustAmount` (incl. `messageService.sendStockChangeMessage` at `:427`) run in implicit auto-commits outside the recalc tx → asymmetric failure semantics (analogous to §9 Risk-8) |
| `FixLocationAssignmentService.changeActive` → `recalculateForItem` | No outer tx (verified: zero `@Transactional` annotations in `FixLocationAssignmentService.java`); Fix A opens a fresh one | Same as Fix A row above | Full for the recalc; **but** the prior `fixLocationAssignment.save()` is NOT enclosed → asymmetric failure semantics (see §9 Risk-8) |
| `recalculateOpenOrders` path (sweep) → `recalculateOrder` | **No `@Transactional`** on `recalculateOpenOrders`; each repo write hits an implicit auto-commit | `findByIdForUpdate`'s row lock is acquired inside the JPA-driver-managed connection-level tx and **released immediately on the next auto-commit** — likely before `updateRequestedAmount` runs | **Partial** — the lock prevents two replicas from simultaneously re-fetching the same row in the same instant, but does **not** prevent a race between the (now-released) re-fetch and the subsequent `updateRequestedAmount` save. Existing per-order try/catch swallowing `ObjectOptimisticLockingFailureException` remains the safety net. |

**Implication:** Fix B alone is **not sufficient** to fully prevent races on
the `recalculateOpenOrders` path. The 260331 plan explicitly accepted this
trade-off to bound transaction width on the 600+ row sweep. SBDEV-2234
preserves that decision — Fix A applies only to `recalculateForItem`, and the
sweep path remains best-effort with optimistic-lock retry semantics. This is
documented as an explicit out-of-scope decision; revisiting it would require
a separate plan that addresses the long-tx connection-pool concern.

**Why no runtime `Assert.state(...)` for active-tx?** A `TransactionSynchronizationManager.isActualTransactionActive()` assertion in `recalculateOrder` would **break the `recalculateOpenOrders` sweep path** — the sweep deliberately runs each `recalculateOrder` call outside any tx. The contract is therefore documented in code-comment + plan, not enforced at runtime. The verify script (§11.1) includes a NEGATIVE check that no `Assert.state(... isActualTransactionActive ...)` was accidentally added.

### Fix C — Sysprop-persisted `lastRun` cadence

**Problem:** `private Instant lastRun = Instant.EPOCH` is bean-local; multi-replica
defeats cadence throttling.

**Solution:** persist the last-run epoch-milliseconds in the per-tenant
`los_sysprop` table under a new key
`REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS`. Read via
`syspropService.getSysvalue(KEY)` (already cached via Caffeine with proper
tenant scoping). Write via a NEW `syspropService.setSysvalue(String, String)`
method that performs both `@CacheEvict` and an upsert against `los_sysprop`,
all under `@Transactional("tenantTransactionManager")`.

**Step 1 — Add constants to `WmsConstants.java`:**

```java
public static final String SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY
    = "REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS";
public static final String SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_DEFAULT_VALUE
    = "0";
```

**Step 2 — Add a public cache-evicting writer to `SyspropService.java`:**

The only existing write entry point (`createSystemProperty`) is too heavy
(requires `Client`, `workstation`, etc., and only inserts NEW rows). Add a
lightweight upsert helper:

```java
/**
 * Persist a sysprop value for the current tenant (default workstation,
 * system client) and evict the Caffeine cache entry. Use for runtime-managed
 * sysprops where the row may or may not pre-exist.
 */
@CacheEvict(value = "sysprops",
            key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #key")
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void setSysvalue(String key, String value) {
    String workstation = WmsConstants.SystemProperty.WORKSTATION_DEFAULT;
    Long systemClientId = clientService.getSystemClient().getId();
    Optional<Sysprop> existing =
        syspropRepository.findBySyskeyAndClientIdAndWorkstation(key, systemClientId, workstation);
    Sysprop sysProp = existing.orElseGet(() -> {
        Sysprop fresh = new Sysprop();
        fresh.setClientId(systemClientId);
        fresh.setWorkstation(workstation);
        fresh.setSyskey(key);
        fresh.setEntityLock(0);
        return fresh;
    });
    sysProp.setSysvalue(value == null ? "" : value);
    syspropRepository.save(sysProp);
}
```

**Step 3 — Replace the bean-local field in `ReplenishmentOrderMaintenanceService.java`:**

Remove `private Instant lastRun = Instant.EPOCH;` (line 47) and replace
direct field accesses with two private helpers:

```java
// REMOVED: private Instant lastRun = Instant.EPOCH;

private Instant getLastRun() {
    String raw = syspropService.getSysvalue(
        WmsConstants.SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY);
    if (raw == null || raw.isBlank()) {
        return Instant.EPOCH;
    }
    try {
        long ms = Long.parseLong(raw.trim());
        return Instant.ofEpochMilli(ms);
    } catch (NumberFormatException nfe) {
        LOG.warn("Invalid {} value '{}', falling back to EPOCH",
            WmsConstants.SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY, raw);
        return Instant.EPOCH;
    }
}

private void setLastRun(Instant now) {
    try {
        syspropService.setSysvalue(
            WmsConstants.SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY,
            Long.toString(now.toEpochMilli()));
    } catch (Exception e) {
        // Cadence is a soft throttle; failing to persist must not abort the recalc itself.
        LOG.warn("Failed to persist replenishment lastRun: {}", e.getMessage());
        LOG.debug("setLastRun failure", e);
    }
}
```

Update the two call sites:

```java
// :74 (before) — lastRun = Instant.now();
// :74 (after)  — setLastRun(Instant.now());
```

```java
// :165 (before) — return Duration.between(lastRun, now).compareTo(cadence) < 0;
// :165 (after)  — return Duration.between(getLastRun(), now).compareTo(cadence) < 0;
```

**Behavior for fresh tenants:** absent sysprop row → `getSysvalue` returns
`null` → `getLastRun()` returns `Instant.EPOCH` → identical behavior to the
old field initializer. No data migration required.

**Cache coherence note:** `syspropService.setSysvalue` evicts the `sysprops`
cache entry under the tenant-scoped key. The next `getSysvalue` call on the
same replica reloads from DB. Other replicas observe the new value on their
next cache miss (Caffeine TTL: per `CacheConfig`). For a soft-throttle
cadence read, eventual consistency is acceptable — a stale read on a peer
replica during the eviction window simply means one extra recalc may slip
through. The plan ACCEPTS this small window because (a) the throttle is best-effort,
and (b) the alternative (Redis or DB-direct-read on every call) costs more
than it saves.

---

## §6 File Change Summary

| File | Lines touched | Change |
|---|---|---|
| `service/ReplenishmentOrderMaintenanceService.java` | 47 (remove), 74, 93–96 (null-guard rewrite), 119, 124, 165 + 2 new helpers | Add `@Transactional` to `recalculateForItem`; rewrite null branch to early-return + warn (Fix A.1); swap `findById` → `findByIdForUpdate`; remove `lastRun` field; add `getLastRun()` / `setLastRun()` helpers |
| `service/SyspropService.java` | new method ~line 250 | Add public `setSysvalue(String, String)` with `@CacheEvict` + `@Transactional("tenantTransactionManager")` |
| `service/WmsConstants.java` | new constants near line 1051 | Add `SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY` + default `"0"` |
| `test/.../service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | new test methods | Fix A/B/C unit coverage + AC-5 audit grep test |
| `test/.../service/ReplenishmentOrderMaintenanceServiceIntegrationTest.java` (new) | new file | AC-4 TestContainers concurrency test |

---

## §7 Implementation Steps

### §7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. No migration. `los_sysprop` row for `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` is created lazily by `setSysvalue` on first write. | N/A | Pure code change |
| 2 | **Feature flags / system properties** | `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` must be ≥0 for cadence to operate; default 0 (no throttling). Add nothing else. | Implementer (verify) | Verify current tenant value before deploy |
| 3 | **Config / env changes** | None | N/A | |
| 4 | **Deploy-order dependencies** | None — single JAR | N/A | |
| 5 | **Data migration** | None | N/A | |
| 6 | **External systems** | None | N/A | |
| 7 | **Access / permissions** | None | N/A | |
| 8 | **Monitoring / alerts** | Pre-deploy baseline: `wms2.transaction.lock.timeout` rate, `PessimisticLockException` rate. Post-deploy: brief uptick expected as silent races become observable lock timeouts. | Implementer | Existing Micrometer counters |

### §7.2 Implementation Checklist (ordered atomic commits)

> **Order matters.** Fix B's lock is only meaningful inside a transaction; ship
> Fix A in the same commit as Fix B (or strictly before), never after.

- [ ] **C1 (constants)** — Add `SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS_KEY` and `..._DEFAULT_VALUE` to `WmsConstants.java` (near line 1051, sibling to `..._CADENCE_SECONDS_KEY`).
- [ ] **C2 (SyspropService)** — Add public `setSysvalue(String key, String value)` to `SyspropService.java` with `@CacheEvict(value="sysprops", key=...)` matching the existing get-key pattern, and `@Transactional("tenantTransactionManager", rollbackFor=...)`.
- [ ] **C3 (Fix C — service refactor)** — Remove the `private Instant lastRun = Instant.EPOCH` field at line 47; add `getLastRun()` and `setLastRun(Instant)` private helpers; replace `lastRun = Instant.now()` at line 74 with `setLastRun(Instant.now())`; replace `Duration.between(lastRun, now)` at line 165 with `Duration.between(getLastRun(), now)`.
- [ ] **A+B+A.1 (atomic)** — In a single commit: (1) Add `@Transactional("tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` to `recalculateForItem(Long)` at line 93 (Fix A); (2) Rewrite the null branch at lines 94–97 to an early-return + `LOG.warn` (Fix A.1); (3) Replace `replenishorderRepository.findById(order.getId())` with `replenishorderRepository.findByIdForUpdate(order.getId())` at line 124 (Fix B). All three land together because Fix B's lock requires Fix A's tx, and Fix A.1 prevents Fix A from accidentally wrapping the sweep.
- [ ] **Verify Caller Audit** — confirm Caller Propagation Matrix in §0.1 matches reality before deploy. Audit list (with verified outer-tx context as of 2026-05-15):
  - `schedulejob/ReplenishOrderJob.java:155` — no JPA tx (advisory lock only) → Fix A opens fresh tx ✓
  - `service/StockunitService.java:121` `triggerReplenishmentMaintenance`: called from `transferStock` (`:145`, `@Transactional`) and `adjustReservedAmount` (`:435`, `@Transactional`) → Fix A joins outer tx (see §9 Risk-2 for hold-time impact); also called from `adjustAmount` (`:395`, **no `@Transactional`**) → Fix A opens fresh tx, asymmetric-failure pattern analogous to §9 Risk-8
  - `service/FixLocationAssignmentService.java:292` `triggerReplenishmentMaintenance`: called from `changeActive:271` and from other entry points at `:99, :172, :189, :207, :225, :268, :279`. Verified: **no `@Transactional` annotation on any method** in `FixLocationAssignmentService.java` — every caller exhibits the asymmetric-failure pattern (see §9 Risk-8). Fix A opens a fresh tx for each recalc invocation.
  - `service/mobile/MobileReplenishService.java:807` — calls **`recalculateOpenOrders(true)`** NOT `recalculateForItem` → Fix A does NOT apply (out of scope; see §10 #4)
- [ ] **Metric: lock-wait timer (Risk-2 mitigation)** — Add a Micrometer timer `wms2.replenishment.recalc.lock.wait` around the `findByIdForUpdate` call (or wire via a wrapping aspect / explicit sample). Alert if p99 > 1000ms post-deploy. This gives early warning if the join-outer-tx behavior produces unexpected contention on hot SKUs.
- [ ] **Audit assertion** — add unit test grep assertion that no `synchronized` keyword exists on any class in `service/` package (AC-5).
- [ ] **Tests — Unit** — extend `ReplenishmentOrderMaintenanceServiceUnitTest`:
  - AC-1: assert `@Transactional("tenantTransactionManager")` via reflection on `recalculateForItem`.
  - AC-2: stub `findByIdForUpdate`, call `recalculateForItem`, `verify(replenishorderRepository).findByIdForUpdate(...)` and `verify(replenishorderRepository, never()).findById(...)` for the re-fetch.
  - AC-3: assert no `lastRun` field exists (reflection `getDeclaredFields()`); stub `syspropService.getSysvalue` and `syspropService.setSysvalue`; verify both are called by `recalculateOpenOrders(false)`.
- [ ] **Tests — Integration (new)** — write `ReplenishmentOrderMaintenanceServiceIntegrationTest` with TestContainers PostgreSQL:
  - AC-4: two-thread CountDownLatch race. Seed one `Replenishorder` + one `Stockunit`. Thread A and Thread B both call `recalculateForItem(itemDataId)` simultaneously. After both join, assert `Replenishorder.requestedamount == Stockunit.reservedamount` (the pair-invariant).
  - AC-3 cross-replica simulation: two service-instance beans share the same DB. Thread A on instance A calls `recalculateOpenOrders(false)` and persists `lastRun`. Within cadence window, Thread B on instance B calls `recalculateOpenOrders(false)` — assert it skips (reads instance A's persisted `lastRun`).
- [x] **Tests — Regression** — `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest`: 41/41 PASS.
- [x] **Verify script** — `bash sbdocs/9-System/scripts/verify-SBDEV-2234-replenishment-maintenance-tx-and-lock.sh`: 23/23 PASS.
- [x] **Code review** — `code-reviewer` agent: 1 CRITICAL fixed (setSysvalue precise row targeting), 2 HIGH documented as accepted limitations.
- [x] **Full suite** — `mvn test`: 3921 tests, 0 failures, 67 skipped (2026-05-15T14:03:01).
- [x] **Plan post-rollout** — status: `implemented`; commit: `f478b2d`; PR: https://github.com/SiteBossInc/wms2-api/pull/22

### §7.3 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **No (removes existing)** | Fix C removes the bean-local `lastRun` field; replaces with `los_sysprop` row read via Caffeine cache. Cache is per-replica but the source of truth is the per-tenant DB; eventual consistency is acceptable for a soft throttle. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **Yes (low)** | Fix A wraps `recalculateForItem` in a transaction — holds one connection for the duration of the per-item recalc (~tens of ms; bounded by N orders for the single itemDataId, typically 1-3). Negligible at the `replicas × tenants × maxPoolSize` math. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` job? | **No** | `ReplenishOrderJob` is unchanged; it calls `recalculateForItem` / `recalculateOpenOrders` from outside any prior tx and the new annotation propagates cleanly. |
| 4 | **Long transactions** | Hold a DB transaction across additional calls or external I/O? | **Yes (bounded)** | Fix A's `@Transactional` brackets the per-item loop. Per-item recalc is DB-only (no external I/O, no OMS call). Typical hold time tens of ms; bounded by HikariCP `connectionTimeout=30s`. Acceptable. |
| 5 | **Request affinity** | Assume same-replica follow-up? | **No** | No in-memory session state introduced. |
| 6 | **Retry / idempotency** | Break if a replica dies mid-op? | **Yes (improved)** | Fix B's PESSIMISTIC_WRITE + Fix A's atomic tx mean a replica dying mid-recalc leaves the `Replenishorder` row unmodified (Hibernate rollback on tx close), and the FOR UPDATE lock is released by Postgres on connection close. A retry from another replica re-acquires the lock and re-computes consistently. Strict improvement over current behavior. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **No** | No new async paths. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **Yes (primary mechanism)** | Fix B's `findByIdForUpdate` is invoked inside Fix A's `@Transactional("tenantTransactionManager")` — PostgreSQL row lock coordinates across all replicas via the shared per-tenant DB. Lock timeout governed by `jakarta.persistence.lock.timeout` already configured. |
| 9 | **Cache invalidation** | Write to a cached entity? | **Yes** | Fix C's `syspropService.setSysvalue` writes the `los_sysprop` row whose `getSysvalue` is `@Cacheable("sysprops")`. The new method has `@CacheEvict` with the matching tenant-scoped key. Cross-replica eviction is NOT instantaneous (Caffeine is per-replica); the plan accepts an eventual-consistency window for the soft cadence throttle. See §5 Fix C rationale. |
| 10 | **External notifications** | Send HTTP / message inside a transaction? | **No** | No OMS or webhook calls in this code path. |

#### Evidence

| Concern # | What was done / verified | File:line or reference |
|---|---|---|
| 2 | Per-item recalc loops over `findByStateAndItemdataId` — typically 1-3 orders per `itemDataId` (confirmed via tenant DB query) | `ReplenishmentOrderMaintenanceService.java:98` |
| 4 | Loop has no external I/O; only repository writes; bounded duration | `ReplenishmentOrderMaintenanceService.java:102-112` |
| 8 | `findByIdForUpdate` declared with `@Lock(PESSIMISTIC_WRITE)` and JPQL `@Query` | `ReplenishorderRepository.java:27-29` |
| 9 | `SyspropService.setSysvalue` will use the identical `@CacheEvict` key formula as `getSysvalue` (`Cacheable`); Caffeine is per-replica per `CacheConfig.java` | `SyspropService.java:53, 289` |

### §7.4 v2-only Constraint Checklist

| # | Constraint | Status | Notes |
|---|---|---|---|
| 1 | All `@Transactional` annotations specify `value = "tenantTransactionManager"` | ✓ | Fix A uses tenant TM; Fix C's `setSysvalue` uses tenant TM |
| 2 | `jakarta.*` imports (not `javax.*`) | ✓ | `jakarta.persistence.LockModeType` already in `ReplenishorderRepository` |
| 3 | No `mockStatic()` in tests (Mockito 3.3.3 compatibility) | ✓ | Unit tests use only instance-mocks |
| 4 | No JPA association annotations (`@OneToMany`, `@ManyToOne`) added | ✓ | Manual FK lookups preserved |
| 5 | Entity comparison by ID, not `.equals()` | ✓ | No new entity-equality checks introduced |
| 6 | Cache eviction explicit for any `@Cacheable` write path | ✓ | `setSysvalue` has matching `@CacheEvict` |
| 7 | Spring Boot 3.5.9 + Java 21 features only (no Spring Boot 2 API) | ✓ | No deprecated API |
| 8 | If new `@Scheduled` added → ShedLock or single-instance documented | N/A | No new scheduled job |

---

## §8 Testing Plan

### Unit tests — `ReplenishmentOrderMaintenanceServiceUnitTest` (extend existing class)

| Test method | Acceptance Criterion | What it asserts |
|---|---|---|
| `recalculateForItem_isAnnotatedWithTenantTransactionalManager` | **AC-1** | Reflection: `recalculateForItem(Long)` method has `@Transactional` with `value() == "tenantTransactionManager"` |
| `recalculateOpenOrders_isNOTAnnotatedWithTransactional` | **AC-1** | Reflection: `recalculateOpenOrders(boolean)` has no `@Transactional` annotation (per 260331 decision) |
| `recalculateForItem_callsFindByIdForUpdate_notFindById` | **AC-2** | Stub `replenishorderRepository.findByIdForUpdate(...)`; call `recalculateForItem(itemId)`; verify `findByIdForUpdate` called and `findById` (for re-fetch) never called |
| `lastRunFieldDoesNotExist` | **AC-3** | Reflection: `getDeclaredFields()` of class has no field named `lastRun` |
| `recalculateOpenOrders_readsAndWritesLastRunViaSyspropService` | **AC-3** | Stub `syspropService.getSysvalue(KEY)` → "100"; call `recalculateOpenOrders(false)` outside cadence; verify `syspropService.setSysvalue(KEY, ...)` called with current epoch-ms string |
| `recalculateOpenOrders_skipsWithinCadence_whenSyspropLastRunIsRecent` | **AC-3** | Stub `getSysvalue(KEY)` → recent epoch-ms; assert no `findByState` / iteration occurs |
| `concurrencyPatternAudit_noSynchronizedKeywordInServiceLayer` | **AC-5** | Walk `src/main/java/net/aim_ai/wms/service` `.java` files; assert none contain `synchronized` token (excluding string literals / comments) |
| `recalculateForItem_oneFailingOrderDoesNotRollbackSiblings` | regression | Mock one order to throw `BusinessException`; verify sibling orders still get `save()`-d (try/catch loop semantics preserved despite `@Transactional`) |
| `recalculateForItem_withNullItemDataId_earlyReturnsWithoutSweep` | **AC-6** (Fix A.1) | Call `recalculateForItem(null)`; verify (a) `replenishorderRepository.findByStateAndItemdataId` is NOT called, (b) no `findAllByState` / no iteration occurs, (c) one `WARN` log line is emitted mentioning "recalculateForItem(null)". Confirms the null branch no longer routes into the sweep. |

### Integration tests — `ReplenishmentOrderMaintenanceServiceIntegrationTest` (NEW file, TestContainers PostgreSQL)

| Test method | Acceptance Criterion | What it asserts |
|---|---|---|
| `concurrentRecalculateForItem_preservesPairInvariant` | **AC-4** | Seed `Replenishorder R` + `Stockunit S`. Two threads call `recalculateForItem(itemDataId)` simultaneously via a start-gate `CountDownLatch`. After both join: `Replenishorder.requestedamount == Stockunit.reservedamount` (no drift). |
| `crossReplicaCadence_secondCallSkipsWhenFirstSetSysprop` | **AC-3 cross-replica** | Two service instances share one DB. Instance A: `recalculateOpenOrders(false)` (sets sysprop `lastRun`). Within cadence window, Instance B: `recalculateOpenOrders(false)` — assert no iteration (skipped via sysprop read). |
| `pessimisticLockTimeoutSurfacesAsException_notSilentDrift` | regression | One thread holds a FOR UPDATE lock past timeout; second thread's `recalculateForItem` receives `LockTimeoutException` (or `PessimisticLockingFailureException`) — `RestExceptionHandler` would map this to HTTP 409 for HTTP callers. No silent corruption. |
| `recalcForItem_fromStockunitService_joinsOuterTx_lockHeldUntilOuterCommit` | **per-caller (Risk-2)** | Seed `Replenishorder R` and `Stockunit S`. From a test method annotated `@Transactional("tenantTransactionManager")`, call `stockunitService.adjustReservedAmount(stockUnit, ..., "test")`. Assert the FOR UPDATE lock on `R` is **still held** after `recalculateForItem` returns but **before** the outer adjustReservedAmount tx commits (poll `pg_locks` for a `Replenishorder` row lock on the test thread). Validates §0.1 row 11 / §9 Risk-2 behavior. |
| `recalcForItem_fromFixLocationChangeActive_freshTxOnly_assignmentNotRolledBackOnRecalcFail` | **per-caller (Risk-8)** | Seed a `FixLocationAssignment` with `active=false`. Stub `replenishorderRepository.findByIdForUpdate` to throw. Call `fixLocationAssignmentService.changeActive(id)`. Assert (a) the recalc threw and was swallowed by `triggerReplenishmentMaintenance`'s try/catch (or surfaced as a 500, depending on impl), (b) `fixLocationAssignment.active` is **still flipped** to `true` in the DB (proves the prior `save()` was NOT rolled back by the recalc failure). Validates §0.1 row "FixLocationAssignmentService.changeActive" / §9 Risk-8 asymmetry. |
| `recalcForItem_fromReplenishOrderJob_opensFreshTx` | **per-caller** | Without any outer `@Transactional` on the test method, invoke `replenishOrderJob` flow that calls `recalculateForItem(itemId)`. Assert a new transaction is opened (e.g., observe via `TransactionSynchronizationManager.getCurrentTransactionName()` from a custom interceptor / synchronization registered before invocation). Validates §0.1 row "ReplenishOrderJob". |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Single-item replenishment recalc works after fix | Dev/staging, 1 replica | 1. Identify an item with ≥1 open replenishorder. 2. Trigger a stock movement for that item (mobile pick or admin UI). 3. Observe `replenishorder.requestedamount` updates within 2s. | `Replenishorder.requestedamount` updated correctly; no 500 errors; `Stockunit.reservedamount` matches expected. | |
| Cadence throttling works across service restart | Dev/staging, 1 replica | 1. Set `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS=60`. 2. Call `recalculateOpenOrders` (via admin trigger or job). 3. Restart wms2-api. 4. Within 60s of original call, trigger again. | Second call skips (reads `lastRun` from `los_sysprop`, not lost JVM field). Log shows "skip for cadence". | |
| Cadence throttling works across replicas | Staging, 2 replicas | 1. Set cadence to 60s. 2. Hit replica A's admin endpoint to trigger recalc. 3. Within 30s, hit replica B's endpoint. | Replica B reads the sysprop and skips; no double-run. | |
| No `synchronized` in service layer | Any | `grep -rn "synchronized" v2/wms2-api/src/main/java/net/aim_ai/wms/service --include="*.java"` | Zero matches (excluding any in import / comment text). | |
| Two-operator race produces no drift | Staging, 2 replicas | 1. Two mobile operators on different devices confirm picks for the same item simultaneously. 2. Query `SELECT requestedamount FROM replenishorder WHERE id=R;` and `SELECT reservedamount FROM stockunit WHERE id=S;` | Pair-invariant holds. No 500 errors visible to either operator (or, at worst, one operator sees HTTP 409 retry message). | |
| Sysprop row visible in DB post-first-run | Staging | `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey = 'REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS';` | One row with epoch-ms value updated each recalc cycle. | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest` | | |
| `mvn verify -Dtest=ReplenishmentOrderMaintenanceServiceIntegrationTest` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2234-replenishment-maintenance-tx-and-lock.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| H2-based variant of the concurrency test | H2 does not implement PostgreSQL `SELECT ... FOR UPDATE` row-blocking semantics; would pass even without the fix |
| Load test of cadence throttle precision under 50+ concurrent triggers | The cadence is a soft throttle; eventual consistency on the sysprop cache is an accepted trade-off (§5 Fix C) |
| Test for `recalculateOpenOrders` per-order auto-commit width | Behavior intentionally preserved per 260331; existing tests already exercise this |

---

## §9 Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Fix A breaks `MobileReplenishService` outer transaction** by mis-propagation | Low | Medium | `Propagation.REQUIRED` (default) joins the existing outer tx; verified by reading caller. Add an integration test invoking the mobile-replenish flow end-to-end. |
| **Fix B introduces lock contention on hot items** (high-velocity SKUs) | Medium | Medium-High | **Re-quantified post-architect-review:** lock hold time depends on caller context. For `ReplenishOrderJob` callers (no outer tx), `FixLocationAssignmentService` callers (all entry points, no `@Transactional` anywhere in that file), and `StockunitService.adjustAmount` (`:395`, no `@Transactional`), hold time is bounded by per-item recalc duration (tens of ms — same as the job path). **For `StockunitService.transferStock` (`:145`) and `adjustReservedAmount` (`:435`) callers only, the `Propagation.REQUIRED` join means the FOR UPDATE lock on the `Replenishorder` row(s) is held until the outer business tx commits — potentially 100–500ms including `messageService.sendStockChangeMessage` and other intra-tx writes.** Under high-throughput stock-movement flows (e.g., parallel mobile-picking on the same item), this may serialize concurrent operators on the same item's replenishment orders. `jakarta.persistence.lock.timeout` already configured. Worst case: REST callers see HTTP 409 → retry, still far better than silent drift. **Mitigation:** add a Micrometer timer `wms2.replenishment.recalc.lock.wait` measuring time spent waiting on `findByIdForUpdate` and alert if p99 exceeds 1000ms. Monitor `wms2.transaction.lock.timeout` post-deploy; alert at 1% rate. |
| **Fix C cache eviction is per-replica → stale `lastRun` on peer replicas** | Medium | Low | Soft-throttle semantics accept eventual consistency. Worst case: one extra recalc slips through during the eviction window. Documented in §5. |
| **Sysprop row contention if cadence-write fires across many replicas** | Low | Low | `setSysvalue` is a single-row UPSERT under tenant tx; row-level Postgres lock resolves instantly. The cadence-sync write is throughput-light (once per cadence period per replica). |
| **`@Transactional` swallows per-order exceptions and rolls back batch unexpectedly** | Low | High | Existing try/catch inside the loop swallows exceptions before they reach the tx boundary, preventing rollback. Regression test (`recalculateForItem_oneFailingOrderDoesNotRollbackSiblings`) locks this in. |
| **Sysprop write failure aborts entire recalc** | Low | Medium | `setLastRun` wraps the call in its own try/catch and logs; cadence becomes effectively no-throttle on persistent failure but recalc itself proceeds. |
| **Tenant context not set when `setSysvalue` is called inside `recalculateOpenOrders` from a scheduled job** | Medium | High | `ReplenishOrderJob` already iterates tenants and sets `TenantContext` per tenant before calling `recalculateOpenOrders` (verified via `wms2-scheduled-jobs-catalog.md`). Add an explicit assertion at the top of `setLastRun` that `TenantContext.getCurrentTenant()` is non-null. |
| **Plan ships in wrong order (Fix A landed after Fix B)** — lock held outside tx → no serialization | Low | High | §7.2 explicitly requires A+B atomic commit. Verify script's NEGATIVE check for `findById` failing while POSITIVE check for `findByIdForUpdate` passing would surface this. |
| **`FixLocationAssignmentService.changeActive` asymmetric failure** — the `setActive(...) + save()` at `:276-277` runs in its own implicit auto-commit, **outside** Fix A's new `@Transactional` on the subsequent `recalculateForItem` call (because `changeActive` itself has no `@Transactional`). If the recalc throws, the active-flip is **not** rolled back. | Medium | Medium | Documented in §0.1 Caller Propagation Matrix and §5 Fix A caller-side propagation. This asymmetry **predates SBDEV-2234** — the bug was the missing `@Transactional` on `changeActive`, not anything Fix A introduces. Recommend a follow-up ticket to add `@Transactional("tenantTransactionManager")` to `changeActive` so the assignment flip and the recalc become atomic. Out of scope for SBDEV-2234. |
| **Fix A.1 changes null-branch semantics silently** — historical caller passing `null` (none in current codebase, verified via grep) would now early-return instead of running the sweep | Very Low | Low | Verified 2026-05-15: zero `recalculateForItem(null)` call sites in `v2/wms2-api/src/main/java`. `LOG.warn` is emitted to surface any unexpected null caller in production. Verify script check `A4` asserts the early-return + warn shape is present. |

---

## §10 Open Questions / Resolved Decisions

### Resolved decisions (locked in by user during planning)

1. **Scope reframe (resolved 2026-05-15)** — The original SBDEV-2234 framing was
   "remove `synchronized` from `ReplenishmentOrderMaintenanceService`". That
   keyword was already removed in commit `b68cbbf4` per archived plan `260331`.
   The ticket is reframed as: "harden the remaining concurrency gaps (Fix A
   `@Transactional`, Fix B `findByIdForUpdate`, Fix C sysprop-persisted
   cadence)".
2. **Cadence approach (resolved 2026-05-15)** — Use the existing `SyspropService`
   + `los_sysprop` table to persist `lastRun` rather than introducing Redis or
   a new advisory-lock pattern. Rationale: `SyspropService` is the canonical
   per-tenant mutable-config store; the throttle is best-effort; eventual
   consistency is acceptable.
3. **`recalculateOpenOrders` stays non-transactional (preserved from 260331)** —
   The 600+ row sweep MUST NOT be wrapped in `@Transactional` to avoid a long
   transaction holding a tenant pool connection. Fix A applies ONLY to
   `recalculateForItem`.
4. **`MobileReplenishService:807` is out of scope (resolved 2026-05-15 post-architect-review)** —
   The original §0 table mis-classified row 12 as "covered by Fix A scope".
   Verification confirms `MobileReplenishService.confirmAndClose` calls
   `recalculateOpenOrders(true)` at line 807, **not** `recalculateForItem`.
   Fix A does not apply to that site. The fact that the 600+ row sweep
   currently runs inside the long mobile transaction is a **separate concern**
   filed as a follow-up ticket (see Open Questions #4).
5. **Null-itemDataId guard added as Fix A.1 (resolved 2026-05-15 post-architect-review)** —
   The pre-Fix-A null branch routed into `this.recalculateOpenOrders()`. After
   Fix A wraps the method in `@Transactional`, that delegate would have run
   the 600+ row sweep inside the recalc tx — violating decision #3. The null
   branch now early-returns with `LOG.warn`. Verified no production caller
   passes `null` today.
6. **No runtime tx-active assertion in `recalculateOrder` (resolved 2026-05-15 post-architect-review)** —
   Adding `Assert.state(TransactionSynchronizationManager.isActualTransactionActive(), ...)`
   to `recalculateOrder` would break the `recalculateOpenOrders` sweep path,
   which intentionally calls `recalculateOrder` outside any tx. The contract
   is documented in code comments and the §5 Fix B caller-context table
   instead. Verify script has a NEGATIVE check to prevent accidental
   re-introduction of the assertion.
7. **`FixLocationAssignmentService` and `StockunitService.adjustAmount` asymmetric failure is pre-existing (resolved 2026-05-15 post-architect-review)** —
   Verified: `FixLocationAssignmentService.java` has **zero** `@Transactional`
   annotations on any method (not just `changeActive`); `StockunitService.adjustAmount`
   (`:395`) likewise has no `@Transactional` (only `transferStock:145` and
   `adjustReservedAmount:435` do). For every such caller, the prior `save()`
   / `messageService.sendStockChangeMessage` / etc. runs in implicit auto-commits;
   Fix A's new tx wraps only the recalc. A failure in the recalc rolls back
   only the recalc, not the prior writes. This is a **pre-existing bug**
   unrelated to SBDEV-2234, documented in §9 Risk-8 and §0.1 and filed as a
   follow-up.

### Open questions

| # | Question | Why it matters | Default if unresolved |
|---|---|---|---|
| 1 | Should `setSysvalue` be added to `SyspropService` as a new generic helper, or a one-off `setReplenishmentLastRun(Instant)` helper specific to this plan? | Generic helper has reuse value but expands API surface; one-off keeps blast radius minimal | Generic helper (per Fix C §5) — easier to grep + reuse |
| 2 | Should the verify script's `mvn test` invocations be gated behind a CI-only env var, or always run? | Local-dev runs of the verify script may be slow if `mvn test` always fires | Always run; tag with SKIP if `SKIP_MVN_TESTS=1` env var set |
| 3 | Should the cross-replica cadence integration test (AC-3) be in-scope for this plan or deferred? | Two-instance-bean test infra may not exist yet in `wms2-api` test harness | In-scope; if test infra doesn't support two beans, downgrade to a unit-level mock test and document the gap |
| 4 | Should the `MobileReplenishService:807` long-mobile-tx sweep be addressed in a follow-up ticket? | The 600+ row `recalculateOpenOrders(true)` call currently runs inside the mobile-confirm `@Transactional`, holding a tenant pool connection for the duration of the sweep. Architect flagged this as out-of-scope but worth a follow-up. | **Yes — file as a follow-up SBDEV ticket** after SBDEV-2234 lands. Likely fix: change the call site to `@Async` or invoke from a post-commit hook so the sweep runs outside the mobile request tx. |
| 5 | Should `FixLocationAssignmentService.changeActive` get `@Transactional("tenantTransactionManager")` to fix the asymmetric-failure issue documented in §9 Risk-8? | Pre-existing bug; out of scope for SBDEV-2234. Architect flagged for follow-up. | **Yes — file as a follow-up SBDEV ticket**. Trivial fix; not bundled here to keep SBDEV-2234 atomic and reviewable. |

---

## Completeness Checklist

| # | Item | Status |
|---|---|---|
| 1 | §0 affected-sites table enumerated with in-scope/out-of-scope rationale | ✓ |
| 2 | Problem statement with user-visible symptoms + reproduction | ✓ |
| 3 | Root cause per bug with file:line + code snippets | ✓ |
| 4 | Regression chain (predecessor commit, archived plan) documented | ✓ |
| 5 | Architecture overview with ASCII flow + key-files table | ✓ |
| 6 | Fix design per bug with Before/After code blocks | ✓ |
| 7 | File change summary table | ✓ |
| 8 | Implementation steps ordered with atomic-commit guidance | ✓ |
| 9 | Horizontal Scalability Validation (all 10 rows) | ✓ |
| 10 | v2-only constraint checklist (all 8 rows) | ✓ |
| 11 | Testing plan: unit + integration + regression + manual | ✓ |
| 12 | Risks & mitigations table | ✓ |
| 13 | Open questions / resolved decisions | ✓ |
| 14 | Acceptance script path referenced (`§11`) | ✓ |

---

## §11 Acceptance & Implementation

### 11.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2234-replenishment-maintenance-tx-and-lock.sh`

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 3 fixes (A+B+C) across 3 files; one new test class; concurrency change but well-bounded |
| **Pre-draft step** | done (analyst + ralplan consensus) | Plan grounded in verified code facts and DB state |
| **Plan-review step** | `critic` | Concurrency fix — second pair of eyes recommended |
| **Implementation shape** | `executor` | Mechanical refactor + one new test class |
| **Verification step** | verify-script + `verifier` | Mandatory |
| **Code-review step** | `code-reviewer` | Concurrency + new public API on `SyspropService` warrants review |
| **Commit step** | `git-master` (atomic A+B+C) | Three logical commits acceptable: C1+C2 (sysprop infra), C3 (Fix C wire-up), A+B (atomic) |

### 11.3 ADR (Architecture Decision Record)

**Decision:** Fix concurrency hardening for `ReplenishmentOrderMaintenanceService`
via three coordinated changes: (A) `@Transactional("tenantTransactionManager")`
on `recalculateForItem(Long)` only, (B) replace `findById` with
`findByIdForUpdate` in `recalculateOrder(...)` re-fetch, (C) replace
JVM-bean-local `lastRun` field with sysprop-persisted
`REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` via a new
`SyspropService.setSysvalue(String, String)` helper.

**Decision drivers:**
1. v2 deploys multiple replicas; JVM-level coordination provides zero safety.
2. `ReplenishorderRepository.findByIdForUpdate` already exists — minimal code
   change, maximum safety.
3. `SyspropService` is the canonical tenant-scoped mutable-config store; reuse
   beats new infrastructure.

**Alternatives considered:**
- **Option B — Pessimistic lock only (Fix B without Fix A):** rejected. Lock
  released immediately after re-fetch auto-commit; the race window between
  re-fetch and `updateRequestedAmount` remains.
- **Option C — Advisory lock at `recalculateForItem` callers:** rejected.
  Acquired at HTTP call site → wide contention footprint. The job already
  holds a narrower scoped advisory lock (`JobLockId.REPLENISH_ORDER`); duplicating
  at HTTP layer over-serializes.
- **Option D — Redis-backed cadence (replace `lastRun` field with Redis):**
  rejected. Adds a new infrastructure dependency for a soft throttle; the
  sysprop approach achieves the same correctness at a fraction of the
  operational cost.

**Why chosen:** Option A (the chosen design) is the unique combination that
fixes correctness at the DB layer (Fix A+B) without introducing new
infrastructure (Fix C reuses existing sysprop store). Fix B alone is
insufficient because the lock has no transactional scope to live within;
Fix A alone is insufficient because the re-fetch is still a plain `findById`
race.

**Consequences:**
- **Positive:** correctness across replicas; visible HTTP 409 retries replace
  silent drift; no new infrastructure; existing test infra suffices.
- **Negative:** brief contention window on hot SKUs (mitigated by 5s lock
  timeout); per-replica Caffeine cache means cross-replica cadence has an
  eventual-consistency window (accepted for soft throttle).

**Follow-ups:**
- Open a directive in `project_memory_add_directive` after rollout: "Any
  `@Service` bean with mutable instance state must persist it to the DB or
  Redis; never assume single-replica."
- Sweep for other JVM-bean-local state across `service/` after this lands
  (potential follow-up audit ticket).
