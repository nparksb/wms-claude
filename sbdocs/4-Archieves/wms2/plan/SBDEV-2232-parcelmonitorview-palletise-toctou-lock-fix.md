---
title: "ParcelMonitorView.palletise/palletiseAndTruckLoad TOCTOU — unguarded state reads on customerOrder, parcel-unitload, BOL, and pallet enable concurrent partial palletisation and BOL state desync"
ticket: "SBDEV-2232"
ticket_url: ""
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
  - sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.md
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2223-confirmPick-last-pick-detection-race.md
  - sbdocs/4-Archieves/wms2/plan/260424-CONCURRENCY_FIX_PLAN.md
tags:
  - plan
  - wms2
  - palletisation
  - truck-loading
  - bill-of-lading
  - concurrency
  - pessimistic-lock
  - toctou
  - race-condition
---

# SBDEV-2232 — `ParcelMonitorViewService.palletise` / `palletiseAndTruckLoad` TOCTOU lock-state checks

**Ticket:** SBDEV-2232
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** implemented
**Date:** 2026-05-15

> **Drift from ticket:** The ticket text states `palletise` mutates shared state "without transaction". That framing
> is outdated as of `260424-CONCURRENCY_FIX_PLAN.md`: both `palletise` (line 102) and `palletiseAndTruckLoad`
> (line 213) now carry `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class,
> FacadeException.class})`. The transaction boundary is correct. **The remaining bug** is that the customer-order,
> unitload, and BOL entities are loaded inside that transaction with plain `findById` / `findByExternalIdList`
> rather than `findByIdForUpdate`. This plan completes the partial fix from 260424 by adding pessimistic locking
> on all four entity classes mutated inside the transaction.

> **db_verified: true** — `customerorder.entity_lock` verified as `integer nullable` (NOT `@Version`) via MCP
> `wms1-wineco-dev` on 2026-05-15. Hibernate does NOT enforce optimistic-lock semantics. All three
> `findByIdForUpdate` methods confirmed present: `CustomerorderRepository:27`, `UnitloadRepository:31`,
> `BillofladingRepository:30`. `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` confirmed at
> `application.properties:64`.

---

## §0 Affected Sites

| # | File:line | Construct | Same root-cause? | In-scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `service/ParcelMonitorViewService.java:147` | `findByExternalIdList` — orders fetched unlocked, then state-checked and mutated | YES | **YES — Fix B** |
| 2 | `service/ParcelMonitorViewService.java:181,184` | `unitloadRepository.findById(parcelId)` — parcel read unlocked before `transferUnitLoadToCarrier` mutation | YES | **YES — Fix C** |
| 3 | `service/ParcelMonitorViewService.java:219-238` | `billOfLading` method parameter (caller-supplied, stale) — state switched and written without row lock | YES | **YES — Fix D** |
| 4 | `service/ParcelMonitorViewService.java:143` | `palletOpt.get()` — existing pallet loaded unlocked, then used as transfer destination | YES | **YES — Fix E (palletise existing-pallet branch only)** |
| 5 | `service/ParcelMonitorViewService.java:278-321` | Same anti-pattern in `palletiseAndTruckLoad` for customerOrders / parcel / pallet | YES | **YES — Fix B/C/E re-applied** |
| 6 | `repo/jpa/CustomerorderRepository` | `findByIdForUpdate(Long)` — prerequisite, already present from SBDEV-2223 lineage | n/a | YES — Fix A1 (verify) |
| 7 | `repo/jpa/BillofladingRepository` | `findByIdForUpdate(Long)` — prerequisite, already present | n/a | YES — Fix A2 (verify) |
| 8 | `service/UnitloadBusinessService.transferUnitLoadToCarrier` | Bare `findById` at L184, L204, L213 — no internal pessimistic locking | YES (external contract) | **OUT — documented as lock invariant in §3.0; caller must hold locks** |
| 9 | `service/BillofladingPositionService.removeBOLPositionIfExists` (called at L175) | Mutates `billoflading_position`; same BOL context | YES | **OUT — covered transitively: BOL is locked first in Fix D** |

**Scope rationale:** Rows 1–5 are the self-contained TOCTOU cluster. Rows 6/7 are repo prerequisites confirmed present.
Row 8 is `transferUnitLoadToCarrier` — it performs no internal locking; this plan documents the lock invariant the caller
must establish (§3.0). Row 9 is covered transitively by the BOL `FOR UPDATE` taken first in Fix D.

---

## 1. Problem Statement

`ParcelMonitorViewService.palletise(parcelMonitorDTOSet, ...)` and its sibling
`palletiseAndTruckLoad(parcelMonitorDTOSet, billOfLading, ...)` form the operator-driven
"build a pallet of parcels (optionally load straight onto a truck)" path. Both methods:

1. Resolve a pallet (create-by-system or look up by label).
2. Resolve a `List<Customerorder>` via `findByExternalIdList(...)` — **unlocked**.
3. Validate `customerOrder.getState() < FINISHED` — **on the stale snapshot**.
4. For each customer order, advance `state := PALLETIZED` if still below, then
   `transferUnitLoadToCarrier(parcel, pallet, ...)` — **with a parcel re-read via bare `findById`**.
5. `palletiseAndTruckLoad` additionally switches `billOfLading.state` to `TRUCK_LOADING`
   on a **caller-supplied (stale) `Billoflading` entity**, then writes it.

Each "read state → decide → mutate" pair is a classic **TOCTOU (time-of-check-to-time-of-use)**
race under PostgreSQL `READ COMMITTED`:

- Two concurrent palletisations on overlapping orders both pass the `< FINISHED` guard, both attempt
  `setState(PALLETIZED) + save`. `entity_lock` is NOT `@Version` — Hibernate does not detect the
  concurrent write. Both commits succeed; OMS notification fires twice.
- Two concurrent `palletiseAndTruckLoad` calls on the same BOL can both enter at `state=OPEN`, both
  flip to `TRUCK_LOADING`, and both proceed silently. A race against a concurrent `closeBOL` overwrites
  `CLOSED → TRUCK_LOADING`.
- A parcel `Unitload` re-read with bare `findById` at L181/L184 does not block a concurrent
  `MobileMoveUnitloadService` or `MobilePickingService` from mutating the same parcel between read
  and `transferUnitLoadToCarrier` execution.

Symptoms in production:
1. Customer orders in `PALLETIZED` state but on no pallet (lost between concurrent palletisations).
2. BOL state oscillation: BOL appears in `TRUCK_LOADING` after another operator marked it `CLOSED`.
3. Parcel on the wrong carrier, or "on two pallets" depending on which write wins.
4. Sporadic `StaleObjectStateException` surfacing in downstream services that touch the half-updated rows.

---

## 2. Root Cause Analysis

### Bug 1 — Unlocked `customerOrderList` (`ParcelMonitorViewService.java:147` and `:278`)

```java
// :147 (palletise) — unlocked bulk fetch; snapshot immediately stale
List<Customerorder> customerOrderList = customerorderRepository.findByExternalIdList(
    parcelMonitorDTOSet.stream().map(ParcelMonitorDto::getCustomerExternalNumber)
        .collect(Collectors.toList()));

for (Customerorder customerOrder : customerOrderList) {
    if (customerOrder.getState() >= WmsConstants.State.FINISHED) {
        throw new BusinessException("Order is already finished: ...");
    }
}
// ...
for (Customerorder customerOrder : customerOrderList) {
    if (customerOrder.getState() < WmsConstants.State.PALLETIZED) {
        customerOrder.setState(WmsConstants.State.PALLETIZED);
        customerorderRepository.save(customerOrder);  // silent last-writer-wins
    }
```

`entity_lock` on `customerorder` is `integer nullable` with no `@Version` annotation — Hibernate
emits `UPDATE ... WHERE id=?` (no `AND version=?` predicate). Two concurrent transactions both read
state=PACKED(650), both pass the `>= FINISHED` guard, both write `setState(PALLETIZED)`, both fire
the `afterCommit` OMS notification. Last writer wins; OMS receives a duplicate event.

### Bug 2 — Parcel `findById` before `transferUnitLoadToCarrier` (`:181`/`:184`, `:311`/`:319`)

```java
// :181 — unlocked parcel read just before the mutation call
Unitload unitLoad = unitloadRepository.findById(customerOrder.getParcelId())...;
unitloadBusinessService.transferUnitLoadToCarrier(unitLoad, pallet, ...);

// :184 — second unlocked read to rewrite the carrier id
Optional<Unitload> parcelOpt = unitloadRepository.findById(customerOrder.getParcelId());
if (parcelOpt.isPresent()) {
    parcelOpt.get().setCarrierunitloadId(pallet.getId());
    unitloadRepository.save(parcelOpt.get());
}
```

`transferUnitLoadToCarrier` performs **no internal pessimistic locking** (verified:
`UnitloadBusinessService.java:184, 204, 213` all use bare `findById`). A concurrent
`MobileMoveUnitloadService.transferUnitLoadToLocation` can mutate the parcel between L181's read
and the eventual UPDATE inside `transferUnitLoadToCarrier`.

### Bug 3 — Caller-supplied stale BOL with unlocked state switch (`:219-238`, `:225`)

```java
public void palletiseAndTruckLoad(..., Billoflading billOfLading, ...) {
    switch (billOfLading.getState()) {           // stale snapshot from caller
        case OPEN: case CREATED:
            billOfLading.setState(TRUCK_LOADING);
            billofladingRepository.save(billOfLading);  // :225 — write on stale entity
```

A second transaction can advance the BOL to `CLOSED` between the caller's load and this method's
switch. The save at `:225` overwrites `CLOSED → TRUCK_LOADING` silently.

### Bug 4 — Existing-pallet path loads `palletOpt.get()` unlocked (`:143`, `palletise` only)

```java
// :126 — look up existing pallet by label, unlocked
Optional<Unitload> palletOpt = unitloadRepository.findByLabelid(palletName);
if (palletOpt.isEmpty()) {
    // ... create new pallet ...
} else {
    pallet = palletOpt.get();  // :143 — stale snapshot, used as N-parcel destination
}
```

A concurrent operator transfers the same pallet onto a truck (sets `carrierunitloadId`) between the
lookup and the loop body. The palletisation then runs against an already-loaded pallet.

Note: `palletiseAndTruckLoad` (line ~274) **unconditionally throws** `BusinessException("Pallet with
name=... already exists!")` on the existing-pallet branch — so Bug 4 and Fix E's existing-pallet
re-validation apply to `palletise` only.

---

## 3. Design / Proposed Fix

### 3.0 Lock Invariants and Transaction Boundary (READ FIRST)

**Global lock order (deadlock prevention):**

```
// Lock acquisition order (deadlock-prevention):
// 1. BOL (if applicable) — first, as the outermost carrier
// 2. Pallet — fan-in point for all parcels
// 3. CustomerOrders — sorted by ID ascending
// 4. Parcels (Unitloads) — sorted by ID ascending, per-order
```

