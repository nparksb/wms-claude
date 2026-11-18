---
title: "SBDEV-3511 Generate a BOL PDF from order details: questions for Brent"
type: questions
status: open
version: v2
scope: shipping / bill of lading / OMS documents
owner: "Nam Park"
ticket: "SBDEV-3511"
ticket_url: "https://app.clickup.com/t/868m9qbfp"
requester: "Ryan Fernandez (ShipItEZ), via the ShipItEZ standing meeting 2026-09-24; ticket written by Scott Dalton"
created: 2026-11-07
updated: 2026-11-07
last_verified: 2026-11-07
verified_by: "triage comment on the ticket 2026-11-07 (Nam); code read at oms-laravel-api origin/develop, wms2-api origin/develop, branch sweep of oms-laravel-api / siteboss-frontend / wms2-api / wms2-web-ui 2026-11-07; SQL on ShipItEZ PRD (c1wh wh01_shipitez_v2, nywh wh02_shipitez_v2) 2026-11-07; independent fact-check lane 2026-11-07 (dates, OMS weight, pallet-count and search-scope wording corrected)"
related:
  - SBDEV-3512-location-create-delete.md
  - ../../3-Resources/workflows/wms2-bol-truck-loading-workflow.md
tags:
  - questions
  - bol
  - oms
  - v2
---

# SBDEV-3511 Generate a BOL PDF from order details: questions for Brent

## The ask

Where the BOL is generated is **already decided** (Nam, 2026-11-07): **in the OMS, per order**, not from the WMS's
outbound BOL. What blocks the plan is the document itself. Four questions:

1. **Which template is the approved one?** ShipItEZ sent three different documents (see
   [Q1](#q1-which-template)).
2. **Which fields does the system fill, and which stay blank to fill by hand?** The OMS has no freight class, NMFC,
   per-order pallet count or order weight, and the freight bill-to party is unclear (see [Q2](#q2-which-fields-the-system-fills)).
3. **Which orders get a BOL, and how do we recognise them?** Nothing marks an order as freight/LTL today (see
   [Q3](#q3-which-orders-get-a-bol)).
4. **Should generated BOLs be kept?** (see [Q4](#q4-keep-generated-bols)).

Plus two things to confirm with others: **David's branch** and the **pickup sheet**
([Q5](#q5-two-confirmations)).

## The ticket

[WMSv2 — Generate Bills of Lading Automatically From Order Details](https://app.clickup.com/t/868m9qbfp). Created by
Scott Dalton from the ShipItEZ standing meeting of 2026-09-24. Assigned to David Oppenheim, Leonardo Castro and Brent
Campbell. **Status:** `Open` · priority normal · Phase *Investigation* · Item Type *New Feature*.

**The request** (from the ticket text, which is marked *AI summary, not yet verified*): Ryan asked for SiteBoss to build the BOL from order data already in the system, as a PDF to print
or download, instead of staff filling one in by hand each time. He warned that old copies carry outdated company
and contact details. David thought a branch for this might already exist.

**What happened on the ticket since:**
- 2026-09-25, Brent asked Scott to get ShipItEZ's current BOL so we know which fields they expect.
- 2026-09-25, Scott attached *Shipitez_BOL_for_Pickups.xlsx*. Truman (ShipItEZ) wants to look at the Co-Op's BOL
  before deciding, and may want "some of the standard terms" on it.
- 2026-09-25, Scott attached *BOL_Samples.pdf* from Jo Ann: one BOL from the Co-Op and one from a trucking
  company. Truman wants "the compliance verbiage" added to the system-generated BOL. Brent: "I'll take a look!"
- 2026-11-07, Nam's triage (summarised below).

## What we found (triage, 2026-11-07)

- **No BOL PDF exists on any remote branch of the v2 repos** (oms-laravel-api, siteboss-frontend, wms2-api,
  wms2-web-ui; the fact-check also covered wms2-mobile-ui and omsv2-UI). Method: commit-message search across all
  branches for BOL with PDF/print and for "lading", a search of `pom.xml` history for PDF
  libraries, and remote branch names. Re-run 2026-11-07 evening: still nothing. **Blind spot:** an unpushed local
  branch on David's machine, or a commit whose message doesn't mention BOL or PDF. The closest work is David's
  SBDEV-4020/4025 in siteboss-frontend (branch `claude/wms-app-shell`, not merged), which ports the WMS *Outbound
  BOL* screens and their XLSX export. That is not a BOL document.
- **Why the OMS, not the WMS:**
  - ShipItEZ's sample BOL covers **one order** shipped as two pallets LTL to one consignee. A WMS outbound BOL is a
    different thing: one truck carrying parcels from many orders.
  - **The WMS doesn't hold the data.** Its order record has a recipient name, weight, client order number and
    special instructions, with no street address. On ShipItEZ CA (`wh01`), **none** of the 1,171 WMS BOLs has a
    destination. All 135 created in the last 180 days are *REGULAR* truck BOLs with no courier, each tied to a
    transfer. NY (`wh02`) has 70 BOLs, none with a destination, and none created since 2026-02-11.
  - **The OMS has most of what a BOL needs:** ship-to and bill-to addresses, PO number, carrier and ship method, special,
    delivery and warehouse instructions, and the order lines. It **already renders PDFs**: the pick sheet
    (`PicksheetPdfService`, Blade templates plus dompdf, with ship-to / bill-to / from address partials). A BOL would
    follow the same pattern. wms2-api has no PDF library.
- **Side note:** the existing WMS outbound-BOL XLSX export always leaves its "shipped to" row blank.

## Questions for Brent

### Q1. Which template?

The attachments are three different documents (as described in the 2026-11-07 triage; the fact-check didn't
re-open the files):

| # | Document | What it is |
|---|---|---|
| a | *Shipitez_BOL_for_Pickups.xlsx* | A **winery inventory-pickup sheet**: SKU, description, bottles, signatures. Not a carrier BOL |
| b | *BOL_Samples.pdf* page 1 | A blank **Straight Bill of Lading – Short Form** under the *Sonoma County Vintner's Co-Op* header. This looks like the outdated company information Ryan warned about |
| c | *BOL_Samples.pdf* page 2 | A BOL **generated by the carrier/broker** (Agforce / Quote Factory / Estes) for one order |

**What we need:** the one approved layout, with ShipItEZ's **current** company name, address and contact, and the
exact **compliance wording** Truman wants. Our suggestion is a standard *Straight BOL – Short Form* (layout b) with
ShipItEZ's current header and Truman's terms at the bottom. **Who signs off on the wording:** Truman, Ryan or Jo Ann?

### Q2. Which fields the system fills

| BOL field | Where it would come from | Status |
|---|---|---|
| Shipper (from) | Client / facility address in the OMS | Available |
| Consignee (ship to) | Order ship-to address | Available |
| Bill freight to | Order bill-to address, **or** a freight account | Bill-to available. *Is freight billed to the order's bill-to party, to ShipItEZ, or to the consignee?* |
| PO / reference numbers | Order PO number, order number | Available |
| Carrier | Order carrier and ship method | Available, but LTL carriers like Estes may not be set up as ship methods. *Not checked* |
| Special instructions | Order instructions | Available |
| Item lines (description, quantity) | Order lines | Available. *Bottles, cases or pallets?* |
| **Pallet / handling-unit count** | No per-order pallet count in the OMS. It keeps pallet labels only for BOLs the WMS shipped, and a per-facility *cases per pallet* billing setting | **Missing.** Packing happens in the WMS |
| **Weight** | The OMS has no order weight, only item, product and parcel weights. The WMS has an order weight (whole numbers) | Partly. *Is the sum of item weights good enough, or must it be the weighed pallet?* |
| **NMFC number, freight class, dimensions** | Nothing in either system | **Missing.** Searched oms-laravel-api for `nmfc`, freight class and `ltl`: no hits |
| PRO number, pickup date, signatures | Carrier and driver | Leave blank, filled at pickup |

**The question:** for the **missing** rows, should the system **leave them blank** to fill by hand (smallest change),
**ask for them** when someone generates the BOL (a short form), or **store them** (freight class and NMFC per SKU,
pallet count from the WMS)? We recommend **asking at generation time**, pre-filled where possible. Storing per-SKU
freight data is a larger feature.

### Q3. Which orders get a BOL?

- **Where:** a *Print BOL* action on the order in the OMS (siteboss-frontend). *Also from a list of several
  orders at once?*
- **Which orders:** only freight/LTL orders? **No dedicated freight/LTL flag exists.** The OMS order has a free-text
  *shipping mode* field that we haven't checked as a marker. Should it be the carrier/ship method, a client
  setting, or simply available on any order?
- **Whose:** ShipItEZ only, or every client of every warehouse? (ShipItEZ's company details and Truman's terms
  suggest the template is **per client** or **per warehouse**. *Which?*)

**Our recommendation:** available on any order for clients that have a BOL template set up, with the template
chosen per client. That keeps WineCo and others unaffected.

### Q4. Keep generated BOLs?

Options: generate fresh every time (no storage), or **save each generated PDF on the order** so the exact document
handed to the driver can be found later. We recommend **saving it**, because a BOL is a legal shipping document and
re-generating after the order has changed would produce a different one. *How long must it be kept?*

### Q5. Two confirmations

- **David:** do you have an unpushed BOL branch? (Asked on the ticket 2026-11-07; nothing found on any remote.)
- **The pickup sheet (document a):** is that a **second**, separate request (a winery pickup / inventory release
  sheet), or only an example? If it is wanted, it belongs on its own ticket.

## What happens after the answers

- **Tier: T3.** Multi-repo (oms-laravel-api for the PDF, siteboss-frontend for the button), a new document type,
  probably a new table if Q4 = save, and the requirements are still open.
- **The ticket should be retagged** from WMSv2 to OMS v2 (part of the 2026-11-07 decision).
- **Next step:** once the template (Q1) and the field rules (Q2) are settled, write a feature plan. The PDF itself
  reuses the pick-sheet pattern, so the rendering is the cheap part. The field sourcing (Q2) and the order
  eligibility rule (Q3) are where the effort goes.

## Answers

*Fill in during the conversation with Brent. Date each answer. Then copy the decisions onto the ticket.*

- **Q1 (template; who approves the wording):**
- **Q2 (missing fields: blank / ask / store; freight bill-to; units):**
- **Q3 (which orders; per client or per warehouse; single or many):**
- **Q4 (keep generated BOLs; how long):**
- **Q5 (David's branch; pickup sheet):**
- **Anything else raised:**
