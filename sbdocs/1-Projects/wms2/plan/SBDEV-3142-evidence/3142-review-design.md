# SBDEV-3142 — adversarial DESIGN review

**Lane:** r1-critic · **Date:** 2026-08-31
**Target:** `sbdocs/1-Projects/wms2/plan/SBDEV-3142-report-read-gating.md`
**Instruments:** `git show origin/develop:<path>` and `git grep … origin/develop` in `v2/wms2-api` (@ `d434a3e5`), `v2/wms2-web-ui`, `v2/wms2-mobile-ui`. **No `mvn`, no `git stash/checkout/switch`, no worktree writes, no live probe.** Every code claim below is quoted from `origin/develop` object-store content.

---

## Verdict

**The fix as designed is correct and safe to implement. The plan's *scope* claim is not.**

The mechanism analysis is unusually good — §3.2's conclusion, §3.3's instrument-divergence table, §3.4's dead-caller call and §3.5's gate-don't-delete call all survive attack, and three of them I tried hard to break and could not. What does not survive is the plan's **boundary**: the 19 are selected by an `awk` verb filter, not by a property of the read surface, and the plan then tells SBDEV-3169 that it *is* "the MVC half" — a claim that is false by roughly 4x, on 3169's own table, including on the founding complaint's own controller. Two of the five attacks land hard.

**Recommendation:** implement the 19 as designed. Before that, fix §3.6 (F3), fix §3.2's stated rule (F7), add the existing tranche pin (F4), and rewrite §3.6's first bullet and §7.1 so the coverage claim matches the surface (F1, F2). None of these changes the 19 annotations themselves.

---

## Findings

| # | Sev | Section | Finding |
|---|---|---|---|
| F1 | **HIGH** | §3.6 bullet 1, vs 3169 §2.7 | 3142 asserts it is "the MVC half" 3169 depends on. It covers ~19 of the ~69 ungated MVC handlers 3169 enumerated, touches 3 of 3169's 10 controllers, and does **not** touch `ItemDataController` — so the founding complaint stays open after both tickets land. Neither plan owns the remainder |
| F2 | **HIGH** | §1.2 awk, §7.1 | The `$2=="POST"` filter silently drops **~14 ungated GET *reads*** on the two named controllers, incl. `GET /v3/transfers/skus`, which returns the same `List<ClubLineSkuDto>` as the `POST /v3/clubLine/skus` being gated. §7.1's "proposed six" is truncated by the same artifact |
| F3 | **HIGH** | §3.6 bullet 3 | The `GUARDED` rejection rests on two **factually false** premises. After the fix there is no unannotated `ReportController` handler, and the boot assertion keys on `declaringClass` so it would **not** refuse to start. The durable tripwire is rejected for a reason that does not exist |
| F4 | MED-HIGH | §6 | `Sbdev3017TrancheGateContextTest` — the existing `(declaringClass, path)`-keyed pin that **already carries both `/v3/report/reprintLabels` and `/v3/dashboard/reprintLabels`** — is never mentioned. It is a strictly better instrument than the plan's T3/T4, and it has a row-count `@Test` that reds if you add rows without bumping it |
| F5 | MEDIUM | §6 "deliberately-skipped", §7.4 | The `wms2-web-ui` **Cypress** suite is an undocumented direct caller of ≥6 of the 19. The web lane's three-hop method structurally cannot see it. Suite auth is `env.KC_USERNAME`, unpinned in-repo |
| F6 | MEDIUM | §1.2, §7.2-1 | The `m[$5"#"$6]` reduction is **name-keyed with no arity** — the exact trap the repo's own `FunctionGuardStartupAssertion.key()` javadoc documents. §7.2 item 1 is misdiagnosed as a direct consequence |
| F7 | LOW | §3.2 | The stated invariant ("different declaring classes, so no annotation on one reaches the other") is **one-directionally false**. The conclusion holds today; the law does not. This interceptor's own javadoc says why |