This comment block MUST appear verbatim at the top of both `palletise` and `palletiseAndTruckLoad`.
Two concurrent callers acquiring overlapping rows always compete for the same first-conflicting
lock because all callers sort IDs ascending. AC8 grep-checks for the comment block.

**`transferUnitLoadToCarrier` lock invariant:**

- `UnitloadBusinessService.transferUnitLoadToCarrier` performs **no internal pessimistic locking**
  (verified: bare `findById` at L184, L204, L213 — NOT `findByIdForUpdate`). The misleading
  comment at L183 ("fresh, locked instance") is factually wrong and must be corrected as part of R3-1.
- Therefore, callers (`ParcelMonitorViewService`) MUST hold `PESSIMISTIC_WRITE` on the source parcel
  (Fix C) and on the destination pallet (Fix E) for the entire `transferUnitLoadToCarrier` call.
- All four locks are acquired inside the same `@Transactional(value="tenantTransactionManager")`
  method with default `Propagation.REQUIRED` — Hibernate's row locks survive across the helper call
  because the transactional context is shared.
- **Hypothetical future-refactor trap (advisory only — current code uses default `REQUIRED`):** If
  `transferUnitLoadToCarrier` is ever annotated `@Transactional(propagation = REQUIRES_NEW)`, the
  inner transaction will have a different PostgreSQL backend pid. The caller's `FOR UPDATE` locks
  are invisible to it — Fix C/E silently break. A code comment at the top of
  `transferUnitLoadToCarrier` must warn against this.

**Recursive boundary:** `processTransfer` in `UnitloadBusinessService.java:252-269` recurses into
`findByCarrierunitloadId(unitload.getId())` and mutates child unit loads' `storagelocationId`. For
the BOL outbound palletisation flow, outbound parcels are **leaf nodes** (no children in the carrier
graph), so this recursion is a no-op. If a future caller invokes `transferUnitLoadToCarrier` on a
unit load with carried children, those children are NOT locked by Fix C/E — caller must extend the
lock plan to cover the subtree, OR document that the subtree is read-only.

---

### 3.1 Fix A — Repository prerequisites

Verify (do not add unless missing) that the following locked finders exist:

| Repository | Method |
|---|---|
| `CustomerorderRepository` | `Optional<Customerorder> findByIdForUpdate(Long id)` |
| `UnitloadRepository` | `Optional<Unitload> findByIdForUpdate(Long id)` |
| `BillofladingRepository` | `Optional<Billoflading> findByIdForUpdate(Long id)` |

If any is missing, add with the canonical `@Lock(LockModeType.PESSIMISTIC_WRITE)` pattern.

---

### 3.2 Fix B — Lock `customerOrderList` before state-check and mutation

**Decision (R6 — Option S, Sequential):** N customer orders bounded by ≤20 per typical batch.
N sequential `findByIdForUpdate` calls in sorted-ID order are deterministic and deadlock-free.
A batch method `findAllByIdInOrderByIdForUpdate` (Option B) was considered and deferred — adds
a new repo method for negligible wall-clock gain at N≤20.

**Pattern (applied identically in both `palletise` and `palletiseAndTruckLoad`):**

```java
// (BEFORE) Unlocked bulk fetch — returns stale snapshot used as mutation base.
// List<Customerorder> customerOrderList = customerorderRepository.findByExternalIdList(...);

// (AFTER) Step 1 — enumerate IDs via unlocked fetch (snapshot used for ID discovery only).
// Defensive copy: native @Query return type mutability is not contract-guaranteed.
List<Customerorder> initialSnapshot = new ArrayList<>(
    customerorderRepository.findByExternalIdList(
        parcelMonitorDTOSet.stream().map(ParcelMonitorDto::getCustomerExternalNumber)
            .collect(Collectors.toList())));

// Step 2 — sort by ID ascending IMMEDIATELY and BEFORE any findByIdForUpdate call.
// The sort order IS the deterministic lock-acquisition order (deadlock-prevention).
initialSnapshot.sort(Comparator.comparing(Customerorder::getId));

// Step 3 — re-acquire each Customerorder with FOR UPDATE in sorted-ID order.
List<Customerorder> customerOrderList = new ArrayList<>(initialSnapshot.size());
for (Customerorder stale : initialSnapshot) {
    final Long coId = stale.getId();
    Customerorder locked = customerorderRepository.findByIdForUpdate(coId)
        .orElseThrow(() -> new EntityNotFoundException("Customerorder", coId));
    // findByIdForUpdate returns DB-fresh state at lock-grant time; no refresh() needed.
    // Re-validate FINISHED guard against the locked, post-lock state.
    if (locked.getState() >= WmsConstants.State.FINISHED) {
        throw new BusinessException("Order is already finished: "
            + Customerorder.class.getSimpleName() + ", " + locked.getHistorytote());
    }
    // Observability: log when state advanced under the lock so production occurrences are visible.
    if (locked.getState() != stale.getState()) {
        LOG.warn("customerOrder id={} state advanced under lock: stale={}, locked={}",
            locked.getId(), stale.getState(), locked.getState());
    }
    customerOrderList.add(locked);
}

// Step 4 — mutate ONLY the locked instances; stale snapshot is discarded.
for (Customerorder customerOrder : customerOrderList) {
    if (customerOrder.getState() < WmsConstants.State.PALLETIZED) {
        customerOrder.setState(WmsConstants.State.PALLETIZED);
        customerorderRepository.save(customerOrder);
    }
    // ... rest of loop unchanged ...
}
```

