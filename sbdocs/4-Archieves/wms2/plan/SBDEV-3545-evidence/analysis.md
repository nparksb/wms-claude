---
ticket: SBDEV-3545
phase: analysis (T3 bug-fix plan)
date: 2026-09-27
bases: wms2-api origin/develop a715a27b · wms2-web-ui origin/develop b32a134 · wms2-mobile-ui origin/develop 5e99732 · siteboss-frontend origin/main 4ca0c544 · oms-laravel-api origin/main
method: all code read via `git show/grep origin/<branch>:` after `git fetch`, never local checkouts
author: executor (opus) analysis lane; transcribed by the main session (subagent Write was harness-blocked)
---

# SBDEV-3545 — role rename over SDR item PUT: analysis bundle

## 0. Affected sites (enumeration)

Method: `git grep` on fetched refs (sees `.gitignore`d paths such as web-ui `reports/`). Every zero below carries a positive control.

| # | Site (file · quoted snippet) | Same root cause? | In scope? |
|---|---|---|---|
| A1 | `wms2-api RestConfiguration#configureAccessChainMembershipWriteExposure`: `.forDomainType(UserRole.class).withItemExposure((metadata, httpMethods) -> httpMethods.disable(HttpMethod.PATCH, HttpMethod.DELETE));` | **Yes — the defect.** Item PUT stays exported | Yes: add `PUT` (use `WRITE_VERBS` like the `User` block above it) |
| A2 | `RestConfiguration` javadoc: *"`PUT` is safe and is deliberately kept… `store/admin/role.js:85 $put('/userRole' + urlPart)`… So `UserGroup` and `UserRole` lose only `PATCH`/`DELETE`"*; also `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` javadoc (*"`UserGroup` item PUT and `UserRole` item PUT (both `store/admin/{group,role}.js`…)"*) and `configurePutForCreationWriteExposure` javadoc (*"the item-PUT callers this file keeps open for all four types"*) | Stale once A1 lands | Yes — sibling copies of one claim; fix all three |
| A3 | `UserRoleRepository` class javadoc: *"Leaving the item `PUT`/`PATCH` exported is safe: … a `PUT /v3/userRole/{id}` that omits `functions` does NOT null the grants."* | Stale — the exact premise this ticket disproves (safe for associations, not scalars) | Yes — rewrite |
| A4 | `UserRoleController` class javadoc: *"all four handlers are reached only from the Admin → User Management screen"* | Count becomes five | Yes |
| A5 | `wms2-web-ui store/admin/role.js#updateRole`: `const result = await this.$axios.$put('/userRole' + urlPart, data)` (urlPart=`'/' + data.id`); caller `components/admin/userManagement/roles/editRole.vue`: `await this.$store.dispatch('admin/role/updateRole', this.item)` | **The one legitimate caller** | Yes — move to new endpoint |
| A6 | `editRole.vue` template: `v-model="item.name"`, `v-model="item.description"`; connector switch commented out | UI already edits only name+description | No change; decision 2 matches |
| A7 | `editRole.vue#validated`: `if (this.editMode === 'Create' && this.item.name) { … checkName …` | No client-side dup-name check on **Edit** — server is the only guard | Server-side (AC-5); UI parity optional |
| A8 | wms2-mobile-ui: `git grep -c "/userRole" origin/develop` → **0** | n/a | No. Control: `userGroup` hits `store/index.js`, `store/home.js`. Blind spot: fragment-concatenated URLs |
| A9 | siteboss-frontend / oms-laravel-api (origin/main): `/userRole` → **0** both; their `userRole` identifiers are their own permission systems | n/a | No. Control: OMS `WmsApiService.php` hits `PATCH /v3/client/{id}` |
| A10 | wms2-web-ui Cypress `admin.cy.js` mentions `PUT … /userRole` in prose only | n/a | Prose refresh optional |
| A11 | `UserGroup` item PUT (still `disable(PATCH, DELETE)` only) — **same shape** | Same mechanism, but **nothing grants by `mywms_group.name` today** (migrations use group names only in `audit-access-invariants.sql`; `UserService#isSuperAdmin` `findByName("super-admin")` has **zero callers**; Keycloak groups are fixed paths `"/wms_user"`, `"/warehouse/"`) | **Out of scope** (ticket keeps it). Latent: any future group-name-keyed seed reopens it |
| A12 | `connector`, `number`, `additionalcontent`, `entityLock` also PUT-writable; `connector=true` hides the role from `findByConnectorFalse` (admin grid) | Yes, same route | Covered by A1 |
| A13 | Name-keyed consumers (harm path): `V2.2.19`/`V2.2.21` (*"KEYED BY ROLE NAME … MISSING ROLES ARE SKIPPED SILENTLY"*); `V2.2.34` on `origin/feature/SBDEV-3381-waive` `AND r.name IN ('outbound-manager','super-admin')`; `audit-access-invariants.sql:287`; `AccessService#findConnectionUserToRole` (`curRole.getName().equals(role.getName())`) | Harm path, not defect | Context |