**Attacks I could not break — stated explicitly:** #1 (§3.2's central claim, as a conclusion), #3 (function-granularity mismatch, incl. the `exportSkuLocation` hypothesis specifically), and both halves of #4. Details in "What survived", below.

---

## F1 — HIGH — "this is the MVC half" is false by ~4x, and 3169 is depending on it

§3.6 bullet 1:

> "Does not touch SDR. That is SBDEV-3169. The two are complementary and neither closes the founding complaint alone — SBDEV-3169 §2.7 records that gating SDR while the MVC twin stays open closes nothing, and **this is the MVC half**."

3169 §2.7's table is the surface that sentence is answering. Ten controllers, `@RequiresFunction` count zero on all but one:

| controller (3169 §2.7) | handlers | gated | covered by 3142? |
|---|---|---|---|
| `TransfersController` | 17 | 0 | **3** |
| `ClubLineController` | 14 | 0 | **3** |
| `ReportController` | 14 | 1 | **13** ✅ |
| `ItemDataController` | 8 | 0 | **0** |
| `MessageController` | 4 | 0 | 0 |
| `StockRecordController` | 3 | 0 | 0 |
| `SystemController` | 3 | 0 | 0 |
| `UnitloadRecordController` | 2 | 0 | 0 |
| `PickingOrderPositionController` | 2 | 0 | 0 |
| `CustomerOrderPositionController` | 2 | 0 | 0 |

3169 does not merely mention 3142; it **delegates to it and stakes a slice on it**:

> "The MVC read axis is **SBDEV-3142** — this ticket cannot claim to close the founding complaint on its own"
> "It is Slice 3, the operational tranches, **whose value is contingent on SBDEV-3142 landing alongside**."

And 3169 names the decisive case, which 3142 does not gate:

> "`ItemDataController.java:98-100` records that removing a `@RequiresFunction` there 'fell through ALLOWED and survived all 5673 tests' … So **gating SDR `itemdata` does not close §1.1** while `/v3/itemData/detailView` serves the same rows unguarded."

Verified on `origin/develop`: `ItemDataController extends AdminController` at `@RequestMapping("/v3/itemData")` carries no class-level `@RequiresFunction`, no `accessService`/`denyUnless` call anywhere in the file, and its read handlers — `@GetMapping(path = "/detailView", …)`, `/detailViewByKeyword`, `/itemdataDetailsById/{id}`, `/itemdataDetailsByNumber/{itemNumber}`, `/itemdataDetailsByNumberAndClientNumber/{itemNumber}/{clientNumber}` — carry none either. **After SBDEV-3169 and SBDEV-3142 both land, the founding complaint is still open**, because the MVC producer of `itemdata` rows is in neither ticket.

This is the plan's own landmine, at the level below the one it checked. §3.6 correctly enumerates the three *mechanisms* (MVC / SDR / `/rest/**`) — that part is genuinely well done, better than most plans in this estate. But inside the MVC mechanism it fences the controllers the ticket happened to name and then reports that as the mechanism being covered. "A guard fences the mechanism you aimed at" bites on instances too.

**Fix (no change to the 19):** replace "this is the MVC half" with the coverage table above, state that ~50 ungated MVC reads across 7 further controllers are owned by neither ticket, and make that a single §7.1-style **proposed** T3 tranche (policy-compliant: proposed, not filed, one per visit). Also tell 3169 to stop describing Slice 3's value as contingent on 3142 — as scoped, 3142 does not discharge that dependency.

---

## F2 — HIGH — the `$2=="POST"` filter, not a decision, sets the boundary

§1.2's derivation:

```
awk -F'\t' 'NR>1 && $8=="" && $9=="" && (($5=="net.aim_ai.wms.controller.ReportController") \
  || ($2=="POST" && $5 ~ /ClubLineController|TransfersController/)) \
  {m[$5"#"$6]++; p++} END{print length(m), p}'   # -> 19 32
```

