---
title: "RunClubLine Transaction Boundary Hardening — V2 Residual Gaps"
ticket: ""
ticket_url: ""
type: "bug"
priority: "high"
status: "ready"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-05-03"
updated: "2026-05-03"
related:
  - "../../../4-Archieves/wms2/plan/260424-transaction-scope-refactoring-runclub-closebol.md"
tags:
  - plan
  - runclubline
  - club
  - transaction
  - npe
  - tdd-gate
---

# RunClubLine Transaction Boundary Hardening — V2 Residual Gaps

**Ticket:** —
**Project:** wms2/wms2-api | **Version:** v2 (Java 21 / Spring Boot 3.x) | **Type:** Bug (residual port from v1)
**Priority:** High (NPE in production path; TX crash risk on duplicate parcel labels)
**Date:** 2026-05-03

**V1 Source commits:**
- `f46cf06` — original cluster of runClubLine TX-boundary fixes (v1)
- `827a77e` — follow-up null-safe sysprop parsing (v1)

**V2 Prior plan:** [`sbdocs/4-Archieves/wms2/plan/260424-transaction-scope-refactoring-runclub-closebol.md`](../../../4-Archieves/wms2/plan/260424-transaction-scope-refactoring-runclub-closebol.md) — refactored runClubLine to a 4-phase per-order-TX architecture. **This plan targets only the gaps that remain after that refactor.**

---

## 0. RALPLAN-DR Summary (consensus mode)

### Principles (top 5)

1. **Port only what v2 is missing.** Verified "already done" items (F1, F3, F6, F7, Fix C) do not get re-done. Re-applying a v1 fix that the 260424 refactor already addressed adds confusing dead code and obscures the actual residual gap.
2. **Fail fast with informative errors.** `BusinessException` with operator-actionable context > `NullPointerException`; enriched per-shortfall messages > generic "Not enough stock on location."
3. **Use `WmsConstants` defaults — never hardcode fallback values.** The constants file already holds the authoritative defaults (`"36"` / `"60"` / `"84"`). Fallbacks at the call site would drift from these constants and create a second source of truth.
4. **Minimal blast radius.** Two isolated fixes in two files for Phase 1 (CRITICAL); one diagnostic fix in one file for Phase 2 (LOW). No cross-cutting concerns; no new abstractions; no new dependencies beyond an already-injected repository.
5. **Constructor injection only.** Add `UnitloadRepository` to `ClubLineOrderProcessor`'s constructor parameter list — no field injection, no `@Autowired` on a setter. Mirrors the rest of v2's idiom.

### Decision Drivers (top 3)

1. **Safety first.** Fix B (NPE on null sysprop) is CRITICAL. `Long.parseLong(null)` throws `NumberFormatException` (not NPE strictly — `Long.parseLong(null)` is documented to throw NPE because the implementation calls `s.length()` on null), unwinding the entire fix-location-assignment scheduled job. Must ship in Phase 1.
2. **Correctness.** Fix F2 (duplicate parcel label) causes silent cross-order parcel-pointer corruption: `UnitloadService.createUnitload(String,...)` short-circuits on duplicate `labelid` and returns the foreign unitload, which then gets stamped onto the new order's `parcelId` and receives the wrong stock. Pre-empting with an explicit `BusinessException` via `findByLabelidForUpdate` gives a usable error and prevents the corruption.
3. **Low-risk diagnostic.** Fix F5 (enriched shortfall message) is informational only — no behavior change, no TX semantics change. Deferred to Phase 2 to keep the Phase 1 deploy focused on the two actual production hazards.

### Options considered (≥2 viable, with bounded pros/cons)

| # | Option | Pros | Cons | Verdict |
|---|--------|------|------|---------|
| **A — chosen** | `parseSyspropLong(key, defaultValue)` private helper inside `FixLocationAssignmentService` using `WmsConstants` defaults | Mirrors v1 fix exactly; defaults are authoritative values already in `WmsConstants`; no API change to `SyspropService`; 3-line helper | Per-class private helper is mildly duplicative if other services have the same pattern (audited — only this class hits null sysprops on a hot path) | **Selected** |
| **B** | Add a public null-safe method to `SyspropService` (`getSysvalueAsLong(key, defaultValue)`) | More reusable across services; centralizes the parse | Larger blast radius (one more public API in a widely-injected service); requires `SyspropServiceUnitTest` expansion; overkill for 3 call sites in one class; not in v1 source | **Rejected — overkill** |
| **C — for F5 only** | Add `shortfallMap` to `StockValidationResult` record vs. compute shortfall inline at the throw site | Record approach keeps the per-itemdata data available for future use (UI rendering, OMS notification, audit log); composes with future enrichment | Slight record signature change; needs to thread `shortfallMap` through all callers of `validateStockOnStagingLane` (audited — single caller in `CustomerorderBatchService`) | **Selected for F5** |
| **D — for F5 only** | Compute shortfall locally in `validateStockOnStagingLane` and build the message string inline at the `throw` site | Smallest diff; no record signature change | Throws away structured shortfall data; future "show shortfall on UI" work has to recompute; F5 is the canonical place to capture this | **Rejected — discards structure** |

**Why A was chosen over B.** v1's `827a77e` introduced the `parseSyspropLong` helper as a class-local helper in `FixLocationAssignmentService`. There are exactly 3 call sites in this class that hit a null-prone sysprop on the scheduled-job path. A `SyspropService` public method would force a unit-test expansion across the entire sysprop surface and break the pattern of "v2 ports v1 mechanically when no v2-specific reason exists to deviate." Reuse can be hoisted later if a second class needs it.

**Why C was chosen over D for F5.** F5 is LOW priority and diagnostic-only, so simplicity (D) was tempting. But the shortfall is exactly the data a future "show me which SKUs are short" UI / OMS-notification feature needs, and `StockValidationResult` is the natural carrier. Threading it through one caller is cheap; recomputing it later is wasteful and risks inconsistency between the message and the structured data.

### Mode

**SHORT** (default). Two narrowly-scoped code fixes (Phase 1) plus one message-enrichment (Phase 2). No auth/security/migration concern. No new persistence path. No new external integration. If the reviewer wants `--deliberate`, escalate via `critic` and re-emit with a pre-mortem and expanded e2e/observability test plan.

