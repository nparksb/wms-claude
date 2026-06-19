---
title: "Club Line Re-Run Idempotency Fix — reconcile-on-reentry with content re-validation"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: archived
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-04
updated: 2026-06-05
db_verified: true
related:
  - sbdocs/3-Resources/workflows/wms2-club-run-workflow.md
  - sbdocs/4-Archieves/wms2/plan/260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.md
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
verify_script: sbdocs/9-System/scripts/verify-260604-club-line-rerun-idempotency-fix.sh
tags:
  - plan
---

# Club Line Re-Run Idempotency Fix — reconcile-on-reentry with content re-validation

**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** High
**Status:** draft (ralplan consensus: Planner → Architect → Critic; Critic ITERATE findings resolved by user decisions + position-mutability investigation)
**Date:** 2026-06-04
**DB verified:** true (live queries against `wms2-wineco-dev`, tenant `wine-wsl`)

---

## 0. Affected Sites (enumeration before drafting)

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `ClubLineOrderProcessor.java:106-110` | `findByLabelidForUpdate` guard throws **unconditionally** when a UL with the label exists | yes | **YES — Fix A** |
| 2 | `ClubLineOrderProcessor.java:112-118` | `createUnitload` + `setParcelId` + `save` — the Phase-2 side effects committed per order | yes | **YES — Fix A reuse target** |
| 3 | `ClubLineOrderProcessor.java:125-182` | per-position stock validation + transfer loop — **skipped** by a naive reuse early-return | yes | **YES — Fix A re-validation** |
| 4 | `CustomerorderBatchService.java:768-781` `rollbackClubLineState` | reverts **batch state only**; leaves committed Phase-2 artifacts | yes | NO — intentionally unchanged (see §3.3 "Why no cleanup-on-rollback") |
| 5 | `CustomerorderBatchService.java:844-851` `runClubLine` catch | calls `rollbackClubLineState` only | yes | NO — unchanged (orphan is now *reused*, not cleaned up) |
| 6 | `CustomerorderService.java:621-769` `cancelOrder` | cancels club CO positions with **no batch-state guard** while batch ∈ {520,525,527} | **adjacent / enabling** | NO — separate defect; see §10 Open Question 1 (the reason Fix A must re-validate) |
| 7 | `CustomerorderService.java:528,549` `packageOrder` | non-club packaging; rejects CLUB at 502-504; no label guard | no | NO — different workflow |
| 8 | `BillofladingService.java:744,768` | BOL / transfer-lane parcel creation | no | NO — different workflow |

The §0 in-scope rows (1-3) each map to a POSITIVE check in `verify-260604-club-line-rerun-idempotency-fix.sh` (§9.1).

---

## 1. Problem Statement

Running a club order that had previously been **partially processed** fails permanently with a parcel-label conflict, and the batch can never complete.

**Observed (tenant `wine-wsl`, `wms2-wineco-dev`, 2026-06-04 10:39:39):**
```
ClubLineOrderProcessor  processOrder: working with order=29902997
BusinessException       Parcel label already in use: WF1780587616140 on order 051613-000001
CustomerorderBatchService Club line failed for batch 19e934bc6d6: Parcel label already in use: WF1780587616140 on order 051613-000001
CustomerorderBatchService Rolled back batch 29902996 state from IN_PROGRESS to 520 after club line failure
```

**Reproduction:** activate a club batch → run club line → induce a Phase-3 (`finalizeClubLine`) failure after at least one order's Phase-2 commit → re-run the club line. Every re-run fails on the parcel-label guard and rolls the batch back to ACTIVATED (520). The batch is stuck-looping.

### DB evidence (queries run live)

```sql
-- the order: parcel already built, but never finalized (state 0, not PACKED=650)
SELECT id, number, state, parcelexternalnumber, parcel_id, orderbatch_id, modified
FROM customerorder WHERE id = 29902997;
-- → state=0, parcel_id=29903012, parcelexternalnumber=WF1780587616140,
--   orderbatch_id=29902996, modified=2026-06-04 08:45:21.314881

-- the orphan package unit load created by the prior (08:45) run's Phase 2
SELECT id, labelid, storagelocation_id, type_id, created FROM unitload WHERE labelid='WF1780587616140';
-- → id=29903012, storagelocation_id=51609 (Packaging), type_id=3, created=08:45:21.302454

SELECT id, amount, itemdata_id, unitload_id FROM stockunit WHERE unitload_id=29903012;
-- → id=29903008, amount=1.0, itemdata_id=20371549   (the 1u transferred into the package at 08:45)

-- the batch: back at ACTIVATED, staging lane NOT nulled (finalize never ran)
SELECT id, state, staginglane_id, modified FROM customerorder_batch WHERE id=29902996;
-- → state=520 (ORDER_BATCH_ACTIVATED), staginglane_id=658552050 (StagingLane07), modified=10:39:39.894

-- finalize enqueues 3 outbox rows/order; none exist → finalize never committed
SELECT id FROM outbox_message WHERE aggregate_id=29902997;        -- → (empty)

-- the position still needs 1u; staging still holds 10u → a clean run WOULD succeed
SELECT id, itemdata_id, amount, state FROM customerorder_position WHERE order_id=29902997;
-- → id=29902998, itemdata_id=20371549, amount=1.0, state=0
-- staging UL317313 holds stockunit 29903018 = 10u of item 20371549 on StagingLane07
```

