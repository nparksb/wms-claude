---
title: "SBDEV-1581: Empty Pallet Cleanup — Investigation Report"
type: investigation
status: concluded
version: v1
scope: WMS v1 (wms-api) automated empty-pallet lifecycle management
owner: nam.park@siteboss.net
created: 2026-05-06
updated: 2026-05-06
last_verified: 2026-05-06
verified_by: nam.park@siteboss.net
related: []
tags:
  - investigation
  - report
  - pallets
  - cleanup
  - scheduled-jobs
---

# SBDEV-1581: Empty Pallet Cleanup — Investigation Report

**Topic:** WMS v1 automated empty pallet movement to EmptyPallets location | **Version:** v1
**Started:** 2026-05-06 | **Investigator:** Nam Park
**Status:** concluded

---

## 1. Context & Trigger

ClickUp ticket SBDEV-1581 (Priority: High, Effort: 2/5) describes the expected lifecycle of inbound pallets:

1. Pallet created at receiving and assigned to a putaway
2. Pallet stored in an overstock/bulk location
3. Stock gradually pulled from pallet to pickable locations until empty
4. Empty pallet should be moved automatically to the `EmptyPallets` location — ideally by a nightly cleanup job

The ticket notes that during putaway the system "advises" the user to move the pallet, but otherwise empty pallets left in storage locations are not cleaned up automatically. This investigation determines whether a cleanup job exists, what automated paths do exist, and what is missing.

---

## 2. Questions

1. Does a scheduled job exist that finds and moves empty pallets to the `EmptyPallets` location?
2. Under what conditions does the system currently move a pallet to `EmptyPallets` automatically vs. by user action?
3. What data query would be needed to identify pallets that are empty but not yet at `EmptyPallets`?
4. What infrastructure is missing to implement the nightly cleanup?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | A cleanup job exists but is not wired into SchedulingConfiguration | low | Ticket says feature "should be running" — might be coded but disabled |
| H2 | The cleanup job does not exist at all — it was planned but never built | high | Ticket created 2025, status "in development" — feature request language |
| H3 | The system already moves empty pallets automatically through process flows (not a scheduled job) | medium | Several move-unitload paths look like they might handle this |
| H4 | Nothing is actually wrong — empty pallets accumulate but only as an operational nuisance | low | Ticket priority is High; ticket explicitly describes a missing nightly job |

---

## 4. Method

- Code read of all 5 registered scheduled jobs (`schedulejob/SchedulingConfiguration.java`, `schedulejob/*.java`)
- Symbol grep for `EmptyPallets`, `EMPTY_PALLETS`, `emptyPallet` across `src/main/java/`
- Code read of all service paths that reference `STORAGE_LOCATION_EMPTY_PALLETS`
- Trace of `PutAwayMobileDto.emptyPallet` flag from service through controller to mobile UI
- Grep for repository queries that could identify empty pallets by type + absence of children/stock
- Grep for any system property keys for an empty pallet timer

---

## 3.5 Sources In Scope

| Symbol / Pattern | Files found |
|---|---|
| `STORAGE_LOCATION_EMPTY_PALLETS` | `WmsConstants.java:734`, `MobileMoveUnitloadService.java:248,379`, `ReceivingService.java:615,642`, `MobilePutAwayService.java` (via dto flag) |
| `emptyPallet` (DTO flag) | `PutAwayMobileDto.java:16,52,56`, `MobilePutAwayService.java:365,475`, `scanFlowBin.vue:17` |
| `schedulejob/` classes | `CleanUpOldMessagesJob`, `OrderReleaseJob`, `ReplenishOrderJob`, `StockSummaryExportJob`, `ReleaseExpiredPickingOrdersFromUserJob` |
| `SchedulingConfiguration` registered tasks | cleanUpOldMessages, orderRelease, replenish, stockSummaryExport, releaseExpiredPickingOrdersFromUser |
| `SYSTEM_PROPERTY_*_EMPTY_PALLET` | **None found** |
| repo query for empty pallets | **None found** |
| Prior reports | None in `sbdocs/3-Resources/reports/` or archives |

---

## 5. Evidence

### 5.1 No empty-pallet cleanup job exists anywhere in the codebase

**Source:** `src/main/java/net/aim_ai/wms/schedulejob/` — directory listing + `SchedulingConfiguration.java`

**Observation:** The `schedulejob/` directory contains exactly 5 job files. `SchedulingConfiguration.configureTasks()` registers exactly 5 cron tasks: `cleanUpOldMessages`, `orderRelease`, `replenish`, `stockSummaryExport`, `releaseExpiredPickingOrdersFromUser`. None targets empty pallet detection or movement. No `EmptyPalletCleanupJob.java` or equivalent exists.