---

## 1. Problem Statement

The 260424 refactor (`260424-transaction-scope-refactoring-runclub-closebol.md`) restructured runClubLine into a 4-phase per-order-TX architecture, fixing the bulk of v1's `f46cf06` cluster. Two hazards remain that did **not** carry over from v1:

### Hazard 1 — `FixLocationAssignmentService` NPE on null sysprop (CRITICAL)

`FixLocationAssignmentService` line 80-82 (v2/wms2-api) reads three system properties for fix-location assignment bounds:

```java
BigDecimal lowerBound = BigDecimal.valueOf(Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY)));
BigDecimal middleBound = BigDecimal.valueOf(Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_KEY)));
BigDecimal upperBound = BigDecimal.valueOf(Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY)));
```

`syspropService.getSysvalue(key)` returns `null` when the row is absent for the tenant (a green-field tenant or a tenant where the sysprop has not yet been seeded). `Long.parseLong(null)` throws `NumberFormatException` (the JDK source does `if (s == null) throw new NumberFormatException("null")`), which on the scheduled-job path unwinds the assignment loop entirely and is not retried until the next tick.

V1 fix (`827a77e`) introduced a `parseSyspropLong(key, defaultValue)` helper that returns `Long.parseLong(getSysvalue(key) != null ? value : defaultValue)`, with defaults sourced from `WmsConstants` (`"36"` / `"60"` / `"84"`).

### Hazard 2 — `ClubLineOrderProcessor` cross-order parcel-pointer corruption (HIGH)

`ClubLineOrderProcessor.processOrder` line 101-107 (v2/wms2-api):

```java
Unitload packageUnitLoad = unitloadService.createUnitload(
        order.getParcelexternalnumber(), packageLocation, packageUnitLoadTypeId,
        clientId, WmsConstants.CODE_PACKAGING_CLUB, spawnLocation, null);
LOG.debug("processOrder: created unitload={}", packageUnitLoad.getId());

order.setParcelId(packageUnitLoad.getId());
customerorderRepository.save(order);
```

`UnitloadService.createUnitload(String name, ...)` at `UnitloadService.java:168-190` does **not** throw on a duplicate `labelid`. Instead it calls `unitloadRepository.findByLabelid(name)` internally and **silently returns the pre-existing `Unitload`** when found. This means: if a previous club run already persisted a unitload with `labelid='P-001'` for **order A**, then today's club run for **order B** with `order.getParcelexternalnumber()='P-001'`:

1. `createUnitload` returns order A's existing unitload (no exception, no constraint violation).
2. Line 106 stamps `order_B.parcelId = unitloadA.id` — **order B's parcel pointer references order A's unitload**.
3. The downstream `transferStockToUnitLoad` loop transfers order B's stock into order A's unitload — silent inventory corruption committed with no operator-visible error.

V1 fix (`f46cf06`) added a guard before `createUnitload`: if `unitloadRepository.findByLabelid(...)` returns a present `Optional`, throw `BusinessException`. In v2 the identical guard intercepts the silent-merge path before it can corrupt the parcel pointer. To close the race window across replicas (two concurrent `processOrder` calls both passing the pre-check), the guard must use a new `findByLabelidForUpdate` method (following the `findByIdForUpdate` precedent at `UnitloadRepository.java:29-31`) so the `SELECT ... FOR UPDATE` serializes the check inside the per-order TX.

### Hazard 3 — Generic shortfall error message (LOW, diagnostic)

`CustomerorderBatchService.validateStockOnStagingLane` (Phase 1 of the 260424 refactor) throws a generic `BusinessException("Not enough stock on location.")` when stock is insufficient. The per-order phase (`ClubLineOrderProcessor` line 165-168) already enriches the message with the order number, but the staging-lane phase does not enumerate which itemdatas are short or by how much.

V1 fix (`f46cf06`) tracked the per-itemdata shortfall in `StockCheckResult` and built a "SKU X needs Y more, SKU Z needs W more" message at the throw site.

---

## 2. Root Cause Analysis

### 2.1 V1 → V2 Applicability Matrix

| V1 Fix | Description | V2 Verdict | Where it lives in v2 |
|--------|-------------|-----------|----------------------|
| **F1** | `assignClubHistoryTotes` inside TX + `afterCommit` OMS defer | **Not needed** | `ManageOrderService.customerOrderPicked` L344-346 `saveAll` runs before OMS POST at L361; UUID is persisted before the OMS notification is dispatched. The 260424 refactor preserved this ordering. |
| **F2** | Parcel-label collision guard before `createUnitload` | **Needed (HIGH)** | `ClubLineOrderProcessor.processOrder` L101-107. `UnitloadService.createUnitload(String,...)` at `UnitloadService.java:168-190` silently returns an existing `Unitload` on duplicate `labelid` (no UNIQUE-constraint exception). Line 106 then stamps the new order's `parcelId` onto the foreign unitload — silent cross-order inventory corruption. Guard must use `findByLabelidForUpdate` (new repo method) to close the race inside the per-order TX. |
| **F3** | `orElseThrow` in inner loop | **Not needed** | `ClubLineOrderProcessor` L133-138 uses `.orElse(null)` + a graceful skip (intentional — empty inner-loop steps are valid); L165 has a correctness guard for the path where the value MUST be present. |
| **F5** | Enriched shortfall error message | **Needed (LOW)** | Phase-1 `validateStockOnStagingLane` failure still emits "Not enough stock on location." Per-order message in `ClubLineOrderProcessor` L165-168 is already enriched. |
| **F6** | `findByIdForUpdate` at runClubLine entry | **Not needed** | Already done by the 260424 refactor — `runClubLine` opens with `findByIdForUpdate` on the batch row. |
| **F7** | `checkStagingLaneStock` / `StockCheckResult` | **Not needed** | v2 already has `validateStockOnStagingLane` returning `StockValidationResult` (record). F5 extends the record; the broader F7 restructure is already in place. |
| **Fix B** (`827a77e`) | `parseSyspropLong` null-safe sysprop parsing | **Needed (CRITICAL)** | `FixLocationAssignmentService` L80-82: 3× `Long.parseLong(getSysvalue(...))` where `getSysvalue` can return `null` → `NumberFormatException` (often surfaced as NPE in tracebacks because `Long.parseLong` may delegate to `s.length()` first depending on JDK version). |
| **Fix C** (`f46cf06`) | `@Transactional` on `storeBoxOnLocation` | **Not needed** | Already done by the 260424 refactor (or earlier mobile-services pass — `MobilePutAwayService.storeBoxOnLocation` L445 has `@Transactional(value = "tenantTransactionManager", rollbackFor = …)`). |

