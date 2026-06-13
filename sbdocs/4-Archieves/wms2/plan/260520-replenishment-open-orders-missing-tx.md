---
title: "Replenishment Open-Orders Sweep — Missing Transaction Around recalculateOrder"
ticket: ""
ticket_url: ""
type: "bugfix"
priority: "high"
status: "archived"
project:
  - wms2
version: "v2"
requester: ""
created: "2026-05-20"
updated: "2026-05-20"
implemented: "2026-05-20"
pr: "https://github.com/SiteBossInc/wms2-api/pull/30"
commit: "d7bd64fd"
db_verified: false
related:
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2234-replenishment-maintenance-tx-and-lock.md
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md
tags:
  - plan
  - wms2
  - replenishment
  - concurrency
  - pessimistic-lock
  - transaction
  - aop-self-call
  - regression
---

# Replenishment Open-Orders Sweep — Missing Transaction Around `recalculateOrder`

**Ticket:** _(none yet — followup to SBDEV-2234)_
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high (production error in tenant `hydra-nywh`, 2026-05-20)
**Status:** draft
**Date:** 2026-05-20

> **Observed in production (tenant hydra-nywh, 2026-05-20):**
>
> ```
> org.springframework.dao.InvalidDataAccessApiUsageException: Query requires transaction be in progress
>   at ReplenishmentOrderMaintenanceService.recalculateOrder(ReplenishmentOrderMaintenanceService.java:125)
>   at ReplenishmentOrderMaintenanceService.recalculateOpenOrders(ReplenishmentOrderMaintenanceService.java:85)
>   at ReplenishOrderJob.lambda$executeForTenant$3(ReplenishOrderJob.java:183)
> ```
>
> The stack trace is the scheduled-job → sweep path. `ReplenishOrderJob:183` invokes
> `recalculateOpenOrders(false)`; line 85 is the self-call to `recalculateOrder(order, ctx)`
> inside the sweep loop; line 125 is `replenishorderRepository.findByIdForUpdate(order.getId())`.
> This is the SBDEV-2234 Fix-B `@Lock(PESSIMISTIC_WRITE)` call — it requires an active
> Spring-managed transaction, which the sweep path does not provide.

---

## §0 Affected Sites

