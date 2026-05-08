# Phase 2: N+1 Batch Fetch Implementation Plan

**Date:** 2026-04-04
**Status:** Analysis Complete — Implementation In Progress
**Branch:** `tmp/np2-api-problem-areas`

---

## Summary

Deep code analysis identified **35 N+1 query patterns** across 5 hot paths. The combined estimated query reduction is **~5,600 queries per cycle** (from ~6,200 to ~500). Implementation is prioritized by impact-to-effort ratio.

---

## 1. ReleaseOrderJobService.releaseOrder() — 11 N+1 patterns

### Quick Wins (implement first)
- **Eliminate duplicate fetches in finalization loop (lines 499-516):** Store entities fetched in the second loop (Unitload, Stockunit) in local maps and reuse them in the finalization loop. Eliminates patterns #11-13. **0 new repo methods.**
- **Pass pre-fetched Unitload/Location to `createPickingPosition()`:** Add an overloaded method that accepts already-fetched entities. Eliminates patterns #14-15.

### Bulk Pre-Fetch (main optimization)
Before the second loop (line 230), add:
1. Bulk-fetch all `FixLocationAssignment` via `findAllById(fixIds)` from `itemDataFixAssignmentMap`
2. Bulk-fetch all `Unitload` via `findAllById(unitloadIds)` from fix assignments
3. Bulk-fetch all `Location` via `findAllById(locationIds)` from fix assignments + unitloads
4. Bulk-fetch all `Stockunit` via existing `findByUnitloadIdIn(unitloadIds)`
5. New repo method: `UnitloadRepository.findByStoragelocationIdIn(Collection<Long>)`

**Estimated reduction:** ~12F queries/order to ~6 bulk queries

### New Repository Methods Needed
- `UnitloadRepository.findByStoragelocationIdIn(Collection<Long> locationIds)`

---

## 2. CustomerorderBatchService.runClubLine() — 6 N+1 patterns

### Quick Wins (implement first)
- **Use return value from `transferStockToUnitLoad`** instead of re-fetching at lines 642, 656. Eliminates ~300 queries. **0 new methods.**

### Batch Pre-Fetch (main optimization)
- **Rewrite `mapStockUnitsToItemData()`** (lines 537-553): Collect all unitload IDs, batch-fetch with existing `findByUnitloadIdIn()` and `findByCarrierunitloadIdIn()`, group in memory. Eliminates ~600 queries.
- **Pass pre-fetched context to `transferStockToUnitLoad()`**: Pre-fetch UnitloadType, source Location, destination Location once before the loop. Requires new overload on `StockunitBusinessService`. Eliminates ~2,400 queries.

### New Repository Methods Needed
- None (existing `findByUnitloadIdIn` and `findByCarrierunitloadIdIn` already exist)

**Estimated reduction:** ~3,620 to ~324 (91%)

---

## 3. TransferOrderService — 7 N+1 patterns

### Quick Wins (implement first)
- **Batch stockunit fetch in `isEnoughStockOnTransferLane()`** (line 144): Replace per-unitload `findByUnitloadId` with single `findByUnitloadIdIn()`. **0 new methods.**
- **Reuse carrier data in `getTransferLineUnitLoads()`** (line 360): Retain carrier map from traversal at lines 289-301 instead of re-fetching.

### Batch Pre-Fetch
- **Batch `findByCarrierunitloadId`** in child traversal (line 313): Replace per-ID call with existing `findByCarrierunitloadIdIn()` per level.
- **New bulk `getAmountsAvailableByLocation()`** for `getSKUOverview()` (line 235).

### New Repository Methods Needed
- `StockunitRepository.getAmountsAvailableByLocationAndItemdataIds(Long locationId, Collection<Long> itemdataIds)`

**Estimated reduction:** ~350-500 to ~10-20

---

## 4. ReplenishOrderJob — 9 N+1 patterns

### Quick Wins (implement first)
- **Bulk-update `updateReplenishmentOrderPriority()`**: Replace per-item fetch+save with `@Modifying @Query UPDATE ... WHERE id IN :ids`. Eliminates 2*N queries per priority level.
- **Optimize stock candidate loop** in `calculateOrder()` (line 160-168): Select winning candidate ID from projection list first, then single `findById`.

### Batch Pre-Fetch
- **Pre-fetch validation context for `generateReplenishmentForItemDataWithFixedAssignment()`**: Bulk-load FLAs, unitloads, locations, stockunits before the loop (similar to RecalcContext pattern).
- **Extend RecalcContext** with Location and LocationArea maps for `recalculateOrder()`.

### New Repository Methods Needed
- `ReplenishorderRepository.updatePriorityByIdIn(Collection<Long> ids, int priority)` — `@Modifying` bulk update

