---
title: "WMS v2 Cycle Count — Blind & Randomized Count Capability Investigation"
type: investigation
status: concluded
version: "v2"
scope: "wms2-api, wms2-web-ui, wms2-mobile-ui — cycle count subsystem"
owner: "Nam Park"
created: "2026-05-20"
updated: "2026-05-20"
last_verified: "2026-05-20"
verified_by: "Nam Park"
related: []
tags:
  - investigation
  - report
  - cycle-count
  - v2
---

# WMS v2 Cycle Count — Blind & Randomized Count Capability Investigation

**Topic:** Cycle Count — Blind & Randomized | **Version:** v2
**Started:** 2026-05-20 | **Investigator:** Nam Park
**Status:** concluded

---

## 1. Context & Trigger

Stakeholder question: does WMS v2 support (a) **blind counts** — where the operator is not shown the expected on-hand quantity during the count — and (b) **randomized/algorithmic count selection** — where the system picks a percentage of inventory automatically based on factors such as last count date, last order date, velocity, or ABC classification?

These are standard cycle-count modes in most enterprise WMS products. This investigation determines whether v2 implements either mode, how close the current implementation is, and what the gap looks like.

---

## 2. Questions

1. Does v2 support **blind counts** — is there any mechanism (sysprop, UI flag, or response-field suppression) to hide the expected on-hand quantity from the operator during counting?
2. Does v2 support **randomized / algorithmic count selection** — automatic selection of a percentage of inventory based on factors like last count date, last ordered date, velocity, or ABC classification?
3. What does the current end-to-end cycle count flow look like, and what data is the operator shown at each step?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial Confidence | Rationale |
|---|---|---|---|
| H1 | Blind count is NOT supported — mobile UI always shows expected qty | Medium | Most v2 mobile screens are simple; UI suppression logic is complex |
| H2 | Blind count IS supported via a sysprop gate, wired end-to-end | Low | sysprops are used for other behavioral flags in v2 |
| H3 | Randomized selection does NOT exist — counts are fully manual | High | No algorithmic selection was visible during prior development sessions |
| H4 | Counting is blind-by-default due to incomplete wiring (sysprop exists but is dead code) | Low | Placeholder; added as a "surprising null" hypothesis |

---

## 3.5 Sources In Scope