| # | File:line | Construct | In-scope? |
|---|-----------|-----------|-----------|
| 1 | `service/ReplenishmentOrderMaintenanceService.java:71-91` | `recalculateOpenOrders(boolean force)` — no `@Transactional`, calls `this.recalculateOrder(order, ctx)` at `:85` (AOP self-call → proxy bypass) | **yes** — Fix A: change the sweep-loop invocation to `self.recalculateOrder(order, ctx)` |
| 2 | `service/ReplenishmentOrderMaintenanceService.java:120-158` | `recalculateOrder(Replenishorder, RecalcContext)` — **package-private**, no `@Transactional`, line 125 calls `findByIdForUpdate` which requires an active tx | **yes** — Fix A: make `public` + annotate `@Transactional("tenantTransactionManager", REQUIRED)` |
| 3 | `service/ReplenishmentOrderMaintenanceService.java:67-69` | `recalculateOpenOrders()` no-arg — delegates to `this.recalculateOpenOrders(false)` | **yes (verify-only)** — no change needed; no external callers of the no-arg overload exist that depend on tx behavior. Verified by grep. |
| 4 | `service/ReplenishmentOrderMaintenanceService.java:116-118` | `recalculateOrder(Replenishorder)` single-arg — package-private, no `@Transactional`, only used by tests | **out-of-scope** (see Open Question #2 — symmetry-only refactor) |
| 5 | `service/ReplenishmentOrderMaintenanceService.java:93-114` | `recalculateForItem(Long)` — already `@Transactional("tenantTransactionManager")` per SBDEV-2234 Fix A; calls `this.recalculateOrder(order, ctx)` inside the loop at `:108` | **no change needed** — the outer `@Transactional` on `recalculateForItem` already provides a tx scope that `this.recalculateOrder` runs inside. The AOP self-call still bypasses `recalculateOrder`'s **own** annotation, but with `Propagation.REQUIRED` semantics it would join the caller's tx anyway — same effective behavior |
| 6 | `service/mobile/MobileReplenishService.java:806` | calls `recalculateOpenOrders(true)` inside outer `@Transactional` | **out-of-scope** — separate concern, SBDEV-2234 §10 Open Question #4 already filed |
| 7 | `schedulejob/ReplenishOrderJob.java:176` | calls `recalculateForItem(itemId)` under advisory lock | **no change** — caller already inside per-item path that has its own `@Transactional` (SBDEV-2234) |
| 8 | `schedulejob/ReplenishOrderJob.java:183` | calls `recalculateOpenOrders(false)` under advisory lock — the trigger that surfaced this bug | **no change** — Fix A in row 2 fixes it without touching the caller |
| 9 | `test/.../unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java:1192-1203` | `AC-1 neg` — asserts `recalculateOpenOrders(boolean)` has NO `@Transactional` | **keep** — Fix A does not annotate `recalculateOpenOrders`; the per-order auto-commit design from 260331 is preserved |
| 10 | `test/.../unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java:1175-1271` | `ConcurrencyHardening` nested class | **yes — extend** with new positive tests AC-NEW-1 / AC-NEW-2 |

**Scope rationale.** Rows 1–2 form the minimal in-scope diff: annotate the
package-private worker `recalculateOrder(Replenishorder, RecalcContext)` and
re-route the **one** sweep-loop self-call through a `@Lazy @Autowired` self
proxy so Spring's AOP can open a per-order transaction. The two-arg
`recalculateOrder` is the only function in the cluster whose AOP proxy needs
to fire — the single-arg variant (row 4) is test-only and the
`recalculateForItem` path (row 5) already provides its own enclosing tx. Rows
3, 7, 8 are verify-only; row 6 is a known separate concern.

---

## 1. Problem Statement

`ReplenishOrderJob` runs every cron tick. After acquiring its advisory lock
and per-tenant `TenantContext`, in the cycle where no item-data IDs were
affected it falls into the cadence-throttled sweep branch
(`ReplenishOrderJob.java:183`):

```java
} else {
    // Nothing changed this cycle — respect cadence
    replenishmentOrderMaintenanceService.recalculateOpenOrders(false);
}
```

The job class has no `@Transactional`. `recalculateOpenOrders(boolean)` also
has no `@Transactional` — intentionally, per archived plan `260331` which
chose to keep the 600+ row sweep on per-order auto-commit rather than wrap
the entire sweep in a single long transaction.

`recalculateOpenOrders` then iterates and calls
`recalculateOrder(order, ctx)` (line 85). That worker, at line 125, calls
`replenishorderRepository.findByIdForUpdate(order.getId())`. The repository
declares `@Lock(PESSIMISTIC_WRITE)` on this method — which **requires** a
Spring-managed transaction to exist when the query is issued. With no tx
active, Spring/Hibernate raises:

```
org.springframework.dao.InvalidDataAccessApiUsageException: Query requires transaction be in progress
```

The exception bubbles out of `recalculateOrder` to the outer sweep loop's
`try/catch`, where it is logged at `WARN`-level per order (lines 87–88) — so
the job appears to run cleanly while in fact **every order in the sweep is
silently skipped**. No replenishment recalculation happens on the sweep
path. The HTTP path (`recalculateForItem`, called from `StockunitService` /
`FixLocationAssignmentService` / `ReplenishOrderJob`'s per-item branch) is
unaffected because `recalculateForItem` carries its own
`@Transactional("tenantTransactionManager")` (SBDEV-2234 Fix A) so
`findByIdForUpdate` inherits a valid tx scope.

**User-visible symptom.** Operators see drift between
`Replenishorder.requestedamount` and `Stockunit.reservedamount` on items that
**don't** receive a stock movement (which would trigger the HTTP per-item
path). Anything that previously relied on the cron sweep to converge
quietly stops converging. Log noise: a steady stream of
`Failed to recalculate replenishOrder=... : Query requires transaction be in progress`
warnings per cron tick.

**Reproduction (deterministic).**

1. Pick any tenant with at least one PROCESSABLE `Replenishorder`.
2. Wait for `ReplenishOrderJob` to reach the "nothing changed" branch (or
   force it by ensuring no `triggerReplenishmentMaintenance` calls fired
   since the last tick).
3. Observe `application.log`: one
   `InvalidDataAccessApiUsageException: Query requires transaction be in progress`
   warning per order in PROCESSABLE state.
4. Query `SELECT id, requestedamount, modified FROM replenishorder WHERE state = 'PROCESSABLE'`
   before and after the cron tick — `modified` does NOT advance for any
   row.

---

## 2. Root Cause Analysis

### Bug — `recalculateOrder` has no transaction and is called via `this.`

The package-private worker at line 120 has **no `@Transactional` annotation**:

```java
// :120 — declared package-private, no @Transactional
void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null) {
        return;
    }
    // Re-fetch with pessimistic write lock to serialize concurrent writers on the same row
    order = replenishorderRepository.findByIdForUpdate(order.getId()).orElse(null);   // :125 — explodes
    ...
}
```

`recalculateOpenOrders(boolean)` calls it via `this.` (Java implicit-self):

```java
// :71-91
public void recalculateOpenOrders(boolean force) {
    if (!force && shouldSkipForCadence()) {
        return;
    }
    setLastRun(Instant.now());
    List<Replenishorder> openOrders = replenishorderRepository.findByState(WmsConstants.State.PROCESSABLE);
    RecalcContext ctx = buildRecalcContext(openOrders);
    for (Replenishorder order : openOrders) {
        if (Boolean.TRUE.equals(order.getManuallyoverridepriority())) {
            continue;
        }
        try {
            recalculateOrder(order, ctx);   // :85 — this.recalculateOrder, bypasses Spring AOP proxy
        } catch (Exception e) {
            LOG.warn("Failed to recalculate replenishOrder={} : {}", order.getNumber(), e.getMessage());
            LOG.debug("Recalculation failure", e);
        }
    }
}
```

Two compounding facts produce the failure:

1. **No annotation.** Even if the call did go through the proxy,
   `recalculateOrder` itself has no `@Transactional`, so the proxy would not
   open a tx. The `findByIdForUpdate` at line 125 has nothing to live in.

2. **AOP self-call bypass.** Even if we annotated `recalculateOrder`, Spring
   AOP proxies only wrap **external** calls into the bean. A `this.method()`
   call inside the same class bypasses the proxy entirely (the bytecode does
   not go through the proxy stub). So the annotation alone is not enough —
   the sweep-loop call site must invoke the worker through the proxy
   reference, not `this`.

Why `recalculateForItem` (the HTTP path) doesn't fail: it carries
`@Transactional("tenantTransactionManager")` from SBDEV-2234 Fix A. When
the HTTP request enters the bean, Spring's proxy starts a tenant transaction.
The inner `this.recalculateOrder(order, ctx)` self-call then **runs inside
that already-open tx** — Hibernate's `findByIdForUpdate` is happy. The proxy
bypass is invisible because the surrounding tx exists for an unrelated
reason.

The sweep path has no such accidental cover: `recalculateOpenOrders` is
intentionally non-transactional (260331 decision), and there is no outer
caller providing a tx either (`ReplenishOrderJob` has no `@Transactional`).

### Why `setLastRun` does NOT exhibit the same bug

`setLastRun(Instant.now())` at line 75 calls
`syspropService.setSysvalue(KEY, value)`. `SyspropService.setSysvalue`
carries its **own** `@Transactional("tenantTransactionManager", REQUIRED)`
(SBDEV-2234 Fix C, added in the same plan). Because the call crosses bean
boundaries (`ReplenishmentOrderMaintenanceService` → `SyspropService`),
Spring's proxy on `SyspropService` **fires** and opens a short
tenant transaction for the sysprop write. The cadence timestamp commits
cleanly **before** the sweep loop begins. The bug only surfaces inside the
loop, on a within-same-bean call.

---

## §3 Regression Chain

This bug was introduced by **SBDEV-2234 Fix B** (commit `f478b2d`, plan
`SBDEV-2234-replenishment-maintenance-tx-and-lock.md`, status `implemented`
as of 2026-05-15).

| Step | Event | File | Effect |
|---|---|---|---|
| Pre-SBDEV-2234 | `recalculateOrder` re-fetched with **plain `findById`** | `ReplenishmentOrderMaintenanceService.java:124` (then) | Worked without an active tx — `findById` does not require one. Race window between fetch and write left silent drift (SBDEV-2234 Bug A3). |
| SBDEV-2234 Fix B | Replaced `findById` → `findByIdForUpdate` (`@Lock(PESSIMISTIC_WRITE)`) | same line, now `:125` | **Required an active tx**. Worked on the `recalculateForItem` path because that method got `@Transactional` in Fix A. **Silently broke** the `recalculateOpenOrders` path, which 260331 deliberately kept non-transactional. |
| SBDEV-2234 §0.1 / §5 Fix B "lock-hold semantics by caller path" | The plan **documented** that the sweep path's FOR UPDATE row lock would be "acquired … and released immediately on the next auto-commit — likely before `updateRequestedAmount` runs" and called the path "partial — still safer than a plain findById" | `SBDEV-2234-…-tx-and-lock.md` (§5 Fix B caller-context table) | The plan was **wrong**: it assumed Hibernate would honor the lock under JDBC-level autocommit. In reality, Spring rejects the `@Lock` query when no Spring-managed tx is active. The bug was masked in tests because TestContainers + JPA setup happens to fail differently on H2 (no FOR UPDATE semantics) and the integration test suite did not exercise the sweep path under a real Postgres without an outer tx. |
| Production tick, 2026-05-20 | First tenant where the "nothing changed" branch of `ReplenishOrderJob` fired post-deploy | tenant `hydra-nywh` | Sweep raised one `InvalidDataAccessApiUsageException` per order in PROCESSABLE state; all were swallowed by the per-order `try/catch`. |

**Regression vector.** SBDEV-2234's caller-context analysis correctly
identified that the sweep path has different lock semantics, but
misjudged the consequence: it assumed a degraded-but-functional lock, when
in fact Spring fails the query outright. The plan's verify script only
asserted code-shape ("`findByIdForUpdate` is the construct used at line
125") — not behavior under no-outer-tx invocation. A targeted integration
test calling `recalculateOpenOrders(false)` against TestContainers Postgres
would have caught this before merge.

**Lesson candidate (post-rollout):** any `@Lock(...)` repository method
introduced into an existing call path must have an integration test that
exercises **every public caller of the worker that uses it**, not just one.
See §10 follow-ups.

---

## §4 Architecture Overview

### Post-fix code path (ASCII)

```
                       ┌──────────────────────────────────────────────────────────────┐
                       │  ReplenishmentOrderMaintenanceService (singleton bean)       │
                       │                                                              │
   ReplenishOrderJob ─►│  recalculateOpenOrders(boolean force)        ← NO @Tx        │
   (advisory lock,    │   ─ shouldSkipForCadence()  (syspropService.getSysvalue)      │
    no JPA tx)         │   ─ setLastRun(now)         (syspropService.setSysvalue ────▶│──► los_sysprop
                       │                              has its own @Tx — short tx)     │
                       │   ─ openOrders = findByState(PROCESSABLE)                    │
                       │   ─ for order in openOrders:                                 │
                       │        try {                                                 │
                       │            self.recalculateOrder(order, ctx) ────┐           │
                       │        } catch (Exception e) { LOG.warn(…); }    │           │
                       │                                                  │           │
                       │  ┌───────────────────────────────────────────────▼──────┐    │
                       │  │ proxy(ReplenishmentOrderMaintenanceService).recalculateOrder ◄── @Lazy @Autowired self
                       │  │   ↓ AOP proxy opens fresh tenant tx (REQUIRED)        │    │
                       │  │ recalculateOrder(Replenishorder, RecalcContext)       │    │
                       │  │   @Transactional(tenantTransactionManager, REQUIRED)  │    │
                       │  │   ─ findByIdForUpdate(id) ──── SELECT … FOR UPDATE ───┼───►│──► replenishorder
                       │  │   ─ updateRequestedAmount      ── UPDATE ─────────────┼───►│──► replenishorder
                       │  │   ─ stockunit save             ── UPDATE ─────────────┼───►│──► stockunit
                       │  │   ↑ proxy commits per-order tx on return              │    │
                       │  └──────────────────────────────────────────────────────┘    │
                       └──────────────────────────────────────────────────────────────┘

   HTTP / mobile path  ─►   recalculateForItem(itemId)   ← already @Transactional (SBDEV-2234)
                                  └─ recalculateOrder(order, ctx)   ← via this. (proxy bypass)
                                          ↑ REQUIRED would join recalculateForItem's outer tx anyway
                                          ↑ so behavior unchanged
```

The fix preserves SBDEV-2234's "per-order short tx" intent literally: each
sweep iteration commits independently, so a failure on order N does not
roll back successful saves for orders 1..N-1 (the existing per-order
`try/catch` still wraps the proxy call).

### Key files

| File | Role |
|---|---|
| `service/ReplenishmentOrderMaintenanceService.java` | **Primary fix target.** Annotate `recalculateOrder(Replenishorder, RecalcContext)`, add `@Lazy @Autowired self`, change line 85 to `self.recalculateOrder(order, ctx)` |
| `repo/jpa/ReplenishorderRepository.java` | No change. `findByIdForUpdate(Long)` at `:27-29` already exists |
| `service/SyspropService.java` | No change. `setSysvalue` already `@Transactional` per SBDEV-2234 Fix C |
| `schedulejob/ReplenishOrderJob.java` | No change. Caller is correct; bug was downstream |
| `service/mobile/MobileReplenishService.java` | No change here. SBDEV-2234 §10 Open Question #4 covers the separate long-mobile-tx concern at line 806 |
| `test/.../unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | **Test target.** Add AC-NEW-1 (reflection: `recalculateOrder` is `@Transactional`), AC-NEW-2 (sweep reaches `findByIdForUpdate` via self-proxy), and AC-NEW-3 (sibling-isolation under per-order exception in `recalculateForItem`) to the `ConcurrencyHardening` nested class. Preserve all existing tests. |
| `sbdocs/9-System/scripts/verify-260520-content-derived-idempotency-key.sh` | Sibling — not relevant; this plan ships its own `verify-260520-replenishment-open-orders-missing-tx.sh` |

---

## §5 Fix Design — Fix A: self-injection pattern

### Step 1 — Annotate `recalculateOrder(Replenishorder, RecalcContext)`

**Before** (`ReplenishmentOrderMaintenanceService.java:120`):

```java
void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null) {
        return;
    }
    // Re-fetch with pessimistic write lock to serialize concurrent writers on the same row
    order = replenishorderRepository.findByIdForUpdate(order.getId()).orElse(null);
    ...
}
```

**After:**

```java
/**
 * Recalculate a single replenishment order.
 *
 * <p>This method MUST run inside an active tenant transaction so the
 * {@code @Lock(PESSIMISTIC_WRITE)} on {@link ReplenishorderRepository#findByIdForUpdate}
 * has a scope to hold. The annotation below opens one when the call enters
 * through the Spring proxy (sweep path via {@code self}); the
 * {@code recalculateForItem(Long)} caller already opens an outer tx and
 * {@code REQUIRED} joins it.
 *
 * <p>Called via {@code self.recalculateOrder(...)} from
 * {@link #recalculateOpenOrders(boolean)} (line 85) so Spring's AOP proxy
 * fires; called via {@code this.recalculateOrder(...)} from
 * {@link #recalculateForItem(Long)} (line 108) which is acceptable because
 * {@code recalculateForItem} provides the outer tx.
 */
@Transactional(value = "tenantTransactionManager",
               propagation = Propagation.REQUIRED,
               rollbackFor = {BusinessException.class, FacadeException.class})
