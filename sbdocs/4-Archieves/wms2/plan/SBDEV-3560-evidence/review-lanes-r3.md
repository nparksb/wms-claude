---
ticket: SBDEV-3560
tier: T2 (whole family, one PR — Nam 2026-09-28)
reviewed_commit: e58d08e (wms2-web-ui)
date: 2026-09-28
---

# SBDEV-3560: review lanes, round 3

The subagent lanes can't write files, so the author has recorded their results here.

## Lane 1: code-reviewer (opus). Verdict: REQUEST CHANGES

Evidence: 271/271 sweep tests pass on e58d08e. Against the parent code (34fcbaa), 76 fail and all 8 suites are red. 13 of 14 hand mutants were killed; M13 survived (see Low).

| Sev | Finding | Disposition |
|---|---|---|
| High | `closeOutbouldBols`: when every BOL fails, `BillofladingBatchService.closeBOLs` throws a single aggregate error ("All BOLs failed to close…", field "Runtime Error"), so `errors.length < ids.length` wrongly reports a partial success. The test fixture used a shape the server never sends | Round 4, lane H |
| High | `deleteOpenNoticeReceipt` is a real multi-select batch (per-id loop, partial commits) but missed the batch rule, so every retry fails with EntityNotFound on the first id already deleted | Round 4, lane G |
| Medium | Same batch-rule gap in `adjustAmountOpenNoticeReceipt` | Round 4, lane G |
| Medium | Same batch-rule gap in `cancelCycleCountPop`, and a partial result doesn't refresh | Round 4, lane H |
| Medium | `updateStockUnitPop` round-3 change switches on a feature that has never worked (a stock-reservation move). `redirectSource` has no state guard and an inverted reserved-amount check | **Nam decided 2026-09-28: revert to develop and propose a T3 ticket.** Round 4, lane H |
| Medium | Input is still cleared after a refusal in `updateBound.vue`, `moveFixedLocation.vue` (whose catch also throws a TypeError) and `receivingForm.vue` (`receiveInboundItems`) | Round 4, lanes G/H |
| Low | Confirmation dialogs with no typed input still close on a refusal | **Nam 2026-09-28: excluded and recorded** (list below) |
| Low | Unrequested toast/refresh changes compared with develop | All accounted for: every one is required by the fix or benign (reprint no longer toasts twice on success) |
| Low | The refresh in `closeOpenInboundNotice` on a partial close is not pinned (M13 survived) | Round 4, lane G |
| Low | An empty selection leaves 3 batch dialogs open silently | No change. The UI can't reach it, because the multi-action buttons are disabled when nothing is selected |
| Low | `closeMultipleInboundBol` calls `orElseThrow` outside the try, so a concurrently deleted advice aborts the request after earlier ids have committed | Backend. Proposed, not filed (below) |
| Low | The `closeOutbouldBols` comment was false for the all-fail case | Round 4, lane H |

Verified in round 3: all 13 H2 and sweep sites are gated. No success body is misread as a refusal. The cancelRequestPop tests are order-sensitive, including the mutant killer.

## Lane 2: verifier (sonnet), STORE-side instrument. Verdict: PASS for the diff, INCOMPLETE for the family

The instrument was new: it enumerates every write action (~128) and classifies each caller as GATED, NO-DISMISS or DEFECT. For its positive control it classified editRole as GATED on HEAD and DEFECT on origin/develop. A global scan for dispatches to actions that don't exist found no live hits. 5 of 5 round-3 mutants were killed.

- **In scope (fixed in round 4):** receivingForm `receiveInboundItems`, and fixedLocation `toggleActiveStatus`, whose store never reads the error envelope and always reports success.
- **`updatePriority` has no `errors` check:** no change. The reviewer's reading of the API is that `ReplenishOrderController.updatePriority` has no 200-with-errors path, and its exceptions surface as HTTP errors, which the catch handles.
- **`moveFixedLocation` commits a `setShowDialog` mutation that doesn't exist,** so even a successful move never closes its dialog. It's sub-T3 and in a file we're already changing, so it goes onto this ticket, round 4, lane H.

## Excluded, and why (Nam 2026-09-28: no typed input, and no refusal is presented as a success)

These dialogs are only confirmations with no typed input, or they report the outcome elsewhere:
- `admin/systemManagement/actionConfirmation.vue`: the 4 background triggers. Their toast says the job "started", and the real result arrives later.
- `recoverStuckPallets.vue`: the confirm sub-popup.
- The export popups: `exportCyclePop.vue`, `exportBolPop.vue`, and the `storageLocation.vue` export confirm.
- The delete confirmations in `fixedLocation.vue`, `sections/section.vue`, `storageLocations/storageLocation.vue` and `packaging/packaging.vue`.

## Proposed, not filed (T3, for Nam)

1. **Enable "Change Source Stock Unit" (`updateStockUnitPop`).** It has never worked, because it dispatches an action that doesn't exist.
   - The fix is to dispatch `updateSourceStockUnit`, which posts the same payload to the same endpoint.
   - It needs a backend state guard in `ReplenishorderService.redirectSource`, because a STARTED order that is being picked can currently have its source moved.
   - It also needs the inverted reserved-amount guard fixed: the check is `ZERO.compareTo(reserved) > 0`, so it throws only when the reservation is negative.
   - Blast radius: stock reservations on replenishment orders. Cost: a small backend change, the UI one-liner, and ITs.
   - This is authorisation/data integrity, hence T3.
2. **(Low, backend) `AdviceController.closeMultipleInboundBol` calls `orElseThrow` outside the per-id try.** A concurrently deleted advice aborts the batch as an HTTP error after earlier ids have committed, so the UI cannot tell that anything was applied. The fix is to move the lookup inside the try and report it as a per-id error. Cost: one method plus a test. I'd rank it below item 1.
