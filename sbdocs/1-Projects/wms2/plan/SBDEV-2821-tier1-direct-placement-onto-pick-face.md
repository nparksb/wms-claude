---
title: "SBDEV-2821 — Receive ICE PACK into the ICE PACK pick face: route at putaway, not at receipt"
ticket: "SBDEV-2821"
ticket_url: "https://app.clickup.com/t/868km8j9z"
type: "bugfix"
priority: "high"
status: "APPROVED 2026-08-08 for OPTION (iii) — route at putaway. Q4 resolved; Q1 resolved (label prints unconditionally = existing behaviour, no change). Q15 resolved 2026-08-08 as (A) — this ticket ships TIER 1 ONLY, first and independently; SBDEV-2732 extends putaway to all four tiers and now DEPENDS ON THIS TICKET (§0, §5.1 row 4). Remaining gate: **M1a** must be proven on UAT before code (§5.1 row 2). **M1b was RUN 2026-08-09 and confirmed the `cases and pallets` gap** — §3.2a is evidenced, not inferred. Decision provenance in §0."
project: [wms2]
version: "v2"
requester: "Brent Campbell (via SBDEV-2731)"
created: "2026-08-07"
updated: "2026-08-08"
db_verified: true
db_verified_note: >
  Verified SELECT-only 2026-08-07 against wms2-hydra (HMG/NYWH PRD — the reporting
  environment) and wsl-wineco-uat. Both are MIGRATED copies; the fresh-seeded
  wh01_hydra_v2t was deliberately NOT used as the sole sample — see §2.4, where
  measuring only fresh-seed data is what hid the pick-face population from
  SBDEV-2732 for two weeks.
depends_on:
  - {ticket: SBDEV-2731, sha: 6bc709a}    # MERGED 2026-08-07 (api 6bc709a / ui 4ce39a1). Message key
                                          # and receiving display shipped. Prerequisite satisfied.
  # SBDEV-2732 was listed here until 2026-08-08. REMOVED — it is NOT a prerequisite, and Q15 -> (A)
  # reversed the arrow: 2732's step-15 gate diverts pick-face receipts to the putaway lane and needs
  # THIS ticket's candidate surfacing to make them offerable, so 2732 now declares the dependency
  # instead. Leaving it here made the TDD gate look blocked on a ticket that must ship second.
  # Order: 2731 -> 2821 -> 2732. Kept under `related:` below. See §5.1 row 4 and §0 Q15.
db_verified_tenants:
  fresh_seed: [wh01_hydra_v2t]
  migrated:   [wms2-hydra, wsl-wineco-uat]
related:
  - "[[SBDEV-2731-alternate-putaway-location-not-honored-receiving]]"
  - "[[SBDEV-2732-configurable-default-putaway-location-hierarchy]]"
  - "[[SBDEV-2854-replenish-rejects-non-flowbin-destination]]"
  - "[[wms2-receiving-putaway-workflow]]"
tags:
  - plan
---

# SBDEV-2821 — Receive ICE PACK into the ICE PACK pick face

## 0. Decision record

> [!done] **OPTION (iii) — route at putaway — ADOPTED 2026-08-08.**
> One gate remains before code: **M1 must be proven on UAT** (§5.1 row 2, §6.1). If M1 fails, this design is
> void and the option choice must be reopened.

**Provenance — recorded precisely, because "everyone agreed" is how undecided things get built:**

| Question | Resolution | Who, and how firm |
|---|---|---|
| **Q5** | *(c) bounds are advisory for receiving* | B/A, via SBDEV-2796. Settled. |
| **Q11** | *advisory for replenishment too* | Recorded 2026-08-06. Settled. |
| **Q1** | **Case label prints unconditionally** — see below | Brent, 2026-08-07 ("yes… especially if it puts it in a location that is not a standard pick location where the UL label is stripped"). Settled. |
| **Q4** | **Option (iii)** | **David Oppenheim, 2026-08-08: "not only acceptable but preferable"** — then asked *"Brent?"*. **Brent has not replied to that hand-off.** Adopted on David's endorsement plus the ticket owner's direction (Nam Park, 2026-08-08). **Not a recorded Brent sign-off.** |
| **Q15** | **(A) — tier 1 ships here, first and independently** | Ticket owner (Nam Park), 2026-08-08. Recommended by both plans before it was decided. Schedule-only; reversible. |

> [!done] **✅ Q15 RESOLVED 2026-08-08 — option (A). THE ORDER IS `2731 PR1 → SBDEV-2821 → SBDEV-2732`.**
>
> SBDEV-2732's Q12 answer (iv-b) makes receiving *divert* pick-face destinations to the standard putaway
> lane at **every tier**, leaving putaway to consume them. This plan consumes **tier 1 only** — it reads
> `itemdata.putawaylocation_id` directly (§3.2). (A) accepts that seam rather than closing it here:
>
> - **This ticket ships first, unchanged in scope.** It needs nothing from 2732 — `itemdata.putawaylocation_id`
>   already exists and both live overrides are tier 1 — and it is gated only on M1. **It delivers the reported
>   ICE PACK receipt without waiting on the whole hierarchy feature.**
> - **SBDEV-2732 then extends** the candidate surfacing of §3.2 from `itemdata.putawaylocation_id` to the full
>   four-tier `Resolution`, as a step in its own plan.
>
> **⚠ This REVERSES the order 2732 §8.4 previously stated** (*"2731 PR1 → 2732 → 2821"*), which was written
> when 2821 was the follow-up that consumed 2732's output. Under (iv-b) the dependency runs the other way:
> **2732's step-15 gate is only safe once this plan's candidate surfacing exists**, otherwise a diverted
> receipt reaches a putaway list that cannot offer its own configured destination —
> `getStorageLocationsForPutAwayItemData` (`LocationRepository:104-111`) returns only locations where the SKU
> **already has stock**, which is precisely the chicken-and-egg §3.2 fixes. 2732 §8.4 and its `depends_on`
> were corrected the same day.
>
> **Degraded, not broken, if the order is violated:** the operator can still *manually scan* the destination
> (`verifyScannedLocation:403-447` accepts it — §3.2), so shipping 2732 first strands the destination as
> undiscoverable rather than unreachable. That is a UX regression against the ticket's intent, not data loss.

