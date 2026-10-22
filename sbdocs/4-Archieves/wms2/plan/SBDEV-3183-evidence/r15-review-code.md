---
title: SBDEV-3183 r15 — independent code review (rules for the 15 swept read-only SDR types)
date: 2026-10-21
ticket: SBDEV-3183
kind: evidence (review lane, read-only)
worktree: .claude/worktrees/wms2-api/SBDEV-3183-r15
range: a49e6ebd..38a1c1ac (6c2a39ef, 832ab872, 38a1c1ac)
verdict: COMMENT (no blocking finding)
---

# SBDEV-3183 r15: code review

**Verdict: COMMENT.** I found no High finding. There are 8 findings: 1 Medium and 7 Low.

I did not run Maven and edited no file in the worktree. The full suite was running there during the review.

## How I checked it

- **Diff.** I read `git diff a49e6ebd..HEAD` in full. It touches 6 files.
- **Callers, rebuilt independently** from `origin/develop` with `git grep`, not from the sweep:
  - wms2-web-ui `add0628`, the same SHA the sweep used. I fetched it today and it has not moved.
  - wms2-mobile-ui `f51dc6c`, unmoved.
  - oms-laravel-api `26a301ac`. This **moved** after the sweep's `39bdd031`, so I swept it again.
- **Liveness and routes.**
  - For every SDR-calling store action I grepped its dispatch sites.
  - I walked each dispatching component up to a page through explicit imports and Nuxt auto-import tags (`components: true`).
  - I mapped each page to its function using `util/appMenuList.js` (MENU `fn` and EXTRA_ROUTES) and `pages/admin.vue` TAB_FUNCTIONS.
- **Grants on dev.** `wms2-wineco-dev` DB `mywms_function` ⋈ `mywms_role_mywms_function`: all 20 functions the new rules name exist and are granted to between 2 and 8 roles. No rule names a function that nobody can hold.
- **Spy mechanics.** `spring-test-6.2.15` `MockitoSpyBeanOverrideHandler` contains `Proxy.isProxyClass` and `AdditionalAnswers.delegatesTo`. A JDK-proxy Spring Data repository is therefore spied by delegation, which is supported.

## 1. Do the rules match the real callers?

All 15 rules and both overrides match every live caller I could find. No live web-ui caller lacks its function.

| Type / search | Live caller → page → function | In rule? |
|---|---|---|
| Goodsreceiptposition | openNoticeTable / closedNoticeTable / receive.js → `/receiving/inbound-notices`, `openNotice/:id`, `closedNotice/:id`, `openNotice/receive` → INBOUND_BOL | yes |
| Itemunit | skuUnit.vue → sku-units → ITEM_UNIT; editPackagingDialog ← packaging.vue → CASE_TYPE | yes, both |
| LocationArea | functionalArea.vue → AREA; createCycleCount ← plannedCycleCount ← `/internalOps/cycle-count` → CYCLECOUNT | yes, both |
| LocationRack | no dispatch of `getLocationRacks` (dead) | n/a |
| LocationType | locationType.vue → location-types → STORAGE_LOCATION_TYPE | yes |
| LockOverview(All)DtoView | lockReport.vue → lock-report → STOCK_UNIT_LOCK_OVERVIEW | yes, both types |
| Printer (collection) | printerSetup.vue → PRINTER; editUser ← user ← userManagementMain → USER_MANAGEMENT; in-module follow-ons from setDefault/update/save/delete, dispatched only from Printer Setup | yes |
| Printer `findByType` | openNoticeTable → INBOUND_BOL; add/editShipper ← shipperList (Shippers tab) → CLIENT; parcelPickingReport → PARCEL_PICKING | yes, all 3 plus PRINTER |
| ReceivingDtoView base | openNoticeDescription / closedNoticeDescription / createPo.updateInboundBol ← addMissingSku (`findByAdvicenumber`); receivingForm.vue (`findByAdvicepositionid`) → INBOUND_BOL | yes |
| ReceivingDtoView `findByKeyword` | receivingReport.vue → receiving-report → RECEIVED_STOCK_OVERVIEW (`reports/data/searchReport` is dead) | yes |
| Replenishorder | openRequest.vue ← `/internalOps/replenishment` → REPLENISHMENT_ORDER | yes |
| StockView | inventoryReport.vue → INVENTORY_RECORD | yes |
| Unitload | only a commented-out dispatch (dead) | n/a |
| UnitloadRecord | containerRecord.vue → UNIT_LOAD_RECORD | yes |
| UnitloadType | unitLoadType.vue → UNIT_LOAD_TYPE (`createPo/getUnitLoadTypes` is dead) | yes |
| ViewWarehouseLocationReport | skuLocationReport.vue → LOCATION_OVERVIEW | yes |

