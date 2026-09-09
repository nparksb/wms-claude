---
title: "SBDEV-3244 (V2): Concurrent recalculateForItem — stale @Version at the pessimistic lock read"
ticket: "SBDEV-3244"
ticket_url: "https://app.clickup.com/t/868m240ba"
type: "bug"
priority: "high"
status: "pending approval"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-09"
updated: "2026-09-09"
db_verified: true
related:
  - "../../../3-Resources/design/wms2-replenishment-design.md"
  - "../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map.md"
  - "https://app.clickup.com/t/868m3fzwv"
tags: [plan, sbdev-3244, replenishment, pessimistic-lock, optimistic-lock, transaction-boundary, tdd-gate]
---

# SBDEV-3244 (V2): Concurrent `recalculateForItem` — stale `@Version` at the pessimistic lock read

**Ticket:** [SBDEV-3244](https://app.clickup.com/t/868m240ba) | **wms2/wms2-api** | v2 (Java 21 / Spring Boot 3.5.9, Hibernate ORM 6.6.39) | Bug (concurrency) | **Tier T3** — data integrity + lock topology + root cause initially misattributed.
**Baseline:** code evidence on `.claude/worktrees/wms2-api/SBDEV-3244-probe`, detached at `origin/develop` @ `84083464`; DB evidence re-measured 2026-09-09 (§2.4).

> **⭐ SCOPE — A-narrow (Nam, 2026-09-09; §12 Q1 resolved).** This plan ships **F1–F5 and F7–F9 only**. F6, F10 and F11 are **dropped** and the whole wide-scope programme is handed to **[SBDEV-3286](https://app.clickup.com/t/868m3fzwv)** — *"Pre-lock entity load makes findByIdForUpdate throw StaleObjectStateException — 15 sites across picking, BOL, parcel monitor and receiving"*.
>
> **What this plan therefore does and does not fix.** It fixes the **ten non-transactional `triggerReplenishmentMaintenance` callers and the cron** — every path on which `recalculateForItem` opens its own transaction, which is where the committed integration test reproduces. It does **not** fix the two `@Transactional` callers, `StockunitService.setLockOnHold` (operator *"Set On Hold"*) and `FixLocationAssignmentService.move`: their own pre-loads sit in the transaction `recalculateForItem` joins, so on those two paths the throw **relocates** to `ensureValidSource` instead of disappearing (§2.3). **Do not close this plan believing "Set On Hold" is fixed** — it is not, and it is SBDEV-3286's.

> **Citation form.** File + a distinctive quoted snippet, never a line number. Earlier revisions broke this rule three times, and two of the three ranges volunteered *as corrections* were themselves wrong. Do not reintroduce line numbers.

**Decision record:** `scratchpad/dr-3244.md`. The two principles that select Option A: **(P1)** the first touch of an entity you will write under a lock must *be* the locking finder — Hibernate version-checks only on a lock *upgrade*; **(P2)** carry ids across a lock boundary, never entities — the check keys on the persistence-context entry **by identity**, so a detached copy or an id fixes nothing while the pre-lock load remains. Options B/C/D are rejected there; all three review lanes audited the rejections and they hold, with M-4's correction at §12 Q4.

---

## 0. Affected Sites

The lock-site sweep (`scratchpad/sites-3244.md` §3) enumerated the `@Lock(PESSIMISTIC_WRITE)` call sites in `src/main` and found the in-scope HITs below. Blind spots: matches by method *name*, so a call through a variable or reflection is missed; a line with two calls counts once; and — the one that actually bit (§2.3) — **a lock-site sweep cannot see a pre-load living in a caller that joins the transaction.**

### 0.1 The precondition that decides every verdict

`spring.jpa.open-in-view=false` in `src/main/resources/application.properties` and in both integration profiles (`application-integration.properties`, `application-postgres-integration.properties`); `src/test/resources/application.properties` carries no such key. Corroborated by six in-source javadocs reasoning from it and railed by `unit/config/SdrEvictionPostCommitAssumptionUnitTest` (*"AC-27 spring.jpa.open-in-view must remain false"*). So there is no request-scoped persistence context and an entity returned outside a transaction is detached. Controllers open none — of the 12 `@Transactional` grep hits under `controller/`, 9 are javadoc `{@code @Transactional}` mentions and the only real ones are three in `PutawayConfigController`; `schedulejob/` has zero. The naive count is the wrong instrument.

**The deciding question at every site is therefore "was the pre-load inside the *same* transaction?", never "was it earlier in program order?" — and "the same transaction" includes one a caller opened.** Blind spots: derived from the property file plus javadocs, not a running context; cannot see a programmatic `TransactionTemplate` (`MobilePickingService.claimTx` is one) nor inherited `@Transactional`.

### 0.2 In scope

| # | Site | Locating snippet | Verdict | Fix |
|---|---|---|---|---|
| 1 | `service/ReplenishmentOrderMaintenanceService.java` → `recalculateOrder` | `// Re-fetch with pessimistic write lock to serialize concurrent writers on the same row` / `order = replenishorderRepository.findByIdForUpdate(order.getId()).orElse(null);` | **HIT** on the `recalculateForItem` entry, IMMUNE-DETACHED on the cron entry | F1 |
| 2 | same file → `buildRecalcContext` | `StreamSupport.stream(stockunitRepository.findAllById(stockunitIds).spliterator(), false)` | **HIT** (feeds site 5) | F2 |
| 3 | same file → `ensureValidSource` | `Optional<Stockunit> sourceOpt = ctx.getStock(order.getStockunitId());` + `RecalcContext.getStock`'s fallback `return s != null ? Optional.of(s) : stockunitRepository.findById(id);` | **HIT** (feeds site 5; the fallback is *unconditional* — both entry paths) | F2 + F3 |
| 4 | same file → `redirectSource` | `Stockunit targetStock = stockunitRepository.findById(candidate.stockUnitId).orElse(null);` | **HIT** — READ load and lock re-read in one method body, one tx | F4 |
| 5 | `service/StockunitBusinessService.java` → `changeReservedAmount` | `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())` / `entityManager.refresh(stockUnit);` | **HIT — the next throw point** | closed *by* F2–F4; file not modified (§4.6) |
| 6 | same file as 1 → `reassignOrCancelForMovedStockUnit`, **and** `service/ReplenishmentOrderSourceSyncService.java` → `syncForMovedStockUnit` | `Replenishorder probe = replenishorderRepository.findByStateLessThanAndStockunitId(…)` then `findByIdForUpdate(probe.getId()) // AC8: serialize w/ cron`; the sync service repeats the shape (class javadoc *"It deliberately joins the caller's tenant transaction"*) | **HIT** ×2 — both self-contained, one tx | F5 |
| 7 | `service/StockunitService.java` **and** `service/FixLocationAssignmentService.java` | `// That premise is FALSE at 8 of the 11 call sites …` — identical in both (`git grep -ln 'That premise is FALSE' -- src/main` returns exactly these two; blind spot: that exact phrase only) | comment, factually wrong | F7 |

### 0.3 Handed to SBDEV-3286 (each by name — do not re-derive here)

Every residual below is a *real* HIT that A-narrow does not close. Mechanism in one line each; the detail lives on the ticket.

1. **The two `@Transactional` caller pre-loads.** `FixLocationAssignmentService.move`'s `for (Replenishorder replenishOrder : replenishorderService.getActive(fixedLocationAssignment.getItemdataId(), null))` (uses `getState()`/`getNumber()` only) and both `move`'s and `StockunitService.setLockOnHold`'s `List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(...)` size guards: same-transaction READ entries, so F3's locking read stays an *upgrade* and the throw relocates to `ensureValidSource` (§2.3).
2. **`PickLineRealignmentService.collectTree`** — `for (Stockunit su : stockunitRepository.findByUnitloadId(unitloadId)) { stockUnitIds.add(su.getId()); }`: whole entities loaded only to read `su.getId()`, fired unconditionally on **every** BLOCK_REALIGN move and therefore on both of the paths in item 1. The earliest producer of all, and the single highest-value line in 3286.
3. **The `createFixedLocationAssignment` producer family** — `FixLocationAssignmentService.createFixedLocationAssignment` carries no `@Transactional` and its last statement before `return` is `triggerReplenishmentMaintenance(itemData.getId());`. Three of its six call sites are `@Transactional` *and* pre-load the entities the recalc will lock (§3.1).
4. **`StockunitService.transferStock`'s `CODE_MANUAL_TRANSFER` branch** — `List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(suUnitLoad.getId());` for a `stockUnitList.size() == 1` guard immediately before `transferUnitLoadToLocation(suUnitLoad, destinationLocation, false, WmsConstants.CODE_MANUAL_TRANSFER, null, comment)`. A **fourth** BLOCK_REALIGN producer: 3286's F6-equivalent cannot ship until it is converted.
5. **`transferUnitLoadToLocation`'s own FLA-branch `findByUnitloadId`** — reads only `stockUnit.getItemdataId()`, so it is the same mechanical conversion; §2.3's closing paragraph explains why the guard argument that used to exclude it does not hold.
6. **R9 — `setLockOnHold`'s detached-`merge` version check.** The controller hands it a detached `Stockunit` and the method ends `stockunitRepository.save(stockUnit)`; a wrapper `@Version` routes `save` to `merge`, and `DefaultMergeEventListener` throws `StaleObjectStateException` when the detached version differs from the loaded target. A different mechanism from this plan's, and the reason **AC-2 case (a) for `setLockOnHold` is unsatisfiable in every scope** (§8.1).
7. **F6 itself** — `UnitloadBusinessService.processTransfer`'s BLOCK_REALIGN loop. Dropped here for the reason in §4.10; it belongs to 3286 behind items 2–5.

**Also proposed on the SBDEV-3244 ticket, not filed:** the remaining lock-site HITs and UNDETERMINED sites, ranked with blast radius and cost in `scratchpad/analysis-3244.md` §12.4 — headed by `PickingorderBusinessService.finishPickingOrder`/`.confirmPick` (hottest operator path), `ParcelMonitorViewService.palletise` (cheapest) and `StockunitBusinessService.transferStockToUnitLoad` (6 locks, 12 callers, highest cost); plus `PickLineRealignmentService.lockOwningPickingorders`, which calls `findByIdForUpdate` and **discards the return value**, five in-source comments promising a freshness the provider does not deliver, and the native twin `getStockUnitsByItemDataIdForUpdate` (`nativeQuery = true` — cannot throw, silently discards the freshly-locked values).

Also out: the cron's **stale-read** exposure (detached `Stockunit`s in `ctx`, arithmetic on that snapshot). Not a lock failure; F2 removes it as a side effect — a bonus, not a claim.

---

## 1. Problem Statement

Two concurrent `recalculateForItem(itemDataId)` calls for one item: the winner completes, the loser throws `UnexpectedRollbackException: Transaction silently rolled back because it has been marked as rollback-only` to its caller. Reproduced deterministically by the committed integration test (2026-09-09: `e1=NULL`, `e2=UnexpectedRollbackException`, `requested=84.0000 reserved=84.0000`, with `WARN … Failed to recalculate replenishOrder=RO-SBDEV2234 : Row was updated or deleted by another transaction … [Replenishorder#9956]`).

The SBDEV-2234 pair invariant **holds** (84/84) and the loser writes nothing. **The damage is entirely to the caller** — and at least two of the eleven callers are `@Transactional`, so for them the damage is their own committed work being discarded: `StockunitService.setLockOnHold` (the ON_HOLD write, the stock-change message and the unit-load relocation are all rolled back) and `FixLocationAssignmentService.move` (the move is rolled back).

⚠ **Those are exactly the two paths A-narrow does not fix** (§0's scope box, §2.3, §8.1's AC-2 note). This plan removes the defect on every path where `recalculateForItem` opens its own transaction — the cron and the ten unannotated callers, including the one the integration test drives; the two operator actions above stay exposed until SBDEV-3286 lands, and §9 item 2 requires the implementation report to say so.

*Derivation of "at least two of eleven":* every `triggerReplenishmentMaintenance(` call site mapped to its enclosing method by walking back to the nearest 4-space signature and reading the annotation block above it; reproduced independently by the critic lane's Python walker and re-run this pass (7 sites in `FixLocationAssignmentService`, 4 in `StockunitService` = 11, matching the in-source comment's own figure); positive control `setLockOnHold` reports TX=YES. Two blind spots, both material — a meta-annotation would be missed, and **an unannotated enclosing method reached from a transactional caller is still inside a transaction** (§3.1 names the family that exploits this), which is why the predicate the code obeys is the runtime `isActualTransactionActive()` (F7). Read it as a floor, not a count.

---

## 2. Root Cause Analysis

### 2.1 The mechanism

Authoritative stack (DEBUG run): `ObjectOptimisticLockingFailureException … [Replenishorder#9956]` → `HibernateJpaDialect.convertHibernateAccessException` → `$Proxy297.findByIdForUpdate` → `recalculateOrder` → `recalculateForItem`, landing on the **first statement** of `recalculateOrder`. Verified against the Hibernate ORM 6.6.39 and Spring 6.2.15 `-sources.jar` in `~/.m2`:

`recalculateForItem` is `@Transactional` and its first act is a plain JPQL select **before any lock** (`findByStateAndItemdataId(PROCESSABLE, itemDataId)`), so the order is managed at `EntityEntry` lock mode `READ`. `recalculateOrder` then re-reads the same id via `findByIdForUpdate` — `@Lock(PESSIMISTIC_WRITE)` over a **full-entity** `@Query`, so the version column is in the result set and `versionAssembler != null`. `EntityInitializerImpl.upgradeLockMode` finds `entry.getLockMode().lessThan(data.lockMode)` true (READ=1 < PESSIMISTIC_WRITE=5) and, per its own comment *"we only check the version when _upgrading_ lock modes"*, runs `checkVersion`. `SELECT … FOR UPDATE` blocks until the winner commits, then (Postgres `EvalPlanQual` follow-update) returns the latest committed row at `v+1` while the entry still holds `v` → `StaleObjectStateException`, thrown from **inside** `findByIdForUpdate`, with the row lock taken and nothing written. `ExceptionConverterImpl.convert` wraps it and calls **`markForRollbackOnly()`**; `JpaTransactionManager.isRollbackOnly()` reads that flag back, so `processCommit` throws `UnexpectedRollbackException`. SBDEV-3250's swallow predicate `e instanceof DataAccessException dae && hasSqlCause(dae)` does not match — no `SQLException` in the chain — so the exception also takes the `LOG.warn` branch, which is why the WARN and the commit failure appear together.

⚠ **The message does not discriminate.** Nine Hibernate sites throw that identical string, including the flush path (`ModelMutationHelper`). Only the stack trace separates a lock-read failure from a flush failure. Do not accept the message alone as evidence in review.

### 2.2 What this invalidates — including in-repo test prose

| Claim | Where | Reality |
|---|---|---|
| the loser calls `changeReservedAmount` with a stale `Stockunit` (step 4), and a cross-bean `@Transactional(rollbackFor=…)` marks the tx rollback-only (step 5) | ticket; the integration test's own comment | **`changeReservedAmount` is never entered** — nothing after `recalculateOrder`'s first statement runs — and **no proxy participates**: Hibernate's exception converter sets the flag. |
| the loser "recomputes a DIFFERENT desiredAmount" | same comment | **False.** `sumRequestedAmountForOpenOrders` carries `AND (:excludedId IS NULL OR ro.id <> :excludedId)` and is called with `order.getId()`, so the winner's own order is excluded (§4.5). |
| AC-3: re-read the **Stockunit** after the order lock | ticket | Wrong entity, and **already implemented** — `changeReservedAmount` already does `findByIdForUpdate` + `refresh`. **AC-3 as written is green while the bug is live**; hence AC-3′. |

### 2.3 ⚠ The pivotal constraint — the invariant is **transaction**-scoped, and this subsystem does not own its transaction

`buildRecalcContext` bulk-loads the **Stockunits** into the same persistence context in the same transaction, so they too are managed at READ; `changeReservedAmount`'s first statement is the identical READ→PESSIMISTIC_WRITE upgrade on the hottest entity in the product. The `Replenishorder` throws first only because it is textually earlier. Confirmed by two independent instruments.

**Four routes to the Stockunit hop inside the service** — a fix aimed only at the prefetch closes one:

1. the `buildRecalcContext` prefetch — path-conditional (managed only on the `recalculateForItem` entry);
2. `RecalcContext.getStock`'s fallback `stockunitRepository.findById(id)` — **unconditional**, inside `recalculateOrder`'s own tx on both entries, for any order whose `stockunitId` missed the map;
3. `ensureValidSource`'s post-redirect `return stockunitRepository.findById(order.getStockunitId())`;
4. `redirectSource`'s `Stockunit targetStock = stockunitRepository.findById(candidate.stockUnitId)`.

**A fifth class of route lives outside the service** — found independently by two review lanes from different evidence, and the reason A-narrow exists. `recalculateForItem` is `@Transactional(REQUIRED)`: from a transactional caller it **joins** that transaction and shares its persistence context. Inside the two host transactions §1 names:

| Pre-load | Uses it for | Effect |
|---|---|---|
| `move` → `for (Replenishorder replenishOrder : replenishorderService.getActive(fixedLocationAssignment.getItemdataId(), null))`. `getActive` is `@Transactional(readOnly = true)` with default `REQUIRED`, so it **joins** `move`'s tx, and its `itemId != null` branch returns the full-entity `findByStateLessThanAndItemdataId(FINISHED, itemId)` | `getState()`, `getNumber()` | `state < FINISHED` is a superset of `PROCESSABLE`, so every row F1's `findIdsByStateAndItemdataId` returns is already managed at READ. **F1 changes nothing on this path.** |
| `setLockOnHold` → `List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(stockUnit.getUnitloadId());` | a `size() > 1` guard | Stockunit managed at READ before the recalc |
| `move` → `List<Stockunit> stockunitList = stockunitRepository.findByUnitloadId(fixedLocationAssignment.getAssignedunitloadId());` | two size guards + a trailing `recordRelocation(su, …)` loop | same |
| `PickLineRealignmentService.collectTree` → `for (Stockunit su : stockunitRepository.findByUnitloadId(unitloadId)) { stockUnitIds.add(su.getId()); }`, reached from `transferUnitLoadToLocation`'s `collectStockUnitIdsForUnitloadTree(unitload)` pre-walk | **`su.getId()` only** | Fires **unconditionally on every BLOCK_REALIGN move**, hence on both of these paths (`PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES` contains `CODE_MOVE_FIX_ASSIGNMENT` and `CODE_ON_HOLD`, read from its `Set.of(...)`). Earliest of the four; **no review lane named it before round 2.** |

**Consequence — stated as the scope limit, not as a fix:** F1–F4 make the locking read a first touch **only when `recalculateForItem` opens its own transaction.** On the two `@Transactional` caller paths it stays an upgrade, so the throw **relocates** to `ensureValidSource` rather than disappearing. That is the residual A-narrow accepts and SBDEV-3286 closes (§0.3 items 1–2). And **passing a detached copy or an id into `changeReservedAmount` does not help**: the version check keys on the persistence-context entry **by identity**, not on the reference handed over.

**Withdrawn: the guard argument that used to exclude `transferUnitLoadToLocation`'s own `List<Stockunit> stockunitList = stockunitRepository.findByUnitloadId(unitload.getId());`.** The earlier revision excluded it because it sits inside `if (fixLocationAssignment != null)` and *"`move` rejects a destination that already carries an FLA and `setLockOnHold` rejects a flowbin"*. Half of that holds and half does not. For `move` it is sound: `if (fixLocationAssignmentRepository.findByAssignedlocationId(destination.getId()).isPresent()) { throw new BusinessException("Can't move fix assignment. Destination has already a fixed assignment!"); }` tests the same predicate on the same location id, so the branch cannot be entered. For `setLockOnHold` it does **not**: the cited guard is `if (locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)) { throw new BusinessException("Can not set lock. Location is a flowbin! Move stock first!"); }` — a **location-type** test, while the branch tests a **fixed assignment** on a different table, against the stock unit's own live storage location. The conclusion is nonetheless true **as a measured data property, not a code guarantee**: every FLA sits on a flowbin — `wms2-hydra` (prd) `fix_location_assignment ⋈ location ⋈ location_type` grouped by `sltname` → `flowbin: 132` and nothing else; `nywh-hydra-uat` → `flowbin: 158`, nothing else. *Positive control* (a single-bucket result is worthless without one): the same join over `location_type ⋈ location` on prd returns eight distinct type names — flowbin 179, overstock pallet 47, overstock box 14, cases and pallets 13, NoRestriction 11, totes 2, packages 1, System 0 — so the instrument can see non-flowbin locations. The invariant is **not enforced in code** (`createFixedLocationAssignment(Location storageLocation, Itemdata itemData)` has no location-type check, and `MobileReplenishService`'s `SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS` path exists precisely to allow non-flowbin destinations). Since A-narrow does not modify `UnitloadBusinessService` at all, none of this bears on this plan's diff — it is recorded so SBDEV-3286 does not inherit the false derivation (§0.3 item 5).

### 2.4 DB verification (floor item 1) — re-measured 2026-09-09

**Hydra prd (`wms2-hydra`, the only v2 prd client): `replenishorder` has NEVER held a row** — `count(*) = 0`, `max(version) = -1`, so `findByStateAndItemdataId` returns empty, the loop body never runs, and there is **zero live production exposure today**. *Positive control*, same DB and query: 557 `stockunit`, 132 active `fix_location_assignment`. The second concurrent actor is live: `REPLENISHMENT_TIMER_ACTIVATED = true`, `HOUR = *`, `MINUTE = *`, and `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` resolved to ~13–16 s before the query on two independent runs. Exposure begins with the first `PROCESSABLE` order — latent, not theoretical.

**Hydra UAT (`nywh-hydra-uat`).** Measured: 124 replenishorders, 121 with `version > 0`, `max(version) = 27`, of which **8 are `PROCESSABLE` with 8 distinct `stockunit_id`s** and **0 carry `manuallyoverridepriority`**; `max(created) = 2026-07-01`, so the population is static. The load-bearing form is qualitative: **UAT carries live `PROCESSABLE` replenishorders, so §8.7's manual plan is executable there and the versioned-update path is exercised on real data.** Re-derive any number at test time.

⚠ **Cause of an earlier error in this plan's own history, so nobody repeats it:** `WmsConstants.State.PROCESSABLE = 300`, not 100 (`service/WmsConstants.java`, `public static final int PROCESSABLE = 300;` — the class is in package `service`, not `util`). States present on UAT are 300/700/800; a `state = 100` filter returns 0 on a populated table and reads exactly like a true zero. Schema notes: `los_sysprop` uses `syskey`/`sysvalue`, `stockunit` uses `entity_lock`.

---

## 3. Architecture Overview

### 3.1 The shape of the fix, and the exact scope of the invariant

```
recalculateForItem  ❌ findByStateAndItemdataId → List<Replenishorder> MANAGED @ READ(1)  ← the defect
                    ✅ findIdsByStateAndItemdataId → List<Long>          nothing enters the PC
  buildRecalcContext ❌ stockunitRepository.findAllById(...)  READ(1)   ← 2nd throw point
                     ✅ scalar id hops: order → itemdata → stockunit → unitload
  recalculateOrder(id, ctx)  — plain this. call, REQUIRED, joins this tx
    findByIdForUpdate(id)  ❌ READ(1)→PESSIMISTIC_WRITE(5) UPGRADE → checkVersion → THROW
                           ✅ first touch → fresh EntityEntry → no comparison possible
    ensureValidSource   ✅ stockunitRepository.findByIdForUpdate(order.getStockunitId())
    changeReservedAmount → findByIdForUpdate: PW(5) NOT lessThan PW(5) → checkVersion SKIPPED
```

**The invariant, stated at the scope this plan actually delivers:** *within the transaction **`recalculateForItem` opens itself**, the first touch of any entity this subsystem will write under a lock is the locking finder itself.*

⚠ **It does NOT extend to a transaction opened by a caller, and the earlier revision's unqualified wording was false.** Five producer families put a `Replenishorder` or `Stockunit` into a joined persistence context at READ before the recalc runs; A-narrow converts none of them. The fifth — and the one that proves the unqualified claim cannot be repaired by fixing "the two AC-2 callers" either — is the **`createFixedLocationAssignment` family**: that method carries no `@Transactional`, its last statement before `return` is `triggerReplenishmentMaintenance(itemData.getId());`, and it has **six call sites across four files**. Three of the six are `@Transactional` *and* pre-load:

| Call site | Enclosing method's annotation | Same-transaction pre-load before the call |
|---|---|---|
| `service/mobile/MobileReplenishService.java` → `finishReplenishmentOrderInternal`, reached by a plain `this.` call from `@Transactional finishReplenishmentOrder` | on `finishReplenishmentOrder` | `Replenishorder replenishOrder = readReplenishOrder(mobileOrder);` **and** `Optional<Stockunit> sourceStockOpt = stockunitRepository.findById(mobileOrder.getSourceStockId());` — literally a replenishment order and its source stock unit |
| `service/mobile/MobilePutAwayService.java` → `storeBoxOnLocation` | `@Transactional(value = "tenantTransactionManager", …)` | `Stockunit sourceStockUnit = stockunitRepository.findByUnitloadId(unitLoad.getId()).get(0);`, four lines earlier |
| `service/mobile/MobileMoveUnitloadService.java` → `scanDestination` | `@Transactional(value = "tenantTransactionManager", …)` | three `stockunitRepository.findByUnitloadId(sourceUnitLoad.getId())` loads earlier in the method |

The other three are excluded, each for a named reason: `StockunitService.transferStock` (`@Transactional`) reaches it only on the flowbin branch, which loads no `Stockunit` or `Replenishorder` entity beforehand — `stockUnit` is the method parameter; `MobileReplenishService.checkDestination` (`@Transactional`) does load a `Replenishorder` via `readReplenishOrder`, but **after** the `createFixedLocationAssignment` call, not before; and `MobileReplenishService.assignDestinationForMultiUnitLoads` is reached only from `fulfillMultipleUnitLoads`, which carries no `@Transactional` (its own javadoc: *"deliberately NOT `@Transactional`"*).

*Method / blind spots:* `git grep -n createFixedLocationAssignment -- src/main` for the six sites (three further hits in that grep are javadoc prose), then a Python enclosing-signature walker for each site's method and annotation block, plus a ranged read of each method to place the pre-load relative to the call. The walker reads the annotation lines immediately above the signature, so a meta-annotation is missed, and it cannot see a transaction opened by a `TransactionTemplate`. Positive control: the same walker reports `setLockOnHold` and `move` as the only two annotated of the eleven `triggerReplenishmentMaintenance` sites, reproducing §1's figure.

Handed to SBDEV-3286 as §0.3 item 3. **Nothing in this plan's acceptance criteria may assert the caller-scoped form of the invariant** — see AC-3′ (§8.1) and §9 item 3.

### 3.2 Key files

`service/ReplenishmentOrderMaintenanceService.java` (subject: both entry points, `RecalcContext`, `ensureValidSource`, `redirectSource`, sibling site 6) · `service/ReplenishmentOrderSourceSyncService.java` (sibling site 7) · `service/StockunitBusinessService.java` (site 5 — **read-only for this plan**, §4.6) · `service/StockunitService.java` and `service/FixLocationAssignmentService.java` (F7 comment only) · `repo/jpa/ReplenishorderRepository.java` and `repo/jpa/StockunitRepository.java` (new scalar projections — both SDR-exported classes, §5.1) · `landlord/config/LockTimeoutHibernateJpaDialect.java` (read-only; the bound R2 relies on). Follow the project `CLAUDE.md` file-size heuristic — grep + ranged read — for all of them.

---

## 4. Fix Design

House rules per `v2/wms2-api/CLAUDE.md` apply throughout and are not restated; §7 records conformance.

### 4.1 F1 — both entry points fetch **ids**; `recalculateOrder` takes a `Long`

`recalculateForItem` and `recalculateOpenOrders` fetch `List<Long>`; `recalculateOrder(Long orderId, RecalcContext ctx)` null-guards the id and its **first statement** is `replenishorderRepository.findByIdForUpdate(orderId)`. The state guard (`state == PROCESSABLE`) and the `manuallyoverridepriority` guard both move **under** the lock. Add an in-code comment stating the first-touch rule and why a pre-lock load breaks it — the wording belongs in the diff, not here, so the two cannot silently diverge. New projections, in the scalar-JPQL idiom already present in this repository (`findItemdataIdsByIdIn`), each `@RestResource(exported = false)`:

```java
@Query("SELECT r.id FROM Replenishorder r WHERE r.state = :state")
List<Long> findIdsByState(@Param("state") Integer state);

@Query("SELECT r.id FROM Replenishorder r WHERE r.state = :state AND r.itemdataId = :itemdataId")
List<Long> findIdsByStateAndItemdataId(@Param("state") Integer state, @Param("itemdataId") Long itemdataId);
```

`findByState` and `findByStateAndItemdataId` stay — `findByState` is SDR-exported by an explicit `@RestResource(path = …)` and removing it is an API contract change.

**The WARN lines lose the order number — decided here, not in the diff.** Both catch blocks log `LOG.warn("Failed to recalculate replenishOrder={} : {}", order.getNumber(), e.getMessage());` (the sweep's catch and `recalculateForItem`'s SBDEV-3250 catch; `git grep -n "Failed to recalculate replenishOrder" -- src/main` finds exactly these two). After F1 the loop variable is a `Long`, so **log the id**: `LOG.warn("Failed to recalculate replenishOrder id={} : {}", orderId, e.getMessage());`. Do **not** re-fetch the number to preserve the string — a second read of the row inside a catch block on a rollback-marked transaction is the wrong trade. Consequence to record: the evidence string §2.1 and §8.5 quote (`replenishOrder=RO-SBDEV2234`) changes shape, so any log grep or runbook keyed on the number must expect `id=`.

Two further deliberate consequences. **(a)** The `manuallyoverridepriority` guard now reads freshly locked state; the cost is one row lock on orders that are then skipped (R4). The architect lane proposed projecting the flag (`List<Object[]>` of `id, manuallyoverridepriority`) to avoid that lock — **rejected**, because it re-introduces a pre-lock read of a business field that the next reader cannot distinguish from the pattern this plan exists to remove; R4 is Low and applies to zero rows in the measured UAT population. **(b)** The cron becomes *structurally* immune rather than accidentally immune: today `recalculateOpenOrders` is safe only because **neither of its two callers opens a transaction** — `schedulejob/ReplenishOrderJob.java` (`replenishmentOrderMaintenanceService.recalculateOpenOrders(false);`) and `service/mobile/MobileReplenishService.java`'s `fulfillMultipleUnitLoads`, whose own javadoc says *"deliberately NOT `@Transactional` … then — only after that transaction has committed and released every pessimistic lock — best-effort runs … `recalculateOpenOrders(true)`"*. Adding `@Transactional` above either reproduces the defect identically; the mobile one is the likelier future refactor. AC-6a pins the new property. (Both callers found by `git grep -n recalculateOpenOrders -- src/main`, which returns two call lines plus javadoc mentions; §0.1's controller/schedulejob-only instrument would have missed the mobile caller.)

