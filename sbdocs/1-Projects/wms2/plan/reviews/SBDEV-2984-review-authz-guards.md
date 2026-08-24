---
title: "SBDEV-2984 — independent review: ungated user write endpoints"
type: review
status: complete
version: v2
ticket: SBDEV-2984
branch: bugfix/SBDEV-2984-ungated-user-write-endpoints
base: origin/develop @ 808819d
reviewer: independent authz lane (did not author the fix)
created: 2026-08-21
---

# SBDEV-2984 — Review: authorization guards on `UserController` write endpoints

## Verdict

**ship-with-changes.**

The core of the fix is correct and its completeness claim holds where it matters most: **five *is* the
true total of ungated MVC write handlers declared on `UserController`**, verified by reflection over
`getMethods()` rather than by grepping the source file, and the widening from three to five was the
right call. Every guard sits as the first statement of its method and outside every `try`. Six of eight
production mutants were killed, the pre-existing happy paths are genuinely exercised rather than
vacuously green, and the full suite matches the known baseline exactly.

What must change before merge is **not the guards** — it is one **factually false claim** the author
added to `AdminController` on this branch, plus two test assertions that mutation testing proved
absent. The Spring Data REST surface exported at the *same* `/v3/user` prefix still offers an ungated
route to the WMS-row half of four of the five gated endpoints, so the sentence "Every write endpoint
under `/v3/user` is now gated; the remaining ungated methods there are reads" is wrong and repeats
exactly the over-claiming that SBDEV-2870's own docs were written to prevent.

Counts: **1 High · 3 Medium · 3 Low.**

---

## Scope reviewed

Working tree of `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2984`, branch
`bugfix/SBDEV-2984-ungated-user-write-endpoints`.

⚠️ **The brief said two files. There are three.** A third file appeared in the worktree during this
review:

| File | Change |
|---|---|
| `src/main/java/net/aim_ai/wms/controller/UserController.java` | +17 — five `denyUnlessUserManagementAllowed()` calls + a javadoc block |
| `src/test/java/net/aim_ai/wms/unit/controller/UserControllerUnitTest.java` | +130 — `UngatedWriteEndpoints` @Nested, 6 tests |
| `src/main/java/net/aim_ai/wms/controller/AdminController.java` | +5/-3 — rewrites the ⚠ comment above `importUserWithCsv` |

The `AdminController` hunk is the subject of **F1**. It is uncommitted and was not in the brief, so it
has had no review other than this one.

---

## The complete `/v3/user/**` endpoint table

Built by **reflection over `getMethods()`** on the five beans that register under `/v3/user`
(`UserController`, `AdminController`, `UserAdministrationController`, plus `UserGroupController` /
`UserRoleController` for the self-grant question), not from the source file. 59 handler registrations
enumerated; 27 land under `/v3/user`. Throwaway probe deleted.

### A. Declared on `UserController` (prefix `/v3/user`) — 11 handlers

| # | Endpoint | R/W | Gated? | By what | `file:line` |
|---|---|---|---|---|---|
| 1 | `POST /getKeycloakUser` | **read** | ❌ **NO** | — | `UserController.java:107` |
| 2 | `GET /isWmsUser/{username}` | read | ❌ NO (correct — see F4) | — | `:120` |
| 3 | `POST /importUser` | **WRITE** | ✅ yes | `denyUnless…` (2984) | `:132`, guard `:135` |
| 4 | `POST /create` | **WRITE** | ✅ yes | `denyUnless…` (2984) | `:177`, guard `:180` |
| 5 | `POST /update` | **WRITE** | ✅ yes | `denyUnless…` (2984) | `:236`, guard `:239` |
| 6 | `GET /delete/{userId}` | **WRITE** | ✅ yes | `denyUnless…` (2984) | `:294`, guard `:297` |
| 7 | `POST /saveUserGroups` | **WRITE** | ✅ yes | `denyUnless…` (2870) | `:324`, guard `:326` |
| 8 | `GET /userDetailsById/{id}` | **read** | ❌ **NO** | — | `:351` |
| 9 | `GET /getAllRoles/{username}` | read | ❌ NO (correct — see F4) | — | `:357` |
| 10 | `GET /getDetails` | **read** | ❌ **NO** | — | `:363` |
| 11 | `POST /bulkEditUsers` | **WRITE** | ✅ yes | `denyUnless…` (2984) | `:369`, guard `:372` |

