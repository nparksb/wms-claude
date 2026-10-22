---
title: "c1wh Pending Reversals — Why and How to Waive"
type: runbook-brief
status: open-awaiting-waive
version: "v2"
scope: "ShipItEZ c1wh PRD: 5 cancellation reversals (orders 97454308819:4263, 96964215564A:4263) that RTS can never complete"
owner: "Nam Park"
created: "2026-10-12"
updated: "2026-10-12"
last_verified: "2026-10-12"
verified_by: "Claude (read-only queries on c1wh-shipitez-prd; code read of wms2-api origin/develop 60ddb320 and wms2-mobile-ui origin/develop)"
related:
  - "ClickUp SBDEV-3313 (RTS roadmap umbrella): https://app.clickup.com/t/868m41gye"
  - "ClickUp SBDEV-3381 (waive), SBDEV-3547 (fence), SBDEV-3548 (mobile Waive)"
  - "Shareable copy (Claude Docs): https://claude.ai/code/artifact/79d66e15-8220-4b2e-a0c2-b6b979bf5d85"
tags:
  - runbook
  - rts
  - cancellation
---

# c1wh Pending Reversals — Why and How to Waive

Five cancellation reversals on ShipItEZ c1wh PRD can never complete, although their stock is already back in its bins. A supervisor closes them with **Waive** on WMS mobile, as user **panderson**. It is record cleanup, not a stock fix.

## What happened

Operators put the stock back by hand instead of using Return to Stock (RTS), so the reversal records were never closed.

When an order is cancelled after picking, WMS writes one **reversal record** per picked item: "these units are on tote X and must go back to bin Y". The intended close-out is the mobile RTS screen. You scan the tote, tap Complete Reversal, and the system moves the units back and closes the record.

| Order | Tote | Cancelled | What the operator did instead |
| --- | --- | --- | --- |
| 96964215564A:4263 | C1-0049 | 2026-10-01 | The tote went to Clearing. On 2026-10-07 14:01 UTC, `rfernandez` hand-moved the 4 bottles from Clearing to bin A110B4. |
| 97454308819:4263 | C1-0063 | 2026-09-21 21:50 UTC | All 4 items were hand-moved back to their source bins by 21:54 UTC. |

The hand moves emptied the tote's stock units. They now hold 0 units, are at lock 2 (`GOING_TO_DELETE`), and sit on the virtual `Nirwana` location. The reversal records (`customerorder_cancellation_log` ids 1–4 and 9) still point at them. RTS refuses to complete them because there is nothing left to move, and that refusal is correct: completing them would move the same stock twice.

**Will it recur?** Nothing blocked hand moves of cancelled stock until SBDEV-3547 (the fence against hand moves) reached prod, about 2026-10-08. Both moves above happened before that. The deploy date comes from the ClickUp status change and has not been confirmed against the running build (`/actuator/info`).

## Why it matters

Inventory is correct, so nothing is broken. The open records still cost three things:

- **A nightly alert that never clears.** Every night `PendingReversalReconciliationJob` writes a `message` row: "5 cancellation reversal(s) pending beyond 24h on shipitez - c1wh; oldest 484h…". It has fired 20 times, from 2026-09-23 to 2026-10-12. A permanent false alarm teaches people to ignore that alert, including on the night it reports a real stranded tote.
- **An RTS list that never empties.** Both orders stay in Pending Reversals forever.
- **OMS never hears the reversal finished.** WMS sends OMS a "reversal completed" notice only once every row on an order is closed. These two orders never get it. What OMS does with that notice for ShipItEZ has not been checked.

## What Waive does

Waive closes the record with an audit trail and moves no stock. It is a supervisor override added in SBDEV-3381 for reversals the system can never complete (`CancellationReversalService.waiveReversal`).