### 4.2 F2 — `RecalcContext` carries no `Stockunit`

`stocksById` and `getStock` are removed. `buildRecalcContext(List<Long> orderIds)` walks ids only — order ids → itemdata ids (existing `findItemdataIdsByIdIn`) → FLAs → stockunit ids → unitload ids → `Unitload`s — so neither a `Replenishorder` nor a `Stockunit` enters the persistence context. The bulk `Stockunit` fetch is *replaced* by a scalar `unitloadId` projection, not deleted: the `Unitload` prefetch `isSourceUsable` depends on is preserved, and the prefetch stays O(1) in the order count. `findByItemdataIdIn` takes a `Collection<Long>` and `findItemdataIdsByIdIn` is `SELECT DISTINCT`, so the `List` goes in directly — no `Set` wrapper.

```java
// ReplenishorderRepository
@Query("SELECT DISTINCT r.stockunitId FROM Replenishorder r WHERE r.id IN :ids AND r.stockunitId IS NOT NULL")
List<Long> findStockunitIdsByIdIn(@Param("ids") Collection<Long> ids);
// StockunitRepository
@Query("SELECT DISTINCT s.unitloadId FROM Stockunit s WHERE s.id IN :ids AND s.unitloadId IS NOT NULL")
List<Long> findUnitloadIdsByIdIn(@Param("ids") Collection<Long> ids);
```

