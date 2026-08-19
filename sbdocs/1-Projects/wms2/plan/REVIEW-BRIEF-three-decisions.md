# Review brief — three design decisions on the WMS V2 putaway hierarchy

**Self-contained.** Everything needed is here or cited with `file:line`. You should not need to re-derive
the measurements — they are recorded below and were taken SELECT-only.

**Your scope is three decisions.** Do not review the plans as a whole; they have had four prior passes and a
consolidation. **Do not review the verify scripts** — those were audited empirically on 2026-08-09 against a
synthetic conformant implementation and all 17 relevant checks were proven to pass a correct implementation
and fail the unimplemented tree.

**Be adversarial.** All three decisions were made by one person who has been wrong repeatedly on this
material in the last week: claimed `cases and pallets` took an overstock branch (it throws), shipped a verify
check that would have failed a correct implementation and passed the reported bug, missed a check in their
own sweep, wrote "M1 must be extended" and did not extend it, and gave test fixtures from the wrong database
three times. Assume similar errors here.

---

## Background in six lines

`SBDEV-2731` reported: a SKU configured to receive into a pick face fails with *"Unit load type ID 4 not
allowed on location Ice Pack with location type ID 2"*. Root cause: receiving uses the whole-unit-load
transfer primitive against a flowbin, whose `location_constraint` permits only `PickLocation` unit loads.

The chosen design (**Q12 → option iv-b**): **configure anywhere, place everywhere EXCEPT pick faces.** A
pick-face destination is diverted at receipt to the standard putaway lane, and **putaway** routes it —
because `MobilePutAwayService.storeBoxOnLocation:497-514` already auto-creates a `FixLocationAssignment`,
resolves its virtual `PickLocation` unit load, and merges stock into it.

**Proven on running code, 2026-08-09, wineco DEV:**
- **M1a PASSED** — received a Case of `13GSYC` to a container, manually scanned FLA-free flowbin `01-A01` at
  putaway. FLA `30586183` auto-created (bounds 36/60/84), virtual `PickLocation` unit load `30586181`
  created, stockunit `30585960` amount 1.0 merged into it, **exactly one unit load on the location**.
- **M1b THREW** — scanning club location `Club08` (`cases and pallets`) was **accepted**, and the store then
  threw `Unsupported location type cases and pallets`. `storeBoxOnLocation` switches on only three constants
  (`WmsConstants.java:736-738`); `cases and pallets` is a fourth (`:741`).

---

## DECISION 1 — P2.7 rule (e): tiers 2/3 may not target a `flowbin`-TYPE location; tier 1 exempt

**Plan:** `SBDEV-2732-configurable-default-putaway-location-hierarchy.md` §3.4c, P2.7 rule (e).

**Rationale.** (iv-b) widened configuration at every scope, which re-opened a hazard that P2.5's absolute
reject had been closing *as a side effect*. Putaway auto-creates a `FixLocationAssignment` binding a flowbin
to **whichever SKU is put away first**. The table carries `UNIQUE(assignedlocation_id)` **and**
`UNIQUE(itemdata_id)` (`V2.2.00__base_v2_schema.sql:3760-3763`, `:3712-3715`), so every later SKU under a
merchant or warehouse default then fails — at `verifyScannedLocation:447-453` or
`UnitloadBusinessService:180-183`. A merchant default applies to every SKU that merchant receives, so the
blast radius is the whole scope, not one SKU. **M1a confirmed the auto-create behaviour is real.**

**Predicate is `location_type.sltname == 'flowbin'`, deliberately NOT `location_area.useforpicking`** —
club lanes are `cases and pallets` in a `useforpicking` area, so keying on the area flag would re-ban them
and silently undo Q12.

**Measured (SELECT-only, 2026-08-08/09):**

| Tenant | FLA-free flowbins (the hazard) | `cases and pallets` in picking areas (the clubs) |
|---|---|---|
| `wms2-hydra` (HMG PRD) | **46** | 0 — none exist |
| `wsl-wineco-uat` | **656** | 70 |

**Questions for you.**
1. Is the hazard real as described, and is rule (e) the right shape to close it?
2. **Does it MISS a case?** Specifically: a tier-2/3 default on an **FLA-BEARING** flowbin; a tier-2/3
   default on a `cases and pallets` location; a tier-2/3 default on an `overstock box` pick face.
