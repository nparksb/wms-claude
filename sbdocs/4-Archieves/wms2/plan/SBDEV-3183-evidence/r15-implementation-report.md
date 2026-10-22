---
title: SBDEV-3183 r15 — implementation report (rules for the swept read-only SDR types)
date: 2026-10-20
ticket: SBDEV-3183
kind: evidence (implementation lane report)
worktree: .claude/worktrees/wms2-api/SBDEV-3183-r15
branch: feature/SBDEV-3183-rules-needs-gating-15
base: origin/develop a49e6ebd
commits: 6c2a39ef, 832ab872, 38a1c1ac; review fix round 5d4ebac5, 8d78c58a, 29814e05, a26f926f, 08212401, f91548a3 (not pushed, no PR)
---

# SBDEV-3183 r15: implementation report

## Deviation from the brief: 15 types, not 16. Result is 26 ruled / 9 unruled, not 27 / 8

> **Superseded 2026-10-21 by the review fix round:** Nam decided to rule Pickingorder (`f91548a3`). The boot line now reads `35 exported domain type(s), 27 ruled, 8 unruled`, Unruled = exactly the 8 rail types. The text below records the state at `38a1c1ac`.

The brief said "16 types" and asked for a Row-5 comment reading "27 ruled; 35 − 27 = 8 unruled". Its own rule list names **15** types, and so does the sweep (`needs-gating-caller-sweep-2026-10-20.md`, "the 15 still-unruled SDR domain types"). I added the 15 listed rules. I did not invent a 16th.

The previous 24 unruled types split as 15 needs-gating + 8 must-stay-open + **Pickingorder**. `review-docs-and-ticket-2026-10-18.md` line 38 has the same split: "15+8+1 = 24 … Pickingorder Cypress-only". Pickingorder was not in the brief's list, so it stays unruled. The boot log confirms the result:

```
Spring Data REST read guard: 35 exported domain type(s), 26 ruled, 9 unruled. Mode is per-tenant via sysprop WMS2_SDR_READ_GUARD_MODE (absent or unparseable => OFF). Unruled: [Boxtype, Client, Customerorder, CustomerorderBatch, Itemdata, Pickingorder, Section, Shipperid, Stockunit]
```

The Row-5 comment in `SdrFunctionGuard.java` now reads 26 rules, 35 − 26 = 9 unruled. It names the 9 as the 8 rail types plus Pickingorder. **Open decision for Nam:** should Pickingorder get a rule? Its only SDR reader is Cypress.

## What changed

### `src/main/java/net/aim_ai/wms/security/SdrFunctionRules.java`
- Added 12 new ordered constants: `ITEM_UNIT_VIEW`, `LOCATION_AREA_VIEW`, `STORAGE_LOCATION_TYPE_VIEW`, `STOCK_UNIT_LOCK_OVERVIEW_VIEW`, `PRINTER_VIEW`, `PRINTER_BY_TYPE_VIEW`, `RECEIVED_STOCK_OVERVIEW_VIEW`, `REPLENISHMENT_ORDER_VIEW`, `INVENTORY_RECORD_VIEW`, `HANDLING_UNITS_VIEW`, `UNIT_LOAD_RECORD_VIEW`, `UNIT_LOAD_TYPE_VIEW`, `LOCATION_OVERVIEW_VIEW`. Existing `INBOUND_BOL_VIEW` and `STORAGE_LOCATION_VIEW` were reused. All are built with `ordered(...)`, and union order follows the brief.
- Added 15 `rules.put` entries. Each comment cites its caller as a file plus a quoted snippet from the sweep, with no bare line numbers:
  - Goodsreceiptposition → {INBOUND_BOL}
  - Itemunit → {ITEM_UNIT, CASE_TYPE}
  - LocationArea → {AREA, CYCLECOUNT}
  - LocationRack → {STORAGE_LOCATION} (no live caller)
  - LocationType → {STORAGE_LOCATION_TYPE}
  - LockOverviewDtoView and LockOverviewAllDtoView → {STOCK_UNIT_LOCK_OVERVIEW}, with a "RULE BOTH OR NEITHER" note
  - Printer → {PRINTER, USER_MANAGEMENT}
  - ReceivingDtoView → {INBOUND_BOL}
  - Replenishorder → {REPLENISHMENT_ORDER}
  - StockView → {INVENTORY_RECORD}
  - Unitload → {STOCK_UNIT, CONTAINER} (no live UI caller)
  - UnitloadRecord → {UNIT_LOAD_RECORD}
  - UnitloadType → {UNIT_LOAD_TYPE}
  - ViewWarehouseLocationReport → {LOCATION_OVERVIEW}