### Tests pinning today's exposure — must be inverted (`git grep -i userRole src/test`, 35 files checked)

| Test | Pins | Change |
|---|---|---|
| `unit/config/AccessChainSdrWriteExposureUnitTest#groupAndRoleItemsLosePatchAndDeleteButKeepPut` | loops `{UserGroup, UserRole}` asserting `item.contains(PUT)` | Split: UserGroup keeps PUT; UserRole no write verbs |
| same `#adminAggregateWritesAreUntouched` | `aggregate(UserRole.class, ITEM).contains(PUT)` | Invert for UserRole; keep UserGroup half as control |
| `security/SdrWriteWithdrawalContextTest` | `"UserRole"` ∈ `MUST_STAY_WRITABLE` (`hasSize(9)`); `WITHDRAWN` `hasSize(50)` | Move to `WITHDRAWN` → 8 / 51 |
| `security/MustStayWritableCollectionPostWithdrawalContextTest` | `ITEM_VERBS_AUDITED_ELSEWHERE = Set.of("UserGroup","UserRole")` | Drop UserRole |
| `security/PutForCreationWithdrawalContextTest#itemPutToExistingIdRemainsExposed` | `.contains(PUT)` for UserGroup, UserRole, Boxtype, Sysprop | Exclude UserRole; keep `disablePutForCreation()` (harmless belt) |
| `unit/security/UserAdminFunctionGateUnitTest` | `USER_ROLE_HANDLERS = Set.of("createRole/2","deletRole/2","saveRoleFunctions/2","userRoleDetailsById/2")` + `@CsvSource` | Add new handler to both (the handler-set pin is the intended trip-wire) |
| web-ui `test/store/adminRoleErrorHandling.spec.js` | two `updateRole` cases mock `put:` | Switch to `post:` |

Not affected: `SdrWriteExposureUnitTest`; `SdrFunctionRules` UserRole rule stays; `SdrReadGateEnforcementContextTest` (GETs); no repository event handler touches UserRole.

## 1. How existing endpoints are built