**If Brent later objects to (iii), Q4 reopens.** The alternatives and their costs are preserved in §9 so
that reversal is cheap.

**Q1 needs no code under this option.** Brent's answer is *print unconditionally* — which is what v1 did,
what v2 ships today, and what option (iii) leaves untouched, because receiving is never modified. **C1
(suppress the label on the flowbin path) is moot here:** it only exists inside a receiving-side flowbin
path, and option (iii) creates none. C1 stays recorded in §9 as live **only** under option (ii).

> ⚠ **On how Q1 was asked.** The question labelled "(a) suppress" as *"current plan"*. That was accurate
> about SBDEV-2731's §10 C1 decision, but **the code has never suppressed** — v1 and v2 both print
> unconditionally. Presenting a plan proposal as "current" beside "still print it" risked reading as *"the
> system suppresses today"*. It does not. Brent's answer lands in the same place either way, but the
> framing was imprecise and is corrected here for the record.

**David's follow-up idea, deliberately out of scope:** *"we could build an automation that can be triggered
to effect automation at a later point"* — i.e. auto-trigger the putaway step so no operator scan is needed.
**That belongs in a separate ticket, and option (iii) is what makes it cheap.** Placement logic stays in one
audited place (`storeBoxOnLocation`), so automating it later means invoking existing code on a trigger.
Under option (ii) the same logic would be duplicated into receiving, leaving two implementations of "put
stock on a pick face" to keep in sync. **(iii) is a step toward that automation; (ii) is a detour from it.**

---

## 1. Problem Statement

SKU `ICE PACK` (itemdata 52072) on HMG/NYWH production is configured with a Default Putaway Location of
`ICE PACK` (location 52075). Receiving it fails:

> `Unit load type ID 4 not allowed on location Ice Pack with location type ID 2`

SBDEV-2731 made that message actionable. SBDEV-2732 makes the destination resolve and display, and adds the
configuration surface. **Neither lets you receive the SKU.** Brent's headline criterion — *"Ice Pack SKU can
be received successfully into the Ice Pack location"* — is delivered **here**.

The reported receipt is **1,000 units**, advice `IBOL000221`, adviceposition 52077.

---

## 2. Root Cause Analysis

### 2.1 The failure

`ReceivingService.java:491-494` places a freshly created **Case** unit load with
`transferUnitLoadToLocation`. `ICE PACK` is a **flowbin**, whose only `location_constraint` row permits
`unitloadtype_id = 1` (`PickLocation`). The Case unit load is rejected. The rejection is *correct* — a Case
unit load may not sit on a pick face. The bug is that receiving uses the whole-unit-load transfer primitive
against a location that requires stock-level merging.

### 2.2 Two premises in the original tickets are wrong — corrected 2026-08-07

Both SBDEV-2796 and this ticket's original description state that `ICE PACK` is *"a flowbin, i.e. a pick face
**carrying a FixLocationAssignment**"*, with 1,000 units against `upperbound = 84` — a *"12× overfill"*.

**Measured on HMG production:**

| Location `ICE PACK` (id 52075) | Value |
|---|---|
| `type_id` / `sltname` | 2 / **`flowbin`** |
| Area | *Storage and Picking* — `useforstorage = true`, `useforpicking = true` |
| **`FixLocationAssignment` rows on the location** | **0** |
| **FLAs for SKU `ICE PACK` (itemdata 52072)** | **0** |
| Unit loads / stockunits currently on it | **0 / 0** |
| `stockunit` rows for the SKU **anywhere** | **0** |

The `36 / 60 / 84` bounds belong to the other **133** FLAs on that tenant. **`ICE PACK` has no bounds at all.**
Consequences:

- **Q11's over-bound-bin concern cannot arise for the reported receipt.** The answer stands; it is moot here.
- **Relaxing P2.5 does not unblock `ICE PACK`** — P2.5 is the FLA check and there is no FLA to match. In
  SBDEV-2732's *pre-(iv-b)* design what would have blocked the **configuration** is its **P2.7(c) clause 1**,
  the pick-face predicate (`location_area.useforpicking`). **⚠ UPDATED 2026-08-08 — that is no longer the
  case, in either direction:** the `ICE PACK` override **already exists in production**
  (`itemdata.putawaylocation_id = 52075`), so nothing blocks it *today* — 2732 has not shipped and P2.7(c)
  is a proposed write-time rule, not live code. And under 2732's Q12 → **(iv-b)** that rule is **dropped at
  all three scopes**: a pick face is a legal configuration at every tier, and it is the *placement* that is
  refused, by a runtime gate in receiving. **So SBDEV-2732 blocks this ticket's configuration neither now nor
  after it ships**, which is why §5.1 row 4 lists it as not required.
- **An FLA-free, empty pick face is a third case** the design must name, alongside "has FLA" and
  "has resident unit load".

### 2.3 Both live override SKUs are the same shape

