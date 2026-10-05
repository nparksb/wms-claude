---
name: wms2-parcel-source-guard-sbdev-3353
description: "SBDEV-3353 (PR #416 MERGED 27280283, on dev 2026-09-24) — operator stock moves out of a Package are refused by SourceContainerGuard at 6 sites; a callee-based route sweep missed Transfer to Damaged"
metadata:
  node_type: memory
  type: project
  originSessionId: dc9fb8a8-b7c9-4dd6-ab5c-0a9c2454db03
  modified: 2026-09-24T10:19:30.121Z
---

SBDEV-3353 (wms2-api PR #416, merged to develop as `27280283`, deployed to dev and confirmed via /api/public/version, 2026-09-24; not yet on UAT or PRD) refuses every **operator** stock move whose source container is a `Package` (parcel). The refusal is `SourceContainerGuard`, key `transferStockSourceIsParcel`, called at 6 sites:
- `StockunitService.transferStock` (top)
- `StockunitService.setLockDamaged`
- `CancellationReversalService.completeReversal` (pre-validate)
- `MobileTransferOrderService.transferStock`
- `MobileMoveUnitloadService` (stock-move arm)
- `MobilePutAwayService` (flow-bin arm)

Package also left `UnitloadService.TYPES_THAT_REST_IN_A_STORAGE_LOCATION`. Nam's decisions: type-only; no CANCELED exemption; `handleTruckOffLoading` and `adjustAmount` deliberately unguarded. Whole-parcel relocation is split to ClickUp 868m9914u.

**Why it matters:** draining a parcel sends it to Nirvana via `relocateEmptiedContainer`'s `default:`. That is irreversible, and `customerorder.parcel_id` and the BOL still point at it.

**How to apply:**
- Before adding any new caller that moves stock out of a unit load, check whether it can see a Package, and call the guard at operator entry points. Never put it inside `transferStockToUnitLoad`: packing and BOL use that method on Packages.
- **Route sweeps keyed on a callee miss routes that reach the same outcome another way.** The architect's sweep from `transferStock` missed `/transferToDamaged` (`setLockDamaged` → `moveStockToNewDamagedContainer`), the one live Nirvana path. Both review lanes found it independently. Sweep by **outcome** (every `transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)` reachable from a controller), not from a single entry method. See [[a-guard-fences-the-mechanism-you-aimed-at]].
- **Don't add an in-transaction `findById` "fresh re-read" before a later `findByIdForUpdate` on the same row.** It turns the lock read into a lock upgrade; see [[findbyidforupdate-throws-at-the-lock-read-not-at-flush]]. Read the needed columns as scalars instead: `findUnitloadIdsByIdIn`, `UnitloadRepository.findParcelGuardViewById`.