**Interpretation:** the order was Phase-2 processed at **08:45** (unit load 29903012 created, `parcel_id` set, 1u transferred in — all timestamped `08:45:21`). Phase-3 `finalizeClubLine` then never committed (order still state 0, no outbox rows, staging lane not nulled). The failure path rolled the batch back to 520 (re-runnable) **without removing the committed Phase-2 unit load**. The 10:39 re-run hit the parcel-label guard on that orphan and stuck-looped.

---

## 2. Root Cause Analysis

### 2.1 The mechanism

`runClubLine` is intentionally **non-transactional**, split into four phases (260424 per-order design; 260521 self-invocation fix). Phase 2 calls `clubLineOrderProcessor.processOrder(...)` **once per order, each in its own tenant transaction** (`ClubLineOrderProcessor.java:92`, `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`). That transaction creates the package unit load, sets `order.parcel_id`, and transfers stock into it (`ClubLineOrderProcessor.java:112-174`) — and **commits independently of the batch outcome**.

When Phase 3 (`finalizeClubLine`) fails, the orchestrator's catch (`CustomerorderBatchService.java:844-851`) calls **only** `rollbackClubLineState` (`767-781`), which reverts the batch state `527 → originalState (520)` and nothing else. The committed Phase-2 unit load + `parcel_id` survive.

The re-run then re-enters `processOrder`, whose **first action is an unconditional reject** (`ClubLineOrderProcessor.java:106-110`):

```java
if (unitloadRepository.findByLabelidForUpdate(order.getParcelexternalnumber()).isPresent()) {
    throw new BusinessException("Parcel label already in use: "
            + order.getParcelexternalnumber() + " on order " + order.getNumber());
}
```

The order's **own** previously-created unit load carries the label, so the guard fires against the order itself — a self-inflicted deadlock between an idempotency-blind guard and a side-effect-blind rollback.

### 2.2 Why this is the durable problem, not finalize

`finalizeClubLine` (`688-758`) is a **single** `@Transactional` method: `updateStateByIds(PACKED)` (691), `batch.setState(530)` (696), and all outbox enqueues (707-757) are one atomic unit — it cannot partially commit (confirmed: order state 0 **and** zero outbox rows are mutually consistent with a full rollback). The orphan does **not** come from finalize; it comes from the **already-committed Phase-2 per-order transactions**. *Why* finalize first failed at 08:45 is a separate question (§10 Open Question 2) and is out of scope — this plan makes the **re-run safe** regardless of that trigger.

### 2.3 Architectural gap

The 260424 redesign traded the single mega-transaction for per-order commits to cut lock-hold time from `O(N·M)` to `O(M)`. That trade **silently dropped atomic rollback**: a partial failure now leaves committed side effects, and nothing was added to make the pipeline safe to re-run. This plan closes that gap by making `processOrder` **idempotent on re-entry** rather than by adding a compensating-delete path (which is unsafe here — see §3.3).

---

## 3. Design / Proposed Fix

**Strategy (user decision, 2026-06-04): Fix A (reconcile-on-reentry) + observability. The orphan unit load is *reused*, never mutated/deleted.** "Defense in depth" is realized as three non-destructive layers:

- **Layer 1 — reconcile-on-reentry (Fix A, §3.1):** `processOrder` reuses the order's own committed unit load instead of throwing.
- **Layer 2 — self-healing re-run (inherent, no code):** because Phase 2 becomes a near-no-op for the already-processed order, the re-run proceeds to re-drive Phase 3 `finalizeClubLine` to completion. The stuck loop becomes a successful retry.
- **Layer 3 — observability (§3.2):** counters on the reuse path + a content-mismatch failure, so silent recurrences are visible.

### 3.1 Fix A — reconcile-on-reentry with content re-validation (`ClubLineOrderProcessor.processOrder`, lines 106-118)

**Problem:** the guard at 106 rejects the order's own unit load on re-run.

**Solution:** look up the existing unit load *under lock*, and branch on ownership. If this exact order already owns it (`order.parcelId == ul.id`), **re-validate the package contents against the order's current non-cancelled positions** before reusing it (see §3.4 for why re-validation is mandatory, not optional). Only a label owned by a *different* order (or with no owning `parcel_id`) is the genuine conflict that still throws.