- Added two overrides:
  - `(Printer, "findByType")` → {PRINTER, INBOUND_BOL, CLIENT, PARCEL_PICKING}
  - `(ReceivingDtoView, "findByKeyword")` → {RECEIVED_STOCK_OVERVIEW}
- Search paths were verified against the repositories before writing:
  - `PrinterRepository`: `@RestResource(path = "findByType", rel = "findByType") List<Printer> findByType(@Param("type") String type)`
  - `ReceivingDtoViewRepository`: `@RestResource(path = "findByKeyword", rel = "findByKeyword") … findByKeyword(@Param("keyword") String keyword, @Param("clientNumber") String clientNumber, Pageable p)`
  - Both match exactly. Boot validation (`SdrSurfaceInventoryContextTest` and `SdrRuleInventoryContextTest`) passes.
- Recorded in comments:
  - **OMS caveat on the Printer override.** OMS's `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT` defaults to `rest/printer/findByType`, which is not SDR. None of oms-laravel-api's tracked env files (`.env.dev`, `.env.uat`, `.env.testing`) set it, checked 2026-10-20. The production env is untracked, so check it before any PRD tenant leaves OFF/SHADOW.
  - **Cypress.** It reads /unitload, /locationArea and the other ruled paths, so its test user must hold STOCK_UNIT or CONTAINER, and AREA or CYCLECOUNT, once its tenant enforces.
  - None of the 15 types is a JPA association target. I grepped `@ManyToOne|@OneToMany|@OneToOne|@ManyToMany` in `model/`: only User, UserRole, UserGroup and OutboxMessage have them. The association note in `SdrFunctionGuard.evaluate` is updated to match.
- The class javadoc now mentions the new overrides.

### `src/main/java/net/aim_ai/wms/security/SdrFunctionGuard.java`
- The association comment now covers AC-2's 3 types plus the sweep's 15.
- Row 5 now reads "11 rules … other 24" → "26 rules … other 9 (8 rail + Pickingorder)", with the arithmetic line "35 − 26 = 9 unruled (measured 2026-10-20 by the boot log)". *(At 38a1c1ac; now 27 / 8, see Review fix round.)*
- I grepped `src/` for other stale "11 ruled", "11 rules", "24 unruled" and "other 24" literals and found none. The dated history lines (e.g. `SdrUncalledSurfaceNotExportedContextTest` "measured 2026-09-23 … unruled=27") are labelled as history and were left alone.

### Tests
- **`SdrFunctionRulesUnitTest`:**
  - `sbdev3183NeedsGatingRules()` (MethodSource) drives `needsGatingTypeRequiresExactlyItsScreenFunctions`. It runs 15 cases, `containsExactlyElementsOf` on the ordered set, with `.as(...)` naming the type.
  - `sbdev3183NeedsGatingOverrides()` drives `needsGatingOverrideRequiresExactlyItsScreenFunctions` (2 cases, exact ordered set, named).
  - `sbdev3183UnoverriddenSearches()` drives `unoverriddenSearchFallsBackToTheTypeRule`. It runs 4 cases: Printer `findByTypeAndProcessdefaultTrue` and `findAllTypeAndProcessdefaultTrue`; ReceivingDtoView `findByAdvicenumber` and `findByAdvicepositionid`.
  - `ruledDomainTypesMatchesTheFullRuleSet` is extended with the 15 types.
  - `OVERRIDE_REPOSITORIES` gains Printer and ReceivingDtoView.
  - `everyOverriddenSearchTakesNoParameters` is renamed to `everyOverriddenSearchTakesNoParametersOrItsReviewedList`; see the next section.
