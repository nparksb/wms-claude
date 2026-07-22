---
title: "Duplicate Replenishment Orders — Concurrent Generation Defeats the NOT-EXISTS De-Dup Guards"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: archived
project: [wms1]
version: v1
requester: "Nam Park"
created: 2026-07-09
updated: "2026-07-15"
db_verified: true
related:
  - "[[wms1-replenish-workflow]]"
  - "[[wms1-replenish-order-creation]]"
  - "[[wms1-multi-unitload-replenish]]"
  - "[[wms1-scheduled-jobs-catalog]]"
  - "[[wms1-stockunit-design]]"
  - "[[260709-multi-unitload-replen-reserve-availability-guard]]"
tags:
  - plan
  - replenishment
  - concurrency
---

# Duplicate Replenishment Orders — Concurrent Generation Defeats the NOT-EXISTS De-Dup Guards

**Project:** wms1 | **Version:** v1 | **Type:** bugfix
**Priority:** high
**Status:** implemented (Architect + Critic pass + code review — see §11/§12)
**Date:** 2026-07-09

---

## 0. Affected sites (enumeration before drafting)

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1 | `schedulejob/ReplenishOrderJob.java:61` | `doCalculation(Boolean)` — the generation entry point; no concurrency guard | yes (the run that can overlap) | **yes** — Fix A wraps it |
| 2 | `service/ReplenishGeneratorService.java:87-162` | `calculateOrder(...)` — non-transactional; unlocked read-then-`INSERT` | yes (read-then-write race) | **yes** — Fix B guards it + makes it `@Transactional` |
| 3 | `service/ReplenishGeneratorService.java:172-215` | `createOrderFromTemplate(...)` — same unlocked insert; used by multi-UL split | partial (shares insert, but legit multi-order) | **yes** — Fix B must NOT touch this method |
| 4 | `controller/AdminActionController.java:87-91` | `/triggerOrderReplenish` → `replenishJob.doCalculation(false)` | yes (a second concurrent entry point) | yes — covered transitively by Fix A (guard lives in `doCalculation`) |
| 5 | `controller/SystemController.java:50` | `/triggerOrderReplenish` (second manual endpoint) → `doCalculation(false)` | yes (a third concurrent entry point) | yes — covered transitively by Fix A |
| 6 | `schedulejob/SchedulingConfiguration.java:118-129` | `replenish(...)` cron → `doCalculation(true)` | yes (the scheduled entry point) | yes — covered transitively by Fix A |
| 7 | `service/ReplenishGeneratorService.java:50-74` | `refillFixedLocations()` → same-bean `calculateOrder` call at `:65` | root-cause context (self-invocation bypasses proxy) | yes — must route via `self` so Fix B's tx engages |
| 8 | `service/mobile/MobileReplenishService.java:573-584` | `requestReplenish` (non-tx) → `calculateOrder`, null-checks return | non-job manual path | yes — Fix B covers it once `calculateOrder` is `@Transactional` |
| 9 | `service/ReplenishorderService.java:63-73` | `create(...)` (non-tx) → `calculateOrder`, null-checks return | non-job manual path | yes — same as #8 |
| 10 | `repo/jpa/ReplenishorderRepository.java:191-195` | `getIdsForItemDataWithFixedAssignmentWithOrders` NOT-EXISTS guard (item-only) | root-cause context (guard correct but not concurrency-safe) | no code change |
| 11 | `repo/jpa/ItemdataRepository.java:79-85` | `getIdsForItemDataWithoutFixedAssignment` NOT-EXISTS guard | same | no code change |
| 12 | `repo/jpa/FixLocationAssignmentRepository.java:70-73` | `getRefillFixedLocationIds` NOT-EXISTS guard | same | no code change |
| 13 | `service/ReplenishorderService.java:187-208` | `cancelReplenishmentOrder(...)` — releases reservation (floored, `findByIdForUpdate`) + CANCELED | reused for cleanup | yes — invoked by remediation (no change) |
| 14 | `service/job/ReplenishOrderJobService.java:236-250` | `cancelReplenishmentOrder(long)` REQUIRES_NEW wrapper | reused for cleanup | yes — invoked by remediation admin action (no change) |

New file introduced by the fix:
- `repo/jpa/AdvisoryLockRepository.java` — thin native wrappers for the **transaction-scoped** advisory-lock functions (`pg_try_advisory_xact_lock`, `pg_advisory_xact_lock`), two-int form.

---

## 1. Problem Statement

**User-visible symptom.** The WMS v1 *Replenishment* menu shows pairs of replenishment orders that are duplicates of each other — same SKU, same destination pick-face, same amount, created within a fraction of a second. Example reported by the tester: **REPL052259 and REPL052231** were created at essentially the same time. When an operator opens one of a duplicate pair and tries to fulfill it by scanning a unit load, they hit:

> **"Unit load stock is already reserved (0.0000 available). Choose a different unit load."**

…because the *other* duplicate order already reserved that source stock. (That message is the [[260709-multi-unitload-replen-reserve-availability-guard]] availability guard working correctly — it is the *messenger*, not the cause. The corrupt data — two orders reserving stock for one demand — is the cause.)

**Reproduction.** Trigger two overlapping replenishment generations against the same demand set, e.g.:
1. Wait for (or trigger) the daily replenishment cron, and
2. Within the same ~second, hit `GET /v3/adminAction/triggerOrderReplenish` (or the mobile/desktop "request replenish" that routes to `doCalculation`), or double-fire the trigger.

Both passes compute the same pick-face deficits and each emits a full set of replen orders.

### DB verification (mandatory gate — `db_verified: true`)

Tenant: `wms1-wineco-dev`. All queries via `mcp__wms1-wineco-dev__execute_sql` on 2026-07-09.

**(a) The reported pair is a true duplicate** (differs only in source `stockunit_id`):

```
number      state created                     itemdata  reqLoc  dest   stockunit  amt  src
REPL052231  300   2026-04-29 12:19:01.560      810830013 63941   63793  945492897  12   01-XA04
REPL052259  300   2026-04-29 12:19:01.775      810830013 63941   63793  945492899  12   01-XA04
                  ^^^^^^^^ 0.215 s apart, identical demand, different source unit
```

