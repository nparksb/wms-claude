---
title: "WMSv2: deleting a role destroys its entire function grant set and then fails with a bare 500 — `deletRole` clears only one of the three tables that reference `mywms_role`, and the deletes are not transactional"
ticket: "SBDEV-3011"
ticket_url: "https://app.clickup.com/t/868kua92j"
type: "bugfix"
priority: "high"
status: "on dev 2026-08-21 — wms2-api PR #173 MERGED into develop as 7d0fd13; DEV redeployed healthy. Combined-state suite with PR #180: 5371 run, 2 failures (both pre-existing on develop). Verify 48 pass / 1 fail — row S1 red only because its 60aef02 baseline expired; per-file git log confirms #173 touched neither UserGroupController nor UserController. Staleness check over 19 intervening commits: SBDEV-3013 gating intact (@RequiresFunction on UserRoleController:39, still in GUARDED). NOT verified behaviourally on DEV — the role-delete check is destructive and was not run; verified by suite + compile + deploy. Prior: pr submitted 2026-08-20; commits 96ad273 + 6e75c8a + 982df3b; 4 review lanes clean."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-20
updated: 2026-08-21
db_verified: true
related:
  - SBDEV-3005-role-function-composite-key-swap.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
  - ../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
tags:
  - plan
---

# WMSv2: deleting a role destroys its entire function grant set and then fails with a bare 500