**Before:**
```java
if (unitloadRepository.findByLabelidForUpdate(order.getParcelexternalnumber()).isPresent()) {
    throw new BusinessException("Parcel label already in use: "
            + order.getParcelexternalnumber()
            + " on order " + order.getNumber());
}

Unitload packageUnitLoad = unitloadService.createUnitload(
        order.getParcelexternalnumber(), packageLocation, packageUnitLoadTypeId,
        clientId, WmsConstants.CODE_PACKAGING_CLUB, spawnLocation, null);
LOG.debug("processOrder: created unitload={}", packageUnitLoad.getId());

order.setParcelId(packageUnitLoad.getId());
customerorderRepository.save(order);
```

**After (intent — exact form decided at implementation):**
```java
Optional<Unitload> existing =
        unitloadRepository.findByLabelidForUpdate(order.getParcelexternalnumber());
if (existing.isPresent()) {
    Unitload ul = existing.get();
    boolean ownedByThisOrder =
            order.getParcelId() != null && order.getParcelId().equals(ul.getId());
    if (ownedByThisOrder && packageMatchesPositions(ul, positions)) {
        // Idempotent re-entry: this order's package was fully built + stocked by a
        // prior committed Phase-2 run. Reuse it; the per-position transfer loop below
        // must NOT run again (the stock already left staging). See §3.4 safety proof.
        meterRegistry.counter("wms2.clubline.orphan_reused").increment();
        LOG.info("processOrder: reusing existing package unitload={} for order={} (idempotent re-run)",
                ul.getId(), order.getId());
        return ul.getId();
    }
    if (ownedByThisOrder) {
        // Order owns the UL but its contents no longer match current positions
        // (positions changed between runs — see §10 OQ1). Fail loud, not silent-wrong-ship.
        meterRegistry.counter("wms2.clubline.reuse_content_mismatch").increment();
        throw new BusinessException("Package contents for order " + order.getNumber()
                + " no longer match its positions (positions changed after packaging)"
                + " — manual reconciliation required for unitload " + ul.getId());
    }
    // Label owned by a different order (or no owning parcel_id): genuine conflict.
    throw new BusinessException("Parcel label already in use: "
            + order.getParcelexternalnumber()
            + " on order " + order.getNumber());
}

Unitload packageUnitLoad = unitloadService.createUnitload(
        order.getParcelexternalnumber(), packageLocation, packageUnitLoadTypeId,
        clientId, WmsConstants.CODE_PACKAGING_CLUB, spawnLocation, null);
LOG.debug("processOrder: created unitload={}", packageUnitLoad.getId());

order.setParcelId(packageUnitLoad.getId());
customerorderRepository.save(order);
```

`packageMatchesPositions(ul, positions)` is a private helper: it loads the unit load's stock (`stockunitRepository.findByUnitloadId(ul.getId())`), groups by `itemdataId`, sums amounts, and compares against the sum of the order's positions grouped by `itemdataId`. Equal (per item, using `BigDecimal.compareTo`) → match. The helper runs inside `processOrder`'s existing transaction (no new boundary).

> **MUST (architect/critic):** the helper compares against the **`positions` parameter already passed into `processOrder`** — i.e. the CANCELED-filtered list built in `validateClubLine` (`CustomerorderBatchService.java:644-646`, `.filter(p -> p.getState() != CANCELED)`) and handed in at `CustomerorderBatchService.java:822`. It **must NOT re-query** positions (e.g. `customerorderPositionRepository.findByOrderId(...)`): a divergent re-read could apply a different filter or see a stale state and produce a **false mismatch → false stuck**. Validating against the same param the build loop consumes guarantees the comparison filter matches the pipeline. (This is a review-only contract — the verify script cannot assert *which* list is compared; see §9.1.)

**Files changed:** `ClubLineOrderProcessor.java` (logic + new `MeterRegistry` constructor dependency + `java.util.Optional` import).

### 3.2 Layer 3 — observability

`ClubLineOrderProcessor` does not currently hold a `MeterRegistry`; add it via **constructor injection** (constructor-only per v2 rules). Two counters:

| Metric | When | Why |
|--------|------|-----|
| `wms2.clubline.orphan_reused` | reuse path taken (a partial prior run was recovered) | a non-zero rate means finalize is failing upstream (§10 OQ2) — points ops at the real trigger |
| `wms2.clubline.reuse_content_mismatch` | order owns the UL but contents diverged from positions | surfaces the cancel-after-activation hole (§10 OQ1) as a loud, counted failure instead of a wrong shipment |

These mirror the existing `meterRegistry.counter("wms2.outbox.serialize_failed", ...)` pattern in `CustomerorderBatchService:311`.