**6 writes, all 6 gated. 5 reads, 3 of which should be gated (F4) and 2 of which must not be.**
No ungated write remains among `UserController`'s own declared handlers. **Five is the true total.**

### B. Inherited from `AdminController`, re-registered under the `/v3/user` prefix — 9 handlers

The documented landmine (base class for 43 controllers) **was checked and is clean.**

| Endpoint | R/W | Gated? |
|---|---|---|
| `POST /v3/user/user/createUser` | write | ✅ `@PreAuthorize(IS_SB_ADMIN)` |
| `POST /v3/user/user/updateUser` | write | ✅ `IS_SB_ADMIN` |
| `POST /v3/user/user/deleteUserByUsername` | write | ✅ `IS_SB_ADMIN` |
| `POST /v3/user/user/resetPassword` | write | ✅ `IS_SB_ADMIN` |
| `GET /v3/user/user/findUsers` | read | ✅ `IS_SB_ADMIN` |
| `GET /v3/user/user/findUserByUsername` | read | ✅ `IS_SB_ADMIN` |
| `GET /v3/user/user/findUserGroupsByUsername` | read | ✅ `IS_SB_ADMIN` |
| `GET /v3/user/admin/importUsersFromCsvText` | write | ✅ `IS_SB_ADMIN` |
| `POST /v3/user/groups/findGroup` | read | ✅ `IS_SB_ADMIN` |

### C. `AdminController` under its own `/v3` prefix, landing in `/v3/user/*` — 7 handlers

`/v3/user/{findUsers, findUserByUsername, deleteUserByUsername, findUserGroupsByUsername, createUser,
updateUser, resetPassword}` — all `@PreAuthorize(Authority.IS_SB_ADMIN)`
(`AdminController.java:79,107,120,133,142,154,175`). No gap.

### D. `UserAdministrationController` under `/v3` — 4 handlers, all gated by SBDEV-2870

`POST /v3/user/addUserToWarehouseGroup` (`:129`) · `POST /v3/user/removeUserFromWarehouseGroup`
(`:151`) · `GET /v3/user/isWarehouseUser` (`:180`) · `GET /v3/user/existsInKeycloak` (`:224`).
All four call `denyUnlessUserManagementAllowed()` as their first statement, outside the try. Note
that **two of these four are reads** and were gated anyway — the precedent F4 turns on.

### E. Spring Data REST, exported at the same `/v3/user` prefix — **UNGATED**

`UserRepository.java:13` `@RepositoryRestResource(collectionResourceRel = "user", path = "user")` +
`RestConfiguration.java:32` `config.setBasePath("/v3")` + `:47`
`RepositoryDetectionStrategies.ANNOTATED`. No `@RestResource(exported = false)` anywhere on
`UserRepository` — an idiom this repo uses freely elsewhere (`LocationRepository.java:53`,
`StockViewRepository.java:30`, 8 more).

| Endpoint | R/W | Gated? |
|---|---|---|
| `GET /v3/user` (collection) | read | ❌ **NO** |
| `POST /v3/user` | **WRITE** | ❌ **NO** |
| `GET /v3/user/{id}` | read | ❌ **NO** |
| `PUT /v3/user/{id}` | **WRITE** | ❌ **NO** |
| `PATCH /v3/user/{id}` | **WRITE** | ❌ **NO** |
| `DELETE /v3/user/{id}` | **WRITE** | ❌ **NO** |
| `GET /v3/user/search/getAllRoles?username=` | read | ❌ **NO** |
| `GET /v3/user/search/getDetails` | read | ❌ **NO** |
| `GET /v3/user/search/{findByName, findByPrinterId, findClientIdByName}` | read | ❌ **NO** |