| Tenant | SKU | Destination | Location type | Area `useforpicking` | FLA rows |
|---|---|---|---|---|---|
| `wms2-hydra` (HMG PRD) | `ICE PACK` | `ICE PACK` | **flowbin** | true | **0** |
| `wsl-wineco-uat` | `1135` | `Club08` | **cases and pallets** | true | **0** |

Every override in real use is an **FLA-free pick face**. The location-*type* difference is load-bearing —
see §3.3.

### 2.4 Why this was missed for two weeks

SBDEV-2732's P2.7 correction was measured on `wh01_hydra_v2t` — the fresh-seeded copy, and the **one tenant
that structurally cannot exhibit this** (no picking area there is also storage or goods-in). A predicate
validated only against fresh-seed data is validated against the case that cannot fail. **Every P2 measurement
must run against a migrated tenant as well.**

---

## 3. Design / Proposed Fix — option (iii), route at putaway

### 3.1 The insight: Fix B already exists, in putaway

`MobilePutAwayService.storeBoxOnLocation:471-489`, flowbin branch:

```java
FixLocationAssignment fla = fixLocationAssignmentRepository.findByAssignedlocationId(location.getId()).orElse(null);
Stockunit sourceStockUnit = stockunitRepository.findByUnitloadId(unitLoad.getId()).get(0);
if (fla == null) {
    Itemdata itemData = itemdataService.getById(sourceStockUnit.getItemdataId());
    fla = fixLocationAssignmentService.createFixedLocationAssignment(location, itemData);  // auto-create
}
Unitload assignedUnitLoad = unitloadRepository.findById(fla.getAssignedunitloadId()).orElseThrow(...);
stockunitBusinessService.transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad, ...);   // resident-UL merge
```

That is **Fix B** — flowbin classification, FLA auto-creation when absent, resident-unit-load resolution,
stock merged into it. **Already built, tested and in production.** It never calls
`transferUnitLoadToLocation` for a flowbin, so **the reported error cannot occur on this path**.

### 3.2 What actually has to change

`LocationRepository.getStorageLocationsForPutAwayItemData:104-111` builds the putaway suggestion list from
**where the SKU already has stock**:

```sql
FROM stockunit su JOIN itemdata i ... JOIN location l ... JOIN location_area a
WHERE i.id = :itemDataId AND a.useforstorage = 'true'
```

`ICE PACK` has **zero stockunits anywhere**, so this returns **zero candidates** — a chicken-and-egg: you can
only put away to where the SKU already is.

**But `MobilePutAwayService.verifyScannedLocation:403-447` already ACCEPTS a manual scan of `ICE PACK`:**
the area is `useforstorage = true`, and on the flowbin branch the SKU has no FLA *and* the location has no
FLA, so it passes.

> **The capability substantially exists today; it is not discoverable.** The change is to surface the SKU's
> configured `putawaylocation_id` as a candidate destination even when no stock is there yet.
>
> ⚠ **This is a code-path read, not an executed test.** §6.1 M1 proves it on UAT *before* any code is written.
> If M1 fails, this design is wrong and the option choice must be revisited.

**The change:** in `calculatePutAwayList` (`MobilePutAwayService:268`), union the SKU's configured
`putawaylocation_id` into `resultList` before the location-type switch, de-duplicated, and only when it is
not already present. The existing switch then buckets it correctly by type (flowbin → `flowBinLocationList`,
overstock → `overstockLocationList`). Prefer a repository-level change so the type switch stays untouched.

**Do NOT** reuse `getStorageLocationsForPutAwayItemData` by relaxing its `WHERE`. That query is also
`@RestResource`-exported and used elsewhere; widening it changes unrelated callers.

> **Tier scope, and the extension point (Q15 → (A), 2026-08-08).** `itemdata.putawaylocation_id` is
> **tier 1** — the SKU override. SBDEV-2732's (iv-b) diverts pick-face destinations to the putaway lane at
> **all four tiers**, so its merchant- and warehouse-scope defaults will need the same surfacing. **Build
> this for tier 1 and stop.** Design the new repository method so the destination arrives as a *parameter*
> rather than being read from `itemdata` inside the query — then 2732 extends it by passing
> `Resolution.locationId()` from `PutawayDestinationResolver` instead of rewriting it. That is the whole
> cost of taking (A), and it is why (A) was affordable.

### 3.2a `MobilePutAwayService` must handle `cases and pallets` — SCOPE ADDED 2026-08-08

> **This ticket now owns this fix.** It was unowned until 2026-08-08: SBDEV-2732 has no
> `MobilePutAwayService` step, and this plan was scoped tier-1-only. **Without it the club use case cannot be
> consumed at putaway by anyone**, which made SBDEV-2732's claim *"the club use case ships, safely"* false.

`storeBoxOnLocation:472-503` switches on `locationType.getSltname()` against exactly **three** constants —
`WmsConstants.java:736-738`: `"flowbin"`, `"overstock box"`, `"overstock pallet"`. **`"cases and pallets"` is
a FOURTH constant** (`WmsConstants.java:741`, `STORAGE_LOCATION_TYPE_STOCK_RESTRICTION`) matching none of
them, so it falls through to `default:` at `:496`, and since club locations have `staginglane = false` it
reaches `:502`:

```java
throw new BusinessException("Unsupported location type " + locationType.getSltname());
```

**Worse, the failure is late.** `verifyScannedLocation:418` gates only on `!useforstorage && !staginglane`.
Club locations sit in *Storage and Picking* with `useforstorage = true`, so **the scan is ACCEPTED and the
store then throws** — the operator scans, gets a tick, then an error.

