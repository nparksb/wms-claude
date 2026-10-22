---
title: "SBDEV-3545 — Any wms_user can rename a role over SDR (name-keyed grant self-grant)"
ticket: "SBDEV-3545"
ticket_url: "https://app.clickup.com/t/868mab5jh"
type: bugfix
priority: high
status: "pending approval — ralplan round 2"
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

# SBDEV-3545: any wms_user can rename a role over SDR

**Ticket:** [SBDEV-3545](https://app.clickup.com/t/868mab5jh) · **Tier:** T3 (authorization, two repos) · **Status:** pending approval
**Base:** wms2-api `origin/develop` **286b5673** (SBDEV-3381 merged; the 28 files it brought in do not touch the role surface) · wms2-web-ui `origin/develop` b32a134.
**Evidence:** [`analysis.md`](SBDEV-3545-evidence/analysis.md) · round 1 reviews: [`review-r1-architect.md`](SBDEV-3545-evidence/review-r1-architect.md), [`review-r1-critic.md`](SBDEV-3545-evidence/review-r1-critic.md). A claim below with no citation is cited in `analysis.md`.

---

## 1. Problem Statement

Any authenticated `wms_user` can send `PUT /v3/userRole/{id}` (Spring Data REST) and change `mywms_role.name`, along with `number`, `connector`, `additionalcontent` and `entityLock`. A rename grants nothing by itself. It becomes a **self-grant** because Flyway seed migrations grant functions **by role name**. The complete set was found by counting `git grep -o -E "[a-z_]+\.name *(=|IN) *\(?'"` over `db/migration`, which gives **8 `r.name` predicates**:
- V2.2.18: `r.name IN ('outbound-worker', 'outbound-manager', 'super-admin')` and `('outbound-manager', 'inventory-manager')`
- V2.2.19: four predicates
- V2.2.21: `r.name = 'inventory-manager'`
- **V2.2.34 (SBDEV-3381, merged 2026-09-27):** `AND r.name IN ('outbound-manager','super-admin')`

The seed-keyed names are **`outbound-worker`, `outbound-manager`, `inventory-manager` and `super-admin`**. The other aliases the grep hits are function, location and user names. V2.2.21's `'anonymous'` is a *user* name (`u.name`) inside a comment.

The attack takes two PUTs: move the real role's name aside (`name` is UNIQUE), then rename your own role to it. Alternatively, rename your role to a seed name that doesn't exist on that tenant; the seeds skip missing roles silently.

**When a tenant is exposed.** Flyway applies each version once. For a given seed, the exposure is the moment that version **first applies on a tenant**; after that the grant is bound by id to whichever role held the name at that moment. Today that means V2.2.34 on every tenant that hasn't run it yet. After that, the rename stays latent until the next name-keyed seed.

**DB verification (2026-09-27):**
- **Guard mode.** `los_sysprop.WMS2_SDR_READ_GUARD_MODE` is **`OFF` on all 8 tenants**: dev_wh01_om1, nywh-hydra-prd/uat, nywh-shipitez-prd/uat, c1wh-shipitez-prd/uat and wsl-wineco-uat. Positive control: `count(*) FROM los_sysprop` returned 151–163 in the same query. At `OFF`, the only gate (`SdrFunctionRules` `rules.put(UserRole.class, USER_ADMIN_VIEW)`) does nothing.
- **Rename audit.** On all 8 tenants, the four seed-keyed role names were last modified on or before 2023-03-07. `version > 0` shows up only on the old seed tenants: `super-admin` at v4 on dev and wineco-uat, last modified 2019-07-02. **No evidence of exploitation.**
  - Method: `modified` is kept current by `AbstractBaseEntity`'s `@EntityListeners(AuditingEntityListener.class)` and `@LastModifiedDate`.
  - Blind spot: a rename that was later reverted also bumps `modified`, so a revert would still show up. But a direct SQL rename that bypasses JPA would not.
- **V2.2.34 on dev.** `flyway_schema_history` on dev_wh01_om1 reaches only **2.2.33** so far, so V2.2.34 has not applied there yet (control: `count(*) FROM mywms_role` = 145). The roles were last modified in 2019, so the pre-apply identity check passes on dev.
- **Per-tenant numbering.** `number` differs by tenant: `ROLE000003`/`ROLE000006` on 3 tenants and `ROLE000004`/`ROLE000007` on 5.
- **Unique indexes.** `mywms_role` has `UNIQUE(name)` and `UNIQUE(number)` on **6 sampled tenants** (analysis §1), with 0 duplicate names, whether compared exactly or case-insensitively.

## 2. Root Cause Analysis

### Bug 1: SDR item PUT on `UserRole` is still exported
`RestConfiguration#configureAccessChainMembershipWriteExposure`:
```java
config.getExposureConfiguration()
    .forDomainType(UserRole.class)
    .withItemExposure((metadata, httpMethods) ->
        httpMethods.disable(HttpMethod.PATCH, HttpMethod.DELETE));
```
PUT was kept deliberately for the admin screen (javadoc: *"`{@code PUT}` is safe and is deliberately kept"*). That safety argument holds only for the **associations**: SDR's PUT merge skips linked `functions`, and `UserRoleRepository`'s javadoc says the same. It never held for the **scalar** fields. `UserRole.name` is a plain `@NotNull private String name;`, and `/v3/**` requires only the `wms_user` authority.

### Bug 2: the only legitimate rename path depends on Bug 1
`wms2-web-ui components/admin/userManagement/roles/editRole.vue` binds the name field with `v-model="item.name"`. On Edit it dispatches `admin/role/updateRole`, and `store/admin/role.js` sends `this.$axios.$put('/userRole' + urlPart, data)`. `UserRoleController` has **no update handler**: it has only create, delete, saveRoleFunctions and userRoleDetailsById.

### Ruled out
- **Keycloak coupling.** No role method calls `KeycloakService`. Access resolves user→group→role→function **by id**.
- **Runtime reads of role names.** The only runtime name comparison is `AccessService#findConnectionUserToRole` (`curRole.getName().equals(role.getName())`). It compares two rows already loaded by id; names are unique and compared case-sensitively, so a rename can't change its result. Its callers use the direct user→role path, which v2 doesn't use.
- **Other callers of the PUT.** wms2-mobile-ui, siteboss-frontend and oms-laravel-api contain 0 `/userRole` references, each with a positive control. Blind spot: a URL built from fragments.
- **Caching.** No `@Cacheable` on any role, access or function type, and `SdrCacheEvictionEventHandler` doesn't reference UserRole (Architect (f)).

## 3. Architecture Overview
```
editRole.vue ──> store/admin/role.js#updateRole
  today:  PUT  /v3/userRole/{id}   ──> SDR (ungated at OFF)                            ✗
  after:  POST /v3/userRole/update ──> FunctionGuardInterceptor(WEB_UI_VIEW_USER_MANAGEMENT)
                                        └> UserRoleController#updateRole(Map, Principal)
                                             └> UserRoleService#updateRole  [tenantTransactionManager]
          PUT  /v3/userRole/{id}   ──> 405   (item GET, /search/*, /{id}/functions GET unaffected)
```

## 4. Fix Design

### Fix A: withdraw item PUT on `UserRole` (wms2-api)
- In `configureAccessChainMembershipWriteExposure`, change the `UserRole` item exposure from `disable(PATCH, DELETE)` to `disable(WRITE_VERBS)`. `WRITE_VERBS` is `{POST, PUT, PATCH, DELETE}`; the `User` block next to it already does this. Keep `disablePutForCreation()` and the association withdrawal. `UserGroup` stays **unchanged** (see F-1).
- **UserRole stays out of the global `SDR_WRITE_WITHDRAWN` array.** It is withdrawn by the per-type block only, because that array's own comment warns that listing a type there masks its per-type block, the same trap already documented for `User`. The test-side parity claim in `SdrWriteWithdrawalContextTest` (*"IDENTICAL — 50 names … 50 withdrawn + 9 kept = the 59 writable resources"*) is rewritten to "identical except UserRole, which the access-chain block withdraws per type".
- *Why not `@ReadOnlyProperty` (D1):* a withdrawn verb returns 405 to everyone, even at `OFF`, and the status can be tested. A read-only property returns 200 and silently drops the change, and it leaves `connector`, `additionalcontent` and `entityLock` writable.

### Fix B: gated update endpoint (wms2-api)
**Controller.** `@PostMapping(path = "/update", consumes/produces = "application/json") public ResponseEntity<Object> updateRole(@RequestBody Map<String, Object> reqMap, @AuthenticationPrincipal Principal principal)`, declared **on `UserRoleController`** (not on `AdminController`).
- The `(Map, Principal)` signature makes the gate-test key `updateRole/2`.
- It inherits the class gate and is already in `GUARDED` and in `FunctionGuardArchTest`'s `GOLDEN_MAP`.
- It reads only `roleId` (via the existing `requiredId`), `name` and `description`, then calls `service.updateRole(id, name, description)`.
- *Why not a controller `@PutMapping("/{id}")`:* D3 fixes the UI contract as a move to a separate endpoint, and a separate POST path can't shadow the SDR route. The `/create` precedent shows an MVC POST subpath wins over SDR today.

**Service.** `UserRoleService#updateRole(Long roleId, String name, String description)`, annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = ApiInvalidParameterException.class)`. A bare `@Transactional` in `service` would bind the landlord manager. The service runs these steps **in this order**, with **no setter before step 4**; otherwise Hibernate's AUTO flush would hit the unique index before `findByName` runs:
1. Validate `name`: not blank, at most 255 characters. Validate `description`: at most 255 characters (the column is `varchar(255) NOT NULL`), and store null as `""`. A violation is an `ApiInvalidParameterException` (422) with a field-specific message. No trimming, which matches `createRole`.
2. `findById(roleId)`. Missing → `EntityNotFoundException` (404).
3. `findByName(name)` returns a **different** id → `ApiInvalidParameterException` (422) *"Role name '<name>' already exists"*. The role's own current name passes. The check is case-sensitive (D6).
4. `setName(name)` and `setDescription(description)`, nothing else.

**Race mapping.** The controller catches `DataIntegrityViolationException` **after** the transaction has rolled back. It maps the exception to the duplicate 422 **only if** the root cause's SQLSTATE is `23505` or its message names `uk_6yyotbpw7edc76ejucc4mflf2`; anything else is rethrown. Catching it inside the transaction would mark the transaction rollback-only and cause an `UnexpectedRollbackException`.

Response: 200 with `{id, name, description, number}`.

### Fix C: the admin screen uses Fix B (wms2-web-ui)
`store/admin/role.js#updateRole` → `this.$axios.$post('/userRole/update', { roleId: data.id, name: data.name, description: data.description })`. The `adminWriteError` handling stays as it is, and `editRole.vue` doesn't change.

