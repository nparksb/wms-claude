---
title: "WMSv2: the Default Putaway Location picker hides tier 1's only usable destinations behind the storage toggle"
ticket: "SBDEV-2947"
ticket_url: "https://app.clickup.com/t/868kr048e"
type: "bugfix"
priority: "normal"
status: "MERGED to develop 2026-08-15 — wms2-web-ui #61, merge commit 3098e46. ClickUp `on dev`.
  ARCHIVE-GATED on manual QA: the fix is a deliberate NO-OP on 3 of 4 tenants and nothing automated
  proves it inert there — a non-wineco (hydra/shipitez) pass is the only such evidence.
  Merged with no review lane ever run against the final commit 879693a (see §12)."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-13
updated: 2026-08-15
db_verified: true
related:
  - SBDEV-2643-sku-default-putaway-location-ui.md
  - SBDEV-2732-configurable-default-putaway-location-hierarchy.md
  - SBDEV-2821-tier1-direct-placement-onto-pick-face.md
tags:
  - plan
  - wms2
  - putaway
  - web-ui
---

# WMSv2: the Default Putaway Location picker hides tier 1's only usable destinations behind the storage toggle

**Ticket:** [SBDEV-2947](https://app.clickup.com/t/868kr048e)
**Project:** wms2 (`v2/wms2-web-ui` only) | **Version:** v2 | **Type:** bugfix
**Priority:** normal
**Status:** **MERGED to `develop` 2026-08-15** — [wms2-web-ui #61](https://github.com/SiteBossInc/wms2-web-ui/pull/61), merge commit `3098e46`. ClickUp `on dev`; archive-gated on manual QA (incl. a non-wineco tenant)
**Date:** 2026-08-13

> **Process note — `ralplan` was skipped, then a `critic` review was run on request, and it found a
> High.** The plan was first drafted without the mandated Planner→Architect→Critic loop, on the
> skill's small-change exception, with the four design decisions put to the requester directly. A
> critic pass run afterwards **falsified the plan's central claim** (§2's "structural") by measuring
> three more tenants, which in turn invalidated the stated rationale in §3.5 and §10 Q1 and made the
> original Fix B wrong on two live tenants. It also caught a third SKU-only predicate missing from
> §2's table, three stale manual-test rows, five wrong Java line references and a set of invented
> caption figures. **The fix itself did not change; the reasoning behind it and one design detail
> did.** Revision r2 folds all of it in. The exception was applied to a change that did not qualify —
> recorded here rather than quietly corrected, because the numbers that made this plan look
> well-evidenced (a mutation-tested verify script, a satisfiable gate) were all downstream of a
> premise none of them could test.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by `git grep` **against `origin/develop`**, not the local checkout — the local
`v2/wms2-web-ui` was 19 commits behind when this plan was written, and PRs #54/#55/#56 (the SKU dialog
and the caption this plan edits) exist only on the remote. Two greps: `showAdvanced` and
`Show storage locations`, plus every consumer of `LocationPicker`.

| # | File:line (`origin/develop`) | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `components/common/LocationPicker.vue:89` | `showAdvanced: false` — the hard-coded initial state of the storage-tier gate | **yes — this is the defect** | **yes** (Fix A) |
| 2 | `components/common/LocationPicker.vue:114-123` | `offeredItems()` — the tier filter that reads `showAdvanced` | yes — consumes #1, no edit needed | **yes**, as the behaviour Fix A moves; no code change |
| 3 | `components/common/LocationPicker.vue:26-38` | the lock-contention `v-alert`, `v-if="showAdvanced"`; its closing sentence advises preferring a goods-in location | yes — becomes permanently visible at tier 1 and names an empty set | **yes** (Fix B) |
| 4 | `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue:28-34` | the `<location-picker>` call site — the only one in the repo | yes — must supply the new prop | **yes** (Fix C) |
| 5 | `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue:57-64` | the PR #56 caption's trailing sentence, *"Enable "Show storage locations" below…"* | yes — becomes a false instruction at SKU scope | **yes** (Fix D) |
| 6 | `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue:44-53` | the comment block explaining why the split exists | yes — documents #5 | **yes**, comment amend only (Fix D) |
| 7 | `components/masterData/material/skuData/editSkuPutawayDialog.vue:97-105` | the SKU dialog — passes `scope="SKU"` and nothing else picker-related | yes, it is *the* affected screen | **no** — it already delegates everything; adding anything here is the cloning §3.8 forbids |
| 7a | `components/masterData/material/skuData/editSkuPutawayDialog.vue:64-67` | the dialog's OWN count sentence — *"{{ counts.eligibleCount }} of this warehouse's {{ counts.totalCount }} locations are currently eligible for this SKU"*, ~200px above the caption Fix D edits | no — pre-existing | **no**, but recorded: at SKU scope the operator reads "1206 of 2738" **twice** in different words on one screen. Not caused by this plan and not fixed by it; row 7's "delegates everything" was too strong. Worth a follow-up if the duplication reads badly in M1 |
| 8 | `components/admin/parametersAndConfiguration/{add,edit}ParamAndConfig.vue`, `operationOptions/operationOptions.vue`, `shippers/editShipper.vue` | the four tier-2/tier-3 hosts | **no** — their default tier is populated (12 eligible, §1.2) | **no** — unchanged by construction; §6 pins that they stay unchanged |
| 9 | `test/components/common/locationPicker.spec.js` (T5, T9, T16) | asserts the picker starts closed | partially — must keep asserting it for tiers 2/3, plus new tier-1 rows | **yes** (§6) |
| 10 | `test/components/admin/defaultPutawayLocationField.spec.js:472-534` | PR #56's three caption tests, all mounted at `scope: 'WAREHOUSE'` | no — unaffected; new SKU-scope siblings needed | **yes**, additive (§6) |
| 11 | `test/components/masterData/material/skuData/editSkuPutawayDialog.spec.js` | the SKU dialog's specs, all `shallowMount` (picker stubbed) | no | **yes**, one new mounted row (§6) |
| 12 | `v2/wms2-mobile-ui`, `v1/wms-web-ui` | — | **no** — `git grep` on each repo's `origin/develop` finds no `LocationPicker`, no `Show storage locations`, no `eligibleLocations` | **no** |
| 13 | `v2/wms2-api` | `PutawayDestinationQueryService`, `PutawayDestinationRules`, `LocationConstraintService` | **no** — the server's verdicts are correct; only which of them the UI *offers first* is wrong | **no** — see §3.5 for why the tempting server-side fix is rejected |

Rows 1, 3, 4, 5, 6 are the in-scope production sites and each maps to a fix in §3 and to at least one
POSITIVE row in `verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh`.

---

## 1. Problem Statement

### 1.1 Symptom

Open a SKU on the Master Data → SKU screen and press the Default Putaway Location pencil. The dialog
renders, the caption reads *"1206 of 2738 locations can be used as a putaway destination"*, and the
dropdown directly beneath it is **empty**. Every SKU behaves this way. The ice-pack scenario
SBDEV-2643 was raised to configure is not reachable without first finding and enabling a switch whose
warning describes a different risk.

Reported after three separate SKUs showed an empty dropdown during SBDEV-2643's manual test plan on
2026-08-13; the first reading was that the screen was broken.

The dropdown is empty because `LocationPicker` offers only `tier === 'DEFAULT'` rows until
*"Show storage locations"* is switched on, and **at SKU scope, on this tenant, zero locations carry
that tier and are eligible.**

### 1.2 DB verification (analysis-protocol §8 — `db_verified: true`)

Run 2026-08-13 against `mcp__wms2-wineco-dev` — confirmed as `dev_wh01_om1` by
`SELECT current_database()`, Flyway head `2.2.16` (per the recorded landmine, an env file is not
proof of which DB you are on). 2,739 locations, 8,804 SKUs.

The queries below **reproduce `PutawayDestinationRules.CHAIN` in SQL**, rule for rule, rather than
approximating it. Three independent cross-checks say the reproduction is faithful — each of these
numbers is asserted by a comment in the production source, written by a different pass:

| Cross-check | Source's own figure | This SQL |
|---|---|---|
| candidates (`name <> 'PutAwayLane'`) | 2,738 — `PutawayDestinationValidator.java:88` | 2,738 ✅ |
| ineligible at SKU scope | 1,532 — `PutawayDestinationValidator.java:88` | 2,738 − 1,206 = 1,532 ✅ |
| FLA-bound flowbins | 1,345 of 2,068 — `repo/jpa/LocationRepository.java:313` | 1,345 / 2,068 ✅ |
| rows at merchant/warehouse scope | 516 — `PutawayDestinationQueryService.java:247` | 516 ✅ |

**(a) There is exactly one goods-in area, holding 12 candidates:**

```sql
SELECT la.name, la.useforgoodsin, la.useforstorage,
       count(l.id) FILTER (WHERE l.name <> 'PutAwayLane') AS candidates
FROM location_area la LEFT JOIN location l ON l.area_id = la.id
GROUP BY 1,2,3 ORDER BY la.useforgoodsin DESC;
-- Inbound  | t | f | 12       <-- the entire DEFAULT tier
-- Default  | f | f | 16
-- Storage and Replenish        | f | t |  415
-- Storage and Picking          | f | t | 2137
-- users | f | f | 118 · Outbound | f | f | 40 · (2 empty areas)
```

**(b) At SKU scope, for a Case SKU with no fix-location assignment — 0 of those 12 survive:**

```
tier      verdict                  count
ADVANCED  BOUND_TO_ANOTHER_SKU     1345
ADVANCED  (eligible)               1206   <-- every usable destination
ADVANCED  AREA_NOT_USABLE           122
ADVANCED  LANE_staging_crossdock     20
ADVANCED  LANE_automation            19
ADVANCED  LANE_gate                   7
ADVANCED  LANE_transfer               6
ADVANCED  TYPE_INCOMPATIBLE           1
DEFAULT   LANE_staging_crossdock     10   <-- HubAndSpoke-01..-10
DEFAULT   TYPE_INCOMPATIBLE           2   <-- EmptyPallets, InboundWorkstation
```

