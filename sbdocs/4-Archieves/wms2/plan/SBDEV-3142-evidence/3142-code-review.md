# SBDEV-3142 — code review of the implementation diff

**Reviewer lane:** x2-review · **Date:** 2026-08-31
**Under review:**
- `/.claude/worktrees/wms2-api/SBDEV-3142` @ `eabdf1e1` (2 commits on `origin/develop` @ `c8b3634f`)
- `/.claude/worktrees/wms2-web-ui/SBDEV-3142` @ `df7a1e4` (1 commit, a deletion)
- Plan: `sbdocs/1-Projects/wms2/plan/SBDEV-3142-report-read-gating.md`

Read-only review. No `mvn`, no git state mutation.

---

## Verdict

**APPROVE with fixes.** The core of the ticket is correct.

- **All 20 function assignments are right.** I re-derived every one independently from
  `util/appMenuList.js` and from an untruncated caller trace, and all 20 agree with the plan's §3.1
  table and with the diff. Zero discrepancies.
- **No over-gating found**, in either UI or in OMS. I closed the plan's own admitted sweep gap
  (`omsv2-UI`, `oms-laravel-api`) — both are clean.
- **The tests are not vacuous.** `mappedPaths()` is complete for the annotations actually in use and
  fails *closed* for any it does not read. `assertFunction`'s `hasSize(1)` does fail closed if a
  mapping moves. `T1b` and `T4` are honestly labelled as pre-fix-passing controls. The 123 arithmetic
  is right (85 + 26 + 3 + 4 + 5 = 123), the 33 paths are right, and the 5 `DashboardController`
  UNGATED rows enumerate *all five* of that class's own read handlers.
- **The mobile-safety pin (T4) is the right instrument and is sound.** I verified the mechanism it
  claims: `AnnotationUtils.findAnnotation(Class, …)` walks superclasses, so a class-level annotation
  on `ReportController` *would* resolve for `DashboardController`'s own handlers — and
  `FunctionGuardArchTest.functionsOn` uses plain `Class#getAnnotation`, which does **not** (the
  annotation is not `@Inherited`). So the rail really would stay green while the runtime denied, and
  `T4` + the 5 tranche rows really are the only detectors.

Nothing here is High. One Medium (a merge-readiness gap in the plan, with an operational
consequence), four Lows to fix in-pass, and two items that are the owner's call, not mine to change.

---

## Findings

| # | Sev | Where | What |
|---|-----|-------|------|
| M1 | **Medium** | plan §7 "The Cypress suite is a direct caller" | Cypress table names 5 of 20 gated endpoints; the real count is **7**, and the two missed have the widest footprint (14 more spec files). Two more functions must be on the pre-merge grant check. |
| L1 | Low | `ReportReadGateUnitTest` `setUp` | Sets `SecurityContextHolder` authentication and never clears it. Repo convention (5 sibling classes, 3 with a javadoc naming the measured hazard) is an `@AfterEach clearContext()`. |
| L2 | Low | `ReportReadGateUnitTest.T1b` | `isNotEqualTo(403)` is satisfied by a 500 — the exact trap `setUp`'s own comment names. T4 has a `verify(never())` backstop; T1b has none. |
| L3 | Low | `ReportReadGateUnitTest` T2c / T2d | The ClubLine and Transfers endpoint lists are inline `List.of(...)`; only `EXPORTS`/`VIEWS` get the `T0` anti-shrink pin. Same defect class T0 exists to prevent, left half-closed. |
| L4 | Low | `ReportReadGateUnitTest.mappedPaths` javadoc | "across the four mapping annotations in use here" — it reads **three** (`PostMapping`, `GetMapping`, `RequestMapping`). |
| D1 | Design → owner | plan §3.6 vs §5.2 | §3.6 recommends enrolling `ReportController` in `GUARDED` "in the same PR, as the final step"; §5.2's checklist does not, and the diff does not. The plan contradicts itself. **Not silently redesigning — owner decides.** |
| I1 | Info | `FunctionGuardArchTest` AC-4 | Pre-existing rail blind spot the diff walks through: the 13 new gates register under `/v3/dashboard/*` but are invisible to the reviewed-allow-list rule. Recorded, not a defect in this diff. |
| I2 | Info | plan §3.5 | Row 18's "no caller found" caveat can now be **closed** — I swept the two repos neither lane swept. |