Each dispatching component is imported or tagged only from the pages listed. No report component is embedded in a second page.

**Mobile.** A case-sensitive grep for the 15 lower-case SDR paths returns zero hits. Mobile uses only the camel-cased MVC paths.

**OMS at `26a301ac`.**
- No `v3/` key in `config/wms.php` names any of the 15 types.
- The only reference is the documented env override `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT`, which defaults to `rest/printer/findByType`.
- I found no `search/find*` string in `app/` that targets these types.

**Why a live UI caller cannot be locked out.** The web-ui route guard (SBDEV-2967) already refuses each page unless the user holds the page's function. Every rule is a superset of the functions of the routes that reach it. A live UI caller therefore always holds a function the rule accepts.

**SHADOW telemetry (dev, 2026-10-21 12:19Z: ReceivingDtoView 3, Printer 1).** `wms2.authz.sdr.unruled` is tagged with `domainType` only (`SdrFunctionGuard.java`: `meterRegistry.counter(METRIC_SDR_UNRULED, "domainType", label)`). It carries no search path or user, so the reading **cannot attribute the calls to a screen**. From the code, the candidates are:
- **ReceivingDtoView:** Inbound Notices description panes and the add-missing-SKU flow (`findByAdvicenumber`), the receive form (`findByAdvicepositionid`), all INBOUND_BOL; or the Receiving Report (`findByKeyword`, RECEIVED_STOCK_OVERVIEW).
- **Printer:** Printer Setup or edit-user (collection, PRINTER or USER_MANAGEMENT); or Inbound Notices, Shippers or Parcel Picking (`findByType`, override).
- **Cypress:** it reads both types.

Every candidate's function is in the rule that governs that path. The definitive check is post-deploy, below.

## Findings

### [Medium] F1. SdrMustStayOpenRailUnitTest's Printer note now contradicts the code
`src/test/java/net/aim_ai/wms/unit/security/SdrMustStayOpenRailUnitTest.java:62-66`:
> "One known configuration-only reader is not listed: OMS's `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT` env override can repoint its printer lookup at `v3/printer/search/findByType` (SDR) … **A tenant that sets it makes `Printer` a ninth entry.** Whether any OMS deployment sets it was not measured as of 2026-10-18."

r15 rules `Printer`, and the `findByType` override excludes the OMS identity. The rail's recorded decision says a tenant with that env var needs `Printer` **unruled**, so the two now disagree:
- The caveat comment in `SdrFunctionRules.productionOverrides()` has the correct story.
- The rail doc, which is the single home for the "who must stay open" decision, still says otherwise and is silent that the rule has landed.

A reader re-opening the rail decision will be misled, and nothing turns red.

**Fix:** rewrite the sentence along these lines: "Since SBDEV-3183 r15, `Printer` IS ruled (`findByType` override → PRINTER/INBOUND_BOL/CLIENT/PARCEL_PICKING). A deployment that sets the env var to `v3/…` is denied once its tenant enforces. Confirm the PRD OMS env before any PRD tenant leaves OFF/SHADOW, or resolve OMS onto `/rest`." Keep the open measurement as an explicit pre-ENFORCE gate in the plan's rollout checklist.

