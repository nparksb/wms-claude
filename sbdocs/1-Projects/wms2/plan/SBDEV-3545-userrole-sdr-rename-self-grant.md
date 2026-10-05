---
title: "SBDEV-3545 — Any wms_user can rename a role over SDR (name-keyed grant self-grant)"
ticket: "SBDEV-3545"
ticket_url: "https://app.clickup.com/t/868mab5jh"
type: bugfix
priority: high
status: implemented
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
**Evidence:** [`analysis.md`](SBDEV-3545-evidence/analysis.md) · reviews: [r1 Architect](SBDEV-3545-evidence/review-r1-architect.md) · [r1 Critic](SBDEV-3545-evidence/review-r1-critic.md) · [r2 Architect](SBDEV-3545-evidence/review-r2-architect.md) · [r2 Critic](SBDEV-3545-evidence/review-r2-critic.md). A claim below with no citation is cited in `analysis.md`.

---

## 1. Problem Statement

Any authenticated `wms_user` can send `PUT /v3/userRole/{id}` (Spring Data REST) and change `mywms_role.name`, along with `number`, `connector`, `additionalcontent` and `entityLock`. A rename grants nothing by itself. It becomes a **self-grant** because Flyway seed migrations grant functions **by role name**. The complete set was found by counting `git grep -o -E "[a-z_]+\.name *(=|IN) *\(?'"` over `db/migration`, which gives **8 `r.name` predicates**:
- V2.2.18: `r.name IN ('outbound-worker', 'outbound-manager', 'super-admin')` and `('outbound-manager', 'inventory-manager')`
- V2.2.19: four predicates
- V2.2.21: `r.name = 'inventory-manager'`
- **V2.2.34 (SBDEV-3381, merged 2026-09-27):** `AND r.name IN ('outbound-manager','super-admin')`

The seed-keyed names are **`outbound-worker`, `outbound-manager`, `inventory-manager` and `super-admin`**. The other aliases the grep hits are function, location and user names. V2.2.21's `'anonymous'` is a *user* name (`u.name`) inside a comment. **Second instrument:** the unaliased subquery form (`mywms_role WHERE name = '…'`) returns 0 role hits (confirmed by the r2 Critic).

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

**Race mapping.** The controller catches `DataIntegrityViolationException` **after** the transaction has rolled back. It maps it to the duplicate 422 **only if** `NestedExceptionUtils.getMostSpecificCause(e)` is a `SQLException` with SQLSTATE `23505`. `number` is immutable here, so any 23505 must come from the name index. Anything else is rethrown. Catching it inside the transaction would mark the transaction rollback-only and cause an `UnexpectedRollbackException`.

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
- `RestConfiguration`, a seventh region: the inline comment *"PUT is safe (mergeForPut skips linked associations) and is kept where the UI needs it"*.
- `SdrFunctionGuard`: the javadoc *"`UserGroup` and `UserRole` — are among the resources whose SDR writes SBDEV-3157's withdrawal kept live"*. The same claim appears in `SdrFunctionGuardUnitTest`.
- `UserRoleRepository`: *"Leaving the item `{@code PUT}`/`{@code PATCH}` exported is safe"*.
- `UserRoleController`: *"all four handlers"*.
- `UserAdminFunctionGateUnitTest`: *"All four declared handlers"*.
- `SdrMustStayWritableStateNotPatchableContextTest`: *"among the ten"*.
- `SdrWriteWithdrawalContextTest`: the parity claim (Fix A). Rewrite it as arithmetic: WITHDRAWN 51 = `SDR_WRITE_WITHDRAWN` 50 + UserRole, and 51 + 8 kept = 59. Also update the prose counts *"50 resources"* and *"9 resources that must KEEP"*, the class javadoc and the section comment.
- `PutForCreationWithdrawalContextTest`: class `@DisplayName` *"item PUT-to-existing intact"*, *"stays open on all four types"*, and its class javadoc.
- `AccessChainSdrWriteExposureUnitTest`: javadoc *"Deliberately NOT touched: aggregate writes on … UserRole … `$put('/userRole'`"* and two inline comments.
- `MustStayWritableCollectionPostWithdrawalContextTest` and `CustomerorderTransferLaneSdrWriteContextTest`: item-verb and "both lists" prose.
- web-ui `admin.cy.js`: prose only.

