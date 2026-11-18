---
title: "SBDEV-3766 Transfer recommends PutAwayLane stock: questions for Brent"
type: questions
status: open
version: v2
scope: transfer orders / mobile transfer / location area config
owner: "Nam Park"
ticket: "SBDEV-3766"
ticket_url: "https://app.clickup.com/t/868mhdp2t"
requester: "Nam Park (found while testing SBDEV-2857; not client-reported)"
created: 2026-11-04
updated: 2026-11-04
last_verified: 2026-11-04
verified_by: "code read at wms2-api origin/develop 68a20d76 and wms2-mobile-ui origin/main; SQL on WineCo PRD (wsl-wineco-prd) 2026-11-04; independent fact-check lane 2026-11-04 (putaway-lock wording corrected; reservation gap and partial-take transfer model added)"
related:
  - ../../3-Resources/workflows/wms2-transfer-order-workflow.md
  - ../../3-Resources/workflows/wms2-receiving-putaway-workflow.md
  - SBDEV-3372-multi-ul-pick-allocation.md
tags:
  - questions
  - transfer
  - v2
---

# SBDEV-3766 Transfer recommends PutAwayLane stock: questions for Brent

## The ask

Three questions. The first decides the fix; the second explains the data behind it.

1. **Should stock on PutAwayLane ever be a transfer source?** Our recommendation is **yes, but only as a last
   resort**, because for 111 SKUs it is currently the only source (see [Q1](#q1-should-putawaylane-stock-be-a-transfer-source)).
2. **Is PutAwayLane being used as storage on purpose?** More than half of the unit loads on it arrived over 30 days
   ago (see [Q2](#q2-is-putawaylane-being-used-as-storage)).
3. **What should "Go to:" recommend when several sources qualify?** Today the order is not defined; it is whatever
   order the database returns (see
   [Q3](#q3-which-source-should-go-to-recommend)).

Plus a configuration check that Brent may want to hand to whoever owns area setup ([Q4](#q4-confirm-two-area-settings)).

**Why now:** the mobile screen that shows this recommendation (SBDEV-2857) is **on prod**. WineCo operators are
already seeing it.

## The ticket

[WMSv2 Mobile Transfer recommends PutAwayLane (Inbound) stock as the transfer source](https://app.clickup.com/t/868mhdp2t).
Nam filed it on 2026-10-14 while testing SBDEV-2857 on DEV; the client did not report it. It has no assignee.
**Status:** `Open` · priority high · Phase *Investigation* · Item Type *Research*.

**The issue.** SBDEV-2857 (ST#1082, now `on prod`) added a source list to the Mobile Transfer *Scan Unit Load*
screen. The first entry is shown as **"Go to: &lt;location&gt;"**. That list includes stock sitting on
**PutAwayLane**, which is stock that has been received but not put away. On DEV, the first recommendation and the
top of the list were all PutAwayLane. Before SBDEV-2857 the list was hidden, so this did not matter.

**The ticket's acceptance criteria:**
- The list never recommends stock that has not been put away, unless no other source exists. The exact rule
  depends on the questions below.
- The order within the list is deterministic and documented.
- The area settings on WineCo PRD are confirmed intentional or corrected.
- Tests cover the rule and the ordering.

## Why it happens (code, checked 2026-11-04)

Nothing has changed since the ticket was filed. `origin/develop` still has both causes:

- **Which stock counts as a source:** any unlocked stock, with quantity, in an area flagged *use for transfer*.
  WineCo's **Inbound** area is flagged, and Inbound contains PutAwayLane.
- **How the list is ordered:** three groups, in this order:
  1. deep storage;
  2. everything else that isn't a flowbin;
  3. flowbins.

  WineCo has no area flagged *deep storage*, so group 1 is always empty. **Within a group there is no ordering at
  all**: the database returns rows in whatever order it likes. PutAwayLane falls in group 2 alongside every racked
  location, so it can be first. The mobile screen shows that first entry as "Go to:". Nothing later re-sorts the
  list.
- **A second gap the ticket didn't mention: reservations are ignored.** The list only checks that the stock unit
  has stock and isn't locked. Stock already **reserved** for other picks still qualifies, and the screen shows it
  with what's left after reservations, which can be **0**. So "Go to:" can send the operator to a location whose
  stock is all promised elsewhere. The check also ignores locks on the unit load and the location; only the stock
  unit's own lock counts.

## What the data says (WineCo PRD, 2026-11-04)

**How big PutAwayLane is:**

| Measure | Value |
|---|---|
| Unit loads on PutAwayLane with stock | 1,679 (1,677 stock units, 367 SKUs) |
| Locked or reserved | **0**. That is by design: putaway creates no task, lock or reservation. It is just a scan that moves the unit load off PutAwayLane. So nothing stops a transfer from taking stock from a unit load **before** it is put away, and the putaway operator may then find it partly or fully empty |
| SKUs that have PutAwayLane stock among their transfer sources | 369 of 3,007 transfer-eligible SKUs |
| SKUs whose **only** transfer source is PutAwayLane | **111** (5,336 units) |

**How long it sits there.** This is the time since each unit load last *arrived* on PutAwayLane:

| Last arrived | Unit loads |
|---|---|
| under 7 days | 515 |
| 7–30 days | 262 |
| 30–180 days | **764** |
| 180–365 days | 71 |
| over 1 year | 67 |

So **902 of 1,679 unit loads (54%) have sat on PutAwayLane for more than 30 days.** That looks less like a lane
that stock passes through and more like storage.

**Is it actually happening?** Since 2026-09-01, 2,114 stock moves went into a TransferLane. **58 came from
PutAwayLane**: 23 of the 1,254 moves before SBDEV-2857 reached prod (1.8%), and 35 of the 860 after (4.1%). The
share roughly doubled, but it is small. The PutAwayLane moves carry no order number, unlike the others, so we
can't tie them to specific transfer orders.

## Questions for Brent

### Q1. Should PutAwayLane stock be a transfer source?

| Option | Rule | Effect |
|---|---|---|
| **A. Never** | Drop PutAwayLane (or all of Inbound) from the source list | Clean. But the **111 SKUs** whose only stock is on PutAwayLane become impossible to transfer until someone puts them away, and their transfers would stall |
| **B. Last resort** *(recommended)* | Keep it in the list, but always after every put-away source. It is recommended only when nothing else has the SKU | Matches the ticket's AC ("unless no other source exists"). No transfer that works today stops working. The operator is no longer sent to PutAwayLane when the stock is on a rack |
| **C. As today** | No change to eligibility; only fix the ordering (Q3) | Smallest change. PutAwayLane would still be recommended whenever it sorts first under the new order |

**Our recommendation: B.** It removes the bad recommendation without stranding the 111 SKUs. Whichever option
Brent picks, it is a code change of about two classes plus tests (T2). It doesn't need a data change on PRD.

### Q2. Is PutAwayLane being used as storage?

54% of the unit loads on PutAwayLane have been there more than 30 days, and 67 for over a year. Is that:

- **intended**: overflow storage while the racks are full, or stock deliberately kept on the lane? If so, Q1's
  premise that "PutAwayLane = not put away yet" is wrong, and option C becomes reasonable;
- **a backlog**: stock that should have been put away and wasn't? If so, it is a separate cleanup, outside this
  ticket. It also explains why transfers keep finding stock there;
- **left over from the v1 → v2 migration**: unit loads that landed on PutAwayLane during the cutover?

His answer decides whether this ticket is the whole fix or half of it.

### Q3. Which source should "Go to:" recommend?

When several sources of the SKU qualify, which should be first? Today the order isn't defined.

**How a transfer takes stock:** the operator scans a source, and the system moves *the smaller of what's free and
what's still needed* onto a new unit load on the transfer lane. The rest stays on the source; the screen says "Bring
back not used stock". So a source that holds more than needed means a partial take, and one that holds less means
another trip to the next source.

| Option | Effect |
|---|---|
| **The smallest source with enough free stock for the whole quantity** *(recommended)* | One trip, and the least stock to bring back. Big pallets aren't broken open for a few bottles |
| **Oldest stock first (FIFO)** | Rotates stock. Can send the operator to a source that doesn't have enough, so it takes more trips |
| **Location sequence (pick path)** | Predictable walking order, but ignores quantity |

**Our recommendation:** the smallest source with enough **free** (unreserved) stock for the whole quantity, with
ties broken by location order. If none has enough, the largest first. Sources whose stock is all reserved go last
or are dropped. This is the same question as SBDEV-3372's "which ULs go first", so the two answers should agree.

### Q4. Confirm two area settings

These may be for whoever owns WineCo's area configuration, not Brent himself:

- **Inbound is flagged *use for transfer*.** Intentional, or a default carried from setup or migration? (If Q1 = B,
  it can stay as it is.)
- **The "Deep Storage" area has no locations and isn't flagged *deep storage*.** The first priority group in the
  ranking only works through that flag, so it never applies on WineCo. Is the area meant to be used, or is it a
  leftover?

## What happens after the answers

- **Tier: T2** (as filed): an API behaviour change in two places, with predictable effects, plus tests. It becomes
  **T3** only if the fix is a data change to PRD area flags (option A done through configuration rather than code),
  which we don't recommend.
- **Independent of the answers:** fixing the ordering within each group is needed whatever Brent says, and so is
  not recommending fully reserved stock. Both can be planned now; the rule Brent picks in Q3 just fills in the
  ordering. The reservation gap is sub-T3 and belongs on this ticket.
- If Q2 turns out to be a backlog, propose a separate cleanup ticket (PutAwayLane put-away sweep) rather than
  widening this one.
- No ClickUp comment has been posted for this round yet.

## Answers

*Fill in during the conversation with Brent. Date each answer. Then copy the decisions onto the ticket.*

- **Q1 (PutAwayLane as a source):**
- **Q2 (PutAwayLane as storage):**
- **Q3 (which source first):**
- **Q4 (area settings; who owns them):**
- **Anything else raised:**