`calculatePutAwayList:273-286` carries the same switch; its `default:` at `:284-286` **silently drops** the
location with only a debug log, so a surfaced candidate never reaches the operator either.

**Scope: 70 locations on `wsl-wineco-uat`. HMG PRD is unaffected** — all 191 of its picking-area locations are
`flowbin` (179) or `overstock box` (12), both already handled.

**The fix:** add `STORAGE_LOCATION_TYPE_STOCK_RESTRICTION` to both switches, taking the same branch as the
overstock constants — `transferUnitLoadToLocation`, **no FLA auto-creation**. That last part is load-bearing:
`Club08` is shared across 27 SKUs, and auto-binding it to one SKU via a `FixLocationAssignment` is exactly the
defect SBDEV-2854's plan warned about. **The FLA branch must stay reachable only from `flowbin`.**

**M1a does not cover this** — it exercises the FLA-free *flowbin* path, which works, so it goes green while
leaving this failure undetected. **§6.1 now carries `M1b`** for the `cases and pallets` branch. Neither M1a
nor M3 alone is sufficient evidence that the club use case works; M1b is the one that proves this fix.

### 3.3 The two live SKUs take different branches — both safe, and the difference is load-bearing

| SKU → destination | Location type | Putaway branch | Effect |
|---|---|---|---|
| `ICE PACK` → `ICE PACK` | **flowbin** | FLA auto-create + resident-UL merge | Binds the location to the SKU — **correct** for a dedicated location |
| `1135` → `Club08` | **cases and pallets** | ⛔ **`default:` → THROWS** | **This branch does not exist** — see the box below |

The second row matters. `Club08` is shared across **27 SKUs**. Auto-binding it to one SKU would be a real
defect — SBDEV-2854's plan flagged exactly this (*"would silently re-bind shared Club01 to one SKU at commit
time"*). **The location-type difference prevents it.** Any change here must preserve that: FLA auto-creation
must remain reachable only from the `flowbin` branch.

### 3.4 What this design deliberately does NOT do

- **No new receiving branch.** `ReceivingService` is untouched. **⚠ Scoped to THIS ticket's diff — read it
  that way when both tickets are in flight.** SBDEV-2732 *does* modify `ReceivingService:451-459` (resolver
  wiring, plus the (iv-b) `useforpicking` gate at its step 15). The two changes do not overlap: 2732 owns the
  receiving surface (its D14), this plan owns the putaway surface. Nothing here needs to change when 2732
  lands — but do not read "receiving is untouched" as a program-level guarantee.
- **No `Goodsreceiptposition` repointing** ⇒ **C2b cannot arise** (see §3.5).
- **No FLA auto-create code** — exists.
- **No resident-UL resolution code** — exists.
- **No `Replenishorder` locks inside the receive transaction**, no Inbound-row lock re-scoping.
- **F1, F4, F5 drop out of scope** — they were consequences of building direct placement in receiving.

### 3.5 Why C2b disappears

**C2b:** repointing `Goodsreceiptposition.stockunitId` / `.unitloadId` at a flowbin's resident rows makes
receipt correction destructive — `GoodsReceiptPositionService.delete:159-167` reads
`position.getStockunitId()` and calls `sendStockUnitToNirvana(...)`, so deleting **one** position would
nirvana the **entire** flowbin balance.

Under option (iii) the goods-receipt position keeps pointing at the receipt's **own** unit load and stockunit.
Putaway moves stock afterwards as a separate, already-audited operation. **Nothing is repointed, so the
defect is unreachable.** This is the single largest reason to prefer (iii).

### 3.6 Behaviour with `REQUIRE_RECEIVING_TO_CONTAINER = TRUE`

Under (iii) the sysprop and the SKU override **stop interacting entirely**:

1. UI hides the no-container switch (`receivingForm.vue:92`); the operator must pick a container.
2. `ReceivingController:274` — `storeOnCarrier = true`; `ReceivingService:387` — `carrier != null`.
3. `ReceivingService:454` never looks up the configured location; `:494` → `transferUnitLoadToCarrier`.
4. Case label prints unconditionally (v1 parity — see §9 Q1).
5. Pallet moves to `PutAwayLane` by the existing flow.
6. Putaway offers the configured location (§3.2) → operator confirms → §3.1 places it.

**No tenant's receiving behaviour changes** — *as a result of this ticket*. This is why (iii) needs no
decision about container precedence, whereas (ii) does. **SBDEV-2732 does change receiving behaviour** for
non-pick-face destinations (its step 17 places staging / goods-in / cross-dock destinations directly at
receipt); that is its change to justify, and it is orthogonal to the flowbin path this plan fixes.

**Note the pre-existing asymmetry it also sidesteps:** the sysprop is enforced **UI-only** — read once at
`ReceivingController:318-322` and never consulted by `ReceivingService`. `ReturnAdviceAutoReceiveService:556`
calls `receiveGoods(..., null, false, ...)` with a hard-coded null carrier, so **return auto-receive already
ignores the container requirement and honours the configured destination** while the web screen does not.
Option (ii) would widen that divergence; option (iii) leaves receipt semantics identical on both paths.

---

## 4. V1/V2 Applicability

**v1 and v2-as-shipped are line-for-line identical** at `v1/wms-api/.../ReceivingService.java:520-526` and
`v2 ReceivingService.java:491-494`:

```java
if (carrier == null) { transferUnitLoadToLocation(unitload, putAwayLocation, ...); }
else                 { transferUnitLoadToCarrier(unitload, carrier, ...); }
```

