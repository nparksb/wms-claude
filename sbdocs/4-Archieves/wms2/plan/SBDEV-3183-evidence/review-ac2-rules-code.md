---
title: SBDEV-3183 AC-2 rules — independent code review (e0bb9412)
date: 2026-10-18
lane: code-reviewer (read-only)
commit: e0bb9412 (base origin/develop 5016bb19)
sibling heads: wms2-web-ui add0628 · wms2-mobile-ui f51dc6c · oms-laravel-api 59039e8c (all origin/develop, fetched 2026-10-18)
verdict: APPROVE (one Medium test gap, three Low; no High)
---

# SBDEV-3183 AC-2: review of the rule wiring (e0bb9412)

No Maven or build was run, as the brief asked. All evidence below comes from reading source and from `git grep` against `origin/develop`.

## 1. Rule wiring and override lookup: correct

- `SdrFunctionGuard.evaluate` (around line 264) reads `String searchPath = uriVariable(request, VAR_SEARCH);` and passes it to `rules.requiredFunctions(domainType, searchPath)`. `VAR_SEARCH` is the `{search}` variable of `/{repository}/search/{search}`. It is absent for collection, item and association routes, so those resolve to the type rule.
- `SdrFunctionRules.requiredFunctions(Class, String)` (lines 406-417) returns the override for `new SearchOverrideKey(domainType, searchPath)` when there is one, and otherwise the type rule. The key is a record, so it has value equality.
- The key strings `findByGateTrue` and `getAllCrossDockingLanes` match the `@RestResource(path = …)` values in `LocationRepository.java:98` and `:176` exactly.
- The match is case-sensitive and exact on both sides. SDR resolves a search with `Path.matches` → `this.path.matches(String.format("/?%s", Pattern.quote(reference)))` (spring-data-rest-core 4.5.7 sources). The guard does a `HashMap` lookup on the same decoded `{search}` string. A request whose search name SDR would dispatch therefore always hits the override. If a key ever drifted, the result fails toward the stricter type rule (over-gating), and `SdrRuleStartupCheck.afterSingletonsInstantiated` calls `findUnresolvableOverrides`, which refuses to boot when a key names no exported search. That second path is also pinned at context level by `SdrRuleInventoryContextTest.everyOverrideKeyResolvesToALiveSearch`.
- Association reads resolve the owning type. None of `Advice`, `Cyclecount` or `Location` is the target of a JPA association: the only `@ManyToOne/@OneToMany/...` are in `UserGroup`, `User`, `UserRole` and `OutboxMessage`, and no model has a field of these three types. So no `/{other}/{id}/{property}` path can serve their rows through an unruled owner.
- The four function constants exist in `WmsConstants.java:380/397/408/437`, and the boot check `findUnknownFunctions` guards against typos.

## 2. Over-gating sweep: no defect found

Method: literal path prefixes `['"\`](/v3)?/(advice|cyclecount|location)(['"\`/?]|$)`, every exported search name on the three repositories by bare word, variable-built URLs (`'/' + x + '/search…'`, template literals), HAL `_links` link-following, `cy.wms`, and `v3/(advice|location|cyclecount)`. Each SDR call was traced from the store action, to the component that dispatches it, to the page that imports it, to the gate on that route in `util/appMenuList.js`.