### 2.2 Affected Locations

| # | File | Line(s) | Description | Fix |
|---|------|---------|-------------|-----|
| 1 | `service/FixLocationAssignmentService.java` | 80-82 | Three unguarded `Long.parseLong(syspropService.getSysvalue(...))` calls | Fix B |
| 1.5 | `schedulejob/ReplenishOrderJob.java` | 192 | `Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PICKING_BOX_PER_CART_KEY))` in `mergePickingOrders()` — same null-NPE on scheduled-job path | Fix B |
| 2 | `service/ClubLineOrderProcessor.java` | 101-103 | `unitloadService.createUnitload(order.getParcelexternalnumber(), …)` with no pre-check guard | Fix F2 |
| 3 | `service/ClubLineOrderProcessor.java` | constructor | Add `UnitloadRepository unitloadRepository` to constructor injection | Fix F2 (dep) |
| 3.5 | `repo/jpa/UnitloadRepository.java` | new method | Add `findByLabelidForUpdate(String labelid)` with `@Lock(LockModeType.PESSIMISTIC_WRITE)` — mirrors `findByIdForUpdate` at line 29-31 | Fix F2 (dep) |
| 4 | `service/CustomerorderBatchService.java` | `validateStockOnStagingLane` + `StockValidationResult` record | Add `shortfallMap` to record; compute shortfall per itemdata; build enriched message | Fix F5 |

### 2.3 Why this stays out of the 260424 refactor's scope

The 260424 plan was scoped to **transaction boundary** changes: per-order TX, OMS deferral, lock acquisition. The three remaining hazards in this plan are:
- **Fix B**: a defensive-coding gap inside an unrelated scheduled job (`FixLocationAssignmentService`) that happens to share the v1 `f46cf06` / `827a77e` ticket because they shipped in the same v1 commit window.
- **Fix F2**: a parcel-label collision guard that's orthogonal to TX scoping — it would need to exist regardless of whether per-order TX or per-batch TX was chosen.
- **Fix F5**: a diagnostic-only message enrichment that has no TX semantics.

Bundling them into 260424 would have widened that plan's blast radius unnecessarily. Deferring them to a follow-up is the v2-aware choice, and this is that follow-up.

---

## 3. Design / Proposed Fix

### 3.1 Phase 1, Fix B — `parseSyspropLong` helper in `FixLocationAssignmentService` (CRITICAL)

**Problem.** `Long.parseLong(syspropService.getSysvalue(BOUND_KEY))` throws when the row is absent for the tenant. Repeated 3× at L80-82, on a scheduled-job path that has no surrounding fallback.

**Solution.** Add a private helper that defaults to a `WmsConstants` value when the sysprop is null, and replace the three call sites.

**Helper signature:**

```java
private long parseSyspropLong(String key, String defaultValue) {
    String value = syspropService.getSysvalue(key);
    if (value == null) {
        LOG.warn("Sysprop {} absent for tenant; falling back to default {}", key, defaultValue);
        return Long.parseLong(defaultValue);
    }
    return Long.parseLong(value);
}
```

**Replacement at L80-82:**

```java
// Before:
BigDecimal lowerBound = BigDecimal.valueOf(Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY)));
BigDecimal middleBound = BigDecimal.valueOf(Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_KEY)));
BigDecimal upperBound = BigDecimal.valueOf(Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY)));

// After:
BigDecimal lowerBound = BigDecimal.valueOf(parseSyspropLong(
        WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY,
        WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_VALUE));
BigDecimal middleBound = BigDecimal.valueOf(parseSyspropLong(
        WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_KEY,
        WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_VALUE));
BigDecimal upperBound = BigDecimal.valueOf(parseSyspropLong(
        WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY,
        WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_VALUE));
```

`WmsConstants` already exposes:
- `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_VALUE = "36"`
- `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND_VALUE = "60"`
- `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_VALUE = "84"`

**Replicate at `ReplenishOrderJob.java:192`.** The `mergePickingOrders()` method at line 192 has the same unguarded pattern: `Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PICKING_BOX_PER_CART_KEY))`. Apply the same `parseSyspropLong` helper (private, class-local to `ReplenishOrderJob`). Default: `WmsConstants.SYSTEM_PROPERTY_PICKING_BOX_PER_CART_DEFAULT_VALUE` (`"6"`).

**Files changed:** `src/main/java/net/aim_ai/wms/service/FixLocationAssignmentService.java`, `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java`.

### 3.2 Phase 1, Fix F2 — Parcel-label collision guard in `ClubLineOrderProcessor`

**Problem.** When `order.getParcelexternalnumber()` collides with an existing unitload label, `unitloadService.createUnitload(String,...)` does NOT throw — it short-circuits via its internal `findByLabelid` (non-locking, at `UnitloadService.java:168-190`) and silently returns the pre-existing `Unitload`. Line 106 then stamps `order.parcelId = foreignUnitload.id` and the stock transfer loop fills the wrong unitload. Note: the DB does have a UNIQUE constraint on `unitload.labelid` (`uq_unitload_labelid`), but `createUnitload` short-circuits before INSERT, so the constraint never fires. The guard in `ClubLineOrderProcessor` is the only pre-insert check.

**Solution.** Add `UnitloadRepository` to constructor injection. Before calling `createUnitload`, query `findByLabelidForUpdate` and throw a clean `BusinessException` if the label is already in use.

**New repo method — `UnitloadRepository.findByLabelidForUpdate`:**

```java
// Add to UnitloadRepository.java (after findByIdForUpdate at lines 29-31).
// Do NOT modify the existing non-locking findByLabelid at line 62-63.
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT u FROM Unitload u WHERE u.labelid = :labelid")
Optional<Unitload> findByLabelidForUpdate(@Param("labelid") String labelid);
```

