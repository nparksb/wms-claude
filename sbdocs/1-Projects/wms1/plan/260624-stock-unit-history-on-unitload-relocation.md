---
title: "Log Whole-Unit-Load Relocations in Stock-Unit History (Move Fixed Location + Move Stock)"
ticket: ""
ticket_url: ""
pr: "https://github.com/SiteBossInc/wms-api/pull/178"
type: bug
priority: medium
status: implemented
project:
  - wms-api-v1
version: v1
requester: "QA (SBDEV-2481 UAT)"
created: 2026-06-24
updated: 2026-06-24
db_verified: false
related:
  - "[[260624-stock-unit-history-gap-on-unitload-location-move]]"
  - "[[SBDEV-2481-stale-pick-line-realignment-on-stock-move]]"
tags:
  - plan
  - stock-history
  - move-stock
---

# Log Whole-Unit-Load Relocations in Stock-Unit History (Move Fixed Location + Move Stock)

**Ticket:** _(untracked — to be assigned)_
**Project:** wms-api-v1 | **Version:** v1 | **Type:** bug (enhancement-shaped audit-coverage fix)
**Priority:** medium
**Status:** IMPLEMENTED (branch `fix/stock-unit-history-relocation`, uncommitted — see §11)
**Date:** 2026-06-24