Only `wms_user` is required (`SecurityConfiguration.java:151`, `.requestMatchers("/v3/**", …)
.hasAnyAuthority(Authority.WMS_USER_ROLE)`). `FunctionGuardInterceptor` provably cannot reach these —
`RepositoryRestHandlerMapping` does not consult `WebMvcConfigurer#addInterceptors`
(`FunctionGuardInterceptor.java:64-66`, `RequiresFunction.java:36-40`).

---

## Findings

| # | Sev | `file:line` | What breaks | Fix |
|---|---|---|---|---|
| F1 | **High** | `AdminController.java:211-215` (new on this branch) | The new comment asserts "**Every write endpoint under `/v3/user` is now gated; the remaining ungated methods there are reads.**" That is **false**. Section E above lists four ungated SDR writes at exactly that prefix, and each reproduces the WMS-row half of a gate this PR adds (details below). Shipping this sentence retires a known-open hole in the reader's mind — the precise error `wms2-keycloak-role-matrix.md` warns against: *"this ticket must NOT be closed with wording implying Keycloak identity creation is locked down."* | Do **not** change code. Reword to scope the claim to *MVC handlers declared on `UserController`* and name the SDR residual, cross-referencing SBDEV-3013 door ① and SBDEV-3017. |
| F2 | Medium | `UserController.java:95` vs `UserGroupController.java:42`, `UserRoleController.java:41`, `FunctionGuardInterceptor.java:92-96` | Five hand-rolled imperative calls where the **newest convention on this exact surface is declarative**. SBDEV-3013 (already on `develop`) gated the two sibling user-admin controllers with class-level `@RequiresFunction` **and** added both to `FunctionGuardInterceptor.GUARDED`, stating: *"Membership here is what makes a future unannotated handler on these two fail CLOSED; the class-level `@RequiresFunction` alone would let it through."* `UserController` is in neither, so `FunctionGuardStartupAssertion` cannot see it and `FunctionGuardArchTest`'s golden map does not cover it — **a sixth write handler added next month is ungated again with nothing failing.** That is the exact failure mode that created *this* ticket (SBDEV-2870 left three behind). Secondary: a raw `AccessDeniedException` yields a bare 403 with no body, whereas the interceptor returns `application/problem+json` with `reason` + `requiredFunction` + `Authority.AUTHZ_DENIED_HEADER` (`FunctionGuardInterceptor.java:177-193`) — the shape the clients parse. Two denial contracts on one screen. | Convert the six writes to method-level `@RequiresFunction`, add `UserController` to `GUARDED` and to `GOLDEN_MAP`, and reconcile `FunctionGuardArchTest` AC-2/AC-4b. **If that is judged too large for this PR** (it is not a drop-in: 5 of the 11 handlers must stay ungated, so a class-level annotation would 403 login) then say so in one line in the javadoc and state how the fail-closed property will be obtained. Silence here is the problem, not the choice. |
| F3 | Medium | `UserControllerUnitTest.java:582-600` (`createUserIsGated`), `:563-578` (`importUserIsGated`) | **Two mutants SURVIVED.** Moving the guard in `createUser` to *after* `keycloakService.findUserByUsernameOrEmail` (`UserController.java:194`) → **24/24 green**. Moving the guard in `importUser` to *after* `userRepository.findByName` (`:146`) → **24/24 green**. Both tests `verify(never())` only the terminal writes; nothing pins precedence over the first *read*. The test file's own comment — *"A guard placed after the first repository call would satisfy the first and fail the second"* — is **measured false for these two**. If a later refactor slides either guard, an unauthorized caller gets a Keycloak account-existence oracle out of `/user/create` — the exact vector `existsInKeycloak` was gated for. Contrast `deleteIsGated`, where `verify(userGroupUserRepository, never()).findByUserlistId(anyLong())` **is** load-bearing (M9 below). | Add `verify(keycloakService, never()).findUserByUsernameOrEmail(any(), any());` to `createUserIsGated` and `verify(userRepository, never()).findByName(anyString());` to `importUserIsGated`. Re-run M7/M8 and confirm both go red. |
| F4 | Medium | `UserController.java:107`, `:351`, `:363` | **Three User-Management-screen-only reads remain ungated, contradicting the precedent this fix cites.** SBDEV-2870 gated `GET /v3/user/existsInKeycloak` explicitly because *"ungated this was a user-enumeration vector open to any `wms_user`"* (`UserAdministrationController.java:220-224`). The author left `POST /getKeycloakUser` open on "it is a read" grounds — but it is **strictly stronger** than the read that *was* gated: `KeycloakService.findUserByUsernameAndEmail` (`:250-277`) returns `username`, `firstName`, `lastName`, `email` for any realm account, SiteBoss staff included — PII, not a boolean. `GET /getDetails` dumps the entire user directory (`UserRepository.java:36-40`) and `GET /userDetailsById/{id}` one row. **Gating all three breaks nothing**: untruncated grep across both UIs gives each exactly one caller, all on the gated screen — `store/admin/user.js:152`, `:33`, `:122`. | Add `denyUnlessUserManagementAllowed()` to `checkKeycloakUser`, `getUserDetails` and `userDetailsById`. Necessary-not-sufficient while F1's SDR search resources leak the same data. |
| F5 | Low | `UserController.java:99` | `LOG.warn("Denied **saveUserGroups** for {}: missing function {}", …)` is now reached from six endpoints. An operator investigating a 403 on `/user/create` gets a log line naming `saveUserGroups`. `UserAdministrationController.java:120` gets this right ("Denied user-administration call for {}"). | `LOG.warn("Denied user-management call for {}: …")`, or pass the endpoint name. |
| F6 | Low | `UserController.java:58-94` | **Two consecutive javadoc blocks on one method.** Java attaches only the last (`:88-94`), so the SBDEV-2870 block (`:58-87`) becomes a dangling comment and its rationale drops out of the generated docs. Worse: the orphaned block's closing paragraph at **`:83-86` still reads** *"⚠ `/user/create`, `/user/importUser` and `/user/delete/{userId}` on this same class remain **UNGATED** and can still manufacture Keycloak identities with warehouse-group membership"* — now false, sitting six lines above the guard that closes it. The author corrected the equivalent drift in `AdminController` and missed it here. | Merge into one javadoc block; delete or rewrite the ⚠ paragraph. |
| F7 | Low | `UserControllerUnitTest.java:572`, `:591`, `:610`, `:623`, `:640` | `hasMessageContaining(WEB_UI_VIEW_USER_MANAGEMENT)` — the constant's value is the literal `"WEB_UI_VIEW_USER_MANAGEMENT"` (`WmsConstants.java:365`) and `"WEB_UI_VIEW_USER"` (`:356`) is a **substring** of it, so this assertion is directional and weaker than it reads. M4 (guard narrowed to `WEB_UI_VIEW_USER`) *was* killed — but by the 10 pre-existing happy-path tests erroring, not by these assertions. Don't credit them for it. | Optional: `isEqualTo("Missing function " + …)` or `hasMessageEndingWith`. |

