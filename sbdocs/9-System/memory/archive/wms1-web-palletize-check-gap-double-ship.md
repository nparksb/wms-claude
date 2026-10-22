---
name: wms1-web-palletize-check-gap-double-ship
description: WMS v1 — web (Outbound Report) palletize path has far fewer checks than mobile; SBDEV-2507 = a real double-shipment; fix belongs in a shared server-side guard
metadata: 
  node_type: memory
  type: project
  originSessionId: 1039835d-246e-4941-bcc5-e63901b61965
---

WMS v1 has TWO palletize paths with different validation depth:
- Mobile: `/v3/palletizing/*` → `MobilePalletizingService.scanParcel/scanPallet` — full checks (order ≥ PACKED, not cancelled/finished, shipping-method compatibility, target is a pallet type, **pallet not already assigned to gate**).
- Web (Outbound Parcel Report → Palletize): `POST /palletize` `BillOfLadingController:316` → `ParcelMonitorViewService.palletise()` — lean: order-not-FINISHED (≥700) + duplicate-truck-load guard only. Client only checks `state >= 670`. Leniency is partly BY DESIGN (no-scanner back-office correction tool) but dropped the safety floor.

**SBDEV-2507 / ST#1023 (WineCo) — ROOT CAUSE = missing guard (code-level, data-independent):** the user used the web UI to create/select another pallet and add parcels to a pallet that was **already truck-loaded (assigned to a gate/BOL)**. Web `palletise` reuses an existing named pallet with NO check (the "already exists" throw is commented out, `ParcelMonitorViewService:110-114`); mobile blocks it via `getBySourceUnitLoadLabelId(palletLabel)` non-empty → `Pallet already assigned to gate!` (`MobilePalletizingService:198-201`). IMPORTANT: the WineCo DB likely has MANUAL FIXES applied — the observed `unitload_record` timeline (parcel 54068/XR1781642381900 on PM-017012→OBOL117374 then OUT-999093→OBOL117390) and current order state (700) are corroborating, NOT authoritative; do not build causal claims on them. A closeBOL "stuck at 670" finalize miss is a possible secondary contributor but unconfirmed (may be a transient/mid-remediation state).

**Fix direction:** #1 add the target-pallet "already assigned to gate/BOL" guard to web `palletise` (mirror mobile), ideally as a shared server-side `assertPalletNotTruckLoaded()`/`assertParcelPalletizable()` used by BOTH services so they can't drift; #2 (verify-first) closeBOL order-state finalize only if reproducible; #3 data remediation. Label patterns: `PM-######` = system-generated, `OUT-######` = manual/scanned.

Full report: `sbdocs/3-Resources/reports/260701-sbdev-2507-repalletize-double-ship-after-closed-bol.md`. Recommendation = Fix now via wms-bugfix-plan. Related: [[SBDEV-2099-outbound-parcel-report-clears-after-palletize]].