### [Low] F2. Stale ruled/unruled counts the literal sweep missed
The implementer grepped for the old figures ("11 rules", "24 unruled") but not for the older ones that were already stale. This change makes each of these further wrong:
- `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:94-95`: "Slice 1 ruled eight authorization-graph types; SBDEV-3183 Slice 2 un-exported three of them, so **five rules remain**." There are now 26.
- `src/main/java/net/aim_ai/wms/security/RequiresFunction.java:59-61`: "(Slice 1 rules the five authorization-graph types, SBDEV-3222 added Sysprop and Message, and SBDEV-3410 P2 added StockrecordView; every other exported type is untouched, **27 as of SBDEV-3471**…)". It omits AC-2's 3 types and r15's 15.
- `src/test/java/net/aim_ai/wms/unit/security/SdrRuleStartupCheckUnitTest.java:157`: "**30 of 35** exported types have no rule by design." It is now 9 of 35.

**Fix:** replace each count with the rule rather than a number, e.g. "see SdrRuleStartupCheck's boot log / SdrRuleInventoryContextTest for the live ruled/unruled split". Or at minimum date-stamp the figure as history, as SdrUncalledSurfaceNotExportedContextTest does.

### [Low] F3. REVIEWED_OVERRIDE_PARAMETERS pins the signature, not the query the review depends on
`SdrFunctionRulesUnitTest.java`, `REVIEWED_OVERRIDE_PARAMETERS` and its `containsExactlyElementsOf(reviewed)` branch.

**Unlisted overrides are as strict as before.** The `reviewed == null` branch keeps the original `getParameterCount()…isZero()` check. I looked for ways the new check could pass silently and found none:
- A stale entry goes red through `containsAll(REVIEWED_OVERRIDE_PARAMETERS.keySet())`.
- A second exported method on the same path goes red through `hasSize(1)`.
- `Map.of` rejects duplicate keys.

**The gap is in the listed entries.** The ReceivingDtoView entry's justification is about query semantics: "both strings only narrow … the query's `:keyword IS NULL or :keyword = ''` arms". Suppose someone edits the `@Query` in `ReceivingDtoViewRepository` (lines 24-26), for example dropping the `clientid` predicate, joining another view, or changing the return type to a wider projection, while keeping `(String, String, Pageable)`. That passes green, and the recorded review no longer holds. Two things limit the damage:
- The same blind spot existed for zero-parameter overrides (a zero-parameter query body can change too).
- The data is already reachable through the base rule's collection GET.

So this is a durability gap, not a hole.

**Fix (cheap):** for reviewed entries, also pin the `@Query` value, either with a hash or by `contains`-asserting the narrowing arms (`":keyword IS NULL"`, `":clientNumber IS NULL"`). The failure message should send an editor back to the review.

### [Low] F4. The fallback rows are not anchored to real search paths
`SdrFunctionRulesUnitTest.sbdev3183UnoverriddenSearches()` and the fallback CSV rows in `SdrFunctionGuardUnitTest.searchOverrideReachesAccessService`:
> `"printer, search/findByTypeAndProcessdefaultTrue, WEB_UI_VIEW_PRINTER|WEB_UI_VIEW_USER_MANAGEMENT"`

`requiredFunctions(type, anyUnknownPath)` falls back to the base rule. So a misspelled row, or a search later renamed or withdrawn, stays green and vacuous. The assertion is still attributable (deleting the base rule turns it red), but the row's *name* asserts something the test does not check.

**Fix:** in `unoverriddenSearchFallsBackToTheTypeRule`, resolve the search on `OVERRIDE_REPOSITORIES.get(type)` with the existing `searchPathOf`/`isExported` helpers and assert exactly one match before asserting the fallback.

### [Low] F5. Pickingorder is left unruled, inconsistent with the rationale used for LocationRack and Unitload
- `SdrFunctionGuard.java` Row-5 comment: "the 8 OMS/mobile-read types SdrMustStayOpenRailUnitTest pins open, plus Pickingorder (Cypress-only)."
- `SdrFunctionRules.java`: Unitload and LocationRack are ruled with "No live UI caller … nothing can break". Unitload is in fact also Cypress-read.

