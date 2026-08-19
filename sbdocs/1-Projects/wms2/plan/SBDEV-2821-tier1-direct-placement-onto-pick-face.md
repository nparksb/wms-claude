---
title: "SBDEV-2821 — Receive ICE PACK into the ICE PACK pick face: route at putaway, not at receipt"
ticket: "SBDEV-2821"
ticket_url: "https://app.clickup.com/t/868km8j9z"
type: "bugfix"
priority: "high"
status: "merged — **PR #135 MERGED into `develop` 2026-08-09** (merge `fd90487`, feature commit `cfb6d49`); ClickUp moved to `on dev`. See §11 Implementation Status. Original approval record follows. APPROVED for OPTION (iii) — route at putaway. **M1a PASSED 2026-08-09 on wineco DEV: the design gate is GREEN** (FLA 30586183 auto-created, stock merged into virtual PickLocation UL 30586181, one UL on the location). M1b confirmed the cases-and-pallets gap. Q4 resolved; Q1 resolved (label prints unconditionally = existing behaviour, no change). Q15 resolved 2026-08-08 as (A) — this ticket ships TIER 1 ONLY, first and independently; SBDEV-2732 extends putaway to all four tiers and now DEPENDS ON THIS TICKET (§0, §5.1 row 4). **No gates remain: the M1-on-UAT prerequisite was SATISFIED 2026-08-09 by the DEV run, accepted by the ticket owner (§5.1 row 2) — M1a exercises a switch branch, not tenant data, and re-running on UAT would burn a second fixture pair for no extra coverage.** **M1b was RUN 2026-08-09 and confirmed the `cases and pallets` gap** — §3.2a is evidenced, not inferred. Decision provenance in §0. **Next action: TDD gate (§5.2 step 2).**"
project: [wms2]
version: "v2"
requester: "Brent Campbell (via SBDEV-2731)"
created: "2026-08-07"
updated: "2026-08-09"
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
> ✅ **The design gate is CLOSED.** M1a passed 2026-08-09 on `wms2-wineco-dev` (§6.1), and the ticket owner
> accepted the DEV run as satisfying the "on UAT" wording the same day (§5.1 row 2). This design can no
> longer be voided by M1. ~~One gate remains before code: **M1 must be proven on UAT** (§5.1 row 2, §6.1).
> If M1 fails, this design is void and the option choice must be reopened.~~

**Provenance — recorded precisely, because "everyone agreed" is how undecided things get built:**

| Question | Resolution | Who, and how firm |
|---|---|---|
| **Q5** | *(c) bounds are advisory for receiving* | B/A, via SBDEV-2796. Settled. |
| **Q11** | *advisory for replenishment too* | Recorded 2026-08-06. Settled. |
| **Q1** | **Case label prints unconditionally** — see below | Brent, 2026-08-07 ("yes… especially if it puts it in a location that is not a standard pick location where the UL label is stripped"). Settled. |
| **Q4** | **Option (iii)** | **David Oppenheim, 2026-08-08: "not only acceptable but preferable"** — then asked *"Brent?"*. **Brent has not replied to that hand-off.** Adopted on David's endorsement plus the ticket owner's direction (Nam Park, 2026-08-08). **Not a recorded Brent sign-off.** |
| ~~Q15~~ | ~~The tier seam — (A) or (B)?~~ | — | ✅ **CLOSED 2026-08-09 — (A), with one mandatory addition.** See the box below §0. |

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
> (`verifyScannedLocation:412-456` accepts it — §3.2), so shipping 2732 first strands the destination as
> undiscoverable rather than unreachable. That is a UX regression against the ticket's intent, not data loss.

