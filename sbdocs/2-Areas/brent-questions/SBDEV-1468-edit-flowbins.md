---
title: "SBDEV-1468 Edit Flowbins: questions for Brent"
type: questions
status: open
version: v2
scope: replenishment / fixed location assignment
owner: "Nam Park"
ticket: "SBDEV-1468"
ticket_url: "https://app.clickup.com/t/868etpny4"
requester: "Brent Campbell"
created: 2026-11-03
updated: 2026-11-03
last_verified: 2026-11-03
verified_by: "code read at wms2-api origin/develop 065b4aaa and wms2-web-ui origin/develop f49105d; SQL on WineCo PRD (wsl-wineco-prd) and DEV (dev_wh01_om1); independent fact-check lane 2026-11-03 (1 overstatement + wording fixes applied)"
related:
  - ../../4-Archieves/wms2/plan/SBDEV-3128-location-default-fla-bounds.md
  - ../../3-Resources/design/wms2-replenishment-design.md
  - ../proposals-register.md
tags:
  - questions
  - replenishment
  - v2
---

# SBDEV-1468 Edit Flowbins: questions for Brent

## The ask

Two questions. The first one decides the design.

1. **When someone selects several flowbins and edits their bounds, what should change?** Our recommendation is
   **Option A**: set the flowbin's location default (see [Q1](#q1-what-does-a-bulk-bound-edit-change)).
