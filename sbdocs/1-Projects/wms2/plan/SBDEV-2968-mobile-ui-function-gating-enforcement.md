---
title: "WMSv2: mobile workflow tiles are gated client-side only — nothing re-enforces the function server-side"
ticket: "SBDEV-2968"
ticket_url: "https://app.clickup.com/t/868krr3rw"
type: "bugfix"
priority: "normal"
status: "reviewed, then RE-SCOPED 2026-08-17. Base RESOLVED — SBDEV-2870 PR #166 merged (`27e2f21`) and this ticket's worktree fast-forwarded onto it; P11 closed, Δ2's counts verified on develop rather than assumed. §3.1-A2b now ORIGINATES the `X-Authz-Denied` header + its CORS exposure here (SBDEV-2967 lands after this plan and consumes it). TDD gate unblocked on the base; **§3.1-A2b is new scope and has had no review pass** — see §14.3."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-16
updated: 2026-08-17
db_verified: true
related:
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
tags:
  - plan
  - security
  - authorization
---

# SBDEV-2968 — Mobile workflow tiles are gated client-side only; nothing re-enforces server-side

**Ticket:** [SBDEV-2968](https://app.clickup.com/t/868krr3rw)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix (security hardening)
**Repos:** `v2/wms2-api`, `v2/wms2-mobile-ui`
**Status:** reviewed; **re-scoped 2026-08-17 — base resolved (§14.3), one review pass still owed on §3.1-A2b**
**Base:** `origin/develop` @ **`27e2f21`** (merge of SBDEV-2870 PR #166) · worktree `.claude/worktrees/wms2-api/SBDEV-2968`, branch `bugfix/SBDEV-2968-mobile-function-gating`, fast-forwarded 2026-08-17

> **Companion to [SBDEV-2967](SBDEV-2967-web-ui-function-gating-enforcement.md).** This plan builds the
> enforcement mechanism (`@RequiresFunction` + `FunctionGuardInterceptor`); 2967 consumes it. **This plan
> lands first.**
>
> ⚠️ **Read [§14](#14-re-scope-2026-08-17--what-sbdev-2870-pr-166-changed-under-this-plan) before the TDD
> gate.** SBDEV-2870 PR #166 moved the `X-Authz-Denied` emitter *out* of the branch this plan assumed it
> would inherit from, and reshaped `AdminController`. One item is new scope (§3.1-A2b), the rest are
> count/line corrections.

---

## 0. Affected sites (enumeration before drafting)

### 0.A In scope — the gated surface (11 controllers, **66** method-level endpoints)

| # | Controller · path | Endpoints | Extends `AdminController`? |
|---|---|---|---|
| 0.1 | `controller/mobile/LookupController.java` · `/v3/lookup` | 5 | yes |
| 0.2 | `controller/mobile/PutawayController.java` · `/v3/putaway` | 6 | yes |
| 0.3 | `controller/mobile/MoveUnitloadController.java` · `/v3/moveUnitload` | 2 | yes |
| 0.4 | `controller/mobile/MoveStockController.java` · `/v3/moveStock` | 3 | yes |
| 0.5 | `controller/mobile/PickingController.java` · `/v3/picking` | 11 | yes |
| 0.6 | `controller/mobile/PalletizingController.java` · `/v3/palletizing` | 4 | yes |
| 0.7 | `controller/mobile/TruckLoadingController.java` · `/v3/truckLoading` | 5 | yes |
| 0.8 | `controller/mobile/CycleCountLosController.java` · `/v3/cycleCountLos` | 9 | yes |
| 0.9 | `controller/mobile/ReplenishController.java` · `/v3/replenish` | 11 | yes |
| 0.10 | `controller/mobile/TransferOrderController.java` · `/v3/transferOrder` | 5 | yes |
| 0.11 | `controller/OrderCancellationController.java` · `/v3/cancellation` | 5 | **no** — see 3.1/F1 |
| | **Total** | **66** | |

> **Count resolved (three different figures were in circulation).** The authoritative count is **66 method-level mappings**, obtained by counting every `@(Get\|Post\|Put\|Delete\|Patch\|Request)Mapping` per file and subtracting the one class-level `@RequestMapping` each. It is corroborated independently by the per-tile endpoint tables in the surface enumeration. An earlier figure of 77 counted the 11 class-level prefixes; an earlier figure of 67 was off by one on `PickingController`. **The golden map must still be built from reflection, not from this number** (§5.1-P4) — the number is documentation, the reflection is the contract.

### 0.B Explicitly EXCLUDED — shared endpoints (do **not** gate)

Gating any of these 403s a web-UI screen. All five are declared **outside** `controller/mobile/`, so the annotation-driven design excludes them by construction. Recorded so the exclusion reads as a decision, not an oversight; pinned by `FunctionGuardArchTest#noSharedControllerCarriesRequiresFunction`.

| Endpoint | Controller | Mobile caller | Web-UI caller | Breakage if gated |
|---|---|---|---|---|
| `POST /v3/stockUnit/transferStock` | `StockUnitController` | `store/moveStock.js:169` | `store/handlingUnits/stockUnits.js:161` | Handling Units → Stock Units transfer |
| `GET /v3/stockUnit/storageLocationsForStockMovement` | `StockUnitController` | `store/moveStock.js:157` | `store/handlingUnits/stockUnits.js:199` | its destination dropdown |
| `GET /v3/dashboard/orderMonitorViewSummary` | `DashboardController` | `store/picking.js:244` | `store/dashboard/pickpackMonitor.js:85` | Pick & Pack Monitor |
| `GET /v3/dashboard/replenishMonitorViewSummary` | `DashboardController` | `pages/replenish.vue:133,153` | `store/dashboard/replenishMonitor.js:33` | Replenish Monitor |
| `GET /v3/replenishOrder/detailView` | `ReplenishOrderController` | `pages/replenish.vue:146` | `store/internalOps/replenishments.js:155,357` | Internal Ops → Replenishments |

**Partially shared** — same Spring Data REST repository, different sub-paths (`SectionRepository`, `StockunitRepository`, `ClientRepository`, `FixLocationAssignmentRepository`, all under `/v3`). Safe per path, but a *repository-level* gate would break the web UI. None is added; `#noRepositoryCarriesRequiresFunction` prevents one being added later by reflex.

**Consequence, stated plainly:** after this change a user denied `MOBILE_UI_VIEW_STOCK_TRANSFER` cannot use the Move Stock *page* — its `/v3/moveStock` endpoints are gated and the route guard blocks the page — but **can still call `POST /v3/stockUnit/transferStock` directly**. The tile is enforced; the underlying shared capability is not. That is the correct scope boundary (narrowing it needs a per-caller distinction the shared controllers do not support), and it must appear in the ticket's closing note so nobody reads this as "mobile is now locked down." Tracked as R12.

### 0.C Inherited alias surface (finding — behaviour deliberately unchanged)

`AdminController.java:29` is `@RestController @RequestMapping("/v3")` with **9 mapped methods**; all 10 controllers in `controller/mobile/` extend it. Spring re-registers inherited mapped methods under each subclass prefix, so `GET /v3/picking/user/findUsers` and `GET /v3/putaway/admin/importUsersFromCsvText` are live URLs — roughly **90 alias mappings**.

> ⚠️ **Corrected 2026-08-17 (§14-Δ2). This section originally read 13 methods / ~130 aliases**, which was
> accurate when the plan was reviewed. SBDEV-2870 PR #166 (`989611e`) extracts four methods
> (`addUserToWarehouseGroup`, `removeUserFromWarehouseGroup`, `isWarehouseUser`, `existsInKeycloak`) into a
> new **standalone** `UserAdministrationController` (§0.26) that does **not** extend `AdminController`, so
> 13 → 9 and ~130 → ~90. ✅ **#166 merged 2026-08-17 (`27e2f21`) and these counts are now VERIFIED on
> `origin/develop`, not assumed** — 9 mapped `@RequestMapping`/`@*Mapping` methods on `AdminController`,
> counted on the merged base. §5.1-P4 still builds the golden map from reflection, so no number here is
> load-bearing; the count is documentation, and the reflection is the control.

Two consequences:

1. Nothing here gates them, and that is correct: gating `/v3/putaway/user/findUsers` while `/v3/user/findUsers` stays open is theatre. Declaring-class resolution (§3.1-A2) passes them through untouched.
2. **SBDEV-2870's blast radius was ~11× what it looked like — PR #166 removed most of it.** When this was found, each of its five ungated endpoints had an alias under every mobile controller prefix. After #166 only `GET /v3/admin/importUsersFromCsvText` still inherits (10 aliases); the other four now have **exactly one URL each** on the standalone `UserAdministrationController`. The finding stands as the reason a URL-pattern mitigation scoped to `/v3/user/**` would have failed, and as the reason #166's extraction was the right shape. **Reported to SBDEV-2870; nothing to act on here** (§5.1-P9, now closed).

### 0.D Supporting sites

| # | Site | What |
|---|---|---|
| 0.12 | `service/AccessService.java:81-87` | `doesUserHaveAccess` — 5 call sites, all `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`. **No `@Cacheable`.** Returns `false` identically for "no row", "row with no functions", and "row with other functions". |
| 0.13 | `repo/jpa/UserRepository.java:26-34` | `getAllRoles` — 5-table native join, `SELECT DISTINCT` |
| 0.14 | `model/User.java:15-39` | `additionalcontent, entityLock, email, firstname, lastname, locale, name, password, phone, clientId, printerId, groups`. **No Keycloak-mapping column** — the only link is `mywms_user.name == <keycloak username>`. Drives §3.5. |
| 0.15 | `controller/AdminController.java:80` (was `:81`) | `GET /v3/user/findUsers` → `List<UserRepresentation>`, a **bulk** Keycloak listing deployed today. The pre-deploy audit instrument. **Unmoved by PR #166 and still ungated** — so §3.5's audit and the `inheritedAdminControllerAliasIsNotGatedByTheSubclassAnnotation` fixture both survive the rebase unchanged. |
| 0.16 | ~~`controller/AdminController.java:359`~~ → `controller/UserAdministrationController.java:224` | `GET /v3/user/existsInKeycloak` — per-username probe. **Moved and gated** by SBDEV-2870 PR #166 (`WEB_UI_VIEW_USER_MANAGEMENT`). Still do not build the audit on it — now for two reasons: it is per-username, and after #166 the audit runner would need that function. |
| 0.17 | `service/WmsConstants.java:418-430, :364` | `FunctionEnum` — 80 constants |
| 0.18 | `controller/rest/UtilRestController.java:237-416, :878` | persona seed; the only two callers of `updateFunctionList` |
| 0.19 | `service/AccessService.java:63-79` | `updateFunctionList` — reflection-based, **no `src/main` caller**; runs only via `POST /v3/initDB` / `/v3/initAdmin` |
| 0.20 | `WebConfig.java` | the `WebMvcConfigurer` for interceptor registration. **This will be the first `HandlerInterceptor` in `src/main`** — no in-repo precedent. |
| 0.21 | `src/main/resources/db/migration/` | next free = **V2.2.17**. **Re-confirmed on the post-#166 base (`27e2f21`) 2026-08-17: head is V2.2.16.** The old warning here ("the local checkout is 36 commits stale and shows V2.2.13") no longer applies to *this worktree* — but the reason behind it does: `ls` shows only merged versions, and unmerged branches hold invisible ones. **P6's all-remote sweep is still required at PR time** (`flyway-version-pick-sweep-all-remote-branches`). |
| 0.22 | `store/home.js:19-118` | static 12-tile menu + the client-side filter |
| 0.23 | `pages/*.vue` ×12 | deep-linkable, unguarded; no `middleware/` directory exists |
| 0.24 | `pages/not-authorized.vue:20` | `layout: "splash"` — **no such layout in this repo** (`layouts/` holds only `default`, `error`, `no-tenant`) |
| 0.25 | `test/.../BaseControllerUnitTest.java:44-56` | plain `standaloneSetup` chain; needs an **additive** overload, not a change |
| 0.26 | `controller/UserAdministrationController.java:79-81` | **NEW — on `origin/develop` since `27e2f21` (SBDEV-2870 PR #166, merged 2026-08-17).** `@RestController @RequestMapping("/v3")` in package `controller/` — **not** `controller/mobile/`, and it does **not** extend `AdminController`. Four endpoints, all already gated on `WEB_UI_VIEW_USER_MANAGEMENT` by a plain `AccessService` call (not `@PreAuthorize`). Passes this plan's guard by construction (unannotated, outside the guarded set → allow), and `passesThroughForUnannotatedNonMobileController` already covers that shape. **It changes the golden-map and startup-assertion baseline** (§5.1-P4/P11) — the reflected handler surface this plan asserts against is not the one the plan was reviewed on. |
| 0.27 | `SecurityConfiguration.java:167-188` | `corsConfigurationSource` — exposes exactly one header today (`CyclecountService.EXPORT_SKIPPED_HEADER`, SBDEV-2632), with an additive `contains()` de-duplication guard. **Verified 2026-08-17: identical on `origin/develop` and on the SBDEV-2870 branch — PR #166 does not touch it.** This plan must add `X-Authz-Denied` here (§3.1-A2b); nothing else will. |
| 0.28 | `Authority.java` | Gains `WMS_ADMIN_ROLE` in PR #166. **Does not gain `AUTHZ_DENIED_HEADER`** — that constant was written on the 2870 branch and then reverted (2870 §11.4) because no emitter remained there. This plan re-introduces it (§3.1-A2b). |

---

## 1. Problem Statement

### 1.1 Symptom

`store/home.js:104-118` fetches `GET /v3/user/getAllRoles/{username}` and filters a hard-coded 12-entry menu down to the permitted tiles. That list is consumed by exactly one component — `components/homePage/homePage.vue:35` — to decide which tiles to **paint**. Nothing else consults it.

- `…/mobile/picking` typed into the address bar renders `pages/picking.vue` for any authenticated user.
- Browser history and saved links do the same.
- `curl -H "Authorization: Bearer <any wms_user token>" …/v3/picking/…` reaches the handler.

All **66** endpoints across the 11 controllers carry **zero** `@PreAuthorize` and **zero** function checks. The only authorization is `SecurityConfiguration.java:143`, a blanket `hasAnyAuthority("wms_user")` on `/v3/**`.

`MOBILE_UI_VIEW_*` is presentation, not authorization. A seeded `outbound-forklift` operator — Truck Loading and Lookup only — can execute cycle counts, adjust stock, cancel orders, and finalize picks.

### 1.2 DB verification (analysis-protocol §8 — `db_verified: true`)

Queried live 2026-08-16 against **WineCo dev** (`wms2-wineco-dev`, the primary test client, 96 users) and **Hydra UAT** (`wms2-hydra-uat`, 19 users).

Per-role mobile view-function counts on WineCo dev:

| Role | total fns | `MOBILE_UI_VIEW_*` | users reached |
|---|---|---|---|
| `inventory-manager` | 11 | 4 | 10 |
| `inventory-worker` | 5 | 4 | 10 |
| `outbound-forklift` | 3 | 2 | 10 |
| `outbound-manager` | 23 | 7 | 10 |
| `outbound-worker` | 7 | 6 | 17 |
| `receiving` | 15 | 5 | 7 |
| `super-admin` | 77 | 10 | 39 |
| `CS-REP` (tenant-authored) | 28 | **0** | 4 |

**Bypass condition proven:** `outbound-forklift` holds `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_TRUCK_LOADING` and nothing else, yet `/v3/picking`, `/v3/cycleCountLos` and `/v3/putaway` are all fully reachable for its 10 users today.

**Grant drift proven:** `MOBILE_UI_VIEW_CANCELLATION` is granted to `outbound-manager`, `outbound-worker`, `super-admin` on WineCo and to `super-admin` only on Hydra UAT — while `UtilRestController` grants it to **nobody**. The same tile means different things per tenant.

**Transfer tile proven invisible:** `WEB_UI_VIEW_TRANSFER_ORDER` is held by `super-admin` only on both tenants, so the Transfer Process tile is hidden from all six operational personas.

### 1.3 Scope

**In scope:** re-enforcing the existing *tile-level* decision on the server across the mobile-exclusive surface, plus the grant-data gaps that make the decision unusable.

**Out of scope:** the five shared endpoints (§0.B), the inherited aliases (§0.C), sub-tile read/write granularity, and the openness of `getAllRoles` itself (§10.4).

---

## 2. Root Cause Analysis

**RC-1 — the decision was implemented in the only layer that cannot enforce it.** A Vuex action in a client the server does not control. `AccessService.doesUserHaveAccess` was added later for one unrelated web action and never generalised.

**RC-2 — the test harness cannot observe declarative authorization, so its absence is invisible.** `BaseControllerUnitTest:50` uses `MockMvcBuilders.standaloneSetup`, which installs no method-security advisor: a controller with `@PreAuthorize` and one without produce byte-identical results. This is realised, not hypothetical — it is how `Authority.IS_SB_ADMIN` shipped naming a non-existent SpEL method for nine months (SBDEV-2863). **Any fix that does not change what the harness can see leaves RC-2 in place.** This is the single strongest constraint on the design.

**RC-3 — the grant data cannot express the decision even if enforced.**

- `MOBILE_UI_VIEW_CANCELLATION` (`WmsConstants:430`) is seeded to **zero** personas; live tenants granted it by hand.
- `WEB_UI_VIEW_TRANSFER_ORDER` (`:364`) → `super-admin` only.
- Replenish **Process** and **Request** are two tiles sharing one constant, so they cannot be granted independently.
- CS-REP-style roles hold `MOBILE_UI_LOG_IN` with zero view functions (4 live users).
- **A new `FunctionEnum` constant does not self-seed.** `updateFunctionList` (`AccessService:63`) creates missing rows by reflection but has **no caller in `src/main`** — only `POST /v3/initDB` and `/v3/initAdmin`. Already-provisioned tenants never run it, which is why §3.4 must INSERT the row explicitly.

> **On the "42 of 96 WineCo users belong to no group" figure — not evidence of impending lockout.** Only a subset of `mywms_user` rows map to Keycloak identities. User management either creates the Keycloak user and imports it into WMS, or creates the WMS user and syncs it to Keycloak; **only mapped users can authenticate at all.** The groupless remainder are unmapped, legacy, or archived rows that will never reach the interceptor. The figure is an artifact of the username-only mapping model. The residual concern is narrower and real: a **Keycloak-mapped** user whose `mywms_user` row exists but whose group assignment was missed is denied, and today that denial is indistinguishable in the logs from an ordinary permissions gap. Fix A7 (§3.1) addresses exactly that.

**RC-4 — the mapping surface is wider and less uniform than the source suggests.** Endpoint→function is many-to-many (`store/replenish.js:171` calls a `/v3/lookup` endpoint from the Replenish tile); five endpoints are shared with the web UI; and `AdminController` inheritance multiplies each mobile controller's URL surface by ~13. Any design assuming "one controller, one function, one URL each" is wrong on all three counts.

---

## 3. Fix Design

### 3.1 Fix A — backend enforcement (the central mechanism)

**A1. `net.aim_ai.wms.security.RequiresFunction`** — new annotation, `@Target({TYPE, METHOD})`, `@Retention(RUNTIME)`, `String[] value()`, **ANY-of** semantics.

```java
@Target({ElementType.TYPE, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
public @interface RequiresFunction {
    String[] value();   // ANY-of
}
```

Values must be `WmsConstants.FunctionEnum` **constant references**, never string literals — so a rename is a compile error rather than a silent runtime failure. That single property is what kills the SBDEV-2863 class of bug at the compiler. Javadoc must state: (i) constant references only; (ii) enforcement lives in `FunctionGuardInterceptor`, registered in `WebConfig`; (iii) a method-level annotation **replaces** (does not union with) the class-level one; (iv) it resolves against the **declaring class**, so annotating a subclass of `AdminController` does not gate that class's inherited methods; (v) the SBDEV-2863 rationale for not using `@PreAuthorize`.

> **Naming is deliberate — do not "correct" it back toward `Mobile*`.** Per the 2026-08-16 target-state decision (§13), `FunctionEnum` becomes the platform's only fine-grained authorization mechanism, so SBDEV-2967 and the `sb_admin` migration extend *these* types rather than adding parallel ones. What is mobile-specific here is only the golden map in A5 — the set this ticket guards first.

**A2. `net.aim_ai.wms.security.FunctionGuardInterceptor implements HandlerInterceptor`** — constructor-injected `AccessService`, `ObjectMapper`, `MeterRegistry`. `preHandle`:

1. `if (!(handler instanceof HandlerMethod hm)) return true;`
2. `Class<?> declaring = hm.getMethod().getDeclaringClass();` — **not** `hm.getBeanType()`. This one line is the §0.C fix: inherited `AdminController` methods resolve to `AdminController` and fall through untouched, whichever of the ~90 alias URLs was used. *(The count moved 130 → 90 with SBDEV-2870 PR #166; the mechanism is count-independent, which is why the correction is a footnote and not a redesign.)*
3. Resolve: `hm.getMethodAnnotation(RequiresFunction.class)`, else `AnnotationUtils.findAnnotation(declaring, RequiresFunction.class)`.
4. **Fail closed:** none found **and** `declaring` is in the guarded set → `ERROR` log + deny. Otherwise allow, preserving existing behaviour for the rest of the API. See A8 — the guarded set is *not* a package predicate.
5. `accessService.checkAnyAccess(username, fns)` → `AccessDecision`. Allowed → increment `wms2.authz.allowed`, return true.
6. Denied → `403` + `ProblemDetail` carrying `requiredFunction` and `reason`, **plus an `X-Authz-Denied: <function>` response header** — this is what lets the client tell an authorization denial from a stale-token 401 and skip its retry-then-logout path (§3.2-B5 / §5.1-P10). **This interceptor is the header's FIRST and only emitter** — see A2b. Log `WARN` (`ERROR` for `USER_NOT_PROVISIONED`); increment `wms2.authz.denied{controller,function,reason}`.

**A2b. The `X-Authz-Denied` contract — owned here, not inherited (new scope, 2026-08-17; §14-Δ1)**

> **This subsection replaces a false premise.** Steps 6 above, §3.2-B5 and §5.1-P10 originally said the header
> "is already emitted by SBDEV-2870's damaged-lock gate (`StockUnitController.denyUnlessDamagedLockAllowed`)"
> and that this plan merely *adopts* it. That was true of the branch as reviewed and is **no longer true**: on
> 2026-08-17 the damaged-lock gate, the `Authority.AUTHZ_DENIED_HEADER` constant and the CORS entry were all
> reverted from SBDEV-2870 and re-homed in **SBDEV-2967 Fix E** (2870 §11.4) — and 2967 lands *after* this
> plan. Verified against `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin` @ `989611e`: **no
> `X-Authz-Denied` anywhere in `src/main/`**, and `corsConfigurationSource` exposes only
> `CyclecountService.EXPORT_SKIPPED_HEADER`. The dependency had inverted — the plan that lands first was
> waiting on the plan that lands second.

Three additions, all in `wms2-api`:

1. **`Authority.AUTHZ_DENIED_HEADER = "X-Authz-Denied"`** — re-introduce the constant reverted by 2870 §11.4. One definition, referenced by the interceptor, by `SecurityConfiguration`, and by 2967 Fix E when it arrives. Javadoc must record that the emitter is `FunctionGuardInterceptor` and that **the CORS entry in `SecurityConfiguration` is what makes it readable** — the two must never be separated.
2. **CORS exposure in `SecurityConfiguration.corsConfigurationSource` (§0.27).** Follow the SBDEV-2632 precedent already in that method verbatim: additive `addExposedHeader` behind a `contains()` guard, so an environment supplying `rest.security.cors.exposed-headers` cannot drop it and cannot double-list it. **Without this the header is invisible to the browser and P10's `retryCondition` fix is dead on arrival** — a same-origin unit test or a `curl` will not catch it, because both read headers CORS never filters.
3. **Extend `unit/config/SecurityConfigurationTest`.** Two new cases following the file's existing naming
   convention: `corsConfigurationSource_exposesAuthzDeniedHeader_whenPropertyAbsent` and
   `corsConfigurationSource_doesNotDuplicateAuthzDeniedHeader_whenPropertyAlreadySuppliesIt`.

   ⚠️ **Read this before touching the two SBDEV-2632 cases already there — 2870 §3.5.1 property 5 is half
   right, and the half that is wrong will cost a build.** It says "`SecurityConfigurationTest` asserts the
   exposed-header list *exactly* and will fail when the header is added." **Exactly one of the two existing
   cases does.** Verified on `develop`:
   - `…_exposesSkippedCycleCountHeader_whenPropertyAbsent` (`:64`) uses `.contains(…)` — permissive, stays
     green when a second header appears. **Leave it alone.**
   - `…_doesNotDuplicateHeader_whenPropertyAlreadySuppliesIt` (`:83`) uses
     `.containsExactly("X-Export-Skipped-Cycle-Counts")` — a **one-element** exact list. **This one goes red
     the moment `X-Authz-Denied` is exposed**, and it is the test 2870 meant.

   **Extend that expectation to both headers; do not relax it to `contains`.** Exactness there is what forces
   a future change to be deliberate — and it is the only assertion in the repo that would notice the header
   being dropped again. *(Taking 2870's property 5 at face value would have meant either a surprise red build
   or, worse, "fixing" it by relaxing the wrong assertion.)*

   ⚠️ **Use `containsExactlyInAnyOrder`, not `containsExactly` (review ②, 2026-08-19).** AssertJ's
   `containsExactly` is **order-sensitive**. With one element that is invisible; with two the assertion's
   outcome starts depending on whether the property supplied `X-Export-Skipped-Cycle-Counts` before the code
   added `X-Authz-Denied` — i.e. on the ordering of two `addExposedHeader` calls that no requirement
   constrains. A refactor that changes nothing observable then turns the test red.
   `containsExactlyInAnyOrder` keeps **exact membership**, which is the property this decision actually wants,
   and drops an accidental coupling to call order. This is **not** the relaxation forbidden above — `contains`
   is, because it tolerates extra entries. Verify rows `H24` and `H25` are both anchored on the literal
   `containsExactly(` and must be widened in the same commit (see §9.2).

**Why this plan is the right owner, not a scheduling accident.** `FunctionGuardInterceptor` writes the denial
response itself, so it can attach a header with no new machinery. SBDEV-2870 could not: its five gates are
`@PreAuthorize`, which produces Spring's *default* 403, and **there is no `AccessDeniedHandler` in this
codebase** (verified) — so emitting a header there would have been new infrastructure, not a one-liner. 2967
Fix E can emit it because it is also a controller-level gate. Ownership follows the emitter.

**Hand-off to 2967:** its Fix E must **reuse** `Authority.AUTHZ_DENIED_HEADER` and find the CORS entry already
present — its §3.5.1 property 4 and §5.1-P8 are updated to say so. If this plan is descoped or reordered, 2967
takes both items back; they must not be dropped by both.

The username is **resolved by the interceptor and passed as a value** into `AccessService`, rather than the service reaching into `SecurityContextUtils` statically. This keeps the unit tests honest and avoids a hidden ThreadLocal dependency inside the check.

**A3. `AccessService.doesUserHaveAnyAccess(String username, String... functions)`** — one `getAllRoles` call, any-match, `false` on an empty role list and on empty varargs. **No `@Transactional`**: a single Spring Data read opens its own, and a bare `@Transactional` here would bind to the `@Primary` **landlord** TM and query the wrong database. The existing `doesUserHaveAccess` and its 5 call sites are untouched.

**A4. Registration** — `WebConfig.addInterceptors(registry)` → `registry.addInterceptor(guard).addPathPatterns("/**")`. Broad by design: the annotation decides, so an **MVC controller** that later changes path cannot escape. (This does not extend to Spring Data REST — see A9.)

**A5. The golden map**

| Declaring class | Class-level | Method-level override |
|---|---|---|
| `LookupController` | `MOBILE_UI_VIEW_INFO` | `locationByLocationName` → `{MOBILE_UI_VIEW_INFO, MOBILE_UI_VIEW_REPLENISHMENT}` |
| `PutawayController` | `MOBILE_UI_VIEW_PUT_AWAY` | — |
| `MoveUnitloadController` | `MOBILE_UI_VIEW_TRANSFER` | — |
| `MoveStockController` | `MOBILE_UI_VIEW_STOCK_TRANSFER` | — |
| `PickingController` | `MOBILE_UI_VIEW_PICKING` | — |
| `PalletizingController` | `MOBILE_UI_VIEW_PALLETIZING` | — |
| `TruckLoadingController` | `MOBILE_UI_VIEW_TRUCK_LOADING` | — |
| `CycleCountLosController` | `MOBILE_UI_VIEW_CYCLE_COUNT` | — |
| `ReplenishController` | `MOBILE_UI_VIEW_REPLENISHMENT` | `requestLocation` and `requestAmount` → `MOBILE_UI_VIEW_REPLENISH_REQUEST` (see A5.1) |
| `TransferOrderController` | `WEB_UI_VIEW_TRANSFER_ORDER` (D4) | — |
| `OrderCancellationController` | `MOBILE_UI_VIEW_CANCELLATION` | — |

**A5.1 — the `ReplenishController` split, derived (closes §10.12).** Derived from callers, not method names, by mapping every endpoint through `store/replenish.js` to the component subtree that dispatches it. `components/replenish/` splits cleanly into `process/`, `request/` and `shared/`, and the dispatch sets are disjoint:

| Endpoint | Line | Store action | Dispatched from | Function |
|---|---|---|---|---|
| `GET /requestLocation/{input}` | :51 | `scanLocation` | `request/` | **`MOBILE_UI_VIEW_REPLENISH_REQUEST`** |
| `POST /requestAmount` | :73 | `requestAmount` | `request/` | **`MOBILE_UI_VIEW_REPLENISH_REQUEST`** |
| `GET /reservedOrder` | :104 | — (no UI caller) | — | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `GET /clientList` | :111 | `getClients` | `process/` | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `GET /clientOrderList/{clientNumber}` | :118 | `getOrders` | `process/` | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `GET /loadOrderById/{id}` | :126 | `getOrderById` | `process/` + `pages/replenish.vue` | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `GET /checkSource/{id}/{input}` | :133 | `checkSource` | via `submitULBatchToDestination` (`process/`) | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `GET /checkAmount/{id}/{input}` | :157 | `checkAmount` | via `submitULBatchToDestination` (`process/`) | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `GET /checkDestination/{id}/{input}` | :182 | `checkDestination` | via `submitULBatchToDestination` (`process/`) | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `PUT /order/{id}` | :209 | `updateOrderSourceLocation` | `process/` | `MOBILE_UI_VIEW_REPLENISHMENT` |
| `POST /multi-unitloads` | :229 | `submitULBatchToDestination` | `process/` | `MOBILE_UI_VIEW_REPLENISHMENT` |

**2 request-side, 9 process-side — 11 total, matching §0.A.** Implementation: class-level `MOBILE_UI_VIEW_REPLENISHMENT` plus a method-level override naming **only** `MOBILE_UI_VIEW_REPLENISH_REQUEST` on `requestLocation` and `requestAmount`. The override is deliberately *not* an ANY-of including `…REPLENISHMENT`: that would make the two functions inseparable again and defeat C1. Existing users keep both because §3.4 part 2 grants `…REPLENISH_REQUEST` to every role already holding `…REPLENISHMENT`.

Three notes the implementer needs:

- `checkSource` / `checkAmount` / `checkDestination` are **dispatched from no component at all** — they exist as store actions but their only live use is the internal axios calls inside `submitULBatchToDestination`. They are process-side by that call path, and a UI-only trace would have missed them entirely.
- `GET /reservedOrder` (:104) has **no UI caller** and cannot be classified by tracing. It reads reserved replenishment orders — a process concern — so it takes the class-level default. Covered by M16 (curl-only).
- `updateOrderSourceLocation` also calls `GET /v3/lookup/locationByLocationName/{name}`, which is the cross-tile case already handled by the `LookupController` method-level override in the table above.

Two endpoints have **no mobile-UI caller** and are covered only by their class-level annotation: `GET /v3/lookup/searchSku/{keyword}` (`LookupController:55`) and `GET /v3/replenish/reservedOrder` (`ReplenishController:105`). Both are reachable by any `wms_user` today and must be gated; neither is verifiable through the UI, so they get curl-only manual tests (M15/M16).

**A6 — dropped.** *(A per-request cache was considered and rejected; see §3.6.)*

**A7. Deny-reason distinguishability.** `AccessService.checkAnyAccess` returns an `AccessDecision` record. This is a **diagnosability** control — it changes nothing about who is allowed, only what the log, metric, and message say when someone is not:

| `reason` | Condition | Log | Metric tag | Operator message |
|---|---|---|---|---|
| `ALLOWED` | any function matches | — | `allowed` | — |
| `MISSING_FUNCTION` | row exists, functions non-empty, none match | `WARN` | `missing_function` | "You don't have access to **{workflow}**. Ask your warehouse administrator to grant **{fn}**." |
| `NO_FUNCTIONS` | row exists, `getAllRoles` empty — **the missed-group-assignment case** | `WARN` | `no_functions` | "Your account has no warehouse permissions yet. Ask your administrator to assign your user group." |
| `USER_NOT_PROVISIONED` | `userRepository.findByName(username)` empty | **`ERROR`** with username + tenant | `unprovisioned` | "Your account is not set up in this warehouse. Contact support." |

The `findByName` probe runs **only after a deny**, so the allow path stays at exactly one query.

**A8. The guarded set is an explicit set, not a package predicate.** *(Critic F1 — CRITICAL.)*

A package-based rule (`declaring.getPackageName().startsWith("net.aim_ai.wms.controller.mobile")`) covers only 10 of the 11 in-scope controllers: **`OrderCancellationController` is declared in `net.aim_ai.wms.controller`** (verified: package line, and it is the only one of the eleven with no `extends`). Under a package rule, removing its annotation makes it fail **open**, silently — and both a "denies unannotated mobile controller" test and a "passes through unannotated non-mobile controller" test are satisfied by an implementation carrying that hole.

Two changes, both required:

1. **Move `OrderCancellationController` into `controller/mobile/`.** Its `@RequestMapping("/v3/cancellation")` is absolute, so **no URL changes**. Verified blast radius: **zero external references** anywhere in `src/` — no other class imports it, and it has no test — and all its imports are from other packages (`exceptions`, `json`, `service`), so this is a one-line package change plus the file move. It must **not** be made to extend `AdminController`; that would manufacture 13 aliases it does not currently have.
2. **Add a startup assertion.** A `SmartInitializingSingleton` walks `RequestMappingHandlerMapping.getHandlerMethods()`, collects declaring classes, and fails bean initialisation unless the set carrying `@RequiresFunction` equals the hard-coded golden-map keyset. This is fail-closed over the **deployed handler surface** rather than over a package name: it catches both deletion of an annotation and addition of an unannotated mobile controller, and it is unit-testable by feeding a fake `Map<RequestMappingInfo, HandlerMethod>` — no Spring context, so SBDEV-2217 is not implicated.

Keep the package check inside `preHandle` as defence in depth, but the startup assertion is the real invariant.

**A9. Spring Data REST is out of reach of the interceptor — and that is fine.** *(Critic F6.)* `/v3/section`, `/v3/stockunit`, `/v3/client`, `/v3/fixLocationAssignment` are served by `RepositoryRestHandlerMapping`, which does **not** honour `WebMvcConfigurer.addInterceptors`. They never reach the guard **at all** — not, as a naive reading suggests, because their declaring class is outside the mobile package. The outcome is what we want, but the rationale must be recorded correctly, and A4's "cannot escape" claim holds for MVC controllers only.

### 3.2 Fix B — mobile route guard and actionable denial

**B1. `util/menuCatalog.js`** (new) — extract the 12-entry menu from `store/home.js:19-118` verbatim; export `MENU` and `deriveRouteFunctionMap()`. One source of truth, so the tile filter and the route guard cannot disagree.

**B2. `store/home.js`** — add `rolesLoaded` / `rolesError`; add `ensureRolesLoaded()` memoising a single in-flight promise. Today `setMenus` swallows failures into a toast and leaves `pageList` empty, which after B3 would read as "denied".

**B3. `middleware/require-function.js`** (new — no `middleware/` directory exists yet) + `nuxt.config.js` `router: { middleware: ['require-function'] }`. Unmapped path (`/`, `/not-authorized`, `/unknown-tenant`, `/unhealthy-tenant`) → `next()`. Mapped path → `await store.dispatch('home/ensureRolesLoaded')`; `rolesError` → `/unhealthy-tenant?reason=roles`; loaded-and-missing → `/not-authorized?workflow=…&fn=…`; otherwise `next()`.

**B4. `pages/not-authorized.vue`** — `layout: "splash"` → `layout: "default"`. **This is a live bug independent of this ticket:** `wms2-mobile-ui/layouts/` contains only `default.vue`, `error.vue`, `no-tenant.vue` — there is no `splash.vue` in this repo at all (the web UI has one; mobile does not), so the page every denied operator is sent to today references a non-existent layout. Also render the A7 message variant and a "Back to menu" button, keeping the generic copy when no query params are present (the existing `pages/index.vue:202` path).

**B5. `plugins/axios.js`** — a 403 carrying `reason` + `requiredFunction` renders the matching A7 message; everything else keeps today's generic toast. This is **rendering of the server's decision, not a second gate**.

> 🔴 **B5 CANNOT WORK AS DRAFTED — the interceptor never lets the 403 reach the renderer. Found 2026-08-17.**
>
> `plugins/axios.js` treats **403 identically to 401**: `retryCondition` (`:35-37`) returns true for either, so the request is retried up to **3 times** with `$kc.updateToken(5)` on each attempt, and when retries are exhausted on an authenticated session it calls **`$kc.logout()`** (`:92`). The same shape exists in `wms2-web-ui/plugins/axios.js` (`:33-34`, `:86`).
>
> **Consequence:** every A7 deny would present to the operator as *"the app logged me out"*, not *"you don't have access to Cycle Count"* — and each denial costs 4 requests plus 3 token refreshes. **The entire A7 design (four typed reasons, tailored messages, the `reason` metric tag) is discarded by the client before anything is rendered.**
>
> **Root cause:** the interceptor conflates two different 403s. An **authentication** 403 (stale/invalid token) is worth retrying because a refresh may fix it. An **authorization** 403 (you lack the function) can *never* be fixed by a refresh, so retrying is pointless by construction.
>
> **Required change — `retryCondition` must not retry an authorization denial.** Emit an **`X-Authz-Denied: <function>`** response header from `FunctionGuardInterceptor` (§3.1-A2 step 6) and have `retryCondition` return `false` when it is present. Header-based detection is deliberately preferred over parsing the body — an interceptor should not have to deserialise to make a retry decision.
>
> ⚠️ **Corrected 2026-08-17 (§14-Δ1).** This paragraph previously read *"the server side already exists: SBDEV-2870's damaged-lock gate emits it (`StockUnitController.denyUnlessDamagedLockAllowed`) — adopt the same header."* **It does not exist.** That gate and its header were reverted from SBDEV-2870 and re-homed in SBDEV-2967 Fix E, which lands after this plan. The server side is **new work in this plan** — the constant, the emitter *and* the CORS exposure without which the browser cannot read it. See **§3.1-A2b**. The client-side change described here is unaffected; only its server-side precondition moved.
>
> **This is a blocking prerequisite (§5.1-P10), not a nice-to-have.** Without it the deny UX is strictly worse than today's generic toast, because today's failure at least does not log the user out.

### 3.3 Fix C — `FunctionEnum` and persona seed (D3)

| | |
|---|---|
| **C1** | Add `MOBILE_UI_VIEW_REPLENISH_REQUEST` to `FunctionEnum`. **Split rather than couple:** requesting a replenishment (a picker at an empty flow bin) and executing one (a forklift operator) are different jobs — the live matrix gives `receiving` replenishment but not `outbound-worker`, yet outbound workers are exactly who hit empty bins. Coupling forces granting execute in order to grant request. Existing users are protected by §3.4 part 2's back-compat grant. |
| **C2** | `UtilRestController.initDB` gains: `MOBILE_UI_VIEW_CANCELLATION` → `inventory-manager`, `outbound-manager`, `outbound-worker`, `super-admin`; `WEB_UI_VIEW_TRANSFER_ORDER` → the same four (**D4 — reuse the existing constant; no rename, no `MOBILE_UI_VIEW_TRANSFER_ORDER`**); `MOBILE_UI_VIEW_REPLENISH_REQUEST` → `receiving`, `outbound-worker`, `outbound-manager`, `super-admin`. |
| **C3** | `updateFunctionList` has **no caller in `src/main`**, so a new constant does **not** appear on boot on any already-provisioned tenant. §3.4 must INSERT the row explicitly; C2 covers only freshly-initialised DBs. |
| **C4** | CS-REP-style roles (`MOBILE_UI_LOG_IN`, zero view functions) are **deliberately unchanged** — "may authenticate, may run no workflow" is a coherent stance. Behaviour after enforcement is identical (empty home screen); it merely becomes load-bearing. §3.5 reports them; the plan does not decide for the warehouse. |

### 3.4 Fix D — `V2.2.17__seed_mobile_workflow_functions.sql`

Version: `origin/develop` head is **V2.2.16** — re-confirmed on the merged base `27e2f21`, 2026-08-17 (the "36 commits stale" caveat is spent; the worktree is current). **Re-sweep all remote branches immediately before the PR** (versions are append-only; V2.2.11/14/15/16 were claimed off-develop, and #166 carried none).

Idempotent, three parts:

1. **Insert function rows** — `MOBILE_UI_VIEW_REPLENISH_REQUEST` and, defensively, `MOBILE_UI_VIEW_CANCELLATION`, each guarded by `WHERE NOT EXISTS (SELECT 1 FROM mywms_function WHERE name = …)`. Column shape from the base dump (`V2.2.00__base_v2_schema.sql:2739`): `id` from `nextval('seqentities')`, `version = 0`, `client_id = 0`, `name = number = function = <constant>`.
2. **Back-compat grant** — every role holding `MOBILE_UI_VIEW_REPLENISHMENT` also gets `MOBILE_UI_VIEW_REPLENISH_REQUEST`, so C1's split removes nobody's access. `mywms_role_mywms_function` has **no unique constraint** in the base schema, so `ON CONFLICT` will not fire — use `AND NOT EXISTS (…)`. Verify against a real tenant DB first (§5.1-P5).
3. **Persona grants** for `WEB_UI_VIEW_TRANSFER_ORDER` and `MOBILE_UI_VIEW_CANCELLATION`, keyed by role **name**, skipping silently where the role is absent — migrated tenants have renamed roles and the migration must never fail on one.

**Ownership:** INSERT-only, no `CREATE OR REPLACE`, so the `42501 must be owner of…` failure that stalled prd at V2.2.06 does not apply. Still confirm the app role can INSERT into all three tables on prd.

**Not included:** any repair of invariant violations — D2 is detect-and-report only.

### 3.5 Fix E — invariant audit surface (detect + report only), scoped to Keycloak-mapped users

**The constraint that shapes this section.** `model/User.java` has **no Keycloak-mapping column**; the only link is `mywms_user.name == <keycloak username>`. A SQL-only audit therefore **cannot** distinguish a mapped operator from an orphan row — and since only mapped users can authenticate, an unfiltered report is mostly noise. It was exactly the unfiltered view that produced the misleading "42 of 96" reading.

**Choice: cross-check each username against Keycloak.** The alternative — report everything with a caveat the operator must apply by hand — is the failure mode this section exists to prevent. The cross-check needs no new code pre-deploy: `GET /v3/user/findUsers` (`AdminController:81`) already returns a **bulk** `List<UserRepresentation>`.

**Coupling flagged:** do **not** implement the join with per-username `GET /v3/user/existsInKeycloak`. It is N round-trips, and it is one of the five ungated SBDEV-2870 endpoints — if 2870 restores its guard, a non-`sb_admin` caller loses the audit. Use the bulk listing (E1-P) or `KeycloakService` directly (E2).

**E1. `db/audit-access-invariants.sql`** (new) — read-only, runnable before deploy. Six result sets, each carrying `mywms_user.name` so the Keycloak join can be applied:

1. Users with zero group membership.
2. Groups with zero roles; roles with zero functions (excluding `connector` rows created by `AccessService.addFunctionToUser`).
3. Roles holding `MOBILE_UI_LOG_IN` with zero `MOBILE_UI_VIEW_*`.
4. **Regression predictor** — per user, controllers reachable *after* the change vs. tiles seen today, parameterised by the §5.1-P3 cross-caller inventory (page↦controller is many-to-many). Any non-empty row is a user who will break.
5. Users holding `MOBILE_UI_VIEW_REPLENISHMENT` (C1's blast radius).
6. Full `mywms_user` roster for the join.

**E1-P. The pre-deploy join.** Intersect set 6 with the usernames from `GET /v3/user/findUsers`, then re-filter sets 1 and 4 to that intersection. **Only the intersected rows are actionable.** Rows outside it are unmapped/legacy and explicitly out of scope.

**E2. `GET /v3/adminAction/accessAudit`** on `AdminController`, `@PreAuthorize(Authority.IS_SB_ADMIN)`, read-only — the same six sets **already joined** against Keycloak via the injected `KeycloakService`, adding `keycloakMapped: true|false` per row plus a seventh set: Keycloak warehouse-group members with **no** `mywms_user` row. This is the ongoing surface; E1 + E1-P is the pre-deploy one. RC-2 applies to this annotation as to every `@PreAuthorize` here: correct today, unverifiable by unit test. The endpoint is diagnostic and read-only.

### 3.6 Rejected alternatives

| Option | Why rejected |
|---|---|
| **Per-method `@PreAuthorize` with a custom SpEL predicate** | Fails RC-2 outright. `standaloneSetup` installs no method-security advisor, so no controller unit test in this repo can observe it, and the `@SpringBootTest` lane that could is down (SBDEV-2217). This is precisely the configuration in which SBDEV-2863 shipped a broken expression that returned HTTP 500 to every caller for nine months, undetected. Choosing it would re-create the conditions of the last incident. |
| **Service-layer `accessService.requireFunction(...)` at each entry point** | Structurally incomplete. Seven controllers call repositories or `SyspropService` **directly** (`PickingController:229,349`; `TruckLoadingController:55`; `CycleCountLosController:88-91,215-219`; `PalletizingController:120`; `MoveStockController:73`; `TransferOrderController:95`; `ReplenishController:121`), and `GET /v3/truckLoading/orderList` never touches a service at all — it would remain ungated. It also multiplies the number of places to forget from 1 to 66, and `MobileReplenishService.fulfillMultipleUnitLoads:1002` self-invokes `:1015`, so a proxy-based variant would be silently bypassed. |
| **Path-keyed `HandlerInterceptor` (external `Map<String,String>`)** | Same enforcement point as the chosen design but the mapping is string-typed and lives away from the controller — a path change silently unmaps a controller, which is the SBDEV-2863 failure shape again in a new place. |
| **Per-request `@Cacheable` on the resolved function set (former A6)** | Broken three ways as drafted, not merely optional: the key expression is not valid SpEL without `T(net.aim_ai.wms.landlord.config.TenantContext)`; `TenantProfile` has **no `toString()`**, so the key resolves to an identity hash and its own "key includes the tenant" test would go **green over a useless key**; and `@Cacheable` on a method invoked from the same bean is self-invocation, so the proxy is bypassed and the cache is silently dead — the identical defect this plan cites at `MobileReplenishService:1002`. The interceptor already caps the cost at **one** `getAllRoles` per request rather than one per endpoint, so the cache was an optimisation, not a requirement. **Dropped.** |

---

## 4. Architecture Overview

```
 mobile-ui                                wms2-api
┌────────────────────────┐   HTTP    ┌────────────────────────────────────────────────────┐
│ router                 │──────────▶│ TenantFilter  @Order(HIGHEST_PRECEDENCE)           │
│  middleware/           │           │   └─ TenantContext.setCurrentTenant(...)           │
│   require-function.js  │◀── Fix B  ├────────────────────────────────────────────────────┤
│    ├ util/menuCatalog  │           │ SecurityFilterChain                                │
│    └ home/ensureRoles  │           │   ├ MultiTenantJwtDecoder → SecurityContext        │
│                        │           │   ├ /v3/** hasAnyAuthority("wms_user")   ← floor   │
│ store/home.js          │           │   └ IdempotencyFilter                              │
│   pageList → tiles     │           ├────────────────────────────────────────────────────┤
└────────────────────────┘           │ DispatcherServlet                                  │
                                     │  └ FunctionGuardInterceptor        ← Fix A   │
                                     │     1. HandlerMethod?            no → pass         │
                                     │     2. declaring =                                 │
                                     │          hm.getMethod().getDeclaringClass()        │
                                     │          ── AdminController alias → pass ──────────┼─▶ ~90 aliases
                                     │          ── StockUnit/Dashboard/                   │   unchanged
                                     │             ReplenishOrder      → pass ────────────┼─▶ §0.B unchanged
                                     │     3. @RequiresFunction: method ▸ declaring       │
                                     │     4. none + declaring in guarded set             │
                                     │             → DENY (fail closed)                   │
                                     │     5. AccessService.checkAnyAccess(user, fns)     │
                                     │          └ getAllRoles (tenant DB, 5-table join)   │
                                     │          └ deny path only: findByName → typed      │
                                     │            reason for diagnosis          ← A7      │
                                     │     allow → handler                                │
                                     │     deny  → 403 ProblemDetail{reason, functions}   │
                                     ├────────────────────────────────────────────────────┤
                                     │ 11 controllers · 66 endpoints                      │
                                     └────────────────────────────────────────────────────┘

  RepositoryRestHandlerMapping (/v3/section, /v3/stockunit, /v3/client, …)
     └─ never reaches the interceptor at all (A9) — by construction, not by predicate
```

**Deny semantics.** `403` + `ProblemDetail`. **Never call `response.reset()`** — Spring Security's `CorsFilter` has already written `Access-Control-Allow-Origin`, and `reset()` strips it, turning the 403 into a generic browser network error. Nothing is written at `preHandle` time, so no reset is needed; use `resetBuffer()` if a body must be rewritten.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

D1 is **hard-on at deploy with no feature flag** — a locked decision. These prerequisites are what replaces the kill switch.

| # | Prerequisite | Blocking? |
|---|---|---|
| **P1** | Run `db/audit-access-invariants.sql` against **every active tenant DB in every environment** (dev, UAT, prd — wineco ×2, hydra ×2, shipitez ×2), then apply the **E1-P Keycloak join**. Attach both raw output and joined view to the ticket. | **YES** |
| **P2** | **Over the Keycloak-mapped population only:** result set 4 (regression predictor) must be empty on prd, and any mapped user in set 1 (no group) must have a named remediation applied before the image lands. **Unmapped rows are explicitly not a blocker** — they cannot authenticate. 🔴 **AMENDED 2026-08-18 (§14.6): an empty set 4 is NOT self-evidently an all-clear.** On WineCo dev it is an artifact — all 3 live `CS-REP` holders also carry `super-admin`, so the at-risk role has no exclusive holder and the impact query returns nothing. The audit must **distinguish "no affected users" from "the affected roles have no exclusive holders in this tenant"**, and be run per tenant. Hydra UAT's empty result is the genuine kind (every live user holds ≥1 `MOBILE_UI_VIEW_*`); dev's is not. Same number, opposite meaning. | **YES** |
| **P3** | Re-derive the **complete bidirectional** cross-caller inventory: every `$axios` path in `wms2-mobile-ui` (`store/*.js`, `pages/*.vue`, `components/**`) *and* in `wms2-web-ui`, reconciled against §0.A/§0.B. The first enumeration missed a whole direction; assume this one can too. | **YES** |
| **P4** | Build the golden map **from reflection**, not from the §0.A number. Assert the reflected set equals the §3.1-A5 table. | **YES** |
| **P5** | Confirm `mywms_role_mywms_function` uniqueness on a real tenant DB (`\d`) so §3.4 part 2 uses the right idempotency guard. | **YES** |
| **P6** | Re-sweep `V2.2.*` across **all remote branches** at PR time. `origin/develop` head is V2.2.16; local is 36 commits stale. | **YES** |
| **P7** | **Deploy order: `wms2-mobile-ui` first, then `wms2-api`.** Mobile-first is strictly safe — the client guard denies nothing the server would allow. API-first 403s operators before the client can explain why. | **YES** |
| **P8** | Write the rollback runbook into the ticket: the revert is `WebConfig`'s interceptor registration (redeploy); the **faster** remedy for a single affected role is an administrator grant through the existing User Management screen, no deploy required. | **YES** |
| **P10** | 🔴 **Make `retryCondition` stop retrying an authorization 403** (§3.2-B5). Both UIs currently retry a 403 three times then `$kc.logout()`, so every A7 deny logs the operator out instead of showing the message. Emit `X-Authz-Denied` from the interceptor (A2 step 6) and skip retry when present. **Without this the deny UX is worse than today's.** **Re-scoped 2026-08-17:** the server half is no longer inherited from SBDEV-2870 — this plan must build the constant, the emitter **and** the CORS exposure (§3.1-A2b). No test in this repo can prove the last one — **and neither can a `curl`**, which is not CORS-filtered. Evidence is **M23**, a local browser test as an under-privileged user. | **YES** |
| ~~**P11**~~ | ✅ **CLOSED 2026-08-17 — decided and executed.** #166 merged first (`27e2f21`) and this ticket's worktree fast-forwarded onto it; the branch had no commits of its own, so this was a clean fast-forward, not a rebase, and nothing had to be replayed. The golden map and startup-assertion baseline will now be built once, against a stable surface. Verified post-merge: `AdminController` = **9** mapped methods, `UserAdministrationController` present, Flyway head still **V2.2.16** so V2.2.17 remains free (P6's all-remote sweep is still owed at PR time). See §14.3. | Done |
| **P9** | ~~Report the §0.C finding to SBDEV-2870 — its five endpoints have ~11 URLs each.~~ **CLOSED 2026-08-17** — reported, and PR #166 acted on it: four of the five endpoints moved to a standalone controller and now have one URL each (§0.C consequence 2). | Done |

### 5.2 Implementation checklist

0. ✅ **Base resolved** — worktree is on `27e2f21` (post-#166). Done 2026-08-17; nothing reflective was written before it.
1. Create `security/RequiresFunction.java`, `security/AccessDecision.java`, `security/FunctionGuardInterceptor.java`.
2. Add `AccessService.doesUserHaveAnyAccess` + `checkAnyAccess`; leave `doesUserHaveAccess` and its 5 call sites untouched.
3. **Move `OrderCancellationController` into `controller/mobile/`** (package line + file move; zero external references — verified). Do not add `extends AdminController`.
4. Annotate all 11 controllers per §3.1-A5; derive the `ReplenishController` split from `store/replenish.js` callers.
5. Register the interceptor in `WebConfig`; add the `SmartInitializingSingleton` startup assertion (A8).
6. Add `MOBILE_UI_VIEW_REPLENISH_REQUEST` to `FunctionEnum`; extend the `UtilRestController` seed (C2).
7. Write `V2.2.17__seed_mobile_workflow_functions.sql` and `db/audit-access-invariants.sql`.
8. Add `AccessAuditService` + `GET /v3/adminAction/accessAudit`.
9. Mobile UI: `util/menuCatalog.js`, `middleware/require-function.js`, `nuxt.config.js`, `store/home.js`, `pages/not-authorized.vue`, `plugins/axios.js` — **including the `retryCondition` fix (P10); the message rendering is inert without it**.
10. Add the `setupMockMvcWithGuard` **additive** overload to `BaseControllerUnitTest` (do not modify `setupMockMvc`).
11. Update `sbdocs`: `wms2-keycloak-role-matrix.md` (username-only Keycloak link; `AdminController` inheritance multiplies each mobile controller's URL surface by **9** post-#166) and `wms2-function-to-docs-map.md` §9 — **which must also gain the new `UserAdministrationController` (§0.26)**.
12. **(A2b, new)** Add `Authority.AUTHZ_DENIED_HEADER`; add the header to `SecurityConfiguration.corsConfigurationSource` using the existing SBDEV-2632 additive + `contains()` shape; extend `SecurityConfigurationTest`'s **exact** exposed-header expectation. Do this in the *same* commit as the interceptor's emit — a header without its CORS entry is a silent no-op in the browser.

---

## 6. Test Plan

Rules: **no `@SpringBootTest`** (SBDEV-2217 down); **no reliance on `standaloneSetup` evaluating annotations** (it does not); `BusinessException`'s 1-arg ctor sets `key="placeholder"`, so assert `getKey()`, never `getMessage()`.

> **Verified prerequisite for this whole strategy:** `StandaloneMockMvcBuilder.addInterceptors(HandlerInterceptor...)` and `addMappedInterceptors(...)` exist on the classpath (spring-test 6.2.15). A `HandlerInterceptor` **is** honoured by `standaloneSetup`, where `@PreAuthorize` is not. That asymmetry is the entire reason this mechanism was chosen, and it is confirmed rather than assumed.

### 6.1 New / updated tests — `wms2-api`

**`unit/security/FunctionGuardInterceptorUnitTest`** — plain JUnit + Mockito, `MockHttpServletRequest/Response`, `HandlerMethod` built by reflection over the **real** controller classes.

`allowsWhenUserHoldsTheClassLevelFunction` · `deniesWith403WhenUserHoldsNoneOfTheFunctions` · `deniesResponseBodyNamesTheRequiredFunctionAndReason` · `deniesWithoutCallingResponseReset` (asserts a pre-set `Access-Control-Allow-Origin` survives) · `methodLevelAnnotationOverridesClassLevel` · `anyOfSemantics_allowsWhenUserHoldsTheSecondFunction` · **`resolvesAnnotationFromDeclaringClassNotBeanType`** · **`inheritedAdminControllerAliasIsNotGatedByTheSubclassAnnotation`** (builds a `HandlerMethod` for `AdminController#findUsers` with `PutawayController` as bean type; asserts **allow**) · `passesThroughWhenHandlerIsNotAHandlerMethod` · `passesThroughForUnannotatedNonMobileController` · `deniesUnannotatedControllerInTheGuardedSet` · `callsGetAllRolesExactlyOncePerAllowedRequest` · `doesNotProbeUserExistenceOnTheAllowPath` · `deniesWithNoFunctionsReasonWhenUserRowExistsButHasNoGroups` · `deniesWithUnprovisionedReasonWhenUserRowIsAbsent` · `deniesWithMissingFunctionReasonWhenUserHasOtherFunctions` · `incrementsDeniedCounterTaggedWithControllerFunctionAndReason` (`SimpleMeterRegistry`) · **`deniedResponseCarriesTheAuthzDeniedHeaderNamingTheFunction`** (A2b — asserts the header is present on deny, names the required function, and is **absent** on the allow path).

**`unit/config/SecurityConfigurationTest`** (extend, A2b) — **`corsConfigurationSource_exposesAuthzDeniedHeader_whenPropertyAbsent`** and **`corsConfigurationSource_doesNotDuplicateAuthzDeniedHeader_whenPropertyAlreadySuppliesIt`**, plus the existing `…_doesNotDuplicateHeader_whenPropertyAlreadySuppliesIt` **`containsExactly`** list extended from one header to two. See the ⚠️ in A2b item 3 — that existing case is the one that goes red, and relaxing it is the wrong fix.

> ⚠️ **What no unit test here can prove — and what no `curl` can prove either.** All of these read the header off a `MockHttpServletResponse`, where CORS filtering does not exist. A missing `Access-Control-Expose-Headers` entry is invisible to every test in this repo, **and equally invisible to `curl` and to the DevTools Network panel** — neither is subject to CORS header filtering, which restricts only what *JavaScript* may read. It manifests in exactly one place: JS calling `headers.get()` in a browser on a cross-origin response. **AC-31's evidence is M23, a local browser test** (see the manual matrix), not a green test and not a green `curl`. This is the same class of gap as the `@PreAuthorize` untestability that motivated the whole mechanism (RC-2), and the same shape as `wms2-response-reset-strips-cors-headers`.

**`unit/security/FunctionGuardStartupAssertionUnitTest`** (A8) — `failsStartupWhenAGuardedControllerLacksTheAnnotation`; `failsStartupWhenAnUnmappedControllerCarriesIt`; `passesOnTheCurrentHandlerSurface`. Fed a fake `Map<RequestMappingInfo, HandlerMethod>`; no Spring context.

**`unit/config/FunctionGuardArchTest`** — ArchUnit (`archunit-junit5`, `pom.xml:311`).
`everyGuardedControllerCarriesRequiresFunction` (over all 11, **by explicit set — not by package**) · `everyRequiresFunctionValueIsADeclaredFunctionEnumConstant` · `controllerToFunctionMapMatchesTheGoldenMap` (hard-coded §3.1-A5 map vs reflection, exact equality — the anti-drift device) · `noSharedControllerCarriesRequiresFunction` (`StockUnitController`, `DashboardController`, `ReplenishOrderController`) · `adminControllerCarriesNoRequiresFunction` (prevents "fixing" the aliases by annotating the base class) · `noRepositoryCarriesRequiresFunction` · `noMobileControllerUsesPreAuthorizeForFunctionChecks`.

**`unit/service/AccessServiceUnitTest`** (extend) — `doesUserHaveAnyAccessReturnsTrueWhenAnyFunctionMatches` · `…ReturnsFalseOnEmptyRoleList` · `…ForEmptyVarargs` · `checkAnyAccessDistinguishesUnprovisionedFromNoFunctions` · `doesUserHaveAccessBehaviourIsUnchanged`.

**`unit/service/AccessAuditServiceUnitTest`** — `everyResultRowCarriesKeycloakMappedFlag` · `usersWithNoKeycloakIdentityAreFlaggedNotOmitted` · `doesNotCallExistsInKeycloakPerUsername` (pins the bulk path, guarding the SBDEV-2870 coupling).

**`unit/controller/mobile/FunctionGuardMockMvcUnitTest`** — per controller, `setupMockMvcWithGuard(controller, mockAccessService)`, so the real enforcement object sits in the real dispatch path.
11 × `{controller}IsForbiddenWithoutItsFunction` / `…IsAllowedWithItsFunction` · `lookupLocationByLocationNameIsAllowedForReplenishOnlyUser` · `putawayUserFindUsersAliasIsNotForbiddenForAUserWithoutPutAway` · `truckLoadingOrderListIsForbiddenWithoutTruckLoading` (the endpoint with **no service in its path**, proving the guard covers what a service-layer check could not) · `replenishFulfillMultipleUnitLoadsIsForbiddenWithoutReplenishment` (the self-invoking path, proving proxy semantics are irrelevant here).

> **Mandatory harness hygiene:** every test in this class must populate `SecurityContextHolder` (and `TenantContext` where the path reads it) in `@BeforeEach` and **clear both in `@AfterEach`**. A leaked ThreadLocal across the 11 pairs is exactly the false-green shape this repo has been bitten by before. Preferring the interceptor to resolve the username and pass it as a value (A2) keeps this contained.

### 6.2 New / updated tests — `wms2-mobile-ui`

Jest via `node_modules/.bin/jest` under nvm node — no `yarn` on PATH. **Baseline: `develop` has 2 always-red *suites* and 0 failing tests — compare the tests count, not the suites count.**

`test/util/menuCatalog.spec.js` — `menuCatalogHasTwelveEntries` · `everyEntryHasTitleLinkAndRole` · `deriveRouteFunctionMapCoversEveryPageFile` (**with an explicit exclusion set**: `index`, `not-authorized`, `unhealthy-tenant`, `unknown-tenant` — `pages/` holds 16 files, 12 of them tiles).
`test/middleware/requireFunction.spec.js` — `waitsForEnsureRolesLoadedBeforeDeciding` · `allowsWhenUserHoldsTheFunction` · `redirectsToNotAuthorizedWithWorkflowAndFnQueryParams` · `allowsUnmappedRoutes` · `routesToUnhealthyTenantWhenRolesFetchFailed` · `doesNotRefetchRolesOnASecondNavigation`.
`test/store/home.spec.js` — `ensureRolesLoadedIsIdempotentUnderConcurrentCalls` · `setMenusSetsRolesErrorOnFailure`.
`test/pages/notAuthorized.spec.js` — `usesALayoutThatExistsInLayoutsDir` · `rendersTheMessageVariantForEachDenyReason`.

### 6.3 Manual test plan

> ⚠️ **Every `curl` row below must assert the HTTP status line, not only the body or a header** (review ③,
> §14.4). A grep that finds nothing looks the same whether the assertion failed or the request never reached
> the filter chain — a malformed URL is rejected by Tomcat at 400 with no CORS headers at all. Assert the
> status first, then the payload.

| # | Persona / setup | Action | Expected | Result |
|---|---|---|---|---|
| M1 | `outbound-forklift` (Truck Loading + Lookup) | deep-link `/mobile/cycle-count` | `/not-authorized`, layout **renders**, names "Cycle Count" + `MOBILE_UI_VIEW_CYCLE_COUNT` | |
| M2 | same | `curl …/v3/cycleCountLos/…` | **403** + `ProblemDetail{reason:"MISSING_FUNCTION"}`; `Access-Control-Allow-Origin` present; `Access-Control-Expose-Headers` names **both** headers | |
| M3 | same | home screen | Truck Loading + Lookup tiles only; both work end-to-end | |
| M4 | `receiving` | Replenish Process → scan a location | succeeds (method-level override) | |
| M5 | hand-made role: `REPLENISHMENT` without `INFO` | Replenish Process → scan a location | succeeds — the many-to-many case a class-only gate breaks | |
| M6 | web-UI admin | Handling Units → Stock Units → transfer | **succeeds** — §0.B exclusion holds | |
| M7 | web-UI admin | Pick & Pack Monitor, Replenish Monitor, Internal Ops → Replenishments | all **succeed** — §0.B | |
| M8 | `outbound-forklift` | `curl …/v3/picking/user/findUsers` | **not 403** — same as `/v3/user/findUsers` today (§0.C) | |
| M9 | Keycloak-mapped user, `mywms_user` row exists, **no group** | log in, deep-link any tile | 403 `reason:"NO_FUNCTIONS"`; message names **group assignment** as the missing step | |
| M10 | Keycloak user with **no** `mywms_user` row | log in, deep-link any tile | 403 `reason:"USER_NOT_PROVISIONED"`; **`ERROR` log names the tenant** | |
| M11 | `outbound-worker` after V2.2.17 | Replenish Request tile | visible and functional | |
| M12 | user mid-session | admin revokes a function | tile gone on next `refreshMenus`; API denies immediately | |
| M13 | CS-REP (LOG_IN, no view fns) | log in | empty home screen, no error, no crash (C4) | |
| M14 | `sb_admin` staff, no `mywms_user` row | log in to mobile | empty screen, all workflows denied — **same as today**, no bypass (§10.2) | |
| M15 | `outbound-forklift` | `curl …/v3/lookup/searchSku/abc` | **403** — no UI caller | |
| M16 | `outbound-forklift` | `curl …/v3/replenish/reservedOrder` | **403** — no UI caller | |
| M17 | authorised picker | hard-refresh (F5) on `/mobile/picking` | loads; **no** bounce to `/not-authorized` | |
| M18 | `outbound-manager` after V2.2.17 | Transfer Process | visible and functional via `WEB_UI_VIEW_TRANSFER_ORDER` (D4) | |
| M19 | `sb_admin`, any tenant | `GET /v3/adminAction/accessAudit` | every row carries `keycloakMapped`; unmapped legacy rows flagged, not silently dropped | |
| M20 | any tenant, PR time | re-sweep `V2.2.*` across all remotes | V2.2.17 is still free (was AC-25) | |
| M21 | scratch tenant DB | run V2.2.17 twice | second run is a no-op; no duplicate `mywms_role_mywms_function` rows | |
| M22 | any tenant | run `db/audit-access-invariants.sql` | six named result sets, read-only, no error (was AC-30) | |
| **M23** | **local dev**: `wms2-mobile-ui` on `:3001` against `wms2-api` on `:8088`, signed in through real Keycloak as a user who authenticates but holds **no** mobile workflow function (the `CS-REP` shape) | Tap a gated tile (e.g. Cycle Count). Then, from the browser console on the same page: `(await fetch('http://localhost:8088/v3/cycleCountLos/…', {headers:{Authorization:'Bearer '+token}})).headers.get('x-authz-denied')` | **(a)** the A7 denial message renders, **(b)** the operator is **NOT** logged out and no "Maximum unauthorized request attempts" toast appears, **(c)** the console probe returns a **non-null** function name | **AC-31's + P10's evidence of record — and the only admissible form.** See the ⚠️ below: `curl` and the DevTools Network panel both **fail to discriminate** here. Requires no deployed environment. |

> ⚠️ **Why M23 is a browser test and not a `curl` — and why DevTools will not do either.** This row was
> drafted twice as a cross-origin `curl -H 'Origin: …'` before the obvious was noticed: **`curl` never has
> response headers filtered by CORS.** It reads `X-Authz-Denied` whether or not the header is exposed, so a
> green `curl` is fully compatible with a browser that cannot see it — the precise failure P10 exists to
> prevent. **The DevTools Network panel is no better:** it renders every response header regardless of
> exposure, because CORS restricts what *JavaScript* may read, not what the panel displays. Only JS actually
> reading the header discriminates — hence the behavioural assertions and the explicit `headers.get()` probe.
>
> **A credential-free variant was considered and dropped.** An unauthenticated cross-origin request would
> still show `Access-Control-Expose-Headers` on its 401 (Spring Security's `CorsFilter` runs before
> authentication), which looked like a way to check the CORS half with no test account. It buys nothing: the
> programmatic `addExposedHeader` in §3.1-A2b is **additive and override-proof by construction**, so no
> environment's `REST_SECURITY_CORS_EXPOSED_HEADERS` can drop the header and there is no ***silent***
> env-specific drift for such a check to catch. It would have been a row that can only ever pass.
> *(Wording made precise by review ④, 2026-08-19 — see §14.4a for why the qualifier is load-bearing.)*
>
> **Local is a valid test bed, and that is not an accident worth assuming.** `nuxt.config.js` declares
> `modules: ['@nuxtjs/axios', '@nuxtjs/toast']` — **no `@nuxtjs/proxy`** — and the browser calls
> `http://localhost:8088/v3` directly from a page served on `:3001`. Different port, different origin, CORS
> fully in force. **Had the API been proxied through the Nuxt dev server, every request would be same-origin
> and this entire class of defect would be invisible locally**, no matter how carefully tested. Re-check that
> before trusting a local result.

### 6.4 Test execution (fill in after running)

| Command | Result |
|---|---|
| `mvn test -Dtest=FunctionGuardInterceptorUnitTest` | |
| `mvn test -Dtest=FunctionGuardArchTest` | |
| `mvn test -Dtest=FunctionGuardMockMvcUnitTest` | |
| `mvn clean compile` | |
| `mvn test` (full) — expect the 2 known pre-existing failures | |
| `node_modules/.bin/jest` (mobile-ui) — compare **tests** count vs baseline | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2968-mobile-ui-function-gating-enforcement.sh` | |

> `mvn test` **mutates the tracked `archunit_store`** — revert it before committing. `-Dtest='Outer#method'` silently no-ops for `@Nested` tests.

### 6.5 Deliberately-skipped coverage

The full chain (JWT → `TenantFilter` → security chain → interceptor → tenant DB) cannot be automated while **SBDEV-2217** is open. Covered by §6.3 and recorded here as skipped automated coverage, **not** as coverage. The `@PreAuthorize` on the new audit endpoint (E2) is likewise unverifiable by unit test (RC-2); it is read-only and diagnostic.

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | The cache was dropped (§3.6). The guard is stateless. |
| 2 | Connection pool math | **No** | One extra short read per request on a connection the request opens anyway; A7's `findByName` probe runs only on the deny path. No new pool or tenant. |
| 3 | Scheduled jobs | **N/A** | None added. |
| 4 | Long transactions | **No** | Runs *before* the handler; cannot extend a business transaction; opens and closes its own read. |
| 5 | Request affinity | **No** | Stateless per request. |
| 6 | Retry / idempotency | **No** | A denied request never reaches the handler; 403 is safely retryable. |
| 7 | Tenant context | **Yes — load-bearing** | Read transitively via the routing datasource and for A7's log line. Runs in `DispatcherServlet`, same thread, strictly after `TenantFilter` (`HIGHEST_PRECEDENCE`). No async boundary. Pinned by `deniesWhenTenantContextIsAbsent`. |
| 8 | Distributed locks | **N/A** | None. |
| 9 | Cache invalidation | **N/A** | No cache. |
| 10 | External notifications | **N/A** | None. |

### v2-only constraint checklist

| # | Constraint | Verdict | Note |
|---|---|---|---|
| 1 | OSIV disabled | ✓ OK | Repository calls return `List<String>` / `Optional<User>` — no lazy proxy escapes. |
| 2 | `tenantTransactionManager` | ✓ N/A | No `@Transactional` added. `UserRepository` inherits it from `@EnableJpaRepositories`. **A bare `@Transactional` on the new methods would bind to the `@Primary` landlord TM and hit the wrong DB.** |
| 3 | `readOnly = true` | ✓ N/A | Per row 2. |
| 4 | Caffeine invalidation | ✓ N/A | Cache dropped (§3.6). |
| 5 | Jakarta namespace | ✓ Required | `jakarta.servlet.http.*` in the interceptor — never `javax.*`. |
| 6 | H2-compatible test SQL | ✓ N/A | All new tests are Mockito/ArchUnit. The audit SQL is Postgres-only and never executed by a test. |
| 7 | `BaseControllerTest` | ⚠ additive only | `BaseControllerUnitTest` gains `setupMockMvcWithGuard(...)`; the existing `setupMockMvc` (`:44-56`) is untouched, so no existing test changes behaviour. |
| 8 | Micrometer metrics | ✓ New | `wms2.authz.allowed`, `wms2.authz.denied{controller,function,reason}`. New names, no reuse. |

---

## 8. Risks & Mitigations

| # | Risk | Sev | Mitigation | Residual |
|---|---|---|---|---|
| **R1** | A Keycloak-mapped user whose **group assignment was missed** is denied every tile, with a message and log line indistinguishable from an ordinary permissions gap. | Low | A7's typed reason (`NO_FUNCTIONS`, distinct log, distinct metric tag, message naming *group assignment*) + §5.1-P2's sweep over the mapped population + M9. Only Keycloak-mapped users can authenticate, and mapping and group assignment are steps in the same user-management flow. | Low. Caught pre-deploy by P2 or post-deploy by a single `reason=no_functions` log line; fixed by an administrator grant with no deploy. |
| **R2** | **D1 hard-on with no kill switch** — a wrong mapping or missing grant is a workflow outage. | **High** | §5.1-P1/P2/P3; the `denied` metric as a 24 h watch; §5.1-P8's runbook — revert is `WebConfig`'s registration, and the faster remedy for a single role is an administrator grant through User Management with no deploy. | **Accepted per D1**, named explicitly. |
| **R3** | A page calls another workflow's controller. Two known (`replenish → lookup`; the five §0.B shared endpoints). The first enumeration missed a whole direction. | **High** | §5.1-P3 re-derives *both* directions; method-level overrides; §0.B structural and ArchUnit-pinned; M4–M7. | Low after P3. A miss shows as a `denied` spike on one controller within minutes. |
| **R4** | `AdminController` inheritance mis-gates ~90 alias URLs (~130 pre-#166). | **High** | Declaring-class resolution (§3.1-A2 step 2); `resolvesAnnotationFromDeclaringClassNotBeanType`, `inheritedAdminControllerAliasIsNotGatedByTheSubclassAnnotation`, `adminControllerCarriesNoRequiresFunction`; M8. | Very low — three independent tests. |
| **R5** | A future mobile-only controller lands **outside** the guarded set and silently fails open — the defect the package predicate would have shipped. | **High** | A8: explicit guarded set + the `SmartInitializingSingleton` startup assertion that fails bean init unless the annotated set equals the golden-map keyset; `FunctionGuardStartupAssertionUnitTest`. | Low — a miss fails startup, not silently at runtime. |
| **R6b** | 🔴 **An authorization 403 logs the operator out.** Both UIs retry a 403 three times with a token refresh, then `$kc.logout()` on an authenticated session (`plugins/axios.js:35-37, :92`) — so every A7 deny presents as a session failure and the typed messages never render. Found 2026-08-17. | **High** | §5.1-P10 — emit `X-Authz-Denied` from the interceptor and return `false` from `retryCondition` when present; `test/plugins/axios.spec.js#doesNotRetryWhenXAuthzDeniedHeaderPresent`. | None once P10 lands. **The plan must not ship without it** — the deny UX would otherwise be worse than today's generic toast. **Residual raised 2026-08-17:** P10's server half is now this plan's own work (§3.1-A2b), and its CORS half is unprovable by any test in this repo — so the failure mode "header emitted, browser can't read it, operator still logged out" is live until **M23** is run (AC-31) — and M23 must be the browser test, since a `curl` cannot distinguish that failure from success. |
| **R13** | 🔴 **The `X-Authz-Denied` contract is dropped by both plans.** It was reverted from SBDEV-2870 on the argument that 2967 Fix E would carry it, while this plan — which lands *first* and needs it — recorded it as already-done. Each plan can point at another as the owner. Found 2026-08-17. | **High** | §3.1-A2b assigns the constant, the emitter and the CORS entry **here**, and 2967 §3.5.1-4 / §5.1-P8 are edited to consume rather than create. Test: `deniedResponseCarriesTheAuthzDeniedHeaderNamingTheFunction` + `corsExposedHeadersContainsAuthzDeniedHeader`. | Low now that ownership is written down in both plans — but this is the second time a relocation between these three tickets left an orphan (the first cost 2870 its §10.1 blocker). Re-check ownership after **any** future scope move between 2870/2967/2968. **Mitigation superseded 2026-08-19 (§14.7)** — prose replaced by the `[inherited]` verify-row class, after a third instance (§14.6) showed the defect is any inherited claim, not only a relocation. |
| **R6** | Nuxt cold-start — the middleware runs before roles load and bounces every hard refresh to `/not-authorized`. | Medium | Memoised `ensureRolesLoaded()` awaited in the middleware; three distinct states (loading / denied / fetch-failed); `waitsForEnsureRolesLoadedBeforeDeciding`; M17. | Low. |
| **R7** | Deploying api before mobile-ui gives the generic toast instead of the actionable message. | Medium | §5.1-P7 pins **mobile-ui first**; mobile-first is strictly safe. | Low. |
| **R8** | V2.2.17 collides with a version on an unmerged branch; the local checkout is 36 commits stale. | Medium | §5.1-P6 re-sweep across all remotes at PR time; M20. | Low. |
| **R9** | The audit reads as noise or false alarm because unmapped legacy rows dominate — the exact misreading that produced the "42 of 96" scare. | Medium | §3.5 chooses the Keycloak cross-check over a hand-applied caveat; E1-P is a mandatory join step; E2 stamps `keycloakMapped` on every row; M19. | Low. |
| **R10** | The audit is implemented with per-username `existsInKeycloak` — N round-trips **and** an ungated SBDEV-2870 endpoint that may gain a guard. | Low | §3.5 states the bulk requirement; `doesNotCallExistsInKeycloakPerUsername` pins it. | Low. |
| **R11** | `mywms_role_mywms_function` has no unique constraint → a re-run duplicates grants. | Low | `NOT EXISTS` guard, not `ON CONFLICT`; §5.1-P5; M21. `getAllRoles` is `SELECT DISTINCT`, so duplicates are functionally harmless but pollute the audit. | Low. |
| **R12** | The five §0.B shared endpoints stay reachable by a denied user — the tile is enforced, the shared capability is not. | Low | Documented as an explicit scope boundary in §0.B and in the ticket's closing note. Narrowing it needs a per-caller distinction the shared controllers do not support. | **Accepted and stated.** Follow-up ticket. |
| **R14** | `IS_SB_ADMIN` on the new audit endpoint is itself unverifiable by unit test (RC-2 applies to it too). | Low | Read-only, diagnostic; the `/v3/**` `wms_user` floor bounds exposure; exposes structure, not credentials. | Accepted. |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance criteria (TDD-gate ready)

| # | Criterion | Failing test on `develop` |
|---|---|---|
| AC-1 | All **11** guarded controllers carry `@RequiresFunction` — asserted over an explicit set, not a package. | `FunctionGuardArchTest#everyGuardedControllerCarriesRequiresFunction` |
| AC-2 | The {declaring class → functions} map equals the §3.1-A5 golden map exactly. | `…#controllerToFunctionMapMatchesTheGoldenMap` |
| AC-3 | Every annotation value is a declared `FunctionEnum` constant. | `…#everyRequiresFunctionValueIsADeclaredFunctionEnumConstant` |
| AC-4 † | `StockUnitController`, `DashboardController`, `ReplenishOrderController` carry **no** `@RequiresFunction`. | `…#noSharedControllerCarriesRequiresFunction` |
| AC-5 † | `AdminController` carries none, and no Spring Data repository does either. | `…#adminControllerCarriesNoRequiresFunction`, `…#noRepositoryCarriesRequiresFunction` |
| AC-6 | An inherited `AdminController` method reached via a mobile alias URL is **allowed** for a user lacking that controller's function. | `FunctionGuardInterceptorUnitTest#inheritedAdminControllerAliasIsNotGatedByTheSubclassAnnotation`; `FunctionGuardMockMvcUnitTest#putawayUserFindUsersAliasIsNotForbiddenForAUserWithoutPutAway` |
| AC-7 | A guarded handler denies with **403** and the handler is never invoked. | `…#deniesWith403WhenUserHoldsNoneOfTheFunctions` |
| AC-8 | The 403 body names the required function(s) and the reason; the response retains `Access-Control-Allow-Origin`. | `…#deniesResponseBodyNamesTheRequiredFunctionAndReason`, `…#deniesWithoutCallingResponseReset` |
| AC-9 | A user with **no `mywms_user` row** is denied with `reason=USER_NOT_PROVISIONED`, logged at `ERROR`, metered `reason=unprovisioned` — distinct from a user who exists with no functions. | `…#deniesWithUnprovisionedReasonWhenUserRowIsAbsent` + `…#deniesWithNoFunctionsReasonWhenUserRowExistsButHasNoGroups` |
| AC-10 | The existence probe does **not** run on the allow path. | `…#doesNotProbeUserExistenceOnTheAllowPath` |
| AC-11 | A handler in the guarded set with no annotation is **denied** at runtime, **and** startup fails. | `…#deniesUnannotatedControllerInTheGuardedSet`; `FunctionGuardStartupAssertionUnitTest#failsStartupWhenAGuardedControllerLacksTheAnnotation` |
| AC-12 † | A handler outside the guarded set with no annotation passes through. | `…#passesThroughForUnannotatedNonMobileController` |
| AC-13 | Exactly one `getAllRoles` call per allowed request. | `…#callsGetAllRolesExactlyOncePerAllowedRequest` |
| AC-14 | `GET /v3/lookup/locationByLocationName/{n}` succeeds for a `REPLENISHMENT`-only user. | `FunctionGuardMockMvcUnitTest#lookupLocationByLocationNameIsAllowedForReplenishOnlyUser` |
| AC-15 | `GET /v3/truckLoading/orderList` — which reaches `billofladingRepository` with **no service in its path** — is gated. | `…#truckLoadingOrderListIsForbiddenWithoutTruckLoading` |
| AC-16 | `POST /v3/replenish/fulfillMultipleUnitLoads` — the self-invoking path — is gated. | `…#replenishFulfillMultipleUnitLoadsIsForbiddenWithoutReplenishment` |
| AC-17 | Each of the 11 controllers returns 403 for an empty role list and 200 for its mapped function, **through MockMvc with the real interceptor installed**. | `FunctionGuardMockMvcUnitTest` (11 pairs) |
| AC-18 | `doesUserHaveAnyAccess` returns `false` for an empty role list and for empty varargs. | `AccessServiceUnitTest#…ReturnsFalseOnEmptyRoleList`, `…ForEmptyVarargs` |
| AC-19 | The route middleware does not call `next()` until `home/ensureRolesLoaded` resolves. | `test/middleware/requireFunction.spec.js#waitsForEnsureRolesLoadedBeforeDeciding` |
| AC-20 | A denied navigation routes to `/not-authorized` with `workflow` and `fn`. | `…#redirectsToNotAuthorizedWithWorkflowAndFnQueryParams` |
| AC-21 | `pages/not-authorized.vue` declares a layout that **exists** in `layouts/`. | `test/pages/notAuthorized.spec.js#usesALayoutThatExistsInLayoutsDir` — **red today**: `:20` is `layout: "splash"` and no `splash.vue` exists in this repo |
| AC-22 | Every workflow page under `pages/` has a route→function map entry, excluding `index`, `not-authorized`, `unhealthy-tenant`, `unknown-tenant`. | `test/util/menuCatalog.spec.js#deriveRouteFunctionMapCoversEveryPageFile` |
| AC-23 | A roles-fetch failure routes to the unhealthy-tenant page, not `/not-authorized`. | `…#routesToUnhealthyTenantWhenRolesFetchFailed` |
| AC-24 | `MOBILE_UI_VIEW_REPLENISH_REQUEST` exists and `initDB` grants the three functions to the C2 roles. | `UtilRestControllerSeedUnitTest#seedsMobileWorkflowFunctionsForEveryPersona` |
| AC-25 | `wms2.authz.denied` carries `controller`, `function`, and `reason` tags. | `…#incrementsDeniedCounterTaggedWithControllerFunctionAndReason` |
| AC-26 ‡ | No mobile controller uses `@PreAuthorize` for a function check. | `FunctionGuardArchTest#noMobileControllerUsesPreAuthorizeForFunctionChecks` |
| AC-27 | Every result row from the audit surface carries `keycloakMapped`, and the bulk Keycloak path is used. | `AccessAuditServiceUnitTest#everyResultRowCarriesKeycloakMappedFlag`, `#doesNotCallExistsInKeycloakPerUsername` |
| AC-28 | The Replenish split is real in **both** directions: a `REPLENISH_REQUEST`-only user reaches `GET /v3/replenish/requestLocation/{x}` but is **403** on `GET /v3/replenish/clientList`; a `REPLENISHMENT`-only user is the exact inverse. | `FunctionGuardMockMvcUnitTest#replenishRequestOnlyUserReachesRequestLocationButNotClientList`, `#replenishmentOnlyUserReachesClientListButNotRequestLocation` |
| **AC-29** *(A2b)* | A denied response carries `X-Authz-Denied: <function>`; an allowed response does **not**. | `…#deniedResponseCarriesTheAuthzDeniedHeaderNamingTheFunction` |
| **AC-31** *(A2b)* ★ | The browser can **read** that header cross-origin: `Access-Control-Expose-Headers` lists `X-Authz-Denied`, exactly once, even when `rest.security.cors.exposed-headers` also supplies it. | `SecurityConfigurationTest#corsConfigurationSource_exposesAuthzDeniedHeader_whenPropertyAbsent`, `#corsConfigurationSource_doesNotDuplicateAuthzDeniedHeader_whenPropertyAlreadySuppliesIt` — **plus M23 (local browser test), which is the real evidence** |

† **AC-4, AC-5, AC-12** "fail" on `develop` only because `RequiresFunction.class` does not compile yet. They are correctness pins on the implementation, not behavioural gates — stated so nobody mistakes them for evidence of a pre-existing defect.
‡ **AC-26 passes vacuously on `develop` today** (no mobile controller uses `@PreAuthorize` — confirmed). It is a **regression pin**, not a gate.

★ **AC-31 is only half-assertable, and the assertable half is the weaker one.** `SecurityConfigurationTest` proves the bean's `CorsConfiguration` *lists* the header; no test in this repo proves a real response carries `Access-Control-Expose-Headers`, because `MockMvc` installs no `CorsFilter` (the same blind spot recorded in `wms2-response-reset-strips-cors-headers`). **M23 — a local browser test as an under-privileged user, asserting the denial renders, no logout occurs, and `headers.get('x-authz-denied')` is non-null from JS — is the evidence of record.** Do not substitute a `curl` or a DevTools header listing; neither is CORS-filtered, so neither can fail in the way that matters.

Two former criteria are **not CI-assertable** and have moved to the manual matrix: "V2.2.17 is the highest across all remote branches at PR time" → **M20/M21**; "the audit SQL exists and returns six named result sets" → **M22**. Neither can be asserted by anything in the build. **M23** (above) joins them.

### 9.2 Verify script

`sbdocs/9-System/scripts/verify-SBDEV-2968-mobile-ui-function-gating-enforcement.sh`

Run it **before** any code change to capture the FAIL baseline, and again after each cluster of changes. Final acceptance is `Result: N pass, 0 fail`, pasted into the ticket. A grep-based script cannot prove its own assertions have teeth — the TDD gate's failing tests are the companion control.

---

## 10. Open Questions / Resolved Decisions

**Resolved**

- **10.1 Mechanism** — `@RequiresFunction` + one `HandlerInterceptor` resolving on the **declaring class**, with an explicit guarded set and a startup assertion. Not `@PreAuthorize` (RC-2 / SBDEV-2863); not a service-layer guard (§3.6).
- **10.2 No `sb_admin` bypass** — staff with no `mywms_user` row see nothing today and will reach nothing after. A bypass would create a path the tile filter lacks, re-introducing the divergence being fixed.
- **10.3 Granularity is per-tile.** Read/write splits within a workflow are a separate design question.
- **10.4 `GET /v3/user/getAllRoles/{username}` stays open** to any `wms_user` for any username (`UserController:294-297`). A genuine disclosure issue, but the route guard depends on it and gating it here breaks the client mid-change. Own ticket.
- **10.5 Replenish is split** (C1) with a back-compat grant so nobody loses access.
- **10.6 Transfer reuses `WEB_UI_VIEW_TRANSFER_ORDER`** (D4). No rename, no new constant.
- **10.7 CS-REP-style roles unchanged** (C4) — reported, not decided for the warehouse.
- **10.8 Invariant violations are reported, never repaired** (D2).
- **10.9 The five shared endpoints are excluded** (§0.B), structurally and ArchUnit-pinned, residual stated in R12.
- **10.10 The per-request cache does not ship** (§3.6).
- **10.11 `OrderCancellationController` moves into `controller/mobile/`** (A8), verified zero-reference.
- **10.12 CLOSED 2026-08-16 — the `ReplenishController` split is derived, not guessed.** 2 request-side endpoints (`requestLocation` :51, `requestAmount` :73, both dispatched from `components/replenish/request/`) and 9 process-side; full derivation and its three caveats in §3.1-A5.1. The fallback ("class-level only") was **not** needed — the `process/` and `request/` component subtrees have disjoint dispatch sets, so the split is clean.

**Open**

- *(none — §10.12 was the last one; the plan is gate-ready.)*

---

## 11. Notes

### 11.1 Pre-mortem

**PM-1 — "The web UI's Handling Units screen and both dashboard monitors started 403ing, and nobody connected it to a *mobile* ticket."** Cause: someone gated a shared endpoint. Control: §0.B is an explicit exclusion list, structural (those controllers are outside the guarded set) and pinned by `noSharedControllerCarriesRequiresFunction`; M6/M7 exercise all three web screens.

**PM-2 — "`GET /v3/picking/user/findUsers` started requiring the picking permission and the admin CSV import broke for half the URLs it has."** Cause: bean-type resolution instead of declaring-class. Control: §3.1-A2 step 2, three tests, and M8.

**PM-3 — "A newly-imported operator was denied every tile for an afternoon and the log said only 'no permission' — the row existed, the Keycloak identity existed, the group assignment step had been missed."** Cause: undifferentiated deny reasons. Control: A7's typed `AccessDecision`, a distinct `ERROR`/`WARN` split, a `reason` metric tag, and an operator message naming group assignment; M9/M10.

### 11.2 Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1.2 — live queries on WineCo dev + Hydra UAT; `db_verified: true` |
| 1 | All callsites enumerated | ✓ §0.A (11 controllers, 66 endpoints), §0.B (5 excluded with rationale), §0.C (aliases), §0.D |
| 2 | Adjacent bugs | ✓ §0.C (SBDEV-2870 ×11 URLs, → P9); §3.2-B4 (`splash` layout does not exist) |
| 3 | Backward compatibility | ✓ §3.4 part 2 back-compat grant; §0.B exclusions; `doesUserHaveAccess` untouched |
| 4 | Concurrency | ✓ §7 rows 4–6; stateless per request; no locks |
| 5 | Multi-tenant | ✓ §7 row 7; `TenantContext` strictly after `TenantFilter`; `deniesWhenTenantContextIsAbsent` |
| 6 | Error handling | ✓ A7's four reasons; 403 + `ProblemDetail`; no `response.reset()` |
| 7 | Observability | ✓ §6.1 metrics + §8-R2's 24 h watch signal |
| 8 | Rollback / migration | ✓ V2.2.17 (P6 re-sweep), P7 deploy order, P8 runbook |
| 9 | Test coverage | ✓ §6.1–§6.3; §6.5 records the skipped E2E lane honestly |
| 10 | Commit ordering (A2b) | ✓ `Authority.AUTHZ_DENIED_HEADER` + the `SecurityConfiguration` CORS entry land in **this branch's first commit**, not mid-branch — review ① — so SBDEV-2967 has something to reference by symbol from the moment 2968 exists. Row `A27` (`file_not_contains '"X-Authz-Denied"'`) enforces by-constant use here; 2967 mirrors it |
| 11 | Cross-version (v1↔v2) | no — v2-only. v1 has the same client-side-only pattern but a separate UI codebase and its own `FunctionEnum`; a v1 port is a separate plan if wanted. |

### 11.3 Provenance

Authored via the `wms-bugfix-plan` → `ralplan` consensus loop. The Planner pass produced the mechanism and structure; the Critic pass returned **ITERATE** with three must-fixes (the fail-closed invariant, the endpoint count, the cache), all incorporated. **The Architect pass did not complete** — it stalled without returning a review — so its two highest-value questions (the `AdminController` inheritance behaviour and the package-predicate gap) were verified directly against the code instead, as were the endpoint count, the `standaloneSetup` interceptor capability, the `OrderCancellationController` reference blast radius, and the missing `splash` layout. Any claim in this plan that rests on an unverified agent assertion is flagged inline; none currently does.

---

## 12. Relationship to SBDEV-2967 (web UI authorization)

[SBDEV-2967](https://app.clickup.com/t/868krr3rq) covers the same defect class on `wms2-web-ui`. The two are **complementary, not overlapping** — but three couplings run between them, and the web plan will ship a regression if it is drafted without them.

### 12.1 Disjoint surfaces, shared mechanism

This plan gates 11 **mobile-exclusive** controllers (66 endpoints). SBDEV-2967 covers the web menu (30 items), its route guards, and the 6 Admin tabs. No endpoint is gated by both — the five shared ones are excluded here by construction (§0.B).

The mechanism, however, is deliberately generic and **should be reused rather than rebuilt**: `@RequiresFunction` resolves on the declaring class, lets unannotated controllers through untouched, and keys fail-closed on an explicit set rather than on the `.mobile` package name (§3.1-A8). Nothing about it is mobile-specific except its name. For SBDEV-2967 the backend work reduces to *annotate the web controllers with `WEB_UI_VIEW_*`, extend the guarded set, extend the ArchUnit golden map.*

**Recommended sequencing: this plan lands first.** It builds the annotation, the interceptor, the startup assertion, the `setupMockMvcWithGuard` harness, the invariant audit, and the Flyway seed pattern. In the reverse order the web plan pays all of that cost instead.

### 12.2 The three couplings SBDEV-2967 must inherit

**C-1 — the five shared endpoints are a conflict zone, not a free win.** R12 records that a user denied `MOBILE_UI_VIEW_STOCK_TRANSFER` can still `POST /v3/stockUnit/transferStock`. It is tempting to read that as "SBDEV-2967 will close it." **It does not close cleanly**, because the mobile UI calls those controllers too:

| Controller | Web caller | Mobile caller |
|---|---|---|
| `StockUnitController` | Handling Units → Stock Units | Move Stock tile |
| `DashboardController` | Pick & Pack + Replenish Monitors | Picking + Replenish tiles |
| `ReplenishOrderController` | Internal Ops → Replenishments | Replenish tile |

Annotating `StockUnitController` with `WEB_UI_VIEW_STOCK_UNIT` alone **403s every mobile Move Stock operator** — a regression the web plan could ship unnoticed, since its own testing is web-side. Those three controllers need **ANY-of across both namespaces**, e.g. `{WEB_UI_VIEW_STOCK_UNIT, MOBILE_UI_VIEW_STOCK_TRANSFER}`. The annotation's ANY-of semantics already support this; the web plan simply has to know. If SBDEV-2967 adopts it, `noSharedControllerCarriesRequiresFunction` (AC-4) must be relaxed from "carries none" to "carries a cross-namespace ANY-of" — **do not delete the test, change its assertion**, or the §0.B exclusion silently stops being pinned.

**C-2 — the namespaces already cross; do not assert that they don't.** The mobile Transfer tile is gated on `WEB_UI_VIEW_TRANSFER_ORDER` (D4, deliberately retained). Any ArchUnit rule of the form "every `WEB_UI_*` constant belongs to a web controller" fails on `TransferOrderController`, which lives in `controller/mobile/`.

**C-3 — Flyway and seed collision.** Both plans touch `FunctionEnum`, the `UtilRestController` seed, and need a tenant migration. This plan claims **V2.2.17**. SBDEV-2967 must re-sweep **all remote branches** and take the next free version; if both are in flight, whichever merges second re-sweeps again. Versions are append-only and never reused.

### 12.3 What SBDEV-2967 should consume, not rebuild

- **The invariant audit** (`db/audit-access-invariants.sql` + `GET /v3/adminAction/accessAudit`, §3.5) is **not mobile-specific**. It reports users/groups/roles for the whole tenant.
- **The `mywms_user` ↔ Keycloak clarification** (username-only link, no mapping column, unmapped rows cannot authenticate — §2) applies identically and should not be re-derived.
- **The `AdminController` inheritance finding** (§0.C, ~130 aliases when found; ~90 after PR #166 — §14-Δ2) belongs to **SBDEV-2870**, not to either UI plan — but SBDEV-2967 is the one that will trip over it, since its blast radius *is* the Admin screen and SBDEV-2870's five ungated endpoints sit behind exactly that screen.

### 12.4 The asymmetry worth stating plainly (see also §13 — this widened on 2026-08-16)

The two tickets are complementary in mechanism but **not equivalent in severity**. Mobile already filters its menu client-side, so this plan closes a *bypass*. The web UI filters nothing — `layouts/default.vue:284-285` hardcodes `menuList["super-admin"]` for every authenticated user — so SBDEV-2967 is the larger exposure, and its hardest part is not the backend at all. It is the client-side layer that does not exist: the menu filter, the four dead persona menus in `util/appMenuList.js`, a route guard, and six ungated Admin tabs. **None of that ports from here, because mobile already had it.**

---

## 13. Target-state decision (2026-08-16) — this plan now builds the platform's only authorization mechanism

**Decision by Nam Park with Brent (BA), recorded in [wms2-keycloak-role-matrix.md §1.1](../../../3-Resources/architecture/wms2-keycloak-role-matrix.md).** Configuring default putaway locations belongs to `super-admin` (the WMS application admin), and **no function should be restricted to `sb_admin`**.

That reframes this ticket. It was scoped as "close a mobile bypass." It is now **the first implementation of the platform's sole fine-grained authorization mechanism.** Nothing in §0–§11 becomes wrong; the *significance* changes, and three things follow.

### 13.1 The end state

| Keycloak group | Purpose | Enforced? |
|---|---|---|
| `wms_user` | App access **and facility scope** | Yes — the `/v3/**` floor |
| `wms_admin` | `/actuator/**` only | Yes, narrowly |
| `sb_admin` | SiteBoss identity; reserved for future global actions | **No — retained, never checked** |

Everything else is `UserFunction` → `UserRole` → `UserGroup` → `User`. Two carve-outs are structural, not preference: actuator is per-JVM so there is no tenant DB to read a function from; and facility scope cannot become a function because `token.warehouse` → routing key → *which DB holds `mywms_function`* — choosing the facility is what selects the function table.

### 13.2 What changed in this plan as a result

**The guard is named namespace-neutrally.** `MobileFunctionGuardInterceptor` → **`FunctionGuardInterceptor`**; `MobileFunctionGuard*Test` → `FunctionGuard*Test`; `MobileFunctionGuardStartupAssertion` → `FunctionGuardStartupAssertion`; metrics `wms2.authz.mobile.{allowed,denied}` → **`wms2.authz.{allowed,denied}`**. Done before implementation deliberately — the rename costs minutes now and would mean touching every annotation site, the golden map and the verify script later. SBDEV-2967 and the `sb_admin` migration extend *these* types rather than introducing parallel ones. **Do not rename back toward "Mobile."**

`@RequiresFunction` needed no change; it was already neutral.

**What did NOT change:** the guarded set is still the 11 controllers in §0.A. The mechanism is platform-wide; this ticket's *coverage* is not. Widening it is SBDEV-2967's job and the `sb_admin` migration's job.

### 13.3 A design question this raises for later, deliberately not answered here

The runtime fail-closed rule (§3.1-A8) keys on an explicit guarded set, which was right for 11 controllers. If the set grows to most of the API, the natural inversion is **deny unless annotated across the whole `controller` package, with an explicit allowlist for genuinely public endpoints**. That is a larger change with a real blast radius and it should be reviewed on its own merits — recorded here so it is a decision rather than a drift. The startup assertion added in A8 is the right place for it when the time comes.

### 13.4 Follow-on work this unblocks or constrains

| Ticket | Effect |
|---|---|
| **SBDEV-2870** | **Unblocked.** Its recorded blocker — "restoring the guards 403s the User Management screen for every non-`sb_admin` admin" — dissolves under function gating: those endpoints take `WEB_UI_VIEW_USER_MANAGEMENT`, which the screen's users already hold. |
| **SBDEV-2967** | Extends `FunctionGuardInterceptor` and the golden map. See §12 for the three couplings. |
| **`sb_admin` migration** (no ticket yet) | The 18 `@PreAuthorize(IS_SB_ADMIN)` gates re-home onto functions. ⚠ **Two mechanisms needed**: the interceptor covers the 4 controller sites, but the 5 on `PutawayConfigService` are service-layer and its write path is served by `RepositoryRestHandlerMapping`, which does not honour `addInterceptors` at all — those need explicit `accessService` calls. |
| **SBDEV-2732** | Its `sb_admin` gate becomes `WEB_UI_ACTION_CONFIGURE_PUTAWAY_DESTINATION` granted to `super-admin`. This is the natural pilot for the migration: smallest surface, and the one the BA actually asked for. |

### 13.5 Ordering, which fails in both directions

**This plan must land before any gate is moved off `sb_admin`.** Today only 1 of 80 functions is enforced anywhere, so swapping a working `@PreAuthorize` for a function reference before this ships leaves the control **fully open**. Conversely, adding a function gate before the Flyway seed reaches a tenant leaves it **inaccessible to everyone** — worse than today, where staff could at least act.

**Sequence: this plan → functions seeded and audited per tenant → then swap gates, in tranches.**

### 13.6 Two items still open with the BA

1. 🔴 **Break-glass.** After the migration nobody — including SiteBoss — can repair a tenant whose function data is wrong, except by direct SQL or a redeploy. Today `sb_admin` is that escape hatch. Cheapest mitigation is keeping one narrow `sb_admin`-gated repair endpoint; `ReplenishmentReconciliationController` is already shaped like one.
2. ~~**`importUsersFromCsvText`**~~ — **RESOLVED 2026-08-16.** A one-off Keycloak-migration utility, retained for reuse. **Deliberately NOT mapped to any function**, existing or new: it manufactures identities rather than performing a warehouse operation, so it sits outside the `FunctionEnum` model alongside `/actuator/**`. Excluded from the `sb_admin` migration in §13.4. Implemented on `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin` (PR #166).

    ⚠️ **Corrected 2026-08-17 (§14-Δ3): the gate is `@PreAuthorize(Authority.IS_SB_ADMIN)`, not `IS_WMS_ADMIN`.** `IS_WMS_ADMIN` was written, then **deleted as dead** in #166 — `Authority` now carries only the `WMS_ADMIN_ROLE` literal, whose sole consumer is `/actuator/**`. The endpoint moved to `sb_admin` because its caller is SiteBoss staff, and `Authority`'s javadoc explicitly forbids reintroducing `IS_WMS_ADMIN` speculatively. **This matters to §13.4:** the `sb_admin` migration's "everything moves to functions" target now has *two* documented exceptions (`/actuator/**` on `wms_admin`, CSV import on `sb_admin`), not one.

---

## 14. Re-scope 2026-08-17 — what SBDEV-2870 PR #166 changed under this plan

This plan was marked `reviewed` on 2026-08-16. On 2026-08-17 SBDEV-2870 was re-cut and pushed as
[wms2-api PR #166](https://github.com/SiteBossInc/wms2-api/pull/166) (`989611e`, based on `2be4ea5`), and part of
its scope was moved to SBDEV-2967. Four deltas land on this plan. **Δ1 is new scope; Δ2–Δ4 are corrections.**
The mechanism (§3.1), the 66-endpoint mobile surface (§0.A), the fail-closed design (A8) and the
guarded-set decision (§13) are **untouched** — this is a delta review, not a re-plan.

**Verification basis:** `git diff` of `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin` against its
merge-base with `origin/develop`, plus direct reads of `AdminController`, `UserAdministrationController`,
`SecurityConfiguration` and `Authority` on that branch. Every claim below is from the branch, not from either plan's prose.

### Δ1 — 🔴 The `X-Authz-Denied` premise inverted (NEW SCOPE → §3.1-A2b)

| | |
|---|---|
| **This plan said** | The header "is already emitted by SBDEV-2870's damaged-lock gate (`StockUnitController.denyUnlessDamagedLockAllowed`)"; the interceptor merely *adopts* it. Stated at §3.1-A2 step 6, §3.2-B5, §5.1-P10, R6b. |
| **What is true** | The damaged-lock gate, `Authority.AUTHZ_DENIED_HEADER` and the CORS entry were **reverted** from SBDEV-2870 and re-homed in **SBDEV-2967 Fix E** (2870 §11.4) — and **2967 lands after this plan** (§12). |
| **Evidence** | No `X-Authz-Denied` anywhere in `src/main/` on the 2870 branch. `SecurityConfiguration.corsConfigurationSource` (`:167-188`) exposes only `CyclecountService.EXPORT_SKIPPED_HEADER`, and that method is **byte-identical** to `origin/develop` — #166 does not touch it. `Authority` gains `WMS_ADMIN_ROLE` only. |
| **Why it inverted** | The revert argument was sound in isolation — nothing left in 2870 could *emit* the header, because its five gates are `@PreAuthorize` (Spring's default 403) and this codebase has **no `AccessDeniedHandler`**. What nobody re-checked was that the plan inheriting the header lands *first*. |
| **Resolution** | **§3.1-A2b**: this plan owns the constant, the emitter, the CORS exposure and the `SecurityConfigurationTest` extension. Correct owner on the merits — `FunctionGuardInterceptor` writes the denial response itself, so the header is a one-liner here and infrastructure anywhere else. New: AC-29, AC-31, M23, R13, P10 (re-scoped), checklist step 12. |
| **If unfixed** | P10's `retryCondition` fix is dead on arrival: no header to key on, and — even once emitted — unreadable cross-origin without the CORS entry. Every denial would still log the operator out. This is the **same defect 2870's own reviewer caught**, resurfacing one ticket downstream. |

### Δ2 — `AdminController` 13 → 9 mapped methods (correction)

#166 extracts `addUserToWarehouseGroup`, `removeUserFromWarehouseGroup`, `isWarehouseUser` and `existsInKeycloak`
into a new **standalone** `UserAdministrationController` (`@RestController @RequestMapping("/v3")`, package
`controller/`, **does not extend** `AdminController`, 4 endpoints, gated on `WEB_UI_VIEW_USER_MANAGEMENT` by a plain
`AccessService` call). So the inherited alias surface goes **~130 → ~90**.

Corrected at §0.C, §0.15, §0.16, §3.1-A2 step 2, the §4 diagram, §5.2 step 11, R4. **§5.1-P9 closes** — the finding
was reported and #166 acted on it.

**The design is unaffected, and that is the point:** declaring-class resolution is count-independent, and
`findUsers` **stayed** on `AdminController` (`:80`) — so both the `inheritedAdminControllerAliasIsNotGatedByTheSubclassAnnotation`
fixture and the §3.5 pre-deploy audit instrument survive the rebase with no change. Had `findUsers` moved, Δ2 would
have been a redesign rather than a renumber.

### Δ3 — `IS_WMS_ADMIN` deleted as dead (correction)

§13.6 said `importUsersFromCsvText` is gated on `@PreAuthorize(Authority.IS_WMS_ADMIN)`. That expression was written
and then **removed** in #166; the endpoint is on `IS_SB_ADMIN`, and `Authority`'s javadoc forbids reintroducing
`IS_WMS_ADMIN`. Corrected in place at §13.6. Consequence for §13.4: the `sb_admin` migration has **two** standing
exceptions, not one.

### Δ4 — ✅ RESOLVED 2026-08-17 — #166 merged first; base is now stable (was §5.1-P11)

> **Resolution, appended after the fact.** The user chose "merge #166 first." Executed the same day — see
> **§14.3** for what was run and what was re-verified afterwards. The paragraphs below are the statement of the
> problem as it stood before that decision, kept because the *reasoning* (why a reflective baseline must not be
> built on a moving base) still governs P4 and A8.

`git merge-base --is-ancestor 989611e origin/develop` → **false**. `origin/develop` head is `2be4ea5`; this ticket's
worktree (`.claude/worktrees/wms2-api/SBDEV-2968`, branch `bugfix/SBDEV-2968-mobile-function-gating`) is based on it
and holds one uncommitted file, `src/test/java/net/aim_ai/wms/unit/security/FunctionGuardContractUnitTest.java`.

So **Δ2's counts describe a base that does not exist yet.** Either #166 merges first and this plan rebases onto it,
or this plan lands first and #166 rebases. Decide before building anything reflective — the golden map (P4), the
`SmartInitializingSingleton` startup assertion (A8) and the verify script's endpoint rows are all derived from the
deployed handler surface, and a new controller appearing underneath them invalidates all three at once.
**Recommended: let #166 merge first** — it is the smaller, already-reviewed change, and this plan then builds its map
once against a stable surface instead of twice.

### 14.1 What this costs, and the pattern worth naming

Nothing here required rework of code, because no implementation code exists yet — the TDD gate had produced exactly
one uncommitted test file when the deltas landed. That is the cheapest possible moment to catch it, and it was caught
only because the ordering question was asked out loud.

**The pattern (R13):** SBDEV-2870, 2967 and 2968 have now exchanged scope twice, and **both times the move left an
orphan.** The first cost 2870 its §10.1 blocker (the gates emit 403s with no way to soften them). The second is Δ1.
A relocation between plans moves the *work* atomically but leaves each plan's *prose about the other* behind — and
prose that says "already done elsewhere" is indistinguishable from prose that says "done", right up until someone
greps the branch. **Any future scope move between these three tickets must end with a grep of the receiving branch for
the thing being assumed, not a reading of the sending plan.**

### 14.2 Verify-script delta, and a defect the re-run found in the correction itself

`verify-SBDEV-2968-…sh` grew from **76 to 91 rows**: `A24`–`A31` (the A2b contract) and `H21`–`H27` (its test
surface). Re-negative-tested against the SBDEV-2968 worktree pre-implementation, via a symlink shadow root:

**`16 pass, 87 fail, 5 skip`** (previously `12 pass, 76 fail, 5 skip`).

Six of the eight new A-rows are correctly red. The four that pass on the unfixed tree — `A29`, `A31`, `H24`,
`H26` — are regression pins on the SBDEV-2632 CORS shape this cluster must reuse, and each is labelled
**`[pre-passes]`** in the row description so a green one is never mistaken for progress.

> ⚠️ **Writing the rows found a defect in the source this re-scope was based on.** The first draft of `H24`
> asserted *"the exposed-list assertion is not loosened to `contains(`"*, taken directly from 2870 §3.5.1
> property 5 ("`SecurityConfigurationTest` asserts the exposed-header list **exactly**"). Running it against
> `develop` returned a **red row on unmodified code** — because the file has **two** SBDEV-2632 cases and the
> exposure one legitimately uses `.contains(…)` (`:64`); only the de-duplication one is exact (`:83`). A row
> that is permanently red on correct code is indistinguishable from unimplemented work
> (`verify-script-undefined-check-fn-reads-as-honest-fail`), and acting on the unqualified claim would have
> meant "fixing" the wrong assertion. `H24`/`H25` now target `containsExactly` on the dedup case, and A2b item
> 3 names both cases explicitly. **The general lesson matches R13: a claim inherited from a sibling plan is
> not evidence — run it against the branch.**

**Not scriptable, and named so it is not forgotten:** no row here proves the browser can *read* the header.
That is **M23** — and M23 is a **local browser test**, not a `curl`. See §14.4 for why the two `curl` drafts
that preceded it were both inadmissible.

### 14.3 Base resolution — what was actually run (2026-08-17)

**Decision:** merge SBDEV-2870 PR #166 first, then bring this ticket onto it. Chosen because #166 was the
smaller, already-reviewed change, and because building the golden map (P4) and the startup assertion (A8)
against a base that was about to move would have meant building them twice.

| Step | Command | Result |
|---|---|---|
| Pre-merge state | `gh pr view 166` | `OPEN`, `MERGEABLE`, `mergeStateStatus: CLEAN`, base `develop`, **no CI checks configured** (`statusCheckRollup: []`) and **no recorded review decision** |
| Merge | `gh pr merge 166 --merge` | merge commit **`27e2f21`**, `mergedAt 2026-08-17T20:43:43Z`. Merge-commit style chosen to match this repo's history (`#157`–`#164` are all merge commits) |
| Confirm | `git merge-base --is-ancestor 989611e origin/develop` | **true** — no orphan (`stacked-v2-pr-merge-order-orphan-trap`) |
| Bring this branch on | `git merge --ff-only origin/develop` | **fast-forward**, 8 commits, 20 files. `bugfix/SBDEV-2968-mobile-function-gating` had **no commits of its own**, so nothing was replayed and no conflict was possible — this was never a rebase in substance |
| Untracked work | — | `src/test/java/net/aim_ai/wms/unit/security/FunctionGuardContractUnitTest.java` (the sole TDD-gate artifact) survived untouched |

**Integration risk was nil, and that is checkable rather than asserted:** #166 was based on `2be4ea5`, which
*was* `origin/develop`'s head at merge time — so the merge introduced no interleaved commits and no semantic
conflict surface. No build was run on the merge for that reason; #166's own suite (5122 run, 2 failures, both
pre-existing on `develop`) is the last word on it.

**Re-verified on the merged base, replacing three assumptions with observations:**

| Claim | Was | Now |
|---|---|---|
| `AdminController` mapped methods | assumed 9 post-merge (§14-Δ2) | **9, counted on `27e2f21`** |
| `UserAdministrationController` | "arrives with #166" | **present on `develop`** (§0.26) |
| Flyway head | V2.2.16, local checkout 36 commits stale | **V2.2.16 on a current worktree**; V2.2.17 free. #166 carried no migration. P6's all-remote sweep still owed at PR time |
| Verify baseline | `16 pass, 87 fail, 5 skip` (pre-merge base) | **`16 pass, 87 fail, 5 skip` — identical.** Expected: #166 touches no file this script asserts on except `SecurityConfiguration`, and only its `/actuator/**` literal. A shifted total here would have meant a row was coupled to something it had no business reading |

**P11 closes. §5.1's other blocking prerequisites do not** — P1–P8 stand, including the per-tenant
Keycloak-joined audit and the mobile-first deploy order.

> ⚠️ **What this did NOT do.** Resolving the base is not a review. **§3.1-A2b is still new design that no
> second party has looked at** — specifically: whether this plan is the right owner of the header contract at
> all (a standalone prerequisite PR consumed by both 2967 and 2968 would decouple the ordering instead of
> resolving it by assignment), whether extending the `containsExactly` list preserves the SBDEV-2632 dedup
> test's intent, and whether R13's mitigation — prose in three documents — is strong enough given that the
> same control has now failed twice. The TDD gate is unblocked *on the base*; that review is still owed.

### 14.4 M23 rewritten — why the `curl` evidence was inadmissible (2026-08-17)

**M23 was drafted twice as a cross-origin `curl`, and both drafts were wrong.** The row now specifies a local
browser test. The reasoning is recorded here because it is not obvious, it was not caught by writing the row,
and the next person to review §3.1-A2b will otherwise re-derive it.

**The defect P10 guards against is "the header is emitted but the browser cannot read it."** Any check that is
not itself subject to CORS filtering cannot distinguish that state from success:

| Instrument | Sees `X-Authz-Denied` when it is **not** exposed? | Admissible? |
|---|---|---|
| `SecurityConfigurationTest` (`MockMvc`, no `CorsFilter`) | yes — reads the bean's config, not a filtered response | proves the *list*, not the *reading* |
| `curl -H 'Origin: …' -i` | **yes** — curl is not a browser and applies no CORS policy | **no** |
| DevTools → Network → Response Headers | **yes** — the panel renders all headers; CORS restricts what *JS* may read | **no** |
| JS `response.headers.get('x-authz-denied')` in the app's origin | **no** — returns `null` when unexposed | **yes** |
| The behaviour itself (denial message shown, no logout) | **no** | **yes, and strongest** |

So M23 asserts the behaviour plus an explicit `headers.get()` probe.

⚠️ **Narrowed by review ③ (2026-08-19) — "curl is inadmissible" is true of one curl check, not of curl.**
The table's row 2 condemns `curl -i | grep X-Authz-Denied`, which is the check that was actually drafted twice
and which does pass on the broken configuration. It does **not** condemn
`curl -i | grep -i 'access-control-expose-headers:.*X-Authz-Denied'`: the expose list is itself on the wire,
curl reads it fine, and that assertion detects the CORS-layer defect with no browser and no test account.
Correct statement: **a curl check on the header's *presence* is inadmissible; on the *expose list* it is
admissible but insufficient.** M23 still needs a browser, because arm (b) — denial renders, no logout, no
max-unauthorized toast — is behavioural and nothing but the app produces it.

**Every curl-shaped row must also assert the status line.** A bare header grep returns *identical empty
output* whether the header is missing (the defect) or the request never reached the filter chain. Measured
2026-08-19: `/v3//system/mobileUiUrl` — one extra slash — is rejected by Tomcat at **400 before `CorsFilter`
runs** and carries no CORS headers at all. Silent and indistinguishable from a real failure, and the same
class of defect as the `H24` error in §14.5: a row red on correct code.

**Verified rather than reasoned (2026-08-19).** A two-origin probe — 403 + `X-Authz-Denied`, one route
listing it in `Access-Control-Expose-Headers` and one omitting it — returned `headers.get('x-authz-denied')`
= `null` when unexposed and `"true"` when exposed, on otherwise byte-identical responses, while `curl -i`
showed the header in **both**. Rows 2 and 4 of the table above are now measurements. CORS filtering applies to
error responses, so the 403 case behaves like a 200.

### 14.4a The credential-free variant, re-examined — why "override-proof" needs the word *silent* (2026-08-19)

Review ④ initially judged the drop **wrong**, on an objection worth recording because the plan's wording
invites it: `addExposedHeader` is override-proof for the **expose list**, but a browser only receives
`Access-Control-Expose-Headers` when the **Origin is allowed**, and
`rest.security.cors.allowed-origin-patterns` (`application.properties:98`) binds through
`@ConfigurationProperties(prefix = "rest.security")` (`SecurityProperties.java:11`) — so it *is* overridable
per environment as `REST_SECURITY_CORS_ALLOWED_ORIGIN_PATTERNS`. That reads exactly like the env-specific
drift the plan says cannot exist.

**Checking the deployed configuration retired the objection:**

| Probe | Result |
|---|---|
| Every `allowed-origin` declaration in the repo | Two — `application.properties:98` and `allowed-origins=*` in test resources. **No override anywhere** |
| Profile-specific property files | **None exist.** `SPRING_PROFILES_ACTIVE=wineco` (`Dockerfile:45`) is commented out |
| Config externalization | `ENTRYPOINT` is a bare `-jar app.jar` — no `--spring.config.location`, no config volume, no env injection in `Dockerfile`, `.gitlab-ci.yml` or `.github/workflows/` |
| `REST_SECURITY_*` anywhere | Only in two source comments |
| Reach of the baked default | Spring compiles `*` in an origin pattern to `.*`, so `https://*.sbo.li` matches multi-level hosts such as `https://wms.wineco.dev.sbo.li`. Broad enough that no environment needs to touch it |

**And the decisive point: a wrong origin pattern is loud, not silent.** It breaks *every* cross-origin
request — the UI is comprehensively down within seconds of a deploy. Expose-list omission is the opposite:
one header silently unreadable while everything else works. Only the silent class needs a dedicated smoke
row, so the credential-free check has no silent failure mode to catch and dropping it costs nothing even
under §14.6's account scarcity. **The conclusion stands; only the wording needed the qualifier.**

*Residual:* deployment is Kubernetes and the manifests are outside this repo, so absence of an override is
inferred from the image having no mechanism to receive one, not observed in a Deployment spec. If one does set
the variable the finding is unaffected — the failure would still be loud.

**A credential-free variant was considered and dropped, not deferred.** Spring Security's `CorsFilter` runs
before authentication, so an *unauthenticated* cross-origin request still carries
`Access-Control-Expose-Headers` on its 401 — which appeared to offer a CORS check needing no test account.
It buys nothing: §3.1-A2b's `addExposedHeader` is **additive and override-proof by construction**, so no
environment's `REST_SECURITY_CORS_EXPOSED_HEADERS` can drop the header, and there is no ***silent***
env-specific drift for such a check to catch. It would have been a row incapable of failing. Recorded so it is
not re-proposed — and see **§14.4a**, where a review took the un-qualified wording at face value, reached the
opposite verdict, and had to check the deployed configuration to retire it.

**Local dev is a valid CORS test bed — verified, not assumed.** `nuxt.config.js` declares
`modules: ['@nuxtjs/axios', '@nuxtjs/toast']` with **no `@nuxtjs/proxy`**, and `axios.baseURL` is
`http://localhost:8088/v3` while the app is served on `:3001`. Different port ⇒ different origin ⇒ CORS
applies in full. **This is the load-bearing fact that lets M23 run without a deployed environment**, and it is
fragile: adding a Nuxt dev proxy would make every request same-origin and render this entire defect class
invisible locally while every test stayed green. Re-check `modules` before trusting a local M23 result.

**Consequence for the ticket:** P10's whole evidence chain now runs on a developer machine. The only
non-automatable input is **a Keycloak account that authenticates but holds no mobile workflow function** (the
`CS-REP` shape, §3.5) — which must be identified before the TDD gate finishes, not at PR time.

### 14.5 Review status — and two defects found by auditing my own rows

**The independent review did not happen.** Two subagent reviewers (design/scope, verify-rows) were dispatched
2026-08-17 and **both returned idle with no report**, twice, including after a direct request for a written
verdict. Nothing was accepted from them. Per `idle-review-subagent-is-not-a-passing-review`, idle-with-no-report
is indistinguishable from "found nothing", so this is recorded as **no review**, not as a clean one.

What was done instead is a **mechanical self-audit** — the checks whose outcome does not depend on the opinion
of whoever wrote the rows (does the path exist, does the helper resolve, does the row pass on unfixed code, is
every requirement covered). It found two real defects:

| # | Defect | Fix |
|---|---|---|
| 1 | **`A31` passed on the unfixed tree while UNLABELLED.** The `[pre-passes]` convention was applied to `A29` but the shared comment covering both rows was mistaken for covering both descriptions. A green unlabelled row reads as progress; that is the precise misreading the convention exists to prevent, reintroduced in the same commit that introduced the convention. | label added; all four pre-passing rows (`A29`, `A31`, `H24`, `H26`) now carry it |
| 2 | 🔴 **P10's client half had NO row at all.** `H27` asserted only that a *spec file* mentions the header; **nothing asserted `plugins/axios.js` itself**. Neither the pre-existing G section nor the A2b additions covered it — so the script could have reported `0 fail` while every authorization denial still logged the operator out, which is the entire defect P10 exists to close. | new **`H28`** asserts `plugins/axios.js` references the header. Deliberately not a proximity grep tying it to `retryCondition` — that shape asserts "same block" and goes stale under a refactor; the behavioural proof is M23 |

Script is now **92 rows**, re-negative-tested: **`16 pass, 88 fail, 5 skip`** (H28 correctly red).

> ⚠️ **What remains genuinely unreviewed, and a self-audit cannot substitute.** The mechanical pass says nothing
> about the *judgment* in §3.1-A2b: whether this plan should own the header contract at all rather than a
> standalone prerequisite PR consumed by both 2967 and 2968; whether extending the `containsExactly` list
> preserves the SBDEV-2632 test's intent; whether §14.4's instrument argument is sound; whether dropping the
> credential-free check was right; and whether R13's prose mitigation is adequate. **Those were written by one
> author and checked by no one.** The two defects above were found precisely because they were mechanically
> checkable — which is a reason to distrust, not trust, the parts that were not.

**Premises re-verified, since a false premise sinks the judgment regardless of who reviews it.** The
ownership-follows-emitter argument in §3.1-A2b rests on one load-bearing claim about the codebase, and it holds
— **more strongly than it was stated**: `grep -rn "AccessDeniedHandler\|accessDeniedHandler\|exceptionHandling("
src/main/java/` on `27e2f21` returns **nothing at all**. There is not merely no custom `AccessDeniedHandler`;
there is **no `exceptionHandling(...)` configuration in the security chain whatsoever**. So SBDEV-2870's five
`@PreAuthorize` gates have no hook of any kind for attaching a header to a denial — emitting `X-Authz-Denied`
there would have meant introducing that machinery from scratch, not adding a line. *The premise is confirmed;
whether the conclusion drawn from it is the right call remains unreviewed.*

### 14.6 M23 has no test subject — measured, 2026-08-18

**No account on either reachable tenant can run M23.** The `CS-REP` shape assumed by §3.5 is real at the
**role** level and absent at the **user** level. SELECT-only, via the 5-table `getAllRoles` chain
(`UserRepository.java:26-34`):

**WineCo dev (`dev_wh01_om1`)** — role-level, `CS-REP` is exactly as described: **28 functions,
`MOBILE_UI_LOG_IN` yes, `MOBILE_UI_VIEW_*` zero, 3 live holders.** But every live holder also carries
`super-admin`:

| User | Roles | `MOBILE_UI_VIEW_*` held |
|---|---|---|
| `Z-mariaortiz(archived)` | CS-REP **only** | **0** ← the only true shape, and archived |
| `vmedellin` | CS-REP + super-admin + 4 others | 10 |
| `dwessel` | CS-REP + super-admin + outbound-worker + 5 | 16 |
| `lukamiranda` | CS-REP + super-admin + outbound-worker + 5 | 16 |

**Hydra UAT** — the same query over live users returns **zero rows**: every non-archived user holds at least one
`MOBILE_UI_VIEW_*` function.

**Consequence 1 — M23 needs a purpose-made account.** Create one (Keycloak user + `mywms_user` row + a group
whose only role is `CS-REP`, or any role with `MOBILE_UI_LOG_IN` and no `MOBILE_UI_VIEW_*`). Do **not**
substitute a user with no `mywms_user` row: that path denies with `reason=USER_NOT_PROVISIONED` at `ERROR`
severity and a different message, so it exercises the wrong branch (§3.1-A2 step 5).

**Consequence 2 — 🔴 this undermines §5.1-P1/P2's pre-deploy audit, which is the more serious finding.** The
audit asks "who loses access when enforcement turns on?" **On WineCo dev the answer is nobody** — every CS-REP
holder is also `super-admin`, so the query returns an empty impact set. That is a **false all-clear produced by
the dev data**, not evidence of a safe rollout. P2 currently reads "result set 4 must be empty on prd"; an
empty result must be shown to mean *no affected users* rather than *the roles that would be affected have no
exclusive holders here*. **P1/P2 must be re-run per tenant on prd/UAT and must distinguish those two cases.**
Hydra UAT returning zero rows is genuinely reassuring (nobody would be locked out); WineCo dev returning zero
is an artifact. Same number, opposite meaning.

---

### 14.7 R13's mitigation replaced — the `[inherited]` verify-row class (2026-08-19)

**Source:** review of §3.1-A2b, `reviews/SBDEV-2968-review-a2b-header-contract.md`, decision ⑤. That review
judged R13's mitigation — prose in three documents — inadequate, on the grounds that prose is the same class of
control that had already failed twice. This section replaces it.

**The defect is broader than R13 states.** R13 is scoped to *scope moves between 2870/2967/2968*. There are now
three instances, and the third involves no scope move at all:

| # | Inherited claim | Carried as | Reality | Found by |
|---|---|---|---|---|
| 1 | "2967 Fix E will carry the header" | 2870 §11.4 | 2967 lands *after* 2968 | reviewing 2870 |
| 2 | "the header is already emitted by SBDEV-2870's damaged-lock gate" | this plan, pre-§3.1-A2b | **No `X-Authz-Denied` anywhere in `src/main/`** on `27e2f21` | a `grep`, 2026-08-17 |
| 3 | "a `CS-REP`-shaped account exists" | §3.5, from plan prose | True of a **role**, false of any live **user** (§14.6) | a SELECT, 2026-08-18 |

The general defect is **any inherited claim carried as fact** — not specifically a relocation. "Grep the
receiving branch after a scope move" would not have caught instance 3, because nothing moved.

**All three were caught by running something.** None was caught by reading. That is what selects the medium.

#### The control

> **`[inherited]` — every claim a plan makes about state it does not itself create must appear as a verify-script
> row that re-executes the check on the receiving branch.**

Three properties make this the right shape:

1. **It is executable, not prose.** The failure mode being mitigated is "nobody re-read the sentence." A row is
   re-run on every verify invocation whether or not anyone remembers it exists.
2. **It runs on the receiving branch.** That is exactly R13's own instruction — *"a grep of the receiving branch
   for the thing being assumed, not a reading of the sending plan"* — automated instead of asked for.
3. **It generalises past relocation** to the whole inherited-claim class, which is what instance 3 requires.

#### Label semantics, alongside `[pre-passes]`

| Label | Meaning | Reading a green row |
|---|---|---|
| `[pre-passes]` | Regression pin on pre-existing shape; passes on the unfixed tree by design | **Not progress** (script :120-122) |
| `[inherited]` | A precondition this plan assumes but does not build | **Not this plan's work** — green means the assumption still holds; red means the assumption is an orphan |

Both labels answer the same question — *what does a green row here actually prove?* — which is why they belong
in the same convention.

#### Rows this ticket adds

| Row | Assertion | Expected on `27e2f21` |
|---|---|---|
| `X1` | `[inherited]` — nothing outside this plan is assumed to emit `X-Authz-Denied` | n/a: §3.1-A2b now **owns** it, so instance 2 is closed by ownership rather than by a row. Recorded here so the closure is deliberate |
| `X2` | `[inherited]` — a mobile account holding `MOBILE_UI_LOG_IN` and **zero** `MOBILE_UI_VIEW_*` exists on the target tenant | **RED** until §14.6's purpose-made account is created. M23 cannot run before this is green |
| `X3` | `[inherited]` — `Authority.AUTHZ_DENIED_HEADER` resolves on the branch under test | For **SBDEV-2967's** row set, not this one — see below |

`X2` is the row that would have found §14.6 on the day §3.5 was written rather than the day the account was
needed. It is the whole proposal in one line.

#### Compile-time reinforcement (from decision ①)

SBDEV-2967's Fix E must reference `Authority.AUTHZ_DENIED_HEADER` **by symbol, never a string literal** — row
`A27` already enforces this on the interceptor side (script :118). An orphaned constant then breaks 2967's
build instead of silently logging operators out, which is the loudest available signal and costs nothing.
`X3` is the verify-script backstop for the case where 2967 is read before it is compiled.

#### What this does not cover

A claim nobody thought to write down is still invisible; the control catches *stated* assumptions, not
unstated ones. And a row asserting the wrong thing is worse than no row — see §14.2 and §14.5, where two rows
in this very script were red on correct code. `[inherited]` rows are subject to the same discipline as the
rest: assert the status line as well as the payload, and confirm the row is red before the precondition is met.

#### Two housekeeping notes from the same review

- **`R13` ID collision — fixed 2026-08-19.** The ID was used twice in §8's register: the header-contract risk
  and an unrelated `IS_SB_ADMIN` observability risk. Every cross-reference — §14.2, §14.4, §14.5, §14.7,
  SBDEV-2870 `:516`, SBDEV-2967 `:393` — means the header contract, so **the observability row was renumbered
  to `R14`** (previously unused) and `R13` was left untouched. No reference needed updating.
- The review's other verdicts (①–④, all *sound* or *sound-with-changes*) are recorded in the review file and
  are not repeated here. Two carry edits to this plan's own artifacts: `containsExactlyInAnyOrder` in place of
  `containsExactly` for the two-header assertion, with row `H24` widened to match; and M23's rationale narrowed
  to *"a curl check on the header's presence is inadmissible; on the expose list it is admissible but
  insufficient."*
