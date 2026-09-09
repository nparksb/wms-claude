# SBDEV-3154 — authorization lane review

- **Plan reviewed:** `sbdocs/1-Projects/wms2/plan/SBDEV-3154-admin-action-console-gating.md` (220 lines, DRAFT 2026-09-01)
- **Derived from:** `wms2-api` `origin/develop` = `2e9ddcfafe42de97dbe6dc6d1459bc7d3e2749de`; `wms2-web-ui` `origin/develop` = `3117acace1c64558ef6c44d09038860ba1cc56a9`; `wms2-mobile-ui` `origin/develop`
- **DB evidence:** read-only SQL on all six v2 tenant DBs (dev_wh01_om1, wsl-wineco-uat, nywh-hydra-uat, wh01_hydra_v2 PRD, c1wh-shipitez-uat, nywh-shipitez-uat)
- **Mode:** read-only. No maven, no worktree, no file modified outside this evidence directory.
- **Verdict:** the gate **does** fire — this is a real gate, not a label. But the plan's over-gating section rests on a **false factual premise**, and three of the four capabilities remain reachable by other means.

---

## Q1 — DOES THE GATE ACTUALLY FIRE ON THESE ROUTES? **YES.** GUARDED membership is NOT required.

**The condition that gates a request** is: the handler resolves a `@RequiresFunction`, method-level first, then class-level. `GUARDED` governs **only** the branch where *no* annotation resolved.

`src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:238-260`:

```java
RequiresFunction annotation = methodLevel;
if (annotation == null) {
    annotation = AnnotationUtils.findAnnotation(declaring, RequiresFunction.class);
}

if (annotation == null) {
    if (!GUARDED.contains(declaring)) {
        return true;
    }
    ... deny fail-closed ...
}

String username = currentUsername();
AccessDecision decision = accessService.checkAnyAccess(username, annotation.value());
if (decision.allowed()) { ... return true; }
logDenial(...); deny(...); return false;
```

So a **method-level `@RequiresFunction` on a plain `@RestController` that is not in `GUARDED` is enforced.** `GUARDED` buys two different things — fail-closed for *unannotated* handlers, and a deletion tripwire — neither of which is enforcement of an annotation that is present.

Three further conditions, all satisfied:

1. **Registration.** `WebConfig.java:86-87` — `return new MappedInterceptor(new String[] {"/**"}, functionGuardInterceptor);`. A `MappedInterceptor` **bean** is detected by every `AbstractHandlerMapping` via `detectMappedInterceptors`, and the pattern is `/**`, so `/v3/adminAction/*` matches.
2. **The filter chain lets the request reach MVC.** `SecurityConfiguration.java:157-160` already matches `/v3/adminAction/**` → `hasAnyAuthority(Authority.WMS_USER_ROLE)`, so an authenticated `wms_user` reaches the handler and the interceptor runs. (See F9 — that matcher is mislabeled "Admin-Only".)
3. **Shipped behavioural precedent, not just source reading.** `ReportController` is **not** in `GUARDED` (the set is the 14 classes listed at `FunctionGuardInterceptor.java:110-152`) and carries **15 method-level `@RequiresFunction`** annotations (`ReportController.java:59,86,114,141,168,195,222,249,283,323,361,382,403,426`). That is SBDEV-3142, which is `on dev`. The exact mechanism this plan proposes is already live in production-adjacent code on a non-`GUARDED` plain controller.

**Two instruments agree** (source + shipped precedent). The documented "anti-drift covers only GUARDED" and "`setupMockMvc` installs no interceptor" traps are real but neither applies here: the first is about the *fail-closed* rail, the second about the `standaloneSetup` test lane — which the plan correctly avoids by extending the `@SpringBootTest` pin instead.

### Caveat on Q1 that is a finding in its own right — see **F11a**: nothing in the plan's test set proves a **403**.

---

## Findings

### F1 — HIGH · §2.2 and §6.1 assert "no menu entry and no UI caller". Both halves are false.

The plan says (§2.2) "*consistent with C30–C33 being an operator console with no menu entry and no UI caller*" and (§6.1) "*Mitigation: the console has no menu entry and no UI caller*".

Measured in `wms2-web-ui` `origin/develop` with `git grep` (not plain grep — `.gitignore` hides `reports/`):

- `components/admin/systemManagement/actions.vue` renders **six buttons**, five live: `@click="allocate"`, `updateStock`, `archiveMessage`, `testConnectivity`, `recoverStuckPallets`.
- `store/admin/mgmt/action.js:17,27,37,47,63,74` calls **every one of the four routes** plus `listRecoverableStuckPallets`:
  ```js
  let results = await this.$axios.$get('/adminAction/triggerOrderReplenish')
  ...
  const results = await this.$axios.$post('/adminAction/recoverStuckPallets', { ids: ids.join(','), comment })
  ```