**Ticket:** [SBDEV-3011](https://app.clickup.com/t/868kua92j)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** reviewed 2026-08-20 — consensus iteration 2 (Architect + Critic); ready for TDD gate
**Date:** 2026-08-20

**Base:** `develop` @ `60aef02` (the merge of [wms2-api PR #170](https://github.com/SiteBossInc/wms2-api/pull/170), branch commit `f4e78c5`) — i.e. SBDEV-3005 is already in. This ticket is the item that plan's §0 row 15 and §12.2 deferred by name, and §14 row 2 filed.

---

## 0. Affected sites (enumeration before drafting)

Enumerated from the schema outward, not from memory: every FK referencing `mywms_role` was read out of `pg_constraint` on `wms2-hydra-uat` (§1 Query 1, 3 rows, complete), and every one of those three tables was then traced to its writer, its mapping, and its repository.

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `controller/UserRoleController.java:89-93` | `deletRole` clears only `mywms_role_mywms_function`; it never checks or clears `mywms_group_mywms_role` or `mywms_user_mywms_role`, both of which also FK to `mywms_role(id)` | **yes — the reported defect** | **yes — Fix A** |
| 2 | `controller/UserRoleController.java:85-96` | the whole method is non-transactional (`grep -c Transactional` in `UserRoleController` = 0, in its base `AdminController` = 0), so each `SimpleJpaRepository.delete()` commits alone and the function rows are durably gone before `deleteById` throws | **yes — this is what makes #1 destructive rather than merely broken** | **yes — Fix B** |
| 3 | `model/UserGroup.java:22-28` | `UserGroup.roles` is a second `@ManyToMany(fetch = EAGER, cascade = PERSIST)` `@JoinTable` over `mywms_group_mywms_role` — the double-mapping hazard SBDEV-3005 §5 Fix D documented, here over a table this fix reads | hazard, not a defect | **yes — it constrains the Fix A/B design** |
| 4 | `model/UserRole.java:27-33` | `UserRole.functions` is a second `@ManyToMany(EAGER)` `@JoinTable` over `mywms_role_mywms_function`, and `UserRole` is its **owning** side (`UserFunction` declares no inverse — `model/UserFunction.java:1-40`) | hazard, not a defect | **yes — it forces Fix C; see §4.2** |
| 5 | `repo/jpa/UserUserRoleRepository.java:9-10` | a bare `CrudRepository` with **no methods at all** — there is no finder by `rolesId`, so the user-side refusal check cannot be written without one | gap that blocks the fix | **yes — Fix A needs it** |
| 6 | `repo/jpa/UserRoleRepository.java:12-13` | `@RepositoryRestResource(path = "userRole")` + `CrudRepository` + `RestConfiguration:32` basePath `/v3` + `RestConfiguration:47` detection strategy `ANNOTATED` → Spring Data REST exposes a **parallel `DELETE /v3/userRole/{id}`** that no controller or service fix can reach. SDR is provably live on this exact path: the web UI calls `/userRole/search/findByConnectorFalse` and `/userRole/search/findByName` (`store/admin/role.js:30,125`) | **same defect, different route** | **yes — Fix D. Verdict and residual risk in §4.4** |
| 7 | `controller/UserGroupController.java:80-96` | `delete/{groupId}` — the same non-atomic multi-delete, zero `@Transactional`. Its **cascade is complete** though: the FKs referencing `mywms_group` are exactly `mywms_group_mywms_role` + `mywms_group_mywms_user`, and both are deleted | atomicity only, not the FK defect | **no — OWNED as of 2026-08-20: [SBDEV-3012](https://app.clickup.com/t/868kua93r) was WIDENED to cover it** (`UserGroupController.java:80-96`) after this plan's review found it fell between two tickets. Iteration 1 wrongly claimed it was "excluded with named owners": 3012's original scope was `saveGroupRoles` / `saveUserGroups`, i.e. the *save* methods only, and SBDEV-3005 §12.2 deferred `saveGroupRoles:99-117`, not `delete/{groupId}`. §12.5 |
| 8 | `controller/UserController.java:281-306` | `delet/{userId}` — deletes only group memberships. Misses `mywms_user_mywms_role` **and nine operational FKs** on `mywms_user(id)`: `billoflading`, `billoflading_position`, `cyclecount_position`, `goodsreceipt`, `goodsreceiptposition`, `message`, `pickingorder`, `pickingorder_position`, `replenishorder` (all `operator_id`). Deleting any user who ever did work fails — and it **cannot** be fixed by cascading, because an operator's history must not be destroyed. Needs a soft-delete / deactivate design | same class of bug, materially larger design question | **no — FILED as [SBDEV-3021](https://app.clickup.com/t/868kug16p)** (`high`), scoped to the soft-delete design only; atomicity + the HTTP-200 contract went into the widened SBDEV-3012, and SBDEV-2984 already owned the authorization gap. §12.4 |
| 9 | `test/.../unit/controller/UserRoleControllerUnitTest.java:110-153` (`@Nested class DeletRole`) | `deletesRoleAndFunctions` and `deletesRoleWithNoFunctions` **pin the current buggy behaviour** — they assert the controller owns the delete loop and that the call returns 200 | the tests encode the bug | **yes — both must be rewritten, not merely added to; §7.4** |

Rows 3, 4, 5 and 9 are in scope but are not *fixes*: they are the reason the fix has the shape it has. Rows 7 and 8 are the same family and are excluded with a **specified disposition** rather than waved off. Iteration 1 claimed both were "excluded with named owners", which was wrong for row 7 excluded and now genuinely owned — [SBDEV-3012](https://app.clickup.com/t/868kua93r) **widened** to cover it (§12.5);
```

Result — 3 rows, complete:

| conname | referencing_table | def |
|---|---|---|
| `fk2k1nyn576adktb9r318x6x90` | `mywms_group_mywms_role` | FOREIGN KEY (`rolelist_id`) REFERENCES `mywms_role(id)` |
| `fkby47oyt3v45jq6sysqya4til9` | `mywms_role_mywms_function` | FOREIGN KEY (`rolelist_id`) REFERENCES `mywms_role(id)` |
| `fkiyrof2dr48h37rnp0owmwguuk` | `mywms_user_mywms_role` | FOREIGN KEY (`roles_id`) REFERENCES `mywms_role(id)` |

Only `mywms_role_mywms_function` is cleared by the current code. The other two are not.

#### Query 2 — the triggering data condition

```sql
SELECT (SELECT count(*) FROM mywms_role) AS roles_total,
       (SELECT count(DISTINCT rolelist_id) FROM mywms_group_mywms_role) AS roles_held_by_group,
       (SELECT count(DISTINCT roles_id) FROM mywms_user_mywms_role) AS roles_held_by_user,
       (SELECT count(*) FROM mywms_user_mywms_role) AS user_role_rows,
       (SELECT count(*) FROM mywms_group_mywms_role) AS group_role_rows,
       (SELECT count(*) FROM mywms_role r
          WHERE NOT EXISTS (SELECT 1 FROM mywms_group_mywms_role g WHERE g.rolelist_id = r.id)
            AND NOT EXISTS (SELECT 1 FROM mywms_user_mywms_role u WHERE u.roles_id = r.id)) AS roles_deletable_today;
```

Result:

```
roles_total = 14   roles_held_by_group = 14   roles_held_by_user = 0
user_role_rows = 0   group_role_rows = 34   roles_deletable_today = 0
```

**`roles_deletable_today = 0` is the headline finding.** All 14 of 14 roles are held by at least one group. This endpoint is not "broken for assigned roles" — on this tenant it is broken for **every role that exists**, and each attempt destroys grants before it fails. There is no path through this endpoint today that both succeeds and is reachable.

`mywms_user_mywms_role` is **empty** (0 rows). The live authorization chain is user → group → role → function (`repo/jpa/UserRepository.java:26-34`, `getAllRoles`), so the user→role table is a vestigial path. The FK is real, however, and one stale row would block a delete — so the refusal check must still cover it. This also means the user-side branch of this fix has **no production data to exercise it on any known tenant**, which §7.4 accounts for.

#### Query 3 — blast radius per role: function rows destroyed before the 500

| role id | name | function rows destroyed | groups holding |
|---|---|---|---|
| 50356 | `super-admin` | **77** | **16** |
| 50353 | `outbound-manager` | 23 | 1 |
| 50355 | `receiving` | 15 | 1 |
| 50350 | `inventory-manager` | 11 | 1 |
| 50354 | `outbound-worker` | 7 | 3 |
| 50351 | `inventory-worker` | 5 | 3 |
| 50352 | `outbound-forklift` | 3 | 2 |
| 50363 | `ROLE000014` | 1 | 1 |

One click of Delete on `super-admin` destroys **77 function rows affecting 16 groups**, returns 500, and leaves the role in place with zero permissions. That is silent privilege stripping presented to the operator as a generic failure — and on a platform where SBDEV-2967 / SBDEV-2968 are about to start *enforcing* those grants, it is a lockout waiting to happen.

### Reproduction

1. Any v2 tenant. Pick any role — on `wms2-hydra-uat` every one of the 14 qualifies.
2. `GET /v3/userRole/delete/{roleId}`.
3. → HTTP 500. Then `SELECT count(*) FROM mywms_role_mywms_function WHERE rolelist_id = <roleId>` → **0**, where before it was the count in Query 3.

---

## 2. Root Cause Analysis

`controller/UserRoleController.java:85-96`, verbatim:

```java
// Request json: { roleId }
@GetMapping(path= "/delete/{roleId}", produces = "application/json")
public ResponseEntity<Object> deletRole(@PathVariable("roleId") Long roleId, @AuthenticationPrincipal Principal principal) throws WebserviceBusinessExceptionClientSide {
    LOG.info("delete role with Id {}", roleId);
    // delete the role from functions
    List<UserRoleUserFunction> roleFunctionList = userRoleUserFunctionRepository.findByRolelistId(roleId);
    roleFunctionList.forEach( roleFunction -> {
        userRoleUserFunctionRepository.delete(roleFunction);   // ← each call commits on its own
    });
    userRoleRepository.deleteById(roleId);                     // ← FK violation → bare 500
    LOG.info("Role with Id {} is deleted ", roleId);
    return ResponseEntity.ok(roleId + " DELETED");
}
```

### Bug 1: the FK cascade is incomplete — only 1 of 3 referencing tables is cleared

`findByRolelistId` / `delete` cover `mywms_role_mywms_function` and nothing else. `deleteById` then violates `fk2k1nyn576adktb9r318x6x90` (`mywms_group_mywms_role`) or, where a stale row exists, `fkiyrof2dr48h37rnp0owmwguuk` (`mywms_user_mywms_role`) → `DataIntegrityViolationException`.

Why it surfaces as an untyped 500: `RestExceptionHandler` handles `ApiInvalidParameterException`, `ApiConstraintViolationException`, `MethodArgumentNotValidException`, `ApiMissingUserException`, the **three** SSO types (`SsoCreateUserException:94`, `SsoGroupMembershipException:102`, `SsoException:110`), `BusinessException`, `PutawayConfigValidationException`, `NoSuchElementException`, `EntityNotFoundException`, `ObjectOptimisticLockingFailureException` and `PessimisticLockingFailureException` — **13** `@ExceptionHandler` methods in total (`:35-182`). `DataIntegrityViolationException` is **not** in that list, and neither is `EmptyResultDataAccessException` — which is the *other* 500 on this method, thrown by `SimpleJpaRepository.deleteById` when the id does not exist at all.

Note the log line at `:94`: `"Role with Id {} is deleted "` is on the success path, so it never prints. `:87` already reads `delete role with Id` — SBDEV-3005's Fix E corrected the copy-pasted `delete printer with Id` string here, so **there is no log-line defect left in this method**. The only log evidence of a failed delete is the framework's stack trace.

### Bug 2: the deletes are not atomic

`grep -c "Transactional"` is 0 in `UserRoleController.java` and 0 in `AdminController.java`. OSIV is disabled (`spring.jpa.open-in-view=false`). So each `SimpleJpaRepository.delete()` opens its own `REQUIRED` transaction and commits immediately, N times. By the time `deleteById` is reached and throws, the N function rows are **already durable**. Nothing rolls back, because there was never one transaction to roll back.

### Why the two compose into silent privilege stripping

Either bug alone would be tolerable:

- Bug 1 without Bug 2 would be a clean, harmless 500: the whole operation would roll back and the operator would retry or give up, having lost nothing. Annoying, not dangerous.
- Bug 2 without Bug 1 would almost never fire, because a complete cascade leaves nothing to fail on.

Together they make **a failed delete strictly worse than no delete at all.** The operation destroys the role's entire authorization payload, reports failure, and leaves every holding group pointing at a role that now grants nothing. Neither the operator nor the log says so. On `super-admin` that is 77 grants and 16 groups (§1 Query 3), and because `roles_deletable_today = 0`, *every* delete attempt on this tenant takes that path.

This is the identical shape SBDEV-3005 fixed on `saveRoleFunctions` — the same file, the same method family, the same non-atomic delete-then-write. It was deliberately deferred there, recorded at **SBDEV-3005 §0 row 15 → §12.2 → §14 row 2**, on the honest grounds that its FK defect is a *different* bug needing its own acceptance criteria. This plan is that ticket.

---

## 3. Architecture Overview

```
Web UI: components/admin/userManagement/roles/deleteRolePop.vue:44   deleteItem()
   │   await dispatch('admin/role/deleteRole', { roleId })  — then $emit('close') UNCONDITIONALLY
   ▼
store/admin/role.js:110-119   $get(`/userRole/delete/${roleId}`)
   │   catch → console.log(error); $toast.error('...network or server issue...')   ← body discarded (§12.3)
   ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ UserRoleController.deletRole                       (:85)  ← NO @Transactional │
│   ├─ LOG.info("delete role with Id {}")            (:87)                      │
│   ├─ findByRolelistId(roleId)                      (:89)  correct orientation │
│   ├─ delete(each) × N                              (:91)  ← Bug 2: N commits  │
│   └─ userRoleRepository.deleteById(roleId)         (:93)  ← Bug 1: FK ✗ 500   │
└───────────────────────────────────────────────────────────────────────────────┘
                                     │
         three FKs reference mywms_role(id) — the code clears ONE
                                     │
    ┌────────────────────────────┬────┴───────────────────────┬──────────────────────────┐
    ▼                            ▼                            ▼
mywms_role_mywms_function   mywms_group_mywms_role      mywms_user_mywms_role
  CLEARED (and committed)     NEVER TOUCHED → the FK       NEVER TOUCHED → the FK
  77 rows on super-admin      that actually fires          that would fire if non-empty
                              34 rows / 14 roles           0 rows today

Second, independent live route into the same defect (§0 row 6, §4.4):
┌───────────────────────────────────────────────────────────────────────────────┐
│ DELETE /v3/userRole/{id}   — Spring Data REST, from UserRoleRepository's       │
│   @RepositoryRestResource. Reaches SimpleJpaRepository.deleteById directly:    │
│   no refusal check, no controller, no service. Atomic (one repository call =   │
│   one transaction) so it destroys nothing — but it 500s on every held role and │
│   silently succeeds on an unheld one, bypassing every guard this plan adds.    │
└───────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Key files

| File | Lines | Role |
|------|-------|------|
| `controller/UserRoleController.java` | 85-96 | `deletRole` — Bugs 1 and 2. Becomes a thin adapter |
| `controller/UserRoleController.java` | 99-151 | `saveRoleFunctions` — the reference shape after SBDEV-3005: validate in the controller, delegate to a transactional service method. `:128-130` is the `existsById` precedent |
| `service/UserRoleService.java` | 114-167 | `replaceRoleFunctions` — **the pattern to mirror.** `:131` carries `@Transactional(value = "tenantTransactionManager", …)`; `:126-129` encodes the "do not load `UserRole` here" rule in javadoc |
| `service/UserRoleService.java` | 38-46 | constructor — takes 4 repositories today; Fix A adds `UserUserRoleRepository`, `UserGroupRepository`, `UserRepository` |
| `repo/jpa/UserRoleUserFunctionRepository.java` | 14-27 | Fix C adds `deleteByRoleId`, the bulk join-row delete (§4.2). `findByRolelistId` (`:21-23`) already exists and stays for `replaceRoleFunctions`, but `deleteRole` does **not** call it |
| `repo/jpa/UserGroupUserRoleRepository.java` | 21-23 | `findByRolelistId` — **exists, reuse it** |
| `repo/jpa/UserUserRoleRepository.java` | 9-10 | bare `CrudRepository`, no methods. Fix A adds `findByRolesId` |
| `repo/jpa/UserRoleRepository.java` | 12-19 | `@RepositoryRestResource(path="userRole")`. Fix C adds `deleteRoleById`; Fix D changes its base interface |
| `repo/jpa/BillofladingPositionRepository.java` | 105-109 | the nearest `@Modifying` bulk-delete precedent — and **the thing not to copy verbatim**: bare `@Transactional` (→ the `@Primary` landlord manager), `clearAutomatically = true`, and a `@RestResource(path=…, rel=…)` that publishes the route. §4.2 |
| `service/UserRoleService.java` | 106-112 | `removeGroupFromRole` — legitimately calls `userGroupUserRoleRepository.delete(...)` at `:109`. **This is why verify row `A4` must be method-scoped, not file-scoped** (§13.1) |
| `repo/cinterface/NoDeletePagingAndSortingRepository.java` | 8-29 | **the codebase's own idiom** for suppressing the SDR delete surface — `@Hidden @RestResource(exported = false)` over `deleteById`/`delete`/`deleteAll`. Currently extended by **zero** repositories. Fix D is its first use |
| `model/UserRole.java` | 27-33 | `functions` — owning `@ManyToMany(EAGER)` over the table Fix A clears. The reason Fix C exists |
| `model/UserGroup.java` | 22-28 | `roles` — second `@ManyToMany(EAGER)` over `mywms_group_mywms_role`. The reason the refusal check uses projections, not entities |
| `exceptions/RestExceptionHandler.java` | 35-40, 153-164 | `ApiInvalidParameterException` → 422; `EntityNotFoundException` → 404 with `LOG.warn`. Neither `DataIntegrityViolationException` nor `EmptyResultDataAccessException` is handled anywhere in this class |
| `exceptions/ApiException.java` | 6 | `extends Exception` — **`ApiInvalidParameterException` is a CHECKED exception.** This is load-bearing for Fix B; see §4.3 |
| `common/base/BaseControllerUnitTest.java` | 65-73 | `MockMvcBuilders.standaloneSetup` (`:66`), in the advice-registering `setupMockMvc(Object, Object...)` overload — no Spring context, therefore no transaction proxy and no visibility of the `/v3` class prefix (§7). (Iteration 1 cited `:49-56`; that range is the *no-advice* `setupMockMvc(Object)` overload) |
| `test/.../unit/repo/OnHandQueryContractUnitTest.java` | 1-38 | this codebase's **reflection-based repository-contract idiom**, written for exactly the SBDEV-2217 situation. Its javadoc also carries the "regression pins … PASS on the unfixed build by design" convention §13.1 adopts. Sibling: `unit/repo/AdviceRepositoryRestExportUnitTest.java` for the `exported = false` half |

---

## 4. Design / Proposed Fix

Guiding constraint, from the user decision recorded in §12.1: **refuse, do not cascade.** A role still held by any group or user is not deletable; the response names the holders so the administrator detaches them first.

The operation moves from the controller into `UserRoleService.deleteRole`, under the tenant transaction manager, exactly as `replaceRoleFunctions` did in SBDEV-3005.

### 4.1 The hard constraint that shapes everything below

**Never materialise a `UserRole` or a `UserGroup` entity inside this transaction.**

`UserRole.functions` (`model/UserRole.java:27-33`) and `UserGroup.roles` (`model/UserGroup.java:22-28`) are *second, independent* `@ManyToMany(fetch = EAGER)` mappings over two of the three tables this operation reads and writes. Hibernate treats a `@JoinTable` mapping and an `@EmbeddedId` entity over the same table as unrelated, so a collection action can contradict an entity-level write. SBDEV-3005 §5 Fix D established this rule and `UserRoleService.java:126-129` encodes it in javadoc for the sibling method.

**The EAGER chain is transitive, and that is what turns this from a rule to be trusted into a rule that cannot be broken without visible harm.** `UserGroup.roles` is EAGER to `UserRole`; `UserRole.functions` is EAGER to `UserFunction`. So loading 16 holders in order to name them would materialise 16 `UserGroup`s, **their** roles, and **every function grant of every one of those roles** — pulling the exact `mywms_role_mywms_function` rows this transaction is deleting into the persistence context as a managed collection owned by `UserRole`. That recreates §4.2's collision from the opposite direction, in the one code path whose only purpose is to build an error message. §11 asks reviewers to police this rule; stated with the chain, it polices itself.

Concretely, this rules out three innocent-looking constructions:

| Tempting | Why it is forbidden here |
|---|---|
| `userRoleRepository.findById(roleId)` for validation | loads `UserRole` → eagerly loads `functions` over `mywms_role_mywms_function` |
| `userGroupRepository.findAllById(holderIds)` to name the holders | loads `UserGroup` × N → each eagerly loads `roles` → **and each of those eagerly loads `functions`**, i.e. the very rows this transaction is deleting |
| `userRoleRepository.deleteById(roleId)` to delete the role | `SimpleJpaRepository.deleteById` is `findById(id).ifPresent(this::delete)` — it **loads the entity**. See §4.2 |

Permitted instead: `existsById` (never materialises), the `@EmbeddedId` join entities (`UserGroupUserRole`, `UserUserRole`, `UserRoleUserFunction` — none declares an association), scalar and interface projections, and bulk JPQL `DELETE` statements.

### 4.2 Neither delete goes through an entity — Fix C

Fix C is the decision that **both** of this operation's deletes are bulk JPQL: the join rows by `UserRoleUserFunctionRepository.deleteByRoleId`, the role by `UserRoleRepository.deleteRoleById`.

Iteration 1 of this plan used bulk JPQL for the role and a load-and-remove loop for the join rows. The Architect's review pointed out that this applies the plan's own principle to the row with no collection mapping and its opposite to the rows that have one, and it is corrected here. The correction is worth making because it **removes** the hazard below rather than routing around it.

#### The hazard, and why this shape cannot produce it

`SimpleJpaRepository.deleteById(id)` calls `findById(id)` and then `delete(entity)`. `findById` → `EntityManager.find()` → loads `UserRole` **and eagerly initialises `functions`**. `EntityManager.find()` does not auto-flush (Hibernate's autoflush is driven by query execution, not by entity or collection loaders), so any pending `EntityDeleteAction`s over the join table are still unflushed and the collection loads the **pre-delete** rows.

`delete(entity)` then schedules an `EntityDeleteAction` for the role *plus* a `CollectionRemoveAction` for `functions`, because `UserRole` is the **owning** side of that join table (`UserFunction` declares no inverse mapping — `model/UserFunction.java:1-40`). At flush, `ActionQueue.executeActions()` runs `CollectionRemoveAction` **before** `EntityDeleteAction`. So with an entity-level join-row loop in the same transaction:

1. `CollectionRemoveAction` issues `DELETE FROM mywms_role_mywms_function WHERE rolelist_id = ?` → removes all N rows.
2. Each of the N pending `EntityDeleteAction`s then issues `DELETE … WHERE rolelist_id = ? AND functionlist_id = ?` → **0 rows affected each.**

Hibernate's default delete `Expectation` verifies the affected row count and raises `StaleStateException` on zero for **all** entities, versioned or not — versioning changes the `WHERE` clause, not the expectation. `UserRoleUserFunction` is unversioned (it does not extend `AbstractBaseEntity`, which is where `@Version` lives — `model/AbstractBaseEntity.java:34`) and that does not exempt it. `RestExceptionHandler:166-173` would turn the result into a **409 telling the operator to retry a delete that is not retryable.**

Two qualifications, both corrections to iteration 1:

- **The label.** The mechanism is reasoned from Hibernate's execution model, not observed: the Testcontainers IT lane cannot boot (SBDEV-2217), so there is no lane in which to watch the emitted SQL. It stays **UNVERIFIED** — but the honest reading is that the mechanism makes a throw **likely**, not that it is a coin flip. Iteration 1's framing invited a reviewer to cut Fix C as machinery for a non-problem. Under the shape below the question stops mattering anyway: **no `EntityDeleteAction` over the join table is ever queued, so there is nothing for a `CollectionRemoveAction` to collide with.** The hazard cannot arise rather than being avoided. The analysis is retained as recorded reasoning because it is the reason `deleteById` stays forbidden (verify row `C2`).
- **The bundling argument.** Iteration 1 said "Fix B without Fix C would trade a known destructive 500 for an unknown one." That is wrong — with the transaction in place everything rolls back, so Fix B alone destroys nothing; it is *misleading*, not destructive, exactly as §11 row 1 says. The genuinely stronger argument, which iteration 1 omitted: with Fix A + Fix B and no Fix C, the collision fires on the **happy path**. An unheld role passes the refusal check, the join-row deletes are queued, `deleteById` loads the role and its EAGER `functions`, `CollectionRemoveAction` takes the rows first, and every queued `EntityDeleteAction` affects zero. Manual tests M3 and M4 break. That is why the role delete must not go through `deleteById` even now that the join rows are bulk-deleted.

#### The two bulk methods

```java
// repo/jpa/UserRoleUserFunctionRepository.java — NEW (Fix C)
/**
 * SBDEV-3011. Clears a role's function grants in ONE statement, materialising nothing.
 * The old controller code loaded N entities and called delete() on each: SimpleJpaRepository
 * .delete(T) is an em.find + em.contains/em.merge + em.remove, i.e. three persistence-context
 * operations to remove a two-column join row, N+1 transactions in total, and an EntityDeleteAction
 * queue that collides with UserRole.functions' CollectionRemoveAction if anything in the same
 * transaction ever loads the role. See the plan's §4.2.
 */
@RestResource(exported = false)
@Modifying(flushAutomatically = true)
@Query("DELETE FROM UserRoleUserFunction f WHERE f.id.rolelistId = :roleId")
int deleteByRoleId(@Param("roleId") Long roleId);
```

```java
// repo/jpa/UserRoleRepository.java — NEW (Fix C)
/**
 * SBDEV-3011. Deletes the role WITHOUT loading it. {@code deleteById} would call {@code findById},
 * which materialises {@code UserRole} and eagerly initialises {@code UserRole.functions} — a second
 * @ManyToMany mapping of the very table {@code deleteByRoleId} has just emptied. See §4.2.
 *
 * flushAutomatically = true is a NO-OP under the shape above, and is retained deliberately rather
 * than because it is required today. Nothing in deleteRole is ever queued: deleteByRoleId is itself
 * a bulk executeUpdate() that reaches the database at call time, existsById is a COUNT, and the two
 * finders are reads — so the statement ordering deleteByRoleId -> deleteRoleById follows from
 * program order on one connection in one transaction, NOT from any annotation. It is kept for two
 * narrower reasons: (a) if entity-level removal is ever reintroduced here, the flush is what stops
 * the reordering described in §4.2; (b) a future caller joining this transaction with pending
 * changes to these entities gets them flushed before the bulk statement rather than after.
 * clearAutomatically is deliberately ABSENT, and there is no @Transactional here on purpose.
 */
@RestResource(exported = false)
@Modifying(flushAutomatically = true)
@Query("DELETE FROM UserRole r WHERE r.id = :roleId")
int deleteRoleById(@Param("roleId") Long roleId);
```

The nearest precedent is `repo/jpa/BillofladingPositionRepository.java:105-109` — `@Modifying(clearAutomatically = true) @Transactional @RestResource(path = "deleteBolPositionById", rel = …) @Query("DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId")`. It is structurally identical and it is **the thing not to copy verbatim**, on three counts:

1. **`flushAutomatically = true` is a NO-OP here, retained deliberately — and iteration 2's first draft of this bullet was wrong.** `grep -rn "flushAutomatically" repo/jpa/` returns **zero** hits across all 24 `@Modifying` annotations in the package, so it *is* a deviation. But the reason first given for it — "the ordering `deleteByRoleId` → `deleteRoleById` must be enforced by flushing rather than assumed from call order" — **does not hold under the ADJ-1 shape, and both reviewers caught it independently.** The general Hibernate fact is true (a bulk SQM mutation does not trigger autoflush the way a selection query does); the applied consequence is unreachable, because after the join rows moved to a bulk delete **there is nothing pending to flush**. `deleteByRoleId` is itself an `executeUpdate()` that reaches the database at call time; `existsById` is a `COUNT`; the two finders are reads. The action queue is empty at every point in `deleteRole`, and the statement ordering follows from program order on one connection in one transaction. Keep the flag for the two narrow reasons in the javadoc — it costs nothing and it survives a future reintroduction of entity-level removal — but do **not** describe it as load-bearing, and note the symmetry: the very argument that rejects `clearAutomatically` below (a persistence-context side effect declared at repository level, invisible at every call site) applies to `flushAutomatically` too, which is why the honest local answer is that `OutboxMessageRepository:75-76`'s bare `@Modifying` would also be correct. `T9` pins `clearAutomatically() == false`, which is the assertion that carries real weight; its `flushAutomatically() == true` companion pins an intentional choice, not a guarantee.
2. **`clearAutomatically` is deliberately omitted — reversing iteration 1.** It is the majority local form (4 of the 7 bulk-delete precedents: `MessageRepository:41`, `BillofladingPositionRepository:105` and `:111`, `BillofladingRepository:75`; the other three — `RestIdempotencyRepository:64`, `:69` and `OutboxMessageRepository:75` — are bare `@Modifying`). The flag exists to evict entities a bulk statement made stale, and there are none here: Fix C's whole premise is that neither `UserRole` nor `UserRoleUserFunction` is ever materialised. What `em.clear()` *would* do is detach the **entire** persistence context and discard its pending changes. `deleteRole` is `PROPAGATION_REQUIRED`, so any future caller wrapping it in a larger tenant transaction would silently lose its own managed entities — a whole-persistence-context side effect declared at repository level, invisible at every call site and invisible to every mocked-repository unit test.
3. **No `@Transactional` on either method.** **Five** of the seven precedents carry one, and **three of those five are bare** (`BillofladingPositionRepository:106` and `:112`, `BillofladingRepository:76`) — a bare `@Transactional` resolves to the `@Primary` **landlord** manager, so it would move these deletes off the tenant datasource entirely. The other two (`RestIdempotencyRepository:65`, `:70`) are `@Transactional("tenantTransactionManager")`, which is *not* a trap — with default `REQUIRED` propagation they join the caller's transaction — but still redundant here, and they would let a future caller invoke the method outside any transaction without noticing. Simplest correct answer: no annotation, and let §4.3's `deleteRole` own the boundary. The bare-`@Transactional` precedents also carry `@RestResource(path = …, rel = …)` — i.e. they *publish* an ungated HAL bulk-delete route — which is the third thing not to copy; both new methods are `exported = false`, matching `MessageRepository:41-43`'s form and the stated reason in the comment at `MessageRepository:40` ("suppresses the HAL mass-delete endpoint to prevent unauthenticated bulk mutations" — note `:30` is the *mass-archive* comment above `archiveMessages`, a different method). Verify row `C4` is the negative guard on the `@Transactional` half.

`@Modifying` appears **24** times as a real annotation in `repo/jpa/` (a bare `grep -c` reports 25 — `RestIdempotencyRepository:33` is a `{@code @Modifying}` javadoc mention), across **seven** bulk `DELETE` methods in five files. Of those seven only **six** are JPQL: `MessageRepository:41` is `nativeQuery = true`, so a reader checking that citation for JPQL will not find it. The construct itself is unremarkable here; only these three deviations are. The closest existing shape is `OutboxMessageRepository:75-76` — bare `@Modifying`, no `clearAutomatically`, no `@Transactional` — which is exactly the new methods minus `flushAutomatically`, and which (per point 1) would also have been a defensible choice.

Both `int` returns are used. `deleteByRoleId`'s count is what the success log reports — an actual affected-row count rather than a pre-count. `deleteRoleById` returning 0 means the role vanished between the check and the delete (§9 row 8): logged at WARN, not turned into an error, because the caller's goal has been achieved either way.

**Rejected alternative — keep the load-and-remove loop for the join rows.** Reuse `findByRolelistId` (which exists and is already exercised) and call `delete` on each row, keeping `deleteRole` structurally parallel to `replaceRoleFunctions` so a reviewer who has just read SBDEV-3005 recognises the shape. That parallel is a genuine benefit and it is why iteration 1 preferred it. Rejected because `replaceRoleFunctions` needs entities — it computes a set difference — and `deleteRole` does not; because the loop is what makes the collision above reachable at all; and because `verify(userRoleUserFunctionRepository).deleteByRoleId(roleId)` is a **stronger** pin than `verify(…, times(N)).delete(any())`, so nothing is lost on the greppable/mockable axis AC-10 exists to protect.

**Rejected alternative — let the mapping do it.** Drop the join-table clearing entirely and call only `userRoleRepository.deleteById(roleId)`; Hibernate's `CollectionRemoveAction` clears `mywms_role_mywms_function` on its own — one mechanism, no collision, one line. Rejected because that behaviour would be **unverifiable in this repository**: the join rows would be removed by a Hibernate mapping rather than by a call, so no Mockito unit test could assert it and the broken IT lane offers no alternative. A correctness property no test can see is one a future refactor deletes for free. An explicit **bulk repository call is not this alternative** — it keeps the property greppable and mockable while getting the single-statement efficiency.

### 4.3 Fix A — refuse with 422, naming the holders

```java
// service/UserRoleService.java — NEW
/**
 * Deletes a role, refusing if any group or user still holds it.
 *
 * <p>Refuses rather than cascades: cascading would silently revoke permissions from every member
 * of every holding group — on wms2-hydra-uat that is 16 groups for {@code super-admin}. The
 * caller is told who the holders are so they can detach them first. See the plan's §12.1.
 *
 * <p>Do NOT add a {@code userRoleRepository.findById} or a {@code userGroupRepository.findAllById}
 * here: {@code UserRole.functions} and {@code UserGroup.roles} are second @ManyToMany(EAGER)
 * mappings over two of the three tables this method touches, and UserGroup.roles is itself EAGER
 * to UserRole.functions — so loading a holder loads the rows being deleted. See §4.1.
 */
@Transactional(value = "tenantTransactionManager",
               rollbackFor = ApiInvalidParameterException.class)
public void deleteRole(Long roleId) throws ApiInvalidParameterException {
    if (!userRoleRepository.existsById(roleId)) {
        throw new EntityNotFoundException("UserRole", roleId);          // → 404
    }

    // VERDICT comes from the id-level finders. Both are authoritative; neither depends on a name
    // being present. UserGroup.name and User.name are a separate concern — see below.
    List<UserGroupUserRole> holdingGroups = userGroupUserRoleRepository.findByRolelistId(roleId);
    List<UserUserRole>      holdingUsers  = userUserRoleRepository.findByRolesId(roleId);

    if (!holdingGroups.isEmpty() || !holdingUsers.isEmpty()) {
        // Logged BEFORE the message is built, so the operational signal does not depend on the
        // name lookup succeeding.
        LOG.warn("refusing to delete role {}: held by {} group(s) and {} user(s)",
                 roleId, holdingGroups.size(), holdingUsers.size());

        // MESSAGE ONLY, and only on the refusal path. The ids come from the verdict itself, so the
        // name lookup cannot widen or narrow the holder set.
        List<Long> groupIds = holdingGroups.stream().map(UserGroupUserRole::getGrouplistId).toList();
        List<Long> userIds  = holdingUsers.stream().map(UserUserRole::getUserId).toList();
        throw new ApiInvalidParameterException(
                describeHolders(roleId, groupIds, userIds,
                        groupIds.isEmpty() ? List.of() : userGroupRepository.findHolderNamesByIds(groupIds),
                        userIds.isEmpty()  ? List.of() : userRepository.findHolderNamesByIds(userIds)),
                "roleId");
    }

    int functionRows = userRoleUserFunctionRepository.deleteByRoleId(roleId);

    int deleted = userRoleRepository.deleteRoleById(roleId);
    if (deleted == 0) {
        LOG.warn("role {} was already gone when the delete ran (concurrent delete)", roleId);
    }
    LOG.info("deleted role {} and {} function grant(s)", roleId, functionRows);
}
```

Before, for contrast — the whole of `UserRoleController.java:85-96` collapses to:

```java
// Request json: { roleId }
@GetMapping(path= "/delete/{roleId}", produces = "application/json")
public ResponseEntity<Object> deletRole(@PathVariable("roleId") Long roleId,
                                       @AuthenticationPrincipal Principal principal)
        throws WebserviceBusinessExceptionClientSide, ApiInvalidParameterException {
    LOG.info("delete role with Id {}", roleId);
    userRoleService.deleteRole(roleId);
    LOG.info("Role with Id {} is deleted ", roleId);
    return ResponseEntity.ok(roleId + " DELETED");
}
```

The response body string `"<id> DELETED"` is preserved verbatim: the UI does nothing with it (`store/admin/role.js:113` only `console.log`s it), but changing it buys nothing and would break any script that greps for it.

#### Verdict and message are deliberately separated

The refusal verdict comes **only** from the two id-level finders. The names are looked up afterwards, only when refusing, and only to build the message. This is not fussiness — `UserGroup.name` is declared without `@NotNull` (`model/UserGroup.java:14`; `number` on the next line does carry one, so the omission is a real nullable column and not a project-wide absence of validation), so a name-driven check could return an empty or null-bearing list for a role that genuinely is held, and the endpoint would then destroy grants for a role it should have refused. **The verdict must not be able to depend on a display string.**

#### The name lookup — reshaped, and its fallback fixed

Iteration 1 had two defects here, both found in review:

- **The query re-derived the holder set from a second snapshot.** `SELECT g.name FROM UserGroup g, UserGroupUserRole gr WHERE gr.id.grouplistId = g.id AND gr.id.rolelistId = :roleId` is valid, safe, index-backed JPQL, and it does correctly avoid materialising `UserGroup` — the Architect confirmed all three. But it reads `mywms_group_mywms_role` a **second** time, and Postgres defaults to READ COMMITTED, so the verdict query and the name query take different snapshots and can legitimately disagree. That divergence was the *only* reason iteration 1 needed a length-mismatch fallback. The service already holds the holder ids, so it passes them: `WHERE g.id IN :ids`. This also fixes a layering problem — a `UserGroupRepository` method whose `FROM` clause spans `UserGroupUserRole` asks about a relationship the `UserGroup` aggregate does not own, whereas `WHERE g.id IN :ids` is unambiguously a single-entity query.
- **The fallback guarded length where the hazard is nullness.** Iteration 1 said `describeHolders` "falls back to raw ids whenever the name list comes back shorter than the holder list". `SELECT g.name` on a group with `name IS NULL` returns a **null element**, not a shorter list, so a length-equal null-bearing list passed the guard and the 422 would render `held by group: null` — in exactly the case nullable `name` was invoked to justify. Worse, `ORDER BY g.name` puts nulls last in Postgres, so a null element is not positionally correlated with any particular holder and a `List<String>` cannot be repaired per element at all.

Both are fixed by returning **(id, name) pairs** through an interface projection — the local idiom, 53 of them already in `repo/projection/` (e.g. `UserDetailView`). This is a small step beyond the letter of either review finding, and it is the step that makes a *per-element* id fallback expressible rather than approximate:

```java
// repo/projection/RoleHolderNameView.java — NEW
public interface RoleHolderNameView {
    Long getId();
    String getName();
}
```

```java
// UserGroupRepository — names for the message. A tuple projection materialises no UserGroup,
// so UserGroup.roles (and transitively UserRole.functions) is never fetched. §4.1.
@RestResource(exported = false)
@Query("SELECT g.id AS id, g.name AS name FROM UserGroup g WHERE g.id IN :ids ORDER BY g.name")
List<RoleHolderNameView> findHolderNamesByIds(@Param("ids") List<Long> ids);

// UserRepository — same shape for the user side
@RestResource(exported = false)
@Query("SELECT u.id AS id, u.name AS name FROM User u WHERE u.id IN :ids ORDER BY u.name")
List<RoleHolderNameView> findHolderNamesByIds(@Param("ids") List<Long> ids);

// UserUserRoleRepository — the finder the refusal check needs
@RestResource(exported = false)
@Query("SELECT u FROM UserUserRole u WHERE u.id.rolesId = :rolesId")
List<UserUserRole> findByRolesId(@Param("rolesId") Long rolesId);
```

Both verdict finders are index-backed or harmless: `mywms_group_mywms_role` carries `UNIQUE (grouplist_id, rolelist_id)` plus a `rolelist_id` btree, and `mywms_user_mywms_role` has 0 rows (§9 row 8).

`UserGroupUserRoleRepository.findByRolelistId` (`:21-23`) **already exists and is reused unchanged.** `UserRoleUserFunctionRepository.findByRolelistId` (`:21-23`) also stays, but `deleteRole` no longer calls it — the bulk `deleteByRoleId` replaces it (§4.2). Do not add duplicates of either.

#### `describeHolders` — specified, not left to the implementer

Iteration 1 left this to prose, which made AC-3 unfalsifiable and manual test M2's expected result ("16 of them, or a truncated list — check readability") impossible to fail. Specified:

```
Role 50356 cannot be deleted: it is still held by 16 group(s) and 0 user(s). Detach it first.
Groups: admin, inbound-leads, night-shift, ops-managers, receiving-team (and 11 more). Users: none.
```

| Rule | Value |
|---|---|
| Entries listed per holder kind | at most **`HOLDER_NAMES_IN_MESSAGE = 5`** — the cap counts *rendered entries*, whether a resolved name or an `id <n>` fallback, so the message length is bounded regardless of how many holders are unnameable |
| Suffix when truncated | `" (and %d more)"` with the remaining count |
| When a kind has no holders | the literal `none` |
| Per-element id fallback | for each holder id, if the projection returned **no row** for it (concurrent delete) **or** its `getName()` is `null` or blank, render `id <holderId>` in place of the name |
| Ordering of the fallback entries | after the resolved names, ascending by id, so the message is deterministic and testable |
| Total length | bounded by 5 entries per kind plus the two `(and N more)` suffixes. No unbounded interpolation of a 16- or 80-element list into an exception message |

The cap exists for the `super-admin` case: 16 group names in a toast is not a message, and the fix for "the operator cannot see which groups hold this role" is the follow-up role-screen view (ADR follow-up 3), not a longer string.

#### The unknown-`roleId` contract — decided

Today `deleteById` on a missing id throws `EmptyResultDataAccessException`, which `RestExceptionHandler` does not handle → bare 500. **Decision: 404, via the unchecked `EntityNotFoundException`.**

| Option | Verdict |
|---|---|
| **404 `EntityNotFoundException`** — chosen | "Not found" is the accurate semantic for an id that identifies no resource. The type is already handled (`RestExceptionHandler:153-164`) with a `ProblemDetail` and a `LOG.warn`, and it is **unchecked**, so it rolls back by default and cannot fall into §4.4's trap. Consistent with `UserRoleService.getUserRoleDetails:170`, which already throws exactly this for exactly this reason |
| 422 `ApiInvalidParameterException`, per the `saveRoleFunctions:128-130` precedent | Rejected. That precedent is sound *there* because `roleId` arrives as a body field being validated, and 422 is the right code for an invalid field; reporting a missing resource as a malformed parameter loses that distinction. (Iteration 1 argued this as "path variable, not body field" and then refused *held* roles with `ApiInvalidParameterException(msg, "roleId")` on the same path variable — an argument that undercut itself, so it is dropped. The decision is unchanged; only the reasoning is) |
| Leave the 500 | Rejected: it is one of the two bare 500s this ticket exists to remove |

On the refusal side, `ApiInvalidParameterException(message, "roleId")` is retained: 422 is the right code for "the request is well-formed but the referenced resource is in a state that forbids this operation", and `fieldName = "roleId"` is what makes the refusal machine-distinguishable from the 404 for a client that grows past the current generic toast.

Note the `existsById` placement diverges from the precedent §3.1 cites: `saveRoleFunctions:128-130` deliberately puts the check in the **controller**. The divergence is intentional — a check that guards a write belongs inside the transaction that performs the write, and `EntityNotFoundException`/404 is a resource semantic the service should own. It is stated here so a reviewer does not read it as drift. (`existsById` does **not** materialise the entity: `SimpleJpaRepository` issues `select 1 from UserRole x where x.id = ?` for a simple id attribute.)

Both refusal and not-found are behaviour changes from a 500. §11 records them.

#### New repository surface

| Repository | Method | Why |
|---|---|---|
| `UserUserRoleRepository` | `List<UserUserRole> findByRolesId(Long)` | **required** — §0 row 5, the repository has no methods at all. The component is `rolesId` on the `UserUserRoleId` **record** (`model/UserUserRoleId.java:13-14`), column `roles_id` — **not** `rolelistId`/`rolelist_id` like its three siblings |
| `UserGroupRepository` | `List<RoleHolderNameView> findHolderNamesByIds(List<Long>)` | id+name tuple projection, so no `UserGroup` entity and no EAGER chain. `IN :ids` from the verdict, not a re-derived holder set |
| `UserRepository` | `List<RoleHolderNameView> findHolderNamesByIds(List<Long>)` | same, for the user side |
| `UserRoleUserFunctionRepository` | `int deleteByRoleId(Long)` | Fix C, §4.2 — replaces the find-then-loop |
| `UserRoleRepository` | `int deleteRoleById(Long)` | Fix C, §4.2 |

All five carry `@RestResource(exported = false)`: the ungated HAL surface must not grow by one row as a side effect of this fix (§4.5, and the standing finding `wms2-only-one-of-80-functions-is-enforced`).

**These five methods have no execution lane in this repository, and that is a real risk with a real mitigation.** `@Query` text is checked at Spring Data repository-factory initialisation, i.e. at **application startup** — not at compile time, and not by any test that runs here: every context-load lane (`smoke/OmsNotificationConfigContextLoadTest`, `smoke/PutawayResolverContextLoadTest`, `smoke/ReplenishReassignContextLoadTest`) extends the `@SpringBootTest` harness blocked by SBDEV-2217, and two of them say so in their own javadoc. So a malformed JPQL string or a mistyped `@Param` would ship and fail at **whole-application startup**, on a branch that auto-deploys to DEV. Iteration 1's §10 row 6 claimed these queries were "validated at context load"; that was wrong, and §6.2 step 6 told the implementer to run exactly that blocked test. Both are corrected. The mitigation is two-part and both parts are required: a reflection-based repository-contract test on the model of `unit/repo/OnHandQueryContractUnitTest` (§7.3), which pins the `@Query` text, `exported = false` and `@Modifying(flushAutomatically = true)` as real JUnit assertions in CI; and **blocking** manual row M10 — boot the application against a real tenant before merge.

### 4.4 Fix B — the transaction, and the checked-exception trap

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = ApiInvalidParameterException.class)
```

Three things about this annotation, each of which fails silently if got wrong:

1. **`value = "tenantTransactionManager"` is mandatory.** `landlordTransactionManager` is `@Primary`, so a bare `@Transactional` would open the transaction against the landlord database while the writes go to the tenant one. Project `CLAUDE.md`, Dual Transaction Manager.
2. **`rollbackFor = ApiInvalidParameterException.class` is load-bearing, not decoration.** `ApiInvalidParameterException extends ApiException extends Exception` (`exceptions/ApiException.java:6`) — a **checked** exception. Spring's default rule rolls back only on `RuntimeException` and `Error`, so **without this entry Spring would COMMIT the transaction on every refusal.** It happens to be harmless today because the refusal throws before any write — which is exactly the kind of "harmless because of statement order" that a later edit turns into data loss. It lists **one** type, not three: iteration 1 listed `BusinessException` and `FacadeException` alongside it on a method that throws neither, reproducing the dead configuration this section criticises in `replaceRoleFunctions:131` two sentences later. Verify row `B2` now asserts one **live** entry rather than one live and two dead.
3. `propagation` stays `REQUIRED` and `readOnly` stays `false`. A mutant of `NOT_SUPPORTED, readOnly = true` was **measured 100% green** across the whole SBDEV-3005 suite while being strictly worse than the unfixed code. Only `transactionDefinitionIsAWritableRequiredTransaction` catches it (§7.3).

Do **not** put `@Transactional` on `AdminController`: it is the base class of 43 controllers, and annotating it would open a tenant transaction around every endpoint in the application. Equally, do not put one on the two new `@Modifying` methods (§4.2, point 3).

### 4.5 Fix D — the parallel Spring Data REST route: verdict on §0 row 6

**Verdict: IN SCOPE for the item resource. Close it.**

`UserRoleRepository` is `@RepositoryRestResource(collectionResourceRel = "userRole", path = "userRole")` over `PagingAndSortingRepository` + `CrudRepository`, `RestConfiguration:32` sets the base path to `/v3`, and `:47` sets the detection strategy to `ANNOTATED` — so `DELETE /v3/userRole/{id}` is exported and reaches `SimpleJpaRepository.deleteById` with no controller, no service, and no refusal check. SDR is provably live on this path: the web UI's own role list is loaded from `/userRole/search/findByConnectorFalse` (`store/admin/role.js:30,41`) and `checkName` calls `/userRole/search/findByName` (`:125`) — both pure SDR routes on this repository.

What that route does today, precisely (it matters, and it is *not* the same as the controller's behaviour): one repository call is one transaction, `UserRole` owns `functions`, so Hibernate's `CollectionRemoveAction` clears `mywms_role_mywms_function` and then the entity delete hits the `mywms_group_mywms_role` FK — **and the whole thing rolls back.** So the SDR route destroys nothing. It returns a bare 500 for every held role, and silently succeeds for an unheld one, unlogged and ungated.

Why it is in scope rather than deferred:

- Without it, this plan's own headline acceptance criterion — *a role held by a group cannot be deleted* — is **false via a live route on the same URL prefix**. Shipping a guard whose bypass is one HTTP verb away is the shape of fix this plan family exists to reject.
- The fix is idiomatic and pre-built. `repo/cinterface/NoDeletePagingAndSortingRepository.java:8-29` already exists in this codebase for exactly this purpose, extends the same `PagingAndSortingRepository` + `CrudRepository` pair, and carries `@Hidden @RestResource(exported = false)` on `deleteById`, `delete`, `deleteAll(Iterable)` and `deleteAll()`. It is currently extended by **zero** repositories. Fix D is a one-line change to a supertype and its first use:

```java
// Before
public interface UserRoleRepository extends PagingAndSortingRepository<UserRole, Long>,
                                            CrudRepository<UserRole, Long> {
// After
public interface UserRoleRepository extends NoDeletePagingAndSortingRepository<UserRole, Long> {
```

- **No caller breaks, and the evidence is stronger than iteration 1 claimed.** On the **Java** side: `grep -rn "userRoleRepository\.\(delete\|deleteById\|deleteAll\)" src/` returns **exactly one** hit — `UserRoleController.java:93`, the line Fix A removes — and **zero** test references to any delete method. Fix D's Java blast radius is provably nil. On the **UI** side, iteration 1 stated that `grep -rn '\$delete' v2/wms2-web-ui/store` returns zero hits. **That was wrong: it returns 5** — `store/masterData/locationType.js:109`, `store/receiving/inboundNotices.js:187`, `store/masterData/storageLocation.js:73`, `store/masterData/packaging.js:89`, `store/admin/configuration.js:157`. None is on `/userRole/` (they are `/locationType/`, `/advice/`, `/location/`, `/boxtype/`, `/sysprop/`), so the no-caller-breaks conclusion holds — and the corrected reading **strengthens** Fix D rather than weakening it: it proves SDR item-resource `DELETE` routes are live and UI-consumed in this application, not merely exported. `grep -rn userRole` over the mobile UI's `store`/`components`/`pages` returns zero hits. Every web-UI call on this repository is enumerated: `store/admin/role.js` lines 30, 41, 56, 70, 85, 100, 112, 125, 139 — `$get`/`$put`/`$post` only — plus `store/admin/group.js:38-49`, which does `$get('/userGroup/' + groupId + '/roles')` (`:42`) and reads `results._embedded.userRole` (`:44`), i.e. a live, UI-consumed SDR **association** route that resolves `UserRole` through `UserRoleRepository`. The Java side keeps full access either way: `@RestResource(exported = false)` suppresses the HAL surface, not the method.

**Reconciling Fix D with §4.2's "no test can see it" principle.** §4.2 rejects let-the-mapping-do-it on the grounds that a correctness property no test can see is one a future refactor deletes for free, and §7.7 then concedes AC-11 has no automated coverage of any kind. The two are consistent, and the distinction is worth stating so the ADR does not read as self-contradictory: verify rows `D1`/`D2` statically pin the **construct** that produces the behaviour — the supertype and the absence of the old ones — whereas the rejected alternative's behaviour has no greppable construct at all, only the absence of one. A pinned construct survives a refactor because the refactor has to delete the pin; an implicit mapping behaviour does not.

Residual risk, stated plainly:

- **Fix D closes the item resource only.** `DELETE /v3/userRole/{id}` is gone. It does **not** close the SDR **association** resource `/v3/userRole/{id}/functions`. `UserRole.functions` is a `@ManyToMany` to `UserFunction`, and `UserFunctionRepository` is `@RepositoryRestResource(collectionResourceRel = "userFunction", path = "userFunction")` (`repo/jpa/UserFunctionRepository.java:13`), so Spring Data REST exports `GET`, `PUT`/`POST`/`PATCH` (`Content-Type: text/uri-list`) and `DELETE /v3/userRole/{id}/functions/{functionId}` on it. `@RestResource(exported = false)` on repository `delete*` methods does not touch `PropertyReferenceController`, and `NoDeletePagingAndSortingRepository` cannot reach it. This is not speculative — the symmetric route is provably live and UI-consumed (`store/admin/group.js:38-49`, above). So after this PR, `PUT /v3/userRole/50356/functions` with `text/uri-list` and an empty body still clears all 77 function grants on `super-admin`, ungated and unlogged. **Corrected 2026-08-20 after the security-review lane probed `spring-data-rest-core 4.5.7` directly — the verb list above was wrong in two ways:** `PUT` is the destructive verb (it is absent from `RepositoryPropertyReferenceController.AUGMENTING_METHODS`, so it replaces the collection wholesale); `PATCH`/`POST` are **additive only** and can grant functions but never remove them; and `DELETE` on the *collection* returns **405**, not a mass delete — only `DELETE /functions/{functionId}` works and it removes exactly one grant. SBDEV-3013 should be scoped off the corrected list, not the original. Also verified: leaving the item `PUT`/`PATCH` exported is safe, because `DomainObjectReader`'s `LinkedAssociationSkippingAssociationHandler` returns early for linkable associations and `UserFunction` has an exported repository — so a `PUT /v3/userRole/{id}` omitting `functions` does **not** null the grants. **It is owned:** [SBDEV-3013](https://app.clickup.com/t/868kua9b6) names this surface verbatim as its **surface #2** — `PUT/PATCH/DELETE /v3/userRole/{id}/functions`, "the association endpoint generated from `UserRole.functions` … on the `@RepositoryRestResource`-exported `UserRoleRepository`" — and `sbdocs/1-Projects/wms2/plan/SBDEV-2967-web-ui-function-gating-enforcement.md:731` records the same split independently ("Two Spring Data REST surfaces write the same table without passing through any controller — `POST /v3/userRoleUserFunction` and the `PUT /v3/userRole/{id}/functions` association endpoint … A guard added here closes one of three doors; SBDEV-3013 closes the other two"). It is **not** pulled into this plan, and the reason is **ownership, not cost**: SBDEV-3013 already owns this surface and has an open decision on how to close it — its own text proposes field-level `@RestResource(exported = false)` on `UserRole.functions` as the likely fix, with a `RepositoryRestConfigurer` exposure change (`config.getExposureConfiguration().forDomainType(UserRole.class).withAssociationExposure(…)`) named only as "an alternative worth weighing". Either way it is a published-API decision for that ticket, not a rider on this one.
- Fix D also does **not** close the three join-table repositories — `userGroupUserRole`, `userUserRole`, `userRoleUserFunction` are all `@RepositoryRestResource` with full CRUD, so a HAL caller can still detach every holder (making the role legitimately deletable) and can still delete function grants one by one. Same owner: SBDEV-3013.
- `NoDeletePagingAndSortingRepository` does not override `deleteAllById(Iterable)`. SDR exposes no bulk-delete endpoint for it, so the exported surface is fully covered; the gap is noted so nobody reads the interface as exhaustive.
- **Its being previously unused means it is also previously unexercised, and the failure mode is invisible to the build**: Spring Data's `DefaultCrudMethods` resolves the type-erased `deleteById(Object)` through the interface hierarchy, and SDR reads `@RestResource` off whichever declaration it lands on. Nothing in `mvn test` or `mvn clean compile` can catch that. **That is why manual row M7 is marked blocking** rather than being one of nine. Read endpoints are unaffected: the two `@RestResource` search methods are declared on `UserRoleRepository` itself and untouched, and `exposeIdsFor` is keyed on the entity class (`RestConfiguration.java:34-45`), not the repository, so a supertype swap cannot move it.
- Both this and the whole endpoint remain **ungated** — any authenticated user can call them. That is the standing platform finding (`wms2-only-one-of-80-functions-is-enforced`; SBDEV-2967 is the widener) and is out of scope here.

### 4.6 Observation only — `deletRole` is a destructive `@GetMapping`

`@GetMapping(path = "/delete/{roleId}")` performs a destructive write. That is CSRF-prone, unsafe against link prefetching and any intermediary that treats GET as idempotent, and it means a browser or proxy could delete a role by following a URL. **Do not change the verb in this ticket.** It is a UI-coupled contract change (`store/admin/role.js:112` uses `$get`), the user scoped this plan to the API repository, and the same shape exists on `UserGroupController:80` and `UserController:281`. Recorded as an observation for the follow-up in §12.4, and deliberately excluded from every acceptance criterion so nobody "fixes" it unreviewed.

---

## 5. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/UserRoleService.java` | modify | Add `deleteRole(Long)` — the refusal check plus the atomic delete, `@Transactional(value = "tenantTransactionManager", rollbackFor = ApiInvalidParameterException.class)` (**one** `rollbackFor` entry — §4.4). Add the `describeHolders` private helper and the `HOLDER_NAMES_IN_MESSAGE` constant (§4.3). Extend the constructor with `UserUserRoleRepository`, `UserGroupRepository`, `UserRepository` |
| `controller/UserRoleController.java` | modify | `deletRole` becomes a thin adapter: log, delegate, log, return. Declares `throws ApiInvalidParameterException`. Loses the `findByRolelistId`/`delete`/`deleteById` body |
| `repo/jpa/UserUserRoleRepository.java` | modify | Add `findByRolesId(Long)` — `@Query` on `u.id.rolesId`, `@RestResource(exported = false)` |
| `repo/jpa/UserRoleUserFunctionRepository.java` | modify | Add `deleteByRoleId(Long)` — `@Modifying(flushAutomatically = true)` (**no** `clearAutomatically`, **no** `@Transactional`), `@RestResource(exported = false)` (Fix C, §4.2) |
| `repo/jpa/UserRoleRepository.java` | modify | Change base interface to `NoDeletePagingAndSortingRepository<UserRole, Long>` (Fix D). Add `deleteRoleById(Long)` — `@Modifying(flushAutomatically = true)` (**no** `clearAutomatically`, **no** `@Transactional`), `@RestResource(exported = false)` (Fix C) |
| `repo/jpa/UserGroupRepository.java` | modify | Add `findHolderNamesByIds(List<Long>)` — `(id, name)` tuple projection over `WHERE g.id IN :ids`, `exported = false` (§4.3) |
| `repo/jpa/UserRepository.java` | modify | Add `findHolderNamesByIds(List<Long>)` — same shape for the user side, `exported = false` |
| `repo/projection/RoleHolderNameView.java` | **new** | `Long getId(); String getName();` — the interface projection that makes `describeHolders`' per-element id fallback expressible (§4.3). Joins 53 siblings in the same package |
| `test/.../unit/controller/UserRoleControllerUnitTest.java` | **rewrite** | Delete `deletesRoleAndFunctions` and `deletesRoleWithNoFunctions` (they pin the bug — §0 row 9). Replace with delegation + 422 + 404 surface tests |
| `test/.../unit/service/UserRoleServiceUnitTest.java` | modify | New `@Nested class DeleteRole` — refusal, no-write-on-refusal, no-entity-load, ordering, observability |
| `test/.../unit/service/UserRoleServiceTransactionBoundaryTest.java` | modify | New `deleteRole` lane on the existing Spring slice: rollback on failure, rollback on **refusal** (the checked-exception trap), and the `TransactionDefinition` capture. Three new `@Bean mock(...)` methods in `TxTestConfig` (`:79-115`), and `userRoleRepository` + `userGroupUserRoleRepository` added to `setUp:136`'s `reset(...)` list |
| `test/.../unit/repo/UserRoleQueryContractUnitTest.java` | **new** | Reflection-based repository contract for the five new methods — `@Query` text, `exported = false`, `flushAutomatically`/`clearAutomatically`, absence of `@Transactional`. **The only lane in this repository that can see them at all** (§4.5, AC-15). Modelled on `unit/repo/OnHandQueryContractUnitTest` |
| `sbdocs/9-System/scripts/verify-SBDEV-3011-delete-role-join-table-cascade.sh` | new | Acceptance script — §13.1 |
| `sbdocs/1-Projects/wms2/plan/SBDEV-3005-role-function-composite-key-swap.md` | modify | Back-link §12.2 / §14 row 2 to this plan |

No migration. No UI change. No configuration change. One new production file (`RoleHolderNameView`) and one new test file (`UserRoleQueryContractUnitTest`); everything else is a modification.

---

## 6. Prerequisites & Implementation Plan

### 6.1 Prerequisites

| # | Item | Status | Detail |
|---|------|--------|--------|
| P1 | **DB state / schema change** | **N/A** | No DDL. The three FKs already exist and are the mechanism being respected, not changed. §1 Query 1 |
| P2 | **Data migration / repair** | **N/A** | Nothing to repair *from this bug in isolation* — but see P3 |
| P3 | **Pre-existing damage audit** | **OPEN — must run before sign-off** | Every failed delete attempt already stripped a role's grants. One read-only query per tenant finds the victims: `SELECT r.id, r.name FROM mywms_role r WHERE NOT EXISTS (SELECT 1 FROM mywms_role_mywms_function f WHERE f.rolelist_id = r.id) AND EXISTS (SELECT 1 FROM mywms_group_mywms_role g WHERE g.rolelist_id = r.id);` — a non-connector role that is held by a group and has **zero** functions is either a victim or a never-configured role. Both need an operator's eyes; the fix cannot restore grants it has no record of. **Not a code prerequisite** — record the result, do not block the PR on the repair |
| P4 | **Feature flag / sysprop** | **N/A** | A pure correctness fix. Gating it would mean shipping a configuration in which deleting a role still destroys its grants. No new sysprop key, so `los_sysprop.description`'s `varchar(255)` trap is not in play |
| P5 | **Flyway version claim** | **N/A** | No `V2.2.x` claimed. Do not add one — version numbers in this area are contested between in-flight plans (SBDEV-3005 §7.1-P4) |
| P6 | **Config change** | **N/A** | No `application*.properties` / `.yml` edit. In particular `spring.jpa.open-in-view` stays `false`; Fix B supplies the boundary explicitly rather than leaning on OSIV |
| P7 | **Deploy order** | **N/A — API-only, no coordination needed** | The web UI already calls `/userRole/delete/{roleId}` and already treats any non-2xx as a generic failure (§12.3), so the API can ship alone in either order. Fix D removes an SDR route with zero callers in either UI (§4.5) |
| P8 | **External systems** | **N/A** | No OMS notification, no Keycloak call, no printer, no outbox message. `KeycloakService` is injected into the controller but `deletRole` does not use it, and this change does not add a use |
| P9 | **Access for the manual test** | **OPEN** | §7.5 needs a tenant plus an admin account, and at least one role that is **not** held by any group. On `wms2-hydra-uat` there are **zero** such roles (§1 Query 2), so the happy-path tests M3/M4 require creating a throwaway role first — a step, not an obstacle |
| P10 | **Monitoring / observability** | **DONE by design, no infrastructure needed** | The refusal is logged at WARN with holder counts and the success path logs the grant count (§4.3). No Micrometer counter: this is a low-frequency admin path and `RestExceptionHandler`'s existing `LOG.warn` covers the 404 (§10 row 8) |
| P11 | **Merge-order coordination** | **OPEN — raise with the SBDEV-3012 owner** | SBDEV-3012 covers `saveGroupRoles` (`UserGroupController:99-117`) and `saveUserGroups` (`UserController:310-334`) — the *save* methods of the same non-atomic family, in different files. It does **not** cover `UserGroupController.delete/{groupId}`; that gap is §12.5's follow-up, and the conversation with the 3012 owner is the natural place to ask whether to widen 3012 or file separately. No file overlap with this plan except that both will extend `UserRoleService`-adjacent services; whoever goes second rebases. Also relevant to SBDEV-2967 / SBDEV-2968, which turn on *enforcement* of the grants this endpoint destroys |

### 6.2 Implementation checklist

Each step is independently committable and leaves the tree compiling.

1. Confirm the TDD-gate tests exist and fail **for the intended reason** (§7) before touching production code. Capture the verify script's FAIL baseline (§13.1).
2. **Repository surface, one commit.** Add `repo/projection/RoleHolderNameView`, then `UserUserRoleRepository.findByRolesId`, `UserGroupRepository.findHolderNamesByIds`, `UserRepository.findHolderNamesByIds`, `UserRoleUserFunctionRepository.deleteByRoleId` and `UserRoleRepository.deleteRoleById`. All five methods carry `@RestResource(exported = false)`; the two `@Modifying` ones carry `flushAutomatically = true`, **no** `clearAutomatically` and **no** `@Transactional` (§4.2). Write `UserRoleQueryContractUnitTest` in the same commit — it is the only lane that can see any of this. Run `mvn clean compile`, but do not mistake it for validation: a malformed `@Query` fails at **application startup**, which step 6 cannot reach and only manual row M10 can (§4.5).
3. **Fix D, its own commit.** `UserRoleRepository extends NoDeletePagingAndSortingRepository<UserRole, Long>`. Small, isolated, and the one change whose blast radius is the HTTP surface rather than the code — keep it legible in the history.
4. **Fix A + B + C together, one commit.** `UserRoleService.deleteRole` with the transaction, the refusal, the projections and the bulk role delete; `UserRoleController.deletRole` reduced to delegation. These three cannot land separately: Fix B without Fix C creates the §4.2 collision, and Fix A without Fix B is a refusal that does not protect anything.
5. **Rewrite the two pinning tests** (§0 row 9). Delete, do not adapt — §7.4 explains why adapting them reproduces the bug in a new shape.
6. `mvn clean compile`, then the gate classes, then the full suite. Expect exactly the 2 known pre-existing `develop` failures and nothing new. **Revert the `archunit_store` mutation `mvn test` leaves in the working tree.** **Do NOT plan to run a context-load test here.** Iteration 1 of this plan told the implementer to run `OmsNotificationConfigContextLoadTest`; that test — and `PutawayResolverContextLoadTest` and `ReplenishReassignContextLoadTest` — extends the `@SpringBootTest` harness blocked by SBDEV-2217, and two of them say so in their own javadoc. There is **no** lane here that validates a `@Query`. `UserRoleQueryContractUnitTest` pins the query *text* in CI; only blocking manual row M10 proves the queries parse.
7. `bash sbdocs/9-System/scripts/verify-SBDEV-3011-delete-role-join-table-cascade.sh` → `0 fail`.
8. Manual tests §7.5, on a tenant. **M2 and M5 are the only end-to-end evidence for AC-2 and AC-6.**
9. Record P3, P9 and P11 in §13.3, together with the three blocking manual rows M7, M8 and M10. Verify rows `X1`, `X2` and `X4` FAIL until those lines exist, so this step is machine-enforced rather than a checklist promise (§13.1 constraint 11).

---

## 7. Test Plan

### 7.1 The constraints that shape this section

- **`standaloneSetup` sees no transaction proxy and no class-level prefix.** `BaseControllerUnitTest:65-73` builds MockMvc with `MockMvcBuilders.standaloneSetup(controller)` — no Spring context. A `@Transactional` annotation is entirely unexercised by controller unit tests, and the `/v3` prefix from `@RequestMapping("/v3/userRole")` is invisible, so **no controller test can prove the route exists.** Only a curl can (repo memory: `wms2-controller-mappings-must-carry-v3-standalonesetup-cannot-see-it`).
- **The IT lane cannot boot.** SBDEV-2217 — the Testcontainers Postgres lane does not start. Gate on unit tests plus `mvn clean compile`; leave any IT `@Disabled` and count it as a gap, not a pass.
- **`develop` has 2 pre-existing failures.** Any run reporting exactly those 2 is clean. A run reporting 0 is suspicious.
- **`mvn test` mutates the tracked `archunit_store`.** Revert it after every run.
- **`-Dtest='Outer#method'` silently no-ops for `@Nested` tests in this repo.** Every test below lives in a `@Nested` class. Target the **outer** class only.
- **No lane in this repository executes a repository query.** SBDEV-2217 blocks the Testcontainers harness, there is no `@DataJpaTest` anywhere in `src/test`, and every `smoke/*ContextLoadTest` extends the blocked `@SpringBootTest` harness. So the five new `@Query` strings are checked at **application startup** and nowhere else (§4.5). The response is the reflection-based contract test below plus blocking manual row M10 — not a claim of coverage the repository cannot deliver.
- **Assert on the right accessor.** This plan throws `ApiInvalidParameterException`, so assert `getMessage()` **and** `getFieldName()` / `getErrorObject()`. It deliberately does **not** use `BusinessException`, whose 1-arg constructor silently sets `key = "placeholder"` and whose `getMessage()` returns the key only while it is absent from the bundle — **if an implementer switches to `BusinessException`, the assertion must move to `getKey()`.** A verify row forbids the switch so this cannot drift silently.

### 7.2 Why the current tests are green on a permanently broken path

`UserRoleControllerUnitTest.java:110-153` exercises `deletRole` twice and asserts:

```java
verify(userRoleUserFunctionRepository).findByRolelistId(roleId);
verify(userRoleUserFunctionRepository, times(2)).delete(any(UserRoleUserFunction.class));
verify(userRoleRepository).deleteById(roleId);
```

Both tests pass today against code that, on the tenant in §1, **cannot complete a single delete**. They pass because the mocked `userRoleRepository.deleteById` is stubbed `doNothing()` — the FK that fires in production has no representation in the mock, and the two join tables that cause it are not mocked at all because the code never mentions them. The tests describe the code, and the code is wrong. This is the same failure mode SBDEV-3005 §13.3 called "the gate's most valuable finding".

### 7.3 New and updated tests

| Test | Class | Guards | State on unfixed code |
|---|---|---|---|
| `refusesWhenAGroupHoldsTheRole` | `UserRoleServiceUnitTest.DeleteRole` (new) | **AC-1** | **ERRORS** — `NoSuchMethodException: deleteRole` |
| `refusesWhenAUserHoldsTheRole` | same | **AC-1** (the `roles_id` column, and the only coverage the user branch will ever get — §1) | **ERRORS** |
| `refusalWritesNothingAtAll` | same | **AC-2** — the composition defect. `verify(userRoleUserFunctionRepository, never()).deleteByRoleId(any())`, `verify(userRoleRepository, never()).deleteRoleById(any())`, **and** `verify(userGroupUserRoleRepository, never()).delete(any())` + `verify(userUserRoleRepository, never()).delete(any())` so all four tables AC-2 names are covered here rather than leaving the anti-cascade half to verify row `A4` alone | **ERRORS** |
| `refusalMessageNamesTheHoldingGroups` | same | AC-3 — asserts `getFieldName()` is `"roleId"`, the group name appears, and the counts appear in the `describeHolders` format (§4.3) | **ERRORS** |
| `refusalMessageTruncatesAtTheHolderCap` | same (new in iteration 2) | **AC-3** — 16 holders in, at most 5 names plus `(and 11 more)` out. Pins the cap so the `super-admin` case has a definite expectation | **ERRORS** |
| `refusalVerdictSurvivesAnEmptyNameLookup` | same | **AC-3b** — the name projection returns `List.of()` while the id finder returns a holder → still refuses, message renders `id <n>` for each | **ERRORS** |
| `refusalMessageFallsBackToIdsForNullNames` | same (new in iteration 2) | **AC-3b** — the projection returns rows whose `getName()` is `null` for some holders and non-null for others. This is the case iteration 1's length-based guard let through (§4.3); a length-equal null-bearing result must still render `id <n>` for the null ones and never the string `null` | **ERRORS** |
| `deletesFunctionRowsThenTheRoleWhenUnheld` | same | AC-4 — an `InOrder` over exactly **two** calls: `deleteByRoleId(roleId)` then `deleteRoleById(roleId)` | **ERRORS** |
| `deletesAnUnheldRoleWithZeroGrants` | same (new in iteration 2) | AC-4 — replaces the deleted `deletesRoleWithNoFunctions`'s property: an unheld role with **zero** grants still deletes. `deleteByRoleId` returns 0, `deleteRoleById` returns 1, no exception, success logged with `0 function grant(s)` | **ERRORS** |
| `neverLoadsTheRoleOrGroupEntities` | same | **AC-5 / §4.1-§4.2.** `verify(userRoleRepository, never()).findById(any())`, `never()).deleteById(any())`, `verify(userGroupRepository, never()).findAllById(any())`, `verify(userRoleUserFunctionRepository, never()).findByRolelistId(any())`. This is the only automated guard on the hard constraint | **ERRORS** |
| `unknownRoleIdIsRejectedWithoutWriting` | same | AC-7 — `existsById` false → `EntityNotFoundException`, and no delete of any kind | **ERRORS** |
| `refusalIsLoggedAtWarnWithHolderCounts` | same | **AC-8 observability.** `ListAppender<ILoggingEvent>` on the `UserRoleService` logger; asserts one WARN containing the role id and both counts, **and that it is emitted even when the name lookup returns nothing** (§4.3 logs before building the message). Precedent: `DestinationEligibilityServiceUnitTest`, `StockUnitControllerUnitTest`, `FileImportControllerUnitTest`, `StartupFlywayMigratorUnitTest` | **ERRORS** |
| `successIsLoggedWithTheGrantCount` | same | AC-8 — and the count comes from `deleteByRoleId`'s return value, not from a pre-count | **ERRORS** |
| `deleteRoleRefusalRollsBackOnTenantManager` | `UserRoleServiceTransactionBoundaryTest` | **AC-6 — the checked-exception trap.** Make a holder exist, assert `rollback(status)` on the **tenant** manager and `never()).commit(any())`. Without `ApiInvalidParameterException.class` in `rollbackFor` this test goes red, which is the whole point (§4.4) | **ERRORS** |
| `deleteRoleRollsBackWhenTheRoleDeleteFails` | same | AC-6 | **ERRORS** |
| `deleteRoleTransactionDefinitionIsAWritableRequiredTransaction` | same | **AC-6.** Captures the `TransactionDefinition` and asserts `PROPAGATION_REQUIRED` and `isReadOnly() == false`. **The only form that catches propagation/readOnly drift** — modelled directly on `:179-203`, where a `NOT_SUPPORTED, readOnly = true` mutant was measured 100% green against every other kind of transaction test | **ERRORS** |
| `deleteRoleNeverTouchesTheLandlordManager` | same | AC-6 — the `@Primary` landlord mock at `:105-109` catches a bare `@Transactional` behaviourally | **ERRORS** |
| `UserRoleQueryContractUnitTest` (whole class, **new in iteration 2**) | `unit/repo/` | **AC-15 — the only lane that can see the five new repository methods at all.** Reflection-only, modelled on `unit/repo/OnHandQueryContractUnitTest` and `unit/repo/AdviceRepositoryRestExportUnitTest`, both of which exist for exactly this SBDEV-2217 situation: `@Query`, `@Modifying` and `@RestResource` are all `RetentionPolicy.RUNTIME`, so their values are readable with no Spring context, datasource or H2. Per method it pins the **`@Query` text**, `@RestResource(exported = false)`, and — on the two `@Modifying` methods — `flushAutomatically() == true` **and** `clearAutomatically() == false` **and** the absence of `@Transactional`. Reflection reads the *resolved* annotation, which is why it also absorbs the `B1`/`C1` formatting-fragility problem (§13.1 constraint 12) | **ERRORS** — three of the five methods do not exist |
| ~~`deletesRoleAndFunctions`~~ | `UserRoleControllerUnitTest.DeletRole` | **DELETE** — pins the bug (§0 row 9, §7.4) | passes today |
| ~~`deletesRoleWithNoFunctions`~~ | same | **DELETE** — pins the bug. Its *property* is preserved by `deletesAnUnheldRoleWithZeroGrants` above; only its assertions go | passes today |
| `delegatesToTheTransactionalServiceMethod` | same (replacement) | AC-9 — `verify(userRoleService).deleteRole(15L)`, body contains `DELETED`, and `verify(userRoleUserFunctionRepository, never()).deleteByRoleId(any())` + `never()).delete(any())` so the deletion cannot creep back into the controller in either shape | **FAILS** — the controller still owns the loop |
| `refusalSurfacesAs422NamingTheHolder` | same | AC-3 — stub the service to throw `ApiInvalidParameterException`, assert `status().isUnprocessableEntity()` and the holder name in the body. Works because `setUp:70` already registers `RestExceptionHandler` | **FAILS** |
| `unknownRoleIdSurfacesAs404` | same | AC-7 — stub `EntityNotFoundException`, assert `status().isNotFound()` | **FAILS** |

The `UserRoleServiceTransactionBoundaryTest` harness is reused as-is: `@SpringJUnitConfig` + `@EnableTransactionManagement` + `@Import(UserRoleService.class)` + mocked repositories + a mock `tenantTransactionManager` beside a `@Primary` mock `landlordTransactionManager`. Because the service bean comes in via `@Import`, Spring autowires whatever constructor exists, so **Fix A's three new constructor parameters do not break the file** — but three new `@Bean mock(...)` methods must be added to `TxTestConfig` (`:79-115`) or the context will not start.

Two mock-plumbing details that bite silently, both raised in review:

- `UserRoleServiceUnitTest:51` uses `@InjectMocks`, so `UserUserRoleRepository`, `UserGroupRepository` and `UserRepository` need explicit `@Mock` fields. Without them Mockito injects **nulls** and every new test NPEs for a reason unrelated to the fix.
- `UserRoleServiceTransactionBoundaryTest.setUp:136` resets only `userRoleUserFunctionRepository` and the two managers, and the context is shared across tests in the class. `userRoleRepository` — now stubbed for `existsById` and `deleteRoleById` — and `userGroupUserRoleRepository` must join that `reset(...)` list, or stubbing leaks between tests in declaration order.

### 7.4 Why the two pinning tests are deleted rather than adapted

`deletesRoleAndFunctions` asserts three things that all become false: that the controller calls `findByRolelistId`, that it calls `delete` twice, and that it calls `deleteById`. An implementer told to "make them pass" has one obvious move — keep the loop in the controller and add the refusal check beside it. That reproduces Bug 2 with a guard in front of it: the refusal would protect the common case while the N per-row commits stay non-atomic, and every test would be green.

The tests must therefore be **deleted and replaced**, and the replacement must assert the *negative* — that the controller no longer touches the repositories at all. Adapting is the failure mode; deleting is the fix.

Deleting a test does still lose whatever property it happened to cover, and one of these two covered a real one: `deletesRoleWithNoFunctions` was the only assertion that an unheld role with **zero** function grants still deletes. `deletesFunctionRowsThenTheRoleWhenUnheld` uses N > 0, so the zero case would otherwise survive only in manual row M4. `deletesAnUnheldRoleWithZeroGrants` (§7.3) carries that property forward — asserting `deleteByRoleId` returns 0, `deleteRoleById` returns 1, and the success log reads `0 function grant(s)` — without carrying forward any of the assertions that encoded the bug. (SBDEV-3005's `AccessServiceUnitTest:284` was the same trap in the opposite direction: a green test that encoded the bug and would have been "fixed" by reverting the real change.)

### 7.5 Manual test plan

Tenant header is **`X-Tenant-ID`** (`landlord/config/TenantFilter.java:23`) — **not** `tenant_name` — plus `facility_code`. Substitute a real bearer token.

| # | Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | **The reported bug — refusal replaces destruction** | `wms2-hydra-uat` | Note `SELECT count(*) FROM mywms_role_mywms_function WHERE rolelist_id = 50353;` (→ 23). Then `curl -i -H 'X-Tenant-ID: <tenant>' -H 'facility_code: <fc>' -H 'Authorization: Bearer <tok>' '<host>/v3/userRole/delete/50353'` | **422**, body names the holding group. Re-run the count → **still 23**. Log shows one `refusing to delete role 50353: held by 1 group(s) and 0 user(s)` at WARN | |
| M2 | **The blast-radius case — no partial destruction, and the message is bounded** | same | Same against role `50356` (`super-admin`, 77 grants, 16 groups) | 422; `count = 77` unchanged. Body matches §4.3's `describeHolders` contract exactly: `held by 16 group(s) and 0 user(s)`, **at most 5 group names**, then `(and 11 more)`, then `Users: none`. A 16-name message or a bare count is a **FAIL**. **This is the end-to-end evidence for AC-2** | |
| M3 | Happy path | same | Create a throwaway role (`POST /v3/userRole/create`) and assign it 2 functions. Do **not** add it to a group. Delete it | 200, body `<id> DELETED`. `mywms_role`, `mywms_role_mywms_function` both have no rows for that id. Log: `deleted role <id> and 2 function grant(s)` — the count comes from `deleteByRoleId`'s affected-row count, so `2` also proves the bulk statement matched | |
| M4 | Happy path, no grants | same | Create a throwaway role, assign nothing, delete it | 200. Log reports `0 function grant(s)`. No error, no 0-row warning | |
| M5 | **Atomicity — the Fix B/C case** | same | Take a role with grants that is **not** held (M3's, before deleting). Make the role delete fail — easiest is to attach it to a group **in a second session between the check and the delete**; if that is impractical, temporarily revoke DELETE on `mywms_role` for the app user | non-2xx **and** the function rows **still present**. Under the old code they would be gone. **This is the only end-to-end proof of the rollback** | |
| M6 | Unknown roleId | same | `GET /v3/userRole/delete/99999999` | **404** with a `ProblemDetail` body, not a bare 500. Log shows `EntityNotFound -> 404` (`RestExceptionHandler:159`) | |
| M7 | **BLOCKING — Fix D: the SDR item-resource DELETE is gone** | same | `curl -i -X DELETE '<host>/v3/userRole/50353'` | **405 or 404** — SDR's response for a non-exported CRUD method is version-dependent between `HttpRequestMethodNotSupportedException` (405) and 404, so either passes. What matters is **not 200 and not 500**. **Blocking, not one of nine**: the failure mode is `DefaultCrudMethods` resolving the type-erased `deleteById(Object)` through the interface hierarchy and SDR reading `@RestResource` off whichever declaration it lands on. Nothing in `mvn test` or `mvn clean compile` can see that, and `NoDeletePagingAndSortingRepository` has never been exercised (§4.5) | |
| M8 | **BLOCKING — Fix D did not break the SDR reads the UIs depend on** | same | `curl '<host>/v3/userRole/search/findByConnectorFalse'`, `.../search/findByName?name=receiving'`, **`curl '<host>/v3/userGroup/<groupId>/roles'`** (the association route `store/admin/group.js:42` consumes, and the route most sensitive to a supertype swap), and load Admin → User Management → Roles **and** Admin → User Management → Groups → a group's roles in the web UI | all 200; both screens render; the `/userGroup/{id}/roles` response still contains `_embedded.userRole`. Blocking for the same reason as M7 | |
| M9 | UI behaviour is unchanged-but-uninformative | same | Delete a held role from the web UI | The generic red toast, dialog closes, list unchanged. **Expected** — §12.3 and §11. Confirms the API fix ships safely without the UI ticket, and confirms the operator still cannot see *why* | |
| M10 | **BLOCKING — the application still starts** | same | Boot the built artifact against a real tenant and hit any endpoint | Startup completes and the tenant `EntityManagerFactory` initialises. **Blocking**: the five new `@Query` strings are validated at Spring Data repository-factory initialisation, and no test lane in this repository reaches that point (§4.5, §10 row 6). A malformed JPQL or a mistyped `@Param` takes down the **whole application**, not this endpoint, on a branch that auto-deploys to DEV | |

### 7.6 Regression

- `UserRoleControllerUnitTest` (`CreateRole`, `SaveRoleFunctions`), `UserRoleServiceUnitTest` (`ReplaceRoleFunctions`), `UserRoleServiceTransactionBoundaryTest`'s three existing tests, `AccessServiceUnitTest`, `UserGroupControllerUnitTest`, `UserControllerUnitTest`, `EntityUnitTest`, `EntityEqualsHashCodeContractTest` — none should change behaviour.
- **SBDEV-3005's fixes must remain intact.** `UserRoleService.replaceRoleFunctions:131-167` is not touched. Any diff to it means this fix over-reached. Its `@Transactional` value, its set-difference body and the `UserRoleUserFunctionId(roleId, functionId)` orientation are all covered by that plan's verify script — re-run it.
- §0 rows 7 and 8 (`UserGroupController`, `UserController`) must show **zero** diff.
- ArchUnit: adding **two** `@Modifying` queries, a new `repo/projection/` interface, and a changed repository supertype can each trip layering or naming rules. Run the ArchUnit suite and **revert the `archunit_store` mutation** afterwards.

### 7.7 Deliberately-skipped coverage

- **A Testcontainers IT proving the FK actually refuses.** The lane cannot boot (SBDEV-2217). This is the plan's largest genuine gap. M5 is the only empirical evidence. Recorded as a known gap, not a passing check. Note §4.2's ordering analysis is reasoned rather than observed, but under Fix C's bulk join-row delete the collision it describes cannot form, so what is untested is a hazard the design excludes rather than a behaviour the design depends on.
- **Any lane that executes the five new repository queries.** There is none: SBDEV-2217 blocks the Testcontainers harness, there is no `@DataJpaTest` in `src/test`, and every `smoke/*ContextLoadTest` extends the blocked `@SpringBootTest` harness. A malformed `@Query` or a mistyped `@Param` therefore fails at **application startup — the whole application, not this endpoint** — on a branch that auto-deploys to DEV. `UserRoleQueryContractUnitTest` pins the query text so a silent rewrite is caught in CI, but only blocking manual row **M10** proves the queries parse. This is the gap iteration 1 did not list, and §10 row 6 previously claimed coverage that does not exist.
- **A test proving `DELETE /v3/userRole/{id}` is gone.** `standaloneSetup` cannot see SDR at all. Blocking rows M7 and M8 only. The reconciliation with §4.2's "a property no test can see" principle is in §4.5: `D1`/`D2` pin the *construct*, which a refactor has to delete deliberately.
- **Anything about the SDR association resource `/v3/userRole/{id}/functions`.** Out of scope by AC-11's wording and owned by SBDEV-3013 (surface #2). Named here so its absence is a stated boundary rather than an oversight.
- **The user→role branch against real data.** `mywms_user_mywms_role` has 0 rows on every known tenant (§1), so `refusesWhenAUserHoldsTheRole` is the only coverage that branch will get. Stated rather than implied.
- **v1.** §8 — an observation, not work.

---

## 8. V1/V2 Applicability

`v1/wms-api/src/main/java/net/aim_ai/wms/controller/RoleController.java` has the same shape as the v2 endpoint — a role delete that clears the role↔function join table and then deletes the role, with **zero** `@Transactional` in the controller. SBDEV-3005 §6 already established that v1's `RoleController` carries the sibling non-atomicity and log defects byte-for-byte, and the v1 schema has the same three FKs on `mywms_role`. So the defect described here almost certainly exists in v1 as well.

**Action: none.** Per Nam's standing direction of 2026-08-19 — *v2 only unless explicitly told otherwise* — **no v1 ticket is filed, no v1 plan is written, and no v1 file is edited.** This paragraph is an observation recorded for whoever eventually revisits v1, not a work item. Do not port Fix A/B/C/D to v1.

---

## 9. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | No new cache, static field, or `ThreadLocal`. The service gains three constructor-injected repositories and nothing else |
| 2 | Connection pool math | **Better than today, on both axes** | Today: N+1 sequential transactions (one per function row plus the role delete), each acquiring and releasing a connection, and N+1 SQL statements. After Fix C's bulk join-row delete: **one** connection and **two** statements for the whole operation. On `super-admin` that is 78 acquisitions → 1 *and* 78 statements → 2 — iteration 1 claimed the former while still issuing 78 of the latter, because it deleted the join rows entity-by-entity (§4.2). No longer bounded by the function count of one role at all |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` touched or added. This is an operator-initiated admin action |
| 4 | Long transactions | **No** | The transaction spans `existsById` + 2 id finders + (≤2 name projections on the refusal path) + 1 bulk join-row delete + 1 bulk role delete — **five statements at most on the happy path, three on the refusal path**, and no longer proportional to the role's grant count. No HTTP, no file, no external I/O, no user interaction inside the boundary. Refusal is the *short* path: 3 queries and out |
| 5 | Request affinity | **N/A** | Stateless request/response. No session, no sticky routing |
| 6 | Retry / idempotency | **Yes — and this is the point of Fix B** | Today a retried delete is *not* idempotent in the way that matters: the first attempt destroys grants and fails, the second finds nothing to destroy and fails the same way, so the operator's two clicks produce one silent data loss and two identical errors. After the fix, a refused delete is a true no-op and can be retried indefinitely with no side effect; a successful delete is terminal, and a replayed success gets a clean **404** rather than a 500 (§4.3). The `deleteRoleById` 0-row return covers the concurrent-duplicate case with a WARN instead of an error |
| 7 | Tenant context | **No** | One synchronous request thread; no async boundary is crossed, so no `TenantContext` propagation problem. `value = "tenantTransactionManager"` binds the transaction to the tenant datasource (§4.4) |
| 8 | Distributed lock correctness | **No lock — the window is accepted and documented** | There is a genuine check-then-act window: a group could be attached to the role between the refusal check and the `deleteRoleById`. **Measured on `wms2-hydra-uat`:** `mywms_group_mywms_role` carries `UNIQUE (grouplist_id, rolelist_id)` plus a `rolelist_id` btree, so the refusal query is index-backed **and the FK still refuses the delete** — worst case the race degrades a clean 422 into a 500, and once Fix B makes the operation atomic it **cannot corrupt data**. `mywms_user_mywms_role` has **no index at all** (no PK, no unique — [SBDEV-3010](https://app.clickup.com/t/868kua912) owns that), so `findByRolesId` will seq-scan; harmless at 0 rows today. **Recommendation: accept and document the window; do not add locking.** A `SELECT … FOR UPDATE` on `mywms_role` would serialise a rare admin action against every concurrent group edit, and this repo has already been bitten twice by speculative lock ordering (`wms2-requires-new-in-lock-holding-tx-deadlock`, and SBDEV-1762's up-front lane locking). The FK is the correct backstop and it is already there |
| 9 | Cache invalidation | **N/A — MEASURED, not assumed** | `grep -rn "Cacheable\|CacheEvict\|CachePut"` over `service/AccessService.java`, `service/UserRoleService.java`, `service/UserGroupService.java`, `service/UserFunctionService.java`, `repo/jpa/UserRole*.java`, `repo/jpa/UserGroup*.java` and `repo/jpa/UserUserRole*.java` returns **zero hits**. `AccessService` (`:20-37`) constructor-injects all seven authorization repositories and reads them directly on every gate check with no caching layer, so a role delete is **immediately visible to authorization** on every replica and there is no stale-grant window to evict |
| 10 | External notifications | **N/A** | No OMS notify, no outbox row, no Keycloak mutation, no printer, no message. A role delete is purely local to the tenant database |

---

## 10. v2-only constraint checklist

| # | Constraint | Verdict | Where addressed |
|---|---|---|---|
| 1 | OSIV disabled (`spring.jpa.open-in-view=false`) | **Yes** | It is *why* Bug 2 destroys data — nothing holds the N deletes together (`UserRoleController.java:89-93`). Fix B supplies the boundary explicitly (§4.4). No code is added that would need OSIV to work |
| 2 | Transaction manager must be named | **Yes** | `@Transactional(value = "tenantTransactionManager", …)`, mirroring `UserRoleService.java:131`. A bare `@Transactional` hits the `@Primary` landlord manager; `UserRoleServiceTransactionBoundaryTest`'s `@Primary` landlord mock (`:105-109`) catches that behaviourally, not by string comparison |
| 3 | `readOnly = true` on read-only methods | **N/A — and asserted false here** | `deleteRole` is a write. `readOnly = true` would set `FlushMode.MANUAL` and the deletes would never flush; `deleteRoleTransactionDefinitionIsAWritableRequiredTransaction` pins `isReadOnly() == false` (§7.3) |
| 4 | Caffeine cache invalidation | **N/A — measured** | §9 row 9. Zero `@Cacheable`/`@CacheEvict`/`@CachePut` on any of the seven authorization tables' services or repositories; `AccessService:20-37` reads uncached |
| 5 | Jakarta namespace | **Yes** | `jakarta.persistence` throughout (`model/UserUserRoleId.java:5-6`, `model/UserRole.java:6`). No v1 code is ported (§8), so no `javax.*` can leak in |
| 6 | H2-compatible test SQL | **N/A for the tests — but the queries have NO execution lane** | Every new test is a Mockito unit test, a Spring slice with mocked repositories, or reflection. No SQL, no embedded database. **Correction to iteration 1, which claimed the new `@Query` strings are "validated at context load":** they are not. They are checked at Spring Data repository-factory initialisation, i.e. application startup, and every context-load lane in this repository (`smoke/OmsNotificationConfigContextLoadTest`, `smoke/PutawayResolverContextLoadTest`, `smoke/ReplenishReassignContextLoadTest`) extends the `@SpringBootTest` harness blocked by SBDEV-2217 — two of them say so in their own javadoc. Coverage is `UserRoleQueryContractUnitTest` for the query *text* (AC-15) plus blocking manual row **M10** for whether they parse at all (§4.5) |
| 7 | `BaseControllerUnitTest` for controller changes | **Yes** | `UserRoleControllerUnitTest` already extends it (`:36`), and `setUp:70` already registers `RestExceptionHandler` so the 422 and 404 contracts are actually asserted. Its `standaloneSetup` limits are stated in §7.1 rather than worked around |
| 8 | Micrometer metrics | **No — declined with a reason** | A low-frequency admin action. The refusal already logs at WARN with holder counts (§4.3) and `RestExceptionHandler:159` logs the 404, so the operational signal exists without a counter. SBDEV-2994 made the same call on `EntityNotFoundException` for the same reason. Revisit if the refusal turns out to be frequent, which would itself be the interesting signal |

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Fix B lands without Fix C** | The wrapping transaction creates the §4.2 collision — `CollectionRemoveAction` and N `EntityDeleteAction`s over the same rows — turning a destructive 500 into a misleading 409 "please retry". Strictly worse than today in diagnosability, and under Fix A it fires on the **happy** path, not the refusal path | Same commit (§6.2 step 4). Under Fix C's bulk join-row delete no `EntityDeleteAction` is queued at all, so the collision cannot form; `neverLoadsTheRoleOrGroupEntities` asserts `deleteById` and `findByRolelistId` are never called, and verify rows `C2`/`C3` forbid the entity forms inside `deleteRole` |
| **A reviewer "normalises" `@Modifying(flushAutomatically = true)` to the local `clearAutomatically = true` form** | **Asymmetric, and only one direction is a real defect.** *Gaining* `clearAutomatically` detaches the caller's entire persistence context and discards its pending changes, invisibly at every call site and invisible to every mocked-repository test — that is the harm. *Losing* `flushAutomatically` is **not** a defect under the bulk shape: nothing is ever queued, so there is nothing to flush and the statement order follows program order (§4.2 point 1 — iteration 2 initially claimed an FK violation here, which both reviewers independently refuted). | `UserRoleQueryContractUnitTest` asserts `clearAutomatically() == false` off the resolved annotation — **this is the assertion that matters**. Its `flushAutomatically() == true` companion pins an intentional choice, not a guarantee, and a future maintainer who removes the flag with a note is not breaking anything. Verify row `C1` mirrors both in source text |
| **An implementer copies `BillofladingPositionRepository:105-109` verbatim** | It brings a **bare** `@Transactional` (→ the `@Primary` landlord manager, so the deletes leave the tenant transaction) and a `@RestResource(path = …, rel = …)` that publishes an ungated HAL bulk-delete route. Three of the seven local bulk-delete precedents have this exact shape, so it is the likeliest copy source | §4.2 point 3 names both. Verify row `C4` is a negative on `@Transactional` in the two `@Modifying` blocks; `C1` and `A5`/`A6` require `exported = false`; `UserRoleQueryContractUnitTest` asserts the absence of `@Transactional` reflectively |
| **A malformed `@Query` on any of the five new methods** | Fails at Spring Data repository-factory initialisation, i.e. **application startup — the whole app, not this endpoint** — on a branch that auto-deploys to DEV. No lane in this repository catches it: every context-load test extends the `@SpringBootTest` harness blocked by SBDEV-2217 | `UserRoleQueryContractUnitTest` pins the query text so a *silent rewrite* is caught in CI; blocking manual row **M10** (boot against a real tenant) is the only thing that catches a genuinely malformed string. Iteration 1 claimed context-load validation it does not have — corrected in §10 row 6 and §6.2 step 6 |
| **Behaviour change: 500 → 422 for a held role** | Any consumer keying on the status code sees a new one | The only consumer is the web UI, which treats every non-2xx identically (§12.3). Documented in §7.5-M1. This is the intended fix, not a side effect |
| **Behaviour change: 200-that-half-destroyed → 422** | An operator who "successfully" deleted before now cannot | There was never a success: `roles_deletable_today = 0` (§1 Query 2), so no held role has ever been deletable through this endpoint. The 200 case only exists for unheld roles, and those still return 200 (M3/M4) |
| **Behaviour change: 500 → 404 for an unknown roleId** | New status on a path that used to fault | §4.3 records the decision and the rejected 422 alternative. M6 covers it |
| **The check-then-act race still returns a bare, unhandled 500** | §9 row 8's window: a group attached between the refusal check and `deleteRoleById` makes the FK fire, and `DataIntegrityViolationException` is **still** unhandled by `RestExceptionHandler` — so the one remaining path through this endpoint produces exactly the untyped 500 that §1 names as defect #2 | **Accepted and declined deliberately.** Adding a `DataIntegrityViolationException` handler means editing a global `@ControllerAdvice` that serves all 43 controllers, changing the error contract of every endpoint in the application to fix a rare race on one admin action. That is a legitimate reason to decline, but it must be *stated* rather than left as an unmentioned residue: after this PR the endpoint has one reachable bare 500 left, it is bounded (no data loss once atomic — §9 row 8), and closing it is a `RestExceptionHandler` ticket, not this one |
| **On the tenant measured, the operator-visible behaviour of this endpoint is unchanged by this PR** | `roles_deletable_today = 0`, so every call 422s, and the web UI renders its hardcoded generic toast for any non-2xx. The operator sees the same red toast as today. **AC-3 is a log-and-API win, not an operator-facing one** | **Stated plainly rather than mitigated.** What ships regardless is the important half: the destruction stops, and the refusal becomes visible in logs *today*, which is where an escalation actually gets diagnosed. The operator-facing half needs the §12.3 UI ticket — raised to **`high`** with the dependency stated — and, to be genuinely usable, the "groups holding this role" view (ADR follow-up 3). Do not read AC-3 as an operator-visible improvement before those land |
| **Fix D breaks an unknown SDR consumer** | A caller relying on `DELETE /v3/userRole/{id}` gets 405/404 | Enumerated, not assumed: on the Java side `grep -rn "userRoleRepository\.\(delete\|deleteById\|deleteAll\)" src/` returns exactly one hit (the line Fix A removes) and zero test references. On the UI side, the five `$delete` call sites in `v2/wms2-web-ui/store` are on `/locationType/`, `/advice/`, `/location/`, `/boxtype/` and `/sysprop/` — none on `/userRole/` — and the mobile UI has zero `userRole` references. Blocking rows M7 and M8 re-check both the removal and the reads. Residual: an external HAL client outside this monorepo cannot be enumerated from here — flagged as unverifiable |
| **Fix D does not close `PUT /v3/userRole/{id}/functions`** | The SDR **association** resource still clears every function grant on a role with one ungated, unlogged request — the same destruction, one URL segment away | Named by verb and path in §4.5, and **owned**: SBDEV-3013's surface #2 is this exact endpoint. Deliberately not pulled in — the fix is a global `RepositoryRestConfigurer` exposure change. **AC-11 is scoped to the item resource** so this plan cannot be read as having closed it |
| **Changing `UserRoleRepository`'s base interface has wider effects than expected** | SBDEV-3005 §5 warned that a repository's inheritance determines its SDR surface | `NoDeletePagingAndSortingRepository` extends the *same* `PagingAndSortingRepository` + `CrudRepository` pair and only annotates four inherited methods, so no query method, return type or exported search resource changes; `exposeIdsFor` is keyed on the entity class (`RestConfiguration:34-45`), not the repository. Its being previously unused means it is also previously **unexercised**, and `DefaultCrudMethods`' type-erasure resolution is invisible to the build — which is why M7 and M8 are blocking |
| **`rollbackFor` loses `ApiInvalidParameterException`** in a later "cleanup" | Spring commits on refusal. Harmless while the refusal precedes every write; silent data loss the moment a statement moves | `deleteRoleRefusalRollsBackOnTenantManager` (§7.3) goes red immediately, and verify row `B2` asserts the entry's presence. It is now the annotation's **only** `rollbackFor` entry (§4.4), so there is no dead configuration beside it to make it look decorative |
| **Two independent mappings of two of the three tables** (`UserRole.functions`, `UserGroup.roles`) | Hibernate does not reconcile a `@JoinTable` mapping with an `@EmbeddedId` entity over the same table — and the mappings are **transitively** EAGER, so loading a `UserGroup` reaches the `mywms_role_mywms_function` rows being deleted (§4.1) | §4.1 forbids materialising either entity and states the chain; `neverLoadsTheRoleOrGroupEntities` pins it; the service javadoc states it. **Reviewers must reject any later addition of `findById`/`findAllById` inside `deleteRole`** |
| **Someone "simplifies" the refusal into a cascade** | Silently revokes permissions from every member of every holding group — 16 groups for `super-admin` | §12.1 records the decision and the rejected alternatives. `refusalWritesNothingAtAll` now asserts `never()).delete(any())` on **both** holder repositories, so the property is pinned by a test and not only by verify row `A4` — which matters because `A4` is a *method-scoped* negative (`removeGroupFromRole:109` legitimately deletes from `userGroupUserRoleRepository`, so a file-scoped row can never go green) |
| **Pre-existing damage is not repaired by this fix** | Roles already stripped stay stripped; the fix has no record of what they had | P3 (§6.1) is the audit query. Explicitly **not** a blocker on the PR — the fix stops the bleeding; restoring grants is an operator decision per role. Verify row `X1` fails until §13.3 records a result, so it cannot be silently skipped |

---

## 12. Notes / Open Questions & Resolved Decisions

### 12.1 RESOLVED — refuse, do not cascade

**Decision (Nam, 2026-08-20): a role still held by any group or user is not deletable. Refuse with HTTP 422 and name the holders.**

Rationale: a cascade would delete the holders' rows too, which **silently revokes permissions from every member of every holding group.** On `wms2-hydra-uat`, deleting `super-admin` would strip 16 groups (§1 Query 3), and because the whole point of an authorization table is that nothing else records what was in it, that change is unrecoverable and invisible. Refusal makes the administrator do the detaching explicitly, one group at a time, where they can see what they are doing.

| Alternative | Why rejected |
|---|---|
| **Cascade all three tables** | Turns a loud failure into a silent, unrecoverable permission revocation for up to 16 groups at once. The blast radius is exactly what makes this ticket `high` |
| **`?force=true` escape hatch** | The dangerous path becomes one query parameter away and will be found. It also splits the endpoint's contract in two, doubling the test matrix and the reasoning burden, for a case (bulk detach + delete) that the admin UI can already do in steps — `components/admin/userManagement/groups/groupRoleEdit.vue:81` → `admin/group/saveGroupRoles`. **"Safely" needs qualifying:** `saveGroupRoles` is the very endpoint SBDEV-3012 exists to fix, so for `super-admin` the prescribed workflow routes an operator 16 times through a known non-atomic writer. It is still the better option — a non-atomic detach loses one group's assignment at worst, whereas a cascade loses all 16 silently — but the alternative is not being rejected in favour of a clean path |
| Soft-delete the role (flag it inactive) | Larger design, and it does not answer this ticket's question — the grants are still destroyed by the current code path. Genuinely the right answer for **users** (§12.4), where history must be preserved; roles have no history to preserve |

Not to be reopened.

### 12.2 RESOLVED — both defects in one PR

**Decision (Nam, 2026-08-20): the missing FK check/refusal and the atomicity defect ship together.**

They are not separable in any useful way. The refusal without the transaction leaves two independent auto-commits — clear the grants, then delete the role — so any failure between them still strips a role; the guard would protect the common case and hide the remaining one. (Iteration 1 wrote this as "the N per-row commits"; Fix C's bulk delete reduces N to 1, which shrinks the window without closing it.) The transaction without the refusal makes the FK failure a clean rollback, which is better than today but still reports a 500 for something the operator could have been told plainly. And per §4.2, the transaction alone would introduce a *new* hazard. One PR.

### 12.3 RESOLVED — API-only; the web UI swallow is a follow-up

**Decision (Nam, 2026-08-20): this plan touches `v2/wms2-api` only.**

The web UI discards the API error body, so the new 422 message will never reach an operator:

```js
// v2/wms2-web-ui/store/admin/role.js:110-119
async deleteRole(context, data) {
  try {
    const result = await this.$axios.$get(`/userRole/delete/${data.roleId}`)
    console.log('deleteRole returned', result)
    context.dispatch('getNonConnectorRoles')
    this.$toast.success('Role deleted')
  } catch (error) {
    console.log(error);
    this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
  }
}
```

The toast text is hardcoded, so a 422 naming 16 holding groups renders as "network or server issue". `components/admin/userManagement/roles/deleteRolePop.vue:44-50` compounds it: `deleteItem()` awaits the dispatch and then `$emit('close')` **unconditionally**, so the dialog closes exactly as it does on success. The same swallow pattern appears in `saveRole` (`role.js:99-107`) and `checkName` (`:123-133`).

**Companion ticket — FILED 2026-08-20 as [SBDEV-3030](https://app.clickup.com/t/868kugvjg)** (`high`) — *"Admin stores discard every API error body, so a 422 renders as 'network or server issue' — and the naive fix reads the wrong field"*. Scope: surface `error.response.data` in the toast across `store/admin/role.js` (`deleteRole`, `saveRole`, `checkName`) and keep the delete dialog open on failure.

**Priority `high`, raised from `normal` in iteration 2, with the dependency stated:** because `roles_deletable_today = 0`, every call to this endpoint on the measured tenant 422s, and the UI renders its hardcoded generic toast for any non-2xx. **So AC-3 is not observable by any human until this ticket lands** — the operator-visible behaviour of the endpoint is byte-identical to today (§11). At `normal` it sat as follow-up #1 of six, indistinguishable in weight from the doc-drift item, which understated it: it is the half that makes AC-3 mean anything.

**Second companion ticket — FILED 2026-08-20 as [SBDEV-3031](https://app.clickup.com/t/868kugvue)** (`normal`) — *"Add a 'groups holding this role' view to the role screen — the reverse lookup is already exported and unused"*. The detach affordance exists but only in one direction: `store/admin/group.js:38-49` reads a **group's** roles, and `groupRoleEdit.vue:81` saves them, from the **group** screen. There is no reverse view. So even with the error body surfaced, the 422 message is the *only* artefact that tells an operator which 16 groups to visit — which makes the first ticket structurally load-bearing rather than cosmetic, and makes this one the difference between a workflow that is technically available and one that is discoverable.

### 12.4 FILED as SBDEV-3021 — `UserController.delet` is a much larger problem (§0 row 8)

`controller/UserController.java:281-306` deletes only the user's group memberships, then calls `userRepository.deleteById`. It misses `mywms_user_mywms_role` **and nine operational FKs** on `mywms_user(id)` — `billoflading`, `billoflading_position`, `cyclecount_position`, `goodsreceipt`, `goodsreceiptposition`, `message`, `pickingorder`, `pickingorder_position`, `replenishorder`, all `operator_id`. So deleting **any user who has ever done work** fails.

This is deliberately **not** folded into this ticket, and not because of scope discipline alone: it is a different problem with a different answer. The nine operational FKs must **not** be cascaded — an operator's audit trail is the point of recording `operator_id` — so the fix is a **soft-delete / deactivate** design, not a cascade or a refusal. That is a design ticket, not a bug fix. It also swallows its own errors into a 200 (`:294-299` returns `ResponseEntity.ok(errorMap)` on `DataAccessException`), which is a third defect in the same method.

**FILED 2026-08-20 as [SBDEV-3021](https://app.clickup.com/t/868kug16p)** (`high`) — *"Deleting a user who has ever done warehouse work is impossible — /user/delete misses 10 FKs and needs a soft-delete design"*. Split deliberately across three tickets, all on the same method: **SBDEV-2984** owns the authorization gap (one-line guard, should land first), **SBDEV-3012** now owns the atomicity **and** the HTTP-200-on-failure contract (mechanical, reference impls in PR #170 / PR #173), and **SBDEV-3021** owns only the semantic question — what deleting a user with work history should mean. The nine `operator_id` FKs must not be cascaded, so that half is a design decision rather than a bug fix, which is why it did not fold into either of the others.

### 12.5 RESOLVED — `UserGroupController.delete/{groupId}` now owned by a widened SBDEV-3012 (§0 row 7)

Atomicity only; its cascade is complete (the FKs on `mywms_group` are exactly `mywms_group_mywms_role` and `mywms_group_mywms_user`, both cleared, verified against `pg_constraint`). So it is not this ticket's defect and it stays out of scope.

**Disposition, 2026-08-20: [SBDEV-3012](https://app.clickup.com/t/868kua93r) was WIDENED rather than a new ticket filed.** The defect class (non-atomic multi-write, zero `@Transactional`), the controller, and the fix shape (extract to a service method under `tenantTransactionManager`) are identical to what 3012 already covered on `saveGroupRoles`, so a separate ticket would have split one piece of work across two. Its title and location list were updated, and its Sequencing section now records the three-way overlap on `UserController.delet`.

**Correction to iteration 1, now closed.** Iteration 1 called this "already deferred with a named owner", which was wrong: [SBDEV-3012](https://app.clickup.com/t/868kua93r)'s scope was `saveGroupRoles` (`UserGroupController:99-117`) and `saveUserGroups` (`UserController:310-334`) — the *save* methods — and SBDEV-3005 §12.2 deferred `saveGroupRoles:99-117`, not `delete/{groupId}`, so `UserGroupController.delete/{groupId}:80-96` fell between the two tickets with no owner at all. Both consensus reviewers found this independently. **Closed 2026-08-20 by widening SBDEV-3012** (§12.5) and has **no owner at all**.

**Action — DONE 2026-08-20:** the second option was taken. SBDEV-3012 was widened explicitly rather than a fourth ticket opened, because the defect class, controller and fix shape are identical to what it already covered. It was **not** folded into this plan — a stray edit in an unrelated controller is how a focused diff stops being reviewable, and verify row `S1` exists precisely to prove that file is untouched.

`UserGroupController:80-96` also carries two cosmetic log defects: `:82` still logs `"delete printer with Id {}"` and `:94` logs `"Role with Id {} is deleted"` for a *group* — SBDEV-3005's Fix E cleaned these strings out of `UserRoleController` but not out of `UserGroupController`. Iteration 1 addressed this advice to "whoever takes 3012", who will never open this method; it belongs to the new ticket above.

### 12.6 Doc-drift candidate

`sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md:204` maps `UserRoleController` / `AccessService` → **`wms2-keycloak-role-matrix.md`**. That doc is the drift candidate: it describes the role↔function↔group model this change alters the *lifecycle* of (roles are now non-deletable while held, and the SDR delete route is gone). Run `verify-docs` against the PR diff and update `wms2-keycloak-role-matrix.md`'s role-lifecycle section plus its `last_verified` date.

### 12.7 Version history

| Date | Change |
|------|--------|
| 2026-08-20 | Created. Diagnosis and §0 from the DB-verified analysis bundle; §4.2's `deleteById` EAGER-collision hazard and Fix C derived during drafting; §0 row 6 resolved in scope via the pre-existing `NoDeletePagingAndSortingRepository`; unknown-roleId contract decided as 404 rather than following the 422 precedent |
| 2026-08-20 | **Consensus reached — Critic returned APPROVE at iteration 2.** Post-approval corrections, none of which weakens a test, AC or verify row. (a) **The `flushAutomatically` rationale was false and is restated.** Iteration 2 escalated it to "load-bearing / NOT optional / do not normalise away" and pinned it in four places including prescribed production javadoc. Both reviewers **independently** refuted it: after the ADJ-1 bulk restructure there is no pending join-row delete to flush — `deleteByRoleId` is itself an `executeUpdate()`, `existsById` is a `COUNT`, the finders are reads, so the action queue is empty and ordering follows program order. The flag is kept as an intentional no-op with the two narrow reasons stated; `clearAutomatically() == false` is identified as the assertion that actually carries weight. Root cause of the error: the orchestrator's ADJ-1 (adopt the bulk delete) invalidated ADJ-3's "flushAutomatically IS load-bearing" wording, which was true only for the superseded find-then-loop shape. (b) **`T5` could never have gone green** — it scoped to "the `DeleteRole` region" of `UserRoleServiceTransactionBoundaryTest`, but that class is flat (zero `@Nested`); re-scoped to the method. (c) **Constraint 3's prescribed temper was self-defeating** — `(?:(?!;|@).)*?` cannot cross a `;`, so the six body-spanning rows would have gone permanently red; tempers are now split by span with a two-method validation fixture. Corrected counts: **five** of seven bulk-delete precedents carry `@Transactional` (three bare), not four of seven; **24** real `@Modifying` annotations (a bare grep reports 25 — `RestIdempotencyRepository:33` is a javadoc mention); only **six** of the seven bulk deletes are JPQL (`MessageRepository:41` is `nativeQuery`); `repo/projection/` holds **53** interfaces, not ~35; the mass-delete comment is at `MessageRepository:40` (`:30` is mass-archive). The association-resource deferral now rests on SBDEV-3013's ownership rather than an inflated `RepositoryRestConfigurer` cost estimate. |
| 2026-08-20 | **Revised after consensus iteration 2 (Architect + Critic).** Substantive changes: (a) the join rows are now deleted in bulk by a new `UserRoleUserFunctionRepository.deleteByRoleId`, not by a find-then-loop — which makes §4.2's collision *unreachable* rather than routed around, turns N+1 statements into 2, and strengthens AC-10's pin; (b) `clearAutomatically` dropped from both `@Modifying` annotations, with the reason recorded, and "no `@Transactional`" made explicit against the local precedent; (c) the two name queries take the already-held ids (`IN :ids`) and return `(id, name)` interface projections, so the fallback keys on **nullness per element** instead of list length — the case iteration 1's guard let through; (d) `describeHolders` specified with a format, a 5-name cap and a per-element id fallback; (e) AC-11 narrowed to the *item resource*, with the SDR **association** resource `PUT/PATCH/DELETE /v3/userRole/{id}/functions` named by verb and handed to SBDEV-3013's surface #2; (f) a new `UserRoleQueryContractUnitTest` plus blocking manual row M10, because **no lane in this repository validates a `@Query`** — §10 row 6 and §6.2 step 6 previously claimed one that cannot run; (g) verify rows `A4`/`T5`/`T6`/`T8` scoped to a method or nested class (three false-greened, one was permanently red), `S1` given a mechanism, `X1`–`X4` made able to fail, and an expected-pre-fix-state column added to every row; (h) `rollbackFor` reduced to its one live entry; (i) §0 row 7 / §12.5 corrected — `UserGroupController.delete/{groupId}` has **no** owner; (j) the §12.3 UI ticket raised to `high` and §11 made to say plainly that on the measured tenant this PR changes nothing an operator can see. Corrected facts: `$delete` in `wms2-web-ui/store` returns **5** hits, not zero (none on `/userRole/`, so the conclusion strengthens); `RestExceptionHandler` has **13** `@ExceptionHandler` methods and **three** SSO types, not fourteen and four; `BaseControllerUnitTest`'s `standaloneSetup` is at `:65-73`, not `:49-56`; `repo/jpa/` carries **25** `@Modifying` annotations over **7** bulk-delete methods in 5 files, not "13 precedents" / "five" — and `flushAutomatically` appears in **zero** of them, which is stronger than the review's "none of the five". Recorded but not acted on: the Architect's suggestion to sequence Fix A behind the UI ticket (rejected — splitting means two rounds of test rewriting on one method for no safety gain, and the log-side win lands immediately) |

---

## 13. Acceptance & Implementation

### 13.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-3011-delete-role-join-table-cascade.sh`

Run before the first code change to capture the FAIL baseline, and again at the end. Sign-off requires the script's own final line pasted into the completion report:

```
Result: N pass, 0 fail, M skip
```

**Rows to implement** (grouped by fix; each must be negative-tested against the pre-fix file before being trusted). The **expected pre-fix state** column exists because roughly a third of these rows are GREEN at baseline *by construction* — they are regression pins, not defect detectors — and without the column §6.2 step 1's FAIL baseline is unreadable. `unit/repo/OnHandQueryContractUnitTest`'s javadoc has the convention wording: *"regression pins, and they PASS on the unfixed build by design."*

| Row | Asserts | Expected pre-fix |
|---|---|---|
| `A1` | `UserRoleService` declares `deleteRole(Long` | **FAIL** |
| `A2` | inside `deleteRole`: `userGroupUserRoleRepository.findByRolelistId` **and** `userUserRoleRepository.findByRolesId` both appear (tempered gap, method-scoped) | **FAIL** |
| `A3` | inside `deleteRole`: `throw new ApiInvalidParameterException` | **FAIL** |
| `A4` | **negative, METHOD-SCOPED** — inside the body of `deleteRole` only, no `userGroupUserRoleRepository.delete(` and no `userUserRoleRepository.delete(` (the anti-cascade guard, §12.1). **Must not be file-scoped:** `UserRoleService.removeGroupFromRole` legitimately calls `userGroupUserRoleRepository.delete(roleGroup.get())` at `:109`, so a file-scoped negative is permanently RED against correct post-fix code | **FAIL** (`deleteRole` does not exist, so the tempered gap finds no body — see constraint 5: make the helper return FAIL, not 127) |
| `A5` | `UserUserRoleRepository` declares `findByRolesId` **and** `u.id.rolesId` (the component, not `rolelistId`) **and** `exported = false` | **FAIL** |
| `A6` | `UserGroupRepository.findHolderNamesByIds` and `UserRepository.findHolderNamesByIds` exist, both return `List<RoleHolderNameView>`, both `exported = false`, and both queries contain `IN :ids` (not a `UserGroupUserRole`/`UserUserRole` cross-join — §4.3) | **FAIL** |
| `A7` | `repo/projection/RoleHolderNameView.java` exists and declares `Long getId()` and `String getName()` | **FAIL** |
| `A8` | `UserRoleService` declares `describeHolders` **and** a `HOLDER_NAMES_IN_MESSAGE` constant (§4.3's specified cap — without a named constant the cap is not reviewable) | **FAIL** |
| `B1` | `deleteRole` carries `@Transactional` naming `tenantTransactionManager` (annotation→method tempered gap). **Accept both spellings** — `value = "tenantTransactionManager"` and `transactionManager = "tenantTransactionManager"` are semantically identical and this repo has been bitten by treating the alias as a failure. The authoritative check is behavioural: `deleteRoleNeverTouchesTheLandlordManager` | **FAIL** |
| `B2` | that same annotation's `rollbackFor` contains `ApiInvalidParameterException.class` (§4.4) | **FAIL** |
| `B3` | **negative** — `AdminController` still has no `@Transactional` | **PASS (regression pin)** — green at baseline by construction; it guards against the fix being applied in the wrong place |
| `C1` | `UserRoleRepository` declares `deleteRoleById` with `@Modifying`, `flushAutomatically = true`, **no `clearAutomatically`**, and `exported = false`. **Attribute order must not matter** — assert the three facts independently rather than matching one literal string; the resolved-annotation assertion lives in `UserRoleQueryContractUnitTest` (`T9`) and this row is the source-text mirror of it | **FAIL** |
| `C2` | **negative, method-scoped** — inside `deleteRole`, no `userRoleRepository.deleteById(` and no `userRoleRepository.findById(` (§4.1, §4.2) | **FAIL** (no `deleteRole` body; same treatment as `A4`) |
| `C3` | `UserRoleUserFunctionRepository` declares `deleteByRoleId` with `@Modifying`, `flushAutomatically = true` and `exported = false`, **and** `deleteRole` calls `userRoleUserFunctionRepository.deleteByRoleId` — the join-table clearing stays an explicit, greppable, mockable call rather than a Hibernate mapping behaviour (§4.2's second rejected alternative, AC-10) | **FAIL** |
| `C4` | **negative** — neither `deleteByRoleId` nor `deleteRoleById` carries `@Transactional` (§4.2 point 3: five of the seven local precedents do, three of them bare, and a bare one resolves to the `@Primary` landlord manager) | **PASS (vacuous at baseline)** — neither method exists yet, so this row cannot detect the defect it guards; it only earns its keep post-fix. Marked so nobody reads its baseline green as evidence |
| `D1` | `UserRoleRepository extends NoDeletePagingAndSortingRepository<UserRole, Long>` | **FAIL** |
| `D2` | **negative** — `UserRoleRepository` no longer names `PagingAndSortingRepository` or `CrudRepository` directly | **FAIL** |
| `E1` | `UserRoleController.deletRole` calls `userRoleService.deleteRole` | **FAIL** |
| `E2` | **negative, method-scoped** — `deletRole` contains no `userRoleUserFunctionRepository` and no `userRoleRepository` reference | **FAIL** |
| `E3` | `deletRole` declares `throws … ApiInvalidParameterException` | **FAIL** |
| `T1` | `UserRoleControllerUnitTest` no longer contains `deletesRoleAndFunctions` or `deletesRoleWithNoFunctions` (§7.4 — deletion, not adaptation) | **FAIL** |
| `T2` | `UserRoleControllerUnitTest` contains `isUnprocessableEntity` **and** `isNotFound` within the delete nested class | **FAIL** |
| `T3` | `UserRoleServiceUnitTest` contains `refusalWritesNothingAtAll` **and**, within that method, `never()).deleteByRoleId(`, `never()).deleteRoleById(` and two `never()).delete(` verifies (all four tables AC-2 names) | **FAIL** |
| `T4` | `UserRoleServiceUnitTest` contains `neverLoadsTheRoleOrGroupEntities` **and** `never()).findById(` | **FAIL** |
| `T5` | **METHOD-scoped** (corrected — iteration 2 said "the `DeleteRole` region", but `UserRoleServiceTransactionBoundaryTest` is **flat**: zero `@Nested`, tests at `:141`/`:165`/`:177`, and §5/§7.3 add a `deleteRole` lane to that flat class rather than nesting it — so a nested-class scope has no subject and the row could never go green). Assert `deleteRoleRefusalRollsBackOnTenantManager` exists **and** contains a `rollback(` verify **inside its own body**. **Must not be file-scoped:** `rollback(` already appears at `:154`, `:162` and `:173` from SBDEV-3005, so a file-scoped row false-greens | **FAIL** |
| `T6` | **method-scoped** — `deleteRoleTransactionDefinitionIsAWritableRequiredTransaction` exists and contains both `PROPAGATION_REQUIRED` and `isReadOnly` **inside its own body**. **Must not be file-scoped:** `PROPAGATION_REQUIRED` is already at `:199` and `isReadOnly` at `:200`, so a file-scoped row false-greens | **FAIL** |
| `T7` | `UserRoleServiceUnitTest` contains `ListAppender` and a `WARN` assertion inside the `DeleteRole` nested class (AC-8) | **FAIL** |
| `T8` | **negative, nested-class-scoped** — no test in the `DeleteRole` regions asserts on `BusinessException` for the refusal (§7.1: if the exception type changes the assertion must move to `getKey()`, and this row forces the conversation). **Must not be file-scoped:** `UserRoleServiceUnitTest:202` already asserts `isInstanceOf(BusinessException.class)` for `removeGroupFromRole`, so a file-scoped negative is permanently RED | **FAIL** (the `DeleteRole` region does not exist; treated as `A4`) |
| `T9` | `unit/repo/UserRoleQueryContractUnitTest` exists and, per new method, asserts the `@Query` text, `exported()` is `false`, and — for the two `@Modifying` methods — `flushAutomatically()`, `clearAutomatically()` and the absence of `@Transactional` (§7.3, AC-15) | **FAIL** |
| `S1` | **negative, with a mechanism** — `git diff --quiet <base-sha> -- src/main/java/net/aim_ai/wms/controller/UserGroupController.java src/main/java/net/aim_ai/wms/controller/UserController.java`, plus literal pins as a fallback when the base SHA is unavailable: `UserGroupController:82`'s `"delete printer with Id {}"` and `UserController`'s `ResponseEntity.ok(errorMap)` are both still present (§0 rows 7, 8). "Unchanged in the delete methods" is not a grep and iteration 1 stated no mechanism | **PASS (regression pin)** |
| `S2` | SBDEV-3005 invariants hold: `UserRoleService.replaceRoleFunctions` still carries `tenantTransactionManager` and still constructs `UserRoleUserFunctionId(roleId, functionId)` | **PASS (regression pin)** |
| `X1` | **P3 tenant damage audit is recorded.** FAILs while §13.3 still contains the `*(empty — to be filled…)*` placeholder **or** contains no `P3:` line. Iteration 1 made this a `SKIP`, which meant AC-14 could not fail and the script could report `0 fail` with the audit never run | **FAIL** |
| `X2` | **P9 and P11 are recorded** — §13.3 contains a `P9:` line and a `P11:` line. Same construction as `X1` | **FAIL** |
| `X3` | `SKIP` — M1–M10 manual tests. The three **blocking** rows (M7, M8, M10) are recorded in §13.3 by `X4` | **SKIP** |
| `X4` | **the three blocking manual rows are recorded** — §13.3 contains `M7:`, `M8:` and `M10:` lines. These three cannot be covered by any automated lane (§7.7) and M10's failure mode is a whole-application startup failure on an auto-deploying branch | **FAIL** |

#### Verify script: WRITTEN AND NEGATIVE-TESTED 2026-08-20 — evidence

`sbdocs/9-System/scripts/verify-SBDEV-3011-delete-role-join-table-cascade.sh` exists and has been
validated against the unfixed tree **and** against a synthetic correct fixture. A script that has
only ever been seen red is not trustworthy either — both directions were measured.

| Check | Result |
|---|---|
| `bash -n` + every called helper is defined (constraint 5) | clean; no row can record bash's 127 as a plain FAIL |
| **Baseline on unfixed `develop` @ `60aef02`** | **`Result: 6 pass, 43 fail, 6 skip`** — and the 6 passes are exactly the six rows marked `[exp:PASS-pin]` (`B3`, `D4`, `D5`, `S1`, `S2`, `S2b`). No row's observed state disagrees with its predicted state |
| Correct-fixture run (a conforming `deleteRole` injected into a copy of the tree) | `A2`, `A3`, `A4`, `B1`, `B2`, `C2`, `C3c` all flip to PASS — so none of the scoped rows is permanently red |
| **`A4` anti-false-red** (the iteration-1 defect) | PASSES on the fixture **while `userGroupUserRoleRepository.delete(` is still present at `UserRoleService:109`** — method scoping confirmed working, not merely intended |
| `B1` four-variant matrix (constraint 4) | correct → PASS; **bare `@Transactional` → FAIL; annotation on a *different* method → FAIL; annotation absent → FAIL**; `transactionManager =` alias → PASS (deliberate) |
| `C2` comment immunity (constraint 6) | a javadoc naming `deleteById(` and `findById(` → still PASS; a **real** `userRoleRepository.deleteById(` call → FAIL |

**Two bugs the negative test found in the script itself** — both would have shipped as trustworthy:

1. **`X2` and `X4` false-greened at baseline.** They grepped the whole plan file for `P9:` / `M7:`, which
   also match the §6.1 prerequisite and §7.5 manual-test tables — so the two rows meant to gate
   *unrecorded* work passed while nothing was recorded. Fixed by extracting §13.3 first
   (`plan_status_section` / `status_records`); all three X rows now fail at baseline as intended.
2. **The declaration extractor dropped multi-line annotations**, so `B1`/`B2` **failed against correct
   code** — the prescribed `@Transactional(value = …,\n rollbackFor = …)` spans two lines and a
   "line starts with `@`" backward walk stops at the continuation. Fixed by balancing parens *and*
   braces (annotation array values such as `rollbackFor = {A.class, B.class}` contain braces, so a
   backward brace scan is also wrong). This would have mis-graded every `decl`-scoped row.

**Deviation from constraint 3, deliberate:** the script does **not** use tempered-greedy gaps. Every
scoped row extracts the exact syntactic region first — brace-balanced method body, brace-balanced
nested class, or the annotation block above a signature — and greps inside it. The prescribed
`(?:(?!;|@).)*?` cannot cross a `;`, so on the six body-spanning rows it is permanently red, which is
constraint 8's trap self-inflicted. Region extraction also fails **closed** on a missing method, which
is why `C4`/`C4b` are `[exp:FAIL]` here rather than the `PASS (vacuous)` §13.1 predicted: an
unimplemented method reads as FAIL, so no row in this script is vacuous at baseline.

**Verify-script construction constraints — every one of these has produced a false green or a permanent red in this repo before:**

1. **The template's perl helpers fail OPEN on a missing file.** `perl -0777 -ne` exits 0 when it cannot open its target, so every multi-line assertion about a file that does not exist yet false-greens. Add `[ -f "$2" ] || return 1` to each helper. This matters for `A7` (a brand-new projection file) and `T9` (a brand-new test class).
2. **Do not use the template's `mvn_test_passes`.** It greps for strings that `mvn -q` suppresses, so it reports FAIL on every passing run — 62 red rows across 22 scripts, filed as [SBDEV-3014](https://app.clickup.com/t/868kua9c9). Copy the corrected form from `verify-SBDEV-3005-…sh`, which adds `Skipped: 0` and per-class test-count minimums, and which restores the `archunit_store` the maven rows mutate.
3. **Never use an unbounded `.*?` gap under `/s`** — it will match a correct construct *elsewhere in the file* and go green on a broken method. Use a tempered-greedy gap scoped to the method. **But pick the temper to match the span.** `(?:(?!;|@).)*?` cannot cross a `;`, so it works only for an annotation→signature hop (`B1`, `C1`, `C3`); used literally on the rows that must span a **multi-statement method body** — `A2`, `A4`, `C2`, `E2`, `T5`, `T6` — it goes permanently RED, which is this document's own constraint 8 trap self-inflicted. For body-spanning rows temper on the **next member declaration** instead, e.g. `(?:(?!\n    (?:public|private|protected|@)).)*?`, which stops at the following method or annotation but freely crosses statements inside one body. Validate each body-spanning row against a two-method fixture where the forbidden construct sits in the *neighbouring* method — the row must stay green.
4. **Do not over-temper.** A gap that forbids `public` cannot match an annotation→method pair, because the method's own declaration contains it. Row `B1` must be validated against four variants: correct (green), annotation on a *different* method (red), no annotation (red), bare `@Transactional` (red).
5. **A row naming an undefined shell function records bash's 127 as a plain FAIL**, indistinguishable from unimplemented work, and `bash -n` does not catch it. Grep the script for every helper name it calls.
6. **A negative grep can be satisfied by a comment** that merely quotes the forbidden literal. Rows `A4`, `C2`, `C4`, `E2`, `T8` must exclude comment lines or anchor on a call shape (`repo.delete(`) rather than a bare identifier. Note §4.2's javadoc deliberately mentions `deleteById` and `clearAutomatically` by name, and §4.3's javadoc mentions `findById` and `findAllById` — so comment exclusion is **required**, not optional, for `C1`, `C2` and `C4`.
7. **Rows that anchor on identifier names go stale under a rename.** `A1`–`A8`, `C1`, `C3`, `E1` all do. Prefer chain-level assertions where possible, and note that a proximity regex secretly asserts "same block".
8. **A file-scoped negative is permanently RED whenever the forbidden construct has a legitimate use elsewhere in the file.** Worked examples, all found in review of iteration 1: `A4` (`removeGroupFromRole:109` legitimately deletes from `userGroupUserRoleRepository`) and `T8` (`UserRoleServiceUnitTest:202` legitimately asserts `BusinessException` for `removeGroupFromRole`). Both must be scoped to the method or nested class. The trap is that a permanently-red row is indistinguishable from unimplemented work.
9. **A file-scoped POSITIVE row false-greens off a pre-existing literal.** `T5` (`rollback(` at `:154`, `:162`, `:173`) and `T6` (`PROPAGATION_REQUIRED` at `:199`, `isReadOnly` at `:200`) — all four literals landed with SBDEV-3005, so both rows pass on completely unmodified code. Scope them to the new method or nested class.
10. **Verify rows go stale when a refactor moves code between files**, and "behaviour-preserving" makes the reds easy to wave away. Iteration 2 moved the join-row delete from a loop in `deleteRole` to a bulk method on `UserRoleUserFunctionRepository`; `C3` had to change with it. Prefer chain-level helpers over per-line pins.
11. **A row that cannot fail is not a check.** `X1`–`X4` are constructed so they FAIL until §13.3 records a result. Iteration 1 made `X1` a `SKIP` and then hung AC-14 on it, which meant the script could report `0 fail` with the damage audit never run.
12. **Two of these rows assert formatting, not semantics, and must not.** `@Transactional(transactionManager = "…")` is identical in meaning to `value = "…"` and would red `B1`; swapping `@Modifying`'s attribute order would red `C1`. Both are handled by asserting the facts independently rather than a literal string, and by making `T9`'s reflection test — which reads the *resolved* annotation, not the source text — the authoritative check.
13. Run the script with `PROJECT_ROOT` pointed at the **symlink shadow root**, not the main checkout, or it grades the wrong tree.

### 13.2 Acceptance criteria

Every in-scope §0 row maps to at least one criterion: row 1 → AC-1; row 2 → AC-2/AC-6; row 3 → AC-5; row 4 → AC-5/AC-10; row 5 → AC-1; row 6 → AC-11; row 9 → AC-12.

| # | Criterion | Verified by |
|---|---|---|
| **AC-1** | **A role held by any group or user cannot be deleted.** `GET /v3/userRole/delete/{id}` on a held role returns **422** and does not delete anything from any of the three tables | `refusesWhenAGroupHoldsTheRole`, `refusesWhenAUserHoldsTheRole`; verify `A1`/`A2`/`A3`/`A5`; **M1** |
| **AC-2** | **A refused delete is a total no-op.** Zero rows removed from `mywms_role_mywms_function`, `mywms_group_mywms_role`, `mywms_user_mywms_role` or `mywms_role` | **`refusalWritesNothingAtAll`** — which now asserts all four tables, so `A4` is no longer the sole guard on the anti-cascade half; verify `A4` (method-scoped) and `T3`; **M2 — the only end-to-end evidence** |
| **AC-3** | The 422 body follows §4.3's `describeHolders` contract: both holder counts, at most `HOLDER_NAMES_IN_MESSAGE` names per kind with an `(and N more)` suffix, `none` for an empty kind, and `fieldName = "roleId"` | `refusalMessageNamesTheHoldingGroups`, `refusalMessageTruncatesAtTheHolderCap`, `refusalSurfacesAs422NamingTheHolder`; verify `A8`/`T2`; M1, M2. **Not observable by any operator until the §12.3 UI ticket lands — §11** |
| **AC-3b** | **The refusal verdict does not depend on the name lookup, and no holder ever renders as `null`.** A holder whose name is null, blank, or missing from the projection still causes a refusal, and appears in the message as `id <holderId>` | `refusalVerdictSurvivesAnEmptyNameLookup`, **`refusalMessageFallsBackToIdsForNullNames`** (§4.3 — the case iteration 1's length-based guard let through); verify `A7` (the `(id, name)` projection is what makes a per-element fallback expressible at all — with a bare `List<String>` and `ORDER BY name` putting nulls last, a null element cannot be correlated with any holder) |
| **AC-4** | An unheld role is deleted completely, in two statements: its function rows first, then the role — and this holds when the role has **zero** grants | `deletesFunctionRowsThenTheRoleWhenUnheld` (an `InOrder` over exactly two calls), `deletesAnUnheldRoleWithZeroGrants`; verify `C3`; M3, M4 |
| **AC-5** | **Neither `UserRole` nor `UserGroup` is materialised inside the transaction.** No `findById`, no `deleteById`, no `findAllById` on those repositories within `deleteRole`, and no `UserRoleUserFunction` entity is loaded either | **`neverLoadsTheRoleOrGroupEntities`**; verify `C1`/`C2`/`T4`/`A6` |
| **AC-6** | The whole operation is one tenant transaction: `REQUIRED`, not read-only, on `tenantTransactionManager`, and it rolls back on **both** a failure and a **refusal** | `deleteRoleRollsBackWhenTheRoleDeleteFails`, **`deleteRoleRefusalRollsBackOnTenantManager`**, **`deleteRoleTransactionDefinitionIsAWritableRequiredTransaction`**, `deleteRoleNeverTouchesTheLandlordManager`; verify `B1`/`B2`/`B3`/`C4`/`T5`/`T6`; **M5** |
| **AC-7** | An unknown `roleId` returns **404** with a `ProblemDetail`, not a 500, and writes nothing | `unknownRoleIdIsRejectedWithoutWriting`, `unknownRoleIdSurfacesAs404`; verify `T2`; M6 |
| **AC-8** | A refusal is logged at WARN with the role id and both holder counts — **and is logged even when the name lookup returns nothing**; a success logs the affected-row count from `deleteByRoleId` | `refusalIsLoggedAtWarnWithHolderCounts`, `successIsLoggedWithTheGrantCount`; verify `T7`; M1, M3, M4 |
| **AC-9** | The controller owns no deletion logic — it validates nothing, touches no repository, and delegates | `delegatesToTheTransactionalServiceMethod`; verify `E1`/`E2`/`E3` |
| **AC-10** | The join-table clearing is still an explicit, greppable, mockable call — not delegated to Hibernate's collection mapping (§4.2's rejected alternative). Satisfied by `verify(userRoleUserFunctionRepository).deleteByRoleId(roleId)`, which is a stronger pin than the per-row `verify(…, times(N)).delete(any())` iteration 1 relied on | verify `C3`; `deletesFunctionRowsThenTheRoleWhenUnheld`, `deletesAnUnheldRoleWithZeroGrants` |
| **AC-11** | **The *item resource* `DELETE /v3/userRole/{id}` is no longer exported** — it returns 405 or 404 — and the SDR *reads* both UIs depend on still work, including the `/userGroup/{id}/roles` association route. **This does NOT close the SDR association resource `PUT/PATCH/DELETE /v3/userRole/{id}/functions`**, which still clears every function grant on a role, ungated and unlogged; that surface is SBDEV-3013's surface #2 and is explicitly out of scope (§4.5) | verify `D1`/`D2`; **M7 and M8, both blocking — no automated test in this repository can see the SDR surface (§7.7)** |
| **AC-12** | The two bug-pinning tests are **deleted**, not adapted, the replacements assert the negative, and `deletesRoleWithNoFunctions`'s *property* survives in a new test | verify `T1`/`T3`; `deletesAnUnheldRoleWithZeroGrants` |
| **AC-13** | SBDEV-3005 is intact: `replaceRoleFunctions` unchanged, `UserGroupController` and `UserController` show zero diff | verify `S1` (now a `git diff --quiet` plus literal fallbacks) / `S2`; re-run `verify-SBDEV-3005-…sh` |
| **AC-14** | P3 (pre-existing damage audit), P9 and P11 have been run and their results recorded in §13.3 | verify `X1`/`X2` — **these now FAIL until §13.3 records a result**, so the script cannot report `0 fail` with the audit outstanding. Iteration 1 made this a `SKIP`, i.e. an AC that could not fail |
| **AC-15** | **The five new repository methods' contracts are pinned by an executing test, not only by a shell grep.** Per method: the `@Query` text, `@RestResource(exported = false)`, and for the two `@Modifying` methods `flushAutomatically() == true`, `clearAutomatically() == false`, and no `@Transactional` | `UserRoleQueryContractUnitTest`; verify `T9`. Added in iteration 2 because **no lane in this repository executes these queries at all** (§4.5) — so the reflection test plus blocking manual row **M10** are the whole of their coverage. Note the two `@Modifying` attributes carry different weight: `clearAutomatically() == false` pins a real correctness property, while `flushAutomatically() == true` pins an intentional-but-inert choice (§4.2 point 1). Do not read the latter's green as evidence of an ordering guarantee |
| **AC-16** | **The three blocking manual rows are recorded.** M7 (SDR item-resource DELETE gone), M8 (SDR reads intact), M10 (the application still boots) each have a recorded outcome in §13.3 | verify `X4`. These three have no automated lane and two of them fail invisibly to the build (§4.5, §7.7) |

### 13.3 Implementation Status

**Implemented 2026-08-20 — [wms2-api PR #173](https://github.com/SiteBossInc/wms2-api/pull/173) into `develop`.** Branch `bugfix/SBDEV-3011-delete-role-join-table-cascade` off `origin/develop` @ `60aef02`, in worktree `.claude/worktrees/wms2-api/SBDEV-3011`.

| Commit | Subject |
|---|---|
| `96ad273` | SBDEV-3011: refuse deleting a held role, and make the delete atomic |
| `6e75c8a` | SBDEV-3011: close the review findings (4 medium, 8 low), all mutation-verified |
| `982df3b` | SBDEV-3011: close the second-pass review Lows (arity-blind pin, count drift) |

### Tests

| Class | Result |
|---|---|
| `UserRoleQueryContractUnitTest` (new) | 13 pass — reflection-only repository contract; the only lane in this repo that can see the five new methods |
| `UserRoleServiceUnitTest` | 25 pass, **12 in the new `@Nested DeleteRole`** |
| `UserRoleControllerUnitTest` | 18 pass; the two bug-pinning tests **deleted**; the 422 stub now carries the real wire shape |
| `UserRoleServiceTransactionBoundaryTest` | 6 pass (3 pre-existing + 3 new) |
| `mvn clean compile` | success |
| Full suite | `Tests run: 5248, Failures: 2, Errors: 0, Skipped: 67` — the 2 are the known pre-existing failures on clean `develop` (`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`, `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`), unchanged by this branch |

**Verify script:** `Result: 54 pass, 0 fail, 1 skip` with `PROJECT_ROOT=<worktree>` — the single SKIP is `X3` (the non-blocking manual rows M1–M6/M9).

Two script bugs were found by running it against the finished code, both fixed and both re-checked against unfixed `develop` to confirm they had not been loosened into false greens:
- `D2` forbade the substring `PagingAndSortingRepository`, which `NoDeletePagingAndSortingRepository` **contains** — so the row went permanently RED the moment Fix D landed. Replaced with an extends-clause parser.
- `T1` matched the replacement block's own comment naming the two deleted tests — §13.1 constraint 6's trap, self-inflicted. Now comment-stripping.
- `PLAN` was a relative `../../sbdocs/...` path, correct from `v2/wms2-api` but not from a worktree at `.claude/worktrees/<repo>/<TICKET>`; the `X` rows failed CLOSED on a missing file, indistinguishable from unrecorded work. Now absolute with an env override.

⚠ **`PATH` must reach JDK 21 + maven in the SAME invocation** — a `bash script` call does not inherit an earlier `export`. Run naively the five `M` rows fail spuriously and the script reports `46 pass, 8 fail`. That is a PATH artifact, not the known broken-`mvn_test_passes` template bug (this script carries the repaired helper).

**Baseline for comparison:** on unfixed `origin/develop` the same script reports `6 pass, 43 fail, 6 skip`, and the conformance lane independently confirmed every `[exp:FAIL]` row genuinely fails and every `[exp:PASS-pin]` row passes — **zero false greens, zero permanently-red rows**. `verify-SBDEV-3005-…sh` re-run in this worktree: `39 pass, 0 fail, 2 skip` (predecessor intact).

### Review outcome

Four independent lanes: conformance (`PASS`, 16/16 AC), code review (4 Medium + 8 Low — **all Mediums fixed**), security review (**security-neutral to net-positive**), and a second pass scoped to the fixes, which confirmed all four Medium fixes sound and **no fix had weakened a test** — but caught one as incompletely done.

**The pattern worth recording: three of the defects found in this work were assertions that could not fail.** The Fix D regression pin was vacuous (a for-each over an empty method list); its first fix was then *arity-blind* (name-only keys collapsed the two `deleteAll` overloads, so partial gutting stayed green); and the alias assertion pinned the presence of `AS id`/`AS name` but not their pairing, so a positional swap — this repo's signature defect class — passed. None of these would have been found by reading. Every one was found by applying a mutant and observing green.

Mutants confirmed killed by the fixed assertions — every one was measured GREEN before its fix:
- gutting `NoDeletePagingAndSortingRepository` to `{}` (Fix D deleted, item DELETE re-exported)
- swapping the projection aliases (`SELECT g.name AS id, g.id AS name`)
- removing `.sorted()` from the unresolved-id fallback
- adding `noRollbackFor = RuntimeException.class` to `deleteRole`

### Prerequisite dispositions

**P3: CLOSED — audit run 2026-08-20, no damage found anywhere reachable.** The fingerprint of a previously-failed delete is: role still exists, still held by a group, **zero** function grants.
```sql
SELECT count(*) FROM mywms_role r
 WHERE (SELECT count(*) FROM mywms_role_mywms_function f WHERE f.rolelist_id = r.id) = 0
   AND (SELECT count(*) FROM mywms_group_mywms_role g WHERE g.rolelist_id = r.id) > 0;
```
| Tenant | Roles | Damaged | `mywms_user_mywms_role` rows |
|---|---|---|---|
| `wms2-hydra-uat` | 14 | **0** | 0 |
| `wms2-wineco-dev` | 140 | **0** | 0 |
| `nywh-hydra-uat` | 14 | **0** | 0 |

No repair needed. **Not run against prd** — no prd MCP in this session; an operator must run the same query there before sign-off. The empty `mywms_user_mywms_role` on all three confirms §1's finding that the user→role path is vestigial.

**P9: CLOSED — use `wms2-wineco-dev` for the success-path manual rows.** `wms2-hydra-uat` has **zero** deletable roles (all 14 group-held), so M3/M4 cannot be exercised there at all. `wms2-wineco-dev` has **2** roles held by neither a group nor a user — e.g. id `30262754`, `cy-test-role-1783506236250`, a Cypress leftover and therefore safe to delete. Run the refusal rows (M1/M2) on hydra-uat and the success rows (M3/M4) on wineco-dev.

**P11: STILL OPEN — human coordination, not this session's call.** Merge order versus SBDEV-3012 (`saveGroupRoles`/`saveUserGroups`) needs agreeing with its owner. There is **no file overlap**: this PR touches `UserRoleController`/`UserRoleService`, SBDEV-3012 touches `UserGroupController`/`UserController`, and verify row `S1` proves both of those files are byte-identical to `60aef02`. Low risk.

### Manual tests — NOT RUN (no running instance in this session)

The three **blocking** rows must be executed before merge.

**M7: NOT RUN** — `curl -i -X DELETE '<host>/v3/userRole/<id>'` must return 405 or 404, never 200/500. *Partially discharged statically:* the security lane drove Spring Data REST's own `CrudMethodsSupportedHttpMethods.getMethodsFor(...)` against `spring-data-rest-core 4.5.7` and got item verbs `[GET, HEAD, OPTIONS, PATCH, PUT]` for `UserRoleRepository` — **no DELETE** — with all four sibling repositories unaffected. It also ruled out type erasure as a bypass: `DefaultCrudMethods` selects the *annotated* `NoDeletePagingAndSortingRepository.delete(Object)` and `AnnotationUtils.findAnnotation` resolves `exported = false`. `UserRoleQueryContractUnitTest` pins the same property by reflection in CI. The curl is still the only end-to-end proof.

**M8: NOT RUN** — the SDR reads the UIs depend on must still work: `/v3/userRole/search/findByConnectorFalse`, `/search/findByName`, and **`GET /v3/userGroup/{groupId}/roles`** (`store/admin/group.js:42`, reads `_embedded.userRole`) — the association route most sensitive to a supertype swap.

**M10: NOT RUN, and this is the one that matters most** — boot the artifact against a real tenant. The five new `@Query` strings are validated only at Spring Data repository-factory initialisation and **no test lane in this repository reaches that point** (§4.5). A malformed JPQL or mistyped `@Param` takes down the **whole application**, not just this endpoint, on a branch that auto-deploys to DEV.

M1–M6 and M9 are non-blocking but are the only end-to-end evidence for AC-2 and AC-3. M2 now has a falsifiable expected body, and the unit suite asserts that exact string.

### Deliberately not done

- The SDR **association** resource on `/v3/userRole/{id}/functions` — SBDEV-3013 surface #2. See §4.5 for the corrected verb list (`PUT` destructive; `PATCH`/`POST` additive only; collection `DELETE` is 405).
- `UserGroupController.delete/{groupId}` (§0 row 7 — **no owner**, needs a ticket) and `UserController.delet` (§0 row 8 — needs a soft-delete design; it returns **HTTP 200** on failure).
- The wms2-web-ui error-body swallow (§12.3), raised to `high`. Until it ships, this PR's operator-visible change is "generic error, no damage" replacing "500 plus silent damage", and nothing more.
- **Doc drift: none found.** No architecture doc documents this endpoint's contract, and `wms2-keycloak-role-matrix.md` has **no role-lifecycle section** — so §12.6's suggestion to update one rested on an assumption. Nothing in `sbdocs/3-Resources/` is falsified by this diff. Adding a lifecycle section to a 700-line security doc as a side effect of a bug fix would be scope creep; recorded here instead.

### Test-name reconciliation (§13.2 vs the suite)

The conformance lane flagged five §13.2 names that do not exist verbatim. Four are folded into differently-named tests that **do** assert the property; one was a real gap and was added.

| §13.2 name | Actual |
|---|---|
| `refusalMessageTruncatesAtTheHolderCap` | folded into `refusalMessageNamesTheHoldingGroups` (now a full-message equality assertion) |
| `refusalSurfacesAs422NamingTheHolder` | `heldRoleSurfacesAs422` (controller) |
| `refusalVerdictSurvivesAnEmptyNameLookup` | `refusalVerdictSurvivesANullBearingNameLookup` — strictly stronger |
| `refusalMessageFallsBackToIdsForNullNames` | same test, plus `unresolvedHolderIdsAreOrderedAscending` |
| `deleteRoleNeverTouchesTheLandlordManager` | asserted inline in both transaction-boundary tests |
| `deleteRoleRollsBackWhenTheRoleDeleteFails` | **was genuinely absent — added**, and mutation-verified |

**These lines are machine-required.** Verify rows `X1`, `X2` and `X4` grep for them and FAIL while the placeholder above is still present or any of them is missing (§13.1 constraint 11) — so an unrecorded audit or an unrun blocking manual test cannot reach `0 fail`:

- `P3:` — the pre-existing damage audit result, per tenant (§6.1)
- `P9:` — the throwaway role created for M3/M4, since no unheld role exists on `wms2-hydra-uat`
- `P11:` — the SBDEV-3012 merge-order outcome, and whether that ticket was widened to cover `UserGroupController.delete/{groupId}` (§12.5)
- `M7:` — the SDR item-resource `DELETE` status observed (405 or 404)
- `M8:` — SDR reads intact, explicitly including `/userGroup/{id}/roles` returning `_embedded.userRole`
- `M10:` — the application booted against a real tenant

---

## Completeness checklist

| # | Concern | Status |
|---|---------|--------|
| 0 | DB verified | ✓ `db_verified: true` — three queries against `wms2-hydra-uat` reproduced verbatim in §1 (FK enumeration, `roles_deletable_today = 0`, per-role blast radius) |
| 1 | All callsites enumerated | ✓ §0 rows 1–9, enumerated from `pg_constraint` outward (every FK on `mywms_role` → its writer, mapping and repository), not from memory. **Java side re-verified in iteration 2:** `grep -rn "userRoleRepository\.\(delete\|deleteById\|deleteAll\)" src/` returns exactly one hit — `UserRoleController.java:93`, the line Fix A removes — and zero test references, so Fix D's Java blast radius is provably nil (§4.5). **UI side corrected:** iteration 1 said `$delete` in `wms2-web-ui/store` returns zero hits; it returns **5**, all on other repositories, which strengthens rather than weakens the conclusion |
| 2 | Adjacent bugs | ✓ row 6 resolved **in scope for the item resource**, with a written verdict, and its *association* half named by verb and handed to its actual owner (SBDEV-3013 surface #2 — §4.5, AC-11); row 7 **corrected in iteration 2**: it has no owner, so §12.5 specifies the ticket to file rather than pointing at SBDEV-3012, whose scope is the *save* methods; row 8 excluded with a **new ticket specified** and the reason it needs a different design (§12.4); §4.6 records the destructive-`@GetMapping` observation without acting on it. Every excluded row now has either a ticket to file or a named owner, and the distinction between the two is stated |
| 3 | Backward compat | ✓ §11 — three status-code changes (500→422 held, 200-that-half-destroyed→422, 500→404 unknown) plus 405-or-404 on the SDR item resource. Every consumer enumerated: the web UI treats all non-2xx identically (§12.3), the five `$delete` call sites in `wms2-web-ui/store` are all on other repositories, zero mobile-UI `userRole` references, and one Java call site (the one Fix A deletes). Response body string preserved verbatim |
| 4 | Concurrency | ✓ §9 row 8 — the check-then-act window is named, **measured** (`UNIQUE (grouplist_id, rolelist_id)` + `rolelist_id` btree on the group table; no index at all on the user table), bounded (worst case 422→500, never corruption once atomic), and **accepted with a documented rationale for not locking** |
| 5 | Multi-tenant | ✓ §4.4 and §10 row 2 — `value = "tenantTransactionManager"` is mandatory and its omission is caught behaviourally by the `@Primary` landlord mock, not by a string comparison |
| 6 | Error handling | ✓ §2 (neither `DataIntegrityViolationException` nor `EmptyResultDataAccessException` is handled → bare 500; **13** `@ExceptionHandler` methods, three of them SSO); §4.3 (422 refusal / 404 unknown, with the rejected alternative reasoned and the self-undercutting path-variable argument dropped); §4.4 (the checked-exception `rollbackFor` trap, now one live entry rather than one live and two dead). The **one bare 500 that remains** — the §9 row 8 race — is recorded in §11 with an explicit decision to decline a global `@ControllerAdvice` change, rather than left as an unmentioned residue |
| 7 | Observability | ✓ §4.3 logs the refusal at WARN with holder counts and the success with the grant count; AC-8 and tests `refusalIsLoggedAtWarnWithHolderCounts` / `successIsLoggedWithTheGrantCount`; §10 row 8 declines a Micrometer counter with a reason |
| 8 | Rollback / migration | ✓ §6.1 P1/P2/P5 — no DDL, no Flyway version claimed, no data migration. P3 covers the **pre-existing damage** the bug has already done, explicitly as an audit rather than a blocker |
| 9 | Test coverage | ✓ §7 — 21 new test rows (one of them a whole new reflection-based repository-contract class), the two pinning tests deleted with the reason (§7.4) **and the one real property they covered carried forward** (`deletesAnUnheldRoleWithZeroGrants`), every landmine honoured (`@Nested` targeting, `archunit_store`, broken IT lane, 2 pre-existing failures, `getKey()` vs `getMessage()`, `standaloneSetup`/`/v3`, `@InjectMocks` needing new `@Mock` fields, the shared-context `reset(...)` list), observability tests added for deliberate mode, and §7.7 states **four** gaps plainly — the fourth being the one iteration 1 missed: **no lane in this repository executes a repository query at all**, so the five new `@Query` strings are covered by reflection plus blocking manual row M10 and nothing else |
| 10 | Cross-version | ✓ §8 — v1 `RoleController` almost certainly has the same defect; recorded as an **observation only**. No v1 ticket, no v1 plan, no v1 file touched, per the standing v2-only instruction |

---

## ADR — refuse a held role delete; make the delete atomic; close the parallel HAL route

**Decision.** Move `deletRole`'s body into `UserRoleService.deleteRole` under a single `tenantTransactionManager` transaction. **Refuse** (HTTP 422, naming the holders under a specified format and cap) any delete of a role still referenced by `mywms_group_mywms_role` or `mywms_user_mywms_role`; return 404 for an unknown id. Perform **both** deletes as bulk JPQL statements — the function grants by `UserRoleUserFunctionRepository.deleteByRoleId`, the role by `UserRoleRepository.deleteRoleById` — so no `UserRole` and no `UserRoleUserFunction` entity is ever materialised. Remove the parallel Spring Data REST **item-resource** `DELETE /v3/userRole/{id}` by extending the codebase's existing `NoDeletePagingAndSortingRepository`; the SDR **association** resource on the same prefix stays open and is handed to its named owner.

**Drivers.**
1. **Blast radius over frequency.** `roles_deletable_today = 0` and 77 grants / 16 groups on one role. Every attempt on this tenant destroys before it fails, and nothing records what was destroyed.
2. **Unrecoverability.** An authorization join table is its own only record. A cascade or a partial delete cannot be undone by anything the system knows.
3. **Verifiability under a broken IT lane.** SBDEV-2217 means no integration test can observe emitted SQL, so the design must be provable by Mockito and a Spring slice — which rules out relying on Hibernate's implicit collection cleanup.
4. **Two mappings per table, transitively EAGER.** `UserRole.functions` and `UserGroup.roles` make the obvious implementations (`findById`, `findAllById`, `deleteById`) unsafe in ways no unit test would notice — and because `UserGroup.roles` is EAGER to `UserRole` which is EAGER to `UserFunction`, loading a *holder* to name it reaches the very join rows being deleted (§4.1). The constraint applies to the error-message path, not only to the write path.
5. **Every property the design relies on must be pinned by something that executes.** No lane in this repository runs a repository query (SBDEV-2217, no `@DataJpaTest`, every context-load test blocked), so "it will fail at startup if wrong" is not a check — it is a production incident on an auto-deploying branch. Hence the reflection-based contract test and three *blocking* manual rows rather than nine advisory ones.

**Alternatives considered.**

| Alternative | Bounded assessment |
|---|---|
| **Cascade all three tables** | + One code path, no new error contract, the operator's click always works. − Silently revokes permissions from every member of every holding group (16 for `super-admin`), unrecoverably and invisibly. **Rejected — §12.1** |
| **Cascade behind `?force=true`** | + Keeps the safe default while allowing bulk cleanup. − Puts the unrecoverable path one query parameter away, splits the contract in two, doubles the test matrix. **Rejected — §12.1** |
| **Transaction only, no refusal check** | + Two-line change; the FK failure becomes a clean rollback and nothing is destroyed. − Leaves a bare 500 with no message on a path that is 100% failing, and per §4.2 the transaction alone introduces the `CollectionRemoveAction`/`EntityDeleteAction` collision on the happy path. **Rejected — §12.2** |
| **Bulk JPQL for the join rows** — *chosen* | + One statement instead of N; no `EntityDeleteAction` is queued, so §4.2's collision cannot form rather than being avoided; `verify(repo).deleteByRoleId(id)` is a stronger pin than `verify(…, times(N)).delete(any())`; N+1 statements → 2. − Breaks the structural parallel with `replaceRoleFunctions`, which a reviewer fresh from SBDEV-3005 will expect. **Chosen — §4.2** |
| **Load-and-remove loop for the join rows** (iteration 1's choice) | + Reuses the existing, already-exercised `findByRolelistId`; keeps `deleteRole` shaped like its sibling `replaceRoleFunctions`. − `replaceRoleFunctions` needs entities because it computes a **set difference**; `deleteRole` does not, so the parallel is cosmetic. The loop is also the only thing that makes §4.2's collision reachable, and `SimpleJpaRepository.delete(T)` is three persistence-context operations per two-column join row. **Rejected in iteration 2 — §4.2** |
| **Delete via `deleteById` and let `UserRole.functions` clear the join table** | + One line, one mechanism, no collision. − The join-row removal becomes a Hibernate mapping behaviour that **no test in this repository can observe**, so a future refactor deletes it for free. Note this is *not* the bulk-JPQL option above: a bulk repository call keeps the property greppable and mockable. **Rejected — §4.2** |
| **`@Modifying(clearAutomatically = true)`, the majority local form** | + Matches 4 of the 7 in-repo bulk-delete precedents, so it reads as unremarkable. − There is no stale entity to evict (Fix C's premise is that nothing is materialised), while `em.clear()` detaches the **entire** persistence context and discards its pending changes — so any future caller wrapping `deleteRole` in a larger tenant transaction silently loses its managed entities, invisibly at every call site and invisibly to mocked-repository unit tests. **Rejected in iteration 2 — §4.2** |
| **Leave the SDR route alone (row 6 out of scope)** | + Smaller diff; SBDEV-3013 already owns the broader HAL surface. − Makes this plan's headline criterion false via a live route on the same URL prefix, when the fix is a one-line supertype change to an interface the codebase already wrote for the purpose. **Rejected — §4.5** |
| **Also close the SDR association resource `/v3/userRole/{id}/functions`** | + It is the same destruction, one URL segment from the one being closed, and provably live. − Requires a `RepositoryRestConfigurer` exposure change, which alters a global surface for all domain types and needs its own caller enumeration; it is named verbatim as SBDEV-3013's surface #2. **Deferred to its named owner — §4.5**, with AC-11 narrowed to the item resource so this plan cannot be read as having closed it |
| **Follow the 422 precedent for an unknown roleId** | + Consistent with `saveRoleFunctions:128-130`. − That precedent's input is a body field being validated; reporting a missing *resource* as a malformed parameter loses the distinction, and `EntityNotFoundException` is unchecked so it sidesteps the `rollbackFor` trap. **Rejected — §4.3** |
| **Pessimistic lock on `mywms_role` to close the check-then-act window** | + Eliminates a real race. − Serialises a rare admin action against every concurrent group edit; the FK is already a correct backstop; this repo has twice been bitten by speculative lock ordering. **Rejected — §9 row 8** |
| **Add a `DataIntegrityViolationException` handler to `RestExceptionHandler`** | + Would close the last bare 500 on this endpoint (the §9 row 8 race). − `RestExceptionHandler` is a global `@ControllerAdvice` serving all 43 controllers, so this changes the error contract of every endpoint in the application to fix a rare race on one admin action. **Declined — §11**, stated rather than left as an unmentioned residue |

**Why chosen.** Refusal is the only option whose failure mode is a *message*. Every alternative's failure mode is lost permission data. The transaction is what makes refusal mean something — without it a refusal protects only the cases the check anticipated. And the two together are only safe if neither delete loads an entity, which is why Fix C exists rather than being an optimisation.

**Consequences.**
- Deleting a role becomes a two-step operator workflow: detach the holders, then delete. That is a deliberate friction increase on an unrecoverable action — but it is currently **undiscoverable**: the only artefact naming the holders is the 422 body, which the web UI discards, and there is no reverse "which groups hold this role" view. Follow-ups 1 and 3 are what make the prescribed workflow actually walkable.
- Three new status codes on one endpoint, all of them replacing a 500. One bare 500 remains, on the §9 row 8 race path, and adding a handler for it is declined above.
- `DELETE /v3/userRole/{id}` disappears from the HAL surface. `NoDeletePagingAndSortingRepository` gains its first user, which also means its first exercise — hence two blocking manual rows.
- **The SDR association resource `PUT/PATCH/DELETE /v3/userRole/{id}/functions` remains open** and can still clear every function grant on a role in one ungated, unlogged request. AC-11 is scoped to the item resource for exactly this reason; SBDEV-3013 owns it as surface #2.
- Five new repository methods, all `@RestResource(exported = false)`, so the ungated HAL surface does not grow. **None of them has an execution lane in this repository** — `UserRoleQueryContractUnitTest` pins their contracts reflectively and blocking manual row M10 is the only check that they run at all.
- `@Modifying(flushAutomatically = true)` without `clearAutomatically` deviates from all seven local bulk-delete precedents (none sets `flushAutomatically`; four set `clearAutomatically`). Both javadocs record it as an intentional choice — **not** as load-bearing: under the bulk shape the flag is a no-op, and bare `@Modifying` would also be correct. `clearAutomatically`'s *absence* is the part that carries weight.
- §4.2's ordering analysis stays **UNVERIFIED** until the IT lane is fixed. Under the chosen shape the hazard cannot arise, so the label constrains nothing beyond keeping `deleteById` forbidden.
- **On the tenant measured, the operator-visible behaviour of this endpoint does not change.** Every role is held, so every call 422s, and the UI renders the same generic toast it renders today. AC-3 is a log-and-API win until follow-up 1 ships.

**Follow-ups.**
1. **Web UI error-body swallow** — `store/admin/role.js:110-119` + `deleteRolePop.vue:44-50`. **FILED as [SBDEV-3030](https://app.clickup.com/t/868kugvjg)**, **`high`**, raised from `normal` in iteration 2: AC-3 is not observable by any human until it lands, so it is not cosmetic and must not sit at the same weight as the doc-drift item. §12.3
2. **`UserController.delet`** — **FILED as [SBDEV-3021](https://app.clickup.com/t/868kug16p)** (`high`), scoped to the soft-delete design only; its atomicity + HTTP-200 halves went into the widened [SBDEV-3012](https://app.clickup.com/t/868kua93r), and [SBDEV-2984](https://app.clickup.com/t/868kt73f9) already owned the authorization gap. §12.4
3. **A "groups holding this role" view on the role screen** — **FILED as [SBDEV-3031](https://app.clickup.com/t/868kugvue)**, `normal`. The reverse lookup turned out to be **already exported and unused** (`GET /v3/userGroupUserRole/search/findByRolelistId`), so it needs no API work. Without it the discarded 422 body is the *only* path from *refused* to *resolved*, which is what makes follow-up 1 structurally load-bearing rather than a nicety. §12.3
4. **`UserGroupController.delete/{groupId}`** — the same non-atomic multi-delete with a complete cascade and no `@Transactional`. **Now owned: [SBDEV-3012](https://app.clickup.com/t/868kua93r) was WIDENED to cover it 2026-08-20** (§12.5), after this plan's review found it fell between two tickets with no owner at all.
5. **P3 tenant damage audit** — **DONE 2026-08-20: clean on all three reachable tenants** (hydra-uat 14 roles, wineco-dev 140, nywh-hydra-uat 14 — zero damaged). Not run against prd. §13.3
6. **Doc drift** — **none found.** `wms2-keycloak-role-matrix.md` has no role-lifecycle section and no architecture doc documents this endpoint's contract, so §12.6's suggestion rested on an assumption. §13.3
7. **Destructive `@GetMapping`** on `deletRole` / `UserGroupController:80` / `UserController:281` — CSRF and prefetch exposure. Observation only. §4.6
8. Existing and related: [SBDEV-3010](https://app.clickup.com/t/868kua912) (join-table uniqueness/indexes), [SBDEV-3012](https://app.clickup.com/t/868kua93r) (the non-atomic *save* family), [SBDEV-3013](https://app.clickup.com/t/868kua9b6) (SDR join-table **and association** exposure — surface #2 is the resource AC-11 does not close), [SBDEV-3014](https://app.clickup.com/t/868kua9c9) (`mvn_test_passes` always FAILs).