### F1 in detail — the concrete SDR bypasses

| Gated by this PR | Ungated SDR equivalent | Reproduces |
|---|---|---|
| `POST /user/bulkEditUsers` (`setPrinterId`) | `PATCH /v3/user/{id}` `{"printerId": N}` | **the entire effect**, one row at a time |
| `POST /user/update` | `PATCH /v3/user/{id}` `{"firstname","lastname","email","printerId"}` | the WMS-row half |
| `POST /user/create`, `POST /user/importUser` | `POST /v3/user` | the WMS-row half (`userService.create`) |
| `GET /user/delete/{userId}` | `DELETE /v3/user/{id}` | **partially** — succeeds for a user with no dependent rows; 11 FKs reference `mywms_user` (`mywms_group_mywms_user`, `mywms_user_mywms_role`, `billoflading`, `pickingorder`, …, verified live on Hydra UAT) and block the rest |

**What the fix genuinely does close, and this is substantial:** the **Keycloak** half —
`createSingleUser`, `addUserToWmsGroup`, `updateSingleUser`, `updateUserPassword`. SDR cannot reach
Keycloak at all. Manufacturing a *loginable* identity with warehouse-group membership is now gated,
and that was the sharpest edge of the ticket.

Evidence that SDR write verbs are live in this deployment rather than theoretically exported:
`wms2-web-ui/store/admin/role.js:85` `$put('/userRole/' + id)` and `store/admin/group.js:65`
`$put('/userGroup/' + id)` are SDR item PUTs — neither controller declares a `PUT` mapping.
`store/admin/management.js:124` `$get('/user' + urlPart)` confirms the `/v3` base path on
`UserRepository` specifically.