**Instruments (two, run both, in both repos).**
- **I-1:** `git grep -n -i -E "userRole" -- src | grep -i -E "put|writ|kept|live|safe|intact|touched"`. It gives about 60 hits, all reviewable.
- **I-2:** `git grep -n -E "IDENTICAL|59 writable|(50|9) resources|all four|among the ten|live UI writer|KEEP"` over the files I-1 touches.
- **Positive controls:** I-1 must hit *"`{@code PUT}` is safe and is deliberately kept"*. I-2 must hit the `PutForCreationWithdrawalContextTest` `@DisplayName`.
- **Blind spot:** a claim that names neither UserRole nor a count.
- The list above is what these two instruments found. It is not asserted to be closed.

## 5. Implementation

### 5.1 Prerequisites
| # | Item | Status |
|---|---|---|
| 1 | No Flyway migration. `UNIQUE(name)` already exists (base V2.2.00; seen on 6 sampled tenants) | verified |
| 2 | No sysprop changes. The fix works with guard mode `OFF` | N/A |
| 3 | **Deploy (D4):** merge the wms2-api PR, then merge the wms2-web-ui PR straight after, and promote them together. Edit Role shows a 405 refusal toast until the UI is deployed | required |
| 4 | Check the `:develop` tag race after both merges: the `/api/public/version` SHA and the web-ui build | required |
| 5 | **V2.2.34 promotion order.** V2.2.34 is on develop and has not yet applied on dev_wh01_om1. **Unconditionally**, for every tenant a promotion carrying V2.2.34 reaches:
  - run SBDEV-3381 §5.1 #9's role-identity SQL **before** the promotion;
  - after the first boot, compare the waive holders **by role id**.

  Shipping 3545 in the same image doesn't undo a rename made earlier: the grant binds at boot to whichever role holds the name. Promoting 3545 in the same release as 3381 or earlier only **narrows** the window. On dev, dev_wh01_om1 is the only active dev tenant, so run the post-boot comparison once V2.2.34 applies there. That will almost certainly happen before 3545 merges | required — Nam to confirm with devops |
| 6 | Feature flags, external systems, backfill, monitoring | N/A (a pure authorization/API change) |

### 5.2 Steps (each step is one atomic commit)
1. wms2-api: create worktree `bugfix/SBDEV-3545-userrole-sdr-rename` off a freshly fetched `origin/develop`. Run the TDD gate: failing tests for AC-1…AC-9.
2. Fix B (service, then controller, then the gate-test handler set). Makes AC-2…AC-6, AC-6b and AC-8 pass.
3. Fix A, plus the **5 exposure-pin inversions and 3 literal changes** (`hasSize(50)`→51, `hasSize(9)`→8, `isEqualTo(8)`→7) in §6 AC-1b. Makes AC-1 and AC-1b pass.
4. Fix D sweep, plus AC-9 rail.
5. wms2-web-ui, same branch name: Fix C, plus converting the two `put:` Jest cases. Makes AC-7 pass.
6. Run the full suites and compare against fresh develop baselines. Run PIT scoped to `UserRoleService` and `UserRoleController`.

## 6. Test Plan

⚠ **The pre-fix status trap.** The plan predicted 405 (SDR item POST with id `update`); **measured at the gate on 286b5673 it is 404**. Every test therefore asserts an **exact** status (`isOk()`, `isForbidden()`, `isUnprocessableEntity()`). No 405 may satisfy any AC except AC-1.

| AC | Assertion | Test (lane) | Fails today because |
|---|---|---|---|
| AC-1 | `PUT /v3/userRole/{id}` with a changed name and number → **405**. Then `flush()` + `clear()` on the **tenant** EntityManager (not a bare `@PersistenceContext`, which gets the landlord EM), and re-read through JPA: name and number unchanged. **In-test controls:**
  - `GET /v3/userRole/{id}` → `isOk()` with a `$.id` in the body (pins the `exposeIdsFor` dependency Fix C relies on);
  - `GET /v3/userRole` collection → `isOk()` (replaces the `collectionReadsRemainExposed` coverage lost when UserRole leaves `MUST_STAY_WRITABLE`);
  - `PUT /v3/userGroup/{id}` → the **exact** 2xx that SDR returns under this config (`returnBodyOnUpdate`), recorded when the gate runs | new `UserRoleSdrWriteContextTest extends BaseControllerIntegrationTest` (surefire full context; guard mode OFF). The name must end in `ContextTest`, because the pom excludes `**/*IntegrationTest.java` | today the PUT returns 200/204 and the rename persists. The re-read half must first be shown red against the unfixed code |
