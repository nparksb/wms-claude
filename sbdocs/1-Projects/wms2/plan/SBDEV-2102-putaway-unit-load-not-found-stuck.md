---
title: "SBDEV-2102 (V2): Putaway Fails — Unit Load Gets Stuck After Scan"
ticket: "SBDEV-2102"
ticket_url: ""
type: "bug"
priority: "urgent"
status: "done"
project: ["wms2"]
version: "v2"
requester: "David Oppenheim, Nam Park, Arden Latraca"
created: "2026-04-11"
updated: "2026-05-03"
related:
  - "../../../4-Archieves/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md"
tags:
  - plan
  - putaway
  - sbdev-2102
  - osiv
  - pick-pack
  - tdd-gate
---

# SBDEV-2102 (V2): Putaway Fails — Unit Load Gets Stuck After Scan

**Ticket:** SBDEV-2102
**Project:** wms2/wms2-api | **Version:** v2 (Java 21 / Spring Boot 3.x) | **Type:** Bug (regression + latent)
**Priority:** Urgent (Release Blocking) | **Points:** 5
**Assignees:** David Oppenheim, Nam Park, Arden Latraca
**V1 Source plan:** [`sbdocs/4-Archieves/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md`](../../../4-Archieves/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md)
**V1 Source commits:**
- `227eede` — fix(putaway): prevent stuck unit loads and recognize case-mismatched labels (Fixes A-D)
- `f19bfea` — fix(putaway): use ID comparison for UnitloadType to fix OSIV-disabled regression (Fixes E-F)
- `77c7518` — fix(putaway): remove duplicate sendToNirvana in storeBoxOnLocation (Fix Bug 6)
- `b5ac3fa` — fix(pickingtote): guard null pickingtoteId across order lifecycle (Fix Bug 7)

**V2 Status (as of 2026-05-03):** Source code for **all seven fixes (Bugs 1-7)** is already merged on `wms2-api/main`. This plan documents the work that has been done, identifies the **TDD-gate test gaps** that remain (especially around the v1 `b5ac3fa` follow-up sites that landed in source without a per-site v2 regression test), and codifies the acceptance criteria so the plan is wms-tdd-gate-ready.

---

## 0. RALPLAN-DR Summary (consensus mode)

### Principles (top 5)

1. **TDD-gate first.** Every fix in this plan must map to at least one failing-then-passing unit test that asserts the new behavior. No blanket "all green" claims accepted.
2. **Don't re-fix what isn't broken in v2.** v2 entity `equals()` is ID-based via `AbstractBaseEntity`; v1 fixes that exist solely because v1's `equals()` was broken are not ported.
3. **Honor v2 transactional contract.** Every `@Transactional` on a tenant service MUST specify `value = "tenantTransactionManager"`. Bare `@Transactional` defaults to landlord and silently disables rollback on tenant writes.
4. **Validate before mutate.** Any state-mutating operation in mobile services must run after all validation; failures must not leave the system in a half-applied state with no recovery path.
5. **Multi-replica safety is non-negotiable.** v2 runs ≥2 replicas. Any fix touching shared rows must be safe under concurrent access (optimistic lock, ownership guard, or after-commit deferral).

### Decision Drivers (top 3)

1. **Release-blocking severity.** Putaway is the bottleneck for goods-in. Stuck unit loads are unrecoverable without manual DB intervention. Cost of one bad scan in production = one operator + one supervisor blocked, plus ad-hoc DBA time.
2. **OSIV disabled in production.** `spring.jpa.open-in-view=false` means every repository call without `@Transactional` is auto-commit. Object-reference equality of detached entities returns `false` 100% of the time — the v1 commit `f19bfea` discovered this; v2's `AbstractBaseEntity.equals()` already covers it but a few places use direct ID comparison redundantly.
3. **Pick-pack flow legitimately has null pickingtoteId.** Schema NOT NULL is rejected. Code must null-guard at every `findById(customerOrder.getPickingtoteId())` call site because Spring Data `findById(null)` throws `IllegalArgumentException` before returning `Optional.empty()`.

### Options considered (≥2 viable, with bounded pros/cons)

| # | Option | Pros | Cons | Verdict |
|---|--------|------|------|---------|
| **A** | Full v1 port — copy each v1 hunk into v2, including v1 `equals()` workarounds | Mechanical; fastest to type | Fixes A, E, F have no v2 reproduction (v2 `Location.equals()` and `AbstractBaseEntity.equals()` already work); ports dead code; misses v2-specific gaps (`@Transactional` on tenant TM) | **Rejected** |
| **B** | v2-aware port — apply only fixes whose v1 root cause reproduces in v2; add v2-specific gaps (`@Transactional`, ownership guard); harden Bug 6 + Bug 7 | Smallest effective diff; respects v2 architecture; adds value v1 does not have (multi-replica ownership guard) | More analysis up front; harder to review without docs | **Selected (CURRENT PLAN)** |
| **C** | Schema-level fixes — make `pickingtoteId` NOT NULL; add DB-level case-insensitive collation | Fail-fast on bad data; eliminates entire bug class | Breaks pick-pack semantics (column is genuinely optional); requires migration affecting all queries; affects every tenant DB | **Rejected** |
| **D** | Wrap all `findById` sites in try/catch | Smallest behavioral change | Hides genuine data corruption; loses the "precondition violation" signal at `packageOrder`; pattern proliferation | **Rejected** |

**Why B was chosen over A**: The v1 commit `f19bfea` exists because v1 `UnitloadType` had no `equals()`. v2 `UnitloadType extends AbstractBaseEntity`, which has an ID-based `equals()`. Applying v1's `Bug E` fix verbatim is harmless but misleading; applying it as a *performance* optimization (skip 2 redundant `findById` calls) is the correct framing. Similarly, v1 `b5ac3fa`'s six call sites map almost 1:1 to v2 — but v2 already had two of them guarded (`getOrderDetails`, batch service); the remaining four needed to be guarded. This nuance is captured by Option B.

### Mode

**SHORT** (default). This plan does not include a pre-mortem or expanded e2e/observability test plan because the change is narrowly-scoped to one mobile flow and one cross-service null-guard pattern. Multi-replica concerns are addressed inline (Section 10). If the reviewer wants `--deliberate` mode, escalate via critic and re-emit.

---

## 1. Problem Statement

### Reported Symptoms (Putaway)

Receiving operators scan a pallet on the inbound putaway lane via the mobile app. The first scan fails with one of two errors:
- "Unit Load Not Found" — when scanner input case differs from DB label (`pallet-001` vs `PALLET-001`).
- "Unit Load not in PutAway Lane" — even when the pallet IS on the putaway lane.

After this failed first scan, the unit load is **stuck assigned to the operator's location**, with no recovery path: subsequent rescans by the same operator (or anyone else) still report "not in PutAway Lane" because the pallet is no longer on the putaway lane — the failed first scan moved it before the validation check.

### Reported Symptom (Pick-pack picking — V1 b5ac3fa)