2. **Can the ticket be unblocked?** ClickUp has it as Blocked / Phase Deferred, and no reason is recorded
   (see [Q2](#q2-can-the-ticket-be-unblocked)).

Plus one point to confirm: we read **"Mid Bound"** as **Hysteresis** (see [Q3](#q3-confirm-mid-bound-means-hysteresis)).

## The ticket

[WMS: Edit Flowbins](https://app.clickup.com/t/868etpny4). Brent opened it on 2025-07-16 as a client request. It is
assigned to Nam.

**Status:** `blocked` · Phase *Deferred* · Release Status *Blocked* · General Status *PLANNING* · priority normal.

**The original complaint.** In the old WMS, users could edit a flowbin's capacity (bounds) directly. In v2 the only
place to edit bounds was the Fixed Assignment screen, and only for a flowbin that already had a SKU assigned. To
edit an empty flowbin, a user had to assign a SKU first.

**What the ticket asks for:**
- Rename *Fixed Assignment* to **Pickable Locations**, with managing fixed assignments as one of the screen's jobs.
- Show **every** pickable location, whether or not it has a fixed assignment.
- Keep moving and deleting fixed assignments.
- **Multi-select** locations, and **bulk-edit** Lower Bound / Hysteresis / Upper Bound.
- Columns, left to right: Location ID · Rack Name · Low Bound · Mid Bound · High Bound · SKU ID · Current Qty ·
  Shipper Name. The last three are filled only where a fixed assignment exists.
- **Filters:** locations with no fixed assignment, and fixed assignments by shipper.
- An **export** with the same columns.

## What has already shipped

**The core complaint is fixed.** SBDEV-3128 (API, wms2-api #601) and SBDEV-3991 (UI, wms2-web-ui #193) were merged
and dev-tested on 2026-11-02:

- On the **Storage Locations** screen, any flowbin can now be given default Min / Hysteresis / Max (menu item
  *Set replenishment defaults*), with or without an assigned SKU.
- A fixed assignment **inherits** its flowbin's default. Fixed Assignment shows each assignment as *Inherited*,
  *Inherited (out of date)* or *Overridden*, and has a *Use … default* action that puts an assignment back on the
  default.
- An assignment edited by hand becomes **Overridden** and keeps its own values when the default changes.

So the "assign a SKU first" workaround is no longer needed. What is left is the redesign: one screen, bulk editing,
and better columns and filters.

## What is still open

On `origin/develop` of both repos (checked 2026-11-03), none of the following exists yet:

| Ask | Status today | What it needs |
|---|---|---|
| One list of every flowbin | Fixed Assignment lists only locations **with** an assignment; empty ones are on Storage Locations | A new API read covering all flowbins, with their assignment if any |
| Multi-select + bulk bound edit | One row at a time | UI work; **meaning depends on Q1** |
| Rack Name, Current Qty columns | Neither screen's data includes rack name or current qty (the empty-flowbin list carries only a rack id) | The same new API read |
| Filter: no fixed assignment | Not available on this screen | UI work, using the new read |
| Filter: by shipper | Free-text search only | UI work |
| Export with the new columns | Exports today's columns | UI work |
| Rename to *Pickable Locations* | Still *Fixed Assignment* | UI work |

There is also a small engineering cleanup that rides on this ticket and needs no input from Brent: four unused,
incorrectly wired store actions in `wms2-web-ui` (see the ticket comment of 2026-11-02).

## Evidence

**How many flowbins the current screen hides.** Flowbins with no fixed assignment never appear on Fixed Assignment:

| Environment | Flowbins | With no fixed assignment | With a location default set |
|---|---|---|---|
| WineCo PRD (`wh01_om1_v2`) | 2,149 | **557 (26%)** | 0 |
| DEV (`dev_wh01_om1`) | 2,068 | 724 (35%) | 0 |

- Every fixed assignment on PRD (1,592) is on a flowbin, so in practice "pickable location" means flowbin.
- Rack data exists: 2,139 of 2,149 PRD flowbins have a rack (92 racks in all).
- Location defaults are 0 everywhere because nobody has set one yet. The SBDEV-3128 migration only marks existing
  assignments as inherited. It reached WineCo PRD on 2026-11-02 (Flyway `2.2.45`, installed 22:13).

**Why the current screen hides them.** In wms2-api, `FixLocationAssignmentRepository.getDetailView` starts its query
at the assignment table (`from fix_location_assignment fla join location l …`), so only assigned locations come back.
Neither endpoint the screen uses returns rack name or current quantity: `/fixedAssignment/detailView` has neither,
and `/fixedAssignment/getFlowBinHavingNoFixedAssignment` returns the raw location record, which has a rack id but
no rack name and no quantity.

## Questions for Brent

### Q1. What does a bulk bound edit change?

**Why it matters:** since SBDEV-3128 each flowbin has **two** sets of bounds, and the ticket was written before that
split:

- **Location default:** the flowbin's own values, which apply whatever SKU is assigned.
- **Assignment values:** the values on the current SKU assignment. They follow the location default until someone
  edits them by hand. After that the assignment is *Overridden* and keeps its own values.

| Option | What a bulk edit does | Effect |
|---|---|---|
| **A. Location default only** *(recommended)* | Sets the default on every selected flowbin | Empty flowbins get the values. Assigned flowbins still following the default update too. Hand-edited (*Overridden*) assignments keep their values. Future SKU assignments start from the new values. Replenishment for the affected SKUs is refreshed straight away. |
| **B. Default + reset overrides** | Same as A, and also resets every *Overridden* assignment on the selected flowbins | Every selected flowbin ends up with exactly the values entered. Hand-tuned bounds on those flowbins are lost. |
| **C. Assignment values only** | Edits the current SKU assignments, as the screen does today | Empty flowbins can't be bulk-edited, which is the original complaint. Every edited assignment becomes *Overridden* and stops following its flowbin's default. The values live on the assignment, so they are gone if the assignment is deleted. |

**Our recommendation: A**, with B as an optional "also reset overrides" checkbox for when someone wants everything
levelled. A respects bounds that someone tuned on purpose, and it reuses the default editor that already shipped.
Defaults can be set on flowbins only, so a bulk edit would skip, or refuse, any other location type in the selection.

*Note:* B is our addition; the ticket doesn't mention it. *Cost note (unverified):* A and B could loop the existing
single-location update from the UI. Whether that is fast enough for hundreds of flowbins at once hasn't been
measured; if it isn't, the API slice also needs a bulk write.

**Follow-ups to raise only if Brent picks B:** should the reset happen without asking, or after a confirmation that
lists the Overridden assignments it will reset?

### Q2. Can the ticket be unblocked?

The ticket is Blocked / Deferred, and neither of its comments says why or who blocked it. If something is holding it
(a dependency, a client decision, sequencing), we'll wait. Otherwise, once Q1 is answered we'll plan it.

### Q3. Confirm: "Mid Bound" means Hysteresis

The column list says Low / **Mid** / High Bound, while the bullets say Lower Bound / **Hysteresis** / Upper Bound.
The system stores hysteresis in the "middle bound" slot (`setMiddleBound` writes `fla.middlebound`, which the
screen labels *Hysteresis*), so we are treating them as the same. The column would be labelled *Hysteresis* unless
Brent prefers *Mid Bound*.

## What happens after the answers

- **Tier:** T3 as written: two repos (`wms2-api` and `wms2-web-ui`), plus a bulk write to replenishment inputs.
  It splits into slices that are each T2:
  - **(a) API:** a new read covering all flowbins, with their assignment if any: rack, current qty, shipper,
    bounds and default provenance. It adds a bulk write endpoint only if looping turns out too slow (see Q1).
  - **(b) UI:** the *Pickable Locations* screen, with multi-select, bulk edit, columns, filters and export.
  - **(c) Cleanup:** T0. Delete the four unused store actions. This is independent and can go first.
- **Next step:** a feature plan (`wms-feature-plan`) built on Brent's answer to Q1.
- The full triage block is on the ticket (ClickUp comment, 2026-11-03).

## Answers

*Fill in during the conversation with Brent. Date each answer. Then copy the decisions onto the ticket.*

- **Q1 (bulk edit):**
- **Q2 (unblock):**
- **Q3 (Mid Bound = Hysteresis):**
- **Anything else raised:**
