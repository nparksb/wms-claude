---
title: "WMSv2: Transfer and Club source inventory by hardcoded area NAMES instead of the usefortransfer flag"
ticket: "SBDEV-2952"
ticket_url: "https://app.clickup.com/t/868kr4zw8"
type: "refactor"
priority: "normal"
status: "MERGED to develop 2026-08-15 — merge commit 0cecb44. ClickUp `on dev`.
    wms2-api PR #158  commits 25f4ef3 + 704e003  refactor/SBDEV-2952-transfer-club-usefortransfer-flag
    Contract test 10/10, targeted 163/163, full suite 5036 run / 2 fail = clean-develop baseline, verify 19 pass / 0 fail.
    AC1/AC3/AC4 EXECUTED against live wineco dev (not just reasoned): per-SKU set identity over 2,682 SKUs with empty
    symmetric difference both directions; users 2,604 units sourced; Shipped + Nirwana 0 rows. The implemented SQL was
    run on a live tenant — it parses and plans (Hash LEFT Join), retiring the §5.2 'typo reaches an operator' hazard.
    NOT DONE: archive, and manual rows M2/M3/M4/M8/M9/M10/M11 — merged WITHOUT the second pair of eyes
    the review note asked for (operator's call at merge time); the ⚠ §6.1.1 risks are now live on develop.
    REVIEW ROUND 1 (2026-08-14, commit 704e003): the two AC5 tests converted from name-only invocation-record
    inspection to verify(...) with both Long args pinned (an arg transposition was demonstrably invisible before);
    two vacuous .doesNotContain assertions dropped; and §3.5 — Clearing resolved once per call, not once per SKU.
    Round 1 also re-measured the behaviour differential at the AREA level across 7 DBs incl. the only v2 PRODUCTION
    tenant (0 rows differ), closing a structural blind spot: the unit-load differential inner-joins stockunit, so
    the two zero-stock whitelisted areas (Deep Storage, Storage Picking and Replenish (from)) were never graded by it.
    Also confirmed usefortransfer is NOT NULL on fresh-seeded AND migrated DBs, so `= true` has no NULL hazard.
    ⚠ STILL NO SECOND PAIR OF EYES — all six subagent lanes failed to return in the authoring session, and round 1
    was the same operator. A human review is still wanted, particularly on the two §6.1.1 risks.
    No deploy prerequisite — no migration, no sysprop, no UI change.
    D4: option A. D5: HAL break accepted, old method deleted not deprecated. Verify script proven three ways (0/16 pre-change, 16/0 on fixture,
    11/5 adversarial with sabotaged SQL). FIVE of the plan's own claims were falsified across r1→r3:
    the SBDEV-2951 dependency is NOT blocking (no hunk overlap, measured); a malformed native query has no
    startup safety net (ddl-auto=none, native SQL unparsed at boot); v1 DOES carry the identical defect (§12);
    the real residual risk is that usefortransfer becomes load-bearing for two operator screens (§6.1.1),
    not the HAL break; and r2 caught only ONE direction of that risk — r3 adds case 3, where CLEARING the
    flag on a stocked storage area silently removes up to 246,883 units, reproducing this ticket's own
    failure mode under a new trigger."
project: ["wms2"]
version: "v2"
requester: "Nam Park (found while investigating SBDEV-2951)"
created: "2026-08-13"
updated: "2026-08-15"
db_verified: true
related:
  - "SBDEV-2951-transfer-club-available-counts-lane-only"
  - "SBDEV-2854-replenish-rejects-non-flowbin-destination"
  - "260424-TRANSFER_ORDER_PERFORMANCE_PLAN"
tags:
  - plan
---

# WMSv2: Transfer and Club source inventory by hardcoded area NAMES instead of the `usefortransfer` flag

**Ticket:** [SBDEV-2952](https://app.clickup.com/t/868kr4zw8)
**Project:** wms2 | **Version:** v2 | **Type:** refactor (preventive hardening)
**Priority:** normal
**Status:** **MERGED to `develop` 2026-08-15** — [PR #158](https://github.com/SiteBossInc/wms2-api/pull/158), merge commit `0cecb44`. ClickUp `on dev`; archive-gated on manual QA
**Date:** 2026-08-13
**Repo:** `v2/wms2-api` (single repo, single PR)

> [!note] **r1 → r4 corrected six claims this plan itself had made. Read §6.1.1 and §12 first.**
> **§9.2 / Q7 (r4)** — r3 introduced option G as a serious contender and leaned toward it as the
> remedy for the §7.4 coverage gap. **On inspection both of G's headline gains were overstated**:
> its bootstrap validation guards only a new derived finder, not the native `Unitload` query that
> can actually be malformed; and the helper it makes testable is near-tautological glue. **Q7's
> recommendation is now A**, and §7.4 no longer points at G as a fix.
> **§6.1.1 (new, most important — and it took two passes to get right)** — r1 treated the HAL break
> as the headline risk. It is not. The real consequence is that `usefortransfer` becomes
> **load-bearing for two operator screens where it was previously inert**, in **both** directions.
> r2 caught only the exposure direction (flag `Outbound` → 2.86M units of `Shipped` stock appear).
> **r3 adds the worse one**: *clearing* the flag on a stocked storage area silently removes up to
> **246,883 units** — reproducing this ticket's own failure mode under a new trigger. Full
> divergence enumeration in §6.1.1; both are exercised by manual rows M10 and M11.
> **§12 (new)** — r1's completeness checklist claimed v1 had no equivalent path. **False.**
> `v1/wms-api` carries the identical query and predicate, reachable from Club Run.
> **§5.1** — r1 called the SBDEV-2951 dependency **BLOCKING**. Measured: **no overlapping hunks**,
> so git merges cleanly. Downgraded to recommended sequencing.
> **§5.2/§7.4** — r1 asserted the runtime-failure risk without checking. Confirmed and sharpened:
> `ddl-auto=none` and native `@Query` strings are not parsed at boot, so there is **no** startup
> safety net — a typo reaches an operator, not a build.

> [!important] **The acceptance bar is behaviour-identity, not improvement.**
> This ticket changes *how* the sourceable set is computed, not *what* it contains. On all six
> reachable tenant databases the old and new predicates return **byte-identical unit-load id sets**
> (§2.4). Any diff at implementation time is a defect in the change, not a discovered bug.

> [!warning] **The SQL predicate change has ZERO automated coverage.** `UnitloadRepositoryTest` is
> `@Disabled`, and every test that touches this method mocks the repository — so no test in the suite
> ever parses or executes this SQL. The unit tests in §7 prove **wiring only**. Predicate correctness
> rests on the §2.4 database differential and the §7.3 manual plan. Do not read a green build as
> proof the predicate is right. See §7.4.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep over `v2/wms2-api/src`, not from memory. Every in-scope row is covered by §3.

| # | File:line | Construct | In scope? | Phase |
|---|---|---|---|---|
| 1 | `repo/jpa/UnitloadRepository.java:106-114` | the query + its `@RestResource` export | **yes** | §3.1 |
| 2 | `service/TransferOrderService.java:328-331` | caller — web Transfer Picking | **yes** | §3.2 |
| 3 | `service/CustomerorderBatchService.java:1079-1084` | caller — Club Run | **yes** | §3.2 |
| 4 | `service/WmsConstants.java:755-762` | the eight `AREA_*_NAME` constants | **yes — retained, not deleted** | §3.3 |
| 5 | `unit/service/TransferOrderServiceUnitTest.java:1107-1119` | 1 test stubs the 3-arg signature | **yes** | §3.4 |
| 6 | `unit/service/CustomerorderBatchServiceUnitTest.java:1910-2286` | 6 tests stub the 3-arg signature | **yes** | §3.4 |
| 7 | `repo/jpa/StockunitRepository.java:282-292` `getStockUnitItemIdAndNotLocked` | already uses `usefortransfer = true` (INNER JOIN, no `users`) | **no** — the in-repo precedent, correct as-is | — |
| 8 | `service/mobile/MobileTransferOrderService.java:246` | sole prod caller of #7; mobile transfer sourcing | **no — flagged for BA** | §10 Q1 |
| 9 | `service/SectionService.java:72` | `findByName(AREA_OUTBOUND_NAME)` | **no** — single-area identity lookup, different question | — |
| 10 | `service/UserService.java:80` | `findByName(AREA_USERS_NAME)` | **no** — but it is the precedent justifying D1 | §3.1 |
| 11 | `controller/rest/UtilRestController.java:773` | `findByName(AREA_USERS_NAME)` | **no** — same precedent | — |
| 12 | `controller/rest/UtilRestController.java:567-606` | area-name provisioning | **no** — entirely commented out / dead | — |

### 0.1 Anti-pattern sweep — is this 1 of N?

A repo-wide grep for all eight `AREA_*_NAME` constants and their string literals across
`src/main/java` returns rows 1–3 and 9–12 above and nothing else.

**Verdict: 1 of 1.** The target query is the **only** place in production code that uses area
*names as a set predicate for sourceability*. Rows 9–11 are single-area **identity lookups**
("give me the one area called X") — a different question, correctly answered by name, and
deliberately untouched. There is no second instance of this anti-pattern to sweep up, so this plan
does not leave a known sibling defect behind.

---

## 1. Problem Statement

The **Available Inventory** list on **Transfer Picking** and **Club Run** decides which locations may
be sourced by matching each location's area **name** against six hardcoded strings:

```java
Arrays.asList(AREA_INBOUND_NAME, AREA_STORAGE_PICKING_NAME, AREA_STORAGE_PICKING_REPLENISH_NAME,
              AREA_STORAGE_REPLENISH_NAME, AREA_DEEP_STORAGE_NAME, AREA_USERS_NAME)
```

The schema already carries the correct predicate as a first-class flag — `location_area.usefortransfer`
— and the six-string list is a hand-copy of it (proven in §2.4).

**The failure mode this prevents.** A client who renames an area, or adds a second picking area
(mezzanine pick module, cold room, a club-only picking area), gets stock that **silently disappears**
from both screens. There is no error, no warning, and no empty state — just a short list that looks
complete. An operator cannot tell a correctly-empty list from a truncated one, and the arithmetic
downstream (transfer quantities, club run availability) is computed off the truncated set.

**This is preventive.** There is no known live symptom, because every warehouse we run today happens
to use the stock area names. Found while investigating [[SBDEV-2951-transfer-club-available-counts-lane-only]].

The codebase already settled this exact argument for replenishment at `WmsConstants.java:1126-1128`
(SBDEV-2854): *"Capability, not location type, is the correct axis, and it is the axis this system
already uses: the SOURCE side asks `LocationArea.useforreplenish`."* The same reasoning applies to
transfer, and `usefortransfer` is the flag that already exists for it.

### 1.1 Why now, and why so small

The change is one SQL disjunct and one method signature. It is worth doing as its own ticket because
the current code is a **latent correctness trap that only fires on customer configuration change** —
i.e. it will fire during an onboarding or a warehouse re-layout, at the worst possible moment, and
present as "the WMS is missing our stock" rather than as a code defect.

---

## 2. Current Architecture

### 2.1 The query

`v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java:106-114`

```java
@RestResource(path = "getBatchLocationsByItemIdAndNamedLocations", rel = "getBatchLocationsByItemIdAndNamedLocations")
@Query(value = "SELECT ul.* "
        + " FROM unitload ul  "
        + " INNER JOIN stockunit su ON su.unitload_id = ul.id "
        + " INNER JOIN location lo ON ul.storagelocation_id = lo.id "
        + " LEFT JOIN location_area area ON lo.area_id = area.id "
        + " WHERE su.itemdata_id = :itemDataId "
        + " AND (lo.staginglane = true OR lo.id = :clearingLocationId OR area.name IN (:locationNameList)) ", nativeQuery = true)
List<Unitload> getBatchLocationsByItemIdAndNamedLocations(@Param("itemDataId") Long itemDataId,
                                                         @Param("clearingLocationId") Long clearingLocationId,
                                                         @Param("locationNameList") List<String> locationNameList);
```

The `WHERE` clause is a three-way disjunction. Only the third disjunct is being changed:

| Disjunct | Purpose | Changing? |
|---|---|---|
| `lo.staginglane = true` | staged stock on any lane | **no — preserved verbatim** |
| `lo.id = :clearingLocationId` | the Clearing pseudo-location | **no — preserved verbatim** |
| `area.name IN (:locationNameList)` | "is this area a valid source?" | **yes — this is the whole change** |

### 2.2 The two callers

Both pass the **same six constants in the same order**, and neither derives the list from anything:

| Caller | File:line | Enclosing method | Branch it sits in |
|---|---|---|---|
| Transfer Picking | `service/TransferOrderService.java:328-331` | `getTransferLineUnitLoads(...)` @292 | `else` of `if (onlyTransferLocation)` |
| Club Run | `service/CustomerorderBatchService.java:1079-1084` | `fetchUnitLoads(...)` @1058, from `getClubLineUnitLoads(...)` @939 | `else` of `if (onlyStagingLocation)` |

The `if` branch of each calls `getBatchLocationsByItemIdAndLaneName(...)` — a separate,
lane-scoped query that this plan does not touch.

**Branch equivalence — verified, because collapsing to one method depends on it.** Both flags
originate as the same request-body boolean (`TransfersController.java:343` reads
`reqMap.get("onlyTransferLocation")`; `ClubLineController.java:269` reads
`reqMap.get("onlyStagingLocation")`) and both mean the same thing: *false* = "show warehouse-wide
sourceable stock", *true* = "show only what is staged on the lane". Neither caller reaches the
changed line under a condition the other cannot. The question being asked is identical, so one
shared method is correct rather than merely convenient.

One benign asymmetry, noted so it is not mistaken for a defect later: `TransferOrderService`
iterates `positions` directly and may call the query more than once for a repeated SKU, while
`CustomerorderBatchService` de-duplicates first (`uniqueItemDataIds`, `:1073-1077`). That is a
call-*frequency* difference only — it does not affect the predicate, the result set, or this change.

Both services import `WmsConstants` via a **wildcard static import**
(`TransferOrderService.java:15`, `CustomerorderBatchService.java:26`), so removing the constant
references requires **no import cleanup**.

### 2.3 The flag, and the precedent that already uses it

`location_area.usefortransfer` is mapped at `model/LocationArea.java:27` as
`private Boolean usefortransfer = Boolean.FALSE;` and is **`NOT NULL` in the database** on every
tenant (§2.4).

`repo/jpa/StockunitRepository.java:282-292` **already** asks the flag:

```java
"INNER JOIN location_area loc_area on loc.area_id = loc_area.id " +
...
"AND loc_area.usefortransfer = true " +
```

Its sole production caller is `service/mobile/MobileTransferOrderService.java:246`. So the flag is
not a new or speculative axis — it is the axis the **mobile** transfer flow already uses. This plan
brings the web flow onto the same axis. (It does **not** make the two flows identical — see §10 Q1.)

### 2.4 Database verification — measured, all six reachable tenant DBs

`db_verified: true`. Run 2026-08-13 via the per-tenant MCP servers.

**Step 1 — predicate agreement per area.** For every area on every tenant, compare
`old = name IN (6 strings)` against `new = usefortransfer = true OR name = 'users'`:

```sql
SELECT a.name, a.usefortransfer,
       (a.name IN ('Inbound','Storage and Picking','Storage Picking and Replenish (from)',
                   'Storage and Replenish','Deep Storage','users'))       AS old_pred,
       (a.usefortransfer = true OR a.name = 'users')                      AS new_pred,
       (SELECT count(*) FROM location l WHERE l.area_id = a.id)           AS locations
FROM location_area a ORDER BY a.name;
```

Result on `dev_wh01_om1` (wineco dev) — and structurally identical on all six:

| area | `usefortransfer` | old_pred | new_pred | agree? | locations |
|---|---|---|---|---|---|
| Deep Storage | true | true | true | ✅ | 0 |
| Default | false | false | false | ✅ | 16 |
| Inbound | true | true | true | ✅ | 13 |
| Outbound | false | false | false | ✅ | 40 |
| Storage Picking and Replenish (from) | true | true | true | ✅ | 0 |
| Storage and Picking | true | true | true | ✅ | 2,137 |
| Storage and Replenish | true | true | true | ✅ | 415 |
| **users** | **false** | **true** | **true** | ✅ | 118 |

Every tenant carries the **same eight areas**. `usefortransfer = true` on exactly the five
storage/inbound areas. **`users` is `usefortransfer = false` on every tenant** — which is precisely
why the explicit `OR area.name = 'users'` disjunct is load-bearing and cannot be dropped.

**Step 2 — unit-load set differential**, modelling the *full* predicate including `staginglane` and
Clearing, and diffing the returned id sets with `EXCEPT` in both directions:

| DB | tenant | old unit loads | new unit loads | only_in_old | only_in_new |
|---|---|---|---|---|---|
| `dev_wh01_om1` | wineco dev | 18,910 | 18,910 | **0** | **0** |
| `wh01_om1_v2` | wineco UAT (wsl) | 12,518 | 12,518 | **0** | **0** |
| `wh01_hydra_v2` | hydra UAT | 362 | 362 | **0** | **0** |
| `wh01_hydra_v2` | hydra dev2 | 347 | 347 | **0** | **0** |
| `wh01_shipitez_v2` | shipitez LA UAT | 1,600 | 1,600 | **0** | **0** |
| `wh02_shipitez_v2` | shipitez NY UAT | 60 | 60 | **0** | **0** |

**Empty symmetric difference on every tenant.** This is the evidence behind the acceptance bar.

**Step 3 — edge cases.** On all six DBs:

| Check | Result | Consequence |
|---|---|---|
| `location.area_id IS NULL` | **0 rows** | the LEFT JOIN's NULL-area path is unreachable today |
| `location_area.usefortransfer IS NULL` | **0 rows** | no three-valued-logic surprise |
| `information_schema` nullability of `usefortransfer` | **NOT NULL** | flag is always true/false |

Even so, `area.usefortransfer = true` is **NULL-safe by construction**: under a LEFT JOIN a missing
area yields `NULL`, `NULL = true` is `NULL`, and `NULL` is not `TRUE`, so the row is excluded —
exactly as `area.name IN (...)` yields `NULL` and excludes. The two predicates degrade identically.
**The LEFT JOIN must be preserved**; switching to INNER JOIN would silently drop `staginglane` and
Clearing rows whose location has no area.

**Step 4 — the `staginglane` trap (discovered during verification, not in the ticket).**

```sql
SELECT count(*) FROM location l JOIN location_area a ON l.area_id = a.id
 WHERE l.staginglane = true AND a.usefortransfer IS NOT TRUE AND a.name <> 'users';
```

On `dev_wh01_om1` this returns **20 — i.e. all 20 staging lanes**, every one of them in the
`Outbound` area, which is neither `usefortransfer` nor `users`.

**Therefore the `lo.staginglane = true` disjunct is single-handedly carrying every staging lane.**
Any "tidy-up" that folds staging lanes into the area predicate — the obvious-looking simplification —
silently removes all 20 from both screens. §3.1 preserves the disjunct verbatim and §9 records the
verify-script assertion that guards it.

### 2.5 The query is a live HAL endpoint

`UnitloadRepository.java:27` declares
`@RepositoryRestResource(collectionResourceRel = "unitload", path = "unitload")`, and
`RestConfiguration.java:47` sets `RepositoryDetectionStrategies.ANNOTATED`. Annotated repositories
are exported, and the method's own `@RestResource` exports the search endpoint. So

```
{basePath}/unitload/search/getBatchLocationsByItemIdAndNamedLocations
    ?itemDataId=&clearingLocationId=&locationNameList=
```

is reachable over HTTP today. Grepping `v2/wms2-web-ui` and `v2/wms2-mobile-ui` (excluding
`node_modules`) for that path and for `/unitload/search/` returns **zero hits** — no first-party
consumer.

**Rename safety.** A repo-wide grep for the string `getBatchLocationsByItemIdAndNamedLocations`
outside `src/**/*.java` finds exactly one artifact: `docs/plan/completed/
TRANSFER_ORDER_PERFORMANCE_PLAN.md`, a completed historical plan inside the repo. No config file,
no properties file, no client code, and no HAL path constant depends on the old name as a string.
The historical doc is deliberately left alone — it is a record of what was true then. This mirrors the finding recorded in SBDEV-2951 §0 row 4 about `getAmountAvailable` being
HAL-exported: the export here is **incidental**, an artifact of the repository-wide annotation,
not a designed contract. It is nonetheless a real public surface, so §6 records the break explicitly.

---

## 3. Design

### 3.1 Replace the name disjunct with the flag, and rename the method

`repo/jpa/UnitloadRepository.java:106-114` becomes:

```java
/**
 * Unit loads holding stock of the given item that may be SOURCED by transfer picking and club runs.
 *
 * Sourceability is decided by capability, not by area name: an area qualifies when it carries
 * LocationArea.usefortransfer. The 'users' area is an explicit, deliberate addition — it holds
 * operator-held stock and is intentionally NOT flagged usefortransfer, because the mobile transfer
 * flow (StockunitRepository.getStockUnitItemIdAndNotLocked) must keep excluding it. The literal
 * mirrors WmsConstants.AREA_USERS_NAME; UnitloadRepositoryUsersAreaConstantTest guards the pair.
 *
 * The staginglane and Clearing disjuncts are load-bearing and independent of the area predicate:
 * on every tenant measured, ALL staging lanes live in the Outbound area, which is not usefortransfer.
 * Do not fold them into the area predicate. See SBDEV-2952 §2.4.
 */
@RestResource(path = "getBatchLocationsByItemIdAndTransferableAreas", rel = "getBatchLocationsByItemIdAndTransferableAreas")
@Query(value = "SELECT ul.* "
        + " FROM unitload ul  "
        + " INNER JOIN stockunit su ON su.unitload_id = ul.id "
        + " INNER JOIN location lo ON ul.storagelocation_id = lo.id "
        + " LEFT JOIN location_area area ON lo.area_id = area.id "
        + " WHERE su.itemdata_id = :itemDataId "
        + " AND (lo.staginglane = true OR lo.id = :clearingLocationId "
        + "      OR area.usefortransfer = true OR area.name = 'users') ", nativeQuery = true)
List<Unitload> getBatchLocationsByItemIdAndTransferableAreas(@Param("itemDataId") Long itemDataId,
                                                            @Param("clearingLocationId") Long clearingLocationId);
```

The old 3-arg method is **deleted** (decision D2, §10).

Changes, precisely:

| Element | Before | After | Rationale |
|---|---|---|---|
| area predicate | `area.name IN (:locationNameList)` | `area.usefortransfer = true OR area.name = 'users'` | the point of the ticket |
| 3rd parameter | `List<String> locationNameList` | *removed* | no longer derivable-from-caller; it was always a constant |
| method name | `...AndNamedLocations` | `...AndTransferableAreas` | the name described the mechanism; the new one describes the question |
| `LEFT JOIN` | LEFT | **LEFT (unchanged)** | NULL-area safety, §2.4 step 3 |
| `staginglane` / Clearing | present | **present, verbatim** | §2.4 step 4 — carries all 20 lanes alone |

**Why `'users'` is a SQL literal rather than a bound parameter.** Binding it would re-introduce a
third argument and let a caller pass anything, defeating "one method both callers share" (AC5). The
literal is consistent with existing production code that already resolves this area by name —
`UserService.java:80` and `UtilRestController.java:773` both call
`locationAreaRepository.findByName(WmsConstants.AREA_USERS_NAME)`. The cost is a silent coupling
between the SQL literal and the constant, which §3.4 closes with a one-line guard test.

### 3.2 Collapse both callers onto the one shared method

`service/TransferOrderService.java:328-331`:

```java
resultList = unitloadRepository.getBatchLocationsByItemIdAndTransferableAreas(
    itemData.getId(),
    locationService.getClearing().getId());
```

`service/CustomerorderBatchService.java:1079-1084`:

```java
unitLoads = unitloadRepository.getBatchLocationsByItemIdAndTransferableAreas(
    itemDataId,
    locationService.getClearing().getId());
```

Both surrounding `if/else` structures, the `getBatchLocationsByItemIdAndLaneName` branches, and all
downstream carrier-traversal and filtering logic are **unchanged**.

This satisfies ticket AC5 structurally rather than by convention: with the argument list gone there
is no per-caller configuration left to drift, so a future change to the sourceable set **cannot**
land on one screen and miss the other.

### 3.3 `WmsConstants` — retain the constants, delete nothing

After §3.2, five constants (`AREA_INBOUND_NAME`, `AREA_STORAGE_PICKING_NAME`,
`AREA_STORAGE_PICKING_REPLENISH_NAME`, `AREA_STORAGE_REPLENISH_NAME`, `AREA_DEEP_STORAGE_NAME`) have
no remaining *live* references — their only other mentions are the commented-out provisioning block
at `UtilRestController.java:567-606`.

**They are deliberately retained.** Deleting them is scope creep on a preventive ticket, it would
strand the commented provisioning block that documents how a warehouse is seeded, and it risks a
merge conflict with SBDEV-2951 for no behavioural gain. `AREA_USERS_NAME`, `AREA_OUTBOUND_NAME` and
`AREA_DEFAULT_NAME` remain live regardless.

**The verify script must NOT assert their deletion** — a future reviewer reading "5 unused constants"
should find this paragraph, not a red row.

### 3.4 Tests — wiring guards plus one constant guard

Seven existing tests stub the 3-arg signature and must be updated to the 2-arg form (§0 rows 5–6;
exact list in §7.1). Beyond the mechanical update, three new assertions:

1. **`UnitloadRepositoryUsersAreaConstantTest`** — asserts `WmsConstants.AREA_USERS_NAME` equals
   `"users"`, so renaming the constant cannot silently desynchronise it from the SQL literal.
   This is the mitigation for the coupling introduced in §3.1.
2. **Shared-method wiring, Transfer** — `TransferOrderServiceUnitTest` verifies
   `getBatchLocationsByItemIdAndTransferableAreas` is invoked and the old method is never invoked.
3. **Shared-method wiring, Club** — the same pair in `CustomerorderBatchServiceUnitTest`.

Assertions 2–3 are what AC5 can honestly be tested at, given §7.4. They prove both flows reach the
same method; they do **not** prove the predicate.

### 3.5 Resolve the Clearing location once per call (added at PR review, 2026-08-14)

Both call sites passed `locationService.getClearing().getId()` as the second argument **from inside
the per-SKU loop**. `LocationService.getClearing()` (`LocationService:117`) is an uncached
`locationRepository.findByName(...)` — not `@Cacheable`, no memoisation — so a screen listing N SKUs
issued N extra single-row lookups for a value that is warehouse-wide and constant for the whole call.
On wineco dev the Club Run SKU set is 2,682.

Not introduced by this ticket, but this ticket rewrites exactly those argument lists, so the fix is
two lines where the diff already is. Resolved **lazily on first use** rather than hoisted
unconditionally above the loop, which keeps three things byte-identical to the pre-change behaviour:

- the lane-only / staging-only branches still issue **zero** `getClearing()` calls;
- an empty position list, or one where every position is filtered out by the `itemData == null` /
  `skuFilter` guards in `TransferOrderService`, still issues zero;
- the `NullPointerException` on a warehouse with no Clearing location (`getClearing()` ends in
  `.orElse(null)`) still fires at exactly the same iteration it fired at before — this change does not
  move it earlier, and deliberately does not fix it. That is its own ticket.

Pinned by tests 13–14 in §7.2 and verify rows `H1`/`H2`. Both were negative-tested against the
pre-hoist commit (`25f4ef3`): the two tests fail with Mockito `Wanted 1 time`, and the verify script
reports exactly `17 pass, 2 fail` with `H1`/`H2` red.

---

## 4. File Change Summary

| File | Change | Description |
|---|---|---|
| `repo/jpa/UnitloadRepository.java` | **Modify** | Rename to `getBatchLocationsByItemIdAndTransferableAreas`; swap area predicate to `usefortransfer = true OR area.name = 'users'`; drop `locationNameList` param; add the rationale Javadoc. Delete the old 3-arg method. |
| `service/TransferOrderService.java` | **Modify** | Call the new 2-arg method; drop the `Arrays.asList(...)` argument (lines 328-331). No import change (wildcard static import). Plus §3.5: resolve Clearing lazily, once per call. |
| `service/CustomerorderBatchService.java` | **Modify** | Same, lines 1079-1084, plus §3.5. |
| `service/WmsConstants.java` | **Unchanged** | Constants deliberately retained — §3.3. Listed here so its absence from the diff is intentional, not an oversight. |
| `unit/service/TransferOrderServiceUnitTest.java` | **Modify** | Update 1 stub to 2-arg; add the shared-method wiring assertion (§7.2 #11) and the resolve-once assertion (§7.2 #13). |
| `unit/service/CustomerorderBatchServiceUnitTest.java` | **Modify** | Update 6 stubs / 4 verifies to 2-arg; add the shared-method wiring assertion (§7.2 #12) and the resolve-once assertion (§7.2 #14). |
| `unit/repo/UnitloadRepositoryUsersAreaConstantTest.java` | **Add** | One test: `AREA_USERS_NAME` == `"users"`. |
| `sbdocs/9-System/scripts/verify-SBDEV-2952-...sh` | **Add** | Grep-level acceptance checks — §9.1. |

No Flyway migration. No system property. No schema change. No seed data. No UI change.

---

## 5. Phased Implementation Plan

**Single phase, single PR.** The change is one predicate, one signature, and their call sites; there
is no safe intermediate state worth landing separately, and a two-step (add-new-then-migrate) rollout
would leave the old name-matching query in the tree — the very thing the ticket exists to remove.

### 5.1 Prerequisites

| Prerequisite | Status | Detail |
|---|---|---|
| **Deploy-order dependency** | ⚠ **recommended, NOT blocking** — measured | SBDEV-2951's `wms2-api` PR #157 (branch `bugfix/SBDEV-2951-transfer-club-onhand-quantity`) modifies the same two files, so an earlier draft of this plan called it blocking. **That was over-cautious — `git diff origin/develop...bugfix/SBDEV-2951-...` shows no hunk overlap.** 2951 touches `TransferOrderService` @47/59/72/261/276-288 and `CustomerorderBatchService` @93/142/172/1244/1262-1278; this plan edits `TransferOrderService` **328-331** and `CustomerorderBatchService` **1079-1084**. Disjoint regions, so git merges both cleanly, and 2951's §0 row 5 already records `UnitloadRepository.java:106-114` as untouched. **Still merge 2951 first where practical** — it shifts this plan's edit targets by roughly +9 lines in `TransferOrderService` and +4 in `CustomerorderBatchService`, and it is the higher-priority ticket already in review. Do not let it *block* 2952 if review stalls. |
| **Base branch freshness** | ⚠ action needed | Local `v2/wms2-api` is on `develop`, **24 commits behind `origin/develop`**. Branch off a freshly-fetched `origin/develop`. |
| **DB state** | ✅ none | No migration, no backfill. `usefortransfer` is already populated and `NOT NULL` on all six tenants (§2.4). |
| **Feature flags / sysprops** | ✅ none | Deliberately ungated — see §9 option C for why. |
| **Config / env** | ✅ none | — |
| **External systems** | ✅ none | No OMS, printer, or Keycloak interaction on this path. |
| **Access** | ✅ held | Per-tenant DB MCP access used for §2.4 and needed again for §7.3 M1. |
| **Monitoring** | ✅ none | No new metric — §7.5 row 5. |

### 5.2 The single phase

**Goal.** Both Transfer Picking and Club Run source stock via `location_area.usefortransfer`
(plus the explicit `users` area), through one shared repository method, with no change to the
sourced set on any current tenant.

**Changes.** §3.1 → §3.2 → §3.4, in that order (the signature change breaks compilation of the
callers and tests, so the compiler enumerates the work).

**Testing.** §7.

**Risk.** **Low-to-moderate.** The change itself is provably behaviour-identical (§2.4). The risk is
not in the logic but in the **absence of any lane that can catch a typo in the SQL string** (§7.4).

Confirmed, because it sets this rating: **a malformed native query here fails on first call, not at
startup.** `spring.jpa.hibernate.ddl-auto=none` (`application.properties:70`), and Hibernate does not
parse `nativeQuery = true` strings at bootstrap the way it validates JPQL named queries — native SQL
is handed to PostgreSQL at execution time. So there is no context-load safety net: a broken query
compiles, boots, passes the whole suite, and then 500s the first time an operator opens Available
Inventory. Mitigated by §7.3 M2/M3, which open both screens against a real tenant before merge —
those two rows are the only thing standing between a typo and production.

**Branch.** `refactor/SBDEV-2952-transfer-club-usefortransfer-flag`

**Estimated effort.** ~2–3 hours implementation and test update; the manual verification in §7.3 is
the longer pole.

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| Sourced unit-load set, Transfer Picking | name-matched | flag-matched | **none** — set-identical, all 6 tenants (§2.4) |
| Sourced unit-load set, Club Run | name-matched | flag-matched | **none** — set-identical, all 6 tenants (§2.4) |
| Staging-lane stock | via `staginglane` disjunct | **unchanged** | none — all 20 lanes preserved (§2.4 step 4) |
| Clearing-location stock | via `clearingLocationId` | **unchanged** | none |
| `users` / operator-held stock | via name list | via explicit `name = 'users'` | none — 118 locations still sourced |
| `Shipped`, `Nirwana` exclusion | excluded (`Outbound`/`Default`) | **still excluded** | none — neither area is `usefortransfer` |
| **HAL endpoint** `/unitload/search/getBatchLocationsByItemIdAndNamedLocations` | exported, 3 params | **removed**; replaced by `...AndTransferableAreas` with 2 params | ⚠ **knowingly-taken break** — see below |
| Java method signature | 3-arg | 2-arg | compile-time; all callers in-repo and updated |
| DB schema | — | — | none |
| Error-response shape | — | — | none |
| Frontend payload shape | — | — | none |

### 6.1 The HAL break — taken deliberately, recorded here

Per decision D2 (§10), the old endpoint is **removed rather than deprecated**. Justification:

- No first-party consumer exists — both v2 UIs grepped, zero hits (§2.5).
- The export is incidental (repository-level `@RepositoryRestResource` + `ANNOTATED` strategy), not a
  designed contract.
- Keeping a deprecated name-matching query in the tree preserves the exact anti-pattern the ticket
  removes, and invites the next developer to copy it.

**Residual risk, stated plainly:** an unknown external or manual HAL consumer would break. This is
unprovable from the repo and judged acceptable. If that risk is not acceptable to the reviewer, §9
option D (keep both, deprecate the old) is a one-line change to this plan.

### 6.1.1 ⚠ The real residual risk: this change makes `usefortransfer` load-bearing for two operator screens

This is the one consequence that is **not** captured by "behaviour-identical today", and it deserves
more prominence than the HAL break.

**Today**, toggling `location_area.usefortransfer` has **no effect whatsoever** on web Transfer
Picking or Club Run — those screens read area *names*. The flag only drives the mobile transfer flow
(`StockunitRepository.java:282-292` → `MobileTransferOrderService.java:246`).

**After this change**, that same flag directly controls what two operator-facing pick lists show.

The flag becomes authoritative in **both** directions, and both are one `UPDATE` away. Enumerated by
working through where the old and new predicates can disagree at all:

| # | Divergence | Old predicate | New predicate | Effect |
|---|---|---|---|---|
| 1 | Area flagged `usefortransfer` whose name is **not** on the old list | excludes | **includes** | **the intended fix** — a renamed or newly-added picking area sources correctly |
| 2 | **`Outbound` flagged `usefortransfer = true`** | excludes | **includes** | ⚠ surfaces `Shipped` — **2,856,635 units, 87% of all stock rows on wineco** — into an operator pick list. `Nirwana` (6,809 SKUs at zero amount) sits behind the same flag |
| 3 | **A whitelisted storage area flagged `usefortransfer = false`** | **includes** | excludes | ⚠⚠ **silent stock loss — the worse direction.** See below |
| 4 | Location with `area_id IS NULL` | excludes (NULL) | excludes (NULL) | identical — three-valued logic degrades the same way for both |
| 5 | An area **renamed to** `'users'` | includes | includes | identical |

**Case 3 deserves more alarm than case 2, and an earlier draft of this plan missed it entirely.**
Setting `usefortransfer = false` on a stocked storage area is inert today — the old code reads names
— but after this change it silently removes that area's stock from both pick lists. Measured on
`dev_wh01_om1`:

| Area (all currently `usefortransfer = true`) | Locations | Units that would vanish |
|---|---|---|
| `Storage and Replenish` | 415 | **246,883** |
| `Inbound` | 13 | **88,198** |
| `Storage and Picking` | 2,137 | **62,797** |
| `Deep Storage`, `Storage Picking and Replenish (from)` | 0 | 0 |

That is **397,878 units on one tenant**, disappearing with no error and no warning — *precisely the
failure mode this ticket exists to prevent*, merely triggered by a different lever. The refactor does
not create that class of failure; it **moves the trigger** from "rename an area" to "clear a flag".
Whether that is a net improvement is a real judgement call, and the honest answer is yes: a flag
named `usefortransfer` is a far more discoverable and intentional control than an undocumented
string list buried in a repository, and case 1 (the fix) is the common real-world event while cases
2–3 require a deliberate administrative act.

**How reachable is it?** Measured:

| Path | Reachable? | Detail |
|---|---|---|
| Web UI Master Data → Functional Area | **read-only** | `wms2-web-ui/components/masterData/location/functionalArea/functionalArea.vue:85-86` renders `usefortransfer` through `makeYesNo(...)`; there is no `v-switch`, no edit dialog, and no save/PATCH action on that screen |
| HAL CRUD endpoint | **yes** | `LocationAreaRepository.java:11-12` is `@RepositoryRestResource(collectionResourceRel = "locationArea", path = "locationArea")` extending `CrudRepository`, with no `exported = false` → `PATCH /locationArea/{id}` can set the flag |
| Direct DB / provisioning | **yes** | this is how tenant onboarding seeds the flags today |

So it takes a deliberate API call or a DB update, not a UI misclick — the risk is **bounded, not
absent**. It is nonetheless the correct trade: the whole point of the ticket is to make a documented
capability flag authoritative instead of a hand-copied string list. Making it authoritative means it
now matters.

**Actions taken by this plan:** the Javadoc in §3.1 states the coupling at the query; manual rows
**M10** (case 2) and **M11** (case 3) exercise both dangerous toggles explicitly, so each is observed
once, on purpose, rather than discovered in production; and this section is called out for the
reviewer as the plan's most consequential trade.

**Not done, deliberately:** no guard clause excluding `Outbound` by name. Adding one would
re-introduce exactly the name-matching this ticket removes, and would silently override an explicit
administrative decision. If the reviewer wants the flag constrained, that belongs in the Master Data
layer (validation on write), not buried in a sourcing query — raised as §10 Q6.

### 6.2 What does NOT change

- The lane-scoped branch of both flows — `getBatchLocationsByItemIdAndLaneName` is untouched.
- The `staginglane` and Clearing disjuncts — byte-for-byte identical.
- The `LEFT JOIN` — retained for NULL-area safety.
- All carrier-traversal, client filtering, and zero-amount filtering downstream of the query.
- `StockunitRepository.getStockUnitItemIdAndNotLocked` and the entire mobile transfer flow.
- `WmsConstants` — no constant added, renamed, or deleted (§3.3).
- The 2,143 units the ticket lists as invisible today (`Damaged` 420, `Palletizing` 786,
  `Packaging` 668, `FinishedPicking` 252, `Gate_01` 14, `TransferLane01/02` 3). All sit in `Outbound`
  or `Default`, neither `usefortransfer` — so **the flag swap preserves the exclusion**. That this is
  preserved rather than incidentally changed is a deliberate outcome; whether it *should* change is
  §10 Q2, a product question for the BA.

---

## 7. Testing Strategy

### 7.1 Unit tests — the seven that must be updated

Signature change from 3-arg to 2-arg breaks these at compile time:

| # | File | Test method | Line(s) |
|---|---|---|---|
| 1 | `TransferOrderServiceUnitTest` | `shouldReturnUnitLoadsFromAllLocations()` | stub @1119 |
| 2 | `CustomerorderBatchServiceUnitTest` | `filtersBySKUWhenProvided()` | stub @1925, verify @1935, verify-never @1938 |
| 3 | `CustomerorderBatchServiceUnitTest` | `excludesBatchStagingLaneFromResults()` | stub @2080 |
| 4 | `CustomerorderBatchServiceUnitTest` | `skipsUnitLoadsNotBelongingToClient()` | stub @2114 |
| 5 | `CustomerorderBatchServiceUnitTest` | `skipsUnitLoadsWithZeroAmount()` | stub @2148 |
| 6 | `CustomerorderBatchServiceUnitTest` | `getClubLineUnitLoads_shouldFilterOutPosition_whenItemdataMissingFromMap()` | stub @2186, verify @2195, verify-never @2198 |
| 7 | `CustomerorderBatchServiceUnitTest` | `getClubLineUnitLoads_shouldTreatNullStockAmountAsZero()` | stub @2230 |
| 8 | `CustomerorderBatchServiceUnitTest` | `getClubLineUnitLoads_shouldStillSumById_whenItemdataInstancesDiffer()` | stub @2286 |

(Eight stub sites across seven distinct test methods — #2's `verify`/`verify-never` pair sits in the
same method as its stub.)

### 7.2 New tests

**Written by the TDD gate on 2026-08-14 — 12 tests. This supersedes the r3 sketch.**

`src/test/java/net/aim_ai/wms/unit/repo/UnitloadRepositoryTransferableAreasContractTest.java` (new,
10 tests). The plan originally proposed a one-assertion `UnitloadRepositoryUsersAreaConstantTest`;
the gate folded that into a broader **reflection-based contract test** instead.

| # | Test | Asserts | AC |
|---|---|---|---|
| 1 | `MethodSurface.repositoryDeclaresTransferableAreasMethod` | the new method exists | §3.1 |
| 2 | `MethodSurface.transferableAreasMethodTakesTwoParams` | exactly 2 `@Param`; no `locationNameList` | D2 |
| 3 | `MethodSurface.oldNamedLocationsMethodIsRemoved` | old method **deleted**, not deprecated | D5 |
| 4 | `Predicate.queryFiltersByUsefortransferFlag` | `area.usefortransfer = true` in the `@Query` | §1 |
| 5 | `Predicate.queryRetainsUsersAreaDisjunct` | `area.name = 'users'` present | D1 |
| 6 | `Predicate.queryNoLongerMatchesAreaNameList` | `:locationNameList` gone (with a non-blank precondition) | §3.1 |
| 7 | `Predicate.usersAreaConstantMatchesQueryLiteral` | `AREA_USERS_NAME` == `"users"` — **standing guard, passes today by design** | D1 |
| 8 | `LoadBearingClauses.queryRetainsStaginglaneDisjunct` | `lo.staginglane = true` survives | §2.4 step 4 |
| 9 | `LoadBearingClauses.queryRetainsClearingLocationDisjunct` | `lo.id = :clearingLocationId` survives | §2.1 |
| 10 | `LoadBearingClauses.queryRetainsLeftJoinOnLocationArea` | `LEFT JOIN` not switched to `INNER` | §2.4 step 3 |
| 11 | `TransferOrderServiceUnitTest…GetTransferLineUnitLoads.getTransferLineUnitLoads_shouldSourceViaTransferableAreasMethod_whenNotLaneOnly` | Transfer reaches the shared method, **both args pinned by value** | **AC5** |
| 12 | `CustomerorderBatchServiceUnitTest…GetClubLineUnitLoads.getClubLineUnitLoads_shouldSourceViaTransferableAreasMethod_whenNotStagingOnly` | Club reaches the **same** method, **both args pinned by value** | **AC5** |
| 13 | `TransferOrderServiceUnitTest…getTransferLineUnitLoads_shouldResolveClearingOnce_acrossMultiplePositions` | two positions → **one** `getClearing()` | §3.5 |
| 14 | `CustomerorderBatchServiceUnitTest…getClubLineUnitLoads_shouldResolveClearingOnce_acrossMultipleSkus` | two SKUs → **one** `getClearing()` | §3.5 |

**Why reflection for tests 1–10.** This is a repository *signature* change: any test naming
`getBatchLocationsByItemIdAndTransferableAreas` directly would not **compile** until the production
change lands, and a test that cannot compile is broken scaffolding, not a failing test. Reading the
interface reflectively lets the gate compile today and fail today for the right reason.

**Tests 11–12 were converted to ordinary `verify(...)` at PR review (2026-08-14).** The gate wrote
them the same way as 1–10 — inspecting Mockito's invocation record by method *name* — for the same
compile-order reason. Once the production change landed that constraint expired, and the name-only
form was strictly weaker in two ways:

- It skipped the **arguments**. `itemDataId` and `clearingLocationId` are both `Long`, so transposing
  them is invisible to the compiler and would silently empty the Available Inventory list on both
  screens. Confirmed by experiment: with the two arguments swapped in production, the name-only form
  stayed green while the converted form fails on both halves.
- Each carried a `.doesNotContain("getBatchLocationsByItemIdAndNamedLocations")` assertion that was
  **vacuous** — a method absent from the interface can never appear in an invocation record, so it
  could not fail under any edit. Test 3 already asserts that deletion structurally, and is the only
  place that needs to name the old method.

Verify row `N1b`'s comment was updated to match: only the contract test quotes `OLD_METHOD` now.

**What tests 4–10 do and do not prove.** `@Query` is retained at runtime, so they pin the SQL
**text** — catching a typo'd column, a dropped disjunct, or a `LEFT`→`INNER` join change. They do
**not** execute the SQL. This is real coverage the r3 plan did not credit, but it is *string-level*,
equivalent in power to the verify script while running inside CI. A semantically wrong but textually
plausible query still passes here and fails on first request. §7.4 stands.

### 7.3 Manual Test Plan (mandatory — this is where the real proof lives)

| # | Scenario | Environment | Steps | Expected result | Pass/Fail |
|---|---|---|---|---|---|
| M1 | **Set-identity re-proof after implementation** | wineco dev (`dev_wh01_om1`) + hydra UAT | Re-run the §2.4 step-2 `EXCEPT` differential against the deployed build; additionally diff per-SKU counts | `only_in_old = 0` and `only_in_new = 0`; per-SKU diff empty. Ticket AC1 | |
| M2 | Transfer Picking Available Inventory renders | wineco dev, web UI | Open a transfer order, view Available Inventory for a SKU with stock in `Storage and Picking` | List renders, same rows and quantities as the pre-change build. Catches a malformed native query (§5.2 risk) | |
| M3 | Club Run Available Inventory renders | wineco dev, web UI | Open a club run, view the item list for a stocked SKU | As M2 | |
| M4 | **Renamed area still sources** — the regression actually being prevented | wineco dev, DB + UI | `UPDATE location_area SET name = 'Main Pick Module' WHERE name = 'Storage and Picking';` re-open M2's screen; **then roll back the rename** | Stock still listed. On the pre-change build the same rename empties the list. Ticket AC2 | |
| M5 | `users` locations still appear | wineco dev | Pick a SKU with stock in a `users` location (2,604 units / 5 locations on this tenant); view Available Inventory | User-held stock listed. Ticket AC3 | |
| M6 | Staging-lane stock still appears | wineco dev | View a SKU staged on a lane (all 20 lanes are in `Outbound`) | Lane stock listed — guards §2.4 step 4 | |
| M7 | `Shipped` and `Nirwana` still excluded | wineco dev | Confirm no `Shipped` (2,856,635 units) or `Nirwana` rows appear | Absent. Ticket AC4 | |
| M8 | Second picking area is picked up automatically | wineco dev, DB + UI | `INSERT` a new area with `usefortransfer = true`, move one location into it, view the screen; **then roll back** | Stock listed **without any code change** — demonstrates the capability the refactor buys | |
| M9 | Mobile transfer unaffected | wineco dev, mobile UI | Run a mobile transfer for a SKU | Behaviour unchanged — guards the §10 Q1 boundary | |
| M10 | **Dangerous toggle, direction 1** — §6.1.1 case 2 | wineco dev, DB + UI | `UPDATE location_area SET usefortransfer = true WHERE name = 'Outbound';` open Transfer Picking for a SKU with `Shipped` stock; **then roll back immediately** | `Shipped` stock **appears** — confirming the flag is now authoritative for this screen. Roll back and re-run M7 to confirm exclusion is restored | |
| M11 | **Dangerous toggle, direction 2 — the worse one** — §6.1.1 case 3 | wineco dev, DB + UI | `UPDATE location_area SET usefortransfer = false WHERE name = 'Storage and Replenish';` open Transfer Picking for a SKU stocked there; **then roll back immediately** | That area's stock **disappears** with no error (246,883 units on this tenant). Confirms the trigger for silent stock loss has moved from "rename an area" to "clear a flag" — a known, accepted consequence, not a regression. Roll back and re-run M2 | |

M4 and M8 are the two rows that prove the *point* of the ticket; M1 is the row that proves it was
free. None of them can be automated today (§7.4).

### 7.4 Automated coverage — the honest position

**The SQL predicate change has no automated coverage whatsoever.** Evidence:

- `src/test/java/net/aim_ai/wms/unit/repo/UnitloadRepositoryTest.java` is annotated
  `@Disabled("Pre-existing env issue: landlord datasource not configured (SBDEV-2099 env skip)")`,
  contains **one** test, and does not reference this query.
- Every test that names the method is a **Mockito stub** — `unitloadRepository` is a mock, so the
  `@Query` string is never parsed by Hibernate or executed against a database.
- The v2 Testcontainers integration lane is broken under **SBDEV-2217**, with many ITs `@Disabled`.
- There is **no startup safety net either**: `spring.jpa.hibernate.ddl-auto=none`
  (`application.properties:70`) and native `@Query` strings are not parsed at bootstrap. A malformed
  query reaches production and fails on first operator request (§5.2).

**Consequences the reviewer must accept explicitly:**

1. Ticket ACs 1–4 (set identity, renamed area, `users`, `Shipped`/`Nirwana`) **cannot** be satisfied
   by an automated test in this repo today. They are carried by §7.3 M1, M4, M5, M7.
2. AC5 (both flows share one method) **can** be, and is — §7.2.
3. A green `mvn test` proves the code **compiles and wires correctly**. It does not prove the SQL is
   valid, let alone correct. A typo in the native query would pass the entire suite and fail on the
   first real request.

**What is deliberately not done:** writing an IT that is born `@Disabled` under `TODO(SBDEV-2217)`.
It would add the appearance of coverage without the substance. If the reviewer prefers that shape as
a marker for when SBDEV-2217 is fixed, it is a small addition — flagged as §10 Q3.

**Is there a remedy? Not a cheap one — and r3's proposed remedy did not survive inspection.**
Option G (§9.2) appeared to fix this by moving the area decision into a testable service helper. On
examination it does not: G still ships **unvalidated native SQL** for the `Unitload` query, so the
"malformed predicate reaches an operator" hazard is untouched, and the helper it makes testable is
near-tautological glue. G is **not** the answer to this section — see §9.2 and Q7, recommendation A.

The honest position is that this gap is **structural to the repo**, not to this change: with
SBDEV-2217 unresolved there is no lane that executes native SQL at all. It is accepted here rather
than solved, and carried by the §7.3 manual rows. The genuine fix — a shared service method taking
only `itemDataId`, keeping the zero-knob guarantee while making composition testable — is described
at the end of §9.2 and is a follow-up, not a prerequisite.

### 7.5 Horizontal Scalability Validation (mandatory for v2)

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state introduced | **No** | Stateless read; no field, no static, no ThreadLocal added |
| 2 | Connection-pool math changed | **No** | Same one query per SKU as today; no new datasource or query count |
| 3 | Scheduled job affected | **No** | Path is request-scoped only; not reachable from any `@Scheduled` |
| 4 | Long transaction introduced | **No** | Read inside the callers' existing boundaries; no boundary added or widened |
| 5 | Request affinity required | **No** | Any replica can serve; no session state |
| 6 | Retry / idempotency | **N/A** | Pure read, naturally idempotent |
| 7 | Tenant context propagation | **No change** | Routes through the existing tenant datasource as before |
| 8 | Distributed lock correctness | **N/A** | No lock taken or needed |
| 9 | Cache invalidation | **No** | Query is not `@Cacheable`; `LocationArea` is not a cached type per `wms2-caching-strategy.md` |
| 10 | External notification in transaction | **No** | No OMS / printer / HTTP call on this path |

### 7.6 v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | **N/A** | Returns managed `Unitload` entities exactly as before, into the callers' existing transactional methods. No new lazy-association access. |
| 2 | `tenantTransactionManager` on writes | **N/A** | Read-only change; no new `@Transactional` method introduced |
| 3 | `@Transactional(readOnly=true)` | **N/A** | No new service method added; callers' annotations unchanged |
| 4 | Caffeine cache invalidation | **N/A** | Nothing cached on this path (§7.5 row 9) |
| 5 | Micrometer metrics | **No** | No new flow — the same call at the same frequency; adding a metric would be noise |
| 6 | Jakarta namespace | **N/A** | No new imports of any kind |
| 7 | H2-compatible test SQL | **N/A** | No test executes this SQL (§7.4). `= true` is standard SQL regardless. |
| 8 | `BaseControllerTest` for endpoints | **N/A** | No controller endpoint added or modified |

---

## 8. Rollout Plan

| Step | Detail |
|---|---|
| **Gate** | SBDEV-2951 `wms2-api` PR #157 merged into `develop` (§5.1) |
| Branch | `refactor/SBDEV-2952-transfer-club-usefortransfer-flag` off freshly-fetched `origin/develop` |
| Merge target | `develop` |
| Pre-merge evidence | `mvn test` green (baseline: 2 pre-existing failures on clean `develop` — `OptionalSafetyArchTest`, `MobilePalletizingServiceTest`); `verify-SBDEV-2952-*.sh` → `N pass, 0 fail`; §7.3 M1–M9 recorded |
| Deploy | Code-only. No migration, no sysprop, no seed. DEV auto-deploys on push to `develop`. |
| Release tag | Normal `dev-*` → `qa-*` → `ua-*` progression; no special sequencing |
| Rollback | Plain revert of the single commit. No data or schema state to unwind. |

---

## 9. Alternatives Considered

| Option | Description | Verdict |
|---|---|---|
| **A — chosen** | `area.usefortransfer = true OR area.name = 'users'`, one shared 2-arg method, old method deleted | **Chosen.** Provably set-identical (§2.4); removes the anti-pattern; makes AC5 structural |
| B | Flyway `UPDATE location_area SET usefortransfer = true WHERE name = 'users'`, then drop the name check entirely — fully flag-driven | **Rejected.** The flag has a **second consumer**: `StockunitRepository.getStockUnitItemIdAndNotLocked` → `MobileTransferOrderService.java:246`. Flipping the flag would make the **mobile** transfer screen start sourcing operator-held stock — an unrequested behaviour change that also destroys the single acceptance bar. Purity at the cost of a real regression. |
| C | New dedicated column, e.g. `location_area.usefortransfersource`, seeded from today's six names | **Rejected.** Cleanest semantics and no collision with B's problem, but it is a schema change plus a six-tenant data migration for a preventive ticket with no live symptom. Cost/benefit fails. Revisit only if Q1 (§10) resolves toward "mobile and web must differ permanently". |
| D | Keep the old 3-arg method, add the new one, deprecate | **Rejected** (decision D2). Strictly additive and safest for any unknown HAL consumer, but leaves the exact name-matching query in the tree for the next developer to copy — preserving the anti-pattern this ticket exists to delete. Available as a one-line fallback if the reviewer rejects §6.1. |
| E | Sysprop-gate the new predicate, default OFF | **Rejected.** The standard hedge for behaviour change, but there is no behaviour change to hedge (§2.4). A toggle would institutionalise the dead name list as the "safe" branch and double the test surface. Also, per SBDEV-1666, a service-layer sysprop branch cannot guard a `@RestResource` query anyway. |
| F | Also align mobile transfer to include `users` | **Rejected for this plan** — see §10 Q1. It is a genuine inconsistency, but fixing it *is* a behaviour change, which would forfeit the single clean acceptance bar. Belongs in its own BA-approved ticket. |
| **G** | **Resolve the sourceable area IDs in the service layer**, then pass them to a query whose predicate is just `area.id IN (:areaIds)` | **Genuine contender — not rejected on merit. See §9.2.** It is the only option that meaningfully attacks this plan's biggest weakness (§7.4, four of five ACs manual-only), but it costs the structural AC5 guarantee. Escalated to the reviewer as Q7 rather than decided here. |

### 9.2 Option G in full — the one real challenge to the chosen design

Option A was chosen partly because it is minimal. That is a virtue, but minimality is not the only
axis, and A is weakest exactly where this ticket is most exposed: **the predicate it changes has no
automated coverage and cannot be given any** (§7.4).

**The shape.** Add a derived finder to `LocationAreaRepository` (currently a bare `CrudRepository`
with two `findBy...` methods, `LocationAreaRepository.java:11-19`), compose the sourceable set in a
shared service helper, and reduce the `Unitload` query's area predicate to `area.id IN (:areaIds)`:

```java
// service — one shared helper, unit-testable against a mocked repository
List<Long> sourceableAreaIds() {
    return Stream.concat(
            locationAreaRepository.findByUsefortransferTrue().stream(),
            locationAreaRepository.findByName(WmsConstants.AREA_USERS_NAME).stream())
        .map(LocationArea::getId).distinct().toList();
}
```

**What it buys — corrected in r4, because r3 overstated both headline gains.**

| Claimed gain | Honest assessment |
|---|---|
| ~~**Failure moves from runtime to startup**~~ | ⚠ **Largely false.** Spring Data validates the *derived* finder (`findByUsefortransferTrue`) against the entity metamodel at context load — but the `Unitload` query is **still native SQL**, and native `@Query` is never parsed at bootstrap. The safety net covers the new trivial query, **not the one that can actually be wrong**. A's "a typo reaches an operator, not a build" hazard survives G essentially intact |
| ~~**ACs 2/3/4 become automated**~~ | ⚠ **True but much weaker than it sounds.** `sourceableAreaIds()` is near-tautological — fetch the flagged areas, add `users`, dedupe. A unit test over it largely asserts that `Stream.concat` works. What can genuinely break is the four-way disjunct and the `LEFT JOIN` three-valued semantics, and **G leaves that exactly as untested as A**. Net effect: "untested disjunct" becomes "untested disjunct **plus** a tested list-builder" |
| **The `users` SQL literal disappears** | ✅ genuine — removes the D1 residual coupling and the `UnitloadRepositoryUsersAreaConstantTest` band-aid |
| **The remaining SQL is marginally simpler** | ✅ genuine but minor — `area.id IN (:areaIds)` is slightly harder to get wrong than a four-way disjunct, though both are unvalidated native SQL |

**What it costs.**

| Cost | Detail |
|---|---|
| **AC5's structural guarantee weakens** | A's whole anti-drift argument is that with *no* per-caller argument, the two callers *cannot* diverge. G re-introduces a list parameter — safe only by convention (both callers must use the shared helper), which is precisely the convention that failed and produced this ticket |
| Extra query per request | must be hoisted **outside** the per-position loop at `TransferOrderService.java:317-331`, which today already calls `locationService.getClearing()` once per iteration. Cheap (≈8 area rows) but it is a real code change in a loop this plan otherwise does not touch |
| Behaviour-identity harder to prove | the §2.4 differential was run against SQL predicates. G's set is assembled in Java, so identity now depends on the helper too — a second thing to verify |
| Larger than the ticket asked for | the ticket proposes a predicate swap; G is a small architectural change |

**Assessment — r4, and it reverses r3's framing.** r3 presented this as a close call with G as "the
available remedy" for the coverage gap. Once both of G's headline gains are checked rather than
asserted, **it is no longer close: take option A.**

1. **G does not fix the actual risk.** The hazard is a malformed native predicate reaching an
   operator. G still ships unvalidated native SQL, so that hazard is untouched. The bootstrap
   validation it adds guards a query that was never going to be the problem.
2. **A's anti-drift property is this ticket's real deliverable.** The names are *correct* on every
   tenant today — the defect is that one decision was hand-copied into two call sites and could
   diverge. A removes the knob entirely; G hands it back as a list parameter that is safe only by
   convention, and convention failing is the origin of this ticket.
3. **A stays inside the layer the evidence covers.** The §2.4 differential is a SQL-level proof
   across six databases. G moves part of the decision into Java, so that proof no longer covers the
   whole path and behaviour-identity becomes harder to demonstrate, not easier.

**What would actually be better than both** — and is a follow-up, not a prerequisite: put the helper
**and** the repository call behind one shared service method taking a single `itemDataId`
(e.g. `SourceableStockResolver.findSourceableUnitLoads(itemDataId)`). That keeps A's zero-knob
anti-drift guarantee *and* makes the composition unit-testable, because callers still get no
configuration parameter. It costs a new small component plus a hoisting/caching decision — the area
set is ~8 near-static rows and the codebase already runs tenant-scoped Caffeine, so caching is the
natural answer rather than resolving per position inside the loop at
`TransferOrderService.java:317-331`. Out of proportion for a preventive ticket right now; the right
shape if this area is revisited. Raised as §10 Q7.

### 9.1 Verify script

`sbdocs/9-System/scripts/verify-SBDEV-2952-transfer-club-source-by-usefortransfer-flag.sh`

Positive checks:
1. `UnitloadRepository` declares `getBatchLocationsByItemIdAndTransferableAreas` with exactly two `@Param`s.
2. That `@Query` contains `area.usefortransfer = true`.
3. That `@Query` contains `area.name = 'users'`.
4. That `@Query` still contains `LEFT JOIN location_area`.
5. That `@Query` still contains `lo.staginglane = true` — guards §2.4 step 4.
6. That `@Query` still contains `lo.id = :clearingLocationId`.
7. `TransferOrderService` calls the new method.
8. `CustomerorderBatchService` calls the new method.
9. **Chain-level:** call sites of the new name across `src/main` == **2** — encodes AC5 as a count, not a pair of independent greps.
10. `UnitloadRepositoryUsersAreaConstantTest` exists and asserts against `AREA_USERS_NAME`.

Negative checks:
11. `getBatchLocationsByItemIdAndNamedLocations` absent from the **entire** `src/` tree (main **and** test).
12. `area.name IN (:locationNameList)` absent from `src/main`.
13. `Arrays.asList(AREA_INBOUND_NAME` absent from both services.

Authoring constraints, from prior verify-script incidents:
- Every multi-line perl helper must begin `[ -f "$2" ] || return 1` — the template's helpers **fail
  OPEN** on a missing file and would false-green every assertion about a new file.
- No row may reference an undefined shell function — bash's exit 127 is recorded as an ordinary FAIL
  and is indistinguishable from unimplemented work.
- Use a tempered-greedy gap rather than unbounded `.*?` under `/s` in the positional regexes, so a
  check cannot match a correct construct elsewhere in the file.
- Do **not** assert deletion of the five now-unreferenced `AREA_*_NAME` constants (§3.3).
- **Negative-test the script before trusting it:** replay the pre-change files and confirm it FAILs.
  A "N pass, 0 fail" on the unchanged tree means the script asserts nothing.

**Status: written and proven in both directions (2026-08-13).** 16 checks.

| Test | Tree | Result |
|---|---|---|
| **Negative** | Real pre-change `v2/wms2-api` | **0 pass / 16 fail**, exit 1 |
| **Positive** | Simulated post-change fixture (§3.1–§3.4 applied) | **16 pass / 0 fail**, exit 0 |
| **Adversarial** | Correct method name + a Javadoc naming every asserted token, but the SQL sabotaged back to `area.name IN (...)` with `INNER JOIN` and no `staginglane`/Clearing disjuncts | **11 pass / 5 fail** — R3–R7 all correctly FAIL |

The adversarial run is the one that matters most: it proves the query checks bind to the **SQL**, not
to prose. `method_block_contains` scopes each match to the span from `@RestResource(` through the
signature's terminating `;`, so a Javadoc sitting *above* the annotation cannot satisfy any row —
which is the most likely false-green vector for a plan whose §3.1 deliberately adds a Javadoc naming
all five tokens.

The negative test earned its keep immediately: the first draft passed R3–R7 **on unchanged code**.
The `method_block_contains` helper passed its env vars *after* the `perl -e` script, so perl read
them as input filenames, `$ENV{...}` came back undef, and the block regex collapsed to "match
anything". Five checks were silently vacuous. The helper now sets the variables before `perl` and
`die`s if either is empty. This is the fourth documented instance of a verify row that looks green
and asserts nothing — the negative test is not optional.

---

## 10. Open Questions / Resolved Decisions

### Resolved

**D1 — how to handle the `users` area. → Keep the name literal.**
`usefortransfer = true OR area.name = 'users'`. Rejected setting the flag on the `users` area via
migration, because the flag's second consumer (`MobileTransferOrderService.java:246`) would then
start sourcing operator-held stock on mobile — an unrequested behaviour change (§9 option B). Also
rejected a dedicated new column (§9 option C). Supporting precedent: `UserService.java:80` and
`UtilRestController.java:773` already resolve this area **by name** in production code, so a name
check for `users` is consistent with the codebase rather than a new exception.
**Residual risk, accepted and stated:** renaming the `users` area still breaks sourcing of user-held
stock. The refactor shrinks the name-coupling from six strings to one; it does not eliminate it.

**D2 — the HAL contract. → Drop the parameter, delete the old method, accept the break.**
The endpoint is exported (§2.5) but has no first-party consumer. Recorded as a knowingly-taken
non-additive change in §6.1, with §9 option D as the fallback if the reviewer disagrees.

**D3 — scope of the anti-pattern sweep. → 1 of 1; nothing else to sweep.**
Repo-wide grep (§0.1) finds no second place using area names as a sourceability set predicate.

**D4 (was Q7) — option A or option G. → OPTION A. Approved by Nam, 2026-08-14.**
Both of G's headline gains failed inspection (§9.2): its bootstrap validation guards only a new
derived finder while the `Unitload` query stays unvalidated native SQL, and the helper it makes
testable is near-tautological glue — so G leaves the four-way disjunct as untested as A while giving
back A's structural anti-drift guarantee. A is the plan of record and the design is now **closed**.
The single-argument shared-service shape at the end of §9.2 remains the right follow-up if this area
is revisited; it is not a prerequisite.

**D5 (was Q4) — the HAL contract break. → ACCEPTED. Approved by Nam, 2026-08-14.**
`{basePath}/unitload/search/getBatchLocationsByItemIdAndNamedLocations` is removed rather than
deprecated. Zero consumers in either v2 UI (§2.5); the export was incidental to the repository-wide
annotation, not a designed contract. §9 option D (keep + deprecate) is **not** taken. Residual risk —
an unknown external or manual HAL consumer — is knowingly accepted; it is unprovable from the repo
and judged acceptable. Verify row **N1** ("old method gone from the ENTIRE src tree") therefore
stands as written.

**Both gating questions are now closed. The TDD gate is unblocked.**

### Open

Question numbers are stable and referenced elsewhere in this document, so they are **not** in
priority order. Read this index first:

| Q | Question | Owner | Gates the TDD run? |
|---|---|---|---|
| ~~Q7~~ | ~~Option A or option G~~ → **CLOSED as D4: option A** (Nam, 2026-08-14) | — | ✅ closed |
| ~~Q4~~ | ~~Is the §6.1 HAL break acceptable~~ → **CLOSED as D5: accepted** (Nam, 2026-08-14) | — | ✅ closed |
| Q6 | Should `usefortransfer` be protected at the Master Data layer (§6.1.1) | reviewer / BA | no — separate ticket either way |
| Q3 | Born-`@Disabled` IT as an SBDEV-2217 marker | reviewer | no — additive |
| Q1 | Should mobile transfer source `users` like web does | BA | no — explicitly out of scope |
| Q2 | Should the 2,143 in-process units become visible | BA | no — explicitly out of scope |
| Q5 | When to file the paired v1 ticket (§12) | Nam / reviewer | no — separate ticket |

**Q7 and Q4 are the two that must close before the TDD gate runs.** Everything else can be answered
after implementation without rework.

**Q1 — Should mobile transfer source `users` stock the way web transfer does?** *(Owner: BA)*
Today `MobileTransferOrderService.java:246` sources `usefortransfer` areas and **excludes** `users`,
while web Transfer Picking **includes** it. Same business question, two answers, and this plan
preserves both rather than picking one. **Assumption stated explicitly:** this plan does **not**
change mobile — that was the recommended default and the question was not answered before drafting.
If the BA wants them aligned, it is a separate ticket with its own acceptance bar, because aligning
them *is* a behaviour change (§9 option F).

**Q2 — Should the 2,143 in-process units become visible?** *(Owner: BA — carried from the ticket)*
`Damaged` (420), `Palletizing` (786), `Packaging` (668), `FinishedPicking` (252), `Gate_01` (14),
`TransferLane01/02` (3). All sit in `Outbound` or `Default`, neither `usefortransfer`, so this plan
**preserves** their exclusion. `Damaged` is almost certainly correct to exclude; the in-process
locations are a genuine product question. Flagged, not resolved.

**Q3 — Do we want a born-`@Disabled` integration test as a marker for SBDEV-2217?** *(Owner: reviewer)*
§7.4 argues against it — it would look like coverage without being coverage. Cheap to add if the
reviewer prefers a visible placeholder for when the Testcontainers lane is repaired.


**Q5 — When do we file the paired v1 ticket?** *(Owner: Nam / reviewer)*
§12 establishes that `v1/wms-api` carries the identical query and predicate, reachable from Club Run
only (`v1/.../CustomerorderBatchService.java:960`). Not fixed here, deliberately — v1 needs its own
DB differential against v1 tenant databases before it can claim the same acceptance bar. Recommend
filing after this lands, sharing the base filename per the v1↔v2 pairing convention.

**Q6 — Should `usefortransfer` be protected at the Master Data layer?** *(Owner: reviewer / BA)*
Per §6.1.1 the flag becomes authoritative in **both** directions once this lands, via
`PATCH /locationArea/{id}` on the exported CRUD resource (`LocationAreaRepository.java:11-12`):
setting it on `Outbound` exposes 2.86M units of `Shipped` stock (case 2), and **clearing** it on a
stocked storage area silently removes up to 246,883 units from both pick lists (case 3). Case 3 is
the one that reproduces this ticket's own failure mode under a new trigger.

This plan deliberately adds **no** name-based guard in the query — that would re-create the
anti-pattern it removes. The candidate protections all belong elsewhere and each is its own ticket:
write-side validation on the Master Data layer, `exported = false` on `LocationAreaRepository`, an
audit-log entry when the flag changes, or simply making the flag editable in the Master Data UI
**with a warning** rather than only over HAL. **Recommendation: at minimum, an audit-log entry** — it
is the cheapest thing that turns a silent config change into a traceable one. Flagged so the decision is
explicit rather than implied by silence.


---

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | All callsites enumerated | ✓ §0 rows 1–6 in scope and all covered by §3; rows 7–12 excluded with rationale |
| 2 | Adjacent shapes | ✓ §0.1 sweep — 1 of 1, no sibling instance. `StockunitRepository.java:282-292` is the correct-already precedent, not a defect |
| 3 | Backward compatibility | ✓ §6 table + §6.1 HAL break + §6.2 explicit "What Does NOT Change" |
| 4 | Concurrency | ✓ §7.5 rows 4/6/8 — pure read, no lock, no transaction boundary added, naturally idempotent |
| 5 | Multi-tenant | ✓ §2.4 verified on all six tenant DBs; §7.5 row 7 — routes through the existing tenant datasource unchanged |
| 6 | Error handling | ✓ no new throw path; the query returns a list, empty on no match, as before |
| 7 | DB verified | ✓ `db_verified: true` — §2.4, four query steps across six databases |
| 8 | Observability | **no** — §7.6 row 5: same call at the same frequency on an existing path; a new metric would be noise, not signal |
| 9 | Rollout / migration | ✓ §5.1 prerequisites, §8 — code-only, no Flyway, no sysprop, plain-revert rollback |
| 10 | Test coverage | ✓ §7.1 (7 methods updated), §7.2 (3 new), §7.3 (9 manual rows), and §7.4 states plainly that the SQL itself has none |
| 11 | Cross-version v1↔v2 | ✓ **applicable — v1 has the identical defect, deferred to a paired plan.** See §12 |
| 12 | Alternatives considered | ✓ §9 options B–F rejected with rationale, plus **option G (§9.2), which is NOT rejected on merit** — it is a live reviewer decision (Q7) and the only serious challenge to the chosen design |

---

## 12. Cross-version: v1 carries the identical defect

Checked rather than assumed — and the assumption would have been wrong. `v1/wms-api` has the **same
query with a byte-identical predicate**:

| v1 site | Detail |
|---|---|
| `v1/wms-api/.../repo/jpa/UnitloadRepository.java:108-116` | same method name, same 3-arg signature, same `area.name IN (:locationNameList)` disjunct, same `LEFT JOIN`, same `staginglane`/Clearing disjuncts. (A duplicate copy sits commented out at `:96-106`.) |
| `v1/wms-api/.../service/CustomerorderBatchService.java:960` | the **only** production caller |
| `v1/wms-api/.../model/LocationArea.java:65` | `usefortransfer` exists on v1 too, declared `NOT NULL` at `:36` |
| `v1/wms-api/.../repo/jpa/StockunitRepository.java:220` | v1 **also** already uses `loc_area.usefortransfer = true` — the same precedent as v2 |

**Blast radius differs.** In v1 only **Club Run** reaches this query — v1's `TransferOrderService`
does not call it, so v1 Transfer Picking sources stock by some other path. So the v1 fix is strictly
smaller: one caller, no method-collapse needed, and AC5 (both flows share one method) does not apply.

**Deliberately deferred, not done here.** This plan stays v2-only because the DB evidence in §2.4 was
gathered on v2 tenant databases, and v1's Club Run would need its own before/after differential
against the v1 tenant DBs. Shipping a v1 change on v2's evidence would violate this plan's own
acceptance bar.

**Action:** file a paired v1 ticket sharing this base name
(`SBDEV-####-transfer-club-source-by-usefortransfer-flag`, per the v1↔v2 pairing convention) once
this lands. Tracked as §10 Q5.

---

## 13. Implementation Status

**MERGED 2026-08-15.** PR [#158](https://github.com/SiteBossInc/wms2-api/pull/158) merged into `develop` as **`0cecb44`**, confirmed an ancestor of `origin/develop`. Branch retained, matching repo convention.

> [!warning] **Merged without the second reviewer the PR's own review note asked for.** All six subagent lanes failed to return in the authoring session and round 1 was the same operator, so the ⚠ §6.1.1 risks — `usefortransfer` becoming load-bearing for two operator screens, in *both* directions, and mutable via an unguarded `PATCH /locationArea/{id}` — went to `develop` ungraded by a second pair of eyes. The behaviour differential is strong (0 differing rows at area level across 7 DBs including production), so this is a review-process gap, not a known defect.

| | |
|---|---|
| Repo / branch | `wms2-api` @ `refactor/SBDEV-2952-transfer-club-usefortransfer-flag` |
| Merge commit | **`0cecb44`** (merge commit, branch not deleted) |
| Commit | `25f4ef3` — *Source transfer/club inventory by usefortransfer, not hardcoded area names [SBDEV-2952]* |
| Review commit | `704e003` — *Pin call arguments and resolve Clearing once per call [SBDEV-2952]* (§3.5 + §7.2 #11–14) |
| Base | `origin/develop` @ `02dc7ca` |
| Worktree | `.claude/worktrees/wms2-api/SBDEV-2952` (retained for review feedback; `archive-plan` owns removal) |
| Diffstat | Cumulative vs base `02dc7ca`: 6 files, **+402/−45**; production only **+52/−11** across 3 files (25 of those added lines are the rationale Javadoc, 9 the §3.5 comments — 18 lines of actual code). At `25f4ef3` alone it was +313/−45 / production +44/−12. |

### Results

| Gate | Result |
|---|---|
| `UnitloadRepositoryTransferableAreasContractTest` | **10/10 pass** |
| Targeted (3 classes) | **163/163 pass** (161 at first submission, +2 from the §3.5 review addendum) |
| Full unit suite | **5036 run, 2 failures** = documented clean-`develop` baseline (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`); both re-run in isolation and fail there too, neither implicates the touched files |
| `mvn clean compile` | OK |
| `verify-SBDEV-2952-...sh` | **Result: 19 pass, 0 fail** (baseline before implementation: 2 pass / 15 fail; against the pre-§3.5 commit `25f4ef3`: 17 pass / 2 fail, `H1`+`H2` red) |

### Acceptance criteria — 4 of 5 executed live, not merely reasoned

§7.4 predicted ACs 1–4 would be manual-only. Live DB access let me execute four of them during implementation:

| AC | Result |
|---|---|
| **AC1** per-SKU set identity | ✅ 18,935 (SKU, unit-load) pairs each side, **empty symmetric difference both directions**, 2,682 SKUs, wineco dev |
| AC2 renamed area still sources | ⏳ manual row M4 — not executed |
| **AC3** `users` still appears | ✅ 207 rows / **2,604 units** — matches the ticket's own figure exactly |
| **AC4** `Shipped` + `Nirwana` excluded | ✅ **0 rows each** |
| **AC5** both flows share one method | ✅ 2 wiring tests + verify `C3` (exactly 2 production call sites) |
| M6 staging lanes still sourced | ✅ 198 rows / 28,381 units — proves the `staginglane` disjunct still carries them |

### §5.2 risk retired

The plan rated the runtime hazard on the basis that a malformed native query fails on an operator's first request with no startup safety net. **The implemented SQL was executed against a live tenant**: it parses and plans, and PostgreSQL reports
`Filter: (lo.staginglane OR (lo.id = $1) OR area.usefortransfer OR ((area.name)::text = 'users'::text))`
with a **Hash Left Join** — confirming the disjunct's parenthesisation, the flag predicate, the `users` literal, and LEFT-join preservation against the real parser. That hazard is closed for this change.

### Landmines found during implementation that the plan did not predict

1. **The gate's own contract test could not name the new method directly** — a signature change means any conventional test fails to *compile* before implementation, and non-compiling is not "failing". Solved with reflection over the interface plus Mockito invocation-record inspection by method name.
2. **Two verify rows would have been permanently red.** `T1/T2` named a test file the gate never created (the plan proposed `UnitloadRepositoryUsersAreaConstantTest`; the gate wrote a broader contract test), and `N1` grepped the whole `src` tree for the old method name — which the gate's own tests must quote in order to assert its absence. Split into `N1` (src/main) + `N1b` (no dot-call in src/test). Both are the "row naming an undefined thing reads as an honest FAIL" failure mode.
3. **Whitespace normalisation hides seam defects.** The contract test normalises the `@Query` string, so a missing space producing `:clearingLocationIdOR` would still satisfy a `contains(":clearingLocationId")` assertion. Checked separately by printing the runtime-concatenated SQL and asserting balanced parens + no glued tokens.
4. **Mockito strict stubs are enforced here** (`MockitoExtension` via `BaseUnitTest:18`) — proven by injecting a deliberately-unused stub and observing `UnnecessaryStubbing`. So 161/161 green is real evidence of no dead stubs rather than an assumption.
5. `Arrays` and the `AREA_*` constants became unused in both services, but both files import via **wildcards**, so nothing dangles — no import cleanup was needed.

### ⚠ No independent review

All six subagent lanes spawned across authoring and execution — enumeration, architect, critic, verifier, code-reviewer (×2) — went idle without returning output, including after explicit forced-answer requests. Every check they were assigned was re-run directly instead, and the conformance table in the PR body is **self-produced**. It is evidence-backed (live SQL execution, real set differential, mutation-proven suite) but it is not a second pair of eyes. **PR review is the independent lane**, by the user's explicit decision.

### Done 2026-08-15

Merged (`0cecb44`, verified on `origin/develop`) · ClickUp `pr submitted` → **`on dev`**.

### Not done

Archive · manual rows **M2, M3, M4, M8, M9, M10, M11** · the paired v1 ticket (§12, Q5) · the second human review the PR asked for.

⚠ **M4 is the row that proves the point of this ticket** — rename `Storage and Picking` and confirm stock is *still* listed, then roll back. On the pre-change build that rename empties the list; that is the regression being prevented, and nothing automated covers it.

---

## ADR

**Decision.** Replace the hardcoded six-area-name whitelist in
`UnitloadRepository.getBatchLocationsByItemIdAndNamedLocations` with
`location_area.usefortransfer = true OR area.name = 'users'`, rename the method to
`getBatchLocationsByItemIdAndTransferableAreas`, drop its now-constant third parameter, and route
both Transfer Picking and Club Run through that single method.

**Drivers.**
1. Correctness under customer configuration change — a renamed or added picking area currently causes
   silent, unsignalled stock loss on two operator screens.
2. Consistency with the axis this system already uses — `useforreplenish` for replenishment
   (SBDEV-2854), `usefortransfer` for mobile transfer (`StockunitRepository.java:291`).
3. Structural enforcement of "both flows agree" — a shared no-argument predicate cannot drift the way
   two hand-copied lists can.

**Alternatives considered.** Flag-migration for `users` (B); dedicated new column (C); additive
deprecation of the old method (D); sysprop gate (E); aligning mobile in the same change (F) — all
rejected in §9 with rationale. **Option G (§9.2)** — service-layer resolution of the sourceable area
IDs — was a live contender in r3 and is **rejected in r4 on inspection** (Q7).

**Why chosen.** A is the only option that removes the anti-pattern while remaining provably
behaviour-identical on every current tenant (§2.4), with no schema change, no data migration, and no
new configuration surface. Against option G specifically: G's two claimed advantages did not survive
checking — its bootstrap validation guards only a new *derived* finder while the `Unitload` query
remains unvalidated native SQL, so the real hazard is untouched; and the helper it makes testable is
near-tautological, leaving the four-way disjunct and `LEFT JOIN` semantics as untested under G as
under A. G meanwhile gives back A's structural guarantee that the two flows cannot drift — this
ticket's actual deliverable — and moves part of the decision outside the layer the §2.4 six-database
differential covers. The better long-term shape is neither A nor G but a shared single-argument
service method (end of §9.2): a follow-up, not a prerequisite.

**Consequences.**
- *Positive:* new `usefortransfer` areas are picked up with no code change; area renames stop causing
  silent stock loss (except `users` — D1 residual); the two flows can no longer diverge.
- *Negative:* **`usefortransfer` becomes load-bearing for two operator screens where it was
  previously inert (§6.1.1)**, in **both** directions — flagging `Outbound` exposes 2.86M units of
  `Shipped` stock, and *clearing* the flag on a stocked storage area silently removes up to 246,883
  units, reproducing this ticket's own failure mode under a new trigger. Both are reachable via the
  exported `locationArea` CRUD endpoint, bounded by the absence of a UI edit affordance, and
  deliberately unguarded because a name-based guard would re-create the anti-pattern being removed.
  **This is the most consequential trade in the change — not the HAL break.** The trade is judged
  favourable because a discoverable flag beats an undocumented string list, and the fix case is the
  common real-world event while both hazard cases require a deliberate administrative act.
- *Negative:* one HAL endpoint signature is removed without deprecation (§6.1); a name coupling on
  `users` remains, mitigated but not eliminated; and the change ships with **no automated proof of
  the predicate itself** (§7.4), leaning on manual rows M1/M4/M5/M7/M10.
- *Negative:* v1 keeps the identical defect until the paired ticket is filed (§12, Q5).

**Follow-ups.** §10 Q1 (mobile/web `users` divergence — BA), Q2 (in-process units visibility — BA),
Q3 (placeholder IT for SBDEV-2217 — reviewer).