Column meanings confirmed against `SurfaceInventoryContextTest.dumpDeployedSurface`'s emit — `bean.getKey(), verbStr, paths, type.getName(), method.getDeclaringClass().getName(), method.getName(), kind, rf, pa, isPublic, guarded` — so `$2`=verb, `$5`=declaringClass, `$6`=method name, `$8`/`$9`=`@RequiresFunction`/`@PreAuthorize`. The filter is read correctly by the plan. The problem is what it does.

`ReportController` gets **no** verb filter — that is how the 3 GET `*View` reads entered scope, and §0 row 2 states the principle: *"the 3 ungated GET `*View` reads on the same controller, dual-mapped the same way, belonging to no other ticket."* The other two named controllers **do** get a verb filter. Nothing in the plan says why the principle stops there.

What the filter drops. Enumerated by reading the `@RequestMapping`/`@GetMapping` annotations in `ClubLineController.java` and `TransfersController.java` at `origin/develop`, then confirming both classes carry **no** class-level `@RequiresFunction` and **zero** occurrences of `accessService` / `denyUnless` / `doesUserHaveAccess` / `AccessDenied` / `PreAuthorize` (grep over the whole file, both files empty result). Pure reads only — the GET-shaped *writes* (`/activateBatch`, `/runClubLine`, `/assignStagingLane`, `/unlinkStagingLane`, `/runTransfer`, `/activateTransferOrder`, `/assignTransferLane`, `/reassignTransferLane`, `/unlinkTransferLane`) belong to the action-gating axis and are correctly out:

| controller | ungated GET reads excluded by the filter |
|---|---|
| `ClubLineController` | `/orderBatch/{orderBatchId}`, `/openClubRun`, `/closedClubRun`, `/activeClubRun`, `/inactiveClubRun`, `/availableStagingLanes` — **6** |
| `TransfersController` | `/transferOrder/{customerOrderId}`, `/transferOrderByOrderBatchId/{orderBatchId}`, `/openTransfer`, `/allOpenTransfer`, `/activeTransfer`, `/closedTransfer`, `/inactiveTransfer`, **`/skus`** — **8** |

**The sharpest one is `GET /v3/transfers/skus`.** Quoted from `TransfersController.java`:

```java
    @RequestMapping(value = "/skus", produces = "application/json", method = RequestMethod.GET)
    public List<ClubLineSkuDto> getSkuView(@RequestParam("orderBatchId") Long orderBatchId,
```

Compare `ClubLineController.java`, which **is** row 14 of the plan's table:

```java
    @RequestMapping(value = "/skus", produces = "application/json", method = RequestMethod.POST)
    public List<ClubLineSkuDto> getSkuView(@RequestBody Map<String,Object> reqMap,
```

Same method name, same return type, same semantic (the SKU view of an order batch), same controller family, both ungated. One is gated by this ticket and one is not, and the only thing separating them is that one author wrote `RequestMethod.POST` and the other wrote `RequestMethod.GET`. A user denied `WEB_UI_VIEW_CLUB_LINE` will be 403'd on `POST /v3/clubLine/skus` and served on `GET /v3/transfers/skus`.

§7.1 inherits the same defect: it is titled *"six more ungated `/v3` **POST-as-query** reads"* and drawn from the same TSV with the same verb assumption, so the plan's own proposed-follow-up list is verb-truncated too. It is not "six more"; it is six more of one verb.

**Fix:** either extend to the 14 (they are single-mapped, all `CLUB_LINE`/`TRANSFER_ORDER`, ~zero marginal design cost and no new function decisions) or state in §1.2 that GET reads on those two controllers were excluded **by decision**, with the reason, so the next reader doesn't have to re-derive it from an awk filter. My method's blind spot: I classified read-vs-mutate from path name, signature and return type, plus bodies for `getActiveClubRun`/`getInactiveTransfer`/`getSkuView`/`getParcelView`; I did not read the bodies of `/orderBatch/{id}`, `/availableStagingLanes`, `/transferOrder/{id}` or `/transferOrderByOrderBatchId/{id}`, so one of those four could be a GET-shaped mutation and belong to the action axis instead.

