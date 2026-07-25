---
title: "Split Unit Load Missing Reprint Label Button in Club Process — v1 API"
ticket: "SBDEV-2485"
ticket_url: "https://app.clickup.com/t/868k4txce"
pr: ""
type: bug
priority: high
status: draft
project:
  - wms-api
version: v1
requester: "Brent Campbell (ClickUp SBDEV-2485)"
created: 2026-07-21
updated: 2026-07-21
db_verified: false
related:
  - "[[SBDEV-2485-club-split-unitload-reprint-label]]"
tags:
  - plan
  - club-run
  - unitload
  - printing
---

# Split Unit Load Missing Reprint Label Button in Club Process — v1 (wms-api)

**Ticket:** [SBDEV-2485](https://app.clickup.com/t/868k4txce)
**Project:** v1/wms-api | **Version:** v1 | **Type:** bug
**Priority:** high (urgent per ticket; Effort 1, Impact 2)
**Status:** draft
**Date:** 2026-07-21

**Pairs with:** `sbdocs/4-Archieves/wms2/plan/SBDEV-2485-club-split-unitload-reprint-label.md` (identical logic; same base name; v2 archived 2026-07-25 after wms2-api PR #86).

> **Review of record:** Per the `wms-bugfix-plan` small-fix exception, the ralplan consensus loop is skipped. The fix is a one-line semantic change plus dead-code removal in a single private method with one caller. The Explore code trace + live UAT DB verification (§1) + full-method read serve as the review of record. Test-first via `wms-tdd-gate`.

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn "findPrintableUnitLoadIds|setPrintable|printable" v1/wms-api/src`.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `service/CustomerorderBatchService.java:902` | `goodsreceiptpositionRepository.findPrintableUnitLoadIds(unitLoadIds)` call + LOG lines `:903-904` | yes (the receiving-only gate) | yes — remove |
| 2 | `service/CustomerorderBatchService.java:906-915` | `buildDtoList(...)` call passes `printableUnitLoadIds` | yes | yes — drop arg |
| 3 | `service/CustomerorderBatchService.java:984` | `buildDtoList(..., Set<Long> printableUnitLoadIds, ...)` signature param | yes | yes — remove param |
| 4 | `service/CustomerorderBatchService.java:1034` | `dto.setPrintable(printableUnitLoadIds.contains(unitLoad.getId()))` | yes (the actual defect) | yes — change to `entry.getValue() > 0 && entityLock == NOT_LOCKED` (see §2 Bug 2) |
| 5 | `repo/jpa/GoodsreceiptpositionRepository.java:50-57` | `findPrintableUnitLoadIds` query (`@RestResource`-exposed) | source of the flag | no — keep (see §10 Q1); becomes unused by the service but stays a HAL search resource |
| 6 | `json/ClubLineUnitLoadDto.java:107-113` | `printable` field + getter/setter | payload shape | no — unchanged; field stays, only its value changes |
| 7 | `components/.../clubRuns/tabTables/inventoryOnLaneTable.vue:63` (wms-web-ui) | `v-if="item.printable"` button gate | consumes the flag | no — no UI change; UI renders correctly once API returns `true` |
| 8 | `test/.../CustomerorderBatchServiceUnitTest.java:1119,1180,1219,1247,1275,2219` | `when(...findPrintableUnitLoadIds(anySet()))` stubs | test fixtures | yes — remove stubs (else Mockito `UnnecessaryStubbingException`) |

Cross-reference grep (`sbdocs/1-Projects`, `sbdocs/4-Archieves`): the only prior club-lane plans touching this service are `SBDEV-2486-club-lane-blank-screen-split-adjust` (NPE hardening in the same class — no overlap with `printable`) and `SBDEV-2163/2164` (lane assignment / cleanup — no overlap). No plan previously touched `printable` / `findPrintableUnitLoadIds`.

---

## 1. Problem Statement

**Reported (ClickUp SBDEV-2485, WMS v1 / Club Processing):** After a club run, operators reprint unit-load labels so remaining inventory can be moved back to warehouse locations. In the club **staging-lane** inventory view, unit loads that were moved into the lane directly show a **print/reprint label** button, but a unit load that was created by **splitting** an existing unit load does **not** show the button.

**Impact:** Operators cannot reprint labels for split unit loads after club runs, making it harder to return remaining inventory to proper locations; forces manual workarounds.

**Reproduction:**
1. Prepare a club batch/run and move multiple unit loads into the staging lane.
2. Split an existing unit load; move the resulting unit load into the staging lane.
3. Complete/process the club run.
4. Open the staging-lane inventory list. Directly-moved ULs show the print button; the split UL does not.

### DB verification

`db_verified: false` for the v1 database — **no v1 tenant MCP was reachable this session** (only v2 UAT endpoints are wired). The v1 UAT tenant databases are the pre-migration twins of the v2 tenants queried below, and the v1 code path (§2) is byte-identical, so the mechanism is corroborated. **The implementer MUST run this on a live v1 tenant DB before starting:**

```sql
-- Among unit loads that currently hold stock, how many lack a goodsreceiptposition row
-- (printable=false today)? These are the ULs whose reprint button is wrongly hidden.
WITH stocked AS (
  SELECT ul.id,
         EXISTS(SELECT 1 FROM goodsreceiptposition g WHERE g.unitload_id = ul.id) AS has_grp
  FROM unitload ul
  WHERE EXISTS(SELECT 1 FROM stockunit su WHERE su.unitload_id = ul.id)
)
SELECT has_grp, COUNT(*) FROM stocked GROUP BY has_grp;
```

**Corroborating evidence — same query on the v2 UAT twins (run 2026-07-21):**
- `wsl-wineco-uat`: of unit loads holding stock, **470,764 (97.9%)** have `printable=false` vs **10,059 (2.1%)** `printable=true`. **Scope caveat:** this is a whole-`unitload`-table count, not the club-staging-lane population the screen filters to — it corroborates the *mechanism* (receiving-provenance ≠ reprint eligibility) but overstates the button-relevant share; it is not load-bearing for the fix.
- `wms2-hydra-uat`: `HAS_GRP` = 2,052 ULs (89 stockunits); `NO_GRP` = 11,329 ULs (19,331 stockunits) — same inversion.

This confirms `printable = "has a goodsreceiptposition row"` is a receiving-provenance proxy, not a reprint-eligibility signal. Split ULs are one visible slice of a much larger population that the rule wrongly excludes.

---

## 2. Root Cause Analysis

### Bug 1: `printable` is computed from receiving provenance, not from reprint eligibility

`CustomerorderBatchService.getClubLineUnitLoads(...)` fetches the "printable" set from the `goodsreceiptposition` table and threads it into `buildDtoList`:

`service/CustomerorderBatchService.java:897-904`
```java
// Batch fetch printable status
Set<Long> unitLoadIds = itemToUnitLoads.values().stream()
    .flatMap(List::stream).map(Unitload::getId).collect(Collectors.toSet());
Set<Long> printableUnitLoadIds = goodsreceiptpositionRepository.findPrintableUnitLoadIds(unitLoadIds);
```

`repo/jpa/GoodsreceiptpositionRepository.java:50-57`
```java
@RestResource(path = "findPrintableUnitLoadIds", rel = "findPrintableUnitLoadIds")
@Query(value = "SELECT DISTINCT unitload_id FROM goodsreceiptposition "
             + "WHERE unitload_id IN (:unitLoadIds) ", nativeQuery = true)
Set<Long> findPrintableUnitLoadIds(@Param("unitLoadIds") Set<Long> unitLoadIds);
```

A `goodsreceiptposition` row is written only when a unit load is created during **receiving**. A **split** creates a brand-new `Unitload` (via `UnitloadService.createUnitload(...)` with activity `CODE_MANUAL_SPLIT`) and never writes a `goodsreceiptposition` row for it. So a split UL is absent from `findPrintableUnitLoadIds` and gets `printable = false`:

`service/CustomerorderBatchService.java:1034`
```java
dto.setPrintable(printableUnitLoadIds.contains(unitLoad.getId()));
```

The Vue button is gated solely on that flag (`wms-web-ui/components/processes/clubRuns/tabTables/inventoryOnLaneTable.vue:63`, `v-if="item.printable"`), so the button is hidden for split ULs. A directly-moved UL keeps its original receiving row (same UL id) → `printable = true` → button shown. This exactly matches the reported symptom.

### Why the endpoint is already capable for the provenance dimension (fix is safe on that axis)

`UnitloadService.reprintLabel` (the `/unitLoad/reprintLabel` handler, `:162-203`) already handles ULs with **no** `goodsreceiptposition` row via a "Path 2" branch that builds a case label from the stock unit directly, and `ReceivingService.createCaseLabel` (`:123-160`) null-guards the absent advice/goodsreceipt. So the backend can already print a split UL's label — the provenance dimension is safe.

> **Latent v1-only NPE (pre-existing, out of scope):** in the anonymous-user fallback, `ReceivingService.java:139` uses `.orElse(null)` and then dereferences `operator.getName()` at `:156`; if `USER_ANONYMOUS` is missing this NPEs. v2 uses `orElseThrow`. Not introduced or worsened by this fix (Path 2 is unchanged); noted for a separate cleanup.

### Bug 2 (verify-surfaced): the flag must also honor `reprintLabel`'s `NOT_LOCKED` precondition

`reprintLabel` hard-throws before printing if the UL is not active (`UnitloadService.java:165-168`: `entityLock != WmsConstants.BusinessObjectLockState.NOT_LOCKED` → `RuntimeException`). The staging-lane query `getBatchLocationsByItemIdAndLaneName` (`repo/jpa/UnitloadRepository.java:87-94`) does **not** filter on `entity_lock`, so a locked UL with stock can appear on the lane. Under the old gate this rarely surfaced (only ~2.1% of stocked ULs were `printable=true`); making the flag stock-based expands the `true` population sharply, so a **locked lane UL would show the button and 500 on click**. The flag must therefore also require `NOT_LOCKED`. (The endpoint's empty-stock guard at `:171-175` is not a concern here — the staging query's `INNER JOIN stockunit` guarantees a direct stockunit on every listed UL.)

### Why "has remaining stock" is the correct, minimal signal

`buildDtoList` builds one DTO per unit load that has a **non-zero amount** of the club item, and **skips `amount == 0`** before the DTO is created:

`service/CustomerorderBatchService.java:998-1034`
```java
for (Map.Entry<Unitload, Integer> entry : unitLoadAmounts.entrySet()) {
    Unitload unitLoad = entry.getKey();
    if (!clientId.equals(unitLoad.getClientId())) continue;
    if (entry.getValue() == 0) continue;                 // <-- amount==0 already skipped
    if (!locationMap.containsKey(unitLoad.getStoragelocationId())) continue;
    ...
    dto.setPrintable(printableUnitLoadIds.contains(unitLoad.getId()));
    dtos.add(dto);
}
```

`entry.getValue()` is the remaining stock of the club item on that UL, computed by `calc()` (`:1197-1224`) as the sum of `stockunit.amount` plus child ULs, recursively. So `entry.getValue() > 0` captures the stock dimension of reprint eligibility at `:1034`, and the `findPrintableUnitLoadIds` round-trip is dead weight. Note `> 0` is **not** equivalent to a bare `true`: the pre-DTO guard skips `amount == 0` but not `< 0`, and `calc()` sums signed amounts, so `> 0` correctly withholds the button on a net-negative UL. Combined with the `NOT_LOCKED` conjunct (Bug 2), the flag matches exactly what `reprintLabel` can serve.

> **Approved eligibility rule (requester decision, 2026-07-21):** *printable = the unit load has remaining stock (≥1 stockunit of the club item), regardless of origin (received / split / move / transfer).* **Refined after architect review:** additionally require `entityLock == NOT_LOCKED` so the button shows only when the reprint endpoint would actually succeed (see §10 for the tension vs. the literal "has stock" wording). Fully-depleted or locked ULs correctly show no button.

---

## 3. Design / Proposed Fix

Single-method change in `CustomerorderBatchService`, API-only. No UI change (the Vue button already consumes `printable`). No DTO shape change. No DB/schema change.

### 3.1 Fix A — set `printable` from remaining stock; delete the receiving-only query

**File:** `service/CustomerorderBatchService.java`

**Before (`:897-904` + `:906-915` + `:984` + `:1034`):**
```java
// Batch fetch printable status
Set<Long> unitLoadIds = itemToUnitLoads.values().stream()
    .flatMap(List::stream).map(Unitload::getId).collect(Collectors.toSet());
Set<Long> printableUnitLoadIds = goodsreceiptpositionRepository.findPrintableUnitLoadIds(unitLoadIds);
LOG.debug("unitLoadIds " + unitLoadIds.size());
LOG.debug("printableUnitLoadIds " + printableUnitLoadIds.size());

return buildDtoList(positions, itemDataMap, itemToUnitLoads, locationMap,
    carrierMap, itemUnitMap, printableUnitLoadIds, orderBatch.getClientId());
...
private List<ClubLineUnitLoadDto> buildDtoList(..., Set<Long> printableUnitLoadIds, Long clientId) {
    ...
    dto.setPrintable(printableUnitLoadIds.contains(unitLoad.getId()));
```

**After:**
```java
return buildDtoList(positions, itemDataMap, itemToUnitLoads, locationMap,
    carrierMap, itemUnitMap, orderBatch.getClientId());
...
private List<ClubLineUnitLoadDto> buildDtoList(..., Long clientId) {   // printableUnitLoadIds param removed
    ...
    // SBDEV-2485: reprint eligibility = the UL still holds stock of the club item
    // AND is active (NOT_LOCKED), matching UnitloadService.reprintLabel's precondition.
    // amount==0 is already skipped above; > 0 also excludes a net-negative amount
    // (calc() sums signed stockunit amounts). NOT_LOCKED avoids showing a button
    // that would 500 on click. (Previously gated on goodsreceiptposition membership,
    // which hid split/move-created ULs.)
    Integer lock = unitLoad.getEntityLock();
    boolean active = lock != null && lock == WmsConstants.BusinessObjectLockState.NOT_LOCKED;
    dto.setPrintable(entry.getValue() > 0 && active);
```

Also delete the now-unused `unitLoadIds` build + `findPrintableUnitLoadIds` call + its two `LOG.debug` lines (`:897-904`).

> **NPE guard (must-do):** `Unitload.getEntityLock()` returns a **nullable `Integer`** (`model/Unitload.java:84`) and `NOT_LOCKED` is a primitive `int`, so a bare `getEntityLock() == NOT_LOCKED` unboxes and NPEs on a null lock. The `lock != null` guard above is mandatory; a null lock → `active=false` (button hidden — conservative, since `reprintLabel` would itself NPE on a null lock). **Test-fixture consequence:** the existing `getClubLineUnitLoads_withUnitLoads_buildsCompleteDto` (`:1148`) uses `buildUnitload(300L, 21L)` which leaves `entityLock` null, so after this change its `getPrintable().isTrue()` assertion flips to false unless the fixture calls `setEntityLock(0)`. Any `printable==true` test must set `entityLock = 0` (`NOT_LOCKED`).

**Why this and not alternatives:**
- *Broaden `findPrintableUnitLoadIds` to also match split/move ULs* — brittle (enumerate activity codes), keeps an unnecessary query, and still misses other non-receiving origins the DB shows.
- *Always `true`* — **not** equivalent: the amount==0 guard doesn't exclude net-negative amounts, so `entry.getValue() > 0` is the more correct form (and survives future changes to that guard).
- *Omit the `NOT_LOCKED` conjunct* — would reintroduce a click-time 500 for locked lane ULs (Bug 2).

**Files changed:** `service/CustomerorderBatchService.java` (one method + its private helper signature).

---

## 4. Architecture Overview

```
GET club-line unit loads (staging lane)
  CustomerorderBatchService.getClubLineUnitLoads(batch, onlyStagingLocation, skuFilter)
    ├─ fetchUnitLoads()               → ULs on the staging lane per item
    ├─ [REMOVED] findPrintableUnitLoadIds(unitLoadIds)   ← receiving-only gate (the bug)
    └─ buildDtoList()
         └─ calculateUnitLoadAmounts()/calc()  → remaining stock per UL (amount)
              for each UL with amount>0:
                dto.setPrintable(amount > 0 && entityLock==NOT_LOCKED)  ← FIX (was: printableSet.contains(ulId))
  → JSON [{..., printable}]  → wms-web-ui inventoryOnLaneTable.vue  v-if="item.printable"
                                → printLabel() → POST /unitLoad/reprintLabel (Path 2 handles split ULs)
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| `service/CustomerorderBatchService.java` | 855-1041 | `getClubLineUnitLoads` + `buildDtoList` (fix site) |
| `service/CustomerorderBatchService.java` | 1197-1224 | `calc()` — remaining-stock amount |
| `repo/jpa/GoodsreceiptpositionRepository.java` | 50-57 | `findPrintableUnitLoadIds` (caller removed; method kept — §10 Q1) |
| `json/ClubLineUnitLoadDto.java` | 107-113 | `printable` field (unchanged) |
| `service/UnitloadService.java` (reprint) | Path 1/Path 2 | already prints split/move ULs — no change |
| `wms-web-ui .../inventoryOnLaneTable.vue` | 63 | button `v-if="item.printable"` — no change |

---

## 5. Implementation Steps

### 5.1 Prerequisites

| Concern | Applies? |
|---|---|
| DB state | **Yes** — run the §1 verification query on a live v1 tenant DB first to confirm the population of stock-bearing, `printable=false` ULs. |
| Feature flags / sysprops | N/A — no gate; behavior change is immediate and desired. |
| Config / env | N/A. |
| Deploy-order dependency | N/A — API-only; UI needs no coordinated release (already consumes `printable`). |
| Data migration | N/A — no schema/data change. |
| External systems | N/A. |
| Access / monitoring | N/A. |

### 5.2 Steps (atomic)

1. **Test-first (`wms-tdd-gate`):** add a unit test proving a split-created UL (no `goodsreceiptposition` row) with stock in the lane yields `printable = true` (see §8). Confirm it fails against current code.
2. Remove the `findPrintableUnitLoadIds` fetch + `unitLoadIds` build + 2 LOG lines (`:897-904`); drop `printableUnitLoadIds` from the `buildDtoList` call and signature.
3. Change `dto.setPrintable(...)` to `dto.setPrintable(entry.getValue() > 0 && unitLoad.getEntityLock() == WmsConstants.BusinessObjectLockState.NOT_LOCKED)` with the SBDEV-2485 comment.
4. Remove the now-unnecessary `findPrintableUnitLoadIds(anySet())` Mockito stubs from `CustomerorderBatchServiceUnitTest` (6 sites). **This test class runs strict** (`@ExtendWith(MockitoExtension.class)`, no `@MockitoSettings`), so leftover stubs **do** fail with `UnnecessaryStubbingException` — removal is required, not just hygiene. (Contrast v2, which is LENIENT.)
5. Run the verify script + targeted tests (§8). Update §11.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/CustomerorderBatchService.java` | Modify | Remove receiving-only printable query + param; set `printable = entry.getValue() > 0 && NOT_LOCKED` |
| `test/.../CustomerorderBatchServiceUnitTest.java` | Modify | Remove `findPrintableUnitLoadIds` stubs; add split-UL + locked-UL printable tests |
| `repo/jpa/GoodsreceiptpositionRepository.java` | None (see §10 Q1) | `findPrintableUnitLoadIds` kept as HAL resource; optional removal deferred |

> **Orphaned dependency note:** after removing the only service caller, the `@Autowired goodsreceiptpositionRepository` field (`:84`, field injection) becomes unused **in this class**. It compiles fine; left in place for a minimal diff (flagged so a reviewer isn't surprised). Optional removal can ride with §10 Q1.

---

## 7. Testing Plan

### Unit (Mockito 3.3.3 — no `mockStatic`; not needed here)
- `getClubLineUnitLoads_shouldMarkPrintable_whenSplitUnitLoadHasStockAndNotLocked` — active UL with stock in lane, `findByUnitloadId` returns stock, **no** goodsreceiptposition; assert `dto.getPrintable()` is `true` (the fix).
- `getClubLineUnitLoads_shouldNotMarkPrintable_whenUnitLoadLocked` — UL with stock in lane but `entityLock != NOT_LOCKED`; assert `printable == false` (§2 Bug 2). **Mandatory** — this is the only guard for the lock precondition.
- `getClubLineUnitLoads_receivedUnitLoad_stillPrintable` — regression: active received UL with stock still `printable = true` (the existing `getClubLineUnitLoads_withUnitLoads_buildsCompleteDto` at `:1148` already asserts this; update it to drop the `findPrintableUnitLoadIds` stub, and ensure its UL fixture is `NOT_LOCKED`).
- `getClubLineUnitLoads_zeroAmount_excluded` — UL with amount 0 is not in the result at all (existing coverage retained).

### Integration
- N/A — v1 Testcontainers ITs are blocked by the `ro_id` view drift (see memory `v1-its-blocked-roid-view-drift`); the change is pure service logic with unit coverage. Note in §11 if the view is fixed and an IT is added.

### Regression
- Full `CustomerorderBatchServiceUnitTest` must pass (the removed stubs are the only fixture change).

### Manual test plan

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Split UL shows reprint button | v1 UAT (wineco) | Club run → split a UL → move split UL to staging lane → open staging-lane inventory | Split UL row shows the print/reprint button; clicking it reprints the label | |
| Directly-moved UL unchanged | v1 UAT | Same run, a directly-moved received UL | Print button still shown (no regression) | |
| Depleted UL has no button | v1 UAT | UL fully consumed by the run (amount 0) | Row not listed (no button) — unchanged | |

---

## 8. Acceptance

Verify script: `sbdocs/9-System/scripts/verify-SBDEV-2485-club-split-unitload-reprint-label-v1.sh`
Run from `v1/wms-api`: `PROJECT_ROOT=/home/nampark/dev/wms-claude/v1/wms-api bash sbdocs/9-System/scripts/verify-SBDEV-2485-club-split-unitload-reprint-label-v1.sh`

Checks: (A-pos-stock) `setPrintable(... entry.getValue() > 0 ...)`; (A-pos-lock) `NOT_LOCKED` present in the fix; (A-neg1/A-neg2) no `setPrintable(printableUnitLoadIds.contains(` and no `findPrintableUnitLoadIds` call remain in the service; (A-param) `buildDtoList` no longer declares `printableUnitLoadIds`; (T-split) split-UL regression test exists; (T-locked) locked-UL test exists; (T-nostub) no leftover stub; (T-unit) `CustomerorderBatchServiceUnitTest` passes (keys off mvn exit code). Final acceptance: `Result: N pass, 0 fail`.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Button now appears on ULs that previously hid it | Intended behavior change (the fix) | Requester-approved; reprint Path 2 handles provenance; `NOT_LOCKED` conjunct handles the lock dimension |
| **Locked lane UL shows a button that 500s on click** | Bad UX / error | §2 Bug 2 — flag now requires `entityLock == NOT_LOCKED`; new `lockedUnitLoad` test asserts `printable=false` |
| **Null `entityLock` NPE on the new comparison** | 500 building the list | `lock != null` guard (§3.1 NPE note); null → button hidden |
| Removing `findPrintableUnitLoadIds` stubs missed → `UnnecessaryStubbingException` | Test suite red | v1 runs strict; Step 4 removes all 6 stubs; verify script runs the class |
| Some external HAL client calls the `findPrintableUnitLoadIds` search rel | Broken integration | Method kept in the repository (§10 Q1); only the internal caller is removed |
| A received-but-now-empty / net-negative UL loses its button | Correct — nothing to reprint | Amount==0 excluded pre-DTO; `> 0` excludes net-negative; matches approved rule |

---

## 10. Open Questions / Resolved Decisions

- **Resolved (requester, 2026-07-21):** eligibility rule = "has remaining stock," fixed API-side. (Alternatives "any UL in lane" and "received OR split/move" rejected.)
- **Resolved:** no UI change — the Vue button already gates on `item.printable`; the API fix is sufficient. UI file listed in §0 for traceability only.
- **Q2 (RESOLVED — requester, 2026-07-21):** keep the `&& entityLock == NOT_LOCKED` conjunct. Intentionally narrower than the literal "has remaining stock" rule so the flag matches `reprintLabel`'s precondition (§2 Bug 2) — a locked lane UL will not show the button rather than 500 on click. Showing a visible-but-erroring button for locked ULs was declined as out of scope.
- **Q1 (deferred, low priority):** remove the now-caller-less `findPrintableUnitLoadIds` repository method? It is `@RestResource`-exposed via Spring Data REST, so removal touches the HAL contract surface. **Recommendation:** keep for now (zero-risk); revisit in a dead-code sweep after confirming no external client uses the `findPrintableUnitLoadIds` rel. (The now-unused injected field is addressed in §6.)

---

## 11. Implementation Status

_Not yet implemented._