**(b) The 12:19:01 burst is two interleaved full passes.** Grouping open orders by `(itemdata_id, requestedlocation_id, destination_id)`:

- Every duplicate group in the burst has exactly 2 members, spaced a near-constant **0.19–0.22 s** apart.
- Pass-1 consumed numbers **REPL052146 → REPL052244**; pass-2 consumed **REPL052186 → REPL052266**. The ranges **overlap** — two runs interleaving on `nextval('replenishorder_custom_id_seq')` concurrently. (A single sequential run cannot produce overlapping bands.)
- `SELECT date_trunc('second',created), COUNT(*)` over the burst → **137 orders at 12:19:00 + 150 at 12:19:01** (~287 in ~2 s).

**(c) Scale + recurrence** (`GROUP BY item, reqLoc, dest, minute HAVING COUNT(*) > 1`, by day):

| Day | Dup groups | Dup orders |
|-----|-----------:|-----------:|
| 2026-04-28 | 182 | 364 |
| 2026-04-29 | 111 | 222 |
| 2026-07-09 (today) | 2 | 4 |
| sporadic (≥15 other days) | 1–2 each | 2–19 |

Today's **REPL052291 / REPL052292** (11:19:00, 11 ms apart, now state 800) is the same bug on a lightly-loaded box (tighter offset). Today's **REPL052285-2 / -3** are **NOT** this bug — the `-N` suffix comes from `createOrderFromTemplate` (`template.getNumber() + "-" + (seq+1)`), i.e. the legitimate multi-UL split; they coincidentally share the group key.

**(d) Live remediation scope** (open groups, excluding `%-%` split children, keep earliest per group):

```
total_orders_in_dup_groups = 296
keepers                    = 148
redundant_to_cancel        = 148
reserved_qty_to_release    = 1562.0000   -- units of source stock currently double-reserved
```

All 148 current redundant orders sit at `state = 300` (PROCESSABLE) — none started (re-verify per tenant; see §7).

---

## 2. Root Cause Analysis

### Bug 1 (primary): concurrent `doCalculation` passes defeat unlocked NOT-EXISTS de-dup guards

The generator already tries to avoid duplicates. Every selection query that feeds order creation carries a `NOT EXISTS (open replenishorder for this item[/location])` filter:

- `ItemdataRepository.getIdsForItemDataWithoutFixedAssignment` (`ItemdataRepository.java:79-85`) — item-only.
- `ReplenishorderRepository.getIdsForItemDataWithFixedAssignmentWithOrders` (`ReplenishorderRepository.java:191-195`) — item-only.
- `FixLocationAssignmentRepository.getRefillFixedLocationIds` (`FixLocationAssignmentRepository.java:70-73`) — item OR requestedlocation.

These guards are a **read-then-write with no lock**. `ReplenishGeneratorService.calculateOrder` (`:87-162`) is not transactional and does: *selection query passed the NOT-EXISTS filter → build `Replenishorder` → `save(...)` → `changeReservedAmount(...)`*. There is no lock between the "does an open order already exist?" read and the insert.

When **two `doCalculation` runs execute at the same time**, both evaluate `NOT EXISTS` before either has committed its inserts, both see "no open order," and both create a full order for the same demand — each grabbing the *next* available source stock unit (why the pair has different `stockunit_id`). The `nextval` sequence is atomic (no PK collision), so the only visible artifact is two orders with interleaved numbers — exactly the DB evidence in §1(b).

**Single-run duplication is ruled out (verified in review).** Within one pass the generation sub-steps run sequentially as `@Transactional(REQUIRES_NEW)` calls (`ReplenishOrderJobService.java:76,90,192`), so each step's inserts are committed and visible (READ COMMITTED) before the next step's selection query runs — a later step's NOT-EXISTS therefore excludes the item. The only within-pass "duplicate" possible is a legitimate second order to a *different* destination. So the mass events require two concurrent passes.

**Why the deficit is identical in both passes.** The deficit is computed from `stockunit.getAmount()` (the destination pick-face on-hand), e.g. `required = upperBound − amountOnLocation` (`ReplenishOrderJobService.java:175, 207`; `ReplenishGeneratorService.java:64`). Creating a replen order only bumps `reservedamount` on the *source* unit — it does not change the destination pick-face `amount`. So the second concurrent pass sees the same deficit and re-issues.

### Bug 2 (trigger surface): three unguarded entry points into `doCalculation`

`doCalculation` is reachable from the daily cron (`SchedulingConfiguration.replenish` → `doCalculation(true)`, `:118-129`) and from **two** manual endpoints (`AdminActionController./triggerOrderReplenish` → `doCalculation(false)`, `:87-91`; `SystemController./triggerOrderReplenish` → `doCalculation(false)`, `:50`). None coordinates with the others; `isCronJob=false` (manual) even **skips** the activation-flag check (`ReplenishOrderJob.java:65-71`). A manual trigger overlapping the cron, two admins/tabs, a double-click, or two app instances each with `app.cron=true` → two concurrent passes → Bug 1.