| Caller (wms2-web-ui @ add0628) | Verb / path | Dispatcher → page | Route gate | Rule needs | OK |
|---|---|---|---|---|---|
| `store/receiving/inboundNotices.js:410` saveComment | PATCH `/advice/{id}` | `closedNoticeDescription.vue:242` → `pages/receiving/closedNotice/_id.vue` and `closedNoticeDetails.vue` → `closedNotices.vue` → `pages/receiving/inbound-notices.vue` | EXTRA_ROUTES `/receiving/closedNotice/:id` and menu `/receiving/inbound-notices` = `WEB_UI_VIEW_INBOUND_BOL` | INBOUND_BOL | ✓ |
| `store/receiving/inboundNotices.js:197` deleteOpenInboundNotices | DELETE `/advice/{id}` | `deleteOpenNotices.vue:56`, opened only from `openNotices.vue:31` and `:100`. **Both triggers are inside HTML comments** (`<!-- the following will be activated in later version not in v1.5 -->`), so the call is dead. The verb is also withdrawn (`RestConfiguration.configureAdviceItemVerbWriteExposure` disables PUT and DELETE). | n/a (dead) | INBOUND_BOL | ✓ (see L2) |
| `store/internalOps/cycleCount.js:261` saveComment | PATCH `/cyclecount/{id}` | `plannedCycleCountDescription.vue:92` → `pages/internalOps/cycleCount/planned/_id.vue` | EXTRA_ROUTES `/internalOps/cycleCount/planned/:id` = `WEB_UI_VIEW_CYCLECOUNT` | CYCLECOUNT | ✓ |
| `store/masterData/storageLocation.js:73` deleteStorageLocation | DELETE `/location/{id}` | `storageLocation.vue:321` → `pages/masterData/locationData/storage-locations.vue` | menu = `WEB_UI_VIEW_STORAGE_LOCATION` | STORAGE_LOCATION | ✓ |
| `store/outbound/outboundBols.js:298` getGateDocks | GET `/location/search/findByGateTrue` | `createBol.vue:187` → `openOutboundBol.vue:134` → `pages/outbound/outbound-bol/index.vue` | menu `/outbound/outbound-bol` = `WEB_UI_VIEW_BILL_OF_LADING` | override BILL_OF_LADING | ✓ |
| `store/receiving/inboundNotices.js:212` getAllCrossDockingLanes | GET `/location/search/getAllCrossDockingLanes` | `receiving/open/popups/selectLanePop.vue:78`, imported only by `openNotices.vue:138` (the import is unique across the repo) → `pages/receiving/inbound-notices.vue` | menu = `WEB_UI_VIEW_INBOUND_BOL` | override INBOUND_BOL | ✓ |

Not SDR, checked against the wms2-api controllers:
- `AdviceController @RequestMapping("/v3/advice")` serves `/create`, `/update`, `/setPurchaseOrderNumber`, `/closeInboundBol[/{id}]`, `/acceptHubAndSpokeBol/{id}/{locationId}`, `/fixHubAndSpokePalletIssues`, `/detailView`, `/adviceDetailsById/{id}` and `/exportInboundNotice`.
- `LocationController @RequestMapping("/v3/location")` serves `/detailView`, `/locationDetailsById/{id}`, `/create`, `/update`, `/createLocationType` and `/updateLocationType`.
- Every UI `/advice/...` and `/location/...` subpath maps to one of these. RequestMappingHandlerMapping (order 0) takes precedence over SDR's mapping (LOWEST_PRECEDENCE-100).
- Mobile cycle count uses `/cycleCountLos/*`, a different prefix.
- Aside, pre-existing and not caused by this commit: the UI's `$put('/location/create')`, `$post('/location/update')`, `$put('/location/createLocationType')` and `$post('/location/updateLocationType')` use the opposite verb to the controller. All four store actions have zero dispatchers, so they are dead.

Other repos:
- **wms2-mobile-ui**: no call site for `/advice`, `/cyclecount` or `/location`, whether literal, template or variable-built. The only variable-built SDR URL in either UI is `wms2-web-ui store/reports/lock.js:64`, and its resource is fixed to `lockOverviewDtoView` or `lockOverviewAllDtoView`.
- **oms-laravel-api**: no `v3/advice`, `v3/location` or `v3/cyclecount`. Advice goes through `rest/advice/create*` (the `/rest/**` surface, not SDR) in `config/wms.php:98,125,126`. The only `_links` use is the Client self-href at `WmsApiService.php:4189`.
- **siteboss-frontend**: no `v3/(advice|location|cyclecount)`.
- **Remaining exported searches**: none of the other exported Location searches (`findByName`, `findByAreaId`, `findByStaginglaneTrue`, `findByKeyword`, `getLocationsByAreaName`, `getPickableLocations`, `getStorageLocationsFor{PutAwayItemData,StockUnitItemData}`, `getLocationList`, `getFlowBinHavingNoFixedAssignment`, `findPutawayCandidates`) has an SDR caller in any of the three repos. `getPickableLocations` and `getFlowBinHavingNoFixedAssignment` are called, but on `/replenishOrder/` and `/fixedAssignment/` (MVC). The same holds for any Cyclecount or Advice search.

