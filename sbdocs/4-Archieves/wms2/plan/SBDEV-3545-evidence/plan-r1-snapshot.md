---
title: "SBDEV-3545 — Any wms_user can rename a role over SDR (name-keyed grant self-grant)"
ticket: "SBDEV-3545"
ticket_url: "https://app.clickup.com/t/868mab5jh"
type: bugfix
priority: high
status: "pending approval — ralplan round 1"
project: [wms2]
version: v2
tier: T3
repos: [v2/wms2-api, v2/wms2-web-ui]
db_verified: true
requester: "Nam Park (SBDEV-3381 security review lane)"
created: 2026-09-27
updated: 2026-09-27
related:
  - "[[SBDEV-3381-cancellation-reversal-waive]]"
  - "[[SBDEV-3545-evidence/analysis]]"
tags: [plan, wms2, authz, sdr]
---

# SBDEV-3545 — Any wms_user can rename a role over SDR

**Ticket:** [SBDEV-3545](https://app.clickup.com/t/868mab5jh) · **Tier:** T3 (authorization, two repos) · **Status:** pending approval
**Evidence bundle:** [`SBDEV-3545-evidence/analysis.md`](SBDEV-3545-evidence/analysis.md). Every claim below that has no citation is cited there. All code was read at wms2-api `origin/develop` a715a27b and wms2-web-ui `origin/develop` b32a134.

---

## 1. Problem Statement

Any authenticated `wms_user` can change `mywms_role.name` (and `number`, `connector`, `additionalcontent`, `entityLock`) by sending `PUT /v3/userRole/{id}` through Spring Data REST. A rename grants nothing directly. It becomes a **self-grant** because Flyway seed migrations grant functions **by role name**:
- V2.2.19 and V2.2.21: *"KEYED BY ROLE NAME … MISSING ROLES ARE SKIPPED SILENTLY"*
- V2.2.34 (pending, SBDEV-3381): `AND r.name IN ('outbound-manager','super-admin')`

The attack is two PUTs: move the real role's name aside (the name is `UNIQUE`), then rename your own role to it. It can also be done by renaming to a seed name that is simply absent on that tenant.

**DB verification (2026-09-27, 8 tenants):**
- `SELECT sysvalue FROM los_sysprop WHERE syskey='WMS2_SDR_READ_GUARD_MODE'` returned **`OFF` on all 8**: dev_wh01_om1, nywh-hydra-prd, nywh-hydra-uat, nywh-shipitez-prd, nywh-shipitez-uat, c1wh-shipitez-prd, c1wh-shipitez-uat, wsl-wineco-uat.
  - Positive control: the same query returned `count(*) FROM los_sysprop` = 151–163 on each tenant.
  - `OFF` means the only gate is inert: `SdrFunctionRules` `rules.put(UserRole.class, USER_ADMIN_VIEW)`.
- Rename audit: `outbound-manager`, `super-admin` and `inventory-manager` have `modified` ≤ 2023-03-07 on every tenant. **No evidence of exploitation.**
- `number` differs per tenant: `ROLE000003`/`ROLE000006` on 3 tenants, `ROLE000004`/`ROLE000007` on 5.
- `mywms_role` has `UNIQUE(name)` and `UNIQUE(number)` on every sampled tenant, with 0 duplicate names (exact or case-insensitive).

## 2. Root Cause Analysis

### Bug 1 — SDR item PUT on `UserRole` is still exported
`RestConfiguration#configureAccessChainMembershipWriteExposure`:
```java
config.getExposureConfiguration()
    .forDomainType(UserRole.class)
    .withItemExposure((metadata, httpMethods) ->
        httpMethods.disable(HttpMethod.PATCH, HttpMethod.DELETE));
```
PUT was kept on purpose, for the admin screen. The javadoc records that reasoning: *"`PUT` is safe and is deliberately kept… `store/admin/role.js` … `$put('/userRole' + urlPart)`"*. The claim of safety covered only the **associations**: SDR's PUT merge skips linked `functions`, a point `UserRoleRepository`'s javadoc also makes. It never covered the **scalar** fields. `UserRole.name` is a plain `@NotNull private String name;`, and `/v3/**` requires only the `wms_user` authority.

### Bug 2 — the one legitimate rename path depends on Bug 1
`wms2-web-ui components/admin/userManagement/roles/editRole.vue` binds "Role Name" with `v-model="item.name"`. On Edit it dispatches `admin/role/updateRole`, and `store/admin/role.js` does `this.$axios.$put('/userRole' + urlPart, data)`. `UserRoleController` (class-gated `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)`) has **no update handler**; its handlers are create, delete, saveRoleFunctions and userRoleDetailsById. So removing Bug 1 alone would break legitimate renames. That is why `@ReadOnlyProperty` (the ticket's option 1) was rejected: every rename would silently return 200.

### Not the cause (ruled out)
- **Keycloak coupling:** none. No role method calls `KeycloakService`, and `git grep` for `RoleRepresentation|roles().create|clientLevel|realmLevel` returns 0 (control: 21 `import org.keycloak`). Access resolves user→group→role→function **by id**.
- **No other caller:** wms2-mobile-ui, siteboss-frontend and oms-laravel-api contain 0 `/userRole` references, each scan with a positive control (analysis §0 A8, A9).

## 3. Architecture Overview

```
editRole.vue ──dispatch──> store/admin/role.js#updateRole
   today:  PUT  /v3/userRole/{id}  ──> SDR RepositoryEntityController (ungated at OFF)  ✗
   after:  POST /v3/userRole/update ─> FunctionGuardInterceptor (WEB_UI_VIEW_USER_MANAGEMENT)
                                        └> UserRoleController#updateRole ─> UserRoleService#updateRole
                                             @Transactional("tenantTransactionManager") ─> mywms_role
           PUT  /v3/userRole/{id}  ──> 405 (item WRITE_VERBS withdrawn)
```

| File | Role |
|---|---|
| `wms2-api …/RestConfiguration.java` | SDR exposure: add the withdrawal; fix three stale javadoc copies |
| `wms2-api …/controller/UserRoleController.java` | new `updateRole` handler; class javadoc count |
| `wms2-api …/service/UserRoleService.java` | new transactional `updateRole` |
| `wms2-api …/repo/jpa/UserRoleRepository.java` | javadoc: remove *"Leaving the item `PUT`/`PATCH` exported is safe"* |
| `wms2-web-ui store/admin/role.js` | `updateRole` → `$post('/userRole/update', {roleId, name, description})` |

## 4. Fix Design

### Fix A — withdraw item PUT on `UserRole` (wms2-api)
Change the `UserRole` item exposure from `disable(PATCH, DELETE)` to `disable(WRITE_VERBS)`, matching the `User` block beside it. Keep `disablePutForCreation()` and the association withdrawal as defence in depth. `UserGroup` is **unchanged**; see §10 follow-up F-1.
*Why this over `@ReadOnlyProperty`:* a withdrawn verb returns 405 to everyone, even at guard mode `OFF`, and a status code can be tested. A read-only property returns 200 and silently drops the change, which hides regressions. It would also leave `connector`, `additionalcontent` and `entityLock` writable.

### Fix B — gated update endpoint (wms2-api)
`POST /v3/userRole/update`, body `{roleId, name, description}`. The body mirrors `saveRoleFunctions` and reuses its `requiredId` helper. The handler is declared **on `UserRoleController`**, not `AdminController` (which is the base class of 43 controllers). It inherits the class gate and is already in `GUARDED`.
*Why a distinct POST path and not `@PutMapping("/{id}")`:* a controller PUT on the same path would shadow the SDR route. Fix A's 405 then could not be observed, and AC-1 would prove nothing.

`UserRoleService#updateRole(Long roleId, String name, String description)`, annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = ApiInvalidParameterException.class)`. A bare `@Transactional` in `service` binds the landlord manager.
1. Blank name, or name longer than 255 → `ApiInvalidParameterException` (422). A null description is stored as `""` (the column is NOT NULL).
2. Unknown id → `EntityNotFoundException` (404).
3. `findByName(name)` returns a **different** id → `ApiInvalidParameterException` (422) naming the name. The role's own current name → no-op, 200. Comparison is case-sensitive (§10 D6).
4. Assign **only** `name` and `description`. Any `number`, `connector`, `additionalcontent`, `functions` or `version` in the body are ignored and never read from the map.
5. A race on the unique index (`DataIntegrityViolationException`) is caught **in the controller**, after the transaction has rolled back, and rethrown as a 422 with the same message. Catching it inside the transaction would mark it rollback-only and throw `UnexpectedRollbackException`.

Response: 200 with `{id, name, description, number}`.

### Fix C — admin screen uses Fix B (wms2-web-ui)
`store/admin/role.js#updateRole`:
```js
const result = await this.$axios.$post('/userRole/update',
  { roleId: data.id, name: data.name, description: data.description })
```
Error handling stays unchanged (`adminWriteError`). `editRole.vue` needs no change.

### Fix D — stale-claim sweep (both repos)
The claim *"UserRole item PUT is kept / safe"* has sibling copies. Fix all of them:
- `RestConfiguration`: three javadocs.
- `UserRoleRepository`: class javadoc.
- `UserRoleController`: *"all four handlers"*.
- `UserAdminFunctionGateUnitTest`: javadoc *"All four declared handlers"*.
- web-ui `admin.cy.js`: prose.

Sweep with `git grep -n -i "userRole.*PUT\|item PUT"` in both repos, grepping the **claim**, not one token.

## 5. Implementation

### 5.1 Prerequisites
| # | Item | Status |
|---|---|---|
| 1 | DB state: `UNIQUE(name)` on `mywms_role` exists on every sampled tenant (base V2.2.00) → **no Flyway migration** | verified 2026-09-27 |
| 2 | Sysprops: none added. The guard mode stays `OFF`; the fix does not depend on it | N/A |
| 3 | Deploy order (**§10 D4**): merge the wms2-api PR, then merge the wms2-web-ui PR straight after, and ask devops to promote them together. Between the two deploys, Edit Role shows a refusal toast (405). Renames are rare, and no data is at risk | required |
| 4 | Check the `:develop` tag race after both merges: `/api/public/version` SHA plus the web-ui build | required |
| 5 | **SBDEV-3381 V2.2.34** stays exploitable until this fix is on each tenant. Its §5.1 #9 role-identity check remains the detection control until then | coordinate |
| 6 | Feature flags, external systems, data backfill, monitoring | N/A: pure authz/API change |

### 5.2 Steps (each an atomic commit)
1. wms2-api, branch `bugfix/SBDEV-3545-userrole-sdr-rename` off freshly fetched `origin/develop` (per-ticket worktree). TDD gate: failing tests for AC-1…AC-8 (§6).
2. Fix B: service, then controller, then gate-test handler set. Makes AC-2…AC-6 and AC-8 pass.
3. Fix A, plus inverting the seven exposure pins (analysis §0 table). Makes AC-1 and AC-1b pass.
4. Fix D: javadoc sweep.
5. wms2-web-ui, same branch name: Fix C, plus inverting the two `put:` Jest cases. Makes AC-7 pass.
6. Full suites compared with the fresh develop baselines; PIT scoped to `UserRoleService` and `UserRoleController`.

## 6. Test Plan

⚠ **TDD trap.** In the full-context lane, `POST /v3/userRole/update` today resolves as an **SDR item POST with id `update` and returns 405**, not 404. Every new test asserts an **exact** status (`isOk()`, `isForbidden()`, `isUnprocessableEntity()`), never `is4xxClientError()`. A 405 must not satisfy any AC except AC-1.

| AC | Assertion | Test (lane) | Why it fails today |
|---|---|---|---|
| AC-1 | `PUT /v3/userRole/{id}` with a changed `name`/`number` → **405**, and a re-read shows the stored name and number unchanged | new `UserRoleSdrWriteContextTest extends BaseControllerIntegrationTest` (surefire, full context, H2, guard mode default OFF). The name must end in `ContextTest`, because surefire excludes `*IntegrationTest` | returns 200/204 and the rename persists |
| AC-1b | the UserRole item exposes no write verb; the **UserGroup item still exposes PUT** (control that nothing wider was withdrawn) | `AccessChainSdrWriteExposureUnitTest` (split), `SdrWriteWithdrawalContextTest` (UserRole moves `MUST_STAY_WRITABLE`→`WITHDRAWN`, sizes 9→8, 50→51), `MustStayWritableCollectionPostWithdrawalContextTest`, `PutForCreationWithdrawalContextTest` | `contains(PUT)` is true |
| AC-2 | a gate holder renames and changes the description → 200, and the row carries both | `UserRoleServiceUnitTest`, `UserRoleControllerUnitTest` (`@Nested UpdateRole`), plus one context row asserting `isOk()` and the row | endpoint absent (context lane returns 405) |
| AC-3 | a caller without `WEB_UI_VIEW_USER_MANAGEMENT` → **403** | `UserAdminFunctionGateUnitTest`: add `updateRole/2` to `USER_ROLE_HANDLERS` and a `@CsvSource` row, plus an **ungated** row (full varargs); a context row with `@MockitoBean AccessService` → `deny(MISSING_FUNCTION)` asserting `isForbidden()` | handler-set pin; context returns 405 ≠ 403 |
| AC-4 | a body carrying `number:"X"` or `connector:true` → stored `number` and `connector` unchanged | service unit | endpoint absent. Mutant: copy `number` from the map → red |
| AC-5 | another role's name → **422**, message contains the name, row unchanged; the role's own name → 200 | service unit; a context row **only if** the H2 schema builds the unique index (check at gate time and record the result) | today a unique-index hit becomes a 500 |
| AC-6 | unknown id → 404; blank name → 422 | controller unit | endpoint absent |
| AC-7 | `updateRole` calls `$post('/userRole/update', {roleId,name,description})` exactly (no `number`, `connector` or `_links`); `$put` is never called; a 422 reason still toasts; a 5xx shows `GENERIC_ERROR` | web-ui `test/store/adminRoleErrorHandling.spec.js` | calls `$put('/userRole/7', …)` |
| AC-8 | `updateRole` binds `tenantTransactionManager`: rollback on the tenant manager, landlord never touched | extend `UserRoleServiceTransactionBoundaryTest` | method absent. Mutant: bare `@Transactional` → red |

**Floor:**
- Every new assertion is mutation-checked, with the kill attributable (the failure message names the mutant). PIT for the Java classes.
- Hand-checked mutants: re-enable PUT in `RestConfiguration`; drop the dup check; copy `number` from the map; bare `@Transactional`.
- Jest: mutate `role.js` back to `$put`.
- Run commands: `mvn -o test -Dtest=…` scoped first (**never** a `-Dtest` selector joined with `+`, which leaves stale XML), then the full `mvn verify` against a fresh develop baseline. Jest via nvm: `node_modules/.bin/jest --testPathPattern=adminRoleErrorHandling`, then the full suite against its baseline.

### Manual test plan
| Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Admin renames a role | dev (dev_wh01_om1) | Admin → User Management → Roles → Edit → change name and description → Submit | "Role updated"; the grid shows the new name; `SELECT name, description, number, version FROM mywms_role WHERE id=?` shows the new values and an unchanged `number` | |
| Duplicate name | dev | Edit a role, set its name to another role's name | Toast shows the server's reason; row unchanged | |
| Plain wms_user PUT | dev | `curl -X PUT …/v3/userRole/{id}` with a `wms_user`-only token, `X-Tenant-ID`, `facility_code`, body `{"name":"x"}` | **405**; row unchanged | |
| Plain wms_user new endpoint | dev | `curl -X POST …/v3/userRole/update` with the same token | **403** | |
| Description-only edit | dev | Edit only the description | 200; name unchanged | |

## 7. Horizontal Scalability Validation
In-JVM state **No** · pool math **No** (one short tenant tx) · scheduled jobs **No** · long tx **No** (no external I/O) · request affinity **No** · retry/idempotency **No** (same body → same end state; the unique index arbitrates across replicas) · tenant context **No** (request thread only) · distributed lock **No** (`@Version` present; last write wins, as today's UI) · cache invalidation **No** (`UserRole` is not `@Cacheable`; confirm at gate time with `git grep -n Cacheable` on `UserRole*`) · external notifications **No**.

**v2 constraints:**
- OSIV off: service loads and saves inside one tx ✓
- tenant TM: AC-8 ✓
- readOnly: N/A (write)
- Caffeine: see above
- jakarta: ✓
- H2 SQL: no native SQL ✓
- controller test: `UserRoleControllerUnitTest` plus the context test ✓
- metrics: N/A (admin path, not hot)

## 8. Risks & Mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| Edit Role returns 405 between the API and UI deploys | Admins can't rename for minutes to hours | D4: back-to-back merges, promoted together; the toast explains it; no data risk |
| A hidden SDR PUT caller not found by the scans | That caller breaks with 405 | 0 hits across mobile-ui, siteboss-frontend and oms-laravel-api, each with a positive control; the blind spot (URL built from fragments) is accepted; a 405 fails loudly, not silently |
| A dup-name race returns 500 | An admin sees a generic error | Fix B step 5 maps `DataIntegrityViolationException` to 422 outside the tx |
| V2.2.34 lands before this fix | The self-grant window stays open | §5.1 #5; SBDEV-3381's role-identity check detects it |
| Future seeds keyed on group names | Same attack via `UserGroup` item PUT | Follow-up F-1 (proposed, not filed) |
| Exposure pins inverted too broadly | UserGroup PUT withdrawn by accident, breaking group edit | AC-1b keeps UserGroup PUT as an asserted control |

## 9. Completeness checklist
| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1: 8 tenants plus a positive control; `db_verified: true` |
| 1 | All call sites enumerated | ✓ analysis §0 A1–A13; every in-scope row maps to Fix A–D |
| 2 | Adjacent bugs | ✓ A11 UserGroup (out of scope → F-1); A12 other scalars (covered by Fix A) |
| 3 | Backward compatibility | ✓ breaking: SDR item PUT removed. Its only consumer (A5) moves in Fix C; D4 covers the deploy gap |
| 4 | Concurrency | ✓ unique-index race → 422 (Fix B.5); `@Version` last-write-wins is unchanged from today |
| 5 | Multi-tenant | ✓ tenant TM (AC-8); per-tenant `number` values are untouched |
| 6 | Error handling | ✓ 422 / 404 / 403 / 405 mapped through the existing `RestExceptionHandler` types |
| 7 | Observability | no. An admin rename is rare and audited by `modified`/`version`; the 405 appears in access logs |
| 8 | Rollback / migration | ✓ no Flyway. Revert both PRs to roll back (the API revert alone restores the old UI path) |
| 9 | Test coverage | ✓ §6 AC-1…AC-8, named classes, manual table |
| 10 | Cross-version | no. v1 is reference-only and has no `/v3` SDR role surface. Out of scope per standing rule |

## 10. Resolved Decisions (Nam, 2026-09-27) and Follow-ups
- **D1** Withdraw SDR item PUT on `UserRole` (405), not `@ReadOnlyProperty`.
- **D2** The new gated endpoint may change **name and description only**; `number` is immutable.
- **D3** The web-ui `updateRole` moves to the new endpoint.
- **D4** One API PR, then one UI PR merged right after, promoted together. The brief Edit Role 405 window is accepted.
- **D5** A duplicate name → **422** (`ApiInvalidParameterException`) naming the duplicate; the role's own name → 200.
- **D6** Names differing only by case are **allowed**. The unique index and the seeds are case-sensitive, so a case variant cannot capture a grant.
- **F-1 (proposed T3 follow-up, not filed):** `UserGroup` item PUT has the same shape (analysis A11). It is latent today, because nothing grants by `mywms_group.name` and `mywms_group` has no name unique index. It becomes live the moment a seed keys on a group name. Evidence: `RestConfiguration` `forDomainType(UserGroup.class)…disable(HttpMethod.PATCH, HttpMethod.DELETE)`. Blast radius: every `wms_user`. Cost: the same shape as this ticket (endpoint plus UI move).
- **F-2 (proposed, SBDEV-3381 scope):** rekey V2.2.34 by role id or `number` per tenant instead of by name. Given the per-tenant `number` split, it would need a per-tenant mapping. Nam's call.

## 11. Implementation Status
_Not started._