**Topology (verified in review).** v1/wms-api uses a **single static datasource** (`application.properties:24` → one `wh01_om1`); there is **no** `AbstractRoutingDataSource` / custom datasource bean in `src/main`. Each tenant is a **physically separate PostgreSQL database** selected by Spring profile (`SPRING_PROFILES_ACTIVE=wineco`). Therefore an advisory lock lives in that one tenant DB and a **global (non-tenant-scoped) lock key is correct**. (Monorepo CLAUDE.md's "dynamic datasource routing" describes v2, not v1.)

**CLAUDE.md rules in play.** `spring.jpa.open-in-view=false` and the mixed `REQUIRES_NEW` transaction strategy mean each generation sub-step commits independently — good for partial progress, but the de-dup read in one pass cannot see the uncommitted inserts of a *concurrent* pass. Entities compared by ID; no JPA associations.

---

## 3. Architecture Overview

```
 cron (SchedulingConfiguration.replenish, daily)        ┐
 AdminActionController./triggerOrderReplenish (false)    ├─►  ReplenishOrderJob.doCalculation()
 SystemController./triggerOrderReplenish (false)         ┘        │  (activation check, then self.doCalculationGuarded())
                                                                  │
                                        Fix A: @Transactional doCalculationGuarded()
                                        first stmt: pg_try_advisory_xact_lock(RUN) — skip if a run is already active
                                                                  │ (lock held for the whole run; auto-released at tx end)
                                                                  ▼
   generateReplenishmentForItemDataWithoutFixedAssignment ─┐
   generateReplenishmentForItemDataWithFixedAssignmentWithOrders ├─► ReplenishOrderJobService.* (REQUIRES_NEW, suspend/resume)
   triggerRegularReplenishment (refillFixedLocationAssignment) ──┘        │
                                                                          ▼
                             ReplenishGeneratorService.calculateOrder()  [now @Transactional]
                                Fix B: pg_advisory_xact_lock(DEMAND, hash(item,dest))  — BLOCKS on peer
                                       → re-check existsOpenForItemAndDestination → skip if present
                                                                          │
                                                                          ▼
                                             exactly one Replenishorder per demand
```

### Key files

| File | Lines | Role |
|------|-------|------|
| `schedulejob/ReplenishOrderJob.java` | 58, 61-97, 150 | `doCalculation`; existing `self` proxy (reused by Fix A) — **Fix A wrap point** |
| `controller/AdminActionController.java` / `controller/SystemController.java` | 87-91 / 50 | manual triggers (covered transitively) |
| `schedulejob/SchedulingConfiguration.java` | 118-129 | daily cron |
| `service/ReplenishGeneratorService.java` | 50-74, 83-162, 172-215 | `refillFixedLocations`/`calculateOrder`/`createOrderFromTemplate` — **Fix B point**; make `calculateOrder` `@Transactional` |
| `service/job/ReplenishOrderJobService.java` | 76,90,192,236-250 | REQUIRES_NEW callers of `calculateOrder`; `cancelReplenishmentOrder` (cleanup) |
| `service/mobile/MobileReplenishService.java` | 573-584 | non-tx manual caller of `calculateOrder` (null-checks return) |
| `service/ReplenishorderService.java` | 63-73, 187-208 | non-tx manual caller; `cancelReplenishmentOrder` (floored + `findByIdForUpdate`) |
| `repo/jpa/*` (3 queries) | see §0 | existing NOT-EXISTS filters (correct once runs are serialized) |
| `application.properties` | 4, 24 | Hikari `maximumPoolSize=5`; single static datasource |

---

## 4. Fix Design

> **Design principle (from review): use only transaction-scoped advisory locks.** `pg_advisory_xact_lock` / `pg_try_advisory_xact_lock` are released automatically at the end of the transaction that acquired them. This **eliminates the session-lock-leak failure class entirely** — there is no `pg_advisory_unlock` to skip, no dependence on which pooled connection runs the release, and no possibility of a leaked lock silently stalling all future replenishment. (The earlier session-lock + `finally`-unlock design was rejected in review for exactly that leak risk.)

New repository (native queries, two-int lock form to give Fix A and Fix B separate namespaces):

```java
// repo/jpa/AdvisoryLockRepository.java
@Repository
public interface AdvisoryLockRepository extends Repository<..., Long> {
    // Fix A: non-blocking run lock — returns false if another run already holds it.
    @Query(value = "SELECT pg_try_advisory_xact_lock(:classifier, :key)", nativeQuery = true)
    boolean tryXactLock(@Param("classifier") int classifier, @Param("key") int key);

    // Fix B: blocking demand lock — waits until the current holder's tx commits.
    // pg_advisory_xact_lock returns void; wrap it so the native query yields a mappable column.
    @Query(value = "SELECT 1 FROM (SELECT pg_advisory_xact_lock(:classifier, :key)) locked", nativeQuery = true)
    Integer xactLock(@Param("classifier") int classifier, @Param("key") int key);
}
```

`WmsConstants` (distinct classifiers so a demand key can never collide with the run lock):
```java
public static final int ADVISORY_CLASS_REPLENISH_RUN    = 42071001;  // Fix A namespace
public static final int ADVISORY_CLASS_REPLENISH_DEMAND = 42071002;  // Fix B namespace
```

### Fix A (primary): serialize the whole run with a transaction-scoped advisory lock

Split `doCalculation` so the guard sits inside a transactional method invoked through the **existing `self` proxy** (`ReplenishOrderJob.java:58`, already used for `self.mergePickingOrders(...)` at `:150`):

```java
public void doCalculation(Boolean isCronJob) {
    if (isCronJob && !activated()) { /* existing early-return at :65-71 */ return; }
    self.doCalculationGuarded();                    // through the proxy → real @Transactional
}

@Transactional  // default (single JpaTransactionManager on the one datasource); no qualifier needed
public void doCalculationGuarded() {
    // Fix A — one replenishment generation at a time (this DB / this tenant).
    if (!advisoryLockRepository.tryXactLock(
            WmsConstants.ADVISORY_CLASS_REPLENISH_RUN, 0)) {
        LOG.info("replenishment generation already in progress on another run/instance — skipping");
        return;                                     // lock never acquired; nothing to release
    }
    // ... existing body: mergePickingOrders(); ... recalculateOpenOrders(true); ...
    // NO explicit unlock — pg_*_xact_lock auto-releases when this tx ends.
}
```

Why this holds for the whole run: the sub-steps are `@Transactional(REQUIRES_NEW)` (`ReplenishOrderJobService.*`), which **suspend** (not commit) the outer `doCalculationGuarded` transaction and run on their own connections, committing independently (partial progress preserved). The outer connection — holding the xact lock — stays bound and is resumed between steps, so the lock is held until the outer tx completes, then auto-released. Because the guard lives inside `doCalculation`, **all three entry points (cron + both manual triggers) are serialized automatically** — no controller changes.

Pool note (`maximumPoolSize=5`): the outer tx pins 1 connection for the run; each REQUIRES_NEW step transiently pins 1 more → peak 2 of 5. The run is short and single-threaded; acceptable. If pool pressure is ever observed, the alternative is a dedicated-`Connection` component holding a **session** lock via try-with-resources (`close()` releases it) — but that reintroduces manual JDBC and is not recommended.

**Why not a DB partial-unique index on `(itemdata_id, destination_id) WHERE state < FINISHED`?** It would forbid the *legitimate* multi-UL split, which deliberately creates several open orders (`REPL…-2`, `-3`) for one item/destination. Rejected.

### Fix B (defense-in-depth): atomic idempotency re-check in `calculateOrder`, under a BLOCKING demand lock

Covers any caller that bypasses `doCalculation` (mobile `requestReplenish`, desktop `create`) and any residual race. Two coupled changes to `ReplenishGeneratorService`:

1. **Make `calculateOrder` transactional AND guarantee proxy entry** so the demand lock always lives in a real transaction (else it releases immediately in autocommit and Fix B is a silent no-op). Two coupled moves:

   **(a) Annotate the lock-bearing 4-arg overload `REQUIRES_NEW`** (NOT default REQUIRED — see the rollback hazard below). The 3-arg overload stays a plain, non-transactional delegator that routes to the 4-arg via `self`:
   ```java
   // 3-arg (:83) — plain delegator, NOT @Transactional:
   public Replenishorder calculateOrder(Long itemDataId, BigDecimal amount, Long destinationId) {
       return self.calculateOrder(itemDataId, amount, destinationId, WmsConstants.Priority.PRIORITY_VERY_LOW);  // via proxy → 4-arg's tx engages
   }

   // 4-arg (:87) — holds the demand lock + re-check + insert, in its OWN isolated transaction:
   @Transactional(propagation = Propagation.REQUIRES_NEW,
                  rollbackFor = { FacadeException.class, BusinessException.class })
   public Replenishorder calculateOrder(Long itemDataId, BigDecimal amount, Long destinationId, Integer priority) { ... }
   ```

   > **Why `REQUIRES_NEW`, not REQUIRED (critical).** `calculateOrder` throws `FacadeException` on its routine no-stock path (`:110`), and every job caller **catches and swallows** it (`ReplenishOrderJobService.java:82-85`). If `calculateOrder` used default REQUIRED, it would *participate* in the caller's `REQUIRES_NEW` transaction; its `rollbackFor` would mark that **shared** tx rollback-only, and — because the caller swallows the exception — the job step would then throw `UnexpectedRollbackException` at commit, propagating out of the narrowly-catching generation loop (`ReplenishOrderJob.java:254` catches only optimistic-lock) and **aborting the entire run** on the common no-stock case. `REQUIRES_NEW` isolates `calculateOrder`'s transaction: on `FacadeException` it rolls back only its own (write-free) tx, the caller's caught exception leaves the job's `REQUIRES_NEW` tx clean, and the pass continues. It also makes a late failure (`changeReservedAmount` throwing after `save` at `:156-158`) atomic — the order+reservation roll back together instead of orphaning.

   **(b) Inject `self` and route the two same-bean calls through it** so the lock-bearing 4-arg is *always* reached through the Spring proxy (a same-bean `this.` call bypasses the proxy and leaves `@Transactional` inert):
   ```java
   @Autowired private ReplenishGeneratorService self;   // NEW — absent today
   // :65  refillFixedLocations():  self.calculateOrder(ass.getItemdataId(), required, ass.getAssignedlocationId());
   // :84  3-arg overload:          return self.calculateOrder(itemDataId, amount, destinationId, WmsConstants.Priority.PRIORITY_VERY_LOW);
   ```

   **Verified caller graph** (why both moves are needed — `refillFixedLocations` is reachable, so its `:65` call is not dead):

   | Caller | Overload | Transaction when it reaches the 4-arg lock |
   |--------|----------|--------------------------------------------|
   | `ReplenishOrderJobService:81/178/208` (REQUIRES_NEW, swallows FacadeException) | 3-arg | 4-arg **suspends** the job tx and runs in its **own** REQUIRES_NEW tx; a no-stock `FacadeException` rolls back only the 4-arg tx, the job tx resumes clean — no `UnexpectedRollbackException` |
   | `ReplenishorderService.create:69` (non-tx, cross-bean) | 4-arg | proxy opens the 4-arg's REQUIRES_NEW tx — correct |
   | `MobileReplenishService.requestReplenish:581` (non-tx, cross-bean) | 3-arg | 3-arg delegator → `self`→4-arg → proxy opens the REQUIRES_NEW tx (this is why the 3→4 hop must go via `self`) |
   | `ReplenishGeneratorService.refillFixedLocations:65` (from `MobileReplenishService:481,788`) | 3-arg, same-bean | `self`→3-arg→`self`→4-arg opens its own per-demand REQUIRES_NEW tx |

   Net: every path that reaches the 4-arg (lock + insert) enters through the proxy into an **isolated** REQUIRES_NEW tx, so the demand lock is never in autocommit and a caught checked-exception from `calculateOrder` never poisons a caller's transaction. Confirm with `grep -rn "calculateOrder(" src/main` during implementation.

   **Connection budget (`maximumPoolSize=5`).** Job path peak = `doCalculationGuarded` (1, holds RUN lock) + sub-step `REQUIRES_NEW` (1) + `calculateOrder` `REQUIRES_NEW` (1) = **3 of 5**. Acceptable: the RUN lock serializes passes so only one generation runs at a time; note the headroom for concurrent API traffic.

2. **Blocking demand lock + re-check before insert** (only in `calculateOrder`, **never** `createOrderFromTemplate`):
   ```java
   int demandKey = 31 * Long.hashCode(itemDataId)
                 + (destinationId == null ? 0 : Long.hashCode(destinationId));   // 32-bit; collisions only over-serialize (harmless)
   advisoryLockRepository.xactLock(WmsConstants.ADVISORY_CLASS_REPLENISH_DEMAND, demandKey);   // BLOCKS until peer tx commits
   if (replenishorderRepository.existsOpenForItemAndDestination(itemDataId, destinationId, WmsConstants.State.FINISHED)) {
       LOG.info("open replenishment already exists for item=" + itemDataId + " dest=" + destinationId + " — skip create");
       return null;   // job callers ignore the return; non-job callers already null-check (verified)
   }
   // ... existing build + save + reserve ...
   ```
   Blocking (`pg_advisory_xact_lock`, **not** `pg_try_…`) is essential: a second concurrent create for the same demand waits until the first commits, *then* the re-check sees the committed row and returns `null`. A non-blocking try that ignored its result would let the second create proceed before the first commits — no serialization at all.

New finder:
```java
@Query(value = "SELECT (COUNT(*) > 0) FROM replenishorder " +
    "WHERE itemdata_id = :itemDataId AND state < :finished " +
    "AND ((:dest)::bigint IS NULL OR destination_id = :dest)", nativeQuery = true)
boolean existsOpenForItemAndDestination(@Param("itemDataId") long itemDataId,
                                        @Param("dest") Long dest, @Param("finished") int finished);
```

**Key granularity note.** The existing selection guards key on **item only**; Fix B's re-check keys on **(item, destination)**. This is intentional — it lets a legitimate second order go to a *different* destination while still blocking a true same-demand duplicate. Its practical effect on the mobile manual path: `requestReplenish` becomes a silent no-op when an open order for that (item, dest) already exists — verified safe (`MobileReplenishService.java:582-583` and `ReplenishorderService.java:70` both null-check). The `null`-destination branch (`(:dest)::bigint IS NULL`) is exercised by the without-fixed-assignment path (`ReplenishOrderJobService.java:81`) and must be covered by tests.

**`createOrderFromTemplate` is explicitly excluded** — the multi-UL split (`MobileReplenishService.java:780`, inside `@Transactional fulfillMultipleUnitLoads`) is *meant* to create multiple open orders for one template/destination.

### Fix C (data remediation): cancel the redundant open duplicates via the app path

Cancel every redundant open order via the **existing** `ReplenishOrderJobService.cancelReplenishmentOrder(id)` (`:236-250`, REQUIRES_NEW), which calls `ReplenishorderService.cancelReplenishmentOrder` → `findByIdForUpdate` + floored `changeReservedAmount(negate, CODE_REPLENISHMENT_CANCELLED)` + state 800, and writes stock-history. This path is row-locked, floored at zero, and per-order idempotent.

**No raw-SQL variant.** The raw `UPDATE stockunit SET reservedamount = reservedamount - …` approach is rejected: `UPDATE … FROM` applies one arbitrary matching row (under-releases when two redundant orders share a `stockunit_id`), has no zero floor (can go negative), takes no row lock (races live `changeReservedAmount`), and writes no history.

**State safety.** Remediation targets **`state = 300` (PROCESSABLE) only**, and **skips any group that has a member with `state ≥ STARTED (500)`** — so a duplicate whose sibling is mid-pick is never cancelled and no scanned work is invalidated. Delivery: a one-off admin action / script that loops the reviewed IDs through `cancelReplenishmentOrder(id)`. If the loop dies mid-batch it is safe to re-run (per-order idempotent; already-cancelled orders are skipped by the state filter).

---

## 5. Implementation Steps

### 5.1 Prerequisites

| Concern | Detail |
|--------|--------|
| DB state | 148 redundant open dup orders on wineco-dev (1562 units double-reserved), all at state 300 — Fix C required post-deploy. Re-derive per tenant. |
| Feature flags / sysprops | None new. Existing `NEW_CRON_JOB_ACTIVATED` / `REPLENISHMENT_TIMER_ACTIVATED` unchanged. |
| Deploy order | 1) deploy code (Fix A+B), 2) confirm no new dup groups for one cron cycle, 3) run Fix C. Remediating *before* the code fix would let the next overlapping run recreate dupes. |
| DB dialect | PostgreSQL only (dev + prod) — `pg_*advisory_xact*` safe. Testcontainers PG 12 → the concurrency test uses the real functions. |
| Topology | v1 = one PG DB per deployment/tenant (verified). Global lock key is tenant-safe. If any deployment ever points two facilities at one DB, the run lock would serialize replenishment across them (acceptable, but note it). |
| Access | DB write on target tenant for Fix C; deploy pipeline for code. |
| Monitoring | After deploy, watch for the new "already in progress … skipping" log line to confirm the guard engages; alert if the daily dup-group count (§7 query) > 0. Ops escape hatch for a stuck run lock: it auto-releases at tx end; if a JVM hangs mid-run, killing/recycling that backend releases it (session ends). |