The existing `findByLabelid(String)` at line 62 is non-locking (read-only). The new `findByLabelidForUpdate` adds `@Lock(LockModeType.PESSIMISTIC_WRITE)` so the `SELECT ... FOR UPDATE` inside the per-order TX serializes two concurrent replicas racing to create the same parcel label. The first replica acquires the lock; the second blocks until the first commits, then finds the row and throws `BusinessException` instead of returning silently.

**Constructor change** (illustrative — preserve the existing constructor parameter order; add `UnitloadRepository unitloadRepository` to the parameter list and to the field assignment block):

```java
// Before:
public ClubLineOrderProcessor(
        UnitloadService unitloadService,
        // ... existing deps ...
) {
    this.unitloadService = unitloadService;
    // ...
}

// After:
public ClubLineOrderProcessor(
        UnitloadService unitloadService,
        UnitloadRepository unitloadRepository,
        // ... existing deps ...
) {
    this.unitloadService = unitloadService;
    this.unitloadRepository = unitloadRepository;
    // ...
}
```

**Guard insertion at L100-103:**

```java
// Before (L101-103):
Unitload packageUnitLoad = unitloadService.createUnitload(
        order.getParcelexternalnumber(), packageLocation, packageUnitLoadTypeId,
        clientId, WmsConstants.CODE_PACKAGING_CLUB, spawnLocation, null);

// After:
if (unitloadRepository.findByLabelidForUpdate(order.getParcelexternalnumber()).isPresent()) {
    throw new BusinessException("Parcel label already in use: "
            + order.getParcelexternalnumber()
            + " on order " + order.getNumber());
}
Unitload packageUnitLoad = unitloadService.createUnitload(
        order.getParcelexternalnumber(), packageLocation, packageUnitLoadTypeId,
        clientId, WmsConstants.CODE_PACKAGING_CLUB, spawnLocation, null);
```

**Note on TX semantics.** The guard runs inside the per-order TX established by `ClubLineOrderProcessor.processOrder`'s `@Transactional(value = "tenantTransactionManager", ...)` at line 87. `findByLabelidForUpdate` acquires a `SELECT ... FOR UPDATE` row-level lock for the `labelid` value. Under READ COMMITTED (PostgreSQL default), two concurrent replicas both attempting to create parcel label 'P-001' will serialize at this point: the first replica acquires the lock and proceeds; the second blocks, then sees the row and throws `BusinessException`. This closes the race window. Note that `UnitloadService.createUnitload(String, ...)` has its own internal `findByLabelid` (non-locking) that would silently return the existing row without throwing — because `createUnitload` short-circuits before INSERT, the DB's UNIQUE constraint on `unitload.labelid` (`uq_unitload_labelid`) never fires. The guard in `ClubLineOrderProcessor` is the only pre-insert check that converts the collision into an explicit error.

**Files changed:** `src/main/java/net/aim_ai/wms/service/ClubLineOrderProcessor.java`.

### 3.3 Phase 2, Fix F5 — Enriched shortfall message in `validateStockOnStagingLane` (LOW)

**Problem.** Phase-1 staging-lane shortfall throws "Not enough stock on location." with no enumeration of which itemdatas are short.

**Solution.** Extend `StockValidationResult` to carry a `shortfallMap`; populate it in `validateStockOnStagingLane`; build a per-shortfall message at the throw site.

**Record change** (in `CustomerorderBatchService.java` or wherever the record is declared):

```java
// Before:
record StockValidationResult(boolean sufficient, Map<Itemdata, List<Stockunit>> stockMap) { }

// After:
record StockValidationResult(
        boolean sufficient,
        Map<Itemdata, List<Stockunit>> stockMap,
        Map<Itemdata, BigDecimal> shortfallMap) { }
```

**Population logic** in `validateStockOnStagingLane` (illustrative):

```java
Map<Itemdata, BigDecimal> shortfallMap = new LinkedHashMap<>();
for (Map.Entry<Itemdata, BigDecimal> req : requiredByItemdata.entrySet()) {
    BigDecimal available = computeAvailable(req.getKey(), stockMap);
    if (available.compareTo(req.getValue()) < 0) {
        shortfallMap.put(req.getKey(), req.getValue().subtract(available));
    }
}
boolean sufficient = shortfallMap.isEmpty();
return new StockValidationResult(sufficient, stockMap, shortfallMap);
```

**Throw-site change:**

```java
// Before:
throw new BusinessException("Not enough stock on location.");

// After:
throw new BusinessException("Not enough stock on location: "
        + buildShortfallMessage(result.shortfallMap()));
```

**Helper:**

```java
private String buildShortfallMessage(Map<Itemdata, BigDecimal> shortfallMap) {
    return shortfallMap.entrySet().stream()
            .map(e -> "SKU " + e.getKey().getNumber() + " needs " + e.getValue() + " more")
            .collect(Collectors.joining(", "));
}
```

**Files changed:** `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`.

---

## 4. V1 / V2 Applicability

See §2.1 for the full matrix. Summary:

### What needs porting

- **Fix B** (`827a77e`): `parseSyspropLong` helper — Phase 1, CRITICAL.
- **Fix F2** (`f46cf06`): parcel-label collision guard — Phase 1, HIGH.
- **Fix F5** (`f46cf06`): enriched shortfall message — Phase 2, LOW.

### What does NOT need porting (with justification)