- **createRole**: in-controller, no service, **no tx**, **no duplicate-name check**; `number` from `basicService.generateNumber(EntityPrefixes.ROLE, "USER_ROLE")`.
- **deleteRole / replaceRoleFunctions**: service with `@Transactional(value = "tenantTransactionManager", rollbackFor = …)`. ⚠ bare `@Transactional` in `service` binds **landlord**.
- **`RestExceptionHandler` mapping**: `ApiInvalidParameterException`→422 (controller convention, e.g. `"Unknown roleId " + roleId`); `ApiConstraintViolationException`→409; `BusinessException`→422 (1-arg ctor key=`placeholder`); `EntityNotFoundException`→404; `ObjectOptimisticLockingFailureException`→409. **No `DataIntegrityViolationException` handler** (only mobile-scoped) → a unique-index race is a bare 500.
- **No Keycloak coupling**: none of the role methods calls `KeycloakService` (manages only `/wms_user`, `/warehouse/{fc}`). `git grep -E "RoleRepresentation|roles\(\)\.create|clientLevel|realmLevel" src/main` → 0 (control: 21 `import org.keycloak`). Permissions resolve user→group→role→function **by id**. WMS-only rename cannot desync Keycloak.
- **DB (measured 2026-09-27)**: `mywms_role` has `UNIQUE INDEX uk_6yyotbpw7edc76ejucc4mflf2 (name)` and `uk_d3w5xk1nns0ibm6bhgfkishku (number)` (V2.2.00) on every sampled tenant (wsl-wineco-uat 137 roles · nywh-hydra-prd 9 · nywh-hydra-uat 14 · c1wh-shipitez-prd 9 · nywh-shipitez-prd 9 · dev_wh01_om1 145); 0 duplicate names exact or case-insensitive; max length 26; no whitespace anomalies. `mywms_group` has **no** name unique index (nywh-shipitez-prd has `GROUP000007`×2, `GROUP000008`×2).
  - (a) today a dup-name SDR PUT → index → 409; through a new controller without a pre-check → **500** (AC-5).
  - (b) the index does **not** stop the attack (rename to a name absent on that tenant — seeds skip missing roles silently; or rename the real one away first).

## 2. Proposed shape (non-binding)

`POST /v3/userRole/update` body `{roleId, name, description}` (mirrors `saveRoleFunctions` + its `requiredId` helper). A distinct POST path keeps the SDR 405 unambiguous — a controller `@PutMapping("/{id}")` would shadow the SDR route and blur AC-1. Class-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` covers it; class is in `GUARDED`.

`UserRoleService#updateRole(roleId, name, description)`, `@Transactional(value="tenantTransactionManager", rollbackFor=ApiInvalidParameterException.class)`:
1. name non-blank, ≤255; null description → `""` (NOT NULL column).
2. unknown id → 404.
3. `findByName(name)` returns a *different* role → 422 naming it; same role's own name → 200 no-op.
4. set only `name`, `description`; ignore `number`, `connector`, `additionalcontent`, `functions`, `version`.
5. map a unique-index race to 409/422 **in the controller** (after rollback) — catching inside the tx leaves it rollback-only → `UnexpectedRollbackException`.

A gate holder can already grant any function via `saveRoleFunctions`, so the endpoint confers nothing new; the fix removes rename from every plain `wms_user`.

## 3. Test patterns (wms2-api)

| Need | Pattern | Lane |
|---|---|---|
| **405 + stored name unchanged** | new `…ContextTest extends BaseControllerIntegrationTest` modelled on `SdrReadGateEnforcementContextTest`; insert role, `put("/v3/userRole/{id}")`, `isMethodNotAllowed()`, re-read. Guard mode OFF default (withdrawal is 405 at OFF) | **Surefire full-context**; must end `ContextTest` (surefire excludes `*IntegrationTest`). No HTTP-level SDR 405 test exists today |
| Exposure pins | `AccessChainSdrWriteExposureUnitTest`; `SdrWriteWithdrawalContextTest`, `PutForCreationWithdrawalContextTest` (`ResourceMappings`) | unit / context |
| Controller behaviour | `UserRoleControllerUnitTest` (`BaseControllerUnitTest`, `setupMockMvc(controller, new RestExceptionHandler())`, `@Nested` per endpoint) | unit; **no interceptor** |
| Service + tx manager | `UserRoleServiceUnitTest`; `UserRoleServiceTransactionBoundaryTest` (mocked tenant/landlord TMs, verifies `rollback(tenantStatus)`, never commit) | surefire |
| **403 without gate** | `UserAdminFunctionGateUnitTest` → `FunctionGuardInterceptor.preHandle` with `SdrTestGuards.inert()`; optional context row with `@MockitoBean AccessService` → `deny(MISSING_FUNCTION, …)` | unit + context |