- There **is** a menu entry: `pages/admin.vue:56` — `{ text: 'System Management', fn: 'WEB_UI_VIEW_IMPORT_DATA', component: 'SystemManagement', canonical: 0 }`.

So the real question is not "is there a caller" but **"who holds `WEB_UI_VIEW_IMPORT_DATA` and is not reachable via `super-admin`?"** I measured that on all six tenants:

| tenant | users w/ `WEB_UI_VIEW_IMPORT_DATA` | users via `super-admin` | **would lose access** | roles holding the function |
|---|---|---|---|---|
| dev_wh01_om1 (WineCo dev) | 37 | 37 | **0** | super-admin |
| wsl-wineco-uat | 35 | 35 | **0** | super-admin, ROLE000068, ROLE000113, ROLE000132 |
| nywh-hydra-uat | 15 | 15 | **0** | super-admin |
| **wh01_hydra_v2 (Hydra PRD)** | **7** | **7** | **0** | super-admin |
| c1wh-shipitez-uat | 23 | 23 | **0** | super-admin |
| nywh-shipitez-uat | 9 | 9 | **0** | super-admin |

Method: `mywms_function → mywms_role_mywms_function → mywms_group_mywms_role → mywms_group_mywms_user → mywms_user`, counted by **USER population** and set-differenced against the super-admin population (AC-2′). Blind spot: this walks the group path only; the direct `mywms_user_mywms_role` path is not walked — which is correct, because direct user→role assignment confers nothing in v2 (`getAllRoles` only walks user→group→role→function).

**The plan's conclusion survives — zero users lose access on any tenant, including PRD — but its stated reason is wrong**, and the reason it survives is a grant-configuration coincidence, not the absence of a UI. Fix §2.2/§6.1 to say: *the console has a UI caller and a menu entry gated on `WEB_UI_VIEW_IMPORT_DATA`; measured 2026-09-01, every holder of that function on all six tenants is also reachable via `super-admin`, so 0 users lose access.*

**Secondary, and real:** `actions.vue` performs **no per-button function check** — the buttons render for anyone who can see the tab. After this ships, a `WEB_UI_VIEW_IMPORT_DATA` holder without the two new functions sees five buttons and four of them 403. §6.4's decision to do no UI work is defensible, but it must be justified by "no such user exists today", not by "there is no UI".

### F2 — MEDIUM · three non-super-admin roles already hold `WEB_UI_VIEW_IMPORT_DATA` on WSL WineCo UAT, with zero users only because they are orphaned.

```
role_name    | users_via_role
super-admin  | 35
ROLE000068   | 0
ROLE000113   | 0
ROLE000132   | 0
```

Those three roles hold the function but are attached to **no group**, so they reach no user. The F1 "0 losers" figure is therefore a **snapshot with a live drift path**: an operator attaching `ROLE000113` to any group — an ordinary User Management action, no deploy required — immediately creates the F1 breakage on that tenant. Worth one line in §6.1 and a post-deploy re-run of the F1 query rather than trusting the pre-deploy figure.

### F3 — MEDIUM · `WEB_UI_ACTION_SYSTEM_MANAGEMENT` bundles three capabilities; one of them erases the audit trail of the other two.

Stated plainly: **anyone granted this one function can (a) run the warehouse allocation + replenishment sweep, (b) archive the entire message table, and (c) make WMS issue an outbound HTTP call.** These are not variants of one capability:

- (a) `triggerOrderReplenish` → `orderReleaseJob.doCalculation(false); replenishJob.doCalculation(false)` (`AdminActionController:108-109`) — a real inventory/workload mutation: it releases customer orders and creates replenishment orders.
- (b) `triggerArchiveMessages` → `cleanUpOldMessagesJob.doCalculation(false)` (`:123`) → `MessageRepository.archiveMessages` (`INSERT INTO message_archived SELECT * FROM message where created < :refDate`) plus a batched DELETE. The `message` table **is the Service Log** — the operator-visible record of every WMS↔OMS exchange, including the ones (a) and (c) produce.
- (c) `testCrmConnectivity` → `httpRestService.get(urlPath)` where `urlPath` comes from a sysprop (`:140`).