**Not empirically curl-confirmed.** No bootable environment here (the `@SpringBootTest` lane is down,
SBDEV-2217), so section E is a code-level deduction from four independently verified facts, not an
observation. **One curl against DEV would settle it** and is worth doing before rewording F1.

---

## Mutation results

`export JAVA_HOME=$HOME/.sdkman/candidates/java/21.0.11-ms`, `mvn -o test -Dtest=UserControllerUnitTest`
(24 tests). Every mutant reverted; `src/test/resources/archunit_store` reverted after the full run.

| # | Mutant | Result | Killed by |
|---|---|---|---|
| M1 | Remove the guard from `bulkEditUsers` entirely | ✅ **KILLED** (1 failure) | `bulkEditUsersIsGated:643` |
| M2 | Move the `delet` guard to **after** `userGroupUserRepository.findByUserlistId` | ✅ **KILLED** (1 failure) | `deleteIsGated:631` |
| M3 | Move the `bulkEditUsers` guard **inside** its `try` (the only one with `catch (Exception e)`) | ✅ **KILLED** (1 failure) | `bulkEditUsersIsGated:643` |
| M4 | Guard checks `WEB_UI_VIEW_USER` instead of `WEB_UI_VIEW_USER_MANAGEMENT` | ✅ **KILLED** (6 failures + 10 errors) | 5 deny tests, `SaveUserGroups`, and every happy path |
| M5 | `denyUnlessUserManagementAllowed()` made a no-op | ✅ **KILLED** (7 failures) | all 5 new deny tests + both `SaveUserGroups` deny tests |
| M6 | Guard always throws (regression detector) | ✅ **KILLED** (1 failure + 10 errors) | `grantedCallerIsNotBlocked:660` + all 10 pre-existing happy paths |
| **M7** | Move the `createUser` guard to **after** `keycloakService.findUserByUsernameOrEmail` | ❌ **SURVIVED — 24/24 green** | nothing → **F3** |
| **M8** | Move the `importUser` guard to **after** `userRepository.findByName` | ❌ **SURVIVED — 24/24 green** | nothing → **F3** |
| M9 | *(test-side)* Delete `verify(userGroupUserRepository, never()).findByUserlistId(anyLong())` **and** re-apply M2 | ⚠️ **24/24 green** — that one line is the *sole* pin on guard precedence in `delet`. Load-bearing, correctly present, and the pattern F3 says is missing from the other two. |

**M6 is the answer to the regression question.** The 10 pre-existing happy-path tests are *not*
passing merely because `setUp()` grants the function leniently — when the guard is made to deny
unconditionally, all 10 error. They genuinely traverse the allow path.

---

## Regression: PASS

- **Full suite: 5341 run, 2 failures, 0 errors, 67 skipped.** Exactly the stated baseline, and exactly
  the two known-pre-existing tests, confirmed by name from `target/surefire-reports/`:
  `net.aim_ai.wms.unit.config.OptionalSafetyArchTest` and
  `net.aim_ai.wms.unit.service.mobile.MobilePalletizingServiceTest`. No new failure.
- `UserControllerUnitTest`: **24/24**.
- **Live grant check (Hydra UAT), using the exact `UserRepository.getAllRoles` join** (`:26-34`) rather
  than a hand-rolled approximation: **15 of 19** `mywms_user` rows resolve
  `WEB_UI_VIEW_USER_MANAGEMENT`. The 4 that do not are `anonymous` (id 1 — the sentinel the guard
  rejects by name before it ever queries), `omallozzi2`, `pesposito`, `oms_integration`. So a
  legitimate user-management caller on that tenant keeps all five endpoints.