> [!done] **Q15 CLOSED 2026-08-09 — option (A), with one mandatory addition.**
>
> **(A):** this ticket ships **tier-1 only**, reading `itemdata.putawaylocation_id` directly, in the order
> `SBDEV-2731 → SBDEV-2821 → SBDEV-2732`. SBDEV-2732 step 17a later replaces that raw read with the
> four-tier `Resolution`. **(B)** would have had this ticket wait for 2732's resolver and do all four tiers
> at once.
>
> **Why (A).** M1a passed, so this ticket is implementable **now**, and it is the one that fixes the reported
> production bug. SBDEV-2732 is not ready — it is gated on items still under review **and on this ticket**
> (step 17a). (B) would put a live production defect behind an entire large plan for no functional gain.
> The divergence (B) warned about is real but **planned and bounded**: step 17a explicitly *replaces* the raw
> read rather than adding a second one.
>
> **⚠ THE MANDATORY ADDITION — the (B) argument was right about this much.** SBDEV-2732's `V2.2.13`
> **nulls the column this ticket reads**: it drops the `NOT NULL`, stops seeding, and runs
> `UPDATE itemdata SET putawaylocation_id = NULL WHERE putawaylocation_id IN (SELECT id FROM location WHERE
> name = 'PutAwayLane')`. So the column's meaning changes from *"always populated, lane by default"* to
> *"NULL means no override"*.
>
> **This ticket must handle `putawaylocation_id == NULL` from day one — before `V2.2.13` exists.** Today the
> column is `NOT NULL`, so a naive implementation will not crash and will look correct; it will break
> **later**, when 2732 lands, on a tenant nobody is watching. That is a delayed, silent failure and it is the
> worst shape available. A `NULL` must simply mean *"no configured destination — surface nothing"*.
>
> *Decided by the ticket owner's analysis, 2026-08-09. **Not a reviewer's finding** — `arch-four` was asked
> twice and did not deliver. An earlier architect pass argued for (B) on the column-semantics ground above,
> which is why that ground is now carried as a hard requirement rather than dismissed.*

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

`MobilePutAwayService.storeBoxOnLocation:497-514`, flowbin branch:

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

**But `MobilePutAwayService.verifyScannedLocation:412-456` already ACCEPTS a manual scan of `ICE PACK`:**
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

> ⚠ **The last two sentences are WRONG for `cases and pallets`, corrected 2026-08-09 during implementation —
> see the box in §3.2a.** The switch does *not* bucket that type; it drops it in `default:`. The type switch
> could **not** stay untouched, and the repository change alone would have surfaced a club destination that
> was then discarded before display. Implemented as: a new `getPutAwayCandidateLocations(itemDataId,
> configuredLocationId)` (destination as a **parameter** — the SBDEV-2732 seam) **plus** a fourth case in
> *both* switches.

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

> [!warning] **⚠ CORRECTED 2026-08-09 DURING IMPLEMENTATION — THERE ARE **TWO** SWITCHES, NOT ONE.**
>
> This section, as originally written, named only `storeBoxOnLocation:472-503`. **`calculatePutAwayList`
> has its own switch** (`MobilePutAwayService:277-295`) over the same three constants, and its `default:`
> branch **only logs** — it adds the location to neither `flowBinLocationList` nor `overstockLocationList`.
>
> So §3.2's statement *"The existing switch then buckets it correctly by type"* is true for `flowbin` and
> `overstock`, and **false for `cases and pallets`**: the destination would have been unioned into the
> candidate list by §3.2's change and then **silently dropped before the operator ever saw it.** Fixing
> only `storeBoxOnLocation` would have produced a club destination that could be scanned by hand but was
> never offered.
>
> **Both switches are fixed.** This matters beyond this ticket: **SBDEV-2732 step 17a depends on this
> surfacing for tiers 2/3**, and the club lane is 2732's named use case.
>
> **A third, subtler dependency surfaced with it.** `PutAwayLane` is itself a `cases and pallets`
> location, and on `wms2-wineco-dev` **8,803 of 8,804 SKUs** carry `putawaylocation_id = PutAwayLane`
> (`itemdata.putawaylocation_id` is `@NotNull`, so production's "no override" is *PutAwayLane*, not
> `null`). Admitting the type to the switch without also filtering the candidate query would have offered
> every operator *"put it back on the PutAwayLane."* The query's second leg carries
> `(a.useforstorage = 'true' OR l.staginglane = true)` — mirroring `verifyScannedLocation:427`'s own gate —
> which excludes it. **That predicate is load-bearing, not defensive.**

`storeBoxOnLocation:472-503` switches on `locationType.getSltname()` against exactly **three** constants —
`WmsConstants.java:736-738`: `"flowbin"`, `"overstock box"`, `"overstock pallet"`. **`"cases and pallets"` is
a FOURTH constant** (`WmsConstants.java:741`, `STORAGE_LOCATION_TYPE_STOCK_RESTRICTION`) matching none of
them, so it falls through to `default:` at `:496`, and since club locations have `staginglane = false` it
reaches `:502`:

```java
throw new BusinessException("Unsupported location type " + locationType.getSltname());
```