---

## F3 — HIGH — §3.6's `GUARDED` rejection is built on two false premises

§3.6 bullet 3:

> "Does not add anything to `GUARDED`. Enrolling `ReportController` would make **its one remaining unannotated handler** — and every handler added later — deny fail-closed, and **the boot assertion would refuse to start**."

Both halves are wrong.

**Premise 1 — "its one remaining unannotated handler".** `ReportController` declares exactly 14 handlers (grep of `Mapping|public ` over the file: 11 `@PostMapping`/POST + 3 `@GetMapping`). One (`reprintLabels`) is already annotated. The plan annotates the other 13. That is 14 of 14. **After the fix there is no remaining unannotated handler on `ReportController`.**

**Premise 2 — "the boot assertion would refuse to start".** `FunctionGuardStartupAssertion.findUnannotatedGuardedHandlers`:

```java
            Class<?> declaring = handler.getMethod().getDeclaringClass();
            if (!guarded.contains(declaring)) {
                continue;
            }
```

It keys on `getMethod().getDeclaringClass()` and skips anything whose declarer is not in the set — the same key as the interceptor. So enrolling `ReportController`:
- examines only the 14 `ReportController`-declared handlers → all annotated → **no violations, boots clean**;
- does **not** examine `AdminController`-declared methods registered under `/v3/report/**` (declarer is `AdminController`, skipped);
- does **not** examine `DashboardController`'s own 6 handlers (declarer is `DashboardController`, skipped) — so the mobile-safety property of §3.2 is untouched.

So the rejected option is available, boots, and buys exactly the property this ticket's own history argues for: `ReportController` is the controller that accumulated **13 ungated handlers** over its lifetime, and the interceptor's javadoc says why a tripwire is the answer — *"a new mobile endpoint must not be reachable merely because someone forgot the annotation."* SBDEV-3063's corrected comment in `GUARDED` names the property precisely: *"a DELETION TRIPWIRE."*

**The real trade-off — which the plan should have argued instead:**
1. **A forgotten annotation on a future `ReportController` handler becomes a fleet-wide boot failure**, not a 403. `afterSingletonsInstantiated` throws in production too, and the assertion's own javadoc calls a wrong keying decision *"every replica fails to boot simultaneously."* That is a real cost and a legitimate reason to decline.
2. **The enrollment is partial by construction.** `DashboardController`'s 6 handlers stay outside the tripwire (different declarer), so "ReportController is enrolled" would not mean "the `/v3/dashboard` surface is protected from a forgotten annotation."
3. Consistency: every current `GUARDED` member carries a **class-level** annotation, which `ReportController` cannot have (§3.2). `ReportController` would be the first method-level-only guarded class — supported by the code, but a new shape.

That is a defensible "no". "There is one unannotated handler left and the app won't boot" is not, and it is the reason a reader will not revisit the decision.

---

## F4 — MED-HIGH — the right test already exists and §6 doesn't name it

`src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` is a `(declaringClass, path)`-keyed reflection pin over the deployed mapping, and it **already contains this ticket's dual-mapping precedent**:

```java
        row("ReportController",       "/v3/report/reprintLabels",     "WEB_UI_VIEW_PARCEL_PICKING");
        …
        row("ReportController",       "/v3/dashboard/reprintLabels",  "WEB_UI_VIEW_PARCEL_PICKING");
```

Its resolver is the interceptor's, not the inventory's — which is exactly the honest instrument §3.3 correctly says is needed:

```java
    /** Resolves exactly as {@link FunctionGuardInterceptor} does: method annotation, else DECLARING class. */
    private static String resolve(HandlerMethod hm) { … AnnotatedElementUtils.findMergedAnnotation(m.getDeclaringClass(), …) … }
```

Four reasons it beats the plan's proposed T3/T4:

1. **Path-keyed, never method-name-keyed** — its own javadoc says *"Keyed on (declaring class, path), never on a handler method name"* and lists measured name traps. This directly discharges §1.2's warning about `floowbinMonitorView` and `getDetailView`; the plan raises the hazard and then proposes tests without saying they are immune to it.
2. **T4 becomes non-vacuous and declarative.** The `EXPECTED` value `""` means "must resolve NO gate" — the §0.C OMS carve-out shape. `row("DashboardController", "/v3/dashboard/orderMonitorViewSummary")` and the `replenishMonitorViewSummary` twin pin mobile safety **with no interceptor to install**, so the `standaloneSetup` vacuity trap §6 warns about cannot apply. A class-level annotation on `ReportController` would then red on the *named route*, not on a MockMvc 200 that might be green for the wrong reason.
3. **It catches the drift failure mode**, which is what actually threatens 19 hand-placed annotations: *"someone deletes an annotation in a refactor, or renames a route so a path-keyed rule silently stops matching."*
4. It is the closest thing this repo has to the rule-shaped enrollment F3 discusses, without the boot-failure cost.

⚠️ **And it will red if you touch it carelessly.** A second `@Test` asserts the row count, with a comment reading *"85 = 71 tranche rows + the inherited `/v3/dashboard/reprintLabels` registration of one of them + 2 FixLocationAssignment reads + 8 LabelPrinting reads…"*. Adding 32 rows without bumping that number fails the suite, and §5.2 step 8 ("compare failures against P6's baseline") would present it as an unexplained regression. Either way this test belongs in the plan: as the pin, or as a known-touched file.

---

## F5 — MEDIUM — Cypress is a caller class the web lane's method cannot see

§6 "Deliberately-skipped coverage" and §7.4 describe the web-caller evidence as tracing *"Vuex `export` action → `exportReport.vue` `reportType` switch → owning report component → page."* That method finds page-reachable callers. It cannot find a test harness that calls the API directly, and `wms2-web-ui` has one. From `git grep … origin/develop` in `v2/wms2-web-ui`:

| endpoint (in the 19) | Cypress caller |
|---|---|
| `GET /report/parcelPickingView` | `cypress/e2e/wms/pick-pack/pick-pack-order.cy.js` (5 sites incl. bogus-keyword and SQL-injection rows), `cypress/e2e/wms/scenario1-hybrid/step1-submit-batch.cy.js:135` |
| `GET /report/parcelMonitorView` | `pick-pack-order.cy.js:968, :1314, :1399`, `club/club-line-order.cy.js:611` |
| `POST /clubLine/skus` | `club-line-order.cy.js:361`, `support/helpers/wmsHelpers.js:589` |
| `POST /clubLine/unitLoads` | `club-line-order.cy.js:456`, `wmsHelpers.js:597` |
| `POST /transfers/availableTransferLanes` | `transfer-offsite/transfer-offsite.cy.js:222`, `wmsHelpers.js:1096` |
| `POST /transfers/unitLoads` | `wmsHelpers.js:1115` |

Auth comes from `cypress/support/plugins/auth-task.js:51`/`:79` — `username: env.KC_USERNAME` — which is not pinned in the repo. So whether the club-line, pick-pack, transfer-offsite and scenario1-hybrid suites survive this merge depends on an environment value nobody has checked. If `KC_USERNAME` resolves to something like `estellavasquez` rather than `panderson`, four E2E suites go red at merge and the failures will read as flakiness.