- **`SdrRuleStartupAssertionUnitTest`:** `productionOverridesAreExactlyTheLocationPair` is renamed to `productionOverridesAreExactlyTheLocationPairPrinterAndReceiving` and pins all 4 keys exactly.
- **`SdrFunctionGuardUnitTest`:**
  - `fakeMappings()` gains `printer` and `receivingDtoView`.
  - `searchOverrideReachesAccessService` gains a `repository` column, and its expected sets are `|`-separated and asserted in order with `containsExactly`. Four rows were added: printer findByType (override), printer findByTypeAndProcessdefaultTrue (fallback), receivingDtoView findByKeyword (override), receivingDtoView findByAdvicenumber (fallback).
- **`SdrMustStayOpenRailUnitTest`:** unchanged and passing (10/10).

## The parameterized-override decision (brief item 4)

Both new overrides **take parameters**, so the old zero-parameter assertion would fail by design. I did not weaken it. It is now an explicit, reviewed allow-list, `REVIEWED_OVERRIDE_PARAMETERS`, of type `Map<SearchOverrideKey, List<Class<?>>>`:
- An override **absent** from the map must still take zero parameters. Both Location overrides go through this branch.
- An override **present** in the map must have exactly the pinned parameter-type list (`containsExactlyElementsOf`). Adding, removing or retyping a parameter goes red and names the override.
- A map entry for an override that no longer exists goes red ("remove the entry").

The review recorded per entry (the javadoc on the constant):
- **ReceivingDtoView/findByKeyword(String, String, Pageable).** Both strings only narrow the result. The query's `:keyword IS NULL or :keyword = ''` and `:clientNumber IS NULL OR :clientNumber = ''` arms make "empty" mean all rows. The widest read a holder can make is therefore the full receiving view, which is exactly what the Receiving Report (RECEIVED_STOCK_OVERVIEW) shows. No argument reaches outside it.
- **Printer/findByType(String type). ⚠ This one does not "only narrow".** `type` is a filter, not a scope. A holder can iterate the type values and read **every printer row** (number, name, address, client_id, type, processdefault). In data terms the override grants INBOUND_BOL, CLIENT and PARCEL_PICKING holders read access to all printers, though not the paged collection or the item resource. I recorded it as **accepted for review**, not as "cannot widen":
  - Printer rows are device configuration with no credentials or order data.
  - The MVC siblings already serve printer lists to other function holders: `/inboundPrinters` to CONTAINER, CLUB_LINE and TRANSFER_ORDER; `/outboundTotePrinters` to ORDER_MONITOR.
  - The sweep's alternative, a five-function base union, exposes the same rows plus the item resource.

  **This needs Nam's or a reviewer's explicit yes.** If it is not accepted, the fix is an MVC endpoint, not a narrower SDR rule.

## Verification

### Red first (before production code; tests compiled)
| Class | tests | failures | errors |
|---|---|---|---|
| SdrFunctionRulesUnitTest | 54 | 19 | 4 |
| SdrRuleStartupAssertionUnitTest | 8 | 1 | 0 |
| SdrFunctionGuardUnitTest | 55 | 4 | 0 |
| SdrMustStayOpenRailUnitTest | 10 | 0 | 0 |

Failure messages were the intended ones, e.g. `[StockView must carry a rule (needs-gating caller sweep 2026-10-20)]` and `[Printer/search/findByType must be a production override]`. The 4 errors were `NoSuchElement` in the fallback test, because the base rule was absent. I then added an `isPresent` assertion so that case fails as an assertion rather than an error.

### Green (targeted; counts from `target/surefire-reports` XML)
| Class | tests | failures | errors |
|---|---|---|---|
| SdrFunctionRulesUnitTest | 54 | 0 | 0 |
| SdrRuleStartupAssertionUnitTest | 8 | 0 | 0 |
| SdrFunctionGuardUnitTest | 55 | 0 | 0 |
| SdrMustStayOpenRailUnitTest | 10 | 0 | 0 |
| SdrSurfaceInventoryContextTest | 1 | 0 | 0 |
| SdrRuleInventoryContextTest | 5 | 0 | 0 |