**Worse, the failure is late.** `verifyScannedLocation:427` gates only on `!useforstorage && !staginglane`.
Club locations sit in *Storage and Picking* with `useforstorage = true`, so **the scan is ACCEPTED and the
store then throws** — the operator scans, gets a tick, then an error.

`calculatePutAwayList:273-286` carries the same switch; its `default:` at `:284-286` **silently drops** the
location with only a debug log, so a surfaced candidate never reaches the operator either.

**Scope: 70 locations on `wsl-wineco-uat`. HMG PRD is unaffected** — all 191 of its picking-area locations are
`flowbin` (179) or `overstock box` (12), both already handled.

**The fix:** add `STORAGE_LOCATION_TYPE_STOCK_RESTRICTION` to both switches, taking the same branch as the
overstock constants — `transferUnitLoadToLocation`, **no FLA auto-creation**. That last part is load-bearing:
club lanes are shared across many SKUs, and auto-binding one to a single SKU via a `FixLocationAssignment` is
exactly the defect SBDEV-2854's plan warned about. **The FLA branch must stay reachable only from `flowbin`.**

**M1a does not cover this** — it exercises the FLA-free *flowbin* path, which works, so it goes green while
leaving this failure undetected. **§6.1 now carries `M1b`** for the `cases and pallets` branch. Neither M1a
nor M3 alone is sufficient evidence that the club use case works; M1b is the one that proves this fix.

### 3.3 The two live SKUs take different branches — both safe, and the difference is load-bearing

| SKU → destination | Location type | Putaway branch | Effect |
|---|---|---|---|
| `ICE PACK` → `ICE PACK` | **flowbin** | FLA auto-create + resident-UL merge | Binds the location to the SKU — **correct** for a dedicated location |
| `1135` → `Club08` | **cases and pallets** | ⛔ **`default:` → THROWS** | **This branch does not exist** — see the box below |

The second row matters. **⚠ CORRECTED 2026-08-09 — this previously read "`Club08` is shared across 27 SKUs",
which is wrong on two counts and was caught during implementation.** Re-measured SELECT-only on
`wms2-wineco-dev`: **`Club08` is EMPTY** — 0 unit loads, 0 SKUs of stock, 0 FLA — which is precisely why it
was chosen as the M1b fixture (§6.1) and is consistent with `:657` and `:668` of this plan, which the old
claim contradicted. The **27** belongs to **`Club01` on `wsl-wineco-uat`** (114 ULs / 27 SKUs, per SBDEV-2732
Q12) and was transposed onto the wrong lane.