Cypress (wms2-web-ui) makes SDR calls on these types: PATCH `/advice/{id}` (`wmsHelpers.js:401`), PATCH `/cyclecount/{id}` (`:862`), GET `/location/{id}` (`:273`, `step5-verify-mobile-putaway.cy.js:244`), and GET `/location/search/findByGateTrue` (`wmsHelpers.js:77`, `pick-pack-order.cy.js:415`, `scenario1-hybrid/step5-bol-create.cy.js:69`, `transfer-offsite.cy.js:331`). The last one is missing from the commit's ⚠ note (L1).

**Conclusion:** every reachable SDR caller sits on a route gated on exactly the function its rule or override requires. No mobile caller exists. The OMS does not touch these three types over SDR.

## 3. Claims

- "Only SDR caller found: PATCH /advice/{id}" (SdrFunctionRules comment, and also in the commit message). A DELETE call site exists (`inboundNotices.js:197`). It is dead and the verb is withdrawn, so the conclusion stands, but as worded the claim is literally false. See L2.
- "The four other selectLanePop.vue files … do not call this search" holds: the action has a single dispatch site in the whole repo.
- "The sweep found no UI caller for any of those, but it matched literal '/location/...' paths only and cannot see a URL assembled from a variable" is an honest limit. I ran the variable-built sweep the comment says was not done, and it found nothing.
- "Each function is the one util/appMenuList.js guards the caller's route on, so no UI user who reaches the caller is denied" holds for every caller in the table above.
- Stale zero-override prose that this commit makes false: see L3.
- The dev_wh01_om1 holder counts (43/45/44/46 of 100) were **not re-verified** by this lane, because no DB query was run.
- The arithmetic comment in `SdrFunctionGuard` (35 - 11 = 24) agrees with the commit's boot-line claim. It is runtime-derived and not checked here.

## 4. Test quality

- `SdrFunctionRulesUnitTest` pins each type rule, the fallback for searches without an override (`findByName`), and both overrides, through `requiredFunctions`. `ruledDomainTypes().containsExactlyInAnyOrderElementsOf(allRuled)` would catch a rule that is added or dropped. `productionOverridesAreExactlyTheLocationPair` pins the override key set exactly.
- `Optional<Set>.contains(Set.of(...))` compares with `Set.equals`, so it is correct against the `LinkedHashSet` that `ordered()` builds.
- **Gap (M1):** no test drives an override through `SdrFunctionGuard.evaluate`. The only guard-level search tests (`SdrFunctionGuardUnitTest:228`, `SdrReadGateEnforcementContextTest:77/134`) use `userGroup/search/findByConnectorFalse`, which has no override, so the type rule and the "override" give the same answer. Mutating line 266 to `rules.requiredFunctions(domainType, null)`, or dropping the `uriVariable(request, VAR_SEARCH)` read, would leave every test green. Once a tenant enforces, that mutant would 403 a BOL clerk who lacks `WEB_UI_VIEW_STORAGE_LOCATION` on the gate-dock dropdown. This is the over-gating this commit exists to avoid.

## Findings