3. Is the **tier-1 exemption** safe? The argument is that a SKU binding its own pick face is the intent,
   mirroring the runtime rule at `UnitloadBusinessService.java:178-184`, which rejects only on SKU *mismatch*.
4. Is `sltname` load-bearing in the way claimed, or is there a better predicate?

---

## DECISION 2 — P1 is SKIPPED for pick-face destinations, at config-write AND receive time

**Plan:** `SBDEV-2732…md` §3.4c, the box immediately above "3.4c Predicate P2".

**Rationale.** P1 is `isUnitloadTypePermitted(destinationType, unitloadType)`. For a pick face it asks
*"can a unit load of the SKU's default type sit here?"* and answers **no**. Measured on HMG PRD: flowbin
(`type_id = 2`) has **exactly one** `location_constraint` row permitting `unitloadtype_id = 1`
(`PickLocation`); `ICE PACK`'s `defultype_id` is **4** (`Case`). **So P1 rejects the ICE PACK configuration
even after P2.5 and P2.7(c) are dropped** — relaxing those two does not make the config writable.

Under (iv-b) no Case unit load ever sits on the pick face: putaway merges stock into the resident
`PickLocation` unit load and retires the Case UL en route. **M1a demonstrated exactly this** — one unit
load on the location afterwards, of type `PickLocation`.

At **receive** time the gate must run **before** `requireCompatible` and retarget to the lane, so P1 is
evaluated against `PutAwayLane` (which permits Case and Pallet) rather than the pick face.

`Club08` passes P1 only **by accident** — `cases and pallets` has **zero** `location_constraint` rows, so P1
fails *open*.

**Questions for you.**
1. Is skipping P1 entirely for pick-face destinations correct, or does it discard a check that still matters?
2. If something SHOULD still be validated for a pick-face destination, what?
3. Is "skip at both enforcement points" right, or should the two differ?
4. Does the fail-open behaviour on constraint-less location types create a hazard of its own?

---

## DECISION 3 — SBDEV-2643 D1 reverted: the SKU picker offers pick faces again

> [!note] **STATUS UPDATE 2026-08-12 — Q1 and Q2 have been answered BY IMPLEMENTATION; Q3 and Q4 have
> not.** This brief was never formally returned. In the meantime SBDEV-2732 shipped (iv-b) end to end
> (both phases merged 2026-08-11, its verify script 285/0) and **SBDEV-2821 merged 2026-08-09** (PR #135,
> `fd90487`), so:
>
> - **Q1 — "is reverting D1 correct under (iv-b)?"** Ratified in code. `GET
>   /putawayConfig/eligibleLocations?scope=SKU` returns the pick faces as `eligible: true`, and the
>   route-at-putaway path SBDEV-2821 shipped is what makes them placeable. **2,554 eligible rows at SKU
>   scope on `wms2-wineco-dev` against 516 at merchant/warehouse scope — the gap IS the pick faces.**
> - **Q2 — "should the picker exclude anything now?"** Answered by 2732's rule (f) plus the 7-value
>   `BlockingReason`: flowbins bound to a *different* SKU are excluded (`BOUND_TO_ANOTHER_SKU`), and
>   `FIX_ASSIGNED` / `LOCKED` / `LANE` / `AREA_NOT_USABLE` / `FLOWBIN_SCOPE` / `TYPE_INCOMPATIBLE` name
>   the rest. Server-side, one source of truth.
> - **Q3 — the operator message — ✅ ANSWERED 2026-08-12: MIRROR 2732's ALREADY-APPROVED WORDING.**
>   No new copy is written. 2732 step 19a's variant-A sentence is in `messages.properties`:
>   `putawayDestinationDivertedToLane=Received to %1$s. Putaway will move it to %2$s — the stock is not
>   on %2$s until then.` SBDEV-2643 §3.8.2a now specifies the **configure-time mirror** of that
>   sentence, so an operator meets one voice at config time and at receipt. ⚠ It is a mirror, not a
>   reuse: the key is emitted only when a receipt was actually diverted, there is no receipt at config
>   time to bind its arguments, and `wms2-web-ui` has no `vue-i18n`. **The two strings must move
>   together** if a later product read revises variant A.
> - **Q4 — ✅ ANSWERED 2026-08-12: option (ii) — SBDEV-2643 ships the server-side search parameter.**
>   This was **not** merely a UX question. This brief's own Q2 close assigned the remedy to 2643 *"as a
>   parameter on `eligibleLocations`"* and **it was never built** — the endpoint takes only `scope`,
>   `subjectId`, `Pageable`. Measured 2026-08-12: the UI store accumulates every page at `size=200`, so
>   **2,564 candidate locations on `wms2-wineco-dev` = 13 sequential round-trips before the operator can
>   type** (`wsl-wineco-uat` 2,703/14; both hydra copies 602/4). It is now SBDEV-2643 **Phase A4**
>   (§3.5a, +0.5 d), with an in-query case-insensitive contains and an **empty-search identity
>   contract** — tiers 2 and 3 call the same endpoint with no `name`, so a predicate bug would silently
>   shrink the WAREHOUSE and MERCHANT pickers with no error shown.
>   ⚠ **Q4's original framing was also based on the wrong number.** It asked about *"the unfiltered
>   229-location picker on HMG production"*; 229 is a **PRD** figure, and the reachable HMG copies
>   measure **602** candidates while the WineCo tenants measure **~2,600**. The volume problem is
>   WineCo-shaped, not HMG-shaped.
>
> **Consequence for SBDEV-2643: DECISION 3 IS NOW FULLY ANSWERED — all four questions.** D1 is settled
> and is no longer a schedule risk. The banner wording is derived from copy already accepted, so §5.7's
> product-review item is a courtesy rather than a blocker. Q4 added **Phase A4** to the plan.
> **Decisions 1 and 2 of this brief remain unreturned** — they block nothing in 2643.