---

### M1 — the Cypress blast radius is understated by two endpoints and 14 files (Medium)

Plan §7 states:

> `wms2-web-ui`'s **Cypress e2e suite calls five of the 20** directly

and lists `clubLine/skus`, `clubLine/unitLoads`, `transfers/unitLoads`,
`transfers/availableTransferLanes`, `transfers/skus`. Its action item is therefore:

> confirm that account's grants before merge … `WEB_UI_VIEW_CLUB_LINE` and `WEB_UI_VIEW_TRANSFER_ORDER`

**That is wrong. It is seven of the 20, and the two omitted are the largest.** Measured in the
wms2-web-ui SBDEV-3142 worktree with `command grep -rl -- "<path>" cypress/` (one line per endpoint,
file counts, untruncated):

```
10 files  /report/parcelMonitorView      <- gated WEB_UI_VIEW_PARCEL_MONITOR, NOT in the plan's table
 4 files  /report/parcelPickingView      <- gated WEB_UI_VIEW_PARCEL_PICKING, NOT in the plan's table
 2 files  /clubLine/skus
 2 files  /clubLine/unitLoads
 2 files  /transfers/availableTransferLanes
 1 files  /transfers/unitLoads
 1 files  /transfers/skus
 0 files  /clubLine/parcels, /transfers/parcels, and all 10 export* paths
```

Representative call sites, quoted rather than cited by line so they survive a shift:

- `cypress/support/helpers/wmsHelpers.js` — `return cy.wms('GET', '/report/parcelMonitorView', { qs });`
- `cypress/support/helpers/wmsHelpers.js` — `return cy.wms('GET', '/report/parcelPickingView', { qs });`
- `cypress/e2e/wms/pick-pack/pick-pack-order.cy.js` — `name: 'GET /report/parcelPickingView (happy, after polling)'`
- `cypress/e2e/wms/smoke/phase4-palletize.cy.js` — `it('step 4.5: parcelMonitorView reports state=Palletized and palletName matches', …)`

Because both are reached through a **named helper** (`wmsHelpers.js`), the fan-out is wider than the
file count suggests — every consumer of that helper inherits the dependency.

**Consequence.** If the Cypress `KC_USERNAME` account does not hold
`WEB_UI_VIEW_PARCEL_MONITOR` and `WEB_UI_VIEW_PARCEL_PICKING`, the e2e suite starts 403-ing in 14
files that the plan's pre-merge check would never have thought to cover — and the failures land in
smoke phases 3–7, which read as a pipeline regression rather than an authz grant gap.

**Fix (no API code change):** amend the plan's §7 table to seven rows and extend the pre-merge grant
check to **four** functions: `WEB_UI_VIEW_CLUB_LINE`, `WEB_UI_VIEW_TRANSFER_ORDER`,
`WEB_UI_VIEW_PARCEL_MONITOR`, `WEB_UI_VIEW_PARCEL_PICKING`.

*Derivation and blind spot:* file counts are from `command grep -rl` over `cypress/` (ignore-aware
tools are unsafe in this repo — `.gitignore` hides `reports/`). A spec that assembles the path by
string concatenation would not be counted; I did not find any, but I did not prove their absence.

---

### L1 — `SecurityContextHolder` is set and never cleared

`ReportReadGateUnitTest`:

```java
SecurityContextHolder.getContext().setAuthentication(
        new UsernamePasswordAuthenticationToken("truckloading", "n/a", Collections.emptyList()));
```

There is no `@AfterEach`, and neither `BaseControllerUnitTest` nor `BaseUnitTest` clears it (verified:
zero `clearContext` occurrences in either file). `SecurityContextHolder` is a `ThreadLocal` and
Surefire reuses threads across classes.

This repo already has the convention and the measured rationale. `FileImportControllerTest`:

