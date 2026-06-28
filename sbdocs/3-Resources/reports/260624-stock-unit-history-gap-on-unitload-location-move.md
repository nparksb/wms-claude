---
title: "Investigation: Stock-Unit History Not Logged on Unit-Load Location Move (Move Fixed Location)"
type: investigation-report
status: complete
version: v1
project:
  - wms-api-v1
area: "Stock history / Move Fixed Location / Move Stock"
trigger: "QA tester during SBDEV-2481 UAT: 'Move Fixed Location moves the product but does not log the move in stock unit history.'"
verdict: "Pre-existing design gap — NOT a regression. Confidence: HIGH."
recommendation: "Fix later (separate ticket) — confirm product intent first."
created: 2026-06-24
updated: 2026-06-24
db_verified: false
related:
  - "[[SBDEV-2481-stale-pick-line-realignment-on-stock-move]]"
  - "[[SBDEV-2481-stale-pick-line-move-qa-checklist]]"
tags:
  - report
  - stock-history
  - move-stock
  - audit
---

# Investigation: Stock-Unit History Not Logged on Unit-Load Location Move

**Target:** v1/wms-api (Java 8, Spring Boot 2.3.7, PostgreSQL)
**Trigger:** QA tester during SBDEV-2481 UAT — _"The ONLY issue I see, and it's likely it existed prior to this, is that when I use Move Fixed Location and the product is moved, it's not logging that move in the stock unit history."_
**Verdict:** Pre-existing design gap, **not** a regression (HIGH confidence).
**Recommendation:** Fix later, as a separate ticket, after confirming product intent.

---

## 1. Context & Trigger