**Recommendation:** split (b) out into its own constant — e.g. `WEB_UI_ACTION_ARCHIVE_MESSAGES` — and leave (a) and (c) on `WEB_UI_ACTION_SYSTEM_MANAGEMENT`. Rationale: (b) is the only one that destroys evidence, and bundling it means the grant that lets you trigger jobs also lets you delete the log of having triggered them. (a) and (c) are both "poke a subsystem and observe" and are reasonably one function.

**Cost, stated because it conflicts with a stated constraint:** this makes it **three** constants, three `mywms_function` INSERTs and a third grant row. §1.1(b) says "the count stays at **two**, as the ticket requires". This is Nam's call, not mine to make — but the security argument for splitting (b) is stronger than the argument for holding the ticket's original count, and the marginal cost of a third INSERT in a migration already doing two is near zero. If the count must stay at two, the second-best split is (a)+(c) on `SYSTEM_MANAGEMENT` and (b) folded into `WEB_UI_ACTION_RECOVER_STUCK_PALLETS` — which is worse, and I do not recommend it. Third option: keep as planned and record the bundling decision explicitly in §6 so the next reviewer does not re-derive it.

### F4 — MEDIUM · gating `testCrmConnectivity` removes the trigger but not the redirect; the URL it calls is writable by any `wms_user`.

The target URL is read from a sysprop at call time — `AdminActionController:140`:
```java
String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_TEST_CRM_CONNECTIVITY_URL_KEY);
```
(`WmsConstants.java:1053` — key `"WEBSERVICE_TEST_CRM_CONNECTIVITY"`.)

`Sysprop` is **deliberately excluded** from the SDR write withdrawal. `RestConfiguration.java:306-310`:
> *"⚠ **NOT in this list, deliberately:** the ELEVEN resources with a live UI writer at their SDR path — `advice`, `boxtype`, `client`, `customerorder`, `cyclecount`, `location`, `locationType`, `section`, **`sysprop`**, `userGroup`, `userRole`."*

Combined with `SecurityConfiguration.java:157-160` (`/v3/sysprop/**` → `hasAnyAuthority(WMS_USER_ROLE)`) and SDR read gating shipping at `OFF` (`FunctionGuardInterceptor` javadoc: *"ships at `OFF`… it enforces only the domain types that have a rule"*), a `wms_user` can rewrite where WMS calls out. I did **not** live-probe a `PATCH /v3/sysprop/{id}`, and per the repo's own rule a 400 from an SDR write verb proves nothing either way — so treat this as "the exposure configuration is open", not "measured exploitable".

Consequence for this plan: the gate closes *"who can press the button"*, not *"who can make WMS call an arbitrary host"*. The outbound call also fires from `MessageService:123`, `BillofladingService:1417`, `StockSummaryExportJob:308` and `OmsNotificationService:108` on their own schedules. Pre-existing, out of scope — but §6 should not leave a reader thinking C33 closes SSRF-shaped risk.

### F5 — MEDIUM · replenishment-order generation has a per-item path that this gate does not touch.

The gate fences the *warehouse-wide sweep*. It does not fence *"can cause replenishment orders to be created"*:

- `StockunitService.triggerReplenishmentMaintenance` (`:139-146`) → `replenishmentOrderMaintenanceService.recalculateForItem(itemDataId)`, called from `:434, :490, :554, :661`.
- `FixLocationAssignmentService.triggerReplenishmentMaintenance` (`:302-310`) → the same service method, called from `:105, :178, :195, :213, :231, :278, :289`.

Both wrap it in `catch (Exception e) { LOG.warn(...) }`, so it is a silent side effect of ordinary stockunit and fixed-location writes. Whoever can perform those writes can drive per-item replenishment recalculation without holding `WEB_UI_ACTION_SYSTEM_MANAGEMENT`.

**The order-release half IS fully fenced**, and that is worth stating positively: `git grep releaseOrderJobService\.` over `src/main` returns callers in `OrderReleaseJob` only (`:130, :159, :214, :343`), and `orderReleaseJob.doCalculation(` appears at exactly two sites — `AdminActionController:108` and `SchedulingConfiguration:204` (the cron). So C31 does close the only non-cron HTTP path to order release.

### F6 — MEDIUM · one out-of-scope sibling has an **unauthenticated** twin, which makes §7's framing understate it.

`StockCountRestController.java:105-113`:
```java
@GetMapping(value = "triggerStockCount", produces = "application/json")
public void triggerStockCount() { triggerSchedule().run(); }
public Runnable triggerSchedule() { return () -> stockSummaryExportJob.doCalculation(false); }
```
Mapped at `@RequestMapping("/rest/stockcount")`, and `SecurityConfiguration.java:150-154` puts `/rest/**` under `.permitAll()`. That is byte-identical in effect to `triggerUpdateStock` (`AdminActionController:116`), which §7 lists as staying ungated.

