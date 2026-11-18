---
title: "Questions for Brent: tickets waiting on product input"
type: area
status: active
version: v2
scope: product-questions
owner: "Nam Park"
created: 2026-11-03
updated: 2026-11-03
last_verified: 2026-11-03
verified_by: initial authoring
related:
  - ../proposals-register.md
tags:
  - area
  - product-questions
  - v2
---

# Questions for Brent

**What this is:** one file per ticket that needs a product decision from Brent Campbell before planning or work can
continue. Each file stands on its own, so it can be opened during a conversation with Brent and read top to bottom:
the ask first, then the context and evidence behind it.

**How to use it:**
- **Add a file** when a ticket stalls on a product question. Name it `SBDEV-####-kebab-description.md` and add a row
  below. Use [SBDEV-1468](SBDEV-1468-edit-flowbins.md) as the shape: *The ask* → ticket → what already shipped →
  what is open → evidence → questions (each with options and a recommendation) → *Answers*.
- **During the conversation**, write Brent's answers into the file's *Answers* section, with the date.
- **Afterwards**, copy the decision onto the ClickUp ticket as a comment, so it doesn't live only here. Then set the
  file's `status:` to `answered`, and move its row to *Answered* below.
- Product questions only. Engineering findings that need Nam's decision belong in the
  [proposals register](../proposals-register.md).

## Open

| Ticket | Title | Questions | Blocks | Added |
|---|---|---|---|---|
| [SBDEV-1468](SBDEV-1468-edit-flowbins.md) | WMS: Edit Flowbins | 2: bulk-edit meaning; unblock | the plan (T3, splits into T2 slices) | 2026-11-03 |
| [SBDEV-3372](SBDEV-3372-multi-ul-pick-allocation.md) | Multi-SKU pick locations can't allocate across ULs | 4: who chooses the UL; split order; same location; recount/consolidate scope. Round 2 (Brent answered round 1 on 2026-11-02); team meeting with David proposed | the plan (T3) | 2026-11-03 |
| [SBDEV-3766](SBDEV-3766-transfer-source-putawaylane.md) | Transfer recommends PutAwayLane stock | 4: PutAwayLane as a source; PutAwayLane as storage; which source first; area settings | the rule (T2; ordering fix can start now) | 2026-11-04 |
| [SBDEV-3511](SBDEV-3511-bol-pdf-from-order.md) | Generate a BOL PDF from order details (ShipItEZ) | 4 + 2 confirmations: template; system vs hand-filled fields; which orders; keep the PDFs; David's branch; pickup sheet | the plan (T3; OMS, per order, already decided) | 2026-11-07 |
| [SBDEV-3512](SBDEV-3512-location-create-delete.md) | Create and delete warehouse locations (ShipItEZ) | 5: delete vs retire; what must be clear first; who; create form/copy/import; audit | the retire design (T3); gating the live delete can start now | 2026-11-07 |

## Answered

| Ticket | Answered | Decision (one line) | Copied to ClickUp |
|---|---|---|---|