- **The container takes precedence in v1.** A selected carrier means the SKU override is ignored entirely.
- **v1 printed the case label unconditionally** — `createCaseLabel` sits outside the branch.

So **option (iii) is v1-parity at the receiving layer**, and both C1 (label suppression) and D2 (override beats
container) are *departures* from v1 that arose in planning rather than from a stated requirement. **v1 is not
fixed either** — it has the same flowbin failure; parity here means "we change nothing that already worked".

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Status |
|---|---|---|
| 0 | **Q4 answered — option (iii) chosen** | ✅ 2026-08-08 (§0). David endorsed; adopted by the ticket owner. Brent's concurrence not separately recorded. |
| 1 | **Q1 — case label** | ✅ Resolved, **and requires no code**: prints unconditionally, which is existing behaviour. C1 is moot under (iii) — §0, §9. |
| 2 | **M1 proven on UAT** (§6.1) — manual scan of an FLA-free flowbin succeeds today | ⛔ Not yet run. **If M1 fails, this design is void.** |
| 3 | SBDEV-2731 PR1 merged | ✅ 2026-08-07 — api `6bc709a`, ui `4ce39a1` |
| 4 | SBDEV-2732 | **Not required by (iii)** — and **the dependency runs the other way** (Q15 → (A), §0). Routing works off `itemdata.putawaylocation_id`, which already exists; 2732 is needed only for the *configuration UI* and the tiers 2–4 defaults. **2732's step-15 gate, conversely, needs this ticket** — it diverts pick-face receipts to the lane and putaway can only offer the destination once §3.2 ships. **Ship this first.** |
| 6 | **Q15 answered — (A), tier 1 only, ships first** | ✅ 2026-08-08 (§0). Order is `2731 PR1 → this ticket → SBDEV-2732`. |
| 5 | Flyway migration | **None.** No schema change. |

### 5.2 Steps

| # | Work | Gate |
|---|---|---|
| 1 | **Prove M1 on UAT** — manually scan an FLA-free flowbin at putaway and confirm placement succeeds. Record the result. | evidence recorded before any code |
| 2 | **TDD gate.** Write §6.2 tests failing for the right reason. **Pause for approval.** | red for the right reason |
| 3 | Repository method returning putaway candidates **including** the SKU's configured `putawaylocation_id`. Do not widen the exported `getStorageLocationsForPutAwayItemData`. | unit test |
| 4 | Wire into `calculatePutAwayList:268`; de-duplicate; leave the type switch untouched. | `PutawayControllerUnitTest` |
| 5 | Mobile UI: show the configured destination distinctly (it is a suggestion, not a constraint). | Jest spec |
| 6 | **No change — assert only.** The case label already prints unconditionally (`ReceivingService:498`, and v1 identically). Option (iii) never touches receiving, so there is nothing to reverse; C1 was scoped to a receiving-side flowbin path this option does not create. Add a regression assertion so a later change cannot silently suppress it. | test asserts label emitted |
| 7 | Full `mvn test`; revert any mutated `archunit_store`. | 0 fail |

---

## 6. Test Plan

### 6.1 Manual, on UAT — **M1 is the gate for the whole design**

| # | Scenario | Expected |
|---|---|---|
| **M1a** | Receive a Case of an FLA-free-**flowbin** SKU to a container, then at putaway **manually scan** the flowbin | Placement succeeds; FLA auto-created; stock merged into the resident UL. **If this fails, stop — the design is wrong.** |
| **M1b** | Same, against a **`cases and pallets`** pick face (a wineco club location) | Placement succeeds; **no FLA created**. ⚠ **Throws today** (`Unsupported location type cases and pallets`) — §3.2a is the fix. **M1a passing does NOT imply M1b passes: they take different switch branches.** |
| M2 | Repeat with the configured location surfaced in the suggestion list | Appears without a manual scan |
| M3 | `1135` → `Club08` (cases and pallets) | **Placement succeeds after the §3.2a fix**; no FLA created; `Club08` stays multi-SKU. **Before that fix this throws** — see §3.2a. M3 is the test that proves the fix, not a formality. |
| M4 | SKU with no override | Suggestion list unchanged from today |
| M5 | The originating receipt: 1,000 units of `ICE PACK` on HMG | Lands in `ICE PACK`; receipt and inventory history record it |

> [!done] **✅ M1b WAS RUN — 2026-08-09, `wsl-wineco-uat`. Prediction confirmed exactly.**
>
> | Stage | Predicted | **Observed** |
> |---|---|---|
> | Scan of `Club08` | ACCEPTED | ✅ **Accepted** |
> | Store the box | throws `Unsupported location type cases and pallets` | ✅ **`Unsupported location type cases and pallets`** |
>
> **The accept-then-throw sequence is now OBSERVED, not inferred.** The operator scans a location, gets a
> successful scan, and only then gets an error. That is a worse operator experience than a clean rejection
> and it is why this cannot be dismissed as a configuration mistake.
>
> **What this settles:**
> - **§3.2a is confirmed necessary**, on evidence rather than a code read. `storeBoxOnLocation` genuinely
>   cannot consume a `cases and pallets` destination.
> - **SBDEV-2732's club use case is confirmed blocked** until §3.2a ships — the earlier claim that it
>   *"ships, safely"* on 2732 alone was false, and this is the proof.
> - The static analysis behind option (iii)/(iv-b) is **validated on the branch it was tested against**.
>
> **What this does NOT settle — read this before treating the gate as green:**
> **M1a has not been run.** M1b exercised the `cases and pallets` branch. **M1a exercises the `flowbin`
> branch — FLA auto-creation plus resident-unit-load merge — and that is the path the reported `ICE PACK`
> bug takes.** The two take different `switch` arms, so **M1b passing its expectation tells us nothing about
> M1a**, exactly as M1a would have told us nothing about M1b. **M1a remains the gate that voids the design
> if it fails.**
>
> **After §3.2a ships, re-run M1b** with the expectation flipped: placement succeeds, **no FLA created**,
> `Club08` stays multi-SKU.