### Fix D: stale-claim sweep, listed by region (Critic M1)
- `RestConfiguration`, six regions:
  - *"`{@code PUT}` is safe and is deliberately kept"*
  - *"`UserGroup` and `UserRole` lose only PATCH/DELETE"*
  - *"what makes ordinary item PUT safe on UserGroup/UserRole"*
  - *"every live PUT caller … `store/admin/role.js` updateRole"*
  - *"the TEN resources with a live UI writer … `userRole`"*
  - the `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` javadoc *"`UserRole` item PUT (both `store/admin/{group,role}.js`"*. Its contents stay as they are, since collection POST remains withdrawn; only the "item PUT kept" wording changes.
- `UserRoleRepository`: *"Leaving the item `{@code PUT}`/`{@code PATCH}` exported is safe"*.
- `UserRoleController`: *"all four handlers"*.
- `UserAdminFunctionGateUnitTest`: *"All four declared handlers"*.
- `SdrMustStayWritableStateNotPatchableContextTest`: *"among the ten"*.
- `SdrWriteWithdrawalContextTest`: the parity claim (Fix A).
- web-ui `admin.cy.js`: prose only.

**Instrument.** The grep has to tolerate markup: `git grep -n -i -E "(PUT|put)[^.]*(safe|kept)|all four|among the ten|IDENTICAL|59 writable|live UI writer"` in both repos, narrowed by hand. **Positive control:** it must hit *"`{@code PUT}` is safe and is deliberately kept"*. A plain `userRole.*PUT` pattern misses that line.