### 3.3 Why NOT cleanup-on-rollback (rejected alternative — recorded for reviewers)

The originally-requested "BOTH" strategy included a Fix B that, on failure, would reverse-transfer the package stock back to staging and delete/relabel the orphan unit load. **Consensus review proved every orphan-mutating variant is unsafe; do not add it later.** Two verified facts:

1. **`sendToNirvana` refuses to act on a stock-bearing unit load** — `UnitloadBusinessService.java:294-296` throws `BusinessException("...has stock!")`. A freshly-built package UL always has stock, so "relabel the orphan out of the way" is impossible without first emptying it.
2. **Reverse-transfer has no reliable destination** — Phase 2 calls `transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)` (`ClubLineOrderProcessor.java:170`); when a staging UL drains it is itself sent to nirvana and **relabeled** (`StockunitBusinessService.java:333-356` → `UnitloadBusinessService.java:312-317`, label becomes `labelid + "-X-" + id`). The original staging UL may no longer exist at the staging lane, so reverse-transfer fails or recreates stock at the wrong place — and the best-effort `catch` would **swallow** it, regenerating a *silent* stuck loop and an inventory discrepancy. This is the common case (last order drains the staging UL), not a corner case.

Reuse (Fix A) sidesteps all of this: the stock stays in the package UL, `parcel_id` stays set, and the re-run reuses it. Confirmed safe by the atomicity proof in §3.4.

### 3.4 Safety proofs (load-bearing — confirmed against code)

**(a) Reuse never sees an under-filled unit load.** `processOrder` is `@Transactional(rollbackFor={BusinessException, FacadeException})` (line 92) and is invoked cross-bean from `CustomerorderBatchService:825` (real proxy boundary). Inside, the UL-create (112), `parcel_id` save (117-118) and every `transferStockToUnitLoad` (168) run in one transaction — each transfer is itself `@Transactional` with `REQUIRED` propagation, so it **joins** `processOrder`'s tx (`StockunitBusinessService.java:181`). A mid-position throw rolls back UL-create + all transfers + the `parcel_id` save together. Therefore a committed `parcel_id` ⇒ a fully-built, fully-stocked UL. (Unchecked `RuntimeException`s also roll the tx back under Spring's default, so there is no reachable gap.)

**(b) Early-return does not corrupt the shared `stockSnapshotMap`.** `validateClubLine` rebuilds `stockSnapshotMap` from **current** staging stock at the start of each run (`CustomerorderBatchService.java:656-668`). On a reuse re-run the prior run already moved this order's stock off staging into the package UL, so that stock is **absent** from the freshly-built snapshot. The deduction at `ClubLineOrderProcessor.java:185` (`pendingDeductions.forEach(StockSnapshot::deduct)`) only mutates snapshots the per-position loop visited; the early `return` skips the loop, so it never deducts for the reused order. Because the reused stock was never in the new snapshot, **not** deducting is exactly correct — subsequent orders already see a pool that excludes it.

**(c) Content re-validation is mandatory** because club positions are **not** provably immutable post-activation — see §10 Open Question 1. The `packageMatchesPositions` check converts the one residual correctness risk (shipping a stale package after a position was cancelled) into a loud, counted failure.

---

## 4. Architecture Overview

```
ClubLineController  POST /runClubLine/{id}
        │
        ▼
CustomerorderBatchService.runClubLine   (NON-transactional 4-phase orchestrator, 802-860)
        │
        ├─ Phase 1  self.validateClubLine        (605-682)  short tx: findByIdForUpdate(batch) lock,
        │                                                    state 520/525 → 527 IN_PROGRESS,
        │                                                    build stockSnapshotMap from staging (656-668)
        ├─ Phase 2  for order: clubLineOrderProcessor.processOrder(...)   ← Fix A here (per-order tx, 825)
        │                                                    create UL + setParcelId + transfer; commits per order
        ├─ Phase 3  self.finalizeClubLine        (688-758)  one tx: orders/positions→PACKED, batch→530,
        │                                                    staging lane null, enqueue 3 outbox msgs/order
        └─ catch → self.rollbackClubLineState    (767-781)  REQUIRES_NEW: reverts batch state ONLY  (unchanged)
```

### Key files

| File | Lines | Role |
|------|-------|------|
| `service/ClubLineOrderProcessor.java` | 92-188 | per-order processor; guard at 106 (**Fix A**); add `MeterRegistry` dep |
| `service/CustomerorderBatchService.java` | 802-860 | orchestrator (unchanged); 656-668 snapshot build; 767-781 rollback (unchanged) |
| `service/UnitloadBusinessService.java` | 294-296, 312-317 | `sendToNirvana` stock-guard + relabel — the reason cleanup-on-rollback is unsafe (§3.3) |
| `service/StockunitBusinessService.java` | 181, 333-356 | transfer joins caller tx; `removeUnitLoadIfEmpty` drains staging to nirvana (§3.3) |
| `repo/jpa/UnitloadRepository.java` | 65-67 | `findByLabelidForUpdate` (`@Lock(PESSIMISTIC_WRITE)`) — the guard query |
| `repo/jpa/StockunitRepository.java` | 31-32 | `findByUnitloadId` — used by `packageMatchesPositions` |
| `service/CustomerorderService.java` | 614-762 | `cancelOrder` with no batch-state guard — §10 OQ1 |

