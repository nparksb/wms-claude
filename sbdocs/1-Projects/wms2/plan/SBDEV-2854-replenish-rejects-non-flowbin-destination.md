---
title: "WMSv2: Replenishment rejects operational destination location as 'not a flowbin'"
ticket: "SBDEV-2854"
ticket_url: "https://app.clickup.com/t/868kn5nnn"
type: "bugfix"
priority: "urgent"
status: "MERGED to develop 2026-08-07 — PR #132, merge commit 68274b0, implementation 9750a04. V2.2.10 is on develop; it still has to be APPLIED per tenant."
project: [wms2]
version: "v2"
requester: "Scott Dalton (client V2 testing, 2026-08-06)"
created: "2026-08-06"
updated: "2026-08-06"
db_verified: true
depends_on: []   # none blocking. SBDEV-2801 is referenced only as version history (it took V2.2.08,
                 # which pushed SBDEV-2732 to V2.2.10 and then this plan to V2.2.10) and is MERGED
                 # via origin/* refs. Recorded 2026-08-06 so the empty list reads as a decision.
depended_on_by:
  # REVERSE dependency — the direction that can wedge tenants, so it is recorded here too.
  - {ticket: SBDEV-2732, note: "this plan's V2.2.10 must merge AND apply BEFORE 2732's V2.2.13.
      Reverse order leaves V2.2.10 out-of-order: outOfOrder=false skips it, validateOnMigrate=true
      then fails every boot, and StartupFlywayMigrator swallows it. See 2732 §8.1 merge 0b."}
related:
  - "[[260424-club-location-replenish-fix]]"
  - "[[SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock]]"
  - "[[wms2-replenish-workflow]]"
  - "[[wms2-multi-unitload-replenish]]"
tags:
  - plan
---

# WMSv2: Replenishment rejects operational destination location as "not a flowbin"

**Ticket:** [SBDEV-2854](https://app.clickup.com/t/868kn5nnn)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** urgent
**Status:** implemented, pending PR & review
**Date:** 2026-08-06

> **Not a v2 regression.** V1 rejects `Club01` identically — see §1.3. This plan is a
> deliberate *behavior change* that lifts a pre-existing product limitation in v2, not a
> repair of something v2 broke. Framing matters for client communication: nothing was
> lost in migration.

> **Supersedes** `sbdocs/4-Archieves/wms2/plan/260424-club-location-replenish-fix.md`,
> which described the same symptom on 2026-04-24, was never implemented (no commit in
> either repo touches the gate — see §3), and whose recommended fix (Option A,
> location-type allowlist only) would **not** have fixed the reported case. See §1.4.

---

## 0. Affected sites (enumeration before drafting)

Root-cause pattern: **the replenishment destination path hard-codes the assumption that a
destination is a flowbin** — a single-SKU pick bin holding exactly one virtual
`PICKLOCATION` unit load, addressed through a `FixLocationAssignment` (FLA). Every
precondition on that path encodes that shape, so the type gate is only the first of
several blockers.

Enumeration method: `grep -rn "STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN" src/main/java/`
(20 hits), plus `grep -rn "not a flowbin"` (both repos), plus a read of the full
destination-assignment and finish paths.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1 | `service/mobile/MobileReplenishService.java:917` | `assignDestinationForMultiUnitLoads` — flowbin-only type gate | yes | **yes** — primary; this is the site the reported UI actually hits (§1.2) |
| 2 | `service/mobile/MobileReplenishService.java:920` | multi-UL — rejects destination that already holds any unit load | yes | **yes** — `Club01` holds 3 ULs, so relaxing #1 alone just moves the error here |
| 3 | `service/mobile/MobileReplenishService.java:923` | multi-UL — `createFixedLocationAssignment` binds destination to one SKU | yes | **yes** — must be skipped for shared locations |
| 4 | `service/mobile/MobileReplenishService.java:399` | `checkDestination` — flowbin-only type gate | yes | **yes** — single-UL / handheld path, same defect |
| 5 | `service/mobile/MobileReplenishService.java:403` | single-UL — rejects destination that already holds any unit load | yes | **yes** — same as #2 |
| 6 | `service/mobile/MobileReplenishService.java:407-411` | single-UL — **inverted** guard: throws `"Unit load already exists."` when `findByLabelid(code)` is *empty* | yes | **yes** — independent latent bug; blocks the flowbin path too (§2.3) |
| 7 | `service/mobile/MobileReplenishService.java:415` | single-UL — `createFixedLocationAssignment` | yes | **yes** — same as #3 |
| 8 | `service/mobile/MobileReplenishService.java:501-520` | `finishReplenishmentOrderInternal` — resolves the destination UL **from the FLA**, creating one at :510 if absent | yes | **yes** — without this the fix is defeated at finish time (§2.5) |
| 9 | `service/mobile/MobileReplenishService.java:390-392` | `checkDestination` rejects any SKU that already has an FLA anywhere, even when the scanned destination *is* that FLA's location; multi-UL variant at :908-911 correctly compares the location id | partly | **yes** — narrow consistency fix, aligns :390 with :908 |
| 10 | `service/mobile/MobileMoveStockService.java:267,290` | Move Stock destination flowbin gate | yes (same pattern) | no — different workflow with its own UX contract; flag as sibling ticket (§8) |
| 11 | `service/mobile/MobileMoveUnitloadService.java:303` | Move Unit Load destination flowbin gate | yes (same pattern) | no — as #10 |
| 12 | `service/FixLocationAssignmentService.java:120` | `move()` requires an FLA's new home to be a flowbin | no | no — legitimately flowbin-only: an FLA *is* the flowbin abstraction |
| 13 | `service/StockunitService.java:181,314,495` | flowbin-specific capacity / merge / upper-bound logic | no | no — correctly flowbin-scoped behavior, not a destination gate |
| 14 | `service/mobile/MobilePutAwayService.java:274,424,473` | putaway routing `switch` on location type | no | no — routes by type, never hard-rejects |
| 15 | `service/mobile/MobileTransferOrderService.java:289` | transfer destination type predicate | no | no — different workflow |
| 16 | `controller/FixLocationAssignmentController.java:50` | lists flowbins having no FLA | no | no — correct as-is |
| 17 | `controller/rest/UtilRestController.java:708` | test-data seeding | no | no — not a runtime path |

Rows 1-9 are in scope and each maps to a fix in §3 and a positive check in
`verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh`.

---

## 1. Problem Statement

### 1.1 Reported symptom

During client V2 testing (2026-08-06), an operator ran Replenishment in the desktop
build of Mobile UI and entered `Club01` as the destination. The workflow rejected it:

> **Destination is not a flowbin!**

Reported evidence:

| Field | Value |
|---|---|
| SKU | `ET21BRUTNT` — 2021 Brut Nature 750 ml |
| Shipper | Zerolink - Et Fille Wines (ZVEF) |
| Source location | `16-XC21` |
| Destination shown | `No fixed assignment` |
| Entered destination | `Club01` |
| Requested Qty | 1 |
| Moving Qty | 12 |

The client states these locations are used routinely for product moving both into and
out of the area — i.e. `Club01` is a legitimate operational destination.

### 1.2 Which code path actually fires

The screenshot is the **Select Destination Location** step of the multi-unit-load
replenishment flow. That screen
(`v2/wms2-mobile-ui/components/replenish/process/selectDestination.vue:128`) dispatches
`submitULBatchToDestination`, which posts to `/replenish/multi-unitloads`
(`store/replenish.js:312`) — **not** the legacy per-scan `checkDestination` endpoint,
whose call is commented out at `store/replenish.js:320-347`.

```
selectDestination.vue:128  submitULBatchToDestination
  → store/replenish.js:312  POST /v3/replenish/multi-unitloads
    → ReplenishController.java:229-230  multiUnitLoads(MultiReplenishRequestDto)
      → MobileReplenishService.assignDestinationForMultiUnitLoads()   :888
        → :917  flowbin type gate  ── THROWS "Destination is not a flowbin!"
```

So the site that produced the reported error is **`MobileReplenishService.java:917`**.
`checkDestination:399` carries the identical defect and is still reachable through
`GET /v3/replenish/checkDestination/{id}/{input}` (`ReplenishController.java:182`), so
both are in scope.

### 1.3 DB verification (Analysis protocol §8) — `db_verified: true`

Queried live tenant DBs via MCP. **`Club01` is type `cases and pallets`, not `flowbin`,
and is configured identically in V1 and V2 — same location id, same type.**

`mcp__wms2-wineco-dev__execute_sql`:

```sql
SELECT l.id, l.name, lt.sltname AS location_type, l.type_id, l.client_id,
       l.staginglane, l.gate, l.transferlane, l.automationlane, l.crossdockinglane
FROM location l LEFT JOIN location_type lt ON lt.id = l.type_id
WHERE l.name ILIKE 'club%' ORDER BY l.name;
```

| id | name | location_type | type_id | client_id | lane flags |
|---|---|---|---|---|---|
| 225748 | Club01 | **cases and pallets** | 51507 | 0 | all false |
| 225749 | Club02 | cases and pallets | 51507 | 0 | all false |
| … | … | … | … | … | … |
| 225797 | Club50 | cases and pallets | 51507 | 0 | all false |

50 rows, all `cases and pallets`, all in area 51553 / rack 225210, all `client_id = 0`
(shared, not client-scoped), and **no lane flags set** — so they are ordinary storage
locations, not staging/transfer/gate lanes.

`mcp__wms1-wineco-dev__execute_sql`, same query — **V1 returns the same ids and the same
type**:

| id | name | location_type |
|---|---|---|
| 225748 | Club01 | cases and pallets |
| … | … | … |

**Club locations already hold multiple unit loads**, which is the decisive fact for the
fix design:

```sql
SELECT u.id, u.labelid, u.storagelocation_id, l.name AS on_location, ut.name AS ul_type
FROM unitload u
LEFT JOIN location l ON l.id = u.storagelocation_id
LEFT JOIN unitload_type ut ON ut.id = u.type_id
WHERE l.name ILIKE 'club%' ORDER BY u.labelid;
```

`Club01` (225748) holds `UL169356`, `UL220736`, `UL258560` — all `ul_type = Case`.
`Club02` and `Club04` hold a dozen more each, including `Pallet`-type ULs
(`IN-000371`, `IN-000485`, `IN-000601`). Identical rows in the V1 DB.

Supporting facts:

- **No FLA exists on any club location**, in either version:
  `SELECT count(*) FROM fix_location_assignment f JOIN location l ON l.id = f.assignedlocation_id WHERE l.name ILIKE 'club%';`
  → `0` in both `wms2-wineco-dev` and `wms1-wineco-dev`.
- Type distribution in the V2 tenant: `flowbin` 2068 locations, `cases and pallets` 510,
  `NoRestriction` 122, `overstock pallet` 13, `overstock box` 3, `totes` 2, `packages` 1,
  `System` 20. **`cases and pallets` covers 510 locations, not just the 50 club ones** —
  a blanket type-wide allow is a wider blast radius than the ticket asks for. Addressed
  in §3.1 and §8b Risk R2.

#### Confirmed on the tested tenant and on V1 production (2026-08-06)

The two DBs above are dev copies. Both `wsl-wineco-uat` (the environment the client tested)
and `wms1-wineco` (**V1 production** — the system they run today) were unreachable during
drafting and have since been queried. **Four independent databases agree**, and the
production numbers are far more emphatic than dev:

| DB | Role | `Club01` type | FLAs | Unit loads on `Club01` |
|---|---|---|---|---|
| `wsl-wineco-uat` | **V2, the tested environment** | `cases and pallets` | 0 | **114** |
| `wms1-wineco` | **V1 production** | `cases and pallets` | 0 | **109** |
| `wms2-wineco-dev` | V2 dev | `cases and pallets` | 0 | 3 |
| `wms1-wineco-dev` | V1 dev | `cases and pallets` | 0 | 3 |

Same location id (225748) and same type in every one. The dev copies are simply stale; the
live warehouses carry ~110 unit loads on that single location.

**V1 production having 109 unit loads on `Club01` settles the regression question.**
Operators are actively using it as a bulk multi-UL location in V1 *today*, with no fixed
assignment — and have never been able to replenish into it there either. Nothing was lost in
migration.

The rest of the reported scenario also checks out on UAT:

- `ET21BRUTNT` → itemdata id 33394696, client `Zerolink - Et Fille Wines` (33353190),
  **`fla_count = 0`** — exactly matching the screenshot's `Destination: No fixed assignment`,
  which is what puts control into the `!fixedLocationAssignmentOpt.isPresent()` branch.
  `defultype_id = 4` (Case) — the type Fix D would give a newly created destination unit load.
- Source `16-XC21` → id 64312, also `cases and pallets`, no lane flags. (Note the source is a
  non-flowbin location too; sourcing has never required flowbin.)
- Neither `Club01` nor `16-XC21` sets any of the five lane flags, so both clear
  `isNonStorageLane` (§3.1).

**§10 O1 is closed.** No pre-implementation DB check remains outstanding; the rollout
`sysvalue` is confirmed as `cases and pallets`.

#### One more thing the UAT data exposes

`Club03`, `Club05`–`Club09` hold **0** unit loads while `Club01`/`Club02`/`Club04` hold
114/99/91. That mix makes the archived plan's Option A worse than uniformly broken rather
than merely insufficient: widening only the type gate would let an **empty** club location
through `:920`, then hit `:923` and **create a `FixLocationAssignment`** — silently
converting a shared club location into a single-SKU pick bin and enrolling it in automatic
replenishment. The operator-visible result would depend on whether the bin happened to be
empty that day: a hard error on `Club01`, and quiet data corruption on `Club03`. This is the
strongest argument for the FLA-free path in §3 over any gate-only change.

### 1.4 Why the archived 2026-04-24 plan does not solve this

`260424-club-location-replenish-fix.md` correctly guessed the type mismatch but was
written without DB access ("Pre-Implementation Verification Needed" §1) and recommended
Option A: widen the type gate to accept `cases and pallets`. Applied alone, that is
**insufficient** — `Club01` holds 3 unit loads, so control falls straight through to the
next guard:

```java
// MobileReplenishService.java:920 (multi-UL) / :403 (single-UL)
if (!unitloadRepository.findByStoragelocationId(storageLocation.getId()).isEmpty()) {
    throw new BusinessException("Destination has already a unit load!");
}
```

The operator's error message would change from "not a flowbin" to "already has a unit
load" and the move would still be blocked. The archived plan also missed sites #6 and #8
in §0 entirely. It is superseded, not extended.

### 1.5 Requested Qty 1 vs Moving Qty 12 — not a defect

Per the ticket's acceptance criteria. Traced through the UI:

```
selectDestination.vue:7   :requested-qty="$store.state.replenish.realAmountNeeded"   → 1
selectDestination.vue:8   :moving-qty="pickedAmount"                                 → 12
selectDestination.vue:86  pickedAmount = selectedULBatch.reduce((s,i) => s + i.qtySelected, 0)
```

`Requested Qty` is the replenishment order's outstanding need (1 unit). `Moving Qty` is
the sum the operator actually staged by selecting unit loads (one case of 12). Moving a
whole 12-unit case to satisfy a 1-unit need is normal replenishment behavior — the tile
even renders a thumbs-up when `moving > 0` (`QtySummaryRow.vue:38`).

**Verdict: expected behavior, no code change.** The labels are legitimately confusing
though, so §8 proposes a separate UX ticket rather than folding a UI change into this
fix. Per the pre-draft decision in §10 Q3, this closes that acceptance-criteria row
without expanding scope.

---

## 2. Root Cause Analysis

### 2.1 The flowbin assumption

Replenishment was built for one job: top up a **flowbin** pick location from overstock. A
flowbin in this data model is:

- `location_type.sltname = 'flowbin'`
- bound to exactly one SKU through a `FixLocationAssignment`
- holding exactly one **virtual** unit load of type `PICKLOCATION`, created by
  `FixLocationAssignmentService.createFixedLocationAssignment` at line 90 and named after
  the location itself

Stock is never moved "to a location" in this design — it is moved to the FLA's virtual
unit load (`finishReplenishmentOrderInternal:517-520`).

A club location breaks every one of those assumptions. It is `cases and pallets`, shared
across SKUs (`client_id = 0`), and holds several real `Case`/`Pallet` unit loads at once
(§1.3). So the destination path rejects it — correctly, given its own assumptions, but
those assumptions are narrower than warehouse operations now require.

### 2.2 Bug 1 — flowbin-only type gate (sites #1, #4)

`MobileReplenishService.java:915-919`, the multi-UL path actually hit:

```java
Optional<FixLocationAssignment> fixedLocationAssignmentOpt =
        fixLocationAssignmentRepository.findByAssignedlocationId(storageLocation.getId());
if (!fixedLocationAssignmentOpt.isPresent()) {
    LocationType locationType = locationTypeRepository.findById(storageLocation.getTypeId())
            .orElseThrow(() -> new EntityNotFoundException("LocationType", storageLocation.getTypeId()));
    if (!locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)) {
        throw new BusinessException("Destination is not a flowbin!");   // ← :917
    }
```

`checkDestination:396-401` is the same code. Two problems:

1. **Wrong question.** It tests a literal type name rather than whether the location can
   accept this inventory movement. `Club01` has no lane flags, is active, and already
   stores cases — it is operationally valid.
2. **Leaks an internal concept.** "flowbin" is an implementation term. The message names
   neither the actual requirement nor any corrective action, which is exactly what the
   ticket calls out.

### 2.3 Bug 2 — inverted unit-load guard (site #6)

`checkDestination:403-411`:

```java
if (!unitloadRepository.findByStoragelocationId(storageLocation.getId()).isEmpty()) {
    throw new BusinessException("Destination has already a unit load!");     // :403-405
}

Optional<Unitload> fixedUnitLoadOpt = unitloadRepository.findByLabelid(code);

if (!fixedUnitLoadOpt.isPresent()) {
    throw new BusinessException("Unit load already exists.");                // :409-411  ← INVERTED
}
```

The condition and the message contradict each other: it throws *"Unit load already
exists"* precisely when the unit load **does not** exist. And the intent is backwards
either way — the very next statement (`createFixedLocationAssignment`, :415) *creates* a
unit load labelled `storageLocation.getName()` (`FixLocationAssignmentService.java:90`),
so the correct precondition is that no such label exists yet.

Consequence today: scanning an empty, correctly-typed **flowbin** with no UL named after
it passes :403 and then throws `"Unit load already exists."` at :409 — a spurious hard
block on the intended happy path. This is a live latent bug independent of SBDEV-2854.

The multi-UL twin (`assignDestinationForMultiUnitLoads:915-923`) has no such check,
confirming it is spurious rather than load-bearing.

**v1 carries the identical block** at `MobileReplenishService.java:352-356`.

### 2.4 Bug 3 — FLA auto-creation on a shared location (sites #3, #7)

Both paths call `fixLocationAssignmentService.createFixedLocationAssignment(storageLocation, itemData)`
(:923 multi-UL, :415 single-UL). On a shared club location that is actively harmful: it
would permanently bind `Club01` to `ET21BRUTNT`, add a virtual `PICKLOCATION` unit load
named `Club01` alongside the three real case ULs already there, and enrol the location in
automatic replenishment top-up via `triggerReplenishmentMaintenance`
(`FixLocationAssignmentService.java:104`). None of that is wanted for a club location.

### 2.5 Bug 4 — the finish path re-creates the FLA (site #8)

This is why relaxing validation alone is not enough.
`finishReplenishmentOrderInternal:501-520`:

```java
Optional<FixLocationAssignment> fixedLocationAssignmentOpt =
        fixLocationAssignmentRepository.findByAssignedlocationId(destinationLocation.getId());
FixLocationAssignment fixLocationAssignment = fixedLocationAssignmentOpt.orElse(null);

if (fixLocationAssignment == null) {
    Itemdata itemData = itemdataService.getById(sourceStock.getItemdataId());
    fixLocationAssignment = fixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, itemData);  // :510
}
…
final Long fixLocAssignedUnitloadId = fixLocationAssignment.getAssignedunitloadId();
Unitload assignedUnitLoad = unitloadRepository.findById(fixLocAssignedUnitloadId)…;      // :517-518
stockunitBusinessService.transferStockToUnitLoad(sourceStock, assignedUnitLoad, amountPicked, …);  // :519
```

The destination unit load is derived **exclusively** from the FLA. If §3.2/§3.3 let a
non-flowbin destination through without creating an FLA, this method creates one anyway
at :510 — reintroducing Bug 3 one step later, at commit time, where it is far harder to
diagnose. Any fix that stops at the validation gates is incomplete.

### 2.6 v1 / v2 comparison (ticket requirement)

| Aspect | v1/wms-api | v2/wms2-api | Verdict |
|---|---|---|---|
| Type gate, multi-UL | `MobileReplenishService.java:851` | `:917` | identical |
| Type gate, single-UL | `:360` | `:399` | identical |
| Inverted UL guard | `:352-356` | `:407-411` | identical |
| FLA auto-create on destination | `:356` (approx.) | `:415`, `:923` | identical |
| Finish path derives dest UL from FLA | same shape | `:501-520` | identical |
| `Club01` location type | `cases and pallets` (id 225748) | `cases and pallets` (id 225748) | identical |
| FLA on club locations | 0 | 0 | identical |
| Unit loads on `Club01` | 3 (`UL169356`, `UL220736`, `UL258560`) | same 3 | identical |

**Conclusion: V1 rejects `Club01` exactly as V2 does.** This is not a v2 regression, not a
migration data gap, and not a missing fixed assignment. It is a pre-existing product
limitation present since the replenishment feature was written. Acceptance-criteria row
"Equivalent V1 behavior is documented" is satisfied by this table — no V1 click-test is
required, because the code and the data are provably the same on both sides.

### 2.7 Regression archaeology — the fix was planned and dropped

| Date | Artifact | Outcome |
|---|---|---|
| 2026-04-24 | `260424-club-location-replenish-fix.md` written (v2 plan dir) | Documented the symptom for `UL174497` → `Club01`; recommended Option A; listed 4 open verification questions |
| unknown | plan moved to `4-Archieves/wms2/plan/` | Archived with its verification questions still unanswered |
| — | code | **No commit in either repo ever changed the gate.** `git log --all --grep=flowbin -i` returns only report-formatting and unrelated work (`17c058fa`, `7a42c9e9`, `82669934`, `a29738a1`); `git log` on `MobileReplenishService.java` shows no destination-validation change |

So the same defect was reported, analysed, shelved, and has now resurfaced with the same
location four months later. §8 records the process lesson.

---

## 3. Design / Proposed Fix

**Chosen shape** (pre-draft decision §10 Q1): add a dedicated **FLA-free destination
path** for locations that are valid but not flowbins. Flowbin behavior is untouched;
non-flowbin destinations get accepted without an FLA, without an empty-location
requirement, and stock lands on a real unit load standing on that location.

**Guiding constraints**

- Default behavior must not change for any tenant that does not opt in (R1).
- Do not widen `cases and pallets` silently to all 510 locations without an operator
  decision (R2).
- Reuse the existing `SyspropService` pattern already in this class (`:766`, `:771`).
- v2 rules: constructor injection only; `@Transactional(value = "tenantTransactionManager", …)`;
  SLF4J parameterized logging; `orElseThrow` over `.get()`.

### 3.1 Fix A — configurable allowed destination types

**Problem:** the gate hard-codes one literal type.

**Solution:** a sysprop-driven allowlist, defaulting to flowbin only so nothing changes
until an operator opts in.

`WmsConstants.java` — new pair beside the existing replenishment keys:

```java
public static final String SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_KEY
        = "REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS";
public static final String SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_DEFAULT_VALUE
        = STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN;   // "flowbin" — behavior-preserving default
```

New private helper on `MobileReplenishService`:

> **⚠ SUPERSEDED — as-shipped code differs. Added 2026-08-07 after PR #132 merged.**
> The CSV type allow-list below (`isAllowedReplenishDestinationType`, sysprop
> `REPLENISH_ALLOWED_DESTINATION_LOCATION_TYPES`, default `"flowbin"`) was **replaced by decision O4**
> with a plain boolean, and that is what merged: `isNonFlowbinDestinationAllowed()`
> (`MobileReplenishService.java:853-860`) reading `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS`, default
> `"false"` (`WmsConstants.java:1128-1129`), with eligibility gated on `location_area.useforpicking`
> rather than on location type at all. **Read §O4 (:1123-1156) as the design; the block below is the
> superseded first answer, retained for the evidence trail.**

```java
/**
 * SBDEV-2854: a replenishment destination no longer has to be a flowbin. Types listed in
 * REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS (CSV) are accepted as FLA-free destinations.
 * An absent / blank sysprop yields flowbin-only — the pre-SBDEV-2854 behavior.
 */
private boolean isAllowedReplenishDestinationType(LocationType locationType) {
    String configured = syspropService.getSysvalue(
            WmsConstants.SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_KEY);
    if (configured == null || configured.trim().isEmpty()) {
        configured = WmsConstants.SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_DEFAULT_VALUE;
    }
    for (String allowed : configured.split(",")) {
        if (allowed.trim().equalsIgnoreCase(locationType.getSltname())) {
            return true;
        }
    }
    return false;
}
```

Plus a safety predicate — an allowed *type* must still not be a non-storage lane:

```java
/**
 * SBDEV-2854: lane-ish locations are transit points, never replenishment destinations,
 * regardless of their location type. Mirrors the SBDEV-1666 source-side exclusion.
 */
private boolean isNonStorageLane(Location location) {
    return Boolean.TRUE.equals(location.getStaginglane())
        || Boolean.TRUE.equals(location.getGate())
        || Boolean.TRUE.equals(location.getTransferlane())
        || Boolean.TRUE.equals(location.getAutomationlane())
        || Boolean.TRUE.equals(location.getCrossdockinglane());
}
```

All five flags are `false` for every club location (§1.3), so this blocks nothing the
ticket needs while keeping the guardrail the archived plan's Option C would have removed.

**Files changed:** `WmsConstants.java`, `MobileReplenishService.java`

### 3.2 Fix B — branch the multi-UL destination path (sites #1, #2, #3)

**Problem:** `assignDestinationForMultiUnitLoads:915-923` applies flowbin preconditions to
every destination.

**Before** (`MobileReplenishService.java:913-927`):

```java
Optional<FixLocationAssignment> fixedLocationAssignmentOpt =
        fixLocationAssignmentRepository.findByAssignedlocationId(storageLocation.getId());
if (!fixedLocationAssignmentOpt.isPresent()) {
    LocationType locationType = locationTypeRepository.findById(storageLocation.getTypeId()).orElseThrow(() -> new EntityNotFoundException("LocationType", storageLocation.getTypeId()));
    if (!locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)) {
        throw new BusinessException("Destination is not a flowbin!");
    }
    if (!unitloadRepository.findByStoragelocationId(storageLocation.getId()).isEmpty()) {
        throw new BusinessException("Destination has already a unit load!");
    }
    fixLocationAssignmentService.createFixedLocationAssignment(storageLocation, itemData);
} else if (!itemdataService.getById(fixedLocationAssignmentOpt.get().getItemdataId())
        .equals(itemData)) {
    throw new BusinessException(storageLocation.getName() + " has different fixed assignment");
}
```

**After:**

```java
Optional<FixLocationAssignment> fixedLocationAssignmentOpt =
        fixLocationAssignmentRepository.findByAssignedlocationId(storageLocation.getId());
if (!fixedLocationAssignmentOpt.isPresent()) {
    LocationType locationType = locationTypeRepository.findById(storageLocation.getTypeId())
            .orElseThrow(() -> new EntityNotFoundException("LocationType", storageLocation.getTypeId()));

    if (WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(locationType.getSltname())) {
        // Flowbin destination — unchanged: must be empty, gets an FLA + virtual pick UL.
        if (!unitloadRepository.findByStoragelocationId(storageLocation.getId()).isEmpty()) {
            throw new BusinessException("Destination has already a unit load!");
        }
        fixLocationAssignmentService.createFixedLocationAssignment(storageLocation, itemData);
    } else if (isAllowedReplenishDestinationType(locationType) && !isNonStorageLane(storageLocation)) {
        // SBDEV-2854: FLA-free destination (e.g. club locations, type 'cases and pallets').
        // Shared across SKUs and holding many real unit loads, so NO empty-location check and
        // deliberately NO createFixedLocationAssignment — the destination unit load is resolved
        // at finish time by resolveNonFlowbinDestinationUnitload (Fix D).
        LOG.debug("accepting FLA-free replenish destination location={} type={}",
                storageLocation.getName(), locationType.getSltname());
    } else {
        throw new BusinessException(storageLocation.getName() + " (type '" + locationType.getSltname()
                + "') is not a valid replenishment destination. Allowed types: "
                + effectiveAllowedDestinationTypes()
                + ". Ask an administrator to add this type to "
                + WmsConstants.SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_KEY
                + ", or use Move Stock instead.");
    }
} else if (!itemdataService.getById(fixedLocationAssignmentOpt.get().getItemdataId())
        .equals(itemData)) {
    throw new BusinessException(storageLocation.getName() + " has different fixed assignment");
}
```

`effectiveAllowedDestinationTypes()` is a trivial accessor returning the resolved CSV, so
the message names the real requirement **and** the corrective action — the ticket's
acceptance criterion on error messaging.

**Why this and not alternatives:**

- *Widen the type gate only* (archived Option A) — proven insufficient in §1.4.
- *Drop the type check entirely* (archived Option C) — removes the guardrail for
  overstock-pallet and totes locations with no operator control. Rejected.
- *Give club locations `location_type = 'flowbin'` in data* — would make them single-SKU
  FLA-managed pick bins and break club picking and the flowbin monitor report. Rejected.

**Files changed:** `MobileReplenishService.java`

### 3.3 Fix C — branch the single-UL path and delete the inverted guard (sites #4, #5, #6, #7)

**Problem:** `checkDestination:396-418` has the same flowbin preconditions plus the
inverted guard of §2.3.

**After** (`MobileReplenishService.java:396-418`) — same three-way branch as Fix B, and the
`findByLabelid` block deleted outright:

```java
if (!fixedLocationAssignmentOpt.isPresent()) {
    LocationType locationType = locationTypeRepository.findById(storageLocation.getTypeId())
            .orElseThrow(() -> new EntityNotFoundException("LocationType", storageLocation.getTypeId()));

    if (WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(locationType.getSltname())) {
        if (!unitloadRepository.findByStoragelocationId(storageLocation.getId()).isEmpty()) {
            throw new BusinessException("Destination has already a unit load!");
        }
        // SBDEV-2854: the former guard here threw "Unit load already exists." when
        // findByLabelid(code) was EMPTY — inverted condition and inverted message, and it
        // blocked the intended flowbin happy path (a clean flowbin has no UL named after it
        // until createFixedLocationAssignment makes one). Removed; :403 above already
        // establishes the location is empty. The multi-UL twin never had this check.
        LOG.debug("for scanned code={} set flowbin location={} to fixed type={}",
                code, storageLocation, itemData.getItemNr());
        fixLocationAssignmentService.createFixedLocationAssignment(storageLocation, itemData);
    } else if (isAllowedReplenishDestinationType(locationType) && !isNonStorageLane(storageLocation)) {
        LOG.debug("accepting FLA-free replenish destination location={} type={}",
                storageLocation.getName(), locationType.getSltname());
    } else {
        throw new BusinessException(/* same actionable message as Fix B */);
    }
} else if (…) { … }
```

**Files changed:** `MobileReplenishService.java`

### 3.4 Fix D — resolve a real destination unit load at finish time (site #8)

**Problem:** `finishReplenishmentOrderInternal:501-520` derives the destination UL from the
FLA and creates an FLA when none exists — defeating Fixes B and C at commit time (§2.5).

**Solution:** keep the FLA route for flowbins; for an allowed non-flowbin destination,
resolve a real unit load standing on that location.

New helper:

```java
/**
 * SBDEV-2854: destination unit load for an FLA-free (non-flowbin) replenishment destination.
 * Prefers an existing unit load on the location that already carries this SKU so stock merges
 * instead of fragmenting; otherwise creates a new unit load of the item's default type on the
 * location. Never creates a FixLocationAssignment — these locations stay shared and multi-SKU.
 */
private Unitload resolveNonFlowbinDestinationUnitload(Location destinationLocation, Itemdata itemData)
        throws BusinessException {
    List<Unitload> onLocation = unitloadRepository.findByStoragelocationId(destinationLocation.getId());
    for (Unitload candidate : onLocation) {
        for (Stockunit stock : stockunitRepository.findByUnitloadId(candidate.getId())) {
            if (stock.getItemdataId().equals(itemData.getId())) {
                LOG.debug("merging replenishment into existing destination unitload={} on location={}",
                        candidate.getLabelid(), destinationLocation.getName());
                return candidate;
            }
        }
    }
    UnitloadType unitLoadType = unitloadTypeRepository.findById(itemData.getDefultypeId())
            .orElseGet(() -> unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_BOX)
                    .orElseThrow(() -> new EntityNotFoundException(
                            "UnitloadType not found by name: " + WmsConstants.UNIT_LOAD_TYPE_BOX)));
    LOG.debug("creating new destination unitload on location={} type={}",
            destinationLocation.getName(), unitLoadType.getName());
    // O2 resolved: the 4-arg overload (UnitloadService.java:123) takes the Location directly
    // and generates the label itself — no caller-invented label format. It declares
    // `throws BusinessException`, hence the signature above.
    return unitloadService.createUnitload(destinationLocation, unitLoadType.getId(),
            itemData.getClientId(), WmsConstants.CODE_REPLENISHMENT);
}
```

Call-site change at `:501-518`:

```java
LocationType destinationType = locationTypeRepository.findById(destinationLocation.getTypeId())
        .orElseThrow(() -> new EntityNotFoundException("LocationType", destinationLocation.getTypeId()));
Itemdata destinationItemData = itemdataService.getById(sourceStock.getItemdataId());

Unitload assignedUnitLoad;
Optional<FixLocationAssignment> fixedLocationAssignmentOpt =
        fixLocationAssignmentRepository.findByAssignedlocationId(destinationLocation.getId());

if (fixedLocationAssignmentOpt.isPresent()) {
    final Long ulId = fixedLocationAssignmentOpt.get().getAssignedunitloadId();
    assignedUnitLoad = unitloadRepository.findById(ulId)
            .orElseThrow(() -> new EntityNotFoundException("UnitLoad", ulId));
} else if (WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(destinationType.getSltname())) {
    // Flowbin with no FLA yet — unchanged: create the FLA and use its virtual pick unit load.
    FixLocationAssignment created =
            fixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, destinationItemData);
    final Long ulId = created.getAssignedunitloadId();
    assignedUnitLoad = unitloadRepository.findById(ulId)
            .orElseThrow(() -> new EntityNotFoundException("UnitLoad", ulId));
} else {
    // SBDEV-2854: FLA-free destination — resolve/create a real unit load on the location.
    assignedUnitLoad = resolveNonFlowbinDestinationUnitload(destinationLocation, destinationItemData);
}
```

The downstream `transferStockToUnitLoad` call, the SBDEV-1714 audit snapshot
(`:525-528`), and the `triggerRefill` block (`:533-539`) are unchanged — they only need
`assignedUnitLoad`, which is now correct for both destination shapes.

**New constructor dependencies** (v2 requires constructor injection):
`UnitloadService unitloadService`, `UnitloadTypeRepository unitloadTypeRepository`.

**Overload choice (O2, resolved).** `UnitloadService` exposes six `createUnitload`
overloads (`:123`, `:127`, `:132`, `:136`, `:163`, `:168`). The `String name`-first forms
(`:132`, `:136`, `:168`) require the caller to invent a label — that is how a flowbin's
virtual UL gets named after its location (`FixLocationAssignmentService.java:90`), which is
exactly what we must *not* do here. Use the **4-arg** form:

```java
public Unitload createUnitload(Location location, Long unitLoadTypeId, Long clientId,
                               String activityCode) throws BusinessException   // :123
```

It takes the destination `Location` directly and generates the label itself. No new
overload is needed. Because it declares `throws BusinessException`, the new helper must
too, and `finishReplenishmentOrderInternal` already declares
`throws FacadeException, BusinessException` — so no signature change propagates upward.

**Files changed:** `MobileReplenishService.java`

### 3.5 Fix E — align the item-side FLA guard (site #9)

**Problem:** `checkDestination:390-392` rejects any SKU that already has an FLA anywhere:

```java
if (currentItemDataOpt.isPresent()) {
    throw new BusinessException(code + " is wrong location!");
}
```

The multi-UL twin at `:908-911` is correct — it only rejects when the existing FLA points
somewhere *else*:

```java
if (currentItemDataOpt.isPresent()
        && !currentItemDataOpt.get().getAssignedlocationId().equals(storageLocation.getId())) {
    throw new BusinessException(storageLocation.getName() + " is wrong location!");
}
```

**Solution:** adopt the `:908` form at `:390`, so re-scanning a SKU's own fixed location no
longer fails. Narrow, low-risk, and it keeps the two paths from diverging further.

**Files changed:** `MobileReplenishService.java`

### 3.6 Fix F — seed the sysprop

New migration `src/main/resources/db/migration/V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop.sql`,
following `V2.2.04` exactly (sequence-drawn id, idempotent `WHERE NOT EXISTS`):

```sql
-- SBDEV-2854: REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS — CSV of location_type.sltname
-- values accepted as replenishment destinations. Ships as 'flowbin' only, which reproduces
-- the pre-SBDEV-2854 behavior exactly; per-tenant opt-in (e.g. 'flowbin,cases and pallets'
-- for club locations) is a separate operator step, NOT this file.
INSERT INTO public.los_sysprop
    (id, version, entity_lock, hidden, syskey, sysvalue,
     workstation, client_id, groupname, description, created, modified)
SELECT
    nextval('public.seqentities'), 0, 0, false,
    'REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS', 'flowbin',
    'DEFAULT', 0, 'Operation Options',
    'SBDEV-2854: comma-separated location types accepted as replenishment destinations. Types other than flowbin are accepted WITHOUT creating a fixed location assignment, so shared multi-SKU locations (e.g. club locations, type ''cases and pallets'') can receive replenishment. Default ''flowbin'' preserves pre-SBDEV-2854 behavior.',
    now(), now()
WHERE NOT EXISTS (
    SELECT 1 FROM public.los_sysprop
    WHERE syskey = 'REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS'
);
```

**Files changed:** new Flyway migration

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| Flowbin-only type gate | `MobileReplenishService.java:360`, `:851` | `:399`, `:917` | Same defect; v2 fixed here |
| Inverted UL guard | `:352-356` | `:407-411` | Same defect; v2 fixed here |
| FLA auto-create on destination | present | `:415`, `:923` | Same; v2 fixed here |
| Finish derives dest UL from FLA | present | `:501-520` | Same; v2 fixed here |
| Item-side FLA guard asymmetry | present | `:390` vs `:908` | Same; v2 fixed here |
| `Club01` config | `cases and pallets` | `cases and pallets` | Identical — no data fix needed either side |
| Sysprop mechanism | `los_sysprop` + `SyspropService` | same | Port is mechanical |

### What needs porting

Per pre-draft decision §10 Q2: **v2 only in this plan; the v1 sibling is flagged, not
dropped.** All five fixes port mechanically to v1 (same method names, same line
neighbourhoods) with these v1-specific adjustments:

1. `@Transactional` in v1 takes no `value = "tenantTransactionManager"`.
2. v1 uses string-concatenation logging (`LOG.debug("x=" + v)`), not SLF4J placeholders.
3. Mockito 3.3.3 — no `mockStatic()`; the new helpers are instance methods, so this is a
   non-issue for the planned tests.
4. v1 has no `ItemdataService`; use `itemdataRepository.findById(...).orElseThrow(...)`.

Open the v1 sibling as its own SBDEV ticket with the **same base filename** in
`sbdocs/1-Projects/wms1/plan/` once this plan is approved. Do not implement both from one
TDD-gate run — tests land in two repos.

### What does NOT need porting

- Nothing in the mobile UI: `Requested Qty` / `Moving Qty` is expected behavior (§1.5),
  and the destination screen needs no change for the fix itself.
- No data migration in either version: `Club01`'s configuration is already correct for the
  new code path.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Migration head on disk is `V2.2.09__seed_return_advice_auto_receive_sysprop.sql`. **This plan claims `V2.2.10`, keeping the sequence contiguous** — see the version note below for why the earlier `V2.2.11`-with-a-gap answer was unsafe. Re-check for new claims before committing | Dev | `ls src/main/resources/db/migration/`; `grep -rn "V2\.2\.1[0-9]" sbdocs/1-Projects/ sbdocs/4-Archieves/` |
| 2 | **Feature flags / system properties** | `los_sysprop.syskey = 'REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS'` seeded by `V2.2.10` with **`sysvalue = 'false'`** (a plain boolean — **not** the CSV type list this row previously described; O4 superseded that and the as-shipped code agrees). **For the wineco UAT/prod opt-in set `sysvalue = 'true'`.** | Dev + Ops | Absent row also yields flowbin-only (`SYSTEM_PROPERTY_..._DEFAULT_VALUE = "false"`, `WmsConstants.java:1129`) — the row exists to be visible in the config UI |
| 3 | **Config / env changes** | N/A — no `application.properties`, Jasypt, or Keycloak change | — | Pure service-layer + sysprop change |
| 4 | **Deploy-order dependencies** | None. API-only; no mobile-UI or OMS coordination required | — | Error-message text changes are display-only; UI renders `errors[0].message` verbatim (`store/replenish.js:315`) |
| 5 | **Data migration** | N/A — `Club01`'s existing config is already valid for the new path; no backfill | — | Confirmed §1.3 |
| 6 | **External systems** | N/A — no OMS, printer, or webhook interaction on this path | — | |
| 7 | **Access / permissions** | None new. Existing replenishment authority unchanged | — | |
| 8 | **Monitoring / alerts** | Confirm the new `LOG.debug` lines are visible at the tenant's log level during UAT; no new metric | Dev | Optional counter deferred — see §7 row 1 |

**Flyway version — this plan takes `V2.2.10`. History, because the first answer was wrong.**

> This paragraph was briefly self-contradictory ("why `V2.2.10` and not `V2.2.10`") after a blanket
> `V2.2.11 → V2.2.10` replace also rewrote the references that pointed at *SBDEV-2732's* claim.
> Restored, because it is the written record for a decision that can wedge tenant migrations.

1. **The claim.** `V2.2.10` was reserved by **SBDEV-2732**
   (`V2.2.10__putaway_destination_hierarchy.sql` — its §0 row N12 and decision D16, itself a
   renumber away from `V2.2.08` after SBDEV-2801 took that). Neither plan is merged, so the number
   was claimed-but-unwritten: `ls db/migration/` showed `V2.2.10` free, and only a grep of the plan
   vault surfaced the claim.
2. **First answer — wrong.** This plan originally took `V2.2.11` and left the gap, reasoning that
   "Flyway requires versions to be unique and ascending, not contiguous, so a gap is harmless."
3. **Why that was wrong (review H3).** There is no `outOfOrder(true)` and no
   `validateOnMigrate(false)` anywhere in the codebase, so Flyway's defaults apply
   (`outOfOrder=false`, `validateOnMigrate=true`) — a gap is **not** harmless. Worse,
   `StartupFlywayMigrator.java:140-152` catches `FlywayException`, logs
   *"migration failed — this tenant's schema may be stale"*, and **continues**. A tenant that
   applied `V2.2.11` before SBDEV-2732 landed `V2.2.10` would boot normally and **silently stop
   receiving that migration and every later `V2.2.x`**, indefinitely, until a human read the log or
   ran `flyway repair`.
4. **Resolution.** This plan takes `V2.2.10`, keeping the sequence contiguous, because it is an
   urgent client fix and deploys first. **SBDEV-2732 must take the next free version at PR time**; a
   `> [!warning]` block recording that is in its plan at
   `SBDEV-2732-configurable-default-putaway-location-hierarchy.md:62-71`.

Verify check `F6` asserts exactly one `V2.2.10__*` file exists, catching the mirror-image mistake of
two branches both writing this number. Re-run
`grep -rn "V2\.2\.1[0-9]" sbdocs/1-Projects/ sbdocs/4-Archieves/` immediately before merge — that
grep is what surfaced the collision in the first place.

**No outstanding pre-check.** The UAT and V1-production confirmation this section originally
demanded is done — see §1.3. `Club01` is `cases and pallets` on all four databases including
the tested tenant, so the rollout `sysvalue` is settled and implementation is unblocked.

### 5.2 Implementation Checklist

Each step is independently committable.

- [ ] **Step 1** — `WmsConstants.java`: add the `..._KEY` / `..._VALUE` pair (Fix A).
- [ ] **Step 2** — `MobileReplenishService.java`: add `isAllowedReplenishDestinationType`,
      `isNonStorageLane`, `effectiveAllowedDestinationTypes` (Fix A). No call-sites yet.
- [ ] **Step 3** — Fix B: three-way branch in `assignDestinationForMultiUnitLoads`
      (:915-923). **Primary reported defect.**
- [ ] **Step 4** — Fix C: three-way branch in `checkDestination` (:396-418) **and delete
      the inverted `findByLabelid` guard** (:407-411).
- [ ] **Step 5** — Fix E: align `:390` with the `:908` form.
- [ ] **Step 6** — Fix D: add `UnitloadService` + `UnitloadTypeRepository` constructor
      deps, add `resolveNonFlowbinDestinationUnitload`, rework
      `finishReplenishmentOrderInternal:501-518`. Confirm the `createUnitload` overload
      first (§3.4).
- [ ] **Step 7** — Fix F: `V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop.sql`.
- [ ] **Step 8** — Unit tests per §6, including the regression test that a default-config
      tenant still rejects `cases and pallets`.
- [ ] **Step 9** — Testcontainers integration test for the Flyway migration + the
      end-to-end finish path onto a non-flowbin destination.
- [ ] **Step 10** — `bash sbdocs/9-System/scripts/verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh`
      → must report `0 fail`.
- [ ] **Step 11** — `mvn test -Dtest=MobileReplenishServiceUnitTest`, then `mvn verify`.
- [ ] **Step 12** — Update §11 Implementation Status; move ClickUp to `pr submitted`.
- [ ] Code review completed.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Non-flowbin destination accepted when opted in | sysprop `true`; multi-UL replenish, destination `Club01` (`cases and pallets`, holds 3 ULs, no FLA) | Accepted. No `BusinessException`. **No FLA created** for `Club01` |
| Same, single-UL path | as above via `checkDestination` | Accepted; no FLA created |
| Default config still flowbin-only | sysprop absent or `flowbin`; destination `Club01` | `BusinessException` naming the type, the allowed list, and the sysprop — **not** the string "not a flowbin" |
| Flowbin path unchanged | empty flowbin, no FLA | FLA + virtual `PICKLOCATION` UL created exactly as before |
| Inverted guard removed | empty flowbin with **no** UL named after it | Accepted — previously threw `"Unit load already exists."` |
| Occupied flowbin still rejected | flowbin holding a UL, no FLA | `"Destination has already a unit load!"` — unchanged |
| Lane excluded despite allowed type | location typed `cases and pallets` with `transferlane = true` | Rejected by `isNonStorageLane` |
| Finish merges into existing UL | finish onto `Club01` where a UL already holds `ET21BRUTNT` | Stock merged into that UL; no new UL; no FLA |
| Finish creates UL when none matches | finish onto `Club01` with no UL holding the SKU | New UL of item's default type created **on `Club01`**; no FLA |
| FLA destination unaffected | destination already has an FLA | Existing behavior; different-SKU FLA still throws `"has different fixed assignment"` |
| Item-side guard (Fix E) | SKU whose FLA *is* the scanned destination | Accepted — previously `"is wrong location!"` |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `MobileReplenishServiceUnitTest` | `multiUnitLoads_acceptsAllowedNonFlowbinDestination_withoutCreatingFla` | Fix B happy path; `verify(fixLocationAssignmentService, never()).createFixedLocationAssignment(any(), any())` |
| `MobileReplenishServiceUnitTest` | `multiUnitLoads_acceptsNonFlowbinDestinationThatAlreadyHoldsUnitLoads` | Site #2 — no empty-location rejection on the FLA-free branch |
| `MobileReplenishServiceUnitTest` | `multiUnitLoads_rejectsNonFlowbinDestination_whenSyspropDefault` | Backward compatibility (R1) |
| `MobileReplenishServiceUnitTest` | `multiUnitLoads_rejectionMessageNamesTypeAllowedListAndSysprop` | Error-message acceptance criterion; asserts absence of `"not a flowbin"` |
| `MobileReplenishServiceUnitTest` | `checkDestination_acceptsAllowedNonFlowbinDestination_withoutCreatingFla` | Fix C |
| `MobileReplenishServiceUnitTest` | `checkDestination_allowsEmptyFlowbinWithNoMatchingLabel` | **Bug 2 regression** — must fail before Fix C |
| `MobileReplenishServiceUnitTest` | `checkDestination_stillRejectsOccupiedFlowbin` | Guardrail preserved |
| `MobileReplenishServiceUnitTest` | `destination_rejectsLaneEvenWhenTypeAllowed` | `isNonStorageLane` |
| `MobileReplenishServiceUnitTest` | `finish_mergesIntoExistingUnitLoadOnNonFlowbinDestination` | Fix D merge branch |
| `MobileReplenishServiceUnitTest` | `finish_createsUnitLoadOnNonFlowbinDestination_whenNoneMatches` | Fix D create branch; asserts `never()` on FLA creation |
| `MobileReplenishServiceUnitTest` | `finish_stillCreatesFlaForEmptyFlowbinDestination` | Flowbin finish unchanged |
| `MobileReplenishServiceUnitTest` | `checkDestination_acceptsDestinationThatIsItemsOwnFixedLocation` | Fix E |
| `MobileReplenishServiceIntegrationTest` (new, Testcontainers) | `replenishToNonFlowbinDestination_endToEnd_noFlaCreated` | Full finish path against real PostgreSQL; asserts `fix_location_assignment` row count unchanged and stock landed on a UL whose `storagelocation_id` is the club location |
| `FlywayMigrationIntegrationTest` | `v2_2_10_seedsReplenishAllowedDestinationTypesSysprop` | Migration applies; row present with **`sysvalue = 'false'`**; re-running is idempotent |

v2 notes: `mvn verify` runs Testcontainers PostgreSQL; unit tests run on H2, so keep
native SQL out of the unit-test lane. The new integration test must use Testcontainers,
not H2 — it asserts on a Flyway-seeded row.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Confirm UAT location config — **already done, see §1.3**; re-run only if the tenant is refreshed | UAT tenant DB | `SELECT l.id, l.name, lt.sltname FROM location l JOIN location_type lt ON lt.id = l.type_id WHERE l.name = 'Club01';` | One row, `sltname = 'cases and pallets'` | |
| Reproduce the bug pre-fix | UAT, current build | Mobile UI (desktop) → Replenishment → SKU `ET21BRUTNT` → source `16-XC21` → destination `Club01` → Next | `Destination is not a flowbin!` | |
| Opt in and retry post-fix | UAT | Set sysprop to `true`; repeat above | Destination accepted; flow advances past the destination step | |
| Complete the move | UAT | Finish the replenishment | Stock lands on a unit load standing on `Club01`; `SELECT count(*) FROM fix_location_assignment f JOIN location l ON l.id=f.assignedlocation_id WHERE l.name='Club01';` → **0** | |
| Flowbin regression, desktop | UAT | Normal flowbin replenishment end-to-end | Unchanged behavior | |
| Flowbin regression, handheld | UAT handheld | Same via handheld (`checkDestination` path) | Unchanged; confirms desktop/handheld parity (ticket AC) | |
| Message quality | UAT | Set sysprop back to `flowbin`; attempt `Club01` | Message names the type, the allowed list, and the sysprop to change | |
| Non-opted tenant unaffected | Another UAT tenant, sysprop untouched | Attempt a `cases and pallets` destination | Rejected with the new actionable message | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=MobileReplenishServiceUnitTest` | | |
| `mvn test -Dtest=MobileReplenishServiceIntegrationTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Mobile-UI unit tests | No UI change in this plan; `Requested`/`Moving` qty is expected behavior (§1.5) |
| v1/wms-api tests | v1 is a separate sibling ticket per §10 Q2; its own gate run owns them |
| `MobileMoveStockService` / `MobileMoveUnitloadService` flowbin gates | Out of scope (§0 rows #10-11); separate ticket in §8 |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change… | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce replica-local state? | **No** | Helpers are stateless; the sysprop is read through `SyspropService` per call, same as `:766`/`:771`. If `getSysvalue` proves hot, cache it there — not in a new field here |
| 2 | **Connection pool math** | Change per-request DB connections? | **Yes (bounded)** | Fix D adds up to 1 `findByStoragelocationId` + N `findByUnitloadId` (N = ULs on the destination, ≤ ~15 observed on `Club02`) inside the existing finish transaction. No new pool or datasource; see Evidence |
| 3 | **Scheduled jobs** | Add/modify `@Scheduled`? | **No** | Untouched. Note: not creating an FLA means these locations are **not** enrolled in `ReplenishOrderJob` auto-refill — intended (§2.4) |
| 4 | **Long transactions** | Hold a transaction across more calls or external I/O? | **Yes (bounded)** | Same as #2 — a few extra indexed reads, no external I/O added. `finishReplenishmentOrderInternal` was already the long pole |
| 5 | **Request affinity** | Assume same-replica follow-up? | **No** | Destination is persisted on `Replenishorder.destinationId` (`:929-930`), not held in memory |
| 6 | **Retry / idempotency** | Break if a replica dies mid-op and another retries? | **Yes — mitigated** | `resolveNonFlowbinDestinationUnitload` **creates** a UL. A retry after a crash between create and commit could orphan/duplicate a UL. The whole finish path is inside one `@Transactional(tenantTransactionManager)`, so an aborted attempt rolls the new UL back. The merge-first branch also makes a successful retry idempotent in practice. Verify the create happens inside that boundary |
| 7 | **Tenant context** | Cross async boundaries? | **No** | Entirely synchronous request-scoped |
| 8 | **Distributed lock correctness** | Add or rely on cross-replica locks? | **No new locks** | Existing optimistic locking on `Stockunit`/`Unitload` unchanged. Two operators replenishing the same club location concurrently both merge into the same UL → normal optimistic-lock retry, no new deadlock ordering |
| 9 | **Cache invalidation** | Write to a cached entity? | **No** (O3 closed) | Only `clients`, `locations`, `sysprops`, `itemdata` are `@Cacheable`. Fix D writes `Unitload` + `Stockunit` (neither cached) and only **reads** `Itemdata`. No `@CacheEvict` needed. Note `LocationService.getByName` is cached, but no `Location` row is mutated here |
| 10 | **External notifications** | Send HTTP/message inside a transaction? | **No** | No OMS/printer call added. `transferStockToUnitLoad` keeps whatever notification behavior it already has |

### Evidence (for each "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 2, 4 | Extra reads are `findByStoragelocationId` (indexed on `storagelocation_id`) plus one `findByUnitloadId` per UL on the destination. Worst observed fan-out is ~15 ULs (`Club02`, §1.3 query). Bounded and small | `MobileReplenishService.java:501-520` after Fix D; `resolveNonFlowbinDestinationUnitload` |
| 6 | Confirm `unitloadService.createUnitload` executes inside `finishReplenishmentOrder`'s `@Transactional(value = "tenantTransactionManager", …)` and that no `REQUIRES_NEW` sits between them — SBDEV-2575 hit exactly that shape on this class | `MobileReplenishService.java:427-429`; cf. `cc9ca6b` (SBDEV-2575) |
| 9 | Confirmed neither `Unitload` nor `Stockunit` is `@Cacheable` — O3 closed, row revised to No | `grep -rn "@Cacheable" src/main/java/` → `ClientService:53,100`, `LocationService:97`, `SyspropService:95,288`, `ItemdataService:47,52` only |

---

## 7b. v2-only constraint checklist

| # | Constraint | Verdict | Where addressed |
|---|---|---|---|
| 1 | **OSIV disabled** | **N/A** | No lazy associations — v2 has no JPA association annotations; all navigation is explicit repository calls by FK. New reads sit inside the existing transactional methods |
| 2 | **Transaction manager** | **Yes** | `checkDestination` (`:367`) and `finishReplenishmentOrder` (`:427`) already declare `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. No new public entry point is added, so no new annotation — verify `assignDestinationForMultiUnitLoads` runs under the `multiUnitLoads` caller's tenant-scoped boundary |
| 3 | **`@Transactional(readOnly=true)`** | **N/A** | All touched methods are write paths |
| 4 | **Caffeine cache invalidation** | **N/A** | O3 closed: no cached entity is written. §7 row 9 |
| 5 | **Jakarta namespace** | **Yes** | No code is copied from v1 in this plan; if the v1 sibling is ported back, convert `javax.*` → `jakarta.*` |
| 6 | **H2-compatible test SQL** | **Yes** | New Flyway seed is plain `INSERT … SELECT … WHERE NOT EXISTS` with `nextval` — asserted via Testcontainers, not H2 (§6) |
| 7 | **`BaseControllerTest`** | **N/A** | No controller signature or endpoint change; `ReplenishController:229` is untouched |
| 8 | **Micrometer metrics** | **No** | Replenishment is high-frequency, but this changes validation shape, not throughput. Deferred; `LOG.debug` on both new branches gives UAT observability |

---

## 8. Notes

**Related plans**

- `sbdocs/4-Archieves/wms2/plan/260424-club-location-replenish-fix.md` — **superseded** by
  this plan (§1.4). Leave archived; add a pointer line to this plan in it.
- `SBDEV-2575-multi-unitload-replen-requires-new-self-deadlock.md` — prior work on
  `assignDestinationForMultiUnitLoads`; read before touching transaction boundaries.
- `wms2-replenish-workflow.md`, `wms2-multi-unitload-replenish.md`,
  `wms2-replenishment-design.md` — update the destination-validation section once this
  ships; they currently document flowbin-only destinations as invariant.

**Follow-up tickets to open**

1. **v1 sibling** — port Fixes A-E to `v1/wms-api` (§4). Same base filename in
   `sbdocs/1-Projects/wms1/plan/`.
2. **Move Stock / Move Unit Load destination gates** — §0 rows #10-11 carry the same
   flowbin-only pattern (`MobileMoveStockService.java:290`,
   `MobileMoveUnitloadService.java:303`). Likely the client's next report; decide whether
   they share `isAllowedReplenishDestinationType` or get their own sysprop.
3. **Qty label clarity (UI)** — `Requested Qty` / `Moving Qty` is correct but reads as a
   mismatch (§1.5). Relabel or add a hint in `QtySummaryRow.vue`.

**Process lesson (§2.7).** A plan documenting this exact defect was written on
2026-04-24, left with four unanswered verification questions, archived unimplemented, and
the bug resurfaced four months later on the same location. Two guards worth adopting:
never archive a plan whose "Pre-Implementation Verification Needed" section is still
open, and treat an archived plan with no corresponding commit as an open bug. Record via
`project_memory_add_directive` after rollout.

**Client communication.** V1 behaves identically (§2.6). Nothing was lost in migration —
this is a capability the product never had. Worth stating plainly, since the ticket was
filed as a V2 testing defect.

---

## 8b. Risks & Mitigations

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| **R1** | The change silently alters replenishment for tenants that never asked for it | High — every tenant shares this code path; an unexpected destination becoming valid could route stock into overstock or totes locations | Sysprop defaults to `flowbin`, so behavior is byte-identical until an operator opts in (§3.1, §3.6). Locked by `multiUnitLoads_rejectsNonFlowbinDestination_whenSyspropDefault` and the "non-opted tenant unaffected" manual row (§6) |
| **R2** | Opting wineco in type-wide opens **all 510** `cases and pallets` locations, not just the 50 club ones | Medium — an operator could replenish into a `cases and pallets` location that is not meant to be a pick face | Surfaced explicitly as §10 O4, a rollout decision rather than a code decision. The lane guard (`isNonStorageLane`) already blocks staging/transfer/gate/automation/crossdock locations. If 510 proves too broad, key the allowlist on functional area — all club locations share area 51553 (§1.3), so that narrowing is available without redesign |
| **R3** | Fix D creates a unit load where the old code never did, so a crash mid-finish could orphan one | Medium — orphan ULs pollute the location and confuse operators | The create happens inside the existing `@Transactional(value = "tenantTransactionManager", …)` on `finishReplenishmentOrder`, so an aborted attempt rolls back. §7 row 6 makes verifying that boundary — specifically that no `REQUIRES_NEW` sits between them — an explicit implementation check; SBDEV-2575 hit exactly that shape on this class |
| **R4** | Relaxing validation regresses the flowbin path that every tenant depends on daily | High — flowbin replenishment is the core workflow | The flowbin branch is preserved verbatim behind an explicit `flowbin.equals(...)` test, not merged into a shared code path. Verify checks B3, C5, C6 assert it survives; C6 passes at baseline precisely because it guards existing behavior. Four §6 regression scenarios plus a handheld manual row |
| **R5** | Deleting the `:407-411` guard removes a check someone intended | Low | The guard is provably self-contradictory (throws "already exists" when it does not exist), `:403` already establishes the location is empty, and the multi-UL twin never had it (§2.3). Test `checkDestination_allowsEmptyFlowbinWithNoMatchingLabel` pins the corrected behavior |
| **R6** | Two branches both write `V2.2.10`, or SBDEV-2732 renumbers onto it | Medium — a duplicate Flyway version fails startup for every tenant | Collision analysed in §5.1; verify check `F6` asserts exactly one `V2.2.10__*` file and was counter-tested with a deliberate duplicate. Re-run `grep -rn "V2\.2\.1[0-9]" sbdocs/1-Projects/` immediately before committing |
| **R7** | ~~Root cause rests on DBs other than the tested tenant~~ — **retired 2026-08-06** | — | Closed by evidence, not mitigation: `Club01` confirmed `cases and pallets` on `wsl-wineco-uat` (the tested tenant) and on `wms1-wineco` (V1 production), 4 DBs total. See §1.3 and §10 O1 |
| **R8** | Club locations get no automatic replenishment top-up, because no FLA means no `ReplenishOrderJob` enrolment | Low — but it may surprise operators who expect club bins to auto-refill | Intended, and called out in §7 row 3. Manual replenishment to club locations is exactly what the ticket asks for; automatic refill of a shared multi-SKU location is not well-defined. Flag to the client during UAT |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh`

Run with `PROJECT_ROOT` pointed at the v2 checkout (or the per-ticket worktree —
`wms-plan-executor`'s symlink-shadow recipe, so it grades the work and not `develop`):

```bash
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
  bash sbdocs/9-System/scripts/verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh
```

**Baseline already captured and the script already validated in both directions**
(2026-08-06, against `origin/develop` @ `169065c`; `db5c4f2` is merely the last commit that touched `MobileReplenishService.java`, not the baseline HEAD):

| Run | Result |
|---|---|
| Real unfixed `develop` | `Result: 2 pass, 41 fail, 2 skip` (exit 1) |

> **BASELINE LABEL (added 2026-08-06).** Both rows were measured against `origin/develop` at api
> `169065c`, **pre-merge of this plan's own PR #132**. They expire on that merge. **Note the two
> tables in this document do not agree** — the negative control above reads `43 pass` on the
> synthetic tree while §11's completion table reads `45 pass, 0 fail, 2 skip`; the difference is
> checks added after the negative control was recorded. **Re-measure and re-record both, together,
> after #132 merges** — an unlabelled baseline that has silently drifted is how SBDEV-2732 ended up
> instructing implementers that >8 passes meant a vacuous check, on a script that returned 9 every run.
| Synthetic post-fix tree containing the §3 constructs | `Result: 43 pass, 0 fail, 2 skip` (exit 0) |

The two baseline passes are intentional regression guards, not gaps:

- **B4** — "FLA creation call-sites did not grow" holds before *and* after by design.
- **C6** — "occupied-flowbin guardrail preserved" asserts existing behavior survives.

Every other check fails on the unfixed build, so none is a no-op. The second run matters
as much as the first: a grep suite that cannot pass even on correct code is just as
useless as one that passes on broken code. Both runs are reproducible:

```bash
# baseline (must fail)
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
  bash sbdocs/9-System/scripts/verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh

# fast shape-only pass while iterating (skips the two mvn runs)
SBDEV2854_SKIP_MVN=1 PROJECT_ROOT=... bash sbdocs/9-System/scripts/verify-...sh
```

Final acceptance is `Result: N pass, 0 fail` **with the mvn gate not skipped**, pasted
verbatim into the end-of-task report.

### 9.1b Completeness checklist (Layer 2 gate)

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1.3 — `execute_sql` against `wms2-wineco-dev` + `wms1-wineco-dev`; queries and results inline; `db_verified: true` on **4 DBs** incl. the tested tenant (`wsl-wineco-uat`) and V1 production (`wms1-wineco`) — §1.3. No caveat remains; O1 closed |
| 1 | **All callsites enumerated** | ✓ §0 — 17 rows; rows 1-9 in scope, each mapped to a §3 fix and a verify check; rows 10-17 excluded with rationale |
| 2 | **Adjacent bugs** | ✓ Found two the ticket did not ask about: the inverted `findByLabelid` guard (§2.3, Bug 2 — blocks the flowbin happy path too) and the `:390` vs `:908` guard asymmetry (§3.5) |
| 3 | **Backward compatibility** | ✓ §3.1/§3.6 — sysprop defaults to `flowbin`, so behavior is byte-identical until a tenant opts in. Test `multiUnitLoads_rejectsNonFlowbinDestination_whenSyspropDefault` (§6) locks it. No API, schema, or payload change; error-message text is display-only |
| 4 | **Concurrency** | ✓ §7 rows 6, 8 — UL creation inside the existing tenant transaction; merge-first branch is retry-friendly; two operators onto one club location resolve via existing optimistic locking. Explicit check that no `REQUIRES_NEW` sits between finish and create (SBDEV-2575 precedent) |
| 5 | **Multi-tenant** | ✓ Sysprop is per-tenant via `SyspropService` (facility-keyed cache). Ships default-off so no other tenant's behavior moves. §6 has a "non-opted tenant unaffected" manual row |
| 6 | **Error handling** | ✓ New throw path is `BusinessException`, already handled on this route; the new message replaces `"Destination is not a flowbin!"` and names the type, the allowed list, and the corrective action. Verify checks M1-M3 |
| 7 | **Observability** | ✓ `LOG.debug` on both FLA-free branches (§3.2/§3.3) and both resolver branches (§3.4), SLF4J-parameterized. No new metric — deferred with rationale in §7b row 8 |
| 8 | **Rollback / migration** | ✓ §3.6 Flyway `V2.2.10`, idempotent (`WHERE NOT EXISTS`), sequence-drawn id. Rollback is `sysvalue` → `'flowbin'`, no code revert needed — the killer feature of the sysprop design. §5.1 row 1 flags the version-collision check |
| 9 | **Test coverage** | ✓ §6 — 12 unit tests, 2 integration tests, 8 manual rows, all named. Includes a regression test for Bug 2 that must fail pre-fix |
| 10 | **Cross-version (v1↔v2)** | ✓ §2.6 full comparison table; §4 port notes with the four v1-specific adjustments. Deferred to a paired sibling ticket per §10 Q2 — explicitly flagged, not dropped |

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | **Standard** | 6 fixes (A-F) in one service plus one migration — single subsystem |
| **Pre-draft step** | done — DB verification + explicit decisions in §10 | Root cause proven against two live DBs |
| **Plan-review step** | `critic` | Standard+; Fix D changes a stock-movement path, worth a second read |
| **Implementation shape** | `executor`, escalate to `ralph` if the verify baseline shows >8 FAIL | Steps are sequential and the verify script is the exit gate |
| **Verification step** | verify-script + `verifier` | Mandatory |
| **Code-review step** | `code-reviewer` | Touches inventory movement; regression risk on the flowbin path |
| **Commit step** | `git-master` | 7 logical commits (Steps 1-7) |

---

## 10. Open Questions / Resolved Decisions

Resolved with the requester before drafting (pre-draft question phase):

| # | Question | Decision | Rationale |
|---|---|---|---|
| Q1 | Fix shape for non-flowbin destinations | **New FLA-free destination path** (§3.2-§3.4) | The only option that actually fixes the reported case. Type-allowlist alone stops at `:920` because `Club01` holds 3 ULs (§1.4); message-only would close the ticket as "works as designed" against the client's stated need |
| Q2 | v1 and v2, or v2 only? | **v2 only; v1 sibling flagged, not dropped** (§4, §8) | V2 testing surfaced it and the client is migrating to V2. Tests land in two repos, so one TDD-gate run cannot own both |
| Q3 | Requested Qty 1 vs Moving Qty 12 in scope? | **Investigated; not a defect — split the UX concern** (§1.5, §8) | Traced to `realAmountNeeded` vs staged `qtySelected`; expected behavior. Labels are confusing, which is a separate UI ticket |
| Q4 | Workflow: skill-mandated `ralplan` consensus, or draft directly? | **Drafted directly, no subagents** | Evidence (file:line, DB proof, V1 comparison) was already in hand; the requester's review replaces the ralplan Critic gate. Deviation from `wms-bugfix-plan`'s mandated §Plan-generation step, recorded here per that skill's requirement |

Still open — **must be closed before the TDD gate writes tests**:

| # | Question | Owner | Blocking? |
|---|---|---|---|
| **O5** | **Should replenishment to a non-flowbin destination RELOCATE the source unit load instead of transferring stock out of it?** Today (and before this change) `transferStockToUnitLoad` drains the source container and retires it — correct when a case is consumed into a flowbin, questionable when the operator places that case intact on a club shelf, because the physical container on the shelf then carries a retired label while the stock sits on a system-generated one. Relocating the source UL, as Move Unit Load does, preserves container identity. Raised by review H1 | Product + warehouse ops | **No** — not a regression (pre-existing behavior on this code path), and the reported blocker is fixed without it. But it is a real operational wart on the new path |


**O4 — DECIDED 2026-08-06: gate on functional-area picking capability, not location type.**

The original design keyed a CSV allow-list on `location_type.sltname`. The UAT data shows type is
the wrong axis — `cases and pallets` spans **583** locations there:

| Functional area | Count | What they are | `useforpicking` |
|---|---|---|---|
| Storage and Replenish | **472** | overstock racks — the locations replenishment sources **from**, incl. `16-XC21` from this ticket | false |
| Storage and Picking | **70** | the club locations we want | **true** |
| Outbound | 40 | staging / transfer lanes | false |
| Inbound | 1 | `PutAwayLane` | false |

Enabling the type would have opened 583 locations to get 70, and permitted rack→rack "replenishment".
Worse, **`PutAwayLane` sets none of the five lane booleans** and is identified in code by name
(`WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE`), so `isNonStorageLane` cannot see it — the type
allow-list would have made the inbound putaway lane a valid replenishment destination.

`useforpicking` is true for exactly one area (2149 flowbins + the 70 clubs) and false for every
other, so it selects the pick faces and nothing else, with no tenant-specific magic strings.

It is also the axis this system already uses, and it restores a missing symmetry: the **source** side
already asks `LocationArea.useforreplenish` (*"Location not usable to replenish from!"*). A
destination is a pick face being topped up, so the mirror question is `useforpicking` —
**destination : `useforpicking` :: source : `useforreplenish`**.

And it answers the ticket's own question — *"Is the application checking the location type literally
instead of checking supported operational capabilities?"* — as asked. It was; it now checks the
capability.

The sysprop is therefore a plain boolean, `REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS`, default
`false`. Rollout is: enable picking on the area (already true for wineco) **and** flip the switch.

**Nothing blocks implementation.** O4 is a rollout-configuration choice on a flag that ships
off; the code, tests, and migration do not depend on its answer.

Closed:

| # | Question | Resolution |
|---|---|---|
| O1 | Does the tenant the client actually tested have `Club01` as `cases and pallets`? | **Closed 2026-08-06** — yes, confirmed directly on `wsl-wineco-uat` once the MCP came back, *and* on **V1 production** (`wms1-wineco`). Four DBs agree on location id 225748 / type `cases and pallets` / 0 FLAs. V1 production carries **109** unit loads on it and V2 UAT **114**, which is stronger evidence than the dev copies gave (3 each). `ET21BRUTNT` and source `16-XC21` also verified on UAT. Full table in §1.3. Rollout `sysvalue` is confirmed as `cases and pallets` |

Closed during drafting:

| # | Question | Resolution |
|---|---|---|
| O2 | Which `createUnitload` overload should Fix D use? | **Closed.** The 4-arg `createUnitload(Location, Long, Long, String)` at `UnitloadService.java:123` takes the location directly and generates the label; no new overload needed, no caller-invented label. Declares `throws BusinessException` (§3.4) |
| O3 | Is `Unitload` `@Cacheable`, requiring `@CacheEvict` in Fix D? | **Closed — no action.** `grep -rn "@Cacheable" src/main/java/` returns only `clients` (`ClientService:53,100`), `locations` (`LocationService:97`), `sysprops` (`SyspropService:95,288`) and `itemdata` (`ItemdataService:47,52`). Neither `Unitload` nor `Stockunit` is cached, and Fix D only *reads* `Itemdata`. §7 row 9 revised to **No** |

---

## 11. Implementation Status

**Implemented 2026-08-06** — v2 only. Branch `bugfix/SBDEV-2854-replenish-non-flowbin-destination`
in worktree `.claude/worktrees/wms2-api/SBDEV-2854`, off `origin/develop` @ `169065c`.
**MERGED 2026-08-07** — PR [#132](https://github.com/SiteBossInc/wms2-api/pull/132), merge commit `68274b0`, implementation commit `9750a04`. `V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop.sql` is now on `origin/develop`.

> **Still outstanding: the migration must be APPLIED per tenant.** Being on `develop` is not being applied. **SBDEV-2732 cannot apply its `V2.2.11` to any tenant that has not yet received this `V2.2.10`** — `outOfOrder=false` would skip the lower version and `validateOnMigrate=true` then fails every boot, swallowed by `StartupFlywayMigrator`. See SBDEV-2732 §8.1 merge 0b.

| Commit | Contents |
|---|---|
| `a2bd0e9` | Fixes A-F: sysprop constants + 4 helpers, multi-UL branch, `checkDestination` branch + inverted-guard deletion, finish-path resolver, item-side guard alignment, `V2.2.10` migration |
| `ec943fe` | 3 defects found post-implementation (below) + the missing multi-UL test |

### Results

| Command | Result |
|---|---|
| `mvn test -Dtest=MobileReplenishServiceUnitTest` | **121 pass, 0 fail, 0 skip** |
| `mvn test` (full suite) | **4709 tests, 2 failures, 67 skipped** |
| Same, pristine `origin/develop` baseline | **4686 tests, 2 failures, 67 skipped** |
| `verify-SBDEV-2854-...sh` | **`Result: 45 pass, 0 fail, 2 skip`** |
| Same, pristine `origin/develop` | `Result: 2 pass, 41 fail, 2 skip` |

The 2 remaining suite failures are **pre-existing on `origin/develop`**, measured in a throwaway
worktree at the same SHA: `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` and
`MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`. Net effect:
**+22 tests, no new failures.**

### Tests added (10, all in `MobileReplenishServiceUnitTest`)

New nested class `Sbdev2854NonFlowbinDestination` (8) — `checkDestination` accept /
accept-with-unit-loads-present / reject-under-default / lane-rejection /
item's-own-fixed-location, the two multi-UL cases, and the three finish-path cases. Plus 2
pre-existing tests repurposed in `CheckDestinationAdvanced`:
`shouldThrowExceptionWhenDestinationIsNotFlowbin` now asserts the new actionable message, and
`shouldThrowExceptionWhenUnitLoadAlreadyExists` **inverted** into
`checkDestination_allowsEmptyFlowbinWithNoMatchingLabel` (it had codified Bug 2).

### Mutation testing — every fix proven to have teeth

Each fix was reverted in isolation and the suite re-run. All six caught:

| Mutation | Detected by |
|---|---|
| Allow-list always false | 2 failures |
| **Multi-UL flowbin gate restored** | 1 failure — **0 before the new test existed** |
| Finish re-creates the FLA unconditionally | 1 failure + 2 errors |
| Item-side guard unconditional again | 1 failure |
| Lane guard removed | 1 failure |
| Blank-sysprop fallback opens everything | 2 failures |

### Three defects found after the first commit

1. **Migration description overflowed `varchar(255)` by 69 chars** (324 total), caught by the
   existing `SyspropMigrationDescriptionWidthTest`. Unfixed this raises Postgres 22001, rolling
   back the whole migration and leaving the tenant's Flyway chain failed. Rationale moved to the
   file header; column text trimmed to 253.
2. **Fix E introduced a new `Optional.get()`**, taking `OptionalSafetyArchTest` from 8 violations
   to 9 (the SBDEV-2116 rule). Rewritten as `map(...).orElse(false)`; back to 8 with no new
   offending methods (verified by diffing the violating-method sets).
3. **Mutation testing exposed a coverage hole.** Restoring the flowbin gate in
   `assignDestinationForMultiUnitLoads` — the site the reported UI actually hits — left all 106
   tests green, because every test reached the logic through `checkDestination`. Fixed by adding
   `multiUnitLoads_acceptsAllowedNonFlowbinDestination_withoutCreatingFla`, which drives
   `fulfillMultipleUnitLoadsTx` end to end.

### Deviations from the plan as drafted

- **`WmsConstants` naming**: `..._DEFAULT_VALUE`, not `..._VALUE`, matching the four adjacent
  replenishment sysprops. Plan and verify script updated to match.
- **Rejection message extracted** into `rejectDestinationMessage(...)` instead of being duplicated
  at both throw sites. Verify check M3 correspondingly counts throw *sites*, not the string.
- **Destination-type lookup in the finish path is lazy** (inside the no-FLA branch). Strictly
  better than the drafted version: no extra query on the common FLA-present path, and it dropped
  test churn from 19 failures to 3.
- **Fix E uses `map(...).orElse(false)`** rather than `isPresent() && get()`, forced by defect 2
  above. The two destination paths therefore use different idioms; verify check E1 was made
  idiom-agnostic (it counts the location-id comparison on both paths).

### Deliberately-skipped coverage

| What | Why |
|---|---|
| `MobileReplenishServiceIntegrationTest` (Testcontainers) | **Owed, not done.** `BasePostgresIntegrationTest` carries an open blocker — it cannot boot a full context without the `integration` profile (`TODO SBDEV-2217` in that class) — and the nearest working analogue is 567 lines. Verify check `TEST-I` is a **`skip` with that reason, never a pass**. Unit tests assert `verify(never()).createFixedLocationAssignment(...)` and are mutation-validated, but nothing yet proves at the Postgres level that no `fix_location_assignment` row appears. **Note for whoever writes it: ITs are excluded from surefire (`pom.xml:449-452`) and run by failsafe (`pom.xml:562-569`), so use the script's `mvn_it_passes` helper, not `mvn_test_passes`.** |
| `FlywayMigrationIntegrationTest` | Partly redundant: `SyspropMigrationDescriptionWidthTest` already parses `db/migration/` and caught defect 1. A "row is actually seeded" assertion is still owed, and SBDEV-2732 notes the IT harness scans `db/v1-to-v2-onboarding/schema`, not `db/migration/`. |
| v1/wms-api | Separate sibling ticket per §10 Q2. |
| `MobileMoveStockService` / `MobileMoveUnitloadService` gates | Out of scope (§0 rows #10-11); follow-up in §8. |

### Code review (independent pass, 2026-08-06) — 3 High, 5 Medium, all addressed

Commit `a991c9e`. Two High findings were verified against the collaborating services before acting.

| # | Finding | Outcome |
|---|---|---|
| **H1** | Merging into an existing unit load on the destination recorded it as holding 24 units while 12 physically sat there, leaving a second unlabelled case on the shelf | **Fixed** — merge branch removed; every replenished container gets its own unit load. Also eliminated M1, M2 and M4's merge half. **One residual left open — see §10 O5** |
| **H2** | The sysprop + lane guards were enforced only at the scan, not at the mutation, so "default off ⇒ behavior unchanged" was false; two endpoints reach finish with an unvalidated destination | **Fixed** — guards re-asserted in `finishReplenishmentOrderInternal`. 3 tests fail if removed |
| **H3** | The deliberate `V2.2.11` gap would silently wedge Flyway for any tenant reaching it before SBDEV-2732 landed `V2.2.10` | **Fixed** — renumbered to `V2.2.10`. **SBDEV-2732 must now take a later version** |
| M1 | Concurrent replenishment created duplicate ULs with a nondeterministic later merge target | **Fixed** by H1 (no merge scan at all) |
| M2 | ~115-query N+1 on a 114-UL club location, inside the locked finish transaction | **Fixed** by H1 |
| M3 | `createUnitload` → `generateNumber` → `SequenceTransactionService` is `REQUIRES_NEW` — new on this path | **Documented, no code change.** No lock cycle; residual is a consumed sequence number on rollback and a briefly-held second pool connection. Javadoc rollback claim corrected |
| M4 | No client / lock / capacity validation on the FLA-free destination | **Fixed** — client-scoped destinations rejected; lock/carrier concerns moot once merge was removed. Capacity remains absent (flowbin `upperbound` is FLA-derived) — noted below |
| M5 | Coverage gaps mutation testing structurally cannot report — branches no test entered | **Fixed** — 12 tests added: case-insensitivity, whitespace CSV, all five lane flags, `UNIT_LOAD_TYPE_BOX` fallback, blank sysprop, destination-recorded assertions |

**Verification pass (same reviewer, on the fix commit):** all 8 findings confirmed resolved, none
narrowed, **nothing new at High or Medium**. Four new Lows, three fixed (two vacuous test assertions
that could not fail, and this plan's own corrupted version-collision paragraph). The fourth is
recorded rather than fixed:

> **Known cosmetic asymmetry (review L3).** The M4 client-scope check lives only in
> `resolveNonFlowbinDestinationUnitload`, i.e. at the mutation site — the mirror image of H2. On a
> tenant that scopes locations by client, the operator would be allowed to scan a client-scoped
> destination, move the case physically, and only then hit
> `"… is reserved for a different client"` at finish. Nothing corrupts (`rollbackFor` covers
> `BusinessException`), but it is a late failure after physical work. **Inert on the target tenant:**
> all 2890 locations on `wsl-wineco-uat` are `client_id = 0`, including all 583 `cases and pallets`
> ones, so the guard can never fire there. Left as-is to avoid widening a PR that is already open;
> fix alongside the §10 O5 decision if that work happens.

Also settled during verification: `client_id = 0` is literally the **System** client on this tenant,
so reading it as "unscoped" matches the schema's own convention; and comparing the *location's* client
against the item's is the right shape — comparing against the other unit loads on the location would
have broken Club01, which legitimately holds stock for **43 distinct clients**.

Lows: `MIN_EXPECTED_SEEDS` raised 5 → 6 (its stale floor defeated the anti-vacuity purpose of the very
guard that caught the `varchar(255)` overflow). The rest are rollout notes now folded into §5.1:
`findSysvalueBySyskey` is facility-wide (`ORDER BY client_id LIMIT 1`), so a **client-scoped** sysprop row
is silently ignored — opt in on the system-client row; and a direct SQL `UPDATE` takes up to the 2-minute
Caffeine TTL per replica to take effect, so use `SyspropService.setSysvalue` to evict.

Also corrected the reviewer on one point: retiring the emptied **source** container is pre-existing
behavior, not introduced here — `transferStockToUnitLoad`'s internal FLA lookup keys on the *source*
location (`StockunitBusinessService.java:332`), which for replenishment is an overstock rack with no
assignment. That matters because it separates "my change broke this" from "this was always so".

### Verify-script defects found while re-baselining (6 total, all self-inflicted)

Worth recording because the pattern repeats: an assertion that cannot fail is as useless as a wrong fix.
Inverted `perl` negation polarity; an unbounded `.*?` anchored on a method name matching unrelated
methods (twice — E1, then D2, which passed with a merge scan deliberately reintroduced);
`file_contains_ml` succeeding on a **missing** file; a line-counting `grep -c` that cannot reach 2 on a
construct wrapping a newline; `method_body` passing its signature via `@ARGV`, where `perl -n` treats it
as a file to open, so every assertion built on it silently succeeded; and the `mvn -q` trap (third
occurrence in this repo — `-q` suppresses the very lines the grep needs). Fixed with a structural
method-body extractor plus comment-stripping negatives, then each counter-tested by mutation.

### Remaining before merge

1. Push the branch and open the PR into `develop`.
2. Code review (§9.2 recommends `code-reviewer` — touches inventory movement).
3. `mvn verify` (failsafe / Testcontainers) — only `mvn test` has been run so far.
4. UAT: set `sysvalue` to `true`, then walk the §6 manual test plan.
5. Decide §10 O4 (type-wide vs functional-area scoping) before flipping the flag in production.
