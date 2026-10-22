---
name: sbdev-3086-stockunit-nontransactional-write-paths
description: SBDEV-3086 SHIPPED + archived — the 3 StockunitService entry points stay unannotated by design; the boundary is UnitloadService.moveStockToNewDamagedContainer, its FIRST ever
metadata:
  type: project
---

Merged 2026-08-26 and archived: `206ad9ed` (wms2-api #198), `d3fb6ac` (wms2-web-ui #79),
`98060c99` (wms2-api #203 — the D8 regression pin). Plan at
`sbdocs/4-Archieves/wms2/plan/SBDEV-3086-stockunit-nontransactional-write-paths.md`.

**The design point that is easy to get wrong:** `setLockDamaged` (`:413`), `adjustAmount` (`:485`)
and `removeLock` (`:565`) are **still not `@Transactional`, deliberately.** The fix did not wrap
them. The boundary is `UnitloadService.moveStockToNewDamagedContainer` (`UnitloadService:157`) —
**`UnitloadService`'s first and only** `@Transactional` ever, so the bean is newly proxied. Two
mechanics break silently if "tidied":
- the label is minted **outside** the boundary (`mintUnitloadLabel()`), because the sequence write is
  `REQUIRES_NEW` and must not run inside a lock-holding tx — see
  [[wms2-requires-new-in-lock-holding-tx-deadlock]];
- the helper is called **cross-bean** via `unitloadService`, never `this.`, or the advice evaporates.
Scoping it to the helper keeps `triggerReplenishmentMaintenance` outside, so the
`ReplenishmentOrderMaintenanceService:126-135` rollback-only hazard stays unreachable.

**Live-verified on dev** (wineco/wsl → `dev_wh01_om1`): F5 returns `{requested, succeeded, errors}`
with per-item outcomes; D7 omits `errors` entirely on total success; gates enforce (403 for a user
lacking the function). Pre-deploy the same call returned **HTTP 500 while the write committed** — F5
closed a silent-write defect, not just bad ergonomics.

**Do not "clean up" the id interpolation in `errors[].field`** — it is pinned by
`StockUnitControllerUnitTest.bulkSetLockOnHold_failingId_isFoldedIntoField`. `errors[].id` feeds the
UI's `failedIdsFrom()` grid-narrowing (load-bearing: `setLockDamaged` is NOT idempotent), while
`field` is the only place the operator sees the id, because `commonUtility.js:11` renders
`${field}: ${message}` and never reads `id`.

**Known gap, pre-existing:** `bulkTransferToDamaged` 500s when `amount` is omitted —
`Integer.parseInt(null)` throws, then the catch calls `Double.parseDouble(null)` which NPEs uncaught
at `StockUnitController:572-573`, before the F5 loop. Out of scope, not filed.
