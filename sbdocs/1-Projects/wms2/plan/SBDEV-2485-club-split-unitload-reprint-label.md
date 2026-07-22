---
title: "Split Unit Load Missing Reprint Label Button in Club Process — v2 API"
ticket: "SBDEV-2485"
ticket_url: "https://app.clickup.com/t/868k4txce"
pr: ""
type: bug
priority: high
status: draft
project:
  - wms2-api
version: v2
requester: "Brent Campbell (ClickUp SBDEV-2485)"
created: 2026-07-21
updated: 2026-07-21
db_verified: true
v1_source_plan: "[[SBDEV-2485-club-split-unitload-reprint-label]] (v1/wms-api)"
related:
  - "[[SBDEV-2485-club-split-unitload-reprint-label]]"
tags:
  - plan
  - club-run
  - unitload
  - printing
  - v2-port
---

# Split Unit Load Missing Reprint Label Button in Club Process — v2 (wms2-api)

**Ticket:** [SBDEV-2485](https://app.clickup.com/t/868k4txce)
**Project:** v2/wms2-api | **Version:** v2 | **Type:** bug
**Priority:** high (urgent per ticket)
**Status:** draft
**Date:** 2026-07-21

**Pairs with:** `sbdocs/1-Projects/wms1/plan/SBDEV-2485-club-split-unitload-reprint-label.md` (same base name). v1 and v2 are byte-for-byte identical on this path; the fix ports 1:1.

> **Review of record:** Per the `wms-bugfix-plan` small-fix exception, ralplan consensus is skipped. One-line semantic change plus dead-code removal in a single private method with one caller. Explore code trace + live UAT DB verification (§1) + full-method read serve as the review of record. Test-first via `wms-tdd-gate`.

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn "findPrintableUnitLoadIds|setPrintable|printable" v2/wms2-api/src`.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `service/CustomerorderBatchService.java:1023-1030` | `findPrintableUnitLoadIds(unitLoadIds)` call + `unitLoadIds` build + 2 LOG lines | yes (receiving-only gate) | yes — remove |
| 2 | `service/CustomerorderBatchService.java:1032-1041` | `buildDtoList(...)` call passes `printableUnitLoadIds` | yes | yes — drop arg |
| 3 | `service/CustomerorderBatchService.java:1113` | `buildDtoList(..., Set<Long> printableUnitLoadIds, Long clientId)` signature param | yes | yes — remove param |
| 4 | `service/CustomerorderBatchService.java:1161` | `dto.setPrintable(printableUnitLoadIds.contains(unitLoad.getId()))` | yes (the actual defect) | yes — change to `entry.getValue() > 0 && entityLock == NOT_LOCKED` (see §2 Bug 2) |
| 5 | `repo/jpa/GoodsreceiptpositionRepository.java:50-54` | `findPrintableUnitLoadIds` query (`@RestResource`-exposed) | source of the flag | no — keep (see §10 Q1); becomes unused by the service |
| 6 | `json/ClubLineUnitLoadDto.java:107-113` | `printable` field + getter/setter | payload shape | no — unchanged; only its value changes |
| 7 | `wms2-web-ui .../clubRuns/tabTables/inventoryOnLaneTable.vue:63` | `v-if="item.printable"` button gate | consumes the flag | no — no UI change |
| 8 | `test/.../CustomerorderBatchServiceUnitTest.java:1984,2020,2056,2141,2198` | `when(...findPrintableUnitLoadIds(anySet()))` stubs | test fixtures | yes — remove stubs (Mockito strict stubbing) |

Cross-reference grep (`sbdocs/1-Projects`, `sbdocs/4-Archieves`): archived `SBDEV-2486-club-lane-blank-screen-split-adjust` hardened NPEs in the same class (no `printable` overlap); `SBDEV-2610` (move-unitload) and `SBDEV-1714` (replen audit) do not touch this method. No prior plan touched `printable`.

---

## 1. Problem Statement

**Reported (ClickUp SBDEV-2485; ticket flags "Also Applicable To: WMS V2 review"):** In the club **staging-lane** inventory view, unit loads moved in directly show a **print/reprint label** button, but a unit load created by **splitting** an existing unit load does not. Operators cannot reprint labels for split ULs after a club run.

**Reproduction:** Prepare a club batch → move ULs to the staging lane → split a UL and move the result into the lane → complete the run → open the staging-lane inventory list. Directly-moved ULs show the print button; the split UL does not.

### DB verification (`db_verified: true`)

Query run against v2 UAT tenants on 2026-07-21 (via MCP `mcp__wsl-wineco-uat` and `mcp__wms2-hydra-uat`):

```sql
WITH stocked AS (
  SELECT ul.id,
         EXISTS(SELECT 1 FROM goodsreceiptposition g WHERE g.unitload_id = ul.id) AS has_grp
  FROM unitload ul
  WHERE EXISTS(SELECT 1 FROM stockunit su WHERE su.unitload_id = ul.id)
)
SELECT CASE WHEN has_grp THEN 'printable=true' ELSE 'printable=false (HIDDEN)' END AS status,
       COUNT(*) AS stocked_unitloads,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct
FROM stocked GROUP BY has_grp ORDER BY has_grp DESC;
```

**`wsl-wineco-uat` result:**

| status | stocked_unitloads | pct |
|---|---|---|
| printable=true (button shows) | 10,059 | 2.1% |
| printable=false (button HIDDEN) | 470,764 | 97.9% |

**`wms2-hydra-uat`** shows the same inversion (`HAS_GRP` 2,052 ULs / 89 stockunits vs `NO_GRP` 11,329 ULs / 19,331 stockunits).

**Interpretation:** `printable = "has a goodsreceiptposition row"` is a *receiving-provenance* proxy, not a reprint-eligibility signal. Split ULs are the reported slice of a much larger excluded population.

> **Scope note on the 97.9% figure:** the query above is computed over the **entire** `unitload` table, whereas the club screen filters to the staging lane + club item + `INNER JOIN stockunit`. The percentage therefore corroborates the *mechanism* (receiving-provenance ≠ reprint eligibility) but overstates the button-relevant population; it is not load-bearing for the fix. The point stands that any split/move-created UL on the lane is wrongly `printable=false`.

---

## 2. Root Cause Analysis

### Bug 1: `printable` computed from receiving provenance, not reprint eligibility

`CustomerorderBatchService.getClubLineUnitLoads(...)` fetches the printable set from `goodsreceiptposition` and threads it into `buildDtoList`:

`service/CustomerorderBatchService.java:1023-1041`
```java
// Batch fetch printable status
Set<Long> unitLoadIds = itemToUnitLoads.values().stream()
    .flatMap(List::stream).map(Unitload::getId).collect(Collectors.toSet());
Set<Long> printableUnitLoadIds = goodsreceiptpositionRepository.findPrintableUnitLoadIds(unitLoadIds);
...
return buildDtoList(positions, itemDataMap, itemToUnitLoads, locationMap,
    carrierMap, itemUnitMap, printableUnitLoadIds, orderBatch.getClientId());
```

`repo/jpa/GoodsreceiptpositionRepository.java:50-54` — `SELECT DISTINCT unitload_id FROM goodsreceiptposition WHERE unitload_id IN (:unitLoadIds)`. A `goodsreceiptposition` row exists only for ULs created during **receiving**. A **split** creates a new `Unitload` via `UnitloadService.createUnitload(..., CODE_MANUAL_SPLIT)` (`StockunitService.java:169,228`; `mobile/MobileMoveStockService.java:310,333`) and writes no `goodsreceiptposition`. So the split UL is absent from the set and gets `printable = false`:

`service/CustomerorderBatchService.java:1161`
```java
dto.setPrintable(printableUnitLoadIds.contains(unitLoad.getId()));
```

The Vue button gates solely on `item.printable` (`wms2-web-ui .../inventoryOnLaneTable.vue:63`), so it is hidden for split ULs while directly-moved ULs (keeping their receiving row) show it — exactly the reported symptom.

### Endpoint already capable for the provenance dimension (fix is safe on that axis)

`UnitloadService.reprintLabel` (`:242-255`) has an explicit branch: *Path 1* uses `goodsreceiptposition` data when present; *Path 2* ("UL created via split/move/transfer") builds the case label from the stock unit with `createCaseLabel(unitLoad, stockunit, null, null, warehouseName)`, and `SharedService.createCaseLabel` null-guards the absent advice/goodsreceipt (`:57-65,78`). The backend already prints split ULs — the goodsreceiptposition-absence dimension is safe.

### Bug 2 (verify-surfaced): the flag must also honor `reprintLabel`'s `NOT_LOCKED` precondition

`reprintLabel` hard-throws before printing anything if the UL is not active:

`service/UnitloadService.java:219-222`
```java
if (unitLoad.getEntityLock() != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
    throw new RuntimeException("Cannot reprint label for unitload=" + unitLoad.getLabelid() +
        ". UL is not active (entityLock=" + unitLoad.getEntityLock() + ")");
}
```

The staging-lane query `getBatchLocationsByItemIdAndLaneName` (`repo/jpa/UnitloadRepository.java:96-103`) does **not** filter on `entity_lock`, so a locked UL with stock can appear on the lane. Under the old gate this rarely mattered (only ~2.1% of stocked ULs were `printable=true`); making the flag stock-based expands the `true` population sharply, so a **locked lane UL would show the button and 500 on click**. Therefore the flag must also require `NOT_LOCKED` to match what the endpoint can actually serve. (The endpoint's empty-stock guard at `:226-229` is not a concern here — the staging query's `INNER JOIN stockunit` guarantees a direct stockunit on every listed UL.)

### "Has remaining stock" is the correct minimal signal

`buildDtoList` (`:1119-1164`) builds one DTO per UL with a non-zero amount of the club item and **skips `amount == 0`** before DTO creation (`:1136-1138`). `entry.getValue()` is the remaining stock computed by `calc()` (`:1197-1224`: `stockunit.amount` sum + child ULs, recursive). So `dto.setPrintable(entry.getValue() > 0)` captures reprint eligibility for the stock dimension and the `findPrintableUnitLoadIds` round-trip is dead weight. `> 0` (not `!= 0`, not a bare `true`) also correctly excludes a net-negative amount, since `calc()` sums signed amounts. Combined with the `NOT_LOCKED` conjunct (§2 Bug 2), the flag then matches exactly what `reprintLabel` can serve.

> **Approved eligibility rule (requester, 2026-07-21):** printable = the UL has remaining stock (≥1 stockunit of the club item), origin-agnostic. **Refined after architect review:** additionally require the UL to be active (`entityLock == NOT_LOCKED`) so the button is shown only when the reprint endpoint would actually succeed — see §10 for the tension this introduces vs. the literal "has stock" wording. Depleted or locked ULs correctly show no button.

---

## 3. Design / Proposed Fix

Single-method change in `CustomerorderBatchService`, API-only. No UI change, no DTO shape change, no schema change.

### 3.1 Fix A — set `printable` from remaining stock; delete the receiving-only query

**Before (`:1023-1041` + `:1113` + `:1161`):**
```java
Set<Long> unitLoadIds = itemToUnitLoads.values().stream()
    .flatMap(List::stream).map(Unitload::getId).collect(Collectors.toSet());
Set<Long> printableUnitLoadIds = goodsreceiptpositionRepository.findPrintableUnitLoadIds(unitLoadIds);
LOG.debug("unitLoadIds {}", unitLoadIds.size());
LOG.debug("printableUnitLoadIds {}", printableUnitLoadIds.size());
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
private List<ClubLineUnitLoadDto> buildDtoList(..., Long clientId) {   // printableUnitLoadIds removed
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

Delete the `unitLoadIds` build + `findPrintableUnitLoadIds` call + 2 LOG lines (`:1023-1030`). `WmsConstants` is already imported in this file.

> **NPE guard (must-do):** `Unitload.getEntityLock()` returns a **nullable `Integer`** (`model/Unitload.java:37`) and `NOT_LOCKED` is a primitive `int` (`WmsConstants.java:1169`), so a bare `getEntityLock() == NOT_LOCKED` unboxes and NPEs on a null lock. The `lock != null` guard above is mandatory; a null lock resolves to `active=false` (button hidden — the conservative choice, since `reprintLabel` itself would NPE on a null lock). **Test-fixture consequence:** any test asserting `printable == true` must set the UL's `entityLock = 0` (`NOT_LOCKED`); `buildUnitload(...)` leaves it null, so the existing `printable`-true assertions must add `setEntityLock(0)` or they will flip to false after this change.

**Why `> 0` and not a bare `true`:** they are **not** equivalent — the pre-DTO guard skips `amount == 0` but not `< 0`, and `calc()` sums signed amounts, so a net-negative UL would reach `setPrintable`; `> 0` correctly withholds the button. **Why not broaden `findPrintableUnitLoadIds`:** brittle (activity-code enumeration) and misses other non-receiving origins. **Why the `NOT_LOCKED` conjunct:** §2 Bug 2 — it makes the flag honest against the endpoint's real precondition, preventing a click-time 500 on locked lane ULs.

**Files changed:** `service/CustomerorderBatchService.java` only.

---

## 4. Architecture Overview

```
GET club-line unit loads (staging lane)
  CustomerorderBatchService.getClubLineUnitLoads(batch, onlyStagingLocation, skuFilter)   [@Transactional? see v2 §checklist]
    ├─ fetchUnitLoads()               → ULs on staging lane per item
    ├─ [REMOVED] findPrintableUnitLoadIds(unitLoadIds)   ← receiving-only gate (bug)
    └─ buildDtoList()
         └─ calculateUnitLoadAmounts()/calc()  → remaining stock per UL
              for each UL with amount>0:  dto.setPrintable(amount > 0 && entityLock==NOT_LOCKED)  ← FIX
  → JSON [{..., printable}] → wms2-web-ui inventoryOnLaneTable.vue v-if="item.printable"
                              → POST /unitLoad/reprintLabel (Path 2 handles split ULs)
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| `service/CustomerorderBatchService.java` | 1023-1041, 1106-1164 | `getClubLineUnitLoads` + `buildDtoList` (fix site) |
| `service/CustomerorderBatchService.java` | 1197-1224 | `calc()` — remaining-stock amount |
| `repo/jpa/GoodsreceiptpositionRepository.java` | 50-54 | `findPrintableUnitLoadIds` (caller removed; method kept — §10 Q1) |
| `json/ClubLineUnitLoadDto.java` | 107-113 | `printable` field (unchanged) |
| `service/UnitloadService.java` | 241-255 | reprint Path 1/Path 2 — already prints split ULs, no change |

---

## 5. Implementation Steps

### 5.1 Prerequisites

| Concern | Applies? |
|---|---|
| DB state | Done — §1 verified on wsl-wineco-uat + wms2-hydra-uat. |
| Feature flags / sysprops | N/A — immediate, desired behavior change. |
| Config / env | N/A. |
| Deploy-order dependency | N/A — API-only; wms2-web-ui already consumes `printable`. |
| Data migration | N/A. |
| External systems | N/A. |
| Access / monitoring | N/A. |

### 5.2 Steps (atomic)

1. **Test-first (`wms-tdd-gate`):** add a nested-class unit test proving a split UL (no `goodsreceiptposition`, has stock in lane) yields `printable = true`. Confirm failure against current code.
2. Remove the `findPrintableUnitLoadIds` fetch + `unitLoadIds` build + 2 LOG lines (`:1023-1030`); drop `printableUnitLoadIds` from the `buildDtoList` call and signature.
3. Change `dto.setPrintable(...)` → `dto.setPrintable(entry.getValue() > 0 && unitLoad.getEntityLock() == WmsConstants.BusinessObjectLockState.NOT_LOCKED)` with the SBDEV-2485 comment.
4. Remove the 5 `findPrintableUnitLoadIds(anySet())` Mockito stubs in `CustomerorderBatchServiceUnitTest`. **Note:** this test class is `@MockitoSettings(strictness = Strictness.LENIENT)` (`:37`), so leftover stubs would **not** throw `UnnecessaryStubbingException` — removal is hygiene, not a compile/test blocker (unlike v1, which runs strict). The `T-nostub` acceptance check still enforces it.
5. `mvn clean compile`; run the verify script + targeted tests (§8). Update §11.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/CustomerorderBatchService.java` | Modify | Remove receiving-only printable query + param; `printable = entry.getValue() > 0 && NOT_LOCKED` |
| `test/.../CustomerorderBatchServiceUnitTest.java` | Modify | Remove `findPrintableUnitLoadIds` stubs; add split-UL + locked-UL printable tests |
| `repo/jpa/GoodsreceiptpositionRepository.java` | None (§10 Q1) | Method kept as HAL resource; optional removal deferred |

> **Orphaned dependency note:** after removing the only service caller, the constructor-injected `goodsreceiptpositionRepository` field (`:73`, assigned `:134,163`) becomes unused **in this class**. It compiles fine and is left in place for a minimal diff (the field is small and may be reused later); do not remove the constructor param, or the `CustomerorderBatchServiceUnitTest` constructor wiring would also need updating for no benefit. Flagged so a reviewer isn't surprised.

---

## 7. Testing Plan

### Unit (JUnit 5 + Mockito; H2 not needed — pure service logic with mocks)
> **Coverage gap (G2):** the v2 `CustomerorderBatchServiceUnitTest` currently has **zero** `printable` assertions, so `T-unit` alone cannot catch a `printable` regression. The two new tests below are the only guard — they are mandatory, not optional (enforced by the `T-split`/`T-locked` acceptance checks).
- `getClubLineUnitLoads_shouldMarkPrintable_whenSplitUnitLoadHasStockAndNotLocked` — active UL, stock in lane, **no** goodsreceiptposition; assert `printable == true` (the fix).
- `getClubLineUnitLoads_shouldNotMarkPrintable_whenUnitLoadLocked` — UL with stock in lane but `entityLock != NOT_LOCKED`; assert `printable == false` (§2 Bug 2 — button must not show for a UL the endpoint would reject).
- `getClubLineUnitLoads_shouldMarkPrintable_whenStockLivesOnChildUnitLoad` — parent lane UL has no direct stock; stock lives on a carried child UL, so `calc()` recursion reaches amount > 0 → `printable == true`. Covers the recursion branch and guards the null-`entityLock` fixture trap (parent set `NOT_LOCKED`). (Replaces the earlier received-regression test, which after the query removal was behaviorally identical to the split test — per code-review.)
- Update existing nested-class tests (`excludesBatchStagingLaneFromResults`, `skipsUnitLoadsNotBelongingToClient`, `skipsUnitLoadsWithZeroAmount`, and the two others at `:2141,:2198`) to drop the now-unnecessary `findPrintableUnitLoadIds` stub (hygiene under LENIENT).
- Retain `skipsUnitLoadsWithZeroAmount` — proves depleted ULs never reach DTO creation (so never printable).

### Integration
- N/A — v2 Testcontainers IT harness is blocked (memory `wms2-it-harness-broken-sbdev-2217`); gate on unit tests + `mvn clean compile`. Leave any IT `@Disabled` with `TODO(SBDEV-2217)`.

### Regression
- Full `CustomerorderBatchServiceUnitTest` green after stub removal.

### Manual test plan

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Split UL shows reprint button | v2 UAT (wineco/hydra) | Club run → split UL → move split UL to staging lane → open staging-lane inventory | Split UL row shows print button; click reprints label (Path 2) | |
| Directly-moved UL unchanged | v2 UAT | Received UL moved to lane | Print button still shown | |
| Depleted UL absent | v2 UAT | UL consumed to amount 0 | Row not listed | |

---

## 7b. Horizontal Scalability Validation (v2 mandatory)

Multiple replicas behind a load balancer. Verdicts:

| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state (Caffeine/static/ThreadLocal) | **N/A** — no new state; a method-local `memoCache` already exists and is unchanged |
| 2 | Connection pool math | **Improved** — removes one native query (`findPrintableUnitLoadIds`) per club-line load; strictly fewer round-trips |
| 3 | Scheduled jobs | **N/A** — no `@Scheduled` touched |
| 4 | Long transactions | **N/A** — read path; no new I/O, one fewer query |
| 5 | Request affinity | **N/A** — stateless request |
| 6 | Retry / idempotency | **N/A** — read-only |
| 7 | Tenant context | **N/A** — request-thread read; no async/ForkJoin added (SBDEV-2218 sequential-processing guard untouched) |
| 8 | Distributed lock correctness | **N/A** — no locks |
| 9 | Cache invalidation | **N/A** — `ClubLineUnitLoadDto` is a transient DTO, not a cached entity; no `@Cacheable` on this path |
| 10 | External notifications | **N/A** — no OMS/broker send |

No **Yes** rows — the change removes a query and flips a boolean expression on a read path.

## 7c. v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled — lazy loads inside a tx | **N/A** — no new lazy access; stock/amount already fetched via explicit repo calls in `calc()` |
| 2 | `tenantTransactionManager` on tenant writes | **N/A** — read-only method; no write, no TM change |
| 3 | `@Transactional(readOnly=true)` | **N/A / no change** — `getClubLineUnitLoads` has **no** `@Transactional` annotation today (`:939`); the fix does not add one. Safe because this codebase uses manual FK fetches (no JPA associations), so there is no lazy-load to strand under OSIV-disabled, and the change only *removes* a query. Adding `readOnly=true` here would be a separate, out-of-scope hardening. |
| 4 | Caffeine cache invalidation | **N/A** — no cached entity written |
| 5 | Jakarta namespace | **N/A** — no imports added/changed |
| 6 | H2-compatible test SQL | **N/A** — unit test uses mocks, no native SQL |
| 7 | `BaseControllerTest` for controller changes | **N/A** — no controller change |
| 8 | Micrometer metrics | **N/A** — read path, no new failure mode |

---

## 8. Acceptance

Verify script: `sbdocs/9-System/scripts/verify-SBDEV-2485-club-split-unitload-reprint-label-v2.sh`
Run: `PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api bash sbdocs/9-System/scripts/verify-SBDEV-2485-club-split-unitload-reprint-label-v2.sh`

Checks: (A-pos-stock) `setPrintable(... entry.getValue() > 0 ...)`; (A-pos-lock) `NOT_LOCKED` present in the same `setPrintable` expression; (A-neg1/A-neg2) no `setPrintable(printableUnitLoadIds.contains(` and no `findPrintableUnitLoadIds` call remain in the service; (A-param) `buildDtoList` no longer declares `printableUnitLoadIds`; (T-split) split-UL regression test exists; (T-locked) locked-UL test exists; (T-nostub) no leftover stub; (C-compile) `mvn clean compile` (keys off mvn exit code); (T-unit) `CustomerorderBatchServiceUnitTest` passes. Final: `Result: N pass, 0 fail`.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Button appears on ULs previously hidden | Intended (the fix) | Requester-approved; reprint Path 2 handles the provenance dimension; `NOT_LOCKED` conjunct handles the lock dimension |
| **Locked lane UL shows a button that 500s on click** | Bad UX / error | §2 Bug 2 — flag now requires `entityLock == NOT_LOCKED`; new `lockedUnitLoad` test asserts `printable=false` |
| `findPrintableUnitLoadIds` stubs left | Slight test noise only | Test class is LENIENT (`:37`) — leftover stubs do **not** fail the suite; Step 4 removes them for hygiene; `T-nostub` enforces |
| External HAL client uses `findPrintableUnitLoadIds` rel | Broken integration | Repository method kept (§10 Q1); only internal caller removed |
| Depleted / net-negative UL loses button | Correct — nothing to reprint | amount==0 excluded pre-DTO; `> 0` excludes net-negative; matches approved rule |

---

## 10. Open Questions / Resolved Decisions

- **Resolved (requester, 2026-07-21):** eligibility = "has remaining stock," API-side.
- **Resolved:** no UI change — `wms2-web-ui` already gates on `item.printable`.
- **Q2 (RESOLVED — requester, 2026-07-21):** keep the `&& entityLock == NOT_LOCKED` conjunct. The flag is intentionally narrower than the literal "has remaining stock" rule so it matches what `reprintLabel` can actually serve (§2 Bug 2) — a locked lane UL will simply not show the button rather than 500 on click. Surfacing the lock state via a visible-but-erroring button was explicitly declined as out of scope.
- **Q1 (deferred, low):** remove the caller-less `findPrintableUnitLoadIds`? It is `@RestResource`-exposed. **Recommendation:** keep now; revisit in a dead-code sweep after confirming no external client uses the rel. (The now-unused injected field is addressed in §6.)

---

## 11. Implementation Status

**Implemented 2026-07-21 (uncommitted — no branch/PR yet; awaiting go-ahead).**

### Code changes — `service/CustomerorderBatchService.java`
- Removed the receiving-only printable fetch (`findPrintableUnitLoadIds` + `unitLoadIds` build + 2 `LOG.debug` lines) in `getClubLineUnitLoads`.
- Dropped the `Set<Long> printableUnitLoadIds` parameter from `buildDtoList` (signature + call site).
- Replaced `dto.setPrintable(printableUnitLoadIds.contains(unitLoad.getId()))` with the null-safe reprint-eligibility gate:
  ```java
  Integer lock = unitLoad.getEntityLock();
  boolean active = lock != null && lock == WmsConstants.BusinessObjectLockState.NOT_LOCKED;
  dto.setPrintable(entry.getValue() > 0 && active);
  ```
- `goodsreceiptpositionRepository` field intentionally kept (§6, §10 Q1) — now unused in this class only.

### Tests — `CustomerorderBatchServiceUnitTest` (nested `GetClubLineUnitLoads`)
- Added `getClubLineUnitLoads_shouldMarkPrintable_whenSplitUnitLoadHasStockAndNotLocked` (the fix).
- Added `getClubLineUnitLoads_shouldNotMarkPrintable_whenUnitLoadLocked` (NOT_LOCKED gate).
- Added `getClubLineUnitLoads_shouldMarkPrintable_whenStockLivesOnChildUnitLoad` (`calc()` child-carrier recursion → printable; also guards the null-`entityLock` fixture trap). Replaced an earlier received-UL regression test that, post query-removal, was behaviorally identical to the split test (code-review finding).
- Added `amount` assertions to the split/locked tests to pin the DTO under assertion.
- Removed all 7 `findPrintableUnitLoadIds(anySet())` Mockito stubs (query no longer exists).
- TDD gate baseline (pre-fix): 2 of 3 failed at the assertion for the right reason; post-fix all pass.

### Code review (2026-07-21, `code-reviewer` agent)
- Verdict **APPROVE** — 0 blocking; 3 MINOR + 1 NIT (all test-hygiene). Verified correct: unboxing/NPE safety of the `lock != null && lock == NOT_LOCKED` gate, net-negative handling (`> 0`), the non-batched `calc()` mock path, child-UL/carrier consistency, v2 conventions, and the one intended behavior change (locked+received UL now hidden).
- MINOR/NIT items **fixed**: redundant regression test → recursion test; stale comment reworded; `amount` assertions added. Dead `goodsreceiptpositionRepository` field left intentionally (§6, §10 Q1) per reviewer's "no action required".

### Verification (2026-07-21, Java 21 / Maven 3.9.15 via SDKMAN)
- `mvn clean compile` — SUCCESS.
- `mvn test -Dtest=CustomerorderBatchServiceUnitTest` — PASS (full class green; no regressions in-class).
- Verify script `verify-SBDEV-2485-club-split-unitload-reprint-label-v2.sh` — **`Result: 10 pass, 0 fail, 0 skip`**.
- Full `mvn test` regression sweep — 4370 run, **2 failures, 0 errors**, 67 skipped. Both failures (`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` — violations in `PickLineRealignmentService`/`MobileReplenishService`; `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`) are **pre-existing on `develop`**, proven by re-running both on the stashed (pristine) tree — neither touches `CustomerorderBatchService`, and this change adds no `Optional.get()`. No new regressions.
- Integration: N/A (v2 IT harness blocked, SBDEV-2217).

### Follow-ups
- v1 pair not yet implemented (same change; strict-stubbing removal required there).
- Not committed — create `task/SBDEV-2485` branch + PR into `develop` on go-ahead.