Two consequences, one cheap fix each: add a §5.1 prerequisite recording which functions `KC_USERNAME` holds; and add Cypress to §7.4's evidence limits as the blind spot of the three-hop method. The `/dashboard/export*` claim in the same paragraph ("the web UI never calls them") is unaffected — I confirmed zero Cypress hits on `dashboard/export`.

---

## F6 — MEDIUM — a name-keyed reduction, and §7.2-1 misdiagnosed because of it

`m[$5"#"$6]` keys on `declaringClass#methodName` with **no arity**. The repo has a javadoc'd rule against exactly this, in `FunctionGuardStartupAssertion.key()`:

> "Arity is part of the key deliberately: **a name-only key has a measured escape in this repository**, where a new overload of an already-listed method passed the whole suite."

The headline "**19 distinct methods**" happens to be right — I checked for name collisions within each declaring class among the 19 and found none — but the derivation cannot see one, and the plan presents the figure as reproducible evidence.

It already produced a wrong conclusion. §7.2 item 1:

> "The TSV shows `getActiveClubRun` mapped to **two** paths, `/activeClubRun` and `/inactiveClubRun` — a copy-paste of the handler reference."

Source says otherwise. These are **two distinct overloads**, with different arities and different bodies:

```java
    @RequestMapping(value = "/activeClubRun", …, method = RequestMethod.GET)
    public Map<String, Object> getActiveClubRun(@RequestParam(value = "keyword", …) String keyword,
                                                @RequestParam("page") Integer page, … ) {
        …
        return dtoViewService.getActiveClubRun(keyword, p);
    }

    @RequestMapping(value = "/inactiveClubRun", …, method = RequestMethod.GET)
    public Map<String, Object> getActiveClubRun(@AuthenticationPrincipal Principal principal) {
        List<String> typeNames = new ArrayList<>();
        typeNames.add(WmsConstants.OrderBatchType.CLUB);
        return dtoViewService.getOrderBatchByStateAndType(WmsConstants.State.ORDER_BATCH_ACTIVATED, typeNames);
    }
```

The **bug is real** — a path named `/inactiveClubRun` returning `ORDER_BATCH_ACTIVATED` batches — but it is a misnamed method plus a wrong state constant in a second method, not one handler dual-mapped. Anyone who picks up §7.2-1 as written will look for a duplicate `@RequestMapping` and find nothing. Note also that the plan's supporting argument ("`getInactiveTransfer` exists on the transfers side, so this is an omission, not a convention") is *strengthened* by the correct diagnosis: `TransfersController.getInactiveTransfer` is the correctly-named sibling of this very method.

**Fix:** re-key the reduction on `$5"#"$6"/"arity` (or on path, like the tranche test does), and correct §7.2-1's mechanism.

---

## F7 — LOW — §3.2's invariant is one-directionally false

> "the five mobile-facing GETs have `declaringClass = DashboardController`, while all 13 handlers we annotate have `declaringClass = ReportController`. **Different declaring classes, so no annotation on one reaches the other.**"