Memory rules: gate tests need UNGATED rows + full varargs; anti-drift covers only GUARDED (UserRoleController is); standalone MockMvc installs no interceptor so cannot prove a 403.

## 4. Web-ui test patterns

Extend `test/store/adminRoleErrorHandling.spec.js` (`harness({get, post, put})`, `roleActions.updateRole.call(scope, ctx, {...})`). New: `$post('/userRole/update', {roleId, name, description})` exactly (no `number`/`connector`/`_links`); `$put` never called; 422 reason still toasts; 5xx → `GENERIC_ERROR`.
Run: `cd v2/wms2-web-ui && export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"; node_modules/.bin/jest --testPathPattern=adminRoleErrorHandling`.

## 5. Acceptance-criteria candidates

| AC | Failing test | Fails today because |
|---|---|---|
| AC-1 PUT `/v3/userRole/{id}` → **405**; stored name & number unchanged | ContextTest | today 200/204 and rename persists |
| AC-1b UserRole item has no write verbs; UserGroup item **keeps** PUT (control) | inverted `AccessChainSdrWriteExposureUnitTest`; `SdrWriteWithdrawalContextTest` WITHDRAWN | `contains(PUT)` true today |
| AC-2 gate holder renames + changes description → 200, row updated | controller + service unit | ⚠ **trap**: in the full-context lane `POST /v3/userRole/update` today resolves as SDR item POST id=`update` → **405**, not 404. Assert `isOk()` + row, never `is4xxClientError()` |
| AC-3 no gate → **403** | `UserAdminFunctionGateUnitTest` row + handler set; optional context row | assert exactly `isForbidden()` (today's 405 must not satisfy it) |
| AC-4 `number`/`connector` unchanged even if sent | unit | endpoint absent; mutation copying number → red |
| AC-5 other role's name → **422** naming it, row unchanged; own name → 200 | unit (+ context row if H2 creates the unique index — verify) | without pre-check → 500 |
| AC-6 unknown id → 404; blank name → 422 | unit | endpoint absent |
| AC-7 admin screen calls new endpoint | Jest | today `$put('/userRole/7', …)` |
| AC-8 service method binds `tenantTransactionManager` | copy `UserRoleServiceTransactionBoundaryTest` | mutation: bare `@Transactional` → landlord → red |

## 6. Risks

1. **Deploy order** — API first. Single API PR (endpoint + withdrawal) → Edit Role 405 window until UI deploys; UI shows the refusal toast, no corruption, renames rare. Alternative 3-PR (endpoint → UI → withdrawal) has no window but keeps the hole open a cycle longer. Watch the `:develop` tag race; verify via `/api/public/version`.
2. **V2.2.34 window** — stays exploitable until this reaches prd; order the tickets or rekey V2.2.34 by id/number (per `SBDEV-3381-evidence/review-3b-security.md`).
3. Future name-keyed seeds on roles (gate holders) / groups (every user via UserGroup item PUT — A11).
4. New handler must be on `UserRoleController`, not `AdminController` (base of 43; `FunctionGuardArchTest` AC-5).
5. Stale-claim sweep: A2, A3, A4, `UserAdminFunctionGateUnitTest` javadoc *"All four declared handlers"* — grep the claim text.
6. Optimistic lock: `@Version` present but endpoint takes no version → last write wins (same as today's UI).

Horizontal scalability: N/A (stateless; DB unique index arbitrates). v2 constraint: tenant TM (AC-8). No Flyway (index already on every sampled tenant).

## Open questions (for Nam)
1. Deploy split: 1 API PR with a brief Edit-Role 405 window (rec.) vs 3 PRs.
2. Duplicate-name status: 422 (rec., controller convention) vs 409.
3. Case-variant names: allow (rec.; index + migrations case-sensitive, so a case variant can't capture a grant) vs reject.