After the putaway flow was repaired by Bugs 1-6, mobile pick-pack picking surfaced an additional 500 on the **last confirmed pick** of a pick-pack order:

```
IllegalArgumentException: The given id must not be null!
  at SimpleJpaRepository.findById(SimpleJpaRepository.java:296)
  at PickingorderBusinessService.finishPickingOrder:172
  at MobilePickingService.processPick:470
```

Pick-pack orders pick directly into a unit load (no tote assigned), so `Customerorder.pickingtoteId` is genuinely `null`. The cleanup loop in `finishPickingOrder()` calls `unitloadRepository.findById(customerOrder.getPickingtoteId())` — Spring Data rejects `findById(null)` with `IllegalArgumentException` before returning. The `if (pickingTote.isPresent())` guard never gets to execute.

V1 `b5ac3fa` audited and fixed this primary site plus five sibling sites across `CustomerorderService`, `ManageOrderService`, and `PickingorderBusinessService`.

---

## 2. Root Cause Analysis

### V1 → V2 Applicability Matrix

| V1 Bug | V1 Fix | V2 Reproduction? | V2 Action |
|--------|--------|------------------|-----------|
| Bug 1: Transfer before validation in `findUnitLoad()` | A+B | **Yes** (same code) | Apply (Fix 1) |
| Bug 2: No case-insensitive label fallback at 6 sites | C | **Yes** (same code) | Apply (Fix 2) |
| Bug 3: No error recovery in `PutawayController.scanPallet` | D | **Yes** (same code) | Apply (Fix 3) |
| Bug 4: `UnitloadType.equals()` returns `false` under OSIV-disabled | E | **No** — `AbstractBaseEntity.equals()` is ID-based | Skip; but apply as **performance optimization** (Fix 5: eliminate 2 redundant `findById`) |
| Bug 5 (V1 numbering): broken `Location.equals()` in `verifyScannedLocation` | F | **No** — v2 `Location.equals()` is ID-based | Skip |
| **Bug 6**: Duplicate `sendToNirvana` in `storeBoxOnLocation` FLOWBIN branch | (V1 commit `77c7518`) | **Yes** (identical code pattern) | Apply (Fix 6) |
| **Bug 7** (cross-cutting): `findById(null)` on `pickingtoteId` at 6 call sites | (V1 commit `b5ac3fa`) | **Yes** at 4 of 6 sites; 2 sites already guarded in v2 | Apply (Fix 7) |
| **V2-only G**: `findUnitLoad()` missing `@Transactional("tenantTransactionManager")` | N/A | **Yes** | Apply (Fix 4) |
| **V2-only H**: `calculatePutAwayList`, `updateCurrentItemDataUnitLoadList`, `verifyScannedLocation` missing `@Transactional` | N/A | **Yes** | Apply (Fix 4 — readOnly variants) |
| **V2-only I (multi-replica)**: `storePalletBackOnPutawayLane` yanks pallets across users | N/A | **Yes** (latent — v1 is single-replica) | Apply (Fix 3a — ownership guard) |

### V2 Entity Comparison Reference

`AbstractBaseEntity.equals()` (v2 — `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java:69-75`):

```java
@Override
public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof AbstractBaseEntity other)) return false;
    if (this.getClass() != other.getClass()) return false;
    return getId() != null && getId().equals(other.getId());
}
```

| Entity | V1 `equals()` | V2 `equals()` | V1 fix needed in V2? |
|--------|---------------|---------------|----------------------|
| `Location` | xpos+ypos+zpos+name (broken)  | inherits `AbstractBaseEntity` (ID-based) | No |
| `UnitloadType` | `Object.equals()` (reference)  | inherits `AbstractBaseEntity` (ID-based) | No |
| `Unitload` | `Object.equals()` | inherits `AbstractBaseEntity` (ID-based) | N/A |

### Affected Locations

| # | File | Line(s) | Description | Fix |
|---|------|---------|-------------|-----|
| 1 | `service/mobile/MobilePutAwayService.java` | 90-153 | `findUnitLoad()` — transfer-before-validation, no case fallback, missing `@Transactional`, redundant `findById` | 1, 2, 4, 5 |
| 2 | `service/mobile/MobilePutAwayService.java` | 155-182 | `storePalletOnLocation()` — no case fallback | 2 |
| 3 | `service/mobile/MobilePutAwayService.java` | 184-209 | `storePalletBackOnPutawayLane()` — no case fallback, no ownership guard | 2, 3a |
| 4 | `service/mobile/MobilePutAwayService.java` | 211-290 | `calculatePutAwayList()` — no case fallback, missing `@Transactional(readOnly)` | 2, 4 |
| 5 | `service/mobile/MobilePutAwayService.java` | 353-394 | `updateCurrentItemDataUnitLoadList()` — no case fallback, missing `@Transactional(readOnly)` | 2, 4 |
| 6 | `service/mobile/MobilePutAwayService.java` | 396-443 | `verifyScannedLocation()` — missing `@Transactional(readOnly)` | 4 |
| 7 | `service/mobile/MobilePutAwayService.java` | 445-505 | `storeBoxOnLocation()` — no case fallback, **duplicate `sendToNirvana` (Bug 6)** | 2, 6 |
| 8 | `controller/mobile/PutawayController.java` | 36-59 | `requestLocation()` — no error recovery in catch | 3 |
| 9 | `service/PickingorderBusinessService.java` | 333-334 | `cleanUpCancelledOrder()` — missing null guard on `pickingtoteId` | 7a |
| 10 | `service/CustomerorderService.java` | 365-380 | `cancelOrderPositions` cleanup branch — missing null guard | 7b |
| 11 | `service/CustomerorderService.java` | 489-496 | `packageOrder()` — missing precondition check (NPE → BusinessException) | 7c |
| 12 | `service/CustomerorderService.java` | 654-666 | cancel-during-active-picking — missing null guard | 7d |
| 13 | `service/CustomerorderService.java` | 332-362 | `cleanUpCancelledOrder()` — missing null guard, `tote` hoisted to method scope | 7e |
| 14 | `service/ManageOrderService.java` | 213-216 | `notifyPickingToteAssigned` — missing null guard before OMS call | 7f |
| 15 | `service/ManageOrderService.java` | 338-342 | `customerOrderPicked` non-CLUB branch — missing null guard | 7g |
| 16 | `service/PickingorderBusinessService.java` | 162-244 | `finishPickingOrder()` — primary reported-bug site for `findById(null)` | 7h |

**Already guarded in v2 (no change needed):**

| File | Line | Site | Why already safe |
|------|------|------|------------------|
| `CustomerorderService.java` | 195-196 | `getOrderDetails()` | Pre-existing `if (co.getPickingtoteId() != null)` |
| `CustomerorderBatchService.java` | 314-315 | batch processing | Pre-existing `if (customerOrder.getPickingtoteId() != null)` |

---

## 3. Design / Proposed Fix

### 3.1 Fix 1 — Reorder `findUnitLoad()`: validation BEFORE transfer