A tester verifying [SBDEV-2481](https://app.clickup.com/t/9006034209/SBDEV-2481) (stale pick-line realignment on stock move) noticed that performing a **Move Fixed Location** physically relocates the product but leaves **no entry in the stock-unit history**. They correctly suspected it predates the SBDEV-2481 change. This report confirms the behavior, identifies the cause, determines whether SBDEV-2481 introduced it, and recommends whether/how to fix it.

WMS v1 keeps **two distinct movement histories**:
- **`UnitloadRecord`** (via `UnitloadRecordService`) — *container* movement history ("this unit load moved from location A to B").
- **`Stockrecord`** (via `StockrecordService`) — *stock-unit* events ("this stock unit's quantity / container changed"), surfaced in the UI as **stock unit history**.

The question is why a Move Fixed Location appears in the former but not the latter.

---

## 2. Questions

1. Does Move Fixed Location actually write **no** `Stockrecord`? Through which code path?
2. Why — is stock-unit history structurally tied to something a fixed-location move doesn't do?
3. Did **SBDEV-2481** introduce or worsen this?
4. Is any **other** move flow affected the same way (systemic vs one-off)?
5. If it should be fixed, what is the smallest correct change, and what does it cost?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence |
|---|-----------|--------------------|
| H1 | The fixed-location move path never calls `StockrecordService`; it only writes a `UnitloadRecord`. | HIGH |
| H2 | `Stockrecord` is, by design, only written when the stock unit's **unit load** (or amount/reservation) changes — a fixed-location move keeps the stock unit on the same unit load and only changes that unit load's **location**, so no `Stockrecord` event is defined. | HIGH |
| H3 | SBDEV-2481 introduced/worsened this. | LOW (expected to be refuted) |
| H4 | **Nothing is actually wrong** — the move *is* logged (in unit-load history), and stock-unit history is intentionally not a container-relocation log. | MEDIUM |
| H5 | The gap is systemic: other whole-unit-load relocation flows (e.g. Move Stock's "move the whole container" branch) share it. | MEDIUM |

---

## 4. Method

Primary evidence = code read of the move call chain + `git log -S` archaeology. No DB query was required to answer the question (the absence of a `Stockrecord` write is provable from code); `db_verified: false` is therefore acceptable here — a DBA can confirm empirically by checking `stockrecord` for a known fixed-location move (see §9).

Sources consulted: `FixLocationAssignmentService`, `UnitloadBusinessService` (`processTransfer`), `StockunitBusinessService`, `StockrecordService`, `UnitloadRecordService`, `StockunitService`, `WmsConstants.StockRecordType`, and the `Stockrecord` model.

---

## 3.5 Sources In Scope

| Source | Role in this investigation |
|--------|---------------------------|
| `service/FixLocationAssignmentService.java:96-161` | Move Fixed Location entry; calls `transferUnitLoadToLocation` |
| `service/UnitloadBusinessService.java:227-257` (`processTransfer`) | The choke point that relocates the UL; writes `UnitloadRecord` only |
| `service/UnitloadBusinessService.java:247` | `unitloadRecordService.recordForTransferUnitLoad(...)` — the only history write here |
| `service/StockrecordService.java:50-330` | All `Stockrecord` writers (`recordCreation/Change/ChangeReservedAmount/Removal/TransferStockUnit`) |
| `service/StockunitBusinessService.java:253,273,274,330,349,397` | The **only** callers of `StockrecordService` |
| `service/StockunitService.java:107-226` (`transferStock`) | Manual Move Stock; two branches with different logging |
| `service/WmsConstants.java` `StockRecordType` | Available stock-record types (no relocation type) |
| `model/Stockrecord.java:32-82` | `Stockrecord` columns (from/to location + unitload + stockunit) |

---

## 5. Evidence

### F1 — Move Fixed Location routes through `transferUnitLoadToLocation`, which writes only a `UnitloadRecord` (supports H1, H2)

`FixLocationAssignmentService.move()` relocates the assigned virtual container by calling the unit-load mover:

```java
// FixLocationAssignmentService.java (~:159-161)
unitload.setLabelid(destination.getName());
unitload = unitloadRepository.save(unitload);
unitloadBusinessService.transferUnitLoadToLocation(unitload, destination, false,
    WmsConstants.CODE_MOVE_FIX_ASSIGNMENT, null, null);
```

`transferUnitLoadToLocation` → `processTransfer`:

```java
// UnitloadBusinessService.processTransfer (:230-247)
unitload.setStoragelocationId(destinationLocation.getId());   // :230  container's location changes
unitload = unitloadRepository.save(unitload);                 // :231
...
unitloadRecordService.recordForTransferUnitLoad(...);         // :247  writes a UnitloadRecord ONLY
```

`processTransfer` writes a **`UnitloadRecord`** and **never** calls `StockrecordService`. So the move is logged — but against the *container*, not the *stock unit*. (Finding; the picker's stock-unit history is a separate table.)

### F2 — `Stockrecord` is only ever written by `StockunitBusinessService`, keyed on a stock-unit→unit-load change (supports H2)

Every `Stockrecord` write in the codebase originates in `StockunitBusinessService`:

| Caller | Method | Stock-record type |
|--------|--------|-------------------|
| `transferStockToUnitLoad:253` | `recordTransferStockUnit` | `STOCK_TRANSFERRED` |
| `transferStockToUnitLoad:273/274` (partial) | `recordRemoval` + `recordCreation` | `STOCK_REMOVED` / `STOCK_CREATED` |
| `sendStockUnitToNirvana:330` | `recordTransferStockUnit` | `STOCK_TRANSFERRED` |
| `changeAmount:349` | `recordChange` | `STOCK_ALTERED` |
| `changeReservedAmount:397` | `recordChangeReservedAmount` | `STOCK_RESERVED_CHANGED` |

`recordTransferStockUnit` is keyed on the stock unit moving **between unit loads** and derives from/to location from each *unit load's* `storagelocationId`:

```java
// StockrecordService.recordTransferStockUnit (:259-...)
rec.setFromunitload(sourceUnitload.getLabelid());
rec.setFromstoragelocation(<source unitload's location>.getName());
rec.setTounitload(destinationUnitload.getLabelid());
rec.setTostoragelocation(<destination unitload's location>.getName());
rec.setType(WmsConstants.StockRecordType.STOCK_TRANSFERRED);
```

A fixed-location move keeps the stock unit on the **same** unit load (`unitload_id` unchanged) and only changes that unit load's `storagelocation_id`. There is no source/destination *unit load* pair, so none of the `Stockrecord` writers fire. (Inference from F1+F2: the data model defines a `Stockrecord` as a stock-unit event, and a container relocation is not one.)

### F3 — `StockRecordType` has no "relocated / location-changed" member (supports H2, informs §8)

```
WmsConstants.StockRecordType: STOCK_CREATED, STOCK_SPLITTED, STOCK_ALTERED,
STOCK_REMOVED, STOCK_TRANSFERRED, STOCK_COUNTED, STOCK_RESERVED_CHANGED
```

There is no `STOCK_RELOCATED`/`STOCK_MOVED_LOCATION`. The closest, `STOCK_TRANSFERRED`, semantically means "moved to a different unit load." So even conceptually the model has no first-class "the container holding this stock moved" stock-unit event. (Finding.)

### F4 — SBDEV-2481 did NOT introduce this (refutes H3)

`git log -S "stockrecordService" -- .../service/UnitloadBusinessService.java` returns **no commits** — `UnitloadBusinessService` has *never* referenced `StockrecordService`. The SBDEV-2481 change added the pick-line guard (Hook A) immediately after the `setStoragelocationId` write at `:230`, adjacent to the `UnitloadRecord` call at `:247`, but did not add or alter any history logging. (Finding — strong: the absence is in the file's entire git history.)

### F5 — The gap is systemic: Move Stock's "move whole unit load" branch shares it (supports H5)

`StockunitService.transferStock` (manual **Move Stock**) has two kinds of branch:

```java
// StockunitService.transferStock
//   moving stock into a DIFFERENT container (split / transfer):
stockunitBusinessService.transferStockToUnitLoad(stockUnit, unitLoad, amount,
    WmsConstants.CODE_MANUAL_SPLIT, ...);                              // :132/:174/:208  -> WRITES a Stockrecord
//   moving the WHOLE unit load to a new location:
unitloadBusinessService.transferUnitLoadToLocation(suUnitLoad, destinationLocation,
    false, WmsConstants.CODE_MANUAL_TRANSFER, null, comment);          // :185            -> UnitloadRecord ONLY
```

So the same asymmetry exists inside Move Stock: a split/partial move logs stock-unit history, but moving the entire container does not. The gap is **not specific to Move Fixed Location** — it is inherent to **`transferUnitLoadToLocation`** (every whole-container relocation). (Finding — raises the blast radius and argues for a systemic fix if a fix is wanted.)

### F6 — Null result: no other writer compensates (supports H1/H4)

Looked for any `Stockrecord` write triggered indirectly by `transferUnitLoadToLocation` (e.g., a post-commit listener, a scheduled reconciler, an `@EventListener`). Found none — the only consumers of the move are `UnitloadRecordService` (history) and the SBDEV-2481 pick-line hook. (Null result documented as a finding: nothing downstream backfills stock-unit history for container moves.)

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Note |
|---|-----------|------------------|------|
| H1 | Fixed-location move writes only `UnitloadRecord`, never `Stockrecord` | **CONFIRMED (HIGH)** | F1 |
| H2 | By design, `Stockrecord` is a stock-unit (container/amount) event; a location-only container move isn't one | **CONFIRMED (HIGH)** | F2, F3 |
| H3 | SBDEV-2481 caused it | **REFUTED (HIGH)** | F4 — never logged here in git history |
| H4 | "Nothing is wrong" — the move IS logged (unit-load history); stock-unit history is intentionally not a container-relocation log | **PARTIALLY TRUE** | The move is logged in `UnitloadRecord`; whether stock-unit history *should* also show it is a product decision, not a code defect |
| H5 | Systemic across whole-UL relocations | **CONFIRMED (MEDIUM-HIGH)** | F5 — Move Stock's whole-UL branch shares it |

---

## 7. Verdict

**Confidence: HIGH.** The behavior is real, understood, and **pre-existing — not a regression from SBDEV-2481.**

A **Move Fixed Location** (and the manual Move-Stock "move whole unit load" branch) relocates the *unit load*, which is recorded in **unit-load history (`UnitloadRecord`)** but not in **stock-unit history (`Stockrecord`)**. This follows directly from the v1 data model: a `Stockrecord` is defined as a stock-unit-level event (the stock unit changes unit load, amount, or reservation), and a container relocation changes neither the stock unit's `unitload_id` nor its amount — only the unit load's `storagelocation_id`. There is not even a `StockRecordType` for a location-only relocation.

So this is best characterised as a **design gap / audit-coverage limitation**, not a bug: the event is captured (in the container log), just not in the log the tester was looking at. Whether stock-unit history *ought* to surface container relocations is a product/audit decision.

---

## 8. Recommendation

**Fix later — pending product confirmation.** (Not "do not fix": the tester's expectation — that a physical product move shows in stock-unit history — is reasonable for audit/traceability, and the same gap affects Move Stock.) This report does **not** implement a fix.

Decision needed from product first: _should a whole-unit-load relocation appear in stock-unit history?_ If yes, two implementation options:

| Option | Scope | Pros | Cons |
|--------|-------|------|------|
| **A — Targeted** | In `FixLocationAssignmentService.move()` (and the Move-Stock `:185` branch), capture the old location **before** the transfer, then write a `Stockrecord` via a new `StockrecordService.recordRelocation(stockunit, oldLocation, newLocation, activityCode, …)` + new `WmsConstants.StockRecordType.STOCK_RELOCATED`. | Low blast radius; explicit; no change to other UL-move callers | Touches each relocation caller individually; can still be forgotten by a future caller |
| **B — Systemic** | In `UnitloadBusinessService.processTransfer`, after the `UnitloadRecord`, also write a `Stockrecord` (new `STOCK_RELOCATED` type) for each stock unit on the moved UL. | One place covers every whole-UL relocation present and future (consistent with the SBDEV-2481 Hook-A choke-point reasoning) | Materially increases `Stockrecord` volume on **every** UL move (shipping, putaway, truck-load, BOL bulk); needs `activityCode` discrimination (likely reuse the SBDEV-2481 `PickLineActivityCodeClassifier`-style bucketing or an explicit allow-list) and product sign-off on which moves are audit-relevant |

**Recommended:** start with **Option A** scoped to Move Fixed Location + the Move-Stock whole-UL branch (the two operator-initiated relocations the tester cares about), and explicitly decide whether to generalise to Option B later. A `STOCK_RELOCATED` type (or reuse of `STOCK_TRANSFERRED` with equal from/to unit load and differing from/to location) must be agreed.

**Downstream handoff:** draft via `wms-bugfix-plan` (treat as a small enhancement) for v1; the resulting plan **must ship a `sbdocs/9-System/scripts/verify-<plan-id>.sh`** per that skill. Expect a paired `wms-v2-migrate` follow-up — v2's `UnitloadBusinessService` very likely has the identical split (verify during the port).

---

## 9. Open Questions

1. **Product intent** — should stock-unit history include whole-unit-load relocations at all? (Blocks the fix decision.)
2. **DB confirmation (empirical)** — `db_verified: false` here; a DBA should confirm by performing one Move Fixed Location and checking `SELECT * FROM stockrecord WHERE fromstockunitidentity = '<su id>' ORDER BY created DESC` shows no new row while `unitload_record` does. (Code is unambiguous, but a live check closes it.)
3. **v2 parity** — does `v2/wms2-api` have the same `transferUnitLoadToLocation`-only-writes-`UnitloadRecord` split? (Almost certainly; confirm before porting.)
4. **Scope of "relocation" audit** — if Option B is chosen, which `activityCode`s are audit-relevant (operator moves) vs noise (inbound putaway, outbound shipping, BOL bulk)? Reuse SBDEV-2481's classifier pattern?
5. **Reporting impact** — does the `transaction_detail(...)` report (referenced in `Stockrecord.java`) already cover container relocations from `unitload_record`, making a `Stockrecord` redundant for some report consumers?

---

## 10. References

- Plan — [[SBDEV-2481-stale-pick-line-realignment-on-stock-move]] (`sbdocs/1-Projects/wms1/plan/`) — the UAT context; its Hook A sits adjacent to the unlogged path.
- QA checklist — [[SBDEV-2481-stale-pick-line-move-qa-checklist]] (`sbdocs/2-Areas/runbooks/`).
- Code: `UnitloadBusinessService.java:227-257`, `StockrecordService.java:50-330`, `StockunitBusinessService.java:253-397`, `StockunitService.java:107-226`, `FixLocationAssignmentService.java:96-161`, `WmsConstants.java` `StockRecordType`, `model/Stockrecord.java`.
- Workflow docs: `sbdocs/3-Resources/workflows/wms1-move-stock-unitload-workflow.md` (container vs stock-unit move semantics).