`FixLocationAssignment`, `Unitload` and `Location` may stay managed at READ: nothing on the `recalculateOrder` path locks any of them, so no upgrade — and hence no `checkVersion` — can occur. Instrument: the lock-site sweep, with §0's blind spots.

### 4.3 F3 — `ensureValidSource` loads the source **under the lock**

```java
Stockunit source = order.getStockunitId() == null ? null
    : stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null);
if (isSourceUsable(order, source, ctx)) { return source; }
if (redirectSource(order, source)) {
    return stockunitRepository.findById(order.getStockunitId()).orElse(null);   // see note
}
cancelOrder(order, source, WmsConstants.CODE_REPLENISHMENT_CANCELLED);
return null;
```

This is both the version-safety rule and the AC-5 requirement: `desiredAmount` is computed from this row's `amount`/`reservedamount`, so reading it before the order lock was granted converges on pre-winner numbers. *Note on the retained `findById`:* after a successful `redirectSource`, `order.getStockunitId()` is `candidate.stockUnitId`, which F4 has just loaded at `PESSIMISTIC_WRITE`, so the `findById` hits the persistence context and returns that locked instance — no upgrade; `changeReservedAmount`'s `entityManager.refresh` runs in between and does **not** break this (§4.6). *Behaviour change, named:* today a null `stockunitId` reaches `findById(null)` and throws `IllegalArgumentException`; after F3 it yields `null`, which `isSourceUsable` (false) and `redirectSource` (`currentSource == null ? null : …`) already guard. Safe, arguably better, but a change.