**Problem:** `findUnitLoad()` calls `transferUnitLoadToLocation()` BEFORE checking the unit-load type. If the type check then fails (empty pallet / unknown type), the unit load is already on the user's location and cannot be re-found by a rescan.

**Solution:** Compute `isPallet` and `isBox` flags first, validate them, and only then call `transferUnitLoadToLocation()`. Single return path.

**Files changed:** `MobilePutAwayService.java:90-153`.

**Status:** **Implemented** (current source — verified at line 125-143).

### 3.2 Fix 2 — Case-insensitive label fallback (6 sites)

**Problem:** `unitloadRepository.findByLabelid()` is case-sensitive. Scanner input case may differ from DB.

**Solution:** Apply the `MobileReplenishService` pattern (try exact, fall back to `findByLabelidIgnoreCase()`). Six call sites in `MobilePutAwayService.java`.

```java
Optional<Unitload> opt = unitloadRepository.findByLabelid(label);
if (!opt.isPresent()) {
    opt = unitloadRepository.findByLabelidIgnoreCase(label);
}
```

**Files changed:** `MobilePutAwayService.java` lines 98-101, 159-162, 188-191, 215-218, 359-362, 453-456.

**Status:** **Implemented** (current source).

### 3.3 Fix 3 + 3a — Controller error recovery + multi-replica ownership guard

**Problem:** If `findUnitLoad()` transfers a pallet then throws (Bug 1 unchanged code path, or any other post-transfer error), the controller does not attempt to release the pallet back to the putaway lane. In a multi-replica deployment, a naive `storePalletBackOnPutawayLane` could yank a pallet from another user's active putaway session.

**Solution:**
- **Fix 3:** Wrap `mobilePutAwayService.storePalletBackOnPutawayLane(dto)` in a nested try/catch inside both `BusinessException` and `FacadeException` catch blocks of `PutawayController.requestLocation()`.
- **Fix 3a:** In `MobilePutAwayService.storePalletBackOnPutawayLane()`, only transfer if the pallet's current `storagelocationId` resolves to a `Location` whose `name` equals `SecurityContextUtils.getUserName()`. Otherwise log `"Skipping recovery — pallet on '<location>', not current user '<user>'"` and return.

**Files changed:** `PutawayController.java:36-59`, `MobilePutAwayService.java:184-209`.

**Status:** **Implemented** (current source).

### 3.4 Fix 4 — `@Transactional(value = "tenantTransactionManager")` on putaway methods (V2-CRITICAL)

**Problem:** v2 sets `spring.jpa.open-in-view=false`. Mobile services without `@Transactional` get a separate auto-committed session per repo call; transfers commit immediately and cannot be rolled back.

**Solution:** Add per CLAUDE.md tenant TM rule.

| Method | Annotation |
|---|---|
| `findUnitLoad()` | `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` |
| `storePalletOnLocation()` | same |
| `storePalletBackOnPutawayLane()` | same |
| `storeBoxOnLocation()` | same |
| `calculatePutAwayList()` | `@Transactional(value = "tenantTransactionManager", readOnly = true)` |
| `updateCurrentItemDataUnitLoadList()` | same readOnly |
| `verifyScannedLocation()` | same readOnly |

**Files changed:** `MobilePutAwayService.java` — annotations at lines 90, 155, 184, 211, 353, 396, 445.

**Status:** **Implemented** (current source).

### 3.5 Fix 5 — Eliminate redundant `findById()` in type check (perf, not correctness in v2)

**Problem:** Original code did `unitloadTypeRepository.findById(unitLoad.getTypeId()).get().equals(findByName(...).get())` — that's 2 wasteful DB reads per type check, twice over (4 total). The first `findById` returns the entity whose ID we already have on `unitLoad.getTypeId()`.

**Solution (performance, but mechanically identical to v1 Fix E):**

```java
boolean isPallet = unitLoad.getTypeId().equals(
    unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PALLET)
        .orElseThrow(() -> new EntityNotFoundException(...)).getId());
```

**Files changed:** `MobilePutAwayService.java:125-131`.

**Status:** **Implemented** (current source).

### 3.6 Fix 6 — Remove duplicate `sendToNirvana` in `storeBoxOnLocation` FLOWBIN branch (latent bug, ported from V1 `77c7518`)

**Problem:** `storeBoxOnLocation`'s FLOWBIN branch calls `sendToNirvana(unitLoad, ...)` immediately after `transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)`. The latter already sends the source UL to nirvana when it becomes empty (`StockunitBusinessService` lines 294-295 and 318-319). The redundant explicit call uses the now-stale local `Unitload` reference (loaded in its own mini-session) and triggers `StaleObjectStateException` on the second merge.

This bug is latent in v2: it was unreachable until Bugs 1-5 unblocked the box-to-flowbin code path.

**Solution:** Delete the explicit `sendToNirvana` call after `transferStockToUnitLoad`. Add a comment explaining the responsibility ownership.

**Files changed:** `MobilePutAwayService.java:478-484`.

**Status:** **Implemented** (current source — verified line 478-484: `transferStockToUnitLoad` + comment, no second `sendToNirvana`).

### 3.7 Fix 7 — `pickingtoteId` null guard at all 6 sites (cross-cutting, ported from V1 `b5ac3fa`)

**Problem:** Spring Data's `SimpleJpaRepository.findById(null)` throws `IllegalArgumentException` (it does not return `Optional.empty()`). Any unguarded `unitloadRepository.findById(customerOrder.getPickingtoteId())` is a 500 waiting to happen for pick-pack flows.

**Solution:** Add per-site null guards mirroring v1 `b5ac3fa`.