## 5. Implementation

### 5.1 Prerequisites
| # | Item | Status |
|---|---|---|
| 1 | No Flyway migration. `UNIQUE(name)` already exists (base V2.2.00; seen on 6 sampled tenants) | verified |
| 2 | No sysprop changes. The fix works with guard mode `OFF` | N/A |
| 3 | **Deploy (D4):** merge the wms2-api PR, then merge the wms2-web-ui PR straight after, and promote them together. Edit Role shows a 405 refusal toast until the UI is deployed | required |
| 4 | Check the `:develop` tag race after both merges: the `/api/public/version` SHA and the web-ui build | required |
| 5 | **V2.2.34 promotion order.** V2.2.34 is on develop and has not yet applied on dev_wh01_om1. Ask devops to promote **3545 in the same release as 3381, or an earlier one**, on UAT and on PRD. If 3381 goes first on an environment, SBDEV-3381 §5.1 #9 becomes a **hard gate** there: run the role-identity SQL before promotion, then compare the waive holders **by role id** after the first boot. On dev, run the post-boot comparison once V2.2.34 applies | required — Nam to confirm with devops |
| 6 | Feature flags, external systems, backfill, monitoring | N/A (a pure authorization/API change) |

### 5.2 Steps (each step is one atomic commit)
1. wms2-api: create worktree `bugfix/SBDEV-3545-userrole-sdr-rename` off a freshly fetched `origin/develop`. Run the TDD gate: failing tests for AC-1…AC-9.
2. Fix B (service, then controller, then the gate-test handler set). Makes AC-2…AC-6 and AC-8 pass.
3. Fix A, plus the **5 exposure-pin inversions and 2 derived-count updates** in §6 AC-1b. Makes AC-1 and AC-1b pass.
4. Fix D sweep, plus AC-9 rail.
5. wms2-web-ui, same branch name: Fix C, plus converting the two `put:` Jest cases. Makes AC-7 pass.
6. Run the full suites and compare against fresh develop baselines. Run PIT scoped to `UserRoleService` and `UserRoleController`.