Design references: `sbdocs/3-Resources/workflows/wms2-club-run-workflow.md` (rollbackClubLineState is the only revert pattern; reverts batch state only); `260521-...-runclubline-self-invocation-tx-fix.md` (self-proxy; do **not** wrap phases in one tx); `wms2-transaction-osiv-boundary-map.md` (Rule 5: OMS HTTP outside JPA tx — untouched here).

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Database state** | None | No schema change, no Flyway migration |
| 2 | **Feature flags / system properties** | N/A | Pure correctness fix; no rollout gate |
| 3 | **Config / env changes** | N/A | — |
| 4 | **Deploy-order dependencies** | None | Single-service deploy (`wms2-api`); no coordinated rollout |
| 5 | **Data migration** | **One-off, per stuck batch** | §5.3 runbook — unstick batch 29902996 in `wms2-wineco-dev` |
| 6 | **External systems** | N/A | OMS outbox path unchanged |
| 7 | **Access / permissions** | N/A | No new endpoint/role |
| 8 | **Monitoring / alerts** | **New** | Add a panel/alert for `wms2_clubline_orphan_reused_total` and `wms2_clubline_reuse_content_mismatch_total` (§3.2) |

### 5.2 Implementation Checklist

- [ ] **S1** `ClubLineOrderProcessor`: add `MeterRegistry` constructor dependency + `import java.util.Optional;`.
- [ ] **S2** `ClubLineOrderProcessor.processOrder` 106-118: replace the unconditional throw with the ownership-checked reuse branch (§3.1).
- [ ] **S3** `ClubLineOrderProcessor`: add private `packageMatchesPositions(Unitload, List<CustomerorderPosition>)` helper (§3.1) using `stockunitRepository.findByUnitloadId`.
- [ ] **S4** Wire the two counters (§3.2).
- [ ] **S5** Unit tests (§6) — `ClubLineOrderProcessorUnitTest`. **Also update the existing 5-arg constructor fixture** at `ClubLineOrderProcessorUnitTest.java:56` (`new ClubLineOrderProcessor(...)`) to pass a `MeterRegistry` mock (e.g. `new SimpleMeterRegistry()`), since S1 adds a 6th constructor parameter — the test will not compile otherwise.
- [ ] **S6** Integration test (§6) — re-run self-heal, Testcontainers.
- [ ] Code review completed.
- [ ] **Operational (separate from code deploy):** run §5.3 runbook to unstick batch 29902996.

### 5.3 Live data-fix runbook — unstick batch 29902996 (`wms2-wineco-dev`, tenant `wine-wsl`)

> **Pre-deploy (current code, the unconditional guard is still live):** a re-run will keep failing until Fix A ships. To unstick **now**, remove the orphan so a re-run rebuilds from staging:
>
> 1. **Verify** state with the §1 queries (orphan UL 29903012 holds stockunit 29903008 @ 1u; batch 520; staging UL317313 holds 10u; staging lane 658552050 still set).
> 2. **Remove the orphan** (dev tenant — acceptable since staging still holds 10u for a 1u need): delete `stockunit` 29903008 then `unitload` 29903012, *or* move the 1u back to staging via the UI/move-stock tool.
> 3. `UPDATE customerorder SET parcel_id = NULL WHERE id = 29902997;`
> 4. **Confirm** batch `state=520` and `staginglane_id=658552050` still set (do **not** null the staging lane — finalize must still run).
> 5. **Re-run** club line for batch 29902996 → expect order 29902997 PACKED (650), batch 530, 3 outbox rows for aggregate 29902997.
>
> **Post-deploy (Fix A live):** no manual SQL is needed — a re-run reuses orphan UL 29903012 (its `parcel_id` already points at it; its 1u of item 20371549 matches the 1u position), re-validates, and re-drives finalize. This batch is a clean reuse case.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Reuse (same owner, contents match) | order.parcelId == existing UL.id; UL stock matches positions | returns UL.id; **no** `createUnitload`; **no** `transferStockToUnitLoad`; `orphan_reused` counter +1 |
| Content mismatch (same owner) | order.parcelId == UL.id but a position was cancelled after packaging | throws `BusinessException` ("…no longer match its positions…"); `reuse_content_mismatch` counter +1 |
| Different-order conflict | UL exists under the label but order.parcelId is null or != UL.id | throws `BusinessException` ("Parcel label already in use…") |
| Fresh order | no UL under the label | creates + transfers as today (unchanged) |
| Re-run self-heal (end-to-end) | seed partial-run state, re-run `runClubLine` | batch → 530, order → PACKED, **no** duplicate UL, outbox rows present |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `ClubLineOrderProcessorUnitTest` | `reusesExistingUnitLoadWhenOrderOwnsItAndContentsMatch` | returns existing id; `verify(unitloadService, never()).createUnitload(...)`; `verify(stockunitBusinessService, never()).transferStockToUnitLoad(...)` |
| `ClubLineOrderProcessorUnitTest` | `throwsContentMismatchWhenOwnedUnitLoadDivergesFromPositions` | `BusinessException`, message contains "no longer match"; counter incremented |
| `ClubLineOrderProcessorUnitTest` | `throwsLabelInUseWhenUnitLoadOwnedByDifferentOrder` | `BusinessException`, message contains "Parcel label already in use" |
| `ClubLineOrderProcessorUnitTest` | `createsUnitLoadWhenNoneExists` | unchanged happy path; `createUnitload` called once |
| `CustomerorderBatchClubRerunIT` (new, Testcontainers) | `partialRunThenRerunSelfHeals` | seed orphan UL + parcel_id + batch back at 520; `runClubLine` → batch 530, order PACKED, exactly one UL for the label, outbox rows present — **DEFERRED, see note** |

