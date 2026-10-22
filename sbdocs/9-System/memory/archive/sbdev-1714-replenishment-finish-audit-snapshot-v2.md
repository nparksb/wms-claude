---
name: sbdev-1714-replenishment-finish-audit-snapshot-v2
description: "SBDEV-1714 (finished replenishments lose audit data) is present in v2 too, not just v1; root cause + drafted v2 fix plan"
metadata: 
  node_type: memory
  type: project
  originSessionId: 53f5fd51-a145-4a4e-b029-db9ecc811ec6
  modified: 2026-07-24T16:32:12.479Z
---

SBDEV-1714 "Finished Replenishments Not Keeping Data/Drifting" — filed on v1, but **confirmed present in WMS v2** on wms2-wineco-dev: 164 of 168 FINISHED (state=700) replenishorders show source UL = `Nirwana` and Stock Unit Amount = 0 (matches v1 REPL052269 exactly).

**Root cause (same both versions):** a closed `Replenishorder` never snapshots what moved — it keeps only a LIVE FK to the source `stockunit_id` + creation-time fields (`requestedamount`, `sourcelocationname`). `MobileReplenishService.finishReplenishmentOrderInternal` (:428, the single finish choke point — also serves the multi-UL `fulfillMultipleUnitLoads` path via `finishReplenishmentOrderWithoutRefill`) only sets state=FINISHED (:501-502). Detail (`findDetailMapById` `su.amount as stockUnitAmount`) and list queries (`u.labelid as unitload`) read live, so after the source drains they show 0 / `Nirwana`.

**KEY landmine:** `transferStockToUnitLoad` (:498) mutates the source stockunit's `unitloadId` IN PLACE — full move re-homes it to the DESTINATION UL (`StockunitBusinessService:346`), partial-drain-to-zero sends it to Nirvana (:380/:422). So any snapshot code MUST read the source UL label BEFORE :498, not before setState at :501. (The first plan draft got this wrong; ralplan Architect caught it.)

**Fix (MERGED 2026-07-24 — wms2-api PR #83 → develop, merge commit 50b4435; impl commit 393bf8f; ClickUp SBDEV-1714 moved pr submitted→on dev):** plan `sbdocs/4-Archieves/wms2/plan/SBDEV-1714-replenishment-finish-audit-snapshot.md` + verify script `sbdocs/9-System/scripts/verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh`. v2-only, forward-only (164 legacy rows can't be faithfully backfilled). Add 4 nullable cols to `replenishorder` (Flyway V2.2.03): moved_amount, moved_source_unitload_label, moved_destination_unitload_label, moved_destination_location_name; capture pre-transfer; detail/list reads COALESCE frozen over live. Chose columns over a stockrecord read-time join because `recordRemoval`(:376) carries no from/to UL on the partial branch — unreliable exactly on the drained-to-zero bug rows. UI display switch = wms2-web-ui follow-on (out of scope). v1 paired plan = candidate, not started. Posted v2-confirmation comment on the ClickUp ticket 2026-07-20. Related: [[wms2-requires-new-in-lock-holding-tx-deadlock]], [[sbdev-2074-nonreplenishable-move-reservation-gap]].

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

v2 had it too (164/168 on wms2-wineco-dev show Nirwana/0); closed Replenishorder never snapshotted the move, read live source stockunit; LANDMINE: transferStockToUnitLoad(:498) re-homes source UL in place so capture BEFORE it; IMPLEMENTED 2026-07-20 → wms2-api PR #83 into develop (Flyway V2.2.03 + 4 snapshot cols, forward-only)