| AC-1b | UserRole item has no write verbs, and the **UserGroup item keeps PUT** (control) | Invert `AccessChainSdrWriteExposureUnitTest` (split both methods). `SdrWriteWithdrawalContextTest`: UserRole goes from `MUST_STAY_WRITABLE` to `WITHDRAWN`, sizes 9→8 and 50→51, parity javadoc per Fix A. `MustStayWritableCollectionPostWithdrawalContextTest`: drop it from `ITEM_VERBS_AUDITED_ELSEWHERE`, `checked` 8→7, keep the `REQUIRED_ITEM_VERBS` key-set pin consistent. `PutForCreationWithdrawalContextTest`: exclude UserRole from the `contains(PUT)` loop. `SdrMustStayWritableStateNotPatchableContextTest`: re-derive its count from the set, fix the javadoc | `contains(PUT)` is true today |
| AC-2 | A caller holding the gate: rename + new description → 200, the row has both, and the response body is exactly `{id, name, description, number}` | `UserRoleServiceUnitTest`; `UserRoleControllerUnitTest` (`@Nested UpdateRole`); one context row: `isOk()` plus the row | the endpoint doesn't exist (the context lane gets 405) |
| AC-3 | A caller without `WEB_UI_VIEW_USER_MANAGEMENT` → **403** | `UserAdminFunctionGateUnitTest`: add `updateRole/2` to `USER_ROLE_HANDLERS`, a gated `@CsvSource` row, and an **ungated control row**: a handler on a non-`GUARDED` class passes `preHandle`, asserted with `verifyNoInteractions(accessService)`. A `never()` on fixed arity would pass vacuously for a one-element vararg. Mutant: put `@RequiresFunction` on the control class → red. Plus a context row with `@MockitoBean AccessService` → `deny(MISSING_FUNCTION)` → `isForbidden()` | the handler-set pin fails; the context lane's 405 ≠ 403 |
| AC-4 | Payload fields other than name/description are ignored | **Controller unit:** post `{roleId:7,name:"n",description:"d",number:"X",connector:true}`, then `verify(service).updateRole(7L,"n","d")` and `verifyNoMoreInteractions`. **Service unit:** the loaded entity's `number`, `connector`, `additionalcontent` and `entityLock` are unchanged after the call | endpoint absent. Mutants: forward the map to the service, or set `number` inside it |
| AC-5 | Another role's name → **422** containing that name, row unchanged. The role's own name + a new description → 200, **and the description persists** | service unit. The context row is **skipped**: H2 uses `create-drop` and the entity declares no unique constraint, so H2 has no index (Critic, verified) | the pre-check is missing. Mutant: delete step 3 |
| AC-6 | Unknown id → 404. Blank name, name > 255 or description > 255 → 422 with a field-specific message | **service unit** (the real `orElseThrow` and validation), plus controller-unit mapping | endpoint absent. Mutant: drop `orElseThrow` or the length check |
| AC-6b | Race mapping: a `DataIntegrityViolationException` whose most specific cause has SQLSTATE 23505 → 422 duplicate. With 22001 → **not** the duplicate message (rethrown) | controller unit with a mocked service throwing each cause. The stack does deliver a plain DIVE at commit: `LockTimeoutHibernateJpaDialect extends HibernateJpaDialect`, with the same pattern already in `UserController`'s `deleteUser` catch | endpoint absent. Mutant: widen the catch to every DIVE |
| AC-7 | `updateRole` sends `$post('/userRole/update', {roleId,name,description})` exactly (no `number`, `connector` or `_links`); `roleId` comes from `data.id`; `$put` is never called; a 422 still shows its reason; a 5xx shows `GENERIC_ERROR` | web-ui `test/store/adminRoleErrorHandling.spec.js` | today the action calls `$put('/userRole/7', …)` |
| AC-8 | `updateRole` binds `tenantTransactionManager`: rolls back on the tenant manager and never touches the landlord manager | extend `UserRoleServiceTransactionBoundaryTest` (landlord is `@Primary` there) | method absent. Mutant: bare `@Transactional` |
| AC-9 | **Name-keyed-seed rail.** Scans migrations statement by statement (spec below). Any file outside the allow-list, or a count differing from the pinned value, fails with a message naming the file and SBDEV-3545 | new `NameKeyedGrantSeedRailTest` | the class is new. Mutants: remove an allow-list entry → red naming the file; narrow the pattern to aliased-only → red on the pinned count; point the scan at an empty directory → red on non-vacuity |