### 4.4 F4 — `redirectSource`'s target loaded under the lock

`findById(candidate.stockUnitId)` → `findByIdForUpdate(candidate.stockUnitId)`. The `preferredAreaId` `unitloadRepository.findById(...)` → `locationRepository.findById(...)` chain is left alone: neither entity is locked on this path. **Lock-ordering note:** F3 + F4 flip the *relative* order of two stock-unit locks on the redirect path from `target → current` to `current → target`. Both shapes are unordered with respect to id, so the ABBA pair already exists today; no ordering edge is added and the sequence becomes consistent by role. Recorded as R2.

### 4.5 What the loser does after the fix (the AC-5 contract, computed)

Fixture after the winner commits: source `amount = 100000`, `reservedamount = 84`, order `requestedamount = 84`. The loser reads `requestedamount = 84` (first touch, under the lock, after the winner committed); `getInboundReplenish` is unchanged (the current order is excluded); `shortage = 84` (destination totals come from native queries, which force a session flush, so they are current); `getAvailableIncludingReservation = 100000 − 84 + 84 = 100000` from the **locked** source row; `desiredAmount = min(84, 100000) = 84`; and `updateRequestedAmount` takes its **early return** (`desiredAmount.compareTo(currentRequested) == 0`).

⚠ **So in this fixture a correctly-converging loser writes nothing at all**, and converge is *observationally identical* to skip-without-recomputing — one `CODE_REPLENISHMENT` stockrecord and `requestedamount = 84` either way. AC-5 must therefore be tested against a **different** fixture (§8.3). Not a hypothetical hazard on this suite: the existing test's own javadoc records *"Deleting `replenishorderRepository.findByIdForUpdate` at the top of `recalculateOrder` left it GREEN 3 of 3."*

### 4.6 Why `StockunitBusinessService` is **not** modified

Once F2–F4 guarantee the stock unit's first touch in this transaction is a locking finder, the entry is at `PESSIMISTIC_WRITE(5)` when `changeReservedAmount` runs its own `findByIdForUpdate`; `PESSIMISTIC_WRITE.lessThan(PESSIMISTIC_WRITE)` is **false**, so `checkVersion` is never reached and the site is CONDITION-2-EXEMPT by construction. **Both review lanes verified this independently against `EntityInitializerImpl.upgradeLockMode` in the 6.6.39 sources — it is the load-bearing scope claim and does not need re-litigating.**

One step an earlier revision omitted, without which the proof looks wrong: the next statement is `entityManager.refresh(stockUnit)`, and a refresh **destroys and rebuilds the `EntityEntry`**. The exemption survives only because `DefaultRefreshEventListener.doRefresh` restores it — *"prepare to reset the entry lock-mode to the previous lock mode after the refresh completes"*, then `persistenceContext.getEntry(result).setLockMode(postRefreshLockMode)`. Anyone deleting that "redundant" refresh must re-check this. (P4 would normally delete it after a shape fix, as plan 260713 Fix B did; settled decision 3 scopes this file out, so it stays.) ⚠ Scoped to the transaction `recalculateForItem` opens: on the two `@Transactional` caller paths the caller's pre-load already put the stock unit in at READ, F3's finder is the upgrade, and `changeReservedAmount` is never reached (§2.3).

### 4.7 F5 — the two sibling `Replenishorder` probes

`reassignOrCancelForMovedStockUnit` and `syncForMovedStockUnit` both read the probe as an entity and lock the same id a few lines later, inside the move's transaction. Replace the probe with an id — `findIdByStateLessThanAndStockunitId(...)` then `findByIdForUpdate(probeId).orElseThrow(...)`:

```java
@Query("SELECT r.id FROM Replenishorder r WHERE r.state < :state AND r.stockunitId = :stockunitId")
Optional<Long> findIdByStateLessThanAndStockunitId(@Param("state") Integer state, @Param("stockunitId") Long stockunitId);
```

`findByStateLessThanAndStockunitId` is SDR-exported and used by `ReplenishorderService`, so it stays. ⚠ The existing query is a *derived* method; the new `@Query` must reproduce it exactly — strict `<`, not `<=`. `Optional<Long>` on a multi-match predicate throws `IncorrectResultSizeDataAccessException` exactly as `Optional<Replenishorder>` does today: behaviour preserved, not improved (§12 Q2).

### 4.8 F7 — correct the false enumeration, in **both** files

The comment (*"…only setLockOnHold, setLockDamaged and FixLocationAssignmentService.move are @Transactional"*) is wrong on the count, wrong on `setLockDamaged` (it carries no `@Transactional`), and self-contradictory — it uses `setLockDamaged` as its example of a site where rethrowing was *harmful*, which requires it to be non-transactional. Per the house rule that prose enumerations rot, replace the list with the **rule**, not a corrected list: `isActualTransactionActive()` decides at runtime — rethrow when this call joined a caller's transaction, swallow when `recalculateForItem` opened its own; do not encode a count. The wording goes in the code, in **both** `StockunitService` and `FixLocationAssignmentService`; fixing one leaves the other asserting the disproved claim next to the same predicate.

### 4.9 F8 / F9 — the WARNING block and the integration test's narrative

**F8.** The WARNING above the `this.recalculateOrder` call is **load-bearing**: the plain `this.` call keeps the recalculation inside `setLockOnHold`'s transaction so it reads the flushed `ON_HOLD` state (the in-source comment states the rule directly — *"MUST remain the LAST statement before return … Moving it above the save would let recalc see NOT_LOCKED and re-grab the stock — the SBDEV-2033 re-reservation bug"*). Keep it and append a paragraph recording that SBDEV-3244's `UnexpectedRollbackException` came from Hibernate's own converter, not a Spring proxy, and is orthogonal to the self-vs-`this` decision.

