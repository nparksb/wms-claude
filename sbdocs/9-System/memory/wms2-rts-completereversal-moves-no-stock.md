---
name: wms2-rts-completereversal-moves-no-stock
description: "RTS \"complete\" stamps the timestamp and notifies OMS but moves zero stock — picktounitload_id is an FK to pickingorder_unitload, not unitload"
metadata: 
  node_type: memory
  type: project
  originSessionId: cafcc809-95cd-4f7f-ad6f-7439a6660c6e
  modified: 2026-09-11T00:53:52.607Z
---

**v2 Return to Stock (RTS) has never moved stock.** `CancellationLogService.recordCancellation`
calls `stockunitRepository.findByUnitloadId(pickingPosition.getPicktounitloadId())`, but
`pickingorder_position.picktounitload_id` is an FK to **`pickingorder_unitload`**, not `unitload`
(PRD constraint `fklm74sp508ly1vn9ui6hfnhw0a`). The code skips the `.getUnitloadId()` hop the rest
of the codebase makes, so `picktostockunit_id` always lands NULL — and
`CancellationReversalService.completeReversal()` moves stock only `if (picktostockunitId != null)`.

Net effect: completing RTS stamps `reversal_completed_at`, fires `ORDER_BATCH_REVERSAL_COMPLETED`
to OMS, and **moves nothing**. Silent divergence, worse than a hard failure.

Measured 2026-09-10:
- Hydra PRD: 16 rows, `picktostockunit_id` NULL on **all 16**, 7 pending, **0 ever completed or
  even initiated**; 63 units stranded on T-0002 (41 days) and T-0007 in `FinishedPicking`.
- wineco-dev: **4 reversals actually completed** 2026-05-28/29 by `sbtest`/`panderson` — the day
  SBDEV-1921 merged — every one with `picktostockunit_id = None`. That is how it shipped: the flow
  returned green and nobody checked whether stock moved.
- Positive control per row: wrong hop → 0 stockunits; correct hop via `pou.unitload_id` → 4 and 3.

**Why:** FILED 2026-09-10 as **SBDEV-3316** (Urgent) at Nam's direction. Two blockers, both
required: SBDEV-3264 is the UPSTREAM one (operators cannot reach the completion step) and 3316 the
DOWNSTREAM one (completing it moves nothing). Roadmap context is SBDEV-3313.

No FK exists on `customerorder_cancellation_log.picktounitload_id` — only `customerorder_id` and
`customerorder_position_id` are constrained — which is why a wrong-table id persisted cleanly.
Hydra PRD's `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` also points at the UAT OMS; folded into 3316
because it fires the moment reversals start completing.

**How to apply:** fixing the hop does NOT repair the 16 existing rows — they are already written
with NULL and need backfill from `pickingorder_unitload`. Never read `reversal_completed_at` as
evidence that stock moved. Related: [[green-tests-that-prove-nothing]],
[[advertised-capability-is-not-exploitable-capability]], [[tote-reuse-nonunique-optional-finders]].