`0` eligible `DEFAULT` rows, `1206` eligible `ADVANCED` rows — which is precisely the caption PR #56
ships (*"0 in goods-in areas (none), 1206 storage"*). The empty dropdown is the picker faithfully
rendering a correct, empty tier.

**This holds for all 8,804 SKUs, not just the sampled one.** All 8,804 have `defultype_id = 4` (Case)
— `SELECT count(DISTINCT defultype_id) FROM itemdata` returns 1 — so the two `TYPE_INCOMPATIBLE`
rejections apply identically to every SKU, and the ten `LANE_staging_crossdock` rejections do not
consult the SKU at all. A fix-location assignment can only add `FIX_ASSIGNED` rejections, never
remove one. The DEFAULT tier is empty for every SKU on this tenant, with no exceptions.

**(c) The same 12 locations at WAREHOUSE / MERCHANT scope — all 12 eligible:**

```
tier      verdict         count
ADVANCED  FLOWBIN_SCOPE   2068
ADVANCED  (eligible)       504
ADVANCED  AREA_NOT_USABLE  122
ADVANCED  LANE_automation   19 · LANE_gate 7 · LANE_transfer 6
DEFAULT   (eligible)        12   <-- all of them
```

**(d) The one real tier-1 configuration on the tenant points at a storage location:**

```sql
SELECT count(*) FILTER (WHERE putawaylocation_id IS NOT NULL) FROM itemdata;                -- 2
SELECT l.name, i.modified::date FROM itemdata i JOIN location l ON l.id = i.putawaylocation_id;
--   Club08  2022-06-23   <- the long-standing hand-set override
--   ICEPACK 2026-08-13   <- ⚠ SAVED DURING MANUAL TESTING, AFTER this plan's first queries ran,
--                           by an operator flipping the storage switch by hand. Re-measured at
--                           critic review. An earlier revision of this section said "1" and named
--                           only Club08, which then contradicted §2 Bug 2's "both real
--                           configurations on this tenant". Live data moves under a plan.
-- Club08:  area "Storage and Picking" (useforstorage), type "cases and pallets"  -> ADVANCED
-- ICEPACK: area "Storage and Picking" (useforstorage), type "flowbin", 1 FLA row -> ADVANCED
```

**(e) The UAT fleet — all four active tenant databases, surveyed 2026-08-13**

Tenant roster read from the UAT landlord (`tenant` ⋈ `tenant_db_configuration`, `active = true`).
All clients run the same wms2 build, so the question "who does this actually affect?" is a data
question, and it had not been asked until now.

| Database | tenant / warehouse | SKUs | goods-in candidates | **eligible at SKU scope** |
|---|---|---|---|---|
| `wh01_om1_v2` | **wineco / wsl** | 10,480 | 12 | **0** ❌ |
| `wh01_hydra_v2` | hydra / nywh | 2,715 | 2 | **2** ✅ |
| `wh01_shipitez_v2` | shipitez / c1wh | 3,277 | 2 | **2** ✅ |
| `wh02_shipitez_v2` | shipitez / nywh | 1,334 | 2 | **2** ✅ |

**Wineco is the only affected tenant — 1 of 4 in UAT, and 1 of 3 distinct tenants in dev (§2's
correction). The defect is not fleet-wide.**

The discriminator is identical on all six databases measured and comes down to one row:

| | `overstock pallet` permits | HubAndSpoke crossdock lanes in goods-in |
|---|---|---|
| wineco (dev + uat) | `{5}` — Pallet only | 10 |
| hydra, shipitez ×2 | `{4, 5}` — Case **and** Pallet | 0 |

Every tenant's SKUs are unit-load type 4 (Case), so wineco's two goods-in stations fail P2.6 while
everyone else's pass. **A single missing `location_constraint` row is the whole defect** — see §8 for
the separate ticket this warrants.

⚠ **This measurement changed the design.** It is why Fix A is data-driven rather than scope-driven
(§3.1): a scope-driven default would have altered behaviour on the three tenants that have nothing
wrong with them.

### 1.3 Two corrections to the ticket's own figures

Recorded because the ticket says *"Every figure above is a live query, not an estimate"*, and two of
them do not survive re-measurement. Neither changes the verdict; both change the reasoning.

**(i) "locations a Case SKU can use — 2,068, all `ADVANCED`" is wrong. The figure is 1,206.**
2,068 is the count of *flowbins*, of which 1,345 are FLA-bound to another SKU and therefore
ineligible. Both numbers appear in `repo/jpa/LocationRepository.java:313`, which is the likely source of the
transposition. 1,206 is also the number PR #56's own caption prints, so the ticket contradicts the
screen it is describing.

**(ii) "HubAndSpoke-01…-10 have no `location_constraint` rows, so they accept nothing" inverts the
actual rule.** `LocationConstraintService.isUnitloadTypePermitted` **fails open**:

```java
// LocationConstraintService.java:61-63
// THE FAIL-OPEN. Keep the return adjacent to the guard — see the class comment.
if (locationConstraintList == null || locationConstraintList.isEmpty()) {
    return true;
}
```

A location type with no constraint rows permits **every** unit-load type. Those ten locations are
rejected for a different reason entirely — they are `crossdockinglane = true`, and
`PutawayDestinationRules.stagingOrCrossdockAtSku` rejects staging/crossdock lanes **at SKU scope
only**. Confirmed per row:

```sql
SELECT l.name, lt.sltname, l.crossdockinglane,
       (SELECT count(*) FROM location_constraint lc WHERE lc.storagelocationtype_id = l.type_id) AS rows
FROM location l JOIN location_type lt ON lt.id = l.type_id
WHERE l.area_id = 51554 AND l.name <> 'PutAwayLane';
-- HubAndSpoke-01..-10 | System           | t | 0   -> LANE (not the constraint check; that passes)
-- EmptyPallets        | overstock pallet | f | 1   -> TYPE_INCOMPATIBLE (1 row, and it is not Case)
-- InboundWorkstation  | overstock pallet | f | 1   -> TYPE_INCOMPATIBLE
```

**Consequence for the ticket's "Not in scope" note.** It proposes giving HubAndSpoke sensible
`location_constraint` rows as a separate configuration gap. That would change nothing: those
locations already accept every unit-load type, and adding rows could only *narrow* them. If someone
wants them offerable at tier 1, the lever is `crossdockinglane`, which governs real crossdock
routing. **Recommend closing that note rather than raising a ticket for it** (§8).

---

## 2. Root Cause Analysis

### Bug 1 — the tier gate's default is a property of the *location*, but its correctness is a property of the *scope*

`LocationPicker` splits its rows into two tiers and opens only the first:

```js
// components/common/LocationPicker.vue:87-91
data() {
  return {
    showAdvanced: false,          // <-- the defect: one constant for three scopes
  }
},

// :114-123
offeredItems() {
  return this.items.filter((row) =>
    row && row.eligible === true &&
    (row.locationId === this.value ||
     row.tier === 'DEFAULT' ||
     (this.showAdvanced && row.tier === 'ADVANCED')))
},
```

`tier` is assigned server-side from one column and nothing else:

```java
// PutawayDestinationQueryService.java:331
area != null && Boolean.TRUE.equals(area.getUseforgoodsin()) ? "DEFAULT" : "ADVANCED",
```

So the tier partition is **identical for all three scopes** — it is a fact about the location. But
`eligible` is **not**: `PutawayDestinationRules.CHAIN` runs a different set of predicates per scope.
Two of the nine rules fire only at SKU scope, and both target exactly what a goods-in area contains:

| Rule | Applies at | What it rejects |
|---|---|---|
| `stagingOrCrossdockAtSku` (P2.3), `PutawayDestinationRules.java:222` | **SKU only** — explicit `scope == PutawayScope.SKU` guard | staging and crossdock lanes — i.e. receiving lanes, which is what a goods-in area is *for* |
| `fixedAssignmentCoherence` (P2.7(f)), `:227` | **SKU only** — literal `if (scope != PutawayScope.SKU \|\| subjectId == null) return null;` | direction 2 rejects **every** location that is not the SKU's own FLA pick face |
| `unitloadTypeCompatible` (P2.6) | **SKU only** in practice — `defaultUnitloadTypeId` is `null` at tiers 2/3, and the rule short-circuits on null | locations whose type does not accept the SKU's default unit-load type |
| `areaAdmitsGoodsInOrStorage` (P2.4) | all — but tiers 2/3 get the P2.7(d) lane exemption; **SKU scope does not** | locations whose area is neither goods-in nor storage |

⚠ **P2.7(f) was missing from an earlier revision of this table, and its absence had teeth.** It is the
*most* unambiguously SKU-only of the three — a literal early return. On wineco **1,345 of 8,804 SKUs
(15%)** carry an FLA, and for every one of them direction 2 reduces the eligible set to **exactly one
row**: their own pick face. That is correct behaviour, but it means "the dropdown is populated with
~1,206 rows" is wrong for 15% of SKUs, and §6's manual rows were written on that false premise — see
the corrections to M1/M2 there.

The defect is the interaction: **the UI opens the tier defined by "this location is in a goods-in
area", while tier 1 applies eligibility rules that can reject the locations goods-in areas contain.**
The two tiers are drawn on one axis and filtered on another.

### ⚠ Correction (2026-08-13, critic review): scope-DEPENDENT, not scope-structural

**An earlier revision of this section claimed the empty tier-1 default tier was *structural* — that
"any warehouse whose goods-in area holds receiving lanes and pallet stations, the ordinary shape,
gets an empty tier-1 default tier". That was generalised from one tenant and it is false.** The claim
is recorded rather than deleted because §3.5, §10 Q1 and a code comment in §3.3 were all built on it.

The same chain, reproduced as SQL on four databases for a no-FLA SKU:

| Database | goods-in candidates | **DEFAULT-tier eligible at SKU scope** |
|---|---|---|
| `dev_wh01_om1` (wineco dev) | 12 | **0** ← the defect |
| `wh01_om1_v2` (wineco uat) | 12 | 0 |
| `wh01_hydra_v2` (hydra dev2) | 2 | **2** |
| `wh02_shipitez_v2` (shipitez nywh uat) | 2 | **2** |

**On hydra and shipitez the dropdown is not empty and there is no bug.** Both discriminators are
tenant data, not code:

1. **Crossdock lanes inside the goods-in area.** Wineco's `Inbound` holds `HubAndSpoke-01…-10`
   (`crossdockinglane = true`). Hydra's and shipitez's hold only the two pallet stations. Nothing in
   the model puts hub-and-spoke lanes in a goods-in area.
2. **One `location_constraint` row.** Verified directly: `overstock pallet` permits unit-load types
   `{5}` on wineco and `{4, 5}` on hydra. Every SKU on all four tenants is type 4 (Case), so
   `EmptyPallets` / `InboundWorkstation` fail P2.6 on wineco and pass it everywhere else. **That one
   row is the whole difference between an empty and a populated tier-1 default tier.**

**What survives.** The mechanism is real and the fix is unchanged — the SKU-only predicates below
*can* empty the tier-1 default tier, and on wineco they do. What does not survive is "therefore scope
is the structurally honest discriminator". Scope remains the right lever for the **default** on the
grounds in §10 Q1 (deterministic, compile-time, testable) — not because the emptiness is structural.
See §3.5 for the corrected revisit trigger, and §3.2a for the consequence for the warning copy, which
is a genuine design change rather than a wording repair.

### Bug 2 — the toggle's own rationale does not hold at tier 1

The alert behind the switch is a real warning:

> Receiving takes an exclusive lock on the chosen location and holds it for the duration of a whole
> multi-case receipt, so choosing a location that picking, replenishment or transfer is also using
> may cause receipts to fail with a database deadlock.

