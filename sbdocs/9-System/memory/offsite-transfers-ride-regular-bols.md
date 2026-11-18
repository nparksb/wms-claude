---
name: offsite-transfers-ride-regular-bols
description: On WineCo PRD ALL transfers (305 intra-company + 325 offsite) ship on REGULAR BOLs — the normal flow; never refuse it. SBDEV-1564 rule is Transfer-BOL-only.
metadata:
  type: project
---

Measured 2026-10-26 on **WineCo PRD (`wsl-wineco-prd`, `wh01_om1_v2`)**: every TRANSFER_INTRACOMPANY batch — **305 batches on 178 REGULAR BOLs**, 2025-08-07 → 2026-10-22, 304 finished at state 700 — and **325 TRANSFER_OFFSITE batches** shipped on REGULAR BOLs. WineCo has **never** used an intra-company Transfer BOL; only 5 offsite Transfer BOLs ever. No transfer-process `message` rows (ADVICE_TRANSFER_* / ACCEPT_TRANSFER) exist on v2 PRD at all. DEV (`dev_wh01_om1`) has only 2 intra-company batches, so it hid this.

**Why it matters:** SBDEV-1564's first cuts refused transfers on non-transfer BOLs (symmetric, then intra-company only). Both would have stopped WineCo's live floor flow; caught only by the PRD census after #568 was already on dev, fixed in a follow-up PR. Switching WineCo to intra-company Transfer BOLs would be worse: those close to TRANSFER and wait for a destination accept that has never fired in v2 ([[wms2-transfer-completion-roundtrip-never-fired]]).

**How to apply:** before tightening any transfer/BOL/batch-type rule, run the bol_type × batch_type census **on PRD** (WineCo PRD is the high-volume tenant), not just DEV: join billoflading → billoflading_position.orderposition_id → customerorder_position → customerorder → customerorder_batch. Final SBDEV-1564 rule: a Transfer BOL carries only its own transfer; non-transfer BOLs unchecked. Open: proposal P25 (does OMS fully book transfers shipped on REGULAR BOLs).

**P25 / SBDEV-3928 answer (code, 2026-10-27):** OMS's REGULAR path DOES resolve a transfer parcel (WMS order unique_id = OMS parcel id) and `shipParcel`'s `IF(fulfillment_id=6 AND transfer_destination IS NULL, DELIVERED, SHIPPED)` makes OFFSITE end at DELIVERED (fine). INTRA-COMPANY ends at SHIPPED(4): no destination advice, no initiateTransfer, no quantity_in_transfer. Identical in v1's `parcelShip` SP, so it is not a v2 regression. Unverified in OMS data (no OMS DB access from here).
