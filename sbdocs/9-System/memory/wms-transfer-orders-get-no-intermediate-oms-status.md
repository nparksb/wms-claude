---
name: wms-transfer-orders-get-no-intermediate-oms-status
description: A transfer order's OMS lifecycle is IMPORT then SHIPPED and nothing between; runTransfer skips the picking-status enqueues club's finalizeClubLine performs
metadata:
  type: project
---

SBDEV-3311, measured 2026-09-10 on WineCo prd (v1). **A transfer order's entire OMS lifecycle is
`ORDER_BATCH_IMPORT` → `ORDER_BATCH_SHIPPED`, with nothing in between** — no PICKING_RELEASED /
STARTED / FINISHED, no QA_FINISHED, no PALLETIZED, no LOADED_TO_TRUCK. Order `695571` had 26 hours of
silence between the two rows. Positive control: a `PICK_PACK` order from the same tenant and days
returns four process types via the identical pattern. Both transfer types affected — **588 finished
transfer batches** on WineCo prd (294 intracompany + 294 offsite).

**Cause — the club asymmetry. Both flows write the SAME batch state `ORDER_BATCH_CLUB_RUN_FINISHED` (530):**

- `CustomerorderBatchService.finalizeClubLine` sets it **and** enqueues 3 notifications per CO, in-tx,
  with ascending outbox ids for ordering (SBDEV-2381). Club orders are never picked individually, so
  the run step synthesizes what the picking path would emit.
- `BillofladingService.transferOrder` sets `customerOrder → PACKED` and the same batch state, and
  enqueues **nothing**. Transfer orders also bypass the normal picking path (moved to a lane and
  "run"), so nothing else emits them either.

**Method note: when a WMS flow looks under-notified, diff it against CLUB.** Club is the
high-volume exercised sibling and it reuses transfer's state constants (and vice versa), so
asymmetries between `finalizeClubLine` and `transferOrder` are real defects rather than design
differences. This finding came from that comparison after three other framings failed.

Fix = mirror `finalizeClubLine`'s enqueue block. Open contract question: a transfer is genuinely not
picked, so RELEASE/STARTED may be semantically wrong for it even though FINISHED is needed — ask OMS.

Related: [[wms2-transfer-completion-roundtrip-never-fired]] (the intra-company ACCEPT_TRANSFER round
trip, which has never been exercised and is therefore NOT the reported symptom).