- **No integration caller breaks.** OMS's user-sync config is commented out and pointed at
  non-existent paths anyway: `v2/oms-laravel-api/config/wms.php:103-113` — `// 'user_create' => …
  'rest/user/create'`, `// 'user_import' => … 'rest/user/importUser'`, above the note *"WMS /v3/user/*
  endpoints exist but require Keycloak JWT auth."* **Forward risk worth a line in the plan:** if OMS
  ever enables it, `oms_integration` holds zero functions on UAT and will get a 403.
- No caller of the five endpoints exists anywhere in `wms2-api/src/main`, `wms2-mobile-ui`, or `v1/oms`.

---

## Axis check — is `WEB_UI_VIEW_USER_MANAGEMENT` right for all five?

**Yes, for all five.** `@PreAuthorize(Authority.IS_SB_ADMIN)` was considered and is wrong here:

1. All five are driven by the customer-facing Admin → User Management screen —
   `wms2-web-ui/store/admin/user.js:74` (`/update`), `:92` (`/create`), `:110` (`/delete/{id}`),
   `:131` (`/bulkEditUsers`), `:163` (`/importUser`). `sb_admin` would 403 every customer
   administrator who uses the screen today.
2. `wms2-keycloak-role-matrix.md` §1.1 records the 2026-08-16 target-state decision (Nam Park +
   Brent): *no function should be `sb_admin`-only*, `sb_admin` is *"identity only, never enforced."*
3. SBDEV-2870 chose this same axis for the four neighbours in `UserAdministrationController`, on the
   explicit argument that gating on a Keycloak group puts the API gate on a second, independent axis
   from the one that grants the screen.
4. The one `sb_admin` carve-out — `importUsersFromCsvText` — is a bulk migration utility with **no UI
   caller**, retained for SiteBoss staff onboarding. Materially different from the screen's "Add
   User" button, so the asymmetry with `/user/create` is defensible rather than an inconsistency.

The `sb_admin`-arrives-via-the-groups-claim landmine is **not in play**: nothing in this diff reads
`resource_access`, and the correct axis here is the function model, not `sb_admin` at all.

---

## Self-grant reachability — NOT closed by this fix, but the residual is already owned