#### M1a — runnable procedure, fixture verified on `wsl-wineco-uat` 2026-08-09

> [!warning] **⚠ M1a LEAVES PERMANENT STATE ON UAT — M1b did not.**
> `createFixedLocationAssignment` (`FixLocationAssignmentService:82-100`) creates a **virtual
> `PickLocation` unit load** on the location and a `FixLocationAssignment` row binding
> **location ↔ SKU**. `fix_location_assignment` is `UNIQUE(assignedlocation_id)` **and**
> `UNIQUE(itemdata_id)`, so **each SKU can only ever hold one**. Consequences:
> - **M1a is single-use per SKU/location pair.** A re-run needs a fresh pair — spares listed below.
> - The binding survives the test. On UAT that is harmless, but it is a real row: decide deliberately
>   whether to leave it or have a DBA remove the FLA and its virtual UL.

**Fixture — an OPEN advice already exists, so no setup is required.**

| | |
|---|---|
| Advice | **`IBOL015140`** (state `OPEN`), adviceposition **33874177** |
| SKU | **`SBB18S`** — *2018 Sparkling Blanc de Blancs 750 ml*, itemdata **26571284**, `defultype_id = 4` (**Case**), **no FLA** |
| Location | **`04-A01`** — id **63881**, **flowbin**, `entity_lock = 0`, **0 unit loads, 0 FLA** |
| Location permits | `unitloadtype_id = 1` (**`PickLocation`**) **only** — see below, this is the point |
| FLA bounds it will create | `lowerbound 36` / `middlebound 60` / `upperbound 84` (from sysprops) |
| Spare pairs | locations `01-B05` (63821), `04-A05` (63885) · SKUs `DTW-01` (607940912), `22PNLV750` (826712472) |

**Why this test is the design gate.** `04-A01` permits **only** `PickLocation` unit loads. A Case unit load
placed there by `transferUnitLoadToLocation` is exactly SBDEV-2731's reported error. **M1a proves that
putaway's flowbin branch sidesteps that constraint** — by auto-creating the FLA, resolving its virtual
`PickLocation` unit load, and merging stock into it with `transferStockToUnitLoad` rather than moving the
Case UL onto the location. If that does not work, option (iii)/(iv-b) has no mechanism.

**Steps** — identical to M1b except the location.

1. **Do NOT create a Purchase Order.** The advice already exists and is OPEN. Go to **Receiving**, select
   client **`Adelsheim`**, open advice **`IBOL015140`** (position `IBOL015140-000000`, 1 case) and receive it.
   Take a container when asked.
   > ⚠ **Corrected 2026-08-09 after a failed run.** The step previously read *"Receive one case of `SBB18S`
   > against advice `IBOL015140`"*, which was taken as an instruction to create a PO. `SBB18S` does not appear
   > in the Create-Purchase-Order item list unless client **Adelsheim** is selected — the list is client-scoped.
   > **Creating a PO is not part of this test.**
   >
   > **If Adelsheim is not available in your session, any of these OPEN positions works** — all are Case-type
   > SKUs with no existing FLA, which is the only precondition that matters:
   >
   > | Client | Advice | SKU | Cases |
   > |---|---|---|---|
   > | Adelsheim | `IBOL015140` | `SBB18S` | 1 |
   > | Adelsheim | `IBOL015177` | `SBB18S` | 3 |
   > | Brooks Winery | `IBOL015195` | `BW15RSW` | 1 |
   > | Brooks Winery | `IBOL015199` | `BW23GN` | 1 |
   > | Cristom Vineyards | `IBOL015178` | `22PNLV750` | 1 |
   >
   > **Swapping the SKU is safe. Do not swap the location** — `04-A01` must stay, and it must still have no FLA.
2. Move the pallet to `PutAwayLane`.
3. Mobile → **Putaway** → **Scan Pallet**.
4. Tap **"Replenish Location(s)"**.
5. **⚠ BEFORE typing anything, check the header.** The screen reads **`Product - N of M`** and shows
   **`SKU:`** below it. **It must show the SKU you just received.** If it does not, use the **`<` / `>`
   arrows** to move to it.
   > **This step was added 2026-08-09 after a failed run** that returned `itemDataNotMatchFixedAssignment`.
   > **That was not a defect** — `verifyScannedLocation:430-437` validates the scanned location against the
   > **currently-selected SKU in the putaway list**, not against the box you are about to scan. The list is
   > built from everything on the scanned pallet, and `PutAwayLane` on `wsl-wineco-uat` carries **1,373 unit
   > loads across 238 SKUs, 108 of which already have a `FixLocationAssignment` bound elsewhere**. Landing on
   > one of those 108 and scanning `04-A01` produces exactly that error.
   >
   > **Two ways to avoid it, in order of preference:**
   > 1. **Receive onto an empty pallet** so the putaway list contains only your SKU — `Product - 1 of 1`.
   > 2. Or arrow across to your SKU before scanning the location.
   >
   > **If you see `itemDataNotMatchFixedAssignment`, the test has not run yet** — you were on the wrong
   > product. It is not an M1a result and must not be recorded as one.
6. At **"Scan Location"**, type **`04-A01`**.
7. At **"Scan Box"**, scan the box label.

