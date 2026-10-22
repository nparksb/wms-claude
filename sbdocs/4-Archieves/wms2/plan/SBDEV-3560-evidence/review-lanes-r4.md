---
ticket: SBDEV-3560
tier: T2
reviewed_commit: ba157ae (delta e58d08e..ba157ae); fixes in 165a973
date: 2026-09-28
---

# SBDEV-3560: round-4 review (opus). Verdict: COMMENT, no blockers

All 8 claims made in round 4 were checked against the Java on origin/develop and hold:
- **Aggregate BOL error:** a batch where every BOL fails comes back as one "Runtime Error" entry; a partial failure comes back as one "BOL <id>" entry per failed BOL.
- **Per-id errors:** the goods-receipt delete/adjust and cycle-count cancel endpoints return one error per refused id.
- **Receive:** refusals inside the controller's try come back as a 200 with an `errors` body.
- **`fixedLocation.js`:** it reads the full axios response, so `.data` is correct there. `setShowMoveDialog` is a real mutation.
- **Revert:** `updateStockUnitPop` is byte-identical to develop, and so is `updateSourceStockUnit`.

The specs were also run against the e58d08e (pre-round-4) source: 31 fail, 193 pass. Every one that still passes is a success-path lock-in or a regression pin, with one exception, M1.

| Sev | Finding | Disposition (165a973) |
|---|---|---|
| Medium M1 | Nothing caught dropping `String()` from the bare-id count, because the only bare-id test was a refusal | **Fixed.** Added a test where one bare-number id succeeds and must resolve true. The mutant is now killed, for both delete and adjust |
| Medium M2 | The goods-receipt delete/adjust controllers look each id up with `findById` outside the per-id try (the cycle-count cancel controller does the same). If a stale id comes back 404 after earlier ids have committed, the UI can't see that anything was applied, and the receipt table stays empty | **UI half fixed:** the catch now reloads the receipt table, or the planned list for cycle counts. Mutants killed ×3. **API half proposed**, see below |
| Low L1 | Two tests pin response shapes the server can't produce | Relabelled as defensive |
| Low L2 | The `errors` branch in `toggleActiveStatus` can never run | Comment now says it's defensive; the real refusal path is a 422 |
| Low L3 | The array branch in `cancelCycleCount` can't work, because the server would split `"[1"` and fail | Dropped; ids are now counted with `String(ids).split` |
| Low L4 | Cycle-count test fixtures use a message the server never sends | Now uses "unknown status 3" |
| Low L5 | The `receive.js` comment overstated what the server does: the casts sit outside the try, so a bad payload gets a 500 | Comment corrected |
| Low L6 | `deleteFixedLocation` commits `removeDeletedSection`, which only exists in `section.js`. A successful delete never removes its row | Not fixed: the delete-confirmation dialogs were excluded by Nam. Proposed below |

Open questions the reviewer raised:
- **Decimal bounds:** `updateBound` sends `parseFloat`, but the API casts the value to `(Integer)`, so every decimal gets a 500. The operator then retries against a misleading toast. This is an API bug and is proposed below.
- **Double receive:** `receivingForm` now keeps the typed values after a network error. If the server had in fact committed the receive before the timeout, clicking again receives the goods a second time. This is the direct cost of keeping input. It is worth Nam knowing about, because receiving creates stock.

## Proposed, not filed (add to the r3 list)

3. **(API, Medium) Out-of-loop `orElseThrow` in batch endpoints.** Found in `GoodsReceiptPositionController` delete/adjust (the `findById` lookups), `CycleCountController.cancel` and `AdviceController.closeMultipleInboundBol`. A missing id aborts the request with a non-2xx after earlier ids have committed, so the UI cannot tell anything was applied.
   - Fix: move the lookup inside the per-id try and report a missing id as a per-id error, the same pattern as SBDEV-2632.
   - Cost: 4 methods plus ITs.
   - This supersedes r3 item 2.
4. **(API, Low) `FixLocationAssignmentController` set*Bound casts the value to `(Integer)`.** Any decimal bound gets a 500.
   - Fix: parse it as a number, or reject decimals in the UI.
   - This one is sub-T3, but the host ticket would be an API ticket.
5. **(UI, Low) `store/masterData/fixedLocation.js` `deleteFixedLocation` commits `removeDeletedSection`, a mutation that doesn't exist.** So a delete succeeds but its row stays until the page reloads. It's a one-line fix (dispatch `getFixedLocations`). It is left out of 3560 only because Nam excluded the delete confirmations.