Pickingorder has exactly the shape that was ruled for Unitload. Its only SDR reader is `cypress/e2e/wms/smoke/phase2-pick.cy.js:97` `'/pickingorder/search/findByNumber?number='`, and `WEB_UI_VIEW_PICKING_ORDER` exists (`WmsConstants.java:405`).

Leaving it unruled has two costs:
- Picking-order rows stay readable by any authenticated user at ENFORCE_RULED.
- It keeps every tenant off FAIL_CLOSED for no recorded reason.

Nothing pins it unruled. It is not on the rail, so the omission is undocumented apart from one comment clause. This is consistent with the brief, which listed 15 types, and the implementer raised it as an open decision. The code is not wrong.

**Fix:** either rule `Pickingorder → {WEB_UI_VIEW_PICKING_ORDER}` in the same slice (with a Cypress-grant note like Unitload's), or record the deliberate omission with a reason, ideally as a pinned test entry rather than prose.

### [Low] F6. The spy commit 38a1c1ac has no recorded verification
`CustomerorderForceCancelOutboxIntegrationTest.java:94-103` and `:136-137`.

`r15-implementation-report.md` lists only commits `6c2a39ef, 832ab872`, and its full-suite line reads `FULL_SUITE_PLACEHOLDER`. No targeted run of this IT is recorded. `target/surefire-reports` held no ForceCancel report at review time, because the suite was still running.

**The change itself is right:**
- `doReturn(...).when(spy).findById(anyLong())` and `doAnswer(...).when(spy).save(any(Unitload.class))` are the correct spy idiom. `when(spy.findById(..))` would invoke the real proxy while stubbing.
- spring-test 6.2.15 spies JDK proxies through `delegatesTo`, so stubbing never reaches H2.
- There is prior art: `ReplenishDupConcurrencySliceIT.java:103` already spies `ReplenishorderRepository`. `MessageRepositoryNativeSearchIT.java:45-47` documents the same mock-erases-SDR-metadata trap.

**There is one semantic change.** Every *unstubbed* `UnitloadRepository` method now runs for real against H2, where the mock returned null or empty. On this fixture's path (`cancelOrder(order, true)`, with `pickingtoteId` null and `parcelId = 900`), `CustomerorderService` calls only `findById` (`:522`) and `save` (`:524`), both stubbed. The tote branches (`:476/492`, `:989/992`, `:1040`) are guarded by `getPickingtoteId() != null`. Other beans that get the same spy (`unitloadBusinessService` is a mock) may call real finders, which return empty on this H2 schema. No real Unitload row is written.

I swept the other context tests: no other `@MockitoBean`/`@MockBean` targets any of the 15 newly-ruled repositories. All the others are `@Autowired`, apart from the pre-existing Replenishorder spy. No sibling context will refuse to boot.

**Fix:** append the targeted result for this IT and the full-suite verdict to the implementation report, and list 38a1c1ac in its `commits:`. Optionally add `verify(unitloadRepository).save(argThat(u -> u.getId() == PARCEL_ID))`, so the stubbed path is proven to be the one exercised.

### [Low] F7. The Printer/findByType override widens a read (for the record; needs Nam's yes)
`SdrFunctionRules.java` `PRINTER_BY_TYPE_VIEW` and the `findByType` override. `PrinterRepository.findByType(@Param("type") String type)` is an unpaged `List<Printer>` over the whole table. INBOUND_BOL, CLIENT and PARCEL_PICKING holders can enumerate `type` values and read every printer row.

The test javadoc records this honestly as "accepted for review". The comparison it draws is fair: the five-function base union would also open the item resource, and the MVC `/inboundPrinters` and `/outboundTotePrinters` already serve printer lists more widely. This is not a defect, but it is an explicit sign-off item. If it is declined, the remedy is an MVC endpoint, not a narrower SDR rule.

### [Low] F8. The Goodsreceiptposition rule governs a caller whose URL is malformed
`SdrFunctionRules.java`:
> "Its urlPart starts with '/' not '?', so the request has no {search} variable and this base rule governs it whatever SDR then does with the malformed path."

The rule is correct for the path as sent. The UI bug (`store/receiving/inboundNotices.js` `urlPart = '/advicepositionId=' + …`) is separate. If someone fixes the UI to `?advicepositionId=`, the request gains `{search}=findByAdvicepositionId`, has no override, and still falls back to INBOUND_BOL. So no rule change is needed.

**Fix:** none to this diff. Keep the UI bug on the ticket as the sweep proposed.

## Test assertions: would they fail attributably?

| Test | Mutation | Red, and named? |
|---|---|---|
| `needsGatingTypeRequiresExactlyItsScreenFunctions` (15 rows) | delete a `rules.put` | yes: `isPresent` `.as("%s must carry a rule …")` |
| same | reorder, add or remove a function | yes: `containsExactlyElementsOf` on a LinkedHashSet |
| `needsGatingOverrideRequiresExactlyItsScreenFunctions` | drop or change an override | yes: `overrideKeys().contains(key)`, then exact ordered set |
| `ruledDomainTypesMatchesTheFullRuleSet` | add or remove any type | yes: `containsExactlyInAnyOrderElementsOf` |
| `productionOverridesAreExactlyTheLocationPairPrinterAndReceiving` | add or remove any override | yes: exact set |
| `searchOverrideReachesAccessService` | guard passes `null` as search | yes (the implementer's mutant d killed exactly the 4 override rows) |
| `unoverriddenSearchFallsBackToTheTypeRule` | add an override for the listed search | yes. A misspelled row stays green (F4) |
| `everyOverriddenSearchTakesNoParametersOrItsReviewedList` | add, remove or retype a parameter | yes. A query-body change stays green (F3) |

- **Display names agree with bodies.** That includes the renamed `productionOverridesAre…PrinterAndReceiving`, the parameterized `"{0}/{1} -> {2}"`, and the `fakeMappings` javadoc, which says "Six exported resources" and builds 6.
- **Stale literals.** `grep -rnE "11 rules|24 unruled|27 ruled|16 types|other 24|11 ruled|35 - 11"` over `src/` finds only the dated history line in `SdrFunctionGuard.java` ("35 - 11 = 24 unruled", correctly followed by "35 - 26 = 9"). The others are F2.
- The implementer's report notes "15 types, not 16 / 26 ruled, 9 unruled", which matches the code: 11 + 15 = 26, and 35 − 26 = 9.

## Positive observations
- Every rule cites its caller as a quoted file snippet, with no bare line numbers. The rule-both-or-neither note on the Lock Report pair prevents a real future break.
- Ordered any-of sets with the busiest screen first, asserted in order, keep the denied-caller message useful.
- The allow-list design keeps zero-parameter strictness for unlisted overrides, adds stale-entry and missing-repository checks, and records what a holder can reach rather than what the screen passes. The implementer also caught and fixed their own message contradiction (832ab872).
- The mutants are attributable, the PIT run is recorded, and the boot-log figure is quoted.
- The spy fix uses the correct `doReturn` idiom and documents why the mock broke the context.

## Recommended actions before ENFORCE on any tenant
1. Fix F1, so the rail doc matches the ruled Printer.
2. After deploying r15 to dev at SHADOW, read `wms2.authz.sdr.would_deny{domainType=ReceivingDtoView|Printer|…}` and the would-deny log lines, which carry the user. Expect 0. Any non-zero names the user and function and settles the 2026-10-21 attribution question that the `unruled` counter cannot.
3. Grant the Cypress test user STOCK_UNIT or CONTAINER, and AREA or CYCLECOUNT, plus PRINTER, INBOUND_BOL, INVENTORY_RECORD, REPLENISHMENT_ORDER and LOCATION_OVERVIEW, before its tenant enforces.
4. Measure the PRD OMS env for `WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT` (F1 and F7).
