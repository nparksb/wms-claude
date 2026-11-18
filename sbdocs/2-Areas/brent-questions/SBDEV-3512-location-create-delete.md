---
title: "SBDEV-3512 Create and delete warehouse locations: questions for Brent"
type: questions
status: open
version: v2
scope: location management / master data / authz
owner: "Nam Park"
ticket: "SBDEV-3512"
ticket_url: "https://app.clickup.com/t/868m9qcdf"
requester: "Ryan Fernandez (ShipItEZ), via the ShipItEZ standing meeting 2026-09-24; ticket written by Scott Dalton"
created: 2026-11-07
updated: 2026-11-07
last_verified: 2026-11-07
verified_by: "code read at wms2-api origin/develop cd17fc32, wms2-web-ui origin/develop 885929e and origin/main; SQL on ShipItEZ PRD (c1wh wh01_shipitez_v2, nywh wh02_shipitez_v2) 2026-11-07; independent fact-check lane 2026-11-07 (missed SDR guard found, NY count corrected, name-only history references added)"
related:
  - SBDEV-1468-edit-flowbins.md
  - ../../3-Resources/architecture/wms2-keycloak-role-matrix.md
tags:
  - questions
  - location
  - v2
---

# SBDEV-3512 Create and delete warehouse locations: questions for Brent

## The ask

The ticket's own four open questions are the right ones. Here they are with what the system does today and a
recommendation for each:

1. **Delete or retire?** A location that open work or configuration still points at can't be deleted, so it needs
   a *retire* state. Meanwhile a location whose only trace is stock history *can* be deleted, which loses track of
   it. We recommend **delete for never-used locations, retire for the rest**
   (see [Q1](#q1-delete-or-retire)).
2. **What must be clear before a location can be retired or deleted?** We propose a checklist
   (see [Q2](#q2-what-must-be-clear-first)).
3. **Who may create and remove locations?** Today, **anyone who can sign in** can delete one
   (see [Q3](#q3-who-may-do-it)).
4. **How should creation work: a form, cloning, or import?** (see [Q4](#q4-how-should-creation-work)).

Plus one point to confirm: what *auditable* means ([Q5](#q5-what-does-auditable-mean)).

**Before the meeting:** the ticket is an AI summary marked *not yet verified*. Brent is an assignee with David
and Leo. Some answers may need Ryan at ShipItEZ.

## The ticket

[WMSv2 — Allow Authorized Users to Create and Delete Warehouse Locations](https://app.clickup.com/t/868m9qcdf).
Created by Scott Dalton from the ShipItEZ standing meeting of 2026-09-24. Assigned to David Oppenheim, Leonardo
Castro and Brent Campbell. **Status:** `Open` · priority normal · Phase *Intake* · Item Type *Enhancement*. No
comments yet.

**The request:** Ryan Fernandez asked for authorized ShipItEZ users to create and remove locations themselves,
instead of asking SiteBoss staff. David said it is high on the list.

**The ticket's acceptance criteria, in short:** create with validation; remove or retire; a location holding stock
can't be silently deleted; a location in active use is protected; history stays readable; clear reasons when
removal is refused; only authorized users; create and remove are auditable.

**Out of scope (per the ticket):** bulk flowbin settings (that is [SBDEV-1468](SBDEV-1468-edit-flowbins.md)),
a warehouse map, moving stock, physical geometry.

## What exists today (checked 2026-11-07)

More is already built than the ticket assumes. Some of it is hidden, and some is live without protection.

| Capability | API | Web UI | On prod? |
|---|---|---|---|
| **Create one location** | Yes. `POST /v3/location/create` checks the name is unique and fills in defaults (note: a new location defaults to *automation lane = yes*) | **No.** The *Create New* button on Storage Locations is commented out. The store action that would call it is never used, and it sends `PUT` to a `POST` route, so it would not work as written (not tested) | API yes, UI no |
| **Create many (import)** | Yes. `/import/locations` creates locations together with their racks, rows, areas and types | Yes. *Admin › System Management › Import Data*, gated by the *Import Data* permission | Yes. This is probably how ShipItEZ's batches were loaded (277 in 2025-05, 150 in 2026-02) |
| **Edit a location** | Yes. `PUT /v3/location/update` | No edit form on the screen | API only |
| **Delete a location** | Yes. The generic `DELETE /v3/location/{id}` | **Yes.** Each row on Storage Locations has *Delete* (the system locations Nirwana, Clearing, Spawn and CycleCount are refused) | **Yes, live** |
| **Retire / deactivate** | No. The location table has no active, retired or locked flag | No | — |

**How delete behaves today:**
- It is a **hard delete**: the row is removed.
- **It is refused while one of 13 database links still points at the location.** These are strict foreign keys:
  stock on unit loads, fixed assignments, SKU and client putaway defaults, cycle-count lines, replenishment and
  picking orders, goods receipts, BOLs, and transfer, staging and automation lanes. So a location holding stock
  **cannot** be deleted, which already meets the "no silent delete" AC.
- **Records that hold a location by name or plain number are not checked.** Stock history, unit-load, picking,
  replenishment and cancellation logs, the putaway-config audit, and the `DEFAULT_PUTAWAY_LOCATION` setting all fall
  in this group. A location whose only trace is in these records **can** be deleted. In CA at least 813 of the 1,383
  "deletable" locations have stock history (that is a lower bound; the exact query timed out).
- **The refusal reason is generic.** SBDEV-4066 (web UI only; on `develop` 2026-11-07, not yet on prod) replaced
  the raw SQL message with *"it is still in use (other records refer to it)"*. It doesn't say what refers to it.
  The API still returns the raw SQL. 4066 also makes delete refuse a row someone changed since the list loaded;
  prod doesn't have that yet.
- **No permission check beyond signing in, today.** The delete route is the generic one. The API has a rule that
  would require *View Storage Location* for it, but that guard is switched per tenant by the setting
  `WMS2_SDR_READ_GUARD_MODE`, and it is **OFF** on both ShipItEZ warehouses. So any signed-in WMS user can call it.
  Nothing else guards it: there is no delete handler for Location, and `SecurityConfiguration` grants `/v3/**` to
  `wms_user`.
- **Nothing records who deleted or created a location.** The table holds only created and modified timestamps,
  with no user, and there is no audit log. The server log notes a create (id and name), but not who did it.
- **Stock history refers to locations by name, not by link.** History stays readable after a delete. But if a new
  location later reuses the name, its history and the old location's history can't be told apart.

## What the data says (ShipItEZ PRD, 2026-11-07)

ShipItEZ is live on v2: 49,323 stock records in the last 7 days at CA.

| Measure | CA (`wh01_shipitez_v2`) | NY (`wh02_shipitez_v2`) |
|---|---|---|
| Locations | 2,781 | 200 |
| …holding stock (a unit load is on them) | 1,106 | 47 |
| **Deletable today** (none of the 13 links points at them; at least 813 still appear in stock history by name) | **1,383** | not counted |
| **Empty, but undeletable** (no stock, but an order, count, assignment or default still links to them) | **292** | not counted |
| Locations created since 2025 | 440, mostly in two batches (277 in 2025-05, 150 in 2026-02) | 163, the latest on 2025-08-18; none since |
| Location names in the last year's stock history that no longer exist | 0 | — |

The last row is the deletion check: no location that had stock movements in the past year has been deleted or
renamed.

**The 292 are the case the ticket is really about.** They are empty, so the warehouse may consider them gone. But
something still links to them, such as an old cycle count, a picking order or a SKU's putaway default. So delete
refuses them until those links are removed, and some links (finished orders) are never removed. Without a retire
state they stay in every list.

**The 813+ are the opposite risk.** They can be deleted today, but their stock history then points at a name that
no longer exists.

## Questions for Brent

### Q1. Delete or retire?

| Option | Rule | Effect |
|---|---|---|
| **A. Delete only (as today)** | Hard delete, refused while one of the 13 links points at the location. Improve the refusal so it names *what* refers to it | Smallest change, no schema change. But a location with lasting links can never go away (the 292), and one with only stock history disappears from it (the 813+) |
| **B. Delete if never used, otherwise retire** *(recommended)* | Never-used locations (no links **and** no stock history) are deleted. A used location is **retired**: it disappears from putaway, picking, transfer and replenishment choices and from default lists, but stays in history and reports, and can be reactivated | Covers the whole ticket. History stays exact. Retired names stay reserved, so they can't be reused by mistake |
| **C. Retire only** | No hard delete from the UI at all | Simplest rule for users. But typo locations created by mistake stay forever |

**Our recommendation: B.** It is also what the ticket's first open question leans toward. The cost is real:
retiring needs a new database column, and every place that offers a location for new work has to skip retired
ones. That is a T3 change on its own (see *What happens after*).

**Follow-up:** can a retired location's name be reused for a new location? We recommend **no**: reactivate it
instead. Otherwise stock history, which stores names, mixes the two.

### Q2. What must be clear first?

Proposed checklist before **retire** (delete already requires that *nothing* refers to the location):

| Condition | Proposed rule |
|---|---|
| Stock on the location | **Block.** Move it first (moving stock is out of scope per the ticket) |
| Open picks, replenishments, cycle counts or putaways to or from it | **Block** until they finish or are cancelled |
| A fixed (flowbin) assignment | **Block**, or **remove the assignment automatically** if it holds no stock. *Which?* |
| Set as a SKU's or client's default putaway location, a BOL's outbound location, or a lane | **Block**, and name the SKUs/clients, so someone repoints them first. *Or should retiring clear these defaults automatically?* |
| Closed history (finished orders, old counts, receipts) | **Never blocks.** That is the point of retiring |

The two questions marked *Which?* and *Or…?* are the real decisions. Auto-clearing is friendlier but changes
other records silently.

### Q3. Who may do it?

Today **any signed-in WMS user** can delete a location, as long as none of the 13 links points at it, because the
permission guard is switched off at ShipItEZ (see *What exists today*).

| Option | Effect |
|---|---|
| **A. Anyone who can open Storage Locations** | Matches how other master-data screens work today. Still wider than the ticket's "authorized users" |
| **B. A new *Manage Locations* permission** *(recommended)* | Separate from viewing. Each site gives it to the few people who own the layout (Ryan's team at ShipItEZ) |
| **C. SiteBoss admins only** | Defeats the purpose of the request |

**Our recommendation: B.** Independent of the answer, the existing delete should get **at least** the
*View Storage Location* check now, so that users who can't even see the screen can't call it. That rule is already
written. It needs the tenant's guard mode switched on, once we have checked which users and callers that would
cut off (the SBDEV-3183 check), and it can go on this ticket.

### Q4. How should creation work?

- **Single form** on Storage Locations: name, area, rack, type and lane flags. The API already exists, so this is
  mostly UI work.
- **Copy from an existing location** (the ticket's open question 4): the form is pre-filled from a chosen
  location, so only the name needs typing. This is cheap on top of the form.
- **Import** already exists for bulk (*Admin › Import*). Should ShipItEZ users get the *Import Data* permission, or
  is that for SiteBoss staff only?

**Our recommendation:** the single form with *copy from*, and keep import for SiteBoss. Ask whether ShipItEZ
needs flowbin bounds set at creation, or whether the existing *Set replenishment defaults* action afterwards is
enough.

### Q5. What does "auditable" mean?

Today nothing records **who** created or deleted a location. Options, from least to most work:
- a log line only (visible to SiteBoss engineers, not to users);
- *created by* / *modified by* / *retired by* columns on the location (a new database column);
- a full change history screen.

**Our recommendation:** the user columns, added in the same database change as the retire flag.

## What happens after the answers

- **Tier: T3 as a whole.** It touches authorization, needs a Flyway migration (retire flag and user columns),
  and spans two repos (`wms2-api`, `wms2-web-ui`). It splits into slices:
  - **(a) Gate the existing delete: T1, can start now.** Switch on the existing permission guard for ShipItEZ
    after checking who it affects (an engineering decision, not Brent's), or add a direct check to the delete
    route. Then make the refusal name what refers to the location. It goes on this ticket.
  - **(b) Create form: T2.** Re-enable *Create New*, fix the store action's HTTP method, and add *copy from*
    (Q4). The API exists.
  - **(c) Retire: T3.** A new column, plus every location chooser (putaway, picking, transfer, replenishment,
    lane pickers) skipping retired locations, plus the Q2 checks. This needs a feature plan
    (`wms-feature-plan`).
  - **(d) Permission and audit: T2.** A new function if Q3 = B, and the user columns from Q5 (which ride on
    (c)'s migration).
- No ClickUp comment has been posted yet.

## Answers

*Fill in during the conversation with Brent. Date each answer. Then copy the decisions onto the ticket.*

- **Q1 (delete or retire; reuse retired names):**
- **Q2 (checklist; block or auto-clear assignments and defaults):**
- **Q3 (who):**
- **Q4 (form / copy / import for ShipItEZ):**
- **Q5 (audit):**
- **Anything else raised (and anything to confirm with Ryan):**