If a `Customerorder` is deleted between the initial `findByExternalIdList` and the
`findByIdForUpdate`, the `EntityNotFoundException` rolls back the whole batch cleanly
(covered by `rollbackFor=BusinessException.class`'s parent class). The operator sees
a clean error message and can retry.

---

### 3.3 Fix C — Lock the parcel `Unitload` before `transferUnitLoadToCarrier`

Replace the two-read pattern (L181 + L184) with a single locked fetch:

```java
// (BEFORE)
Unitload unitLoad = unitloadRepository.findById(customerOrder.getParcelId())...;
// ...
Optional<Unitload> parcelOpt = unitloadRepository.findById(customerOrder.getParcelId());
if (parcelOpt.isPresent()) {
    parcelOpt.get().setCarrierunitloadId(pallet.getId());
    unitloadRepository.save(parcelOpt.get());
}

// (AFTER)
final Long parcelId = customerOrder.getParcelId();
Unitload unitLoad = unitloadRepository.findByIdForUpdate(parcelId)
    .orElseThrow(() -> new EntityNotFoundException("UnitLoad", parcelId));
// findByIdForUpdate returns DB-fresh state — no refresh() needed.
unitloadBusinessService.transferUnitLoadToCarrier(unitLoad, pallet,
    WmsConstants.CODE_PALLETISING, customerOrder.getNumber(), null);
// Reuse the locked entity — no second findById. L1 cache returns the same locked instance.
unitLoad.setCarrierunitloadId(pallet.getId());
unitloadRepository.save(unitLoad);
```

Apply identically at L181/L184 (`palletise`) and L311/L319 (`palletiseAndTruckLoad`).

---

### 3.4 Fix D — Re-fetch and lock the BOL FIRST in `palletiseAndTruckLoad` (repositioned as first operation)

**The BOL lock MUST be the first operation in `palletiseAndTruckLoad`**, before any state inspection
or write. The caller-passed `billOfLading` parameter is treated as ID-only (stale) from method
entry onward.

```java
public void palletiseAndTruckLoad(Set<ParcelMonitorDto> parcelMonitorDTOSet,
                                  Billoflading billOfLading, ...) {
    // Lock acquisition order (deadlock-prevention):
    // 1. BOL (if applicable) — first, as the outermost carrier
    // 2. Pallet — fan-in point for all parcels
    // 3. CustomerOrders — sorted by ID ascending
    // 4. Parcels (Unitloads) — sorted by ID ascending, per-order

    // FIX D — re-fetch BOL with PESSIMISTIC_WRITE FIRST, BEFORE any state inspection.
    // The parameter billOfLading is treated as ID-only (stale) from this point.
    final Long billOfLadingId = billOfLading.getId();
    Billoflading lockedBOL = billofladingRepository.findByIdForUpdate(billOfLadingId)
        .orElseThrow(() -> new EntityNotFoundException("Billoflading", billOfLadingId));
    // findByIdForUpdate returns DB-fresh state at lock-grant time; no refresh() needed.

    // Re-validate BOL state under the lock. Abort if state advanced to a terminal value.
    int bolState = lockedBOL.getState();
    if (bolState == WmsConstants.BillOfLadingState.CLOSED
        || bolState == WmsConstants.BillOfLadingState.CANCELLED
        || bolState == WmsConstants.BillOfLadingState.TRANSFER) {
        LOG.warn("billOfLading id={} state advanced to {} under lock; expected < CLOSED",
            lockedBOL.getId(), bolState);
        throw new BusinessException("billOfLadingUnexpectedStateFound: "
            + bolState + ", " + WmsConstants.BillOfLadingState.TRUCK_LOADING);
    }

    switch (bolState) {
        case WmsConstants.BillOfLadingState.CREATED:
        case WmsConstants.AdviceState.OPEN:
            lockedBOL.setState(WmsConstants.BillOfLadingState.TRUCK_LOADING);
            billofladingRepository.save(lockedBOL);
            break;
        case WmsConstants.BillOfLadingState.TRUCK_LOADING:
            break;
        default:
            throw new RuntimeException("unexpected billOfLading.getState=" + bolState);
    }

    // All subsequent references to billOfLading are replaced with lockedBOL.
    // ... rest of method uses lockedBOL everywhere ...
```

---

### 3.5 Fix E — Lock the pallet (both methods, with documented asymmetry)

**`palletise`** — two branches:

*Existing-pallet branch (L140-144):*
```java
} else {
    // FIX E — lock existing pallet and re-validate before entering parcel loop.
    final Long existingPalletId = palletOpt.get().getId();
    pallet = unitloadRepository.findByIdForUpdate(existingPalletId)
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad", existingPalletId));
    // findByIdForUpdate returns DB-fresh state; no refresh() needed.
    if (pallet.getCarrierunitloadId() != null) {
        LOG.warn("pallet id={} labelid={} already on carrier {} under lock",
            pallet.getId(), pallet.getLabelid(), pallet.getCarrierunitloadId());
        throw new BusinessException("Pallet already loaded onto a carrier: " + pallet.getLabelid());
    }
    // Add any further WmsConstants pallet-cancelled / pallet-in-nirvana state checks here.
}
```

*Create branch:*
```java
pallet = unitloadService.createUnitload(...);  // freshly inserted
// FIX E — re-acquire freshly-created pallet for consistency with the lock plan.
// Defense-in-depth: the pallet ID is not yet visible to other transactions but
// re-locking ensures the lock plan is uniform across both code paths.
final Long createdPalletId = pallet.getId();
pallet = unitloadRepository.findByIdForUpdate(createdPalletId)
    .orElseThrow(() -> new EntityNotFoundException("UnitLoad", createdPalletId));
```

**`palletiseAndTruckLoad`** — **existing-pallet branch is unreachable**: the method unconditionally
throws `BusinessException("Pallet with name=... already exists!")` at line ~274 if `palletOpt` is
present. Fix E therefore applies to `palletiseAndTruckLoad`'s **create branch only** (same as the
`palletise` create branch above). No existing-pallet re-validation is needed in `palletiseAndTruckLoad`.