**The argument is unaffected — club lanes really are multi-SKU.** On `wms2-wineco-dev`: `Club01` = **15**
distinct SKUs / 111 ULs, `Club04` = **22** / 199. Auto-binding any of them to one SKU would be a real
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
| 2 | **M1 proven** (§6.1) — manual scan of an FLA-free flowbin succeeds today | ✅ **SATISFIED 2026-08-09 by M1a on `wms2-wineco-dev`.** ⚠ **Proven on DEV, not UAT.** The prerequisite was worded "on UAT"; the ticket owner accepted the DEV run as satisfying it on 2026-08-09, on the grounds that M1a exercises a code-path branch (`storeBoxOnLocation`'s `flowbin` arm) rather than tenant data, and that M1a burns a SKU/location pair permanently under `UNIQUE(itemdata_id)` / `UNIQUE(assignedlocation_id)` — so a second run on UAT costs a fixture for no additional branch coverage. **The design is no longer void-able by this gate.** Evidence box in §6.1. |
| 3 | SBDEV-2731 PR1 merged | ✅ 2026-08-07 — api `6bc709a`, ui `4ce39a1` |
| 4 | SBDEV-2732 | **Not required by (iii)** — and **the dependency runs the other way** (Q15 → (A), §0). Routing works off `itemdata.putawaylocation_id`, which already exists; 2732 is needed only for the *configuration UI* and the tiers 2–4 defaults. **2732's step-15 gate, conversely, needs this ticket** — it diverts pick-face receipts to the lane and putaway can only offer the destination once §3.2 ships. **Ship this first.** |
| 6 | **Q15 answered — (A), tier 1 only, ships first** | ✅ 2026-08-08 (§0). Order is `2731 PR1 → this ticket → SBDEV-2732`. |
| 5 | Flyway migration | **None.** No schema change. |

### 5.2 Steps

| # | Work | Gate |
|---|---|---|
| 1 | ~~**Prove M1 on UAT**~~ — ✅ **DONE 2026-08-09** via M1a on `wms2-wineco-dev`; DEV accepted in place of UAT (§5.1 row 2). Result recorded in §6.1. | ✅ evidence recorded before any code |
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

> [!done] **✅✅ M1a PASSED — 2026-08-09, `wms2-wineco-dev`. THE DESIGN GATE IS GREEN.**
>
> Received 1 case of `13GSYC` (advice `IBOL012604`) to a container, then manually scanned flowbin `01-A01`
> at putaway. **Scan accepted, store succeeded.** Verified in the database afterwards:
>
> | Artifact | Value |
> |---|---|
> | `FixLocationAssignment` **30586183** | auto-created 02:19:20 UTC — `13GSYC` ↔ `01-A01`, bounds **36 / 60 / 84**, `active` |
> | Resident unit load **30586181** | labelid `01-A01`, **`type_id = 1` (`PickLocation`)** — the virtual UL |
> | Stockunit **30585960** | amount **1.0000**, `13GSYC`, on that unit load |
> | Unit loads on `01-A01` | **exactly one** — no second UL, no `assignedunitload_id` unique violation |
>
> **What this proves.** `01-A01` permits `unitloadtype_id = 1` **only**. A **Case** unit load placed there
> by `transferUnitLoadToLocation` is precisely SBDEV-2731's reported error — and it did not happen, because
> the flowbin branch auto-created the assignment, resolved its virtual `PickLocation` unit load, and merged
> the stock into it. **The Case UL was retired en route; only the `PickLocation` UL sits on the flowbin.**
>
> **Putaway can consume a pick-face destination. That is the mechanism the whole of option (iii)/(iv-b)
> rests on, and it is now demonstrated on running code rather than inferred from a read.**
>
> **It also confirms, empirically, the P1 exemption in SBDEV-2732 §3.4c:** no Case unit load ever sits on
> the pick face, so testing the destination against the SKU's default Case type — at config-write time or
> at receive time — asks a question about a unit load that will never be there.
>
> **Combined with M1b**, both branches are now characterised on evidence:
> - `flowbin` → **works** (this test)
> - `cases and pallets` → **throws** (M1b) ⇒ §3.2a is required for the club use case
>
> ⚠ **`13GSYC` and `01-A01` are now consumed** — `UNIQUE(itemdata_id)` and `UNIQUE(assignedlocation_id)`
> mean neither can be reused for another M1a. Fallbacks: locations `00-C07` (63807), `04-B01` (63889);
> single-position advice `IBOL012466` / SKU `615`. **`1135` remains deliberately unbound** for the post-fix
> M1b re-run.

#### M3 — POST-MERGE SMOKE TEST ON DEV (2026-08-09) — ✅ **BOTH PASSED**

> [!done] **✅ The design is now proven end-to-end on the deployed build, not just on a code read.**
> Run against `wms2-wineco-dev` after PR #135 merged (`fd90487`) and auto-deployed. **This discharges the
> M2 residual risk** — the UNION query has now executed through Hibernate.
>
> **M1a re-run — `615` → `00-C07`** (advice `IBOL012466`, adviceposition 22626888; `itemdata.putawaylocation_id`
> repointed to 63807 for the test):
>
> | Artifact | Value |
> |---|---|
> | **⭐ Candidate list** | **`00-C07` APPEARED as an offered destination BEFORE it was scanned** |
> | `FixLocationAssignment` **30586247** | `615` (itemdata 740642) ↔ `00-C07` (63807), bounds **36 / 60 / 84** |
> | Resident unit load **30586245** | labelid `00-C07`, **`PickLocation`** |
> | Stock | **12** units merged onto that UL |
> | Unit loads on `00-C07` | **exactly one** |
>
> **⭐ The candidate-list line is the ONLY one that proves the fix.** Everything below it is a *regression
> guard* — that merge behaviour already worked pre-2821 and was recorded by the original M1a the same
> morning, before any code existed. What was broken was **discoverability**: `615` had **zero** stock at
> `00-C07` (0 unit loads, confirmed pre-flight), so `getStorageLocationsForPutAwayItemData` could not have
> returned it. Its appearance is reachable only through the new UNION leg. **Note the DB evidence alone
> cannot distinguish the two** — a manual scan produces identical rows, because `verifyScannedLocation` has
> always accepted an FLA-free flowbin. Any future re-run must record the operator's observation of the list.
>
> **M1b re-run — `1135` → `Club08`, PREDICTION FLIPPED AND CONFIRMED:**
>
> | Assertion | Result |
> |---|---|
> | `FixLocationAssignment` rows on `Club08` | **0** ✅ — the club lane was NOT bound to `1135` |
> | Unit loads on `Club08` | **1** |
> | Distinct SKUs / qty | 1 / **1.0000** |
>
> **`uls_on_club08 = 1` is the disambiguator, not `fla_rows = 0`.** A throw would also have left zero FLA
> rows — the two outcomes are indistinguishable on that column alone. The unit load actually landing is what
> proves the store succeeded. Pre-2821 this threw `Unsupported location type cases and pallets` and nothing
> would have landed.
>
> **⚠ Fixtures consumed.** `615` and `00-C07` are now FLA-bound and cannot serve another M1a
> (`UNIQUE(itemdata_id)` / `UNIQUE(assignedlocation_id)`). Remaining spare flowbin: **`04-B01` (63889)**.
> `Club08` now holds 1 unit load, so an M1b re-run is against a non-empty lane.
>
> **⛔ STILL OUTSTANDING — the negative test (Step 4).** `POST /putaway/storeBoxOnLocation` naming
> `PutAwayLane` must return **`locationNotUsableForStorage` in the body of a 200** (this controller never
> returns 4xx). **It cannot be run from the mobile UI** — `store/putaway.js:113` only reaches the store step
> after `scanFlowBinLocation` succeeds, so the UI would exercise `verifyScannedLocation`'s pre-existing gate
> and false-pass identically on the old build. Direct API call only, with a **real** unit load label
> (`UL304204`), or the unit-load lookup throws `entityNotFoundForName` before reaching the gate.

#### M2 — SQL evidence for `getPutAwayCandidateLocations` (ADDED 2026-08-09, implementation)

> [!done] **The new UNION query is NOT covered by any automated test and never will be on this branch** —
> the v2 Testcontainers lane cannot boot (SBDEV-2217), and the unit tests mock the repository, so they
> prove service behaviour only. This section is the substitute evidence. **All SELECT-only, executed
> against `wms2-wineco-dev` (`dev_wh01_om1`) on 2026-08-09**, independently by two lanes.
>
> | # | Claim | How it was proven | Result |
> |---|---|---|---|
> | S1 | Row shape maps to `Location` | built the query as a temp view, introspected output columns | exactly the **19 physical `location` columns**, same names/types as the already-working single-leg query |
> | S2 | Purely additive | SKU `1135`, configured `Club08` | new query returns `06-XB13` **+ `Club08`**; old query returns `06-XB13` only |
> | S3 | NULL override is safe | `CAST(NULL AS bigint)` | leg 2 returns **0 rows**; result identical to leg 1. The explicit cast fully determines the bind type |
> | S4 | `UNION` (not `UNION ALL`) is required | SKU `1135` (itemdata 740645), configured id set to `06-XB13` — the one location it already has stock at | `union_rows = 1`, `leg1_only = 1` — no duplicate. `UNION ALL` returns **2**. *(An earlier draft of this row recorded 2/2/3 against an unnamed SKU and did not reproduce; the +1 duplicate delta is the claim, and it holds.)* |
> | S5 | Leg-2 area predicate excludes `PutAwayLane` | `PutAwayLane` is `cases and pallets`, `useforstorage=false`, `staginglane=false`, and is the `putawaylocation_id` of **8,803 of 8,804** SKUs | excluded. **Without this predicate every operator would be offered "put it back on the PutAwayLane" on every putaway** |
> | S6 | FLA clause admits own / excludes foreign | FLA `location 51630 ↔ itemdata 52350` | `itemDataId=52350` ⇒ location **returned**; `itemDataId=83901` ⇒ **0 rows** |
> | S7 | FLA clause is cheap | `EXPLAIN (ANALYZE, BUFFERS)` | `Nested Loop Anti Join`, `Index Cond: assignedlocation_id`, unique btree `uk_qakwvmdhdymic54v3dgie46wa`, **7 buffers / 0.379 ms** |
> | S8 | NOT NULL premises the SQL relies on | `information_schema` | `fix_location_assignment.itemdata_id`, `location.area_id`, `location.staginglane`, `location_area.useforstorage` — **all NOT NULL**, so `<>` has no three-valued-logic hole and the Java `!getUseforstorage() && !getStaginglane()` mirror is exact |
>
> ~~**Residual risk:** a psql round-trip is not a Hibernate round-trip. S1 makes the mapping risk near-zero
> (byte-identical output shape to a query that already maps in production), but **the first DEV smoke test
> after deploy is the first real execution of this path through Hibernate.**~~
>
> ✅ **RESIDUAL RISK DISCHARGED 2026-08-09 — see M3 above.** The query executed through Hibernate on the
> deployed DEV build and returned the configured destination: `00-C07` appeared in the putaway candidate
> list for a SKU with **zero** stock there, which is reachable only via the new UNION leg. Mapping,
> parameter binding and the second leg's predicates all work in the real runtime.
>
> **Still not run against `wsl-wineco-uat` or HMG prd** — and those matter for a reason DEV cannot cover:
> `overstock pallet` permits **Pallet only** on wineco but **Case + Pallet** on hydra, so `location_constraint`
> configuration is per-tenant. The `DefaultStrategy` collision check (two `cases and pallets` locations
> sharing `(rack, rackrow, xpos, ypos)`) is likewise verified on wineco-dev only.

#### M1a — runnable procedure, fixture verified on **`wms2-wineco-dev` (`dev_wh01_om1`)** 2026-08-09

> [!warning] **⚠ ENVIRONMENT CORRECTION — the tester is on wineco DEV, not UAT.**
> Every fixture in earlier revisions of this section was verified against **`wsl-wineco-uat`**
> (`wh01_om1_v2`) and **none of it exists on dev**, which is why two runs failed to find the advice. The
> two databases share location ids but not advice data. **All M1a/M1b fixtures below are dev.**
>
> **M1b's result is unaffected and still stands.** `Club08` on dev is id 225755, `cases and pallets`,
> *Storage and Picking*, `staginglane = false`, 0 FLA — identical to the UAT fixture — and SKU `1135` is
> configured to it. The `Unsupported location type cases and pallets` finding was produced against exactly
> the intended shape.

> [!warning] **⚠ M1a LEAVES PERMANENT STATE ON UAT — M1b did not.**
> `createFixedLocationAssignment` (`FixLocationAssignmentService:82-100`) creates a **virtual
> `PickLocation` unit load** on the location and a `FixLocationAssignment` row binding
> **location ↔ SKU**. `fix_location_assignment` is `UNIQUE(assignedlocation_id)` **and**
> `UNIQUE(itemdata_id)`, so **each SKU can only ever hold one**. Consequences:
> - **M1a is single-use per SKU/location pair.** A re-run needs a fresh pair — spares listed below.
> - The binding survives the test. On UAT that is harmless, but it is a real row: decide deliberately
>   whether to leave it or have a DBA remove the FLA and its virtual UL.

**Fixture — on `wms2-wineco-dev`. An OPEN advice already exists; no setup required.**

| | |
|---|---|
| Advice | **`IBOL012604`** — created 2026-07-30, client **Bergstrom Wines** |
| Position | `IBOL012604-000000` — the **only** position, OPEN, **1 case** |
| SKU | **`13GSYC`** — *2013 Gargantua Syrah California 750 ml*, Case type, **no FLA**, configured destination `PutAwayLane` |
| Location | **`01-A01`** — id **63809**, **flowbin**, `entity_lock = 0`, **0 unit loads, 0 FLA** |
| Location permits | `unitloadtype_id = 1` (**`PickLocation`**) only |
| FLA bounds it will create | upper bound **84** (from sysprops) |

> **Client filter:** this advice is **Bergstrom Wines**, not Elk Cove — clear or change the client filter to
> see it. It is second-newest in the list.
>
> **Why not `IBOL012607` / SKU `1135`, which is newer and at the very top?** Because `1135` is the SKU
> configured to `Club08`, and `fix_location_assignment` is `UNIQUE(itemdata_id)`. Binding it to a flowbin
> here would **consume its one allowed FLA and make a future M1b re-run impossible** — after §3.2a ships,
> M1b needs `1135 → Club08` to still be FLA-free. Leave `1135` alone.
>
> **Other single-position fallbacks:** `IBOL012466` / `615` (Elk Cove, 2 cases).

**Why this test is the design gate.** `04-A01` permits **only** `PickLocation` unit loads. A Case unit load
placed there by `transferUnitLoadToLocation` is exactly SBDEV-2731's reported error. **M1a proves that
putaway's flowbin branch sidesteps that constraint** — by auto-creating the FLA, resolving its virtual
`PickLocation` unit load, and merging stock into it with `transferStockToUnitLoad` rather than moving the
Case UL onto the location. If that does not work, option (iii)/(iv-b) has no mechanism.

**Steps** — identical to M1b except the location.

1. **Do NOT create a Purchase Order.** Go to **Inbound → Open Notices** on **wineco DEV**. Clear the client
   filter (the advice is Bergstrom Wines) and open:

   | | |
   |---|---|
   | Advice | **`IBOL012604`** — 2026-07-30, **Bergstrom Wines** |
   | Position | `IBOL012604-000000` — the only position, OPEN, **1 case** |
   | SKU | **`13GSYC`** — *2013 Gargantua Syrah California 750 ml* |

   **Receive its 1 case onto an EMPTY pallet** → the putaway list will read `Product - 1 of 1`.

   > **⚠ Corrected three times. The first two failures were mine:**
   > - *"receive against advice X"* was read as *create a PO*. **PO creation is not part of this test.**
   > - The advices offered were from another **environment entirely** — `wsl-wineco-uat`, while the tester is
   >   on **wineco DEV**. The two share location ids but not advice data.
   > - Separately, the Open Notices screen sorts by **`created` descending**, so old advices sit far down.
   >   **Type the advice number into the search box** to jump straight to one.
   >
   > **If you must substitute**, the SKU needs only two properties: **Case type** and **no existing FLA**.
   > Prefer a **single-position** advice, and always receive onto an **empty** pallet.

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
| Scan of `04-A01` | **ACCEPTED** | `verifyScannedLocation:447-453` — SKU has no FLA **and** the location has no FLA, so the mismatch branch passes |
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
| Scan of `Club08` | **ACCEPTED** | `verifyScannedLocation:427` passes (`useforstorage = true`); the FLA branch at `:430-444` is flowbin-only, so a `cases and pallets` location skips it entirely |
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

---

## 11. Implementation Status

**MERGED 2026-08-09 into `develop`.**

| | |
|---|---|
| Repo / branch | `wms2-api` @ `bugfix/SBDEV-2821-tier1-direct-placement-onto-pick-face` |
| Commit | **`cfb6d49`** — *fix(putaway): offer the SKU's configured destination and accept club lanes [SBDEV-2821]* |
| Base | `origin/develop` @ `7d9d38e` |
| PR | **https://github.com/SiteBossInc/wms2-api/pull/135** → `develop` — **MERGED 2026-08-09, merge commit `fd90487`** |
| ClickUp | moved `pr submitted` → **`on dev`** 2026-08-09 |
| Post-merge | DEV auto-deploys on push. **The first DEV smoke test is the first execution of the new UNION query through Hibernate** — the v2 Testcontainers lane cannot boot (SBDEV-2217), so this path has no automated coverage. Run M1a/M1b (§6.1) against DEV before promoting to QA. |
| Diff | 4 files, +632 / −6 (2 production, 2 test) |
| Flyway | **none** — no schema change, no deploy prerequisite |
| Worktree | `.claude/worktrees/wms2-api/SBDEV-2821` (kept for review feedback; `archive-plan` removes it) |

### What shipped

| Step (§5.2) | Status |
|---|---|
| 1 — prove M1 | ✅ M1a on `wms2-wineco-dev`, DEV accepted in place of UAT (§5.1 row 2) |
| 2 — TDD gate | ✅ 9 tests, 3 red-first, paused and approved |
| 3 — repository method | ✅ `getPutAwayCandidateLocations(itemDataId, configuredLocationId)`, destination as a **parameter** |
| 4 — wire into `calculatePutAwayList` | ✅ **plus the second switch** — see the §3.2a correction box |
| 5 — mobile UI | ⛔ **DEFERRED, pending Q13** (owner Brent). Pure UX; `scanFlowBin.vue` already renders both lists, so the destination reaches the operator without it |
| 6 — case label assert-only | ✅ asserted on **both** the location and container paths |
| 7 — full `mvn test` | ✅ 4733 run, 2 fail = pre-existing baseline; `archunit_store` reverted |

### Results

- **98 pass** in `MobilePutAwayServiceUnitTest` + `ReceivingServiceUnitTest`
- **Full suite 4733 run, 2 fail** — `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`, `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`. Both pre-existing on untouched `develop`.
- `verify-SBDEV-2821-…sh` — **`Result: 24 pass, 0 fail`**. **Negative-tested: 6 pass / 18 fail** on untouched `origin/develop` (all 18 FIX rows red; only the 6 GUARD rows green).
- Conformance lane: **PASS**, 7/7 §6.2 criteria VERIFIED. Security lane: **0 findings**.
- Code review: **0 critical, 0 high; 10 medium fixed** over three passes.

### Q15's mandatory addition — satisfied

`putawaylocation_id == NULL` is handled **from day one, before `V2.2.13` exists**: `calculatePutAwayList` passes the raw value through, and `CAST(:configuredLocationId AS bigint)` makes leg 2 return zero rows for NULL. Proven two ways — §6.1 M2 row **S3** (executed SQL) and the unit test `shouldLeaveCandidateListUnchangedWhenNoOverrideConfigured`, which asserts the null is passed through rather than defaulted.

### Landmines found during implementation that the plan did not predict

1. **There were TWO switches, not one.** §3.2a named only `storeBoxOnLocation`'s. `calculatePutAwayList:277-295` has its own with the same three-constant gap and a `default:` that only logs — so a club destination would have been surfaced and then silently dropped. **SBDEV-2732 step 17a depends on this.** See the §3.2a correction box.
2. **`PutAwayLane` is itself a `cases and pallets` location** with `useforstorage = false`, and is the `putawaylocation_id` of **8,803 of 8,804** SKUs on `wms2-wineco-dev`. Admitting the type to the switch without the query's area predicate would have offered every operator *"put it back on the PutAwayLane"* on every putaway. The predicate is load-bearing, not defensive.
3. **`storeBoxOnLocation` had no area gate of its own** — it and `verifyScannedLocation` are separate endpoints and the client is merely trusted to call verify first. The `default: throw` was the incidental backstop for these types; adding the case removed it. The gate is now hoisted (code review MEDIUM-2).
4. **A flowbin bound to a *different* SKU was offerable.** Nil exposure at tier 1, but **1,344 of 2,068 flowbins on `wms2-wineco-dev` already carry an FLA** — under SBDEV-2732's merchant/warehouse defaults a conflicted row would become the auto-selected top suggestion (flowbins sort above overstock). Closed with a `NOT EXISTS` clause (code review MEDIUM-1).

### Deliberately not done

- **§5.2 step 5 (mobile UI)** — deferred pending **Q13**. **Q14** also remains open.
- **Club lanes render under the UI's "Overstock" heading**, and a tier-1 override gets **no precedence** over a stock-derived candidate. Both are design questions **SBDEV-2732 must answer for tiers 2–4**.
- **`DefaultStrategy` collision risk** — it throws `UnsupportedOperationException` for two locations sharing `(rack, rackrow, xpos, ypos)`, and `cases and pallets` locations now reach it for the first time. **Zero collisions on `wms2-wineco-dev`; NOT verified on `wsl-wineco-uat` or prd** — run that query before this reaches production.
- **`storePalletOnLocation` has the same area-gate hole** just closed in `storeBoxOnLocation`, and deliberately proceeds with `CODE_UNASSIGN_PUT_AWAY` instead of rejecting. Pre-existing and apparently intentional; out of scope.

### Not done by this work

~~Merging the PR · setting ClickUp to `on dev`~~ — both done 2026-08-09 by whoever merged.

✅ **DEV smoke test DONE 2026-08-09 — M1a and M1b BOTH PASSED** (§6.1 **M3**). The UNION query has executed
through Hibernate on the deployed build; **M2's residual risk is discharged.** The behaviour that was
actually broken — the configured destination being *offered* at putaway — is confirmed by the operator
observing `00-C07` in the candidate list before scanning it.

**Still outstanding:** the **Step-4 negative test** (`PutAwayLane` → `storeBoxOnLocation`; direct API only —
it **cannot** be run from the mobile UI, which would false-pass on the pre-existing `verifyScannedLocation`
gate, see §6.1 M3) · archiving this plan (`archive-plan`, which also removes the worktree at
`.claude/worktrees/wms2-api/SBDEV-2821`) · promotion to QA/prod · the deferred items listed above ·
**UAT/prd verification of the two per-tenant assumptions** (`location_constraint` config and the
`DefaultStrategy` collision check, both checked on wineco-dev only).