Likewise `MessageDummyController` (`@RequestMapping("/rest/stockcount")`, `POST sendDummyMessageStockCountList`) reaches `httpRestService.post(urlPath, payload)` on a sysprop URL with a caller-supplied body, also under `permitAll()`.

Per Nam's 2026-08-27 decision, `/rest/**` is internal-only WMS↔OMS and **not** treated as a live exposure — so this is **not** an escalation and I am not proposing a ticket. It matters for one reason only: §7 says the four siblings "are ungated and stay ungated", and a future ticket that gates `triggerUpdateStock` on `AdminActionController` alone would be **cosmetic**. Add one sentence to §7 naming the `/rest/` twin so that ticket is scoped correctly when it is written.

### F7 — LOW · nothing compares the `FunctionEnum` constant's string **value** against the literal seeded by `V2.2.23`.

`FunctionGuardArchTest`'s AC-3 (*"every annotation value is a declared FunctionEnum constant"*) iterates `GOLDEN_MAP.keySet()` — the 14 `GUARDED` controllers (`FunctionGuardArchTest.java:70-108`). `AdminActionController` is not in it, and `SHARED_CONTROLLERS` (`:110-118`) is `["StockUnitController", "DashboardController", "ReplenishOrderController", "UnitLoadController"]`. So **no arch rail inspects the four new annotation sites** — none will break, and none will cover them either.

A constant *reference* in the annotation makes a Java-side typo a compile error, so AC-3's property is nearly free here. The uncovered failure mode is the other one: if `WEB_UI_ACTION_SYSTEM_MANAGEMENT`'s string **value** differs by one character from the `function` literal in `V2.2.23`, `accessService.checkAnyAccess` matches nothing and all four routes deny **all 126 super-admin users, permanently and silently** — fail-closed, no boot error, green suite. §4.3 lists "nothing executes the migration" but not this. Cheap fix: an AC that reads `V2.2.23__*.sql` as text and asserts each seeded `function` literal equals the corresponding `FunctionEnum` constant.

### F8 — LOW · `recoverPalletFromNirvana` is fenced; the *outcome* is not, and the plan should not claim otherwise.

`git grep recoverPalletFromNirvana` over `src/main` on `origin/develop` returns exactly two lines: the definition (`UnitloadBusinessService.java:737`) and the one call site (`AdminActionController:291`). So the **service method** has a single entry point and C30 closes it.

The **outcome** — a unitload relocated out of Nirwana into EmptyPallets, its To-Delete lock cleared, its label un-mangled — is a composite reachable in parts elsewhere: `UnitLoadController.java:68 reprintLabel`, `:101 deleteContainer`, `:136 bulkDeleteContainer`, `:176 deleteContainerRecursive`, plus `MoveUnitloadController` (mobile, class-level gated). `Unitload` and `Stockunit` *are* in `SDR_WRITE_WITHDRAWN` (`RestConfiguration.java:341-343`), so SDR is not a path. Enumeration method: `git grep` on the service method name plus a mapping grep of the unitload controllers. Blind spot: this finds direct callers by name only — it would miss a reflective or proxy-mediated call, and it does not prove the composite is *equivalently* gated. State the narrow claim ("the service method has one caller") rather than "the capability is closed".

### F9 — LOW · `SecurityConfiguration` block C is labelled "Admin-Only" but grants the same authority as the general matcher.

`SecurityConfiguration.java:156-160`:
```java
// C. Admin-Only WMS Endpoints
.requestMatchers(
    "/v3/adminAction/**", "/v3/sysprop/**", "/v3/systemProperty/**",
    "/v3/printer/**", "/userDetailsById/**", "/userGroup/**", "/user/**"
).hasAnyAuthority(Authority.WMS_USER_ROLE)
```
Block D at `:178` is `.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority(Authority.WMS_USER_ROLE)` — **identical**. Block C is inert with respect to authorization; it confers no admin restriction whatsoever. This corroborates the ticket's premise (the routes really are open to every `wms_user`), and it is a trap: a reviewer who trusts the comment concludes the routes are already admin-gated and closes SBDEV-3154 as invalid. Recommend a comment-only correction in the same PR (T0, one line, zero behaviour change) — not a matcher change, which would be scope.

### F10 — LOW · `admin.cy.js` will report a correct 403 as `BUG`.