**Plan:** `SBDEV-2643-sku-default-putaway-location-ui.md`, revision-3 banner near the top.

**History.** r1 offered pick faces behind an advisory. **r2 (2026-08-07) reversed it** and offered only
"genuinely eligible" locations, because a SKU-scope pick-face write was then an unconditional 422 that
SBDEV-2732 shipped a test to enforce. Sound at the time. **r3 (2026-08-08) reverses it back**, because
Q12 → (iv-b) deleted that reject: a SKU-scope pick-face write is now legal.

**Re-measured 2026-08-09 (SELECT-only).** r2's figures were 603 goods-in-or-storage → **92 eligible**,
**511 excluded by P2.7(c)**. Those sum exactly, so P2.7(c) was doing all the exclusion.

| Tenant | goods-in-or-storage | of which in a picking area | eligible at SKU scope under (iv-b) |
|---|---|---|---|
| `wms2-wineco-dev` | — | — | **2,555** of 2,739 total |
| `wsl-wineco-uat` | 2,704 | 2,219 | **2,694** |
| `wms2-hydra` (HMG PRD) | 229 | 191 | **229** — exclusion set now empty |

**r2's population of 603 matches none of these three tenants**, so its numbers came from somewhere else
again and are treated as unusable rather than stale.

**Questions for you.**
1. Is reverting D1 correct under (iv-b)?
2. Should the picker exclude **anything** now? Tier 1 is exempt from rule (e), so flowbins are offerable.
3. The advisory must say a pick-face destination is **routed via putaway**, not placed directly. Is that the
   right operator message, and is an advisory sufficient rather than a warning or a confirm dialog?
4. **On HMG production the exclusion set is empty — every candidate qualifies.** Is that acceptable, or does
   an unfiltered picker of 229 locations need a different affordance?

---

## What a good report looks like

- A **verdict per decision**: sound / sound-with-changes / wrong.
- Any **case the decision misses**, with `file:line` or a query.
- Any **interaction between the three** — decision 1 and 2 both key on "is this a pick face" but use
  different predicates (`sltname` vs `useforpicking OR sltname`). Is that inconsistency deliberate-and-correct,
  or a latent bug?
- State plainly what you did **not** examine.

**Do not** re-verify the measurements unless you doubt one — say which and why.

## Environments

Read-only MCP SQL is available. `wms2-wineco-dev` (`dev_wh01_om1`) is where the tests were run;
`wsl-wineco-uat` (`wh01_om1_v2`) and `wms2-hydra` (HMG production) are also reachable. **dev and uat share
location ids but NOT advice data** — do not conflate them. Repos: `v2/wms2-api` and `v2/wms2-web-ui`, both on
`develop` at the SBDEV-2731 merge (`6bc709a` / `4ce39a1`).