public void recalculateOrder(Replenishorder order, RecalcContext ctx) {
    if (order == null) {
        return;
    }
    order = replenishorderRepository.findByIdForUpdate(order.getId()).orElse(null);
    if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
        return;
    }
    ...
}
```

Three changes vs. the current source:
- visibility `void` → `public void` (proxy can only intercept public methods on the proxied interface/class)
- add `@Transactional(value = "tenantTransactionManager", propagation = REQUIRED, rollbackFor = {BusinessException.class, FacadeException.class})`
- add a `Propagation` import: `import org.springframework.transaction.annotation.Propagation;`

The single-arg overload `recalculateOrder(Replenishorder)` at line 116 stays
package-private and untouched (Open Question #2).

### Step 2 — Add `@Lazy @Autowired` self-reference

**New field** alongside the existing constructor-injected dependencies
(insert near line 47, after `syspropService`):

```java
// Self-reference for AOP-aware self-invocation of @Transactional methods.
// Lazy avoids the constructor-time circular-injection cycle that would
// otherwise form because this bean is referencing itself.
@Lazy
@Autowired
private ReplenishmentOrderMaintenanceService self;
```

Required imports:

```java
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Lazy;
```

**Pattern provenance (corrected 2026-05-20 after critic review):**
This field-level `@Lazy @Autowired` **self-reference** pattern is **new to
v2/wms2-api**; the existing `@Lazy` usages in `StockunitBusinessService`,
`UnitloadBusinessService`, and `MessageService` use `@Lazy` for adjacent
purposes (lazy init / non-self cycle breaking), not self-injection. Their
specifics:

- `service/StockunitBusinessService.java:85` — `@Lazy` on a `@PostConstruct`
  method (defers init timing), not a self-injected field
- `service/UnitloadBusinessService.java:30` — `@Lazy` on the class
  declaration (defers bean instantiation), not self-injection
- `service/MessageService.java:46` — `@Lazy @Autowired` on
  `StockChangeNotificationService` (a **different** service, breaking a
  cross-bean cycle), not self-injection

The pattern is **standard Spring Framework guidance** for AOP self-call
(Spring reference §6.6.1 "Understanding AOP proxies"). Adopting it here
establishes the v2 precedent for future contributors. Open Question #1's
rationale is updated accordingly — the choice over `AopContext.currentProxy()`
/ `ApplicationContext.getBean(...)` rests on Spring-framework idiom, not on
internal precedent.

### Step 3 — Re-route the sweep-loop call

**Before** (`ReplenishmentOrderMaintenanceService.java:85`):

```java
try {
    recalculateOrder(order, ctx);
} catch (Exception e) {
    LOG.warn("Failed to recalculate replenishOrder={} : {}", order.getNumber(), e.getMessage());
    LOG.debug("Recalculation failure", e);
}
```

**After:**

```java
try {
    // Call through self-proxy so Spring AOP fires and opens the
    // per-order tenant tx declared on recalculateOrder. A plain
    // this.recalculateOrder(...) here bypasses the proxy and the
    // findByIdForUpdate query would raise
    // "InvalidDataAccessApiUsageException: Query requires transaction
    // be in progress" — see plan 260520-replenishment-open-orders-missing-tx.md.
    self.recalculateOrder(order, ctx);
} catch (Exception e) {
    LOG.warn("Failed to recalculate replenishOrder={} : {}", order.getNumber(), e.getMessage());
    LOG.debug("Recalculation failure", e);
}
```

### Propagation semantics — three caller paths

| Caller into `recalculateOrder` | Active outer tx? | Effect of `Propagation.REQUIRED` |
|---|---|---|
| Sweep path: `recalculateOpenOrders(boolean)` → **`self`**`.recalculateOrder(...)` (`:85` after Fix A) | **No** (260331: sweep intentionally non-transactional) | **AOP fires.** Proxy opens a fresh per-order tenant tx. `findByIdForUpdate` runs inside that tx; commits when `recalculateOrder` returns. Preserves "per-order short tx" intent literally. |
| HTTP path: `recalculateForItem(Long)` → **`this`**`.recalculateOrder(...)` (`:108` — **must NOT change to `self.`**) | **Yes** — `recalculateForItem` has `@Transactional("tenantTransactionManager")` from SBDEV-2234 | AOP **deliberately bypassed**. The inner `@Transactional`'s `rollbackFor` does NOT fire; the outer try/catch can swallow per-order `BusinessException` / `FacadeException` without poisoning the shared `recalculateForItem` tx. **See §5.4 for the `UnexpectedRollbackException` trap that routing through `self.` would activate.** |
| Single-arg test path: `recalculateOrder(Replenishorder)` → `this.recalculateOrder(order, new RecalcContext(...))` (`:117`) | Depends on test wiring | Bypassed (this-call); behavior unchanged. The single-arg variant is test-only. |

### Why per-order try/catch survives the new `@Transactional`

`recalculateOpenOrders` wraps each `self.recalculateOrder(order, ctx)` call
in a try/catch (line 84–89). Three failure modes:

1. **`findByIdForUpdate` raises `InvalidDataAccessApiUsageException`** — won't happen any more; that's the bug being fixed.
2. **Per-order business failure** (`BusinessException`, `FacadeException`,
   optimistic lock, lock timeout) — Spring's proxy marks the per-order tx
   rollback-only and rethrows. The outer try/catch swallows the exception
   and logs `WARN`. The **next iteration's `self.recalculateOrder(...)`
   call opens a fresh tx**; sibling orders are unaffected. This is the
   correct semantic match for the new **AC-NEW-3** sibling-isolation test
   (`recalculateForItem_oneFailingOrderDoesNotRollbackSiblings`, added by this plan).
3. **Runtime non-business exception** — same as case 2: per-order tx rolls
   back, outer try/catch swallows, loop continues.

The architectural contract of "per-order auto-commit" is now realized as
"per-order Spring-managed transaction that commits before the next iteration
starts." Behaviorally equivalent for success; strictly safer for failure
(rollback semantics on the order's writes).

### §5.4 Why `recalculateForItem`'s line-108 call site must remain `this.` (not `self.`)

This subsection exists because the most plausible future regression of this
plan is a contributor "tidying up" the inconsistency between line 85
(`self.recalculateOrder`) and line 108 (`this.recalculateOrder`) by making
them symmetrical. **Doing so re-creates an SBDEV-2234-class "sibling
isolation" bug under a new name.** The keep-it-`this.` decision is
**semantic**, not stylistic.

**Setup.** After Fix A, `recalculateForItem(Long)` (already
`@Transactional("tenantTransactionManager")` from SBDEV-2234) iterates over
N orders for one `itemDataId` and calls the inner worker per order. The
inner worker `recalculateOrder(Replenishorder, RecalcContext)` is now also
`@Transactional("tenantTransactionManager", REQUIRED, rollbackFor = {BusinessException.class, FacadeException.class})`
(Fix A Step 1).

**Current behavior (this.-call at `:108`, the correct state).**
1. `recalculateForItem`'s proxy opens an outer tenant tx T1.
2. The loop calls `this.recalculateOrder(order, ctx)` — bypasses the inner
   proxy (Java implicit-self).
3. **The inner `@Transactional` is inert on this path.** The inner
   `rollbackFor` clause is never consulted.
4. Per-order `BusinessException` / `FacadeException` propagates out of the
   inner method into the outer try/catch (`recalculateForItem.java:109-112`),
   which logs `WARN` and continues.
5. T1 is **not** marked rollback-only by Spring (no proxy fired on the
   failing inner call). Subsequent orders save successfully into T1. T1
   commits cleanly on `recalculateForItem` return.

**Broken behavior IF someone routes line 108 through `self.`.**
1. `recalculateForItem`'s proxy opens outer tenant tx T1.
2. The loop calls `self.recalculateOrder(order, ctx)` — **the inner proxy
   fires**.
3. The inner proxy sees an active tx (T1) + `Propagation.REQUIRED` →
   **joins T1** (does not open a new one).
4. The inner method throws `BusinessException` on order K.
5. The inner proxy's `rollbackFor = {BusinessException.class, ...}` clause
   matches → **proxy marks T1 as `rollback-only`** on exception unwind.
6. The outer try/catch in `recalculateForItem.java:109-112` swallows the
   exception. Loop continues to order K+1.
7. Orders K+1..N execute, each calling `self.recalculateOrder(...)` which
   joins T1, each performing `replenishorderRepository.save(...)` and
   `stockunitRepository.save(...)`. None of these throw at flush time
   because Hibernate defers the failure.
8. `recalculateForItem` returns. Outer proxy attempts to commit T1. **T1
   was marked rollback-only at step 5.** Spring raises
   `UnexpectedRollbackException` from the commit attempt → **all of orders
   1..N roll back, including the ones that succeeded.**

This is exactly the SBDEV-2234 "sibling isolation" regression class
(one failing order rolls back its siblings) — but caused by `REQUIRED`
re-entry into a shared tx with mismatched `rollbackFor`, not by missing
try/catch. The **new AC-NEW-3 test** (`recalculateForItem_oneFailingOrderDoesNotRollbackSiblings`,
added by this plan — see §8) validates per-order exception isolation;
however, AC-NEW-3 runs under Mockito without a real Spring tx so it cannot
directly surface `UnexpectedRollbackException`. The verify script adds
**A3b (negative)** below as the primary structural guard against this
regression being introduced in the first place.

**The general principle.** Once an inner method's `@Transactional` declares
a `rollbackFor` clause, calling that method through the proxy from inside a
caller that uses `REQUIRED`-joined tx semantics turns sibling isolation
from a property of the caller's try/catch into a property of the inner
method's `rollbackFor` list. The only safe ways to preserve sibling
isolation are:
- (chosen) **Bypass the proxy via `this.`** so the inner `rollbackFor` is
  inert when the caller already has its own tx, OR
- Use `Propagation.REQUIRES_NEW` on the inner method so each call gets its
  own tx that can be rolled back independently of T1. **Rejected** here
  because it doubles the connection-pool footprint per outer call (one
  connection held for T1 throughout, plus one held for each inner tx).

**Enforcement.**
1. The verify script's **A3b (NEGATIVE)** check asserts no
   `self.recalculateOrder(order, ctx)` appears in the
   `recalculateForItem(Long)` method region (lines ~93-114). See §11.1.
2. An inline `// WARNING: ...` comment is added directly above the
   `this.recalculateOrder(order, ctx)` call at line 108 (see §7.2 step
   A4-b) pointing at this section.
3. The **new AC-NEW-3 test** (`recalculateForItem_oneFailingOrderDoesNotRollbackSiblings`,
   added by this plan) is a behavioral companion — it validates that per-order
   exception isolation holds in the outer try/catch. NOTE: because AC-NEW-3
   runs under Mockito with no real Spring tx, it cannot directly observe
   `UnexpectedRollbackException`; the A3b grep is the primary guard against
   the §5.4 trap. AC-NEW-3 catches the weaker regression of "catch-and-continue
   silently removed" (without AOP interaction).

### Why the verify script will catch the regression vector

The verify script at `sbdocs/9-System/scripts/verify-260520-replenishment-open-orders-missing-tx.sh`
includes (see §11.1):

- **A1 positive**: `recalculateOrder(Replenishorder order, RecalcContext ctx)`
  is preceded by `@Transactional(value = "tenantTransactionManager"`