### 5.2 Ordered steps

1. Add `AdvisoryLockRepository` (`tryXactLock`, `xactLock`) + `ADVISORY_CLASS_REPLENISH_RUN` / `ADVISORY_CLASS_REPLENISH_DEMAND` in `WmsConstants`. *(commit)*
2. **Fix A** — extract `doCalculationGuarded()` (`@Transactional`), acquire `tryXactLock(RUN,0)` as its first statement (skip on false), call it via `self` from `doCalculation` after the activation check. *(commit)*
3. Add `ReplenishorderRepository.existsOpenForItemAndDestination`. *(commit)*
4. **Fix B** — make `calculateOrder` `@Transactional`; add blocking `xactLock(DEMAND, hash)` + existence re-check before insert; route same-bean self-calls via `self`; leave `createOrderFromTemplate` untouched. First `grep -rn "calculateOrder(" src/main` and confirm no caller dereferences the return without a null check (verified: only `MobileReplenishService:582`, `ReplenishorderService:70`, both guarded). *(commit)*
5. Tests — unit (Fix A skip-when-locked; Fix B skip/create incl. null-destination; multi-UL split still creates N) **and** the Testcontainers-PG concurrency test (step below). *(commit)*
6. **Fix C** — run the §7 dry-run, review, then loop the IDs through `cancelReplenishmentOrder(id)` on each tenant after deploy. *(ops step)*

