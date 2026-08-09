---
title: "SBDEV-2821 — Receive ICE PACK into the ICE PACK pick face: route at putaway, not at receipt"
ticket: "SBDEV-2821"
ticket_url: "https://app.clickup.com/t/868km8j9z"
type: "bugfix"
priority: "high"
status: "APPROVED 2026-08-08 for OPTION (iii) — route at putaway. Q4 resolved; Q1 resolved (label prints unconditionally = existing behaviour, no change). Remaining gate: M1 must be proven on UAT before code (§5.1 row 2). Decision provenance in §0."
project: [wms2]
version: "v2"
requester: "Brent Campbell (via SBDEV-2731)"
created: "2026-08-07"
updated: "2026-08-07"
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
  - {ticket: SBDEV-2732, sha: UNMERGED}   # owns PutawayDestinationValidator P2.5 / P2.7(c), which
                                          # option (ii) would relax. Option (iii) does NOT need it.
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
- **Relaxing P2.5 does not unblock `ICE PACK`** — P2.5 is the FLA check and there is no FLA to match. What
  blocks the *configuration* is SBDEV-2732's **P2.7(c) clause 1**, the pick-face predicate
  (`location_area.useforpicking`).
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

### 3.3 The two live SKUs take different branches — both safe, and the difference is load-bearing

| SKU → destination | Location type | Putaway branch | Effect |
|---|---|---|---|
| `ICE PACK` → `ICE PACK` | **flowbin** | FLA auto-create + resident-UL merge | Binds the location to the SKU — **correct** for a dedicated location |
| `1135` → `Club08` | **cases and pallets** | overstock → `transferUnitLoadToLocation` | **No FLA created** |

The second row matters. `Club08` is shared across **27 SKUs**. Auto-binding it to one SKU would be a real
defect — SBDEV-2854's plan flagged exactly this (*"would silently re-bind shared Club01 to one SKU at commit
time"*). **The location-type difference prevents it.** Any change here must preserve that: FLA auto-creation
must remain reachable only from the `flowbin` branch.

### 3.4 What this design deliberately does NOT do

- **No new receiving branch.** `ReceivingService` is untouched.
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

**No tenant's receiving behaviour changes.** This is why (iii) needs no decision about container precedence,
whereas (ii) does.

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
| 4 | SBDEV-2732 | **Not required by (iii).** Needed only for the *configuration UI*; the routing works off `itemdata.putawaylocation_id`, which already exists |
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
| **M1** | Receive a Case of an FLA-free-flowbin SKU to a container, then at putaway **manually scan** the flowbin | Placement succeeds; FLA auto-created; stock merged into the resident UL. **If this fails, stop — the design is wrong.** |
| M2 | Repeat with the configured location surfaced in the suggestion list | Appears without a manual scan |
| M3 | `1135` → `Club08` (cases and pallets) | Overstock branch; **no FLA created**; `Club08` stays multi-SKU |
| M4 | SKU with no override | Suggestion list unchanged from today |
| M5 | The originating receipt: 1,000 units of `ICE PACK` on HMG | Lands in `ICE PACK`; receipt and inventory history record it |

### 6.2 Automated

- Configured location appears in candidates when the SKU has **no stock anywhere** (the `ICE PACK` case)
- Configured location is **not duplicated** when the SKU already has stock there
- No override ⇒ candidate list byte-identical to today (**regression guard**)
- Flowbin destination ⇒ FLA auto-created, stock merged into resident UL, **no second UL on the location**
- **`cases and pallets` destination ⇒ NO FLA created** (guards §3.3 — the `Club08` defect)
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
| **Q15** | **The tier seam.** SBDEV-2732 answered Q12 as **(iv-b)**: configure at any tier; place everywhere **except** pick faces, which are diverted to the lane at receipt and routed by putaway — so putaway must consume **pick-face destinations for all four tiers**, while this plan is written for **tier 1 only** (it reads `itemdata.putawaylocation_id`). **(A)** ship tier 1 here independently and let 2732 extend it, or **(B)** wait for 2732's resolver and do all four at once? **Recommend (A)** — it delivers the reported ICE PACK fix without waiting on 2732, and this plan is otherwise gated only on M1. | owner + 2732 | scope of §3.2, and whether `depends_on: SBDEV-2732` becomes hard |
| **M1** | Not a question but the remaining **gate**: does a manual putaway scan of an FLA-free flowbin succeed today? | implementer, on UAT | **Everything.** If it fails, the design is void and Q4 reopens. |
| Q13 | If (iii): should the configured location be **pre-selected** at putaway, or merely offered? | Brent | §5.2 step 5 — UX only |
| Q14 | If (iii): should receiving *display* the eventual destination, even though it routes to a container first? | David | Interacts with SBDEV-2732 §3.11.1 |