## 6. Test Plan

⚠ **The 405 trap.** Before the fix, the full-context lane routes `POST /v3/userRole/update` to **SDR as an item POST with id `update` → 405**. Every test therefore asserts an **exact** status (`isOk()`, `isForbidden()`, `isUnprocessableEntity()`). No 405 may satisfy any AC except AC-1.

| AC | Assertion | Test (lane) | Fails today because |
|---|---|---|---|
| AC-1 | `PUT /v3/userRole/{id}` with a changed name and number → **405**. Then `flush()` + `clear()`, re-read through JPA: name and number unchanged. **In-test controls:** `GET /v3/userRole/{id}` → `isOk()` with the same fixture and principal; `PUT /v3/userGroup/{id}` → **not** 405 | new `UserRoleSdrWriteContextTest extends BaseControllerIntegrationTest` (surefire full context; guard mode OFF). The name must end in `ContextTest`, because the pom excludes `**/*IntegrationTest.java` | today the PUT returns 200/204 and the rename persists. The re-read half must first be shown red against the unfixed code |
| AC-1b | UserRole item has no write verbs, and the **UserGroup item keeps PUT** (control) | Invert `AccessChainSdrWriteExposureUnitTest` (split both methods). `SdrWriteWithdrawalContextTest`: UserRole goes from `MUST_STAY_WRITABLE` to `WITHDRAWN`, sizes 9→8 and 50→51, parity javadoc per Fix A. `MustStayWritableCollectionPostWithdrawalContextTest`: drop it from `ITEM_VERBS_AUDITED_ELSEWHERE`, `checked` 8→7, keep the `REQUIRED_ITEM_VERBS` key-set pin consistent. `PutForCreationWithdrawalContextTest`: exclude UserRole from the `contains(PUT)` loop. `SdrMustStayWritableStateNotPatchableContextTest`: re-derive its count from the set, fix the javadoc | `contains(PUT)` is true today |
| AC-2 | A caller holding the gate: rename + new description → 200, and the row has both | `UserRoleServiceUnitTest`; `UserRoleControllerUnitTest` (`@Nested UpdateRole`); one context row: `isOk()` plus the row | the endpoint doesn't exist (the context lane gets 405) |
| AC-3 | A caller without `WEB_UI_VIEW_USER_MANAGEMENT` → **403** | `UserAdminFunctionGateUnitTest`: add `updateRole/2` to `USER_ROLE_HANDLERS`, a gated `@CsvSource` row, and an **ungated control row**: a handler on a non-`GUARDED` class passes `preHandle` with `checkAnyAccess` never called, verified with full varargs `(any(), any(), any())`. Plus a context row with `@MockitoBean AccessService` → `deny(MISSING_FUNCTION)` → `isForbidden()` | the handler-set pin fails; the context lane's 405 ≠ 403 |
| AC-4 | Payload fields other than name/description are ignored | **Controller unit:** post `{roleId:7,name:"n",description:"d",number:"X",connector:true}`, then `verify(service).updateRole(7L,"n","d")` and `verifyNoMoreInteractions`. **Service unit:** the loaded entity's `number`, `connector`, `additionalcontent` and `entityLock` are unchanged after the call | endpoint absent. Mutants: forward the map to the service, or set `number` inside it |
| AC-5 | Another role's name → **422** containing that name, row unchanged. The role's own name + a new description → 200, **and the description persists** | service unit. The context row is **skipped**: H2 uses `create-drop` and the entity declares no unique constraint, so H2 has no index (Critic, verified) | the pre-check is missing. Mutant: delete step 3 |
| AC-6 | Unknown id → 404. Blank name, name > 255 or description > 255 → 422 with a field-specific message | **service unit** (the real `orElseThrow` and validation), plus controller-unit mapping | endpoint absent. Mutant: drop `orElseThrow` or the length check |
| AC-6b | Race mapping: a `DataIntegrityViolationException` with SQLSTATE 23505 → 422 duplicate. With 22001 → **not** the duplicate message (rethrown) | controller unit with a mocked service throwing each cause | endpoint absent. Mutant: widen the catch to every DIVE |
| AC-7 | `updateRole` sends `$post('/userRole/update', {roleId,name,description})` exactly (no `number`, `connector` or `_links`); `roleId` comes from `data.id`; `$put` is never called; a 422 still shows its reason; a 5xx shows `GENERIC_ERROR` | web-ui `test/store/adminRoleErrorHandling.spec.js` | today the action calls `$put('/userRole/7', …)` |
| AC-8 | `updateRole` binds `tenantTransactionManager`: rolls back on the tenant manager and never touches the landlord manager | extend `UserRoleServiceTransactionBoundaryTest` (landlord is `@Primary` there) | method absent. Mutant: bare `@Transactional` |
| AC-9 | **Name-keyed-seed rail (Architect M-4).** A unit test scans `src/main/resources/db/migration/V*.sql` for `[rg]\.name\s*(=\|IN)\s*\(?'`. The allow-list is V2.2.18, V2.2.19, V2.2.21 and V2.2.34 (**8 predicates**). Any new hit fails with a message pointing to SBDEV-3545. **Non-vacuity:** assert that the scanned file count is > 0 and that the allow-listed hits are found (a positive control). Blind spots: dynamic SQL, other aliases, grants in Java `initDB` | new `NameKeyedGrantSeedRailTest` | the class is new. Mutants: remove one allow-list entry → red, naming the file; point the scan at an empty directory → red on the non-vacuity check |