---

### 3.6 Lock chain after all fixes

**`palletise`:**
```
1. Pallet (Fix E)                  findByIdForUpdate(palletId)
2. CustomerOrders (sorted asc)     findByIdForUpdate(coId) × N  (Fix B)
3. Parcel per order                findByIdForUpdate(parcelId)  (Fix C)
```

**`palletiseAndTruckLoad`:**
```
1. BOL (Fix D)                     findByIdForUpdate(billOfLadingId)  ← FIRST
2. Pallet (Fix E)                  findByIdForUpdate(createdPalletId)
3. CustomerOrders (sorted asc)     findByIdForUpdate(coId) × N  (Fix B)
4. Parcel per order                findByIdForUpdate(parcelId)  (Fix C)
```

**Throughput note:** Typical N ≤ 20. Fix adds ~2N+2 `FOR UPDATE` round-trips ≈ 20–40ms at N=20
against an existing ~500ms transaction. `jakarta.persistence.lock.timeout=5000` (application.properties:64).

---

## 4. V1/V2 Applicability

This plan targets **v2 only**. File a paired v1 audit ticket after this fix lands.

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| Same anti-pattern present? | unverified | yes | v1 audit required |
| `findByIdForUpdate` style | `@Query` + `@Lock` | `@Query` + `@Lock` | identical mechanism if present in v1 |
| Transaction manager | `transactionManager` | `tenantTransactionManager` | v2 uses per-tenant routing |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Status |
|---|---|---|
| 1 | No DB schema change, no migration | N/A |
| 2 | No feature flag, no system property | N/A |
| 3 | `CustomerorderRepository.findByIdForUpdate` present | Confirmed at `:27` |
| 4 | `UnitloadRepository.findByIdForUpdate` present | Confirmed at `:31` |
| 5 | `BillofladingRepository.findByIdForUpdate` present | Confirmed at `:30` |
| 6 | `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` | Confirmed at `application.properties:64` |
| 7 | `EntityManager` injected into `ParcelMonitorViewService` | Verify in class header; inject via constructor if absent |
| 8 | `transferUnitLoadToCarrier` propagation = `REQUIRED` (default) | Confirmed at `UnitloadBusinessService.java:178` |

### 5.2 Implementation Steps

- [ ] **Step 1 — Read & verify.** Read `ParcelMonitorViewService.java` L95-430, `UnitloadBusinessService.java` L178-280, and the three repo files. Add `// Lock acquisition order:` comment block at the top of both `palletise` and `palletiseAndTruckLoad` (R4). Add `// CALLER MUST HOLD ROW LOCKS — DO NOT add REQUIRES_NEW (see SBDEV-2232 §3.0)` comment at the top of `UnitloadBusinessService.transferUnitLoadToCarrier`. Correct the misleading `// fresh, locked instance` comment at `UnitloadBusinessService.java:183` to say `// fresh but NOT locked — lock must be held by caller (SBDEV-2232 §3.0)`.
- [ ] **Step 2 — Fix D (BOL first) in `palletiseAndTruckLoad`.** Insert locked BOL re-fetch + state re-validation as the FIRST operation, before the state switch. Replace every subsequent `billOfLading` reference with `lockedBOL`.
- [ ] **Step 3 — Fix E (Pallet) in both methods.** In `palletise`: lock both the existing-pallet branch (with state re-validation) and the freshly-created pallet. In `palletiseAndTruckLoad`: lock the freshly-created pallet only (existing-pallet branch unreachable).
- [ ] **Step 4 — Fix B (CustomerOrders) in both methods.** Defensive-copy + sort by ID before lock loop. Replace stale `customerOrderList` with locked list. Re-validate FINISHED guard under lock. Emit `LOG.warn` when state moved under the lock.
- [ ] **Step 5 — Fix C (Parcel) in both methods + tests.** Replace `findById` at L181/L184 (and L311/L319 mirror) with single `findByIdForUpdate`; reuse locked instance for `setCarrierunitloadId`. Update `ParcelMonitorViewServiceUnitTest`: stub all four `findByIdForUpdate` methods; add `verify` + `InOrder` assertions. Create `ParcelMonitorViewServiceConcurrencyIT` (Testcontainers PostgreSQL — NOT H2).

### 5.3 Test execution checklist