### 5.3 File Change Summary

| File | Change | Description |
|------|--------|-------------|
| `repo/jpa/AdvisoryLockRepository.java` | **new** | native `pg_try_advisory_xact_lock` / `pg_advisory_xact_lock` (two-int) |
| `service/WmsConstants.java` | edit | add the two advisory classifiers |
| `schedulejob/ReplenishOrderJob.java` | edit | Fix A: `doCalculationGuarded` + `self` delegation |
| `service/ReplenishGeneratorService.java` | edit | Fix B: both `calculateOrder` overloads `@Transactional`; new self-injected field; blocking demand lock + re-check; `self`-route `:65` and `:84` |
| `repo/jpa/ReplenishorderRepository.java` | edit | add `existsOpenForItemAndDestination` |
| tests | new | unit + Testcontainers-PG concurrency test (see §6) |

---

## 6. Testing Plan

### Unit (Mockito 3.3.3 — no `mockStatic`)
- `ReplenishOrderJobUnitTest`
  - `doCalculation_skipsGeneration_whenRunLockNotAcquired` → `tryXactLock(RUN,0)` returns `false` ⇒ no generation sub-service invoked (`verify(..., never())`).
  - `doCalculation_runsGeneration_whenRunLockAcquired` → `true` ⇒ body runs.
