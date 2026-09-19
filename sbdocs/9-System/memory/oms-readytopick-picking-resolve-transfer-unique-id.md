---
name: oms-readytopick-picking-resolve-transfer-unique-id
description: "SETTLED on dev 2026-09-11 — OMS readytopick and picking DO resolve a transfer CO's unique_id (processed:1/total:1); the SBDEV-3311 javadoc's open question is answered YES"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0aef6eaa-fc83-4b38-8a7c-84210c5c6254
  modified: 2026-09-11T13:26:28.453Z
---

**SBDEV-3311's shipped code carries an open question in its own javadoc** (`WmsConstants`
`SYSTEM_PROPERTY_WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED_KEY`): *"whether an OMS `parcel`
row resolves from a transfer CO's `unique_id` at all … If it does not resolve, enabling this buys
nothing."* It said the question needed "an OMS database or one UAT round trip on a single tenant".

**Answered on dev 2026-09-11 (wineco/wsl, `dev_wh01_om1`), build `develop-34b897c8`. It resolves.**
Both endpoints returned HTTP 200 with an OMS body reporting it matched and updated a parcel:

| leg | OMS answer |
|---|---|
| `…/services/call/readytopick` | `{"Status":"Success","Message":"All parcels marked as ready to pick","Result":[],"processed":1,"total":1}` |
| `…/services/call/picking` | `{"Status":"Success","Message":"All parcels marked as picking","Result":[],"processed":1,"total":1}` |

**`processed:1, total:1` is the load-bearing field, not the 200.** Per the same javadoc, these
endpoints return through `legacyVerdictResponse($data)`, which defaults to **200 with the errors in
the body** — so a 200 alone proves nothing and `SENT` in `outbox_message` proves less. `processed:1`
is OMS's own accounting that it resolved one parcel from the payload. A failure to resolve would show
as `processed:0` or entries in `Result[]`.

⚠ **Still not independently confirmed:** the parcel's `parcel_status` column was not read — this is
OMS's self-report, not a DB observation. Strong, specific, and it contradicts the
"may not resolve at all" hypothesis, but if the distinction matters, read `parcel` on dev OMS.

Payload shape (identical for both legs, built by `ManageOrderService.buildPickingStartedPayloadJson`):
`{"positions":[{"unique_id":"571036"}],"facility_code":"WSL","batch_id":"TR-20260821-002"}` —
`unique_id` is `Customerorder.externalnumber`, `batch_id` is `CustomerorderBatch.batchid`.

**What this unblocks:** the javadoc named this an *unknown, not an accepted cost*, and made it a
pre-enablement question. It is now answered for the readytopick/picking pair. The other stated
pre-enablement blocker (M-A, the double-`runTransfer` idempotency-key collision) was **fixed in the
same PR** and verified live — so both of the gate's stated reasons to stay off have been discharged
on dev. Enabling per tenant is now a decision, not a research task.

Related: [[wms-transfer-orders-get-no-intermediate-oms-status]] (the defect),
[[wms2-transfer-completion-roundtrip-never-fired]] (the separate ACCEPT_TRANSFER round trip, still
never exercised), [[wms2-outbox-dispatcher-status-blind-silent-loss]].