**Predicted outcome**

| Stage | Prediction | Why |
|---|---|---|
| Scan of `04-A01` | **ACCEPTED** | `verifyScannedLocation:430-444` — SKU has no FLA **and** the location has no FLA, so the mismatch branch passes |
| Store | ✅ **SUCCEEDS** | flowbin branch: FLA auto-created, virtual `PickLocation` UL created, stock merged via `transferStockToUnitLoad` |
| After | FLA exists on `04-A01` bound to `SBB18S`, bounds 36/60/84; stock on the virtual UL | |

**How to read the result**

- **Succeeds** ⇒ **the design gate is GREEN.** Putaway can consume a pick-face destination, which is the
  mechanism all of option (iii)/(iv-b) rests on. Implementation can start.
- **Throws** ⇒ **STOP.** The mechanism does not exist and option (iii)/(iv-b) has no basis. Q4 and Q12 both
  reopen, and SBDEV-2732 step 15's divert becomes a dead end at every tier.
- **Scan rejected at step 5** ⇒ a different failure; capture the message and stop.

#### M1b — runnable procedure, fixture verified on `wsl-wineco-uat` 2026-08-08

**Everything needed is already configured. No setup writes required.**

| | |
|---|---|
| SKU | `1135` — *2015 Roosevelt Pinot Noir 750 ml*, itemdata **740645**, `defultype_id = 4` (**Case**) |
| Configured destination | **`Club08`** — already set on the SKU |
| `Club08` | id **225755** · `cases and pallets` · area *Storage and Picking* (`useforstorage = true`, `useforpicking = true`) · `staginglane = false` · `entity_lock = 0` · **0 FLA · 0 unit loads** |
| Spare fixture | `Club07` id 225754 — identical and also empty, if `Club08` gets dirty |

**Steps**

1. Create or open an inbound advice for SKU `1135`, one case.
2. Receive it. `REQUIRE_RECEIVING_TO_CONTAINER = TRUE` on this tenant, so the screen will require a
   container — **that is expected**; take one.
3. Move the pallet to `PutAwayLane` by the normal flow.
4. On the mobile putaway screen, scan the pallet, then **manually scan `Club08`**. It will *not* appear in the
   suggestion list — `getStorageLocationsForPutAwayItemData` returns only locations where the SKU already has
   stock, and `Club08` is empty. Manual scan is the point of the test.
5. Confirm the store.

**Predicted outcome — this is what the test is checking, not an assumption**

| Stage | Prediction | Why |
|---|---|---|
| Receipt | **succeeds**, stock goes to the container | container mandated ⇒ `carrier != null` ⇒ `ReceivingService:454` never reads the configured destination |
| Scan of `Club08` | **ACCEPTED** | `verifyScannedLocation:418` passes (`useforstorage = true`); the FLA branch at `:430-444` is flowbin-only, so a `cases and pallets` location skips it entirely |
| Store | ⛔ **THROWS** `Unsupported location type cases and pallets` | `storeBoxOnLocation:496-503` — the switch covers only `flowbin` / `overstock box` / `overstock pallet`; `staginglane = false` so `default:` reaches the throw |

**The accept-then-throw sequence is the finding.** The operator gets a successful scan and *then* an error,
which is why this cannot be dismissed as a config problem.

**How to read the result**

- **Throws as predicted** ⇒ §3.2a is confirmed necessary. Proceed with it; re-run M1b after the fix, where
  the expectation flips to *placement succeeds, no FLA created, `Club08` stays multi-SKU*.
- **Placement succeeds** ⇒ the static analysis is wrong somewhere. **Stop** — §3.2a, SBDEV-2732's Q12
  answer and this plan's §3.3 all rest on it, and all three need re-deriving before any code is written.

> **M1a does not substitute for this.** M1a scans a *flowbin*, which takes a different switch branch and
> works today. Running M1a alone and calling the gate green is the false-green this split exists to prevent.

### 6.2 Automated

- Configured location appears in candidates when the SKU has **no stock anywhere** (the `ICE PACK` case)
- Configured location is **not duplicated** when the SKU already has stock there
- No override ⇒ candidate list byte-identical to today (**regression guard**)
- Flowbin destination ⇒ FLA auto-created, stock merged into resident UL, **no second UL on the location**
- **`cases and pallets` destination ⇒ placement succeeds and NO FLA is created** (guards §3.3 — the `Club08` defect). **This test fails today**: `storeBoxOnLocation` throws for that type. §3.2a is what makes it pass.
- Case label emitted on the direct-to-container path (C1 reversal)
- `Goodsreceiptposition` still points at the receipt's own UL/stockunit after putaway (**C2b regression guard**)

---

## 7. Horizontal Scalability Validation

No new transaction spans the receive path; putaway placement is an existing, already-audited operation with
its own transaction. **No new lock is taken in the receiving transaction** — which is precisely what F4/F5
were about, and why they leave scope under (iii). The only new work is a read extending an existing query.

---

## 8. Notes

- **The trade-off, stated plainly:** option (iii) does **not** satisfy SBDEV-2731's acceptance criterion
  *"Manual putaway is bypassed when direct putaway succeeds."* The operator still performs one putaway scan.
  **This is the only judgement call, and it belongs to the requester.** Both routes end with the stock in the
  same place; the difference is one scan versus a materially larger and riskier change.
- The auto-created FLA seeds bounds from sysprops (`36 / 60 / 84`), so a 1,000-unit receipt is immediately
  over-bound. Covered by **Q11** — bounds are advisory. It should still be **observable**: the
  `wms2.putaway.*` metric obligation inherited from SBDEV-2732 D13 travels with whichever option is chosen.