- **A2 positive**: the field `private ReplenishmentOrderMaintenanceService self;`
  is preceded by `@Lazy` and `@Autowired`
- **A3 positive** (sweep-loop region, lines ~71-91): the file region
  contains `self\.recalculateOrder\(order,\s*ctx\)`
- **A3-neg (bare-call)** (sweep-loop region): the file region does NOT
  contain a bare unqualified `recalculateOrder(order, ctx)` call at
  line-start whitespace (regex: line begins with whitespace, then the
  literal `recalculateOrder(` with no preceding `self.` / `this.` /
  `.`). PCRE form: `^\s+recalculateOrder\(order,\s*ctx\)`. **This regex
  is intentionally line-anchored** to avoid matching `self.recalculateOrder(...)`
  via word-boundary loophole (the prior draft's `\b…` regex was broken —
  see Critic Major #3).
- **A3b (NEGATIVE — `recalculateForItem` region, lines ~93-114)**: the
  region does NOT contain `self\.recalculateOrder\(order,\s*ctx\)`.
  Guards against the `UnexpectedRollbackException` trap from §5.4.
- **A4 positive**: `recalculateOpenOrders(boolean)` is NOT annotated with
  `@Transactional` (preserve 260331 decision)
- **A5 behavioral**: `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest`
  passes — the existing AC-1 negative (`recalculateOpenOrders_boolean_shouldNotBeTransactional`),
  the existing `recalculateForItem_oneFailingOrderDoesNotRollbackSiblings`
  (which would surface an `UnexpectedRollbackException` if §5.4's trap is
  triggered), and the new AC-NEW-1 / AC-NEW-2 all green

The regression that bit SBDEV-2234 (a code-shape check passing while a
behavioral test was missing) is closed by A5. **A5 is a necessary
condition for "DONE" but not sufficient for proxy-routing correctness**
— see the AC-NEW-2 test-scope boundary box in §8.

---

## §6 File Change Summary

| File | Change Type | Description |
|---|---|---|
| `service/ReplenishmentOrderMaintenanceService.java` | Modify | (a) Line 120: `recalculateOrder(Replenishorder, RecalcContext)` → `public`, add `@Transactional(value="tenantTransactionManager", propagation=REQUIRED, rollbackFor={BusinessException.class, FacadeException.class})`. (b) After line 47: add `@Lazy @Autowired private ReplenishmentOrderMaintenanceService self;`. (c) Line 85: change `recalculateOrder(order, ctx)` → `self.recalculateOrder(order, ctx)`. (d) Add imports: `org.springframework.beans.factory.annotation.Autowired`, `org.springframework.context.annotation.Lazy`, `org.springframework.transaction.annotation.Propagation`. |
| `test/.../unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | Modify | Add AC-NEW-1 (`recalculateOrder_twoArg_mustBeTransactional_tenantTM`), AC-NEW-2 (`recalculateOpenOrders_invokesRecalculateOrderViaProxy_reachingFindByIdForUpdate`), and AC-NEW-3 (`recalculateForItem_oneFailingOrderDoesNotRollbackSiblings`) to the `ConcurrencyHardening` nested class. Keep all existing tests including the AC-1 negative at lines 1192-1203. |
| `sbdocs/9-System/scripts/verify-260520-replenishment-open-orders-missing-tx.sh` | New | Machine-checkable acceptance per §11.1 |

No production data migration. No schema change. No new sysprop or
constant. No new repository method (`findByIdForUpdate` already exists).
No caller-side change.

---

## §7 Implementation Steps

### §7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. No migration. | N/A | Pure code change |
| 2 | **Feature flags / system properties** | None added. `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` already exists from SBDEV-2234 Fix C and is unrelated to this fix | N/A | |
| 3 | **Config / env changes** | None | N/A | |
| 4 | **Deploy-order dependencies** | SBDEV-2234 must already be deployed (it is — commit `f478b2d`, PR #22, status `implemented`) | Implementer (verify) | Confirms `findByIdForUpdate` is the current re-fetch construct before annotating its caller |
| 5 | **Data migration** | None | N/A | |
| 6 | **External systems** | None | N/A | |
| 7 | **Access / permissions** | None | N/A | |
| 8 | **Monitoring / alerts** | Before deploy, baseline `wms2.cron.replenish_order.*` counters and grep log volume for `Failed to recalculate replenishOrder=… : Query requires transaction be in progress`. After deploy: that line should disappear from logs entirely; `wms2.transaction.lock.timeout` rate may show a small uptick as previously-silent FOR UPDATE waits now actually serialize (still strict improvement vs silent no-op). | Implementer | Existing Micrometer counters |

### §7.2 Implementation Checklist (one atomic commit)

> **Atomicity.** Step 1 alone (annotate without `self`) regresses on test
> AC-1 neg (`recalculateOpenOrders_boolean_shouldNotBeTransactional` —
> the annotation isn't on `recalculateOpenOrders`, so this still passes,
> but the sweep path would still bypass the proxy via `this.`). Step 3
> alone (route through `self` without annotating) leaves the worker
> non-transactional. Ship all three in one commit.

> **Line-number caveat for the executor.** Step A3 below adds ~10+ lines
> (Javadoc + `@Transactional` block) above the current `recalculateOrder`
> declaration. **After A3 lands, the line numbers cited in A4-a and A4-b
> will shift.** Locate the two call sites **by name**, not by line number:
> for A4-a, search for the literal call inside `public void recalculateOpenOrders(boolean force)`;
> for A4-b, search for the literal call inside `public void recalculateForItem(Long itemDataId)`.
> Each method body contains exactly one `recalculateOrder(order, ctx)` invocation.

- [ ] **A1** — Add imports to `ReplenishmentOrderMaintenanceService.java`:
  `org.springframework.beans.factory.annotation.Autowired`,
  `org.springframework.context.annotation.Lazy`,
  `org.springframework.transaction.annotation.Propagation`.
- [ ] **A2** — Add the `@Lazy @Autowired private ReplenishmentOrderMaintenanceService self;`
  field after the `syspropService` field (around line 47).
- [ ] **A3** — Change `recalculateOrder(Replenishorder, RecalcContext)`
  (currently line 120 — note pre-A3 anchor; after A3 the declaration moves)
  from `void` → `public void`, prepend
  `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRED, rollbackFor = {BusinessException.class, FacadeException.class})`,
  and add the Javadoc comment from §5 Step 1.
- [ ] **A4-a (sweep loop — change to `self.`)** — Inside
  `recalculateOpenOrders(boolean force)`, locate the call
  `recalculateOrder(order, ctx);` by name and change it to
  `self.recalculateOrder(order, ctx);`. Add the inline comment block from
  §5 Step 3 above the call.
- [ ] **A4-b (recalculateForItem loop — KEEP `this.`, add WARNING comment)** —
  Inside `recalculateForItem(Long itemDataId)`, locate the call
  `recalculateOrder(order, ctx);` by name. **Do NOT change it to
  `self.recalculateOrder(...)`.** Immediately above the call, insert this
  comment block verbatim:

  ```java
  // WARNING: Do NOT change to self.recalculateOrder(order, ctx) —
  // see §5.4 of plan 260520-replenishment-open-orders-missing-tx.md.
  // Routing this call through the self-proxy activates the inner
  // method's rollbackFor on a BusinessException / FacadeException
  // thrown by any one order, which marks this method's outer
  // REQUIRED-joined tx as rollback-only and produces
  // UnexpectedRollbackException at commit time — destroying sibling-order
  // saves (the SBDEV-2234 "sibling isolation" regression class).
  // The this.-call is intentional: it bypasses the inner proxy so the
  // inner @Transactional is inert here; the outer try/catch alone
  // governs per-order failure handling.
  ```
- [ ] **A5** — Write AC-NEW-1, AC-NEW-2, and AC-NEW-3 in the test file (see §8).
- [ ] **A6** — Author `sbdocs/9-System/scripts/verify-260520-replenishment-open-orders-missing-tx.sh`
  per §11.1; make it executable.
- [ ] **A7** — Run `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest`;
  expect all existing + 3 new tests green.
- [ ] **A8** — Run `bash sbdocs/9-System/scripts/verify-260520-replenishment-open-orders-missing-tx.sh`;
  expect 0 fail.
- [ ] **A9** — Run `mvn test` (full suite) for regression coverage; record
  pass/fail count.
- [ ] **A10** — `code-reviewer` pass on the diff (small surface; one
  reviewer round expected).
- [ ] **A11** — Commit + PR (suggest title: `fix(wms2): replenishment open-orders sweep — annotate recalculateOrder + self-proxy invocation`).
- [ ] **A12** — Post-rollout: flip plan `status: implemented`; record commit
  SHA, mvn results, PR URL per the plan-status-after-implementation convention;
  watch production logs for tenant `hydra-nywh` for the next two cron
  ticks to confirm the warning line disappears.

### §7.3 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Add per-replica state? | **No** | The new field `self` is a Spring proxy reference — managed by the container, not transient state |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **Yes (low, bounded)** | Each sweep iteration now opens its own tenant tx → holds one connection for the duration of one order's recalc (typically tens of ms). Net change vs current (broken) behavior: sweep currently holds **zero** connections beyond the immediate `findByIdForUpdate` failure, but the sweep is also doing **zero useful work**. Net change vs pre-SBDEV-2234 behavior: identical (each `save()` was its own auto-commit there too). No connection-pool math regression. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` job? | **No** | `ReplenishOrderJob` is unchanged. The cadence + advisory-lock + per-tenant context are all upstream of this fix |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | **Yes (bounded, per-order)** | Each `recalculateOrder` tx brackets: `findByIdForUpdate` → optional `redirectSource` → optional `updateRequestedAmount` (save) → optional `stockunit` save. All DB-only; no HTTP / message / OMS. Bounded by HikariCP `connectionTimeout`. Identical to the existing `recalculateForItem` path's tx — that path is in production and is well-behaved. |
| 5 | **Request affinity** | Assume same-replica follow-up? | **No** | |
| 6 | **Retry / idempotency** | Break if a replica dies mid-op? | **Yes (improved)** | Currently a replica dying mid-sweep leaves zero damage because zero writes happen (everything raises and is swallowed). Post-fix, a replica dying mid-iteration rolls back its in-flight per-order tx via Postgres connection close; the FOR UPDATE lock is released; the next cron tick on any replica re-acquires and retries. Strict improvement. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **No** | `ReplenishOrderJob` already sets `TenantContext` before invoking `recalculateOpenOrders` per tenant; this fix doesn't introduce any new async path |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **Yes (primary mechanism — restored)** | The FOR UPDATE lock on `replenishorder.id` that SBDEV-2234 Fix B introduced is restored to functional status on the sweep path. The lock now actually serializes concurrent sweeps across replicas — currently it doesn't because the query never executes |
| 9 | **Cache invalidation** | Write to a cached entity? | **No** | `Replenishorder` is not `@Cacheable`. `los_sysprop` is, but `setSysvalue` already evicts properly (SBDEV-2234) |
| 10 | **External notifications** | Send HTTP / message inside a transaction? | **No** | The recalc path is DB-only (no OMS, no webhook, no message). `MessageService.sendStockChangeMessage` is invoked by callers (`StockunitService.adjustAmount`), not by `recalculateOrder` itself. |