| | What Waive does here |
| --- | --- |
| The record | Marks it waived (`reversal_waived`), not completed, and stores who did it, when, the reason, and whether the stock was returned. |
| Stock | No movement and no stock change. In the code's words: "Never a transfer, never a stock-change message." On-hand is unchanged, which is correct because the stock is already home. |
| Locks | Only a `PICKED_FOR_GOODSOUT` lock is ever released. These units are `GOING_TO_DELETE`, which another process owns, so Waive leaves them alone. |
| OMS | When an order's last row closes, Waive sends that order's "reversal completed" notice. |
| Alert and list | The nightly alert stops listing these rows, and the orders leave Pending Reversals. |

**Answer "Yes" to "Was the stock returned to its bin?"** The stock movement records show every unit back in its source bin. Answering "No" would put a false statement in the audit trail. The server accepts "Yes" here because the tote stock units hold 0 units and are not shipped.

## How to waive

About 10 minutes, on WMS mobile. Do **not** move any stock: it is already in its bins.

1. Log in to WMS mobile on ShipItEZ **c1wh** PRD as **panderson**. The account has the super-admin role, which carries `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL` (verified 2026-10-12).
2. From the Main Menu, open **Return to Stock (RTS)**.
3. Tap **View List**. Pending Reversals shows two orders: **97454308819:4263** and **96964215564A:4263**. Use the list rather than scanning a tote, because these tote labels are reused across orders.
4. Tap **97454308819:4263**, then **Start Reversal** on Reversal Details.
5. Tick **all 4 rows**, then tap **Complete Reversal**. Each row is refused in red ("…locked as GOING_TO_DELETE (2) — manual intervention required"). That is expected, and a **Waive** button then appears on each row.
6. On each row, tap **Waive**, enter a **Reason**, answer **Yes** to "Was the stock returned to its bin?", and tap **Waive**. The row moves down to "Waived: …". Suggested reason: *Stock hand-returned to source bin after cancel on 2026-09-21; tote stock unit drained, reversal cannot complete (SBDEV-3313).*
7. Tap **Back**, open **96964215564A:4263**, and repeat steps 4–6 for its single row. Suggested reason: *Tote went to Clearing; 4 units hand-moved Clearing to A110B4 on 2026-10-07; reversal cannot complete (SBDEV-3313).*
8. Tell Nam it is done. Nam re-checks c1wh PRD for 5 waived and 0 pending, then closes SBDEV-3313.

| Order | Item | Qty | Source bin |
| --- | --- | --- | --- |
| 97454308819:4263 | Fall Club 2026 Member Note (Maroon) | 1 | AT01-15 |
| 97454308819:4263 | Fall 2026 NYE/ADV Card | 1 | AC01-84 |
| 97454308819:4263 | 2023 Grand Dry Creek Valley, Sonoma County Merlot 750ml | 3 | A301C4 |
| 97454308819:4263 | 2024 Vive Le Jazz Sonoma Coast Chardonnay 750ml | 3 | A301C5 |
| 96964215564A:4263 | 2022 MyStory Bourbon Barrel Aged Red Blend | 4 | A110B4 |

## If something goes off-script

| You see | Meaning | Do |
| --- | --- | --- |
| No Waive button after Complete Reversal | The failure was a login, permission or network error, not a refusal of the row. | Log out, log back in as panderson, and repeat step 5. |
| Waive refused: "cannot record the stock as returned…" | The data changed since 2026-10-12. | Stop and send Nam the message. |
| A row completes instead of being refused | The data changed since 2026-10-12. | Stop and tell Nam. |
| "Position was waived by another operator" | Someone already waived it. | Nothing to do for that row. |

## Verification query (after the waive)

```sql
select count(*) filter (where reversal_required and reversal_completed_at is null) pending,
       count(*) filter (where reversal_waived) waived
from customerorder_cancellation_log;   -- expect pending = 0, waived = 5
```

The remaining roadmap work is tracked on SBDEV-3733 to SBDEV-3736, filed 2026-10-12.