**Estimated reduction:** ~1,400+ to ~50-100

---

## 5. BillofladingService.closeBOL() — 2 N+1 patterns (already well-optimized)

### Quick Wins
- **Eliminate redundant `findById` in `closeBOLs()`** (line 270): Pass ID directly to `closeBOL()` since it re-fetches with `findByIdForUpdate` at line 287 anyway.
- **Consolidate per-pallet `saveAll`** (lines 539-541): Accumulate entities across pallets, issue single `saveAll` per type after the loop.

### New Repository Methods Needed
- None

**Estimated reduction:** Minor (closeBOL is already optimized)

---

## Implementation Priority Order

| # | Change | Files | Effort | Impact | Risk | Status |
|---|--------|-------|--------|--------|------|--------|
| 1 | Use `transferStockToUnitLoad` return value in clubline | CustomerorderBatchService | Low | -300 queries | Very Low | **DONE** ✅ (`0d2bcee`) |
| 2 | Bulk-update replenish priority | ReplenishOrderJobService, ReplenishorderRepository | Low | -2*N*levels queries | Low | **DONE** ✅ (`0d2bcee`) |
| 3 | Batch stockunit fetch in `isEnoughStockOnTransferLane` | TransferOrderService | Low | -N queries | Low | **DONE** ✅ (`0d2bcee`) |
| 4 | Eliminate redundant `findById` in `closeBOLs` | BillofladingService | Low | -N queries | Very Low | **DONE** ✅ (`0d2bcee`) |
| 5 | Batch `mapStockUnitsToItemData` in clubline | CustomerorderBatchService | Medium | -600 queries | Medium | **DONE** ✅ (`4a0e876`) |
| 6 | Reuse carrier data in transfer line UL | TransferOrderService | Low | -N queries | Low | **DONE** ✅ (`4a0e876`) |
| 7 | Bulk pre-fetch for `releaseOrder` second loop | ReleaseOrderJobService, UnitloadRepository | Medium | -7F queries/order | Medium | **DONE** ✅ (`4a0e876`) |
| 8 | Pre-fetch context for FLA generation | ReplenishOrderJob, ReplenishOrderJobService | Medium | -6*N queries | Medium | **Deferred** — each FLA generation runs in `REQUIRES_NEW` transaction; pre-fetched entities become detached in the inner transaction. Solvable with read-only context passing, but lower ROI vs items 1-7. |
| 9 | Pass TransferContext to `transferStockToUnitLoad` | StockunitBusinessService, CustomerorderBatchService | High | -900 JPQL queries (L1 cache already handles ~1,500 of the 2,400) | Medium | **Deferred** — Hibernate L1 cache within `@Transactional` already mitigates ~60% of redundant `findById` calls. Only JPQL queries (`findByUnitloadId`, `findByCarrierunitloadId`) bypass L1 cache. Net remaining cost is ~3 queries per call (~900 total for 300 calls). If profiling shows this is still a bottleneck, a `TransferContext` object can be added as a targeted fix (Option C). |
| 10 | Consolidate per-pallet `saveAll` in closeBOL | BillofladingService | Low | 3 calls vs 3*P | Low | **DONE** ✅ (`4a0e876`) |

---

## New Repository Methods Added

- `ReplenishorderRepository.updatePriorityByIdIn(Collection<Long> ids, int priority)` — `@Modifying` bulk UPDATE (item 2)
- `UnitloadRepository.findByStoragelocationIdIn(Collection<Long> locationIds)` — bulk fetch by location (item 7)

## Test Results

- Full suite: 3774 tests, 10 failures, 56 errors — **all pre-existing, no new regressions**
- Affected test files updated: `ReplenishOrderJobTest`, `TransferOrderServiceUnitTest`, `CustomerorderBatchServiceUnitTest`, `BillofladingServiceUnitTest`, `ReleaseOrderJobServiceUnitTest`

## Estimated Total Query Reduction

| Hot Path | Before | After | Savings |
|----------|--------|-------|---------|
| `releaseOrder()` (per order with 20 fix positions) | ~240 | ~6 bulk | **97%** |
| `runClubLine()` (50 orders × 6 SKUs) | ~3,620 | ~1,220 (items 1,5 done; 9 deferred) | **66%** |
| `isEnoughStockOnTransferLane()` | ~N per-UL | 1 bulk | **~95%** |
| `updateReplenishmentOrderPriority()` | ~2*N*levels | 1 per level | **~95%** |
| `closeBOL()` | Already optimized | 3 saveAll vs 3*P | **Minor** |
| `getTransferLineUnitLoads()` | ~N carrier re-fetch | 0 (cache reuse) | **~100%** |

## Status: COMPLETE (8 of 10 items implemented, 2 deferred with justification)