#### Evidence (for "Yes" rows)

| Concern # | What was done / verified | File:line or reference |
|---|---|---|
| 2 | Tx scope is **single order's recalc only**; no external I/O inside | `ReplenishmentOrderMaintenanceService.java:120-158` |
| 4 | Same scope as existing `recalculateForItem` path (already in production via SBDEV-2234) | `ReplenishmentOrderMaintenanceService.java:93-114` |
| 6 | Hibernate tx rollback on uncaught throw; Postgres releases row lock on connection close | Standard Spring/Hibernate behavior |
| 8 | `findByIdForUpdate` uses `@Lock(PESSIMISTIC_WRITE)` | `ReplenishorderRepository.java:27-29` |

### §7.4 v2-only Constraint Checklist

| # | Constraint | Status | Notes |
|---|---|---|---|
| 1 | All `@Transactional` annotations specify `value = "tenantTransactionManager"` | ✓ | Fix A uses tenant TM explicitly |
| 2 | `jakarta.*` imports (not `javax.*`) | ✓ | No new imports of `javax.*`; `Propagation` is `org.springframework.transaction.annotation.Propagation` |
| 3 | No `mockStatic()` in tests (Mockito 3.3.3 compatibility) | ✓ | New tests use only instance mocks + `@Spy` + `ReflectionTestUtils` to inject the `self` reference |
| 4 | No JPA association annotations added | ✓ | None added |
| 5 | Entity comparison by ID, not `.equals()` | ✓ | No new entity-equality checks |
| 6 | Cache eviction explicit for any `@Cacheable` write path | ✓ | No `@Cacheable` entity touched |
| 7 | Spring Boot 3.5.9 + Java 21 features only | ✓ | `@Lazy` + `@Autowired` are stable Spring API |
| 8 | If new `@Scheduled` added → ShedLock / single-instance documented | N/A | No new scheduled job |

---

## §8 Testing Plan

### Unit tests — extend `ReplenishmentOrderMaintenanceServiceUnitTest` `ConcurrencyHardening` nested class