> **Scope qualifier:** this plan logs the **two operator whole-UL relocation paths the tester named** — Move Fixed Location and Move Stock (whole-UL branch). It deliberately does **not** cover the mobile "Move Unitload" path (`CODE_TRANSFER`, §0 row 7, §10-#6) or any system move (shipping/putaway/BOL/truck-load). The claim "we now log operator whole-UL relocations" must always be read as **"these two paths."**

> `db_verified: false` — **rationale:** the fix is code-provable (a new `Stockrecord` write at two named call sites). The empirical DBA close-out is a one-shot live check: perform one **Move Fixed Location**, then confirm a new `stockrecord` row with `type='STOCK_RELOCATED'` appears for the moved stock unit (SQL in §6). No schema change is involved, so no migration to verify.

---

## 0. Affected Sites

| # | File | Line (confirmed) | Change | In scope |
|---|------|------|--------|----------|
| 1 | `service/WmsConstants.java` `StockRecordType` | :168-179 | **ADD** `STOCK_RELOCATED = "STOCK_RELOCATED"` | Yes (F-A) |
| 2 | `service/StockrecordService.java` | new method after `:298` | **ADD** `recordRelocation(Stockunit, Location fromLocation, Location toLocation, String activityCode, String orderNumber, String comment)` | Yes (F-B) |
| 3 | `service/FixLocationAssignmentService.move()` | `:161` (after `transferUnitLoadToLocation`); `oldLocation` `:101`; `stockunitList` `:145` (hard-throws if size>1 at `:148-150`) | **CALL** `recordRelocation` per stock unit; inject `StockrecordService` | Yes (F-C) |
| 4 | `service/StockunitService.transferStock()` whole-UL branch | `:185` (after `transferUnitLoadToLocation`, gated `:183` `size()==1`); `ulLocation` `:179`; `destinationLocation` `:140` | **CALL** `recordRelocation`; inject `StockrecordService` | Yes (F-D) |
| 5 | `service/UnitloadBusinessService.processTransfer` | :230-247 | **OUT** — Option B rejected (would log every UL move incl. shipping/putaway/BOL bulk). Rejected alternative (§5, §9, RALPLAN-DR). | No |
| 6 | Other **system** `transferUnitLoadToLocation` callers (`ReceivingService`, `MobilePutAwayService`, `PickingorderBusinessService`, `BillofladingService`, `MobileTruckLoadingService`) | — | **OUT** — not operator relocations. Protected by the processTransfer negative verify check + scope-guard AC-4. | No |
| 7 | `service/mobile/MobileMoveUnitloadService` | :250 / :378 / :382 (`CODE_TRANSFER`) | **OUT — KNOWINGLY DEFERRED.** A *third* operator whole-UL move the tester did **not** name. Not logged by this plan; documented as a known gap (§10-#6). The verify-script does **not** forbid a future deliberate addition here. | No (deferred) |

---

## 1. Problem Statement

**Symptom (reported in SBDEV-2481 UAT):** A QA tester performing **Move Fixed Location** observed that the product is physically relocated but **no entry appears in the stock-unit history**. They correctly suspected it pre-dates SBDEV-2481.

**Impact:** Loss of audit/traceability. An operator-initiated physical relocation of inventory is invisible in the stock-unit history (the screen the operator/auditor consults). The same gap silently affects the **Move Stock → "move the whole unit load"** branch (and the mobile Move Unitload path — deferred, §10-#6).

**Expected:** An operator-initiated whole-unit-load relocation should produce a stock-unit history entry recording the from-location, to-location, operator, and activity, in addition to the existing unit-load (container) history entry.

**Reproduction:**
1. Pick a fixed-location assignment with one unit load / one stock unit on a flowbin.
2. **Move Fixed Location** to an empty flowbin destination.
3. Open the moved stock unit's **stock unit history** → no relocation row. The **unit-load history** *does* show the move.

---

## 2. Root Cause Analysis

WMS v1 maintains **two distinct movement histories**:

- **`UnitloadRecord`** (`UnitloadRecordService`) — *container* movement.
- **`Stockrecord`** (`StockrecordService`) — *stock-unit* events, surfaced in the UI as **stock unit history**.

A whole-unit-load relocation routes through `UnitloadBusinessService.transferUnitLoadToLocation` → `processTransfer`, which writes **only** a `UnitloadRecord`:

```java
// UnitloadBusinessService.processTransfer (:230-247)
unitload.setStoragelocationId(destinationLocation.getId());   // :230  container's location changes
unitload = unitloadRepository.save(unitload);                 // :231
...
unitloadRecordService.recordForTransferUnitLoad(...);         // :247  writes a UnitloadRecord ONLY
```

`processTransfer` **never** calls `StockrecordService`. Every `Stockrecord` in the codebase is written from `StockunitBusinessService`, keyed on a **stock-unit → unit-load** change (`recordTransferStockUnit` at `StockrecordService.java:259`, type `STOCK_TRANSFERRED`). A whole-UL relocation keeps the stock unit on the **same** unit load (`unitload_id` unchanged) — only the unit load's `storagelocation_id` changes — so there is no source/destination *unit-load* pair and none of the existing writers fire.

`StockRecordType` has no member for a location-only relocation (`WmsConstants.java:173-179`).

Two **in-scope** operator paths hit this gap:
- **Move Fixed Location** — `FixLocationAssignmentService.move()` calls `transferUnitLoadToLocation(..., CODE_MOVE_FIX_ASSIGNMENT, ...)` at `:161`.
- **Move Stock whole-UL branch** — `StockunitService.transferStock()` calls `transferUnitLoadToLocation(suUnitLoad, destinationLocation, false, CODE_MANUAL_TRANSFER, null, comment)` at `:185`, gated on `stockUnit.getAmount() == amountToTransfer && no FLA && stockUnitList.size()==1` (`:183`). Its sibling branches that move stock into a *different* container go through `transferStockToUnitLoad` and **do** log `STOCK_TRANSFERRED`.

A third operator path — mobile **Move Unitload** (`MobileMoveUnitloadService` :250/:378/:382, `CODE_TRANSFER`) — shares the gap but is **knowingly deferred** (§10-#6).

**Report-safety context (load-bearing for the design):** the inventory reports do **not** sum every `stockrecord` row. Both report functions use an explicit `(activitycode, type)` **allow-list**:
- `transaction_detail(...)` — `V1.1.08__wms_functions.sql:197-212` (WHERE-clause predicate list).
- `transaction_summary(...)` — `V1.1.04__wms_functions.sql:395-429` (per-bucket `CASE WHEN ... THEN sr.amount/amountstock`).

`STOCK_RELOCATED` matches **no** predicate in either function, so a relocation row is **excluded from every report total and produces no detail line** — regardless of its amount. This is the **primary** protection against a relocation corrupting inventory reports (see §9).

Full evidence: investigation report `sbdocs/3-Resources/reports/260624-stock-unit-history-gap-on-unitload-location-move.md` (F1–F6).

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `WmsConstants.java` | :168-179 | No `STOCK_RELOCATED` type |
| 2 | `StockrecordService.java` | :259-298 | Closest writer is UL→UL keyed; no relocation writer |
| 3 | `FixLocationAssignmentService.java` | :161 | `transferUnitLoadToLocation` writes UnitloadRecord only |
| 4 | `StockunitService.java` | :185 | whole-UL branch writes UnitloadRecord only |
| 5 | `UnitloadBusinessService.java` | :247 | only history write in `processTransfer` is `UnitloadRecord` |

---

## 3. The Regression Chain — NOT a Regression

**Pre-existing design gap, not a regression.** `git log -S "stockrecordService" -- .../service/UnitloadBusinessService.java` returns **no commits** — `UnitloadBusinessService` has *never* referenced `StockrecordService`. SBDEV-2481 added the pick-line guard (Hook A) adjacent to `:230` but added/altered **no** history logging (investigation F4, HIGH confidence). No regression chain.

---

## 4. Architecture Overview

```
OPERATOR ACTION                 MOVER                         HISTORY WRITES
───────────────                 ─────                         ──────────────
Move Fixed Location ─┐
(CODE_MOVE_FIX_      │
 ASSIGNMENT)         ├─► transferUnitLoadToLocation ─► processTransfer ─► UnitloadRecord   (existing)
                     │                                                  └─► [NEW] StockrecordService
Move Stock whole-UL ─┘                                                       .recordRelocation
(CODE_MANUAL_TRANSFER)                                                       → Stockrecord type=STOCK_RELOCATED
                                                                             (called from the CALLER,
                                                                              NOT inside processTransfer)

Mobile Move Unitload ───────────► transferUnitLoadToLocation ─► processTransfer ─► UnitloadRecord ONLY
(CODE_TRANSFER)                                                  (DEFERRED — §10-#6, not logged yet)

Move Stock split / to-different-UL ─► transferStockToUnitLoad ─► recordTransferStockUnit
(CODE_MANUAL_SPLIT)                                              → Stockrecord type=STOCK_TRANSFERRED  (unchanged)

Shipping / Putaway / BOL / TruckLoad whole-UL moves (system)
(CODE_SHIPPING etc.) ──────────────► transferUnitLoadToLocation ─► processTransfer ─► UnitloadRecord ONLY
                                                                    (NO Stockrecord — scope-guarded)

REPORTS: transaction_detail / transaction_summary use a (activitycode,type) ALLOW-LIST.
         STOCK_RELOCATED matches no predicate → excluded from all totals + no detail line.
```

### Key Files

| File | Role |
|------|------|
| `service/WmsConstants.java` | `StockRecordType` (+ `STOCK_RELOCATED`) |
| `service/StockrecordService.java` | All `Stockrecord` writers (+ `recordRelocation`) |
| `service/FixLocationAssignmentService.java` | Move Fixed Location entry (calls relocation logger) |
| `service/StockunitService.java` | Manual Move Stock whole-UL branch (calls relocation logger) |
| `service/UnitloadBusinessService.java` | Choke point — intentionally unchanged (scope guard) |
| `service/mobile/MobileMoveUnitloadService.java` | Mobile Move Unitload — deferred path (§10-#6) |
| `db/migration/V1.1.08__wms_functions.sql` | `transaction_detail` allow-list (:197-212) |
| `db/migration/V1.1.04__wms_functions.sql` | `transaction_summary` allow-list (:395-429) |
| `model/Stockrecord.java` | Record columns (from/to location + unit load + stock unit) |

---

## 5. Fix Design

**Why Option A (targeted), not Option B (systemic).** Option B logs inside `processTransfer`, which fires on **every** whole-UL move — shipping, putaway, truck-load, BOL bulk — flooding stock-unit history with non-operator noise and requiring `activityCode` discrimination. Option A writes only at the two named operator call sites, has low blast radius, and keeps `processTransfer` untouched. (Full trade-off: §9 + RALPLAN-DR.)

**Critical ordering invariant (both call sites):** the old `Location` must be **read/captured before** `transferUnitLoadToLocation`, because that call overwrites the unit load's `storagelocation_id` (`processTransfer:230`). In Move Fixed Location, the UL is additionally relabelled-and-saved at `:159-160` *before* the transfer at `:161`. Both callers already hold the old `Location` object before the move (`FixLocationAssignmentService.oldLocation` at `:101`; `StockunitService.ulLocation` at `:179`), so we pass it **explicitly** — guaranteeing `fromstoragelocation != tostoragelocation`. We do **not** derive the from-location from the (now-mutated, same) unit load. Asserted by AC-1/AC-2 and a unit test.

### Fix A — `WmsConstants.StockRecordType.STOCK_RELOCATED`

```java
// WmsConstants.java  StockRecordType
public static final String STOCK_RESERVED_CHANGED = "STOCK_RESERVED_CHANGED";
public static final String STOCK_RELOCATED = "STOCK_RELOCATED";   // NEW
```

### Fix B — `StockrecordService.recordRelocation(...)`

Model on `recordTransferStockUnit` (`:259-298`). The stock unit stays on the **same** unit load, so `fromunitload == tounitload` (the stock unit's own UL label, looked up via the already-injected `unitloadRepository`), while from/to **locations differ** (passed in explicitly).

**Signature:**
```java
public void recordRelocation(Stockunit stockunit, Location fromLocation, Location toLocation,
                             String activityCode, String orderNumber, String comment)
```

**Body:**
```java
// zero-amount guard, identical to recordTransferStockUnit (:260-263)
if (BigDecimal.ZERO.compareTo(stockunit.getAmount()) >= 0) {
    LOG.debug("Do not record zero amount relocation");
    return;
}
Stockrecord rec = new Stockrecord();
rec.setId(stockrecordRepository.getNextId());
rec.setOperator(SecurityContextUtils.getUserName());
rec.setAmount(stockunit.getAmount());                       // moved qty = whole stock unit (SBDEV-2488) — see note below
rec.setAmountstock(stockunit.getAmount());                  // current amount
rec.setClientId(stockunit.getClientId());

rec.setFromstockunitidentity(String.valueOf(stockunit.getId()));
rec.setTostockunitidentity(String.valueOf(stockunit.getId()));   // same stock unit

// same unit load before and after — look it up by the stock unit's (unchanged) unitloadId
Unitload unitload = unitloadRepository.findById(stockunit.getUnitloadId())
    .orElseThrow(() -> new NoSuchElementException("No value present"));
rec.setFromunitload(unitload.getLabelid());
rec.setTounitload(unitload.getLabelid());                   // fromunitload == tounitload

rec.setFromstoragelocation(fromLocation.getName());         // explicit old location (NOT NULL col)
rec.setTostoragelocation(toLocation.getName());             // explicit new location (NOT NULL col)

Itemdata itemdata = itemdataRepository.findById(stockunit.getItemdataId())
    .orElseThrow(() -> new NoSuchElementException("No value present"));
rec.setItemdata(itemdata.getItemNr());
rec.setScale(itemdata.getScale());

rec.setType(WmsConstants.StockRecordType.STOCK_RELOCATED);
rec.setActivitycode(activityCode);
rec.setOrdernumber(orderNumber);
rec.setAdditionalcontent(comment);

UnitloadType unitloadType = unitloadTypeRepository.findById(unitload.getTypeId())
    .orElseThrow(() -> new NoSuchElementException("No value present"));
rec.setUnitloadtype(unitloadType.getName());
rec.setEntityLock(0);

stockrecordRepository.save(rec);
```

**`amount` = the moved quantity (the whole stock unit's amount) — REVISED per SBDEV-2488.** The stock-unit-history UI maps its **"Moved"** column to `amount` and **"Remain"** to `amountstock` (`wms-web-ui/components/reports/stockUnitRecord.vue:184-196`). A whole-UL relocation moves the entire stock unit, so `amount == amountstock == stockunit.getAmount()` and "Moved" correctly shows the moved quantity (matching the other move-stock entries), instead of `0`. **Report-safety does NOT depend on this amount:** the **only** protection is the report functions' `(activitycode, type)` allow-list (`transaction_detail` V1.1.08:197-212; `transaction_summary` V1.1.04:395-429) — `(MOVE_FIX_ASSIGNMENT\|MANUAL_TRANSFER, STOCK_RELOCATED)` matches no predicate, so a relocation row is excluded from every total and produces no detail line **regardless of amount**. This is empirically locked by `StockRecordReportExclusionIT`, which seeds a **non-zero** relocation amount and asserts zero contribution. **Originally `amount` was zeroed as a defense-in-depth hedge against a future allow-list relaxation; that hedge produced a visible "Moved = 0" defect (Brent, SBDEV-2488 QA) and was dropped in favor of the correct operator-facing value.** Leave a code comment at the `setAmount(stockunit.getAmount())` line explaining the report-safety reasoning so a maintainer does not re-zero it.

**Exception style:** `recordRelocation` keeps `NoSuchElementException` on its lookups, matching `recordTransferStockUnit`. These are internal **post-move FK lookups of rows that must exist** (the stock unit's own UL, its itemdata, the UL type). A leaked `NoSuchElementException` → HTTP 500 via `RestExceptionHandler` is acceptable here: non-existence at this point is data corruption, not user input. Resolved (not open) — see §10-#5. All repos are already `@Autowired` in `StockrecordService` (`:21-37`) — **no new field** in this class.

### Fix C — `FixLocationAssignmentService.move()`

Inject `StockrecordService` (new `@Autowired` field). After the transfer at `:161`, loop `stockunitList` (`:145`):

**Before (`:159-163`):**
```java
unitload.setLabelid(destination.getName());
unitload = unitloadRepository.save(unitload);
unitloadBusinessService.transferUnitLoadToLocation(unitload, destination, false, WmsConstants.CODE_MOVE_FIX_ASSIGNMENT, null, null);
fixedLocationAssignment.setAssignedlocationId(destination.getId());
```

**After:**
```java
unitload.setLabelid(destination.getName());
unitload = unitloadRepository.save(unitload);
unitloadBusinessService.transferUnitLoadToLocation(unitload, destination, false, WmsConstants.CODE_MOVE_FIX_ASSIGNMENT, null, null);
for (Stockunit su : stockunitList) {                                    // oldLocation read at :101, BEFORE the relabel+transfer
    stockrecordService.recordRelocation(su, oldLocation, destination,
        WmsConstants.CODE_MOVE_FIX_ASSIGNMENT, null, null);
}
fixedLocationAssignment.setAssignedlocationId(destination.getId());
```

`oldLocation` (`:101`) is read before the UL relabel (`:159`) and the move (`:161`); `destination` (`:106`) is the target. The method **hard-throws** if `stockunitList.size() > 1` (`:148-150`), so in production the loop runs exactly once — the loop is **forward-looking / defensive**, not exercising a real multi-SU case (see §8).

### Fix D — `StockunitService.transferStock()` whole-UL branch

Inject `StockrecordService` (new `@Autowired` field). After `:185`:

**Before (`:184-187`):**
```java
unitloadBusinessService.transferUnitLoadToLocation(suUnitLoad, destinationLocation, false, WmsConstants.CODE_MANUAL_TRANSFER, null, comment);
// suUnitLoad may be updated by transferUnitLoadToLocation, get read the updated one
unitLoad = unitloadRepository.findById(suUnitLoad.getId()).orElse(null);
```

**After:**
```java
unitloadBusinessService.transferUnitLoadToLocation(suUnitLoad, destinationLocation, false, WmsConstants.CODE_MANUAL_TRANSFER, null, comment);
stockrecordService.recordRelocation(stockUnit, ulLocation, destinationLocation,   // ulLocation read at :179, BEFORE the move
    WmsConstants.CODE_MANUAL_TRANSFER, null, comment);
// suUnitLoad may be updated by transferUnitLoadToLocation, get read the updated one
unitLoad = unitloadRepository.findById(suUnitLoad.getId()).orElse(null);
```

`ulLocation` (`:179`) is captured before the move; `destinationLocation` (`:140`) is the target; the branch is gated on `stockUnitList.size()==1` (`:183`), so `stockUnit` is the single stock unit. This is the `CODE_MANUAL_TRANSFER` whole-UL branch **only** — the sibling `CODE_MANUAL_SPLIT` branches are untouched.

**Files changed:** `WmsConstants.java`, `StockrecordService.java`, `FixLocationAssignmentService.java`, `StockunitService.java`.

---

## 6. File Change Summary

| # | File | Change | Risk |
|---|------|--------|------|
| F-A | `service/WmsConstants.java` | Add `STOCK_RELOCATED` to `StockRecordType` | Trivial — additive constant |
| F-B | `service/StockrecordService.java` | Add `recordRelocation(...)` | Low — mirrors existing writer; no new fields |
| F-C | `service/FixLocationAssignmentService.java` | Inject `StockrecordService`; call after `:161` | Low — additive call inside existing `@Transactional` |
| F-D | `service/StockunitService.java` | Inject `StockrecordService`; call after `:185` (CODE_MANUAL_TRANSFER branch) | Low — additive call inside existing `@Transactional` |

No DDL, no migration, no API/payload change, no UI server-side change.

---

## 7. Implementation Steps

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **N/A** — no schema change. `STOCK_RELOCATED` is a new *value* in the existing free-text `stockrecord.type` column. No Flyway migration, no DDL. | — | Backward compatible by construction |
| 2 | **Feature flags / system properties** | **N/A** — no toggle; unconditional for the two operator paths. | — | |
| 3 | **Config / env changes** | **N/A** for production. For **local ITs only:** SDKMAN Java 8 + maven on PATH; `-DargLine="-Dapi.version=1.41"`. | — | Test-only |
| 4 | **Deploy-order dependencies** | **N/A** — self-contained wms-api change. | — | UI label rendering is a flag-not-block item (§10-#2) |
| 5 | **Data migration** | **N/A** — additive; no backfill of historical relocations. | — | |
| 6 | **External systems** | **N/A** — no OMS webhook / printer interaction added. | — | |
| 7 | **Access / permissions** | **N/A** — uses existing stock-unit-history read authority. | — | |
| 8 | **Monitoring / alerts** | **N/A** — no new metric required. | — | |
| 9 | **Test environment (ITs)** | DB migration **V1.26.30** (`ro_id`) present in the Testcontainers schema; `@MockBean OAuth2RestTemplate` to dodge startup Keycloak call; pre-existing surefire H2 failures (`ClientRepositoryH2Test`, `LocationRepositoryH2Test`) scoped around. The Testcontainers harness runs Flyway, so the **real** `transaction_detail`/`transaction_summary` functions exist for the report-exclusion IT (§6 / AC-8). | — | Per repo memory: "Run v1/wms-api Testcontainers ITs locally" |

### 5.2 Implementation Checklist (ordered, atomic)

- [ ] **Step 1 (F-A):** Add `STOCK_RELOCATED` to `WmsConstants.StockRecordType` (after `STOCK_RESERVED_CHANGED`, `:179`).
- [ ] **Step 2 (F-B):** Add `recordRelocation(...)` to `StockrecordService` (after `recordTransferStockUnit`, ~`:298`). Mirror the zero-amount guard; `amount=ZERO` (+ load-bearing comment), `amountstock=stockunit.getAmount()`, same from/to stockunitidentity, same from/to UL label, explicit from/to location names, `type=STOCK_RELOCATED`, `NoSuchElementException` on lookups. No new `@Autowired` field.
- [ ] **Step 3 (F-C):** In `FixLocationAssignmentService`, add `@Autowired private StockrecordService stockrecordService;`. After `:161`, loop `stockunitList` → `recordRelocation(su, oldLocation, destination, CODE_MOVE_FIX_ASSIGNMENT, null, null)`.
- [ ] **Step 4 (F-D):** In `StockunitService`, add `@Autowired private StockrecordService stockrecordService;`. After `:185` (CODE_MANUAL_TRANSFER branch) → `recordRelocation(stockUnit, ulLocation, destinationLocation, CODE_MANUAL_TRANSFER, null, comment)`.
- [ ] **Step 5:** Unit tests (StockrecordServiceUnitTest) — §6.
- [ ] **Step 6:** Testcontainers ITs (FixLocationAssignment + StockunitService + **report-exclusion**) — §6.
- [ ] **Step 7:** `mvn clean compile`, then targeted `mvn test -Dtest=...`, then `bash sbdocs/9-System/scripts/verify-260624-stock-unit-history-on-unitload-relocation.sh` — **0 FAIL** required.
- [ ] Code review completed.

**Transaction note:** `recordRelocation` runs inside the callers' existing transactions — `FixLocationAssignmentService.move` is `@Transactional(rollbackFor = Exception.class)` (`:94`); `StockunitService.transferStock` is `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` (`:106`). The `Stockrecord` write rolls back with the move on failure — no orphan history.

---

## 8. Test Plan

### Acceptance Criteria

| AC | Statement |
|----|-----------|
| AC-1 | Move Fixed Location → a `Stockrecord` with `type=STOCK_RELOCATED`, `fromstoragelocation`=old & `tostoragelocation`=dest (**both non-null**, and **from != to**), `from/tostockunitidentity`=su id, **`fromunitload == tounitload`** (same UL label), `activitycode=MOVE_FIX_ASSIGNMENT`. |
| AC-2 | Move Stock whole-UL branch → same shape, `activitycode=MANUAL_TRANSFER` (both locations non-null, from != to, fromunitload==tounitload). |
| AC-3 | Split / to-different-UL move (`transferStockToUnitLoad`) still logs `STOCK_TRANSFERRED`, and writes **no** `STOCK_RELOCATED` — no double-logging, no regression. |
| AC-4 | Scope guard: a **system** whole-UL move via `processTransfer` (e.g. CODE_SHIPPING) writes **no** `STOCK_RELOCATED`. |
| AC-5 | **(unit-level)** `recordRelocation` invoked in a loop over N stock units writes exactly N `STOCK_RELOCATED` rows, each with the correct per-su `from/tostockunitidentity`. *(Both production callers are single-SU; this asserts the writer's per-su behavior generically — not a multi-SU IT.)* |
| AC-6 | `amountstock <= 0` → `recordRelocation` writes nothing. |
| AC-7 | A `STOCK_RELOCATED` row has **`amount == stockunit.getAmount()`** and **`amountstock == stockunit.getAmount()`** (moved qty shows in the UI "Moved" column — SBDEV-2488; superseding the earlier `amount == ZERO` invariant). |
| AC-8 | A seeded `STOCK_RELOCATED` row in a date window **contributes 0 to all `transaction_summary` totals** and **produces no `transaction_detail` line** (report-exclusion, via the real Flyway-applied functions). |

### Unit tests — `StockrecordServiceUnitTest`

Mockito 3.3.3 — **no `mockStatic`**. For `SecurityContextUtils.getUserName()`, set `SecurityContextHolder` directly.

| Test method | What it asserts | AC |
|-------------|-----------------|-----|
| `recordRelocation_writesStockRelocatedWithCorrectFieldMapping` | Captured `Stockrecord`: `type=STOCK_RELOCATED`, from/to stockunitidentity=su.id, activitycode/ordernumber/additionalcontent pass-through, clientId, itemdata/scale, unitloadtype, entityLock=0 | AC-1/2 |
| `recordRelocation_amountZeroAmountstockEqualsStockunitAmount` | `amount == BigDecimal.ZERO` and `amountstock == stockunit.getAmount()` | AC-7 |
| `recordRelocation_fromAndToStorageLocationBothNonNullAndDiffer` | `fromstoragelocation`/`tostoragelocation` both non-null and `from != to` (proves explicit-location wiring) | AC-1/2 |
| `recordRelocation_sameUnitLoadLabelOnBothSides` | `fromunitload == tounitload` (single UL lookup by `stockunit.getUnitloadId()`) | AC-1/2 |
| `recordRelocation_zeroAmountSkipped` | `amountstock <= 0` → `stockrecordRepository.save` never called | AC-6 |
| `recordRelocation_loopOverNStockUnitsWritesNRowsWithPerSuIdentity` | Called N times over distinct stock units → N saves, each with its own `from/tostockunitidentity` | AC-5 |
| `recordRelocation_operatorFromSecurityContext` | `operator` = username on `SecurityContextHolder` | AC-1/2 |

### Integration tests — Testcontainers

| Test class | Test method | What it asserts | AC |
|------------|-------------|-----------------|-----|
| `FixLocationAssignmentServiceIT` | `move_writesSingleStockRelocatedRecord` | After `move(...)`, exactly one `Stockrecord` `type=STOCK_RELOCATED`, from=oldLoc, to=dest, from/to stockunitidentity=su.id, fromunitload==tounitload, activitycode=MOVE_FIX_ASSIGNMENT *(single-SU by construction)* | AC-1 |
| `StockunitServiceIT` | `transferStock_wholeUnitLoad_writesStockRelocatedRecord` | After whole-UL `transferStock`, one `STOCK_RELOCATED`, activitycode=MANUAL_TRANSFER, correct from/to | AC-2 |
| `StockunitServiceIT` | `transferStock_split_stillWritesStockTransferred_noRelocated` | Split branch writes `STOCK_TRANSFERRED` and **no** `STOCK_RELOCATED` | AC-3 |
| `StockRecordReportExclusionIT` (new) | `stockRelocated_excludedFromTransactionSummaryAndDetail` | Seed a `STOCK_RELOCATED` row in `[startdate, enddate]`; call `transaction_summary(...)` → all numeric totals unchanged/zero contribution from that row; call `transaction_detail(...)` → no line for that row. Uses the real Flyway-applied functions. | AC-8 |

### Regression

- Existing `STOCK_TRANSFERRED` assertions must stay green — `recordTransferStockUnit` is untouched.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Move Fixed Location logs relocation | staging | 1. FLA w/ 1 UL / 1 SU on a flowbin. 2. Move Fixed Location → empty flowbin. 3. Open SU stock-unit history. | New row `STOCK_RELOCATED`, from=old, to=dest, operator=me | |
| Move Stock whole-UL logs relocation | staging | 1. SU = whole UL, no FLA on dest, single SU. 2. Move Stock → new location (full amount). 3. Open SU history. | New row `STOCK_RELOCATED`, activity `MANUAL_TRANSFER`, comment carried | |
| Split still logs TRANSFERRED only | staging | Move Stock partial amount to a different container. | `STOCK_TRANSFERRED` row; **no** `STOCK_RELOCATED` | |
| System move writes no Stockrecord (scope guard) | staging | Shipping/putaway whole-UL move (CODE_SHIPPING etc.). | UnitloadRecord written; **no** `STOCK_RELOCATED` | |
| Report not skewed by relocation | staging DB | Run inventory transaction report over a window containing a relocation. | Totals unchanged; no relocation line in detail | |
| DB SQL sanity | staging DB | `psql: SELECT type, amount, amountstock, fromstoragelocation, tostoragelocation, fromunitload, tounitload, operator FROM stockrecord WHERE fromstockunitidentity = '<su id>' ORDER BY created DESC LIMIT 5;` | Top row `STOCK_RELOCATED`, `amount=0`, from≠to location, fromunitload=tounitload | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn clean compile` | | |
| `mvn test -Dtest=StockrecordServiceUnitTest` | | |
| `mvn verify -Dtest=FixLocationAssignmentServiceIT,StockunitServiceIT,StockRecordReportExclusionIT -DargLine="-Dapi.version=1.41"` | | |
| `bash sbdocs/9-System/scripts/verify-260624-stock-unit-history-on-unitload-relocation.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Multi-stock-unit UL **at the IT level** | Both production callers are single-SU by construction: `FixLocationAssignmentService.move` hard-throws on `stockunitList.size()>1` (`:148-150`); the `StockunitService` whole-UL branch is gated on `stockUnitList.size()==1` (`:183`). The per-su `recordRelocation` loop in `move` is forward-looking/defensive; its multiplicity is covered at the **unit** level (AC-5), not by an IT that cannot construct the case. |
| Mobile Move Unitload (`CODE_TRANSFER`) | Knowingly deferred (§10-#6); not in this plan's scope. |
| Backfill of historical relocations | Out of scope — additive going-forward only. |

---

## 9. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Relocation skews inventory reports** | Low | High | **PRIMARY:** the report functions use an explicit `(activitycode,type)` allow-list (`transaction_detail` V1.1.08:197-212; `transaction_summary` V1.1.04:395-429); `STOCK_RELOCATED` matches no predicate → excluded from all totals + no detail line, regardless of amount. Locked by AC-8 / `StockRecordReportExclusionIT`. **DEFENSE-IN-DEPTH:** `amount=ZERO` so a future allow-list relaxation or new amount-summing report still counts it as zero (load-bearing — comment in code). |
| **Double-logging** — a path both transfers stock-to-UL and relocates | Low | Medium | Relocation logger is placed ONLY in the two whole-UL operator branches, which do **not** call `transferStockToUnitLoad`. AC-3 asserts no overlap. |
| **UI renders unknown `STOCK_RELOCATED` label as blank/raw** | Medium | Low | Server change is additive; wms-web-ui / mobile-ui may show a raw/blank label until a UI map entry is added. §10-#2: flag, do not implement here. |
| **Scope creep into `processTransfer` (Option B)** | Low | High | Explicitly rejected. The verify-script **negative** check asserts `UnitloadBusinessService.processTransfer` does **not** reference `stockrecordService`/`recordRelocation` — catches an accidental Option-B migration without forbidding a future deliberate mobile-Move-Unitload addition. |
| **Old location captured after the move (from==to)** | Low | High | Both call sites read the old `Location` before `transferUnitLoadToLocation` (and before the FLA relabel at `:159`) and pass it explicitly; AC-1/AC-2 + `recordRelocation_fromAndToStorageLocationBothNonNullAndDiffer` assert from != to. |
| **Incomplete operator coverage (mobile Move Unitload)** | Medium | Low | **Knowingly deferred** (§10-#6). The "operator whole-UL relocations are logged" claim is qualified to the two named paths everywhere it appears. |
| **Leaked `NoSuchElementException` → HTTP 500** | Very low | Low | Lookups are of rows that must exist post-move; mirrors `recordTransferStockUnit`. Resolved (§10-#5). |

---

## 10. Open Questions / Resolved Decisions

1. **[RESOLVED]** Product intent — should operator whole-UL relocations appear in stock-unit history? **Yes** (confirmed by user). Scope = Move Fixed Location + Move Stock whole-UL only.
2. **[OPEN — flag, don't implement]** UI rendering — does `wms-web-ui` / `wms-mobile-ui` have a label map entry for `STOCK_RELOCATED`? If not, the new type may show raw/blank. UI follow-up.
3. **[OPEN — separate plan]** v2 parity — `v2/wms2-api` very likely has the identical split. Paired `wms-v2-migrate` plan (same base name) follows; not implemented here.
4. **[RESOLVED — verified]** Reporting impact — `transaction_detail`/`transaction_summary` exclude `STOCK_RELOCATED` by their `(activitycode,type)` allow-list (V1.1.08:197-212 / V1.1.04:395-429); `amount=ZERO` is defense-in-depth. Locked by AC-8.
5. **[RESOLVED]** Exception style — `recordRelocation` keeps `NoSuchElementException` for consistency with `recordTransferStockUnit`. Acceptable HTTP 500: these are internal post-move FK lookups of rows that must exist (data corruption, not user input). Not a divergent style; no change.
6. **[OPEN — KNOWINGLY DEFERRED]** Mobile **Move Unitload** (`MobileMoveUnitloadService` :250/:378/:382, `CODE_TRANSFER`) is a third operator whole-UL move that Option A does **not** cover. The tester named only Move Fixed Location + Move Stock, so it is out of this plan's scope. If product wants full operator coverage, add a `recordRelocation` call there in a follow-up — the verify-script intentionally does **not** forbid it.

---

## 11. Implementation Status

**Implemented 2026-06-24** on branch `fix/stock-unit-history-relocation` (off `develop`, which now includes the merged SBDEV-2481 PR #176 + V1.26.30 `ro_id` migration). Architect-verified (APPROVE, all ACs); deslop = no changes; code-reviewed (0 critical/high; 2 medium test tightenings applied). **Committed & PR'd:** commit `c46688e`, [PR #178](https://github.com/SiteBossInc/wms-api/pull/178) → `develop`.

**QA follow-up (2026-06-25, SBDEV-2488 — branch `fix/SBDEV-2488-relocation-moved-amount` off `develop`):** QA (Brent) signed off the relocation logging but flagged that the stock-unit-history **"Moved"** column showed `0` instead of the moved quantity (e.g. moved WINE750 9784 → "Remain" 9784 but "Moved" 0). Root cause: the UI maps "Moved"→`amount`, and `recordRelocation` set `amount = ZERO`. Fix: `recordRelocation` now sets `amount = stockunit.getAmount()` (whole-UL move → moved == remain). The earlier `amount = ZERO` defense-in-depth was confirmed unnecessary — report-exclusion is keyed solely on the `(activitycode, type)` allow-list (verified against `V1.1.08`/`V1.1.04` SQL), so a non-zero amount cannot skew reports. `StockRecordReportExclusionIT` was hardened to seed a **non-zero** relocation amount and still assert zero report contribution; the `recordRelocation_amountAndAmountstockEqualStockunitAmount` unit test and the verify-script `FBc` check were updated to match. Verified: `mvn clean compile` BUILD SUCCESS; `StockrecordServiceUnitTest` 20/0/0; `StockRecordReportExclusionIT` 1/0/0 (with non-zero seeded amount); verify-script static checks 10/10. PR: [#181](https://github.com/SiteBossInc/wms-api/pull/181) → `develop` (commit `b39b44d`).

**Code-review follow-up (2026-06-24, commit `8767fd3`, pushed to PR #178):** a re-review of the committed diff confirmed correctness, transactional rollback safety (both callers `@Transactional`), and test adequacy. Two LOW-severity nits in `StockrecordService.recordRelocation` were addressed: (1) null-guard `stockunit.getAmount()` in the zero-amount skip (null now treated as zero → skip, no NPE — defensive; `stockunit.amount` is `NOT NULL` at the schema level); (2) the three `orElseThrow` lookups now throw specific `"<Entity> not found: <id>"` messages (unitload / itemdata / unitloadType) instead of generic `"No value present"`, improving diagnostics on the 404 surfaced if data is missing mid-move. Verified: `mvn test -Dtest=StockrecordServiceUnitTest` → exit 0 (compile clean + all tests pass).

| Item | Status | Notes |
|------|--------|-------|
| F-A WmsConstants.STOCK_RELOCATED | ✅ done (uncommitted) | `WmsConstants.java:180` |
| F-B StockrecordService.recordRelocation | ✅ done (uncommitted) | `StockrecordService.java:300-342`; modeled on `recordTransferStockUnit`; `amount=ZERO` (load-bearing comment), same UL label both sides, explicit from/to locations, `NoSuchElementException` lookups; no new `@Autowired` field |
| F-C FixLocationAssignmentService | ✅ done (uncommitted) | injected `StockrecordService`; per-su `recordRelocation(su, oldLocation, destination, CODE_MOVE_FIX_ASSIGNMENT, …)` after the transfer; `oldLocation` captured pre-move |
| F-D StockunitService | ✅ done (uncommitted) | injected `StockrecordService`; `recordRelocation(stockUnit, ulLocation, destinationLocation, CODE_MANUAL_TRANSFER, …)` in the whole-UL branch only; `ulLocation` captured pre-move |
| Unit tests | ✅ StockrecordServiceUnitTest 20/0 (7 new) | field mapping, amount==ZERO, from!=to non-null, fromunitload==tounitload, zero-skip, per-su loop, operator from SecurityContextHolder |
| Testcontainers ITs | ✅ green | `FixLocationAssignmentServiceIT`, `StockunitServiceIT` (split still logs STOCK_TRANSFERRED, no STOCK_RELOCATED), `StockRecordReportExclusionIT` — **empirically confirmed** a STOCK_RELOCATED row yields no `transaction_detail` line and 0 in every `transaction_summary` bucket |
| Scope guard | ✅ | `UnitloadBusinessService.processTransfer` unchanged (Option B not implemented) — verify negative checks NG1/NG2 pass |
| verify-script | ✅ **Result: 14 pass, 0 fail, 0 skip** | `bash sbdocs/9-System/scripts/verify-260624-stock-unit-history-on-unitload-relocation.sh` |
| `mvn clean compile` | ✅ BUILD SUCCESS | no DI cycle |
| PR link | _pending (not committed)_ | |

**Deferred / follow-up (unchanged from plan):** mobile Move Unitload (§10-#6, `CODE_TRANSFER`) knowingly out of scope; v2 parity via `wms-v2-migrate`; UI label for `STOCK_RELOCATED` (§10-#2).

**Verify script:** `sbdocs/9-System/scripts/verify-260624-stock-unit-history-on-unitload-relocation.sh`
- **POSITIVE — constant:** `STOCK_RELOCATED` present in `WmsConstants.StockRecordType`.
- **POSITIVE — method:** `recordRelocation` defined in `StockrecordService`.
- **POSITIVE — FLA call:** `FixLocationAssignmentService` calls `recordRelocation` with `CODE_MOVE_FIX_ASSIGNMENT`.
- **POSITIVE — Move-Stock call:** `StockunitService` calls `recordRelocation` with `CODE_MANUAL_TRANSFER`.
- **NEGATIVE — scope guard (system moves):** `UnitloadBusinessService.processTransfer` does **not** reference `stockrecordService` / `recordRelocation` (catches an accidental Option-B migration). Does **not** assert anything about `CODE_TRANSFER` / `MobileMoveUnitloadService`, so a future deliberate mobile-Move-Unitload addition is not blocked.