⚠ **Two false derivations to retire while touching this block, both about `transferStock`.** (i) `analysis-3244.md` §12.3's *"there is no `transferStock` method in `src/main`"* is wrong in that blanket form: `StockunitBusinessService` has no `transferStock` (only two `transferStockToUnitLoad` overloads), but `StockunitService.transferStock` **does** exist and **is** `@Transactional(value = "tenantTransactionManager", …)`. Only the class-scoped form is true. (ii) The previous revision then kept the block's *"Most acute when recalculateForItem is called from StockunitService.transferStock"* sentence **because** `transferStock` is `@Transactional` — but being transactional is not the claim that sentence makes. `transferStock` does **not** call `triggerReplenishmentMaintenance`; its own comment says so (*"[SBDEV-2033] Intentionally NOT triggering replenishment maintenance here"*) and the enclosing-signature walker over `StockunitService` reports the four `triggerReplenishmentMaintenance(` sites as `setLockOnHold`, `setLockDamaged`, `adjustAmount`, `removeLock`. The sentence is nevertheless **true by an indirect route no lane had named**: `transferStock` → `fixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, stockUnitItemData)` → `triggerReplenishmentMaintenance(itemData.getId())` → `recalculateForItem`, all inside `transferStock`'s transaction — the §3.1 family. **Keep the sentence and write that route into the block**, otherwise the next reviewer greps `transferStock` for `recalculateForItem`, finds the SBDEV-2033 comment saying the opposite, and re-opens this.

*Correction to the round-2 review, verified this pass:* that indirect route and §0.3 item 4's `CODE_MANUAL_TRANSFER` pre-load are on **mutually exclusive branches** of `transferStock` — the flowbin `if` reaches `createFixedLocationAssignment`, the non-flowbin `else` carries the `findByUnitloadId` guard — so they cannot compound in a single call, contrary to N-3's closing note.

**F9.** The AC-4 test's comment block names the cross-bean proxy, the pre-lock `RecalcContext` snapshot and a changed `getInboundReplenish` — three claims §2.2 refutes. Delete the tolerance assertions and rewrite the block to the measured mechanism, citing this plan.

### 4.10 Why F6, F10 and F11 are **deliberately** dropped — do not "restore" them

Nam's A-narrow decision (§12 Q1) removes all three. Two of the reasons are substantive, not administrative, and are recorded here so a later reader does not read the gap as an omission:

- **F6 alone makes things worse.** F6 would convert `UnitloadBusinessService.processTransfer`'s BLOCK_REALIGN loop from `for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId()))` into an id projection plus `findByIdForUpdate(id)`. Today that loop is a **non-locking repeat load** — no upgrade, no version check — and the first lock on that stock unit is taken later at `changeReservedAmount`, **only on the redirect/cancel branch**. F6 replaces it with an *unconditional locking upgrade for every stock unit on every BLOCK_REALIGN move*. On the `setLockOnHold` path the row has not been written yet at that point (`save(stockUnit)` comes after `transferUnitLoadToLocation`), so there is a genuine window for the cron to bump the version — i.e. **F6 without the producer conversions adds a new `UnexpectedRollbackException` site to the exact operator action AC-2 existed to protect.** It only becomes safe once *every* BLOCK_REALIGN producer with a same-transaction pre-load is converted, which is four producers (§0.3 items 2–5), not the two the earlier revision counted. That enumeration is SBDEV-3286's ship condition for its F6-equivalent.
- **F10 and F11 buy nothing without each other and without R9.** They convert the caller pre-loads, but on `setLockOnHold` the version check merely moves to the detached `merge` at the end of the method (§0.3 item 6) — so even the full wide scope does not make *"Set On Hold"* immune without R9's three-line re-load-by-id. That interaction is why AC-2 case (a) is deleted rather than deferred (§8.1).

Everything F6/F10/F11 would have covered is in §0.3, by name, against SBDEV-3286.

---

## 5. File Change Summary

| # | File | Change | Fix |
|---|---|---|---|
| 1 | `repo/jpa/ReplenishorderRepository.java` | +3 scalar projections | F1, F2, F5 |
| 2 | `repo/jpa/StockunitRepository.java` | +`findUnitloadIdsByIdIn` | F2 |
| 3 | `service/ReplenishmentOrderMaintenanceService.java` | entry points → id lists; `recalculateOrder(Long, RecalcContext)`; `RecalcContext` drops `stocksById`/`getStock`; `ensureValidSource` + `redirectSource` lock-first; sibling probe → id; both WARN lines → `id=`; comments | F1–F5, F8 |
| 4 | `service/ReplenishmentOrderSourceSyncService.java` | probe → id | F5 |
| 5 | `service/StockunitService.java` **and** `service/FixLocationAssignmentService.java` | false enumeration → the runtime rule; comment-only, both files | F7 |
| 6 | `unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` (1670 lines) | signature updates at the `recalculateOrder(` references (7 matching lines by `git grep -c`; the instrument counts lines and includes comments, so treat it as "about 7", not a checklist) + the `mockRefetch` helper; new AC-3′ pins | §8 |
| 7 | `unit/service/ReplenishmentOrderMaintenanceServiceReassignTest.java` (316) | probe stub → id | §8 |
| 8 | `unit/service/ReplenishmentOrderSourceSyncServiceTest.java` + `…BranchTest.java` | probe stub → id | §8 |
| 9 | `integration/service/ReplenishmentOrderMaintenanceServiceIntegrationTest.java` (255) | tolerance block deleted, narrative corrected, AC-1 companion case added | F9, §8 |
| 10 | new: `integration/service/ReplenishmentRecalcLockOrderIntegrationTest.java` | AC-5, AC-6b | §8 |

No Flyway migration, no `application.properties` change, no new bean. `UnitloadBusinessService` and `PickLineRealignmentService` are **not** touched (§4.10).

### 5.1 Prerequisites

No DB-state, feature-flag, deploy-order, data-migration, external-system or monitoring prerequisite. Two real ones:

1. **Lock-timeout bound active** (Nam). `wms.tenant.lock-timeout-ms=10000` in `src/main/resources/application.properties` and in `application-postgres-integration.properties`; it must stay non-zero and the tenant dialect must stay PostgreSQL, or `LockTimeoutHibernateJpaDialect` logs *"Tenant lock_timeout is NOT being applied"* and every new acquisition is unbounded. Confirm the INFO line *"Tenant lock_timeout bound ACTIVE at {}ms per lock acquisition"* on dev boot. ⚠ Its own javadoc: the GUC applies *"separately to each lock acquisition attempt"* — the bound is **10 s per acquisition, not 5 s per transaction**, so a loop taking *k* locks is bounded at *k* × 10 s serially.
2. **New query methods must not become SDR read surface** (implementer). Both repositories are `@RepositoryRestResource`-annotated, so an unannotated `@Query` method becomes a new `/search/...` endpoint; every method added here carries `@RestResource(exported = false)`. ⚠ Grepping for `exported = false` matches *method*-level annotations and does not establish class-level export status — read the class annotation. Flag to SBDEV-3169: after F1, `findByStateAndItemdataId` has **zero `src/main` callers** but stays exported by default (it carries no `@RestResource`).

---

## 6. Implementation Steps

Each step compiles and is independently committable.