The conclusion is right today (see "What survived", #1). The stated law is not, and this interceptor's own javadoc is emphatic about why:

> "`getMethodAnnotation` delegates to `AnnotatedElementUtils.findMergedAnnotation` with `SearchStrategy.TYPE_HIERARCHY`, so **an override of a marked method** — and an implementation of a marked interface method, and a bridge/synthetic method — **INHERITS the marker.** … so do not reason from '`@Target(METHOD)` makes inheritance unwritable'. It does not."

A method-level `@RequiresFunction` on a `ReportController` method **does** reach a `DashboardController` override of that same method, at which point `declaringClass` is `DashboardController` and the annotation still resolves. That direction happens to be the *desirable* one, and no such override exists — but the plan writes its safety argument as a symmetric structural property, so a future reader who adds an override will trust a rule that no longer describes the code. Two sentences fix it: the immunity comes from (a) declarer-keyed resolution **and** (b) the fact that `DashboardController` overrides no `ReportController` method — and (b) is a fact about today's source, not a law.

---

## What survived — attacks I could not break

**#1 — §3.2's central claim: SOUND as a conclusion.** `DashboardController` declares exactly 6 handlers (`orderMonitorViewOverview`, `orderMonitorViewBySectionName` ×2 overloads, `orderMonitorClientViewSummary`, `printToteLabels` (already gated `WEB_UI_VIEW_ORDER_MONITOR`), `replenishMonitorViewSummary`). None carries `@Override`; none shares a name with any `ReportController`-declared method. So there is no override, no bridge/synthetic route, and `AnnotationUtils.findAnnotation(declaring, …)` at step 3 searches **superclasses of the declarer** — upward only, never down into `DashboardController`. A method-level annotation on a `ReportController` method therefore cannot reach a `DashboardController`-declared one, and vice versa. The reverse-direction warning (class-level on `DashboardController` being **silently inert** while the inventory reports it as gated) is correct and is corroborated independently by `Sbdev3017TrancheGateContextTest`'s own javadoc: *"The tool will report `AdminController`'s inherited handlers under those prefixes as **gated**; the interceptor will **not** gate them. The interceptor is the authority."* Only the *reason* is imprecise (F7). Blind spot: I reasoned from source and from the two Spring javadocs quoted in-repo, not from a runtime `getMethodAnnotation` measurement.

**#3 — function granularity: the hypothesis fails, and I found no genuine mismatch.** The specific concern named — that `exportSkuLocation` (a SKU→location map) under `WEB_UI_VIEW_LOCATION_OVERVIEW` leaks SKU data to someone entitled only to locations — does not hold. `WEB_UI_VIEW_LOCATION_OVERVIEW` occurs **exactly once** in `wms2-web-ui/util/appMenuList.js`, and it is on that report itself:

```js
      { text: 'SKU Location Report', to: '/reports/sku-location-report', fn: 'WEB_UI_VIEW_LOCATION_OVERVIEW' }, // 24
```

It appears nowhere else in `wms2-web-ui` outside `test/support/webFunctionConstants.js`, and **nowhere at all** in `wms2-mobile-ui`. So the constant is not shared with a locations-only screen; despite its name it *is* the SKU-location report's function. I checked every row the same way (per-`fn` occurrence count over `appMenuList.js`): only `WEB_UI_VIEW_CLUB_LINE` and `WEB_UI_VIEW_TRANSFER_ORDER` appear more than once, and their extra sites (`/outbound/club`, `/processes/club-run`, `/outbound/transfer`, `/processes/transfer-picking`, plus the route map at lines 167–181) are all the same workflow the endpoints serve. Rows 11–13 reusing rows 5/6/7's functions is right — and note `reprintLabels` already sits on `WEB_UI_VIEW_PARCEL_PICKING` with a measured justification in source (*"that constant reaches 38 users while this screen reaches 47; gating on it 403s 7 LIVE users"*), so the precedent is not just structural, it is calibrated.

Two observations, offered as notes rather than findings. (a) The design principle — *gate the endpoint at exactly the entitlement the UI already asserts* — is the correct one, but it means the API now **inherits the menu's granularity**, so a future menu granularity error becomes an API authorization error. Worth one sentence in §3.1. (b) `UtilRestController` seeds `WEB_UI_VIEW_LOCATION_OVERVIEW` to `role_outbound_manager` (`…findByName(WmsConstants.FunctionEnum.WEB_UI_VIEW_LOCATION_OVERVIEW)…, role_outbound_manager.getId()`), so an outbound-manager role carries the SKU-location report by seed. §1.4's measured 42–46 holders per constant bounds the spread, so this is not a live problem — but it is why the per-constant holder counts, not just presence, matter in the release note, which §1.4 already says.

**#4a — §3.4's dead-caller call: VERIFIED CORRECT, and I tried to break it.** `store/outbound/outboundBols.js` does contain `const results = await this.$axios.$post('/clubLine/skus', data)` inside `getItemInfo`, and there is **no** `dispatch('outbound/outboundBols/getItemInfo', …)` anywhere in the repo. My near-miss: `components/outbound/bol/outboundBolDetailsTable.vue:202` dispatches `'outbound/club/getItemInfo'` **from a BOL component**, which looked like a live BOL-screen caller of `/clubLine/skus`. It is not — `store/outbound/club.js#getItemInfo` hits `/customerOrderPosition/detailsByOrderId`, a different endpoint entirely. So the §3.4 decision (gate `WEB_UI_VIEW_CLUB_LINE`, delete the dead action, don't widen to an ANY-of) stands, and the ANY-of fallback it offers is well-precedented anyway (`UnitLoadController` already declares `{WEB_UI_VIEW_CLUB_LINE, WEB_UI_VIEW_TRANSFER_ORDER}`). One addition: the Cypress club suite calls `/clubLine/skus` directly (F5), so "delete the dead action" does not remove the last caller.

**#4b — §3.5's gate-don't-delete call on `TransfersController.getParcelView`: SOUND.** Independently confirmed: no caller in `wms2-web-ui` (`git grep` over `origin/develop`, including the `.gitignore`d `reports/` trees the plan's F0 warns about) and none in `wms2-mobile-ui` (a single grep for `parcelView|parcelPickingView|parcelMonitorView|clubLine/|transfers/|report/export|dashboard/export` over `origin/develop` returned **zero** rows — which also corroborates the mobile evidence lane's negative result). Its body is `return dtoViewService.getOrderDetailView(orderBatchId );`, identical to `ClubLineController.getParcelView`. Gating it with its siblings' function, and keeping API-surface removal out of an authorization fix, is the right call.

**Also sound, worth saying:** §3.3's instrument-divergence table (`getMethod().getDeclaringClass()` vs `hm.getBeanType()`) is exactly right and is independently confirmed in two places in `src/test` — `SurfaceInventoryContextTest`'s own "Gate detection is ANNOTATION-ONLY … the ungated count is an upper bound" limitation block, and the tranche test's "**The interceptor is the authority**" warning. §1.3's insistence on a *differential* account (`estellavasquez`) over a zero-function account is the single best methodological decision in the plan. §4's "develop-only, NOT on prd" caveat is correct — `FunctionGuardInterceptor` does not exist on `origin/main`.

---

## Blind spots of this review, inline

- **No execution.** No `mvn`, no TSV regeneration, no live probe, no DB query (per lane instructions). Every claim is source-derived from `origin/develop` object-store reads. Where I contradict the plan's TSV-derived figures (F2, F6) I am reasoning from the emit statement in `SurfaceInventoryContextTest` plus the controller sources, not from the TSV file.
- **F2's enumeration** rests on reading `@*Mapping` annotations in two files plus a whole-file grep for in-body gates. It would miss a gate applied by a servlet filter, by `SecurityConfiguration.authorizeHttpRequests` (which, per `Sbdev3017OmsCarveOutSourceContractTest`, **no** Spring-context test in this repo can observe), or by an interceptor other than `FunctionGuardInterceptor`. It would also miss a read handler declared on a *third* class and registered under these prefixes.
- **F1's "~69" and "~50"** are 3169 §2.7's numbers, not mine; I verified only the `ReportController` (14/1) and `ItemDataController` (ungated) rows directly.
- **F5** establishes that Cypress calls these endpoints. It does **not** establish that the suites will break — that depends on `KC_USERNAME`, which I could not resolve from the repo.
- **"exactly once" in F3/#3** was derived by `git grep` over `origin/develop` in each UI repo plus an occurrence count over `appMenuList.js`'s `fn:` fields; it is blind to a function name assembled at runtime from fragments, and to any gate expressed outside `appMenuList.js` / `middleware/require-function.js`.
