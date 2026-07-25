---
title: "SBDEV-1666 (v2) — Exclude Staging & Transfer Lanes from Replenishment Sourcing"
ticket: "SBDEV-1666"
ticket_url: "https://app.clickup.com/t/868g59mdu"
type: feature
priority: urgent
status: archived
project: [wms2]
version: v2
requester: ""
created: 2026-07-23
updated: 2026-07-23
db_verified: true
related:
  - "[[wms2-replenish-order-creation]]"
  - "[[wms2-replenish-workflow]]"
  - "[[SBDEV-1762-transfer-lane-club-like-depletion]]"
  - "[[wms2-multi-unitload-replenish]]"
tags:
  - plan
  - wms2
  - replenishment
  - staging-lane
  - transfer-lane
  - system-property-toggle
---

# SBDEV-1666 (v2) — Exclude Staging & Transfer Lanes from Replenishment Sourcing

**Ticket:** [SBDEV-1666](https://app.clickup.com/t/868g59mdu)
**Project:** wms2 | **Version:** v2 (`wms2-api`, Java 21 / Spring Boot 3.5.9) | **Type:** feature (behavior guarantee via toggle)
**Priority:** urgent
**Status:** Draft — consensus iteration 2 (Planner, post Architect + Critic). Bound for re-review.
**Date:** 2026-07-23
**db_verified:** `true` — see §2.6.

> **One-line intent:** Guarantee that **staging lanes and transfer lanes are never selected as a replenishment SOURCE** — matching v2's existing PutAwayLane behavior. If a lane holds the only stock for an item, **no replenish order is created** (`calculateOrder` throws `FacadeException "No replenish stock available"`, exactly as putaway does today). The **create/selection path** is delivered as a per-tenant opt-in system-property gate (default OFF); non-opted tenants are **plan-identical** to today. Three **display-only** surfaces (the monitor view + the two HAL-exposed open-request source queries) are corrected **unconditionally** because they cannot leak into a create path and cannot be guarded by a service branch.

---

## §0. Affected Sites

All paths relative to `v2/wms2-api/src/main/java/net/aim_ai/wms/` unless noted. **Repository package is `repo/jpa/`** (not `repository/`). Line numbers are as of authoring (develop head). Every in-scope row maps to a §3 subsection and a verify-script check (last two columns).

**Two treatment buckets** (the central architecture correction from iteration 1):

- **GATED (create/selection path):** boolean-parameterized single query + service-layer branch on the sysprop. Non-opted tenants get a plan-identical query (Postgres constant-folds `:excludeLanes = FALSE`). Applies to service-branchable queries only.
- **UNCONDITIONAL (display-only):** guard applied in place, no toggle, no twin. Applies to HAL-exposed queries that a service branch **cannot** intercept (Spring Data REST invokes the original `@RestResource` method straight from HTTP) and to the monitor view. Safe because none feeds a create path (`calculateOrder` re-selects its own source and takes no caller-chosen source id).

| # | file:line | Construct | Exposure / treatment | §3 | Verify |
|---|-----------|-----------|----------------------|----|--------|
| 1 | `repo/jpa/StockunitRepository.java:164-179` `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` (PRIMARY cron path; consumed `ReplenishGeneratorService.java:208,:211`) | source-selection native `@Query`; **currently HAL-exported (no `exported=false`), cron-only, no frontend consumer** | **GATED** — ADD `@RestResource(exported=false)` first, THEN boolean-param + service branch | 3.2, 3.4, 3.5 | A9, A9b |
| 2 | `repo/jpa/StockunitRepository.java:197-211` `getStockUnitInfoForReplenishment` (HAL-exported AND consumed `ReplenishorderService.java:384`) | source-info native `@Query` | **UNCONDITIONAL** — guard in place, no toggle, no twin (display-only; open-request screen calls it directly) | 3.6 | A14 |
| 3 | `repo/jpa/StockunitRepository.java:213-227` `getAvailableReplenishmentSources` (`exported=false`; consumed `ReplenishmentOrderMaintenanceService.java:365` `redirectSource`) | source-selection native `@Query` | **GATED** — boolean-param + service branch | 3.4, 3.5 | A9 |
| 4 | `repo/jpa/UnitloadRepository.java:135-148` `findUnitloadsByItemDataIdForReplenish` (`exported=false`; consumed hand-written `controller/UnitLoadController.java:214`) | source-selection native `@Query` | **GATED** — boolean-param + service branch | 3.4, 3.5 | A10 |
| 5 | `repo/jpa/StockunitRepository.java:181-195` `getStockUnitsForReplenishment` (HAL-exported AND consumed by wms2-web-ui open-request replenishment screen) | source-selection native `@Query` | **UNCONDITIONAL** — guard in place, no toggle, no twin (display-only) | 3.6 | A14 |
| 6 | `repo/jpa/FixLocationAssignmentRepository.java:39` `getRefillFixedLocations`, `:66` `getRefillFixedLocationIds` | shortage-detection `EXISTS(...useforreplenish='true')` | **GATED** — boolean-param + service branch (extra blast radius, §3.5) | 3.5 | A11 |
| 7 | `repo/jpa/ItemdataRepository.java:66` `getIdsForItemDataWithoutFixedAssignment` (value), `:116` `...Page` (value), **+ the `...Page` `countQuery` (line ~150) has its OWN 3rd `EXISTS(...useForReplenish)`** — **THREE guard sites total**, §3.5 | shortage-detection `EXISTS(...useForReplenish='true')` | **GATED** — boolean-param; all 3 EXISTS guarded | 3.5 | A11 |
| 8 | **NEW** `util/LocationReplenishabilityUtil.isUsableSourceLocation(...)` | new source-usability helper | **Add** | 3.1 | A3, A4 |
| 9 | `service/ReplenishmentOrderMaintenanceService.java:319-357` `isSourceUsable` (calls `isReplenishableArea :354`) | source-usability check | **GATED** — gains lane guard via #8 when ON (SyspropService already injected `:51`) | 3.7 | A6 |
| 10 | `service/ReplenishmentOrderMaintenanceService.java:359-421` `redirectSource` (flows via `getAvailableReplenishmentSources :365`) | source resync | **Assert only** — auto-covered once #3 branched | 3.7 | A6 |
| 11 | `service/ReplenishmentOrderSourceSyncService.java:69-125` `syncForMovedStockUnit` (only gate `if(!isReplenishableDestination(dest)){reassignOrCancel;return;}` at `:74`, `isReplenishableDestination :122-125`) | move-onto-lane resync | **GATED — DESTINATION-lane guard.** Widen the destination check so a **lane destination is treated as non-replenishable** → routes to `reassignOrCancelForMovedStockUnit`. **INJECT SyspropService** (class has none today) | 3.7 | A7, A7b |
| 12 | `service/mobile/MobileReplenishService.java:317` (validates scanned manual re-source target ONLY via `locationAreaRepository...getUseforreplenish()`; then `setStockToReplenishMobileOrder(...) :350`) | manual re-source create/selection | **GATED** — add sysprop-gated lane check on the scanned target (SyspropService already injected `:43`). `:600`/`:820` consumers inherit #1's guard | 3.7 | A15 |
| 13 | `service/WmsConstants.java` (`*_ACTIVATED_*` block, SBDEV-1762 precedent `:1046-1047`) | new sysprop key + default | **Add** | 3.3 | A1 |
| 14 | `repo/jpa/ReplenishmentMonitorViewRepository.java:70-113` — `getReplenishViewSummary()`; buckets are **CASE-WHEN inside `sum()`/`string_agg()`**, NOT a WHERE clause (`:84` non-repl sum, `:88` non-repl string_agg, `:92` repl sum, `:96` repl string_agg) | monitor-view native SQL | **UNCONDITIONAL** — pure display correction (D4) | 3.8 | A8 |
| 15 | `service/ReplenishGeneratorService.java:191-271` `calculateOrder` (`@Transactional REQUIRES_NEW`; fallback `stockList.get(0)`; sets `sourcelocationname`) | order-creation consumer | Note-only — takes no caller-chosen source id; inherits eligibility from guarded #1 | 3.4 | — |
| 16 | `service/ReplenishGeneratorService.java:299-314` `createOrderFromTemplate` (multi-UL split) | order-creation consumer | Note-only — inherits eligibility from selected stock | 3.4 | — |
| 17 | `util/LocationReplenishabilityUtil.isReplenishableArea(LocationAreaRepository, Long)` (existing, SBDEV-2074) | destination-area helper | **No change** — DESTINATION semantics preserved; do NOT overload | 3.1 | A5 (NEG) |
| 18 | `service/ReplenishmentOrderMaintenanceService.java:197` destination `isReplenishableArea` call-site | destination check | **No change** — untouched | 3.7 | A5 (NEG) |
| 19 | `repo/jpa/ReplenishorderRepository.java:114-140` `getIdsForUnreachableReplenishOrders` (`la.useforreplenish=false`) | cancel-unreachable | **Review / no-change** — already area-based; no lane-sourced order is ever created (§3.9) | 3.9 | — |

**Sysprop read path** (`service/SyspropService.java`): `getSysvalue :289` is a plain `syspropRepository.findSysvalueBySyskey(key)` — it returns `null` when the row is absent (NO auto-create, NO default-tier resolution). An absent row therefore yields `Boolean.parseBoolean(null) == false` → OFF, which is the intended default. Served from the Caffeine `"sysprops"` cache, evicted `@CacheEvict` on `setSysvalue`. The `*_DEFAULT_VALUE="false"` constant documents the intended default; it is not consulted by `getSysvalue` (the OFF default is enforced by `parseBoolean(null)`).

**Entity flags** (`model/Location.java`): `:33 staginglane (Boolean)`, `:35 transferlane (Boolean)`. Both nullable `Boolean` → SQL `IS NOT TRUE` handles null correctly; Java side uses `Boolean.TRUE.equals(...)`.

---

## §1. Problem Statement

Replenishment sourcing in v2 must **never** pull stock **from** a staging lane or a transfer lane. These lanes are outbound-staging surfaces (order build-up, truck marshalling); treating them as replenishment source deep-storage would pull already-committed / in-transit stock back into the pick faces and corrupt outbound flow.

Three truths shape this ticket:

1. **This is a config-INDEPENDENT GUARANTEE, not a reproducing bug fix.** v2 today excludes lanes from sourcing **purely** via the area-level `location_area.useforreplenish=true` filter — there is **no** name-based or type-based code exclusion and **no** v1-style "N/A last-resort" branch. On DB-verified tenants (`wms2-wineco-dev`, `wms2-hydra-dev2`) every staging/transfer lane sits in an `Outbound` area whose `useforreplenish=false`, so lanes are **already** excluded there (§2.6). The ticket exists to make that exclusion a **code-level invariant keyed on the lane flags themselves** rather than a per-tenant area-config coincidence that a mis-configured tenant (a lane area accidentally flagged `useforreplenish=true`) could silently break.

2. **The monitor view mis-buckets lane stock.** `ReplenishmentMonitorViewRepository.getReplenishViewSummary()` (`:70-113`) buckets non-replenishable via a **CASE-WHEN** on `loc_area.name IN ('Inbound','Default','users')` (`:84,:88`) and replenishable via a CASE-WHEN on `useforreplenish=true` (`:92,:96`). Outbound-area staging/transfer lane stock falls into **neither** bucket, so it silently disappears from the monitor. Display defect, independent of the sourcing guarantee.

3. **The two HAL-exposed source queries leak lane stock into a display.** `getStockUnitInfoForReplenishment` (#2) and `getStockUnitsForReplenishment` (#5) are exported by Spring Data REST and called **directly** by the wms2-web-ui open-request replenishment screen, which shows the operator the candidate source stock for an item. Because HTTP invokes the **original** `@RestResource` method, a service-layer branch can never guard them — the fix must live **in the query body**. This is display-only (no create-path risk — see §3.4), so the guard is applied **unconditionally**.

### Scope contract (USER-CONFIRMED — see §10)

- **Match v2 CURRENT PutAwayLane behavior:** lanes are never selected as a source; if a lane holds the only stock for an item, **no order is created** (`calculateOrder` throws `FacadeException "No replenish stock available"` exactly as putaway does today).
- **Out of scope:** any v1-style "create order with source marked N/A" path. Never build it.
- **Out of scope:** SBDEV-1762 (transfer-lane club-like depletion) — separate ticket.

---

## §2. Current Architecture

### 2.1 Mechanism truth — how lanes are excluded today

v2 excludes lanes from replenishment sourcing **only** through the area-level `location_area.useforreplenish='true'` join filter present in every source-selection query. There is **NO** name/type code exclusion and **NO** N/A-last-resort branch anywhere; exclusion is **entirely** a function of tenant area configuration.

### 2.2 Source-selection queries (each JOINs `location` and filters `useforreplenish='true'`)

| Query | file:line | Consumer | Exposure |
|-------|-----------|----------|----------|
| `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` | `repo/jpa/StockunitRepository.java:164-179` | `ReplenishGeneratorService.java:208,:211` | HAL-exported, **cron-only** (no frontend consumer) → safe to set `exported=false` |
| `getStockUnitInfoForReplenishment` | `repo/jpa/StockunitRepository.java:197-211` | `ReplenishorderService.java:384` **AND** open-request screen (HAL) | HAL-exported + consumed |
| `getAvailableReplenishmentSources` | `repo/jpa/StockunitRepository.java:213-227` | `ReplenishmentOrderMaintenanceService.java:365` (`redirectSource`) | `exported=false` |
| `findUnitloadsByItemDataIdForReplenish` | `repo/jpa/UnitloadRepository.java:135-148` | `controller/UnitLoadController.java:214` | `exported=false`, hand-written controller |
| `getStockUnitsForReplenishment` | `repo/jpa/StockunitRepository.java:181-195` | wms2-web-ui open-request replenishment screen (HAL) | HAL-exported + consumed |

**Aliases (verified, needed for the guard — §3):** #1 joins `location` with **NO alias** and uses `area.useForReplenish` (camelCase); #2/#5 use `loc`/`a`; #3 uses `loc`/`area`; #4 uses `loc`/`a`.

### 2.3 Shortage-detection queries (`EXISTS` on `useforreplenish='true'`)

- `repo/jpa/FixLocationAssignmentRepository.java:39` `getRefillFixedLocations`, `:66` `getRefillFixedLocationIds` — `EXISTS(...)` sub-select aliases `location` as `lo`.
- `repo/jpa/ItemdataRepository.java:66` `getIdsForItemDataWithoutFixedAssignment`, `:116` `...Page` — `EXISTS(...)` sub-select joins `location` with **NO alias**, uses `location_area.useForReplenish` (camelCase). **The `...Page` method (decl `:151`) also carries a separate `countQuery` with its own duplicate `EXISTS(...useForReplenish)` block** — both the value query and the countQuery must be guarded (§3.5).

These decide **which items are considered short and eligible for a refill trigger**. Guarding them (§3.5) narrows the shortage universe so lane-only stock is never counted as "available to refill from"; extra blast radius called out in §3.5.

### 2.4 Order creation

`ReplenishGeneratorService.calculateOrder` (`:191-271`) — `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW, rollbackFor={FacadeException.class, BusinessException.class})`. It takes `(itemDataId, amount, destinationId, priority)` — **no caller-chosen source id**; it re-selects its own source via #1 (`:208` deep-storage=false, then `:211` deep-storage=true), falls back to `stockList.get(0)`, sets `sourcelocationname`. `createOrderFromTemplate` (`:299-314`, multi-UL split) issues no direct query. Both are **consumers**: once #1 excludes lane rows, no lane can be picked, and an item whose only stock is on a lane yields an empty list → existing `FacadeException "No replenish stock available"` (matching putaway). **This is exactly why #2/#5 can be corrected unconditionally without create-path risk** (§3.6).

### 2.5 Source-usability / resync mirror surfaces (the SBDEV-2074 leak-bug class)

- `ReplenishmentOrderMaintenanceService.isSourceUsable :319-357` — SOURCE check; calls `isReplenishableArea :354`. `SyspropService` **already injected** (`:51`). Must gain the lane guard when ON.
- `ReplenishmentOrderMaintenanceService.redirectSource :359-421` — flows through `getAvailableReplenishmentSources :365`; **auto-covered** once #3 is branched; assert only.
- `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit :69-125` — on a stock move its **only** gate is `if(!isReplenishableDestination(destinationLocation)){ reassignOrCancel; return; }` (`:74`). There is **no source-usability branch and no source Location in scope** — the method only has the moved `Stockunit` and the `destinationLocation`. `isReplenishableDestination :122-125` delegates to `isReplenishableArea`. The class has **NO SyspropService** (constructor deps `:48-56`: `replenishorderRepository`, `locationRackRepository`, `locationAreaRepository`, `@Lazy replenishmentOrderMaintenanceService`).
- `MobileReplenishService :317` — validates a scanned **manual** re-source target with `locationAreaRepository.findById(...).getUseforreplenish()` only (no lane-flag check), then `setStockToReplenishMobileOrder(...) :350`. `SyspropService` **already injected** (`:43`). This lets an operator manually re-point a source onto a lane, defeating the invariant.

**Existing helper:** `util/LocationReplenishabilityUtil.isReplenishableArea(LocationAreaRepository, Long areaId)` returns `false` for a null/unflagged area (SBDEV-2074). This is **destination** semantics used at `ReplenishmentOrderMaintenanceService:197` and `ReplenishmentOrderSourceSyncService:124` and must be left untouched.

### 2.6 DB-Verification — `true`

Verified live on `wms2-wineco-dev` and `wms2-hydra-dev2`:

| Location group | Location count | `location.staginglane` | `location.transferlane` | Area | `location_area.useforreplenish` |
|----------------|----------------|------------------------|--------------------------|------|----------------------------------|
| `PutAwayLane` | — | false/null | false/null | `Inbound` | **false** |
| `StagingLane01`–`StagingLane20` | 20 | **true** | false/null | `Outbound` | **false** |
| `TransferLane01`–`TransferLane06` | 6 | false/null | **true** | `Outbound` | **false** |
| bare `Transfer` | 1 | false/null | **false/null (not flagged!)** | `Outbound` | **false** |

**Establishes:**
1. Lanes are **already** excluded from sourcing on these tenants (`useforreplenish=false`) — this ticket is a *guarantee*, not a reproduction (§1).
2. `staginglane=true` on **20** locations and `transferlane=true` on **6** — a flag-based code guard has real rows to key on.
3. The bare `Transfer` location is **neither** flagged nor name-matchable — see OQ2; the guard relies on `Location.transferlane`, so it would **not** be excluded until its flag is corrected (data-quality follow-up).
4. `WmsConstants.java:764/:777-788` name lists are **INCOMPLETE** (DB has StagingLane01-20; constants stop at 06) — confirming we must key on the `Location` flags, never name-match.

---

## §3. Design

**Chosen mechanism (D2):** a **code guard on the Location-level boolean flags** — `<alias>.staginglane IS NOT TRUE AND <alias>.transferlane IS NOT TRUE` — added to source-selection and shortage-detection queries, mirrored at the service layer through **one** new helper `LocationReplenishabilityUtil.isUsableSourceLocation`. Not area-flag/config only.

**Chosen gate strategy (D3):** two treatments driven by **query exposure** (see §0):
- **Service-branchable queries → GATED via a boolean-parameterized single query.** No twin. See §3.2.
- **HAL-exposed queries a service cannot intercept (#2, #5) + the monitor view → UNCONDITIONAL guard in place.** See §3.6, §3.8.

### 3.1 New helper — `LocationReplenishabilityUtil.isUsableSourceLocation` (§0 #8)

```java
// SOURCE usability = replenishable area AND not a staging/transfer lane.
// Does NOT touch isReplenishableArea (DESTINATION semantics, SBDEV-2074) — that stays as-is.
public static boolean isUsableSourceLocation(LocationAreaRepository areaRepo, Location loc) {
    if (loc == null) return false;
    if (Boolean.TRUE.equals(loc.getStaginglane()))  return false;   // Location.java:33
    if (Boolean.TRUE.equals(loc.getTransferlane()))  return false;  // Location.java:35
    return isReplenishableArea(areaRepo, loc.getAreaId());          // existing helper, unchanged
}
```

- `Boolean.TRUE.equals(...)` is null-safe (nullable flags per `Location.java:33/35`).
- Do **NOT** overload `isReplenishableArea` — destination semantics, consumed at `ReplenishmentOrderMaintenanceService:197` / `ReplenishmentOrderSourceSyncService:124`, must stay untouched (§0 #17, #18).

### 3.2 Service-layer gate — boolean-PARAMETERIZED single query (D3, GATED queries only)

For each service-branchable source/shortage query (§0 #1, #3, #4, #6, #7), **add a bound boolean parameter and a lane clause to the SAME query** — no duplicate `_excludingLanes` twin:

```sql
-- existing FROM/JOIN/WHERE ... AND <area-alias>.useforreplenish = 'true'
AND (:excludeLanes = FALSE
     OR (<loc-alias>.staginglane IS NOT TRUE AND <loc-alias>.transferlane IS NOT TRUE))
```

```java
// signature gains a boolean param:
List<StockunitIdAmountView> getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage(
    @Param("notLocked") int notLocked, @Param("itemDataId") Long itemDataId,
    @Param("useForDeepStorage") Boolean useForDeepStorage, @Param("excludeLanes") boolean excludeLanes);

// service reads the sysprop once and passes an EXPLICIT boolean (NEVER null):
boolean excludeLanes = Boolean.parseBoolean(
    syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY));
```

**Why parameterized, not twin queries:** in Postgres `:excludeLanes = FALSE` constant-folds so the lane predicate is provably never evaluated when OFF → the plan is **identical** to today's (verify with `EXPLAIN`), so OFF is non-regressive. A single query also halves the surface and removes the twin-SQL drift risk (two hand-maintained copies of a large native query inevitably diverge).

> **GOTCHA (must-follow):** a **NULL-bound** param makes `null = FALSE` evaluate to `NULL`, and `NULL OR (…)` drops the row unless the lane clause is true — i.e. lanes get excluded **as if ON**. Therefore the service **ALWAYS** passes an explicit `boolean` (primitive, never `Boolean`/null). The HAL-exposed queries (#2/#5) must **NOT** thread this param at all (they have no service call site to bind it) — they are corrected unconditionally in §3.6.

> **Correction to iteration-1 claim:** the earlier draft asserted a native `@Query` "cannot be toggled inline" and cited the `OR :param=''` hazard. **Both are wrong here.** A native `@Query` **can** be toggled by a bound boolean param; the `OR :param=''` hazard is **STRING-specific** (empty-string vs NULL) and does not apply to a boolean flag. The parameterized guard is the chosen mechanism for all service-branchable queries.

### 3.3 System-property toggle (§0 #13 — `WmsConstants.java`, SBDEV-1762 precedent `:1046-1047`)

```java
// SBDEV-1666 — Exclude staging/transfer lanes from replenishment SOURCING, per-tenant opt-in.
public static final String SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY =
        "REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED";
public static final String SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_DEFAULT_VALUE =
        "false";
```

- `getSysvalue` (`SyspropService.java:289`) is a global-per-tenant lookup; each tenant is a separate DB, so the `los_sysprop` row **is** the per-tenant opt-in.
- `Boolean.parseBoolean(null) → false` → absent row = default OFF, safe.
- Served from the `"sysprops"` Caffeine cache; evicted `@CacheEvict` on `setSysvalue`.
- Read **per-item inside the cron loop**, not once per pass: `ReplenishOrderJob:174` iterates `affectedItemIds` and calls `calculateOrder` per item, so the sysprop is read once per `calculateOrder` invocation. Because it is Caffeine-cached the cost is negligible; a mid-pass flip is still safe.

### 3.4 GATED source-selection query guards (§0 #1, #3, #4) & order-creation consumers (§0 #15, #16)

Apply §3.2 to the three service-branchable source queries with the **correct per-query alias**:

| # | Query | loc alias for guard | area alias / flag |
|---|-------|---------------------|-------------------|
| 1 | `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` | `location.staginglane` / `location.transferlane` (**NO alias** on the `location` join) | `area.useForReplenish` (camelCase — harmless in PG, see note) |
| 3 | `getAvailableReplenishmentSources` | `loc.staginglane` / `loc.transferlane` | `area.useforreplenish` |
| 4 | `findUnitloadsByItemDataIdForReplenish` | `loc.staginglane` / `loc.transferlane` | `a.useforreplenish` |

**Prerequisite for #1:** it is currently HAL-exported with no `exported=false`. Because Spring Data REST would otherwise expose the parameterized method (and a bad HAL caller could pass `excludeLanes=false`), **add `@RestResource(exported=false)` to #1 first** (it is cron-only, verified no frontend consumer), THEN parameterize + branch at `ReplenishGeneratorService:208,:211`. #3 and #4 are already `exported=false`.

Wiring points: #1 → `ReplenishGeneratorService.java:208,:211`; #3 → `ReplenishmentOrderMaintenanceService.java:365`; #4 → `controller/UnitLoadController.java:214`.

> **camelCase note:** #1 uses `area.useForReplenish` and #7 uses `location_area.useForReplenish` (camelCase) while others use lowercase. In Postgres unquoted identifiers case-fold, so this is **harmless** — do NOT "fix" it; keep each query's existing casing and only add the lane clause.

**Consumers (#15, #16):** no direct query change. Once #1 excludes lane rows, `calculateOrder`'s `stockList` never contains a lane, the `stockList.get(0)` fallback cannot land on a lane, and a lane-only item yields an empty list → existing `FacadeException "No replenish stock available"` (matches putaway, AC2). `createOrderFromTemplate` inherits eligibility from the already-selected stock.

### 3.5 GATED shortage-detection query guards (§0 #6, #7)

Add the parameterized guard inside the `EXISTS(...)` sub-select of each method (per-query alias):

```sql
-- #6 FixLocationAssignmentRepository (EXISTS aliases location as `lo`):
... AND area.useforreplenish = 'true'
    AND (:excludeLanes = FALSE OR (lo.staginglane IS NOT TRUE AND lo.transferlane IS NOT TRUE)) )

-- #7 ItemdataRepository (EXISTS joins location with NO alias, uses location_area.useForReplenish):
... AND location_area.useForReplenish = 'true'
    AND (:excludeLanes = FALSE OR (location.staginglane IS NOT TRUE AND location.transferlane IS NOT TRUE)) )
```

**countQuery gap (MUST — Architect iter-2 finding):** `ItemdataRepository` has **THREE** `EXISTS(... useForReplenish = 'true')` sites, not two: (a) `getIdsForItemDataWithoutFixedAssignment` value query (~line 77), (b) `getIdsForItemDataWithoutFixedAssignmentPage` value query (~line 116), and (c) the **`...Page` `countQuery`** (~line 150), whose string contains its **own** duplicate `EXISTS`. Apply the **same** `AND (:excludeLanes = FALSE OR (location.staginglane IS NOT TRUE AND location.transferlane IS NOT TRUE))` clause inside **all three** EXISTS blocks. If the buried countQuery (c) is missed, then when the gate is ON the value query excludes lane-only short items but the countQuery still counts them → `Page.getTotalElements()` over-reports relative to returned rows (silent count/page divergence, opted-in tenants only; OFF folds true in all three, no divergence). Spring Data binds `:excludeLanes` to both the value and count queries, so this is a semantic-consistency fix. **Verify A11 asserts the lane clause appears ≥3× in `ItemdataRepository.java` AND pins one occurrence to a `countQuery` context** — a 2-of-3 miss fails the gate.

**Blast-radius note (OQ4 in scope):** these queries feed the "what is short / what has no fixed assignment" determination. Guarding them means lane-only stock stops counting as "available to refill from" — intended, but wider than the pure source path. Confined to opted-in tenants by the sysprop.

### 3.6 UNCONDITIONAL display correction — HAL-exposed source queries (§0 #2, #5)

`getStockUnitInfoForReplenishment` (#2, `:197`, `loc`/`a`) and `getStockUnitsForReplenishment` (#5, `:181`, `loc`/`a`) are exported by Spring Data REST and called **directly** from HTTP by the wms2-web-ui open-request replenishment screen. **A service-layer branch cannot guard them** — HTTP invokes the original `@RestResource` method, bypassing any twin. So the guard goes **in the query body, unconditionally, no toggle, no param, no twin:**

```sql
-- add to BOTH #2 and #5, after `AND a.useforreplenish = true`:
AND loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE
```

**Why unconditional is safe (no create-path risk):** `calculateOrder` (§2.4) re-selects its own source via #1 and takes **no caller-chosen source id**, so nothing an operator sees on this screen becomes an order's source through a create path. #2 is also service-consumed at `ReplenishorderService:384` (source-info display of an existing order) — unconditional exclusion is still correct there because **"lanes are never a valid source" is a universal display truth**, not a tenant-configurable one. This puts #2/#5 in the **same unconditional bucket as the monitor view** (§3.8).

**AC9 (HAL display leak):** the open-request screen stops showing lane stock as a candidate source. Verify asserts #2/#5 carry the guard in-body **and** that **no `_excludingLanes` twin exists** for them (A14).

### 3.7 Service-mirror — usability & resync (§0 #9, #10, #11, #12)

- **#9 `isSourceUsable` (`:319-357`, GATED):** when the sysprop is ON, replace the `isReplenishableArea(area :354)` source-usability decision with `LocationReplenishabilityUtil.isUsableSourceLocation(locationAreaRepository, sourceLocation)`; OFF path calls the legacy `isReplenishableArea` unchanged. `SyspropService` already injected (`:51`). **No new injection needed here.** Satisfies AC5.
- **#10 `redirectSource` (`:359-421`, ASSERT):** auto-covered because it sources candidates from `getAvailableReplenishmentSources` (#3, branched at `:365`). Assert with a unit test that no lane candidate is returned; no code edit beyond #3.
- **#11 `syncForMovedStockUnit` (`:69-125`, GATED — DESTINATION-lane guard):** the method's only gate is the destination check at `:74`; there is **no source Location in scope**. To guarantee that a move **onto a lane** routes to `reassignOrCancelForMovedStockUnit`, the **DESTINATION check must reject lane destinations.** Change `isReplenishableDestination` so that, **when the sysprop is ON**, a `destinationLocation` with `staginglane IS TRUE` or `transferlane IS TRUE` is treated as **non-replenishable** (→ falls into the existing `reassignOrCancel; return;` branch). This is a **destination-is-not-a-lane** guard, **NOT** `isUsableSourceLocation`. **INJECT `SyspropService`** into the class (add to the constructor `:48-56` and a field) — it currently has none. Leave the `isReplenishableArea` delegation for the OFF path intact. Satisfies AC4.

  ```java
  // ReplenishmentOrderSourceSyncService.isReplenishableDestination (revised):
  private boolean isReplenishableDestination(Location destination) {
      if (destination == null) return false;
      boolean excludeLanes = Boolean.parseBoolean(syspropService.getSysvalue(
          WmsConstants.SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY));
      if (excludeLanes
          && (Boolean.TRUE.equals(destination.getStaginglane())
              || Boolean.TRUE.equals(destination.getTransferlane()))) {
          return false; // move onto a lane -> reassignOrCancel path
      }
      return LocationReplenishabilityUtil.isReplenishableArea(locationAreaRepository, destination.getAreaId());
  }
  ```

- **#12 `MobileReplenishService:317` (GATED):** the scanned manual re-source target is validated only by `getUseforreplenish()`. Add a sysprop-gated lane check: when ON, reject the target if `storageLocation.getStaginglane()`/`getTransferlane()` is TRUE (throw the existing `BusinessException "Location not usable to replenish from!"`). `SyspropService` already injected (`:43`). This is part of the source-selection/create path → **GATED**. `:600` (`calculateOrder`) and `:820` (`createOrderFromTemplate`) are consumers that inherit #1's guard — no edit there.

**Destination semantics preserved:** `isReplenishableArea` itself and its OFF-path call-sites (§0 #17, #18) are not modified — the verify script asserts this negatively (A5).

### 3.8 Monitor-view widening (§0 #14, D4 — UNCONDITIONAL)

`ReplenishmentMonitorViewRepository.getReplenishViewSummary()` (`:70-113`) buckets stock inside **CASE-WHEN expressions within `sum()`/`string_agg()`** (NOT a WHERE clause):
- `on_non_replenishable_location` sum CASE (`:84`) + `on_non_replenishable_location_names` `string_agg(... CASE ...)` (`:88`) ← `loc_area.name IN ('Inbound','Default','users')`.
- `on_replenishable_location` sum CASE (`:92`) + `on_replenishable_location_names` `string_agg(... CASE ...)` (`:96`) ← `loc_area.useforreplenish = true`.

Widen **all four** CASE branches (alias `loc`):

```sql
-- :84 non-repl sum CASE — ADD lane membership:
WHEN loc_area.name::text = ANY (ARRAY['Inbound','Default','users']::...)
     OR loc.staginglane IS TRUE OR loc.transferlane IS TRUE THEN su.amount
-- :88 non-repl string_agg CASE — same OR-widening
-- :92 repl sum CASE — EXCLUDE lanes so a mis-configured tenant (lane area useforreplenish=true)
--     does not DOUBLE-COUNT lane stock into both buckets:
WHEN loc_area.useforreplenish = true
     AND loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE THEN su.amount
-- :96 repl string_agg CASE — same AND-exclusion
```

**Explicitly NOT sysprop-gated:** pure additive display correction with no sourcing effect. The lane-exclusion added to the replenishable CASE (`:92,:96`) prevents double-counting on a mis-configured tenant. **AC8** asserts lane flags appear in **BOTH** the non-replenishable and replenishable CASE branches.

### 3.9 Cancel-unreachable interplay (§0 #19 — review / no-change)

`ReplenishorderRepository.getIdsForUnreachableReplenishOrders (:114-140)` selects orders whose source-area `la.useforreplenish=false`. Under the guarantee we **never create** a lane-sourced order, so this path has nothing new to cancel. A legacy lane-sourced order on a `useforreplenish=false` lane area (all verified tenants, §2.6) is **already** cancelled by it — desirable. **No change**; recorded so a reviewer does not re-open it.

### 3.10 Concurrency / horizontal-scalability posture

No new in-JVM state, no new `@Scheduled` job, no new transaction boundary. The gate reads the existing per-tenant `"sysprops"` Caffeine cache (a per-tenant config value, not shared mutable state). Parameterized queries run inside the existing `calculateOrder` `REQUIRES_NEW` tenant transaction. Full analysis in the Horizontal Scalability table below.

---

## §4. File Change Summary

Every row maps to a §0 in-scope item, a §3 subsection, and a verify check.

| # | File | Change | Treatment | Type |
|---|------|--------|-----------|------|
| 1 | `service/WmsConstants.java` (`*_ACTIVATED_*` block, ~`:1046`) | Add `SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY` + `…_DEFAULT_VALUE="false"` | — | Add |
| 2 | `util/LocationReplenishabilityUtil.java` | Add `isUsableSourceLocation(LocationAreaRepository, Location)`; leave `isReplenishableArea` untouched | — | Add method |
| 3 | `repo/jpa/StockunitRepository.java` | #1: add `@RestResource(exported=false)` + parameterize (`excludeLanes`) `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` (`:164`, `location.` alias); #3: parameterize `getAvailableReplenishmentSources` (`:213`, `loc.`); **#2 `getStockUnitInfoForReplenishment` (`:197`, `loc.`) + #5 `getStockUnitsForReplenishment` (`:181`, `loc.`): add lane guard UNCONDITIONALLY in-body (no param)** | GATED (#1,#3) / UNCONDITIONAL (#2,#5) | Modify queries |
| 4 | `repo/jpa/UnitloadRepository.java` | Parameterize `findUnitloadsByItemDataIdForReplenish` (`:135`, `loc.`) | GATED | Modify query |
| 5 | `repo/jpa/FixLocationAssignmentRepository.java` | Parameterize `getRefillFixedLocations` (`:39`, `lo.`), `getRefillFixedLocationIds` (`:66`, `lo.`) | GATED | Modify queries |
| 6 | `repo/jpa/ItemdataRepository.java` | Parameterize `getIdsForItemDataWithoutFixedAssignment` (`:66`) + `...Page` (`:116`) value query **AND its separate `countQuery`** (both carry `EXISTS(...useForReplenish)`); `location.`, no alias | GATED | Modify queries |
| 7 | `service/ReplenishGeneratorService.java:208,:211` | Read sysprop; pass `excludeLanes` to #1 (PRIMARY path) | GATED | Modify |
| 8 | `service/ReplenishmentOrderMaintenanceService.java:319-357,:365` | `isSourceUsable` → `isUsableSourceLocation` (ON); `redirectSource` passes `excludeLanes` to #3. SyspropService already injected `:51` | GATED | Modify |
| 9 | `service/ReplenishmentOrderSourceSyncService.java:69-125` | **INJECT SyspropService**; widen `isReplenishableDestination` so a lane destination is non-replenishable when ON (routes to reassignOrCancel) | GATED | Modify + inject |
| 10 | `service/mobile/MobileReplenishService.java:317` | Add sysprop-gated lane check on scanned manual re-source target. SyspropService already injected `:43` | GATED | Modify |
| 11 | `controller/UnitLoadController.java:214` | Read sysprop; pass `excludeLanes` to #4 | GATED | Modify |
| 12 | `repo/jpa/ReplenishmentMonitorViewRepository.java:70-113` | Widen all 4 CASE branches (`:84,:88` non-repl add lanes; `:92,:96` repl exclude lanes) — UNCONDITIONAL | UNCONDITIONAL | Modify |
| 13 | `test/…` (unit suites, §7) | Add ON/OFF + unconditional tests; keep existing green | — | Test |
| 14 | `sbdocs/9-System/scripts/verify-SBDEV-1666-...sh` | New acceptance script | — | Add |

**No changes:** `isReplenishableArea` and its destination call-sites (§0 #17, #18); `ReplenishorderRepository.getIdsForUnreachableReplenishOrders` (§3.9); DB schema (no Flyway *schema* migration — `Location.staginglane`/`transferlane` and `useforreplenish` already exist; **V2.2.04** adds only a data-only sysprop seed).

---

## §5. Phased Implementation Plan

### §5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change (data-only seed). `Location.staginglane`/`.transferlane` and `location_area.useforreplenish` already exist. Flyway **V2.2.04** (`V2.2.04__seed_lane_behavior_sysprop_toggles.sql`, wms2-api PR #93) seeds `los_sysprop` `syskey='REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED'` **default OFF** (`sysvalue='false'`) on freshly provisioned DBs; opting-in tenants flip it to `'true'`. Absent row = OFF. | DBA / ops | V2.2.04 = data seed, **no DDL**. Existing tenants (running app does **not** invoke Flyway) are seeded by an operator running `flyway migrate` (or `psql`-applying `V2.2.04__seed_lane_behavior_sysprop_toggles.sql`) against the tenant DB. Per-tenant opt-in (`sysvalue='true'`) is a separate step via `configure-client-sysprops.sh` / `SyspropService.setSysvalue`. |
| 2 | **Feature flags** | Ship default OFF. Set `true` only on tenants that requested lane-source exclusion. | ops | Per-tenant opt-in. |
| 3 | **Config / env** | N/A — no properties/jasypt/keycloak change. | — | Pure toggle-in-DB. |
| 4 | **Deploy-order** | N/A — WMS-only; no endpoint contract change. Monitor-view + HAL-query display corrections are additive. | — | — |
| 5 | **Data migration** | N/A. Enablement = one `setSysvalue` per opting-in tenant. **PREREQUISITE (OQ1):** confirm the target client's lane-area config on prod/UAT before enabling. | ops | Dev already excludes lanes; reproduce there first. |
| 6 | **External systems** | N/A. | — | — |
| 7 | **Access / permissions** | N/A. | — | — |
| 8 | **Monitoring** | Optional: watch `calculateOrder` `FacadeException "No replenish stock available"` rate for opted-in tenants (expected to rise for lane-only items — the guarantee firing). | ops | No new metric. |

### §5.2 Implementation Checklist

- [ ] **P1:** Add sysprop key + default in `WmsConstants.java`.
- [ ] **P1:** Add `LocationReplenishabilityUtil.isUsableSourceLocation`; leave `isReplenishableArea` untouched.
- [ ] **P1:** Add `@RestResource(exported=false)` to #1, then parameterize (`excludeLanes`) the GATED source/shortage queries (#1,#3,#4,#6,#7).
- [ ] **P1:** Add UNCONDITIONAL in-body lane guard to #2 and #5 (no param, no twin).
- [ ] **P1:** Wire service branches: RGS:208/:211, ROMS:365 (+ `isSourceUsable`), UnitLoadController:214; inject SyspropService into RSSS + widen `isReplenishableDestination`; add lane check at MobileReplenishService:317.
- [ ] **P1:** Widen monitor-view 4 CASE branches (UNCONDITIONAL).
- [ ] **P2:** Add ON/OFF + unconditional unit tests (§7.1); confirm existing tests stay green unmodified.
- [ ] **P2:** `mvn clean compile` + targeted `mvn test`.
- [ ] **P2:** Run `verify-SBDEV-1666-...sh` → 0 FAIL.
- [ ] **P3 (ops, per opting-in tenant):** confirm lane-area config (OQ1) → `setSysvalue(...true)` → run Manual Test Plan (§7.3).

---

## §6. Backward Compatibility

| Aspect | OFF (default, all existing tenants) | ON (opt-in) |
|--------|-------------------------------------|-------------|
| GATED source/shortage queries (#1,#3,#4,#6,#7) | `:excludeLanes=FALSE` constant-folds → **plan-identical** to legacy | lane predicate active |
| `isSourceUsable` (#9) | `isReplenishableArea` (unchanged) | `isUsableSourceLocation` (adds lane guard) |
| `syncForMovedStockUnit` (#11) | `isReplenishableArea` destination check (unchanged) | lane destination → non-replenishable → reassignOrCancel |
| `MobileReplenishService:317` (#12) | area-only check (unchanged) | scanned lane target rejected |
| `calculateOrder` behavior | as today | lane never in source list; lane-only item → existing `FacadeException` |
| **HAL #2/#5** (open-request screen) | **CHANGES for ALL tenants** (unconditional display correction — lane stock no longer shown as a source) | same as OFF |
| **Monitor view** (#14) | **CHANGES for ALL tenants** (unconditional display correction) | same as OFF |
| `getIdsForUnreachableReplenishOrders` | unchanged | unchanged |
| DB schema / Flyway / endpoint contracts | no schema/contract change; **V2.2.04** data-only sysprop seed (default OFF) | no schema/contract change |
| Existing tests | pass **unmodified** | new tests added |

### THREE unconditional cross-tenant display corrections

The following change for **all** tenants (display truth, not tenant-configurable sourcing):
1. **Monitor view** (§3.8) — lane stock now bucketed non-replenishable, not dropped.
2. **#2 `getStockUnitInfoForReplenishment`** (§3.6) — source-info display no longer lists lanes.
3. **#5 `getStockUnitsForReplenishment`** (§3.6) — open-request screen no longer lists lanes.

### Gated create/selection surfaces (OFF = plan-identical)

#1, #3, #4, shortage #6/#7, `isSourceUsable` (#9), `syncForMovedStockUnit` destination guard (#11), `MobileReplenishService:317` (#12). OFF branches execute the plan-identical legacy query / call the legacy `isReplenishableArea` — no behavior change.

### What Does NOT Change

- `LocationReplenishabilityUtil.isReplenishableArea` and its **destination** call-sites (`ReplenishmentOrderMaintenanceService:197`, `ReplenishmentOrderSourceSyncService:124` OFF-path delegation).
- `ReplenishorderRepository.getIdsForUnreachableReplenishOrders` (§3.9).
- `calculateOrder` / `createOrderFromTemplate` code.
- Endpoint contracts, OMS callbacks, entity-lock / optimistic-lock semantics, DB schema.

---

## §7. Testing Strategy

**Harness reality:** the v2 IT harness is broken (SBDEV-2217). **Gate on unit tests + `mvn clean compile`.** Any repo-query test needing native SQL is authored `@Disabled` with `TODO(SBDEV-2217)`; the verify script's grep checks are the shippable proxy for SQL shape.

### 7.1 Unit tests (named)

**`ReplenishGeneratorServiceUnitTest`**
1. `calculateOrder_gateOn_prefersReplenishableOverLane_sourceIsNotLane` (AC1).
2. `calculateOrder_gateOn_onlyLaneStock_throwsNoReplenishStockAvailable` (AC2).
3. `calculateOrder_gateOff_passesExcludeLanesFalse_planIdentical` (AC6) — assert `getStockUnitsByNotLockedAndItemIdAndUseForDeepStorage` is called with `excludeLanes=false`.

**`ReplenishmentOrderMaintenanceServiceUnitTest`**
4. `isSourceUsable_gateOn_sourceOnLane_returnsFalse` (AC5).
5. `isSourceUsable_gateOff_unchanged` (AC6).
6. `redirectSource_gateOn_neverReturnsLaneCandidate` (AC3, #10 assertion).

**`ReplenishmentOrderSourceSyncServiceTest`**
7. `syncForMovedStockUnit_gateOn_moveOntoLane_routesToReassignOrCancel` (AC4) — mock destination with `staginglane=true`; assert `reassignOrCancelForMovedStockUnit` invoked and no re-point.
8. `syncForMovedStockUnit_gateOff_unchanged` (AC6) — destination lane still re-points per legacy area check.

**`MobileReplenishServiceUnitTest` / `MobileReplenishServiceH2Test`**
9. `mobile_gateOn_scanLaneTarget_throwsNotUsable` (AC10) — target with `staginglane=true` rejected at `:317`.
10. `mobile_gateOff_scanLaneTarget_legacyAreaCheckOnly` (AC6).

**`ReplenishOrderControllerUnitTest` / UnitLoad controller test**
11. `findByItemForReplenish_gateOn_excludesLanes` (AC3 for #4).

**Shortage detection** (owning service unit test)
12. `shortageDetection_gateOn_laneStockNotCounted` (AC7).

**HAL unconditional (repo-query, Testcontainers, `@Disabled TODO(SBDEV-2217)`)**
13. `getStockUnitInfoForReplenishment_alwaysExcludesLanes` + `getStockUnitsForReplenishment_alwaysExcludesLanes` (AC9) — lane rows never returned regardless of sysprop; verify-script A14 is the shippable proxy.

**Monitor view** (repo-query, `@Disabled TODO(SBDEV-2217)`)
14. `monitorView_laneStock_countedNonReplenishable_notDoubleCounted` (AC8).

All pre-existing replenishment unit tests must stay green **unmodified**.

### 7.2 Integration tests

Repo-level SQL correctness → `@Disabled TODO(SBDEV-2217)`. Service-branch selection is covered by unit tests (mocking which arg/method is invoked); SQL shape by the verify script.

### 7.3 Manual Test Plan (MANDATORY)

| Scenario | Env | Steps | Expected | P/F |
|----------|-----|-------|----------|-----|
| AC1 — replenishable + lane (ON) | staging (opted-in) | Item stock in replenishable deep-storage AND on a lane; trigger replenish | Order created; source = replenishable location, never the lane | |
| AC2 — lane-only (ON) | staging | Item's only stock on a lane; trigger replenish | No order; `FacadeException "No replenish stock available"` | |
| AC3 — source-query exclusion (ON) | staging DB | Inspect `getAvailableReplenishmentSources` / `findByItemForReplenish` for a lane-stock item | Lane rows absent | |
| AC4 — move onto lane (ON) | staging | Move a replen-backed source SU onto a lane | Routes to `reassignOrCancelForMovedStockUnit`; source not re-pointed onto the lane | |
| AC5 — source drifted onto lane (ON) | staging | Order whose current source is a lane | `isSourceUsable == false` | |
| AC6 — regression (OFF) | staging (default) | Same mix on non-opted tenant | Plan-identical to today (lanes excluded only if area `useforreplenish=false`) | |
| AC7 — shortage detection (ON) | staging DB | Item short, only lane stock | Not surfaced as refillable-from-lane | |
| AC8 — monitor view (NOT gated) | any tenant | Query `replenishment_monitor_view` for lane stock | Lane stock under `on_non_replenishable_location`; not double-counted in replenishable | |
| AC9 — HAL open-request screen (NOT gated) | any tenant | Open-request replenishment screen for a lane-stock item | Lane stock not shown as a candidate source | |
| AC10 — mobile manual re-source (ON) | mobile, opted-in | Scan a lane location as manual re-source target | Rejected: "Location not usable to replenish from!" | |

### 7.4 Test execution (fill after running)

| Command | Result | P/F/Skip |
|---------|--------|----------|
| `mvn clean compile` | | |
| `mvn test -Dtest=ReplenishGeneratorServiceUnitTest,ReplenishmentOrderMaintenanceServiceUnitTest,ReplenishmentOrderSourceSyncServiceTest,MobileReplenishServiceUnitTest,MobileReplenishServiceH2Test,ReplenishOrderControllerUnitTest` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.sh` | | |

### 7.5 Deliberately-skipped coverage

| What | Why |
|------|-----|
| Live Testcontainers repo-query ITs | SBDEV-2217; `@Disabled`; SQL shape covered by verify grep |
| Cross-tenant snapshot tests for the 3 unconditional display corrections | Additive display changes; unit-level assertion + manual AC8/AC9 sufficient |

---

## §8. Rollout Plan

1. **Ship code with default OFF.** All tenants get: unchanged (plan-identical) sourcing + the three unconditional display corrections (monitor view, HAL #2/#5). Verify the display corrections are visually harmless on a non-opted tenant first.
2. **Per-tenant enablement (opt-in):**
   a. **OQ1:** confirm the target client's lane-area config on prod/UAT (dev already excludes lanes). Reproduce pre/post on UAT first.
   b. `setSysvalue('REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED','true')` (auto-evicts `"sysprops"` cache).
   c. Run §7.3.
3. **Observe:** `FacadeException "No replenish stock available"` rate (rise = guarantee firing) + monitor non-replenishable bucket.
4. **Rollback:** `setSysvalue(...,'false')` — instant revert to plan-identical legacy sourcing. The three display corrections stay (harmless). No redeploy, no data migration.
5. **Follow-up:** raise the bare-`Transfer`-location data-quality ticket (OQ2).

---

## §9. Alternatives Considered

### 9.1 Mechanism alternatives

| # | Option | Pros | Cons | Verdict |
|---|--------|------|------|---------|
| Alt-1 | **Area-flag/config only** | Zero code; already works on verified tenants | Silently breaks on a mis-configured tenant; not a code-level invariant | **Rejected** (D2). |
| Alt-2 | **Name/type-based code exclusion** | No flag dependency | `WmsConstants` name list INCOMPLETE (01-06 vs DB 01-20); bare `Transfer` unmatchable | **Rejected** — key on flags (§2.6). |
| Alt-3 | **Location-flag code guard (chosen)** | Keys on lane identity; null-safe via `IS NOT TRUE`; one helper mirrors service layer | Requires touching each query | **Chosen** (D2). |
| Alt-4 | **v1-style "source = N/A"** | v1 parity | OUT OF SCOPE (D1); contradicts "match putaway" | **Rejected.** |

### 9.2 Sysprop-gate implementation

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **(A) Boolean-parameterized single query + service branch (CHOSEN for service-branchable queries)** | Postgres constant-folds `:excludeLanes=FALSE` → OFF plan-identical; **halves surface, no twin-SQL drift**; DB does filtering | needs explicit-boolean discipline (never null — §3.2 gotcha) | **Chosen** for #1,#3,#4,#6,#7. |
| **(B) Duplicate `_excludingLanes` twin queries** | conceptually simple branch | two hand-maintained copies of a large native query → **twin-drift risk**; doubles surface | **Rejected** — the real ground is drift, not any "can't toggle" claim (that claim was false — §3.2). |
| **(C) Single query + service post-filter** | one query | `calculateOrder` sees id+amount projections only → post-filter needs joins/extra lookups (N round-trips) | **Rejected** for projection-only queries. |
| **In-body unconditional guard (for HAL #2/#5 + monitor view)** | works where a service branch **cannot** (HTTP invokes the original `@RestResource`); display-only, no create-path risk | changes display for all tenants (intended) | **Chosen** for #2,#5,#14 (§3.6, §3.8). |

### 9.3 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | **Standard-to-Large** | ~5 gated queries + 2 unconditional queries + 4 service surfaces + 1 helper + 1 monitor view + sysprop, single subsystem |
| **Plan-review** | **critic** (done — iteration 2) | mirror-surface + exposure-split risk |
| **Implementation shape** | **ralph** (implement cluster → verify → fix → 0 fail) | multi-site; verify-as-exit prevents over-claim |
| **Verification** | verify-script + verifier | mandatory |
| **Code-review** | **code-reviewer** | multi-file, exposure-split risk |
| **Commit** | git-master | sysprop+helper / gated queries / unconditional queries / service mirrors / monitor view / tests |

---

## §10. Open Questions / Resolved Decisions

### Resolved decisions (USER-CONFIRMED 2026-07-23 — do NOT re-open)

- **D1 — Contract = match v2 current PutAwayLane behavior.** Lane-only stock ⇒ **no order** (`FacadeException "No replenish stock available"`). No v1-style "source = N/A" path.
- **D2 — Mechanism = code guard on Location-level boolean flags** (`staginglane IS NOT TRUE AND transferlane IS NOT TRUE`), mirrored via ONE new helper `isUsableSourceLocation`. NOT area-flag/config only.
- **D3 — Rollout = split by query exposure.** Service-branchable queries → sysprop-gated **boolean-parameterized single query** (default OFF, per-tenant opt-in, OFF plan-identical). HAL-exposed queries a service cannot intercept (#2/#5) + monitor view → **unconditional** in-body display correction. New key `SYSTEM_PROPERTY_REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED_KEY` (SBDEV-1762 precedent).
- **D4 — Monitor view in scope, NOT gated.** Widen all four CASE branches so lane stock buckets non-replenishable and is not double-counted.

### Open questions

- **OQ1 (PREREQUISITE):** Confirm the affected client's lane-area config on prod/UAT before enabling. Dev already excludes lanes (§2.6). — *Behavior only visibly changes on a tenant whose lane area is NOT already `useforreplenish=false`.*
- **OQ2:** The bare `Transfer` location is neither flagged nor name-matchable (§2.6). **Recommendation:** rely on the `Location.transferlane` flag; raise a data-quality follow-up. — *The code guard will not exclude an unflagged lane.*
- **OQ3 (RESOLVED):** `getStockUnitsForReplenishment` exposure. **Resolved by C1: it is HAL-exposed AND consumed by the open-request screen → guard unconditionally in place (§3.6).**
- **OQ4 (RESOLVED):** Shortage-detection queries — **in scope; blast radius noted (§3.5).**
- **OQ5 (RESOLVED by C1 — exposure split):** the "how to gate a HAL query" question is answered: HAL-exposed queries a service branch cannot intercept are corrected **unconditionally in the query body** (#2/#5, §3.6); they are display-only with no create-path risk. No Architect deferral remains.

### Maintenance constraint (Architect iter-2 antithesis — record, do not lose)

The **unconditional** correction of #2/#5 is safe **only** while `calculateOrder` (and `createOrderFromTemplate`) take **no caller-chosen source id** — i.e. the operator's open-request screen selection cannot become an order's source. This is verified true today (`ReplenishGeneratorService:191-271` re-selects its own source). **If a future ticket adds an operator-chosen-source create path** (plausible given SBDEV-2074's manual-re-source direction and the `MobileReplenishService:317` path this plan touches), the unconditional #2/#5 filter would silently become a create-path filter with no sysprop escape hatch. Any such future change MUST revisit whether #2/#5 should move from unconditional to gated. Encode this as a `project_memory_add_directive` after rollout.

---

## Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Change it? | Verdict | Rationale |
|---|---|---|---|---|
| 1 | In-JVM state | replica-local state? | **No** | Reads existing per-tenant `"sysprops"` Caffeine cache only. |
| 2 | Connection pool math | per-request DB usage? | **No** | Same query count (param added, not extra query). |
| 3 | Scheduled jobs | add/modify cron? | **No** | Reuses existing replenish cron. |
| 4 | Long transactions | tx across repo calls / I/O? | **No** | Runs inside existing `calculateOrder` `REQUIRES_NEW`; no I/O. |
| 5 | Request affinity | assume same replica? | **No** | Stateless; sysprop DB-backed + per-replica cache. |
| 6 | Retry / idempotency | single-execution? | **No** | Source selection is a read; order idempotency unchanged. |
| 7 | Tenant context | ThreadLocal across async? | **No** | Synchronous tenant-scoped path; no `@Async`. |
| 8 | Distributed lock | new lock across replicas? | **No** | Existing `calculateOrder` locking unchanged. |
| 9 | Cache invalidation | write cached entity? | **No** | Sysprop `@CacheEvict` already handled; no new cached writes. |
| 10 | External notifications | HTTP/message in tx? | **No** | None added. |

---

## v2-only constraint checklist

| # | v2 constraint | Applies? | How satisfied |
|---|---|---|---|
| 1 | Dual TX (`tenantTransactionManager`) | Yes | Parameterized queries run inside existing `calculateOrder` `REQUIRES_NEW`; no new TM. |
| 2 | OSIV off | Yes | Entity access inside service/tx boundaries; helper + `isReplenishableDestination` take already-loaded `Location`. |
| 3 | Sysprop 4-tier read via Caffeine | Yes | `getSysvalue`; `Boolean.parseBoolean(null)=false`; `@CacheEvict` on set. |
| 4 | Native `@Query` optional-param `OR :param=''` safety | Yes (N/A here) | Param is a **boolean**, not a string — the `= ''` hazard is string-specific; `:excludeLanes` bound as an explicit primitive (never null — §3.2 gotcha). |
| 5 | Manual FK (no JPA associations) | Yes | Helper uses `loc.getAreaId()` + repo lookup; no lazy traversal. |
| 6 | Entity comparison by id, not `.equals()` | Yes | Guard keys on `staginglane`/`transferlane` booleans. |
| 7 | Horizontal scalability | Yes | See table — all "No". |
| 8 | Flyway forward-only | Yes | **V2.2.04** data-only sysprop seed is forward-only (idempotent `INSERT ... WHERE NOT EXISTS`); no columns added. |

---

## §Acceptance

Machine-checkable acceptance script:
`sbdocs/9-System/scripts/verify-SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.sh`

The implementing agent runs it after every pass and pastes output into its report; the orchestrator re-runs it. **A "DONE" claim with any FAIL line is not accepted.** POSITIVE checks are EXPECTED to FAIL pre-implementation; NEGATIVE/preservation checks (destination `isReplenishableArea` untouched, no v1-style N/A branch, no `_excludingLanes` twin for #2/#5) are EXPECTED to PASS today.

---

## RALPLAN-DR — Consensus Decision Record (iteration 2, Planner)

**Mode:** SHORT (not `--deliberate`; urgent but bounded single-subsystem change).

### Principles
1. **Guarantee over coincidence** — lane exclusion is a code-level invariant keyed on lane identity, not per-tenant area-config accident.
2. **OFF path plan-identical** — for the GATED create/selection queries the toggle is a bound boolean that Postgres constant-folds (`:excludeLanes = FALSE`), so the OFF plan is **identical** to today's (plan-identical, NOT literal-byte-identical text). The three display-only surfaces (#2, #5, monitor view) are corrected **unconditionally** and are not gated.
3. **Match existing putaway semantics** — lane-only stock yields the *existing* `FacadeException "No replenish stock available"`; no new failure mode, no v1-style N/A path.
4. **Mirror every source surface** — the SBDEV-2074 leak-bug class means the source-eligibility change must reflect in usability + resync (`isSourceUsable`, `syncForMovedStockUnit` destination guard, `MobileReplenishService:317`), not just the primary query.
5. **Separate display from behavior, and gate by exposure** — a HAL-exposed query a service branch cannot intercept is corrected in-body unconditionally (display-only); a service-branchable query is gated.

### Decision drivers (top 3)
1. **Non-regression safety** for the large installed base of non-opted tenants → parameterized single query with constant-folding OFF.
2. **Correctness of the guarantee** across mis-configured tenants → flag-based code guard over area-config reliance.
3. **Completeness across leak-prone mirror surfaces AND HAL exposure** → include usability + resync + mobile + the two un-branchable HAL queries.

### Viable options
- **Option A — Flag-based guard; boolean-parameterized queries for service-branchable paths + unconditional in-body guard for HAL #2/#5 & monitor view (CHOSEN).**
  - *Pros:* keys on lane identity; OFF plan-identical via constant-fold; no twin-drift; handles the un-branchable HAL queries correctly; mirrors through one helper.
  - *Cons:* requires explicit-boolean discipline; three unconditional cross-tenant display changes (intended).
- **Option B — Duplicate `_excludingLanes` twin queries + service branch.**
  - *Pros:* branch is conceptually simple.
  - *Cons:* two hand-maintained copies of each large native query → drift risk; doubles surface; still cannot guard the HAL #2/#5 (HTTP hits the original). **Invalidated** on twin-drift + HAL-un-branchability.
- **Option C — Area-config only (no code).**
  - *Pros:* zero code.
  - *Cons:* not a guarantee; breaks on mis-configured tenant. **Invalidated** by D2.

### ADR
- **Decision:** Per-tenant sysprop-gated, flag-based code guard via **boolean-parameterized queries** selected at the service layer for create/selection paths, mirrored through the new `isUsableSourceLocation` helper (+ a destination-lane guard in `syncForMovedStockUnit` and a scanned-target guard in `MobileReplenishService:317`); **unconditional in-body guard** for the two HAL-exposed open-request queries (#2/#5) and the monitor view.
- **Drivers:** non-regression safety; correctness of the guarantee; mirror-surface + HAL-exposure completeness.
- **Alternatives considered:** Option B (twin queries — rejected on twin-drift + HAL-un-branchability), Option C (area-config only — rejected: not a code-level guarantee), post-filter (rejected on projection-only round-trips), name/type matching (rejected: incomplete list), v1-style N/A path (out of scope).
- **Why chosen:** only Option A delivers a code-level identity-based guarantee while keeping the OFF create/selection path plan-identical (constant-fold), avoiding twin-SQL drift, and correctly handling HAL-exposed queries that a service branch cannot intercept.
- **Consequences:** ~5 parameterized gated queries + 2 unconditional query edits + 4 service branch points + 1 helper + 1 sysprop + 1 unconditional monitor-view change; **three** cross-tenant display corrections (monitor view, #2, #5); enablement raises the "no replenish stock available" rate on affected tenants (intended). RSSS gains a `SyspropService` dependency.
- **Follow-ups:** (1) SBDEV-2217 IT-harness fix to un-disable repo-query + monitor-view ITs; (2) data-quality ticket for the bare `Transfer` location (OQ2); (3) OQ1 tenant lane-area confirmation before enablement.


> **Archived 2026-07-25.** Acceptance script retired to `sbdocs/4-Archieves/scripts/verify-SBDEV-1666-staging-transfer-lane-replenish-source-exclusion.sh`.