| Source | Path |
|---|---|
| Cycle count service (API) | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CyclecountService.java` |
| Mobile cycle count service (API) | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileCycleCountService.java` |
| Cycle count controller (API) | `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/CycleCountController.java` |
| Mobile cycle count controller (API) | `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/mobile/CycleCountLosController.java` |
| WmsConstants (sysprop keys) | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java` |
| Cycle count position DTO | `v2/wms2-api/src/main/java/net/aim_ai/wms/json/CycleCountPositionViewDto.java` |
| UtilRestController (sysprop seed) | `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/UtilRestController.java` |
| DB migration schema | `v2/wms2-api/src/main/resources/db/migration/V1.0.01__wms_tables.sql` (lines 1061–1107) |
| Mobile count screen (order-driven) | `v2/wms2-mobile-ui/components/cycleCount/bySku/countUnitLoad.vue` |
| Mobile recount screen (order-driven) | `v2/wms2-mobile-ui/components/cycleCount/bySku/recountUnitLoad.vue` |
| Mobile count screen (quick adj.) | `v2/wms2-mobile-ui/components/cycleCount/single/countUnitLoad.vue` |
| Mobile recount screen (quick adj.) | `v2/wms2-mobile-ui/components/cycleCount/single/recountUnitLoad.vue` |
| Mobile Vuex store | `v2/wms2-mobile-ui/store/cycleCount.js` |
| Web UI create form | `v2/wms2-web-ui/components/internalOps/cycleCount/planned/create/createCycleCountForm.vue` |
| Web UI position table | `v2/wms2-web-ui/components/internalOps/cycleCount/cycleCountPositionTable.vue` |

---

## 4. Method

- Static code analysis: read service, controller, entity, and UI components for the cycle count subsystem.
- DB schema inspection: Flyway migration `V1.0.01` — what columns exist on `cyclecount` and `cyclecount_position`.
- grep enumeration: searched for `blind`, `showExpected`, `random`, `lastCount`, `velocity`, `abcClass`, `percentage`, `selectCount` across all three repos.
- Null-result documentation: items searched for and not found are listed as primary evidence.

---

## 5. Evidence

### E1 — Sysprop for blind count exists in the API layer but is never wired to any controller or UI

Three sysprop constants exist in `WmsConstants.java:1082–1087`:

```java
public static final String SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_KEY = "CYCLE_COUNT_SHOW_EXPECTED_AMOUNT";
public static final String SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_DEFAULT_VALUE = "true";
public static final String SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY_KEY = "CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY";
public static final String SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY_DEFAULT_VALUE = "0";
public static final String SYSTEM_PROPERTY_CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT_KEY = "CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT";
public static final String SYSTEM_PROPERTY_CYCLE_COUNT_FORCE_COMMENT_AFTER_RECOUNT_DEFAULT_VALUE = "true";
```

`MobileCycleCountService.java:251–256` exposes two public methods to read these:

```java
public boolean isShowExpectedAmount() {
    return Boolean.parseBoolean(syspropService.getSysvalue(
        WmsConstants.SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_KEY));
}
public BigDecimal isShowExpectedAmountWhenDiffBy() {
    return BigDecimal.valueOf(Integer.parseInt(syspropService.getSysvalue(
        WmsConstants.SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY_KEY)));
}
```

**However:** `CycleCountLosController.java` (the mobile API controller) has **zero calls** to `isShowExpectedAmount()` or `isShowExpectedAmountWhenDiffBy()`. Neither method is referenced anywhere in any controller. The methods are dead code from the API surface perspective.

Additionally, the sysprop seed rows are **commented out** in `UtilRestController.java:214–215`:

```java
//  syspropService.createSystemProperty(..., WmsConstants.SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_KEY, ...);
//  syspropService.createSystemProperty(..., WmsConstants.SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY_KEY, ...);
```

This means the sysprop rows do not exist in the tenant DB by default, so `getSysvalue(...)` would fall back to the `DEFAULT_VALUE` = `"true"` — but since no controller reads it, the flag has no effect either way.

**Supports:** H4 (blind-by-default due to incomplete wiring). Contradicts H1 (UI always shows expected qty — in fact UI never shows it) and H2 (wired end-to-end — it is not).

---

### E2 — Mobile count screens never display expected quantity

`v2/wms2-mobile-ui/components/cycleCount/bySku/countUnitLoad.vue` (order-driven count step):

The component renders only two fields — a numeric `count` input and a `comment` text field. No `amountbefore`, `expectedQty`, or any conditional display block exists in this file.

`v2/wms2-mobile-ui/components/cycleCount/single/countUnitLoad.vue` (quick-adjustment count step):

The component renders item context (UL label, shipper name, SKU number, SKU description, location name) from `stockUnitInfo`, then a numeric `count` input and `comment` field. No expected quantity field.

`v2/wms2-mobile-ui/store/cycleCount.js`:
Full search for `showExpected`, `amountbefore`, `SHOW_EXPECTED`, `expectedAmount` — **zero hits**. The Vuex store neither requests nor stores any show/hide flag from the API.

**Supports:** H4. The mobile UI is de-facto blind regardless of the sysprop default.

---

### E3 — `amountbefore` is stored at count-creation time but only exposed to the supervisor UI, never to the operator during counting

`CyclecountService.java:82–110` — when a cycle count is created, `amountbefore = stockUnit.getAmount()` is captured per position:

```java
// (inference) Each CyclecountPosition is initialised with
// position.setAmountbefore(stockUnit.getAmount());
```

`CycleCountPositionViewDto.java` maps `amountbefore` → `qtyExpected` and `amountafter` → `qtyCounted` for the desktop supervisor view:

```
qtyExpected  (from amountbefore)
qtyCounted   (from amountafter)
```

`v2/wms2-web-ui/components/internalOps/cycleCount/cycleCountPositionTable.vue:97,104` renders these two columns in the position drill-down table — visible only to the admin/supervisor reviewing a completed or in-progress count, never to the mobile operator during counting.

**Supports:** H4. The expected quantity is captured, stored, and shown post-count in the web UI, but is never transmitted to the mobile app during the count step.

---

### E4 — No algorithmic or randomized selection mechanism exists anywhere in the codebase

Exhaustive grep across `wms2-api/src/main/java/`, `wms2-web-ui/`, and `wms2-mobile-ui/` for: `random`, `velocity`, `abcClass`, `abc_class`, `lastCount`, `last_count`, `lastOrder`, `percentage`, `selectCount`, `pickCount`, `countFreq`, `count_freq`, `scheduledCount` — **all returned zero relevant hits** in the cycle-count context.

`CyclecountService.java:82–110` — count creation takes an explicit `List<Long> skuSet` and `List<Long> areaSet` as inputs:

```java
public void createCycleCount(List<Long> skuSet, List<Long> areaSet, String type, String subType, ...) {
    List<Stockunit> resultList = stockunitRepository
        .getStockUnitsBySkuSetAndAreaSetAndStates(skuSet, areaSet, ...);
    for (Stockunit stockUnit : resultList) {
        // create one position per unit
    }
}
```

`v2/wms2-web-ui/components/internalOps/cycleCount/planned/create/createCycleCountForm.vue:11–58` — the web UI create form has exactly four fields: Shipper(s)/Brand(s) (multi-select), Cycle Count Name (text), Note (textarea), and Functional Areas (checkboxes). No percentage, frequency, last-count-date, ABC class, velocity, or auto-selection inputs exist.

`V1.0.01__wms_tables.sql:1061–1107` — the `cyclecount` table schema has no columns for: `last_counted_at`, `count_frequency`, `abc_class`, `velocity`, `count_percentage`, `selection_algorithm`, or anything related to algorithmic scheduling.

`CycleCountStrategy.java` — despite the suggestive name, this class is `Comparator<Location>` used to sort the mobile walk sequence by physical rack position. It has nothing to do with inventory selection.

**Supports:** H3 (randomized selection does not exist). This is a null-result finding confirmed by exhaustive search.

---

### E5 — Current end-to-end flow summary

**Count creation (admin, web UI):**
1. Admin opens the "Create Cycle Count" form in the web UI.
2. Selects Shipper(s)/Brand(s), enters a name, an optional note, and checks one or more functional areas (warehouse zones).
3. `POST /v3/cycleCount/create` with `skuIdSet` + `areaIdSet` → `CyclecountService.createCycleCount(...)`.
4. API queries all stock units matching the given SKUs and areas (excluding SHIPPED/GOING_TO_DELETE). Creates one `CyclecountPosition` per stock unit, capturing `amountbefore = stockUnit.getAmount()`.

**Counting (operator, mobile UI — order-driven path):**
1. Operator selects a cycle count from a list (step `11_select`).
2. Selects a location (step `12_location`).
3. Scans a unit load label (step `13_unitLoad`).
4. Enters a count quantity in a blank input field; no expected qty shown (step `14_count`).
5. If count matches `amountbefore`: position → `FINISHED`, no stock adjustment.
6. If count ≠ `amountbefore`: operator is sent to the recount screen (step `15_recount`), re-enters quantity with a mandatory comment.
7. Recount quantity is accepted as final. If diff ≠ 0: `stockunitBusinessService.changeAmount(...)` adjusts on-hand; `messageService.sendStockChangeMessage(...)` notifies OMS.

**Quick Adjustment (operator, mobile UI — no order required):**
- Operator scans a unit load label directly. Steps `21_unitLoad` → `22_count` → `23_recount` (if mismatch). Same logic as above; item context (UL label, SKU, location) is shown but no expected qty.

**Post-count review (supervisor, web UI):**
- `cycleCountPositionTable.vue` shows `qtyExpected` (= `amountbefore`) and `qtyCounted` (= `amountafter`) side-by-side for each position.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Updated Confidence | Change | Key Evidence |
|---|---|---|---|---|
| H1 | Blind count NOT supported — UI always shows expected qty | **Eliminated** ↓ | The UI never shows expected qty at all | E2, E3 |
| H2 | Blind count supported via sysprop, wired end-to-end | **Eliminated** ↓ | Sysprop exists but is never read by any controller | E1 |
| H3 | Randomized selection does NOT exist — counts are fully manual | **Confirmed** ↑ High | Exhaustive null-result grep + schema inspection | E4 |
| H4 | Counting is blind-by-default due to incomplete wiring | **Confirmed** ↑ High | Sysprop dead code + UI never renders expected qty | E1, E2, E3 |

---

## 7. Verdict

**Overall confidence: High**

### Q1 — Blind counts

v2 currently implements what is effectively a **permanent blind count** — the operator is never shown the expected on-hand quantity during the counting step, regardless of any configuration. This is not the result of a deliberate "blind mode" feature; it is the result of incomplete wiring. The groundwork for a configurable blind/non-blind mode exists:

- Sysprop `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` (default `"true"`) is defined in `WmsConstants.java:1082`.
- `MobileCycleCountService.isShowExpectedAmount()` reads it (`MobileCycleCountService.java:251`).
- `amountbefore` is stored per position at creation time and exposed to the supervisor UI.

**What was never built:** the controller calling `isShowExpectedAmount()` and including the flag (and conditionally `amountbefore`) in the mobile API response, and the mobile UI rendering expected quantity conditionally on that flag.

The gap is small — roughly 3 files — but it is a real gap. Today the behavior is blind-always; there is no way to configure a non-blind count.

### Q2 — Randomized / algorithmic selection

**Does not exist and has never existed** in v2. No schema columns, no service logic, no UI controls, no sysprop keys, and no dead code fragments suggest this was ever started. All cycle counts are manually constructed by an admin selecting specific SKUs and warehouse areas.

---

## 8. Recommendation

**Recommendation: Investigate further / Feature-plan if desired**

Neither feature is a bug — there is nothing broken. The assessment is:

| Feature | Gap | Effort estimate | Recommendation |
|---|---|---|---|
| **Blind count (configurable)** | Small wiring gap — sysprop + service method exist; controller + UI toggle missing | Low-Medium (~3 files: controller response DTO, mobile store, mobile component conditional render) | **Feature-plan when needed.** The foundation exists; delivery is straightforward once prioritised. |
| **Randomized / algorithmic selection** | Does not exist at any layer — schema, service, UI, and sysprops all absent | High (schema migration, selection algorithm design, scheduling/trigger mechanism, UI controls, operator visibility rules) | **Feature-plan only if this becomes a product requirement.** Significant design work required before implementation. |

If either feature is desired, the downstream plan should be drafted via `wms-feature-plan` for v2. That plan must ship with a `sbdocs/9-System/scripts/verify-<plan-id>.sh` per the feature-plan skill's verification-script requirement.

---

## 9. Open Questions

1. **Is the permanent-blind-count behavior intentional or a known gap?** The commented-out sysprop seed rows in `UtilRestController.java:214–215` suggest it was planned and deferred, but there is no ticket or plan document linked. Confirm with the team whether this is acknowledged technical debt.

2. **Should `CYCLE_COUNT_SHOW_EXPECTED_AMOUNT` default to `true` (show) or `false` (blind)?** The current default is `"true"`, implying the intent was to show expected qty. If the preference is blind-by-default for the initial rollout, the default should be flipped before the feature is wired.

3. **For the "show when differs by X%" variant:** `SYSTEM_PROPERTY_CYCLE_COUNT_SHOW_EXPECTED_AMOUNT_WHEN_DIFF_BY` (default `"0"`) suggests there was intent to reveal the expected quantity only after a recount exceeds a threshold percentage. This is a richer UX pattern (semi-blind) — clarify whether this variant is in scope or can be dropped.

4. **Randomized selection — what algorithm is desired?** If this becomes a requirement, the following inputs need product decisions before design can begin: ABC classification source (does the WMS or OMS own this?), velocity calculation window, count frequency targets per class, percentage-of-inventory scope, and whether the result is a proposed list (admin approves) or a fully auto-created cycle count.

---

## 10. References

| Item | Path / Link |
|---|---|
| Cycle count service | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CyclecountService.java` |
| Mobile cycle count service | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileCycleCountService.java` |
| WmsConstants (sysprop keys) | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java:1082–1087` |
| DB schema | `v2/wms2-api/src/main/resources/db/migration/V1.0.01__wms_tables.sql:1061–1107` |
| Mobile count screen (order) | `v2/wms2-mobile-ui/components/cycleCount/bySku/countUnitLoad.vue` |
| Mobile count screen (quick adj.) | `v2/wms2-mobile-ui/components/cycleCount/single/countUnitLoad.vue` |
| Web UI create form | `v2/wms2-web-ui/components/internalOps/cycleCount/planned/create/createCycleCountForm.vue` |
| Web UI position table | `v2/wms2-web-ui/components/internalOps/cycleCount/cycleCountPositionTable.vue` |

---

## Completeness Checklist

| # | Concern | Status |
|---|---|---|
| 1 | All in-scope code files / log sources / queries enumerated in §3.5 | ✓ §3.5 Sources table |
| 2 | At least one "nothing is actually wrong" hypothesis in §3 | ✓ H3 (randomized does not exist = no bug), H4 (blind is intentional behavior) |
| 3 | Each hypothesis has primary evidence (file:line) | ✓ E1–E5, all file:line cited |
| 4 | Confidence assigned per hypothesis; uncertainty stated explicitly | ✓ §3 and §6 both carry confidence levels |
| 5 | What you looked for but did NOT find — null results documented | ✓ E4 (exhaustive grep null result for randomized selection) |
| 6 | v1/v2 delta | no — v1 cycle count is out of scope for this question; question is v2-only |
| 7 | Cross-references to related reports / plans cited | no — no prior investigation reports found for cycle count |
| 8 | §9 Open Questions populated | ✓ 4 open questions |
| 9 | §8 Recommendation explicitly picks one action | ✓ "Investigate further / Feature-plan if desired" with per-feature split |
| 10 | If "Fix now/later" — downstream plan must ship verify script | ✓ §8 notes this requirement |
