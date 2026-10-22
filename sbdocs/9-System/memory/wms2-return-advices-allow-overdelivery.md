---
name: wms2-return-advices-allow-overdelivery
description: "Every v2 RETURN advice has allowoverdelivery=true (AdviceRestController sets it), so the receiving over-delivery guard never fires for returns"
metadata:
  node_type: memory
  type: project
  originSessionId: 5c546a63-0c40-49e3-81ef-0430ab89e322
  modified: 2026-10-15T18:46:50.457Z
---

`AdviceRestController` create sets `adviceEntity.setAllowoverdelivery(true)` for RETURN advices. On WineCo PRD (2026-10-15), all 2,822 RETURN advices have `allowoverdelivery = true`, and none has `false`. So the over-delivery guard in `ReceivingService.receiveGoods` is skipped for every return, and a dock mis-key can over-receive.

**Why:** the SBDEV-3736 architect consult assumed over-receipt was impossible. Its first S8 design (finish an advice at received ≥ notified) would have finished an advice on a mis-key and locked it, because Adjust/Delete refuse a FINISHED advice. Review M1 caught this, and Nam chose to finish on an exact match only.

**How to apply:** any RETURN-advice logic that compares received to notified amounts must handle received > notified. Never claim "can't over-receive" for returns. Re-query `select type, allowoverdelivery, count(*) from advice group by 1,2` per tenant before relying on it. Related: [[wms2-canceled-is-not-beyond-packed]], [[sbdev-1512-damaged-returns-decisions]].