- **F1** — `assignClubHistoryTotes` ordering and `afterCommit` OMS deferral are already correct in v2 `ManageOrderService.customerOrderPicked` (L344-346 saveAll runs before L361 OMS POST). The 260424 refactor preserved this.
- **F3** — `ClubLineOrderProcessor` L133-138 deliberately uses `.orElse(null)` + graceful skip; this is correct for the inner-loop semantics (empty steps are valid). L165 has the correctness guard where it matters.
- **F6** — `findByIdForUpdate` at runClubLine entry was added by the 260424 refactor.
- **F7** — `validateStockOnStagingLane` returning `StockValidationResult` is already in place. F5 extends; F7 itself is done.
- **Fix C** — `@Transactional` on `storeBoxOnLocation` was added prior to this plan; verified `MobilePutAwayService` line 445 already has the tenant-TM annotation.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. Tenants without seeded `los_sysprop` rows for the three bound keys will pick up `WmsConstants` defaults (36/60/84) after Fix B ships. If a tenant *does* have rows, the existing values continue to drive behavior. | n/a | Optional follow-up: seed defaults explicitly via Flyway for new tenants. |
| 2 | **Feature flags / system properties** | None added. The three existing keys (`SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND_KEY`, `_MIDDLE_BOUND_KEY`, `_UPPER_BOUND_KEY`) keep their current names and semantics. | n/a | |
| 3 | **Config / env changes** | None. | DevOps | |
| 4 | **Deploy-order dependencies** | None. Backend-only; no DTO contract change. | n/a | |
| 5 | **Data migration** | None. | n/a | |
| 6 | **External systems** | None. OMS notification path unchanged (F1 verdict: not needed). | n/a | |
| 7 | **Access / permissions** | None. | n/a | |
| 8 | **Monitoring / alerts** | Optional: add a Grafana panel for `fix_location_assignment_run_total` with a tenant dimension to detect tenants that previously failed silently and now succeed under default bounds. Not blocking. | DevOps | |

### 5.2 Implementation Checklist

**Phase 1 — CRITICAL (single conceptual commit recommended):**

- [ ] Fix B — `FixLocationAssignmentService.parseSyspropLong` helper (with LOG.warn on null) added; 3 call sites at L80-82 replaced
- [ ] Fix B (ReplenishOrderJob) — same helper added to `ReplenishOrderJob.mergePickingOrders`; L192 call site replaced
- [ ] Fix F2 — `UnitloadRepository.findByLabelidForUpdate` method added (mirrors `findByIdForUpdate`)
- [ ] Fix F2 — `ClubLineOrderProcessor` constructor extended with `UnitloadRepository`; pre-`createUnitload` guard (using `findByLabelidForUpdate`) at L100-103 added
- [ ] Unit tests: `FixLocationAssignmentServiceUnitTest` — A1, A2
- [ ] Unit tests: `ReplenishOrderJobUnitTest` — A2.1
- [ ] Unit tests: `ClubLineOrderProcessorUnitTest` (extend existing) — A3, A4
- [ ] `mvn test -Dtest=FixLocationAssignmentServiceUnitTest` green
- [ ] `mvn test -Dtest=ClubLineOrderProcessorUnitTest` green
- [ ] `bash sbdocs/9-System/scripts/verify-260503-runclubline-transaction-boundary-hardening.sh` — all checks pass

**Phase 2 — LOW (separate commit):**

- [ ] Fix F5 — `StockValidationResult` record extended with `shortfallMap`; `validateStockOnStagingLane` populates it; throw-site message enriched
- [ ] Unit test: `CustomerorderBatchServiceUnitTest` — shortfall message asserts SKU + needed amount
- [ ] `mvn test -Dtest=CustomerorderBatchServiceUnitTest` green
- [ ] `mvn verify` clean
- [ ] Code review by `code-reviewer`
- [ ] Acceptance script re-run

---

## 6. Test Plan

### 6.1 Acceptance Criteria → Test Mapping (TDD-gate contract)

| AC# | Criterion | Test class | Test method | Phase |
|-----|-----------|------------|-------------|-------|
| A1 | `createFixedLocationAssignment` does NOT throw `NumberFormatException` when all three bound sysprops return null; uses `WmsConstants` defaults (36/60/84) | `FixLocationAssignmentServiceUnitTest` | `createFixedLocationAssignment_shouldUseWmsConstantsDefaults_whenBoundSyspropsReturnNull` | 1 |
| A2 | `createFixedLocationAssignment` parses present sysprop values correctly: mocks return "100"/"200"/"300" → saved entity has `lowerbound=100`, `middlebound=200`, `upperbound=300` | `FixLocationAssignmentServiceUnitTest` | `createFixedLocationAssignment_shouldParseLong_whenBoundSyspropsPresent` | 1 |
| A2.1 | `mergePickingOrders` in `ReplenishOrderJob` does NOT throw `NumberFormatException` when `SYSTEM_PROPERTY_PICKING_BOX_PER_CART_KEY` sysprop returns null; uses default `"6"` | `ReplenishOrderJobUnitTest` | `mergePickingOrders_shouldUseDefault_whenBoxPerCartSyspropNull` | 1 |
| A3 | `processOrder` throws `BusinessException` when `unitloadRepository.findByLabelidForUpdate(parcelexternalnumber)` returns present; `unitloadService.createUnitload(...)` is **never** called | `ClubLineOrderProcessorUnitTest` | `processOrder_shouldThrowBusinessException_whenParcelLabelAlreadyExists` | 1 |
| A4 | `processOrder` proceeds to `createUnitload` when `findByLabelidForUpdate` returns empty | `ClubLineOrderProcessorUnitTest` | `processOrder_shouldProceedToCreateUnitload_whenParcelLabelIsNew` | 1 |
| A5 | `validateStockOnStagingLane` failure message enumerates per-itemdata shortfall as `"SKU X needs Y more"` (LOW) | `CustomerorderBatchServiceUnitTest` | `validateStockOnStagingLane_shouldEnumerateShortfall_whenInsufficient` | 2 |

### 6.2 Test scenarios

| # | Scenario | Steps | Expected Result |
|---|----------|-------|-----------------|
| S1 | Fix-location assignment runs on green-field tenant (no sysprop rows) | Trigger scheduled job for a tenant with zero `los_sysprop` rows for the three bound keys | Job completes; bounds 36/60/84 used; no exception in logs |
| S2 | Fix-location assignment with explicit sysprop values | Tenant has rows `LOWER=100`, `MIDDLE=200`, `UPPER=300` | Job completes; bounds 100/200/300 used |
| S3 | Club run with previously-used parcel label | Pre-seed a `unitload` with `labelid='P-DUP-001'`; run club for an order whose `parcelexternalnumber='P-DUP-001'` | Per-order TX rolls back with `BusinessException("Parcel label already in use: P-DUP-001 on order …")`; downstream orders in the same batch continue |
| S4 | Club run with novel parcel label | Order's `parcelexternalnumber` not present in `unitload` | `createUnitload` invoked; order processes normally |
| S5 | Staging-lane shortfall with two short SKUs | Stage stock such that SKU-A is short by 5 and SKU-B is short by 2 | `BusinessException("Not enough stock on location: SKU A needs 5 more, SKU B needs 2 more")` |