| Test method | Acceptance Criterion | What it asserts |
|---|---|---|
| `recalculateOrder_twoArg_mustBeTransactional_tenantTM` | **AC-NEW-1** | Reflection: `ReplenishmentOrderMaintenanceService.class.getMethod("recalculateOrder", Replenishorder.class, RecalcContext.class).getAnnotation(Transactional.class)` is non-null; `tx.value() == "tenantTransactionManager"`; `tx.propagation() == Propagation.REQUIRED`. **Note on `RecalcContext`:** it is currently a private inner class. The test should resolve the parameter type via `Class.forName("net.aim_ai.wms.service.ReplenishmentOrderMaintenanceService$RecalcContext")` or by walking `getDeclaredMethods()` for the two-arg variant. (Open Question #4: should `RecalcContext` become package-visible for cleaner test access? Default: no — keep encapsulation; resolve via `getDeclaredMethods()`.) |
| `recalculateOpenOrders_invokesRecalculateOrderViaProxy_reachingFindByIdForUpdate` | **AC-NEW-2** | Wire a real `ReplenishmentOrderMaintenanceService` instance under test (`@InjectMocks` already does this). Use `ReflectionTestUtils.setField(service, "self", service)` to inject the service as its own `self` (the unit-test environment has no AOP proxy, so the field would otherwise be null and the call would NPE on the sweep path). Stub `replenishorderRepository.findByState(PROCESSABLE)` to return one processable order; stub `replenishorderRepository.findByIdForUpdate(orderId)` to return that order; stub the bulk-load methods to return empty (force `ensureValidSource` to fall through and exit the method early). Stub `syspropService.getSysvalue` cadence keys to allow the sweep to proceed. Call `service.recalculateOpenOrders(false)`. `verify(replenishorderRepository).findByIdForUpdate(orderId)`. Assert no `InvalidDataAccessApiUsageException` thrown (the bug reproducer — would have surfaced pre-fix). |
| `recalculateForItem_oneFailingOrderDoesNotRollbackSiblings` | **AC-NEW-3** (new, added by this plan) | Two processable orders for the same item. Stub `findByIdForUpdate(order1.getId())` to throw `RuntimeException("simulated lock failure")`; stub `findByIdForUpdate(order2.getId())` to return `Optional.of(order2)`. Call `service.recalculateForItem(itemDataId)`. Assert no exception thrown. `verify(replenishorderRepository).findByIdForUpdate(order2.getId())` — sibling order2 was still processed despite order1's failure. **Scope boundary:** this test verifies the outer try/catch properly catches per-order exceptions without aborting the loop. It does NOT detect the §5.4 `UnexpectedRollbackException` trap (that requires a real Spring tx, not Mockito). The A3b grep + inline `// WARNING:` comment are the primary guards against §5.4; AC-NEW-3 validates the per-order exception isolation. |
| `recalculateOpenOrders_boolean_shouldNotBeTransactional` | **AC-KEEP-1-neg** (existing at `:1192-1203`) | Keep as-is. `recalculateOpenOrders(boolean)` must NOT have `@Transactional` — the 260331 per-order auto-commit decision is preserved by Fix A, just now realized via per-order proxy-opened txns instead of JDBC autocommit. |
| `recalculateForItem_shouldCallFindByIdForUpdate_notFindById` | **AC-KEEP-2** (existing at `:1206-1221`) | Keep as-is. Validates the HTTP path's worker still uses `findByIdForUpdate`. |
| `recalculateForItem_shouldHaveTransactional_withTenantTxManager` | **AC-KEEP-3** (existing at `:1178-1190`) | Keep as-is. Validates `recalculateForItem(Long)`'s SBDEV-2234 annotation is still present. |

**Test wiring detail for AC-NEW-2.** The standard `@ExtendWith(MockitoExtension.class)` + `@InjectMocks` test harness does not install a Spring AOP proxy, so the `self` field would be null after construction. The test must:
1. `@InjectMocks` build the service with all mock dependencies, and
2. immediately call `ReflectionTestUtils.setField(service, "self", service)` so the loop's `self.recalculateOrder(...)` resolves to the same instance.

This deliberately collapses `self.recalculateOrder(...)` to a `this`-call in the unit test, **which is exactly what we want** for AC-NEW-2: the test asserts that the call site invokes the worker (verified by `findByIdForUpdate` being reached). The annotation behavior (AOP opens a tx) is **out of scope** for unit tests — it lives in integration coverage. Spring's proxy behavior is the framework's contract, not ours to test.

> **AC-NEW-2 test-scope boundary (critic-required acknowledgment, 2026-05-20).**
> The unit test verifies **call-site routing** (the loop calls
> `self.recalculateOrder(...)`), not **proxy interception**. Because
> `ReflectionTestUtils.setField(service, "self", service)` collapses the
> proxy back to `this.`, AC-NEW-2 would pass equally against the unfixed
> code if `self` were similarly injected — the test cannot detect whether
> a real Spring proxy fires. Additionally, the production failure
> (`InvalidDataAccessApiUsageException: Query requires transaction be in
> progress`) cannot be reproduced via Mockito because the mocked
> `ReplenishorderRepository.findByIdForUpdate` doesn't enforce `@Lock`
> semantics — the mocked method returns whatever was stubbed regardless
> of tx state.
>
> The regression gate for **proxy routing** is the verify script's
> **A3 positive** grep (`self\.recalculateOrder\(order,\s*ctx\)` is
> present in the `recalculateOpenOrders(boolean)` region) plus the
> **A3-neg (bare-call)** grep. The regression gate for **full behavioral
> validation** (proxy fires + tx active inside `recalculateOrder` against
> real Postgres) is the deferred TestContainers integration test
> (Open Question #3). Explicitly: **`mvn test` passing does NOT by itself
> confirm the AOP fix is correct** — the A3 grep and the post-deploy
> production log signal (the
> `InvalidDataAccessApiUsageException: Query requires transaction be in
> progress` warning line disappearing from tenant `hydra-nywh`'s next
> two cron ticks) are the load-bearing completion evidence.

### Integration test — defer to existing TestContainers coverage

`ReplenishmentOrderMaintenanceServiceIntegrationTest` already exercises the
HTTP path under TestContainers Postgres (SBDEV-2234). Adding a sweep-path
integration test is **deferred** to a follow-up because:

- The bug is specific to `findByIdForUpdate` being called without an active
  tx, which only manifests on a real `@Lock(PESSIMISTIC_WRITE)` JPA driver
  against Postgres (H2 does not produce the same `InvalidDataAccessApiUsageException`).
- The unit test AC-NEW-2 + the verify script's code-shape + the production
  log signal (warning line disappears post-deploy) form a sufficient
  acceptance triangle.
- Open Question #3 records the deferral and recommends authoring
  `recalculateOpenOrders_sweepUnderNoOuterTx_completesWithoutInvalidDataAccess`
  as a TestContainers integration test in a small follow-up plan.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| **Cron tick — production reproducer** | dev / staging matching the production tenant shape (≥1 PROCESSABLE replenishorder, no recent stock movement) | 1. Tail application log. 2. Wait for `ReplenishOrderJob` cron tick (or trigger via admin endpoint). 3. Observe whether the "nothing changed" branch fires (line 183). | **Pre-fix:** one `Failed to recalculate replenishOrder=… : Query requires transaction be in progress` warning per PROCESSABLE order per tick. **Post-fix:** zero such warnings; `wms2.cron.replenish_order.success` counter increments cleanly. | |
| **DB-level convergence** | staging tenant DB | Identify a PROCESSABLE replenishorder whose `requestedamount` drifts from its `Stockunit.reservedamount`. Wait one cron tick. | **Pre-fix:** no convergence (the sweep silently does nothing). **Post-fix:** the next sweep tick updates `requestedamount` to match the expected value computed from current stock. | |
| **Per-order failure does not abort sweep** | staging | Make one order intentionally fail recalc (e.g., delete its source `Stockunit`); leave 2+ siblings processable. | Sibling orders still get `save()`-d; failed order logs a WARN; cron tick completes normally. | |
| **HTTP path unchanged** | staging | Trigger a stock movement (mobile pick or admin UI) for an item with an open replenishorder. | `recalculateForItem` runs as before; `requestedamount` updates within 2s; no 500 errors. | |
| **Concurrency under high load** | staging, 2+ replicas | Two operators on different replicas trigger sweeps simultaneously (cron tick alignment + advisory-lock contention). | One replica wins advisory lock; the other no-ops the entire job. No `InvalidDataAccessApiUsageException`. | |
| **Verify-script gate** | local dev | `bash sbdocs/9-System/scripts/verify-260520-replenishment-open-orders-missing-tx.sh` | All checks PASS; exit 0 | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest` | | |
| `mvn test` (full suite) | | |
| `bash sbdocs/9-System/scripts/verify-260520-replenishment-open-orders-missing-tx.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| H2-based variant of AC-NEW-2 | H2 does not produce `InvalidDataAccessApiUsageException` on `@Lock` without active tx — would pass even pre-fix. The unit-test reflection-based assertion + the production log signal cover the gap |
| TestContainers integration test for the sweep path | Deferred to follow-up (Open Question #3). The unit-level proxy-bypass assertion + verify-script code-shape + production log signal form sufficient acceptance for the urgent fix |
| Load test of sweep throughput pre/post fix | Per-order tx is the same shape as the pre-existing `recalculateForItem` tx; throughput characteristics are well-understood from SBDEV-2234 production data |
| Single-arg `recalculateOrder(Replenishorder)` symmetry refactor | Out-of-scope per Open Question #2; test-only path |

---

## §9 Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **`@Lazy @Autowired self` causes circular-injection startup failure** | Very Low | High | `@Lazy` in v2/wms2-api is used for adjacent purposes (lazy init, cross-bean cycle-breaking) — those usages are NOT self-injection precedents (see §10 Resolved Decision #1). This plan **establishes** the self-injection sub-pattern as a first v2 precedent per Spring reference §6.6.1. `@Lazy` defers resolution until first access (post-context-refresh); no constructor-time cycle. Test by booting `mvn spring-boot:run` in dev before commit. |
| **Field injection (`@Autowired self`) violates constructor-only convention** | Low | Low | AOP self-call via `self` cannot use constructor injection (Spring cannot construct a bean that takes itself as a constructor arg — chicken-and-egg). `@Lazy @Autowired` field injection is the Spring-recommended exception per §6.6.1 of the Spring Framework reference. Document the exception in a Javadoc comment on the field (`// AOP self-proxy — see Spring §6.6.1; do not convert to constructor injection`). |
| **`Propagation.REQUIRED` JOINS an unexpected outer tx and changes per-order rollback semantics** | Low | Medium | The only outer caller that opens an outer tx is `recalculateForItem` (SBDEV-2234). On that path, the per-order tx joins the per-item tx — semantically identical to pre-Fix-A behavior on that path (`this.recalculateOrder` runs inside `recalculateForItem`'s tx). The sweep path has no outer tx, so REQUIRED opens a fresh one per iteration. Regression-tested by AC-KEEP-2 (HTTP path) + AC-NEW-2 (sweep path). |
| **Per-order proxy hop adds latency in the sweep loop** | Low | Low | Each AOP proxy invocation is microseconds; per-order tx open+commit is bounded by Postgres round-trip (sub-ms on a healthy cluster). For a 600-row sweep, ~600 extra tx-open + commit round-trips. Estimated sweep duration increase: <1s on the 600-row tenant. Acceptable given the alternative is no-op. |
| **Sweep latency growth under FOR UPDATE contention** | Medium | Medium | Once Fix A makes the lock effective, two replicas executing the sweep simultaneously serialize at the row level. `AdvisoryLockService.JobLockId.REPLENISH_ORDER` already prevents simultaneous sweep across replicas (one replica wins, the other no-ops the job), so contention is bounded to in-tenant intra-replica cases (none in current deployment). Monitor `wms2.transaction.lock.timeout` post-deploy; alert at 1% rate. |
| **Test AC-NEW-2 false-positive: setField(self, service) collapses proxy to this** | Low | Low | Documented in §8. The unit test is asserting reachability of `findByIdForUpdate`, not proxy behavior. AOP correctness is a Spring contract, not under test. The verify script's code-shape A3 positive check ("loop calls `self.recalculateOrder`") complements the unit test. |
| **Forgetting Step 3 (route through `self`)** — annotation present, sweep loop still uses `this.` → still broken | Medium during implementation | High | Verify script A3 positive grep + A3 negative grep gates the commit. Also surfaces in AC-NEW-2 because the test would still throw `InvalidDataAccessApiUsageException` if `self` is not used (the test uses `setField(self, service)` which collapses the call back to `this.`, BUT in the runtime where the bug occurred we have no such test setup; the test is checking the worker is reached, not the proxy path). The verify-script's A3 grep is the actual safety net. |
| **Concurrent rollout while SBDEV-2234 not yet deployed everywhere** | Very Low | Medium | SBDEV-2234 is already merged (commit `f478b2d`, PR #22, status `implemented`). All environments running v2/wms2-api `main` already have `findByIdForUpdate` at line 125. Confirm pre-deploy with: `git log --oneline | grep f478b2d`. |
| **A future contributor un-routes `self.recalculateOrder` back to `this.recalculateOrder`** during cleanup or formatting refactor | Medium long-term | High (regression of this very bug) | Add a code comment at line 85 stating "DO NOT inline to this.recalculateOrder — Spring AOP proxy required for per-order @Transactional to fire." Verify script will catch in CI. Lesson for `project_memory_add_directive`: "Any `self.method(...)` call inside a `@Service` bean must have a `// AOP self-proxy intentional` comment." (See §10 follow-ups.) |
| **`MobileReplenishService:806` calls `recalculateOpenOrders(true)` inside an outer tx; after Fix A, each per-order proxy hop joins that outer tx (REQUIRED), holding the mobile request's connection longer** | Low | Low (pre-existing concern) | Already noted as SBDEV-2234 §10 Open Question #4. Behavior change is mechanical but **not a new bug**: the sweep was previously joining the mobile tx implicitly (no inner annotation), now joins explicitly (annotation present + REQUIRED). Same hold semantics. The proper fix (move the sweep outside the mobile tx) is the deferred follow-up. |

---

## §10 Open Questions / Resolved Decisions

### Resolved decisions

1. **Self-injection pattern (resolved 2026-05-20, precedent claim corrected 2026-05-20 post-critic)** — Use `@Lazy @Autowired private ReplenishmentOrderMaintenanceService self;` as a field. The choice rests on **Spring Framework idiom**, not on internal v2 precedent: the v2 codebase has **zero** prior examples of `@Lazy @Autowired` self-injection (verified 2026-05-20). The cited `@Lazy` usages in `StockunitBusinessService.java:85` (`@PostConstruct` method), `UnitloadBusinessService.java:30` (class-level lazy init), and `MessageService.java:46` (lazy injection of a **different** bean, `StockChangeNotificationService`) serve adjacent purposes — none are self-injection. This plan establishes the v2 precedent for the AOP-self-call pattern. Rejected alternatives:
   - **`ApplicationContext.getBean(...)` lookup at each call site** — works but ugly, harder to mock in unit tests, also no precedent.
   - **Constructor injection of self** — Spring cannot resolve (chicken-and-egg).
   - **`AopContext.currentProxy()` cast** — requires `@EnableAspectJAutoProxy(exposeProxy = true)` globally; we don't currently enable that and adding it has unrelated blast radius.

   The chosen pattern matches Spring reference §6.6.1 "Understanding AOP proxies" guidance for self-invocation. (Closes prompt-supplied Open Question #1.)

2. **Single-arg `recalculateOrder(Replenishorder)` (resolved 2026-05-20)** — Leave package-private and un-annotated. The single-arg overload is **test-only** (no production caller; verified via grep — only used in `ReplenishmentOrderMaintenanceServiceUnitTest`). Making it public-and-annotated for symmetry has zero production benefit and would expose a test-only API. (Closes prompt-supplied Open Question #2.)

3. **`MobileReplenishService:806` follow-up (resolved 2026-05-20)** — Already filed as SBDEV-2234 §10 Open Question #4 ("Should the long-mobile-tx sweep be addressed in a follow-up ticket?"). This plan does not duplicate or re-file. Recommend ticketing as `MobileReplenishService.confirmAndClose — sweep should run outside the mobile request transaction` after this plan lands. (Closes prompt-supplied Open Question #3.)

4. **`recalculateForItem` loop call at `:108` stays `this.` — for semantic correctness, not style (resolved 2026-05-20, post-critic review)** — Do NOT change `recalculateForItem`'s inner loop to `self.recalculateOrder(...)`. This is a **semantic** decision, not a "needless proxy hop" stylistic one. Routing line 108 through `self.` would activate the inner method's proxy and its `rollbackFor = {BusinessException.class, FacadeException.class}` clause on **the shared `REQUIRED`-joined outer tx**. A per-order `BusinessException` would mark `recalculateForItem`'s outer tx rollback-only; the outer try/catch would still swallow the exception and continue iterating; subsequent orders' `save(...)` calls would execute against the poisoned tx; and Spring would raise `UnexpectedRollbackException` from the outer commit — **rolling back every sibling order that "succeeded" along with the one that failed**. This is the SBDEV-2234 "sibling isolation" regression class under a new name. Full mechanism in §5.4. The `this.`-call at `:108` is correct because it deliberately bypasses the inner proxy so `rollbackFor` is inert on this path — outer try/catch alone governs per-order failure handling. Verify-script check **A3b** is the structural guard. Inline `// WARNING:` comment at the call site (§7.2 step A4-b) is the human guard.

5. **Per-order semantics: auto-commit → REQUIRED tx is a strict upgrade, NOT a semantic identity (resolved 2026-05-20, post-critic clarification)** — The 260331 architectural decision to keep the sweep on per-order short-tx semantics is preserved **in spirit** (each order commits independently of its siblings) but **not literally**:
   - **Pre-SBDEV-2234**: JDBC-level autocommit — each `replenishorderRepository.save(...)` and downstream `stockunitRepository.save(...)` inside `recalculateOrder` was its own implicit tx. If the `stockunit` save failed after the `replenishorder` save committed, the row pair was left in a torn state. (Documented in SBDEV-2234 §2 Bug A2.)
   - **Post-SBDEV-2234 Fix B (the production-broken state, 2026-05-15 → 2026-05-20)**: `findByIdForUpdate` was added but the sweep path had no tx → every order silently raised `InvalidDataAccessApiUsageException`; no writes happened at all.
   - **Post-Fix-A (this plan)**: Spring-managed `REQUIRED` tx **per order**, opened by the proxy on entry into `self.recalculateOrder(...)` and committed on return. The pair `(replenishorder.requestedamount, stockunit.reservedamount)` either both commit together or both roll back together for that order. Sibling orders are unaffected — the outer try/catch swallows any per-order exception **after** Spring rolls back that order's tx.
   - **Worked example.** Suppose order K's `updateRequestedAmount` succeeds (`replenishorder.requestedamount` UPDATE issued) but the downstream `stockunitBusinessService.changeReservedAmount(...)` throws `FacadeException`. Pre-SBDEV-2234: the `replenishorder` UPDATE has already auto-committed → the row reflects the new `requestedamount` while the corresponding `stockunit.reservedamount` is unchanged → drift. Post-Fix-A: `rollbackFor=FacadeException` triggers; Spring rolls back order K's per-order tx; the `replenishorder` UPDATE never commits; the outer try/catch swallows the exception; sweep continues with order K+1, which opens its own fresh tx. The pair invariant is preserved.

   Net: post-fix is **strictly safer** than pre-SBDEV-2234, and **legal for `@Lock`** (unlike the production-broken interim state). The 260331 "bounded transaction width" intent is realized as N short per-order txns rather than one long sweep-wide tx — same connection-pool footprint per moment, same sibling isolation, better failure atomicity per order.

### Open questions

| # | Question | Why it matters | Default if unresolved |
|---|---|---|---|
| 1 | Should this plan ship under a new ticket (e.g., `SBDEV-2240`) or as a hot-fix under the existing SBDEV-2234 follow-up bucket? | The bug is a direct regression of SBDEV-2234; a single new ticket would help future archaeology, but the team's hot-fix flow may prefer attaching to the parent | **New ticket** (suggest `SBDEV-2240 — replenishment open-orders sweep: missing @Transactional on recalculateOrder worker (SBDEV-2234 regression)`). Cross-link in the regression chain (§3). |
| 2 | Should AC-NEW-1 access the private `RecalcContext` inner class via `Class.forName(...)` or by walking `getDeclaredMethods()` for the two-arg `recalculateOrder`? | Test brittleness vs. encapsulation | **`getDeclaredMethods()`** — stream methods, filter by name + parameter count, assert the annotation on the only two-arg variant. Avoids hardcoding the inner-class type name. |
| 3 | Should we also write a TestContainers integration test for the sweep path under no-outer-tx? | Closes the SBDEV-2234 acceptance gap that allowed this bug to ship | **Yes — file as a small follow-up plan** (1 test class, ~80 lines) once this hot-fix lands. Not gating this plan because the unit test + verify-script + production log signal are sufficient acceptance. |
| 4 | Should the project-memory directive "AOP self-proxy comment required for `self.method(...)` calls in `@Service` beans" be filed after this plan? | Prevents long-term regression by future contributors who might "tidy up" the `self.` call back to `this.` | **Yes — `project_memory_add_directive` after rollout.** Suggested text: *"In v2/wms2-api `@Service` beans, any `self.method(...)` invocation (self-injected via `@Lazy @Autowired`) is intentional for Spring AOP proxy access; never inline it back to `this.method(...)` without auditing the called method's `@Transactional` / `@Cacheable` annotations. Trigger: tidying refactors, IntelliJ 'inline variable' suggestions."* |
| 5 | Should the verify script invocation be wired into CI (e.g., `mvn verify` or a pre-commit hook)? | Ensures regression coverage outlives the implementer | **Yes — follow-up to wire all `sbdocs/9-System/scripts/verify-*.sh` into the v2/wms2-api CI pipeline as a single audit step.** Out-of-scope for this plan. |

---

## Completeness Checklist

| # | Item | Status |
|---|---|---|
| 1 | §0 affected-sites table enumerated with in-scope/out-of-scope rationale | ✓ |
| 2 | Problem statement with user-visible symptoms + reproduction | ✓ |
| 3 | Root cause with file:line + code snippets | ✓ |
| 4 | Regression chain documented (SBDEV-2234 Fix B as proximate cause) | ✓ |
| 5 | Architecture overview with ASCII flow + key-files table | ✓ |
| 6 | Fix design with Before/After code blocks | ✓ |
| 7 | File change summary table | ✓ |
| 8 | Implementation steps ordered with atomic-commit guidance | ✓ |
| 9 | Horizontal Scalability Validation (all 10 rows) | ✓ |
| 10 | v2-only constraint checklist (all 8 rows) | ✓ |
| 11 | Testing plan: unit + manual + deferred integration | ✓ |
| 12 | Risks & mitigations table | ✓ |
| 13 | Open questions / resolved decisions | ✓ |
| 14 | Acceptance script path referenced (§11) | ✓ |

---

## §11 Acceptance & Implementation

### 11.1 Acceptance script

Path: `sbdocs/9-System/scripts/verify-260520-replenishment-open-orders-missing-tx.sh`

Checks (per the §5 design):

| ID | Check | Type |
|---|---|---|
| A1 | `recalculateOrder(Replenishorder order, RecalcContext ctx)` is preceded (within 6 lines above) by `@Transactional\(value\s*=\s*"tenantTransactionManager"` | POSITIVE grep |
| A1b | The same `@Transactional` block contains `propagation\s*=\s*Propagation\.REQUIRED` | POSITIVE grep |
| A1c | The same `@Transactional` block contains `rollbackFor\s*=\s*\{?BusinessException\.class\s*,\s*FacadeException\.class\s*\}?` | POSITIVE grep |
| A1-neg | `recalculateOrder(Replenishorder order, RecalcContext ctx)` is declared `public` (not package-private) | POSITIVE grep `public\s+void\s+recalculateOrder\s*\(\s*Replenishorder\s+order\s*,\s*RecalcContext\s+ctx\s*\)` |
| A2 | The service has a field `private ReplenishmentOrderMaintenanceService self;` preceded by `@Lazy` and `@Autowired` | POSITIVE grep |
| A3 | The `recalculateOpenOrders(boolean force)` method region contains `self\.recalculateOrder\(order,\s*ctx\)` | POSITIVE grep, region-scoped (extract region via `awk '/public void recalculateOpenOrders\(boolean force\)/,/^    \}$/'` or `sed -n` on the line range computed by `grep -n`) |
| A3-neg (bare-call) | The `recalculateOpenOrders(boolean force)` region does NOT contain a bare unqualified `recalculateOrder(order, ctx)` at line-start whitespace — i.e., no `self.` / `this.` prefix. **Corrected regex (line-anchored)**: PCRE `^\s+recalculateOrder\(order,\s*ctx\)` (using `grep -P '^\s+recalculateOrder\b'` or equivalent). **Prior draft's `\brecalculateOrder\(` was broken** because the `\b` boundary matches at the `.`/letter transition in `self.recalculateOrder` — the negative check would have falsely fired on the correct fixed state. | NEGATIVE grep, region-scoped, line-anchored |
| **A3b** | The `recalculateForItem(Long itemDataId)` method region does NOT contain `self\.recalculateOrder\(order,\s*ctx\)`. **Guards the `UnexpectedRollbackException` trap documented in §5.4** — routing this call through the self-proxy activates the inner `rollbackFor` and poisons the shared `recalculateForItem` tx on any `BusinessException` / `FacadeException`. | NEGATIVE grep, region-scoped |
| A4 | `recalculateOpenOrders(boolean force)` method declaration is NOT preceded by `@Transactional` (preserves 260331 decision) | NEGATIVE grep, line-range scoped |
| A5 | `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest` exits 0. **What this proves and does NOT prove:** A5 validates **call-site grammar** (the loop compiles with `self.recalculateOrder` and routes to the worker), **test wiring** (the 3 new tests pass), and **per-order exception isolation** (new AC-NEW-3 catches catch-and-continue regressions). It does **NOT** validate proxy-routing correctness (no real Spring tx in unit tests) and does NOT directly detect §5.4's `UnexpectedRollbackException` — those are the job of the A3 / A3-neg / A3b greps + the post-deploy production log signal. See §8 AC-NEW-2 and AC-NEW-3 test-scope boundary boxes. | behavioral |
| A6 | The imports include `org.springframework.beans.factory.annotation.Autowired`, `org.springframework.context.annotation.Lazy`, `org.springframework.transaction.annotation.Propagation` | POSITIVE grep ×3 |

Script template: copy `sbdocs/9-System/templates/verify-plan-template.sh`,
set `PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"`,
and wire each check above as a `run <id> "<desc>" <fn>` line.

### 11.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Trivial-to-Standard | 1 production file modified (3 hunks), 1 test file modified (2 new methods), 1 verify script. Bounded blast radius. |
| **Pre-draft step** | none (this plan is the draft) | Bug + fix are unambiguous; no need for analyst+planner round |
| **Plan-review step** | `critic` | Concurrency-adjacent fix with a regression-chain history; second pair of eyes warranted |
| **Implementation shape** | `executor` (single-shot) | Three tight changes in one file plus two tests — no parallelism benefit |
| **Verification step** | `verify-260520-replenishment-open-orders-missing-tx.sh` + `verifier` | Mandatory |
| **Code-review step** | `code-reviewer` | Touches `@Transactional` semantics — concurrency change warrants review |
| **Commit step** | git directly (single atomic commit) | One logical commit; no separation needed |

### 11.3 ADR — Architecture Decision Record

**Decision.** Annotate `recalculateOrder(Replenishorder, RecalcContext)` with `@Transactional("tenantTransactionManager", REQUIRED)`, make it `public`, add a `@Lazy @Autowired` self-reference to `ReplenishmentOrderMaintenanceService`, and re-route the **one** sweep-loop self-call through that self-reference. Do not annotate `recalculateOpenOrders(boolean)` itself.

**Decision drivers.**
1. **Restore SBDEV-2234 correctness on the sweep path** — `findByIdForUpdate` must run inside a Spring-managed tx; the sweep currently provides none.
2. **Preserve the 260331 per-order short-tx intent literally** — no giant sweep-wide transaction; each order commits independently.
3. **Use Spring-framework idiom for AOP self-call** — `@Lazy @Autowired self` per Spring reference §6.6.1. This pattern is **new to v2/wms2-api** (no internal precedent — the cited `@Lazy` usages in `StockunitBusinessService`, `UnitloadBusinessService`, and `MessageService` serve adjacent purposes); this plan establishes the v2 precedent. No `AopContext.currentProxy()`, no `ApplicationContext.getBean(...)`.

**Alternatives considered.**

- **Option B — annotate `recalculateOpenOrders(boolean)` itself with `@Transactional`.**
  Rejected. Would wrap the entire 600-row sweep in one transaction, holding a tenant connection for the full sweep duration. Directly violates the 260331 architectural decision and the SBDEV-2234 §5 reaffirmation of that decision. Re-introduces the long-tx connection-pool concern that 260331 specifically guarded against.

- **Option C — call `recalculateForItem(order.getItemdataId())` from the sweep loop instead of the package-private worker.**
  Rejected. `recalculateForItem` re-fetches the order list per item via `findByStateAndItemdataId`, rebuilds `RecalcContext` from scratch each call, and would re-process orders multiple times within a single sweep. Quadratic-ish behavior and breaks the bulk `RecalcContext` pre-loading optimization.

- **Option D — use `AopContext.currentProxy()` cast.**
  Rejected. Requires enabling `@EnableAspectJAutoProxy(exposeProxy = true)` at application config level — unrelated blast radius. No existing v2 code uses this pattern.

- **Option E — use `applicationContext.getBean(ReplenishmentOrderMaintenanceService.class).recalculateOrder(...)`.**
  Rejected. Works but is uglier than the field-injected pattern, adds `ApplicationContext` as a dependency, and has no precedent in the v2 codebase.

- **Option F — move the per-order recalc logic into a separate Spring bean (e.g., `ReplenishmentRecalculationWorker`) so the proxy boundary is natural (cross-bean call, no self-injection needed).**
  Rejected for this plan as too-large a refactor for a hot-fix. Filed mentally as a long-term cleanup follow-up: extracting the worker would also simplify testing. Not bundled here to keep the diff small and the rollback path simple.

**Why chosen.** Option A (the chosen design) is the minimal-diff path that restores correctness, preserves the explicit 260331 architectural intent, and adopts the Spring-framework self-injection idiom (Spring reference §6.6.1) — **new to v2/wms2-api** (no prior internal precedent; see §10 Resolved Decision #1). Options B–C alter behavior beyond the bug surface; Options D–E introduce non-idiomatic patterns; Option F is the right long-term shape but wrong for a hot-fix.

**Consequences.**
- **Positive.** Sweep path resumes converging replenishment quantities. Production warning line disappears. SBDEV-2234's pessimistic-lock guarantee is restored on the sweep path (was silently inert pre-fix). Per-order rollback semantics improve (Spring-managed tx vs. JDBC autocommit).
- **Negative.** Adds a `@Lazy @Autowired` field — a minor convention bend (field injection instead of constructor injection), justified by the AOP-self-call requirement and Spring reference §6.6.1 (no internal v2 precedent — see §10 Resolved Decision #1). Per-order proxy hop adds microseconds × N orders (≤1s for a 600-row tenant; immaterial). Future contributors must understand why the `self.` call exists — mitigated by inline comment + verify-script + the project-memory directive in Open Question #4.

**Follow-ups.**
- File `project_memory_add_directive` per Open Question #4 ("AOP self-proxy comment required for `self.method(...)` calls").
- Open a small follow-up plan to add TestContainers integration coverage for the sweep path (Open Question #3).
- Consider extracting `ReplenishmentRecalculationWorker` as a separate bean in a future refactor (Option F) — would remove the need for the self-injection entirely. **Trigger condition:** any of (a) next feature change to `ReplenishmentOrderMaintenanceService` that adds a new `@Transactional` method, (b) any future bug surfaced by the §5.4 `UnexpectedRollbackException` trap class, or (c) Q3 2026 v2 refactor wave — whichever comes first. File as `wms2-replenishment-worker-extraction` plan at trigger time.
- Sweep audit: grep `src/main/java/net/aim_ai/wms/service/**` for `@Lock(` repository calls and verify each call site has an enclosing `@Transactional` either on the method or up the call stack. Likely zero other regressions of this shape, but worth a one-shot audit.

---

## RALPLAN-DR Summary (for consensus review)

**Mode.** SHORT (default). This is a small, well-scoped hot-fix with a confirmed root cause and a single viable implementation pattern. No DELIBERATE mode signal (no security review needed, no >3 services impacted, no schema change).

**Principles.**
1. **Minimum-diff correctness** — fix the bug with the smallest possible change footprint; do not bundle adjacent cleanups.
2. **Preserve explicit architectural intent** — the 260331 / SBDEV-2234 decision to keep `recalculateOpenOrders` on per-order short-tx semantics is load-bearing; restore its functional realization without re-debating it.
3. **Use Spring-framework idiom** — `@Lazy @Autowired self` per Spring reference §6.6.1. **This is new to v2/wms2-api** (no internal precedent); this plan establishes it.
4. **Close the regression vector that bit SBDEV-2234** — the verify script must include a behavioral check (`mvn test`) and structural greps; **structural greps must be line-anchored** (the prior `\b…` regex was broken).
5. **Make both regression vectors visible** — (a) the original "back-to-`this.`-in-the-sweep" tidy-up, and (b) the **new** "promote-`this.`-to-`self.`-in-`recalculateForItem`-for-symmetry" trap (§5.4 `UnexpectedRollbackException`). Verify-script A3-neg + A3b + inline `// WARNING:` comments + the **new AC-NEW-3 sibling-isolation test** (added by this plan) together form three independent guards (two structural + one behavioral).

**Decision drivers (top 3).**
1. Sweep path is currently inert in production (every order skipped each tick) — high urgency, but bounded blast radius (silent no-op, not silent corruption).
2. The fix must not re-introduce the long-sweep-tx that 260331 expressly rejected.
3. The fix must close the SBDEV-2234 acceptance gap (behavioral test, not just code-shape grep).

**Viable options (≥2 required).**

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A (chosen) — Annotate worker + `self.` invocation on the sweep loop ONLY** | `@Transactional(REQUIRED, rollbackFor=Business/FacadeException)` on `recalculateOrder(R, ctx)`; new `@Lazy @Autowired self` field; sweep loop uses `self.recalculateOrder(...)`; **`recalculateForItem`'s inner loop must remain `this.`** (§5.4 `UnexpectedRollbackException` trap) | Smallest diff. Preserves 260331 per-order semantics. Restores SBDEV-2234 lock effectiveness. Per-order rollback semantics strictly improved (atomic pair invariant — see §10 Resolved Decision #5 worked example). | Adds **a new pattern to v2/wms2-api** (no internal precedent — corrected post-critic); justified by Spring reference §6.6.1. Asymmetry between line 85 (`self.`) and line 108 (`this.`) is **semantically required**, not stylistic — guarded by verify-script A3b + inline `// WARNING:` comment + new AC-NEW-3 sibling-isolation test (added by this plan). Per-order proxy hop adds microseconds (immaterial). |
| **B — Annotate `recalculateOpenOrders(boolean)` directly** | Wrap entire sweep in one tx | Trivial diff (one annotation). No `self` injection. | **Violates 260331.** 600-row sweep holds one tenant connection for full duration → re-introduces the long-tx connection-pool concern. Per-order failure rolls back entire batch (mirrors the §5.4 trap at sweep scale). **Invalidated.** |
| **C — Replace sweep loop's worker call with `recalculateForItem(itemId)`** | Reuse the already-annotated method | Reuses an existing-and-tested annotation; no new annotation needed. | Quadratic re-fetch: each call re-runs `findByStateAndItemdataId` and rebuilds `RecalcContext` from scratch. Breaks bulk pre-loading. Performance regression. **Invalidated.** |
| **D — Extract a separate `ReplenishmentRecalculationWorker` bean** | Move worker into its own bean → cross-bean call → no self-injection needed | Cleanest long-term architecture. No `@Lazy @Autowired self` field. Cross-bean proxy boundary is natural. Test isolation improves. **Also eliminates the §5.4 asymmetry-trap entirely** (separate beans have separate `rollbackFor` scoping). | Large diff for a hot-fix. Multi-file refactor. Postpones the production fix while the refactor lands. **Recommended as the long-term follow-up** (filed in §11.3 ADR Follow-ups), not bundled here. |

**Invalidation rationale for non-chosen options.**
- **B** violates load-bearing architectural intent (260331 — sweep must not hold one tx for the full 600+ row iteration). At sweep scale, B also reproduces the §5.4 `rollbackFor`-poisons-shared-tx trap.
- **C** produces a measurable performance regression (quadratic re-fetch + breaks bulk `RecalcContext` pre-loading).
- **D** is correct shape but wrong size for a hot-fix. Recommended as the long-term follow-up — it would also eliminate the §5.4 line-85-vs-line-108 asymmetry that the chosen option must guard against in three places.

The chosen option (A) is the minimum-diff path that satisfies all decision drivers. Two viable options (A, D) reach the same correctness; A is preferred for cost and rollback simplicity in a hot-fix context. B and C are invalidated above.

---

## §12 Implementation Notes (post-rollout — fill in)

| Field | Value |
|---|---|
| Implementing commit SHA | _(fill in)_ |
| PR URL | _(fill in)_ |
| `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest` result | _(fill in)_ |
| `mvn test` full-suite result | _(fill in)_ |
| `verify-260520-replenishment-open-orders-missing-tx.sh` result | _(fill in)_ |
| Production validation (tenant `hydra-nywh` cron tick after deploy) | _(fill in: warning-line count before / after; replenishorder.modified advance count)_ |
| Status transition | draft → in-progress → implemented |
| `project_memory_add_directive` filed (Open Question #4) | _(yes/no + directive ID)_ |
| Follow-up tickets opened (TestContainers integration test; worker extraction) | _(fill in ticket IDs)_ |
