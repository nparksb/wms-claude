---
title: "WMSv2: SKU-level Default Putaway Location — configuration UI and the per-SKU effective-destination read"
ticket: "SBDEV-2643"
ticket_url: "https://app.clickup.com/t/868keru0b"
type: "feature"
priority: "urgent"
status: "draft"
project: [wms2]
version: "v2"
db_verified: true
requester: "Scott Dalton"
assignee: "Nam Park / David Oppenheim"
created: "2026-08-07"
updated: "2026-08-09"
revision: 4
depends_on:
  - {ticket: SBDEV-2732, status: "draft — NOT STARTED, nothing of it is in merged code",
     note: "Owns the resolver, PutawayConfigService.setSkuDestination, PUT /putawayConfig/sku/{id},
       PutawayDestinationQueryService, PutawayDestinationValidator, putaway_config_audit, V2.2.11
       (DROP NOT NULL), stop-seeding, LocationPicker.vue, and — per r2's Q5/D12 hand-over — the
       eligibleLocations read. Verified 2026-08-07:
       zero matches in v2/wms2-api/src and v2/wms2-web-ui for PutawayDestinationResolver,
       PutawayConfigService, PutawayConfigController, PutawayDestinationQueryService,
       putaway_config_audit, LocationPicker.vue, getPutawayDestination. 10 of this plan's 12 ACs are
       blocked on its Phase 1-API; AC4 and AC9 are hard-blocked on V2.2.11 specifically."}
  - {ticket: SBDEV-2731, sha: 6bc709a, status: "MERGED",
     note: "wms2-api #133 @ 6bc709a + wms2-web-ui #39 @ 4ce39a1, both on develop. Supplies the
       configured-vs-default display precedent and the wording constants this plan reuses verbatim
       (receivingForm.vue:221-222), plus the neutral unitloadTypeNotPermittedOnLocation message the
       receive-time backstop already renders."}
related:
  - "[[SBDEV-1938]]"
  - "[[SBDEV-2642]]"
  - "[[SBDEV-2731-alternate-putaway-location-not-honored-receiving]]"
  - "[[SBDEV-2732-configurable-default-putaway-location-hierarchy]]"
  - "[[SBDEV-2796]]"
  - "[[SBDEV-2821]]"
  - "[[SBDEV-2863]]"
  - "[[wms2-it-harness-broken-sbdev-2217]]"
db_verified_note: >
  Verified 2026-08-07 against hydra/nywh DEV (`wms2-hydra-dev2` = `wh01_hydra_v2`, tunnel :25060).
  ALL READS SELECT-ONLY — no DDL, no DML, no session settings changed. "HMG" is the former name of
  the Hydra `nywh` warehouse, so the ticket's "Example Warehouse: HMG" resolves to this tenant.

  MEASURED (each number reproduced independently of the analysis lane):
  `itemdata` = 2,720 rows; `count(DISTINCT putawaylocation_id)` = **1**; rows with
  `putawaylocation_id IS NULL` = **0**; `information_schema.columns.is_nullable` for
  `itemdata.putawaylocation_id` = **NO**; `location` = **666**; columns named `location.active` = **0**;
  tables named `putaway_config_audit` = **0**.

  SKU-SCOPE ELIGIBILITY under SBDEV-2732's predicate set (P2.2 `entity_lock = 0` AND P2.3 no lane flag
  AND P2.4 `useforgoodsin OR useforstorage` AND P2.5 no `fix_location_assignment.assignedlocation_id`
  AND P2.7(c) not in a `useforpicking` area): total 666 → unlocked 666 → no-lane 644 →
  goodsin-or-storage 603 → **92 eligible (13.8%)**. Rejected by P2.7(c): **511 in a `useforpicking`
  area**. Rejected by P2.5: **154 fix-assigned**.

  THE FINDING THAT DRIVES D1: by `location_type.sltname` (the column is `sltname`, NOT `name`), the
  tenant has **496 flowbins, and all 496 are in a `useforpicking` area**; 154 of them are fix-assigned.
  So P2.7(c) rejects **every flowbin in the warehouse**. SBDEV-2731's own PRD evidence records the
  reported ICE PACK location as id 52075 with `type_id = 2` (`flowbin`) — i.e. the one location this
  ticket exists to configure is rejected by 2732's SKU-scope predicates.

  ⚠ **r3 (2026-08-08) IS THE CURRENT CONCLUSION — the r2 text below is SUPERSEDED.** The measurement is
  unchanged and still correct; what keeps changing is what 2643 does about it.

  **r3: 2643 OFFERS the 511 pick-face locations, `ICE PACK` among them.** 2732 answered Q12 as option
  (iv-b) on 2026-08-08: configuration is widened at every scope, `skuWriteRejectsPickFaceDestination`
  is DELETED, and a SKU-scope pick-face write is LEGAL. What is refused is the *placement*, at run time.
  Tier 1 is exempt from 2732's P2.7 rule (e), so flowbins are offerable at this plan's scope.
  **One exclusion survives:** a flowbin fix-assigned to a *different* SKU (2732's rule (f), added
  2026-08-09) — 1,344 of 2,555 candidate rows on `wms2-wineco-dev`, 154 of 603 on `wms2-hydra-dev2`.
  See §10.1 D1 and §15.

  ~~r2 (2026-08-07): a SKU-scope pick-face WRITE is an unconditional 422 that 2732 ships a unit test to
  enforce (`skuWriteRejectsPickFaceDestination`, 2732 `:2211`), so offering those 511 rows would offer
  rows that cannot be saved; 2643 therefore offers only the 92 eligible locations.~~ **That test no
  longer exists and the cited line no longer resolves.**

  ⚠ **DEPENDENCY NOW SATISFIED:** SBDEV-2821 **merged to `develop` 2026-08-09** (`wms2-api` PR #135,
  merge `fd90487`), so putaway can surface a configured destination. The r2 text's hand-off of tier-1
  pick-face relaxation to 2821 is complete.
tags:
  - plan
---

# WMSv2: SKU-level Default Putaway Location — configuration UI and the per-SKU effective-destination read

**Ticket:** [SBDEV-2643](https://app.clickup.com/t/868keru0b)
**Project:** wms2 (`wms2-api` + `wms2-web-ui`) | **Version:** v2 | **Type:** feature
**Priority:** urgent
**Status:** draft
**Date:** 2026-08-07

> **This plan is a THIN CONSUMER STACKED ON SBDEV-2732.** 2732 owns the resolver, the validated
> writer, the write endpoint, the read facade, the audit table, `V2.2.11`, stop-seeding, and
> `LocationPicker.vue`. **SBDEV-2643 ships ZERO migrations.** Its own deliverables are six small,
> well-bounded items (D-A … D-F, §3) plus the SKU edit surface. Everything else it needs belongs to
> 2732, and **as of 2026-08-07 none of 2732 exists in merged code** — its plan is `status: draft`.
>
> Read §5.1, §8 and **§3's blocking banner** before writing a line of code. Three items are
> implementable **today** — A0's detector, `B1-pre`, and A1 (in that order, §5.1 row 4) — plus most of
> B1; everything else waits on 2732's Phase-1 merge landing on `develop`.
>
> **⚠ REVISION 2 (2026-08-07) REVERSED D1 — AND REVISION 3 (2026-08-08) REVERSES IT BACK.**
>
> **r1** offered pick faces behind an advisory warning. **r2** enforced 2732's P2.7(c) and offered only the
> 92 genuinely-eligible locations, on the sound reasoning that a SKU-scope pick-face write was an
> unconditional 422 which 2732 shipped a test to enforce — so r1 would have offered ~511 unsavable rows.
>
> **r3: that premise no longer holds.** SBDEV-2732 answered **Q12 as option (iv-b)** on 2026-08-08.
> Configuration is now **widened at every scope**: `skuWriteRejectsPickFaceDestination` is **deleted**, and
> a SKU-scope pick-face write is **legal**. What is refused is the *placement* — receiving diverts a
> pick-face destination to the standard lane and putaway routes it (2732 §5.2 step 15). Three consequences
> for this plan:
>
> 1. **D1 returns to r1's shape** — offer pick faces, with an advisory rather than an exclusion. r2's
>    exclusion would now hide **511 savable locations**, including `ICE PACK` itself, which is the
>    configuration the parent bug is about.
> 2. **Tier 1 is exempt from 2732's P2.7 rule (e).** Rule (e) bars `flowbin`-type destinations at
>    **merchant and warehouse** scope only (putaway auto-creates a `FixLocationAssignment` binding the
>    location to the first SKU, which breaks multi-SKU scopes). **This plan is SKU scope, so flowbins are
>    offerable here.**
> 3. **P1 must be skipped for `flowbin` destinations at write time** (2732 §3.4c). Without that, `ICE PACK`
>    is still unsavable — flowbin permits only `PickLocation` and the SKU's default type is `Case`. **This
>    plan depends on that exemption shipping; if 2732 implements P1 unguarded, the picker will offer rows
>    the backend still rejects and r2's objection becomes correct again.**
>    ⚠ **NARROWED 2026-08-09 by review of 2732:** the skip predicate is **`sltname == 'flowbin'` ONLY**, not
>    the `useforpicking OR flowbin` form r3 was drafted against. That does not change this plan's dependency
>    — `ICE PACK` is a flowbin either way — but 2643 must not restate the wider predicate anywhere.
>
> **⚠ 4. ADDED 2026-08-09, POSTDATES r3 — 2732 gained P2.7 rule (f), and it changes what the picker must
> exclude.** Tier 1 is exempt from rule (e), but **not** from rule (f): a flowbin whose
> `FixLocationAssignment` belongs to a **different** SKU must **not** be offered, because such a row saves
> cleanly and then fails at *every* putaway (`scannedLocationHasDifferentFixedAssignment`) with nothing
> naming the configuration that caused it. **This is the majority of flowbins, not an edge case** — 1,344 of
> 2,555 candidate rows on `wms2-wineco-dev` (53%), 154 of 603 on `wms2-hydra-dev2` (26%).
> **Consequences for this plan:** the exclusion set is **never empty**, so r3's claim that *"on HMG
> production the exclusion set is empty — every candidate qualifies"* no longer holds; and `blockingReason`
> needs a value distinguishing own-from-foreign, which is **2732's enum to extend, not this plan's**
> (MUST-4).
>
> **The advisory text matters.** A pick-face destination does not receive stock directly — it is routed via
> putaway, so the operator performs one putaway scan. Say that, rather than implying immediate placement.
>
> **✅ RE-MEASURED 2026-08-09 (SELECT-only).** r2's arithmetic (603 goods-in-or-storage → **92 eligible**,
> **511 excluded by P2.7(c)**) was computed with P2.7(c) as an absolute reject. Those two numbers sum
> exactly to the population — **P2.7(c) was doing ALL of the exclusion.** Under (iv-b) it is dropped, so at
> SKU scope the picker's exclusion set collapses to the remaining predicates (locked, lane flags, area):
>
> | Tenant | goods-in-or-storage | of which in a picking area | **eligible at SKU scope under (iv-b)** |
> |---|---|---|---|
> | `wms2-wineco-dev` (tester's env) | — | — | **2,555** of 2,739 total locations |
> | `wsl-wineco-uat` | 2,704 | **2,219** | **2,694** |
> | `wms2-hydra` (HMG PRD) | 229 | **191** | **229** |
>
> **On HMG production the exclusion set is now empty** — all 229 qualify. On wineco UAT r2's rule would
> have hidden **2,219 of 2,704** locations, about 82% of the picker.
>
> **r2's own population (603) matches none of these three tenants**, so its figures were measured somewhere
> else again — treat them as unusable rather than merely stale, and re-derive on whichever tenant this ships
> against. The `db_verified` note needs the same treatment.
>
> **Tier 1 is exempt from rule (e)**, so flowbins are offerable here; rule (e) bars them at merchant and
> warehouse scope only.
>
> **Read §15 (revision log) before §10.1, and §14 for the principles this is graded against.**

> **Repos verified at:** `v2/wms2-api` `6bc709a` (branch `develop`), `v2/wms2-web-ui` `4ce39a1`
> (branch `develop`) — both are the SBDEV-2731 merge. Every `file:line` in this document was read at
> those SHAs. Claims that could not be confirmed are marked **UNVERIFIED** inline.

---

## 0. Affected Sites

Enumerated 2026-08-07 by grep against disk, not from memory: `putawaylocation|putawayLocation|PutAwayLocation`
(case-insensitive) across `v2/wms2-api/src` and `v2/wms2-web-ui` (excluding `node_modules`, `.nuxt`,
`cypress`), plus the SKU-screen store and every component that renders SKU details.

Every **out-of-scope** row keeps its ownership marker. `no — owned by SBDEV-2732 <section>` means the
construct is real and needs changing, but **2732's PR changes it** — do not touch it here, and do not
re-discover it during implementation.

### 0.1 API — `v2/wms2-api/src/main/java/net/aim_ai/wms/`

| # | File:line | Construct | In scope this plan? | Phase |
|---|---|---|---|---|
| 1 | `service/ItemdataService.java:119-174` | `getItemdataDetails` — the SKU details map | **YES — primary API change** | A1 |
| 2 | `service/ItemdataService.java:166-171` | `putawayLocation` = location **name only**; key omitted when id null **or** FK dangling | **YES — add `putawayLocationId`; the dangling-FK ambiguity is AC8's blocker (§3.3, Q6→D-C)** | A1 |
| 3 | `controller/ItemDataController.java:173-176` | `GET /v3/itemData/itemdataDetailsById/{id}` → row 1 | **YES — payload grows** | A1 |
| 4 | `controller/ItemDataController.java:186-191` | `GET .../itemdataDetailsByNumberAndClientNumber/{n}/{cn}` → row 1 | **YES — payload grows; 12 UI consumers (§6.2)** | A1 |
| 5 | `controller/ItemDataController.java:179-183` | `GET .../itemdataDetailsByNumber/{n}` → row 1; `:182` `.get(0)` throws `IndexOutOfBoundsException` on a miss | **YES for the payload; NO for the `.get(0)` bug** — pre-existing, zero UI consumers, out of scope (F6) | A1 |
| 6 | **NEW** `GET /v3/itemData/{id}/effectivePutawayDestination` | the per-SKU 4-tier effective read | **YES — D-B** | A2 |
| 7 | **NEW** `service/SkuPutawayQueryService.describeForSku(Long)` | `readOnly=true` tenant-transaction boundary for the `MANDATORY` resolver. ⚠ **r2: 2643's OWN new file**, not a method added to 2732's `PutawayDestinationQueryService` (§3.2) | **YES — D-A** | A2 |
| 8 | `controller/ItemDataController.java:80` | `@CacheEvict(value="itemdata", allEntries=true)` — flushes every tenant | no — owned by SBDEV-2732 §3.5 (its §0.1 row 14) |
| 9 | `controller/ItemDataController.java:81` | state-mutating `@GetMapping` with `consumes="application/json"` | no — owned by SBDEV-2732 §3.5 / §10.4 Q5 (**deliberately left as-is**: the web UI calls it and changing the verb is a breaking API change) |
| 10 | `controller/ItemDataController.java:83-85, 89-91` | zero-validation write path; `itemdataService.getById` (`@Cacheable`) then raw `save()` | no — owned by SBDEV-2732 §3.5 |
| 11 | `controller/ItemDataController.java:93` | `LOG.debug(... oldLocation={} ...)` interpolates `itemData.getPutawaylocationId()` **after** `:90` mutated it — both args render the NEW id | **YES — 2643 flags it.** 2732 §3.5 rewrites the method but never names this line. If 2732 ships without fixing it, 2643 fixes it (one line). See **D11** (§10.1) |
| 12 | `service/ItemdataService.java:47-50` | `getById` is `@Cacheable`; writers must not use it | no — owned by SBDEV-2732 §0.1 row 13a |
| 13 | `service/ItemdataService.java:62-76` | dead `setPutAwayLocation` (0 production callers) carrying the **correct** 2-key `@CacheEvict` at `:62-67` | no — owned by SBDEV-2732 §3.5 (promoted to the validated writer) |
| 14 | `model/Itemdata.java:49-51` | `@NotNull` on `putawaylocationId` | no — owned by SBDEV-2732 §3.2 (removed with `V2.2.11`) |
| 15 | `controller/LocationController.java:47-49` | `GET /v3/location/detailView` → `getLocationView()` | **YES — read-only context for D-D; NOT widened (D3)** | A3 |
| 16 | `service/ViewDtoService.java:806-832` | `getLocationView()` — exactly 8 fields (`id` `:815`, `locationName` `:816`, `clientNumber` `:817`, `clientName` `:818`, `areaName` `:819`, `locationType` = `sltname` `:820`, `created` `:821`, `modified` `:822`). **No lane flags, no `type_id`, no `usefor*`, no `entity_lock`** | **YES as evidence, NO as a change target** — D3 rejects widening it (4 other screens consume it). D-D ships a dedicated endpoint instead | A3 |
| 17 | `repo/jpa/LocationRepository.java:104-111` | `getStorageLocationsForPutAwayItemData` — `a.useforstorage = 'true'` **and stockunit-driven** (returns only locations where the SKU already has stock) | **NO — must NOT back the picker**, on two independent grounds. 2732 §0.1 row 34 / §3.4c |
| 18 | `repo/jpa/LocationRepository.java:21-22` | `findByName` → tier-4 resolution, no `client_id` filter, `location.name` not unique | no — owned by SBDEV-2732 §3.4b / §5.1 |
| 19 | `SecurityConfiguration.java:136` | `/v3/**` → `hasAnyAuthority("wms_user")` only. **Path note:** the file is `net/aim_ai/wms/SecurityConfiguration.java`, **not** `config/SecurityConfiguration.java` (C1) | **YES — context: any warehouse user can repoint any SKU today. 2643 must not widen it** | A2 |
| 20 | `Authority.java:14` | `IS_SB_ADMIN = "isSbAdmin()"` — **names a SpEL method that does not exist** (F1) | **YES — blocking prerequisite for AC12** | A0 |
| 21 | `CustomMethodSecurityExpressionRoot.java:77` | `isAimAdmin()` — the **only** admin predicate the custom root defines | **YES — the evidence for F1** | A0 |
| 22 | `Authority.java:19, 24` | `SB_ADMIN_ROLE = "sb_admin"`; `getExpForRole(String)` → `hasAuthority('<role>')` | **YES — the fix target for F1** | A0 |
| 23 | `CustomMethodSecurityExpressionHandler.java:19` | `root.setDefaultRolePrefix(null)` — why a bare authority name is correct and no `ROLE_` prefix is needed | **YES — read-only context proving fix (c) is safe** | A0 |
| 24 | `MethodSecurityConfig.java:9-18` | `@EnableMethodSecurity(prePostEnabled=true, …)` + handler wiring | **YES — read-only context** | A0 |
| 25 | `controller/AdminController.java:80, 108, 121, 134, 143, 155, 176, 194` | 8 live `@PreAuthorize(Authority.IS_SB_ADMIN)` sites — **all return 500 for everyone today, including `sb_admin`** | **YES — A0's blast radius; tracked separately by SBDEV-2863** | A0 |
| 26 | `controller/ReplenishmentReconciliationController.java:37` | the 9th broken `@PreAuthorize(Authority.IS_SB_ADMIN)` site | **YES — same** | A0 |
| 27 | `controller/AdminController.java:31` | `@RequestMapping("/v3")`, **no class-level `@PreAuthorize`** — so `ItemDataController extends AdminController` (`:34`) inherits no authorization | **YES — read-only context** | A2 |
| 28 | `service/ViewDtoService.java:895-931` | `getItemDataViewPage` — SKU table projection at `:915-924`, **no putaway field** | **no — Q4 answered NO COLUMN** (§10). Overlay + dialog satisfy AC1; a column would need a second API change and hits the persistedState hazard (F3) | — |
| 29 | `controller/rest/SkuRestController.java:85-88, 144-146, 198-201, 257-259` | create/update seed `putawaylocation_id` = lane id | no — owned by SBDEV-2732 §0.1 rows 8, 9 (stop-seeding, same commit as `V2.2.11`) |
| 30 | `controller/FileImportController.java:355-359, 383` | CSV import seeds the lane id | no — owned by SBDEV-2732 §0.1 row 11 |
| 31 | `service/SkuBatchCreateUpdateService.java:36, 53` | `setPutawaylocationId(defaultPutawayLocationId)` | no — owned by SBDEV-2732 §0.1 row 10 (parameter removed) |
| 32 | `service/WmsConstants.java:771` | `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"` | no — owned by SBDEV-2732 §0.1 row 32. **2643 reads it** for display wording and for Q3's picker exclusion |
| 33 | `service/ReceivingService.java:454-457, 491-495` | the consumption side of the SKU value | no — owned by SBDEV-2732 §3.7, **and** explicitly out per the ticket's own "Receiving Behavior Boundary" |
| 34 | `service/BoxtypeService.java:87` | `details.put("putawayLocation", …)` for **box types** | **out** — unrelated entity, same key name. Do not sweep it |
| 35 | `model/ReceivingDtoView.java:47, 173` | `defaultputawaylocationname` | no — owned by SBDEV-2732 §3.8 (the view needs **no** change) |
| 36 | `service/ReportService.java:182` | `getDefaultputawaylocationname()` | out — read-only report column (2732 §0.1 row 36) |
| 37 | `service/mobile/MobileMoveUnitloadService.java:362-366`, `service/ReturnAdviceAutoReceiveService.java:344-348` | lane-by-name / null-guard readers | no — owned by SBDEV-2732 §3.7.4 |
| 38 | `src/main/resources/db/migration/` head = **`V2.2.10`** (swept across **all** remote branches, not `ls`) | Flyway state | **out — 2643 ships NO migration.** `V2.2.11` is 2732's |
| 39 | `landlord/config/IdempotencyFilter.java:262` | Javadoc naming `ItemdataService.setPutAwayLocation` | out — comment only; **goes stale when 2732 rewrites that method** — flag to 2732 |
| 40 | `landlord/config/IdempotencyFilter.java:271` | `uri.startsWith("/rest/sku/")` — the filter guards `/rest/**` only, so `PUT /putawayConfig/**` is outside it | **YES — read-only context for §7's scalability row 6** | A2 |
| 41 | `controller/ItemDataController.java:97-98` | `sendStockUpdate` — notifies OMS via `httpRestService` | **out, and load-bearing that it stays out**: a putaway-config change must **not** trigger an inventory export. Verify row `A2-neg-oms` asserts it | A2 |

### 0.2 API tests — `v2/wms2-api/src/test/`

| # | File:line | Construct | In scope this plan? | Phase |
|---|---|---|---|---|
| 42 | `unit/controller/ItemDataControllerUnitTest.java:91-102` | the **11-arg** `new ItemDataController(...)` construction (verified 2026-08-07: `keycloakService, 100, itemdataRepository, clientRepository, warehouseStockReportService, dtoViewService, itemdataService, syspropRepository, messageService, httpRestService, syspropService`) | **YES — adding a constructor parameter for D-B breaks this test.** Expect to touch it | A2 |
| 43 | `unit/controller/ItemDataControllerUnitTest.java:111` | `testItemdata.setPutawaylocationId(5L)` fixture | **YES — reused by the new nested class** | A1 |
| 44 | `unit/controller/ItemDataControllerUnitTest.java:119-158` | `@Nested @DisplayName("setPutAwayLocation")` — `:125-146` happy path, `:148-157` not-found | **⚠ COLLISION — do NOT edit.** 2732 Phase-1 Step 9 rewires `ItemDataController:80-95` and must edit these same two tests. 2643 appends a **NEW** nested class at the end of the file (`:374` is EOF) | A2 |
| 45 | `unit/service/ItemdataServiceUnitTest.java:415-428` | `shouldIncludePutawayLocationWhenPresent` — asserts `get("putawayLocation") == "LOC-001"` | **YES — gains a `putawayLocationId` assertion** | A1 |
| 46 | `unit/service/ItemdataServiceUnitTest.java:448-472` | `shouldHandleItemWithAllOptionalFields` — `containsKeys(...)` list at `:468-471` | **YES — the added key must be added here** | A1 |
| 47 | `unit/service/ItemdataServiceUnitTest.java:475-498` | `shouldHandleMissingOptionalReferences` — dangling FK ⇒ `doesNotContainKey("putawayLocation")` at `:498` | **YES — this test ENCODES the AC8 ambiguity.** Adding `putawayLocationId` unconditionally requires rewriting it, deliberately (§3.3) | A1 |
| 48 | `unit/service/ItemdataServiceUnitTest.java:585-604` | null id ⇒ `doesNotContainKey("putawayLocation")` at `:604` | **YES — this is the correct "not configured" case and MUST stay green.** It also must NOT gain `putawayLocationId` | A1 |
| 49 | `unit/config/OptionalSafetyArchTest.java:37` + tracked `src/test/resources/archunit_store/{stored.rules, 5fb3fee0-6caf-4f48-a5cd-5271da610572}`, config `src/test/resources/archunit.properties` | `FreezingArchRule.freeze(...)` over a **git-tracked** violation store (F4) | **YES — build-hygiene constraint.** A new unguarded `Optional.get()` either fails the build or **silently freezes**; `mvn test` mutates the tracked store | all |
| 50 | `unit/CustomMethodSecurityExpressionRootUnitTest.java:170-206` | tests `isAimAdmin()` **directly**, never evaluating the SpEL string | **YES — the reason F1 was invisible for 9 endpoints. A0 adds the SpEL-evaluation test here** | A0 |
| 51 | `common/base/BaseControllerUnitTest.java:34, 52-58` | `setupMockMvc` → `MockMvcBuilders.standaloneSetup(...)` — **no security filter chain, no method-security advisor** (F2). ⚠ The class is `BaseControllerUnitTest`, **not** `BaseControllerTest` (C6) | **YES — this is what makes AC12 non-automatable in the Java unit lane** | A2 |
| 52 | `common/fixtures/TestDataFactory.java:632, 677-678, 694` | `ItemdataBuilder.withPutawaylocationId` | no — 2732 updates ≈10 fixtures for the nullable column |
| 53 | `unit/service/BoxtypeServiceUnitTest.java:188, 222` | box-type `putawayLocation` assertions | out — row 34's entity. Do not touch |
| 54 | ~10 `src/test/resources/scripts/*.sql` + 4 IT files seeding `putawaylocation_id` | NOT NULL fixtures | no — owned by SBDEV-2732 Step 3 |

### 0.3 Web UI — `v2/wms2-web-ui/`

| # | File:line | Construct | In scope this plan? | Phase |
|---|---|---|---|---|
| 55 | `components/masterData/material/skuData/skuData.vue:95-99` | **ACTIVE** `item.actions` template, one eye button at `:97` (`@click="showDetails(item)"`) | **YES — add the Edit affordance beside it.** ⚠ An actions column already exists and already ships one button (C2) — 2643 adds a second, it does not create the column | B1 |
| 56 | `…/skuData.vue:100-123` | commented-out pencil / trash / `v-menu`("Something 1/2/3") block | **YES — delete the corpse.** It is the reference shape only; do **not** resurrect trash or the menu. ⚠ 2732 §0.2 row 45 cites this as `:107-131` — **wrong** (C4) | B1 |
| 57 | `…/skuData.vue:126-152` | `<full-details title="SKU Details" …>` overlay | **YES — host the Edit entry point via its `#actions` slot** | B1 |
| 58 | `…/skuData.vue:130` | `:exclude-fields="['id', 'itemNr', 'version']"` | **YES — MUST add `'putawayLocationId'`, or a raw-integer row renders (§6.1)** | B1 |
| 59 | `…/skuData.vue:142` | `'putawayLocation': 'Putaway Location'` in the `field-names` map | **YES — relabel to `'Default Putaway Location'`** per the ticket's exact wording | B1 |
| 60 | `…/skuData.vue:184-193` | `headers` array — no putaway column | **no — Q4 answered NO COLUMN** (§10) | — |
| 61 | `…/skuData.vue:303-307` | `showDetails` → `getSkuDetail` — **always refetches**, no caching | **YES — the fresh-read path; the dialog reuses it** | B1 |
| 62 | **NEW** `components/masterData/material/skuData/editSkuPutawayDialog.vue` | the SKU edit surface | **YES — 2643's primary UI deliverable** | B2 |
| 63 | **NEW** `components/masterData/material/skuData/putawayWording.js` | shared `DEFAULT_PUTAWAY_LANE_NAME` / `_LABEL` extracted from 2731 | **YES — §3.6; prevents a third copy** | B1 |
| 64 | `store/masterData/skuData.js:88-94` | `getSkuDetail` → `GET /itemData/itemdataDetailsById/{id}` | **YES — consumes the widened payload; re-dispatched after a write** | B1 |
| 65 | `store/masterData/skuData.js:46-95` | actions block — `getSkuData` (`:46`), `searchSkuData` (`:63`), `getSkuDetail` (`:88`). **Zero write actions exist in this store** | **YES — 2643 adds the first: `setSkuPutawayLocation`** | B2 |
| 66 | **NEW** store action reading `effectivePutawayDestination` | the "effective default when no override" AC | **YES — `getSkuEffectivePutaway`** | B2 |
| 67 | `components/common/fullDetails.vue:10-11` | `v-for="(value, name) in details"` + `v-if="excludeFields.indexOf(name) == -1"` | **YES — the BC mechanism; renders every unexcluded key.** Label falls through to `:14`'s `name.charAt(0).toUpperCase() + name.slice(1)` | B1 |
| 68 | `components/common/fullDetails.vue:26` | `<slot name="actions">` inside `v-card-actions` | **YES — the clean Edit-button host. Zero changes to `fullDetails.vue` required** | B1 |
| 69 | `components/common/skuInfo.vue:102-105` | explicit `reportDetail.putawayLocation` row | **YES — audit only, expected no-change.** BC-safe: field-explicit, no key iteration (§6.2) | B1 |
| 70 | `store/masterData/storageLocation.js:50-58` | `getStorageLocations` → `$get('/location/detailView')`, **no params** | **YES as evidence, NO as a change target** — D3 keeps this endpoint untouched | A3 |
| 71 | `components/common/LocationPicker.vue` | the tiered picker | no — owned by SBDEV-2732 §3.11.2 Step 19. **2643 consumes it** (Q7 → strict reuse) |
| 72 | `components/masterData/location/fixedLocations/moveFixedLocation.vue:13` | bare `<v-autocomplete :items="items">` — the naive precedent | **YES as reference only** — insufficient for AC3 "searchable + meaningful info" | B2 |
| 73 | `components/receiving/open/receive/receivingForm.vue:14-24, 215-222, 296-314` | 2731's configured-vs-default wording: comment `:215-220`, `DEFAULT_PUTAWAY_LANE_NAME='PutAwayLane'` `:221`, `DEFAULT_PUTAWAY_LANE_LABEL='Put Away Lane'` `:222`, `isPutawayDestinationApplied` `:296-300`, `isPutawayOverride` `:301-305`, `putawayDisplay` `:309-314` | **YES — 2643 MUST reuse these, not invent new wording** (§3.6) | B1 |
| 74 | `store/index.js:5-6, 24-28` | `affiliatedGroups: []` / `affiliatedGroupsStr: ''` + their two mutations — **set, never read for gating** | **YES — the only material for the UI permission gate** | B1 |
| 75 | `store/index.js:3, 19-21, 92-101, 103-117` | `isWmsUser`; `getUserRoles`; `getAffiliatedGroupsByUsername` — roles are **already fetched** | **YES — the data is there; only the gate is missing** | B1 |
| 76 | `nuxt.config.js:167` | `appAdminGroup: process.env.APP_ADMIN_GROUP \|\| '/wms/wh/wms_admin'` — **read nowhere** | **YES — consumed for the first time by 2643** | B1 |
| 77 | `layouts/default.vue:467` | `console.log("affiliatedGroupsStr ", …)` — the **only** read of the gating material in the entire app, and it is a log statement | **YES — proof there is no gating framework (§3.7)** | B1 |
| 78 | `plugins/persistedState.client.js:26-29` | reducer `({ warehouseTimezone, selectedWarehouse, warehouses, ...persisted }) => persisted` ⇒ `masterData.skuData` **IS** persisted to `localStorage['vuex-web']` (F3) | **YES — AC5 hazard.** Mitigated by Q4's no-column decision + the overlay's unconditional refetch at `skuData.vue:304` | B1 |
| 79 | `components/masterData/material/packaging/editPackagingDialog.vue` (196 L) + `packaging.vue:91-94, 122-127, 161, 170, 294` | the **only** masterData create/edit dialog in the repo, and a sibling of the SKU screen | **YES — the idiom to copy** (§3.5) | B2 |
| 80 | `store/masterData/packaging.js:99-113` (`createPackaging`) / `:114-128` (`editPackaging`) | the write-action idiom: `try` → `results.errors` → `$toast` → `catch` → `context.dispatch(...)` | **YES — the store idiom to copy, with 3 deliberate deviations** (§3.4) | B2 |
| 81 | 12 components calling `itemdataDetailsByNumberAndClientNumber`, all feeding `components/common/skuInfo.vue` | BC blast radius — enumerated in §6.2 | **YES — audit, expected no-change** | B1 |
| 82 | `components/internalOps/cycleCount/planned/create/createCycleCountSkuTable.vue:166`, `components/receiving/open/create/createPurchaseOrderSkuTable.vue:290` | the other two `itemdataDetailsById` consumers | **YES — audit** | B1 |
| 83 | `test/` — 16 Jest specs, **no `skuData` spec** | test surface | **YES — 3 new specs (§7.2)** | B1/B2 |
| 84 | `pages/masterData/strategies/sku-data-nam.vue`, `static/fakeSKUData.json` | stray scratch page + fixture with putaway refs | **out** — dead scratch artifacts, not menu-reachable. **Do not edit** | — |
| 85 | `components/putaway/storePallet.vue` (mobile UI) | mobile putaway | **out** — `wms2-mobile-ui` is out of scope (2732 §0.2 row 46, §8.4) | — |

---

## 1. Problem Statement

### 1.1 The requester's framing

Scott Dalton, via SBDEV-2643 (child of SBDEV-1938): warehouse operators need to designate a
**Default Putaway Location** per SKU, so that SKUs which always live in one known place — the worked
example is a **System-Client Ice Pack SKU in the HMG warehouse** — are received directly there instead
of routing through the generic Put Away Lane. The ticket asks for this to be settable *"in the
appropriate SKU edit or warehouse-configuration interface"*, with a searchable location selector,
a way to clear back to standard behaviour, and an audit trail. It carries **12 acceptance criteria**
(mapped 1:1 in §13) and an explicit **"Receiving Behavior Boundary"** section deferring what receiving
*does* with the value to a separate ticket.

### 1.2 The verified current state — two facts that reframe the ticket

**(a) The value is DB-only configurable today.** There is no UI to set it. `skuData.vue` displays
`putawayLocation` read-only (`:142`) and its create/edit block has been **commented out** since before
this ticket (`:100-123`). Consequence, measured on hydra/nywh DEV 2026-08-07: **2,720 of 2,720 SKUs
point at exactly one destination** — `count(DISTINCT putawaylocation_id) = 1`, the `PutAwayLane`
(id 50155). The feature is not merely unconfigurable; it has never been configured. On PRD, SBDEV-2731
records exactly **one** SKU warehouse-wide with a non-`PutAwayLane` destination (the ICE PACK SKU) —
and that one value is invalid, which is what filed 2731.

**(b) The one live write path is an unvalidated, unauthorized `@GetMapping`.** Verified at
`ItemDataController.java:79-95`:

```java
// Request Json: { itemDataId, locationId }
@CacheEvict(value = "itemdata", allEntries = true)                      // :80  flushes EVERY tenant
@GetMapping(path = "/setPutAwayLocation/{itemdataid}/{locationid}",     // :81  GET that mutates state,
            consumes = "application/json", produces = "application/json")  //     with a nonsensical `consumes`
public ResponseEntity<Object> setPutAwayLocation(@PathVariable("itemdataid") Long itemDataId,
                                                 @PathVariable("locationid") Long locationId,
                                                 @AuthenticationPrincipal Principal principal) … {
    LOG.debug("start with itemData={} location={}", itemDataId, locationId);
    Itemdata itemData = itemdataService.getById(itemDataId);            // :89  @Cacheable — mutated in place
    itemData.setPutawaylocationId(locationId);                          // :90  zero validation
    Itemdata newItemData = itemdataRepository.save(itemData);           // :91  raw save
    LOG.debug("end.  changed putaway location in itemData={} from oldLocation={} to newLocation={}",
              itemData, itemData.getPutawaylocationId(), locationId);   // :93  logs the NEW value as `oldLocation`
    return ResponseEntity.ok(newItemData);
}
```

Every clause is a defect:

| Line | Defect | Consequence |
|---|---|---|
| `:80` | `allEntries = true` on the `itemdata` cache | one SKU write flushes every tenant's `itemdata` cache |
| `:81` | `@GetMapping` mutates state; `consumes = "application/json"` on a body-less GET | not idempotent-by-verb; CSRF-reachable; the `consumes` clause is meaningless |
| `:83-85` | no `@PreAuthorize`. `ItemDataController extends AdminController` (`:34`) but `AdminController:31` carries only `@RequestMapping("/v3")` — **no class-level authorization** | `SecurityConfiguration.java:136` gates `/v3/**` on `hasAnyAuthority("wms_user")`, so **any warehouse user can repoint any SKU to any location id** |
| `:89` | `itemdataService.getById` is `@Cacheable` (`ItemdataService.java:47`) | the cached instance is mutated in place before eviction fires |
| `:90` | no existence check, no compatibility check, no lane check, no lock check | a nonexistent or hostile location id is accepted verbatim. **This is where SBDEV-2731's invalid ICE PACK configuration came from** (2732 §10.5) |
| `:91` | raw repository `save()`, no `@Transactional` anywhere under `controller/` | no audit row, no metric, no rollback semantics |
| `:93` | `itemData.getPutawaylocationId()` is read *after* `:90` mutated it | the debug line renders the **new** id twice — actively misleads anyone debugging a putaway config |

And the one service method that *would* have validated, `ItemdataService.setPutAwayLocation`
(`:68-76`), has **zero production callers** — the only other `src/main` reference is a Javadoc mention
at `IdempotencyFilter.java:262`. It is also broken for the case that matters: `:71` does
`locationRepository.findById(itemData.getPutawaylocationId()).orElseThrow(...)`, and `findById(null)`
raises `InvalidDataAccessApiUsageException`, so it blows up on a first-time set.

### 1.3 What this plan is, and is not

SBDEV-2732 already owns the repair of every row in that table. **This plan does not re-fix them.** It
builds the operator-facing surface on top, plus the five API pieces 2732's design does not define
(§3, D-A…D-F). Its central risk is therefore not technical difficulty — it is that **every contract it
consumes is on unwritten code** (§11.0, R5).

### 1.4 The scope limitation, stated up front

2732 §3.4c/§3.5a make a pick-face destination a **422 at all three scopes** (P2.7(c)) — `:722`
*"absolute at all three scopes — tier 1 included"*, `:792-795` *"Tier 1 (SKU) is exempt from (a), (b)
and (d) — **but NOT from (c)**, deliberately"*, and 2732 ships the unit test that enforces it
(`skuWriteRejectsPickFaceDestination`, `:2211`). Measured 2026-08-07 on hydra/nywh DEV: **all 496
flowbins in the warehouse are in a `useforpicking` area**, and SBDEV-2731's PRD evidence records the
reported ICE PACK location (id 52075) as `type_id = 2` = `flowbin`.

**Consequence, and it is the most important sentence in this plan: 2643 ships a picker offering 92
locations, and the ICE PACK location the ticket names as its worked example is not one of them.**
That is not a defect in 2643 and not a divergence from 2732 — it is **correct sequencing**. 2732
`:722` already assigns tier-1 pick-face relaxation to **[SBDEV-2821](https://app.clickup.com/t/868km8j9z)**,
alongside P2.5. Until 2821 lands, a SKU-scope pick-face configuration **cannot be written by any
client**, 2643 included; a picker that offered them would offer rows whose selection 422s.

**What 2643 owes the operator instead is legibility.** The picker states, in the UI, that pick faces
are not yet selectable and names SBDEV-2821 — so an operator who came looking for a flowbin learns
*why* it is absent rather than concluding the search box is broken. §10.1 **D1** records the decision;
§9.1 records the option that was rejected and why. A reviewer who reads nothing else should read D1.

---

## 2. Current Architecture

The "is" state, with DB evidence inline. All reads SELECT-only against `wms2-hydra-dev2`
(= `wh01_hydra_v2` = HMG/nywh DEV) on 2026-08-07.

### 2.1 The data model

| Aspect | Evidence | Value |
|---|---|---|
| the column | `V2.2.00__base_v2_schema.sql:951`; FK `:5686-5690`; index `:4468-4471` | `itemdata.putawaylocation_id bigint NOT NULL` |
| nullability, live | `information_schema.columns` | `is_nullable = NO` — **AC4 is hard-blocked until 2732's `V2.2.11 DROP NOT NULL`** |
| the entity | `Itemdata.java:49-51` | `@NotNull` / `@Column(name="putawaylocation_id")` / `Long putawaylocationId`. **Verified in code, not inferred from 2732's plan** |
| configured values | `SELECT count(*), count(DISTINCT putawaylocation_id) FROM itemdata` | **2,720 SKUs → 1 distinct destination**, id 50155 `PutAwayLane`. `count(*) WHERE putawaylocation_id IS NULL` = **0** |
| tier-4 resolution | `LocationRepository.java:21-22` `findByName` | no `client_id` filter, and `location.name` has no unique constraint |
| the constant | `WmsConstants.java:771` | `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"` |
| **there is no `location.active`** | `information_schema.columns` count = **0**; `Location.java:32-41` has only the 5 lane booleans (`staginglane` `:33`, `transferlane` `:35`, `automationlane` `:37`, `crossdockinglane` `:39`, `gate` `:41`) | **AC6's "active" and "shipping lane" name columns that do not exist.** §3.9 records the reinterpretation |
| **there is no location "code"** | `Location.java:10-41` has `name` only; `getLocationView()` exposes `locationName` + `areaName` + `locationType` | **AC3's `CODE — Human Name` rendering is unimplementable as specified.** §3.9 records the substitute |
| location-type column | `information_schema` | the column is **`location_type.sltname`**, not `name` |
| audit | `information_schema.tables` count for `putaway_config_audit` = **0** | **AC9 is hard-blocked** on 2732 |
| facility scope | one DB per facility (2732 §2.4) | **AC7 is structurally satisfied** — assert as an invariant, do not build for it |

### 2.2 The location inventory — and why the picker's eligible set is the crux

666 locations. Under 2732's SKU-scope predicate set:

| Filter | Count | Predicate |
|---|---|---|
| all locations | 666 | — |
| `entity_lock = 0` | 666 | P2.2 |
| no lane flag TRUE | 644 | P2.3 (rejects 22) |
| `useforgoodsin OR useforstorage` (area flags) | 603 | P2.4 — **OR, not AND** |
| in a `useforpicking` area | **511** | P2.7(c) **rejects all 511** |
| fix-assigned (`fix_location_assignment.assignedlocation_id`) | **154** | P2.5 **rejects all 154** |
| **SKU-scope eligible under 2732 verbatim** | **92 (13.8%)** | all predicates |

By `location_type.sltname`:

| `sltname` | count | in a `useforpicking` area | fix-assigned |
|---|---|---|---|
| **flowbin** | **496** | **496 (100%)** | 154 |
| overstock pallet | 104 | 3 | 0 |
| NoRestriction | 36 | 0 | 0 |
| overstock box | 14 | 12 | 0 |
| cases and pallets | 13 | 0 | 0 |
| totes | 2 | 0 | 0 |
| packages | 1 | 0 | 0 |

Two conclusions:

1. **`useforpicking` is the single most aggressive filter** — 511 of 666 — and it eliminates **every
   flowbin**, i.e. every pick face, i.e. the class of location the ticket's own worked example names.
2. **A preloaded, client-side-filtered picker scales fine at 666 rows.** 2732's Q2 ("does a preloaded
   picker scale?") is answered NO-PROBLEM for this tenant. AC3's "searchable" therefore needs a search
   *box*, not a server-search endpoint — but D3 still puts **predicate evaluation** server-side, for a
   different reason (single source of truth), not for scale.

Also measured: `PutAwayLane` itself (id 50155) is `entity_lock=0`, `type_id=50057`
(`sltname='cases and pallets'`), area `Inbound`, `useforgoodsin=TRUE`, `useforstorage=FALSE`,
`useforpicking=FALSE`, all 5 lane flags FALSE, 0 FLA rows — so **the tier-4 fallback passes every
SKU-scope predicate and is legally selectable.** After `V2.2.11`, "pin this SKU to `PutAwayLane`" and
"clear the override" produce identical receiving behaviour but different configurations. §3.5 / Q3
resolve the ambiguity by excluding it from the picker.

### 2.3 The read path

`ItemdataService.getItemdataDetails(Long)` (`:119-174`) — verified 2026-08-07:

```java
public Map<String, Object> getItemdataDetails(Long id) {                 // :119  NO @Transactional
    Itemdata i = itemdataRepository.findById(id).orElseThrow(...);       // :120  repo, NOT the @Cacheable getById
    Map<String, Object> details = new HashMap<>();
    …
    if (i.getPutawaylocationId() != null) {                             // :166
        Optional<Location> location = locationRepository.findById(...);  // :167
        if (location.isPresent()) {                                     // :168
            details.put("putawayLocation", location.get().getName());    // :169  NAME ONLY — no id
        }
    }
    return details;
}
```

Three properties matter downstream:

- **No id in the payload.** No picker can pre-select the current value. This is D-C, the single
  smallest change that unblocks the whole UI.
- **Double-guarded omission.** The key is absent when the id is NULL (`:166`) *and* when the FK dangles
  (`:168`). Today those are indistinguishable to a client — and `ItemdataServiceUnitTest.java:498`
  **enforces** the ambiguity. After `V2.2.11` makes NULL the normal state, "inherit" and "broken"
  must be distinguishable, or **AC8 is unimplementable**. §3.3.
- **`findById`, not `getById`.** The details read bypasses the Caffeine `itemdata` cache entirely, so
  2643's own display is always fresh even under Caffeine — a real advantage over 2732 §7.6 row 9's
  accepted staleness. §7.4 row 5/9 assert it so a future "optimisation" to `getById` cannot break it.
  It also means `getItemdataDetails` must **not** host the resolver call: it has no transaction
  (`ItemdataService.java:15` is a bare `@Service`) and 2732's resolver is `Propagation.MANDATORY` (F5).

### 2.4 The location list the picker would naturally use — and why it cannot work

`ViewDtoService.getLocationView()` (`:806-832`), served by `LocationController.java:47-49` at
`GET /v3/location/detailView`, read by `store/masterData/storageLocation.js:51` with no params.
It returns exactly 8 fields:

`id` `:815` · `locationName` `:816` · `clientNumber` `:817` · `clientName` `:818` · `areaName` `:819` ·
`locationType` (= `getSltname()`) `:820` · `created` `:821` · `modified` `:822`

**No lane flags. No `type_id`. No `usefor*`. No `entity_lock`. No FLA marker.** So 2732 §3.11.2's
mandated *client-side P2.4 filter over `/location/detailView`* **cannot be implemented against the
endpoint it names** — and 2732's own Step 19 is blocked identically. D3 resolves this with a dedicated
server-side endpoint rather than widening a payload four other screens consume.

### 2.5 The write surface, the auth surface, and the test surface

- **Write:** §1.2. One unvalidated `@GetMapping`, plus five other seeders
  (`SkuRestController` ×4, `FileImportController`, `SkuBatchCreateUpdateService`) that all 2732 owns.
- **Auth:** `SecurityConfiguration.java:136` — `/v3/**` requires only `hasAnyAuthority("wms_user")`.
  Method-level authorization is wired (`MethodSecurityConfig.java:9-18`,
  `CustomMethodSecurityExpressionHandler.java:15-23`) and the custom root defines exactly one admin
  predicate, `isAimAdmin()` at `CustomMethodSecurityExpressionRoot.java:77`. But
  `Authority.java:14` reads `IS_SB_ADMIN = "isSbAdmin()";  // legacy` — **a method that exists
  nowhere in `src/main` or `src/test`.** §3.1 (F1 / D2).
- **UI auth:** none. An exhaustive grep for
  `APP_ADMIN_GROUP|affiliatedGroups|isAdmin|isSbAdmin|adminGroup|wms_admin|hasRole|realmAccess|resourceAccess`
  over `*.vue` + `*.js` returns **6 lines total** (rows 74–77 in §0.3), of which the only *read* is a
  `console.log`. There is no `isAdmin` computed, no mixin, no route middleware, no role `v-if`
  anywhere. **2643 builds the first gate in the app.** §3.7.
- **Tests:** `BaseControllerUnitTest.java:52-58` uses `MockMvcBuilders.standaloneSetup(...)` — no
  security filter chain, no method-security advisor — so **`@PreAuthorize` is never evaluated in any
  controller unit test** (F2). The `@SpringBootTest` lane is down (SBDEV-2217). AC12's "permission
  enforcement" is therefore **not automatable as a controller test**; it is proven by A0's
  SpEL-evaluation unit test plus a manual row. §7.

### 2.6 Flyway state

Head, swept across **all** remote branches (not `ls db/migration/`, per the recorded landmine):
**`V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop`** (SBDEV-2854, merged `68274b0`).
`V2.2.11` is 2732's. **2643 ships zero migrations**, so the whole Flyway-ordering hazard class
(out-of-order skip → `validateOnMigrate` boot failure → swallowed by `StartupFlywayMigrator`) does not
apply to this plan. Stale duplicate versions on abandoned branches (`V2.2.01`, `V2.2.02`, `V2.2.03`)
are pre-rebase artifacts — ignore them.

---

## 3. Design

> # ⛔ BLOCKING BANNER — READ BEFORE WRITING A TEST AGAINST ANYTHING IN §3
>
> **Every contract in §3.2, §3.4 and §3.5 is a NEGOTIATING POSITION, not a specification.** Each is
> marked `CONTRACT-PROVISIONAL` in its own heading. **Re-derive each one from SBDEV-2732's *merged PR*
> before writing a single test** (R5, §11.0).
>
> Why this is a banner and not a checklist bullet: 2732 is `status: draft`, and its own **D18**
> (`:103-106`) records that *"the 2026-08-04 revisions changed validator predicate semantics (P2.5,
> P2.7(c)) and have had no independent pass; the previous Critic pass returned 12 findings including a
> **CRITICAL** one."* 2732's §12 changelog shows P2.5 flipped and reverted the same day, and P2.7(c)
> becoming implementable only on 2026-08-06. §10.3 records **ten** defects found in 2732 while verifying
> these contracts, one of which (C4) is in the row that scopes this entire ticket, and two of which
> (C10) are 2732 contradicting itself on the exact rule §3.5 depends on.
>
> An implementer with no memory of this session must not read §3.4's code block as settled API.

Six API/UI deliverables (**D-A … D-F**) plus the SKU edit surface. Each subsection states the contract,
the phase, and the 2732 dependency. **Nothing here changes `ReceivingService`, and nothing here ships
SQL.** The five principles §3 is designed against are stated in **§14**.

### 3.1 D-E — repair `Authority.IS_SB_ADMIN` (Phase A0, no 2732 dependency)

**Problem.** `Authority.java:14`:

```java
public static final String IS_SB_ADMIN = "isSbAdmin()";  // legacy
```

SpEL resolves `isSbAdmin()` reflectively against the method-security expression root. The root is
`CustomMethodSecurityExpressionRoot` (`:11`), wired via `CustomMethodSecurityExpressionHandler:15-23`
and `MethodSecurityConfig:13-18`. Its **only** admin predicate is `isAimAdmin()` at `:77`. An
exhaustive grep for `isSbAdmin` across `src/main` and `src/test` returns exactly one hit —
`Authority.java:14` itself. So evaluation raises
`SpelEvaluationException: EL1004E: Method call: Method isSbAdmin() cannot be found on type
CustomMethodSecurityExpressionRoot` → **HTTP 500, not 403**, for **every caller including a genuine
`sb_admin`**.

**Live blast radius today:** `AdminController.java:80, 108, 121, 134, 143, 155, 176, 194` (8 user/group
admin endpoints) and `ReplenishmentReconciliationController.java:37`. Nine endpoints are dead.
Separately ticketed as **[SBDEV-2863](https://app.clickup.com/t/868knmx18)**.

**Why it is 2643's problem.** 2732 §3.12 mandates `@PreAuthorize(Authority.IS_SB_ADMIN)` on
`PutawayConfigController`'s three writes **and** on `PutawayConfigService`'s writers plus
`validateOnly`, calling it *"the pattern used throughout `AdminController`"*. If 2643 adopts the
constant as-is, **every SKU putaway write returns 500** — and AC12's permission test would be
asserting against a broken expression.

**Fix (D2, option (c)) — the correct expression is:**

```java
@PreAuthorize(Authority.getExpForRole(Authority.SB_ADMIN_ROLE))   // → "hasAuthority('sb_admin')"
```

`Authority.java:19` defines `SB_ADMIN_ROLE = "sb_admin"` and `:24` `getExpForRole(String)` renders
`hasAuthority('<role>')`. This is safe with **no** `ROLE_` prefix because
`CustomMethodSecurityExpressionHandler.java:19` calls `root.setDefaultRolePrefix(null)`. It touches no
shared security wiring and needs no custom root at all.

> **⚖ r2 SCOPE CHANGE — 2643 does NOT apply that swap. It ships the DETECTOR and the FINDING.**
>
> r1 had A0 (later A2) edit `@PreAuthorize(Authority.IS_SB_ADMIN)` → `getExpForRole(...)` inside
> **`PutawayConfigService.java` and `PutawayConfigController.java`** — 2732's own files, on lines 2732
> deliberately writes (2732 §3.5 `:905, 917, 925`, §3.9 `:1491`, §3.5a `:972, 978, 985`, all citing its
> §3.12 as *"the authorization boundary"*).
>
> **A 2643 PR reverting a security annotation that a 2732 PR deliberately added, days later, in 2732's
> own file, is the wrong home for the change** — whatever its merits. It is not a stacked consumer edit;
> it is a cross-plan security reversal, and it would land after 2732's review approved the annotation.
>
> **Correct homes, in order of preference:** (1) a one-token review comment on 2732's PR *before it
> merges*; (2) **[SBDEV-2863](https://app.clickup.com/t/868knmx18)**, which already owns the constant.
> 2643 carries a **blocking prerequisite row** (§5.1 row 0e: *"2732 must not merge with
> `Authority.IS_SB_ADMIN`"*) and a **prerequisite probe** in the verify script (`X-2732-authz`) that
> FAILS if 2732's file lands still carrying the broken constant. The probe is labelled a prerequisite,
> never a 2643 deliverable.
>
> **What 2643 keeps is the higher-value half.** The detector below is the artefact that protects a third
> party — without it, 2732 §3.12 builds a new security boundary on a constant that 500s for everyone,
> and no existing test can see it.

**Two alternatives were considered and rejected for A0's scope:** (a) add an `isSbAdmin()` alias to
`CustomMethodSecurityExpressionRoot` — changes shared security wiring on a plan that has no business
doing so; (b) repoint `Authority.IS_SB_ADMIN` at `"isAimAdmin()"` — silently changes the semantics of
9 unrelated endpoints from "sb admin" to "aim admin". **A0 ships the detector only; the expression fix
belongs to 2732's review or SBDEV-2863, and the repair of the 9 broken endpoints is SBDEV-2863's.**

**The detector is the deliverable, not the annotation.** `CustomMethodSecurityExpressionRootUnitTest.java:170-206`
tests `isAimAdmin()` **directly** and therefore cannot see this class of defect. A0 adds a test that
**evaluates the SpEL string**:

```java
// unit/CustomMethodSecurityExpressionRootUnitTest.java — NEW @Nested class
@Test
@DisplayName("every Authority SpEL constant resolves against the expression root")
void authoritySpelConstantsResolve() {
    var root = new CustomMethodSecurityExpressionRoot(authentication);   // real root, not a mock
    var parser = new SpelExpressionParser();
    // A constant naming a method the root does not declare throws SpelEvaluationException here,
    // exactly as it does inside Spring Security's method-security advisor. A direct isAimAdmin()
    // call cannot catch this — the string is never parsed.
    assertThatCode(() -> parser.parseExpression(Authority.getExpForRole(Authority.SB_ADMIN_ROLE))
            .getValue(new StandardEvaluationContext(root), Boolean.class))
        .doesNotThrowAnyException();
}
```

Assert the **same** for whichever constant 2643's handlers actually carry. Do **not** assert
`Authority.IS_SB_ADMIN` resolves — it does not, and A0 is not fixing it.

### 3.2 D-A — `SkuPutawayQueryService.describeForSku` (Phase A2, blocked on 2732 Phase 1-API)

> **`CONTRACT-PROVISIONAL` — re-derive from 2732's merged PR before writing tests.** The types
> (`Resolution`, `PutawayDestinationResolver`) and the `MANDATORY` propagation rule are 2732's and are
> `draft`. See §3's blocking banner.

2732 §3.1.5 defines exactly two facade methods — `describeForAdvicePosition(Long)` and
`describeForClient(Long)`. **There is no `describeForSku`.** That is 2643's genuine API gap: without
it, no SKU-scope caller can obtain a `Resolution`.

**r2 change — 2643 owns the file, not the method-on-someone-else's-class.** r1 added `describeForSku`
*into* `service/PutawayDestinationQueryService.java`, a file 2732 creates days earlier. The
`Propagation.MANDATORY` constraint (constraint 3 below) requires **a** `@Transactional` bean between the
controller and the resolver; **it does not require that bean to be 2732's file.** 2732 §3.1.5 (`:508-519`)
describes the facade as a holder of two sibling methods, not a registry. So D-A ships as **2643's own
class**:

```java
// service/SkuPutawayQueryService.java  — NEW, 2643-OWNED FILE
@Service
public class SkuPutawayQueryService {

    private final PutawayDestinationResolver putawayDestinationResolver;   // 2732's bean, injected
    private final ItemdataRepository itemdataRepository;

    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public Resolution describeForSku(Long itemdataId) throws BusinessException { … }
}
```

**Why this is strictly better, and it is not a style preference:**

| | r1 (method on 2732's class) | r2 (2643's own class) |
|---|---|---|
| merge surface | a three-way merge inside 2732's newest file | a compile-time dependency on two 2732 **types** |
| failure mode if 2732 reworks the facade on merge | textual conflict, or PM1's silent orphan | a compile error the build catches immediately |
| blast radius on 2732's review cycle | 2643's method must survive 2732's rewrites | none — 2732 never sees this file |
| cost | — | one class + one line of DI |

The counter-argument is cohesion: three `describeForX` methods in one place is more discoverable. Real,
but weaker than the conflict cost — §5.4 rated A2 **HIGH** risk principally *because* of that coupling
(R1, R2, §11.0), and this removes the reason.

**The negative check does not move.** `A2-neg-res` still asserts `putawayDestinationResolver`
appears nowhere in `ItemDataController.java` — the resolver moves into a *service*, never the
controller. That the check is shape-independent is evidence it was written against the right invariant.
A **new** negative row (`A2-neg-2732f`) asserts `describeForSku` does **not** appear in
`PutawayDestinationQueryService.java`, so the boundary is enforced rather than merely intended.

Three constraints, each load-bearing:

1. **`value = "tenantTransactionManager"` verbatim.** A bare `@Transactional` silently binds the
   `@Primary` **landlord** transaction manager. `unit/config/TransactionManagerArchTest.java` enforces
   this repo-wide; the verify script asserts the literal string as well.
2. **`readOnly = true`.** Required for symmetry with 2732's two sibling facade methods, and safe **only
   because** 2732 §3.4a reads tier 3 through `SyspropRepository` and never
   `SyspropService.getStringDefault` (which INSERTs at `SyspropService.java:234`). 2643 must not
   weaken that.
3. **It must supply the transaction the resolver demands.** `PutawayDestinationResolver.resolve(...)`
   is `Propagation.MANDATORY` (2732 §3.1.5) and there is **zero `@Transactional` anywhere under
   `controller/`** — the only three matches in the tree are comments. A `MANDATORY` call from a
   controller raises `IllegalTransactionStateException`, a bare `RuntimeException`, on **every** call →
   mapped to **500**. OSIV would not help and is off anyway
   (`application.properties:55` `spring.jpa.open-in-view=false`): it opens an `EntityManager`, never a
   transaction. **`describeForSku` must NOT be added to `ItemdataService`** either —
   `ItemdataService.java:15` is a bare `@Service` with no transaction annotation anywhere (F5).
   `SkuPutawayQueryService` exists **only** to be that transactional boundary; a `@Service` without the
   annotation would reproduce the F5 bug in a new file.

**No mocked unit test can prove this wiring** (a Mockito mock has no propagation semantics), so it is
enforced by the negative code-shape check **D-F** (§3.6) plus manual row **M8**.

### 3.3 D-C — `getItemdataDetails` gains `putawayLocationId` (Phase A1, **no 2732 dependency**)

The smallest change in the plan and the one that unblocks the whole UI.

```java
// service/ItemdataService.java — inside getItemdataDetails, replacing :166-171
if (i.getPutawaylocationId() != null) {
    // SBDEV-2643: emit the id UNCONDITIONALLY when non-null, even if the FK dangles.
    // The id present WITHOUT a name is the "configured but invalid" signal (AC8); the key
    // absent entirely is the "not configured / inherits" signal. Before this, both cases
    // omitted every key and were indistinguishable — see ItemdataServiceUnitTest:498.
    details.put("putawayLocationId", i.getPutawaylocationId());
    locationRepository.findById(i.getPutawaylocationId())
        .ifPresent(loc -> details.put("putawayLocation", loc.getName()));
}
```

| SKU state | `putawayLocationId` | `putawayLocation` | UI reads it as |
|---|---|---|---|
| no override (post-`V2.2.11` normal) | absent | absent | *inherits the effective default* |
| override, FK resolves | present | present | *configured: `<name>`* |
| override, FK dangles | **present** | **absent** | **configured but INVALID — AC8** |

**Zero extra queries.** `putawaylocationId` is already on the entity loaded at `:120`; only a
`details.put` is added. **No behaviour change to the name key** — every existing consumer of
`putawayLocation` is untouched.

**Test consequences, all deliberate:**

| Test | Line | Action |
|---|---|---|
| `shouldIncludePutawayLocationWhenPresent` | `:415-428` | add `assertThat(details).containsEntry("putawayLocationId", <id>)` |
| `shouldHandleItemWithAllOptionalFields` | key list `:468-471` | add `"putawayLocationId"` |
| `shouldHandleMissingOptionalReferences` | assertion `:498` | **rewrite deliberately** — dangling FK now yields `containsKey("putawayLocationId")` **and** `doesNotContainKey("putawayLocation")`. This test encodes the AC8 ambiguity; changing it is the point |
| null-id case | assertion `:604` | **must stay green, and must also assert `doesNotContainKey("putawayLocationId")`** |

**The richer AC8 signal (`compatible` / `warning`) does NOT come from here.** It comes from D-B, so
precedence and compatibility logic stay in exactly one place. The details map stays dumb.

### 3.4 D-B — `GET /v3/itemData/{id}/effectivePutawayDestination` (Phase A2, blocked on 2732 Phase 1-API)

> **`CONTRACT-PROVISIONAL` — re-derive from 2732's merged PR before writing tests.** The `Resolution`
> shape, the `Source` enum names and the `compatible`/`warning` semantics are 2732's §3.8 and are
> `draft`. See §3's blocking banner.

2732's read inventory covers advice positions (N8) and clients (N9). No SKU-scope read exists.

```java
// controller/ItemDataController.java — delegates only; opens no transaction of its own
@GetMapping(path = "/{id}/effectivePutawayDestination", produces = "application/json")
public Map<String, Object> effectivePutawayDestination(@PathVariable("id") Long id,
                                                      @AuthenticationPrincipal Principal principal)
        throws BusinessException {
    // §3.2's SkuPutawayQueryService supplies the tenant transaction the MANDATORY resolver requires.
    return toEnvelope(skuPutawayQueryService.describeForSku(id));
}
```

**Envelope — 2732 §3.8's `Resolution` shape, 7 fields, unchanged:**

```
{ locationId, locationName, source, sourceLabel, configuredFor, compatible, warning }
```

| Field | Contract |
|---|---|
| `source` | **enum name**: `SKU_OVERRIDE` \| `MERCHANT_OVERRIDE` \| `WAREHOUSE_DEFAULT` \| `STANDARD_PUTAWAY_LANE` |
| `sourceLabel` | display string: `"SKU override"` \| `"Merchant default"` \| `"Warehouse default"` \| `"Standard putaway lane"` |
| `compatible` | **P1 reported without throwing** — this is what lets the UI warn *before* commit (AC8) |
| `warning` | the rendered `putawayDestinationNotPermitted` text when `compatible == false` |

2732 §3.8 is explicit: *"`source` is the enum name so Vue never re-derives the precedence."*
**2643 must not re-derive tiers in JavaScript.** The controller owns only the `Resolution` →
JSON mapping.

**Do not conflate this with 2732's `PutawayConfigPreview` envelope** (2732 §3.5a):
`{ locationId, locationName, compatible, incompatibleSkuCount, totalSkuCount, exampleIncompatibleSku, blockingReason }`.
Different shape, different purpose. At SKU scope the three count fields are degenerate (the subject
*is* one SKU). What the dialog wants from `preview` is `compatible` + `blockingReason` as the pre-Save
gate — **and 2732 does not state what `preview` returns for `scope=SKU`.** That is **Q2, still OPEN**
(§10). Until answered, B2 gates Save on the 422 response from the write itself, which always works.

**Security.** The endpoint lands under the existing `/v3/**` → `hasAnyAuthority("wms_user")` rule
(`SecurityConfiguration.java:136`). It is a **read**, so it is deliberately **not** admin-gated —
consistent with 2732's reasoning that `preview` reveals no more than the picker already shows, and
required by the ticket's *"read-only users may view the configured value"*. **2643 must not widen
`SecurityConfiguration`.**

**Constructor impact.** `ItemDataController`'s constructor is currently 11-arg
(`ItemDataControllerUnitTest.java:91-102`); adding `SkuPutawayQueryService` makes it 12 and
**breaks that test's construction**. Expect to touch `:91-102` — and see R2 (§11.0) on the collision with
2732 Step 9.

**Envelope completeness is a verify row, not a comment.** `A2-env` asserts **all seven** keys —
`locationId`, `locationName`, `source`, `sourceLabel`, `configuredFor`, `compatible`, `warning`. r1's
row was named "7-field" and asserted four; a four-field envelope would have passed it while the UI
silently lost `source` (the field 2732 §3.8 exists to stop Vue re-deriving precedence) and `locationId`
(the field the picker pre-selects with).

**Negative constraints on the handler:** no `putawayDestinationResolver` (D-F), and no
`httpRestService` — a putaway-config read must never touch the OMS notification path
(`ItemDataController.java:97-98`). Both are verify rows.

### 3.5 D-D — `GET /v3/putawayConfig/eligibleLocations?scope=SKU` (specified here, **handed to 2732**; A3 is the fallback)

> **`CONTRACT-PROVISIONAL` — re-derive from 2732's merged PR before writing tests.** `PutawayScope`,
> `blockingReason` and `PutawayDestinationValidator` are 2732's and are `draft`. **And as of r2 this
> subsection is a specification handed to 2732, not a 2643 deliverable** — see the ownership box below.
> See §3's blocking banner.

**Decision D3: server-side predicate evaluation. Do NOT widen `getLocationView()`, and do NOT
re-implement predicates in Vue.**

> **⚖ OWNERSHIP (r2, resolves Q5 — D12).** **2732 owns D-D.** This subsection is a complete
> specification handed to 2732's author; **A3 is 2643's named fallback, not its plan of record.**
> Three grounds, and the first is decisive:
> 1. **2732's own picker cannot ship without it.** 2732 `:1605` mandates a client-side P2.4 filter over
>    `/location/detailView`, and `ViewDtoService.java:815-822` exposes **none** of the flags (§2.4).
>    2732's Step 19 (`:2036`) is blocked **identically**. The endpoint is on 2732's critical path whether
>    or not 2643 exists.
> 2. **Building it in 2643 inverts the dependency direction of the whole feature family** — 2732's
>    merchant and warehouse pickers would consume a 2643-owned endpoint.
> 3. **Robustness is *higher* if 2732 owns it.** If 2643 shipped D-D and 2732 later reshaped
>    `blockingReason` or `PutawayScope`, 2643 would own a broken endpoint inside someone else's
>    controller.
>
> **Decision deadline: before A3's TDD gate opens.** If 2732 declines, 2643 ships A3 as specified here
> (1.5 d). Recorded as **D12**; the acceptance item is §5.1 row 0d.
>
> **Consequence for the verify script:** 2643 cannot assert the shape of constructs it did not write. The
> `A3-*` rows are therefore split — **consumer** rows (the dialog sources its items from
> `eligibleLocations`; it does **not** call `/location/detailView` and does **not** re-implement
> predicates in JS) are asserted unconditionally against 2643's own files, and the **contract** rows run
> only once the endpoint exists at all, *whoever* shipped it.

```java
// controller/PutawayConfigController.java  (2732's class — ONE read, specified by 2643)
@GetMapping("/eligibleLocations")
@Transactional(value = "tenantTransactionManager", readOnly = true)
public List<Map<String, Object>> eligibleLocations(@RequestParam PutawayScope scope,
                                                   @RequestParam(required = false) Long subjectId)
        throws BusinessException;
// row: { locationId, locationName, areaName, locationType, eligible, blockingReason }
```

| Field | Contract |
|---|---|
| `locationName` / `areaName` / `locationType` | display material; `locationType` is `location_type.sltname` |
| `eligible` | `true` when the location passes **every** SKU-scope predicate, P2.7(c) included |
| `blockingReason` | 2732's enum **as 2732 defines it** — `LOCKED \| FIX_ASSIGNED \| LANE \| null`. **r2 removes r1's `PICK_FACE` extension**: with D1 reversed there is no 2643-specific class to name, and extending a 2732 enum from a 2643 PR was an undeclared cross-plan mutation (§15, MUST-4) |

**r2 also deletes r1's `advisory` field.** It existed only to carry the old D1's "offered with a
warning" class. With D1 reversed, a row is `eligible` or it is not offered; no third state exists, and
no 2643-specific field is added to a 2732-owned type. This restores §14's principle 2 without
qualification.

The predicate authority is **2732's `PutawayDestinationValidator`**, called from the server. The
endpoint reports its verdict; it does not re-derive it. A `PutawayScope` parameter is carried so the
same endpoint serves 2732's merchant/warehouse pickers — at SKU scope the response is:

| Class | Predicates | Offered? | Measured on hydra DEV |
|---|---|---|---|
| **eligible** | passes all — P2.2, P2.3, P2.4, P2.5 **and P2.7(c)** | **yes** | **92** |
| **not offered** | fails any predicate: P2.7(c) pick face (511), P2.5 fix-assigned (154), P2.3 lane (22), P2.4 area flags (63) | **no** — and the picker says *why*, see §3.8.2 | 574 distinct rows |

**Both P2.5 and P2.7(c) are absolute.** 2732 §3.4c calls P2.5 *"load-bearing for D15"* and `:722` says
the same of P2.7(c) — *"absolute at all three scopes, tier 1 included."* Relaxing either from a 2643 PR
would (a) fail 2732's `skuWriteRejectsFixAssignedLocation` / `skuWriteRejectsPickFaceDestination` tests
(`:2210-2211`) and (b) arm the over-bound-bin path SBDEV-2796/2821 own. **SBDEV-2821 relaxes them, for
tier 1, when it ships tier-1 placement** (2732 `:722`, `:711`).

**Tiering and the lock warning are inherited, not reinvented.** 2732 §3.11.2 requires the SKU picker to
carry the same two-tier shape (default = `useforgoodsin`; advanced = `useforstorage` behind a
**"Show storage locations"** toggle that reveals a lock-contention warning) — 2732 `:1607` says so
explicitly, and `:1605-1607` gives the reason. **This warning survives r2 unchanged**: unlike the
pick-face banner it is about a hazard that is genuinely reachable — a *storage* destination is savable
today, and a receipt into one holds `FOR UPDATE` on that Location row for a whole multi-case receipt.
§7.4 row 8 explains why it is a scalability requirement and not a nicety.

**Excluded from the list:** the tier-4 lane itself (`location.name == 'PutAwayLane'`,
`WmsConstants.java:771`). Per Q3/F8 it passes every predicate, so without the exclusion an operator can
*pin* tier 1 to the fallback and then wonder why a later warehouse default does nothing. **"Clear /
Use default" is the only route back.** The exclusion test compares against the machine **name**
constant, never the display label (§3.6).

**H2 note:** if D-D lands as a repository query, keep it **JPQL with plain joins and booleans** — no
`nullif(...)::bigint` or other Postgres-only construct (2732 §7.7 row 6 flags exactly that in
`readCommittedDestination`), because the test SQL lane must stay H2-compatible.

### 3.6 D-F — the negative code-shape checks (all phases)

2732 mandates `check_N2_controller_delegates_not_resolves` for `ReceivingController` only. **2643 must
carry the identical check for `ItemDataController.java`.** Rationale, and it is not theoretical: an
implementer can satisfy every positive check by adding the facade method *and still* calling
`putawayDestinationResolver` directly from the controller — which reintroduces the
`Propagation.MANDATORY` → `IllegalTransactionStateException` → 500 on every call, while the script
stays green.

Four negative checks, in the verify script:

| id | Assertion | Failure it catches |
|---|---|---|
| `A2-neg-res` | `putawayDestinationResolver` appears **nowhere** in `ItemDataController.java` | 500 on every call to the new endpoint |
| `A2-neg-oms` | `httpRestService` appears nowhere in the new handler | a config read triggering an OMS inventory export |
| `B2-neg-leg` | the store action does **not** target `/itemData/setPutAwayLocation` | the tenant-wide `allEntries=true` cache flush, no validation, no audit |
| `B1-neg-corpse` | the commented `:100-123` block is gone from `skuData.vue` | dead code the ticket's missing edit form is attributed to |

**Negative-test the script itself.** Per the recorded landmine, a "N pass, 0 fail" means nothing until
you replay the pre-fix tree and watch it FAIL. §7.5.

### 3.7 The wording contract — inherit from 2731, invent nothing

`receivingForm.vue` already canonicalised this, with a comment at `:215-220` explaining why:

```js
// SBDEV-2731 Fix A. Mirrors WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE
// (WmsConstants.java:771) — this is the LOCATION NAME, not a display label. […]
// Comparing against the spaced display label below would make isPutawayOverride
// true for every SKU.
const DEFAULT_PUTAWAY_LANE_NAME  = 'PutAwayLane'          // :216  location.name — for COMPARISON
const DEFAULT_PUTAWAY_LANE_LABEL = 'Put Away Lane'        // :217  operator-facing text ONLY
```

with `isPutawayDestinationApplied` (tri-state, `:296-300`), `isPutawayOverride` (`:301-305`, compares
against the **NAME**) and `putawayDisplay` (`:309-314`, maps the machine name to the **LABEL**).

**2643 reuses both constants and the same comparison discipline.** 2731 has them in one place; a second
copy is the divergence risk, so **B1 extracts them to
`components/masterData/material/skuData/putawayWording.js`** and re-imports them into
`receivingForm.vue`, rather than making a third copy. Never render `PutAwayLane` to an operator; never
compare against `'Put Away Lane'`.

**The ticket's own wording, reconciled:** it writes `Default Putaway Location: PutawayLane` (no capital
A) in one place. The real name is `PutAwayLane`. **Use the code constant for comparison and the label
for display** — do not encode the ticket's typo.

### 3.8 The SKU edit surface (Phase B1 + B2)

Copy `components/masterData/material/packaging/editPackagingDialog.vue` (196 L) — the **only**
masterData create/edit dialog in the repo, and a sibling of the SKU screen
(`material/packaging/` next to `material/skuData/`). Not the `components/admin/` ones.

**3.8.1 Entry points — two, per `packaging.vue`'s precedent**

1. A pencil button in the **existing active** actions column at `skuData.vue:95-99`, beside the eye at
   `:97` — mirroring `packaging.vue:91-94`. Reachable without opening details first.
2. A button in `<full-details>`'s **`#actions` slot** (`fullDetails.vue:26`, already present) so the
   edit is reachable from the overlay. **Zero changes to `fullDetails.vue`.**

`fullDetails.vue` **cannot** host an editable field, and should not be made to: it is a generic
read-only renderer (`:10` `v-for`, `:11` exclude check, `:13-17` label/value spans, `:18` `getValue()`),
used by many screens. Making one field editable means either a cross-cutting per-field slot API (out of
2643's scope) or a `name`-specific special case — exactly the anti-pattern `:19`'s hardcoded
`name === 'priority'` already is.

Delete the commented `:100-123` block in the same commit. Do **not** resurrect the trash button or the
"Something 1/2/3" menu.

**3.8.2 `editSkuPutawayDialog.vue` — structure, matching the precedent exactly**

```
<v-dialog v-model="show" class="rounded-0" persistent max-width="400px">
  props: ['show', 'item']                        // no `mode` — edit-only, there is no create
  ── Current value              (read-only)  "Default Putaway Location: <configured name>"
                                            or  "Inherits: <sourceLabel> — <locationName>"
                                            from GET /v3/itemData/{id}/effectivePutawayDestination
  ── <location-picker>                       2732's components/common/LocationPicker.vue
                                             :items from GET /v3/putawayConfig/eligibleLocations?scope=SKU
                                             two tiers (goodsin default / storage behind the toggle)
                                             renders "<locationName> — <areaName>"   (§3.9 AC3)
  ── SCOPE banner               ALWAYS VISIBLE, above the picker  ← D1 (r2)
                                "Pick faces (flowbins) are not yet selectable as a SKU default.
                                 Pick-face putaway is tracked by SBDEV-2821 (see SBDEV-2732 Q9).
                                 {eligibleCount} of this warehouse's {totalCount} locations
                                 are currently eligible."
                                ⚠ {eligibleCount}/{totalCount} are COMPUTED AT RUNTIME from the
                                  eligibleLocations response — NEVER literals. See §3.8.2a(3).
  ── storage-tier lock warning  v-if the "Show storage locations" toggle is on   (2732 :1607)
  ── compatibility warning      v-if effective.compatible === false  → render `warning` verbatim
  ── actions:  [Clear / Use default]   [Cancel]   [Submit]
```

**3.8.2a The scope banner is a deliverable, not decoration (D1, §14 principle 4).**

r1 shipped a *per-row advisory* banner on pick-face rows. r2 removes those rows from the list entirely,
which creates a new and worse failure if nothing replaces the banner: **an operator opens the picker,
types "ICE", finds nothing, and concludes the search is broken** — a silent failure in place of a
legible one. So the banner moves from per-row to **always-visible**, and it must:

1. name **SBDEV-2821** as the ticket that will make pick faces selectable;
2. name **SBDEV-2732 Q9** as the design decision behind the current restriction, so the reason is
   traceable and not folklore;
3. state the eligible count, so "the list looks short" is confirmed rather than suspected.

> **⚠ The counts MUST be computed at runtime, never written as literals.** `92` and `666` appear
> throughout this plan as **measurements of `wh01_hydra_v2` on 2026-08-07** (frontmatter, §2.2). They are
> wrong for wineco, for ShipItEZ, for hydra PRD, and wrong for hydra DEV itself the moment a location is
> added. A banner asserting "92 of this warehouse's 666 locations" to an operator whose warehouse has
> neither number is **confidently wrong** — a worse failure than the silent one this banner exists to
> prevent, and a direct inversion of §14 principle 4.
>
> Both numbers are already in the response: §3.5's row shape is
> `{ locationId, locationName, areaName, locationType, eligible, blockingReason }` and the endpoint
> returns **both** classes (Jest `pickerNeverOffersPickFaces` depends on it). So the dialog computes
> `eligibleCount = items.filter(r => r.eligible).length` and `totalCount = items.length`. That is
> **reading a server verdict**, not re-deriving a predicate — §14 principle 2 is untouched.

The same three facts belong in the picker's **empty-state** text (a client filter can produce zero rows
even when many are eligible) — including the computed counts, on the same rule.

Verify rows: `B2-banner` (names SBDEV-2821), `B2-banner2` (names 2732 Q9 / SBDEV-2732), **`B2-banner3`
(no hard-coded tenant counts in the dialog)**; Jest `scopeBannerNamesBlockingTicket` and
**`scopeBannerCountIsComputedNotLiteral`**.

**3.8.2b `LocationPicker.vue`'s props/events contract — SPECIFIED HERE, handed to 2732 (Q6).**

r1 filed this as an interim guess in §10.2. r2 promotes it to a **written spec** and makes 2732's
acceptance of it a §5.1 item (row 0b). Grounds: waiting costs the entire user-visible half of the ticket
while its `urgent` priority runs; specifying costs at worst one dialog's binding rewrite, and
`B2-picker` detects the divergence.

The shape is **the repo's own idiom**, taken from the *real* precedent — `createBol.vue:68-76`, the
file's only `v-autocomplete` (§10.3 **C7**; 2732's cited `:109-121` + `:125` "Lookup" button do **not**
exist):

```
props:   :items       Array of eligible rows, exactly as GET /putawayConfig/eligibleLocations returns them
         :value       the currently selected locationId  (v-model)
         :disabled    Boolean — the permission gate (§3.11), applied as :disabled never v-if
         item-text    String, default 'locationName'   (createBol.vue:74 uses item-text="label")
         item-value   String, default 'locationId'     (createBol.vue:75 uses item-value="value")
events:  @input       the selected locationId — the v-model contract (createBol.vue:69 v-model)
         @select      the FULL row object, so the caller reads blockingReason / areaName / locationType
                      without a second lookup or a client-side re-derivation (§14 principle 2)
```

`@select` emitting the whole row is the load-bearing clause: without it the dialog must either refetch
or re-derive, and re-deriving is exactly what D3 forbids.

Idiom rules, all from the precedent:

- Field labels are `<v-card-text class="pa-0 font-weight-bold">Label</v-card-text>` **above** the
  control — **not** Vuetify `label=` props.
- **Validation is a hand-rolled `validated()` returning a boolean and firing `this.$toast.error(...)`
  per failure.** No `v-form`, no `rules`, no Vuelidate.
- `save()` wraps in `CommUtil.showPageSpinner(this)` / `hidePageSpinner(this)`, dispatches, then
  `this.close()`. `close()` calls `resetFields()` then `this.$emit('close')`.
- Buttons: `<v-btn class="justify-start bigButton" tile depressed dark @click="close">Cancel</v-btn>`
  and `<v-btn class="justify-start bigButton ml-0" tile depressed color="primary" dark @click="save">Submit</v-btn>`.

**3.8.3 The store write action — `store/masterData/skuData.js`**

The store currently has `getSkuData` (`:46`), `searchSkuData` (`:63`), `getSkuDetail` (`:88`) and
**zero write actions of any kind**. 2643 adds the first, copying `store/masterData/packaging.js:114-128`:

```js
// data: { id, locationId }   — locationId == null  ⇒  CLEAR (omit the query param entirely)
async setSkuPutawayLocation(context, data) {
  try {
    const qs = data.locationId == null ? '' : `?locationId=${data.locationId}`
    const results = await this.$axios.$put(`/putawayConfig/sku/${data.id}${qs}`)
    if (results && results.errors) {
      this.$toast.error(results.errors[0].message)
    } else {
      this.$toast.success('Default putaway location updated')
    }
    // Re-read THIS SKU only. NOT searchSkuData — that re-pages the table and loses the user's place.
    await context.dispatch('getSkuDetail', { id: data.id })
  } catch (e) {
    // 2732's writes return REAL HTTP errors (422 validation, 409 stale confirmation), so they land
    // HERE, not in results.errors. Surface the body or every validation message is swallowed.
    const msg = e?.response?.data?.errors?.[0]?.message
             ?? e?.response?.data?.message
             ?? 'Error: Request failed due to a network or server issue. Please retry.'
    this.$toast.error(msg)
  }
},

getSkuEffectivePutaway(context, data) {
  return this.$axios.$get(`/itemData/${data.id}/effectivePutawayDestination`)
},
```

Three deliberate deviations from the packaging precedent:

1. **`PUT /putawayConfig/sku/{id}`** (2732 §3.5a) — **not** `PUT /itemdata/{id}` (the HAL path) and
   **not** `GET /itemData/setPutAwayLocation/{i}/{l}` (unvalidated, unaudited, wrong verb, tenant-wide
   cache flush). Verify row `B2-neg-leg`.
2. **Re-dispatch `getSkuDetail` for the edited SKU**, where `editPackaging:122` re-dispatches
   `getPackaging` (the whole list). `searchSkuData` re-pages the table.
3. **Surface `e.response.data`.** The bare "network or server issue" toast would hide every validation
   message the ticket asks to be actionable.

⚠ **Related landmine — CORS.** `response.reset()` strips the CORS headers Spring Security's
`CorsFilter` already wrote, after which the browser blocks the 422 and the UI shows its generic network
toast regardless of the code above. **If 2732's exception handler uses `reset()` instead of
`resetBuffer()`, the 422 body never reaches the operator.** MockMvc installs no `CorsFilter`, so no
unit test catches it. **Manual row M6 is the ONLY detector.** ⚠ *r2 correction: r1 promised a verify row
`B2-cors` here. No such row exists, and none can — the `reset()` vs `resetBuffer()` call lives in
**2732's** exception handler, and a grep asserting its content would be both a cross-plan assertion
(§14 principle 1) and unable to see the browser-side effect that actually matters. Citing a check that
does not exist is exactly the over-claim this plan's §14 principle 5 forbids.*

**3.8.4 `locationId` omitted ⇒ CLEAR.** 2732 §3.5a: `@RequestParam(required = false) Long locationId`,
*"omitted ⇒ clear"*. The Clear button must omit the parameter, **not** send `?locationId=` or
`?locationId=null`. Jest asserts the exact URL.

**3.8.5 AC5 / persistedState.** `masterData.skuData` **is** persisted to `localStorage['vuex-web']`
(`plugins/persistedState.client.js:26-29` — an allow-nothing-out reducer excluding only
`warehouseTimezone`, `selectedWarehouse`, `warehouses`), so the SKU list rehydrates from localStorage
on refresh. **The overlay is safe** because `skuData.vue:304` always refetches via `getSkuDetail`, which
has no caching. This is the second reason Q4 answers **no table column**: a column would render a
stale rehydrated value after a write. No exclusion is added to `persistedState.client.js`.

### 3.9 Three ticket requirements that name things the schema does not have

Documented reinterpretations, **never silent**. Each is a scope clarification for the reviewer, not a
blocker.

| AC | Ticket wording | Reality | This plan's reading |
|---|---|---|---|
| AC6 | *"only valid, **active**, stock-compatible locations"* | `Location` has **no `active` column** — `Location.java:32-41` is the 5 lane booleans; `information_schema` count of `location.active` = **0** | **`entityLock == NOT_LOCKED`** (`WmsConstants.java:1188-1195`) is the active proxy — 2732's P2.2. Measured: 666 of 666 unlocked, so this predicate rejects nothing on this tenant today |
| AC6 | *"shipping lane"* | no `shippinglane` flag exists | nearest is **`gate`** (`Location.java:41`, 7 rows). Rejected by P2.3 like every other lane flag |
| AC3 | *"displays meaningful location information"*, ticket renders `ICE-PACK-01 — Ice Pack Pick Location` (a **code — name** pair) | `Location` has **`name` only**; `getLocationView()` exposes `locationName`, `areaName`, `locationType` (= `sltname`). **There is no location code column** | render **`locationName — areaName`** (falling back to `locationType` when the area is null). The two-part shape the ticket asks for is preserved; the *fields* are the ones that exist |

### 3.10 What this plan explicitly does NOT build

- **Any migration.** 2643 ships zero SQL. `V2.2.11` is 2732's.
- **Any change to `ReceivingService`** — the ticket's own "Receiving Behavior Boundary" defers routing
  behaviour, and 2732 §3.7 owns it regardless.
- **`LocationPicker.vue` itself** (2732 §3.11.2 Step 19) — 2643 *consumes* it. Q7 → strict reuse; a
  second picker would mean two implementations of a safety-critical filter.
- **The merchant and warehouse tiers.**
- **A general web-UI role-gating framework** — cross-cutting across every screen, already a named
  follow-up in 2732 §8.4. §3.11 builds one bounded gate, not a framework.
- **The `eligibleLocations` endpoint itself, as plan of record.** D-D is **specified** in §3.5 and
  **handed to 2732** (D12). A3 remains as a named fallback with a decision deadline.
- **The `@PreAuthorize` constant swap in 2732's files.** §3.1's r2 scope box. 2643 ships the detector and
  a prerequisite row; the edit belongs to 2732's review or SBDEV-2863.
- **Any relaxation of P2.5 or P2.7(c).** Both stay absolute. SBDEV-2821 relaxes them for tier 1
  (2732 `:722`). 2643 does not extend `blockingReason` and adds no `advisory` field (r2, §3.5).
- **A count-and-confirm preview flow.** Answered by 2732's own signature (Q8/D-x): `setSku` carries
  **no** `confirmIncompatibleSkus`; only `setMerchant` and `setWarehouse` do. Count-and-confirm is a
  bulk-blast-radius device and one SKU has no blast radius. 2643 needs only the **blocking** signal.
- **A table column on the SKU grid** (Q4).
- **Repairing the 9 endpoints F1 breaks** — SBDEV-2863's.

### 3.11 The UI permission gate — `disabled`, not `v-if`

There is no role gating anywhere in `wms2-web-ui` (§2.5). 2643 builds the first one, bounded:

```js
// computed, in skuData.vue and editSkuPutawayDialog.vue
isPutawayConfigAdmin() {
  // First consumer of nuxt.config.js:167's appAdminGroup, and the first read of
  // store/index.js:5's affiliatedGroups that is not a console.log (layouts/default.vue:467).
  return (this.$store.state.affiliatedGroups || []).includes(this.$config.appAdminGroup)
}
```

Applied as **`:disabled` plus a tooltip**, on the pencil button and the dialog's Submit —
**never `v-if`**. The ticket says read-only users **may view** the configured value; hiding the field
would fail AC1 for them, and hiding the button hides the fact that the capability exists.

**This gate is defence-in-depth only.** The real boundary is `PutawayConfigService`'s `@PreAuthorize`
(2732 N5 / §3.12: *"the security boundary is the backend, and it is enforced in `PutawayConfigService`,
not on the event-handler methods"*) — and that boundary is **inoperative until A0 lands** (F1).
Saying so explicitly is what keeps AC12 *explicitly* met by backend enforcement rather than
*implicitly* unmet.

---

## 4. File Change Summary

**`v2/wms2-api`**

**Files 2643 writes into that SBDEV-2732 owns: ZERO in the plan of record.** r1 had four (a
security-annotation swap in two of them, a method added to a third, `blockingReason`/`advisory` mutations
in a fourth). r2 removes all four — see §15. Only the A3 **fallback** rows touch a 2732 file, and they
apply only if 2732 declines D-D.

| File | Change | Phase | Description |
|---|---|---|---|
| `src/test/java/net/aim_ai/wms/unit/CustomMethodSecurityExpressionRootUnitTest.java` | **Modify** | A0 | NEW `@Nested` class that **evaluates** the SpEL string (§3.1). ⚠ **The only A0 deliverable** — the constant swap in 2732's files is out of 2643's scope (§3.1 r2 box, §5.1 row 0e) |
| `src/main/java/net/aim_ai/wms/service/ItemdataService.java` | **Modify** | A1 | `getItemdataDetails` `:166-171` → emit `putawayLocationId` unconditionally when non-null (§3.3) |
| `src/test/java/net/aim_ai/wms/unit/service/ItemdataServiceUnitTest.java` | **Modify** | A1 | 4 cases: `:415-428`, `:468-471`, `:475-498` (rewritten), `:585-604` |
| `src/main/java/net/aim_ai/wms/service/SkuPutawayQueryService.java` | **Add** — **2643-owned** | A2 | `describeForSku(Long)`, `@Transactional(value="tenantTransactionManager", readOnly=true)`, injecting 2732's `PutawayDestinationResolver` (§3.2). ⚠ **r2: replaces r1's "add a method to `PutawayDestinationQueryService.java`"** |
| `src/main/java/net/aim_ai/wms/controller/ItemDataController.java` | **Modify** | A2 | new `GET /{id}/effectivePutawayDestination` + `toEnvelope`; constructor gains `SkuPutawayQueryService` (11→12 args) |
| `src/test/java/net/aim_ai/wms/unit/controller/ItemDataControllerUnitTest.java` | **Modify** | A2 | fix the constructor call at `:91-102`; append a **NEW** `@Nested EffectivePutawayDestination` class at EOF (`:374`). **Do NOT touch `:119-158`** — 2732 Step 9 owns it |
| `src/test/java/net/aim_ai/wms/unit/service/SkuPutawayQueryServiceUnitTest.java` | **Add** | A2 | `describeForSku` delegation + the two transaction-annotation assertions |
| `src/main/java/net/aim_ai/wms/service/PutawayDestinationQueryService.java` | **unchanged** | — | 2732's file. `describeForSku` deliberately does **not** land here (§3.2); `A2-neg-2732f` asserts it |
| `src/main/java/net/aim_ai/wms/controller/PutawayConfigController.java` | **unchanged in the plan of record** | *A3 fallback only* | `GET /eligibleLocations` (§3.5) — **2732's to write** (D12). Touched by 2643 only if 2732 declines |
| `src/main/java/net/aim_ai/wms/service/PutawayConfigService.java` | **unchanged in the plan of record** | *A3 fallback only* | eligibility evaluation delegating to `PutawayDestinationValidator`; JPQL only, H2-safe. Same condition |
| `src/test/java/net/aim_ai/wms/unit/controller/PutawayConfigControllerUnitTest.java` | **unchanged in the plan of record** | *A3 fallback only* | `?scope=SKU` returns eligible / not-offered; the tier-4 lane is excluded; `FIX_ASSIGNED` stays blocked |
| — | **no `blockingReason` enum change** | — | **r2: `PICK_FACE` is NOT added.** D1 reversed ⇒ no 2643-specific reason code exists (MUST-4) |
| — | **no migration** | — | **2643 ships zero SQL** |

**`v2/wms2-web-ui`**

| File | Change | Phase | Description |
|---|---|---|---|
| `components/masterData/material/skuData/putawayWording.js` | **Add** | B1 | `DEFAULT_PUTAWAY_LANE_NAME` / `_LABEL` extracted from `receivingForm.vue:221-222` (§3.7) |
| `components/receiving/open/receive/receivingForm.vue` | **Modify** | B1 | import the two constants from the shared module instead of declaring them at `:221-222`. **No behaviour change** — 2731's tri-state and comparisons are untouched |
| `components/masterData/material/skuData/skuData.vue` | **Modify** | B1 | `:130` `exclude-fields` += `'putawayLocationId'`; `:142` relabel → `'Default Putaway Location'`; pencil button at `:95-99`; `#actions` slot button in `<full-details>`; **delete** `:100-123`; `isPutawayConfigAdmin` computed; mount the dialog |
| `components/masterData/material/skuData/editSkuPutawayDialog.vue` | **Add** | B2 | the edit surface (§3.8.2), incl. the always-visible **scope banner** naming SBDEV-2821 + 2732 Q9 (§3.8.2a) |
| `store/masterData/skuData.js` | **Modify** | B2 | `setSkuPutawayLocation` + `getSkuEffectivePutaway` (§3.8.3) |
| `test/components/masterData/material/skuData/skuData.spec.js` | **Add** | B1 | Edit affordance, exclude-fields, relabel, permission gate |
| `test/components/masterData/material/skuData/editSkuPutawayDialog.spec.js` | **Add** | B2 | Clear omits the param; **scope banner names SBDEV-2821**; validation toasts; picker filtered |
| `test/store/masterData/skuData.spec.js` | **Add** | B2 | the write action hits `PUT /putawayConfig/sku/{id}`, never the legacy GET |
| `components/common/fullDetails.vue` | **unchanged** | — | the `#actions` slot at `:26` already exists |
| `plugins/persistedState.client.js` | **unchanged** | — | §3.8.5 — the overlay always refetches, and there is no table column |

---

## 5. Phased Implementation Plan

Six phases across two repos. **A0 and A1 are implementable today; A2, A3, B1 and B2 are not.**

### 5.1 Prerequisites — MANDATORY

Every row is required. `N/A` carries a one-sentence rationale.

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| **0** | **External dependency — SBDEV-2732 Phase 1-API merged to `develop`** | The resolver, `Resolution` + `Source`, `PutawayDestinationQueryService`, `PutawayDestinationValidator` (P1 + P2), `PutawayConfigService.setSkuDestination`, `PutawayConfigController`, `putaway_config_audit`, `V2.2.11`, stop-seeding, `@NotNull` removed from `Itemdata.java:49`. **Verified 2026-08-07: none of it exists.** 2732's plan is `status: draft` | 2732 | **HARD BLOCKER on A2, A3, B2.** Not on A0, A1, B1. 2732 §5.1 row 4: *"SBDEV-2731 and SBDEV-2643 must not be worked independently while this is open"* |
| **0b** | **External dependency — SBDEV-2732 Phase 2-UI merged** (`components/common/LocationPicker.vue`), **and 2732's acceptance of §3.8.2b's props/events spec** | Q7 → strict reuse, so B2 waits for the component. ⚠ **2732 specifies its behaviour but NOT its props/events API** — no prop list, no event list, no `v-model` contract in 2732 §3.11.2, §3.11.3 or Step 19. **r2 writes that spec (§3.8.2b) and hands it over.** ACCEPTANCE ITEM: 2732's author confirms `:items` / `:value` / `:disabled` / `item-text` / `item-value` + `@input` / `@select`-emits-the-full-row, or returns a counter-spec | 2732 | **HARD BLOCKER on B2.** ⚠ **Do not start B2 until the contract is pinned in writing** — a picker whose contract changes mid-implementation is R5 in its most expensive form. **Q6 is now SPECIFIED-PENDING-ACCEPTANCE, not open-ended** |
| **0c** | **External dependency — SBDEV-2863** (`Authority.IS_SB_ADMIN`) | SBDEV-2863 owns repairing the 9 pre-existing broken endpoints **and the constant itself**. 2643 Phase **A0** ships only the **detector** | 2863 | A0's detector is **independent and un-blocked** — pull it forward ahead of both tickets. F1 blocks 2732 as much as 2643 |
| **0d** | **Ownership decision — who ships D-D (`GET /putawayConfig/eligibleLocations`)?** | **2732, per D12.** §3.5 is a full specification handed to 2732's author. **DECISION DEADLINE: before A3's TDD gate opens.** If 2732 declines in writing, 2643 ships A3 as the fallback (1.5 d, §5.5) | 2732 author + 2643 author | **Blocks BOTH tickets' pickers** — 2732's Step 19 (`:2036`) is blocked by the identical gap (`:1605` mandates a filter over a payload that carries none of the flags). **Unsettled ⇒ the work is done twice or not at all.** Recorded as Q5 → resolved by D12 |
| **0e** | **SBDEV-2732 must NOT merge carrying `@PreAuthorize(Authority.IS_SB_ADMIN)`** | The constant names a SpEL method that does not exist (F1), so **every one of 2732's admin-gated writes would return 500 for everyone, `sb_admin` included.** 2732 writes it at `:905, 917, 925` (`PutawayConfigService`), `:1491` (`validateOnly`) and `:972, 978, 985` (`PutawayConfigController`). Required value: `Authority.getExpForRole(Authority.SB_ADMIN_ROLE)`, or the constant repaired by SBDEV-2863 first | **2732 review, or SBDEV-2863 — NOT 2643** | ⚠ **r2 removes this edit from 2643's scope** (§3.1 r2 box, §15): a 2643 PR reverting a security annotation a 2732 PR deliberately added, in 2732's own file, is the wrong home. **Detector:** verify row `X-2732-authz` FAILS if 2732's file lands with the broken constant; manual **M8** returns 500 instead of 403. **AC12 cannot be met until this is resolved by someone** |
| 1 | **Database state** | **No change required and none made. 2643 ships ZERO migrations.** Flyway head on `origin/develop` = `V2.2.10` (swept across all remotes). `V2.2.11` is 2732's and is 2732's operator gate, not this plan's | — | **Consequence for A1:** `putawaylocation_id` is still `NOT NULL` and `Itemdata.java:49` still carries `@NotNull` when A1 ships. A1's added key is **read-only**, so it is unaffected. **AC4 stays unreachable until 2732's `V2.2.11` is both merged AND applied per tenant** |
| 2 | **Feature flags / system properties** | **N/A** — 2643 introduces no toggle and reads none. It inherits 2732's `DEFAULT_PUTAWAY_LOCATION` sysprop transitively through the resolver and never touches it directly | — | Rationale recorded so the empty row reads as a decision |
| 3 | **Config / env changes** | **One, and only for B1's gate:** `APP_ADMIN_GROUP` must be set to the real admin group in every environment, or `nuxt.config.js:167`'s default `'/wms/wh/wms_admin'` applies. **It is read nowhere today**, so nobody has ever validated it | author + ops | If the default is wrong for a tenant, `isPutawayConfigAdmin` is `false` for everyone and the Edit button is disabled for all users — a **visible** failure, not a silent security hole (the backend is the boundary). Manual row **M7** |
| 4 | **Deploy-order dependencies — `B1-pre` is a HARD PREREQUISITE OF A1** | **`B1-pre` (one line: `'putawayLocationId'` added to `skuData.vue:130`'s `exclude-fields`) MUST be merged and deployed BEFORE A1 merges.** Not "prefer that ordering" — **required.** Then **A2 → B2** (and A3 → B2 only under the fallback). No OMS dependency, no `oms-laravel-api` dependency | author | ⚠ **r2 upgrades this from permission to gate.** The line is a **provable no-op today** — `exclude-fields` naming a key the payload does not yet carry changes nothing — so there is no cost to landing it first and no reason to accept the alternative. The alternative is not hypothetical: **DEV auto-deploys on push**, and §6.1 predicts that A1-without-B1-pre renders a stray `PutawayLocationId` raw-integer row on **every** SKU details overlay within minutes. Deploying a known user-visible cosmetic defect because the fix was optional is not a tradeoff, it is an avoidable one. **M2 is a pre-B1-pre *observation* of the hazard (run it on a local build or a branch preview), not a licence to ship A1 alone to DEV.** §8 rollout step 2 |
| 5 | **Data migration** | **N/A** — no backfill, no one-off SQL, no DBA task. 2732's `V2.2.11` carries the only backfill in this feature family, and it is scoped inside that migration | — | |
| 6 | **External systems** | **N/A** — no OMS notification, no outbox row, no printer, no Keycloak realm or client change. Explicitly: a putaway-config change must **not** trigger an inventory export (verify row `A2-neg-oms`) | — | |
| 7 | **Access / permissions** | `@PreAuthorize(Authority.getExpForRole(Authority.SB_ADMIN_ROLE))` (→ `hasAuthority('sb_admin')`) on 2643's write path, via A0. **No new Keycloak role and no new group** — `sb_admin` already exists (`Authority.java:19`). `GET /{id}/effectivePutawayDestination` is deliberately **not** admin-gated: it is a read, and the ticket requires read-only users to see the value | author | The `/v3/**` → `hasAnyAuthority("wms_user")` rule (`SecurityConfiguration.java:136`) must **not** be widened. A0 must land before any write path claims to be gated |
| 8 | **Monitoring / alerts** | **2643 adds no metric.** It inherits 2732's `PutawayResolutionMetrics`. Ops must add a panel for **`wms2.putaway.resolution{source="SKU_OVERRIDE"}`** — the only correct adoption detector for *this* ticket | author + ops | ⚠ **2732 §8.1 (`:2293`) makes non-zero tier-2/3 usage a condition for closing 2643.** That is the wrong signal for a SKU-tier ticket: `MERCHANT_OVERRIDE`/`WAREHOUSE_DEFAULT` counters can stay at zero forever while 2643 works perfectly. **Raise at review; 2643's closure gate should be `resolution{source="SKU_OVERRIDE"} > 0`** |
| 9 | **Deadlock-retry hardening — is the deferred *"stock-move deadlock-retry hardening"* ticket a prerequisite of 2643?** | **NO — and this row exists so that nobody re-adds it.** 2732 `:2308`(i) makes that ticket *"an **absolute** prerequisite before **Q9 widens P2.4 to admit pick locations**"*, and 2732 **Q9** (`:2561`) answers **No** to that widening. **r1's D1 did precisely what Q9 declines, for the same physical reason**, so r1 inherited the price — and answered it with a UI banner, which is not retry infrastructure. **r2's D1 widens nothing:** the eligible set is 2732's own 92, P2.7(c) is enforced, and 2643 arms no path 2732 has not already accepted | — | ⚠ **What DOES remain is 2732's *own* accepted risk, unchanged by 2643.** `:2308`(i)'s **first** clause makes the deadlock ticket a prerequisite *"before any tenant points tier 2 or tier 3 at a live storage location"*, and the `useforstorage` advanced tier lets an operator point a **SKU** at one. **2643 inherits that as 2732's condition, not as a new one**, and mitigates it exactly as 2732 requires: the picker defaults to `useforgoodsin`, storage sits behind the toggle + lock warning (2732 `:1607`, §3.5), and the log-based `40P01` detector (§7.7) stays. See §7.4 row 8 |

### 5.2 Phase A0 — the SpEL detector (`wms2-api`) — **test-only**

| Aspect | Detail |
|---|---|
| **Goal** | the F1 defect class becomes **detectable**, before 2732 builds a security boundary on it |
| **Changes** | §3.1's detector **only**: a new `@Nested` class in `CustomMethodSecurityExpressionRootUnitTest` that **evaluates** the SpEL string against a real `CustomMethodSecurityExpressionRoot`. ⚠ **r2: NO constant swap.** The `@PreAuthorize` edit in 2732's files is out of 2643's scope — §3.1's r2 box, §5.1 row 0e. Do **not** repair the 9 pre-existing endpoints either (SBDEV-2863) |
| **Testing** | `mvn test -Dtest=CustomMethodSecurityExpressionRootUnitTest`. Negative-test it: temporarily assert `Authority.IS_SB_ADMIN` resolves and confirm the test **FAILS** with `EL1004E`, then revert the assertion |
| **Risk** | **NONE — test-only, zero production bytes, zero blast radius** (§8.2 row 1). This is the one artefact in the plan that is unblocked, un-stacked and protects a third party |
| **Branch** | `fix/SBDEV-2643-A0-sb-admin-spel` |
| **Effort** | 0.5 d |

### 5.3 Phase A1 — `putawayLocationId` in the details payload (`wms2-api`)

| Aspect | Detail |
|---|---|
| **Goal** | the UI can pre-select the configured value, and "invalid" becomes distinguishable from "inherits" |
| **Changes** | §3.3. `ItemdataService.getItemdataDetails` `:166-171`; four `ItemdataServiceUnitTest` cases |
| **Testing** | `mvn test -Dtest=ItemdataServiceUnitTest` + `mvn clean compile`. **Mutate-then-check** each new assertion: flip the production line, confirm the test fails, restore |
| **Risk** | **LOW code, MEDIUM deploy.** 15 call sites consume the widened payload (§6.2); 12 of them are provably safe, 3 need the `exclude-fields` companion. R4 (§11.0). ⚠ **HARD-GATED on `B1-pre` being deployed first** — §5.1 row 4 |
| **Branch** | `feature/SBDEV-2643-A1-itemdata-details-putaway-id` |
| **Effort** | 0.5 d |

### 5.4 Phase A2 — the effective-destination read (`wms2-api`)

| Aspect | Detail |
|---|---|
| **Goal** | one server-side answer to "where does this SKU actually go, and is it compatible?" |
| **Changes** | §3.2 (D-A) + §3.4 (D-B). **NEW 2643-owned `service/SkuPutawayQueryService.java`** — r2 no longer edits 2732's facade. New `@Nested EffectivePutawayDestination` appended to `ItemDataControllerUnitTest`; new `SkuPutawayQueryServiceUnitTest`. ⚠ **No A0 constant swap** (§5.1 row 0e) |
| **Testing** | `mvn test -Dtest=ItemDataControllerUnitTest` and `-Dtest=SkuPutawayQueryServiceUnitTest`. ⚠ `-Dtest='Outer#method'` **silently no-ops for `@Nested`** — name the nested class. Plus `mvn clean compile` for the 12-arg constructor |
| **Risk** | **MEDIUM (was HIGH in r1).** r2 removes the two coupling sources that made it HIGH: the method-into-2732's-file and the security-annotation swap. What remains is a **type-level** dependency on `Resolution` / `PutawayDestinationResolver` — a compile error if 2732 reshapes them, not a three-way merge (R1 ↓, R2 unchanged: the test file collision at `ItemDataControllerUnitTest` is real and mitigated by the new nested class). **Re-verify every §3 contract against 2732's merged PR before writing a single test** (R5, §3's banner) |
| **Branch** | `feature/SBDEV-2643-A2-sku-effective-putaway` — **branched from 2732's Phase-1 MERGE COMMIT on `develop`, never from 2732's branch** (§8) |
| **Effort** | 1.5 d after 2732 Phase 1-API merges |

### 5.5 Phase A3 — the eligible-locations read (`wms2-api`) — **FALLBACK PHASE, not the plan of record**

| Aspect | Detail |
|---|---|
| **Status** | ⚠ **CONDITIONAL.** D-D is **specified in §3.5 and handed to 2732** (D12, §5.1 row 0d). A3 exists only for the case where 2732 declines. **Decision deadline: before A3's TDD gate opens.** Expected outcome: **A3 is a 0-day phase** |
| **Goal** | the picker offers exactly the right locations, evaluated once, server-side |
| **Changes** | §3.5 (D-D). `GET /v3/putawayConfig/eligibleLocations`, the two-class response (eligible / not-offered), the tier-4-lane exclusion. ⚠ **r2: no `advisory` field, no `PICK_FACE` reason** — both were D1's apparatus |
| **Testing** | `mvn test -Dtest=PutawayConfigControllerUnitTest` + a service-level case per predicate. **JPQL only** — H2-safe (§7.3 row 7) |
| **Risk** | **MEDIUM.** Under the fallback, 2643 writes an endpoint into 2732's controller and a query into 2732's service — the largest cross-plan write surface remaining anywhere in the plan, which is itself an argument for the hand-over. **The verify script does not assert 2643's authorship of these constructs** (§13's A3 note): the contract rows run whoever ships them, and the consumer rows are what 2643 is accountable for |
| **Branch** | `feature/SBDEV-2643-A3-eligible-locations` (only if the fallback fires) |
| **Effort** | 1.5 d — **0 d if 2732 absorbs it, which is the expectation** |

### 5.6 Phase B1 — the SKU screen surface (`wms2-web-ui`)

| Aspect | Detail |
|---|---|
| **Goal** | the edit affordance exists, the payload renders cleanly, wording is shared not copied |
| **Changes** | §3.7 + §3.8.1 + §3.11. `exclude-fields` += `'putawayLocationId'`; relabel `:142`; pencil at `:95-99`; `#actions` slot button; **delete `:100-123`**; `isPutawayConfigAdmin`; extract `putawayWording.js` and re-import into `receivingForm.vue` |
| **Testing** | `export PATH="$HOME/.nvm/versions/node/v24.15.0/bin:$PATH"` then `node_modules/.bin/jest test/components/masterData/material/skuData/skuData.spec.js --coverage=false`. **Re-run `receivingForm.spec.js`** — B1 edits that file's constant declarations |
| **Risk** | **LOW–MEDIUM.** Touching `receivingForm.vue` risks regressing 2731's just-merged display; its spec is the guard. The Edit button must be **disabled with a "coming soon" tooltip** if B1 ships before B2 |
| **Branch** | `feature/SBDEV-2643-B1-sku-putaway-surface` |
| **Effort** | 1 d |

### 5.7 Phase B2 — the edit dialog and the write (`wms2-web-ui`)

| Aspect | Detail |
|---|---|
| **Goal** | an authorized operator can set, change and clear a SKU's default putaway location |
| **Changes** | §3.8.2 + §3.8.2a + §3.8.2b + §3.8.3. `editSkuPutawayDialog.vue`; `setSkuPutawayLocation` + `getSkuEffectivePutaway`; `LocationPicker` integration against §3.8.2b's contract; **the always-visible scope banner naming SBDEV-2821 + 2732 Q9**; Clear; 2 Jest specs |
| **Testing** | the 2 new specs, `--coverage=false`. Copy the idiom from `test/components/receiving/open/receive/receivingForm.spec.js`: `shallowMount`, `@/` alias, a `mount*` helper hand-building `$axios` as `{ $get: jest.fn(url => …), $put: jest.fn() }` branching on `url.includes(...)`, and `$store` as a **plain object literal** with a nested `state` tree — no Vuex, no localVue. `jest.config.js` has **no `roots` key** |
| **Risk** | **HIGH.** Blocked on 2732 Phase 1-API **and** Phase 2-UI, plus A2 (and A3 only under the fallback). `LocationPicker.vue`'s props/events API is **specified in §3.8.2b and pending 2732's acceptance** (prereq 0b / Q6). ⚠ **The scope banner's wording lives here and is the plan's only mitigation for D1's user-visible consequence** — get it reviewed by Scott Dalton / David Oppenheim before merge, because it is what an operator reads when the ICE PACK location is not in the list |
| **Branch** | `feature/SBDEV-2643-B2-sku-putaway-dialog` |
| **Effort** | 2.5 d after all blockers clear |

### 5.8 Fallback if 2732 slips

A0's detector + `B1-pre` + A1 + B1 deliver AC1's configured-value display, the relabel, the shared
wording module, the permission computed, and the whole surface. **Do not ship a visible-but-dead Edit
button.** Either hold B1 with A1 and ship the UI as one coherent change once B2 is unblocked, or ship B1
with the button `disabled` and a tooltip naming the blocking ticket.

⚠ **`B1-pre` is not part of this fallback discussion — it is a prerequisite of A1 in every scenario**
(§5.1 row 4). r1 phrased this as *"shipping A1 alone is safe only if B1's `exclude-fields` line has
already deployed"*, which reads as a conditional permission. It is a gate: **A1 does not merge until
`B1-pre` is deployed.**

**The honest read of this section:** if 2732 slips indefinitely, 2643 ships ~6 lines of production code
(one `details.put`, one `exclude-fields` entry, one label, plus the B1 surface) and one test-only
detector. That is a real but small deliverable, and it is the *whole* of what 2643 can be held to before
2732 merges. Everything else in this document is either a consumer plan or a specification handed to
2732 — §14's principle 1, made explicit.

### 5.9 Implementation Checklist

- [ ] Re-fetch **both** repos and diff `develop..origin/develop` **per repo** before enumerating anything — the recorded process landmine from SBDEV-2781 (a local `develop` 11 commits stale made a plan's primary fix already-merged)
- [ ] **Re-derive §3.2, §3.4 and §3.5 from 2732's merged PR** — all three are `CONTRACT-PROVISIONAL`; see §3's blocking banner (R5). 2732's §12 changelog shows P2.5 flipped and reverted the same day, P2.7(c) becoming implementable only on 2026-08-06, and 2732's own D18 (`:103-106`) records no independent review pass
- [ ] A0 detector test; negative-test it against `Authority.IS_SB_ADMIN`
- [ ] **Send §5.1 row 0e to 2732's reviewer** — 2732 must not merge with `@PreAuthorize(Authority.IS_SB_ADMIN)`. 2643 does **not** fix it
- [ ] **`B1-pre` merged AND deployed** — the hard prerequisite of A1 (§5.1 row 4)
- [ ] A1 + the 4 test-case edits; mutate-then-check each
- [ ] **Send §3.5 to 2732's author and get D-D ownership in writing** (Q5 → D12, §5.1 row 0d) — before A3's TDD gate
- [ ] **Send §3.8.2b's picker props/events spec to 2732's author and get acceptance or a counter-spec** (Q6, §5.1 row 0b) — before B2's TDD gate
- [ ] Get the **scope banner's wording** (§3.8.2a) reviewed by David Oppenheim / Scott Dalton before B2 merges — it is what an operator reads when the ICE PACK location is absent
- [ ] A2, A3 (each branched from a 2732 merge commit, ancestry asserted — §8)
- [ ] B1, B2
- [ ] `git checkout src/test/resources/archunit_store/` before **every** commit — `mvn test` mutates those tracked files
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh` — 0 FAIL, and the SKIP count matches the phases not yet reached
- [ ] Manual test plan M1–M12 executed and recorded (§7.5)
- [ ] Code review; every High/Medium finding fixed

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| `getItemdataDetails` payload | `putawayLocation` (name) present only when the id is non-null **and** the FK resolves | `putawayLocationId` added whenever the id is non-null; `putawayLocation` unchanged | **🟡 additive.** One consumer of 15 renders unknown keys generically — mitigated by one array entry (§6.1) |
| "configured but invalid" | indistinguishable from "not configured" — both omit every key | id present, name absent | **🟢 strictly more information.** Enables AC8 |
| `GET /v3/itemData/itemdataDetailsById/{id}` | 3 consumers | same 3 | 1 needs the `exclude-fields` companion; 2 are field-explicit |
| `GET .../itemdataDetailsByNumberAndClientNumber/{n}/{cn}` | 12 consumers, all → `skuInfo.vue` | same 12 | **🟢 all safe** — `skuInfo.vue` renders explicit named fields |
| `GET .../itemdataDetailsByNumber/{n}` | 0 UI consumers | same | **🟢 no impact** |
| `SecurityConfiguration.java:136` | `/v3/**` → `hasAnyAuthority("wms_user")` | **unchanged** | the new read lands under the existing rule; the write is 2732's endpoint |
| `@PreAuthorize(Authority.IS_SB_ADMIN)` at 9 existing sites | 500 for everyone | **unchanged by 2643** | SBDEV-2863 owns them. A0 changes only 2643's/2732's own sites |
| `receivingForm.vue` display | constants declared inline at `:221-222` | imported from `putawayWording.js` | **🟢 no behaviour change.** Same values, same comparisons, same tri-state. `receivingForm.spec.js` is the guard |
| `skuData.vue` details label | `"Putaway Location"` | `"Default Putaway Location"` | **🟢 cosmetic**, and it is the ticket's own wording |
| `skuData.vue` actions column | one eye button | eye + pencil | **🟢 additive.** The column already exists |
| SKU CSV export | `downloadSkuData` (`skuData.vue:320`) destructures an explicit field list | **unchanged** | **🟢** the new id never reaches a CSV |
| `itemdata` Caffeine cache | 2-key eviction on the dead writer; `allEntries=true` on the live one | **unchanged by 2643** | 2643 adds no cache and no write path of its own — §7.3 row 4 |
| Flyway | head `V2.2.10` | **head `V2.2.10`** | **🟢 2643 ships zero migrations** |

### 6.1 The one real hazard — `fullDetails.vue`'s stray row

`fullDetails.vue:10-11` iterates **every** key in `details` and renders any key not in `excludeFields`;
`:13-14` falls back to `name.charAt(0).toUpperCase() + name.slice(1)` when `fieldNames` has no entry.
`skuData.vue:130` excludes only `['id', 'itemNr', 'version']`.

**So A1 alone makes every SKU details overlay render a new row labelled `PutawayLocationId` showing a
raw integer.** Not a functional break — user-visible on DEV within minutes, because DEV auto-deploys on
push.

**Mandatory mitigation, and it is a GATE not a preference:** `'putawayLocationId'` goes into
`skuData.vue:130`'s `exclude-fields` — shipped **first**, as the standalone one-line `B1-pre` PR.
**Adding the exclusion before A1 merges is a provable no-op** (you are excluding a key the payload does
not yet carry), so it costs nothing and closes the window entirely. **A1 does not merge until `B1-pre`
is deployed** (§5.1 row 4, §8 rollout step 2). Verify row `B1-exclude`; risk R4 (§11.0).

### 6.2 Complete consumer inventory of the widened payload

**`GET /v3/itemData/itemdataDetailsById/{id}` — 3 consumers:**

| Consumer | Renders via | Verdict |
|---|---|---|
| `store/masterData/skuData.js:90` → `skuData.vue:304` → `<full-details>` `:126-152` | generic key iteration | **🟡 stray id row unless excluded at `:130`** |
| `components/internalOps/cycleCount/planned/create/createCycleCountSkuTable.vue:166` | feeds `SkuInfo` | **🟢 safe** — confirm the sink during B1's audit |
| `components/receiving/open/create/createPurchaseOrderSkuTable.vue:290` | feeds `SkuInfo` (imported `:173`) | **🟢 safe** |

**`GET /v3/itemData/itemdataDetailsByNumberAndClientNumber/{n}/{cn}` — 12 consumers, all feeding
`components/common/skuInfo.vue`, all 🟢 SAFE:**

`components/receiving/open/openNoticeTable.vue:271, :279` (imports SkuInfo `:158`) ·
`components/outbound/transfer/transferDetailsTable.vue:132` (`:43`) ·
`components/processes/clubRuns/tabTables/availableInventory.vue:174` (`:68`) ·
`components/processes/transferPicking/tabTables/availableInventory.vue:175` (`:68`) ·
`components/processes/transferPicking/tabTables/inventoryOnLane.vue:188` (`:75`) ·
`components/outbound/club/batchContentTable.vue:151` (`:59`) ·
`components/outbound/pickPack/parcelDetailsTable.vue:130` (`:43`) ·
`components/processes/clubRuns/tabTables/inventoryOnLaneTable.vue:185` (`:75`) ·
`components/processes/clubRuns/itemsTable.vue:191` (`:43`) ·
`components/outbound/club/orderDetails/orderDetailsTable.vue:127` (`:48`)

**Why all 12 are safe:** `skuInfo.vue:102-105` renders **explicit** named fields —
`<v-list-item-content>Putaway Location</…><v-list-item-content>{{ reportDetail.putawayLocation }}</…>`.
No key iteration, no `excludeFields`. An added key is simply ignored.
(`pages/receiving/openNotice/receive.vue:27` imports a **different** component,
`receiving/open/receive/skuInfo.vue` — also field-explicit.)

**`GET /v3/itemData/itemdataDetailsByNumber/{n}` — zero UI consumers.**

**Java-side consumers of the map:** `ItemDataController.java:176, 183, 191` only. Tests asserting on its
keys: `ItemdataServiceUnitTest.java:415-428, 448-472, 475-498, 585-604`.
`BoxtypeServiceUnitTest.java:188, 222` asserts a **different** map (`BoxtypeService.java:87`) — do not
touch it.

### 6.3 What Does NOT Change

- **`ReceivingService` — nothing.** No routing behaviour changes. The ticket's own "Receiving Behavior
  Boundary" defers it and 2732 §3.7 owns it. A SKU configured through 2643 behaves at receive time
  exactly as one configured by a DBA today.
- **`itemdata.putawaylocation_id`'s nullability, the `@NotNull` at `Itemdata.java:49`, and the DB
  schema.** 2643 ships no DDL. `ddl-auto=none` per-request `42703` risk is **nil** — a genuine
  advantage over 2732's row 8.
- **The legacy `GET /v3/itemData/setPutAwayLocation/{i}/{l}`** — left in place, verb unchanged (2732
  §10.4 Q5: the web UI calls it and changing the verb is breaking). 2643 simply **never calls it**.
- **`ViewDtoService.getLocationView()` and `GET /v3/location/detailView`** — not widened (D3). Four
  other screens keep their payload byte-for-byte.
- **`fullDetails.vue`** — the `#actions` slot already exists at `:26`.
- **`plugins/persistedState.client.js`** — no exclusion added (§3.8.5).
- **`SecurityConfiguration.java`** — not widened, not narrowed.
- **`CacheConfig`, `MethodSecurityConfig`, `CustomMethodSecurityExpressionRoot`** — untouched. A0 fixes
  the *call sites*, not the shared wiring.
- **The 9 endpoints F1 breaks** — SBDEV-2863's, still broken after 2643 ships.
- **`store/masterData/storageLocation.js`** — untouched; the picker reads the new endpoint.
- **The SKU data table** — no new column, no `headers` change, no `getItemDataViewPage` change (Q4).
- **`wms2-mobile-ui`** — entirely out of scope.

---

## 7. Testing Strategy

### 7.1 Unit lane — Java (`v2/wms2-api`)

**Harness constraints, non-negotiable:**

- **The base class is `BaseControllerUnitTest`** (`common/base/BaseControllerUnitTest.java:34`), **not**
  `BaseControllerTest` — which does not exist (C6; 2732 §7.7 row 7 carries the same wrong name).
  `setupMockMvc(controller)` at `:52-58` builds `MockMvcBuilders.standaloneSetup(...)` with a
  `PageableHandlerMethodArgumentResolver`, a `MockPrincipalArgumentResolver`, a
  `MappingJackson2HttpMessageConverter` over a `JavaTimeModule`-registered `ObjectMapper` with
  `FAIL_ON_UNKNOWN_PROPERTIES=false`, and `.alwaysDo(print())`.
- **⚠ `standaloneSetup` installs no security filter chain and no method-security advisor, so
  `@PreAuthorize` is NEVER evaluated in this lane** (F2). This lane proves shape and delegation, never
  authorization.
- **The `@SpringBootTest` / Testcontainers lane is DOWN** (SBDEV-2217). Gate on `mvn test` +
  `mvn clean compile`. Any new IT is `@Disabled` with `TODO(SBDEV-2217)`.
- `mvn test` **MUTATES** tracked `src/test/resources/archunit_store/{stored.rules,
  5fb3fee0-6caf-4f48-a5cd-5271da610572}` (F4) — `git checkout` them before every commit.
- `mvn` / `java` need the SDKMAN PATH export.
- **`-Dtest='Outer#method'` silently no-ops for `@Nested` tests** (false green) — always name the nested
  class.
- **Baseline the 2 pre-existing failures on clean `develop`** as of 2026-07-28
  (`OptionalSafetyArchTest` ArchUnit drift, `MobilePalletizingServiceTest`). Do not chase them; record
  the baseline count before the first change.

| Test class | Method | Asserts | Phase |
|---|---|---|---|
| `CustomMethodSecurityExpressionRootUnitTest` (new `@Nested SpelResolution`) | `authoritySpelConstantsResolve` | the SpEL string 2643's handlers carry **parses and evaluates** against a real `CustomMethodSecurityExpressionRoot` without `SpelEvaluationException` | A0 |
| `CustomMethodSecurityExpressionRootUnitTest` | `sbAdminExpressionUsesBareAuthorityName` | `Authority.getExpForRole(Authority.SB_ADMIN_ROLE)` == `"hasAuthority('sb_admin')"` — no `ROLE_` prefix, consistent with `setDefaultRolePrefix(null)` | A0 |
| `ItemdataServiceUnitTest` | `shouldIncludePutawayLocationWhenPresent` (mod `:415-428`) | `containsEntry("putawayLocationId", 7L)` **and** `containsEntry("putawayLocation", "LOC-001")` | A1 |
| `ItemdataServiceUnitTest` | `shouldHandleItemWithAllOptionalFields` (mod `:468-471`) | key list gains `"putawayLocationId"` | A1 |
| `ItemdataServiceUnitTest` | `shouldHandleMissingOptionalReferences` (**rewritten**, `:498`) | dangling FK ⇒ `containsKey("putawayLocationId")` **and** `doesNotContainKey("putawayLocation")` — the AC8 signal | A1 |
| `ItemdataServiceUnitTest` | null-id case (mod `:585-604`) | `doesNotContainKey("putawayLocation")` **and** `doesNotContainKey("putawayLocationId")` | A1 |
| `ItemdataServiceUnitTest` | `getItemdataDetailsAddsNoQueries` | `verify(locationRepository, times(1)).findById(any())` and **zero** additional repository interactions vs. the pre-change baseline | A1 |
| `SkuPutawayQueryServiceUnitTest` (**new file, 2643-owned**) | `describeForSkuDelegatesToResolver` | the resolver is called once with the SKU's id; the returned `Resolution` is passed through unmodified | A2 |
| `SkuPutawayQueryServiceUnitTest` | `describeForSkuIsReadOnlyTenantTransaction` | reflective assertion that the method's `@Transactional` carries `value="tenantTransactionManager"` **and** `readOnly=true` | A2 |
| `ItemDataControllerUnitTest` (**new `@Nested EffectivePutawayDestination`**, appended at EOF) | `returnsSevenFieldEnvelope` | all 7 keys present: `locationId, locationName, source, sourceLabel, configuredFor, compatible, warning` | A2 |
| ″ | `sourceIsEnumNameNotLabel` | `source` == `"SKU_OVERRIDE"`, `sourceLabel` == `"SKU override"` — **the UI must never re-derive tiers** | A2 |
| ″ | `incompatibleConfigCarriesWarning` | `compatible=false` ⇒ `warning` is non-blank (AC8) | A2 |
| ″ | `delegatesToFacadeNotResolver` | the facade mock is invoked; **no resolver collaborator is even constructed** | A2 |
| `SkuPutawayQueryServiceUnitTest` | `describeForSkuOpensNoNewTransaction` | no `Propagation.REQUIRES_NEW` and no second `@Transactional` layer — the resolver must **join**, per 2732 §3.1.5's `MANDATORY` | A2 |
| `ItemDataControllerUnitTest` ″ | `neverCarriesBrokenAuthorityConstant` | the new handler and `SkuPutawayQueryService` carry no `Authority.IS_SB_ADMIN` (§5.1 row 0e; the read is deliberately not admin-gated at all) | A2 |
| `PutawayConfigControllerUnitTest` **(A3 fallback only)** | `eligibleLocationsSkuScopeTwoClasses` | eligible (passes **all** predicates incl. P2.7(c)) vs. not-offered are correctly partitioned. ⚠ **r2: no third "advisory" class and no `PICK_FACE` reason** | A3 |
| ″ | `eligibleLocationsExcludesTierFourLane` | no row whose `locationName` equals `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE` (Q3) | A3 |
| ″ | ~~`eligibleLocationsNeverRelaxesFixAssigned`~~ → **`eligibleLocationsExcludesFlowbinAssignedToAnotherSku`** | ⚠ **REWRITTEN 2026-08-09 — the old form asserts the superseded r2 design and would fail a correct implementation.** P2.5's absolute reject is **dropped** (2732 Q12 → iv-b), so "a fix-assigned location is never offered" is false: a SKU pointed at **its own** pick face is the intent. What must be excluded is a flowbin fix-assigned to a **different** SKU — 2732's new **P2.7 rule (f)**. **Two tests needed**, or an implementation that excludes all fix-assigned locations passes: pair this with `eligibleLocationsOffersTheSkusOwnFixAssignedPickFace` | A3 |
| ″ | ~~`eligibleLocationsNeverOffersPickFace`~~ → **`eligibleLocationsOffersPickFaces`** | ⚠ **INVERTED 2026-08-09 — this is the single most dangerous stale row in the plan.** As written it asserts *"a `useforpicking`-area location is **not offered**, ever"*, which is **exactly what r3 reversed**. It cites P2.7(c) as *"absolute"* — P2.7(c) is **DROPPED at all three scopes** — and mirrors 2732's `skuWriteRejectsPickFaceDestination`, a test 2732 **deleted** on 2026-08-08 (the cited line `:2211` no longer resolves). **A TDD gate run against the old row would permanently enforce the design r3 abandoned.** The correct assertion: a `useforpicking` location **IS** offered at SKU scope, including flowbins (tier 1 is exempt from rule (e)) | A3 |

**Mutate-then-check every new assertion.** Per the recorded landmine, a new assertion is worthless until
you have seen it fail: flip the production line, watch red, restore. SBDEV-2736 scored 57 pass / 0 fail
on the very build carrying the defect its ticket was written to catch.

### 7.2 Unit lane — Jest (`v2/wms2-web-ui`)

**How to run** (no `yarn` on PATH; `jest.config.js` has **no `roots` key**):

```bash
export PATH="$HOME/.nvm/versions/node/v24.15.0/bin:$PATH"
cd /home/nampark/dev/wms-claude/v2/wms2-web-ui
node_modules/.bin/jest test/components/masterData/material/skuData/skuData.spec.js --coverage=false
```

**Copy the idiom from `test/components/receiving/open/receive/receivingForm.spec.js`** — same feature
area, written by 2731's TDD gate: `shallowMount`, import the SUT by `@/` alias, a `mount*` helper
hand-building `$axios` as `{ $get: jest.fn(url => …), $put: jest.fn() }` branching on
`url.includes(...)`, and `$store` as a **plain object literal** with a nested `state` tree — no Vuex, no
localVue. Match its header comment too: it explains *why* each test cannot pass against the pre-fix
component, driving the whole chain (axios payload → watcher → computed → rendered text) rather than
poking a computed directly.

| Spec | Test | Asserts | Phase |
|---|---|---|---|
| `test/components/masterData/material/skuData/skuData.spec.js` | `excludesRawPutawayLocationId` | with `putawayLocationId` in the details payload, **no** row labelled `PutawayLocationId` renders | B1 |
| ″ | `detailsLabelIsDefaultPutawayLocation` | the overlay renders `"Default Putaway Location"`, not `"Putaway Location"` | B1 |
| ″ | `editAffordanceEnabledForAdmin` | `affiliatedGroups` containing `$config.appAdminGroup` ⇒ pencil **enabled** | B1 |
| ″ | `editAffordanceDisabledNotHiddenForReadOnly` | non-admin ⇒ pencil **present and `disabled`**. ⚠ **REQUIRED ASSERTION FORM** (r2, so the verify row can see it and so the test is not satisfied by the word "disabled" appearing anywhere in a Vuetify spec): the spec must (a) name the computed **`isPutawayConfigAdmin`**, (b) prove presence with **`.exists()`**, and (c) read the attribute with **`.attributes('disabled')`** or **`.props('disabled')`** — never a snapshot or a text match. Verify row `B1-jest2` | B1 |
| ″ | `commentedActionsBlockIsGone` | the rendered tree has no trash icon and no `mdi-dots-vertical` menu | B1 |
| `test/components/…/editSkuPutawayDialog.spec.js` | `clearOmitsLocationIdEntirely` | Clear dispatches with `locationId: null`, and the resulting URL has **no** `?locationId=` at all | B2 |
| ″ | `scopeBannerNamesBlockingTicket` | the banner renders **unconditionally** (not behind a selection) and its text contains **`SBDEV-2821`** and **`SBDEV-2732`**/`Q9` — §3.8.2a. ⚠ **r2 replaces r1's `advisoryBannerNamesTicket`**, which asserted a per-row advisory state that no longer exists | B2 |
| ″ | `pickerNeverOffersPickFaces` | given an `eligibleLocations` payload containing a not-offered pick-face row, the picker's `:items` **excludes** it — the client does not resurrect what the server filtered | B2 |
| ″ | `emptyStateExplainsWhy` | a client filter yielding zero rows renders the same three facts as the banner, not a bare "No data available" | B2 |
| ″ | `incompatibleEffectiveRendersWarning` | `compatible: false` ⇒ the envelope's `warning` text renders verbatim | B2 |
| ″ | `defaultRenderedWithLabelNotMachineName` | an inherited `STANDARD_PUTAWAY_LANE` renders `"Put Away Lane"`, never `"PutAwayLane"` | B2 |
| ″ | `validationToastOnEmptySelection` | Submit with nothing selected fires `$toast.error` and dispatches nothing | B2 |
| ″ | `submitDisabledForReadOnly` | non-admin ⇒ Submit `disabled` | B2 |
| `test/store/masterData/skuData.spec.js` | `writeTargetsPutawayConfigEndpoint` | `$put` called with `/putawayConfig/sku/{id}`; **`$get`/`$put` never see `/itemData/setPutAwayLocation`**. ⚠ **REQUIRED ASSERTION FORM** (r2): the negative half must be written **`.not.` FIRST** — e.g. `expect($put).not.toHaveBeenCalledWith(expect.stringContaining('setPutAwayLocation'))` or `expect(urls.join(' ')).not.toContain('setPutAwayLocation')`. r1's verify row was a bare substring grep for `setPutAwayLocation` and would have **passed on a spec asserting the opposite**, or on the string in a comment. Verify row `B2-jest4` | B2 |
| ″ | `surfacesValidationBodyOn422` | a rejected `$put` with `response.data.errors[0].message` ⇒ that message reaches `$toast.error`, not the generic network string | B2 |
| ″ | `refetchesDetailNotTable` | after a successful write, `getSkuDetail` is dispatched and **`searchSkuData` is not** | B2 |

**Re-run `receivingForm.spec.js` in B1** — B1 moves the constants that spec's assertions depend on.

### 7.3 v2-only constraint checklist (8 rows)

Verdicts are about code not yet written; **the verify script and the post-implementation gate hold the
real PASS/FAIL**, matching 2732 §7.7's verdict semantics.

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | **OSIV disabled** ⇒ load entities inside the transaction, or return ids/DTOs | **BY DESIGN — re-verify post-implementation** | `application.properties:55` `spring.jpa.open-in-view=false`. 2643's only new read is `describeForSku`, which runs entirely inside the `readOnly=true` facade and returns a fully-loaded `Resolution`. `getItemdataDetails` already dereferences via explicit `findById` (`ItemdataService.java:167`); every FK on `Itemdata` (`:39-51`) is a manual `Long` with no lazy association. **No new risk** |
| 2 | **`tenantTransactionManager` named explicitly** — a bare `@Transactional` silently binds the `@Primary` landlord TM | **BY DESIGN — re-verify post-implementation** | `describeForSku` carries `@Transactional(value="tenantTransactionManager", readOnly = true)` verbatim from 2732 §3.1.5's two siblings. `unit/config/TransactionManagerArchTest.java` enforces it repo-wide; verify row `A2-tx` asserts the literal string. **⚠ `ItemdataService` is a bare `@Service` (`:15`) with NO `@Transactional` anywhere (F5) — do not add the resolver call there** |
| 3 | **`readOnly = true`** on the read facade; the resolver must not be `readOnly` and must not open `REQUIRES_NEW` | **BY DESIGN — re-verify post-implementation** | `describeForSku` is a pure read. Safe **only** because 2732 §3.4a reads tier 3 via `SyspropRepository` and never `SyspropService.getStringDefault` (which INSERTs at `SyspropService.java:234`). 2643 adds no `REQUIRES_NEW` and no resolver of its own. If 2732's `neverCallsGetStringDefault` guard is ever deleted this becomes a write-in-readOnly bug |
| 4 | **Caffeine/Redis eviction covers every write path, in both profiles** | **BY DESIGN — re-verify post-implementation** | 2643 introduces **no cache and no write path of its own** — it delegates to `PutawayConfigService.setSkuDestination`, which carries 2732's 2-key `itemdata` eviction copied verbatim from `ItemdataService.java:62-67`. `CacheConfig` untouched ⇒ the two-profile-sync trap is avoided entirely. ⚠ **2643 must NOT call `GET /v3/itemData/setPutAwayLocation/...`**, whose `@CacheEvict(allEntries=true)` at `ItemDataController.java:80` flushes every tenant — verify row `B2-neg-leg`. `describeForSku` is uncached |
| 5 | **Micrometer** | **BY DESIGN — re-verify post-implementation** | 2643 adds no metric; it inherits 2732's `PutawayResolutionMetrics` via the shared writer and resolver. ⚠ 2732 §8.1 (`:2293`) makes non-zero **tier-2/3** counters a condition for closing 2643 — wrong signal for a SKU-tier ticket. `resolution{source="SKU_OVERRIDE"} > 0` is 2643's own correct detector (§5.1 row 8; raise at review) |
| 6 | **Jakarta namespace only (`jakarta.*`)** | **BY DESIGN — re-verify post-implementation** | Nothing is ported from v1 — SBDEV-2642 shipped zero commits (2732 §10.5). Existing files comply: `Location.java:3` `import jakarta.persistence.*`, `:5` `jakarta.validation.constraints.NotNull`; `ItemDataControllerUnitTest.java:28` `jakarta.servlet.ServletException`. 2643 adds no entity, so no new persistence imports |
| 7 | **H2-compatible test SQL** | **BY DESIGN — re-verify post-implementation** | 2643 adds **no migration**. Its only candidate query is D-D's eligibility read: **JPQL with plain joins and booleans**, no `nullif(...)::bigint` (the Postgres-only construct 2732 §7.7 row 6 flags in `readCommittedDestination`). Prefer JPQL over native to sidestep the class entirely |
| 8 | **New/changed endpoints need a `BaseControllerUnitTest` subclass** (⚠ **not** `BaseControllerTest` — C6) | **BY DESIGN — re-verify post-implementation** | `GET /v3/itemData/{id}/effectivePutawayDestination` gets a NEW `@Nested` class in `ItemDataControllerUnitTest`, which already extends `BaseControllerUnitTest`. ⚠ **F2: `standaloneSetup` (`:52-58`) evaluates no `@PreAuthorize`** — this lane proves shape and delegation, not authorization. **Entity/DDL drift: 2643 ships no DDL and no entity change**, so the `ddl-auto=none` per-request `42703` risk is nil |

### 7.4 Horizontal-scalability checklist (10 rows)

| # | Concern | Does 2643 change... | Verdict | Evidence / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | introduce state that exists in only one replica? | **No — BY DESIGN, re-verify post-implementation** | No new cache, no `ConcurrentHashMap`, no static, no `ThreadLocal`. `describeForSku` is a pure function of DB state. Vuex state is per-browser, not per-replica. 2643 adds no equivalent of 2732 §7.6 row 1's request-scoped previous-value carrier |
| 2 | **Connection-pool math** | change per-request DB connection usage? | **No — BY DESIGN, re-verify post-implementation** | `effectivePutawayDestination` is one new request holding one connection for ≤4 index-backed resolver queries. `getItemdataDetails` gains **zero** queries — `putawaylocationId` is already on the entity loaded at `:120`; only a `details.put` is added (asserted by `getItemdataDetailsAddsNoQueries`). Call frequency is admin-screen scale — one per dialog open, not per receipt |
| 3 | **Scheduled jobs** | add or modify a `@Scheduled` job? | **N/A** | 2643 adds no job and touches none |
| 4 | **Long transactions** | hold a transaction across more repository calls or external I/O? | **No — BY DESIGN, re-verify post-implementation** | `describeForSku`'s `readOnly=true` transaction spans ≤4 lookups and closes. No HTTP, no printer, no broker, no loop. Config writes are 2732's single-entity transactions. **2643 adds nothing to the receiving path** |
| 5 | **Request affinity** | assume a follow-up request lands on the same replica? | **No — BY DESIGN, re-verify post-implementation** | Every read re-resolves from the DB; every write is a separate stateless `PUT`. The read-after-write (Save → re-dispatch `getSkuDetail`) may land on a **different** replica — safe because the write commits before the response and `describeForSku` is uncached. ⚠ **Caveat:** `ItemdataService.getById` is `@Cacheable` (`:47`) under Caffeine, so a different replica could serve a stale `itemdata` for its TTL — but the read-after-write goes through `getItemdataDetails`, which uses `itemdataRepository.findById` (`:120`), **not** the cached `getById`. **🟢 by accident — verify row `A1-repo` pins it** so a future "optimisation" cannot silently break it |
| 6 | **Retry / idempotency** | rely on single-execution semantics? | **No — BY DESIGN, re-verify post-implementation** | The write is idempotent last-writer-wins on one column, protected by `Itemdata`'s `@Version`. A double-submit yields a duplicate `putaway_config_audit` row — harmless, and the correct record of two requests (2732 §7.6 row 6). `PUT /putawayConfig/**` is **outside** `IdempotencyFilter`, which guards `/rest/**` only (`IdempotencyFilter.java:271`) — unchanged, not made worse |
| 7 | **Tenant context** | use `TenantContext` across an async boundary? | **No — BY DESIGN, re-verify post-implementation** | Everything on the request thread. No `@Async`, no `CompletableFuture`. The `@Cacheable`/`@CacheEvict` SpEL reads `TenantContext.getCurrentTenant()?.getFacilityCode()` synchronously (`ItemdataService.java:47, 63-66`) |
| 8 | **Distributed-lock correctness** | add or rely on cross-replica locking? | **No lock added — but 2643 IS the surface that arms 2732's accepted risk** | `describeForSku` is `readOnly`; the config write is a single-row `UPDATE itemdata`. 2732 §7.6 row 8's accepted risk is a **lock-order inversion at receive time** (`transferUnitLoadToLocation` takes `findByIdForUpdate` on the destination Location at `:150`, before UL/SU at `:293-294`, inverting SBDEV-2232's canonical SU→UL→Location order, with no deadlock-retry infra). Receiving is out of 2643's scope — **but 2643 is how an operator arms it:** a SKU pointed at a live storage location makes receipts hold `FOR UPDATE` on that row for a whole multi-case receipt. **Therefore 2643 MUST carry 2732 §3.11.2's advanced-tier toggle + lock-contention warning verbatim** (2732 `:1607` requires exactly this for the SKU picker) and must **not** default the picker to storage locations. Measured: 92 SKU-eligible locations on hydra DEV, of which the `useforstorage` subset is the armed set. ⚠ **r2: the armed set is exactly 2732's own, not one byte wider.** r1's D1 widened it to include pick faces and answered 2732 `:2308`(i)'s *hard* prerequisite with a UI banner — a UI banner is not deadlock-retry infrastructure, and 2732 **Q9** (`:2561`) answers *"No"* to precisely that widening, naming the same physical reason (*"picking locks the same rows in the opposite order far more often than replenishment does"*). **r2 enforces P2.7(c), so no new prerequisite is inherited** (§5.1 row 9). The storage-tier toggle + lock warning remain **mandatory** — that hazard is 2732's, is real, and is reachable today |
| 9 | **Cache invalidation** | write to a cached entity? | **Yes, indirectly — BY DESIGN, re-verify post-implementation** | The write targets `Itemdata`, cached under `itemdata` (2 keys, `ItemdataService.java:47, 62-67`). Eviction is 2732's, copied verbatim. Under **Redis** it propagates cross-replica; under **Caffeine** it does not, so another replica can show a stale value for up to the TTL. **Accepted** on 2732's reasoning: the receiving path reads tiers uncached (no receipt is misrouted) and the exposure is admin display only. **2643-specific improvement:** `getItemdataDetails` reads via `findById` (`:120`), bypassing the cache, so **2643's own display is always fresh even under Caffeine.** Asserted — see row 5 |
| 10 | **External notifications** | send HTTP/message to an external system inside a transaction? | **No — BY DESIGN, re-verify post-implementation** | No OMS notification, no outbox row, no printer, no Keycloak call on any 2643 path. ⚠ `ItemDataController` **does** hold `HttpRestService` and a `sendStockUpdate` endpoint (`:97-98`) that notifies OMS — **2643 must not touch it**, and a putaway-config change must **not** trigger an inventory export. Verify row `A2-neg-oms` asserts `httpRestService` appears nowhere in the new handler |

### 7.5 Manual Test Plan (MANDATORY)

**⚠ Subject-data problem, and it is real.** The ticket names *"Example Warehouse: HMG, Example SKU: Ice
Pack system SKU"*. On hydra DEV (= HMG/nywh) there is **no Ice Pack SKU** — the nearest are
`ICEDCARAFE` (id 18118465) and `ICEBAGCHILLER` (id 18118466), both Le Grand Courtage (`22LEG536`), and
**all 2,720 SKUs point at `PutAwayLane`**. The reported invalid Ice Pack configuration is a **PRD-only**
state (SBDEV-2731 proved it there: SKU id 52072, location id 52075). **A manual plan that says "open the
Ice Pack SKU on HMG dev" will not work.** Until **Q10** is answered, designate **`ICEBAGCHILLER`
(18118466)** as the DEV stand-in and say so in the test record.

| # | Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| **M1** | Details overlay shows no stray id row | DEV (post-A1+B1) | 1. Master Data → SKU 2. eye icon on `ICEBAGCHILLER` | overlay renders **"Default Putaway Location: PutAwayLane"**; **no** `PutawayLocationId` row anywhere | |
| **M2** | A1 without `B1-pre` — **observe the hazard, do NOT deploy it** | **local `yarn dev` or a branch preview — NOT DEV** | run the UI locally against a build carrying A1 but **without** `'putawayLocationId'` in `exclude-fields`; open the overlay | a `PutawayLocationId` raw-integer row **DOES** appear. **This is the hazard §6.1 predicts** — confirm it, then confirm the `exclude-fields` line removes it. Do not skip: it proves the mitigation is load-bearing. ⚠ **r2: this is an OBSERVATION, not a deployment.** r1 read as "deploy A1 only to DEV" — but §5.1 row 4 now makes `B1-pre` a hard prerequisite of A1, and DEV auto-deploys on push, so shipping the ordering the row forbids in order to watch it fail is not a test, it is the defect | |
| **M3** | Effective value when nothing is configured | DEV (post-A2, post-`V2.2.11`) | pick a SKU whose `putawaylocation_id` is NULL; open the dialog | shows *"Inherits: Standard putaway lane — Put Away Lane"*. **Never the machine name `PutAwayLane`** | |
| **M4** | Set a valid destination end-to-end | DEV (post-B2) | dialog → pick an **eligible** location → Submit | success toast; overlay re-reads and shows the new name; `SELECT putawaylocation_id FROM itemdata WHERE id=…` matches; a `putaway_config_audit` row exists with SKU + previous + new + user + timestamp (AC9) | |
| **M5** | Clear back to default | DEV (post-B2, post-`V2.2.11`) | dialog → **Clear / Use default** → confirm | request URL has **no** `?locationId=` at all; DB value becomes **NULL**; overlay flips to *"Inherits: …"*; an audit row records the clear (AC4) | |
| **M6** | 422 reaches the operator (**the CORS landmine**) | DEV (post-B2) | pick a **blocked** location (fix-assigned or locked) → Submit. Watch the browser Network tab | the toast shows the **specific validation message**. ⚠ If it shows the generic *"network or server issue"* AND the response has no `Access-Control-Allow-Origin`, 2732's handler used `response.reset()` — file against 2732; `resetBuffer()` is the fix. **No unit test can catch this** (MockMvc installs no `CorsFilter`) | |
| **M7** | Permission gate — read-only user | DEV (post-B1) | log in as a user **not** in `APP_ADMIN_GROUP`; open the SKU screen and the overlay | the configured value **is visible**; the pencil and Submit are **present and disabled with a tooltip** — not hidden (AC1 for read-only users + AC12's UI half) | |
| **M8** | Permission enforcement — the backend boundary (**AC12, not automatable**) | DEV (post-2732 Phase 1-API) | as a non-`sb_admin`, `curl -X PUT '/v3/putawayConfig/sku/18118466?locationId=…'` | **403**, not 500 and not 200. ⚠ **A 500 means F1 is still live** — i.e. 2732 merged with `Authority.IS_SB_ADMIN` and **§5.1 row 0e was not honoured.** That is 2732's / SBDEV-2863's fix, **not 2643's** (§3.1 r2 box). `standaloneSetup` (`BaseControllerUnitTest:52-58`) cannot assert this and the IT lane is down (SBDEV-2217), so **this row IS the AC12 evidence** | |
| **M9** | The resolver is not called from the controller | DEV (post-A2) | `curl '/v3/itemData/18118466/effectivePutawayDestination'` | **200** with the 7-field envelope. **A 500 with `IllegalTransactionStateException` means the controller calls the resolver directly** (§3.2/§3.6). No mocked test can prove this | |
| **M10** | ⚠ **REWRITTEN 2026-08-09 — r3.** **D1 — pick faces ARE offered, the write SUCCEEDS, and a foreign-bound flowbin is excluded** | DEV (post-B2) | **(a)** open the dialog and search for a known flowbin by name and for `ICE`; **(b)** read the always-visible scope banner and the advisory; **(c)** save `ICE PACK` to its own pick face through the UI; **(d)** then try a flowbin whose `FixLocationAssignment` belongs to a *different* SKU (1,344 of 2,068 on wineco dev qualify) | **(a)** the picker **DOES** return flowbin rows, `ICE PACK` among them; **(b)** the banner shows the computed `{eligibleCount}`/`{totalCount}` (never hard-coded — r3 F-1) and the advisory says the destination is **routed via putaway, not placed directly**, and that the stock arrives when someone puts it away rather than when the receipt closes; **(c)** the write **SUCCEEDS** — a SKU-scope pick-face write is legal under Q12 → (iv-b); **(d)** the foreign-bound flowbin is **not offered** (2732 rule (f)). ⚠ **r2's version of this row asserted the exact opposite on every point — picker returns no flowbins, API returns 422 — and cited `skuWriteRejectsPickFaceDestination`, a test 2732 DELETED on 2026-08-08. It could never pass against a correct implementation.** Record (c)'s response body — it is also M6's CORS evidence |
| **M11** | Persistence after refresh (**AC5**) | DEV (post-B2) | set a value → hard-refresh (F5) → reopen the overlay | the new value shows. `masterData.skuData` rehydrates from `localStorage['vuex-web']` but `skuData.vue:304` always refetches (§3.8.5) | |
| **M12** | Receiving display is unregressed | DEV (post-B1) | open Receiving → an open notice → the receive form | "Inbound Putaway Staging" renders exactly as before B1. **B1 moves `receivingForm.vue`'s constants — this row proves 2731 was not regressed** | |
| **M13** | SQL-level sanity | DEV DB | `SELECT id, putawaylocation_id FROM itemdata WHERE id=18118466;` then `SELECT * FROM putaway_config_audit WHERE itemdata_id=18118466 ORDER BY id DESC LIMIT 5;` | value matches the UI; audit rows carry all six required fields (SKU, facility, previous, new, user, timestamp) | |

### 7.6 e2e lane

No Cypress/Playwright suite is wired for this area (`cypress/` exists but is excluded from Jest and
carries no SKU spec). **e2e coverage is the manual plan above**, specifically the M4 → M5 → M11 chain
(set → clear → survive refresh) and M10 (D1's boundary, proven from both sides — the picker's omission
and the API's 422). Recorded as a deliberate gap, not an omission.

### 7.7 Observability lane

| Signal | Source | What it proves |
|---|---|---|
| `wms2.putaway.resolution{source="SKU_OVERRIDE"}` **> 0** | 2732's `PutawayResolutionMetrics`, inherited | **2643's own adoption gate.** Zero = the feature shipped inert (pre-mortem PM2) |
| `wms2.putaway.config.changed{scope="SKU"}` | same | writes are landing through the validated writer, not the legacy GET |
| `wms2.putaway.resolution.rejected` | same | a configured destination is failing P1 at receive time. ⚠ **r2: this is no longer D1's residual risk** (there is none — pick faces cannot be configured). Non-zero now means either a **pre-existing** DB-written configuration is invalid (2731's PRD case, exactly what filed that ticket) or a write-time predicate and a receive-time check disagree — **a 2732 bug, worth escalating rather than accepting** |
| HTTP 500 rate on `/v3/itemData/*/effectivePutawayDestination` | logs | a non-zero rate is the `IllegalTransactionStateException` signature (M9's failure mode) |
| `SpelEvaluationException` / `EL1004E` in logs | logs | F1 is live. Should go to zero for 2643's paths after A0 |
| `40P01` / `DeadlockLoserDataAccessException` on `/receiving/receive` | logs | §7.4 row 8's lock-order inversion, armed by a storage-location or pick-face config. **Must be log-based** — `/receiving/receive` returns 200-with-`errors`, never 5xx, so an HTTP-status alert misses it entirely |

### 7.8 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---|---|---|
| `mvn test` (baseline, before any change) | | expect the 2 known `develop` failures |
| `mvn test -Dtest=CustomMethodSecurityExpressionRootUnitTest` | | |
| `mvn test -Dtest=ItemdataServiceUnitTest` | | |
| `mvn test -Dtest=ItemDataControllerUnitTest` | | |
| `mvn test -Dtest=SkuPutawayQueryServiceUnitTest` | | |
| `mvn test -Dtest=PutawayConfigControllerUnitTest` | | |
| `mvn clean compile` | | must pass — catches the 12-arg constructor drift |
| `node_modules/.bin/jest test/components/masterData/material/skuData --coverage=false` | | |
| `node_modules/.bin/jest test/store/masterData/skuData.spec.js --coverage=false` | | |
| `node_modules/.bin/jest test/components/receiving/open/receive/receivingForm.spec.js --coverage=false` | | regression guard for B1 |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh` | | 0 FAIL; SKIP count must match the phases not yet reached |

### 7.9 Deliberately-skipped coverage

| What | Why |
|---|---|
| Any Testcontainers integration test | v2 IT harness is down (SBDEV-2217). New ITs are `@Disabled` with `TODO(SBDEV-2217)` |
| `@PreAuthorize` enforcement as a controller test | `BaseControllerUnitTest:52-58` uses `standaloneSetup` — no filter chain, no method-security advisor (F2). Proven by A0's SpEL test + manual **M8** |
| The CORS/`reset()` interaction | MockMvc installs no `CorsFilter`, so no unit test can reproduce it. Manual **M6** |
| Resolver propagation semantics | a Mockito mock has no propagation semantics — a mocked test passes against a controller that calls the resolver directly. Code-shape check `A2-neg-res` + manual **M9** |
| `ItemDataController.java:182`'s `.get(0)` `IndexOutOfBoundsException` | pre-existing (F6), zero UI consumers, out of scope. Named so it is not "discovered" mid-implementation |
| The 9 endpoints `Authority.IS_SB_ADMIN` breaks | SBDEV-2863's scope |
| A SKU table column | Q4 answered no column |

---

## 8. Rollout

**2643 ships zero migrations, so there is no operator gate and no per-tenant apply step** — the whole
Flyway hazard class that dominates 2732's rollout simply does not apply here.

| Order | Phase | Repo | Branch | Merge target | Deploy note |
|---|---|---|---|---|---|
| 1 | **A0** (detector, test-only) | `wms2-api` | `fix/SBDEV-2643-A0-sb-admin-spel` | `develop` | independent, un-blocked, zero production bytes. **Ship first.** ⚠ **No constant swap rides with it** (§5.1 row 0e) |
| 2 | **B1-pre** (one line) | `wms2-web-ui` | `feature/SBDEV-2643-B1-exclude-field` | `develop` | `exclude-fields` += `'putawayLocationId'`. **A provable no-op today** — and a **HARD PREREQUISITE of step 3**, not a preference (§5.1 row 4) |
| 3 | **A1** | `wms2-api` | `feature/SBDEV-2643-A1-itemdata-details-putaway-id` | `develop` | DEV auto-deploys on push. **Must not merge until step 2 is deployed** |
| — | *gate* | — | — | — | **wait for SBDEV-2732 Phase 1-API's merge commit to land on `develop`** (§8.1). ⚠ **And confirm §5.1 row 0e was honoured** — if 2732 merged with `Authority.IS_SB_ADMIN`, every 2732 write 500s and AC12 is unmeetable until SBDEV-2863 lands |
| 4 | **A2** | `wms2-api` | `feature/SBDEV-2643-A2-sku-effective-putaway` | `develop` | new 2643-owned `SkuPutawayQueryService` + the read endpoint. **Touches no 2732 file** |
| 5 | **A3** | `wms2-api` | `feature/SBDEV-2643-A3-eligible-locations` | `develop` | ⚠ **FALLBACK ONLY — expected to be SKIPPED.** D-D is 2732's per D12; this step fires only if 2732 declines in writing (§5.1 row 0d) |
| 6 | **B1** | `wms2-web-ui` | `feature/SBDEV-2643-B1-sku-putaway-surface` | `develop` | Edit button `disabled` + tooltip until B2 lands |
| — | *gate* | — | — | — | **wait for SBDEV-2732 Phase 2-UI (`LocationPicker.vue`) on `develop`** |
| 7 | **B2** | `wms2-web-ui` | `feature/SBDEV-2643-B2-sku-putaway-dialog` | `develop` | then M4–M11, then close 2643 |

### 8.1 The stacked-PR ancestry gate — spelled out as commands

**Do NOT open A2 or A3 against 2732's branch.** Both target `develop`. This is the exact failure that
orphaned PR #51: a stacked PR whose base was merged out of order, leaving the stacked commits
unreachable. The rule is **merge base-first INTO `develop`, then verify ancestry before advancing.**

```bash
export PATH="$HOME/.sdkman/candidates/java/current/bin:$HOME/.sdkman/candidates/maven/current/bin:$PATH"
cd /home/nampark/dev/wms-claude/v2/wms2-api
git fetch origin --prune

# 1. Confirm 2732's Phase-1 merge is ACTUALLY on develop — not just that its PR says "merged".
git log origin/develop --oneline --grep='SBDEV-2732' | head
BASE=$(git log origin/develop --format=%H --grep='SBDEV-2732' -1)
test -n "$BASE" || { echo "SBDEV-2732 Phase 1 is NOT on develop — A2 is blocked"; exit 1; }

# 2. Confirm the constructs A2 depends on exist at that commit. "Merged" is not "present".
git show --stat "$BASE" | grep -E 'PutawayDestinationQueryService|PutawayDestinationResolver|V2\.2\.11'
git grep -l 'class PutawayDestinationQueryService' "$BASE" -- src/main/java || \
  { echo "facade absent at BASE — re-read 2732's PR before writing tests"; exit 1; }

# 3. Branch from origin/develop AT OR AFTER that merge — never from 2732's feature branch.
git switch -c feature/SBDEV-2643-A2-sku-effective-putaway origin/develop
git merge-base --is-ancestor "$BASE" HEAD || { echo "ANCESTRY FAIL — 2732's merge is not in this branch"; exit 1; }

# 4. Re-assert immediately before opening the PR, and again before merging it.
git fetch origin && git merge-base --is-ancestor "$BASE" HEAD && echo "ancestry OK"
```

Repeat verbatim for A3 and, with `wms2-web-ui` and 2732's **Phase 2-UI** merge, for B2.

### 8.2 Blast radius

| Phase | Blast radius of a defect | Gate |
|---|---|---|
| A0 (detector) | none — a test-only addition | the test itself |
| ~~A0 (swap)~~ | **removed from 2643's scope in r2.** The blast radius of the *unfixed* constant is 2732's nine 500-ing endpoints, tracked by SBDEV-2863 | §5.1 row 0e + verify `X-2732-authz` + manual **M8** (403 not 500, and not 200) |
| B1-pre | none — a one-line no-op today | `B1-exclude` |
| A1 | a cosmetic stray row on every SKU details overlay **if `B1-pre` was skipped** — which §5.1 row 4 forbids | **M2** locally (confirm the hazard) then **M1** on DEV (confirm the fix) |
| A2 | one new read endpoint; 500 if the resolver is called directly | `A2-neg-res` + **M9** |
| A3 (fallback only) | the picker offers too many or too few locations | the two-class unit tests + **M10(a)** |
| B1 | `receivingForm.vue` regression (2731's just-merged display) | `receivingForm.spec.js` + **M12** |
| B2 | **one SKU per write.** The narrowest tier in the whole feature family. Its **worst** outcome is a legible refusal, not a bad configuration: an ineligible destination cannot be selected *and* cannot be written | write validation (2732) + the receive-time backstop + **M10** proving both sides of the boundary |

### 8.3 Rollback

Every phase is code-only and independently revertible; **no migration means no forward-only
constraint** anywhere in this plan. A1's revert is safe even after B1 deploys (`exclude-fields` naming
an absent key is a no-op). B2's revert leaves the pencil button `disabled` — degraded, not broken.
Any SKU value written through 2643 is undone by 2732's own Clear, or by one `UPDATE itemdata SET
putawaylocation_id = <lane id> WHERE id = …`.

### 8.4 Closure conditions

1. **`bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh`** → 0 FAIL and
   **0 SKIP**. A green run with SKIPs means phases are still blocked, not that the work is done.
2. **M1–M13 recorded**, including **M2** (proves the `B1-pre` mitigation is load-bearing) and **M10**
   (proves D1's boundary from both sides — the picker's omission *and* the API's 422).
3. **`wms2.putaway.resolution{source="SKU_OVERRIDE"} > 0`** on DEV — the adoption gate. ⚠ Do **not**
   accept 2732 §8.1's tier-2/3 condition as 2643's gate (§5.1 row 8).
4. **Q2, Q6, Q10, Q11 answered or explicitly deferred with a named owner**, and **Q5 → D12 confirmed in
   writing** by 2732's author (§5.1 row 0d).
5. **§5.1 row 0e resolved by someone** — 2732 not carrying `Authority.IS_SB_ADMIN`, or SBDEV-2863 merged.
   Until then AC12 is unmeetable and closing 2643 on it would be an over-claim.
6. **§10.3's ten corrections sent to 2732's author**, C4 and C10 in particular.

---

## 9. Alternatives Considered

### 9.1 Offer pick faces behind an advisory warning — **REJECTED in r2 (was r1's D1)**

r1's plan of record: offer the 511 `useforpicking` locations alongside the 92 eligible ones, behind a
per-row banner naming SBDEV-2821, on the reasoning that the ticket is a *configuration* deliverable and
the "Receiving Behavior Boundary" defers what receiving does with the value.

**Pros (as r1 argued them):** the feature can express the configuration the ticket was filed to create;
the ICE PACK location is findable; the config/runtime split is a coherent shape in general.

**Cons — and the first one is fatal, not a tradeoff:**

1. **The write does not succeed. It 422s.** A config/runtime split is legitimate only if the *config*
   write is permitted. 2732 makes a SKU-scope pick-face destination an **unconditional** reject:
   `:722` — P2.7(c) is *"absolute at all three scopes — tier 1 included, and this is load-bearing for
   D15"*; `:792-795` — *"Tier 1 (SKU) is exempt from (a), (b) and (d) — **but NOT from (c)**,
   deliberately… (A 2026-08-04 revision briefly added (c) to this exemption list; reverted the same
   day.)"*; and `:2211` ships the enforcing unit test **`skuWriteRejectsPickFaceDestination`**. So r1
   would have shipped **a picker offering ~511 rows whose selection cannot be saved at all** — two dead
   ends instead of one, the second of which looks like a bug in the new feature.
2. **It does what 2732's own open question declines, for the same physical reason.** 2732 **Q9**
   (`:2561`) asks whether P2.4 should admit pick locations and answers *"**No** — the narrow reading
   ships safely and can be widened later… widening P2.4 is a one-clause change **but §7.6 row 8's
   deadlock-retry prerequisite becomes hard**, because picking locks the same rows in the opposite order
   far more often than replenishment does."* And 2732 `:2308`(i) makes the deferred *"stock-move
   deadlock-retry hardening"* ticket **"an absolute prerequisite before Q9 widens P2.4 to admit pick
   locations."* r1 answered a hard infrastructure prerequisite with a UI banner.
3. **2643 cannot divergence-document its way out of a validator it does not own.** 2732's test fails the
   moment 2643's picker is used. The only coherent version of r1's D1 was a *change request against
   2732 P2.7(c)* — which would then inherit 2732's deadlock-ticket price, making the short-term outcome
   identical to r2's anyway.

**Rejected. r2's D1 enforces P2.7(c) and ships the 92** — see §10.1 D1. The ticket's use case is not
abandoned, it is **sequenced**: 2732 `:722` already assigns tier-1 pick-face relaxation to
**SBDEV-2821**, and §3.8.2a makes the restriction legible in the UI so the operator learns *why* the
location is absent. **Also rejected: building a 2643-owned SKU-scope validator** — it would duplicate
six safety-critical predicates, violating §14's principle 2 and D3's entire rationale (§9.3(a)).

### 9.2 Stack on SBDEV-2821 so configuration and receiving land together — **REJECTED**

Wait for SBDEV-2821 to make pick-face receiving actually work, then ship 2643 against a validator that
genuinely permits the ticket's destination — no divergence, no warning, no residual risk.

**Pros:** the cleanest possible semantics — the picker offers exactly what receiving accepts.

**Cons:** SBDEV-2821 is **Open with no plan document**, and it carries the resident-UL/Fix B machinery
that 2732 D15 deliberately deferred plus 2732's own unresolved Q11 and C2b. Stacking on it makes 2643's
critical path **2731 → 2732 Phase 1 → 2732 Phase 2 → 2821 (unplanned) → 2643** — the longest chain
available, gated on a ticket nobody has scoped. Meanwhile the ticket is `urgent` and the requester is
waiting on a **configuration UI**, which is orthogonal to receiving behaviour: the ticket's own
"Receiving Behavior Boundary" section says so explicitly.

**Rejected.** 2643 ships the configuration surface for the 92 locations that *are* configurable today
and *names* the gap in the UI (§3.8.2a). **When 2821 relaxes P2.7(c) for tier 1, the scope banner is
deleted and 511 rows become eligible with no 2643 code change at all** — the predicate authority is
2732's validator, server-side (D3), so the picker's eligible set widens by itself. That is the payoff for
not duplicating the predicate: r2's design absorbs 2821 for free, where r1's would have needed the
advisory class, the `PICK_FACE` reason and the banner all unwound.

### 9.3 Widen `ViewDtoService.getLocationView()` and filter client-side — **REJECTED (D3)**

Add `staginglane`, `transferlane`, `automationlane`, `crossdockinglane`, `gate`, `typeId`,
`useforgoodsin`, `useforstorage`, `useforpicking`, `entityLock` and a `fixAssigned` marker to
`getLocationView()` (`:806-832`), then implement the predicate set in Vue — literally what 2732 §3.11.2
mandates.

**Pros:** no new endpoint; reuses `store/masterData/storageLocation.js:51`'s existing fetch; the
666-row payload is small enough to filter client-side (§2.2).

**Cons:** (a) it re-implements **six safety-critical predicates in JavaScript**, guaranteeing divergence
from `PutawayDestinationValidator` the first time either side changes — and 2732's own §12 changelog
shows P2.5 flipped and reverted the same day and P2.7(c) arriving on 2026-08-06, so "either side
changes" is not hypothetical; (b) it widens a payload **four other screens** consume, for the benefit of
one dialog; (c) `fixAssigned` is not a column at all — it is an `EXISTS` over
`fix_location_assignment`, so the "just add fields" framing is already false; (d) it puts the eligibility
verdict in the client, where a stale bundle silently offers a location the server rejects.

**Rejected per D3.** D-D ships `GET /v3/putawayConfig/eligibleLocations?scope=SKU` with **server-side**
predicate evaluation delegating to 2732's validator — one source of truth, matching the ticket's own
"ONE shared service" spirit. `getLocationView()` is left byte-for-byte unchanged.

### 9.4 Absorb 2643 into SBDEV-2732 as a "Phase 3-UI" — **REJECTED**

Delete this plan; add the SKU dialog, `describeForSku` and the eligible-locations read to 2732 as a
third phase, and ship one coherent feature.

**Pros:** no stacked-PR hazard (R1), no `ItemDataControllerUnitTest` collision (R2), no unwritten-contract
risk (R5) — 2732 would own both sides of every contract, so nothing could drift.

**Cons:** **2732 explicitly carved this out** — its §0.2 row 45 marks the SKU edit surface *"out of THIS
plan — that is SBDEV-2643's SKU edit form"* and its §10.4 Q3 records that 2643 is materially bigger than
"add a field". 2732 is already **2848 lines** and carries a gated migration, an absolute operator gate,
two open blocking questions of its own (2732's Q12 and Q8) and three pre-mortem scenarios; absorbing 2643 would
add a fourth phase and a second repo's UI work. ⚠ **r2 note:** r1 also argued that D1's divergence
"cannot coherently live inside the plan that declares P2.7(c) absolute" — **that argument is void, because
r2's D1 is not a divergence.** The remaining grounds (2732's explicit carve-out at its §0.2 row 45, its
size, its own open questions) still hold on their own. There is also
a scheduling argument in the other direction: **2643's picker is less blocked than 2732's own.** 2732's
2732's Q12 (may a tier-2/3 default target a club lane?) is entirely about P2.7(a); at SKU scope P2.3 rejects all
lane flags unconditionally, so **2732's Q12 answer cannot change 2643's eligible set.** 2643 can proceed while
2732's hardest open question is still open.

**Rejected.** 2643 stays a separate, thin, stacked plan — with §8.1's ancestry gate as the structural
answer to R1 and a new nested test class as the answer to R2.

### 9.5 Also considered, briefly

| Option | Verdict |
|---|---|
| Fix `Authority.IS_SB_ADMIN` globally (repoint at `"isAimAdmin()"`, or alias `isSbAdmin()` on the root) | **Rejected for 2643.** Both silently change the semantics of 9 unrelated endpoints. SBDEV-2863 owns that call. §3.1 |
| Add a "Default Putaway Location" column to the SKU table | **Rejected (Q4).** Needs a second API change (`getItemDataViewPage:915-924`) and hits F3's persistedState staleness. The overlay + dialog satisfy AC1. Add later if operators ask |
| Build a second, SKU-specific picker instead of reusing `LocationPicker.vue` | **Rejected (Q7).** Two pickers means two implementations of a safety-critical filter. Cost accepted: B2 hard-blocks on 2732 Phase 2-UI |
| Put `describeForSku` on `ItemdataService` beside `getItemdataDetails` | **Rejected (F5).** `ItemdataService.java:15` is a bare `@Service` with no `@Transactional` anywhere; the `MANDATORY` resolver would throw `IllegalTransactionStateException` from there exactly as from a controller |
| Add a count-and-confirm preview flow to the SKU dialog | **Rejected (Q8).** Answered by 2732's own signature: `setSku` carries no `confirmIncompatibleSkus`; only `setMerchant`/`setWarehouse` do. One SKU has no blast radius |
| Offer `PutAwayLane` itself in the picker | **Rejected (Q3/F8).** It passes every predicate, so pinning tier 1 to the tier-4 fallback is possible and produces a silently-inert configuration. **Clear is the only route back** |

---

## 10. Open Questions / Resolved Decisions

### 10.1 Recorded decisions — decided, do not re-open

| # | Decision | Rationale |
|---|---|---|
| **D1** ⭐ **REVERSED IN r2, RE-REVERSED IN r3 — this row is r3's** | ⚠ **REWRITTEN 2026-08-09. The r2 text below the strikethrough is SUPERSEDED; do not implement it.** **The picker OFFERS pick faces, including flowbins**, at SKU scope — tier 1 is exempt from 2732's P2.7 rule (e), and a SKU-scope pick-face write is legal under Q12 → (iv-b). The r2 exclusion would hide **511 savable locations on hydra DEV, `ICE PACK` among them** — the very configuration the parent bug is about. **What the picker must still exclude is a flowbin fix-assigned to a *different* SKU** (2732's new **rule (f)**, added 2026-08-09): those rows save cleanly and then fail at *every* putaway, which is worse than r1's "unsavable rows" because the failure is deferred and detached from its cause. On `wms2-wineco-dev` that is **1,344 of the 2,555** rows the picker would otherwise offer (53%); on `wms2-hydra-dev2`, **154 of 603**. `blockingReason` is **2732's enum** — 2643 still may not extend it from its own PR (MUST-4); 2732 owns that change. The **advisory** returns in r1's shape and must say the destination is *routed via putaway*, not placed directly — and state the operational consequence: **the stock is not on the pick face when the receipt closes; it arrives when someone puts it away.** The always-visible scope banner (§3.8.2a) stays, with r3's computed `{eligibleCount}`/`{totalCount}`. ~~**r2: ENFORCE 2732's P2.7(c). The SKU picker offers ONLY the 92 genuinely-eligible locations; pick faces are NOT selectable.** P2.5 (fix-assigned) also stays absolutely blocked. **2643 adds no `advisory` field, does not extend `blockingReason` with `PICK_FACE`, and builds no SKU-scope validator of its own.** What 2643 *does* build is the **always-visible scope banner** (§3.8.2a) naming **SBDEV-2821** and **SBDEV-2732 Q9**, plus a matching picker empty state~~ | **This is correct SEQUENCING, not a divergence, and not a compromise.** ① **A SKU-scope pick-face write is an unconditional 422** — 2732 `:722` (*"absolute at all three scopes — tier 1 included… load-bearing for 2732's D15"*), `:792-795` (*"tier 1 is exempt from (a), (b) and (d) — **but NOT from (c)**, deliberately"*, with the 2026-08-04 exemption *"reverted the same day"*), and 2732 ships **`skuWriteRejectsPickFaceDestination`** (`:2211`) to enforce it. **Offering rows that cannot be saved is strictly worse than not offering them.** ② **2732 already owns the relaxation and has assigned it:** `:722` — *"**SBDEV-2821** relaxes this for tier 1 only, alongside P2.5."* 2643's job is to ship the surface that becomes correct-and-complete the moment 2821 lands — and because D3 keeps predicate evaluation server-side in 2732's validator, **that widening needs zero 2643 code** (§9.2). ③ **2732 Q9 (`:2561`) answers "No" to exactly this widening**, and `:2308`(i) makes the deferred deadlock-retry ticket *"an absolute prerequisite before Q9 widens P2.4 to admit pick locations."* r1 answered a hard infrastructure prerequisite with a UI banner; r2 does not incur the prerequisite at all (§5.1 row 9). ④ **The cost is real and is stated, not hidden:** the ICE PACK location the ticket names is **not** configurable through 2643, and 496/496 flowbins are excluded. **That cost was unavoidable under every coherent option** — including r1's, whose only coherent form was a change request against 2732 that would have inherited the same deadlock gate. ⑤ **The residual risk is now a UI legibility risk, not a data risk:** an operator must not conclude the search is broken. §3.8.2a is the mitigation and it is a verified deliverable (`B2-banner`, `B2-banner2`, `scopeBannerNamesBlockingTicket`). See §9.1 for the rejected option, §11 PM3, §15 |
| **D2** (r2: **narrowed**) | **2643 ships the DETECTOR ONLY** — a test that **EVALUATES the SpEL string** against a real expression root. The correct expression is `Authority.getExpForRole(Authority.SB_ADMIN_ROLE)` → `hasAuthority('sb_admin')`, but **applying it in `PutawayConfigService` / `PutawayConfigController` is 2732's review or [SBDEV-2863](https://app.clickup.com/t/868knmx18)'s, not 2643's** (§3.1 r2 box, §5.1 row 0e). The 9 pre-existing broken endpoints are SBDEV-2863's | `Authority.java:14` `IS_SB_ADMIN = "isSbAdmin()"` names a method that exists nowhere; the only admin predicate is `isAimAdmin()` (`CustomMethodSecurityExpressionRoot.java:77`), so 9 sites 500 for everyone. Safe with no `ROLE_` prefix because `CustomMethodSecurityExpressionHandler.java:19` calls `setDefaultRolePrefix(null)`. **A direct `isAimAdmin()` call cannot catch this class of defect** — `CustomMethodSecurityExpressionRootUnitTest:170-206` is proof: it has been green for the whole life of the bug |
| **D3** | **Server-side predicate evaluation:** `GET /v3/putawayConfig/eligibleLocations?scope=SKU`. Do **not** widen `getLocationView()`; do **not** re-implement predicates in Vue | §9.3 |
| **D4** | **AC7 is asserted as an invariant, not built for.** One DB per facility (2732 §2.4); `/v3/location/detailView` and every repository read are inherently facility-scoped by the tenant datasource | Building anything for AC7 would be dead code |
| **D5** | **No table column** on the SKU grid (**Q4**) | §9.5. Avoids a second API change and F3's stale-rehydrate hazard |
| **D6** | **Strict reuse of `LocationPicker.vue`** (**Q7**) | 2732 `:1607` requires the same tiering and lock warning for the SKU picker. Cost: B2 hard-blocks on 2732 Phase 2-UI. Accepted |
| **D7** | **No count-and-confirm flow** (**Q8**) | 2732's `setSku` signature carries no `confirmIncompatibleSkus` |
| **D8** | **The tier-4 lane is excluded from the picker; "Clear / Use default" is the only route back** (**Q3**) | `PutAwayLane` (50155) passes every SKU-scope predicate, so it is selectable — and pinning it produces identical receiving behaviour to NULL but a *different* configuration (tier 1 pinned vs. fall-through to tiers 2/3/4). The exclusion compares against the machine **name** constant, never the display label |
| **D9** | **AC8's richer signal comes from D-B's envelope, not from the details map** (**Q6**) | Keeps precedence and compatibility logic in exactly one place. The details map gains only the id (§3.3), which is enough to distinguish "invalid" from "inherits" |
| **D10** | **The UI gate is `disabled` + tooltip, never `v-if`** | The ticket says read-only users **may view**. Hiding the field fails AC1 for them; hiding the button hides that the capability exists |
| **D11** | **`ItemDataController.java:93`'s misleading log is raised in 2732's review; 2643 fixes it only if 2732 ships without it** (§0.1 row 11) | One line, and 2732 §3.5 rewrites the whole method. Duplicating the fix invites a conflict. ⚠ *r2 renumbering note:* r1 tagged this decision "(Q9)", which collides with **2732's** Q9 (the P2.4/pick-location question D1 now cites). 2643 has no Q9 of its own; the reference is §0.1 row 11 |
| **D12** (r2, **new**) | **2732 owns D-D (`GET /putawayConfig/eligibleLocations`). §3.5 is a full specification handed over; A3 is 2643's named fallback with a decision deadline before A3's TDD gate** | Resolves **Q5**. 2732 `:1605` mandates a picker filtered over `/location/detailView`, which exposes none of the flags (`ViewDtoService.java:815-822`), so **2732's own Step 19 (`:2036`) is blocked identically** — the endpoint is on 2732's critical path with or without 2643. Building it here would invert the dependency direction of the feature family and leave 2643 owning an endpoint inside 2732's controller. §3.5's ownership box; §5.1 row 0d |
| **D13** (r2, **new**) | **`describeForSku` lives in 2643's own `service/SkuPutawayQueryService.java`, not as a method added to 2732's `PutawayDestinationQueryService`** | The `Propagation.MANDATORY` resolver needs **a** `@Transactional(value="tenantTransactionManager", readOnly=true)` bean between controller and resolver; it does not need that bean to be 2732's file. Converts the plan's hardest ordering constraint from a three-way merge into a compile-time type dependency, and drops R1's cross-plan write surface to zero in the plan of record. §3.2 |
| **D14** (r2, **new**) | **`LocationPicker.vue`'s props/events contract is SPECIFIED in §3.8.2b and handed to 2732**, rather than waited for | Resolves **Q6** to *specified-pending-acceptance*. Waiting forfeits every user-visible AC while the ticket runs `urgent`; specifying costs at worst one dialog's binding rewrite, detected by `B2-picker`. The shape is the repo's own idiom at `createBol.vue:68-76` — the file's only `v-autocomplete` (§10.3 C7) |

### 10.2 Open questions

| # | Question | Blocking? | Recommendation / next action |
|---|---|---|---|
| **Q2** | **What does `GET /putawayConfig/preview?scope=SKU` return?** 2732 §3.5a specifies a 7-field envelope whose `incompatibleSkuCount` / `totalSkuCount` / `exampleIncompatibleSku` are degenerate at SKU scope (the subject *is* one SKU ⇒ 0-or-1 of 1). 2643 wants `compatible` + `blockingReason` as its pre-Save gate. **2732 never states whether `preview` accepts `scope=SKU` at all.** | **YES for the dialog's Save-gating design** — not for the write, which always returns a real 422 | **OPEN.** Assume `{compatible, blockingReason, locationId, locationName}` are meaningful and the three counts are `0/1/null`. Confirm with 2732's author before B2's TDD gate. If `preview` rejects `scope=SKU`, B2 gates on the write's 422 alone — workable, one extra round-trip for the operator |
| **Q6** | **`LocationPicker.vue`'s props/events API is unspecified.** 2732 §3.11.2 specifies the component's *behaviour* (two tiers, the storage toggle, the lock warning, `/location/detailView` as the source) but there is **no prop list, no event list and no `v-model` contract** in 2732 §3.11.2, §3.11.3 or Step 19 (`:2035`). ⚠ 2732 also grounds it in `createBol.vue:109-121, :125` — a citation r2 **verified as WRONG** (§10.3 C7) | **YES for B2** | **SPECIFIED — awaiting acceptance (D14).** r2 promotes r1's interim guess to a **written spec at §3.8.2b**, grounded in the *real* precedent at `createBol.vue:68-76`, and makes 2732's acceptance a §5.1 row 0b item. **Do not start B2 until 2732 accepts it or returns a counter-spec** — a picker whose contract changes mid-implementation is R5 (§11.0) in its most expensive form. Note `@select` must emit the **full row**, so the caller reads `blockingReason` without re-deriving it (§14 principle 2) |
| **Q10** | **What is the manual-test subject?** The ticket names an Ice Pack system SKU in HMG. **No Ice Pack SKU exists on hydra DEV** (nearest: `ICEDCARAFE` 18118465, `ICEBAGCHILLER` 18118466, both `22LEG536`), and all 2,720 SKUs point at 50155 — so the reported invalid configuration is a **PRD-only** state (SBDEV-2731: SKU 52072 → location 52075) on this v1→v2-migrated dev copy | No — but §7.5 is unwritable without an answer, and a reviewer will report "cannot test" | **OPEN.** Ask which tenant/SKU actually carries the reported configuration and whether the manual plan may run against **UAT**. Interim: designate `ICEBAGCHILLER` (18118466) as the DEV stand-in, recorded in §7.5 |
| **Q11** | **Does "system SKU" (AC10) mean `client_id` = the System client?** `ClientService.getSystemClient()` looks up `cl_nr='System'` and 2732 §7.6 notes it returns **null** when no such row exists. If HMG has no System-client row, AC10's subject class may not exist there. ⚠ SBDEV-2731 records the PRD ICE PACK SKU as `client_id = 0` (`System-Client`), so the class certainly exists on PRD | No | **OPEN.** Run `SELECT id, cl_nr FROM client WHERE cl_nr = 'System' OR id = 0;` on the target tenant before writing AC10's test. If absent on DEV, AC10 is a UAT/PRD-only manual row |
| ~~**Q5**~~ | ~~**Who ships D-D (the eligible-locations read)?**~~ | — | **RESOLVED in r2 by D12: 2732 owns it.** §3.5 is a full specification handed over; A3 is 2643's named fallback with a decision deadline before A3's TDD gate (§5.1 row 0d). Grounds: 2732's own Step 19 (`:2036`) is blocked by the identical gap, so the endpoint is on 2732's critical path regardless; building it in 2643 inverts the feature family's dependency direction; and if 2732 later reshapes `blockingReason`/`PutawayScope`, 2643 would own a broken endpoint in someone else's controller. **Still requires a written answer — an unsettled hand-over is the same schedule risk it always was** |

### 10.3 Corrections to SBDEV-2732's own citations — **flagged for 2732's author**

**Ten findings** from verifying 2732's contracts against disk at `6bc709a` / `4ce39a1`. **C1–C9 are
*citation* defects** — an implementer following them lands in the wrong file or the wrong hunk. **C10
(added in r2) is not a citation defect: it is 2732 contradicting itself, twice, on the exact rules 2643
depends on.** **Fix them in 2732 rather than propagating them.**

| # | 2732 (or the brief) says | Actual | Severity |
|---|---|---|---|
| **C1** | `SecurityConfiguration.java` is under `config/` | It is `src/main/java/net/aim_ai/wms/SecurityConfiguration.java`. **`config/SecurityConfiguration.java` does not exist.** Line `:136` is correct | low — path only |
| **C2** | `skuData.vue:100-123` is *the* actions block, implying no actions column exists | There are **TWO** `item.actions` templates: an **ACTIVE** one at `:95-99` rendering a live eye button (`:97` `@click="showDetails(item)"`), and the commented pencil/trash/menu block at `:100-123`. **An actions column already exists and already ships one button** | **medium** — changes the UI work from "create a column" to "add a second button" |
| **C3** | `skuData.vue:142` is the load-bearing line for the details overlay | `:142` is correct for the label map, but the load-bearing line is **`:130`** `:exclude-fields="['id','itemNr','version']"` — that is what makes A1's added key render as a stray row | **medium** |
| **C4** | **2732 §0.2 row 45** cites `components/masterData/skuData.vue:107-131, 142` | **Wrong in BOTH path and range.** The real path has two extra segments: `components/masterData/material/skuData/skuData.vue`. The commented block is **`:100-123`**, not `:107-131`. Only `:142` is right. ⚠ **2732 §10.4 Q3 and §8.1's "unblock 2643" note repeat the wrong `:107-131` range** | **HIGH** — this is the row that scopes 2643, and both of its coordinates are wrong |
| **C5** | **2732 §3.12** cites *"the pattern used throughout `AdminController.java:93, 121, 134, 147, 156`"* | Actual active `@PreAuthorize` lines: **`80, 108, 121, 134, 143, 155, 176, 194`**. Only `121` and `134` match. (`:184, 248, 269, 297` are **commented out**.) And every one of those 8 sites is **broken** (F1/D2) | **medium** — the cited "pattern" is a pattern of 500s |
| **C6** | **2732 §7.7 row 7** names **`BaseControllerTest`** | The class is **`BaseControllerUnitTest`** (`src/test/java/net/aim_ai/wms/common/base/BaseControllerUnitTest.java:34`). There is a separate `BaseControllerIntegrationTest`. **`BaseControllerTest` does not exist.** The template `wms-plan-template.md` §6 carries the same wrong name | **medium** — an implementer extends a class that is not there |
| **C7** (r2: **upgraded to CONFIRMED WRONG**, with the real coordinates) | **2732 §3.11.2 `:1594`** grounds `LocationPicker.vue` in `createBol.vue:109-121` (inline `v-autocomplete`) + `:125` (a *"Lookup"* button opening a search dialog) | **CONFIRMED WRONG on all three counts.** Path: `components/outbound/bol/create/createBol.vue` — 2732's is short one segment. **`:100-130` is a run of plain `<v-text-field>`s** (Carrier, Truck Number, Seal Number / Tag, Tracker ID) — no autocomplete at the cited range. The file's **only** `v-autocomplete` is at **`:68-76`** — an *Order Batch* picker: `v-model="orderBatchId"` `:69`, `:items="orderBatches"` `:70`, `item-text="label"` `:74`, `item-value="value"` `:75`. And **`grep -n 'Lookup\|lookup'` over the whole file returns NOTHING** — there is no Lookup button anywhere in it. ✅ **But the *shape* 2732 wanted does exist, at `:68-76`, and it is the repo's idiom** — which is what makes §3.8.2b's spec cheap. The other confirmed (naive) precedent is `moveFixedLocation.vue:13` | **medium** — the named precedent for a component 2643 consumes is off by ~40 lines, names the wrong control type at the cited range, and invents a control that does not exist |
| **C8** | `LocationRepository.getStorageLocationsForPutAwayItemData` spans `:104-120` | **`:104-111`.** `:112-119` is the sibling `getStorageLocationsForStockUnitItemData`. And the method is worse than described: its predicate is `a.useforstorage = 'true'` **and it is stockunit-driven**, returning only locations where the SKU already has stock — unusable as a picker on two independent grounds | low — 2732's verdict (do not use it) is right for a stronger reason than stated |
| **C9** | `ItemdataService.setPutAwayLocation` spans `:68-76` | The method does span `:68-76`, but its `@Caching`/`@CacheEvict` block sits **above** it at `:62-67`. Anyone editing "`:68-76`" will move the method away from its annotations | low |
| **C10** (r2, **new — the only DESIGN-level finding in this table**) | **(a)** 2732's own front matter `:114-119` states the 2026-08-06 revision leaves *"P2.5 scope-dependent; **tier 1 exempt from P2.7(c)**"*. **(b)** 2732 §3.11.2 `:1605` mandates *"The picker's filter must be **exactly P2.4** (`useforgoodsin OR useforstorage`)… Offering anything P2.4 rejects produces a 422 the operator cannot act on."* | **2732 contradicts itself on both.** **(a) The tier-1 P2.7(c) exemption does NOT exist in the body.** `:711` says P2.7(c) is *"**Absolute at all three scopes** — tier 1 included"*; `:792-795` says *"Tier 1 (SKU) is exempt from (a), (b) and (d) — **but NOT from (c)**, deliberately"* and records that *"(a) 2026-08-04 revision briefly added (c) to this exemption list; **reverted the same day**"*; and `:2211` ships `skuWriteRejectsPickFaceDestination` to enforce the reject. **The front matter documents a state that was rolled back — on the exact rule 2643's D1 turns on.** ⚠ **2643's r1 was drafted against the front-matter reading and had to be reversed** (§15). **(b) `:1605`'s mandated filter offers what `:722`'s validator rejects.** P2.4 admits a `useforpicking` area that *also* carries `useforgoodsin` or `useforstorage` — **511 of 666 locations on hydra DEV** (§2.2) — and P2.7(c) then rejects every one of them. So **2732's own picker, at merchant and warehouse scope, offers 511 rows whose selection 422s** — the identical defect r1's D1 was reversed for, at larger scale, and with no equivalent of 2643's scope banner. ✅ **2732's own Q12 (`:2558`) independently reaches the same conclusion from the other direction:** verified SELECT-only on `wsl-wineco-uat`, `Club01`–`Club08` (ids 225748+) have **all five lane flags FALSE** and sit in area 51553 with **`useforpicking = TRUE`** — they are *"live multi-SKU pick faces, not staging lanes"* (`Club01`: 114 ULs / 27 SKUs / 973 bottles). **So 2732's own named tier-2 use case — "Club assembly lane" — is also blocked by P2.7(c)**, and Q12 states the three coherent answers, of which (i) is *"P2.7(c) stands… belongs with SBDEV-2821's pick-face work"* — **which is exactly r2's D1, arrived at independently.** That corroboration is the strongest available evidence that r2's D1 is right and that `:1605` and `:114-119` are the things that need fixing | **HIGH** — (a) is why r1 was wrong; (b) means 2732's Phase-2 picker is **unimplementable as specified**. §2.2's measurement is the first evidence of it |

**Two more, not citation errors but worth 2732's attention:**

- **`IdempotencyFilter.java:262`'s Javadoc names `ItemdataService.setPutAwayLocation`** — it goes stale
  the moment 2732 §3.5 rewrites that method.
- **2732 §8.1 (`:2293`) makes non-zero tier-2/3 metric usage a condition for closing 2643.** That is the
  wrong signal for a SKU-tier ticket: `MERCHANT_OVERRIDE`/`WAREHOUSE_DEFAULT` can stay at zero forever
  while 2643 works perfectly. **2643's own gate is `resolution{source="SKU_OVERRIDE"} > 0`** (§5.1
  row 8, §8.4).

### 10.4 Closed questions — do not re-investigate

> **r2 numbers these rows (Critic F-2).** `Q3`, `Q4`, `Q7` and `Q8` were cited ~20 times across §0, §3,
> §4, §7, §10.1 and §13 and **defined nowhere** — the same defect class as the missing `R<n>` register
> (§11.0), in the adjacent namespace. A pointer such as *"Q4 answered NO COLUMN (§10)"* sent the reader
> to a section that did not contain a Q4. Every `Q<n>` citation in this document now resolves to a
> numbered row below, or to §10.2 for the still-open ones (Q2, Q6, Q10, Q11).
>
> **Numbering note:** there is deliberately **no Q1** — r1's Q1 (pick faces) was promoted to decision
> **D1** and lives in §10.1. **Q5** is struck (superseded by D3). Where this document discusses a
> question belonging to *SBDEV-2732* rather than to 2643 — 2732's own Q3, Q8, Q9 and Q12 — it is written
> **"2732's Qn"** explicitly; a bare `Qn` always means 2643's.

| # | Question | Answer |
|---|---|---|
| **Q3** | **Should the tier-4 `PutAwayLane` itself be offered in the SKU picker?** | **No — excluded (D8).** It passes every SKU-scope predicate (measured: id 50155, `entity_lock=0`, area `Inbound`, `useforgoodsin=TRUE`, all lane flags FALSE, 0 FLA rows), so it *would* be selectable. But pinning tier 1 to the lane and clearing the override produce **identical receiving behaviour and different configurations** — the pinned SKU stops inheriting a future merchant or warehouse default. "Clear / Use default" is the only supported way back. Excluded by the `STORAGE_LOCATION_PUTAWAY_LANE` **name** constant (§0.3 row 32), never by a hard-coded id |
| **Q4** | **Does the SKU table get a "Default Putaway Location" column?** | **No — overlay and dialog only (D5).** `getItemDataViewPage` (`ViewDtoService.java:895-931`, projection `:915-924`) does not project it, so a column means a second API change; and `masterData.skuData` is persisted to `localStorage['vuex-web']` (`plugins/persistedState.client.js:26-29`), so a stale rehydrated row could render a pre-write value (F3). The overlay always refetches (`skuData.vue:304`), so it is safe. Revisit only if operators ask |
| **Q7** | **Does 2643 build its own picker or reuse 2732's `LocationPicker.vue`?** | **Strictly reuse (D6).** 2732 `:1607` states the same tiering and lock warning apply to the SKU picker. A second picker means a second implementation of a safety-critical filter set that 2732 revised twice in three days. Cost, accepted: **B2 hard-blocks on 2732 Phase 2-UI**, not just Phase 1-API. Mitigated by §3.8.2b, which specifies the props/events contract 2732 never defined and hands it over |
| **Q8** | **Does the SKU screen need 2732's count-and-confirm preview flow?** | **No — answered by 2732's own signature.** `PUT /putawayConfig/sku/{itemdataId}` takes only `locationId`; `confirmIncompatibleSkus` exists **only** on `setMerchant` and `setWarehouse` (2732 §3.5a). Count-and-confirm is a bulk-blast-radius device and one SKU has no blast radius. 2643 needs only the **blocking** signal (`compatible` / `blockingReason`), not the confirmation dance (D7). ⚠ Not to be confused with **2732's** Q8, referenced in §10.5 |
| **Q13** | Does 2732's Q12 (club/staging lanes via P2.7(a)) block 2643's picker? | **No.** Q12 is a tiers-2/3 question and at SKU scope **P2.3 rejects all lane flags unconditionally**, so its answer cannot change 2643's eligible set. ✅ **r2 addition — Q12 does something more useful than block: it corroborates D1.** Q12 was *re-framed by measurement* on 2026-08-06 (`:2558`): wineco's `Club01`–`Club08` have **`staginglane = FALSE`**, all lane flags FALSE, and **`useforpicking = TRUE`** — they never passed through rule (a) at all and are **blocked by P2.7(c)** instead. So 2732's *own* named tier-2 use case is blocked by the same rule that blocks 2643's, and Q12's answer (i) — *"P2.7(c) stands… belongs with SBDEV-2821's pick-face work"* — **is r2's D1, reached independently for the club case.** §10.3 C10 |
| **Q14** | Does a preloaded, client-side-filtered picker scale? | **Yes** at 666 locations (measured). 2732's Q2 is NO-PROBLEM for this tenant. AC3's "searchable" needs a search *box*, not a server-search endpoint — D3 puts predicates server-side for correctness, not scale |
| **Q15** | Is there v1 prior art to port? | **No.** SBDEV-2642 shipped zero commits (2732 §10.5). Nothing to port, and the Jakarta-vs-javax question is moot |
| **Q16** | Does `getItemdataDetails` need a `@Transactional`? | **No**, and adding one would be a scope creep. It has none today (`ItemdataService.java:15` is a bare `@Service`), works because every FK on `Itemdata` is a manual `Long` with no lazy association, and A1 adds **zero** queries |
| **Q17** | Where did the invalid ICE PACK configuration come from? | `ItemDataController.java:88-90` — raw `save()` with zero validation (2732 §10.5). Fixed by 2732 §3.5, not by 2643 |
| **Q18** | Does 2643 need `V2.2.11`? | **For AC4 and AC9, yes — transitively.** For its own code, **no**: 2643 ships zero migrations and A1's added key is read-only |

---

## 11. Risk register and pre-mortem

### 11.0 Risk register — R1…R10

> **r2 adds this section.** r1 cited `R1`, `R2`, `R4` and `R5` seven times as *"(§11)"* and **defined
> them nowhere** — a reader following *"see R2 (§11)"* landed on the pre-mortem. Every `R<n>` citation in
> this document now resolves here.

| # | Risk | Sev / likelihood | Mitigation, and where it lives | r2 change |
|---|---|---|---|---|
| **R1** | **Stacked-PR merge-order orphan.** A 2643 PR opened against 2732's *branch*, or branched from `origin/develop` before 2732's Phase-1 merge landed, then orphaned when 2732 is squashed / rebased / force-pushed on review feedback. **This is the recorded failure that orphaned PR #51** | **HIGH** severity, MEDIUM likelihood | §8.1's four-step ancestry gate as literal commands, run **before opening the PR and again before merging** — not once at branch time. `git merge-base --is-ancestor "$BASE" HEAD`. Plus §8.1 step 2, which asserts the *constructs* exist at the base commit, because a merged-then-reworked PR is the same failure with a green checkmark. §11 **PM1** | **↓ REDUCED.** r1 had 2643 writing into four 2732 files (a method into the facade, a security-annotation swap in two more, `blockingReason`/`advisory` in a fourth). **r2's plan of record writes into zero** — D13 moves `describeForSku` into 2643's own `SkuPutawayQueryService`, §5.1 row 0e removes the swap, D12 hands D-D over, and D1's reversal deletes the enum/field mutations. What remains is a **type-level** dependency: a compile error, not a three-way merge |
| **R2** | **`ItemDataControllerUnitTest.java` merge conflict.** 2732 Step 9 rewires `ItemDataController:80-95` and must edit the `@Nested SetPutAwayLocation` class at `:119-158`; 2643 A1/A2 edit the same file | HIGH likelihood, **LOW** severity (a conflict, not a defect) | 2643 appends a **NEW** `@Nested EffectivePutawayDestination` class at EOF (`:374`) and **never touches `:119-158`** (§0.2 row 44, §4). It touches `:91-102` only for the constructor arity. Verify row `A2-nested` | unchanged — this one is irreducible, both plans genuinely need that file |
| **R3** | **`ItemdataService.java` conflict.** 2732 rewrites `setPutAwayLocation` (`:62-76`); 2643 edits `getItemdataDetails` (`:166-171`) | MEDIUM likelihood, LOW severity | Different hunks ~45 lines apart; should auto-merge. **Watch the import block** — that is where these conflict in practice | unchanged |
| **R4** | **API/UI deploy-window skew.** A1 merges, DEV auto-deploys on push, and until the `exclude-fields` line is live every SKU details overlay renders a stray raw-integer `PutawayLocationId` row (§6.1) | MEDIUM, **user-visible** | **`B1-pre` is a HARD PREREQUISITE of A1** — one line, a provable no-op today, deployed first (§5.1 row 4, §8 step 2). Verify row `B1-exclude`; manual **M2** observes the hazard locally, **M1** confirms the fix on DEV | **↓ REDUCED.** r1 framed the ordering as a "safe trick" / "prefer that ordering"; r2 makes it a gate, so the window closes by construction rather than by discipline |
| **R5** | **Building on a contract that changes.** Every contract in §3.2 / §3.4 / §3.5 is on unwritten code, and 2732 has a visible revision history: its §12 changelog shows P2.5 flipped and reverted the same day, P2.7(c) became implementable only on 2026-08-06, and 2732's own **D18** (`:103-106`) records **no independent review pass** plus a prior **CRITICAL** finding | **MEDIUM–HIGH**, and it already fired once | ⛔ **§3's blocking banner** + `CONTRACT-PROVISIONAL` headings on all three subsections + §5.9's first checklist item: **re-derive every §3 contract from 2732's *merged* PR before writing a single test.** Temporal mitigation only — §8.1's ancestry gate | **⚠ CONFIRMED, not theoretical.** r1's D1 was built on 2732's front-matter claim (`:114-119`) that tier 1 is exempt from P2.7(c); the body says the opposite and records the exemption reverted the same day (§10.3 **C10a**). **r2 exists because R5 fired.** That is why the hedge was promoted from a bullet to a banner |
| **R6** | **F1 makes AC12 unprovable.** `Authority.IS_SB_ADMIN` names a SpEL method that does not exist, so any `@PreAuthorize` using it returns **500 for everyone**, `sb_admin` included — and `standaloneSetup` (`BaseControllerUnitTest:52-58`) evaluates no `@PreAuthorize`, while the `@SpringBootTest` lane is down (SBDEV-2217) | MEDIUM | A0's **SpEL-evaluation** detector (§3.1) + manual **M8** (403, not 500, not 200) + §5.1 row 0e as a blocking prerequisite + verify row `X-2732-authz` | **↕ RE-HOMED.** r1 mitigated it by *editing 2732's files*; r2 keeps the detector and the finding and makes the edit 2732's review's or SBDEV-2863's (§3.1 r2 box). **Consequence to state plainly: AC12 is not 2643's to close alone** |
| **R7** | **The picker cannot be built as 2732 specifies.** `/location/detailView` exposes none of the eligibility flags (`ViewDtoService.java:815-822`), so 2732 `:1605`'s mandated client-side P2.4 filter has nothing to filter on — and **2732's own Step 19 (`:2036`) is blocked identically** | MEDIUM, **schedule risk for BOTH tickets** | D3 (server-side evaluation) + D-D (§3.5), **owned by 2732 per D12** with A3 as 2643's fallback and a decision deadline (§5.1 row 0d) | **↑ SHARPENED.** r1 left ownership as an open question while keeping A3 and 8 producer verify rows. r2 resolves ownership (D12) and re-scopes the verify rows so 2643 asserts only what it writes (§13) |
| **R8** | **v2 IT harness down** (SBDEV-2217) — no Testcontainers lane, so no test can prove Spring wiring, propagation or `@PreAuthorize` | LOW (known, stable) | Gate on `mvn test` + `mvn clean compile`; any new IT `@Disabled` with `TODO(SBDEV-2217)`; SDKMAN PATH export; **baseline the 2 known `develop` failures** (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) before the first change. §7.1, §7.9 | unchanged |
| **R9** | **`mvn test` mutates tracked files** — `src/test/resources/archunit_store/{stored.rules, 5fb3fee0-…}` (F4). A new unguarded `Optional.get()` either fails the build or **silently freezes** into the store | LOW severity, HIGH likelihood | `git checkout src/test/resources/archunit_store/` before **every** commit (§5.9). Verify row `X-archunit` fails a dirty store | unchanged |
| **R10** | **Verify-script false green.** The `verify-plan-template` `perl -0777 -ne` and `grep` helpers **exit 0 when they cannot open the file**, so every multi-line assertion about a **new** file passes vacuously — and 2643 creates several. Recorded landmine; SBDEV-2736 scored 57 pass / 0 fail on the build carrying the defect its ticket was written to catch | MEDIUM | **Every** helper opens with `[ -f "$2" ] || return 1`, negative helpers included (script `:139-169`), with the reasoning in the script header. Plus the script's SELF-TEST block and the negative-testing discipline in §7.5 | **↓ FURTHER REDUCED in r2.** The 2732 gate now greps **class declarations** instead of `[ -f ]` and **escalates SKIP → FAIL** once a SBDEV-2732 merge is on `origin/develop` — closing the "renamed-on-merge facade SKIPs every 2732-blocked check forever" fail-quiet. Three checks weaker than their names (`A2-env`, `B2-jest4`, `B1-jest2`) were strengthened |

**The irreducible residue, stated rather than resolved:** 2643 is a consumer of an **unapproved**
interface. r2 removes every *textual* coupling from the plan of record, but `Resolution`, `Source` and
`PutawayScope` are 2732 types wherever the methods live. **The only real mitigation for that is temporal
— wait for 2732's merge commit (§8.1) — not architectural.** The two alternatives are "duplicate the
predicates" (rejected, §9.3) and "merge 2643 into 2732" (rejected, §9.4), and both are worse.

### 11.1 Pre-mortem — three ways this ships and still fails

### PM1 — It ships as an orphan, and the API half silently disappears

A2's PR was opened against **2732's feature branch** rather than `develop`, or was branched from
`origin/develop` *before* 2732's Phase-1 merge landed. 2732's branch is then squashed, rebased or
force-pushed on review feedback. A2's commits become unreachable; GitHub still shows the PR as open and
mergeable; a later merge succeeds and drops `SkuPutawayQueryService` and the new endpoint on the floor.
B2 deploys against an endpoint that returns 404, and the dialog shows an empty effective value with no
error — because `getSkuEffectivePutaway` has no `catch` and Nuxt swallows it.

⚠ **r2 variant, and it is the one the verify script now catches:** 2732 merges but with the facade
**renamed or relocated**. r1's `phase_2732_present()` was three `[ -f ]` tests, so it would have stayed
false and reported **"blocked on SBDEV-2732"** for every 2732-blocked check — the *wrong story*, since the real state is
"the contract drifted". r2 greps the class declarations and escalates **SKIP → FAIL** once a SBDEV-2732
**merge commit** is on `origin/develop` (SHOULD-8).

> **The probe is deliberately narrow, and deliberately unwindowed.** A first cut used
> `git log origin/develop --grep=SBDEV-2732`, which matched **four** commits on 2026-08-07 — `89de3f0`,
> `b623561` (SBDEV-2731) and `a991c9e`, `a2bd0e9` (SBDEV-2854) — none of them a 2732 merge, all merely
> *citing* 2732 as a dependency. That escalated every correctly-blocked SKIP into a FAIL, i.e. the drift
> detector became the false signal it exists to prevent. It now matches **merge commits carrying a 2732
> branch name** (`Merge pull request #N from Org/feature/SBDEV-2732-…`, the verified shape on this repo),
> and scans **all** merges: a `-50` window would make the probe expire silently ~29 days after 2732's
> merge on this repo's cadence (192 merges on `develop`), which merely defers the fail-quiet rather than
> closing it. Negative-tested three ways: silent today, fires on a simulated real 2732 merge, ignores the
> four false positives above.

This is not hypothetical: it is the recorded failure that orphaned **PR #51**.

*Detector:* `git merge-base --is-ancestor "$BASE" HEAD` (§8.1) run **immediately before opening the PR
and again before merging it** — not once at branch time. Plus a post-merge
`git grep -l 'describeForSku' origin/develop -- src/main/java` returning a hit. Plus manual **M9**
(a 404 or 500 rather than a 7-field 200).

*Mitigation:* §8.1's four-step command block, verbatim, per stacked phase. **Never `--base` a 2643 PR on
a 2732 branch.** And do not trust "2732 is merged" — step 2 of that block asserts the *constructs*
exist at the base commit, because a merged PR whose content was reworked is the same failure with a
green checkmark. **r2 adds a second layer:** D13 puts `describeForSku` in a 2643-owned file, so the
orphan variant where 2643's method is dropped *out of 2732's file during 2732's own rework* cannot
happen — that file is not 2732's to rework.

### PM2 — It ships completely, every test is green, and nothing is ever configured

All six phases land. The dialog works. And **2,720 of 2,720 SKUs still point at `PutAwayLane`**, because
2732's stop-seeding and scoped backfill either never applied to a tenant (`V2.2.11` merged but not
applied — 2732's own pre-mortem P1) or applied and nobody used the new screen. Operators do not know the
capability exists: the pencil button is one more icon on a master-data table nobody was told changed.
The ticket closes on green tests, and the requester reports the same problem in six weeks.

**This is the most likely failure**, because every automated signal is green in exactly this state — the
verify script passes, both test suites pass, and the manual plan passes on a stand-in SKU nobody uses.

*Detector:* **`wms2.putaway.resolution{source="SKU_OVERRIDE"}` stuck at zero** two weeks after B2.
Corroborate in SQL per tenant: `SELECT count(DISTINCT putawaylocation_id) FROM itemdata;` still returning
**1**, or `SELECT count(*) FROM putaway_config_audit WHERE scope='SKU';` returning **0**. ⚠ Note that
2732 §8.1's tier-2/3 condition would **not** detect this — those counters can be non-zero while the SKU
tier stays inert, and vice versa.

*Mitigation:* §8.4 makes `source="SKU_OVERRIDE" > 0` a **closure condition**, not a nice-to-have — the
ticket cannot be closed against an inert feature. Plus: hand the requester the exact click path and the
stand-in SKU in the PR description, and confirm one real configuration on UAT with them present before
closing. Q10 exists precisely so that confirmation has a real subject.

### PM3 — It ships, it is correct, and the operator concludes it is broken

**r2 rewrote this scenario, because r1's version described a failure mode r2's design makes
impossible.** r1's PM3 was *"an operator saves a pick-face configuration and every receipt for that SKU
then fails"* — which could not happen even under r1, because the **write** 422s (§9.1, §10.3 C10a). With
D1 reversed, no operator can configure an incompatible destination through 2643 at all. **The real
residual risk is not a bad configuration. It is a good feature that reads as a broken one.**

The scenario: B2 ships. Scott Dalton opens the SKU screen for the Ice Pack SKU — the worked example in
his own ticket — clicks the new pencil, types `ICE` into the location search, and gets **nothing**. He
tries the flowbin's name. Nothing. The list he can see holds 92 rows, none of which is the location he
filed the ticket about, and 496 of the warehouse's locations are flowbins. **He concludes the search box
is broken, or that the feature was built wrong, and reopens the ticket** — which is materially worse than
r1's scenario, because it burns the requester's trust in a feature that is behaving exactly as designed.

Second variant, subtler and more likely at scale: an operator *does* find a plausible-looking storage
location, saves it, and it works. Then receipts of that SKU hold `FOR UPDATE` on that Location row for a
whole multi-case receipt — **arming §7.4 row 8's lock-order inversion, which has no deadlock-retry
infrastructure.** This is 2732's accepted risk (`:2308`(i), `:1607`), not a new one, and it is the reason
the storage tier must stay behind a toggle.

*Detector:* the ticket being reopened, or a support question of the form *"the location picker doesn't
show our bins"*. There is **no metric for a misread UI** — which is precisely why the mitigation has to
be in the UI text rather than in observability. For the second variant: **`40P01` /
`DeadlockLoserDataAccessException` in the logs on `/receiving/receive`** — and it **must** be log-based,
because that endpoint returns 200-with-`errors` and never a 5xx, so an HTTP-status alert misses it
entirely. Also watch `wms2.putaway.resolution.rejected`: under r2 a non-zero value means a *pre-existing*
DB-written configuration is invalid, or a write-time predicate and a receive-time check disagree — the
latter is a 2732 bug worth escalating, not an accepted state.

*Mitigation, four layers:* (1) **the always-visible scope banner** (§3.8.2a) states that pick faces are
not yet selectable, names **SBDEV-2821** and **SBDEV-2732 Q9**, and gives the eligible count — so the
short list is *confirmed and explained* rather than suspected; (2) the **picker's empty state** repeats
the same three facts, because a client-side filter can yield zero rows even with 92 eligible; (3)
**the banner wording is reviewed by Scott Dalton / David Oppenheim before B2 merges** (§5.7, §5.9) —
the person who will misread it is the person who filed the ticket, so he should approve the sentence; (4)
for the second variant, the picker **defaults to the `useforgoodsin` tier** with storage behind 2732
§3.11.2's explicit toggle and lock-contention warning, so arming the deadlock path takes two deliberate
operator actions. *Kill path for a regretted configuration:* one Clear in the dialog, or
`UPDATE itemdata SET putawaylocation_id = <lane id> WHERE id = …`.

**And the honest framing for the requester, which belongs in the PR description, not buried here:**
*"This ticket ships the configuration surface. The specific location in your example is a pick face;
pick-face putaway is SBDEV-2821 and is not yet supported by receiving, so it is not offered here yet —
the screen will offer it automatically once 2821 lands, with no further UI work."*

---

## 12. Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | **All callsites enumerated** — every §0 row covered by §3 Design or excluded with rationale | ✓ §0 (85 rows across 3 sub-tables) → §3 / §4. Every out-of-scope row carries `no — owned by SBDEV-2732 <section>` or an explicit `out` rationale |
| 2 | **Adjacent shapes** — other classes/methods sharing the pattern that need the new behavior | ✓ §0.1 rows 29–31 (the 4 other `putawaylocation_id` write paths — all 2732's), row 34 (`BoxtypeService.java:87` shares the *key name* on a different entity — deliberately NOT swept), §0.2 row 53 (its test), §6.2 (the 15 payload consumers), §0.3 row 85 (mobile UI, out) |
| 3 | **Backward compatibility** — API contract, DB schema, persisted state, frontend payload, error-response shape; explicit "What Does NOT Change" | ✓ §6 (13-row table), §6.1 (the `fullDetails` stray-row hazard + its no-op pre-fix), §6.2 (all 15 call sites: 3 + 12 + 0), §6.3 (18-item **What Does NOT Change**) |
| 4 | **Concurrency** — races, lock ordering, optimistic-lock retry, deadlock, idempotency under retry | ✓ §7.4 rows 5, 6, 8 — including that **2643 is the surface that arms** 2732's accepted lock-order inversion (`transferUnitLoadToLocation:150` before UL/SU at `:293-294`, no retry infra) — ⚠ **r2: 2643 does NOT widen the armed set** (D1 reversed; §5.1 row 9 records why no deadlock-retry prerequisite is inherited). §11.1 PM3's storage-location variant + the log-based `40P01` detector |
| 5 | **Multi-tenant** — cross-tenant queries, tenant context propagation, per-tenant cache/pool scoping; v2 scalability checklist filled | ✓ §7.3 rows 2, 4 (`tenantTransactionManager` literal; the `allEntries=true` trap 2643 must not touch), §7.4 (all 10 rows), §10.1 D4 (AC7 is structurally satisfied — one DB per facility) |
| 6 | **Error handling** — every new throw path has a handler or a documented contract change | ✓ §3.2 (`IllegalTransactionStateException` → 500 if the resolver is called from a controller; prevented by `A2-neg-res` + M9), §3.4 (`BusinessException` on the new endpoint), §3.8.3 (422/409 land in `catch`, not `results.errors`; `e.response.data` surfaced), §3.8.3's CORS/`reset()` landmine + M6, §3.3 (the dangling-FK case becomes *representable* rather than throwing) |
| 7a | **DB verified** | ✓ frontmatter `db_verified: true` + `db_verified_note`; §2.1–§2.2 (every number re-measured SELECT-only on `wms2-hydra-dev2` 2026-08-07, independently of the analysis lane); §7.5's Q10 subject problem |
| 7b | **Observability** — logs, metrics, Grafana panels, alert thresholds | ✓ §7.7 (6 signals), §5.1 row 8 (the panel ops must add, and why 2732's closure signal is the wrong one for 2643), §8.4 item 3, §11 PM2's detector. §0.1 row 11 / D11 covers the one **log** defect (`:93` renders the new value as `oldLocation`) |
| 8 | **Rollout / migration** — Flyway version, backfill, deploy-order, feature flags, sysprop rows, rollback | ✓ §5.1 rows 1, 4, 5 (**zero migrations, zero backfill, zero flags** — each with a rationale, not a blank), §8 (7-step order), §8.1 (the ancestry gate as executable commands), §8.3 (rollback: code-only, no forward-only constraint anywhere) |
| 9 | **Test coverage** — unit + integration + manual smoke; named classes and methods | ✓ §7.1 (17 named Java methods), §7.2 (14 named Jest tests), §7.5 (**13 manual rows**, incl. M2 which proves a mitigation is load-bearing and M10 which proves D1's boundary from **both** sides — the picker's omission and the API's 422 — rather than a happy path), §7.6 (e2e = the M4→M5→M11 chain, recorded as a deliberate gap), §7.9 (7 skipped items, each with a reason). No performance target is claimed, so no perf test |
| 10 | **Cross-version (v1↔v2)** | **no — v2-only, and deliberately.** v1 has no equivalent UI and no 4-tier resolver; SBDEV-2642 (the v1 sibling) shipped **zero commits** across all five repos and was closed as superseded (2732 §10.5). There is nothing to port in either direction and no paired v1 plan is warranted |
| 11 | **Alternatives considered** — at least 2, each with an explicit rejection rationale | ✓ §9 — **4 primary** (offer pick faces behind an advisory / stack on 2821 / widen `getLocationView` / absorb into 2732), each with pros, cons and an explicit rejection, plus **6 more** in §9.5. ⚠ **r2 inverted §9.1**: what r1 rejected is what r2 ships, and r1's own D1 is now the rejected option — with the three grounds spelled out (the write 422s; 2732 Q9 declines the same widening; 2643 cannot divergence-document a validator it does not own) |
| 12 | **Principles the plan is graded against are STATED** | ✓ **§14** (r2 addition — MUST-7). r1 was audited against five principles it never wrote down, so a reviewer could not check the plan against them and the author could not tell when one was being traded away |
| 13 | **Risks cited are DEFINED** | ✓ **§11.0** (r2 addition — MUST-6). r1 cited R1/R2/R4/R5 seven times as "(§11)" and defined none of them; §11 was the pre-mortem |
| 14 | **Revision history is auditable** | ✓ **§15** (r2 addition) — every r1→r2 change tied to the Architect finding or user decision that drove it |

---

## 13. Acceptance

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh`

Run as:

```bash
# API checks
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
WEB_UI_ROOT=/home/nampark/dev/wms-claude/v2/wms2-web-ui \
  bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh
```

⚠ When run against a **worktree**, point `PROJECT_ROOT` / `WEB_UI_ROOT` at the worktree (or a symlink
shadow root), or the script grades the main checkouts instead of the work.

**The script reports SKIP — not PASS — for every 2732-blocked check**, and prints the skip count in its
summary. **A green run with a non-zero SKIP count is NOT "done."** Exit 0 requires every *runnable*
check to pass; §8.4 requires 0 SKIP as well.

**Three r2 changes to how the script grades:**

1. **The 2732 gate greps class declarations, not file existence** (`class PutawayDestinationQueryService`
   / `class PutawayConfigController` / `class PutawayConfigService`). r1's `[ -f ]` test meant an **empty
   file** passed the gate, and the header's claim that it *"tests for the CONSTRUCTS, not for a merge
   message"* was not true of the code beneath it.
2. **SKIP escalates to FAIL once SBDEV-2732 is merged.** If a SBDEV-2732 **merge commit** is on
   `origin/develop` but the constructs are absent under `PROJECT_ROOT`, the honest verdict is **contract
   drift (PM1)**, not "blocked" — so those rows FAIL and say so. The probe matches a 2732 **branch name
   on a merge commit** and scans all merges: a bare `--grep=SBDEV-2732` matches commits that merely cite
   the ticket (4 such on 2026-08-07), and any `-N` window lets the signal expire silently. Without this, a renamed-on-merge facade
   SKIPs every 2732-blocked check forever while reporting a plausible story.
3. **The `A3-*` rows are split by accountability** (D12). **Consumer** rows — the dialog sources its
   items from `eligibleLocations`, does **not** call `/location/detailView`, and does **not** re-derive
   predicates in JS — are asserted against 2643's own files. **Contract** rows run only once the endpoint
   exists, *whoever* shipped it. **2643 does not assert the shape of constructs it did not write**, which
   is the only honest posture once D-D is handed to 2732.

### 13.1 The ticket's 12 acceptance criteria — reachability

| AC | Ticket wording (abridged) | Repo | Test lane | Phase | Reachability |
|---|---|---|---|---|---|
| **1** | WMS V2 displays the Default Putaway Location on the SKU | api + ui | Java (`ItemdataServiceUnitTest`) + Jest (`skuData.spec.js`) | A1, B1 / A2, B2 | 🟡 **PARTLY REACHABLE NOW.** The name already displays (`skuData.vue:142`, `skuInfo.vue:104`); adding the **id** needs no 2732. Showing the **effective/inherited** value is **blocked on 2732 Phase 1-API** |
| **2** | Authorized users can select a valid warehouse location through the UI | api + ui | Jest (`editSkuPutawayDialog.spec.js`, `skuData.spec.js` store) + manual **M4** | B2 | ❌ **blocked on 2732 Phase 1-API** (`PUT /putawayConfig/sku/{id}`) **and Phase 2-UI** (`LocationPicker.vue`) |
| **3** | Location selector is searchable and displays meaningful location information | ui | Jest | A3, B2 | ❌ **blocked on 2732 Phase 2-UI** + A3. ⚠ **Reinterpreted:** the ticket's `CODE — Human Name` pair does not exist — `Location` has **no code column**. Rendered as `locationName — areaName` (§3.9) |
| **4** | Users can clear an alternate location and return to standard Putaway Lane behavior | api + ui | Java (2732's `setSkuDestination(item, null)`) + Jest (`clearOmitsLocationIdEntirely`) + manual **M5** | B2 | ❌ **HARD-BLOCKED on `V2.2.11 DROP NOT NULL`** — `itemdata.putawaylocation_id` is `NOT NULL` in DB *and* `@NotNull` at `Itemdata.java:49`. **The single most blocking AC**, and it needs `V2.2.11` **applied**, not merely merged |
| **5** | Saved values persist after refresh and reopening the SKU | ui | Jest partly + manual **M11** | B2 | ❌ depends on AC2. ⚠ `masterData.skuData` **is** persisted to `localStorage['vuex-web']` (F3) — the overlay is safe because `skuData.vue:304` always refetches, and D5's no-column decision removes the stale-row path |
| **6** | Only valid, active, stock-compatible locations can be selected | api + ui | Java (`PutawayConfigControllerUnitTest` eligible/not-offered partition) + Jest | A3, B2 | ❌ **blocked on 2732's `PutawayDestinationValidator`.** ⚠ **Reinterpreted twice:** "active" has **no column** → `entityLock == NOT_LOCKED` (P2.2); "shipping lane" has no flag → nearest is `gate` (§3.9). ✅ **r2: this AC is now met WITHOUT divergence** — D1 reversed, so "only valid locations can be selected" is literally true: the picker offers the 92 that pass every predicate, P2.7(c) included. ⚠ **The cost is scope, and it is stated in the UI:** the ticket's own worked example (a flowbin) is not among them until SBDEV-2821 (§3.8.2a) |
| **7** | Locations are scoped to the applicable warehouse/facility | api | **none needed** | — | ✅ **ALREADY TRUE.** One DB per facility (2732 §2.4); every read is facility-scoped by the tenant datasource. **Asserted as an invariant (D4) — nothing is built for it** |
| **8** | Invalid or inactive existing configurations are surfaced safely | api + ui | Java (`shouldHandleMissingOptionalReferences` rewritten; `incompatibleConfigCarriesWarning`) + Jest | A1, A2, B2 | 🟡 **PARTLY REACHABLE NOW.** A1's unconditional id makes "invalid" *distinguishable* today (§3.3) — before it, `ItemdataServiceUnitTest:498` **enforced** the ambiguity. The `compatible`/`warning` half is **blocked on 2732 Phase 1-API** |
| **9** | Changes are recorded in an audit or activity log | api | Java (2732's `PutawayConfigAuditService.record`) + manual **M4**, **M13** | B2 | ❌ **HARD-BLOCKED on `putaway_config_audit`** (DB: 0 such tables). 2732 N11 + `V2.2.11`. **Verify 2732's table carries all six required fields** — SKU, facility, previous, new, user, timestamp |
| **10** | System SKUs, including ice packs, support this configuration | api | Java (a System-client SKU writes) + manual | B2 | ❌ depends on AC2. ⚠ **Q10 + Q11 OPEN** — no Ice Pack SKU exists on hydra DEV, and whether HMG has a `cl_nr='System'` row is unverified (PRD has `client_id = 0`) |
| **11** | Client-owned SKUs also support the configuration where applicable | api | Java + manual **M4** | B2 | ❌ depends on AC2. **Plentiful subjects:** all 2,720 SKUs on hydra DEV are client-owned |
| **12** | Automated tests cover viewing, setting, changing, clearing, invalid-location validation, and **permission enforcement** | both | Java + Jest for 5 of 6 verbs; **MANUAL-ONLY for permission enforcement** | A0…B2 | ❌ **and one clause is not automatable.** ⚠ **F2:** `BaseControllerUnitTest.java:52-58` uses `standaloneSetup` — no security filter chain, no method-security advisor — so `@PreAuthorize` is **never evaluated**; the `@SpringBootTest` lane is down (**SBDEV-2217**). ⚠ **F1:** the annotation itself is broken, and **r2 moves the FIX out of 2643's scope** — §5.1 row 0e makes *"2732 must not merge with `Authority.IS_SB_ADMIN`"* a blocking prerequisite owned by 2732's review or SBDEV-2863. **Consequence, stated plainly: AC12 is not 2643's to close alone.** 2643 supplies the **detector** (A0's SpEL-evaluation test), the finding, and manual **M8**; someone else must supply the working annotation. Base class is **`BaseControllerUnitTest`**, not `BaseControllerTest` (C6) |

**Summary: of 12 ACs — 1 is already satisfied (AC7), 2 are partly reachable today (AC1's id half,
AC8's distinguishability half), 9 are blocked on 2732 Phase 1-API. Two are hard-blocked on `V2.2.11`
specifically (AC4 on `DROP NOT NULL`, AC9 on `putaway_config_audit`). Three require documented
reinterpretation of ticket language against columns that do not exist (AC3 "location code", AC6
"active" and "shipping lane"). One (AC12's permission-enforcement clause) cannot be automated at all in
the available lanes.**

---

## 14. Design principles

> **r2 adds this section (MUST-7).** r1 was reviewed against five principles it never stated anywhere —
> so a reviewer could not audit the plan against them, and the author could not notice when one was being
> traded away. **Principle 3 is the one r1 failed, and failing it silently is what produced the D1
> reversal.** Each principle names where it is enforced and where it is currently strained.

| # | Principle | What it means here | Enforced by | Status in r2 |
|---|---|---|---|---|
| **1** | **Thin consumer with a hard boundary** | 2643 builds the operator surface and the one API gap 2732 does not fill. It does **not** repair, extend or re-annotate 2732's code, however tempting the one-line fix | §4's "files 2643 writes into that 2732 owns: **zero** in the plan of record"; D13 (own the facade file); D12 (hand D-D over); §5.1 row 0e (the `@PreAuthorize` swap is not 2643's); verify `A2-neg-2732f` | ✅ **restored.** r1 violated it four times — a method into 2732's facade, a security-annotation swap in two more of its files, and `blockingReason`/`advisory` mutations. The boundary was asserted in prose and breached in §4 |
| **2** | **One source of truth for predicates** | Eligibility is decided **once**, server-side, by 2732's `PutawayDestinationValidator`. Vue never re-derives a predicate, and 2643 never adds a competing classification | D3 / §9.3; verify `A3-neg-view` (`getLocationView` not widened), `A3-neg-pred` (no predicate names in the dialog), `B2-neg-dv`; `@select` emitting the full row (§3.8.2b) so the caller never recomputes | ✅ **honoured, and r2 closed the one leak.** r1 added a 2643-specific `advisory` field and a `PICK_FACE` value to a 2732 enum — 2643-specific classification inside a 2732 type. Both deleted with D1's reversal |
| **3** | **Divergence documented, never silent** | If 2643 departs from 2732, it says so, in the plan and in the UI. **And the departure must be described against what 2732 actually says** — a divergence documented against a misread contract is a *silent* divergence wearing a label | §9.1 (the rejected option, with 2732 line cites); §10.3 C10 (2732's self-contradiction, recorded rather than propagated); §3's `CONTRACT-PROVISIONAL` banner | ⚠ **r2 reframes this to a DEFERRAL rather than a divergence — there is no longer a divergence to document.** r1 documented D1 at length across §1.4, §9.1, §10.1 and PM3 — exemplary in form — but got its **mechanism** wrong: it asserted the write succeeded when 2732 422s it, and cited neither 2732 **Q9** (`:2561`) nor `:2308`(i)'s absolute deadlock prerequisite. **r2's D1 defers to SBDEV-2821 instead of diverging**, and cites both |
| **4** | **Legible failure over hidden failure** | An operator must always be able to tell *what* went wrong and *why*. A capability that is absent must say it is absent and name what will restore it | §3.8.2a's always-visible scope banner + empty state (naming SBDEV-2821 and 2732 Q9); M2 (confirm the hazard before confirming the fix); §7.7's **log-based** `40P01` detector, because `/receiving/receive` returns 200-with-`errors`; the CORS `reset()` vs `resetBuffer()` landmine carried with M6; §5.1 row 3 (a wrong `APP_ADMIN_GROUP` is a *visible* failure, not a silent hole) | ✅ **honoured, and it is what r2's D1 costs money to preserve.** Removing 511 rows creates a new silent failure — "the search is broken" — so the banner is a **deliverable with three verify rows**, not a nicety |
| **5** | **A green signal must be earnable** | The verify script must be capable of going red. SKIP is not PASS, a missing file is not "absent construct", and a check must fail on the pre-fix tree | Every helper opens `[ -f "$2" ] || return 1`; `skip()` is counted separately and §8.4 requires **0 SKIP**; the SELF-TEST block; the documented false-positive at the pencil check; R10 | ✅ **honoured, and hardened in r2.** The 2732 gate now greps class declarations and escalates SKIP→FAIL on a merge (SHOULD-8); `A2-env`, `B2-jest4` and `B1-jest2` were strengthened from checks weaker than their own names (SHOULD-10) |

**The tension these five do not resolve, left visible on purpose.** Principle 2 (one source of truth)
and principle 1 (thin consumer with a hard boundary) pull against each other: server-side evaluation in
2732's validator is what prevents semantic divergence, and it is also what makes every 2643 deliverable
touch 2732's world. r2 reduces the *textual* coupling to zero in the plan of record (D12, D13, row 0e),
but `Resolution`, `Source` and `PutawayScope` remain 2732 types wherever the code lives. **The residue is
temporal, not architectural** — see §11.0's closing note.

---

## 15. Revision log

### r4 — 2026-08-09 (this revision) — BODY RECONCILED TO r3

r3 reversed D1 in its banner but **left the body asserting r2 in five places**. Anything downstream of this
plan — a TDD gate above all — would have read the body, not the banner, and encoded the abandoned design.

| # | What was still asserting r2 | Now |
|---|---|---|
| **1** | §7 test **`eligibleLocationsNeverOffersPickFace`** — *"a `useforpicking`-area location is **not offered**, ever — P2.7(c) is absolute"*, mirroring 2732's `skuWriteRejectsPickFaceDestination` at `:2211` | **INVERTED** to `eligibleLocationsOffersPickFaces`. **This was the single most dangerous row in the plan:** a gate run would have made "never offer a pick face" a contract the executor may not weaken — the exact opposite of r3. The mirrored 2732 test was **deleted** 2026-08-08 and `:2211` no longer resolves |
| **2** | §7 test **`eligibleLocationsNeverRelaxesFixAssigned`** — *"a fix-assigned location is not offered, ever — P2.5 is absolute"* | **REWRITTEN** to `eligibleLocationsExcludesFlowbinAssignedToAnotherSku`. P2.5's absolute reject is dropped; a SKU pointed at **its own** pick face is the intent. Paired with a positive test so "exclude everything fix-assigned" cannot pass |
| **3** | **M10** — manual test instructing the tester to confirm the picker returns **no** flowbins and the API returns **422** | **REWRITTEN** — the picker DOES return flowbins, the write SUCCEEDS, and a foreign-bound flowbin is excluded. The r2 row could never pass against a correct implementation |
| **4** | **§10.1 D1** — still headed *"REVERSED IN r2 … pick faces are NOT selectable"* | **REWRITTEN as r3's**, r2 text struck through and retained |
| **5** | **frontmatter `db_verified_note`** — closed with *"2643 therefore offers only the 92 eligible locations"*, the first conclusion any reader hits | **REWRITTEN**, r2 struck through, r3's conclusion stated first |

**Also folded in — two things that postdate r3:**

- **2732 gained P2.7 rule (f)** (2026-08-09 review). Tier 1 is exempt from rule (e) but **not** from (f): a
  flowbin fix-assigned to a **different** SKU must not be offered. **1,344 of 2,555 candidate rows on
  `wms2-wineco-dev` (53%)**, 154 of 603 on `wms2-hydra-dev2`. Consequences: the exclusion set is **never
  empty**, so r3's *"on HMG production the exclusion set is empty"* no longer holds; and `blockingReason`
  needs an own-vs-foreign distinction, which is **2732's enum to extend** (MUST-4).
- **2732's P1 skip narrowed** to `sltname == 'flowbin'` only. Does not change this plan's dependency —
  `ICE PACK` is a flowbin — but the wider `useforpicking OR flowbin` form must not be restated here.

**Dependency cleared:** SBDEV-2821 **merged to `develop` 2026-08-09** (PR #135, merge `fd90487`). Putaway can
now surface a configured destination, which is what r2's deferral was waiting on.

**Not addressed by r4:** this plan is still `draft` and still blocked on 2732's Phase-1 API, which is itself
blocked on Q12 sign-off. r4 is a consistency pass, not an approval.

### r3 — 2026-08-07

Driven by the **Critic pass (verdict ITERATE — 2 BLOCKING, 7 non-blocking)**, plus three integrity
defects found by direct inspection of r2's artefacts. Every r2 defect was the **same class**: the
changelog claimed work that was not in the code. That is worth naming, because this plan's whole premise
is that a claim must be machine-checkable.

| # | Change | Driver | Where |
|---|---|---|---|
| **1** | **Scope-banner counts de-hard-coded.** `92` / `666` are measurements of `wh01_hydra_v2` on 2026-08-07; a banner asserting them to an operator whose warehouse has neither is *confidently wrong* — a worse failure than the silent one the banner exists to prevent, and an inversion of §14 principle 4. Now `{eligibleCount}` / `{totalCount}`, computed from the `eligibleLocations` response (reading a server verdict, so principle 2 is untouched). New verify row **`B2-banner3`** + Jest `scopeBannerCountIsComputedNotLiteral` | **Critic F-1 (BLOCKING)** | §3.8.2a, script `B2-banner3` |
| **2** | **`Q3`, `Q4`, `Q7`, `Q8` defined.** Cited ~20 times, defined nowhere — the same defect as r1's missing `R<n>` register, in the adjacent namespace. §10.4 rows are now numbered `Q3`/`Q4`/`Q7`/`Q8` + `Q13`–`Q18`. **No `Q1`** (promoted to D1); `Q5` struck. 2732's own questions are always written *"2732's Qn"* — and the first draft of this fix reused `Q9`, colliding with 2732's Q9 in the banner copy, so that row became `Q13` | **Critic F-2 (BLOCKING)** | §10.4 |
| **3** | **Drift probe unwindowed.** My own SHOULD-8 fix carried `-50`, which made it expire silently ~29 days after 2732's merge (192 merges on `develop`; the 50th-most-recent is 2026-07-09) — deferring the fail-quiet rather than closing it, while R10 and §15 called it closed | **Critic F-3** | script `git_has_2732_merge`, §11.0 R10 |
| **4** | **`B2-jest4` comment hole closed** — requires a matcher *call* and forbids an intervening `//`. ⚠ The first attempt used a bare `(?!//)`, which **terminates perl's `m/.../` delimiter**, so the check could never pass. Caught by negative-testing; a check that cannot pass is worse than one that cannot fail | **Critic F-4** | script `check_B2_jest_store_asserts_no_legacy` |
| **5** | **`receivingForm.vue` citations corrected in 6 places.** Constants are `:221-222` (not `:216-217`), comment `:215-220` (not `:210-215`), `isPutawayDestinationApplied` `:296-300`, `isPutawayOverride` `:301-305`, `putawayDisplay` `:309-314`. B1's deliverable pointed an implementer at prose. §10.3 grades this exact defect class in 2732 as HIGH (C4) — the standard must survive contact with this document | **Critic F-5** | §0.3 row 73, §3.7, §4, §6 |
| **6** | r1 remnants removed: M4's dead *"(non-advisory)"* parenthetical; `check_A3_test_three_classes` → `check_A3_test_two_classes` | **Critic F-6** | §7.5 M4, script |
| **7** | Stale **"44 checks"** replaced with *"every 2732-blocked check"* — r1 skipped 44, r2 skips 51, and the number moves with every added check | **Critic F-7** | §11.0 R10, PM1, §13, §15 |
| **8** | Script header `:27` now names `SkuPutawayQueryServiceUnitTest` (the one place SHOULD-9 had not landed) | **Critic F-8** | script header |
| **8b** | **`A3-t1` strengthened.** Was a bare substring grep for `eligibleLocations` under the label *"controller test covers eligibleLocations"* — satisfied by an import or a comment. §13 claims CONTRACT-side rows *"assert properties any correct implementation must have"*, and a substring is not one. Now requires the named §7.1 method `eligibleLocationsSkuScopeTwoClasses`. A fallback-only row (D12 hands D-D to 2732) that cannot fail is still worthless | **Critic F-9** | script `check_A3_test_two_classes` |
| **9** | **Three r2 integrity defects fixed by direct inspection**, all "changelog ≠ code": (a) `A0-swap` / advisory-banner check *functions* were deleted per MUST-5 but their `run` call sites survived — `command not found` the moment 2732 merged; (b) the drift probe matched any commit *citing* 2732 (4 real matches: `89de3f0`, `b623561`, `a991c9e`, `a2bd0e9`), escalating 73 correct SKIPs to FAIL — the detector became the false signal it exists to prevent; (c) `X-2732-authz`, `A2-neg-badconst`, `B2-banner`, `B2-banner2` were listed as ADDED in the header but existed only as comments | direct inspection | script |

**Verify state after r3:** `bash -n` clean; **zero** dangling call sites, **zero** orphan definitions, **zero**
duplicate `run` wirings; baseline **13 pass / 24 fail / 51 skip**, exit 1. `B2-banner3` and the tightened
`B2-jest4` were negative-tested in both directions (fail on the defect, pass on a correct
implementation, fail on a missing file).

> ⚠ **The r2 rows below are HISTORY, not the current design.** r3 re-reversed D1 and r4 reconciled the body to it. A row here saying *"pick faces are not selectable"* records what r2 decided on 2026-08-07 — it is **not** an instruction.

### r2 — 2026-08-07

Driven by the Architect review (SOUND-WITH-CHANGES, 13 required changes) and by the user's **reversal of
D1**. Every row names what changed and what drove it.

| # | Change | Driver | Where |
|---|---|---|---|
| **★1** | **D1 REVERSED.** The picker offers only the 92 eligible locations; **pick faces are not selectable**. Reframed from *"deliberate documented divergence"* to **correct sequencing** — 2732 `:722` already assigns tier-1 pick-face relaxation to SBDEV-2821. The *"an operator can save a configuration that later fails at receive"* residual-risk framing is **deleted as false**: a SKU-scope pick-face write is an unconditional 422 (`:722`, `:792-795`, enforced by `skuWriteRejectsPickFaceDestination` at `:2211`) | **User decision**, on Architect MUST-1. r1 would have shipped ~511 rows whose selection cannot be saved — two dead ends instead of one | §1.4, §3.5, §9.1, §9.2, §10.1 D1, §11.1 PM3, §13.1 AC6, M10, frontmatter `db_verified_note` |
| **★2** | **M10 rewritten.** r1 asserted *"the picker **offers** it… the write **succeeds**"* — **false, and the row could never pass.** r2 asserts the picker does **not** offer pick faces and that a curl'd pick-face write **422s** | same | §7.5 M10 |
| **★3** | **Scope banner added as a deliverable.** Always visible above the picker, plus a matching empty state, naming **SBDEV-2821** and **SBDEV-2732 Q9** and stating the eligible count — so an operator who cannot find their location learns *why* rather than concluding the search is broken | same (preserves principle 4, which the reversal would otherwise have cost) | §3.8.2a, §4, §7.2, §5.7, PM3; verify `B2-banner`, `B2-banner2` |
| **★4** | **D1's apparatus deleted:** the 2643-specific `advisory` field on a 2732 type, the `PICK_FACE` addition to 2732's `blockingReason` enum, and the "receiving not yet supported" per-row warning. **The storage-location lock-contention warning is KEPT** — that hazard is real and 2732 `:1607` requires it | same; **also resolves MUST-4** (these were the two undeclared 2732-file mutations missing from §4) | §3.5, §4, §7.1, §7.2; the old `A3-advis` row is **deleted** and replaced by `A3-neg-advis` / `B2-neg-advis`, which assert the apparatus is *gone* |
| **★5** | **No deadlock-retry prerequisite is inherited**, stated explicitly so nobody re-adds it. That price applied only to r1's D1, which did what 2732 Q9 declines | same | §5.1 **row 9**, §7.4 row 8 |
| **★6** | **2732 Q9 (`:2561`) and §7.6 row 8(i) (`:2308`) now cited** — as the reason r1's approach was rejected | **MUST-2**, satisfied by rejection rather than by pricing | §9.1, §10.1 D1, §5.1 row 9 |
| **★7** | **§10.3 gains C10** — 2732's Q12 (`:2558`) independently reaches r2's conclusion for the *club* case: wineco's `Club01`–`Club08` are live multi-SKU pick faces (`useforpicking = TRUE`, all lane flags FALSE), so 2732's own named tier-2 scenario is **also** blocked by P2.7(c) | user instruction + **SHOULD-13** | §10.3 C10, §10.4 |
| **8** | **§3.2, §3.4, §3.5 marked `CONTRACT-PROVISIONAL`**, with a blocking banner at the head of §3. §5.9's re-verify bullet promoted to that banner | **MUST-3** — 2732 is `draft` and 2732's own D18 (`:103-106`) records changed validator semantics with no independent pass and a prior CRITICAL finding | §3 head, §3.2, §3.4, §3.5, §5.9 |
| **9** | **A0's constant swap removed from 2643's scope.** The **detector stays** (highest-value near-term artefact); the swap becomes §5.1 row 0e, owned by 2732's review or SBDEV-2863. The two `A0-swap*` verify rows are deleted and replaced by a **prerequisite probe** (`X-2732-authz`) and a consumer negative (`A2-neg-badconst`) | **MUST-5** — a 2643 PR reverting a security annotation that 2732 deliberately writes in 2732's own file is the wrong home | §3.1, §4, §5.1 row 0e, §5.2, §5.4, §8, §8.2, §10.1 D2, §13.1 AC12, M8 |
| **10** | **§11.0 risk register added**, defining **R1–R10** with severity, mitigation and the r2 delta for each. Every `R<n>` citation now resolves | **MUST-6** — r1 cited R1/R2/R4/R5 seven times as "(§11)" and defined none | §11.0; refs at §1.3, §3.2, §3.4, §5.3, §5.4, §5.9, §6.1, §9.4 |
| **11** | **§14 design principles added** — five, with enforcement points and honest status. Principle 3 reworded to cover a *deferral* rather than a divergence | **MUST-7** | §14 |
| **12** | **Verify script's 2732 gate hardened** — greps class declarations instead of `[ -f ]`, and escalates **SKIP → FAIL** once a SBDEV-2732 **merge commit** is on `origin/develop` (branch-name match on merge commits only, unwindowed — a bare `--grep` matched 4 commits that merely cite 2732, and a `-50` window expires ~29 days after the merge). The header's *"tests for the CONSTRUCTS"* claim is now true of the code beneath it | **SHOULD-8** — a renamed-on-merge facade must not SKIP every 2732-blocked check forever | script `:187-`, §13 |
| **13** | **`describeForSku` moved into a 2643-owned `service/SkuPutawayQueryService.java`** (D13). Same transaction boundary, injecting 2732's resolver directly — the `MANDATORY` rule needs *a* transactional bean, not *2732's* bean. Test renamed to `SkuPutawayQueryServiceUnitTest` | **SHOULD-9** — drops the cross-plan write surface and de-risks R1/PM1 | §0.1 row 7, §3.2, §3.4, §4, §5.4, §7.1, §11.0 R1, PM1; verify `A2-facade`, `A2-tx`, `A2-fsvc`, new `A2-neg-2732f` |
| **14** | **Three weak checks strengthened.** `A2-env` asserted 4 fields under a "7-field" name → now asserts all 7. `B2-jest4` was a bare substring grep that passed if the spec asserted the opposite → now requires the `.not.`-first form. `B1-jest2` grepped for `disabled`, which any Vuetify spec contains → now anchored to `isPutawayConfigAdmin` + `.exists()` + `.attributes('disabled')`. **The required assertion forms are specified in §7.2 so they are writable, not guessable** | **SHOULD-10** | script; §7.2 |
| **15** | **`B1-pre` is now a HARD PREREQUISITE of A1**, not a "safe trick"/"prefer that ordering". **M2 reframed** as a local pre-`B1-pre` *observation*, not a deliberate deploy of a known cosmetic defect to a DEV that auto-deploys on push | **SHOULD-11** | §5.1 row 4, §5.3, §5.8, §6.1, §8 step 2, §8.2, M2 |
| **16** | **Q6's picker contract promoted to a written spec** (§3.8.2b) and handed to 2732, with a §5.1 row 0b acceptance item (D14). **C7 upgraded from "UNVERIFIED" to CONFIRMED WRONG** with real coordinates: `createBol.vue:100-130` is plain `v-text-field`s; the file's only `v-autocomplete` is at **`:68-76`**; `grep -n Lookup` returns **nothing** | **SHOULD-12** | §3.8.2b, §5.1 row 0b, §10.2 Q6, §10.3 C7 |
| **17** | **D-D specified fully but HANDED TO 2732** (D12), with A3 as a named fallback and a decision deadline before A3's TDD gate. **The 8 `A3-*` verify rows re-scoped** from *producer* to *consumer* assertions plus contract rows that run whoever ships the endpoint | Architect **Q3** recommendation | §3.5 ownership box, §5.1 row 0d, §5.5, §8, §10.1 D12, §10.2 Q5, §13; script's A3 block |
| **18** | Housekeeping: D11's stray "(Q9)" tag removed (it collided with **2732's** Q9, which D1 now cites); §12 gains rows 12–14; §8.4 gains closure conditions 5–6; frontmatter gains `revision: 2` | consistency pass | throughout |

**What r2 deliberately did NOT do**

- **Did not build a 2643-owned SKU-scope validator** (Architect option C). It would duplicate six
  safety-critical predicates and violate §14 principle 2 and D3's entire rationale. Explicitly rejected
  in §9.1.
- **Did not raise a change request against 2732's P2.7(c)** (Architect option A). It is the right *target
  state* and 2732 already owns it as SBDEV-2821 — but it is gated on the deadlock-retry ticket
  (`:2308`(i)), so the near-term outcome would be identical to r2's while adding a negotiation. Recorded
  in §9.1 ground 3.
- **Did not split the document** into "ships this week" / "asked of 2732" as separate files (Architect
  synthesis point 2). The same information is now carried by §3's banner, §4's zero-2732-files statement,
  D12/D13/row 0e and §5.8's honest read — without fragmenting a plan whose value is in its §0 and §2
  cross-references.
- **Did not re-measure the DB.** Every number in §2 is unchanged and was verified SELECT-only on
  2026-08-07; the reversal changes what the 92/511/154 split *means for the design*, not the split.

### r1 — 2026-08-07

Initial draft, written from a verified analysis bundle. Repos read at `wms2-api` `6bc709a` /
`wms2-web-ui` `4ce39a1`. DB measured SELECT-only on `wms2-hydra-dev2`. Reviewed by the Architect lane,
which returned **SOUND-WITH-CHANGES** with 7 MUST and 6 SHOULD changes — all applied above.

---

## 16. Notes

- **Recommended OMC composition.** Size class **Large** (2 repos, 6 phases, cross-subsystem, security
  work, a deliberate divergence from a sibling plan's contract). Pre-draft: `analyst` + `planner`
  (done — this document). Plan review: **`critic`** — mandatory, and it should specifically pressure-test
  **D1** and §10.3's corrections to 2732. Implementation: **`ralph`** per phase, with the verify script's
  exit code as the loop condition. Verification: verify-script + `verifier` (always). Code review:
  **`code-reviewer`** — mandatory at Large. Commits: `git-master` (6 logical commits across 2 repos).
- **Do not single-shot this.** The over-claim failure mode is structurally prevented only by
  ralph + verify-script-as-exit. Phase A2 still depends on another plan's unwritten **types** (§11.1 PM1)
  — though r2's D13 downgrades that from a file-level dependency to a compile-time one.
- **Re-read 2732's merged PR before A2's TDD gate writes a single test** (R5, §11.0, and §3's blocking
  banner). Its §12 changelog shows P2.5 flipped and reverted the same day, and P2.7(c) gaining an
  implementable predicate only on 2026-08-06. Every contract in §3 is on unwritten code.
- **Send §10.3 to 2732's author** as a standalone note. **Two matter most: C4** — 2732 §0.2 row 45, the
  row that scopes this entire ticket, has both the wrong path and the wrong line range — **and C10**,
  which is not a citation defect at all: 2732's front matter (`:114-119`) claims a tier-1 P2.7(c)
  exemption its own body reverted (`:792-795`), and 2732 §3.11.2 `:1605` mandates a picker whose filter offers
  **511 of 666** locations that `:722`'s validator then rejects. **2732's own Phase-2 picker is
  unimplementable as specified**, and 2643's §2.2 measurement is the first evidence of it.
- **Related tickets:** SBDEV-1938 (parent), SBDEV-2642 (v1 sibling, zero commits, superseded),
  SBDEV-2731 (MERGED — the display precedent and the wording constants), SBDEV-2732 (the blocking
  parent), SBDEV-2796 (bounds are advisory for receiving), SBDEV-2821 (pick-face receiving — the ticket
  D1's warning names), SBDEV-2863 (`Authority.IS_SB_ADMIN`), SBDEV-2217 (the dead IT lane).
- **Document history.** See **§15**. r1 2026-08-07 (initial draft); **r2 2026-08-07** (D1 reversed, plus
  the Architect lane's 7 MUST + 6 SHOULD changes). Repos read at `wms2-api` `6bc709a` / `wms2-web-ui`
  `4ce39a1`. DB measured SELECT-only on `wms2-hydra-dev2`. **Still open after r2: Q2, Q10, Q11**
  (Q5 → D12, Q6 → D14). **The decision most in need of requester confirmation is no longer D1 itself —
  it is §3.8.2a's banner wording**, because that is the sentence Scott Dalton reads when the ICE PACK
  location is not in the list.