### 6.3 New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `FixLocationAssignmentServiceUnitTest` (extend) | `createFixedLocationAssignment_shouldUseWmsConstantsDefaults_whenBoundSyspropsReturnNull` | A1 — three `getSysvalue` mocks return null → method completes; verify the `BigDecimal`s passed to the downstream call match `BigDecimal.valueOf(36)`, `BigDecimal.valueOf(60)`, `BigDecimal.valueOf(84)` (capture the args) |
| `FixLocationAssignmentServiceUnitTest` (extend) | `createFixedLocationAssignment_shouldParseLong_whenBoundSyspropsPresent` | A2 — mocks return "100"/"200"/"300" → saved entity has `lowerbound=100`, `middlebound=200`, `upperbound=300`; capture-and-verify |
| `ReplenishOrderJobUnitTest` (new) | `mergePickingOrders_shouldUseDefault_whenBoxPerCartSyspropNull` | A2.1 — `getSysvalue` mock returns null for `SYSTEM_PROPERTY_PICKING_BOX_PER_CART_KEY` → method completes using default `"6"`; no `NumberFormatException` thrown |
| `ClubLineOrderProcessorUnitTest` (extend) | `processOrder_shouldThrowBusinessException_whenParcelLabelAlreadyExists` | A3 — `unitloadRepository.findByLabelidForUpdate(...)` returns `Optional.of(<existing>)` → expect `BusinessException` thrown; verify `unitloadService.createUnitload(...)` is `never()` invoked |
| `ClubLineOrderProcessorUnitTest` (extend) | `processOrder_shouldProceedToCreateUnitload_whenParcelLabelIsNew` | A4 — `findByLabelidForUpdate` returns `Optional.empty()` → `createUnitload` is invoked once with the expected args |
| `CustomerorderBatchServiceUnitTest` (extend) | `validateStockOnStagingLane_shouldEnumerateShortfall_whenInsufficient` | A5 — fixture with two short SKUs → captured `BusinessException` message contains both SKU numbers and their shortfall amounts in the documented format |

### 6.4 Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|----------|-------------|-------|-----------------|-----------|
| M1 | Green-field tenant fix-location assignment | staging (a tenant with no `los_sysprop` bound rows) | Trigger or wait for the scheduled job | Job completes for that tenant; logs show no NPE / NumberFormatException; no halt on the cluster cron | |
| M2 | Existing tenant unchanged | staging (tenant with `LOWER=36`, `MIDDLE=60`, `UPPER=84` already seeded) | Trigger job | Identical output to pre-deploy; bounds unchanged | |
| M3 | Club run duplicate parcel label | staging (admin-seeded duplicate `unitload.labelid`) | Run club batch for the matching order | API returns 4xx with `BusinessException` message including label and order number; batch continues with remaining orders | |
| M4 | Club run happy path | staging | Normal club batch | All orders processed; no `BusinessException`s in logs | |
| M5 | Staging-lane shortfall (Phase 2) | staging | Reduce staging-lane stock for one SKU below the batch requirement | API returns 4xx with the enriched message; operator can identify which SKU + how much | |

### 6.5 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=FixLocationAssignmentServiceUnitTest` | | |
| `mvn test -Dtest=ClubLineOrderProcessorUnitTest` | | |
| `mvn test -Dtest=CustomerorderBatchServiceUnitTest` | | |
| `mvn verify` | | |

### 6.6 Deliberately-skipped coverage