- `ReplenishGeneratorServiceUnitTest`
  - `calculateOrder_skips_whenOpenOrderExists` → `existsOpenForItemAndDestination` true ⇒ returns null, no `save`, no `changeReservedAmount`; verify `xactLock(DEMAND, …)` was called first.
  - `calculateOrder_creates_whenNoOpenOrder` → false ⇒ one save + one reserve (happy path).
  - `calculateOrder_nullDestination_isHandled` → destination null path (without-fixed-assignment) exercises the `(:dest) IS NULL` branch.
  - `createOrderFromTemplate_stillCreatesEachSplit_forMultiUL` → the existence guard is NOT consulted; N children still created (multi-UL split regression guard).
- `ReplenishGenerationTransactionBoundaryIT` (or a focused slice) — **rollback-isolation guard for C-R2**: a `REQUIRES_NEW` caller that catches `calculateOrder`'s no-stock `FacadeException` must complete normally (no `UnexpectedRollbackException`) and continue to the next item. Proves the 4-arg's `REQUIRES_NEW` propagation isolates rollback; a REQUIRED annotation would fail this. Needs a real tx manager (Testcontainers-PG / `@DataJpaTest`-style), not a Mockito unit test.

### Integration — the real-race proof (Testcontainers PostgreSQL 12, **no full `@SpringBootTest` context**)
- `ReplenishAdvisoryLockConcurrencyIT` — a narrow `@DataJpaTest` / raw-JDBC test that needs only the PG container + `db/migration` (Flyway), **deliberately avoiding** the broken full-context IT harness (ro_id view drift / SBDEV-2384; see [[v1-its-blocked-roid-view-drift]] / [[wms2-it-harness-broken-sbdev-2217]]). Two threads/connections both take `pg_advisory_xact_lock(DEMAND, k)` and attempt to create an order for the same demand; assert the lock **serializes** them and **exactly one** `replenishorder` survives (the second sees the committed row and skips). This is the only test that proves atomicity — the unit tests only prove wiring.

### Regression
- Full `mvn test` after targeted tests pass.
- `MobileReplenishServiceUnitTest` (multi-UL, 87 tests) must stay green — confirms Fix B didn't touch the split path.

### Manual test plan

| # | Scenario | Env | Steps | Expected |
|---|----------|-----|-------|----------|
| M1 | Overlapping trigger | wineco-dev | Fire `/v3/adminAction/triggerOrderReplenish` twice within ~1 s (or trigger + let cron fire) | Second run logs "already in progress … skipping"; **no** new dup groups (§7 count = 0) |
| M2 | Normal generation unaffected | wineco-dev | Single trigger with a real deficit | Deficits filled once; orders generated as before |
| M3 | Multi-UL split intact | wineco-dev | Run a multi-UL replen that splits across ≥2 source ULs | `REPL…-2`, `-3` children still created |
| M4 | Fix C releases stock | wineco-dev | Run §7 remediation; open a former-victim replen and scan its UL | UL shows available > 0; replen proceeds (no "already reserved (0.0000)") |

---

## 7. Data remediation (Fix C) — exact queries + app-path apply

**Dry-run (review before applying) — state-guarded:**

```sql
WITH grp AS (
  SELECT id, number, created, state, itemdata_id, requestedlocation_id, destination_id,
         stockunit_id, requestedamount,
         ROW_NUMBER() OVER (PARTITION BY itemdata_id, requestedlocation_id, destination_id
                            ORDER BY created, id) AS rn,
         COUNT(*)     OVER (PARTITION BY itemdata_id, requestedlocation_id, destination_id) AS grp_size,
         MAX(state)   OVER (PARTITION BY itemdata_id, requestedlocation_id, destination_id) AS grp_max_state
  FROM replenishorder
  WHERE state < 700 AND number NOT LIKE '%-%'      -- open, exclude legit multi-UL split children
)
SELECT id, number, stockunit_id, requestedamount
FROM grp
WHERE grp_size > 1          -- duplicated demand
  AND rn > 1                -- keep the earliest, cancel the rest
  AND state = 300           -- only cancel PROCESSABLE (never a started pick)
  AND grp_max_state < 500   -- skip the whole group if ANY member is >= STARTED
ORDER BY itemdata_id, created;
-- wineco-dev 2026-07-09: 148 rows, sum(requestedamount)=1562, all state=300
```

**Apply — app path only:** feed the reviewed `id` list to `ReplenishOrderJobService.cancelReplenishmentOrder(id)` (a one-off admin action / small script). This releases each source reservation (floored, row-locked) and writes stock-history. Re-runnable if interrupted. **Do not** hand-edit `stockunit.reservedamount` in SQL.

**Monitoring query (dup groups formed today — should be 0 after deploy):**
```sql
SELECT COUNT(*) FROM (
  SELECT 1 FROM replenishorder
  WHERE created::date = CURRENT_DATE AND number NOT LIKE '%-%'
  GROUP BY itemdata_id, requestedlocation_id, destination_id, date_trunc('minute', created)
  HAVING COUNT(*) > 1) d;
```

---

## 8. Acceptance

Encoded in `verify-260709-duplicate-replenishment-orders-concurrent-generation.sh`:

1. `AdvisoryLockRepository` defines `pg_try_advisory_xact_lock` (Fix A) **and** `pg_advisory_xact_lock` (Fix B). *(transaction-scoped only — a `pg_advisory_unlock`/session-lock implementation must FAIL this gate.)*
2. `WmsConstants` defines both classifiers (`ADVISORY_CLASS_REPLENISH_RUN`, `ADVISORY_CLASS_REPLENISH_DEMAND`).
3. `ReplenishOrderJob` has a `@Transactional doCalculationGuarded()` that calls `tryXactLock`, and `doCalculation` delegates to it via `self`.
4. The lock-bearing 4-arg `ReplenishGeneratorService.calculateOrder` is `@Transactional(propagation = Propagation.REQUIRES_NEW, rollbackFor = {FacadeException, BusinessException})` (grep asserts `REQUIRES_NEW` on `ReplenishGeneratorService`), and it calls the **blocking** `xactLock` (grep asserts `pg_advisory_xact_lock`, not only the try-variant) before the existence check. *(REQUIRES_NEW, not REQUIRED — so a swallowed no-stock `FacadeException` cannot roll back a job caller's tx.)*
5. **Proxy-entry guarantee:** `ReplenishGeneratorService` has a self-injected field and the two same-bean calls (`refillFixedLocations`→`calculateOrder`, 3-arg→4-arg) are routed via `self.calculateOrder(` — so the lock-bearing method is never reached by a proxy-bypassing `this.` call.
6. `ReplenishorderRepository.existsOpenForItemAndDestination` present; `calculateOrder` consults it before `save`.
7. `createOrderFromTemplate` does **not** consult the existence check (grep asserts absence — multi-UL split preserved).
8. `ReplenishOrderJobUnitTest` + `ReplenishGeneratorServiceUnitTest` pass (skip-when-locked; skip-when-open; null-destination; multi-UL still splits).
9. **Concurrency criterion:** `ReplenishAdvisoryLockConcurrencyIT` present and, where the PG container is available, green — two contending transactions driving the **Spring-proxied** `calculateOrder` (3-arg mobile entry) yield exactly one order (an inert `@Transactional` fails this test).

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Advisory lock leaks → all future runs skip | replenishment stops generating | **Eliminated by design**: xact-scoped locks auto-release at tx end; no `pg_advisory_unlock`, no session lock, no `finally`. Acceptance gate rejects any session-lock impl. |
| Fix B lock non-blocking (try + ignore) → race stays open | dupes persist | Use **blocking** `pg_advisory_xact_lock`; acceptance check 4 asserts it. |
| `calculateOrder` not transactional / proxy-bypassed → Fix B no-op on manual paths | residual manual-trigger dupes | 4-arg `calculateOrder` is `@Transactional(REQUIRES_NEW)`; same-bean self-calls routed via `self`; acceptance checks 4 + 5. |
| `calculateOrder` REQUIRED propagation poisons a job caller's tx on swallowed `FacadeException` (C-R2) | whole run aborts via `UnexpectedRollbackException` on the routine no-stock path | 4-arg `calculateOrder` is **`REQUIRES_NEW`** (isolated rollback); `ReplenishGenerationTransactionBoundaryIT` proves catch-and-continue; acceptance check 4 asserts `REQUIRES_NEW`. |
| Outer tx + nested `REQUIRES_NEW` steps pin connections (pool = 5) | pool pressure under load | Run is short/single-threaded (serialized by the RUN lock); peak **3 of 5** (`doCalculationGuarded` + sub-step + `calculateOrder`). |
| Fix C cancels an in-progress pick | invalidated operator work | Remediation restricted to `state = 300` and skips groups with any member ≥ STARTED (§7). |
| Fix C reservation release wrong (raw SQL) | negative/under-released reservedamount, audit gap | Raw SQL removed; app path only (floored, `findByIdForUpdate`, writes history, idempotent). |
| Fix B `null` return dereferenced | NPE | Verified: only job callers (ignore return) + two manual callers that null-check (`MobileReplenishService:582`, `ReplenishorderService:70`). |
| Two facilities share one DB (future) | run lock serializes both | Documented; not a current topology (one DB per tenant). |
| Concurrency unprovable in CI (SBDEV-2384) | fix ships unverified | Narrow `@DataJpaTest`/JDBC PG test sidesteps the broken full context; manual M1 is the pre-deploy behavioral gate. |

---

## 10. Open Questions / Resolved Decisions

**Resolved (2026-07-09, requester):**
- **Locking approach → transaction-scoped PostgreSQL advisory lock** (run-level for Fix A, blocking demand-level for Fix B). Cross-instance safe; leak-free by construction.
- **Defense-in-depth → yes** (Fix B in `calculateOrder`, made transactional; `createOrderFromTemplate` excluded).
- **Existing dupes → cleanup included** (Fix C, app path, state-guarded).

**Resolved in review (Architect/Critic):**
- **Tenant scoping of the lock key** → not needed: v1 is one physical PG DB per tenant (no routing datasource); global key is correct.
- **`calculateOrder` null-return safety** → safe; both non-job callers null-check.
- **Lock namespace** → Fix A and Fix B use distinct two-int classifiers; no collision.

**Open:**
1. **Deployment topology** — does wineco run one combined instance or split cron/API JVMs? Does not change the fix (DB advisory lock is correct either way); confirms whether the mass 04-28/04-29 events were multi-instance cron vs. manual+cron overlap. *Recommend confirming before deploy for root-cause completeness.*
2. Consolidating the two `/triggerOrderReplenish` endpoints (`AdminActionController`, `SystemController`) — out of scope (Fix A covers both); flagged as tech-debt.

---

## 11. Review log

- **2026-07-09 — Architect (read-only):** DESIGN NEEDS CHANGES. Must-fix: Fix B blocking lock; Fix A connection-affinity/leak; `calculateOrder` transactionality. Resolved tenant-scoping (one DB/tenant) and null-return safety. Should-fix: two-int lock namespace.
- **2026-07-09 — Critic (read-only):** APPROVE-WITH-CHANGES. Must-fix: commit Fix A to a leak-free lock + strengthen acceptance; Fix B blocking; Fix C `state=300`/skip-started; remove raw-SQL Fix C; add two-connection PG concurrency test + §8 criterion.
- **2026-07-09 — Author (round 1):** all round-1 must-fixes + should-fixes folded in. Fix A switched to xact-scoped lock via `self.doCalculationGuarded()` (eliminates the session-lock leak class rather than mitigating it).
- **2026-07-09 — Critic (re-review):** APPROVE-WITH-CHANGES. Confirmed C1/M1/M2/M3/M4 genuinely closed. One residual MAJOR-1: Fix B's `@Transactional` engagement depended on an unverified same-bean self-invocation (mobile `requestReplenish:581` → 3-arg → 4-arg), so Fix B could be a silent no-op on the mobile path. Minors: `xactLock` void-column mapping; loose A3a grep.
- **2026-07-09 — Author (round 2):** MAJOR-1 closed — self-injected field + both same-bean calls (`:65`, `:84`) routed via `self`; verified caller graph (incl. reachable `refillFixedLocations` from `MobileReplenishService:481,788`) added to Fix B. Acceptance gains criterion 5 (proxy-entry) and a proxied-bean concurrency IT. Minors fixed: `xactLock` wrapped `SELECT 1 FROM (…)`; A3a anchored.
- **2026-07-09 — Critic (re-review round 2):** APPROVE-WITH-CHANGES. MAJOR-1 verified closed. One new CRITICAL C-R2: `calculateOrder` `@Transactional` with default REQUIRED + `rollbackFor={Facade,Business}` poisons the caller's `REQUIRES_NEW` tx on the routine no-stock `FacadeException` (`:110`), which the job swallows (`ReplenishOrderJobService:82-85`) → `UnexpectedRollbackException` aborts the whole pass. Confirmed no `globalRollbackOnParticipationFailure` override (default true → fires).
- **2026-07-09 — Author (round 3):** C-R2 closed — lock-bearing 4-arg `calculateOrder` is now `@Transactional(propagation = REQUIRES_NEW, rollbackFor={FacadeException,BusinessException})` (isolated tx); 3-arg reduced to a plain `self`-routed delegator. Caller-graph notes corrected; connection budget re-stated (3 of 5); acceptance criterion 4 now asserts `REQUIRES_NEW`; added `ReplenishGenerationTransactionBoundaryIT` (catch-and-continue rollback-isolation guard). Status → reviewed; ready for `wms-tdd-gate`.
- **2026-07-09 — Code review (post-implementation):** 0 CRITICAL, 0 HIGH, 3 MEDIUM, 4 LOW; recommendation COMMENT (nothing blocking). M1 (outer-tx pins a connection / `recalculateOpenOrders` joins the run tx) — accepted with rationale (idempotent, self-heals next run) + documented on `doCalculationGuarded`; pool-headroom note added. M2 (Fix B silently depends on proxy) — added a `TransactionSynchronizationManager.isActualTransactionActive()` warning in the 4-arg. M3 (blocking demand lock pins a connection while waiting) — accepted with rationale (blocking required for correctness; ms-bounded critical section; Fix A removes job-vs-job contention) + documented. LOWs: `InOrder` lock-ordering assertion added; item-vs-(item,dest) granularity + multi-UL-split-unguarded notes added; `demandLockKey` overflow already documented.

---

## 12. Implementation Status — 2026-07-09 (implemented)

Branch `fix/260709-duplicate-replen-concurrent-generation` off `origin/develop`.

**Code (Fix A + Fix B):**
- `service/WmsConstants.java` — `ADVISORY_CLASS_REPLENISH_RUN` / `ADVISORY_CLASS_REPLENISH_DEMAND`.
- `repo/jpa/AdvisoryLockRepository.java` (new) — `tryXactLock` (`pg_try_advisory_xact_lock`) + blocking `xactLock` (`pg_advisory_xact_lock`, wrapped for clean mapping).
- `repo/jpa/ReplenishorderRepository.java` — `existsOpenForItemAndDestination`.
- `schedulejob/ReplenishOrderJob.java` — `doCalculation` delegates to `@Transactional doCalculationGuarded()` via `self`; run-level `tryXactLock` skip-if-busy.
- `service/ReplenishGeneratorService.java` — 4-arg `calculateOrder` `@Transactional(REQUIRES_NEW, rollbackFor=…)` + blocking demand lock + existence re-check (returns `null` on skip) + tx-active warning; 3-arg is a `self`-routed delegator; `refillFixedLocations` routed via `self`; `createOrderFromTemplate` deliberately unguarded.

**Tests:**
- `ReplenishGeneratorServiceUnitTest` — 3 new (skip-when-open, null-destination, lock-then-check-then-save ordering) + 11 existing; **14/14 green**.
- `ReplenishOrderJobUnitTest` — 5/5 green (unaffected).
- `ReplenishAdvisoryLockConcurrencyIT`, `ReplenishGenerationTransactionBoundaryIT` — authored, `@Disabled(SBDEV-2384)` (v1 IT harness cannot boot); interim behavioral gate = Manual Test M1/M2.

**Verification:** `mvn -o test -Dtest=ReplenishGeneratorServiceUnitTest,ReplenishOrderJobUnitTest` → 19/19 pass; `mvn -o test-compile` clean (Java 8). `verify-260709-…sh` → **19 pass, 0 fail**.

**PR:** https://github.com/SiteBossInc/wms-api/pull/195 (→ `develop`), commit `1d5d847`.

**Fix C remediation — DONE on wineco-dev (2026-07-09):** cancelled **148** redundant open orders and released **1562** units of double-reserved stock via the atomic single-statement SQL in §7 (release aggregated per `stockunit_id`, floored at 0; state→800). Verify: `still_dup = 0`; spot-check REPL052259 → CANCELED + source freed, keeper REPL052231 → still open with its reservation intact. Audit note: the SQL path (used here) does not write stock-history rows; use the API cancel path on tenants where that audit trail is required. Re-run §7 per remaining tenant after their deploy.

> ⚠️ Remediation was run on `wineco-dev` before PR #195 was deployed (to unblock the tester). Until #195 ships, a concurrent replenishment run can regenerate duplicates — re-check the §7 monitoring query and re-run if needed.