- [ ] `mvn test -Dtest=ParcelMonitorViewServiceUnitTest` — exits 0
- [ ] `mvn verify -Dtest=ParcelMonitorViewServiceConcurrencyIT` — exits 0
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2232-parcelmonitorview-palletise-toctou-lock-fix.sh` — all PASS
- [ ] Code review — APPROVED with 0 CRITICAL, 0 HIGH

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/ParcelMonitorViewService.java` | Modify | Fixes A–E: sorted-ID lock pattern on all four entity types |
| `service/UnitloadBusinessService.java` | Modify | Add caller-lock invariant comment + correct L183 comment |
| `test/.../ParcelMonitorViewServiceUnitTest.java` | Modify | Stub `findByIdForUpdate` for all four entities; add `verify` + `InOrder` assertions |
| `test/.../ParcelMonitorViewServiceConcurrencyIT.java` | Create | Testcontainers PostgreSQL concurrency tests (Fixes B, C, D, E) |
| `sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md` | Update | Refresh `palletise`/`palletiseAndTruckLoad` line refs; bump `last_verified` |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation |
|---|---|---|---|
| 1 | In-JVM state | No | Pure DB-layer change; no cache, no static field, no ThreadLocal |
| 2 | Connection pool math | Yes (low) | Adds ~2N row locks per call, no extra connections. `replicas × tenants × maxPoolSize` math unchanged. |
| 3 | Scheduled jobs | No | No `@Scheduled` added |
| 4 | Long transactions | Yes | ~2N FOR UPDATE round-trips added at start. OMS notification already deferred to `afterCommit()`. Typical hold time <800ms; `lock.timeout=5s` generous. |
| 5 | Request affinity | No | No in-memory session state |
| 6 | Retry / idempotency | Yes | `PessimisticLockingFailureException` → HTTP 409. `BusinessException` from stale-state re-validation rolls back cleanly (`rollbackFor=BusinessException.class`). Operator can retry — re-submitting the same `parcelMonitorDTOSet` either succeeds or throws again (correct outcome). |
| 7 | Tenant context | No | Runs inside HTTP request scope; tenant context set by filter |
| 8 | Distributed lock correctness | Yes (primary) | `findByIdForUpdate` inside `@Transactional(tenantTransactionManager)`. PostgreSQL row locks coordinate across replicas via per-tenant DB. BOL→Pallet→sorted-orders→parcels ordering. `lock.timeout=5000` at `application.properties:64`. LOG.warn on state-advance-under-lock. |
| 9 | Cache invalidation | No | `Customerorder`, `Unitload`, `Billoflading` not Caffeine-cached per `CacheConfig.java` |
| 10 | External notifications | No | OMS `customerOrderPalletized` already deferred to `afterCommit()` synchronization |

### Evidence

| # | File:line |
|---|---|
| 4 | `ParcelMonitorViewService.java:102, 213` — both methods carry `@Transactional(tenantTransactionManager, rollbackFor=...)` |
| 6 | `RestExceptionHandler.java` — `PessimisticLockingFailureException` → HTTP 409 (SBDEV-2230 baseline) |
| 8 | `UnitloadBusinessService.java:178-250` — `transferUnitLoadToCarrier` verified no internal locking; `application.properties:64` |

---

## 8. Testing Plan

### Unit tests

| Test class | Test method | Asserts |
|------------|-------------|---------|
| `ParcelMonitorViewServiceUnitTest` | migrate existing happy-path tests | Stub `findByIdForUpdate` for all four entities; verify via `verify(...).findByIdForUpdate(...)` |
| `ParcelMonitorViewServiceUnitTest` | `palletiseAndTruckLoad_locksBOLFirstThenPalletThenSortedOrdersThenParcels` | Mockito `InOrder` matching §3.6 chain |
| `ParcelMonitorViewServiceUnitTest` | `palletise_throwsWhenExistingPalletAlreadyOnCarrier` | Fix E re-validation under lock |
| `ParcelMonitorViewServiceUnitTest` | `palletise_acquiresCustomerOrderLocksInSortedIdOrder` | `InOrder` on `findByIdForUpdate(id1 < id2 < id3)` |
| `ParcelMonitorViewServiceUnitTest` | `palletise_throwsWhenOrderAdvancedToFinishedUnderLock` | Stale snapshot = PACKED; locked entity = FINISHED → throws `BusinessException` |
| `ParcelMonitorViewServiceUnitTest` | `palletise_noSaveOnUnlockedInstance` | `verify(repo, never()).save(argThat(isStaleInstance))` |

### Integration tests (Testcontainers PostgreSQL — NOT H2)

| Test class | Test method | Asserts |
|------------|-------------|---------|
| `ParcelMonitorViewServiceConcurrencyIT` | `palletiseAndTruckLoad_throwsWhenBOLStateAdvancedUnderLock` | Thread A flips BOL to CLOSED, Thread B blocks at `FOR UPDATE`, then throws BusinessException; no parcels mutated |
| `ParcelMonitorViewServiceConcurrencyIT` | `palletise_throwsWhenCustomerOrderAdvancedUnderLock` | Thread A advances order to FINISHED; Thread B sees it under lock |
| `ParcelMonitorViewServiceConcurrencyIT` | `palletise_serializesWithConcurrentParcelMove` | Thread A `transferUnitLoadToLocation` on parcel; Thread B `palletise`; no torn writes |
| `ParcelMonitorViewServiceConcurrencyIT` | `palletise_throwsWhenExistingPalletAlreadyOnCarrier_underLock` | Thread A assigns pallet to a truck carrier; Thread B `palletise` with same pallet name sees it under lock |
| `ParcelMonitorViewServiceConcurrencyIT` | `transferUnitLoadToCarrier_loosesWriteWithoutCallerHeldLock` | Negative: bypassing Fix C's lock allows concurrent mutation to win (proves the invariant from §3.0) |

### Manual test plan