| What | Why |
|------|-----|
| Cross-replica race on parcel-label pre-check | Race is closed in-TX by `findByLabelidForUpdate` (`SELECT ... FOR UPDATE`), not by a DB UNIQUE constraint (`UnitloadService.createUnitload` silently merges on duplicate — no constraint path exists). Unit tests cannot model cross-replica lock timing meaningfully. |
| Integration test for `FixLocationAssignmentService` scheduled-job path | Scheduled-job orchestration is not a logic concern of this fix; the bug is purely the null-parse, which is fully covered by A1 / A2 unit tests. |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica state? | **No** | All state remains in DB. No Caffeine / static / ThreadLocal added. `parseSyspropLong` helper is stateless. |
| 2 | **Connection pool math** | Change per-request DB connection use? | **No** | Fix B replaces 3× `getSysvalue` (each its own implicit auto-commit if outside a TX) with the same 3 calls inside the helper — no net change. Fix F2 adds **one** `findByLabelidForUpdate` call per club order, executed inside the existing per-order TX boundary established by 260424 — no extra connection acquired. Fix F5 adds no new DB calls. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled`? | **No** | `FixLocationAssignmentService` is invoked by an existing scheduled job; this plan changes its body, not its scheduling. ShedLock posture unchanged. |
| 4 | **Long transactions** | Hold a tx across multiple repo calls / external I/O? | **No (slight extension within existing boundary)** | Fix F2 adds one `findByLabelidForUpdate` to the existing per-order TX in `ClubLineOrderProcessor.processOrder`. Estimated added wall-clock <5ms p95 (single-row indexed lookup). Far below `connectionTimeout`. |
| 5 | **Request affinity** | Assume same-replica follow-up? | **No** | All work is in DB-backed state. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op and another replica retries? | **No (closed by guard)** | Fix F2's `findByLabelidForUpdate` inside the per-order TX acquires a `SELECT ... FOR UPDATE` lock, serializing concurrent replicas racing on the same parcel label. The first replica proceeds; the second blocks and then throws `BusinessException` on finding the row. There is no DB UNIQUE-constraint path — `UnitloadService.createUnitload` silently merges on duplicate `labelid`; the pessimistic-lock guard in `ClubLineOrderProcessor` is the sole serialization point. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **No** | All work happens on the request thread inside the existing tenant TX. |
| 8 | **Distributed lock correctness** | Add or rely on locks across replicas? | **No new locks** | Existing optimistic locking on `Unitload`, `Customerorder` continues to arbitrate. The 260424 refactor's `findByIdForUpdate` on the batch row at runClubLine entry continues to serialize the batch-level work. No change to lock semantics. |
| 9 | **Cache invalidation** | Write to a cached entity? | **No** | `Unitload`, `Customerorder` are not in `CacheConfig`'s caches. |
| 10 | **External notifications** | HTTP/message inside tx? | **No new** | OMS notification path unchanged (F1 verdict: already correct). Fix F5 enriches an in-process exception message; no external dispatch. |

### Evidence (fill in after implementation)

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 2 | One added DB call per order, indexed lookup | `ClubLineOrderProcessor.java:~100` (post-edit), `unitload.labelid` unique index already in schema |
| 4 | Per-order TX scope unchanged | `ClubLineOrderProcessor.processOrder` annotation (preserved from 260424 refactor) |
| 6 | Pessimistic-lock guard as sole serialization point | `findByLabelidForUpdate` closes the race inside per-order TX; `BusinessException` path covered by `processOrder_shouldThrowBusinessException_whenParcelLabelAlreadyExists` |

---

## 8. Notes

### Related plans

- **V2 prior plan (archived):** `sbdocs/4-Archieves/wms2/plan/260424-transaction-scope-refactoring-runclub-closebol.md` — the transaction-scope refactor that this plan extends. Without that refactor, the per-order TX boundary that contains Fix F2's failure does not exist.
- **V1 source commits:** `f46cf06` (original cluster), `827a77e` (sysprop null-safe parsing follow-up).

### Deployment considerations

Backend-only. No frontend or migration. Roll out with the next normal `wms2-api` release. Phase 1 is the load-bearing deploy; Phase 2 (F5) can ship in the same release or the next.

### Follow-ups

1. **Optional Flyway seed** for the three `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_*` keys per new tenant — eliminates the need for the default-fallback path on green-field tenants. Not blocking; defaults exist in `WmsConstants` and are now correctly applied.
2. **Codebase audit** for other `Long.parseLong(syspropService.getSysvalue(...))` patterns — convert to a CI lint or a project-memory directive if more sites surface.
3. **F5 future use** — once `shortfallMap` is in `StockValidationResult`, expose it via the OMS notification or the batch-failure UI panel (out of scope for this plan).

### Project-memory directives proposed (post-rollout)

- `project_memory_add_directive`: *"Any new `Long.parseLong(syspropService.getSysvalue(...))` MUST go through a null-safe helper with a `WmsConstants` default. Bare `getSysvalue` returns `null` for unseeded tenants and `Long.parseLong(null)` throws. (260503 / `827a77e`)"*
- `project_memory_add_directive`: *"Before `unitloadService.createUnitload(label, ...)`, call `unitloadRepository.findByLabelidForUpdate(label)` and throw a `BusinessException` if present. `UnitloadService.createUnitload(String,...)` silently returns an existing unitload on duplicate labelid (no UNIQUE-constraint exception), causing cross-order parcel-pointer corruption. The `SELECT ... FOR UPDATE` guard is the sole serialization point. (260503 / `f46cf06`)"*

### Version history

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2026-05-03 | v1 | Nam Park (planner agent) | Initial draft. Ports F2, F5, Fix B from v1 `f46cf06` + `827a77e` after the 260424 transaction-scope refactor. Skips F1, F3, F6, F7, Fix C as already done. |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance Decision Record (ADR)

**Decision.** Apply Option A — class-local `parseSyspropLong` helper inside `FixLocationAssignmentService` using `WmsConstants` defaults; `findByLabelidForUpdate` guard inside `ClubLineOrderProcessor` (new repo method + constructor dep); record-extension shortfall enrichment in `CustomerorderBatchService`.

**Drivers (top 3).**
1. Safety first — Fix B prevents an NPE that halts the fix-location-assignment scheduled job for unseeded tenants.
2. Operator usability — Fix F2 converts a silent cross-order parcel-pointer corruption (no exception, wrong stock transferred) into a clean `BusinessException` with the parcel label and order number.
3. Minimal blast radius — three isolated fixes in three files; no new abstractions; no API change to widely-injected services.

**Alternatives considered.**
- *Option B — `SyspropService.getSysvalueAsLong(key, default)`:* Rejected. More reusable in principle, but only one class hits this pattern on a hot null-prone path; promoting to public API forces unit-test expansion and breaks the v1-mechanical-port pattern. Can be hoisted later if a second class needs it.
- *Option D — inline shortfall string in `validateStockOnStagingLane`:* Rejected. Discards the structured per-itemdata shortfall data that future UI / OMS work will need; record-extension (Option C) is the canonical place to capture it.

**Why A was chosen.** Smallest effective diff. Mirrors v1 `827a77e` and `f46cf06` mechanically. Defaults already exist in `WmsConstants` — a class-local helper is the right abstraction level for a single-call-site pattern. Constructor injection of `UnitloadRepository` matches v2's idiom.

**Consequences.**
- Positive: scheduled job no longer NPEs on green-field tenants; club run produces operator-actionable errors on parcel-label collision; staging-lane shortfall messages identify the specific short SKUs.
- Positive: per-order TX boundary from 260424 cleanly contains the parcel-label `BusinessException` rollback — downstream orders continue.
- Negative: one added indexed DB read per club order. Estimated <5ms p95; negligible against the existing per-order TX duration.
- Negative (Phase 2 only): `StockValidationResult` record signature change. Single caller in `CustomerorderBatchService`; ripple is confined.

**Follow-ups.**
1. Optional Flyway seed for the three bound `los_sysprop` keys per new tenant.
2. Codebase audit for other `Long.parseLong(syspropService.getSysvalue(...))` patterns; promote to CI lint if recurrence.
3. Future: surface `shortfallMap` to the operator UI / OMS notification.

### 9.2 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-260503-runclubline-transaction-boundary-hardening.sh`

The script (to be authored alongside this plan; tracked in §5.2 checklist) encodes:

**Positive checks (one per fix):**
- `check_fixB_helper_present` — grep `FixLocationAssignmentService.java` for `private long parseSyspropLong(String key, String defaultValue)`.
- `check_fixB_call_sites_replaced` — `grep -c 'parseSyspropLong(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_' FixLocationAssignmentService.java` ≥ 3.
- `check_fixF2_repo_injected` — grep `ClubLineOrderProcessor.java` for `UnitloadRepository unitloadRepository` in the constructor parameter list and as a field.
- `check_fixF2_guard_present` — grep `ClubLineOrderProcessor.java` for `unitloadRepository.findByLabelidForUpdate(order.getParcelexternalnumber()).isPresent()` followed within ~3 lines by `throw new BusinessException("Parcel label already in use: "`.
- `check_fixF2_no_nonlocking_guard` — grep `ClubLineOrderProcessor.java` for `unitloadRepository.findByLabelid(order.getParcelexternalnumber())` returns **0** (the non-locking variant must not be used as the guard).
- `check_fixF5_record_extended` — grep `CustomerorderBatchService.java` (or the record's home file) for `StockValidationResult(boolean sufficient, Map<Itemdata, List<Stockunit>> stockMap, Map<Itemdata, BigDecimal> shortfallMap)`.
- `check_fixF5_message_enriched` — grep for `"Not enough stock on location: " +` and `buildShortfallMessage(`.

**Negative checks:**
- `check_fixB_no_bare_parseLong_at_bounds` — grep `FixLocationAssignmentService.java` for `Long.parseLong(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_` returns **0** (the old pattern is gone).
- `check_fixF5_no_generic_message` — grep `CustomerorderBatchService.java` for the literal `"Not enough stock on location."` (with trailing period and no colon) returns **0**.

**Targeted test invocations (correctness gates):**
- `mvn test -Dtest=FixLocationAssignmentServiceUnitTest`
- `mvn test -Dtest=ClubLineOrderProcessorUnitTest`
- `mvn test -Dtest=CustomerorderBatchServiceUnitTest`

**Workflow contract.** A "DONE" claim is accepted only if all positive + negative checks pass and all three test classes are green. The script runs after every change pass; CI runs it on every push.

### 9.3 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 2 fixes (Phase 1) + 1 fix (Phase 2), single subsystem (runClub + the adjacent FixLocationAssignment scheduled job), no cross-service or contract change |
| **Pre-draft step** | analyst+planner (current) | This document is the planner output; analyst input drove the v1→v2 applicability matrix |
| **Plan-review step** | critic | Mandatory for Standard+ — should run before any code is written, particularly to validate the §2.1 matrix |
| **Implementation shape** | executor | Single agent; the plan is small enough that `ralph` would be overkill. If `wms-tdd-gate` is run first to author the failing tests, executor implements against those tests. |
| **Verification step** | `verify-260503-runclubline-transaction-boundary-hardening.sh` + verifier | Mandatory |
| **Code-review step** | code-reviewer | Optional for Standard; recommended here because Fix F2 introduces a new constructor parameter |
| **Commit step** | git directly | Two logical commits: Phase 1 (Fix B + Fix F2) and Phase 2 (Fix F5). `git-master` not required for this size. |

**Override rationale.** The plan is small (3 fixes total, 3 files), all changes are mechanical or near-mechanical, and the verify-script + targeted unit tests provide a tight green gate. A single `executor` against this plan is appropriate; scaling up to `ralph` or `team` adds orchestration overhead without proportional risk reduction.

**Sequence:**

1. `critic` reviews this plan; address any gaps.
2. `wms-tdd-gate` writes failing tests for A1-A4 (Phase 1) against current source; confirms they fail for the right reason; pauses for approval.
3. `executor` implements Fix B + Fix F2 against the failing tests; runs `verify-260503-runclubline-transaction-boundary-hardening.sh`; pastes output into the end-of-task report.
4. Commit Phase 1.
5. `wms-tdd-gate` writes failing test for A5 (Phase 2); pauses for approval.
6. `executor` implements Fix F5; re-runs verify script.
7. Commit Phase 2.
8. `code-reviewer` final pass.

#### Why this matters (the two failure modes)

- **Over-claim** is structurally prevented by the verify script's negative checks (the *old* `Long.parseLong(syspropService.getSysvalue(...))` and the literal `"Not enough stock on location."` must be **gone**, not just have new code added next to them).
- **Under-coverage** is structurally prevented by the explicit `WmsConstants` default values being baked into A1's assertion — the test fails if the helper falls back to anything other than 36/60/84.

#### Persistence — record lessons AFTER rollout

- `project_memory_add_directive` for the two patterns enumerated in §8 ("project-memory directives proposed").
- `notepad_write_priority` (short-term) noting that the 260503 plan completes the residual gaps from `f46cf06`/`827a77e` after the 260424 transaction-scope refactor — useful context for the next club-related plan.

#### Cross-plan references

- 260424-transaction-scope-refactoring-runclub-closebol.md (archived) — established the per-order TX boundary that this plan's Fix F2 leverages.
- SBDEV-2102-putaway-unit-load-not-found-stuck.md — same shape: v2-aware port of v1 fixes with explicit "applicable / not applicable" matrix and TDD-gate alignment.

---

## 10. Implementation Status

### Phase 1 — COMPLETED 2026-05-03

| Fix | Files changed | Status |
|-----|--------------|--------|
| Fix B (parseSyspropLong) | `FixLocationAssignmentService.java` | ✓ Done |
| Fix B (parseSyspropLong) | `ReplenishOrderJob.java` | ✓ Done |
| Fix F2 (findByLabelidForUpdate guard) | `UnitloadRepository.java`, `ClubLineOrderProcessor.java` | ✓ Done |

**Test classes added/extended:**
- `FixLocationAssignmentServiceUnitTest` — added `CreateFixedLocationAssignmentSyspropHandling` nested class (A1, A2)
- `ReplenishOrderJobTest` — added `MergePickingOrdersSyspropHandling` nested class (A2.1)
- `ClubLineOrderProcessorUnitTest` — added A3, A4 in `ProcessOrder` nested class; updated constructor to 5-param

**mvn test result:** Tests run: 3845, Failures: 0, Errors: 0, Skipped: 67 (baseline was 3840; 5 new gate tests added)

### Phase 2 — COMPLETED 2026-05-03

| Fix | Files changed | Status |
|-----|--------------|--------|
| Fix F5 (shortfall message) | `CustomerorderBatchService.java` | ✓ Done |

**Test classes extended:**
- `CustomerorderBatchServiceUnitTest` — added A5 in `RunClubLineCancelledOrderTests` nested class

**v2 commit SHA:** `8de5f4b`

**mvn test result:** Tests run: 3846, Failures: 0, Errors: 0, Skipped: 67 (baseline was 3845; 1 new gate test added)