> **IT deferred (2026-06-04, documented per the implementation fallback).** The full `runClubLine` re-run IT requires seeding a large multi-entity fixture — named `Packaging`/`Spawn` locations, the `UNIT_LOAD_TYPE_PACKAGE` unit-load type, a staging-lane fix-location assignment, staging + committed-package stock, and every finalize sysprop URL — none of which the existing club IT (`CustomerorderBatchOutboxIntegrationTest`, which seeds only a `Client` + bare batch) provides. Authoring it reliably is beyond a safe single-iteration scope and risks a fixture-failing/flaky test. Fix A's `processOrder` behavior is fully covered at the unit level by `A5`/`A5b`/`A6`/`A7` (reuse-match incl. multi-row + scale, content-mismatch, empty-package, different-order, fresh-create), and the end-to-end self-heal is exercised operationally via the §5.3 runbook (live batch 29902996 is already in the clean reuse state). The IT remains a recommended follow-up.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Re-run a previously-failed club batch | staging | activate club batch → force finalize failure → re-run | batch FINISHED, orders PACKED, no duplicate parcels | |
| Different-order label collision | staging | two orders share a parcelexternalnumber across batches | second run rejected with "Parcel label already in use" | |
| SQL sanity | staging DB | after re-run: `SELECT count(*) FROM unitload WHERE labelid='<label>'` | exactly 1 | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|-----------------------|
| `mvn test -Dtest=ClubLineOrderProcessorUnitTest` | | |
| `mvn verify -Dtest=CustomerorderBatchClubRerunIT` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Mockito static-mock note | N/A — v2 uses modern Mockito; no static mocking needed |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---------|---------|------------------------|
| 1 | In-JVM state | N/A | Reuse decision uses only DB state + method-local data; no per-replica cache |
| 2 | Connection pool math | No | No new pools; reuse path uses *fewer* writes (skips create/transfer) |
| 3 | Scheduled jobs | N/A | `runClubLine` is request-driven, not `@Scheduled` |
| 4 | Long transactions | No | `processOrder` tx boundary unchanged; `packageMatchesPositions` is one extra read inside the existing tx; no external I/O held |
| 5 | Request affinity | N/A | No sticky-session assumption |
| 6 | **Retry / idempotency** | **Yes — core of the fix** | A re-run from *any* replica now reuses the committed UL instead of throwing; safe under crash-and-retry |
| 7 | Tenant context | OK | Runs within request-scoped `TenantContext`; no async boundary introduced |
| 8 | **Distributed lock correctness** | **Yes** | `findByLabelidForUpdate` is `@Lock(PESSIMISTIC_WRITE)` inside `processOrder`'s tenant tx; `validateClubLine` holds `findByIdForUpdate(batch)` + sets IN_PROGRESS, serializing same-batch runs. Lock timeout **confirmed configured**: `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` (`application.properties:64`) — a crashed lock holder self-heals within 5s, so it cannot block re-runs indefinitely |
| 9 | Cache invalidation | N/A | No `@Cacheable` entity on this path |
| 10 | External notifications (OMS) | Unchanged | Finalize's transactional-outbox enqueue is untouched |

### Evidence (Yes rows)

