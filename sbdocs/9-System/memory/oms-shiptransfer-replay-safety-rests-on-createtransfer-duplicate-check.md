---
name: oms-shiptransfer-replay-safety-rests-on-createtransfer-duplicate-check
description: OMS finishedShipping for a transfer calls destination createTransfer BEFORE its already-shipped check; replay is safe only because wms2 createTransfer rejects ANY existing transfer_id
metadata:
  node_type: memory
  type: project
  originSessionId: a929abe8-f111-4992-8a63-d5b644afd391
  modified: 2026-10-11T22:26:40.509Z
---

oms-laravel-api `LegacyTransferShipService::shipTransfer` (from `finishedShipping` for TRANSFER_INTRACOMPANY) calls `WmsApiService::createTransferAdviceFromBol` on the destination WMS *before* checking `ALREADY_SHIPPED_STATUSES`. A late or replayed ORDER_BATCH_SHIPPED is harmless only because wms2 `AdviceRestController.createTransfer` refuses any existing transfer_id, whatever its state (`adviceRepository.findByTransferId` → ENTITY_ALREADY_EXITS), and OMS's `isDuplicateTransferAdvice` maps that to success. OMS `completeTransfer` sets the parcel to DELIVERED (18), which is in ALREADY_SHIPPED_STATUSES, so `transferInitiate` is skipped.

**Why:** SBDEV-3728 (PR #504, 2026-10-11) made finishTransfer enqueue ORDER_BATCH_SHIPPED after OMS has already completed the transfer, relying on this. An architect consult wrongly predicted a phantom advice; the claim was refuted with the code above.

**How to apply:** if anyone narrows createTransfer's duplicate check (for example to OPEN advices only), the late notification would create a phantom inbound advice at the destination. Treat that check as a cross-repo contract. Related: [[oms-readytopick-picking-resolve-transfer-unique-id]].