**AC-9 spec** (kept outside the table so the regex is copy-safe):
- For each `src/main/resources/db/migration/V*.sql`, strip `--` comments and split on `;`.
- A statement is flagged when it matches both `\bmywms_(role|group)\b(?!_)` and `(?i)(?<![A-Za-z0-9_])(?:[a-z_]+\.)?name\s*(=|in)\s*\(?'`.
- The pinned per-file counts **measured at the gate** are {V2.2.18: 2, V2.2.19: **5**, V2.2.21: 1, V2.2.34: 1} (9 total, 35 files scanned). V2.2.19's 5th statement is a known statement-level false positive: `FROM mywms_role r` plus `src.name`/`target.name` on `mywms_function`. It is documented in the class javadoc. The "narrow to aliased-only" mutant cannot be caught by the counts, because all 9 statements use an alias, so a synthetic unaliased control (`detectorFlagsAnUnaliasedNamePredicate`) catches it instead.
- *(Plan text before the gate, kept for the record: {V2.2.18: 2, V2.2.19: 4, V2.2.21: 1, V2.2.34: 1}.)* These must be **measured by the test on 286b5673 first**; the statement-level count may differ from the predicate count. Record the measured values, and investigate any mismatch before pinning.
- Non-vacuity: the number of files scanned is > 0, and the total flagged equals the sum of the pinned counts.
- Blind spots: dynamic SQL, and grants made in Java `initDB`.

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
  - tenant context (request thread only) · optimistic lock (`@Version` on `AbstractBaseEntity`: overlapping edits make the loser hit `ObjectOptimisticLockingFailureException` → 409 via `RestExceptionHandler`; only sequential edits are last-write-wins; OOLFE is not a DIVE, so the race catch can't swallow it)
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
| A role renamed before V2.2.34 first applies on a tenant | The renamed role picks up the waive grant | §5.1 #5: an unconditional pre/post identity check on every tenant; release ordering only narrows the window |
| Edit Role returns 405 between the API and UI deploys | Admins can't rename for a short time | D4: merge back to back and promote together; no data risk |
| A hidden SDR PUT caller | That caller gets 405 | 0 hits across three repos, each with a control; a 405 fails loudly |
| A DIVE that isn't a duplicate gets mislabelled | The admin sees a false "already exists" | Map only SQLSTATE 23505 (AC-6b); lengths are validated first |
| The pin inversion is too broad | UserGroup PUT is withdrawn and group editing breaks | AC-1 and AC-1b keep UserGroup PUT as an asserted control |
| A future name-keyed seed | Same class of attack | AC-9 rail; F-1 for groups |

## 9. Completeness checklist
| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1: 8 tenants plus a positive control; V2.2.34 not yet applied on dev |
| 1 | All callsites enumerated | ✓ analysis §0 A1–A13. The Fix D stale regions are what instruments I-1 and I-2 found (with positive controls), not a closed list |
| 2 | Adjacent bugs | ✓ A11 UserGroup → F-1; A12 other scalar fields → covered by Fix A |
| 3 | Backward compatibility | ✓ breaking change: item PUT is removed; its only consumer moves (Fix C); D4 covers the deploy gap |
| 4 | Concurrency | ✓ race → 422 only on 23505 (AC-6b); overlapping edits → OOLFE → 409; sequential edits → last write wins |
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
- **D7 (added from the final security review, 2026-09-27):** role names also refuse invisible Unicode FORMAT characters (category Cf: zero-width, bidi overrides, BOM, tag characters), because they let a name *display* as another role's.
  - Cost: a name that legitimately needs one, such as an emoji ZWJ sequence or Persian ZWNJ, is refused with the same "control characters" 422.
  - Measured exposure: 0 of 309 existing role names on 5 tenants contain any non-ASCII character. The check had a positive control: the same pattern matches a zero-width sample.
  - No ZWJ allowance, because U+200D is itself a spoofing vector.
  - Nam can loosen this later.
- **R2 (round-2 plan choices, open to override):**
  - UserRole stays out of `SDR_WRITE_WITHDRAWN` (Architect M-1 option a).
  - AC-9 rail added under this ticket as a sub-T3 addition.
  - Names are not trimmed.
- **F-1 (proposed T3, not filed):** `UserGroup` item PUT has the same shape (`forDomainType(UserGroup.class)…disable(HttpMethod.PATCH, HttpMethod.DELETE)`). It is latent: nothing grants by `mywms_group.name`, and `UserService#isSuperAdmin` (a group lookup by name) has no callers. Also, `mywms_group` has **no** unique index on name, so a rename can create a duplicate outright. Blast radius: every `wms_user`, once a group-name seed exists (AC-9's `g.name` pattern already watches for that). Cost: the same shape as this ticket.
- **F-2 (proposed, SBDEV-3381 scope):** V2.2.34 **cannot** be edited: it is merged and applying it again would break the checksum. The options are an ops check (§5.1 #5, preferred) or, if a tenant is found compromised, a corrective migration that regrants by id. Nam decides.

## 11. Implementation Status

### TDD gate baseline (2026-09-27)
- **Worktrees.** Each on branch `bugfix/SBDEV-3545-userrole-sdr-rename`, off a freshly fetched `origin/develop`, with nothing committed:
  - `.claude/worktrees/wms2-api/SBDEV-3545` (at 286b5673)
  - `.claude/worktrees/wms2-web-ui/SBDEV-3545` (at b32a134)
- **wms2-api:** 62 run, **14 failures, 0 errors**. Reproduced independently by the main session. `src/main` untouched.
  - New:
    - `security/UserRoleSdrWriteContextTest`: AC-1 405 and re-read (currently fails with `but was: "super-admin-renamed"`), AC-2 (404≠200), AC-3 (404≠403), and 3 controls. The UserGroup PUT control is pinned to **200**.
    - `unit/service/UserRoleServiceUpdateContractUnitTest` and `unit/controller/UserRoleControllerUpdateContractUnitTest`: reflection contracts covering the signature, the `/update` mapping and the tenant transaction manager.
    - `unit/db/NameKeyedGrantSeedRailTest`: AC-9. It is a guard, so it passes by design; its 3 mutants and 2 controls were all killed.
  - Inverted: `AccessChainSdrWriteExposureUnitTest`, `SdrWriteWithdrawalContextTest`, `PutForCreationWithdrawalContextTest`, `MustStayWritableCollectionPostWithdrawalContextTest`, `UserAdminFunctionGateUnitTest`. The gate test adds the handler `updateRole/2` and an ungated control using `verifyNoInteractions`; putting `@RequiresFunction` on the control class kills it.
- **wms2-web-ui:** `test/store/adminRoleErrorHandling.spec.js`, 4 AC-7 cases. All fail today and all 46 pass with the one-line Fix C, which was applied only to check this and then reverted.
- **Deferred to the executor's first commit.** These can't compile until the signatures exist; paste them in with Fix B:
  - `UserRoleServiceUnitTest @Nested UpdateRole`:
    1. rename + description
    2. AC-4: number, connector, additionalcontent and entityLock unchanged
    3. AC-5: another role's name → 422 `"Role name 'taken' already exists"`, row unchanged
    4. AC-5: own name + new description persists
    5. AC-6: unknown id → `EntityNotFoundException`
    6. blank name → 422
    7. name > 255 → 422
    8. description > 255 → 422
    9. null description → `""`
    10. ordering via `InOrder` (`findById` → `findByName` → `setName`; no `setName` when validation fails)
  - `UserRoleControllerUnitTest @Nested UpdateRole`:
    1. forwards only id, name and description (`verify` + `verifyNoMoreInteractions`)
    2. response body is exactly 4 keys
    3. missing `roleId` → 422 with no service call
    4. 404 and 422 mapping
    5. DIVE 23505 → 422 "already exists"
    6. DIVE 22001 → not that message
  - `UserRoleServiceTransactionBoundaryTest`: `updateRole` rolls back on the tenant manager, and the landlord manager is never touched.

### Implementation (2026-09-27): merged, deployed and live-tested on dev
- **PRs:**
  - wms2-api [#427](https://github.com/SiteBossInc/wms2-api/pull/427): merge first.
  - wms2-web-ui [#147](https://github.com/SiteBossInc/wms2-web-ui/pull/147): merge straight after #427; promote the two together.
- **wms2-api commits** (branch `bugfix/SBDEV-3545-userrole-sdr-rename`, base 286b5673):
  - `04a411ec` the fix
  - `e603ce3b` review fixes
  - `d32cff1a` review round 2
  - `a16dcc65` round 3
  - `4fc63ae1` round 4
  - `b840d0d7` round-5 Lows
  - `2d2c5939` final pre-merge review fixes (FORMAT characters, the `/create` duplicate and race 422, the connector type)
  - `baa2e3f2` scoped-review Lows (check order, `codePoints` pin, the `/create` race IT)
  - `30ecc023` duplicate check before `connector` (scoped-review Medium). Reviewed at the tip: APPROVE
- **wms2-web-ui commits:** `257f8ad` (Fix C), `d6ecaaa` (Cypress note), `d86992d` (spec header written in past tense).
- **Tests:**
  - wms2-api surefire, clean build at the tip `30ecc023`: 7344 run, 0 failures, 0 errors, 1 skipped. Develop baseline: 7258 / 0 / 0 / 1. CI on the merge ref at `b840d0d7`: 7338 unit and 541 IT, 0 failures.
  - The race IT now covers both `/update` and `/create` against real Postgres. The measured cause chain is `DataIntegrityViolationException` caused by `PSQLException` 23505.
  - `UserRoleRenameUniqueRaceIntegrationTest` (Testcontainers) passes; its negative control fails correctly.
  - PIT on `UserRoleService` and `UserRoleController`: 0 survivors on the new code.
  - Jest: 1605 passed, plus the same 5 suite-load failures as develop b32a134.
- **Reviews:** conformance PASS; code review APPROVE; security PASS; plus a scoped review of every fix commit, 6 in all. **Corrected 2026-09-27: this line previously said "4 scoped fix rounds, 2 Medium and 18 Low", which was an undercount written before rounds 3–5.** The recount from the lane reports is **4 Medium and 31 Low**. All 4 Mediums are fixed. 30 Lows are fixed; the other one (UserController logs raw request maps at DEBUG) predates this ticket and is already tracked separately. A final pre-merge pass added a whole-diff security review (PASS) and a conformance re-check at the tip (PASS).
- **Scope added from review, all sub-T3 on this ticket:**
  - `/create` shares the name and description rules, messages and check order with `/update`.
  - One shared id parser, `RequestBodyIds.requiredId`, used by the UserRole, UserGroup and User controllers. It rejects `7.9` and out-of-range ids.
  - Log hygiene.
  - `ProductionOpenInViewDisabledUnitTest`.
  - `NameKeyedGrantSeedRailTest`, which walks subdirectories and is case-insensitive.
- **Landmines the plan did not predict:**
  1. **SDR merges the PUT body before returning 405.** A refused PUT *persists* under an outer test transaction (and would under OSIV). Production is safe only because `open-in-view=false`, which is now pinned.
  2. **The pre-fix status for `POST /update` is 404, not 405.**
  3. **Hand mutants restored with preserved mtimes left stale bytecode.** The next full run showed 7 false reds; `mvn clean test` cleared them. Recorded in memory `mutation-harness-traps`.
- **Known residuals:**
  - Hibernate `SqlExceptionHelper` logs a colliding name at ERROR. It is already validated, so it can't forge a log line.
  - The gated endpoints accept seed role names. This is accepted residual: gate holders can already grant any function.
- **Follow-ups (proposed, not filed):**
  - F-1: UserGroup item PUT.
  - F-2: SBDEV-3381 V2.2.34 per-tenant check.
- **Not done by design:** merge, `on dev`, archive, worktree removal, deploy.
- **Merged 2026-09-27.** wms2-api #427 as `85b8afcf`; dev reported `develop-85b8afcf` with `drift:false`. wms2-web-ui #147 as `14c70f27`, merged straight after the API was confirmed live (D4). ClickUp is at `on dev`.
- **Live test on dev as `panderson`** (tenant wineco/wsl, dev_wh01_om1; panderson holds `WEB_UI_VIEW_USER_MANAGEMENT`), using throwaway roles only:
  - API: 23/23 passed (AC-1 through AC-6, including the `/create` fixes).
  - UI in headless Chrome: 11/11 passed. Edit Role sends exactly one `POST /userRole/update {roleId,name,description}` and no PUT; the duplicate-name toast shows the server's reason.
  - The DB was clean afterwards, and the seed roles were untouched.
  - The 403 path wasn't live-tested, because panderson holds the function. It is covered by the context test and CI.
  - Scripts: session scratchpad `live3545.py` and `ui/ui3545.js`.
- **Observation, predates this ticket:** `editRole.vue` `save()` closes the dialog even when the save is refused.