**Floor.** Every new assertion gets an attributable mutation kill: PIT for the Java classes, plus hand mutants listed per row above. For Jest, mutate `role.js` back to `$put`. Run scoped tests first with `mvn -o test -Dtest=A,B` (never join classes with `+`), then `mvn verify` against a fresh develop baseline. Jest runs via nvm: `node_modules/.bin/jest --testPathPattern=adminRoleErrorHandling`, then the full suite against its baseline.

### Manual test plan (dev, dev_wh01_om1)
| Scenario | Steps | Expected | Pass/Fail |
|---|---|---|---|
| Admin rename | Admin → User Management → Roles → Edit: change name and description → Submit | "Role updated"; `SELECT name, description, number, version FROM mywms_role WHERE id=?` shows the new values and the same `number` | |
| Duplicate name | Edit a role and set its name to another role's name | the toast shows the server's reason; the row is unchanged | |
| Description only | Edit only the description | 200; name unchanged; description saved | |
| Plain wms_user PUT | `curl -X PUT …/v3/userRole/{id}` with a `wms_user`-only token, `X-Tenant-ID`, `facility_code`, and `{"name":"x"}` | **405**; row unchanged | |
| Plain wms_user endpoint | `curl -X POST …/v3/userRole/update` with the same token | **403** | |