| ID | Severity | Confidence | File | Evidence | Fix |
|---|---|---|---|---|---|
| M1 | Medium | HIGH (that no test covers it; I did not see the PIT report) | `src/main/java/net/aim_ai/wms/security/SdrFunctionGuard.java:264-266`; tests `SdrFunctionGuardUnitTest`, `SdrReadGateEnforcementContextTest` | `String searchPath = uriVariable(request, VAR_SEARCH); … rules.requiredFunctions(domainType, searchPath);`. The only guard search test is `uriVariables("repository", "userGroup", "search", "findByConnectorFalse")`, which has no override, so passing `null` instead of `searchPath` is indistinguishable. The first production overrides ship in this commit with no guard-level pin. | In `SdrFunctionGuardUnitTest`, add `uriVariables("repository","location","search","findByGateTrue")` at ENFORCE_RULED, capture the `checkAnyAccess` varargs and assert exactly `{WEB_UI_VIEW_BILL_OF_LADING}`; do the same for `getAllCrossDockingLanes` → `{WEB_UI_VIEW_INBOUND_BOL}`, plus `findByName` → `{WEB_UI_VIEW_STORAGE_LOCATION}`. Optionally add a MockMvc row in `SdrReadGateEnforcementContextTest`: a user holding only BILL_OF_LADING gets 200 on `/v3/location/search/findByGateTrue` and 403 on `/v3/location/1`. Mutation-check it by passing `null` and confirming red. |
| L1 | Low | HIGH | `src/main/java/net/aim_ai/wms/security/SdrFunctionRules.java` (AC-2 block comment, "⚠ The Cypress suite PATCHes /advice and /cyclecount and GETs /location/{id}") | Cypress also GETs `/location/search/findByGateTrue`: `wms2-web-ui cypress/support/helpers/wmsHelpers.js:77`, `e2e/wms/pick-pack/pick-pack-order.cy.js:415`, `e2e/wms/scenario1-hybrid/step5-bol-create.cy.js:69`, `e2e/wms/transfer-offsite/transfer-offsite.cy.js:331`. That needs `WEB_UI_VIEW_BILL_OF_LADING`, a fourth function the Cypress user must hold. | Add the findByGateTrue read and its function to the note, so the Cypress user is listed as needing INBOUND_BOL, CYCLECOUNT, STORAGE_LOCATION and BILL_OF_LADING. |
| L2 | Low | HIGH | `SdrFunctionRules.java` ("Only SDR caller found: PATCH /advice/{id} …"), and the same in the commit message | `wms2-web-ui store/receiving/inboundNotices.js:197`: ``this.$axios.$delete(`/advice/${data.deleteOpenInboundNotices[i].id}`)``. Its only triggers are commented out (`openNotices.vue:31`, `:100`) and `RestConfiguration.configureAdviceItemVerbWriteExposure` disables DELETE. The claim is true only as "only live caller". | Reword to "Only live SDR caller: PATCH … (the DELETE in `deleteOpenInboundNotices` is undispatched, and the verb is withdrawn in RestConfiguration)". |
| L3 | Low | HIGH | `src/test/java/net/aim_ai/wms/security/SdrRuleInventoryContextTest.java:78`; `src/test/java/net/aim_ai/wms/unit/security/SdrFunctionRulesUnitTest.java:247`; `SdrFunctionRules.forTesting` javadoc | "Slice 1 ships zero overrides; this test is the reason Slice 3 can add them safely." / "Slice 1 ships no override; the mechanism must still be proven…" / "exercisable without shipping a production override". Production now ships two overrides. The renamed `productionShipsNoOverrides` test was updated, but these siblings were not. | Update all three to say production carries the two Location overrides (pinned by `productionOverridesAreExactlyTheLocationPair`). |

### Open questions (not blocking)
- The dev holder counts were not re-measured by this lane.
- Under-gating, outside the brief: a Location type rule gates `/v3/location/**` only. Other still-unruled exported types that project location data (for example `ViewWarehouseLocationReport`) are unaffected. That is Slice-4 territory, and this is not a defect in this commit.

## Positive observations
- Overrides fail toward the stricter type rule, and a stale key refuses to boot. Both directions are safe.
- The comments record *why* Boxtype, Client and Section stay unruled, and say plainly where the sweep's method has limits.
- The override test was converted from "is empty" to an exact set, so adding an override is a visible decision, not drift.
- Each per-search override is grounded in a dispatch chain I could reproduce end to end.

## Verdict
**APPROVE.** The wiring is correct and the over-gating sweep found no caller that would be denied. M1 is worth closing before AC-5 moves any tenant off OFF, because the code path it leaves unpinned is the one that prevents over-gating. L1-L3 are prose fixes.
