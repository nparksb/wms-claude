# SBDEV-3142 — fact-check lane (r2-facts)

**Target:** `sbdocs/1-Projects/wms2/plan/SBDEV-3142-report-read-gating.md`
**Date:** 2026-08-31
**Instruments:** `git show`/`git grep` against `origin/develop` in all three repos (never the working tree);
`target/surface-inventory.tsv` (792 data rows, copied out before `mvn clean`); one `mvn -o clean test`
in `.claude/worktrees/wms2-api/SBDEV-3142`.
**Anchors measured:** wms2-api `origin/develop` = `d434a3e5`, `origin/main` = `cf430ff3` (2026-08-20),
245 commits ahead. wms2-web-ui `origin/develop` = `9e70a73b`. wms2-mobile-ui `origin/develop` = `c79e81c`.
All three match the anchors the plan cites.

**Headline.** The plan's arithmetic is right — 19/32, 14/13, 26 paths, 12 constants, the 14-member
`GUARDED` set, the six §7.1 endpoints, `grep -c` = 10, the 41 probe rows, the `getAllRoles` join,
every source citation and quoted snippet I could resolve. Consistent with the lesson in my brief,
**every defect I found is a closed-set, mechanism, or identifier claim, and not one of them is a number.**
Eight are wrong or self-contradictory; one closed set is materially incomplete; two are overstated.