| Concern # | What was verified | File:line |
|-----------|-------------------|-----------|
| 6 | Reuse returns the committed UL id; per-order tx atomicity proven | `ClubLineOrderProcessor.java:92,112-174`; §3.4(a) |
| 8 | Pessimistic lock on the label; batch lock + IN_PROGRESS serialization | `UnitloadRepository.java:65-67`; `CustomerorderBatchService.java:608-624` |

---

## 8. Notes

- The orphan unit load is **intentionally retained and reused**, never deleted. Do not "tidy this up" later by adding a delete/cleanup path — see §3.3 for why every orphan-mutating variant is unsafe.
- This plan does **not** diagnose why `finalizeClubLine` first failed at 08:45 (§10 OQ2). The `wms2.clubline.orphan_reused` counter is the breadcrumb to find that trigger in production.

### v2 Constraint Checklist

| # | Constraint | Verdict | Where addressed |
|---|------------|---------|-----------------|
| 1 | OSIV disabled — lazy loads inside a tx | OK | `packageMatchesPositions` runs inside `processOrder`'s tx |
| 2 | Tenant transaction manager | OK | `processOrder` already `@Transactional("tenantTransactionManager")`; no new boundary added |
| 3 | `@Transactional(readOnly=true)` for reads | N/A | The read is inside an existing read-write tx |
| 4 | Caffeine cache invalidation | N/A | No cached entity written |
| 5 | Jakarta namespace | OK | No `javax.*` introduced |
| 6 | H2-compatible test SQL | OK | Unit tests mock repos; the re-run IT uses **Testcontainers PostgreSQL** (real transfer/stock semantics) |
| 7 | `BaseControllerTest` for controller changes | N/A | No controller change |
| 8 | Micrometer metrics | **Yes** | Two counters via injected `MeterRegistry` (§3.2), reusing the `CustomerorderBatchService:311` pattern |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-260604-club-line-rerun-idempotency-fix.sh` (authored alongside this plan). It asserts:
- **POSITIVE** — the reuse branch exists: `findByLabelidForUpdate` result is bound to an `Optional`, gated by an `order.getParcelId()…equals(…getId())` ownership check with an `idempotent re-run` log + `return`.
- **POSITIVE** — the `packageMatchesPositions` helper exists and calls `findByUnitloadId`.
- **POSITIVE** — both counters (`wms2.clubline.orphan_reused`, `wms2.clubline.reuse_content_mismatch`) are present; `MeterRegistry` is a constructor field.
- **NEGATIVE (gated, not removed)** — the `"Parcel label already in use"` throw is **no longer the unconditional first statement** after `findByLabelidForUpdate`; it must be reachable only after the ownership check. (The throw still exists for the different-order case — a script that asserted its *removal* would be wrong.)
- **mvn** — `ClubLineOrderProcessorUnitTest` passes.

**Review-only gate (not machine-checkable):** the script asserts `packageMatchesPositions` exists and calls `findByUnitloadId`, but it **cannot** assert *which* position list the helper compares against. The code-reviewer must confirm the helper uses the passed-in `positions` parameter and does **not** re-query (§3.1 MUST). A defensive negative grep — `file_not_contains 'customerorderPositionRepository\.findByOrderId' "$CLP"` — is included to catch the most likely wrong re-query, but the positive contract remains a human review item.

Final acceptance: the script prints `Result: N pass, 0 fail, …`; paste that line in the implementation report.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | One service file + helper + tests; single subsystem |
| **Pre-draft step** | analyst+planner (done) + ralplan consensus (done) | root cause was layered; consensus already run |
| **Plan-review step** | critic (done — ITERATE findings folded in) | — |
| **Implementation shape** | executor (`model=opus`) | bounded, single-file logic + tests; verify script is the gate |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | code-reviewer | concurrency/idempotency-sensitive change |
| **Commit step** | git directly | single logical commit |

After rollout, if `wms2.clubline.orphan_reused` is non-zero in prod, open the OQ2 investigation (why finalize fails).

---

## 10. Resolved Decisions & Open Questions

### Resolved (user decisions, 2026-06-04)
1. **Strategy = Fix A (reuse) + observability.** Orphan-mutating cleanup-on-rollback ("Fix B") is **dropped as actively unsafe** (§3.3), after consensus review proved the `sendToNirvana` stock-guard + staging-drain leak. "Defense in depth" = reuse (Layer 1) + self-healing re-run (Layer 2) + counters/detection (Layer 3).
2. **Reuse safety = re-validate UL contents** (not blind trust). Chosen because the immutability proof **failed** — see OQ1.
3. **Live data-fix runbook for batch 29902996 included** (§5.3), aligned to reuse semantics.

### Open questions / follow-ups
1. **Club CO positions are NOT immutable after activation (enabling defect).** `CustomerorderService.cancelOrder` (614-762), reachable via OMS `POST /rest/order/cancelPositions` (`OrderRestController.java:534-626`), cancels positions with **no batch-state guard** while the batch is at 520/525/527. This is the scenario the §3.1 content re-validation defends against. **Strongly recommended companion fix (separate plan):** add a guard rejecting cancellation when the batch is in a club-run state. Tracked as a follow-up; not implemented here.
2. **Why did `finalizeClubLine` first fail at 08:45? — OUT OF SCOPE.** No logs retained. Suspect a null sysprop URL or a tote-label/payload build error in `finalizeClubLine` (717-746). The `wms2.clubline.orphan_reused` counter (§3.2) is the production breadcrumb; investigate separately if the rate is non-zero.
3. **Lock timeout — RESOLVED.** `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` is already configured (`application.properties:64`). The 5s finite timeout means a crashed `findByLabelidForUpdate` / batch-lock holder self-heals rather than blocking re-runs indefinitely. No action needed.
4. **Deploy ordering & the inter-deploy loud-failure window.** Ship this plan **before** the companion `260604-cancelorder-club-batch-state-guard.md` (this one fixes the live stuck batch + makes re-runs safe; the guard then closes the upstream cause). **Caveat:** with this plan deployed but the guard not yet, a legitimate mid-run OMS cancel still mutates a club order's positions, and the new `packageMatchesPositions` re-validation will then throw "contents no longer match" — converting a previously-recoverable batch into a manual-reconciliation hard-stop. This is net-positive (it fixes the incident and fails loud rather than mis-shipping), but **keep the inter-deploy window short and watch `wms2.clubline.reuse_content_mismatch`** — it should return to zero once the guard ships.

---

## 11. Implementation Status (2026-06-04)

**Status: implemented.** Fix A landed; Fix B confirmed absent (verify-script `G1` PASS). IT deferred (§8 note).

### Changes
| File | Change |
|------|--------|
| `service/ClubLineOrderProcessor.java` | Added `MeterRegistry` constructor dependency (+ `Optional`/`HashMap` imports). Replaced the unconditional parcel-label guard with the ownership-checked reuse branch (reuse-on-match → `wms2.clubline.orphan_reused` + return existing id; owned-but-divergent → `wms2.clubline.reuse_content_mismatch` + throw "…no longer match…"; not-owned → original "Parcel label already in use"). Added private `packageMatchesPositions(Unitload, List<CustomerorderPosition>)` comparing the package's summed-by-itemdata stock against the passed-in (CANCELED-filtered) `positions`, zero-pruned, via `BigDecimal.compareTo` — no position re-query. |
| `test/.../ClubLineOrderProcessorUnitTest.java` | Constructor fixture now injects `SimpleMeterRegistry`. Added `A5` (reuse, scale-tolerant + verifies contents compared), `A5b` (multi-row same item sums to position), `A6` (content mismatch), `A7` (empty package → mismatch); counter assertions on A5/A6. A3 (different-order) + A4 (fresh-create) regression guards retained. |

### Verification
- `mvn test -Dtest=ClubLineOrderProcessorUnitTest` → **BUILD SUCCESS, 13 tests, 0 failures, 0 errors** (Java 21.0.11 / Maven 3.9.15).
- `mvn clean compile` → **BUILD SUCCESS** (no DI/compile drift from the new constructor arg).
- `bash sbdocs/9-System/scripts/verify-260604-club-line-rerun-idempotency-fix.sh` → **`Result: 15 pass, 0 fail, 0 skip`**.
- Code review (`code-reviewer`, opus): **0 CRITICAL, 0 HIGH**. One MEDIUM (the `packageMatchesPositions` `size()` shortcut yielding a false mismatch on a zero-amount residual row) was **fixed** — the helper now zero-prunes both sides before comparing. Recommended hardening tests (multi-row, scale, empty-package, "verify contents compared") **added**.
- verify-docs: `wms2-club-run-workflow.md` (`last_verified: 2026-06-01`) is within the freshness threshold but does not yet describe the reuse-on-reentry guard — recommended one-line touch-up (non-blocking; the doc's pre-existing `runClubLine (line 743)` and "REQUIRES_NEW" notes also predate this change).

### Git
- Branch: `tasks/club-order-fix` (clean off `origin/develop`).
- Commit: `fa870095fe3bcc3c50edf45e8abb6d270bcafb34`
- PR (→ `develop`): https://github.com/SiteBossInc/wms2-api/pull/36

---

> **Archive note (2026-06-05):** Shipped via PR #36 (merged to `develop`). Archived from `1-Projects/wms2/plan/`.
> Acceptance script retained at `sbdocs/9-System/scripts/verify-260604-club-line-rerun-idempotency-fix.sh`.
> Follow-up: this fix made club re-runs reach `finalizeClubLine`, which exposed a separate state-clobber bug fixed in PR #38 (`fix/club-finalize-order-state-clobber`).