Boot line (SdrRuleStartupCheck): `35 exported domain type(s), 26 ruled, 9 unruled … Unruled: [Boxtype, Client, Customerorder, CustomerorderBatch, Itemdata, Pickingorder, Section, Shipperid, Stockunit]` *(At 38a1c1ac; now 27 ruled / 8 unruled, see Review fix round.)*

### Mutants
Work was committed first. Each mutant was applied by script and restored with `git checkout -- src/main src/test`, and `git status` was clean after each one.

| # | Mutant | Result | Attributable failure message |
|---|---|---|---|
| a | delete `rules.put(StockView…)` | **killed** (2 red) | `needsGatingTypeRequiresExactlyItsScreenFunctions:179 [StockView must carry a rule (needs-gating caller sweep 2026-10-20)]`; also `ruledDomainTypesMatchesTheFullRuleSet` |
| b | Printer/findByType override set → `PRINTER_VIEW` | **killed** (2 red) | `needsGatingOverrideRequiresExactlyItsScreenFunctions:197 [Printer/search/findByType override must be exactly [WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_INBOUND_BOL, WEB_UI_VIEW_CLIENT, WEB_UI_VIEW_PARCEL_PICKING] in this order]`; `SdrFunctionGuardUnitTest.searchOverrideReachesAccessService:312 [printer/search/findByType must be checked against WEB_UI_VIEW_PRINTER\|…\|WEB_UI_VIEW_PARCEL_PICKING]` |
| c | drop LockOverviewAllDtoView only | **killed** (2 red) | `[LockOverviewAllDtoView must carry a rule (needs-gating caller sweep 2026-10-20)]`; `ruledDomainTypesMatchesTheFullRuleSet` |
| d | guard passes `null` as the search path | **killed** (4 red, exactly the 4 override rows) | `[location/search/findByGateTrue must be checked against WEB_UI_VIEW_BILL_OF_LADING]`, `[location/search/getAllCrossDockingLanes …INBOUND_BOL]`, `[printer/search/findByType …]`, `[receivingDtoView/search/findByKeyword must be checked against WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW]` |
| e | override path `findByKeyword` → `findByKeywrod` | **killed**: boot refuses (SdrSurfaceInventoryContextTest 1 error) | `IllegalStateException: Spring Data REST function rules have drifted from the exported surface: [ReceivingDtoView#findByKeywrod (no exported search at that path)]` |
| f (extra) | remove the Printer entry from REVIEWED_OVERRIDE_PARAMETERS | **killed** | `[PrinterRepository.findByType (override Printer/search/findByType) gained a parameter; re-review …]` |
| g (extra) | ReceivingDtoView reviewed list drops `Pageable` | **killed** | `[ReceivingDtoViewRepository.findByKeyword (override ReceivingDtoView/search/findByKeyword) changed its parameter list; the reviewed list … is [class java.lang.String, class java.lang.String] …]` |

Mutant f's message originally said "only if a holder still cannot widen the read", which contradicted the Printer entry's own review. I reworded it in commit `832ab872`.

### PIT
`mvn -o org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.security.SdrFunctionRules -DtargetTests='…SdrFunctionRulesUnitTest,…SdrRuleStartupAssertionUnitTest'` after `mvn -o -q test-compile`:
- **Generated 11, killed 11 (100%)**, no coverage 0, test strength 100%.
- Line coverage on the mutated class: 72/73.
- PIT's default mutators do not remove non-void `Map.put` calls, so rule deletion is covered by hand mutants a and c, not by PIT.

### Full suite
38a1c1ac: `mvn -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` → unit 8535/0/0/1, IT 938/0/0/23, BUILD SUCCESS (2026-10-21). Baseline #546 merge: 8510/0/0/1, 938/0/0/23 — same failure set (none); +25 unit = new parameterized cases. CustomerorderForceCancelOutboxIntegrationTest 2/2.

The review fix round commits (below) have NOT had a full-suite run yet; only the targeted classes listed there.

