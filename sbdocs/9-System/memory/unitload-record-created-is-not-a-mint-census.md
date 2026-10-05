---
name: unitload-record-created-is-not-a-mint-census
description: "unitload_record recordtype=CREATED is also written for closeBOL/finishTransfer shipping transfers, and system locations are typed `overstock pallet` — replaying location_constraint over CREATED rows is noise outside MANUAL_SPLIT"
metadata:
  node_type: memory
  type: project
  originSessionId: ffd93f1b-3f2e-47c8-9ee4-eb0786bdfb64
  modified: 2026-09-26T19:13:01.201Z
---

Measured 2026-09-27 (SBDEV-3356) on all nine v2 DBs:

- `UnitloadRecordService.batchRecordForTransfer` (callers `BillofladingService.closeBOL` + `finishTransfer`) hard-codes `UnitloadRecordType.CREATED` on shipping TRANSFERS into `Shipped`. It came in with `acdafb06` (2026-02-16, the closeBOL bulk optimisation), which replaced `transferUnitLoadToLocation` (that one writes TRANSFERRED). Hydra PRD has 284 CREATED / 0 TRANSFERRED into Shipped. Only effect: the Container Record report shows "CREATED". Nothing in src/main branches on recordtype. The fix was proposed on SBDEV-3356 (T1 code fix, T3 backfill), not filed.
- `InboundWorkstation`, `Palletizing` and `Shipped` are typed `overstock pallet` on every v2 DB, so any location_constraint replay flags receiving/palletizing/shipping wholesale (WineCo PRD RECEIVING 342 364 / 342 364 "refusable").

**Why:** I wrote "group CREATED rows by activitycode = per-route mint census" into a PR javadoc, and the first DB run disproved it.
**How to apply:** scope any constraint replay to MANUAL_SPLIT, or exclude `tolocation='Shipped'`. Never read cross-route "would refuse" counts as real violations. Related: [[a-zero-scan-needs-a-positive-control]], [[derive-cross-repo-claims-from-origin-develop]].