| Scenario | Environment | Steps | Expected |
|---|---|---|---|
| Palletise happy path | staging | Select 3 cartons, click Palletise | Pallet created; OMS receives exactly one palletise event; order state = PALLETIZED in DB |
| Concurrent palletise (two operators, same cartons) | staging | Two operators palletise same 3 cartons within 1 second | Exactly one succeeds; the other sees "already finished" or HTTP 409; OMS event log shows one event per order |
| `palletiseAndTruckLoad` happy path | staging | Select cartons + BOL, click Palletise & Truck Load | Pallet created; BOL state = TRUCK_LOADING; OMS receives one event |
| Concurrent palletiseAndTruckLoad + closeBOL | staging | Operator A: palletiseAndTruckLoad on BOL X; Operator B: closeBOL on BOL X | One wins; the other sees a clean error; BOL state in DB consistent with the winning operation |
| SQL state baseline (24h post-deploy) | staging DB | `SELECT state, count(*) FROM customerorder WHERE state IN (650,670,680)` hourly | Counts grow at the same rate as pre-deploy baseline; no spike from duplicate state transitions |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| H2-based concurrency tests | H2 does not implement PostgreSQL `SELECT ... FOR UPDATE` row-blocking semantics |
| REST-layer e2e test | Service-level Testcontainers IT exercises the lock path; manual staging test covers REST path |
| Quantitative load test | Qualitatively assessed in §7. Deferred to post-deploy monitoring gate. |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Deadlock with `MobilePickingService` / `PickingorderBusinessService` (both lock customer orders) | High — transaction stall | Sort IDs ascending (both callers). PostgreSQL deadlock detector resolves within ~100ms. Monitor `wms2.transaction.lock.timeout`; alert at 1% rate. |
| Lock timeout during high-volume palletisation batch | Medium | `jakarta.persistence.lock.timeout=5000` configured. `BusinessException` surfaces as HTTP 409; operator retries. |
| `palletiseAndTruckLoad` is dead code — fix never exercised | Low | Fix regardless; concurrency IT pins the contract. |
| `processTransfer` recursion mutates unlocked child unit loads | Low | Outbound parcels are leaf nodes in this flow. Documented in §3.0 "Recursive boundary." |
| Future `REQUIRES_NEW` on `transferUnitLoadToCarrier` silently breaks Fix C | Medium | Code comment + AC7 negative test catches it in CI if the propagation changes. |
| Mobile UI does not surface HTTP 409 gracefully | Medium — UX | Manual staging test covers this path (§8). Fast-follow UI ticket if needed. |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Should BOL lock be acquired before or after customer-order locks? | **Before** (Fix D first) — BOL is the outermost carrier; locking it first prevents `closeBOL` crossover deadlock. |
| 2 | Should `entityManager.refresh()` be used after `findByIdForUpdate`? | **No** — `findByIdForUpdate` already returns DB-fresh state. `refresh()` is an unnecessary second round-trip. Executor may omit it. |
| 3 | Sequential vs. batch lock acquisition for customer orders? | **Sequential (Option S)** — N≤20, negligible cost difference, matches house style. Batch method deferred per R6. |
| 4 | Does Fix E apply to `palletiseAndTruckLoad`'s existing-pallet branch? | **No** — that branch unconditionally throws at line ~274. Fix E in `palletiseAndTruckLoad` applies only to the fresh-pallet create branch. |
| 5 | Does `transferUnitLoadToCarrier` need internal locking? | **No — caller owns the locks.** Invariant documented in §3.0; code comment added in Step 1. |

---

## 11. Known Follow-up Work

1. **Audit `transferUnitLoadToCarrier` callers** — `MobilePutAwayService`, `MobileMoveUnitloadService`, `MobileTruckLoadingService` all call this helper. Audit each for the caller-held-lock invariant (§3.0). Open a parent ticket.
2. **v1 paired plan** — if v1 audit confirms the same anti-pattern in `v1/wms-api`.
3. **Batch lock acquisition (Option B)** — revisit `findAllByIdInOrderByIdForUpdate` if N grows past 50.
4. **Cross-method lock ordering convention** — standardize BOL-first vs. orders-first across all BOL-touching flows as a system-wide ADR.

---

## 12. ADR — Architectural Decision Record

**Decision:** Apply pessimistic row locks (`PESSIMISTIC_WRITE` via `findByIdForUpdate`) on BOL (first),
Pallet, all CustomerOrders (sorted by id asc), and all Parcels at the head of `palletise` and
`palletiseAndTruckLoad`. The caller (`ParcelMonitorViewService`) owns the locks; the helper
`transferUnitLoadToCarrier` performs no locking.

**Drivers:**
1. Silent lost-updates and duplicate OMS notifications under concurrent operator palletisation.
2. House-style consistency with SBDEV-2223 / SBDEV-2228 / SBDEV-2229 (pessimistic, not optimistic).
3. Minimal blast radius: one service file + two test classes; no schema change, no migration, no feature flag.

**Alternatives considered:**

| Option | Rejected because |
|--------|-----------------|
| O1: Move locks INTO `transferUnitLoadToCarrier` | Helper has 8+ callers with different lock-ordering needs; forces all callers to share one ordering |
| O2: Add `@Version` column (optimistic locking) | `entity_lock` carries business-state values; schema migration required; doesn't solve cross-row TOCTOU |
| O3: Batch `findAllByIdInOrderByIdForUpdate` | Negligible perf gain at N≤20; adds new repo method; deferred |
| O4: `synchronized` / in-JVM lock | Fails across replicas (v2 runs multi-replica) |
| O5: Redis / ShedLock | Adds infra dependency for a problem the DB already solves |

**Consequences:**
- **Positive:** Silent corruption becomes observable HTTP 409 (operator retries).
- **Negative:** ~20ms hold-time increase per palletisation transaction at N=20.
- **Risk:** Future `REQUIRES_NEW` on `transferUnitLoadToCarrier` silently breaks Fix C (mitigated by code comment + AC7 negative test).

**Follow-ups:** Items 1–4 in §11.

---

## 13. Acceptance Criteria (for wms-tdd-gate)