## Not done / open
- No push, no PR (per brief).
- No independent review lane was run by this executor. The brief scoped this lane to implementation, and the five-item floor still needs one review pass.
- ~~Open decisions for Nam: (1) accept the Printer/findByType read-all-printers widening, or move it to MVC; (2) whether Pickingorder (Cypress-only) should get a rule;~~ decided 2026-10-21: (1) accepted as built, (2) ruled. Still open: (3) check the PRD OMS env for `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT` before any PRD tenant leaves OFF/SHADOW.

## Review fix round (2026-10-21)

Reviews: `r15-review-code.md` (COMMENT, 1 Medium + 7 Low), `r15-review-security.md` (APPROVE, 6 Low). Plus Nam's two decisions relayed by the coordinator.

| Finding | Fix | Commit |
|---|---|---|
| Code F1 (Medium) | `SdrMustStayOpenRailUnitTest` OMS printer note now says Printer IS ruled since r15 (findByType override → PRINTER/INBOUND_BOL/CLIENT/PARCEL_PICKING). A deployment whose OMS env points `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT` at the v3 SDR path is denied once its tenant enforces. Check the PRD OMS env before any PRD tenant leaves OFF/SHADOW. | `5d4ebac5` |
| Code F2 | Stale counts replaced by the rule (pointer to `SdrRuleStartupCheck`'s boot log and `SdrRuleInventoryContextTest`): `FunctionGuardInterceptor` ("five rules remain"), `RequiresFunction` ("27 as of SBDEV-3471"), `SdrRuleStartupCheckUnitTest` ("30 of 35"). The grep for the old literals found one more copy: `SdrGuardMode` "27 as of SBDEV-3471", now date-stamped "27 when SBDEV-3471 landed, history only". All other hits are dated history lines. | `5d4ebac5` |
| Code F3 + Security L5 | Each `REVIEWED_OVERRIDE_PARAMETERS` entry is now a `ReviewedOverride(parameters, genericReturnType, queryArms)`. Printer/findByType pins `java.util.List<net.aim_ai.wms.model.Printer>` and must stay a derived query (no `@Query`). ReceivingDtoView/findByKeyword pins `org.springframework.data.domain.Page<net.aim_ai.wms.model.ReceivingDtoView>`, a non-native `@Query`, and the fragments `SELECT p FROM ReceivingDtoView p  WHERE `, `:keyword IS NULL` and `:clientNumber IS NULL`. Every message names the override and ends "the recorded review in REVIEWED_OVERRIDE_PARAMETERS no longer holds; re-review what a holder can reach before updating the entry". | `8d78c58a`, `29814e05` |
| Code F4 | `unoverriddenSearchFallsBackToTheTypeRule` first resolves each row on `OVERRIDE_REPOSITORIES` to exactly one exported search. It uses `exportedSearches()`, the stream the override test already used, now extracted so both tests share it. | `8d78c58a` |
| Security L4 | UnitloadType rule comment records the dead caller `store/receiving/createPo.js` `getUnitLoadTypes` (`'/unitloadType'`, not dispatched at web-ui `add0628`). Reviving it needs `WEB_UI_VIEW_INBOUND_BOL` added to the rule. The same note is in `needs-gating-caller-sweep-2026-10-20.md` §14. | `a26f926f` |
| Code F6 | This report: commits and full-suite line. The IT also gains `verify(unitloadRepository).save(argThat(u -> PARCEL_ID equals u.getId()))`, which proves the stubbed save path was the one exercised. | `08212401` |
| Code F5 (Nam: rule it) | `Pickingorder → {WEB_UI_VIEW_PICKING_ORDER}` with a Cypress-grant note, added to `sbdev3183NeedsGatingRules`. That also feeds `ruledDomainTypesMatchesTheFullRuleSet`. The Row-5 comment now reads 27 rules, 35 − 27 = 8 unruled, exactly the 8 rail types. | `f91548a3` |
| Code F7 / Security L1 (Nam: accept) | No change to the override. The rule comment and the `REVIEWED_OVERRIDE_PARAMETERS` javadoc now say "accepted by Nam 2026-10-21 (security review L1, code review F7)". | `f91548a3` |
| L2, L3, L6, F8 | Record-only, per brief. No change. | — |

### Pickingorder caller sweep (before writing the rule)

Case-sensitive `git grep` for the SDR path token `pickingorder` (not adjacent to letters or `_`) and for quote/template-adjacent string-built forms. Exported search names `findByNumber` and `findByStateAndSectionId` were grepped separately, which also catches a path split across lines.

| Repo @ ref | Hits |
|---|---|
| wms2-web-ui `origin/develop` `add0628` | only `cypress/e2e/wms/smoke/phase2-pick.cy.js:97` `'/pickingorder/search/findByNumber?number='` (plus its labels at :100 and :114) |
| wms2-mobile-ui `origin/develop` `f51dc6c` | none. A case-insensitive pass shows only MVC `/picking/releasePickingOrder` and `/picking/resetPickingOrder` |
| oms-laravel-api `origin/develop` `26a301ac` | none in app code. `config/wms.php` has no picking key and no `v3/pickingorder`. Only release-note text mentions it |
| siteboss-frontend `origin/main` `5ae96922` | none |

Only Cypress reads it, so the rule was added. Boot line after the change (`SdrRuleStartupCheck`, in the targeted run): `35 exported domain type(s), 27 ruled, 8 unruled … Unruled: [Boxtype, Client, Customerorder, CustomerorderBatch, Itemdata, Section, Shipperid, Stockunit]`. These are the 8 `SdrMustStayOpenRailUnitTest` entries. Once its tenant enforces, the Cypress test user also needs `WEB_UI_VIEW_PICKING_ORDER`.

### Mutants (fix round; each committed first, then restored with `git checkout -- <file>`)

| # | Mutation | Result |
|---|---|---|
| M1 | `PrinterRepository.findByType` returns `ArrayList<Printer>` | RED `everyOverriddenSearch…`: "PrinterRepository.findByType (override Printer/search/findByType) changed its return type — the recorded review … expected `java.util.List<…Printer>` but was `java.util.ArrayList<…Printer>`" |
| M2 | `findByKeyword` returns `Slice<ReceivingDtoView>` | RED: "ReceivingDtoViewRepository.findByKeyword (override ReceivingDtoView/search/findByKeyword) changed its return type …" |
| M3 | drop `or :keyword IS NULL` | RED: "…'s @Query no longer contains [:keyword IS NULL] — the recorded review …" |
| M4 | drop `OR :clientNumber IS NULL` | RED: "…'s @Query no longer contains [:clientNumber IS NULL] …" |
| M5 | `nativeQuery = true` on findByKeyword | RED: "…'s @Query became native; the review covered a JPQL query over one entity …" (first attempt did not compile without `value =`; rerun with it) |
| M6 | add `@Query(... OR 1=1)` to Printer findByType | RED: "PrinterRepository.findByType … was reviewed as a derived query but now carries an @Query …" |
| M7 | add `JOIN Advice a ON …` after the entity | RED: "…'s @Query no longer contains [SELECT p FROM ReceivingDtoView p  WHERE ] …" |
| M8 | misspell fallback row `findByAdvicenumber` → `findByAdviceNumber` | RED `unoverriddenSearchFallsBackToTheTypeRule[3]`: "fallback row ReceivingDtoView/search/findByAdviceNumber must name exactly one exported search declared on ReceivingDtoViewRepository; zero means the row is misspelled or the search was renamed, re-pathed or withdrawn …" |
| M9 | `exported = false` on `findAllTypeAndProcessdefaultTrue` | RED `[2]`: "fallback row Printer/search/findAllTypeAndProcessdefaultTrue must name exactly one exported search …" |
| M10 | IT fixture parcel id `PARCEL_ID + 1` | RED `forceCancel_commitsOneCancellationRowWithTheOrder`: Mockito "Argument(s) are different! Wanted: unitloadRepository.save(<custom argument matcher>)" |
| M11 | delete `rules.put(Pickingorder…)` | RED ×2: "Pickingorder must carry a rule (needs-gating caller sweep 2026-10-20)" and `ruledDomainTypesMatchesTheFullRuleSet` |

Each was restored, and `git status` was clean afterwards.

Known limit of the F3 pin: it is a fragment check, not a parser. A whitespace-only reformat of the `@Query` also goes red, which is a false red that sends you to re-check. A new narrowing-irrelevant predicate ANDed in stays green, because it only narrows.

### Green (fix round, targeted; counts from `target/surefire-reports` XML at `f91548a3`)

| Class | tests/fail/err/skip |
|---|---|
| SdrFunctionRulesUnitTest | 55/0/0/0 |
| SdrFunctionGuardUnitTest | 55/0/0/0 |
| SdrMustStayOpenRailUnitTest | 10/0/0/0 |
| SdrRuleStartupCheckUnitTest | 10/0/0/0 |
| SdrRuleStartupAssertionUnitTest | 8/0/0/0 |
| SdrRuleInventoryContextTest | 5/0/0/0 |
| SdrSurfaceInventoryContextTest | 1/0/0/0 |
| **Total** | **144/0/0/0** |

`CustomerorderForceCancelOutboxIntegrationTest` (failsafe, `mvn -o -Pci verify -Dit.test=… -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`) at `08212401`: 2/0/0/0, report file written.

## Re-review round (2026-10-21, `r15-rereview.md` R1–R4) — commit `758fb8a9`

Full suite on the previous head `f91548a3`: unit 8536/0/0/1, IT 938/0/0/23, BUILD SUCCESS (same failure set as baseline: none).

| Finding | Fix in `758fb8a9` |
|---|---|
| R1 "pins it" false claim | `FunctionGuardInterceptor`, `RequiresFunction`: "logs it (not asserted)" |
| R2 `@NativeQuery` missed | `assertReviewedShape` uses `AnnotatedElementUtils.findMergedAnnotation` |
| R3 verify() on a spy sees real calls | counter `stubbedParcelSaves` incremented in the stub, asserted positive |
| R4 double-space-sensitive fragments | pin the whitespace-collapsed query prefix `SELECT p FROM ReceivingDtoView p WHERE `; the `IS NULL` arm pins dropped (removing an arm can only narrow) |

Targeted: SdrFunctionRulesUnitTest 55/0/0/0; CustomerorderForceCancelOutboxIntegrationTest 2/0/0/0.

Mutants (all red, attributable):
- `@NativeQuery` on `PrinterRepository.findByType` → "[PrinterRepository.findByType (override Printer/search/findByType) was reviewed as a derived query but now carries an @Query/@NativeQuery …]"
- JOIN in `findByKeyword` → "[ReceivingDtoViewRepository.findByKeyword (…)'s @Query no longer starts [SELECT p FROM ReceivingDtoView p WHERE …]"
- stub counter not incremented → "[control: UnitloadRepository.save must run the stubbed answer (spy stub missing => real save on H2)]"
- Control: whitespace-only reformat of the `@Query` stays green.
- Note on R3's premise: deleting the `doAnswer` stub entirely already fails the IT (`DataIntegrityViolationException: Detached entity with generated id '900' has an uninitialized version value`), so the old verify was not silently green; the counter is kept as the direct proof.

Full suite on `758fb8a9`: unit 8536/0/0/1, IT 938/0/0/23, BUILD SUCCESS.

## Re-review-2 round (`r15-rereview-2.md` N1–N6) — commit `a03b5ad4`

Comment and test-wording only: N1 javadoc reflow; N2–N5 the ReviewedOverride javadoc (real reason the WHERE arms are unpinned, named-query route and after-WHERE subquery disclosed, non-whitespace reformat needs a re-pin); N6 AtomicInteger import, redundant reset dropped, counter message reworded. Targeted on `a03b5ad4`: SdrFunctionRulesUnitTest 55/0/0/0, CustomerorderForceCancelOutboxIntegrationTest 2/0/0/0; counter mutant red with "[control: UnitloadRepository.save must reach the stubbed answer, not the real repository]". No production-code behaviour changed since the `758fb8a9` full suite.