### 8.1 Inherited artifacts — disposition under each option

SBDEV-2731 relocated these here (D14 → SBDEV-2732, then 2732's D15 → this ticket). They exist in **no**
source file and in no other plan, so they had no owner until 2026-08-06. Each is named exactly as 2731 names
it, so the relocation can be verified mechanically.

| Artifact | Kind | Under **(iii)** | Under **(ii)** |
|---|---|---|---|
| `resolveFlowbinResidentUnitload` | code — F1: move into `FixLocationAssignmentService` | **Not needed.** The equivalent already exists inside `storeBoxOnLocation` (§3.1). Do not build a second one. | Required, in `FixLocationAssignmentService` per F1's accepted shape — **not** the rejected three-dependency form still described in 2731 §5/§6 |
| `saveGoodsreceiptPosition` repointing | code — the C2b site | **Not needed, and must not be built.** Positions keep pointing at the receipt's own rows; that is exactly why C2b is unreachable (§3.5) | Required, and **C2b becomes the binding gate** |
| `BusinessException.FlowbinAssignedToOtherSku` | message key | **Not needed** | Required, in **both** bundles |
| `BusinessException.SkuAlreadyAssignedToFlowbin` | message key | **Not needed** | Required, in **both** bundles |
| `BusinessException.FlowbinOccupiedWithoutAssignment` | message key | **Not needed** | Required, in **both** bundles |

All three keys are thrown **only** by a receiving-side Fix B. Under (iii) leave them unbuilt — an unreachable
operator-facing string invites a reviewer to wire it up prematurely, which is why SBDEV-2731 declined to ship
them. If (ii) is chosen they must be added to **both** `messages.properties` and `messages_en_US.properties`:
`BusinessException` resolves against `Locale.getDefault()` at construction, so a single-bundle add silently
misses. 2731's verify checks `M3`–`M8` and `B1`/`B5`–`B8`/`B13` are **skipped, not deleted**, and become live
here only under (ii).

*(`noContainer` is also flagged by `plan-reconcile.sh` near 2731's relocation notice. It is **not** a
relocated artifact — it is a `receivingForm.vue` UI flag that SBDEV-2731 shipped and still owns. Recorded here
only to close the false positive.)*

---

## 9. Alternatives Considered

| Option | What it is | Why not (yet) |
|---|---|---|
| **(i) v1 parity** | Keep `carrier == null`; change nothing | Correct and free, but the feature stays **unreachable** on container-mandating tenants — wineco UAT's `1135 → Club08` can never fire from the receiving screen |
| **(ii) D2 — direct placement, override beats container** | `(carrier == null) \|\| !isDefaultPutawayLane` | Satisfies "bypass putaway", but: departs from v1; **silently activates a dormant override** on a tenant that deliberately mandated containers; and brings back **C2b**, Fix B, F1/F4/F5 |
| **(iii) Route at putaway** ← **ADOPTED 2026-08-08** | Container receives; configured location drives the putaway step | Accepted trade-off: does **not** satisfy "manual putaway is bypassed". David: *"not only acceptable but preferable"*. Reversible — (i) and (ii) preserved above |

**Q1 — case-label suppression (C1). RESOLVED: the label prints; no code required under (iii).**

C1 (SBDEV-2731 §10, `:1785`) decided *"suppress the case label on the flowbin path"*, flagged as *"the one
operator-visible behaviour change in the plan — confirm with the requester before PR2 merges."* Brent
confirmed in favour of **printing**, and v1 printed unconditionally (`createCaseLabel` sits outside the
carrier/putaway branch), so printing is also parity.

**Under option (iii) C1 cannot apply at all** — it is scoped to a receiving-side flowbin path, and this
option creates none. Receiving is untouched, so the label prints as it always has.

**C1 remains live only under option (ii)**, where the received unit load really is retired into a resident
UL and `sendToNirvana` rewrites `labelid` to `<label>-X-<id>`, so a printed label would not scan. If (ii) is
ever revived, C1 must be re-decided against Brent's answer, not assumed.

---

## 10. Open Questions

| # | Question | Owner | Blocks |
|---|---|---|---|
| ~~Q4~~ | ~~Routing precedence~~ | — | ✅ **CLOSED 2026-08-08 — option (iii)** (§0) |
| ~~Q1~~ | ~~Case label: print or suppress~~ | — | ✅ **CLOSED — prints unconditionally; no code needed** (§0, §9) |
| ~~Q15~~ | ~~The tier seam — ship tier 1 independently (A), or wait for 2732's resolver (B)?~~ | — | ✅ **CLOSED 2026-08-08 — (A).** Tier 1 ships here, first. `depends_on: SBDEV-2732` does **not** become hard; **2732 gains a dependency on this ticket** instead. Order: `2731 PR1 → 2821 → 2732`. Rationale, the reversed arrow and the degraded-not-broken analysis in **§0**; the extension point in **§3.2** |
| **M1a/M1b** | Not a question but the remaining **gate**: does a manual putaway scan succeed for **both** an FLA-free flowbin (M1a) **and** a `cases and pallets` club location (M1b)? **M1a alone is a false green** — it exercises the branch that already works. | implementer, on UAT | **Everything.** If M1a fails, the design is void and Q4 reopens. |
| Q13 | If (iii): should the configured location be **pre-selected** at putaway, or merely offered? | Brent | §5.2 step 5 — UX only |
| Q14 | If (iii): should receiving *display* the eventual destination, even though it routes to a container first? | David | Interacts with SBDEV-2732 §3.11.1 |