## 7. Horizontal Scalability Validation and v2 constraints
- **Horizontal scalability.** Each check below is No:
  - in-JVM state · pool math (one short tenant tx) · scheduled jobs · long tx
  - request affinity · retry/idempotency (the same body reaches the same end state; the unique index settles races across replicas)
  - tenant context (request thread only) · distributed lock (`@Version` exists but the endpoint takes no version, so the last write wins, as with today's UI)
  - cache invalidation (UserRole is not cached) · external notifications
- **v2 constraints:**
  - OSIV is off: the service loads and saves inside one transaction ✓
  - tenant transaction manager: AC-8 ✓
  - readOnly: N/A (a write)
  - jakarta ✓
  - no native SQL (H2) ✓
  - controller tests: unit + context ✓
  - metrics: N/A (an admin path)

## 8. Risks & Mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| V2.2.34 applies on a UAT/PRD tenant before 3545 reaches it | A renamed role picks up the waive grant | §5.1 #5: promote in the same release or earlier; otherwise SBDEV-3381 §5.1 #9 is a hard pre/post gate |
| Edit Role returns 405 between the API and UI deploys | Admins can't rename for a short time | D4: merge back to back and promote together; no data risk |
| A hidden SDR PUT caller | That caller gets 405 | 0 hits across three repos, each with a control; a 405 fails loudly |
| A DIVE that isn't a duplicate gets mislabelled | The admin sees a false "already exists" | Map only SQLSTATE 23505 (AC-6b); lengths are validated first |
| The pin inversion is too broad | UserGroup PUT is withdrawn and group editing breaks | AC-1 and AC-1b keep UserGroup PUT as an asserted control |
| A future name-keyed seed | Same class of attack | AC-9 rail; F-1 for groups |

## 9. Completeness checklist
| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1: 8 tenants plus a positive control; V2.2.34 not yet applied on dev |
| 1 | All callsites enumerated | ✓ analysis §0 A1–A13; Fix D lists every stale region |
| 2 | Adjacent bugs | ✓ A11 UserGroup → F-1; A12 other scalar fields → covered by Fix A |
| 3 | Backward compatibility | ✓ breaking change: item PUT is removed; its only consumer moves (Fix C); D4 covers the deploy gap |
| 4 | Concurrency | ✓ race → 422 only on 23505 (AC-6b); last write wins, as today |
| 5 | Multi-tenant | ✓ tenant transaction manager (AC-8); promotion order per tenant (§5.1 #5) |
| 6 | Error handling | ✓ 422 / 404 / 403 / 405 all go through existing handler types |
| 7 | Observability | no — renames are rare and audited through `modified`/`version`; the 405 appears in access logs |
| 8 | Rollback | ✓ no Flyway. **Revert both PRs, UI first**: reverting only the API would make the new UI get a 405 on `/update` |
| 9 | Test coverage | ✓ AC-1…AC-9, the manual table, PIT |
| 10 | Cross-version | no — v1 is reference-only and has no `/v3` SDR role surface |

## 10. Resolved Decisions (Nam, 2026-09-27) and Follow-ups
- **D1**: Withdraw SDR item PUT on `UserRole` (405), not `@ReadOnlyProperty`.
- **D2**: The new gated endpoint changes **name and description only**; `number` is immutable.
- **D3**: web-ui `updateRole` moves to the new endpoint.
- **D4**: One API PR, then one UI PR merged straight after, promoted together. The short 405 window is accepted.
- **D5**: A duplicate name → **422** naming it; the role's own name passes.
- **D6**: Names that differ only by case are **allowed**, since the index and the seeds are case-sensitive.
- **R2 (round-2 plan choices, open to override):**
  - UserRole stays out of `SDR_WRITE_WITHDRAWN` (Architect M-1 option a).
  - AC-9 rail added under this ticket as a sub-T3 addition.
  - Names are not trimmed.
- **F-1 (proposed T3, not filed):** `UserGroup` item PUT has the same shape (`forDomainType(UserGroup.class)…disable(HttpMethod.PATCH, HttpMethod.DELETE)`). It is latent: nothing grants by `mywms_group.name`, and `mywms_group` has no unique index on name. Blast radius: every `wms_user`, once a group-name seed exists (AC-9's `g.name` pattern already watches for that). Cost: the same shape as this ticket.
- **F-2 (proposed, SBDEV-3381 scope):** V2.2.34 **cannot** be edited: it is merged and applying it again would break the checksum. The options are an ops check (§5.1 #5, preferred) or, if a tenant is found compromised, a corrective migration that regrants by id. Nam decides.

## 11. Implementation Status
_Not started._