That argument is strong for racking under active picking, which is what tiers 2 and 3 configure: a
warehouse or merchant default applies to **every** SKU that inherits it, so a contended destination
is contended by the whole inbound stream. Tier 1 is the opposite case by construction — a single
SKU's dedicated bin, frequently fix-assigned, as both real configurations on this tenant are
(`ICEPACK` has an FLA row; `Club08` is one SKU's override).

So the same gate is doing two different jobs, and its closing advice — *"Prefer a goods-in location
unless you have a specific reason not to"* — points at an empty set at tier 1.

### Bug 3 — the caption instructs the operator to enable something that will already be enabled

PR #56 (merged `10bec3a`) added the tier split to stop the count contradicting the dropdown, and
closed it with the actionable half:

```html
<!-- defaultPutawayLocationField.vue:57-64 -->
{{ eligibleAdvancedCount }} storage. Enable &ldquo;Show storage locations&rdquo; below to choose a
storage location.
```

Correct today. The moment Fix A opens that switch by default at SKU scope, the sentence tells the
operator to enable a switch that is already on — reintroducing, in mirror image, the
caption-contradicts-the-control defect PR #56 exists to remove.

### Not a regression

`git log` on both files shows no commit that changed this default. `showAdvanced: false` has been
the initial state since `LocationPicker` was introduced by SBDEV-2732 step 19. The behaviour became
*reachable* on 2026-08-13, when wms2-api PR #152 fixed the `/v3` mapping and the endpoint stopped
404-ing — which is why the first live run of this picker surfaced three defects in one afternoon
(#152, #153, #56) and this one behind them.

---

## 3. Fix Design

Four edits across two files. No API change, no store change, no new dependency.

### 3.1 Fix A — the storage tier opens when, and only when, the goods-in tier would be empty

**File:** `components/common/LocationPicker.vue`

⚠ **r3 — this fix was changed from scope-driven to data-driven after the UAT fleet was measured.**
r1/r2 opened the tier whenever `scope === 'SKU'`. With all six reachable databases surveyed
(§1.2e), **only 1 of 4 UAT tenants has the defect**, so a scope-driven default would change behaviour
on three tenants that have nothing wrong with them — opening ~448 rows of storage in front of a hydra
operator who today sees two clean goods-in options. The condition that actually describes the defect
is *"the goods-in tier is empty"*, so that is what the code now says.

```js
  computed: {
    /**
     * SBDEV-2947 — is any goods-in destination actually offerable right now?
     *
     * ⚠ READS THE SERVER'S `tier` and re-derives nothing — the same field `offeredItems` keys on.
     * This is NOT the forbidden client-side `useforgoodsin` test the class comment warns about; that
     * would mean recomputing the tier from raw location columns the wire does not carry.
     *
     * Drives BOTH the default gate and the advice below, so the two can never disagree — the
     * incoherent state (storage open, above advice to prefer a goods-in location) is now
     * unrepresentable rather than merely avoided by convention.
     */
    hasGoodsInOption() {
      return this.items.some((row) => row && row.eligible === true && row.tier === 'DEFAULT')
    },
  },

  data() {
    return {
      showAdvanced: false,
    }
  },

  watch: {
    /**
     * ⚠ WATCH `items`, NOT `mounted()` — the rows arrive ASYNCHRONOUSLY. The caller accumulates a
     * paginated read (§3.11.0.1) and re-binds `items` per page, so at mount the array is empty and
     * `hasGoodsInOption` is false for a reason that has nothing to do with the tenant. Opening the
     * tier there would open it on EVERY tenant, every time, which is the scope-driven behaviour this
     * revision exists to remove — silently, and only under a slow read.
     *
     * `immediate: true` covers a caller that already has its rows at first render.
     *
     * ⚠ ONE-WAY ON PURPOSE. This only ever OPENS the tier; it never closes it. An operator who opened
     * storage by hand must not have it shut under them because a later page brought a goods-in row,
     * and an operator who closed it must not have it reopened. §10 Q4 keeps the switch flippable, and
     * a watcher that fought the operator would make that promise hollow.
     */
    items: {
      immediate: true,
      handler(rows) {
        // ⚠⚠ THE `rows.length` GUARD IS LOAD-BEARING — WITHOUT IT THIS OPENS ON EVERY TENANT.
        // "No rows yet" is not "no goods-in option": an empty array satisfies `!hasGoodsInOption`
        // exactly as an all-storage one does. Two real paths arrive here with zero rows —
        //   1. `items` has `default: () => []`, so `immediate: true` fires at MOUNT, before the
        //      caller has assigned anything, on every host and every tenant;
        //   2. `getEligiblePutawayLocations` returns `items: []` from its catch on a first-request
        //      failure — a fresh zero-length array that re-triggers the handler.
        // Caught by T24 against an otherwise-correct implementation; this plan's first draft of the
        // watcher omitted the guard while its own comment described the hazard.
        //
        // ⚠ CORRECTED AT CODE REVIEW: an earlier draft justified the guard by "the caller re-binds
        // `items` per page". IT DOES NOT — `store/admin/configuration.js` accumulates every page into
        // one array inside a single `for(;;)` loop and returns ONCE, so `items` goes [] -> full set in
        // one step. The guard is still required, for the two reasons above; only the stated reason was
        // wrong. Recorded rather than silently reworded, because a reader who checks a false premise
        // and then deletes the guard reintroduces open-on-every-tenant.
        if (rows && rows.length > 0 && !this.hasGoodsInOption) {
          this.showAdvanced = true
        }
      },
    },
  },
```

Measured effect, from §1.2e:

| Tenant / scope | eligible goods-in | Tier at open | Change vs today |
|---|---|---|---|
| wineco, SKU | 0 | **opens** | ✅ the fix |
| hydra / shipitez ×2, SKU | 2 | closed | none |
| every tenant, WAREHOUSE / MERCHANT | 12 or 2 | closed | none |

**One tenant's behaviour moves, and it is the one with the defect.**

### 3.2 Fix B — the closing advice, from the same single source of truth

**File:** `components/common/LocationPicker.vue:26-38`

```html
    <v-alert v-if="showAdvanced" class="mt-3" dense type="warning"
             icon="mdi-light mdi-alert-circle-outline" :rounded="false">
      Storage locations are not goods-in areas. Receiving takes an exclusive lock on the chosen
      location and holds it for the duration of a whole multi-case receipt, so choosing a location
      that picking, replenishment or transfer is also using may cause receipts to fail with a
      database deadlock.
      <!--
        SBDEV-2947 — the RISK paragraph above is unconditional and must stay that way: the lock is
        taken regardless of tier, scope or tenant. Only the closing ADVICE moves, in three states:

          goods-in options exist         -> prefer them. True at any scope; the common case, and the
                                            state 3 of 4 UAT tenants are in at every scope.
          none, and this is tier 1       -> name the dedicated bin instead of an empty set.
          none, at tier 2/3              -> SAY NOTHING. "A dedicated single-SKU bin" is wrong wording
                                            for a warehouse-wide default, and an empty set is not a
                                            licence to print something false. Unreached on all six
                                            databases measured; present so the chain is TOTAL.
      -->
      <template v-if="hasGoodsInOption">
        Prefer a goods-in location unless you have a specific reason not to.
      </template>
      <template v-else-if="dedicatedBinTier">
        A dedicated single-SKU bin is not usually in contention; a shared pick face is.
      </template>
    </v-alert>
```

### 3.2a The one prop that remains, and why it is now honestly named

r1/r2 carried `advancedByDefault`, one boolean driving the default *and* the copy. The critic called
that under-argued and the fleet data proved it: the two concerns **do** diverge — not by caller, but
by tenant. The default belongs to the data; only the *wording* of the fallback belongs to the scope,
because "a dedicated single-SKU bin" is tier-1 language.

```js
    /**
     * SBDEV-2947 — this picker is serving the dedicated-bin tier (tier 1 / SKU scope).
     *
     * ⚠ WORDING ONLY. It does NOT decide whether the storage tier opens — `hasGoodsInOption` does
     * (§3.1). An earlier revision fused the two into `advancedByDefault`; measuring the UAT fleet
     * showed the default must follow tenant data while the fallback wording must follow the tier, so
     * fusing them made one of the two wrong on three tenants.
     */
    dedicatedBinTier: {
      type: Boolean,
      default: false,
    },
```

### 3.3 Fix C — the wrapper supplies the tier, not the default

**File:** `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue:28-34`

```html
    <!--
      SBDEV-2947 — the picker decides for ITSELF whether to open the storage tier, from the rows it
      was handed. All this passes is which tier's vocabulary to use in the fallback advice.
    -->
    <!--
      ⚠ THE `:key` IS THE SUBJECT BOUNDARY — added at code review, and load-bearing. The picker's tier
      gate is a LATCHED one-shot; this component is NOT destroyed between subjects (the SKU dialog
      mounts it with no `v-if` and only nulls its subject on close), so without a key the instance
      survives and carries the latch into the next SKU. A SKU whose goods-in tier IS populated would
      inherit a storage tier it never asked for and read "Enable Show storage locations" beneath an
      already-open switch — the caption contradicting its own control.

      ⚠ Deliberately NOT solved by making the watcher two-way, which could shut a tier the operator
      opened. The boundary belongs at the subject change, not in the picker.
    -->
    <location-picker
      :key="`${scope}-${subjectId}`"
      :value="selectedId"
      :items="eligibleItems"
      :disabled="!canEdit"
      :dedicated-bin-tier="scope === 'SKU'"
      label="Default Putaway Location"
      @input="onSelect"
    />
```

**The `:key` alone is NOT sufficient — a second change is required in the same method.**
`resetForSubject()` must also clear the candidate rows:

```js
    resetForSubject() {
      this.selectedId = this.value
      this.selectedRow = null
      this.showConfirm = false
      // ⚠⚠ BOTH HALVES ARE LOAD-BEARING. `loadEligible()` is ASYNC and Vue 2 runs this user watcher
      // before the render watcher, so the picker remounts while these arrays still hold the PREVIOUS
      // subject's rows. The new instance's `immediate: true` watcher reads those stale rows, finds no
      // goods-in option, and latches the tier open — and being one-way, it cannot correct itself when
      // the right rows land a tick later.
      this.allRows = []
      this.eligibleItems = []
      this.resetPreview()
      this.loadEligible()
    },
```

**Ablation, measured on the branch** (subject A all-storage → subject B with a goods-in option):

| Configuration | `showAdvanced` on subject B | |
|---|---|---|
| key + clear | `false` | ✅ correct |
| key removed, clear kept | `true` | latch survives on the old instance |
| clear removed, key kept | `true` | new instance latches on **stale rows** |

⚠ **The first fix attempt was the key alone, and it did not work.** A scoped code review caught it and
the defect was then reproduced directly: `key=SKU-222`, `hasGoodsInOption=true`, yet `showAdvanced=true`
— the open-storage warning and "Enable Show storage locations" rendered together for a SKU that had a
goods-in option. Recorded because "I added a key, therefore it remounts, therefore the state resets"
is a plausible chain in which every link is true and the conclusion is still false.

⚠ **The test written for the first attempt could not have caught this.** It asserted
`picker(wrapper).vm.$vnode.key` under `shallowMount` — where LocationPicker is a STUB and
`showAdvanced` is not observable at all — so it was green on a branch where the property was false.
Replaced by `doesNotCarryTheAutoOpenedTierIntoASubjectThatHasGoodsInOptions`, a real `mount` asserting
`showAdvanced === false` on the second subject, which fails under **either** ablation. The verify row
had the same defect (it grepped the test's *name*) and now requires the behavioural row's `mount(` and
`toBe(false)`.

### 3.3a Fix E — request-generation guard on `loadEligible()` (added at code review)

**File:** `defaultPutawayLocationField.vue` — `loadEligible()`, plus a `loadGeneration: 0` data field.

**Pre-existing, not a regression from this change**, but it reaches the *identical* operator-visible
screen this ticket exists to remove, so it is fixed here rather than deferred (decision recorded in
§10 Q8).

The read is a **serial page loop** in the store — ~14 sequential GETs for a 2,738-location facility, so
seconds. Closing SKU A and opening SKU B inside that window is ordinary operator speed. A late response
was applied unconditionally, and the picker's `items` watcher then re-fired **on the current,
correctly-keyed instance** — so the `:key` cannot help: there is no remount, the right instance simply
receives the wrong subject's rows and re-latches the tier open. Reproduced at review:
`subjectId=222, allRows=[900], showAdvanced=true`, where it had been `false` a moment earlier.

```js
      const generation = ++this.loadGeneration        // ⚠ BEFORE the early return
      if (this.scope === 'SKU' && this.subjectId == null) return
      ...
        const result = await this.$store.dispatch(...)
        if (generation !== this.loadGeneration) return  // superseded — drop it WHOLE
      ...
      } finally {
        if (generation === this.loadGeneration) this.loading = false
      }
```

⚠ **The bump sits BEFORE the early return** because closing the dialog nulls `subjectId` and returns
without dispatching — yet must still invalidate whatever is in flight. **A mutation escaped on exactly
this:** moving the bump below the return left every test green except the close-path one, which is why
`invalidatesAnInFlightReadWhenTheSubjectGoesAway` exists and why verify row `C-gen` asserts the
*ordering* rather than mere presence.

Dropping the response **whole** also protects `totalCount` / `eligibleCount` / `loadIncomplete` /
`selectedRow` and the `eligible-loaded` emit that `editSkuPutawayDialog` latches as the SKU's counts.

**Also fixed (Low, introduced by the row-clearing in §3.3):** `resetForSubject()` now resets
`loadIncomplete`, and the count caption is gated on `allRows.length > 0`. Without this the closed-dialog
window renders the *previous* subject's "could not be loaded completely" alert or "2 of 706 locations
can be used" over an empty picker. The counts are deliberately **not** zeroed — zeroing re-creates M4's
"0 of 0 locations can be used", an affirmative claim the caption is gated against making.

⚠ **This closes a real gap in §3.5's reasoning.** That row accepts the toggle carrying over between
subjects — but it argued only the **manual** case ("an operator who switches the tier off for SKU A
has it off for SKU B"). Fix A added an **automatic** writer to that same latched state, and the
original acceptance did not weigh it, nor its interaction with Fix D's caption. Latent on every
measured tenant (it needs per-SKU variation in goods-in eligibility, which no tenant's data produces)
— but SBDEV-2947 exists *because* a latent defect became reachable the moment three unrelated fixes
landed, so "unreachable today" was not treated as a reason to leave it.

### 3.3b Fix F — the same guard on `refreshPreview()` (added at code review)

**File:** `defaultPutawayLocationField.vue` — `refreshPreview()`, `onSelect()`, plus `previewGeneration: 0`.

**Pre-existing, and the more damaging of the two races** — `blockingReason` drives `saveDisabled`, so a
stale verdict does not merely mislead, it **blocks a legal configuration**. The old guard tested
`selectedId` at *call* time, never at *resolve* time. Select a location in SKU A's dialog, close it,
open SKU B: A's verdict lands against B, showing a red *"This location cannot be used: its area is not
used for goods-in or storage"* over a destination that is perfectly valid for B, with Save disabled.
The mirror direction sends the **other subject's** `confirmIncompatibleSkus` through D11 (the server
recomputes and 409s, so nothing corrupts — but the number the admin accepted was never about that SKU).

Same pattern as Fix E, with a **separate counter**: the two reads are triggered independently, so one
counter would let either invalidate the other's still-current response.

⚠ **`onSelect()`'s early return on a cleared selection had to go.** It returned *before* calling
`refreshPreview()`, so clearing never bumped the generation and an in-flight verdict stayed live —
landing on a field the operator had just cleared. Routing the clear through `refreshPreview()` costs
nothing (it dispatches nothing for a null selection) and is what makes the clear invalidating.
**Caught by this plan's own test, not by review** — `invalidatesAnInFlightPreviewWhenTheSelectionIsCleared`
failed against the first version of the guard.

### 3.4 Fix D — the caption's instruction follows the same fact

**File:** `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue:57-64`

⚠ **This gate changed with Fix A and the change is load-bearing.** r2 gated the instruction on
`scope !== 'SKU'`, which was correct only while the tier auto-opened at every SKU scope. Under the
data-driven default it is **wrong on hydra and shipitez**: there the tier stays closed at SKU scope,
so *"Enable 'Show storage locations'"* is still the true and necessary instruction, and hiding it
would strand the operator. The honest condition is *"the tier did not auto-open"* — i.e. a goods-in
option exists — which is the same fact Fix A keys on and is scope-independent.

```html
      <template v-if="eligibleAdvancedCount > 0">
        —
        {{ eligibleDefaultCount }} in goods-in areas<template v-if="eligibleDefaultCount === 0"> (none)</template>,
        {{ eligibleAdvancedCount }} storage.<!--
          SBDEV-2947 — the SPLIT is unconditional; it is what explains an all-storage list. The
          INSTRUCTION appears only when the switch is actually still closed, which is exactly when
          goods-in options exist. Telling an operator to enable something already enabled is the
          caption-contradicts-the-control defect PR #56 removed, in mirror image; telling them nothing
          when they DO need the switch is the original defect. `eligibleDefaultCount` is the wrapper's
          own count of the same rows the picker gates on, so the two cannot drift.
        --><template v-if="eligibleDefaultCount > 0"> Enable &ldquo;Show storage locations&rdquo; below to choose a storage location.</template>
      </template>
```

Resulting copy, measured:

| Tenant / scope | Caption |
|---|---|
| wineco, SKU | `1206 of 2738 … — 0 in goods-in areas (none), 1206 storage.` (no instruction; switch already on) |
| hydra, SKU | `448 of 706 … — 2 in goods-in areas, 446 storage. Enable "Show storage locations" …` |
| wineco, WAREHOUSE | `516 of 2738 … at this level — 12 in goods-in areas, 504 storage. Enable "Show storage locations" …` |

⚠ These are **measured**. An earlier revision printed `7 of 2738 … 2 in goods-in areas, 5 storage` for
the WAREHOUSE row — invented figures reading as measured, in a plan whose §1.3 opens by correcting the
ticket for exactly that.

### 3.5 Rejected alternatives

| Alternative | Why not |
|---|---|
| **Auto-open when 0 `DEFAULT` rows are eligible** (ticket option 2) | Safety default becomes data-dependent; untestable against the tenant that receives it. Superseded by the §1.2c finding that the emptiness is scope-structural, so scope is the honest discriminator. |
| **Discoverability only** (ticket option 3) | Already merged as PR #56 and kept as the safety net, but it leaves the primary workflow behind a deliberate extra step whose warning is about a risk that does not apply at tier 1. |
| **Flag `useforgoodsin` on a storage area, or add `location_constraint` rows** (ticket option 4) | Changes receiving behaviour warehouse-wide to make one picker look better. And per §1.3(ii) the constraint half is a no-op — those types already permit everything. |
| **Hide the toggle at SKU scope** | Removes a disclosed safety control and makes tier 1 structurally different from the other two pickers. §10 Q4 chose to keep it flippable. |
| **Change `tier` server-side to be scope-aware** (e.g. `DEFAULT` = "eligible and recommended at this scope") | Rejected — but on a **better argument than blast radius**. `tier` is assigned at `PutawayDestinationQueryService.java:331` and has exactly **two** consumers, both in this repo: `LocationPicker.offeredItems` and the wrapper's `eligibleDefaultCount`/`eligibleAdvancedCount`. So the reach is small. The decisive objection is **meaning**: redefining `tier` as "eligible and recommended here" makes the caption's own words — *"N **in goods-in areas**"* — false, because `tier` would no longer mean goods-in. That is changing a field's semantics to move a UI default. ⚠ **Revisit trigger corrected:** the old trigger ("a second tenant shows an empty default tier at *tiers 2/3*") is near-unreachable — at tiers 2/3 P2.3/P2.6/P2.7(f) are all skipped and P2.4 passes by construction for a goods-in area, so it would need *every* goods-in location to be a gate, lane, flowbin or locked. It recorded "never revisit" while looking like a condition. **The live condition is the opposite and is true today on hydra and shipitez: a tenant whose SKU-scope DEFAULT tier is non-empty**, where the scope-driven default is unnecessary and the scope-driven copy is wrong (§3.2a). |
| **Reset the toggle when `subjectId` changes** | Out of scope — but ⚠ **the earlier rationale here was factually wrong.** It claimed "there is no state to leak between SKUs". There is: `skuData.vue:192` mounts `<edit-sku-putaway-dialog>` with **no `v-if`** (only `:show` toggles the inner `v-dialog`), so dialog → field → picker stay mounted for the life of the page, and `resetForSubject()` never touches `showAdvanced`. An operator who switches the tier off for SKU A has it off for SKU B, C, D until reload. Accepted as a deliberate carry-over — the toggle is a per-session view preference, and resetting it per SKU would fight the operator — but accepted knowingly, not because the state cannot leak. |

---

## 4. Architecture Overview

```
Master Data → SKU → [pencil]
  └─ editSkuPutawayDialog.vue                       scope="SKU", :subject-id="sku.id"
      └─ defaultPutawayLocationField.vue            owns the data, the preview gate, the write
          ├─ store admin/configuration/getEligiblePutawayLocations   (paginated, accumulated)
          │     └─ GET /v3/putawayConfig/eligibleLocations
          │           └─ PutawayDestinationQueryService.eligibleLocations
          │                 ├─ LocationRepository.findPutawayCandidates   2,738 rows
          │                 └─ PutawayDestinationValidator.verdictFor   per row
          │                       └─ PutawayDestinationRules.CHAIN  ── 9 rules, 2 of them SKU-only
          │                 → rows: { locationId, locationName, areaName, locationType,
          │                           tier: DEFAULT|ADVANCED, eligible, blockingReason }
          │
          ├─ caption  "N of M …"  + PR #56 tier split      ◀── Fix D
          └─ LocationPicker.vue                            ◀── Fixes A, B  (◀── Fix C passes the prop)
                ├─ v-autocomplete   offeredItems = eligible ∧ (selected ∨ DEFAULT ∨ showAdvanced∧ADVANCED)
                ├─ v-switch         "Show storage locations"   ── initial state = advancedByDefault
                └─ v-alert          lock-contention warning     ── closing advice = advancedByDefault
```

**Key files**

| File | Lines | Role |
|---|---|---|
| `wms2-web-ui components/common/LocationPicker.vue` | 89, 26-38, 114-123 | the tier gate, its switch, its warning — **Fixes A, B** |
| `wms2-web-ui components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue` | 28-34, 44-64 | the only picker host; owns the caption — **Fixes C, D** |
| `wms2-web-ui components/masterData/material/skuData/editSkuPutawayDialog.vue` | 97-105 | the affected screen; delegates entirely — **unchanged** |
| `wms2-api service/PutawayDestinationQueryService.java` | 331 | assigns `tier` from `area.useforgoodsin` — **unchanged, and correct** |
| `wms2-api service/PutawayDestinationRules.java` | 37-46, 222, 227 | the 9-rule chain; rules 2, 8 and 9 are SKU-only — **unchanged, the source of the asymmetry** |
| `wms2-api service/LocationConstraintService.java` | 61-63 | the fail-open that §1.3(ii) corrects the ticket on — **unchanged** |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **N/A** | — | UI-only; no schema, no seed row, no Flyway version. |
| 2 | **Feature flags / system properties** | **N/A** | — | No sysprop. The change is a compile-time default keyed on `scope`. |
| 3 | **Config / env changes** | **N/A** | — | No env var, no `nuxt.config.js` change. |
| 4 | **Deploy-order dependencies** | **wms2-api ≥ `origin/develop` @ `0517286`** must already be deployed | dev/ops | PR #152 (`/v3` mapping) and #153 (no exception-per-row) are **already merged**. Without #152 the endpoint 404s and this fix is invisible — the dropdown is empty for a different reason. No new API work; nothing to sequence. |
| 5 | **Data migration** | **N/A** | — | No data is read or written differently. |
| 6 | **External systems** | **N/A** | — | No OMS, printer, or Keycloak interaction. |
| 7 | **Access / permissions** | **N/A** | — | Unchanged. The dialog is already `sb_admin`-gated via `resolveSbAdmin`; this plan does not touch `canEdit`. ⚠ `sb_admin` rides the Keycloak **`groups`** claim — do not "improve" the gate to `hasResourceRole` while in this file. |
| 8 | **Monitoring / alerts** | **N/A** | — | No new failure mode; no telemetry surface in this UI (see §6 manual plan and §8). |
| 9 | **Branch base** | branch off freshly-fetched `origin/develop`, **not** the local checkout | implementer | ⚠ At the time of writing, local `v2/wms2-web-ui develop` is **19 commits behind** `origin/develop` and does **not** contain `editSkuPutawayDialog.vue`, the SKU write, or PR #56's caption. Every line number in this plan is `origin/develop`. |

### 5.2 Implementation Checklist

One PR into `develop` on `bugfix/SBDEV-2947-sku-putaway-storage-tier-default`. Steps 1–4 are one
logical change and should be one commit; step 5 the tests.

- [ ] **Step 0** — `git fetch origin && git checkout -b bugfix/SBDEV-2947-sku-putaway-storage-tier-default origin/develop`; confirm `components/masterData/material/skuData/editSkuPutawayDialog.vue` exists (proves the base is current). Run `bash sbdocs/9-System/scripts/verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh` and record the **pre-fix FAIL baseline**.
- [ ] **Step 1 (Fix A)** — add the `advancedByDefault` prop, initialise `showAdvanced` from it, add the `advancedByDefault` watcher. `LocationPicker.vue`.
- [ ] **Step 2 (Fix B)** — split the warning's closing sentence on `advancedByDefault`; leave the risk paragraph byte-identical. `LocationPicker.vue`.
- [ ] **Step 3 (Fix C)** — bind `:advanced-by-default="scope === 'SKU'"` at the single call site. `defaultPutawayLocationField.vue`.
- [ ] **Step 4 (Fix D)** — gate the caption's trailing instruction on `scope !== 'SKU'`; keep the split unconditional; amend the `:44-53` comment. `defaultPutawayLocationField.vue`.
- [ ] **Step 5** — tests per §6: 6 new rows in `locationPicker.spec.js`, 4 in `defaultPutawayLocationField.spec.js`, 1 in `editSkuPutawayDialog.spec.js`.
- [ ] **Step 6** — `node_modules/.bin/jest` (full suite) green; `yarn lint` clean.
- [ ] **Step 7** — verify script reports `Result: N pass, 0 fail`; paste the line verbatim into the PR body.
- [ ] **Step 8** — manual test plan §6 executed on dev against a WineCo SKU; §6's row M5 (the tier-2/3 regression row) is not optional.
- [ ] **Step 9** — update §9 Implementation Status: commit SHAs, jest counts, the verify line, PR link. Move ClickUp to `pr submitted`.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Tier 1 opens on storage | mount `LocationPicker` with `advancedByDefault: true`, rows of both tiers | `showAdvanced === true` before any interaction; `ADVANCED` rows in `offeredItems` |
| Tiers 2/3 unchanged | mount with the prop absent | `showAdvanced === false`; only `DEFAULT` rows offered — T5/T9/T16 still pass unmodified |
| Warning is not suppressed | mount with `advancedByDefault: true` | the lock-contention alert renders at mount, with the risk paragraph verbatim |
| Advice follows the tier | mount both ways | `advancedByDefault` → the dedicated-bin sentence, and **not** "Prefer a goods-in location"; default → the reverse |
| Toggle stays flippable | mount with `advancedByDefault: true`, emit `change:false` on the switch | `showAdvanced === false`; `ADVANCED` rows drop out; no `input` emitted (the value is not cleared) |
| Scope change re-arms the gate | mount the picker, `setProps({ advancedByDefault: true })` | `showAdvanced` becomes `true` — the Vue-2 `data()`-reads-once trap |
| Wrapper passes the flag | `shallowMount` the field at each of the three scopes | picker prop `advancedByDefault` is `true` at `SKU`, `false` at `WAREHOUSE` and `MERCHANT` |
| Caption at SKU scope | field at `scope: 'SKU'`, rows `(0 DEFAULT, 1206 ADVANCED)` | contains `0 in goods-in areas (none)` and `1206 storage`; does **not** contain `Enable` |
| Caption at tier 2/3 | field at `scope: 'WAREHOUSE'`, rows `(2, 5)` | unchanged from PR #56, instruction included |
| SKU dialog end-to-end | full `mount` of `editSkuPutawayDialog`, storage rows only | the autocomplete's items are non-empty on open |

### New / updated tests

| Test file | Test name | What it asserts |
|---|---|---|
| `test/components/common/locationPicker.spec.js` | `T18: advancedByDefault opens the storage tier at mount` | `showAdvanced === true`; `offeredItems` includes the `ADVANCED` row, with no interaction |
| " | `T19: the prop defaults to false — tiers 2 and 3 are untouched` | prop absent → `showAdvanced === false`, only `DEFAULT` offered. **The regression guard for the four shipped hosts** |
| " | `T20: the lock warning renders at mount when the tier opens by default` | alert exists on first render; its text contains the full risk sentence (`exclusive lock` … `database deadlock`) |
| " | `T21: the closing advice names a dedicated bin, not a goods-in preference` | with the prop: contains `dedicated single-SKU bin`; `.not.toContain('Prefer a goods-in location')` |
| " | `T22: ...and the default keeps the goods-in advice` | without the prop, toggled open: contains `Prefer a goods-in location`; `.not.toContain('dedicated single-SKU bin')` |
| " | `T23: the switch is still flippable at tier 1` | `change:false` → `showAdvanced === false`, `ADVANCED` rows gone, **no `input` event emitted** |
| " | `T24: a live scope change re-arms the gate` | `setProps({ advancedByDefault: true })` after mount → `showAdvanced === true` |
| `test/components/admin/defaultPutawayLocationField.spec.js` | `passesAdvancedByDefaultAtSkuScope` | `picker(wrapper).props('advancedByDefault') === true` at `scope: 'SKU'` |
| " | `negWithholdsItAtTierTwoAndThree` | `false` at both `WAREHOUSE` and `MERCHANT` — a loop over both, not one |
| " | `skuCaptionKeepsTheSplitAndDropsTheInstruction` | text has `0 in goods-in areas (none)` + `1206 storage`; `.not.toContain('Enable')` |
| " | `tierTwoCaptionStillCarriesTheInstruction` | unchanged PR #56 wording at `WAREHOUSE` |
| `test/components/masterData/material/skuData/editSkuPutawayDialog.spec.js` | `skuDialogOffersStorageLocationsOnOpen` | **full `mount`** (not `shallowMount` — the existing rows stub the picker away, so none of them can catch this): open the dialog with an all-`ADVANCED` eligible set; the `v-autocomplete`'s items are non-empty |

⚠ **`mvn` is not involved.** This is `wms2-web-ui` (Nuxt 2 / Jest). Per the recorded landmine there is
no `yarn` on PATH here; run `node_modules/.bin/jest` under an nvm node:

```bash
cd v2/wms2-web-ui
node_modules/.bin/jest --testPathPattern='(locationPicker|defaultPutawayLocationField|editSkuPutawayDialog)'
node_modules/.bin/jest        # full suite before the PR leaves the branch
```

### Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| M1 | The reported defect is gone — **SKU with no FLA** | dev (wineco/wsl, `dev_wh01_om1`) | Master Data → SKU → pick a SKU **not** in the FLA set (`SELECT id FROM itemdata i WHERE NOT EXISTS (SELECT 1 FROM fix_location_assignment f WHERE f.itemdata_id = i.id) LIMIT 1`) → pencil | Dropdown **populated** on open, ~1,206 rows. Switch already on. | |
| M1b | …and the **FLA** case, which is 15% of SKUs | dev | same, on any SKU that HAS an FLA | Dropdown holds **exactly one** row — that SKU's own pick face. ⚠ This is CORRECT (P2.7(f) direction 2), not a regression. An earlier revision of M1 said "~1,206 rows" for every SKU and would have been read as a failure here. | |
| M2 | The ice-pack case | dev | same, on itemdata **874400** (`ICE PACK`) | ⚠ **Re-baselined at critic review:** 874400 now already carries `putawaylocation_id = ICEPACK` (saved by hand 2026-08-13 during manual testing) **and** has an FLA on `ICEPACK`. So the dialog opens with ICEPACK **preselected** and exactly **one** offered row — not the "select it fresh" flow this row used to describe. Verify it renders preselected, saves, and the effective line reads the SKU override. To exercise the fresh path, clear it first. | |
| M3 | Risk still disclosed | dev | observe the dialog on open | Lock-contention warning visible **without touching anything**, closing with the dedicated-bin sentence, **not** "Prefer a goods-in location" | |
| M4 | Caption agrees with the control | dev | read the caption above the dropdown | `1206 of 2738 … — 0 in goods-in areas (none), 1206 storage.` and **no** "Enable …" | |
| M5 | **Tier 2/3 regression — not optional** | dev | Admin → Parameters & Configuration → Operation Options; and Admin → Shippers → edit a shipper | Both still open **closed**, offering the 12 goods-in locations, with the "Enable …" instruction present and the old "Prefer a goods-in location" advice once toggled | |
| M6 | The toggle still works at tier 1 | dev | in the SKU dialog switch *Show storage locations* off | List empties (0 goods-in eligible); a previously-saved value stays visible; switching back on restores the list | |
| M7 | An existing override renders | dev | open the one SKU already configured (→ `Club08`) | `Club08` is preselected and visible; no "no longer available" banner | |
| M8 | SQL sanity — the fix changed no data | dev DB | `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NOT NULL;` before/after browsing | ⚠ **Baseline is 2, not 1** (Club08 since 2022, ICEPACK since 2026-08-13). Unchanged at 2 while browsing; only a deliberate save may move it. Take a fresh `SELECT` as the baseline rather than trusting this number — it moved once already, mid-plan. | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `node_modules/.bin/jest --testPathPattern='(locationPicker\|defaultPutawayLocationField\|editSkuPutawayDialog)'` | | |
| `node_modules/.bin/jest` (full) | | |
| `yarn lint` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Any `wms2-api` test | No Java changes. §1.3's corrections are *findings about* existing behaviour, not requests to change it — `LocationConstraintService`'s fail-open is deliberate and documented at its own call site. |
| Cypress e2e | `cypress/e2e/wms/scenario2/step5-verify-mobile-putaway.cy.js` covers mobile putaway, not this admin dialog. Adding an admin-dialog e2e is out of proportion; M1–M7 cover the click path. |
| A test that the *initial* tier-2/3 default is unchanged **in production code** | Covered structurally: T19 pins the prop default at `false` and `negWithholdsItAtTierTwoAndThree` pins the wrapper's binding. A third assertion would restate them. |

---

## 7. Horizontal Scalability Validation

**Every row is N/A, on one shared rationale: this plan changes no JVM code.** The only artifacts are
two Vue single-file components in `v2/wms2-web-ui`, which runs as a stateless Nuxt SSR front end and
holds no tenant data, no cache and no DB connection. The rows are enumerated rather than collapsed
because the template requires an explicit verdict per concern.

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | N/A | No Java. The one new piece of state is `showAdvanced`, already component-local per browser tab. |
| 2 | Connection pool math | N/A | No change to request count or shape. The picker's paginated read is unchanged — same endpoint, same page size, same accumulate. |
| 3 | Scheduled jobs | N/A | None added or touched. |
| 4 | Long transactions | N/A | No transaction. |
| 5 | Request affinity | N/A | The new state lives in one component instance in one browser; nothing is assumed about which replica serves the next request. |
| 6 | Retry / idempotency | N/A | No write path changes. The tier-1 write is untouched. |
| 7 | Tenant context | N/A | No async boundary, no `TenantContext`. |
| 8 | Distributed lock correctness | N/A | No lock. ⚠ Note the *subject* of the copy is receiving's exclusive location lock — this plan changes only prose about it, never the lock. |
| 9 | Cache invalidation | N/A | No `@Cacheable` entity written. The eligible-locations read is not cached client-side. |
| 10 | External notifications | N/A | None. |

### v2-only constraint checklist

| # | Constraint | Verdict | Note |
|---|---|---|---|
| 1 | OSIV disabled | N/A | No repository access added. |
| 2 | `tenantTransactionManager` | N/A | No `@Transactional` added or moved. |
| 3 | `readOnly = true` | N/A | " |
| 4 | Caffeine invalidation | N/A | No cached entity written. |
| 5 | Jakarta namespace | N/A | No Java. |
| 6 | H2-compatible test SQL | N/A | No SQL in tests. The §1.2 queries are analysis-time only and are recorded in this document, not committed. |
| 7 | `BaseControllerTest` | N/A | No controller change. |
| 8 | Micrometer metrics | N/A | Reused-metric question does not arise; see §8 on the absence of a UI telemetry surface. |

---

## 8. Notes

**Relationship to the sibling plans.** This is a follow-on defect from
[SBDEV-2643](SBDEV-2643-sku-default-putaway-location-ui.md) (the SKU-scope dialog, all six phases
merged 2026-08-12) built on [SBDEV-2732](SBDEV-2732-configurable-default-putaway-location-hierarchy.md)
(the shared picker and the four-tier hierarchy, both phases merged 2026-08-11). It is the fourth
defect surfaced by the same manual-test session on 2026-08-13, after wms2-api #152 (`/v3` mapping),
#153 (exception-per-row logging) and wms2-web-ui #56 (the caption). It does **not** block archiving
either sibling.

**A separate ticket IS warranted — but not the one the ticket proposes.** §1.2e shows wineco's
`overstock pallet` type permits only unit-load type `{5}` while all three other tenants permit
`{4, 5}`. Adding the `Case` row would make wineco's two goods-in stations usable at tier 1 and remove
this defect at its source. Whether that is right is a warehouse-operations question — those stations
may be genuinely pallet-only — so it needs a human decision, not a code change. **Raise it as its own
ticket; it does not block this fix**, and the UI fix is correct either way (if the row is added,
wineco simply joins the other three and the tier stops auto-opening).

**The ticket's own "Not in scope" note should be closed rather than actioned.** §1.3(ii) shows
the premise is inverted — `HubAndSpoke-01…-10` already accept every unit-load type, because the
constraint check fails open on a type with no rows. They are ineligible at tier 1 because
`crossdockinglane = true`, which is presumably correct for hub-and-spoke lanes. Adding
`location_constraint` rows would only narrow them.

**No telemetry.** As with SBDEV-2930, there is no analytics surface in this UI, so there is no
signal that would tell us operators stopped hitting the empty dropdown. M1–M7 are the only evidence
this fix works in the field; treat the manual plan as the acceptance gate, not a formality.

**If a second tenant shows an empty default tier at tier 2 or 3**, revisit the rejected server-side
option in §3.5 (making `tier` scope-aware) rather than adding a second UI special case. Two
special cases is where this control starts drifting from the server's model.

**Effort:** ~0.5 day including tests and the manual plan.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh`

```bash
WEB_UI_ROOT=/home/nampark/dev/wms-claude/v2/wms2-web-ui \
  bash sbdocs/9-System/scripts/verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh
```

Single-root (`WEB_UI_ROOT`) — this plan touches one repo. Point it at the per-ticket worktree when
verifying implementation work, or it grades the main checkout instead.

⚠ **Baseline it against `origin/develop` before writing a line of code.** Recorded landmine: a
`N pass, 0 fail` proves nothing until the pre-fix tree has been watched go red. Two script hazards
that specifically apply here and are guarded in the script itself:

- **Every helper carries `[ -f "$file" ] || return 1`.** The template's helpers exit 0 on an
  unopenable file, so a negative check would false-green on the stale local checkout, which does not
  contain `editSkuPutawayDialog.vue` at all.
- **Fix B's negatives are conjoined with their positives.** `not.toContain('Prefer a goods-in
  location')` is trivially true on a tree where the sentence has not moved yet — an unconjoined
  negative would be green before the work starts, which is how a row stops carrying information.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Trivial | 4 edits, 2 files, one component pair, no contract change |
| **Pre-draft step** | none — the four decisions were put to the requester directly (§10) | |
| **Plan-review step** | `critic` (optional) | Trivial-class; the reviewer may skip. See the header note on `ralplan`. |
| **Implementation shape** | `executor` | one agent, one PR |
| **Verification step** | verify-script + `verifier` | mandatory |
| **Code-review step** | `code-reviewer` | cheap here, and the last three PRs in this area each found something |
| **Commit step** | git directly | one logical change + its tests |

---

## 10. Open Questions / Resolved Decisions

**No open questions. Seven decisions, all closed by the requester.** Q1–Q4 were taken before drafting;
Q1 and Q3 were then **reopened and reversed** on evidence, and Q5–Q7 arose from that evidence. The
superseded answers are kept rather than overwritten — §3 was built on them once, and a reader who finds
only the final answer cannot tell which parts of the reasoning were retired.

| # | Question | Decision | Rationale |
|---|---|---|---|
| Q1 | Scope-driven default, data-driven, or both? | ⚠ **REVERSED at Q5.** Originally *scope-driven*. | Original reason — "a data-driven safety default cannot be tested against the tenant that gets it" — rested on §2's *structural* claim, which a critic review falsified. See Q5. |
| Q2 | What does the lock warning say once the storage tier is open? | **Scope-aware closing sentence**; risk paragraph byte-identical everywhere. Refined at Q6 to key on data first. | Rejected keeping it identical (advises an empty set) and warning only after selection (discloses risk after the decision). Still the shape in r3 — only its *driver* moved. |
| Q3 | What does the PR #56 caption say at SKU scope? | ⚠ **REVERSED at Q7.** Originally *drop the instruction at SKU scope*. | Correct only while the tier auto-opened at every SKU scope. Under the data-driven default it strands a hydra operator. See Q7. |
| Q4 | Does the toggle stay flippable? | **Yes.** Only the initial state changes. | Keeps the control honest and symmetric across scopes. Rejected hiding it (removes a disclosed safety control) and locking it on (a third data-dependent UI state). **Unchanged by r2/r3**, and it is why Fix A's watcher is one-way — see T24b. |
| Q5 | *(reopened Q1, after the UAT fleet survey)* Scope-driven or data-driven **default**? | **Data-driven.** The picker opens the storage tier only when zero eligible `DEFAULT`-tier rows exist. | §1.2e: **only 1 of 4 UAT tenants is affected.** A scope-driven default would change behaviour on three tenants with no defect — opening ~448 storage rows in front of a hydra operator who today sees two clean goods-in options. Q1's objection was to a *safety default* moving with tenant data; with the fleet measured, the condition is testable per tenant in one query, and "the goods-in tier is empty" is simply what the defect *is*. |
| Q6 | *(refines Q2)* What drives the closing advice? | **Data first, scope only for the fallback wording.** `hasGoodsInOption` → prefer goods-in; else `dedicatedBinTier` → dedicated bin; else nothing. | Scope-driven copy is **wrong on hydra and shipitez**, where SKU scope has 2 eligible goods-in rows: it would print "a dedicated single-SKU bin" while goods-in options sat in the same dropdown — Bug 3 in mirror image. The third state exists so the chain is total: "a dedicated single-SKU bin" is wrong wording for a warehouse-wide default, and an empty set is not a licence to print something false. |
| Q7 | *(reopened Q3)* What gates the caption's "Enable …" instruction? | **`eligibleDefaultCount > 0`** — i.e. the switch is actually still closed. Not scope. | Under the data-driven default the tier stays closed at SKU scope on hydra/shipitez, so the instruction is still **true and necessary** there; gating on scope would hide it exactly where the operator needs it. Gating on the same fact Fix A keys on means the caption and the control cannot disagree. |

| Q8 | *(raised at code review)* A **pre-existing** race — a late `loadEligible()` response is applied unconditionally — reaches the same broken screen. Fix here or file separately? | **Fix in this PR** (§3.3a). | It produces the identical operator-visible symptom this ticket removes, at ordinary operator speed. Shipping "the tier no longer opens wrongly" while leaving a live path that opens it wrongly would be incoherent, and a reviewer would reasonably ask why. ~6 lines plus two tests. |

| Q9 | *(raised at the fourth review pass)* `refreshPreview()` carries the identical unguarded race, and it gates **Save**. Fix here or file separately? | **Fix in this PR** (§3.3b). | Consistent with Q8, and this one is worse in kind: the tier race misleads, this one blocks a legal save behind a false error. Same three-line pattern, ~15 lines with tests. |

### Retired rationale — recorded so it is not re-derived

- **"The empty tier is structural."** False. Falsified by measuring three further databases; the
  discriminator is one `location_constraint` row (§2's correction, §1.2e). The scope-driven default and
  its Q1 justification both rested on this.
- **"One prop must drive both effects, or they can go incoherent."** Superseded by Q5/Q6. The two
  concerns genuinely diverge — not by caller, as the r1 rationale assumed, but **by tenant**. They are
  now driven by two different facts, and the incoherent state is unrepresentable because the default and
  the primary advice branch read the *same* `hasGoodsInOption`.

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1.2 — `execute_sql` against `dev_wh01_om1` (identity confirmed, Flyway `2.2.16`); the rule chain reproduced in SQL and cross-checked against four figures asserted independently in the production source; `db_verified: true`. Two ticket figures corrected in §1.3. |
| 1 | **All callsites enumerated** | ✓ §0 — 13 rows, enumerated by `git grep` on `origin/develop`; 5 in-scope production rows, each mapped to a §3 fix and a verify row |
| 2 | **Adjacent bugs** | ✓ §0 rows 8, 12 — the four tier-2/3 hosts share the component but not the defect (§1.2c proves it); `git grep` finds no second `LocationPicker`, and neither the mobile UI nor v1 has one |
| 3 | **Backward compatibility** | ✓ Additive prop with `default: false`. Every existing caller is byte-identical in behaviour; T19 and `negWithholdsItAtTierTwoAndThree` pin it. No API, wire-format, persisted-state or payload change. |
| 4 | **Concurrency** | no — client-side render state in one browser tab. No shared state, no race. The *subject* of the copy is receiving's exclusive lock, but nothing here touches it. |
| 5 | **Multi-tenant** | ✓ The fix is deliberately tenant-independent — that is Q1's whole argument against the data-driven option. Measured on one tenant; the mechanism (§2 Bug 1) is scope-structural and holds regardless of tenant data. |
| 6 | **Error handling** | ✓ No new throw path. The existing `loadIncomplete` / `blockingReason` / 422 surfacing is untouched, including the `scope === 'SKU' && subjectId == null` guard at `loadEligible` — do not disturb it while in this file. |
| 7 | **Observability** | ✓ §8 — no UI telemetry surface exists; recorded explicitly rather than left blank, and the manual plan is therefore the acceptance gate |
| 8 | **Rollback / migration** | ✓ §5.1 rows 1–5 all N/A. Rollback is reverting one commit; no state to unwind, nothing persisted. |
| 9 | **Test coverage** | ✓ §6 — 7 picker rows, 4 wrapper rows, 1 mounted dialog row, plus 8 manual scenarios including the M5 tier-2/3 regression row |
| 10 | **Cross-version (v1↔v2)** | ✓ no — v2-only. `git grep` on `v1/wms-web-ui origin/develop` finds no `LocationPicker` and no `Show storage locations`; the whole four-tier putaway hierarchy is a v2 feature (SBDEV-2732). Nothing to port. |

---

## 12. Implementation Status

**MERGED to `develop` 2026-08-15.** Merge commit **`3098e46`**, confirmed an ancestor of `origin/develop`. Merge commit (not squash), branch retained, matching repo convention. ClickUp moved `pr submitted` → `on dev`.

> [!warning] **Merged with the §12 review gap still open.** No review lane ever ran against the final commit `879693a`, and PR review — named here as "the remaining gate" — did not happen either: the PR merged with zero reviews. That matters because three consecutive rounds each introduced a defect while fixing the previous one, and `879693a`'s fixes are the first in that chain never seen by a fresh reviewer. They are covered by tests (96/96 targeted, 29/29 mutations caught), but not by a second pair of eyes.

- **PR:** [wms2-web-ui #61](https://github.com/SiteBossInc/wms2-web-ui/pull/61) → `develop` — **merged `3098e46`**
- **Worktree:** `.claude/worktrees/wms2-web-ui/SBDEV-2947`
- **Branch:** `bugfix/SBDEV-2947-sku-putaway-storage-tier-default`, off `origin/develop` `39eedd4`,
  pushed 2026-08-13
- **Commits:**
  - `742dc84` — open the putaway storage tier when goods-in has no eligible option
  - `879693a` — invalidate in-flight previews on subject change; no availability claim before the
    first read (the 5th-pass High + Medium)
- **Final measured contracts (re-run on `879693a` at PR time, not carried over from the gate):**
  verify **`47 pass, 0 fail`**; targeted Jest **96 / 96**; full suite **370 passed / 370**.
- **Zero regressions:** **370 / 370** vs **338 / 338** clean = +32, exactly the new tests. ⚠ Both show
  `Test Suites: 2 failed` — `labelPrinting/zplPreview.spec.js` and `labelCsvUpload.spec.js`,
  **pre-existing**, zero failing tests.

> ⚠ **Superseded gate figures, kept so they are not re-derived as current.** The TDD gate measured
> 18 tests / `12 failed, 70 passed, 82 total`, a satisfiability check of `82/82` + `34 pass, 0 fail`,
> and 356/356. All four are **r2-era**; the five code-review passes added 14 more tests and 13 more
> verify rows. The live contract is the 47/96/370 line above.

> ⚠ **No review lane ran against `879693a` itself.** The 5th pass reviewed the working tree and its
> fixes were then committed; the plan doc was saved in the same second as the commit. This matters
> because three consecutive rounds each introduced a defect while fixing the previous one (Fix E's
> `finally` guard → 4th-pass Low 1; Fix D's caption gate → 4th-pass Low 2; that fix → 5th-pass
> Medium). The 5th pass's own fixes are the first in that chain never seen by a fresh lane — they
> are covered by tests and mutations, but not by a reviewer. Flagged to the requester before the
> push; PR review is the remaining gate.

### ⚠ The gate earned its keep — T24 found a defect in this plan's own code

The r3 watcher was first written as `immediate: true` + `if (!this.hasGoodsInOption)`. Test **T24**
failed it against an otherwise-correct implementation: `immediate` fires **before the first page of a
paginated read arrives**, and an empty `items` array has no goods-in option either — so the tier would
have opened on **every tenant**, reinstating exactly the scope-blind behaviour r3 exists to remove, and
visibly only under a slow read. The plan's comment described the hazard; its code did not guard it.
Fixed with the `rows.length > 0` guard, pinned by verify row `A-empty`.

### Independent review lanes (Phase 3)

**Conformance (`verifier`) — PASS.** Reproduced every number independently, including standing up its
own clean `origin/develop` worktree to confirm the two red suites are pre-existing (338/338 there, both
dying at module resolution, zero failing tests). All five design properties confirmed by reading the
diff, and the lock warning's risk paragraph verified byte-identical to `origin/develop`. No gaps.

**Code review — no High; 1 Medium + 4 Low.** Resolutions:

| # | Finding | Resolution |
|---|---|---|
| Medium 1 | The auto-opened tier **latches across subjects**; a later SKU with goods-in options inherits an open tier and a caption telling it to enable an already-on switch | **FIXED ON THE SECOND ATTEMPT.** The `:key` alone was insufficient — a scoped re-review proved the remounted picker re-latched on the previous subject's rows, because `resetForSubject()` did not clear them and `loadEligible()` is async. Reproduced directly, then fixed with key **+** row-clear; both halves ablation-tested (§3.3). ⚠ The first attempt's test asserted `$vnode.key` under `shallowMount` and was green on a branch where the property was false — replaced with a real-`mount` behavioural row, and the verify row strengthened to require it |
| Low 2 | The comment promised a manually-closed tier stays closed across a reload. **It does not**, and `T24b` did not test that | **FIXED (comment + test comment)** — both now state what is actually guaranteed. Behaviour left as-is: where this fires the goods-in tier is empty, so reopening restores the only usable options |
| Low 3 | The guard's stated rationale — "the caller re-binds `items` per page" — **describes a mechanism that does not exist**; the store accumulates all pages and assigns once | **FIXED (rationale)** — corrected in the component, the plan and the tests. The guard is still required, for two *different* reasons: the `default: () => []` prop under `immediate: true`, and the store's catch returning `items: []`. Left on the record because a reader who checks a false premise and deletes the guard reintroduces open-on-every-tenant |
| Low 4 | The auto-open can decide on a **partial read** and cannot self-correct (one-way) | **DEFERRED, recorded.** Mitigated by the red "could not be loaded completely" alert directly above. Closing it means passing `loadIncomplete` into the picker — new prop, new state, beyond this fix's scope |
| **4th pass — Medium** | `refreshPreview()` has the identical unguarded race, and it gates **Save** | **FIXED** (§3.3b, Q9) |
| **4th pass — Low 1** | `loading` latched `true` forever on the close path — **introduced by Fix E's `finally` guard** | **FIXED** — the early return clears it; pinned by `doesNotStrandTheSpinner…` and row `C-gen-close` |
| **4th pass — Low 2** | A **successful** read returning zero rows rendered total silence — **introduced by Fix D's caption gate** | **FIXED** — explicit "No locations are available…" branch; pinned by `statesThatNothingIsAvailable…` and row `D-empty` |
| **5th pass — HIGH** | `previewGeneration` was bumped ONLY inside `refreshPreview()`, so a **subject change** never invalidated an in-flight preview — SKU A's verdict landed on SKU B, disabling Save behind a false error. ⚠ **Fix F's own docblock claimed this case was covered**, so it would have shipped signed off | **FIXED** — bump moved into `resetPreview()`, the chokepoint every discard shares. Reproduced before fixing; pinned by `invalidatesAnInFlightPreviewWhenTheSubjectChanges` and row `C-prev-reset` |
| **5th pass — Medium** | `loading` started `false`, and `mounted()` awaits `resolveSbAdmin()` before the first read — so the initial render hit the new empty-set branch and asserted "No locations are available" with **zero** reads dispatched. **Introduced by the 4th-pass Low 2 fix** | **FIXED** — `loading` starts `true`; pinned by `makesNoAvailabilityClaimBeforeTheFirstReadIsIssued` and row `C-load-true` |
| **4th pass — Low 3** | Three sub-changes had **zero** regression cover (all 87 tests green with them deleted) | **FIXED** — four rows added. ⚠ Three of them *escaped their own mutations first*: they asserted in windows where `loading` or a following read masked the defect. Retargeted onto the close path. One "guard" turned out to be **dead code** (`allRows.length > 0`, unreachable once the empty-set branch preceded it) and was removed rather than kept as decorative protection |
| Low 5 | The caption tracks "a goods-in option exists", not "the switch is closed", so a hand-enabled switch still shows the instruction | **NO CHANGE — pre-existing, zero delta** (the old code printed it unconditionally). Recorded because it bounds §3.4's claim |

Both lanes were re-run scoped to the fixes; see below.

### Verify-script progression (r3 final, 47 rows)

| State | `Result:` | Meaning |
|---|---|---|
| clean `origin/develop` `39eedd4` | `12 pass, 24 fail` | nothing done |
| TDD-gate state | `24 pass, 12 fail` | tests written, no production code (MEASURED, not derived) |
| **implemented** | **`47 pass, 0 fail`** | ✅ (Jest 96/96; full suite 370/370) |

**29/29 mutations caught** across r1–r3, every one applied and re-run rather than reasoned about. The four that matter most: `M16` (remove the row-clear) and
`M17` (remove the key) each reproduce the subject-boundary Medium; `M18` (remove the generation check)
and `M19` (move the bump below the early return) each reproduce the race. ⚠ **M19 initially ESCAPED** —
every test stayed green because none passed through the null-subject state; that gap is now closed by
`invalidatesAnInFlightReadWhenTheSubjectGoesAway`.

**Completion criterion — MET on `879693a`, 2026-08-13:**

```bash
cd .claude/worktrees/wms2-web-ui/SBDEV-2947
source ~/.nvm/nvm.sh          # no yarn on PATH; use the nvm node + local jest binary
node_modules/.bin/jest --coverage=false \
  --testPathPattern='(locationPicker|defaultPutawayLocationField|editSkuPutawayDialog)'   # 96/96 ✅
WEB_UI_ROOT=$PWD bash /home/nampark/dev/wms-claude/sbdocs/9-System/scripts/verify-SBDEV-2947-sku-putaway-picker-storage-tier-default.sh   # 47 pass, 0 fail ✅
```

Both contracts re-measured at PR time and met: targeted run **96 passed / 96**, script
**`Result: 47 pass, 0 fail, 0 skip`**. Neither may be weakened. ⚠ The verify script path must be
absolute — it lives in the vault, not in the worktree, and `WEB_UI_ROOT` must point at the worktree
or the script silently grades the main checkout.

**Remaining before archive:** PR #61 review, then the M1–M8 manual grid per §5.2 step 9.

⚠ **Manual testing must cover a non-wineco tenant.** §1.2e shows 3 of 4 UAT tenants have no defect and
this fix is a deliberate no-op there. M5 (tier 2/3) plus one SKU-scope pass on hydra or shipitez is the
only evidence that the change is inert where nothing was broken.