`wms2-web-ui/cypress/e2e/wms/admin/admin.cy.js:138` — `report.recordApi({ ..., expectedStatus: 200 })`, and `:142` emits `'BUG: ' + a.name + ' returned ' + resp.status` for any non-200. It is opt-in behind `CYPRESS_WMS_ADMIN_ACTIONS_RUN` (default off), so no default-CI breakage — but the moment it is run by a principal that is not `super-admin`, a correctly-working gate is reported as a defect. One-line fix in the spec, or a note in §6.

### F11 — additions to §4.3 "what no test here can see"

**F11a (MEDIUM, and the most important of these).** **No test in the plan exercises the interceptor on these routes.** `Sbdev3017TrancheGateContextTest` is an **annotation-presence pin**: it reads `context.getBeansOfType(RequestMappingHandlerMapping.class)`, resolves `@RequiresFunction` per handler and diffs against `EXPECTED`. It never issues a request and never invokes `FunctionGuardInterceptor.preHandle`. So AC-4 cannot distinguish *"annotation present and enforced"* from *"annotation present and inert"*. Q1 establishes enforcement from source + the SBDEV-3142 precedent, which is why my verdict is still that this is a real gate — but the plan should either (i) add a MockMvc denial test that calls `.addInterceptors(functionGuardInterceptor)` explicitly, or (ii) state in §4.3 that enforcement is asserted by argument and precedent, not by any test in this ticket. Silence is the wrong option; that silence is exactly how SBDEV-2863 shipped a broken SpEL for nine months.

**F11b (LOW).** **No boot-time rail covers these four sites.** `FunctionGuardStartupAssertion.findUnannotatedGuardedHandlers` early-returns `if (!guarded.contains(declaring)) continue;` (`:158-161`), so it never inspects `AdminActionController`. §3.2's three ⛔ rules ("never annotate `AdminController`", "never add a class-level annotation", "never join `GUARDED`") are enforced by **nothing** at boot or in the arch rails for this class (see F7). They live only as comments.

**F11c (LOW — correcting a row in §4.2).** The mutation table says of "add `AdminActionController` to `GUARDED`": *"covered elsewhere — state this explicitly, the pin does not see GUARDED membership"*. The first half is right but the mechanism is unnamed and worth naming, because it is dramatic: adding the class to `GUARDED` leaves `triggerUpdateStock`, `triggerReleaseExpiredPickingOrdersFromUser`, `finishStuckPickingOrder`, `listRecoverableStuckPallets` and `accessAudit` resolving no `@RequiresFunction`, so `FunctionGuardStartupAssertion` (a `@Component implements SmartInitializingSingleton`, `:55-56`) **throws in `afterSingletonsInstantiated`** — the context refuses to start, and **every `@SpringBootTest` in the repo goes red**, not just this pin. It is not caught by `FunctionGuardArchTest` G-2 either: that filters `guarded.stream().filter(c -> c.getName().startsWith(REST_PKG))` (`controller.rest.` only) and its `doesNotContain` list is `("StockUnitController", "UnitLoadController")`. Neither matches `AdminActionController`.

**F11d (LOW).** §4.3 should add: `SecurityConfiguration`'s `authorizeHttpRequests` matchers are invisible to every Spring-context test in this repo (`Sbdev3017TrancheGateContextTest.java:313-317` says so explicitly). So the interaction between the new function gate and block C/D is unobservable in tests — relevant given F9.

---

## What I did NOT verify (blind spots, stated so no enumeration above reads as closed)

- **No live HTTP probe.** Every enforcement claim is from source plus the SBDEV-3142 shipped precedent. I did not curl a `403` from these routes, and I did not probe `PATCH /v3/sysprop/{id}` (F4).
- **Alternate-path enumeration method:** `git grep` on service/job **method names** and on `schedulejob` imports across `src/main`, plus a mapping grep of the unitload and `controller/rest` classes. Blind spots — reflective invocation, `x::methodRef` call sites, proxy-mediated calls, subtype dispatch, and any path through a stored procedure or DB trigger. The repo's own ArchUnit blind-spot note applies.
- **Grant population:** walked the group path only, on the six tenant DBs, on 2026-09-01. Roles attached to groups after that date invalidate the F1 table (that is F2).
- **The migration itself** is the other lane's subject; I did not review `V2.2.23`'s SQL beyond the function-name/constant-value coupling in F7.

## Bottom line

Ship it, with §2.2/§6.1 rewritten and F3 decided by Nam. The gate is real. The plan's mechanism is correct and matches shipped precedent. Its risk section is the part that needs work: it justifies a correct conclusion with a false premise, and it claims more closure than four route annotations can deliver.
