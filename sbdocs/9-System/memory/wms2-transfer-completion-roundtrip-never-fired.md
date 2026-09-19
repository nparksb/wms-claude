---
name: wms2-transfer-completion-roundtrip-never-fired
description: The intra-company transfer completion round trip (ADVICE_TRANSFER_IMPORT -> ADVICE_ACCEPT_TRANSFER -> ORDER_BATCH_FINISHED_TRANSFER) has never fired once in v2; SBDEV-3311
metadata:
  type: project
---

Measured 2026-09-10 (SBDEV-3311): the WMS<->OMS intra-company transfer completion round trip
has **never run in v2**. All three `message.process` legs — `ADVICE_TRANSFER_IMPORT`,
`ADVICE_ACCEPT_TRANSFER`, `ORDER_BATCH_FINISHED_TRANSFER` — are **0 rows on Hydra prd AND
Hydra UAT**, against an 18-process-type positive control. v1 ShipItEZ prd wrote all three for
the one intra-company transfer ever run there (2022-11-28), so the design is real and once worked.

Two facts that reframe any investigation here:

- **The completion signal fires at the DESTINATION, not the source.** It is
  `ADVICE_ACCEPT_TRANSFER` from `AdviceService.acceptTransferAdvice` -> OMS `.../services/call/closeTransfer`.
  Source-side close only ever emits `ORDER_BATCH_SHIPPED`, so a transfer that shipped looks
  identical to one that completed. `BillofladingService.finishTransfer` (v1 AND v2) enqueues
  nothing and writes no message row.
- **An intra-company transfer can complete without ever having a `TRANSFER_INTRACOMPANY` BOL.**
  On Hydra UAT two such batches reached state 700 riding a **`REGULAR`** BOL. So grepping
  `billoflading.type` for the intra-company flow finds nothing and reads as "never used" —
  check `customerorder_batch.type` instead. Hydra prd has zero intra-company BOLs, so live prd
  exposure is currently nil; it becomes real for the first two-warehouse v2 client (ShipItEZ NY/LA).

Upstream cause is [[wms2-oms-notification-status-blind]]-adjacent but distinct: SBDEV-3268
(`on prod`) fixed the OMS half. See also [[wms2-outbox-dispatcher-status-blind-silent-loss]].

## Resolved 2026-09-10 (SBDEV-3311)

**Source-side silence is the DESIGN, not the bug.** `BillofladingService.finishTransfer` emits nothing
in **v1 too** — the whole 55-line body on v1 `origin/develop` has no `createMessage`, no
`httpRestService`, no sysprop lookup (positive control: the same grep over v1
`AdviceService.acceptTransferAdvice` returns 3). v1 is fully working code, so its silence is evidence.
Completion is **destination-side `ADVICE_ACCEPT_TRANSFER` only**, at both versions. Do not add a
source-side event: OMS already commits on that leg alone — `LegacyTransferCloseService.php` calls
`completeTransfer($parcelId, 1)` and marks the WMS call *"best effort"*.

**The 2022 ShipItEZ transfer was SAME-warehouse, so it proves nothing about cross-DB behaviour.**
`wh02_shipitez` has no data before 2025-06-23 — it came online ~2.5 years after 2022-11-28. That is
why the source BOL and destination advice sat 6 ids apart in one schema. **No real cross-warehouse
intra-company transfer has ever completed in either version** in any reachable DB.

**What IS broken in WMS:** `finishTransfer` guards on BOL *type* only, never *state* — `closeBOL` in
the same class has the state switch it lacks — so it succeeds from all six states and re-runs
`unitloadRecordService.batchRecordForTransfer`, duplicating audit rows. The only path that can re-run
it, `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}`, is the one `IdempotencyFilter`
skips: `shouldNotFilter` returns true for **any GET** before it tests `/rest/`. T1-T2, not T3.