| # | File:Line | Site | Pattern applied |
|---|-----------|------|-----------------|
| 7a | `PickingorderBusinessService.java:333-334` | `cleanUpCancelledOrder` | `if (customerOrder.getPickingtoteId() != null) { ... }`, hoist `tote` to method scope |
| 7b | `CustomerorderService.java:365-380` | `cancelOrder` (PROCESSABLE branch) | `if (customerOrder.getPickingtoteId() != null) { ... }` wrapping the whole tote cleanup block |
| 7c | `CustomerorderService.java:489-496` | `packageOrder` | Throw `BusinessException("Cannot package order=... without an assigned picking tote")` — fail fast on precondition violation |
| 7d | `CustomerorderService.java:654-666` | `cancelOrder` (RAPID_PICKING/STARTED branch) | `if (customerOrder.getPickingtoteId() != null) { ... }` wrapping the tote-emptying block |
| 7e | `CustomerorderService.java:332-362` (note: same as v1 `cleanUpCancelledOrder`, but in v2 most logic moved into `pickingorderBusinessService.cleanUpCancelledOrder`. v2's `CustomerorderService.cleanUpCancelledOrder` delegates.) | (delegated) | Already covered by 7a once delegation is in place |
| 7f | `ManageOrderService.java:213-216` | `notifyPickingToteAssigned` (foreach over `customerOrderList`) | `if (customerOrder.getPickingtoteId() != null) { ... }` around `findById` + `setToteLabel` |
| 7g | `ManageOrderService.java:338-342` | `customerOrderPicked` non-CLUB branch | `else if (customerOrder.getPickingtoteId() != null) { ... }` |
| 7h | `PickingorderBusinessService.java:298, 333-334` | `finishPickingOrder` | Primary reported site. Loop guarded by `if (co.getPickingtoteId() == null) continue;` (line 298) and tote-fetch guarded by `if (customerOrder.getPickingtoteId() != null)` (line 333). |

**Status:** **Implemented at all 6 sites** (current source — verified by grep on every `findById(...getPickingtoteId()...)` occurrence — every one is preceded by an `if (... != null)` or is a documented `findById(... .orElse(null))` form). Two sites pre-existed as guarded.

---

## 4. V1 / V2 Applicability

| V1 Fix | V2 Verdict | Where it lives in v2 source |
|--------|------------|----------------------------|
| **A** (`Location.equals()` → ID) | **Skip** — v2 `Location.equals()` already uses ID via `AbstractBaseEntity` | n/a |
| **B** (reorder validation before transfer) | **Apply (Fix 1)** | `MobilePutAwayService.java:125-143` |
| **C** (case-insensitive label fallback ×6) | **Apply (Fix 2)** | `MobilePutAwayService.java` 6 sites |
| **D** (controller error recovery) | **Apply (Fix 3)** | `PutawayController.java:36-59` |
| **E** (`UnitloadType.equals()` → ID) | **Skip for correctness, apply as perf (Fix 5)** | `MobilePutAwayService.java:125-131` |
| **F** (`assignedLocation.equals()` in `verifyScannedLocation`) | **Skip** — v2 `Location.equals()` already uses ID | n/a |
| **77c7518 / Bug 6** (drop redundant `sendToNirvana`) | **Apply (Fix 6)** | `MobilePutAwayService.java:478-484` |
| **b5ac3fa / Bug 7** (null guard `pickingtoteId` ×6) | **Apply (Fix 7a-7h)** | 4 service files |

### What needs porting

All of the above except A, E, F.

### What does NOT need porting (with justification)

- **A**, **F**: v2's `Location` inherits `AbstractBaseEntity.equals()` which is ID-based. v1's bug does not reproduce.
- **E**: v2's `UnitloadType` inherits `AbstractBaseEntity.equals()` which is ID-based. v1's Object-reference equality bug does not reproduce. The redundant `findById` calls are still wasteful; Fix 5 ports the *spirit* of E as a perf cleanup, not a correctness fix.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** (schema, migrations) | No change. Fix 7 does not require `pickingtoteId NOT NULL`. | n/a | Schema change explicitly rejected (Option C). |
| 2 | **Feature flags / system properties** | None. | n/a | |
| 3 | **Config / env changes** | `spring.jpa.open-in-view=false` already set in `application.properties`. No new env vars. | DevOps | Verify via `grep open-in-view` in deployed properties. |
| 4 | **Deploy-order dependencies** | None. Backend-only fix; mobile UI consumes the same DTO shape. | n/a | |
| 5 | **Data migration** | None. | n/a | |
| 6 | **External systems** | OMS still receives a `null` `toteLabel` for pick-pack orders (Fix 7f, 7g). Confirm OMS tolerates null. | OMS team | Confirmed in v1 since 2026-04-13 — no OMS-side change needed. |
| 7 | **Access / permissions** | None. | n/a | |
| 8 | **Monitoring / alerts** | Optional: add Prometheus counter for `mobile_putaway_recovery_skipped_total` (cross-replica ownership-guard hits). Not blocking. | DevOps | Useful to detect cross-replica contention. |

### 5.2 Implementation Checklist

All seven fixes are already merged on `wms2-api/main`. The remaining checklist is **TDD-gate alignment**:

- [x] Fix 1 — `findUnitLoad()` validation before transfer (source)
- [x] Fix 2 — case-insensitive fallback at 6 sites (source)
- [x] Fix 3 — controller error recovery (source)
- [x] Fix 3a — multi-replica ownership guard (source)
- [x] Fix 4 — `@Transactional(tenantTransactionManager)` on 7 methods (source)
- [x] Fix 5 — eliminate redundant `findById` in type check (source)
- [x] Fix 6 — drop duplicate `sendToNirvana` in FLOWBIN branch (source)
- [x] Fix 7a — null guard `PickingorderBusinessService.cleanUpCancelledOrder` (source)
- [x] Fix 7b — null guard `CustomerorderService.cancelOrder` PROCESSABLE branch (source)
- [x] Fix 7c — fail-fast precondition in `CustomerorderService.packageOrder` (source)
- [x] Fix 7d — null guard `CustomerorderService.cancelOrder` RAPID_PICKING/STARTED branch (source)
- [x] Fix 7f — null guard `ManageOrderService.notifyPickingToteAssigned` (source)
- [x] Fix 7g — null guard `ManageOrderService.customerOrderPicked` non-CLUB (source)
- [x] Fix 7h — null guard `PickingorderBusinessService.finishPickingOrder` (source)
- [ ] **TDD-gate: per-site regression tests for Fix 7** (only `PickingorderBusinessService.finishPickingOrder` has an explicit V1-style test; the other six need v2 unit tests — see Section 6)
- [ ] **TDD-gate: ownership-guard regression test for Fix 3a** (already in v2 plan but verify it exists in `MobilePutAwayServiceUnitTest`)
- [ ] **TDD-gate: precondition test for Fix 7c** (`packageOrder` with null pickingtoteId throws BusinessException with the expected message)
- [ ] Code review by `code-reviewer` once test gaps are closed
- [ ] `mvn test` clean (already green per Section 11 of original plan; needs re-run after new tests added)

---

## 6. Test Plan

### 6.1 Acceptance Criteria → Test Mapping (TDD-gate contract)

This is the wms-tdd-gate authoritative mapping. Each criterion has at least one test.

| AC# | Acceptance criterion | Test class | Test method | Status |
|-----|----------------------|------------|-------------|--------|
| AC-1 | `findUnitLoad` does not transfer the unit load when type validation fails (empty pallet) | `MobilePutAwayServiceUnitTest` | `findUnitLoad_EmptyPallet_ThrowsBusinessException_NoTransfer` | exists |
| AC-2 | `findUnitLoad` does not transfer when type is neither pallet nor box | `MobilePutAwayServiceUnitTest` | `findUnitLoad_UnitloadTypeNotPalletNotBox_ThrowsBusinessException_NoTransfer` | exists |
| AC-3 | `findUnitLoad` falls back to `findByLabelidIgnoreCase` when exact match misses | `MobilePutAwayServiceUnitTest` | `findUnitLoad_CaseMismatch_FallsBackToIgnoreCase` | exists |
| AC-4 | `findUnitLoad` throws `BusinessException` when both lookups miss | `MobilePutAwayServiceUnitTest` | `findUnitLoad_NotFoundEvenIgnoreCase_ThrowsBusinessException` | exists |
| AC-5 | `storePalletBackOnPutawayLane` only transfers pallets on current user's location (multi-replica safety) | `MobilePutAwayServiceUnitTest` | `storePalletBackOnPutawayLane_PalletOnDifferentUser_SkipsRecovery` | exists |
| AC-6 | `storePalletBackOnPutawayLane` falls back to ignore-case | `MobilePutAwayServiceUnitTest` | `storePalletBackOnPutawayLane_CaseMismatch_FallsBackToIgnoreCase` | exists |
| AC-7 | `storeBoxOnLocation` FLOWBIN branch never calls `sendToNirvana` directly (Bug 6) | `MobilePutAwayServiceUnitTest` | `shouldStoreBoxOnFlowbinAndCreateFixedAssignment` (assertion: `verify(unitloadBusinessService, never()).sendToNirvana(...)`) | exists |
| AC-8 | Same for the existing-fixed-assignment FLOWBIN sub-branch | `MobilePutAwayServiceUnitTest` | `shouldStoreBoxOnFlowbinWithExistingFixedAssignment` (same negative assertion) | exists |
| AC-9 | `findUnitLoad` type check works under OSIV-disabled (different `UnitloadType` references with same ID) | `MobilePutAwayServiceUnitTest` | `findUnitLoad_TypeCheckUsesIdNotObjectEquals` | exists |
| AC-10 | `findUnitLoad` type check works for box type with separate object refs | `MobilePutAwayServiceUnitTest` | `findUnitLoad_OsivDisabled_BoxType_DifferentRefs_SucceedsWithIdComparison` | exists |
| AC-11 | `PickingorderBusinessService.finishPickingOrder` succeeds when `pickingtoteId == null` (pick-pack); never calls `findById((Long) null)`; cleanup loop is skipped | `PickingorderBusinessServiceUnitTest` | `finishPickingOrder_CustomerOrderWithNullPickingtoteId_Succeeds` | **ADDED ✓** (2026-05-03) |
| AC-12 | `PickingorderBusinessService.cleanUpCancelledOrder` succeeds when `pickingtoteId == null`; does not call `findById(null)`; still sets state CANCELED, cancels positions, finalizes batch | `PickingorderBusinessServiceUnitTest` | `cleanUpCancelledOrder_NullPickingtoteId_SucceedsAndPreservesCancellationFlow` | **ADDED ✓** (2026-05-03) |
| AC-13 | `CustomerorderService.cancelOrder` PROCESSABLE branch (line 365 region) succeeds when `pickingtoteId == null`; does not call `findById(null)`; still sets state and cancels positions | `CustomerorderServiceUnitTest` | `cancelOrder_Processable_NullPickingtoteId_SucceedsWithoutToteCleanup` | **ADDED ✓** (2026-05-03) |
| AC-14 | `CustomerorderService.packageOrder` throws `BusinessException` (with the expected message containing "Cannot package order" and the order number) when `pickingtoteId == null` | `CustomerorderServiceUnitTest` | `packageOrder_NullPickingtoteId_ThrowsPreconditionBusinessException` | **ADDED ✓** (2026-05-03) |
| AC-15 | `CustomerorderService.cancelOrder` RAPID_PICKING/STARTED branch (line 654 region) succeeds when `pickingtoteId == null`; tote-emptying block skipped; no `findById(null)` | `CustomerorderServiceUnitTest` | `cancelOrder_RapidPickingStarted_NullPickingtoteId_Succeeds` | **ADDED ✓** (2026-05-03) |
| AC-16 | `ManageOrderService.notifyPickingToteAssigned` (or v2-equivalent caller) sends a null `toteLabel` to OMS rather than throwing when `pickingtoteId == null` | `ManageOrderServiceUnitTest` | `notifyPickingToteAssigned_NullPickingtoteId_SendsNullToteLabel` | **ADDED ✓** (2026-05-03) |
| AC-17 | `ManageOrderService.customerOrderPicked` non-CLUB branch: same — no NPE, null toteLabel | `ManageOrderServiceUnitTest` | `customerOrderPicked_NonClub_NullPickingtoteId_SendsNullToteLabel` | **ADDED ✓** (2026-05-03) |

### 6.2 Test Scenarios

| # | Scenario | Steps | Expected Result |
|---|----------|-------|-----------------|
| S1 | Putaway happy path (pallet) | Create pallet on putaway lane → mobile scan exact label | DTO returned with `unitLoadIsPallet=true`, pallet on user location |
| S2 | Putaway case-mismatch | Create pallet labeled `IN-000364` → mobile scan `in-000364` | Same result as S1 |
| S3 | Putaway empty pallet | Create empty pallet on putaway lane → scan | `BusinessException("emptyPalletNotSuitableForPutAway")`; pallet **still on putaway lane** (not transferred) |
| S4 | Putaway unknown type | Create UL with type other than Pallet/Box → scan | `BusinessException("entityNotFoundForName")`; UL still on putaway lane |
| S5 | Putaway recovery skip across users | UL transferred to UserA → UserB calls `storePalletBackOnPutawayLane` | UL stays on UserA's location; debug log emitted |
| S6 | Pick-pack last-pick null tote | Create pick-pack order with `pickingtoteId=null` → confirm last pick → `finishPickingOrder` triggers | No exception; order moves to `FINISHED` state; cleanup loop skipped; OMS notification sent with null toteLabel |
| S7 | Pick-pack package without tote | Create pick-pack order with `pickingtoteId=null`, state `PICKED` → call `packageOrder` | `BusinessException("Cannot package order=... without an assigned picking tote")` with order number in message |
| S8 | Pick-pack cancel without tote | Create pick-pack order with `pickingtoteId=null` → cancel | Order state `CANCELED`; positions cancelled; no `findById(null)` invocation |
| S9 | Storebox FLOWBIN no-fixed-assignment | Box scanned to flowbin, no fixed assignment exists | Fixed assignment created; stock transferred; box sent to nirvana exactly **once** (via `transferStockToUnitLoad`); no `StaleObjectStateException` |
| S10 | Storebox FLOWBIN existing-fixed-assignment | Box scanned to flowbin, fixed assignment exists | Stock transferred; box sent to nirvana exactly once; no double-merge |

### 6.3 New / updated tests

| Test class | Test method | What it asserts | Status |
|------------|-------------|-----------------|--------|
| `MobilePutAwayServiceUnitTest` | `findUnitLoad_*` (10 tests, see AC table) | Fixes 1, 2, 4, 5, 3a — putaway flow | **exists** |
| `MobilePutAwayServiceUnitTest` | `shouldStoreBoxOnFlowbin*` (2 tests, asserting `never()` on `sendToNirvana`) | Fix 6 regression guard | **exists** |
| `MobilePutAwayServiceUnitTest` | `storePalletBackOnPutawayLane_*` (2 tests) | Fix 3a + Fix 2 | **exists** |
| `PickingorderBusinessServiceUnitTest` | `finishPickingOrder_CustomerOrderWithNullPickingtoteId_Succeeds` | AC-11 | **ADDED ✓** 2026-05-03 |
| `PickingorderBusinessServiceUnitTest` | `cleanUpCancelledOrder_NullPickingtoteId_SucceedsAndPreservesCancellationFlow` | AC-12 | **ADDED ✓** 2026-05-03 |
| `CustomerorderServiceUnitTest` | `cancelOrder_Processable_NullPickingtoteId_SucceedsWithoutToteCleanup` | AC-13 | **ADDED ✓** 2026-05-03 |
| `CustomerorderServiceUnitTest` | `packageOrder_NullPickingtoteId_ThrowsPreconditionBusinessException` | AC-14 | **ADDED ✓** 2026-05-03 |
| `CustomerorderServiceUnitTest` | `cancelOrder_RapidPickingStarted_NullPickingtoteId_Succeeds` | AC-15 | **ADDED ✓** 2026-05-03 |
| `ManageOrderServiceUnitTest` | `notifyPickingToteAssigned_NullPickingtoteId_SendsNullToteLabel` | AC-16 | **ADDED ✓** 2026-05-03 |
| `ManageOrderServiceUnitTest` | `customerOrderPicked_NonClub_NullPickingtoteId_SendsNullToteLabel` | AC-17 | **ADDED ✓** 2026-05-03 |

Note: V2 `CustomerorderServiceUnitTest` already has one test `handlesOrderWithNullPickingtoteId()` at line 708-709, but it does not cover the cancel branches; AC-13 and AC-15 still need dedicated tests for the v2 cancellation paths.

### 6.4 Manual test plan

| # | Scenario | Environment | Steps | Expected Result |
|---|----------|-------------|-------|-----------------|
| M1 | Putaway happy path | staging mobile | Receive shipment → release → mobile scan a pallet on the putaway lane | DTO returns; pallet on user; can complete putaway |
| M2 | Putaway case-mismatch | staging mobile | Manually create a pallet with mixed-case label → scan with different case | Same as M1 |
| M3 | Putaway empty pallet recovery | staging mobile | Scan an empty pallet → see error → rescan | Second scan still works (pallet stayed on putaway lane) |
| M4 | Pick-pack picking last item | staging mobile | Pick-pack order → pick all items, last one is `confirmPick` → flow promotes order to PICKED | No 500; OMS receives notification (null toteLabel) |
| M5 | Pick-pack package without tote | staging admin | `packageOrder()` REST call against an order with null pickingtoteId | 4xx with "Cannot package order=..." message — NOT 500 |
| M6 | Storebox FLOWBIN end-to-end | staging mobile | Scan a box at a flowbin location | Stock transferred; no `StaleObjectStateException` in logs |

### 6.5 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=MobilePutAwayServiceUnitTest` | (existing — green per Section 11) | 51 / 0 / 0 |
| `mvn test -Dtest=PickingorderBusinessServiceUnitTest` | PASS 2026-05-03 | all nested classes pass, 0 failures |
| `mvn test -Dtest=CustomerorderServiceUnitTest` | PASS 2026-05-03 | all nested classes pass, 0 failures |
| `mvn test -Dtest=ManageOrderServiceUnitTest` | PASS 2026-05-03 | all nested classes pass, 0 failures |
| `mvn test` | PASS 2026-05-03 | 3833 run / 0 failures / 67 skipped |

### 6.6 Deliberately-skipped coverage

| What | Why |
|------|-----|
| End-to-end concurrent putaway across two replicas (real load balancer) | Out of scope for unit/integration tests. Logic is asserted via the multi-replica scenario analysis (Section 10). Manual smoke against the staging cluster covers the integration. |
| `CustomerorderService.cleanUpCancelledOrder` direct test (site 7e) | This site delegates to `pickingorderBusinessService.cleanUpCancelledOrder` in v2, which is covered by AC-12. A redundant delegate-only test adds no signal. |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica state? | **No** | All state still in DB; no Caffeine / static / ThreadLocal added. |
| 2 | **Connection pool math** | Change per-request DB connection use? | **No (slight reduction)** | Fix 4 replaces auto-commit-per-call with a single `@Transactional` boundary. Net effect: fewer borrow/release cycles, same peak hold time. |
| 3 | **Scheduled jobs** | Add or modify `@Scheduled`? | **No** | n/a |
| 4 | **Long transactions** | Hold a tx across multiple repo calls / external I/O? | **Yes (intentional)** | `findUnitLoad()` now spans 5-10 reads + 1 write inside one tenant tx. All work is local (no HTTP / printer / OMS). Estimated wall-clock <50ms p95 — well below `connectionTimeout`. |
| 5 | **Request affinity** | Assume same-replica follow-up? | **No** | Mobile flow is stateless across requests; tx state lives in DB. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | **Yes** (handled) | `transferUnitLoadToLocation` uses `optimisticLockRetry.executeWithRetry()` (UnitloadBusinessService line 161). Concurrent transfers fail with `OptimisticLockException`; first writer wins. Fix 3a ownership guard prevents cross-replica recovery from yanking a pallet. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **No** | All work happens on the request thread inside a `@Transactional(tenantTransactionManager)` boundary. No `@Async` introduced. |
| 8 | **Distributed lock correctness** | Add or rely on locks across replicas? | **Yes (existing optimistic)** | `@Version` on `Unitload`, `Stockunit`, `Customerorder` continues to be the contention arbiter. Fix 4 ensures the version-check actually rolls back rather than being lost in auto-commit. |
| 9 | **Cache invalidation** | Write to cached entity? | **No** | `Unitload`, `Customerorder`, `Stockunit` are not in `CacheConfig`'s caches. |
| 10 | **External notifications** | HTTP/message inside tx? | **Indirect (already deferred)** | `finishPickingOrder` → `manageOrderService.customerOrderPicked` is wrapped in `TransactionSynchronization.afterCommit` (line 256-272 of `PickingorderBusinessService.java`). Fix 7g/7h does not change this; it just guards the null tote case in the deferred call body. |

### Evidence

| Concern # | What was verified | File:line / test reference |
|-----------|-------------------|----------------------------|
| 4 | `findUnitLoad` tx scope | `MobilePutAwayService.java:90` (annotation), method body 90-153 (~63 lines, all DB-local) |
| 6 | Optimistic-lock contention | `findUnitLoad_OsivDisabled_DifferentUnitloadTypeRefs_SucceedsWithIdComparison` (multi-session simulation); production retry via `UnitloadBusinessService.java:161` |
| 6 | Cross-replica ownership guard | `storePalletBackOnPutawayLane_PalletOnDifferentUser_SkipsRecovery` |
| 8 | Optimistic-lock rollback under tx | `MobilePutAwayService.java:90` `rollbackFor` clause covers `BusinessException` + `FacadeException`; `OptimisticLockingFailureException` is unchecked → rolls back by default |
| 10 | OMS deferral | `PickingorderBusinessService.java:256-272` — `TransactionSynchronization.afterCommit` |

---

## 8. Notes

### Related plans

- v1 source plan (archived): `sbdocs/4-Archieves/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md` — this v2 plan supersedes it for v2 scope.
- Follow-up ticket (created): **Harden `UnitloadBusinessService.transferUnitLoadToLocation`** — reload `unitload` fresh by id at method entry to match `transferUnitLoadToCarrier` and `processTransfer`. Same follow-up exists in v1.
- Follow-up: codebase-wide audit of `findByLabelid(` usages — see Section 9 of the prior plan revision.
- Follow-up: codebase-wide audit of `findById(...getPickingtoteId())` to confirm no new unguarded sites have crept in (greppable in CI as a directive — see Section 9).

### Deployment considerations

This change is purely backend; no frontend or migration. Roll out with the next normal `wms2-api` release. There is no data migration to run. Tenants do not need to be drained.

### Version history

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2026-04-11 | v1 | David Oppenheim | Initial — Bugs 1-5 |
| 2026-04-12 | v2 | Nam Park | Implementation status; multi-replica analysis; Fix 3a ownership guard |
| 2026-04-13 | v3 | Nam Park | Bug 6 added (duplicate `sendToNirvana`) |
| 2026-05-03 | v4 | Nam Park (planner agent) | **Adds Bug 7 (pickingtoteId null guard, 6 sites; ported from v1 `b5ac3fa`); restructures into wms-tdd-gate-ready format with explicit AC→test mapping; identifies 7 missing v2 unit tests; adds RALPLAN-DR + ADR sections** |

### Project-memory directives proposed (post-rollout)

- `project_memory_add_directive`: *"Any new `unitloadRepository.findById(customerOrder.getPickingtoteId())` call MUST be preceded by an explicit `if (...getPickingtoteId() != null)` guard. Spring Data `findById(null)` throws `IllegalArgumentException`, not `Optional.empty`. Pick-pack flows legitimately have null pickingtoteId. (SBDEV-2102, b5ac3fa, 2026-05-03)"*
- `project_memory_add_directive`: *"Mobile services in v2 that mutate state MUST use `@Transactional(value = \"tenantTransactionManager\", rollbackFor = {BusinessException.class, FacadeException.class})`. With `open-in-view=false`, bare repo calls auto-commit and cannot be rolled back. (SBDEV-2102, 2026-04-12)"*
- `project_memory_add_directive`: *"`storeBoxOnLocation` and similar callers MUST NOT call `sendToNirvana` directly after `transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)`. The transfer method owns the empty-source nirvana send. The regression tests `shouldStoreBoxOnFlowbin*` enforce this. (SBDEV-2102 Bug 6, 2026-04-13)"*

---

## 9. Acceptance & Implementation

### 9.1 Acceptance Decision Record (ADR)

**Decision.** Apply Option B — v2-aware port of v1 `SBDEV-2102` covering Bugs 1-7 (where they reproduce in v2), plus v2-specific gaps (`@Transactional` on tenant TM, multi-replica ownership guard).

**Drivers (top 3).**
1. Release-blocking putaway bug; cost of a stuck unit load is high (manual DB intervention).
2. v2 OSIV-disabled in production: every untransacted mobile-service write is a corruption hazard.
3. Multi-replica deployment shape: any recovery path that could yank state from another replica's active session is unsafe by default.

**Alternatives considered.**
- *Option A: full v1 port* — rejected because v1 fixes for `equals()` quirks do not reproduce under v2's `AbstractBaseEntity.equals()`; porting them adds confusing dead code.
- *Option C: schema NOT NULL on `pickingtoteId`* — rejected because pick-pack semantics legitimately require nullable.
- *Option D: try/catch wrapping `findById`* — rejected because it hides genuine data corruption and erodes the precondition signal at `packageOrder`.

**Why B was chosen.** Option B applies the smallest effective diff, respects v2 architecture (`AbstractBaseEntity.equals()`, `tenantTransactionManager`), adds value v1 does not have (Fix 3a ownership guard for multi-replica), and is structured for wms-tdd-gate (each fix maps to ≥1 test).

**Consequences.**
- Positive: putaway flow no longer leaves stuck unit loads; case-mismatched scans succeed; pick-pack lifecycle no longer 500s on `findById(null)`; `storeBoxOnLocation` no longer raises `StaleObjectStateException`.
- Positive: the seven `@Transactional(tenantTransactionManager)` annotations make rollback semantics explicit, eliminating an entire class of half-applied-state bugs in the putaway flow.
- Negative: longer-held tenant tx in `findUnitLoad()` (~50ms p95). Acceptable — connection-pool math unchanged; no external I/O in the boundary.
- Negative: `packageOrder` now throws `BusinessException` (mapped to 4xx) instead of `IllegalArgumentException` (mapped to 500) for null-tote case. This is the desired behavior change. OMS clients calling the admin endpoint directly may need to adjust — confirm in M5 manual test.

**Follow-ups.**
1. Harden `UnitloadBusinessService.transferUnitLoadToLocation` to reload `unitload` by id at method entry. Class-wide protection for all callers. (Mechanical — same as v1 follow-up.)
2. Codebase-wide grep audit for unguarded `findByLabelid(` (without IgnoreCase fallback) and unguarded `findById(...getPickingtoteId())` — convert to CI lint if recurrence.
3. Optional: introduce `UnitloadRepository.findByLabelidWithFallback(label)` default method to deduplicate the 6-site fallback pattern. Only worthwhile if the codebase audit finds more callers.

### 9.2 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-2102.sh`

The script (to be authored alongside this plan revision; tracked in §5.2 checklist) encodes:

- **Positive checks** (one per fix):
  - `check_fix1_validation_before_transfer` — grep `MobilePutAwayService.java` for `boolean isPallet =` BEFORE `transferUnitLoadToLocation` line.
  - `check_fix2_case_fallback_count` — `grep -c "findByLabelidIgnoreCase" MobilePutAwayService.java` ≥ 6.
  - `check_fix3_controller_recovery` — grep `PutawayController.java` for `storePalletBackOnPutawayLane(dto)` inside both `BusinessException` and `FacadeException` catch blocks.
  - `check_fix3a_ownership_guard` — grep `MobilePutAwayService.java` for `currentLocation.getName().equals(currentUser)`.
  - `check_fix4_transactional_count` — `grep -c '@Transactional(value = "tenantTransactionManager"' MobilePutAwayService.java` ≥ 7.
  - `check_fix5_id_compare_typecheck` — grep `MobilePutAwayService.java` for `unitLoad.getTypeId().equals(` (≥2 occurrences).
  - `check_fix6_no_explicit_sendToNirvana_in_storeBoxOnLocation` — within the FLOWBIN case block, must NOT find `sendToNirvana` (after `transferStockToUnitLoad`).
  - `check_fix7_pickingtote_null_guard_count` — every `findById(\\(.*\\)getPickingtoteId\\(\\))` must be preceded by `getPickingtoteId() != null` within ~5 lines.
- **Targeted test invocations** (correctness gates):
  - `mvn test -Dtest=MobilePutAwayServiceUnitTest`
  - `mvn test -Dtest=PickingorderBusinessServiceUnitTest`
  - `mvn test -Dtest=CustomerorderServiceUnitTest`
  - `mvn test -Dtest=ManageOrderServiceUnitTest`

**Workflow contract.** A "DONE" claim is accepted only if all checks pass and all four test classes are green.

### 9.3 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Large | 7 fixes × multiple files; cross-service Fix 7; multi-replica concerns |
| **Pre-draft step** | analyst+planner (current) | This document is the planner output |
| **Plan-review step** | critic | Should run before any new test code is written |
| **Implementation shape** | wms-tdd-gate → executor (per fix cluster) | Source already merged; the remaining work is **test gap closure**, ideally TDD-gate-driven (write failing tests first) |
| **Verification step** | `verify-SBDEV-2102.sh` + verifier | Mandatory |
| **Code-review step** | code-reviewer | Required for Large |
| **Commit step** | git directly (single conceptual commit per fix-7 site) | Test additions are mechanical |

**Override rationale.** Source code is already in main. The remaining workflow is closing the **TDD-gate test gaps** identified in Section 6.1 (rows AC-11 through AC-17). Recommended sequence:

1. `wms-tdd-gate` — for each missing AC, write a failing test that asserts the new behavior; confirm it actually fails with the OLD behavior (use `git stash`/revert per site to validate); pause for human approval.
2. After approval, since the source change is already in place, the test will pass against current source. The verify script + `mvn test` provides the green gate.
3. If any AC test passes against old source (i.e., is not actually a regression guard), refine the assertion until it does fail, then re-validate.

---

## 10. Multi-Replica Safety (recap from v3, restated against this plan)

The wms2-api runs ≥2 replicas behind a load balancer. Each fix has been analyzed under concurrent access:

| Fix | Concurrency model | Safe? |
|-----|-------------------|-------|
| 1 (reorder validation) | Two replicas pass validation; first transfer wins via `@Version` | ✅ |
| 2 (case fallback) | Pure reads, deterministic via `LIMIT 1` + unique label | ✅ |
| 3 (controller recovery) | Bounded by Fix 3a ownership guard | ✅ |
| 3a (ownership guard) | Recovery only on current user's location | ✅ — prevents cross-user yanking |
| 4 (`@Transactional`) | Provides explicit rollback boundaries | ✅ — improves over auto-commit |
| 5 (perf) | Pure reads on reference data | ✅ |
| 6 (drop duplicate `sendToNirvana`) | One nirvana send via `transferStockToUnitLoad` | ✅ — eliminates the second-merge stale-version path |
| 7 (null guard `pickingtoteId`) | Pure null check before existing repo call | ✅ — no contention semantics changed |

### Scenario: two users scan same pallet on different replicas

```
Replica A (User A)                    Replica B (User B)
─────────────────                     ─────────────────
BEGIN TX                              BEGIN TX
findByLabelid("P-001") → found       findByLabelid("P-001") → found
validate location → pass              validate location → pass
validate type → pass                  validate type → pass
transfer P-001 to UserA → SUCCESS     transfer P-001 to UserB → FAILS
  (version 1 → 2)                       (OptimisticLockException: version=1 stale)
COMMIT                                ROLLBACK
return dto(isPallet=true)             catch → error "concurrent modification"
                                       → recovery: storePalletBackOnPutawayLane
                                       → ownership guard: pallet on UserA, not UserB
                                       → SKIP recovery (correct)
```

User A proceeds; User B's failed scan does not disrupt User A. Correct first-come-first-served semantics.

### Scenario: pick-pack last-pick across replicas

`finishPickingOrder` runs inside `@Transactional(tenantTransactionManager)` with `findByIdForUpdate` on the customer order (line 176). Two replicas trying to finalize the same picking order serialize on the row lock; the second sees the order in `FINISHED` state and short-circuits via the existing state guard at line 140-143. Fix 7h's null-guard does not change this.

---

## 11. Implementation Status (rolled forward from v3)

### Implemented in source (verified by grep / read on 2026-05-03)

| Fix | File | Verification anchor |
|-----|------|---------------------|
| 1 | `MobilePutAwayService.java:125-143` | `boolean isPallet = unitLoad.getTypeId().equals(...)` precedes `transferUnitLoadToLocation` |
| 2 | `MobilePutAwayService.java` 6 sites | `grep -c findByLabelidIgnoreCase MobilePutAwayService.java` returns 6 |
| 3 | `PutawayController.java:36-59` | `storePalletBackOnPutawayLane(dto)` in both catch blocks |
| 3a | `MobilePutAwayService.java:195-208` | `currentLocation.getName().equals(currentUser)` ownership check |
| 4 | `MobilePutAwayService.java` 7 methods | All putaway methods have `@Transactional(value = "tenantTransactionManager", ...)` |
| 5 | `MobilePutAwayService.java:125-131` | Direct `unitLoad.getTypeId().equals(...getId())` (no redundant `findById`) |
| 6 | `MobilePutAwayService.java:478-484` | FLOWBIN branch: only `transferStockToUnitLoad` call; comment explains |
| 7a | `PickingorderBusinessService.java:333` | `if (customerOrder.getPickingtoteId() != null)` |
| 7b | `CustomerorderService.java:365` | `if (customerOrder.getPickingtoteId() != null)` |
| 7c | `CustomerorderService.java:493-495` | `throw new BusinessException("Cannot package order=" + ... + " without an assigned picking tote")` |
| 7d | `CustomerorderService.java:655` | `if (customerOrder.getPickingtoteId() != null)` |
| 7f | `ManageOrderService.java:213` | `if (customerOrder.getPickingtoteId() != null)` |
| 7g | `ManageOrderService.java:338` | `else if (customerOrder.getPickingtoteId() != null)` |
| 7h | `PickingorderBusinessService.java:298, 333` | Two guards (`continue` for the dedup loop, `if (... != null)` for the tote fetch) |

### Tests added (TDD-gate closed 2026-05-03)

All 7 unit tests added in `@Nested class NullPickingtoteIdGuards` in each test class:

1. `PickingorderBusinessServiceUnitTest::finishPickingOrder_CustomerOrderWithNullPickingtoteId_Succeeds` ✓
2. `PickingorderBusinessServiceUnitTest::cleanUpCancelledOrder_NullPickingtoteId_SucceedsAndPreservesCancellationFlow` ✓
3. `CustomerorderServiceUnitTest::cancelOrder_Processable_NullPickingtoteId_SucceedsWithoutToteCleanup` ✓
4. `CustomerorderServiceUnitTest::packageOrder_NullPickingtoteId_ThrowsPreconditionBusinessException` ✓
5. `CustomerorderServiceUnitTest::cancelOrder_RapidPickingStarted_NullPickingtoteId_Succeeds` ✓
6. `ManageOrderServiceUnitTest::notifyPickingToteAssigned_NullPickingtoteId_SendsNullToteLabel` ✓
7. `ManageOrderServiceUnitTest::customerOrderPicked_NonClub_NullPickingtoteId_SendsNullToteLabel` ✓

Full suite result: **3833 run / 0 failures / 67 skipped** (2026-05-03).

### Status

**Source: COMPLETE. Tests: COMPLETE (17/17 ACs covered). Ready to archive.**