**AC1 — `palletiseAndTruckLoad` BOL locked FIRST (Fix D)**
Unit test: `verify(billofladingRepository).findByIdForUpdate(bolId)` fires before any state inspection or save.

**AC2 — BOL state re-validated under lock; terminal state → throws (Fix D + R7)**
Concurrency IT: Thread A flips BOL to CLOSED, commits. Thread B `palletiseAndTruckLoad(stale BOL)` blocks at `FOR UPDATE`, re-reads state=CLOSED, throws `BusinessException`. No parcels mutated.

**AC3 — `customerOrderList` sorted by id BEFORE first `findByIdForUpdate` (Fix B + R5)**
Unit test: stubs `findByExternalIdList` returning IDs [7,3,5]. `InOrder` asserts `findByIdForUpdate(3)`, `findByIdForUpdate(5)`, `findByIdForUpdate(7)`.

**AC4 — All four entity types locked; old unlocked reads gone (Fixes B, C, D, E)**
```java
verify(billofladingRepository, times(1)).findByIdForUpdate(bolId);        // Fix D
verify(unitloadRepository,     atLeastOnce()).findByIdForUpdate(palletId); // Fix E
verify(customerorderRepository,times(N)).findByIdForUpdate(any());         // Fix B
verify(unitloadRepository,     times(N)).findByIdForUpdate(parcelIdN);     // Fix C
verify(unitloadRepository,     never()).findById(parcelId(any()));          // old L181/L184 gone
```

**AC5 — Global lock order matches §3.6 (R4)**
`grep -qE "// Lock acquisition order"` returns 0 in both method bodies. Verify-script LO-1.

**AC6 — Existing-pallet re-validation under lock (Fix E, `palletise` only)**
Unit test: stubs `findByLabelid` returning pallet with `carrierunitloadId=999`. `palletise` throws `BusinessException("Pallet already loaded...")`.

**AC7 — Lock invariant negative test: unprotected `transferUnitLoadToCarrier` loses writes (R3)**
Integration test: calls `transferUnitLoadToCarrier` without Fix C's parcel lock. Concurrent mutation shows the write can be lost. Proves Fix C is load-bearing.

**AC8 — Lock order comment present in both methods (R4)**
Verify-script check LO-1: `file_contains_n_times '// Lock acquisition order' "$PMV" 2`.

**AC9 — `LOG.warn` emitted when state advances under lock (R9)**
Concurrency IT: captures log output; asserts a line matching `state advanced.*under lock` appears when state moves between snapshot and lock.

**AC10 — Idempotent retry: clean rollback on stale-state rejection (R10)**
Concurrency IT: Thread B throws `BusinessException` from re-validation. A fresh retry of the same `parcelMonitorDTOSet` either succeeds (Thread A's mutation resolved contention) or throws again (correct). No partial state from the failed first attempt.

---

## 14. Implementation Status

_Implemented 2026-05-15 on branch `tasks/SBDEV-2232`._

```
v2 commit SHA(s): c57aced
Test results: 3920 tests, 0 failures, 0 errors, 67 skipped — BUILD SUCCESS (2026-05-15)
mvn verify result: BUILD SUCCESS (full suite mvn test)
verify-script result: 20/20 PASS
PR: https://github.com/SiteBossInc/wms2-api/pull/20 (target: develop)
```

Files changed:
- `src/main/java/net/aim_ai/wms/service/ParcelMonitorViewService.java` — Fixes D, E, B, C applied to both `palletise` and `palletiseAndTruckLoad`
- `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java` — comment corrections only (SBDEV-2232 §3.0)
- `src/test/java/net/aim_ai/wms/unit/service/ParcelMonitorViewServiceUnitTest.java` — updated all stubs to `findByIdForUpdate`; 5/5 gate tests pass
- `src/test/java/net/aim_ai/wms/integration/service/ParcelMonitorViewServiceConcurrencyIT.java` — new IT proving pessimistic lock prevents duplicate PALLETIZED write

---

## Completeness Checklist (Layer 2)

| # | Concern | Status |
|---|---|---|
| 0 | DB verified | ✓ db_verified: true — `entity_lock` confirmed non-`@Version`; `findByIdForUpdate` confirmed on all three repos; `lock.timeout=5000` confirmed |
| 1 | All callsites enumerated | ✓ §0 rows 1-9 all visited by Fixes A-E or explicitly excluded with rationale |
| 2 | Adjacent bugs | ✓ `palletiseAndTruckLoad` (rows 5-7) and `UnitloadBusinessService` children (§3.0 recursive boundary) |
| 3 | Backward compatibility | ✓ No API contract change; HTTP 409 path already handled by `RestExceptionHandler` (SBDEV-2230) |
| 4 | Concurrency | ✓ §3.0 global lock order; sorted-ID acquisition; `lock.timeout=5000`; AC7-AC10 |
| 5 | Multi-tenant | ✓ `@Transactional(value="tenantTransactionManager")` confirmed on both methods; tenant context set by HTTP filter |
| 6 | Error handling | ✓ `BusinessException` on stale-state re-validation rolls back via `rollbackFor`; `PessimisticLockingFailureException` → HTTP 409 |
| 7 | Observability | ✓ `LOG.warn` on state-advance-under-lock (R9); existing Micrometer `lock.timeout` counter |
| 8 | Rollback / migration | ✓ No DB change; single-JAR rollback; no data migration |
| 9 | Test coverage | ✓ Unit tests (AC3-AC6) + Concurrency IT (AC1-AC2, AC7-AC10) + manual smoke |
| 10 | Cross-version (v1↔v2) | ✓ v2 only; v1 audit ticket documented in §11 |
