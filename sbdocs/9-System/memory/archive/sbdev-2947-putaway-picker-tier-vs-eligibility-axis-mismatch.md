---
name: sbdev-2947-putaway-picker-tier-vs-eligibility-axis-mismatch
description: "SBDEV-2947 — the putaway picker's DEFAULT tier is empty at SKU scope BY CONSTRUCTION, and LocationConstraintService fails OPEN"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5648b9f8-6d4b-4383-bc62-815e0c926d5f
  modified: 2026-08-13T16:45:53.372Z
---

**SBDEV-2947 (v2/wms2-web-ui only, plan drafted + TDD-gated 2026-08-13, not yet implemented.)** The
Default Putaway Location picker offers only `tier === 'DEFAULT'` rows until "Show storage locations" is
enabled, and at SKU scope **zero** are eligible — so the dropdown is empty for every SKU.

**The mechanism, which is the reusable part.** The two tiers are drawn on one axis and filtered on
another:

- `tier` is set server-side from ONE column — `area.useforgoodsin ? DEFAULT : ADVANCED`
  (`PutawayDestinationQueryService:331`). It is a property of the **location**, identical at all scopes.
- `eligible` is **per scope**. Two of `PutawayDestinationRules.CHAIN`'s nine predicates run at SKU
  scope only — `stagingOrCrossdockAtSku` (P2.3) and `unitloadTypeCompatible` (P2.6, because
  `defaultUnitloadTypeId` is null at tiers 2/3) — and they reject exactly what a goods-in area
  contains: receiving lanes and pallet stations.

⚠⚠ **NOT FLEET-WIDE — 1 tenant of 4.** Full survey of every reachable v2 database, 2026-08-13,
reproducing `PutawayDestinationRules.CHAIN` in SQL. DEFAULT-tier eligible **at SKU scope**:

| DB | tenant / wh | goods-in candidates | eligible at SKU |
|---|---|---|---|
| `dev_wh01_om1` / `wh01_om1_v2` | **wineco** dev + uat | 12 | **0** ❌ |
| `wh01_hydra_v2` | hydra nywh (dev2 + uat) | 2 | **2** ✅ |
| `wh01_shipitez_v2` | shipitez c1wh uat | 2 | **2** ✅ |
| `wh02_shipitez_v2` | shipitez nywh uat | 2 | **2** ✅ |

**The whole difference is ONE `location_constraint` row.** `overstock pallet` permits unit-load types
`{5}` on wineco and `{4,5}` everywhere else; every tenant's SKUs are type 4 (Case). Wineco also has 10
`HubAndSpoke-*` `crossdockinglane` locations in its Inbound area that no other tenant has.

So the mechanism is scope-**dependent**, not scope-structural (an earlier version of this memory said
"structural" — wrong, generalised from one tenant). **The shipped fix is DATA-driven**: the picker
opens the storage tier only when zero eligible `DEFAULT`-tier rows exist, so wineco is fixed and the
other three are untouched. A scope-driven default would have changed behaviour on 3 tenants with no
defect.

⚠ **LANDMINE for anyone implementing an auto-open like this:** the rows arrive via a PAGINATED
accumulate, so a `mounted()` hook or an unguarded `immediate: true` watcher sees an EMPTY array — which
also has no goods-in option — and opens the tier on every tenant, visibly only under a slow read. Guard
on `rows.length > 0`.

**How to apply: never generalise a WMS tenant measurement from one database.** The landlord's
`tenant ⋈ tenant_db_configuration WHERE active` gives the roster; querying the other three took minutes
and overturned the plan's central claim and then its design.

⚠⚠ **LANDMINE — `LocationConstraintService.isUnitloadTypePermitted` FAILS OPEN.** A location type with
**no** `location_constraint` rows permits **every** unit-load type (`:61-63`, the guard is labelled
"THE FAIL-OPEN"). The ticket asserted the opposite — that constraint-less `HubAndSpoke-01…-10` "accept
nothing" — and proposed adding rows as a follow-up. Adding rows could only **narrow** them. Those ten
are ineligible at tier 1 because `crossdockinglane = true`, nothing to do with constraints.

⚠ **The ticket's "2,068 locations a Case SKU can use" is wrong; it is 1,206.** 2,068 is the *flowbin*
count, 1,345 of them FLA-bound. Both numbers sit in `repo/jpa/LocationRepository.java:313`. 1,206 is what PR
#56's own caption prints — the ticket contradicted the screen it described.

**How to apply:** when reasoning about this picker, never infer eligibility from tier or vice versa,
and re-measure any figure before quoting it — [[sbdev-2643-sku-default-putaway-location-ui]] carried
five figures on this exact subject and all five were wrong. Reproduce the rule chain in SQL and
cross-check against the counts the production source asserts in its own comments (2,738 candidates /
1,532 ineligible / 1,345 of 2,068 FLA-bound / 516 rows at tiers 2-3); if your SQL matches all four,
it is faithful.

Verify script `verify-SBDEV-2947-…sh` progression: **12/15 fail** on clean develop → **19/8** at the
TDD-gate state → **27/0** proven achievable on a synthetic conformant tree, 8/8 mutations caught.
Related: [[wms2-web-ui-develop-preexisting-suite-failures]],
[[sbdev-2821-tier1-putaway-candidate-surfacing]], [[verify-script-traps]].