> `SecurityContextHolder` in `setUp()` and leave it there. Surefire reuses threads,
> … `SecurityContextHolder.getContext().setAuthentication(...)` silently mutated the mock

and `UserControllerPublicHandlerUnitTest` / `UserControllerAffiliatedGroupsUnitTest`:

> SecurityContextHolder is a ThreadLocal and surefire reuses threads across classes; a context left
> behind by one class leaks into another

Five classes clear it; two sibling guard tests (`StockUnitControllerActionGuardUnitTest`,
`PutawayConfigActionGuardUnitTest`) do not, so the precedent is mixed — but the documented side is
the one with a measured failure behind it.

**Fix:**

```java
@AfterEach
void clearAuthentication() {
    SecurityContextHolder.clearContext();
}
```

---

### L2 — `T1b` can pass on a 500

`gatedEndpointsAreReachableWhenTheFunctionIsHeld` asserts only `isNotEqualTo(403)` on all three
endpoints. `setUp`'s own comment names exactly this hazard:

> A 500 would satisfy `isNotEqualTo(403)` and pass for the wrong reason — the same trap
> `ShipperIdControllerActionGuardUnitTest` documents

`T4` is covered — its real detector is `verify(accessService, never()).checkAnyAccess(...)`, which a
500 does not satisfy. **`T1b` has no such backstop.** It is the *only* over-gating detector in the
class, so a future change that makes one of its three endpoints blow up under the mocks would leave
it green while it claims "holding the function reaches the handler".

All three already return 200 under the current stubs, so the stronger assertion is free:

- `exportInventory` is `void` and `reportService.exporIventoryReport(...)` is a void mock → 200
- `POST /v3/clubLine/skus` → `customerorderBatchService.getClubLineSKUOverview` stubbed to empty list → 200
- `GET /v3/transfers/skus?orderBatchId=1` → `transferOrderService.getSKUOverview` stubbed to empty list → 200

**Fix:** change the three `isNotEqualTo(403)` to `isEqualTo(200)` in `T1b`. Leave `T4`'s two as they
are — there the looser form is deliberate and the `never()` carries the weight.

---

### L3 — the anti-shrink pin covers `EXPORTS`/`VIEWS` but not the ClubLine/Transfers lists

`T0` exists because, in its own words:

> a shortened list would otherwise make every loop below iterate fewer endpoints and still pass

That reasoning applies verbatim to `T2c`'s `List.of("/skus", "/unitLoads", "/parcels")` and `T2d`'s
`List.of("/unitLoads", "/parcels", "/availableTransferLanes")`, which are inline and unpinned.
Deleting an element from either silently drops a 403 assertion with nothing red.

The damage is bounded — `everyGatedHandlerRequiresExactlyItsScreensFunction` enumerates all 20
explicitly and the tranche test pins all 33 paths, so only the *status* check is lost, not the
function pin — but it is the same defect class `T0` was written to close, left half-closed.

**Fix:** hoist both to `private static final List<String> CLUB_LINE_READS` / `TRANSFERS_POST_READS`
and add `hasSize(3)` for each to `T0`.

---

### L4 — javadoc count is wrong

`mappedPaths`:

> ⚠ Unions `value()` AND `path()`. … Every path this method is mapped at, **across the four mapping
> annotations in use here**

It reads three: `PostMapping`, `GetMapping`, `RequestMapping`. The behaviour is correct — an
unread annotation type yields an empty set and the `hasSize(1)` above goes red, so it fails closed —
but the number is wrong and a reader auditing the union will look for a fourth. **Fix: "three".**

---

### D1 — `GUARDED` enrollment: the plan contradicts itself (owner's call)

Plan §3.6:

> **Recommendation: enroll `ReportController` in `GUARDED` in the same PR, as the final step** — after
> the 13 annotations, so the boot assertion is green at every commit.

Plan §5.2, the implementation checklist, step 3:

> Add the 20 annotations. Method-level only (§3.2).

No enrollment step. The diff follows §5.2.

I checked that §3.6's safety argument holds: `ReportController` declares 14 handlers, all 14 are now
annotated (13 here + `reprintLabels` from SBDEV-3017), and `FunctionGuardStartupAssertion` keys on
`getMethod().getDeclaringClass()`, so `DashboardController`'s own six handlers are skipped and cannot
become boot violations. Enrolling would be safe and would buy the deletion tripwire.