**Supports:** H2 — the job was never built.
**Contradicts:** H1.

### 5.2 No repository query exists to find empty pallets

**Source:** `src/main/java/net/aim_ai/wms/repo/jpa/` — full grep for `emptyPallet`, `findByUnitloadTypeId`, `empty_pallet`, `pallet.*no.*stock`

**Observation:** Zero results. No `UnitloadRepository` or `StockunitRepository` method queries for pallets that have no child unit loads and no stock units. The query needed to implement the job does not exist in the data access layer.

**Supports:** H2.

### 5.3 No system property keys exist for an empty pallet timer

**Source:** `WmsConstants.java` — grep for `SYSTEM_PROPERTY_*PALLET*` and `SYSTEM_PROPERTY_*EMPTY*`

**Observation:** All pallet-related system properties cover label printing and label patterns (`PRINTING_ZPL_OUTBOUND_PALLET_LABEL`, `STRING_PATTERN_INBOUND_PALLET`, `STRING_PATTERN_OUTBOUND_PALLET`). No `EMPTY_PALLET_CLEANUP_TIMER_HOUR` or equivalent key exists. All existing scheduled jobs read their run time from sysprop-backed hour/minute keys — this groundwork is not laid for the cleanup job.

**Supports:** H2.

### 5.4 Three manual/process-triggered paths DO move empty pallets today

**Source:** Multiple files — evidence below

**Path A — Move-stock flow** (`MobileMoveUnitloadService.java:348–381`):
When a user moves the last stock unit off a pallet using the mobile move-stock screen, `transferStock()` is called. After the stock transfer, it re-fetches the unit load, checks its type, and for `UNIT_LOAD_TYPE_PALLET` or `UNIT_LOAD_TYPE_CART`, calls `unitloadBusinessService.transferUnitLoadToLocation(sourceUnitLoad, emptyPallets, ...)`. This is automatic **within** the move-stock user action, but requires the user to have initiated a move.

Note: `transferStock` is marked `// TODO remove this method entirely` (`MobileMoveUnitloadService.java:350`), indicating this path may be revised or removed. It also throws `BusinessException` for pallets with no stock and no children (`line 367`), with a commented-out block (`line 366`) that was originally intended to handle that case.

**Path B — Putaway flow** (`MobilePutAwayService.java:363–365`, `wms-mobile-ui/components/putaway/scanFlowBin.vue:17`):
When all packages on a pallet are stored during putaway, `checkPackagesInPallet()` detects that every item's `moveCompleted=true` and sets `putAwayMobileDto.setEmptyPallet(true)`. The mobile UI then renders `<span v-if="info.emptyPallet"><strong>Completed</strong></span>`. This is a **UI advisory only** — the API does not auto-move the pallet to EmptyPallets. The user must physically move it and scan it through the move-unitload flow.

**Path C — Receiving unassign** (`ReceivingService.java:631–648`):
`unassignPallet()` explicitly moves the pallet to `EmptyPallets` after it is unassigned from a receiving advice. This handles only the specific case where a pallet is detached from a receiving advice before its stock has been moved.

**Supports:** H3 (partially true — some flows auto-move on user action), but confirms these paths are user-triggered, not nightly batch.
**Contradicts:** H4 — the ticket is correct that there is no automated nightly path.

### 5.5 MobileMoveUnitloadService guards against moving a non-empty pallet to EmptyPallets

**Source:** `MobileMoveUnitloadService.java:244–248`

```java
List<Stockunit> stockUnits = stockunitRepository.findByUnitloadId(sourceUnitLoad.getId());
List<Unitload> childUnitLoads = unitloadRepository.findByCarrierunitloadId(sourceUnitLoad.getId());
if (destinationStorageLocation.getName().equals(WmsConstants.STORAGE_LOCATION_EMPTY_PALLETS)
        && (!stockUnits.isEmpty() || !childUnitLoads.isEmpty())) {
```

**Observation:** The system prevents a user from manually moving a non-empty pallet to EmptyPallets. The two queries used here (`findByUnitloadId` and `findByCarrierunitloadId`) are exactly the join conditions needed for a cleanup job query — they already exist in `UnitloadRepository` / `StockunitRepository`.

**Supports:** Implementation of the cleanup job can reuse existing queries — no new query pattern needs to be invented.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H1 | Job exists but not wired | eliminated | Exhaustive job directory scan; no class found |
| H2 | Job does not exist at all | **confirmed** | No job file, no repo query, no sysprop keys |
| H3 | Process flows already auto-move (partial) | **confirmed (partial)** | Move-stock and unassign paths do move on user action; putaway only advises |
| H4 | Nothing actually wrong | eliminated | Ticket priority High; missing nightly path confirmed |

---