Two of the eight change what the implementer does: **F5** (a handler name that does not exist, in the
plan's most important test) and **F8** (§3.1 and §3.4 contradict each other on whether there is a UI change).
Two lower the severity of recorded findings: **F2** (§7.2's club-run defect is cosmetic, not behavioural)
and **F1** (§3.6's stated reason for declining `GUARDED` enrolment is false).

---

## FALSE — correct these

| # | claim (quoted) | verdict | evidence and correct value |
|---|---|---|---|
| **F1** | §3.6: "Enrolling `ReportController` would make **its one remaining unannotated handler** — and every handler added later — deny fail-closed, and **the boot assertion would refuse to start**." | **FALSE** | Post-fix `ReportController` has **zero** unannotated declared handlers. It declares 14 (10 `export*` POST + 3 `*View` GET + `reprintLabels`); the plan annotates 13 and `reprintLabels` already carries `@RequiresFunction` at `ReportController.java:314`. So 14 of 14. `FunctionGuardStartupAssertion.findUnannotatedGuardedHandlers` keys on `handler.getMethod().getDeclaringClass()` (`FunctionGuardStartupAssertion.java:148`) and tests membership exactly at `:149` (`if (!guarded.contains(declaring))`), as the interceptor does at `FunctionGuardInterceptor.java:213` — an exact `Set<Class<?>>.contains(declaring)` with **no hierarchy walk** — so `DashboardController` would not be dragged in either. Enrolling `ReportController` in `GUARDED` after this fix boots cleanly. **The recommendation (out of scope for this PR) stands; the reason given for it does not.** |
| **F2a** | §7.2.1: "The TSV shows `getActiveClubRun` mapped to **two** paths, `/activeClubRun` and `/inactiveClubRun` — **a copy-paste of the handler reference**." | **FALSE** | There is no dual mapping. `ClubLineController` declares **two overloaded methods that happen to share the name** `getActiveClubRun`: `getActiveClubRun(keyword, page, size, sort, order, principal)` at `ClubLineController.java:229-230` mapped to `/activeClubRun`, and `getActiveClubRun(principal)` at `:248-249` mapped to `/inactiveClubRun`. Different signatures, different bodies, different `dtoViewService` calls. Two TSV rows appear because the TSV's `handler` column carries only a method **name** — the same name-keying trap §1.2 warns about, hit here by the plan itself. |
| **F2b** | §7.2.1 heading: "**`/v3/clubLine/inactiveClubRun` returns ACTIVE club runs.**" | **FALSE** | It returns inactive ones, correctly. Body: `dtoViewService.getOrderBatchByStateAndType(WmsConstants.State.ORDER_BATCH_ACTIVATED, [CLUB])` (`ClubLineController.java:250-252`) → `ViewDtoService.java:403` → `CustomerorderBatchRepository.findByStateAndType`, whose SQL is `where cb.state < :state` (`CustomerorderBatchRepository.java:100`). `ORDER_BATCH_ACTIVATED = 520` (`WmsConstants.java:78`), so the query returns batches **below** 520 — not yet activated. The transfers counterpart is the identical shape: `getInactiveTransferBatchOrders` is `where co.state < :state` with `CUSTOMER_ORDER_ACTIVATED = 505`. **Correct value: the only defect is the Java method NAME.** A readability bug, not a data bug — and that materially lowers its priority. |
| **F3** | §3.4: "Its sibling action `getOrderDetails` **in the same store** *is* live on the Outbound BOL screen, which is gated `WEB_UI_VIEW_BILL_OF_LADING`." | **FALSE** | `outbound/outboundBols/getOrderDetails` is dispatched **nowhere** — `git grep "outboundBols/getOrderDetails" origin/develop` → 0 hits. What is live on the Outbound BOL screen is `outbound/club/getOrderDetails`, dispatched from `components/outbound/bol/outboundBolDetailsTable.vue:201` — a **different store module**. Correct version, and it happens to strengthen the decision: that same component at line **202** already dispatches `outbound/club/getItemInfo`, so the BOL screen genuinely reaches into the club module today — but `store/outbound/club.js:228-232` GETs `/customerOrderPosition/detailsByOrderId`, **not** `/clubLine/skus`, so no live path reaches the endpoint from a `BILL_OF_LADING` screen. **§3.4's conclusion (gate `WEB_UI_VIEW_CLUB_LINE`, delete the dead action) is correct; its cited evidence is not.** |
| **F4** | §1.2 and §5.1 P5: "**793** deployed handler rows" | **FALSE** | **792.** `target/surface-inventory.tsv` is 793 lines, of which line 1 is the header the test writes at `SurfaceInventoryContextTest.java:147` (`String.join("\t", "mappingBean", "verbs", "paths", "beanType", "declaringClass", "handler", …)`). |
| **F5** | §6 T4: "**`DashboardController.orderMonitorViewSummary`** + `replenishMonitorViewSummary`, user holds nothing → **200**" | **FALSE** | **No method of that name exists.** `/v3/dashboard/orderMonitorViewSummary` is declared by **`orderMonitorViewOverview`** (`DashboardController.java:48-49`). `replenishMonitorViewSummary` is correct (`:116-117`). This is exactly the trap §1.2 documents for `floowbinMonitorView` / `getDetailView`, reintroduced in the plan's own most load-bearing test row. **A T4 written from this line will not compile, or will silently pin the wrong handler.** |
| **F6** | §1.2: "This is inheritance, not a second annotation, **which is why there is no `/v3/dashboard` string anywhere in `ReportController`**." | **FALSE** (literal) | The string is at `ReportController.java:310`, in a comment: `// /v3/report/reprintLabels and /v3/dashboard/reprintLabels for the same reason - one annotation covers both.` No dashboard **mapping** exists there, so the substance holds — but a reader who greps `dashboard` in that file to confirm the claim gets a hit. Reword to "no `/v3/dashboard` mapping". |
| **F7** | §1.3: "the DEV maximum is **80** functions (`sbuser1`, `sbuser15` hold **81**), not 79." | **FALSE** (self-contradictory) | These cannot both hold: 80 cannot be the maximum if two accounts hold 81. §0 correction #1 repeats "the max is **80**, not 79", and the §1.3 table gives `panderson` 80. One of the two numbers is wrong. **Not resolvable by me** — DB-side. Note the maximum feeds nothing load-bearing, but it is stated as a correction *to the ticket*, so it will be quoted. |
| **F8** | §3.1: "No new class, no new interceptor, no `GUARDED` change, no migration, **no UI change**." | **FALSE** (self-contradictory) | §3.4's recorded decision is "**delete the dead action** in the web UI, in the same PR pair", and §5.2 step 4 is "Delete `store/outbound/outboundBols.js#getItemInfo` in `wms2-web-ui` (§3.4) — a second, small PR." Both cannot be true. Reword §3.1 to "no UI change **in the API PR**". |

---

## INCOMPLETE — a closed set that is not closed

| # | claim (quoted) | verdict | evidence |
|---|---|---|---|
| **I1** | §0 row 5 / §7.1: "**Six more `/v3` endpoints of identical shape exist outside the ticket's three controllers.**" — and §7.1's framing as the complete adjacent set | **INCOMPLETE** | Literally true (six do exist outside), but it reads as "and that is all there is", and it is not. **23 further ungated handlers sit on two of the three controllers this ticket already touches**, silently excluded by the `$2=="POST"` term in §1.2's awk. Most pointedly: **`GET /v3/transfers/skus` → `TransfersController#getSkuView`**, the exact read twin of plan row 14 (`ClubLineController#getSkuView`, `POST /v3/clubLine/skus`) — same DTO type `List<ClubLineSkuDto>`, same purpose, no gate, and it is *not* in the 19. Nine more are plain list reads of the same class: `/clubLine/{open,closed,active,inactive}ClubRun`, `/transfers/{open,active,closed,inactive}Transfer`, `/transfers/allOpenTransfer`, `/clubLine/availableStagingLanes`, `/clubLine/orderBatch/{id}`, `/transfers/transferOrder/{id}`, `/transfers/transferOrderByOrderBatchId/{id}`. **Either widen the scope or say explicitly in §1.2 that the POST filter is a deliberate cut and name what it excludes** — otherwise the next reader trusts §7.1 as the adjacent-surface inventory. Full enumeration in the appendix. |

---

## OVERSTATED — substance holds, phrasing does not

| # | claim (quoted) | verdict | evidence |
|---|---|---|---|
| **O1** | §1.1: "**Ten of them export an entire dataset.**" | OVERSTATED | `exportInventory` reads `offset`, `limit`, `filter`, `keyword` from the request body and passes all four to `reportService.exporIventoryReport` (`ReportController.java:63-72`). The caller controls them, so a caller *can* request everything — the security substance is intact — but these are not unconditional full dumps. Say "can be asked for an entire dataset". |
| **O2** | §3.6: "The inventory surfaces **four** `/rest/report/*`, `/rest/stockcount/*` POST-as-query **reads**." | OVERSTATED | Four POSTs match those prefixes, but one is not a read: `POST /rest/stockcount/sendDummyMessageStockCountList` → `MessageDummyController#sendDummyMessageStockCountList`. The three genuine reads are `POST /rest/report/getTransactionReport`, `POST /rest/report/getTransactionDetailedReport`, `POST /rest/stockcount/getStockCount`. A fifth row exists on those prefixes, `GET /rest/stockcount/triggerStockCount`. The scope decision (out of scope) is unaffected. |
| **O3** | §2: "the set holds 14 classes: **11 mobile controllers** plus `UserController`, `UserGroupController`, `UserRoleController`" | OVERSTATED | 14 and the three named classes are exact. "11 mobile" is the plan's shorthand and `FunctionGuardInterceptor`'s own javadoc contradicts it in place: *"a package rule covered 10 of 11 controllers because `OrderCancellationController` was declared outside `controller/mobile/`"*. Harmless here; do not reuse the phrase as a location predicate. |

---

## CONFIRMED

### Counts and derivations (all reproduced exactly)

| claim | verdict | evidence |
|---|---|---|
| "**19 distinct methods, 32 distinct paths**", and §1.2's awk reproduces them | **CONFIRMED** | The plan's awk, run verbatim on the TSV, prints `19 32`. Independently: 32 distinct values of `$3` and 19 distinct `$5"#"$6`. The awk's `p++` counts rows, not paths — safe only because each of the 32 rows carries exactly one path, which I verified. Its `length(m)` collapses same-name overloads — safe only because none of the 19 shares a name within its declaring class, which I also verified. Both are latent, not active. |
| Group table: exports 10/20, GET views 3/6, ClubLine 3/3, Transfers 3/3, total 19/32 | **CONFIRMED** | Row-by-row from the TSV. |
| §0 #3: `ReportController` "declares **14** handlers of which **13** are ungated (10 POST + 3 GET), across **26** paths" | **CONFIRMED** | 14 declared: 10 `@PostMapping(path= "/export*")` + `reprintLabels` + 3 `@GetMapping` `*View`. 13 ungated × 2 prefixes = 26 deployed paths. |
| "`reprintLabels` is the **only** gated handler on `ReportController`" | **CONFIRMED** | `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_PARCEL_PICKING)` at `ReportController.java:314` — quoted verbatim in §2's Affected Locations table and matching exactly. Every other `declaringClass = ReportController` row in the TSV has empty `requiresFunction`, `preAuthorize` and `publicHandler`. |
| §7.3: "`grep -c '@PostMapping(path= "/export'` = 10" | **CONFIRMED** | Returns `10` on `origin/develop`. |
| §7.4: probe script "**41 rows**" | **CONFIRMED** | 20 (A: 10 exports × 2) + 6 (B: 3 views × 2) + 6 (C) + 3 (D) + 4 (E) + 2 (F) = **41**. Section headers at lines 127/136/143/152/160/168. |
| §5.1 P5: inventory "**1 test**, BUILD SUCCESS" | **CONFIRMED** | Exactly one `@Test` in `SurfaceInventoryContextTest.java:95`. (The 19.3 s timing I did not re-measure.) |
| §5.1 P4: worktree @ `d434a3e5` | **CONFIRMED** | `.claude/worktrees/wms2-api/SBDEV-3142` HEAD = `d434a3e5`, clean tree, and it equals `origin/develop`. |

### Mechanism claims

| claim | verdict | evidence |
|---|---|---|
| §3.2: "**Method-level annotations are immune**" — the 13 annotated handlers declare on `ReportController`, the five mobile-facing GETs on `DashboardController` | **CONFIRMED** | All 13 TSV rows we annotate carry `declaringClass = net.aim_ai.wms.controller.ReportController`. `DashboardController` declares **five distinct GET methods** across five paths — `orderMonitorViewOverview`, `orderMonitorViewBySectionName(String)`, `orderMonitorViewBySectionName(String,String)` (an overload, which is why the name-keyed TSV looks like four), `orderMonitorClientViewSummary`, `replenishMonitorViewSummary` — plus one already-gated POST `printToteLabels`. **None of the five overrides a `ReportController` method**, which is the condition that matters: `getMethodAnnotation` delegates to `findMergedAnnotation` with `SearchStrategy.TYPE_HIERARCHY`, so an *override* of an annotated method WOULD inherit the annotation. It does not arise here. Immunity holds, for the reason the plan gives. |
| §3.2: `DashboardController extends ReportController` under `@RequestMapping("/v3/dashboard")` | **CONFIRMED** | `DashboardController.java:25-26`, quoted verbatim. TSV corroborates: `/v3/report/exportInventory` and `/v3/dashboard/exportInventory` are two rows, different `beanType`, same `declaringClass`. |
| §3.2: a class-level annotation on `DashboardController` is "**silently inert**" because the inventory's `findMergedAnnotation(getBeanType(), …)` finds it while the interceptor keys on `declaringClass` | **CONFIRMED** | `SurfaceInventoryContextTest.java:107` `Class<?> type = hm.getBeanType();` and `:87` `findMergedAnnotation(type, RequiresFunction.class)`. `FunctionGuardInterceptor.java:166` `Class<?> declaring = handlerMethod.getMethod().getDeclaringClass();` → `:209` `AnnotationUtils.findAnnotation(declaring, …)`. §3.3's divergence table is exactly right, and so is §0 #4's rejection of AC-4's "inventory alone" instrument. |
| §2's four-step `preHandle` resolution order | **CONFIRMED** | `FunctionGuardInterceptor.java:179` (`@PublicHandler` first, short-circuit), `:184` (method-level captured once, as `methodLevel`), `:207-210` (class-level `AnnotationUtils.findAnnotation(declaring, …)`), `:212-220` (null → `!GUARDED.contains(declaring)` → allow, else deny fail-closed). |
| §2: `GUARDED` "holds 14 classes" and none of the three controllers is in it | **CONFIRMED** | `FunctionGuardInterceptor.java:112-144`: `LookupController`, `PutawayController`, `MoveUnitloadController`, `MoveStockController`, `PickingController`, `PalletizingController`, `TruckLoadingController`, `CycleCountLosController`, `ReplenishController`, `TransferOrderController`, `OrderCancellationController`, `UserRoleController`, `UserGroupController`, `UserController` = 14. `ReportController`, `ClubLineController`, `TransfersController` absent. ⚠ Note `TransferOrderController` (in the set) is a **different class** from `TransfersController` (not in it) — the plan does not confuse them, but a reader might. |
| §2's javadoc quote: *"such a request falls through allowed, exactly as before."* | **CONFIRMED** | `FunctionGuardInterceptor.java:89` verbatim. |
| §6's warning that `standaloneSetup` installs no interceptor and an allow-only gate test is "**vacuous and green**" | **CONFIRMED** | `FunctionGuardInterceptor.java:80-85` states it in those terms; `BaseControllerUnitTest.java` exists at `src/test/java/net/aim_ai/wms/common/base/`. |
| §6 T2's deny contract: 403, body `reason`, header `X-Authz-Denied` | **CONFIRMED** | `:269` `problem.put("reason", …)`; `:279` `response.setHeader(Authority.AUTHZ_DENIED_HEADER, …)`; `Authority.java:150` `= "X-Authz-Denied"`. ⚠ Line 279 is inside `if (decision.requiredFunction() != null)`, so the header is absent on a null-function deny. Not our case (every one of the 19 names a function), but do not assert the header unconditionally. |
| §6 T5 / §3.4's ANY-of semantics | **CONFIRMED** | `AccessService.checkAnyAccess:144-148` loops `functions` and allows on the first held one. |
| §6 T6: `FunctionGuardStartupAssertion` exists | **CONFIRMED** | `src/main/java/net/aim_ai/wms/security/FunctionGuardStartupAssertion.java`. |

### §1.3, §1.4 and the function table

| claim | verdict | evidence |
|---|---|---|
| §1.3: `getAllRoles` is "the five-table `mywms_user → mywms_group_mywms_user → mywms_group_mywms_role → mywms_role_mywms_function → mywms_function` join that `AccessService.checkAnyAccess` consumes" | **CONFIRMED** | `UserRepository.java:77-84`, verbatim: `SELECT DISTINCT f.name FROM mywms_user u join mywms_group_mywms_user gu on u.id=gu.userlist_id join mywms_group_mywms_role gr on gr.grouplist_id=gu.grouplist_id join mywms_role_mywms_function rf on rf.rolelist_id=gr.rolelist_id join mywms_function f on rf.functionlist_id=f.id where u.name = :username` — five tables, exactly the chain named, in that order. `AccessService.java:142` `List<String> held = userRepository.getAllRoles(username);` is the only consumer in `checkAnyAccess`. |
| §1.4: "All 12 constants assigned by this plan exist" — **source half** | **CONFIRMED** | All 12 present in `service/WmsConstants.java` (note: `service/`, not the root package) as `public static final String` on `FunctionEnum`: lines 367, 381, 382, 383, 395–399, 402, 403, 419 for `STORAGE_LOCATION`, `STOCK_UNIT_RECORD`, `UNIT_LOAD_RECORD`, `INVENTORY_RECORD`, `BILL_OF_LADING`, `STOCK_UNIT_LOCK_OVERVIEW`, `RECEIVED_STOCK_OVERVIEW`, `LOCATION_OVERVIEW`, `FLOWBIN_MONITOR`, `PARCEL_MONITOR`, `PARCEL_PICKING`; plus `CLUB_LINE` 363 and `TRANSFER_ORDER` 364. `FunctionEnum` is a nested `public static final class` of String constants (`:347`), not a Java enum — the plan's `WmsConstants.FunctionEnum.X` reference form is valid. Exactly 12 distinct constants across the 19 rows, so the "12" is internally consistent. |
| §1.4: "**`WEB_UI_VIEW_PARCEL_PICKING`** … exists in `WmsConstants`" | **CONFIRMED** | `WmsConstants.java:419`. Its own SBDEV-2967-B comment block (`:404-418`) **independently corroborates plan rows 6/12 vs 7/13**: menu row 26 "calls `/report/exportParcelPicking` and `/report/parcelPickingView`", while "`WEB_UI_VIEW_PARCEL_MONITOR` above belongs to row 27, which is the row that actually calls `parcelMonitorView`." That is precisely the plan's split. |
| §3.1 rows 14–19: the `CLUB_LINE` / `TRANSFER_ORDER` gates and their screens | **CONFIRMED** | `util/appMenuList.js` @ `9e70a73b`: `:60` `/outbound/club` → `WEB_UI_VIEW_CLUB_LINE`; `:61` `/outbound/transfer` → `WEB_UI_VIEW_TRANSFER_ORDER`; `:69` `/processes/club-run` → `CLUB_LINE`; `:70` `/processes/transfer-picking` → `TRANSFER_ORDER`; `:167` `/processes/club-fulfillment` → `CLUB_LINE`; `:168` `/processes/transfer-fulfillment` → `TRANSFER_ORDER`; `:172-174` `/outbound/club/*` → `CLUB_LINE`; `:180-181` `/outbound/transfer/*` → `TRANSFER_ORDER`; `:175-177` `/outbound/outbound-bol/*` → `WEB_UI_VIEW_BILL_OF_LADING`. |
| §1.1's `appMenuList.js` quote: *"the single source of truth for 'which screen needs which function'"* | **CONFIRMED** | `util/appMenuList.js:1` verbatim. `middleware/require-function.js` exists on `origin/develop`. |
| §1.2: the three name/path mismatches — `floowbinMonitorView`, `getDetailView` → `/parcelPickingView`, `parcelMonitorView` | **CONFIRMED** | `ReportController.java:352-353`, `:372-373`, `:392-393`. The misspelling and the mismatch are both real, and the warning to key on the path is sound — see **F5**, where the plan then violated it. |
| §1.4 DB half: all 12 constants present in five tenant DBs; DEV 42–46 of 99 holders; hydra PRD 7 of 9 | **UNVERIFIABLE BY ME** | Out of my instrument set (no DB access granted to this lane, and I was told not to re-run the queries). Internally consistent, though: §1.3's "45 of 99 hold zero" leaves 54 with ≥1, and 42–46 fits under 54. See **F7** for the one internal contradiction in the §1.3 prose. |

### §3.2's mobile citations, §3.4, §3.5

| claim | verdict | evidence |
|---|---|---|
| §3.2: `pages/replenish.vue:133`, `:153` → `$get('/dashboard/replenishMonitorViewSummary')`; `store/picking.js:246` → `$get('/dashboard/orderMonitorViewSummary')` | **CONFIRMED** | Exact, at those line numbers, on `wms2-mobile-ui` `origin/develop` = `c79e81c`. A repo-wide grep finds these three `src` sites and no others (the rest are Jest/Playwright mocks). So the mobile blast radius §3.2 describes is complete. |
| §3.4: `store/outbound/outboundBols.js#getItemInfo` POSTs `/clubLine/skus` and "currently has **no dispatcher** — dead code" | **CONFIRMED** | `store/outbound/outboundBols.js:199-209`, `$post('/clubLine/skus', data)` at `:202`. `git grep "outboundBols/getItemInfo" origin/develop` → 0 hits; the nine live `getItemInfo` dispatches all target `outbound/club`, `outbound/pickPack`, `outbound/transfer`, `processes/clubRuns` or `processes/transferPicking`. The only live caller of `/clubLine/skus` is `store/processes/clubRuns.js:201`, reached from `components/processes/clubRuns/clubRunDetails.vue:142` and `components/outbound/club/batchDetails.vue:211` — both `CLUB_LINE`-gated screens, which is what row 14 asserts. **Decision sound; see F3 for the misattributed sibling.** |
| §3.5: `TransfersController.getParcelView` — "Swept in both UIs at `origin/develop`: **0 hits**" | **CONFIRMED** | `git grep "transfers/parcels" origin/develop` → 0 hits in `wms2-web-ui`, 0 in `wms2-mobile-ui`. Positive control: the same grep for `clubLine/parcels` returns 2 real store callers, so the pattern is not silently failing. |
| §3.5: its body is "byte-identical in effect" to `ClubLineController.getParcelView` — "both are `return dtoViewService.getOrderDetailView(orderBatchId)`" | **CONFIRMED** | `TransfersController.java:359-364` and `ClubLineController.java:298-303` are character-for-character identical apart from indentation. |

### §7.1 and §7.2.2

| claim | verdict | evidence |
|---|---|---|
| §7.1: all six endpoints ungated, with the stated paths, declaring classes and bodies | **CONFIRMED** | TSV: all six have empty `requiresFunction`/`preAuthorize`/`publicHandler`. Bodies verbatim: `AdviceService.exportInboundNotice(response, advice)` at `AdviceController.java:368`; `billofladingService.exportOutboundBOLs(response, bols, exportDetails)` at `BillOfLadingController.java:327`; `CycleCountController.java:136` `/export`, `:273-278` `itemDataView` → `dtoViewService.getCycleCountItemDataView(cycleCountId)`, `:285-291` `locationView` → `getCycleLocationView(cycleCountId, itemDataId)`, `:298-305` `positionView` → `getCycleCountPositionView(cycleCountId, itemDataId, locationId)`. |
| §7.1: "`AdviceController#exportOutboundBol` ⚠ name/path mismatch" | **CONFIRMED** | `AdviceController.java:357-358`: `@PostMapping(path= "/exportInboundNotice")` on a method named `exportOutboundBol`. |
| §7.1's stated limit: "four confirmed reads, three 'read at the controller level, **service not audited**'" | **CONFIRMED — and I closed it** | The admission is the honest reading, and I extended it two levels: **no write call in any of the three.** `AdviceService#exportInboundNotice` (`:507-551`), `BillofladingService#exportOutboundBOLs` (`:972-1083`), `CyclecountService#exportCycleCounts` (`:185-290`) contain zero `save`/`saveAll`/`delete`/`persist`/`merge`/`flush`/`saveAndFlush` calls, and none carries `@Transactional`. Their `N == 1` delegates are clean too — `BillofladingService#exportOutboundBOL` (`:932-957`) and `CyclecountService#exportCycleCount` (`:298-358`) — as is `FileExportService`. **Limit of my own evidence: I audited two call levels plus `FileExportService`, not the full transitive closure.** |
| §7.2.2: `getTransferLineUnitLoads` does `findByOrderbatchId(orderBatchId).get(0)` with no emptiness check → `IndexOutOfBoundsException`, while `getAvailableTransferLanes` guards the identical call | **CONFIRMED — including the quoted comment** | `TransfersController.java:388-395`: `Customerorder customerOrder = customerorderRepository.findByOrderbatchId(orderBatchId).get(0);`, unguarded. `:366-377`: `List<Customerorder> orders = …; if (orders.isEmpty()) { return Collections.emptyList();   // batch has no order → no lanes (don't 500) }` — the plan's quote is verbatim, comment and spacing included. (Nit: it is two methods away, not three.) |

### §4 and §7.3

| claim | verdict | evidence |
|---|---|---|
| §4: "`origin/main` is at **`cf430ff3`** (2026-08-20); `FunctionGuardInterceptor` **does not exist there**" | **CONFIRMED** | `origin/main` = `cf430ff3`, committed `2026-08-20 01:38:45 -0400`. `git cat-file -e origin/main:…/security/FunctionGuardInterceptor.java` → *"exists on disk, but not in 'origin/main'"*. `git grep -l "FunctionGuardInterceptor\|RequiresFunction" origin/main -- 'src/main/*'` → 0 files; the whole `security/` directory is absent from `main`. `origin/develop` is **245** commits ahead. The release-note warning is correct. |
| §4: "v1 has no function-gating mechanism at all… v2-only. No v1 work." | **CONFIRMED (by policy, not re-measured)** | Consistent with the standing "v1 is reference-only" rule; I did not sweep the v1 repo, as it is out of this lane's scope. |
| §7.3: "`SBDEV-3169-sdr-read-gating.md` §2.7: `ReportController` 15 handlers / 14 ungated → **14 / 13**" | **CONFIRMED as applied** | That file now reads, at line 463: `| ReportController | 14 | **1** — only reprintLabels; the other 13 (10 export* POSTs + 3 *View GETs) ungated |`. Consistent with the corrected value. `sbdocs/` is not in git, so I cannot verify it previously read 15/14. |

---

## Measured: §5.1 P6 baseline (was ⛔ unmeasured)

`mvn -o clean test` in `.claude/worktrees/wms2-api/SBDEV-3142` @ `d434a3e5`:

```
[WARNING] Tests run: 5788, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
[INFO] Total time:  02:19 min
```

**Baseline failure count: 0. Failing classes: none.** `clean` was used, so the total is not inflated by
stale `target/test-classes`. This settles P6 and simplifies §5.2 step 8: the baseline **is** zero, so
"compare failures against P6's baseline, not against zero" collapses to "expect zero" — and any red
after the change is caused by the change. Flip P6 to ✅ with this number.

(Method note: I copied `target/surface-inventory.tsv` out before running, because `clean` deletes it.
Regenerate with `mvn -o test -Dtest=SurfaceInventoryContextTest` if it is needed again.)

---

## Adjacent finding the plan does not record

**`GET` handlers that mutate, on the two controllers this ticket touches.** Ungated, and reachable by
any authenticated `wms_user` — a strictly worse exposure than the reads being gated, and one a browser
prefetch or a crawler can trigger:

`GET /v3/clubLine/runClubLine/{orderBatchId}`, `/clubLine/activateBatch/{orderBatchId}/{locationId}`,
`/clubLine/assignStagingLane/{orderBatchId}/{locationId}`, `/clubLine/unlinkStagingLane/{orderBatchId}`,
`GET /v3/transfers/runTransfer/{orderId}`, `/transfers/activateTransferOrder/{customerOrderId}/{locationId}`,
`/transfers/assignTransferLane/{customerOrderId}/{locationId}`, `/transfers/reassignTransferLane/{customerOrderId}/{locationId}`,
`/transfers/unlinkTransferLane/{customerOrderId}`.

Out of scope for a read-gating ticket, and a T3 in its own right (write authorization), so per the
ticket policy it is **recorded here for Nam, not filed**.

---

## Appendix — the 23 ungated non-`export` handlers on `ClubLineController` / `TransfersController`

Excluded from the 19 by §1.2's `$2=="POST"` term. Verb, path, declaring class, handler, all with empty
`requiresFunction` / `preAuthorize` / `publicHandler` in the TSV.

**Reads of the same class as the 19 (candidates the scope cut silently dropped):**

```
GET  /v3/transfers/skus                                     TransfersController#getSkuView    ← twin of plan row 14
GET  /v3/clubLine/openClubRun                               ClubLineController#getOpenClubRun
GET  /v3/clubLine/closedClubRun                             ClubLineController#getClosedClubRun
GET  /v3/clubLine/activeClubRun                             ClubLineController#getActiveClubRun
GET  /v3/clubLine/inactiveClubRun                           ClubLineController#getActiveClubRun (overload)
GET  /v3/clubLine/availableStagingLanes                     ClubLineController#getAvailableStagingLanes
GET  /v3/clubLine/orderBatch/{orderBatchId}                  ClubLineController#orderBatch
GET  /v3/transfers/openTransfer                             TransfersController#getOpenTransfer
GET  /v3/transfers/allOpenTransfer                          TransfersController#getAllOpenTransfer
GET  /v3/transfers/activeTransfer                           TransfersController#getActiveTransfer
GET  /v3/transfers/closedTransfer                           TransfersController#getClosedTransfer
GET  /v3/transfers/inactiveTransfer                         TransfersController#getInactiveTransfer
GET  /v3/transfers/transferOrder/{customerOrderId}           TransfersController#transferOrder
GET  /v3/transfers/transferOrderByOrderBatchId/{orderBatchId} TransfersController#transferOrderByOrderBatchId
```

**Mutating GETs (the adjacent finding above):**

```
GET  /v3/clubLine/runClubLine/{orderBatchId}                        ClubLineController#runClubLine
GET  /v3/clubLine/activateBatch/{orderBatchId}/{locationId}         ClubLineController#activeBatch
GET  /v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}     ClubLineController#assignStagingLane
GET  /v3/clubLine/unlinkStagingLane/{orderBatchId}                  ClubLineController#unlinkStagingLane
GET  /v3/transfers/runTransfer/{orderId}                            TransfersController#runTransfer
GET  /v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}  TransfersController#activateTransferOrder
GET  /v3/transfers/assignTransferLane/{customerOrderId}/{locationId}     TransfersController#assignTransferLane
GET  /v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}   TransfersController#reassignTransferLane
GET  /v3/transfers/unlinkTransferLane/{customerOrderId}             TransfersController#unlinkTransferLane
```

---

## What this lane could not verify

1. **Every DB-side number in §1.3 and §1.4** — the five-tenant constant presence, holder populations
   (DEV 42–46 of 99, hydra PRD 7 of 9), the 45 zero-function accounts, and the per-account function
   table. No DB access in this lane. The **source** half of §1.4 is confirmed above; the *entitlement*
   half is not, and §1.4's own "Presence is not entitlement" caveat is the right posture.
2. **The pre-correction text of `SBDEV-3169` §2.7** — `sbdocs/` is not in git, so "15 / 14 → 14 / 13"
   is confirmed only in its corrected state.
3. **The full transitive closure of the three §7.1 export services** — audited two call levels plus
   `FileExportService`; clean at every level I read.
4. **The 19.3 s inventory timing** and **AC-1 itself** (P1 is still blocked on the dev Keycloak password).
5. **Whether the 10 exports honour an unbounded `limit`** — relevant only to O1's phrasing.
