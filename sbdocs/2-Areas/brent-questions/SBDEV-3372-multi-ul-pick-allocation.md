---
title: "SBDEV-3372 Multi-UL pick allocation: questions for Brent"
type: questions
status: open
version: v2
scope: picking / allocation / reservation
owner: "Nam Park"
ticket: "SBDEV-3372"
ticket_url: "https://app.clickup.com/t/868m5vad0"
requester: "Brent Campbell"
created: 2026-11-03
updated: 2026-11-03
last_verified: 2026-11-03
verified_by: "code read at wms2-api origin/develop ee1670b8 and wms2-mobile-ui origin/develop ee86b0a; SQL on WineCo PRD (wsl-wineco-prd) 2026-11-03; triage comment 2026-10-31; Brent's reply 2026-11-02; independent fact-check lane 2026-11-03 (1 wrong claim + Option B cost corrected)"
related:
  - ../../3-Resources/workflows/wms2-picking-workflow.md
  - ../../3-Resources/workflows/wms2-cycle-count-workflow.md
  - ../../3-Resources/workflows/wms2-move-stock-unitload-workflow.md
  - SBDEV-1468-edit-flowbins.md
tags:
  - questions
  - picking
  - v2
---

# SBDEV-3372 Multi-UL pick allocation: questions for Brent

## The ask

Brent answered our first round on the ticket (2026-11-02). His answer settles two of our questions and widens the
scope, so this round has **one design question** and some scoping:

1. **Who chooses the UL: the system or the picker?** This decides the size of the fix. Our recommendation is to
   **start with the system choosing, and let the picker swap in another UL of the same SKU at the same location**
   (see [Q1](#q1-who-chooses-the-ul)).
2. **When the system has to split, which ULs go first?** Smallest-first empties partial ULs; largest-first means
   fewer scans (see [Q2](#q2-when-splitting-which-uls-go-first)).
3. **Can one pick span two locations?** This is "split-span" asked again in plain words (see [Q3](#q3-can-one-pick-span-two-locations)).
4. **Are recount, correction and consolidation part of this ticket?** Some of that already exists (see [Q4](#q4-recount-correction-consolidation-this-ticket-or-separate)).

Brent also suggested a team discussion with David, who has architecture ideas. **Q1 is the agenda for that meeting.**

## The ticket

[WMSv2 - Multi-SKU Pick Locations Cannot Allocate Across Multiple Unit Loads](https://app.clickup.com/t/868m5vad0).
Opened by Brent; assigned to David Oppenheim and Nam. **Status:** `Open` · priority high · Phase *Triage* · Release
Status *Needs Attention*.

**The report:** a parcel needs 6 bottles of one SKU. Its multi-SKU pick location (WineCo Club01/02/03) holds UL A
with 2 and UL B with 4. The release fails with "not enough stock on location" even though the location holds 6 in
total. Expected: pick 2 from UL A and 4 from UL B.

**The ticket's acceptance criteria:**
- The parcel releases when the stock across several ULs at the location is enough.
- The pick may be split across two or more ULs, and the picker is told how much to take from each.
- Reservations never over-reserve any one UL.
- UL quantities and the audit history record the actual UL(s) used.
- Single-UL picking is unchanged when one UL covers the quantity.

That model is **system-directed**: the system chooses the ULs, and the picker follows.

## What we found (first round, 2026-10-31)

- **The single-UL behaviour is intended.** SBDEV-2512 (Closed; WineCo ST#1026, order BF173533) added a rule: a pick
  takes exactly **one** UL that covers the whole quantity, and never splits. It was added after WineCo asked why a
  picker pulled bottles one by one instead of taking a full case. This ticket asks for the reverse, so the two
  rules have to be reconciled; they can't both apply everywhere.
- **Splitting already exists in the code**, but the SBDEV-2512 rule turns it off for every order position.
  Club-line packaging is different again: it takes from one UL and spills over to the next only when the first runs
  out. It has no full-case preference, and it isn't a pick.
- **No blocked parcel is live on PRD.** 0 order lines are in state 55 (Not enough stock on location). Held
  positions return to normal once stock appears, so past holds can't be counted. In the 120 days to 2026-10-31,
  1 of 1,485 Club picks was split across ULs.
- **A global switch exists, and we don't recommend it.** Setting the sysprop `ENFORCE_PARTITIONALLOWED=false` turns
  the SBDEV-2512 rule off for **every** order (flowbin picks never had it), which brings back the bottle-by-bottle picks WineCo complained about.

## What Brent answered (2026-11-02)

| Our question | Brent's answer | What it settles |
|---|---|---|
| A concrete blocked order? | No example. It has happened in prod several times and was fixed each time by consolidating ULs by hand. Repro: receive two small ULs (6 and 8) of one SKU into Club02 and order 12. | We reproduce it ourselves on DEV (no ticket input needed) |
| Split only at multi-SKU/club locations, or drop SBDEV-2512? | **Keep SBDEV-2512 as the preference** (take a full case if there is one). If no single UL covers the quantity, pull from one or more ULs. | The rule: **one covering UL if possible, otherwise split.** Not a reversal of SBDEV-2512 |
| Must the ULs be in the same location ("split-span")? | Didn't recognise the term | Asked again as Q3 |

**And he widened the scope.** His use cases have the **picker** choosing the UL: *"I am taking X-qty from
UL-NNNNNN"*, as opposed to the system telling the picker *"take X from Club-NN"*:

1. The picker sees how many to pick from the multi-UL location. If a full UL of that SKU holds enough (say 12), the
   picker scans it and takes 12.
2. If only partial ULs exist (6 and 8), the picker scans the first and takes 6, then scans the second and takes 6,
   leaving 2.
3. Other picks must keep UL quantities accurate for this to work.
4. A way to correct ULs and counts on a location.
5. A way to quickly recount a UL when the picker sees a wrong quantity.
6. A way to consolidate ULs of the same SKU to tidy pick locations.

## What the code does today (checked 2026-11-03)

| Brent's need | Today | Gap |
|---|---|---|
| 1–2. Picker scans the UL to pick from | Both pick screens (regular and rapid) ask the picker to *"Scan Picking Location or Unit Load"*. But the UL is **fixed when the order is released**, and both refuse a different UL: regular with *"Location not valid. Expected location X or unit load Y"*, rapid with *"Scan correct source=&lt;assigned UL&gt;"*. The regular screen also accepts a scan of the location itself. The only automatic re-sourcing happens when the assigned stock has gone stale, never by the picker's choice | **The main gap.** The UL would have to be chosen (or re-chosen) when the picker scans, not at release |
| 3. Accurate UL quantities | Each pick is reserved against one specific stock unit and deducted from it | None in principle. This is why system-directed splitting fits today's model |
| 4–5. Correct / quickly recount a UL | **Exists.** Mobile *Cycle Count* has a single-UL path: scan a UL and count it. A mismatch leads to a recount, and the **recount** adjusts the stock (`scanSingleUnitLoad`, `recountSingleUnitLoad`) | Possibly none. **Is it fast enough to use mid-pick?** (Q4) |
| 6. Consolidate ULs of one SKU | **Exists, with a limit.** Mobile *Move Stock* moves stock from one UL into another, and a fully drained source is removed. It **can't move stock that is reserved for a pick or being picked**, so a UL with open picks can't be consolidated until they finish | A dedicated "consolidate this location" shortcut, or a way around the reserved-stock limit (Q4) |

**PRD layout (2026-11-03):** Club01 holds 23 SKUs on 27 ULs, with 3 SKUs on more than one UL (at most 3). Club02
holds 16 SKUs on 19 ULs, with 2 SKUs on more than one UL (at most 3). So at any one time only a handful of SKUs are
exposed, which matches Brent's "fixed by hand each time".

## Questions for Brent

### Q1. Who chooses the UL?

| Option | How picking works | Effect |
|---|---|---|
| **A. System-directed split** | At release, the system prefers one UL that covers the quantity (SBDEV-2512 unchanged). If none does, it splits the quantity across ULs of that SKU at the location and tells the picker "take 6 from UL-…, then 6 from UL-…". The picker scans each UL in turn | Matches the ticket's ACs. Fits today's reservation model, since each part is reserved up front. Unblocks the stranded parcels. The picker can't go off-plan |
| **B. A + picker may swap the UL** *(recommended, limited form)* | As A, but when the picker scans a **different** UL of the **same SKU** at the **same location**, the system checks that UL has enough **unreserved** stock and moves the pick onto it, rather than refusing | Keeps quantities accurate, because the swap is checked and recorded. **Limit:** a full case is often already reserved for another parcel. Swapping in a UL that is reserved for someone else means re-arranging two orders' picks, and collapsing a 6 + 8 split into one 12 means merging pick lines. Both are much bigger, so the limited form refuses those cases and covers only free ULs |
| **C. Fully picker-directed** | The system only says "pick 12 of SKU-ABC at Club02". The picker scans any ULs and enters an amount for each until the 12 are reached; nothing is fixed at release | Exactly Brent's use cases. **Largest change:** reservations would have to work at location level instead of UL level, and that touches every pick and replenishment path. Concurrent pickers at the same location become a real risk |

**Our recommendation: B in its limited form.** It is **A** with the swap added: A fixes the stranded parcels, and
the swap covers Brent's case 1 (the picker sees a full case and takes it) **when that case isn't already promised to
another parcel**. B also keeps every bottle reserved against a known UL.

**Follow-up for Brent:** how often is the full case on the shelf free, rather than already reserved by another
parcel? If it's usually reserved, the limited swap rarely helps, and the choice is really between A and C.
**C** is a redesign of how reservations work. It deserves its own ticket, and David's input, before anyone commits
to it.

### Q2. When splitting, which ULs go first?

Applies to options A and B. When no single UL covers the quantity:

- **Smallest first:** empties the partial ULs, so locations tidy themselves and less manual consolidation is needed.
  The cost is more scans per pick.
- **Largest first:** fewer scans, but small remainders pile up. Today's candidate order is largest-first, by the UL's total quantity (stock already
  reserved for other picks is not subtracted).

**Our recommendation: smallest first.** Brent's pain point is partial ULs piling up.

### Q3. Can one pick span two locations?

This is what we meant by "split-span". If Club01 has 2 bottles and Club02 has 4, may one pick take bottles from
**both** locations? Or must every UL in a split be at the **same** location? We recommend the **same location
only**: it keeps the picker in one place and matches the ticket's wording ("within the same valid pick location").
Today, allocation looks for the SKU across all picking areas, so "same location" would be a new rule we add.

### Q4. Recount, correction, consolidation: this ticket or separate?

Two of Brent's six use cases may already be covered:
- **Quick recount / correct a UL:** mobile *Cycle Count* → single UL.
- **Consolidate:** mobile *Move Stock* into another UL.

Are these good enough? If not, what is missing: speed, starting it from inside the pick screen, or doing a whole
location at once? We'd like to keep this ticket to allocation and picking, and put any new
recount/consolidate screens on their own ticket.

## What happens after the answers

- **Tier: T3.** Brent's reply disputes the current design (picker-chosen vs system-chosen UL), which is one of the
  mid-flight escalation triggers. The work also touches reservation integrity and two repos (`wms2-api`,
  `wms2-mobile-ui`).
  - With **A**, the API part alone is close to T2: release-time split at one location, keeping the SBDEV-2512
    preference.
  - **B** (limited) adds the scan-time swap. The API swap path partly exists already: the stale-stock re-sourcing
    moves reservations. The regular pick path would have to start sending the scanned UL, and both mobile pick
    screens need changes.
  - **C** is a separate design project.
- **Before planning:** reproduce on DEV with Brent's recipe (6 + 8 in Club02, order 12) and record the exact
  failure. This is the floor's "one DB query / repro" step, and it needs nothing from Brent.
- **Next step:** after the team discussion, write a feature plan (`wms-feature-plan`) for the chosen option.

## Answers

*Fill in during the conversation with Brent (and David). Date each answer. Then copy the decisions onto the ticket.*

- **Q1 (who chooses the UL):**
- **Q2 (split order):**
- **Q3 (same location only):**
- **Q4 (recount / consolidate scope):**
- **David's architecture input:**
- **Anything else raised:**