## 7. Verdict

The nightly empty-pallet cleanup job described in SBDEV-1581 **does not exist**. This is a missing feature, not a broken one. The codebase has no `EmptyPalletCleanupJob` class, no repository query to identify pallets with no children and no stock, and no system property keys for a cleanup timer.

Three process-triggered paths do move empty pallets today — move-stock (automatic within the flow), receiving unassign (automatic), and putaway (UI advisory only). All three require a user to have initiated the relevant process. Pallets that become empty through gradual stock depletion across multiple picking/replenishment cycles — the most common warehouse scenario — have no automated path to EmptyPallets.

The guard logic in `MobileMoveUnitloadService.java:248` already demonstrates the correct emptiness check: `findByUnitloadId(id).isEmpty() && findByCarrierunitloadId(id).isEmpty()`. The infrastructure to implement the cleanup query is already present in the repositories.

**Confidence:** high

---

## 8. Recommendation

- [x] **Fix now** — implement the nightly empty pallet cleanup job via `wms-feature-plan`.

**Justification:** High-priority ticket, effort 2/5 (Brent's estimate), and the code structure is already in place. No new repository patterns needed. The job needs:
1. A new `UnitloadRepository` native query to find pallets with no children and no stock, not already at EmptyPallets
2. A new `EmptyPalletCleanupJobService` that iterates the result and calls `unitloadBusinessService.transferUnitLoadToLocation(..., emptyPalletsLocation, ...)`
3. A new `EmptyPalletCleanupJob` wired into `SchedulingConfiguration` with two new sysprop keys (`EMPTY_PALLET_CLEANUP_TIMER_HOUR`, `EMPTY_PALLET_CLEANUP_TIMER_MINUTE`)

The downstream feature plan must ship with a `verify-SBDEV-1581.sh` script per the `wms-feature-plan` skill's verification-script requirement.

---

## 9. Open Questions

1. **Should the cleanup job also handle empty CART-type unit loads?** The `transferStock()` switch in `MobileMoveUnitloadService.java:376–380` treats Pallet and Cart identically (waterfall case). WmsConstants has `STORAGE_LOCATION_EMPTY_PALLETS` but no `STORAGE_LOCATION_EMPTY_CARTS`. Clarify with Brent whether carts should go to the same location or be excluded.

2. **Should the job delete or relocate?** The ticket says "moves them to EmptyPallets." The `transferStock()` path does a location transfer, not a deletion. Is this the desired behavior, or should truly empty pallets eventually be deleted from the unitload table? Leaving them in EmptyPallets indefinitely will grow that location's count.

3. **Scope of "empty" — what about pallets with entity locks?** Pallets whose children are locked (`ON_HOLD`, `PICKED_FOR_GOODSOUT`, etc.) should not be moved. The job query needs to account for this. Confirm the intended behavior with the team.

4. **TODO on `transferStock` removal** (`MobileMoveUnitloadService.java:350`): The move-stock auto-move path is marked for removal. Will the cleanup job be the canonical path for pallet relocation going forward? If so, the TODO should be resolved in the same feature plan.

---

## 10. References

- **Ticket:** SBDEV-1581 — [https://app.clickup.com/t/868fmwy65](https://app.clickup.com/t/868fmwy65)
- **Key source files:**
  - `src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java`
  - `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:348–381`
  - `src/main/java/net/aim_ai/wms/service/mobile/MobilePutAwayService.java:363–365`
  - `src/main/java/net/aim_ai/wms/service/ReceivingService.java:631–648`
  - `src/main/java/net/aim_ai/wms/service/WmsConstants.java:696,734`
  - `v1/wms-mobile-ui/components/putaway/scanFlowBin.vue:17`
- **Related plans:** none yet — see §8 for downstream plan requirement

---

## 11. Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | All in-scope code files / log sources / queries enumerated in §3.5 | ✓ §3.5 table covers all symbol/pattern greps |
| 2 | At least one "nothing is actually wrong" hypothesis in §3 | ✓ H4 |
| 3 | Each hypothesis has primary evidence (file:line) | ✓ §5.1–5.5 |
| 4 | Confidence assigned per hypothesis; uncertainty stated | ✓ §6 updated ranking |
| 5 | Null results documented | ✓ §5.1–5.3 document three non-findings |
| 6 | v1/v2 delta | no — ticket is v1 only; no v2 scope |
| 7 | Cross-references to related reports | no prior reports exist for this topic |
| 8 | §9 Open Questions populated | ✓ four questions |
| 9 | §8 Recommendation picks exactly one option | ✓ Fix now |
| 10 | Downstream plan must ship verify script | ✓ noted in §8 |

---

## 12. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| 2026-05-06 | Initial investigation | concluded | Nam Park |