| Step in the escalation chain | Endpoint | State |
|---|---|---|
| Grant yourself group membership (`mywms_group_mywms_user` — the table `getAllRoles` reads) | `POST /v3/user/saveUserGroups` | ✅ gated, SBDEV-2870 (`UserController.java:326`) — **verified**, 3 `SaveUserGroups` tests green |
| Attach a role to your group (`mywms_group_mywms_role`) | `POST /v3/userGroup/saveGroupRoles` | ✅ gated, SBDEV-3013 — **verified by reflection**, class-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` at `UserGroupController.java:41` resolves on all 4 declared handlers |
| Grant a role a function (`mywms_role_mywms_function`) | `POST /v3/userRole/saveRoleFunctions` | ✅ gated, SBDEV-3013 — same, `UserRoleController.java:40` |
| Create the role / group to hang it on | `POST /v3/userRole/create`, `POST /v3/userGroup/create` | ✅ gated, SBDEV-3013 |
| **…or do any of the above over Spring Data REST** | `POST /v3/userRoleUserFunction`, `POST /v3/userGroupUserRole`, `POST /v3/userGroupUser`, `PATCH`/`POST /v3/userRole/{id}/functions` | ❌ **OPEN** — structurally unreachable by `FunctionGuardInterceptor` |

So a plain `wms_user` can **still** grant themselves `WEB_UI_VIEW_USER_MANAGEMENT`, and therefore
still walk back through every endpoint this PR gates.

**This is not a defect in this diff and no new ticket should be filed.** SBDEV-3013's plan already
owns it as "door ①", names it *explicitly not closed by PR #179* (§0.2, and risk row 3-R2: *"Door ①
left open while door ② ships, and the ticket is marked done — High"*), and SBDEV-3017 owns the general
SDR case. The only action for SBDEV-2984 is **F1**: do not close it with wording that implies the
escalation is shut.

---

## Checked and RULED OUT

- **Completeness of the MVC write surface** — five *is* the total. Reflection over `getMethods()`,
  59 registrations enumerated across five beans; 11 handlers declared on `UserController`, of which
  6 write and all 6 are gated. Not derived from grepping the source file.
- **The `AdminController` base-class landmine** — checked, **clean**. All 9 handlers that re-register
  under `/v3/user` (`/v3/user/user/*`, `/v3/user/admin/importUsersFromCsvText`,
  `/v3/user/groups/findGroup`) carry `@PreAuthorize(IS_SB_ADMIN)`. Confirmed on the `getMethods()`
  probe, per-registration, not by reading `AdminController.java`.
- **Guard outside every `try`** — verified by reading all five. `bulkEditUsers` (`:400`) is the **only**
  method with `catch (Exception e)`; M3 proves a denial moved inside it is caught. The other four catch
  only `ApiMissingUserException` / `SsoCreateUserException` / `ApiInvalidParameterException` /
  `ApiConstraintViolationException` / `DataAccessException` — none a supertype of
  `AccessDeniedException` — so a misplaced guard there could not be swallowed anyway.
- **Guard precedes the first write in all five** — M1, M2, M3, M5 all killed. (Precedence over the
  first *read* is F3.)
- **`AccessDeniedException` → HTTP 403 reachability** — verified independently rather than inherited
  from the existing javadoc. The only `@ExceptionHandler(Exception.class)` in the codebase is
  `RestEndpointExceptionHandler.java:84`, scoped `@ControllerAdvice(basePackages =
  "net.aim_ai.wms.controller.rest")` (`:37`) — which does not cover `net.aim_ai.wms.controller`.
  `RestExceptionHandler` (`:23`, unscoped) declares 14 handlers, none for `AccessDeniedException` and
  none for `Exception`. So it propagates to `ExceptionTranslationFilter` → 403.
- **The `anonymous` sentinel** — the guard rejects `SecurityContextUtils.ANONYMOUS` before consulting
  `accessService`. Hydra UAT does carry a `mywms_user` row named `anonymous` (id 1), and it appears in
  the *no-function* set, so the gate would fail closed even without the sentinel. Defence in depth, as
  documented.
- **Whether the happy paths are vacuous** — no. M6 errors all 10.
- **Whether the `@Nested` tests could pass for the wrong reason** — the deny tests re-stub
  `accessService` to `false` over `setUp()`'s lenient grant, and all five were killed by M5 (no-op
  guard), which is only possible if they are asserting on the guard. `grantedCallerIsNotBlocked` is
  killed by M6, so it is not vacuous either.
- **The `-Dtest='Outer#method'` @Nested landmine** — avoided. Every run used
  `-Dtest=UserControllerUnitTest`, which reports all 24 including the nested classes.
- **`archunit_store` mutation from `mvn test`** — occurred as expected on the full run
  (`src/test/resources/archunit_store/5fb3fee0-…`) and was reverted with `git checkout --`.
- **v1** — not examined and not touched, per the v2-only policy.

**Working tree left as found:** `git status --porcelain` shows exactly the author's three modified
files and nothing else. No commit, no amend, no push.

---

## Recommended action before merge

1. **F1** — reword `AdminController.java:211-215`. Blocking; it is a false security claim.
2. **F3** — add the two `verify(never())` assertions; re-run M7/M8 and confirm red.
3. **F6** — merge the two javadoc blocks and delete the stale ⚠ paragraph at `UserController.java:83-86`.
4. **F4** — gate `checkKeycloakUser`, `getUserDetails`, `userDetailsById`. One line each, no caller
   impact, and it is the same decision SBDEV-2870 already made for `existsInKeycloak`.
5. **F2** — either convert to `@RequiresFunction` + `GUARDED`, or state in one line why not.
6. **F5** — fix the log message.
7. Record in the plan, do **not** file: `getAllRoles/{username}` accepts an arbitrary username, so any
   `wms_user` can read anyone's function list; the correct shape ignores the path variable and reads
   `SecurityContextUtils.getUserName()`. Also record the `oms_integration` forward risk.