**This disputes the plan's design, not its code, so I am not proposing a silent change.** The owner
should decide whether §3.6 or §5.2 is authoritative and reconcile the two sections either way — as it
stands the plan tells the next reader two different things.

---

### I1 — the AC-4 rail cannot see 13 of these gates (pre-existing, recorded)

`FunctionGuardArchTest.noSharedControllerCarriesRequiresFunction` iterates
`SHARED_CONTROLLERS = {StockUnitController, DashboardController, ReplenishOrderController, UnitLoadController}`
and scans `c.getDeclaredMethods()`.

`DashboardController#printToteLabels` had to clear the reviewed-allow-list bar in
`REVIEWED_SHARED_METHOD_GATES` ("every OTHER caller across `wms2-web-ui` has been enumerated with an
UNTRUNCATED grep"). The 13 new gates are declared on `ReportController` — `DashboardController`'s
**superclass** — so they register under `/v3/dashboard/*` alongside `printToteLabels` yet are
invisible to that rule.

Also worth recording: the rule's class-level half is blind too. `functionsOn` uses plain
`element.getAnnotation(...)`, and `@RequiresFunction` is not `@Inherited`, so a class-level
annotation added to `ReportController` would **not** trip `offenders.add(name + " [class-level]")` on
`DashboardController`. This is exactly why `T4` and the 5 UNGATED tranche rows are load-bearing — I
confirm the diff's claim on that point rather than disputing it.

The tranche test does pin all 26 `ReportController` paths, so coverage is not lost. Whether to widen
`SHARED_CONTROLLERS` (which would mean 20 more allow-list entries) is a scope decision, not a fix I
should make inside this ticket.

---

### I2 — the plan's §3.5 sweep gap is now closed

Plan §3.5 on `TransfersController.getParcelView`:

> ⚠️ **This is "no caller found", not "there is no caller."** Neither lane swept `omsv2-UI` or
> `oms-laravel-api`.

I swept both. Zero hits on any of the 20 endpoint paths:

- `omsv2-UI` @ `origin/main` — 0 hits; positive control `git grep -li "wms"` → **50 files**
- `oms-laravel-api` @ `origin/develop` — 1 hit, and it is a changelog line
  (`docs/releases/owl-v2.0.100/developer.md`: *"fix transfers availableTransferLanes — resolve
  customerorder id from batch id"*), not a caller; positive control → **313 files**

So row 18 is genuinely uncalled across all four consumers, and the "by analogy, not evidence-backed"
caveat can be downgraded. `omsv2-UI` has no `origin/develop` — its default branch is `origin/main`;
worth noting because a sweep written against `origin/develop` there returns a silent zero.

---

## What I verified and found clean

### 1. All 20 function assignments (attack #1)

Derived independently from `wms2-web-ui/util/appMenuList.js` using `command grep` (never a bare
`grep` — `.gitignore` hides `reports/` from ignore-aware tooling). Every row matches the diff:

| endpoint | annotation in diff | `appMenuList.js` entry |
|---|---|---|
| `/report/exportInventory` | `WEB_UI_VIEW_INVENTORY_RECORD` | `{ text: 'Inventory Report', to: '/reports/inventory-report', fn: 'WEB_UI_VIEW_INVENTORY_RECORD' }` |
| `/report/exportLock` | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | `'Lock Report' … 'WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW'` |
| `/report/exportReceiving` | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | `'Receiving Report' … 'WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW'` |
| `/report/exportSkuLocation` | `WEB_UI_VIEW_LOCATION_OVERVIEW` | `'SKU Location Report' … 'WEB_UI_VIEW_LOCATION_OVERVIEW'` |
| `/report/exportFlowbin`, `/report/flowbinMonitorView` | `WEB_UI_VIEW_FLOWBIN_MONITOR` | `'Flowbin Report' … 'WEB_UI_VIEW_FLOWBIN_MONITOR'` |
| `/report/exportParcelPicking`, `/report/parcelPickingView` | `WEB_UI_VIEW_PARCEL_PICKING` | `'Parcel Picking Report' … 'WEB_UI_VIEW_PARCEL_PICKING'` |
| `/report/exportOutboundParcel`, `/report/parcelMonitorView` | `WEB_UI_VIEW_PARCEL_MONITOR` | `'Outbound Parcel Report' … 'WEB_UI_VIEW_PARCEL_MONITOR'` |
| `/report/exportStockUnitRecord` | `WEB_UI_VIEW_STOCK_UNIT_RECORD` | `'Stock Unit Record' … 'WEB_UI_VIEW_STOCK_UNIT_RECORD'` |
| `/report/exportContainerRecord` | `WEB_UI_VIEW_UNIT_LOAD_RECORD` | `'Container Record' … 'WEB_UI_VIEW_UNIT_LOAD_RECORD'` |
| `/report/exportStorageLocations` | `WEB_UI_VIEW_STORAGE_LOCATION` | `'Storage Locations' … 'WEB_UI_VIEW_STORAGE_LOCATION'` |
| `/clubLine/{skus,unitLoads,parcels}` | `WEB_UI_VIEW_CLUB_LINE` | `'Club'`, `'Club Run'`, and `'/outbound/club/*'` EXTRA_ROUTES, all `WEB_UI_VIEW_CLUB_LINE` |
| `/transfers/{skus,unitLoads,parcels,availableTransferLanes}` | `WEB_UI_VIEW_TRANSFER_ORDER` | `'Transfer'`, `'Transfer Picking'`, `'/outbound/transfer/*'`, all `WEB_UI_VIEW_TRANSFER_ORDER` |

All 12 constants exist in `WmsConstants.FunctionEnum` (verified by grep against
`src/main/java/net/aim_ai/wms/service/WmsConstants.java`; each line is a `public static final String
X = "X"` self-naming pair, so no value/name skew).

### 2. Over-gating (attack #2)

Traced every caller of every gated path, untruncated, across four repos:

- **`wms2-web-ui`** — every caller sits on a page whose menu gate is the same constant. The
  non-obvious ones I chased down and cleared:
  - `store/reports/data.js` also posts `/report/exportReceiving`. Reachable only via
    `components/reports/popups/exportReport.vue`'s `reportType == 'Data'` branch, and its page
    (`pages/reports/data-report.vue`) was deleted by B-25 — `test/util/appMenuList.spec.js`'s
    `theSixDeadAndShadowPagesAreDeleted` pins that. No live component passes `'Data'`. **Dead, not a
    cross-gate caller.**
  - `components/reports/popups/exportReport.vue` is imported by nine report components, so it *looks*
    like a shared funnel. It is not — it dispatches on `reportType`, one branch per store module.
  - `components/reports/skuLocationReport.vue` and
    `components/receiving/open/create/createPurchaseOrderSkuTable.vue` both dispatch
    `reports/inventory/getReportInfo` from non-INVENTORY screens — but that action GETs
    `/itemData/itemdataDetailsById/{id}`, **not** a gated path.
  - `components/outbound/club/batchDetails.vue` dispatches `processes/clubRuns/getItemInfo`
    (→ `POST /clubLine/skus`) from `/outbound/club/*`, which is `WEB_UI_VIEW_CLUB_LINE`. Same gate.
  - `components/receiving/open/popups/selectLanePop.vue` references `processes/clubRuns/` — every
    such line is commented out, and all are `commit`, not `dispatch`.
- **`wms2-mobile-ui`** @ `origin/develop` — **zero** callers of `/report`, `/clubLine` or
  `/transfers`. Its only WMS-dashboard traffic is the two `DashboardController`-declared summaries
  this diff deliberately leaves ungated:
  `pages/replenish.vue` → `this.$axios.$get('/dashboard/replenishMonitorViewSummary')` and
  `store/picking.js` → `this.$axios.$get('/dashboard/orderMonitorViewSummary')`.
  Positive control: `$axios` appears in 33 files, so the zero is absence, not a broken search.
- **`omsv2-UI`** @ `origin/main` and **`oms-laravel-api`** @ `origin/develop` — see I2.

**Blind spot, stated:** all four sweeps are lexical over literal path strings. A caller that builds
its URL by concatenation, or a third-party/manual integration, would be invisible to every one of
them.

### 3. The test class (attack #3)

- **`mappedPaths()` is complete and correct for the annotations in use.** All 20 handlers use
  `@PostMapping(path=…)`, `@GetMapping(path=…)` or `@RequestMapping(value=…, method=…)` — I checked
  each of the three controllers' mapping lines. The union of `value()` and `path()` is necessary
  exactly as documented: raw `Method#getAnnotation` does not resolve `@AliasFor`, and
  `ClubLineController`/`TransfersController` use `value` while `ReportController` uses `path`.
  `@PutMapping`/`@DeleteMapping`/`@PatchMapping` are unread — but that **fails closed**: an unread
  annotation yields an empty set, no method matches, and `hasSize(1)` goes red. (Count in the javadoc
  is wrong — L4.)
- **`assertFunction`'s `hasSize(1)` does fail closed if a mapping moves.** It asserts the size
  *before* dereferencing `matches.get(0)`, so a renamed path reds with a named message rather than
  passing vacuously. The "exactly one, never `findFirst()`" rationale is correct — `getDeclaredMethods()`
  order is unspecified.
- **T1b and T4 are honestly labelled.** Both carry `CONTROL (passes pre-fix)` in the `@DisplayName`
  and a javadoc saying so. T4's javadoc goes further and states the thing most reviewers would miss:
  its two *status* assertions do not detect the M4 mutant, only the `verify(never())` does. That is
  accurate.
- **The `never()` matcher is correct, and deliberately so.**
  `verify(accessService, never()).checkAnyAccess(any(), any(String[].class))` against
  `public AccessDecision checkAnyAccess(String username, String... functions)`. This is **not** an
  `NeverMatcherNullBlindnessArchTest` (SBDEV-3170) violation: its `REFERENCE_NULL_BLIND` regex matches
  `[A-Za-z_][\w.]*\s*\.\s*class`, which `String[].class` does not, and its javadoc says so explicitly
  — *"ARRAY classes are deliberately NOT matched … bare `any()` in a varargs slot matches exactly one
  element … Keep `any(X[].class)`."* The form used here is the prescribed one.
- **The strict/lenient split is right.** `denyEverything()` is a strict stub and is always consumed
  in T2a–T2d/T3; the two allow paths use `lenient()` because pre-fix the guard never consults
  `AccessService`, so a strict stub would raise `UnnecessaryStubbingException` and mask the verdict.
- **The `BATCH_BODY` boolean flags are load-bearing**, as claimed:
  `getClubLineUnitLoads` reads `(Boolean) reqMap.get("onlyStagingLocation")` and
  `getTransferLineUnitLoads` reads `("onlyTransferLocation")`, so an absent key would NPE into a 500
  and surface as a JUnit ERROR rather than the status assertion.
- **`@DisplayName` compliance.** No new name trips `TestIdentifierCountArchTest`'s
  `DISPLAY_NAME_COUNT` (`\b(?:the|exactly|all)\s+([2-9]|[1-9][0-9])\s+[a-z]`) — the bare `403`/`200`
  in the names are not preceded by the/exactly/all. `everyGatedHandlerRequiresExactlyItsScreensFunction`
  does not trip `METHOD_NAME_COUNT` either (`Exactly` must be followed by a number-word).
- **Constructors match.** All four `new XController(...)` calls in `setUp` match the real signatures.
- **No existing test breaks.** `ReportControllerUnitTest`, `ClubLineControllerUnitTest` and
  `TransfersControllerUnitTest` all use plain `setupMockMvc(...)`, which installs **no** interceptor —
  so none of them acquires a gate. `DashboardControllerUnitTest` sets up no MockMvc at all.

### 4. The 38 tranche rows (attack #4)

- **All 33 gated paths are correct.** `DashboardController extends ReportController` and only that
  one class does (grepped `extends ReportController|ClubLineController|TransfersController|DashboardController`
  across `src/main`), so 13 × 2 + 3 + 4 = **33** is exact, not an estimate.
- **The 5 `DashboardController` UNGATED rows are right and complete.** That class declares exactly
  six handlers: `printToteLabels` (already pinned gated in the original 85) plus five GET reads —
  `/orderMonitorViewSummary`, `/replenishMonitorViewSummary`, `/orderMonitorClientViewSummary`,
  `/orderMonitorViewBySectionName/{sectionName}` and the typo'd
  `/orderMonitoClientrViewBySectionName/{clientName}/{sectionName}`. All five appear, and the path
  strings match the mappings character-for-character including the typo.
- **`row(cls, path)` with no functions really does assert UNGATED.** `String.join("+", new
  TreeSet<>(Set.of()))` is `""`, and the harness compares it against `resolve(hm)`, which also returns
  `""` when no annotation resolves. `resolve` uses
  `AnnotatedElementUtils.findMergedAnnotation(m.getDeclaringClass(), …)`, whose `TYPE_HIERARCHY`
  strategy **does** walk to `ReportController` — so the M4 mutant reds all five rows with a named
  route. Correct instrument.
- **Arithmetic:** 26 + 3 + 4 + 5 = 38; 85 + 38 = **123**. `assertThat(EXPECTED).hasSize(123)` matches,
  and it lives in its own `@Test` so a drift failure cannot pre-empt the shrink check.
- The comment's warning that the pin is keyed on **path**, not method name, is well-founded:
  `/flowbinMonitorView` is served by `floowbinMonitorView` (sic) and `/parcelPickingView` by
  `getDetailView`.

### 5. Things the diff breaks that no test covers (attack #5)

- **Nothing found in the API.** The three annotated controllers are not in
  `FunctionGuardInterceptor.GUARDED`, so no unannotated sibling handler fail-closes; the boot
  assertion (`FunctionGuardStartupAssertion`) only inspects `GUARDED` declaring classes.
  `SurfaceInventoryContextTest` asserts only `total > 200`. `ActionGuardAnnotationContractUnitTest`'s
  `hasSize(13)` is scoped to `StockUnitController`/`UnitLoadController`. `FunctionGuardArchTest`
  AC-4 is blind to these gates (I1) rather than red on them.
- **Client-side 403 handling already works for the blob exports.** Ten of the 20 are fetched with
  `responseType: 'blob'`, so a problem+JSON body would arrive unreadable — but
  `wms2-web-ui/plugins/axios.js` discriminates on the **header**, not the body
  (`const deniedFunction = readAuthzDeniedHeader(error.response)` … `if (error.response.status === 403
  && deniedFunction)`), which the interceptor sets. So the retry-then-logout path is correctly
  suppressed. The user still sees the store's generic *"network or server issue"* toast rather than a
  permission message, but that is the estate's existing 403 UX, not something this diff introduces.
- **The Cypress exposure is M1, above.**

### 6. The `wms2-web-ui` deletion commit

`df7a1e4` removes `store/outbound/outboundBols.js#getItemInfo`. Justified and clean:

- zero dispatchers remain (`command grep -rn "outboundBols/getItemInfo"` → nothing; `outboundBols/`
  otherwise has 20 live dispatch/commit sites, so the search works)
- no orphan state — `command grep -n "itemInfo" store/outbound/outboundBols.js` → nothing
- the commit message's claim that it committed a `setItemInfo` this module does not define is
  consistent with what remains in the file

The plan's §3.4 alternative (an ANY-of `{CLUB_LINE, BILL_OF_LADING}` gate) was correctly not taken —
deleting dead code beats permanently widening an endpoint for a caller nobody has.

---

## Recommended action before merge

1. Fix **L1–L4** in this pass (standing instruction: Lows are fixed, not handed back).
2. Amend the plan and the ticket for **M1**, and run the grant check against **four** functions.
3. Take **D1** to the owner: reconcile plan §3.6 with §5.2, then either enroll `ReportController` in
   `GUARDED` or strike the §3.6 recommendation. Do not leave the two sections disagreeing.
4. Optionally record **I2** in the plan — §3.5's caveat is now measurably closed.
