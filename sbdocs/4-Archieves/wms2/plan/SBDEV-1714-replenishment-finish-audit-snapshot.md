---
title: "SBDEV-1714 — Replenishment finish audit snapshot (frozen moved-qty & source UL)"
ticket: "SBDEV-1714"
ticket_url: "https://app.clickup.com/t/SBDEV-1714"
type: bugfix
priority: medium
status: archived
project: [wms2]
system: wms2
version: "v2"
requester: ""
created: "2026-07-20"
updated: "2026-07-20"
status_note: "implemented 2026-07-20 — wms2-api PR #83 into develop"
db_verified: true
related:
  - "sbdocs/3-Resources/design/wms2-replenishment-design.md"
  - "sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md"
  - "sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md"
tags:
  - plan
  - replenishment
  - audit
---

# SBDEV-1714 — Replenishment finish audit snapshot (frozen moved-qty & source UL)

**Ticket:** [SBDEV-1714](https://app.clickup.com/t/SBDEV-1714)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** medium
**Status:** implemented (2026-07-20) — wms2-api PR [#83](https://github.com/SiteBossInc/wms2-api/pull/83) into `develop`
**Date:** 2026-07-20

> **Scope note:** This plan targets **v2/wms2-api ONLY**. The ticket was originally filed against v1/wms-api; the user has scoped this work to v2. A v1 counterpart is a candidate future paired plan — see §4 and §10. Do **not** implement v1 here.

---

## 0. Affected Sites

Every in-scope row is visited in §3. Line numbers are as of reads on branch `feature/fresh-v2-db-base-refresh-and-provisioning`, 2026-07-20.

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `service/mobile/MobileReplenishService.java` finish path (`finishReplenishmentOrderInternal` @ :428, save @ :502) | `setState(FINISHED)` + `save`, no snapshot of what moved | yes | **yes** — capture snapshot values **before** the stock mutation, set on entity, persist via the existing save (single choke point covers every finish path) |
| 2 | `model/Replenishorder.java` | entity has no snapshot columns | yes | **yes** — add 4 nullable fields + getters/setters |
| 3 | `repo/jpa/ReplenishorderRepository.java:519` `findDetailMapById` | `su.amount as stockUnitAmount` read live | yes | **yes** — select the 4 frozen `moved_*` columns |
| 4 | `service/ReplenishorderService.java:328-374` `getReplenishorderDetails` | maps the detail payload | yes | **yes** — surface new keys, additive & NULL-safe |
| 5 | `repo/jpa/ReplenishorderRepository.java:389` `getDetailViewByKeyword` (**no** state filter — returns closed rows) | `u.labelid as unitload` (live) | yes | **yes** — `COALESCE` frozen source-UL label |
| 6 | `repo/jpa/ReplenishorderRepository.java:417` `getOpenViewByKeyword` (`r.state < :state`) | `u.labelid as unitload` (live) | — | **NO** — returns open orders only; the live join is always correct here (§3.5) |
| 7 | `repo/jpa/ReplenishorderRepository.java:447` `getClosedViewByKeyword` (`r.state >= :state`) | `u.labelid as unitload` (live) | yes | **yes** — `COALESCE` frozen source-UL label |
| 8 | `repo/projection/ReplenishOrderDetailView.java` | projection interface | — | **NO** — Fix E `COALESCE`s into the **existing** `unitload` alias, so no new projection getter is needed (§3.5) |
| 9 | `service/ReplenishorderService.cancelReplenishmentOrder` (state→800) | no stock is moved on cancel | no | **NO** — nothing was moved, nothing to snapshot |
| 10 | `ReplenishmentMonitorViewRepository` (`su.amount`) | live on-hand monitor, not a closed-record audit | no | **NO** — different purpose (real-time on-hand, must stay live) |

**Layer-2 completeness note:** verification of each list query's `WHERE` clause reclassified row 6 (`getOpenViewByKeyword`) as out-of-scope — it only returns rows with `state < FINISHED`, whose source stockunit is still reserved/on-pallet, so the live `u.labelid` join is correct. Only the two queries that can return `state >= FINISHED` rows (rows 5 and 7) drift.

---

## 1. Problem Statement

**User-visible symptom (WMS web — Replenishment detail & closed-list views):**
For a *finished* replenishment order, the "Source Unit Load" shows the WineCo void/holding pallet label **`Nirwana`** and the stock-unit amount shows **`0`**, instead of the pallet and quantity actually moved. Finished replenishment records are therefore useless as an audit trail.

**DB evidence (db_verified: true — `wms2-wineco-dev`, 2026-07-20):**

```sql
SELECT COUNT(*)                                              AS finished_total,
       COUNT(*) FILTER (WHERE su.amount = 0)                 AS drained,
       COUNT(*) FILTER (WHERE ul.labelid = 'Nirwana')        AS nirwana,
       COUNT(*) FILTER (WHERE su.amount = 0
                          AND ul.labelid = 'Nirwana')        AS both
FROM replenishorder r
LEFT JOIN stockunit su ON su.id = r.stockunit_id
LEFT JOIN unitload  ul ON ul.id = su.unitload_id
WHERE r.state = 700;
-- → finished_total=168 | drained=164 | nirwana=164 | both=164
```

Of 168 FINISHED (`state=700`) rows, **164** show source `su.amount = 0` **and** source UL label `Nirwana`. Sample: `REPL389497` — `requestedamount=12`, live `su.amount=0`, `source_ul_label='Nirwana'`, `sourcelocationname='18-XD02'`. The **4 clean** rows (e.g. `REPL389490`: `su.amount=10`, UL `UL273331`) are orders whose source pallet still happened to hold stock at query time — the bug looks intermittent but is not. Mirrors the v1 ClickUp report exactly (v1 `REPL052269`: Source/UL = `55-XH01`/`Nirwana`, Requested Amount = 6, Stock Unit Amount = 0).

**Reproduction:**
1. Create/execute a replenishment order; finish it (moves qty from a source pallet to the fix-location pallet).
2. The source stockunit is drained by the move itself (full move re-homes it to the destination UL; partial-to-zero sends it to the `Nirwana` holding UL).
3. Open the finished order's detail (or the "closed" list) → Source UL reads `Nirwana`, Stock Unit Amount reads `0`.

---

## 2. Root Cause Analysis

A closed `Replenishorder` **never snapshots what was moved.** It retains only a **live FK to the SOURCE stockunit** (`r.stockunit_id`) plus **creation-time fields** (`requestedamount`, `sourcelocationname`). `finishReplenishmentOrderInternal` (`MobileReplenishService.java:428`) performs the physical move and then only:

```java
// MobileReplenishService.java:501-502
replenishOrder.setState(WmsConstants.State.FINISHED);
replenishorderRepository.save(replenishOrder);
```

Every read then re-derives "source UL" and "amount" by joining `r.stockunit_id` **live**:
- `findDetailMapById` (:527) `LEFT JOIN stockunit su ON su.id = r.stockunit_id`, exposes `su.amount as stockUnitAmount` (:519).
- `getDetailViewByKeyword` / `getClosedViewByKeyword` (:401/:459) join `unitload u on s.unitload_id = u.id`, expose `u.labelid as unitload` (:389/:447).

**Why the source pointer drifts — the transfer mutates the source in place (LOAD-BEARING for Fix C).**
`transferStockToUnitLoad` (`StockunitBusinessService`) mutates the **same JVM `sourceStock` object's** `unitloadId`:
- **Full move:** `sourceStockunit.setUnitloadId(destinationUnitload.getId())` (`StockunitBusinessService:346`) — the source stockunit is re-homed onto the **destination** UL.
- **Partial-drain-to-zero:** `sendStockUnitToNirvana(sourceStockunit, ...)` (`:380`) → `stockUnit.setUnitloadId(nirvanaUnitload.getId())` (`:422`) — the emptied source is sent to the **`Nirwana`** holding UL.

Therefore reading `sourceStock.getUnitloadId()` **after** the transfer (`:498`) yields the destination or `Nirwana` label — reproducing the exact bug. The correct source-UL label exists only **before** `:498`.

Field-by-field:
- **`su.amount`** — drifts to 0 (source pallet current on-hand, not moved qty).
- **`u.labelid`** — drifts to destination or `Nirwana` (source stockunit re-homed).
- **`r.sourcelocationname`** — STABLE creation snapshot; the "Source" location column stays correct.
- **`r.requestedamount`** — stable but WRONG on partial picks (requested, not moved). New `moved_amount` fixes this.

**The moved values are all in scope at the finish site**, but at different points:
- `amountPicked` (`BigDecimal`, :492-495) — actual moved qty; a non-mutated local.
- `sourceStock` (`Stockunit`) — its `getUnitloadId()` is correct **only before :470/:498**.
- `assignedUnitLoad` (`Unitload`, resolved :497) — the destination pallet; **not** re-homed by the transfer, so safe to read after.
- `destinationLocation` (`Location`, resolved by :467).

**Single choke point:** `finishReplenishmentOrderInternal` (:428) is the *only* finish path — called by `finishReplenishmentOrder` (:420, single) and `finishReplenishmentOrderWithoutRefill` (:424), the latter driven by the multi-order path `fulfillMultipleUnitLoads` (:810, :827). One snapshot write covers **every finish path** (see §3.3 for the precise multi-source caveat).

### Affected Locations

See §0. In-scope: rows 1, 2, 3, 4, 5, 7.

---

## 3. Design / Proposed Fix

**Strategy:** freeze what was moved onto the `replenishorder` row **at finish time** in new **nullable columns**, capturing the source-UL label **before** the stock mutation, then prefer those frozen values on read (falling back to the live join for old rows and open orders). **Forward-only** — §10.

New columns on `replenishorder` (all NULLABLE, additive):

| Column | Type | Source at finish (capture point) |
|--------|------|----------------------------------|
| `moved_amount` | `NUMERIC(17,4)` | `amountPicked` (:492-495), captured pre-transfer |
| `moved_source_unitload_label` | `VARCHAR(255)` | source UL label via `sourceStock.getUnitloadId()` → `Unitload.getLabelid()`, **captured pre-transfer (:498)** |
| `moved_destination_unitload_label` | `VARCHAR(255)` | `assignedUnitLoad.getLabelid()` (safe after transfer) |
| `moved_destination_location_name` | `VARCHAR(255)` | `destinationLocation.getName()` |

**`moved_source_location_name` deliberately NOT added** — `r.sourcelocationname` is already a stable creation-time snapshot (§10 #4).

### 3.1 Fix A — Schema (Flyway V2.2.03)

**Problem:** the table has nowhere to store frozen values.

**Solution:** new `db/migration/V2.2.03__replenishorder_finish_audit_snapshot.sql`:

```sql
-- V2.2.03__replenishorder_finish_audit_snapshot.sql
-- SBDEV-1714: freeze moved qty + source/destination labels on replenishment finish.
-- Forward-only. Existing FINISHED rows keep these columns NULL (source data gone; see plan §10).
ALTER TABLE replenishorder ADD COLUMN moved_amount                     NUMERIC(17,4);
ALTER TABLE replenishorder ADD COLUMN moved_source_unitload_label      VARCHAR(255);
ALTER TABLE replenishorder ADD COLUMN moved_destination_unitload_label VARCHAR(255);
ALTER TABLE replenishorder ADD COLUMN moved_destination_location_name  VARCHAR(255);
```

- Next free version = **V2.2.03** (highest existing is `V2.2.02`; base dump `V2.2.00`). Never edit an applied migration.
- All nullable → additive; app boots under `ddl-auto=validate`. **No backfill** (§10).

**Files changed:** `src/main/resources/db/migration/V2.2.03__replenishorder_finish_audit_snapshot.sql` (new).

### 3.2 Fix B — Entity (`Replenishorder.java`)

**Problem:** the entity lacks the fields; `validate` needs them mapped.

**Solution:** 4 fields + getters/setters, jakarta `@Column(name=...)`, no `@NotNull`:

```java
@Column(name = "moved_amount", columnDefinition = "numeric(17,4)")
private BigDecimal movedAmount;
@Column(name = "moved_source_unitload_label")
private String movedSourceUnitloadLabel;
@Column(name = "moved_destination_unitload_label")
private String movedDestinationUnitloadLabel;
@Column(name = "moved_destination_location_name")
private String movedDestinationLocationName;
// + standard getters/setters (match existing entity style)
```

**Files changed:** `model/Replenishorder.java`.

### 3.3 Fix C — Capture the snapshot BEFORE the stock mutation (`finishReplenishmentOrderInternal`)

**Problem:** the source stockunit's `unitloadId` is mutated in place by `transferStockToUnitLoad` (:498) — full move → destination UL (`StockunitBusinessService:346`), partial-to-zero → `Nirwana` (`:380/:422`). **Any read of the source UL label after :498 reproduces the bug.** The naive "set fields just before :501" is therefore WRONG.

**Solution:** split the capture. Resolve the SOURCE-UL label (and the moved amount) into **locals early** — after the final `sourceStock` is resolved (:453-459; note the explicit-`sourceStockId` path at :434-441 wins, so capture from the FINAL `sourceStock`) and after `destinationLocation` is resolved (:461-467), and **before** `changeReservedAmount` (:470) and `transferStockToUnitLoad` (:498). Destination captures (`assignedUnitLoad.getLabelid()`) are safe after the transfer (`assignedUnitLoad` is not re-homed) but are set alongside the rest just before the existing save.

**Before** (`:492-502`):

```java
BigDecimal amountPicked = mobileOrder.getAmountPicked();        // :492
if (amountPicked == null) {
    amountPicked = sourceStock.getAmount();                     // :494
}
final Long fixLocAssignedUnitloadId = fixLocationAssignment.getAssignedunitloadId();
Unitload assignedUnitLoad = unitloadRepository.findById(fixLocAssignedUnitloadId)
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad", fixLocAssignedUnitloadId));   // :497
stockunitBusinessService.transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked,
        WmsConstants.CODE_REPLENISHMENT, replenishOrder.getNumber(), null, false, true);          // :498

replenishOrder.setState(WmsConstants.State.FINISHED);           // :501
replenishorderRepository.save(replenishOrder);                  // :502
```

**After** — new early capture block inserted right after `destinationLocation` is confirmed (after :467, before the :469 branch); reuse the captured `amountPicked` at :498; set all four fields just before :501:

```java
// --- SBDEV-1714 [CAPTURE BEFORE MUTATION]: transferStockToUnitLoad(:498) re-homes
//     sourceStock.unitloadId in place (→ destination on full move, → Nirwana on
//     partial-to-zero). The source UL label MUST be read here, pre-transfer. ---
BigDecimal amountPicked = mobileOrder.getAmountPicked();
if (amountPicked == null) {
    amountPicked = sourceStock.getAmount();                     // pre-transfer source amount
}
String movedSourceUnitloadLabel = null;
final Long sourceUnitloadId = sourceStock.getUnitloadId();      // MUST be read pre-transfer
if (sourceUnitloadId != null) {
    movedSourceUnitloadLabel = unitloadRepository.findById(sourceUnitloadId)
            .map(Unitload::getLabelid).orElse(null);            // null-guarded
}
final String movedDestinationLocationName = destinationLocation.getName();
// --- end capture ---

// ... existing :469-490 reservation + fix-location-assignment logic unchanged ...

final Long fixLocAssignedUnitloadId = fixLocationAssignment.getAssignedunitloadId();
Unitload assignedUnitLoad = unitloadRepository.findById(fixLocAssignedUnitloadId)
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad", fixLocAssignedUnitloadId));
stockunitBusinessService.transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked,
        WmsConstants.CODE_REPLENISHMENT, replenishOrder.getNumber(), null, false, true);   // :498 (mutates sourceStock)

// destination UL label is SAFE to read after the transfer (assignedUnitLoad not re-homed)
replenishOrder.setMovedAmount(amountPicked);
replenishOrder.setMovedSourceUnitloadLabel(movedSourceUnitloadLabel);        // captured pre-transfer
replenishOrder.setMovedDestinationUnitloadLabel(assignedUnitLoad.getLabelid());
replenishOrder.setMovedDestinationLocationName(movedDestinationLocationName);

replenishOrder.setState(WmsConstants.State.FINISHED);           // :501 (unchanged)
replenishorderRepository.save(replenishOrder);                  // :502 (unchanged — one save)
```

- No new dependency — `unitloadRepository` is already constructor-injected (used at :497). **Confirm during implementation.**
- Reuses the single existing `save` at :502 — no extra DB round-trip.
- `amountPicked` is computed early and reused at :498 so the moved-qty snapshot cannot diverge from the transferred amount, and a future reorder cannot pull the source-label read past the mutation.

**Multi-source / multi-path precision (Change 5):** this ONE write executes on **every finish path** — the single-order path and each `fulfillMultipleUnitLoads` sub-order (:810, :827). It is **not** multi-source aggregation: the finish path can release *reservation* from a second stockunit (:472-478, when an explicit `sourceStockId` at :434-441 differs from `replenishOrder.getStockunitId()`), but only `sourceStock` is *physically transferred* (:498). `moved_source_unitload_label` faithfully records the UL that MOVED (the transferred `sourceStock`'s UL, including the explicit-`sourceStockId` case); a replenishment sourced across >1 UL records only the transferred UL, by design. Documented as a known limitation in §10.

**Files changed:** `service/mobile/MobileReplenishService.java`.

### 3.4 Fix D — Detail read (`findDetailMapById` + `getReplenishorderDetails`)

**Problem:** the detail payload exposes only the live `su.amount`; old finished rows show 0.

**Solution (both additive):**

1. `findDetailMapById` (:509-529) — add 4 frozen columns to the `SELECT`:

```sql
   ... , su.amount as stockUnitAmount,
   r.moved_amount as movedAmount,
   r.moved_source_unitload_label as movedSourceUnitload,
   r.moved_destination_unitload_label as movedDestinationUnitload,
   r.moved_destination_location_name as movedDestinationLocation
   FROM replenishorder r ...
```

2. `getReplenishorderDetails` (:328-374) — surface new keys, NULL-safe, matching the existing lower-cased-key convention (`row.get("stockunitamount")`); keep the existing `stockUnitAmount` put for back-compat:

```java
   if (row.get("movedamount") != null)              details.put("movedAmount", row.get("movedamount"));
   if (row.get("movedsourceunitload") != null)      details.put("movedSourceUnitload", row.get("movedsourceunitload"));
   if (row.get("moveddestinationunitload") != null) details.put("movedDestinationUnitload", row.get("moveddestinationunitload"));
   if (row.get("moveddestinationlocation") != null) details.put("movedDestinationLocation", row.get("moveddestinationlocation"));
```

- Old 164 rows: NULL snapshot → keys omitted; `stockUnitAmount` retained; no error.
- **UI switch is out of scope** — a `wms2-web-ui` follow-on prefers `movedAmount`/`movedSourceUnitload` for closed records (§8).

**Files changed:** `ReplenishorderRepository.java`, `ReplenishorderService.java`.

### 3.5 Fix E — List reads (source-UL label COALESCE) — 2 of 3 queries

**Problem:** `getDetailViewByKeyword` (:389) and `getClosedViewByKeyword` (:447) both return `state >= FINISHED` rows and expose `u.labelid as unitload` live → drift.

**Solution:** COALESCE the frozen label into the **existing** `unitload` alias; open orders and old finished rows (NULL snapshot) fall back to the live join:

```sql
   COALESCE(r.moved_source_unitload_label, u.labelid) as unitload,
```

Apply to **:389** `getDetailViewByKeyword` (no state filter) and **:447** `getClosedViewByKeyword` (`state >= :state`).

**Explicitly NOT applied — :417 `getOpenViewByKeyword`** (`state < :state`): returns open orders only, whose source pallet is still present; the live `u.labelid` is always correct and the frozen column is NULL until finish. **Dropped from scope** (§0 row 6).

**Projection unchanged:** COALESCE targets the pre-existing `unitload` alias, so `ReplenishOrderDetailView` needs no new getter (§0 row 8). `requestedamount` in the list stays as-is (labeled "Requested Amount"); a moved-qty column is the same `wms2-web-ui` follow-on.

**Files changed:** `ReplenishorderRepository.java`.

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| Bug present | Yes (ClickUp `REPL052269`) | Yes (164/168 on wms2-wineco-dev) | Same root cause: live source-UL/amount join on closed orders |
| This plan | **Not planned** | **In scope** | v2-only per user scoping |

### What Needs Porting
1. Nothing — v2-only.

### What Does NOT Need Porting (here)
- A v1/wms-api paired plan (same base name, v1 variant) is a later candidate. v1 is Java 8 / Spring Boot 2.3.7 with a different migration layout; the column-snapshot approach ports conceptually but migration/entity/SQL differ. Cross-version row in §10.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Fresh v2 DB at/above base `V2.2.00` with `V2.2.01`/`V2.2.02` applied; `V2.2.03` is this plan's new migration | DBA / operator | Operator applies `V2.2.03` per tenant DB before deploying the JAR |
| 2 | **Feature flags / system properties** | N/A | — | Behavior is unconditional at finish |
| 3 | **Config / env changes** | N/A | — | No `application.properties` change |
| 4 | **Deploy-order dependencies** | Apply `V2.2.03` **before** deploying the new JAR (else `ddl-auto=validate` fails on mapped-but-missing columns) | Release | wms2-web-ui follow-on ships independently, after |
| 5 | **Data migration** | **None (forward-only)** — existing 164 FINISHED rows stay NULL by design (§10) | — | No backfill script |
| 6 | **External systems** | N/A | — | No OMS/printer/Keycloak interaction |
| 7 | **Access / permissions** | N/A | — | No new endpoint/authority |
| 8 | **Monitoring / alerts** | N/A | — | No new metric |

### 5.2 Implementation Checklist

- [ ] **Fix A** — add `V2.2.03__replenishorder_finish_audit_snapshot.sql` (4 nullable columns).
- [ ] **Fix B** — add 4 fields + getters/setters to `Replenishorder.java` (jakarta `@Column`, no `@NotNull`).
- [ ] **Fix C** — insert the early capture block (source-UL label + amountPicked) **before** :470/:498; set all 4 entity fields before :501; reuse `amountPicked` at :498. Verify `unitloadRepository` is injected; null-guard `sourceStock.getUnitloadId()`.
- [ ] **Fix D** — extend `findDetailMapById` SELECT + surface additive, NULL-safe keys in `getReplenishorderDetails`.
- [ ] **Fix E** — `COALESCE(...)` in `getDetailViewByKeyword` (:389) and `getClosedViewByKeyword` (:447) ONLY; leave `getOpenViewByKeyword` unchanged.
- [ ] Unit/H2 tests added (§6), including both transfer branches + forward-only degradation.
- [ ] `mvn clean compile` green; context loads under `ddl-auto=validate`.
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh` → 0 FAIL.
- [ ] Code review completed.

---

## 6. Test Plan

### 6.0 Acceptance Criteria (contract-tested)

1. **AC-1 (headline defect — capture-before-mutation, BOTH branches):** For **both** transfer branches, a replenishment whose source UL differs from the destination UL, finished via `finishReplenishmentOrderInternal`, MUST persist `moved_source_unitload_label` = the source UL's label **as it was BEFORE `transferStockToUnitLoad`**. An implementation that reads the source UL after the transfer will observe the destination (full move) or `Nirwana` (partial-to-zero) label and MUST fail this criterion.
2. **AC-2 (full-move branch):** source fully transferred and re-homed to the destination UL → recorded label = the original source UL, not the destination UL.
3. **AC-3 (partial-drain branch):** source drained to zero and sent to `Nirwana` → recorded label = the original source UL, not `Nirwana`.
4. **AC-4 (moved qty):** `moved_amount` = the actual moved qty (`amountPicked`), including partial picks (`amountPicked < requestedamount`), not `requestedamount`.
5. **AC-5 (transferred-UL fidelity, incl. explicit source):** `moved_source_unitload_label` = the **transferred** `sourceStock`'s UL label, including the explicit-`sourceStockId` case (:434-441) where a second stockunit's reservation is released but not transferred. Not multi-source aggregation.
6. **AC-6 (every finish path):** `fulfillMultipleUnitLoads` writes the snapshot on every finished sub-order (single-order path and each multi-order sub-order).
7. **AC-7 (forward-only graceful degradation):** a CLOSED row created **before** V2.2.03 (all 4 snapshot columns NULL) still renders the live label via the Fix E `COALESCE` in `getDetailViewByKeyword`/`getClosedViewByKeyword`, and Fix D detail returns `stockUnitAmount` (back-compat) with the moved* keys omitted when `movedamount` is NULL.
8. **AC-8 (migration additive):** applying `V2.2.03` and booting under `ddl-auto=validate` passes.

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Full move, source re-homed to destination | Finish where entire source qty moves (StockunitBusinessService:346 path) | `moved_source_unitload_label` = original source UL (AC-2) |
| Partial drain to zero → Nirvana | Finish where source empties (:380/:422 path) | `moved_source_unitload_label` = original source UL, not `Nirwana` (AC-3) |
| Partial pick | `amountPicked < requestedamount` | `moved_amount` = partial qty (AC-4) |
| Explicit sourceStockId ≠ order stockunitId | Finish with explicit source (:434-441) | recorded label = transferred `sourceStock`'s UL (AC-5) |
| Multi-order fulfillment | `fulfillMultipleUnitLoads` over ≥2 orders | snapshot on every finished sub-order (AC-6) |
| Old finished row (NULL snapshot) | Read a pre-migration FINISHED row (detail + closed list) | COALESCE → live label; `stockUnitAmount` returned; no error (AC-7) |
| Open list unaffected | Open-list query | `unitload` = live source UL |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `MobileReplenishServiceUnitTest` | `finish_fullMove_recordsPreMoveSourceUl` | mocks the transfer to re-home `sourceStock` to destination; asserts recorded label = original source UL (AC-1/AC-2). **Guard:** a version that reads the label post-transfer observes the destination label and fails. |
| `MobileReplenishServiceUnitTest` | `finish_partialDrainToNirvana_recordsPreMoveSourceUl` | mocks the transfer to send `sourceStock` to `Nirwana`; asserts recorded label = original source UL, not `Nirwana` (AC-1/AC-3). Same post-transfer-read guard. |
| `MobileReplenishServiceUnitTest` | `finish_explicitSourceStockId_recordsTransferredUl` | explicit `sourceStockId` ≠ order stockunit; recorded label = transferred source's UL (AC-5) |
| `MobileReplenishServiceUnitTest` | `finish_nullSourceUnitloadId_noNpe` | null `sourceStock.getUnitloadId()` → label left null, no NPE |
| `MobileReplenishService…H2Test` | `finishSingle_persistsSnapshot` / `fulfillMultipleUnitLoads_persistsSnapshotOnEach` | snapshot persisted single + each sub-order (AC-6) |
| `MobileReplenishService…H2Test` | `partialPick_recordsAmountPicked` | `moved_amount` = partial qty (AC-4) |
| `ReplenishorderServiceUnitTest` | `getDetails_surfacesMovedKeys` | on a snapshotted row `row.get("movedamount")` non-null and `details` contains `movedAmount`/`movedSourceUnitload`/... (keyed assertion, not naming-only) |
| `ReplenishorderServiceUnitTest` | `getDetails_nullSnapshot_omitsKeys_keepsStockUnitAmount` | NULL snapshot → moved* keys omitted, `stockUnitAmount` retained, no error (AC-7) |
| `ReplenishorderRepositoryIntegrationTest` (H2/PG) | `closedView_coalescesFrozenSourceUl` / `openView_usesLiveLabel` / `nullSnapshot_fallsBackToLive` | COALESCE prefers frozen label for finished rows; open view untouched; NULL → live (AC-7); `findDetailMapById` selects the 4 moved columns |

> **IT harness:** the v2 Testcontainers-Postgres lane is broken (**SBDEV-2217**). Gate on **unit + H2 + `mvn clean compile`**. Any Postgres-only IT that cannot boot is left `@Disabled` with `// TODO(SBDEV-2217)`.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| UI happy path (detail) | staging | Finish a replen on `wms2-wineco-dev`, then open finished-order detail | Payload carries `movedAmount` + `movedSourceUnitload` (UI shows old fields until web follow-on) | |
| SQL sanity | staging DB | `SELECT moved_amount, moved_source_unitload_label FROM replenishorder WHERE state=700 ORDER BY id DESC LIMIT 5;` | Newly-finished rows non-NULL; pre-migration rows NULL | |
| Closed-list smoke | staging | `getClosedViewByKeyword` for a finished order | `unitload` = frozen source UL, not `Nirwana` | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=MobileReplenishServiceUnitTest,MobileReplenishService*H2Test,ReplenishorderServiceUnitTest` | | |
| `mvn clean compile` | | |
| `mvn verify` (ITs may skip per SBDEV-2217) | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Testcontainers-Postgres full boot | Harness broken (SBDEV-2217); covered by H2 + `mvn clean compile` |
| WMS-web UI rendering | Frontend follow-on (`wms2-web-ui`), out of scope |
| Backfill of 164 historical rows | Forward-only (§10) — source data gone |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | In-JVM state | new Caffeine/map/static/ThreadLocal? | **No** | Entity columns + a native-SQL read only |
| 2 | Connection-pool math | change per-request connection usage? | **No** | Reuses the existing save at :502 and existing read tx; no new pool/round-trip (source-UL `findById` is a cache/PC-local read within the same tx) |
| 3 | Scheduled jobs | add/modify `@Scheduled`? | **No** | None touched |
| 4 | Long transactions | hold a tx across repo calls / external I/O? | **No** | Capture is in-memory locals + entity setters in the existing finish tx; no added external I/O |
| 5 | Request affinity | assume same replica for follow-up? | **No** | Stateless; all state on the DB row |
| 6 | Retry / idempotency | rely on single-execution semantics? | **Yes** | Finish guarded by `if (state >= FINISHED) throw REPLENISH_ALREADY_FINISHED` (:448). Post-commit retry is rejected; pre-commit retry re-runs the same deterministic capture. **Idempotent.** |
| 7 | Tenant context | use `TenantContext` across async boundaries? | **No** | Request-scoped tenant tx; no `@Async` |
| 8 | Distributed lock correctness | add/rely on lock across replicas? | **N/A** | No new lock; entity `@Version` (via `AbstractBaseEntity`) rides the same optimistic-lock save |
| 9 | Cache invalidation | write to a cached entity? | **No** | No `@Cacheable`/`@CacheEvict` on `Replenishorder` (verify via grep) → no eviction needed |
| 10 | External notifications | send HTTP/message inside a tx? | **No** | No OMS/outbox/printer call added |

### Evidence (for any "Yes")

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 6 | Existing finish guard makes the write idempotent | `MobileReplenishService.java:448`; asserted alongside the already-finished-throws test |

---

## 8. Notes

- **`@Transactional` correctness:** the finish path is already `@Transactional("tenantTransactionManager", ...)` (:419); the capture + snapshot write join that tenant tx. `getReplenishorderDetails` is already `@Transactional("tenantTransactionManager", readOnly=true)` (:327). No TM change. OSIV is disabled but all reads run inside their tx.
- **Native result-key casing:** native-query maps return lower-cased keys — Fix D reads `row.get("movedamount")` etc.
- **Follow-on (out of scope):** `wms2-web-ui` change to render `movedAmount`/`movedSourceUnitload` for closed records (detail + closed list) instead of the live `stockUnitAmount`/`unitload`. Track as a paired UI plan.
- **Follow-on (optional):** v1/wms-api paired plan (same base name, v1 variant) — §4/§10.
- **Design ref:** `sbdocs/3-Resources/design/wms2-replenishment-design.md` §5 (state machine) + §7 (finish flow).

### Version history
- 2026-07-20 — draft created (Planner pass, ralplan consensus loop).
- 2026-07-20 — **consensus revision** (verdict ITERATE → APPROVE): corrected Fix C to capture the source-UL label **before** `transferStockToUnitLoad` (the source stockunit is mutated in place by the transfer); rewrote §10 stock-history rejection with correct `Stockrecord` facts (revived Option C as co-equal, rejected on the partial-move `recordRemoval` asymmetry); added both-branch + forward-only ACs and tests; added §9.3 Risks (snapshot/journal duplication); verify script now encodes capture-before-transfer **ordering**.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh`. Authored before implementation; run after every change pass; a "DONE" claim with any FAIL is rejected.

Checks (POSITIVE + NEGATIVE/behavioral):

| ID | Check | Type |
|----|-------|------|
| `A_migration_present` | `V2.2.03__…sql` exists and `ADD COLUMN`s all four columns | POSITIVE |
| `A_no_edit_applied` | no git diff to `V2.2.00`–`V2.2.02` (never edit an applied migration) | NEGATIVE |
| `B_entity_getters` | `Replenishorder.java` declares the 4 getters with matching `@Column(name=...)`; no `@NotNull` on them | POSITIVE / NEGATIVE |
| `C_capture_before_transfer` | **(critical)** source-UL label capture line NUMBER **<** `transferStockToUnitLoad(` line number | POSITIVE (ordering) |
| `C_no_post_transfer_source_read` | the source-UL derivation (`sourceStock.getUnitloadId()`) does NOT sit at/after the transfer line | NEGATIVE (ordering) |
| `D_repo_select` | `findDetailMapById` SELECT has the 4 `r.moved_*` aliases | POSITIVE |
| `D_service_keys` | `getReplenishorderDetails` puts the 4 lower-case keys behind NULL guards; `stockUnitAmount` retained | POSITIVE |
| `E_coalesce_applied` | `getDetailViewByKeyword` + `getClosedViewByKeyword` use the COALESCE | POSITIVE |
| `E_open_untouched` | `getOpenViewByKeyword` still plain `u.labelid` | NEGATIVE |
| `projection_unchanged` | `ReplenishOrderDetailView.java` unchanged (no new getter) | NEGATIVE |
| `behavior` | `mvn test -Dtest=MobileReplenishServiceUnitTest,ReplenishorderServiceUnitTest` passes | BEHAVIORAL |

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | **Standard** | 5 fixes (A–E) in one subsystem, additive contract change |
| **Pre-draft step** | analyst+planner + this ralplan consensus (done) | high-signal single-subsystem change |
| **Plan-review step** | **critic** | required for Standard+ (Architect+Critic ran in this loop) |
| **Implementation shape** | **executor** | single coherent subsystem; verify-script is the exit gate |
| **Verification step** | verify-script + **verifier** | mandatory |
| **Code-review step** | code-reviewer (light) | native-SQL + entity + ordering-sensitive edit warrant a read |
| **Commit step** | git directly | one logical change (migration + entity + service + repo) |

### 9.3 Risks

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | **Ordering regression** — a future refactor moves the source-UL read past `transferStockToUnitLoad`, silently reintroducing the bug | High | `C_capture_before_transfer` ordering check in the verify script (line-number comparison); both-branch tests with a post-transfer-read guard |
| 2 | **Snapshot / journal duplication** — the new columns and the `Stockrecord` journal (keyed by ordernumber) now describe the **same** move event. Both are written in the same tenant tx (atomic today), but nothing enforces they stay semantically equal; a future change to either the snapshot write (Fix C) or `transferStockToUnitLoad`'s journaling can diverge with no reconciliation | Medium | Documented as accepted (§10 #2). Single choke point (Fix C) minimizes divergence surface; if a reconciliation need arises, add a periodic snapshot-vs-journal consistency check (follow-on, not in scope) |
| 3 | **Forward-only gap** — the 164 legacy rows stay NULL forever | Low (accepted) | Graceful degradation contract-tested (AC-7); limitation documented (§10 #3) |
| 4 | **Multi-source under-record** — replenishment sourced across >1 UL records only the transferred UL | Low (by design) | Documented (§3.3, AC-5, §10) |

---

## 10. Resolved Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Scope = v2/wms2-api ONLY** | Ticket filed on v1, but the user scoped to v2. A v1 counterpart is a possible future paired plan (same base name) — not planned here. |
| 3 | **Historical data = FORWARD-ONLY; the 164 existing FINISHED rows stay NULL** | The source stockunit is drained/re-homed/recycled to `Nirwana`, so a faithful backfill is impossible — any value would be fabricated. No Flyway backfill. Reads degrade gracefully (AC-7). |
| 4 | **`moved_source_location_name` NOT added** | `r.sourcelocationname` is already a stable creation-time snapshot; a duplicate column would be redundant. |
| 5 | **Fix E excludes `getOpenViewByKeyword`** | `WHERE r.state < :state` returns open orders only, whose live source-UL join is always correct; COALESCE there is dead code. |
| 6 | **Projection `ReplenishOrderDetailView` unchanged** | Fix E COALESCEs into the existing `unitload` alias — no new getter needed. |
| 7 | **UI switch to prefer moved* fields is a `wms2-web-ui` follow-on** | This plan makes the data available (additive, back-compat); the frontend consumes it separately. |
| 8 | **Multi-source is recorded as the single transferred UL, not aggregated** | Only `sourceStock` is physically transferred (:498); the second stockunit (:472-478) only has reservation released. Faithful to "what moved"; aggregation is out of scope. |

### Decision #2 — Storage mechanism (rewritten with correct facts)

**Decision: frozen snapshot COLUMNS on `replenishorder`, written at finish (captured pre-transfer).**

Three mechanisms were evaluated:

- **Option A — snapshot columns on `replenishorder` (CHOSEN).**
- **Option B — separate `replenishorder_finish_audit` table.** Rejected: over-engineered for a 1:1 per-order fact; adds an entity, a join on every read, and a second write in the finish tx — more blast radius for no extra value. Reconsider only if multiple finish events per order ever become possible.
- **Option C — read-time join to the `Stockrecord` journal (revived and evaluated as co-equal).** `Stockrecord` **does** already journal the move keyed by `ordernumber` (`fromunitload`/`tounitload`/`fromstoragelocation`/`tostoragelocation`/`amount`/`ordernumber`/`activitycode`), and `transferStockToUnitLoad` (:498) is called with `orderNumber = replenishOrder.getNumber()` and `CODE_REPLENISHMENT`. It also appears append-only (no recycle mechanism found), so unlike the live `stockunit` join it would **not** drift to `Nirwana`. This is a genuine alternative and was taken seriously.

**Why COLUMNS still win over Option C — on concrete grounds:**
1. **The journal is asymmetric exactly on the bug's core case.** Full move: `recordTransferStockUnit(sourceStockunit, sourceUnitload, destinationUnitload, …)` (`StockunitBusinessService:360`) passes the **original** `sourceUnitload`, so the journal *does* hold the correct pre-move source UL. But the partial branch uses `recordRemoval(sourceStockunit, …)` + `recordCreation(destinationStockUnit, …)` (`:376-377`), and **`recordRemoval` carries no from/to unitload**. The drained-to-zero case — which is precisely the 164-row bug — has **no reliable source UL in the journal**. Reconstructing it via Option C would fail on the exact rows we need to fix.
2. **Projection reuse / O(1) read.** COALESCE into the existing `unitload` alias needs no new projection getter and no journal aggregation. Option C would require joining/aggregating the journal per order and **disambiguating 1-row-full-move vs 2-row-partial-move layouts and activity codes** at read time on a hot list query.
3. **Self-describing row.** The closed order carries its own audit facts; no dependency on a separate journal's schema/retention.

**Residual risk (named, accepted):** the snapshot columns **duplicate** the `Stockrecord` journal — two writes describe one event in the same tenant tx. They are atomic today, but nothing enforces they stay semantically equal; a future change to either side can diverge with no reconciliation. Tracked as §9.3 Risk #2. Accepted because the single choke point (Fix C) minimizes divergence surface and the journal's partial-move asymmetry makes it unusable as the sole source anyway.

**Historical-data axis:** forward-only (chosen) vs Flyway backfill (rejected — impossible to reconstruct faithfully; would fabricate audit values).

### Cross-version row

| Base name | v1 | v2 |
|-----------|----|----|
| `SBDEV-1714-replenishment-finish-audit-snapshot` | candidate future paired plan (not started) | **this plan (draft)** |

### Open Questions
- [ ] Should the WMS-web closed-list "Requested Amount" column show `moved_amount` for finished rows, or add a separate "Moved" column? — affects the follow-on UI plan's contract.
- [ ] Is a v1/wms-api paired plan wanted, or is v2 sufficient for this ticket? — determines whether §4's paired plan is drafted.
- [ ] Do we ever need a snapshot-vs-`Stockrecord` reconciliation check (§9.3 Risk #2)? — defer until a divergence is observed.

---

## 11. Implementation Status (v2 — 2026-07-20)

**Implemented and green.** wms2-api commit `393bf8f` on branch `fix/SBDEV-1714-replenishment-finish-audit-snapshot` → **PR [#83](https://github.com/SiteBossInc/wms2-api/pull/83) into `develop`**.

### Fixes landed
| Fix | File | Notes |
|---|---|---|
| A | `db/migration/V2.2.03__replenishorder_finish_audit_snapshot.sql` | 4 nullable columns |
| B | `model/Replenishorder.java` | 4 fields + getters/setters, no `@NotNull` |
| C | `service/mobile/MobileReplenishService.java` | source-UL label + `amountPicked` captured **before** `transferStockToUnitLoad`; 4 fields set before `setState(FINISHED)`/save |
| D | `repo/jpa/ReplenishorderRepository.java`, `service/ReplenishorderService.java` | `findDetailMapById` selects 4 aliases; `getReplenishorderDetails` surfaces 4 NULL-safe keys, keeps `stockUnitAmount` |
| E | `repo/jpa/ReplenishorderRepository.java` | `COALESCE(moved_source_unitload_label, u.labelid)` in `getDetailViewByKeyword` + `getClosedViewByKeyword` (display **and** keyword search); `getOpenViewByKeyword` untouched |

### Code review
`code-reviewer` (opus): 0 HIGH, 1 MEDIUM, 4 LOW. **MEDIUM fixed** — the two closed/detail list queries were displaying the frozen label via `COALESCE` but still filtering keyword search on the live `u.labelid`; search now `COALESCE`s too, so a finished row is findable by its displayed label. Two LOW test-gap items folded in (null-`amountPicked` fallback, null source-unit-load guard). LOWs remaining are operational/by-design (the `validate`-profile reminder that `wms_test` must have `V2.2.03`; destination UL not frozen in list views — source-side bug only).

### Test results
- `mvn clean compile` — SUCCESS.
- `mvn test -Dtest=MobileReplenishServiceUnitTest,ReplenishorderServiceUnitTest` — **143 + N run, 0 failures, 0 errors**.
- Replenish H2 + controller regression (`MobileReplenishServiceH2Test`, `ReplenishOrderControllerH2Test`, `ReplenishOrderControllerUnitTest`) — **29 run, 0 failures** (4 pre-existing skips).
- `verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh` — **13 pass, 0 fail** (incl. the capture-before-transfer ordering check).
- Testcontainers-Postgres ITs NOT run — harness broken (SBDEV-2217); covered by unit + H2 + compile as planned.

### Docs
`wms2-replenishment-design.md` updated: §4.1 entity table (4 columns), §5 finish-snapshot note, §13 verification log entry.

### Deferred (unchanged from plan)
- `wms2-web-ui` follow-on to *display* `movedAmount`/`movedSourceUnitload` on closed records (API is additive; UI still shows legacy fields until then).
- v1/wms-api paired plan — candidate, not started.


> **Archived 2026-07-25.** Acceptance script retired to `sbdocs/4-Archieves/scripts/verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh`.
