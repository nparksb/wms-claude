---
title: "SBDEV-3063 — @PublicHandler marker so UserController can join the guarded set"
ticket: "SBDEV-3063"
ticket_url: "https://app.clickup.com/t/868kv1g2z"
type: "feature"
priority: "normal"
status: "archived"
project: [wms2]
version: "v2"
requester: "Nam Park"
created: 2026-08-24
updated: 2026-08-24
db_verified: true
related: []
tags:
  - plan
  - authorization
  - function-gating
---

> **ARCHIVED 2026-08-24.** Shipped and verified on dev.
> Merged: PR [#190](https://github.com/SiteBossInc/wms2-api/pull/190) → merge commit `9d16bbf`;
> feature commit `d83b72a` (17 files, +1700/−94), based on `origin/develop` @ `5b704e5`.
> Deployment **proven**, not assumed: the `wms2.authz.public` metric exists only in this commit and is
> registered on the running dev instance, tagged `handler=[isWmsUser, getAllRoles]` — which also proves the
> security review's M-2 fix is live and that exactly two handlers are open on the deployed surface.
> Live QA 8/8 (`sbtest` non-admin / `panderson` admin); mobile tile filter computed against `sbtest`'s real
> function list → 4 of 10 tiles, `pageList` non-empty.
>
> **No acceptance script was retired** — §9.1 deliberately ruled against one; all but two criteria live in
> JUnit. The live-deployment check `sbdocs/9-System/scripts/smoke-wms2-user-authz-dev.sh` (originally
> `smoke-SBDEV-3063-dev.sh`) was **deliberately renamed off this ticket and kept active** — it is the only
> automated check of this authorization surface against a real deployment, and SBDEV-3071 and SBDEV-3017
> slice B both touch these endpoints next.
>
> Implementation worktree removed 2026-08-24: `wms2-api/SBDEV-3063`.
>
> **Open, owned elsewhere:** SBDEV-3071 (arbitrary-username reads on the same two handlers) ·
> SBDEV-3017 slice B (the SDR half of `/v3/user`) · the SBDEV-3063 **ticket title** still says "runtime
> fail-closed", which review falsified — this change delivers default-to-admin-function plus a deletion
> tripwire (§1.1). Retitling is Nam's.

# SBDEV-3063 — `@PublicHandler` marker so `UserController` can join the guarded set

**Ticket:** [SBDEV-3063](https://app.clickup.com/t/868kv1g2z)
**Project:** wms2 | **Version:** v2 | **Type:** feature
**Priority:** normal
**Status:** approved — pending execution approval
**Date:** 2026-08-24

**Graded against `origin/develop` @ `b10b466441db47feaa167a1b51bc5133f87f08ce`.** Every `file:line` in this
document is a line number of the blob at that commit, read via `git show origin/develop:<path>`. The
checkout at `v2/wms2-api` was 27 commits behind at drafting time; do not grade this plan against its
working tree. A clean worktree exists at `.claude/worktrees/wms2-api/SBDEV-3063` on branch
`feature/SBDEV-3063-public-handler-marker`.

Paths are relative to `/home/nampark/dev/wms-claude/v2/wms2-api/` unless prefixed `wms2-web-ui/` or
`wms2-mobile-ui/` (those are relative to `/home/nampark/dev/wms-claude/v2/`).

---

## 0. Affected Sites (by enumeration)

Greps run against `origin/develop`:
`git grep -n "GUARDED|FunctionGuardInterceptor|FunctionGuardStartupAssertion|RequiresFunction|new FunctionGuardInterceptor\(" -- 'src/*'`.
Every hit is below. "Phase" maps to the slices in §5.2.

> ⚠️ **The RED/GREEN verdicts in §0.B are PREDICTIONS to be confirmed at P0, not measurements.** They were
> derived by reading each assertion, not by running it. **An implementer who trusts a GREEN and skips the run
> has been misled by this table** — that is the one way this section can do harm, and r1 presented the column
> as fact. Confirm the actual red set at the P0 gate and compare it to §3's predicted list; a divergence is a
> signal about the plan, not a nuisance. The `file:line` rows themselves are single-use implementation
> scaffolding: they will rot, and that is an accepted trade.

### 0.A — Production code

| # | File:line | Construct | In scope? | Phase |
|---|---|---|---|---|
| 1 | `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:80-96` | `static final Set<Class<?>> GUARDED` — the declaration, **13** members | **YES** — add `UserController.class` → 14 | P2 |
| 2 | `security/FunctionGuardInterceptor.java:118` | `getMethod().getDeclaringClass()` — the resolution key | No change; **load-bearing** (inherited `AdminController` handlers resolve to `AdminController`) | — |
| 3 | `security/FunctionGuardInterceptor.java:119` | `handlerMethod.getMethodAnnotation(RequiresFunction.class)` — METHOD-level only | **YES** — the conflict check must key on *this*, never on the reassigned variable. See §3.2 | P1 |
| 4 | `security/FunctionGuardInterceptor.java:120-122` | class-level fallback `AnnotationUtils.findAnnotation(declaring, …)` — **reassigns `annotation` in place** | **YES** — `@PublicHandler` must short-circuit before this runs | P1 |
| 5 | `security/FunctionGuardInterceptor.java:124-133` | `if (annotation == null) { if (!GUARDED.contains(declaring)) return true; … deny }` | **YES** — the marker block goes above this, immediately after `:118` | P1 |
| 6 | `security/FunctionGuardInterceptor.java:73-74` | `METRIC_ALLOWED` / `METRIC_DENIED` constants | **YES** — add `METRIC_PUBLIC = "wms2.authz.public"` | P1 |
| 7 | `security/FunctionGuardInterceptor.java:56-62` | class javadoc "Fail closed, but only inside GUARDED" | **YES** — becomes incomplete without the escape hatch documented | P1 |
| 8 | `security/FunctionGuardInterceptor.java:64-65` | class javadoc SDR paragraph — the ONE wrong site this plan corrects (§3.7) | **YES** | P1 |
| 9 | `security/FunctionGuardInterceptor.java:145` | `return false` on the deny path (`:146` is the closing brace) | No change | — |
| 10 | `security/FunctionGuardInterceptor.java:162-165` | `wms2.authz.denied{controller,function,reason}` increment, inside `deny(…)` | No change; the new reason tag flows through it | P1 |
| 11 | `security/FunctionGuardStartupAssertion.java:69-70` | 1-arg `findUnannotatedGuardedHandlers(handlers)` — delegates to the 2-arg with `FunctionGuardInterceptor.GUARDED` | No direct edit | — |
| 12 | `security/FunctionGuardStartupAssertion.java:86-87` (signature; `:73-85` is its javadoc) | **2-arg overload** — the real implementation, guarded set as a parameter "so the violation branch is testable" | **YES** — `@PublicHandler` must satisfy the requirement here. ⚠️ **`:94-97` carries the SAME reassign-in-place class-level fallback as `preHandle:119-122`** — see §3.4.1; a conflict check keyed on the reassigned `annotation` fails every replica's boot | P3 |
| 13 | `security/FunctionGuardStartupAssertion.java:53-58` | `violations` → `IllegalStateException`, message text | **No edit — but read §3.4.1 before touching #12.** This does **not** fire for the two markered reads absent the P3 change (`:96`'s class-level fallback resolves them). It fires if `GUARDED` gains `UserController` **without** the type-level annotation, or if the P3 conflict check is mis-keyed | P3 |
| 14 | `security/FunctionGuardStartupAssertion.java:60-61` | `LOG.info("Function-gating startup assertion passed: {} deployed handlers checked, {} guarded controllers", …)` | **YES** — extend to enumerate the open set (§3.5) | P3 |
| 15 | `security/FunctionGuardStartupAssertion.java:40-50` | `ObjectProvider<RequestMappingHandlerMapping>` injection + `getHandlerMethods()` walk | No change | — |
| 16 | `security/RequiresFunction.java:45-48` | `@Target({TYPE, METHOD}) @Retention(RUNTIME)` | No change — the new annotation is a sibling, not an edit | — |
| 17 | `security/RequiresFunction.java:50-55` | `String[] value()` + "empty array denies fail-closed" | No change; it is **the reason** a reserved value cannot express "public" (see #19) | — |
| 18 | `security/RequiresFunction.java:9-16` | resolution-order javadoc | **YES** — point at the new sibling (§3.8) | P1 |
| 19 | `security/AccessDecision.java:23-43` | `enum Reason` — 4 constants, each with a metric tag | **YES** — add `CONFLICTING_ANNOTATIONS("conflicting_annotations")`. Verified safe: no test enumerates `Reason.values()` | P1 |
| 20 | `service/AccessService.java:134-140` | `checkAnyAccess` — empty/null `functions` → `deny(MISSING_FUNCTION, null)` | No change; cited as the rationale for a **separate** annotation | — |
| 21 | `WebConfig.java:33-36` | `registry.addInterceptor(guard).addPathPatterns("/**")` | No change (registration is SBDEV-3017's axis) | — |
| 22 | `controller/UserController.java:31-33` | `@Tag` / `@RestController` / `@RequestMapping("/v3/user")` | **YES** — type-level `@RequiresFunction` goes here | P2 |
| 23 | `controller/UserController.java:34-59` | 24-line block comment arguing the controller **cannot** be guarded | **YES** — becomes false; must be rewritten (§3.8) | P2 |
| 24 | `controller/UserController.java:164-173` | `isWmsUser(String, Principal)` — arity 2, ungated | **YES** — `@PublicHandler` site 1 | P2 |
| 25 | `controller/UserController.java:479-483` | `getAllRoles(String)` — arity 1, ungated | **YES** — `@PublicHandler` site 2 | P2 |
| 26 | `controller/UserController.java:146,176,222,282,362,414,470,485,494` | the **9** method-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` | **YES — DELETE all 9.** Ruling in §9.3.2 | P2 |
| 27 | `controller/UserController.java:134-143` | `denyUnlessUserManagementAllowed()` in-method guard, called first-statement by all 9 gated handlers | **No change** — this is what preserves the per-method record after #26, and it is defence-in-depth | — |
| 28 | `controller/UserController.java:81-94` | ctor: 7 params, `super(keycloakService, maxPageSize)` | No change; **relevant** — null-safe, so the reflective `instantiate()` fixture recipe works (§6.1) | — |
| 29 | `controller/AdminController.java:41-46` | base ctor, null-safe; base class for **43** controllers | No change — and it must **never** carry `@PublicHandler` (§3.6 rail 1) | — |
| 30 | `controller/StockUnitController.java:69-72` **and `:166`** | comment "would fail closed on ~40 endpoints" — **the figure is wrong; the real number is 3 at `e44e972`** | **YES — comment-only correction, 5 sites** (§3.7) | P5 |
| 31 | `controller/UserRoleController.java:39-40`, `controller/UserGroupController.java:46-47` | class-level-only `@RequiresFunction`, **zero** method-level | No change — this is the **established pattern** the §9.3.2 ruling follows | — |
| 32 | `Authority.java:90` | `AUTHZ_DENIED_HEADER` javadoc "emitted by FunctionGuardInterceptor and nowhere else" | No change — the public path emits no header | — |
| 33 | `RestConfiguration.java:36-38`, `WebConfig.java:29-30`, `RequiresFunction.java:37-38`, `controller/mobile/ReplenishController.java:64-65`, `repo/jpa/FixLocationAssignmentRepository.java:27-28` | the **other five** `src/main` sites carrying the wrong SDR assertion | **OUT OF SCOPE** — pointer to SBDEV-3017 only (§3.7) | — |
| 34 | `src/main/resources/db/audit-access-invariants.sql:487,511` | SET-11 prose citing G-1/G-2 and GUARDED | No change (about `controller/rest`, untouched) | — |
| 35 | *(new file)* `security/PublicHandler.java` | the marker annotation | **YES — new** | P1 |

### 0.B — Tests

| # | File:line | Construct | Verdict | Phase |
|---|---|---|---|---|
| 36 | `unit/config/FunctionGuardArchTest.java:70-99` | `GOLDEN_MAP` — 13 entries | **YES** — add `UserController → WEB_UI_VIEW_USER_MANAGEMENT` | P4 |
| 37 | `FunctionGuardArchTest.java:218` | AC-1 `@DisplayName("… the 13 guarded controllers …")` | **YES** — text only, 13 → 14 | P4 |
| 38 | `FunctionGuardArchTest.java:219-233` | AC-1 `everyGuardedControllerCarriesRequiresFunction` | **RED at gate time**; satisfied by the type-level annotation | P4 |
| 39 | `FunctionGuardArchTest.java:237-251` | AC-2 golden-map equality | **RED at gate time**; same remedy | P4 |
| 40 | `FunctionGuardArchTest.java:255-286` | AC-3 every value is a declared `FunctionEnum` constant | Auto-satisfied — `WEB_UI_VIEW_USER_MANAGEMENT` is declared | — |
| 41 | `FunctionGuardArchTest.java:102-108` | `SHARED_CONTROLLERS` — 4 entries | **NO** — `UserController` must not be added | — |
| 42 | `FunctionGuardArchTest.java:316-351` | `REVIEWED_SHARED_METHOD_GATES` — 15, name-keyed | No change | — |
| 43 | `FunctionGuardArchTest.java:333-336`, `:360` | prose "the interceptor resolves a method-level annotation before it consults that set" — still true, now incomplete | **YES** — stale-comment sweep (§3.8) | P5 |
| 43b | `FunctionGuardArchTest.java:69` | `GOLDEN_MAP` javadoc — *"The **eleven** guarded controllers"*, already wrong at 13 | **YES** — §3.8 row 7 | P4 |
| 43c | `FunctionGuardWiringUnitTest.java:66` | `EXPECTED_GUARDED` javadoc — *"The **eleven** controllers §3.1-A5 gates"* | **YES** — §3.8 row 8 | P4 |
| 43d | `FunctionGuardInterceptor.java:77` | `GUARDED` javadoc — *"The **eleven** controllers whose handlers must carry an annotation"* | **YES** — §3.8 row 6 | P2 |
| 43e | `FunctionGuardStartupAssertion.java:73-85` | 2-arg overload javadoc — *"once every one of the **eleven** controllers carries a class-level default"*; also the right home for §3.4.1's keying rule | **YES** — §3.8 row 9 | P3 |
| 44 | `FunctionGuardArchTest.java:491-494` | `REVIEWED_METHOD_LEVEL_OVERRIDES` — 3 entries, key `SimpleClassName#methodName`, **no arity** (produced at `:606`) | **UNTOUCHED under the §9.3.2 ruling.** Would need +9 entries and the `Set.of` >10-arg workaround if the 9 were kept | P4 |
| 45 | `FunctionGuardArchTest.java:517-557` | `REVIEWED_SHARED_GATE_FUNCTIONS` — 15, key `Class#method/arity` | No change — but it is the **format model** for the new allow-list | P4 |
| 46 | `FunctionGuardArchTest.java:365-400` | G-1 `noRestControllerCarriesRequiresFunction`; non-vacuity at `:395` is keyed on **`scanned`** | No change — it is the correct non-vacuity model for the new test (§3.6) | — |
| 47 | `FunctionGuardArchTest.java:402-421` | G-2 `noRestControllerIsInTheGuardedSet` | **GREEN — verified.** `:412` filters `controller.rest.`; `:417-420` names only `StockUnitController`/`UnitLoadController` | — |
| 48 | `FunctionGuardArchTest.java:423-471` | AC-4 `noSharedControllerCarriesRequiresFunction` | **GREEN** — iterates `SHARED_CONTROLLERS` | — |
| 49 | `FunctionGuardArchTest.java:596-624` | **AC-4b** `guardedControllersCarryOnlyReviewedMethodLevelOverrides` | **GREEN under the §9.3.2 DELETE ruling** (UserController contributes 0 method-level entries). Would be **RED with 9 unexpected entries** if the 9 were kept | P4 |
| 50 | `FunctionGuardArchTest.java:626-634` | AC-5 `adminControllerCarriesNoRequiresFunction` | **GREEN** — add the `@PublicHandler` twin (§3.6 rail 1) | P4 |
| 51 | `FunctionGuardArchTest.java:647-665` | AC-26 no `@PreAuthorize` on a GOLDEN_MAP controller, class or **declared** method | **GREEN — verified.** `UserController` declares zero `@PreAuthorize`; the 9 inherited `AdminController` ones are not in `getDeclaredMethods()` | — |
| 52 | `FunctionGuardArchTest.java:112-152` | reflective helpers `type/annotationType/guardedController/functionsOn` | Reuse for the new allow-list test | P4 |
| 53 | ~~`FunctionGuardArchTest.java:31-34`~~ → **`unit/security/FunctionGuardInterceptorUnitTest.java:85`** | the third real `~40` site. **r1 cited `FunctionGuardArchTest:31-34`, which is `import` statements and contains no such figure**, and missed this one entirely | **YES — comment-only correction** to 4 (§3.7a) | P5 |
| 54 | `FunctionGuardArchTest.java:824-841` | Flyway `V2.2.18` pin | No change (no migration in this plan) | — |
| 55 | `unit/security/FunctionGuardWiringUnitTest.java:67-74` | `EXPECTED_GUARDED` — 13, deliberately duplicated | **YES** — add `UserController.class` | P4 |
| 56 | `FunctionGuardWiringUnitTest.java:226-234` | `guardedSetIsExactlyTheEleven` — `containsExactlyInAnyOrderElementsOf` | **RED** until #55 | P4 |
| 57 | `FunctionGuardWiringUnitTest.java:236-259` | `interceptorAndStartupAssertionShareOneGuardedSet` — same equality at `:258` | **RED** until #55 | P4 |
| 58 | `FunctionGuardWiringUnitTest.java:227` | `@DisplayName("… thirteen controllers …")` | **YES** — text, 13 → 14 | P4 |
| 59 | `FunctionGuardWiringUnitTest.java:94-103` | `guardedRequestMappingPrefixes()` — **throws** if a guarded controller has no `@RequestMapping` value | **GREEN** — `UserController:33` has `/v3/user` | — |
| 60 | `FunctionGuardWiringUnitTest.java:127-153` | `guardMatchesAPathOnEveryGuardedController` — probes `/v3/user/probe` | **GREEN** (`/**` matches) | — |
| 61 | `FunctionGuardWiringUnitTest.java:105-185` (`@Nested Registration`) | the three registration pins | No change — **this is SBDEV-3017's territory**; do not touch | — |
| 62 | `FunctionGuardWiringUnitTest.java:242-250` | records the un-closed fail-closed-branch blind spot as "item 5 of §14.19's fix list" | **YES** — update the note to say `@PublicHandler` did not close it either (§3.4) | P4 |
| 63 | `unit/security/FunctionGuardStartupAssertionUnitTest.java:36-40` (`ForgotTheAnnotationController`, **no class-level annotation**) and `:42-47` (`AnnotatedController`, **carries `MOBILE_UI_VIEW_PICKING`**) | the two existing fixtures | **YES — additive, and WHICH ONE matters.** The `@PublicHandler` methods for AC-5a/AC-5c must go on a fixture **carrying a class-level `@RequiresFunction`** — i.e. extend `AnnotatedController`. On `ForgotTheAnnotationController` a mis-keyed boot conflict check is green (§3.4.1) | P3 |
| 64 | `FunctionGuardStartupAssertionUnitTest.java:58-94` | 3 fixture-driven tests via the 2-arg overload | Additive only — none goes red | P3 |
| 65 | `FunctionGuardStartupAssertionUnitTest.java:96-106` | `theRealGuardedSurfaceIsFullyAnnotated` — 1-arg | **GREEN** once #12 lands | P3 |
| 66 | `unit/security/FunctionGuardInterceptorUnitTest.java:66` | `new FunctionGuardInterceptor(accessService, ObjectMapper, meterRegistry)` — **3-arg** | Arity unchanged (§3.9) | — |
| 67 | `FunctionGuardInterceptorUnitTest.java:81-120` | method-level-before-GUARDED ordering pins | **GREEN** — and they are the pins the new branch must not disturb | P1 |
| 68 | `FunctionGuardInterceptorUnitTest.java:122-132` | `handler(Class, String)` helper — **name-only**, `findFirst()`, bare `Object` bean | Reuse. Safe here: `UserController` has 11 distinct handler names, no overloads | P1 |
| 69 | `FunctionGuardInterceptorUnitTest.java:274-296` | AC-6 alias case — the bean must be a **real** guarded controller, not `Object` (mutation-proven at `:282-285`) | Same trap applies to any new alias test | — |
| 70 | `unit/controller/mobile/FunctionGuardMockMvcUnitTest.java:83-96` | `setUpGuard()` + reflective `instantiate()` | **Reuse — this is the §6.1 recipe** | P1 |
| 71 | `FunctionGuardMockMvcUnitTest.java:98-144` | deny-all / allow-all loops, throw-means-allowed idiom at `:132-136` | Reuse the idiom | P1 |
| 72 | `FunctionGuardMockMvcUnitTest.java:176-193` | `requiredFunctions(InvocationOnMock)` varargs unwrapper | Reuse verbatim | P1 |
| 73 | `FunctionGuardMockMvcUnitTest.java:55-81` | `SURFACE` map — 11 **mobile** controllers | **NO** — `UserController` is not added here | — |
| 74 | `common/base/BaseControllerUnitTest.java:50-52`, `:66-75` | `setupMockMvc` — **installs NO interceptor** | **Must not be used** for any gate assertion (§6.1) | — |
| 75 | `common/base/BaseControllerUnitTest.java:95`, `:101` | `setupMockMvcWithGuard(Object, HandlerInterceptor)` → `.addInterceptors(interceptor)` | **This is the only non-vacuous MockMvc gate lane** | P1 |
| 76 | `unit/security/UserAdminFunctionGateUnitTest.java:197-204` | `3-3 bothControllersAreGuarded` — `.contains(…)` | **GREEN** — containment, not equality | — |
| 77 | `UserAdminFunctionGateUnitTest.java:211-216` | `productionGuardedSet()` reflective reader | Reuse pattern | P4 |
| 78 | `unit/security/ActionGuardAnnotationContractUnitTest.java:187-202` | F1 `gatedControllersAreNotAddedToTheGuardedSet` — `.doesNotContain(StockUnitController, UnitLoadController)` | **GREEN** — names only those two | — |
| 79 | `ActionGuardAnnotationContractUnitTest.java:29-35` | javadoc citing the false "~40 endpoints" | **YES — comment-only correction** (§3.7) | P5 |
| 80 | `unit/controller/UserControllerUnitTest.java:87-134` | `setUp()` — `setupMockMvc(userController)` at `:107`, **no interceptor** | No change; but no new gate AC may live in this fixture | — |
| 81 | `UserControllerUnitTest.java:967-1002` | `everyWriteHandlerIsGated` + `OPEN_BY_DESIGN` (`:979-982`), mapping predicate (`:987-988`), assertion (`:996-1001`) | **RED under the DELETE ruling** — and it is being rewritten regardless (§3.6 rail 4) | P5 |
| 82 | `UserControllerUnitTest.java:970-982` | comment "which this controller cannot have" | **YES** — stale-comment sweep (§3.8) | P5 |
| 83 | `UserControllerUnitTest.java:856-965` | the 6 `assertThatThrownBy(… AccessDeniedException)` deny tests, direct invocation | **GREEN** — they exercise `denyUnlessUserManagementAllowed()` (site #27), not the annotation | — |
| 84 | `UserControllerUnitTest.java:1004-1016` | `grantedCallerIsNotBlocked` | **GREEN** — same reason | — |
| 85 | `unit/controller/StockUnitControllerActionGuardUnitTest.java:116`, `unit/controller/UnitLoadControllerActionGuardUnitTest.java:87` | 3-arg interceptor constructions | No change | — |
| 86 | `unit/config/SdrWriteExposureUnitTest.java:36-37`, `:109` | SDR-bypasses-the-interceptor pins | **OUT OF SCOPE** — SBDEV-3017 | — |

**Every direct `new FunctionGuardInterceptor(…)` — 6 sites, all 3-arg:** `FunctionGuardInterceptorUnitTest:66`,
`FunctionGuardWiringUnitTest:77`, `FunctionGuardMockMvcUnitTest:85`, `UserAdminFunctionGateUnitTest:99`,
`StockUnitControllerActionGuardUnitTest:116`, `UnitLoadControllerActionGuardUnitTest:87`. See §3.9.

### 0.C — `UserController` handler inventory (11 declared, verified)

| Method | Line | Arity | Verb / path | Gated today | After this plan |
|---|---|---|---|---|---|
| `checkKeycloakUser` | 148 | 2 | POST `/getKeycloakUser` | method-level | class-level |
| **`isWmsUser`** | **165** | **2** | GET `/isWmsUser/{username}` | **no** | **`@PublicHandler`** |
| `importUser` | 178 | 2 | POST `/importUser` | method-level | class-level |
| `createUser` | 224 | 2 | POST `/create` | method-level | class-level |
| `updateUser` | 284 | 2 | POST `/update` | method-level | class-level |
| `delet` | 364 | 2 | GET `/delete/{userId}` (mutating GET) | method-level | class-level |
| `saveUserGroups` | 416 | 2 | POST `/saveUserGroups` | method-level | class-level |
| `userDetailsById` | 472 | 1 | GET `/userDetailsById/{id}` | method-level | class-level |
| **`getAllRoles`** | **480** | **1** | GET `/getAllRoles/{username}` | **no** | **`@PublicHandler`** |
| `getUserDetails` | 487 | 0 | GET `/getDetails` | method-level | class-level |
| `bulkEditUsers` | 496 | 2 | POST `/bulkEditUsers` | method-level | class-level |

No overloaded names on the class.

### 0.D — UI call sites (verified, untruncated grep across both UIs' `store/ components/ pages/ plugins/`)

| # | File:line | Endpoint |
|---|---|---|
| 1 | `wms2-web-ui/store/index.js:83` | `isWmsUser` |
| 2 | `wms2-web-ui/store/index.js:94` | `getAllRoles` |
| 3 | `wms2-mobile-ui/store/index.js:76` | `isWmsUser` |
| 4 | `wms2-mobile-ui/store/home.js:106` | `getAllRoles` |

**Exactly four HTTP call sites. No UI change is in this plan.** Other grep hits are Vuex
state/mutation/getter names of the same spelling, not calls.

---

## 1. Problem Statement

`UserController` is the user-administration write surface of wms2-api — it creates, updates, deletes and
bulk-edits WMS users and their group memberships. It is **not** a member of
`FunctionGuardInterceptor.GUARDED` (`FunctionGuardInterceptor.java:80-96`), so a handler added to it
without `@RequiresFunction` ships **open**: the interceptor resolves no annotation, sees the declaring
class is outside the guarded set, and returns `true` at `:126`.

That is not hypothetical. SBDEV-2870 left three write endpoints on this class ungated and nothing failed —
`UserControllerUnitTest:988-991` records it. SBDEV-2984 then gated nine handlers but left two reads open
and could not close the runtime hole. Its own class comment (`UserController.java:34-59`) states why:

> GUARDED membership makes an UNANNOTATED handler on the declaring class fail CLOSED. That is the property
> we want … It is not available yet, because two handlers on this class must stay open and there is no
> annotation value meaning "public".

The two handlers are the UI bootstrap reads:

* `GET /v3/user/isWmsUser/{username}` (`UserController:164-173`) — the "are you a WMS user at all" probe.
* `GET /v3/user/getAllRoles/{username}` (`UserController:479-483`) — **how both UIs load the caller's own
  function set.**

#### Why these two cannot be gated — stated precisely, because the obvious argument is false

> ⚠️ **The claim "gating `getAllRoles` is circular because the answer IS the caller's function set" is FALSE
> against the code as written — and it is already in the tree twice** (`UserController:44-49`,
> `UserControllerUnitTest:981-982`). Do not propagate it a third time into a mandatory
> `@PublicHandler(reason=…)`: freezing a false justification into the one mechanism whose purpose is to make
> the justification reviewable is worse than having no annotation at all.

Verified signatures at `origin/develop`:

```java
UserController:479-480   public List<String> getAllRoles(@PathVariable("username") String username)
                         // no principal at all — an arbitrary username
UserController:164-165   public Boolean isWmsUser(@PathVariable("username") String username,
                                                  @AuthenticationPrincipal Principal principal)
                         // `principal` is declared and NEVER READ in the body (:166-172)
UserRepository:29-37     native query "… where u.name = :username"
```

Neither handler is scoped to the caller. A function gate on them is therefore **not circular today** —
because they do not answer "what may *I* do", they answer "what may *anyone you name* do".

**The circularity argument holds for the *intended* semantics, not the current signature.** Once these are
scoped to the principal — which is what both UIs actually use them for, and what they should be — the gate
becomes genuinely circular: you would have to already be known to hold function X in order to be permitted
to discover which functions you hold. Scoping them is the cheapest permanent fix and would make the
`reason()` strings airtight; it is **not** in this plan's scope (§8.3).

**The practical conclusion is unchanged, and it does not depend on the circularity claim at all.** Three
facts, each independently sufficient:

1. **Both UIs call these as bootstrap requests**, before any menu renders (§0.D, four call sites).
2. **61 of 99 users on `wms2-wineco-dev` hold no user-management function** — gating on
   `WEB_UI_VIEW_USER_MANAGEMENT` locks out 62% of the user base at login.
3. **Zero functions is a legitimate provisioned state.** `AccessService:152-157` distinguishes
   `USER_NOT_PROVISIONED` from `NO_FUNCTIONS` precisely because a real `mywms_user` row with an empty
   function set exists. That user must still boot to an empty menu, and passes **no ANY-of set of any
   size**. Widening the list relocates the cut point; it never reaches this user.

**Consequence for implementation (binding):** the two `reason()` strings must state the *actual* scope. The
required shape is in §3.3. A `reason()` reading "loads the caller's own function set — gating it is
circular" is **rejected at review**.

**Measured blast radius of getting this wrong.** On `wms2-wineco-dev`: **99 users, 38 hold
`WEB_UI_VIEW_USER_MANAGEMENT`, 61 would lose bootstrap.** And they would lose it *silently* — the client
error paths swallow the 403:

* `wms2-mobile-ui/store/home.js:104-119` — `setMenus` catches, so `pageList` is never committed. The mobile
  home screen renders **zero tiles** with the toast *"Request failed due to a network or server issue.
  Please retry."*
* `wms2-web-ui/store/index.js:92-100` — `getUserRoles` catches and returns `undefined`.
* `wms2-web-ui/store/index.js:81-90`, `wms2-mobile-ui/store/index.js:74-83` — `isWmsUser` catches, leaving
  `state.isWmsUser` at its initial `false`.

A 403 presented to the operator as a network fault, on an empty screen. That is the exact silent-failure
shape `FunctionGuardInterceptor:157-166` was rewritten to prevent.

**So the problem is a missing vocabulary item.** There is no way to say "this handler is deliberately
reachable without a function", so the whole class is left outside the runtime mechanism and the only
protection is a build-time reflection test with four escape hatches (§2.3). This plan adds the vocabulary
item.

### 1.1 ⚠️ What this change actually delivers — and what it does NOT

> **Runtime fail-closed for `UserController` is NOT what this change delivers.** The chain, stated precisely
> — r2 got the conclusion right and the reason wrong, and r3 corrects the reason:
>
> 1. **This plan chooses** to add `UserController` to `GOLDEN_MAP` (§5.2 P4). That is a decision, not a
>    constraint: `GOLDEN_MAP` (`FunctionGuardArchTest:70-99`) is hand-maintained, `GUARDED` is pinned
>    separately by `EXPECTED_GUARDED` (`FunctionGuardWiringUnitTest:67-74`), and **no test compares the two
>    sets in either direction** — `git grep -n GOLDEN_MAP -- src/test` returns hits only inside
>    `FunctionGuardArchTest`, whose only `GUARDED` reader is G-2's `controller.rest.` package filter
>    (`:403-413`). A class can sit in `GUARDED` and be absent from `GOLDEN_MAP` with the whole suite green.
> 2. `GOLDEN_MAP` membership **does** require a class-level `@RequiresFunction` — AC-1 (`:219-233`) verified.
> 3. A class-level annotation makes `preHandle`'s `annotation == null` branch (`:124-133`) **unreachable for
>    `UserController`**. The repo already says this in plain English at `FunctionGuardWiringUnitTest:242-250`.
>
> So the trade is real and it is **this plan's own**, not the codebase's. §9.3.4 records it as such.

A future handler #12 added to `UserController` without any annotation therefore **inherits
`WEB_UI_VIEW_USER_MANAGEMENT` from the class**. It does not 403. It is open to the 38 admins, and if it
needed a *different* function it ships silently wrong — the exact failure `REVIEWED_METHOD_LEVEL_OVERRIDES`'s
javadoc (`FunctionGuardArchTest:476-489`) exists to name.

**What the change does buy — and it is worth buying:**

| # | Property | Delivered by |
|---|---|---|
| 1 | **Default-to-admin-function** for every future handler on `UserController`, replacing today's **ship-open**. Today handler #12 is reachable by all 99 users and by anyone authenticated; after this change it is reachable by 38. That is the substantive win | the **type-level `@RequiresFunction` alone** |
| 2 | **A deletion tripwire.** With the nine method-level annotations deleted, removing the class-level annotation makes all 9 writes unannotated-on-guarded → runtime 403 **and** boot failure **and** AC-1/AC-2 red. This is the one place `GUARDED` membership earns its keep | `GUARDED` membership + §9.3.2's DELETE ruling |
| 3 | **A build-time tripwire for handler #12.** AC-8a pins the request-mapped declared-handler count at **exactly 11**, so a 12th handler reds `everyWriteHandlerIsGated` and forces a deliberate edit naming the new handler. Build-time only — there is no CI on PRs — so it is weaker than a runtime gate, but it is the same layer option C offered and it survives the DELETE ruling | AC-8a |
| 4 | **`@PublicHandler` is load-bearing for (1).** Without the marker, the type-level annotation 403s 61 of 99 users at login. The marker is what makes (1) shippable at all | this plan |
| 5 | A **greppable, boot-logged, metered, allow-listed** vocabulary for "deliberately open", reusable by SBDEV-3017's bootstrap/identity class and by any future case | §3.1, §3.5, §3.6 |

**Residual risk, accepted and named:** handler #12 needing a *different* function ships silently wrong,
caught only by AC-8a's count pin at build time. Closing that would mean omitting `UserController` from
`GOLDEN_MAP` and dropping the class-level annotation — the shape in §9.3.4, which costs more than it buys for
this class.

---

## 2. Current Architecture

### 2.1 The three layers of the function gate

| Layer | Component | What it enforces | When it fires |
|---|---|---|---|
| Runtime | `FunctionGuardInterceptor.preHandle` (`:110-146`) | resolves `@RequiresFunction` (method → class), calls `AccessService.checkAnyAccess`, allows or 403s; **fail-closed** for an unannotated handler on a GUARDED class (`:124-133`) | every MVC request |
| Deploy | `FunctionGuardStartupAssertion.afterSingletonsInstantiated` (`:46-62`) | walks the **deployed** handler surface via `RequestMappingHandlerMapping.getHandlerMethods()` and throws `IllegalStateException` (`:54-58`) if any GUARDED handler is unannotated | every boot, every replica |
| Build | `FunctionGuardArchTest` (13 golden-map controllers), `FunctionGuardWiringUnitTest`, per-controller contract tests | golden-map equality, no-drift allow-lists, no `@PreAuthorize` on a gated class | `mvn test` |

The critical property is that **membership in `GUARDED` is the switch** for the fail-closed behaviour.
Outside the set, an absent annotation is silently an allow.

### 2.2 Why resolution keys on the declaring class, and why that bounds the cost

`FunctionGuardInterceptor:118` — `handlerMethod.getMethod().getDeclaringClass()`. The javadoc at `:49-54`
explains: `AdminController` is a base class for **43** controllers, so its methods register under 43
class-level prefixes (~90 alias URLs). Keying on `getBeanType()` would make an inherited method inherit the
subclass's function. Keying on the declaring class resolves such a method to `AdminController`, which is
unannotated and unguarded, so it falls through untouched.

**Consequence:** adding a class to `GUARDED` only ever affects handlers **declared on** that class. For
`UserController` that is 11 handlers, of which 9 are already gated — so **2** handlers change behaviour, not
40. (This is also why the "~40 endpoints" figure in three comments is wrong; see §3.7.)

### 2.3 The build-time stand-in, and its four escape hatches

`UserControllerUnitTest.everyWriteHandlerIsGated` (`:967-1002`) is a genuine deny-list — it enumerates
declared handlers and requires an annotation unless allow-listed. It is the best available today, and it is
still not equivalent to runtime fail-closed:

1. **It needs someone to run the build.** Merging to wms2 `develop` is branch-push driven with **no CI on
   PRs**. The startup assertion fails the *deploy*; the test fails only if a human runs `mvn test`.
2. **It reads the classpath, not the deployed surface.** `getDeclaredMethods()` cannot see a handler
   registered by any route its annotation predicate does not recognise. The predicate at `:987-988` is
   `a.annotationType().getSimpleName().endsWith("Mapping")` — a composed annotation (`@AuditedPost`,
   `@TenantScopedGet`) is registered by Spring and invisible here.
3. **`OPEN_BY_DESIGN` is name-keyed with no arity** (`:979-982`, matched at `:990`). A `getAllRoles(String,
   String)` overload inherits the exemption silently. This shape is *measured*, not hypothetical:
   `FunctionGuardArchTest:433-439` records a new annotated `removeLock` overload at arity 3 passing the
   whole suite against a name-only key.
4. **It is vacuous on an empty scan.** It builds `ungated` and asserts it empty; if the mapped-method scan
   ever yields nothing it is green while inspecting nothing. There is no `assertThat(scanned).isNotEmpty()`
   anywhere in the method — unlike its siblings `FunctionGuardArchTest:613-615` and
   `ActionGuardAnnotationContractUnitTest:88-107`.

It is also scoped to *this class*: a new `UserBootstrapController` is invisible to it.

### 2.4 Why a reserved `@RequiresFunction` value cannot express "public"

`AccessService.checkAnyAccess:134-140`:

```java
if (functions == null || functions.length == 0) {
    // An unannotated-but-guarded handler reaches here. Fail closed.
    return AccessDecision.deny(AccessDecision.Reason.MISSING_FUNCTION, null);
}
```

The empty array is **already taken** and it means the opposite of "public". Re-purposing
`@RequiresFunction({})` as an open sentinel requires editing that branch — and that branch has a second
caller: it is the fail-closed path for a guarded unannotated handler. One edit, two behaviours, one of them
silently reopened. **The marker must be its own annotation type.**

### Affected Locations

See §0 for the full enumeration. The eight files that change:

| # | File | Lines | Description |
|---|---|---|---|
| 1 | `src/main/java/net/aim_ai/wms/security/PublicHandler.java` | new | the marker annotation |
| 2 | `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java` | `56-65`, `73-74`, `80-96`, `118-122` | javadoc, metric constant, GUARDED += `UserController`, the marker block |
| 3 | `src/main/java/net/aim_ai/wms/security/AccessDecision.java` | `23-43` | `+ CONFLICTING_ANNOTATIONS` |
| 4 | `src/main/java/net/aim_ai/wms/security/FunctionGuardStartupAssertion.java` | `60-61`, `86-103` | honour the marker; enumerate the open set at boot |
| 5 | `src/main/java/net/aim_ai/wms/security/RequiresFunction.java` | `9-16` | javadoc pointer to the sibling |
| 6 | `src/main/java/net/aim_ai/wms/controller/UserController.java` | `31-59`, `146…494`, `164`, `479` | type-level annotation, comment rewrite, delete 9, add 2 markers |
| 7 | `src/main/java/net/aim_ai/wms/controller/StockUnitController.java` | `69-72` | comment-only: `~40` → `4` |
| 8 | test files per §0.B | | |

---

## 3. Design / Proposed Fix

**Option B is locked** (marker annotation on the existing controller). A and C are recorded in §9.3.2 with the
reasoning; do not re-litigate them here.

### 3.1 The marker annotation

New file `src/main/java/net/aim_ai/wms/security/PublicHandler.java`:

```java
package net.aim_ai.wms.security;

/**
 * Marks a handler as deliberately reachable without any function grant.
 *
 * <p>METHOD-level only, by construction. A class-level "public" would open a whole controller with one
 * token, and because {@link FunctionGuardInterceptor} resolves on the DECLARING class, one such token on
 * {@code AdminController} would open a method under all 43 of its subclasses' prefixes at once.
 * {@code @Target(METHOD)} makes that unwritable rather than merely forbidden.
 *
 * <p><b>{@code reason()} has no default.</b> An unexplained marker is a compile error, the same trick
 * {@link RequiresFunction} uses to make a renamed function a compile error rather than a silent false.
 *
 * <p>Mutually exclusive with {@link RequiresFunction} on the same method: a handler carrying both is
 * DENIED with {@link AccessDecision.Reason#CONFLICTING_ANNOTATIONS}, not silently resolved one way.
 *
 * <p><b>Does not generalise to Spring Data REST.</b> This is a source annotation on a handler we own; the
 * SDR surface has no handlers we own (they live inside {@code spring-data-rest-webmvc}). SBDEV-3017 needs
 * a path/domain-type allow-list, not this marker.
 */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface PublicHandler {

    /** Why this handler is deliberately open. Mandatory — no default. */
    String reason();
}
```

### 3.2 🔴 THE DEFECT THIS PLAN EXISTS TO PREVENT — the conflict check must not read the reassigned variable

This is the single most likely way to ship this change and cause an **outage worse than the one it
prevents**. It gets its own subsection because a reviewer who reads only the design summary will write the
bug.

`FunctionGuardInterceptor:118-125` on `origin/develop`:

```java
118: Class<?> declaring = handlerMethod.getMethod().getDeclaringClass();
119: RequiresFunction annotation = handlerMethod.getMethodAnnotation(RequiresFunction.class);  // METHOD-level
120: if (annotation == null) {
121:     annotation = AnnotationUtils.findAnnotation(declaring, RequiresFunction.class);        // CLASS-level
122: }                                                                                          // ← REASSIGNS IN PLACE
123:
124: if (annotation == null) {
125:     if (!GUARDED.contains(declaring)) { return true; }
```

`annotation` is a **single variable reassigned in place** at `:121`. After `:122` the name `annotation` no
longer means "the method-level annotation". Once `UserController` carries a class-level `@RequiresFunction`
(§3.3), for `isWmsUser` and `getAllRoles` it holds the **class-level** value and is **non-null**.

So an implementation that writes the mutual-exclusion rule the natural way —

```java
if (open != null && annotation != null) {   // ❌ WRONG — reads the CLASS-level value
    deny(...);
}
```

— **denies both bootstrap reads for all 99 users.** That is strictly worse than the 61-user outage this
ticket exists to prevent, and it would present to operators as the same silent "network error" on an empty
screen described in §1.

**The rule is not "line N".** It is: *the conflict check must read a separately-captured **method-level**
`RequiresFunction`, never the variable that `:121` reassigns.*

Placing the whole marker block immediately **after `:118`, before `:119`**, is nonetheless the right
instruction — not because position is the bug, but because it makes the mistake *unwritable*: the reassigned
variable does not exist yet at that point. That is a robustness argument for code review, not a testable
one. **A test cannot assert a line number; it asserts AC-2b (§5.3).**

**Exact control-flow sketch — this replaces `:118-122`:**

```java
Class<?> declaring = handlerMethod.getMethod().getDeclaringClass();

// ── @PublicHandler resolves FIRST, before any class-level fallback can shadow the method-level read.
//    METHOD-level only: getMethodAnnotation, never AnnotationUtils.findAnnotation(declaring, …).
PublicHandler open = handlerMethod.getMethodAnnotation(PublicHandler.class);

// Captured ONCE, as its own name. The conflict rule below reads THIS, never the `annotation` variable —
// `annotation` is reassigned to the CLASS-level value a few lines down, and UserController now carries a
// class-level @RequiresFunction, so keying the conflict on it denies both bootstrap reads for all 99 users.
RequiresFunction methodLevel = handlerMethod.getMethodAnnotation(RequiresFunction.class);

if (open != null) {
    if (methodLevel != null) {                       // mutual exclusion, nested INSIDE the marker block
        LOG.error("Handler {}#{} carries both @PublicHandler and @RequiresFunction — denying. The two are "
                        + "mutually exclusive; delete one. @PublicHandler means the handler is deliberately "
                        + "reachable without a function, so a function requirement alongside it is a "
                        + "contradiction, not a narrowing.",
                declaring.getSimpleName(), handlerMethod.getMethod().getName());
        deny(response, AccessDecision.deny(AccessDecision.Reason.CONFLICTING_ANNOTATIONS, null), declaring);
        return false;
    }
    meterRegistry.counter(METRIC_PUBLIC, "controller", declaring.getSimpleName()).increment();
    return true;
}

RequiresFunction annotation = methodLevel;
if (annotation == null) {
    annotation = AnnotationUtils.findAnnotation(declaring, RequiresFunction.class);
}
// …:124-146 unchanged…
```

Four properties this shape has, each of which a reviewer can point at:

1. The class-level fallback is **unreachable** for a `@PublicHandler` handler — the whole point of the ticket.
2. "Both annotations" denies, and it denies for a **distinguishable reason** (§3.4), because the check reads
   `methodLevel` and not `annotation`.
3. Nothing about `:124-146` changes, so the 13 existing `FunctionGuardInterceptorUnitTest` behaviours and the
   method-level-before-`GUARDED` ordering pins at `:81-120` are untouched.
4. `checkAnyAccess` is never called on the public path — one fewer DB round-trip on the two hottest bootstrap
   endpoints, and the `verifyNoInteractions(accessService)` assertion that makes AC-2b non-vacuous.

**The discriminating test fixture.** A fixture controller **without** a class-level `@RequiresFunction`
passes whether or not the conflict check is mis-keyed, because with no class-level annotation `methodLevel`
and `annotation` hold the same value. The fixture must carry it, and both directions must be asserted
against the **same** fixture:

```java
@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_USER_MANAGEMENT)   // ← LOAD-BEARING
static class ClassAnnotatedFixtureController {

    @PublicHandler(reason = "test fixture — the SBDEV-3063 shape")
    public void openRead() { }                       // AC-2b: ALLOWED, accessService untouched

    @PublicHandler(reason = "test fixture — the conflict")
    @RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_USER_MANAGEMENT)
    public void conflicted() { }                     // AC-3a: DENIED, reason CONFLICTING_ANNOTATIONS
}
```

Either assertion alone passes on a broken implementation; the pair does not. **Mutation pin (AC-2d):** swap
`methodLevel` for `annotation` in the conflict condition → `openRead` must start denying → AC-2b goes red.
If it does not, AC-2b is vacuous and the fixture is missing its class-level annotation.

### 3.3 `UserController` joins `GUARDED`

* Add `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_USER_MANAGEMENT)` at **type level** on
  `UserController:31-33`.
* Add `@PublicHandler(reason = …)` to `isWmsUser` (`:164`) and `getAllRoles` (`:479`). **The reason strings
  are binding and are reviewed as security text, not as comments** — see §1's correction. Required shape:

  ```java
  @PublicHandler(reason = "UI bootstrap — called before any menu renders. No function gate can work: a user "
          + "with zero functions is a legitimate provisioned state, so no ANY-of set of any size reaches "
          + "them. NOTE: this handler currently accepts an ARBITRARY username and is not scoped to the "
          + "caller. Scoping it to the principal is the right fix and is NOT done by SBDEV-3063 — see "
          + "that ticket for the open finding.")
  ```

  Three rules for these strings, and they are review-enforced:

  1. **No `file:line` citations and no pointer to a plan document.** The tempting draft cites
     `store/index.js:94`, `store/home.js:106`, `AccessService:152-157` and "61 of 99 on wineco-dev" — but
     `sbdocs/` **is not in git** and this plan moves to `4-Archieves/` on completion, and §0's preamble
     concedes `file:line` rots. This is §3.7's own rule (*"write the number and a pointer, not a name
     list"*) applied to the one string that gets **compiled into production**. Point at the **ticket** —
     the only durable identifier.
  2. **The reason must state the current scope, not the intended one.** A `reason()` asserting "loads the
     caller's own function set — gating it is circular" is **rejected at review**: it is false against the
     signature (§1). The arbitrary-username clause is **mandatory**, not optional — this is the one place a
     future reviewer is guaranteed to look, and the audit that produced this string found the handler leaking
     other users' authorization data (§8.3(b)). A marker that reads "audited and approved" while omitting the
     live finding is worse than no marker.
  3. **The reason must explain why a gate is *impossible*, not why it is inconvenient** (§8.1 scenario 2).
* **Delete** the 9 method-level `@RequiresFunction` (`:146,176,222,282,362,414,470,485,494`). Ruling and
  reasoning in §9.3.2. `denyUnlessUserManagementAllowed()` (`:134-143`), called first-statement by all 9, stays
  — it is the per-method record and defence-in-depth, and `FunctionGuardInterceptor:124`'s javadoc says so.
* Add `UserController.class` to `FunctionGuardInterceptor.GUARDED` (`:80-96`) → **14** members.

#### Sequencing — the coupling is `GUARDED` ↔ the class-level annotation, NOT `GUARDED` ↔ P3

> ⚠️ **`FunctionGuardStartupAssertion:94-97` has the same reassign-in-place fallback as `preHandle`:**
>
> ```java
> 94: RequiresFunction annotation = handler.getMethodAnnotation(RequiresFunction.class);
> 95: if (annotation == null) {
> 96:     annotation = AnnotationUtils.findAnnotation(declaring, RequiresFunction.class);
> 97: }
> 98: if (annotation == null) { violations.add(…); }
> ```
>
> So once `UserController` carries the type-level `@RequiresFunction`, **all 11 handlers resolve it at `:96`,
> the two markered reads included.** `violations` is empty and **the app boots with or without the P3
> change.** ⚠️ Do not reason
> about this check as though `:96` did not exist — that is §3.2's mistake, one file over.

**The split that DOES fail every replica's boot:** `GUARDED += UserController.class` **without** the
type-level `@RequiresFunction`. Then all 11 handlers resolve nothing, `findUnannotatedGuardedHandlers`
returns 11 violations, and `FunctionGuardStartupAssertion:54-58` throws `IllegalStateException` at
`afterSingletonsInstantiated`.

**So the atomicity rule is:** the `GUARDED` addition, the type-level annotation and the two `@PublicHandler`
markers are **one commit**. (The markers ride along because without them the class-level annotation 403s 61
of 99 users at login — a functional outage rather than a boot failure, but shipped in the same breath.)

**P3 is not boot-order-critical. It is future-proofing, and its `@PublicHandler` branch is unreachable in
production after this change** — every `UserController` handler resolves the class default. Its three real
justifications, none of which is boot ordering:

1. **Boot-time conflict detection** (AC-5c) — a handler carrying both annotations should refuse to deploy.
   This one *is* genuine authorization ambiguity and *is* a `throw`.
2. **`findPublicHandlers`** for the boot-log enumeration (§3.5) and the deploy-time hygiene check (§3.6
   Rail 3b-deploy).
3. **Correctness if a marker ever lands on a guarded class with no class-level default** — the shape §9.3.4
   records as the road not taken, and the shape any future guarded-but-defaultless controller would have.

State this in P3's own comment. An implementer working from a false model of *why* a slice exists is how
slices get reordered under pressure.

### 3.4 `FunctionGuardStartupAssertion` honours the marker

Edit the **2-arg overload** (`:86-103` — the 1-arg at `:69-70` merely delegates; the fixture-driven tests all
call the 2-arg). A handler carrying `@PublicHandler` is not a violation. A handler carrying **both** is,
mirroring the runtime rule at boot time (AC-5c).

#### 🔴 3.4.1 — THE §3.2 TRAP EXISTS A SECOND TIME, HERE. Same rule, same words, worse blast radius.

`FunctionGuardStartupAssertion:94-97` reassigns `annotation` in place with the **class-level** value, exactly
as `preHandle:119-122` does:

```java
94: RequiresFunction annotation = handler.getMethodAnnotation(RequiresFunction.class);
95: if (annotation == null) {
96:     annotation = AnnotationUtils.findAnnotation(declaring, RequiresFunction.class);   // ← REASSIGNS
97: }
```

An implementer writing the both-annotations check the natural way — `if (open != null && annotation != null)
violations.add(…)` — reads the **class-level** value for `isWmsUser` and `getAllRoles`, marks **both
bootstrap reads as boot-time violations**, and `FunctionGuardStartupAssertion:54-58` throws
`IllegalStateException` at `afterSingletonsInstantiated`. **Every replica fails to boot simultaneously.**

**The rule, identical to §3.2's:** *the boot-time conflict check must read a separately-captured
**method-level** `RequiresFunction` — `handler.getMethodAnnotation(RequiresFunction.class)`, captured under
its own name — never the variable that `:96` reassigns.* As in `preHandle`, capture `open` and `methodLevel`
**before** the fallback so the reassigned variable does not exist at the point the conflict is decided.

#### 3.4.2 TWO startup fixtures are required, not one — they catch different mutants and neither is optional

> ⚠️ **Both fixtures, not one.** Mandating the class-annotated fixture *instead of* the defaultless one
> deletes coverage silently — it kills pin #7 and makes AC-5a green at the gate and after the fix.

The two fixtures already in `FunctionGuardStartupAssertionUnitTest` sit on opposite sides of this:

| Fixture | Class-level annotation? | What it can observe |
|---|---|---|
| `ForgotTheAnnotationController:36-40` | **no** | **the marker exemption itself.** On a defaultless guarded class, a `@PublicHandler` handler resolves nothing today and IS a violation — so this is the only fixture on which P3's new branch changes anything |
| `AnnotatedController:42-47` (carries `MOBILE_UI_VIEW_PICKING`) | **yes** | **the conflict keying.** On a defaulted class, `annotation` and `methodLevel` diverge — so this is the only fixture on which a mis-keyed check is visible |

Each fixture is blind to the other's mutant. On the class-annotated fixture alone:

* **Pin #7 dies.** "`findUnannotatedGuardedHandlers` ignores `@PublicHandler` again" → `:96` resolves the
  class annotation anyway, no violation, **AC-5a green under the mutant.** The repo's measured *"a sibling
  fix absorbed the mutant"* shape, arriving via a fixture change rather than a code change.
* **AC-5a is green at the P0 gate and after the fix.** The existing test
  `passesWhenTheGuardedControllerIsAnnotatedAtClassLevel` (`:71-81`) already proves the defaulted case passes
  on `origin/develop` with **no P3 change at all** — so §5.2's rule that every behavioural AC fails on an
  assertion would be silently violated.

**So: two criteria, two fixtures.**

| AC | Fixture | Gate colour | Its job |
|---|---|---|---|
| **AC-5a** | `ForgotTheAnnotationController` + a `@PublicHandler` method | **RED at P0**, green after P3 — *the only genuine gate failure P3 has* | pins the exemption; target of mutant **#7** |
| **AC-5a′** | `AnnotatedController` + a `@PublicHandler` method | **green at P0 and after** — mutation-only, say so | pins the conflict keying; target of mutant **#9** |

**And mutant #9's target is AC-5a′, NOT AC-5c** — the pairing with AC-5c cannot fire. Trace
the mutant `if (open != null && annotation != null) violations.add(…)` against each method:

| Fixture method | Correct impl | Under mutant #9 | Discriminates? |
|---|---|---|---|
| `conflicted` — marker **+** method-level `@RequiresFunction` (**AC-5c**) | `methodLevel != null` → violation | `annotation` **is** the method-level value (the fallback never runs) → violation | **NO — identical** |
| `openRead` — marker only, on `AnnotatedController` (**AC-5a′**) | exempt → empty | `annotation` = the **class-level** value → violation | **YES** |

When the method-level annotation is present, `annotation` *is* `methodLevel`, so AC-5c is structurally
incapable of seeing this mutant. **This is the exact vacuity this document exists to police**, and it took
two review rounds to catch — hence the Closeout row requiring each pin's red criterion to be recorded.

The javadoc at `FunctionGuardStartupAssertion:73-85` — the method P3 edits — is the natural place to record
the keying rule in the tree.

`AccessDecision.Reason` gains `CONFLICTING_ANNOTATIONS("conflicting_annotations")` (`AccessDecision.java:23-43`).
Verified safe: **no test enumerates `Reason.values()`** — every test reference is a `deny(Reason.X, …)`
construction or a `.tag("reason", "<literal>")` lookup (`FunctionGuardInterceptorUnitTest:235,255`). Reusing
`MISSING_FUNCTION` would make a conflict indistinguishable from ordinary fail-closed in the log, in the
`reason` body field and in the `wms2.authz.denied{reason=…}` tag — defeating the record's stated purpose
(`AccessDecision.java:5-10`).

`deny(…)` at `AccessDecision.java:72-77` rejects `Reason.ALLOWED` but accepts a null `requiredFunction`, and
`FunctionGuardInterceptor:182-192` already omits both the body field and the `X-Authz-Denied` header when it
is null. So a conflict denial produces a well-formed body with `reason` and no `requiredFunction`, and the
UI's `body.reason` gate (`:174`) still fires.

**Honest statement of a coverage gap (do not paper over it).** `GUARDED` is read directly from a
`static final` field at `FunctionGuardInterceptor:125`; there is **no injectable-set seam**. Once
`UserController` carries a class-level annotation, no real class can produce a guarded-unannotated handler,
so `preHandle`'s fail-closed deny branch (`:128-132`) is **unreachable by any test — and, per §1.1,
unreachable in production too**. That is not merely a testing gap: it is the reason the fail-closed property
is not among the things this change delivers.
`FunctionGuardWiringUnitTest:242-250` already records this as a known open item ("item 5 of §14.19's fix
list"); update that note to say `@PublicHandler` did not close it either. The honest coverage for
fail-closed is `FunctionGuardStartupAssertion`'s **2-arg overload**, whose guarded-set parameter exists for
exactly this reason (`:73-85`). **No MockMvc acceptance criterion in this plan may be worded so as to imply
runtime coverage of that branch.**

### 3.5 Boot-log enumeration, via an extractable seam

`FunctionGuardStartupAssertion:60-61`'s `LOG.info` lives inside `afterSingletonsInstantiated()`, which no test
in this repository invokes (no Spring context; SBDEV-2217). Written inline, the enumeration's correctness is
unassertable and degrades into a grep. Extract:

```java
/**
 * Every @PublicHandler site on the deployed surface, keyed {@code SimpleClassName#method/arity}.
 * Static and pure for the same reason the two-arg findUnannotatedGuardedHandlers seam is (:73-85):
 * afterSingletonsInstantiated() is unreachable without a Spring context, so the CONTENT must be
 * assertable somewhere a unit test can call it.
 */
public static List<String> findPublicHandlers(Collection<HandlerMethod> handlers) { … }

/**
 * The subset of those whose declaring class is NOT guarded — an inert marker reading as audited.
 * Two-arg for the same testability reason as findUnannotatedGuardedHandlers: the guarded set is a
 * parameter so a fixture can produce the offending case. Reported, never thrown (§3.6 Rail 3b-deploy).
 */
public static List<String> findMarkedHandlersOutsideGuarded(Collection<HandlerMethod> handlers,
                                                            Set<Class<?>> guarded) { … }
```

> ⚠️ **The second seam is not optional.** With only `findPublicHandlers`, AC-5d's sole observable is
> *"`afterSingletonsInstantiated` did not throw"* — **identically true if the `LOG.error` was never written
> at all**. The second seam turns AC-5d into a content assertion with mutant **#15** and leaves only the
> one-line log call as a code-review item beside AC-6b.

then:

```java
LOG.info("Function-gating startup assertion passed: {} deployed handlers checked, {} guarded controllers, "
        + "{} annotation-marked handlers open by design (excludes Spring Data REST — see SBDEV-3017): {}",
        deployed.size(), GUARDED.size(), open.size(), open);
```

> ⚠️ **The "(excludes Spring Data REST — see SBDEV-3017)" clause is not decoration.** `findPublicHandlers`
> walks `RequestMappingHandlerMapping` only, and `FunctionGuardStartupAssertion:40`'s
> `ObjectProvider<RequestMappingHandlerMapping>` is structurally blind to `RepositoryRestHandlerMapping`
> (§8.2 point 3). Once SBDEV-3017 makes the guard enforce on SDR, an unqualified *"N handlers open by
> design"* becomes a **false completeness signal** — it would enumerate the annotation-marked set while
> omitting the entire SDR open surface. One string now prevents a wrong operational conclusion later.

Every deploy in every environment prints the open surface. Nobody has to open a file, and it cannot be
silenced without editing the assertion. The extracted function is unit-testable (AC-6a); only the one-line
log call remains uncovered.

### 3.6 Anti-drift rails (1, 2, 3, 3b, 3b-deploy, 4)

> **⚠️ Read this box before writing any of the four rails.** All four run their own reflective scan, and
> **every one of them is a pure negative or an equality over that scan** — the shape that is green when the
> scan finds nothing. r1 put the non-vacuity rule on Rail 3 only; r2 makes it **binding on all four**, and on
> AC-1e, AC-3b, AC-7c and AC-7d individually (§5.3). One shared, pinned, non-empty scan feeds them all.

**Rail 1 — `@PublicHandler` never on `AdminController`.** It is a base class for 43 controllers
(`FunctionGuardInterceptor:49-54`); because resolution keys on `getDeclaringClass()`, one marker there would
open a method under all 43 prefixes (~90 alias URLs) at once.

> ⚠️ **Do NOT mirror `FunctionGuardArchTest:626-634` literally — it would ship a test that cannot fail.**
> That test reads `functionsOn(c)`, the **class-level** annotation, via
> `guardedController("AdminController").ifPresent(...)`. Two independent vacuities if copied:
> **(i)** `@PublicHandler` is `@Target(METHOD)` (§3.1), so a class-level marker on `AdminController`
> **will not compile** — the assertion can never be violated; **(ii)** `ifPresent` asserts *nothing* when the
> class does not resolve, and `:626-634`'s own `@DisplayName` admits it: *"[regression pin — vacuous until
> the annotation exists]"*. Copying that shape ships a structurally unfailable assertion **into the file that
> exists to catch unfailable assertions.**
>
> **Correct shape:** use the **class literal** `AdminController.class` — there is no resolution risk, so drop
> the `guardedController(...)`/`isPresent()` dance entirely (r2 prescribed both, which was dead weight).
> Iterate `AdminController.class.getDeclaredMethods()`, key `name/arity`, and guard non-vacuity with
> `assertThat(AdminController.class.getDeclaredMethods()).isNotEmpty()` — verified real: `AdminController`
> declares handlers at `:80,108,121,134,143,155,176,233,243`. Mutation pin **#10**.

**Rail 2 — `@PublicHandler` never in `net.aim_ai.wms.controller.rest.`.** A marker there is a *no-op* (those
classes are outside GUARDED and unannotated), which is exactly what makes it dangerous: it is a **false
signal of review** — a reader takes it as "deliberately public and audited" when nothing enforces it. Mirror
G-1 (`FunctionGuardArchTest:365-400`) — **but only its method-level half**: the class-level half at `:386-388`
inherits vacuity (i) above. Keep G-1's `assertThat(scanned).isNotEmpty()` (`:395`) and its
`Files.isDirectory(restDir)` check (`:371-373`), or replace both with the Rail 3 scan below. Mutation pin **#11**.

**Rail 3 — the arity-keyed allow-list, with the right non-vacuity guard.** Collect every `@PublicHandler`
site as `Class#method/arity` and assert `containsExactlyInAnyOrder` against a reviewed constant.

> ⚠️ **The scan root must be `net.aim_ai.wms`, whole-tree — r1 never specified one, and "the controller
> tree" is the wrong answer.** Measured on `origin/develop`:
> `git grep -l "@RestController" -- src/main/java | grep -v net/aim_ai/wms/controller/` returns
> **`net/aim_ai/wms/landlord/controller/TenantDiscoveryController.java`**. A `@PublicHandler` there escapes
> Rails 1, 2, 3, 3b and AC-3b **in silence** — an inert marker reading as audited, the precise failure mode
> Rail 2 exists to prevent. AC-7d does not close it either, because AC-7d only sees what the scan sees.
> **A non-vacuity guard on a scan whose root is a guess guards nothing.**
>
> **Use ArchUnit**, already a test dependency at `pom.xml:311-314` (archunit-junit5 1.3.0), and **set
> `DO_NOT_INCLUDE_TESTS`** — this is a repo-wide convention, not a preference:
>
> ```java
> new ClassFileImporter()
>         .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)   // ← LOAD-BEARING
>         .importPackages("net.aim_ai.wms");
> ```
>
> ⚠️ **Omit that option and every new rail reds on this plan's own fixtures.** All five existing ArchUnit
> tests on `origin/develop` set it — `ParallelStreamSafetyArchTest:40-42` uses the **identical** importer and
> root and is the model to copy; also `HttpInTransactionArchTest:50-52`, `OptionalSafetyArchTest:29-31`,
> `PutawayRulesPurityArchTest:57-59`, `TransactionManagerArchTest:42-44`. Under surefire
> `target/test-classes` is on the classpath and this plan's fixtures live in `net.aim_ai.wms.*` and **carry
> the annotation being scanned for**: `ClassAnnotatedFixtureController.openRead()` and `.conflicted()`
> (§3.2), the extended startup fixtures (§3.4.2), and the pin #10/#11 mutants. Without the option:
> **AC-7a** reds permanently on unexpected sites; **AC-7d** reds (no fixture is in `GUARDED`); **AC-3b** reds
> on `conflicted()`, which exists *precisely* to carry both; **AC-1e** picks up fixture reason strings.
> The predictable "fix" is to add the fixtures to the security allow-list — putting unreviewed, unenforced
> entries into the file whose whole purpose is that an entry there means a human reviewed it, which is
> exactly the false-signal failure mode Rail 2 exists to prevent.
>
> Reflection over a hand-rolled directory walk was also the *measured* lesson at
> `FunctionGuardArchTest:355-357`, where a fully-qualified annotation survived a grep-based rule.
> Keep `assertThat(scanned).isNotEmpty()` **and** pin a floor on the scanned class count — a count of
> **production** classes only, which is what makes the floor stable as the test tree grows.

> ⚠️ **Key it `Class#method/arity`,** mirroring `REVIEWED_SHARED_GATE_FUNCTIONS` (`:517-557`) — **not** its
> nearest sibling `REVIEWED_METHOD_LEVEL_OVERRIDES` (`:491-494`), which is name-only. **Javadoc the
> divergence on the new constant**, or the next reader "fixes" the inconsistency by removing the arity.
> `FunctionGuardArchTest:433-439` and `:507-514` both record measured escapes caused by name-only keys.

> ⚠️ **The non-vacuity pre-assertion goes on the set of classes SCANNED, not on the annotations FOUND.** For
> a `containsExactlyInAnyOrder` over a non-empty allow-list, an empty `found` already fails. The genuine
> vacuity risk is upstream: a wrong package path, a `Class.forName` miss, a `Files.walk` over a directory
> that does not exist. The right model is **G-1's** `assertThat(scanned).isNotEmpty()` at
> `FunctionGuardArchTest:395` (plus the `Files.isDirectory(restDir)` check at `:371-373`) — **not** AC-3's
> `examined` at `:277-280`, and not AC-4b's at `:613-615`. Also pre-assert that the allow-list constant
> itself is non-empty.

**Rail 3b — every `@PublicHandler` site's declaring class must be in `GUARDED`.** On an unguarded class the
marker is decoration that reads as audited while nothing enforces it. Same shared scan, same non-vacuity
guard.

*Overlap, stated so nobody thinks one rail is doing work the other is not:* **Rail 3b subsumes Rail 2.** A
`controller.rest.` class cannot be in `GUARDED` — G-2 pins that (`FunctionGuardArchTest:402-421`, verified
green). Both are kept because the named rail carries the *reason*, and because Rail 2's mutant (#11) is
cheaper to reason about than 3b's. Harmless redundancy, deliberately retained.

**Rail 3b-deploy — duplicate 3b at the layer that actually sees the deployed surface.** Rail 3b is the rail
that makes the marker *mean* something, and at build time its scan root is a construct we chose. The **only**
layer that sees the true deployed handler surface is `FunctionGuardStartupAssertion`, and §3.5 is already
adding `findPublicHandlers(Collection<HandlerMethod>)` there, walking exactly that surface. So:

* `afterSingletonsInstantiated` **`LOG.error`s** — does **not** throw — for any `@PublicHandler` site whose
  declaring class is not in `GUARDED`. An inert marker is a hygiene defect; turning it into a total-fleet
  boot failure adds an outage vector for a cosmetic problem, and §8.1 scenario 3 is what that costs.
* The **both-annotations** case **does** join the existing `IllegalStateException` (AC-5c). That one is
  genuine authorization ambiguity and should refuse to deploy — subject to §3.4.1's keying rule, without
  which this line is itself the outage.

**Rail 4 — rewrite `UserControllerUnitTest.everyWriteHandlerIsGated` (`:967-1002`).** It goes red under the
§9.3.2 ruling anyway. The rewrite must fix all four §2.3 defects:
* assert the number of request-mapped declared handlers examined is **exactly 11** before asserting `ungated`
  is empty. This pin does **double duty**: it kills the vacuous-on-empty-scan shape, *and* it is the plan's
  **only tripwire for handler #12** (§1.1 property 3) — a 12th handler reds the test and forces a deliberate
  edit naming it. Do not weaken it to `.isNotEmpty()`;
* key `OPEN_BY_DESIGN` on `name/arity`;
* read the **class-level** annotation as satisfying the requirement (it is method-level-only today);
* assert `OPEN_BY_DESIGN` is **equal** to the set of `@PublicHandler` methods on the class — one source of
  truth, not two lists that can drift.

**Why the marker does not land in the suite's blind spot.** `GOLDEN_MAP` (`:70-98`) is `class → class-level
function`; a method-level marker is invisible to it. Worse,
`guardedControllersCarryOnlyReviewedMethodLevelOverrides` (`:596-624`) filters on `functionsOn(m)`, which
reads `@RequiresFunction` **only** — so a `@PublicHandler` method on a GOLDEN_MAP class yields an empty set
and is **skipped silently**. Rail 3 is the only thing that sees it. Shipping without Rail 3 puts the marker
in the one blind spot of the suite that exists to catch precisely this.

### 3.7 In-scope comment corrections

**(a) The false "~40 endpoints" figure → 4.** `StockUnitController:72` says GUARDED membership "would fail
closed on all ~40 of its endpoints". That counts the whole deployed alias surface including `AdminController`'s
~90 inherited alias URLs, and attributes it to a class the interceptor never attributes it to (§2.2). Counted
from source:

| Controller | declared `@*Mapping` | already carry `@RequiresFunction` | would fail-close on GUARDED |
|---|---|---|---|
| `StockUnitController` | 16 | **13** | **3** |
| `UnitLoadController` | 9 | 3 | **6** |
| `UserController` | 11 | 9 | **2** |

The three on `StockUnitController` are `getDetailView`, `getStorageLocationsForStockMovement` (the arity-2
overload, whose mapping is `/isUnitLoadIdValid/{labelId}`) and `stockunitDetailsById`. Line numbers are
deliberately omitted — see the "write the number and a pointer" box below; re-derive with the grep.

> 🔄 **Rebased 2026-08-24 onto `e44e972`.** This was **4** when the plan was written against `b10b466`.
> **SBDEV-3017-C** (PR #189) landed mid-flight and gated `bulkTransferStock`, taking
> `@RequiresFunction` from 12 to 13 and the fail-close count from 4 to 3. Nothing in this plan's design
> depends on the number — it is the *figure being corrected in §3.7a*, so it had to be re-derived rather
> than carried forward. Re-derive it again before writing the comment: `mvn`-free, one grep.

> ⚠️ **`git grep -n '~40' -- src/main src/test` returned exactly THREE hits at `b10b466` and returns
> **FIVE** at `e44e972`.** The figure is actively propagating, which is the strongest argument for the sweep.
>
> | Site | Since |
> |---|---|
> | `StockUnitController.java:72` | original |
> | `ActionGuardAnnotationContractUnitTest.java:30` | original |
> | `FunctionGuardInterceptorUnitTest.java:85` | original — inside the very test whose `unannotatedHandlersOnThatSameControllerStayUngated` comment explains why `StockUnitController` is out of `GUARDED`, i.e. exactly where the figure is load-bearing |
> | **`StockUnitController.java:166`** | **NEW — SBDEV-3017-C, 2026-08-24** |
> | **`StockUnitBulkTransferGateUnitTest.java:44`** | **NEW — SBDEV-3017-C, 2026-08-24** |
>
> **`FunctionGuardArchTest:31-34` is `import` statements and contains no such figure**, though it looks like
> the obvious site. **Re-run the grep rather than trusting any list, this one included** — that is the whole
> lesson here: a point-in-time citation sweep cannot catch a branch pushed later, and this one did not.

**Correct all FIVE sites** (scope confirmed by Nam, 2026-08-24, after the two new ones appeared). Comment-only;
no behaviour change. The two new copies are freshly-written justification prose in another ticket's merged
commit — correcting three of five would leave the newest and most-read copies asserting the false number.

> **Write the number and a pointer, not a name list.** The figure this plan is correcting *to* must not
> itself become the next wrong load-bearing figure — a name list rots the moment a handler is renamed, which
> is how `~40` survived. One trap if you do enumerate:
> `getStorageLocationsForStockMovement/2` at `:618` *is* the method whose mapping at `:617` is
> `/isUnitLoadIdValid/{labelId}` — naming it by method and by path looks like two different handlers.

**(b) One SDR paragraph.** `FunctionGuardInterceptor:64-65` asserts SDR endpoints "never arrive here at all"
as though that were structural. It is not: SDR **is** gatable via a `MappedInterceptor` bean, which
`AbstractHandlerMapping.initApplicationContext` pulls out of the context for every handler mapping. Correct
**that paragraph only** (this plan edits that javadoc anyway) and point at SBDEV-3017 for the rest.
**Do not attempt the sweep** — the other five `src/main` sites (`RestConfiguration:36-38`, `WebConfig:29-30`,
`RequiresFunction:37-38`, `ReplenishController:64-65`, `FixLocationAssignmentRepository:27-28`, plus
`SdrWriteExposureUnitTest:36-37` in the test tree) belong to SBDEV-3017, which owns the measurement.
Locate them with `git grep -nE "RepositoryRestHandlerMapping" -- src/main src/test` — that returns exactly
those 6 + 1, no more, no fewer. (The looser prose regex returns 5 spurious hits in 4 unrelated files.)

### 3.8 Stale-comment sweep (in scope, mandatory)

Each of these becomes false or misleading the moment `UserController` joins `GUARDED`, and each is
load-bearing prose a future reader will trust:

| # | Site | What is wrong after the change |
|---|---|---|
| 1 | `controller/UserController.java:34-59` | 24 lines arguing the controller **cannot** be guarded, including "there is no annotation value meaning 'public'" (`:40-41`) and a "WHAT WOULD UNBLOCK IT" paragraph (`:51-53`) proposing a *different* solution (move the reads to another controller) than the one shipping. **Rewrite in full**: state that it IS guarded, name the two `@PublicHandler` reads and why they cannot be gated, and record that the class-level annotation replaced 9 identical method-level ones |
| 2 | `unit/controller/UserControllerUnitTest.java:970-982` | "Stands in for FunctionGuardInterceptor.GUARDED membership, **which this controller cannot have**" — now false |
| 3 | `security/FunctionGuardInterceptor.java:56-62` | "Fail closed, but only inside GUARDED" — silent on the escape hatch; must document `@PublicHandler` or the javadoc is incomplete in the direction that matters |
| 4 | `unit/config/FunctionGuardArchTest.java:333-336` and `:360` | "the interceptor resolves a method-level annotation before it consults that set" — still true, now incomplete |
| 5 | `security/RequiresFunction.java:9-16` | resolution-order javadoc should point at the new sibling |
| 6 | `security/FunctionGuardInterceptor.java:77` | *"The **eleven** controllers whose handlers must carry an annotation"* — **already wrong at 13**, and it is the javadoc **on the `GUARDED` declaration this plan edits**. Fix to 14 |
| **6b** | `security/FunctionGuardInterceptor.java:92-94` — **a FALSE SECURITY CLAIM three lines above the line P2 edits** | The `GUARDED` entry for the SBDEV-3013 pair reads: *"Membership here is what makes a future unannotated handler on these two fail CLOSED; the class-level `@RequiresFunction` alone would let it through."* **Both halves are false.** `UserRoleController:39` and `UserGroupController:46` each carry a class-level `@RequiresFunction` (site #31), so a future unannotated handler on either **resolves the class default and is gated on that function** — not fail-closed, and the class-level annotation does *not* "let it through". This asserts, in production source, the precise claim §1.1 spends thirty lines refuting, and it is the model a reader will copy when adding `UserController` three lines below. **Rewrite it in P2 to say what `GUARDED` actually buys there: a deletion tripwire on the class-level annotation, per §1.1 property 2.** This is §3.8's own preamble failing on itself — *"correcting a constant while leaving the sentence above it wrong is how `~40` happened"* — and it is a second, independent instance of the false model already load-bearing in the tree |
| 7 | `unit/config/FunctionGuardArchTest.java:69` | *"The **eleven** guarded controllers and their class-level function"* — the javadoc on `GOLDEN_MAP`, which this plan edits. Fix to 14 |
| 8 | `unit/security/FunctionGuardWiringUnitTest.java:66` | *"The **eleven** controllers §3.1-A5 gates"* — the javadoc on `EXPECTED_GUARDED`, which this plan edits. Fix to 14 |
| 9 | `security/FunctionGuardStartupAssertion.java:73-85` | *"Once every one of the **eleven** controllers carries a class-level default…"* — the javadoc on the **exact method P3 edits**. Fix the count, and record §3.4.1's keying rule here: this is the closest prose to the code that can get it wrong |
| 10 | *(optional)* `controller/StockUnitController.java:69-72` | a one-line pointer that the marker now exists, **without applying it** — explicitly out of scope |

> r1's sweep missed rows 6–9 — **four stale "eleven"s, every one of them the javadoc physically attached to a
> line this plan edits.** Correcting a constant while leaving the sentence above it wrong is how `~40`
> happened.

### 3.9 Explicitly NOT doing

* **Do not widen the `FunctionGuardInterceptor` constructor.** Six sites construct it 3-arg (§0.B footnote).
  Nothing in this plan needs a fourth parameter. Adding a guarded-set seam to close §3.4's gap is a
  production design change with 6 test-file edits and DI-wiring risk, already tracked as "item 5 of §14.19's
  fix list" (`FunctionGuardWiringUnitTest:250`). **Out of scope.**
* **Do not apply `@PublicHandler` to `StockUnitController` (4 unannotated) or `UnitLoadController` (6).** That
  is 10 separate decisions, and at least `bulkTransferStock` (`StockUnitController:162`) and `reprintLabel`
  (`UnitLoadController:58`) almost certainly want a **real function**, not a marker — `bulkTransferStock`
  moves real inventory in a loop while its single-item sibling `transferStock` (`:93-95`) is gated. Folding
  that in turns a tractable change into an open-ended one. Extending the marker to those two would also
  require deleting or inverting `FunctionGuardArchTest:427-451` and G-2's `doesNotContain` at `:417-420`,
  both written 2026-08-22 with measured mutation evidence.
* **Do not touch anything about the Spring Data REST surface** beyond the one paragraph in §3.7(b).
  SBDEV-3017 owns it and ships **after** this.
* **No UI change.** All four call sites (§0.D) keep working byte-identically.
* **No `MappedInterceptor` / `WebConfig` change.** That is SBDEV-3017's axis; this plan is disjoint from it.

### 3.10 Backward compatibility — what does NOT change

Everything in this list is verified, not assumed. If any row turns out to be false during implementation,
that is an escalation, not a detail.

| Unchanged | Evidence |
|---|---|
| **All four UI call sites keep working byte-identically** — `wms2-web-ui/store/index.js:83` and `:94`, `wms2-mobile-ui/store/index.js:76`, `wms2-mobile-ui/store/home.js:106` | The two endpoints keep their path, verb, response shape and status. `@PublicHandler` short-circuits to `return true` before `AccessService` is ever consulted |
| **No UI code change in either repo** | §0.D. The two UIs are not touched by this plan at all |
| **No URL, verb, header or body shape changes** for any currently-working call | No mapping is added, moved or renamed; `UserController:33` keeps `/v3/user` |
| **The 9 gated write handlers keep denying exactly the same callers** | The type-level `@RequiresFunction` carries the identical `WEB_UI_VIEW_USER_MANAGEMENT` value the 9 deleted method-level ones carried. Resolution falls back to the class level at `FunctionGuardInterceptor:120-122` |
| **`denyUnlessUserManagementAllowed()` and all 9 of its call sites** (`UserController:134-143`) | Untouched — defence-in-depth, and the reason the 6 direct-invocation deny tests at `UserControllerUnitTest:856-965` stay green |
| **The 13 existing guarded controllers behave identically** | `:124-146` of `preHandle` is unchanged; the method-level-before-`GUARDED` ordering pins at `FunctionGuardInterceptorUnitTest:81-120` stay green |
| **Inherited `AdminController` handlers stay ungated under every one of the 43 prefixes** | Resolution keys on `getDeclaringClass()` (`:118`), which is unchanged. §2.2 |
| **The `/rest/**` OMS surface and the Spring Data REST surface** | Neither is touched; AC-7c forbids the marker in `controller.rest.` |
| **`wms2.authz.allowed` and `wms2.authz.denied`** keep their current semantics and tags | The public path increments a *new* counter and never falls through to the allow path (AC-9 pins both halves) |
| **No database read or write changes** | No schema, no seed, no query. The public path issues *fewer* queries than today |
| **No Spring bean, constructor arity or DI wiring change** | The interceptor stays 3-arg; §3.9 |

**The only intentional behavioural delta on the wire:** a *future unannotated* handler declared on
`UserController` becomes **gated on `WEB_UI_VIEW_USER_MANAGEMENT`** instead of shipping open — reachable by
38 of 99 users rather than by all of them. There is no such handler today (§0.C enumerates all 11).

> ⚠️ **Not "starts returning 403".** It 403s only for the 62% who lack the function; for the 38 admins it is
> open, and if it needed a *different* function it ships silently wrong (§1.1, §9.3.4).

---

## 4. V1/V2 Applicability

**v2 only.** `v1/wms-api` has no `FunctionGuardInterceptor`, no `@RequiresFunction`, no
`FunctionGuardStartupAssertion` and no `AccessService` function gate — the whole mechanism was introduced in
v2 (SBDEV-2968 / 2984 / 3013). There is nothing to port and nothing to keep in sync.

Per the standing directive, v1 is reference-only: no v1 ticket, no v1 plan, no v1 change arises from this
work.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **N/A — no schema change.** But the DB reading that justifies the design must be re-confirmed on the target tenant before rollout: `SELECT count(*) FROM mywms_user` and the count holding `WEB_UI_VIEW_USER_MANAGEMENT`. Measured on `wms2-wineco-dev` 2026-08-24: **99 / 38 → 61 would lose bootstrap** | implementer | This is the DB floor item; it is why the marker exists |
| 2 | **Feature flags / system properties** | **N/A** — behaviour is annotation-driven, no `los_sysprop` key, no toggle. Deliberate: a toggle on a fail-closed authorization path is a second failure mode | — | |
| 3 | **Config / env changes** | **N/A** — no property, no Jasypt value, no Keycloak client scope | — | |
| 4 | **Deploy-order dependencies** | **SBDEV-3063 must merge BEFORE SBDEV-3017.** 3017 rewrites `FunctionGuardWiringUnitTest.Registration` (`:105-185`, three tests) and must preserve two *measured* mutation findings (`:126-135`, `:162-176`). 3063 is small, isolated, changes no registration, and has no business queuing behind that. The only overlap is textual: both edit `FunctionGuardInterceptor`'s class javadoc | Nam | Per the stacked-PR rule: merge base-first **into** `develop`, then confirm `git merge-base --is-ancestor` |
| 5 | **Data migration** | **N/A** — no backfill, no one-off SQL | — | |
| 6 | **External systems** | **N/A** — no OMS webhook, no printer, no Keycloak realm change | — | |
| 7 | **Access / permissions** | **N/A** — reuses the existing `WEB_UI_VIEW_USER_MANAGEMENT` function; no new `FunctionEnum` constant, therefore **no Flyway migration** | — | Confirmed: the constant is already declared and already granted to 38 of 99 users on wineco-dev |
| 8 | **Monitoring / alerts** | **New metric `wms2.authz.public`**, tagged `controller`. Optional Grafana panel alongside the existing `wms2.authz.allowed` / `wms2.authz.denied`. A **drop to zero** on this counter after a deploy is the signal that the marker was accidentally removed and 61 users are silently failing to bootstrap | implementer | Tag cardinality must stay bounded — see §7.1 |
| 9 | **Test baseline** | **Re-measure on the merge-base immediately before the run** — do not grade against a number written here. The load-bearing invariant is the **failure SET**, not the count: exactly two failures, both pre-existing and unrelated, and they are `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses:43` and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate:468`. **0 errors.** For reference only, `b10b466` measured 5465 / 2 / 0 / 67 and **`e44e972` measured 5503 / 2 / 0 / 67** — that total *will* be wrong by the time anyone runs it (the repo's recorded baseline was 4442 not long ago), and an implementer chasing a stale total either burns hours or rationalises a genuine new failure. **This row was proved right in practice: `develop` moved from `b10b466` to `e44e972` between plan approval and the implementation run, and the total moved 5465 → 5503 while the failure SET stayed identical. Grade on the set.** | implementer | `mvn test` mutates `src/test/resources/archunit_store/` — **revert before commit** |
| 10 | **Worktree** | `.claude/worktrees/wms2-api/SBDEV-3063`, branch `feature/SBDEV-3063-public-handler-marker`, off freshly-fetched `origin/develop` | implementer | Already created and clean |
| 11 | **Flyway collision sweep** | **N/A this plan** (no migration). But re-run `check-migration-version-collision.sh` immediately before merge regardless — a branch pushed after a point-in-time sweep has bitten three correct sweeps | implementer | |

### 5.2 Implementation Checklist

Slices are ordered. **The atomic unit is `GUARDED += UserController` + the type-level `@RequiresFunction` +
the two `@PublicHandler` markers — i.e. all of P2, and P2 must not ship without them together.** That split,
not the P3 one r1 named, is the un-bootable one (§3.3's corrected sequencing). Shipping P1–P4 as one commit
is still the recommendation and is a superset of the true constraint. P0-scaffold is a separate first commit
(it is behaviour-free); P5 may be a second commit after P4.

**P0-scaffold — FOUR behaviour-free declarations, BEFORE any test is written**

> ⚠️ **Java compiles the test module as a unit, so ONE missing symbol makes every new test fail to compile
> and the gate produces no red assertion for anything.** That is what this slice exists to prevent, and it
> only works if **every** symbol the new tests reference exists — including both seams from §3.5. A compile
> error is indistinguishable across all criteria; an assertion failure is not.

- [x] `PublicHandler.java` exactly as §3.1 specifies (declaration only — nothing reads it yet)
- [x] `AccessDecision.Reason += CONFLICTING_ANNOTATIONS("conflicting_annotations")` (nothing constructs it yet)
- [x] `FunctionGuardStartupAssertion.findPublicHandlers(handlers)` **stub returning `List.of()`**
- [x] `FunctionGuardStartupAssertion.findMarkedHandlersOutsideGuarded(handlers, guarded)` **stub returning
      `List.of()`** — §3.5's second seam. AC-5d asserts on it and §6.6 names its test, so omitting it
      reintroduces exactly the compile failure this slice was added to fix
- [x] Confirm the module compiles and the suite is at baseline

This does not weaken the gate. The `preHandle` marker block, the boot-assertion change and all
`UserController` edits still land **after** the red. It only moves four declarations that carry no
behaviour. **AC-1a…AC-1d and AC-1e pass immediately** — structural pins on the scaffold, not gate failures.
**AC-6a and AC-5d genuinely red** on the `List.of()` stubs, as does AC-7a (0 found vs 2 reviewed).
The full green-at-gate list is in P0 below.

**P0 — TDD gate (tests first, confirmed failing for the right reason)**
- [x] Create `UserControllerPublicHandlerUnitTest` and the `ClassAnnotatedFixtureController` fixture (§3.2)
- [x] Write **every** criterion in §5.3 as a test. The full list, refreshed against §5.3 in r3:
      **AC-1a…1e, AC-2a…2d, AC-3a…3d, AC-4a…4g, AC-5a, AC-5a′, AC-5c, AC-5d, AC-6a, AC-7a…7d, AC-8a…8c,
      AC-9.** There is no AC-2e (dropped as unwritable). AC-6b, AC-11 and AC-12 are not JUnit criteria —
      see §9.1 and §6.5
- [x] Extend **BOTH** `FunctionGuardStartupAssertionUnitTest` fixtures with a `@PublicHandler` method — the
      defaultless `ForgotTheAnnotationController:36-40` for **AC-5a** and the class-annotated
      `AnnotatedController:42-47` for **AC-5a′**. §3.4.2 explains why neither is optional. Give the new
      fixture methods **distinct names**: `handlerOn(Class, String)` at `:49-56` is name-only (`findFirst()`)
- [x] Confirm each behavioural AC fails **on an assertion**, not on a compile error or `NoClassDefFoundError`
      — P0-scaffold is what makes that achievable

#### ⚠️ Criteria that are GREEN at the P0 gate — expected, not a gate failure

r2 listed only AC-1a…1d. Traced against `preHandle:118-133` and `UserController` as it stands, these are
**also green before any change**, and an implementer who does not know that will either fabricate a red or
lose confidence in the gate — the same defect r1's P0 had, relocated:

| AC | Why it is already green |
|---|---|
| AC-1a…AC-1d | Structural pins on the P0-scaffold declarations |
| **AC-1e** | A per-site non-blank assertion over **zero** found sites is trivially true. *(r2 predicted this red. It is not — what reds at scaffold is AC-7a's `containsExactlyInAnyOrder`, 0 found vs 2 reviewed.)* Give AC-1e a `found.size() == allowList.size()` pre-assertion so it is non-vacuous **after** the fix too |
| **AC-2a / AC-2c** | `UserController` is not in `GUARDED` and `isWmsUser` carries no annotation, so `preHandle` returns `true` at `:126` without touching `accessService`. `isNotEqualTo(403)` and `verifyNoInteractions` both hold **today** |
| **AC-4g** | A class-annotated fixture with an unannotated method already resolves the class annotation and is gated on it — that is *current* behaviour. AC-4g's honest role is a **regression pin** that §3.2's block did not disturb `:124-146` (see its mutant, pin #16) |
| **AC-5a′** | Mutation-only by construction (§3.4.2) — `findUnannotatedGuardedHandlers` returns empty on the class-annotated fixture before and after P3 |
| **AC-3b** | "no production handler carries both" over **zero** production `@PublicHandler` sites is trivially true — the identical argument as AC-1e |
| **AC-8a** | `UserController` declares exactly 11 request-mapped handlers today (§0.C), so the count pin is green before the rewrite |

**AC-5a is the one genuine gate failure P3 has.** The behavioural reds to expect at P0 are **AC-2b, AC-3a,
AC-3c, AC-4a** (no type-level annotation until P2)**, AC-4b, AC-4c, AC-4d, AC-4e, AC-4f, AC-5a, AC-5c,
AC-5d, AC-6a, AC-7a…7d, AC-8b, AC-8c, AC-9.**

- [x] Record the actual red set and compare to the list above. **A divergence is a signal about the plan, not
      a nuisance** — §0.B's colour column is predictions, and so is this

**P1 — the mechanism** (`security/`)
*(P0-scaffold already landed the first two as bare declarations — verify, do not re-create.)*
- [x] ~~New `PublicHandler.java`~~ — landed in P0-scaffold; **verify** it matches §3.1 exactly
- [x] ~~`AccessDecision.Reason += CONFLICTING_ANNOTATIONS`~~ — landed in P0-scaffold; P1 is where it is first
      *constructed*, at the conflict branch
- [x] `FunctionGuardInterceptor`: `METRIC_PUBLIC = "wms2.authz.public"` beside `:73-74`
- [x] `FunctionGuardInterceptor.preHandle`: insert the §3.2 block, replacing `:118-122`. **Re-read §3.2 before
      writing the conflict condition**
- [x] `FunctionGuardInterceptor` class javadoc `:56-62` — document the escape hatch; `:64-65` — correct the
      one SDR paragraph and point at SBDEV-3017; `:77` — "eleven" → 14 (§3.8 row 6)
- [x] `RequiresFunction.java:9-16` — javadoc pointer to the sibling

**P2 — `UserController` joins the guarded set**
- [x] Type-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` on `UserController:31-33`
- [x] `@PublicHandler(reason = …)` on `isWmsUser:164` and `getAllRoles:479`, each naming its UI call site
- [x] **Delete** the 9 method-level `@RequiresFunction` (`:146,176,222,282,362,414,470,485,494`) — §9.3
- [x] Leave `denyUnlessUserManagementAllowed()` (`:134-143`) and all 9 of its call sites untouched
- [x] Rewrite the `:34-59` class comment per §3.8 row 1
- [x] `FunctionGuardInterceptor.GUARDED += UserController.class` (`:80-96`) → 14, with a comment naming this
      ticket and the two markers
- [x] **Rewrite the false claim at `FunctionGuardInterceptor:92-94`** (§3.8 row 6b) — it is three lines above
      the line being added and asserts the fail-closed model §1.1 refutes

**P3 — the deploy-time layer** *(future-proofing, NOT boot-order-critical — see §3.3's corrected sequencing;
record its three real justifications in the slice's own comment)*
- [x] `FunctionGuardStartupAssertion` 2-arg overload (`:86-103`): `@PublicHandler` satisfies the requirement;
      **both** annotations is a violation. **Re-read §3.4.1 before writing the conflict condition** — the
      class-level fallback at `:96` reassigns `annotation`, and keying the check on it fails every replica's
      boot
- [x] Extract **two** static seams (§3.5), both keyed `Class#method/arity`: `findPublicHandlers(handlers)`
      and `findMarkedHandlersOutsideGuarded(handlers, guarded)` — the second is what makes AC-5d assertable
- [x] `LOG.error` (do **not** throw) over `findMarkedHandlersOutsideGuarded`'s result (§3.6 Rail 3b-deploy)
- [x] `FunctionGuardStartupAssertion:73-85` javadoc — "eleven" → 14, **and record §3.4.1's keying rule here**
      (§3.8 row 9)
- [x] Extend the `:60-61` success log to enumerate the open set

**P4 — the build-time layer**
- [x] `FunctionGuardArchTest.GOLDEN_MAP += UserController → WEB_UI_VIEW_USER_MANAGEMENT` (`:70-99`)
- [x] `@DisplayName` text `:218` — 13 → 14
- [x] `FunctionGuardWiringUnitTest.EXPECTED_GUARDED += UserController.class` (`:67-74`); `@DisplayName` `:227`
      "thirteen" → "fourteen"; **rename the method** `guardedSetIsExactlyTheEleven` (`:228`) →
      `guardedSetIsExactlyTheFourteen` so §6.6's name and the code agree
- [x] New arch test: the arity-keyed `@PublicHandler` allow-list, non-vacuity on **`scanned`** (§3.6 Rail 3),
      with the divergence-from-sibling javadoc
- [x] New arch rules: no `@PublicHandler` on `AdminController` (Rail 1); none in `controller.rest.` (Rail 2);
      every site's declaring class is in `GUARDED` (Rail 3b)
- [x] Verify P0 landed **both** `FunctionGuardStartupAssertionUnitTest` fixtures and all four criteria —
      AC-5a (defaultless), AC-5a′ (class-annotated), AC-5c, AC-5d. §3.4.2: neither fixture is optional
- [x] `FunctionGuardWiringUnitTest:242-250` — update the blind-spot note (§3.4)
- [x] Confirm `REVIEWED_METHOD_LEVEL_OVERRIDES` (`:491-494`) is **unchanged** at 3 entries
- [x] Stale-count sweep for the **test-tree** javadocs, §3.8 rows 7–8: `FunctionGuardArchTest:69`
      (`GOLDEN_MAP`), `FunctionGuardWiringUnitTest:66` (`EXPECTED_GUARDED`) — both say "eleven"
      *(`FunctionGuardInterceptor:77` and `:92-94` belong to **P2** and
      `FunctionGuardStartupAssertion:73-85` to **P3** — each javadoc travels with the line it annotates.)*

**P5 — comment corrections and the deny-list rewrite**
- [x] Rewrite `UserControllerUnitTest.everyWriteHandlerIsGated` (`:967-1002`) per §3.6 Rail 4 — all four fixes
- [x] `UserControllerUnitTest:970-982` comment (§3.8 row 2)
- [x] `FunctionGuardArchTest:333-336`, `:360` (§3.8 row 4)
- [x] `~40` → the re-derived number: **five** sites — `StockUnitController:72`, `StockUnitController:166`,
      `ActionGuardAnnotationContractUnitTest:30`, `FunctionGuardInterceptorUnitTest:85`,
      `StockUnitBulkTransferGateUnitTest:44` (§3.7a). The last two arrived with SBDEV-3017-C on 2026-08-24.
      **Re-run `git grep -n '~40' -- src/main src/test` immediately before editing** — the count moved once
      already mid-flight. `FunctionGuardArchTest:31-34` is imports and was r1's error
- [x] Optional: `StockUnitController:69-72` pointer that the marker exists, not applied

**Closeout**
- [x] Mutation-check every new assertion (AC-10) — **all eighteen** pins in §6.1 are mandatory, not
      illustrative. **#9 is the one that must not be skipped**: without it the plan has an untested path to a
      total-outage boot failure (§3.4.1) — and note it targets **AC-5a′**, not AC-5c
- [x] ⚠️ **For each pin, record WHICH criterion went red and which stayed green.** If the named criterion
      stayed green while a *different* one reddened, that is a **plan defect to report in one line**, not a
      test to rewrite. Three of the eighteen pins (#7, #9, #16) were mis-targeted across r1→r3 and each was
      caught only by tracing the mutant by hand against the fixture — and §6.1's standing rule ("a green pin
      means the assertion is vacuous") points at the wrong response for that case Each mutant must be *proven to have hit its target* — force
      recompilation; a copy that preserves mtime is skipped and produces a fake green
- [x] `mvn test` full suite; compare to the §5.1 row 9 baseline exactly
- [x] `git checkout -- src/test/resources/archunit_store/` before commit
- [x] Independent `code-reviewer` pass; fix every High/Medium
- [x] Manual QA §6.5 rows M1 and M2 — **done at the API + rendering-logic level, NOT via a browser.**
      Verified 2026-08-24 against the confirmed-new dev build (`wms2.authz.public` metric present, which
      exists only in this commit): 8/8 live authz matrix as `sbtest` (35 functions, no
      `WEB_UI_VIEW_USER_MANAGEMENT`) and `panderson` (80 functions, sb_admin) — bootstrap reads OPEN for the
      non-admin, gated surface DENIED for the non-admin, gated surface ALLOWED for the admin, sibling
      guarded controller unaffected. The mobile tile filter (`store/home.js:109`) was then executed against
      `sbtest`'s real function list: **4 of 10 tiles → `pageList` non-empty → the home screen renders.**
      The web UI was found not to consume the response at all (`pages/index.vue:114` discards it and no
      function-based nav gating exists), so it cannot regress this way. **Residual: nobody has literally
      looked at the screen.** Owner: whoever next opens the mobile UI on dev. Not a blocker — the three
      failure modes this row existed to catch are each independently verified above
- [x] `verify-docs` audit for `sbdocs/3-Resources/` drift on the authorization subsystem

### 5.3 Acceptance criteria

> **Two AC namespaces coexist in this document — pre-existing, and worth knowing before you grep.** `AC-1a`
> … `AC-12` below are **this plan's**. Bare `AC-1`, `AC-2`, `AC-3`, `AC-4`, `AC-4b`, `AC-5`, `AC-26` in §0.B
> and §9.3 are **`FunctionGuardArchTest`'s own SBDEV-2968 numbering** and always appear qualified by that
> file's name. `AC-4b` is live in both.

| AC | Condition | Where |
|---|---|---|
| **AC-1a** | `net.aim_ai.wms.security.PublicHandler` exists and `isAnnotation()` | new arch test, mirroring `FunctionGuardArchTest:173-177` |
| **AC-1b** | `@Target` is **exactly** `{METHOD}` — `containsExactly(ElementType.METHOD)`, not `contains` | mirrors `:191-195` but with equality |
| **AC-1c** | `@Retention` is `RUNTIME` | mirrors `:185-189` |
| **AC-1d** | `reason()` is declared, returns `String`, and **`getDefaultValue()` is null** | reflection |
| **AC-1e** | every `@PublicHandler` site's `reason()` is **non-blank**, with a `found.size() == allowList.size()` pre-assertion — without it the criterion is trivially green over zero sites, which is also why it is **green at the P0 gate** — over the §3.6 Rail 3 shared scan, with its non-vacuity guard, or the criterion is trivially green over zero sites. *(r2: dropped r1's "≥ 20 chars" — an arbitrary count that 20 characters of filler passes. The substance is the review rule in §8.1 scenario 2: the reason must explain why a gate is **impossible**, not inconvenient — and, per §1, must not assert the false circularity claim.)* | arch test |
| **AC-2a** | a `@PublicHandler` handler on a GUARDED controller is allowed **and `accessService` is never consulted** | `verifyNoInteractions(accessService)` |
| **AC-2b** | ⚠️ **THE ORDERING CRITERION.** A `@PublicHandler` handler on a controller that is in `GUARDED` **and** carries a **class-level `@RequiresFunction`** is ALLOWED for a caller holding none of that function, and `accessService` is never consulted | §3.2 fixture, allow variant |
| **AC-2c** | the same handler, driven through **MockMvc with the real interceptor** (`setupMockMvcWithGuard`), returns a status `isNotEqualTo(403)` — proves the gate is *reached* and still allows | Lane B |
| **AC-2d** | **Mutation pin for AC-2b** (procedure, recorded): re-point the conflict check from `methodLevel` to the resolved `annotation` → AC-2b must go RED. The single mutant that reproduces the 99-user outage | manual, recorded |
| ~~AC-2e~~ | **DROPPED — unwritable, and there is deliberately no AC-2e.** "An inherited method whose parent carried `@PublicHandler` does not open a handler" cannot be written: with `@Target(METHOD)` a class cannot carry it, so the fixture will not compile — and the reachable variant, an inherited **method** declaring the marker, *should* open, because resolution keys on `getDeclaringClass()`. **AC-1b is the whole criterion** | — |
| **AC-3a** | method-level `@PublicHandler` **and** method-level `@RequiresFunction` → `preHandle` false, 403, on a fixture that **also** carries the class-level annotation | §3.2 fixture, deny variant |
| **AC-3b** | **no production handler carries both** | arch test over all sites |
| **AC-3c** | the conflict denial is distinguishable: body `reason` is `CONFLICTING_ANNOTATIONS`, not `MISSING_FUNCTION`; the `wms2.authz.denied{reason=…}` tag is its own value | interceptor unit test |
| **AC-3d** | ⚠️ AC-2b and AC-3a hold against the **SAME** class-level-annotated fixture. Either alone passes on a broken implementation; only the pair pins the design | §3.2, two methods on one fixture |
| **AC-4a** | `UserController` carries type-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` | `FunctionGuardArchTest` AC-1/AC-2 |
| **AC-4b** | `isWmsUser` (arity 2) and `getAllRoles` (arity 1) carry `@PublicHandler`; **no other declared method on the class does** — equality, not containment | new arch test |
| **AC-4c** | `FunctionGuardInterceptor.GUARDED` contains `UserController` and has **exactly 14** members | `FunctionGuardWiringUnitTest:226-234` |
| **AC-4d** | `GOLDEN_MAP` and `EXPECTED_GUARDED` remain equal to the production set | existing tests |
| **AC-4e** | `UserController` declares **zero** method-level `@RequiresFunction`, and `REVIEWED_METHOD_LEVEL_OVERRIDES` is unchanged at 3 entries | new assertion + `FunctionGuardArchTest:596-624` |
| **AC-4f** | `@RequiresFunction` is still enforced normally on the same controller, **both directions**: a caller lacking the function gets 403 on `/v3/user/getDetails`, a caller holding it does not. A one-direction test passes on an implementation that denies everything | §6.1 Lane B |
| **AC-4g** | ⚠️ **THE PROPERTY ACTUALLY DELIVERED, pinned.** Green at the P0 gate — this is current behaviour, unchanged by the plan; its honest role is a **regression pin** that §3.2's rewrite of `:118-122` did not break the class-level fallback. Mutant **#16** (delete the fallback) is the one thing that reds it. A handler declared on a class-level-annotated `GUARDED` controller carrying **neither** `@RequiresFunction` nor `@PublicHandler` is **gated on the class function** — *not* allowed, *not* fail-closed 403-for-everyone, *not* `CONFLICTING_ANNOTATIONS`. This is what every future handler on `UserController` will get (§1.1), and nothing in r1 asserted it. Fixture-only: no real class can produce this shape once AC-1 forces the class-level annotation | §3.2 fixture, third method |
| **AC-5a** | `findUnannotatedGuardedHandlers(handlers, guarded)` returns **empty** for a guarded handler carrying `@PublicHandler`, on the **defaultless** fixture `ForgotTheAnnotationController:36-40` + a marker. **RED at the P0 gate; the only genuine gate failure P3 has.** Target of mutant **#7** — and pin #7 is *dead* on any class-annotated fixture, which is how r2's single-fixture mandate silently killed it (§3.4.2) | `FunctionGuardStartupAssertionUnitTest` |
| **AC-5a′** | Same assertion on the **class-annotated** fixture `AnnotatedController:42-47` + a marker. **Green at the P0 gate and after — mutation-only, and the plan says so rather than letting a reader mistake it for coverage.** Target of mutant **#9**: it is the *only* criterion that reds when the boot conflict check is keyed on the reassigned `annotation` (§3.4.2's discrimination table) | `FunctionGuardStartupAssertionUnitTest` |
| **AC-5b** | it still returns a violation for a guarded handler with **neither** annotation (existing `:60-69`, mutation-checked) | existing |
| **AC-5c** | it returns a violation for a handler carrying **both** — the boot-time twin of AC-3a, on the class-annotated fixture. ⚠️ **Mutant #9 does NOT red this criterion**: when the method-level annotation is present, `annotation` *is* `methodLevel`, so the mutant is invisible here. AC-5a′ is the detector (§3.4.2) | new |
| **AC-5d** | `findMarkedHandlersOutsideGuarded(handlers, guarded)` **returns the offending `Class#method/arity` key** for a marker on a non-guarded fixture class, and empty otherwise — a **content** assertion, not "nothing threw" (§3.5; mutant **#15**). The `LOG.error` **call** is a code-review item beside AC-6b | new unit test |
| **AC-6a** | `findPublicHandlers(Collection<HandlerMethod>)` returns `Class#method/arity` for each site and nothing else | new unit test |
| **AC-6b** | the boot log line names the open set | **NOT JUnit-observable** — code-review item (§9.1) |
| **AC-7a** | the allow-list arch test asserts `containsExactlyInAnyOrder` over every `@PublicHandler` site, keyed `Class#method/arity` | new arch test |
| **AC-7b** | ⚠️ **Binds on AC-1e, AC-3b, AC-7c and AC-7d as well, not on the allow-list test alone** — all five are pure negatives or equalities over the same scan, and a scan that finds nothing makes every one of them green. One shared scan, rooted at `net.aim_ai.wms` via ArchUnit `importPackages` (`pom.xml:311-314`) **with `.withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)`** — omit it and every rail reds on this plan's own fixtures (§3.6 Rail 3; model: `ParallelStreamSafetyArchTest:40-42`; pin #17) — plus `assertThat(scanned).isNotEmpty()` **and** a pinned floor on the **production** class count, plus a non-empty check on the allow-list constant. The scan root is not "the controller tree": `TenantDiscoveryController` lives in `net/aim_ai/wms/landlord/controller/` and would escape every rail in silence (§3.6 Rail 3) | new arch test |
| **AC-7c** | no `@PublicHandler` on `AdminController` or anything in `controller.rest.`. ⚠️ **Must iterate `AdminController.class.getDeclaredMethods()` keyed `name/arity` (class literal — §3.6 Rail 1 struck the `guardedController(...)`/`isPresent()` dance as dead weight) — NOT `FunctionGuardArchTest:626-634`'s `functionsOn(c)`/`ifPresent` shape, which is doubly unfailable here** (a class-level `@PublicHandler` will not compile under `@Target(METHOD)`, and `ifPresent` asserts nothing when the class does not resolve — that test's own `@DisplayName` says "[regression pin — vacuous until the annotation exists]"). Mutation pins **#10** and **#11** | new arch test |
| **AC-7d** | every `@PublicHandler` site's declaring class is a member of `GUARDED` | new arch test |
| **AC-8a** | `everyWriteHandlerIsGated` asserts the number of request-mapped declared handlers examined is **exactly 11** before asserting `ungated` is empty | `UserControllerUnitTest:967-1002` |
| **AC-8b** | `OPEN_BY_DESIGN` is keyed `name/arity` **and** asserted **equal** to the set of `@PublicHandler` methods | same |
| **AC-8c** | the rewritten test treats a class-level `@RequiresFunction` as satisfying the requirement | same |
| **AC-9** | `wms2.authz.public` increments once per public-handler request, tagged `controller`; `wms2.authz.allowed` does **not** increment for it | interceptor unit test |
| **AC-10** | mutation floor: for each new assertion, break what it protects and confirm red — in particular the `verifyNoInteractions` in AC-2a and the class-level annotation on the AC-2b fixture | manual, recorded |
| **AC-11** | **61 of 99 users on `wms2-wineco-dev` still bootstrap** after the change | **NOT JUnit-observable** — manual-QA row M3 (§6.5) |
| **AC-12** | full suite: **failure set identical to the two named pre-existing failures** (`OptionalSafetyArchTest:43`, `MobilePalletizingServiceTest:468`), **0 errors**, and test count ≥ the merge-base total plus the new tests. **Do not pin an absolute total** — this plan adds ~15 tests and `develop` moves; the named failure pair is the load-bearing invariant | `mvn test` |

---

## 6. Test Plan

Every fixture in this plan uses **`setupMockMvcWithGuard(controller, interceptor)`**
(`BaseControllerUnitTest:95`, installing the interceptor at `:101`). `setupMockMvc` (`:50-52`, `:66-75`)
installs **no interceptor** — any gate test written with it is vacuous and passes on an ungated controller.
`UserControllerUnitTest:107` uses the no-interceptor overload, so no new gate assertion may live in that
class's existing fixture.

### 6.1 Unit tests

Two lanes, and the plan uses **both**:

* **Lane A — direct `preHandle`** (`FunctionGuardInterceptorUnitTest` style, `:63-71` + the `handler()` helper
  at `:122-132`). Cheapest, and the only lane that can assert the metric counter and the
  `AccessDecision.Reason`. Covers AC-2b, AC-3a, AC-3c, AC-9.
* **Lane B — MockMvc with the real interceptor** (`FunctionGuardMockMvcUnitTest` style, `:83-96`). The only
  lane that proves the interceptor is *reached* for a `/v3/user/**` request. Covers AC-2a, AC-2c.

**Fixture header** (mirrors `FunctionGuardMockMvcUnitTest:83-96`):

```java
class UserControllerPublicHandlerUnitTest extends BaseControllerUnitTest {

    @Mock private AccessService accessService;
    private FunctionGuardInterceptor guard;

    @BeforeEach
    void setUpGuard() {
        guard = new FunctionGuardInterceptor(accessService, new ObjectMapper(), new SimpleMeterRegistry());
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("sbtest", "n/a", Collections.emptyList()));
    }

    @AfterEach
    void clear() { SecurityContextHolder.clearContext(); }   // FunctionGuardInterceptorUnitTest:73-79

    /** FunctionGuardMockMvcUnitTest:91-96 — verified null-safe for UserController:81-94 → AdminController:41-46. */
    private static Object instantiate(Class<?> type) throws Exception {
        Constructor<?> ctor = type.getDeclaredConstructors()[0];
        Object[] args = new Object[ctor.getParameterCount()];
        ctor.setAccessible(true);
        return ctor.newInstance(args);
    }
```

**AC-2a / AC-2c — the marker allows, through the real interceptor.** Assert `isNotEqualTo(403)`, never
`isEqualTo(200)`.

> **AC-2c is meaningful only in conjunction with the deny-direction test.** A non-403 also results from the
> interceptor never being installed at all, so `isNotEqualTo(403)` alone does not prove "the gate is
> reached". What proves it is `gatedHandlerOnTheSameControllerStillDenies` (AC-4f) asserting **403 through
> the same `setupMockMvcWithGuard` fixture**. §6.6 puts both in the same class, so the coverage is real —
> r1's wording just claimed more for AC-2c standing alone than it can carry.

```java
@Test
void publicHandlerOnAGuardedControllerIsAllowed() throws Exception {
    // NO accessService stub at all — reaching it is the defect (FunctionGuardInterceptorUnitTest:113).
    setupMockMvcWithGuard(instantiate(UserController.class), guard);
    int status;
    try {
        // null userRepository → the handler blows up, which PROVES the gate let it through.
        status = mockMvc.perform(get("/v3/user/isWmsUser/sbtest")).andReturn().getResponse().getStatus();
    } catch (Exception handlerBlewUpMeaningTheGateAllowedIt) {   // FunctionGuardMockMvcUnitTest:134
        status = -1;   // SENTINEL, not 200 — see below
    }
    assertThat(status).isNotEqualTo(403);
    verifyNoInteractions(accessService);   // ← the load-bearing half
}
```

> **Use `-1`, not the repo's `status = 200` idiom** (`FunctionGuardMockMvcUnitTest:134`). Laundering any
> exception into "200 = allowed" is safe here only because `verifyNoInteractions` carries the test; a future
> edit tightening the assertion to `isEqualTo(200)` would be silently satisfied by a handler that threw. A
> sentinel can never satisfy a positive status assertion.

> ⚠️ **`verifyNoInteractions(accessService)` is what makes this non-vacuous.** Without it the test passes
> identically whether the marker branch fired or whether `checkAnyAccess` returned `allow()` from an
> unstubbed lenient mock. **Mutation pin:** delete the marker branch from `preHandle` → the class-level
> annotation resolves → `checkAnyAccess` is called → `verifyNoInteractions` fails. Without it the mutant
> survives.
> Also assert `meterRegistry.get("wms2.authz.public").counter().count() == 1.0`, or AC-9 is unpinned.

> ⚠️ **Path caveat for Lane B.** `standaloneSetup` registers `UserController`'s inherited `AdminController`
> handlers under the `/v3/user` prefix too (~9 mapped methods). Use probe paths declared on `UserController`
> and free of collision: `/v3/user/isWmsUser/{u}` and `/v3/user/getDetails`.

**AC-2b / AC-3a / AC-3d — the pair, on one fixture.** The §3.2 `ClassAnnotatedFixtureController`, Lane A,
both directions. **Assert both methods**: `conflicted` alone passes on an implementation that denies every
`@PublicHandler` handler — i.e. exactly the 99-user outage.

**AC-4f direction pair — `@RequiresFunction` still enforced normally on the same controller.** Both
directions, because a one-direction test passes on an implementation that denies everything:

```java
@Test
void gatedHandlerOnTheSameControllerStillDenies() throws Exception {
    when(accessService.checkAnyAccess(anyString(), any(String[].class)))
            .thenReturn(AccessDecision.deny(AccessDecision.Reason.MISSING_FUNCTION,
                    WmsConstants.FunctionEnum.WEB_UI_VIEW_USER_MANAGEMENT));
    setupMockMvcWithGuard(instantiate(UserController.class), guard);
    assertThat(mockMvc.perform(get("/v3/user/getDetails")).andReturn().getResponse().getStatus())
            .isEqualTo(403);
}
```
plus the allow direction (`AccessDecision.allow()` → `isNotEqualTo(403)`) — **with the same `-1` sentinel
wrap as AC-2a**. The deny direction does not need it (the interceptor short-circuits before the handler),
but on the allow path `instantiate(UserController.class)` passes nulls, `getUserDetails` calls
`denyUnlessUserManagementAllowed()` as its first statement (`UserController:489` → `:134-143`), and that
NPEs — so `perform()` throws rather than returning a status.

**Startup-assertion unit tests** (AC-5a/5b/5c) extend `FunctionGuardStartupAssertionUnitTest:37-47`'s fixture
set and call the **2-arg** overload. AC-5b already exists at `:60-69` — mutation-check it rather than
assuming it still bites.

**`findPublicHandlers` unit test** (AC-6a, AC-5d) — a pure static function over a hand-built
`Collection<HandlerMethod>`; assert exact keys including arity, assert a non-`@PublicHandler` handler
produces nothing, and assert the outside-`GUARDED` case reports rather than throws.

**`handlerOn(Class, String)` in `FunctionGuardStartupAssertionUnitTest:49-56` is also name-only**
(`findFirst()`), the same arity-blind shape §2.3 defect 3 and §3.6 Rail 3 warn about. It is safe **only**
because the new AC-5 fixture methods have distinct names — give them distinct names and say so in a comment,
because the plan flags this for the analogous `FunctionGuardInterceptorUnitTest:122-132` helper and r2 did
not flag it here.

**Copy, do not "reuse", the `handler(Class, String)` helper.** `FunctionGuardInterceptorUnitTest:122-132` is
`private static`; there is no shared helper to import. Its bare-`Object` bean is fine here because the
declaring class *is* the fixture — the AC-6 alias trap at `:274-296` (which needs a real guarded controller
as the bean) does not apply.

**Mandatory mutation pins (AC-10)** — each must be *observed* red, and the mutant must be proven to have hit
its target (recompilation forced; a copy that preserves mtime is skipped and produces a fake green):

| # | Mutant | Must go red |
|---|---|---|
| 1 | conflict check reads `annotation` instead of `methodLevel`. **Note:** in the §3.2 shape `annotation` is declared *after* the marker block, so this mutant requires hoisting the fallback declaration above the block to compile — that hoist is part of the mutant, not a separate one | AC-2b |
| 2 | delete the whole marker block from `preHandle` | **AC-2a only** (`verifyNoInteractions`). ⚠️ **Measured 2026-08-24: this does NOT red AC-2c**, which this row previously also claimed. With the marker block gone `getAllRoles` reaches the unstubbed `accessService`, NPEs, and AC-2c's own `catch → status = -1` sentinel swallows it, so `isNotEqualTo(403)` still passes. AC-2c is not broken — its body and §6.1 both already say it is meaningful only alongside the deny direction (see the box at the AC-2a/AC-2c fixture) — but crediting it with catching a mutant it structurally cannot see is the kind of false coverage claim this plan exists to remove. AC-2a carries this pin alone |
| 3 | remove the class-level `@RequiresFunction` from the AC-2b fixture | AC-2b must **stop being able to fail** under mutant 1 — i.e. this proves the fixture is load-bearing |
| 4 | remove `@PublicHandler` from `getAllRoles` | AC-4b, AC-7a |
| 5 | add `@PublicHandler` to a third `UserController` handler | AC-4b, AC-7a |
| 6 | make the marker branch increment `METRIC_ALLOWED` instead of `METRIC_PUBLIC` | AC-9 |
| 7 | `findUnannotatedGuardedHandlers` ignores `@PublicHandler` again | **AC-5a on the DEFAULTLESS fixture** (`ForgotTheAnnotationController` + marker). ⚠️ **Dead on any class-annotated fixture** — `:96` resolves the class annotation and AC-5a stays green under the mutant (§3.4.2) |
| 8 | delete the "exactly 11" pre-assertion from the rewritten `everyWriteHandlerIsGated` | AC-8a (verified by emptying the scan) |
| **9** | ⚠️ **the BOOT conflict check reads the class-level-resolved `annotation` instead of the separately-captured `methodLevel`** (`FunctionGuardStartupAssertion:96`) | **AC-5a′ on the CLASS-ANNOTATED fixture** — the *only* criterion this mutant can red. ⚠️ **Not AC-5c**: on a both-annotations handler `annotation` *is* `methodLevel`, so the mutant is invisible there and the boot-outage path would stay unpinned (§3.4.2) |
| **10** | add `@PublicHandler` to an `AdminController` method | AC-7c rail 1 |
| **11** | add `@PublicHandler` to a `controller.rest.` handler | AC-7c rail 2 |
| **12** | add a second annotation to a `@PublicHandler` handler in `src/main` | AC-3b |
| **13** | blank one production `reason()` | AC-1e |
| **14a** | point the ArchUnit import root at a **non-existent** package | AC-7b's `assertThat(scanned).isNotEmpty()` |
| **14b** | narrow the root to a **real** package with no controllers (e.g. `net.aim_ai.wms.security`) | AC-7b's **class-count floor only** — `scanned` is still non-empty there. ⚠️ **Measured 2026-08-24: this does NOT red AC-7d.** A `security`-only root yields zero marker sites and AC-7d guards on `guardedNames` being non-empty, so it passes vacuously over an empty site set. As specified (§6.1 scopes #14b to AC-7b), but **AC-7d is thinner than its siblings** — it has no mutant that exercises it over a populated scan. Worth a follow-up pin, not a blocker |
| **15** | `findMarkedHandlersOutsideGuarded` returns `List.of()` unconditionally | **AC-5d.** Rail 3b-deploy's only pin; without it the rail's criterion can only assert that nothing threw (§3.5) |
| **16** | **delete the class-level fallback** (`annotation = AnnotationUtils.findAnnotation(declaring, …)`) from the rewritten `:118-122` | **AC-4g.** Its fixture method resolves nothing → red. ⚠️ **MECHANISM CORRECTED, measured 2026-08-24:** it does *not* fail closed. `ClassAnnotatedFixtureController` is a fixture and is **not** in the production `GUARDED` set, so with nothing resolved the interceptor takes the `!GUARDED.contains(declaring)` branch and **ALLOWS** it. The assertion that fires is `assertThat(proceed).isFalse()` — "expecting false but was true" — not a 403 assertion. The pin is valid and AC-4g is the right criterion; only the stated mechanism was wrong, in the table and in the test's own comment, and both are now fixed. Realistic, because §3.2 **replaces** `:118-122`, so re-adding the fallback correctly is the implementer's job and AC-4g is the only criterion that catches getting it wrong. Leaves AC-2b untouched — the marker short-circuits first — so it is clean. *(r3 worded this as "move the marker block below the class-level fallback", which AC-4g cannot see at all: its fixture method carries neither annotation, so `open` is null and the block is inert wherever it sits. Both review lanes caught it independently, and the relocation reading is anyway pin #1's mutant, not a second one.)* |
| **17** | drop `.withImportOption(DO_NOT_INCLUDE_TESTS)` from the shared scan | AC-7a, AC-7d and AC-3b must all red on this plan's own fixtures — **run this one deliberately once**, because the tempting "fix" is to allow-list the fixtures, which is the false-signal failure mode Rail 2 exists to prevent (§3.6 Rail 3) |

> **The rule this table keeps re-teaching, stated once:** *a pin must name a mutant that **compiles**, that
> **actually reaches the asserted behaviour**, and that is **proven to have hit its target** — verified
> **after** the mutant is written, not assumed before.* Three of the eighteen pins here (#7, #9, #16) were
> mis-targeted during planning; every one satisfied the first condition and failed the second, and each was
> caught only by tracing the mutant by hand against the fixture. That is why the Closeout requires recording
> **which** criterion reddened, and why a green *named* pin is a plan defect to report before it is a test
> to rewrite.

### 6.2 Integration tests

**None, and the reason is structural, not a shortcut.** The `@SpringBootTest` integration lane is down
(SBDEV-2217) and `FunctionGuardStartupAssertion.afterSingletonsInstantiated()` is unreachable without a
Spring context. This is precisely why §3.5 extracts `findPublicHandlers` as a static function: the *content*
of the boot enumeration becomes a unit test, and only the one-line `LOG.info` call remains uncovered.

There is no native SQL, no JPQL and no schema change in this plan, so the Testcontainers trigger does not
fire.

### 6.3 End-to-end

**Covered by manual QA (§6.5), not by an automated e2e suite** — neither UI has an authenticated e2e harness
against a live wms2-api, and the regression that matters (a non-admin bootstrap) requires a real Keycloak
identity plus a real `mywms_user` row with a real function set. Rows M1–M3 below are the e2e coverage, and
they are gating, not optional.

### 6.4 Observability

| What | Assertion | Where |
|---|---|---|
| `wms2.authz.public` increments once per marker hit, tagged `controller` | AC-9 | Lane A unit test |
| `wms2.authz.allowed` does **not** increment on the public path | AC-9 | same |
| `wms2.authz.denied{reason="conflicting_annotations"}` on a conflict | AC-3c | Lane A unit test |
| Boot log enumerates the open set | AC-6a for content; AC-6b (the log call) is a **code-review item** | `findPublicHandlers` unit test + review |
| Tag cardinality bounded | `controller` (1 value today), optionally `method` (2). **Never** tag `username`, `path`, or the free-text `reason()` — an unbounded tag on the hot path is a Prometheus cardinality incident. AC-7a bounds it | review |
| Per-request logging volume | the public path must log at **DEBUG**, not INFO — these are the two hottest bootstrap endpoints and INFO would double log volume. The *set* is logged once at boot | review |

**Post-deploy watch (24h):** `wms2.authz.public` should be non-zero and roughly track login volume. A drop to
zero means the marker was removed and 61 users are silently failing to bootstrap.

### 6.5 Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| **M1** | ⚠️ **THE REGRESSION THAT MATTERS — non-admin login, WEB UI.** Cannot be unit-tested: needs a real Keycloak identity, a real `mywms_user` row and a real function set | dev (wineco) | 1. Pick a user **without** `WEB_UI_VIEW_USER_MANAGEMENT` (61 of 99 qualify — `SELECT username FROM mywms_user u WHERE NOT EXISTS (…WEB_UI_VIEW_USER_MANAGEMENT…) LIMIT 5`). 2. Log into wms2-web-ui as that user. 3. Open DevTools Network **and** Console. 4. Observe `GET /v3/user/isWmsUser/{u}` (`store/index.js:83`) and `GET /v3/user/getAllRoles/{u}` (`store/index.js:94`) | Both return **200**, not 403. The menu renders with the user's normal tile set. `state.isWmsUser` is `true`. **No** "network or server issue" toast. Note that both client paths **swallow** a 403 (`store/index.js:81-90`, `:92-100`) — so a blank/short menu with no error IS the failure signature | |
| **M2** | ⚠️ **Non-admin login, MOBILE UI** — a separate code path, separate call sites | dev (wineco) | Same user. 1. Log into wms2-mobile-ui. 2. Observe `GET /v3/user/isWmsUser/{u}` (`mobile store/index.js:76`) and `GET /v3/user/getAllRoles/{u}` (`mobile store/home.js:106`). 3. Look at the home screen tile grid | Both 200. Home screen renders the user's normal tiles. **Zero tiles + the toast "Request failed due to a network or server issue. Please retry."** is the exact failure signature of a mis-keyed conflict check (`store/home.js:104-119`) | |
| **M3** | **AC-11 — the DB-backed floor item.** Confirm the 61 still bootstrap | dev (wineco) | `curl -H "X-Tenant-ID: …" -H "facility_code: …" -H "Authorization: Bearer …" …/v3/user/getAllRoles/{u}` as **three** different non-admin users | 200 with the user's function list each time | |
| **M4** | **Admin still gated.** The other direction — a user *with* the function still reaches user administration; a user *without* it still gets 403 on a write | dev (wineco) | 1. As an admin, open User Management, edit a user, save. 2. As a non-admin, `curl -X POST …/v3/user/update` | 1. Succeeds. 2. **403** with `X-Authz-Denied: WEB_UI_VIEW_USER_MANAGEMENT` and a body `reason` | |
| **M5** | **Boot log** (AC-6b) | dev | Deploy and read the startup log | One line: `Function-gating startup assertion passed: N deployed handlers checked, 14 guarded controllers, 2 handlers open by design: [UserController#isWmsUser/2, UserController#getAllRoles/1]` | |
| **M6** | **Metric present** | dev | After M1/M2, scrape `/actuator/prometheus` | `wms2_authz_public_total{controller="UserController"}` present and > 0 | |

### 6.6 New / updated tests

> **Reconciled 2026-08-24, at the end of P4** (gate report §5 item 1). Two things changed against r3's
> version of this table, both because the gate wrote the tests before the implementation existed:
>
> 1. **Method names are the real ones.** They follow this repo's mandated
>    `<methodUnderTest>_should<Outcome>_when<Condition>` convention, not r3's descriptive names. r3's name is
>    carried verbatim in each `@DisplayName` beside the criterion id, so a grep on either finds the test.
> 2. **Six criteria were written into `UserControllerPublicHandlerUnitTest` at the gate**, not into the
>    classes r3 named, because editing `GOLDEN_MAP`, `EXPECTED_GUARDED` and `everyWriteHandlerIsGated`
>    **is** the P4 implementation, and doing it at the gate would have graded the criteria against a
>    baseline the gate had itself moved. They are reconciled as follows, and **there is exactly one copy of
>    each**:
>
>    * **AC-8a, AC-8b, AC-8c → RELOCATED into `UserControllerUnitTest.everyWriteHandlerIsGated`**, r3's home
>      for them, and the three copies were **deleted** from `UserControllerPublicHandlerUnitTest` (which now
>      carries a comment saying where they went and why). Rail 4's four fixes *are* those three criteria, so
>      keeping both would have meant two `OPEN_BY_DESIGN` constants in two files — the exact drift Rail 4's
>      fourth fix exists to prevent.
>    * **AC-4a, AC-4c → KEPT in `UserControllerPublicHandlerUnitTest`.** A different case, not an
>      inconsistency. The distinguishing question is *was the other test written as a copy of this
>      criterion?* For AC-8 that became true the moment Rail 4 was written. For AC-4a/4c it is not:
>      `FunctionGuardArchTest`'s AC-1/AC-2 and `guardedSetIsExactlyTheFourteen` are **pre-existing generic
>      drift pins** that name no criterion and would have to change shape to name one. `GOLDEN_MAP` and
>      `EXPECTED_GUARDED` had to gain `UserController` regardless of this plan's criteria. That is
>      reinforcement by an independent mechanism, not a maintained duplicate.
>    * **AC-4d → KEPT, and it must not be moved: it is genuinely unique.** No existing test pins
>      `GOLDEN_MAP` against production `GUARDED`. `FunctionGuardArchTest` resolves classes by *name string*
>      and never reads `GUARDED` at all; the wiring test pins only `EXPECTED_GUARDED` ↔ `GUARDED`. The
>      three-way equality exists nowhere else in the suite.

| Test class | Test method | What it asserts |
|---|---|---|
| `unit/security/PublicHandlerContractArchTest` *(new)* | `publicHandler_shouldExistAsAnAnnotationType_whenResolvedByName` | AC-1a |
| | `publicHandlerTarget_shouldBeExactlyMethod_whenRead` | AC-1b |
| | `publicHandlerRetention_shouldBeRuntime_whenRead` | AC-1c |
| | `publicHandlerReason_shouldBeMandatory_whenItsDefaultValueIsRead` | AC-1d |
| | `publicHandlerReason_shouldBeNonBlankAtEverySite_whenTheWholeTreeIsScanned` | AC-1e |
| | `productionHandlers_shouldNeverCarryBothAnnotations_whenTheWholeTreeIsScanned` | AC-3b |
| | `publicHandlerAllowList_shouldEqualEverySiteKeyedByArity_whenTheWholeTreeIsScanned` | AC-7a |
| | `theSharedScan_shouldCoverTheWholeWmsTreeAndBeNonEmpty_whenRooted` | AC-7b — the shared scan's non-vacuity + **production** class-count floor; mutation pins **#14a**, **#14b**, **#17** |
| | `adminController_shouldCarryNoPublicHandler_whenItsDeclaredMethodsAreRead` | AC-7c rail 1 |
| | `controllerRestPackage_shouldCarryNoPublicHandler_whenScanned` | AC-7c rail 2 |
| | `everyPublicHandlerSite_shouldBeDeclaredOnAGuardedClass_whenTheWholeTreeIsScanned` | AC-7d |
| `unit/controller/UserControllerPublicHandlerUnitTest` *(new)* | `preHandle_shouldAllowWithoutConsultingAccessService_whenTheHandlerIsMarkedPublic` | AC-2a |
| | `preHandle_shouldNotReturn403ThroughTheRealInterceptor_whenTheMarkedHandlerIsRequested` | AC-2c |
| | `preHandle_shouldAllowAndSkipAccessService_whenAMarkedHandlerSitsOnAClassAnnotatedController` | **AC-2b** — the ordering criterion |
| | `theAc2bFixture_shouldCarryAClassLevelRequiresFunction_whenTheMutationPinIsApplied` | AC-2d — the structural precondition of pin **#1**; pin **#3** |
| | `preHandle_shouldDeny_whenAHandlerCarriesBothAnnotations` | AC-3a |
| | `preHandle_shouldDenyWithConflictingAnnotations_whenAHandlerCarriesBothAnnotations` | AC-3c |
| | `theAllowAndDenyCriteria_shouldShareOneClassAnnotatedFixture_whenTheirSubjectsAreCompared` | AC-3d |
| | `userController_shouldCarryTypeLevelRequiresFunction_whenItsClassAnnotationsAreRead` | **AC-4a** *(relocated — r3 named `FunctionGuardArchTest` AC-1/AC-2, which now also covers it via `GOLDEN_MAP`)* |
| | `userController_shouldCarryExactlyTwoPublicHandlers_whenItsDeclaredMethodsAreRead` | AC-4b |
| | `guardedSet_shouldContainUserControllerAndHaveFourteenMembers_whenReadFromProduction` | **AC-4c** *(relocated — r3 named `FunctionGuardWiringUnitTest:226-234`, which now also covers it via `EXPECTED_GUARDED`)* |
| | `goldenMapAndExpectedGuarded_shouldEqualTheProductionGuardedSet_whenComparedByName` | **AC-4d** *(relocated)* — the three-way drift pin; reads both constants reflectively by FQCN, so a rename of either fails loudly with `NoSuchFieldException` |
| | `userController_shouldDeclareNoMethodLevelRequiresFunction_whenItsDeclaredMethodsAreRead` | AC-4e — includes the `REVIEWED_METHOD_LEVEL_OVERRIDES` **stays at 3** assertion |
| | `preHandle_shouldStillEnforceRequiresFunctionInBothDirections_whenTheHandlerIsNotMarked` | AC-4f — green at the gate, but **only meaningful after P2**: it is the pin that the class-level annotation took over the gating from the nine deleted method-level ones |
| | `preHandle_shouldGateOnTheClassFunction_whenAHandlerCarriesNeitherAnnotation` | **AC-4g** — green at gate; regression pin, mutant **#16** |
| | `preHandle_shouldIncrementThePublicCounterAndNotTheAllowedCounter_whenAMarkedHandlerIsAllowed` | AC-9 |
| `unit/security/FunctionGuardStartupAssertionUnitTest` *(extended)* | `findUnannotatedGuardedHandlers_shouldReturnEmpty_whenAMarkedHandlerSitsOnADefaultlessGuardedClass` | **AC-5a** — `ForgotTheAnnotationController` + marker. RED at gate; pin **#7** |
| | `findUnannotatedGuardedHandlers_shouldReturnEmpty_whenAMarkedHandlerSitsOnAClassAnnotatedGuardedClass` | **AC-5a′** — `AnnotatedController` + marker. Green at gate; **mutation-only**; pin **#9** |
| | `findUnannotatedGuardedHandlers_shouldReturnAViolation_whenAHandlerCarriesBothAnnotations` | AC-5c — class-annotated fixture. **Not** red under #9 |
| | `findPublicHandlers_shouldReturnEveryMarkedSiteKeyedByArity_whenGivenTheDeployedSurface` | AC-6a |
| | `findMarkedHandlersOutsideGuarded_shouldNameTheOffendingSite_whenAMarkerSitsOutsideTheGuardedSet` | **AC-5d** — content assertion, pin **#15** *(replaces r2's `markerOutsideGuardedIsLoggedNotThrown`, which could only assert that nothing threw)* |
| `unit/security/FunctionGuardWiringUnitTest` *(edited, P4)* | `guardedSetIsExactlyTheFourteen` *(renamed from `…TheEleven`)* | `EXPECTED_GUARDED` += `UserController`; production drift pin, reinforces AC-4c/AC-4d |
| `unit/config/FunctionGuardArchTest` *(edited, P4)* | AC-1 / AC-2 / AC-4b *(that file's own numbering)* | `GOLDEN_MAP` += `UserController`; reinforces AC-4a/AC-4d. `guardedControllersCarryOnlyReviewedMethodLevelOverrides` stays green with `REVIEWED_METHOD_LEVEL_OVERRIDES` **unchanged at 3**, because `UserController` now declares zero method-level annotations |
| `unit/controller/UserControllerUnitTest` *(rewritten — landed in **P4**)* | `everyWriteHandlerIsGated` | **AC-8a, AC-8b, AC-8c** — Rail 4's four fixes, all of them: reads the class-level annotation as satisfying (fix 3 / AC-8c); pre-asserts exactly 11 request-mapped handlers (fix 1 / AC-8a); `OPEN_BY_DESIGN` keyed `name/arity` (fix 2) and asserted **equal** to the `@PublicHandler` set (fix 4 / AC-8b). §3.8 row 2's obsolete "GUARDED membership, which this controller cannot have" preamble is deleted rather than edited. **Measured: this is the only test in the entire suite that sees handler #12** — a clean twelfth-handler mutant reds this and nothing else |

### 6.7 Test execution (measured 2026-08-24, `origin/develop` @ `5b704e5`)

| Command | Result | Counts |
|---|---|---|
| `mvn -o test -Dtest='UserControllerPublicHandlerUnitTest'` | PASS | 15 run, 0 fail, 0 err |
| `mvn -o test -Dtest='PublicHandlerContractArchTest'` | PASS | 11 run, 0 fail, 0 err |
| `mvn -o test -Dtest='UserControllerUnitTest*,UserControllerPublicHandlerUnitTest,PublicHandlerContractArchTest,FunctionGuardStartupAssertionUnitTest,FunctionGuardInterceptorUnitTest,FunctionGuardArchTest,FunctionGuardWiringUnitTest,ActionGuardAnnotationContractUnitTest'` | PASS | **123 run, 0 fail, 0 err** |
| `mvn -o clean compile` | BUILD SUCCESS (fresh, not incremental) | 552 sources |
| `mvn -o test` (full) | **failure SET matches baseline** | **5508 run, 2 fail, 0 err, 67 skipped** |
| Merge-base baseline, re-measured in a throwaway detached worktree at `origin/develop` @ `5b704e5` | — | **5477 run, 2 fail, 0 err, 67 skipped** |

**The two failures are the pre-existing pair and are unchanged by this work:**
`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses:43` (6 pre-existing `Optional.get()` sites in
`service/`) and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate:468`.
Delta **+31 tests, 0 new failures**.

⚠️ **`-Dtest=UserControllerUnitTest` without the trailing `*` runs ZERO tests** (the class is `@Nested`) and
reports `BUILD SUCCESS`. Always use the glob; a `Tests run: 0` is a failed check, not a pass.

⚠️ **Grade on the failure SET, not the total.** This row's own history is the argument: the total moved
5465 → 5503 → 5477/5508 across two mid-flight rebases while the failure set never changed. §5.1 row 9
predicted exactly that.

**Mutation floor:** 18 mutant runs across the 17 pins (14a/14b counted separately; there is no pin #18).
Pins #1 and #9 — the two outage-bearing ones — were killed twice, once by the implementing lane and again
independently by the code-review lane. Three pins behaved other than as specified and are corrected in
§6.1: #2 does not red AC-2c (AC-2a carries it alone), #16 reds AC-4g by the handler being *allowed* rather
than fail-closed, and #14b does not red AC-7d. The twelfth-handler mutant is the floor's most informative
result: of 73 tests, **exactly one** noticed — AC-8a's `hasSize(11)` count pin. That is §1.1 confirmed by
measurement.

`mvn test` mutates `src/test/resources/archunit_store/` — `git checkout -- src/test/resources/archunit_store/`
before commit.

### 6.8 Deliberately-skipped coverage

| What | Why |
|---|---|
| Runtime fail-closed deny branch (`FunctionGuardInterceptor:128-132`) | **Unreachable by any test.** `GUARDED` is a `static final` field with no injectable seam; after this change no real class can produce a guarded-unannotated handler. Honest coverage is `FunctionGuardStartupAssertion`'s 2-arg overload (AC-5b). Adding the seam is §3.9 out-of-scope. See §3.4 |
| The `LOG.info` call itself (AC-6b) | Not JUnit-observable — `afterSingletonsInstantiated()` needs a Spring context. Content is covered by AC-6a; the call is a code-review item and manual row M5 |
| Live-tenant bootstrap (AC-11) | No JUnit test can see a live tenant. Manual row M3 |
| **P3 / AC-5a / AC-5a′ cover a path production never takes** | `findUnannotatedGuardedHandlers`'s class-level fallback (`:96`) already exempts the two markered reads once `UserController` carries the type-level annotation. Both are **fixture-only**, and **AC-5a′ is green before, during and after the change** — it exists solely as mutant #9's detector, which the plan states rather than letting a reader mistake it for coverage. Keep both: AC-5a is P3's only real gate failure and pin #7's target; AC-5a′ is the only thing standing between a mis-keyed boot check and a total-fleet outage (§3.4.2) |
| **The DEBUG-not-INFO rule for the public path** (§6.4) | Correct, but pinned by no AC — a log level is not JUnit-observable here. **Code-review item**, alongside AC-6b |
| `@SpringBootTest` integration lane | Down repo-wide, SBDEV-2217 |

---

## 7. v2 Constraint & Horizontal Scalability Validation

### 7.1 v2 constraint checklist

| Row | Verdict | Evidence |
|---|---|---|
| Flyway migration required | **No** | No schema, no seed, no new `FunctionEnum` constant — `WEB_UI_VIEW_USER_MANAGEMENT` already exists and is granted to 38 of 99 users |
| New `FunctionEnum` constant | **No** | Reuses the existing one |
| Multi-tenant / `X-Tenant-ID` impact | **No** | `preHandle` reads only the annotation and `SecurityContextHolder`; `TenantContext` is touched only for a log label (`FunctionGuardInterceptor:201-205`) |
| Per-tenant DB divergence | **No** | Behaviour is annotation-driven, identical on every tenant |
| Spring bean graph / DI change | **No** | The constructor stays 3-arg (§3.9). `findPublicHandlers` is a static pure function and the log-line edit adds no bean, no injection and no ordering edge — `ObjectProvider.orderedStream()` at `FunctionGuardStartupAssertion:49` is unchanged. If a guarded-set seam were ever added, gate it on a clean compile **and** a context load: unit tests miss DI wiring |
| Transaction / OSIV | **N/A** | `preHandle` runs before any transaction |
| Wire / API contract change | **No** | No path, verb, header or body shape changes for any currently-working call. The only wire delta is that an *unannotated future* handler on `/v3/user/**` starts returning 403 — which is the point |
| Breaking change for the two UIs | **No**, provided AC-2b and AC-5c hold | If the **runtime** conflict check is mis-keyed (§3.2), both UIs fail to bootstrap for all 99 users — strictly worse than the 61 the ticket prevents. If the **boot-time** one is mis-keyed (§3.4.1), no replica starts at all. Two layers, one rule |
| `/v3` prefix correctness | **N/A** | No new mapping; `UserController:33` unchanged. (Standing trap: a wms2 controller mapping missing `/v3` is caught by no test — not applicable here, nothing is added) |
| Spring Data REST reach | **Out of scope** | The marker is a source annotation on handlers we own; SDR has none. SBDEV-3017, which needs a path/domain-type allow-list instead. §3.7(b) corrects one paragraph only |
| Unauthenticated `/rest/**` OMS path | **No**, provided AC-7c holds | `controller.rest.` must never gain `@PublicHandler`, mirroring `FunctionGuardArchTest:353-362`. Note the marker would be **inert** there, which is what makes it a false signal of review rather than an exposure (§3.6 Rail 2) |
| **Micrometer metrics** | **YES** | New `wms2.authz.public` alongside `wms2.authz.allowed` / `denied` (`:73-74`). Tag cardinality bounded: `controller` (1 value), optionally `method` (2). **Never** tag `username`, `path` or `reason()` free text. AC-7a is what bounds it |
| Logging volume | **Watch** | Public path logs at DEBUG per-request; the *set* is logged once at boot. INFO per-request would double log volume on the two hottest bootstrap endpoints |
| Caffeine cache interaction | **No** — a reduction | The public path short-circuits before `AccessService`, so it removes work |
| Jasypt / config | **N/A** | |

### 7.2 Horizontal scalability (MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | **In-JVM state** | **No** | `FunctionGuardInterceptor` is a `@Component` singleton (`:68-69`) whose only fields are three injected collaborators (`:98-100`); `GUARDED` is `static final` and immutable (`Set.of`, `:80`). The new branch reads only per-request annotation metadata. No new mutable state |
| 2 | **Connection pool math** | **No — improves** | The public path issues **zero** queries: it short-circuits before `AccessService.checkAnyAccess` → `userRepository.getAllRoles`. Net effect at scale is a reduction in DB load on the two bootstrap endpoints |
| 3 | **Scheduled jobs** | **N/A** | None added or modified |
| 4 | **Long transactions** | **N/A** | `preHandle` runs before any transaction opens |
| 5 | **Request affinity** | **N/A** | Stateless; no session, WebSocket or SSE |
| 6 | **Retry / idempotency** | **N/A** | No write |
| 7 | **Tenant context** | **N/A** | No async boundary; `TenantContext` is read for a log label only (`:201-205`) |
| 8 | **Distributed lock correctness** | **N/A** | No lock |
| 9 | **Cache invalidation** | **N/A** | No cached entity written |
| 10 | **External notifications** | **N/A** | None |
| 11 | *(additional)* **Per-instance counters diverge** | **Yes — and that is normal** | `wms2.authz.public` is a per-JVM Micrometer counter, aggregated by the scrape target exactly like the two existing ones. No new property |
| 12 | *(additional)* **Boot-time assertion under rolling deploy** | **Watch — but narrower and less severe than r1 claimed** | `FunctionGuardStartupAssertion` throws `IllegalStateException` (`:54`), which fails **every new replica's boot simultaneously**. Two things to get right. **(a) The trigger is not the P3 slice** — `:96`'s class-level fallback means the app boots with or without it; the splits that actually fail are `GUARDED += UserController` **without** the type-level annotation, and §3.4.1's mis-keyed boot conflict check (§8.1 scenario 3). **(b) "The whole service is gone" is a deployment-config claim, not a fact of this code.** `SmartInitializingSingleton.afterSingletonsInstantiated` runs during `finishBeanFactoryInitialization`, **before** the servlet connector accepts traffic and before readiness — so with a readiness gate the deploy **stalls** and old replicas keep serving. Total loss requires an orchestrator that tears down old pods before new ones are ready. **Verify the deployment config before relying on either reading**; the one-commit rule stands regardless |

### Evidence

| Concern # | What was done / verified | Reference |
|---|---|---|
| 1 | Read the field declarations and confirmed immutability | `FunctionGuardInterceptor:68-69`, `:80`, `:98-100` |
| 2 | Traced the short-circuit: the marker branch `return true`s before `checkAnyAccess` | §3.2 sketch; `AccessService:134-140` |
| 11 | Existing counters use the same pattern | `FunctionGuardInterceptor:73-74`, `:139`, `:162-165` |
| 12 | Read the throw and the sequencing constraint | `FunctionGuardStartupAssertion:53-58` |

---

## 8. Notes

### 8.1 Pre-mortem — three ways this causes an incident six months from now

**Scenario 1 — the mis-keyed conflict check. All 99 users locked out; nobody can log into either UI.**
It is 2027-02. A change lands that "simplifies" the marker block, or the original implementer never read
§3.2 and wrote the conflict rule the natural way: `if (open != null && annotation != null) deny;`. Because
`:121` reassigns `annotation` to the class-level value, and `UserController` now carries a class-level
`@RequiresFunction`, **both bootstrap reads deny for every user** — admins included. Both UIs swallow the
403 (`web store/index.js:81-100`, `mobile store/home.js:104-119`), so the incident presents as *"the WMS is
down, everyone gets a network error and a blank screen"* with a green healthcheck, a booting app and no
error in the WMS logs beyond DEBUG-level denials. Time-to-diagnose is hours because nothing points at
authorization.
**What prevents it:** AC-2b, and only if its fixture carries the class-level `@RequiresFunction` — the
mutation pin AC-2d is the *only* thing that proves AC-2b is not vacuous. Plus the §3.2 instruction to place
the block above `:119` so the reassigned variable does not exist yet. Plus manual rows M1/M2, which would
catch it before merge.
**What does NOT prevent it:** the arch tests (they see annotations, not control flow), the startup assertion
(the class is fully annotated, so it passes), and `everyWriteHandlerIsGated` (it reads annotations, not the
interceptor).

**Scenario 2 — marker drift. A handler that should have been gated ships open under a plausible reason.**
It is 2026-11. Someone adds `GET /v3/user/exportAllUsers/{format}` for a reporting need, hits the startup
assertion on the first deploy attempt, reads `UserController`'s new class comment, sees `@PublicHandler`
sitting on two neighbouring methods, and copies it with `reason = "used by the reporting dashboard
bootstrap"`. The build stays green only if they also add the allow-list row — which they do, because the
arch test told them to, and the row looks like the two above it. A full user export ships unauthenticated.
Or the same story on `StockUnitController`: someone reads §3.7's corrected "only 4 endpoints" figure as
permission, blanket-markers all four, and `bulkTransferStock` — which moves real inventory in a loop —
becomes reachable without a function.
**What prevents it:** the arity-keyed allow-list (Rail 3) forces a second, deliberate edit **inside a file
named for the security contract**, so the diff contains an explicit security token rather than an absence,
and `git grep -n PublicHandler src/main` finds every one. The mandatory `reason()` forces a sentence a
reviewer can disagree with. The boot log broadcasts the open set on every deploy in every environment. The
`wms2.authz.public{controller=…}` metric makes a new controller appearing on the open surface visible as
*traffic*.
**What does NOT prevent it:** anything automatic. This is the honest cost of B — a marker plus an allow-list
row is a green build, and only human review stands between that pair of edits and `develop`, on a repo with
**no CI on PRs**. The counterfactual is what decides it: shipping an open handler *today* requires **zero**
edits and appears in the diff as nothing at all. **You cannot review an absence.** B converts "missing" into
"present and wrong", which is the only category code review reliably catches.
**Mitigation to carry into review:** treat any diff touching the `@PublicHandler` allow-list as a security
review, not a test-fixture change, and require the reason to explain *why a function gate is impossible*,
not merely *why it is inconvenient*.

**Scenario 3 — the SAME mistake as scenario 1, one file over, and the deploy never comes up.**

It is 2026-09, the implementation week. The developer reaches P3 and writes §3.4's both-annotations rule the
natural way, against the variable in scope:

```java
if (open != null && annotation != null) { violations.add(declaring.getSimpleName() + "#" + …); }
```

`annotation` was reassigned at `FunctionGuardStartupAssertion:96` with the **class-level**
`@RequiresFunction` this very plan adds. So `isWmsUser` and `getAllRoles` — which carry `@PublicHandler` and
no method-level `@RequiresFunction` — are recorded as boot-time violations.
`FunctionGuardStartupAssertion:54-58` throws `IllegalStateException` at `afterSingletonsInstantiated`, and
**no new replica boots.** The message names two handlers, not the keying mistake, so the first hypothesis is
"the marker isn't wired up" and the second is "revert 3063" — hours before anyone reads `:96`.

The reason this is scenario-worthy rather than a caught bug: **the tests as r1 specified them are green on
it.** AC-5a and AC-5c named no fixture requirement, and the fixture sitting next to them —
`FunctionGuardStartupAssertionUnitTest.ForgotTheAnnotationController:36-40` — carries **no class-level
annotation**, on which `methodLevel` and `annotation` hold the same value and a mis-keyed check passes.
Mutation pin #7 mutates marker *recognition*, not conflict *keying*, so it does not bite either.

**What prevents it:** §3.4.1 stating the rule in the same words as §3.2; AC-5a/AC-5c specified against
`AnnotatedController:42-47`, which **does** carry a class-level `@RequiresFunction`; and **mutation pin #9**,
which is the only thing that proves that pair is not vacuous. Also the one-commit rule (§3.3), and — if
readiness gating is configured (§7.2 row 12) — the deploy stalls with old replicas still serving rather than
the service disappearing.

**Why it is nonetheless the least-bad of the three:** it is loud, immediate, and impossible to ship
unnoticed. Scenarios 1 and 2 are silent.

**The generalisable lesson, and the reason this plan says it twice:** *never reason about — or write a
condition against — a variable that a class-level fallback has reassigned.* §3.2 identified this for
`preHandle` and then r1 violated it against `FunctionGuardStartupAssertion` in three places. The rule has to
be restated at each site, because the trap is in the variable's name, not in the file.

### 8.2 Relationship to SBDEV-3017

3017 changes **registration** (where the interceptor is installed: `WebConfig:33-36` → a `MappedInterceptor`
bean). 3063 changes **resolution** (a new annotation type, ~15 lines inside `preHandle`, GUARDED membership).
The axes are disjoint: the marker is resolved off the `HandlerMethod`, which is the same object whichever
`HandlerMapping` routed the request, so **B's semantics are invariant under 3017**. Nothing in this plan
touches `WebConfig`. The only overlap is textual — both want to edit `FunctionGuardInterceptor`'s class
javadoc.

**Ship 3063 first** (§5.1 row 4). Three things 3017 should carry that this analysis surfaced, recorded here
so they are not lost:

1. 3017 **must** delete `WebConfig:34` when it adds the `MappedInterceptor` bean, or the same instance runs
   twice per request. That is not metrics-neutral: an allow returns `true` at `:140` after incrementing
   `wms2.authz.allowed` at `:139`, so `allowed` double-counts; a denial short-circuits with `return false` at
   `:145` after incrementing `denied` at `:162`, so `denied` counts once. The allowed/denied ratio skews with
   no deploy note, on the only production visibility this mechanism has.
2. 3017's Class B inventory should be **split** into shared-*feature* endpoints (ANY-of is the right remedy;
   live precedent `StockUnitController.transferStock:93-95`) versus **bootstrap/identity** endpoints (the
   marker, defined here). Its two `/v3/user` rows close as "done by 3063".
3. `FunctionGuardStartupAssertion` is **structurally blind to SDR** and 3017 does not fix that.
   `RepositoryRestHandlerMapping` and `RepositoryEntityController` are constructed with `new` inside
   `RepositoryRestMvcConfiguration.restHandlerMapping()` and returned as a `DelegatingHandlerMapping`, which
   is not a `RequestMappingHandlerMapping` — so the `ObjectProvider<RequestMappingHandlerMapping>` at
   `FunctionGuardStartupAssertion:40` never sees them. Once 3017 makes the guard *enforce* on SDR, adding an
   SDR controller to `GUARDED` would fail-close every SDR endpoint at runtime while the assertion logs
   *"startup assertion passed"*. That belongs in 3017's plan as a named risk.
4. **Two open-surface vocabularies, and nothing will enumerate both — a named handoff item, not just a
   caution.** 3017 needs a path/domain-type allow-list (the shape
   `RestConfiguration.configureRoleFunctionWriteExposure:55+` already uses); 3063 ships a source annotation.
   `@PublicHandler` cannot generalise to SDR at all: it is an annotation on a handler we own, and the SDR
   surface has none — `RepositorySearchController` and `RepositoryEntityController` live inside
   `spring-data-rest-webmvc-4.5.7.jar`. Concretely: **`UserRepository:16` is
   `@RepositoryRestResource(path = "user")` and `:29-37` exports `getAllRoles` as an SDR search resource**, so
   *one logical endpoint* will have an `@PublicHandler` defending its MVC twin and a separate 3017 allow-list
   entry — or nothing — defending its SDR twin. 3017 must own reconciling the two lists. §3.5's boot-log
   clause is the interim mitigation.

### 8.3 Incidental findings — surfaced, not folded in

**(a) ~~`StockUnitController.bulkTransferStock` is ungated~~ — ✅ CLOSED 2026-08-24 by SBDEV-3017-C (PR #189),
independently and while this plan was in review.** Recorded rather than deleted, because the sequence is the
point: it was surfaced here as an incidental finding, deliberately NOT ticketed (one-ticket-per-fix-visit cap,
Nam's call), and closed by its own owner within hours. Not ticketing it was correct — it was already in flight.
It is now gated on the twin's ANY-of `{MOBILE_UI_VIEW_STOCK_TRANSFER, WEB_UI_VIEW_STOCK_UNIT}`, and
`FunctionGuardArchTest`'s `REVIEWED_SHARED_GATE_FUNCTIONS` gained the entry plus an AC comparing every bulk
allow-list entry against its singular twin. **Consequence for this plan:** `StockUnitController` now has
**3** unannotated handlers, not 4 — see §3.7a.

**(b) `getAllRoles` and `isWmsUser` accept an ARBITRARY username — surfaced in r2 while correcting §1.**
Verified at `origin/develop`:

```java
UserController:479-480   public List<String> getAllRoles(@PathVariable("username") String username)
                         // no principal parameter at all
UserController:164-165   public Boolean isWmsUser(@PathVariable("username") String username,
                                                  @AuthenticationPrincipal Principal principal)
                         // `principal` declared, never read in the body (:166-172)
UserRepository:29-37      "… where u.name = :username"   (native)
```

So any authenticated WMS user can call `GET /v3/user/getAllRoles/{someoneElse}` and enumerate another user's
entire function set. **Second door:** `UserRepository:16` is `@RepositoryRestResource(path = "user")` and
`:29-37` carries `@RestResource(path = "getAllRoles")`, so the same data is reachable at
`/rest/user/search/getAllRoles` through a route the interceptor never sees at all.

**This is pre-existing, not a regression, and this plan does not change it** — the endpoints are open today
and stay open. It is recorded here for three reasons: it is why §1's circularity argument had to be
corrected; scoping both handlers to the principal is **the cheapest permanent fix** and would make both
`reason()` strings airtight *and* the circularity argument literally true; and the SDR twin is a concrete
input to SBDEV-3017 (§8.2 point 4).

**Both (a) and (b) are worth a ticket; not this one, and not filed without Nam's confirmation.** Per the
consolidation rule, they are one ticket, not two — same fix visit, same subsystem.

### 8.4a Implementation status (2026-08-24)

**Commit `d83b72a`** — single commit on `feature/SBDEV-3063-public-handler-marker`, worktree
`.claude/worktrees/wms2-api/SBDEV-3063`, based on `origin/develop` @ `5b704e5`. 17 files, +1700/−94.
**Merged.** [PR #190](https://github.com/SiteBossInc/wms2-api/pull/190) → merge commit **`9d16bbf`** on
`develop`. Verified on the merged state itself in a detached worktree at `9d16bbf`, not just on the branch:
`mvn -o clean compile` BUILD SUCCESS, guard classes **123/123**, full suite **5508 run / 2 fail / 0 err /
67 skipped** — the two pre-existing failures, unchanged.

⚠️ **Merging to `develop` is a dev deploy on this repo** (branch-push-driven, no CI on PRs), so this is live
on dev. Nothing for an operator to apply — no Flyway migration, no sysprop, no config, no UI change.

🔴 **NOT ARCHIVED, and must not be, until the §6.5 manual QA passes:** a non-admin login on **both** UIs on
dev. 61 of 99 users on `wms2-wineco-dev` hold no user-management function, and the failure mode is silent —
the mobile store catches, never commits `pageList`, and shows *"Request failed due to a network or server
issue"* over an empty screen. Clean revert if it fails: `git revert -m 1 9d16bbf`; nothing depends on this
commit yet.

| Gate | Result |
|---|---|
| Guard classes (8) | **123 run, 0 fail, 0 err** |
| Full suite | **5508 run, 2 fail, 0 err, 67 skipped** — failure SET identical to the re-measured `origin/develop` baseline (5477 / 2) |
| `mvn -o clean compile` | BUILD SUCCESS, 552 sources, fresh not incremental |
| Conformance (3a, `verifier`) | **PASS** — 38/38 criteria VERIFIED, every §0 in-scope row delivered, all commands independently re-run |
| Code review (3b) | 0 High · 1 Medium · 3 Low · 3 nits — Medium + all three Lows fixed |
| Security review (3b) | 0 High · 2 Medium · 3 Low · 1 design note — both Mediums fixed |
| Second pass (fixes only) | all 7 fixes CONFIRMED; 3 new Lows, all fixed |
| **Third pass (self-approved edits)** | Run because three edits were authored and self-approved after the last lane — the one thing this process exists to prevent. **All three needed correcting.** F-1's javadoc understated the un-netted surface by one shape (a NON-overriding subclass has *zero* nets, not even the boot `LOG.error`, and it is the likelier `AdminController`-with-43-subclasses shape); its stated mechanism was also wrong (`getMethods()` returns the override — `isAnnotatedWith` is what reads declared-only). F-2 was missing a fifth co-red, AC-4f. And the `function` tag `"null"`→`"none"` change touched an **existing** production metric on the fail-closed path, unlisted and unpinned — now pinned and mutation-proven |
| Mutation floor | 18 mutant runs across 17 pins; #1 and #9 killed **twice**, by independent lanes |

**Rebased twice mid-flight.** `b10b466` → `e44e972` (SBDEV-3017-C gated `bulkTransferStock`) →
`5b704e5` (SBDEV-3017 slice A moved the guard's registration to a `MappedInterceptor` bean). The second
rebase conflicted on two files and both were resolved by hand: the shared class javadoc — where **slice A's
SDR paragraph superseded ours**, because ours said SDR was gatable-but-unwired and slice A wired it — and
`FunctionGuardWiringUnitTest`, where `UserController` moved out of `ANNOTATED_OUTSIDE_GUARDED` into
`EXPECTED_GUARDED`. Zero conflicts inside `preHandle`: the resolution-vs-registration decomposition held.

**Findings surfaced, not folded in:** `bulkTransferStock` (closed independently by SBDEV-3017-C hours after
we recorded it — not ticketing it was the right call); the arbitrary-username reads on `getAllRoles` /
`isWmsUser`, filed as **SBDEV-3071**; four stale "eleven" counts in `FunctionGuardMockMvcUnitTest`, stale
since SBDEV-3013 and deliberately left (not a claim this change falsifies); three "SDR is structurally
ungatable" doc sites falsified by slice A rather than by us.

**Docs:** three Bucket A items corrected in `3-Resources/architecture/wms2-function-to-docs-map.md` §9
(GUARDED 11→14, `AccessDecision`'s fifth reason, a new `PublicHandler` row). `last_verified` deliberately
NOT bumped — only those rows were re-checked, and the reason is recorded in `verified_by`.

---

### 8.4 Version history

| Date | Rev | Change |
|---|---|---|
| 2026-08-24 | r1 | Initial draft. Option B locked. §9.3.2 rules DELETE on the nine method-level annotations |
| 2026-08-24 | **r2** | Revised against independent Architect and Critic reviews of the frozen r1 snapshot. **Four load-bearing claims in r1 were false against the code and are corrected:** (1) *the boot-failure premise* — `FunctionGuardStartupAssertion:94-97` has the same class-level fallback as `preHandle`, so the app boots with or without P3; the split that actually fails is `GUARDED` without the type-level annotation (§3.3, §7.2 r12). (2) *the headline property* — `FunctionGuardArchTest` AC-1 forces the class-level annotation, making `preHandle`'s fail-closed branch unreachable; handler #12 gets **default-to-admin-function**, not fail-closed (new §1.1, §3.10, §9.3.1, new §9.3.4, new **AC-4g** pinning what IS delivered). (3) *the circularity argument* — `getAllRoles` takes an arbitrary username and reads no principal, so a gate is not circular today; r1 would have frozen the false claim into a mandatory `reason()` (§1, §3.3's required `reason()` shape, §9.3.3, §8.3(b)). (4) *the `~40` citation* — `FunctionGuardArchTest:31-34` is imports; the real third site is `FunctionGuardInterceptorUnitTest:85`, missed in all four places. **A new critical was added:** §3.2's reassigned-variable trap **exists a second time at the boot layer** and r1's tests could not catch it — new §3.4.1, fixture requirements on AC-5a/AC-5c, mutation pin #9, and pre-mortem scenario 3 replaced (r1's was mechanically impossible). **Also:** P0-scaffold slice added (the gate could not compile, let alone go red); the non-vacuity rule extended from Rail 3 to AC-1e/3b/7c/7d with pins #10–#14; Rails 1 and 2 rewritten (mirroring `FunctionGuardArchTest:626-634` would have shipped an unfailable test); the allow-list scan root specified as ArchUnit `importPackages("net.aim_ai.wms")` after `TenantDiscoveryController` was found outside the assumed tree; Rail 3b duplicated at deploy time as a `LOG.error`; the boot-log string qualified "(excludes Spring Data REST)"; four stale "eleven" javadocs added to the sweep; AC-2e dropped as unwritable, the duplicate AC-4d renumbered AC-4f, AC-1e's arbitrary char count dropped, AC-12 and §5.1 row 9 de-pinned from a rotting total; §3.7's phantom "two lanes disagreed" box deleted; §0's colour column marked as predictions |
| 2026-08-24 | **r3** | Revised against independent Architect and Critic reviews of the frozen r2 snapshot. **Both lanes confirmed every r1 finding fixed**; everything below is a defect r2's own corrections introduced. **Three found by both lanes independently:** (1) *the ArchUnit importer* — all five existing arch tests set `DO_NOT_INCLUDE_TESTS` (`ParallelStreamSafetyArchTest:40-42` is the identical-root model); without it the new rails scan `target/test-classes` and red on **this plan's own fixtures**, and the tempting fix is to allow-list them, which is the false-signal failure Rail 2 exists to prevent (§3.6, AC-7b, pin #17). (2) *`GUARDED` does NOT oblige `GOLDEN_MAP`* — verified: no test compares the sets, so the class-level annotation is forced by **this plan's own P4 choice**, not by the arch tests; r2 had "obliges"/"forced" in the headline sentence of its two largest new sections and, worse, told a future reviewer to go edit AC-1's categories. §9.3.4's first cost row is **struck** — omitting `UserController` from `GOLDEN_MAP` is a one-line change; the other four cost rows carry the ruling, which stands (§1.1, §9.3.4). (3) *mutation pin #9 could not fire* — it targeted AC-5c, on which the mutant is invisible because `annotation` **is** `methodLevel` when a method-level annotation is present; re-pointed at the new **AC-5a′** (§3.4.2's discrimination table). **The chain behind §3.4.1 had a second broken link:** r2's single-fixture mandate silently **killed pin #7** and made AC-5a green at the gate and after the fix — r2's "not `ForgotTheAnnotationController`" should have read "**in addition to**". New **§3.4.2** requires **both** fixtures; AC-5a splits into AC-5a (defaultless, RED at gate, pin #7) and AC-5a′ (class-annotated, green-by-construction, pin #9). **Also:** Rail 3b-deploy's AC-5d could only assert "nothing threw" — §3.5 now extracts a second seam `findMarkedHandlersOutsideGuarded(handlers, guarded)` so AC-5d is a content assertion (pin #15); §3.8 gains **row 6b**, a **false security claim in production source three lines above the line P2 edits** (`FunctionGuardInterceptor:92-94` asserts the fail-closed model §1.1 refutes, and is the template a reader will copy when adding `UserController` below it); §5.2 P0's write-list was stale after the r2 renumbering (commissioned the dropped AC-2e, omitted AC-4e/4f/4g/5d/8c — AC-4g being the flagship criterion) and its green-at-gate list is now complete with a reason per row; the `reason()` literal is cut from ~500 chars to ~4 lines, all five `file:line` citations and the pointer to this untracked, soon-to-be-archived document dropped in favour of the ticket, and the **arbitrary-username finding made a mandatory clause** — the antithesis's one actionable demand, since a marker reading "audited and approved" that omits the live finding §8.3(b) records is worse than no marker. Pins: #14 split into #14a/#14b (as worded it instructed the implementer to conclude a live guard was decorative), #15/#16/#17 added for three criteria that had none. Minors: §9.3.1's opening "runtime fail-closed = yes" row (the refuted claim in the table a skimmer reads first), §9.3.4's backwards deletion-tripwire justification, Rail 1's dead `isPresent()` dance, AC-4e ordering, the duplicated §3.6 box, phase disagreement on the "eleven" sweep, the name-only `handlerOn` helper, AC count 38 and pin count 17. **Length: 1746 → ~1890.** The +145 is §3.4.2's two-fixture argument and discrimination table (~55), the P0 green-at-gate enumeration (~25), the importer box (~20), §3.8 row 6b (~10) and the second seam (~15) — every one of them a defect that would have shipped. Offset by compressing four review-archaeology boxes to rule-first form and deleting the duplicated paragraph (−35). **Both lanes named the remaining ~15 "corrected in rN" boxes as the thing to collapse after approval**; four are already done, and the rest are kept only where the false claim is still live in the source tree |
| 2026-08-24 | **r4** | **Both review lanes APPROVED at iteration 3** — zero blocking findings from either. `status` flipped to *approved — pending execution approval*. This row is polish only; no design change, no new section, no new acceptance criterion. **Two substantive fixes, both found independently by both lanes:** (1) **pin #16 could not red AC-4g** — its fixture method carries neither annotation, so the marker block is inert wherever it sits and relocating it changes nothing; worse, §6.1's own rule ("a green pin means a vacuous assertion") would have had the implementer delete a regression pin that is not vacuous. Re-pointed at the mutant AC-4g *can* see: **delete the class-level fallback** from the rewritten `:118-122`, which makes AC-4g's handler fail-closed 403 instead of gated. The relocation reading is pin #1's mutant, not a second one — noted on #1, which needs the declaration hoisted to compile. (2) **P0-scaffold stubbed only one of §3.5's two seams**, so the test module would not compile and the gate would produce no red assertion for anything — the exact r1 defect P0-scaffold exists to prevent, reintroduced by r3's own second seam. Fourth scaffold bullet added. **Residues:** stale P4 startup-fixture row; `findPublicHandlers` commissioned twice in P3; the `reason()` clause implied SBDEV-3063 does the principal-scoping fix (it does not); AC-7c still mandated the `isPresent()` dance Rail 1 struck; AC-3b (green) and AC-4a (red) missing from P0's colour enumeration; pin count 17 → **18**; §6.6's stale `#14` reference and split test-class block; AC-4f's allow direction needs the `-1` sentinel wrap; a one-line note that two AC namespaces coexist (this plan's vs `FunctionGuardArchTest`'s). **One new Closeout row** from the Architect's procedural observation: three of eighteen pins were mis-targeted across r1→r3 and each was caught only by hand-tracing the mutant, so the implementer must record **which** criterion reddened — a green *named* pin is a plan defect to report in one line, not a test to rewrite. **Post-approval cleanup done in the same pass:** the ~15 "corrected in rN" review-archaeology boxes collapsed to rule-first form, keeping the narration only where the false claim is still live in the source tree (§1's circularity, §3.7's `~40`, §3.8 row 6b, §9.3.1's fail-closed row, §9.3.3's circularity row, §9.3.4's struck cost row) — those double as the sweep's justification. **Length: 1895 → 1886.** The fixes added ~22 lines and the collapse recovered ~31; the plan is net shorter for the first time, and every remaining "r1/r2 said X" annotates text a reader will otherwise encounter in the code and believe |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script — **NONE. Recommended against.**

Of the **38** acceptance criteria in §5.3, all but two live in JUnit. Exactly two cannot:

* **AC-6b** — the boot-log *text*. `afterSingletonsInstantiated()` is unreachable without a Spring context
  (SBDEV-2217), and log text is not a JUnit-observable contract. §3.5 already extracts `findPublicHandlers`
  so the log's **content** is unit-tested (AC-6a); what remains is a single `LOG.info` call.
* **AC-11** — 61 of 99 live users still bootstrap. No JUnit test can see a live tenant.

A two-row verify script would be a net negative here, for three measured reasons this repo has already paid
for:

1. **A grep cannot assert either of those two rows anyway.** AC-6b would degrade to "a `LOG.info` containing
   the substring `open by design` exists" — which a comment satisfies, and which goes stale the moment the
   message is reworded. AC-11 needs a live HTTP call with a tenant header and a bearer token; a verify script
   cannot hold credentials.
2. **The rows that *could* be scripted are exactly the rows JUnit already holds better** — and JUnit
   assertions run in CI, survive refactors and can be mutation-checked, which is the T2/T3 rule.
3. Verify scripts have been a measured net negative in this repo: 12 of 16 deliberately-broken
   implementations once scored a full green, and the `PROJECT_ROOT` convention is split 37/7 so a wrong
   invocation reds every row credibly.

**Instead:**
* **AC-6b → a named code-review item.** The reviewer reads the `LOG.info` call and confirms it interpolates
  `findPublicHandlers(...)`, and confirms manual row **M5**.
* **AC-11 → manual-QA gate rows M1, M2, M3** in §6.5. These are **blocking**, not advisory: the plan is not
  done until M1 and M2 pass on both UIs with a genuinely non-admin user.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Tier** | **T3** | The router routes on execution risk: this is **authorization** work, it is a new cross-cutting mechanism, and the failure mode is a total-outage regression on the login path for all 99 users. Not because it is large — it is ~150 lines |
| **Pre-draft step** | done: `analyst`+`architect` design fork, independent claim verification, exec-level site enumeration | three lanes already ran; do not repeat |
| **Plan-review step** | `critic` (T3) — one ralplan round | must specifically stress §3.2, §3.6 Rail 3's non-vacuity target, and the §9.3.2 ruling |
| **Implementation shape** | `ralph`, exit condition = the §5.3 AC set green + the §5.1 row 9 failure-set invariant | no verify script, so the exit gate is the test suite, not a script's exit code. **P0-scaffold runs before the loop starts** — without it nothing compiles and every AC fails identically (§5.2) |
| **Verification step** | the floor, always: **one DB query** (§5.1 row 1, done) · **failing test first** (P0) · **mutation-check every new assertion** (§6.1, **18 named pins** — #1–#13, #14a, #14b, #15, #16, #17) · **one independent review** · **full suite vs the known baseline**. Plus a `verifier` lane at T3 | |
| **Code-review step** | `code-reviewer`, every High/Medium fixed. **Never self-approve** | Hand the reviewer **§3.2 AND §3.4.1** explicitly and make the conflict-check keying — *at both layers* — a first-class review item; r1 caught the runtime one and missed the boot one. Two further named items with no AC behind them: **AC-6b** (the boot-log call interpolates `findPublicHandlers`) and **§6.4's DEBUG-not-INFO** log level. And treat the two `@PublicHandler(reason=…)` strings as **security text**: reject any reason asserting the circularity claim §1 corrects |
| **Commit step** | `git-master` — **P1–P4 as one commit** (boot-order constraint), P5 optionally a second | |

**A note for the implementer, from the floor's own failure history:** an idle review subagent is not a
passing review, and a subagent that returns no file has not delivered. Demand the deliverable.

### 9.3 Alternatives considered — and the ruling on the open decision

#### 9.3.1 The three mechanism options (A, B, C) — **B is locked**

| | **A — move the two reads to a new `UserBootstrapController`** | **B — `@PublicHandler` marker (LOCKED)** | **C — keep the build-time reflection test only** |
|---|---|---|---|
| Runtime fail-closed for `UserController` | **yes** — A keeps no class-level default, so `annotation == null` stays reachable | **no** — see §1.1. `GOLDEN_MAP` membership forces a class-level annotation, which makes that branch unreachable. B delivers **default-to-admin-function** (99 → 38 reachable) plus a deletion tripwire | no |
| Files touched | ≥5 (new controller, `UserController`, GUARDED, GOLDEN_MAP, the deny-list test) | 4 + the new annotation | 0 |
| Handler #12 next month | on `UserController` → **deploy fails** ✅ (A keeps no class-level default, so `annotation == null` really is reachable). **On the new `UserBootstrapController` → nothing happens at all** ❌ | ⚠️ **NOT "unannotated → deploy fails".** Under B the class-level annotation follows from this plan's `GOLDEN_MAP` choice, so handler #12 **resolves it**: boot passes, runtime allows the 38 admins, and a handler needing a *different* function ships silently wrong. What B actually gives: **default-to-admin-function instead of ship-open** (99 → 38 reachable), plus AC-8a's exactly-11 count pin as a build-time tripwire, plus — if markered — the allow-list test reds, forcing a deliberate second edit in a security file. See §1.1 and §9.3.4 | caught only if someone runs the build, on this class, with a `*Mapping`-suffixed annotation, and a non-overloaded name |
| New failure mode it creates | a class whose stated purpose is "the ungated one" — precisely where the next bootstrap-ish endpoint gets parked, by a developer reading the class comment as permission | a marker that is self-grantable with two edits (§8.1 scenario 2) | — |
| Boot ambiguity risk | **real**: 43 of 61 controllers `extend AdminController` by reflex; a second `/v3/user`-mapped class that does would register `AdminController`'s 9 mappings twice → `IllegalStateException: Ambiguous mapping`. Loud, but a trap for the next maintainer who "fixes" the missing `extends` | none | none |
| Generalises to `StockUnitController` / `UnitLoadController` | no — needs a third and fourth bootstrap controller | yes, at a cost of 10 explicit markers | no |
| Cost of the `REVIEWED_METHOD_LEVEL_OVERRIDES` ripple | no difference between A and B — both take it, and both avoid it under the §9.3.2 DELETE ruling | ← | none |

**Why B, in one sentence:** A closes the hole for `UserController` and opens a fresh one right next to it —
the only way to close *that* one is a way to mark individual handlers open, which is B — and C is not
equivalent to runtime fail-closed at all, because it reads the classpath rather than the deployed surface
and needs a human to run the build on a repo with no CI on PRs.

> **r2 honesty note.** With C-2 corrected, A is *stronger than B on the handler-#12 axis specifically* —
> because A keeps no class-level default, so `annotation == null` stays reachable and the deploy really does
> fail. B still wins overall on the four axes that decided it (no new bootstrap class to park the next
> ungated endpoint in; no `Ambiguous mapping` trap; generalises to the two large controllers; no method
> bodies relocated on the repo's most security-sensitive controller), and B's default-to-admin-function is a
> better *default* than A's fail-closed-for-everyone on a class where 100% of the real handlers want the same
> function. But the trade is real and r1 hid it by claiming B had both. **A is not reopened** — this note
> exists so the next reader is not misled about why B won.

**A is not dead — it is demoted.** Once B exists, moving the two reads to a bootstrap controller is a pure
code-organisation tidy-up with **zero security content**. Do it or don't; nothing about the posture changes.
The reverse hybrid ("A now, B later if the pattern recurs") fails on the evidence: the pattern has already
recurred three times — `UserController:40-42`, `StockUnitController:70-73`, `FunctionGuardArchTest:104-108`
all cite the absence of an open-marker as the blocker. A fourth recurrence is not a hypothesis.

**Rejected sub-variant: a reserved `@RequiresFunction` value** (`@RequiresFunction({})` or
`@RequiresFunction("PUBLIC")`). Struck on §2.4 alone: the empty array is already taken and means the
opposite, and its branch (`AccessService:134-140`) is the fail-closed path for a guarded unannotated
handler. One edit, two behaviours, one of them silently reopened.

#### 9.3.2 🔨 THE RULING — delete the nine method-level `@RequiresFunction`, keep only the type-level one

The two analysis lanes disagreed. **Ruling: DELETE all nine.**

| | **KEEP the 9** | **DELETE the 9 (ruled)** |
|---|---|---|
| `REVIEWED_METHOD_LEVEL_OVERRIDES` (`FunctionGuardArchTest:491-494`) | +9 entries, 3 → **12**; requires the `Set.of` >10-varargs workaround (the file already documents hitting this ceiling at `:516`); **dilutes the constant 4×** | **untouched at 3** |
| Semantic honesty of that constant | its javadoc (`:476-489`) defines an override as something that **re-points** an endpoint onto a *different* function. All 9 carry the **same** value as the class-level annotation — nine recorded no-op self-overrides in a constant whose entire purpose is "a reviewer has no signal that a new override is unreviewed" | preserved: an entry there continues to mean "this endpoint deliberately differs from its class default" |
| Matches the codebase's own pattern | no — `UserController` becomes the sole outlier | **yes** — `UserRoleController:39-40` and `UserGroupController:46-47`, the two sibling GUARDED write controllers, carry class-level only and **zero** method-level; rationale at `FunctionGuardArchTest:88-90` |
| Tests red at gate time | AC-4b (`:596-624`) **RED with 9 unexpected entries**, plus AC-1, AC-2, and the two wiring equalities = **5** | AC-4b stays **GREEN**; AC-1, AC-2, the two wiring equalities, and `everyWriteHandlerIsGated` = **5**, but one of them is a test being rewritten anyway |
| Per-method signal for a reader | the annotation, at the handler | the class-level annotation 400 lines up — **plus** `denyUnlessUserManagementAllowed()` (`:134-143`), which every one of the 9 still calls as its first statement. The per-method record survives *in the method body*, where it is harder to delete by accident than an annotation |
| Risk if one is deleted by accident later | caught by AC-4b's equality | **falls back to the class default — the same function. No behaviour change. Strictly safer** |
| Risk if the **class-level** annotation is deleted later | the 9 keep working; the 2 markers keep working; **only future handlers silently lose the default** | all 9 become unannotated handlers on a GUARDED class → **fail closed at runtime AND the deploy fails at boot AND AC-1/AC-2 red**. Fails loud, three ways |
| Diff | +1 type-level, 9 kept, +9 constant entries | +1 type-level, −9 annotations |

**The deciding factors, in order.** (1) It is the codebase's own established pattern for exactly this shape,
and `UserController` was only ever the outlier because it had no class-level annotation to inherit from.
(2) It keeps `REVIEWED_METHOD_LEVEL_OVERRIDES` meaningful — a same-value "override" is a no-op that costs a
constant entry and a reviewer's attention for nothing, and diluting a review-signal constant 4× is a real
cost paid by every future reader of it. (3) The failure modes are asymmetric in DELETE's favour: accidental
deletion of a method annotation is a no-op under DELETE, while accidental deletion of the class annotation
fails loud in three independent places.

**The counter-argument is real but weak here:** locality — a reader at `createUser:224` no longer sees the
gate at the handler. It is weak because all nine carry the *identical* value, so the per-method annotation
conveys no information the class-level one does not, and because `denyUnlessUserManagementAllowed()` is still
the first statement of all nine method bodies, which is a stronger local signal than an annotation.

**Consequences the implementer must not miss:**
* `UserControllerUnitTest.everyWriteHandlerIsGated` (`:967-1002`) goes **RED** — it reads
  `m.getAnnotation(RequiresFunction.class)`, which is method-level only. It is being rewritten regardless
  (§3.6 Rail 4); AC-8c makes reading the class-level annotation part of the rewrite.
* The six `assertThatThrownBy(… AccessDeniedException)` deny tests at `UserControllerUnitTest:856-965` and
  `grantedCallerIsNotBlocked` at `:1004-1016` stay **GREEN** — they exercise
  `denyUnlessUserManagementAllowed()` by direct invocation, not the annotation.
**r2 — the ruling was independently stress-tested by the Architect lane and is UPHELD.** Three traces it ran
that this plan had not, all verified against `origin/develop`, all strengthening the ruling:

| Probe | Result |
|---|---|
| Is in-body `denyUnlessUserManagementAllowed()` really equivalent to the annotation? | **For the reader, yes** — it is the first statement of all nine (call sites `:152,180,226,286,367,418,474,489,498`; body `:134-143`). **For the arch tests, the annotation was never doing the work**: AC-4b asserts *equality* against `REVIEWED_METHOD_LEVEL_OVERRIDES`, so nine same-value entries are pure dilution of a constant whose javadoc (`:476-489`) defines an override as a **re-pointing**. **For the reviewer, neither shape catches a NEW handler added without either** — so KEEP buys nothing on the axis that matters |
| Remove `UserController` from `GUARDED`, keep the class-level annotation | Behaviourally a **total no-op** — the marker block never consults `GUARDED`, and the class-level annotation still gates the nine. Caught loudly by `FunctionGuardWiringUnitTest:229-233`/`:256-258` and AC-7d. Safe |
| Remove the class-level annotation, keep `GUARDED` | The two markers still open; the nine become unannotated-on-guarded → **runtime 403 AND `IllegalStateException` at boot AND AC-1/AC-2 red.** Under KEEP the same deletion is **silent**. This asymmetry is the ruling's strongest argument and it holds |

**One cost r1 understated, raised by the Architect and accepted:** the diff shows **nine `-@RequiresFunction`
lines on the most security-sensitive controller in the repo.** A reviewer skimming sees nine gates removed.
Mitigate in two places already in scope — the commit message, and the rewritten `UserController:34-59` class
comment, both of which must state that the nine were replaced by an identical class-level default and that
`denyUnlessUserManagementAllowed()` is untouched.

* `REVIEWED_METHOD_LEVEL_OVERRIDES` must be verified **unchanged at 3 entries** (AC-4e). If a reviewer
  "helpfully" adds the nine, the constant is diluted and the ruling is silently reversed.

#### 9.3.3 Other alternatives considered and rejected

| Alternative | Rejected because |
|---|---|
| Widen the ANY-of function set on `getAllRoles` instead of marking it open | ⚠️ **The obvious argument — "circular by construction, the call's answer *is* the caller's function set" — is FALSE for the code as written**, and is already asserted twice in the tree (§1). Verified: `getAllRoles(@PathVariable String username)` (`:479-480`) takes an **arbitrary** username and reads no principal, and `isWmsUser` declares a `Principal` it never reads (`:164-172`). The circularity holds for the **intended** semantics, not the current signature (§8.3(b)). The conclusion survives on three independent grounds that do not need it: both UIs call these as **bootstrap** requests before any menu renders; **61 of 99 users hold no user-management function**; and **zero functions is a legitimate provisioned state** (`AccessService:152-157` distinguishes `USER_NOT_PROVISIONED` from `NO_FUNCTIONS`), so that user passes **no ANY-of set of any size** — widening relocates the cut point, it never reaches them |
| Reuse `AccessDecision.Reason.MISSING_FUNCTION` for a conflict denial | Makes a conflict indistinguishable from ordinary fail-closed in the log, the body `reason` and the `wms2.authz.denied{reason=…}` tag — defeating the record's stated purpose (`AccessDecision.java:5-10`). Adding a constant is verified safe: no test enumerates `Reason.values()` |
| Add a guarded-set seam (4th constructor param) so the fail-closed branch becomes runtime-testable | Production design change touching all 6 construction sites with DI-wiring risk, for a branch already covered honestly at boot. Already tracked as "item 5 of §14.19's fix list" (`FunctionGuardWiringUnitTest:250`). §3.9 |
| Extend `@PublicHandler` to `StockUnitController` / `UnitLoadController` in this ticket | 10 separate decisions; at least `bulkTransferStock` and `reprintLabel` want a real function, not a marker. Also requires deleting or inverting `FunctionGuardArchTest:427-451` and G-2's `:417-420`, both written with measured mutation evidence. §3.9 |
| Sweep all six wrong SDR paragraphs now | SBDEV-3017 owns the measurement. This plan corrects the one paragraph it is already editing and points at 3017 (§3.7b) |
| Ship 3063 after 3017 | Leaves the two reads open for the duration of the larger ticket, and queues a small isolated change behind 3017's expensive `FunctionGuardWiringUnitTest.Registration` rewrite (§8.2) |
| A `los_sysprop` toggle to enable the new behaviour | A toggle on a fail-closed authorization path is a second failure mode, and the OFF state is the current bug. §5.1 row 2 |

#### 9.3.4 The road not taken — genuine runtime fail-closed, and why this plan does not take it

The tension — and note it is **this plan's own choice**, not a codebase constraint:

> `GUARDED` means *"an absent annotation denies."*
> `GOLDEN_MAP` membership means *"this class carries a class-level annotation"* (AC-1, `:219-233`).
> **A class-level annotation makes the first unreachable** — and this plan chooses `GOLDEN_MAP` membership.

All 13 current `GUARDED` members happen to be in `GOLDEN_MAP` too, so all 13 are in that state;
`UserController` would be the 14th. Nothing enforces the coupling — see §1.1 step 1.

**The shape that WOULD deliver runtime fail-closed:**

> `GUARDED` + `@PublicHandler` on the two reads + **KEEP** the nine method-level annotations + **NO
> class-level annotation.**

Then handler #12 resolves nothing, reaches `FunctionGuardInterceptor:125`, and gets a genuine runtime 403
**and** an `IllegalStateException` at boot — exactly the property §1 was originally written around.

**Why this plan does not take it — and this is a considered rejection, not an oversight:**

> ⚠️ **The cheap objection does not exist.** It looks as though this shape "cannot enter `GOLDEN_MAP`" and
> would need a new *guarded, no class default* category in AC-1 — a change to the arch test governing 13
> other controllers. **It would not.** The fail-closed shape simply **omits `UserController` from `GOLDEN_MAP`**;
> AC-1, AC-2, AC-3 and AC-4b all iterate `GOLDEN_MAP.keySet()` and would never look at it, and nothing
> compares `GOLDEN_MAP` to `GUARDED`. It is a one-line difference, not an arch-test rework. **The four costs
> below are what actually rule this out** — and they are sufficient.

| Cost | Detail |
|---|---|
| ~~`UserController` cannot enter `GOLDEN_MAP`~~ | **STRUCK** — see the box above. Omitting it is one line; this was never a cost |
| `REVIEWED_METHOD_LEVEL_OVERRIDES` takes the 3 → 12 dilution | The exact cost §9.3.2 rules against, plus the `Set.of` >10-varargs workaround |
| Loses the deletion tripwire | §1.1 property 2 does not exist in this shape — there is no class-level annotation whose deletion could be the tripwire. Note the honest direction: in the defaultless shape, deleting one of the nine is **louder** than under DELETE (unannotated-on-guarded → runtime 403 **and** boot failure) — so the cost is losing the tripwire's *subject*, not losing loudness |
| Fail-closed-for-everyone is the wrong **default** for this class | 9 of 11 real handlers want the identical function. A forgotten annotation 403ing all 99 users is a louder failure than 38-user exposure, but it is also a *more likely* outage, and the thing being defended is a handler that does not exist yet |
| Diverges from every sibling | `UserRoleController:39-40` and `UserGroupController:46-47` are class-level-only; this shape makes `UserController` unique twice over |

**The honest summary, which r1 owed the reader and did not give:** *this plan trades the runtime fail-closed
property for arch-test compatibility and a better default.* The §9.3.2 DELETE ruling is **correct given** the
class-level annotation — and the class-level annotation is itself the choice that costs the property. That
ordering matters: if a future reviewer wants genuine fail-closed on this class, the thing to revisit is
**`GOLDEN_MAP` membership** — omit `UserController` from it, drop the class-level annotation, keep the nine —
**not AC-1's categories** (r2's answer, which sends you to edit a test that is not in the way) and **not the
DELETE ruling**.

**Not recommended for this ticket.** Recorded so the decision is visible rather than inherited.
