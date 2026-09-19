---
name: wms2-canceled-is-not-beyond-packed
description: "wms2 states four \"past the cancellation boundary\" guards; two exclude CANCELED correctly and two don't — SBDEV-3363"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0a3c8a18-078e-4915-af56-c67bd7a21d3d
  modified: 2026-09-15T16:51:20.085Z
---

`PACKED = 650`, `FINISHED = 700`, `CANCELED = 800`. **CANCELED is not further along the pipeline — it is
off it.** A guard meaning *"too late to cancel"* must exclude 800. wms2 states this rule correctly twice
and breaks it twice, all in the cancel path (measured on `origin/develop` 2026-09-15, SBDEV-3363):

| site | guard | correct? |
|---|---|---|
| `CustomerorderService.isShippedOrPastCancellationBoundary` | `>= FINISHED && != CANCELED` | ✅ |
| `CustomerorderService.cancelOrder` inline | `>= PACKED && < CANCELED` | ✅ |
| `CustomerorderPositionService.canOrderPositionBeCancelled` | `>= PACKED` | ❌ the question |
| `CustomerorderPositionService.cancelOrderPosition` | `>= PACKED` | ❌ the action, and it **throws** |

**The trap:** fixing only the predicate is worse than not fixing it. `cancelOrder`'s happy path loops
`cancelOrderPosition` over every position, so relaxing only the question flips the order onto the true
branch and then throws `BusinessException("order position is beyond status PACKED")` on the first
already-cancelled position — and `rollbackFor` includes `BusinessException`, so the whole heal rolls back.
A silent strand becomes a rolled-back 400.

`BillofladingService`'s `getState() >= PACKED` ("has already been transferred") is **correctly** open-ended
— different question, where CANCELED *is* a yes. Same literal, opposite right answer.

Neither helper has an HTTP route (no controller injects `CustomerorderPositionService`), so the band change
alters no API contract. Related: [[blast-radius-is-the-predicate-not-the-symptom]],
[[java-state-constant-has-three-spellings]], [[a-guard-fences-the-mechanism-you-aimed-at]].