1. **Repository projections**, with `@RestResource(exported = false)`. *Gate:* `mvn -o clean test-compile` clean; no behaviour yet.
2. **F1** — id-based entry points, `recalculateOrder(Long, RecalcContext)`, guards under the lock, both WARN lines to `id=`, and the unit test's `recalculateOrder(` references and `mockRefetch` updated. *Gate:* AC-1 red→green on T1 — confirm it was red for the **right reason** first (§8.5).
3. **F2 + F3 + F4.** *Gate:* AC-1 stays green with the Stockunit hop forced (§8.3's T1 companion), and the AC-3′ pins are in place and mutation-killed.
4. **F5** — the two sibling probes + their unit-test stubs.
5. **AC-5 + AC-6 tests** (new integration class), each mutation-checked.
6. **F7 + F8 + F9** — comment and narrative corrections, both F7 files. Comment-only, but a review item, not a rubber stamp: the FIX pass for a false claim has produced a new false claim here **three** times (R7), so §9 item 8 requires an independent read of these blocks and of §13.

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

Rows 1, 2, 5, 7, 9 and 10 are **No — nothing added**: no in-JVM state (`RecalcContext` is a per-invocation local); no pool-math change (F3 adds a *statement* inside an existing transaction, not a connection); no session/WebSocket affinity; no new `@Async` boundary; no cached entity on this path (`Replenishorder` and `Stockunit` appear in none of the 15 `@Cacheable` files — positive control: the same grep finds `SyspropService`, `ItemdataService`, `LocationService`); no added HTTP or message send. Pre-existing and unchanged: the cadence marker is read through a **per-replica** Caffeine cache whose `@CacheEvict` is local, so replica B can re-run a sweep replica A just finished.

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 3 | **Scheduled jobs** | **Yes** — `recalculateOpenOrders` is the `ReplenishOrderJob` sweep | No ShedLock exists in this repo (`git grep ShedLock` over `src/main` + `pom.xml` → 0 hits) and none is added. Cross-replica serialisation on this path *is* the `findByIdForUpdate` row lock this plan repairs, so the change strengthens the existing control. Per-order tx shape unchanged (`self.recalculateOrder` through the CGLIB proxy, REQUIRED). |
| 4 | **Long transactions** | **Yes — larger than the previous revision stated** | See below. |
| 6 | **Retry / idempotency** | **Yes — improved** | Converge makes a retry a no-op by construction (§4.5); before this change a retry after the rollback re-ran the whole host operation. |
| 8 | **Distributed lock correctness** | **Yes — the subject** | Every locking finder here runs inside `@Transactional(value = "tenantTransactionManager")`. "First touch is the locking finder" is what makes the pessimistic lock serialise instead of throw. Ordering: R2. No optimistic-retry expansion — decision 1 chose CONVERGE. |

**Sizing row 4 honestly.** Today `recalculateOrder` takes **no** `Stockunit` lock on the dominant path: `ensureValidSource` reads without a lock and `updateRequestedAmount` short-circuits before `changeReservedAmount` is ever called (§4.5's trace ends there). After F3 it takes **one `PESSIMISTIC_WRITE` per PROCESSABLE order, unconditionally**, on what §2.3 calls the hottest entity in the product — and on the `recalculateForItem` path there is **no per-order transaction**, so every such lock is held until the *host* operation commits. In one sentence: *every operator action that triggers replenishment maintenance now holds a write lock on the source stock unit of every PROCESSABLE order for that item, for the remainder of its own transaction, whether or not any amount changes.* On Hydra UAT that is 8 rows (§2.4); on a warehouse with hundreds of open orders for a hot SKU it is not. Each acquisition is bounded at 10 s per attempt (§5.1), so the worst case is an attributable 55P03, not an unbounded hang. F3 is nonetheless **required** by AC-5 — convergence needs the arithmetic inputs read under the lock.

**v2 constraint checklist:** the `v2/wms2-api/CLAUDE.md` rules (qualified `tenantTransactionManager`, `rollbackFor` preserved, constructor injection, `jakarta.*`, SLF4J parameterised logging, `.orElseThrow` over `.get()`, no JPA associations) all hold — **no new annotation and no new dependency**, every new query is a scalar projection over existing columns, SDR surface handled at §5.1.

---

## 8. Testing Plan

### 8.1 Acceptance criteria → tests

| AC | Test | Asserts |
|---|---|---|
| **AC-1** | T1 `ReplenishmentOrderMaintenanceServiceIntegrationTest.concurrentRecalculateForItem_*` (existing, tolerance block deleted) + §8.3's companion | `e1.get() == null && e2.get() == null` |
| **AC-2** | **none — NOT DELIVERED BY THIS PLAN.** Owned by [SBDEV-3286](https://app.clickup.com/t/868m3fzwv) | see below |
| **AC-3′** | T3 unit pins in `…UnitTest` + `…ReassignTest` + `ReplenishmentOrderSourceSyncServiceTest` | the invariant **scoped to the transaction `recalculateForItem` opens itself** (§3.1); the form is §8.2 |
| **AC-4** | T1 | the SBDEV-2234 pair invariant still holds (84/84); the existing `requested > 0` positive control kept so the equality cannot be vacuous; `count(*) FROM replenishorder WHERE itemdata_id = ?` still 1 |
| **AC-5** | T5 (new fixture, §8.3) | the **recomputed** `requestedamount`, strictly less than the pre-winner 84 |
| **AC-6a** | T4a unit | the two named non-locking finders are not called, each with its positive row (the pin's exact form is §8.2 — the AC is written as what the pin asserts, not as an open-ended invariant) |
| **AC-6b** | T4b integration | with **no** ambient transaction, `recalculateOpenOrders` completes while a concurrent actor bumps the same order's version |
| **AC-7** | none — comment-only | §8.6 |

**AC-2 — why it is not here.** The old AC-2 asserted that the two `@Transactional` operator paths (*"Set On Hold"* and FLA *move*) commit through a concurrent version bump. A-narrow cannot satisfy it: the callers' own pre-loads (`move`'s `getActive(...)` loop; `move`'s and `setLockOnHold`'s `findByUnitloadId(...)` guards) sit in the transaction `recalculateForItem` joins, so F3's locking read stays an upgrade and the throw simply relocates to `ensureValidSource` (§2.3). Writing a gate test against it would encode a red no in-scope change can turn green.

Its `setLockOnHold` half — old case (a) — is **deleted outright, not deferred**, because it is unsatisfiable at *any* scope reachable by a pre-load conversion. Trace it with the full wide scope applied: the controller's `Stockunit stockUnit = stockunitRepository.findById(id).orElseThrow(...)` hands `setLockOnHold` a **detached** instance at version `v` (OSIV off, no transactional controller — §0.1); the third actor commits `v+1`; the locking load inside the method reads `v+1`; then `stockunitRepository.save(stockUnit)` merges the detached `v` copy and `DefaultMergeEventListener.targetEntity` throws `StaleObjectStateException` on `isVersionChanged`. And no interleaving dodges it — once a `SELECT … FOR UPDATE` holds that row the bump cannot commit afterwards, so it must land before, and the locked read therefore necessarily sees `v+1`. Closing that needs R9's fix (re-load by id inside the method and mutate *that* instance), which is SBDEV-3286's §0.3 item 6. The `move` half is satisfiable there once its pre-loads are converted.

### 8.2 The form of the invariant

**AC-3′.** ArchUnit cannot express "same id, across a lock boundary" — it sees call edges, not data flow. The workable form is a **Mockito pin on the finders**, one per in-scope entry point: `verify(replenishorderRepository, never()).findByStateAndItemdataId(any(), any())` and `verify(stockunitRepository, never()).findAllById(any())`, each paired — **always** — with the positive row that makes it non-vacuous: `verify(replenishorderRepository).findIdsByStateAndItemdataId(PROCESSABLE, ITEMDATA)` and `verify(stockunitRepository).findByIdForUpdate(SU_SRC)`. The redirect case needs **its own pair** (`findByIdForUpdate(candidate)` called, `findById(candidate)` not) — note §4.3 deliberately *keeps* one `findById` on the post-redirect return, so a blanket `never()).findById(any())` would be wrong. Add `verifyNoMoreInteractions` on both repositories at the end of each pinned test, so a *newly added* non-locking finder fails the pin rather than passing it — the `never()` rows name two methods and cannot see a third.

Three hazards, per `wms-triage` and the named memories: a `never()` on a method the code never calls is **vacuous forever**, so every one is paired with a mutation restoring exactly that call and must produce an **attributable** red naming the finder (a `NoSuchMethodException`, setup NPE or stubbing error is not a kill); a gated-rows-only pin cannot see a class-level change, hence the mandatory positive rows; and `any()` on a primitive NPEs at unboxing — every pinned parameter here is boxed, so `any()` is safe and `anyInt()` is wrong.

**Scope discipline for these pins:** they run against a mocked repository with no ambient transaction, so they assert the §3.1 invariant at its true scope and nothing wider. Do not add a pin, an assertion or a javadoc sentence claiming the caller-scoped form.

### 8.3 The two negative controls

**T1 companion — AC-1's negative control.** AC-1 going green after step 2 alone would be a false green: the `Replenishorder` throw is gone, but the `Stockunit` throw only fires when that row's version is bumped between the prefetch and the locking read, which the current fixture does not force. T1 gets a companion case with a third actor committing a `reservedamount` change on the source while the loser is blocked on the order lock. Red before F2/F3, green after.

⚠ **That companion is structurally blind to §2.3's caller mechanism** — the class carries `@Transactional(propagation = Propagation.NOT_SUPPORTED)` (*"the threads must see each other's committed rows"*) and calls `recalculateForItem` with **no ambient transaction**, precisely the one shape where caller pre-loads are absent. That is the *only* shape A-narrow claims to fix, so this is a scope statement rather than a gap (R1); the transactional-caller instrument is SBDEV-3286's.

**T5 — AC-5's fixture.** Per §4.5 the current fixture cannot distinguish converge from skip. T5 uses a third actor that, while the loser is blocked on the order lock, commits a **reduction** in the source's availability (lower `amount`, or a `reservedamount` increase under an unrelated activity code). The bound is **two-sided**: `recalculateOrder` does `BigDecimal desiredAmount = shortage.min(getAvailableIncludingReservation(source, order)); if (desiredAmount.compareTo(BigDecimal.ZERO) <= 0) { cancelOrder(...); return; }`, and `isSourceUsable` also sends the order down redirect-or-cancel when its `availableForOrder.compareTo(BigDecimal.ZERO) <= 0`. So the fixture must land `0 < getAvailableIncludingReservation < 84`, not merely `< 84`. Assert a **precondition** that the order is still `PROCESSABLE` after the run: `cancelOrder` leaves `requestedamount` untouched (it sets `State.CANCELED` and calls `releaseReservation`), so an over-large reduction makes T5 red for the wrong reason rather than falsely green. **Assert the recomputed `requestedamount`, not a row count.** Mutation: make `recalculateOrder` return immediately after the locking read — the assertion must go red naming the stale `requestedamount`.

### 8.4 AC-6 — split, because F1 cannot deliver immunity inside an ambient transaction

The original single AC-6 asserted *"`recalculateOpenOrders` completes even when called from inside an ambient tenant transaction that has already read the same orders"*. After F1 that call still **joins** the ambient transaction whose persistence context holds those orders at READ, so the rail either fails (if it forces a bump) or passes vacuously (if it does not). Split it: **AC-6a**, the property F1 actually delivers, as a mutation-checked Mockito pin in the §8.2 form; and **AC-6b**, the honest cron rail — with **no** ambient transaction, `recalculateOpenOrders` completes while a concurrent actor bumps the same order's version, which is the property the cron has today by accident and a future `@Transactional` above either caller (§4.1(b)) would break.

⚠ **No lock-mode assertion is attempted, and the previously proposed belt-and-braces clause is dropped, not re-worded.** Both candidate forms are unwritable in AC-6b's shape: `entityManager.contains(order)` before the read has no `order` reference to name (after F1 there is none until the locking finder returns), and `entityManager.getLockMode(order)` after it fails twice over — AC-6b runs with no transaction, where JPA `getLockMode` throws `TransactionRequiredException`, and even with one the locking read happens inside `recalculateOrder`'s own `REQUIRED` context reached through `self`, so by the time the test regains control the instance is detached and `getLockMode` throws `IllegalArgumentException`. The test never holds a reference to *the* managed instance. AC-6b's real assertion — *completes without throwing while a concurrent actor bumps the version* — is writable and sufficient; AC-6a's pin is the structural half. This is R7 firing on a review-response pass, which is why §9 item 8 makes the independent read of the correction passes mandatory.

The OSIV-shadow trap is **not** a reason to distrust these tests: `spring.jpa.open-in-view=false` is pinned in both integration profiles, so T4b observes the production value. (It remains a real trap for the bare unit lane, where `src/test/resources/application.properties` carries no key.)

### 8.5 Running it — and what a green does NOT mean

⚠ **`BUILD SUCCESS` is not health for the AC-4 test.** The tolerance block absorbs the failure and the captured throwables sit unprinted in `AtomicReference`s. Until step 2 deletes that block:

`mvn -o verify -Dit.test=ReplenishmentOrderMaintenanceServiceIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`, adding `-Dlogging.level.net.aim_ai.wms.service.ReplenishmentOrderMaintenanceService=DEBUG` to surface the swallowed exception and its stack.

The diagnostic WARN changes shape at step 2 — grep for `Failed to recalculate replenishOrder id=` after F1, not for the order number (§4.1). Gating runs follow `wms-triage`'s run discipline (always `mvn -o clean`; one Maven build per worktree; PIT rather than a hand-rolled mutation harness, scoped to the changed class; assert fixture preconditions explicitly). **Baseline comparison — by name, never by count:** before the first implementation commit run the full suite on the detached base and keep `target/surefire-reports/*.xml`, then compare the post-change run **by fully-qualified test name**, because counts alone cannot distinguish "a new red appeared" from "an old red went green". The last measured base was ~3m45s with 26 red / 132 skipped and `mvn verify` aborting before the integration lane — re-measure, do not trust that figure. `OutboxConcurrentEnqueueIT` is timing-flaky (SBDEV-3280); re-run it only after proving independence.

### 8.6 Deliberately-skipped coverage

AC-7 and F8/F9 are comment-only — a test asserting comment text is worse than the comment, and the behaviour the old comment mis-described (the `isActualTransactionActive()` predicate) already has coverage from SBDEV-3250, which F7 must not change; §9 item 8's independent read covers them instead. No unit test for the new `findIds*` projections: a projection's SQL correctness is only meaningful against a real database and a mock-based test would assert the stub. No test for the two `@Transactional` caller paths — deliberately, per §8.1's AC-2 note; that instrument is SBDEV-3286's.

### 8.7 Manual test plan (Hydra UAT, `nywh-hydra-uat` — re-derive counts at test time, §2.4)

| Scenario | Steps | Expected |
|---|---|---|
| Cron sweep under concurrent operator activity (`MINUTE = *`) | Let the timer run; drive stock changes on an item with `PROCESSABLE` replens across several minute boundaries | No `UnexpectedRollbackException` in the log; `Failed to recalculate replenishOrder id=` absent |
| Operator "Set On Hold" on a stock unit backing an active replen | Stock → pick a stock unit whose item has a `PROCESSABLE` replenishorder → Set On Hold | ⚠ **Known still-broken, SBDEV-3286.** May still 500. Record the stack: it must land on `ensureValidSource` or the `save`/`merge`, **not** on `recalculateOrder`'s first statement — that relocation is the evidence F1 landed |
| SQL sanity after a sweep | `SELECT id, requestedamount, version FROM replenishorder WHERE state = 300;` then the source stock units | No stock unit with `reservedamount > amount`; no order whose `requestedamount` exceeds its source's availability |

Not Hydra **prd** — `replenishorder` there has never held a row (§2.4), so a prd smoke test exercises nothing.

---

## 9. Acceptance

DONE when all hold, each with named evidence in the implementation report:

1. **AC-1** T1 asserts `e1 == null && e2 == null`, and §8.3's companion is green with a recorded pre-F2 red.
2. **AC-2** — **explicitly not a gate for this plan.** The implementation report must state, in these words, that *"Set On Hold" and FLA move remain exposed; the throw relocates to `ensureValidSource`; SBDEV-3286 owns them.* A report that omits this is incomplete.
3. **AC-3′** the invariant pins are in place for every in-scope entry point, each with its positive row, its `verifyNoMoreInteractions`, and each `never()` mutation-killed **attributably** — at the scope §3.1 states: *the transaction `recalculateForItem` opens itself*. No pin, assertion or javadoc may claim the caller-scoped form (§8.2).
4. **AC-4** the tolerance block is gone; the `requested > 0` control and the single-order count retained. **AC-7** the false enumeration is replaced by the runtime rule in **both** F7 files.
5. **AC-5** T5's recomputed `requestedamount` asserted on a fixture where converge ≠ skip, with the two-sided bound and the still-`PROCESSABLE` post-condition (§8.3).
6. **AC-6a** and **AC-6b** both green, each mutation-checked; no lock-mode assertion attempted (§8.4).
7. Full suite compared against the base **by test name** (§8.5), any delta explained per test.
8. One independent `code-reviewer` lane per the standing rule in `CLAUDE.md`; every finding fixed including Low. **Mandatory, not advisory:** the F7/F8/F9 comment pass and §13 itself get their own independent read, separate from the review of the logic change (R7).
9. §0.3's seven residuals are all present on SBDEV-3286 before this PR merges.

### 9.1 Verify script — recommendation: **do not write one**

Every assertion here is either a runtime concurrency property (AC-1, AC-4, AC-5, AC-6) a grep cannot observe, or the AC-3′ invariant, whose whole point is that it must be **mutation-checked** — which a shell row cannot be. A row like `grep -q findByIdForUpdate ensureValidSource` would go green on a call that is present but mis-ordered, which is exactly this defect class: every `entityManager.refresh` site in `src/main` is present and every one is in the wrong position (10 lines across 2 files — `StockunitBusinessService:8`, `UnitloadBusinessService:2`; blind spot: counts lines). Generic row-hygiene traps live in `verify-script-traps` and `wms-triage`. If a reviewer insists, the only rows worth having are the two *negative* shape checks a JUnit test cannot see because they are about absence across files (`stocksById` no longer exists in `RecalcContext`; no `@Query` added here lacks `@RestResource(exported = false)`), and both must be negative-tested against the pre-fix tree first.

---

## 10. Risks & Mitigations

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| R1 | **The fix moves the throw to a site nobody enumerated.** The sweep's blind spots are real and one already fired: it cannot see a pre-load in a caller that joins the transaction (§2.3). | High | For the in-scope shape: §8.3's T1 companion with a forced source-version bump. ⚠ **T1 is structurally blind to the caller shape** — its class-level `NOT_SUPPORTED` is the one shape where caller pre-loads are absent. A-narrow therefore has **no** instrument on the transactional-caller paths, by design; §8.1's AC-2 note and §9 item 2 record that, and SBDEV-3286 carries the instrument. |
| R2 | **Redirect-path lock ordering** flips `target → current` to `current → target`. | Med | Unordered by id in *both* shapes, so the ABBA exposure pre-exists and no ordering edge is added. Postgres aborts row-lock deadlocks (40P01) rather than hanging; `lock_timeout` bounds each acquisition. Deterministic id-ordering belongs to the separately-proposed ticket. |
| R3 | **A-narrow relocates rather than removes the throw on the two operator paths**, so a UAT tester may read a still-500 "Set On Hold" as "the fix did not work". | Med | §8.7 tells the tester to expect it and how to tell the relocation apart (stack lands on `ensureValidSource` or the merge, not on `recalculateOrder`'s first statement); §9 item 2 forces the report to say it; SBDEV-3286 is filed and linked. |
| R4 | **One extra row lock per skipped order** (the `manuallyoverridepriority` guard under the lock). | Low | Held for one select. ⚠ Contention is **not** bounded to "another recalculation of the same order" on the `recalculateForItem` path — the plain `this.` call holds it to the host transaction's commit (§7 row 4). Zero rows in the measured UAT population carry the flag, so it is currently unobservable in production data and its only coverage is a unit pin (a manually-overridden order is skipped *after* the locking read, with no `save`) added alongside the AC-3′ pins. |
| R5 | **A new `@Query` method silently becomes an SDR read surface.** | Med | `@RestResource(exported = false)` on all of them (§5.1). ⚠ grepping for it does not establish class-level export status. |
| R6 | **The 1670-line unit test has `lenient()` stubbing** (its own comment: *"the three original stubs were dead in 20-25 callers apiece"*), so a signature change across 7 call sites can produce a green suite that exercises less than before. | Med | Concrete instrument: **remove `lenient()` from the stubs the changed tests touch** and let `STRICT_STUBS` (already the default) report the unnecessary stubbings, plus the `verifyNoMoreInteractions` §8.2 now requires. ("Diff the executed stub set" was not executable — Mockito emits no such artefact.) |
| R7 | **Fixing a false claim tends to produce a new one.** | Med | Fired **three** times on this plan before implementation started: the volunteered line ranges; the `transferStock` blanket claim; the round-2 `transferStock`-is-`@Transactional` derivation and the re-worded-but-still-unwritable AC-6b clause (§4.9, §8.4). §9 item 8 makes the independent read of the correction passes and of §13 mandatory. |
| R8 | **Zero prd exposure could be read as "no need to ship".** | Low | The cron is live every minute (§2.4); exposure begins with the first `PROCESSABLE` order. Ship before that, not after. |

---

## 11. Docs to Update

| Doc | What is stale | Action |
|---|---|---|
| `sbdocs/3-Resources/design/wms2-replenishment-design.md` | §7 *"load-bearing, not ceremonial"* cites `entityManager.refresh(inst.stock)` in `MobileReplenishService`. **That call no longer exists** — removed by `cc9ca6b0` (SBDEV-2575 / plan 260713 Fix B) when `createOrderFromTemplate` went `REQUIRED`; verified with `git log -S`, not inferred from a failed grep. `createOrderFromTemplate` is also no longer `REQUIRES_NEW`. | Rewrite the citation and the `REQUIRES_NEW` premise. **Keep the mechanism paragraph** — it independently places the throw at `changeReservedAmount → findByIdForUpdate` and is now load-bearing prior art. Update the `recalculateOrder` row in the method table for the new signature. Re-locate passages by snippet; line numbers drift. |
| `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` | the 2026-05-20 entry attributes the `this.recalculateOrder` hazard to proxy `rollbackFor` poisoning | Add SBDEV-3244's mechanism **without conflating the two** — the `this.` call stays, and this bug's rollback-only flag came from Hibernate, not a proxy. Record the §3.1 producer families as an open item against SBDEV-3286. |
| `sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md` | §9 symbol index | Add `ReplenishmentOrderSourceSyncService` / `ReplenishmentOrderMaintenanceService` rows if absent. |
| in-source | the integration test's narrative block; the two `That premise is FALSE` comments; the `this.recalculateOrder` WARNING; and four drifted line-number citations in files F5/F8/F9 already touch (`ReplenishmentOrderSourceSyncService`'s class and method javadocs, and `reassignOrCancelForMovedStockUnit`'s javadoc, all pointing into `ReplenishmentOrderMaintenanceService` at positions that have moved) | F9 / F7 / F8 — part of the code change. Per the repo citation rule, convert them to **snippet** citations rather than corrected line numbers. |

Run the `verify-docs` skill against the diff before the PR.

---

## 12. Open Questions / Resolved Decisions

**Resolved (Nam — constraints, not options).** (1) **AC-5 contract = CONVERGE** — the loser re-reads fresh state under the lock and recomputes `desiredAmount` against the winner's committed state; no retry loop, no skip. (2) **Fix shape = pass `Long` ids, never carry the entity** — no `EntityManager` added, no refresh-after-lock, no detach-before-lock. (3) **Scope = subject + both replenishment siblings**; the `StockunitBusinessService` rework is out of scope and §4.6 shows the fix needs no change to that file. (4) **Add a rail** pinning the cron path's currently-accidental immunity (AC-6a/AC-6b).

### Q1 — RESOLVED (Nam, 2026-09-09): **A-narrow.**

The question was whether F10 + F11 (and therefore F6) land in this PR, since F1–F4 alone do not fix the two `@Transactional` callers whose lost writes justify the ticket's priority (§2.3).

**Decision: ship A-narrow — F1–F5 and F7–F9 only.** F6, F10 and F11 are dropped for the substantive reasons in §4.10, and the wide-scope programme is filed as **[SBDEV-3286](https://app.clickup.com/t/868m3fzwv)** with §0.3's seven residuals handed over by name. Consequences already applied throughout: the invariant is narrowed to the self-opened transaction (§3.1), AC-2 leaves this plan's gates and its `setLockOnHold` half is deleted as unsatisfiable at any scope (§8.1), and R3 covers the "relocated throw reads as an unfixed bug" hazard.

**Q2 — `Optional<Long>` for F5's probe when the predicate can match multiple rows?** It preserves today's behaviour exactly; recommendation: no change — what a second active replen on one stock unit means is a separate behavioural decision this plan should not smuggle in.

**Q3 — Should `redirectSource` return the target entity instead of `boolean`,** removing §4.3's retained `findById`? Mechanical, zero behavioural difference, widens the diff. Recommendation: no; follow-up.

**Q4 — Option B's rejection, restated precisely.** The load-bearing leg stands: a projection captured before the order lock carries pre-winner `reservedamount`, on which `desiredAmount` depends, so B cannot deliver AC-5. The earlier second leg — *"projections appear nowhere in `src/main`"* — was too broad and is withdrawn: only the **constructor-expression** form (`SELECT new`) is absent (zero hits across `src/main/java`; positive control — the same instrument finds 66 alias-projection lines in `ReplenishorderRepository` alone). Alias-based interface projections are a dominant idiom here.

---

## 13. Review response

Rounds 1 (architect + critic) and 2 (architect). Round-1 dispositions are collapsed to one line each where round 2 closed them.

| Finding | Verdict | Where addressed |
|---|---|---|
| **Round 1 — closed and re-verified in round 2:** F-4 (§2.4 UAT figures) · F-5 (§4.6's refresh step) · F-6 (R4's mitigation) · F-7 (10 s per acquisition) · F-8 (stale in-source citations) · Critic H-2 (AC-5 vacuous) · M-1 (comment in two files) · M-2 ("2 of 11" is a floor) · M-4 (Option B leg) · M-5 (R6's instrument) · M-6 (OSIV shadow) · L-2 (null `stockunitId`) · L-3 (dead SDR export) · L-4 (§3.2 size column) · 3.5 (baseline procedure) | **Accepted, closed** | §2.4, §4.6, R4, §5.1, header rule, §8.3, §0.2 site 7, §1, §12 Q4, R6, §8.4, §4.3, §5.1, §3.2, §8.5. ⚠ Critic 3.4 (*"AC-2 not encodable as written"*) is **superseded, not closed** — round 2's N-1 showed the encoding it asked for is unsatisfiable at any scope, so AC-2 was deleted rather than encoded (§8.1) |
| Round-1 F-1 / Critic H-1 — the fix does not hold on the two `@Transactional` callers | **Accepted; resolved by scope decision.** F10/F11 were correct as far as they went but could not deliver the claim built on them | §12 Q1 → A-narrow; §0.3 items 1–2; §8.1 AC-2 note; R3 |
| Round-1 F-2 / round-2 **N-3** — F6 converts a conditional upgrade into an unconditional one, and a **fourth** BLOCK_REALIGN producer exists (`transferStock`'s `CODE_MANUAL_TRANSFER` `findByUnitloadId` size guard) | **Accepted; F6 dropped.** The producer is named as a residual and becomes SBDEV-3286's ship condition for its F6-equivalent | §4.10 first bullet; §0.3 item 4 |
| Round-1 F-3 / round-2 **N-4** — AC-6b's belt-and-braces assertion is *still* unwritable | **Accepted; the clause is dropped, not re-worded.** Both candidate forms shown unwritable (no transaction → `TransactionRequiredException`; detached instance → `IllegalArgumentException`; no reference to the managed instance at any point). AC-6a's wording rewritten as what the pin asserts, plus `verifyNoMoreInteractions` | §8.4's ⚠ paragraph; §8.1 AC-6a row; §8.2 |
| **N-1 (High)** — AC-2 case (a) for `setLockOnHold` is unsatisfiable in **both** Q1 branches; §8.2's fixture is R9's detached-merge case | **Accepted; AC-2 case (a) deleted outright**, with the merge trace and the "no interleaving dodges it" argument recorded. AC-2 as a whole leaves this plan's gates | §8.1's AC-2 note; §9 item 2; §0.3 item 6; §4.10 second bullet |
| **N-2 (High)** — §3.1's invariant and AC-3′'s scope are false; a fifth producer family reaches the recalc through `createFixedLocationAssignment` | **Accepted; the claim is narrowed, and the finding extended.** Re-derived this pass: `createFixedLocationAssignment` has **six call sites across four files** (not "four places"), of which **three** are `@Transactional` *and* pre-load — `MobileReplenishService.finishReplenishmentOrder`, `MobilePutAwayService.storeBoxOnLocation`, `MobileMoveUnitloadService.scanDestination`, each verified by signature walker + ranged read. The other three are excluded by named reasons (`transferStock`'s flowbin branch loads neither entity; `checkDestination`'s `readReplenishOrder` runs **after** the call; `assignDestinationForMultiUnitLoads`'s only caller `fulfillMultipleUnitLoads` is not `@Transactional`) | §3.1's ⚠ block and table; §0.3 item 3; §8.2's scope-discipline paragraph; §9 item 3 |
| **N-5 (Medium)** — Critic H-1's sub-claim rejection rests on a guard that does not establish it | **Accepted.** The `move` half is verified sound; the `setLockOnHold` half is withdrawn — the flowbin guard is a location-type test against a different table. The conclusion is restated as a **measured data property** with its positive control, and noted as not enforced in code. Moot for this diff (A-narrow does not touch `UnitloadBusinessService`); handed on so 3286 does not inherit the false derivation | §2.3's closing "Withdrawn" paragraph; §0.3 item 5 |
| **N-6 (Medium)** — the previous revision's §4.10 (now §4.9) reached a true conclusion about `transferStock` by an argument the code refutes | **Accepted; argument replaced.** The sentence is kept and the **indirect** route named (`transferStock` → `createFixedLocationAssignment` → `triggerReplenishmentMaintenance` → `recalculateForItem`), with the SBDEV-2033 comment quoted so the next reviewer's grep does not read as a refutation. **One correction to the finding:** the indirect route and N-3's `CODE_MANUAL_TRANSFER` pre-load sit on **mutually exclusive branches** of `transferStock`, so they cannot compound in one call | §4.9's ⚠ block |
| **N-7 · N-8 · N-9 (Low)** — F1 destroys the order number in both WARN lines · T5's fixture needs a two-sided bound and a "still PROCESSABLE" precondition · §4.1's "neither caller" is under-derived | **All accepted, each decided in the plan rather than the diff.** N-7: log the id (`replenishOrder id={}`, `orderId`), no re-fetch inside a catch on a rollback-marked transaction, downstream log-grep consequence recorded. N-8: bound is `0 < getAvailableIncludingReservation < 84`, with `cancelOrder`'s non-effect on `requestedamount` verified. N-9: both callers named and verified — `schedulejob/ReplenishOrderJob` and `MobileReplenishService.fulfillMultipleUnitLoads`, the latter not `@Transactional` — with the instrument's blind spot stated | §4.1's WARN paragraph and consequence (b); §8.5; §8.3's T5 paragraph |
| Round-1 architect §5 item 5 — project the `manuallyoverridepriority` flag instead of locking the skipped row | **Rejected** (round 2 confirmed the rejection is fair). One caveat recorded: if a tenant ever uses the flag at scale, the projection is the mitigation — the rejection is not a permanent bar | §4.1 consequence (a) |
| Critic Part 4 / round-3 brief — length mandate (~400–450) | **MISSED, and stated as missed.** 1001 → 501 → **488**, measured with `wc -l` on the file itself, not on a wrapped snapshot. Round 2 claimed "~470" against a 501-line file (the 965/966 figure some briefs carry is the *wrapped* snapshot, not this file); that class of error is not repeated. Removing F6/F10/F11 took out ~55 lines; the pass's own obligations put back ~43 (§0.3's seven named residuals, §3.1's six-call-site derivation table, §4.10's two substantive drop reasons, §8.1's AC-2 deletion argument, nine round-2 disposition rows). Every remaining line is a decidable claim, an instrument, or a blind-spot statement — getting to 450 means deleting one of those, which is the wrong trade | throughout |
**Length, measured: 488 lines** (`wc -l`, 2026-09-09, after the A-narrow pass). ⚠ This figure has been misstated twice already — once as "~470" when the file was 966, then via a footer and a §13 row that pointed at each other. Re-derive it with `wc -l`; do not trust any number written here. The drop from 501 comes from removing F6/F10/F11 (the previous revision's §4.8 and §4.11, §5 rows 5/6c, two §6 steps, R3's old text, §8.2's AC-2 encoding block, §0.2 rows 8–9), partly offset by §0.3's residual list, §3.1's producer table and this table's round-2 rows.
