---
title: "WMSv2: mobile workflow tiles are gated client-side only — nothing re-enforces the function server-side"
ticket: "SBDEV-2968"
ticket_url: "https://app.clickup.com/t/868krr3rw"
type: "bugfix"
priority: "normal"
status: "✅ MERGED TO DEVELOP 2026-08-21. [wms2-api #178](https://github.com/SiteBossInc/wms2-api/pull/178) → merge commit `5506117b60`, and [wms2-mobile-ui #42](https://github.com/SiteBossInc/wms2-mobile-ui/pull/42) → `4d768cfa29`. Both branch heads (`bba025c`, `03113ad`) confirmed **ancestors of `origin/develop`** by `merge-base --is-ancestor` — the orphan check, not just the PR page. `V2.2.18` is on develop. ⚠️ **Neither repo has CI checks configured and no human reviewed either PR** — the four review lanes were agent-run; local verification was the only gate. **At merge:** `wms2-api` 5314 tests / 2 failures = known baseline; `wms2-mobile-ui` 218 passing / 18 suites; verify 132/0/2; key pins re-mutated post-rebase, all killed with a null mutant surviving; P6 re-swept (`V2.2.18` uncontested). ⚠️ **DEPLOY ORDER, still live: apply `V2.2.18` → deploy mobile → deploy API.** Runtime Flyway applies migrations on **API boot**, so on UAT/prd step 1 needs a manual run or Replenish Request is dead for everyone between steps 2 and 3 (15 of 19 Hydra UAT users, measured). DEV auto-deploys from develop, so it takes the migration and the gate together — acceptable there, since dev is almost all super-admins. **Owed before ARCHIVE:** manual handheld QA (whether the denial toast paints — its precondition is proven from a real browser, the paint is not) and the 35-endpoint breadth re-measurement, which needs an under-privileged subject and is cheapest now that DEV carries the code. **Ceiling unchanged:** gates are self-grantable via ungated SDR; `/v3/section*` and `/v3/dashboard/*` stay ungated (reads); and a nonce can substitute for a function on `transferStock` via `IdempotencyFilter` (Medium, SBDEV-3017). Full history: §14.3-§14.27."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-16
updated: 2026-08-21
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
**Status:** ✅ **MERGED TO DEVELOP (2026-08-21)** — api `5506117b60`, mobile `4d768cfa29`. Prior: **PR SUBMITTED** — [wms2-api #178](https://github.com/SiteBossInc/wms2-api/pull/178) · [wms2-mobile-ui #42](https://github.com/SiteBossInc/wms2-mobile-ui/pull/42). Prior: **IMPLEMENTED AND COMMITTED** — verify `129/0/2` on the shadow root, both suites at their known baselines, review round 1 done (§14.19) and its fixes 1-4 committed and mutation-verified (§14.20). **No PR in either repo.** What blocks one: three owner decisions (P7 deploy order · the M1/M9 interceptor seam · R12's grading) and a re-review of the current diff, since fixes 1 and 2 changed it materially. ⚠️ **The plan's core design remains one-author** — only §3.1-A2b had an independent pass ([review](reviews/SBDEV-2968-review-a2b-header-contract.md), 2026-08-19), whose own "Not examined" list covers the mechanism, the endpoint surface, the fail-closed design and the pre-existing verify rows; the *implementation* has now been reviewed (§14.19), the plan has not. **Calibration for whoever gates this:** in one day of scrutiny the unreviewed core yielded a false §3.1-A9 verdict, a §0.B that was 5 endpoints instead of 17+, a fourth wrong endpoint count, an unowned R15, a falsified 🔴 R6b, and a mis-targeted row in the sibling plan; the review then found that the entire gate could be switched off with 100 unit tests and 119 verify rows staying green. The mechanism *design* survived a Critic pass and that scrutiny — the defects were in **enumeration, wiring coverage and risk bookkeeping**. Hence §5.1-P4 is the load-bearing control: **build the golden map from reflection before any test asserts the surface**, or a wrong enumeration becomes a green test.
**Base:** ✅ **both worktrees committed and current (verified 2026-08-21 by fetch).** `.claude/worktrees/{wms2-api,wms2-mobile-ui}/SBDEV-2968`, both on branch `bugfix/SBDEV-2968-mobile-function-gating`: `wms2-api` **4 commits @ `fa28026`** (`efe0c6e` implementation → `0723f8c` P4 pin → `dde7953` wiring pins → `fa28026` audit + seed), `wms2-mobile-ui` **2 commits @ `1dfdb30`** (`ab20df7` guard + denial rendering → `1dfdb30` cold-start fix). **Both trees clean, both 0 commits behind `origin/develop`, 0 uncommitted paths.** ⚠️ Do not read this state out of prose — run `sbdocs/9-System/scripts/plan-state.sh SBDEV-2968`; this field claimed "0 commits on either branch" for a day after the work was committed. Historical note retained because it is a real landmine: the golden map and the A8 startup assertion were built against a base that had already fast-forwarded past the one the plan was reviewed on — `StartupFlywayMigrator`, `FlywaySchemaMetrics` and `PutawayDestinationResolver` all landed underneath, so the reflected handler surface is **not** the reviewed one (§14.3, §14.16).
**Verify baseline (measured 2026-08-20 22:18 EDT, Linux, shadow root):** **129 pass, 0 fail, 2 skip** — up from 119/0/2 pre-review-fix; the +10 are §14.20's wiring pins (`A20` tightened plus `A20a`-`A20d`) and the audit/seed rows. The mono root reads **19/105/7** and that is the *wiring control*, not a regression: it confirms the work exists only in the worktree. The 2 skips and the two rows labelled `[pre-passes]` / `[pre-passes: vacuous until T1 is green]` (`S2`, `T2`) are documented as such by design. ⚠️ **Two standing caveats on any green here.** `X2` grades a *file*, so it cannot distinguish a real account from a written claim — re-run the `getAllRoles` SELECT against the tenant whenever it is cited (§14.9). And a green verify run is not evidence the rows would notice a defect: `WebConfig.java:35` was asserted by nothing while 119 rows and 100 unit tests stayed green (§14.19), which is why every fix in §14.20 was mutation-verified. Earlier readings and what each one checked are in §14.2, §14.8 and §14.15.

> **Companion to [SBDEV-2967](SBDEV-2967-web-ui-function-gating-enforcement.md).** This plan builds the
> enforcement mechanism (`@RequiresFunction` + `FunctionGuardInterceptor`); 2967 consumes it. **This plan
> lands first.**
>
> ⚠️ **Read [§14](#14-re-scope-2026-08-17--what-sbdev-2870-pr-166-changed-under-this-plan) before the TDD
> gate.** SBDEV-2870 PR #166 moved the `X-Authz-Denied` emitter *out* of the branch this plan assumed it
> would inherit from, and reshaped `AdminController`. One item is new scope (§3.1-A2b), the rest are
> count/line corrections.
>
> ✅ **§3.1-A2b's review is no longer owed — it landed 2026-08-19.** See
> [reviews/SBDEV-2968-review-a2b-header-contract.md](reviews/SBDEV-2968-review-a2b-header-contract.md) and its
> disposition table; §14.5's "zero reviewer" statement is **superseded**, and §14.4a / §14.7 are its output.
>
> ✅ **The M23 subject blocker is CLOSED (2026-08-19, §14.9).** No purpose-made account is needed — `sbtest`
> (`mywms_user` id 19800000, group `test group` → role `test role`) becomes a literal §14.6 subject with **one
> `INSERT`** adding `MOBILE_UI_LOG_IN`. `X2` flips green once the evidence file is written. **Phase A of §14.9 is
> runnable today, before any implementation**, and captures the pre-fix bypass baseline.
>
> ⚠️⚠️ **Two defects in M23 itself were found while resolving it (§14.10), and one is a potential false green.**
> "Tap a gated tile" is unrunnable for *any* valid subject — `affiliated` is keyed on tile count, so a
> zero-view-function user gets `<not-affiliated />`, never a home screen; **deep-link instead.** And the
> prescribed raw-`fetch` probe cannot exercise `plugins/axios.js` at all, so it is structurally incapable of
> testing assertion (b) — now split into two probes. Worse, **(b) may pass on unfixed code**: `updateToken(5)`
> returns `false` on a valid token, so `retryCondition` gives up without retrying and the logout never fires.
> **R6b and P10 are therefore marked CHALLENGED, not corrected** — §14.9 Phase A step 7 settles it with one
> console call, and until it runs a green (b) must not be banked as evidence.
>
> ✅ **Cleared 2026-08-19:** both worktrees are current (see **Base** above); the baseline is re-measured at
> **16/89/7**; the bash-3.2 hazard is now a **hard `exit 2` gate** at the top of the verify script instead of a
> silent partial run; and **P5 and P6 are answered — the migration moves to `V2.2.18` (17 was lost to a sibling
> branch) and `NOT EXISTS` is confirmed as the only safe idempotency guard.** See **§14.8**.
> **§5.1-P1–P4, P6–P8 and P10 remain open.**

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

> ⚠️ **"Count resolved" is withdrawn as of 2026-08-20 — a fourth independent attempt returned 67, not 66 (§14.11.a).** The GET half is now **execution-verified**: 35 GET paths were probed and all 35 returned a mapped handler, zero no-handler 404s. With 32 mutating mappings that totals **67**, and the disagreement localises to the mutating half or to `PickingController` — the very controller this paragraph blames for the earlier 67. Four attempts have now produced **77, 67, 66, 67**. Treat the number below as commentary and **build the golden map from reflection (§5.1-P4)**; that row is load-bearing, not procedural.
>
> **Original text — count "resolved" (three different figures were in circulation).** The authoritative count is **66 method-level mappings**, obtained by counting every `@(Get\|Post\|Put\|Delete\|Patch\|Request)Mapping` per file and subtracting the one class-level `@RequestMapping` each. It is corroborated independently by the per-tile endpoint tables in the surface enumeration. An earlier figure of 77 counted the 11 class-level prefixes; an earlier figure of 67 was off by one on `PickingController`. **The golden map must still be built from reflection, not from this number** (§5.1-P4) — the number is documentation, the reflection is the contract.

### 0.B Explicitly EXCLUDED — shared endpoints (do **not** gate)

> ⚠️ **INCOMPLETE — corrected 2026-08-20 by P3's re-derivation (§14.12).** This table lists **five**; the mobile
> UI actually calls **seventeen or more** endpoints outside the guarded set (§14.12.c — sixteen were tabulated, then `isUnitLoadIdValid` was found to have been lost by both extractors). All five below are confirmed still live, but
> eleven were never enumerated, and 🔴 **five of the sixteen are Spring Data REST `/search/…` queries that the
> annotation-driven design cannot gate at all** (§14.12.a, **R16**) — including one that is *mobile-only* and used
> inside the gated Replenish workflow. The full sixteen are tabulated in §14.12; **R12's residual is corrected
> accordingly.** The design conclusion below still holds — everything outside `controller/mobile/` is excluded by
> construction — but "by construction" is doing more work than this section admitted: it also silently excludes
> capabilities that *should* have been gated.

Gating any of these 403s a web-UI screen. All five are declared **outside** `controller/mobile/`, so the annotation-driven design excludes them by construction. Recorded so the exclusion reads as a decision, not an oversight; pinned by `FunctionGuardArchTest#noSharedControllerCarriesRequiresFunction`.

| Endpoint | Controller | Mobile caller | Web-UI caller | Breakage if gated |
|---|---|---|---|---|
| `POST /v3/stockUnit/transferStock` | `StockUnitController` | `store/moveStock.js:169` | `store/handlingUnits/stockUnits.js:161` | Handling Units → Stock Units transfer |
| `GET /v3/stockUnit/storageLocationsForStockMovement` | `StockUnitController` | `store/moveStock.js:157` | `store/handlingUnits/stockUnits.js:199` | its destination dropdown |
| `GET /v3/dashboard/orderMonitorViewSummary` | `DashboardController` | `store/picking.js:244` | `store/dashboard/pickpackMonitor.js:85` | Pick & Pack Monitor |
| `GET /v3/dashboard/replenishMonitorViewSummary` | `DashboardController` | `pages/replenish.vue:133,153` | `store/dashboard/replenishMonitor.js:33` | Replenish Monitor |
| `GET /v3/replenishOrder/detailView` | `ReplenishOrderController` | `pages/replenish.vue:146` | `store/internalOps/replenishments.js:155,357` | Internal Ops → Replenishments |

**Partially shared** — same Spring Data REST repository, different sub-paths (`SectionRepository`, `StockunitRepository`, `ClientRepository`, `FixLocationAssignmentRepository`, all under `/v3`). Safe per path, but a *repository-level* gate would break the web UI. None is added; `#noRepositoryCarriesRequiresFunction` prevents one being added later by reflex.

**Consequence, stated plainly — ⚠️ REVISED 2026-08-21, the original text below is now false.** After this change a user denied `MOBILE_UI_VIEW_STOCK_TRANSFER` cannot use the Move Stock *page*, and **can no longer call `POST /v3/stockUnit/transferStock` directly either**: the re-review found that endpoint reachable by ordinary navigation on a slow Keycloak init (not merely by deliberate replay) and gated it with a reviewed method-level annotation, which the interceptor honours because it resolves method annotations *before* consulting `GUARDED` (§14.22 H2). Its ~40 sibling endpoints on that shared controller stay ungated, so no web screen changes. **One replay path remains**: SBDEV-3003 Slice 2 enrolled this exact URI into `IdempotencyFilter`, which serves a cached 2xx without invoking the handler on a key that carries no principal — so a nonce, not a function, gates that request (§14.24, owned by SBDEV-3017). Superseded text: *the tile is enforced; the underlying shared capability is not*. That is the correct scope boundary (narrowing it needs a per-caller distinction the shared controllers do not support), and it must appear in the ticket's closing note so nobody reads this as "mobile is now locked down." Tracked as R12.

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
| 0.21 | `src/main/resources/db/migration/` | next free = **V2.2.18** — ⚠️ **CHANGED 2026-08-19 from V2.2.17, which is now TAKEN.** `origin/develop` head is still V2.2.16, but the all-remote sweep found `V2.2.17__seed_transfer_destination_eligibility_sysprop.sql` on `origin/feature/SBDEV-2994-move-stock-unknown-destination-container`, committed **`3abb1f2`, 2026-08-19** — i.e. the 08-17 "V2.2.17 is free" reading was **true when made** and was overtaken two days later by a parallel ticket of our own. V2.2.18 is free across every remote as of 2026-08-19. This is `flyway-version-pick-sweep-all-remote-branches` landing exactly as predicted: `ls` shows only merged versions, unmerged branches hold invisible ones, and the window between picking and merging is where the collision forms. **P6's sweep is therefore still required at PR time — the answer below is perishable, not final.** |
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

**A9. Spring Data REST is out of reach of the interceptor — ⚠️ but "and that is fine" is FALSE, corrected 2026-08-20.** *(Critic F6; conclusion falsified by P3, §14.12.a.)* **The mechanism description below is right and was right from the start. Its verdict was not:** `/v3/fixLocationAssignment` — named in this very paragraph — is called **only by the mobile UI**, from `components/replenish/shared/OrderHeaderBlock.vue:92`, *inside the Replenish workflow this plan gates*. So one of these unreachable paths is not a shared/web capability that ought to stay open; it is a mobile capability that ought to be gated and cannot be. Closed by **removal** (`exported = false` + a gated controller read) per §14.12.b, checklist steps 13/14, AC-32. The remaining SDR paths listed here are genuinely shared and stay open as R12. `/v3/section`, `/v3/stockunit`, `/v3/client`, `/v3/fixLocationAssignment` are served by `RepositoryRestHandlerMapping`, which does **not** honour `WebMvcConfigurer.addInterceptors`. They never reach the guard **at all** — not, as a naive reading suggests, because their declaring class is outside the mobile package. The outcome is what we want, but the rationale must be recorded correctly, and A4's "cannot escape" claim holds for MVC controllers only.

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

### 3.4 Fix D — `V2.2.18__seed_mobile_workflow_functions.sql`

Version: **V2.2.18** — ⚠️ **re-picked 2026-08-19; the earlier V2.2.17 is taken** by `origin/feature/SBDEV-2994-…` (`3abb1f2`, 2026-08-19). `origin/develop` head remains V2.2.16; V2.2.18 is unclaimed on every remote as of the 08-19 sweep. **Re-sweep all remote branches immediately before the PR** (versions are append-only; V2.2.11/14/15/16 were claimed off-develop, #166 carried none, and 17 was claimed *after* this plan reserved it). Any test or verify row naming the version must be updated with it — see §14.8.

Idempotent, three parts:

1. **Insert function rows** — `MOBILE_UI_VIEW_REPLENISH_REQUEST` and, defensively, `MOBILE_UI_VIEW_CANCELLATION`, each guarded by `WHERE NOT EXISTS (SELECT 1 FROM mywms_function WHERE name = …)`. Column shape from the base dump (`V2.2.00__base_v2_schema.sql:2739`): `id` from `nextval('seqentities')`, `version = 0`, `client_id = 0`, `name = number = function = <constant>`.
2. **Back-compat grant** — every role holding `MOBILE_UI_VIEW_REPLENISHMENT` also gets `MOBILE_UI_VIEW_REPLENISH_REQUEST`, so C1's split removes nobody's access. **Use `AND NOT EXISTS (…)`. Do not use `ON CONFLICT` in any form** — ✅ **P5 measured 2026-08-19, and the constraint population is heterogeneous three ways:**

   | Where | Unique/PK on `(rolelist_id, functionlist_id)` |
   |---|---|
   | `V2.2.00__base_v2_schema.sql:1512-1515` (base dump) | **none** — two FKs and one index on `functionlist_id`, no PK |
   | WineCo dev (`dev_wh01_om1`), live | PK **`mywms_role_mywms_function_pkey`** |
   | Hydra UAT, live | PK **`mywms_role_mywms_function_pk`** — same columns, **different name** |

   So both `ON CONFLICT` forms are unsafe on a different subset of tenants: `ON CONFLICT ON CONSTRAINT <name>` breaks on the name drift between the two live tenants, and column-inference `ON CONFLICT (rolelist_id, functionlist_id)` raises **42P10** on any tenant provisioned from the base dump, where no matching constraint exists. `NOT EXISTS` is the only form correct on all three, so the plan's original choice stands — now **measured rather than assumed**, which is what P5 was for.
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

**E2. `GET /v3/adminAction/accessAudit`** on **`AdminActionController`** — ⚠️ **corrected 2026-08-20; this line said `AdminController` and that was wrong** (§14.15). Declaring it on the base class would register it under all 43 subclass prefixes, ~90 alias URLs for one diagnostic; on `AdminActionController` it has exactly one URL, which is also the only reading consistent with the path this same line specifies. `@PreAuthorize(Authority.IS_SB_ADMIN)`, read-only — the same six sets **already joined** against Keycloak via the injected `KeycloakService`, adding `keycloakMapped: true|false` per row plus a seventh set: Keycloak warehouse-group members with **no** `mywms_user` row. This is the ongoing surface; E1 + E1-P is the pre-deploy one. RC-2 applies to this annotation as to every `@PreAuthorize` here: correct today, unverifiable by unit test. The endpoint is diagnostic and read-only.

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

D1 is **hard-on at deploy with no feature flag** — a locked decision. These prerequisites are what replaces the kill switch. **`Blocking?` means blocking the PR and the image landing, not blocking the TDD gate** (nothing has blocked the gate since 2026-08-20). Reconciled 2026-08-21: three rows had a `Blocking?` value that contradicted their own text. For *implementation* state do not read this table either — run `sbdocs/9-System/scripts/plan-state.sh SBDEV-2968`; this table is authoritative only for prerequisites.

| # | Prerequisite | Blocking? |
|---|---|---|
| ~~**P1**~~ | ✅ **CLOSED 2026-08-21 — both halves done.** DB half: all **4 active UAT tenants** plus **Hydra prd** audited 2026-08-20 (§14.18/§14.18a) — exactly one required function row missing everywhere, `MOBILE_UI_VIEW_REPLENISH_REQUEST`, which is the one `V2.2.18` seeds; the other 11 exist on all five. prd also validated P5: **no PK and no unique constraint**, a *third* variant beyond §14.8's three, so both `ON CONFLICT` forms would have failed on production and the `NOT EXISTS` decision prevented a migration failure. **Keycloak half: the E1-P join is RUN (§14.26)** over the 7-name worklist §14.21 derived — **1 mapped (`lukamiranda`), 6 unmapped.** The decisive one: `Z-mariaortiz(archived)` was the ONLY account in the whole population holding `MOBILE_UI_LOG_IN` with zero `MOBILE_UI_VIEW_*` — the only user who could have lost mobile access — and she does not exist in Keycloak. **Measured conclusion: zero users lose access on any tenant in any environment.** Evidence: `9-System/evidence/SBDEV-2968-p1-uat-function-audit.txt`. | Done |
| ~~**P2**~~ | ✅ **CLOSED 2026-08-21 — both clauses satisfied.** (1) Corrected `SET 4` (users locked out of *every* gated workflow, evaluated post-migration via `projected_held`) has been **run on all six live databases** (§14.21): **0 on prd, measured rather than derived**, 0 on Hydra UAT / shipitez c1wh / shipitez nywh, 4 on WineCo dev, 3 on wineco/wsl — all `Z-…(archived)`. Pre-fix the same query returned 54 and 15 and could never be empty (§14.20 fix 3). (2) The one **Keycloak-mapped** `SET 1` user has a **named remediation of record** (§14.26, Nam 2026-08-21): `lukamiranda` stays archived on UAT — her row there is intentionally marked `Z_Luka`, her access is dev-only, she holds zero functions before and after, so gating takes nothing from her. ⚠️ Two readings that must travel with any zero here: the 2026-08-18 amendment still governs (shipitez/nywh at 9-of-9 and prd at 7-of-7 are the *uninformative* kind of empty — no role has an exclusive holder, so those tenants cannot *demonstrate* the gate), and `SET 4` is scoped by construction to users holding ≥1 function, so it can never report a zero-grant user — that is `SET 1`'s disjoint population, and the counts reconcile exactly (36−33=3, 11−9=2, 94−49=45, 9−7=2). **"SET 4 empty" means nobody holding something is left with nothing, not nobody is locked out.** | Done |
| ~~**P3**~~ | ✅ **CLOSED 2026-08-20 with findings — see §14.12.** Direction 1 confirmed: **zero** web-UI calls into the eleven in-scope prefixes across 289 web paths, so gating breaks no web screen. Direction 2 corrected: **§0.B lists 5 shared endpoints; the real count is 17+**, and 🔴 **five are Spring Data REST `/search/…` queries that `@RequiresFunction` structurally cannot gate — one of them actionable** (§14.12.a) — one of them mobile-only and inside the Replenish workflow. The method matters: my first pass missed a path assigned to a variable, so the numbers come from a broad literal sweep filtered against 127 server-derived prefixes. Original text: Re-derive the **complete bidirectional** cross-caller inventory: every `$axios` path in `wms2-mobile-ui` (`store/*.js`, `pages/*.vue`, `components/**`) *and* in `wms2-web-ui`, reconciled against §0.A/§0.B. The first enumeration missed a whole direction; assume this one can too. | Done |
| ~~**P4**~~ | ✅ **CLOSED 2026-08-20 (§14.16).** Built from reflection: **67 handlers / 67 URL mappings** on the 11 controllers (§0.A's withdrawn "66" resolves to **67**), class-level map matches §3.1-A5 exactly, and the method-level overrides are exactly the three A5/A5.1 predict. `AdminController` contributes **9** unannotated mapped methods → 99 pass-through alias URLs. Evidence: `9-System/evidence/SBDEV-2968-p4-reflected-golden-map.txt`. Found: A5.1's table is one row short (`fixedLocationUpperBound`, step 13) and `CycleCountLosController#processScanUnitLoad` is two handlers, not one. | Done |
| ~~**P5**~~ | ✅ **CLOSED 2026-08-19 — measured on two live tenants plus the base dump.** The population is heterogeneous three ways: **no constraint** in `V2.2.00__base_v2_schema.sql:1512-1515`, PK **`…_pkey`** on WineCo dev, PK **`…_pk`** on Hydra UAT (same columns, different name). Both `ON CONFLICT` forms are therefore unsafe on a different subset — the named form breaks on the drift, the column-inference form raises **42P10** on base-dump tenants. **`NOT EXISTS` confirmed as the only universally correct guard**; §3.4 part 2 unchanged in substance, now evidenced. See §14.8. | Done |
| **P6** | Re-sweep `V2.2.*` across **all remote branches** at PR time. ⚠️ **PARTIALLY ANSWERED 2026-08-19 and it found a live collision: V2.2.17 is TAKEN** by `origin/feature/SBDEV-2994-…` (`3abb1f2`, committed 2026-08-19, *after* this plan reserved the version on 08-17). **This plan moves to V2.2.18**, free across every remote at the time of the sweep. `origin/develop` head is still V2.2.16; the "local is 36 commits stale" caveat is spent. **Row stays BLOCKING** — the answer is perishable and must be re-derived at PR time, which is precisely what this instance demonstrates. ✅ **RE-SWEPT 2026-08-20 (§14.16): V2.2.18 confirmed free** across all remote refs, all local refs and every on-disk worktree; highest elsewhere is V2.2.17, which **`origin/develop` now carries** (the "develop head is V2.2.16" note above is spent). Re-run at PR time anyway. | **YES** — at PR time |
| ~~**P7**~~ | ✅ **ANSWERED 2026-08-20 (§14.17), and the answer CHANGED — written to the ticket.** 🔴 **"Mobile-first is strictly safe" is FALSE as written:** the client gates `/replenish-request` on `MOBILE_UI_VIEW_REPLENISH_REQUEST`, a function `V2.2.18` creates on the **API** side, so mobile-first denies Replenish Request to everyone until the API lands — **15 of 19 Hydra UAT users**, measured. The order is now **three** steps: apply `V2.2.18` → deploy mobile → deploy API. Mobile-before-API still holds between steps 2 and 3, for the original reason. | Done |
| ~~**P8**~~ | ✅ **WRITTEN TO THE TICKET 2026-08-20 (§14.17)** — primary rollback is reverting `WebConfig.addInterceptors` (one redeploy; annotations, the header, the CORS entry, the audit endpoint and the startup assertion are all safe to leave). ⚠️ **The "faster remedy" does not work in prd:** the admin grant goes through `saveRoleFunctions`, which SBDEV-3005 fixed, and `origin/main` — which prd tracks — is **29 commits behind and lacks that fix**. In prd the remedies are the redeploy or direct SQL. Also recorded: do NOT revert `V2.2.18`, and how to diagnose a denial (403 + `ProblemDetail`, `X-Authz-Denied`, the two metrics, the audit endpoint). | Done |
| ~~**P10**~~ | ✅ **DE-BLOCKED 2026-08-20 — keep the work, drop the 🔴.** The premise was falsified (R6b re-graded High → Low, §14.10a): an authz 403 never logs the operator out, so **"without this the deny UX is worse than today's" is not supported** and this is no longer a ship-blocker. The fix is still worth doing — one spurious retry per denial plus a generic error instead of a typed message — and it stays in scope as §3.2-B5. **Its verification moves to Jest** (`test/plugins/axios.spec.js#doesNotRetryWhenXAuthzDeniedHeaderPresent`), which CASE 5 of the probe proved viable: with the header present today, `retryCondition` still returns `true`, so the test genuinely goes red→green. Original text: Make `retryCondition` stop retrying an authorization 403 (§3.2-B5).** Both UIs currently retry a 403 three times then `$kc.logout()`, so every A7 deny logs the operator out instead of showing the message. Emit `X-Authz-Denied` from the interceptor (A2 step 6) and skip retry when present. **Without this the deny UX is worse than today's.** **Re-scoped 2026-08-17:** the server half is no longer inherited from SBDEV-2870 — this plan must build the constant, the emitter **and** the CORS exposure (§3.1-A2b). No test in this repo can prove the last one — **and neither can a `curl`**, which is not CORS-filtered. Evidence is **M23**, a local browser test as an under-privileged user. | Done — de-blocked |
| ~~**P11**~~ | ✅ **CLOSED 2026-08-17 — decided and executed.** #166 merged first (`27e2f21`) and this ticket's worktree fast-forwarded onto it; the branch had no commits of its own, so this was a clean fast-forward, not a rebase, and nothing had to be replayed. The golden map and startup-assertion baseline will now be built once, against a stable surface. Verified post-merge: `AdminController` = **9** mapped methods, `UserAdministrationController` present, Flyway head still **V2.2.16** so V2.2.17 remained free **as observed on 08-17 — no longer true; see §14.8, this plan is on V2.2.18** (P6's all-remote sweep is still owed at PR time). See §14.3. | Done |
| ~~**P9**~~ | ~~Report the §0.C finding to SBDEV-2870 — its five endpoints have ~11 URLs each.~~ **CLOSED 2026-08-17** — reported, and PR #166 acted on it: four of the five endpoints moved to a standalone controller and now have one URL each (§0.C consequence 2). | Done |

### 5.2 Implementation checklist

0. ✅ **Base resolved** — worktree is on `27e2f21` (post-#166). Done 2026-08-17; nothing reflective was written before it.
1. Create `security/RequiresFunction.java`, `security/AccessDecision.java`, `security/FunctionGuardInterceptor.java`.
2. Add `AccessService.doesUserHaveAnyAccess` + `checkAnyAccess`; leave `doesUserHaveAccess` and its call sites untouched — ⚠️ **the count is now 8, not 5** (SBDEV-2870 added the user-administration sites), and **`AccessService.java` itself moved under this plan on 2026-08-20 via SBDEV-3005** (§14.13). Re-read the class before extending it.
3. **Move `OrderCancellationController` into `controller/mobile/`** (package line + file move; zero external references — verified). Do not add `extends AdminController`.
4. Annotate all 11 controllers per §3.1-A5; derive the `ReplenishController` split from `store/replenish.js` callers.
5. Register the interceptor in `WebConfig`; add the `SmartInitializingSingleton` startup assertion (A8).
6. Add `MOBILE_UI_VIEW_REPLENISH_REQUEST` to `FunctionEnum`; extend the `UtilRestController` seed (C2).
7. Write `V2.2.18__seed_mobile_workflow_functions.sql` and `db/audit-access-invariants.sql`.
8. Add `AccessAuditService` + `GET /v3/adminAction/accessAudit`.
9. Mobile UI: `util/menuCatalog.js`, `middleware/require-function.js`, `nuxt.config.js`, `store/home.js`, `pages/not-authorized.vue`, `plugins/axios.js` — **including the `retryCondition` fix (P10); the message rendering is inert without it**.
10. Add the `setupMockMvcWithGuard` **additive** overload to `BaseControllerUnitTest` (do not modify `setupMockMvc`).
11. Update `sbdocs`: `wms2-keycloak-role-matrix.md` (username-only Keycloak link; `AdminController` inheritance multiplies each mobile controller's URL surface by **9** post-#166) and `wms2-function-to-docs-map.md` §9 — **which must also gain the new `UserAdministrationController` (§0.26)**.
12. **(A2b, new)** Add `Authority.AUTHZ_DENIED_HEADER`; add the header to `SecurityConfiguration.corsConfigurationSource` using the existing SBDEV-2632 additive + `contains()` shape; extend `SecurityConfigurationTest`'s **exact** exposed-header expectation. Do this in the *same* commit as the interceptor's emit — a header without its CORS entry is a silent no-op in the browser.
13. **(R16, new — decided 2026-08-20, §14.12.b)** Close the one gateable SDR hole: add
    `@RestResource(exported = false)` to **`FixLocationAssignmentRepository.findByAssignedlocationId` ONLY**
    (leave its eight sibling searches exported — they may have web callers), and add a `@RequiresFunction`
    -annotated read to `ReplenishController` returning the `upperbound` scalar. Follow the `2c5cbc2` /
    `553bbb1` precedent.
14. **(R16, mobile half)** Repoint `components/replenish/shared/OrderHeaderBlock.vue:92` at the new endpoint and
    **delete the three-shape defensive parsing** — the controller returns one number, so the object / array /
    `.content` fallbacks become dead code. Removing them is part of the step, not a follow-up: leaving them
    means the component still tolerates the SDR response shape it is no longer allowed to receive.
15. **(R15, new — the risk had no owner until 2026-08-20)** Prove the denial *renders*. The `scan*` endpoints
    answer failure with **HTTP 200 + an `{"errors":[…]}` envelope** (measured, §14.11.b); the interceptor answers
    **403 + `ProblemDetail`**. Two contracts on the same screens. Find the mobile handler for a 403 body — check
    `plugins/axios.js` and the page-level `catch` blocks — and add a Jest assertion that a 403 `ProblemDetail`
    surfaces the typed message. **Do not infer this from "these pages already show errors"**; that path handles
    the 200-with-`errors` shape and need not fire for a 403. Failure mode if skipped: *the gate works and users
    see nothing*, which reads in QA as the gate being broken.

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
| M11 | `outbound-worker` after V2.2.18 | Replenish Request tile | visible and functional | |
| M12 | user mid-session | admin revokes a function | tile gone on next `refreshMenus`; API denies immediately | |
| M13 | CS-REP (LOG_IN, no view fns) | log in | empty home screen, no error, no crash (C4) | |
| M14 | `sb_admin` staff, no `mywms_user` row | log in to mobile | empty screen, all workflows denied — **same as today**, no bypass (§10.2) | |
| M15 | `outbound-forklift` | `curl …/v3/lookup/searchSku/abc` | **403** — no UI caller | |
| M16 | `outbound-forklift` | `curl …/v3/replenish/reservedOrder` | **403** — no UI caller | |
| M17 | authorised picker | hard-refresh (F5) on `/mobile/picking` | loads; **no** bounce to `/not-authorized` | |
| M18 | `outbound-manager` after V2.2.18 | Transfer Process | visible and functional via `WEB_UI_VIEW_TRANSFER_ORDER` (D4) | |
| M19 | `sb_admin`, any tenant | `GET /v3/adminAction/accessAudit` | every row carries `keycloakMapped`; unmapped legacy rows flagged, not silently dropped | |
| M20 | any tenant, PR time | re-sweep `V2.2.*` across all remotes | **V2.2.18** is still free — V2.2.17 was lost to SBDEV-2994 on 2026-08-19 (was AC-25) | |
| M21 | scratch tenant DB | run V2.2.18 twice | second run is a no-op; no duplicate `mywms_role_mywms_function` rows | |
| M22 | any tenant | run `db/audit-access-invariants.sql` | six named result sets, read-only, no error (was AC-30) | |
| **M23** | **local dev**: `wms2-mobile-ui` on `:3001` against `wms2-api` on `:8088`, signed in through real Keycloak (realm **`wineco`**, client `om1`, `kc2.dev.sbo.li`) as **`sbtest`** — resolved 2026-08-19, see §14.9. Subject must hold `MOBILE_UI_LOG_IN` and **zero** `MOBILE_UI_VIEW_*`, and **must have a `mywms_user` row** (`sbtest` = id 19800000). | ⚠️ **REWRITTEN 2026-08-19 — do NOT "tap a gated tile"; there is no tile and no home page.** `pages/index.vue:190-203` sets `affiliated = (pageList.length > 0)`, and `MOBILE_UI_LOG_IN` is not one of the 12 tile roles, so a zero-view-function subject renders **zero tiles → `<not-affiliated />`**. **Deep-link instead:** `http://localhost:3001/cycle-count`. Then run **two distinct probes**: **(i)** via the app's own instance — `await window.$nuxt.$axios.$get('/cycleCountLos/…')` — for the retry/logout behaviour, and **(ii)** raw `fetch(...).headers.get('x-authz-denied')` for header exposure. | **(a)** the A7 denial message renders, **(c)** probe (ii) returns a **non-null** function name. ⚠️ **(b) MOVED OUT 2026-08-20 — it belonged in Jest, not here.** The retry/logout behaviour is pure control flow in `plugins/axios.js`, and §14.10a settled it deterministically there; as a manual browser step it was **incapable of failing** (on a fresh token, unfixed code already makes one attempt and never logs out). Its home is `test/plugins/axios.spec.js#doesNotRetryWhenXAuthzDeniedHeaderPresent`. **M23 now carries only the two assertions that genuinely require a browser** — a rendered denial, and a header readable from JS under CORS | **AC-31's + P10's evidence of record.** ⚠️ **The single-`fetch` form was wrong**: raw `fetch` does not pass through `plugins/axios.js`, so it can prove (c) and is **structurally incapable** of proving (b) — hence two probes. `curl` and the DevTools Network panel still fail to discriminate (c). ⚠️ **(b) may be incapable of failing — see R6b's 2026-08-19 challenge**; record the attempt *count*, not just the absence of a logout. Requires no deployed environment. |

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
| **R6b** | ✅ **RE-GRADED 2026-08-20: High → LOW. The challenge held; the original claim is FALSIFIED.** Settled empirically (§14.10a): a 5-case Jest probe against the real `plugins/axios.js` plus the keycloak-js source (`lib/keycloak.js:1474-1481`) shows `updateToken(minValidity)` returns **`false`** when the token is not expiring, so `retryCondition` gives up at `:57` **without retrying**, and `onMaxRetryTimesExceeded` — the only path that toasts and calls `logout()` — **never fires**. Worst-case chain measured at **2 attempts, 0 logouts**. **An authz 403 does not log the operator out.** Restated failure mode: *"retries at most once and surfaces a generic error instead of the typed message."* Original claim retained for the record: 🔴 An authorization 403 logs the operator out. Both UIs retry a 403 three times with a token refresh, then `$kc.logout()` on an authenticated session (`plugins/axios.js:35-37, :92`) — so every A7 deny presents as a session failure and the typed messages never render. Found 2026-08-17. **The challenge:** re-reading `plugins/axios.js:35-70`, `retryCondition` awaits `$kc.updateToken(5)`, which keycloak-js resolves **`false`** when the token needs no refresh; that hits `:57` and returns `false`, so there is **no retry**, so `onMaxRetryTimesExceeded` (`:72-91`, the toast + `logout()`) **never fires**. The reachable logout is the `catch (refreshError)` branch at `:64-69` — a refresh *failure*, which a 403 does not cause. | **High → pending re-grade** | §5.1-P10 unchanged — emit `X-Authz-Denied` and return `false` from `retryCondition` when present; `test/plugins/axios.spec.js#doesNotRetryWhenXAuthzDeniedHeaderPresent`. | **Unresolved by reading. §14.9 Phase A step 6 is the empirical test** and must run before this row is re-graded. If the challenge holds, the realistic worst case is *one extra retry when the token sits inside its last 5 seconds*, and **M23's assertion (b) goes green on unfixed code** — a row incapable of failing, the class §14.5 already caught twice. **Do not downgrade P10 on the reading alone**, and do not treat a green (b) as evidence until the count is recorded. The prior residual still stands: the CORS half is unprovable by any test in this repo, so "header emitted, browser can't read it" is live until M23 runs. |
| **R13** | 🔴 **The `X-Authz-Denied` contract is dropped by both plans.** It was reverted from SBDEV-2870 on the argument that 2967 Fix E would carry it, while this plan — which lands *first* and needs it — recorded it as already-done. Each plan can point at another as the owner. Found 2026-08-17. | **High** | §3.1-A2b assigns the constant, the emitter and the CORS entry **here**, and 2967 §3.5.1-4 / §5.1-P8 are edited to consume rather than create. Test: `deniedResponseCarriesTheAuthzDeniedHeaderNamingTheFunction` + `corsExposedHeadersContainsAuthzDeniedHeader`. | Low now that ownership is written down in both plans — but this is the second time a relocation between these three tickets left an orphan (the first cost 2870 its §10.1 blocker). Re-check ownership after **any** future scope move between 2870/2967/2968. **Mitigation superseded 2026-08-19 (§14.7)** — prose replaced by the `[inherited]` verify-row class, after a third instance (§14.6) showed the defect is any inherited claim, not only a relocation. |
| **R6** | Nuxt cold-start — the middleware runs before roles load and bounces every hard refresh to `/not-authorized`. | Medium | Memoised `ensureRolesLoaded()` awaited in the middleware; three distinct states (loading / denied / fetch-failed); `waitsForEnsureRolesLoadedBeforeDeciding`; M17. | Low. |
| **R7** | Deploying api before mobile-ui gives the generic toast instead of the actionable message. | Medium | §5.1-P7 pins **mobile-ui first**; mobile-first is strictly safe. | Low. |
| **R8** | ⚠️ **MATERIALISED 2026-08-19, exactly as written.** V2.2.17 collided with `origin/feature/SBDEV-2994-…` (`3abb1f2`), claimed two days *after* this plan reserved it. | Medium | Re-picked to **V2.2.18** by the §5.1-P6 sweep; M20 re-run at PR time. **The lesson is the timing, not the number:** the 08-17 reading was correct when taken, so a version pick is only valid at the moment of the sweep — and the collision came from a sibling ticket in the same workstream, not a stranger's branch. | Low **for V2.2.18, and only until the next sibling branch claims it.** |
| **R9** | The audit reads as noise or false alarm because unmapped legacy rows dominate — the exact misreading that produced the "42 of 96" scare. | Medium | §3.5 chooses the Keycloak cross-check over a hand-applied caveat; E1-P is a mandatory join step; E2 stamps `keycloakMapped` on every row; M19. | Low. |
| **R10** | The audit is implemented with per-username `existsInKeycloak` — N round-trips **and** an ungated SBDEV-2870 endpoint that may gain a guard. | Low | §3.5 states the bulk requirement; `doesNotCallExistsInKeycloakPerUsername` pins it. | Low. |
| **R11** | **RE-STATED 2026-08-19 after P5 measured it — the premise was half right, and the failure mode differs by tenant.** The base dump has no unique constraint (a re-run duplicates grants), but both live tenants carry a composite PK (a re-run raises **23505**). | Low | `NOT EXISTS` guard, **never `ON CONFLICT` in either form** (§3.4 part 2 — the named form breaks on `_pkey` vs `_pk` drift, the column form raises 42P10 on base-dump tenants); §5.1-P5 closed; M21. `getAllRoles` is `SELECT DISTINCT`, so duplicates are functionally harmless but pollute the audit. | Low **while the guard is present**. ⚠️ If it were ever dropped, the consequence is not "duplicate rows" everywhere — on a live tenant it is a 23505 that aborts the whole migration file and stalls that tenant's Flyway chain (`los-sysprop-description-varchar-255-aborts-migration` shape). |
| **R12** | ⚠️ **UNDERSTATED — corrected 2026-08-20 (§14.12).** Not five shared endpoints but **seventeen or more** (§14.12.c), of which **five are Spring Data REST searches the mechanism cannot gate at all** and one (`/fixLocationAssignment/search/findByAssignedlocationId`) is **mobile-only and used inside the gated Replenish workflow**. Original text: The five §0.B shared endpoints stay reachable by a denied user — the tile is enforced, the shared capability is not. | ~~Low~~ **Medium** (owner, 2026-08-21) | Documented as an explicit scope boundary in §0.B and in the ticket's closing note. Narrowing it needs a per-caller distinction the shared controllers do not support. 🔴 **RE-GRADED Low → MEDIUM by owner decision 2026-08-21, and the residual is not what this row said twice over.** (a) The **mutating** half is CLOSED: `POST /v3/stockUnit/transferStock` is now gated by a reviewed method-level `@RequiresFunction` (§14.22 H2) — it was reachable by *ordinary navigation*, not deliberate replay, which is what made `Low` wrong. (b) A **new** member arrived from outside this ticket: SBDEV-3003 Slice 2 enrolled that same path into `IdempotencyFilter`, which replays a cached 2xx **without invoking the handler**, on a key that is not principal-scoped (§14.23/§14.24). What remains is therefore read-only exposure (`/v3/section*` via SDR, `/v3/dashboard/*`) **plus** the nonce-replay path. | **Accepted and stated. Follow-up ticket FILED 2026-08-20: [SBDEV-3017](https://app.clickup.com/t/868kufdy1) Class B** — carries the measured 17+ surface, the cross-namespace ANY-of option (likely the right answer, since it closes the "holds neither function" case cheaply), and the instruction to re-derive the inventory server-side rather than by grep. |
| **R14** | `IS_SB_ADMIN` on the new audit endpoint is itself unverifiable by unit test (RC-2 applies to it too). | Low | Read-only, diagnostic; the `/v3/**` `wms_user` floor bounds exposure; exposes structure, not credentials. | Accepted. |
| **R15** | **The denial's response shape is not the shape these screens already handle.** The `scan*` endpoints answer failure with **HTTP 200 + an `{"errors":[…]}` envelope** (measured 2026-08-20, §14.11.b); the interceptor answers **403 + `ProblemDetail`**. Two contracts on the same screens. | Medium | Do not infer A7 from "these pages already show errors" — the 200-with-`errors` handler is not necessarily the one that fires for a 403 body. Add an explicit mobile-side assertion that a 403 `ProblemDetail` renders the typed message, and check `plugins/axios.js` / the page-level catch blocks for a 200-only error path. | Open. Cheap to close during implementation, expensive to discover in QA — it presents as "the gate works but users see nothing." |
| **R16** | 🔴 **`@RequiresFunction` cannot gate Spring Data REST.** ⚠️ **Attribution corrected 2026-08-20: the mechanism limitation was already documented at §3.1-A9 (Critic F6) and is NOT a new finding. What P3 adds is that A9's *verdict* — "and that is fine" — is false**, because one such path is mobile-only and inside a gated workflow. Five of the seventeen shared endpoints the mobile UI calls are SDR `/search/…` queries handled by `RepositorySearchController` — outside `controller/mobile/`, unannotated, so the interceptor allows them and the A8 startup assertion does not see them (§14.12.a). `/fixLocationAssignment/search/findByAssignedlocationId` is mobile-only and sits inside the Replenish workflow, and its repository exposes 8 more searches on the same path. | **Medium–High → Low once steps 13/14 land** | ✅ **DECIDED 2026-08-20 (§14.12.b): options D + C** — `exported = false` on the single mobile-only search plus a `@RequiresFunction` read on `ReplenishController`, which **removes** the capability instead of guarding it and keeps the compile-safety property. Precedent: `2c5cbc2`, `553bbb1`. The four *shared* SDR searches take option A (stated residual, R12). Option B — a path-keyed rule that would close the whole class — is **deferred to [SBDEV-3017](https://app.clickup.com/t/868kufdy1)**, which also carries the correction that A9's verdict was wrong and the warning to verify *which* enforcement point actually fires for `RepositoryRestHandlerMapping` before designing around it. | **In scope now (steps 13/14), no longer blocking** — but the ticket's closing note must not say "mobile workflows are function-gated" without naming this. **Third occurrence of the SBDEV-1666 shape** (1666; SBDEV-2870 §10.2; here): a guard keyed on one dispatch path while a second dispatch path reaches the same data. |

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
| **AC-31** *(A2b)* ★ | ✅ **PRE-FIX HALF CAPTURED 2026-08-20** — the bypass is measured on `develop`: 35/35 GET endpoints reached their handler as `sbtest`, **0 × 401, 0 × 403**, incl. 21,260 bytes of live cycle-count orders. Evidence: `9-System/evidence/SBDEV-2968-ac31-prefix-bypass-baseline.txt`, §14.11. The POST-fix half below remains **unrunnable until the interceptor exists** — nothing on any branch emits the header. | The browser can **read** that header cross-origin: `Access-Control-Expose-Headers` lists `X-Authz-Denied`, exactly once, even when `rest.security.cors.exposed-headers` also supplies it. | `SecurityConfigurationTest#corsConfigurationSource_exposesAuthzDeniedHeader_whenPropertyAbsent`, `#corsConfigurationSource_doesNotDuplicateAuthzDeniedHeader_whenPropertyAlreadySuppliesIt` — **plus M23 (local browser test), which is the real evidence** |
| **AC-32** *(R16)* | The one gateable SDR hole is **closed by removal, not by a guard**: `FixLocationAssignmentRepository.findByAssignedlocationId` carries `@RestResource(exported = false)`, its eight sibling searches remain exported, a `@RequiresFunction`-annotated `ReplenishController` read serves the `upperbound` scalar, and `OrderHeaderBlock.vue` calls that endpoint with the three-shape fallback deleted. | Unit-assertable on the API side (annotation presence + the guarded-controller golden map already covers the new endpoint); the mobile half is a spec/grep assertion plus the existing Jest suite. **A live check that `GET /v3/fixLocationAssignment/search/findByAssignedlocationId` now 404s is the honest proof** — the pre-fix baseline in §14.11 recorded it reachable, so this is a genuine before/after pair rather than a claim. | Decided 2026-08-20, §14.12.b. Note what this AC does **not** cover: the four shared SDR searches and R12's sixteen, which take option A and must be named in the closing note. |

† **AC-4, AC-5, AC-12** "fail" on `develop` only because `RequiresFunction.class` does not compile yet. They are correctness pins on the implementation, not behavioural gates — stated so nobody mistakes them for evidence of a pre-existing defect.
‡ **AC-26 passes vacuously on `develop` today** (no mobile controller uses `@PreAuthorize` — confirmed). It is a **regression pin**, not a gate.

★ **AC-31 is only half-assertable, and the assertable half is the weaker one.** `SecurityConfigurationTest` proves the bean's `CorsConfiguration` *lists* the header; no test in this repo proves a real response carries `Access-Control-Expose-Headers`, because `MockMvc` installs no `CorsFilter` (the same blind spot recorded in `wms2-response-reset-strips-cors-headers`). **M23 — a local browser test as an under-privileged user, asserting the denial renders, no logout occurs, and `headers.get('x-authz-denied')` is non-null from JS — is the evidence of record.** Do not substitute a `curl` or a DevTools header listing; neither is CORS-filtered, so neither can fail in the way that matters.

Two former criteria are **not CI-assertable** and have moved to the manual matrix: "V2.2.18 is the highest across all remote branches at PR time" → **M20/M21**; "the audit SQL exists and returns six named result sets" → **M22**. Neither can be asserted by anything in the build. **M23** (above) joins them.

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
| 8 | Rollback / migration | ✓ V2.2.18 (P6 re-sweep; 17 was lost to a sibling branch), P7 deploy order, P8 runbook |
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

**C-3 — Flyway and seed collision.** Both plans touch `FunctionEnum`, the `UtilRestController` seed, and need a tenant migration. This plan claims **V2.2.18** (re-picked 2026-08-19; V2.2.17 went to SBDEV-2994). SBDEV-2967 must re-sweep **all remote branches** and take the next free version; if both are in flight, whichever merges second re-sweeps again. Versions are append-only and never reused.

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
| Flyway head | V2.2.16, local checkout 36 commits stale | **V2.2.16 on a current worktree**; V2.2.17 free **— true when observed on 08-17, and overtaken on 08-19 by SBDEV-2994; this plan is now on V2.2.18, see §14.8**. #166 carried no migration. P6's all-remote sweep still owed at PR time |
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

> ✅ **SUPERSEDED 2026-08-19 — the review happened.** A real pass on the five §3.1-A2b decisions is recorded at
> [reviews/SBDEV-2968-review-a2b-header-contract.md](reviews/SBDEV-2968-review-a2b-header-contract.md) (reviewer
> Nam Park, against `27e2f21` with a live API on `:8088`), and every recommendation is applied — see its
> disposition table. Verdicts: ①③④ Sound, ② Sound-with-changes (`containsExactlyInAnyOrder`), ⑤
> Inadequate-as-written → replaced by §14.7's `[inherited]` row class. Three gaps (G1/G2/G4) are accepted with
> reasons; G3 was withdrawn. **The rest of this subsection is retained as the record of the period when the
> review was outstanding**, and its self-audit findings still stand on their own. What is *still* one-author is
> everything outside A2b: the mechanism, the 66-endpoint surface and the pre-existing verify rows were explicitly
> **out of scope** for that review ("Not examined"), as were F1, F4, F6 and F9, which it took on trust.

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

> ✅ **RESOLVED 2026-08-19 — no new account needed after all.** An existing fixture on WineCo dev fits:
> **`sbtest`** (`mywms_user` id **19800000**) → group `test group` → role `test role`, whose only function was
> `WEB_UI_LOG_IN`. Adding `MOBILE_UI_LOG_IN` (function id **51764**) to that role makes it a literal §14.6
> subject; it still holds **zero** `MOBILE_UI_VIEW_*`. **Full procedure in [§14.9](#149-m23-procedure-resolved-onto-sbtest-2026-08-19).**
> Consequence 2 below — the P1/P2 false all-clear — is **unaffected and still open**; only the subject problem
> is closed. The measurement below stands as written: no *pre-existing* user held the shape, and the fixture
> that does is one INSERT away rather than a whole provisioning exercise.

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

---

### 14.8 P5 and P6 answered — one guard confirmed, one version lost (2026-08-19)

Two blocking prerequisites were cheap enough to close on the spot. Both returned findings; neither returned
the answer the plan assumed.

**P6 — the version pick was already stale. `V2.2.17` → `V2.2.18`.**

`origin/develop` head is still `V2.2.16`, and an `ls` of the merged migration directory would have said
V2.2.17 was free. Sweeping *all* remotes says otherwise:
`V2.2.17__seed_transfer_destination_eligibility_sysprop.sql` sits on
`origin/feature/SBDEV-2994-move-stock-unknown-destination-container`, commit **`3abb1f2`, 2026-08-19**.

The instructive part is the chronology, not the collision. §14.3 recorded "V2.2.17 free" on 2026-08-17 and was
**correct when it was written** — the claim was staked two days later, by a sibling ticket in this same
workstream. So the failure mode is not "someone checked carelessly"; it is that a version pick has a shelf
life measured in days, and the branch that invalidates it is likely to be one of your own. Every artifact
naming the version has been moved to **V2.2.18** (§0.21, §3.4, checklist step 7, M11/M18/M20/M21, AC note, §12
C-3, and the verify script's `E1`/`E7` rows). §14.3's original line is annotated rather than rewritten — it was
a true observation and the record should show it aging, not show it as an error.

**P5 — `NOT EXISTS` confirmed, and both `ON CONFLICT` forms are traps.**

The plan asserted `mywms_role_mywms_function` "has no unique constraint in the base schema." Measured, the
population splits three ways:

| Where | Unique/PK on `(rolelist_id, functionlist_id)` |
|---|---|
| `V2.2.00__base_v2_schema.sql:1512-1515` | **none** — two FK constraints and one index on `functionlist_id` |
| WineCo dev (`dev_wh01_om1`), live | PK **`mywms_role_mywms_function_pkey`** |
| Hydra UAT, live | PK **`mywms_role_mywms_function_pk`** |

Each `ON CONFLICT` form is therefore wrong on a *different* subset of tenants — the named form
(`ON CONFLICT ON CONSTRAINT …`) breaks on the `_pkey` vs `_pk` drift between two live tenants, and the
column-inference form raises **42P10 "no unique or exclusion constraint matching"** on any tenant provisioned
from the base dump. `NOT EXISTS` is correct on all three. The plan's original choice survives, but its stated
*reason* was wrong in a way that pointed at the safe answer by luck: had the base dump carried the constraint,
"no unique constraint in the base schema" would have licensed column-inference `ON CONFLICT` and broken the
migration on whichever tenants lack it.

R11 is re-stated accordingly: without the guard the consequence is **not** uniformly "duplicate rows." On a
base-dump tenant it is duplicates; on either live tenant it is a **23505** that aborts the entire migration
file and stalls that tenant's Flyway chain — the `los_sysprop.description` shape, where one tenant's data
reality turns a benign statement into a chain-blocking abort.

**Two tenants is not the population.** Both readings come from WineCo dev and Hydra UAT because those are the
reachable MCP endpoints; shipitez ×2 and the prd copies were **not** measured. `NOT EXISTS` is
constraint-agnostic, so the guard holds regardless — but the *table above* must not be read as a census, and
§5.1-P1's per-tenant audit is the thing that would turn it into one.

---

### 14.9 M23 procedure — resolved onto `sbtest` (2026-08-19)

§14.6 concluded M23 needed a purpose-made account. It does not. An existing fixture on WineCo dev is one
`INSERT` away from being a literal §14.6 subject, and it is a *better* subject than the `CS-REP` shape the plan
assumed, because `CS-REP` carries 28 functions and this carries two.

**Measured state of the fixture (SELECT-only, via the `getAllRoles` chain):**

| Fact | Value |
|---|---|
| `sbtest` → `mywms_user` | id **19800000**, `client_id=0` — **has a row**, so it exercises the deny branch, not `USER_NOT_PROVISIONED` |
| Groups | `test group` **only** |
| `test group` → roles | `test role` **only** |
| `test role` → functions | `WEB_UI_LOG_IN` only (function id 51700) |
| `MOBILE_UI_LOG_IN` | exists, function id **51764** |

**Make it a subject — add, do not swap:**

```sql
INSERT INTO mywms_role_mywms_function (rolelist_id, functionlist_id)
SELECT 30262745, 51764
WHERE NOT EXISTS (SELECT 1 FROM mywms_role_mywms_function
                  WHERE rolelist_id = 30262745 AND functionlist_id = 51764);
```

Keeping `WEB_UI_LOG_IN` costs nothing — it is not a `MOBILE_UI_VIEW_*`, so the deny case is intact — and it
avoids mutating a shared fixture other work may depend on. The `NOT EXISTS` guard is not decoration: this DB
carries `mywms_role_mywms_function_pkey`, so a bare re-run raises **23505** (§3.4 part 2, R11).

**Environment (measured, not assumed):** tenant `wineco` — the only `active: true` row in
`dev_landlord.tenant_discovery`; Keycloak `https://kc2.dev.sbo.li`, realm **`wineco`**, client **`om1`**; DB
`dev_wh01_om1` @ `dev.sbo.li:25060`. ⚠️ **The facility code is `wsl`, not `wh01`** — the DB name is misleading,
and the Keycloak warehouse group is therefore **`/warehouse/wsl`** (lowercased by
`KeycloakService.getWarehouseGroupPath`). `sbtest` must also hold **`/wms_user`**: `redirectPage` calls
`isWmsUser` *first* and pushes `/not-authorized` when false, which is a different branch than the one under test.

#### Phase A — runnable NOW on `develop`, before any implementation

The interceptor does not exist yet, so there is nothing to deny with; **M23 proper is a post-implementation
test.** What is runnable today is the pre-fix baseline — the negative half the plan needs anyway.

> ✅ **Steps 1, 2, 6, 7 and 8 are DONE (2026-08-19/20). Results in [§14.11](#1411-ac-31-baseline-captured--the-bypass-measured-on-develop-2026-08-20)
> and [§14.10](#1410-two-defects-in-m23-itself-found-while-resolving-its-subject-2026-08-19).** Steps 3–5 remain,
> and they are the browser half — the only part that still needs a human or browser tooling.

**⚠️ Local routing, corrected 2026-08-20 — this cost three rounds of 401s.** The local-test tenant lives in the
**`landlord`** DB (not `dev_landlord`), which is what `application.properties:40` points at:

| | Value |
|---|---|
| Tenant header | 🔴 **`X-Tenant-ID: localhost`** — **NOT `tenant_name`**. `TenantFilter:23` declares `TENANT_HEADER = "X-Tenant-ID"` |
| Facility header | `facility_code: develop` |
| Derived routing key | `loca-develop` — `TenantKeyBuilder` = `first4(tenant) + "-" + facility`, matching the active `tenant_discovery` row |
| Keycloak | `kc2.dev.sbo.li`, realm **`wineco`**, client `om1` (`tenant_auth_configuration.client_id = om1-api` is the audience) |
| Tenant DB | `dev_wh01_om1` — the same DB `sbtest` lives in |

**Why the wrong header produces a misleading failure, not an obvious one:** `TenantFilter` treats a missing
tenant header as `TenantContext.setCurrentTenant(null)`, and `MultiTenantJwtDecoder.getJwtDecoder` then falls
back to the **default** decoder built from `rest.security.issuer-uri` (`realms/master`). The result is
`401 invalid_token — "Signed JWT rejected: Another algorithm expected, or no matching key(s) found"`, which
reads as a Keycloak/realm misconfiguration when it is really a malformed request. **Note the trap for this
plan specifically: a 401 here is indistinguishable at a glance from the guard working.** Anyone probing the
bypass with `tenant_name` will conclude the endpoints are protected. ⚠️ `CLAUDE.md` documents the pair as
`tenant_name` + `facility_code` for both v1 and v2 — wrong for this path, though not arbitrarily so, since
`TenantHealthController:30` really does take a `tenant_name` `@RequestHeader`. Two conventions, and the docs
record the one that does not route.

1. ✅ **DONE** — run the `INSERT` above.
2. ✅ **DONE** — confirm with the app's own query (`UserRepository.getAllRoles`,
   `repo/jpa/UserRepository.java:26-34`) that `sbtest` resolves to exactly `MOBILE_UI_LOG_IN` +
   `WEB_UI_LOG_IN` and **zero** `MOBILE_UI_VIEW_*`. Also confirmed *through the API*:
   `GET /v3/user/getAllRoles/sbtest` → `200 ["MOBILE_UI_LOG_IN","WEB_UI_LOG_IN"]`.
3. ⬜ Confirm the Keycloak side: realm `wineco`, groups `/wms_user` **and** `/warehouse/wsl`. *(Partially done —
   the access token carries `groups: ['/wms_user','/warehouse/wsl']` and `warehouse: ['WSL']`, so this is
   already evidenced for the API path; re-confirm only if the browser flow misbehaves.)*
4. ⬜ Start `wms2-api` on `:8088` and `wms2-mobile-ui` on `:3001`. **Do not add a dev proxy** — §14.4's argument
   depends on local being genuinely cross-origin. *(Steps 6–8 were run against an already-running `develop`
   build launched from `v2/wms2-api/target/classes`, not from the worktree; see §14.11's caveat.)*
5. ⬜ Log in as `sbtest`. **Expect the not-affiliated screen**, which itself confirms the tile filter works.
6. ✅ **DONE — see §14.11.** Deep-link `http://localhost:3001/cycle-count`, and/or replay the API directly.
   **Measured: 35 of 35 GET endpoints reach their handler; 0 × 401, 0 × 403.** That is the bypass, and it is now
   AC-31's pre-fix baseline of record.
7. ✅ **DONE — settled in Jest instead, see §14.10.** The browser form of this step was unnecessary: R6b's claim
   is pure control flow in `plugins/axios.js`, so a 5-case probe against the real plugin plus the keycloak-js
   source settled it deterministically. **Result: an authz 403 never logs the operator out** — worst case is one
   extra retry (2 attempts) when the token sits inside its last 5 seconds.
8. ✅ **DONE** — `sbdocs/9-System/evidence/SBDEV-2968-m23-test-account.txt` written; `X2` is green and the
   baseline is **17 pass / 88 fail / 7 skip**.

#### Phase B — M23 proper, after the interceptor lands

Same subject, same deep-link, both probes per the rewritten §9 M23 row: `$nuxt.$axios` for (b), raw `fetch` for
(c). Only JS can discriminate header *exposure*; neither `curl` nor the DevTools Network panel can.

**Cleanup:** `DELETE FROM mywms_role_mywms_function WHERE rolelist_id=30262745 AND functionlist_id=51764;`
Leave `sbtest`, `test group` and `test role` otherwise untouched.

---

### 14.10 Two defects in M23 itself, found while resolving its subject (2026-08-19)

Neither is about the mechanism; both would have made the plan's headline manual test misreport.

**1. "Tap a gated tile" is unrunnable for every valid subject — not just this one.**
`pages/index.vue:190-203`:

```js
if (this.isWmsUser) {
  await this.$store.dispatch('home/setMenus', { username })
  this.affiliated = this.$store.state.home.pageList.length > 0   // ← tile count, not a login function
}
```

`pageList` is the 12 tiles after the role filter (`store/home.js:104-118`), and **`MOBILE_UI_LOG_IN` is not one
of the 12 tile roles**. So any subject with zero `MOBILE_UI_VIEW_*` — including the exact shape §14.6
prescribes — renders zero tiles, sets `affiliated = false`, and gets `<not-affiliated />` instead of the home
page. There is no tile to tap and no home screen to tap it from. M23 must **deep-link**, which is more faithful
anyway: deep-link reachability is the defect. The tester who followed the old wording would have stalled on
step one and had no way to tell "the subject is wrong" from "the app is broken."

**2. 🔴 The prescribed probe cannot test the thing assertion (b) asserts, and (b) may be unfailable.**
The old row used a single raw `fetch`. Raw `fetch` **does not pass through `plugins/axios.js`**, so it never
touches `retryCondition`, `onMaxRetryTimesExceeded`, or the logout path — it can prove (c) and is
*structurally* incapable of proving (b). Fixed by splitting into two probes.

The deeper problem is (b) itself. Tracing `plugins/axios.js:35-70` for a 403 on an authenticated session with a
comfortably-valid token:

| Step | Line | Result |
|---|---|---|
| status is 401/403 → continue | `:37` | passes |
| `await $kc.updateToken(5)` | `:55` | keycloak-js resolves **`false`** when no refresh was needed |
| `if (!refreshed) return false` | `:57-59` | **no retry** |
| `onMaxRetryTimesExceeded` → toast + `logout()` | `:72-91` | **never fires** — retries were never exhausted |

So the logout R6b describes appears **not reachable** by an authz 403; the reachable one is `catch
(refreshError)` at `:64-69`, a refresh *failure*. If that reading holds, today's behaviour is one request, no
retry, no logout — which means **assertion (b) passes on unfixed code**, making it a row incapable of failing.

**This is recorded as a challenge, not a correction.** It is derived from reading keycloak-js semantics, it
contradicts a 🔴 High finding that survived a review pass, and the plan's own history (§14.5, §14.2) is a list
of confident readings that the *runtime* falsified. §14.9 Phase A step 7 settles it for the cost of one console
call. Until then: R6b keeps its **High** severity, P10 stays **blocking**, and M23's (b) is annotated so a green
result is not banked as evidence. If the challenge holds, the honest outcome is that P10 remains worth doing —
one spurious retry per denial and a generic error instead of a typed message is still bad UX — but it stops
being the ship-blocker the plan calls it, and R6b's failure mode needs restating from "logs the operator out" to
"retries once and reports nothing useful."

**Subject went live the same day.** `test role` (id 30262745) gained `MOBILE_UI_LOG_IN` (fn 51764) on
2026-08-19; the `getAllRoles` SELECT against `dev_wh01_om1` now returns exactly `MOBILE_UI_LOG_IN` and
`WEB_UI_LOG_IN` for `sbtest`, and the transcript is at
`sbdocs/9-System/evidence/SBDEV-2968-m23-test-account.txt`, flipping `X2` green (baseline **17/88/7**).

⚠️ **One caveat about that green, worth stating because the row cannot state it itself.** `X2` greps an evidence
*file* for the string `MOBILE_UI_LOG_IN`. A file is not a database: anyone can write that string without the
grant existing, and the row would go green identically. Its green here was corroborated by re-running the SELECT
— which is exactly the check `X2` is structurally incapable of making, since the script has no DB reach (that
limitation is why the row was designed as evidence-grading in the first place). **Whenever `X2` is cited,
re-confirm against the DB, not the file.** Same class as `A31`/`E7`: a row whose green is cheap to manufacture
needs its provenance named, or it reads as proof of something it never tested.

---

### 14.11 AC-31 baseline captured — the bypass, measured on `develop` (2026-08-20)

**Evidence of record:** `sbdocs/9-System/evidence/SBDEV-2968-ac31-prefix-bypass-baseline.txt`

**First, the question that had to be answered before any of this meant anything: does `develop` contain the
mechanism?** No — measured, not assumed:

| Symbol grepped on `origin/develop` (`src/main/**`) | Files |
|---|---|
| `RequiresFunction`, `FunctionGuardInterceptor`, `AccessDecision` | **0** each |
| `AUTHZ_DENIED`, `X-Authz-Denied` | **0** |
| `doesUserHaveAnyAccess`, `MOBILE_UI_VIEW_REPLENISH_REQUEST` | **0** |
| mobile UI: `middleware/require-function`, `x-authz-denied`, `menuCatalog` | **0** |

The only `MOBILE_UI_VIEW_*` occurrences in `src/main` are the persona **seed** in `UtilRestController` —
provisioning metadata, not enforcement — and `doesUserHaveAccess` has 8 call sites, none mobile. So `develop`
can only ever produce the **pre-fix** half of AC-31. M23 (a) and (c) are not merely unrun on `develop`; they are
**unrunnable**, because nothing emits a denial or the header.

**The sweep.** As `sbtest` (`MOBILE_UI_LOG_IN` + `WEB_UI_LOG_IN`, **zero** `MOBILE_UI_VIEW_*`), all 35 GET
endpoints across all 11 gated controllers:

| Status | Count | What it means |
|---|---|---|
| `200` | 25 | handler ran, returned data |
| `404` | 6 | **all business 404s** (`"title":"Entity Not Found"` ProblemDetail), not Spring's no-handler shape — so every path was correctly mapped |
| `400` | 2 | handler ran, rejected the nonsense input |
| `500` | 2 | handler ran, threw |
| **`401` / `403`** | **0** | **no access decision was made anywhere** |

**Every non-200 is a business outcome of handler execution, not an authorization block.** Live data returned to
a user with no mobile view function: `/v3/cycleCountLos/orderList` **21,260 bytes** of cycle-count orders,
`/v3/replenish/clientList` **11,431 bytes** of clients, `/v3/truckLoading/orderList` **5,878 bytes** of BOL
names, `/v3/transferOrder/orderList` live transfer orders with `customerOrderId`s, `/v3/cancellation/list` live
customer order numbers, `/v3/picking/pickTimeOutValue` → `30`.

**Method note — why this was safe.** Several of these GETs look mutating by name (`releasePickingOrder`,
`requestLocation`, the `scan*` / `check*` family), and this codebase has form there: SBDEV-2984 documents
`GET /v3/user/delete/{userId}`. So every path variable was a **non-existent id** (`999999999`) or a **nonsense
scan input** (`ZZ-NOMATCH-ZZ`), letting a mutating handler run its authorization and lookup and then find
nothing to act on. The disclosure evidence therefore comes entirely from the parameterless list endpoints.
**The 32 mutating endpoints were deliberately NOT probed** — their posture is identical by construction (the
`/v3/**` `wms_user` floor is the only gate on the class), but this baseline does not claim to have measured them,
and §5.1-P7's rollout reasoning should not lean on it as if it had.

⚠️ **Caveat on provenance.** The build under test was an already-running `StartApplication` launched from
`v2/wms2-api/target/classes` (the main checkout on `develop`), not from this ticket's worktree. Given the grep
table above shows the mechanism absent from `develop` entirely, a 200 proves the bypass regardless of which
`develop`-era build served it — but the run is not pinned to a commit, so re-capture against the worktree if
this baseline is ever cited as a before/after pair.

#### 14.11.a The endpoint count still does not converge — and now half of it is execution-verified

Independent extraction gives **35 GET + 32 mutating = 67**, against §0.A's authoritative **66**. All 35 GET
paths returned a mapped handler (zero no-handler 404s), so **the GET half is now verified by execution**, not by
grep. The disagreement therefore sits in the mutating half, or in `PickingController` specifically — which is
the exact controller §0.A blames for the earlier rejected figure of 67.

This is not an argument that 67 is right: a grep for `@GetMapping` would miss a method-level `@RequestMapping`
and would happily count a commented-out annotation. It is an argument that **four independent attempts have now
produced 77, 67, 66 and 67**, and that §5.1-P4 is load-bearing rather than procedural: **build the golden map
from reflection and treat every number in this document, including §0.A's, as commentary.** Until reflection
runs, `66` should be read as unconfirmed.

#### 14.11.b New risk found by the sweep — the denial's response shape is not the shape these endpoints use

The `scan*` endpoints answer failure with **HTTP 200 carrying an error envelope**, e.g. `scanPallet` →
`200 {"errors":[{"field":"Runtime Error","message":"No entity U..."}]}`. The interceptor will instead answer
**403 + `ProblemDetail`** (§3.1-A2 step 6). Those are two different contracts on the same screens, so A7's
"the typed denial message renders" cannot be assumed from the fact that these pages already display errors —
the mobile UI's handler for a 200-with-`errors` payload is not necessarily the one that fires for a 403 body.
Recorded as **R15**.

#### 14.11.c Out of scope, found in passing — two reachable 500s

`GET /v3/replenish/checkSource/{id}/{input}` and `checkDestination/{id}/{input}` return **500** on a
non-existent id, while `checkAmount/{id}/{input}` on the same controller correctly returns **400**. Inconsistent
input validation, unrelated to this plan, reachable today by any authenticated `wms_user`. Not fixed here and
not in scope; **filed as [SBDEV-3016](https://app.clickup.com/t/868kufded)**, with the sequencing constraint recorded there — it touches a file this plan annotates, so it lands *after* 2968 or gets coordinated. Kept out of scope here so it is not silently inherited by whoever touches `ReplenishController`
for C1's request/process split.

---

### 14.12 P3 closed — the bidirectional inventory, re-derived (2026-08-20)

Method: extract **every** string literal beginning with `/` from both UIs' `store|pages|components|plugins|middleware|layouts|util|mixins` trees on `origin/develop`, normalise `${…}` → `{}`, and keep those whose first segment matches one of the **127 API path prefixes derived from the server** (`@RequestMapping` on `@RestController`s plus `@RepositoryRestResource(path=…)`). 90 mobile paths, 289 web paths.

**⚠️ Read this before trusting any earlier inventory, including mine.** My first pass used the obvious regex — a path as the literal first argument of an `$axios` call — and it **missed `/replenishOrder/detailView`**, which `pages/replenish.vue:147` assigns to a variable first (`let url = '/replenishOrder/detailView?…'`). §0.B's own fifth row is what exposed the gap. The narrow regex found 80 mobile / 283 web; the broad one finds 90 / 289. **This is the third time an inventory on this ticket has been wrong, and the second time in the same direction** — the lesson is not "grep harder" but that any `$axios`-shaped pattern is structurally blind to indirection. The numbers below come from the broad sweep.

#### Direction 1 — does gating the 11 controllers break a web screen? **No. Confirmed.**

**Zero** web-UI calls into any of the eleven in-scope prefixes (`lookup`, `putaway`, `moveUnitload`, `moveStock`, `picking`, `palletizing`, `truckLoading`, `cycleCountLos`, `replenish`, `transferOrder`, `cancellation`), across all 289 web paths. §0.A is safe to gate. This was the plan's belief; it is now measured with a method that catches indirection.

#### 🔴 14.12.c Correction to Direction 2 — it is **17+**, and neither extractor was sound (2026-08-20)

**`/stockUnit/isUnitLoadIdValid/{labelId}` belongs on the list and both of my sweeps lost it.** The narrow
regex found it; the broad one did not, because the mobile literal embeds `encodeURIComponent(labelId)` and the
parentheses fell outside my character class. The broad regex found `/replenishOrder/detailView`, which the narrow
one lost to variable indirection. **The union of the two is larger than either**, which means neither is a proof
of completeness and the figure below should be read as **17 or more**, not sixteen.

It is a shared endpoint — mobile `store/moveStock.js:178`, web `store/handlingUnits/stockUnits.js:212` — and it
matters beyond bookkeeping: **SBDEV-2967 row 0.B.16 had targeted it at `WEB_UI_VIEW_STOCK_UNIT`**, which would
have 403'd Move Stock for every mobile-only operator. Corrected in 2967 on 2026-08-20 along with the answer to
its note 3 (mobile does **not** call `bulkTransferStock`, so that one is web-only and may carry a plain gate).

**The methodological conclusion — this is the fourth wrong inventory on this ticket and the second of mine.**
Client-side grepping cannot establish completeness here: every pattern is blind to some form of indirection
(variable assignment, string concatenation, a function call inside a template). The sound method is the one
§5.1-P4 already prescribes for the golden map, applied to P3 as well: **enumerate from the server** — reflect
over the deployed handler surface — **and then verify call sites per endpoint**, rather than enumerating from the
client and hoping the pattern caught everything. Treat §14.12's tables as a floor.

#### Direction 2 — 🔴 §0.B is incomplete. It lists **5** shared endpoints; the mobile UI calls **16** outside the guarded set.

All five §0.B rows are confirmed still live. Eleven more were not enumerated:

| Endpoint | Sharing | Note |
|---|---|---|
| `/client/search/findByClNr` | web ×8 | **Spring Data REST** |
| `/fixLocationAssignment/search/findByAssignedlocationId` | **MOBILE-ONLY** | **Spring Data REST** — see below |
| `/section`, `/section/search/findByName` | web ×5 | second is **SDR** |
| `/stockunit/search/getAmountAvailable` | web ×1 | **SDR** — note lowercase `stockunit`, the repository path, distinct from the `/stockUnit` *controller* |
| `/unitLoad/search/findByItemForReplenish` | web ×7 | **SDR** |
| `/system/mobileUiUrl`, `/system/syncAdminWithKeycloak/{}` | web ×5 | ⚠️ **RETRACTED 2026-08-20 — I flagged `syncAdminWithKeycloak` as privileged and adjacent to SBDEV-2984, and I was wrong.** The endpoint **does not exist**: `SystemController` has exactly two mappings (`/mobileUiUrl`, `/searchSystemByGroupname/{groupName}`) and the name appears nowhere in `src/main`. The mobile store action at `store/index.js:64` also has **zero dispatchers**. It is dead client code pointed at a route that would 404 — **no ticket filed.** The only latent nuisance: if anyone wires it up, the `catch` reports *"network or server issue"* for what is really a missing route |
| `/tenant/health` | web ×1 | diagnostic |
| `/user/getAllRoles/{}`, `/user/isWmsUser/{}` | web ×19 | `getAllRoles` already noted in §10.4 |

*(`/v3` also matched, from `VersionBadge.vue` and `initTenantAuth.client.js` — a baseURL literal, extractor noise, not an endpoint.)*

**R12's residual is therefore understated** and is corrected in the risk table: a user denied a tile retains not one shared capability but **sixteen**.

#### 🔴 14.12.a The mechanism has a structural blind spot: Spring Data REST

**FIVE of the sixteen are SDR `/search/…` endpoints, and `@RequiresFunction` cannot cover any of them — but only ONE of the five is actionable.** (Corrected 2026-08-20: an earlier revision of this section said six. Recount: `client`, `fixLocationAssignment`, `section`, `stockunit`, `unitLoad` = five. **Four are shared with the web UI, so gating them would 403 a web screen — they are §0.B/R12 material by the plan's own logic, not new work.** The actionable surface is the single mobile-only one.) The interceptor resolves the annotation on the **declaring class of the handler**; an SDR request is handled by Spring Data REST's own `RepositorySearchController`, which is not in `controller/mobile/` and carries no annotation, so it falls through to *allow*. The A8 startup assertion won't flag it either — it audits annotation coverage over the mobile package, and these handlers are not in it.

**This is not hypothetical.** `/fixLocationAssignment/search/findByAssignedlocationId` is **mobile-only**, called from `components/replenish/shared/OrderHeaderBlock.vue` — *inside the Replenish workflow this plan gates* — and `FixLocationAssignmentRepository` exposes **eight further `@RestResource` searches on the same path**, all equally reachable. So an operator denied `MOBILE_UI_VIEW_REPLENISHMENT` is blocked from `/v3/replenish/**` and still queries the fixed-location data that workflow is built on.

**This is the SBDEV-1666 landmine class, third occurrence.** 1666: a service-layer sysprop branch cannot guard `@RestResource` queries. SBDEV-2870 §10.2: the route was gated but the *capability* stayed open via `PATCH /v3/stockunit/{id}`. Now: an annotation-on-controller mechanism cannot guard SDR at all. The recurring shape is **a guard keyed on one dispatch path while a second dispatch path reaches the same data.**

#### 14.12.b The five SDR searches — options, and the decision (2026-08-20)

**Scope first: the problem is one endpoint, not five.** Four of the five (`client`, `section`, `stockunit`,
`unitLoad`) are **shared with the web UI**, so gating them would 403 a web screen — by §0.B's own logic they were
never candidates, and they are **R12 material, not new work**. The actionable surface is exactly one:
`/fixLocationAssignment/search/findByAssignedlocationId`, **mobile-only**, called from
`components/replenish/shared/OrderHeaderBlock.vue:92`, which fetches **a single scalar** (`upperbound` for a
destination location) and defensively parses three possible response shapes — itself a sign SDR is a poor fit
for this call.

| | Option | Closes the hole? | Cost | Keeps compile-time safety? |
|---|---|---|---|---|
| **A** | Accept as a stated residual + follow-up ticket | No | Zero | n/a |
| **B** | **Path-keyed** rule beside the annotation-keyed one | Yes — and the whole class | Medium | **No** — a repository path rename silently disables it |
| **C** | Move the query behind a gated mobile controller | Yes, for this endpoint | Low | Yes |
| **D** | `@RestResource(exported = false)` on that one search | Yes — **removes** rather than guards | Very low | Yes |
| **E** | `@PreAuthorize` on repository methods | Partly | Low | **No** — reintroduces RC-2 |

**E is rejected on the plan's founding argument.** Spring Security can secure repository methods, but
`standaloneSetup` installs no method-security advisor and the `@SpringBootTest` lane is down (SBDEV-2217) —
exactly the configuration in which SBDEV-2863 shipped a broken SpEL expression for nine months. That asymmetry
is the whole basis of §3.1's design; using `@PreAuthorize` here would undo it.

**B is the only option that closes the general class.** The interceptor already *sees* SDR requests; it is the
annotation lookup that comes back empty. A path-keyed map would work, and the lost "rename is a compile error"
property is recoverable — at startup, enumerate SDR's exposed search paths from `ResourceMappings` and assert
every path-keyed rule resolves to a live handler, restoring fail-fast. But it is new mechanism for one known
endpoint, in a plan that has already absorbed one re-scope.

> ✅ **DECIDED 2026-08-20 by Nam Park: take D + C, with A for the four shared searches. B is deferred to its own
> ticket.**

**Why D + C.** Un-export the one search and serve the scalar from a `@RequiresFunction`-annotated
`ReplenishController` endpoint. This **removes the capability rather than guarding it**, needs no new mechanism,
keeps the compile-safety property, and simplifies the client from three-shape defensive parsing to one scalar.

**It is an established pattern in this repo, not an invention.** `@RestResource(exported = false)` is already
used across `NoDeletePagingAndSortingRepository`, `ReadOnlyPagingAndSortingRepository`, `AdviceRepository`
(3 searches) and `BillofladingRepository` — and twice applied deliberately as this exact fix: `2c5cbc2`
*"SBDEV-2643: stop exporting the new search query over HAL (A4 review fixes)"* and `553bbb1`
*"fix(receiving): stop exporting advice notice searches over HAL [SBDEV-2781]"*. Both were review-driven
closures of the same shape.

⚠️ **Un-export ONLY `findByAssignedlocationId`.** `FixLocationAssignmentRepository` exposes eight further
`@RestResource` searches on the same path (`findByAssignedunitloadId`, `findByItemdataId`, `findDistinctByState`,
`getRefillFixedLocations`, `getFixedLocationAndItemDataIds`, `getDetailView`, …). The P3 sweep established only
that **this one** is mobile-only; the others may have web callers, and a repository-level un-export would break
them. Verify per search before touching any other.

⚠️ **A still carries an obligation.** The four shared SDR searches, and R12's sixteen generally, must be named in
the ticket's closing note — "mobile workflows are now function-gated" would otherwise be read as covering them.

---

### 14.13 SBDEV-3005 landed under this plan — reconciliation (2026-08-20)

`origin/develop` moved `e7b3b88` → **`60aef02`** while this plan sat at the gate, and one of the merges touches
this plan's foundation: **SBDEV-3005, "fix reversed role↔function composite key and make the replace atomic."**
It changed `AccessService.java` and `WmsConstants.java` — `AccessService` being the exact class §5.2 step 2
extends.

**What it actually fixed** — two swapped-argument bugs in the join-table plumbing:

```java
- userFunctionService.addRoleToFunction(function.getId(), connector_role.getId());
+ userFunctionService.addRoleToFunction(connector_role.getId(), function.getId());
- userRoleUserFunctionRepository.findByFunctionlistId(role.getId());   // ×2
+ userRoleUserFunctionRepository.findByRolelistId(role.getId());
```

**The alarming reading, and why it is wrong.** Pre-fix writes through `addFunctionToGroup` would have inserted
rows with `rolelist_id` and `functionlist_id` **transposed**. If such rows exist, §3.4 part 2's back-compat grant
("every role holding `MOBILE_UI_VIEW_REPLENISHMENT` also gets `MOBILE_UI_VIEW_REPLENISH_REQUEST`") would read the
correct join, miss the transposed rows, and **silently under-grant** — breaking exactly the "C1's split removes
nobody's access" guarantee. Measured on WineCo dev instead of assumed:

| Probe | Result |
|---|---|
| Rows whose `rolelist_id` is a valid *function* id **and** `functionlist_id` a valid *role* id | **0** |
| Ids present in **both** `mywms_role` and `mywms_function` | **0** — the two id spaces do not overlap |
| Total grant rows | 300 |
| Roles holding `MOBILE_UI_VIEW_REPLENISHMENT` | **3** — matches §0.A |

Because FKs exist on both columns (`fkby47…` → `mywms_role`, `fkgewu…` → `mywms_function`) **and the id spaces
are disjoint**, a transposed insert could never have committed — it would have raised an FK violation. **The 3005
bug failed loudly, not silently**, so no corrupt grants exist to miss and §3.4 part 2 is safe as written.

⚠️ **One tenant measured.** Both id spaces draw from `seqentities`, and per `wms2-seqentities-dual-island-id-space`
migrated databases have irregular id ranges — so the disjointness argument is per-tenant, not universal. §5.1-P1's
audit is the right place to confirm it everywhere; add the two probes above to `audit-access-invariants.sql`
(checklist step 7) so the question is answered per tenant rather than re-litigated.

**Residual action:** none blocking. Re-read `AccessService` before step 2 (the "5 call sites" figure was already
stale at 8), and re-fast-forward both worktrees — `wms2-api` `e7b3b88` → `60aef02`, `wms2-mobile-ui` `8e623b8` →
`7f83d55`, both clean since neither branch holds a commit. **V2.2.18 re-confirmed free** across all remotes;
V2.2.17 is now merged on develop, so §14.8's collision is visible without a sweep.

---

### 14.10a R6b settled — the experiment, and what it changes (2026-08-20)

§14.10 raised the challenge and named §14.9 Phase A step 7 as the settling test. The browser form of that step
proved unnecessary: R6b's claim is pure control flow inside `plugins/axios.js`, so it was settled with a 5-case
Jest probe against the **real** plugin (byte-identical between the worktree base and the checkout it ran in),
using the existing `axios-auth-timing.spec.js` harness that already mocks `axios-retry` to capture the retry
config.

| Case | Setup | Result |
|---|---|---|
| 1 | authenticated, **valid token** (`updateToken` → `false`) | `retryCondition` → **false**, **0 logouts, 0 toasts** |
| 2 | token **was** refreshed (`→ true`) | retries |
| 3 | refresh **throws** | logout — the only reachable logout, and a 403 does not cause it |
| 4 | `onMaxRetryTimesExceeded` invoked directly | toast + `logout()` — so the logout needs retries **exhausted** |
| 5 | `x-authz-denied` present **today** | **still retries** → P10 genuinely unimplemented, and its test will go red→green |
| chain | refresh-once-then-fresh | **2 attempts total, 0 logouts** |

**The one assumption the mock encoded is now a source fact.** `keycloak-js/lib/keycloak.js:1474-1481`:
`refreshToken` is set only when `!tokenParsed || isTokenExpired(minValidity)`, then `if (!refreshToken) return
false`. So `updateToken(5)` returning `false` for a healthy token is documented behaviour, not a stipulation.

**Consequences, all applied:** R6b **High → Low** with the failure mode restated from *"logs the operator out"* to
*"retries at most once and reports nothing useful"*; **P10 de-blocked** but kept as work; **M23 assertion (b)
relocated to Jest**, leaving M23 with only the two assertions that need a browser.

**What the probe cost, for calibration.** Nothing was mocked that mattered, no service was restarted, and the
whole thing was two throwaway spec files deleted afterwards — against a 🔴 High that had survived a review pass
and was about to gate a ship decision. The lesson worth keeping is §14.10's own: this plan's history is a list of
confident readings the runtime falsified, and the cheapest possible runtime check beat another round of reading.

---

### 14.14 Never key an assertion on a handler method name (2026-08-20)

Found while implementing US-04/US-05: **a handler's method name is not a reliable identifier for its endpoint**,
and two separate near-misses on this ticket pair have now turned on that fact.

**Measured across the 11 guarded controllers:**

| | |
|---|---|
| Duplicated handler method names | **6** — `orderList` in **four** controllers (`CycleCountLos`, `Replenish`, `TransferOrder`, `TruckLoading`), plus `requestLocation`, `scanPallet`, `selectSource`, `updateOrder`, `processScanUnitLoad` |
| Mappings whose method name ≠ first path segment | **12 of 66** (~18%) |
| Mangled identifiers | **1** — `PickingController.requpickingOrdersestLocation`, pre-existing on develop, now [SBDEV-3016](https://app.clickup.com/t/868kufded) Fix 2 |

**The two near-misses:**

1. **SBDEV-2967 row 0.B.16.** `GET /v3/stockUnit/isUnitLoadIdValid/{labelId}` is served by a method literally
   *named* `getStorageLocationsForStockMovement` (a copy-paste leftover). 2967's own note 4 records it. An
   implementer excluding "the shared method" **by name** would have excluded `/storageLocationsForStockMovement`
   and left `isUnitLoadIdValid` gated — 403-ing mobile Move Stock for every mobile-only operator.
2. **This plan's own gate test.** `PutawayController` serves `GET /scanPallet/{input}` from a method named
   `requestLocation()` — the same name `ReplenishController` uses for a genuinely different endpoint, and the
   one this plan gates on `MOBILE_UI_VIEW_REPLENISH_REQUEST`. A method-name-keyed assertion would have
   conflated them silently.

**The rule.** Never key an assertion, a verify-script row, or a §0 table row on a handler **method name**. Key on
**`(declaring class, path)`** or on the **annotation**. This is §5.1-P4's build-from-reflection rule generalised
past the golden map: the method name is documentation, the mapping is the contract.

**What is deliberately NOT proposed.** Renaming the 12 mismatches. They are mostly not defects — a handler's
name and its URL are allowed to differ, and several read *better* than their path (`listPendingReversals()` over
`/list`). Renaming them inside an authorization diff would bury the security change under noise a reviewer must
take on trust, and would collide with SBDEV-3016, which already touches `ReplenishController`. The single
mangled name is folded into [SBDEV-3016](https://app.clickup.com/t/868kufded) as Fix 2 for the same reason.

**Why the harm is real despite being invisible at runtime.** Spring routes on the mapping, so a duplicated or
mismatched method name breaks nothing when the app runs. The entire cost falls on tooling and on humans — verify
rows, plan tables, review greps, `-Dtest=` filters — which is exactly the population that cannot see its own
mistake. A wrong endpoint in a gating table produces a 403 in production, not a red build.

---

### 14.15 Implementation measured, and the mutation pass that graded its own tests (2026-08-20)

Checklist steps 1–15 are **written** in both worktrees and **uncommitted** (0 commits on either branch; 34 dirty
paths in `wms2-api`, 12 in `wms2-mobile-ui`). This section records what was measured, because "116 pass" was
the least interesting number produced and one of the four measurements below invalidated itself.

**Verify script — `119 pass, 0 fail, 2 skip`** on the shadow root, against `18/95/7` for the same script on the
plain monorepo root (the wiring control: the shadow root is grading the worktrees, the mono root the stale
checkouts). Two rows had to be corrected to get there, and they were **not** code defects:

| Row | Was | Now |
|---|---|---|
| `F3` | `file_contains 'accessAudit' AdminController.java` | keyed on the **path literal** `"/accessAudit"` in `AdminActionController.java` |
| `F4` | 4-line window above `accessAudit` in `AdminController.java` | 3-line window above the **mapping** in `AdminActionController.java` |
| `F5` | — | **new**: the endpoint is *not* declared on the `AdminController` base `[pre-passes]` |

Both original rows were permanently red against a correct implementation — the [`verify rows naming an undefined
thing read as honest FAILs`] class, one layer up: the row named a real file, just not the right one. §3.5-E2 is
what was actually wrong, and it is now corrected. `F5` exists because the *other* half of that decision — keeping
the endpoint off the 43-subclass base — had nothing watching it, and a future "tidy the admin endpoints" pass
would multiply the alias count by 43 with every other row still green. Note `F3`/`F4` are keyed on the **path**,
not the handler method name, per §14.14.

**Suites.** `wms2-api`: **5274 tests, 2 failures** — `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`
(6 violations, all in files this branch does not touch) and
`MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`, i.e. **exactly the known `develop`
baseline, zero new failures**. Gate classes: `FunctionGuardArchTest` 21, `FunctionGuardInterceptorUnitTest` 11,
`FunctionGuardStartupAssertionUnitTest` 4, `FunctionGuardMockMvcUnitTest` 6, `AccessAuditServiceUnitTest` 5,
`SecurityConfigurationTest` 9 — all green. `wms2-mobile-ui`: **15 suites, 170 tests, all passing**, including all
five new specs. (`mvn test` mutated `src/test/resources/archunit_store/5fb3fee0-…` as always; reverted.)

#### The mutation pass — 15 of 16 mutants killed, and the one that lived

Sixteen mutants were applied to **production** code, one at a time, each followed by a **recovery run** that had
to return to green before the next was applied. Two **null mutants** (comment-only edits) were included as the
harness's own self-test and both correctly SURVIVED — without them this table would be unfalsifiable.

| # | Mutant | Verdict |
|---|---|---|
| M0 | null mutant (comment) | SURVIVED ✅ *(expected)* |
| **M1** | **fail-OPEN: unannotated handler on a GUARDED controller is allowed** | **SURVIVED ❌** |
| M2 | resolve on `getBeanType()`, not the declaring class | killed — `FunctionGuardInterceptorUnitTest` |
| M3 | stop emitting `X-Authz-Denied` | killed — `FunctionGuardInterceptorUnitTest` |
| M4 | gate allows every decision | killed — `FunctionGuardInterceptorUnitTest`, `…MockMvcUnitTest` |
| M5 | strip `@RequiresFunction` from `MoveStockController` | killed — `FunctionGuardArchTest`, `…MockMvcUnitTest` |
| M6 | annotate the **shared** `StockUnitController` | killed — `FunctionGuardArchTest`, `…InterceptorUnitTest` |
| M7 | startup assertion never reports a violation | killed — `FunctionGuardStartupAssertionUnitTest` |
| M8 | drop `AUTHZ_DENIED_HEADER` from the CORS exposed list | killed — `SecurityConfigurationTest` |
| N0 | null mutant (comment) | SURVIVED ✅ *(expected)* |
| N1 | route guard fails open | killed — `requireFunction.spec.js` |
| N2 | guard decides without awaiting the roles fetch | killed — `requireFunction.spec.js` |
| N3 | a roles-fetch **failure** treated as a denial | killed — `requireFunction.spec.js` |
| N4 | redirect drops the `workflow`/`fn` params | killed — `requireFunction.spec.js` |
| N5 | axios retries an authz 403 anyway | killed — `axios.spec.js` |
| N6 | denial message never rendered | killed — `authzDenialRendering.spec.js` |
| N7 | axios keys on status alone, not the header | killed — `axios.spec.js` |

🔴 **M1 is a real coverage hole in the plan's own headline invariant.** §3.1-A8 and the interceptor's javadoc both
state that a handler whose declaring class is in `GUARDED` but carries no annotation is **denied**; flipping that
`return false` to `return true` leaves **100 / 100 targeted tests green**. None of the 11 interceptor tests
reaches the branch, and none can: all eleven controllers carry a class-level annotation, so
`AnnotationUtils.findAnnotation(declaring, …)` always resolves and the branch is **unreachable by construction**
today. What actually defends the invariant is the *other* two layers — the boot assertion (killed M7) and
ArchUnit (killed M5) — so the system is defended while the mechanism the javadoc advertises is not.

**The fix is already written down in this codebase.** `FunctionGuardStartupAssertion` takes its `guarded` set as
a **parameter** with a javadoc saying exactly why — "so the violation branch is testable… a test keyed on the
production set could only ever exercise the compliant path while claiming to prove the failure." The interceptor
holds `GUARDED` as a static constant and has precisely that problem. Give it the same seam (package-private
constructor overload or injected set), then assert `403` + `MISSING_FUNCTION` for a guarded-but-unannotated
handler. **Not done here** — it is a production-design change to a plan under review, so it is reported rather
than improvised.

⚠️ **The first mutation harness produced eight false `SURVIVED` verdicts and they read as credible.** It restored
each file with `shutil.move`, which **preserves the original mtime**, so Maven's staleness check never recompiled
the original back and mutant bytecode accumulated in `target/classes` across the whole run — the eighth mutant
was graded against a tree carrying all seven earlier ones. The tell was in the output all along: the failure
counts climbed monotonically (0 → 5 → 1 → 9 → 12 → 14 → 15 → 17) while every verdict printed "no test caught
it", which is self-contradictory. **A restore is not a restore unless the mtime moves**, and the recovery-run
check that would have caught it on mutant #1 was absent from the first harness. Generalising §8.7: red-only
baselining proves nothing, a correct shadow catches false-REDs, near-miss wrong shadows catch false-GREENs — and
a **null mutant plus a recovery run** is what catches a broken *grader*.

**Still owed, unchanged by any of the above:** P1/P2 (the per-tenant audit — `db/audit-access-invariants.sql` now
exists in the worktree, so it is runnable for the first time), P4's reflection golden map as a gate on the §0.A
number, P6's re-sweep at PR time, P7/P8, M23's browser probe (no test in either repo can prove CORS header
exposure), and an AC-31 **post-fix** re-measurement against the §14.11 baseline. Nothing is committed.

---

### 14.16 P4 and P6 closed — the surface, built from reflection (2026-08-20)

**P6 — ANSWERED, and it stays perishable. `V2.2.18` is free.** Swept three ways, because two of them alone
would have missed a claimant: **all remote refs** (`git for-each-ref refs/remotes` × `ls-tree` over
`db/migration`), **all local refs** (a sibling ticket's unpushed branch can claim a version invisibly — this
plan's own V2.2.18 is exactly that shape today), and **every on-disk worktree** including uncommitted files.
Result: the highest `V2.2.*` anywhere except this branch is **V2.2.17**, and V2.2.18/19 are unclaimed.

⚠️ Two things moved since §14.8 wrote this row: **`origin/develop` now carries V2.2.17** (SBDEV-2994 merged),
not V2.2.16 as recorded — so this plan's V2.2.18 is now simply the next number rather than a leapfrog. And
SBDEV-3003/3005/3011 all sit *at* V2.2.17 without adding a file. **Re-run at PR time regardless**: the answer
was already invalidated once between 08-17 and 08-19, and the sweep is thirty seconds.

**P4 — CLOSED. The reflected surface is 67 handlers / 67 URL mappings**, captured at
`9-System/evidence/SBDEV-2968-p4-reflected-golden-map.txt`.

| | |
|---|---|
| Guarded controllers | 11 |
| Own mapped handlers | **67** |
| Own URL mappings | **67** — every handler declares exactly one path, so the two counts coincide *here* and must not be assumed to in general (§0.C found endpoints carrying ~11 URLs each) |
| `AdminController` mapped methods | **9**, carrying no `@RequiresFunction` → 11 × 9 = **99 inherited alias URLs**, all resolving to `AdminController` and therefore passing through untouched |
| Distinct functions referenced | 12 |

**§0.A's withdrawn "66" resolves to 67**, ending the 77 → 67 → 66 → 67 sequence. The count is deliberately
**not** asserted by any test — `FunctionGuardArchTest`'s golden-map row says so in its own display name — and
that is the right call: a test keyed on the number would encode whichever count was current when it was
written. The number is documentation; the reflected map is the contract.

**The A5 comparison passes.** All 11 class-level functions match §3.1-A5 exactly, and the method-level
overrides are exactly the three A5/A5.1 predict: `LookupController#locationByLocationName` →
`{INFO, REPLENISHMENT}`, and `ReplenishController#requestAmount` / `#requestLocation` → `REPLENISH_REQUEST`
alone. Nothing else on the guarded surface carries a method-level annotation.

Three corrections and one methodological note came out of running it:

1. 🔴 **§3.1-A5.1's table is one row short.** `GET /fixedLocationUpperBound/{locationId}` — added by
   checklist step 13 as the gated replacement for the un-exported SDR search — makes `ReplenishController`
   **12** handlers, so A5.1's closing line "2 request-side, 9 process-side — 11 total" is now **2 + 10 = 12**.
   Harmless today, but it is the sort of stale count that reads as drift to the next person.
2. ⚠️ **`CycleCountLosController#processScanUnitLoad` is TWO handlers**, not one: `GET
   /scanSingleUnitLoad/{input}` and `POST /processScanUnitLoad`, same method name, different verb and path.
   Both inherit the class-level function so there is no authorization consequence — but it is §14.14 living
   inside the guarded set, and any name-keyed assertion or `-Dtest=` filter silently conflates them.
3. The reflection run independently re-confirmed §14.14's examples on live code:
   `PutawayController#requestLocation` serves `GET /scanPallet/{input}`, `ReplenishController#orderList`
   serves `/clientOrderList/{clientNumber}`, `PalletizingController#scanUnitLoad` serves
   `/scanParcel/{input}`, and the mangled `requpickingOrdersestLocation` serves `GET /pickingOrders/{input}`.
4. ⚠️ **Methodological, and it nearly produced a wrong answer.** The first dump used
   `AnnotationUtils.findAnnotation(m, RequestMapping.class)` and printed `(no path)` for all 67 handlers:
   `@GetMapping` is *meta-annotated* with `@RequestMapping`, and plain `findAnnotation` returns the
   meta-annotation with its own empty attribute defaults. It looked like it had worked — 67 lines of output,
   one per handler. **`AnnotatedElementUtils.findMergedAnnotation` is required** to see the real
   path/verb. P4 exists to replace a hand-written table with reflected truth, so a reflection helper that
   silently returns defaults is the one failure mode that defeats the whole prerequisite.

**One test strengthened while verifying the map (committed separately).** The golden map pinned ten
controllers to `WmsConstants.FunctionEnum` constants and `OrderCancellationController` to a bare string
literal. Both forms catch a wire-value change, so this was measured rather than assumed: mutating
`MOBILE_UI_VIEW_CANCELLATION`'s value to `…_MUTANT` fails **1** assertion with the literal
(`everyRequiresFunctionValueIsADeclaredFunctionEnumConstant`) and **2** with the constant — the golden-map
row becomes a second, independent detector. The constant form is therefore strictly stronger and is now in
place; verify still `119 pass / 0 fail / 2 skip`.

**Remaining after this:** P1/P2 (per-tenant audit), P7/P8 (deploy order + rollback runbook into the ticket),
M23's browser probe, the AC-31 post-fix re-measurement, and the M1 interceptor seam from §14.15.

---

### 14.17 P7 and P8 answered — and the deploy order was wrong (2026-08-20)

Both were "write it into the ticket" rows, so the deliverable is
[a ticket comment](https://app.clickup.com/t/868krr3rw). Grounding them changed one of the two.

#### 🔴 P7: "mobile-first is strictly safe" is false, and the cost is measured

The claim rested on *the client guard denies nothing the server would allow*. That holds for ten of the eleven
workflows and fails for the eleventh: `util/menuCatalog.js:80` gates `/replenish-request` on
**`MOBILE_UI_VIEW_REPLENISH_REQUEST`**, and that function is **created by `V2.2.18`, which ships with the API**.
Deploy mobile first and, for the length of the window, the client requires a function that exists nowhere.

Measured, not reasoned — `SELECT` on two live tenants:

| Function | Hydra UAT | WineCo dev |
|---|---|---|
| `MOBILE_UI_VIEW_REPLENISHMENT` | 2 roles | 3 roles |
| `MOBILE_UI_VIEW_CANCELLATION` | 3 roles | 3 roles |
| `WEB_UI_VIEW_TRANSFER_ORDER` | 1 role | 1 role |
| **`MOBILE_UI_VIEW_REPLENISH_REQUEST`** | **row absent** | **row absent** |

Blast radius on Hydra UAT: **15 of 19 users** hold `MOBILE_UI_VIEW_REPLENISHMENT` through either grant path, so
15 operators lose Replenish Request — the tile vanishes *and* the deep link redirects to `/not-authorized`.

**The order is therefore three steps: apply `V2.2.18` → deploy `wms2-mobile-ui` → deploy `wms2-api`.** Step 1 is
safe precisely because the seed is INSERT-only and nothing reads those functions yet, and because every statement
is `NOT EXISTS`-guarded the API's own Flyway run re-executes it as a no-op (§14.8's P5 finding earning its keep a
second time). Mobile-before-API still holds between steps 2 and 3 for the original reason.

Alternative if a separate seed step is operationally unacceptable: let the client accept **either** function for
that route and leave the split enforced server-side only, where it is actually a boundary. One line in
`menuCatalog.js`, slightly weaker client-side C1 — flagged on the ticket as needing a decision, not taken here.

Worth noting *why* this was invisible: P7 and the seed were correct **separately**. The defect only exists in the
ordering between two repos, which is exactly the seam no test in either repo covers — and the plan's own §12
deploy-order reasoning was written before C1's split introduced a function that did not yet exist.

Also, a small drift found in passing: `V2.2.18`'s header comment says `MOBILE_UI_VIEW_CANCELLATION` is held by
"3 roles on WineCo dev and 1 on Hydra UAT". Hydra UAT now reads **3**, not 1. The seed is `NOT EXISTS`-guarded so
nothing breaks; the comment is just stale.

#### P8: the rollback runbook, with one live caveat

Primary rollback is one redeploy: revert `WebConfig.addInterceptors` — the sole thing that puts the interceptor in
the request chain — and every `@RequiresFunction` becomes inert metadata. Safe to leave behind: the annotations,
`Authority.AUTHZ_DENIED_HEADER` + its CORS entry, the audit endpoint, and `FunctionGuardStartupAssertion` (it
asserts only that annotations are *present*, so it still passes and cannot block boot). **`V2.2.18` must not be
reverted** — Flyway cannot un-apply it and the rows are inert once the gate is gone.

⚠️ **The "faster remedy" the plan promised is unavailable in production.** An administrator grant through User
Management posts to `POST /v3/userRole/saveRoleFunctions`, which is the endpoint **SBDEV-3005** fixed — and
`origin/main`, which prd tracks, is **29 commits behind and does not contain `f4e78c5`**. `origin/release` and
`origin/develop` both do. So on dev/UAT the fast remedy works as written; **in prd it is the redeploy or a direct
SQL grant** until 3005 ships. A rollback plan whose fast path is broken in the only environment that matters is
worth catching before the deploy rather than during one.

Diagnosis is also on the ticket: 403 + `ProblemDetail` naming `requiredFunction`/`reason`, the `X-Authz-Denied`
header, `wms2.authz.denied`/`.allowed` metrics, and `reason=USER_NOT_PROVISIONED` meaning a missing `mywms_user`
row — a provisioning defect that granting a function will not fix.

**Remaining: P1/P2, M23's browser probe, the AC-31 post-fix re-measurement, and §14.15's M1 interceptor seam.**

---

### 14.18 P1/P2 — the UAT function surface audited, prd blocked on credentials (2026-08-20)

Evidence: `9-System/evidence/SBDEV-2968-p1-uat-function-audit.txt`.

**The question this answers is sharper than "run the audit SQL".** The reflected surface (§14.16) needs
**12** functions; `V2.2.18` creates only **2** of them. The other **10 must already exist on every tenant**,
because nothing in this change creates them — and a missing row is not a partial failure, it denies that
entire workflow to *every* user on that tenant, fail-closed, from the moment the interceptor registers.

**Tenant list taken from the UAT landlord, not an env file** — 4 active tenant/warehouse pairs. Each
connection's `current_database()`/`current_user` was confirmed **before** querying, which mattered twice:
`wms2-hydra-uat` and `nywh-hydra-uat` are the **same database**, and the prd server reports a database *name*
identical to a UAT one. The authz join tables carry **no schema drift** across the four (note
`mywms_user_mywms_role` is `(user_id, roles_id)`, not `rolelist_id`).

| DB | tenant/wh | users | **missing required rows** | ≥1 mobile view fn | mobile login | in no group | via `super-admin` |
|---|---|---|---|---|---|---|---|
| `wh01_hydra_v2` | hydra/nywh | 19 | `…REPLENISH_REQUEST` | 15 | 15 | 4 | 15 |
| `wh01_shipitez_v2` | shipitez/c1wh | 36 | `…REPLENISH_REQUEST` | 33 | 33 | 3 | 23 |
| `wh02_shipitez_v2` | shipitez/nywh | 11 | `…REPLENISH_REQUEST` | 9 | 9 | 2 | 9 |
| `wh01_om1_v2` | wineco/wsl | 94 | `…REPLENISH_REQUEST` | 46 | 47 | 45 | 35 |

✅ **Exactly one required function is missing, on all four tenants, and it is precisely the one `V2.2.18`
seeds.** The other 11 exist everywhere today. So the answer to "will UAT have every function it needs" is
**yes — after V2.2.18, and only after it**. This also independently re-derives §14.17's finding from the
data side: without the migration, Replenish Request is dead for every user on all four tenants, not just
during a mobile-first window.

Three things the numbers say that a pass/fail audit would have hidden:

1. ⚠️ **`super-admin` is the majority role on three of four tenants** — 15/19, 23/36, 9/11, and 35/94. On
   Hydra UAT a *group* literally named `super-admin` holds 15 of 19 users, which is why every function reads
   an identical "15 users" (reproduced with a second, independent query before being believed, then
   explained rather than assumed). **Consequence for P2: "nobody loses access" here is close to vacuous** —
   it means role separation is barely in use, not that the gate is safe. This is §14.6's WineCo-dev trap in a
   new place: same number, opposite meaning. **Consequence for QA: the gate cannot be demonstrated with a
   typical UAT account**, because a typical UAT account is a super-admin. AC-31 and M23 need one of the
   non-super-admin users, or `sbtest`.
2. **`wh01_om1_v2` has 45 of 94 users in no group at all**, and 1 user — `Z-mariaortiz(archived)` — holds
   `MOBILE_UI_LOG_IN` with **zero** `MOBILE_UI_VIEW_*` functions. After the gate that account reaches the
   mobile app and finds no workflows: the ticket's own adjacent defect #2 ("blank app, no explanation"),
   which this change makes *more* visible rather than less. Not a blocker (P2 exempts unmapped rows) but it
   is the exact population that generates "the app is broken" reports.
3. **`WEB_UI_VIEW_TRANSFER_ORDER` is held by exactly 1 role on every tenant** — `super-admin` — confirming
   the ticket's adjacent defect #1 on live data across all four. Gating `TransferOrderController` on it (D4)
   therefore changes nothing for anyone except deep-linkers, which is the intent.

🔴 **Hydra prd could not be audited, and the blocker is credentials, not access policy.** The `wms2-hydra`
MCP authenticates as **`wh03_om1`** and returns `permission denied for table mywms_function` with **0 visible
tables**; the prd landlord says prd's one active v2 tenant (hydra/nywh, `…:25060/wh01_hydra_v2`) uses app
user **`wh01_hydra_v2_app`**. The same blocker stopped **SBDEV-3011's** prd audit, so this is persistent and
unowned rather than new. **P2's prd requirement therefore remains open and needs either fixed MCP credentials
or an operator running the audit SQL.** Mitigating context: prd tracks `origin/main`, which is **29 commits
behind `develop` and at `V2.2.16`**, so this change is not close to prd — the prd audit gates the eventual
release, not this PR.

**Still owed on P1 as specified:** the **E1-P Keycloak join**. Everything above is the raw DB side; the
intersection with `GET /v3/user/findUsers` that separates real from unmapped/legacy rows has not been run,
and it is what turns "45 users in no group" into an actionable number. P2's set-4 predictor is *effectively*
empty on UAT — no user loses a function they hold — but per point 1 that reading is weak on three tenants
by construction.

---

### 14.18a Hydra prd audited — P1/P2 complete, and P5 is validated on production (2026-08-20)

Credentials fixed by Nam, so §14.18's blocker is cleared. ⚠️ **The MCP server itself still authenticates as
`wh03_om1`** — a stdio MCP server is spawned at session start, so a config edit needs the server restarted;
this was run with `psql` against the connection string from the MCP config
(`wh01_hydra_v2_app@localhost:25061`, 67 visible tables, read-only queries only).

**Identity confirmed before trusting anything**, because prd's database has the *same name* as UAT's
(`wh01_hydra_v2`): 9 users where UAT hydra has 19, 433 stockunits, Flyway head **V2.2.16** applied 2026-08-17
— consistent with `origin/main`. Assuming here would have meant reporting UAT numbers as production.

**The 12-function check comes out identical in shape to all four UAT tenants: only
`MOBILE_UI_VIEW_REPLENISH_REQUEST` is absent, and it is the one `V2.2.18` seeds.** All 11 others are present.
So the surface question is now answered for **5 of 5 live v2 databases** — every one needs exactly the
migration this ticket already carries, and nothing more.

**Population: 9 users = 7 real + 2 service accounts.** `admin`, `bcampbell`, `davido`, `jgero`, `panderson`,
`thomasjr`, `tomh` each hold **all 10 existing `MOBILE_UI_VIEW_*` functions** plus `MOBILE_UI_LOG_IN`, all
seven via the `super-admin` role. `anonymous` and `oms_integration` hold nothing, cannot log in to mobile and
are in no group. `mywms_user_mywms_role` is **empty** — every grant flows user→group→role→function.

🔴 **P2's set 4 is empty on prd, and the classification matters more than the number.** It is the *genuine*
kind for the 7 real users — they hold everything, so nobody loses access. But the same fact means **this gate
is a no-op for every current prd user**: nobody is denied, and nobody is exploiting the bypass either, because
all seven legitimately hold every function. **The security value on prd today is future-proofing, not
remediation** — worth saying plainly, since the ticket is filed as a security defect and the deploy risk and
the deploy benefit are both approximately zero on production as it stands.

✅ **P5 is now validated on production, and it prevented a failure.** `mywms_role_mywms_function` on prd has
**no primary key and no unique constraint** — only the two foreign keys. That is a **fourth** variant beyond
the three §14.8 measured (base dump: none · WineCo dev: `…_pkey` · Hydra UAT: `…_pk`). **Both `ON CONFLICT`
forms would have failed here**: the named form has no constraint to name, and column-inference raises `42P10`
with no unique index to infer. The `NOT EXISTS` guard §14.8 argued for on two tenants turns out to be the only
form that works on the one database where a failure would have mattered.

**`V2.2.18` will behave as intended on prd**: every persona-grant target role exists (`outbound-worker`,
`outbound-manager`, `super-admin`, `inventory-manager`), and the back-compat grant fires for the two roles
holding `MOBILE_UI_VIEW_REPLENISHMENT` — `receiving` and `super-admin`. prd sits at V2.2.16, so it will apply
**V2.2.17 and V2.2.18 together**.

⚠️ **Unrelated pre-existing gap, found in passing and needing an owner outside this ticket: prd's Flyway chain
is missing `V2.2.11`** (`seed_adjustment_alert_poll_sysprop`, SBDEV-2658) while 2.2.12–2.2.16 *are* applied.
Benign in effect — it seeds a feature toggle to `'false'` and its own header notes that an absent row is
equivalent to OFF — and it does **not** block `V2.2.18`, since 18 > 16. But it is an unrecorded hole in a
production migration chain, which is the shape of the documented "tenant migration failures never abort boot"
landmine. Recording it here rather than filing: it is one row, currently harmless, and the ticket policy says
consolidate.

**P1/P2 status: the DB half is COMPLETE across all 5 live v2 databases (4 UAT + prd).** What remains of P1 as
written is the **E1-P Keycloak join** — on prd that is now a 9-row question, and 2 of the 9 are service
accounts, so it is close to trivial there.

---

### 14.19 Independent code review — five lanes, and the verdict (2026-08-20)

**This is the implementation's first independent review** (§14.5's "one-author core" is now closed for the code;
the plan's core remains one-author). Five lanes, reports preserved verbatim in `reviews/`:
`SBDEV-2968-review-{authz-bypass,test-adequacy,mobile-ui,migration-data,regression-contract}.md`.

⚠️ **Process note first, because it nearly cost the whole review.** Four of the five lanes initially terminated
**idle with no report**, which is indistinguishable from "reviewed and found nothing". Recalling them with a
**write-the-file-first** contract (create the report file as the first tool call, append each finding as it is
established) recovered all four. Had their silence been read as a pass, this change would have gone to PR with
every finding below unknown. Recorded as a durable rule in memory; never accept an idle lane as a clean lane.

#### The headline: the entire gate can be switched off and nothing notices

🔴 **`WebConfig.java:35` is asserted by nothing.** Registering the interceptor on a path that can never match —
i.e. disabling the whole feature in production — leaves **100 unit tests green AND all 119 verify rows green**.
Reproduced twice, independently of the lane that found it. Verify row `A20` greps only for the tokens
`FunctionGuardInterceptor|addInterceptor`, which such a mutant retains. This is the **SBDEV-2863 shape** the
plan quotes as its own cautionary tale, and it is the one defect that makes every other guarantee in this
document conditional.

The mutant table explains the pattern, and it is coherent rather than scattered: **the interceptor's internals
are well tested** — bean-type-vs-declaring-class, annotation priority, the header emit and the
`response.reset()` trap were all four killed — while **every wiring point is untested**: the registration
(M3), `GUARDED`'s membership (M2), the boot assertion's production overload (M9), the empty-varargs policy
(M8), the interceptor's own fail-closed branch (M1, matching §14.15), and `nuxt.config.js`'s middleware entry.
The suite verifies how the gate behaves once entered and never that anything enters it. A null mutant survived,
so the harness was sane.

#### The mobile guard does not work in the scenario it was built for

🔴 Three High findings, two of which I verified myself:
- **`store/home.js:143` — `ensureRolesLoaded` can never fetch.** It derives its principal from
  `home.profile.username`, and **nothing in the app ever commits `setProfile`** (one mutation definition, one
  commented-out line pointing at a different module, zero writers). So the guard reads `functions: []` and
  denies. **Every cold-start deep link denies every operator, including a fully entitled one** — and the deep
  link is precisely the vulnerability this ticket exists to close.
- **`store/home.js:148` — the memoised promise is poisoned by its own `finally`.** On the no-principal path the
  async IIFE completes synchronously, so `finally { rolesPromise = null }` runs *before* the assignment lands
  and is overwritten; every later call short-circuits. Measured: zero HTTP requests after three calls with a
  valid username. This survives a fix to the first defect, because Keycloak init is async and the first
  navigation always precedes it.
- **Persisted `rolesLoaded` outranks any fresh fetch** — third occurrence of this `vuex-mobile` blob class
  (SBDEV-2726's shared key, the stale `warehouseTimezone`), now load-bearing for an access decision.

**Why all three shipped green: `store/home.js` has no test at all.** The plan specifies
`test/store/home.spec.js` with two named cases; it is not in the commit. Every middleware test injects
`{rolesLoaded: true, functions: […]}` with a stubbed `dispatch`, so AC-19's
`waitsForEnsureRolesLoadedBeforeDeciding` passes against a function that does nothing.

#### Two lanes disagreed; both resolved by measurement, not by argument

1. **403 body shape.** The regression lane called it High — `reason`/`requiredFunction` nested under
   `properties`, so the mobile toast never fires. The mobile lane had ruled the same thing *clean* by execution.
   Settled by serialising a `ProblemDetail` both ways: a plain `new ObjectMapper()` nests
   (`{"properties":{…}}`), Spring's `Jackson2ObjectMapperBuilder` **flattens** (`{"reason":…}`). Production
   injects Spring's, so **rendering works and the High is REFUTED** — but the *test* constructs the interceptor
   with a plain mapper, so it exercises a shape production never produces, and its `.contains(…)` assertions
   hold in both. Re-graded **Medium, test fidelity**.
2. **prd exposure.** The regression lane measured named users losing access on WineCo dev and hydra-uat but was
   refused on prd (`permission denied`). §14.18a closes that gap from the other side: all 7 real prd users hold
   everything, so **prd loses nothing** — the lane's unmeasured worst case does not materialise there.

One further refutation: the migration lane read my own prd evidence table's `roles / users` columns as
"n of 7 users" and raised a High self-contradiction. Refuted — the per-user listing in the same file is
authoritative — but the abbreviated column labels were mine, and are now fixed in the evidence file.

#### What the review CLEARED, by execution

Worth recording, because several were carried as open risks for weeks: dispatch coverage is complete (ASYNC,
`forward:`/`include:`, ERROR, `@ExceptionHandler`, and `IdempotencyFilter` cannot replay a guarded response —
it is restricted to non-GET `/rest/**` and every guarded controller is `/v3`); the guard **fails closed in
every branch**, including a null tenant profile, which routes to the landlord datasource and 403s or 500s but
never allows; annotation resolution is sound for today's code; `X-Authz-Denied` header casing works under axios
1.16.1; a denial **cannot** log the operator out (`handleMaxRetryTimesExceeded` needs `retryCount >= retries`,
and a `false` at attempt 0 leaves it at 0), which independently confirms R6b's re-grade; a genuine stale-token
403 still refreshes; `OrderHeaderBlock`'s deleted defensive parsing is safe; and **zero web-UI callers** reach
the eleven gated prefixes, independently confirming P3 direction 1.

#### The security ceiling, stated plainly

🔴 Two findings bound what this change can claim, and both are pre-existing rather than introduced here:
- **Every `MOBILE_UI_VIEW_*` gate is self-grantable in one unguarded Spring Data REST request** — the
  authorization tables the gate reads are themselves writable under `wms_user`.
- **`POST /v3/stockUnit/transferStock` is ungated**, so a user denied `MOBILE_UI_VIEW_STOCK_TRANSFER` is 403'd
  on `/v3/moveStock/**` and can still perform the transfer. §0.B names it and R12 carries it to SBDEV-3017 — so
  it is a stated boundary, not a miss, but the bypass lane disputes its **Low** grading on the ground that the
  residual is the entire gated *write*, not a peripheral read. That grading should be revisited.

Consequence: this change raises the cost of casual deep-linking; it does not make the mobile surface
authoritative. The plan should say so where it currently implies otherwise.

#### Verdict: NOT PR-ready. Ordered fix list

> **Progress, 2026-08-20 (later the same day): items 1–4 are DONE and committed.** `wms2-api` `dde7953`
> (wiring pins) and `fa28026` (audit + seed), `wms2-mobile-ui` `1dfdb30` (the guard). Verify moved
> `119 → 129 pass / 0 fail / 2 skip`; API suite `5280 tests, 2 failures` = the known baseline; mobile
> `182 passing`. **Every fix was mutation-verified** — 5 API mutants, 6 mobile mutants, 5 verify-row
> reverts, all killed, with a null mutant surviving in each harness. **Item 5 is three decisions and is
> the owner's, not the implementer's.** What remains before a PR is item 5 plus the re-review in item 6.

1. **Pin the wiring.** A test that fails when the interceptor is not registered for `/**`, plus one per surviving
   mutant (`GUARDED` non-empty, boot assertion's production overload, empty-varargs denies, mobile middleware
   registered). Tighten verify `A20` to assert the path pattern, not just the tokens.
2. **Fix `ensureRolesLoaded`** — populate the principal (or read it from Keycloak directly), fix the memo
   ordering, and exclude `functions`/`rolesLoaded`/`rolesError` from the persisted blob. **Add
   `test/store/home.spec.js`** as the plan already specified; without it these recur.
3. **Fix the P2 gate criterion** (§14.16/§14.18 — Set 4 can never be empty) and the audit's pre/post-migration
   mismatch.
4. **Migration:** guard on `function`, not `name`; add `SELECT DISTINCT` to step 2; reconcile the
   `V2.2.18`-vs-`initDB` grant divergence.
5. **Decide** the P7 deploy order (three-step seed-first vs the one-line `menuCatalog` change), M1's test seam,
   and R12's grading.
6. Then re-review the diff — items 1 and 2 change it materially — and only then open the PR.

---

### 14.20 Review fixes 1–4 implemented (2026-08-20)

Commits: `wms2-api` **`dde7953`** (wiring pins) + **`fa28026`** (audit + seed); `wms2-mobile-ui`
**`1dfdb30`** (route guard). Verify **129 pass / 0 fail / 2 skip** (was 119); API **5280 tests / 2 failures**
= the known `develop` baseline; mobile **182 passing** (was 170).

**Everything below was mutation-verified rather than asserted** — 5 API mutants, 6 mobile mutants and 5
verify-row reverts, all killed, each harness validated with a null mutant that correctly survived.
⚠️ **Corrected 2026-08-21: one of the six mobile mutants does NOT die in isolation.** Reverting the memo
ordering alone (`finally` inside the IIFE instead of `.then(clear, clear)`) leaves 182/182 green, because
`await awaitAuthReady(this)` now guarantees a microtask before the `finally` can run, making the two
shapes behaviourally identical *given the barrier*. Only the combined mutant (ordering + barrier
dropped) is caught. The ordering fix is therefore **defence-in-depth, not an independently-pinned
fix** — and it matters, because an early return added *before* the await would reintroduce the
poisoning bug with only `awaitsTheAuthReadyBarrier…` standing between it and green.

| Fix | What changed | Mutants killed |
|---|---|---|
| **1. Wiring** | New `FunctionGuardWiringUnitTest` (6 tests): the interceptor is registered, **matches a real guarded path** (behavioural, via `MappedInterceptor.matches`, not a grep for `"/**"`), matches an arbitrary path so §3.1-A4 holds, `GUARDED` equals the eleven by set equality, ~~the boot assertion reads that same set~~ — 🔴 **that clause is WITHDRAWN 2026-08-21: it was never delivered.** `interceptorAndStartupAssertionShareOneGuardedSet` passes `List.of()`, and an empty handler list can never yield a violation whichever set is used, so assertion 1 is vacuous and assertion 2 is a verbatim duplicate of `guardedSetIsExactlyTheEleven` twelve lines above. Measured two ways: under the `GUARDED`-emptied mutant it failed only on the duplicate, and under the overload-rewired-to-`Set.of()` mutant it passed. §14.19 item 1 explicitly required the boot assertion's production overload to be pinned; it is not. The test file's own inline ⚠️ block was honest about this — this table was not. — and an empty `@RequiresFunction` denies. Verify `A20` tightened + `A20a–d`. | registration removed · pattern never matches · pattern narrowed to `/v3/**` · `GUARDED` emptied · empty list allows |
| **2. Route guard** | Principal now from `$kc.tokenParsed.preferred_username` (the only one available on a deep link); memo assigned **before** the clear-on-settle, via `.then(clear, clear)`; awaits the auth-ready barrier; `functions`/`rolesLoaded`/`rolesError` no longer persisted; `index.vue` commits the profile it was discarding; **an unresolved principal no longer denies**. New `test/store/home.spec.js` (10) + 2 middleware tests. | each of the three fixes reverted · readiness await dropped · empty list committed on unknown principal · guard denies on unresolved principal |
| **3. Audit** | `SET 4` filters to the **locked-out**, roster moved to `SET 4b`; gate evaluated **post-migration** via `projected_held`; direct `mywms_user_mywms_role` path added; `GROUP BY user_id`; header warning rewritten. | 4 verify-row reverts |
| **4. Seed** | Guard on **`function`** (the `UNIQUE` column) as well as `name`; `SELECT DISTINCT` in step 2. | 2 verify-row reverts |

**Two judgement calls worth flagging, both deliberate:**

1. 🔴 **The client guard now fails OPEN on an unresolved principal.** `rolesLoaded === false` makes the
   middleware decline to decide rather than redirect. This is a deviation from §3.2-B3's text, and it is
   correct: this guard is a UX affordance, the server's interceptor is the boundary, and failing closed here
   is exactly what locked fully entitled operators out of every cold-start deep link. Flagged for the
   re-review rather than buried.
2. **The `V2.2.18`-vs-`initDB` grant divergence is documented, not resolved.** Reconciling it is a
   privilege-scope decision: widening the migration to match `initDB` would silently grant new access to
   existing users *inside a security change*, and narrowing `initDB` changes what a new tenant gets. Both
   sets are now recorded in place with their measured holders. `initDB` is unreachable today regardless —
   `UtilRestController` is `@Service`, not `@RestController`.

**`SET 4` was validated in both directions**, which is the whole point of a gate criterion: **0 rows** on
Hydra UAT (satisfiable *and* satisfied) and **4 rows** on WineCo dev — `sbtest` plus three `Z-…(archived)`
accounts, every one explainable. Before the fix it returned 54 and 15 respectively and could never be empty.

**Still open: item 5's three decisions** (P7 deploy order · the M1/M9 interceptor seam · R12's grading) and
item 6, the re-review — items 1 and 2 changed the diff materially, so the earlier lane reports no longer
describe what is on the branch.

### 14.21 The corrected SET 4 run on the remaining four databases (2026-08-21)

§14.20 fixed the P2 gate criterion but ran it on only two databases. The other four are now measured, so
**`SET 4` has been executed on all six live v2 databases** and the prd clause of P2 is satisfied by query
rather than by inference. Verbatim CTE chain from the committed `db/audit-access-invariants.sql`, read-only,
identity confirmed per server before trusting any row. Evidence: addendum 2 in
`9-System/evidence/SBDEV-2968-p1-uat-function-audit.txt`.

| Database | Tenant | SET 4 | SET 4b distribution | SET 1 |
|---|---|---|---|---|
| `wh01_shipitez_v2` | shipitez/c1wh UAT | **0** | 23 x 12/12, 10 x 11/12 | 3 — `anonymous`, `oms_integration`, `tuser03` |
| `wh02_shipitez_v2` | shipitez/nywh UAT | **0** | 9 x 12/12 | 2 — service accounts only |
| `wh01_om1_v2` | wineco/wsl UAT | **3** — `Z-AdamPetersen`, `Z-Warehouse`, `Z-mariaortiz`, all `(archived)` | 3 x 0, 4 x 6/12, 1 x 7/12, 6 x 11/12, 35 x 12/12 | 45 — 40 `Z-…(archived)`, plus `anonymous`, `oms_integration`, `kimberlyconyers`, `lukamiranda`, `sbuser17` |
| `wh01_hydra_v2` | **Hydra prd** | **0 — measured** | 7 x 12/12 | 2 — service accounts only |

**Four things this run changed, three of which correct a document rather than a number.**

1. ✅ **prd is measured, not derived.** §14.18a inferred an empty SET 4 from the per-user listing. The
   inference was sound and the query agrees — but the row now rests on the query.
2. 🔴 **`wh01_om1_v2` has three locked-out accounts, not the one §14.18's evidence recorded.** All three carry
   the `Z-…(archived)` convention, so the disposition is probably WineCo dev's — but the evidence file knew
   only `Z-mariaortiz`, and a spot finding treated as a count would have missed two.
3. ⚠️ **The `wms2-hydra` MCP server now works as `wh01_hydra_v2_app`.** Addendum 1's warning that it
   authenticates as `wh03_om1` against 0 visible tables is **spent**. Identity was still re-confirmed against
   the recorded fingerprint — users 9, stockunit 433, Flyway head V2.2.16 — because two servers point at
   same-named databases and prd previously answered as the wrong one. Also measured: UAT sits at **V2.2.17**,
   prd at **V2.2.16**, and `mywms_user_mywms_role` is empty on all four, so the direct user→role path added to
   `held` in §14.20 changes no number here, exactly as its comment predicts.
4. ⚠️ **`SET 4` cannot see a user with no grants at all** — worth writing down before someone over-reads a
   zero. `per_user` derives from `projected_held`, so a user holding zero functions never enters it. That
   population is `SET 1`'s, the two sets are disjoint by construction, and the counts reconcile exactly:
   36−33=3, 11−9=2, 94−49=45, 9−7=2, each equal to that tenant's `SET 1` size. **By design, not a hole** — but
   "SET 4 empty" means *nobody holding something is left with nothing*, not *nobody is locked out*. The audit
   header does not say this; today only the P2 row does, and the header is what an operator will read.

**One structural consequence: P2 is no longer independent work.** Every undisposed row across all six
databases — `kimberlyconyers`, `lukamiranda`, `sbuser17`, `tuser03`, plus the three archived SET 4 rows — is
settled by the same question, *does this account have a Keycloak identity?* P2 scopes itself to the mapped
population and rules unmapped rows out as unable to authenticate. **So the two remaining blocking
prerequisites are one piece of work: P1's E1-P bulk `findUsers` join over 7 names.** None of the 7 is a
regression — they hold zero gated functions today, already land in the blank app of the ticket's own adjacent
defect #2, and the gate takes nothing from them.

⚠️ **Classification, because two of the four zeros are the weak kind.** Per the audit header's own warning:
shipitez/nywh (9 of 9 hold everything) and prd (7 of 7) have no role with an exclusive holder, so their empty
results mean *this tenant cannot demonstrate the gate*, not *the gate is safe here*. `wh01_shipitez_v2` is
mixed — 10 of its 33 grant-holding users genuinely lack one workflow. Only `wh01_om1_v2` has role separation
broad enough for its numbers to carry weight, and it is the one that returned rows.

### 14.22 Second independent review of the diff, and the fixes it forced (2026-08-21)

§14.19 item 6 required a re-review because fixes 1–4 changed the diff materially. Four lanes, reports in
`reviews/SBDEV-2968-rereview-{wiring,mobile-guard,audit-seed,regression}.md`. All four were given a
**write-the-file-first** contract (create the report as the first tool call, append each finding as it is
established) — the rule §14.19 learned the hard way. All four delivered; none went idle.

**It found four Highs. One was a live production defect that round 1 had explicitly REFUTED.**

| # | Finding | Status |
|---|---|---|
| **H1** | 🔴 **The 403 denial body ships NESTED, so no denial renders anything.** §14.19 re-graded this to "Medium, test fidelity" because Spring's `Jackson2ObjectMapperBuilder` flattens `ProblemDetail` extensions. True in general, false here: `WebConfigurer.java:72` declares `@Bean @Primary ObjectMapper` as a bare `new ObjectMapper()`, and `JacksonObjectMapperConfiguration` is `@ConditionalOnMissingBean`, so Boot's mapper — the one carrying `ProblemDetailJacksonMixin` — backs off entirely. `axios.js` gates its toast on `body.reason`; nested, that is `undefined`. **The gate denied correctly and the operator saw nothing** — exactly the R15 failure mode. | **FIXED** — body assembled explicitly; wire shape no longer depends on the injected mapper |
| **H2** | 🔴 **The fail-open was justified by a false claim, over a mutating endpoint.** "The server's FunctionGuardInterceptor still enforces every endpoint" appeared in 4 sites. `POST /v3/stockUnit/transferStock` — Move Stock's commit action — was ungated, and with the guard declining to decide on a slow Keycloak init it was reachable by **ordinary navigation**, not deliberate replay. That is what makes R12's `Low` wrong. | **FIXED** — endpoint gated; wording corrected in all 4 sites |
| **H3** | 🔴 **Fix 2 reopened the shared-handheld state bleed.** Committing `home.profile` at `pages/index.vue:111` flipped a branch in `refreshMenus` that had been dead since the merge base, so `$kc.logout()` — and with it `clearPersistedSession()`, which removes `vuex-mobile` — stopped running on "back to main" at **24 call sites**. Five workflow pages read `state.<module>.process` straight from that blob with no reset on entry. Found independently by two lanes. | **FIXED** — reset is unconditional again, and pinned by a test |
| **H4** | 🔴 **Deleting `@Configuration` from `WebConfig` disables the whole gate with 157 tests and 129 verify rows green.** The pin closed line 35 but not the class's bean-ness; every test constructs `new WebConfig(...)` by hand, which can never observe whether Spring would have constructed one. Same blast radius and same silence as the defect fix 1 was written to close, two lines up. Not hypothetical: `WebConfigurer` duplicates `addResourceHandlers`, so anyone tidying that turns off mobile authz. | **FIXED** — `@Configuration` + `WebMvcConfigurer` + scan-root now asserted |

**Also fixed:** `profile` and a rehydrated pre-fix blob (the reducer governs what is *written*, never what is
read back — so the exclusion only helped already-clean devices); `excludePathPatterns` un-gating any of ten
controllers with the suite green (the probe now covers all eleven, prefixes derived from each
`@RequestMapping` so they cannot drift); the audit's header case 1, which claimed more than `SET 4` can
support; the `GROUP BY` comment, whose stated reason was factually false — `mywms_user.name` **is** UNIQUE
(`uk_48pkipun1pytmies0wei11bhm`, verified); and `V2.2.18`'s comment, which justified leaving the `initDB`
divergence alone on grounds its own next two statements contradict.

**Two new audit sets, because `SET 4` can be silently wrong in the permissive direction.** `SET 8` probes the
two divergences it cannot see: `mywms_function.name IS DISTINCT FROM function` (the seed guards on `function OR
name` while every acting path keys on `name` alone — on a divergent tenant step 2 inserts nothing *without
error* and replenish-request is dead for everyone, permanently, with the migration reporting success), and
`mywms_user_mywms_role` non-empty (the audit's `held` includes the direct path, the runtime gate does not, so
the predictor is unsound the dangerous way). Both return 0 on all measured databases — latent, not firing.
`SET 9` reports what the deploy **adds**: every other set reported only what it takes away, on a change that
ships hard-on with no flag. Measured: 7 real users on wineco/wsl UAT, 2 QA accounts on shipitez/c1wh, 0
elsewhere, **0 on prd**. Step 3 grants nobody anything.

**AC-4 became a reviewed allow-list rather than a blanket ban.** Their own ArchUnit rule
`noSharedControllerCarriesRequiresFunction` caught H2's fix — the rule doing its job, but its premise is a
claim about each *endpoint*, not the class. It now permits exactly two named method gates, still bans
class-level annotations outright (a class-level gate fails closed across ~40 shared endpoints and would 403
web screens), and asserts no allow-list entry has gone stale — a stale entry would keep permitting a renamed
method and hide the next real offender. Verify row `C13` ("StockUnitController NOT annotated") pinned the
*old* R12 decision, so it was **replaced, not deleted**, by `C13`/`C13a`/`C13b`.

**Measurements.** `wms2-api` **5283 tests, 2 failures = the known develop baseline** (`OptionalSafetyArchTest`,
`MobilePalletizingServiceTest`); an intermediate run showed **3**, and the extra one was AC-4 above — caught
and resolved, not waved through. `wms2-mobile-ui` **186 passing / 16 suites** (was 182). Verify **131 pass / 0
fail / 2 skip** (was 129/0/2). Every fix mutation-checked: 4 mobile mutants, 3 API mutants, 3 AC-4 mutants, 2
wiring mutants, plus 3 verify-row negative tests replaying the pre-fix file — all killed, **with a null mutant
surviving in each harness**. Mutation runs used `mvn -o clean test` throughout, because the wiring lane
measured a mutant reporting **false green** under incremental compile — the same class as §14.15's eight false
SURVIVED verdicts, and a reason to distrust any mutation result taken without `clean`.

**Corrections to §14.20, both applied in place:** claim (e) ("the boot assertion reads that same set") was
never delivered — the test passes `List.of()`, which can never yield a violation whichever set is used — and
one of the six mobile mutants does **not** die in isolation, because the `await` barrier makes the memo
ordering inert on its own. The test file was honest about the first; the summary table was not.

**Still open after this round.** The wiring lane's F3/F4/F7 and the SQL lane's F6/F7/F8 (all Low, or Medium
and test-side); the boot-assertion coupling, which needs either the injectable-guarded-set design change
§14.19 item 5 is holding or one ArchUnit field-access rule; **M23's browser probe and the AC-31 post-fix
re-measurement**, both browser-only; **P1's E1-P Keycloak join** over the 7 names in §14.21; **P6** at PR time;
and manual QA on a handheld. R12's grading should now be revisited in light of H2 — the *mutating* half of
its residual is closed, and what remains on gated screens is read-only (`/v3/section*` via SDR, which this
mechanism structurally cannot reach, and `/v3/dashboard/*`), which is a materially different claim from the
one the plan has been carrying.

#### 14.22a The wiring lane's two remaining Mediums, also taken (2026-08-21)

The lane called F5 and F7 "cheap and I would take them in the same pass". Both are now done, so nothing it
graded Medium-or-above is outstanding.

**F5 — method-level overrides are now pinned exhaustively (`AC-4b`).** A method-level `@RequiresFunction`
*replaces* the class default, so one line moves an endpoint onto an unrelated function. The golden map is
class-level only, and overrides were pinned for exactly one controller (AC-28) plus one named method on a
second (AC-14) — leaving nine controllers with no "no override here" assertion. Worse, AC-14 makes the pattern
legitimate, so a reviewer has no signal that a new override is unreviewed. `AC-4b` now asserts **equality**
between the overrides found by reflection and a declared allow-list of the three that exist
(`LookupController#locationByLocationName`, `ReplenishController#requestLocation`, `#requestAmount`) — derived
from the tree, not guessed. Equality rather than containment, so a **deleted** override fails too: losing an
intended one silently re-points an endpoint at its class default. Mutation-checked with the lane's own mutant
(an override on `PickingController#pickTimeOutValue` → killed) and a deletion (→ killed by `AC-4b` *and*
`AC-28`, independent corroboration); null mutant survived.

**F7 — `A20c`/`A20d` were satisfiable by prose; `A20e` is new.** Measured by the lane: with the test class body
replaced by a single comment and **zero assertions left**, `A20c` still passed off `{@link MappedInterceptor}`
in a javadoc plus the import line; and weakening both equality calls to `containsAnyElementsOf` while leaving
the old name in a trailing comment kept verify at 129/0/2, after which `GUARDED` could be trimmed from eleven
to ten with the suite 6/6 green — the exact §3.1-A8 regression the pin exists for, green in *both* gates. Both
rows now filter comments and require the token in a **call position**; `A20e` counts the production `GUARDED`
set independently, because `A20d` compares it to the test's own `EXPECTED_GUARDED` and trimming *both* keeps
that green. Negative-tested against all three of the lane's scenarios: gutted test → `A20c`+`A20d` red;
weakened-with-comment → `A20d` alone red; `GUARDED` trimmed to ten → `A20e` alone red.

⚠️ **Three self-inflicted traps hit while writing those rows, all of which produce credible-looking reds or
greens, and all worth knowing before editing this script.** (1) A `strip_comments` **shell function is
undefined inside `bash -c`** — subshells do not inherit functions — and bash's exit 127 records as an ordinary
FAIL, so three correct rows went red against correct code. (2) A **regex comment-stripper cannot be used on
this file**: it contains the string literal `"/**"`, whose `/*` opens a fake comment that a lazy `.*?` under
`/s` closes many lines later, deleting the real assertions and zeroing the matches. Comments are therefore
filtered **line-wise**, which a string literal cannot fool. (3) An **unescaped `"` inside a `bash -c "…"` row
closes the string early** and silently mangles the regex — that is what made the first `C13` rewrite fail; the
mapping-path quote is matched as `.` instead. Related: the script runs under `set -u`, so deleting a variable
assignment while editing a block **aborts the run at that line** and every later row silently never executes —
the earlier negative-test runs printed row verdicts but no `Result:` line for exactly this reason. Always
check for a `Result:` line before believing a verify run.

**Final measurements, this round.** `wms2-api` **5284 tests, 2 failures = the known develop baseline**
(`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`); `archunit_store` reverted after the run, as it must
be. `wms2-mobile-ui` **186 passing / 16 suites**. Verify **132 pass / 0 fail / 2 skip** (129 before this
round: `+C13a`, `+C13b`, `+A20e`, with `C13` replaced in place). Working trees hold **7 modified files in
`wms2-api`** and **4 in `wms2-mobile-ui`**, all uncommitted pending the owner's go-ahead.

### 14.23 Committed — and develop moved underneath, which stales a round-1 clearance (2026-08-21)

**Commits.** `wms2-api` **`76b3131`** (5 commits on the branch, clean tree) and `wms2-mobile-ui` **`bed32f5`**
(3 commits, clean tree). Verify **132/0/2** on the shadow root, `wms2-api` **5284 tests / 2 failures = the
known develop baseline**, `wms2-mobile-ui` **186 passing**.

**Base is now stale, and it is not a formality this time.** `origin/develop` gained **6 commits (api)** and
**5 (mobile)** while this round was in flight — **SBDEV-3003 Slice 2**, merged as PRs #175/#176 and #39/#40.

🔴 **It enrolled the exact endpoint this round gated.** `IdempotencyFilter` on develop now carries
`V3_ALLOW_LIST = Set.of("/v3/stockUnit/transferStock")` — the one path §14.22's H2 fix annotated with
`@RequiresFunction`. **That stales §14.19's clearance**, which read *"`IdempotencyFilter` cannot replay a
guarded response — it is restricted to non-GET `/rest/**` and every guarded controller is `/v3`"*. True when
written; false after the merge. Nobody would notice, because the clearance is recorded as settled.

**What the interaction actually is**, read off develop rather than assumed:
- A servlet `Filter` runs **before** Spring MVC's `HandlerInterceptor`, so `IdempotencyFilter` sees the request
  first and, on a replay, serves the cached response **without invoking the handler** — so
  `FunctionGuardInterceptor` never runs on a replay.
- ✅ **A denial cannot be cached.** Only 2xx are persisted; 4xx/5xx are dropped. So a 403 will not be replayed
  to a later, legitimately entitled caller — the direction that would have been an availability bug is closed.
- 🔴 **The key is NOT principal-scoped.** `tryClaim(key, method, path, requestHash)` takes no username or
  tenant-user identity. So a 2xx stored for an **entitled** operator can be replayed to a **different,
  unentitled** caller who presents the same client-generated nonce, and the function gate is bypassed for that
  request because the handler is never reached.
- Exploiting it requires **knowing the nonce**, which the mobile client generates per intent — so this is not
  an open door, and it is not a regression (before this ticket nothing was gated at all). It is a hole in what
  the gate can *claim*: possession of a nonce substitutes for holding the function.

**Graded Medium**, and deliberately NOT fixed here: the fix belongs in SBDEV-3003's code
(`RestIdempotencyService`'s key derivation), the cheapest form is to include the authenticated principal in
the idempotency key, and one open question has to be answered first — whether `SecurityContextHolder` is even
populated at `IdempotencyFilter` time, which decides whether the filter can consult the principal at all.
Per the repo's ticket policy this is recorded here rather than filed; the natural owner is **SBDEV-3017**,
which already carries this mechanism's coverage residuals.

**Rebase note.** A dry-run merge (`git merge-tree`, non-destructive) reports **exactly one conflict:
`Authority.java`** — both branches add a header constant in the same region; `SecurityConfiguration.java`
auto-merges; mobile has **zero** overlapping files. Their change does **not** touch `StockUnitController`, so
the `@RequiresFunction` annotation itself is conflict-free. Not rebased: that rewrites published branch
history and was not asked for.

### 14.24 Rebased onto develop, and the three owner decisions taken (2026-08-21)

**Decisions, recorded so they are not re-litigated.**
1. **`V2.2.18` steps 3–4 SHIP.** The widening is intended (§D4) and production is untouched: 7 real users gain
   `WEB_UI_VIEW_TRANSFER_ORDER` on wineco/wsl UAT, 2 QA accounts on shipitez/c1wh, **0 on prd**, and step 3
   grants nobody anything anywhere. The migration comment that claimed the opposite is corrected, and `SET 9`
   now reports additions per tenant so the next security migration cannot do this invisibly.
2. **R12 is MEDIUM, owned by [SBDEV-3017](https://app.clickup.com/t/868kufdy1).** Row updated in §8, and §0.B's
   "can still call `transferStock` directly" paragraph corrected — it had become false.
3. **Rebase now.** Done, below.

**Rebase.** `wms2-api` **5 commits, now `b0810ea`**; `wms2-mobile-ui` **3 commits, now `76fc87c`**; both **0
behind `origin/develop`**, both trees clean. One conflict, exactly as the dry run predicted:
`Authority.java`, where develop's `WMS_USER_ROLE` (SBDEV-3003 Slice 2) and this branch's
`AUTHZ_DENIED_HEADER` are two purely additive constants landing in the same region. **Resolved by keeping
both**, develop's first so a future diff against develop stays minimal. Nothing else conflicted; mobile was
clean; `StockUnitController` was never touched by them, so the new gate rebased untouched.

**The IdempotencyFilter interaction, now read off one tree instead of two — and it is better than §14.23
feared, in the half that matters most.**

- ✅ **A denial is NOT swallowed by the filter.** The path is wrapped in a `ContentCachingResponseWrapper`, and
  `copyBodyToResponse()` sits in a **`finally`** — unconditional — so the interceptor's 403 body and its
  `X-Authz-Denied` header are copied out even though the handler never ran. Had that call been on the 2xx
  branch, §14.22's H1 fix would have been silently undone on this one endpoint: the gate would work and the
  operator would see nothing, again, on the only *mutating* endpoint in scope. Worth stating as a cleared risk
  rather than an assumed one.
- ✅ **The nonce is not burned by a denial.** `persistResponse` drops non-2xx, so the claim row is deleted and
  the operator's later, entitled retry can execute.
- 🔴 **The cross-user replay stands, and the open question from §14.23 is ANSWERED: the fix is cheap.** I asked
  whether `SecurityContextHolder` is even populated at filter time, because that decided whether a
  principal-scoped key was feasible. It is: the filter already reads
  `SecurityContextHolder.getContext().getAuthentication()` (`IdempotencyFilter:197`) and 403s a caller lacking
  `Authority.WMS_USER_ROLE` (`:389-391`) — develop's own javadoc explains why, since it runs before
  `AuthorizationFilter` and must repeat the route rule itself. **So adding the authenticated principal to the
  idempotency key is a small change in `RestIdempotencyService`, not a design problem.** That is the
  recommendation carried to SBDEV-3017.

**Measurements on the rebased tree** — everything re-run, because a pin measured on the old tree proves nothing
about the new one:

| | before rebase | after rebase |
|---|---|---|
| `wms2-api` | 5284 tests / 2 failures | **5303 tests / 2 failures** — same two known baseline names (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) |
| `wms2-mobile-ui` | 186 passing / 16 suites | **218 passing / 18 suites** (develop brought 2 suites, 32 tests) |
| verify (shadow) | 132 / 0 / 2 | **132 / 0 / 2** |

**The three High pins were re-mutated on the rebased tree, not assumed:** reverting the denial body → red;
dropping the `transferStock` gate → red (now **two** tests, since AC-4b's stale-allow-list check fires as
well); deleting `@Configuration` → red. `archunit_store` reverted after every run.

**What is left before a PR**, none of it blocked on a decision: **P1's E1-P Keycloak join** over the 7 names in
§14.21; **M23's browser probe** and the **AC-31 post-fix re-measurement**, both browser-only; **P6**'s
all-remote `V2.2.*` re-sweep at PR time; manual QA on a handheld; and the optional M1/M9 interceptor seam,
which the wiring lane confirmed is **not** required by any of its findings (every fix it asked for was
test-side or verify-side).

### 14.25 🔴 The H2 gate would have broken a WEB screen — found by asking the deployment question (2026-08-21)

**Nam asked whether deploying 2968 can break anything for Web UI users, ahead of planning 2967. The answer was
NO ONLY AFTER this fix.** §14.22's H2 gated `POST /v3/stockUnit/transferStock` and
`GET /v3/stockUnit/storageLocationsForStockMovement` on the mobile function alone, on the stated basis that
neither had a `wms2-web-ui` application caller. **That basis was false, and it was my error.**

Both endpoints are called by the web UI: `store/handlingUnits/stockUnits.js:161` and `:199`, behind the single
and bulk **Transfer Stock** buttons on `components/handlingUnits/stockUnitsTable.vue` →
`popups/transferStock.vue`. The web UI applies **no** client-side gating, so every authenticated web user can
reach that screen today.

⚠️ **How the wrong conclusion was reached, because the mechanism matters more than the miss.** The grep that
"proved" no web caller was `grep -rn … | grep -v node_modules | head -20`. `cypress/` sorts before
`components/` and `store/`, and there are more than 20 cypress hits — so the real callers fell off the end of
the output and the absence looked measured. **A truncated grep is not evidence of absence.** The same
`head`-truncation pattern is what produced §14.12's original 5-instead-of-17 endpoint count, so this is the
second occurrence in this plan.

**Blast radius, measured before fixing** — per tenant, users holding ≥1 function who would have been 403'd on
the web Transfer Stock screen:

| Tenant | Users w/ any function | Would 403 (mobile-only gate) | Hold NEITHER function (ANY-of gate) |
|---|---|---|---|
| **Hydra prd** | 7 | **0** | **0** — all 7 hold `WEB_UI_VIEW_STOCK_UNIT` |
| Hydra UAT | 15 | 0 | 0 |
| shipitez/c1wh | 33 | 0 | 0 |
| shipitez/nywh | 9 | 0 | 0 |
| wineco/wsl | 49 | **3** — all `Z-…(archived)`, 0 live | 0 |

So it was **latent, not firing**: no live user on any tenant would have broken on deploy day. That is luck, not
design — the SBDEV-1666 shape ships exactly this way.

**Fix: cross-namespace ANY-of.** Both gates now read
`@RequiresFunction({MOBILE_UI_VIEW_STOCK_TRANSFER, WEB_UI_VIEW_STOCK_UNIT})`. The annotation's ANY-of semantics
make this a one-line change, and the union is **strictly safer than the single gate**: it still denies a caller
holding neither, while never denying a web user who holds the web function. This is the cross-namespace ANY-of
that R12/SBDEV-3017 names as the likely general answer, applied here to one endpoint pair.

**Pinned three ways, because a one-token narrowing re-breaks the web screen with no other signal:**
`AC-4c` asserts the exact ANY-of set per gate; verify `C13` matches the two-function form and was
negative-tested (narrowing → RED); and the false claim in `REVIEWED_SHARED_METHOD_GATES`'s javadoc is replaced
with a bar that now requires an **untruncated** enumeration of every other caller — never `head`, never a spot
check — and each such caller's function included in the set.

⚠️ **`AC-4c` also caught an arity trap on its first run, worth recording.** `StockUnitController` declares
**two** methods named `getStorageLocationsForStockMovement`: the 1-arg one serving
`/storageLocationsForStockMovement` (gated) and a 2-arg **overload** serving `/isUnitLoadIdValid/{labelId}`
(deliberately ungated — `wms2-web-ui store/handlingUnits/stockUnits.js:212` reads it). A name-only lookup
resolved the wrong overload and reported the gated method as unannotated. The test now keys on
**name + arity** and fails if a key resolves anything other than exactly one method. Same arity-blindness that
made an earlier reflection test in this repo vacuous.

### 14.26 P1's Keycloak join — ANSWERED (2026-08-21, Nam)

**Result: 1 of the 7 names exists in Keycloak — `lukamiranda`. The other six do not.**

✅ **The only genuine regression evaporates.** `Z-mariaortiz(archived)` was the single account anywhere in the
population that held `MOBILE_UI_LOG_IN` with zero `MOBILE_UI_VIEW_*` — i.e. the only user who could log into
the handheld today, reach every workflow by deep link, and reach **nothing** after the gate. She is **not in
Keycloak**, so she cannot authenticate and cannot be locked out. Verified across all five live databases:
**zero users lose mobile access to this change.**

🔴 **But `lukamiranda` is mapped, and that makes her a live P2 item rather than a dismissible row.** P2's
second clause reads: *any mapped user in `SET 1` must have a named remediation applied before the image lands.*
She is mapped and she is in `SET 1`. What the data says:

| | dev (`dev_wh01_om1`) | UAT (`wh01_om1_v2`) |
|---|---|---|
| user id | 864391850 | **864391850 — the same row, migrated** |
| firstname | `Luka` | **`Z_Luka`** — archived on UAT only |
| groups | `CS-REP, outbound-worker, super-admin` | **none** |
| functions | (full, via super-admin) | **0** |

So her UAT row was **deliberately archived**, while her dev row retains full access including `super-admin`.
The archival happened on UAT specifically — it is not propagated from dev.

⚠️ **She is NOT a regression.** Holding zero functions, she gets nothing before the gate and nothing after;
the gate takes nothing from her. What she gets today, and will keep getting, is the blank
`/not-authorized` bounce — the ticket's own **adjacent defect #2**. P2 requires a *decision* about her, not a
fix to this change.

**Remediation options, with the measured consequence of each** (all three groups exist on UAT already, so none
requires creating anything):

| Option | Effect on UAT | Verdict |
|---|---|---|
| **Leave archived, no group** | Authenticates, reaches nothing — same as today | ✅ **DECIDED (Nam, 2026-08-21) — this is the remediation of record.** See the disposition below. |
| Grant `outbound-worker` | `MOBILE_UI_LOG_IN` + **6** mobile views (cancellation, info, palletizing, picking, stock-transfer, transfer) | Fine if she is meant to work UAT. A working operator, not a stranded one. |
| Grant **`CS-REP` alone** | `MOBILE_UI_LOG_IN` + **0** mobile views | 🔴 **Do not.** This produces the exact post-gate "logs in, sees nothing" state the audit exists to find — the documented CS-REP shape (§5.1-P2, `SET 3`, C4). It would *look* like provisioning and land her in `SET 4`. |
| Copy `super-admin` from dev | 10 mobile views — everything | 🔴 **Do not copy dev's grants to UAT.** That is a privilege decision, and dev is precisely where every `CS-REP` holder also carries `super-admin`, which is why dev's `SET 4` was an artifact rather than a clean result. |

**P1 status: CLOSED.** The join is run, its input set was the 7 names of §14.21, and the answer is 1 mapped /
6 unmapped. **P2 status: one named remediation outstanding** — a decision on `lukamiranda`, not a code or data
defect. Nothing here blocks the deploy: no user on any tenant, in any environment, loses access.

#### P2's named remediation — DECIDED 2026-08-21 (Nam)

> **`lukamiranda` stays archived on UAT. No group is granted, no data changes.**
>
> **Remediation of record:** *her `mywms_user` row on `wh01_om1_v2` (id 864391850) is intentionally archived —
> the `Z_Luka` firstname marker was applied on UAT deliberately and her access is dev-only. She holds zero
> functions before and after this change, so function gating takes nothing from her. She will continue to
> reach the `/not-authorized` screen on UAT, which is pre-existing behaviour and tracked separately as the
> ticket's adjacent defect #2.*
>
> **This closes §5.1-P2.** Both of its clauses are now satisfied: corrected `SET 4` is empty on prd — measured,
> not derived (§14.21) — and the one mapped `SET 1` user has a named remediation.
>
> ⚠️ **For whoever provisions her later, in any environment:** do **not** use `CS-REP` alone. Measured on UAT
> it grants `MOBILE_UI_LOG_IN` and **zero** `MOBILE_UI_VIEW_*`, which manufactures the exact "logs in, reaches
> no workflow" state this audit exists to detect. `outbound-worker` (login + 6 views) is the working
> alternative. And do not copy her dev grants across — dev carries `super-admin`, which is a privilege
> decision and is also why dev's `SET 4` result was an artifact rather than a clean pass.

### 14.27 M23 and AC-31 RUN against a live app — and the CORS gap demonstrated, not asserted (2026-08-21)

**The whole stack was run locally on this branch**: API on `:8088` (landlord overridden to `dev_landlord`,
tenant `wineco`/`wsl` → `dev_wh01_om1`, real Keycloak at `kc2.dev.sbo.li` realm `wineco`), mobile UI on
`:3001`, real Chromium via Playwright. **`app.flyway.migrate-on-startup=false` throughout — zero writes to any
dev database.**

**Subject: `panderson`, and the choice is load-bearing.** He is `super-admin` on dev with all 10
`MOBILE_UI_VIEW_*` functions, so pointed at any ordinary gated endpoint the probe would have been
**structurally incapable of failing** — no denial, no message, no header, indistinguishable from a broken
gate. The probe instead targets `/v3/replenish/requestLocation`, whose **method-level**
`@RequiresFunction` names `MOBILE_UI_VIEW_REPLENISH_REQUEST` — a function `V2.2.18` creates and which exists
on **no tenant yet** (0 rows on dev, measured). So even a super-admin is denied there. That is what gives the
probe teeth without provisioning or mutating anything.

**Measured, live:**

| Check | Result |
|---|---|
| Boot assertion (§3.1-A8) against a REAL handler mapping | ✅ **780 deployed handlers checked, 11 guarded controllers** — first time this has run outside a unit test |
| Denial | ✅ `403` + `X-Authz-Denied: MOBILE_UI_VIEW_REPLENISH_REQUEST` |
| **Body shape (§14.22 H1)** | ✅ `{"type":"about:blank","title":"Forbidden","status":403,"reason":"MISSING_FUNCTION","requiredFunction":"…"}` — **flat and top-level.** The pre-fix nested `{"properties":{…}}` would have left the client's `body.reason` undefined and rendered nothing. H1 is now proven on a running app, not reasoned about. |
| Gate does not OVER-deny | ✅ `/v3/replenish/clientList` 200 · `/v3/replenish/reservedOrder` 200 · `/v3/picking/pickTimeOutValue` 200 |
| CORS listing | ✅ `Access-Control-Expose-Headers: X-Export-Skipped-Cycle-Counts, X-Authz-Denied` — present exactly once, alongside SBDEV-2632's header |
| **M23 (c) — JS reads the header cross-origin** | ✅ real Chromium, origin `http://localhost:3001` → `headers.get('x-authz-denied')` = `MOBILE_UI_VIEW_REPLENISH_REQUEST` |
| **Non-vacuity control** | ✅ an *unexposed* header (`Date`) reads back **null** — so CORS filtering is genuinely active and the line above is a real result, not "this browser filters nothing" |

🔴 **The negative test is the most valuable single result in this ticket.** With the CORS exposure removed from
`SecurityConfiguration` and the app restarted:

```
curl    ->  X-Authz-Denied: MOBILE_UI_VIEW_REPLENISH_REQUEST     (header present — looks correct)
browser ->  authzDenied: null                                     (JS refused — operator sees nothing)
```

**curl reports success while the feature is silently dead.** §3.1-A2b and AC-31 *asserted* that neither a
unit test nor `curl` can see this; it is now demonstrated in both directions, on this code. Reverting the
mutant returns the probe to green. The mutant was reverted and the source verified clean.

**Automated, so it stops being a ritual:** `tests/e2e/m23-authz-denial.spec.ts` + `playwright.m23.config.ts`
(commit `03113ad`). Credentials come from `E2E_USERNAME`/`E2E_PASSWORD`/`E2E_TOKEN` and the test skips without
them — nothing hardcoded. Deliberately outside `playwright.config.ts`'s project graph, whose `setup` logs in
as a super-admin and shares `storageState` — the opposite of what a denial probe needs.

**What is NOT claimed.** ⚠️ Assertion **(a)**, "the denial renders", is not asserted by this probe. It needs a
subject refused at a gated *screen*, and the only endpoint that denies a super-admin sits behind a screen the
client route guard correctly blocks first. Its **precondition is proven** — `reason` is readable and top-level
from a real browser, which is exactly what `plugins/axios.js` gates the toast on — and the rendering logic has
a unit test (`test/plugins/authzDenialRendering.spec.js`). The residual is whether vue-toasted paints, which
stays with handheld QA. Also not done: the **35-endpoint breadth re-measurement** against §14.11's baseline,
which needs an under-privileged subject (`sbtest`) and is cheaper post-merge on DEV, which auto-deploys.

**Two harness notes worth keeping.** `plugins/axios.js` writes tenant headers into
`config.headers.common`, so a hand-built request config from page context throws
`Cannot set properties of undefined` — probe through the app's own instance or supply that shape. And the
browser-stored `kcToken` produced a **401**, not a 403: the `TenantFilter`/`MultiTenantJwtDecoder` path
answers an unresolvable token with 401, so the probe injects a known-good token instead — CORS enforcement is
a property of the browser, not of which token was used, so injecting isolates the assertion rather than
confounding it.

